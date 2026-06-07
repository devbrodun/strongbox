# StrongBox Architecture

```text
                         operator / platform clients
                                    |
                                    v
                              nginx :8080
                                    |
                 +------------------+------------------+
                 |                  |                  |
                 v                  v                  v
          strongbox node1     strongbox node2     strongbox node3
            :8200 leader        :8200 follower      :8200 follower
                 |                  |                  |
                 +---------- cluster HTTP ------------+
                    /_internal/replicate, write proxy

Per node runtime:

  bin/strongbox
      |
      +-- lib/http.sh        request parsing, routing, sealed/auth/leader guards
      +-- lib/consensus.sh   term, leader hint, quorum, write replication
      +-- lib/auth.sh        opaque tokens, revocation, policy checks
      +-- lib/crypto.sh      per-secret DEK, KEK wrapping, OpenSSL AES-256-GCM CMS
      +-- lib/lease.sh       lease lifecycle and background reaper
      +-- lib/dynamic.sh     PostgreSQL role minting and cleanup
      +-- lib/audit.sh       HMAC hash-chain audit log
      +-- lib/storage.sh     storage interface over JSON records
      +-- lib/shamir.py      Shamir GF(2^8) split/combine only

Persistent state:

  /var/lib/strongbox/
      sys/init              initialized flag, threshold, wrapped KEK
      secrets/              encrypted version records and latest pointers
      auth/                 hashed token records and revocation state
      policies/             path-prefix capability policies
      leases/               active, expired, revoked, revocation_pending leases
      cluster/              current term, voted_for, leader hint
      audit.secret          HMAC key for audit chain verification

Runtime-only state:

  /dev/shm/strongbox-<node>/
      crypto.cmd            private FIFO for the crypto daemon
      crypto.resp.*         short-lived response FIFOs
      unseal.shares         threshold-progress file, removed after unseal

External dependency:

  postgres :5432
      appdb
      dynamic roles named sb_<profile>_<time>_<random>
```

## Main Flows

```text
Init:
  POST /v1/sys/init
      -> generate KEK and master material
      -> wrap KEK with master material
      -> split master material into Shamir shares
      -> create root token and root policy
      -> persist only wrapped KEK and metadata

Unseal:
  POST /v1/sys/unseal {share}
      -> collect threshold shares under /dev/shm
      -> reconstruct master material via lib/shamir.py
      -> unwrap KEK into the per-node crypto daemon process
      -> remove submitted shares

Secret write:
  client -> nginx -> any node PUT /v1/secrets/<path>
      -> follower forwards the original write to the current leader
      -> policy check: write on secret/<path>
      -> random DEK per version
      -> encrypt value with DEK
      -> wrap DEK with active KEK
      -> replicate encrypted record to quorum
      -> commit latest pointer
      -> append audit event

Secret read:
  client -> any unsealed node GET /v1/secrets/<path>?version=N
      -> policy check: read on secret/<path>
      -> unwrap DEK with active KEK
      -> decrypt requested version
      -> create static read lease
      -> append audit event

Dynamic PostgreSQL read:
  client -> node GET /v1/dynamic-postgres/readonly
      -> create random PostgreSQL role and password
      -> grant configured privileges
      -> create dynamic lease with username metadata
      -> return credentials
      -> reaper later revokes grants, terminates sessions, drops role

Audit verification:
  bin/strongbox-verify
      -> read audit.secret
      -> replay audit log from GENESIS
      -> recompute prev_hash and HMAC for each entry
      -> fail with corrupted entry index on mismatch
```
