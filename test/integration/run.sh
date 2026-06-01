#!/usr/bin/env bash

set -euo pipefail

BASE="${BASE:-http://127.0.0.1:8201}"
NODE2="${NODE2:-http://127.0.0.1:8202}"
NODE3="${NODE3:-http://127.0.0.1:8203}"

need() {
  command -v "$1" >/dev/null || { echo "missing dependency: $1" >&2; exit 1; }
}

need curl
need jq
need docker

api() {
  curl -fsS "$@"
}

echo "health: sealed"
api "$BASE/v1/sys/health" | jq -e '.sealed == true' >/dev/null

echo "init"
init="$(api -X POST "$BASE/v1/sys/init" || true)"
if [[ -z "$init" || "$(printf '%s' "$init" | jq -r '.error // empty')" == "already initialized" ]]; then
  echo "cluster already initialized; set ROOT_TOKEN and SHARES to re-use it" >&2
  exit 1
fi
root="$(printf '%s' "$init" | jq -r '.root_token')"
mapfile -t shares < <(printf '%s' "$init" | jq -r '.shares[0:3][]')

echo "unseal all nodes"
for node in "$BASE" "$NODE2" "$NODE3"; do
  for share in "${shares[@]}"; do
    api -X POST "$node/v1/sys/unseal" -H 'Content-Type: application/json' -d "$(jq -nc --arg share "$share" '{share:$share}')" >/dev/null
  done
  api "$node/v1/sys/health" | jq -e '.sealed == false' >/dev/null
done

auth=(-H "Authorization: Bearer $root")

echo "secret versioning"
api -X PUT "$BASE/v1/secrets/app/db" "${auth[@]}" -H 'Content-Type: application/json' -d '{"data":{"password":"one"}}' | jq -e '.version == 1' >/dev/null
api -X PUT "$BASE/v1/secrets/app/db" "${auth[@]}" -H 'Content-Type: application/json' -d '{"data":{"password":"two"}}' | jq -e '.version == 2' >/dev/null
api "$NODE2/v1/secrets/app/db?version=1" "${auth[@]}" | jq -e '.data.password == "one"' >/dev/null
api "$NODE3/v1/secrets/app/db" "${auth[@]}" | jq -e '.data.password == "two"' >/dev/null

echo "policy and revoke"
api -X PUT "$BASE/v1/policies/app-read" "${auth[@]}" -H 'Content-Type: application/json' -d '{"rules":[{"path":"secret/app/*","capabilities":["read"]}]}' >/dev/null
limited="$(api -X POST "$BASE/v1/auth/tokens" "${auth[@]}" -H 'Content-Type: application/json' -d '{"policies":["app-read"],"ttl":300}' | jq -r .token)"
curl -fsS "$BASE/v1/secrets/app/db" -H "Authorization: Bearer $limited" >/dev/null
[[ "$(curl -s -o /tmp/strongbox-policy.out -w '%{http_code}' -X PUT "$BASE/v1/secrets/app/db" -H "Authorization: Bearer $limited" -H 'Content-Type: application/json' -d '{"data":{"x":1}}')" == "403" ]]
api -X POST "$BASE/v1/auth/revoke" "${auth[@]}" -H 'Content-Type: application/json' -d "$(jq -nc --arg token "$limited" '{token:$token}')" >/dev/null
[[ "$(curl -s -o /tmp/strongbox-revoked.out -w '%{http_code}' "$NODE2/v1/auth/self" -H "Authorization: Bearer $limited")" == "401" ]]

echo "dynamic postgres"
dyn="$(api "$BASE/v1/dynamic-postgres/readonly" "${auth[@]}")"
lease="$(printf '%s' "$dyn" | jq -r .lease.id)"
user="$(printf '%s' "$dyn" | jq -r .username)"
docker compose exec -T postgres psql -U strongbox_admin -d appdb -tAc "select count(*) from pg_roles where rolname = '$user'" | grep -qx 1
api -X POST "$BASE/v1/leases/$lease/revoke" "${auth[@]}" >/dev/null
docker compose exec -T postgres psql -U strongbox_admin -d appdb -tAc "select count(*) from pg_roles where rolname = '$user'" | grep -qx 0

echo "audit verify"
docker compose exec -T node1 /opt/strongbox/bin/strongbox-verify /var/log/strongbox/audit.log

echo "ok"
