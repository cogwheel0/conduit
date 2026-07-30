# Codex app-server mobile compatibility overlay

This directory vendors the `codex-app-server` library source from Codex commit
`25af12f7e61572b0bc18ddb1008be543b91519b0` (`rust-v0.145.0`). Its dependency
manifest is normalized so the remaining Codex crates continue to resolve from
that exact commit.

The only behavioral change is in `src/in_process.rs`: Android and iOS fall back
to process-serialized, app-private installation-ID persistence when the
platform reports `ErrorKind::Unsupported` for Codex's advisory file lock. All
other errors and all non-mobile targets retain the upstream behavior.
