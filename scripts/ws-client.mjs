// Drive the BAML server over its WebSocket from the terminal, auto-approving.
//   node scripts/ws-client.mjs "task text" [approve|reject-first]
const task = process.argv[2] ?? "Which pro-plan customers have an overdue invoice? Email each one a short, friendly reminder with the amount due.";
const policy = process.argv[3] ?? "approve";
const ws = new WebSocket(process.env.CODEMODE_WS ?? "ws://127.0.0.1:8787/ws");
const t0 = Date.now();
const log = (...a) => console.log(`[${((Date.now() - t0) / 1000).toFixed(1)}s]`, ...a);
let sid = null, decided = new Set(), events = 0, rejected = false;

ws.onopen = () => log("open");
ws.onmessage = (m) => {
  const ev = JSON.parse(m.data); events++;
  switch (ev.type) {
    case "snapshot":
      log("snapshot: sessions", ev.state.sessions.length, "executions", ev.state.runtime.executions.length, "connectors", ev.state.runtime.connectors.map((c) => c.name).join(","));
      ws.send(JSON.stringify({ type: "start", task }));
      break;
    case "result":
      log("result", ev.command, JSON.stringify(ev.result).slice(0, 120));
      if (ev.command === "start") sid = ev.result.id;
      break;
    case "session": {
      const s = ev.session; if (s.id !== sid) return;
      log("session", s.status, "turns", s.turns.length, "|", (s.thought ?? "").slice(0, 90));
      if (s.status === "done" || s.status === "error") { log("ANSWER:\n" + (s.answer ?? "")); log("events received:", events); ws.close(); process.exit(0); }
      break;
    }
    case "execution": {
      const ex = ev.execution;
      const pend = ex.log.find((e) => e.state === "Pending");
      const inv = ev.world.find((w) => w.name === "billing").world.find((i) => i.id === "inv_100").status;
      log("execution", ex.id, ex.status, "attempt", ex.pass_count, "log", ex.log.map((e) => `#${e.seq}:${e.method}:${e.state[0]}`).join(" "), "| inv_100:", inv);
      if (pend && !decided.has(`${ex.id}:${pend.seq}`)) {
        decided.add(`${ex.id}:${pend.seq}`);
        const d = policy === "reject-first" && !rejected ? (rejected = true, "reject") : "approve";
        log(`  -> ${d} ${pend.connector}.${pend.method}`);
        ws.send(JSON.stringify({ type: d, execution_id: ex.id }));
      }
      break;
    }
    default: log("event", ev.type);
  }
};
ws.onerror = (e) => { log("error", e.message); process.exit(1); };
setTimeout(() => { log("timeout"); process.exit(1); }, 240000);
