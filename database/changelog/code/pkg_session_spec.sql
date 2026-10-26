--liquibase formatted sql

--changeset elomwarren:code-pkg-session-spec runOnChange:true endDelimiter:/
CREATE OR REPLACE PACKAGE pkg_session AS
  -- ===========================================================================
  -- Who is calling.
  --
  -- The web app opens each employee's database session through proxy
  -- authentication (wb_app[their_user]), so the session user IS the
  -- employee's own Oracle user, stored in employees.db_username. Nothing can
  -- pass a different employee id in.
  --
  -- Looked up on every call (a unique-index read), never cached: suspending
  -- an employee takes effect at once, even in a session already open.
  -- ===========================================================================

  -- The calling employee. Raises pkg_errors.e_not_an_employee when the
  -- session user is not an ACTIVE employee.
  FUNCTION employee_id RETURN employees.employee_id%TYPE;

  -- The same, but NULL instead of an error (system jobs, scripts).
  FUNCTION employee_id_or_null RETURN employees.employee_id%TYPE;

  -- The calling employee's branch (where their cash transactions happen).
  FUNCTION branch_id RETURN employees.branch_id%TYPE;

  -- The largest amount the calling employee may post alone for this kind of
  -- transaction and currency, from their job's transaction_limits row; 0 when
  -- there is none (everything then needs a checker).
  FUNCTION limit_for(p_txn_type IN VARCHAR2, p_currency IN VARCHAR2) RETURN NUMBER;
END pkg_session;
/
--rollback DROP PACKAGE pkg_session
