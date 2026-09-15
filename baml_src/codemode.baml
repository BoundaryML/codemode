// ─────────────────────────────────────────────────────────────────────────────
// What model-written code sees. The model writes a BAML function
//
//     function run(codemode: host.Codemode) -> json { ... }
//
// The runtime compiles it with `reflect.Package.compile` (this package aliased
// as `host`) and hands it a `Codemode` bound to the execution. Its fields are
// the connectors (see connectors/), each a typed class whose methods route
// through the runtime. Adding a connector means one file in connectors/ plus
// one field, one entry in `all()`, and one line in `bind()` below.
// ─────────────────────────────────────────────────────────────────────────────

// NOTE (toolchain 0.19.1-nightly): a package used as a `reflect.Package.compile`
// dependency must not contain `type` aliases, and its methods must not have
// string-literal parameter defaults. Unions are written out inline and optional
// params default to null.

class SearchHit {
    path: string,
    connector: string,
    method: string,
    description: string,
    kind: "method" | "snippet",
    score: int,
}

class SearchResult {
    results: SearchHit[],
    total: int,
    truncated: bool,
}

/// What the runtime needs from the connector registry, without naming `Codemode`
/// (a class-level cycle Runtime → Codemode → Ctx → Runtime breaks the toolchain's parser setup).
interface Registry {
    function all(self) -> Connector[] throws never;
    function env(self) -> Env throws never;
    function bind(self, rt: Runtime, exec: Execution) -> Codemode throws never;
}

class Codemode {
    ctx: Ctx?, // null on the runtime's root registry; set on the copy each execution gets
    crm: Crm,
    billing: Billing,
    email: Email,
    github: Github,
    env: Env,

    implements Registry {
        function all(self) -> Connector[] throws never {
            [self.crm, self.billing, self.email, self.github, self.env]
        }
        function env(self) -> Env throws never {
            self.env
        }
        function bind(self, rt: Runtime, exec: Execution) -> Codemode throws never {
            Codemode {
                ctx: Ctx { rt: rt, exec: exec, connector: "codemode" },
                crm: self.crm.bind(rt, exec),
                billing: self.billing.bind(rt, exec),
                email: self.email.bind(rt, exec),
                github: self.github.bind(rt, exec),
                env: self.env.bind(rt, exec),
            }
        }
    }

    /// Find connector methods and saved snippets. Returns ranked paths, not full signatures.
    function search(self, query: string) -> SearchResult throws never {
        let ctx = self.ctx;
        if (ctx == null) {
            return SearchResult { results: [], total: 0, truncated: false };
        }
        let r = ctx.rt.search(query);
        ctx.exec.logs.push(`search(${jstr(query)}) → ${r.total} result(s)`);
        for (let h in r.results) {
            self.discover(h.path);
        }
        r
    }
    /// Make this source's functions available to future code as package `name`
    /// (saved when this execution completes). Returns the package alias.
    function publish(self, name: string, description: string) -> string throws never {
        let alias = identifier(name);
        let ctx = self.ctx;
        if (ctx != null) {
            ctx.exec.publish_as = alias;
            ctx.exec.publish_description = description;
            ctx.exec.logs.push(`publish(${jstr(alias)})`);
        }
        alias
    }
    function discover(self, path: string) -> void throws never {
        let ctx = self.ctx;
        if (ctx == null) {
            return;
        }
        if (!ctx.exec.discovered.includes(path)) {
            ctx.exec.discovered.push(path);
        }
    }
    /// BAML declarations for one connector ("crm"), one method ("crm.update_plan"), a snippet,
    /// or any BAML standard-library path ("baml.fs", "baml.http.fetch") via `baml describe`.
    function describe(self, target: string) -> string throws never {
        let ctx = self.ctx;
        if (ctx == null) {
            return "// not bound to an execution";
        }
        if (target.starts_with("baml.") || target.starts_with("reflect.") || target == "baml") {
            ctx.exec.logs.push(`describe(${jstr(target)}) → stdlib docs`);
            self.discover(target);
            return stdlib_docs(target);
        }
        let text = ctx.rt.describe(target);
        ctx.exec.logs.push(`describe(${jstr(target)})`);
        let c = ctx.rt.connector(target);
        if (c != null) {
            for (let t in c.tools()) {
                self.discover(`${target}.${t.name()}`);
            }
        } else {
            self.discover(target);
        }
        text
    }
    /// Record nondeterministic work once; later passes replay the recorded value.
    function step<T>(self, name: string, fn: () -> T throws unknown) -> T throws unknown {
        let ctx = self.ctx ?? throw err("codemode is not bound to an execution");
        let recorded = ctx.rt.step_begin(ctx.exec, name);
        if (recorded != null) {
            return baml.json.to<T>(recorded);
        }
        let value = fn();
        ctx.rt.step_end(ctx.exec, name, j(value));
        value
    }
    /// Run a saved snippet's `run` by name. (Snippets are also importable packages:
    /// `enterprise_names.run(codemode)` is the typed form.) Calls join this execution's log.
    function run(self, name: string, input: json = null) -> json throws unknown {
        let ctx = self.ctx ?? throw err("codemode is not bound to an execution");
        let pkg = ctx.rt.snippet_package(identifier(name));
        if (pkg == null) {
            return j({ "error": `no snippet named ${name}` });
        }
        let f = pkg.get_function<reflect.AnyFunction<Returns = unknown, Throws = unknown>>("run");
        if (f == null) {
            return j({ "error": `snippet ${name} has no run()` });
        }
        ctx.exec.logs.push(`run(${jstr(name)})`);
        j(call_run(f, self))
    }
}

/// The registry the server boots with: every connector, unbound.
function default_connectors() -> Registry throws never {
    Codemode {
        ctx: null,
        crm: seed_crm(),
        billing: seed_billing(),
        email: Email { sent: [], ctx: null },
        github: Github { ctx: null },
        env: Env { vars: {}, ctx: null },
    }
}

/// The Codemode object one execution gets: every connector bound to it.
function new_codemode(rt: Runtime, exec: Execution) -> Codemode throws never {
    rt.root.bind(rt, exec)
}

/// Compile model-written source into a package that can see this one as `host`
/// plus every dependency package (saved snippets) under its own alias.
function compile_package(
    source: string,
    deps: map<string, reflect.Package>,
) -> reflect.Package throws reflect.errors.CompilationError {
    let packages: map<string, reflect.Package> = {};
    for (let k in deps.keys()) {
        let d = deps.get(k);
        if (d != null) {
            packages.set(k, d);
        }
    }
    packages.set("host", reflect.Package.current());
    reflect.Package.compile({ "run.baml": source }, packages = packages) catch_all (e) {
        let c: reflect.errors.CompilationError => {
            throw c;
        },
        _ => {
            throw reflect.errors.CompilationError { message: `package initialization failed: ${e}`, diagnostics: [] };
        },
    }
}

/// Compile and extract the `run` entry point.
function compile_run(
    source: string,
    deps: map<string, reflect.Package>,
) -> reflect.AnyFunction<Returns = unknown, Throws = unknown> throws reflect.errors.CompilationError {
    let pkg = compile_package(source, deps);
    let f = pkg.get_function<reflect.AnyFunction<Returns = unknown, Throws = unknown>>("run");
    if (f == null) {
        throw reflect.errors.CompilationError {
            message: "the source must define `function run(codemode: host.Codemode) -> json`",
            diagnostics: [],
        };
    }
    f
}

/// Invoke a compiled `run` with the Codemode object, whatever the model named the parameter.
function call_run(
    f: reflect.AnyFunction<Returns = unknown, Throws = unknown>,
    codemode: Codemode,
) -> unknown throws unknown {
    let sig = reflect.signature(f);
    let param = sig.args.at(0)?.name ?? "codemode";
    let args: map<string, unknown> = {};
    args.set(param, codemode);
    reflect.call_any<unknown, unknown>(f, args)
}

// ───────────────────────────── rendering for describe ─────────────────────────────

/// A package's exported functions as BAML declarations, e.g. for a saved snippet.
function render_package_api(alias: string, pkg: reflect.Package) -> string {
    let fns = pkg.functions();
    let lines = fns.keys().map((name) -> {
        let f = fns.get(name);
        if (f == null) {
            return `    function ${name}(...)`;
        }
        let params = f.params().map((a) -> {
            `${a.name ?? "_"}: ${a.type.to_string()}${if (a.optional) { " = <default>" } else { "" }}`
        });
        `    function ${short_name(name)}(${params.join(", ")}) -> ${f.return_type().to_string()}`
    });
    `// package "${alias}" — call as: ${alias}.<function>(...), e.g. ${alias}.run(codemode)\n${lines.join("\n")}`
}

function render_signature(sig: reflect.Signature) -> string {
    let doc = if (sig.docstring != null) {
        `    /// ${sig.docstring ?? ""}\n`
    } else {
        ""
    };
    `${doc}    function ${signature_line(sig)}`
}

/// A connector's BAML declaration plus the classes its methods return.
function render_connector(c: Connector, only: string) -> string {
    let tools = c.tools().filter((t) -> {
        only == "" || t.name() == only
    });
    let flags = tools
        .map((t) -> {
            let f = [
                if (t.requires_approval) {
                    "requires approval"
                } else {
                    ""
                },
                if (t.reversible()) {
                    "reversible"
                } else {
                    ""
                },
                if (t.replay == ReplayPolicy.Reexecute) {
                    "re-executed on replay"
                } else {
                    ""
                },
            ]
                .filter((x) -> {
                    x.length() > 0
                });
            if (f.length() > 0) {
                `// ${t.name()}: ${f.join(", ")}`
            } else {
                ""
            }
        })
        .filter((x) -> {
            x.length() > 0
        });
    let body = tools.map((t) -> {
        render_signature(t.sig)
    });
    let types = result_classes(tools).map((t) -> {
        render_class(t)
    });
    `// use as: codemode.${c.name()}.<method>(...)   (keyword args: name = value)\n${flags.join("\n")}\nclass ${c.name()} {\n${body.join("\n")}\n}\n\n${types.join("\n\n")}`
}

/// The distinct classes a set of tools returns (unwrapping arrays and optionals).
function result_classes(tools: Tool[]) -> reflect.Type[] throws never {
    let seen: string[] = [];
    let out: reflect.Type[] = [];
    for (let t in tools) {
        let inner = unwrap_type(t.sig.returns);
        if (inner.as_class() != null && !seen.includes(inner.to_string())) {
            seen.push(inner.to_string());
            out.push(inner);
        }
    }
    out
}

function unwrap_type(t: reflect.Type) -> reflect.Type throws never {
    let arr = t.as_array();
    if (arr != null) {
        return unwrap_type(arr.element_type());
    }
    let u = t.as_union();
    if (u != null) {
        let members = u.member_types().filter((m) -> {
            m.to_string() != "null"
        });
        if (members.length() == 1) {
            return unwrap_type(members[0]);
        }
    }
    t
}

function render_class(t: reflect.Type) -> string {
    let c = t.as_class();
    if (c == null) {
        return `type ${t.to_string()}`;
    }
    let fields = c.fields().map((f) -> {
        let desc = if (f.meta.description != null) {
            `  // ${f.meta.description ?? ""}`
        } else {
            ""
        };
        `    ${f.name}: ${f.type?.to_string() ?? "unknown"},${desc}`
    });
    `class ${t.to_string()} {\n${fields.join("\n")}\n}`
}

/// Standard-library documentation via the toolchain's own `baml describe`.
function stdlib_docs(target: string) -> string {
    let out = baml.sys.exec(
        "baml",
        ["--agent-skill-check", "off", "describe", target, "--budget", "120"],
        baml.sys.ProcessOptions {
            cwd: null,
            env: null,
            timeout_ms: 20000,
            stdin: null,
            stderr: baml.sys.StderrMode.Pipe,
        },
    ) catch_all (e) {
        _ => {
            return `// could not run baml describe: ${e}`;
        }
    };
    let text = out.stdout.to_string().trim();
    if (text.length() == 0) {
        `// nothing found for ${target}: ${out.stderr.to_string().trim()}`
    } else {
        text
    }
}

/// `root.run` → `run`.
function short_name(name: string) -> string {
    let i = name.last_index_of(".");
    if (i == null) {
        name
    } else {
        name.slice(i + 1, name.length())
    }
}

/// Compact one-line signature for tool listings: `name(a: T, b: U = <default>) -> R`.
function signature_line(sig: reflect.Signature) -> string {
    let params = sig.args.map((a) -> {
        `${a.name}: ${a.type.to_string()}`
    });
    for (let k in sig.opts.keys()) {
        let a = sig.opts.get(k);
        if (a != null) {
            params.push(`${a.name}: ${a.type.to_string()} = <default>`);
        }
    }
    `${sig.name ?? "?"}(${params.join(", ")}) -> ${sig.returns.to_string()}`
}
