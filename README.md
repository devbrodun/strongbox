# strongbox

StrongBox is a Bash-first distributed secrets manager engine. It boots sealed, unseals with K-of-N Shamir shares, stores versioned secrets with envelope encryption, enforces opaque bearer-token policies, mints leased PostgreSQL credentials, maintains a tamper-evident audit chain, and runs as a three-node Docker Compose cluster behind Nginx.

## Quick Start

```bash
docker compose build
docker compose up -d
```

Public entrypoint in the local compose file:

```text
http://127.0.0.1:8080
```

Direct node ports:

```text
node1 http://127.0.0.1:8201
node2 http://127.0.0.1:8202
node3 http://127.0.0.1:8203
```

## Init And Unseal

```bash
INIT=$(curl -fsS -X POST http://127.0.0.1:8201/v1/sys/init)
ROOT=$(echo "$INIT" | jq -r .root_token)
echo "$INIT" | jq -r '.shares[]'
```

> jq is a command-line tool for reading, filtering, and formatting JSON.

Submit any three returned shares to every node:

```bash
for node in 8201 8202 8203; do
  for share in $(echo "$INIT" | jq -r '.shares[0:3][]'); do
    curl -fsS -X POST "http://127.0.0.1:$node/v1/sys/unseal" \
      -H 'Content-Type: application/json' \
      -d "{\"share\":\"$share\"}"
  done
done
```

Or manually:

```bash
for node in 8201 8202 8203; do
  for share in \
    "share-1" \
    "share-2" \
    "share-3"
  do
    curl -fsS -X POST "http://127.0.0.1:$node/v1/sys/unseal" \
      -H 'Content-Type: application/json' \
      -d "{\"share\":\"$share\"}"
    echo
  done
done
```

Health:

```bash
curl -fsS http://127.0.0.1:8201/v1/sys/health | jq .
```

```bash
curl -fsS http://127.0.0.1:8202/v1/sys/health | jq .
```

```bash
curl -fsS http://127.0.0.1:8203/v1/sys/health | jq .
```

## API Examples

Write two versions and read both:

```bash
curl -fsS -X PUT http://127.0.0.1:8201/v1/secrets/app/db \
  -H "Authorization: Bearer $ROOT" -H 'Content-Type: application/json' \
  -d '{"data":{"user":"app","password":"one"}}'

curl -fsS -X PUT http://127.0.0.1:8201/v1/secrets/app/db \
  -H "Authorization: Bearer $ROOT" -H 'Content-Type: application/json' \
  -d '{"data":{"user":"app","password":"two"}}'

curl -fsS 'http://127.0.0.1:8202/v1/secrets/app/db?version=1' \
  -H "Authorization: Bearer $ROOT"
```

Create a read-only policy and token:

```bash
curl -fsS -X PUT http://127.0.0.1:8201/v1/policies/app-read \
  -H "Authorization: Bearer $ROOT" -H 'Content-Type: application/json' \
  -d '{"rules":[{"path":"secret/app/*","capabilities":["read"]}]}'

TOKEN=$(curl -fsS -X POST http://127.0.0.1:8201/v1/auth/tokens \
  -H "Authorization: Bearer $ROOT" -H 'Content-Type: application/json' \
  -d '{"policies":["app-read"],"ttl":300}' | jq -r .token)
```

Revoke a token:

```bash
curl -fsS -X POST http://127.0.0.1:8201/v1/auth/revoke \
  -H "Authorization: Bearer $ROOT" -H 'Content-Type: application/json' \
  -d "{\"token\":\"$TOKEN\"}"
```

Mint and revoke dynamic PostgreSQL credentials:

```bash
DYN=$(curl -fsS http://127.0.0.1:8201/v1/dynamic-postgres/readonly \
  -H "Authorization: Bearer $ROOT")
LEASE=$(echo "$DYN" | jq -r .lease.id)

curl -fsS -X POST "http://127.0.0.1:8201/v1/leases/$LEASE/revoke" \
  -H "Authorization: Bearer $ROOT"
```

Verify audit log:

```bash
docker compose exec node1 /opt/strongbox/bin/strongbox-verify /var/log/strongbox/audit.log
```

## Architecture

See [docs/architecture.md](/home/okpainmo/opensource-projects/strongbox/docs/architecture.md) for the component sketch and request flows.

The server entrypoint is [bin/strongbox](/home/okpainmo/opensource-projects/strongbox/bin/strongbox). Request parsing and API routing live in [lib/http.sh](/home/okpainmo/opensource-projects/strongbox/lib/http.sh). Storage goes through [lib/storage.sh](/home/okpainmo/opensource-projects/strongbox/lib/storage.sh), which currently persists JSON records behind a small interface that can be swapped for BoltDB or another backend.

Secrets are encrypted in [lib/crypto.sh](/home/okpainmo/opensource-projects/strongbox/lib/crypto.sh). Each secret version gets a random DEK. The DEK is wrapped by the unsealed KEK. AES-256-GCM is provided by the OpenSSL CLI through CMS encrypted data. The nonce is generated internally by OpenSSL CMS for every encryption operation.

Shamir split/combine is isolated to [lib/shamir.py](/home/okpainmo/opensource-projects/strongbox/lib/shamir.py). Bash owns the platform logic; Python is only used for GF(2^8) arithmetic.

## Election Protocol

StrongBox uses a compact, hand-rolled majority protocol. Each node stores a term and leader hint under its state directory. Node `node1` is the bootstrap leader. Before a write, the receiving node refreshes its leader view and checks that it can reach a majority of configured members. Followers reject writes with the current leader hint. The leader replicates a storage mutation to peers through `/_internal/replicate` and only applies the local mutation after a majority acknowledges. If a leader dies mid-write, the request either fails before quorum or has already reached a majority. During a 2-1 partition, the majority side can elect the lowest reachable node as leader and continue writes; the minority side cannot satisfy quorum and refuses writes.

Reads may be served by followers and can be stale relative to a just-committed leader write.

## Dynamic Revocation

Dynamic PostgreSQL reads create a role, grant the configured profile, and attach the role name to a lease. Manual revoke or expiry runs `REVOKE`, terminates active sessions for the role, and `DROP ROLE`. If PostgreSQL is unreachable, the lease becomes `revocation_pending`; the background reaper retries with exponential backoff until cleanup succeeds.

## Seal Hygiene

Nodes boot without a KEK. Init returns shares once and stores only the KEK wrapped by the reconstructed master material. Unseal shares are held in `/dev/shm`, reconstructed with the short-lived Shamir helper, then the share file is truncated and removed. The active KEK is kept in `/dev/shm/strongbox-<node>/kek.hex` so forked Bash request handlers can decrypt; `POST /v1/sys/seal` truncates and removes it. Bash cannot provide hard heap zeroization guarantees, so StrongBox avoids logs, persistent temp files, exported sensitive variables, and long-lived plaintext buffers.

## Tests

Run the integration smoke test against a fresh compose stack:

```bash
chmod +x test/integration/run.sh
test/integration/run.sh
```

## Threat Model

See [docs/threat-model.md](/home/okpainmo/opensource-projects/strongbox/docs/threat-model.md).
