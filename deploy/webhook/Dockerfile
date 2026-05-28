# Muvee-targeted ama-webhook image.
#
# `ama serve` is the long-running M5 webhook bridge: joins the configured inbox
# once, exposes POST /push + POST /github/pr, gates them on a bearer token, and
# proxies card pushes into the iroh-doc CRDT for delivery to your devices.
#
# Muvee fronts every project with Traefik (TLS termination + HTTP/8080 forward),
# so this image binds plain HTTP on :8080 — Traefik does the rest.
#
# Build context is the WORKSPACE ROOT, not this directory:
#
#   docker build -f deploy/webhook/Dockerfile -t ama-webhook .
#
# `cargo build -p ama-cli` only walks ama-cli's dep graph (ama-core + clap +
# axum + iroh), so the flutter_app/rust workspace member is not pulled in.

FROM rust:1-bookworm AS build
WORKDIR /src
# Copy just enough of the workspace to build ama-cli reproducibly. The
# flutter_app/rust member is referenced by the original root Cargo.toml but
# pulls in flutter_rust_bridge / cargokit (Flutter-only dependencies we don't
# want inside this image), and isn't in ama-cli's dep graph anyway. We rewrite
# the root workspace manifest to drop that member so the lockfile still
# applies and we can keep `--locked`.
COPY Cargo.toml Cargo.lock ./
COPY crates ./crates
RUN sed -i 's|, *"flutter_app/rust"||; s|"flutter_app/rust", *||' Cargo.toml
# `--locked` is dropped because rewriting the workspace manifest invalidates
# the entries for the excluded member. Cargo still prefers Cargo.lock for
# everything else, so reproducibility is preserved in practice — only the
# ama_bridge-only deps (flutter_rust_bridge, cargokit) get dropped.
RUN cargo build --release -p ama-cli

FROM debian:bookworm-slim
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY --from=build /src/target/release/ama /usr/local/bin/ama

# Configuration is read entirely from the environment by clap's `env =` arg
# bindings, so the entrypoint takes no flags. See deploy/webhook/README.md
# for the full env var list (AMA_TICKET, AMA_TOKEN, AMA_RELAY, ...).
ENV AMA_BIND=0.0.0.0:8080
EXPOSE 8080
ENTRYPOINT ["ama", "serve"]
