//! Methods as types, and the JSON-RPC 2.0 frames that carry them.

use serde::de::{DeserializeOwned, IgnoredAny};
use serde::ser::SerializeMap;
use serde::{Deserialize, Deserializer, Serialize, Serializer};
use serde_json::Value;

use crate::transport::EVENT_NOTIFICATION;
use crate::{EventEnvelope, RpcError};

/// The `jsonrpc` member of every frame.
pub const JSONRPC_VERSION: &str = "2.0";

/// One RPC method as a type. Every method in [`crate::methods`] implements
/// it, so a call names its method once and gets the params and result types
/// with it.
pub trait RpcMethod {
    /// The method's name on the wire, e.g. `chats.get`.
    const NAME: &'static str;
    /// What it takes; [`NoParams`] for nothing.
    type Params: Serialize + DeserializeOwned;
    /// What it answers with; [`NoResult`] for nothing.
    type Result: Serialize + DeserializeOwned;
}

/// The params of a method that takes none: sent as `{}`, since every Conduit
/// method takes named params. Decodes from anything.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Hash)]
pub struct NoParams;

impl Serialize for NoParams {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_map(Some(0))?.end()
    }
}

impl<'de> Deserialize<'de> for NoParams {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        IgnoredAny::deserialize(deserializer)?;
        Ok(Self)
    }
}

/// The result of a method that answers with nothing: whatever came back is
/// ignored. Encodes as `{}`.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Hash)]
pub struct NoResult;

impl Serialize for NoResult {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_map(Some(0))?.end()
    }
}

impl<'de> Deserialize<'de> for NoResult {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        IgnoredAny::deserialize(deserializer)?;
        Ok(Self)
    }
}

/// One row of [`crate::METHODS`]: a method and its DTOs by Dart name.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct MethodSpec {
    pub name: &'static str,
    /// `None` when the method takes no params.
    pub params: Option<&'static str>,
    /// `None` when it answers with nothing.
    pub result: Option<&'static str>,
}

/// One row of [`crate::EVENTS`]: an event, its payload DTO by Dart name, and
/// whether the daemon publishes it with a scope.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct EventSpec {
    pub name: &'static str,
    /// `None` when the event has no payload.
    pub payload: Option<&'static str>,
    pub scoped: bool,
}

/// A request, or a notification when it has no `id`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Request {
    pub jsonrpc: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub id: Option<Value>,
    pub method: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub params: Option<Value>,
}

impl Request {
    /// A request calling `M` with `params`.
    pub fn call<M: RpcMethod>(id: u64, params: &M::Params) -> serde_json::Result<Self> {
        Ok(Self {
            jsonrpc: JSONRPC_VERSION.to_owned(),
            id: Some(id.into()),
            method: M::NAME.to_owned(),
            params: Some(serde_json::to_value(params)?),
        })
    }

    /// The event this frame carries, when it is the daemon's `event`
    /// notification.
    pub fn event(&self) -> Option<serde_json::Result<EventEnvelope>> {
        if self.id.is_some() || self.method != EVENT_NOTIFICATION {
            return None;
        }
        Some(EventEnvelope::deserialize(
            self.params.as_ref().unwrap_or(&Value::Null),
        ))
    }
}

/// The `error` member of a failed response.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ErrorObject {
    pub code: i64,
    pub message: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub data: Option<Value>,
}

/// The answer to a request: a `result` or an `error`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Response {
    pub jsonrpc: String,
    pub id: Value,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub result: Option<Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<ErrorObject>,
}

impl Response {
    /// The result decoded as `M`'s, or the daemon's error. A result that
    /// does not decode is an `rpc.internal` error carrying serde's message.
    pub fn into_result<M: RpcMethod>(self) -> Result<M::Result, RpcError> {
        if let Some(error) = self.error {
            return Err(RpcError::from_error_object(&error));
        }
        serde_json::from_value(self.result.unwrap_or(Value::Null)).map_err(|error| {
            RpcError::internal(format!("{}: undecodable result: {error}", M::NAME))
        })
    }
}

/// Any frame the daemon sends: a response to one of the app's requests, or
/// a request or notification of its own (events arrive as the `event`
/// notification; see [`Request::event`]).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum Message {
    Request(Request),
    Response(Response),
}
