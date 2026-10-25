#!/usr/bin/env bash
# init-secrets.sh — create the local secret files that compose.yaml reads.
#
# Usage:   ./scripts/init-secrets.sh
#
# - Files go in ./secrets/, which is gitignored: they are never committed.
# - Existing files are kept, so running this twice is safe.
# - Passwords are random, 24 characters, letters and digits only. That satisfies Oracle's
#   rules (starts with a letter; has upper case, lower case and a digit) and needs no quoting
#   in SQL*Plus or shell scripts.
# - Nothing is printed. To read a value: cat secrets/oracle_pwd.txt

set -euo pipefail

cd "$(dirname "$0")/.."

umask 077
mkdir -p secrets
chmod 700 secrets   # only you can open the folder

# Print a random password: "Wb7" guarantees upper, lower and digit; 21 random letters/digits follow.
generate_password() {
  local body
  body=$(head -c 512 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9' | cut -c1-21)
  printf 'Wb7%s' "$body"
}

# Create secrets/<name>.txt unless it already exists.
create_secret() {
  local file="secrets/$1.txt"
  if [[ -s "$file" ]]; then
    echo "kept existing: $file"
    return
  fi
  generate_password > "$file"
  # Readable by the container's "oracle" user (uid 54321), which is not you. The folder
  # above is private (700), so other users on this laptop still cannot reach the file.
  chmod 644 "$file"
  echo "created:       $file"
}

create_secret oracle_pwd
