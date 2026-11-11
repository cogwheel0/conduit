# syntax=docker/dockerfile:1
#
# Conduit push relay. Build from the repository root with
#
#   docker build -t conduit-push-relay relay/
#
# The image holds no keys or settings: pass them at run time as environment
# variables or mounted files (docs/push/SELF_HOSTING.md).

FROM rust:1-bookworm AS build
WORKDIR /src

# Dependencies first, in their own layer, so editing the relay's sources
# does not rebuild them. The placeholder crate is thrown away below.
COPY Cargo.toml Cargo.lock ./
RUN mkdir src \
 && echo 'fn main() {}' > src/main.rs \
 && touch src/lib.rs \
 && cargo build --release --locked \
 && rm -rf src

COPY src ./src
# Cleaning the crate's own artifacts makes sure the real sources are built,
# whatever their timestamps.
RUN cargo clean --release --locked -p conduit-push-relay \
 && cargo build --release --locked \
 && install -m 0755 target/release/conduit-push-relay /conduit-push-relay

# glibc, CA certificates and nothing else; no shell. Debian 12 matches the
# build stage's glibc.
FROM gcr.io/distroless/cc-debian12:nonroot
COPY --from=build /conduit-push-relay /usr/local/bin/conduit-push-relay
USER nonroot:nonroot
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/conduit-push-relay"]
