# Drive a model session over HTTP and watch it via /api/state (works without WebSockets).
#   CODEMODE_API=http://127.0.0.1:8788 python3 scripts/session.py "task" [approve|reject-first] [--then "follow-up message" ...]
import json, os, sys, time, urllib.request
B = os.environ.get("CODEMODE_API", "http://127.0.0.1:8787")
def post(path, body=None):
    req = urllib.request.Request(B + path, data=json.dumps(body or {}).encode(), headers={"content-type": "application/json"}, method="POST")
    return json.load(urllib.request.urlopen(req, timeout=120))
def state(): return json.load(urllib.request.urlopen(B + "/api/state"))
args = sys.argv[1:]
followups = []
while "--then" in args:
    i = args.index("--then"); followups.append(args[i + 1]); del args[i:i + 2]
envs = {}
while "--env" in args:  # --env NAME=VALUE  answers an env pause with this value
    i = args.index("--env"); k, v = args[i + 1].split("=", 1); envs[k] = v; del args[i:i + 2]
task = args[0]; policy = args[1] if len(args) > 1 else "approve"
sid = post("/api/sessions", {"task": task})["id"]; print("session", sid); t0 = time.time()
last = None; seen = set(); rejected = False
while time.time() - t0 < 600:
    st = state(); s = [x for x in st["sessions"] if x["id"] == sid][0]
    key = (s["status"], len(s["turns"]), s["thought"])
    if key != last:
        print(f"[{time.time()-t0:5.1f}s] {s['status']} turns={len(s['turns'])} | {(s['thought'] or '')[:100]}"); last = key
    for t in s["turns"]:
        if t["execution_id"] in seen: continue
        seen.add(t["execution_id"]); ex = [e for e in st["runtime"]["executions"] if e["id"] == t["execution_id"]][0]
        print("  CODE:\n" + "\n".join("    " + l for l in ex["code"].splitlines()))
        if ex["fix_log"]: print("  FIXES:", [(f["attempt"], f["thought"][:80]) for f in ex["fix_log"]])
        if ex["discovered"]: print("  DISCOVERED:", ex["discovered"])
        print("  LOG:", [(e["seq"], e["method"], e["state"], e["pass"]) for e in ex["log"]])
        print("  OUTCOME:", t["outcome"][:300])
    if s["status"] == "paused":
        eid = s["current_execution_id"]; ex = [e for e in st["runtime"]["executions"] if e["id"] == eid][0]
        p = [e for e in ex["log"] if e["state"] == "Pending"][0]
        if p["connector"] == "env":
            name = p["args"]["name"]
            if name in envs:
                print(f"  ⌨ ENV {name} = ****"); post(f"/api/env/{name}", {"value": envs[name]}); post(f"/api/executions/{eid}/approve")
            else:
                print(f"  ✕ no value for env {name}; rejecting"); post(f"/api/executions/{eid}/reject")
        elif policy == "reject-first" and not rejected:
            rejected = True; print(f"  ✕ REJECT {p['connector']}.{p['method']}"); post(f"/api/executions/{eid}/reject")
        else:
            print(f"  ✓ APPROVE #{p['seq']} {p['connector']}.{p['method']} {json.dumps(p['args'])[:80]}"); post(f"/api/executions/{eid}/approve")
    if s["status"] in ("done", "error"):
        print("ANSWER:\n" + str(s["answer"]))
        if s["status"] == "done" and followups:
            nxt = followups.pop(0); print(f"\n>>> USER: {nxt}"); post(f"/api/sessions/{sid}/messages", {"text": nxt}); last = None; time.sleep(1); continue
        break
    time.sleep(1.5)
