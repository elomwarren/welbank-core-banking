-- =============================================================================
-- simulate_month.sql — one month of banking activity, called by build/seed.sql:
--     @simulate_month.sql <month number> <first day> <last day>
--
-- Everything goes through the packages, played by the right employees (the
-- session user is mapped to one employee at a time, as in the tests):
--   * deferred KYC files fixed by customers who came back;
--   * cash deposits, withdrawals and transfers (amounts above a teller's limit
--     go to the teller supervisor; a few are rejected, a few reversed);
--   * loan applications, decisions, disbursements and repayments (most on
--     time, some late, a few defaulting);
--   * the loans' end-of-day run on the last day of the month.
-- Then everything created "now" is back-dated into the simulated month.
-- DBMS_RANDOM is seeded with the month number: the same run gives the same data.
-- A business refusal (an ORA-20xxx from the packages, e.g. insufficient
-- funds) is counted and skipped, as a real teller would; anything else stops the seed.
-- =============================================================================
DECLARE
  c_month   CONSTANT PLS_INTEGER := &1;
  c_start   CONSTANT DATE := DATE '&2';
  c_end     CONSTANT DATE := DATE '&3';
  c_load    CONSTANT TIMESTAMP := TO_TIMESTAMP('&load_start', 'YYYY-MM-DD HH24:MI:SS');
  -- Never date anything today or later: the history ends yesterday.
  c_last    CONSTANT DATE := LEAST(c_end, TRUNC(CAST(c_load AS DATE)) - 1);
  c_span    CONSTANT NUMBER := GREATEST(c_last - c_start, 0);
  v_posted  PLS_INTEGER := 0;
  v_refused PLS_INTEGER := 0;
  v_loans   PLS_INTEGER := 0;
  v_repaid  PLS_INTEGER := 0;
  v_fixed   PLS_INTEGER := 0;
  v_ref     VARCHAR2(20);
  v_app     VARCHAR2(12);
  v_loan    VARCHAR2(12);
  v_to      VARCHAR2(13);
  v_amount  NUMBER;
  v_avail   NUMBER;
  v_due     NUMBER;
  v_day     DATE;
  v_teller  NUMBER;
  v_term    NUMBER;
  v_product VARCHAR2(20);
  v_n       NUMBER;
  v_count   PLS_INTEGER;
  v_behaviour PLS_INTEGER;

  PROCEDURE act_as(p_employee_id NUMBER) IS
  BEGIN
    UPDATE employees SET db_username = NULL WHERE db_username = SYS_CONTEXT('USERENV', 'SESSION_USER');
    UPDATE employees SET db_username = SYS_CONTEXT('USERENV', 'SESSION_USER') WHERE employee_id = p_employee_id;
  END;

  -- A random active employee with this job (at this branch, unless NULL).
  FUNCTION staff(p_job VARCHAR2, p_branch NUMBER DEFAULT NULL) RETURN NUMBER IS
    v NUMBER;
  BEGIN
    SELECT employee_id INTO v FROM (
      SELECT e.employee_id FROM employees e JOIN jobs j ON j.job_id = e.job_id
       WHERE j.job_title = p_job AND (p_branch IS NULL OR e.branch_id = p_branch) AND e.status = 'ACTIVE'
       ORDER BY DBMS_RANDOM.VALUE)
     WHERE ROWNUM = 1;
    RETURN v;
  END;

  FUNCTION business(p_code NUMBER) RETURN BOOLEAN IS
  BEGIN
    RETURN p_code BETWEEN -20999 AND -20000;
  END;

  -- A pending transaction (above the teller's limit) goes to the supervisor.
  PROCEDURE settle(p_ref VARCHAR2, p_branch NUMBER) IS
  BEGIN
    IF pkg_posting.transaction_status(p_ref) = 'PENDING' THEN
      act_as(staff('Teller supervisor', p_branch));
      IF DBMS_RANDOM.VALUE < 0.03 THEN
        pkg_posting.reject_transaction(p_ref, 'Signature does not match the specimen');
      ELSE
        BEGIN
          pkg_posting.approve_transaction(p_ref);
        EXCEPTION WHEN OTHERS THEN
          IF NOT business(SQLCODE) THEN RAISE; END IF;
          pkg_posting.reject_transaction(p_ref, SUBSTR('Refused at approval: ' || SQLERRM, 1, 200));
        END;
      END IF;
    END IF;
  END;

  -- Puts one transaction on a given day (its lines follow at the end of the month).
  PROCEDURE date_txn(p_ref VARCHAR2, p_day DATE) IS
  BEGIN
    UPDATE transactions
       SET value_date = p_day,
           created_at = CAST(p_day + 10/24 AS TIMESTAMP),
           posted_at  = CASE WHEN posted_at IS NOT NULL THEN CAST(p_day + 10/24 + 1/1440 AS TIMESTAMP) END,
           checked_at = CASE WHEN checked_at IS NOT NULL THEN CAST(p_day + 10/24 AS TIMESTAMP) END
     WHERE txn_ref = p_ref;
  END;
BEGIN
  DBMS_RANDOM.SEED(20261112 + c_month);

  -- ------------------------------------------------- deferred KYC fixed (2 in 3)
  FOR c IN (SELECT customer_no, home_branch_id FROM customers
             WHERE kyc_status = 'DEFERRED' AND created_at < c_load AND MOD(ORA_HASH(customer_id), 3) <> 0
             ORDER BY customer_id) LOOP
    BEGIN
      act_as(staff('Customer service representative', c.home_branch_id));
      v_n := pkg_customer.record_verification(c.customer_no, 'ONBOARDING', 'FACE', 'MATCH',
                                              'NIA-SIM-' || TO_CHAR(c_month, 'FM00') || c.customer_no);
      pkg_customer.submit_kyc(c.customer_no);
      act_as(staff('Branch manager', c.home_branch_id));
      pkg_customer.approve_kyc(c.customer_no, 'MEDIUM');
      v_day := c_start + TRUNC(DBMS_RANDOM.VALUE(0, c_span + 1));
      UPDATE customers
         SET kyc_approved_at = CAST(v_day + 11/24 AS TIMESTAMP),
             next_kyc_review_on = ADD_MONTHS(v_day, (SELECT num_value FROM bank_parameters WHERE param_name = 'KYC_REVIEW_MONTHS_MEDIUM'))
       WHERE customer_no = c.customer_no;
      UPDATE identity_verifications SET performed_at = CAST(v_day + 10/24 AS TIMESTAMP)
       WHERE verification_id = v_n;
      v_fixed := v_fixed + 1;
    EXCEPTION WHEN OTHERS THEN
      IF NOT business(SQLCODE) THEN RAISE; END IF;
      v_refused := v_refused + 1;
    END;
  END LOOP;

  -- ------------------------------------------------------ counter transactions
  FOR a IN (SELECT a.account_id, a.account_no, a.branch_id, a.currency_code, p.account_type, a.post_no_debit,
                   c.expected_monthly_volume / CASE a.currency_code WHEN 'USD' THEN 12 ELSE 1 END AS volume
              FROM accounts a
              JOIN account_products p ON p.product_id = a.product_id
              JOIN account_holders h  ON h.account_id = a.account_id AND h.holder_role = 'PRIMARY'
              JOIN customers c        ON c.customer_id = h.customer_id
             WHERE a.account_class = 'CUSTOMER' AND a.status = 'ACTIVE'
             ORDER BY a.account_id) LOOP
    BEGIN
      v_teller := staff('Bank teller', a.branch_id);
      IF a.account_type = 'FIXED_DEPOSIT' THEN
        SELECT COUNT(*) INTO v_count FROM ledger_entries WHERE account_id = a.account_id;
        IF v_count = 0 THEN                                       -- a fixed deposit is paid in once
          act_as(v_teller);
          v_ref := pkg_posting.cash_deposit(a.account_no, ROUND(GREATEST(1000, a.volume * DBMS_RANDOM.VALUE(1, 4)), -2), 'Fixed deposit');
          settle(v_ref, a.branch_id);
          v_posted := v_posted + 1;
        END IF;
      ELSIF DBMS_RANDOM.VALUE < 0.45 THEN
        act_as(v_teller);                                         -- money in: salary, sales, remittance
        v_ref := pkg_posting.cash_deposit(a.account_no, ROUND(a.volume * DBMS_RANDOM.VALUE(0.4, 1.0), 2));
        settle(v_ref, a.branch_id);
        v_posted := v_posted + 1;
        IF NOT a.post_no_debit THEN
          FOR k IN 1 .. TRUNC(DBMS_RANDOM.VALUE(1, 3)) LOOP      -- money out
            SELECT available_balance INTO v_avail FROM accounts WHERE account_id = a.account_id;
            v_amount := ROUND(v_avail * DBMS_RANDOM.VALUE(0.15, 0.45), -1);
            IF v_amount >= 10 THEN
              BEGIN
                act_as(v_teller);
                v_ref := pkg_posting.cash_withdrawal(a.account_no, v_amount);
                settle(v_ref, a.branch_id);
                v_posted := v_posted + 1;
              EXCEPTION WHEN OTHERS THEN
                IF NOT business(SQLCODE) THEN RAISE; END IF;
                v_refused := v_refused + 1;
              END;
            END IF;
          END LOOP;
          IF DBMS_RANDOM.VALUE < 0.12 THEN                        -- a transfer to someone else
            SELECT account_no INTO v_to FROM (
              SELECT account_no FROM accounts
               WHERE account_class = 'CUSTOMER' AND status = 'ACTIVE' AND currency_code = a.currency_code
                 AND account_id <> a.account_id
               ORDER BY DBMS_RANDOM.VALUE)
             WHERE ROWNUM = 1;
            SELECT available_balance INTO v_avail FROM accounts WHERE account_id = a.account_id;
            v_amount := ROUND(v_avail * DBMS_RANDOM.VALUE(0.05, 0.25), -1);
            IF v_amount >= 10 THEN
              act_as(v_teller);
              v_ref := pkg_posting.transfer(a.account_no, v_to, v_amount);
              settle(v_ref, a.branch_id);
              v_posted := v_posted + 1;
              IF DBMS_RANDOM.VALUE < 0.04 AND pkg_posting.transaction_status(v_ref) = 'POSTED' THEN
                act_as(v_teller);                                 -- "wrong account!": reversed by the supervisor
                v_n := pkg_posting.request_reversal(v_ref, 'Customer gave the wrong account number');
                act_as(staff('Teller supervisor', a.branch_id));
                v_ref := pkg_posting.approve_reversal(v_n);
              END IF;
            END IF;
          END IF;
        END IF;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      IF NOT business(SQLCODE) THEN RAISE; END IF;
      v_refused := v_refused + 1;
    END;
  END LOOP;

  -- -------------------------------------------------------------- repayments
  FOR i IN (SELECT l.loan_id, l.loan_no, MIN(s.due_date) AS due, a.account_no, a.branch_id,
                   MOD(ORA_HASH(l.loan_id), 100) AS behaviour      -- ORA_HASH is SQL-only
              FROM loans l
              JOIN loan_schedule s ON s.loan_id = l.loan_id
              JOIN accounts a      ON a.account_id = l.disbursement_account_id
             WHERE l.status = 'ACTIVE' AND s.status <> 'PAID' AND s.due_date <= c_last
             GROUP BY l.loan_id, l.loan_no, a.account_no, a.branch_id
             ORDER BY l.loan_id) LOOP
    BEGIN
      v_behaviour := i.behaviour;                                -- 85 % on time, 10 % late, 5 % stop paying
      SELECT COUNT(*) INTO v_count FROM loan_schedule WHERE loan_id = i.loan_id AND status = 'PAID';
      IF NOT (v_behaviour >= 95 AND v_count >= 2) THEN
        v_day := CASE WHEN v_behaviour >= 85 THEN LEAST(i.due + 20, c_last) ELSE GREATEST(i.due, c_start) END;
        v_due := pkg_loan.amount_due(i.loan_no, v_day);
        IF v_due > 0 THEN
          v_teller := staff('Bank teller', i.branch_id);
          SELECT available_balance INTO v_avail FROM accounts WHERE account_no = i.account_no;
          IF v_avail < v_due THEN                                 -- the salary comes in first
            act_as(v_teller);
            v_ref := pkg_posting.cash_deposit(i.account_no, ROUND(v_due - v_avail + DBMS_RANDOM.VALUE(50, 500), 2), 'Salary');
            settle(v_ref, i.branch_id);
            date_txn(v_ref, v_day);
          END IF;
          act_as(v_teller);
          v_ref := pkg_loan.repay(i.loan_no, i.account_no, v_due, v_day);
          date_txn(v_ref, v_day);
          v_repaid := v_repaid + 1;
        END IF;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      IF NOT business(SQLCODE) THEN RAISE; END IF;
      v_refused := v_refused + 1;
    END;
  END LOOP;

  -- -------------------------------------------------------------- new loans
  FOR c IN (SELECT * FROM (
              SELECT c.customer_no, c.employment_status, c.expected_monthly_volume AS volume, a.account_no, a.branch_id
                FROM customers c
                JOIN account_holders h ON h.customer_id = c.customer_id AND h.holder_role = 'PRIMARY'
                JOIN accounts a        ON a.account_id = h.account_id
               WHERE c.kyc_status = 'VERIFIED' AND c.employment_status IN ('EMPLOYED', 'SELF_EMPLOYED')
                 AND c.created_at < c_load
                 AND a.account_class = 'CUSTOMER' AND a.status = 'ACTIVE' AND NOT a.post_no_debit AND a.currency_code = 'GHS'
                 AND NOT EXISTS (SELECT 1 FROM loan_applications la WHERE la.customer_id = c.customer_id
                                    AND la.status IN ('SUBMITTED', 'UNDER_REVIEW', 'APPROVED'))
               ORDER BY DBMS_RANDOM.VALUE)
             WHERE ROWNUM <= 13) LOOP
    BEGIN
      v_product := CASE WHEN c.employment_status = 'SELF_EMPLOYED' AND DBMS_RANDOM.VALUE < 0.5 THEN 'GHS-SME' ELSE 'GHS-PL' END;
      v_amount  := ROUND(c.volume * DBMS_RANDOM.VALUE(1, 8), -2);
      v_amount  := CASE v_product WHEN 'GHS-SME' THEN LEAST(GREATEST(v_amount, 5000), 500000) ELSE LEAST(GREATEST(v_amount, 1000), 100000) END;
      v_term    := 6 * TRUNC(DBMS_RANDOM.VALUE(1, 7));
      v_day     := c_start + TRUNC(DBMS_RANDOM.VALUE(0, LEAST(25, c_span) + 1));
      act_as(staff('Loan officer', c.branch_id));
      v_app := pkg_loan.submit_application(c.customer_no, v_product, v_amount, v_term,
                                           CASE v_product WHEN 'GHS-SME' THEN 'BUSINESS' ELSE 'PERSONAL' END, c.volume);
      act_as(staff(CASE WHEN v_amount <= 50000 THEN 'Credit analyst' ELSE 'Risk manager' END));
      IF DBMS_RANDOM.VALUE < 0.12 THEN
        pkg_loan.reject_application(v_app, 'Weak repayment record at the credit bureau');
      ELSE
        BEGIN
          pkg_loan.approve_application(v_app, v_amount, v_term, 6 + ROUND(DBMS_RANDOM.VALUE(0, 10) * 2) / 2);
        EXCEPTION WHEN OTHERS THEN
          IF NOT business(SQLCODE) THEN RAISE; END IF;
          pkg_loan.reject_application(v_app, 'Not affordable at the risk-based price');
          v_app := NULL;
        END;
        IF v_app IS NOT NULL THEN
          act_as(staff('Loan officer', c.branch_id));
          v_loan := pkg_loan.disburse(v_app, c.account_no);
          -- Back to the simulated day: the loan, its schedule, its account and its money.
          UPDATE loans SET disbursed_on = v_day, first_due_date = ADD_MONTHS(v_day, 1), created_at = CAST(v_day + 11/24 AS TIMESTAMP)
           WHERE loan_no = v_loan;
          UPDATE loan_schedule s SET due_date = ADD_MONTHS(v_day, s.installment_no)
           WHERE loan_id = (SELECT loan_id FROM loans WHERE loan_no = v_loan);
          UPDATE accounts SET opened_on = v_day, created_at = CAST(v_day + 11/24 AS TIMESTAMP), checked_at = CAST(v_day - 1 + 15/24 AS TIMESTAMP)
           WHERE account_id = (SELECT loan_account_id FROM loans WHERE loan_no = v_loan);
          SELECT t.txn_ref INTO v_ref FROM loans l JOIN transactions t ON t.txn_id = l.disbursement_txn_id WHERE l.loan_no = v_loan;
          date_txn(v_ref, v_day);
          v_loans := v_loans + 1;
        END IF;
      END IF;
      UPDATE loan_applications
         SET submitted_at = CAST(v_day - 4 + 9/24 AS TIMESTAMP), created_at = CAST(v_day - 4 + 9/24 AS TIMESTAMP),
             decided_at = CASE WHEN decided_at IS NOT NULL THEN CAST(v_day - 1 + 15/24 AS TIMESTAMP) END
       WHERE application_no = v_app;
    EXCEPTION WHEN OTHERS THEN
      IF NOT business(SQLCODE) THEN RAISE; END IF;
      v_refused := v_refused + 1;
    END;
  END LOOP;

  -- ------------------------------------------------------ the loans' end of day
  pkg_loan.run_end_of_day(c_last);

  -- -------------------------------- back-date everything created "now" (load time)
  MERGE INTO customers t
  USING (SELECT customer_id, c_start + 9/24 + (ROW_NUMBER() OVER (ORDER BY customer_id) - 0.5) / COUNT(*) OVER () * c_span AS d
           FROM customers WHERE created_at >= c_load) s
  ON (t.customer_id = s.customer_id)
  WHEN MATCHED THEN UPDATE SET
    t.created_at         = CAST(s.d AS TIMESTAMP),
    t.data_consent_at    = CAST(s.d AS TIMESTAMP),
    t.nia_last_synced_at = CASE WHEN t.nia_last_synced_at IS NOT NULL THEN CAST(s.d + 1/48 AS TIMESTAMP) END,
    t.kyc_approved_at    = CASE WHEN t.kyc_approved_at IS NOT NULL THEN CAST(s.d + 1 AS TIMESTAMP) END,
    t.kyc_deferral_until = CASE WHEN t.kyc_deferral_until IS NOT NULL THEN TRUNC(s.d) + 90 END,
    t.next_kyc_review_on = CASE WHEN t.next_kyc_review_on IS NOT NULL THEN
                             ADD_MONTHS(TRUNC(s.d) + 1, (SELECT p.num_value FROM bank_parameters p
                                                          WHERE p.param_name = 'KYC_REVIEW_MONTHS_' || t.risk_rating)) END;
  UPDATE identity_documents x SET created_at = (SELECT c.created_at FROM customers c WHERE c.customer_id = x.customer_id) WHERE created_at >= c_load;
  UPDATE customer_addresses x SET created_at = (SELECT c.created_at FROM customers c WHERE c.customer_id = x.customer_id) WHERE created_at >= c_load;
  UPDATE customer_contacts x SET created_at = (SELECT c.created_at FROM customers c WHERE c.customer_id = x.customer_id) WHERE created_at >= c_load;
  UPDATE next_of_kin x SET created_at = (SELECT c.created_at FROM customers c WHERE c.customer_id = x.customer_id) WHERE created_at >= c_load;
  UPDATE customer_files x SET captured_at = (SELECT c.created_at + INTERVAL '20' MINUTE FROM customers c WHERE c.customer_id = x.customer_id) WHERE captured_at >= c_load;
  UPDATE identity_verifications x SET performed_at = (SELECT c.created_at + INTERVAL '30' MINUTE FROM customers c WHERE c.customer_id = x.customer_id)
   WHERE performed_at >= c_load;
  -- Customer accounts opened this month: a day after their holder's onboarding,
  -- or spread over the month for existing customers.
  MERGE INTO accounts t
  USING (SELECT a.account_id,
                CASE WHEN MIN(c.created_at) >= CAST(c_start AS TIMESTAMP) THEN CAST(MIN(c.created_at) AS DATE) + 2/24
                     ELSE c_start + 10/24 + DBMS_RANDOM.VALUE(0, c_span) END AS d
           FROM accounts a
           JOIN account_holders h ON h.account_id = a.account_id AND h.holder_role = 'PRIMARY'
           JOIN customers c ON c.customer_id = h.customer_id
          WHERE a.created_at >= c_load AND a.account_class = 'CUSTOMER'
          GROUP BY a.account_id) s
  ON (t.account_id = s.account_id)
  WHEN MATCHED THEN UPDATE SET
    t.created_at = CAST(s.d AS TIMESTAMP),
    t.opened_on  = TRUNC(s.d),
    t.checked_at = CASE WHEN t.checked_at IS NOT NULL THEN CAST(s.d + 1/12 AS TIMESTAMP) END;
  UPDATE account_holders x SET created_at = (SELECT a.created_at FROM accounts a WHERE a.account_id = x.account_id) WHERE created_at >= c_load;
  -- Transactions of the month, spread over it in posting order (batch interest
  -- at 22:00 on its value date).
  MERGE INTO transactions t
  USING (SELECT txn_id, channel, value_date,
                c_start + 8/24 + (ROW_NUMBER() OVER (ORDER BY txn_id) - 0.5) / COUNT(*) OVER () * (c_span + 0.4) AS d
           FROM transactions WHERE created_at >= c_load) s
  ON (t.txn_id = s.txn_id)
  WHEN MATCHED THEN UPDATE SET
    t.created_at = CAST(CASE WHEN s.channel = 'SYSTEM' THEN s.value_date + 22/24 ELSE s.d END AS TIMESTAMP),
    t.posted_at  = CASE WHEN t.posted_at IS NOT NULL THEN
                     CAST(CASE WHEN s.channel = 'SYSTEM' THEN s.value_date + 22/24 ELSE s.d + 2/1440 END AS TIMESTAMP) END,
    t.checked_at = CASE WHEN t.checked_at IS NOT NULL THEN CAST(s.d + 1/1440 AS TIMESTAMP) END,
    t.value_date = CASE WHEN s.channel = 'SYSTEM' THEN s.value_date ELSE TRUNC(s.d) END;
  UPDATE ledger_entries e SET created_at = (SELECT NVL(t.posted_at, t.created_at) FROM transactions t WHERE t.txn_id = e.txn_id)
   WHERE created_at >= c_load;
  UPDATE loan_repayments r SET created_at = (SELECT t.created_at FROM transactions t WHERE t.txn_id = r.txn_id) WHERE created_at >= c_load;
  -- Approval requests: when their transaction, account, customer or application was.
  UPDATE approval_requests r
     SET requested_at = COALESCE((SELECT t.created_at FROM transactions t WHERE t.txn_id = r.txn_id),
                                 (SELECT a.created_at FROM accounts a WHERE a.account_id = r.account_id),
                                 (SELECT c.created_at FROM customers c WHERE c.customer_id = r.customer_id),
                                 (SELECT la.submitted_at FROM loan_applications la WHERE la.application_id = r.application_id),
                                 CAST(c_start AS TIMESTAMP))
   WHERE requested_at >= c_load;
  UPDATE approval_requests SET decided_at = requested_at + INTERVAL '2' HOUR WHERE decided_at >= c_load;

  DBMS_OUTPUT.PUT_LINE('[seed]   ' || TO_CHAR(c_start, 'YYYY-MM') || ': ' || v_posted || ' counter transactions, '
                       || v_loans || ' loans disbursed, ' || v_repaid || ' repayments, ' || v_fixed
                       || ' deferred KYC fixed, ' || v_refused || ' refused by the business rules');
END;
/
COMMIT;
