// ─────────────────────────────────────────────────────────────────────────────
// The model side of Code Mode. The model sees ONE tool, `codemode`, which takes
// BAML source. The return type of NextStep IS that tool contract. The agent
// loop itself lives here too and runs inside the server on a green thread.
// ─────────────────────────────────────────────────────────────────────────────

// Code generation always goes through the local Claude Code CLI with Sonnet:
// it gets the BAML language reference in-prompt and can be given more context
// cheaply. Set CODEMODE_MODEL to pick another Claude Code model alias.
client CodeGen = claude_code.ClaudeCodeClient.new(model = "sonnet", timeout_ms = 240000);

/// The BAML language reference the code generator sees: the agent skill that
/// `baml agent install` writes for the pinned toolchain (frontmatter stripped).
function load_reference() -> string {
    let text = baml.fs.read(".claude/skills/baml-core/SKILL.md") catch_all (e) {
        _ => {
            log.warn(
                "no .claude/skills/baml-core/SKILL.md; run `baml agent install` for a better code generator",
            );
            ""
        }
    };
    //# Drop the YAML frontmatter block
    if (text.starts_with("---")) {
        let end = text.index_of("\n---");
        if (end != null) {
            return text.slice(end + 4, text.length()).trim();
        }
    }
    text
}

enum Action {
    Codemode,
    Answer,
}

/// The model's reply: either a codemode tool call or a final answer.
/// (One class instead of a union: the Claude Code CLI's --json-schema rejects anyOf.)
class AgentStep {
    thought: string @description("One sentence: what you will do next and why"),
    action: Action @description("Codemode = run the BAML below. Answer = the task is done, reply to the user."),
    code: string? @description(
        "When action is Codemode: BAML source defining `function run(codemode: host.Codemode) -> json { ... }`. No markdown fences. Null otherwise.",
    ),
    answer: string? @description(
        "When action is Answer: Markdown reply summarizing what was done and the results. Null otherwise.",
    ),
}

class Turn {
    thought: string,
    code: string,
    execution_id: string,
    outcome: string @description("JSON returned by the codemode tool"),
    message_index: int @description("which user message this execution answered"),
}

class Message {
    role: "user" | "assistant",
    text: string,
}

/// The whole conversation as the model sees it: messages in order, with each
/// user message followed by the executions it caused.
function render_history(messages: Message[], turns: Turn[]) -> string {
    let out: string[] = [];
    let i = 0;
    for (let m in messages) {
        if (m.role == "user") {
            out.push(`### User\n${m.text}`);
            for (let t in turns) {
                if (t.message_index == i) {
                    out.push(
                        `<execution id="${t.execution_id}">\n<code>\n${t.code}\n</code>\n<outcome>\n${t.outcome}\n</outcome>\n</execution>`,
                    );
                }
            }
        } else {
            out.push(`### Assistant\n${m.text}`);
        }
        i += 1;
    }
    out.join("\n\n")
}

/// The model's own saved tools, so it knows they exist without searching.
function render_tools(snippets: Snippet[]) -> string {
    if (snippets.length() == 0) {
        return "(none yet — call codemode.publish(name, description) inside run() to save one)";
    }
    snippets
        .map((sn) -> {
            `${sn.name} — ${sn.description}\n${sn.api ?? ""}`
        })
        .join("\n\n")
}

function codemode_surface(connectors: string[]) -> string {
    `
        What \`codemode\` gives you:
          codemode.search(query: string) -> SearchResult           // { results: [{path, connector, method, description, kind, score}], total, truncated }
          codemode.describe(target: string) -> string              // BAML declarations for "crm", "crm.update_plan", or a snippet name
          codemode.step<T>(name: string, fn: () -> T) -> T          // record nondeterministic work (time, random) so replay is stable
          codemode.publish(name: string, description: string) -> string
            // Save THIS source as a reusable tool package: every top-level function in it becomes callable from
            // later code as <name>.<function>(...). Call it at the end of run() once the functions work.
          Saved tools/snippets are packages you can call directly, e.g. calculator.add(a = 1, b = 2);
            codemode.search("...") lists them (kind "snippet") and codemode.describe(name) shows their functions.
          Connector objects: ${connectors.map((c) -> { `codemode.${c}` }).join(", ")}.
            Methods take keyword arguments (name = value) and return typed values, e.g.
            let customers = codemode.crm.list_customers(plan = "pro");
          Host types are referenced as host.<Name>, e.g. host.Customer.
          codemode.env.get("NAME") -> string   // secrets/API keys the user manages in the UI. If NAME is not set the run pauses and
            // the user is asked for it there: NEVER ask the user to paste a secret into chat, never print or return the value.
          The whole BAML standard library is available inside run(): baml.fs (read_dir, read, write, exists),
            baml.http.fetch, baml.json, baml.time, baml.csv, baml.sys.exec, log. Never guess an API name:
            codemode.describe("baml.fs") or codemode.describe("baml.http.fetch") returns the real docs for any stdlib path.
    `
}

function baml_cheatsheet() -> string {
    `
        BAML in 12 lines (it is TypeScript-shaped, snake_case, strict):
          let x = 1; x = x + 1;                      // let bindings are reassignable; no const, no var
          let names: string[] = [];  names.push(n);  // arrays: push/filter/map/find/length()/join/at(i)
          for (let c in customers) { ... }            // iterates values; while (cond) { ... }
          if (a > b) { "big" } else { "small" }       // if/else is an expression; NO ternary operator
          let total = xs.reduce((acc, x) -> { acc + x.amount }, 0.0);   // closures ALWAYS have parens and braces: (c) -> { c.name == "Ada" }
          \`Hi \${c.name}, you owe \${amount}\`           // backtick strings interpolate anything; "a" + 1 does NOT compile
          let m: map<string, json> = {};              // maps need a type; m.set(k, v); m.get(k) ?? default
          baml.json.from(value)                       // any value -> json (rarely needed: run() may return any type)
          int / int truncates; use 1.0 * n for floats // 285 / 100 == 2
          x.to_string()                               // stringify; no implicit string concat with +
          log.info("...")                             // logging; there is no console
          xs.at(0) returns T?; xs[0] panics if empty   // there is NO non-null operator (no x!): use ?? default, or if let c: host.Customer = opt { ... }
          Host types always need the prefix: host.Customer, host.Invoice (never bare Customer)
          The last expression of a block is its value; use return x; for early exit.
    `
}

/// The inner repair loop: given code that failed to compile, return corrected code.
class CodeFix {
    thought: string @description("One sentence: what was wrong"),
    code: string @description("The complete corrected BAML source. No markdown fences."),
}

function FixCode(
    code: string,
    diagnostics: string,
    connectors: string[],
    api: string,
    reference: string,
) -> CodeFix {
    client: CodeGen
    prompt: `
        This BAML source failed to compile. Fix it and return the COMPLETE corrected source.
        Change as little as possible: keep every call and the intent, fix only what the diagnostics point at.
        Keep the entry point: function run(codemode: host.Codemode) -> <any type>. Any return type is fine.
        Output ONLY BAML source in the code field: no markdown fences, no tags, no commentary.

        ${codemode_surface(connectors)}

        ${baml_cheatsheet()}

        BAML language reference:
        ${reference}

        Connector declarations (host types are host.<Name>):
        ${api}

        ===== SOURCE THAT FAILED =====
        ${code}
        ===== COMPILER DIAGNOSTICS =====
        ${diagnostics}
        ===== END =====

        ${ctx.output_format()}
    `
}

function NextStep(
    history: string,
    connectors: string[],
    tools: string,
    reference: string,
) -> AgentStep {
    client: CodeGen
    prompt: `
        You are an agent that gets work done by writing code. You have exactly one tool: codemode.

        codemode takes BAML source, compiles it, runs it, and returns the outcome as data:
        {"status":"completed","result":...,"logs":[...]},
        {"status":"paused","pending":[{connector,method,args}]} or {"status":"error","error":"..."}.
        Compile errors come back as an error outcome with diagnostics: fix the code and try again.

        The source MUST define this entry point (any return type):
            function run(codemode: host.Codemode) -> SomeType { ... }
        Return whatever is useful: a class you define in the same source, a list, a map, a string.
        It is converted to JSON and becomes "result". Keep it small.

        ${codemode_surface(connectors)}

        ${baml_cheatsheet()}

        Rules:
          - You do not know the connector methods or their signatures up front. In your first execution,
            call codemode.search(...) and codemode.describe(...) and RETURN the declaration text so you can use it next time.
          - Some methods require user approval. When your code reaches one, the execution pauses and the user decides.
            On approval the same code is re-run from the top: already-applied calls replay from a log instead of executing again.
            Therefore: keep call order and arguments deterministic; do not spawn; never wrap connector calls in catch_all.
          - If the user rejects an action, the execution ends with an error; earlier calls stay applied. Do not retry a rejected action.
          - If your code does not compile, the runtime asks a repair step to fix it; you will see the fixed code and its outcome.
          - Prefer one execution that does the whole job over many tiny ones. Discovery first, then one execution that acts.
          - When you are asked to build a tool, define the functions, test them in the same run(), then codemode.publish() them.
          - A service with no connector (a public API, Exa, Slack, a database, anything reachable over HTTP) is NOT a reason
            to give up: build the tool yourself with baml.http.fetch (API keys via codemode.env.get, which pauses to ask the
            user), prove it works in the same run(), then codemode.publish() it. Never answer that a connector must be
            added on the host side.
          - When the latest user message is answered (or truly impossible), set action = Answer instead of more code.

        BAML language reference (authoritative; prefer it over memory):
        ${reference}

        Your saved tools (already compiled; call them as <name>.<function>(...)):
        ${tools}

        Conversation so far. Respond to the LATEST user message; earlier messages are context.
        ${history}

        ${ctx.output_format()}
    `
}

// ───────────────────────────── sessions + loop ─────────────────────────────
class Session {
    id: string,
    task: string @description("the first user message"),
    messages: Message[],
    turns: Turn[],
    status: "thinking" | "executing" | "paused" | "done" | "error",
    answer: string?,
    thought: string?,
    current_execution_id: string?,
    created_at: string,
    updated_at: string,
}

class App {
    runtime: Runtime,
    sessions: Session[],
    started_at: string,
    sockets: baml.ws.WebSocket[],
    streams: baml.http.Response[],

    // ── fan-out: every state change becomes one event to every client ──
    // Two transports carry the same events: WebSocket frames and Server-Sent
    // Events over a streaming HTTP response. Dead connections are dropped.
    function broadcast(self, event: unknown) -> void throws never {
        let text = jstr(event);
        let dead_ws: baml.ws.WebSocket[] = [];
        for (let ws in self.sockets) {
            ws.send(text) catch_all (e) {
                _ => dead_ws.push(ws)
            };
        }
        if (dead_ws.length() > 0) {
            self.sockets
                = self.sockets.filter((ws) -> {
                    !dead_ws.includes(ws)
                });
        }
        let frame = `data: ${text}\n\n`.to_utf8();
        let dead_streams: baml.http.Response[] = [];
        for (let res in self.streams) {
            res.write(frame) catch_all (e) {
                _ => dead_streams.push(res)
            };
        }
        if (dead_streams.length() > 0) {
            self.streams
                = self.streams.filter((res) -> {
                    !dead_streams.includes(res)
                });
        }
    }
    /// SSE comment line; keeps proxies and browsers from timing out idle streams.
    function keepalive(self) -> void throws never {
        let dead: baml.http.Response[] = [];
        for (let res in self.streams) {
            res.write(": ping\n\n".to_utf8()) catch_all (e) {
                _ => dead.push(res)
            };
        }
        if (dead.length() > 0) {
            self.streams
                = self.streams.filter((res) -> {
                    !dead.includes(res)
                });
        }
    }
    function world(self) -> json throws never {
        j(
            self.runtime.root.all().map((c) -> {
                WorldView { name: c.name(), world: c.world() }
            }),
        )
    }
    implements RuntimeListener {
        function on_execution(self, exec: Execution) -> void throws never {
            self.broadcast(
                ExecutionEvent { type: "execution", execution: exec, world: self.world() },
            );
        }
        function on_snippets(self, snippets: Snippet[]) -> void throws never {
            self.broadcast(SnippetsEvent { type: "snippets", snippets: snippets });
        }
        function on_notice(self, exec: Execution, message: string) -> void throws never {
            self.broadcast(NoticeEvent { type: "notice", execution_id: exec.id, message: message });
        }
        function on_env(self, names: string[]) -> void throws never {
            self.broadcast(EnvEvent { type: "env", names: names });
        }
    }

    function session(self, id: string) -> Session? throws never {
        self.sessions.find((s) -> {
            s.id == id
        })
    }
    function session_for_execution(self, execution_id: string) -> Session? throws never {
        self.sessions.find((s) -> {
            s.current_execution_id == execution_id
        })
    }
    function touch(self, s: Session) -> void throws never {
        s.updated_at = baml.time.Instant.now().to_string();
        self.persist_sessions();
        self.broadcast(SessionEvent { type: "session", session: s });
    }
    function persist_sessions(self) -> void throws never {
        baml.fs.write(".codemode/sessions.json", jstr(self.sessions)) catch_all (e) {
            _ => 0
        };
    }
    function load_sessions(self) -> void throws never {
        if (
            !(
                baml.fs.exists(".codemode/sessions.json") catch_all (e) {
                    _ => false
                }
            )
        ) {
            return;
        }
        let text = baml.fs.read(".codemode/sessions.json") catch_all (e) {
            _ => "[]"
        };
        self.sessions
            = baml.json.from_string<Session[]>(text) catch_all (e) {
                _ => []
            };
        for (let s in self.sessions) {
            if (s.status == "thinking" || s.status == "executing") {
                s.status = "error";
                s.answer = "server restarted mid-run";
            }
        }
    }

    function start_session(self, task: string) -> Session throws never {
        //# New conversation: one Session with the first user message, then the agent loop
        let now = baml.time.Instant.now().to_string();
        let s = Session {
            id: self.runtime.fresh_id("sess"),
            task: task,
            messages: [Message { role: "user", text: task }],
            turns: [],
            status: "thinking",
            answer: null,
            thought: null,
            current_execution_id: null,
            created_at: now,
            updated_at: now,
        };
        self.sessions.push(s);
        self.touch(s);
        //# The loop runs on its own green thread; clients get events over the WebSocket
        spawn with baml.spawn.options(detach = true) { self.drive(s) };
        s
    }

    /// Continue a conversation with another user message.
    function say(self, session_id: string, text: string) -> Session? throws never {
        let found = self.session(session_id);
        if (found == null) {
            return null;
        }
        let s: Session = found;
        if (
            text.length() == 0
                || s.status == "thinking"
                || s.status == "executing"
                || s.status == "paused"
        ) {
            return null;
        }
        //# Follow-up message: append it and wake the loop again
        s.messages.push(Message { role: "user", text: text });
        s.status = "thinking";
        s.answer = null;
        s.thought = null;
        self.touch(s);
        spawn with baml.spawn.options(detach = true) { self.drive(s) };
        s
    }

    function last_user_index(self, s: Session) -> int throws never {
        let idx = 0;
        let i = 0;
        for (let m in s.messages) {
            if (m.role == "user") {
                idx = i;
            }
            i += 1;
        }
        idx
    }

    /// The agent loop: ask the model, run its code, feed the outcome back, until
    /// it answers, pauses for approval, or hits the step limit.
    function drive(self, s: Session) -> void throws never {
        //# Agent loop: think (one LLM call) → run code → read the outcome → repeat until it answers or pauses
        while (true) {
            let msg_index = self.last_user_index(s);
            let steps_here = s.turns
                .filter((t) -> {
                    t.message_index == msg_index
                })
                .length();
            //# Safety valve: at most 8 executions per user message
            if (steps_here >= 8) {
                s.status = "error";
                s.answer = "Stopped after 8 executions without finishing.";
                s.messages.push(Message { role: "assistant", text: s.answer ?? "" });
                self.touch(s);
                return;
            }
            s.status = "thinking";
            self.touch(s);
            //# One LLM call: the return type is the codemode tool contract
            let history = render_history(s.messages, s.turns);
            let connectors = self.runtime.connector_names();
            let tools = render_tools(self.runtime.snippets);
            let reference = self.runtime.reference;
            //# On its own green thread so a panic inside the toolchain is captured too;
            //# otherwise this thread would die and the session would stay "thinking" forever.
            let settled = await baml.future.all_settled([
                spawn { NextStep(history, connectors, tools, reference) },
            ]);
            let step = match (settled[0]) {
                let ok: baml.future.Success<AgentStep> => ok.value,
                let p: baml.future.Panicked => {
                    s.status = "error";
                    s.answer = `model call panicked: ${p.panic}`;
                    self.touch(s);
                    return;
                },
                _ => {
                    s.status = "error";
                    s.answer = `model call failed: ${settled[0]}`;
                    self.touch(s);
                    return;
                },
            };
            s.thought = step.thought;
            let code = step.code ?? "";
            //# Answer: the model is done with tools; reply to the user and stop
            if (step.action != Action.Codemode || code.trim().length() == 0) {
                s.status = "done";
                s.answer = step.answer ?? step.thought;
                s.messages.push(Message { role: "assistant", text: s.answer ?? "" });
                s.current_execution_id = null;
                self.touch(s);
                return;
            }
            //# Codemode: create an execution and run the first pass
            let latest = s.messages.at(msg_index)?.text ?? s.task;
            let exec = self.runtime.create(code, latest);
            s.status = "executing";
            s.current_execution_id = exec.id;
            self.touch(s);
            //# First pass: compile + run; the outcome decides whether the loop continues
            let outcome = self.runtime.run_pass(exec);
            if (!self.settle(s, exec, outcome)) {
                return;
            }
        }
    }

    /// Record an outcome on the session. Returns true if the loop should continue.
    function settle(
        self,
        s: Session,
        exec: Execution,
        outcome: Completed | Paused | Failed,
    ) -> bool throws never {
        //# Paused → wait for the user (approve/reject resumes the loop); otherwise record the turn and go again
        match (outcome) {
            let p: Paused => {
                s.status = "paused";
                self.touch(s);
                false
            },
            _ => {
                s.turns.push(
                    Turn {
                        thought: s.thought ?? "",
                        code: exec.code,
                        execution_id: exec.id,
                        outcome: jstr(outcome),
                        message_index: self.last_user_index(s),
                    },
                );
                s.current_execution_id = null;
                self.touch(s);
                true
            },
        }
    }

    /// User approved: re-run the pass, then continue the loop on a green thread.
    function approve(self, execution_id: string) -> Completed | Paused | Failed throws never {
        let s = self.session_for_execution(execution_id);
        let exec = self.runtime.execution(execution_id);
        if (exec == null) {
            return Failed {
                status: "error",
                execution_id: execution_id,
                error: "unknown execution",
                logs: [],
            };
        }
        if (s != null) {
            s.status = "executing";
            self.touch(s);
        }
        //# Approve: the runtime re-runs the same code; the approved call executes this time
        let outcome = self.runtime.approve(execution_id);
        if (s != null) {
            self.continue_after(s, exec, outcome);
        }
        outcome
    }

    function reject(self, execution_id: string) -> Completed | Paused | Failed throws never {
        let s = self.session_for_execution(execution_id);
        let exec = self.runtime.execution(execution_id);
        let outcome = self.runtime.reject(execution_id);
        if (s != null && exec != null) {
            self.continue_after(s, exec, outcome);
        }
        outcome
    }

    function continue_after(
        self,
        s: Session,
        exec: Execution,
        outcome: Completed | Paused | Failed,
    ) -> void throws never {
        //# After approve/reject: resume the agent loop on its own green thread if there is more to do
        if (self.settle(s, exec, outcome)) {
            spawn with baml.spawn.options(detach = true) { self.drive(s) };
        }
    }
}

function build_app() -> App {
    //# Boot: connectors → durable runtime → language reference → app with sessions and sockets
    let rt = create_runtime();
    rt.reference = load_reference();
    let app = App {
        runtime: rt,
        sessions: [],
        started_at: baml.time.Instant.now().to_string(),
        sockets: [],
        streams: [],
    };
    app.load_sessions();
    rt.listeners.push(app);
    app
}

test "history renders messages with their executions" {
    let msgs = [
        Message { role: "user", text: "build a calculator" },
        Message { role: "assistant", text: "done" },
        Message { role: "user", text: "use it" },
    ];
    let turns = [
        Turn {
            thought: "t",
            code: "function run(codemode: host.Codemode) -> int { 1 }",
            execution_id: "exec_1",
            outcome: `{"status":"completed"}`,
            message_index: 0,
        },
    ];
    let h = render_history(msgs, turns);
    assert.is_true((h.index_of("build a calculator") ?? 99999) < (h.index_of("exec_1") ?? -1));
    assert.is_true((h.index_of("exec_1") ?? 99999) < (h.index_of("### Assistant") ?? -1));
    assert.is_true(h.includes("use it"));
    assert.is_true(render_tools([]).includes("publish"))
}

// ── events on the wire ──
class WorldView {
    name: string,
    world: json,
}

class SessionEvent {
    type: "session",
    session: Session,
}

class ExecutionEvent {
    type: "execution",
    execution: Execution,
    world: json,
}

class SnippetsEvent {
    type: "snippets",
    snippets: Snippet[],
}

class EnvEvent {
    type: "env",
    names: string[],
}

class NoticeEvent {
    type: "notice",
    execution_id: string,
    message: string,
}
