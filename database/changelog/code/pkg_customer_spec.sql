--liquibase formatted sql

--changeset elomwarren:code-pkg-customer-spec runOnChange:true endDelimiter:/
CREATE OR REPLACE PACKAGE pkg_customer AS
  -- ===========================================================================
  -- Customer onboarding and KYC, following the Bank of Ghana Guidance Note on
  -- the Use of the Ghana Card (Nov 2025) and L.I. 2111 (see SCHEMA_V2 §3.2a):
  --
  --   register_customer -> add_address / add_contact / add_next_of_kin
  --   -> add_file (live photo, specimen signature, proof of address)
  --   -> record_verification (the NIA result; the web app talks to NIA)
  --   -> record_screening (sanctions lists)
  --   -> submit_kyc (maker) -> approve_kyc / reject_kyc (checker).
  --
  -- A NO_MATCH or FAILED onboarding verification defers the customer: deposits
  -- only, KYC_DEFERRAL_DAYS (90) to fix their records. Approving the KYC
  -- switches debits on (pkg_account.refresh_debits); a periodic review that
  -- falls due switches them off first (mark_review_due).
  --
  -- Customers are identified by customer_no (CUS00000001), never by the
  -- internal id. The caller is identified by pkg_session; nothing COMMITs.
  -- ===========================================================================

  -- Returns the new customer number. p_data_consent must be TRUE (Act 843).
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
    p_marketing_consent       IN BOOLEAN  DEFAULT FALSE) RETURN VARCHAR2;

  -- A new current address of that type; the previous one is kept as history.
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
    p_proof_date      IN DATE     DEFAULT NULL);

  -- p_value is a phone (E.164, +233...) for MOBILE/HOME/WORK, an e-mail for EMAIL.
  -- A new primary replaces the previous primary phone (or e-mail).
  PROCEDURE add_contact (
    p_customer_no  IN VARCHAR2,
    p_contact_type IN VARCHAR2,
    p_value        IN VARCHAR2,
    p_is_primary   IN BOOLEAN DEFAULT FALSE);

  PROCEDURE add_next_of_kin (
    p_customer_no  IN VARCHAR2,
    p_full_name    IN VARCHAR2,
    p_relationship IN VARCHAR2,
    p_phone        IN VARCHAR2,
    p_address      IN VARCHAR2 DEFAULT NULL);

  -- PHOTO, SIGNATURE or PROOF_OF_ADDRESS; never an image of an ID card. The
  -- content must really be the declared image type (checked from its first
  -- bytes) and at most 2 MB; its size is measured here, not trusted. The web
  -- app computes the SHA-256. Replaces the current file of that kind.
  PROCEDURE add_file (
    p_customer_no IN VARCHAR2,
    p_file_kind   IN VARCHAR2,
    p_mime_type   IN VARCHAR2,
    p_content     IN BLOB,
    p_sha256      IN VARCHAR2);

  -- Records an identity verification of the customer's primary document, as
  -- returned by NIA (or a manual passport check). On a MATCH, p_nia_data
  -- (JSON: first_name, middle_name, last_name, previous_names, sex,
  -- date_of_birth "YYYY-MM-DD", nationality) replaces the primary data typed
  -- by staff. Returns the verification id.
  FUNCTION record_verification (
    p_customer_no   IN VARCHAR2,
    p_purpose       IN VARCHAR2,
    p_method        IN VARCHAR2,
    p_result        IN VARCHAR2,
    p_nia_reference IN VARCHAR2 DEFAULT NULL,
    p_error_code    IN VARCHAR2 DEFAULT NULL,
    p_nia_data      IN VARCHAR2 DEFAULT NULL,
    p_is_simulated  IN BOOLEAN  DEFAULT TRUE) RETURN NUMBER;

  -- Result of screening against sanctions lists: CLEAR, POTENTIAL_MATCH, CONFIRMED_MATCH.
  PROCEDURE record_screening (p_customer_no IN VARCHAR2, p_sanctions_status IN VARCHAR2);

  -- What is still missing before the KYC can be submitted, as a list for the
  -- screen ("live photo, specimen signature"); NULL when nothing is.
  FUNCTION kyc_missing (p_customer_no IN VARCHAR2) RETURN VARCHAR2;

  -- Maker: sends a complete KYC file to a checker.
  PROCEDURE submit_kyc (p_customer_no IN VARCHAR2);

  -- Checker: VERIFIED with a risk rating (LOW, MEDIUM, HIGH; a PEP is always
  -- HIGH), the next review date, and debits switched on where possible.
  PROCEDURE approve_kyc (p_customer_no IN VARCHAR2, p_risk_rating IN VARCHAR2);
  PROCEDURE reject_kyc (p_customer_no IN VARCHAR2, p_reason IN VARCHAR2);

  -- The periodic review is due: debits off on the customer's accounts, then
  -- KYC REVIEW_DUE (the order the assertion accounts_debit_kyc_as demands).
  PROCEDURE mark_review_due (p_customer_no IN VARCHAR2);
END pkg_customer;
/
--rollback DROP PACKAGE pkg_customer
