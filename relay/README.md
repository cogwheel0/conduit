# Conduit push relay

A small, stateless service that turns end-to-end encrypted Web Push into APNs
and FCM pushes for Conduit. The user's own server encrypts every notification
to a key that only exists on the device; the relay forwards ciphertext and
can't read it. It keeps no database and writes no access logs.

- Contract: [`docs/push/PROTOCOL.md`](../docs/push/PROTOCOL.md) §3–§5
- Running your own: [`docs/push/SELF_HOSTING.md`](../docs/push/SELF_HOSTING.md)

## API

| Route | |
|---|---|
| `GET /v1/info` | Protocol version, active seal key id, configured providers |
| `POST /v1/register` | Seals a device token into an endpoint URL |
| `POST /v1/push/{sealed}` | Web Push receiver (`aes128gcm`) that forwards to APNs or FCM |
| `GET /healthz`, `GET /readyz` | Liveness and readiness |
| `GET /metrics` | Prometheus counters, only on `RELAY_METRICS_ADDR` |

## Layout

| Module | |
|---|---|
| `config` | Environment variables |
| `seal` | Sealed endpoints (XChaCha20-Poly1305) |
| `webpush` | Checks on incoming Web Push requests |
| `apns`, `fcm` | Provider clients, credentials and error mapping |
| `ratelimit` | In-memory token buckets |
| `metrics` | Aggregate counters |
| `routes` | The HTTP API |
| `server` | Accept loop: timeouts, connection cap, graceful shutdown |

## Develop

```bash
cargo fmt --check
cargo clippy --all-targets --locked -- -D warnings
cargo test --locked
```

The integration tests in `tests/relay.rs` run the real router against mock
APNs, FCM and OAuth servers on 127.0.0.1, with signing keys generated at test
time. Request validation is checked against the shared vectors in
[`push/test-vectors/`](../push/test-vectors).

```bash
docker build -t conduit-push-relay .
```
