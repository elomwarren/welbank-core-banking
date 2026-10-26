-- =============================================================================
-- bootstrap.sql — the accounts and storage the WELBANK schema needs.
--
-- Run as SYSDBA by bootstrap.sh, which first DEFINEs deploy_pwd from the
-- Docker secret. Safe to re-run: existing objects are left alone, and the
-- WB_DEPLOY password is re-synced from the secret every time.
--
-- Creates, inside the WELBANK pluggable database:
--   1. WELBANK_DOCS        encrypted tablespace for KYC pictures (LOBs)
--   2. WB_SERVICE_ACCOUNT  profile for technical (non-human) accounts
--   3. WELBANK             schema owner: owns every table, cannot log in
--   4. WB_DEPLOY           deployment account: may connect AS WELBANK (proxy)
-- =============================================================================

WHENEVER SQLERROR EXIT SQL.SQLCODE
-- Never echo substitution variables: deploy_pwd must not appear in any output.
SET VERIFY OFF
SET FEEDBACK OFF
SET LINESIZE 200

ALTER SESSION SET CONTAINER = welbank;
-- After switching container: package state (including the DBMS_OUTPUT buffer
-- that SERVEROUTPUT uses) is separate in every container, so turn it on here.
SET SERVEROUTPUT ON

-- -----------------------------------------------------------------------------
-- 1. Tablespace for KYC pictures. LOBs get their own tablespace so their size
--    can be watched and capped (MAXSIZE) separately from ordinary table data.
-- -----------------------------------------------------------------------------
DECLARE
  l_count PLS_INTEGER;
BEGIN
  SELECT COUNT(*) INTO l_count FROM dba_tablespaces WHERE tablespace_name = 'WELBANK_DOCS';
  IF l_count = 0 THEN
    EXECUTE IMMEDIATE q'[
      CREATE TABLESPACE welbank_docs
        DATAFILE '/opt/oracle/oradata/FREE/WELBANK/welbank_docs01.dbf'
        SIZE 128M AUTOEXTEND ON NEXT 64M MAXSIZE 4G
        ENCRYPTION USING 'AES256' ENCRYPT]';
    DBMS_OUTPUT.PUT_LINE('[bootstrap] created tablespace WELBANK_DOCS (AES256, max 4G)');
  ELSE
    DBMS_OUTPUT.PUT_LINE('[bootstrap] tablespace WELBANK_DOCS already exists');
  END IF;
END;
/

-- -----------------------------------------------------------------------------
-- 2. Profile for technical accounts. Their passwords are rotated on purpose by
--    changing the secret file, so they must not expire on their own (an expired
--    deployment password would break deployments without warning).
-- -----------------------------------------------------------------------------
DECLARE
  l_count PLS_INTEGER;
BEGIN
  SELECT COUNT(*) INTO l_count FROM dba_profiles WHERE profile = 'WB_SERVICE_ACCOUNT';
  IF l_count = 0 THEN
    EXECUTE IMMEDIATE q'[
      CREATE PROFILE wb_service_account LIMIT
        PASSWORD_LIFE_TIME    UNLIMITED
        FAILED_LOGIN_ATTEMPTS 10
        PASSWORD_LOCK_TIME    1/24]';
    DBMS_OUTPUT.PUT_LINE('[bootstrap] created profile WB_SERVICE_ACCOUNT');
  ELSE
    DBMS_OUTPUT.PUT_LINE('[bootstrap] profile WB_SERVICE_ACCOUNT already exists');
  END IF;
END;
/

-- -----------------------------------------------------------------------------
-- 3. Schema owner. NO AUTHENTICATION = "schema-only account": it has no
--    password at all, so nobody can log in as it, steal its password or run
--    ad-hoc SQL as the owner of every table.
-- -----------------------------------------------------------------------------
DECLARE
  l_count PLS_INTEGER;
BEGIN
  SELECT COUNT(*) INTO l_count FROM dba_users WHERE username = 'WELBANK';
  IF l_count = 0 THEN
    EXECUTE IMMEDIATE q'[
      CREATE USER welbank NO AUTHENTICATION
        DEFAULT TABLESPACE welbank_data
        TEMPORARY TABLESPACE temp]';
    DBMS_OUTPUT.PUT_LINE('[bootstrap] created schema-only user WELBANK');
  ELSE
    DBMS_OUTPUT.PUT_LINE('[bootstrap] user WELBANK already exists');
  END IF;
END;
/

-- Storage quotas and the privileges needed to create its own objects.
-- Re-granting an existing privilege is harmless, so these always run.
-- CREATE SESSION is required even without a password: a proxy session runs as WELBANK.
-- CREATE ASSERTION: SQL assertions (Oracle AI Database 23.26.1 and later), rules
-- that span rows and tables, e.g. "every customer account has a primary holder".
ALTER USER welbank QUOTA UNLIMITED ON welbank_data QUOTA UNLIMITED ON welbank_docs;
GRANT CREATE SESSION, CREATE TABLE, CREATE VIEW, CREATE SEQUENCE, CREATE PROCEDURE,
      CREATE TRIGGER, CREATE TYPE, CREATE SYNONYM, CREATE MATERIALIZED VIEW, CREATE DOMAIN,
      CREATE ASSERTION
   TO welbank;

-- -----------------------------------------------------------------------------
-- 4. Deployment account. It owns nothing and may only open a session, then
--    act as WELBANK through the proxy grant below.
-- -----------------------------------------------------------------------------
CREATE USER IF NOT EXISTS wb_deploy IDENTIFIED BY "&deploy_pwd"
  DEFAULT TABLESPACE welbank_data
  PROFILE wb_service_account;

-- Re-sync the password from the secret file (handles password rotation).
ALTER USER wb_deploy IDENTIFIED BY "&deploy_pwd" PROFILE wb_service_account ACCOUNT UNLOCK;
GRANT CREATE SESSION TO wb_deploy;
ALTER USER welbank GRANT CONNECT THROUGH wb_deploy;

BEGIN
  DBMS_OUTPUT.PUT_LINE('[bootstrap] WB_DEPLOY ready: may connect as WELBANK (password synced from secret)');
END;
/
