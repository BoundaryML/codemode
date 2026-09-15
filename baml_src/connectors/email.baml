// Outbound email. Sending is irreversible, so it always needs approval.

class SentEmail {
    to: string,
    subject: string,
    body: string,
    execution_id: string,
    sent_at: string,
}

class EmailSent {
    ok: bool,
    to: string,
}

class Email {
    sent: SentEmail[],
    ctx: Ctx?,

    /// Send one email. Requires user approval. NOT reversible.
    function send(
        self,
        to: string,
        subject: string,
        body: string,
    ) -> EmailSent throws PausedForApproval | ReplayDivergence | ConnectorError {
        call<EmailSent>(self.ctx, self.send, j({ "to": to, "subject": subject, "body": body }), () -> {
            if (to.trim().length() == 0) {
                throw err("send requires `to`");
            }
            self.sent.push(
                SentEmail {
                    to: to,
                    subject: subject,
                    body: body,
                    execution_id: self.ctx?.exec.id ?? "",
                    sent_at: baml.time.Instant.now().to_string(),
                },
            );
            EmailSent { ok: true, to: to }
        })
    }
    /// Emails sent so far.
    function list_sent(
        self,
    ) -> SentEmail[] throws PausedForApproval | ReplayDivergence | ConnectorError {
        call<SentEmail[]>(self.ctx, self.list_sent, j({}), () -> {
            self.sent
        })
    }

    function bind(self, rt: Runtime, exec: Execution) -> Email throws never {
        Email { sent: self.sent, ctx: bind_ctx(self, rt, exec) }
    }

    implements Connector {
        function name(self) -> string throws never {
            "email"
        }
        function description(self) -> string throws never {
            "Outbound email. Sending is irreversible and always needs approval."
        }
        function tools(self) -> Tool[] throws never {
            [tool(self.send, approval = true), tool(self.list_sent)]
        }
        function world(self) -> json throws never {
            j(self.sent)
        }
    }
}
