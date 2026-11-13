#!/usr/bin/env bash
# db-backup.sh — RMAN backups of the WEL Bank database, each run logged in
# WELBANK.BACKUP_RUNS (shown on the web app's Database page).
#
# Usage:  ./scripts/db-backup.sh level0      whole database (incremental level 0) + archived logs
#         ./scripts/db-backup.sh level1      blocks changed since the last level 0 (cumulative) + logs
#         ./scripts/db-backup.sh archivelog  archived redo logs not yet backed up
#         ./scripts/db-backup.sh validate    read the backups as a restore would, write nothing
#         ./scripts/db-backup.sh keystore    copy the TDE keystore (ewallet.p12) to ./backups/keystore/
#         ./scripts/db-backup.sh status      what RMAN holds, what needs a backup, the recent runs
#
# Suggested schedule (host crontab, see BACKUP_RECOVERY.md): level0 on Sunday at
# 01:00, level1 the other nights, archivelog every four hours, keystore after any
# key change. Backups land in the Fast Recovery Area (Docker volume "fra");
# a real bank also keeps a copy on another machine (the 3-2-1 rule).

set -euo pipefail

cd "$(dirname "$0")/.."

readonly WALLET=/opt/oracle/oradata/dbconfig/FREE/tde/ewallet.p12

# The policy, applied before every run (CONFIGURE is idempotent).
readonly RMAN_CONFIG="
CONFIGURE RETENTION POLICY TO RECOVERY WINDOW OF 7 DAYS;
CONFIGURE CONTROLFILE AUTOBACKUP ON;
CONFIGURE BACKUP OPTIMIZATION ON;
CONFIGURE DEVICE TYPE DISK PARALLELISM 1 BACKUP TYPE TO COMPRESSED BACKUPSET;
CONFIGURE COMPRESSION ALGORITHM 'BASIC';
CONFIGURE ARCHIVELOG DELETION POLICY TO BACKED UP 1 TIMES TO DISK;
"

usage() {
  sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'
  exit 1
}

# Write one row in WELBANK.BACKUP_RUNS: $1 type, $2 COMPLETED|FAILED, $3 start (UTC), $4 details.
record() {
  docker compose exec -T db sqlplus -s / as sysdba <<SQL
WHENEVER SQLERROR EXIT SQL.SQLCODE
SET FEEDBACK OFF HEADING OFF
VARIABLE mb NUMBER
BEGIN
  SELECT ROUND(SUM(output_bytes) / 1048576, 1) INTO :mb
    FROM v\$rman_backup_job_details
   WHERE start_time >= TO_DATE('$3', 'YYYY-MM-DD HH24:MI:SS') - 1/1440;
END;
/
ALTER SESSION SET CONTAINER = welbank;
INSERT INTO welbank.backup_runs (run_type, status, started_at, finished_at, output_mb, details)
VALUES ('$1', '$2', TO_TIMESTAMP('$3', 'YYYY-MM-DD HH24:MI:SS'),
        GREATEST(SYS_EXTRACT_UTC(SYSTIMESTAMP), TO_TIMESTAMP('$3', 'YYYY-MM-DD HH24:MI:SS')),
        :mb, '$4');
COMMIT;
EXIT
SQL
}

# Run RMAN commands ($3) as backup type $1 described by $2, and log the outcome.
run_rman() {
  local type=$1 details=$2 commands=$3 started status
  started=$(date -u '+%Y-%m-%d %H:%M:%S')
  echo "db-backup.sh: $details (started $started UTC)"
  if docker compose exec -T db rman target / <<RMAN
$RMAN_CONFIG
$commands
EXIT;
RMAN
  then
    status=COMPLETED
  else
    status=FAILED
  fi
  record "$type" "$status" "$started" "$details"
  echo "db-backup.sh: $type $status"
  [[ $status == COMPLETED ]]
}

case "${1:-}" in
  level0)
    run_rman LEVEL0 "Full backup (incremental level 0) with archived logs" "
BACKUP INCREMENTAL LEVEL 0 DATABASE PLUS ARCHIVELOG;
DELETE NOPROMPT OBSOLETE;"
    ;;
  level1)
    run_rman LEVEL1 "Cumulative incremental (level 1) with archived logs" "
BACKUP INCREMENTAL LEVEL 1 CUMULATIVE DATABASE PLUS ARCHIVELOG;
DELETE NOPROMPT OBSOLETE;"
    ;;
  archivelog)
    run_rman ARCHIVELOG "Archived redo logs not yet backed up" "
SQL 'ALTER SYSTEM ARCHIVE LOG CURRENT';
BACKUP ARCHIVELOG ALL NOT BACKED UP 1 TIMES;"
    ;;
  validate)
    run_rman VALIDATE "Restore validation: every backup needed is present and readable" "
RESTORE DATABASE VALIDATE;
RESTORE CONTROLFILE VALIDATE;"
    ;;
  keystore)
    # Only the password-protected keystore is copied, never cwallet.sso (the
    # auto-login file opens the keys without a password). Keep this copy apart
    # from the database backups: a thief with both could read the data.
    umask 077
    mkdir -p backups/keystore
    stamp=$(date -u '+%Y%m%dT%H%M%SZ')
    docker compose exec -T db cat "$WALLET" > "backups/keystore/ewallet-$stamp.p12"
    if [[ ! -s "backups/keystore/ewallet-$stamp.p12" ]]; then
      echo "db-backup.sh: could not read $WALLET" >&2
      exit 1
    fi
    echo "db-backup.sh: keystore copied to backups/keystore/ewallet-$stamp.p12 (git-ignored, mode 600)"
    ;;
  status)
    docker compose exec -T db rman target / <<RMAN
LIST BACKUP SUMMARY;
REPORT NEED BACKUP;
REPORT OBSOLETE;
EXIT;
RMAN
    docker compose exec -T db sqlplus -s / as sysdba <<'SQL'
SET LINESIZE 160 PAGESIZE 50 FEEDBACK OFF
ALTER SESSION SET CONTAINER = welbank;
COLUMN run_type FORMAT A13
COLUMN details FORMAT A60
SELECT run_id, run_type, status, TO_CHAR(started_at, 'YYYY-MM-DD HH24:MI') AS started_utc,
       output_mb, details
  FROM welbank.backup_runs ORDER BY run_id DESC FETCH FIRST 10 ROWS ONLY;
EXIT
SQL
    ;;
  *)
    usage
    ;;
esac
