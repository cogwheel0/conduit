//! The wire contract between the Dart daemon `conduitd` and the desktop app:
//! JSON-RPC 2.0 over a loopback WebSocket.
//!
//! Most of this crate is generated from `packages/conduit_protocol` by
//! `tool/generate_rust.dart` (into `generated.rs`): one serde struct per DTO,
//! one enum per Dart enum, a zero-sized type per method in [`methods`], the
//! [`Event`] enum, [`ErrorCode`] and the [`METHODS`] and [`EVENTS`] tables.
//! The rest is written here: the [`RpcMethod`] trait, the JSON-RPC frames,
//! [`RpcError`] and the transport's constants.
//!
//! The crate is plain data. It knows nothing of sockets, threads or GPUI;
//! the client that drives a connection lives elsewhere.
//!
//! # Calling a method
//!
//! ```
//! use conduit_protocol::{ChatRef, Request, Response, RpcMethod, methods};
//!
//! // The method's type fixes the name, the params and the result.
//! let request = Request::call::<methods::ChatsGet>(7, &ChatRef { id: "c1".into() }).unwrap();
//! assert_eq!(request.method, "chats.get");
//!
//! // The reply decodes as that method's result, or as the daemon's error.
//! let frame = r#"{"jsonrpc":"2.0","id":7,"result":{"chat":null}}"#;
//! let response: Response = serde_json::from_str(frame).unwrap();
//! let result = response.into_result::<methods::ChatsGet>().unwrap();
//! assert_eq!(result.chat, None);
//! ```
//!
//! # Handling an event
//!
//! ```
//! use conduit_protocol::{Event, EventEnvelope};
//!
//! let frame = r#"{"event":"turn.delta","seq":3,"scope":"c1",
//!     "payload":{"chatId":"c1","messageId":"m1","text":"Hel"}}"#;
//! let envelope: EventEnvelope = serde_json::from_str(frame).unwrap();
//! match Event::try_from(envelope).unwrap() {
//!     Event::TurnDelta(delta) => assert_eq!(delta.text, "Hel"),
//!     Event::Unknown { name, .. } => println!("newer daemon: {name}"),
//!     _ => {}
//! }
//! ```

mod error;
mod generated;
mod rpc;
mod transport;

pub use error::RpcError;
pub use generated::*;
pub use rpc::{
    ErrorObject, EventSpec, JSONRPC_VERSION, Message, MethodSpec, NoParams, NoResult, Request,
    Response, RpcMethod,
};
pub use transport::{APP_ORIGIN, EVENT_NOTIFICATION, SUBPROTOCOL, routes, subprotocols};

impl TryFrom<EventEnvelope> for Event {
    type Error = serde_json::Error;

    /// Decodes the envelope's payload as the event it names.
    fn try_from(envelope: EventEnvelope) -> serde_json::Result<Self> {
        Self::decode(&envelope.event, envelope.payload)
    }
}

impl Event {
    /// Decodes `envelope` without taking it.
    pub fn from_envelope(envelope: &EventEnvelope) -> serde_json::Result<Self> {
        Self::decode(&envelope.event, envelope.payload.clone())
    }

    /// Wraps the event in an envelope, as the daemon sends it.
    pub fn into_envelope(
        self,
        seq: i64,
        scope: Option<String>,
    ) -> serde_json::Result<EventEnvelope> {
        Ok(EventEnvelope {
            payload: self.payload()?,
            event: self.name().to_owned(),
            seq,
            scope,
        })
    }
}
