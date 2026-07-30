# Pagable mobile compatibility copy

This directory contains the source of the crates.io `pagable` 0.4.1 crate
used by pinned Codex 0.145.0. It is kept as a source-compatible dependency
override because that release's 32-bit size assertion does not account for
Android ARM's four-byte `AtomicU64` alignment.

Local changes from the published crate are intentionally narrow:

- The target-specific assertion at the end of `src/pagable_arc.rs` expects ten
  `usize` values on 32-bit Android, while other 32-bit targets retain the
  upstream expectation of twelve.
- Deserialization rejects invalid lengths and static-value indexes without
  panicking or reserving attacker-controlled capacity.
- Synchronous paging reports unsupported Tokio runtime contexts as errors.
- Page-out releases concurrent-map guards before blocking and rejects cyclic
  serialization chains instead of deadlocking.
- The in-memory backend uses one shared session context for serialization and
  deserialization.

Upstream: <https://crates.io/crates/pagable/0.4.1>

This copy is redistributed under Apache-2.0; the complete license is at
`../../../third_party/LICENSE-APACHE-2.0`. The upstream MIT alternative is
also retained in `LICENSE-MIT`. See the repository's
`THIRD_PARTY_NOTICES.md` for attribution.
