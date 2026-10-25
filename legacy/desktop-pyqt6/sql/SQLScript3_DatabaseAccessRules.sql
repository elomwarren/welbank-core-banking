-- WELBANK, Inc Database Administration

-- Connect to the pluggable <WELBANK> as sysdba

---------------------------------- CUSTOMER SERVICE employees

-- USER CREATION
create user kwameowusu identified by "&password"; -- CREATE CUSTOMER SERVICE department USER -- eg. Kwame Owusu (as sysdba)
create user cs identified by "&password"; -- general user of CUSTOMER SERVICE

-- CUSTOMER SERVICE ROLE
create role CUSTOMER_SERVICE;
-- GRANT NECESSARY PRIVILEGES TO ROLE
grant create session to CUSTOMER_SERVICE;
-- 
grant select, insert, update on welbank.CUSTOMERS to CUSTOMER_SERVICE;
grant select, insert, update on welbank.ACCOUNTS to CUSTOMER_SERVICE;
grant select, insert, update on welbank.CARDS to CUSTOMER_SERVICE;
grant select, insert, update on welbank.TRANSACTIONS to CUSTOMER_SERVICE;
grant select, insert, update on welbank.LOANS to CUSTOMER_SERVICE;
grant select, insert, update on welbank.LOANS_PAYMENT to CUSTOMER_SERVICE;

-- Grant CUSTOMER_SERVICE role to users
grant CUSTOMER_SERVICE to cs;
grant CUSTOMER_SERVICE to kwameowusu;

---------------------------------- HUMAN RESOURCES employees

-- USER CREATION 
create user kwadwohanson identified by "&password"; -- CREATE HUMAN RESOURCES department USER (as sysdba) -- eg. Kwadwo Hanson
create user hr identified by "&password";

-- HUMAN RESOURCES ROLE
create role HUMAN_RESOURCES;
-- GRANT NECESSARY RIVILEGES
grant create session to HUMAN_RESOURCES;
-- 
grant select, insert, update on welbank.EMPLOYEES to HUMAN_RESOURCES;
grant select, insert, update on welbank.JOBS to HUMAN_RESOURCES;
grant select, insert, update on welbank.DEPARTMENTS to HUMAN_RESOURCES;
grant select, insert, update on welbank.BRANCHES to HUMAN_RESOURCES;
grant select, insert, update on welbank.LOCATIONS to HUMAN_RESOURCES;
grant select, insert, update on welbank.REGIONS to HUMAN_RESOURCES;

-- Grant HUMAN_RESOURCES to users
grant HUMAN_RESOURCES to hr;
grant HUMAN_RESOURCES to kwadwohanson;

-- Tables Query format: select * from welbank.<table.name>;
