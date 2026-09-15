#!/bin/bash
# Starts the BAML server (8787) and the Vite frontend (5173) together.
set -e
cd "$(dirname "$0")"
# If launched from inside a Claude Code session, drop its nested-session vars so
# the local `claude` CLI fallback can run.
unset ANTHROPIC_API_KEY
unset CLAUDECODE CLAUDE_CODE_ENTRYPOINT CLAUDE_CODE_SESSION_ID CLAUDE_CODE_CHILD_SESSION CLAUDE_PID
baml run main --log info &
BAML_PID=$!
trap 'kill $BAML_PID 2>/dev/null' EXIT
(cd web && pnpm dev)
