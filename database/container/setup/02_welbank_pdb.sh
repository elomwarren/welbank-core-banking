#!/bin/bash
# =============================================================================
# 02_welbank_pdb.sh — create the WELBANK pluggable database (PDB).
#
# When:  once, right after the image creates the database (sourced by the
#        image's runUserScripts.sh, after 01_recovery_area.sh).
# What:  1. creates PDB WELBANK from the seed and makes it open on every start;
#        2. gives it its own TDE master encryption key (each PDB needs one);
#        3. encrypts the tablespaces copied from the (unencrypted) seed: SYSTEM,
#           SYSAUX and UNDOTBS1 online, and TEMP by replacing it. Automatic
#           encryption (TABLESPACE_ENCRYPTION = AUTO_ENABLE) only covers
#           tablespaces created new, not copies;
#        4. creates the encrypted WELBANK_DATA tablespace and makes it the default;
#        5. locks the PDB's local admin account (administration goes through
#           named accounts, created later).
# Needs: ORACLE_PWD, exported by the image from /run/secrets/oracle_pwd. It is
#        the TDE keystore password in this image.
# =============================================================================

# Sourced by the image's start-up script: run in a subshell so `exit` / `set -e`
# cannot stop the container's own script. The exit code is checked on a separate
# line (see 01_recovery_area.sh for why `( ... ) || echo ERROR` is wrong).
(
  set -euo pipefail

  pdb_dir="/opt/oracle/oradata/${ORACLE_SID}/WELBANK"
  # Throwaway password for the PDB admin account, which is locked straight after.
  # It is never stored or printed.
  pdb_admin_pwd="Wb7$(head -c 256 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9' | cut -c1-21)"

  existing=$(sqlplus -s / as sysdba <<'SQL'
SET HEADING OFF FEEDBACK OFF PAGESIZE 0
SELECT COUNT(*) FROM v$pdbs WHERE name = 'WELBANK';
SQL
)
  if [[ "${existing//[[:space:]]/}" != "0" ]]; then
    echo "[welbank] PDB WELBANK already exists; nothing to do"
    exit 0
  fi

  echo "[welbank] Creating pluggable database WELBANK"
  mkdir -p "${pdb_dir}"

  sqlplus -s / as sysdba <<SQL
WHENEVER SQLERROR EXIT SQL.SQLCODE
SET DEFINE OFF

-- 1. Create the PDB from the seed. Its files go in their own folder.
CREATE PLUGGABLE DATABASE welbank
  ADMIN USER welbank_pdbadmin IDENTIFIED BY "${pdb_admin_pwd}"
  FILE_NAME_CONVERT = ('/opt/oracle/oradata/${ORACLE_SID}/pdbseed/', '${pdb_dir}/');

ALTER PLUGGABLE DATABASE welbank OPEN;
-- Remember "open" so the PDB opens automatically whenever the container starts.
ALTER PLUGGABLE DATABASE welbank SAVE STATE;

ALTER SESSION SET CONTAINER = welbank;

-- 2. Each PDB needs its own master encryption key in the keystore.
ADMINISTER KEY MANAGEMENT SET KEY FORCE KEYSTORE
  IDENTIFIED BY "${ORACLE_PWD}" WITH BACKUP USING 'welbank_pdb_created';

-- 3. Encrypt what was copied from the seed. ONLINE conversion writes an encrypted
--    copy of each datafile (new name via FILE_NAME_CONVERT), switches to it and
--    deletes the original, while the PDB stays open. TEMP cannot be converted, so
--    an encrypted replacement is created and the old one dropped.
ALTER TABLESPACE system   ENCRYPTION ONLINE USING 'AES256' ENCRYPT
  FILE_NAME_CONVERT = ('system01.dbf', 'system01_enc.dbf');
ALTER TABLESPACE sysaux   ENCRYPTION ONLINE USING 'AES256' ENCRYPT
  FILE_NAME_CONVERT = ('sysaux01.dbf', 'sysaux01_enc.dbf');
ALTER TABLESPACE undotbs1 ENCRYPTION ONLINE USING 'AES256' ENCRYPT
  FILE_NAME_CONVERT = ('undotbs01.dbf', 'undotbs01_enc.dbf');
CREATE TEMPORARY TABLESPACE temp_enc
  TEMPFILE '${pdb_dir}/temp01_enc.dbf' SIZE 64M AUTOEXTEND ON NEXT 32M MAXSIZE 2G
  ENCRYPTION USING 'AES256' ENCRYPT;
ALTER DATABASE DEFAULT TEMPORARY TABLESPACE temp_enc;
DROP TABLESPACE temp INCLUDING CONTENTS AND DATAFILES;
ALTER TABLESPACE temp_enc RENAME TO temp;

-- 4. Application tablespace, explicitly encrypted with AES-256.
CREATE TABLESPACE welbank_data
  DATAFILE '${pdb_dir}/welbank_data01.dbf' SIZE 256M AUTOEXTEND ON NEXT 64M MAXSIZE 4G
  ENCRYPTION USING 'AES256' ENCRYPT;
ALTER DATABASE DEFAULT TABLESPACE welbank_data;

-- 5. Lock the local admin account; nobody needs it.
ALTER USER welbank_pdbadmin ACCOUNT LOCK;
SQL

  echo "[welbank] PDB WELBANK created, encrypted and open"
)
welbank_rc=$?
if [[ $welbank_rc -ne 0 ]]; then
  echo "[welbank] ERROR: 02_welbank_pdb.sh failed with exit code ${welbank_rc} (see the messages above)"
fi
