#!/usr/bin/env bash
# =============================================================================
# bootstrap.sh — run bootstrap.sql as SYSDBA with the deployment password.
#
# Runs INSIDE the database container, as the "oracle" user:
#   - by hand, via scripts/db-bootstrap.sh on the host;
#   - automatically on a brand-new database, via setup/03_bootstrap.sh.
# =============================================================================

set -euo pipefail

readonly SECRET_FILE=/run/secrets/wb_deploy_pwd
readonly SQL_FILE=/opt/welbank/database/bootstrap/bootstrap.sql

if [[ ! -r "$SECRET_FILE" ]]; then
  echo "ERROR: $SECRET_FILE is missing. Run ./scripts/init-secrets.sh, then 'docker compose up -d'." >&2
  exit 1
fi

deploy_pwd=$(<"$SECRET_FILE")

# The password reaches SQL*Plus through standard input (DEFINE), never as a
# command-line argument, and bootstrap.sql sets VERIFY OFF so it is never echoed.
sqlplus -s / as sysdba <<SQL
DEFINE deploy_pwd = "${deploy_pwd}"
@${SQL_FILE}
EXIT
SQL
