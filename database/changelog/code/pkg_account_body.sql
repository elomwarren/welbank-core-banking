--liquibase formatted sql

--changeset elomwarren:code-pkg-account-body runOnChange:true endDelimiter:/
CREATE OR REPLACE PACKAGE BODY pkg_account AS

  FUNCTION find_customer (p_customer_no IN VARCHAR2) RETURN customers%ROWTYPE IS
    c customers%ROWTYPE;
  BEGIN
    SELECT * INTO c FROM customers WHERE customer_no = p_customer_no;
    RETURN c;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      RAISE_APPLICATION_ERROR(pkg_errors.c_customer_not_found, 'Customer ' || p_customer_no || ' does not exist');
  END find_customer;

  -- The customer account with this number, locked.
  FUNCTION lock_account (p_account_no IN VARCHAR2) RETURN accounts%ROWTYPE IS
    a accounts%ROWTYPE;
  BEGIN
    SELECT * INTO a FROM accounts WHERE account_no = p_account_no AND account_class = 'CUSTOMER' FOR UPDATE;
    RETURN a;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      RAISE_APPLICATION_ERROR(pkg_errors.c_account_not_found, 'Customer account ' || p_account_no || ' does not exist');
  END lock_account;

  -- The PENDING account-opening request of an account, locked.
  FUNCTION opening_request (p_account_id IN NUMBER) RETURN approval_requests.request_id%TYPE IS
    v_id approval_requests.request_id%TYPE;
  BEGIN
    SELECT request_id INTO v_id
      FROM approval_requests
     WHERE request_type = 'ACCOUNT_OPENING' AND account_id = p_account_id AND status = 'PENDING'
       FOR UPDATE;
    RETURN v_id;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      RAISE_APPLICATION_ERROR(pkg_errors.c_request_not_found, 'No pending opening request for this account');
  END opening_request;

  PROCEDURE check_checker (p_me IN NUMBER, p_maker IN NUMBER) IS
  BEGIN
    IF p_me = p_maker THEN
      RAISE_APPLICATION_ERROR(pkg_errors.c_own_approval, 'You cannot approve or reject an account you opened (maker-checker)');
    END IF;
  END check_checker;

  FUNCTION open_account (
    p_customer_no  IN VARCHAR2,
    p_product_code IN VARCHAR2,
    p_mandate      IN VARCHAR2 DEFAULT 'SOLE',
    p_account_name IN VARCHAR2 DEFAULT NULL) RETURN VARCHAR2
  IS
    v_me      employees.employee_id%TYPE := pkg_session.employee_id;
    c         customers%ROWTYPE := find_customer(p_customer_no);
    p         account_products%ROWTYPE;
    v_id      accounts.account_id%TYPE;
    v_no      accounts.account_no%TYPE;
  BEGIN
    IF c.status IN ('CLOSED', 'BLOCKED') OR c.kyc_status = 'REJECTED' THEN
      RAISE_APPLICATION_ERROR(pkg_errors.c_invalid_state,
        'Customer ' || p_customer_no || ' cannot open accounts (status ' || c.status || ', KYC ' || c.kyc_status || ')');
    END IF;
    BEGIN
      SELECT * INTO p FROM account_products WHERE product_code = p_product_code AND is_active;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        RAISE_APPLICATION_ERROR(pkg_errors.c_product_not_found, 'Product ' || p_product_code || ' does not exist or is no longer sold');
    END;

    INSERT INTO accounts (account_class, product_id, branch_id, currency_code, account_name, mandate, opened_by)
    VALUES ('CUSTOMER', p.product_id, pkg_session.branch_id, p.currency_code,
            SUBSTR(NVL(p_account_name, c.first_name || ' ' || c.last_name || ' - ' || p.product_name), 1, 100),
            p_mandate, v_me)
    RETURNING account_id, account_no INTO v_id, v_no;
    INSERT INTO account_holders (account_id, customer_id, holder_role) VALUES (v_id, c.customer_id, 'PRIMARY');
    INSERT INTO approval_requests (request_type, account_id, reason, requested_by)
    VALUES ('ACCOUNT_OPENING', v_id, 'New ' || p.product_name || ' account', v_me);
    pkg_audit.log_event('ACCOUNT_OPENED', 'ACCOUNTS', v_no, NULL,
      JSON_OBJECT('customer_no' VALUE p_customer_no, 'product' VALUE p_product_code, 'mandate' VALUE p_mandate
                  RETURNING VARCHAR2(4000)));
    RETURN v_no;
  END open_account;

  PROCEDURE add_holder (p_account_no IN VARCHAR2, p_customer_no IN VARCHAR2, p_holder_role IN VARCHAR2) IS
    v_me employees.employee_id%TYPE := pkg_session.employee_id;
    a    accounts%ROWTYPE := lock_account(p_account_no);
    c    customers%ROWTYPE := find_customer(p_customer_no);
  BEGIN
    IF a.status IN ('CLOSED', 'REJECTED') THEN
      RAISE_APPLICATION_ERROR(pkg_errors.c_invalid_state, 'Account ' || p_account_no || ' is ' || a.status);
    END IF;
    IF p_holder_role IS NULL OR p_holder_role NOT IN ('JOINT', 'SIGNATORY') THEN
      RAISE_APPLICATION_ERROR(pkg_errors.c_invalid_state,
        'A holder added later is JOINT or SIGNATORY; the PRIMARY holder is set when the account is opened');
    END IF;
    IF p_holder_role = 'JOINT' AND a.mandate = 'SOLE' THEN
      RAISE_APPLICATION_ERROR(pkg_errors.c_invalid_state, 'Account ' || p_account_no || ' has a SOLE mandate: it cannot have joint holders');
    END IF;
    IF NOT a.post_no_debit AND c.kyc_status <> 'VERIFIED' THEN
      RAISE_APPLICATION_ERROR(pkg_errors.c_holder_kyc,
        'Account ' || p_account_no || ' allows debits, so every holder must be verified; customer '
        || p_customer_no || ' is ' || c.kyc_status);
    END IF;
    INSERT INTO account_holders (account_id, customer_id, holder_role) VALUES (a.account_id, c.customer_id, p_holder_role);
    pkg_audit.log_event('HOLDER_ADDED', 'ACCOUNTS', p_account_no, NULL,
      JSON_OBJECT('customer_no' VALUE p_customer_no, 'role' VALUE p_holder_role RETURNING VARCHAR2(4000)));
  END add_holder;

  PROCEDURE approve_account (p_account_no IN VARCHAR2) IS
    v_me           employees.employee_id%TYPE := pkg_session.employee_id;
    a              accounts%ROWTYPE := lock_account(p_account_no);
    v_request      approval_requests.request_id%TYPE;
    v_all_verified BOOLEAN := TRUE;
  BEGIN
    IF a.status <> 'PENDING_APPROVAL' THEN
      RAISE_APPLICATION_ERROR(pkg_errors.c_invalid_state, 'Account ' || p_account_no || ' is ' || a.status || ', not PENDING_APPROVAL');
    END IF;
    check_checker(v_me, a.opened_by);
    v_request := opening_request(a.account_id);

    -- Every holder must be identified: VERIFIED, or DEFERRED (deposits only).
    FOR h IN (SELECT c.customer_no, c.kyc_status
                FROM account_holders h JOIN customers c ON c.customer_id = h.customer_id
               WHERE h.account_id = a.account_id
               ORDER BY c.customer_no) LOOP
      IF h.kyc_status NOT IN ('VERIFIED', 'DEFERRED') THEN
        RAISE_APPLICATION_ERROR(pkg_errors.c_holder_kyc,
          'Holder ' || h.customer_no || ' has not been identified yet (KYC ' || h.kyc_status || ')');
      END IF;
      v_all_verified := v_all_verified AND h.kyc_status = 'VERIFIED';
    END LOOP;

    UPDATE accounts
       SET status = 'ACTIVE', checked_by = v_me, checked_at = SYSTIMESTAMP, post_no_debit = NOT v_all_verified
     WHERE account_id = a.account_id;
    UPDATE approval_requests SET status = 'APPROVED', decided_by = v_me, decided_at = SYSTIMESTAMP
     WHERE request_id = v_request;
    pkg_audit.log_event('ACCOUNT_APPROVED', 'ACCOUNTS', p_account_no, '{"status":"PENDING_APPROVAL"}',
      CASE WHEN v_all_verified THEN '{"status":"ACTIVE","post_no_debit":false}'
           ELSE '{"status":"ACTIVE","post_no_debit":true}' END);
  END approve_account;

  PROCEDURE reject_account (p_account_no IN VARCHAR2, p_reason IN VARCHAR2) IS
    v_me      employees.employee_id%TYPE := pkg_session.employee_id;
    a         accounts%ROWTYPE := lock_account(p_account_no);
    v_request approval_requests.request_id%TYPE;
  BEGIN
    IF TRIM(p_reason) IS NULL THEN
      RAISE_APPLICATION_ERROR(pkg_errors.c_reason_required, 'Give a reason');
    END IF;
    IF a.status <> 'PENDING_APPROVAL' THEN
      RAISE_APPLICATION_ERROR(pkg_errors.c_invalid_state, 'Account ' || p_account_no || ' is ' || a.status || ', not PENDING_APPROVAL');
    END IF;
    check_checker(v_me, a.opened_by);
    v_request := opening_request(a.account_id);
    UPDATE accounts SET status = 'REJECTED', checked_by = v_me, checked_at = SYSTIMESTAMP WHERE account_id = a.account_id;
    UPDATE approval_requests
       SET status = 'REJECTED', decided_by = v_me, decided_at = SYSTIMESTAMP, decision_note = SUBSTR(p_reason, 1, 400)
     WHERE request_id = v_request;
    pkg_audit.log_event('ACCOUNT_REJECTED', 'ACCOUNTS', p_account_no, '{"status":"PENDING_APPROVAL"}',
      JSON_OBJECT('status' VALUE 'REJECTED', 'reason' VALUE p_reason RETURNING VARCHAR2(4000)));
  END reject_account;

  PROCEDURE refresh_debits (p_customer_id IN NUMBER) IS
  BEGIN
    -- One statement for all of the customer's active accounts: debits on
    -- exactly when no holder of the account is unverified.
    UPDATE accounts a
       SET a.post_no_debit = CASE
             WHEN EXISTS (SELECT 1 FROM account_holders h JOIN customers c ON c.customer_id = h.customer_id
                           WHERE h.account_id = a.account_id AND c.kyc_status <> 'VERIFIED')
             THEN TRUE ELSE FALSE END
     WHERE a.status = 'ACTIVE'
       AND a.account_id IN (SELECT h.account_id FROM account_holders h WHERE h.customer_id = p_customer_id);
  END refresh_debits;

END pkg_account;
/
--rollback DROP PACKAGE BODY pkg_account
