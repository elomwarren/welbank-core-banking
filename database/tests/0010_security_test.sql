-- =============================================================================
-- 0010_security_test.sql — the security and operations layer:
-- roles and grants (least privilege, nothing writes but the packages), the
-- proxy account, password rules, audit policies, the nightly job, and the
-- employees' database users once they exist.
--
-- Run by database/tests/run_tests.sh as SYSDBA inside WELBANK, in one
-- transaction that is rolled back at the end.
-- =============================================================================
SET SERVEROUTPUT ON SIZE UNLIMITED FEEDBACK OFF LINESIZE 200
ALTER SESSION SET CURRENT_SCHEMA = welbank;

DECLARE
  passed PLS_INTEGER := 0;
  failed PLS_INTEGER := 0;
  v      NUMBER;
  v_text VARCHAR2(4000);

  PROCEDURE check_that(p_name VARCHAR2, p_ok BOOLEAN, p_detail VARCHAR2 DEFAULT NULL) IS
  BEGIN
    IF p_ok THEN
      passed := passed + 1;
      DBMS_OUTPUT.PUT_LINE('PASS  ' || p_name);
    ELSE
      failed := failed + 1;
      DBMS_OUTPUT.PUT_LINE('FAIL  ' || p_name || CASE WHEN p_detail IS NOT NULL THEN '  -> ' || p_detail END);
    END IF;
  END;

  PROCEDURE rejects(p_name VARCHAR2, p_sql VARCHAR2) IS
  BEGIN
    EXECUTE IMMEDIATE p_sql;
    failed := failed + 1;
    DBMS_OUTPUT.PUT_LINE('FAIL  rejects  ' || p_name || '  -> was accepted');
  EXCEPTION WHEN OTHERS THEN
    passed := passed + 1;
    DBMS_OUTPUT.PUT_LINE('PASS  rejects  ' || p_name);
  END;
BEGIN
  -- Roles ---------------------------------------------------------------------
  SELECT COUNT(*) INTO v FROM dba_roles
   WHERE role IN ('WB_STAFF', 'WB_TELLER', 'WB_SUPERVISOR', 'WB_CUSTOMER_SERVICE', 'WB_KYC_APPROVER',
                  'WB_LOAN_OFFICER', 'WB_CREDIT', 'WB_REPORTS', 'WB_AUDITOR', 'WB_HR', 'WB_BACKUP_ADMIN');
  check_that('the eleven WB_ roles exist', v = 11, v || ' found');

  -- Nothing but the packages writes: no INSERT, UPDATE, DELETE (or ALTER) on any WELBANK object for anyone.
  SELECT COUNT(*), LISTAGG(grantee || ':' || privilege || ':' || table_name, ', ') WITHIN GROUP (ORDER BY 1)
    INTO v, v_text
    FROM dba_tab_privs
   WHERE owner = 'WELBANK' AND privilege IN ('INSERT', 'UPDATE', 'DELETE', 'ALTER', 'INDEX', 'REFERENCES', 'DEBUG');
  check_that('no one holds INSERT/UPDATE/DELETE on the schema', v = 0, v_text);

  SELECT COUNT(*) INTO v FROM dba_tab_privs WHERE owner = 'WELBANK' AND grantee = 'WB_TELLER' AND table_name = 'PKG_CUSTOMER';
  check_that('tellers cannot run the onboarding package', v = 0);
  SELECT COUNT(*) INTO v FROM dba_tab_privs WHERE owner = 'WELBANK' AND grantee = 'WB_STAFF' AND table_name IN ('CUSTOMER_FILES', 'IDENTITY_DOCUMENTS', 'AUDIT_TRAIL', 'EMPLOYEES');
  check_that('identity data, the audit trail and salaries are not readable by every employee', v = 0);
  SELECT COUNT(*) INTO v FROM dba_tab_privs WHERE owner = 'WELBANK' AND grantee = 'WB_AUDITOR' AND table_name = 'AUDIT_TRAIL' AND privilege = 'SELECT';
  check_that('auditors read the audit trail', v = 1);
  SELECT COUNT(*) INTO v FROM dba_tab_privs WHERE owner = 'WELBANK' AND grantee = 'WB_STAFF' AND table_name = 'V_STAFF_DIRECTORY';
  check_that('every employee reads the staff directory (no salaries)', v = 1);
  SELECT COUNT(*) INTO v FROM dba_tab_columns WHERE owner = 'WELBANK' AND table_name = 'V_STAFF_DIRECTORY' AND column_name IN ('SALARY', 'RESIDENTIAL_ADDRESS', 'DATE_OF_BIRTH');
  check_that('the staff directory has no salary, address or birth date', v = 0);

  -- The web application's account -----------------------------------------
  SELECT COUNT(*) INTO v FROM dba_users WHERE username = 'WB_APP' AND account_status = 'OPEN';
  check_that('WB_APP exists and is open', v = 1);
  SELECT (SELECT COUNT(*) FROM dba_sys_privs WHERE grantee = 'WB_APP' AND privilege <> 'CREATE SESSION')
       + (SELECT COUNT(*) FROM dba_role_privs WHERE grantee = 'WB_APP')
       + (SELECT COUNT(*) FROM dba_tab_privs WHERE grantee = 'WB_APP')
    INTO v FROM dual;
  check_that('WB_APP can only log in (no other privilege, no role)', v = 0, v || ' extra privileges');

  -- Password rules --------------------------------------------------------------
  SELECT COUNT(*) INTO v FROM dba_profiles
   WHERE profile = 'WB_EMPLOYEE'
     AND ((resource_name = 'FAILED_LOGIN_ATTEMPTS' AND limit = '5')
       OR (resource_name = 'PASSWORD_LIFE_TIME' AND limit = '90')
       OR (resource_name = 'PASSWORD_VERIFY_FUNCTION' AND limit = 'ORA12C_VERIFY_FUNCTION'));
  check_that('employee profile: 5 attempts, 90-day passwords, complexity check', v = 3, v || ' of 3 limits');

  -- Unified Auditing -------------------------------------------------------------
  SELECT COUNT(DISTINCT policy_name) INTO v FROM audit_unified_enabled_policies
   WHERE policy_name IN ('WB_SCHEMA_CHANGES', 'WB_SENSITIVE_READS', 'ORA_ACCOUNT_MGMT', 'ORA_LOGIN_LOGOUT');
  check_that('audit policies enabled: schema changes, identity reads, accounts, logons', v = 4, v || ' of 4');

  -- Job-to-role map ------------------------------------------------------------------
  rejects('a job mapped to a built-in role (DBA)',
          'INSERT INTO job_roles (job_id, role_name) VALUES ((SELECT MIN(job_id) FROM jobs), ''DBA'')');
  SELECT COUNT(*) INTO v FROM job_roles r WHERE NOT EXISTS (SELECT 1 FROM dba_roles d WHERE d.role = r.role_name);
  check_that('every mapped role exists', v = 0);

  -- Backups log ----------------------------------------------------------------------
  rejects('a backup that finished before it started',
          'INSERT INTO backup_runs (run_type, status, started_at, finished_at) VALUES (''LEVEL0'', ''COMPLETED'', SYSTIMESTAMP, SYSTIMESTAMP - 1)');
  rejects('an unknown backup type',
          'INSERT INTO backup_runs (run_type, status, started_at, finished_at) VALUES (''FULL'', ''COMPLETED'', SYSTIMESTAMP, SYSTIMESTAMP)');

  -- Nightly job ----------------------------------------------------------------------------
  SELECT COUNT(*) INTO v FROM dba_scheduler_jobs
   WHERE owner = 'WELBANK' AND job_name = 'WB_LOAN_END_OF_DAY' AND enabled = 'TRUE' AND repeat_interval LIKE 'FREQ=DAILY%';
  check_that('the loans end-of-day job runs daily', v = 1);

  -- Employees' users (only once scripts/db-security.sh has created them) -------------
  SELECT COUNT(*) INTO v FROM dba_users WHERE profile = 'WB_EMPLOYEE';
  IF v > 0 THEN
    SELECT COUNT(*) INTO v FROM employees e
     WHERE e.status = 'ACTIVE' AND e.db_username IS NOT NULL
       AND (NOT EXISTS (SELECT 1 FROM dba_users u WHERE u.username = e.db_username AND u.profile = 'WB_EMPLOYEE')
            OR NOT EXISTS (SELECT 1 FROM proxy_users p WHERE p.proxy = 'WB_APP' AND p.client = e.db_username));
    check_that('every active employee has a user reachable through WB_APP', v = 0, v || ' missing');
    SELECT COUNT(*) INTO v FROM employees e JOIN dba_users u ON u.username = e.db_username
     WHERE e.status <> 'ACTIVE' AND u.account_status NOT LIKE '%LOCKED%';
    check_that('employees who are not active cannot log in', v = 0, v || ' open');
    SELECT COUNT(*) INTO v FROM employees e JOIN job_roles r ON r.job_id = e.job_id
     WHERE e.db_username IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM dba_role_privs p WHERE p.grantee = e.db_username AND p.granted_role = r.role_name);
    check_that('every employee holds the roles of their job', v = 0, v || ' missing grants');
  ELSE
    DBMS_OUTPUT.PUT_LINE('(employee users not created yet: three checks skipped)');
  END IF;

  ROLLBACK;
  DBMS_OUTPUT.PUT_LINE('RESULT: ' || passed || ' passed, ' || failed || ' failed');
END;
/
