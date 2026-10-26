-- =============================================================================
-- 0009_loans_test.sql — pkg_loan: schedules, applications and decisions,
-- disbursement, the end-of-day run (interest, arrears, Bank of Ghana class),
-- repayments and closure; and pkg_ledger's ACCESSIBLE BY protection.
--
-- Run by database/tests/run_tests.sh as SYSDBA inside WELBANK. Everything runs
-- in one transaction that is rolled back at the end: no data is left behind.
-- act_as() chooses which test employee the session user (SYS) is. Dates in
-- the future are simulated with the p_as_of parameter of run_end_of_day and repay.
-- =============================================================================
SET SERVEROUTPUT ON SIZE UNLIMITED FEEDBACK OFF LINESIZE 200
ALTER SESSION SET CURRENT_SCHEMA = welbank;

DECLARE
  passed PLS_INTEGER := 0;
  failed PLS_INTEGER := 0;
  v_region NUMBER; v_branch NUMBER; v_dept NUMBER;
  v_job_officer NUMBER; v_job_manager NUMBER; v_job_junior NUMBER;
  v_officer NUMBER; v_manager NUMBER; v_junior NUMBER;
  v_borrower NUMBER; v_other NUMBER; v_unverified NUMBER;
  v_no_borrower VARCHAR2(12); v_no_unverified VARCHAR2(12);
  v_sav_prod NUMBER;
  v_income NUMBER; v_savings NUMBER; v_other_acc NUMBER;
  v_no_savings VARCHAR2(13); v_no_other VARCHAR2(13);
  v_app VARCHAR2(12); v_app2 VARCHAR2(12); v_app3 VARCHAR2(12); v_tight VARCHAR2(12);
  v_loan VARCHAR2(12); v_loan2 VARCHAR2(12);
  v_loan_id NUMBER; v_loan_acc NUMBER;
  v_first DATE := ADD_MONTHS(TRUNC(SYSDATE), 1);
  v_ref   VARCHAR2(20);
  v_count PLS_INTEGER;
  v_num   NUMBER; v_num2 NUMBER; v_num3 NUMBER;
  v_text  VARCHAR2(400);
  v_date  DATE;
  v_inst1 NUMBER; v_int1 NUMBER; v_int2 NUMBER;

  PROCEDURE accepts(p_name VARCHAR2, p_sql VARCHAR2) IS
  BEGIN
    EXECUTE IMMEDIATE p_sql;
    passed := passed + 1;
    DBMS_OUTPUT.PUT_LINE('PASS  accepts  ' || p_name);
  EXCEPTION WHEN OTHERS THEN
    failed := failed + 1;
    DBMS_OUTPUT.PUT_LINE('FAIL  accepts  ' || p_name || '  -> ' || SQLERRM);
  END;

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

  FUNCTION q(p_text VARCHAR2) RETURN VARCHAR2 IS
  BEGIN
    RETURN '''' || REPLACE(p_text, '''', '''''') || '''';
  END;

  FUNCTION d(p_date DATE) RETURN VARCHAR2 IS
  BEGIN
    RETURN 'DATE ''' || TO_CHAR(p_date, 'YYYY-MM-DD') || '''';
  END;

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

  FUNCTION balance(p_account_id NUMBER) RETURN NUMBER IS
    v NUMBER;
  BEGIN
    SELECT ledger_balance INTO v FROM accounts WHERE account_id = p_account_id;
    RETURN v;
  END;

  FUNCTION submit_sql(p_customer_no VARCHAR2, p_amount NUMBER, p_term NUMBER, p_income NUMBER DEFAULT 4000) RETURN VARCHAR2 IS
  BEGIN
    RETURN 'DECLARE r VARCHAR2(12); BEGIN r := pkg_loan.submit_application(' || q(p_customer_no) || ', ''T10-SME'', '
        || p_amount || ', ' || p_term || ', ''BUSINESS'', ' || p_income || '); END;';
  END;

  FUNCTION new_customer(p_first VARCHAR2, p_verified BOOLEAN) RETURN NUMBER IS
    v_id NUMBER;
  BEGIN
    INSERT INTO customers (first_name, last_name, sex, date_of_birth, nationality, home_branch_id, employment_status, income_band,
                           source_of_funds, account_purpose, expected_monthly_volume, data_consent_at,
                           kyc_status, kyc_approved_by, kyc_approved_at, risk_rating)
      VALUES (p_first, 'Tester', 'MALE', DATE '1985-01-01', 'GHA', v_branch, 'SELF_EMPLOYED', '5K_10K', 'BUSINESS', 'BUSINESS', 6000,
              SYSTIMESTAMP, CASE WHEN p_verified THEN 'VERIFIED' ELSE 'PENDING_VERIFICATION' END,
              CASE WHEN p_verified THEN v_manager END, CASE WHEN p_verified THEN SYSTIMESTAMP END,
              CASE WHEN p_verified THEN 'LOW' END)
      RETURNING customer_id INTO v_id;
    RETURN v_id;
  END;

  FUNCTION new_savings(p_customer NUMBER) RETURN NUMBER IS
    v_id NUMBER;
  BEGIN
    INSERT INTO accounts (account_class, product_id, branch_id, currency_code, account_name, mandate, opened_by,
                          status, checked_by, checked_at, post_no_debit)
      VALUES ('CUSTOMER', v_sav_prod, v_branch, 'XTS', 'Test savings', 'SOLE', v_officer, 'ACTIVE', v_manager, SYSTIMESTAMP, FALSE)
      RETURNING account_id INTO v_id;
    INSERT INTO account_holders (account_id, customer_id, holder_role) VALUES (v_id, p_customer, 'PRIMARY');
    RETURN v_id;
  END;

  FUNCTION new_employee(p_first VARCHAR2, p_job NUMBER) RETURN NUMBER IS
    v_id NUMBER;
  BEGIN
    INSERT INTO employees (first_name, last_name, sex, date_of_birth, nationality, work_email, phone, job_id, branch_id, salary, hire_date)
      VALUES (p_first, 'Tester', 'FEMALE', DATE '1988-01-01', 'GHA', LOWER(p_first) || '.t10@example.com', '+233200001000',
              p_job, v_branch, 50000, DATE '2018-01-08') RETURNING employee_id INTO v_id;
    RETURN v_id;
  END;
BEGIN
  -- ---------------------------------------------------------------- fixtures
  MERGE INTO countries c USING (SELECT 'GHA' code FROM dual) s ON (c.country_code = s.code)
    WHEN NOT MATCHED THEN INSERT (country_code, country_name, nationality_name) VALUES ('GHA', 'Ghana', 'Ghanaian');
  MERGE INTO loan_classes c
  USING (SELECT 'CURRENT' code, 'Current' name, 0 lo, 29 hi, 1 pct, FALSE npl FROM dual UNION ALL
         SELECT 'OLEM', 'Other loans especially mentioned', 30, 89, 5, FALSE FROM dual UNION ALL
         SELECT 'SUBSTANDARD', 'Substandard', 90, 179, 25, TRUE FROM dual UNION ALL
         SELECT 'DOUBTFUL', 'Doubtful', 180, 359, 50, TRUE FROM dual UNION ALL
         SELECT 'LOSS', 'Loss', 360, 99999, 100, TRUE FROM dual) s
  ON (c.class_code = s.code)
  WHEN NOT MATCHED THEN INSERT (class_code, class_name, min_days_past_due, max_days_past_due, provision_pct, is_non_performing)
    VALUES (s.code, s.name, s.lo, s.hi, s.pct, s.npl);
  INSERT INTO currencies (currency_code, currency_name) VALUES ('XTS', 'Test currency XTS');
  INSERT INTO regions (region_name) VALUES ('Test region 10') RETURNING region_id INTO v_region;
  INSERT INTO branches (branch_code, branch_name, region_id, phone, opened_on)
    VALUES ('T-BR10', 'Test branch 10', v_region, '+233200001001', DATE '2020-01-01') RETURNING branch_id INTO v_branch;
  INSERT INTO departments (department_name) VALUES ('Test credit 10') RETURNING department_id INTO v_dept;
  INSERT INTO jobs (job_title, department_id, min_salary, max_salary) VALUES ('Test loan officer 10', v_dept, 20000, 90000) RETURNING job_id INTO v_job_officer;
  INSERT INTO jobs (job_title, department_id, min_salary, max_salary) VALUES ('Test credit manager 10', v_dept, 20000, 90000) RETURNING job_id INTO v_job_manager;
  INSERT INTO jobs (job_title, department_id, min_salary, max_salary) VALUES ('Test junior analyst 10', v_dept, 20000, 90000) RETURNING job_id INTO v_job_junior;
  -- Credit authority: the job's LOAN_DISBURSEMENT limit.
  INSERT INTO transaction_limits (job_id, txn_type, currency_code, max_amount) VALUES (v_job_manager, 'LOAN_DISBURSEMENT', 'XTS', 100000);
  INSERT INTO transaction_limits (job_id, txn_type, currency_code, max_amount) VALUES (v_job_junior, 'LOAN_DISBURSEMENT', 'XTS', 1000);
  v_officer := new_employee('Akua', v_job_officer);
  v_manager := new_employee('Kwabena', v_job_manager);
  v_junior  := new_employee('Fiifi', v_job_junior);
  v_borrower   := new_customer('Kofi', TRUE);
  v_other      := new_customer('Ama', TRUE);
  v_unverified := new_customer('Yaw', FALSE);
  SELECT customer_no INTO v_no_borrower FROM customers WHERE customer_id = v_borrower;
  SELECT customer_no INTO v_no_unverified FROM customers WHERE customer_id = v_unverified;
  INSERT INTO account_products (product_code, product_name, account_type, currency_code)
    VALUES ('T10-SAV', 'Test savings 10', 'SAVINGS', 'XTS') RETURNING product_id INTO v_sav_prod;
  INSERT INTO loan_products (product_code, product_name, currency_code, interest_rate, min_amount, max_amount, max_term_months)
    VALUES ('T10-SME', 'Test SME loan 10', 'XTS', 18, 1000, 50000, 36);
  INSERT INTO accounts (account_class, internal_purpose, branch_id, currency_code, account_name, status, post_no_debit)
    VALUES ('INTERNAL', 'INTEREST_INCOME', v_branch, 'XTS', 'Interest income 10', 'ACTIVE', FALSE) RETURNING account_id INTO v_income;
  v_savings   := new_savings(v_borrower);
  v_other_acc := new_savings(v_other);
  SELECT account_no INTO v_no_savings FROM accounts WHERE account_id = v_savings;
  SELECT account_no INTO v_no_other FROM accounts WHERE account_id = v_other_acc;
  -- Pricing uses the parameter of the month (the test does not depend on its value).
  UPDATE bank_parameters SET num_value = 10.04 WHERE param_name = 'GHANA_REFERENCE_RATE';

  -- --------------------------------------------------------------- schedules
  SELECT COUNT(*), SUM(principal_due), MIN(balance_after),
         MAX(CASE WHEN installment_no = 1 THEN interest_due END),
         MAX(CASE WHEN installment_no = 1 THEN total_due END)
    INTO v_count, v_num, v_num2, v_int1, v_inst1
    FROM TABLE(pkg_loan.schedule_preview(5000, 16.54, 12, v_first));
  check_that('pipelined schedule: 12 rows, principal adds up to 5,000, ends at 0', v_count = 12 AND v_num = 5000 AND v_num2 = 0);
  check_that('first interest = 5,000 x 16.54 % / 12 = ' || v_int1 || '; installment = ' || v_inst1,
             v_int1 = 68.92 AND v_inst1 = pkg_loan.monthly_installment(5000, 16.54, 12));
  check_that('interest-free: 5,000 over 10 months = 500 a month', pkg_loan.monthly_installment(5000, 0, 10) = 500);

  -- ------------------------------------------------------------ applications
  rejects('applying as a non-employee', submit_sql(v_no_borrower, 5000, 12), 'ORA-20001');
  act_as(v_officer);
  rejects('applicant whose identity is not verified', submit_sql(v_no_unverified, 5000, 12), 'ORA-20026');
  rejects('amount below the product minimum (500)', submit_sql(v_no_borrower, 500, 12), 'ORA-20027');
  rejects('term above the product maximum (48 months)', submit_sql(v_no_borrower, 5000, 48), 'ORA-20027');
  rejects('repayments above 40 % of income (20,000 on 1,000 a month)', submit_sql(v_no_borrower, 20000, 12, 1000), 'ORA-20028');
  v_app := pkg_loan.submit_application(v_no_borrower, 'T10-SME', 5000, 12, 'BUSINESS', 4000);
  SELECT COUNT(*) INTO v_count FROM v_pending_approvals WHERE target_ref = v_app AND target_kind = 'LOAN_APPLICATION';
  check_that('application ' || v_app || ' submitted and waiting in the checkers'' queue', REGEXP_LIKE(v_app, '^LAP[0-9]{9}$') AND v_count = 1);
  -- A tight case: income 1,200, so repayments may reach 480 a month. At the
  -- product's 18 % the installment is about 458 (accepted); at GRR + 20 % it
  -- is about 488.
  v_tight := pkg_loan.submit_application(v_no_borrower, 'T10-SME', 5000, 12, 'BUSINESS', 1200);

  rejects('the loan officer deciding their own application',
    'BEGIN pkg_loan.approve_application(' || q(v_app) || ', 5000, 12, 6.5); END;', 'ORA-20013');
  act_as(v_junior);
  rejects('an analyst whose credit authority is 1,000', 'BEGIN pkg_loan.approve_application(' || q(v_app) || ', 5000, 12, 6.5); END;', 'ORA-20014');
  act_as(v_manager);
  rejects('approving more than was asked for', 'BEGIN pkg_loan.approve_application(' || q(v_app) || ', 6000, 12, 6.5); END;', 'ORA-20022');
  rejects('a negative margin', 'BEGIN pkg_loan.approve_application(' || q(v_app) || ', 5000, 12, -1); END;', 'ORA-20022');
  rejects('a margin that makes the loan unaffordable at the real price (GRR + 20 %)',
    'BEGIN pkg_loan.approve_application(' || q(v_tight) || ', 5000, 12, 20); END;', 'ORA-20028');
  accepts('credit manager approves 5,000 over 12 months at GRR + 6.5 %', 'BEGIN pkg_loan.approve_application(' || q(v_app) || ', 5000, 12, 6.5); END;');
  SELECT COUNT(*) INTO v_count FROM loan_applications
   WHERE application_no = v_app AND status = 'APPROVED' AND approved_margin_pct = 6.5 AND decided_by = v_manager;
  SELECT COUNT(*) INTO v_num FROM v_pending_approvals WHERE target_ref = v_app;
  check_that('APPROVED with its margin; no longer in the queue', v_count = 1 AND v_num = 0);

  -- ------------------------------------------------------------ disbursement
  rejects('the approver paying the loan out (segregation of duties)',
    'DECLARE r VARCHAR2(12); BEGIN r := pkg_loan.disburse(' || q(v_app) || ', ' || q(v_no_savings) || '); END;', 'ORA-20013');
  act_as(v_officer);
  rejects('paying into an account the borrower does not hold',
    'DECLARE r VARCHAR2(12); BEGIN r := pkg_loan.disburse(' || q(v_app) || ', ' || q(v_no_other) || '); END;', 'ORA-20022');
  v_loan := pkg_loan.disburse(v_app, v_no_savings, v_first);
  SELECT loan_id, loan_account_id INTO v_loan_id, v_loan_acc FROM loans WHERE loan_no = v_loan;
  check_that('loan ' || v_loan || ' disbursed: savings 5,000, loan account owes 5,000',
             REGEXP_LIKE(v_loan, '^LN[0-9]{10}$') AND balance(v_savings) = 5000 AND balance(v_loan_acc) = 5000);
  SELECT COUNT(*) INTO v_count FROM accounts a JOIN account_holders h ON h.account_id = a.account_id
   WHERE a.account_id = v_loan_acc AND a.account_class = 'LOAN' AND a.status = 'ACTIVE'
     AND a.opened_by = v_officer AND a.checked_by = v_manager AND h.customer_id = v_borrower AND h.holder_role = 'PRIMARY';
  check_that('its LOAN account: opened by the officer, approved by the credit decision, borrower as primary holder', v_count = 1);
  SELECT COUNT(*) INTO v_count FROM loans
   WHERE loan_id = v_loan_id AND interest_rate = 16.54 AND maturity_date = ADD_MONTHS(v_first, 11) AND classification = 'CURRENT';
  check_that('priced at 10.04 + 6.5 = 16.54 %; matures with the 12th installment', v_count = 1);
  SELECT COUNT(*), SUM(principal_due) INTO v_count, v_num FROM loan_schedule WHERE loan_id = v_loan_id;
  check_that('12 installments written from the pipelined function, principal 5,000', v_count = 12 AND v_num = 5000);
  rejects('disbursing the same application twice',
    'DECLARE r VARCHAR2(12); BEGIN r := pkg_loan.disburse(' || q(v_app) || ', ' || q(v_no_savings) || '); END;', 'ORA-20022');
  rejects('repaying before anything is due',
    'DECLARE r VARCHAR2(20); BEGIN r := pkg_loan.repay(' || q(v_loan) || ', ' || q(v_no_savings) || ', 100, ' || d(v_first - 1) || '); END;',
    'ORA-20029');

  -- --------------------------------------------------------------- end of day
  pkg_loan.run_end_of_day(v_first);
  SELECT COUNT(*) INTO v_count FROM loan_schedule s JOIN transactions t ON t.txn_id = s.interest_txn_id
   WHERE s.loan_id = v_loan_id AND s.installment_no = 1 AND t.txn_type = 'INTEREST' AND t.channel = 'SYSTEM'
     AND t.status = 'POSTED' AND t.value_date = v_first AND s.status = 'DUE';
  check_that('on the first due date, its interest is charged by a SYSTEM transaction; not overdue yet', v_count = 1);
  check_that('loan account now owes 5,068.92; interest income 68.92',
             balance(v_loan_acc) = 5068.92 AND balance(v_income) = 68.92);
  pkg_loan.run_end_of_day(v_first + 45);
  pkg_loan.run_end_of_day(v_first + 45);   -- a second run the same day must change nothing
  SELECT interest_due INTO v_int2 FROM loan_schedule WHERE loan_id = v_loan_id AND installment_no = 2;
  SELECT COUNT(*) INTO v_count FROM loan_schedule WHERE loan_id = v_loan_id AND interest_txn_id IS NOT NULL;
  SELECT COUNT(*) INTO v_num FROM loan_schedule WHERE loan_id = v_loan_id AND status = 'OVERDUE';
  check_that('45 days later: 2 installments charged once each (run twice), both OVERDUE', v_count = 2 AND v_num = 2);
  SELECT COUNT(*) INTO v_count FROM loans WHERE loan_id = v_loan_id AND days_past_due = 45 AND classification = 'OLEM';
  check_that('45 days past due: classified OLEM (Other Loans Especially Mentioned)', v_count = 1);
  check_that('amount due = both installments = ' || pkg_loan.amount_due(v_loan, v_first + 45),
             pkg_loan.amount_due(v_loan, v_first + 45) = 2 * v_inst1);

  -- --------------------------------------------------------------- repayments
  rejects('repaying more than is due',
    'DECLARE r VARCHAR2(20); BEGIN r := pkg_loan.repay(' || q(v_loan) || ', ' || q(v_no_savings) || ', 99999, ' || d(v_first + 45) || '); END;',
    'ORA-20029');
  rejects('repaying from an account the borrower does not hold',
    'DECLARE r VARCHAR2(20); BEGIN r := pkg_loan.repay(' || q(v_loan) || ', ' || q(v_no_other) || ', 100, ' || d(v_first + 45) || '); END;',
    'ORA-20022');
  v_ref := pkg_loan.repay(v_loan, v_no_savings, v_inst1, v_first + 45);
  SELECT COUNT(*) INTO v_count FROM loan_schedule
   WHERE loan_id = v_loan_id AND installment_no = 1 AND status = 'PAID' AND paid_on = v_first + 45;
  SELECT COUNT(*) INTO v_num FROM loan_repayments r JOIN transactions t ON t.txn_id = r.txn_id
   WHERE t.txn_ref = v_ref AND r.installment_no = 1 AND r.interest_amount = v_int1 AND r.principal_amount = v_inst1 - v_int1;
  check_that('repaying one installment pays installment 1: interest ' || v_int1 || ' first, then principal', v_count = 1 AND v_num = 1);
  check_that('savings ' || balance(v_savings) || ', loan account ' || balance(v_loan_acc),
             balance(v_savings) = 5000 - v_inst1 AND balance(v_loan_acc) = 5000 + v_int1 + v_int2 - v_inst1);
  SELECT COUNT(*) INTO v_count FROM loans
   WHERE loan_id = v_loan_id AND days_past_due = (v_first + 45) - ADD_MONTHS(v_first, 1) AND classification = 'OLEM';
  check_that('days past due now count from installment 2; the class stays OLEM (no automatic upgrade)', v_count = 1);
  v_ref := pkg_loan.repay(v_loan, v_no_savings, 50, v_first + 45);
  SELECT COUNT(*) INTO v_count FROM loan_schedule
   WHERE loan_id = v_loan_id AND installment_no = 2 AND interest_paid = 50 AND principal_paid = 0 AND status = 'OVERDUE';
  check_that('a part payment of 50 goes to installment 2''s interest; still OVERDUE', v_count = 1);

  -- ------------------------------------------------------------------ closure
  act_as(v_officer);
  v_app2 := pkg_loan.submit_application(v_no_borrower, 'T10-SME', 1000, 2, 'BUSINESS', 4000);
  act_as(v_manager);
  pkg_loan.approve_application(v_app2, 1000, 2, 6.5);
  act_as(v_officer);
  v_loan2 := pkg_loan.disburse(v_app2, v_no_savings, v_first);
  pkg_loan.run_end_of_day(ADD_MONTHS(v_first, 1));
  v_num := pkg_loan.amount_due(v_loan2, ADD_MONTHS(v_first, 1));
  v_ref := pkg_loan.repay(v_loan2, v_no_savings, v_num, ADD_MONTHS(v_first, 1));
  SELECT COUNT(*) INTO v_count FROM loans l JOIN accounts a ON a.account_id = l.loan_account_id
   WHERE l.loan_no = v_loan2 AND l.status = 'CLOSED' AND l.closed_on = ADD_MONTHS(v_first, 1)
     AND l.days_past_due = 0 AND a.ledger_balance = 0;
  check_that('a 2-month loan repaid in full (' || v_num || '): CLOSED, nothing owed', v_count = 1);
  rejects('repaying a closed loan',
    'DECLARE r VARCHAR2(20); BEGIN r := pkg_loan.repay(' || q(v_loan2) || ', ' || q(v_no_savings) || ', 1, ' || d(ADD_MONTHS(v_first, 1)) || '); END;',
    'ORA-20022');

  -- ----------------------------------------------------------------- rejection
  v_app3 := pkg_loan.submit_application(v_no_borrower, 'T10-SME', 2000, 6, 'VEHICLE', 4000);
  act_as(v_manager);
  rejects('rejecting without a reason', 'BEGIN pkg_loan.reject_application(' || q(v_app3) || ', NULL); END;', 'ORA-20017');
  accepts('credit manager rejects an application', 'BEGIN pkg_loan.reject_application(' || q(v_app3) || ', ''Insufficient collateral''); END;');
  act_as(v_officer);
  rejects('disbursing a rejected application',
    'DECLARE r VARCHAR2(12); BEGIN r := pkg_loan.disburse(' || q(v_app3) || ', ' || q(v_no_savings) || '); END;', 'ORA-20022');
  rejects('a loan number that does not exist', 'DECLARE n NUMBER; BEGIN n := LENGTH(pkg_loan.repay(''LN0000000000'', ''x'', 1)); END;', 'ORA-20030');

  -- --------------------------------------------------------------- the ledger
  SELECT COUNT(*) INTO v_count FROM v_ledger_balance_check
   WHERE account_id IN (SELECT account_id FROM accounts WHERE branch_id = v_branch) AND difference <> 0;
  check_that('reconciliation: every balance at the test branch equals its ledger lines', v_count = 0);
  rejects('calling the posting core directly (ACCESSIBLE BY pkg_posting, pkg_loan)',
    'BEGIN pkg_ledger.check_amount(1, ''XTS''); END;', 'PLS-00904');
  accepts('every COMMIT-time rule holds (checked now)', 'SET CONSTRAINTS ALL IMMEDIATE');
  defer_again;
  SELECT COUNT(*) INTO v_count FROM dba_objects WHERE owner = 'WELBANK' AND status = 'INVALID';
  check_that('no invalid objects in the schema', v_count = 0);

  DBMS_OUTPUT.PUT_LINE('RESULT: ' || passed || ' passed, ' || failed || ' failed');
  ROLLBACK;
END;
/
