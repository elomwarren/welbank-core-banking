--liquibase formatted sql

-- =============================================================================
-- 0008_bank_parameters.sql — policy values the packages read: data, not code
-- (see the engineering log, EL-040). Changing one is an UPDATE (audited), not
-- a release.
-- =============================================================================

--changeset elomwarren:0008-bank-parameters
CREATE TABLE bank_parameters (
  param_name   VARCHAR2(40)  NOT NULL,
  num_value    NUMBER        NOT NULL,
  unit         VARCHAR2(10)  NOT NULL,
  description  VARCHAR2(300) NOT NULL,
  source       VARCHAR2(200) NOT NULL,
  updated_at   TIMESTAMP,
  updated_by   VARCHAR2(128),
  CONSTRAINT bank_parameters_pk      PRIMARY KEY (param_name),
  CONSTRAINT bank_parameters_name_ck CHECK (REGEXP_LIKE(param_name, '^[A-Z][A-Z0-9_]*$')),
  CONSTRAINT bank_parameters_unit_ck CHECK (unit IN ('DAYS', 'MONTHS', 'YEARS', 'COUNT', 'PERCENT')),
  CONSTRAINT bank_parameters_value_ck CHECK (num_value >= 0)
);
COMMENT ON TABLE  bank_parameters        IS 'Policy values read by the packages (e.g. the 90-day KYC deferral). Change with UPDATE; never hard-code them.';
COMMENT ON COLUMN bank_parameters.source IS 'Where the value comes from: a regulation (with its section) or a bank policy decision.';
--rollback DROP TABLE bank_parameters PURGE;

--changeset elomwarren:0008-bank-parameters-updated-trg endDelimiter:/
CREATE OR REPLACE TRIGGER bank_parameters_updated_trg
  BEFORE UPDATE ON bank_parameters
  FOR EACH ROW
BEGIN
  :NEW.updated_at := SYSTIMESTAMP;
  :NEW.updated_by := SYS_CONTEXT('USERENV', 'SESSION_USER');
END;
/
--rollback DROP TRIGGER bank_parameters_updated_trg

--changeset elomwarren:0008-bank-parameters-values
--comment: The values the onboarding packages need. Configuration, not seed data: the system cannot work without them.
INSERT INTO bank_parameters (param_name, num_value, unit, description, source) VALUES
  ('KYC_DEFERRAL_DAYS', 90, 'DAYS', 'Time a customer has to fix their records after a failed onboarding verification; deposits only meanwhile',
   'Bank of Ghana, Guidance Note on the Use of the Ghana Card (Nov 2025), s.10'),
  ('MIN_CUSTOMER_AGE', 18, 'YEARS', 'Minimum age of an individual customer (accounts for minors are out of scope)',
   'Bank policy (Tier 1 scope)'),
  ('KYC_REVIEW_MONTHS_LOW', 36, 'MONTHS', 'Months until the next KYC review of a low-risk customer',
   'Bank policy (risk-based review, illustrative)'),
  ('KYC_REVIEW_MONTHS_MEDIUM', 24, 'MONTHS', 'Months until the next KYC review of a medium-risk customer',
   'Bank policy (risk-based review, illustrative)'),
  ('KYC_REVIEW_MONTHS_HIGH', 12, 'MONTHS', 'Months until the next KYC review of a high-risk customer (and every PEP)',
   'Bank policy (risk-based review, illustrative)');
--rollback DELETE FROM bank_parameters WHERE param_name IN ('KYC_DEFERRAL_DAYS', 'MIN_CUSTOMER_AGE', 'KYC_REVIEW_MONTHS_LOW', 'KYC_REVIEW_MONTHS_MEDIUM', 'KYC_REVIEW_MONTHS_HIGH');
