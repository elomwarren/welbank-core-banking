-- =============================================================================
-- security.sql — the bank's database security that is not part of the schema:
--   1. roles, one per job family (what a person may read or run);
--   2. password rules for employees (profile WB_EMPLOYEE);
--   3. WB_APP, the web application's proxy account;
--   4. system privileges WELBANK needs (scheduler jobs) and monitoring views;
--   5. Unified Auditing policies.
--
-- Run as SYSDBA by scripts/db-security.sh, which DEFINEs app_pwd from
-- secrets/wb_app_pwd.txt. Idempotent: every step checks before it creates, so
-- it is safe to run again after any change.
-- =============================================================================
WHENEVER SQLERROR EXIT SQL.SQLCODE
SET VERIFY OFF
SET FEEDBACK OFF
SET LINESIZE 200

ALTER SESSION SET CONTAINER = welbank;
SET SERVEROUTPUT ON SIZE UNLIMITED

-- -----------------------------------------------------------------------------
-- 1. Roles. The packages run with WELBANK's rights, so a role only decides
--    which packages (and which tables, read-only) a person can reach.
-- -----------------------------------------------------------------------------
DECLARE
  PROCEDURE make_role(p_role VARCHAR2, p_purpose VARCHAR2) IS
  BEGIN
    EXECUTE IMMEDIATE 'CREATE ROLE ' || p_role;
    DBMS_OUTPUT.PUT_LINE('[security] created role ' || RPAD(p_role, 22) || p_purpose);
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLCODE <> -1921 THEN  -- ORA-01921: the role already exists
        RAISE;
      END IF;
  END;
BEGIN
  make_role('WB_STAFF',            'every employee: log in, read customers and accounts');
  make_role('WB_TELLER',           'cash deposits, withdrawals, transfers');
  make_role('WB_SUPERVISOR',       'approve or reject postings, reversals');
  make_role('WB_CUSTOMER_SERVICE', 'register customers, capture KYC, open accounts');
  make_role('WB_KYC_APPROVER',     'approve customers (KYC) and new accounts');
  make_role('WB_LOAN_OFFICER',     'loan applications and repayments');
  make_role('WB_CREDIT',           'credit decisions and disbursements');
  make_role('WB_REPORTS',          'management reports, ledger check');
  make_role('WB_AUDITOR',          'audit trails (read only)');
  make_role('WB_HR',               'staff records');
  make_role('WB_BACKUP_ADMIN',     'backup and recovery monitoring');
END;
/

GRANT CREATE SESSION TO wb_staff;

-- -----------------------------------------------------------------------------
-- 2. Password rules for employees. Oracle enforces them at every login, so the
--    web application does not store or check passwords itself.
-- -----------------------------------------------------------------------------
DECLARE
  l_count PLS_INTEGER;
BEGIN
  SELECT COUNT(*) INTO l_count FROM dba_profiles WHERE profile = 'WB_EMPLOYEE';
  IF l_count = 0 THEN
    EXECUTE IMMEDIATE 'CREATE PROFILE wb_employee LIMIT FAILED_LOGIN_ATTEMPTS 5';
    DBMS_OUTPUT.PUT_LINE('[security] created profile WB_EMPLOYEE');
  END IF;
END;
/
ALTER PROFILE wb_employee LIMIT
  FAILED_LOGIN_ATTEMPTS    5           -- five wrong passwords ...
  PASSWORD_LOCK_TIME       15/1440     -- ... lock the account for 15 minutes
  PASSWORD_LIFE_TIME       90          -- change the password every 90 days
  PASSWORD_GRACE_TIME      14          -- with 14 days of warnings first
  PASSWORD_REUSE_TIME      365         -- no reuse within a year ...
  PASSWORD_REUSE_MAX       6           -- ... nor within the last 6 passwords
  INACTIVE_ACCOUNT_TIME    120         -- unused for 120 days: locked
  PASSWORD_VERIFY_FUNCTION ora12c_verify_function   -- 8+ characters, a letter and a digit, not the user name
;

-- -----------------------------------------------------------------------------
-- 3. WB_APP: the web application's own account. It can log in and nothing
--    else; every request then runs as the employee, through proxy
--    authentication (wb_app[EMPLOYEE]). The password comes from a secret file.
-- -----------------------------------------------------------------------------
CREATE USER IF NOT EXISTS wb_app IDENTIFIED BY "&app_pwd" PROFILE wb_service_account;
ALTER USER wb_app IDENTIFIED BY "&app_pwd" PROFILE wb_service_account ACCOUNT UNLOCK;
GRANT CREATE SESSION TO wb_app;

-- -----------------------------------------------------------------------------
-- 4. System privileges and monitoring views.
-- -----------------------------------------------------------------------------
-- The nightly loans job (changelog 0010).
GRANT CREATE JOB TO welbank;

GRANT SELECT ON sys.v_$database               TO wb_backup_admin;
GRANT SELECT ON sys.v_$instance               TO wb_backup_admin;
GRANT SELECT ON sys.v_$encryption_wallet      TO wb_backup_admin;
GRANT SELECT ON sys.v_$encrypted_tablespaces  TO wb_backup_admin;
GRANT SELECT ON sys.v_$tablespace             TO wb_backup_admin;
-- V$RESTORE_POINT checks for the catalog role itself; an object grant is not enough (ORA-01031).
GRANT select_catalog_role TO wb_backup_admin;
GRANT SELECT ON sys.v_$rman_backup_job_details TO wb_backup_admin;
GRANT SELECT ON sys.dba_scheduler_jobs        TO wb_backup_admin;
GRANT SELECT ON sys.dba_scheduler_job_run_details TO wb_backup_admin;

-- -----------------------------------------------------------------------------
-- 5. Unified Auditing. Oracle already records logons and logoffs
--    (ORA_LOGIN_LOGOUT) and security configuration changes (ORA_SECURECONFIG).
--    Added here: user and role management, schema changes, and every read of
--    identity data by a person.
-- -----------------------------------------------------------------------------
GRANT audit_viewer TO wb_auditor;

DECLARE
  l_count PLS_INTEGER;

  PROCEDURE make_policy(p_name VARCHAR2, p_sql VARCHAR2) IS
  BEGIN
    SELECT COUNT(*) INTO l_count FROM audit_unified_policies WHERE policy_name = p_name;
    IF l_count = 0 THEN
      EXECUTE IMMEDIATE p_sql;
      DBMS_OUTPUT.PUT_LINE('[security] created audit policy ' || p_name);
    END IF;
  END;

  PROCEDURE enable_policy(p_name VARCHAR2, p_sql VARCHAR2) IS
  BEGIN
    SELECT COUNT(*) INTO l_count FROM audit_unified_enabled_policies WHERE policy_name = p_name;
    IF l_count = 0 THEN
      EXECUTE IMMEDIATE p_sql;
      DBMS_OUTPUT.PUT_LINE('[security] enabled audit policy ' || p_name);
    END IF;
  END;
BEGIN
  make_policy('WB_SCHEMA_CHANGES',
    'CREATE AUDIT POLICY wb_schema_changes ACTIONS '
    || 'CREATE TABLE, ALTER TABLE, DROP TABLE, TRUNCATE TABLE, CREATE VIEW, DROP VIEW, '
    || 'CREATE PROCEDURE, DROP PROCEDURE, CREATE PACKAGE, CREATE PACKAGE BODY, DROP PACKAGE, '
    || 'CREATE TRIGGER, DROP TRIGGER, CREATE INDEX, DROP INDEX, GRANT, REVOKE');
  make_policy('WB_SENSITIVE_READS',
    'CREATE AUDIT POLICY wb_sensitive_reads ACTIONS '
    || 'SELECT ON welbank.identity_documents, SELECT ON welbank.identity_verifications, '
    || 'SELECT ON welbank.customer_files');

  enable_policy('ORA_ACCOUNT_MGMT',   'AUDIT POLICY ora_account_mgmt');
  enable_policy('WB_SCHEMA_CHANGES',  'AUDIT POLICY wb_schema_changes BY welbank');
  enable_policy('WB_SENSITIVE_READS', 'AUDIT POLICY wb_sensitive_reads');
END;
/

BEGIN
  DBMS_OUTPUT.PUT_LINE('[security] roles, WB_EMPLOYEE profile, WB_APP and audit policies are in place');
END;
/
