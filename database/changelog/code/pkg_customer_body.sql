--liquibase formatted sql

--changeset elomwarren:code-pkg-customer-body runOnChange:true endDelimiter:/
CREATE OR REPLACE PACKAGE BODY pkg_customer AS

  c_max_file_bytes CONSTANT PLS_INTEGER := 2097152;   -- 2 MB, as customer_files_size_ck

  -- ------------------------------------------------------------------ helpers

  -- The customer with this number, locked (two officers editing the same
  -- customer take turns).
  FUNCTION lock_customer (p_customer_no IN VARCHAR2) RETURN customers%ROWTYPE IS
    c customers%ROWTYPE;
  BEGIN
    SELECT * INTO c FROM customers WHERE customer_no = p_customer_no FOR UPDATE;
    RETURN c;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      RAISE_APPLICATION_ERROR(pkg_errors.c_customer_not_found, 'Customer ' || p_customer_no || ' does not exist');
  END lock_customer;

  -- The PENDING KYC approval request of a customer, locked.
  FUNCTION kyc_request (p_customer_id IN NUMBER) RETURN approval_requests%ROWTYPE IS
    r approval_requests%ROWTYPE;
  BEGIN
    SELECT * INTO r
      FROM approval_requests
     WHERE request_type = 'KYC_APPROVAL' AND customer_id = p_customer_id AND status = 'PENDING'
       FOR UPDATE;
    RETURN r;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      RAISE_APPLICATION_ERROR(pkg_errors.c_request_not_found, 'No KYC waiting for approval for this customer');
  END kyc_request;

  PROCEDURE check_checker (p_me IN NUMBER, p_maker IN NUMBER) IS
  BEGIN
    IF p_me = p_maker THEN
      RAISE_APPLICATION_ERROR(pkg_errors.c_own_approval, 'You cannot approve or reject a KYC you submitted (maker-checker)');
    END IF;
  END check_checker;

  -- Which identity document a customer may be identified with (Ghana Card
  -- note s.2, s.23.2, s.23.4): the NIA card matching their nationality; a
  -- passport only for a Ghanaian living abroad; a diplomatic passport.
  PROCEDURE check_document (p_doc_type IN VARCHAR2, p_nationality IN VARCHAR2, p_residence IN VARCHAR2) IS
    v_ok BOOLEAN;
  BEGIN
    v_ok := CASE p_doc_type
              WHEN 'GHANA_CARD'          THEN p_nationality = 'GHA'
              WHEN 'NON_CITIZEN_CARD'    THEN p_nationality <> 'GHA'
              WHEN 'REFUGEE_CARD'        THEN p_nationality <> 'GHA'
              WHEN 'PASSPORT'            THEN p_nationality = 'GHA' AND p_residence <> 'GHA'
              WHEN 'DIPLOMATIC_PASSPORT' THEN TRUE
              ELSE FALSE
            END;
    IF NOT v_ok THEN
      RAISE_APPLICATION_ERROR(pkg_errors.c_method_not_allowed,
        'A ' || p_doc_type || ' cannot identify a ' || p_nationality || ' national living in ' || p_residence
        || ' (Ghana Card for Ghanaians, Non-Citizen or Refugee Card for others, passport only for Ghanaians abroad)');
    END IF;
  END check_document;

  -- ----------------------------------------------------------- registration

  FUNCTION register_customer (
    p_first_name              IN VARCHAR2,
    p_last_name               IN VARCHAR2,
    p_sex                     IN VARCHAR2,
    p_date_of_birth           IN DATE,
    p_nationality             IN VARCHAR2,
    p_doc_type                IN VARCHAR2,
    p_doc_number              IN VARCHAR2,
    p_employment_status       IN VARCHAR2,
    p_income_band             IN VARCHAR2,
    p_source_of_funds         IN VARCHAR2,
    p_account_purpose         IN VARCHAR2,
    p_expected_monthly_volume IN NUMBER,
    p_data_consent            IN BOOLEAN,
    p_middle_name             IN VARCHAR2 DEFAULT NULL,
    p_title                   IN VARCHAR2 DEFAULT NULL,
    p_place_of_birth          IN VARCHAR2 DEFAULT NULL,
    p_occupation              IN VARCHAR2 DEFAULT NULL,
    p_employer_name           IN VARCHAR2 DEFAULT NULL,
    p_country_of_residence    IN VARCHAR2 DEFAULT 'GHA',
    p_doc_country             IN VARCHAR2 DEFAULT 'GHA',
    p_doc_expiry              IN DATE     DEFAULT NULL,
    p_is_pep                  IN BOOLEAN  DEFAULT FALSE,
    p_pep_details             IN VARCHAR2 DEFAULT NULL,
    p_marketing_consent       IN BOOLEAN  DEFAULT FALSE) RETURN VARCHAR2
  IS
    v_me  employees.employee_id%TYPE := pkg_session.employee_id;
    v_id  customers.customer_id%TYPE;
    v_no  customers.customer_no%TYPE;
  BEGIN
    IF p_data_consent IS NULL OR NOT p_data_consent THEN
      RAISE_APPLICATION_ERROR(pkg_errors.c_consent_required,
        'The customer must consent to the processing of their personal data (Data Protection Act, 2012)');
    END IF;
    IF p_date_of_birth IS NULL
       OR MONTHS_BETWEEN(TRUNC(SYSDATE), p_date_of_birth) < 12 * pkg_params.num('MIN_CUSTOMER_AGE') THEN
      RAISE_APPLICATION_ERROR(pkg_errors.c_underage,
        'A customer must be at least ' || pkg_params.num('MIN_CUSTOMER_AGE') || ' years old');
    END IF;
    check_document(p_doc_type, p_nationality, p_country_of_residence);

    INSERT INTO customers (title, first_name, middle_name, last_name, sex, date_of_birth, place_of_birth, nationality,
                           country_of_residence, home_branch_id, relationship_officer_id, employment_status, occupation,
                           employer_name, income_band, source_of_funds, account_purpose, expected_monthly_volume,
                           is_pep, pep_details, due_diligence_level, data_consent_at, marketing_consent)
    VALUES (p_title, p_first_name, p_middle_name, p_last_name, p_sex, p_date_of_birth, p_place_of_birth, p_nationality,
            p_country_of_residence, pkg_session.branch_id, v_me, p_employment_status, p_occupation,
            p_employer_name, p_income_band, p_source_of_funds, p_account_purpose, p_expected_monthly_volume,
            NVL(p_is_pep, FALSE), p_pep_details, CASE WHEN p_is_pep THEN 'ENHANCED' ELSE 'STANDARD' END,
            SYSTIMESTAMP, NVL(p_marketing_consent, FALSE))
    RETURNING customer_id, customer_no INTO v_id, v_no;

    INSERT INTO identity_documents (customer_id, doc_type, doc_number, issuing_country, expiry_date, is_primary)
    VALUES (v_id, p_doc_type, p_doc_number, p_doc_country, p_doc_expiry, TRUE);

    pkg_audit.log_event('CUSTOMER_REGISTERED', 'CUSTOMERS', v_no, NULL,
      JSON_OBJECT('doc_type' VALUE p_doc_type, 'nationality' VALUE p_nationality RETURNING VARCHAR2(4000)));
    RETURN v_no;
  END register_customer;

  -- ------------------------------------------------- secondary data and files

  PROCEDURE add_address (
    p_customer_no     IN VARCHAR2,
    p_address_type    IN VARCHAR2,
    p_address_line    IN VARCHAR2,
    p_town            IN VARCHAR2,
    p_region_id       IN NUMBER   DEFAULT NULL,
    p_country         IN VARCHAR2 DEFAULT 'GHA',
    p_digital_address IN VARCHAR2 DEFAULT NULL,
    p_landmark        IN VARCHAR2 DEFAULT NULL,
    p_resident_since  IN DATE     DEFAULT NULL,
    p_proof_type      IN VARCHAR2 DEFAULT NULL,
    p_proof_date      IN DATE     DEFAULT NULL)
  IS
    v_me employees.employee_id%TYPE := pkg_session.employee_id;
    c    customers%ROWTYPE := lock_customer(p_customer_no);
  BEGIN
    UPDATE customer_addresses SET is_current = FALSE
     WHERE customer_id = c.customer_id AND address_type = p_address_type AND is_current;
    INSERT INTO customer_addresses (customer_id, address_type, address_line, town, region_id, country_code, digital_address,
                                    landmark, resident_since, proof_type, proof_date)
    VALUES (c.customer_id, p_address_type, p_address_line, p_town, p_region_id, p_country, p_digital_address,
            p_landmark, p_resident_since, p_proof_type, p_proof_date);
    pkg_audit.log_event('ADDRESS_ADDED', 'CUSTOMERS', p_customer_no, NULL,
      JSON_OBJECT('type' VALUE p_address_type, 'town' VALUE p_town RETURNING VARCHAR2(4000)));
  END add_address;

  PROCEDURE add_contact (
    p_customer_no  IN VARCHAR2,
    p_contact_type IN VARCHAR2,
    p_value        IN VARCHAR2,
    p_is_primary   IN BOOLEAN DEFAULT FALSE)
  IS
    v_me employees.employee_id%TYPE := pkg_session.employee_id;
    c    customers%ROWTYPE := lock_customer(p_customer_no);
  BEGIN
    IF p_is_primary THEN
      -- One primary phone and one primary e-mail (customer_contacts_primary_ux).
      UPDATE customer_contacts SET is_primary = FALSE
       WHERE customer_id = c.customer_id AND is_primary
         AND ((p_contact_type = 'EMAIL' AND contact_type = 'EMAIL') OR (p_contact_type <> 'EMAIL' AND contact_type <> 'EMAIL'));
    END IF;
    INSERT INTO customer_contacts (customer_id, contact_type, phone, email, is_primary)
    VALUES (c.customer_id, p_contact_type,
            CASE WHEN p_contact_type <> 'EMAIL' THEN p_value END,
            CASE WHEN p_contact_type = 'EMAIL' THEN p_value END,
            NVL(p_is_primary, FALSE));
    pkg_audit.log_event('CONTACT_ADDED', 'CUSTOMERS', p_customer_no, NULL,
      JSON_OBJECT('type' VALUE p_contact_type RETURNING VARCHAR2(4000)));
  END add_contact;

  PROCEDURE add_next_of_kin (
    p_customer_no  IN VARCHAR2,
    p_full_name    IN VARCHAR2,
    p_relationship IN VARCHAR2,
    p_phone        IN VARCHAR2,
    p_address      IN VARCHAR2 DEFAULT NULL)
  IS
    v_me employees.employee_id%TYPE := pkg_session.employee_id;
    c    customers%ROWTYPE := lock_customer(p_customer_no);
  BEGIN
    INSERT INTO next_of_kin (customer_id, full_name, relationship, phone, address)
    VALUES (c.customer_id, p_full_name, p_relationship, p_phone, p_address);
    pkg_audit.log_event('NEXT_OF_KIN_ADDED', 'CUSTOMERS', p_customer_no);
  END add_next_of_kin;

  PROCEDURE add_file (
    p_customer_no IN VARCHAR2,
    p_file_kind   IN VARCHAR2,
    p_mime_type   IN VARCHAR2,
    p_content     IN BLOB,
    p_sha256      IN VARCHAR2)
  IS
    v_me   employees.employee_id%TYPE := pkg_session.employee_id;
    c      customers%ROWTYPE := lock_customer(p_customer_no);
    v_size NUMBER := NVL(DBMS_LOB.GETLENGTH(p_content), 0);
    v_head RAW(12);
    v_ok   BOOLEAN;
  BEGIN
    -- The size is measured, never taken from the caller.
    IF v_size < 12 OR v_size > c_max_file_bytes THEN
      RAISE_APPLICATION_ERROR(pkg_errors.c_invalid_file,
        'The file must be an image of at most 2 MB (got ' || v_size || ' bytes)');
    END IF;
    -- Check the "magic number": the first bytes every file of a type starts
    -- with. A renamed text or PDF file claiming to be a PNG is refused.
    v_head := DBMS_LOB.SUBSTR(p_content, 12, 1);
    v_ok := CASE p_mime_type
              WHEN 'image/jpeg' THEN UTL_RAW.SUBSTR(v_head, 1, 3) = HEXTORAW('FFD8FF')
              WHEN 'image/png'  THEN UTL_RAW.SUBSTR(v_head, 1, 8) = HEXTORAW('89504E470D0A1A0A')
              WHEN 'image/webp' THEN UTL_RAW.SUBSTR(v_head, 1, 4) = HEXTORAW('52494646')       -- "RIFF"
                                 AND UTL_RAW.SUBSTR(v_head, 9, 4) = HEXTORAW('57454250')       -- "WEBP"
              ELSE FALSE
            END;
    IF NOT v_ok THEN
      RAISE_APPLICATION_ERROR(pkg_errors.c_invalid_file, 'The content is not a ' || p_mime_type || ' image');
    END IF;

    UPDATE customer_files SET is_current = FALSE
     WHERE customer_id = c.customer_id AND file_kind = p_file_kind AND is_current;
    INSERT INTO customer_files (customer_id, file_kind, mime_type, byte_size, sha256, content, captured_by)
    VALUES (c.customer_id, p_file_kind, p_mime_type, v_size, LOWER(p_sha256), p_content, v_me);
    -- The audit records the fingerprint, never the picture.
    pkg_audit.log_event('FILE_ADDED', 'CUSTOMERS', p_customer_no, NULL,
      JSON_OBJECT('kind' VALUE p_file_kind, 'bytes' VALUE v_size, 'sha256' VALUE LOWER(p_sha256) RETURNING VARCHAR2(4000)));
  END add_file;

  -- -------------------------------------------------------- verification

  FUNCTION record_verification (
    p_customer_no   IN VARCHAR2,
    p_purpose       IN VARCHAR2,
    p_method        IN VARCHAR2,
    p_result        IN VARCHAR2,
    p_nia_reference IN VARCHAR2 DEFAULT NULL,
    p_error_code    IN VARCHAR2 DEFAULT NULL,
    p_nia_data      IN VARCHAR2 DEFAULT NULL,
    p_is_simulated  IN BOOLEAN  DEFAULT TRUE) RETURN NUMBER
  IS
    v_me  employees.employee_id%TYPE := pkg_session.employee_id;
    c     customers%ROWTYPE := lock_customer(p_customer_no);
    d     identity_documents%ROWTYPE;
    v_id  identity_verifications.verification_id%TYPE;
  BEGIN
    SELECT * INTO d FROM identity_documents WHERE customer_id = c.customer_id AND is_primary;

    -- NIA cards are verified biometrically, never by looking at them (L.I. 2111
    -- as amended in 2026); passports are checked manually.
    IF d.doc_type IN ('GHANA_CARD', 'NON_CITIZEN_CARD', 'REFUGEE_CARD') AND p_method = 'MANUAL_DOCUMENT' THEN
      RAISE_APPLICATION_ERROR(pkg_errors.c_method_not_allowed,
        'A ' || d.doc_type || ' can only be verified biometrically through NIA, not by inspection (L.I. 2111)');
    ELSIF d.doc_type IN ('PASSPORT', 'DIPLOMATIC_PASSPORT') AND p_method <> 'MANUAL_DOCUMENT' THEN
      RAISE_APPLICATION_ERROR(pkg_errors.c_method_not_allowed, 'A passport is checked manually (MANUAL_DOCUMENT), not through NIA');
    END IF;

    INSERT INTO identity_verifications (customer_id, document_id, purpose, method, result, nia_reference, error_code,
                                        is_simulated, performed_by)
    VALUES (c.customer_id, d.document_id, p_purpose, p_method, p_result, p_nia_reference, p_error_code,
            NVL(p_is_simulated, TRUE), v_me)
    RETURNING verification_id INTO v_id;

    IF p_result = 'MATCH' AND p_nia_data IS NOT NULL THEN
      -- Primary data comes from NIA (Ghana Card note s.2.3): it replaces what
      -- staff typed. Keys NIA did not send leave the column as it was.
      UPDATE customers
         SET first_name         = NVL(JSON_VALUE(p_nia_data, '$.first_name'), first_name),
             middle_name        = NVL(JSON_VALUE(p_nia_data, '$.middle_name'), middle_name),
             last_name          = NVL(JSON_VALUE(p_nia_data, '$.last_name'), last_name),
             previous_names     = NVL(JSON_VALUE(p_nia_data, '$.previous_names'), previous_names),
             sex                = NVL(JSON_VALUE(p_nia_data, '$.sex'), sex),
             date_of_birth      = NVL(JSON_VALUE(p_nia_data, '$.date_of_birth' RETURNING DATE), date_of_birth),
             nationality        = NVL(JSON_VALUE(p_nia_data, '$.nationality'), nationality),
             nia_last_synced_at = SYSTIMESTAMP
       WHERE customer_id = c.customer_id;
    ELSIF p_purpose = 'ONBOARDING' AND p_result IN ('NO_MATCH', 'FAILED') AND c.kyc_status = 'PENDING_VERIFICATION' THEN
      -- Failed onboarding check: deposits only, and a fixed time to fix the
      -- records. A later failure does not restart the clock.
      UPDATE customers
         SET kyc_status = 'DEFERRED', kyc_deferral_until = TRUNC(SYSDATE) + pkg_params.num('KYC_DEFERRAL_DAYS')
       WHERE customer_id = c.customer_id;
    END IF;

    pkg_audit.log_event('IDENTITY_VERIFIED', 'CUSTOMERS', p_customer_no, NULL,
      JSON_OBJECT('purpose' VALUE p_purpose, 'method' VALUE p_method, 'result' VALUE p_result,
                  'verification_id' VALUE v_id RETURNING VARCHAR2(4000)));
    RETURN v_id;
  END record_verification;

  PROCEDURE record_screening (p_customer_no IN VARCHAR2, p_sanctions_status IN VARCHAR2) IS
    v_me employees.employee_id%TYPE := pkg_session.employee_id;
    c    customers%ROWTYPE := lock_customer(p_customer_no);
  BEGIN
    UPDATE customers SET sanctions_status = p_sanctions_status WHERE customer_id = c.customer_id;
    pkg_audit.log_event('SANCTIONS_SCREENED', 'CUSTOMERS', p_customer_no,
      JSON_OBJECT('sanctions_status' VALUE c.sanctions_status RETURNING VARCHAR2(4000)),
      JSON_OBJECT('sanctions_status' VALUE p_sanctions_status RETURNING VARCHAR2(4000)));
  END record_screening;

  -- -------------------------------------------------------------- KYC

  FUNCTION kyc_missing (p_customer_no IN VARCHAR2) RETURN VARCHAR2 IS
    c         customers%ROWTYPE;
    v_missing VARCHAR2(400);
    v_result  identity_verifications.result%TYPE;
    v_count   PLS_INTEGER;

    -- (Variables must be declared before any nested subprogram.)
    PROCEDURE add_item (p_item IN VARCHAR2) IS
    BEGIN
      v_missing := v_missing || CASE WHEN v_missing IS NOT NULL THEN ', ' END || p_item;
    END add_item;
  BEGIN
    BEGIN
      SELECT * INTO c FROM customers WHERE customer_no = p_customer_no;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        RAISE_APPLICATION_ERROR(pkg_errors.c_customer_not_found, 'Customer ' || p_customer_no || ' does not exist');
    END;

    -- The latest verification decides (KEEP ... DENSE_RANK LAST: the result
    -- of the row with the highest performed_at).
    SELECT MAX(result) KEEP (DENSE_RANK LAST ORDER BY performed_at, verification_id) INTO v_result
      FROM identity_verifications WHERE customer_id = c.customer_id;
    IF v_result IS NULL OR v_result <> 'MATCH' THEN
      add_item('a successful identity verification (latest result: ' || NVL(v_result, 'none') || ')');
    END IF;

    SELECT COUNT(*) INTO v_count FROM customer_files WHERE customer_id = c.customer_id AND file_kind = 'PHOTO' AND is_current;
    IF v_count = 0 THEN add_item('live photo'); END IF;
    SELECT COUNT(*) INTO v_count FROM customer_files WHERE customer_id = c.customer_id AND file_kind = 'SIGNATURE' AND is_current;
    IF v_count = 0 THEN add_item('specimen signature'); END IF;
    SELECT COUNT(*) INTO v_count FROM customer_addresses WHERE customer_id = c.customer_id AND address_type = 'RESIDENTIAL' AND is_current;
    IF v_count = 0 THEN add_item('residential address'); END IF;
    SELECT COUNT(*) INTO v_count FROM customer_contacts WHERE customer_id = c.customer_id AND contact_type <> 'EMAIL' AND is_primary;
    IF v_count = 0 THEN add_item('primary phone'); END IF;
    IF c.sanctions_status <> 'CLEAR' THEN
      add_item('sanctions screening with a CLEAR result (now ' || c.sanctions_status || ')');
    END IF;
    RETURN v_missing;
  END kyc_missing;

  PROCEDURE submit_kyc (p_customer_no IN VARCHAR2) IS
    v_me      employees.employee_id%TYPE := pkg_session.employee_id;
    c         customers%ROWTYPE := lock_customer(p_customer_no);
    v_missing VARCHAR2(400);
  BEGIN
    IF c.kyc_status NOT IN ('PENDING_VERIFICATION', 'DEFERRED', 'REVIEW_DUE') THEN
      RAISE_APPLICATION_ERROR(pkg_errors.c_invalid_state, 'The KYC of ' || p_customer_no || ' is ' || c.kyc_status || ': nothing to submit');
    END IF;
    v_missing := kyc_missing(p_customer_no);
    IF v_missing IS NOT NULL THEN
      RAISE_APPLICATION_ERROR(pkg_errors.c_kyc_incomplete, 'The KYC of ' || p_customer_no || ' is incomplete. Missing: ' || v_missing);
    END IF;
    BEGIN
      INSERT INTO approval_requests (request_type, customer_id, reason, requested_by)
      VALUES ('KYC_APPROVAL', c.customer_id, 'KYC complete, please review', v_me);
    EXCEPTION
      WHEN DUP_VAL_ON_INDEX THEN   -- approval_requests_pending_ux
        RAISE_APPLICATION_ERROR(pkg_errors.c_invalid_state, 'The KYC of ' || p_customer_no || ' is already waiting for approval');
    END;
    pkg_audit.log_event('KYC_SUBMITTED', 'CUSTOMERS', p_customer_no);
  END submit_kyc;

  PROCEDURE approve_kyc (p_customer_no IN VARCHAR2, p_risk_rating IN VARCHAR2) IS
    v_me      employees.employee_id%TYPE := pkg_session.employee_id;
    c         customers%ROWTYPE := lock_customer(p_customer_no);
    r         approval_requests%ROWTYPE := kyc_request(c.customer_id);
    v_missing VARCHAR2(400);
  BEGIN
    check_checker(v_me, r.requested_by);
    IF p_risk_rating IS NULL OR p_risk_rating NOT IN ('LOW', 'MEDIUM', 'HIGH') THEN
      RAISE_APPLICATION_ERROR(pkg_errors.c_invalid_state, 'The risk rating must be LOW, MEDIUM or HIGH');
    END IF;
    IF c.is_pep AND p_risk_rating <> 'HIGH' THEN
      RAISE_APPLICATION_ERROR(pkg_errors.c_invalid_state, 'A politically exposed person is always rated HIGH');
    END IF;
    -- The file may have changed since it was submitted.
    v_missing := kyc_missing(p_customer_no);
    IF v_missing IS NOT NULL THEN
      RAISE_APPLICATION_ERROR(pkg_errors.c_kyc_incomplete, 'The KYC of ' || p_customer_no || ' is incomplete. Missing: ' || v_missing);
    END IF;

    UPDATE customers
       SET kyc_status          = 'VERIFIED',
           kyc_deferral_until  = NULL,
           kyc_approved_by     = v_me,
           kyc_approved_at     = SYSTIMESTAMP,
           risk_rating         = p_risk_rating,
           due_diligence_level = CASE WHEN is_pep OR p_risk_rating = 'HIGH' THEN 'ENHANCED' ELSE 'STANDARD' END,
           next_kyc_review_on  = ADD_MONTHS(TRUNC(SYSDATE), pkg_params.num('KYC_REVIEW_MONTHS_' || p_risk_rating)),
           status              = CASE WHEN status = 'PENDING_KYC' THEN 'ACTIVE' ELSE status END
     WHERE customer_id = c.customer_id;
    UPDATE approval_requests SET status = 'APPROVED', decided_by = v_me, decided_at = SYSTIMESTAMP
     WHERE request_id = r.request_id;
    -- Verified: debits can come on where every holder is now verified.
    pkg_account.refresh_debits(c.customer_id);
    pkg_audit.log_event('KYC_APPROVED', 'CUSTOMERS', p_customer_no,
      JSON_OBJECT('kyc_status' VALUE c.kyc_status RETURNING VARCHAR2(4000)),
      JSON_OBJECT('kyc_status' VALUE 'VERIFIED', 'risk_rating' VALUE p_risk_rating RETURNING VARCHAR2(4000)));
  END approve_kyc;

  PROCEDURE reject_kyc (p_customer_no IN VARCHAR2, p_reason IN VARCHAR2) IS
    v_me employees.employee_id%TYPE := pkg_session.employee_id;
    c    customers%ROWTYPE := lock_customer(p_customer_no);
    r    approval_requests%ROWTYPE := kyc_request(c.customer_id);
  BEGIN
    IF TRIM(p_reason) IS NULL THEN
      RAISE_APPLICATION_ERROR(pkg_errors.c_reason_required, 'Give a reason');
    END IF;
    check_checker(v_me, r.requested_by);
    UPDATE customers SET kyc_status = 'REJECTED', kyc_deferral_until = NULL WHERE customer_id = c.customer_id;
    UPDATE approval_requests
       SET status = 'REJECTED', decided_by = v_me, decided_at = SYSTIMESTAMP, decision_note = SUBSTR(p_reason, 1, 400)
     WHERE request_id = r.request_id;
    pkg_audit.log_event('KYC_REJECTED', 'CUSTOMERS', p_customer_no,
      JSON_OBJECT('kyc_status' VALUE c.kyc_status RETURNING VARCHAR2(4000)),
      JSON_OBJECT('kyc_status' VALUE 'REJECTED', 'reason' VALUE p_reason RETURNING VARCHAR2(4000)));
  END reject_kyc;

  PROCEDURE mark_review_due (p_customer_no IN VARCHAR2) IS
    v_me employees.employee_id%TYPE := pkg_session.employee_id;
    c    customers%ROWTYPE := lock_customer(p_customer_no);
  BEGIN
    IF c.kyc_status <> 'VERIFIED' THEN
      RAISE_APPLICATION_ERROR(pkg_errors.c_invalid_state, 'The KYC of ' || p_customer_no || ' is ' || c.kyc_status || ', not VERIFIED');
    END IF;
    -- Debits off FIRST: the assertion accounts_debit_kyc_as refuses an
    -- unverified holder on an account that still allows debits.
    UPDATE accounts SET post_no_debit = TRUE
     WHERE post_no_debit = FALSE
       AND account_id IN (SELECT account_id FROM account_holders WHERE customer_id = c.customer_id);
    UPDATE customers SET kyc_status = 'REVIEW_DUE' WHERE customer_id = c.customer_id;
    pkg_audit.log_event('KYC_REVIEW_DUE', 'CUSTOMERS', p_customer_no, '{"kyc_status":"VERIFIED"}', '{"kyc_status":"REVIEW_DUE"}');
  END mark_review_due;

END pkg_customer;
/
--rollback DROP PACKAGE BODY pkg_customer
