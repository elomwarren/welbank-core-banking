#!/usr/bin/env bash
# db-restore-point.sh — named points in time for the WELBANK pluggable database,
# and Flashback to rewind it to one (for example after a demonstration).
#
# Usage:  ./scripts/db-restore-point.sh create NAME          guaranteed restore point now
#         ./scripts/db-restore-point.sh list                 the restore points
#         ./scripts/db-restore-point.sh drop NAME            remove one (frees its flashback logs)
#         ./scripts/db-restore-point.sh flashback NAME --yes rewind WELBANK to it
#
# Flashback closes WELBANK for a few seconds and throws away everything done
# since the restore point (the audit trail included), so it asks for --yes.
# A guaranteed restore point keeps flashback logs in the Fast Recovery Area
# until it is dropped: drop the ones you no longer need.

set -euo pipefail

cd "$(dirname "$0")/.."

action=${1:-}
name=${2:-}

usage() {
  sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
  exit 1
}

check_name() {
  if [[ ! "$name" =~ ^[A-Za-z][A-Za-z0-9_]{0,29}$ ]]; then
    echo "db-restore-point.sh: a name is a letter then letters, digits or _ (max 30)" >&2
    exit 1
  fi
}

sql_root() {
  { printf 'WHENEVER SQLERROR EXIT SQL.SQLCODE\nSET LINESIZE 160 PAGESIZE 50 FEEDBACK ON\n'; cat; printf '\nEXIT\n'; } \
    | docker compose exec -T db sqlplus -s / as sysdba
}

case "$action" in
  create)
    check_name
    sql_root <<<"CREATE RESTORE POINT $name FOR PLUGGABLE DATABASE welbank GUARANTEE FLASHBACK DATABASE;"
    ;;
  drop)
    check_name
    sql_root <<<"DROP RESTORE POINT $name FOR PLUGGABLE DATABASE welbank;"
    ;;
  list)
    sql_root <<'SQL'
COLUMN name FORMAT A30
SELECT name, TO_CHAR(time, 'YYYY-MM-DD HH24:MI:SS') AS created, guarantee_flashback_database AS guaranteed,
       ROUND(storage_size / 1048576) AS mb
  FROM v$restore_point ORDER BY time;
SQL
    ;;
  flashback)
    check_name
    if [[ "${3:-}" != "--yes" ]]; then
      echo "db-restore-point.sh: this discards everything done in WELBANK since $name; add --yes to proceed" >&2
      exit 1
    fi
    sql_root <<SQL
ALTER PLUGGABLE DATABASE welbank CLOSE IMMEDIATE;
FLASHBACK PLUGGABLE DATABASE welbank TO RESTORE POINT $name;
ALTER PLUGGABLE DATABASE welbank OPEN RESETLOGS;
SQL
    echo "db-restore-point.sh: WELBANK is back at restore point $name"
    ;;
  *)
    usage
    ;;
esac
