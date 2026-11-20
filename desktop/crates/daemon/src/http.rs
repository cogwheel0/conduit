//! The daemon's plain HTTP routes, with `Authorization: Bearer <token>`.
//!
//! * `POST /upload`: the file's bytes as the whole body, its name in a
//!   percent-encoded `x-conduit-filename` header (headers are Latin-1, and
//!   `résumé.pdf` must survive), progress reported as the body streams.
//! * `GET /files/{server}/{id}`: an attachment's bytes and content type.
//! * `POST /transcribe`, `GET /recordings/{id}`: dictation's recordings.
//!
//! The client never uses a proxy: the token is a bearer credential.

use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};

use bytes::Bytes;
use futures_util::StreamExt as _;
use percent_encoding::{AsciiSet, NON_ALPHANUMERIC, utf8_percent_encode};
use serde_json::Value;

use crate::protocol::{APP_ORIGIN, RpcError, RpcErrorExt as _, SUBPROTOCOL, codes, error};
use crate::secrets::subprotocol_token;

/// A message on a [`DaemonSocket`].
pub use tokio_tungstenite::tungstenite::Message as SocketMessage;

/// A WebSocket to the daemon ([`HttpClient::websocket`]).
pub type DaemonSocket =
    tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>;

/// What `encodeURIComponent` leaves alone; Dart's `Uri.decodeComponent`
/// reverses it.
const COMPONENT: &AsciiSet = &NON_ALPHANUMERIC
    .remove(b'-')
    .remove(b'_')
    .remove(b'.')
    .remove(b'!')
    .remove(b'~')
    .remove(b'*')
    .remove(b'\'')
    .remove(b'(')
    .remove(b')');

pub fn encode_component(s: &str) -> String {
    utf8_percent_encode(s, COMPONENT).to_string()
}

/// A downloaded attachment.
#[derive(Clone, Debug)]
pub struct FileBytes {
    pub bytes: Bytes,
    pub content_type: String,
}

#[derive(Clone)]
pub struct HttpClient {
    client: reqwest::Client,
    base: String,
    token: String,
}

/// Bytes sent so far and the total.
pub type Progress = Arc<dyn Fn(u64, u64) + Send + Sync>;

const CHUNK: usize = 64 * 1024;

impl HttpClient {
    pub fn new(port: u16, token: impl Into<String>) -> Self {
        Self::with_base(format!("http://127.0.0.1:{port}"), token)
    }

    pub fn with_base(base: impl Into<String>, token: impl Into<String>) -> Self {
        let client = reqwest::Client::builder()
            .no_proxy()
            .build()
            .expect("a plain-HTTP reqwest client always builds");
        Self {
            client,
            base: base.into(),
            token: token.into(),
        }
    }

    fn bearer(&self) -> String {
        format!("Bearer {}", self.token)
    }

    /// `http://127.0.0.1:{port}`.
    pub(crate) fn base(&self) -> &str {
        &self.base
    }

    pub(crate) fn token(&self) -> &str {
        &self.token
    }

    /// `POST /terminal-upload`: `body` as `name` into `directory` on the
    /// machine of the terminal `handle` names.
    pub async fn terminal_upload(
        &self,
        handle: &str,
        directory: &str,
        name: &str,
        body: Bytes,
    ) -> Result<(), RpcError> {
        let response = self
            .client
            .post(format!("{}/terminal-upload", self.base))
            .header("authorization", self.bearer())
            .header("x-conduit-filename", encode_component(name))
            .header("x-conduit-terminal", encode_component(handle))
            .header("x-conduit-directory", encode_component(directory))
            .body(body)
            .send()
            .await
            .map_err(transport)?;
        let status = response.status();
        if !status.is_success() {
            let text = response.text().await.map_err(transport)?;
            return Err(problem(status.as_u16(), &text));
        }
        Ok(())
    }

    /// Uploads `body` as `name`; answers the daemon's `UploadedFile` JSON.
    /// `progress` sees `(sent, total)` as chunks go out, ending at
    /// `(total, total)`.
    /// `POST /upload`. `attempt` (1 for the first) lets the daemon answer a
    /// failure with the core's advice on trying again (the error's `retry`
    /// and `retryAfterMs` args).
    pub async fn upload(
        &self,
        name: &str,
        content_type: Option<&str>,
        body: Bytes,
        progress: Option<Progress>,
        attempt: u32,
    ) -> Result<Value, RpcError> {
        self.upload_to(name, content_type, body, progress, attempt, None)
            .await
    }

    /// [`Self::upload`], filed under `channel` (`x-conduit-channel`) when
    /// given: a channel's attachment, which its members may read.
    pub async fn upload_to(
        &self,
        name: &str,
        content_type: Option<&str>,
        body: Bytes,
        progress: Option<Progress>,
        attempt: u32,
        channel: Option<&str>,
    ) -> Result<Value, RpcError> {
        let total = body.len() as u64;
        let sent = Arc::new(AtomicU64::new(0));
        let chunks: Vec<Bytes> = (0..body.len())
            .step_by(CHUNK)
            .map(|i| body.slice(i..(i + CHUNK).min(body.len())))
            .collect();
        let stream = futures_util::stream::iter(chunks).map(move |chunk| {
            let now = sent.fetch_add(chunk.len() as u64, Ordering::SeqCst) + chunk.len() as u64;
            if let Some(p) = &progress {
                p(now, total);
            }
            Ok::<Bytes, std::io::Error>(chunk)
        });
        let mut request = self
            .client
            .post(format!("{}/upload", self.base))
            .header("authorization", self.bearer())
            .header("x-conduit-filename", encode_component(name))
            .header("x-conduit-attempt", attempt.max(1))
            .header("content-length", total)
            .body(reqwest::Body::wrap_stream(stream));
        if let Some(ct) = content_type {
            request = request.header("content-type", ct);
        }
        if let Some(channel) = channel {
            request = request.header("x-conduit-channel", channel);
        }
        let response = request.send().await.map_err(transport)?;
        let status = response.status();
        let text = response.text().await.map_err(transport)?;
        if !status.is_success() {
            return Err(problem(status.as_u16(), &text));
        }
        serde_json::from_str(&text).map_err(|e| error(codes::DECODE, e.to_string()))
    }

    /// `GET /files/{server}/{id}`.
    pub async fn file(&self, server_id: &str, file_id: &str) -> Result<FileBytes, RpcError> {
        let url = format!(
            "{}/files/{}/{}",
            self.base,
            encode_component(server_id),
            encode_component(file_id)
        );
        self.get_bytes(url).await
    }

    /// `GET /files/{server}/models/{model}`: a model's profile image (the
    /// one it keeps, or a picture on its server); 404 when it has none.
    pub async fn model_image(
        &self,
        server_id: &str,
        model_id: &str,
    ) -> Result<FileBytes, RpcError> {
        let url = format!(
            "{}/files/{}/models/{}",
            self.base,
            encode_component(server_id),
            encode_component(model_id)
        );
        self.get_bytes(url).await
    }

    /// `GET /media/{kind}?url=`: a picture (`kind` `image`) or a PDF
    /// (`pdf`) on another site, fetched by the daemon with nothing of the
    /// user's sent along. Refused with `media.tooLarge`, `media.wrongType`,
    /// `media.timedOut` or `media.failed`.
    pub async fn media(&self, kind: &str, url: &str) -> Result<FileBytes, RpcError> {
        let url = format!(
            "{}/media/{}?url={}",
            self.base,
            encode_component(kind),
            encode_component(url)
        );
        self.get_bytes(url).await
    }

    /// `GET /tts/{jobId}`: the audio of a `voice.speak` job.
    pub async fn speech(&self, job_id: &str) -> Result<FileBytes, RpcError> {
        let url = format!("{}/tts/{}", self.base, encode_component(job_id));
        self.get_bytes(url).await
    }

    /// A WebSocket on the daemon at `path` (`/calls/{handle}`, a realtime
    /// call's audio), opened as the RPC socket is: the app's origin and the
    /// session token in the subprotocols. Runs on the shared runtime.
    pub async fn websocket(&self, path: &str) -> Result<DaemonSocket, RpcError> {
        use tokio_tungstenite::tungstenite::client::IntoClientRequest as _;
        use tokio_tungstenite::tungstenite::http::HeaderValue;

        let url = format!("{}{}", self.base.replacen("http", "ws", 1), path);
        let mut request = url
            .into_client_request()
            .map_err(|e| error(codes::INTERNAL, e.to_string()))?;
        let headers = request.headers_mut();
        headers.insert("Origin", HeaderValue::from_static(APP_ORIGIN));
        let protocols = format!("{SUBPROTOCOL}, {}", subprotocol_token(&self.token));
        headers.insert(
            "Sec-WebSocket-Protocol",
            HeaderValue::from_str(&protocols).map_err(|e| error(codes::INTERNAL, e.to_string()))?,
        );
        let (socket, _) = tokio::time::timeout(
            std::time::Duration::from_secs(5),
            tokio_tungstenite::connect_async(request),
        )
        .await
        .map_err(|_| error(codes::DAEMON_UNAVAILABLE, "the daemon did not answer"))?
        .map_err(|e| error(codes::DAEMON_UNAVAILABLE, e.to_string()))?;
        Ok(socket)
    }

    /// `POST /transcribe`: `wav` (16 kHz mono) as text, by `engine`
    /// (`server`, `local`; the saved one when None) for `model`'s backend.
    /// Answers the daemon's `VoiceTranscript` JSON.
    pub async fn transcribe(
        &self,
        wav: Bytes,
        engine: Option<&str>,
        model: Option<&str>,
    ) -> Result<Value, RpcError> {
        let mut url = format!("{}/transcribe", self.base);
        let mut query = vec![];
        if let Some(engine) = engine {
            query.push(format!("engine={}", encode_component(engine)));
        }
        if let Some(model) = model {
            query.push(format!("model={}", encode_component(model)));
        }
        if !query.is_empty() {
            url = format!("{url}?{}", query.join("&"));
        }
        let response = self
            .client
            .post(url)
            .header("authorization", self.bearer())
            .header("content-type", "audio/wav")
            .body(wav)
            .send()
            .await
            .map_err(transport)?;
        let status = response.status();
        let text = response.text().await.map_err(transport)?;
        if !status.is_success() {
            return Err(problem(status.as_u16(), &text));
        }
        serde_json::from_str(&text).map_err(|e| error(codes::DECODE, e.to_string()))
    }

    /// `GET /recordings/{id}`: a draft's saved recording as WAV.
    pub async fn recording(
        &self,
        id: &str,
        chat_id: Option<&str>,
        folder_id: Option<&str>,
    ) -> Result<FileBytes, RpcError> {
        let mut url = format!("{}/recordings/{}", self.base, encode_component(id));
        let query: Vec<String> = [("chatId", chat_id), ("folderId", folder_id)]
            .into_iter()
            .filter_map(|(k, v)| v.map(|v| format!("{k}={}", encode_component(v))))
            .collect();
        if !query.is_empty() {
            url = format!("{url}?{}", query.join("&"));
        }
        self.get_bytes(url).await
    }

    /// `GET /recordings/{id}?noteId=`: one of a note's recordings still
    /// waiting to upload, as recorded.
    pub async fn note_recording(&self, note_id: &str, id: &str) -> Result<FileBytes, RpcError> {
        let url = format!(
            "{}/recordings/{}?noteId={}",
            self.base,
            encode_component(id),
            encode_component(note_id)
        );
        self.get_bytes(url).await
    }

    async fn get_bytes(&self, url: String) -> Result<FileBytes, RpcError> {
        let response = self
            .client
            .get(url)
            .header("authorization", self.bearer())
            .send()
            .await
            .map_err(transport)?;
        let status = response.status();
        let content_type = response
            .headers()
            .get("content-type")
            .and_then(|v| v.to_str().ok())
            .unwrap_or("application/octet-stream")
            .to_string();
        let bytes = response.bytes().await.map_err(transport)?;
        if !status.is_success() {
            return Err(problem(status.as_u16(), &String::from_utf8_lossy(&bytes)));
        }
        Ok(FileBytes {
            bytes,
            content_type,
        })
    }
}

fn transport(e: reqwest::Error) -> RpcError {
    error(codes::HTTP, e.to_string()).retryable()
}

/// The daemon's error body (`{code, args, debugMessage, retryable}`), or a
/// status-only error.
fn problem(status: u16, body: &str) -> RpcError {
    if let Ok(e) = serde_json::from_str::<RpcError>(body)
        && !e.code.as_str().is_empty()
    {
        return e;
    }
    let mut e = error(codes::HTTP, format!("HTTP {status}"));
    e.args.insert("status".into(), status.to_string());
    e
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn filenames_encode_like_encode_uri_component() {
        assert_eq!(encode_component("résumé.pdf"), "r%C3%A9sum%C3%A9.pdf");
        assert_eq!(encode_component("a b+c/d"), "a%20b%2Bc%2Fd");
        assert_eq!(encode_component("it's (1)!~*"), "it's%20(1)!~*");
    }
}
