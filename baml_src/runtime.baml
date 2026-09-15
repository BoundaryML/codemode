// ─────────────────────────────────────────────────────────────────────────────
// Durable Code Mode runtime.
//   * executions + a per-execution log keyed by sequence number
//   * each pass compiles the model's BAML with reflect.Package.compile and runs
//     it in-process; approvals abort the pass with a thrown error and resume by
//     re-running the same code (applied calls replay from the log)
//   * replay-divergence detection, `reexecute` policy, reverse-order rollback,
//     snippets, retention/pruning, and persistence to disk.
// ─────────────────────────────────────────────────────────────────────────────

enum ExecutionStatus {
    Running,
    Paused,
    Completed,
    Error,
    Rejected,
    RolledBack,
}

enum CallState {
    Pending,
    Approved,
    Executing,
    Applied,
    Rejected,
    Reverted,
    RevertFailed,
}

class LogEntry {
    seq: int,
    kind: "call" | "step",
    connector: string,
    method: string,
    args: json,
    state: CallState,
    result: json,
    error: string?,
    replay: ReplayPolicy,
    requires_approval: bool,
    pass: int @description("the pass in which this entry was first recorded"),
    recorded_at: string,
}

class FixRecord {
    attempt: int,
    code: string @description("the source that failed to compile"),
    diagnostics: string,
    thought: string,
}

class Execution {
    id: string,
    task: string,
    code: string,
    status: ExecutionStatus,
    log: LogEntry[],
    result: json,
    error: string?,
    logs: string[],
    connectors: string[],
    pass_count: int,
    cursor: int,
    fix_log: FixRecord[],
    discovered: string[] @description("tool paths the code looked up via search/describe"),
    publish_as: string? @description(
        "set by codemode.publish(): save this source as a tool package on completion",
    ),
    publish_description: string?,
    created_at: string,
    updated_at: string,

    function is_terminal(self) -> bool throws never {
        self.status == ExecutionStatus.Completed
            || self.status == ExecutionStatus.Error
            || self.status == ExecutionStatus.Rejected
            || self.status == ExecutionStatus.RolledBack
    }
    function pending(self) -> LogEntry? throws never {
        self.log.find((e) -> {
            e.state == CallState.Pending
        })
    }
}

class Snippet {
    name: string @description("identifier; the package alias the model imports it as"),
    description: string,
    code: string,
    connectors: string[],
    source_execution_id: string,
    created_at: string,
    api: string? @description("its functions, rendered by reflection"),
}

// ── what the model sees back from the `codemode` tool ──
class PendingAction {
    execution_id: string,
    seq: int,
    connector: string,
    method: string,
    args: json,
}

class Completed {
    status: "completed",
    execution_id: string,
    result: json,
    logs: string[],
}

class Paused {
    status: "paused",
    execution_id: string,
    pending: PendingAction[],
}

class Failed {
    status: "error",
    execution_id: string,
    error: string,
    logs: string[],
}

class RollbackReport {
    execution_id: string,
    status: ExecutionStatus,
    reverted: int,
    failures: string[],
    skipped: string[],
}

class PersistedState {
    executions: Execution[],
    snippets: Snippet[],
}

/// Whoever wants to know when durable state changes (the WebSocket broadcaster).
interface RuntimeListener {
    function on_execution(self, exec: Execution) -> void throws never;
    function on_snippets(self, snippets: Snippet[]) -> void throws never;
    function on_notice(self, exec: Execution, message: string) -> void throws never;
    function on_env(self, names: string[]) -> void throws never;
}

class Runtime {
    name: string,
    root: Registry @description("every connector, unbound; each execution gets a bound copy"),
    executions: Execution[],
    snippets: Snippet[],
    max_executions: int,
    state_path: string,
    next_id: int,
    listeners: RuntimeListener[],
    max_fixes: int,
    packages: map<string, reflect.Package>,
    reference: string @description("BAML language reference text handed to the code generator"),

    // ───────────── lookups ─────────────
    function connectors(self) -> Connector[] throws never {
        self.root.all()
    }
    function connector(self, name: string) -> Connector? throws never {
        self.root.all().find((c) -> {
            c.name() == name
        })
    }
    function tool(self, connector: string, method: string) -> Tool? throws never {
        self.connector(connector)?.tools().find((t) -> {
            t.name() == method
        })
    }
    function env(self) -> Env throws never {
        self.root.env()
    }
    function execution(self, id: string) -> Execution? throws never {
        self.executions.find((e) -> {
            e.id == id
        })
    }
    function snippet(self, name: string) -> Snippet? throws never {
        self.snippets.find((s) -> {
            s.name == name
        })
    }
    function connector_names(self) -> string[] throws never {
        self.root.all().map((c) -> {
            c.name()
        })
    }
    function fresh_id(self, prefix: string) -> string throws never {
        self.next_id += 1;
        let ms = baml.time.Instant.now().to_timestamp_milliseconds().to_string();
        `${prefix}_${ms.slice(ms.length() - 6, ms.length())}${self.next_id}`
    }

    // ───────────── discovery (codemode.search / describe) ─────────────
    function search(self, query: string) -> SearchResult throws never {
        let terms = query.to_lower_case().split(" ").filter((t) -> {
            t.length() > 0
        });
        let hits: SearchHit[] = [];
        for (let c in self.root.all()) {
            for (let t in c.tools()) {
                let path = `${c.name()}.${t.name()}`;
                let hay = `${path} ${t.description()}`.to_lower_case();
                let score = terms.reduce(
                    (acc, term) -> {
                        if (path.to_lower_case().includes(term)) {
                            acc + 3
                        } else if (hay.includes(term)) {
                            acc + 1
                        } else {
                            acc
                        }
                    },
                    0,
                );
                if (score > 0 || terms.length() == 0) {
                    hits.push(
                        SearchHit {
                            path: path,
                            connector: c.name(),
                            method: t.name(),
                            description: t.description(),
                            kind: "method",
                            score: score,
                        },
                    );
                }
            }
        }
        for (let s in self.snippets) {
            let hay = `${s.name} ${s.description}`.to_lower_case();
            let score = terms.reduce(
                (acc, t) -> {
                    if (hay.includes(t)) {
                        acc + 2
                    } else {
                        acc
                    }
                },
                0,
            );
            if (score > 0 || terms.length() == 0) {
                hits.push(
                    SearchHit {
                        path: s.name,
                        connector: "snippet",
                        method: s.name,
                        description: s.description,
                        kind: "snippet",
                        score: score,
                    },
                );
            }
        }
        hits.sort_by_key((h) -> {
            0 - h.score
        });
        let total = hits.length();
        let cap = if (total < 12) {
            total
        } else {
            12
        };
        SearchResult { results: hits.slice(0, cap), total: total, truncated: total > 12 }
    }

    /// BAML declarations for a connector, a method, or a snippet — rendered by reflection.
    function describe(self, target: string) -> string throws never {
        let parts = target.split(".");
        let connector = parts[0];
        let c = self.connector(connector);
        if (c != null) {
            let wanted = if (parts.length() == 2) {
                parts[1]
            } else {
                ""
            };
            if (wanted != "" && self.tool(connector, wanted) == null) {
                return `// ${connector} has no method ${wanted}; try codemode.search()`;
            }
            return render_connector(c, wanted);
        }
        let s = self.snippet(target);
        if (s != null) {
            return `// ${s.description}\n// connectors: ${s.connectors.join(", ")}\n${s.api ?? ""}`;
        }
        `// unknown target ${target}; try codemode.search()`
    }

    // ───────────── lifecycle ─────────────
    function create(self, code: string, task: string) -> Execution throws never {
        //# New execution: insert first, then prune older terminal runs
        let now = baml.time.Instant.now().to_string();
        let exec = Execution {
            id: self.fresh_id("exec"),
            task: task,
            code: code,
            status: ExecutionStatus.Running,
            log: [],
            result: null,
            error: null,
            logs: [],
            connectors: self.connector_names(),
            pass_count: 0,
            cursor: 0,
            fix_log: [],
            discovered: [],
            publish_as: null,
            publish_description: null,
            created_at: now,
            updated_at: now,
        };
        self.executions.push(exec);
        self.prune_executions();
        self.persist();
        self.notify(exec);
        exec
    }

    /// Compile and run the execution's code once. Returns when the code
    /// completes, fails, or pauses for approval.
    function run_pass(self, exec: Execution) -> Completed | Paused | Failed throws never {
        if (exec.status != ExecutionStatus.Running && exec.status != ExecutionStatus.Paused) {
            return Failed {
                status: "error",
                execution_id: exec.id,
                error: `cannot run an execution in status ${exec.status}`,
                logs: exec.logs,
            };
        }
        if (exec.pending() != null) {
            return Failed {
                status: "error",
                execution_id: exec.id,
                error: "execution is waiting for approval",
                logs: exec.logs,
            };
        }
        //# Every pass re-runs the same code from the top; applied calls replay from the log
        exec.status = ExecutionStatus.Running;
        exec.cursor = 0;
        exec.pass_count += 1;
        exec.updated_at = baml.time.Instant.now().to_string();
        self.persist();
        self.notify(exec);
        defer {
            for (let c in self.root.all()) {
                c.on_pass_end(exec.id);
            }
        }
        //# Compile the model's BAML against this package (aliased `host`) plus every
        //# saved snippet as its own package. If it does not compile, ask the model to
        //# fix it in a tight inner loop instead of spending a whole agent turn.
        let compiled: reflect.AnyFunction<Returns = unknown, Throws = unknown>? = null;
        let attempt = 0;
        while (compiled == null) {
            compiled
                = compile_run(exec.code, self.snippet_packages(exec)) catch (e) {
                    reflect.errors.CompilationError => {
                        let details = render_diagnostics(e);
                        if (attempt >= self.max_fixes) {
                            let message = `compile error after ${attempt} fix attempt(s): ${details}`;
                            self.finish(exec, ExecutionStatus.Error, message);
                            return Failed {
                                status: "error",
                                execution_id: exec.id,
                                error: message,
                                logs: exec.logs,
                            };
                        }
                        attempt += 1;
                        self.notice(
                            exec,
                            `didn't compile: ${e.diagnostics.length()} diagnostic(s). Asking the model to fix it (attempt ${attempt}/${self.max_fixes})`,
                        );
                        let hints = self.connector_names()
                            .map((c) -> {
                                self.describe(c)
                            })
                            .join("\n\n");
                        let fix = FixCode(exec.code, details, self.connector_names(), hints, self.reference) catch_all (err, ctx) {
                            _ => {
                                let message = `compile error: ${details}\n(auto-fix failed: ${ctx.to_string()})`;
                                self.finish(exec, ExecutionStatus.Error, message);
                                return Failed {
                                    status: "error",
                                    execution_id: exec.id,
                                    error: message,
                                    logs: exec.logs,
                                };
                            }
                        };
                        exec.fix_log.push(
                            FixRecord {
                                attempt: attempt,
                                code: exec.code,
                                diagnostics: details,
                                thought: fix.thought,
                            },
                        );
                        exec.code = fix.code;
                        exec.updated_at = baml.time.Instant.now().to_string();
                        self.notice(exec, `fix ${attempt}: ${fix.thought}`);
                        self.persist();
                        self.notify(exec);
                        null
                    },
                };
        }
        if (compiled == null) {
            return Failed {
                status: "error",
                execution_id: exec.id,
                error: "no compiled function",
                logs: exec.logs,
            };
        }
        let run = compiled;
        let codemode = new_codemode(self, exec);
        //# Run in a green thread so panics are captured too
        let settled = await baml.future.all_settled([spawn { call_run(run, codemode) }]);
        match (settled[0]) {
            let s: baml.future.Success<unknown> => {
                //# Whatever the code returned (a class it defined, a list, a string) becomes JSON
                exec.result = j(s.value);
                self.finish(exec, ExecutionStatus.Completed, null);
                let result = exec.result;
                //# codemode.publish(): the source becomes a tool package other code can import
                let alias = exec.publish_as;
                if (alias != null) {
                    let saved = self.save_snippet(alias, exec.publish_description ?? exec.task, exec.id);
                    if (saved == null) {
                        self.notice(exec, `could not publish tool ${alias}`);
                    } else {
                        self.notice(exec, `published tool "${alias}": ${saved.api ?? ""}`);
                    }
                }
                Completed {
                    status: "completed",
                    execution_id: exec.id,
                    result: result,
                    logs: exec.logs,
                }
            },
            let f: baml.future.Failure<unknown> => {
                match (f.error) {
                    let p: PausedForApproval => {
                        //# The pass aborted at an approval point; the execution stays Paused
                        Paused { status: "paused", execution_id: exec.id, pending: [p.pending] }
                    },
                    let d: ReplayDivergence => {
                        Failed {
                            status: "error",
                            execution_id: exec.id,
                            error: d.message,
                            logs: exec.logs,
                        }
                    },
                    let c: ConnectorError => {
                        let message = `uncaught connector error from ${c.connector}.${c.method}: ${c.message}`;
                        self.finish(exec, ExecutionStatus.Error, message);
                        Failed {
                            status: "error",
                            execution_id: exec.id,
                            error: message,
                            logs: exec.logs,
                        }
                    },
                    _ => {
                        let message = `runtime error: ${f.error}`;
                        self.finish(exec, ExecutionStatus.Error, message);
                        Failed {
                            status: "error",
                            execution_id: exec.id,
                            error: message,
                            logs: exec.logs,
                        }
                    },
                }
            },
            baml.future.Panicked => {
                let message = "the code panicked (out-of-bounds index, missing map key, or division by zero)";
                self.finish(exec, ExecutionStatus.Error, message);
                Failed { status: "error", execution_id: exec.id, error: message, logs: exec.logs }
            },
        }
    }

    /// Approve the pending action and run another pass.
    function approve(self, execution_id: string) -> Completed | Paused | Failed throws never {
        let exec = self.execution(execution_id);
        if (exec == null) {
            return Failed {
                status: "error",
                execution_id: execution_id,
                error: "unknown execution",
                logs: [],
            };
        }
        if (exec.status != ExecutionStatus.Paused) {
            return Failed {
                status: "error",
                execution_id: exec.id,
                error: `cannot resume an execution in status ${exec.status}`,
                logs: exec.logs,
            };
        }
        let p = exec.pending();
        if (p == null) {
            return Failed {
                status: "error",
                execution_id: exec.id,
                error: "nothing pending",
                logs: exec.logs,
            };
        }
        //# Only a paused execution can resume; the approved call executes when the re-run reaches it
        p.state = CallState.Approved;
        self.notify(exec);
        self.run_pass(exec)
    }

    /// Reject the pending action. Ends the execution; earlier actions stay applied.
    function reject(self, execution_id: string) -> Completed | Paused | Failed throws never {
        let exec = self.execution(execution_id);
        if (exec == null) {
            return Failed {
                status: "error",
                execution_id: execution_id,
                error: "unknown execution",
                logs: [],
            };
        }
        if (exec.status != ExecutionStatus.Paused) {
            return Failed {
                status: "error",
                execution_id: exec.id,
                error: `cannot reject an execution in status ${exec.status}`,
                logs: exec.logs,
            };
        }
        let p = exec.pending();
        let what = if (p != null) {
            p.state = CallState.Rejected;
            `${p.connector}.${p.method}`
        } else {
            "action"
        };
        self.finish(exec, ExecutionStatus.Rejected, `user rejected ${what}`);
        Failed {
            status: "error",
            execution_id: exec.id,
            error: `user rejected ${what}. Earlier calls in this execution stayed applied. Do not retry it.`,
            logs: exec.logs,
        }
    }

    /// Compensation: walk applied calls in reverse and invoke each connector's revert.
    function rollback(self, execution_id: string) -> RollbackReport throws never {
        let exec = self.execution(execution_id);
        if (exec == null) {
            return RollbackReport {
                execution_id: execution_id,
                status: ExecutionStatus.Error,
                reverted: 0,
                failures: ["unknown execution"],
                skipped: [],
            };
        }
        if (!exec.is_terminal()) {
            return RollbackReport {
                execution_id: exec.id,
                status: exec.status,
                reverted: 0,
                failures: ["cannot roll back a nonterminal execution"],
                skipped: [],
            };
        }
        let reverted = 0;
        let failures: string[] = [];
        let skipped: string[] = [];
        //# Reverse order: undo the last effect first
        for (let e in exec.log.reverse()) {
            if (e.kind != "call" || e.state != CallState.Applied || e.error != null) {
                continue;
            }
            let c = self.connector(e.connector);
            if (c == null) {
                skipped.push(`#${e.seq} ${e.connector}.${e.method}: connector unavailable`);
                continue;
            }
            let t = self.tool(e.connector, e.method);
            if (t == null) {
                skipped.push(`#${e.seq} ${e.connector}.${e.method}: unknown method`);
                continue;
            }
            let revert = t.revert;
            if (revert == null) {
                skipped.push(`#${e.seq} ${e.connector}.${e.method}: no revert`);
                continue;
            }
            if (revert(e.args, e.result)) {
                e.state = CallState.Reverted;
                reverted += 1;
            } else {
                e.state = CallState.RevertFailed;
                failures.push(`#${e.seq} ${e.connector}.${e.method}`);
            }
        }
        if (reverted > 0) {
            exec.status = ExecutionStatus.RolledBack;
        }
        exec.updated_at = baml.time.Instant.now().to_string();
        for (let c in self.root.all()) {
            c.dispose_execution(exec.id);
        }
        self.persist();
        self.notify(exec);
        RollbackReport {
            execution_id: exec.id,
            status: exec.status,
            reverted: reverted,
            failures: failures,
            skipped: skipped,
        }
    }

    function save_snippet(
        self,
        raw_name: string,
        description: string,
        execution_id: string,
    ) -> Snippet? throws never {
        let exec = self.execution(execution_id);
        if (exec == null) {
            return null;
        }
        let name = identifier(raw_name);
        if (exec.status != ExecutionStatus.Completed || name.length() == 0) {
            return null;
        }
        //# A snippet is a package: compile it once so its functions are typed and discoverable
        let pkg = compile_package(exec.code, {}) catch_all (e) {
            _ => {
                return null;
            }
        };
        self.packages.set(name, pkg);
        self.snippets
            = self.snippets.filter((s) -> {
                s.name != name
            });
        let s = Snippet {
            name: name,
            description: description,
            code: exec.code,
            connectors: exec.connectors,
            source_execution_id: exec.id,
            created_at: baml.time.Instant.now().to_string(),
            api: render_package_api(name, pkg),
        };
        self.snippets.push(s);
        self.persist();
        self.notify_snippets();
        s
    }

    /// Remove a saved tool. Executions that used it keep their logs; new code can no longer import it.
    function delete_snippet(self, name: string) -> bool throws never {
        let before = self.snippets.length();
        self.snippets
            = self.snippets.filter((s) -> {
                s.name != name
            });
        if (self.snippets.length() == before) {
            return false;
        }
        self.packages.delete(name);
        self.persist();
        self.notify_snippets();
        true
    }

    /// The compiled package for a snippet (compiled lazily after a restart).
    function snippet_package(self, name: string) -> reflect.Package? throws never {
        let cached = self.packages.get(name);
        if (cached != null) {
            return cached;
        }
        let s = self.snippet(name);
        if (s == null) {
            return null;
        }
        let pkg = compile_package(s.code, {}) catch_all (e) {
            _ => {
                return null;
            }
        };
        self.packages.set(name, pkg);
        pkg
    }

    /// Every snippet whose connectors are available, as dependency packages for a compile.
    function snippet_packages(self, exec: Execution) -> map<string, reflect.Package> throws never {
        let deps: map<string, reflect.Package> = {};
        for (let s in self.snippets) {
            let available = exec.connectors;
            let ok = s.connectors.every((c) -> {
                available.includes(c)
            });
            if (!ok) {
                continue;
            }
            if (exec.publish_as == s.name) {
                continue;
            }
            let pkg = self.snippet_package(s.name);
            if (pkg == null) {
                self.notice(exec, `snippet ${s.name} no longer compiles; not imported`);
                continue;
            }
            deps.set(s.name, pkg);
        }
        deps
    }

    /// Retention: keep at most `max_executions` terminal records.
    function prune_executions(self) -> int throws never {
        let terminal = self.executions.filter((e) -> {
            e.is_terminal()
        });
        let excess = terminal.length() - self.max_executions;
        if (excess <= 0) {
            return 0;
        }
        let doomed = terminal.slice(0, excess).map((e) -> {
            e.id
        });
        self.executions
            = self.executions.filter((e) -> {
                !doomed.includes(e.id)
            });
        excess
    }

    /// Maintenance: stale paused runs become Rejected, stale running runs become Error.
    function expire_paused(self, max_age_seconds: int) -> int throws never {
        let now = baml.time.Instant.now();
        let n = 0;
        for (let e in self.executions) {
            if (e.is_terminal()) {
                continue;
            }
            let age = (
                baml.time.Instant.parse(e.updated_at) catch_all (err) {
                    _ => now
                }
            )
                .elapsed()
                .to_seconds()
                .to_int() catch_all (err) {
                _ => 0
            };
            if (age < max_age_seconds) {
                continue;
            }
            if (e.status == ExecutionStatus.Paused) {
                self.finish(e, ExecutionStatus.Rejected, "expired while waiting for approval");
            } else {
                self.finish(e, ExecutionStatus.Error, "host stopped mid-pass; execution expired");
            }
            n += 1;
        }
        n
    }

    /// Replace every stored secret value with «ENV:NAME».
    function scrub(self, text: string) -> string throws never {
        let out = text;
        for (let k in self.env().vars.keys()) {
            let v = self.env().vars.get(k) ?? "";
            if (v.length() >= 4) {
                out = out.replace_all(v, `«ENV:${k}»`);
            }
        }
        out
    }
    function scrub_json(self, value: json) -> json throws never {
        if (self.env().vars.length() == 0) {
            return value;
        }
        jparse(self.scrub(jstr(value)))
    }

    // ───────────── env vault ─────────────
    function set_env(self, name: string, value: string) -> void throws never {
        self.env().vars.set(name, value);
        self.persist_env();
        for (let l in self.listeners) {
            l.on_env(self.env().vars.keys());
        }
    }
    function delete_env(self, name: string) -> bool throws never {
        let had = self.env().vars.delete(name) != null;
        self.persist_env();
        for (let l in self.listeners) {
            l.on_env(self.env().vars.keys());
        }
        had
    }
    function persist_env(self) -> void throws never {
        baml.fs.write(".codemode/env.json", jstr(self.env().vars)) catch_all (e) {
            _ => {
                log.warn(`could not persist env: ${e}`);
                0
            }
        };
        baml.fs.chmod(".codemode/env.json", 384) catch_all (e) {
            _ => null
        };
    }
    function load_env(self) -> void throws never {
        if (
            !(
                baml.fs.exists(".codemode/env.json") catch_all (e) {
                    _ => false
                }
            )
        ) {
            return;
        }
        let text = baml.fs.read(".codemode/env.json") catch_all (e) {
            _ => "{}"
        };
        let empty: map<string, string> = {};
        self.env().vars
            = baml.json.from_string<map<string, string>>(text) catch_all (e) {
                _ => empty
            };
    }

    function finish(
        self,
        exec: Execution,
        status: ExecutionStatus,
        error: string?,
    ) -> void throws never {
        exec.status = status;
        exec.error
            = if (error == null) {
                null
            } else {
                self.scrub(error ?? "")
            };
        exec.result = self.scrub_json(exec.result);
        exec.logs
            = exec.logs.map((l) -> {
                self.scrub(l)
            });
        exec.updated_at = baml.time.Instant.now().to_string();
        for (let c in self.root.all()) {
            c.dispose_execution(exec.id);
        }
        self.persist();
        self.notify(exec);
    }

    // ───────────── the interception point ─────────────
    // A connector's typed method calls this (via `call` in connectors/connector.baml)
    // with a closure that does the work. The runtime assigns the sequence number
    // and decides: replay from the log, run the closure, or pause for the user.

    function call<T>(
        self,
        exec: Execution,
        connector: string,
        method: string,
        args: json,
        run: () -> T throws ConnectorError,
    ) -> T throws PausedForApproval | ReplayDivergence | ConnectorError {
        if (exec.status != ExecutionStatus.Running) {
            throw ConnectorError { connector: connector, method: method, message: `execution is ${exec.status}, not running` };
        }
        let seq = exec.cursor;
        let recorded = exec.log.at(seq);
        if (recorded == null) {
            //# First time this seq is reached: record it
            let t = self.tool(connector, method);
            if (t == null) {
                throw ConnectorError { connector: connector, method: method, message: `unknown method ${connector}.${method}; use codemode.search()` };
            }
            //# A tool may also ask for user input (env: a missing variable)
            let gate = t.gate;
            let reason = if (gate == null) {
                null
            } else {
                gate(args)
            };
            let needs_user = t.requires_approval || reason != null;
            let entry = LogEntry {
                seq: seq,
                kind: "call",
                connector: connector,
                method: method,
                args: args,
                state: if (needs_user) {
                    CallState.Pending
                } else {
                    CallState.Executing
                },
                result: null,
                error: null,
                replay: t.replay,
                requires_approval: t.requires_approval,
                pass: exec.pass_count,
                recorded_at: baml.time.Instant.now().to_string(),
            };
            exec.log.push(entry);
            exec.cursor += 1;
            if (needs_user) {
                //# Approval or input required: record as pending and abort this pass
                if (reason != null) {
                    self.notice(exec, `paused: ${reason ?? ""}`);
                }
                self.pause(exec, entry);
            }
            return self.invoke<T>(exec, entry, run);
        }
        //# Replay: the log must match connector/method/args at this seq
        if (
            recorded.kind != "call"
                || recorded.connector != connector
                || recorded.method != method
                || recorded.args != args
        ) {
            self.diverged(exec, seq, `${connector}.${method}(${jstr(args)})`, recorded);
        }
        exec.cursor += 1;
        match (recorded.state) {
            CallState.Applied => {
                if (recorded.replay == ReplayPolicy.Reexecute) {
                    //# reexecute policy: nothing stored, run the read again
                    return self.invoke<T>(exec, recorded, run);
                }
                exec.logs.push(`#${seq} ${connector}.${method} replayed from log`);
                if (recorded.error != null) {
                    throw ConnectorError { connector: connector, method: method, message: recorded.error ?? "" };
                }
                baml.json.to<T>(recorded.result) catch (e) {
                    baml.json.DecodeError => {
                        throw ConnectorError { connector: connector, method: method, message: `logged result did not decode: ${e.message}` };
                    },
                }
            },
            CallState.Approved => {
                //# The user approved exactly this action: execute it now
                self.invoke<T>(exec, recorded, run)
            },
            CallState.Pending => self.pause(exec, recorded),
            _ => {
                throw ConnectorError { connector: connector, method: method, message: `log entry #${seq} is ${recorded.state} and cannot be replayed` };
            },
        }
    }

    /// codemode.step(): the recorded value at the cursor, or null after recording a new step.
    function step_begin(
        self,
        exec: Execution,
        name: string,
    ) -> json throws PausedForApproval | ReplayDivergence | ConnectorError {
        let seq = exec.cursor;
        let recorded = exec.log.at(seq);
        if (recorded != null) {
            if (recorded.kind != "step" || recorded.method != name) {
                self.diverged(exec, seq, `step "${name}"`, recorded);
            }
            exec.cursor += 1;
            exec.logs.push(`#${seq} step "${name}" replayed from log`);
            return recorded.result;
        }
        exec.log.push(
            LogEntry {
                seq: seq,
                kind: "step",
                connector: "codemode",
                method: name,
                args: null,
                state: CallState.Executing,
                result: null,
                error: null,
                replay: ReplayPolicy.Record,
                requires_approval: false,
                pass: exec.pass_count,
                recorded_at: baml.time.Instant.now().to_string(),
            },
        );
        exec.cursor += 1;
        null
    }
    function step_end(self, exec: Execution, name: string, value: json) -> void throws never {
        let entry = exec.log.find_last((e) -> {
            e.kind == "step" && e.method == name && e.state == CallState.Executing
        });
        if (entry != null) {
            entry.result = value;
            entry.state = CallState.Applied;
        }
        self.persist();
        self.notify(exec);
    }

    function invoke<T>(
        self,
        exec: Execution,
        entry: LogEntry,
        run: () -> T throws ConnectorError,
    ) -> T throws ConnectorError {
        entry.state = CallState.Executing;
        let value = run() catch (e) {
            ConnectorError => {
                entry.state = CallState.Applied;
                entry.error = e.message;
                entry.result = null;
                self.persist();
                self.notify(exec);
                throw ConnectorError { connector: entry.connector, method: entry.method, message: e.message };
            },
        };
        entry.state = CallState.Applied;
        entry.error = null;
        entry.result
            = if (entry.replay == ReplayPolicy.Reexecute) {
                null
            } else {
                j(value)
            };
        self.persist();
        self.notify(exec);
        value
    }

    function pause(self, exec: Execution, entry: LogEntry) -> never throws PausedForApproval {
        exec.status = ExecutionStatus.Paused;
        exec.updated_at = baml.time.Instant.now().to_string();
        self.persist();
        self.notify(exec);
        throw PausedForApproval {
            pending: PendingAction { execution_id: exec.id, seq: entry.seq, connector: entry.connector, method: entry.method, args: entry.args },
        }
    }

    function diverged(
        self,
        exec: Execution,
        seq: int,
        got: string,
        recorded: LogEntry,
    ) -> never throws ReplayDivergence {
        let expected = if (recorded.kind == "step") {
            `step "${recorded.method}"`
        } else {
            `${recorded.connector}.${recorded.method}(${jstr(recorded.args)})`
        };
        let message = `replay divergence at #${seq}: expected ${expected}, got ${got}. Connector calls must happen in the same order with the same arguments on every pass; wrap nondeterministic work in codemode.step().`;
        self.finish(exec, ExecutionStatus.Error, message);
        throw ReplayDivergence { message: message }
    }

    // ───────────── change notification ─────────────
    function notify(self, exec: Execution) -> void throws never {
        for (let l in self.listeners) {
            l.on_execution(exec);
        }
    }
    /// Something the user should see right now (compile failures, auto-fixes).
    function notice(self, exec: Execution, message: string) -> void throws never {
        exec.logs.push(`• ${message}`);
        for (let l in self.listeners) {
            l.on_notice(exec, message);
        }
    }
    function notify_snippets(self) -> void throws never {
        for (let l in self.listeners) {
            l.on_snippets(self.snippets);
        }
    }

    // ───────────── persistence (survives restarts, like a DO facet) ─────────────
    function persist(self) -> void throws never {
        let state = PersistedState { executions: self.executions, snippets: self.snippets };
        baml.fs.write(self.state_path, jstr(state)) catch_all (e) {
            _ => {
                log.warn(`could not persist runtime state: ${e}`);
                0
            }
        };
    }
    function load(self) -> void throws never {
        if (
            !(
                baml.fs.exists(self.state_path) catch_all (e) {
                    _ => false
                }
            )
        ) {
            return;
        }
        let text = baml.fs.read(self.state_path) catch_all (e) {
            _ => ""
        };
        let state = baml.json.from_string<PersistedState>(text) catch_all (e) {
            _ => {
                log.warn(`ignoring unreadable state file: ${e}`);
                PersistedState { executions: [], snippets: [] }
            }
        };
        self.executions = state.executions;
        self.snippets = state.snippets;
        //# Anything left Running when the host died is now stale
        for (let e in self.executions) {
            if (e.status == ExecutionStatus.Running) {
                e.status = ExecutionStatus.Error;
                e.error = "host restarted mid-pass";
            }
        }
    }
}

function create_runtime(
    root: Registry = default_connectors(),
    name: string = "default",
    max_executions: int = 50,
) -> Runtime {
    let rt = Runtime {
        name: name,
        root: root,
        executions: [],
        snippets: [],
        max_executions: max_executions,
        state_path: `.codemode/${name}.json`,
        next_id: 0,
        listeners: [],
        max_fixes: 3,
        packages: {},
        reference: "",
    };
    rt.load();
    rt.load_env();
    rt
}

/// Turn any label into a BAML identifier (snippets are imported by this name).
function identifier(raw: string) -> string {
    let cleaned = raw.trim()
        .to_lower_case()
        .chars()
        .map((ch) -> {
            if (ch.is_ascii_alphanumeric()) {
                ch
            } else {
                "_"
            }
        })
        .join("");
    if (cleaned.length() > 0 && cleaned.at(0)?.is_ascii_numeric() == true) {
        `s_${cleaned}`
    } else {
        cleaned
    }
}

function render_diagnostics(e: reflect.errors.CompilationError) -> string {
    let details = e.diagnostics.map((d) -> {
        let where = if let sp: reflect.Span = d.span {
            ` (at offset ${sp.start})`
        } else {
            ""
        };
        `${d.code}${where}: ${d.message}`
    });
    if (details.length() == 0) {
        e.message
    } else {
        details.join("\n")
    }
}
