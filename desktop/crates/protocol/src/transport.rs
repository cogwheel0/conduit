//! How the app reaches the daemon, ported from `subprotocol.dart`,
//! `protocol_version.dart` and `ConduitHttpRoutes` in `methods.dart`.

use base64::Engine as _;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;

/// The `Origin` header every WebSocket upgrade must carry, `/rpc` and
/// `/terminal/*` alike. A browser page cannot claim it; a missing one is
/// refused.
pub const APP_ORIGIN: &str = "app://conduit";

/// The subprotocol that identifies a Conduit client, and the one the daemon
/// echoes back.
pub const SUBPROTOCOL: &str = "conduit.v1";

/// The JSON-RPC notification every event travels under, its params an
/// [`crate::EventEnvelope`].
pub const EVENT_NOTIFICATION: &str = "event";

const TOKEN_PREFIX: &str = "tk.";

/// The `Sec-WebSocket-Protocol` list to offer with the upgrade:
/// [`SUBPROTOCOL`], then the session token as `tk.` + its UTF-8 bytes in
/// base64url without padding (`=` is not legal in a subprotocol token).
pub fn subprotocols(session_token: &str) -> [String; 2] {
    [
        SUBPROTOCOL.to_owned(),
        format!("{TOKEN_PREFIX}{}", URL_SAFE_NO_PAD.encode(session_token)),
    ]
}

/// HTTP paths served beside the RPC socket. Requests carry
/// `Authorization: Bearer <session token>`.
pub mod routes {
    /// The JSON-RPC WebSocket.
    pub const RPC: &str = "/rpc";

    /// `POST` multipart: an attachment, streamed to the server. Answers with
    /// an [`crate::UploadedFile`].
    pub const UPLOAD: &str = "/upload";

    /// `POST` a recording as the body, its type as `content-type`: answers
    /// with a [`crate::VoiceTranscript`].
    pub const TRANSCRIBE: &str = "/transcribe";

    /// `POST` with `x-conduit-terminal` (a handle) and `x-conduit-directory`:
    /// an upload into a terminal's files. Same body as [`UPLOAD`].
    pub const TERMINAL_UPLOAD: &str = "/terminal-upload";

    /// `GET`: a file from the server, fetched with its credentials.
    pub fn file(server_id: &str, file_id: &str) -> String {
        format!("/files/{server_id}/{file_id}")
    }

    /// `GET`: the audio of a `voice.speak` job.
    pub fn tts(job_id: &str) -> String {
        format!("/tts/{job_id}")
    }

    /// `WS`: the raw byte tunnel to a terminal's shell.
    pub fn terminal(handle: &str) -> String {
        format!("/terminal/{handle}")
    }
}
