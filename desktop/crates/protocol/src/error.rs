//! Failures crossing the daemon boundary.

use std::collections::BTreeMap;
use std::convert::Infallible;
use std::fmt;
use std::str::FromStr;

use serde::{Deserialize, Deserializer, Serialize, Serializer};
use serde_json::Value;

use crate::{ErrorCode, ErrorObject};

/// A failure from the daemon, as `rpc_error.dart` defines it.
///
/// Every Conduit failure travels as JSON-RPC error code
/// [`RpcError::JSON_RPC_CODE`] with this in `data`: a stable [`ErrorCode`]
/// the app localizes, with `args` for its placeholders. The daemon has no
/// locale, so it never sends prose; `debug_message` is for logs only.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RpcError {
    pub code: ErrorCode,
    /// Placeholder values for the localized message, all strings.
    #[serde(default)]
    pub args: BTreeMap<String, String>,
    /// Developer-facing detail for the diagnostics log. Never shown.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub debug_message: Option<String>,
    /// Whether retrying the same request could succeed.
    #[serde(default)]
    pub retryable: bool,
}

impl RpcError {
    /// The JSON-RPC error code every Conduit failure rides on.
    pub const JSON_RPC_CODE: i64 = -32000;

    pub fn new(code: ErrorCode) -> Self {
        Self {
            code,
            args: BTreeMap::new(),
            debug_message: None,
            retryable: false,
        }
    }

    /// An `rpc.internal` error with `debug_message`.
    pub fn internal(debug_message: impl Into<String>) -> Self {
        Self {
            debug_message: Some(debug_message.into()),
            ..Self::new(ErrorCode::Internal)
        }
    }

    /// Reads a JSON-RPC error. A Conduit error comes back as it was sent
    /// (the extra `request` key `json_rpc_2` adds to `data` is ignored);
    /// anything else maps the standard codes, as `RpcError.fromException`
    /// does in Dart.
    pub fn from_error_object(error: &ErrorObject) -> Self {
        if error.code == Self::JSON_RPC_CODE
            && let Some(data @ Value::Object(_)) = &error.data
            && let Ok(decoded) = Self::deserialize(data)
        {
            return decoded;
        }
        let code = match error.code {
            -32601 => ErrorCode::MethodNotFound,
            -32602 => ErrorCode::InvalidParams,
            -32700 | -32600 => ErrorCode::ProtocolViolation,
            _ => ErrorCode::Internal,
        };
        Self {
            debug_message: Some(error.message.clone()),
            ..Self::new(code)
        }
    }

    /// This error as the daemon would send it.
    pub fn to_error_object(&self) -> ErrorObject {
        ErrorObject {
            code: Self::JSON_RPC_CODE,
            message: self
                .debug_message
                .clone()
                .unwrap_or_else(|| self.code.to_string()),
            data: serde_json::to_value(self).ok(),
        }
    }
}

impl fmt::Display for RpcError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match &self.debug_message {
            Some(message) => write!(f, "{}: {message}", self.code),
            None => write!(f, "{}", self.code),
        }
    }
}

impl std::error::Error for RpcError {}

impl fmt::Display for ErrorCode {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

impl FromStr for ErrorCode {
    type Err = Infallible;

    fn from_str(code: &str) -> Result<Self, Infallible> {
        Ok(Self::from_code(code))
    }
}

impl From<&str> for ErrorCode {
    fn from(code: &str) -> Self {
        Self::from_code(code)
    }
}

impl Serialize for ErrorCode {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(self.as_str())
    }
}

impl<'de> Deserialize<'de> for ErrorCode {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let code = String::deserialize(deserializer)?;
        Ok(Self::from_code(&code))
    }
}
