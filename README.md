# StrongBox — Distributed Secrets Manager

<!-- TODO: fill in public cluster URL -->
**Cluster URL:** `https://your-domain.example.com`

**GitHub repo:** `https://github.com/your-org/strongbox`

---

## Quick start (grader setup)

```bash
# 1. Clone and deploy
git clone https://github.com/your-org/strongbox
cd strongbox
cp .env.example .env   # fill in POSTGRES_PASSWORD and domain
docker compose up -d

# 2. Initialize (one-time)
curl -s -X POST https://your-domain/v1/sys/init | tee init-output.json
# Save the shares and root_token from init-output.json

# 3. Unseal (submit K=3 shares)
curl -s -X POST https://your-domain/v1/sys/unseal -d '{"share":"<share1>"}'
curl -s -X POST https://your-domain/v1/sys/unseal -d '{"share":"<share2>"}'
curl -s -X POST https://your-domain/v1/sys/unseal -d '{"share":"<share3>"}'

# 4. Create a scoped token for grading
curl -s -X POST https://your-domain/v1/policies/grader \
  -H "Authorization: Bearer <root_token>" \
  -d '{"rules":[{"path":"secret/app/*","capabilities":["read"]}]}'

curl -s -X POST https://your-domain/v1/auth/login \
  -d '{"username":"grader","password":"<password>"}'
```

---

## API examples

<!-- TODO: curl examples for all 10 grading scenarios -->

## Architecture

![Architecture](docs/architecture.png)

<!-- TODO: prose architecture overview -->

## Election protocol

<!-- TODO: 200-400 words on term numbers, vote rules, partition behaviour -->

## DB-unreachable revocation behaviour

<!-- TODO: explain revocation_pending retry with exponential backoff -->

## Seal/unseal memory hygiene

<!-- TODO: what is zeroed, when, and how verified -->

## Threat model

See [docs/threat-model.md](docs/threat-model.md).
