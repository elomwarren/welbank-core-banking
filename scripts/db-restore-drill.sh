#!/usr/bin/env bash
# db-restore-drill.sh — practise a media recovery without risking the bank's data.
#
# Usage:  ./scripts/db-restore-drill.sh
#
# The drill:
#   1. creates a small tablespace WB_DRILL (encrypted, like every tablespace here)
#      with a table of 5,000 rows, and backs its datafile up with RMAN;
#   2. adds 1,000 rows AFTER the backup, so only the redo logs hold them;
#   3. takes the datafile offline and DELETES it, then shows that Oracle cannot
#      find it (ORA-01157);
#   4. restores the file from the backup and recovers it from the redo logs;
#   5. checks that all 6,000 rows are back, logs the result in BACKUP_RUNS,
#      and drops the drill tablespace.
# The WELBANK tablespaces are never touched. Takes about a minute.

set -euo pipefail

cd "$(dirname "$0")/.."

readonly DATAFILE=/opt/oracle/oradata/FREE/WELBANK/wb_drill01.dbf
started=$(date -u '+%Y-%m-%d %H:%M:%S')

sql_pdb() {  # run SQL (stdin) as SYSDBA inside WELBANK, print only the results
  { printf 'WHENEVER SQLERROR EXIT SQL.SQLCODE\nSET HEADING OFF FEEDBACK OFF PAGESIZE 0 VERIFY OFF\nALTER SESSION SET CONTAINER = welbank;\n'; cat; printf '\nEXIT\n'; } \
    | docker compose exec -T db sqlplus -s / as sysdba
}

echo "== 1. A tablespace with 5,000 rows, and its backup"
file_no=$(sql_pdb <<SQL | tr -d '[:space:]'
DECLARE
  n PLS_INTEGER;
BEGIN
  SELECT COUNT(*) INTO n FROM dba_tablespaces WHERE tablespace_name = 'WB_DRILL';
  IF n > 0 THEN
    EXECUTE IMMEDIATE 'DROP TABLESPACE wb_drill INCLUDING CONTENTS AND DATAFILES';
  END IF;
  SELECT COUNT(*) INTO n FROM dba_users WHERE username = 'WB_DRILL';
  IF n > 0 THEN
    EXECUTE IMMEDIATE 'DROP USER wb_drill CASCADE';
  END IF;
END;
/
CREATE TABLESPACE wb_drill DATAFILE '$DATAFILE' SIZE 20M;
CREATE USER wb_drill NO AUTHENTICATION DEFAULT TABLESPACE wb_drill QUOTA UNLIMITED ON wb_drill;
CREATE TABLE wb_drill.evidence TABLESPACE wb_drill AS
  SELECT LEVEL AS n, SYSTIMESTAMP AS written_at FROM dual CONNECT BY LEVEL <= 5000;
SELECT file_id FROM dba_data_files WHERE tablespace_name = 'WB_DRILL';
SQL
)
echo "   datafile number: $file_no"
docker compose exec -T db rman target / <<RMAN >/dev/null
BACKUP DATAFILE $file_no;
EXIT;
RMAN
echo "   backed up"

echo "== 2. 1,000 more rows, only in the redo logs"
sql_pdb <<'SQL'
INSERT INTO wb_drill.evidence SELECT 5000 + LEVEL, SYSTIMESTAMP FROM dual CONNECT BY LEVEL <= 1000;
COMMIT;
SQL

echo "== 3. The datafile is lost"
sql_pdb <<SQL
ALTER DATABASE DATAFILE $file_no OFFLINE;
SQL
docker compose exec -T db rm -f "$DATAFILE"
if sql_pdb <<<"ALTER DATABASE DATAFILE $file_no ONLINE;" 2>&1 | grep -m1 -E 'ORA-0115[17]'; then
  echo "   (expected: Oracle cannot find the file)"
fi

echo "== 4. Restore from the backup, recover from the redo logs"
docker compose exec -T db rman target / <<RMAN | grep -E 'Starting|Finished|restoring|media recovery complete|RMAN-' || true
RESTORE DATAFILE $file_no;
RECOVER DATAFILE $file_no;
EXIT;
RMAN

echo "== 5. Check"
rows=$(sql_pdb <<SQL | tr -d '[:space:]'
ALTER DATABASE DATAFILE $file_no ONLINE;
SELECT COUNT(*) FROM wb_drill.evidence;
SQL
)
if [[ "$rows" == 6000 ]]; then
  status=COMPLETED
  details="Datafile $file_no deleted, restored by RMAN and recovered from redo: 6000 of 6000 rows back"
else
  status=FAILED
  details="Datafile $file_no: expected 6000 rows after recovery, found ${rows:-none}"
fi
echo "   $details"

sql_pdb <<SQL
DROP TABLESPACE wb_drill INCLUDING CONTENTS AND DATAFILES;
DROP USER wb_drill CASCADE;
INSERT INTO welbank.backup_runs (run_type, status, started_at, finished_at, details)
VALUES ('RESTORE_DRILL', '$status', TO_TIMESTAMP('$started', 'YYYY-MM-DD HH24:MI:SS'),
        GREATEST(SYS_EXTRACT_UTC(SYSTIMESTAMP), TO_TIMESTAMP('$started', 'YYYY-MM-DD HH24:MI:SS')),
        '$details');
COMMIT;
SQL
echo "db-restore-drill.sh: $status"
[[ $status == COMPLETED ]]
