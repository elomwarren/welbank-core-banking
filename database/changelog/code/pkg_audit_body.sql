--liquibase formatted sql

--changeset elomwarren:code-pkg-audit-body runOnChange:true endDelimiter:/
CREATE OR REPLACE PACKAGE BODY pkg_audit AS

  PROCEDURE log_event (
    p_event_type   IN VARCHAR2,
    p_entity_table IN VARCHAR2,
    p_entity_id    IN VARCHAR2,
    p_old_values   IN VARCHAR2 DEFAULT NULL,
    p_new_values   IN VARCHAR2 DEFAULT NULL)
  IS
  BEGIN
    -- db_user, proxy_user, client_ip, module and client_identifier fill
    -- themselves from the session (column defaults).
    INSERT INTO audit_trail (event_type, entity_table, entity_id, employee_id, old_values, new_values)
    VALUES (p_event_type, p_entity_table, p_entity_id, pkg_session.employee_id_or_null,
            p_old_values, p_new_values);
  END log_event;

END pkg_audit;
/
--rollback DROP PACKAGE BODY pkg_audit
