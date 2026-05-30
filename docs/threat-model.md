# StrongBox Threat Model

## What we protect against

<!-- TODO (assign to a person): fill in threat model -->

- Secrets at rest: encrypted with per-secret DEK, DEK wrapped by in-memory KEK
- Insider access to disk: KEK never written to disk; attacker with disk access cannot decrypt
- Replay of audit entries: HMAC chain makes insertion/deletion/modification detectable
- Stolen token: instant revocation, no cache window
- Single-node compromise: Shamir K-of-N prevents single-node unseal
- Brute-force passwords: Argon2id with configured cost parameters

## What we do NOT protect against

- Attacker with full memory access to an unsealed node (KEK is in memory)
- Compromise of all K unseal share holders simultaneously
- Denial of service attacks
- Side-channel attacks on the cryptographic operations
- Kubernetes / orchestration-layer attacks (we run on raw Docker Compose)

## Nonce strategy

AES-256-GCM with 96-bit random nonces from /dev/urandom.
Collision probability is negligible for expected secret counts (< 2^32 encryptions per KEK lifetime).
The KEK is rotated on every seal/unseal cycle.

## Election protocol

<!-- TODO (Person 4): describe your election protocol (200-400 words) -->

## DB-unreachable revocation

<!-- TODO (Person 3): describe revocation_pending retry behaviour -->

## Seal/unseal memory hygiene

<!-- TODO (Person 1): describe what is zeroed, when, and how you verified it -->
