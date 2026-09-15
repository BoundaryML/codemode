// The secrets vault. Values live only in the runtime: never in the model's
// context, never in the durable log (re-executed on replay), never sent to the
// browser. A missing value pauses the execution so the user can enter it in the UI.

class Env {
    vars: map<string, string>,
    ctx: Ctx?,

    /// Value of an environment variable / secret. If it is not set, the run pauses and the user enters it in the UI. Never print or return it.
    function get(
        self,
        name: string,
    ) -> string throws PausedForApproval | ReplayDivergence | ConnectorError {
        call<string>(self.ctx, self.get, j({ "name": name }), () -> {
            self.vars.get(name) ?? throw err(`${name} is not set`)
        })
    }
    /// Names of the variables the user has set.
    function names(self) -> string[] throws PausedForApproval | ReplayDivergence | ConnectorError {
        call<string[]>(self.ctx, self.names, j({}), () -> {
            self.vars.keys()
        })
    }

    function bind(self, rt: Runtime, exec: Execution) -> Env throws never {
        Env { vars: self.vars, ctx: bind_ctx(self, rt, exec) }
    }

    implements Connector {
        function name(self) -> string throws never {
            "env"
        }
        function description(self) -> string throws never {
            "Environment variables and secrets managed by the user in the UI. Values are redacted from outputs."
        }
        function tools(self) -> Tool[] throws never {
            [
                tool(self.get, reexecute = true, gate = (args) -> {
                    let name = arg_str(args, "name") ?? "";
                    if (self.vars.has(name)) {
                        null
                    } else {
                        `needs the environment variable ${name}`
                    }
                }),
                tool(self.names),
            ]
        }
        function world(self) -> json throws never {
            j(self.vars.keys())
        }
    }
}
