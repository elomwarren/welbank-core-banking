#!/usr/bin/env bash
# db-migrate.sh — apply or inspect schema changes with Liquibase (SQLcl, inside the db container).
#
# Usage:  ./scripts/db-migrate.sh <command>
#
#   status                   list the changes not applied yet
#   update-sql               print the SQL that "update" would run, without running it
#   update                   apply every pending change, in order, then check that every
#                            package and view compiles (fails if anything is invalid)
#   update-testing-rollback  apply pending changes, roll them back, apply again (tests rollbacks)
#   history                  list the changes already applied, with dates
#   validate                 check the changelog files for mistakes, without touching the database
#   rollback-count N         undo the last N applied changes (each change's "--rollback" SQL)
#   release-locks            clear a lock left by an interrupted run (only if no other run is active)
#
# What happens: this runs database/tools/liquibase.sh inside the container, which connects as
# WB_DEPLOY *proxying into* WELBANK (the schema owner, which cannot log in itself) and runs the
# matching SQLcl "lb" command on database/changelog/controller.xml.
#
# It targets the compose project in this folder. To target another one, set the standard
# COMPOSE_PROJECT_NAME / COMPOSE_FILE environment variables.

set -euo pipefail

cd "$(dirname "$0")/.."

exec docker compose exec -T db bash /opt/welbank/database/tools/liquibase.sh "$@"
