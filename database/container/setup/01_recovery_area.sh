#!/bin/bash
# =============================================================================
# 01_recovery_area.sh — move the Fast Recovery Area (FRA) to its own volume.
#
# When:  once, right after the image creates the database.
# How:   the image's runUserScripts.sh *sources* every .sh file in
#        /opt/oracle/scripts/setup, in name order, as the "oracle" user.
# Why:   the database runs in ARCHIVELOG mode. Archived redo logs, RMAN backups
#        and flashback logs all go to the FRA. Keeping the FRA on a separate
#        Docker volume (welbank_fra) means losing the data volume does not also
#        lose the backups needed to rebuild it.
# =============================================================================

# This file is sourced by the image's start-up script, so the work runs in a
# subshell: an `exit` or `set -e` failure here must not stop the container itself.
(
  set -euo pipefail
  fra_size="${WELBANK_FRA_SIZE:-20G}"
  echo "[welbank] Setting the Fast Recovery Area to /opt/oracle/fra (quota ${fra_size})"

  sqlplus -s / as sysdba <<SQL
WHENEVER SQLERROR EXIT SQL.SQLCODE
SET DEFINE OFF
-- The quota must be set before the destination.
ALTER SYSTEM SET db_recovery_file_dest_size = ${fra_size} SCOPE = BOTH;
ALTER SYSTEM SET db_recovery_file_dest = '/opt/oracle/fra' SCOPE = BOTH;
-- Switch and archive the current redo log so the first archived log lands in the new FRA.
ALTER SYSTEM ARCHIVE LOG CURRENT;
SQL

  echo "[welbank] Fast Recovery Area configured"
) || echo "[welbank] ERROR: 01_recovery_area.sh failed (see the messages above)"
