--liquibase formatted sql

--changeset elomwarren:code-pkg-params-body runOnChange:true endDelimiter:/
CREATE OR REPLACE PACKAGE BODY pkg_params AS

  FUNCTION num (p_param_name IN VARCHAR2) RETURN NUMBER IS
    v_value bank_parameters.num_value%TYPE;
  BEGIN
    SELECT num_value INTO v_value FROM bank_parameters WHERE param_name = p_param_name;
    RETURN v_value;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      RAISE_APPLICATION_ERROR(pkg_errors.c_internal_error, 'Missing bank parameter ' || p_param_name);
  END num;

END pkg_params;
/
--rollback DROP PACKAGE BODY pkg_params
