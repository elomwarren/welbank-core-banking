#!/usr/bin/env bash
# =============================================================================
# sql-session.sh — open an interactive SQLcl session, with no password to type.
#
# Runs INSIDE the database container, as the "oracle" user. Called from the
# host by scripts/db-sql.sh.
#
#   welbank (default)  SYSDBA, already switched into the WELBANK pluggable database
#   root               SYSDBA in the root container (CDB$ROOT)
#   deploy             WB_DEPLOY acting as WELBANK (proxy): you see the schema
#                      exactly as its owner does, e.g. SELECT * FROM user_tables
#
# How the password is avoided:
#   - SYSDBA uses operating-system authentication: inside the container, the
#     "oracle" OS user is trusted by the database, so no password exists to type.
#   - deploy reads WB_DEPLOY's password from the Docker secret and writes the
#     CONNECT command into a temporary login script (readable only by oracle,
#     in the container's private /tmp). SQLcl runs it and the script deletes
#     itself straight after connecting. The password never appears on a
#     command line, so `ps` cannot show it.
#
# SQLcl rather than SQL*Plus: arrow keys recall previous commands, Tab
# completes table and column names, and results print as aligned tables.
# =============================================================================

set -euo pipefail

readonly SERVICE=//localhost:1521/WELBANK
readonly SECRET_FILE=/run/secrets/wb_deploy_pwd
export JAVA_HOME="${ORACLE_HOME}/jdk"

mode="${1:-welbank}"

umask 077
login=$(mktemp /tmp/welbank-login.XXXXXX.sql)

case "$mode" in
  welbank)
    cat >"$login" <<'SQL'
connect / as sysdba
ALTER SESSION SET CONTAINER = welbank;
SET SQLPROMPT "SYS@WELBANK> "
SQL
    ;;
  root)
    cat >"$login" <<'SQL'
connect / as sysdba
SET SQLPROMPT "SYS@CDB$ROOT> "
SQL
    ;;
  deploy)
    if [[ ! -r "$SECRET_FILE" ]]; then
      rm -f "$login"
      echo "ERROR: $SECRET_FILE is missing. Run ./scripts/init-secrets.sh, then 'docker compose up -d'." >&2
      exit 1
    fi
    printf 'connect wb_deploy[welbank]/"%s"@%s\nSET SQLPROMPT "WELBANK(via WB_DEPLOY)> "\n' \
      "$(<"$SECRET_FILE")" "$SERVICE" >"$login"
    ;;
  *)
    rm -f "$login"
    echo "usage: sql-session.sh [welbank | root | deploy]" >&2
    exit 2
    ;;
esac

# Common settings, then the login script deletes itself.
cat >>"$login" <<SQL
SET SQLFORMAT ansiconsole
SET FEEDBACK ON
host rm -f ${login}
SQL

exec "${ORACLE_HOME}/sqlcl/bin/sql" -L /nolog @"$login"
