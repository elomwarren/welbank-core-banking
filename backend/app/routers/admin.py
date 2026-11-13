"""Audit trails and database operations (backups, encryption, scheduler)."""

from typing import Any

from fastapi import APIRouter, Query

from ..db import row, rows
from ..deps import Db, require_role

router = APIRouter(prefix="/api/admin", tags=["admin"])


@router.get("/audit-trail", dependencies=[require_role("WB_AUDITOR")])
def audit_trail(
    db: Db,
    entity: str | None = Query(default=None, max_length=30),
    username: str | None = Query(default=None, max_length=30),
    take: int = Query(default=100, ge=1, le=500),
) -> list[dict[str, Any]]:
    """The application's immutable audit trail, newest first (who, what, before and after)."""
    return rows(
        db,
        """SELECT a.audit_id, a.event_time, a.event_type, a.entity_table, a.entity_id,
                  s.full_name AS employee, a.db_user, a.proxy_user, a.client_identifier,
                  a.module, a.old_values, a.new_values
             FROM audit_trail a LEFT JOIN v_staff_directory s ON s.employee_id = a.employee_id
            WHERE (:entity IS NULL OR a.entity_table = UPPER(:entity))
              AND (:username IS NULL OR a.db_user = UPPER(:username))
            ORDER BY a.audit_id DESC
            FETCH FIRST :take ROWS ONLY""",
        entity=entity,
        username=username,
        take=take,
    )


@router.get("/database-audit", dependencies=[require_role("WB_AUDITOR")])
def database_audit(
    db: Db,
    take: int = Query(default=100, ge=1, le=500),
) -> list[dict[str, Any]]:
    """Oracle's Unified Audit trail: logons, failed logons, identity reads, schema changes."""
    return rows(
        db,
        """SELECT event_timestamp, dbusername, dbproxy_username, action_name, object_schema,
                  object_name, return_code, unified_audit_policies, client_identifier
             FROM unified_audit_trail
            WHERE unified_audit_policies IS NOT NULL
            ORDER BY event_timestamp DESC
            FETCH FIRST :take ROWS ONLY""",
        take=take,
    )


@router.get("/database", dependencies=[require_role("WB_BACKUP_ADMIN")])
def database_status(db: Db) -> dict[str, Any]:
    """Recovery readiness: ARCHIVELOG, Flashback, TDE, the backup log, restore points, jobs."""
    return {
        "database": row(
            db,
            """SELECT d.name, d.log_mode, d.flashback_on, d.open_mode, d.force_logging,
                      i.version_full, i.startup_time, i.host_name
                 FROM v$database d CROSS JOIN v$instance i""",
        ),
        "encryption": {
            "wallet": rows(
                db, "SELECT wrl_type, status, wallet_type, keystore_mode FROM v$encryption_wallet"
            ),
            "tablespaces": rows(
                db,
                """SELECT t.name AS tablespace_name, e.encryptionalg, e.encryptedts
                     FROM v$encrypted_tablespaces e JOIN v$tablespace t
                       ON t.ts# = e.ts# AND t.con_id = e.con_id
                    ORDER BY t.name""",
            ),
        },
        "backups": rows(
            db,
            """SELECT run_id, run_type, status, started_at, finished_at, output_mb, details
                 FROM backup_runs ORDER BY run_id DESC FETCH FIRST 30 ROWS ONLY""",
        ),
        "restore_points": rows(
            db,
            """SELECT name, scn, time, guarantee_flashback_database, storage_size
                 FROM v$restore_point ORDER BY time DESC""",
        ),
        "jobs": rows(
            db,
            """SELECT j.owner, j.job_name, j.enabled, j.state, j.repeat_interval,
                      j.last_start_date, j.next_run_date, j.run_count, j.failure_count,
                      (SELECT MAX(d.status) KEEP (DENSE_RANK LAST ORDER BY d.log_id)
                         FROM dba_scheduler_job_run_details d
                        WHERE d.owner = j.owner AND d.job_name = j.job_name) AS last_status
                 FROM dba_scheduler_jobs j WHERE j.owner = 'WELBANK' ORDER BY j.job_name""",
        ),
    }
