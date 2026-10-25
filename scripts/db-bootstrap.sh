#!/usr/bin/env bash
# db-bootstrap.sh — create (or re-sync) the accounts and storage the schema needs.
#
# Usage:  ./scripts/db-bootstrap.sh
#
# What happens: this runs database/bootstrap/bootstrap.sh inside the container, as SYSDBA, which:
#   - creates the encrypted WELBANK_DOCS tablespace (KYC pictures);
#   - creates WELBANK, the schema owner, as a schema-only account (it cannot log in);
#   - creates WB_DEPLOY, the deployment account, and lets it connect *as* WELBANK (proxy);
#   - sets WB_DEPLOY's password from secrets/wb_deploy_pwd.txt.
#
# Safe to run again at any time: anything that already exists is left alone, and the
# password is simply re-synced (useful after changing the secret file).
#
# New databases run this automatically on first start (database/container/setup/03_bootstrap.sh);
# run it by hand on a database created before it existed.

set -euo pipefail

cd "$(dirname "$0")/.."

exec docker compose exec -T db bash /opt/welbank/database/bootstrap/bootstrap.sh
