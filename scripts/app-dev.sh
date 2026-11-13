#!/usr/bin/env bash
# app-dev.sh — run the web app for development: the API on 127.0.0.1:8000 (reloads
# when backend/app changes) and the SvelteKit dev server on 127.0.0.1:5173, which
# forwards /api to the API.
#
# Usage:  ./scripts/app-dev.sh      then open http://127.0.0.1:5173   (Ctrl+C stops both)
#
# The database must be running (docker compose up -d) with the security layer in
# place (./scripts/db-security.sh). Log in with an employee's user name and the
# development password in secrets/staff_demo_pwd.txt.

set -euo pipefail

cd "$(dirname "$0")/.."

(cd backend && uv sync --quiet)
if [[ ! -d frontend/node_modules ]]; then
  (cd frontend && npm ci)
fi

# Stop both servers when this script ends (Ctrl+C included).
trap 'kill 0' EXIT

(cd backend && uv run uvicorn app.main:app --host 127.0.0.1 --port 8000 --reload --reload-dir app) &
(cd frontend && npm run dev -- --host 127.0.0.1 --port 5173) &
wait
