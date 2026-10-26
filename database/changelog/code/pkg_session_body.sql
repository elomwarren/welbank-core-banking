--liquibase formatted sql

--changeset elomwarren:code-pkg-session-body runOnChange:true endDelimiter:/
CREATE OR REPLACE PACKAGE BODY pkg_session AS

  -- The employees row of the session user, if that user is an ACTIVE employee.
  FUNCTION current_employee RETURN employees%ROWTYPE IS
    r employees%ROWTYPE;
  BEGIN
    SELECT * INTO r
      FROM employees
     WHERE db_username = SYS_CONTEXT('USERENV', 'SESSION_USER')
       AND status = 'ACTIVE';
    RETURN r;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      RAISE_APPLICATION_ERROR(pkg_errors.c_not_an_employee,
        'Database user ' || SYS_CONTEXT('USERENV', 'SESSION_USER') || ' is not an active employee');
  END current_employee;

  FUNCTION employee_id RETURN employees.employee_id%TYPE IS
  BEGIN
    RETURN current_employee().employee_id;
  END employee_id;

  FUNCTION employee_id_or_null RETURN employees.employee_id%TYPE IS
  BEGIN
    RETURN current_employee().employee_id;
  EXCEPTION
    WHEN pkg_errors.e_not_an_employee THEN
      RETURN NULL;
  END employee_id_or_null;

  FUNCTION branch_id RETURN employees.branch_id%TYPE IS
  BEGIN
    RETURN current_employee().branch_id;
  END branch_id;

  FUNCTION limit_for(p_txn_type IN VARCHAR2, p_currency IN VARCHAR2) RETURN NUMBER IS
    v_job   employees.job_id%TYPE := current_employee().job_id;
    v_limit transaction_limits.max_amount%TYPE;
  BEGIN
    SELECT max_amount INTO v_limit
      FROM transaction_limits
     WHERE job_id = v_job AND txn_type = p_txn_type AND currency_code = p_currency;
    RETURN v_limit;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      RETURN 0;
  END limit_for;

END pkg_session;
/
--rollback DROP PACKAGE BODY pkg_session
