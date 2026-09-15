// Live connection to the BAML server. On connect the server sends a full
// snapshot; afterwards every change arrives as one event.
//
// Two transports: WebSocket (/ws, commands go back on the same socket) and
// Server-Sent Events (/api/events, commands go over HTTP POST). The BAML
// server's WebSocket accept path is broken on public toolchains (feedback
// e1911bc9), so SSE is the default; set VITE_TRY_WS=1 to try the WebSocket
// first and fall back to SSE if the upgrade is refused.
import { useEffect, useRef, useState } from "react";
import type { Execution, Session, Snippet, State } from "./api";

type Event =
  | { type: "snapshot"; state: State }
  | { type: "session"; session: Session }
  | { type: "execution"; execution: Execution; world: { name: string; world: State["runtime"]["connectors"][number]["world"] }[] }
  | { type: "snippets"; snippets: Snippet[] }
  | { type: "result"; command: string; result: unknown }
  | { type: "notice"; execution_id: string; message: string }
  | { type: "env"; names: string[] }
  | { type: "error"; error: string };

export type Notice = { id: number; execution_id: string; message: string; at: number };

export type Command =
  | { type: "start"; task: string }
  | { type: "say"; session_id: string; text: string }
  | { type: "approve"; execution_id: string }
  | { type: "reject"; execution_id: string }
  | { type: "rollback"; execution_id: string }
  | { type: "delete_tool"; name: string }
  | { type: "set_env"; name: string; value: string }
  | { type: "delete_env"; name: string }
  | { type: "save_snippet"; execution_id: string; name: string; description: string }
  | { type: "run_code"; code: string; task: string };

export type Transport = "websocket" | "sse" | "none";

function upsert<T extends { id: string }>(list: T[], item: T): T[] {
  const i = list.findIndex((x) => x.id === item.id);
  if (i < 0) return [item, ...list];
  const copy = list.slice(); copy[i] = item; return copy;
}

// Command → HTTP route, for the SSE fallback.
async function postCommand(cmd: Command): Promise<{ command: string; result: unknown }> {
  const post = async (path: string, body?: unknown) => {
    const res = await fetch(path, { method: "POST", headers: { "content-type": "application/json" }, body: body === undefined ? undefined : JSON.stringify(body) });
    return res.json();
  };
  switch (cmd.type) {
    case "start": return { command: "start", result: await post("/api/sessions", { task: cmd.task }) };
    case "say": return { command: "say", result: await post(`/api/sessions/${cmd.session_id}/messages`, { text: cmd.text }) };
    case "approve": return { command: "approve", result: await post(`/api/executions/${cmd.execution_id}/approve`) };
    case "reject": return { command: "reject", result: await post(`/api/executions/${cmd.execution_id}/reject`) };
    case "rollback": return { command: "rollback", result: await post(`/api/executions/${cmd.execution_id}/rollback`) };
    case "set_env": { const res = await fetch(`/api/env/${encodeURIComponent(cmd.name)}`, { method: "PUT", headers: { "content-type": "application/json" }, body: JSON.stringify({ value: cmd.value }) }); return { command: "set_env", result: await res.json() }; }
    case "delete_env": { const res = await fetch(`/api/env/${encodeURIComponent(cmd.name)}`, { method: "DELETE" }); return { command: "delete_env", result: await res.json() }; }
    case "delete_tool": { const res = await fetch(`/api/tools/${encodeURIComponent(cmd.name)}`, { method: "DELETE" }); return { command: "delete_tool", result: await res.json() }; }
    case "save_snippet": return { command: "save_snippet", result: await post("/api/snippets", { name: cmd.name, description: cmd.description, execution_id: cmd.execution_id }) };
    case "run_code": return { command: "run_code", result: await post("/api/executions", { code: cmd.code, task: cmd.task }) };
  }
}

export function useServer() {
  const [state, setState] = useState<State | null>(null);
  const [transport, setTransport] = useState<Transport>("none");
  const [lastResult, setLastResult] = useState<{ command: string; result: unknown; at: number } | null>(null);
  const [notices, setNotices] = useState<Notice[]>([]);
  const wsRef = useRef<WebSocket | null>(null);

  useEffect(() => {
    let closed = false, delay = 500, timer: number | undefined;
    let ws: WebSocket | null = null, es: EventSource | null = null;

    const apply = (ev: Event) => {
      if (ev.type === "snapshot") setState(ev.state);
      else if (ev.type === "session") setState((s) => s && { ...s, sessions: upsert(s.sessions, ev.session) });
      else if (ev.type === "execution") setState((s) => s && {
        ...s,
        runtime: {
          ...s.runtime,
          executions: upsert(s.runtime.executions, ev.execution),
          connectors: s.runtime.connectors.map((c) => ({ ...c, world: ev.world.find((w) => w.name === c.name)?.world ?? c.world })),
        },
      });
      else if (ev.type === "snippets") setState((s) => s && { ...s, runtime: { ...s.runtime, snippets: ev.snippets } });
      else if (ev.type === "env") setState((s) => s && { ...s, runtime: { ...s.runtime, env: ev.names } });
      else if (ev.type === "result") setLastResult({ command: ev.command, result: ev.result, at: Date.now() });
      else if (ev.type === "notice") {
        const n: Notice = { id: Date.now() + Math.random(), execution_id: ev.execution_id, message: ev.message, at: Date.now() };
        setNotices((xs) => [...xs, n]);
        window.setTimeout(() => setNotices((xs) => xs.filter((x) => x.id !== n.id)), 9000);
      }
    };
    const retry = () => { if (closed) return; timer = window.setTimeout(() => connectSseRetry(), delay); delay = Math.min(delay * 2, 5000); };

    const connectSse = () => {
      es = new EventSource("/api/events");
      es.onopen = () => { setTransport("sse"); delay = 500; };
      es.onmessage = (m) => apply(JSON.parse(m.data) as Event);
      es.onerror = () => { es?.close(); es = null; setTransport("none"); retry(); };
    };
    const connectWs = () => {
      let opened = false;
      ws = new WebSocket(`${location.protocol === "https:" ? "wss" : "ws"}://${location.host}/ws`);
      wsRef.current = ws;
      ws.onopen = () => { opened = true; setTransport("websocket"); delay = 500; };
      ws.onmessage = (m) => apply(JSON.parse(m.data) as Event);
      ws.onclose = () => { wsRef.current = null; setTransport("none"); if (!opened) connectSse(); else retry(); };
      ws.onerror = () => ws?.close();
    };
    const tryWs = import.meta.env.VITE_TRY_WS === "1";
    const retryTarget = tryWs ? connectWs : connectSse;
    if (tryWs) connectWs(); else connectSse();
    return () => { closed = true; window.clearTimeout(timer); ws?.close(); es?.close(); };
    function connectSseRetry() { retryTarget(); }
  }, []);

  const send = (cmd: Command) => {
    const ws = wsRef.current;
    if (ws && ws.readyState === WebSocket.OPEN) { ws.send(JSON.stringify(cmd)); return; }
    void postCommand(cmd).then((r) => setLastResult({ ...r, at: Date.now() }));
  };
  return { state, online: transport !== "none", transport, send, lastResult, notices };
}
