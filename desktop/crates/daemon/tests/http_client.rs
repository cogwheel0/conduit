//! `/upload` and `/files` against a minimal fake HTTP server.

use std::sync::{Arc, Mutex};

use bytes::Bytes;
use conduit_daemon::http::HttpClient;
use tokio::io::{AsyncReadExt as _, AsyncWriteExt as _};
use tokio::net::TcpListener;

#[derive(Clone, Debug, Default)]
struct Received {
    head: String,
    body: Vec<u8>,
}

impl Received {
    fn header(&self, name: &str) -> Option<String> {
        self.head.lines().find_map(|l| {
            let (k, v) = l.split_once(':')?;
            k.eq_ignore_ascii_case(name).then(|| v.trim().to_string())
        })
    }
}

/// Answers every request with `status`, `content_type` and `reply`.
async fn serve(
    status: &'static str,
    content_type: &'static str,
    reply: &'static [u8],
) -> (u16, Arc<Mutex<Vec<Received>>>) {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let seen = Arc::new(Mutex::new(vec![]));
    let seen2 = seen.clone();
    tokio::spawn(async move {
        while let Ok((mut tcp, _)) = listener.accept().await {
            let mut buf = vec![];
            let mut chunk = [0u8; 8192];
            let head_end = loop {
                let n = tcp.read(&mut chunk).await.unwrap_or(0);
                if n == 0 {
                    break None;
                }
                buf.extend_from_slice(&chunk[..n]);
                if let Some(i) = buf.windows(4).position(|w| w == b"\r\n\r\n") {
                    break Some(i + 4);
                }
            };
            let Some(head_end) = head_end else { continue };
            let head = String::from_utf8_lossy(&buf[..head_end]).to_string();
            let received = Received { head, body: vec![] };
            let length: usize = received
                .header("content-length")
                .and_then(|v| v.parse().ok())
                .unwrap_or(0);
            let mut body = buf[head_end..].to_vec();
            while body.len() < length {
                let n = tcp.read(&mut chunk).await.unwrap_or(0);
                if n == 0 {
                    break;
                }
                body.extend_from_slice(&chunk[..n]);
            }
            seen2.lock().unwrap().push(Received { body, ..received });
            let head = format!(
                "HTTP/1.1 {status}\r\ncontent-type: {content_type}\r\ncontent-length: {}\r\nconnection: close\r\n\r\n",
                reply.len()
            );
            let _ = tcp.write_all(head.as_bytes()).await;
            let _ = tcp.write_all(reply).await;
            let _ = tcp.shutdown().await;
        }
    });
    (port, seen)
}

#[tokio::test]
async fn upload_streams_the_body_with_auth_name_and_progress() {
    let (port, seen) = serve(
        "200 OK",
        "application/json",
        br#"{"id":"f1","name":"cv.pdf","size":200000}"#,
    )
    .await;
    let client = HttpClient::new(port, "secret-token");
    let body = Bytes::from(vec![7u8; 200_000]);
    let progress: Arc<Mutex<Vec<(u64, u64)>>> = Arc::default();
    let p = progress.clone();
    let result = client
        .upload(
            "résumé.pdf",
            Some("application/pdf"),
            body.clone(),
            Some(Arc::new(move |sent, total| {
                p.lock().unwrap().push((sent, total))
            })),
            2,
        )
        .await
        .unwrap();
    assert_eq!(result["id"], "f1");

    let req = seen.lock().unwrap()[0].clone();
    assert!(
        req.head.starts_with("POST /upload HTTP/1.1"),
        "{}",
        req.head
    );
    assert_eq!(
        req.header("authorization").as_deref(),
        Some("Bearer secret-token")
    );
    assert_eq!(
        req.header("x-conduit-filename").as_deref(),
        Some("r%C3%A9sum%C3%A9.pdf")
    );
    assert_eq!(
        req.header("content-type").as_deref(),
        Some("application/pdf")
    );
    assert_eq!(req.header("content-length").as_deref(), Some("200000"));
    // Which try this is, for the daemon's retry advice.
    assert_eq!(req.header("x-conduit-attempt").as_deref(), Some("2"));
    assert_eq!(req.body, body.to_vec());

    let progress = progress.lock().unwrap().clone();
    assert!(progress.len() >= 3, "several chunks: {progress:?}");
    assert!(progress.windows(2).all(|w| w[0].0 < w[1].0));
    assert_eq!(progress.last(), Some(&(200_000, 200_000)));
}

#[tokio::test]
async fn upload_surfaces_the_daemons_error_code() {
    let (port, _) = serve(
        "503 Service Unavailable",
        "application/json",
        br#"{"code":"rpc.daemonUnavailable","debugMessage":"core starting","retryable":false}"#,
    )
    .await;
    let client = HttpClient::new(port, "t");
    let e = client
        .upload("a.txt", None, Bytes::from_static(b"hi"), None, 1)
        .await
        .unwrap_err();
    assert_eq!(e.code.as_str(), "rpc.daemonUnavailable");
}

#[tokio::test]
async fn files_are_fetched_with_the_bearer_token() {
    let (port, seen) = serve("200 OK", "image/png", b"\x89PNG....").await;
    let client = HttpClient::new(port, "tok");
    let file = client.file("server 1", "abc/def").await.unwrap();
    assert_eq!(file.content_type, "image/png");
    assert_eq!(&file.bytes[..], b"\x89PNG....");
    let req = seen.lock().unwrap()[0].clone();
    assert!(
        req.head
            .starts_with("GET /files/server%201/abc%2Fdef HTTP/1.1"),
        "{}",
        req.head
    );
    assert_eq!(req.header("authorization").as_deref(), Some("Bearer tok"));
}

#[tokio::test]
async fn a_status_without_a_problem_body_keeps_the_status() {
    let (port, _) = serve("404 Not Found", "text/plain", b"no such endpoint").await;
    let e = HttpClient::new(port, "t").file("s", "x").await.unwrap_err();
    assert_eq!(e.code.as_str(), "transport.http");
    assert_eq!(e.args.get("status").map(String::as_str), Some("404"));
}
