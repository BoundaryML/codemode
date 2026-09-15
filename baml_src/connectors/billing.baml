// Invoices and refunds. An in-memory demo world, seeded below.

class Invoice {
    id: string,
    customer_id: string,
    amount: float,
    status: "open" | "paid" | "overdue" | "refunded",
    due: string,
}

class Balance {
    customer_id: string,
    balance: float,
}

class Refund {
    invoice_id: string,
    refunded: float,
    previous_status: string,
}

class Billing {
    invoices: Invoice[],
    ctx: Ctx?,

    /// List invoices, optionally filtered by customer_id and/or status ("open" | "paid" | "overdue" | "refunded").
    function list_invoices(
        self,
        customer_id: string? = null,
        status: string? = null,
    ) -> Invoice[] throws PausedForApproval | ReplayDivergence | ConnectorError {
        call<Invoice[]>(self.ctx, self.list_invoices, j({ "customer_id": customer_id, "status": status }), (
        ) -> {
            self.invoices.filter((i) -> {
                (customer_id == null || i.customer_id == customer_id)
                    && (status == null || i.status == status)
            })
        })
    }
    /// Sum of open + overdue invoices for a customer.
    function get_balance(
        self,
        customer_id: string,
    ) -> Balance throws PausedForApproval | ReplayDivergence | ConnectorError {
        call<Balance>(self.ctx, self.get_balance, j({ "customer_id": customer_id }), () -> {
            let due = self.invoices
                .filter((i) -> {
                    i.customer_id == customer_id && (i.status == "open" || i.status == "overdue")
                })
                .reduce(
                    (a, i) -> {
                        a + i.amount
                    },
                    0.0,
                );
            Balance { customer_id: customer_id, balance: due }
        })
    }
    /// Refund an invoice in full. Requires user approval. Reversible.
    function issue_refund(
        self,
        invoice_id: string,
        reason: string,
    ) -> Refund throws PausedForApproval | ReplayDivergence | ConnectorError {
        call<Refund>(self.ctx, self.issue_refund, j({ "invoice_id": invoice_id, "reason": reason }), (
        ) -> {
            let inv = self.find(invoice_id) ?? throw err(`no invoice ${invoice_id}`);
            if (inv.status == "refunded") {
                throw err(`invoice ${invoice_id} is already refunded`);
            }
            let previous = inv.status;
            inv.status = "refunded";
            Refund { invoice_id: invoice_id, refunded: inv.amount, previous_status: previous }
        })
    }

    function find(self, id: string) -> Invoice? throws never {
        self.invoices.find((i) -> {
            i.id == id
        })
    }
    function bind(self, rt: Runtime, exec: Execution) -> Billing throws never {
        Billing { invoices: self.invoices, ctx: bind_ctx(self, rt, exec) }
    }

    implements Connector {
        function name(self) -> string throws never {
            "billing"
        }
        function description(self) -> string throws never {
            "Invoices and refunds."
        }
        function tools(self) -> Tool[] throws never {
            [
                tool(self.list_invoices),
                tool(self.get_balance),
                tool(self.issue_refund, approval = true, revert = (args, result) -> {
                    let inv = self.find(arg_str(args, "invoice_id") ?? "");
                    let previous = as_status(arg_str(result, "previous_status") ?? "");
                    if (inv == null || previous == null) {
                        return false;
                    }
                    inv.status = previous;
                    true
                }),
            ]
        }
        function world(self) -> json throws never {
            j(self.invoices)
        }
    }
}

function as_status(s: string) -> ("open" | "paid" | "overdue" | "refunded")? throws never {
    match (s) {
        "open" => "open",
        "paid" => "paid",
        "overdue" => "overdue",
        "refunded" => "refunded",
        _ => null,
    }
}

function seed_billing() -> Billing throws never {
    Billing {
        ctx: null,
        invoices: [
            Invoice {
                id: "inv_100",
                customer_id: "c_1",
                amount: 1200.0,
                status: "overdue",
                due: "2026-08-01",
            },
            Invoice {
                id: "inv_101",
                customer_id: "c_1",
                amount: 300.0,
                status: "paid",
                due: "2026-07-01",
            },
            Invoice {
                id: "inv_102",
                customer_id: "c_2",
                amount: 9800.0,
                status: "open",
                due: "2026-10-01",
            },
            Invoice {
                id: "inv_103",
                customer_id: "c_3",
                amount: 450.0,
                status: "overdue",
                due: "2026-08-15",
            },
            Invoice {
                id: "inv_104",
                customer_id: "c_4",
                amount: 0.0,
                status: "paid",
                due: "2026-09-01",
            },
            Invoice {
                id: "inv_105",
                customer_id: "c_5",
                amount: 450.0,
                status: "paid",
                due: "2026-09-01",
            },
            Invoice {
                id: "inv_106",
                customer_id: "c_5",
                amount: 450.0,
                status: "overdue",
                due: "2026-08-20",
            },
        ],
    }
}
