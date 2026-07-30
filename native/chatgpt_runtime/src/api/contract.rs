use serde::{Deserialize, Serialize};
use thiserror::Error;

pub const BRIDGE_PROTOCOL_VERSION: u32 = 2;
pub const EVENT_QUEUE_CAPACITY: usize = 256;
pub const MAX_QUEUED_TURNS: usize = 64;
pub const MAX_QUEUED_INPUT_BYTES: usize = 80 * 1024 * 1024;
pub const MAX_TEXT_INPUT_BYTES: usize = 1024 * 1024;
pub const MAX_BINARY_INPUT_BYTES: usize = 20 * 1024 * 1024;
pub const MAX_AGGREGATE_INPUT_BYTES: usize = 40 * 1024 * 1024;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum BridgeErrorKind {
    InvalidInput,
    Authentication,
    Network,
    RateLimit,
    Unsupported,
    Cancellation,
    ProtocolMismatch,
    Internal,
}

#[derive(Debug, Clone, Error, Serialize, Deserialize)]
#[error("{message}")]
pub struct BridgeError {
    pub kind: BridgeErrorKind,
    pub message: String,
    pub retry_after_seconds: Option<u32>,
}

impl BridgeError {
    pub(crate) fn new(kind: BridgeErrorKind, message: impl Into<String>) -> Self {
        Self {
            kind,
            message: message.into(),
            retry_after_seconds: None,
        }
    }

    pub(crate) fn internal(message: impl Into<String>) -> Self {
        Self::new(BridgeErrorKind::Internal, message)
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AuthStateInfo {
    pub authenticated: bool,
    pub email: Option<String>,
    pub plan_type: Option<String>,
    pub account_id: Option<String>,
    pub account_fingerprint: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DeviceCodeChallenge {
    pub login_id: String,
    pub verification_url: String,
    pub user_code: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ModelInfo {
    pub id: String,
    pub display_name: String,
    pub description: String,
    pub supports_images: bool,
    pub supports_audio: bool,
    pub supported_reasoning_efforts: Vec<String>,
    pub default_reasoning_effort: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ThreadInfo {
    pub thread_id: String,
    pub model_id: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TurnInputPart {
    /// `text`, `image`, `audio`, or `document`.
    pub kind: String,
    pub text: Option<String>,
    pub filename: Option<String>,
    pub mime_type: Option<String>,
    pub bytes: Option<Vec<u8>>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TurnRequest {
    pub thread_id: String,
    pub client_user_message_id: Option<String>,
    pub model_id: String,
    pub reasoning_effort: Option<String>,
    pub enable_web_search: bool,
    pub enable_image_generation: bool,
    pub inputs: Vec<TurnInputPart>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RunInfo {
    pub run_id: String,
    pub thread_id: String,
    pub turn_id: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum RuntimeEventKind {
    AuthState,
    AuthMutationRequired,
    LoginCompleted,
    TurnStarted,
    TextDelta,
    ReasoningDelta,
    ToolStarted,
    ToolCompleted,
    Source,
    GeneratedImage,
    Usage,
    Cancelled,
    Completed,
    Failure,
    Diagnostic,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RuntimeEvent {
    pub client_epoch: u64,
    pub sequence: u64,
    pub kind: RuntimeEventKind,
    pub run_id: Option<String>,
    pub thread_id: Option<String>,
    pub turn_id: Option<String>,
    pub item_id: Option<String>,
    pub text: Option<String>,
    /// Sanitized structured metadata. Authentication material is never placed here.
    pub json_data: Option<String>,
    /// Used only by generated media and opaque auth mutation snapshots.
    pub binary_data: Option<Vec<u8>>,
}
