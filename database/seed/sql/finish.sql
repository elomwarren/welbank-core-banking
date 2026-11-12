-- =============================================================================
-- finish.sql — the last step of build/seed.sql.
--   * the loans' end of day up to today;
--   * periodic KYC reviews that fell due during the simulated years;
--   * debit cards (no card package yet: direct inserts, inside every rule);
--   * last-activity dates, dates of the bank's own accounts and staff;
--   * the employees' database user names (the security commit creates them);
--   * checks: the ledger reconciles, nothing is invalid; then a summary.
-- =============================================================================
DECLARE
  v_count PLS_INTEGER;

  PROCEDURE act_as(p_employee_id NUMBER) IS
  BEGIN
    UPDATE employees SET db_username = NULL WHERE db_username = SYS_CONTEXT('USERENV', 'SESSION_USER');
    UPDATE employees SET db_username = SYS_CONTEXT('USERENV', 'SESSION_USER') WHERE employee_id = p_employee_id;
  END;

  FUNCTION manager_of(p_branch NUMBER) RETURN NUMBER IS
    v NUMBER;
  BEGIN
    SELECT MIN(e.employee_id) INTO v FROM employees e JOIN jobs j ON j.job_id = e.job_id
     WHERE j.job_title = 'Branch manager' AND e.branch_id = p_branch;
    RETURN v;
  END;
BEGIN
  pkg_loan.run_end_of_day(TRUNC(SYSDATE));

  FOR c IN (SELECT customer_no, home_branch_id FROM customers
             WHERE kyc_status = 'VERIFIED' AND next_kyc_review_on <= TRUNC(SYSDATE) ORDER BY customer_id) LOOP
    act_as(manager_of(c.home_branch_id));
    pkg_customer.mark_review_due(c.customer_no);
  END LOOP;

  -- Debit cards for about half of the active cedi accounts.
  INSERT INTO cards (account_id, customer_id, card_scheme, card_type, masked_pan, pan_token, name_on_card, status, block_reason,
                     daily_atm_limit, daily_pos_limit, daily_online_limit, requested_by, requested_at, issued_on, expires_on)
  SELECT a.account_id, h.customer_id,
         DECODE(MOD(ORA_HASH(a.account_id, 99), 3), 0, 'GHLINK', 1, 'VISA', 'MASTERCARD'),
         CASE WHEN MOD(ORA_HASH(a.account_id, 997), 10) = 0 THEN 'VIRTUAL' ELSE 'PHYSICAL' END,
         DECODE(MOD(ORA_HASH(a.account_id, 99), 3), 0, '603226', 1, '453218', '539923') || '******'
           || LPAD(MOD(ORA_HASH(a.account_id, 9973), 10000), 4, '0'),
         LOWER(RAWTOHEX(SYS_GUID())),
         SUBSTR(UPPER(c.first_name || ' ' || c.last_name), 1, 26),
         CASE WHEN MOD(ORA_HASH(a.account_id, 991), 100) < 3 THEN 'BLOCKED' ELSE 'ACTIVE' END,
         CASE WHEN MOD(ORA_HASH(a.account_id, 991), 100) < 3 THEN 'LOST' END,
         2000, 5000, 3000,
         (SELECT MIN(e.employee_id) FROM employees e JOIN jobs j ON j.job_id = e.job_id
           WHERE j.job_title = 'Customer service representative' AND e.branch_id = a.branch_id),
         CAST(a.opened_on + 1 AS TIMESTAMP), a.opened_on + 7, LAST_DAY(ADD_MONTHS(a.opened_on + 7, 36))
    FROM accounts a
    JOIN account_holders h ON h.account_id = a.account_id AND h.holder_role = 'PRIMARY'
    JOIN customers c ON c.customer_id = h.customer_id
   WHERE a.account_class = 'CUSTOMER' AND a.status = 'ACTIVE' AND a.currency_code = 'GHS'
     AND MOD(ORA_HASH(a.account_id, 1009), 100) < 55;

  UPDATE accounts a
     SET last_activity_at = (SELECT MAX(e.created_at) FROM ledger_entries e WHERE e.account_id = a.account_id)
   WHERE EXISTS (SELECT 1 FROM ledger_entries e WHERE e.account_id = a.account_id);
  UPDATE accounts a
     SET opened_on = (SELECT b.opened_on FROM branches b WHERE b.branch_id = a.branch_id),
         created_at = (SELECT CAST(b.opened_on AS TIMESTAMP) FROM branches b WHERE b.branch_id = a.branch_id)
   WHERE account_class = 'INTERNAL';
  UPDATE employees SET created_at = CAST(hire_date AS TIMESTAMP);

  -- Nobody is SYS any more; every employee gets their future Oracle user name:
  -- first initial + surname, numbered when two people share it.
  UPDATE employees SET db_username = NULL WHERE db_username = SYS_CONTEXT('USERENV', 'SESSION_USER');
  MERGE INTO employees t
  USING (SELECT employee_id, base || CASE WHEN ROW_NUMBER() OVER (PARTITION BY base ORDER BY employee_id) > 1
                                          THEN TO_CHAR(ROW_NUMBER() OVER (PARTITION BY base ORDER BY employee_id)) END AS username
           FROM (SELECT employee_id, UPPER(SUBSTR(first_name, 1, 1) || REGEXP_REPLACE(last_name, '[^A-Za-z]', '')) AS base FROM employees)) s
  ON (t.employee_id = s.employee_id)
  WHEN MATCHED THEN UPDATE SET t.db_username = s.username;

  SELECT COUNT(*) INTO v_count FROM v_ledger_balance_check WHERE difference <> 0;
  IF v_count > 0 THEN
    RAISE_APPLICATION_ERROR(-20999, v_count || ' accounts do not reconcile with their ledger lines');
  END IF;

  DBMS_OUTPUT.PUT_LINE('[seed] done:');
  FOR r IN (SELECT 'customers ' || kyc_status AS what, COUNT(*) AS n FROM customers GROUP BY kyc_status
            UNION ALL SELECT 'accounts ' || account_class || ' ' || status, COUNT(*) FROM accounts GROUP BY account_class, status
            UNION ALL SELECT 'transactions ' || status, COUNT(*) FROM transactions GROUP BY status
            UNION ALL SELECT 'loans ' || status || ' ' || classification, COUNT(*) FROM loans GROUP BY status, classification
            UNION ALL SELECT 'cards ' || status, COUNT(*) FROM cards GROUP BY status
            UNION ALL SELECT 'pending approvals', COUNT(*) FROM approval_requests WHERE status = 'PENDING'
            UNION ALL SELECT 'audit trail events', COUNT(*) FROM audit_trail
            ORDER BY 1) LOOP
    DBMS_OUTPUT.PUT_LINE('[seed]   ' || RPAD(r.what, 40) || LPAD(r.n, 8));
  END LOOP;
END;
/
COMMIT;
PROMPT [seed] committed
