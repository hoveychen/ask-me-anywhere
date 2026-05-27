# Build the iroh-relay 0.98 binary (the `server` feature is required for the
# `iroh-relay` bin) and ship it on a slim runtime image.
FROM rust:1-bookworm AS build
RUN cargo install iroh-relay --version 0.98.0 --features server --root /out --locked

FROM debian:bookworm-slim
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY --from=build /out/bin/iroh-relay /usr/local/bin/iroh-relay
# Issued Let's Encrypt certs persist here (mount a volume).
VOLUME ["/var/lib/iroh-relay"]
# HTTP (ACME) / HTTPS / QUIC(udp). Metrics 9090 is internal-only by default.
EXPOSE 80 443 7842/udp
ENTRYPOINT ["iroh-relay", "--config-path", "/etc/iroh-relay/relay.toml"]
