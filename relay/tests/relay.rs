//! End-to-end tests: the real router on 127.0.0.1, talking to a mock APNs,
//! a mock FCM and a mock OAuth token endpoint.

use std::collections::{HashMap, VecDeque};
use std::net::SocketAddr;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use aws_lc_rs::encoding::{AsDer, Pkcs8V1Der};
use aws_lc_rs::rsa::{KeyPair as RsaKeyPair, KeySize};
use aws_lc_rs::signature::{EcdsaKeyPair, KeyPair, ECDSA_P256_SHA256_FIXED_SIGNING};
use axum::body::to_bytes;
use axum::extract::{Request, State};
use axum::http::{HeaderMap, StatusCode, Version};
use axum::response::{IntoResponse, Response};
use axum::Router;
use base64::engine::general_purpose::{STANDARD, URL_SAFE_NO_PAD};
use base64::Engine;
use conduit_push_relay::config::Config;
use conduit_push_relay::{AppState, ConnectionLimits, StartupError};
use jsonwebtoken::{Algorithm, DecodingKey, Validation};
use serde_json::{json, Value};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};

const TEAM_ID: &str = "TEAM123456";
const KEY_ID: &str = "KEY7654321";
const APP: &str = "app.cogwheel.conduit";
const PROJECT: &str = "conduit-test";
const CLIENT_EMAIL: &str = "relay@conduit-test.iam.gserviceaccount.com";
const SID: &str = "QFvhBRA6vVgC_oPGR5mrpA";
const TOPIC: &str = "lIs5gmFDzleXLxWAvzVdVk";
const FCM_TOKEN: &str = "cX1b2C3d4E5f6:APA91bHk-Example_Token.0123456789";

fn apns_token() -> String {
    "0a1b2c3d".repeat(8)
}

// ---------------------------------------------------------------- keys

struct Keys {
    apns_pem: String,
    /// Uncompressed P-256 point.
    apns_public: Vec<u8>,
    fcm_pem: String,
    /// PKCS#1 RSAPublicKey DER.
    fcm_public: Vec<u8>,
}

fn keys() -> &'static Keys {
    static KEYS: OnceLock<Keys> = OnceLock::new();
    KEYS.get_or_init(|| {
        let ec = EcdsaKeyPair::generate(&ECDSA_P256_SHA256_FIXED_SIGNING).unwrap();
        let rsa = RsaKeyPair::generate(KeySize::Rsa2048).unwrap();
        let rsa_pkcs8: Pkcs8V1Der = rsa.as_der().unwrap();
        Keys {
            apns_pem: pem(ec.to_pkcs8v1().unwrap().as_ref()),
            apns_public: ec.public_key().as_ref().to_vec(),
            fcm_pem: pem(rsa_pkcs8.as_ref()),
            fcm_public: rsa.public_key().as_ref().to_vec(),
        }
    })
}

fn pem(der: &[u8]) -> String {
    let b64 = STANDARD.encode(der);
    let lines: Vec<&str> = b64
        .as_bytes()
        .chunks(64)
        .map(|c| std::str::from_utf8(c).unwrap())
        .collect();
    format!(
        "-----BEGIN PRIVATE KEY-----\n{}\n-----END PRIVATE KEY-----\n",
        lines.join("\n")
    )
}

// ---------------------------------------------------------------- vectors

fn vectors() -> &'static Value {
    static VECTORS: OnceLock<Value> = OnceLock::new();
    VECTORS.get_or_init(|| {
        serde_json::from_str(include_str!("../../push/test-vectors/cp1_vectors.json")).unwrap()
    })
}

fn b64(value: &Value) -> Vec<u8> {
    URL_SAFE_NO_PAD.decode(value.as_str().unwrap()).unwrap()
}

fn first_case_body() -> Vec<u8> {
    b64(&vectors()["cases"][0]["body"])
}

fn reject_body(name: &str) -> Vec<u8> {
    b64(&vectors()["reject"]["bodies"][name])
}

// ---------------------------------------------------------------- mock providers

#[derive(Clone, Debug)]
struct Recorded {
    path: String,
    version: Version,
    headers: HeaderMap,
    body: Vec<u8>,
}

impl Recorded {
    fn header(&self, name: &str) -> Option<&str> {
        self.headers.get(name).map(|v| v.to_str().unwrap())
    }

    fn json(&self) -> Value {
        serde_json::from_slice(&self.body).unwrap()
    }
}

#[derive(Default)]
struct Mock {
    apns: Mutex<Vec<Recorded>>,
    fcm: Mutex<Vec<Recorded>>,
    oauth: Mutex<Vec<Recorded>>,
    apns_replies: Mutex<VecDeque<(u16, String)>>,
    fcm_replies: Mutex<VecDeque<(u16, String)>>,
    oauth_replies: Mutex<VecDeque<(u16, String)>>,
    issued: AtomicUsize,
    /// Token requests are answered only while this can be read, so a test
    /// holding it for writing makes Google slow.
    oauth_gate: tokio::sync::RwLock<()>,
    /// How many token requests have arrived, for a test to wait on.
    token_requests: tokio::sync::watch::Sender<usize>,
}

impl Mock {
    fn apns(&self) -> Vec<Recorded> {
        self.apns.lock().unwrap().clone()
    }
    fn fcm(&self) -> Vec<Recorded> {
        self.fcm.lock().unwrap().clone()
    }
    fn oauth(&self) -> Vec<Recorded> {
        self.oauth.lock().unwrap().clone()
    }
    fn reply_apns(&self, status: u16, body: &str) {
        self.apns_replies
            .lock()
            .unwrap()
            .push_back((status, body.into()));
    }
    fn reply_fcm(&self, status: u16, body: &str) {
        self.fcm_replies
            .lock()
            .unwrap()
            .push_back((status, body.into()));
    }
    fn reply_oauth(&self, status: u16, body: &str) {
        self.oauth_replies
            .lock()
            .unwrap()
            .push_back((status, body.into()));
    }
    /// Resolves once `n` token requests have arrived in all.
    async fn wait_for_token_requests(&self, n: usize) {
        let mut arrived = self.token_requests.subscribe();
        arrived.wait_for(|&count| count >= n).await.unwrap();
    }
}

async fn mock_provider(State(mock): State<Arc<Mock>>, request: Request) -> Response {
    let (parts, body) = request.into_parts();
    let recorded = Recorded {
        path: parts.uri.path().to_owned(),
        version: parts.version,
        headers: parts.headers,
        body: to_bytes(body, 1 << 20).await.unwrap().to_vec(),
    };
    let path = recorded.path.clone();
    let (log, replies, default) = if path.contains("/3/device/") {
        (&mock.apns, &mock.apns_replies, (200, String::new()))
    } else if path.ends_with("/messages:send") {
        (
            &mock.fcm,
            &mock.fcm_replies,
            (
                200,
                format!(r#"{{"name":"projects/{PROJECT}/messages/0:1"}}"#),
            ),
        )
    } else if path == "/token" {
        let n = mock.issued.fetch_add(1, Ordering::SeqCst) + 1;
        (
            &mock.oauth,
            &mock.oauth_replies,
            (
                200,
                format!(r#"{{"access_token":"tok-{n}","expires_in":3599,"token_type":"Bearer"}}"#),
            ),
        )
    } else {
        return StatusCode::NOT_FOUND.into_response();
    };
    log.lock().unwrap().push(recorded);
    if path == "/token" {
        mock.token_requests.send_modify(|count| *count += 1);
        let _open = mock.oauth_gate.read().await;
    }
    let (status, body) = replies.lock().unwrap().pop_front().unwrap_or(default);
    (
        StatusCode::from_u16(status).unwrap(),
        [("content-type", "application/json")],
        body,
    )
        .into_response()
}

async fn start_mock() -> (SocketAddr, Arc<Mock>) {
    let mock = Arc::new(Mock::default());
    let app = Router::new()
        .fallback(mock_provider)
        .with_state(mock.clone());
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
    (addr, mock)
}

/// A local address no server can listen on, so no other test's server can
/// answer there (a freed port can be taken, and then answers 502, not 503).
/// A connection to it fails at once on Linux and macOS alike; on macOS, one
/// to a port that is bound but not listening is dropped rather than
/// refused, and waits out the connect timeout.
const UNREACHABLE: &str = "http://127.0.0.1:0";

// ---------------------------------------------------------------- relay harness

type Env = HashMap<&'static str, String>;

struct Relay {
    base: String,
    metrics: String,
    mock: Arc<Mock>,
    mock_addr: SocketAddr,
    http: reqwest::Client,
}

fn seal_key(kid: u8) -> String {
    format!("{kid}:{}", STANDARD.encode([kid; 32]))
}

fn base_env(mock: SocketAddr) -> Env {
    let keys = keys();
    let service_account = json!({
        "type": "service_account",
        "project_id": PROJECT,
        "private_key_id": "abc",
        "private_key": keys.fcm_pem,
        "client_email": CLIENT_EMAIL,
        "token_uri": format!("http://{mock}/token"),
    });
    HashMap::from([
        ("RELAY_SEAL_KEYS", seal_key(1)),
        ("RELAY_SEAL_ACTIVE_KID", "1".into()),
        ("APNS_TEAM_ID", TEAM_ID.into()),
        ("APNS_KEY_ID", KEY_ID.into()),
        ("APNS_KEY_P8", keys.apns_pem.clone()),
        ("APNS_APPS", format!("{APP},{APP}.debug")),
        ("APNS_HOST_PROD", format!("http://{mock}")),
        ("APNS_HOST_DEV", format!("http://{mock}/sandbox")),
        ("FCM_SERVICE_ACCOUNT_JSON", service_account.to_string()),
        ("FCM_APPS", APP.into()),
        ("FCM_API_BASE", format!("http://{mock}")),
    ])
}

async fn start() -> Relay {
    start_with(|_| {}).await
}

async fn start_with(tweak: impl FnOnce(&mut Env)) -> Relay {
    let (mock_addr, mock) = start_mock().await;
    let mut env = base_env(mock_addr);
    tweak(&mut env);
    start_relay(env, mock, mock_addr).await
}

async fn start_relay(env: Env, mock: Arc<Mock>, mock_addr: SocketAddr) -> Relay {
    start_relay_with(env, mock, mock_addr, |_| {}).await
}

/// Starts a relay whose settings `tweak` may change after they are read from
/// `env`, for the ones that have no variable.
async fn start_relay_with(
    mut env: Env,
    mock: Arc<Mock>,
    mock_addr: SocketAddr,
    tweak: impl FnOnce(&mut Config),
) -> Relay {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let base = format!("http://{}", listener.local_addr().unwrap());
    env.entry("RELAY_PUBLIC_URL")
        .or_insert_with(|| base.clone());

    let mut config = Config::from_lookup(|name| env.get(name).cloned()).unwrap();
    tweak(&mut config);
    let state = Arc::new(AppState::new(&config).unwrap());
    let metrics_listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let metrics = format!("http://{}", metrics_listener.local_addr().unwrap());
    tokio::spawn(conduit_push_relay::serve(
        listener,
        state.clone(),
        config.connections,
        std::future::pending(),
    ));
    tokio::spawn(conduit_push_relay::serve_metrics(
        metrics_listener,
        state,
        config.connections,
        std::future::pending(),
    ));
    Relay {
        base,
        metrics,
        mock,
        mock_addr,
        http: reqwest::Client::new(),
    }
}

impl Relay {
    async fn register(&self, body: &Value) -> reqwest::Response {
        self.http
            .post(format!("{}/v1/register", self.base))
            .json(body)
            .send()
            .await
            .unwrap()
    }

    async fn endpoint(&self, provider: &str, env: &str) -> String {
        let token = match provider {
            "apns" => apns_token(),
            _ => FCM_TOKEN.to_owned(),
        };
        let response = self
            .register(
                &json!({"provider": provider, "token": token, "app": APP, "env": env, "sid": SID}),
            )
            .await;
        assert_eq!(response.status(), 200);
        let body: Value = response.json().await.unwrap();
        body["endpoint"].as_str().unwrap().to_owned()
    }

    async fn push(
        &self,
        endpoint: &str,
        body: Vec<u8>,
        headers: &[(&str, &str)],
    ) -> reqwest::Response {
        let mut request = self.http.post(endpoint).body(body);
        for (name, value) in headers {
            request = request.header(*name, *value);
        }
        request.send().await.unwrap()
    }

    /// A push as a Conduit server sends a reply notification.
    async fn push_reply(&self, endpoint: &str) -> reqwest::Response {
        self.push(endpoint, first_case_body(), &standard_headers())
            .await
    }

    async fn get(&self, path: &str) -> reqwest::Response {
        self.http
            .get(format!("{}{path}", self.base))
            .send()
            .await
            .unwrap()
    }

    async fn metrics(&self) -> String {
        self.http
            .get(format!("{}/metrics", self.metrics))
            .send()
            .await
            .unwrap()
            .text()
            .await
            .unwrap()
    }
}

// ---------------------------------------------------------------- blocking client

// The tests on tokio's paused clock drive their client with blocking I/O:
// tokio does not auto-advance a paused clock while a blocking task runs, so
// the clock cannot jump to one of the relay's timers while a request or its
// answer is still in the kernel. It moves only when a test advances it, or
// waits for the relay to close a connection.

async fn blocking<T: Send + 'static>(io: impl FnOnce() -> T + Send + 'static) -> T {
    tokio::task::spawn_blocking(io).await.unwrap()
}

async fn connect_blocking(addr: SocketAddr) -> std::net::TcpStream {
    blocking(move || std::net::TcpStream::connect(addr).unwrap()).await
}

async fn write_blocking(
    mut stream: std::net::TcpStream,
    bytes: impl AsRef<[u8]> + Send + 'static,
) -> std::net::TcpStream {
    use std::io::Write;
    blocking(move || {
        stream.write_all(bytes.as_ref()).unwrap();
        stream
    })
    .await
}

/// Sends `request` on a kept-alive connection and reads the answer.
async fn exchange_blocking(
    mut stream: std::net::TcpStream,
    request: impl AsRef<[u8]> + Send + 'static,
) -> (std::net::TcpStream, Answer) {
    use std::io::Write;
    blocking(move || {
        stream.write_all(request.as_ref()).unwrap();
        let answer = Answer::read(&mut stream);
        (stream, answer)
    })
    .await
}

const HEALTHZ: &[u8] = b"GET /healthz HTTP/1.1\r\nHost: relay\r\n\r\n";

/// Asks for `/healthz` on a kept-alive connection, and checks the answer.
async fn healthz_blocking(stream: std::net::TcpStream) -> std::net::TcpStream {
    let (stream, answer) = exchange_blocking(stream, HEALTHZ).await;
    assert_eq!((answer.status(), answer.body()), (200, "ok"), "{answer}");
    stream
}

/// Reads a head, one byte at a time so that nothing past it is read.
fn read_head(stream: &mut std::net::TcpStream) -> String {
    use std::io::Read;
    let mut head = Vec::new();
    let mut byte = [0u8];
    while !head.ends_with(b"\r\n\r\n") {
        match stream.read(&mut byte) {
            Ok(1) => head.push(byte[0]),
            closed => panic!("{closed:?} after {:?}", String::from_utf8_lossy(&head)),
        }
    }
    String::from_utf8(head).unwrap()
}

/// An answer: its head, then exactly the body its `content-length` gives,
/// so any answer ends the read and nothing past it is read.
struct Answer(String);

impl Answer {
    fn read(stream: &mut std::net::TcpStream) -> Self {
        use std::io::Read;
        let head = Self(read_head(stream));
        let length: usize = head
            .header("content-length")
            .unwrap_or_else(|| panic!("no content-length in {head}"))
            .parse()
            .unwrap();
        let mut body = vec![0u8; length];
        stream.read_exact(&mut body).unwrap();
        Self(head.0 + std::str::from_utf8(&body).unwrap())
    }

    fn status(&self) -> u16 {
        self.0[9..12].parse().unwrap()
    }

    fn header(&self, name: &str) -> Option<&str> {
        let head = self.0.split("\r\n\r\n").next().unwrap();
        head.lines().skip(1).find_map(|line| {
            let (key, value) = line.split_once(':')?;
            key.eq_ignore_ascii_case(name).then(|| value.trim())
        })
    }

    fn body(&self) -> &str {
        self.0.split_once("\r\n\r\n").unwrap().1
    }

    fn error(&self) -> String {
        let body: Value = serde_json::from_str(self.body()).unwrap();
        body["error"].as_str().unwrap().to_owned()
    }
}

impl std::fmt::Display for Answer {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

/// Whether nothing has arrived on `stream` yet, without waiting for it.
fn nothing_received(stream: &std::net::TcpStream) -> bool {
    stream.set_nonblocking(true).unwrap();
    let received = stream.peek(&mut [0u8]);
    stream.set_nonblocking(false).unwrap();
    matches!(received, Err(e) if e.kind() == std::io::ErrorKind::WouldBlock)
}

/// Reads what the relay still sends on `stream` until it closes it, and says
/// how long that took from `since`. Left alone, the paused clock
/// auto-advances to the relay's next timer, so the close comes at an exact
/// time, as long as no other timer is running by then.
async fn read_until_closed(
    stream: std::net::TcpStream,
    since: tokio::time::Instant,
) -> (Duration, Vec<u8>) {
    stream.set_nonblocking(true).unwrap();
    let mut stream = TcpStream::from_std(stream).unwrap();
    let mut received = Vec::new();
    let mut buf = [0u8; 1024];
    while let Ok(n @ 1..) = stream.read(&mut buf).await {
        received.extend_from_slice(&buf[..n]);
    }
    (since.elapsed(), received)
}

/// A request with a body, after which the relay closes the connection, so
/// that none of its timers are left running for it.
fn post(path: &str, headers: &[(&str, &str)], body: &[u8]) -> Vec<u8> {
    let mut request = format!(
        "POST {path} HTTP/1.1\r\nHost: relay\r\nConnection: close\r\n\
         Content-Length: {}\r\n",
        body.len()
    );
    for (name, value) in headers {
        request.push_str(&format!("{name}: {value}\r\n"));
    }
    request.push_str("\r\n");
    let mut request = request.into_bytes();
    request.extend_from_slice(body);
    request
}

impl Relay {
    fn addr(&self) -> SocketAddr {
        self.base.strip_prefix("http://").unwrap().parse().unwrap()
    }

    async fn connect_blocking(&self) -> std::net::TcpStream {
        connect_blocking(self.addr()).await
    }

    /// Sends `request` on a connection of its own.
    async fn send_blocking(&self, request: Vec<u8>) -> Answer {
        exchange_blocking(self.connect_blocking().await, request)
            .await
            .1
    }

    /// `endpoint`, with blocking I/O, and only its path.
    async fn endpoint_blocking(&self, provider: &str) -> String {
        let token = match provider {
            "apns" => apns_token(),
            _ => FCM_TOKEN.to_owned(),
        };
        let body =
            json!({"provider": provider, "token": token, "app": APP, "env": "prod", "sid": SID});
        let answer = self
            .send_blocking(post(
                "/v1/register",
                &[("content-type", "application/json")],
                body.to_string().as_bytes(),
            ))
            .await;
        assert_eq!(answer.status(), 200, "{answer}");
        let body: Value = serde_json::from_str(answer.body()).unwrap();
        let endpoint = body["endpoint"].as_str().unwrap();
        endpoint.strip_prefix(&self.base).unwrap().to_owned()
    }

    /// `push_reply`, with blocking I/O, to an endpoint's path.
    async fn push_reply_blocking(&self, path: &str) -> Answer {
        self.send_blocking(post(path, &standard_headers(), &first_case_body()))
            .await
    }
}

type Headers = Vec<(&'static str, &'static str)>;

fn standard_headers() -> Headers {
    vec![
        ("content-encoding", "aes128gcm"),
        ("content-type", "application/octet-stream"),
        ("ttl", "86400"),
        ("urgency", "high"),
        ("topic", TOPIC),
    ]
}

async fn error_code(response: reqwest::Response) -> (u16, String) {
    let status = response.status().as_u16();
    let body: Value = response.json().await.unwrap();
    (status, body["error"].as_str().unwrap().to_owned())
}

fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs()
}

fn sealed_part(endpoint: &str) -> &str {
    endpoint.rsplit('/').next().unwrap()
}

fn assert_near(actual: u64, expected: u64) {
    assert!(
        actual.abs_diff(expected) <= 5,
        "{actual} is not within 5 s of {expected}"
    );
}

// ---------------------------------------------------------------- info, health

#[tokio::test]
async fn info_reports_protocol_and_providers() {
    let relay = start().await;
    let info: Value = relay.get("/v1/info").await.json().await.unwrap();
    assert_eq!(
        info,
        json!({"proto": 1, "active_kid": 1, "max_body": 2134, "providers": ["apns", "fcm"]})
    );

    let relay = start_with(|env| {
        env.remove("APNS_KEY_P8");
        env.insert(
            "RELAY_SEAL_KEYS",
            format!("{},{}", seal_key(1), seal_key(2)),
        );
        env.insert("RELAY_SEAL_ACTIVE_KID", "2".into());
    })
    .await;
    let info: Value = relay.get("/v1/info").await.json().await.unwrap();
    assert_eq!(info["providers"], json!(["fcm"]));
    assert_eq!(info["active_kid"], 2);
}

#[tokio::test]
async fn health_and_readiness() {
    let relay = start().await;
    assert_eq!(relay.get("/healthz").await.status(), 200);
    assert_eq!(relay.get("/readyz").await.status(), 200);
    // FCM readiness minted an access token; the next check is cached.
    assert_eq!(relay.get("/readyz").await.status(), 200);
    assert_eq!(relay.mock.oauth().len(), 1);

    let relay = start().await;
    relay.mock.reply_oauth(500, "{}");
    let (status, code) = error_code(relay.get("/readyz").await).await;
    assert_eq!((status, code.as_str()), (503, "not_ready"));
    assert_eq!(relay.get("/healthz").await.status(), 200);
}

#[tokio::test]
async fn unknown_routes_and_methods_are_json_errors() {
    let relay = start().await;
    assert_eq!(
        error_code(relay.get("/nope").await).await,
        (404, "not_found".into())
    );
    assert_eq!(
        error_code(relay.get("/v1/register").await).await,
        (405, "method_not_allowed".into())
    );
    // Metrics live only on the internal listener.
    assert_eq!(relay.get("/metrics").await.status(), 404);
}

// ---------------------------------------------------------------- register

#[tokio::test]
async fn register_returns_a_sealed_endpoint() {
    let relay = start().await;
    let response = relay
        .register(&json!({"provider": "apns", "token": apns_token().to_uppercase(), "app": APP, "env": "prod", "sid": SID}))
        .await;
    assert_eq!(response.status(), 200);
    assert_eq!(response.headers()["cache-control"], "no-store");
    let body: Value = response.json().await.unwrap();
    assert_eq!(body["kid"], 1);
    let endpoint = body["endpoint"].as_str().unwrap();
    let prefix = format!("{}/v1/push/", relay.base);
    assert!(endpoint.starts_with(&prefix), "{endpoint}");
    let raw = URL_SAFE_NO_PAD.decode(sealed_part(endpoint)).unwrap();
    assert_eq!(&raw[..2], &[0x01, 0x01]);
    // The token is inside, not readable.
    assert!(!endpoint.contains(&apns_token()));
}

#[tokio::test]
async fn register_validation_errors() {
    // More requests than the default 20 a minute.
    let relay = start_with(|env| {
        env.insert("RELAY_RATE_REGISTER_PER_MIN", "100".into());
    })
    .await;
    let good =
        json!({"provider": "apns", "token": apns_token(), "app": APP, "env": "prod", "sid": SID});
    let with = |key: &str, value: Value| {
        let mut body = good.clone();
        body[key] = value;
        body
    };
    let without = |key: &str| {
        let mut body = good.clone();
        body.as_object_mut().unwrap().remove(key);
        body
    };
    let cases = [
        (
            with("provider", json!("webpush")),
            503,
            "provider_unconfigured",
        ),
        (
            with("provider", json!("APNS")),
            503,
            "provider_unconfigured",
        ),
        (
            with("app", json!("com.example.other")),
            403,
            "app_not_allowed",
        ),
        (
            json!({"provider": "fcm", "token": FCM_TOKEN, "app": format!("{APP}.debug"), "env": "prod", "sid": SID}),
            403,
            "app_not_allowed",
        ),
        (without("provider"), 400, "invalid_request"),
        (without("token"), 400, "invalid_request"),
        (without("sid"), 400, "invalid_request"),
        (with("env", json!("staging")), 400, "invalid_request"),
        (with("env", json!(1)), 400, "invalid_request"),
        (with("token", json!("0a1b2c")), 400, "invalid_request"),
        (
            with("token", json!("zz".repeat(32))),
            400,
            "invalid_request",
        ),
        (
            with("token", json!("a".repeat(202))),
            400,
            "invalid_request",
        ),
        (with("token", json!(FCM_TOKEN)), 400, "invalid_request"),
        (
            json!({"provider": "fcm", "token": "has a space in it, not allowed", "app": APP, "env": "prod", "sid": SID}),
            400,
            "invalid_request",
        ),
        (
            json!({"provider": "fcm", "token": "short", "app": APP, "env": "prod", "sid": SID}),
            400,
            "invalid_request",
        ),
        (
            with("sid", json!("QFvhBRA6vVgC_oPGR5mrpA==")),
            400,
            "invalid_request",
        ),
        (
            with("sid", json!("QFvhBRA6vVgC_oPGR5mr")),
            400,
            "invalid_request",
        ),
        (
            with("sid", json!("QFvhBRA6vVgC+oPGR5mrpA")),
            400,
            "invalid_request",
        ),
        (
            with("sid", json!("QUJDREVGR0hJSktMTU5PUFFSUw")),
            400,
            "invalid_request",
        ),
        (json!([1, 2, 3]), 400, "invalid_request"),
    ];
    for (body, status, code) in cases {
        let got = error_code(relay.register(&body).await).await;
        assert_eq!(got, (status, code.to_owned()), "{body}");
    }

    let not_json = relay
        .http
        .post(format!("{}/v1/register", relay.base))
        .body("provider=apns")
        .send()
        .await
        .unwrap();
    assert_eq!(error_code(not_json).await, (400, "invalid_request".into()));

    let huge = with("app", json!("x".repeat(20_000)));
    assert_eq!(
        error_code(relay.register(&huge).await).await,
        (400, "invalid_request".into())
    );

    // Unknown extra fields are fine.
    assert_eq!(
        relay
            .register(&with("label", json!("iPhone")))
            .await
            .status(),
        200
    );
}

#[tokio::test]
async fn register_is_rate_limited_per_ip() {
    let relay = start_with(|env| {
        env.insert("RELAY_RATE_REGISTER_PER_MIN", "2".into());
    })
    .await;
    relay.endpoint("apns", "prod").await;
    relay.endpoint("fcm", "prod").await;
    let response = relay
        .register(&json!({"provider": "apns", "token": apns_token(), "app": APP, "env": "prod", "sid": SID}))
        .await;
    let retry_after: u64 = response.headers()["retry-after"]
        .to_str()
        .unwrap()
        .parse()
        .unwrap();
    assert!((1..=30).contains(&retry_after), "{retry_after}");
    assert_eq!(error_code(response).await, (429, "rate_limited".into()));
}

// ---------------------------------------------------------------- APNs

#[tokio::test]
async fn apns_push_delivers_the_exact_request() {
    let relay = start().await;
    let endpoint = relay.endpoint("apns", "prod").await;
    let body = first_case_body();

    let response = relay.push_reply(&endpoint).await;
    assert_eq!(response.status(), 201);
    let location = response.headers()["location"].to_str().unwrap().to_owned();
    assert!(location.starts_with(&format!("{}/v1/message/", relay.base)));
    assert_eq!(response.headers()["ttl"], "86400");

    let sent = relay.mock.apns();
    assert_eq!(sent.len(), 1);
    let request = &sent[0];
    assert_eq!(request.path, format!("/3/device/{}", apns_token()));
    assert_eq!(request.version, Version::HTTP_2);
    assert_eq!(request.header("apns-push-type"), Some("alert"));
    assert_eq!(request.header("apns-topic"), Some(APP));
    assert_eq!(request.header("apns-priority"), Some("10"));
    assert_eq!(request.header("apns-collapse-id"), Some(TOPIC));
    assert_eq!(request.header("content-type"), Some("application/json"));
    let expiration: u64 = request.header("apns-expiration").unwrap().parse().unwrap();
    assert_near(expiration, now() + 86400);
    assert_eq!(
        request.json(),
        json!({
            "aps": {
                "alert": {"title-loc-key": "push.fallback.title", "loc-key": "push.fallback.body"},
                "mutable-content": 1,
                "sound": "default"
            },
            "cp": {"v": 1, "s": SID, "d": URL_SAFE_NO_PAD.encode(&body)}
        })
    );

    // The provider token is an ES256 JWT signed by the .p8 key.
    let jwt = request
        .header("authorization")
        .unwrap()
        .strip_prefix("bearer ")
        .unwrap();
    let header = jsonwebtoken::decode_header(jwt).unwrap();
    assert_eq!(header.alg, Algorithm::ES256);
    assert_eq!(header.kid.as_deref(), Some(KEY_ID));
    assert_eq!(header.typ, None);
    let mut validation = Validation::new(Algorithm::ES256);
    validation.required_spec_claims.clear();
    validation.validate_exp = false;
    let claims = jsonwebtoken::decode::<Value>(
        jwt,
        &DecodingKey::from_ec_der(&keys().apns_public),
        &validation,
    )
    .unwrap()
    .claims;
    assert_eq!(claims.as_object().unwrap().len(), 2, "{claims}");
    assert_eq!(claims["iss"], TEAM_ID);
    assert_near(claims["iat"].as_u64().unwrap(), now());

    // A second push reuses the cached token and gets its own Location.
    let second = relay.push_reply(&endpoint).await;
    assert_eq!(second.status(), 201);
    assert_ne!(second.headers()["location"].to_str().unwrap(), location);
    let sent = relay.mock.apns();
    assert_eq!(
        sent[1].header("authorization"),
        request.header("authorization")
    );
}

#[tokio::test]
async fn apns_maps_ttl_urgency_topic_and_sandbox() {
    let relay = start().await;
    let endpoint = relay.endpoint("apns", "dev").await;
    let response = relay
        .push(
            &endpoint,
            first_case_body(),
            &[
                ("content-encoding", "aes128gcm"),
                ("ttl", "0"),
                ("urgency", "normal"),
            ],
        )
        .await;
    assert_eq!(response.status(), 201);
    assert_eq!(response.headers()["ttl"], "0");

    let response = relay
        .push(
            &endpoint,
            first_case_body(),
            &[
                ("content-encoding", "aes128gcm"),
                ("ttl", "99999999"),
                ("urgency", "low"),
                ("topic", "not a valid topic"),
            ],
        )
        .await;
    assert_eq!(response.status(), 201);
    assert_eq!(response.headers()["ttl"], "2419200");

    let sent = relay.mock.apns();
    assert_eq!(sent[0].path, format!("/sandbox/3/device/{}", apns_token()));
    assert_eq!(sent[0].header("apns-priority"), Some("5"));
    assert_eq!(sent[0].header("apns-expiration"), Some("0"));
    assert_eq!(sent[0].header("apns-collapse-id"), None);
    assert_eq!(sent[1].header("apns-priority"), Some("5"));
    let expiration: u64 = sent[1].header("apns-expiration").unwrap().parse().unwrap();
    assert_near(expiration, now() + 2_419_200);
    assert_eq!(sent[1].header("apns-collapse-id"), None);
}

#[tokio::test]
async fn every_padded_size_is_forwarded() {
    let relay = start().await;
    let endpoint = relay.endpoint("apns", "prod").await;
    let bodies: Vec<Vec<u8>> = vectors()["cases"]
        .as_array()
        .unwrap()
        .iter()
        .map(|case| b64(&case["body"]))
        .collect();
    for size in [598, 1110, 2134] {
        assert!(
            bodies.iter().any(|body| body.len() == size),
            "no {size}-byte case in the vectors"
        );
    }
    for body in &bodies {
        let response = relay
            .push(&endpoint, body.clone(), &standard_headers())
            .await;
        assert_eq!(response.status(), 201, "{} bytes", body.len());
    }
    let sent = relay.mock.apns();
    assert_eq!(sent.len(), bodies.len());
    for (request, body) in sent.iter().zip(&bodies) {
        assert_eq!(request.json()["cp"]["d"], URL_SAFE_NO_PAD.encode(body));
    }
}

#[tokio::test]
async fn apns_errors_map_to_web_push_statuses() {
    let relay = start().await;
    let endpoint = relay.endpoint("apns", "prod").await;
    let cases = [
        (
            410,
            r#"{"reason":"Unregistered","timestamp":1760000000000}"#,
            410,
        ),
        (400, r#"{"reason":"BadDeviceToken"}"#, 410),
        (400, r#"{"reason":"DeviceTokenNotForTopic"}"#, 410),
        (400, r#"{"reason":"BadCollapseId"}"#, 502),
        (400, "", 502),
        (403, r#"{"reason":"InvalidProviderToken"}"#, 502),
        (413, r#"{"reason":"PayloadTooLarge"}"#, 413),
        (429, r#"{"reason":"TooManyRequests"}"#, 429),
        (500, r#"{"reason":"InternalServerError"}"#, 503),
        (503, r#"{"reason":"ServiceUnavailable"}"#, 503),
    ];
    for (apns_status, apns_body, expected) in cases {
        relay.mock.reply_apns(apns_status, apns_body);
        let response = relay.push_reply(&endpoint).await;
        assert_eq!(
            response.status(),
            expected,
            "APNs {apns_status} {apns_body}"
        );
        assert!(response.headers().get("location").is_none());
    }
    // One attempt each: only an expired provider token is retried.
    assert_eq!(relay.mock.apns().len(), cases.len());
}

#[tokio::test]
async fn apns_network_failure_is_503() {
    let relay = start_with(|env| {
        env.insert("APNS_HOST_PROD", UNREACHABLE.into());
    })
    .await;
    let endpoint = relay.endpoint("apns", "prod").await;
    assert_eq!(
        error_code(relay.push_reply(&endpoint).await).await,
        (503, "provider_unavailable".into())
    );
}

#[tokio::test]
async fn apns_expired_provider_token_is_refreshed_once() {
    let relay = start().await;
    let endpoint = relay.endpoint("apns", "prod").await;

    relay
        .mock
        .reply_apns(403, r#"{"reason":"ExpiredProviderToken"}"#);
    assert_eq!(relay.push_reply(&endpoint).await.status(), 201);
    let sent = relay.mock.apns();
    assert_eq!(sent.len(), 2);
    for request in &sent {
        let jwt = request
            .header("authorization")
            .unwrap()
            .strip_prefix("bearer ")
            .unwrap();
        let mut validation = Validation::new(Algorithm::ES256);
        validation.required_spec_claims.clear();
        validation.validate_exp = false;
        jsonwebtoken::decode::<Value>(
            jwt,
            &DecodingKey::from_ec_der(&keys().apns_public),
            &validation,
        )
        .unwrap();
    }
    // ECDSA signatures are randomized, so the re-minted token differs.
    assert_ne!(
        sent[0].header("authorization"),
        sent[1].header("authorization")
    );
    // The refreshed token is cached for the next push.
    assert_eq!(relay.push_reply(&endpoint).await.status(), 201);
    assert_eq!(
        relay.mock.apns()[2].header("authorization"),
        sent[1].header("authorization")
    );

    // A token rejected twice is not retried a third time.
    relay
        .mock
        .reply_apns(403, r#"{"reason":"ExpiredProviderToken"}"#);
    relay
        .mock
        .reply_apns(403, r#"{"reason":"ExpiredProviderToken"}"#);
    assert_eq!(
        error_code(relay.push_reply(&endpoint).await).await,
        (502, "provider_rejected".into())
    );
    assert_eq!(relay.mock.apns().len(), 5);
}

// ---------------------------------------------------------------- FCM

#[tokio::test]
async fn fcm_push_delivers_the_exact_request() {
    let relay = start().await;
    let endpoint = relay.endpoint("fcm", "prod").await;
    let body = first_case_body();
    assert_eq!(relay.push_reply(&endpoint).await.status(), 201);

    // OAuth: a JWT-bearer grant signed with the service account's key.
    let oauth = relay.mock.oauth();
    assert_eq!(oauth.len(), 1);
    assert_eq!(
        oauth[0].header("content-type"),
        Some("application/x-www-form-urlencoded")
    );
    let form: HashMap<String, String> = std::str::from_utf8(&oauth[0].body)
        .unwrap()
        .split('&')
        .map(|pair| {
            let (k, v) = pair.split_once('=').unwrap();
            (k.to_owned(), v.to_owned())
        })
        .collect();
    assert_eq!(
        form["grant_type"],
        "urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer"
    );
    let token_uri = format!("http://{}/token", relay.mock_addr);
    let mut validation = Validation::new(Algorithm::RS256);
    validation.set_audience(&[&token_uri]);
    let assertion = jsonwebtoken::decode::<Value>(
        &form["assertion"],
        &DecodingKey::from_rsa_der(&keys().fcm_public),
        &validation,
    )
    .unwrap();
    assert_eq!(assertion.header.alg, Algorithm::RS256);
    let claims = assertion.claims;
    assert_eq!(claims["iss"], CLIENT_EMAIL);
    assert_eq!(
        claims["scope"],
        "https://www.googleapis.com/auth/firebase.messaging"
    );
    assert_eq!(claims["aud"], token_uri);
    let iat = claims["iat"].as_u64().unwrap();
    assert_near(iat, now());
    assert_eq!(claims["exp"].as_u64().unwrap(), iat + 3600);

    // The send itself.
    let sent = relay.mock.fcm();
    assert_eq!(sent.len(), 1);
    assert_eq!(
        sent[0].path,
        format!("/v1/projects/{PROJECT}/messages:send")
    );
    assert_eq!(sent[0].header("authorization"), Some("Bearer tok-1"));
    // The `Topic` is not passed on: FCM would keep only four collapse keys
    // for an offline phone.
    assert_eq!(
        sent[0].json(),
        json!({"message": {
            "token": FCM_TOKEN,
            "data": {"cp_v": "1", "cp_s": SID, "cp_d": URL_SAFE_NO_PAD.encode(&body)},
            "android": {"priority": "HIGH", "ttl": "86400s", "restricted_package_name": APP}
        }})
    );

    // Normal urgency, no topic; the access token is reused.
    let response = relay
        .push(
            &endpoint,
            first_case_body(),
            &[
                ("content-encoding", "aes128gcm"),
                ("ttl", "259200"),
                ("urgency", "normal"),
            ],
        )
        .await;
    assert_eq!(response.status(), 201);
    assert_eq!(
        relay.mock.fcm()[1].json()["message"]["android"],
        json!({"priority": "NORMAL", "ttl": "259200s", "restricted_package_name": APP})
    );
    assert_eq!(relay.mock.oauth().len(), 1);
}

#[tokio::test]
async fn fcm_pushes_reach_only_the_registered_package() {
    let beta = format!("{APP}.beta");
    let relay = start_with(|env| {
        env.insert("FCM_APPS", format!("{APP},{APP}.beta"));
    })
    .await;
    let mut endpoints = Vec::new();
    for app in [APP, beta.as_str()] {
        let response = relay
            .register(&json!({"provider": "fcm", "token": FCM_TOKEN, "app": app, "env": "prod", "sid": SID}))
            .await;
        let body: Value = response.json().await.unwrap();
        endpoints.push(body["endpoint"].as_str().unwrap().to_owned());
    }
    for endpoint in &endpoints {
        assert_eq!(relay.push_reply(endpoint).await.status(), 201);
    }
    // The same token, sealed for two apps: FCM is told which one may get it.
    let sent = relay.mock.fcm();
    let package =
        |i: usize| sent[i].json()["message"]["android"]["restricted_package_name"].clone();
    assert_eq!(package(0), APP);
    assert_eq!(package(1), beta.as_str());
}

#[tokio::test]
async fn fcm_errors_map_to_web_push_statuses() {
    let relay = start().await;
    let endpoint = relay.endpoint("fcm", "prod").await;
    let fcm_error = |code: u16, status: &str, error_code: Option<&str>, message: &str| {
        let details = error_code
            .map(|c| format!(r#"[{{"@type":"type.googleapis.com/google.firebase.fcm.v1.FcmError","errorCode":"{c}"}}]"#))
            .unwrap_or_else(|| "[]".into());
        format!(
            r#"{{"error":{{"code":{code},"message":"{message}","status":"{status}","details":{details}}}}}"#
        )
    };
    let cases = [
        (
            404,
            fcm_error(
                404,
                "NOT_FOUND",
                Some("UNREGISTERED"),
                "Requested entity was not found.",
            ),
            410,
        ),
        (
            400,
            fcm_error(400, "INVALID_ARGUMENT", Some("UNREGISTERED"), "gone"),
            410,
        ),
        (
            403,
            fcm_error(
                403,
                "PERMISSION_DENIED",
                Some("SENDER_ID_MISMATCH"),
                "SenderId mismatch",
            ),
            // Every token answers this when the relay has the wrong Firebase
            // project, so it must not delete subscriptions.
            502,
        ),
        (
            400,
            fcm_error(
                400,
                "INVALID_ARGUMENT",
                Some("INVALID_ARGUMENT"),
                "The registration token is not a valid FCM registration token",
            ),
            410,
        ),
        (
            400,
            fcm_error(
                400,
                "INVALID_ARGUMENT",
                Some("INVALID_ARGUMENT"),
                "Invalid value at 'message.android.ttl'",
            ),
            502,
        ),
        (
            403,
            fcm_error(403, "PERMISSION_DENIED", None, "Permission denied"),
            502,
        ),
        (
            429,
            fcm_error(
                429,
                "RESOURCE_EXHAUSTED",
                Some("QUOTA_EXCEEDED"),
                "Quota exceeded",
            ),
            429,
        ),
        (
            500,
            fcm_error(500, "INTERNAL", Some("INTERNAL"), "Internal error"),
            503,
        ),
        (
            503,
            fcm_error(503, "UNAVAILABLE", Some("UNAVAILABLE"), "Unavailable"),
            503,
        ),
        (
            404,
            fcm_error(404, "NOT_FOUND", None, "Requested entity was not found."),
            410,
        ),
        // A 404 that isn't FCM's says nothing about the token.
        (404, String::new(), 502),
        (404, "<html><body>Not Found</body></html>".into(), 502),
    ];
    for (fcm_status, fcm_body, expected) in &cases {
        relay.mock.reply_fcm(*fcm_status, fcm_body);
        let response = relay.push_reply(&endpoint).await;
        assert_eq!(response.status(), *expected, "FCM {fcm_status} {fcm_body}");
    }
    assert_eq!(relay.mock.fcm().len(), cases.len());
}

#[tokio::test]
async fn fcm_401_refreshes_the_access_token_once() {
    let relay = start().await;
    let endpoint = relay.endpoint("fcm", "prod").await;
    relay
        .mock
        .reply_fcm(401, r#"{"error":{"code":401,"status":"UNAUTHENTICATED"}}"#);
    assert_eq!(relay.push_reply(&endpoint).await.status(), 201);
    let sent = relay.mock.fcm();
    assert_eq!(sent.len(), 2);
    assert_eq!(sent[0].header("authorization"), Some("Bearer tok-1"));
    assert_eq!(sent[1].header("authorization"), Some("Bearer tok-2"));
    assert_eq!(relay.mock.oauth().len(), 2);

    // Twice unauthorized: no third try.
    relay.mock.reply_fcm(401, "{}");
    relay.mock.reply_fcm(401, "{}");
    assert_eq!(
        error_code(relay.push_reply(&endpoint).await).await,
        (502, "provider_rejected".into())
    );
    assert_eq!(relay.mock.fcm().len(), 4);
    assert_eq!(relay.mock.oauth().len(), 3);
}

fn retry_after(response: &reqwest::Response) -> Option<u64> {
    response
        .headers()
        .get("retry-after")
        .map(|v| v.to_str().unwrap().parse().unwrap())
}

#[tokio::test(start_paused = true)]
async fn fcm_token_or_network_failure_is_503() {
    // The default.
    let backoff = Duration::from_secs(30);
    let relay = start().await;
    let endpoint = relay.endpoint_blocking("fcm").await;
    relay.mock.reply_oauth(400, r#"{"error":"invalid_grant"}"#);
    let failed = relay.push_reply_blocking(&endpoint).await;
    assert_eq!(failed.header("retry-after"), Some("30"), "{failed}");
    assert_eq!(
        (failed.status(), failed.error()),
        (503, "provider_unavailable".into())
    );
    assert!(relay.mock.fcm().is_empty());

    // The failure is remembered: until the backoff is over, pushes fail
    // without asking Google again.
    tokio::time::advance(backoff - Duration::from_millis(1)).await;
    let remembered = relay.push_reply_blocking(&endpoint).await;
    assert_eq!(remembered.header("retry-after"), Some("1"), "{remembered}");
    assert_eq!(remembered.status(), 503);
    assert_eq!(relay.mock.oauth().len(), 1);
    assert!(relay.mock.fcm().is_empty());

    // Once it is forgotten, the next push fetches again.
    tokio::time::advance(Duration::from_millis(1)).await;
    assert_eq!(relay.push_reply_blocking(&endpoint).await.status(), 201);
    assert_eq!(relay.mock.oauth().len(), 2);

    let relay = start_with(|env| {
        env.insert("FCM_API_BASE", UNREACHABLE.into());
    })
    .await;
    let endpoint = relay.endpoint_blocking("fcm").await;
    assert_eq!(relay.push_reply_blocking(&endpoint).await.status(), 503);
}

/// A push, sent when it is first polled, so that several can be in flight at
/// once.
fn push_in_flight(
    relay: &Relay,
    endpoint: &str,
) -> impl std::future::Future<Output = (u16, Option<u64>)> + Send + 'static {
    let mut request = relay.http.post(endpoint).body(first_case_body());
    for (name, value) in standard_headers() {
        request = request.header(name, value);
    }
    async move {
        let response = request.send().await.unwrap();
        (response.status().as_u16(), retry_after(&response))
    }
}

/// Sends a push from its own task.
fn spawn_push(relay: &Relay, endpoint: &str) -> tokio::task::JoinHandle<(u16, Option<u64>)> {
    tokio::spawn(push_in_flight(relay, endpoint))
}

#[tokio::test]
async fn fcm_token_fetches_are_shared_and_waiters_are_bounded() {
    let (mock_addr, mock) = start_mock().await;
    let relay = start_relay_with(base_env(mock_addr), mock, mock_addr, |config| {
        config.fcm.as_mut().unwrap().max_token_waiters = 2;
    })
    .await;
    let endpoint = relay.endpoint("fcm", "prod").await;

    // Google is slow, and then fails.
    let slow = relay.mock.oauth_gate.write().await;
    relay.mock.reply_oauth(500, "{}");
    let fetching = spawn_push(&relay, &endpoint);
    relay.mock.wait_for_token_requests(1).await;

    // Room for one more push to wait; the other two are refused at once.
    let mut others = tokio::task::JoinSet::new();
    for _ in 0..3 {
        others.spawn(push_in_flight(&relay, &endpoint));
    }
    for _ in 0..2 {
        assert_eq!(others.join_next().await.unwrap().unwrap().0, 503);
    }
    assert!(!fetching.is_finished());

    // The one fetch fails, and the push that waited for it does not try
    // again: both answer 503 with Retry-After.
    drop(slow);
    let waiting = others.join_next().await.unwrap().unwrap();
    for (status, retry_after) in [fetching.await.unwrap(), waiting] {
        assert_eq!(status, 503);
        assert!(retry_after.is_some_and(|s| (1..=30).contains(&s)));
    }
    assert_eq!(relay.mock.oauth().len(), 1);
    assert!(relay.mock.fcm().is_empty());
}

#[tokio::test]
async fn readiness_waits_for_a_token_fetch_the_pushes_filled_up() {
    let (mock_addr, mock) = start_mock().await;
    let relay = start_relay_with(base_env(mock_addr), mock, mock_addr, |config| {
        config.fcm.as_mut().unwrap().max_token_waiters = 1;
    })
    .await;
    let endpoint = relay.endpoint("fcm", "prod").await;

    // Google is slow, and the push waiting for it fills the waiter cap.
    let slow = relay.mock.oauth_gate.write().await;
    let fetching = spawn_push(&relay, &endpoint);
    relay.mock.wait_for_token_requests(1).await;

    // The probe goes in before a push that finds the cap full, and it waits
    // for that fetch rather than calling the relay not ready.
    let mut probe = write_blocking(
        relay.connect_blocking().await,
        b"GET /readyz HTTP/1.1\r\nHost: relay\r\n\r\n",
    )
    .await;
    assert_eq!(spawn_push(&relay, &endpoint).await.unwrap().0, 503);
    assert!(nothing_received(&probe));
    drop(slow);
    let answer = blocking(move || Answer::read(&mut probe)).await;
    assert_eq!((answer.status(), answer.body()), (200, "ready"), "{answer}");
    assert_eq!(fetching.await.unwrap().0, 201);
    assert_eq!(relay.mock.oauth().len(), 1);
}

// ---------------------------------------------------------------- push validation

#[tokio::test]
async fn push_validation_errors() {
    let relay = start().await;
    let endpoint = relay.endpoint("apns", "prod").await;
    let without = |name: &str| -> Headers {
        standard_headers()
            .into_iter()
            .filter(|(n, _)| *n != name)
            .collect()
    };
    let with = |name: &'static str, value: &'static str| {
        let mut headers = without(name);
        headers.push((name, value));
        headers
    };
    let body = first_case_body;
    let cases: Vec<(Vec<u8>, Headers, u16, &str)> = vec![
        (
            body(),
            without("content-encoding"),
            415,
            "unsupported_encoding",
        ),
        (
            body(),
            with("content-encoding", "aesgcm"),
            415,
            "unsupported_encoding",
        ),
        (body(), without("ttl"), 400, "invalid_ttl"),
        (body(), with("ttl", "-5"), 400, "invalid_ttl"),
        (body(), with("ttl", "soon"), 400, "invalid_ttl"),
        (
            reject_body("truncated"),
            standard_headers(),
            400,
            "unpadded",
        ),
        (vec![0; 100], standard_headers(), 400, "unpadded"),
        (Vec::new(), standard_headers(), 400, "unpadded"),
        (
            reject_body("too_large"),
            standard_headers(),
            413,
            "too_large",
        ),
        (vec![0; 64 * 1024], standard_headers(), 413, "too_large"),
        (
            reject_body("keyid_not_65"),
            standard_headers(),
            400,
            "invalid_header",
        ),
        (
            reject_body("record_size_too_small"),
            standard_headers(),
            400,
            "invalid_header",
        ),
    ];
    for (body, headers, status, code) in cases {
        let len = body.len();
        let got = error_code(relay.push(&endpoint, body, &headers).await).await;
        assert_eq!(got, (status, code.to_owned()), "{len} bytes, {headers:?}");
    }
    assert!(relay.mock.apns().is_empty());

    // Bodies only the device can reject still go through.
    for name in ["wrong_auth", "flipped_tag_bit", "not_last_record_delimiter"] {
        let response = relay
            .push(&endpoint, reject_body(name), &standard_headers())
            .await;
        assert_eq!(response.status(), 201, "{name}");
    }
}

/// Reads the relay's answer on `stream` until it holds `until` or the relay
/// closes the connection.
async fn read_answer(stream: &mut TcpStream, until: &str) -> String {
    let started = Instant::now();
    let mut received = Vec::new();
    let mut buf = [0u8; 1024];
    while !String::from_utf8_lossy(&received).contains(until) {
        let left = Duration::from_secs(5).saturating_sub(started.elapsed());
        match tokio::time::timeout(left, stream.read(&mut buf)).await {
            Err(_) => panic!("no {until:?} after 5 s"),
            Ok(Ok(0) | Err(_)) => break,
            Ok(Ok(n)) => received.extend_from_slice(&buf[..n]),
        }
    }
    String::from_utf8_lossy(&received).into_owned()
}

#[tokio::test]
async fn only_a_body_over_the_limit_is_413() {
    let (mock_addr, mock) = start_mock().await;
    let relay = start_relay_with(base_env(mock_addr), mock, mock_addr, |config| {
        config.body_timeout = Duration::from_millis(300);
    })
    .await;
    let endpoint = relay.endpoint("apns", "prod").await;
    let path = endpoint.strip_prefix(&relay.base).unwrap();
    let head = |framing: &str| {
        format!(
            "POST {path} HTTP/1.1\r\nHost: relay\r\nContent-Encoding: aes128gcm\r\n\
             TTL: 60\r\n{framing}\r\n\r\n"
        )
    };

    // Part of a 598-byte body, and then nothing.
    let mut stalled = relay.connect().await;
    stalled
        .write_all(head("Content-Length: 598").as_bytes())
        .await
        .unwrap();
    stalled.write_all(&first_case_body()[..100]).await.unwrap();
    let answer = read_answer(&mut stalled, r#"{"error":"request_timeout"}"#).await;
    assert!(answer.starts_with("HTTP/1.1 408"), "{answer}");
    assert!(
        answer.ends_with(r#"{"error":"request_timeout"}"#),
        "{answer}"
    );

    // A chunked body that announces no length still stops at the limit.
    let mut chunked = relay.connect().await;
    let mut request = head("Transfer-Encoding: chunked").into_bytes();
    request.extend_from_slice(b"1000\r\n");
    request.extend_from_slice(&[0; 4096]);
    request.extend_from_slice(b"\r\n0\r\n\r\n");
    chunked.write_all(&request).await.unwrap();
    let answer = read_answer(&mut chunked, r#"{"error":"too_large"}"#).await;
    assert!(answer.starts_with("HTTP/1.1 413"), "{answer}");
    assert!(answer.ends_with(r#"{"error":"too_large"}"#), "{answer}");

    let metrics = relay.metrics().await;
    for line in [
        "relay_push_total{provider=\"apns\",result=\"timeout\"} 1",
        "relay_push_total{provider=\"apns\",result=\"too_large\"} 1",
    ] {
        assert!(metrics.lines().any(|l| l == line), "{line} in\n{metrics}");
    }
    assert!(relay.mock.apns().is_empty());
}

#[tokio::test]
async fn bad_and_retired_endpoints() {
    let old = start().await;
    let endpoint = old.endpoint("apns", "prod").await;
    let sealed = sealed_part(&endpoint).to_owned();

    // Same keys, other process: the endpoint opens (the relay is stateless).
    let same = start().await;
    let url = |relay: &Relay, sealed: &str| format!("{}/v1/push/{sealed}", relay.base);
    assert_eq!(same.push_reply(&url(&same, &sealed)).await.status(), 201);

    // Rotated: kid 1 kept alongside the new active kid 2.
    let rotated = start_with(|env| {
        env.insert(
            "RELAY_SEAL_KEYS",
            format!("{},{}", seal_key(1), seal_key(2)),
        );
        env.insert("RELAY_SEAL_ACTIVE_KID", "2".into());
    })
    .await;
    assert_eq!(
        rotated.push_reply(&url(&rotated, &sealed)).await.status(),
        201
    );
    let fresh = rotated.endpoint("apns", "prod").await;
    assert_eq!(URL_SAFE_NO_PAD.decode(sealed_part(&fresh)).unwrap()[1], 2);

    // Retired: kid 1 removed.
    let retired = start_with(|env| {
        env.insert("RELAY_SEAL_KEYS", seal_key(2));
        env.insert("RELAY_SEAL_ACTIVE_KID", "2".into());
    })
    .await;
    assert_eq!(
        error_code(retired.push_reply(&url(&retired, &sealed)).await).await,
        (410, "key_retired".into())
    );

    let mut tampered = URL_SAFE_NO_PAD.decode(&sealed).unwrap();
    let last = tampered.len() - 1;
    tampered[last] ^= 1;
    for bad in [
        URL_SAFE_NO_PAD.encode(&tampered),
        "not-a-real-endpoint".to_owned(),
        "%FF%FE".to_owned(),
        "A".repeat(9000),
    ] {
        assert_eq!(
            error_code(old.push_reply(&url(&old, &bad)).await).await,
            (404, "not_found".into()),
            "{bad:.40}"
        );
    }
    assert_eq!(old.mock.apns().len(), 0);
}

#[tokio::test]
async fn unconfigured_provider_is_503() {
    // A relay that has both, to mint an APNs endpoint with the shared key.
    let full = start().await;
    let apns_endpoint = full.endpoint("apns", "prod").await;

    let fcm_only = start_with(|env| {
        env.remove("APNS_TEAM_ID");
        env.remove("APNS_KEY_ID");
        env.remove("APNS_KEY_P8");
        env.remove("APNS_APPS");
    })
    .await;
    let register = fcm_only
        .register(&json!({"provider": "apns", "token": apns_token(), "app": APP, "env": "prod", "sid": SID}))
        .await;
    assert_eq!(
        error_code(register).await,
        (503, "provider_unconfigured".into())
    );

    let url = format!("{}/v1/push/{}", fcm_only.base, sealed_part(&apns_endpoint));
    assert_eq!(
        error_code(fcm_only.push_reply(&url).await).await,
        (503, "provider_unconfigured".into())
    );
    // FCM still works.
    let fcm_endpoint = fcm_only.endpoint("fcm", "prod").await;
    assert_eq!(fcm_only.push_reply(&fcm_endpoint).await.status(), 201);
}

#[tokio::test]
async fn a_relay_without_providers_refuses_to_start() {
    let mut env = base_env("127.0.0.1:9".parse().unwrap());
    env.retain(|name, _| !name.starts_with("APNS_") && !name.starts_with("FCM_"));
    env.insert("RELAY_PUBLIC_URL", "http://relay.test".into());
    let config = Config::from_lookup(|name| env.get(name).cloned()).unwrap();
    assert!(matches!(
        AppState::new(&config),
        Err(StartupError::NoProviders)
    ));
}

#[tokio::test]
async fn apps_removed_from_the_allow_list_are_refused() {
    let full = start().await;
    let endpoint = full.endpoint("apns", "prod").await;
    let narrowed = start_with(|env| {
        env.insert("APNS_APPS", format!("{APP}.debug"));
    })
    .await;
    let url = format!("{}/v1/push/{}", narrowed.base, sealed_part(&endpoint));
    assert_eq!(
        error_code(narrowed.push_reply(&url).await).await,
        (403, "app_not_allowed".into())
    );
}

// ---------------------------------------------------------------- rate limits

#[tokio::test]
async fn pushes_are_rate_limited_per_endpoint() {
    let relay = start_with(|env| {
        env.insert("RELAY_RATE_ENDPOINT_BURST", "2".into());
    })
    .await;
    let endpoint = relay.endpoint("apns", "prod").await;
    assert_eq!(relay.push_reply(&endpoint).await.status(), 201);
    assert_eq!(relay.push_reply(&endpoint).await.status(), 201);
    let limited = relay.push_reply(&endpoint).await;
    assert_eq!(limited.headers()["retry-after"], "1");
    assert_eq!(error_code(limited).await, (429, "rate_limited".into()));
    assert_eq!(relay.mock.apns().len(), 2);

    // Another endpoint has its own bucket.
    let other = relay.endpoint("apns", "prod").await;
    assert_eq!(relay.push_reply(&other).await.status(), 201);
}

#[tokio::test]
async fn daily_quota_per_endpoint() {
    let relay = start_with(|env| {
        env.insert("RELAY_RATE_ENDPOINT_PER_DAY", "3".into());
    })
    .await;
    let endpoint = relay.endpoint("fcm", "prod").await;
    for _ in 0..3 {
        assert_eq!(relay.push_reply(&endpoint).await.status(), 201);
    }
    let limited = relay.push_reply(&endpoint).await;
    let retry_after: u64 = limited.headers()["retry-after"]
        .to_str()
        .unwrap()
        .parse()
        .unwrap();
    // 3 a day is one every 8 hours.
    assert!(retry_after > 60 * 60, "{retry_after}");
    assert_eq!(limited.status(), 429);
}

#[tokio::test]
async fn pushes_are_rate_limited_per_sender_ip() {
    let relay = start_with(|env| {
        env.insert("RELAY_RATE_IP_PER_MIN", "3".into());
        env.insert("RELAY_TRUST_FORWARDED_FOR", "true".into());
    })
    .await;
    let endpoint = relay.endpoint("apns", "prod").await;
    let from = |ip: &'static str| {
        let mut headers = standard_headers();
        headers.push(("x-forwarded-for", ip));
        headers
    };
    // Spoofed leading entries are ignored; the proxy's last entry counts.
    for spoof in [
        "1.1.1.1, 203.0.113.7",
        "2.2.2.2, 203.0.113.7",
        "203.0.113.7",
    ] {
        let response = relay.push(&endpoint, first_case_body(), &from(spoof)).await;
        assert_eq!(response.status(), 201);
    }
    let limited = relay
        .push(&endpoint, first_case_body(), &from("9.9.9.9, 203.0.113.7"))
        .await;
    assert_eq!(limited.status(), 429);
    assert!(limited.headers().contains_key("retry-after"));

    // Even pushes to bad endpoints count, so they cannot be used to probe.
    let other = from("198.51.100.4");
    let bogus = format!("{}/v1/push/bogus", relay.base);
    for _ in 0..3 {
        assert_eq!(
            relay.push(&bogus, first_case_body(), &other).await.status(),
            404
        );
    }
    assert_eq!(
        relay
            .push(&endpoint, first_case_body(), &other)
            .await
            .status(),
        429
    );
    assert_eq!(
        relay
            .push(&endpoint, first_case_body(), &from("198.51.100.5"))
            .await
            .status(),
        201
    );
}

#[tokio::test]
async fn forwarded_for_is_ignored_unless_trusted() {
    let relay = start_with(|env| {
        env.insert("RELAY_RATE_IP_PER_MIN", "2".into());
    })
    .await;
    let endpoint = relay.endpoint("apns", "prod").await;
    for (i, ip) in ["203.0.113.1", "203.0.113.2", "203.0.113.3"]
        .iter()
        .enumerate()
    {
        let mut headers = standard_headers();
        headers.push(("x-forwarded-for", ip));
        let status = relay
            .push(&endpoint, first_case_body(), &headers)
            .await
            .status();
        assert_eq!(status, if i < 2 { 201 } else { 429 }, "{ip}");
    }
}

// ---------------------------------------------------------------- metrics

#[tokio::test]
async fn metrics_count_by_provider_and_result_only() {
    let relay = start().await;
    let endpoint = relay.endpoint("apns", "prod").await;
    relay.push_reply(&endpoint).await;
    relay
        .push_reply(&format!("{}/v1/push/bogus", relay.base))
        .await;
    relay.mock.reply_apns(410, r#"{"reason":"Unregistered"}"#);
    relay.push_reply(&endpoint).await;

    let text = relay.metrics().await;
    for line in [
        "# TYPE relay_push_total counter",
        "relay_push_total{provider=\"apns\",result=\"sent\"} 1",
        "relay_push_total{provider=\"apns\",result=\"gone\"} 1",
        "relay_push_total{provider=\"none\",result=\"not_found\"} 1",
        "relay_register_total{provider=\"apns\",result=\"ok\"} 1",
    ] {
        assert!(
            text.lines().any(|l| l == line),
            "missing {line:?} in\n{text}"
        );
    }
    // Nothing that identifies a device, endpoint or sender.
    assert!(!text.contains(&apns_token()));
    assert!(!text.contains(sealed_part(&endpoint)));
    assert!(!text.contains("127.0.0.1"));
    for line in text.lines().filter(|l| !l.starts_with('#')) {
        let labels = line.split_once('{').unwrap().1.split_once('}').unwrap().0;
        assert_eq!(labels.split(',').count(), 2, "{line}");
    }
}

// ---------------------------------------------------------------- connections

async fn start_with_connections(limits: ConnectionLimits) -> Relay {
    let (mock_addr, mock) = start_mock().await;
    start_relay_with(base_env(mock_addr), mock, mock_addr, |config| {
        config.connections = limits;
    })
    .await
}

impl Relay {
    async fn connect(&self) -> TcpStream {
        TcpStream::connect(self.base.strip_prefix("http://").unwrap())
            .await
            .unwrap()
    }
}

#[tokio::test(start_paused = true)]
async fn clients_that_send_headers_too_slowly_are_dropped() {
    let timeout = Duration::from_millis(500);
    let relay = start_with_connections(ConnectionLimits {
        header_read_timeout: timeout,
        ..ConnectionLimits::default()
    })
    .await;
    // From the first answer, the client has `timeout` to send the next
    // request's headers. The idle bound, 30 s, is the only other timer that
    // could close the connection.
    let stream = healthz_blocking(relay.connect_blocking().await).await;
    let served = tokio::time::Instant::now();
    let mut stream = write_blocking(
        stream,
        b"POST /v1/register HTTP/1.1\r\nHost: relay\r\nX-Slow: ",
    )
    .await;

    // One header byte every 100 ms, so the headers never finish.
    for _ in 0..4 {
        tokio::time::advance(Duration::from_millis(100)).await;
        stream = write_blocking(stream, b"a").await;
    }
    let (closed_after, received) = read_until_closed(stream, served).await;
    assert_eq!(closed_after, timeout);
    // hyper may say 408 on the way out; the request itself never ran.
    assert!(
        received.is_empty() || received.starts_with(b"HTTP/1.1 408"),
        "{}",
        String::from_utf8_lossy(&received)
    );
    // Other clients are unaffected.
    healthz_blocking(relay.connect_blocking().await).await;
}

#[tokio::test(start_paused = true)]
async fn clients_that_send_nothing_are_dropped() {
    let timeout = Duration::from_millis(300);
    let relay = start_with_connections(ConnectionLimits {
        header_read_timeout: timeout,
        ..ConnectionLimits::default()
    })
    .await;
    // No timer runs until the relay takes the connection, so the clock stands
    // still until then.
    let connected = tokio::time::Instant::now();
    let silent = relay.connect_blocking().await;
    let (closed_after, _) = read_until_closed(silent, connected).await;
    assert_eq!(closed_after, timeout);
}

#[tokio::test(start_paused = true)]
async fn idle_connections_are_closed() {
    // The header timeout would also close an idle HTTP/1 connection; make it
    // long so that only the idle bound can.
    let idle = Duration::from_millis(300);
    let relay = start_with_connections(ConnectionLimits {
        header_read_timeout: Duration::from_secs(60),
        idle_timeout: idle,
        ..ConnectionLimits::default()
    })
    .await;
    let stream = healthz_blocking(relay.connect_blocking().await).await;

    // Used again just inside the bound: kept, and the bound starts over.
    tokio::time::advance(idle - Duration::from_millis(1)).await;
    let stream = healthz_blocking(stream).await;

    // Left alone, the clock auto-advances to the relay's next timer. Closing
    // early, or not at all (then the header timeout closes it), shows as
    // another time.
    let served = tokio::time::Instant::now();
    let (closed_after, _) = read_until_closed(stream, served).await;
    assert_eq!(closed_after, idle);
}

#[tokio::test(start_paused = true)]
async fn connections_over_the_cap_wait_for_a_free_slot() {
    let relay = start_with_connections(ConnectionLimits {
        max_connections: 1,
        ..ConnectionLimits::default()
    })
    .await;
    let first = healthz_blocking(relay.connect_blocking().await).await;

    // The first connection holds the only slot: it is still served, and the
    // second, whose request went in before the first's next one, is not.
    let mut second = write_blocking(relay.connect_blocking().await, HEALTHZ).await;
    let first = healthz_blocking(first).await;
    assert!(nothing_received(&second), "served over the cap");

    drop(first);
    let answer = blocking(move || Answer::read(&mut second)).await;
    assert_eq!((answer.status(), answer.body()), (200, "ok"), "{answer}");
}

#[tokio::test(start_paused = true)]
async fn shutdown_drops_connections_that_do_not_finish() {
    let (mock_addr, _mock) = start_mock().await;
    let mut env = base_env(mock_addr);
    env.insert("RELAY_PUBLIC_URL", "http://relay.test".into());
    let config = Config::from_lookup(|name| env.get(name).cloned()).unwrap();
    let state = Arc::new(AppState::new(&config).unwrap());
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    let drain = Duration::from_millis(300);
    let limits = ConnectionLimits {
        drain_deadline: drain,
        ..ConnectionLimits::default()
    };
    let (stop, stopped) = tokio::sync::oneshot::channel::<()>();
    let server = tokio::spawn(conduit_push_relay::serve(
        listener,
        state,
        limits,
        async move {
            let _ = stopped.await;
        },
    ));

    // A request whose body never comes. Once the relay asks for the body,
    // the request is in progress, and shutdown waits for it.
    let mut stuck = connect_blocking(addr).await;
    let (stuck, interim) = blocking(move || {
        use std::io::Write;
        stuck
            .write_all(
                b"POST /v1/register HTTP/1.1\r\nHost: relay\r\n\
                  Expect: 100-continue\r\nContent-Length: 100\r\n\r\n",
            )
            .unwrap();
        let interim = read_head(&mut stuck);
        (stuck, interim)
    })
    .await;
    assert_eq!(interim, "HTTP/1.1 100 Continue\r\n\r\n");

    let stopping = tokio::time::Instant::now();
    stop.send(()).unwrap();
    server.await.unwrap();
    assert_eq!(stopping.elapsed(), drain);
    let (closed_after, received) = read_until_closed(stuck, stopping).await;
    assert_eq!(closed_after, drain);
    assert!(
        received.is_empty(),
        "{}",
        String::from_utf8_lossy(&received)
    );
    assert!(blocking(move || std::net::TcpStream::connect(addr))
        .await
        .is_err());
}
