# database/

Everything that builds the WEL Bank database. The whole folder is mounted read-only into the container at `/opt/welbank/database`.

```text
database/
├── container/
│   ├── setup/        Run once, automatically, when the container creates a new database
│   │   ├── 01_recovery_area.sh   Fast Recovery Area on its own volume
│   │   ├── 02_welbank_pdb.sh     WELBANK pluggable database, fully encrypted
│   │   └── 03_bootstrap.sh       Calls bootstrap/bootstrap.sh (below)
│   └── startup/      Run on every container start (none yet)
├── bootstrap/        Accounts and storage the schema needs (run as SYSDBA, safe to re-run)
│   ├── bootstrap.sh  Reads the WB_DEPLOY password from the Docker secret, runs bootstrap.sql
│   └── bootstrap.sql WELBANK_DOCS tablespace, WB_SERVICE_ACCOUNT profile, WELBANK owner, WB_DEPLOY
├── changelog/        Liquibase changelogs: every schema object, in order
│   ├── controller.xml            The master list of files, in apply order
│   ├── 0001_domains.sql          SQL domains (email, phone, Ghana Card, money, ...)
│   └── 0002_reference_tables.sql Regions, branches, departments, jobs, currencies, products, limits
└── tools/
    ├── liquibase.sh   Runs one Liquibase command through SQLcl, as WB_DEPLOY[WELBANK]
    └── sql-session.sh Opens an interactive SQLcl session (SYSDBA in WELBANK or root, or WB_DEPLOY[WELBANK])
```

## The commands you use

| Command (from the repo root) | What it does |
|---|---|
| `./scripts/db-sql.sh` | Interactive SQLcl as SYSDBA inside WELBANK; `root` for CDB$ROOT; `deploy` to act as WELBANK. No password to type |
| `./scripts/db-bootstrap.sh` | Creates or re-syncs the schema owner, the deployment account and the documents tablespace |
| `./scripts/db-migrate.sh status` | Lists schema changes not applied yet |
| `./scripts/db-migrate.sh update-sql` | Prints the SQL that `update` would run, without running it |
| `./scripts/db-migrate.sh update` | Applies every pending change |
| `./scripts/db-migrate.sh update-testing-rollback` | Applies pending changes, rolls them back, applies again: proves the rollbacks work |
| `./scripts/db-migrate.sh history` | Lists the changes already applied |
| `./scripts/db-migrate.sh rollback-count 1` | Undoes the last applied change |
| `./scripts/db-migrate.sh release-locks` | Clears a lock left by an interrupted run |

## Who owns what

| Account | Can log in? | Purpose |
|---|---|---|
| `WELBANK` | No (schema-only, `NO AUTHENTICATION`) | Owns every table, view and package |
| `WB_DEPLOY` | Yes, password in `secrets/wb_deploy_pwd.txt` | Applies changes by proxying into `WELBANK`: `connect wb_deploy[welbank]/…` |

## Rules for changelogs

- Never edit a changeset that has been applied: add a new one. Liquibase checksums every applied changeset and stops if one changed.
- Every changeset has a `--rollback`.
- Liquibase records what it applied in `WELBANK.DATABASECHANGELOG`.
