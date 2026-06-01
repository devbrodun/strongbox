#!/usr/bin/env bash

source "${SB_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/lib/util.sh"
source "$SB_ROOT/lib/lease.sh"

pg_env() {
  export PGHOST="$(config_get postgres.host postgres)"
  export PGPORT="$(config_get postgres.port 5432)"
  export PGDATABASE="$(config_get postgres.database appdb)"
  export PGUSER="$(config_get postgres.admin_user strongbox_admin)"
  export PGPASSWORD="$(config_get postgres.admin_password strongbox_admin_password)"
}

pg_ident() {
  printf '%s' "$1" | sed 's/"/""/g'
}

dynamic_postgres_read() {
  local role="$1" ttl="${2:-$(config_get leases.default_ttl_seconds 60)}"
  local username password grants metadata lease
  pg_env
  username="sb_${role}_$(date +%s)_$(rand_b64url 6 | tr '-' '_' | tr -d '_')"
  password="$(rand_b64url 24)"
  psql -v ON_ERROR_STOP=1 <<SQL >/dev/null
CREATE ROLE "$(pg_ident "$username")" LOGIN PASSWORD '$password';
SQL
  grants="$(config_get postgres.readonly_grants "")"
  if [[ "$role" == "readonly" && -n "$grants" ]]; then
    while IFS= read -r stmt; do
      [[ -z "$stmt" ]] && continue
      stmt="${stmt//%USER%/\"$(pg_ident "$username")\"}"
      psql -v ON_ERROR_STOP=1 -c "$stmt" >/dev/null
    done < <(tr ';' '\n' <<< "$grants")
  fi
  metadata="$(jq -nc --arg username "$username" --arg role "$role" '{username:$username,role:$role}')"
  lease="$(lease_create dynamic-postgres "dynamic-postgres/$role" "$ttl" "$metadata")"
  jq -nc --arg username "$username" --arg password "$password" --argjson lease "$lease" \
    '{username:$username,password:$password,lease:$lease}'
}

dynamic_revoke_postgres_lease() {
  local record="$1" username
  username="$(printf '%s' "$record" | jq -r '.metadata.username')"
  [[ -n "$username" && "$username" != "null" ]] || return 0
  pg_env
  psql -v ON_ERROR_STOP=1 <<SQL >/dev/null
REVOKE ALL PRIVILEGES ON DATABASE "$(config_get postgres.database appdb)" FROM "$(pg_ident "$username")";
REVOKE ALL PRIVILEGES ON SCHEMA public FROM "$(pg_ident "$username")";
REVOKE ALL PRIVILEGES ON ALL TABLES IN SCHEMA public FROM "$(pg_ident "$username")";
SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE usename = '$username';
DROP ROLE IF EXISTS "$(pg_ident "$username")";
SQL
}
