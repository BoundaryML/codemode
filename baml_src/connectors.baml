// ─────────────────────────────────────────────────────────────────────────────
// Connectors: host-side services exposed to the sandbox as globals.
// The generated code never sees credentials or client objects; every call
// crosses the sandbox boundary as an RPC that the runtime intercepts.
// ─────────────────────────────────────────────────────────────────────────────

enum ReplayPolicy {
    Record, // store the result, replay it on later passes (default)
    Reexecute, // log seq + args only; run the method again on replay
}

class MethodSpec {
    connector: string,
    name: string,
    description: string,
    requires_approval: bool,
    replay: ReplayPolicy,
    reversible: bool,
    function path(self) -> string {
        `${self.connector}.${self.name}`
    }
}

class CallResult {
    ok: bool,
    value: json,
    error: string?,
}

function ok(value: json) -> CallResult {
    CallResult { ok: true, value: value, error: null }
}

function fail(message: string) -> CallResult {
    CallResult { ok: false, value: null, error: message }
}

interface Connector {
    function name(self) -> string throws never;
    function description(self) -> string throws never;
    function methods(self) -> MethodSpec[] throws never;
    function call(
        self,
        method: string,
        args: json,
        execution_id: string,
    ) -> CallResult throws never;
    /// Should this call pause for user input even though the method needs no approval?
    /// (The env connector pauses when a variable is missing.)
    function gate(self, method: string, args: json) -> string? throws never {
        null
    }
    /// Compensate an applied call. Return true if reverted.
    function revert(
        self,
        method: string,
        args: json,
        result: json,
        execution_id: string,
    ) -> bool throws never {
        false
    }
    /// Pass resources: released after every completed, failed, or paused pass.
    function on_pass_end(self, execution_id: string) -> void throws never {}
    /// Execution resources: released after completion, failure, rejection, or rollback.
    function dispose_execution(self, execution_id: string) -> void throws never {}
    /// A JSON view of the connector's live state, for the demo UI.
    function world(self) -> json throws never {
        null
    }
}

function spec(
    connector: string,
    name: string,
    description: string,
    requires_approval: bool = false,
    replay: ReplayPolicy = ReplayPolicy.Record,
    reversible: bool = false,
) -> MethodSpec {
    MethodSpec {
        connector: connector,
        name: name,
        description: description,
        requires_approval: requires_approval,
        replay: replay,
        reversible: reversible,
    }
}

function arg_str(args: json, key: string) -> string? {
    baml.json.path<string>(args, `.${key}`) catch (e) {
        baml.json.PathError => null
    }
}

function arg_int(args: json, key: string) -> int? {
    baml.json.path<int>(args, `.${key}`) catch (e) {
        baml.json.PathError => null
    }
}

// ── typed results the connectors return (and the model's code receives) ──
class PlanChange {
    id: string,
    previous_plan: string,
    plan: string,
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

class EmailSent {
    ok: bool,
    to: string,
}

class PullRequest {
    number: int,
    title: string,
    user: string,
    url: string,
    updated_at: string,
}

class Repo {
    full_name: string,
    description: string,
    stars: int,
    open_issues: int,
}

// ───────────────────────────── crm ─────────────────────────────

class Customer {
    id: string,
    name: string,
    email: string,
    plan: "free" | "pro" | "enterprise",
    notes: string[],
}

class Crm {
    customers: Customer[],
    implements Connector {
        function name(self) -> string throws never {
            "crm"
        }
        function description(self) -> string throws never {
            "Customer records: who they are and what plan they are on."
        }
        function methods(self) -> MethodSpec[] throws never {
            [
                spec("crm", "list_customers", "List customers, optionally filtered by plan."),
                spec("crm", "get_customer", "Fetch one customer by id."),
                spec(
                    "crm",
                    "update_plan",
                    "Change a customer's plan. Requires user approval. Reversible.",
                    requires_approval = true,
                    reversible = true,
                ),
                spec(
                    "crm",
                    "add_note",
                    "Append a note to a customer record. Reversible.",
                    reversible = true,
                ),
            ]
        }
        function call(
            self,
            method: string,
            args: json,
            execution_id: string,
        ) -> CallResult throws never {
            match (method) {
                "list_customers" => {
                    let plan = arg_str(args, "plan");
                    let rows = self.customers.filter((c) -> {
                        plan == null || c.plan == plan
                    });
                    ok(j(rows))
                },
                "get_customer" => {
                    let id = arg_str(args, "id") ?? "";
                    let c = self.customers.find((c) -> {
                        c.id == id
                    });
                    if (c == null) {
                        fail(`no customer with id ${id}`)
                    } else {
                        ok(j(c))
                    }
                },
                "update_plan" => {
                    let id = arg_str(args, "id") ?? "";
                    let plan = arg_str(args, "plan") ?? "";
                    let c = self.customers.find((c) -> {
                        c.id == id
                    });
                    if (c == null) {
                        return fail(`no customer with id ${id}`);
                    }
                    let previous = c.plan;
                    c.plan
                        = match (plan) {
                            "free" => "free",
                            "pro" => "pro",
                            "enterprise" => "enterprise",
                            _ => c.plan,
                        };
                    ok(j(PlanChange { id: id, previous_plan: previous, plan: c.plan }))
                },
                "add_note" => {
                    let id = arg_str(args, "id") ?? "";
                    let note = arg_str(args, "note") ?? "";
                    let c = self.customers.find((c) -> {
                        c.id == id
                    });
                    if (c == null) {
                        return fail(`no customer with id ${id}`);
                    }
                    c.notes.push(note);
                    ok(j(c))
                },
                _ => fail(`crm has no method ${method}`),
            }
        }
        function revert(
            self,
            method: string,
            args: json,
            result: json,
            execution_id: string,
        ) -> bool {
            match (method) {
                "update_plan" => {
                    let id = arg_str(args, "id") ?? "";
                    let previous = arg_str(result, "previous_plan") ?? "";
                    let c = self.customers.find((c) -> {
                        c.id == id
                    });
                    if (c == null) {
                        return false;
                    }
                    c.plan
                        = match (previous) {
                            "free" => "free",
                            "pro" => "pro",
                            "enterprise" => "enterprise",
                            _ => c.plan,
                        };
                    true
                },
                "add_note" => {
                    let id = arg_str(args, "id") ?? "";
                    let c = self.customers.find((c) -> {
                        c.id == id
                    });
                    if (c == null) {
                        return false;
                    }
                    c.notes.pop();
                    true
                },
                _ => false,
            }
        }
        function world(self) -> json throws never {
            j(self.customers)
        }
    }
}

function seed_crm() -> Crm {
    Crm {
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

// ──────────────────────────── billing ────────────────────────────

class Invoice {
    id: string,
    customer_id: string,
    amount: float,
    status: "open" | "paid" | "overdue" | "refunded",
    due: string,
}

class Billing {
    invoices: Invoice[],
    implements Connector {
        function name(self) -> string throws never {
            "billing"
        }
        function description(self) -> string throws never {
            "Invoices and refunds."
        }
        function methods(self) -> MethodSpec[] throws never {
            [
                spec(
                    "billing",
                    "list_invoices",
                    "List invoices, optionally filtered by customer_id and/or status.",
                ),
                spec("billing", "get_balance", "Sum of open + overdue invoices for a customer."),
                spec(
                    "billing",
                    "issue_refund",
                    "Refund an invoice in full. Requires user approval. Reversible.",
                    requires_approval = true,
                    reversible = true,
                ),
            ]
        }
        function call(
            self,
            method: string,
            args: json,
            execution_id: string,
        ) -> CallResult throws never {
            match (method) {
                "list_invoices" => {
                    let cid = arg_str(args, "customer_id");
                    let status = arg_str(args, "status");
                    let rows = self.invoices.filter((i) -> {
                        (cid == null || i.customer_id == cid)
                            && (status == null || i.status == status)
                    });
                    ok(j(rows))
                },
                "get_balance" => {
                    let cid = arg_str(args, "customer_id") ?? "";
                    let bal = self.invoices
                        .filter((i) -> {
                            i.customer_id == cid && (i.status == "open" || i.status == "overdue")
                        })
                        .reduce(
                            (a, i) -> {
                                a + i.amount
                            },
                            0.0,
                        );
                    ok(j(Balance { customer_id: cid, balance: bal }))
                },
                "issue_refund" => {
                    let id = arg_str(args, "invoice_id") ?? "";
                    let inv = self.invoices.find((i) -> {
                        i.id == id
                    });
                    if (inv == null) {
                        return fail(`no invoice ${id}`);
                    }
                    if (inv.status == "refunded") {
                        return fail(`invoice ${id} is already refunded`);
                    }
                    let previous = inv.status;
                    inv.status = "refunded";
                    ok(j(Refund { invoice_id: id, refunded: inv.amount, previous_status: previous }))
                },
                _ => fail(`billing has no method ${method}`),
            }
        }
        function revert(
            self,
            method: string,
            args: json,
            result: json,
            execution_id: string,
        ) -> bool {
            if (method != "issue_refund") {
                return false;
            }
            let id = arg_str(args, "invoice_id") ?? "";
            let previous = arg_str(result, "previous_status") ?? "open";
            let inv = self.invoices.find((i) -> {
                i.id == id
            });
            if (inv == null) {
                return false;
            }
            inv.status
                = match (previous) {
                    "open" => "open",
                    "paid" => "paid",
                    "overdue" => "overdue",
                    _ => "open",
                };
            true
        }
        function world(self) -> json throws never {
            j(self.invoices)
        }
    }
}

function seed_billing() -> Billing {
    Billing {
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

// ───────────────────────────── email ─────────────────────────────

class SentEmail {
    to: string,
    subject: string,
    body: string,
    execution_id: string,
    sent_at: string,
}

class Email {
    sent: SentEmail[],
    implements Connector {
        function name(self) -> string throws never {
            "email"
        }
        function description(self) -> string throws never {
            "Outbound email. Sending is irreversible and always needs approval."
        }
        function methods(self) -> MethodSpec[] throws never {
            [
                spec(
                    "email",
                    "send",
                    "Send one email. Requires user approval. NOT reversible.",
                    requires_approval = true,
                ),
                spec("email", "list_sent", "Emails sent so far."),
            ]
        }
        function call(
            self,
            method: string,
            args: json,
            execution_id: string,
        ) -> CallResult throws never {
            match (method) {
                "send" => {
                    let to = arg_str(args, "to");
                    if (to == null) {
                        return fail("send requires `to`");
                    }
                    self.sent.push(
                        SentEmail {
                            to: to,
                            subject: arg_str(args, "subject") ?? "(no subject)",
                            body: arg_str(args, "body") ?? "",
                            execution_id: execution_id,
                            sent_at: baml.time.Instant.now().to_string(),
                        },
                    );
                    ok(j(EmailSent { ok: true, to: to }))
                },
                "list_sent" => ok(j(self.sent)),
                _ => fail(`email has no method ${method}`),
            }
        }
        function world(self) -> json throws never {
            j(self.sent)
        }
    }
}

// ───────────────────────────── env (secrets vault) ─────────────────────────────
// Values live only in the runtime: never in the model's context, never in the
// durable log (replay = Reexecute), never sent to the browser. Missing values
// pause the execution so the user can enter them in the UI.

class Env {
    vars: map<string, string>,
    implements Connector {
        function name(self) -> string throws never {
            "env"
        }
        function description(self) -> string throws never {
            "Environment variables and secrets managed by the user in the UI. Values are redacted from outputs."
        }
        function methods(self) -> MethodSpec[] throws never {
            [
                spec(
                    "env",
                    "get",
                    "Value of a variable. If it is not set, the run pauses and the user is asked to enter it in the UI.",
                    replay = ReplayPolicy.Reexecute,
                ),
                spec("env", "names", "Names of the variables that are set."),
            ]
        }
        function gate(self, method: string, args: json) -> string? throws never {
            if (method != "get") {
                return null;
            }
            let name = arg_str(args, "name") ?? "";
            if (self.vars.has(name)) {
                null
            } else {
                `needs the environment variable ${name}`
            }
        }
        function call(
            self,
            method: string,
            args: json,
            execution_id: string,
        ) -> CallResult throws never {
            match (method) {
                "get" => {
                    let name = arg_str(args, "name") ?? "";
                    let v = self.vars.get(name);
                    if (v == null) {
                        fail(`${name} is not set`)
                    } else {
                        ok(j(v))
                    }
                },
                "names" => ok(j(self.vars.keys())),
                _ => fail(`env has no method ${method}`),
            }
        }
        function world(self) -> json throws never {
            j(self.vars.keys())
        }
    }
}

// ───────────────────────────── github ─────────────────────────────
// A real, read-only connector over the public GitHub API. Marked `reexecute`:
// results are large idempotent reads, so the log keeps seq + args only.

class Github {
    implements Connector {
        function name(self) -> string throws never {
            "github"
        }
        function description(self) -> string throws never {
            "Read-only GitHub (public API, unauthenticated)."
        }
        function methods(self) -> MethodSpec[] throws never {
            [
                spec(
                    "github",
                    "list_pull_requests",
                    "List pull requests for a public repo (max 10).",
                    replay = ReplayPolicy.Reexecute,
                ),
                spec(
                    "github",
                    "get_repo",
                    "Repository metadata for a public repo.",
                    replay = ReplayPolicy.Reexecute,
                ),
            ]
        }
        function call(
            self,
            method: string,
            args: json,
            execution_id: string,
        ) -> CallResult throws never {
            let owner = arg_str(args, "owner") ?? "";
            let repo = arg_str(args, "repo") ?? "";
            match (method) {
                "list_pull_requests" => {
                    let state = arg_str(args, "state") ?? "open";
                    let res = gh_get(
                        `https://api.github.com/repos/${owner}/${repo}/pulls?state=${state}&per_page=10`,
                    ) catch_all (e) {
                        _ => {
                            return fail("github fetch failed");
                        }
                    };
                    if (!res.ok()) {
                        return fail(`github returned ${res.status_code}`);
                    }
                    let doc = jparse(
                        res.text() catch_all (e) {
                            _ => ""
                        },
                    );
                    let rows = match (doc) {
                        let arr: json[] => {
                            arr.map((p) -> {
                                PullRequest {
                                    number: baml.json.path_or<int>(p, ".number", 0),
                                    title: baml.json.path_or<string>(p, ".title", ""),
                                    user: baml.json.path_or<string>(p, ".user.login", ""),
                                    url: baml.json.path_or<string>(p, ".html_url", ""),
                                    updated_at: baml.json.path_or<string>(p, ".updated_at", ""),
                                }
                            })
                        },
                        _ => [],
                    };
                    ok(j(rows))
                },
                "get_repo" => {
                    let res = gh_get(`https://api.github.com/repos/${owner}/${repo}`) catch_all (e) {
                        _ => {
                            return fail("github fetch failed");
                        }
                    };
                    if (!res.ok()) {
                        return fail(`github returned ${res.status_code}`);
                    }
                    let p = jparse(
                        res.text() catch_all (e) {
                            _ => ""
                        },
                    );
                    ok(
                        j(
                            Repo {
                                full_name: baml.json.path_or<string>(p, ".full_name", ""),
                                description: baml.json.path_or<string>(p, ".description", ""),
                                stars: baml.json.path_or<int>(p, ".stargazers_count", 0),
                                open_issues: baml.json.path_or<int>(p, ".open_issues_count", 0),
                            },
                        ),
                    )
                },
                _ => fail(`github has no method ${method}`),
            }
        }
    }
}

function gh_get(url: string) -> baml.http.Response {
    baml.http.send(
        baml.http.Request {
            method: "GET",
            url: url,
            body: "",
            headers: { "user-agent": "codemode-baml-demo", "accept": "application/vnd.github+json" },
        },
    )
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
