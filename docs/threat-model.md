# StrongBox Threat Model

StrongBox protects secret values at rest with envelope encryption, authenticates API requests with opaque server-side tokens, and records privileged activity in a tamper-evident audit chain. A sealed node cannot service secret, lease, policy, or auth operations until the operator supplies the configured Shamir threshold of shares.

## Protected

- Disclosure of stored secret ciphertext without the in-memory KEK.
- Reuse of revoked tokens after the revocation request commits.
- Undetected single-entry or middle-entry audit log modification.
- Persistent dynamic PostgreSQL roles after lease expiry when the target database later becomes reachable.
- Minority partitions acknowledging writes without quorum.

## Not Protected

- A fully compromised unsealed node process can read the in-memory KEK and active plaintext during request handling.
- Bash cannot provide hard heap-zeroization guarantees comparable to a memory-safe daemon with locked pages.
- Root on the host can interfere with Docker networking, disks, process memory, and logs.
- TLS certificate issuance and public DNS are deployment concerns outside this repository.
