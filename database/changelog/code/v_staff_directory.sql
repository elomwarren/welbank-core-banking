--liquibase formatted sql

--changeset elomwarren:code-v-staff-directory runOnChange:true
--comment: Who works where, without salaries or home addresses: every employee may read it.
CREATE OR REPLACE VIEW v_staff_directory AS
SELECT e.employee_id,
       e.first_name || ' ' || e.last_name AS full_name,
       e.first_name,
       e.last_name,
       e.work_email,
       e.phone,
       j.job_title,
       d.department_name,
       b.branch_code,
       b.branch_name,
       e.branch_id,
       e.manager_id,
       e.hire_date,
       e.status,
       e.db_username
  FROM employees e
  JOIN jobs j             ON j.job_id = e.job_id
  JOIN departments d      ON d.department_id = j.department_id
  LEFT JOIN branches b    ON b.branch_id = e.branch_id;
