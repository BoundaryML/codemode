import { useEffect, useRef, useState } from "react";
import { marked } from "marked";
import type { Execution, Json, LogEntry, Message, Session, State, ToolView, Turn } from "./api";
import { useServer, type Command } from "./ws";
import { Group, Panel, Separator, useDefaultLayout } from "react-resizable-panels";
import { Code } from "./code";

// Stage UI. Left: the story of one task, in order. Right: reference tabs.
// Everything is derived from server state; the BAML server pushes changes.

const SUGGESTIONS = [
  { title: "Send overdue reminders", task: "Which pro-plan customers have an overdue invoice? Email each one a short, friendly reminder with the amount due." },
  { title: "Refund + note", task: "Refund Ada Lovelace's overdue invoice and add a note to her CRM record explaining why." },
  { title: "Upgrade paid-up customers", task: "Upgrade every pro customer who has no outstanding balance to the enterprise plan." },
  { title: "Ask GitHub", task: "How many stars does BoundaryML/baml have, and what are the 3 most recently updated open PRs?" },
];

export default function App() {
  const { state, online, transport, send, lastResult } = useServer();
  const [sessionId, setSessionId] = useState<string | null>(() => new URLSearchParams(location.search).get("session"));
  const [task, setTask] = useState("");
  const [tab, setTab] = useState<"data" | "tools" | "env" | "history">(() => {
    const t = new URLSearchParams(location.search).get("tab");
    return t === "data" || t === "history" || t === "env" ? t : "tools";
  });
  const [auto, setAuto] = useState(false);
  const scrollRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (lastResult?.command === "start" && lastResult.result && typeof lastResult.result === "object" && "id" in lastResult.result) setSessionId((lastResult.result as Session).id);
  }, [lastResult]);

  const session = state?.sessions.find((s) => s.id === sessionId) ?? null;
  const busy = !!session && (session.status === "thinking" || session.status === "executing");
  const execById = (id: string | null) => (id ? state?.runtime.executions.find((e) => e.id === id) ?? null : null);
  const current = execById(session?.current_execution_id ?? null);
  const pending = current?.status === "Paused" ? current.log.find((e) => e.state === "Pending") ?? null : null;
  const discovered = new Set<string>();
  if (session) for (const id of [...session.turns.map((t) => t.execution_id), session.current_execution_id]) for (const d of execById(id ?? null)?.discovered ?? []) discovered.add(d);

  // First message starts a conversation; later ones continue it.
  const start = (text: string) => {
    if (!text.trim() || busy || session?.status === "paused") return;
    setTask("");
    if (session) send({ type: "say", session_id: session.id, text }); else send({ type: "start", task: text });
  };
  const fresh = () => setSessionId(null);
  const decide = (d: "approve" | "reject") => { if (current) send({ type: d, execution_id: current.id }); };
  // Env pause: store the value, then resume (the re-run replays up to env.get and proceeds).
  const provideEnv = (name: string, value: string) => { if (!current) return; send({ type: "set_env", name, value }); setTimeout(() => send({ type: "approve", execution_id: current.id }), 150); };

  const booted = useRef(false);
  useEffect(() => {
    if (booted.current || !online) return;
    booted.current = true;
    const q = new URLSearchParams(location.search);
    if (q.get("auto") === "approve") setAuto(true);
    const t = q.get("task"); if (t) start(t);
  }, [online]); // eslint-disable-line react-hooks/exhaustive-deps
  useEffect(() => { if (auto && pending) decide("approve"); }, [auto, pending?.seq, current?.id]); // eslint-disable-line react-hooks/exhaustive-deps
  const inSession = !!session;
  useEffect(() => { if (inSession) scrollRef.current?.scrollTo({ top: scrollRef.current.scrollHeight, behavior: "smooth" }); }, [inSession, session?.id, session?.status, session?.turns.length, current?.log.length, current?.pass_count, current?.fix_log.length]);

  const rt = state?.runtime;
  const layout = useDefaultLayout({ id: "codemode-columns", storage: localStorage, onlySaveAfterUserInteractions: true });
  return (
    <div className="app">
      <header className="top">
        <h1><span className="mark" aria-hidden />Code Mode, in BAML</h1>
        <span className="sub">The model gets one tool. It writes BAML; the server compiles it, runs it, and pauses for approval.</span>
        <span className="spacer" />
        <span className={`live ${online ? "on" : ""}`}>{transport === "websocket" ? "live over websocket" : transport === "sse" ? "live" : "offline"}</span>
      </header>
      <Group className="main" orientation="horizontal" defaultLayout={layout.defaultLayout} onLayoutChanged={layout.onLayoutChanged}>
        <Panel id="story" className="col story" defaultSize="54" minSize="30">
          <div className="scroll" ref={scrollRef}>
            {!session && <Welcome onPick={start} disabled={busy} />}
            {session && <Story session={session} execById={execById} current={current} pending={pending} onDecide={decide} onEnv={provideEnv} />}
          </div>
          {session && <div className="chips"><button className="new" onClick={fresh}>New conversation</button>{SUGGESTIONS.map((s) => <button key={s.task} disabled={busy} onClick={() => start(s.task)}>{s.title}</button>)}</div>}
          <div className="composer">
            <textarea rows={1} value={task} disabled={busy || session?.status === "paused"} placeholder={session ? "Reply. The model remembers this conversation and its tools." : "Ask for something that needs a few tools"} onChange={(e) => setTask(e.target.value)}
              onKeyDown={(e) => { if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); start(task); } }} />
            <button className="send" aria-label={session ? "Send" : "Run"} title={session ? "Send" : "Run"} disabled={busy || !task.trim()} onClick={() => start(task)}>
              <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.4" strokeLinecap="round" strokeLinejoin="round" aria-hidden><path d="M12 19V5" /><path d="m5 12 7-7 7 7" /></svg>
            </button>
          </div>
        </Panel>
        <Separator className="divider" aria-label="Resize the columns" />
        <Panel id="ref" className="col ref" minSize="28">
          <div className="tabs">
            <button className={tab === "data" ? "active" : ""} onClick={() => setTab("data")}>Live data</button>
            <button className={tab === "tools" ? "active" : ""} onClick={() => setTab("tools")}>Tools{rt && rt.snippets.length > 0 && <span className="count" title="made by the model">{rt.snippets.length} made</span>}</button>
            <button className={tab === "env" ? "active" : ""} onClick={() => setTab("env")}>Env{rt?.env.length ? ` (${rt.env.length})` : ""}</button>
            <button className={tab === "history" ? "active" : ""} onClick={() => setTab("history")}>History</button>
          </div>
          <div className="scroll">
            {!rt ? <div className="empty">Start the BAML server: <code>./dev.sh</code></div>
              : tab === "data" ? <Data state={rt} />
              : tab === "tools" ? <Tools tools={rt.tools} snippets={rt.snippets} discovered={discovered} send={send} />
              : tab === "env" ? <EnvTab names={rt.env} send={send} />
              : <History state={rt} send={send} />}
          </div>
        </Panel>
      </Group>
    </div>
  );
}

// ─────────────────────────── left: the story ───────────────────────────

function Welcome({ onPick, disabled }: { onPick: (t: string) => void; disabled: boolean }) {
  return (
    <div className="welcome">
      <h2>Pick a task</h2>
      <div className="cards">
        {SUGGESTIONS.map((s) => <button key={s.task} className="card" disabled={disabled} onClick={() => onPick(s.task)}>{s.title}<small>{s.task}</small></button>)}
      </div>
    </div>
  );
}

function Story({ session, execById, current, pending, onDecide, onEnv }: {
  session: Session; execById: (id: string | null) => Execution | null; current: Execution | null; pending: LogEntry | null; onDecide: (d: "approve" | "reject") => void; onEnv: (name: string, value: string) => void;
}) {
  // Chronological: each user message, then the steps it caused, then the answer.
  const items: ({ kind: "msg"; m: Message } | { kind: "step"; n: number; thought: string; ex: Execution; latest: boolean })[] = [];
  const stepsFor = (idx: number): Turn[] => session.turns.filter((t) => t.message_index === idx);
  let n = 0;
  session.messages.forEach((m, idx) => {
    items.push({ kind: "msg", m });
    if (m.role === "user") {
      for (const t of stepsFor(idx)) { const ex = execById(t.execution_id); if (ex) items.push({ kind: "step", n: ++n, thought: t.thought, ex, latest: false }); }
    }
  });
  if (current && (session.status === "executing" || session.status === "paused")) items.push({ kind: "step", n: ++n, thought: session.thought ?? "", ex: current, latest: true });
  const lastStep = [...items].reverse().find((i) => i.kind === "step");
  return (
    <>
      {items.map((it, i) => it.kind === "msg"
        ? (it.m.role === "user"
          ? <div className="you" key={i}><p>{it.m.text}</p></div>
          : <div className="answer" key={i}><div className="who">Answer</div><div className="prose" dangerouslySetInnerHTML={{ __html: marked.parse(it.m.text, { async: false }) as string }} /></div>)
        : <Step key={it.ex.id} n={it.n} thought={it.thought} ex={it.ex} open={it === lastStep} live={it.latest} tail={items[i + 1]?.kind !== "step"} />)}
      {pending && current && (pending.connector === "env" ? <EnvPrompt p={pending} onEnv={onEnv} onReject={() => onDecide("reject")} /> : <Approval p={pending} onDecide={onDecide} />)}
      {session.status === "thinking" && <p className="working"><span className="spin" />{session.turns.length ? "Model is reading the result and deciding what to do next…" : "Model is writing code…"}</p>}
      {session.status === "executing" && !pending && <p className="working"><span className="spin" />Compiling and running…</p>}
      {session.status === "error" && <div className="errbox">{session.answer}</div>}
    </>
  );
}

function Step({ n, thought, ex, open, live, tail }: { n: number; thought: string; ex: Execution; open: boolean; live: boolean; tail: boolean }) {
  const [showCode, setShowCode] = useState(open);
  useEffect(() => setShowCode(open), [open]);
  const replaying = ex.pass_count > 1;
  return (
    <div className={`step ${live ? "current" : ""} ${tail ? "tail" : ""}`}>
      <div className="label">Step {n} <b>The model wrote code</b></div>
      <p className="thought">{thought}</p>
      {ex.fix_log.map((f) => <FixBox key={f.attempt} f={f} />)}
      {showCode ? <Code src={ex.code} /> : <button className="link quiet" onClick={() => setShowCode(true)}>Show the code</button>}
      {(ex.log.length > 0 || ex.discovered.length > 0) && (
        <>
          <div className="runlabel">{replaying ? `Ran it again (attempt ${ex.pass_count}). Earlier calls were answered from the log.` : "Ran it"}</div>
          <ul className="calls">
            {ex.discovered.length > 0 && <li className="discover"><span className="glyph">?</span><span className="what">looked up {ex.discovered.length} tool{ex.discovered.length === 1 ? "" : "s"}: {ex.discovered.join(", ")}</span></li>}
            {ex.log.map((e) => <CallRow key={e.seq} e={e} ex={ex} />)}
          </ul>
        </>
      )}
      {ex.status === "Completed" && ex.publish_as && <div className="published"><b>New tool: {ex.publish_as}</b>. {ex.publish_description} Later code can call <code>{ex.publish_as}.run(codemode)</code>. It is listed under "Made by the model" in the Tools tab.</div>}
      {ex.status === "Completed" && <div className="returned">Returned <code>{short(ex.result, 160)}</code>{JSON.stringify(ex.result ?? null).length > 160 && <details><summary>full result</summary><Code src={JSON.stringify(ex.result, null, 1)} lang="json" /></details>}</div>}
      {ex.status === "Error" && <div className="errbox">Failed: {ex.error}</div>}
      {ex.status === "Rejected" && <div className="errbox">You rejected {ex.log.find((e) => e.state === "Rejected")?.method ?? "the action"}. Earlier calls stayed applied.</div>}
    </div>
  );
}

function FixBox({ f }: { f: Execution["fix_log"][number] }) {
  return (
    <div className="fixbox">
      <b>Didn't compile.</b> The model fixed it (attempt {f.attempt}): <i>{f.thought}</i>
      <details><summary>broken code and compiler errors</summary><Code src={f.code} /><pre style={{ color: "var(--red)" }}>{f.diagnostics}</pre></details>
    </div>
  );
}

function CallRow({ e, ex }: { e: LogEntry; ex: Execution }) {
  const replayed = e.pass < ex.pass_count && e.state !== "Pending";
  const waiting = e.state === "Pending";
  const call = e.kind === "step" ? `step "${e.method}"` : `${e.connector}.${e.method}(${argList(e.args)})`;
  const got = waiting ? "needs your approval" : e.state === "Rejected" ? "rejected" : e.error ? e.error : e.replay === "Reexecute" ? "re-run" : summary(e.result);
  return (
    <li className={`${replayed ? "replay" : ""} ${waiting ? "wait" : ""} ${e.error || e.state === "Rejected" ? "bad" : ""}`}>
      <span className="glyph">{waiting ? "‖" : e.error || e.state === "Rejected" ? "×" : replayed ? "↺" : "·"}</span>
      <span className="what">{call}</span>
      <span className="got">{replayed ? "from the log, " : ""}{got}</span>
    </li>
  );
}

function Approval({ p, onDecide }: { p: LogEntry; onDecide: (d: "approve" | "reject") => void }) {
  const args = (p.args && typeof p.args === "object" && !Array.isArray(p.args) ? p.args : {}) as Record<string, Json>;
  return (
    <div className="approve">
      <h2>Paused. The code wants to call <code>{p.connector}.{p.method}</code></h2>
      <dl className="fields">{Object.entries(args).map(([k, v]) => <div key={k}><dt>{k}</dt><dd>{typeof v === "string" ? v : JSON.stringify(v)}</dd></div>)}</dl>
      <div className="actions"><button className="ok" onClick={() => onDecide("approve")}>Approve</button><button className="danger" onClick={() => onDecide("reject")}>Reject</button></div>
      <p className="hint">Approve re-runs the same code. The {p.seq} earlier call{p.seq === 1 ? " is" : "s are"} answered from the log; this one executes for real.</p>
    </div>
  );
}

function EnvPrompt({ p, onEnv, onReject }: { p: LogEntry; onEnv: (name: string, value: string) => void; onReject: () => void }) {
  const name = String((p.args as Record<string, Json> | null)?.name ?? "");
  const [value, setValue] = useState("");
  return (
    <div className="approve">
      <h2>Paused. The code needs the environment variable <code>{name}</code></h2>
      <p className="hint" style={{ margin: "0 0 12px" }}>Enter it here, not in the chat. It is stored in the server's vault, never shown to the model, and redacted from results.</p>
      <div className="actions">
        <input type="password" className="envinput" placeholder={`value for ${name}`} value={value} onChange={(e) => setValue(e.target.value)} onKeyDown={(e) => { if (e.key === "Enter" && value) onEnv(name, value); }} autoFocus />
        <button className="ok" disabled={!value} onClick={() => onEnv(name, value)}>Save and continue</button>
        <button className="danger" onClick={onReject}>Reject</button>
      </div>
    </div>
  );
}

function EnvTab({ names, send }: { names: string[]; send: (c: Command) => void }) {
  const [name, setName] = useState("");
  const [value, setValue] = useState("");
  const add = () => { if (!name.trim() || !value) return; send({ type: "set_env", name: name.trim(), value }); setName(""); setValue(""); };
  return <>
    <p className="note">Secrets and settings the model's code can read with <code>codemode.env.get("NAME")</code>. Values stay in the BAML server: never shown here, never in the model's context, redacted from results and logs.</p>
    <div className="envform">
      <input className="envinput" placeholder="NAME" value={name} onChange={(e) => setName(e.target.value.toUpperCase().replace(/[^A-Z0-9_]/g, "_"))} />
      <input className="envinput" type="password" placeholder="value" value={value} onChange={(e) => setValue(e.target.value)} onKeyDown={(e) => { if (e.key === "Enter") add(); }} />
      <button className="primary" disabled={!name.trim() || !value} onClick={add}>Save</button>
    </div>
    {names.length === 0 ? <div className="empty">Nothing set. Start the server with <code>CODEMODE_ENV_IMPORT=GITHUB_TOKEN</code> to import from the process environment, or add one above.</div>
      : <table><thead><tr><th>name</th><th>value</th><th></th></tr></thead><tbody>
        {names.map((n) => <tr key={n}><td className="mono">{n}</td><td className="muted">••••••••</td><td><button className="link del" onClick={() => { if (confirm(`Delete ${n}?`)) send({ type: "delete_env", name: n }); }}>delete</button></td></tr>)}
      </tbody></table>}
  </>;
}

// ─────────────────────────── right: reference ───────────────────────────

function Data({ state }: { state: State["runtime"] }) {
  const world = (n: string) => (state.connectors.find((c) => c.name === n)?.world ?? []) as Record<string, Json>[];
  const customers = world("crm"), invoices = world("billing"), emails = world("email");
  return (
    <>
      <div className="sec"><h3>Customers</h3><span className="n">{customers.length}</span></div>
      <table><thead><tr><th>name</th><th>plan</th><th>notes</th></tr></thead><tbody>
        {customers.map((c) => <tr key={String(c.id)}><td>{String(c.name)}<div className="muted small">{String(c.email)}</div></td><td>{String(c.plan)}</td><td className="small">{(c.notes as string[]).map((n, i) => <div key={i}>{n}</div>)}</td></tr>)}
      </tbody></table>
      <div className="sec"><h3>Invoices</h3><span className="n">{invoices.length}</span></div>
      <table><thead><tr><th>invoice</th><th>customer</th><th>amount</th><th>status</th></tr></thead><tbody>
        {invoices.map((i) => <tr key={String(i.id)}><td className="mono">{String(i.id)}</td><td>{customers.find((c) => c.id === i.customer_id)?.name as string ?? String(i.customer_id)}</td><td>${Number(i.amount).toFixed(0)}</td><td className={`status ${String(i.status)}`}>{String(i.status)}</td></tr>)}
      </tbody></table>
      <div className="sec"><h3>Sent emails</h3><span className="n">{emails.length}</span></div>
      {emails.length === 0 ? <div className="empty">None yet. Emails the model's code sends show up here.</div> :
        emails.map((m, i) => <div className="email" key={i}><b>{String(m.subject)}</b> <span className="muted">to {String(m.to)}</span><div className="body">{String(m.body)}</div></div>)}
    </>
  );
}

function Tools({ tools, snippets, discovered, send }: { tools: ToolView[]; snippets: State["runtime"]["snippets"]; discovered: Set<string>; send: (c: Command) => void }) {
  const [open, setOpen] = useState<string | null>(null);
  const remove = (name: string) => { if (confirm(`Delete tool "${name}"? Code that imports it will stop compiling.`)) send({ type: "delete_tool", name }); };
  const builtin = tools.filter((t) => t.kind === "method");
  const connectors = [...new Set(builtin.map((t) => t.connector))];
  const row = (t: ToolView) => (
    <div className={`tool ${discovered.has(t.path) ? "found" : ""}`} key={t.path}>
      <div className="sig"><b>{t.name}</b>{t.signature.slice(t.name.length)}{t.requires_approval && <span className="tag approval">needs approval</span>}{discovered.has(t.path) && <span className="tag found">looked up in this task</span>}</div>
      {t.kind === "method" && t.docstring && <div className="doc">{t.docstring}</div>}
    </div>
  );
  return <>
    <section className="toolset made">
      <div className="head"><h3>Made by the model</h3><span className="n">{snippets.length === 0 ? "none yet" : snippets.length}</span></div>
      <p className="why">Programs the model wrote during a task, compiled into typed packages it can call later.</p>
      {snippets.length === 0 && (
        <div className="made-empty">Nothing yet. When a run finishes, <b>Save as snippet</b> in History turns it into a tool, or the model can publish one itself. It will appear here and become searchable.</div>
      )}
      {snippets.map((sn) => (
        <div className="made-tool" key={sn.name}>
          <div className="mhead">
            <span className="name">{sn.name}</span>
            <span className="acts">
              <button className="link" onClick={() => setOpen(open === sn.name ? null : sn.name)}>{open === sn.name ? "Hide source" : "View source"}</button>
              <button className="link del" onClick={() => remove(sn.name)}>Delete</button>
            </span>
          </div>
          <div className="desc">{sn.description}</div>
          <div className="meta">From run {sn.source_execution_id}, {new Date(sn.created_at).toLocaleString()}</div>
          {open === sn.name && <div className="toolsrc"><Code src={sn.code} /></div>}
          {tools.filter((t) => t.kind === "snippet" && t.connector === sn.name).map(row)}
        </div>
      ))}
    </section>

    <section className="toolset">
      <div className="head"><h3>Built in</h3><span className="n">{builtin.length} across {connectors.length} connectors</span></div>
      <p className="why">Declared in the server's own BAML source. They exist before any task runs.</p>
      {connectors.map((c) => (
        <div className="connector" key={c}>
          <div className="cname">{c}</div>
          <div>{builtin.filter((t) => t.connector === c).map(row)}</div>
        </div>
      ))}
    </section>
  </>;
}

function History({ state, send }: { state: State["runtime"]; send: (c: Command) => void }) {
  if (state.executions.length === 0) return <div className="empty">Nothing has run yet.</div>;
  const save = (ex: Execution) => {
    const name = prompt("Snippet name (the model will import it by this name):", `snippet_${ex.id.slice(5)}`); if (!name) return;
    send({ type: "save_snippet", execution_id: ex.id, name, description: prompt("One-line description:", ex.task) ?? ex.task });
  };
  return <>
    <p className="note">Every run BAML recorded. Roll back undoes a run's calls in reverse order. Save as snippet turns a run into a tool the model can call.</p>
    {state.executions.map((ex) => (
      <div className="hist" key={ex.id}>
        <div className="head"><span className={`status ${ex.status === "Completed" ? "paid" : ex.status === "Error" || ex.status === "Rejected" ? "overdue" : ex.status === "RolledBack" ? "refunded" : ""}`}>{statusText(ex.status)}</span><b>{ex.id}</b><span className="muted small">{ex.pass_count} attempt{ex.pass_count === 1 ? "" : "s"} · {ex.log.length} calls{ex.fix_log.length ? ` · ${ex.fix_log.length} fix` : ""}</span></div>
        <div className="task">{ex.task || "direct run"}</div>
        <details><summary>code and calls</summary>
          <Code src={ex.code} />
          <ul className="calls">{ex.log.map((e) => <CallRow key={e.seq} e={e} ex={ex} />)}</ul>
        </details>
        <div className="actions">
          <button disabled={ex.status === "Running" || ex.status === "Paused" || ex.status === "RolledBack" || !ex.log.some((e) => e.state === "Applied" && e.kind === "call")} onClick={() => send({ type: "rollback", execution_id: ex.id })}>Roll back</button>
          <button disabled={ex.status !== "Completed"} onClick={() => save(ex)}>Save as snippet</button>
        </div>
      </div>
    ))}
  </>;
}

// ─────────────────────────── helpers ───────────────────────────

function statusText(s: Execution["status"]) {
  return { Running: "running", Paused: "paused", Completed: "finished", Error: "failed", Rejected: "rejected", RolledBack: "rolled back" }[s];
}
function argList(args: Json): string {
  if (!args || typeof args !== "object" || Array.isArray(args)) return "";
  return Object.entries(args).filter(([, v]) => v !== null).map(([k, v]) => `${k} = ${typeof v === "string" ? JSON.stringify(v.length > 40 ? v.slice(0, 38) + "…" : v) : JSON.stringify(v)}`).join(", ");
}
function summary(v: Json): string {
  if (Array.isArray(v)) return v.length === 0 ? "nothing" : `${v.length} result${v.length === 1 ? "" : "s"}`;
  if (v && typeof v === "object") {
    const o = v as Record<string, Json>;
    if ("ok" in o && o.ok === true) return "ok";
    const s = Object.entries(o).map(([k, x]) => `${k}: ${typeof x === "string" ? (x.length > 30 ? x.slice(0, 28) + "…" : x) : Array.isArray(x) ? `[${x.length}]` : JSON.stringify(x)}`).join(", ");
    return s.length > 90 ? s.slice(0, 88) + "…" : s;
  }
  return JSON.stringify(v);
}
function short(v: Json | undefined, n: number) {
  const s = v === undefined ? "undefined" : JSON.stringify(v);
  return s && s.length > n ? s.slice(0, n - 1) + "…" : s;
}
