# Muvee-targeted iroh-relay image.
#
# Muvee fronts every project with Traefik that handles TLS termination and
# forwards plain HTTP to the container on port 8080. So this image runs the
# relay with no in-container TLS and binds HTTP on 8080 — Traefik does the rest.
#
# Build for linux/amd64 (Muvee's runtime). `--features server` is required for
# the `iroh-relay` binary itself; `--locked` pins the dep graph for repeatable
# builds.
FROM rust:1-bookworm AS build
RUN cargo install iroh-relay --version 0.98.0 --features server --root /out --locked

FROM debian:bookworm-slim
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY --from=build /out/bin/iroh-relay /usr/local/bin/iroh-relay
COPY relay.toml /etc/iroh-relay/relay.toml
EXPOSE 8080
ENTRYPOINT ["iroh-relay", "--config-path", "/etc/iroh-relay/relay.toml"]
