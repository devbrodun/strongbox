# strongbox

StrongBox is a Bash-first distributed secrets manager engine. It boots sealed, unseals with K-of-N Shamir shares, stores versioned secrets with envelope encryption, enforces opaque bearer-token policies, mints leased PostgreSQL credentials, maintains a tamper-evident audit chain, and runs as a three-node Docker Compose cluster behind Nginx.

## Contents

- [Quick Start](#quick-start)
- [End-To-End Walkthrough](#end-to-end-walkthrough)
- [API Reference](#api-reference)
- [Policies](#policies)
- [Operational Notes](#operational-notes)
- [Architecture](#architecture)
- [Tests](#tests)

## Quick Start

Requirements:

- Docker Compose
- `curl`
- `jq`

> jq is a command-line tool for reading, filtering, and formatting JSON.

Start a fresh local cluster:

```bash
docker compose build
docker compose up -d
```

Public entrypoint through Nginx:

```text
http://127.0.0.1:8080
```

Direct node ports:

```text
node1 http://127.0.0.1:8201
node2 http://127.0.0.1:8202
node3 http://127.0.0.1:8203
```

Useful shell variables for the examples below:

```bash
export SB=http://127.0.0.1:8201
export SB2=http://127.0.0.1:8202
export SB3=http://127.0.0.1:8203
```

Check the API index:

```bash
curl -fsS "$SB/" | jq .
curl -fsS "$SB/v1" | jq .
```

## End-To-End Walkthrough

### 1. Initialize The Cluster

Initialize once. The response contains a root token and five Shamir shares. Store them somewhere safe; the shares are only returned during init.

```bash
INIT=$(curl -fsS -X POST "$SB/v1/sys/init")
export ROOT=$(printf '%s' "$INIT" | jq -r .root_token)
printf '%s\n' "$ROOT"
printf '%s' "$INIT" | jq -r '.shares[]'
```

Expected response shape:

```json
{
  "shares": ["1-...", "2-...", "3-...", "4-...", "5-..."],
  "root_token": "..."
}
```

If the node was already initialized, the endpoint returns:

```json

{"error":"already initialized"} // seems not to be working as expected - returns a 409(mismatch) error - still reasonable though.
```

### 2. Unseal Every Node

The default config requires any three of the five shares. Submit three shares to each node:

```bash
mapfile -t SHARES < <(printf '%s' "$INIT" | jq -r '.shares[0:3][]')

for node in "$SB" "$SB2" "$SB3"; do
  for share in "${SHARES[@]}"; do
    curl -fsS -X POST "$node/v1/sys/unseal" \
      -H 'Content-Type: application/json' \
      -d "$(jq -nc --arg share "$share" '{share:$share}')" | jq .
  done
done
```

Health should now report `sealed: false`:

```bash
curl -fsS "$SB/v1/sys/health" | jq .
curl -fsS "$SB2/v1/sys/health" | jq .
curl -fsS "$SB3/v1/sys/health" | jq .
```

Expected health response:

```json
{
  "sealed": false,
  "leader": "node1",
  "term": 0,
  "node_id": "node1"
}
```

### 3. Write And Read Versioned Secrets

All protected endpoints use opaque bearer tokens:

```bash
AUTH=(-H "Authorization: Bearer $ROOT")
```

Write version 1:

```bash
curl -fsS -X PUT "$SB/v1/secrets/app/db" \
  "${AUTH[@]}" \
  -H 'Content-Type: application/json' \
  -d '{"data":{"user":"app","password":"one"}}' | jq .
```

Write version 2:

```bash
curl -fsS -X PUT "$SB/v1/secrets/app/db" \
  "${AUTH[@]}" \
  -H 'Content-Type: application/json' \
  -d '{"data":{"user":"app","password":"two"}}' | jq .
```

Read the latest version:

```bash
curl -fsS "$SB2/v1/secrets/app/db" "${AUTH[@]}" | jq .
```

Read a specific version:

```bash
curl -fsS "$SB3/v1/secrets/app/db?version=1" "${AUTH[@]}" | jq .
```

Secret reads return a static lease:

```json
{
  "data": {"user": "app", "password": "one"},
  "version": 1,
  "lease": {"id": "...", "state": "active", "ttl": 60}
}
```

### 4. Create A Read-Only Policy And Token

Policies contain path rules and capabilities. This policy can only read secrets under `secret/app/`.

```bash
curl -fsS -X PUT "$SB/v1/policies/app-read" \
  "${AUTH[@]}" \
  -H 'Content-Type: application/json' \
  -d '{"rules":[{"path":"secret/app/*","capabilities":["read"]}]}' | jq .
```

Mint a short-lived token attached to that policy:

```bash
APP_TOKEN=$(curl -fsS -X POST "$SB/v1/auth/tokens" \
  "${AUTH[@]}" \
  -H 'Content-Type: application/json' \
  -d '{"policies":["app-read"],"ttl":300}' | jq -r .token)
```

Read succeeds:

```bash
curl -fsS "$SB/v1/secrets/app/db" \
  -H "Authorization: Bearer $APP_TOKEN" | jq .
```

Write fails with `403`:

```bash
curl -sS -o /tmp/strongbox-denied.json -w '%{http_code}\n' \
  -X PUT "$SB/v1/secrets/app/db" \
  -H "Authorization: Bearer $APP_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"data":{"password":"blocked"}}'
cat /tmp/strongbox-denied.json | jq .
```

### 5. Inspect And Revoke Tokens

Inspect the current token:

```bash
curl -fsS "$SB/v1/auth/self" \
  -H "Authorization: Bearer $APP_TOKEN" | jq .
```

Revoke the limited token:

```bash
curl -fsS -X POST "$SB/v1/auth/revoke" \
  "${AUTH[@]}" \
  -H 'Content-Type: application/json' \
  -d "$(jq -nc --arg token "$APP_TOKEN" '{token:$token}')"
```

The revoked token should now fail:

```bash
curl -sS -o /tmp/strongbox-revoked.json -w '%{http_code}\n' \
  "$SB/v1/auth/self" \
  -H "Authorization: Bearer $APP_TOKEN"
cat /tmp/strongbox-revoked.json | jq .
```

### 6. Mint And Revoke Dynamic PostgreSQL Credentials

The compose stack includes PostgreSQL. The built-in dynamic role is `readonly`.

```bash
DYN=$(curl -fsS "$SB/v1/dynamic-postgres/readonly" "${AUTH[@]}")
printf '%s' "$DYN" | jq .

PG_USER=$(printf '%s' "$DYN" | jq -r .username)
PG_PASS=$(printf '%s' "$DYN" | jq -r .password)
PG_LEASE=$(printf '%s' "$DYN" | jq -r .lease.id)
```

Use the leased credentials from the Postgres container:

```bash
docker compose exec -T \
  -e PGPASSWORD="$PG_PASS" \
  postgres psql \
  -h 127.0.0.1 \
  -U "$PG_USER" \
  -d appdb \
  -c 'select current_user;'
```

Confirm the role exists:

```bash
docker compose exec -T postgres psql \
  -U strongbox_admin \
  -d appdb \
  -tAc "select count(*) from pg_roles where rolname = '$PG_USER'"
```

Revoke the lease and drop the dynamic role:

```bash
curl -fsS -X POST "$SB/v1/leases/$PG_LEASE/revoke" "${AUTH[@]}"

docker compose exec -T postgres psql \
  -U strongbox_admin \
  -d appdb \
  -tAc "select count(*) from pg_roles where rolname = '$PG_USER'"
```

### 7. Query And Verify Audit Logs

Query audit events through the API:

```bash
curl -fsS "$SB/v1/audit" "${AUTH[@]}" | jq .
```

Filter by token id:

```bash
ROOT_ID=$(curl -fsS "$SB/v1/auth/self" "${AUTH[@]}" | jq -r .token_id)
curl -fsS "$SB/v1/audit?token=$ROOT_ID" "${AUTH[@]}" | jq .
```

Verify the tamper-evident audit chain on a node:

```bash
docker compose exec node1 \
  /opt/strongbox/bin/strongbox-verify /var/log/strongbox/audit.log
```

### 8. Delete And Seal

Delete marks a secret as deleted. Previous encrypted versions remain in storage, but the API no longer serves the secret.

```bash
curl -fsS -X DELETE "$SB/v1/secrets/app/db" "${AUTH[@]}"
```

Seal a node:

```bash
curl -fsS -X POST "$SB/v1/sys/seal" "${AUTH[@]}"
curl -fsS "$SB/v1/sys/health" | jq .
```

After sealing, protected operations on that node return:

```json
{"error":"strongbox is sealed"}
```

Unseal the node again by submitting the threshold shares to `POST /v1/sys/unseal`.

## API Reference

### Conventions

Protected endpoints require:

```http
Authorization: Bearer <token>
```

JSON request bodies require:

```http
Content-Type: application/json
```

Successful JSON responses use `Content-Type: application/json`. `204` responses have an empty body.

Common errors:

| Status | Meaning |
| --- | --- |
| `400` | Invalid request body, missing required field, not initialized, or non-renewable lease. |
| `401` | Missing, invalid, expired, or revoked bearer token. |
| `403` | Token policy does not allow the requested capability/path. |
| `404` | Route, policy, secret, version, token, or lease was not found. |
| `409` | Write was sent to a follower or init was called after initialization. |
| `503` | Node is sealed, write quorum is unavailable, or PostgreSQL is unavailable. |

Writes should be sent to the current leader. If a follower receives a write, it returns:

```json
{
  "leader": "node1",
  "leader_url": "http://node1:8200",
  "error": "not leader"
}
```

### Public Discovery

#### `GET /`

Returns the service index.

```bash
curl -fsS "$SB/" | jq .
```

Response:

```json
{
  "service": "strongbox",
  "status": "ok",
  "api": "/v1",
  "health": "/v1/sys/health"
}
```

#### `GET /v1`

Returns top-level API groups.

```bash
curl -fsS "$SB/v1" | jq .
```

#### `GET /v1/sys`

Returns system routes.

```bash
curl -fsS "$SB/v1/sys" | jq .
```

#### `GET /v1/secrets`

Returns secret routes.

```bash
curl -fsS "$SB/v1/secrets" | jq .
```

#### `GET /v1/dynamic-postgres`

Returns dynamic PostgreSQL routes and supported roles.

```bash
curl -fsS "$SB/v1/dynamic-postgres" | jq .
```

#### `GET /v1/auth`

Returns auth routes.

```bash
curl -fsS "$SB/v1/auth" | jq .
```

#### `GET /v1/policies`

Returns policy routes.

```bash
curl -fsS "$SB/v1/policies" | jq .
```

#### `GET /v1/leases`

Returns lease routes and states.

```bash
curl -fsS "$SB/v1/leases" | jq .
```

#### `GET /v1/audit/`

Returns audit routes. Use the trailing slash for the route index; `GET /v1/audit` queries audit entries.

```bash
curl -fsS "$SB/v1/audit/" | jq .
```

### System

#### `GET /v1/sys/health`

Returns seal and leader state. This endpoint does not require auth.

```bash
curl -fsS "$SB/v1/sys/health" | jq .
```

Response:

```json
{
  "sealed": false,
  "leader": "node1",
  "term": 0,
  "node_id": "node1"
}
```

#### `POST /v1/sys/init`

Initializes an uninitialized cluster. This endpoint does not require auth and can only be called once per state directory.

```bash
curl -fsS -X POST "$SB/v1/sys/init" | jq .
```

Response:

```json
{
  "shares": ["1-...", "2-...", "3-...", "4-...", "5-..."],
  "root_token": "..."
}
```

The threshold and share count come from `config.yaml`:

```yaml
seal:
  threshold: 3
  shares: 5
```

#### `POST /v1/sys/unseal`

Submits one Shamir share. This endpoint does not require auth.

Request:

```json
{"share":"1-..."}
```

Example:

```bash
curl -fsS -X POST "$SB/v1/sys/unseal" \
  -H 'Content-Type: application/json' \
  -d '{"share":"1-..."}' | jq .
```

Response before the threshold is met:

```json
{
  "sealed": true,
  "progress": "1/3"
}
```

Response after the threshold is met:

```json
{
  "sealed": false,
  "progress": "3/3"
}
```

#### `POST /v1/sys/seal`

Purges the active KEK from the node and returns it to sealed mode.

Required capability:

| Capability | Path |
| --- | --- |
| `sudo` | `sys/seal` |

Example:

```bash
curl -fsS -X POST "$SB/v1/sys/seal" "${AUTH[@]}"
```

Response: `204 No Content`.

### Secrets

Secret API paths are arbitrary slash-delimited paths under `/v1/secrets/`. Policy checks use the logical path `secret/<path>`.

#### `PUT /v1/secrets/{path}`

Writes a new version of a secret.

Required capability:

| Capability | Path |
| --- | --- |
| `write` | `secret/{path}` |

Request:

```json
{
  "data": {
    "username": "app",
    "password": "secret"
  }
}
```

Example:

```bash
curl -fsS -X PUT "$SB/v1/secrets/app/db" \
  "${AUTH[@]}" \
  -H 'Content-Type: application/json' \
  -d '{"data":{"username":"app","password":"secret"}}' | jq .
```

Response:

```json
{"version":1}
```

Notes:

- Each write creates a new integer version.
- The `data` field can be any JSON value except `null`.
- Writes require the current node to be leader and to reach write quorum.

#### `GET /v1/secrets/{path}`

Reads the latest secret version.

Required capability:

| Capability | Path |
| --- | --- |
| `read` | `secret/{path}` |

Example:

```bash
curl -fsS "$SB/v1/secrets/app/db" "${AUTH[@]}" | jq .
```

Response:

```json
{
  "data": {"username": "app", "password": "secret"},
  "version": 1,
  "lease": {"id": "...", "state": "active", "ttl": 60}
}
```

#### `GET /v1/secrets/{path}?version=N`

Reads a specific secret version.

Example:

```bash
curl -fsS "$SB/v1/secrets/app/db?version=1" "${AUTH[@]}" | jq .
```

#### `DELETE /v1/secrets/{path}`

Marks a secret as deleted.

Required capability:

| Capability | Path |
| --- | --- |
| `delete` | `secret/{path}` |

Example:

```bash
curl -fsS -X DELETE "$SB/v1/secrets/app/db" "${AUTH[@]}"
```

Response: `204 No Content`.

### Policies

Policies are JSON documents with a `rules` array. Each rule grants capabilities over an exact path or a prefix wildcard ending in `*`.

Supported capabilities:

| Capability | Meaning |
| --- | --- |
| `read` | Read secrets, policies, dynamic credentials, or audit entries. |
| `write` | Write secrets. |
| `delete` | Delete secrets. |
| `sudo` | Administrative capability. Also satisfies any capability check. |

#### `PUT /v1/policies/{name}`

Creates or replaces a policy.

Required capability:

| Capability | Path |
| --- | --- |
| `sudo` | `policies/{name}` |

Example:

```bash
curl -fsS -X PUT "$SB/v1/policies/app-read" \
  "${AUTH[@]}" \
  -H 'Content-Type: application/json' \
  -d '{"rules":[{"path":"secret/app/*","capabilities":["read"]}]}' | jq .
```

Response:

```json
{"ok":true}
```

More policy examples:

```json
{
  "rules": [
    {"path": "secret/app/*", "capabilities": ["read", "write"]},
    {"path": "dynamic-postgres/readonly", "capabilities": ["read"]},
    {"path": "audit", "capabilities": ["read"]}
  ]
}
```

#### `GET /v1/policies/{name}`

Reads a policy.

Required capability:

| Capability | Path |
| --- | --- |
| `read` | `policies/{name}` |

Example:

```bash
curl -fsS "$SB/v1/policies/app-read" "${AUTH[@]}" | jq .
```

### Auth

Tokens are opaque bearer tokens. StrongBox stores token hashes, policy names, expiry time, and revocation state.

#### `POST /v1/auth/tokens`

Creates a token.

Required capability:

| Capability | Path |
| --- | --- |
| `sudo` | `auth/tokens` |

Request:

```json
{
  "policies": ["app-read"],
  "ttl": 300
}
```

Example:

```bash
curl -fsS -X POST "$SB/v1/auth/tokens" \
  "${AUTH[@]}" \
  -H 'Content-Type: application/json' \
  -d '{"policies":["app-read"],"ttl":300}' | jq .
```

Response:

```json
{
  "token": "...",
  "token_id": "...",
  "policies": ["app-read"]
}
```

#### `GET /v1/auth/self`

Inspects the current token.

Example:

```bash
curl -fsS "$SB/v1/auth/self" "${AUTH[@]}" | jq .
```

Response:

```json
{
  "token_id": "...",
  "policies": ["root"],
  "ttl": 315359999
}
```

#### `POST /v1/auth/revoke`

Revokes a token by token value.

This route requires a valid bearer token and must be sent to the leader. It does not currently check a specific policy capability.

Request:

```json
{"token":"..."}
```

Example:

```bash
curl -fsS -X POST "$SB/v1/auth/revoke" \
  "${AUTH[@]}" \
  -H 'Content-Type: application/json' \
  -d '{"token":"..."}'
```

Response: `204 No Content`.

#### `POST /v1/auth/login`

Logs in with username and password.

This route does not require a bearer token, but the node must be unsealed.

Request:

```json
{
  "username": "alice",
  "password": "password"
}
```

Example:

```bash
curl -fsS -X POST "$SB/v1/auth/login" \
  -H 'Content-Type: application/json' \
  -d '{"username":"alice","password":"password"}' | jq .
```

Response:

```json
{
  "token": "...",
  "policies": ["..."]
}
```

Note: the code supports this route when user records exist in storage, but the current public API does not include a user creation endpoint. The root-token flow above is the default local workflow.

### Dynamic PostgreSQL

#### `GET /v1/dynamic-postgres/{role}`

Creates leased PostgreSQL credentials. The local config supports `readonly`.

Required capability:

| Capability | Path |
| --- | --- |
| `read` | `dynamic-postgres/{role}` |

Example:

```bash
curl -fsS "$SB/v1/dynamic-postgres/readonly" "${AUTH[@]}" | jq .
```

Response:

```json
{
  "username": "sb_readonly_...",
  "password": "...",
  "lease": {
    "id": "...",
    "state": "active",
    "ttl": 60
  }
}
```

The default grant SQL is configured in `config.yaml`:

```yaml
postgres:
  readonly_grants: "GRANT CONNECT ON DATABASE appdb TO %USER%; GRANT USAGE ON SCHEMA public TO %USER%; GRANT SELECT ON ALL TABLES IN SCHEMA public TO %USER%;"
```

### Leases

Secret reads create static leases. Dynamic PostgreSQL reads create dynamic leases that can revoke database roles.

Lease states:

| State | Meaning |
| --- | --- |
| `active` | Lease is valid. |
| `expired` | Lease reached expiry and cleanup finished. |
| `revoked` | Lease was manually revoked. |
| `revocation_pending` | Cleanup failed and the reaper will retry. |

#### `POST /v1/leases/{id}/renew`

Renews an active, unexpired lease up to the configured max TTL.

This route requires a valid bearer token. It does not currently check a specific policy capability.

Example:

```bash
curl -fsS -X POST "$SB/v1/leases/$LEASE_ID/renew" "${AUTH[@]}" | jq .
```

Response:

```json
{"new_ttl":60}
```

#### `POST /v1/leases/{id}/revoke`

Revokes a lease.

This route requires a valid bearer token. It does not currently check a specific policy capability.

Example:

```bash
curl -fsS -X POST "$SB/v1/leases/$LEASE_ID/revoke" "${AUTH[@]}"
```

Response: `204 No Content`.

### Audit

#### `GET /v1/audit`

Returns audit entries.

Required capability:

| Capability | Path |
| --- | --- |
| `read` | `audit` |

Example:

```bash
curl -fsS "$SB/v1/audit" "${AUTH[@]}" | jq .
```

Response:

```json
[
  {
    "ts": "2026-06-04T12:00:00Z",
    "token": "anonymous",
    "op": "sys.init",
    "path": "/v1/sys/init",
    "status": 201
  }
]
```

#### `GET /v1/audit?token={token_id}`

Filters audit entries by token id.

Example:

```bash
curl -fsS "$SB/v1/audit?token=$ROOT_ID" "${AUTH[@]}" | jq .
```

### Internal Cluster API

These endpoints are for node-to-node traffic inside the compose network. They are documented for completeness, but clients should not call them directly.

| Method | Path | Purpose |
| --- | --- | --- |
| `GET` | `/_internal/health` | Returns node health for peer discovery. |
| `POST` | `/_internal/replicate` | Applies replicated storage mutations. |
| `POST` | `/_internal/vote` | Handles election vote requests. |
| `POST` | `/_internal/heartbeat` | Handles leader heartbeats. |

## Policies

The root policy created during init is:

```json
{
  "rules": [
    {
      "path": "*",
      "capabilities": ["read", "write", "delete", "sudo"]
    }
  ]
}
```

Policy path examples:

| Resource | Policy path |
| --- | --- |
| Secret `app/db` | `secret/app/db` |
| All app secrets | `secret/app/*` |
| Policy `app-read` | `policies/app-read` |
| Token creation | `auth/tokens` |
| Dynamic readonly credentials | `dynamic-postgres/readonly` |
| Audit log query | `audit` |
| Seal operation | `sys/seal` |

`sudo` satisfies any capability check, so use it sparingly.

## Operational Notes

### Leader And Quorum

Node `node1` is the bootstrap leader. Writes require the current leader and a majority of configured nodes. Reads may be served by followers and can be stale relative to a just-committed leader write.

During a 2-1 partition, the majority side can elect a leader and continue writes. The minority side cannot satisfy quorum and refuses writes.

### Dynamic Revocation

Dynamic PostgreSQL reads create a role, grant the configured profile, and attach the role name to a lease. Manual revoke or expiry runs `REVOKE`, terminates active sessions for the role, and `DROP ROLE`. If PostgreSQL is unreachable, the lease becomes `revocation_pending`; the background reaper retries with exponential backoff until cleanup succeeds.

### Seal Hygiene

Nodes boot without a KEK. Init returns shares once and stores only the KEK wrapped by the reconstructed master material. Unseal shares are held in `/dev/shm`, reconstructed with the short-lived Shamir helper, then the share file is truncated and removed. The active KEK is held by the per-node crypto daemon and is purged by `POST /v1/sys/seal`. Bash cannot provide hard heap zeroization guarantees, so StrongBox avoids logs, persistent temp files, exported sensitive variables, and long-lived plaintext buffers where practical.

### Local State

Compose stores data in named volumes:

```text
pgdata
node1-state
node2-state
node3-state
node1-log
node2-log
node3-log
```

To start from scratch, stop the stack and remove volumes:

```bash
docker compose down -v
```

## Architecture

See [docs/architecture.md](docs/architecture.md) for the component sketch and request flows.

The server entrypoint is [bin/strongbox](bin/strongbox). Request parsing and API routing live in [lib/http.sh](lib/http.sh). Storage goes through [lib/storage.sh](lib/storage.sh), which persists JSON records behind a small interface that can be swapped for another backend.

Secrets are encrypted in [lib/crypto.sh](lib/crypto.sh). Each secret version gets a random DEK. The DEK is wrapped by the unsealed KEK. AES-256-GCM is provided by the OpenSSL CLI through CMS encrypted data. The nonce is generated internally by OpenSSL CMS for every encryption operation.

Shamir split/combine is isolated to [lib/shamir.py](lib/shamir.py). Bash owns the platform logic; Python is only used for GF(2^8) arithmetic.

## Tests

Run the integration smoke test against a fresh compose stack:

```bash
chmod +x test/integration/run.sh
test/integration/run.sh
```

The script initializes the cluster, unseals every node, checks secret versioning, verifies policy denial and token revocation, mints and revokes dynamic PostgreSQL credentials, and verifies the audit log.

## Threat Model

See [docs/threat-model.md](docs/threat-model.md).
