# Dockerfile
# OWNER: Person 4 (Cluster, HTTP & Infrastructure)
FROM ubuntu:24.04

RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    openssl \
    argon2 \
    python3 \
    python3-pip \
    socat \
    netcat-openbsd \
    postgresql-client \
    xxd \
    curl \
    jq \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY . /app/

RUN chmod +x bin/strongbox bin/strongbox-verify lib/shamir.py

# TODO: set ENTRYPOINT / CMD
# ENTRYPOINT ["/app/bin/strongbox"]

EXPOSE 8200
