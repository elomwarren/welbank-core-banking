--liquibase formatted sql

--changeset elomwarren:code-pkg-params-spec runOnChange:true endDelimiter:/
CREATE OR REPLACE PACKAGE pkg_params AS
  -- ===========================================================================
  -- Reads policy values from bank_parameters, so no package hard-codes them.
  -- A missing parameter is a deployment bug: pkg_errors.e_internal_error.
  -- ===========================================================================
  FUNCTION num (p_param_name IN VARCHAR2) RETURN NUMBER;
END pkg_params;
/
--rollback DROP PACKAGE pkg_params
