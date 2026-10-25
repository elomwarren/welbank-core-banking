#!/usr/bin/env bash
# =============================================================================
# run_tests.sh — run every database/tests/*_test.sql file and add up the results.
#
# Runs INSIDE the database container, as the "oracle" user (called from the
# host by scripts/db-test.sh). Each test file:
#   - runs as SYSDBA inside the WELBANK pluggable database;
#   - works in one transaction and rolls it back, leaving no data behind;
#   - prints PASS / FAIL lines and a final "RESULT: <p> passed, <f> failed".
# Exit code: 0 only if every check of every file passed.
# =============================================================================

set -euo pipefail

readonly TEST_DIR=/opt/welbank/database/tests

total_passed=0
total_failed=0
broken_files=0

for test_file in "$TEST_DIR"/*_test.sql; do
  echo "=== $(basename "$test_file")"

  # A failing check does not stop SQL*Plus; an unexpected SQL error does (the
  # file is then reported as BROKEN below).
  output=$(sqlplus -s / as sysdba <<SQL 2>&1
WHENEVER SQLERROR EXIT SQL.SQLCODE
ALTER SESSION SET CONTAINER = welbank;
@${test_file}
EXIT
SQL
) || true

  grep -E '^(PASS|FAIL) ' <<<"$output" || true

  result=$(grep -oE 'RESULT: [0-9]+ passed, [0-9]+ failed' <<<"$output" || true)
  if [[ -z "$result" ]]; then
    broken_files=$((broken_files + 1))
    echo "BROKEN: the file stopped before printing its RESULT line. Output:"
    printf '%s\n' "$output"
    continue
  fi
  echo "$result"

  passed=$(sed -E 's/RESULT: ([0-9]+) passed.*/\1/' <<<"$result")
  failed=$(sed -E 's/.* ([0-9]+) failed/\1/' <<<"$result")
  total_passed=$((total_passed + passed))
  total_failed=$((total_failed + failed))
done

echo "=== TOTAL: ${total_passed} passed, ${total_failed} failed, ${broken_files} broken file(s)"
if [[ $total_failed -ne 0 || $broken_files -ne 0 ]]; then
  exit 1
fi
