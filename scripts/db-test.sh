#!/usr/bin/env bash
# db-test.sh — run the database tests (database/tests/*_test.sql).
#
# Usage:  ./scripts/db-test.sh
#
# What happens: this runs database/tests/run_tests.sh inside the container. Each
# test file checks that the schema accepts good rows and rejects bad ones, inside
# a transaction that is rolled back, so the database is left unchanged.
# Exit code 0 means every check passed.
#
# Run it after every ./scripts/db-migrate.sh update, and before every commit
# that touches database/.

set -euo pipefail

cd "$(dirname "$0")/.."

exec docker compose exec -T db bash /opt/welbank/database/tests/run_tests.sh
