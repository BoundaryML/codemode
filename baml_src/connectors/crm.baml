// Customer records. An in-memory demo world, seeded below.

class Customer {
    id: string,
    name: string,
    email: string,
    plan: "free" | "pro" | "enterprise",
    notes: string[],
}

class PlanChange {
    id: string,
    previous_plan: string,
    plan: string,
}

class Crm {
    customers: Customer[],
    ctx: Ctx?,

    /// List customers, optionally filtered by plan ("free" | "pro" | "enterprise").
    function list_customers(
        self,
        plan: string? = null,
    ) -> Customer[] throws PausedForApproval | ReplayDivergence | ConnectorError {
        call<Customer[]>(self.ctx, self.list_customers, j({ "plan": plan }), () -> {
            self.customers.filter((c) -> {
                plan == null || c.plan == plan
            })
        })
    }
    /// Fetch one customer by id.
    function get_customer(
        self,
        id: string,
    ) -> Customer throws PausedForApproval | ReplayDivergence | ConnectorError {
        call<Customer>(self.ctx, self.get_customer, j({ "id": id }), () -> {
            self.find(id) ?? throw err(`no customer with id ${id}`)
        })
    }
    /// Change a customer's plan. Requires user approval. Reversible.
    function update_plan(
        self,
        id: string,
        plan: string,
    ) -> PlanChange throws PausedForApproval | ReplayDivergence | ConnectorError {
        call<PlanChange>(self.ctx, self.update_plan, j({ "id": id, "plan": plan }), () -> {
            let c = self.find(id) ?? throw err(`no customer with id ${id}`);
            let previous = c.plan;
            c.plan = as_plan(plan) ?? throw err(`unknown plan ${plan}`);
            PlanChange { id: id, previous_plan: previous, plan: c.plan }
        })
    }
    /// Append a note to a customer record. Reversible.
    function add_note(
        self,
        id: string,
        note: string,
    ) -> Customer throws PausedForApproval | ReplayDivergence | ConnectorError {
        call<Customer>(self.ctx, self.add_note, j({ "id": id, "note": note }), () -> {
            let c = self.find(id) ?? throw err(`no customer with id ${id}`);
            c.notes.push(note);
            c
        })
    }

    function find(self, id: string) -> Customer? throws never {
        self.customers.find((c) -> {
            c.id == id
        })
    }
    function bind(self, rt: Runtime, exec: Execution) -> Crm throws never {
        Crm { customers: self.customers, ctx: bind_ctx(self, rt, exec) }
    }

    implements Connector {
        function name(self) -> string throws never {
            "crm"
        }
        function description(self) -> string throws never {
            "Customer records: who they are and what plan they are on."
        }
        function tools(self) -> Tool[] throws never {
            [
                tool(self.list_customers),
                tool(self.get_customer),
                tool(self.update_plan, approval = true, revert = (args, result) -> {
                    let c = self.find(arg_str(args, "id") ?? "");
                    let previous = as_plan(arg_str(result, "previous_plan") ?? "");
                    if (c == null || previous == null) {
                        return false;
                    }
                    c.plan = previous;
                    true
                }),
                tool(self.add_note, revert = (args, result) -> {
                    let c = self.find(arg_str(args, "id") ?? "");
                    if (c == null) {
                        return false;
                    }
                    c.notes.pop();
                    true
                }),
            ]
        }
        function world(self) -> json throws never {
            j(self.customers)
        }
    }
}

function as_plan(s: string) -> ("free" | "pro" | "enterprise")? throws never {
    match (s) {
        "free" => "free",
        "pro" => "pro",
        "enterprise" => "enterprise",
        _ => null,
    }
}

function seed_crm() -> Crm throws never {
    Crm {
        ctx: null,
        customers: [
            Customer {
                id: "c_1",
                name: "Ada Lovelace",
                email: "ada@analytical.io",
                plan: "pro",
                notes: [],
            },
            Customer {
                id: "c_2",
                name: "Grace Hopper",
                email: "grace@cobol.dev",
                plan: "enterprise",
                notes: [],
            },
            Customer {
                id: "c_3",
                name: "Linus Torvalds",
                email: "linus@kernel.org",
                plan: "pro",
                notes: [],
            },
            Customer {
                id: "c_4",
                name: "Margaret Hamilton",
                email: "margaret@apollo.nasa",
                plan: "free",
                notes: [],
            },
            Customer {
                id: "c_5",
                name: "Ken Thompson",
                email: "ken@bell.labs",
                plan: "pro",
                notes: [],
            },
        ],
    }
}
