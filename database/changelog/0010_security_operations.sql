--liquibase formatted sql

-- =============================================================================
-- 0010_security_operations.sql — what the security and operations layer keeps
-- in the schema: which Oracle roles each job gets, the log of backups, and the
-- loans' nightly end of day as a DBMS_SCHEDULER job.
--
-- The roles, the WB_APP proxy account and the employees' Oracle users are not
-- schema objects: database/security/*.sql creates them as SYSDBA
-- (scripts/db-security.sh). Run that script BEFORE this update on a new database.
-- =============================================================================

--changeset elomwarren:0010-job-roles
--comment: Which Oracle roles each job gets. scripts/db-security.sh grants them to every employee's database user.
CREATE TABLE job_roles (
  job_id     NUMBER        NOT NULL,
  role_name  VARCHAR2(30)  NOT NULL,
  created_at TIMESTAMP     DEFAULT ON NULL SYSTIMESTAMP NOT NULL,
  created_by VARCHAR2(128) DEFAULT ON NULL SYS_CONTEXT('USERENV', 'SESSION_USER') NOT NULL,
  CONSTRAINT job_roles_pk      PRIMARY KEY (job_id, role_name),
  CONSTRAINT job_roles_job_fk  FOREIGN KEY (job_id) REFERENCES jobs (job_id),
  -- Only the bank's own roles: a job can never be mapped to DBA or another built-in role.
  CONSTRAINT job_roles_role_ck CHECK (REGEXP_LIKE(role_name, '^WB_[A-Z_]{2,27}$'))
);
COMMENT ON TABLE job_roles IS 'Oracle roles granted to the database users of the employees holding each job (least privilege by job).';
--rollback DROP TABLE job_roles PURGE;

--changeset elomwarren:0010-backup-runs
--comment: One row per RMAN run, written by scripts/db-backup.sh, read by the backup page of the web app.
CREATE TABLE backup_runs (
  run_id      NUMBER GENERATED ALWAYS AS IDENTITY CONSTRAINT backup_runs_pk PRIMARY KEY,
  run_type    VARCHAR2(16)   NOT NULL,
  status      VARCHAR2(10)   NOT NULL,
  started_at  TIMESTAMP      NOT NULL,
  finished_at TIMESTAMP      NOT NULL,
  output_mb   NUMBER(12, 1),
  details     VARCHAR2(4000),
  CONSTRAINT backup_runs_type_ck   CHECK (run_type IN ('LEVEL0', 'LEVEL1', 'ARCHIVELOG', 'VALIDATE', 'RESTORE_DRILL')),
  CONSTRAINT backup_runs_status_ck CHECK (status IN ('COMPLETED', 'FAILED')),
  CONSTRAINT backup_runs_time_ck   CHECK (finished_at >= started_at),
  CONSTRAINT backup_runs_size_ck   CHECK (output_mb IS NULL OR output_mb >= 0)
);
COMMENT ON TABLE backup_runs IS 'Log of backups, validations and restore drills (RMAN), written by scripts/db-backup.sh.';
--rollback DROP TABLE backup_runs PURGE;

--changeset elomwarren:0010-loan-end-of-day-job endDelimiter:/
--comment: The loans' end of day every evening at 23:30 (Ghana time is UTC): interest falls due, arrears age, Bank of Ghana classes are updated.
BEGIN
  DBMS_SCHEDULER.CREATE_JOB(
    job_name        => 'WB_LOAN_END_OF_DAY',
    job_type        => 'PLSQL_BLOCK',
    job_action      => 'BEGIN pkg_loan.run_end_of_day(TRUNC(SYSDATE)); END;',
    start_date      => SYSTIMESTAMP,
    repeat_interval => 'FREQ=DAILY;BYHOUR=23;BYMINUTE=30;BYSECOND=0',
    enabled         => TRUE,
    comments        => 'Loans end of day: interest due, days past due, Bank of Ghana classification.');
END;
/
--rollback BEGIN DBMS_SCHEDULER.DROP_JOB(job_name => 'WB_LOAN_END_OF_DAY'); END;
--rollback /
