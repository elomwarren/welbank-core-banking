#!/usr/bin/env bash
# db-seed.sh — fill an EMPTY database with synthetic, census-shaped data.
#
# Usage:  ./scripts/db-seed.sh [--customers 2000] [--months 24]
#
# What happens:
#   1. database/seed/generate_seed.py (Python, no dependencies) writes
#      database/seed/build/seed.sql: reference data, staff, and the customers
#      of each simulated month, onboarded through pkg_customer / pkg_account.
#   2. SQL*Plus inside the container runs it as SYSDBA in WELBANK; each month
#      it calls database/seed/sql/simulate_month.sql (deposits, withdrawals,
#      transfers, loans, repayments, end of day, all through the packages).
# The full default load takes about 90 minutes. It refuses to run on a database
# that already has customers; see database/seed/README.md to start again.

set -euo pipefail

cd "$(dirname "$0")/.."

python3 database/seed/generate_seed.py "$@"

started=$SECONDS
docker compose exec -T db bash -c 'sqlplus -s / as sysdba <<SQL
WHENEVER SQLERROR EXIT SQL.SQLCODE
ALTER SESSION SET CONTAINER = welbank;
@/opt/welbank/database/seed/build/seed.sql
SQL'
echo "db-seed.sh: loaded in $(( (SECONDS - started) / 60 )) min $(( (SECONDS - started) % 60 )) s"
