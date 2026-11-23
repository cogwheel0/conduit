//! Everything between Conduit Desktop and its Dart daemon `conduitd` that
//! needs no UI toolkit.
//!
//! * [`paths`]: dev vs packaged flavour, userData, logs, the daemon binary,
//!   each OS's known folders.
//! * [`secrets`]: the per-launch session token and the Keychain master key.
//! * [`instance`]: one app per profile on Windows and Linux; a second
//!   launch hands its arguments to the first.
//! * [`network`]: whether Windows and Linux have a network.
//! * [`supervisor`]: spawn, stdin bootstrap, ready line, restart policy,
//!   graceful stop, stderr to rotating logs, child watching.
//! * [`rpc`]: one JSON-RPC 2.0 WebSocket connection per process on a tokio
//!   runtime, bridged to the UI by channels: handshake first, ping, jittered
//!   reconnect with re-subscribe, `rpc.daemonUnavailable` retry.
//! * [`http`]: `/upload` with progress and `/files/{server}/{id}`.
//! * [`protocol`]: the generated `conduit-protocol` crate's types, methods
//!   and events, plus the client's own transport error codes.
//!
//! The UI never touches tokio: calls return runtime-agnostic futures and
//! state arrives on unbounded channels, so a GPUI executor can await them.

#[cfg(target_os = "linux")]
pub mod abstract_socket;
pub mod http;
pub mod instance;
pub mod logs;
pub mod network;
pub mod paths;
pub mod protocol;
pub mod rpc;
pub mod runtime;
pub mod secrets;
pub mod supervisor;
pub mod terminal;

pub use protocol::{Event, EventEnvelope, RpcError, RpcMethod};
pub use rpc::{ClientEvent, ConnectionState, Handshake, RpcClient, RpcConfig};
pub use supervisor::{
    ExitInfo, FatalReason, RestartPolicy, Supervisor, SupervisorConfig, SupervisorEvent,
};
