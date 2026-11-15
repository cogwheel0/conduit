//! The wire contract, from the generated `conduit-protocol` crate, plus the
//! client's own transport codes.
//!
//! Every method is a type in [`methods`] (`RpcClient::call::<M>`), every
//! event a variant of [`Event`] (`Event::try_from(envelope)`). This module
//! re-exports what the client and the app use, and adds the codes for
//! failures that happen on this side of the socket, which the daemon never
//! sends.

use serde_json::Value;

pub use conduit_protocol::{
    APP_ORIGIN, EVENT_NOTIFICATION, ErrorCode, ErrorObject, Event, EventEnvelope, HandshakeRequest,
    HandshakeResponse, NoParams, NoResult, PROTOCOL_VERSION, RpcError, RpcMethod, SUBPROTOCOL,
    WindowKind, events, methods,
};

/// Error codes as strings: the daemon's (`ConduitErrorCodes`) and the
/// client's own transport codes, which ride in [`ErrorCode::Other`].
pub mod codes {
    pub const INTERNAL: &str = "rpc.internal";
    pub const METHOD_NOT_FOUND: &str = "rpc.methodNotFound";
    pub const INVALID_PARAMS: &str = "rpc.invalidParams";
    pub const PROTOCOL_VIOLATION: &str = "rpc.protocolViolation";
    pub const PROTOCOL_VERSION_MISMATCH: &str = "rpc.protocolVersionMismatch";
    pub const TIMEOUT: &str = "rpc.timeout";
    pub const DAEMON_UNAVAILABLE: &str = "rpc.daemonUnavailable";
    pub const SHUTTING_DOWN: &str = "rpc.shuttingDown";
    /// Client-side: the socket dropped while the call was in flight. The
    /// daemon may or may not have run it, so it is not retried blindly.
    pub const DISCONNECTED: &str = "transport.disconnected";
    /// Client-side: the client was shut down, or gave up reconnecting.
    pub const CLOSED: &str = "transport.closed";
    /// Client-side: an HTTP request failed below the daemon's error layer.
    pub const HTTP: &str = "transport.http";
    /// Client-side: a result did not decode into the expected type.
    pub const DECODE: &str = "transport.decode";
}

/// An error with `code` (any string; unknown ones are kept as
/// [`ErrorCode::Other`]) and a developer-facing message.
pub fn error(code: &str, debug: impl Into<String>) -> RpcError {
    RpcError {
        debug_message: Some(debug.into()),
        ..RpcError::new(ErrorCode::from_code(code))
    }
}

/// What the client needs on top of [`RpcError`].
pub trait RpcErrorExt: Sized {
    /// Whether this is `code`.
    fn is(&self, code: &str) -> bool;
    /// Marks it worth retrying.
    fn retryable(self) -> Self;
}

impl RpcErrorExt for RpcError {
    fn is(&self, code: &str) -> bool {
        self.code.as_str() == code
    }

    fn retryable(mut self) -> Self {
        self.retryable = true;
        self
    }
}

/// Decodes a JSON-RPC `error` object, like Dart's `RpcError.fromException`.
pub fn error_from_wire(error: &Value) -> RpcError {
    match serde_json::from_value::<ErrorObject>(error.clone()) {
        Ok(object) => RpcError::from_error_object(&object),
        Err(e) => self::error(codes::PROTOCOL_VIOLATION, format!("bad error object: {e}")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn constants_come_from_the_generated_crate() {
        assert_eq!(PROTOCOL_VERSION.split('.').count(), 3, "{PROTOCOL_VERSION}");
        assert_eq!(SUBPROTOCOL, "conduit.v1");
        assert_eq!(APP_ORIGIN, "app://conduit");
    }

    #[test]
    fn conduit_errors_decode_from_data() {
        let wire = json!({
            "code": -32000,
            "message": "core starting",
            "data": {"code": "rpc.daemonUnavailable", "retryable": true, "request": {}}
        });
        let e = error_from_wire(&wire);
        assert!(e.is(codes::DAEMON_UNAVAILABLE));
        assert_eq!(e.code, ErrorCode::DaemonUnavailable);
        assert!(e.retryable);
    }

    #[test]
    fn json_rpc_errors_map_to_conduit_codes() {
        let e = error_from_wire(&json!({"code": -32601, "message": "nope"}));
        assert!(e.is(codes::METHOD_NOT_FOUND));
        let e = error_from_wire(&json!({"code": -32700, "message": "bad"}));
        assert!(e.is(codes::PROTOCOL_VIOLATION));
        let e = error_from_wire(&json!({"code": 1, "message": "?"}));
        assert!(e.is(codes::INTERNAL));
    }

    #[test]
    fn transport_codes_survive_as_other() {
        let e = error(codes::DISCONNECTED, "gone").retryable();
        assert!(e.is(codes::DISCONNECTED));
        assert_eq!(e.code, ErrorCode::Other(codes::DISCONNECTED.into()));
        assert!(e.retryable);
    }
}
