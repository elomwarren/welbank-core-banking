-- =============================================================================
-- staff_users.sql — one Oracle user per employee, kept in step with HR data:
--   * employees.db_username is the user name (filled by the seed);
--   * new employees get a user with the WB_EMPLOYEE password rules;
--   * roles follow the job (job_roles), plus WB_STAFF for everyone; roles the
--     job no longer has are revoked;
--   * every user may be reached only through WB_APP (proxy authentication);
--   * only ACTIVE employees can log in: on leave, suspended or terminated
--     employees are locked, and so is a user whose employee no longer exists.
--
-- Run as SYSDBA by scripts/db-security.sh, which DEFINEs staff_pwd (the
-- development password from secrets/staff_demo_pwd.txt) and reset_passwords
-- (YES sets that password again on existing users too).
-- =============================================================================
WHENEVER SQLERROR EXIT SQL.SQLCODE
SET VERIFY OFF
SET FEEDBACK OFF
SET LINESIZE 200

ALTER SESSION SET CONTAINER = welbank;
SET SERVEROUTPUT ON SIZE UNLIMITED

-- Default roles for jobs that have none yet. After this, HR owns the mapping:
-- a job that already has roles is never touched here.
MERGE INTO welbank.job_roles t
USING (
  SELECT j.job_id, m.role_name
    FROM welbank.jobs j
    JOIN (VALUES
            ('Bank teller',                     'WB_TELLER'),
            ('Personal banker',                 'WB_TELLER'),
            ('Personal banker',                 'WB_CUSTOMER_SERVICE'),
            ('Personal banker',                 'WB_LOAN_OFFICER'),
            ('Teller supervisor',               'WB_TELLER'),
            ('Teller supervisor',               'WB_SUPERVISOR'),
            ('Customer service representative', 'WB_CUSTOMER_SERVICE'),
            ('Call center representative',      'WB_CUSTOMER_SERVICE'),
            ('Account manager',                 'WB_CUSTOMER_SERVICE'),
            ('Branch manager',                  'WB_SUPERVISOR'),
            ('Branch manager',                  'WB_KYC_APPROVER'),
            ('Branch manager',                  'WB_REPORTS'),
            ('Operations manager',              'WB_SUPERVISOR'),
            ('Operations manager',              'WB_KYC_APPROVER'),
            ('Operations manager',              'WB_REPORTS'),
            ('Operations specialist',           'WB_REPORTS'),
            ('Loan officer',                    'WB_LOAN_OFFICER'),
            ('Loan processor',                  'WB_LOAN_OFFICER'),
            ('Credit analyst',                  'WB_CREDIT'),
            ('Risk manager',                    'WB_CREDIT'),
            ('Risk manager',                    'WB_REPORTS'),
            ('Portfolio manager',               'WB_REPORTS'),
            ('Chief financial officer (CFO)',   'WB_REPORTS'),
            ('Financial analyst',               'WB_REPORTS'),
            ('Treasury manager',                'WB_REPORTS'),
            ('Controller',                      'WB_REPORTS'),
            ('Controller',                      'WB_AUDITOR'),
            ('Compliance officer',              'WB_AUDITOR'),
            ('Compliance officer',              'WB_REPORTS'),
            ('Human resources manager',         'WB_HR'),
            ('HR generalist',                   'WB_HR'),
            ('Recruiter',                       'WB_HR'),
            ('Database administrator',          'WB_BACKUP_ADMIN'),
            ('IT manager',                      'WB_BACKUP_ADMIN')
         ) m (job_title, role_name)
      ON m.job_title = j.job_title
   WHERE NOT EXISTS (SELECT 1 FROM welbank.job_roles r WHERE r.job_id = j.job_id)
) s
ON (t.job_id = s.job_id AND t.role_name = s.role_name)
WHEN NOT MATCHED THEN INSERT (job_id, role_name) VALUES (s.job_id, s.role_name);
COMMIT;

DECLARE
  c_password CONSTANT VARCHAR2(128) := '&staff_pwd';
  c_reset    CONSTANT BOOLEAN       := UPPER('&reset_passwords') = 'YES';
  l_user     VARCHAR2(130);
  l_count    PLS_INTEGER;
  l_status   dba_users.account_status%TYPE;
  n_created  PLS_INTEGER := 0;
  n_reset    PLS_INTEGER := 0;
  n_locked   PLS_INTEGER := 0;
  n_users    PLS_INTEGER := 0;

  PROCEDURE run(p_sql VARCHAR2) IS
  BEGIN
    EXECUTE IMMEDIATE p_sql;
  END;
BEGIN
  FOR e IN (SELECT employee_id, db_username, status, job_id
              FROM welbank.employees
             WHERE db_username IS NOT NULL
             ORDER BY employee_id) LOOP
    -- The name goes into DDL: DBMS_ASSERT refuses anything but a plain identifier.
    l_user := DBMS_ASSERT.SIMPLE_SQL_NAME(e.db_username);
    n_users := n_users + 1;

    SELECT COUNT(*) INTO l_count FROM dba_users WHERE username = e.db_username;
    IF l_count = 0 THEN
      run('CREATE USER ' || l_user || ' IDENTIFIED BY "' || c_password || '" PROFILE wb_employee');
      n_created := n_created + 1;
    ELSIF c_reset THEN
      run('ALTER USER ' || l_user || ' IDENTIFIED BY "' || c_password || '"');
      n_reset := n_reset + 1;
    END IF;

    -- Roles: WB_STAFF and the job's roles; anything else starting WB_ is revoked.
    FOR r IN (SELECT 'WB_STAFF' AS role_name FROM dual
              UNION
              SELECT role_name FROM welbank.job_roles WHERE job_id = e.job_id) LOOP
      run('GRANT ' || DBMS_ASSERT.SIMPLE_SQL_NAME(r.role_name) || ' TO ' || l_user);
    END LOOP;
    FOR r IN (SELECT granted_role FROM dba_role_privs
               WHERE grantee = e.db_username
                 AND granted_role LIKE 'WB\_%' ESCAPE '\'
                 AND granted_role <> 'WB_STAFF'
                 AND granted_role NOT IN (SELECT role_name FROM welbank.job_roles WHERE job_id = e.job_id)) LOOP
      run('REVOKE ' || DBMS_ASSERT.SIMPLE_SQL_NAME(r.granted_role) || ' FROM ' || l_user);
    END LOOP;
    run('ALTER USER ' || l_user || ' DEFAULT ROLE ALL');

    -- Reachable through the web application's account.
    SELECT COUNT(*) INTO l_count FROM proxy_users WHERE proxy = 'WB_APP' AND client = e.db_username;
    IF l_count = 0 THEN
      run('ALTER USER ' || l_user || ' GRANT CONNECT THROUGH wb_app');
    END IF;

    -- Only ACTIVE employees can log in. A lock from failed logins (LOCKED(TIMED))
    -- is left alone: it ends by itself after PASSWORD_LOCK_TIME.
    SELECT account_status INTO l_status FROM dba_users WHERE username = e.db_username;
    IF e.status = 'ACTIVE' AND l_status = 'LOCKED' THEN
      run('ALTER USER ' || l_user || ' ACCOUNT UNLOCK');
    ELSIF e.status <> 'ACTIVE' AND l_status NOT LIKE '%LOCKED%' THEN
      run('ALTER USER ' || l_user || ' ACCOUNT LOCK');
      n_locked := n_locked + 1;
    END IF;
  END LOOP;

  -- A database user whose employee record is gone (or renamed) is locked.
  FOR u IN (SELECT username FROM dba_users
             WHERE profile = 'WB_EMPLOYEE'
               AND account_status NOT LIKE '%LOCKED%'
               AND username NOT IN (SELECT db_username FROM welbank.employees WHERE db_username IS NOT NULL)) LOOP
    run('ALTER USER ' || DBMS_ASSERT.SIMPLE_SQL_NAME(u.username) || ' ACCOUNT LOCK');
    n_locked := n_locked + 1;
  END LOOP;

  DBMS_OUTPUT.PUT_LINE('[security] staff users: ' || n_users || ' employees, ' || n_created || ' users created, '
                       || n_reset || ' passwords reset, ' || n_locked || ' locked');
END;
/
