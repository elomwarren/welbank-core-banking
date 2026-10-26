--liquibase formatted sql

--changeset elomwarren:code-pkg-audit-spec runOnChange:true endDelimiter:/
CREATE OR REPLACE PACKAGE pkg_audit AS
  -- ===========================================================================
  -- Business events into audit_trail (an immutable table: kept five years,
  -- never changed).
  --
  -- The row is written in the caller's transaction: if the action is rolled
  -- back, its audit row goes with it, so the trail only ever shows things that
  -- really happened. Failed attempts (refused logins, refused grants, ...) are
  -- the job of Unified Auditing (security commit), which records them
  -- independently of the transaction.
  -- ===========================================================================

  -- p_old_values / p_new_values: JSON objects as text, e.g. '{"status":"POSTED"}'.
  PROCEDURE log_event (
    p_event_type   IN VARCHAR2,
    p_entity_table IN VARCHAR2,
    p_entity_id    IN VARCHAR2,
    p_old_values   IN VARCHAR2 DEFAULT NULL,
    p_new_values   IN VARCHAR2 DEFAULT NULL);
END pkg_audit;
/
--rollback DROP PACKAGE pkg_audit
