//! The RPC client against a fake daemon WebSocket server: auth headers,
//! handshake first, re-subscribe on reconnect, ping timeout, version
//! mismatch, `rpc.daemonUnavailable` retry, events and seq gaps.

// The tungstenite accept callback signature fixes its error type.
#![allow(clippy::result_large_err)]

use std::sync::{Arc, Mutex};
use std::time::Duration;

use conduit_daemon::protocol::{PROTOCOL_VERSION, codes};

/// The error's code as a string.
fn code<T: std::fmt::Debug>(r: Result<T, conduit_daemon::RpcError>) -> String {
    r.unwrap_err().code.as_str().to_string()
}
use conduit_daemon::rpc::{ClientEvent, ConnectionState, RpcClient, RpcConfig};
use futures_util::{SinkExt as _, StreamExt as _};
use serde_json::{Value, json};
use tokio::net::TcpListener;
use tokio::sync::mpsc;
use tokio::time::timeout;
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::tungstenite::handshake::server::{Request, Response};
use tokio_tungstenite::tungstenite::http::HeaderValue;

const TOKEN: &str = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQ";

/// What the fake server does with one request.
enum Reply {
    Result(Value),
    Error(Value),
    /// Never answer.
    Silent,
    /// Drop the connection.
    Close,
}

type Handler = dyn Fn(usize, &Value) -> Reply + Send + Sync;

#[derive(Default)]
struct Seen {
    /// (connection index, request)
    requests: Vec<(usize, Value)>,
    /// (Origin, Sec-WebSocket-Protocol) per upgrade.
    upgrades: Vec<(String, String)>,
}

struct FakeDaemon {
    port: u16,
    seen: Arc<Mutex<Seen>>,
    /// Push a frame to the newest connection.
    push: Arc<Mutex<Option<mpsc::UnboundedSender<Value>>>>,
}

impl FakeDaemon {
    async fn start(selected_protocol: &'static str, handler: Arc<Handler>) -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let seen = Arc::new(Mutex::new(Seen::default()));
        let push: Arc<Mutex<Option<mpsc::UnboundedSender<Value>>>> = Arc::new(Mutex::new(None));
        let (seen2, push2) = (seen.clone(), push.clone());
        tokio::spawn(async move {
            let mut index = 0;
            while let Ok((tcp, _)) = listener.accept().await {
                let conn = index;
                index += 1;
                let seen = seen2.clone();
                let handler = handler.clone();
                let (tx, mut rx) = mpsc::unbounded_channel::<Value>();
                *push2.lock().unwrap() = Some(tx);
                tokio::spawn(async move {
                    let seen_cb = seen.clone();
                    let callback = move |req: &Request, mut resp: Response| {
                        let h = |k: &str| {
                            req.headers()
                                .get(k)
                                .and_then(|v| v.to_str().ok())
                                .unwrap_or_default()
                                .to_string()
                        };
                        seen_cb
                            .lock()
                            .unwrap()
                            .upgrades
                            .push((h("origin"), h("sec-websocket-protocol")));
                        resp.headers_mut().insert(
                            "Sec-WebSocket-Protocol",
                            HeaderValue::from_static(selected_protocol),
                        );
                        Ok(resp)
                    };
                    let Ok(ws) = tokio_tungstenite::accept_hdr_async(tcp, callback).await else {
                        return;
                    };
                    let (mut sink, mut stream) = ws.split();
                    loop {
                        tokio::select! {
                            pushed = rx.recv() => match pushed {
                                Some(v) => { let _ = sink.send(Message::text(v.to_string())).await; }
                                None => return,
                            },
                            msg = stream.next() => {
                                let Some(Ok(Message::Text(text))) = msg else { return };
                                let req: Value = serde_json::from_str(text.as_str()).unwrap();
                                seen.lock().unwrap().requests.push((conn, req.clone()));
                                let id = req["id"].clone();
                                let frame = match handler(conn, &req) {
                                    Reply::Result(r) => json!({"jsonrpc":"2.0","id":id,"result":r}),
                                    Reply::Error(e) => json!({"jsonrpc":"2.0","id":id,"error":e}),
                                    Reply::Silent => continue,
                                    Reply::Close => {
                                        let _ = sink.send(Message::Close(None)).await;
                                        return;
                                    }
                                };
                                if sink.send(Message::text(frame.to_string())).await.is_err() {
                                    return;
                                }
                            }
                        }
                    }
                });
            }
        });
        Self { port, seen, push }
    }

    fn methods(&self, conn: usize) -> Vec<String> {
        self.seen
            .lock()
            .unwrap()
            .requests
            .iter()
            .filter(|(c, _)| *c == conn)
            .map(|(_, r)| r["method"].as_str().unwrap_or_default().to_string())
            .filter(|m| m != "system.ping")
            .collect()
    }

    fn requests(&self, method: &str) -> Vec<(usize, Value)> {
        self.seen
            .lock()
            .unwrap()
            .requests
            .iter()
            .filter(|(_, r)| r["method"] == method)
            .cloned()
            .collect()
    }

    fn connections(&self) -> usize {
        self.seen.lock().unwrap().upgrades.len()
    }

    fn push(&self, frame: Value) {
        if let Some(tx) = self.push.lock().unwrap().as_ref() {
            let _ = tx.send(frame);
        }
    }
}

fn handshake_ok(needs_onboarding: bool) -> Reply {
    Reply::Result(json!({
        "protocolVersion": PROTOCOL_VERSION,
        "daemonVersion": "0.1.0",
        "sessionId": "s1",
        "capabilities": {},
        "paths": {},
        "platform": "macos",
        "needsOnboarding": needs_onboarding,
    }))
}

/// Answers the handshake, pings and subscribes; everything else via `rest`.
fn standard(rest: impl Fn(usize, &Value) -> Reply + Send + Sync + 'static) -> Arc<Handler> {
    Arc::new(move |conn, req| match req["method"].as_str() {
        Some("system.handshake") => handshake_ok(false),
        Some("system.ping") => Reply::Result(json!({"uptimeMs": 1, "serverTimeMs": 2})),
        Some("events.subscribe") => Reply::Result(json!({"ok": true})),
        _ => rest(conn, req),
    })
}

fn fast_config() -> RpcConfig {
    let mut c = RpcConfig::new(TOKEN, "0.0.0-test");
    c.locale = "de".into();
    c.ping_interval = Duration::from_millis(100);
    c.ping_timeout = Duration::from_millis(400);
    c.call_timeout = Duration::from_secs(5);
    c.connect_timeout = Duration::from_secs(2);
    c.reconnect_base = Duration::from_millis(20);
    c.reconnect_cap = Duration::from_millis(80);
    c.unavailable_step = Duration::from_millis(20);
    c.unavailable_budget = Duration::from_secs(3);
    c
}

async fn wait_state(
    rx: &mut mpsc::UnboundedReceiver<ClientEvent>,
    pred: impl Fn(&ConnectionState) -> bool,
) -> ConnectionState {
    loop {
        let e = timeout(Duration::from_secs(5), rx.recv())
            .await
            .expect("a state in time")
            .expect("client alive");
        if let ClientEvent::State(s) = e
            && pred(&s)
        {
            return s;
        }
    }
}

fn connected(s: &ConnectionState) -> bool {
    matches!(s, ConnectionState::Connected(_))
}

#[tokio::test]
async fn sends_origin_and_token_subprotocol_then_handshakes_first() {
    let fake = FakeDaemon::start(
        "conduit.v1",
        standard(|_, _| Reply::Result(json!({"items": []}))),
    )
    .await;
    let (client, mut rx) = RpcClient::start(fast_config(), &tokio::runtime::Handle::current());
    // A call made before there is a daemon waits for the session.
    let early = client.call_value("chats.list", json!({"limit": 5}));
    assert!(matches!(
        wait_state(&mut rx, |_| true).await,
        ConnectionState::WaitingForDaemon
    ));
    client.set_endpoint(Some(fake.port));
    let state = wait_state(&mut rx, connected).await;
    let ConnectionState::Connected(h) = state else {
        unreachable!()
    };
    assert_eq!(h.needs_onboarding, Some(false));
    assert_eq!(early.await.unwrap(), json!({"items": []}));

    let (origin, protocols) = fake.seen.lock().unwrap().upgrades[0].clone();
    assert_eq!(origin, "app://conduit");
    // tk. + base64url-nopad(utf8(token))
    let expected = format!("conduit.v1, tk.{}", base64_url_nopad(TOKEN.as_bytes()));
    assert_eq!(protocols, expected);

    assert_eq!(fake.methods(0), vec!["system.handshake", "chats.list"]);
    let (_, hs) = fake.requests("system.handshake")[0].clone();
    assert_eq!(hs["params"]["protocolVersion"], PROTOCOL_VERSION);
    assert_eq!(hs["params"]["clientName"], "conduit-desktop");
    assert_eq!(hs["params"]["windowKind"], "main");
    assert_eq!(hs["params"]["locale"], "de");
    let (_, list) = fake.requests("chats.list")[0].clone();
    assert_eq!(list["params"], json!({"limit": 5}));
    client.shutdown();
}

#[tokio::test]
async fn refuses_a_daemon_that_echoes_the_token_entry() {
    // The daemon must select the bare `conduit.v1`; echoing the token
    // would leak it into logs, so the client treats it as a failed connect.
    let tk: &'static str =
        Box::leak(format!("tk.{}", base64_url_nopad(TOKEN.as_bytes())).into_boxed_str());
    let fake = FakeDaemon::start(tk, standard(|_, _| Reply::Silent)).await;
    let (client, mut rx) = RpcClient::start(fast_config(), &tokio::runtime::Handle::current());
    client.set_endpoint(Some(fake.port));
    let s = wait_state(&mut rx, |s| {
        matches!(s, ConnectionState::Reconnecting { .. })
    })
    .await;
    let ConnectionState::Reconnecting { error, .. } = s else {
        unreachable!()
    };
    assert!(error.contains("subprotocol"), "{error}");
    // The error is logged and shown: it never carries the token.
    assert!(!error.contains(&tk["tk.".len()..]), "{error}");
    assert!(!error.contains(TOKEN), "{error}");
    assert!(fake.requests("system.handshake").is_empty());
    client.shutdown();
}

#[tokio::test]
async fn reconnects_and_resubscribes() {
    // The first connection drops right after its first call.
    let fake = FakeDaemon::start(
        "conduit.v1",
        standard(|conn, req| match (conn, req["method"].as_str()) {
            (0, Some("chats.list")) => Reply::Close,
            _ => Reply::Result(json!({"ok": true})),
        }),
    )
    .await;
    let (client, mut rx) = RpcClient::start(fast_config(), &tokio::runtime::Handle::current());
    client.subscribe(&["chats.changed", "shell.openUrl"], &["chat:1".to_string()]);
    client.set_endpoint(Some(fake.port));
    wait_state(&mut rx, connected).await;
    let dropped = client.call_value("chats.list", Value::Null).await;
    assert_eq!(code(dropped), codes::DISCONNECTED);
    wait_state(&mut rx, |s| {
        matches!(s, ConnectionState::Reconnecting { .. })
    })
    .await;
    wait_state(&mut rx, connected).await;
    // The new session works (and, answered in order, proves the server has
    // seen everything sent before it).
    assert_eq!(
        client.call_value("chats.list", Value::Null).await.unwrap(),
        json!({"ok": true})
    );
    assert_eq!(fake.connections(), 2);
    assert_eq!(
        fake.methods(1),
        ["system.handshake", "events.subscribe", "chats.list"]
    );
    let subs = fake.requests("events.subscribe");
    assert_eq!(subs.len(), 2);
    assert_eq!(subs[0].1["params"], subs[1].1["params"]);
    assert_eq!(
        subs[1].1["params"],
        json!({"events": ["chats.changed", "shell.openUrl"], "scopes": ["chat:1"]})
    );
    client.shutdown();
}

#[tokio::test]
async fn an_unanswered_ping_means_dead() {
    // Connection 0 never answers pings; connection 1 does.
    let fake = FakeDaemon::start(
        "conduit.v1",
        Arc::new(|conn, req| match req["method"].as_str() {
            Some("system.handshake") => handshake_ok(false),
            Some("system.ping") if conn == 0 => Reply::Silent,
            _ => Reply::Result(json!({})),
        }),
    )
    .await;
    let (client, mut rx) = RpcClient::start(fast_config(), &tokio::runtime::Handle::current());
    // Started before the session, so the time measured can only be longer
    // than the client's own: the lower bound holds whatever the scheduling.
    let started = std::time::Instant::now();
    client.set_endpoint(Some(fake.port));
    wait_state(&mut rx, connected).await;
    let s = wait_state(&mut rx, |s| {
        matches!(s, ConnectionState::Reconnecting { .. })
    })
    .await;
    let ConnectionState::Reconnecting { error, .. } = s else {
        unreachable!()
    };
    assert!(error.contains("ping"), "{error}");
    // Ping every 100 ms, dead after 400 ms without an answer.
    assert!(started.elapsed() >= Duration::from_millis(350));
    wait_state(&mut rx, connected).await;
    assert_eq!(fake.connections(), 2);
    client.shutdown();
}

#[tokio::test]
async fn a_version_mismatch_is_fatal() {
    let fake = FakeDaemon::start(
        "conduit.v1",
        Arc::new(|_, req| match req["method"].as_str() {
            Some("system.handshake") => Reply::Error(json!({
                "code": -32000,
                "message": "client speaks 0.0.1",
                "data": {
                    "code": "rpc.protocolVersionMismatch",
                    "args": {"expected": "9.9.9", "actual": "0.0.1"},
                    "retryable": false
                }
            })),
            _ => Reply::Result(json!({})),
        }),
    )
    .await;
    let (client, mut rx) = RpcClient::start(fast_config(), &tokio::runtime::Handle::current());
    let pending = client.call_value("chats.list", Value::Null);
    client.set_endpoint(Some(fake.port));
    let s = wait_state(&mut rx, |s| {
        matches!(s, ConnectionState::VersionMismatch { .. })
    })
    .await;
    assert_eq!(
        s,
        ConnectionState::VersionMismatch {
            daemon: "9.9.9".into(),
            app: PROTOCOL_VERSION.into()
        }
    );
    assert_eq!(code(pending.await), codes::PROTOCOL_VERSION_MISMATCH);
    // Later calls fail at once rather than wait for a session.
    let later = timeout(
        Duration::from_secs(1),
        client.call_value("chats.list", Value::Null),
    )
    .await
    .expect("fails fast");
    assert_eq!(code(later), codes::PROTOCOL_VERSION_MISMATCH);
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert_eq!(fake.connections(), 1, "no reconnect after a mismatch");
    client.shutdown();
}

#[tokio::test]
async fn a_different_version_in_the_reply_is_a_mismatch_too() {
    let fake = FakeDaemon::start(
        "conduit.v1",
        Arc::new(|_, _| {
            Reply::Result(json!({"protocolVersion": "0.0.0", "needsOnboarding": true}))
        }),
    )
    .await;
    let (client, mut rx) = RpcClient::start(fast_config(), &tokio::runtime::Handle::current());
    client.set_endpoint(Some(fake.port));
    let s = wait_state(&mut rx, |s| {
        matches!(s, ConnectionState::VersionMismatch { .. })
    })
    .await;
    assert_eq!(
        s,
        ConnectionState::VersionMismatch {
            daemon: "0.0.0".into(),
            app: PROTOCOL_VERSION.into()
        }
    );
    client.shutdown();
}

#[tokio::test]
async fn retries_while_the_core_starts() {
    let calls = Arc::new(Mutex::new(0));
    let calls2 = calls.clone();
    let fake = FakeDaemon::start(
        "conduit.v1",
        standard(move |_, req| {
            if req["method"] == "accounts.list" {
                let mut n = calls2.lock().unwrap();
                *n += 1;
                if *n < 3 {
                    return Reply::Error(json!({
                        "code": -32000,
                        "message": "the core is not up yet",
                        "data": {"code": "rpc.daemonUnavailable"}
                    }));
                }
                return Reply::Result(json!({"accounts": []}));
            }
            Reply::Error(json!({
                "code": -32000,
                "message": "nope",
                "data": {"code": "resource.notFound"}
            }))
        }),
    )
    .await;
    let (client, mut rx) = RpcClient::start(fast_config(), &tokio::runtime::Handle::current());
    client.set_endpoint(Some(fake.port));
    wait_state(&mut rx, connected).await;
    assert_eq!(
        client
            .call_value("accounts.list", Value::Null)
            .await
            .unwrap(),
        json!({"accounts": []})
    );
    assert_eq!(fake.requests("accounts.list").len(), 3);
    // Other errors come straight back.
    let e = client.call_value("chats.get", json!({"id": "x"})).await;
    assert_eq!(code(e), "resource.notFound");
    assert_eq!(fake.requests("chats.get").len(), 1);
    client.shutdown();
}

#[tokio::test]
async fn daemon_unavailable_gives_up_after_its_budget() {
    let fake = FakeDaemon::start(
        "conduit.v1",
        standard(|_, _| {
            Reply::Error(json!({
                "code": -32000,
                "message": "starting",
                "data": {"code": "rpc.daemonUnavailable"}
            }))
        }),
    )
    .await;
    let mut config = fast_config();
    config.unavailable_budget = Duration::from_millis(300);
    let (client, mut rx) = RpcClient::start(config, &tokio::runtime::Handle::current());
    client.set_endpoint(Some(fake.port));
    wait_state(&mut rx, connected).await;
    let e = client.call_value("accounts.list", Value::Null).await;
    // How many retries fit depends on when the first answer lands; the test
    // above checks the retries themselves.
    assert_eq!(code(e), codes::DAEMON_UNAVAILABLE);
    client.shutdown();
}

#[tokio::test]
async fn events_arrive_and_gaps_are_reported() {
    let fake = FakeDaemon::start("conduit.v1", standard(|_, _| Reply::Result(json!({})))).await;
    let (client, mut rx) = RpcClient::start(fast_config(), &tokio::runtime::Handle::current());
    client.set_endpoint(Some(fake.port));
    wait_state(&mut rx, connected).await;
    let event = |seq: u64| {
        json!({"jsonrpc": "2.0", "method": "event", "params": {
            "event": "shell.openUrl", "seq": seq, "payload": {"url": "https://example.org"}
        }})
    };
    fake.push(event(1));
    fake.push(event(3));
    let mut got = vec![];
    while got.len() < 3 {
        match timeout(Duration::from_secs(5), rx.recv())
            .await
            .unwrap()
            .unwrap()
        {
            ClientEvent::State(_) => {}
            other => got.push(other),
        }
    }
    let ClientEvent::Event(first) = &got[0] else {
        panic!("{got:?}")
    };
    assert_eq!(first.event, "shell.openUrl");
    assert_eq!(first.seq, 1);
    assert_eq!(first.payload["url"], "https://example.org");
    assert_eq!(
        got[1],
        ClientEvent::Gap {
            expected: 2,
            got: 3
        }
    );
    assert!(matches!(&got[2], ClientEvent::Event(e) if e.seq == 3));
    client.shutdown();
}

#[tokio::test]
async fn gives_up_after_eight_failed_connects_and_retry_starts_over() {
    // A port nobody listens on.
    let port = {
        let l = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        l.local_addr().unwrap().port()
    };
    let mut config = fast_config();
    config.reconnect_base = Duration::from_millis(1);
    config.reconnect_cap = Duration::from_millis(5);
    let (client, mut rx) = RpcClient::start(config, &tokio::runtime::Handle::current());
    client.set_endpoint(Some(port));
    let mut reconnects = 0;
    loop {
        let e = timeout(Duration::from_secs(5), rx.recv())
            .await
            .unwrap()
            .unwrap();
        match e {
            ClientEvent::State(ConnectionState::Reconnecting { .. }) => reconnects += 1,
            ClientEvent::State(ConnectionState::Failed { .. }) => break,
            _ => {}
        }
    }
    assert_eq!(reconnects, 8);
    // A daemon appears; retry connects.
    let fake = FakeDaemon::start("conduit.v1", standard(|_, _| Reply::Result(json!({})))).await;
    client.set_endpoint(Some(fake.port));
    wait_state(&mut rx, connected).await;
    client.shutdown();
}

#[tokio::test]
async fn a_new_endpoint_reconnects_at_once() {
    let a = FakeDaemon::start("conduit.v1", standard(|_, _| Reply::Result(json!("a")))).await;
    let b = FakeDaemon::start("conduit.v1", standard(|_, _| Reply::Result(json!("b")))).await;
    let (client, mut rx) = RpcClient::start(fast_config(), &tokio::runtime::Handle::current());
    client.set_endpoint(Some(a.port));
    wait_state(&mut rx, connected).await;
    assert_eq!(
        client.call_value("x", Value::Null).await.unwrap(),
        json!("a")
    );
    client.set_endpoint(None);
    wait_state(&mut rx, |s| matches!(s, ConnectionState::WaitingForDaemon)).await;
    client.set_endpoint(Some(b.port));
    wait_state(&mut rx, connected).await;
    assert_eq!(
        client.call_value("x", Value::Null).await.unwrap(),
        json!("b")
    );
    client.shutdown();
}

#[tokio::test]
async fn typed_calls_layer_on_untyped_ones() {
    use conduit_daemon::protocol::NoParams;
    use conduit_daemon::protocol::methods::SystemExportDiagnostics;
    let fake = FakeDaemon::start(
        "conduit.v1",
        standard(|_, req| match req["method"].as_str() {
            Some("system.exportDiagnostics") => {
                assert_eq!(req["params"], json!({}), "NoParams is sent as {{}}");
                Reply::Result(json!({"path": "/tmp/d.zip", "sizeBytes": 12}))
            }
            _ => Reply::Silent,
        }),
    )
    .await;
    let (client, mut rx) = RpcClient::start(fast_config(), &tokio::runtime::Handle::current());
    client.set_endpoint(Some(fake.port));
    wait_state(&mut rx, connected).await;
    let export = client
        .call::<SystemExportDiagnostics>(&NoParams)
        .await
        .unwrap();
    assert_eq!(export.path, "/tmp/d.zip");
    assert_eq!(export.size_bytes, 12);
    client.shutdown();
}

fn base64_url_nopad(bytes: &[u8]) -> String {
    const ALPHA: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    let mut out = String::new();
    for chunk in bytes.chunks(3) {
        let b = [
            chunk[0],
            *chunk.get(1).unwrap_or(&0),
            *chunk.get(2).unwrap_or(&0),
        ];
        let n = (u32::from(b[0]) << 16) | (u32::from(b[1]) << 8) | u32::from(b[2]);
        let chars = chunk.len() + 1;
        for i in 0..chars {
            out.push(ALPHA[((n >> (18 - 6 * i)) & 63) as usize] as char);
        }
    }
    out
}
