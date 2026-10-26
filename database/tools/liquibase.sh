#!/usr/bin/env bash
# =============================================================================
# liquibase.sh — run one Liquibase command through SQLcl.
#
# Runs INSIDE the database container, as the "oracle" user. Called from the
# host by scripts/db-migrate.sh; see that file for the list of commands.
#
# How it connects: WB_DEPLOY proxies into WELBANK ("wb_deploy[welbank]").
# WELBANK owns the tables but has no password and cannot log in on its own;
# proxy authentication is how its schema is managed. The session runs as
# WELBANK, so every object Liquibase creates belongs to WELBANK, and the audit
# trail still records that WB_DEPLOY did it.
# =============================================================================

set -euo pipefail

readonly CHANGELOG_DIR=/opt/welbank/database/changelog
readonly CONTROLLER=controller.xml
readonly SERVICE=//localhost:1521/WELBANK
readonly SECRET_FILE=/run/secrets/wb_deploy_pwd

usage() {
  echo "usage: liquibase.sh status | update-sql | update | update-testing-rollback | history | validate | rollback-count <N> | release-locks" >&2
}

if [[ $# -lt 1 ]]; then
  usage
  exit 2
fi

command="$1"
case "$command" in
  status)         lb_command="status -changelog-file ${CONTROLLER}" ;;
  update-sql)     lb_command="update-sql -changelog-file ${CONTROLLER}" ;;
  update)         lb_command="update -changelog-file ${CONTROLLER}" ;;
  # Apply pending changes, roll them back, apply again: proves every rollback works.
  update-testing-rollback) lb_command="update-testing-rollback -changelog-file ${CONTROLLER}" ;;
  history)        lb_command="history" ;;
  # Clear a lock left behind by an interrupted run (only when no other run is active).
  release-locks)  lb_command="release-locks" ;;
  validate)       lb_command="validate -changelog-file ${CONTROLLER}" ;;
  rollback-count)
    if [[ ! "${2:-}" =~ ^[1-9][0-9]*$ ]]; then
      echo "rollback-count needs a positive number, e.g. rollback-count 1" >&2
      exit 2
    fi
    lb_command="rollback-count -changelog-file ${CONTROLLER} -count $2"
    ;;
  *)
    usage
    exit 2
    ;;
esac

if [[ ! -r "$SECRET_FILE" ]]; then
  echo "ERROR: $SECRET_FILE is missing. Run ./scripts/init-secrets.sh, then 'docker compose up -d'." >&2
  exit 1
fi

# SQLcl ships its own Java inside the Oracle home.
export JAVA_HOME="${ORACLE_HOME}/jdk"

# Liquibase stores each change's file path relative to the folder it runs from,
# so always run from the changelog folder.
cd "$CHANGELOG_DIR"

# The password goes in through standard input, never as a command-line argument,
# so it cannot be seen with `ps`.
deploy_pwd=$(<"$SECRET_FILE")
output=$("${ORACLE_HOME}/sqlcl/bin/sql" -S /nolog <<SQL 2>&1
connect wb_deploy[welbank]/"${deploy_pwd}"@${SERVICE}
lb ${lb_command}
exit
SQL
)
printf '%s\n' "$output"

# SQLcl does not set a failing exit code when a Liquibase command fails, so the
# result is read from the output. Success is checked positively: SQLcl ends every
# successful Liquibase command with "Operation completed successfully." Guessing
# failure from error words alone would miss messages that contain none of them.
if ! grep -q 'Operation completed successfully' <<<"$output" \
   || grep -qE 'ORA-[0-9]{5}|SP2-[0-9]{4}' <<<"$output"; then
  echo "liquibase.sh: '${command}' FAILED (see the messages above)" >&2
  exit 1
fi

# PL/SQL that does not compile is still created ("with compilation errors"), and
# Liquibase reports success. So after every change, recompile whatever is
# invalid (a table change can invalidate the code and the assertions that use
# it) and fail if anything is still invalid, listing the compiler's errors.
if [[ "$command" == "update" || "$command" == "update-testing-rollback" ]]; then
  check=$("${ORACLE_HOME}/sqlcl/bin/sql" -S /nolog <<SQL 2>&1
connect wb_deploy[welbank]/"${deploy_pwd}"@${SERVICE}
set feedback off heading off pagesize 0 linesize 300
exec DBMS_UTILITY.COMPILE_SCHEMA(schema => USER, compile_all => FALSE)
-- COMPILE_SCHEMA leaves assertions alone. An ALTER TABLE on a table an assertion
-- reads marks it INVALID (still enforced, found in 23.26.3); VALIDATE clears it.
begin
  for o in (select object_id from user_objects
             where status = 'INVALID' and object_name in (select assertion_name from user_assertions)) loop
    DBMS_UTILITY.VALIDATE(o.object_id);
  end loop;
end;
/
select 'INVALID ' || object_type || ' ' || object_name from user_objects where status = 'INVALID' order by 1;
select 'ERROR ' || type || ' ' || name || ' line ' || line || ': ' || text from user_errors where attribute = 'ERROR' order by name, type, sequence;
exit
SQL
)
  if grep -qE '^(INVALID|ERROR) |ORA-[0-9]{5}' <<<"$check"; then
    grep -E '^(INVALID|ERROR) |ORA-[0-9]{5}' <<<"$check" >&2
    echo "liquibase.sh: invalid objects after '${command}' (see above)" >&2
    exit 1
  fi
  echo "liquibase.sh: every schema object compiles (no invalid objects)"
fi
