--liquibase formatted sql

-- =============================================================================
-- 0007_transaction_limits_by_job.sql — posting limits follow the employee's
-- job (grade), not an Oracle role.
--
-- Why the change: pkg_posting runs with its owner's rights (definer's rights),
-- and inside such code Oracle disables the caller's roles, so the package
-- cannot see which roles the employee has. Banks set authority by grade
-- anyway (teller, senior teller, supervisor). Oracle roles will still decide
-- WHAT an employee may do (security commit); the job decides HOW MUCH.
--
-- Changed with a new changeset, never by editing 0002 (see SCHEMA_MIGRATIONS
-- §8). The table is empty everywhere, so the column can simply be replaced;
-- on a table with rows, ADD ... NOT NULL would fail and stop the migration.
-- =============================================================================

--changeset elomwarren:0007-transaction-limits-by-job
ALTER TABLE transaction_limits DROP CONSTRAINT transaction_limits_uk;
ALTER TABLE transaction_limits DROP CONSTRAINT transaction_limits_role_ck;
ALTER TABLE transaction_limits DROP COLUMN role_name;
ALTER TABLE transaction_limits ADD (job_id NUMBER(10) NOT NULL);
ALTER TABLE transaction_limits ADD CONSTRAINT transaction_limits_job_fk FOREIGN KEY (job_id) REFERENCES jobs (job_id);
-- The unique index starts with job_id, so it also serves the foreign key.
ALTER TABLE transaction_limits ADD CONSTRAINT transaction_limits_uk UNIQUE (job_id, txn_type, currency_code);
COMMENT ON TABLE  transaction_limits        IS 'Largest amount an employee may post alone, by job (grade). Above it, a checker whose own limit covers the amount must approve (maker-checker).';
COMMENT ON COLUMN transaction_limits.job_id IS 'The job the limit applies to, e.g. Teller, Senior Teller, Branch Supervisor. No row = limit 0 (everything needs a checker).';
--rollback ALTER TABLE transaction_limits DROP CONSTRAINT transaction_limits_uk;
--rollback ALTER TABLE transaction_limits DROP CONSTRAINT transaction_limits_job_fk;
--rollback ALTER TABLE transaction_limits DROP COLUMN job_id;
--rollback ALTER TABLE transaction_limits ADD (role_name VARCHAR2(128) NOT NULL);
--rollback ALTER TABLE transaction_limits ADD CONSTRAINT transaction_limits_role_ck CHECK (role_name = UPPER(role_name));
--rollback ALTER TABLE transaction_limits ADD CONSTRAINT transaction_limits_uk UNIQUE (role_name, txn_type, currency_code);
--rollback COMMENT ON TABLE transaction_limits IS 'Largest amount a role may post alone; above it, a supervisor must approve (maker-checker).';
