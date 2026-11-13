//! The one JSON-RPC 2.0 connection a Conduit Desktop process keeps to
//! `conduitd`, on `ws://127.0.0.1:<port>/rpc`.
//!
//! * **Auth:** the upgrade sends `Origin: app://conduit` and the subprotocols
//!   `["conduit.v1", "tk." + base64url_nopad(token)]`; the daemon must select
//!   `conduit.v1` (never the token entry).
//! * **Handshake first:** `system.handshake {protocolVersion, clientName,
//!   clientVersion, windowKind, locale}` precedes every other frame of a
//!   session. A protocol version mismatch is fatal: no reconnect.
//! * **Liveness:** `system.ping` every [`RpcConfig::ping_interval`]; no answer
//!   for [`RpcConfig::ping_timeout`] and the socket is treated as dead.
//! * **Reconnect:** full-jitter backoff, at most
//!   [`RpcConfig::reconnect_attempts`] times in a row; every new session
//!   re-sends the last `events.subscribe`. A new endpoint (the supervisor
//!   restarted the daemon) reconnects at once with a fresh budget.
//! * **Core start-up:** calls answered `rpc.daemonUnavailable` are re-sent
//!   with backoff for up to [`RpcConfig::unavailable_budget`].
//! * **Events:** `event` notifications `{event, seq, scope?, payload}`; a gap in
//!   a session's `seq` is reported so stores refetch instead of patching.
//!
//! The UI side holds an [`RpcClient`] (cheap to clone). Its futures only wait
//! on channels, so any executor can await them; all I/O and timers run on
//! the tokio runtime the client was started on.

use std::collections::{HashMap, VecDeque};
use std::time::{Duration, Instant};

use futures_util::{SinkExt as _, StreamExt as _};
use rand::Rng as _;
use serde_json::{Value, json};
use tokio::net::TcpStream;
use tokio::runtime::Handle;
use tokio::sync::{mpsc, oneshot, watch};
use tokio::time::{interval, sleep_until, timeout};
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::tungstenite::client::IntoClientRequest as _;
use tokio_tungstenite::tungstenite::http::HeaderValue;
use tokio_tungstenite::{MaybeTlsStream, WebSocketStream};

use crate::protocol::{
    APP_ORIGIN, EVENT_NOTIFICATION, EventEnvelope, HandshakeRequest, HandshakeResponse,
    PROTOCOL_VERSION, RpcError, RpcErrorExt as _, RpcMethod, SUBPROTOCOL, WindowKind, codes, error,
    error_from_wire,
};
use crate::secrets::subprotocol_token;

#[derive(Clone, Debug)]
pub struct RpcConfig {
    pub token: String,
    pub client_name: String,
    pub client_version: String,
    /// `main`, `quickAsk` or `headless`.
    pub window_kind: String,
    /// BCP-47, e.g. `zh-Hant`.
    pub locale: String,
    pub protocol_version: String,
    pub host: String,
    pub ping_interval: Duration,
    pub ping_timeout: Duration,
    pub call_timeout: Duration,
    pub connect_timeout: Duration,
    pub reconnect_attempts: u32,
    pub reconnect_base: Duration,
    pub reconnect_cap: Duration,
    pub unavailable_budget: Duration,
    pub unavailable_step: Duration,
}

impl RpcConfig {
    pub fn new(token: impl Into<String>, client_version: impl Into<String>) -> Self {
        Self {
            token: token.into(),
            client_name: "conduit-desktop".into(),
            client_version: client_version.into(),
            window_kind: "main".into(),
            locale: "en".into(),
            protocol_version: PROTOCOL_VERSION.into(),
            host: "127.0.0.1".into(),
            ping_interval: Duration::from_secs(5),
            ping_timeout: Duration::from_secs(15),
            call_timeout: Duration::from_secs(60),
            connect_timeout: Duration::from_secs(10),
            reconnect_attempts: 8,
            reconnect_base: Duration::from_millis(250),
            reconnect_cap: Duration::from_secs(8),
            unavailable_budget: Duration::from_secs(30),
            unavailable_step: Duration::from_millis(250),
        }
    }
}

impl RpcConfig {
    /// `system.handshake`'s params.
    pub fn handshake_request(&self) -> HandshakeRequest {
        HandshakeRequest {
            protocol_version: self.protocol_version.clone(),
            client_name: self.client_name.clone(),
            client_version: self.client_version.clone(),
            window_kind: match self.window_kind.as_str() {
                "quickAsk" => WindowKind::QuickAsk,
                "headless" => WindowKind::Headless,
                _ => WindowKind::Main,
            },
            locale: self.locale.clone(),
        }
    }

    /// [`Self::handshake_request`] as JSON.
    pub fn handshake_params(&self) -> Value {
        serde_json::to_value(self.handshake_request()).unwrap_or(Value::Null)
    }
}

/// The `system.handshake` reply, with the fields the shell reads lifted out.
#[derive(Clone, Debug, PartialEq)]
pub struct Handshake {
    pub protocol_version: String,
    pub daemon_version: String,
    pub session_id: String,
    pub platform: String,
    /// `None` when the reply had no boolean (treated as unknown, never as
    /// "no").
    pub needs_onboarding: Option<bool>,
    /// The whole reply, typed: capabilities and the daemon's paths. `None`
    /// when it did not decode (the fields above still hold what did).
    pub response: Option<Box<HandshakeResponse>>,
    pub raw: Value,
}

impl Handshake {
    pub fn from_value(v: Value) -> Self {
        let s = |k: &str| {
            v.get(k)
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_string()
        };
        Self {
            protocol_version: s("protocolVersion"),
            daemon_version: s("daemonVersion"),
            session_id: s("sessionId"),
            platform: s("platform"),
            needs_onboarding: v.get("needsOnboarding").and_then(Value::as_bool),
            response: serde_json::from_value(v.clone()).ok(),
            raw: v,
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub enum ConnectionState {
    /// No daemon endpoint yet (starting, or restarting).
    WaitingForDaemon,
    Connecting {
        attempt: u32,
    },
    Connected(Handshake),
    /// The socket dropped or a connect failed; trying again after `delay`.
    Reconnecting {
        attempt: u32,
        delay: Duration,
        error: String,
    },
    /// Gave up after [`RpcConfig::reconnect_attempts`]; [`RpcClient::retry`]
    /// starts over.
    Failed {
        error: String,
    },
    /// Fatal: this app and its daemon speak different protocol versions.
    VersionMismatch {
        daemon: String,
        app: String,
    },
}

#[derive(Clone, Debug, PartialEq)]
pub enum ClientEvent {
    State(ConnectionState),
    Event(EventEnvelope),
    /// Events were lost within a session: refetch rather than patch.
    Gap {
        expected: i64,
        got: i64,
    },
}

struct PendingCall {
    method: String,
    params: Value,
    reply: oneshot::Sender<Result<Value, RpcError>>,
    created: Instant,
    deadline: Instant,
    unavailable_retries: u32,
}

impl PendingCall {
    fn finish(self, result: Result<Value, RpcError>) {
        let _ = self.reply.send(result);
    }
}

enum Cmd {
    Call(PendingCall),
    Subscribe(Value),
    Retry,
    Shutdown,
}

/// A handle to the connection task. Clones share the connection.
#[derive(Clone)]
pub struct RpcClient {
    cmds: mpsc::UnboundedSender<Cmd>,
    endpoint: std::sync::Arc<watch::Sender<Option<u16>>>,
    call_timeout: Duration,
}

impl RpcClient {
    /// Starts the connection task on `rt`. It waits for
    /// [`Self::set_endpoint`] before connecting.
    pub fn start(config: RpcConfig, rt: &Handle) -> (Self, mpsc::UnboundedReceiver<ClientEvent>) {
        let (cmds, cmd_rx) = mpsc::unbounded_channel();
        let (events, event_rx) = mpsc::unbounded_channel();
        let (endpoint, endpoint_rx) = watch::channel(None);
        let call_timeout = config.call_timeout;
        let conn = Connection {
            config,
            events,
            cmds: cmd_rx,
            endpoint: endpoint_rx,
            queue: VecDeque::new(),
            delayed: vec![],
            subscription: None,
            next_id: 1,
            state: None,
        };
        rt.spawn(conn.run());
        (
            Self {
                cmds,
                endpoint: std::sync::Arc::new(endpoint),
                call_timeout,
            },
            event_rx,
        )
    }

    /// The daemon's port, or `None` while it is down. A new port reconnects
    /// at once.
    pub fn set_endpoint(&self, port: Option<u16>) {
        self.endpoint.send_if_modified(|current| {
            let changed = *current != port;
            *current = port;
            changed
        });
    }

    /// Calls `method` with named `params` (`Value::Null` sends none). Waits
    /// for a connection if there is none yet, and re-sends while the daemon
    /// answers `rpc.daemonUnavailable`.
    ///
    /// The future borrows nothing (`use<S>`): it can outlive the client
    /// handle and the call site, and be awaited on any executor.
    pub fn call_value<S: Into<String>>(
        &self,
        method: S,
        params: Value,
    ) -> impl Future<Output = Result<Value, RpcError>> + Send + 'static + use<S> {
        self.call_value_with_timeout(method, params, self.call_timeout)
    }

    pub fn call_value_with_timeout<S: Into<String>>(
        &self,
        method: S,
        params: Value,
        call_timeout: Duration,
    ) -> impl Future<Output = Result<Value, RpcError>> + Send + 'static + use<S> {
        let (reply, rx) = oneshot::channel();
        let now = Instant::now();
        let sent = self.cmds.send(Cmd::Call(PendingCall {
            method: method.into(),
            params,
            reply,
            created: now,
            deadline: now + call_timeout,
            unavailable_retries: 0,
        }));
        async move {
            if sent.is_err() {
                return Err(closed_error());
            }
            rx.await.unwrap_or_else(|_| Err(closed_error()))
        }
    }

    /// A typed call: `M::Params` out, `M::Result` back. The generated
    /// `conduit-protocol` markers go through here unchanged.
    pub fn call<M: RpcMethod>(
        &self,
        params: &M::Params,
    ) -> impl Future<Output = Result<M::Result, RpcError>> + Send + 'static + use<M>
    where
        M::Result: Send + 'static,
    {
        let call = serde_json::to_value(params)
            .map(|p| self.call_value(M::NAME, p))
            .map_err(|e| error(codes::INVALID_PARAMS, format!("{}: {e}", M::NAME)));
        async move {
            let value = call?.await?;
            serde_json::from_value::<M::Result>(value)
                .map_err(|e| error(codes::DECODE, format!("{}: {e}", M::NAME)))
        }
    }

    /// Replaces the event subscription (`events.subscribe`): sent now when
    /// connected, and again on every reconnect. Empty `events` means all.
    pub fn subscribe(&self, events: &[&str], scopes: &[String]) {
        let _ = self.cmds.send(Cmd::Subscribe(json!({
            "events": events,
            "scopes": scopes,
        })));
    }

    /// Starts over after [`ConnectionState::Failed`] or a mismatch.
    pub fn retry(&self) {
        let _ = self.cmds.send(Cmd::Retry);
    }

    /// Closes the connection and fails everything pending.
    pub fn shutdown(&self) {
        let _ = self.cmds.send(Cmd::Shutdown);
    }
}

fn closed_error() -> RpcError {
    error(codes::CLOSED, "the connection to the daemon is closed")
}

fn disconnected_error() -> RpcError {
    error(
        codes::DISCONNECTED,
        "the connection dropped during the call",
    )
    .retryable()
}

fn timeout_error(method: &str) -> RpcError {
    error(codes::TIMEOUT, format!("{method} timed out")).retryable()
}

/// Full jitter: uniform in `[0, min(cap, base·2^n))`.
pub fn full_jitter(base: Duration, cap: Duration, n: u32) -> Duration {
    let ceiling = base.saturating_mul(1u32 << n.min(16)).min(cap);
    let ms = ceiling.as_millis() as u64;
    if ms == 0 {
        return Duration::ZERO;
    }
    Duration::from_millis(rand::rng().random_range(0..ms))
}

type Ws = WebSocketStream<MaybeTlsStream<TcpStream>>;

enum Inflight {
    User(PendingCall),
    Ping,
    Internal(&'static str),
}

enum End {
    Shutdown,
    EndpointChanged,
    Lost { error: String, connected: bool },
    Mismatch { daemon: String, app: String },
}

enum Idle {
    Shutdown,
    EndpointChanged,
    Retry,
    Elapsed,
}

struct Connection {
    config: RpcConfig,
    events: mpsc::UnboundedSender<ClientEvent>,
    cmds: mpsc::UnboundedReceiver<Cmd>,
    endpoint: watch::Receiver<Option<u16>>,
    /// Calls waiting for a session.
    queue: VecDeque<PendingCall>,
    /// Calls the daemon answered `daemonUnavailable`, due again at a time.
    delayed: Vec<(Instant, PendingCall)>,
    subscription: Option<Value>,
    next_id: u64,
    state: Option<ConnectionState>,
}

impl Connection {
    fn set_state(&mut self, state: ConnectionState) {
        if self.state.as_ref() != Some(&state) {
            self.state = Some(state.clone());
            let _ = self.events.send(ClientEvent::State(state));
        }
    }

    fn id(&mut self) -> u64 {
        let id = self.next_id;
        self.next_id += 1;
        id
    }

    /// Fails every call that has not been sent.
    fn fail_waiting(&mut self, error: impl Fn() -> RpcError) {
        for call in self.queue.drain(..) {
            call.finish(Err(error()));
        }
        for (_, call) in self.delayed.drain(..) {
            call.finish(Err(error()));
        }
    }

    fn expire_waiting(&mut self, now: Instant) {
        let (expired, kept): (Vec<_>, Vec<_>) =
            self.queue.drain(..).partition(|c| c.deadline <= now);
        self.queue = kept.into();
        for call in expired {
            let e = timeout_error(&call.method);
            call.finish(Err(e));
        }
        let (expired, kept): (Vec<_>, Vec<_>) =
            self.delayed.drain(..).partition(|(_, c)| c.deadline <= now);
        self.delayed = kept;
        for (_, call) in expired {
            let e = timeout_error(&call.method);
            call.finish(Err(e));
        }
    }

    async fn run(mut self) {
        // Consecutive failed connects since the last good session.
        let mut failures = 0u32;
        loop {
            let Some(port) = *self.endpoint.borrow_and_update() else {
                self.set_state(ConnectionState::WaitingForDaemon);
                match self.idle(None, None).await {
                    Idle::Shutdown => break,
                    _ => continue,
                }
            };
            self.set_state(ConnectionState::Connecting {
                attempt: failures + 1,
            });
            match self.session(port).await {
                End::Shutdown => break,
                End::EndpointChanged => failures = 0,
                End::Mismatch { daemon, app } => {
                    log::error!("protocol mismatch: daemon {daemon}, app {app}");
                    self.set_state(ConnectionState::VersionMismatch {
                        daemon: daemon.clone(),
                        app: app.clone(),
                    });
                    let mut mismatch = error(
                        codes::PROTOCOL_VERSION_MISMATCH,
                        "the daemon speaks another protocol version",
                    );
                    mismatch.args.insert("expected".into(), daemon.clone());
                    mismatch.args.insert("actual".into(), app.clone());
                    self.fail_waiting(|| mismatch.clone());
                    match self.idle(None, Some(&mismatch)).await {
                        Idle::Shutdown => break,
                        _ => failures = 0,
                    }
                }
                End::Lost { error, connected } => {
                    if connected {
                        failures = 0;
                    }
                    log::warn!("daemon connection lost: {error}");
                    if failures >= self.config.reconnect_attempts {
                        self.set_state(ConnectionState::Failed {
                            error: error.clone(),
                        });
                        self.fail_waiting(disconnected_error);
                        match self.idle(None, Some(&disconnected_error())).await {
                            Idle::Shutdown => break,
                            _ => {
                                failures = 0;
                                continue;
                            }
                        }
                    }
                    let delay = full_jitter(
                        self.config.reconnect_base,
                        self.config.reconnect_cap,
                        failures,
                    );
                    failures += 1;
                    self.set_state(ConnectionState::Reconnecting {
                        attempt: failures,
                        delay,
                        error,
                    });
                    match self.idle(Some(Instant::now() + delay), None).await {
                        Idle::Shutdown => break,
                        Idle::EndpointChanged | Idle::Retry => failures = 0,
                        Idle::Elapsed => {}
                    }
                }
            }
        }
        self.fail_waiting(closed_error);
    }

    /// Waits without a session: queues calls (or, after a fatal state,
    /// fails them at once with `reject`), keeps the subscription, expires
    /// deadlines. Ends on shutdown, a new endpoint, `retry`, or `until`.
    async fn idle(&mut self, until: Option<Instant>, reject: Option<&RpcError>) -> Idle {
        let mut tick = interval(Duration::from_millis(100));
        let start = *self.endpoint.borrow();
        loop {
            let wake = until.unwrap_or_else(|| Instant::now() + Duration::from_secs(3600));
            tokio::select! {
                _ = sleep_until(wake.into()), if until.is_some() => return Idle::Elapsed,
                changed = self.endpoint.changed() => {
                    if changed.is_err() {
                        return Idle::Shutdown;
                    }
                    if *self.endpoint.borrow() != start {
                        return Idle::EndpointChanged;
                    }
                }
                cmd = self.cmds.recv() => match cmd {
                    Some(Cmd::Call(call)) => match reject {
                        Some(e) => call.finish(Err(e.clone())),
                        None => self.queue.push_back(call),
                    },
                    Some(Cmd::Subscribe(sub)) => self.subscription = Some(sub),
                    Some(Cmd::Retry) => return Idle::Retry,
                    Some(Cmd::Shutdown) | None => return Idle::Shutdown,
                },
                _ = tick.tick() => self.expire_waiting(Instant::now()),
            }
        }
    }

    async fn connect(&self, port: u16) -> Result<Ws, String> {
        let url = format!("ws://{}:{port}/rpc", self.config.host);
        let mut request = url.into_client_request().map_err(|e| e.to_string())?;
        let headers = request.headers_mut();
        headers.insert("Origin", HeaderValue::from_static(APP_ORIGIN));
        let protocols = format!("{SUBPROTOCOL}, {}", subprotocol_token(&self.config.token));
        headers.insert(
            "Sec-WebSocket-Protocol",
            HeaderValue::from_str(&protocols).map_err(|e| e.to_string())?,
        );
        let (ws, response) = timeout(
            self.config.connect_timeout,
            tokio_tungstenite::connect_async(request),
        )
        .await
        .map_err(|_| "connect timed out".to_string())?
        .map_err(|e| e.to_string())?;
        let selected = response
            .headers()
            .get("Sec-WebSocket-Protocol")
            .and_then(|v| v.to_str().ok())
            .unwrap_or_default();
        if selected != SUBPROTOCOL {
            return Err(format!(
                "the daemon selected subprotocol {selected:?}, not {SUBPROTOCOL}"
            ));
        }
        Ok(ws)
    }

    fn request_frame(id: u64, method: &str, params: &Value) -> Message {
        let mut frame = json!({"jsonrpc": "2.0", "id": id, "method": method});
        if !params.is_null() {
            frame["params"] = params.clone();
        }
        Message::text(frame.to_string())
    }

    async fn session(&mut self, port: u16) -> End {
        let ws = match self.connect(port).await {
            Ok(ws) => ws,
            Err(error) => {
                return End::Lost {
                    error,
                    connected: false,
                };
            }
        };
        let (mut sink, mut stream) = ws.split();

        // Handshake: the first frame of every session.
        let hs_id = self.id();
        let params = self.config.handshake_params();
        if let Err(e) = sink
            .send(Self::request_frame(hs_id, "system.handshake", &params))
            .await
        {
            return End::Lost {
                error: e.to_string(),
                connected: false,
            };
        }
        let mut early: Vec<Value> = vec![];
        let deadline = tokio::time::Instant::now() + self.config.connect_timeout;
        let reply = loop {
            let next = match tokio::time::timeout_at(deadline, stream.next()).await {
                Err(_) => {
                    return End::Lost {
                        error: "no handshake reply".into(),
                        connected: false,
                    };
                }
                Ok(None) | Ok(Some(Err(_))) => {
                    return End::Lost {
                        error: "closed during the handshake".into(),
                        connected: false,
                    };
                }
                Ok(Some(Ok(m))) => m,
            };
            let Message::Text(text) = next else { continue };
            let Ok(v) = serde_json::from_str::<Value>(text.as_str()) else {
                continue;
            };
            if v.get("id").and_then(Value::as_u64) == Some(hs_id) && v.get("method").is_none() {
                break v;
            }
            early.push(v);
        };
        if let Some(error) = reply.get("error") {
            let e = error_from_wire(error);
            if e.is(codes::PROTOCOL_VERSION_MISMATCH) {
                return End::Mismatch {
                    daemon: e.args.get("expected").cloned().unwrap_or_default(),
                    app: self.config.protocol_version.clone(),
                };
            }
            return End::Lost {
                error: format!("handshake refused: {e}"),
                connected: false,
            };
        }
        let handshake = Handshake::from_value(reply.get("result").cloned().unwrap_or(Value::Null));
        if handshake.protocol_version != self.config.protocol_version {
            return End::Mismatch {
                daemon: handshake.protocol_version,
                app: self.config.protocol_version.clone(),
            };
        }

        let mut inflight: HashMap<u64, Inflight> = HashMap::new();
        if let Some(sub) = self.subscription.clone() {
            let id = self.id();
            if sink
                .send(Self::request_frame(id, "events.subscribe", &sub))
                .await
                .is_err()
            {
                return End::Lost {
                    error: "closed while subscribing".into(),
                    connected: false,
                };
            }
            inflight.insert(id, Inflight::Internal("events.subscribe"));
        }
        self.set_state(ConnectionState::Connected(handshake));
        let mut last_seq = 0i64;
        for v in early {
            self.on_message(v, &mut inflight, &mut last_seq, &mut None);
        }

        // Everything that waited for a session goes now.
        let waiting: Vec<PendingCall> = self.queue.drain(..).collect();
        for call in waiting {
            if let Err(error) = self.send_call(&mut sink, &mut inflight, call).await {
                return self.lost(inflight, error);
            }
        }

        let mut tick = interval(Duration::from_millis(50));
        let mut last_ping = Instant::now();
        let mut unanswered_since: Option<Instant> = None;
        loop {
            tokio::select! {
                msg = stream.next() => match msg {
                    Some(Ok(Message::Text(text))) => {
                        if let Ok(v) = serde_json::from_str::<Value>(text.as_str())
                            && let Some(reply) =
                                self.on_message(v, &mut inflight, &mut last_seq, &mut unanswered_since)
                            && sink.send(reply).await.is_err()
                        {
                            return self.lost(inflight, "closed".into());
                        }
                    }
                    Some(Ok(Message::Close(_))) | None => {
                        return self.lost(inflight, "the daemon closed the socket".into());
                    }
                    Some(Ok(_)) => {}
                    Some(Err(e)) => return self.lost(inflight, e.to_string()),
                },
                cmd = self.cmds.recv() => match cmd {
                    Some(Cmd::Call(call)) => {
                        if let Err(error) = self.send_call(&mut sink, &mut inflight, call).await {
                            return self.lost(inflight, error);
                        }
                    }
                    Some(Cmd::Subscribe(sub)) => {
                        self.subscription = Some(sub.clone());
                        let id = self.id();
                        if sink.send(Self::request_frame(id, "events.subscribe", &sub)).await.is_err() {
                            return self.lost(inflight, "closed while subscribing".into());
                        }
                        inflight.insert(id, Inflight::Internal("events.subscribe"));
                    }
                    Some(Cmd::Retry) => {}
                    Some(Cmd::Shutdown) | None => {
                        let _ = sink.send(Message::Close(None)).await;
                        for (_, f) in inflight.drain() {
                            if let Inflight::User(call) = f {
                                call.finish(Err(closed_error()));
                            }
                        }
                        return End::Shutdown;
                    }
                },
                changed = self.endpoint.changed() => {
                    if changed.is_err() {
                        return End::Shutdown;
                    }
                    if *self.endpoint.borrow() != Some(port) {
                        let _ = sink.send(Message::Close(None)).await;
                        self.lost(inflight, "the daemon restarted".into());
                        return End::EndpointChanged;
                    }
                }
                _ = tick.tick() => {
                    let now = Instant::now();
                    if let Some(since) = unanswered_since
                        && now.duration_since(since) >= self.config.ping_timeout
                    {
                        return self.lost(
                            inflight,
                            format!("no answer to system.ping for {:?}", self.config.ping_timeout),
                        );
                    }
                    if now.duration_since(last_ping) >= self.config.ping_interval {
                        last_ping = now;
                        let id = self.id();
                        if sink.send(Self::request_frame(id, "system.ping", &Value::Null)).await.is_err() {
                            return self.lost(inflight, "closed".into());
                        }
                        inflight.insert(id, Inflight::Ping);
                        unanswered_since.get_or_insert(now);
                    }
                    // Calls past their deadline.
                    let expired: Vec<u64> = inflight
                        .iter()
                        .filter_map(|(id, f)| match f {
                            Inflight::User(c) if c.deadline <= now => Some(*id),
                            _ => None,
                        })
                        .collect();
                    for id in expired {
                        if let Some(Inflight::User(call)) = inflight.remove(&id) {
                            let e = timeout_error(&call.method);
                            call.finish(Err(e));
                        }
                    }
                    self.expire_waiting(now);
                    // `daemonUnavailable` retries that are due.
                    let (due, later): (Vec<_>, Vec<_>) =
                        self.delayed.drain(..).partition(|(at, _)| *at <= now);
                    self.delayed = later;
                    for (_, call) in due {
                        if let Err(error) = self.send_call(&mut sink, &mut inflight, call).await {
                            return self.lost(inflight, error);
                        }
                    }
                }
            }
        }
    }

    /// Fails in-flight calls (the daemon may have run them, so they are not
    /// re-sent) and reports the loss.
    fn lost(&mut self, inflight: HashMap<u64, Inflight>, error: String) -> End {
        for (_, f) in inflight {
            if let Inflight::User(call) = f {
                call.finish(Err(disconnected_error()));
            }
        }
        End::Lost {
            error,
            connected: true,
        }
    }

    async fn send_call(
        &mut self,
        sink: &mut futures_util::stream::SplitSink<Ws, Message>,
        inflight: &mut HashMap<u64, Inflight>,
        call: PendingCall,
    ) -> Result<(), String> {
        let id = self.id();
        let frame = Self::request_frame(id, &call.method, &call.params);
        match sink.send(frame).await {
            Ok(()) => {
                inflight.insert(id, Inflight::User(call));
                Ok(())
            }
            Err(e) => {
                // Never sent: it can wait for the next session.
                self.queue.push_front(call);
                Err(e.to_string())
            }
        }
    }

    /// Handles one inbound frame; returns a frame to send back, if any.
    fn on_message(
        &mut self,
        v: Value,
        inflight: &mut HashMap<u64, Inflight>,
        last_seq: &mut i64,
        unanswered_since: &mut Option<Instant>,
    ) -> Option<Message> {
        if let Some(method) = v.get("method").and_then(Value::as_str) {
            if let Some(id) = v.get("id") {
                // The daemon does not call the app; say so.
                return Some(Message::text(
                    json!({
                        "jsonrpc": "2.0",
                        "id": id,
                        "error": {"code": -32601, "message": format!("no method {method}")},
                    })
                    .to_string(),
                ));
            }
            if method == EVENT_NOTIFICATION {
                let params = v.get("params").cloned().unwrap_or(Value::Null);
                match serde_json::from_value::<EventEnvelope>(params) {
                    Ok(envelope) => {
                        let expected = *last_seq + 1;
                        if envelope.seq != expected {
                            let _ = self.events.send(ClientEvent::Gap {
                                expected,
                                got: envelope.seq,
                            });
                        }
                        *last_seq = envelope.seq;
                        let _ = self.events.send(ClientEvent::Event(envelope));
                    }
                    Err(e) => log::warn!("bad event envelope: {e}"),
                }
            }
            return None;
        }
        let id = v.get("id").and_then(Value::as_u64)?;
        match inflight.remove(&id)? {
            Inflight::Ping => *unanswered_since = None,
            Inflight::Internal(what) => {
                if let Some(error) = v.get("error") {
                    log::warn!("{what} failed: {}", error_from_wire(error));
                }
            }
            Inflight::User(mut call) => {
                if let Some(error) = v.get("error") {
                    let e = error_from_wire(error);
                    let now = Instant::now();
                    if e.is(codes::DAEMON_UNAVAILABLE)
                        && now.duration_since(call.created) < self.config.unavailable_budget
                        && now < call.deadline
                    {
                        let step = self
                            .config
                            .unavailable_step
                            .saturating_mul(1u32 << call.unavailable_retries.min(3));
                        call.unavailable_retries += 1;
                        self.delayed.push((now + step, call));
                    } else {
                        call.finish(Err(e));
                    }
                } else {
                    call.finish(Ok(v.get("result").cloned().unwrap_or(Value::Null)));
                }
            }
        }
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn jitter_stays_under_the_ceiling() {
        let base = Duration::from_millis(250);
        let cap = Duration::from_secs(8);
        for n in 0..12 {
            let ceiling = base.saturating_mul(1 << n).min(cap);
            for _ in 0..50 {
                assert!(full_jitter(base, cap, n) < ceiling.max(Duration::from_millis(1)));
            }
        }
    }

    #[test]
    fn handshake_keeps_unknown_onboarding_unknown() {
        let h = Handshake::from_value(json!({"protocolVersion": "1.0.0"}));
        assert_eq!(h.needs_onboarding, None);
        let h = Handshake::from_value(json!({"needsOnboarding": true}));
        assert_eq!(h.needs_onboarding, Some(true));
    }
}
