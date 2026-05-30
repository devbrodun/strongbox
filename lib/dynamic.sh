#!/usr/bin/env bash
# lib/dynamic.sh — Dynamic PostgreSQL credential engine
# OWNER: Person 3 (Leases & Dynamic Postgres)
#
# Public API:
#   dynamic_postgres_read <role_name>
#     Connects to target DB, creates a fresh role, GRANTs privileges,
#     calls lease_create, returns JSON {username, password, lease}.
#
#   dynamic_revoke_credential <username> <lease_id>
#     Connects to target DB, REVOKEs and DROPs the role.
#     If DB unreachable: returns exit code 2 (reaper sets revocation_pending).
#     Must never silently succeed without actually dropping the role.
#
# Config (from environment):
#   STRONGBOX_PG_HOST   STRONGBOX_PG_PORT   STRONGBOX_PG_DB
#   STRONGBOX_PG_USER   STRONGBOX_PG_PASS   (admin credentials for role management)
#   STRONGBOX_PG_GRANT  (e.g. "SELECT ON ALL TABLES IN SCHEMA public")

set -euo pipefail

STRONGBOX_PG_HOST="${STRONGBOX_PG_HOST:-localhost}"
STRONGBOX_PG_PORT="${STRONGBOX_PG_PORT:-5432}"
STRONGBOX_PG_DB="${STRONGBOX_PG_DB:-postgres}"
STRONGBOX_PG_USER="${STRONGBOX_PG_USER:-postgres}"
STRONGBOX_PG_PASS="${STRONGBOX_PG_PASS:-}"
STRONGBOX_PG_GRANT="${STRONGBOX_PG_GRANT:-SELECT ON ALL TABLES IN SCHEMA public}"

# TODO: implement dynamic_postgres_read <role_name>
#   - generate random username + password
#   - PGPASSWORD=... psql ... -c "CREATE ROLE ... LOGIN PASSWORD '...'"
#   - PGPASSWORD=... psql ... -c "GRANT $STRONGBOX_PG_GRANT TO ..."
#   - lease_create "dynamic-postgres/$role_name" ...
#   - print JSON {username, password, lease}

# TODO: implement dynamic_revoke_credential <username> <lease_id>
#   - PGPASSWORD=... psql ... -c "REVOKE ... FROM $username"
#   - PGPASSWORD=... psql ... -c "DROP ROLE IF EXISTS $username"
#   - exit 0 on success, exit 2 on DB unreachable

# TODO: implement _dynamic_pg_exec <sql>  (wraps psql, returns exit 2 on conn failure)
# TODO: implement _dynamic_gen_username <role_name>  -> "sb_<role>_<random8>"
# TODO: implement _dynamic_gen_password               -> 24-char random

dynamic_postgres_read()      { echo "NOT_IMPLEMENTED" >&2; return 1; }
dynamic_revoke_credential()  { echo "NOT_IMPLEMENTED" >&2; return 1; }
