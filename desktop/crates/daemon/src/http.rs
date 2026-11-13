//! The daemon's plain HTTP routes, with `Authorization: Bearer <token>`.
//!
//! * `POST /upload`: the file's bytes as the whole body, its name in a
//!   percent-encoded `x-conduit-filename` header (headers are Latin-1, and
//!   `résumé.pdf` must survive), progress reported as the body streams.
//! * `GET /files/{server}/{id}`: an attachment's bytes and content type.
//!
//! The client never uses a proxy: the token is a bearer credential.

use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};

use bytes::Bytes;
use futures_util::StreamExt as _;
use percent_encoding::{AsciiSet, NON_ALPHANUMERIC, utf8_percent_encode};
use serde_json::Value;

use crate::protocol::{RpcError, RpcErrorExt as _, codes, error};

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

    /// `GET /tts/{jobId}`: the audio of a `voice.speak` job.
    pub async fn speech(&self, job_id: &str) -> Result<FileBytes, RpcError> {
        let url = format!("{}/tts/{}", self.base, encode_component(job_id));
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
