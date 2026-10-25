#!/bin/bash
# =============================================================================
# 03_bootstrap.sh — run the schema bootstrap on a brand-new database.
#
# When:  once, after 02_welbank_pdb.sh (sourced by the image's runUserScripts.sh).
# What:  calls database/bootstrap/bootstrap.sh, the same script that
#        scripts/db-bootstrap.sh runs by hand on an existing database, so
#        new and existing databases end up identical.
# =============================================================================

# Sourced by the image's start-up script: run in a subshell so `exit` / `set -e`
# cannot stop the container's own script. The exit code is checked on a separate
# line (see 01_recovery_area.sh for why `( ... ) || echo ERROR` is wrong).
(
  set -euo pipefail
  echo "[welbank] Running the schema bootstrap"
  bash /opt/welbank/database/bootstrap/bootstrap.sh
  echo "[welbank] Schema bootstrap done"
)
welbank_rc=$?
if [[ $welbank_rc -ne 0 ]]; then
  echo "[welbank] ERROR: 03_bootstrap.sh failed with exit code ${welbank_rc} (see the messages above)"
fi
