// Thin client for the BAML server (baml_src/server.baml). The page is only a
// view: it starts sessions, approves/rejects, rolls back, and polls /api/state.

export type Json = null | boolean | number | string | Json[] | { [k: string]: Json };

export type ConnectorView = { name: string; description: string; api: string; world: Json };
export type LogEntry = {
  seq: number; kind: "call" | "step"; connector: string; method: string; args: Json;
  state: "Pending" | "Approved" | "Executing" | "Applied" | "Rejected" | "Reverted" | "RevertFailed";
  result: Json; error: string | null; replay: "Record" | "Reexecute"; requires_approval: boolean; pass: number; recorded_at: string;
};
export type FixRecord = { attempt: number; code: string; diagnostics: string; thought: string };
export type ToolView = { path: string; connector: string; name: string; kind: "method" | "snippet"; signature: string; docstring: string | null; requires_approval: boolean; reversible: boolean; replay: "Record" | "Reexecute" };
export type Execution = {
  id: string; task: string; code: string; fix_log: FixRecord[]; discovered: string[]; publish_as: string | null; publish_description: string | null;
  status: "Running" | "Paused" | "Completed" | "Error" | "Rejected" | "RolledBack";
  log: LogEntry[]; result: Json; error: string | null; logs: string[]; connectors: string[];
  pass_count: number; cursor: number; created_at: string; updated_at: string;
};
export type Snippet = { name: string; description: string; code: string; connectors: string[]; source_execution_id: string; created_at: string; api: string | null };
export type Turn = { thought: string; code: string; execution_id: string; outcome: string; message_index: number };
export type Message = { role: "user" | "assistant"; text: string };
export type Session = {
  id: string; task: string; messages: Message[]; turns: Turn[];
  status: "thinking" | "executing" | "paused" | "done" | "error";
  answer: string | null; thought: string | null; current_execution_id: string | null; created_at: string; updated_at: string;
};
export type State = {
  runtime: { name: string; executions: Execution[]; snippets: Snippet[]; connectors: ConnectorView[]; tools: ToolView[]; env: string[] };
  sessions: Session[]; started_at: string;
};
export type Outcome =
  | { status: "completed"; execution_id: string; result: Json; logs: string[] }
  | { status: "paused"; execution_id: string; pending: { execution_id: string; seq: number; connector: string; method: string; args: Json }[] }
  | { status: "error"; execution_id: string; error: string; logs: string[] };
export type RollbackReport = { execution_id: string; status: Execution["status"]; reverted: number; failures: string[]; skipped: string[] };

async function req<T>(method: string, path: string, body?: unknown): Promise<T> {
  const res = await fetch(path, { method, headers: { "content-type": "application/json" }, body: body === undefined ? undefined : JSON.stringify(body) });
  const text = await res.text();
  try { return JSON.parse(text) as T; } catch { throw new Error(`bad response from BAML server: ${text.slice(0, 200)}`); }
}

export const api = {
  state: () => req<State>("GET", "/api/state"),
  startSession: (task: string) => req<Session>("POST", "/api/sessions", { task }),
  runCode: (code: string, task: string) => req<Outcome>("POST", "/api/executions", { code, task }),
  approve: (id: string) => req<Outcome>("POST", `/api/executions/${id}/approve`),
  reject: (id: string) => req<Outcome>("POST", `/api/executions/${id}/reject`),
  rollback: (id: string) => req<RollbackReport>("POST", `/api/executions/${id}/rollback`),
  saveSnippet: (name: string, description: string, execution_id: string) => req<Snippet | { error: string }>("POST", "/api/snippets", { name, description, execution_id }),
};
