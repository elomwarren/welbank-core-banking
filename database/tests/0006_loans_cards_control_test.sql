-- =============================================================================
-- 0006_loans_cards_control_test.sql — rules of loans, cards, the maker-checker
-- queue and the audit trail (changelog 0006).
--
-- Run by database/tests/run_tests.sh as SYSDBA inside WELBANK. Everything runs
-- in one transaction that is rolled back at the end: no data is left behind
-- (rolling back also removes the audit_trail row: immutable tables forbid
-- UPDATE and DELETE, not ROLLBACK of an uncommitted insert).
--
-- Fixtures use the test currency XTS and the "no currency" code XXX. The loan
-- classes are the Bank of Ghana day bands, merged in only if missing.
-- =============================================================================
SET SERVEROUTPUT ON SIZE UNLIMITED FEEDBACK OFF LINESIZE 200
ALTER SESSION SET CURRENT_SCHEMA = welbank;

DECLARE
  passed PLS_INTEGER := 0;
  failed PLS_INTEGER := 0;
  v_region   NUMBER; v_branch  NUMBER; v_dept NUMBER; v_job NUMBER;
  v_officer  NUMBER; v_manager NUMBER;
  v_cust     NUMBER; v_cust2   NUMBER;
  v_sav_prod NUMBER; v_sav_prod_xxx NUMBER; v_loan_prod NUMBER;
  v_vault    NUMBER; v_sav     NUMBER; v_sav_xxx NUMBER; v_sav2 NUMBER;
  v_loan_acc NUMBER; v_loan_acc2 NUMBER;
  v_disb_txn NUMBER; v_rep_txn NUMBER; v_fee_txn NUMBER; v_pend_txn NUMBER;
  v_app      NUMBER; v_loan    NUMBER; v_card NUMBER; v_card2 NUMBER; v_req NUMBER;
  v_no       VARCHAR2(20);
  v_text     VARCHAR2(400);
  v_count    PLS_INTEGER;
  v_rate     NUMBER;
  v_date     DATE;
  v_int_txn  NUMBER;

  PROCEDURE accepts(p_name VARCHAR2, p_sql VARCHAR2) IS
  BEGIN
    EXECUTE IMMEDIATE p_sql;
    passed := passed + 1;
    DBMS_OUTPUT.PUT_LINE('PASS  accepts  ' || p_name);
  EXCEPTION WHEN OTHERS THEN
    failed := failed + 1;
    DBMS_OUTPUT.PUT_LINE('FAIL  accepts  ' || p_name || '  -> ' || SQLERRM);
  END;

  -- Runs p_sql and expects it to fail with p_expect (a constraint, assertion
  -- or error code) somewhere in the error stack. p_expect is a regular
  -- expression, so 'A|B' accepts either of two equally correct rules.
  PROCEDURE rejects(p_name VARCHAR2, p_sql VARCHAR2, p_expect VARCHAR2) IS
  BEGIN
    EXECUTE IMMEDIATE p_sql;
    failed := failed + 1;
    DBMS_OUTPUT.PUT_LINE('FAIL  rejects  ' || p_name || '  -> was accepted');
  EXCEPTION WHEN OTHERS THEN
    IF REGEXP_LIKE(DBMS_UTILITY.FORMAT_ERROR_STACK, p_expect) THEN
      passed := passed + 1;
      DBMS_OUTPUT.PUT_LINE('PASS  rejects  ' || p_name);
    ELSE
      failed := failed + 1;
      DBMS_OUTPUT.PUT_LINE('FAIL  rejects  ' || p_name || '  -> expected ' || p_expect || ', got ' || SQLERRM);
    END IF;
  END;

  -- Puts the DEFERRABLE assertions back to deferred, by name (never
  -- "SET CONSTRAINTS ALL DEFERRED": see 0005_accounts_ledger_test.sql).
  PROCEDURE defer_again IS
  BEGIN
    FOR a IN (SELECT assertion_name FROM dba_assertions
               WHERE owner = 'WELBANK' AND deferrable = 'DEFERRABLE') LOOP
      EXECUTE IMMEDIATE 'SET CONSTRAINT welbank.' || a.assertion_name || ' DEFERRED';
    END LOOP;
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

  -- An approved account that allows debits, with p_customer as its primary holder.
  FUNCTION new_account(p_class VARCHAR2, p_product NUMBER, p_currency VARCHAR2, p_customer NUMBER) RETURN NUMBER IS
    v_id NUMBER;
  BEGIN
    INSERT INTO accounts (account_class, product_id, branch_id, currency_code, account_name, mandate,
                          opened_by, status, checked_by, checked_at, post_no_debit)
      VALUES (p_class, p_product, v_branch, p_currency, 'Test ' || LOWER(p_class) || ' account', 'SOLE',
              v_officer, 'ACTIVE', v_manager, SYSTIMESTAMP, FALSE)
      RETURNING account_id INTO v_id;
    INSERT INTO account_holders (account_id, customer_id, holder_role) VALUES (v_id, p_customer, 'PRIMARY');
    RETURN v_id;
  END;

  -- A posted SYSTEM transaction with its two balanced ledger lines.
  FUNCTION posted_txn(p_type VARCHAR2, p_debit NUMBER, p_credit NUMBER, p_amount NUMBER) RETURN NUMBER IS
    v_id NUMBER;
  BEGIN
    INSERT INTO transactions (txn_type, channel, currency_code, amount, status, posted_at)
      VALUES (p_type, 'SYSTEM', 'XTS', p_amount, 'POSTED', SYSTIMESTAMP) RETURNING txn_id INTO v_id;
    INSERT INTO ledger_entries (txn_id, line_no, account_id, direction, amount, balance_after) VALUES (v_id, 1, p_debit,  'DR', p_amount, 0);
    INSERT INTO ledger_entries (txn_id, line_no, account_id, direction, amount, balance_after) VALUES (v_id, 2, p_credit, 'CR', p_amount, 0);
    RETURN v_id;
  END;

  -- INSERT for a loan application of v_cust (SUBMITTED); extra columns per check.
  FUNCTION application_sql(p_extra_cols VARCHAR2 DEFAULT NULL, p_extra_vals VARCHAR2 DEFAULT NULL) RETURN VARCHAR2 IS
  BEGIN
    RETURN 'INSERT INTO loan_applications (customer_id, product_id, branch_id, requested_amount, requested_term_months, '
        || 'purpose, monthly_income, loan_officer_id'
        || CASE WHEN p_extra_cols IS NOT NULL THEN ', ' || p_extra_cols END || ') VALUES ('
        || v_cust || ', ' || v_loan_prod || ', ' || v_branch || q'[, 5000, 12, 'BUSINESS', 4000, ]' || v_officer
        || CASE WHEN p_extra_vals IS NOT NULL THEN ', ' || p_extra_vals END || ')';
  END;

  -- INSERT for a card of v_cust on v_sav; extra columns per check.
  FUNCTION card_sql(p_type VARCHAR2 DEFAULT 'PHYSICAL', p_extra_cols VARCHAR2 DEFAULT NULL, p_extra_vals VARCHAR2 DEFAULT NULL,
                    p_account NUMBER DEFAULT NULL, p_customer NUMBER DEFAULT NULL) RETURN VARCHAR2 IS
  BEGIN
    RETURN 'INSERT INTO cards (account_id, customer_id, card_scheme, card_type, masked_pan, pan_token, name_on_card, '
        || 'daily_atm_limit, daily_pos_limit, daily_online_limit, requested_by'
        || CASE WHEN p_extra_cols IS NOT NULL THEN ', ' || p_extra_cols END || ') VALUES ('
        || NVL(p_account, v_sav) || ', ' || NVL(p_customer, v_cust) || q'[, 'GHLINK', ']' || p_type
        || q'[', '539923******1234', 'tok-' || SYS_GUID(), 'KOFI BORROWER', 2000, 5000, 1000, ]' || v_officer
        || CASE WHEN p_extra_vals IS NOT NULL THEN ', ' || p_extra_vals END || ')';
  END;

  -- INSERT for an approval request by v_officer; p_target_cols/vals name its target.
  FUNCTION request_sql(p_type VARCHAR2, p_target_cols VARCHAR2, p_target_vals VARCHAR2,
                       p_payload VARCHAR2 DEFAULT 'NULL') RETURN VARCHAR2 IS
  BEGIN
    RETURN 'INSERT INTO approval_requests (request_type, ' || p_target_cols || ', payload, reason, requested_by) VALUES ('''
        || p_type || ''', ' || p_target_vals || ', ' || p_payload || q'[, 'Test request', ]' || v_officer || ')';
  END;
BEGIN
  -- ---------------------------------------------------------------- fixtures
  MERGE INTO countries c USING (SELECT 'ZZA' code FROM dual) s ON (c.country_code = s.code)
    WHEN NOT MATCHED THEN INSERT (country_code, country_name, nationality_name) VALUES ('ZZA', 'Testland', 'Testlander');
  MERGE INTO countries c USING (SELECT 'GHA' code FROM dual) s ON (c.country_code = s.code)
    WHEN NOT MATCHED THEN INSERT (country_code, country_name, nationality_name) VALUES ('GHA', 'Ghana', 'Ghanaian');
  -- Bank of Ghana day bands (provisioning rates here are placeholders for the test).
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
  INSERT INTO currencies (currency_code, currency_name) VALUES ('XXX', 'Test currency XXX');
  INSERT INTO regions (region_name) VALUES ('Test region 6') RETURNING region_id INTO v_region;
  INSERT INTO branches (branch_code, branch_name, region_id, phone, opened_on)
    VALUES ('T-BR6', 'Test branch 6', v_region, '+233200000601', DATE '2020-01-01') RETURNING branch_id INTO v_branch;
  INSERT INTO departments (department_name) VALUES ('Test department 6') RETURNING department_id INTO v_dept;
  INSERT INTO jobs (job_title, department_id, min_salary, max_salary)
    VALUES ('Test officer 6', v_dept, 20000, 90000) RETURNING job_id INTO v_job;
  INSERT INTO employees (first_name, last_name, sex, date_of_birth, nationality, work_email, phone, job_id, branch_id, salary, hire_date, db_username)
    VALUES ('Efua', 'Officer', 'FEMALE', DATE '1991-04-02', 'ZZA', 'efua.officer.t6@example.com', '+233200000610',
            v_job, v_branch, 40000, DATE '2020-02-03', 'T6_OFFICER') RETURNING employee_id INTO v_officer;
  INSERT INTO employees (first_name, last_name, sex, date_of_birth, nationality, work_email, phone, job_id, branch_id, salary, hire_date, db_username)
    VALUES ('Nii', 'Manager', 'MALE', DATE '1980-12-15', 'ZZA', 'nii.manager.t6@example.com', '+233200000611',
            v_job, v_branch, 80000, DATE '2015-06-01', 'T6_MANAGER') RETURNING employee_id INTO v_manager;
  INSERT INTO customers (first_name, last_name, sex, date_of_birth, nationality, home_branch_id, employment_status, income_band,
                         source_of_funds, account_purpose, expected_monthly_volume, data_consent_at,
                         kyc_status, kyc_approved_by, kyc_approved_at, risk_rating)
    VALUES ('Kofi', 'Borrower', 'MALE', DATE '1984-08-08', 'ZZA', v_branch, 'SELF_EMPLOYED', '5K_10K',
            'BUSINESS', 'BUSINESS', 6000, SYSTIMESTAMP, 'VERIFIED', v_manager, SYSTIMESTAMP, 'LOW') RETURNING customer_id INTO v_cust;
  INSERT INTO customers (first_name, last_name, sex, date_of_birth, nationality, home_branch_id, employment_status, income_band,
                         source_of_funds, account_purpose, expected_monthly_volume, data_consent_at,
                         kyc_status, kyc_approved_by, kyc_approved_at, risk_rating)
    VALUES ('Akosua', 'Other', 'FEMALE', DATE '1990-03-03', 'ZZA', v_branch, 'EMPLOYED', '1K_5K',
            'SALARY', 'SALARY', 3000, SYSTIMESTAMP, 'VERIFIED', v_manager, SYSTIMESTAMP, 'LOW') RETURNING customer_id INTO v_cust2;
  INSERT INTO account_products (product_code, product_name, account_type, currency_code)
    VALUES ('T6-SAV', 'Test savings 6', 'SAVINGS', 'XTS') RETURNING product_id INTO v_sav_prod;
  INSERT INTO account_products (product_code, product_name, account_type, currency_code)
    VALUES ('T6-SAVX', 'Test savings 6 XXX', 'SAVINGS', 'XXX') RETURNING product_id INTO v_sav_prod_xxx;
  INSERT INTO loan_products (product_code, product_name, currency_code, interest_rate, min_amount, max_amount, max_term_months)
    VALUES ('T6-SME', 'Test SME loan 6', 'XTS', 18, 1000, 50000, 36) RETURNING product_id INTO v_loan_prod;
  INSERT INTO accounts (account_class, internal_purpose, branch_id, currency_code, account_name, status, post_no_debit)
    VALUES ('INTERNAL', 'VAULT_CASH', v_branch, 'XTS', 'Vault cash XTS', 'ACTIVE', FALSE) RETURNING account_id INTO v_vault;
  v_sav       := new_account('CUSTOMER', v_sav_prod, 'XTS', v_cust);
  v_sav_xxx   := new_account('CUSTOMER', v_sav_prod_xxx, 'XXX', v_cust);
  v_sav2      := new_account('CUSTOMER', v_sav_prod, 'XTS', v_cust2);
  v_loan_acc  := new_account('LOAN', NULL, 'XTS', v_cust);
  v_loan_acc2 := new_account('LOAN', NULL, 'XTS', v_cust2);
  -- Disbursement: the loan account is debited (the customer owes it), the savings account credited.
  v_disb_txn := posted_txn('LOAN_DISBURSEMENT', v_loan_acc, v_sav, 5000);
  v_rep_txn  := posted_txn('LOAN_REPAYMENT', v_sav, v_loan_acc, 500);
  v_fee_txn  := posted_txn('FEE', v_sav, v_vault, 10);
  INSERT INTO transactions (txn_type, channel, currency_code, amount) VALUES ('LOAN_REPAYMENT', 'SYSTEM', 'XTS', 500)
    RETURNING txn_id INTO v_pend_txn;

  -- ------------------------------------------------------------ loan classes
  SELECT COUNT(*) INTO v_count FROM loan_classes;
  check_that('five Bank of Ghana loan classes', v_count = 5);
  rejects('OLEM band starting at 20 days, overlapping CURRENT (assertion)',
    'UPDATE loan_classes SET min_days_past_due = 20 WHERE class_code = ''OLEM''', 'LOAN_CLASSES_BANDS_AS');
  rejects('class code WATCH',
    q'[INSERT INTO loan_classes (class_code, class_name, min_days_past_due, max_days_past_due, provision_pct, is_non_performing) VALUES ('WATCH', 'Watch', 1, 2, 1, FALSE)]',
    'LOAN_CLASSES_CODE_CK');
  rejects('band ending before it starts',
    'UPDATE loan_classes SET min_days_past_due = 400, max_days_past_due = 399 WHERE class_code = ''LOSS''', 'LOAN_CLASSES_DAYS_CK');

  -- ------------------------------------------------------- loan applications
  EXECUTE IMMEDIATE application_sql || ' RETURNING application_id, application_no INTO :1, :2' RETURNING INTO v_app, v_no;
  check_that('application submitted; number generated (' || v_no || ')', REGEXP_LIKE(v_no, '^LAP[0-9]{9}$'));
  rejects('term of 0 months', REPLACE(application_sql, ', 12, ', ', 0, '), 'LOAN_APPLICATIONS_TERM_CK');
  rejects('purpose GAMBLING', REPLACE(application_sql, q'['BUSINESS']', q'['GAMBLING']'), 'LOAN_APPLICATIONS_PURPOSE_CK');
  rejects('SUBMITTED application with a decider',
    application_sql('decided_by, decided_at', v_manager || ', SYSTIMESTAMP'), 'LOAN_APPLICATIONS_DECIDED_CK');
  rejects('APPROVED without the person who decided',
    'UPDATE loan_applications SET status = ''APPROVED'', approved_margin_pct = 6.5, approved_amount = 4000, approved_term_months = 12 WHERE application_id = ' || v_app,
    'LOAN_APPLICATIONS_DECIDED_CK');
  rejects('APPROVED without approved terms',
    'UPDATE loan_applications SET status = ''APPROVED'', approved_margin_pct = 6.5, decided_by = ' || v_manager || ', decided_at = SYSTIMESTAMP WHERE application_id = ' || v_app,
    'LOAN_APPLICATIONS_APPROVED_CK');
  rejects('APPROVED for more than was requested',
    'UPDATE loan_applications SET status = ''APPROVED'', approved_margin_pct = 6.5, decided_by = ' || v_manager || ', decided_at = SYSTIMESTAMP, '
    || 'approved_amount = 6000, approved_term_months = 12 WHERE application_id = ' || v_app,
    'LOAN_APPLICATIONS_APPROVED_CK');
  rejects('loan officer deciding their own application',
    'UPDATE loan_applications SET status = ''APPROVED'', approved_margin_pct = 6.5, decided_by = ' || v_officer || ', decided_at = SYSTIMESTAMP, '
    || 'approved_amount = 5000, approved_term_months = 12 WHERE application_id = ' || v_app,
    'LOAN_APPLICATIONS_CHECKER_CK');
  rejects('REJECTED without a decision note',
    'UPDATE loan_applications SET status = ''REJECTED'', decided_by = ' || v_manager || ', decided_at = SYSTIMESTAMP WHERE application_id = ' || v_app,
    'LOAN_APPLICATIONS_REJECTED_CK');
  accepts('credit manager approves 5000 over 12 months',
    'UPDATE loan_applications SET status = ''APPROVED'', approved_margin_pct = 6.5, decided_by = ' || v_manager || ', decided_at = SYSTIMESTAMP, '
    || 'approved_amount = 5000, approved_term_months = 12 WHERE application_id = ' || v_app);
  SELECT updated_by INTO v_text FROM loan_applications WHERE application_id = v_app;
  check_that('update trigger filled updated_by (' || v_text || ')', v_text IS NOT NULL);

  -- ------------------------------------------------------------------- loans
  -- Priced at the Ghana Reference Rate (10.04 % in October 2026) plus a 6.5 % margin.
  INSERT INTO loans (application_id, loan_account_id, disbursement_account_id, disbursement_txn_id, principal,
                     rate_type, reference_rate, margin_pct, term_months, disbursed_on, first_due_date)
    VALUES (v_app, v_loan_acc, v_sav, v_disb_txn, 5000, 'VARIABLE', 10.04, 6.5, 12, DATE '2026-10-26', DATE '2026-11-26')
    RETURNING loan_id, loan_no INTO v_loan, v_no;
  check_that('loan disbursed; number generated (' || v_no || ')', REGEXP_LIKE(v_no, '^LN[0-9]{10}$'));
  SELECT interest_rate, maturity_date INTO v_rate, v_date FROM loans WHERE loan_id = v_loan;
  check_that('virtual columns: rate 10.04 + 6.5 = ' || v_rate || ', maturity ' || TO_CHAR(v_date, 'YYYY-MM-DD'),
             v_rate = 16.54 AND v_date = DATE '2027-10-26');
  rejects('second loan for the same application',
    'INSERT INTO loans (application_id, loan_account_id, disbursement_account_id, disbursement_txn_id, principal, rate_type, '
    || 'reference_rate, margin_pct, term_months, disbursed_on, first_due_date) VALUES (' || v_app || ', ' || v_loan_acc2 || ', '
    || v_sav2 || ', ' || v_fee_txn || q'[, 100, 'FIXED', 10, 5, 12, DATE '2026-10-26', DATE '2026-11-26')]',
    'LOANS_APPLICATION_UK');
  rejects('first installment due before the disbursement',
    'UPDATE loans SET first_due_date = DATE ''2026-10-01'' WHERE loan_id = ' || v_loan, 'LOANS_FIRST_DUE_CK');
  rejects('rate type FLOATING', 'UPDATE loans SET rate_type = ''FLOATING'' WHERE loan_id = ' || v_loan, 'LOANS_RATE_TYPE_CK');
  rejects('loan paid into its own loan account',
    'UPDATE loans SET disbursement_account_id = loan_account_id WHERE loan_id = ' || v_loan, 'LOANS_ACCOUNTS_DIFFER_CK');
  rejects('45 days past due but still CURRENT (assertion)',
    'UPDATE loans SET days_past_due = 45 WHERE loan_id = ' || v_loan, 'LOANS_CLASSIFICATION_AS');
  accepts('45 days past due, classified OLEM',
    'UPDATE loans SET days_past_due = 45, classification = ''OLEM'' WHERE loan_id = ' || v_loan);
  SAVEPOINT before_downgrade;
  accepts('45 days past due, downgraded to DOUBTFUL by judgement',
    'UPDATE loans SET classification = ''DOUBTFUL'' WHERE loan_id = ' || v_loan);
  ROLLBACK TO before_downgrade;
  rejects('shrinking the OLEM band below a loan''s 45 days (assertion)',
    'UPDATE loan_classes SET max_days_past_due = 40 WHERE class_code = ''OLEM''', 'LOANS_CLASSIFICATION_AS');
  rejects('writing off a loan that is not classified LOSS',
    'UPDATE loans SET status = ''WRITTEN_OFF'', closed_on = DATE ''2027-12-31'' WHERE loan_id = ' || v_loan, 'LOANS_WRITE_OFF_CK');
  SAVEPOINT before_write_off;
  accepts('writing off a loan 400 days past due, classified LOSS',
    'UPDATE loans SET days_past_due = 400, classification = ''LOSS'', status = ''WRITTEN_OFF'', closed_on = DATE ''2027-12-31'' WHERE loan_id = ' || v_loan);
  ROLLBACK TO before_write_off;
  rejects('CLOSED while 45 days past due',
    'UPDATE loans SET status = ''CLOSED'', closed_on = DATE ''2027-10-26'' WHERE loan_id = ' || v_loan, 'LOANS_CLOSED_ARREARS_CK');
  rejects('CLOSED without a closing date',
    'UPDATE loans SET status = ''CLOSED'', days_past_due = 0, classification = ''CURRENT'' WHERE loan_id = ' || v_loan, 'LOANS_CLOSED_CK');
  rejects('money paid into the bank''s vault instead of a customer account (assertion)',
    'UPDATE loans SET disbursement_account_id = ' || v_vault || ' WHERE loan_id = ' || v_loan, 'LOANS_ACCOUNTS_AS');
  rejects('money paid into an account in another currency (assertion)',
    'UPDATE loans SET disbursement_account_id = ' || v_sav_xxx || ' WHERE loan_id = ' || v_loan, 'LOANS_CURRENCY_AS');
  rejects('loan account held by someone other than the applicant (assertion)',
    'UPDATE loans SET loan_account_id = ' || v_loan_acc2 || ' WHERE loan_id = ' || v_loan, 'LOANS_BORROWER_AS');
  rejects('removing the borrower from the loan account (assertion)',
    'DELETE FROM account_holders WHERE account_id = ' || v_loan_acc || ' AND customer_id = ' || v_cust, 'LOANS_BORROWER_AS');
  rejects('disbursed by a FEE transaction (assertion)',
    'UPDATE loans SET disbursement_txn_id = ' || v_fee_txn || ' WHERE loan_id = ' || v_loan, 'LOANS_DISBURSEMENT_TXN_AS');

  -- ----------------------------------------------------------- loan schedule
  INSERT INTO loan_schedule (loan_id, installment_no, due_date, principal_due, interest_due) VALUES (v_loan, 1, DATE '2026-11-26', 400, 68.92);
  INSERT INTO loan_schedule (loan_id, installment_no, due_date, principal_due, interest_due) VALUES (v_loan, 2, DATE '2026-12-26', 405, 63.40);
  SELECT total_due INTO v_rate FROM loan_schedule WHERE loan_id = v_loan AND installment_no = 1;
  check_that('installments created; virtual total_due 400 + 68.92 = ' || v_rate, v_rate = 468.92);
  rejects('installment number 0',
    'INSERT INTO loan_schedule (loan_id, installment_no, due_date, principal_due, interest_due) VALUES (' || v_loan || q'[, 0, DATE '2026-10-30', 1, 1)]',
    'LOAN_SCHEDULE_NO_CK');
  rejects('two installments due the same day',
    'INSERT INTO loan_schedule (loan_id, installment_no, due_date, principal_due, interest_due) VALUES (' || v_loan || q'[, 3, DATE '2026-12-26', 1, 1)]',
    'LOAN_SCHEDULE_DUE_UK');
  rejects('installment of nothing',
    'INSERT INTO loan_schedule (loan_id, installment_no, due_date, principal_due, interest_due) VALUES (' || v_loan || q'[, 3, DATE '2027-01-26', 0, 0)]',
    'LOAN_SCHEDULE_AMOUNT_CK');
  -- Interest is charged when an installment falls due (changelog 0009); only then can it be paid.
  rejects('paying interest that was never charged',
    'UPDATE loan_schedule SET interest_paid = 10, status = ''PARTIAL'' WHERE loan_id = ' || v_loan || ' AND installment_no = 2',
    'LOAN_SCHEDULE_CHARGED_CK');
  v_int_txn := posted_txn('INTEREST', v_loan_acc, v_vault, 68.92);
  UPDATE loan_schedule SET interest_txn_id = v_int_txn WHERE loan_id = v_loan AND installment_no = 1;
  rejects('paying more interest than is due',
    'UPDATE loan_schedule SET interest_paid = 70, status = ''PARTIAL'' WHERE loan_id = ' || v_loan || ' AND installment_no = 1', 'LOAN_SCHEDULE_PAID_CK');
  rejects('PAID while principal is still owed',
    'UPDATE loan_schedule SET interest_paid = 68.92, status = ''PAID'', paid_on = DATE ''2026-11-20'' WHERE loan_id = ' || v_loan || ' AND installment_no = 1',
    'LOAN_SCHEDULE_STATE_CK');
  rejects('DUE although a payment was received',
    'UPDATE loan_schedule SET interest_paid = 10 WHERE loan_id = ' || v_loan || ' AND installment_no = 1', 'LOAN_SCHEDULE_STATE_CK');
  accepts('PARTIAL: interest paid first',
    'UPDATE loan_schedule SET interest_paid = 68.92, status = ''PARTIAL'' WHERE loan_id = ' || v_loan || ' AND installment_no = 1');
  accepts('PAID in full, with the date',
    'UPDATE loan_schedule SET principal_paid = 400, status = ''PAID'', paid_on = DATE ''2026-11-20'' WHERE loan_id = ' || v_loan || ' AND installment_no = 1');

  -- --------------------------------------------------------- loan repayments
  accepts('repayment transaction allocated to installment 1',
    'INSERT INTO loan_repayments (txn_id, loan_id, installment_no, principal_amount, interest_amount) VALUES ('
    || v_rep_txn || ', ' || v_loan || ', 1, 400, 68.92)');
  rejects('allocation of nothing',
    'INSERT INTO loan_repayments (txn_id, loan_id, installment_no, principal_amount, interest_amount) VALUES ('
    || v_rep_txn || ', ' || v_loan || ', 2, 0, 0)', 'LOAN_REPAYMENTS_AMOUNT_CK');
  rejects('allocation to an installment that does not exist',
    'INSERT INTO loan_repayments (txn_id, loan_id, installment_no, principal_amount, interest_amount) VALUES ('
    || v_rep_txn || ', ' || v_loan || ', 9, 1, 0)', 'LOAN_REPAYMENTS_INSTALLMENT_FK');
  rejects('the same transaction allocated twice to one installment',
    'INSERT INTO loan_repayments (txn_id, loan_id, installment_no, principal_amount, interest_amount) VALUES ('
    || v_rep_txn || ', ' || v_loan || ', 1, 1, 0)', 'LOAN_REPAYMENTS_UK');
  rejects('installment paid by a FEE transaction (assertion)',
    'INSERT INTO loan_repayments (txn_id, loan_id, installment_no, principal_amount, interest_amount) VALUES ('
    || v_fee_txn || ', ' || v_loan || ', 2, 10, 0)', 'LOAN_REPAYMENTS_TXN_AS');
  rejects('installment paid by a repayment still PENDING (assertion)',
    'INSERT INTO loan_repayments (txn_id, loan_id, installment_no, principal_amount, interest_amount) VALUES ('
    || v_pend_txn || ', ' || v_loan || ', 2, 100, 0)', 'LOAN_REPAYMENTS_TXN_AS');

  -- ------------------------------------------------------------------- cards
  EXECUTE IMMEDIATE card_sql || ' RETURNING card_id INTO :1' RETURNING INTO v_card;
  SELECT last4 INTO v_text FROM cards WHERE card_id = v_card;
  check_that('card requested; virtual last4 = ' || v_text, v_text = '1234');
  rejects('full card number stored (PCI DSS)', REPLACE(card_sql, '539923******1234', '5399231234561234'), 'CARDS_PAN_CK');
  rejects('card scheme AMEX', REPLACE(card_sql, q'['GHLINK']', q'['AMEX']'), 'CARDS_SCHEME_CK');
  rejects('name on card longer than 26 characters',
    REPLACE(card_sql, q'['KOFI BORROWER']', q'['KOFI KWAME ASANTE-BORROWER JUNIOR']'), 'NAME_ON_CARD');
  rejects('second live physical card for the same holder and account', card_sql, 'CARDS_LIVE_UX');
  accepts('a virtual card next to the physical one', card_sql('VIRTUAL'));
  rejects('REQUESTED card with an expiry date',
    'UPDATE cards SET issued_on = DATE ''2026-10-26'', expires_on = DATE ''2029-10-31'' WHERE card_id = ' || v_card, 'CARDS_ISSUED_CK');
  rejects('ACTIVE card without issue and expiry dates',
    'UPDATE cards SET status = ''ACTIVE'' WHERE card_id = ' || v_card, 'CARDS_ISSUED_CK');
  rejects('expiry date in the middle of a month',
    'UPDATE cards SET status = ''ISSUED'', issued_on = DATE ''2026-10-26'', expires_on = DATE ''2029-10-15'' WHERE card_id = ' || v_card,
    'CARDS_EXPIRY_CK');
  accepts('card issued, expiring at the end of a month',
    'UPDATE cards SET status = ''ISSUED'', issued_on = DATE ''2026-10-26'', expires_on = LAST_DAY(DATE ''2029-10-01'') WHERE card_id = ' || v_card);
  rejects('BLOCKED without a reason', 'UPDATE cards SET status = ''BLOCKED'' WHERE card_id = ' || v_card, 'CARDS_BLOCK_CK');
  accepts('BLOCKED as LOST', 'UPDATE cards SET status = ''BLOCKED'', block_reason = ''LOST'' WHERE card_id = ' || v_card);
  rejects('card for a customer who does not hold the account (assertion)',
    card_sql(p_customer => v_cust2), 'CARDS_HOLDER_AS');
  rejects('card on a loan account (assertion)', card_sql(p_account => v_loan_acc), 'CARDS_ACCOUNT_AS');
  -- Akosua becomes a signatory on Kofi's account and gets her own card.
  INSERT INTO account_holders (account_id, customer_id, holder_role) VALUES (v_sav, v_cust2, 'SIGNATORY');
  EXECUTE IMMEDIATE card_sql(p_customer => v_cust2) || ' RETURNING card_id INTO :1' RETURNING INTO v_card2;
  rejects('removing a holder who still has a live card (assertion)',
    'DELETE FROM account_holders WHERE account_id = ' || v_sav || ' AND customer_id = ' || v_cust2, 'CARDS_HOLDER_AS');
  UPDATE cards SET status = 'CANCELLED' WHERE card_id = v_card2;
  accepts('removing the holder once the card is cancelled',
    'DELETE FROM account_holders WHERE account_id = ' || v_sav || ' AND customer_id = ' || v_cust2);

  -- ------------------------------------------------------- approval requests
  EXECUTE IMMEDIATE request_sql('OVERDRAFT_CHANGE', 'account_id', TO_CHAR(v_sav), q'[JSON('{"overdraft_limit": 500}')]')
    || ' RETURNING request_id INTO :1' RETURNING INTO v_req;
  SELECT JSON_VALUE(payload, '$.overdraft_limit' RETURNING NUMBER) INTO v_rate FROM approval_requests WHERE request_id = v_req;
  check_that('overdraft change requested; JSON payload read back (' || v_rate || ')', v_rate = 500);
  rejects('request pointing at two things',
    request_sql('OVERDRAFT_CHANGE', 'account_id, customer_id', v_sav2 || ', ' || v_cust), 'APPROVAL_REQUESTS_ONE_TARGET_CK');
  -- No target breaks both target rules; Oracle reports one of them.
  rejects('request pointing at nothing',
    'INSERT INTO approval_requests (request_type, reason, requested_by) VALUES (''KYC_APPROVAL'', ''x'', ' || v_officer || ')',
    'APPROVAL_REQUESTS_(ONE_)?TARGET_CK');
  rejects('KYC approval pointing at an account',
    request_sql('KYC_APPROVAL', 'account_id', TO_CHAR(v_sav2)), 'APPROVAL_REQUESTS_TARGET_CK');
  rejects('payload that is a JSON array, not an object (JSON Schema)',
    request_sql('ACCOUNT_UNFREEZE', 'account_id', TO_CHAR(v_sav2), q'{'[500]'}'), 'APPROVAL_REQUESTS_PAYLOAD_CK|ORA-40875');
  rejects('payload that is not JSON at all',
    request_sql('ACCOUNT_UNFREEZE', 'account_id', TO_CHAR(v_sav2), q'['overdraft please']'), 'ORA-40441');
  rejects('second PENDING overdraft request for the same account',
    request_sql('OVERDRAFT_CHANGE', 'account_id', TO_CHAR(v_sav)), 'APPROVAL_REQUESTS_PENDING_UX');
  rejects('maker deciding their own request',
    'UPDATE approval_requests SET status = ''APPROVED'', decided_by = ' || v_officer || ', decided_at = SYSTIMESTAMP WHERE request_id = ' || v_req,
    'APPROVAL_REQUESTS_CHECKER_CK');
  rejects('APPROVED without the person who decided',
    'UPDATE approval_requests SET status = ''APPROVED'' WHERE request_id = ' || v_req, 'APPROVAL_REQUESTS_DECIDED_CK');
  rejects('REJECTED without a decision note',
    'UPDATE approval_requests SET status = ''REJECTED'', decided_by = ' || v_manager || ', decided_at = SYSTIMESTAMP WHERE request_id = ' || v_req,
    'APPROVAL_REQUESTS_REJECTED_CK');
  accepts('supervisor approves the request',
    'UPDATE approval_requests SET status = ''APPROVED'', decided_by = ' || v_manager || ', decided_at = SYSTIMESTAMP WHERE request_id = ' || v_req);
  accepts('a new overdraft request once the first is decided',
    request_sql('OVERDRAFT_CHANGE', 'account_id', TO_CHAR(v_sav), q'['{"overdraft_limit": 800}']'));

  -- ------------------------------------------------------------- audit trail
  INSERT INTO audit_trail (event_type, entity_table, entity_id, employee_id, old_values, new_values)
    VALUES ('APPROVAL_DECIDED', 'APPROVAL_REQUESTS', TO_CHAR(v_req), v_manager,
            JSON('{"status": "PENDING"}'), JSON('{"status": "APPROVED"}'));
  SELECT COUNT(*) INTO v_count FROM audit_trail
   WHERE entity_table = 'APPROVAL_REQUESTS' AND entity_id = TO_CHAR(v_req)
     AND db_user IS NOT NULL AND JSON_VALUE(new_values, '$.status') = 'APPROVED';
  check_that('audit event recorded with the database user and JSON values', v_count = 1);
  rejects('event type in lower case',
    q'[INSERT INTO audit_trail (event_type, entity_table, entity_id) VALUES ('approval_decided', 'X', '1')]', 'AUDIT_TRAIL_EVENT_CK');
  rejects('changing an audit row (immutable table)',
    'UPDATE audit_trail SET event_type = ''NOTHING_HAPPENED'' WHERE entity_id = ''' || v_req || '''', 'ORA-05715');
  rejects('deleting an audit row (immutable table)',
    'DELETE FROM audit_trail WHERE entity_id = ''' || v_req || '''', 'ORA-05715');
  SELECT COUNT(*) INTO v_count FROM dba_immutable_tables
   WHERE schema_name = 'WELBANK' AND table_name = 'AUDIT_TRAIL' AND row_retention = 1827;
  check_that('audit_trail is immutable, rows kept 1827 days (five years)', v_count = 1);

  -- ------------------------------------------------------- dictionary checks
  accepts('every fixture satisfies the COMMIT-time rules (checked now)', 'SET CONSTRAINTS ALL IMMEDIATE');
  defer_again;
  SELECT COUNT(*) INTO v_count FROM dba_assertions
   WHERE owner = 'WELBANK' AND status = 'ENABLED' AND validated = 'VALIDATED'
     AND assertion_name IN ('LOAN_CLASSES_BANDS_AS', 'LOANS_CLASSIFICATION_AS', 'LOANS_ACCOUNTS_AS', 'LOANS_CURRENCY_AS',
                            'LOANS_BORROWER_AS', 'LOANS_DISBURSEMENT_TXN_AS', 'LOAN_REPAYMENTS_TXN_AS',
                            'CARDS_HOLDER_AS', 'CARDS_ACCOUNT_AS');
  check_that('the 9 assertions of changelog 0006 enabled and validated (found ' || v_count || ')', v_count = 9);

  DBMS_OUTPUT.PUT_LINE('RESULT: ' || passed || ' passed, ' || failed || ' failed');
  ROLLBACK;
END;
/
