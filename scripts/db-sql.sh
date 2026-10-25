#!/usr/bin/env bash
# db-sql.sh — open an interactive SQL session (SQLcl) in the database container.
# Nothing to type or paste: no password is needed.
#
# Usage:  ./scripts/db-sql.sh [mode]
#
#   welbank (default)  SYSDBA inside the WELBANK pluggable database
#   root               SYSDBA in the root container (CDB$ROOT)
#   deploy             WB_DEPLOY acting as the schema owner WELBANK (proxy)
#
# Inside the session: type SQL ending with ";", use the up/down arrow keys for
# earlier commands, Tab to complete names, and "exit" to leave.
#
# What happens: this runs database/tools/sql-session.sh inside the container
# with a terminal attached (docker compose exec, without -T).

set -euo pipefail

cd "$(dirname "$0")/.."

exec docker compose exec db bash /opt/welbank/database/tools/sql-session.sh "$@"
