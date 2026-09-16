// ─────────────────────────────────────────────────────────────────────────────
// What a connector is.
//
// A connector is one class. Its typed methods are the only definition of its
// API: the model's code calls them directly (`codemode.crm.update_plan(id = …)`),
// `reflect.signature` reads their names, docstrings, and parameter types for
// search/describe/the UI, and each body routes through `call(…)`, where the
// runtime assigns the sequence number and decides: replay, execute, or pause.
//
// Policy (approval, replay, rollback, input gates) is declared once, in
// `tools()`, next to the method it belongs to:
//
//     tool(self.update_plan, approval = true, revert = (args, result) -> { … })
//
// Nothing about a method is written as a string: not its name, not its types.
//
// State lives on the connector instance; `bind` makes a per-execution copy that
// shares it and knows which execution it serves. BAML has no access modifiers,
// so model code could reach that state through the bound instance. That was
// already true of the façades' `rt` field, and model code has the whole stdlib
// anyway: the durable log is a product contract, not a security sandbox.
// ─────────────────────────────────────────────────────────────────────────────

enum ReplayPolicy {
    Record, // store the result, replay it on later passes (default)
    Reexecute, // log seq + args only; run the method again on replay
}

// ── errors that cross from the runtime into model code ──
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

/// A connector body's way to fail. The runtime fills in connector and method.
function err(message: string) -> ConnectorError throws never {
    ConnectorError { connector: "", method: "", message: message }
}

/// Which runtime, execution, and connector a bound instance serves.
class Ctx {
    rt: Runtime,
    exec: Execution,
    connector: string,
}

function bind_ctx(c: Connector, rt: Runtime, exec: Execution) -> Ctx throws never {
    Ctx { rt: rt, exec: exec, connector: c.name() }
}

/// One tool: a typed method plus the policy the runtime applies to it.
class Tool {
    sig: reflect.Signature,
    requires_approval: bool,
    replay: ReplayPolicy,
    /// Undo an applied call, given its recorded args and result. Present = reversible.
    revert: ((json, json) -> bool throws never)?,
    /// A reason to pause for user input before running, or null to proceed.
    gate: ((json) -> string? throws never)?,
    function name(self) -> string throws never {
        self.sig.name ?? "?"
    }
    function description(self) -> string throws never {
        self.sig.docstring ?? ""
    }
    function reversible(self) -> bool throws never {
        self.revert != null
    }
}

/// Declare a tool from a method reference. Name, docstring, and types come from reflection.
function tool(
    f: reflect.AnyFunction,
    approval: bool = false,
    reexecute: bool = false,
    revert: ((json, json) -> bool throws never)? = null,
    gate: ((json) -> string? throws never)? = null,
) -> Tool throws never {
    //# Name, docstring, and types come from the method itself; policy is declared here, once
    Tool {
        sig: reflect.signature(f),
        requires_approval: approval,
        replay: if (reexecute) {
            ReplayPolicy.Reexecute
        } else {
            ReplayPolicy.Record
        },
        revert: revert,
        gate: gate,
    }
}

interface Connector {
    function name(self) -> string throws never;
    function description(self) -> string throws never;
    /// Every callable method with its policy. The runtime, search, describe, and the UI read this.
    function tools(self) -> Tool[] throws never;
    /// A JSON view of the connector's live state, for the demo UI.
    function world(self) -> json throws never {
        null
    }
    /// Pass resources: released after every completed, failed, or paused pass.
    function on_pass_end(self, execution_id: string) -> void throws never {}
    /// Execution resources: released after completion, failure, rejection, or rollback.
    function dispose_execution(self, execution_id: string) -> void throws never {}
}

/// Every typed method body goes through here. `f` is the method itself (for its
/// name), `args` is what gets logged, `run` does the work if the runtime says so.
function call<T>(
    ctx: Ctx?,
    f: reflect.AnyFunction,
    args: json,
    run: () -> T throws ConnectorError,
) -> T throws PausedForApproval | ReplayDivergence | ConnectorError {
    //# Every connector method body enters the runtime here: seq, replay, approval, logging
    let method = reflect.signature(f).name ?? "?";
    if (ctx == null) {
        throw ConnectorError { connector: "?", method: method, message: "connector is not bound to an execution" };
    }
    ctx.rt.call<T>(ctx.exec, ctx.connector, method, args, run)
}

// ───────────────────────── json helpers (never throw) ─────────────────────────

/// Any BAML value → json (null if it has no JSON form).
function j(value: unknown) -> json throws never {
    baml.json.to_json(value) catch_all (e) {
        _ => null
    }
}

/// JSON text → json (null if malformed).
function jparse(s: string) -> json throws never {
    baml.json.parse(s) catch_all (e) {
        _ => null
    }
}

/// Any BAML value → JSON text ("null" if it has no JSON form).
function jstr(value: unknown) -> string throws never {
    baml.json.to_string(value) catch_all (e) {
        _ => "null"
    }
}

/// A string field of logged args or results (for revert and gate closures).
function arg_str(args: json, key: string) -> string? throws never {
    baml.json.path<string>(args, `.${key}`) catch_all (e) {
        _ => null
    }
}
