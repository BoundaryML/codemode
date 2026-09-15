// ─────────────────────────────────────────────────────────────────────────────
// What model-written code sees. The model writes a BAML function
//
//     function run(codemode: host.Codemode) -> json { ... }
//
// The runtime compiles it with `reflect.Package.compile` (this package aliased
// as `host`) and hands it a `Codemode` instance. Every connector call goes
// through `Runtime.on_call`, which assigns the sequence number and applies
// approval / replay policy. Approval is a thrown error that unwinds the pass.
// ─────────────────────────────────────────────────────────────────────────────

// ── errors that cross from the runtime into generated code ──
class PausedForApproval {
    pending: PendingAction,
}

class ReplayDivergence {
    message: string,
}

class ConnectorError {
    connector: string,
    method: string,
    message: string,
}

// NOTE (toolchain 0.19.1-nightly): a package used as a `reflect.Package.compile`
// dependency must not contain `type` aliases, and its methods must not have
// string-literal parameter defaults. Unions are written out inline and optional
// params default to null.

/// Route one call through the runtime and decode the recorded/replayed result.
function invoke<T>(
    rt: Runtime,
    exec: Execution,
    connector: string,
    method: string,
    args: json,
) -> T throws PausedForApproval | ReplayDivergence | ConnectorError {
    let value = rt.on_call(exec, connector, method, args);
    baml.json.to<T>(value) catch (e) {
        baml.json.DecodeError => {
            throw ConnectorError { connector: connector, method: method, message: `result did not decode: ${e.message}` }
        },
    }
}

// ───────────────────────────── connector façades ─────────────────────────────

class CrmApi {
    rt: Runtime,
    exec: Execution,
    /// List customers, optionally filtered by plan ("free" | "pro" | "enterprise").
    function list_customers(
        self,
        plan: string? = null,
    ) -> Customer[] throws PausedForApproval | ReplayDivergence | ConnectorError {
        invoke<Customer[]>(self.rt, self.exec, "crm", "list_customers", j({ "plan": plan }))
    }
    /// Fetch one customer by id.
    function get_customer(
        self,
        id: string,
    ) -> Customer throws PausedForApproval | ReplayDivergence | ConnectorError {
        invoke<Customer>(self.rt, self.exec, "crm", "get_customer", j({ "id": id }))
    }
    /// Change a customer's plan. Requires user approval. Reversible.
    function update_plan(
        self,
        id: string,
        plan: string,
    ) -> PlanChange throws PausedForApproval | ReplayDivergence | ConnectorError {
        invoke<PlanChange>(self.rt, self.exec, "crm", "update_plan", j({ "id": id, "plan": plan }))
    }
    /// Append a note to a customer record. Reversible.
    function add_note(
        self,
        id: string,
        note: string,
    ) -> Customer throws PausedForApproval | ReplayDivergence | ConnectorError {
        invoke<Customer>(self.rt, self.exec, "crm", "add_note", j({ "id": id, "note": note }))
    }
    function signatures(self) -> reflect.Signature[] throws never {
        [
            reflect.signature(self.list_customers),
            reflect.signature(self.get_customer),
            reflect.signature(self.update_plan),
            reflect.signature(self.add_note),
        ]
    }
    function types(self) -> reflect.Type[] throws never {
        [reflect.Type.of<Customer>(), reflect.Type.of<PlanChange>()]
    }
}

class BillingApi {
    rt: Runtime,
    exec: Execution,
    /// List invoices, optionally filtered by customer_id and/or status ("open" | "paid" | "overdue" | "refunded").
    function list_invoices(
        self,
        customer_id: string? = null,
        status: string? = null,
    ) -> Invoice[] throws PausedForApproval | ReplayDivergence | ConnectorError {
        invoke<Invoice[]>(
            self.rt,
            self.exec,
            "billing",
            "list_invoices",
            j({ "customer_id": customer_id, "status": status }),
        )
    }
    /// Sum of open + overdue invoices for a customer.
    function get_balance(
        self,
        customer_id: string,
    ) -> Balance throws PausedForApproval | ReplayDivergence | ConnectorError {
        invoke<Balance>(
            self.rt,
            self.exec,
            "billing",
            "get_balance",
            j({ "customer_id": customer_id }),
        )
    }
    /// Refund an invoice in full. Requires user approval. Reversible.
    function issue_refund(
        self,
        invoice_id: string,
        reason: string,
    ) -> Refund throws PausedForApproval | ReplayDivergence | ConnectorError {
        invoke<Refund>(
            self.rt,
            self.exec,
            "billing",
            "issue_refund",
            j({ "invoice_id": invoice_id, "reason": reason }),
        )
    }
    function signatures(self) -> reflect.Signature[] throws never {
        [
            reflect.signature(self.list_invoices),
            reflect.signature(self.get_balance),
            reflect.signature(self.issue_refund),
        ]
    }
    function types(self) -> reflect.Type[] throws never {
        [reflect.Type.of<Invoice>(), reflect.Type.of<Balance>(), reflect.Type.of<Refund>()]
    }
}

class EmailApi {
    rt: Runtime,
    exec: Execution,
    /// Send one email. Requires user approval. NOT reversible.
    function send(
        self,
        to: string,
        subject: string,
        body: string,
    ) -> EmailSent throws PausedForApproval | ReplayDivergence | ConnectorError {
        invoke<EmailSent>(
            self.rt,
            self.exec,
            "email",
            "send",
            j({ "to": to, "subject": subject, "body": body }),
        )
    }
    /// Emails sent so far.
    function list_sent(
        self,
    ) -> SentEmail[] throws PausedForApproval | ReplayDivergence | ConnectorError {
        invoke<SentEmail[]>(self.rt, self.exec, "email", "list_sent", j({}))
    }
    function signatures(self) -> reflect.Signature[] throws never {
        [reflect.signature(self.send), reflect.signature(self.list_sent)]
    }
    function types(self) -> reflect.Type[] throws never {
        [reflect.Type.of<EmailSent>(), reflect.Type.of<SentEmail>()]
    }
}

class GithubApi {
    rt: Runtime,
    exec: Execution,
    /// Pull requests of a public repo (max 10). state: "open" (default) | "closed".
    function list_pull_requests(
        self,
        owner: string,
        repo: string,
        state: string? = null,
    ) -> PullRequest[] throws PausedForApproval | ReplayDivergence | ConnectorError {
        invoke<PullRequest[]>(
            self.rt,
            self.exec,
            "github",
            "list_pull_requests",
            j({ "owner": owner, "repo": repo, "state": state ?? "open" }),
        )
    }
    /// Repository metadata for a public repo.
    function get_repo(
        self,
        owner: string,
        repo: string,
    ) -> Repo throws PausedForApproval | ReplayDivergence | ConnectorError {
        invoke<Repo>(self.rt, self.exec, "github", "get_repo", j({ "owner": owner, "repo": repo }))
    }
    function signatures(self) -> reflect.Signature[] throws never {
        [reflect.signature(self.list_pull_requests), reflect.signature(self.get_repo)]
    }
    function types(self) -> reflect.Type[] throws never {
        [reflect.Type.of<PullRequest>(), reflect.Type.of<Repo>()]
    }
}

class EnvApi {
    rt: Runtime,
    exec: Execution,
    /// Value of an environment variable / secret. If it is not set, the run pauses and the user enters it in the UI. Never print or return it.
    function get(
        self,
        name: string,
    ) -> string throws PausedForApproval | ReplayDivergence | ConnectorError {
        invoke<string>(self.rt, self.exec, "env", "get", j({ "name": name }))
    }
    /// Names of the variables the user has set.
    function names(self) -> string[] throws PausedForApproval | ReplayDivergence | ConnectorError {
        invoke<string[]>(self.rt, self.exec, "env", "names", j({}))
    }
    function signatures(self) -> reflect.Signature[] throws never {
        [reflect.signature(self.get), reflect.signature(self.names)]
    }
    function types(self) -> reflect.Type[] throws never {
        []
    }
}

// ───────────────────────────── the codemode object ─────────────────────────────

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

class Codemode {
    rt: Runtime,
    exec: Execution,
    crm: CrmApi,
    billing: BillingApi,
    email: EmailApi,
    github: GithubApi,
    env: EnvApi,

    /// Find connector methods and saved snippets. Returns ranked paths, not full signatures.
    function search(self, query: string) -> SearchResult throws never {
        let r = self.rt.search(query);
        self.exec.logs.push(`search(${jstr(query)}) → ${r.total} result(s)`);
        for (let h in r.results) {
            self.discover(h.path);
        }
        r
    }
    /// Make this source's functions available to future code as package `name`
    /// (saved when this execution completes). Returns the package alias.
    function publish(self, name: string, description: string) -> string throws never {
        let alias = identifier(name);
        self.exec.publish_as = alias;
        self.exec.publish_description = description;
        self.exec.logs.push(`publish(${jstr(alias)})`);
        alias
    }
    function discover(self, path: string) -> void throws never {
        if (!self.exec.discovered.includes(path)) {
            self.exec.discovered.push(path);
        }
    }
    /// BAML declarations for one connector ("crm"), one method ("crm.update_plan"), a snippet,
    /// or any BAML standard-library path ("baml.fs", "baml.http.fetch") via `baml describe`.
    function describe(self, target: string) -> string throws never {
        if (target.starts_with("baml.") || target.starts_with("reflect.") || target == "baml") {
            self.exec.logs.push(`describe(${jstr(target)}) → stdlib docs`);
            self.discover(target);
            return stdlib_docs(target);
        }
        let text = self.rt.describe(self, target);
        self.exec.logs.push(`describe(${jstr(target)})`);
        let sigs = self.api(target);
        if (sigs.length() > 0) {
            for (let sg in sigs) {
                self.discover(`${target}.${sg.name ?? "?"}`);
            }
        } else {
            self.discover(target);
        }
        text
    }
    /// Record nondeterministic work once; later passes replay the recorded value.
    function step<T>(self, name: string, fn: () -> T throws unknown) -> T throws unknown {
        let recorded = self.rt.step_begin(self.exec, name);
        if (recorded != null) {
            return baml.json.to<T>(recorded);
        }
        let value = fn();
        self.rt.step_end(self.exec, name, j(value));
        value
    }
    /// Run a saved snippet's `run` by name. (Snippets are also importable packages:
    /// `enterprise_names.run(codemode)` is the typed form.) Calls join this execution's log.
    function run(self, name: string, input: json = null) -> json throws unknown {
        let pkg = self.rt.snippet_package(identifier(name));
        if (pkg == null) {
            return j({ "error": `no snippet named ${name}` });
        }
        let f = pkg.get_function<reflect.AnyFunction<Returns = unknown, Throws = unknown>>("run");
        if (f == null) {
            return j({ "error": `snippet ${name} has no run()` });
        }
        self.exec.logs.push(`run(${jstr(name)})`);
        j(call_run(f, self))
    }
    /// The last input passed to codemode.run(), if any (snippets read it here).
    function api(self, connector: string) -> reflect.Signature[] throws never {
        match (connector) {
            "crm" => self.crm.signatures(),
            "billing" => self.billing.signatures(),
            "email" => self.email.signatures(),
            "github" => self.github.signatures(),
            "env" => self.env.signatures(),
            _ => [],
        }
    }
    function api_types(self, connector: string) -> reflect.Type[] throws never {
        match (connector) {
            "crm" => self.crm.types(),
            "billing" => self.billing.types(),
            "email" => self.email.types(),
            "github" => self.github.types(),
            "env" => self.env.types(),
            _ => [],
        }
    }
}

function new_codemode(rt: Runtime, exec: Execution) -> Codemode {
    Codemode {
        rt: rt,
        exec: exec,
        crm: CrmApi { rt: rt, exec: exec },
        billing: BillingApi { rt: rt, exec: exec },
        email: EmailApi { rt: rt, exec: exec },
        github: GithubApi { rt: rt, exec: exec },
        env: EnvApi { rt: rt, exec: exec },
    }
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
    let params = sig.args.map((a) -> {
        `${a.name}: ${a.type.to_string()}`
    });
    for (let k in sig.opts.keys()) {
        let a = sig.opts.get(k);
        if (a != null) {
            params.push(`${a.name}: ${a.type.to_string()} = <default>`);
        }
    }
    let doc = if (sig.docstring != null) {
        `    /// ${sig.docstring ?? ""}\n`
    } else {
        ""
    };
    `${doc}    function ${sig.name ?? "?"}(${params.join(", ")}) -> ${sig.returns.to_string()}`
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
