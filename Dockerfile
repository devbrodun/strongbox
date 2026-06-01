FROM debian:12-slim

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
      argon2 \
      bash \
      ca-certificates \
      coreutils \
      curl \
      gawk \
      iproute2 \
      jq \
      netcat-openbsd \
      openssl \
      postgresql-client \
      procps \
      python3 \
      socat \
      uuid-runtime \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/strongbox
COPY . /opt/strongbox
RUN chmod +x /opt/strongbox/bin/strongbox /opt/strongbox/bin/strongbox-verify

ENTRYPOINT ["/opt/strongbox/bin/strongbox"]
