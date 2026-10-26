-- =============================================================================
-- 0008_onboarding_test.sql — pkg_customer and pkg_account: registration, KYC
-- capture and approval, deferral, account opening and approval, and how KYC
-- switches debits on and off.
--
-- Run by database/tests/run_tests.sh as SYSDBA inside WELBANK. Everything runs
-- in one transaction that is rolled back at the end: no data is left behind.
-- act_as() chooses which test employee the session user (SYS) is, as in
-- 0007_posting_test.sql.
-- =============================================================================
SET SERVEROUTPUT ON SIZE UNLIMITED FEEDBACK OFF LINESIZE 200
ALTER SESSION SET CURRENT_SCHEMA = welbank;

DECLARE
  passed PLS_INTEGER := 0;
  failed PLS_INTEGER := 0;
  v_region NUMBER; v_branch NUMBER; v_dept NUMBER; v_job_cso NUMBER; v_job_sup NUMBER;
  v_cso NUMBER; v_sup NUMBER;
  v_c1 VARCHAR2(12); v_c2 VARCHAR2(12); v_c3 VARCHAR2(12); v_pep VARCHAR2(12);
  v_acc1 VARCHAR2(13); v_acc2 VARCHAR2(13); v_acc3 VARCHAR2(13); v_acc4 VARCHAR2(13); v_joint VARCHAR2(13);
  v_text   VARCHAR2(4000);
  v_count  PLS_INTEGER;
  v_num    NUMBER;
  v_date   DATE;
  v_flag   BOOLEAN;
  v_ref    VARCHAR2(20);
  -- A valid 1x1 PNG (70 bytes, generated with Python; see 0004_customers_kyc_test.sql).
  c_png    CONSTANT RAW(100) := HEXTORAW('89504E470D0A1A0A0000000D49484452000000010000000108060000001F15C4890000000D49444154789C6360606060000000050001A5F645400000000049454E44AE426082');
  v_sha    VARCHAR2(64);
  v_blob   BLOB;

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

  -- A register_customer call as text, with the usual values; p_overrides adds
  -- or replaces named parameters, e.g. 'p_data_consent => FALSE'.
  FUNCTION register_sql(p_card VARCHAR2, p_overrides VARCHAR2 DEFAULT NULL,
                        p_dob VARCHAR2 DEFAULT 'DATE ''1990-05-01''', p_nationality VARCHAR2 DEFAULT 'GHA',
                        p_doc_type VARCHAR2 DEFAULT 'GHANA_CARD') RETURN VARCHAR2 IS
  BEGIN
    RETURN 'DECLARE r VARCHAR2(12); BEGIN r := pkg_customer.register_customer('
        || 'p_first_name => ''Kofi'', p_last_name => ''Mensa'', p_sex => ''MALE'', p_date_of_birth => ' || p_dob
        || ', p_nationality => ' || q(p_nationality) || ', p_doc_type => ' || q(p_doc_type) || ', p_doc_number => ' || q(p_card)
        || ', p_employment_status => ''EMPLOYED'', p_income_band => ''1K_5K'', p_source_of_funds => ''SALARY'''
        || ', p_account_purpose => ''SAVINGS'', p_expected_monthly_volume => 2000'
        || CASE WHEN p_overrides IS NULL OR INSTR(p_overrides, 'p_data_consent') = 0 THEN ', p_data_consent => TRUE' END
        || CASE WHEN p_overrides IS NOT NULL THEN ', ' || p_overrides END
        || '); END;';
  END;

  -- Runs register_sql and returns the new customer number (FAIL line and NULL on error).
  FUNCTION register(p_name VARCHAR2, p_card VARCHAR2, p_overrides VARCHAR2 DEFAULT NULL) RETURN VARCHAR2 IS
    v VARCHAR2(12);
  BEGIN
    -- Hand the number back through a bind variable (only here: rejects()
    -- runs the plain text, which must have no placeholder).
    EXECUTE IMMEDIATE REPLACE(register_sql(p_card, p_overrides), '); END;', '); :r := r; END;') USING OUT v;
    RETURN v;
  EXCEPTION WHEN OTHERS THEN
    failed := failed + 1;
    DBMS_OUTPUT.PUT_LINE('FAIL  accepts  ' || p_name || '  -> ' || SQLERRM);
    RETURN NULL;
  END;

  FUNCTION kyc_of(p_customer_no VARCHAR2) RETURN VARCHAR2 IS
    v VARCHAR2(30);
  BEGIN
    SELECT kyc_status INTO v FROM customers WHERE customer_no = p_customer_no;
    RETURN v;
  END;

  FUNCTION debits_on(p_account_no VARCHAR2) RETURN BOOLEAN IS
    v BOOLEAN;
  BEGIN
    SELECT NOT post_no_debit INTO v FROM accounts WHERE account_no = p_account_no;
    RETURN v;
  END;

  FUNCTION status_of(p_account_no VARCHAR2) RETURN VARCHAR2 IS
    v VARCHAR2(20);
  BEGIN
    SELECT status INTO v FROM accounts WHERE account_no = p_account_no;
    RETURN v;
  END;

  -- Everything a complete KYC file needs, apart from the verification and screening.
  PROCEDURE capture_kyc_data(p_customer_no VARCHAR2) IS
  BEGIN
    pkg_customer.add_address(p_customer_no, 'RESIDENTIAL', 'House 12, Oxford Street', 'Accra', v_region, 'GHA', 'GA-123-4567',
                             'Behind the Methodist church', DATE '2015-03-01', 'UTILITY_BILL', DATE '2026-09-30');
    pkg_customer.add_contact(p_customer_no, 'MOBILE', '+233244000801', TRUE);
    pkg_customer.add_file(p_customer_no, 'PHOTO', 'image/png', v_blob, v_sha);
    pkg_customer.add_file(p_customer_no, 'SIGNATURE', 'image/png', v_blob, v_sha);
  END;
BEGIN
  -- ---------------------------------------------------------------- fixtures
  MERGE INTO countries c USING (SELECT 'GHA' code FROM dual) s ON (c.country_code = s.code)
    WHEN NOT MATCHED THEN INSERT (country_code, country_name, nationality_name) VALUES ('GHA', 'Ghana', 'Ghanaian');
  MERGE INTO countries c USING (SELECT 'ZZA' code FROM dual) s ON (c.country_code = s.code)
    WHEN NOT MATCHED THEN INSERT (country_code, country_name, nationality_name) VALUES ('ZZA', 'Testland', 'Testlander');
  INSERT INTO currencies (currency_code, currency_name) VALUES ('XTS', 'Test currency XTS');
  INSERT INTO regions (region_name) VALUES ('Test region 9') RETURNING region_id INTO v_region;
  INSERT INTO branches (branch_code, branch_name, region_id, phone, opened_on)
    VALUES ('T-BR9', 'Test branch 9', v_region, '+233200000901', DATE '2020-01-01') RETURNING branch_id INTO v_branch;
  INSERT INTO departments (department_name) VALUES ('Test customer service 9') RETURNING department_id INTO v_dept;
  INSERT INTO jobs (job_title, department_id, min_salary, max_salary) VALUES ('Test CSO 9', v_dept, 20000, 40000) RETURNING job_id INTO v_job_cso;
  INSERT INTO jobs (job_title, department_id, min_salary, max_salary) VALUES ('Test supervisor 9', v_dept, 20000, 90000) RETURNING job_id INTO v_job_sup;
  INSERT INTO employees (first_name, last_name, sex, date_of_birth, nationality, work_email, phone, job_id, branch_id, salary, hire_date)
    VALUES ('Abena', 'Cso', 'FEMALE', DATE '1992-02-02', 'GHA', 'abena.cso.t9@example.com', '+233200000910', v_job_cso, v_branch, 30000, DATE '2021-01-04')
    RETURNING employee_id INTO v_cso;
  INSERT INTO employees (first_name, last_name, sex, date_of_birth, nationality, work_email, phone, job_id, branch_id, salary, hire_date)
    VALUES ('Kojo', 'Sup', 'MALE', DATE '1983-03-03', 'GHA', 'kojo.sup.t9@example.com', '+233200000911', v_job_sup, v_branch, 70000, DATE '2016-01-04')
    RETURNING employee_id INTO v_sup;
  INSERT INTO account_products (product_code, product_name, account_type, currency_code)
    VALUES ('T9-SAV', 'Test savings 9', 'SAVINGS', 'XTS');
  INSERT INTO account_products (product_code, product_name, account_type, currency_code, is_active)
    VALUES ('T9-OLD', 'Test retired product 9', 'SAVINGS', 'XTS', FALSE);
  SELECT LOWER(RAWTOHEX(STANDARD_HASH(c_png, 'SHA256'))) INTO v_sha FROM dual;
  v_blob := TO_BLOB(c_png);

  -- ------------------------------------------------------------ registration
  rejects('registering a customer as a non-employee', register_sql('GHA-000000901-1'), 'ORA-20001');
  act_as(v_cso);
  rejects('customer under 18', register_sql('GHA-000000902-1', p_dob => 'ADD_MONTHS(TRUNC(SYSDATE), -12 * 17)'), 'ORA-20019');
  rejects('no consent to data processing (Act 843)', register_sql('GHA-000000903-1', 'p_data_consent => FALSE'), 'ORA-20020');
  rejects('Ghana Card number in the wrong format', register_sql('GHA-12345'), 'IDENTITY_DOCUMENTS_PIN_CK');
  rejects('a Ghana Card for a foreign national', register_sql('GHA-000000904-1', p_nationality => 'ZZA'), 'ORA-20024');
  rejects('a passport for a Ghanaian living in Ghana', register_sql('G1234567', p_doc_type => 'PASSPORT'), 'ORA-20024');
  v_c1 := register('register Kofi', 'GHA-000000905-1');
  SELECT COUNT(*) INTO v_count FROM customers c JOIN identity_documents d ON d.customer_id = c.customer_id
   WHERE c.customer_no = v_c1 AND c.kyc_status = 'PENDING_VERIFICATION' AND c.status = 'PENDING_KYC'
     AND c.home_branch_id = v_branch AND c.relationship_officer_id = v_cso AND c.data_consent_at IS NOT NULL
     AND d.is_primary AND d.doc_type = 'GHANA_CARD';
  check_that('Kofi registered (' || v_c1 || '): pending KYC, primary Ghana Card, branch and officer set', v_count = 1);
  v_text := pkg_customer.kyc_missing(v_c1);
  check_that('kyc_missing lists six items: ' || SUBSTR(v_text, 1, 120) || '...',
             REGEXP_COUNT(v_text, ', ') = 5 AND INSTR(v_text, 'live photo') > 0 AND INSTR(v_text, 'sanctions') > 0);
  rejects('submitting an incomplete KYC (the message lists what is missing)',
    'BEGIN pkg_customer.submit_kyc(' || q(v_c1) || '); END;', 'ORA-20021.*live photo');

  -- -------------------------------------------------------- secondary data
  capture_kyc_data(v_c1);
  pkg_customer.add_address(v_c1, 'RESIDENTIAL', 'Flat 3, Ring Road', 'Accra', v_region, 'GHA', 'GA-321-7654');
  SELECT COUNT(*), SUM(CASE WHEN is_current THEN 1 ELSE 0 END) INTO v_count, v_num
    FROM customer_addresses a JOIN customers c ON c.customer_id = a.customer_id
   WHERE c.customer_no = v_c1 AND a.address_type = 'RESIDENTIAL';
  check_that('a new residential address keeps the old one as history (2 rows, 1 current)', v_count = 2 AND v_num = 1);
  pkg_customer.add_contact(v_c1, 'EMAIL', 'kofi.mensa@example.com', TRUE);
  pkg_customer.add_contact(v_c1, 'MOBILE', '+233244000802', TRUE);
  SELECT COUNT(*) INTO v_count FROM customer_contacts k JOIN customers c ON c.customer_id = k.customer_id
   WHERE c.customer_no = v_c1 AND k.is_primary;
  check_that('a new primary phone replaces the old one; the e-mail stays primary (2 primaries)', v_count = 2);
  pkg_customer.add_next_of_kin(v_c1, 'Ama Mensa', 'SPOUSE', '+233244000803');
  rejects('a text file pretending to be a PNG',
    'BEGIN pkg_customer.add_file(' || q(v_c1) || ', ''PROOF_OF_ADDRESS'', ''image/png'', TO_BLOB(UTL_RAW.CAST_TO_RAW(''this is not a picture at all''))'
    || ', ' || q(v_sha) || '); END;', 'ORA-20023');
  rejects('a PNG declared as a JPEG',
    'BEGIN pkg_customer.add_file(' || q(v_c1) || ', ''PROOF_OF_ADDRESS'', ''image/jpeg'', TO_BLOB(HEXTORAW(''' || RAWTOHEX(c_png) || ''')), '
    || q(v_sha) || '); END;', 'ORA-20023');
  SELECT COUNT(*) INTO v_count FROM customer_files f JOIN customers c ON c.customer_id = f.customer_id
   WHERE c.customer_no = v_c1 AND f.file_kind = 'PHOTO' AND f.is_current AND f.byte_size = 70;
  check_that('photo stored; its size measured by the package (70 bytes)', v_count = 1);

  -- ---------------------------------------------------------- verification
  rejects('checking a Ghana Card by looking at it (L.I. 2111)',
    'DECLARE r NUMBER; BEGIN r := pkg_customer.record_verification(' || q(v_c1) || ', ''ONBOARDING'', ''MANUAL_DOCUMENT'', ''MATCH'', ''X''); END;',
    'ORA-20024');
  v_num := pkg_customer.record_verification(v_c1, 'ONBOARDING', 'FACE', 'MATCH', 'NIA-REF-0001',
             p_nia_data => '{"first_name": "Kofi", "last_name": "Mensah", "previous_names": "Kofi Mensa", "date_of_birth": "1990-05-02"}');
  SELECT COUNT(*) INTO v_count FROM customers
   WHERE customer_no = v_c1 AND last_name = 'Mensah' AND previous_names = 'Kofi Mensa'
     AND date_of_birth = DATE '1990-05-02' AND nia_last_synced_at IS NOT NULL;
  check_that('a MATCH replaces the typed names and birth date with NIA''s (Mensa -> Mensah)', v_count = 1);
  SELECT COUNT(*) INTO v_count FROM identity_verifications WHERE verification_id = v_num AND is_simulated AND performed_by = v_cso;
  check_that('the verification is recorded, marked simulated, with the officer', v_count = 1);
  pkg_customer.record_screening(v_c1, 'CLEAR');
  check_that('nothing missing any more', pkg_customer.kyc_missing(v_c1) IS NULL);

  -- --------------------------------------------------------- KYC approval
  accepts('officer submits the KYC', 'BEGIN pkg_customer.submit_kyc(' || q(v_c1) || '); END;');
  rejects('submitting it twice', 'BEGIN pkg_customer.submit_kyc(' || q(v_c1) || '); END;', 'ORA-20022');
  rejects('the officer approving their own submission', 'BEGIN pkg_customer.approve_kyc(' || q(v_c1) || ', ''LOW''); END;', 'ORA-20013');
  act_as(v_sup);
  rejects('risk rating EXTREME', 'BEGIN pkg_customer.approve_kyc(' || q(v_c1) || ', ''EXTREME''); END;', 'ORA-20022');
  accepts('supervisor approves with risk LOW', 'BEGIN pkg_customer.approve_kyc(' || q(v_c1) || ', ''LOW''); END;');
  SELECT COUNT(*) INTO v_count FROM customers
   WHERE customer_no = v_c1 AND kyc_status = 'VERIFIED' AND status = 'ACTIVE' AND kyc_approved_by = v_sup
     AND risk_rating = 'LOW' AND due_diligence_level = 'STANDARD'
     AND next_kyc_review_on = ADD_MONTHS(TRUNC(SYSDATE), 36);
  check_that('VERIFIED, ACTIVE, approved by the supervisor; next review in 36 months (bank_parameters)', v_count = 1);

  -- ------------------------------------------------------- deferral (90 days)
  act_as(v_cso);
  v_c2 := register('register Ama', 'GHA-000000906-1');
  v_num := pkg_customer.record_verification(v_c2, 'ONBOARDING', 'SINGLE_FINGER', 'NO_MATCH', p_error_code => NULL);
  SELECT kyc_deferral_until INTO v_date FROM customers WHERE customer_no = v_c2;
  check_that('a NO_MATCH at onboarding defers the KYC for 90 days (' || TO_CHAR(v_date, 'YYYY-MM-DD') || ')',
             kyc_of(v_c2) = 'DEFERRED' AND v_date = TRUNC(SYSDATE) + 90);
  v_num := pkg_customer.record_verification(v_c2, 'ONBOARDING', 'FACE', 'FAILED', p_error_code => 'LOW_QUALITY');
  SELECT kyc_deferral_until INTO v_date FROM customers WHERE customer_no = v_c2;
  check_that('a second failure does not restart the 90 days', v_date = TRUNC(SYSDATE) + 90);
  v_c3 := register('register Yaw', 'GHA-000000907-1');

  -- ------------------------------------------------------- account opening
  rejects('opening an account of an unknown product',
    'DECLARE r VARCHAR2(13); BEGIN r := pkg_account.open_account(' || q(v_c1) || ', ''NOPE''); END;', 'ORA-20025');
  rejects('opening an account of a product no longer sold',
    'DECLARE r VARCHAR2(13); BEGIN r := pkg_account.open_account(' || q(v_c1) || ', ''T9-OLD''); END;', 'ORA-20025');
  v_acc1 := pkg_account.open_account(v_c1, 'T9-SAV');
  SELECT COUNT(*) INTO v_count FROM accounts a JOIN approval_requests r ON r.account_id = a.account_id
   WHERE a.account_no = v_acc1 AND a.status = 'PENDING_APPROVAL' AND a.post_no_debit AND a.opened_by = v_cso
     AND r.request_type = 'ACCOUNT_OPENING' AND r.status = 'PENDING';
  check_that('account ' || v_acc1 || ' opened: waiting for approval, deposits only, request queued', v_count = 1);
  SELECT COUNT(*) INTO v_count FROM v_pending_approvals WHERE target_ref = v_acc1 AND target_kind = 'ACCOUNT' AND requested_by = v_cso;
  check_that('it appears in the checkers'' queue (v_pending_approvals)', v_count = 1);
  rejects('the officer approving the account they opened', 'BEGIN pkg_account.approve_account(' || q(v_acc1) || '); END;', 'ORA-20013');
  v_acc2 := pkg_account.open_account(v_c2, 'T9-SAV');   -- Ama: KYC deferred
  v_acc3 := pkg_account.open_account(v_c3, 'T9-SAV');   -- Yaw: never verified
  v_acc4 := pkg_account.open_account(v_c1, 'T9-SAV');   -- to be rejected
  act_as(v_sup);
  accepts('supervisor approves Kofi''s account', 'BEGIN pkg_account.approve_account(' || q(v_acc1) || '); END;');
  check_that('ACTIVE with debits on (every holder verified)', status_of(v_acc1) = 'ACTIVE' AND debits_on(v_acc1));
  accepts('supervisor approves Ama''s account (KYC deferred)', 'BEGIN pkg_account.approve_account(' || q(v_acc2) || '); END;');
  check_that('ACTIVE but deposits only', status_of(v_acc2) = 'ACTIVE' AND NOT debits_on(v_acc2));
  rejects('approving an account whose holder was never verified', 'BEGIN pkg_account.approve_account(' || q(v_acc3) || '); END;', 'ORA-20026');
  rejects('rejecting without a reason', 'BEGIN pkg_account.reject_account(' || q(v_acc4) || ', NULL); END;', 'ORA-20017');
  accepts('supervisor rejects an opening', 'BEGIN pkg_account.reject_account(' || q(v_acc4) || ', ''Duplicate request''); END;');
  -- (EXISTS works only inside SQL, so count first.)
  SELECT COUNT(*) INTO v_count FROM v_pending_approvals WHERE target_ref = v_acc4;
  check_that('REJECTED, and no longer in the queue', status_of(v_acc4) = 'REJECTED' AND v_count = 0);

  -- -------------------------------------------------------------- holders
  act_as(v_cso);
  rejects('a joint holder on a SOLE account',
    'BEGIN pkg_account.add_holder(' || q(v_acc1) || ', ' || q(v_c1) || ', ''JOINT''); END;', 'ORA-20022');
  rejects('an unverified signatory on an account that allows debits',
    'BEGIN pkg_account.add_holder(' || q(v_acc1) || ', ' || q(v_c2) || ', ''SIGNATORY''); END;', 'ORA-20026');
  v_joint := pkg_account.open_account(v_c1, 'T9-SAV', 'EITHER_TO_SIGN');
  accepts('Ama added as joint holder of a new joint account',
    'BEGIN pkg_account.add_holder(' || q(v_joint) || ', ' || q(v_c2) || ', ''JOINT''); END;');
  accepts('the joint account satisfies the COMMIT-time rules', 'SET CONSTRAINTS ALL IMMEDIATE');
  defer_again;

  -- ------------------------------- KYC switches debits on, review switches them off
  capture_kyc_data(v_c2);
  v_num := pkg_customer.record_verification(v_c2, 'ONBOARDING', 'FACE', 'MATCH', 'NIA-REF-0002');
  pkg_customer.record_screening(v_c2, 'CLEAR');
  pkg_customer.submit_kyc(v_c2);
  act_as(v_sup);
  pkg_account.approve_account(v_joint);
  check_that('joint account approved deposits-only while Ama is DEFERRED', NOT debits_on(v_joint));
  pkg_customer.approve_kyc(v_c2, 'MEDIUM');
  check_that('approving Ama''s KYC switches debits on, on her account and the joint one',
             kyc_of(v_c2) = 'VERIFIED' AND debits_on(v_acc2) AND debits_on(v_joint));
  SELECT COUNT(*) INTO v_count FROM customers
   WHERE customer_no = v_c2 AND kyc_deferral_until IS NULL AND next_kyc_review_on = ADD_MONTHS(TRUNC(SYSDATE), 24);
  check_that('the deferral date is cleared; next review in 24 months', v_count = 1);
  accepts('the periodic review of Kofi falls due', 'BEGIN pkg_customer.mark_review_due(' || q(v_c1) || '); END;');
  check_that('debits off on Kofi''s account and on the joint account; KYC REVIEW_DUE',
             kyc_of(v_c1) = 'REVIEW_DUE' AND NOT debits_on(v_acc1) AND NOT debits_on(v_joint) AND debits_on(v_acc2));

  -- ------------------------------------------------- PEP and rejection
  act_as(v_cso);
  v_pep := register('register a politically exposed person', 'GHA-000000908-1',
                    'p_is_pep => TRUE, p_pep_details => ''Member of Parliament''');
  capture_kyc_data(v_pep);
  v_num := pkg_customer.record_verification(v_pep, 'ONBOARDING', 'FACE', 'MATCH', 'NIA-REF-0003');
  pkg_customer.record_screening(v_pep, 'POTENTIAL_MATCH');
  rejects('submitting while sanctions screening is not CLEAR', 'BEGIN pkg_customer.submit_kyc(' || q(v_pep) || '); END;', 'ORA-20021.*sanctions');
  pkg_customer.record_screening(v_pep, 'CLEAR');
  pkg_customer.submit_kyc(v_pep);
  act_as(v_sup);
  rejects('rating a politically exposed person MEDIUM', 'BEGIN pkg_customer.approve_kyc(' || q(v_pep) || ', ''MEDIUM''); END;', 'ORA-20022');
  accepts('the PEP approved as HIGH risk', 'BEGIN pkg_customer.approve_kyc(' || q(v_pep) || ', ''HIGH''); END;');
  SELECT COUNT(*) INTO v_count FROM customers
   WHERE customer_no = v_pep AND due_diligence_level = 'ENHANCED' AND next_kyc_review_on = ADD_MONTHS(TRUNC(SYSDATE), 12);
  check_that('enhanced due diligence and a 12-month review for the PEP', v_count = 1);
  act_as(v_cso);
  capture_kyc_data(v_c3);
  v_num := pkg_customer.record_verification(v_c3, 'ONBOARDING', 'FACE', 'MATCH', 'NIA-REF-0004');
  pkg_customer.record_screening(v_c3, 'CLEAR');
  pkg_customer.submit_kyc(v_c3);
  act_as(v_sup);
  accepts('supervisor rejects Yaw''s KYC', 'BEGIN pkg_customer.reject_kyc(' || q(v_c3) || ', ''Address could not be confirmed''); END;');
  check_that('KYC REJECTED; Yaw cannot open new accounts', kyc_of(v_c3) = 'REJECTED');
  act_as(v_cso);
  rejects('opening an account for a rejected customer',
    'DECLARE r VARCHAR2(13); BEGIN r := pkg_account.open_account(' || q(v_c3) || ', ''T9-SAV''); END;', 'ORA-20022');

  -- ------------------------------------------------------------ the record
  SELECT COUNT(*) INTO v_count FROM audit_trail
   WHERE entity_id IN (v_c1, v_c2, v_acc1, v_acc2)
     AND event_type IN ('CUSTOMER_REGISTERED', 'IDENTITY_VERIFIED', 'KYC_APPROVED', 'ACCOUNT_OPENED', 'ACCOUNT_APPROVED', 'KYC_REVIEW_DUE');
  check_that('audit trail holds the onboarding events (' || v_count || ')', v_count >= 10);
  SELECT COUNT(*) INTO v_count FROM bank_parameters WHERE param_name LIKE 'KYC\_%' ESCAPE '\' OR param_name = 'MIN_CUSTOMER_AGE';
  check_that('policy values come from bank_parameters (5 rows)', v_count = 5);
  accepts('every COMMIT-time rule holds (checked now)', 'SET CONSTRAINTS ALL IMMEDIATE');
  defer_again;
  SELECT COUNT(*) INTO v_count FROM dba_objects WHERE owner = 'WELBANK' AND status = 'INVALID';
  check_that('no invalid objects in the schema', v_count = 0);

  DBMS_OUTPUT.PUT_LINE('RESULT: ' || passed || ' passed, ' || failed || ' failed');
  ROLLBACK;
END;
/
