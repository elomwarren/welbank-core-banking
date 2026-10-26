-- =============================================================================
-- 0007_posting_test.sql — pkg_posting: deposits, withdrawals, transfers,
-- maker-checker approvals, reversals, and the views that check the ledger.
--
-- Run by database/tests/run_tests.sh as SYSDBA inside WELBANK. Everything runs
-- in one transaction that is rolled back at the end: no data is left behind.
--
-- Who is acting: pkg_session maps the session user to the employee whose
-- db_username it is. The test session user is SYS, so act_as() points SYS at
-- one test employee at a time (inside the rolled-back transaction). Switching
-- it switches who is acting, so maker and checker can both be played.
-- =============================================================================
SET SERVEROUTPUT ON SIZE UNLIMITED FEEDBACK OFF LINESIZE 200
ALTER SESSION SET CURRENT_SCHEMA = welbank;

DECLARE
  passed PLS_INTEGER := 0;
  failed PLS_INTEGER := 0;
  v_region  NUMBER; v_branch NUMBER; v_branch2 NUMBER; v_dept NUMBER;
  v_job_teller NUMBER; v_job_sup NUMBER;
  v_teller  NUMBER; v_teller2 NUMBER; v_sup NUMBER;
  v_c1 NUMBER; v_c2 NUMBER; v_c3 NUMBER;
  v_sav NUMBER; v_cur NUMBER; v_sav_xxx NUMBER;
  v_vault NUMBER; v_vault2 NUMBER;
  v_a NUMBER; v_b NUMBER; v_c NUMBER; v_d NUMBER; v_p NUMBER; v_x NUMBER;
  v_no_a VARCHAR2(13); v_no_b VARCHAR2(13); v_no_c VARCHAR2(13); v_no_d VARCHAR2(13);
  v_no_p VARCHAR2(13); v_no_x VARCHAR2(13);
  v_ref VARCHAR2(20); v_big_ref VARCHAR2(20); v_tr_ref VARCHAR2(20); v_rej_ref VARCHAR2(20);
  v_wd_ref VARCHAR2(20); v_rev_ref VARCHAR2(20);
  v_request NUMBER;
  v_count   PLS_INTEGER;
  v_num     NUMBER;
  v_text    VARCHAR2(400);

  PROCEDURE accepts(p_name VARCHAR2, p_sql VARCHAR2) IS
  BEGIN
    EXECUTE IMMEDIATE p_sql;
    passed := passed + 1;
    DBMS_OUTPUT.PUT_LINE('PASS  accepts  ' || p_name);
  EXCEPTION WHEN OTHERS THEN
    failed := failed + 1;
    DBMS_OUTPUT.PUT_LINE('FAIL  accepts  ' || p_name || '  -> ' || SQLERRM);
  END;

  -- p_expect: a regular expression that must match the error stack, here
  -- usually the pkg_errors number, e.g. 'ORA-20005'.
  PROCEDURE rejects(p_name VARCHAR2, p_sql VARCHAR2, p_expect VARCHAR2) IS
  BEGIN
    EXECUTE IMMEDIATE p_sql;
    failed := failed + 1;
    DBMS_OUTPUT.PUT_LINE('FAIL  rejects  ' || p_name || '  -> was accepted');
  EXCEPTION WHEN OTHERS THEN
    IF REGEXP_LIKE(DBMS_UTILITY.FORMAT_ERROR_STACK, p_expect) THEN
      passed := passed + 1;
      DBMS_OUTPUT.PUT_LINE('PASS  rejects  ' || p_name || '  (' || REGEXP_SUBSTR(SQLERRM, '^ORA-[0-9]+') || ')');
    ELSE
      failed := failed + 1;
      DBMS_OUTPUT.PUT_LINE('FAIL  rejects  ' || p_name || '  -> expected ' || p_expect || ', got ' || SQLERRM);
    END IF;
  END;

  PROCEDURE check_that(p_name VARCHAR2, p_ok BOOLEAN) IS
  BEGIN
    IF p_ok THEN
      passed := passed + 1;
      DBMS_OUTPUT.PUT_LINE('PASS  checks   ' || p_name);
    ELSE
      failed := failed + 1;
      DBMS_OUTPUT.PUT_LINE('FAIL  checks   ' || p_name);
    END IF;
  END;

  -- Wraps a call to a pkg_posting function so it can be run as text.
  FUNCTION call(p_function_call VARCHAR2) RETURN VARCHAR2 IS
  BEGIN
    RETURN 'DECLARE r VARCHAR2(40); BEGIN r := pkg_posting.' || p_function_call || '; END;';
  END;

  -- Runs a pkg_posting function that returns a reference; a FAIL line and NULL on error.
  FUNCTION ref_of(p_name VARCHAR2, p_function_call VARCHAR2) RETURN VARCHAR2 IS
    v VARCHAR2(40);
  BEGIN
    EXECUTE IMMEDIATE 'BEGIN :r := pkg_posting.' || p_function_call || '; END;' USING OUT v;
    RETURN v;
  EXCEPTION WHEN OTHERS THEN
    failed := failed + 1;
    DBMS_OUTPUT.PUT_LINE('FAIL  accepts  ' || p_name || '  -> ' || SQLERRM);
    RETURN NULL;
  END;

  FUNCTION q(p_text VARCHAR2) RETURN VARCHAR2 IS
  BEGIN
    RETURN '''' || REPLACE(p_text, '''', '''''') || '''';
  END;

  FUNCTION balance(p_account_id NUMBER) RETURN NUMBER IS
    v NUMBER;
  BEGIN
    SELECT ledger_balance INTO v FROM accounts WHERE account_id = p_account_id;
    RETURN v;
  END;

  FUNCTION status_of(p_ref VARCHAR2) RETURN VARCHAR2 IS
    v VARCHAR2(20);
  BEGIN
    SELECT status INTO v FROM transactions WHERE txn_ref = p_ref;
    RETURN v;
  EXCEPTION WHEN NO_DATA_FOUND THEN
    RETURN 'NONE';
  END;

  -- Makes the session user (SYS) the database user of this employee, and of no other.
  PROCEDURE act_as(p_employee_id NUMBER) IS
  BEGIN
    UPDATE employees SET db_username = NULL WHERE db_username = SYS_CONTEXT('USERENV', 'SESSION_USER');
    UPDATE employees SET db_username = SYS_CONTEXT('USERENV', 'SESSION_USER') WHERE employee_id = p_employee_id;
  END;

  PROCEDURE defer_again IS
  BEGIN
    FOR a IN (SELECT assertion_name FROM dba_assertions WHERE owner = 'WELBANK' AND deferrable = 'DEFERRABLE') LOOP
      EXECUTE IMMEDIATE 'SET CONSTRAINT welbank.' || a.assertion_name || ' DEFERRED';
    END LOOP;
  END;

  -- An account with p_customer as primary holder; approved and open for debits unless p_pending.
  FUNCTION new_account(p_product NUMBER, p_currency VARCHAR2, p_customer NUMBER,
                       p_overdraft NUMBER DEFAULT 0, p_debits BOOLEAN DEFAULT TRUE, p_pending BOOLEAN DEFAULT FALSE) RETURN NUMBER IS
    v_id NUMBER;
  BEGIN
    IF p_pending THEN
      INSERT INTO accounts (account_class, product_id, branch_id, currency_code, account_name, mandate, opened_by)
        VALUES ('CUSTOMER', p_product, v_branch, p_currency, 'Test account', 'SOLE', v_teller)
        RETURNING account_id INTO v_id;
    ELSE
      INSERT INTO accounts (account_class, product_id, branch_id, currency_code, account_name, mandate, opened_by,
                            status, checked_by, checked_at, post_no_debit, overdraft_limit)
        VALUES ('CUSTOMER', p_product, v_branch, p_currency, 'Test account', 'SOLE', v_teller,
                'ACTIVE', v_sup, SYSTIMESTAMP, NOT p_debits, p_overdraft)
        RETURNING account_id INTO v_id;
    END IF;
    INSERT INTO account_holders (account_id, customer_id, holder_role) VALUES (v_id, p_customer, 'PRIMARY');
    RETURN v_id;
  END;

  FUNCTION account_no(p_account_id NUMBER) RETURN VARCHAR2 IS
    v VARCHAR2(13);
  BEGIN
    SELECT account_no INTO v FROM accounts WHERE account_id = p_account_id;
    RETURN v;
  END;

  FUNCTION new_customer(p_first VARCHAR2, p_kyc VARCHAR2) RETURN NUMBER IS
    v_id NUMBER;
  BEGIN
    IF p_kyc = 'VERIFIED' THEN
      INSERT INTO customers (first_name, last_name, sex, date_of_birth, nationality, home_branch_id, employment_status, income_band,
                             source_of_funds, account_purpose, expected_monthly_volume, data_consent_at,
                             kyc_status, kyc_approved_by, kyc_approved_at, risk_rating)
        VALUES (p_first, 'Tester', 'MALE', DATE '1985-01-01', 'ZZA', v_branch, 'EMPLOYED', '1K_5K',
                'SALARY', 'SAVINGS', 2000, SYSTIMESTAMP, 'VERIFIED', v_sup, SYSTIMESTAMP, 'LOW') RETURNING customer_id INTO v_id;
    ELSE
      INSERT INTO customers (first_name, last_name, sex, date_of_birth, nationality, home_branch_id, employment_status, income_band,
                             source_of_funds, account_purpose, expected_monthly_volume, data_consent_at, kyc_status, kyc_deferral_until)
        VALUES (p_first, 'Tester', 'MALE', DATE '1999-01-01', 'ZZA', v_branch, 'STUDENT', 'UNDER_1K',
                'GIFT', 'SAVINGS', 300, SYSTIMESTAMP, 'DEFERRED', TRUNC(SYSDATE) + 90) RETURNING customer_id INTO v_id;
    END IF;
    RETURN v_id;
  END;

  FUNCTION new_employee(p_first VARCHAR2, p_job NUMBER, p_branch NUMBER) RETURN NUMBER IS
    v_id NUMBER;
  BEGIN
    INSERT INTO employees (first_name, last_name, sex, date_of_birth, nationality, work_email, phone, job_id, branch_id, salary, hire_date)
      VALUES (p_first, 'Tester', 'FEMALE', DATE '1990-01-01', 'ZZA', LOWER(p_first) || '.t7@example.com', '+233200000700',
              p_job, p_branch, 30000, DATE '2020-01-06') RETURNING employee_id INTO v_id;
    RETURN v_id;
  END;
BEGIN
  -- ---------------------------------------------------------------- fixtures
  MERGE INTO countries c USING (SELECT 'ZZA' code FROM dual) s ON (c.country_code = s.code)
    WHEN NOT MATCHED THEN INSERT (country_code, country_name, nationality_name) VALUES ('ZZA', 'Testland', 'Testlander');
  MERGE INTO countries c USING (SELECT 'GHA' code FROM dual) s ON (c.country_code = s.code)
    WHEN NOT MATCHED THEN INSERT (country_code, country_name, nationality_name) VALUES ('GHA', 'Ghana', 'Ghanaian');
  INSERT INTO currencies (currency_code, currency_name) VALUES ('XTS', 'Test currency XTS');
  INSERT INTO currencies (currency_code, currency_name) VALUES ('XXX', 'Test currency XXX');
  INSERT INTO regions (region_name) VALUES ('Test region 7') RETURNING region_id INTO v_region;
  INSERT INTO branches (branch_code, branch_name, region_id, phone, opened_on)
    VALUES ('T-BR7', 'Test branch 7', v_region, '+233200000701', DATE '2020-01-01') RETURNING branch_id INTO v_branch;
  INSERT INTO branches (branch_code, branch_name, region_id, phone, opened_on)
    VALUES ('T-BR8', 'Test branch 8', v_region, '+233200000801', DATE '2020-01-01') RETURNING branch_id INTO v_branch2;
  INSERT INTO departments (department_name) VALUES ('Test operations 7') RETURNING department_id INTO v_dept;
  INSERT INTO jobs (job_title, department_id, min_salary, max_salary) VALUES ('Test teller 7', v_dept, 20000, 40000) RETURNING job_id INTO v_job_teller;
  INSERT INTO jobs (job_title, department_id, min_salary, max_salary) VALUES ('Test supervisor 7', v_dept, 20000, 90000) RETURNING job_id INTO v_job_sup;
  -- A teller may post up to 1,000 alone; a supervisor up to 50,000 (and may reverse).
  INSERT INTO transaction_limits (job_id, txn_type, currency_code, max_amount)
    SELECT v_job_teller, column_value, 'XTS', 1000 FROM TABLE(sys.odcivarchar2list('CASH_DEPOSIT', 'CASH_WITHDRAWAL', 'TRANSFER'));
  INSERT INTO transaction_limits (job_id, txn_type, currency_code, max_amount)
    SELECT v_job_sup, column_value, 'XTS', 50000 FROM TABLE(sys.odcivarchar2list('CASH_DEPOSIT', 'CASH_WITHDRAWAL', 'TRANSFER', 'REVERSAL'));
  v_teller  := new_employee('Adjoa', v_job_teller, v_branch);
  v_teller2 := new_employee('Yaa', v_job_teller, v_branch2);
  v_sup     := new_employee('Esi', v_job_sup, v_branch);
  v_c1 := new_customer('Kofi', 'VERIFIED');
  v_c2 := new_customer('Ama', 'VERIFIED');
  v_c3 := new_customer('Kwesi', 'DEFERRED');
  INSERT INTO account_products (product_code, product_name, account_type, currency_code)
    VALUES ('T7-SAV', 'Test savings 7', 'SAVINGS', 'XTS') RETURNING product_id INTO v_sav;
  INSERT INTO account_products (product_code, product_name, account_type, currency_code, overdraft_allowed)
    VALUES ('T7-CUR', 'Test current 7', 'CURRENT', 'XTS', TRUE) RETURNING product_id INTO v_cur;
  INSERT INTO account_products (product_code, product_name, account_type, currency_code)
    VALUES ('T7-SAVX', 'Test savings 7 XXX', 'SAVINGS', 'XXX') RETURNING product_id INTO v_sav_xxx;
  INSERT INTO accounts (account_class, internal_purpose, branch_id, currency_code, account_name, status, post_no_debit)
    VALUES ('INTERNAL', 'VAULT_CASH', v_branch, 'XTS', 'Vault cash 7', 'ACTIVE', FALSE) RETURNING account_id INTO v_vault;
  INSERT INTO accounts (account_class, internal_purpose, branch_id, currency_code, account_name, status, post_no_debit)
    VALUES ('INTERNAL', 'VAULT_CASH', v_branch2, 'XTS', 'Vault cash 8', 'ACTIVE', FALSE) RETURNING account_id INTO v_vault2;
  v_a := new_account(v_sav, 'XTS', v_c1);                          -- Kofi's savings
  v_b := new_account(v_sav, 'XTS', v_c2);                          -- Ama's savings
  v_c := new_account(v_sav, 'XTS', v_c3, p_debits => FALSE);       -- Kwesi (KYC deferred): deposits only
  v_d := new_account(v_cur, 'XTS', v_c2, p_overdraft => 500);      -- Ama's current account, 500 overdraft
  v_p := new_account(v_sav, 'XTS', v_c1, p_pending => TRUE);       -- waiting for approval
  v_x := new_account(v_sav_xxx, 'XXX', v_c1);                      -- in another currency
  v_no_a := account_no(v_a); v_no_b := account_no(v_b); v_no_c := account_no(v_c);
  v_no_d := account_no(v_d); v_no_p := account_no(v_p); v_no_x := account_no(v_x);

  -- ------------------------------------------------------------------ identity
  rejects('posting by a session user who is not an employee',
    call('cash_deposit(' || q(v_no_a) || ', 100)'), 'ORA-20001');

  -- ------------------------------------------------------------------ deposits
  act_as(v_teller);
  v_ref := ref_of('deposit', 'cash_deposit(' || q(v_no_a) || ', 500)');
  check_that('teller deposits 500 into Kofi''s account: ' || v_ref || ' ' || status_of(v_ref), status_of(v_ref) = 'POSTED');
  check_that('balances: account 500, vault 500', balance(v_a) = 500 AND balance(v_vault) = 500);
  SELECT COUNT(*) INTO v_count FROM ledger_entries e JOIN transactions t ON t.txn_id = e.txn_id
   WHERE t.txn_ref = v_ref
     AND ((e.line_no = 1 AND e.account_id = v_vault AND e.direction = 'DR' AND e.balance_after = 500)
       OR (e.line_no = 2 AND e.account_id = v_a AND e.direction = 'CR' AND e.balance_after = 500));
  check_that('two lines: debit vault, credit account, each with balance_after 500', v_count = 2);
  SELECT COUNT(*) INTO v_count FROM audit_trail
   WHERE entity_id = v_ref AND event_type = 'TXN_POSTED' AND employee_id = v_teller
     AND JSON_VALUE(new_values, '$.amount' RETURNING NUMBER) = 500;
  check_that('audit trail records the posting and the teller', v_count = 1);
  rejects('deposit of 0', call('cash_deposit(' || q(v_no_a) || ', 0)'), 'ORA-20009');
  rejects('deposit of 10.005 (more decimals than the currency has)', call('cash_deposit(' || q(v_no_a) || ', 10.005)'), 'ORA-20009');
  rejects('deposit into an account that does not exist', call('cash_deposit(''9999999999999'', 10)'), 'ORA-20002');
  rejects('deposit into an account waiting for approval', call('cash_deposit(' || q(v_no_p) || ', 10)'), 'ORA-20003');
  rejects('deposit in a currency the branch holds no cash in', call('cash_deposit(' || q(v_no_x) || ', 10)'), 'ORA-20010');
  v_ref := ref_of('deposit', 'cash_deposit(' || q(v_no_c) || ', 200)');
  check_that('deposit into a deposits-only account (customer''s KYC deferred) is allowed', status_of(v_ref) = 'POSTED' AND balance(v_c) = 200);

  -- --------------------------------------------------------------- withdrawals
  v_ref := ref_of('withdrawal', 'cash_withdrawal(' || q(v_no_a) || ', 200)');
  check_that('withdrawal of 200: account 300, vault 500', status_of(v_ref) = 'POSTED' AND balance(v_a) = 300 AND balance(v_vault) = 500);
  rejects('withdrawal from a deposits-only account', call('cash_withdrawal(' || q(v_no_c) || ', 50)'), 'ORA-20004');
  rejects('withdrawal of 400 with 300 in the account', call('cash_withdrawal(' || q(v_no_a) || ', 400)'), 'ORA-20005');
  v_ref := ref_of('deposit', 'cash_deposit(' || q(v_no_d) || ', 100)');
  v_ref := ref_of('withdrawal', 'cash_withdrawal(' || q(v_no_d) || ', 450)');
  check_that('current account overdrawn to -350, within its 500 overdraft', status_of(v_ref) = 'POSTED' AND balance(v_d) = -350);
  rejects('withdrawal beyond the overdraft (-550)', call('cash_withdrawal(' || q(v_no_d) || ', 200)'), 'ORA-20005');
  act_as(v_teller2);
  rejects('withdrawal at a branch whose vault is empty', call('cash_withdrawal(' || q(v_no_a) || ', 100)'), 'ORA-20006');

  -- ----------------------------------------------------------------- transfers
  act_as(v_teller);
  v_tr_ref := ref_of('transfer', 'transfer(' || q(v_no_a) || ', ' || q(v_no_b) || ', 100)');
  check_that('transfer of 100: Kofi 200, Ama 100', status_of(v_tr_ref) = 'POSTED' AND balance(v_a) = 200 AND balance(v_b) = 100);
  rejects('transfer from an account to itself', call('transfer(' || q(v_no_a) || ', ' || q(v_no_a) || ', 10)'), 'ORA-20008');
  rejects('transfer between currencies', call('transfer(' || q(v_no_a) || ', ' || q(v_no_x) || ', 10)'), 'ORA-20007');
  rejects('transfer out of a deposits-only account', call('transfer(' || q(v_no_c) || ', ' || q(v_no_b) || ', 10)'), 'ORA-20004');

  -- --------------------------------------------------------------- maker-checker
  v_big_ref := ref_of('deposit', 'cash_deposit(' || q(v_no_a) || ', 5000)');
  check_that('deposit of 5,000, above the teller''s 1,000 limit, waits: ' || status_of(v_big_ref), status_of(v_big_ref) = 'PENDING');
  check_that('nothing moved yet: account still 200', balance(v_a) = 200);
  SELECT COUNT(*) INTO v_count FROM approval_requests r JOIN transactions t ON t.txn_id = r.txn_id
   WHERE t.txn_ref = v_big_ref AND r.request_type = 'TXN_APPROVAL' AND r.status = 'PENDING'
     AND JSON_VALUE(r.payload, '$.lines.size()') = 2;
  check_that('a pending approval request holds the two planned lines (JSON)', v_count = 1);
  rejects('teller approving their own transaction', 'BEGIN pkg_posting.approve_transaction(' || q(v_big_ref) || '); END;', 'ORA-20013');
  act_as(v_teller2);
  rejects('another teller, whose limit is only 1,000', 'BEGIN pkg_posting.approve_transaction(' || q(v_big_ref) || '); END;', 'ORA-20014');
  act_as(v_sup);
  accepts('supervisor approves', 'BEGIN pkg_posting.approve_transaction(' || q(v_big_ref) || '); END;');
  SELECT COUNT(*) INTO v_count FROM transactions t JOIN approval_requests r ON r.txn_id = t.txn_id
   WHERE t.txn_ref = v_big_ref AND t.status = 'POSTED' AND t.checked_by = v_sup
     AND r.status = 'APPROVED' AND r.decided_by = v_sup;
  check_that('posted, checked by the supervisor, request approved; account 5,200', v_count = 1 AND balance(v_a) = 5200);
  rejects('approving it a second time', 'BEGIN pkg_posting.approve_transaction(' || q(v_big_ref) || '); END;', 'ORA-20012');
  rejects('approving a transaction that does not exist', 'BEGIN pkg_posting.approve_transaction(''TXN000000000000''); END;', 'ORA-20011');

  act_as(v_teller);
  v_rej_ref := ref_of('transfer', 'transfer(' || q(v_no_a) || ', ' || q(v_no_b) || ', 3000)');
  act_as(v_sup);
  rejects('rejecting without a reason', 'BEGIN pkg_posting.reject_transaction(' || q(v_rej_ref) || ', '' ''); END;', 'ORA-20017');
  accepts('supervisor rejects a pending transfer', 'BEGIN pkg_posting.reject_transaction(' || q(v_rej_ref) || ', ''Customer cancelled''); END;');
  SELECT COUNT(*) INTO v_count FROM transactions t
   WHERE t.txn_ref = v_rej_ref AND t.status = 'REJECTED' AND t.rejection_reason = 'Customer cancelled'
     AND NOT EXISTS (SELECT 1 FROM ledger_entries e WHERE e.txn_id = t.txn_id);
  check_that('rejected, with its reason and no ledger lines', v_count = 1);

  -- Funds are checked again at approval time.
  act_as(v_teller);
  v_wd_ref := ref_of('withdrawal', 'cash_withdrawal(' || q(v_no_a) || ', 4000)');
  act_as(v_sup);
  v_ref := ref_of('transfer', 'transfer(' || q(v_no_a) || ', ' || q(v_no_b) || ', 2000)');
  check_that('meanwhile the supervisor transfers 2,000 out (within their limit): account 3,200', status_of(v_ref) = 'POSTED' AND balance(v_a) = 3200);
  rejects('approving the 4,000 withdrawal, now more than the account holds',
    'BEGIN pkg_posting.approve_transaction(' || q(v_wd_ref) || '); END;', 'ORA-20005');
  SELECT COUNT(*) INTO v_count FROM transactions WHERE txn_ref = v_wd_ref AND status = 'PENDING' AND checked_by IS NULL;
  check_that('the refused approval left nothing behind (still PENDING, no checker)', v_count = 1);

  -- ----------------------------------------------------------------- reversals
  act_as(v_teller);
  BEGIN
    v_request := pkg_posting.request_reversal(v_tr_ref, 'Wrong account');
    check_that('teller asks to reverse the 100 transfer (request ' || v_request || ')', v_request IS NOT NULL);
  EXCEPTION WHEN OTHERS THEN
    check_that('teller asks to reverse the 100 transfer  -> ' || SQLERRM, FALSE);
  END;
  rejects('asking twice', 'DECLARE r NUMBER; BEGIN r := pkg_posting.request_reversal(' || q(v_tr_ref) || ', ''Again''); END;', 'ORA-20015');
  rejects('the requester approving their own reversal', call('approve_reversal(' || v_request || ')'), 'ORA-20013');
  act_as(v_sup);
  v_rev_ref := ref_of('reversal', 'approve_reversal(' || v_request || ')');
  check_that('supervisor approves: reversal ' || v_rev_ref || ' posted, original REVERSED',
             status_of(v_rev_ref) = 'POSTED' AND status_of(v_tr_ref) = 'REVERSED');
  check_that('balances restored: Kofi 3,300, Ama 2,000', balance(v_a) = 3300 AND balance(v_b) = 2000);
  SELECT COUNT(*) INTO v_count
    FROM ledger_entries o JOIN transactions ot ON ot.txn_id = o.txn_id AND ot.txn_ref = v_tr_ref
    JOIN transactions rt ON rt.txn_ref = v_rev_ref AND rt.reverses_txn_id = ot.txn_id
    JOIN ledger_entries r ON r.txn_id = rt.txn_id AND r.account_id = o.account_id AND r.amount = o.amount
                         AND r.direction <> o.direction;
  check_that('every reversal line mirrors an original line', v_count = 2);
  rejects('reversing a reversal', 'DECLARE r NUMBER; BEGIN r := pkg_posting.request_reversal(' || q(v_rev_ref) || ', ''x''); END;', 'ORA-20015');
  rejects('reversing a transaction still PENDING', 'DECLARE r NUMBER; BEGIN r := pkg_posting.request_reversal(' || q(v_wd_ref) || ', ''x''); END;', 'ORA-20015');
  rejects('approving a reversal request that does not exist', call('approve_reversal(-1)'), 'ORA-20016');

  -- ---------------------------------------------------------- suspended employee
  act_as(v_teller);
  UPDATE employees SET status = 'SUSPENDED' WHERE employee_id = v_teller;
  rejects('a suspended teller is refused at once (no caching)', call('cash_deposit(' || q(v_no_a) || ', 10)'), 'ORA-20001');
  UPDATE employees SET status = 'ACTIVE' WHERE employee_id = v_teller;

  -- ------------------------------------------------------- the ledger agrees
  SELECT COUNT(*) INTO v_count FROM v_ledger_balance_check
   WHERE account_id IN (v_a, v_b, v_c, v_d, v_p, v_x, v_vault, v_vault2) AND difference <> 0;
  check_that('reconciliation view: every stored balance equals the sum of its lines', v_count = 0);
  SELECT COUNT(*), SUM(CASE WHEN running_balance = balance_after THEN 1 ELSE 0 END) INTO v_count, v_num
    FROM v_account_statement WHERE account_id = v_a;
  check_that('statement view: running balance = balance_after on all ' || v_count || ' lines of Kofi''s account', v_count > 0 AND v_num = v_count);
  SELECT COUNT(*) INTO v_count FROM (
    SELECT e.txn_id FROM ledger_entries e JOIN transactions t ON t.txn_id = e.txn_id
     WHERE t.branch_id IN (v_branch, v_branch2)
     GROUP BY e.txn_id
    HAVING SUM(CASE e.direction WHEN 'DR' THEN e.amount ELSE 0 END) <> SUM(CASE e.direction WHEN 'CR' THEN e.amount ELSE 0 END));
  check_that('every transaction posted by the test is balanced', v_count = 0);
  accepts('every COMMIT-time rule holds (checked now)', 'SET CONSTRAINTS ALL IMMEDIATE');
  defer_again;
  SELECT COUNT(*) INTO v_count FROM dba_objects WHERE owner = 'WELBANK' AND status = 'INVALID';
  check_that('no invalid objects in the schema', v_count = 0);

  DBMS_OUTPUT.PUT_LINE('RESULT: ' || passed || ' passed, ' || failed || ' failed');
  ROLLBACK;
END;
/
