//! `--e2e <scenario>`: live end-to-end passes over the real daemon, driven
//! in-process through the same view methods the controls call, with
//! screenshots (light and dark) and AccessKit checks of each screen.
//!
//! Every pass that needs a server or a provider runs against the local Open
//! WebUI that `tool/local_owui/owui.sh up` starts and seeds, with its fake
//! model and fake Hermes server; nothing here reaches a real account.
//!
//! * `owui`: a fresh profile (Settings › Data › Clear local data), the
//!   backend chooser, a bad address, the server form, a wrong password, a
//!   password sign-in, the main frame, Settings › Accounts and the other
//!   tabs, Add account then Cancel (`accounts.cancelAdd`), a native sheet,
//!   the approval cards (answered through `ui.respond`), a toast, and Sign
//!   out with hand-over (to onboarding: no other account).
//! * `sso`: from a fresh profile, the server form, then single sign-on in
//!   the webview window; a test script on the server's sign-in page signs
//!   in the way a user at an identity provider would, and the captured
//!   cookies go through `auth.completeExternal`.
//! * `direct`: a fresh profile, Direct, the fake model as an
//!   OpenAI-compatible provider (`FAKE_OPENAI_URL`), Test, Save, and the
//!   direct-only main frame.
//! * `direct-advanced`: Settings › Direct Connections end to end: headers,
//!   manual models, the Responses API, the history location, a connection
//!   kept in Open WebUI, Ollama's models, an MCP server signed in with OAuth
//!   and its tool called, and web search reaching the request ([`direct`]).
//! * `hermes`: a fresh profile, Hermes in API-server mode against the fake
//!   Hermes server (`FAKE_HERMES_URL`, `FAKE_HERMES_KEY`), Test, Save, and
//!   the Hermes-only main frame.
//! * `hermes-sessions`: Hermes sessions on a real local Desktop gateway
//!   (`HERMES_GATEWAY_URL`, `HERMES_GATEWAY_TOKEN`): opened in the chat
//!   pane and answered, pin, rename, fork, archive, hide and Hidden Chats,
//!   Branch from Here, Undo Last Turn, delete; and a read-only session of
//!   the fake API server continued in a copy ([`hermes_sessions`]).
//! * `hermes-rooms`: Hermes Bot Mode and Group Chats on the same real
//!   gateway: a bot's Bot Chat, New Room, @mentions answered by both bots,
//!   a paused debate continued, an approval card, Room Info, rename, stop
//!   and disband ([`hermes_rooms`]).
//! * `sidebar`: sign in to the seeded server, then the sidebar: folders as the
//!   account left them, open, hover, rename, pin, move to folder (menu and
//!   drop), remove from folder, archive and the archived section, delete,
//!   bulk archive, search, the ⌘K palette (recent, search, open a hit), New
//!   Chat, and comfortable density.
//! * `chat`, `chat-direct`, `chat-smoke`: the chat view ([`chat`]).
//! * `integration`: the sidebar and the chat view together ([`integration`]).
//! * `composer`: the composer's mobile parity: drafts, the queue, the `$`,
//!   `@` and `#` triggers, server files, a web page, the code interpreter,
//!   quick pills, the larger editor, Save as Note and Ask Conduit
//!   ([`composer`]).
//! * `shell`: the macOS shell extras: links, Open with, Settings ›
//!   Desktop, Quick Ask, notifications, close to the menu bar, open at
//!   login, the model the composer names after a send and Show Sidebar
//!   ([`shell`]).
//! * `share`: the Share menu's hand-off (a share staged in the inbox as the
//!   Share extension stages it, opened by its `conduit://share/` link) and
//!   the Services menu's Ask Conduit and New Conduit Chat With Selection
//!   ([`share`]); `share-system` waits for the real extension and Services
//!   menu (`packaging/macos/share/e2e-system.sh`).
//! * `sections`: the sidebar's areas on the seeded server: sections per
//!   capability, collapse kept per account, the keyboard across sections,
//!   note and channel links, the Go menu, lists on `*.changed`, and
//!   Hermes's section coming and going ([`sections`]).
//! * `settings`: Settings' phone pages (Profile, Personalization, Chat,
//!   Connection, Audio, Data Controls behind Advanced, Accounts' Sign Out,
//!   About) and the after-update release notes ([`settings`]).
//! * `actions`: message and chat actions: Info, Regenerate With, versions
//!   and branches kept on the server, Branch in New Chat, Delete, Compare
//!   Models with Continue from Here and Merge Responses, Export, Share
//!   Chat, Generate Title, Mark as Unread and Save Chat ([`actions`]).
//! * `widget`: the desktop widget's snapshot (sign-in, rename, archive, a
//!   new chat, the language, sign-out) and its links ([`widget`]).
//! * `intents`: Shortcuts' actions (App Intents) through the Swift
//!   intents' own `perform()` and chat query ([`intents`]).
//! * `mac-extras-2`: Send to Conduit, Send Link and Send Image; the Dock
//!   menu; the clipboard link; Continuity Camera in the + menu; and
//!   `{{USER_LOCATION}}` from the window's stand-in ([`mac_extras`]).
//! * `apple`: Apple's on-device model: this Mac's real status in Settings ›
//!   Direct Connections, then the engine's scripted model checked ready, in
//!   the model picker, a chat streamed, stopped and failed ([`apple`]).
//! * `apple-only`: Apple On-Device as the only model (Open WebUI signed
//!   out, the engine's scripted model answering): Ask Conduit, Quick Ask and
//!   the widget's links answer through it, or say why not ([`apple::only`]).
//! * `a11y-sweep`: Calendar, Scheduled Tasks, the terminal and two
//!   Settings panes, as VoiceOver and Full Keyboard Access (simulated in
//!   the app) meet them: announcements, roles and labels, and Tab's reach
//!   and order ([`a11y_sweep`]).
//! * `servers`: a saved server's sheet: addresses added (asking before a
//!   session goes to a new host), refused in the phone's words, edited,
//!   reordered (kept across a conduitd restart), handed to the sign-in
//!   proxy's window (only with `OWUI_PROXY_URL` set: start the proxy with
//!   `owui.sh proxy start`; without it the scenario says it skipped that
//!   step), removed; the server renamed; Add Account on This Server; Add
//!   Account's Hermes Agent and Model Provider ([`servers`]).
//! * `offline-setup`, `offline`: a signed-in account whose server is out of
//!   reach at launch, with conduitd restarted once while the window opens;
//!   two launches, run by `crates/app/e2e-offline.sh` ([`offline`]).
//!
//! The server's synthetic credentials come from the env file `owui.sh seed`
//! writes (`--e2e-env` names another), read at run time and never printed
//! or written; screenshots show synthetic account names and hosts
//! ([`crate::views::privacy`]), and the forms are captured before values are
//! typed.

mod a11y_sweep;
mod actions;
mod agents;
mod apple;
mod apps_leftovers;
mod calendar;
mod channels;
mod chat;
mod chat_settings;
mod composer;
mod dictation;
mod direct;
mod hermes_admin;
mod hermes_cards;
mod hermes_extras;
mod hermes_rooms;
mod hermes_sessions;
mod integration;
mod integrations;
mod intents;
mod librechat;
mod mac_extras;
mod notes;
mod notifications;
mod offline;
mod read_aloud;
mod rendering;
mod rendering_media;
mod sections;
mod servers;
mod settings;
mod share;
pub mod shell;
mod sign_in;
mod tasks;
mod terminal;
mod voice_call;
mod voice_call_hermes;
mod widget;
mod workspace;

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use conduit_components::capture;
use conduit_components::window as cw;
use conduit_protocol::{NoticeLevel, UiInputOption, UiInputType, UiRequest, UiRequestKind};
use gpui_kit::{AnyWindowHandle, App, AsyncApp, Entity, Window};
use serde_json::{Value, json};

use crate::AppState;
use crate::shell::sheet::{AutoAnswer, SheetSpec, present_sheet};
use crate::shell::sso::SsoScript;
use crate::smoke::{current_route, current_status, shoot, shoot_both_modes};
use crate::stores::connection::Status;
use crate::stores::session::Route;
use crate::views::main_window::MainWindow;
use crate::views::onboarding::Step;
use crate::views::settings::Tab;
use crate::views::setup_window::SetupWindow;
use crate::views::sidebar::{ChatCommand, ChatMenu, DraggedChat};

/// What the E2E needs from outside: the local server's env file.
#[derive(Clone, Debug, Default)]
pub struct E2eInputs {
    pub scenario: String,
    /// KEY=VALUE pairs (the env file). Never printed.
    pub env: BTreeMap<String, String>,
}

/// Whether env entry `key` names another machine. Every address in the
/// env file (a `*_URL` with a host: every server a pass signs in to, or
/// sends credentials, messages or settings to) must be this Mac's own
/// (loopback), or the env file is not used. The address checked is the
/// one a pass would use: a bare host is read as the server form reads it,
/// its scheme added first ([`crate::views::forms::normalize_url`]). One that
/// names no host (a database file) is no server.
fn names_another_machine(key: &str, value: &str) -> bool {
    if !key.ends_with("_URL") {
        return false;
    }
    let value = value.trim();
    let address = if value.contains("://") {
        Some(value.to_string())
    } else {
        crate::views::forms::normalize_url(value)
    };
    address
        .is_some_and(|a| url::Url::parse(&a).is_ok_and(|u| u.host().is_some()) && !is_local_url(&a))
}

/// Whether `url` is an http(s) or ws(s) address on this Mac (loopback).
pub(crate) fn is_local_url(url: &str) -> bool {
    url::Url::parse(url).is_ok_and(|u| {
        matches!(u.scheme(), "http" | "https" | "ws" | "wss")
            && match u.host() {
                Some(url::Host::Domain(d)) => d.eq_ignore_ascii_case("localhost"),
                Some(url::Host::Ipv4(ip)) => ip.is_loopback(),
                Some(url::Host::Ipv6(ip)) => ip.is_loopback(),
                None => false,
            }
    })
}

/// What a pass says when the env file is missing or incomplete.
const NO_SERVER: &str = "the local Open WebUI's env file is there (tool/local_owui/owui.sh up)";

impl E2eInputs {
    pub fn from_args(args: &[String]) -> Option<Self> {
        let arg = |k: &str| {
            args.iter()
                .position(|a| a == k)
                .and_then(|i| args.get(i + 1))
                .cloned()
        };
        let scenario = arg("--e2e")?;
        let path = arg("--e2e-env").map(PathBuf::from).or_else(|| {
            let var = |k: &str| std::env::var(k).ok().filter(|v| !v.is_empty());
            default_env_path(var)
        });
        let mut env = path
            .and_then(|p| std::fs::read_to_string(p).ok())
            .map(|text| parse_env(&text))
            .unwrap_or_default();
        // The passes sign in with these credentials and photograph what
        // the server shows: only ever on this Mac's own test server.
        // The address itself is never logged: it may be private.
        let remote: Vec<String> = env
            .iter()
            .filter(|(k, v)| names_another_machine(k, v))
            .map(|(k, _)| k.clone())
            .collect();
        for key in remote {
            println!("SMOKE FAILED e2e {key} is not a local (loopback) address");
            env.clear();
        }
        Some(Self { scenario, env })
    }

    pub(crate) fn get(&self, key: &str) -> Option<String> {
        self.env.get(key).cloned().filter(|v| !v.is_empty())
    }

    /// The seeded admin: `OWUI_URL`, `OWUI_EMAIL` and `OWUI_PASSWORD`.
    pub(crate) fn owui(&self) -> Option<(String, String, String)> {
        Some((
            self.get("OWUI_URL")?,
            self.get("OWUI_EMAIL")?,
            self.get("OWUI_PASSWORD")?,
        ))
    }

    /// The fake model's name in the server's model list.
    pub(crate) fn model(&self) -> String {
        self.get("OWUI_MODEL")
            .unwrap_or_else(|| "fake-model".into())
    }
}

/// Where `tool/local_owui/owui.sh` writes its env file: `CONDUIT_OWUI_ENV`,
/// else `local-owui.env` in `CONDUIT_OWUI_DIR`, else in `local-owui` under
/// `CONDUIT_DEV_CACHE` (default `~/Library/Caches/conduit-dev`).
pub fn default_env_path(var: impl Fn(&str) -> Option<String>) -> Option<PathBuf> {
    if let Some(path) = var("CONDUIT_OWUI_ENV") {
        return Some(path.into());
    }
    if let Some(dir) = var("CONDUIT_OWUI_DIR") {
        return Some(Path::new(&dir).join("local-owui.env"));
    }
    let cache = match var("CONDUIT_DEV_CACHE") {
        Some(cache) => PathBuf::from(cache),
        None => Path::new(&var("HOME")?).join("Library/Caches/conduit-dev"),
    };
    Some(cache.join("local-owui").join("local-owui.env"))
}

/// `KEY=VALUE` lines; quotes stripped, comments and blanks skipped.
pub fn parse_env(text: &str) -> BTreeMap<String, String> {
    text.lines()
        .filter_map(|l| {
            let l = l.trim();
            if l.is_empty() || l.starts_with('#') {
                return None;
            }
            let l = l.strip_prefix("export ").unwrap_or(l);
            let (k, v) = l.split_once('=')?;
            let v = v.trim().trim_matches('"').trim_matches('\'');
            Some((k.trim().to_string(), v.to_string()))
        })
        .collect()
}

fn ok(label: &str, pass: bool) -> bool {
    if pass {
        println!("SMOKE e2e ok {label}");
    } else {
        println!("SMOKE FAILED e2e {label}");
    }
    pass
}

fn main_window(cx: &mut App) -> Option<(AnyWindowHandle, Entity<MainWindow>)> {
    let state = cx.try_global::<AppState>()?;
    Some((state.main_window?, state.main_view.clone()?))
}

/// Runs `f` on the main window view with its window.
fn in_main<R>(
    cx: &mut AsyncApp,
    f: impl FnOnce(&mut MainWindow, &mut Window, &mut gpui_kit::Context<MainWindow>) -> R,
) -> Option<R> {
    let (handle, view) = cx.update(main_window)?;
    handle
        .update(cx, |_, window, cx| {
            view.update(cx, |mw, cx| f(mw, window, cx))
        })
        .ok()
}

fn setup_window(cx: &mut App) -> Option<(AnyWindowHandle, Entity<SetupWindow>)> {
    cx.try_global::<AppState>()?.setup_window.clone()
}

/// Runs `f` on the setup window's view (first run, sign-in) with its window.
fn in_setup<R>(
    cx: &mut AsyncApp,
    f: impl FnOnce(&mut SetupWindow, &mut Window, &mut gpui_kit::Context<SetupWindow>) -> R,
) -> Option<R> {
    let (handle, view) = cx.update(setup_window)?;
    handle
        .update(cx, |_, window, cx| {
            view.update(cx, |sw, cx| f(sw, window, cx))
        })
        .ok()
}

/// The setup window, once the session ends (or before it begins): it opens
/// a moment after the route says so.
async fn wait_setup(cx: &mut AsyncApp) -> Option<AnyWindowHandle> {
    wait_until(cx, Duration::from_secs(10), crate::windows::setup_alive).await;
    cx.update(setup_window).map(|(h, _)| h)
}

/// The main window, once there is a session: it opens a moment after the
/// route says so, and the setup window closes.
async fn wait_main(cx: &mut AsyncApp) -> Option<AnyWindowHandle> {
    let swapped = wait_until(cx, Duration::from_secs(10), |cx| {
        main_window(cx).is_some() && setup_window(cx).is_none()
    })
    .await;
    ok("the main window took over from the setup window", swapped);
    cx.update(main_window).map(|(h, _)| h)
}

async fn shoot_setup(dir: &Path, name: &str, cx: &mut AsyncApp) {
    if let Some(handle) = wait_setup(cx).await {
        shoot_both_modes(handle, dir, name, cx).await;
    }
}

async fn wait_until(
    cx: &mut AsyncApp,
    timeout: Duration,
    mut done: impl FnMut(&mut App) -> bool,
) -> bool {
    let deadline = Instant::now() + timeout;
    loop {
        if cx.update(|cx| done(cx)) {
            return true;
        }
        if Instant::now() > deadline {
            return false;
        }
        cx.background_executor()
            .timer(Duration::from_millis(200))
            .await;
    }
}

async fn wait_route(cx: &mut AsyncApp, want: Route, timeout: Duration) -> bool {
    let reached = wait_until(cx, timeout, |cx| {
        current_route(cx) == want && current_status(cx) == Status::Connected
    })
    .await;
    let now = cx.update(current_route);
    ok(&format!("route {want:?} (now {now:?})"), reached)
}

async fn settle(cx: &mut AsyncApp, ms: u64) {
    cx.background_executor()
        .timer(Duration::from_millis(ms))
        .await;
}

/// Roles a VoiceOver user operates (as in the gallery's check).
const CONTROL_ROLES: &[&str] = &[
    "Button",
    "CheckBox",
    "Switch",
    "RadioButton",
    "TextInput",
    "MultilineTextInput",
    "SearchInput",
    "PasswordInput",
    "ComboBox",
    "Link",
    "MenuItem",
    "Tab",
    "ListBoxOption",
    "TreeItem",
    "Slider",
];

/// Activates accessibility on `handle`, reads GPUI's AccessKit tree, and
/// checks every control has a label; writes `<dir>/ax/<name>.json`.
/// Returns the labelled controls, and the labelled headings, as
/// `role:label`, followed by their states in brackets when they have any
/// (`TreeItem:Garden [selected, expanded, focused]`).
/// Controls without a label any [`ax`] check has found in this run.
static UNLABELLED: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);

/// How many controls without a label this run's [`ax`] checks found.
pub(crate) fn unlabelled_seen() -> usize {
    UNLABELLED.load(std::sync::atomic::Ordering::Relaxed)
}

pub(crate) async fn ax(
    handle: AnyWindowHandle,
    name: &str,
    dir: &Path,
    cx: &mut AsyncApp,
) -> Vec<String> {
    let ptr = cx.update(|cx| {
        handle
            .update(cx, |_, window, _| cw::macos::ns_window_ptr(window))
            .ok()
            .flatten()
    });
    if let Some(ptr) = ptr {
        // SAFETY: this process's live NSWindow, on the main thread.
        unsafe { capture::activate_accessibility(ptr) };
    }
    let mut tree = None;
    for _ in 0..20 {
        settle(cx, 150).await;
        tree = cx.update(|cx| {
            handle
                .update(cx, |_, window, _| {
                    window.refresh();
                    window.debug_a11y_tree_json()
                })
                .ok()
                .flatten()
        });
        if tree.as_ref().is_some_and(|t| t.contains("\"Button\"")) {
            break;
        }
    }
    let parsed = tree.as_deref().map(serde_json::from_str::<Value>);
    let Some(Ok(tree)) = parsed else {
        // Say why, and keep what came, for the next look.
        let why = match &parsed {
            None => "no tree".to_string(),
            Some(Err(e)) => e.to_string(),
            Some(Ok(_)) => String::new(),
        };
        if let Some(raw) = &tree {
            let out = dir.join("ax");
            std::fs::create_dir_all(&out).ok();
            std::fs::write(out.join(format!("{name}.raw.json")), raw).ok();
        }
        ok(&format!("ax {name}: tree ({why})"), false);
        return vec![];
    };
    let mut controls = vec![];
    let mut failures = vec![];
    // The node VoiceOver hears as focused: a list's or group's current row
    // or option when it names one, else the focused element.
    let focused = tree
        .get("active_descendant_focus")
        .and_then(Value::as_str)
        .or_else(|| tree.get("gpui_focus").and_then(Value::as_str))
        .map(str::to_string);
    if let Some(nodes) = tree.get("nodes").and_then(Value::as_object) {
        for (key, node) in nodes {
            let aria = node.get("aria").cloned().unwrap_or(Value::Null);
            let role = aria.get("role").and_then(Value::as_str).unwrap_or("");
            let label = aria
                .get("label")
                .and_then(Value::as_str)
                .unwrap_or("")
                .trim()
                .to_string();
            let control = CONTROL_ROLES.contains(&role);
            if !control && !(role == "Heading" && !label.is_empty()) {
                continue;
            }
            if control && label.is_empty() {
                let id = node
                    .get("element_id")
                    .and_then(Value::as_str)
                    .unwrap_or(key);
                failures.push(format!("{role} {id} has no label"));
            }
            let mut states = vec![];
            if aria.get("selected").and_then(Value::as_bool) == Some(true) {
                states.push("selected");
            }
            match aria.get("expanded").and_then(Value::as_bool) {
                Some(true) => states.push("expanded"),
                Some(false) => states.push("collapsed"),
                None => {}
            }
            if focused.as_deref() == Some(key.as_str()) {
                states.push("focused");
            }
            if states.is_empty() {
                controls.push(format!("{role}:{label}"));
            } else {
                controls.push(format!("{role}:{label} [{}]", states.join(", ")));
            }
        }
    }
    controls.sort();
    UNLABELLED.fetch_add(failures.len(), std::sync::atomic::Ordering::Relaxed);
    let out = dir.join("ax");
    std::fs::create_dir_all(&out).ok();
    let report = json!({"screen": name, "controls": controls, "failures": failures});
    std::fs::write(
        out.join(format!("{name}.json")),
        serde_json::to_vec_pretty(&report).unwrap_or_default(),
    )
    .ok();
    println!(
        "SMOKE ax {name}: {} controls, {} unlabelled",
        controls.len(),
        failures.len()
    );
    ok(
        &format!("ax {name} labelled"),
        failures.is_empty() && !controls.is_empty(),
    );
    controls
}

fn has(controls: &[String], role: &str, label_contains: &str) -> bool {
    controls
        .iter()
        .any(|c| c.starts_with(&format!("{role}:")) && c.contains(label_contains))
}

/// Settings › Data › Clear local data, minus the sheet: a fresh profile.
async fn fresh_profile(cx: &mut AsyncApp) -> bool {
    let connected = wait_until(cx, Duration::from_secs(90), |cx| {
        matches!(current_status(cx), Status::Connected | Status::CoreStarting)
            && current_route(cx) != Route::Unknown
    })
    .await;
    if !ok("connected before the reset", connected) {
        return false;
    }
    let ours = cx.update(|cx| crate::may_reset_profile(&cx.global::<AppState>().paths));
    if !ok("the profile to reset is not the app's own", ours) {
        return false;
    }
    cx.update(|cx| {
        let c = cx.global::<AppState>().connection.clone();
        c.update(cx, |c, cx| c.clear_local_data(cx));
    });
    settle(cx, 1500).await;
    wait_route(cx, Route::Onboarding, Duration::from_secs(90)).await
}

fn set_text(
    state: &Entity<gpui_kit::component::input::InputState>,
    text: &str,
    window: &mut Window,
    cx: &mut App,
) {
    let text = text.to_string();
    state.update(cx, |i, cx| i.set_value(text, window, cx));
}

/// The server form: an address, a name, then Connect.
async fn connect_server(url: &str, name: &str, cx: &mut AsyncApp) {
    let (url, name) = (url.to_string(), name.to_string());
    in_setup(cx, move |sw, window, cx| {
        let form = sw.onboarding.read(cx).server.clone();
        let (u, n) = {
            let f = form.read(cx);
            (f.url.clone(), f.name.clone())
        };
        set_text(&u, &url, window, cx);
        set_text(&n, &name, window, cx);
        form.update(cx, |f, cx| f.submit(window, cx));
    });
}

/// Fills Add Account's sheet on the Settings window and connects.
async fn connect_in_sheet(url: &str, name: &str, cx: &mut AsyncApp) {
    let (url, name) = (url.to_string(), name.to_string());
    let Some(sheet) = cx.update(|cx| {
        let (_, view) = cx.global::<AppState>().settings_window.clone()?;
        view.read(cx).add_sheet.clone()
    }) else {
        return;
    };
    let _ = sheet.handle.update(cx, move |_, window, cx| {
        let form = sheet.form(cx);
        let (u, n) = {
            let f = form.read(cx);
            (f.url.clone(), f.name.clone())
        };
        set_text(&u, &url, window, cx);
        set_text(&n, &name, window, cx);
        form.update(cx, |f, cx| f.submit(window, cx));
    });
}

async fn sign_in_password(email: &str, password: &str, cx: &mut AsyncApp) {
    let (email, password) = (email.to_string(), password.to_string());
    in_setup(cx, move |sw, window, cx| {
        let view = sw.sign_in.clone();
        let (e, p) = {
            let v = view.read(cx);
            (v.email.clone(), v.password.clone())
        };
        set_text(&e, &email, window, cx);
        set_text(&p, &password, window, cx);
        view.update(cx, |v, cx| v.submit(window, cx));
    });
}

async fn shoot_main(dir: &Path, name: &str, cx: &mut AsyncApp) {
    if let Some((handle, _)) = cx.update(main_window) {
        shoot_both_modes(handle, dir, name, cx).await;
    }
}

async fn settings_tab(
    tab: Tab,
    dir: &Path,
    name: &str,
    cx: &mut AsyncApp,
) -> Option<AnyWindowHandle> {
    cx.update(|cx| crate::open_settings(Some(tab), cx));
    settle(cx, 600).await;
    let handle = cx.update(|cx| {
        cx.global::<AppState>()
            .settings_window
            .as_ref()
            .map(|(h, _)| *h)
    })?;
    crate::smoke::place_settings(handle, cx);
    settle(cx, 300).await;
    shoot_both_modes(handle, dir, name, cx).await;
    Some(handle)
}

fn request(id: &str, kind: UiRequestKind, args: &[(&str, &str)]) -> UiRequest {
    UiRequest {
        request_id: id.into(),
        kind,
        message_code: "server.prompt".into(),
        message_args: args
            .iter()
            .map(|(k, v)| (k.to_string(), v.to_string()))
            .collect(),
        detail: json!({}),
        timeout_ms: None,
        default_choice: "deny".into(),
        input_type: None,
        options: None,
    }
}

/// The approval cards, each kind once, answered through `ui.respond` (the
/// daemon answers `accepted: false` for these made-up ids, which takes
/// them away).
async fn approval_cards(dir: &Path, cx: &mut AsyncApp) -> bool {
    let mut mcp = request(
        "e2e-mcp",
        UiRequestKind::McpApproval,
        &[("serverName", "Files"), ("toolName", "read_file")],
    );
    mcp.message_code = "mcp.approval".into();
    mcp.detail = json!({"arguments": "{\"path\": \"notes/today.md\"}"});
    let mut hermes = request(
        "e2e-hermes",
        UiRequestKind::HermesDecision,
        &[("summary", "Run `ls -la ~/projects`")],
    );
    hermes.message_code = "hermes.approval".into();
    hermes.detail = json!({"choices": ["once", "session", "always", "deny"]});
    let mut select = request(
        "e2e-select",
        UiRequestKind::InputPrompt,
        &[
            ("title", "Which environment?"),
            ("message", "The deploy tool needs a target."),
        ],
    );
    select.input_type = Some(UiInputType::Select);
    select.options = Some(vec![
        UiInputOption {
            value: "staging".into(),
            label: "Staging".into(),
        },
        UiInputOption {
            value: "production".into(),
            label: "Production".into(),
        },
    ]);
    let mut password = request(
        "e2e-password",
        UiRequestKind::InputPrompt,
        &[
            ("title", "Key passphrase"),
            ("message", "Unlock the signing key."),
        ],
    );
    password.input_type = Some(UiInputType::Password);
    let mut clarify = request("e2e-clarify", UiRequestKind::HermesDecision, &[]);
    clarify.message_code = "hermes.clarify".into();
    let cards = [
        (
            request(
                "e2e-tool",
                UiRequestKind::ToolApproval,
                &[
                    ("title", "Run web search"),
                    ("message", "The model wants to search the web."),
                ],
            ),
            "approval-tool",
        ),
        (mcp, "approval-mcp"),
        (hermes, "approval-hermes"),
        (select, "approval-select"),
        (password, "approval-password"),
        (clarify, "approval-unsupported"),
    ];
    let mut all = true;
    for (req, name) in cards {
        let id = req.request_id.clone();
        cx.update(|cx| {
            let u = cx.global::<AppState>().stores.ui_requests.clone();
            u.update(cx, |u, cx| u.on_request(req, cx));
        });
        settle(cx, 300).await;
        shoot_main(dir, name, cx).await;
        if name == "approval-password"
            && let Some((handle, _)) = cx.update(main_window)
        {
            let controls = ax(handle, name, dir, cx).await;
            all &= ok(
                "the password prompt is a labelled field with Skip and Send",
                has(&controls, "Button", "Skip") && has(&controls, "Button", "Send"),
            );
        }
        // ⌥⌘⌫ through the same action the key binding dispatches.
        cx.update(|cx| {
            if let Some((handle, _)) = main_window(cx) {
                let _ = handle.update(cx, |_, window, cx| {
                    window.dispatch_action(Box::new(crate::actions::DenyRequest), cx)
                });
            }
        });
        let gone = wait_until(cx, Duration::from_secs(10), |cx| {
            let u = cx.global::<AppState>().stores.ui_requests.read(cx);
            !u.queue.iter().any(|r| r.request_id == id)
        })
        .await;
        all &= ok(&format!("{name}: answered and settled"), gone);
    }
    all
}

/// A sheet on the Settings window, captured, then cancelled the way Esc
/// does it.
async fn native_sheet(handle: AnyWindowHandle, dir: &Path, cx: &mut AsyncApp) -> bool {
    let l10n = cx.update(|cx| crate::l10n::ActiveL10n::l10n(cx).clone());
    let spec = SheetSpec::new(
        l10n.accounts_sign_out_confirm_title("Avery Example"),
        l10n.accounts_sign_out_confirm_message(),
        l10n.sign_out(),
        l10n.cancel(),
    )
    .destructive();
    cx.update(|cx| cx.set_global(AutoAnswer(None)));
    let task = cx.update(|cx| {
        handle
            .update(cx, |_, window, cx| present_sheet(window, spec, cx))
            .ok()
    });
    let Some(task) = task else {
        return ok("sheet opened", false);
    };
    settle(cx, 900).await;
    shoot(handle, dir.join("sheet-sign-out.png"), cx).await;
    // Outside any GPUI borrow: ending a sheet calls back into the window.
    let ns = cx.update(|cx| crate::smoke::ns_window(handle, cx));
    let attached = ns
        .as_ref()
        .is_some_and(|ns| crate::smoke::end_attached_sheet(ns));
    let answer = task.await;
    cx.update(|cx| cx.set_global(AutoAnswer(Some(true))));
    ok("a native sheet was attached", attached) && ok("cancel answers false", !answer)
}

pub async fn run(inputs: E2eInputs, dir: PathBuf, cx: &mut AsyncApp) -> bool {
    cx.update(|cx| {
        cx.set_global(crate::views::privacy::Redact(true));
        cx.set_global(AutoAnswer(Some(true)));
    });
    match inputs.scenario.as_str() {
        "owui" => owui(&inputs, &dir, cx).await,
        "sso" => sso(&inputs, &dir, cx).await,
        "direct" => direct(&inputs, &dir, cx).await,
        "direct-advanced" => direct::run(&inputs, &dir, cx).await,
        "apple" => apple::run(&inputs, &dir, cx).await,
        "hermes" => hermes(&inputs, &dir, cx).await,
        "hermes-sessions" => hermes_sessions::run_scenario(&inputs, &dir, cx).await,
        "hermes-rooms" => hermes_rooms::run_scenario(&inputs, &dir, cx).await,
        "hermes-cards" => hermes_cards::run(&inputs, &dir, cx).await,
        "hermes-admin" => hermes_admin::run(&inputs, &dir, cx).await,
        "hermes-extras" => hermes_extras::run(&inputs, &dir, cx).await,
        "sidebar" => sidebar(&inputs, &dir, cx).await,
        "chat" | "chat-direct" | "chat-smoke" | "chat-read-only" => {
            chat::run(&inputs, &dir, cx).await
        }
        "integration" => integration::run(&inputs, &dir, cx).await,
        "sections" => sections::run(&inputs, &dir, cx).await,
        "channels" => channels::run(&inputs, &dir, cx).await,
        "librechat" => librechat::run(&inputs, &dir, cx).await,
        "composer" => composer::run(&inputs, &dir, cx).await,
        "chat-settings" => chat_settings::run(&inputs, &dir, cx).await,
        "shell" | "shell-notify" | "shell-close" => shell::run(&inputs, &dir, cx).await,
        "share" | "share-system" => share::run(&inputs, &dir, cx).await,
        "offline-setup" => offline::setup(&inputs, &dir, cx).await,
        "offline" => offline::run(&inputs, &dir, cx).await,
        "settings" => settings::run(&inputs, &dir, cx).await,
        "servers" => servers::run(&inputs, &dir, cx).await,
        "actions" => actions::run(&inputs, &dir, cx).await,
        "read-aloud" => read_aloud::run(&inputs, &dir, cx).await,
        "rendering" => rendering::run(&inputs, &dir, cx).await,
        "rendering-media" => rendering_media::run(&inputs, &dir, cx).await,
        "dictation" => dictation::run(&inputs, &dir, cx).await,
        "notes" => notes::run(&inputs, &dir, cx).await,
        "dictation-recovered" => dictation::recovered(&inputs, &dir, cx).await,
        "voice-call" => voice_call::run(&inputs, &dir, cx).await,
        "voice-call-hermes" => voice_call_hermes::run(&inputs, &dir, cx).await,
        "workspace" => workspace::run(&inputs, &dir, cx).await,
        "calendar" => calendar::run(&inputs, &dir, cx).await,
        "tasks" => tasks::run(&inputs, &dir, cx).await,
        "agents" => agents::run(&inputs, &dir, cx).await,
        "widget" => widget::run(&inputs, &dir, cx).await,
        "intents" => intents::run(&inputs, &dir, cx).await,
        "mac-extras-2" => mac_extras::run(&inputs, &dir, cx).await,
        "terminal" => terminal::run(&inputs, &dir, cx).await,
        "apple-only" => apple::only(&inputs, &dir, cx).await,
        "onboarding-apple" => apple::onboarding(&inputs, &dir, cx).await,
        "notifications" => notifications::run(&inputs, &dir, cx).await,
        "integrations" => integrations::run(&inputs, &dir, cx).await,
        "sign-in-two-step" => sign_in::two_step(&inputs, &dir, cx).await,
        "sign-in-proxy" => sign_in::proxy(&inputs, &dir, cx).await,
        "apps-leftovers" => apps_leftovers::run(&inputs, &dir, cx).await,
        "a11y-sweep" => a11y_sweep::run(&inputs, &dir, cx).await,
        other => ok(&format!("unknown scenario {other}"), false),
    }
}

async fn owui(inputs: &E2eInputs, dir: &Path, cx: &mut AsyncApp) -> bool {
    let Some((url, email, password)) = inputs.owui() else {
        return ok(NO_SERVER, false);
    };
    let mut pass = fresh_profile(cx).await;
    // First run is the compact setup window's; the main window waits for
    // a session.
    let Some(setup) = wait_setup(cx).await else {
        return ok("the setup window opened", false);
    };
    let size = cx.update(|cx| {
        setup
            .update(cx, |_, window, _| {
                let b = window.bounds();
                (f32::from(b.size.width), f32::from(b.size.height))
            })
            .ok()
    });
    pass &= ok(
        &format!("the setup window is 640×560 ({size:?})"),
        size == Some(crate::windows::SETUP_SIZE),
    );
    pass &= ok(
        "no main window while there is no session",
        cx.update(main_window).is_none(),
    );
    settle(cx, 500).await;
    shoot_setup(dir, "onboarding-chooser", cx).await;
    let chooser = ax(setup, "onboarding-chooser", dir, cx).await;
    // The phone's chooser: a row per backend that goes straight to it.
    pass &= ok(
        "the chooser offers three labelled backends",
        has(&chooser, "Button", "Open WebUI")
            && has(&chooser, "Button", "Hermes Agent")
            && chooser.iter().filter(|c| c.starts_with("Button:")).count() >= 3,
    );

    in_setup(cx, |sw, window, cx| {
        sw.onboarding.update(cx, |o, cx| o.choose(window, cx))
    });
    settle(cx, 500).await;
    shoot_setup(dir, "onboarding-server-form", cx).await;
    let form = ax(setup, "onboarding-server-form", dir, cx).await;
    pass &= ok(
        "the server form has labelled fields and Connect",
        has(&form, "TextInput", "") && has(&form, "Button", "Connect"),
    );

    // A bad address is caught on the form.
    connect_server("ftp://not-a-server", "", cx).await;
    settle(cx, 400).await;
    let url_error = in_setup(cx, |sw, _, cx| {
        sw.onboarding.read(cx).server.read(cx).url_error.is_some()
    })
    .unwrap_or(false);
    pass &= ok("an ftp address is refused on the form", url_error);
    shoot_setup(dir, "onboarding-server-form-error", cx).await;

    connect_server(&url, "Lab server", cx).await;
    pass &= wait_route(cx, Route::SignIn, Duration::from_secs(60)).await;
    settle(cx, 500).await;
    // Sign-in follows in the same window.
    pass &= ok(
        "sign-in stays in the setup window",
        cx.update(setup_window).is_some_and(|(h, _)| h == setup)
            && cx.update(main_window).is_none(),
    );
    shoot_setup(dir, "sign-in", cx).await;
    let sign_in = ax(setup, "sign-in", dir, cx).await;
    pass &= ok(
        "sign-in has labelled fields, the method switch and SSO",
        has(&sign_in, "RadioButton", "LDAP")
            && has(&sign_in, "Button", "SSO")
            && sign_in.iter().filter(|c| c.contains("Input:")).count() >= 2,
    );

    // A wrong password says so and stays.
    sign_in_password(&email, "definitely-not-the-password", cx).await;
    let refused = wait_until(cx, Duration::from_secs(30), |cx| {
        let Some((_, view)) = setup_window(cx) else {
            return false;
        };
        let s = view.read(cx).sign_in.read(cx);
        !s.busy && s.error.is_some()
    })
    .await;
    pass &= ok("a wrong password is refused with a message", refused);
    // The field holds a made-up password at this point; the email is
    // masked by nothing, so clear it before the shot.
    in_setup(cx, |sw, window, cx| {
        let e = sw.sign_in.read(cx).email.clone();
        set_text(&e, "avery@example.org", window, cx);
    });
    shoot_setup(dir, "sign-in-error", cx).await;

    sign_in_password(&email, &password, cx).await;
    pass &= wait_route(cx, Route::Main, Duration::from_secs(60)).await;
    pass &= wait_main(cx).await.is_some();
    let user = cx.update(|cx| {
        let s = cx.global::<AppState>().stores.session.read(cx);
        s.auth.as_ref().is_some_and(|a| a.is_authenticated)
    });
    pass &= ok("auth.status is authenticated", user);
    settle(cx, 1500).await;
    shoot_main(dir, "main-signed-in", cx).await;

    // Settings › Accounts shows the account, active.
    let accounts = cx.update(|cx| {
        let a = cx.global::<AppState>().stores.accounts.read(cx);
        (a.accounts().len(), a.active().is_some())
    });
    pass &= ok(
        &format!("one account, active ({accounts:?})"),
        accounts == (1, true),
    );
    if let Some(settings) = settings_tab(Tab::Accounts, dir, "settings-accounts", cx).await {
        let controls = ax(settings, "settings-accounts", dir, cx).await;
        pass &= ok(
            "Accounts lists the account with its menu and Add account",
            has(&controls, "Button", "Add Account") && has(&controls, "Button", "More Actions"),
        );
        pass &= native_sheet(settings, dir, cx).await;
        for (tab, name) in [
            (Tab::Direct, "settings-direct"),
            (Tab::Hermes, "settings-hermes"),
            (Tab::Desktop, "settings-desktop"),
            (Tab::Data, "settings-data"),
            (Tab::Keyboard, "settings-keyboard"),
            (Tab::About, "settings-about"),
        ] {
            settings_tab(tab, dir, name, cx).await;
        }
        let _ = settings.update(cx, |_, window, _| window.remove_window());
    }

    // Add account (a sheet on Settings), then Cancel: back on the first
    // account.
    cx.update(crate::start_adding_account);
    settle(cx, 600).await;
    let sheet = cx.update(|cx| {
        cx.global::<AppState>()
            .settings_window
            .clone()
            .and_then(|(h, v)| v.read(cx).add_sheet.clone().map(|s| (h, s)))
    });
    pass &= ok(
        "Add Account opens a sheet on the Settings window",
        sheet.is_some(),
    );
    if let Some((handle, sheet)) = &sheet {
        settle(cx, 600).await;
        // A real window sheet: AppKit hangs its window from Settings'.
        let (parent, own) = cx.update(|cx| {
            (
                crate::smoke::ns_window(*handle, cx),
                crate::smoke::ns_window(sheet.handle, cx),
            )
        });
        let attached = match (parent, own) {
            (Some(parent), Some(own)) => {
                own.isSheet()
                    && own.sheetParent().is_some_and(|p| {
                        objc2::rc::Retained::as_ptr(&p) == objc2::rc::Retained::as_ptr(&parent)
                    })
            }
            _ => false,
        };
        pass &= ok("the sheet is attached to Settings (beginSheet)", attached);
        shoot_both_modes(*handle, dir, "add-account-sheet", cx).await;
    }
    connect_in_sheet(&url, "Second server", cx).await;
    let adding = wait_until(cx, Duration::from_secs(60), |cx| {
        let a = cx.global::<AppState>().stores.accounts.read(cx);
        a.adding() && current_route(cx) == Route::SignIn
    })
    .await;
    pass &= ok("Add account leads to sign-in for the new account", adding);
    let ended = wait_until(cx, Duration::from_secs(10), |cx| {
        cx.global::<AppState>()
            .settings_window
            .as_ref()
            .is_some_and(|(_, v)| v.read(cx).add_sheet.is_none())
    })
    .await;
    pass &= ok("the sheet ended once the server answered", ended);
    settle(cx, 500).await;
    // Signing in to the new account is the setup window's.
    pass &= ok(
        "the new account signs in in the setup window",
        wait_setup(cx).await.is_some(),
    );
    shoot_setup(dir, "sign-in-adding", cx).await;
    in_setup(cx, |sw, _, cx| sw.sign_in.update(cx, |s, cx| s.back(cx)));
    pass &= wait_route(cx, Route::Main, Duration::from_secs(60)).await;
    pass &= wait_main(cx).await.is_some();
    let back = cx.update(|cx| {
        let a = cx.global::<AppState>().stores.accounts.read(cx);
        (a.accounts().len(), a.adding())
    });
    pass &= ok(
        &format!("Cancel left the addition ({back:?})"),
        back == (1, false),
    );

    // The approval cards and a toast.
    pass &= approval_cards(dir, cx).await;
    cx.update(|cx| {
        let t = cx.global::<AppState>().stores.toasts.clone();
        t.update(cx, |t, cx| {
            t.show(NoticeLevel::Success, "Your export is ready.", cx)
        });
    });
    settle(cx, 300).await;
    shoot_main(dir, "toast", cx).await;

    // Sign out with hand-over: with no other account, onboarding again.
    in_main(cx, |mw, window, cx| {
        crate::views::accounts::sign_out_active(&mw.stores, window, cx)
    });
    pass &= wait_route(cx, Route::Onboarding, Duration::from_secs(60)).await;
    let after = cx.update(|cx| {
        let s = cx.global::<AppState>().stores.clone();
        let a = s.accounts.read(cx);
        (
            a.accounts().len(),
            a.active().is_none(),
            s.session.read(cx).needs_onboarding,
        )
    });
    pass &= ok(
        &format!("signed out: no account, onboarding ({after:?})"),
        after == (0, true, Some(true)),
    );
    // Back to first run: the setup window, and no main window.
    pass &= ok(
        "signing out closes the main window for the setup window",
        wait_setup(cx).await.is_some()
            && wait_until(cx, Duration::from_secs(5), |cx| main_window(cx).is_none()).await,
    );
    shoot_setup(dir, "after-sign-out", cx).await;
    pass
}

async fn sso(inputs: &E2eInputs, dir: &Path, cx: &mut AsyncApp) -> bool {
    let Some((url, email, password)) = inputs.owui() else {
        return ok(NO_SERVER, false);
    };
    let mut pass = fresh_profile(cx).await;
    pass &= ok("the setup window opened", wait_setup(cx).await.is_some());
    in_setup(cx, |sw, window, cx| {
        sw.onboarding
            .update(cx, |o, cx| o.go(Step::Server, window, cx))
    });
    connect_server(&url, "Lab server", cx).await;
    pass &= wait_route(cx, Route::SignIn, Duration::from_secs(60)).await;
    // Stands in for the user at the identity provider: sign in from the
    // server's own page, so the session cookie lands in the window's store.
    let body = json!({"email": email, "password": password}).to_string();
    let script = format!(
        "fetch('/api/v1/auths/signin',{{method:'POST',headers:{{'Content-Type':'application/json'}},credentials:'include',body:{}}}).then(()=>{{location.href='/';}})",
        serde_json::to_string(&body).unwrap_or_default()
    );
    cx.update(|cx| cx.set_global(SsoScript(Some(script))));
    in_setup(cx, |sw, window, cx| {
        sw.sign_in.update(cx, |s, cx| s.start_sso(window, cx))
    });
    // The backdrop, the setup window, and the SSO window.
    let windows = wait_until(cx, Duration::from_secs(10), |cx| cx.windows().len() >= 3).await;
    pass &= ok("the SSO window opened", windows);
    pass &= wait_route(cx, Route::Main, Duration::from_secs(90)).await;
    cx.update(|cx| cx.set_global(SsoScript(None)));
    pass &= wait_main(cx).await.is_some();
    // The backdrop and the main window (the setup window gave way to it).
    let closed = wait_until(cx, Duration::from_secs(10), |cx| cx.windows().len() <= 2).await;
    pass &= ok("the SSO window closed itself", closed);
    let authed = cx.update(|cx| {
        let s = cx.global::<AppState>().stores.session.read(cx);
        s.auth.as_ref().is_some_and(|a| a.is_authenticated)
    });
    pass &= ok("auth.completeExternal signed in", authed);
    settle(cx, 1000).await;
    shoot_main(dir, "main-after-sso", cx).await;
    // Leave the profile signed out again.
    in_main(cx, |mw, window, cx| {
        crate::views::accounts::sign_out_active(&mw.stores, window, cx)
    });
    pass &= wait_route(cx, Route::Onboarding, Duration::from_secs(60)).await;
    pass
}

async fn direct(inputs: &E2eInputs, dir: &Path, cx: &mut AsyncApp) -> bool {
    let Some(base) = inputs.get("FAKE_OPENAI_URL") else {
        return ok(NO_SERVER, false);
    };
    let mut pass = fresh_profile(cx).await;
    in_setup(cx, |sw, window, cx| {
        sw.onboarding.update(cx, |o, cx| {
            o.selected = conduit_components::views::model::Backend::Direct;
            o.choose(window, cx)
        })
    });
    settle(cx, 600).await;
    shoot_setup(dir, "onboarding-direct", cx).await;
    let fill = move |sw: &mut SetupWindow,
                     window: &mut Window,
                     cx: &mut gpui_kit::Context<SetupWindow>| {
        let Some(direct) = sw.onboarding.read(cx).direct_view() else {
            return;
        };
        let (name, url, key) = {
            let d = direct.read(cx);
            (d.name.clone(), d.base_url.clone(), d.api_key.clone())
        };
        set_text(&name, "Local test provider", window, cx);
        set_text(&url, &base, window, cx);
        set_text(&key, "sk-test", window, cx);
        direct.update(cx, |d, cx| d.test(window, cx));
    };
    in_setup(cx, fill);
    let tested = wait_until(cx, Duration::from_secs(30), |cx| {
        let Some((_, view)) = setup_window(cx) else {
            return false;
        };
        let Some(d) = view.read(cx).onboarding.read(cx).direct_view() else {
            return false;
        };
        let d = d.read(cx);
        matches!(&d.note, Some(crate::views::direct::DirectNote::Tested(r)) if r.reachable)
    })
    .await;
    pass &= ok("direct.test reaches the fake provider", tested);
    shoot_setup(dir, "onboarding-direct-tested", cx).await;
    in_setup(cx, |sw, window, cx| {
        if let Some(d) = sw.onboarding.read(cx).direct_view() {
            d.update(cx, |d, cx| d.save(window, cx));
        }
    });
    pass &= wait_route(cx, Route::Main, Duration::from_secs(60)).await;
    pass &= wait_main(cx).await.is_some();
    let only = cx.update(|cx| {
        let s = cx.global::<AppState>().stores.session.clone();
        s.read(cx).direct_only(cx)
    });
    pass &= ok("direct-only", only);
    settle(cx, 800).await;
    shoot_main(dir, "main-direct-only", cx).await;
    settings_tab(Tab::Direct, dir, "settings-direct-saved", cx).await;
    pass
}

async fn hermes(inputs: &E2eInputs, dir: &Path, cx: &mut AsyncApp) -> bool {
    let (Some(base), Some(key)) = (inputs.get("FAKE_HERMES_URL"), inputs.get("FAKE_HERMES_KEY"))
    else {
        return ok(NO_SERVER, false);
    };
    let mut pass = fresh_profile(cx).await;
    in_setup(cx, |sw, window, cx| {
        sw.onboarding.update(cx, |o, cx| {
            o.selected = conduit_components::views::model::Backend::Hermes;
            o.choose(window, cx)
        })
    });
    settle(cx, 800).await;
    shoot_setup(dir, "onboarding-hermes", cx).await;
    let base_url = base.trim_end_matches("/v1").to_string();
    in_setup(cx, move |sw, window, cx| {
        let Some(h) = sw.onboarding.read(cx).hermes_view() else {
            return;
        };
        let (url, api) = {
            let v = h.read(cx);
            (v.base_url.clone(), v.api_key.clone())
        };
        set_text(&url, &base_url, window, cx);
        set_text(&api, &key, window, cx);
        h.update(cx, |h, cx| h.test(window, cx));
    });
    let tested = wait_until(cx, Duration::from_secs(30), |cx| {
        let Some((_, view)) = setup_window(cx) else {
            return false;
        };
        let Some(h) = view.read(cx).onboarding.read(cx).hermes_view() else {
            return false;
        };
        let h = h.read(cx);
        !h.busy && (h.note.is_some() || h.error.is_some())
    })
    .await;
    let test_ok = in_setup(cx, |sw, _, cx| {
        sw.onboarding
            .read(cx)
            .hermes_view()
            .is_some_and(|h| matches!(&h.read(cx).note, Some(crate::views::hermes::HermesNote::Tested(r)) if r.ok))
    })
    .unwrap_or(false);
    pass &= ok("hermes.test answered", tested) && ok("hermes.test ok", test_ok);
    in_setup(cx, |sw, window, cx| {
        if let Some(h) = sw.onboarding.read(cx).hermes_view() {
            h.update(cx, |h, cx| h.save(window, cx));
        }
    });
    pass &= wait_route(cx, Route::Main, Duration::from_secs(60)).await;
    pass &= wait_main(cx).await.is_some();
    let only = cx.update(|cx| {
        let s = cx.global::<AppState>().stores.session.clone();
        s.read(cx).hermes_only(cx)
    });
    pass &= ok("Hermes-only", only);
    settle(cx, 800).await;
    shoot_main(dir, "main-hermes-only", cx).await;
    settings_tab(Tab::Hermes, dir, "settings-hermes-saved", cx).await;
    pass
}

// The `sidebar` scenario.

/// The chat list as the store holds it.
fn chat_titled(title: &str, cx: &mut App) -> Option<conduit_protocol::ChatSummary> {
    let list = cx.global::<AppState>().stores.chat_list.read(cx);
    list.list
        .iter()
        .flat_map(|l| l.chats.iter())
        .find(|c| c.title == title)
        .cloned()
}

fn chat_by_id(id: &str, cx: &mut App) -> Option<conduit_protocol::ChatSummary> {
    let list = cx.global::<AppState>().stores.chat_list.read(cx);
    list.list
        .iter()
        .flat_map(|l| l.chats.iter())
        .find(|c| c.id == id)
        .cloned()
}

fn folder_named(name: &str, cx: &mut App) -> Option<String> {
    let list = cx.global::<AppState>().stores.chat_list.read(cx);
    list.list
        .as_ref()?
        .folders
        .iter()
        .find(|f| f.name == name)
        .map(|f| f.id.clone())
}

/// Runs `command` on `chat_id` the way the native context menu does: by
/// dispatching its action, which the main window hands to the sidebar.
async fn chat_command(chat_id: &str, command: ChatCommand, cx: &mut AsyncApp) {
    let action = ChatMenu {
        chat_id: chat_id.to_string(),
        command,
    };
    in_main(cx, move |_, window, cx| {
        window.dispatch_action(Box::new(action), cx)
    });
    settle(cx, 150).await;
}

/// Waits until the chat with `id` (or its absence) passes `done`.
async fn wait_chat(
    id: &str,
    label: &str,
    timeout: Duration,
    done: impl Fn(Option<&conduit_protocol::ChatSummary>) -> bool,
    cx: &mut AsyncApp,
) -> bool {
    let id = id.to_string();
    let reached = wait_until(cx, timeout, |cx| done(chat_by_id(&id, cx).as_ref())).await;
    ok(label, reached)
}

/// Types `stroke` into the main window as the keyboard would.
/// Opens `urls` as the system hands links to the app.
fn shell_links(urls: &[&str], cx: &mut AsyncApp) {
    let urls: Vec<String> = urls.iter().map(|u| u.to_string()).collect();
    cx.update(|cx| crate::desktop::handle_urls(urls, cx));
}

fn press(handle: AnyWindowHandle, stroke: &str, cx: &mut AsyncApp) {
    let Ok(keystroke) = gpui_kit::Keystroke::parse_with_os(stroke, gpui_kit::OperatingSystem::Mac)
    else {
        return;
    };
    cx.update(|cx| {
        let _ = handle.update(cx, |_, window, cx| window.dispatch_keystroke(keystroke, cx));
    });
}

/// ⌘- and ⇧-click in the sidebar (Mail's and Finder's multiple selection),
/// Chat › Next and Previous Chat (⌃⇥, ⌃⇧⇥) in the sidebar's order, and Chat
/// › Move to greyed out with no chat open.
async fn multiple_selection(main: AnyWindowHandle, dir: &Path, cx: &mut AsyncApp) -> bool {
    use crate::views::sidebar_keys::Pick;
    // Two pinned chats, and one loose in Today (renamed earlier on): all
    // listed whatever folders are open.
    let titles = [
        "Orbital period of a moon",
        "Quilt pattern maths",
        "ISO date regex, renamed",
    ];
    let ids = cx.update(|cx| {
        titles
            .iter()
            .filter_map(|t| chat_titled(t, cx).map(|c| c.id))
            .collect::<Vec<_>>()
    });
    let [a, b, c] = ids.as_slice() else {
        return ok(&format!("three chats to select ({ids:?})"), false);
    };
    let (a, b, c) = (a.clone(), b.clone(), c.clone());
    let open = |id: String| {
        move |mw: &mut MainWindow, _: &mut Window, cx: &mut gpui_kit::Context<MainWindow>| {
            mw.stores.navigation.update(cx, |n, cx| n.open(id, cx))
        }
    };
    let pick = |id: String, how: Pick| {
        move |mw: &mut MainWindow, _: &mut Window, cx: &mut gpui_kit::Context<MainWindow>| {
            mw.sidebar.update(cx, |s, cx| s.pick_chat(&id, how, cx))
        }
    };
    let selected = |cx: &mut AsyncApp| {
        in_main(cx, |mw, _, cx| {
            let s = mw.sidebar.read(cx);
            (s.selecting.clone(), s.has_multiple_selection())
        })
        .unwrap_or((None, false))
    };
    in_main(cx, open(a.clone()));
    settle(cx, 500).await;
    // ⌘-click: the open chat and this one, drawn as selected rows.
    in_main(cx, pick(b.clone(), Pick::Toggle));
    settle(cx, 400).await;
    let (set, rows) = selected(cx);
    let mut pass = ok(
        "⌘-click selects a chat beside the open one, as rows (no checkboxes)",
        rows && set == Some([a.clone(), b.clone()].into_iter().collect()),
    );
    // The list's top (the pinned rows) on screen: only drawn rows are in
    // the accessibility tree.
    in_main(cx, |mw, _, cx| {
        mw.sidebar
            .read(cx)
            .scroll_handle()
            .scroll_to_item(0, gpui_kit::ScrollStrategy::Top);
        mw.sidebar.update(cx, |_, cx| cx.notify());
    });
    settle(cx, 500).await;
    shoot_main(dir, "sidebar-multi-select", cx).await;
    let controls = ax(main, "sidebar-multi-select", dir, cx).await;
    let row_of = |c: &String, t: &str| {
        *c == format!("TreeItem:{t}") || c.starts_with(&format!("TreeItem:{t} ["))
    };
    let rows_shown: Vec<&String> = controls
        .iter()
        .filter(|c| titles[..2].iter().any(|t| row_of(c, t)))
        .collect();
    pass &= ok(
        &format!("both rows read as selected ({rows_shown:?})"),
        rows_shown.len() == 2
            && rows_shown.iter().all(|c| c.contains("selected"))
            && !controls.iter().any(|c| c.starts_with("CheckBox:")),
    );
    // ⌘-click again: back to one chat, open.
    in_main(cx, pick(b.clone(), Pick::Toggle));
    settle(cx, 300).await;
    let (set, _) = selected(cx);
    let opened = cx.update(|cx| {
        let n = cx.global::<AppState>().stores.navigation.read(cx);
        n.selected_chat().map(String::from)
    });
    pass &= ok(
        "⌘-click on a selected row takes it out",
        set.is_none() && opened.as_deref() == Some(a.as_str()),
    );
    // ⇧-click: every chat from the open one to this one.
    in_main(cx, pick(c.clone(), Pick::Range));
    settle(cx, 300).await;
    let (set, rows) = selected(cx);
    let range = set.clone().unwrap_or_default();
    pass &= ok(
        &format!("⇧-click takes in the range ({} chats)", range.len()),
        rows && range.contains(&a) && range.contains(&c) && range.len() >= 2,
    );
    // The selection's context menu acts on all of them; a plain click ends
    // it.
    let menu_moves = in_main(cx, |mw, window, cx| {
        mw.sidebar.update(cx, |s, cx| {
            s.run_on_selection(&ChatCommand::Rename, window, cx)
        })
    })
    .unwrap_or(true);
    pass &= ok("Rename stays the open chat's alone", !menu_moves);
    in_main(cx, pick(a.clone(), Pick::Only));
    settle(cx, 300).await;
    pass &= ok("a plain click ends the selection", selected(cx).0.is_none());

    // Chat › Next Chat and Previous Chat, in the sidebar's order.
    let order = in_main(cx, |mw, _, cx| {
        let rows = mw.sidebar.read(cx).rows().to_vec();
        (
            crate::views::sidebar_keys::step_chat(&rows, Some(&a), true),
            crate::views::sidebar_keys::step_chat(&rows, Some(&a), false),
        )
    })
    .unwrap_or((None, None));
    let now = |cx: &mut AsyncApp| {
        cx.update(|cx| {
            let n = cx.global::<AppState>().stores.navigation.read(cx);
            n.selected_chat().map(String::from)
        })
    };
    press(main, "ctrl-tab", cx);
    settle(cx, 400).await;
    let next = now(cx);
    press(main, "ctrl-shift-tab", cx);
    settle(cx, 400).await;
    let back = now(cx);
    pass &= ok(
        &format!("⌃⇥ opens the next chat and ⌃⇧⇥ comes back ({next:?})"),
        next.is_some() && next == order.0 && back.as_deref() == Some(a.as_str()),
    );
    press(main, "ctrl-shift-tab", cx);
    settle(cx, 400).await;
    pass &= ok("⌃⇧⇥ opens the chat before", now(cx) == order.1);

    // Chat › Move to: on with a chat open, greyed out with none (AppKit
    // enables any submenu item unless told otherwise). AppKit's menu
    // validation calls back into GPUI: read the menus outside any update
    // (the App is borrowed inside one).
    #[cfg(target_os = "macos")]
    {
        let (chat_menu, move_to, next, previous) = cx.update(|cx| {
            let l = crate::l10n::ActiveL10n::l10n(cx).clone();
            (
                l.desktop_menu_chat(),
                l.desktop_menu_move_to(),
                l.desktop_menu_next_chat(),
                l.desktop_menu_previous_chat(),
            )
        });
        cx.update(crate::menus::refresh_menus);
        settle(cx, 200).await;
        let with_chat = crate::shell::macos::menu_item_enabled(&chat_menu, &move_to);
        in_main(cx, |mw, _, cx| {
            mw.stores
                .navigation
                .update(cx, |n, cx| n.new_chat(false, cx))
        });
        settle(cx, 400).await;
        cx.update(crate::menus::refresh_menus);
        settle(cx, 200).await;
        let without = crate::shell::macos::menu_item_enabled(&chat_menu, &move_to);
        pass &= ok(
            &format!("Chat › Move to is off with no chat open ({with_chat:?} → {without:?})"),
            with_chat == Some(true) && without == Some(false),
        );
        // Next and Previous Chat read ⌃⇥ and ⌃⇧⇥ (the Tab key, not T).
        let keys = (
            crate::shell::macos::menu_key_equivalent(&chat_menu, &next),
            crate::shell::macos::menu_key_equivalent(&chat_menu, &previous),
        );
        pass &= ok(
            &format!("Next and Previous Chat are on the Tab key ({keys:?})"),
            keys.0 == Some(("\t".to_string(), 1 << 18))
                && keys.1 == Some(("\t".to_string(), (1 << 18) | (1 << 17))),
        );
        in_main(cx, open(a.clone()));
        settle(cx, 300).await;
    }
    pass
}

/// The folder a name field edits, while one is open.
fn name_target(cx: &mut AsyncApp) -> Option<crate::views::sidebar::NameTarget> {
    in_main(cx, |mw, _, cx| mw.sidebar.read(cx).name_target().cloned()).flatten()
}

/// Types `name` into the open name field and presses Return.
async fn type_name(name: &str, cx: &mut AsyncApp) -> bool {
    let Some(field) = in_main(cx, |mw, _, cx| mw.sidebar.read(cx).rename_input()).flatten() else {
        return false;
    };
    let name = name.to_string();
    in_main(cx, move |mw, window, cx| {
        set_text(&field, &name, window, cx);
        mw.sidebar.update(cx, |s, cx| s.commit_rename(window, cx));
    });
    settle(cx, 150).await;
    true
}

/// Folders end to end: File › New Folder names one in place; its menu
/// offers New Subfolder, Rename… and Delete Folder… (another user's
/// folder none of those); Return on a selected folder renames it; a taken
/// name is refused and the field opens again; Delete Folder… deletes it
/// with its subfolder and keeps the chat filed there.
async fn sidebar_folders(
    main: AnyWindowHandle,
    chat_id: &str,
    dir: &Path,
    cx: &mut AsyncApp,
) -> bool {
    use crate::views::sidebar::{FolderCommand, FolderMenu, NameTarget};
    let folder_command = |id: &str, command: FolderCommand| FolderMenu {
        folder_id: id.to_string(),
        command,
    };

    // New Folder: the field opens named "New Folder", where it will be.
    in_main(cx, |_, window, cx| {
        window.dispatch_action(Box::new(crate::actions::NewFolder), cx)
    });
    settle(cx, 400).await;
    let mut pass = ok(
        "New Folder opens a name field at the top level",
        name_target(cx) == Some(NameTarget::NewFolder { parent: None }),
    );
    let suggested = in_main(cx, |mw, _, cx| {
        mw.sidebar
            .read(cx)
            .rename_input()
            .map(|i| i.read(cx).value().to_string())
    })
    .flatten();
    pass &= ok(
        &format!("it is named New Folder ({suggested:?})"),
        suggested.as_deref() == Some("New Folder"),
    );
    shoot_main(dir, "sidebar-new-folder", cx).await;
    let named = ax(main, "sidebar-new-folder", dir, cx).await;
    pass &= ok(
        "the new folder's field is labelled",
        has(&named, "TextInput", "Folder Name"),
    );
    pass &= type_name("Field notes", cx).await;
    let made = wait_until(cx, Duration::from_secs(20), |cx| {
        folder_named("Field notes", cx).is_some()
    })
    .await;
    pass &= ok("Return makes the folder", made);
    let Some(field_notes) = cx.update(|cx| folder_named("Field notes", cx)) else {
        return ok("the new folder", false);
    };

    // Its menu, and another user's.
    let menus = in_main(cx, |mw, _, cx| {
        let store = mw.stores.chat_list.read(cx);
        let list = store.list.as_ref()?;
        let own = list.folders.iter().find(|f| f.name == "Field notes")?;
        let shared = list.folders.iter().find(|f| f.shared)?;
        let labels = |f| {
            mw.sidebar
                .read(cx)
                .folder_menu_items(f, false, cx)
                .into_iter()
                .map(|i| i.map_or("—".to_string(), |(label, _)| label))
                .collect::<Vec<_>>()
        };
        Some((labels(own), labels(shared)))
    })
    .flatten()
    .unwrap_or_default();
    println!("SMOKE folder menus {menus:?}");
    pass &= ok(
        "a folder's menu offers New Chat, New Subfolder, Folder Settings…, Share Folder…, \
         Rename…, Expand, Delete Folder…",
        menus.0
            == [
                "New Chat in Folder",
                "New Subfolder",
                "—",
                "Folder Settings…",
                "Share Folder…",
                "—",
                "Rename…",
                "Expand",
                "—",
                "Delete Folder…",
            ],
    );
    pass &= ok(
        "a read-only shared folder offers no rename, delete or new subfolder",
        menus.1 == ["Expand"],
    );

    // Rename… from its menu.
    in_main(cx, {
        let action = folder_command(&field_notes, FolderCommand::Rename);
        move |_, window, cx| window.dispatch_action(Box::new(action), cx)
    });
    settle(cx, 300).await;
    pass &= ok(
        "Rename… opens the folder's name field",
        name_target(cx) == Some(NameTarget::Folder(field_notes.clone())),
    );
    if let Some(field) = in_main(cx, |mw, _, cx| mw.sidebar.read(cx).rename_input()).flatten() {
        in_main(cx, move |_, window, cx| {
            set_text(&field, "Field notes, renamed", window, cx)
        });
    }
    settle(cx, 200).await;
    shoot_main(dir, "sidebar-folder-rename", cx).await;
    pass &= type_name("Field notes, renamed", cx).await;
    let fid = field_notes.clone();
    let renamed = wait_until(cx, Duration::from_secs(20), move |cx| {
        let store = cx.global::<AppState>().stores.chat_list.read(cx);
        store
            .folder(&fid)
            .is_some_and(|f| f.name == "Field notes, renamed")
    })
    .await;
    pass &= ok("the folder's new name reached the server", renamed);

    // A name another folder beside it has: refused, and the field again.
    in_main(cx, {
        let action = folder_command(&field_notes, FolderCommand::Rename);
        move |_, window, cx| window.dispatch_action(Box::new(action), cx)
    });
    settle(cx, 300).await;
    pass &= type_name("garden", cx).await;
    settle(cx, 600).await;
    pass &= ok(
        "a taken name opens the field again",
        name_target(cx) == Some(NameTarget::Folder(field_notes.clone())),
    );
    in_main(cx, |mw, window, cx| {
        mw.sidebar.update(cx, |s, cx| s.cancel_rename(window, cx))
    });
    let fid = field_notes.clone();
    let kept = cx.update(move |cx| {
        let store = cx.global::<AppState>().stores.chat_list.read(cx);
        store.folder(&fid).map(|f| f.name.clone())
    });
    pass &= ok(
        "Esc leaves the name as it was",
        kept.as_deref() == Some("Field notes, renamed"),
    );

    // Return on the selected folder renames it (the keyboard path).
    in_main(cx, |mw, window, cx| {
        mw.sidebar.update(cx, |s, cx| s.focus_list(window, cx))
    });
    settle(cx, 200).await;
    let target = crate::views::sidebar_keys::KeyRow::Folder(field_notes.clone());
    for _ in 0..80 {
        let at = in_main(cx, |mw, _, cx| mw.sidebar.read(cx).cursor().cloned()).flatten();
        if at.as_ref() == Some(&target) {
            break;
        }
        press(main, "down", cx);
        settle(cx, 30).await;
    }
    press(main, "enter", cx);
    settle(cx, 300).await;
    pass &= ok(
        "Return on a selected folder edits its name",
        name_target(cx) == Some(NameTarget::Folder(field_notes.clone())),
    );
    press(main, "escape", cx);
    settle(cx, 200).await;

    // New Subfolder, and a chat filed in it.
    in_main(cx, {
        let action = folder_command(&field_notes, FolderCommand::NewSubfolder);
        move |_, window, cx| window.dispatch_action(Box::new(action), cx)
    });
    settle(cx, 400).await;
    pass &= ok(
        "New Subfolder opens a field inside the folder",
        name_target(cx)
            == Some(NameTarget::NewFolder {
                parent: Some(field_notes.clone()),
            }),
    );
    pass &= type_name("Tide tables", cx).await;
    let fid = field_notes.clone();
    let nested = wait_until(cx, Duration::from_secs(20), move |cx| {
        let store = cx.global::<AppState>().stores.chat_list.read(cx);
        store.list.as_ref().is_some_and(|l| {
            l.folders
                .iter()
                .any(|f| f.name == "Tide tables" && f.parent_id.as_deref() == Some(fid.as_str()))
        })
    })
    .await;
    pass &= ok("the subfolder is made inside it", nested);
    let Some(tides) = cx.update(|cx| folder_named("Tide tables", cx)) else {
        return ok("the subfolder", false);
    };
    chat_command(chat_id, ChatCommand::MoveTo(tides.clone()), cx).await;
    let t = tides.clone();
    pass &= wait_chat(
        chat_id,
        "a chat filed in the subfolder",
        Duration::from_secs(20),
        move |c| c.is_some_and(|c| c.folder_id.as_deref() == Some(t.as_str())),
        cx,
    )
    .await;
    settle(cx, 500).await;
    shoot_main(dir, "sidebar-folder-nested", cx).await;

    // An icon chosen on the web (any Open WebUI shortcode, here `fire`):
    // drawn in the sidebar, and offered as the folder's current choice.
    let rpc = cx.update(|cx| cx.global::<AppState>().connection.read(cx).rpc());
    let set = rpc
        .call::<conduit_protocol::methods::FoldersUpdate>(&conduit_protocol::FolderUpdate {
            id: field_notes.clone(),
            name: None,
            icon: Some("fire".into()),
            system_prompt: None,
            model_ids: None,
            knowledge: None,
        })
        .await;
    let f = field_notes.clone();
    let drawn = set.is_ok()
        && wait_until(cx, Duration::from_secs(20), move |cx| {
            cx.global::<AppState>()
                .stores
                .chat_list
                .read(cx)
                .folder(&f)
                .is_some_and(|f| f.icon.as_deref() == Some("\u{1F525}\u{FE0F}"))
        })
        .await;
    pass &= ok(
        "a folder icon chosen on the web shows in the sidebar",
        drawn,
    );
    let offered = rpc
        .call::<conduit_protocol::methods::FoldersGet>(&conduit_protocol::FolderRef {
            folder_id: field_notes.clone(),
        })
        .await;
    pass &= ok(
        "and is offered first, selected, among the icon choices",
        offered.as_ref().is_ok_and(|f| {
            f.icon.as_deref() == Some("fire")
                && f.icon_choices.first().is_some_and(|c| c.alias == "fire")
        }),
    );
    settle(cx, 400).await;
    shoot_main(dir, "sidebar-folder-web-icon", cx).await;

    // Delete Folder… (the sheet is answered "Delete" in the E2E): both
    // folders go, the chat stays, out of any folder.
    in_main(cx, {
        let action = folder_command(&field_notes, FolderCommand::Delete);
        move |_, window, cx| window.dispatch_action(Box::new(action), cx)
    });
    let (f1, f2) = (field_notes.clone(), tides.clone());
    let gone = wait_until(cx, Duration::from_secs(20), move |cx| {
        let store = cx.global::<AppState>().stores.chat_list.read(cx);
        store.folder(&f1).is_none() && store.folder(&f2).is_none()
    })
    .await;
    pass &= ok("Delete Folder… deletes it and its subfolder", gone);
    pass &= wait_chat(
        chat_id,
        "the chat in it is kept, out of any folder",
        Duration::from_secs(20),
        |c| c.is_some_and(|c| c.folder_id.is_none()),
        cx,
    )
    .await;
    pass
}

async fn sidebar(inputs: &E2eInputs, dir: &Path, cx: &mut AsyncApp) -> bool {
    let Some((url, email, password)) = inputs.owui() else {
        return ok(NO_SERVER, false);
    };
    // A new profile starts on onboarding; anything else is cleared first.
    let routed = wait_until(cx, Duration::from_secs(90), |cx| {
        current_route(cx) != Route::Unknown
    })
    .await;
    let mut pass = ok("routed", routed);
    if cx.update(current_route) != Route::Onboarding {
        pass &= fresh_profile(cx).await;
    }
    pass &= ok("the setup window opened", wait_setup(cx).await.is_some());
    in_setup(cx, |sw, window, cx| {
        sw.onboarding.update(cx, |o, cx| o.choose(window, cx))
    });
    settle(cx, 500).await;
    connect_server(&url, "Lab server", cx).await;
    pass &= wait_route(cx, Route::SignIn, Duration::from_secs(60)).await;
    sign_in_password(&email, &password, cx).await;
    pass &= wait_route(cx, Route::Main, Duration::from_secs(60)).await;
    let Some(main) = wait_main(cx).await else {
        return ok("main window", false);
    };

    // The list fills from the first sync: 36 chats (4 are archived).
    let loaded = wait_until(cx, Duration::from_secs(120), |cx| {
        let s = cx.global::<AppState>().stores.chat_list.read(cx);
        s.list.as_ref().is_some_and(|l| l.chats.len() >= 36)
            && s.sync
                .as_ref()
                .is_some_and(|s| s.ever_completed && !s.running)
    })
    .await;
    let counts = cx.update(|cx| {
        let s = cx.global::<AppState>().stores.chat_list.read(cx);
        s.list
            .as_ref()
            .map(|l| (l.chats.len(), l.folders.len(), l.archived_count))
    });
    pass &= ok(&format!("the list loaded ({counts:?})"), loaded);
    // The account's four folders, and the second user's shared with it.
    let own = cx.update(|cx| {
        let s = cx.global::<AppState>().stores.chat_list.read(cx);
        s.list
            .as_ref()
            .map(|l| l.folders.iter().filter(|f| !f.shared).count())
    });
    pass &= ok(
        &format!("four folders of its own, one shared, four archived ({own:?})"),
        own == Some(4) && counts.is_some_and(|(_, f, a)| f == 5 && a == 4),
    );
    let garden_open = cx.update(|cx| {
        let s = cx.global::<AppState>().stores.chat_list.clone();
        let id = folder_named("Garden", cx);
        id.is_some_and(|id| s.read(cx).is_expanded(&id))
    });
    pass &= ok("Garden opens as the account left it", garden_open);
    settle(cx, 1500).await;
    shoot_main(dir, "sidebar", cx).await;
    let controls = ax(main, "sidebar", dir, cx).await;
    pass &= ok(
        "the sidebar's rows, folders and controls are labelled",
        has(&controls, "TreeItem", "Garden")
            && has(&controls, "TreeItem", "Sourdough starter schedule")
            && has(&controls, "TextInput", "Search chats")
            && has(&controls, "Button", "New Chat"),
    );

    // Open: the row highlights and the navigation follows.
    let Some(open) = cx.update(|cx| chat_titled("Orbital period of a moon", cx)) else {
        return ok("a chat to open", false);
    };
    let id = open.id.clone();
    in_main(cx, move |mw, _, cx| {
        mw.sidebar.update(cx, |s, cx| s.open(&id, cx))
    });
    let selected = cx.update(|cx| {
        let n = cx.global::<AppState>().stores.navigation.read(cx);
        n.selected_chat().map(String::from)
    });
    pass &= ok(
        "a click opens the chat",
        selected.as_deref() == Some(open.id.as_str()),
    );
    settle(cx, 400).await;
    shoot_main(dir, "sidebar-open", cx).await;

    // Hover shows "…" alone (the commands are in its menu), naming the chat.
    let id = open.id.clone();
    in_main(cx, move |mw, _, cx| {
        mw.sidebar.update(cx, |s, cx| s.hover(Some(&id), cx))
    });
    settle(cx, 300).await;
    shoot_main(dir, "sidebar-hover", cx).await;
    let hovered = ax(main, "sidebar-hover", dir, cx).await;
    pass &= ok(
        "the hover action names the chat, and is the only one",
        has(&hovered, "Button", "More Actions for \u{201c}Orbital")
            && !has(&hovered, "Button", "Rename \u{201c}Orbital")
            && !has(&hovered, "Button", "Delete \u{201c}Orbital"),
    );
    in_main(cx, |mw, _, cx| {
        mw.sidebar.update(cx, |s, cx| s.hover(None, cx))
    });

    // Rename in place.
    let Some(target) = cx.update(|cx| chat_titled("Regex for ISO dates", cx)) else {
        return ok("a chat to rename", false);
    };
    chat_command(&target.id, ChatCommand::Rename, cx).await;
    settle(cx, 300).await;
    let field = in_main(cx, |mw, _, cx| mw.sidebar.read(cx).rename_input()).flatten();
    pass &= ok("Rename opens the field", field.is_some());
    if let Some(field) = field {
        in_main(cx, move |_, window, cx| {
            set_text(&field, "ISO date regex, renamed", window, cx)
        });
        settle(cx, 200).await;
        shoot_main(dir, "sidebar-rename", cx).await;
        in_main(cx, |mw, window, cx| {
            mw.sidebar.update(cx, |s, cx| s.commit_rename(window, cx))
        });
    }
    pass &= wait_chat(
        &target.id,
        "the rename reached the server",
        Duration::from_secs(20),
        |c| c.is_some_and(|c| c.title == "ISO date regex, renamed"),
        cx,
    )
    .await;

    // Pin.
    let Some(pin) = cx.update(|cx| chat_titled("Quilt pattern maths", cx)) else {
        return ok("a chat to pin", false);
    };
    chat_command(&pin.id, ChatCommand::Pin, cx).await;
    pass &= wait_chat(
        &pin.id,
        "Pin moves it to Pinned",
        Duration::from_secs(20),
        |c| c.is_some_and(|c| c.pinned),
        cx,
    )
    .await;

    // Move to a folder from the menu, and by dragging onto one.
    let (Some(garden), Some(side)) =
        cx.update(|cx| (folder_named("Garden", cx), folder_named("Side project", cx)))
    else {
        return ok("the folders", false);
    };
    let Some(tomato) = cx.update(|cx| chat_titled("Tomato companion plants", cx)) else {
        return ok("a chat to file", false);
    };
    chat_command(&tomato.id, ChatCommand::MoveTo(garden.clone()), cx).await;
    let g = garden.clone();
    pass &= wait_chat(
        &tomato.id,
        "Move to folder files it",
        Duration::from_secs(20),
        move |c| c.is_some_and(|c| c.folder_id.as_deref() == Some(g.as_str())),
        cx,
    )
    .await;
    let Some(bike) = cx.update(|cx| chat_titled("Bike fit notes", cx)) else {
        return ok("a chat to drag", false);
    };
    let dragged = DraggedChat {
        chat_id: bike.id.clone(),
        title: bike.title.clone().into(),
        folder_id: bike.folder_id.clone(),
        chat_ids: vec![bike.id.clone()],
        grab: Default::default(),
    };
    let target_folder = side.clone();
    in_main(cx, move |mw, _, cx| {
        mw.sidebar
            .update(cx, |s, cx| s.drop_on(Some(target_folder), &dragged, cx))
    });
    let s2 = side.clone();
    pass &= wait_chat(
        &bike.id,
        "dropping a row on a folder files it",
        Duration::from_secs(20),
        move |c| c.is_some_and(|c| c.folder_id.as_deref() == Some(s2.as_str())),
        cx,
    )
    .await;
    // A filed chat's menu offers the folder items.
    let items = in_main(cx, |mw, _, cx| {
        let chat = mw.stores.chat_list.read(cx).find(&tomato.id).cloned()?;
        Some(
            mw.sidebar
                .read(cx)
                .menu_items(&chat, cx)
                .into_iter()
                .map(|(label, _)| label)
                .collect::<Vec<_>>(),
        )
    })
    .flatten()
    .unwrap_or_default();
    println!("SMOKE menu {items:?}");
    pass &= ok(
        "the context menu offers pin, rename, share, remove from folder, archive, select, delete",
        [
            "Pin",
            "Rename…",
            "Share Chat…",
            "Remove from Folder",
            "Archive",
            "Select Chats…",
            "Delete…",
        ]
        .iter()
        .all(|w| items.iter().any(|i| i == w)),
    );
    chat_command(&tomato.id, ChatCommand::RemoveFromFolder, cx).await;
    pass &= wait_chat(
        &tomato.id,
        "Remove from folder takes it out",
        Duration::from_secs(20),
        |c| c.is_some_and(|c| c.folder_id.is_none()),
        cx,
    )
    .await;

    pass &= sidebar_folders(main, &tomato.id, dir, cx).await;

    // Archive, then show the archived section.
    let Some(jazz) = cx.update(|cx| chat_titled("Jazz chord voicings", cx)) else {
        return ok("a chat to archive", false);
    };
    chat_command(&jazz.id, ChatCommand::Archive, cx).await;
    pass &= wait_chat(
        &jazz.id,
        "Archive takes it out of the list",
        Duration::from_secs(20),
        |c| c.is_none_or(|c| c.archived),
        cx,
    )
    .await;
    settle(cx, 600).await;
    shoot_main(dir, "sidebar-after-edits", cx).await;
    cx.update(|cx| {
        let s = cx.global::<AppState>().stores.chat_list.clone();
        s.update(cx, |c, cx| c.set_archived_visible(true, cx))
            .detach();
    });
    let shown = wait_until(cx, Duration::from_secs(20), |cx| {
        let s = cx.global::<AppState>().stores.chat_list.read(cx);
        s.list
            .as_ref()
            .is_some_and(|l| l.archived_visible && l.chats.iter().any(|c| c.archived))
    })
    .await;
    pass &= ok("the archived section lists archived chats", shown);
    settle(cx, 600).await;
    // The section is at the end of the list.
    in_main(cx, |mw, _, cx| {
        mw.sidebar.read(cx).scroll_handle().scroll_to_bottom();
        mw.sidebar.update(cx, |_, cx| cx.notify());
    });
    settle(cx, 400).await;
    shoot_main(dir, "sidebar-archived", cx).await;
    cx.update(|cx| {
        let s = cx.global::<AppState>().stores.chat_list.clone();
        s.update(cx, |c, cx| c.set_archived_visible(false, cx))
            .detach();
    });

    // Delete (the sheet is answered "Delete" in the E2E).
    let Some(gone) = cx.update(|cx| chat_titled("Trip budget for a city break", cx)) else {
        return ok("a chat to delete", false);
    };
    chat_command(&gone.id, ChatCommand::Delete, cx).await;
    pass &= wait_chat(
        &gone.id,
        "Delete removes it",
        Duration::from_secs(20),
        |c| c.is_none(),
        cx,
    )
    .await;

    // Selection mode: archive two at once.
    let picks = cx.update(|cx| {
        ["Why tides lag the moon", "Migration plan"]
            .iter()
            .filter_map(|t| chat_titled(t, cx).map(|c| c.id))
            .collect::<Vec<_>>()
    });
    for id in picks.clone() {
        in_main(cx, move |mw, _, cx| {
            mw.sidebar.update(cx, |s, cx| s.toggle_selected(&id, cx))
        });
    }
    settle(cx, 400).await;
    shoot_main(dir, "sidebar-select", cx).await;
    in_main(cx, |mw, window, cx| {
        mw.sidebar.update(cx, |s, cx| {
            s.bulk(conduit_protocol::BulkChatAction::Archive, None, window, cx)
        })
    });
    for id in picks {
        pass &= wait_chat(
            &id,
            "bulk Archive archives each",
            Duration::from_secs(20),
            |c| c.is_none_or(|c| c.archived),
            cx,
        )
        .await;
    }

    pass &= multiple_selection(main, dir, cx).await;

    // Search replaces the list with hits.
    let search = in_main(cx, |mw, _, cx| mw.sidebar.read(cx).search.clone());
    if let Some(search) = search {
        in_main(cx, move |mw, window, cx| {
            set_text(&search, "espresso", window, cx);
            mw.stores
                .chat_list
                .update(cx, |c, cx| c.set_query("espresso", cx));
        });
    }
    let found = wait_until(cx, Duration::from_secs(20), |cx| {
        let s = cx.global::<AppState>().stores.chat_list.read(cx);
        s.searched() == "espresso" && s.results.as_ref().is_some_and(|r| !r.hits.is_empty())
    })
    .await;
    pass &= ok("sidebar search finds espresso", found);
    settle(cx, 500).await;
    shoot_main(dir, "sidebar-search", cx).await;
    // A query shows the field's ⓧ in place of the ⌥⌘F hint; Esc clears
    // the field, then leaves it (NSSearchField's).
    let search_ax = ax(main, "sidebar-search", dir, cx).await;
    pass &= ok(
        "a query shows the search field's clear button",
        has(&search_ax, "Button", "Clear Search"),
    );
    in_main(cx, |mw, window, cx| {
        mw.sidebar.update(cx, |s, cx| {
            s.focus_search(window, cx);
            s.escape_search(window, cx)
        })
    });
    settle(cx, 400).await;
    let cleared = cx.update(|cx| {
        cx.global::<AppState>()
            .stores
            .chat_list
            .read(cx)
            .searched()
            .is_empty()
    });
    let still_in = in_main(cx, |mw, window, cx| {
        let field = mw.sidebar.read(cx).search.clone();
        gpui_kit::Focusable::focus_handle(field.read(cx), cx).is_focused(window)
    })
    .unwrap_or(false);
    pass &= ok(
        "Esc clears the search field and stays in it",
        cleared && still_in,
    );
    let empty_ax = ax(main, "sidebar-search-cleared", dir, cx).await;
    pass &= ok(
        "the clear button goes with the query",
        !has(&empty_ax, "Button", "Clear Search"),
    );
    in_main(cx, |mw, window, cx| {
        mw.sidebar.update(cx, |s, cx| s.escape_search(window, cx))
    });
    settle(cx, 400).await;
    let left = in_main(cx, |mw, window, cx| {
        let field = mw.sidebar.read(cx).search.clone();
        !gpui_kit::Focusable::focus_handle(field.read(cx), cx).is_focused(window)
    })
    .unwrap_or(false);
    pass &= ok("a second Esc leaves the empty field", left);

    // ⌘K: recent chats and commands, then a search, then open a hit.
    in_main(cx, |_, window, cx| {
        window.dispatch_action(Box::new(crate::actions::OpenPalette), cx)
    });
    settle(cx, 600).await;
    let open = in_main(cx, |mw, _, cx| mw.palette.read(cx).is_open(cx)).unwrap_or(false);
    pass &= ok("⌘K opens the palette", open);
    shoot_main(dir, "palette-recent", cx).await;
    let palette_ax = ax(main, "palette", dir, cx).await;
    pass &= ok(
        "the palette's field and options are labelled",
        has(&palette_ax, "TextInput", "Search chats and commands")
            && has(&palette_ax, "ListBoxOption", "New Temporary Chat"),
    );
    in_main(cx, |mw, window, cx| {
        mw.palette
            .update(cx, |p, cx| p.type_query("tides moon", window, cx))
    });
    let hits = wait_until(cx, Duration::from_secs(20), |cx| {
        let p = cx.global::<AppState>().stores.palette.read(cx);
        p.searched() == "tides moon"
    })
    .await;
    pass &= ok("the palette searches", hits);
    settle(cx, 500).await;
    shoot_main(dir, "palette-search", cx).await;
    in_main(cx, |mw, window, cx| {
        mw.palette
            .update(cx, |p, cx| p.type_query("sourdough", window, cx))
    });
    let _ = wait_until(cx, Duration::from_secs(20), |cx| {
        let p = cx.global::<AppState>().stores.palette.read(cx);
        p.searched() == "sourdough" && p.results.as_ref().is_some_and(|r| !r.hits.is_empty())
    })
    .await;
    settle(cx, 300).await;
    let first_hit = in_main(cx, |mw, _, cx| {
        mw.palette.read(cx).entries().first().and_then(|e| match e {
            crate::stores::palette::PaletteEntry::Chat { chat_id, .. } => Some(chat_id.clone()),
            _ => None,
        })
    })
    .flatten();
    in_main(cx, |mw, window, cx| {
        mw.palette.update(cx, |p, cx| p.choose(0, window, cx))
    });
    settle(cx, 300).await;
    let opened = cx.update(|cx| {
        let n = cx.global::<AppState>().stores.navigation.read(cx);
        n.selected_chat().map(String::from)
    });
    pass &= ok(
        "choosing a hit opens it and closes the palette",
        first_hit.is_some()
            && opened == first_hit
            && !in_main(cx, |mw, _, cx| mw.palette.read(cx).is_open(cx)).unwrap_or(true),
    );

    // New Chat (⌘N's action).
    in_main(cx, |_, window, cx| {
        window.dispatch_action(Box::new(crate::actions::NewChat), cx)
    });
    settle(cx, 300).await;
    let fresh = cx.update(|cx| {
        cx.global::<AppState>()
            .stores
            .navigation
            .read(cx)
            .selection()
            .clone()
    });
    pass &= ok(
        "New Chat selects a new chat",
        fresh == crate::stores::navigation::Selection::New { temporary: false },
    );

    // Comfortable density: taller rows.
    cx.update(|cx| {
        let s = cx.global::<AppState>().settings.clone();
        s.update(cx, |s, cx| {
            s.set_appearance(|a| a.density = crate::prefs::DensityChoice::Comfortable, cx)
        });
    });
    settle(cx, 500).await;
    shoot_main(dir, "sidebar-comfortable", cx).await;
    cx.update(|cx| {
        let s = cx.global::<AppState>().settings.clone();
        s.update(cx, |s, cx| {
            s.set_appearance(|a| a.density = crate::prefs::DensityChoice::Compact, cx)
        });
    });
    pass
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn passes_sign_in_only_on_this_macs_own_server() {
        assert!(is_local_url("http://127.0.0.1:19860"));
        assert!(is_local_url("http://localhost:8150/"));
        assert!(is_local_url("http://[::1]:8080"));
        assert!(!is_local_url("https://chat.example.org"));
        assert!(!is_local_url("http://10.0.0.5:8080"));
        assert!(!is_local_url("http://localhost.example.org"));
        assert!(!is_local_url("file:///tmp/x"));
        // An env file naming another machine is not used, for any kind of
        // server, whatever its name.
        for key in [
            "OWUI_URL",
            "OWUI_PROXY_URL",
            "LIBRECHAT_URL",
            "HERMES_GATEWAY_URL",
            "HERMES_DESKTOP_URL",
            "HERMES_A_URL",
            "HERMES_A_PROXY_URL",
            "HERMES_B_URL",
            "FAKE_HERMES_URL",
            "GPT_LIVE_URL",
            "SOME_NEW_SERVER_URL",
        ] {
            let file = std::env::temp_dir()
                .join(format!("conduit-e2e-env-{key}-{}.env", std::process::id()));
            std::fs::write(&file, format!("{key}=https://chat.example.org\nX=1\n")).unwrap();
            let args: Vec<String> = ["app", "--e2e", "smoke", "--e2e-env"]
                .into_iter()
                .map(String::from)
                .chain([file.display().to_string()])
                .collect();
            let inputs = E2eInputs::from_args(&args).unwrap();
            assert_eq!(inputs.get(key), None, "{key} names another machine");
            assert_eq!(
                inputs.get("X"),
                None,
                "{key}: the rest of the file is still used"
            );
        }
    }

    #[test]
    fn local_addresses_and_non_addresses_keep_the_env_file() {
        for (key, value) in [
            ("OWUI_URL", "http://127.0.0.1:20500"),
            ("GPT_LIVE_URL", "ws://localhost:20501/live"),
            ("DATABASE_URL", "sqlite:///tmp/webui.db"),
            ("HERMES_A_HOME", "https://chat.example.org"),
        ] {
            assert!(!names_another_machine(key, value), "{key}={value}");
        }
        assert!(names_another_machine("OWUI_URL", "ws://chat.example.org"));
        // A bare host is read as the server form reads it (a scheme first).
        assert!(names_another_machine("OWUI_URL", "chat.example.org"));
        assert!(names_another_machine(
            "HERMES_A_PROXY_URL",
            "chat.example.org:8443/x"
        ));
        assert!(!names_another_machine(
            "HERMES_A_PROXY_URL",
            "127.0.0.1:20501"
        ));
        assert!(!names_another_machine("OWUI_URL", "localhost:20500"));
        assert!(names_another_machine("OWUI_URL", "ftp://127.0.0.1/x"));
    }

    #[test]
    fn env_files_parse_like_a_shell() {
        let env = parse_env("# c\nA=1\nexport B=\"two\"\nC='3'\n\nbad line\nD=a=b\n");
        assert_eq!(env.get("A").map(String::as_str), Some("1"));
        assert_eq!(env.get("B").map(String::as_str), Some("two"));
        assert_eq!(env.get("C").map(String::as_str), Some("3"));
        assert_eq!(env.get("D").map(String::as_str), Some("a=b"));
        assert_eq!(env.len(), 4);
    }

    #[test]
    fn the_env_file_defaults_to_where_owui_sh_writes_it() {
        let vars = |pairs: &'static [(&'static str, &'static str)]| {
            move |k: &str| {
                pairs
                    .iter()
                    .find(|(key, _)| *key == k)
                    .map(|(_, v)| v.to_string())
            }
        };
        let path = |p: Option<PathBuf>| p.map(|p| p.to_string_lossy().into_owned());
        assert_eq!(
            path(default_env_path(vars(&[("HOME", "/Users/avery")]))).as_deref(),
            Some("/Users/avery/Library/Caches/conduit-dev/local-owui/local-owui.env")
        );
        assert_eq!(
            path(default_env_path(vars(&[
                ("HOME", "/Users/avery"),
                ("CONDUIT_DEV_CACHE", "/tmp/cache")
            ])))
            .as_deref(),
            Some("/tmp/cache/local-owui/local-owui.env")
        );
        assert_eq!(
            path(default_env_path(vars(&[
                ("CONDUIT_OWUI_DIR", "/tmp/owui"),
                ("CONDUIT_DEV_CACHE", "/tmp/cache")
            ])))
            .as_deref(),
            Some("/tmp/owui/local-owui.env")
        );
        assert_eq!(
            path(default_env_path(vars(&[
                ("CONDUIT_OWUI_ENV", "/tmp/x.env"),
                ("CONDUIT_OWUI_DIR", "/tmp/owui")
            ])))
            .as_deref(),
            Some("/tmp/x.env")
        );
        assert_eq!(default_env_path(vars(&[])), None);
    }
}
