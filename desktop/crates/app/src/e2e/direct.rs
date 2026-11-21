//! `--e2e direct-advanced`: Settings › Direct Connections against the
//! local Open WebUI and the fake model server's direct extras
//! (`tool/local_owui/fake_direct.py`), each step checked where it lands:
//!
//! * a connection with a custom header and a manual model id: Test, Save,
//!   and a chat whose request carries the header (the fake model's log);
//! * an MCP server signed in with OAuth against the fake authorization
//!   server (the browser's part played here: the authorize page's redirect
//!   followed to the app's loopback address), then a chat whose model calls
//!   its tool, approved Always, and the approval revoked;
//! * web search on in the composer: the request offers `web_search`;
//! * the Responses API with Azure's `api-version`: the request goes to
//!   `/responses` with it;
//! * the history location: a chat stays on this Mac, or reaches the server;
//! * a connection kept in the Open WebUI account (`ui.directConnections`),
//!   listed, and chatted through; skipped, with a line saying so, on a
//!   server that moved them into Tether (Open WebUI 0.13.4);
//! * Ollama on "this Mac": its models, Load and Unload, keep-alive, and a
//!   context limit Ollama then loads the model with (`num_ctx`);
//! * images per request and the web search engine, region and safe search.
//!
//! Screens are shot in light and dark: the pane, the editor (Advanced
//! open), the Ollama models, the MCP server signed in.

use std::io::{Read as _, Write as _};
use std::net::TcpStream;

use conduit_protocol::{
    ChatRef, DirectConnectionList, DirectKind, McpAuth, NoParams, UiRequestKind, UiResponse,
    methods,
};
use serde_json::Value;

use super::chat::{chat_store, in_pane, send, sign_in, wait_answer, wait_models};
use super::*;
use crate::actions::SettingsChoice;
use crate::views::direct::editor::DirectEditorSheet;
use crate::views::direct::mcp::McpServerSheet;
use crate::views::direct::ollama::{MENU_KEEP, OllamaModels};
use crate::views::direct::pane::{
    DirectPane, MENU_CONTEXT, MENU_ENGINE, MENU_IMAGES, MENU_REGION, MENU_SAFE,
};
use crate::views::direct::{DirectNote, form};
use crate::views::sheet::{self, SheetBody as _};

const GATEWAY: &str = "Harbour gateway";
const HEADER: &str = "x-conduit-test";
const HEADER_VALUE: &str = "lighthouse-42";
const MANUAL: &str = "fake-manual";
const FERRY_SERVER: &str = "Ferry timetable";

fn log_lines(path: &Path) -> Vec<Value> {
    std::fs::read_to_string(path)
        .unwrap_or_default()
        .lines()
        .filter_map(|l| serde_json::from_str::<Value>(l).ok())
        .collect()
}

/// The log's lines after the first `skip`.
fn new_lines(path: &Path, skip: usize) -> Vec<Value> {
    log_lines(path).into_iter().skip(skip).collect()
}

/// The newest chat request whose last user text contains `text`.
fn request_with(path: &Path, skip: usize, text: &str) -> Option<Value> {
    new_lines(path, skip).into_iter().rev().find(|v| {
        v.get("user")
            .and_then(Value::as_str)
            .is_some_and(|u| u.contains(text))
    })
}

fn tools_of(request: &Option<Value>) -> Vec<String> {
    request
        .as_ref()
        .and_then(|r| r.get("tools"))
        .and_then(Value::as_array)
        .map(|a| {
            a.iter()
                .filter_map(Value::as_str)
                .map(str::to_string)
                .collect()
        })
        .unwrap_or_default()
}

/// A GET as a browser makes it: the status and any Location, no redirect
/// followed. Plain HTTP to the fake servers and the app's loopback port.
fn http_get(url: &str) -> Option<(u16, Option<String>)> {
    let u = url::Url::parse(url).ok()?;
    let host = u.host_str()?.to_string();
    let port = u.port_or_known_default()?;
    let mut path = u.path().to_string();
    if let Some(q) = u.query() {
        path = format!("{path}?{q}");
    }
    let mut stream = TcpStream::connect((host.as_str(), port)).ok()?;
    stream
        .set_read_timeout(Some(Duration::from_secs(15)))
        .ok()?;
    write!(
        stream,
        "GET {path} HTTP/1.1\r\nHost: {host}:{port}\r\nAccept: text/html\r\nConnection: close\r\n\r\n"
    )
    .ok()?;
    let mut raw = vec![];
    let _ = stream.read_to_end(&mut raw);
    let text = String::from_utf8_lossy(&raw).to_string();
    let mut lines = text.lines();
    let status = lines
        .next()?
        .split_whitespace()
        .nth(1)?
        .parse::<u16>()
        .ok()?;
    let location = lines.take_while(|l| !l.is_empty()).find_map(|l| {
        let (k, v) = l.split_once(':')?;
        k.eq_ignore_ascii_case("location")
            .then(|| v.trim().to_string())
    });
    Some((status, location))
}

/// A request to the local Open WebUI (or another local fake): the status
/// and the body (chunked bodies joined).
pub(super) fn http_request(
    method: &str,
    url: &str,
    bearer: Option<&str>,
    json: Option<&str>,
) -> Option<(u16, String)> {
    let u = url::Url::parse(url).ok()?;
    let host = u.host_str()?.to_string();
    let port = u.port_or_known_default()?;
    let mut path = u.path().to_string();
    if let Some(q) = u.query() {
        path = format!("{path}?{q}");
    }
    let mut stream = TcpStream::connect((host.as_str(), port)).ok()?;
    stream
        .set_read_timeout(Some(Duration::from_secs(15)))
        .ok()?;
    let body = json.unwrap_or("");
    let mut head = format!(
        "{method} {path} HTTP/1.1\r\nHost: {host}:{port}\r\nConnection: close\r\nAccept: application/json\r\n"
    );
    if let Some(token) = bearer {
        head.push_str(&format!("Authorization: Bearer {token}\r\n"));
    }
    if json.is_some() {
        head.push_str(&format!(
            "Content-Type: application/json\r\nContent-Length: {}\r\n",
            body.len()
        ));
    }
    head.push_str("\r\n");
    stream.write_all(head.as_bytes()).ok()?;
    stream.write_all(body.as_bytes()).ok()?;
    let mut raw = vec![];
    let _ = stream.read_to_end(&mut raw);
    let text = String::from_utf8_lossy(&raw).to_string();
    let (headers, rest) = text.split_once("\r\n\r\n")?;
    let status = headers
        .lines()
        .next()?
        .split_whitespace()
        .nth(1)?
        .parse()
        .ok()?;
    let chunked = headers.lines().any(|l| {
        let l = l.to_ascii_lowercase();
        l.starts_with("transfer-encoding:") && l.contains("chunked")
    });
    let body = if chunked {
        let mut out = String::new();
        let mut rest = rest;
        while let Some((size, after)) = rest.split_once("\r\n") {
            let n = usize::from_str_radix(size.trim(), 16).unwrap_or(0);
            if n == 0 || after.len() < n {
                break;
            }
            out.push_str(&after[..n]);
            rest = after[n..].trim_start_matches("\r\n");
        }
        out
    } else {
        rest.to_string()
    };
    Some((status, body))
}

/// The local Open WebUI's token for the seeded account.
fn owui_token(url: &str, email: &str, password: &str) -> Option<String> {
    let body = serde_json::json!({"email": email, "password": password}).to_string();
    let (status, text) = http_request(
        "POST",
        &format!("{}/api/v1/auths/signin", url.trim_end_matches('/')),
        None,
        Some(&body),
    )?;
    if status != 200 {
        return None;
    }
    serde_json::from_str::<Value>(&text)
        .ok()?
        .get("token")?
        .as_str()
        .map(str::to_string)
}

/// Whether the server holds the chat `id`.
fn on_server(url: &str, token: &str, id: &str) -> bool {
    http_request(
        "GET",
        &format!("{}/api/v1/chats/{id}", url.trim_end_matches('/')),
        Some(token),
        None,
    )
    .is_some_and(|(status, _)| status == 200)
}

fn settings_handle(cx: &mut App) -> Option<AnyWindowHandle> {
    cx.global::<AppState>()
        .settings_window
        .as_ref()
        .map(|(h, _)| *h)
}

/// The Settings window's Direct Connections pane.
fn direct_pane(cx: &mut App) -> Option<Entity<DirectPane>> {
    let (_, view) = cx.global::<AppState>().settings_window.clone()?;
    view.read(cx).direct.clone()
}

/// Runs `f` on the pane with the Settings window.
fn in_pane_settings<R>(
    cx: &mut AsyncApp,
    f: impl FnOnce(&mut DirectPane, &mut Window, &mut gpui_kit::Context<DirectPane>) -> R,
) -> Option<R> {
    let handle = cx.update(settings_handle)?;
    let pane = cx.update(direct_pane)?;
    cx.update(|cx| {
        handle
            .update(cx, |_, window, cx| {
                pane.update(cx, |p, cx| f(p, window, cx))
            })
            .ok()
    })
}

fn in_sheet<V: 'static, R>(
    cx: &mut AsyncApp,
    f: impl FnOnce(&mut V, &mut Window, &mut gpui_kit::Context<V>) -> R,
) -> Option<R> {
    let handle = cx.update(|cx| sheet::current_window(cx))?;
    let entity = cx.update(|cx| sheet::current::<V>(cx))?;
    cx.update(|cx| {
        handle
            .update(cx, |_, window, cx| {
                entity.update(cx, |v, cx| f(v, window, cx))
            })
            .ok()
    })
}

/// The Settings window made tall (the pane is long), shot in light and
/// dark, and put back.
async fn shoot_tall(dir: &Path, name: &str, cx: &mut AsyncApp) {
    let Some(h) = cx.update(settings_handle) else {
        return;
    };
    if let Some(ns) = cx.update(|cx| crate::smoke::ns_window(h, cx)) {
        crate::smoke::place(
            &ns,
            (300., 40.),
            (crate::views::settings::SETTINGS_SIZE.0, 1040.),
        );
    }
    settle(cx, 500).await;
    crate::smoke::shoot_both_modes(h, dir, name, cx).await;
    crate::smoke::place_settings(h, cx);
    settle(cx, 300).await;
}

async fn wait_sheet<V: 'static>(cx: &mut AsyncApp) -> bool {
    wait_until(cx, Duration::from_secs(15), |cx| {
        sheet::current::<V>(cx).is_some()
    })
    .await
}

async fn wait_closed(cx: &mut AsyncApp) -> bool {
    wait_until(cx, Duration::from_secs(20), |cx| !sheet::is_open(cx)).await
}

/// The pane's list, once it holds `name`.
async fn wait_connection(cx: &mut AsyncApp, name: &str) -> bool {
    let name = name.to_string();
    wait_until(cx, Duration::from_secs(30), move |cx| {
        direct_pane(cx).is_some_and(|p| {
            p.read(cx)
                .list
                .as_ref()
                .is_some_and(|l| l.connections.iter().any(|c| c.name == name))
        })
    })
    .await
}

fn rpc(cx: &mut App) -> crate::stores::rpc::Rpc {
    cx.global::<AppState>().stores.connection.read(cx).rpc()
}

async fn direct_list(cx: &mut AsyncApp) -> Option<DirectConnectionList> {
    let rpc = cx.update(rpc);
    rpc.call::<methods::DirectList>(&NoParams).await.ok()
}

/// A picker model offered by `connection`, named `name`.
fn model_of(connection: &str, name: &str, cx: &mut App) -> Option<String> {
    let pane = super::chat::pane(cx)?;
    let store = pane.read(cx).composer_store.read(cx);
    store
        .models
        .as_ref()?
        .models
        .iter()
        .find(|m| m.connection.as_deref() == Some(connection) && m.name.contains(name))
        .map(|m| m.id.clone())
}

/// A new chat with `model`.
async fn chat_with(model: &str, cx: &mut AsyncApp) {
    let nav = cx.update(|cx| cx.global::<AppState>().stores.navigation.clone());
    nav.update(cx, |n, cx| n.new_chat(false, cx));
    settle(cx, 500).await;
    let model = model.to_string();
    in_pane(cx, move |p, _, cx| {
        p.composer_store
            .update(cx, |c, cx| c.select_model(&model, cx))
    });
    settle(cx, 400).await;
}

/// Refreshes the composer's model list (a connection was added).
async fn refresh_models(cx: &mut AsyncApp) {
    in_pane(cx, |p, _, cx| {
        p.composer_store.update(cx, |c, cx| c.refresh_models(cx))
    });
    settle(cx, 800).await;
}

pub async fn run(inputs: &E2eInputs, dir: &Path, cx: &mut AsyncApp) -> bool {
    let (Some((url, email, password)), Some(openai)) =
        (inputs.owui(), inputs.get("FAKE_OPENAI_URL"))
    else {
        return ok(NO_SERVER, false);
    };
    let Some(log) = inputs.get("FAKE_MODEL_LOG").map(std::path::PathBuf::from) else {
        return ok("FAKE_MODEL_LOG in the env file", false);
    };
    let origin = openai
        .trim_end_matches('/')
        .trim_end_matches("/v1")
        .to_string();
    cx.update(|cx| cx.set_global(crate::shell::open_url::Intercept(true)));

    let mut pass = sign_in(&url, &email, &password, cx).await;
    pass &= ok("models.list answered", wait_models(cx).await);
    cx.update(|cx| crate::open_settings(Some(Tab::Direct), cx));
    settle(cx, 600).await;
    if cx.update(settings_handle).is_none() {
        return ok("Settings opened on Direct Connections", false);
    }
    let loaded = wait_until(cx, Duration::from_secs(30), |cx| {
        direct_pane(cx).is_some_and(|p| {
            let p = p.read(cx);
            p.list.is_some() && p.search.is_some() && p.mcp.is_some()
        })
    })
    .await;
    pass &= ok(
        "the pane lists connections, MCP servers and web search",
        loaded,
    );
    let (owui, moved) = cx.update(|cx| {
        direct_pane(cx)
            .and_then(|p| {
                let p = p.read(cx);
                let l = p.list.as_ref()?;
                Some((l.open_web_ui_available, direct_moved_to_tether(l)))
            })
            .unwrap_or_default()
    });
    if moved {
        println!("SMOKE e2e skip a connection kept in the Open WebUI account: {MOVED_TO_TETHER}");
    } else {
        pass &= ok("the server keeps direct connections for its users", owui);
    }
    shoot_tall(dir, "direct-pane-empty", cx).await;

    pass &= gateway(&openai, &log, dir, cx).await;
    pass &= mcp_oauth(&origin, &log, dir, cx).await;
    pass &= web_search(&log, cx).await;
    pass &= openai_default(cx).await;
    pass &= responses(&log, cx).await;
    pass &= history((&url, &email, &password), cx).await;
    if !moved {
        pass &= open_web_ui_connection(&openai, &log, cx).await;
    }
    pass &= ollama(&origin, &log, dir, cx).await;
    pass &= options(dir, cx).await;
    pass
}

/// A connection with a header and a manual model id, tested, saved and
/// chatted through.
async fn gateway(openai: &str, log: &Path, dir: &Path, cx: &mut AsyncApp) -> bool {
    in_pane_settings(cx, |p, window, cx| p.open_editor(None, false, window, cx));
    let mut pass = ok(
        "Add Connection opens a sheet",
        wait_sheet::<DirectEditorSheet>(cx).await,
    );
    let openai = openai.to_string();
    in_sheet::<DirectEditorSheet, _>(cx, move |s, window, cx| {
        s.form.update(cx, |f, cx| {
            set_text(&f.name.clone(), GATEWAY, window, cx);
            set_text(&f.base_url.clone(), &openai, window, cx);
            set_text(&f.api_key.clone(), "sk-test", window, cx);
            f.advanced = true;
            let models = f.manual_models.clone();
            models.update(cx, |m, cx| m.set_value(MANUAL, window, cx));
            set_text(&f.tags.clone(), "e2e, harbour", window, cx);
            cx.notify();
        });
        // A header row, as Add Header makes it.
        let (name, value) = {
            let n = crate::views::forms::input("", false, window, cx);
            let v = crate::views::forms::input("", true, window, cx);
            (n, v)
        };
        set_text(&name, HEADER, window, cx);
        set_text(&value, HEADER_VALUE, window, cx);
        s.form.update(cx, |f, cx| {
            f.headers
                .push(crate::views::forms::HeaderRow { name, value });
            cx.notify();
        });
    });
    settle(cx, 600).await;
    if let Some(h) = cx.update(settings_handle) {
        crate::smoke::shoot_both_modes(h, dir, "direct-editor-advanced", cx).await;
    }
    in_sheet::<DirectEditorSheet, _>(cx, |s, window, cx| {
        s.form.update(cx, |f, cx| f.test(window, cx))
    });
    let tested = wait_until(cx, Duration::from_secs(30), |cx| {
        sheet::current::<DirectEditorSheet>(cx).is_some_and(|s| {
            matches!(&s.read(cx).form.read(cx).note, Some(DirectNote::Tested(r)) if r.reachable)
        })
    })
    .await;
    pass &= ok("Test Connection reaches the provider", tested);
    let mark = log_lines(log).len();
    in_sheet::<DirectEditorSheet, _>(cx, |s, window, cx| {
        s.form.update(cx, |f, cx| f.save(window, cx))
    });
    pass &= ok("Save closes the sheet", wait_closed(cx).await);
    pass &= ok(
        "the pane lists the connection",
        wait_connection(cx, GATEWAY).await,
    );
    let saved = direct_list(cx)
        .await
        .and_then(|l| l.connections.into_iter().find(|c| c.name == GATEWAY));
    pass &= ok(
        "the header is saved, by name only",
        saved.as_ref().is_some_and(|c| {
            c.custom_header_names
                .iter()
                .any(|n| n.eq_ignore_ascii_case(HEADER))
        }),
    );
    pass &= ok(
        "the manual model id and tags are saved",
        saved.as_ref().is_some_and(|c| {
            c.manual_model_ids == vec![MANUAL.to_string()]
                && c.tags == vec!["e2e".to_string(), "harbour".to_string()]
        }),
    );

    refresh_models(cx).await;
    let manual = wait_until(cx, Duration::from_secs(30), |cx| {
        model_of(GATEWAY, MANUAL, cx).is_some()
    })
    .await;
    pass &= ok("the manual model is in the picker", manual);
    let Some(model) = cx.update(|cx| model_of(GATEWAY, MANUAL, cx)) else {
        return false;
    };
    chat_with(&model, cx).await;
    send("Say just: heron", cx).await;
    pass &= ok(
        "the manual model answers",
        wait_answer(cx, Duration::from_secs(60)).await,
    );
    let request = request_with(log, mark, "heron");
    pass &= ok(
        "the request carries the custom header",
        request
            .as_ref()
            .and_then(|r| r.get("headers"))
            .and_then(|h| h.get(HEADER))
            .and_then(Value::as_str)
            == Some(HEADER_VALUE),
    );
    pass &= ok(
        "the request names the manual model and sends the key as a bearer token",
        request.as_ref().is_some_and(|r| {
            r.get("model").and_then(Value::as_str) == Some(MANUAL)
                && r.get("auth").and_then(Value::as_str) == Some("bearer")
        }),
    );
    pass
}

/// An MCP server signed in with OAuth, then its tool called in a chat.
async fn mcp_oauth(origin: &str, log: &Path, dir: &Path, cx: &mut AsyncApp) -> bool {
    in_pane_settings(cx, |p, window, cx| p.open_mcp(None, window, cx));
    let mut pass = ok(
        "Add Server opens a sheet",
        wait_sheet::<McpServerSheet>(cx).await,
    );
    let endpoint = format!("{origin}/oauth-mcp");
    in_sheet::<McpServerSheet, _>(cx, move |s, window, cx| {
        set_text(&s.name.clone(), FERRY_SERVER, window, cx);
        set_text(&s.endpoint.clone(), &endpoint, window, cx);
        s.auth = McpAuth::Oauth;
        cx.notify();
    });
    settle(cx, 400).await;
    let opened_before = cx.update(|cx| {
        cx.global::<AppState>()
            .connection
            .read(cx)
            .opened_urls
            .len()
    });
    // Connect in Browser on a new server saves it, then signs in.
    in_sheet::<McpServerSheet, _>(cx, |s, window, cx| s.connect(window, cx));
    let waiting = wait_until(cx, Duration::from_secs(20), |cx| {
        sheet::current::<McpServerSheet>(cx).is_some_and(|s| s.read(cx).connecting)
    })
    .await;
    pass &= ok("the sheet waits for the browser", waiting);
    if let Some(h) = cx.update(settings_handle) {
        crate::smoke::shoot_both_modes(h, dir, "direct-mcp-waiting", cx).await;
    }
    let opened = wait_until(cx, Duration::from_secs(20), move |cx| {
        cx.global::<AppState>()
            .connection
            .read(cx)
            .opened_urls
            .len()
            > opened_before
    })
    .await;
    pass &= ok(
        "the daemon asks to open the sign-in page (shell.openUrl)",
        opened,
    );
    let authorize = cx.update(|cx| {
        cx.global::<AppState>()
            .connection
            .read(cx)
            .opened_urls
            .last()
            .cloned()
    });
    pass &= ok(
        "it is the fake server's authorization page",
        authorize
            .as_deref()
            .is_some_and(|u| u.contains("/auth/authorize")),
    );
    // The browser's part: the authorize page approves and redirects to the
    // app's loopback address.
    let callback = match authorize {
        Some(u) => {
            cx.background_executor()
                .spawn(async move { http_get(&u) })
                .await
        }
        None => None,
    };
    let location = callback.as_ref().and_then(|(_, l)| l.clone());
    pass &= ok(
        "the authorization server redirects to the loopback address",
        callback.as_ref().is_some_and(|(s, _)| *s == 302)
            && location
                .as_deref()
                .is_some_and(|l| l.starts_with("http://127.0.0.1:")),
    );
    let landed = match location {
        Some(l) => {
            cx.background_executor()
                .spawn(async move { http_get(&l) })
                .await
        }
        None => None,
    };
    pass &= ok(
        "the app's loopback listener takes the code",
        landed.is_some_and(|(s, _)| s == 200),
    );
    let signed_in = wait_until(cx, Duration::from_secs(30), |cx| {
        sheet::current::<McpServerSheet>(cx).is_some_and(|s| {
            let s = s.read(cx);
            !s.connecting && s.saved.as_ref().is_some_and(|x| x.oauth_connected)
        })
    })
    .await;
    pass &= ok("the server is signed in", signed_in);
    let scopes = cx.update(|cx| {
        sheet::current::<McpServerSheet>(cx)
            .and_then(|s| s.read(cx).saved.clone())
            .map(|s| (s.oauth_issuer_host.clone(), s.oauth_scopes.clone()))
    });
    pass &= ok(
        "it shows the authorization server and the scopes granted",
        scopes.is_some_and(|(host, scopes)| {
            host.as_deref() == Some("127.0.0.1") && scopes == vec!["tides.read".to_string()]
        }),
    );
    let token_ok = log_lines(log).iter().any(|v| {
        v.get("oauth").and_then(Value::as_str) == Some("token")
            && v.get("ok").and_then(Value::as_bool) == Some(true)
    });
    pass &= ok("the code was exchanged with PKCE", token_ok);
    if let Some(h) = cx.update(settings_handle) {
        crate::smoke::shoot_both_modes(h, dir, "direct-mcp-signed-in", cx).await;
    }
    in_sheet::<McpServerSheet, _>(cx, |s, window, cx| s.test(window, cx));
    let listed = wait_until(cx, Duration::from_secs(30), |cx| {
        sheet::current::<McpServerSheet>(cx).is_some_and(|s| {
            matches!(
                &s.read(cx).note,
                Some(crate::views::direct::mcp::McpNote::Tested(r))
                    if r.reachable && r.tool_count == Some(1)
            )
        })
    })
    .await;
    pass &= ok(
        "Test Connection lists the server's tool with the token",
        listed,
    );
    in_sheet::<McpServerSheet, _>(cx, |s, window, cx| s.cancel(window, cx));
    pass &= ok("the sheet closes", wait_closed(cx).await);

    // A chat whose model calls the tool: approved Always, so the server
    // then lists it under Always Allowed Tools.
    let Some(model) = cx.update(|cx| model_of(GATEWAY, MANUAL, cx)) else {
        return ok("the gateway's model for the tool call", false);
    };
    chat_with(&model, cx).await;
    // The server is one of the chat's tools, turned on as mobile's tools
    // menu does.
    in_pane(cx, |p, _, cx| {
        p.composer_store.update(cx, |c, cx| c.refresh_options(cx))
    });
    let tool = |cx: &mut App| -> Option<String> {
        let pane = super::chat::pane(cx)?;
        let store = pane.read(cx).composer_store.read(cx);
        store
            .options
            .mcp_tools
            .iter()
            .find(|t| t.name == FERRY_SERVER)
            .map(|t| t.id.clone())
    };
    let offered = wait_until(cx, Duration::from_secs(20), move |cx| tool(cx).is_some()).await;
    pass &= ok("the MCP server is offered among the chat's tools", offered);
    if let Some(id) = cx.update(tool) {
        in_pane(cx, move |p, _, cx| {
            p.composer_store.update(cx, |c, cx| c.toggle_tool(&id, cx))
        });
    }
    let mark = log_lines(log).len();
    send("When is the next ferry?", cx).await;
    let asked = wait_until(cx, Duration::from_secs(60), |cx| {
        cx.global::<AppState>()
            .stores
            .ui_requests
            .read(cx)
            .queue
            .iter()
            .any(|r| r.kind == UiRequestKind::McpApproval)
    })
    .await;
    pass &= ok("the tool call asks for approval", asked);
    let request = cx.update(|cx| {
        cx.global::<AppState>()
            .stores
            .ui_requests
            .read(cx)
            .queue
            .iter()
            .find(|r| r.kind == UiRequestKind::McpApproval)
            .cloned()
    });
    if let Some(main) = cx.update(main_window).map(|(h, _)| h) {
        crate::smoke::shoot_both_modes(main, dir, "direct-mcp-approval", cx).await;
    }
    if let Some(r) = request {
        let rpc = cx.update(rpc);
        let _ = rpc
            .call::<methods::UiRespond>(&UiResponse {
                request_id: r.request_id,
                choice: "allowAlways".into(),
                text: None,
                remember: true,
            })
            .await;
    }
    pass &= ok(
        "the answer arrives",
        wait_answer(cx, Duration::from_secs(60)).await,
    );
    let called = new_lines(log, mark).iter().any(|v| {
        v.get("mcp_call").and_then(Value::as_str) == Some("ferry_times")
            && v.get("authorized").and_then(Value::as_bool) == Some(true)
    });
    pass &= ok(
        "the tool ran on the MCP server with the OAuth token",
        called,
    );
    let answer = cx.update(super::chat::last_answer_text);
    pass &= ok(
        "the answer uses the tool's result",
        answer.contains("The ferry tool says"),
    );
    let remembered = cx.update(rpc).call::<methods::McpList>(&NoParams).await;
    let server = remembered
        .ok()
        .and_then(|l| l.servers.into_iter().find(|s| s.name == FERRY_SERVER));
    pass &= mcp_content(cx).await;
    pass &= ok(
        "Always Allow is remembered",
        server.as_ref().is_some_and(|s| {
            s.approvals
                .iter()
                .any(|a| a.tool_name.contains("ferry_times"))
        }),
    );
    // Revoked from the sheet.
    if let Some(server) = server {
        in_pane_settings(cx, move |p, window, cx| {
            p.open_mcp(Some(server), window, cx)
        });
        if wait_sheet::<McpServerSheet>(cx).await {
            settle(cx, 500).await;
            if let Some(h) = cx.update(settings_handle) {
                crate::smoke::shoot_both_modes(h, dir, "direct-mcp-approvals", cx).await;
            }
            in_sheet::<McpServerSheet, _>(cx, |s, _, cx| s.forget(None, cx));
            let forgot = wait_until(cx, Duration::from_secs(20), |cx| {
                sheet::current::<McpServerSheet>(cx).is_some_and(|s| {
                    s.read(cx)
                        .saved
                        .as_ref()
                        .is_some_and(|x| x.approvals.is_empty())
                })
            })
            .await;
            pass &= ok("Revoke All forgets the approval", forgot);
            in_sheet::<McpServerSheet, _>(cx, |s, window, cx| s.cancel(window, cx));
            pass &= ok("the sheet closes", wait_closed(cx).await);
        }
    }
    pass
}

/// The composer's MCP Content: the signed-in server's prompt and
/// resource listed, read with its token, and the prompt inserted.
async fn mcp_content(cx: &mut AsyncApp) -> bool {
    use crate::views::chat::composer::{ComposerMenu, Panel};
    in_pane(cx, |p, window, cx| {
        p.composer
            .update(cx, |c, cx| c.on_menu(&ComposerMenu::McpContent, window, cx))
    });
    let items = |cx: &mut App| -> usize {
        super::chat::pane(cx)
            .and_then(|p| {
                let composer = p.read(cx).composer.clone();
                let c = composer.read(cx);
                match &c.panel {
                    Some(Panel::Mcp(m)) => Some(m.items(cx).len()),
                    _ => None,
                }
            })
            .unwrap_or(0)
    };
    let listed = wait_until(cx, Duration::from_secs(20), move |cx| items(cx) == 2).await;
    let mut pass = ok("MCP Content lists the server's prompt and resource", listed);
    in_pane(cx, |p, _, cx| {
        p.composer.update(cx, |c, cx| {
            if let Some(Panel::Mcp(m)) = &mut c.panel
                && let Some(item) = m.items(cx).first().cloned()
            {
                m.read(item, cx);
            }
        })
    });
    let previewed = wait_until(cx, Duration::from_secs(20), |cx| {
        super::chat::pane(cx).is_some_and(|p| {
            let composer = p.read(cx).composer.clone();
            matches!(&composer.read(cx).panel, Some(Panel::Mcp(m)) if m.preview.is_some())
        })
    })
    .await;
    pass &= ok("the prompt is read for a preview", previewed);
    in_pane(cx, |p, window, cx| {
        p.composer.update(cx, |c, cx| {
            let text = match &c.panel {
                Some(Panel::Mcp(m)) => m.preview.as_ref().map(|(t, _)| t.clone()),
                _ => None,
            };
            if let Some(text) = text {
                c.insert_text(&text, window, cx);
            }
        })
    });
    settle(cx, 300).await;
    let text = cx.update(|cx| {
        super::chat::pane(cx)
            .map(|p| p.read(cx).composer.read(cx).text(cx))
            .unwrap_or_default()
    });
    pass &= ok(
        "Insert puts the prompt in the composer",
        text.contains("Post the ferry timetable on the harbour board."),
    );
    in_pane(cx, |p, window, cx| {
        p.composer.update(cx, |c, cx| c.set_text("", window, cx))
    });
    pass
}

/// Web search on in the composer reaches the request as the app's own
/// search tools.
async fn web_search(log: &Path, cx: &mut AsyncApp) -> bool {
    let Some(model) = cx.update(|cx| model_of(GATEWAY, MANUAL, cx)) else {
        return ok("the gateway's model for web search", false);
    };
    chat_with(&model, cx).await;
    let offered = wait_until(cx, Duration::from_secs(15), |cx| {
        super::chat::pane(cx).is_some_and(|p| p.read(cx).composer_store.read(cx).options.web_search)
    })
    .await;
    let mut pass = ok("web search is offered for the direct model", offered);
    in_pane(cx, |p, _, cx| {
        p.composer_store.update(cx, |c, cx| c.toggle_web_search(cx))
    });
    let mark = log_lines(log).len();
    send("Say just: ibis", cx).await;
    pass &= ok("it answers", wait_answer(cx, Duration::from_secs(60)).await);
    let tools = tools_of(&request_with(log, mark, "ibis"));
    pass &= ok(
        "the request offers the on-device web_search and web_fetch tools",
        tools.iter().any(|t| t == "web_search") && tools.iter().any(|t| t == "web_fetch"),
    );
    pass
}

/// A new OpenAI-compatible connection follows its address to the
/// Responses API on the OpenAI platform itself (Chat Completions elsewhere)
/// until a mode is picked; nothing is saved or sent.
async fn openai_default(cx: &mut AsyncApp) -> bool {
    in_pane_settings(cx, |p, window, cx| p.open_editor(None, false, window, cx));
    let mut pass = ok(
        "Add Connection opens a sheet",
        wait_sheet::<DirectEditorSheet>(cx).await,
    );
    async fn mode(url: &'static str, cx: &mut AsyncApp) -> Option<conduit_protocol::DirectApiMode> {
        in_sheet::<DirectEditorSheet, _>(cx, move |s, window, cx| {
            s.form
                .update(cx, |f, cx| set_text(&f.base_url.clone(), url, window, cx))
        });
        settle(cx, 300).await;
        in_sheet::<DirectEditorSheet, _>(cx, |s, _, cx| s.form.read(cx).api_mode)
    }
    let responses = conduit_protocol::DirectApiMode::Responses;
    let chat = conduit_protocol::DirectApiMode::Chat;
    pass &= ok(
        "on the OpenAI platform's address it starts on Responses",
        mode("https://api.openai.com/v1", cx).await == Some(responses),
    );
    pass &= ok(
        "elsewhere on Chat Completions",
        mode("http://127.0.0.1:19799/v1", cx).await == Some(chat),
    );
    in_sheet::<DirectEditorSheet, _>(cx, |s, window, cx| {
        s.form.update(cx, |f, cx| {
            f.on_choice(
                &SettingsChoice {
                    menu: form::MENU_API.into(),
                    value: "chat".into(),
                },
                window,
                cx,
            )
        })
    });
    pass &= ok(
        "a mode picked stays, whatever the address",
        mode("https://api.openai.com/v1", cx).await == Some(chat),
    );
    cx.update(sheet::dismiss);
    pass &= ok("closed unsaved", wait_closed(cx).await);
    pass
}

/// The Responses API with Azure's api-version.
async fn responses(log: &Path, cx: &mut AsyncApp) -> bool {
    let Some(gateway) = direct_list(cx)
        .await
        .and_then(|l| l.connections.into_iter().find(|c| c.name == GATEWAY))
    else {
        return ok("the gateway to edit", false);
    };
    in_pane_settings(cx, move |p, window, cx| {
        p.open_editor(Some(gateway), false, window, cx)
    });
    let mut pass = ok(
        "Edit Connection opens a sheet",
        wait_sheet::<DirectEditorSheet>(cx).await,
    );
    in_sheet::<DirectEditorSheet, _>(cx, |s, window, cx| {
        s.form.update(cx, |f, cx| {
            f.on_choice(
                &SettingsChoice {
                    menu: form::MENU_API.into(),
                    value: "responses".into(),
                },
                window,
                cx,
            );
            set_text(&f.api_version.clone(), "2024-10-21", window, cx);
        });
    });
    settle(cx, 300).await;
    in_sheet::<DirectEditorSheet, _>(cx, |s, window, cx| {
        s.form.update(cx, |f, cx| f.save(window, cx))
    });
    pass &= ok("the edit is saved", wait_closed(cx).await);
    let saved = direct_list(cx)
        .await
        .and_then(|l| l.connections.into_iter().find(|c| c.name == GATEWAY));
    pass &= ok(
        "it is in Responses mode with the api-version, the key kept",
        saved.as_ref().is_some_and(|c| {
            c.api_mode == conduit_protocol::DirectApiMode::Responses
                && c.api_version.as_deref() == Some("2024-10-21")
                && c.has_api_key
        }),
    );
    let Some(model) = cx.update(|cx| model_of(GATEWAY, MANUAL, cx)) else {
        return ok("the gateway's model for Responses", false);
    };
    chat_with(&model, cx).await;
    let mark = log_lines(log).len();
    send("Say just: otter", cx).await;
    pass &= ok(
        "the Responses API answers",
        wait_answer(cx, Duration::from_secs(60)).await,
    );
    let request = request_with(log, mark, "otter");
    pass &= ok(
        "the request went to /responses with api-version and the header",
        request.as_ref().is_some_and(|r| {
            r.get("path")
                .and_then(Value::as_str)
                .is_some_and(|p| p.ends_with("/responses"))
                && r.get("api_version").and_then(Value::as_str) == Some("2024-10-21")
                && r.get("headers")
                    .and_then(|h| h.get(HEADER))
                    .and_then(Value::as_str)
                    == Some(HEADER_VALUE)
        }),
    );
    let text = cx.update(super::chat::last_answer_text);
    pass &= ok("the answer streamed in", text.contains("otter"));
    pass
}

/// Where direct chats are kept: this Mac only, or the server too.
async fn history(owui: (&str, &str, &str), cx: &mut AsyncApp) -> bool {
    let (url, email, password) = (owui.0.to_string(), owui.1.to_string(), owui.2.to_string());
    let token = cx
        .background_executor()
        .spawn(async move { owui_token(&url, &email, &password) })
        .await;
    let url = owui.0.to_string();
    let Some(model) = cx.update(|cx| model_of(GATEWAY, MANUAL, cx)) else {
        return ok("the gateway's model for history", false);
    };
    in_pane_settings(cx, |p, window, cx| p.set_history(false, window, cx));
    let local = wait_until(cx, Duration::from_secs(15), |cx| {
        direct_pane(cx).is_some_and(|p| p.read(cx).list.as_ref().is_some_and(|l| l.local_history))
    })
    .await;
    let mut pass = ok("Open WebUI History off: chats stay on this Mac", local);
    chat_with(&model, cx).await;
    send("Say just: puffin", cx).await;
    pass &= ok("it answers", wait_answer(cx, Duration::from_secs(60)).await);
    settle(cx, 5000).await;
    let local_id = cx.update(|cx| chat_store(cx).map(|s| s.read(cx).chat_id().to_string()));
    let kept = match (&token, local_id) {
        (Some(token), Some(id)) => {
            let (url, token) = (url.clone(), token.clone());
            !cx.background_executor()
                .spawn(async move { on_server(&url, &token, &id) })
                .await
        }
        _ => false,
    };
    pass &= ok(
        "the chat is kept on this Mac only (the server hasn't it)",
        kept,
    );

    in_pane_settings(cx, |p, window, cx| p.set_history(true, window, cx));
    let synced = wait_until(cx, Duration::from_secs(15), |cx| {
        direct_pane(cx).is_some_and(|p| p.read(cx).list.as_ref().is_some_and(|l| !l.local_history))
    })
    .await;
    pass &= ok("Open WebUI History on", synced);
    chat_with(&model, cx).await;
    send("Say just: tern", cx).await;
    pass &= ok("it answers", wait_answer(cx, Duration::from_secs(60)).await);
    let id = cx.update(|cx| chat_store(cx).map(|s| s.read(cx).chat_id().to_string()));
    let mut stored = false;
    if let (Some(token), Some(id)) = (&token, id.clone()) {
        for _ in 0..30 {
            let (url, token, id) = (url.clone(), token.clone(), id.clone());
            if cx
                .background_executor()
                .spawn(async move { on_server(&url, &token, &id) })
                .await
            {
                stored = true;
                break;
            }
            settle(cx, 1000).await;
        }
    }
    pass &= ok("the chat is saved to the Open WebUI account", stored);
    if let Some(id) = id {
        let rpc = cx.update(rpc);
        let _ = rpc.call::<methods::ChatsDelete>(&ChatRef { id }).await;
    }
    pass
}

/// A connection kept in the Open WebUI account: added, listed apart, and
/// its model answers.
async fn open_web_ui_connection(openai: &str, log: &Path, cx: &mut AsyncApp) -> bool {
    in_pane_settings(cx, |p, window, cx| p.open_editor(None, true, window, cx));
    let mut pass = ok(
        "Add Connection for the server opens a sheet",
        wait_sheet::<DirectEditorSheet>(cx).await,
    );
    let openai = openai.to_string();
    in_sheet::<DirectEditorSheet, _>(cx, move |s, window, cx| {
        s.form.update(cx, |f, cx| {
            set_text(&f.base_url.clone(), &openai, window, cx);
            set_text(&f.api_key.clone(), "sk-test", window, cx);
            f.save(window, cx);
        })
    });
    pass &= ok("it is saved", wait_closed(cx).await);
    let listed = wait_until(cx, Duration::from_secs(30), |cx| {
        direct_pane(cx).is_some_and(|p| {
            p.read(cx)
                .list
                .as_ref()
                .is_some_and(|l| l.connections.iter().any(|c| c.open_web_ui && c.compatible))
        })
    })
    .await;
    pass &= ok("it is listed under Open WebUI Server", listed);
    let name = cx.update(|cx| {
        direct_pane(cx).and_then(|p| {
            p.read(cx)
                .list
                .as_ref()?
                .connections
                .iter()
                .find(|c| c.open_web_ui)
                .map(|c| c.name.clone())
        })
    });
    refresh_models(cx).await;
    let found = match name.clone() {
        Some(n) => {
            wait_until(cx, Duration::from_secs(30), move |cx| {
                model_of(&n, "fake-model", cx).is_some()
            })
            .await
        }
        None => false,
    };
    pass &= ok("its models are in the picker", found);
    if let Some(model) = name.and_then(|n| cx.update(|cx| model_of(&n, "fake-model", cx))) {
        chat_with(&model, cx).await;
        let mark = log_lines(log).len();
        send("Say just: egret", cx).await;
        pass &= ok("it answers", wait_answer(cx, Duration::from_secs(60)).await);
        pass &= ok(
            "the request reached the provider",
            request_with(log, mark, "egret").is_some(),
        );
    }
    pass
}

/// Ollama on "this Mac": its models, Load and Unload, keep-alive, and a
/// context limit that is loaded as `num_ctx`.
async fn ollama(origin: &str, log: &Path, dir: &Path, cx: &mut AsyncApp) -> bool {
    in_pane_settings(cx, |p, window, cx| p.open_editor(None, false, window, cx));
    let mut pass = ok(
        "Add Connection opens a sheet",
        wait_sheet::<DirectEditorSheet>(cx).await,
    );
    let base = format!("{origin}/ollama");
    in_sheet::<DirectEditorSheet, _>(cx, move |s, window, cx| {
        s.form.update(cx, |f, cx| {
            f.on_choice(
                &SettingsChoice {
                    menu: form::MENU_PRESET.into(),
                    value: "ollama".into(),
                },
                window,
                cx,
            );
            f.on_choice(
                &SettingsChoice {
                    menu: form::MENU_AUTH.into(),
                    value: "none".into(),
                },
                window,
                cx,
            );
            set_text(&f.name.clone(), "Studio Ollama", window, cx);
            set_text(&f.base_url.clone(), &base, window, cx);
            f.save(window, cx);
        })
    });
    pass &= ok("the Ollama connection is saved", wait_closed(cx).await);
    pass &= ok("it is listed", wait_connection(cx, "Studio Ollama").await);
    let Some(summary) = direct_list(cx).await.and_then(|l| {
        l.connections
            .into_iter()
            .find(|c| c.name == "Studio Ollama")
    }) else {
        return ok("the Ollama connection to open", false);
    };
    pass &= ok(
        "it is a local Ollama server",
        summary.kind == DirectKind::Ollama && !summary.ollama_cloud,
    );

    // Its context limit: the models report none.
    in_pane_settings(cx, |p, _, cx| p.refresh_quietly(cx));
    let listed = wait_until(cx, Duration::from_secs(30), |cx| {
        direct_pane(cx).is_some_and(|p| {
            p.read(cx).options.as_ref().is_some_and(|o| {
                o.context_models
                    .iter()
                    .any(|m| m.name == "llama3.2:1b" && m.ollama)
            })
        })
    })
    .await;
    pass &= ok("its models are offered a context limit", listed);
    let model_id = cx.update(|cx| {
        direct_pane(cx).and_then(|p| {
            p.read(cx)
                .options
                .as_ref()?
                .context_models
                .iter()
                .find(|m| m.name == "llama3.2:1b")
                .map(|m| (m.id.clone(), m.logo.clone()))
        })
    });
    pass &= ok(
        "it carries its maker's logo",
        model_id
            .as_ref()
            .is_some_and(|(_, logo)| logo.as_deref() == Some("meta")),
    );
    if let Some((id, _)) = model_id {
        let menu = format!("{MENU_CONTEXT}{id}");
        in_pane_settings(cx, move |p, window, cx| {
            p.choose(&menu, "32768", window, cx)
        });
        let set = wait_until(cx, Duration::from_secs(15), |cx| {
            direct_pane(cx).is_some_and(|p| {
                p.read(cx).options.as_ref().is_some_and(|o| {
                    o.context_models
                        .iter()
                        .any(|m| m.name == "llama3.2:1b" && m.limit == 32768)
                })
            })
        })
        .await;
        pass &= ok("the context limit is set", set);
    }

    in_pane_settings(cx, move |p, window, cx| {
        p.open_editor(Some(summary), false, window, cx)
    });
    pass &= ok(
        "Edit Connection opens a sheet",
        wait_sheet::<DirectEditorSheet>(cx).await,
    );
    let models = wait_until(cx, Duration::from_secs(30), |cx| {
        sheet::current::<DirectEditorSheet>(cx).is_some_and(|s| {
            s.read(cx).ollama.as_ref().is_some_and(|o| {
                o.read(cx)
                    .list
                    .as_ref()
                    .is_some_and(|l| l.lifecycle && l.models.len() == 2)
            })
        })
    })
    .await;
    pass &= ok("the editor lists the server's models", models);
    let ollama = |cx: &mut App| -> Option<Entity<OllamaModels>> {
        sheet::current::<DirectEditorSheet>(cx)?
            .read(cx)
            .ollama
            .clone()
    };
    let mark = log_lines(log).len();
    let handle = cx.update(|cx| sheet::current_window(cx));
    if let (Some(handle), Some(o)) = (handle, cx.update(ollama)) {
        let _ = handle.update(cx, |_, window, cx| {
            o.update(cx, |o, cx| o.load("llama3.2:1b", window, cx))
        });
    }
    let loaded = wait_until(cx, Duration::from_secs(30), move |cx| {
        ollama(cx).is_some_and(|o| {
            o.read(cx).list.as_ref().is_some_and(|l| {
                l.models
                    .iter()
                    .any(|m| m.id == "llama3.2:1b" && m.loaded == Some(true))
            })
        })
    })
    .await;
    pass &= ok("Load puts the model in memory", loaded);
    let load = new_lines(log, mark)
        .into_iter()
        .find(|v| v.get("ollama").and_then(Value::as_str) == Some("load"));
    pass &= ok(
        "it is loaded with the context limit as num_ctx",
        load.as_ref()
            .and_then(|v| v.get("num_ctx"))
            .and_then(Value::as_i64)
            == Some(32768),
    );
    if let (Some(handle), Some(o)) = (handle, cx.update(ollama)) {
        let _ = handle.update(cx, |_, window, cx| {
            o.update(cx, |o, cx| {
                o.on_choice(
                    &SettingsChoice {
                        menu: format!("{MENU_KEEP}llama3.2:1b"),
                        value: "30m".into(),
                    },
                    window,
                    cx,
                )
            })
        });
    }
    let kept = wait_until(cx, Duration::from_secs(20), move |cx| {
        ollama(cx).is_some_and(|o| {
            o.read(cx).list.as_ref().is_some_and(|l| {
                l.models
                    .iter()
                    .any(|m| m.id == "llama3.2:1b" && m.keep_alive.as_deref() == Some("30m"))
            })
        })
    })
    .await;
    pass &= ok("Keep Alive is saved for the model", kept);
    settle(cx, 400).await;
    if let Some(h) = cx.update(settings_handle) {
        crate::smoke::shoot_both_modes(h, dir, "direct-ollama-models", cx).await;
    }
    if let (Some(handle), Some(o)) = (handle, cx.update(ollama)) {
        let _ = handle.update(cx, |_, window, cx| {
            o.update(cx, |o, cx| o.unload("llama3.2:1b", window, cx))
        });
    }
    let unloaded = wait_until(cx, Duration::from_secs(30), move |cx| {
        ollama(cx).is_some_and(|o| {
            o.read(cx).list.as_ref().is_some_and(|l| {
                l.models
                    .iter()
                    .any(|m| m.id == "llama3.2:1b" && m.loaded == Some(false))
            })
        })
    })
    .await;
    pass &= ok("Unload frees it", unloaded);
    pass &= ok(
        "the unload reached the server",
        new_lines(log, mark)
            .iter()
            .any(|v| v.get("ollama").and_then(Value::as_str) == Some("unload")),
    );
    in_sheet::<DirectEditorSheet, _>(cx, |s, window, cx| s.cancel(window, cx));
    pass &= ok("the sheet closes", wait_closed(cx).await);
    pass
}

/// Images per request and the web search settings round-trip, and the
/// pane is shot with everything in it.
async fn options(dir: &Path, cx: &mut AsyncApp) -> bool {
    in_pane_settings(cx, |p, window, cx| p.choose(MENU_IMAGES, "4", window, cx));
    let images = wait_until(cx, Duration::from_secs(15), |cx| {
        direct_pane(cx).is_some_and(|p| {
            p.read(cx)
                .options
                .as_ref()
                .is_some_and(|o| o.images_per_request == 4)
        })
    })
    .await;
    let mut pass = ok("Images per Request is set", images);
    in_pane_settings(cx, |p, window, cx| {
        p.choose(MENU_ENGINE, "brave", window, cx);
        p.choose(MENU_SAFE, "strict", window, cx);
        p.choose(MENU_REGION, "fr-fr", window, cx);
    });
    let search = wait_until(cx, Duration::from_secs(15), |cx| {
        direct_pane(cx).is_some_and(|p| {
            p.read(cx).search.as_ref().is_some_and(|w| {
                w.engine == "brave"
                    && w.safe_search == "strict"
                    && w.region.as_deref() == Some("fr-fr")
            })
        })
    })
    .await;
    pass &= ok(
        "the web search engine, safe search and region are saved",
        search,
    );
    let rpc = cx.update(rpc);
    let stored = rpc.call::<methods::WebSearchGet>(&NoParams).await;
    pass &= ok(
        "the daemon keeps them",
        stored.is_ok_and(|w| w.engine == "brave" && w.effective_region == "fr-fr"),
    );
    in_pane_settings(cx, |p, _, cx| p.refresh_quietly(cx));
    settle(cx, 1500).await;
    shoot_tall(dir, "direct-pane", cx).await;
    // Back to the defaults, for any pass after this one.
    in_pane_settings(cx, |p, window, cx| {
        p.choose(MENU_ENGINE, "auto", window, cx);
        p.choose(MENU_SAFE, "moderate", window, cx);
        p.choose(MENU_REGION, "auto", window, cx);
        p.choose(MENU_IMAGES, "10", window, cx);
    });
    settle(cx, 800).await;
    pass
}
