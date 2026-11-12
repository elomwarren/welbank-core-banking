-- =============================================================================
-- preflight.sql — run first by build/seed.sql.
--
-- The seed runs only on an EMPTY database: its audit trail rows are immutable
-- (kept five years), so a half-loaded database cannot be cleaned up; start
-- again from a fresh database instead (database/seed/README.md).
-- Also records when the load started: rows created after this moment belong
-- to the simulated month being loaded and are back-dated into it.
-- =============================================================================
DECLARE
  v_count PLS_INTEGER;
BEGIN
  SELECT COUNT(*) INTO v_count FROM customers;
  IF v_count > 0 THEN
    RAISE_APPLICATION_ERROR(-20000, 'This database already has ' || v_count
      || ' customers: the seed runs only on an empty database (see database/seed/README.md)');
  END IF;
END;
/
COLUMN load_start NEW_VALUE load_start NOPRINT
SELECT TO_CHAR(SYSTIMESTAMP, 'YYYY-MM-DD HH24:MI:SS') AS load_start FROM dual;
PROMPT [seed] database is empty; loading starts
