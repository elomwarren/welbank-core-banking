#!/usr/bin/env bash
# db-security.sh — create or update the bank's Oracle security:
#   * roles, the WB_EMPLOYEE password rules, the WB_APP proxy account and the
#     Unified Auditing policies (database/security/security.sql);
#   * one Oracle user per employee, with the roles of their job
#     (database/security/staff_users.sql), once employees exist.
#
# Usage:  ./scripts/db-security.sh                    # create what is missing
#         ./scripts/db-security.sh --reset-passwords  # also set every employee's
#                                                     # password back to secrets/staff_demo_pwd.txt
#
# Safe to run again at any time. On a new database the order is:
#   db-security.sh  ->  db-migrate.sh update  ->  db-seed.sh  ->  db-security.sh
# (the roles must exist before the migration grants to them; the employees'
# users can only be made once the seed has created the employees).

set -euo pipefail

cd "$(dirname "$0")/.."

secrets_dir=${WELBANK_SECRETS_DIR:-secrets}
reset=NO
if [[ "${1:-}" == "--reset-passwords" ]]; then
  reset=YES
fi

for name in wb_app_pwd staff_demo_pwd; do
  if [[ ! -s "$secrets_dir/$name.txt" ]]; then
    echo "db-security.sh: $secrets_dir/$name.txt is missing; run ./scripts/init-secrets.sh first" >&2
    exit 1
  fi
done
app_pwd=$(<"$secrets_dir/wb_app_pwd.txt")
staff_pwd=$(<"$secrets_dir/staff_demo_pwd.txt")

# The passwords travel on standard input (here-documents), never on a command
# line, so they do not show in `ps` or in the shell history.
docker compose exec -T db sqlplus -s / as sysdba <<SQL
WHENEVER SQLERROR EXIT SQL.SQLCODE
DEFINE app_pwd = "${app_pwd}"
@/opt/welbank/database/security/security.sql
EXIT
SQL

ready=$(docker compose exec -T db sqlplus -s / as sysdba <<'SQL' || true
SET HEADING OFF FEEDBACK OFF PAGESIZE 0
ALTER SESSION SET CONTAINER = welbank;
SELECT 'READY' FROM dba_tables t
 WHERE t.owner = 'WELBANK' AND t.table_name = 'JOB_ROLES'
   AND EXISTS (SELECT 1 FROM dba_tables WHERE owner = 'WELBANK' AND table_name = 'EMPLOYEES');
EXIT
SQL
)

if [[ "$ready" == *READY* ]]; then
  docker compose exec -T db sqlplus -s / as sysdba <<SQL
WHENEVER SQLERROR EXIT SQL.SQLCODE
DEFINE staff_pwd = "${staff_pwd}"
DEFINE reset_passwords = "${reset}"
@/opt/welbank/database/security/staff_users.sql
EXIT
SQL
else
  echo "db-security.sh: no employees table yet; run db-migrate.sh update (and db-seed.sh), then this script again"
fi
