//! A terminal's shell: `WS /terminal/{handle}` on the daemon, which opens
//! the session, sends the credential and then pipes bytes both ways.
//!
//! [`spawn`] runs the socket on the shared runtime. Keystrokes go up as
//! binary frames; `resize` and `ping` as JSON text, as Open Terminal reads
//! them. The shell's output reaches `on_output` on a runtime thread, where
//! a terminal emulator can parse it without holding up the UI thread; the
//! end of the socket reaches `on_closed` once, with the close code when
//! there was one.

use std::time::Duration;

use futures_util::{SinkExt as _, StreamExt as _};
use tokio::sync::mpsc;
use tokio::time::{interval, timeout};
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::tungstenite::client::IntoClientRequest as _;
use tokio_tungstenite::tungstenite::http::HeaderValue;

use crate::http::{HttpClient, encode_component};
use crate::protocol::{APP_ORIGIN, SUBPROTOCOL};
use crate::runtime;
use crate::secrets::subprotocol_token;

/// What the window sends the shell.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum TerminalInput {
    /// Keystrokes and pasted text, as the shell reads them.
    Bytes(Vec<u8>),
    /// The visible grid's new size.
    Resize { cols: u16, rows: u16 },
}

impl TerminalInput {
    fn message(&self) -> Message {
        match self {
            Self::Bytes(bytes) => Message::binary(bytes.clone()),
            Self::Resize { cols, rows } => Message::text(
                serde_json::json!({"type": "resize", "cols": cols, "rows": rows}).to_string(),
            ),
        }
    }
}

/// How a shell's socket ended.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum TerminalEnd {
    /// It never opened: the daemon refused the upgrade or could not be
    /// reached.
    Refused(String),
    /// It opened and later closed, with the code the far end gave.
    Closed(Option<u16>),
    /// The window let it go.
    Dropped,
}

enum Command {
    Input(TerminalInput),
    Close,
}

/// The window's end of a running shell. Clones share the socket, which
/// closes on [`TerminalLink::close`] or when the last clone goes.
#[derive(Clone)]
pub struct TerminalLink {
    input: mpsc::UnboundedSender<Command>,
}

impl TerminalLink {
    /// Queues `input` for the shell; false once the socket is gone.
    pub fn send(&self, input: TerminalInput) -> bool {
        self.input.send(Command::Input(input)).is_ok()
    }

    /// Closes the socket (the shell's session ends).
    pub fn close(&self) {
        let _ = self.input.send(Command::Close);
    }
}

/// How often the shell is pinged while idle, as mobile's terminal does, so
/// proxies between here and the terminal keep the socket open.
const PING_EVERY: Duration = Duration::from_secs(25);
const CONNECT_TIMEOUT: Duration = Duration::from_secs(20);

/// Opens `handle`'s shell through the daemon `http` names, and pumps it
/// until either end closes. `initial` (the grid's size, say) goes out
/// first; `on_open` hears that the daemon took the socket.
pub fn spawn(
    http: &HttpClient,
    handle: &str,
    initial: Vec<TerminalInput>,
    on_open: impl FnOnce() + Send + 'static,
    mut on_output: impl FnMut(&[u8]) + Send + 'static,
    on_closed: impl FnOnce(TerminalEnd) + Send + 'static,
) -> TerminalLink {
    let (tx, mut rx) = mpsc::unbounded_channel::<Command>();
    let url = format!(
        "{}/terminal/{}",
        http.base().replacen("http://", "ws://", 1),
        encode_component(handle)
    );
    let token = http.token().to_string();
    runtime::shared().spawn(async move {
        let request = match connect_request(&url, &token) {
            Ok(request) => request,
            Err(e) => return on_closed(TerminalEnd::Refused(e)),
        };
        let connected = timeout(CONNECT_TIMEOUT, tokio_tungstenite::connect_async(request)).await;
        let mut ws = match connected {
            Ok(Ok((ws, _))) => ws,
            Ok(Err(e)) => return on_closed(TerminalEnd::Refused(e.to_string())),
            Err(_) => return on_closed(TerminalEnd::Refused("connect timed out".into())),
        };
        on_open();
        for input in initial {
            if ws.send(input.message()).await.is_err() {
                return on_closed(TerminalEnd::Closed(None));
            }
        }
        let mut ping = interval(PING_EVERY);
        ping.tick().await;
        let end = loop {
            tokio::select! {
                command = rx.recv() => match command {
                    Some(Command::Input(input)) => {
                        if ws.send(input.message()).await.is_err() {
                            break TerminalEnd::Closed(None);
                        }
                    }
                    Some(Command::Close) | None => {
                        let _ = ws.close(None).await;
                        break TerminalEnd::Dropped;
                    }
                },
                _ = ping.tick() => {
                    let ping = Message::text(r#"{"type":"ping"}"#);
                    if ws.send(ping).await.is_err() {
                        break TerminalEnd::Closed(None);
                    }
                }
                message = ws.next() => match message {
                    Some(Ok(Message::Binary(bytes))) => on_output(&bytes),
                    Some(Ok(Message::Text(text))) => {
                        // A server's own JSON (a pong) is not output.
                        if !text.trim_start().starts_with('{') {
                            on_output(text.as_bytes());
                        }
                    }
                    Some(Ok(Message::Close(frame))) => {
                        break TerminalEnd::Closed(frame.map(|f| u16::from(f.code)));
                    }
                    Some(Ok(_)) => {}
                    Some(Err(_)) | None => break TerminalEnd::Closed(None),
                },
            }
        };
        on_closed(end);
    });
    TerminalLink { input: tx }
}

fn connect_request(
    url: &str,
    token: &str,
) -> Result<tokio_tungstenite::tungstenite::handshake::client::Request, String> {
    let mut request = url.into_client_request().map_err(|e| e.to_string())?;
    let headers = request.headers_mut();
    headers.insert("Origin", HeaderValue::from_static(APP_ORIGIN));
    let protocols = format!("{SUBPROTOCOL}, {}", subprotocol_token(token));
    headers.insert(
        "Sec-WebSocket-Protocol",
        HeaderValue::from_str(&protocols).map_err(|e| e.to_string())?,
    );
    Ok(request)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn input_goes_up_as_the_shell_reads_it() {
        assert_eq!(
            TerminalInput::Bytes(b"ls\r".to_vec()).message(),
            Message::binary(b"ls\r".to_vec())
        );
        let Message::Text(text) = (TerminalInput::Resize {
            cols: 100,
            rows: 30,
        })
        .message() else {
            panic!("a resize is text");
        };
        let value: serde_json::Value = serde_json::from_str(&text).unwrap();
        assert_eq!(
            value,
            serde_json::json!({"type": "resize", "cols": 100, "rows": 30})
        );
    }

    #[test]
    fn the_socket_authenticates_as_the_rpc_connection_does() {
        let request = connect_request("ws://127.0.0.1:1/terminal/h", "tok").unwrap();
        assert_eq!(request.headers()["Origin"], APP_ORIGIN);
        let protocols = request.headers()["Sec-WebSocket-Protocol"]
            .to_str()
            .unwrap();
        assert!(protocols.starts_with(SUBPROTOCOL));
        assert!(protocols.contains(&subprotocol_token("tok")));
    }
}
