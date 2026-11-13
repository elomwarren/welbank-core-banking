--liquibase formatted sql

--changeset elomwarren:code-grants runOnChange:true
--comment: What each role may read or run. Only the packages write: no role gets INSERT, UPDATE or DELETE on any table.
-- The roles themselves are created by database/security/security.sql (SYSDBA).
-- Packages run with WELBANK's rights (definer's rights), so EXECUTE on a package
-- is the whole permission: the package's own rules (maker-checker, limits by
-- job, KYC state) decide the rest.

-- Every employee (WB_STAFF): reference data, the customer and account records
-- needed to serve someone, and who they are (pkg_session).
GRANT SELECT ON currencies            TO wb_staff;
GRANT SELECT ON countries             TO wb_staff;
GRANT SELECT ON regions               TO wb_staff;
GRANT SELECT ON branches              TO wb_staff;
GRANT SELECT ON locations             TO wb_staff;
GRANT SELECT ON departments           TO wb_staff;
GRANT SELECT ON jobs                  TO wb_staff;
GRANT SELECT ON account_products      TO wb_staff;
GRANT SELECT ON loan_products         TO wb_staff;
GRANT SELECT ON loan_classes          TO wb_staff;
GRANT SELECT ON bank_parameters       TO wb_staff;
GRANT SELECT ON transaction_limits    TO wb_staff;
GRANT SELECT ON customers             TO wb_staff;
GRANT SELECT ON customer_addresses    TO wb_staff;
GRANT SELECT ON customer_contacts     TO wb_staff;
GRANT SELECT ON next_of_kin           TO wb_staff;
GRANT SELECT ON accounts              TO wb_staff;
GRANT SELECT ON account_holders       TO wb_staff;
GRANT SELECT ON transactions          TO wb_staff;
GRANT SELECT ON ledger_entries        TO wb_staff;
GRANT SELECT ON loans                 TO wb_staff;
GRANT SELECT ON loan_applications     TO wb_staff;
GRANT SELECT ON loan_schedule         TO wb_staff;
GRANT SELECT ON loan_repayments       TO wb_staff;
GRANT SELECT ON cards                 TO wb_staff;
GRANT SELECT ON approval_requests     TO wb_staff;
GRANT SELECT ON v_account_statement   TO wb_staff;
GRANT SELECT ON v_pending_approvals   TO wb_staff;
GRANT SELECT ON v_staff_directory     TO wb_staff;
GRANT EXECUTE ON pkg_session          TO wb_staff;

-- Identity data (ID numbers, NIA checks, photos and signatures): only the people
-- who onboard or approve customers, and the auditors. Every read is audited
-- (unified audit policy WB_SENSITIVE_READS).
GRANT SELECT ON identity_documents     TO wb_customer_service;
GRANT SELECT ON identity_verifications TO wb_customer_service;
GRANT SELECT ON customer_files         TO wb_customer_service;
GRANT SELECT ON identity_documents     TO wb_kyc_approver;
GRANT SELECT ON identity_verifications TO wb_kyc_approver;
GRANT SELECT ON customer_files         TO wb_kyc_approver;
GRANT SELECT ON identity_documents     TO wb_auditor;
GRANT SELECT ON identity_verifications TO wb_auditor;

-- Counter work: tellers post, supervisors also approve, reject and reverse.
GRANT EXECUTE ON pkg_posting  TO wb_teller;
GRANT EXECUTE ON pkg_posting  TO wb_supervisor;

-- Onboarding and accounts: customer service registers and opens; branch managers approve.
GRANT EXECUTE ON pkg_customer TO wb_customer_service;
GRANT EXECUTE ON pkg_account  TO wb_customer_service;
GRANT EXECUTE ON pkg_customer TO wb_kyc_approver;
GRANT EXECUTE ON pkg_account  TO wb_kyc_approver;

-- Lending: loan officers apply and collect; credit decides and disburses.
GRANT EXECUTE ON pkg_loan     TO wb_loan_officer;
GRANT EXECUTE ON pkg_loan     TO wb_credit;

-- Management reports and the ledger check.
GRANT SELECT ON v_ledger_balance_check TO wb_reports;
GRANT SELECT ON v_ledger_balance_check TO wb_auditor;

-- Audit: the application's own immutable trail.
GRANT SELECT ON audit_trail   TO wb_auditor;

-- Human resources: the full staff records (salaries included) and the job-to-role map.
GRANT SELECT ON employees     TO wb_hr;
GRANT SELECT ON job_roles     TO wb_hr;
GRANT SELECT ON job_roles     TO wb_auditor;

-- Backups: the log written by scripts/db-backup.sh (V$ views are granted in security.sql).
GRANT SELECT ON backup_runs   TO wb_backup_admin;
GRANT SELECT ON backup_runs   TO wb_auditor;
