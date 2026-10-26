--liquibase formatted sql

--changeset elomwarren:code-pkg-loan-body runOnChange:true endDelimiter:/
CREATE OR REPLACE PACKAGE BODY pkg_loan AS

  -- ------------------------------------------------------------------ helpers

  FUNCTION fmt (p_amount IN NUMBER) RETURN VARCHAR2 IS
  BEGIN
    RETURN TO_CHAR(p_amount, 'FM999999999990.00');
  END fmt;

  FUNCTION lock_application (p_application_no IN VARCHAR2) RETURN loan_applications%ROWTYPE IS
    a loan_applications%ROWTYPE;
  BEGIN
    SELECT * INTO a FROM loan_applications WHERE application_no = p_application_no FOR UPDATE;
    RETURN a;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      RAISE_APPLICATION_ERROR(pkg_errors.c_loan_not_found, 'Loan application ' || p_application_no || ' does not exist');
  END lock_application;

  FUNCTION lock_loan (p_loan_no IN VARCHAR2) RETURN loans%ROWTYPE IS
    l loans%ROWTYPE;
  BEGIN
    SELECT * INTO l FROM loans WHERE loan_no = p_loan_no FOR UPDATE;
    RETURN l;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      RAISE_APPLICATION_ERROR(pkg_errors.c_loan_not_found, 'Loan ' || p_loan_no || ' does not exist');
  END lock_loan;

  FUNCTION product_of (p_product_id IN NUMBER) RETURN loan_products%ROWTYPE IS
    p loan_products%ROWTYPE;
  BEGIN
    SELECT * INTO p FROM loan_products WHERE product_id = p_product_id;
    RETURN p;
  END product_of;

  -- A customer account the borrower holds, in the loan's currency.
  FUNCTION borrower_account (p_account_no IN VARCHAR2, p_customer_id IN NUMBER, p_currency IN VARCHAR2) RETURN accounts%ROWTYPE IS
    a       accounts%ROWTYPE;
    v_count PLS_INTEGER;
  BEGIN
    BEGIN
      SELECT * INTO a FROM accounts WHERE account_no = p_account_no AND account_class = 'CUSTOMER';
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        RAISE_APPLICATION_ERROR(pkg_errors.c_account_not_found, 'Customer account ' || p_account_no || ' does not exist');
    END;
    IF a.currency_code <> p_currency THEN
      RAISE_APPLICATION_ERROR(pkg_errors.c_currency_mismatch,
        'Account ' || p_account_no || ' is in ' || a.currency_code || '; the loan is in ' || p_currency);
    END IF;
    SELECT COUNT(*) INTO v_count FROM account_holders WHERE account_id = a.account_id AND customer_id = p_customer_id;
    IF v_count = 0 THEN
      RAISE_APPLICATION_ERROR(pkg_errors.c_invalid_state, 'Account ' || p_account_no || ' is not held by the borrower');
    END IF;
    RETURN a;
  END borrower_account;

  -- The debt-service check: all monthly loan repayments within the limit
  -- (DEBT_SERVICE_RATIO_MAX % of income).
  PROCEDURE check_affordable (
    p_amount      IN NUMBER,
    p_annual_rate IN NUMBER,
    p_term_months IN NUMBER,
    p_income      IN NUMBER,
    p_obligations IN NUMBER)
  IS
    v_installment NUMBER := monthly_installment(p_amount, p_annual_rate, p_term_months);
    v_max_pct     NUMBER := pkg_params.num('DEBT_SERVICE_RATIO_MAX');
  BEGIN
    IF NVL(p_income, 0) <= 0 OR v_installment + NVL(p_obligations, 0) > p_income * v_max_pct / 100 THEN
      RAISE_APPLICATION_ERROR(pkg_errors.c_not_affordable,
        'Not affordable: repayments would be ' || fmt(v_installment + NVL(p_obligations, 0)) || ' a month ('
        || fmt(v_installment) || ' for this loan at ' || p_annual_rate || ' %), above ' || v_max_pct
        || ' % of the monthly income of ' || fmt(NVL(p_income, 0)));
    END IF;
  END check_affordable;

  -- Interest of the installments due by p_as_of that has not been charged yet:
  -- debit the loan account (the borrower owes it), credit interest income.
  PROCEDURE charge_due_interest (p_loan_id IN NUMBER, p_as_of IN DATE) IS
    l         loans%ROWTYPE;
    la        accounts%ROWTYPE;
    v_income  accounts.account_id%TYPE;
    v_lines   pkg_ledger.t_lines;
    v_txn_id  transactions.txn_id%TYPE;
    v_txn_ref transactions.txn_ref%TYPE;
  BEGIN
    SELECT * INTO l FROM loans WHERE loan_id = p_loan_id;
    SELECT * INTO la FROM accounts WHERE account_id = l.loan_account_id;
    FOR s IN (SELECT installment_no, due_date, interest_due
                FROM loan_schedule
               WHERE loan_id = p_loan_id AND due_date <= p_as_of AND interest_txn_id IS NULL AND interest_due > 0
               ORDER BY installment_no) LOOP
      v_income := pkg_ledger.internal_account_id(la.branch_id, 'INTEREST_INCOME', la.currency_code);
      pkg_ledger.new_transaction('INTEREST', la.currency_code, s.interest_due,
        'Interest, installment ' || s.installment_no || ' of loan ' || l.loan_no, NULL, v_txn_id, v_txn_ref,
        p_channel => 'SYSTEM', p_branch_id => la.branch_id, p_value_date => s.due_date);
      v_lines(1) := pkg_ledger.new_line(l.loan_account_id, 'DR', s.interest_due);
      v_lines(2) := pkg_ledger.new_line(v_income, 'CR', s.interest_due);
      pkg_ledger.apply_lines(v_txn_id, v_lines, p_write => TRUE);
      UPDATE loan_schedule SET interest_txn_id = v_txn_id WHERE loan_id = p_loan_id AND installment_no = s.installment_no;
    END LOOP;
  END charge_due_interest;

  -- Installments past due become OVERDUE; days past due count from the oldest
  -- unpaid one; the class follows the band of loan_classes, but never improves
  -- here (an upgrade is a person's decision). One UPDATE sets days and class
  -- together, so the assertion loans_classification_as is never violated.
  PROCEDURE refresh_arrears (p_loan_id IN NUMBER, p_as_of IN DATE) IS
    v_oldest DATE;
    v_days   NUMBER;
    v_band   loan_classes.class_code%TYPE;
    v_class  loan_classes.class_code%TYPE;
  BEGIN
    UPDATE loan_schedule SET status = 'OVERDUE'
     WHERE loan_id = p_loan_id AND due_date < p_as_of AND status IN ('DUE', 'PARTIAL');
    SELECT MIN(due_date) INTO v_oldest
      FROM loan_schedule WHERE loan_id = p_loan_id AND status <> 'PAID' AND due_date < p_as_of;
    v_days := CASE WHEN v_oldest IS NULL THEN 0 ELSE p_as_of - v_oldest END;
    BEGIN
      SELECT class_code INTO v_band FROM loan_classes WHERE v_days BETWEEN min_days_past_due AND max_days_past_due;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        RAISE_APPLICATION_ERROR(pkg_errors.c_internal_error, 'Set-up error: no loan class covers ' || v_days || ' days past due');
    END;
    SELECT CASE WHEN b.min_days_past_due > c.min_days_past_due THEN b.class_code ELSE c.class_code END
      INTO v_class
      FROM loans l
      JOIN loan_classes c ON c.class_code = l.classification
      JOIN loan_classes b ON b.class_code = v_band
     WHERE l.loan_id = p_loan_id;
    UPDATE loans SET days_past_due = v_days, classification = v_class WHERE loan_id = p_loan_id;
  END refresh_arrears;

  -- ------------------------------------------------------------- schedules

  FUNCTION monthly_installment (p_principal IN NUMBER, p_annual_rate IN NUMBER, p_term_months IN NUMBER) RETURN NUMBER IS
    v_rate NUMBER := p_annual_rate / 1200;   -- monthly rate as a fraction
  BEGIN
    IF v_rate = 0 THEN
      RETURN ROUND(p_principal / p_term_months, 2);
    END IF;
    RETURN ROUND(p_principal * v_rate / (1 - POWER(1 + v_rate, -p_term_months)), 2);
  END monthly_installment;

  FUNCTION schedule_preview (
    p_principal      IN NUMBER,
    p_annual_rate    IN NUMBER,
    p_term_months    IN NUMBER,
    p_first_due_date IN DATE) RETURN t_schedule PIPELINED
  IS
    v_payment NUMBER := monthly_installment(p_principal, p_annual_rate, p_term_months);
    v_rate    NUMBER := p_annual_rate / 1200;
    v_balance NUMBER := p_principal;
    v_row     t_installment;
  BEGIN
    FOR i IN 1 .. p_term_months LOOP
      v_row.installment_no := i;
      v_row.due_date       := ADD_MONTHS(p_first_due_date, i - 1);
      v_row.interest_due   := ROUND(v_balance * v_rate, 2);
      -- The last installment takes whatever principal is left (rounding).
      v_row.principal_due  := CASE WHEN i = p_term_months THEN v_balance ELSE v_payment - v_row.interest_due END;
      v_row.total_due      := v_row.principal_due + v_row.interest_due;
      v_balance            := v_balance - v_row.principal_due;
      v_row.balance_after  := v_balance;
      PIPE ROW (v_row);   -- hand one row to the query, keep going
    END LOOP;
    RETURN;
  END schedule_preview;

  -- ------------------------------------------------------- applications

  FUNCTION submit_application (
    p_customer_no         IN VARCHAR2,
    p_product_code        IN VARCHAR2,
    p_amount              IN NUMBER,
    p_term_months         IN NUMBER,
    p_purpose             IN VARCHAR2,
    p_monthly_income      IN NUMBER,
    p_monthly_obligations IN NUMBER   DEFAULT 0,
    p_purpose_details     IN VARCHAR2 DEFAULT NULL) RETURN VARCHAR2
  IS
    v_me employees.employee_id%TYPE := pkg_session.employee_id;
    c    customers%ROWTYPE;
    p    loan_products%ROWTYPE;
    v_id     loan_applications.application_id%TYPE;
    v_no     loan_applications.application_no%TYPE;
    v_reason approval_requests.reason%TYPE;
  BEGIN
    BEGIN
      SELECT * INTO c FROM customers WHERE customer_no = p_customer_no;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        RAISE_APPLICATION_ERROR(pkg_errors.c_customer_not_found, 'Customer ' || p_customer_no || ' does not exist');
    END;
    -- Rules about this moment (not invariants): KYC, product range, affordability.
    IF c.kyc_status <> 'VERIFIED' THEN
      RAISE_APPLICATION_ERROR(pkg_errors.c_holder_kyc,
        'Customer ' || p_customer_no || ' must be identified (KYC VERIFIED) to apply; now ' || c.kyc_status);
    END IF;
    BEGIN
      SELECT * INTO p FROM loan_products WHERE product_code = p_product_code AND is_active;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        RAISE_APPLICATION_ERROR(pkg_errors.c_product_not_found, 'Loan product ' || p_product_code || ' does not exist or is no longer offered');
    END;
    pkg_ledger.check_amount(p_amount, p.currency_code);
    IF p_amount < p.min_amount OR p_amount > p.max_amount OR p_term_months IS NULL
       OR p_term_months < 1 OR p_term_months > p.max_term_months THEN
      RAISE_APPLICATION_ERROR(pkg_errors.c_outside_product,
        p.product_name || ' lends ' || fmt(p.min_amount) || ' to ' || fmt(p.max_amount) || ' ' || p.currency_code
        || ' over 1 to ' || p.max_term_months || ' months');
    END IF;
    check_affordable(p_amount, p.interest_rate, p_term_months, p_monthly_income, p_monthly_obligations);

    INSERT INTO loan_applications (customer_id, product_id, branch_id, requested_amount, requested_term_months, purpose,
                                   purpose_details, monthly_income, monthly_obligations, loan_officer_id)
    VALUES (c.customer_id, p.product_id, pkg_session.branch_id, p_amount, p_term_months, p_purpose,
            p_purpose_details, p_monthly_income, NVL(p_monthly_obligations, 0), v_me)
    RETURNING application_id, application_no INTO v_id, v_no;
    -- fmt is private, so it cannot appear inside the SQL statement (PLS-00231).
    v_reason := 'Loan application ' || v_no || ': ' || fmt(p_amount) || ' ' || p.currency_code
                || ' over ' || p_term_months || ' months';
    INSERT INTO approval_requests (request_type, application_id, reason, requested_by)
    VALUES ('LOAN_DECISION', v_id, v_reason, v_me);
    pkg_audit.log_event('LOAN_APPLIED', 'LOAN_APPLICATIONS', v_no, NULL,
      JSON_OBJECT('customer_no' VALUE p_customer_no, 'amount' VALUE p_amount, 'term_months' VALUE p_term_months
                  RETURNING VARCHAR2(4000)));
    RETURN v_no;
  END submit_application;

  PROCEDURE approve_application (
    p_application_no IN VARCHAR2,
    p_amount         IN NUMBER,
    p_term_months    IN NUMBER,
    p_margin_pct     IN NUMBER)
  IS
    v_me    employees.employee_id%TYPE := pkg_session.employee_id;
    a       loan_applications%ROWTYPE := lock_application(p_application_no);
    p       loan_products%ROWTYPE := product_of(a.product_id);
    v_limit NUMBER;
  BEGIN
    IF a.status NOT IN ('SUBMITTED', 'UNDER_REVIEW') THEN
      RAISE_APPLICATION_ERROR(pkg_errors.c_invalid_state, 'Application ' || p_application_no || ' is ' || a.status);
    END IF;
    IF v_me = a.loan_officer_id THEN
      RAISE_APPLICATION_ERROR(pkg_errors.c_own_approval, 'You cannot decide an application you captured (maker-checker)');
    END IF;
    IF p_amount IS NULL OR p_amount > a.requested_amount THEN
      RAISE_APPLICATION_ERROR(pkg_errors.c_invalid_state,
        'The bank may lend less than the ' || fmt(a.requested_amount) || ' asked for, never more');
    END IF;
    IF p_amount < p.min_amount OR p_term_months IS NULL OR p_term_months < 1 OR p_term_months > p.max_term_months THEN
      RAISE_APPLICATION_ERROR(pkg_errors.c_outside_product,
        p.product_name || ' lends ' || fmt(p.min_amount) || ' to ' || fmt(p.max_amount) || ' over 1 to ' || p.max_term_months || ' months');
    END IF;
    IF p_margin_pct IS NULL OR p_margin_pct < 0 THEN
      RAISE_APPLICATION_ERROR(pkg_errors.c_invalid_state, 'The margin over the Ghana Reference Rate must be zero or more');
    END IF;
    -- Credit authority: the checker's job limit for disbursements in this currency.
    v_limit := pkg_session.limit_for('LOAN_DISBURSEMENT', p.currency_code);
    IF p_amount > v_limit THEN
      RAISE_APPLICATION_ERROR(pkg_errors.c_over_your_limit,
        'Your credit authority in ' || p.currency_code || ' is ' || fmt(v_limit) || '; this loan is ' || fmt(p_amount));
    END IF;
    -- Affordable at the real price: GRR + margin.
    check_affordable(p_amount, pkg_params.num('GHANA_REFERENCE_RATE') + p_margin_pct, p_term_months,
                     a.monthly_income, a.monthly_obligations);

    UPDATE loan_applications
       SET status = 'APPROVED', approved_amount = p_amount, approved_term_months = p_term_months,
           approved_margin_pct = p_margin_pct, decided_by = v_me, decided_at = SYSTIMESTAMP
     WHERE application_id = a.application_id;
    UPDATE approval_requests SET status = 'APPROVED', decided_by = v_me, decided_at = SYSTIMESTAMP
     WHERE request_type = 'LOAN_DECISION' AND application_id = a.application_id AND status = 'PENDING';
    pkg_audit.log_event('LOAN_APPROVED', 'LOAN_APPLICATIONS', p_application_no, '{"status":"' || a.status || '"}',
      JSON_OBJECT('status' VALUE 'APPROVED', 'amount' VALUE p_amount, 'term_months' VALUE p_term_months,
                  'margin_pct' VALUE p_margin_pct RETURNING VARCHAR2(4000)));
  END approve_application;

  PROCEDURE reject_application (p_application_no IN VARCHAR2, p_reason IN VARCHAR2) IS
    v_me employees.employee_id%TYPE := pkg_session.employee_id;
    a    loan_applications%ROWTYPE := lock_application(p_application_no);
  BEGIN
    IF TRIM(p_reason) IS NULL THEN
      RAISE_APPLICATION_ERROR(pkg_errors.c_reason_required, 'Give a reason');
    END IF;
    IF a.status NOT IN ('SUBMITTED', 'UNDER_REVIEW') THEN
      RAISE_APPLICATION_ERROR(pkg_errors.c_invalid_state, 'Application ' || p_application_no || ' is ' || a.status);
    END IF;
    IF v_me = a.loan_officer_id THEN
      RAISE_APPLICATION_ERROR(pkg_errors.c_own_approval, 'You cannot decide an application you captured (maker-checker)');
    END IF;
    UPDATE loan_applications
       SET status = 'REJECTED', decided_by = v_me, decided_at = SYSTIMESTAMP, decision_note = SUBSTR(p_reason, 1, 400)
     WHERE application_id = a.application_id;
    UPDATE approval_requests
       SET status = 'REJECTED', decided_by = v_me, decided_at = SYSTIMESTAMP, decision_note = SUBSTR(p_reason, 1, 400)
     WHERE request_type = 'LOAN_DECISION' AND application_id = a.application_id AND status = 'PENDING';
    pkg_audit.log_event('LOAN_REJECTED', 'LOAN_APPLICATIONS', p_application_no, '{"status":"' || a.status || '"}',
      JSON_OBJECT('status' VALUE 'REJECTED', 'reason' VALUE p_reason RETURNING VARCHAR2(4000)));
  END reject_application;

  -- ------------------------------------------------------------ disbursement

  FUNCTION disburse (
    p_application_no          IN VARCHAR2,
    p_disbursement_account_no IN VARCHAR2,
    p_first_due_date          IN DATE     DEFAULT NULL,
    p_rate_type               IN VARCHAR2 DEFAULT 'VARIABLE') RETURN VARCHAR2
  IS
    v_me        employees.employee_id%TYPE := pkg_session.employee_id;
    a           loan_applications%ROWTYPE := lock_application(p_application_no);
    p           loan_products%ROWTYPE := product_of(a.product_id);
    c_kyc       customers.kyc_status%TYPE;
    d           accounts%ROWTYPE;
    v_count     PLS_INTEGER;
    v_loan_acc  accounts.account_id%TYPE;
    v_lines     pkg_ledger.t_lines;
    v_txn_id    transactions.txn_id%TYPE;
    v_txn_ref   transactions.txn_ref%TYPE;
    v_first     DATE := NVL(p_first_due_date, ADD_MONTHS(TRUNC(SYSDATE), 1));
    v_grr       NUMBER := pkg_params.num('GHANA_REFERENCE_RATE');
    v_loan_id   loans.loan_id%TYPE;
    v_loan_no   loans.loan_no%TYPE;
  BEGIN
    IF a.status <> 'APPROVED' THEN
      RAISE_APPLICATION_ERROR(pkg_errors.c_invalid_state, 'Application ' || p_application_no || ' is ' || a.status || ', not APPROVED');
    END IF;
    SELECT COUNT(*) INTO v_count FROM loans WHERE application_id = a.application_id;
    IF v_count > 0 THEN
      RAISE_APPLICATION_ERROR(pkg_errors.c_invalid_state, 'Application ' || p_application_no || ' has already been disbursed');
    END IF;
    -- Segregation of duties: approving and paying out are two people's jobs.
    IF v_me = a.decided_by THEN
      RAISE_APPLICATION_ERROR(pkg_errors.c_own_approval, 'The person who approved a loan cannot also disburse it');
    END IF;
    SELECT kyc_status INTO c_kyc FROM customers WHERE customer_id = a.customer_id;
    IF c_kyc <> 'VERIFIED' THEN
      RAISE_APPLICATION_ERROR(pkg_errors.c_holder_kyc, 'The borrower''s identity is no longer verified (KYC ' || c_kyc || ')');
    END IF;
    d := borrower_account(p_disbursement_account_no, a.customer_id, p.currency_code);

    -- The loan's own account: what the borrower owes is its balance. Approved
    -- by the credit decision (checked_by), opened by the disburser.
    INSERT INTO accounts (account_class, branch_id, currency_code, account_name, mandate, opened_by,
                          status, checked_by, checked_at, post_no_debit)
    VALUES ('LOAN', a.branch_id, p.currency_code, SUBSTR('Loan ' || a.application_no || ' - ' || p.product_name, 1, 100), 'SOLE', v_me,
            'ACTIVE', a.decided_by, a.decided_at, FALSE)
    RETURNING account_id INTO v_loan_acc;
    INSERT INTO account_holders (account_id, customer_id, holder_role) VALUES (v_loan_acc, a.customer_id, 'PRIMARY');

    -- The money: debit the loan account, credit the borrower's account.
    pkg_ledger.new_transaction('LOAN_DISBURSEMENT', p.currency_code, a.approved_amount,
      'Loan ' || a.application_no || ' paid out', v_me, v_txn_id, v_txn_ref, p_branch_id => a.branch_id);
    v_lines(1) := pkg_ledger.new_line(v_loan_acc, 'DR', a.approved_amount);
    v_lines(2) := pkg_ledger.new_line(d.account_id, 'CR', a.approved_amount);
    pkg_ledger.apply_lines(v_txn_id, v_lines, p_write => TRUE);

    INSERT INTO loans (application_id, loan_account_id, disbursement_account_id, disbursement_txn_id, principal,
                       rate_type, reference_rate, margin_pct, term_months, disbursed_on, first_due_date)
    VALUES (a.application_id, v_loan_acc, d.account_id, v_txn_id, a.approved_amount,
            p_rate_type, v_grr, a.approved_margin_pct, a.approved_term_months, TRUNC(SYSDATE), v_first)
    RETURNING loan_id, loan_no INTO v_loan_id, v_loan_no;

    -- The schedule, straight from the pipelined function.
    INSERT INTO loan_schedule (loan_id, installment_no, due_date, principal_due, interest_due)
    SELECT v_loan_id, s.installment_no, s.due_date, s.principal_due, s.interest_due
      FROM TABLE(pkg_loan.schedule_preview(a.approved_amount, v_grr + a.approved_margin_pct,
                                           a.approved_term_months, v_first)) s;

    pkg_audit.log_event('LOAN_DISBURSED', 'LOANS', v_loan_no, NULL,
      JSON_OBJECT('application_no' VALUE p_application_no, 'amount' VALUE a.approved_amount,
                  'rate' VALUE v_grr + a.approved_margin_pct, 'txn_ref' VALUE v_txn_ref RETURNING VARCHAR2(4000)));
    RETURN v_loan_no;
  END disburse;

  -- -------------------------------------------------------------- servicing

  FUNCTION amount_due (p_loan_no IN VARCHAR2, p_as_of IN DATE DEFAULT TRUNC(SYSDATE)) RETURN NUMBER IS
    v_due NUMBER;
  BEGIN
    SELECT NVL(SUM((s.principal_due - s.principal_paid) + (s.interest_due - s.interest_paid)), 0)
      INTO v_due
      FROM loan_schedule s JOIN loans l ON l.loan_id = s.loan_id
     WHERE l.loan_no = p_loan_no AND s.due_date <= p_as_of AND s.status <> 'PAID';
    RETURN v_due;
  END amount_due;

  FUNCTION repay (
    p_loan_no         IN VARCHAR2,
    p_from_account_no IN VARCHAR2,
    p_amount          IN NUMBER,
    p_as_of           IN DATE DEFAULT TRUNC(SYSDATE)) RETURN VARCHAR2
  IS
    v_me        employees.employee_id%TYPE := pkg_session.employee_id;
    l           loans%ROWTYPE := lock_loan(p_loan_no);
    la          accounts%ROWTYPE;
    v_customer  customers.customer_id%TYPE;
    f           accounts%ROWTYPE;
    v_due       NUMBER;
    v_left      NUMBER;
    v_interest  NUMBER;
    v_principal NUMBER;
    v_status    loan_schedule.status%TYPE;
    v_open      PLS_INTEGER;
    v_lines     pkg_ledger.t_lines;
    v_txn_id    transactions.txn_id%TYPE;
    v_txn_ref   transactions.txn_ref%TYPE;
  BEGIN
    IF l.status <> 'ACTIVE' THEN
      RAISE_APPLICATION_ERROR(pkg_errors.c_invalid_state, 'Loan ' || p_loan_no || ' is ' || l.status);
    END IF;
    SELECT * INTO la FROM accounts WHERE account_id = l.loan_account_id;
    SELECT customer_id INTO v_customer FROM loan_applications WHERE application_id = l.application_id;
    f := borrower_account(p_from_account_no, v_customer, la.currency_code);
    pkg_ledger.check_amount(p_amount, la.currency_code);

    -- Interest of installments now due, in case tonight's run has not charged it yet.
    charge_due_interest(l.loan_id, p_as_of);
    v_due := amount_due(p_loan_no, p_as_of);
    IF p_amount > v_due THEN
      RAISE_APPLICATION_ERROR(pkg_errors.c_more_than_due,
        'Only ' || fmt(v_due) || ' ' || la.currency_code || ' is due on ' || TO_CHAR(p_as_of, 'YYYY-MM-DD')
        || '; early repayment is not supported yet');
    END IF;

    -- The money: debit the borrower's account, credit the loan account.
    pkg_ledger.new_transaction('LOAN_REPAYMENT', la.currency_code, p_amount, 'Repayment of loan ' || p_loan_no,
                               v_me, v_txn_id, v_txn_ref);
    v_lines(1) := pkg_ledger.new_line(f.account_id, 'DR', p_amount);
    v_lines(2) := pkg_ledger.new_line(l.loan_account_id, 'CR', p_amount);
    pkg_ledger.apply_lines(v_txn_id, v_lines, p_write => TRUE);

    -- Allocation: oldest installment first; within it, interest before principal.
    v_left := p_amount;
    FOR s IN (SELECT * FROM loan_schedule
               WHERE loan_id = l.loan_id AND due_date <= p_as_of AND status <> 'PAID'
               ORDER BY installment_no) LOOP
      EXIT WHEN v_left = 0;
      v_interest  := LEAST(v_left, s.interest_due - s.interest_paid);
      v_left      := v_left - v_interest;
      v_principal := LEAST(v_left, s.principal_due - s.principal_paid);
      v_left      := v_left - v_principal;
      IF v_interest + v_principal > 0 THEN
        INSERT INTO loan_repayments (txn_id, loan_id, installment_no, principal_amount, interest_amount)
        VALUES (v_txn_id, l.loan_id, s.installment_no, v_principal, v_interest);
        v_status := CASE
                      WHEN s.interest_paid + v_interest = s.interest_due
                       AND s.principal_paid + v_principal = s.principal_due THEN 'PAID'
                      WHEN s.due_date < p_as_of THEN 'OVERDUE'
                      ELSE 'PARTIAL'
                    END;
        UPDATE loan_schedule
           SET interest_paid  = interest_paid + v_interest,
               principal_paid = principal_paid + v_principal,
               status         = v_status,
               paid_on        = CASE WHEN v_status = 'PAID' THEN p_as_of END
         WHERE loan_id = l.loan_id AND installment_no = s.installment_no;
      END IF;
    END LOOP;

    refresh_arrears(l.loan_id, p_as_of);
    SELECT COUNT(*) INTO v_open FROM loan_schedule WHERE loan_id = l.loan_id AND status <> 'PAID';
    IF v_open = 0 THEN
      UPDATE loans SET status = 'CLOSED', closed_on = p_as_of, days_past_due = 0 WHERE loan_id = l.loan_id;
    END IF;

    pkg_audit.log_event('LOAN_REPAID', 'LOANS', p_loan_no, NULL,
      JSON_OBJECT('txn_ref' VALUE v_txn_ref, 'amount' VALUE p_amount, 'closed' VALUE CASE WHEN v_open = 0 THEN 'yes' ELSE 'no' END
                  RETURNING VARCHAR2(4000)));
    RETURN v_txn_ref;
  END repay;

  PROCEDURE run_end_of_day (p_as_of IN DATE DEFAULT TRUNC(SYSDATE)) IS
    v_loans   PLS_INTEGER := 0;
    v_charged PLS_INTEGER;
    v_before  PLS_INTEGER;
    v_id      loans.loan_id%TYPE;
  BEGIN
    SELECT COUNT(*) INTO v_before FROM loan_schedule WHERE interest_txn_id IS NOT NULL;
    FOR l IN (SELECT loan_id FROM loans WHERE status = 'ACTIVE' ORDER BY loan_id) LOOP
      SELECT loan_id INTO v_id FROM loans WHERE loan_id = l.loan_id FOR UPDATE;   -- one loan at a time
      charge_due_interest(l.loan_id, p_as_of);
      refresh_arrears(l.loan_id, p_as_of);
      v_loans := v_loans + 1;
    END LOOP;
    SELECT COUNT(*) - v_before INTO v_charged FROM loan_schedule WHERE interest_txn_id IS NOT NULL;
    pkg_audit.log_event('LOANS_END_OF_DAY', 'LOANS', TO_CHAR(p_as_of, 'YYYY-MM-DD'), NULL,
      JSON_OBJECT('loans' VALUE v_loans, 'interest_charges' VALUE v_charged RETURNING VARCHAR2(4000)));
  END run_end_of_day;

END pkg_loan;
/
--rollback DROP PACKAGE BODY pkg_loan
