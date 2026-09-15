# Code Mode, in pure BAML

A reproduction of Cloudflare's [Code Mode](https://developers.cloudflare.com/agents/tools/codemode/how-it-works/)
where **everything runs inside one BAML process**: the model writes **BAML**, the server compiles it at
runtime with `reflect.Package.compile`, runs it in-process against typed connector façades, and keeps a
durable execution log with approvals via abort-and-replay, replay-divergence detection, rollback, and
snippets. The React page in `web/` is only a view: it receives every state change as an event over a
WebSocket (`/ws`) and sends commands back on it. No polling, no code in the browser.

```
 model ──AgentStep{code}──▶ BAML server ──reflect.Package.compile(code, {host: current()})──▶ run(codemode)
                                │                                                                │
                                │   codemode.crm.list_customers(plan = "pro")  ◀── typed façade ─┘
                                │   Runtime.on_call → seq #n → replay | execute | throw PausedForApproval
                                │
                          web/ (Vite+React) ◀── events over /ws (or /api/events SSE) ── commands ──▶
```

## Run it

```bash
./dev.sh            # BAML server on :8787 + Vite on :5173
```

Code generation (`NextStep` and `FixCode` in `baml_src/agent.baml`) runs on the local Claude Code CLI
with Sonnet (`claude_code.ClaudeCodeClient`), no API key needed. The prompt includes the BAML agent
skill from `.claude/skills/baml-core/SKILL.md` as the language reference, so keep it in sync with the
pinned toolchain via `baml agent install`. Inside its code the model can also ask for docs on any
stdlib path, `codemode.describe("baml.fs")`, which runs `baml describe` on the server.
Open http://localhost:5173 and pick a task.
Deep links: `/?task=<url-encoded>&auto=approve` runs a task on load and approves everything;
`/?session=<id>` reopens a finished run (ids are in the History tab); `/?tab=tools|history` picks the right-hand tab.
The page is deliberately plain and large for a projector: one story on the left, three reference tabs on the right.

## Secrets: the env vault

The **Env** tab stores names and values in the BAML server (`.codemode/env.json`, mode 600). Values are
never sent to the browser or the model; only names are. Model code reads them with
`codemode.env.get("GITHUB_TOKEN")`. If the variable is not set, the execution pauses like an approval:
the story shows "The code needs GITHUB_TOKEN" with a password field, *Save and continue* stores it and
re-runs the code (earlier calls replay, `env.get` now succeeds). `env.get` uses the re-execute replay
policy so values never enter the durable log, and every stored value is replaced by `«ENV:NAME»` in
results, logs, and error messages before they reach the model or the page.
`CODEMODE_ENV_IMPORT=GITHUB_TOKEN,OTHER ./dev.sh` seeds the vault from the process environment.

## What to show

1. **One tool, discovered by code.** The model's first program calls `codemode.search("…")` and
   `codemode.describe("billing")`; `describe` renders real BAML declarations from `reflect.signature`
   and `reflect.Type.of<T>()` (`baml_src/sandbox.baml`). The catalog never enters the prompt.
2. **The model writes BAML.** `function run(codemode: host.Codemode) -> AnyType { … }`: it can return a
   class it defines in the same source; the runtime calls `.to_json()` on whatever comes back.
3. **Compile errors are repaired in place.** If the source doesn't compile, `Runtime.run_pass` runs an
   inner loop: diagnostics → `FixCode` (a focused LLM function) → recompile, up to three attempts. Each
   attempt is a `notice` event (a toast in the UI) and a `FixRecord` on the execution with the broken
   source, the diagnostics, and the model's one-line explanation. The agent loop never sees the failure.
4. **Snippets are typed packages.** *Save as snippet* compiles the execution into a `reflect.Package`
   that is passed into every later compile as a dependency. The model calls `enterprise_names.run(codemode)`
   with real types, `describe("enterprise_names")` renders its functions from `Package.functions()`, and
   the Tools tab lists them next to the connector methods.
5. **Tools are listed by reflection.** The Tools tab is built from `reflect.signature` on each façade
   method (name, parameters, defaults, return type, `///` docstring) plus each snippet package's
   functions. Tools the model has looked up in the current session are marked *found*.
6. **Approvals = abort + replay.** `email.send`, `update_plan`, `issue_refund` need approval. The façade
   call reaches `Runtime.on_call`, which records the entry as *Pending* and throws `PausedForApproval`;
   the pass unwinds. Approve → the same code runs again; earlier calls are answered from the log
   (dimmed, "answered from log"), the approved call executes, the code continues.
7. **Deterministic replay.** Same seq must see the same connector/method/args (structural `==`), or
   `ReplayDivergence`. `codemode.step("name", () -> { … })` records nondeterministic values.
8. **Rollback.** Execution log → *Roll back* walks applied calls in reverse and calls each connector's
   `revert`. Watch Live data change back.
9. **Panics, errors, limits.** Out-of-bounds in generated code is caught via `spawn` + `all_settled`;
   uncaught connector errors end the execution; history is pruned at 50; `.codemode/*.json` survives restarts.

## Layout

| file | role |
|---|---|
| `baml_src/agent.baml` | `NextStep` and `FixCode` LLM functions, the shared `codemode_surface` / `baml_cheatsheet` prompt text, the agent loop on a detached green thread, sessions, WebSocket/SSE fan-out |
| `baml_src/sandbox.baml` | `Codemode` object handed to generated code: `search/describe/step/run` + typed façades `crm/billing/email/github`; `compile_run` via reflection |
| `baml_src/runtime.baml` | `Runtime`: executions, `LogEntry` with seq/state/pass, `run_pass`, `on_call` (the interception point), approve/reject/rollback, snippets, prune/expire, persistence |
| `baml_src/connectors.baml` | `Connector` interface (`call`, `revert`, `on_pass_end`, `dispose_execution`) and four connectors with typed results |
| `baml_src/server.baml` | HTTP routes over `baml.http.Server`, typed `StateView` |
| `web/src/App.tsx` | timeline derived from server state, approvals, Live data / Execution log / Snippets / Tools |

## Live events

`GET /ws` upgrades to a WebSocket. The server sends `{type:"snapshot", state}` on connect, then one event
per change: `{type:"session", session}`, `{type:"execution", execution, world}`, `{type:"snippets", snippets}`,
and `{type:"result", command, result}` in reply to a command. Commands are JSON frames:
`{type:"start", task}`, `{type:"approve"|"reject"|"rollback", execution_id}`,
`{type:"save_snippet", execution_id, name, description}`, `{type:"run_code", code, task}`.
`node scripts/ws-client.mjs "task"` drives a whole session from the terminal this way;
`python3 scripts/session.py "task"` does the same over HTTP, and `python3 scripts/direct.py` runs the
hand-written runtime scenarios (no model). `CODEMODE_API=http://127.0.0.1:8788` points the scripts and
`pnpm dev` at another server.

`GET /api/events` streams the same events as Server-Sent Events with commands over the POST routes below.
The page uses SSE by default; `VITE_TRY_WS=1 pnpm dev` makes it try the WebSocket first (expect Vite to log
"ws proxy error: write EPIPE" while the BAML bug below stands; the page falls back to SSE).

**Known issue (0.19.0, 0.19.1-nightly.20260911.a, 0.18.1-nightly.20260909.a; feedback e1911bc9):** the `websocket` handler runs and
returns its `WsAccept` closure exactly as the stdlib docs show, but the engine answers 500
"websocket handler failed" before the 101. The SSE path is what the demo runs on today; the WebSocket
code is in place for when a nightly fixes it. Minimal repro: a `serve(handler, websocket = (req) -> {
(socket) -> { } })` and any client upgrade.

## API

```
GET  /api/events                             Server-Sent Events, same events as /ws
GET  /api/state                              everything the UI renders
POST /api/sessions {task}                    start the agent loop (background), returns the session
POST /api/executions {code, task}            run BAML directly, no model (synchronous outcome)
POST /api/executions/:id/approve | reject | rollback
POST /api/snippets {name, description, execution_id}   save an execution as a tool by hand
GET  /api/env                                names of stored variables (values are write-only)
PUT  /api/env/:name {value} · DELETE /api/env/:name   (also `set_env` / `delete_env` WebSocket commands)
GET  /api/tools                              every tool (connector methods + saved tools), by reflection
GET  /api/tools/:name                        one saved tool: source, functions, executions that use it
DELETE /api/tools/:name                      remove a saved tool (also the `delete_tool` WebSocket command)
POST /api/maintenance/expire {max_age_seconds} · /api/maintenance/prune
```

## Toolchain notes

The project is pinned to **0.19.0** in `baml.toml` (`[toolchain] version`), so your global `nightly`
selector is free to move. Everything below was verified on 0.19.0 and 0.19.1-nightly.20260911.a.
The WebSocket accept bug is filed as BAML feedback `e1911bc9` (repro in `repro/ws_accept.baml`).

- A package used as a `reflect.Package.compile` dependency cannot contain `type` aliases, and its methods
  cannot have string-literal parameter defaults. Unions are inlined; optional params default to `null`.
- Extract the entry point with `get_function<reflect.AnyFunction<Returns = json, Throws = unknown>>` and
  call it with `reflect.call_any`; function-type literals don't parse in generic arguments.
- Generated code is isolated as a package but not as a security boundary: it can still reach the BAML
  stdlib. Treat this as the "pretend sandbox".
- Started from inside a Claude Code session? `dev.sh` unsets the nested-session env vars so the CLI
  fallback can run.
