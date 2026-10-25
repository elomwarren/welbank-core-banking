--liquibase formatted sql

-- =============================================================================
-- 0001_domains.sql — SQL domains (Oracle 23ai+).
--
-- A domain is a named, reusable column definition: a data type plus the rules
-- that every value must follow. A column declared with a domain gets the rule
-- automatically, so a rule like "a Ghana Card number looks like GHA-#########-#"
-- is written once, here, instead of being copied as a CHECK constraint into
-- every table that stores one.
-- =============================================================================

--changeset elomwarren:0001-domain-email
--comment: E-mail address: text@text.text, no spaces.
CREATE DOMAIN email_d AS VARCHAR2(254)
  CONSTRAINT email_d_format_ck
    CHECK (REGEXP_LIKE(email_d, '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'));
--rollback DROP DOMAIN email_d;

--changeset elomwarren:0001-domain-phone
--comment: Phone number in international E.164 form, e.g. +233244123456 (works for foreign numbers too).
CREATE DOMAIN phone_d AS VARCHAR2(16)
  CONSTRAINT phone_d_e164_ck
    CHECK (REGEXP_LIKE(phone_d, '^\+[1-9][0-9]{7,14}$'));
--rollback DROP DOMAIN phone_d;

--changeset elomwarren:0001-domain-ghana-card
--comment: Ghana Card personal ID number, e.g. GHA-123456789-0.
CREATE DOMAIN ghana_card_d AS VARCHAR2(15)
  CONSTRAINT ghana_card_d_format_ck
    CHECK (REGEXP_LIKE(ghana_card_d, '^GHA-[0-9]{9}-[0-9]$'));
--rollback DROP DOMAIN ghana_card_d;

--changeset elomwarren:0001-domain-digital-address
--comment: GhanaPost GPS digital address, e.g. GA-123-4567 or GA-0123-4567.
CREATE DOMAIN gh_digital_address_d AS VARCHAR2(12)
  CONSTRAINT gh_digital_address_d_format_ck
    CHECK (REGEXP_LIKE(gh_digital_address_d, '^[A-Z]{2}-[0-9]{3,4}-[0-9]{4}$'));
--rollback DROP DOMAIN gh_digital_address_d;

--changeset elomwarren:0001-domain-country
--comment: ISO 3166-1 alpha-3 country code, e.g. GHA, NGA, GBR.
CREATE DOMAIN iso_country_d AS VARCHAR2(3)
  CONSTRAINT iso_country_d_format_ck
    CHECK (REGEXP_LIKE(iso_country_d, '^[A-Z]{3}$'));
--rollback DROP DOMAIN iso_country_d;

--changeset elomwarren:0001-domain-currency
--comment: ISO 4217 currency code, e.g. GHS, USD.
CREATE DOMAIN iso_currency_d AS VARCHAR2(3)
  CONSTRAINT iso_currency_d_format_ck
    CHECK (REGEXP_LIKE(iso_currency_d, '^[A-Z]{3}$'));
--rollback DROP DOMAIN iso_currency_d;

--changeset elomwarren:0001-domain-money
--comment: Money that may be negative, such as a balance in overdraft. Never FLOAT: binary floating point cannot store 0.10 exactly.
CREATE DOMAIN money_d AS NUMBER(15, 2);
--rollback DROP DOMAIN money_d;

--changeset elomwarren:0001-domain-positive-money
--comment: Money that must be greater than zero, such as a ledger amount or a limit.
CREATE DOMAIN positive_money_d AS NUMBER(15, 2)
  CONSTRAINT positive_money_d_ck CHECK (positive_money_d > 0);
--rollback DROP DOMAIN positive_money_d;

--changeset elomwarren:0001-domain-non-negative-money
--comment: Money that may be zero but never negative, such as a fee or a minimum balance.
CREATE DOMAIN non_negative_money_d AS NUMBER(15, 2)
  CONSTRAINT non_negative_money_d_ck CHECK (non_negative_money_d >= 0);
--rollback DROP DOMAIN non_negative_money_d;

--changeset elomwarren:0001-domain-rate
--comment: Annual percentage rate between 0 and 100, e.g. 24.5000 for 24.5 %.
CREATE DOMAIN rate_pct_d AS NUMBER(7, 4)
  CONSTRAINT rate_pct_d_range_ck CHECK (rate_pct_d BETWEEN 0 AND 100);
--rollback DROP DOMAIN rate_pct_d;

--changeset elomwarren:0001-domain-txn-type
--comment: Kinds of money movement, shared by transaction limits now and the ledger later.
CREATE DOMAIN txn_type_d AS VARCHAR2(20)
  CONSTRAINT txn_type_d_list_ck
    CHECK (txn_type_d IN ('CASH_DEPOSIT', 'CASH_WITHDRAWAL', 'TRANSFER', 'FEE', 'INTEREST',
                          'LOAN_DISBURSEMENT', 'LOAN_REPAYMENT', 'REVERSAL'));
--rollback DROP DOMAIN txn_type_d;
