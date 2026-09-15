# Exercise the runtime with hand-written BAML programs (no model). Server must be running.
#   python3 scripts/direct.py
import json, urllib.request
B = "http://127.0.0.1:8787"
def post(path, body=None):
    req = urllib.request.Request(B + path, data=json.dumps(body or {}).encode(), headers={"content-type": "application/json"}, method="POST")
    return json.load(urllib.request.urlopen(req, timeout=120))
def state(): return json.load(urllib.request.urlopen(B + "/api/state"))
def run(title, code):
    r = post("/api/executions", {"code": code, "task": title}); print(f"--- {title}: {r['status']}", json.dumps(r.get('result', r.get('error', r.get('pending'))))[:160]); return r

run("discovery", '''function run(codemode: host.Codemode) -> json {
    let hits = codemode.search("refund invoice");
    baml.json.from({ "hits": hits.results.map((h) -> { h.path }), "doc": codemode.describe("billing.issue_refund") })
}''')
r = run("reads then approval", '''function run(codemode: host.Codemode) -> json {
    let pros = codemode.crm.list_customers(plan = "pro");
    let overdue = codemode.billing.list_invoices(customer_id = pros[0].id, status = "overdue");
    let stamp = codemode.step("stamp", () -> { 4242 });
    let refund = codemode.billing.issue_refund(invoice_id = overdue[0].id, reason = `overdue since ${overdue[0].due}`);
    let note = codemode.crm.add_note(id = pros[0].id, note = `refunded ${refund.refunded} (stamp ${stamp})`);
    baml.json.from({ "refunded": refund.refunded, "notes": note.notes })
}''')
eid = r["execution_id"]
a = post(f"/api/executions/{eid}/approve"); print("--- approve:", a["status"], json.dumps(a.get("result"))[:120], "| replayed:", [l for l in a.get("logs", []) if "replayed" in l][:1])
ex = [e for e in state()["runtime"]["executions"] if e["id"] == eid][0]
print("    log:", [(e["seq"], e["method"], e["state"], e["pass"]) for e in ex["log"]])
rb = post(f"/api/executions/{eid}/rollback"); print("--- rollback:", rb["status"], "reverted", rb["reverted"], "skipped", len(rb["skipped"]))
w = state()["runtime"]["connectors"]; print("    inv_100:", [i for i in w[1]["world"] if i["id"] == "inv_100"][0]["status"], "| c_1 notes:", w[0]["world"][0]["notes"])
r = run("reject flow", 'function run(codemode: host.Codemode) -> json { baml.json.from(codemode.email.send(to = "a@b.c", subject = "s", body = "b")) }')
print("--- reject:", post(f"/api/executions/{r['execution_id']}/reject")["error"][:80])
run("compile error", 'function run(codemode: host.Codemode) -> json { let x: int = "no"; baml.json.from(x) }')
run("panic", 'function run(codemode: host.Codemode) -> json { let xs = [1]; baml.json.from(xs[7]) }')
run("connector error", 'function run(codemode: host.Codemode) -> json { baml.json.from(codemode.crm.get_customer(id = "nope")) }')
r = run("snippet source", 'function run(codemode: host.Codemode) -> json { baml.json.from(codemode.crm.list_customers(plan = "enterprise").map((c) -> { c.name })) }')
print("--- save snippet:", post("/api/snippets", {"name": "enterprise-names", "description": "Names of enterprise customers", "execution_id": r["execution_id"]}).get("name"))
run("run snippet", 'function run(codemode: host.Codemode) -> json { baml.json.from({ "found": codemode.search("enterprise").results.map((h) -> { h.path }), "out": codemode.run("enterprise-names") }) }')
run("github", 'function run(codemode: host.Codemode) -> json { baml.json.from(codemode.github.get_repo(owner = "BoundaryML", repo = "baml").stars) }')
