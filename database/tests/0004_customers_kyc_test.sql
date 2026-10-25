-- =============================================================================
-- 0004_customers_kyc_test.sql — rules of employees, customers and KYC tables
-- (changelogs 0003 and 0004).
--
-- Run by database/tests/run_tests.sh as SYSDBA inside WELBANK. Everything runs
-- in one transaction that is rolled back at the end: no data is left behind.
-- =============================================================================
SET SERVEROUTPUT ON SIZE UNLIMITED FEEDBACK OFF LINESIZE 200
ALTER SESSION SET CURRENT_SCHEMA = welbank;

DECLARE
  passed PLS_INTEGER := 0;
  failed PLS_INTEGER := 0;
  v_region  NUMBER; v_branch NUMBER; v_dept NUMBER; v_job NUMBER;
  v_emp     NUMBER; v_cust   NUMBER; v_cust2 NUMBER; v_doc NUMBER;
  v_cust_no customers.customer_no%TYPE;
  v_text    VARCHAR2(400);
  v_count   PLS_INTEGER;
  -- A valid 1x1 transparent PNG (70 bytes), generated with Python's zlib/struct
  -- (signature + IHDR + IDAT + IEND chunks with correct CRCs). Its SHA-256 is
  -- computed below with STANDARD_HASH.
  c_png     CONSTANT RAW(100) := HEXTORAW('89504E470D0A1A0A0000000D49484452000000010000000108060000001F15C4890000000D49444154789C6360606060000000050001A5F645400000000049454E44AE426082');
  v_sha     VARCHAR2(64);

  PROCEDURE accepts(p_name VARCHAR2, p_sql VARCHAR2) IS
  BEGIN
    EXECUTE IMMEDIATE p_sql;
    passed := passed + 1;
    DBMS_OUTPUT.PUT_LINE('PASS  accepts  ' || p_name);
  EXCEPTION WHEN OTHERS THEN
    failed := failed + 1;
    DBMS_OUTPUT.PUT_LINE('FAIL  accepts  ' || p_name || '  -> ' || SQLERRM);
  END;

  PROCEDURE rejects(p_name VARCHAR2, p_sql VARCHAR2) IS
  BEGIN
    EXECUTE IMMEDIATE p_sql;
    failed := failed + 1;
    DBMS_OUTPUT.PUT_LINE('FAIL  rejects  ' || p_name || '  -> was accepted');
  EXCEPTION WHEN OTHERS THEN
    passed := passed + 1;
    DBMS_OUTPUT.PUT_LINE('PASS  rejects  ' || p_name);
  END;

  -- A plain true/false check on data.
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

  -- Builds an INSERT for customers with every required column; p_extra_cols /
  -- p_extra_vals add or override columns for a particular check.
  FUNCTION customer_sql(p_extra_cols VARCHAR2 DEFAULT NULL, p_extra_vals VARCHAR2 DEFAULT NULL) RETURN VARCHAR2 IS
  BEGIN
    RETURN 'INSERT INTO customers (first_name, last_name, sex, date_of_birth, nationality, home_branch_id, '
        || 'employment_status, income_band, source_of_funds, account_purpose, expected_monthly_volume, data_consent_at'
        || CASE WHEN p_extra_cols IS NOT NULL THEN ', ' || p_extra_cols END || ') VALUES ('
        || q'['Test', 'Customer', 'FEMALE', DATE '1990-05-01', 'ZZA', ]' || v_branch
        || q'[, 'EMPLOYED', '1K_5K', 'SALARY', 'SAVINGS', 2000, SYSTIMESTAMP]'
        || CASE WHEN p_extra_vals IS NOT NULL THEN ', ' || p_extra_vals END || ')';
  END;
BEGIN
  -- ---------------------------------------------------------------- fixtures
  INSERT INTO countries (country_code, country_name, nationality_name) VALUES ('ZZA', 'Testland', 'Testlander');
  INSERT INTO countries (country_code, country_name, nationality_name) VALUES ('ZZB', 'Otherland', 'Otherlander');
  MERGE INTO countries c USING (SELECT 'GHA' code FROM dual) s ON (c.country_code = s.code)
    WHEN NOT MATCHED THEN INSERT (country_code, country_name, nationality_name) VALUES ('GHA', 'Ghana', 'Ghanaian');
  INSERT INTO regions (region_name) VALUES ('Test region') RETURNING region_id INTO v_region;
  INSERT INTO branches (branch_code, branch_name, region_id, phone, opened_on)
    VALUES ('T-BR1', 'Test branch', v_region, '+233200000001', DATE '2020-01-01') RETURNING branch_id INTO v_branch;
  INSERT INTO departments (department_name) VALUES ('Test department') RETURNING department_id INTO v_dept;
  INSERT INTO jobs (job_title, department_id, min_salary, max_salary)
    VALUES ('Test teller', v_dept, 20000, 40000) RETURNING job_id INTO v_job;

  -- ---------------------------------------------------------------- employees
  INSERT INTO employees (first_name, last_name, sex, date_of_birth, nationality, work_email, phone,
                         job_id, branch_id, salary, hire_date, db_username)
  VALUES ('Ama', 'Tester', 'FEMALE', DATE '1992-03-04', 'ZZA', 'ama.tester@example.com', '+233200000010',
          v_job, v_branch, 30000, DATE '2021-06-01', 'T_AMATESTER')
  RETURNING employee_id INTO v_emp;
  check_that('employee inserted with an identity key', v_emp IS NOT NULL);

  rejects('employee with sex "F" (domain sex_d)',
    q'[INSERT INTO employees (first_name, last_name, sex, date_of_birth, nationality, work_email, phone, job_id, branch_id, salary, hire_date) VALUES ('A','B','F',DATE '1990-01-01','ZZA','a.b@example.com','+233200000011',]' || v_job || ',' || v_branch || q'[,30000,DATE '2021-01-01')]');
  rejects('second employee with the same work e-mail',
    q'[INSERT INTO employees (first_name, last_name, sex, date_of_birth, nationality, work_email, phone, job_id, branch_id, salary, hire_date) VALUES ('A','B','MALE',DATE '1990-01-01','ZZA','ama.tester@example.com','+233200000012',]' || v_job || ',' || v_branch || q'[,30000,DATE '2021-01-01')]');
  rejects('database username in lower case',
    'UPDATE employees SET db_username = ''t_lower'' WHERE employee_id = ' || v_emp);
  rejects('TERMINATED without a termination date',
    'UPDATE employees SET status = ''TERMINATED'' WHERE employee_id = ' || v_emp);
  rejects('termination date before hire date',
    'UPDATE employees SET status = ''TERMINATED'', termination_date = DATE ''2020-01-01'' WHERE employee_id = ' || v_emp);
  rejects('employee as their own manager',
    'UPDATE employees SET manager_id = employee_id WHERE employee_id = ' || v_emp);
  UPDATE employees SET phone = '+233200000099' WHERE employee_id = v_emp;
  SELECT updated_by INTO v_text FROM employees WHERE employee_id = v_emp;
  check_that('update trigger filled updated_by (' || v_text || ')', v_text IS NOT NULL);

  -- ---------------------------------------------------------------- customers
  EXECUTE IMMEDIATE customer_sql || ' RETURNING customer_id, customer_no INTO :1, :2' RETURNING INTO v_cust, v_cust_no;
  check_that('customer number generated from the sequence (' || v_cust_no || ')', REGEXP_LIKE(v_cust_no, '^CUS[0-9]{8}$'));
  EXECUTE IMMEDIATE customer_sql || ' RETURNING customer_id INTO :1' RETURNING INTO v_cust2;

  rejects('customer from an unknown country',      REPLACE(customer_sql, q'['ZZA']', q'['XXX']'));
  rejects('customer without data-processing consent', REPLACE(customer_sql, 'SYSTIMESTAMP', 'NULL'));
  rejects('income band not in the list',           REPLACE(customer_sql, q'['1K_5K']', q'['LOTS']'));
  rejects('PEP without PEP details',               customer_sql('is_pep, due_diligence_level', q'[TRUE, 'ENHANCED']'));
  rejects('PEP with only standard due diligence',  customer_sql('is_pep, pep_details', q'[TRUE, 'Member of Parliament']'));
  accepts('PEP with details and enhanced due diligence',
                                                  customer_sql('is_pep, pep_details, due_diligence_level', q'[TRUE, 'Member of Parliament', 'ENHANCED']'));
  rejects('DEFERRED without the 90-day end date',  customer_sql('kyc_status', q'['DEFERRED']'));
  accepts('DEFERRED with the 90-day end date',     customer_sql('kyc_status, kyc_deferral_until', q'['DEFERRED', SYSDATE + 90]'));
  rejects('VERIFIED without approver and risk rating', customer_sql('kyc_status', q'['VERIFIED']'));
  accepts('VERIFIED with approver, time and risk rating',
                                                  customer_sql('kyc_status, kyc_approved_by, kyc_approved_at, risk_rating', q'['VERIFIED', ]' || v_emp || q'[, SYSTIMESTAMP, 'LOW']'));

  -- ---------------------------------------------------------- identity documents
  INSERT INTO identity_documents (customer_id, doc_type, doc_number, issuing_country, expiry_date, is_primary)
    VALUES (v_cust, 'GHANA_CARD', 'GHA-999999991-1', 'GHA', DATE '2034-01-01', TRUE) RETURNING document_id INTO v_doc;
  check_that('Ghana Card stored as the primary document', v_doc IS NOT NULL);
  rejects('Ghana Card PIN in the wrong format',
    'INSERT INTO identity_documents (customer_id, doc_type, doc_number, issuing_country) VALUES (' || v_cust2 || q'[, 'GHANA_CARD', 'GHA-12345-1', 'GHA')]');
  rejects('Ghana Card "issued" by another country',
    'INSERT INTO identity_documents (customer_id, doc_type, doc_number, issuing_country) VALUES (' || v_cust2 || q'[, 'GHANA_CARD', 'GHA-999999992-2', 'ZZB')]');
  rejects('the same Ghana Card for a second customer',
    'INSERT INTO identity_documents (customer_id, doc_type, doc_number, issuing_country) VALUES (' || v_cust2 || q'[, 'GHANA_CARD', 'GHA-999999991-1', 'GHA')]');
  rejects('a second PRIMARY document for one customer',
    'INSERT INTO identity_documents (customer_id, doc_type, doc_number, issuing_country, is_primary) VALUES (' || v_cust || q'[, 'PASSPORT', 'P1234567', 'GHA', TRUE)]');
  accepts('an extra, non-primary passport',
    'INSERT INTO identity_documents (customer_id, doc_type, doc_number, issuing_country) VALUES (' || v_cust || q'[, 'PASSPORT', 'P1234567', 'GHA')]');
  rejects('a "driver licence" (not accepted any more)',
    'INSERT INTO identity_documents (customer_id, doc_type, doc_number, issuing_country) VALUES (' || v_cust2 || q'[, 'DRIVER_LICENCE', 'DL1', 'GHA')]');

  -- ------------------------------------------------------ identity verifications
  accepts('MATCH with the NIA reference',
    'INSERT INTO identity_verifications (customer_id, document_id, purpose, method, result, nia_reference, performed_by) VALUES ('
    || v_cust || ',' || v_doc || q'[, 'ONBOARDING', 'FACE', 'MATCH', 'SIM-NIA-0001', ]' || v_emp || ')');
  rejects('MATCH without an NIA reference',
    'INSERT INTO identity_verifications (customer_id, document_id, purpose, method, result, performed_by) VALUES ('
    || v_cust || ',' || v_doc || q'[, 'ONBOARDING', 'FACE', 'MATCH', ]' || v_emp || ')');
  rejects('FAILED without an error code',
    'INSERT INTO identity_verifications (customer_id, document_id, purpose, method, result, performed_by) VALUES ('
    || v_cust || ',' || v_doc || q'[, 'ONBOARDING', 'SINGLE_FINGER', 'FAILED', ]' || v_emp || ')');
  rejects('verification method "VISUAL_INSPECTION" (unlawful)',
    'INSERT INTO identity_verifications (customer_id, document_id, purpose, method, result, nia_reference, performed_by) VALUES ('
    || v_cust || ',' || v_doc || q'[, 'ONBOARDING', 'VISUAL_INSPECTION', 'MATCH', 'X', ]' || v_emp || ')');

  -- ------------------------------------------------------------------ addresses
  rejects('residential address in Ghana without a digital address',
    'INSERT INTO customer_addresses (customer_id, address_type, address_line, town, region_id) VALUES (' || v_cust || q'[, 'RESIDENTIAL', 'House 12', 'Accra', ]' || v_region || ')');
  rejects('address in Ghana without a region',
    'INSERT INTO customer_addresses (customer_id, address_type, address_line, town, digital_address) VALUES (' || v_cust || q'[, 'RESIDENTIAL', 'House 12', 'Accra', 'GA-123-4567')]');
  accepts('residential address with region and digital address',
    'INSERT INTO customer_addresses (customer_id, address_type, address_line, town, region_id, digital_address, landmark) VALUES (' || v_cust || q'[, 'RESIDENTIAL', 'House 12', 'Accra', ]' || v_region || q'[, 'GA-123-4567', 'Behind the church')]');
  rejects('a second CURRENT residential address',
    'INSERT INTO customer_addresses (customer_id, address_type, address_line, town, region_id, digital_address) VALUES (' || v_cust || q'[, 'RESIDENTIAL', 'House 99', 'Accra', ]' || v_region || q'[, 'GA-123-9999')]');
  accepts('new address after retiring the old one',
    'BEGIN UPDATE customer_addresses SET is_current = FALSE WHERE customer_id = ' || v_cust || '; '
    || 'INSERT INTO customer_addresses (customer_id, address_type, address_line, town, region_id, digital_address) VALUES (' || v_cust || q'[, 'RESIDENTIAL', 'House 99', 'Accra', ]' || v_region || q'[, 'GA-123-9999'); END;]');
  accepts('foreign postal address (no region needed)',
    'INSERT INTO customer_addresses (customer_id, address_type, address_line, town, country_code) VALUES (' || v_cust || q'[, 'POSTAL', '1 Main St', 'Otherville', 'ZZB')]');
  rejects('proof of address without its date',
    'INSERT INTO customer_addresses (customer_id, address_type, address_line, town, country_code, proof_type) VALUES (' || v_cust2 || q'[, 'POSTAL', '2 Main St', 'Otherville', 'ZZB', 'UTILITY_BILL')]');

  -- ------------------------------------------------------------------- contacts
  accepts('primary mobile number',
    'INSERT INTO customer_contacts (customer_id, contact_type, phone, is_primary) VALUES (' || v_cust || q'[, 'MOBILE', '+233240000001', TRUE)]');
  accepts('primary e-mail alongside the primary phone',
    'INSERT INTO customer_contacts (customer_id, contact_type, email, is_primary) VALUES (' || v_cust || q'[, 'EMAIL', 'test.customer@example.com', TRUE)]');
  rejects('a second primary phone',
    'INSERT INTO customer_contacts (customer_id, contact_type, phone, is_primary) VALUES (' || v_cust || q'[, 'WORK', '+233240000002', TRUE)]');
  rejects('an EMAIL row holding a phone number',
    'INSERT INTO customer_contacts (customer_id, contact_type, phone) VALUES (' || v_cust || q'[, 'EMAIL', '+233240000003')]');

  -- ---------------------------------------------------------------- next of kin
  accepts('next of kin',
    'INSERT INTO next_of_kin (customer_id, full_name, relationship, phone) VALUES (' || v_cust || q'[, 'Kofi Tester', 'SIBLING', '+233240000004')]');
  rejects('next of kin with relationship BOSS',
    'INSERT INTO next_of_kin (customer_id, full_name, relationship, phone) VALUES (' || v_cust || q'[, 'X', 'BOSS', '+233240000005')]');

  -- --------------------------------------------------------------------- files
  SELECT LOWER(RAWTOHEX(STANDARD_HASH(c_png, 'SHA256'))) INTO v_sha FROM dual;
  INSERT INTO customer_files (customer_id, file_kind, mime_type, byte_size, sha256, content, captured_by)
    VALUES (v_cust, 'PHOTO', 'image/png', UTL_RAW.LENGTH(c_png), v_sha, TO_BLOB(c_png), v_emp);
  SELECT COUNT(*) INTO v_count FROM customer_files
   WHERE customer_id = v_cust AND file_kind = 'PHOTO'
     AND DBMS_LOB.GETLENGTH(content) = byte_size AND byte_size = 70 AND sha256 = v_sha;
  check_that('photo stored as a BLOB; size (70 bytes) and SHA-256 match the bytes', v_count = 1);

  rejects('a second CURRENT photo for the same customer',
    'INSERT INTO customer_files (customer_id, file_kind, mime_type, byte_size, sha256, content, captured_by) VALUES ('
    || v_cust || q'[, 'PHOTO', 'image/png', 70, ']' || v_sha || q'[', EMPTY_BLOB(), ]' || v_emp || ')');
  rejects('an image of the ID card (file kind ID_FRONT)',
    'INSERT INTO customer_files (customer_id, file_kind, mime_type, byte_size, sha256, content, captured_by) VALUES ('
    || v_cust2 || q'[, 'ID_FRONT', 'image/png', 70, ']' || v_sha || q'[', EMPTY_BLOB(), ]' || v_emp || ')');
  rejects('a PDF file',
    'INSERT INTO customer_files (customer_id, file_kind, mime_type, byte_size, sha256, content, captured_by) VALUES ('
    || v_cust2 || q'[, 'SIGNATURE', 'application/pdf', 70, ']' || v_sha || q'[', EMPTY_BLOB(), ]' || v_emp || ')');
  rejects('a 3 MB file (limit 2 MB)',
    'INSERT INTO customer_files (customer_id, file_kind, mime_type, byte_size, sha256, content, captured_by) VALUES ('
    || v_cust2 || q'[, 'SIGNATURE', 'image/png', 3145728, ']' || v_sha || q'[', EMPTY_BLOB(), ]' || v_emp || ')');
  rejects('a SHA-256 in upper case',
    'INSERT INTO customer_files (customer_id, file_kind, mime_type, byte_size, sha256, content, captured_by) VALUES ('
    || v_cust2 || q'[, 'SIGNATURE', 'image/png', 70, ']' || UPPER(v_sha) || q'[', EMPTY_BLOB(), ]' || v_emp || ')');

  SELECT COUNT(*) INTO v_count FROM dba_lobs
   WHERE owner = 'WELBANK' AND table_name = 'CUSTOMER_FILES' AND column_name = 'CONTENT'
     AND tablespace_name = 'WELBANK_DOCS' AND securefile = 'YES';
  check_that('picture bytes stored as a SecureFile in tablespace WELBANK_DOCS', v_count = 1);

  DBMS_OUTPUT.PUT_LINE('RESULT: ' || passed || ' passed, ' || failed || ' failed');
  ROLLBACK;
END;
/
