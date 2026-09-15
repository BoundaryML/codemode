// ─────────────────────────────────────────────────────────────────────────────
// HTTP API. The frontend is only a view: it starts sessions, approves or
// rejects, rolls back, saves snippets, and polls /api/state.
// ─────────────────────────────────────────────────────────────────────────────

class StateView {
    runtime: RuntimeView,
    sessions: Session[],
    started_at: string,
}

class RuntimeView {
    name: string,
    executions: Execution[],
    snippets: Snippet[],
    connectors: ConnectorView[],
    tools: ToolView[],
    env: string[] @description("names only; values never leave the runtime"),
}

/// One callable thing the model can discover, listed by reflection.
class ToolView {
    path: string,
    connector: string,
    name: string,
    kind: "method" | "snippet",
    signature: string,
    docstring: string?,
    requires_approval: bool,
    reversible: bool,
    replay: ReplayPolicy,
}

class ConnectorView {
    name: string,
    description: string,
    methods: MethodSpec[],
    api: string @description("BAML declarations, as codemode.describe() renders them"),
    world: json,
}

class ErrorBody {
    error: string,
}

/// One saved tool with everything the manager UI needs.
class ToolDetail {
    snippet: Snippet,
    functions: ToolView[],
    used_by: string[] @description("execution ids whose source calls this tool"),
}

function tool_detail(app: App, name: string) -> ToolDetail? {
    let found = app.runtime.snippet(name);
    if (found == null) {
        return null;
    }
    let sn: Snippet = found;
    let fns = state_view(app).runtime.tools.filter((t) -> {
        t.connector == name
    });
    let used = app.runtime.executions
        .filter((e) -> {
            e.id != sn.source_execution_id && e.code.includes(`${name}.`)
        })
        .map((e) -> {
            e.id
        });
    ToolDetail { snippet: sn, functions: fns, used_by: used }
}

function state_view(app: App) -> StateView {
    let rt = app.runtime;
    //# A scratch Codemode instance just to render each connector's API by reflection
    let probe = new_codemode(
        rt,
        Execution {
            id: "probe",
            task: "",
            code: "",
            status: ExecutionStatus.Error,
            log: [],
            result: null,
            error: null,
            logs: [],
            connectors: [],
            pass_count: 0,
            cursor: 0,
            fix_log: [],
            discovered: [],
            publish_as: null,
            publish_description: null,
            created_at: "",
            updated_at: "",
        },
    );
    let connectors = rt.connectors.map((c) -> {
        ConnectorView {
            name: c.name(),
            description: c.description(),
            methods: c.methods(),
            api: rt.describe(probe, c.name()),
            world: c.world(),
        }
    });
    //# Tools by reflection: every connector method's live signature + docstring, then snippet packages
    let tools: ToolView[] = [];
    for (let c in rt.connectors) {
        let specs = c.methods();
        for (let sg in probe.api(c.name())) {
            let spec = specs.find((m) -> {
                m.name == sg.name
            });
            tools.push(
                ToolView {
                    path: `${c.name()}.${sg.name ?? "?"}`,
                    connector: c.name(),
                    name: sg.name ?? "?",
                    kind: "method",
                    signature: signature_line(sg),
                    docstring: sg.docstring,
                    requires_approval: spec?.requires_approval ?? false,
                    reversible: spec?.reversible ?? false,
                    replay: spec?.replay ?? ReplayPolicy.Record,
                },
            );
        }
    }
    for (let sn in rt.snippets) {
        let pkg = rt.snippet_package(sn.name);
        if (pkg == null) {
            continue;
        }
        let fns = pkg.functions();
        for (let fname in fns.keys()) {
            let f = fns.get(fname);
            if (f == null) {
                continue;
            }
            let params = f.params().map((a) -> {
                `${a.name ?? "_"}: ${a.type.to_string()}`
            });
            tools.push(
                ToolView {
                    path: `${sn.name}.${short_name(fname)}`,
                    connector: sn.name,
                    name: short_name(fname),
                    kind: "snippet",
                    signature: `${short_name(fname)}(${params.join(", ")}) -> ${f.return_type().to_string()}`,
                    docstring: sn.description,
                    requires_approval: false,
                    reversible: false,
                    replay: ReplayPolicy.Record,
                },
            );
        }
    }
    StateView {
        runtime: RuntimeView {
            name: rt.name,
            executions: rt.executions.reverse(),
            snippets: rt.snippets,
            connectors: connectors,
            tools: tools,
            env: rt.env.vars.keys(),
        },
        sessions: app.sessions.reverse(),
        started_at: app.started_at,
    }
}

// ───────────────────────────── websocket ─────────────────────────────
// GET /ws upgrades. On connect the client gets a full snapshot; afterwards
// every runtime/session change arrives as one event. Commands go the other way.

class SnapshotEvent {
    type: "snapshot",
    state: StateView,
}

class ErrorEvent {
    type: "error",
    error: string,
}

class ResultEvent {
    type: "result",
    command: string,
    result: unknown,
}

function ws_upgrade(app: App, req: baml.http.Request) -> baml.http.Response | baml.http.WsAccept {
    log.info(`websocket upgrade: ${req.method} ${req.url}`);
    if (req.url.split("?")[0] != "/ws") {
        return baml.http.reject_websocket(req);
    }
    (socket: baml.ws.WebSocket) -> {
        app.sockets.push(socket);
        defer {
            app.sockets
                = app.sockets.filter((ws) -> {
                    ws != socket
                });
        }
        socket.send(jstr(SnapshotEvent { type: "snapshot", state: state_view(app) })) catch_all (e) {
            _ => {
                return;
            }
        };
        while (true) {
            let frame = socket.next() catch_all (e) {
                _ => {
                    break;
                }
            };
            match (frame) {
                let text: string => ws_command(app, socket, text),
                baml.ws.CloseEvent => {
                    break;
                },
                _ => {},
            }
        }
    }
}

/// One command from a client. Long-running ones run on their own green thread
/// so this socket keeps reading.
function ws_command(app: App, socket: baml.ws.WebSocket, text: string) -> void {
    let msg = jparse(text);
    let kind = body_str(msg, "type");
    let id = body_str(msg, "execution_id");
    let reply = (command: string, result: unknown) -> {
        socket.send(jstr(ResultEvent { type: "result", command: command, result: result })) catch_all (e) {
            _ => null
        };
    };
    match (kind) {
        "start" => {
            let task = body_str(msg, "task").trim();
            if (task.length() == 0) {
                reply("start", ErrorBody { error: "task is required" });
            } else {
                reply("start", app.start_session(task));
            }
        },
        "approve" => {
            spawn with baml.spawn.options(detach = true) { reply("approve", app.approve(id)) };
        },
        "reject" => {
            spawn with baml.spawn.options(detach = true) { reply("reject", app.reject(id)) };
        },
        "rollback" => reply("rollback", app.runtime.rollback(id)),
        "set_env" => {
            let name = body_str(msg, "name");
            let value = body_str(msg, "value");
            if (name.length() == 0 || value.length() == 0) {
                reply("set_env", ErrorBody { error: "name and value are required" });
            } else {
                app.runtime.set_env(name, value);
                reply("set_env", { "set": name });
            }
        },
        "delete_env" => {
            let name = body_str(msg, "name");
            if (app.runtime.delete_env(name)) {
                reply("delete_env", { "deleted": name });
            } else {
                reply("delete_env", ErrorBody { error: `${name} is not set` });
            }
        },
        "delete_tool" => {
            let name = body_str(msg, "name");
            if (app.runtime.delete_snippet(name)) {
                reply("delete_tool", { "deleted": name });
            } else {
                reply("delete_tool", ErrorBody { error: `no tool named ${name}` });
            }
        },
        "save_snippet" => {
            let s = app.runtime.save_snippet(
                body_str(msg, "name").trim(),
                body_str(msg, "description").trim(),
                id,
            );
            if (s == null) {
                reply(
                    "save_snippet",
                    ErrorBody { error: "snippets need a name and a Completed execution" },
                );
            } else {
                reply("save_snippet", s);
            }
        },
        "run_code" => {
            spawn with baml.spawn.options(detach = true) {
                let exec = app.runtime.create(body_str(msg, "code"), body_str(msg, "task"));
                reply("run_code", app.runtime.run_pass(exec))
            };
        },
        _ => reply(kind, ErrorBody { error: `unknown command ${kind}` }),
    }
}

function cors() -> map<string, string> {
    {
        "content-type": "application/json",
        "access-control-allow-origin": "*",
        "access-control-allow-methods": "GET, POST, PUT, DELETE, OPTIONS",
        "access-control-allow-headers": "content-type",
    }
}

function respond(status: int, body: unknown) -> baml.http.Response {
    baml.http.Response.new(status, cors(), jstr(body).to_utf8())
}

function bad_request(message: string) -> baml.http.Response {
    respond(400, ErrorBody { error: message })
}

function body_str(body: json, key: string) -> string {
    baml.json.path_or<string>(body, `.${key}`, "")
}

function handle(app: App, req: baml.http.Request) -> baml.http.Response {
    let path = req.url.split("?")[0];
    let parts = path.split("/").filter((p) -> {
        p.length() > 0
    });
    let body = jparse(req.body);
    let method = req.method.to_upper_case();
    if (method == "OPTIONS") {
        return baml.http.Response.new(204, cors(), "".to_utf8());
    }

    if (method == "GET" && path == "/api/state") {
        return respond(200, state_view(app));
    }

    // Server-Sent Events: same events as /ws, one direction. Commands go over POST.
    if (method == "GET" && path == "/api/events") {
        let res = baml.http.Response.new_streaming(
            200,
            {
                "content-type": "text/event-stream",
                "cache-control": "no-cache",
                "access-control-allow-origin": "*",
            },
        );
        res.write(
            `data: ${jstr(SnapshotEvent { type: "snapshot", state: state_view(app) })}\n\n`.to_utf8(
            ),
        );
        app.streams.push(res);
        return res;
    }

    // Start a session: the agent loop runs in the background, poll /api/state.
    if (method == "POST" && path == "/api/sessions") {
        let task = body_str(body, "task").trim();
        if (task.length() == 0) {
            return bad_request("task is required");
        }
        return respond(200, app.start_session(task));
    }

    // Continue a conversation: POST /api/sessions/:id/messages {text}
    if (
        parts.length() == 4
            && parts[0] == "api"
            && parts[1] == "sessions"
            && parts[3] == "messages"
            && method == "POST"
    ) {
        let s = app.say(parts[2], body_str(body, "text").trim());
        if (s == null) {
            return bad_request("unknown session, empty text, or session busy");
        }
        return respond(200, s);
    }

    // Run BAML directly, no model involved (playground). Synchronous.
    if (method == "POST" && path == "/api/executions") {
        let code = body_str(body, "code");
        if (code.trim().length() == 0) {
            return bad_request("code is required");
        }
        let exec = app.runtime.create(code, body_str(body, "task"));
        return respond(200, app.runtime.run_pass(exec));
    }

    // /api/executions/:id/<action>
    if (parts.length() == 4 && parts[0] == "api" && parts[1] == "executions" && method == "POST") {
        let id = parts[2];
        match (parts[3]) {
            "approve" => {
                return respond(200, app.approve(id));
            },
            "reject" => {
                return respond(200, app.reject(id));
            },
            "rollback" => {
                return respond(200, app.runtime.rollback(id));
            },
            _ => {},
        }
    }

    // Env vault: names are public, values are write-only.
    if (method == "GET" && path == "/api/env") {
        return respond(200, app.runtime.env.vars.keys());
    }
    if (parts.length() == 3 && parts[0] == "api" && parts[1] == "env") {
        let name = parts[2];
        if (method == "PUT" || method == "POST") {
            let value = body_str(body, "value");
            if (name.length() == 0 || value.length() == 0) {
                return bad_request("name and value are required");
            }
            app.runtime.set_env(name, value);
            return respond(200, { "set": name });
        }
        if (method == "DELETE") {
            if (!app.runtime.delete_env(name)) {
                return respond(404, ErrorBody { error: `${name} is not set` });
            }
            return respond(200, { "deleted": name });
        }
    }

    // Tool manager: list, inspect, delete saved tools.
    if (method == "GET" && path == "/api/tools") {
        return respond(200, state_view(app).runtime.tools);
    }
    if (parts.length() == 3 && parts[0] == "api" && parts[1] == "tools") {
        let name = parts[2];
        if (method == "GET") {
            let d = tool_detail(app, name);
            if (d == null) {
                return respond(404, ErrorBody { error: `no tool named ${name}` });
            }
            return respond(200, d);
        }
        if (method == "DELETE") {
            if (!app.runtime.delete_snippet(name)) {
                return respond(404, ErrorBody { error: `no tool named ${name}` });
            }
            return respond(200, { "deleted": name });
        }
    }
    if (method == "POST" && path == "/api/snippets") {
        let s = app.runtime.save_snippet(
            body_str(body, "name").trim(),
            body_str(body, "description").trim(),
            body_str(body, "execution_id"),
        );
        if (s == null) {
            return bad_request("snippets need a name and a Completed execution");
        }
        return respond(200, s);
    }
    if (method == "POST" && path == "/api/maintenance/expire") {
        let n = app.runtime.expire_paused(baml.json.path_or<int>(body, ".max_age_seconds", 600));
        return respond(200, { "expired": n });
    }
    if (method == "POST" && path == "/api/maintenance/prune") {
        return respond(200, { "pruned": app.runtime.prune_executions() });
    }
    if (method == "GET" && path == "/") {
        return respond(200, { "service": "codemode-baml", "docs": "/api/state" });
    }
    respond(404, ErrorBody { error: `no route ${method} ${path}` })
}
