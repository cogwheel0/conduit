//! The Computer viewer: a chat terminal's Desktop or Browser, live, in a
//! window of its own, as mobile's full-screen Computer page.
//!
//! The page is mobile's own viewer (`assets/computer/viewer.js`, noVNC and
//! the frame transport), loaded with mobile's origin (`http://127.0.0.1`)
//! into a WKWebView, and it streams through the daemon's relay
//! (`computer.open`), which holds every credential: the viewer is given no
//! token, and the relay puts the account's into its auth message.
//!
//! While the chat's response runs, the agent drives and the screen is
//! watch-only; Take Control stops the response (`turns.stop`), and control
//! follows once it has ended (mobile's rule). The mouse and the keyboard go
//! straight to the page; the toolbar has Back, Forward, Reload, the address
//! and the tabs for the Browser, and Paste, a key combination, Zoom, Sound,
//! Desktop Site and Lower Data Use in its More menu.

use std::rc::Rc;

use conduit_components::ActiveConduitTheme as _;
use conduit_components::assets::IconName;
use conduit_components::views::kit::{Button, IconButton, Segment, Segmented, bare_input};
use conduit_components::window::{
    TOOLBAR_HEIGHT, TRAFFIC_LIGHTS_WIDTH, drag_region, open_window_clear_root,
};
use conduit_protocol::{
    ComputerHandleRef, ComputerOpen, ComputerScope, ComputerShortcut, ComputerStatus,
    ComputerSurfaceKind, ComputerTab, ComputerTabRef, ComputerView, ComputerViewState, Event,
    StopTurn, events, methods,
};
use futures::StreamExt as _;
use futures::channel::mpsc;
use gpui_kit::component::input::{InputEvent, InputState};
use gpui_kit::component::native_menu::NativeMenu;
use gpui_kit::prelude::*;
use gpui_kit::{
    Action, AnyWindowHandle, App, Bounds, ClickEvent, Context, Entity, Focusable as _, FontWeight,
    Global, Role, SharedString, Subscription, Task, Window, WindowBounds, div, px, size,
};
use gpui_webview::WebView;
use serde_json::{Value, json};

use crate::l10n::ActiveL10n as _;
use crate::stores::Stores;
use crate::stores::connection::ConnectionEvent;

/// Mobile's viewer script, bundled.
const VIEWER_JS: &str = include_str!("../../../../../../assets/computer/viewer.js");

/// Where the page claims to come from: mobile's origin, which the core's
/// relay checks on every socket.
pub const ORIGIN: &str = "http://127.0.0.1";

/// The page around the viewer, as mobile builds it; the viewer reports to
/// the window through wry's IPC where mobile's goes through its WebView
/// plugin.
pub fn document() -> String {
    format!(
        r#"<!doctype html><html><head>
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src blob: data:; media-src blob:; connect-src ws://127.0.0.1:* data:; base-uri 'none'; form-action 'none'">
<style>
html,body{{margin:0;width:100%;height:100%;background:transparent;overflow:auto;overscroll-behavior:none;-webkit-user-select:none;user-select:none}}
#surface{{width:100%;height:100%;display:flex;align-items:center;justify-content:center;overflow:auto}}
#surface.zoomed{{align-items:flex-start;justify-content:flex-start}}
#frame{{display:block;max-width:100%;max-height:100%;object-fit:contain;flex-shrink:0}}
#frame.zoomed{{max-width:none;max-height:none;width:200%;align-self:flex-start}}
</style></head><body><div id="surface"><canvas id="frame" width="1" height="1"></canvas></div>
<script>
window.flutter_inappwebview = {{ callHandler: (name, message) => {{ if (name === "computer") window.ipc.postMessage(JSON.stringify(message)); }} }};
(async () => {{{}}})();</script></body></html>"#,
        VIEWER_JS.replace("</script", "<\\/script")
    )
}

/// What a viewer message says.
#[derive(Clone, Debug, PartialEq)]
pub enum ViewerNote {
    /// connecting, live, reconnecting, unavailable, watching.
    Status(String),
    State {
        title: String,
        url: String,
        back: bool,
        forward: bool,
    },
    Audio {
        available: Option<bool>,
        enabled: bool,
        failed: bool,
    },
    /// The trackpad's drag (mobile only): not a change of connection.
    Pointer,
}

/// Reads a message the viewer posted.
pub fn viewer_note(message: &str) -> Option<ViewerNote> {
    let value: Value = serde_json::from_str(message).ok()?;
    let status = value.get("status")?.as_str()?;
    let text = |k: &str| {
        value
            .get(k)
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string()
    };
    let flag = |k: &str| value.get(k).and_then(Value::as_bool) == Some(true);
    Some(match status {
        "state" => ViewerNote::State {
            title: text("title"),
            url: text("url"),
            back: flag("canGoBack"),
            forward: flag("canGoForward"),
        },
        "audio" => ViewerNote::Audio {
            available: value.get("available").and_then(Value::as_bool),
            enabled: flag("enabled"),
            failed: flag("failed"),
        },
        "pointer" => ViewerNote::Pointer,
        other => ViewerNote::Status(other.to_string()),
    })
}

/// What the address field must be set to so it shows `url`, the page's
/// address now, given `shown`, what the field holds: nothing while it is
/// being edited (`editing`), or while it already shows `url`. An edit left
/// without navigating is put back.
fn address_sync<'a>(shown: &str, url: &'a str, editing: bool) -> Option<&'a str> {
    (!editing && shown != url).then_some(url)
}

/// What typed text in the address field opens: mobile's rule, a bare host
/// (or host and port) is an https address.
pub fn address_url(typed: &str) -> String {
    let address = typed.trim();
    let lower = address.to_ascii_lowercase();
    let has_scheme = address.split_once("://").is_some_and(|(s, _)| {
        !s.is_empty()
            && s.chars()
                .all(|c| c.is_ascii_alphanumeric() || "+.-".contains(c))
    }) || ["about:", "data:", "blob:", "view-source:", "mailto:"]
        .iter()
        .any(|p| lower.starts_with(p));
    if has_scheme {
        address.to_string()
    } else {
        format!("https://{address}")
    }
}

/// A More menu command.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MoreCommand {
    Paste,
    Shortcut,
    Zoom,
    Sound,
    DesktopSite,
    LowerDataUse,
    Reconnect,
}

#[derive(Clone, Debug, PartialEq, Action)]
#[action(namespace = conduit_computer, no_json)]
pub struct ComputerMore(pub MoreCommand);

/// A Tabs menu command.
#[derive(Clone, Debug, PartialEq, Action)]
#[action(namespace = conduit_computer, no_json)]
pub enum ComputerTabsMenu {
    Select(String),
    New,
    Close(String),
    Refresh,
}

/// Where the view stands, as the toolbar says it.
#[derive(Clone, Debug, PartialEq)]
pub enum Phase {
    Connecting,
    Live,
    Reconnecting,
    Empty,
    Inactive,
    BrowserUnavailable,
    Unavailable,
}

/// The Computer window open now (one at a time, as mobile's page).
#[derive(Default)]
/// Weak: a closed window's viewer (and its stream) must go with it.
pub struct OpenComputer(
    pub  Option<(
        String,
        AnyWindowHandle,
        gpui_kit::WeakEntity<ComputerWindow>,
    )>,
);

impl Global for OpenComputer {}

pub struct ComputerWindow {
    stores: Stores,
    chat_id: String,
    status: ComputerStatus,
    surface: ComputerSurfaceKind,
    view: Option<ComputerView>,
    phase: Phase,
    /// The chat's response runs: the agent drives.
    working: bool,
    stopping: bool,
    controlling: bool,
    zoomed: bool,
    audio_available: bool,
    audio_on: bool,
    desktop_site: bool,
    lower_data: bool,
    url: String,
    title: String,
    can_back: bool,
    can_forward: bool,
    tabs: Vec<ComputerTab>,
    webview: Entity<WebView>,
    /// The page has loaded: the viewer can start.
    loaded: bool,
    address: Entity<InputState>,
    shortcut: Entity<InputState>,
    shortcut_open: bool,
    /// Bumped by every open: late answers to older ones are dropped.
    generation: u64,
    _tasks: Vec<Task<()>>,
    _subscriptions: Vec<Subscription>,
}

impl ComputerWindow {
    pub fn phase(&self) -> &Phase {
        &self.phase
    }

    pub fn surface(&self) -> ComputerSurfaceKind {
        self.surface
    }

    pub fn controlling(&self) -> bool {
        self.controlling
    }

    pub fn working(&self) -> bool {
        self.working
    }

    fn rpc(&self, cx: &App) -> crate::stores::rpc::Rpc {
        self.stores.connection.read(cx).rpc()
    }

    fn eval(&self, js: &str, cx: &App) {
        if let Err(e) = self.webview.read(cx).raw().evaluate_script(js) {
            log::warn!("computer viewer: {e}");
        }
    }

    /// Opens the selected surface (or, for the Browser, `tab` / a new
    /// tab), closing the view before it.
    fn open_surface(&mut self, tab: Option<String>, new_tab: bool, cx: &mut Context<Self>) {
        self.generation += 1;
        let generation = self.generation;
        self.close_view(cx);
        self.phase = Phase::Connecting;
        self.controlling = false;
        self.zoomed = false;
        self.url.clear();
        self.title.clear();
        self.can_back = false;
        self.can_forward = false;
        self.audio_available = false;
        self.audio_on = false;
        cx.notify();
        let call = self.rpc(cx).call::<methods::ComputerOpen>(&ComputerOpen {
            chat_id: self.chat_id.clone(),
            surface: self.surface,
            tab_id: tab,
            new_tab,
        });
        self._tasks.push(cx.spawn(async move |this, cx| {
            let result = call.await;
            this.update(cx, |w, cx| {
                if w.generation != generation {
                    return;
                }
                match result {
                    Ok(view) => w.adopt(view, cx),
                    Err(e) => {
                        log::warn!("computer.open: {e}");
                        w.phase = Phase::Unavailable;
                        cx.notify();
                    }
                }
            })
            .ok();
        }));
        if self.surface == ComputerSurfaceKind::Browser {
            self.load_tabs(cx);
        }
    }

    fn adopt(&mut self, view: ComputerView, cx: &mut Context<Self>) {
        self.phase = match view.state {
            ComputerViewState::Live => Phase::Connecting,
            ComputerViewState::Empty => Phase::Empty,
            ComputerViewState::Inactive => Phase::Inactive,
            ComputerViewState::BrowserUnavailable => Phase::BrowserUnavailable,
            _ => Phase::Unavailable,
        };
        self.url = view.url.clone();
        self.title = view.title.clone();
        self.audio_available = view.audio;
        self.view = Some(view);
        self.start_viewer(cx);
        self.activate_when_idle(cx);
        self.sync_control(cx);
        cx.notify();
    }

    /// Starts the page on the view's relay once both are ready.
    fn start_viewer(&mut self, cx: &mut Context<Self>) {
        let (Some(view), true) = (&self.view, self.loaded) else {
            return;
        };
        let Some(url) = view.stream_url.clone() else {
            return;
        };
        let surface = match view.surface {
            ComputerSurfaceKind::Desktop => "desktop",
            _ => "browser",
        };
        let mut config = json!({
            "surface": surface,
            "url": url,
            "transport": view.transport,
            // The relay holds the token and puts it in.
            "token": "",
            "chatId": self.chat_id,
            "audio": view.audio,
            "visible": true,
        });
        if view.surface == ComputerSurfaceKind::Browser {
            config["viewport"] = json!({"width": 1280, "height": 800, "mobile": false});
            config["desktopSite"] = json!(self.desktop_site);
        }
        let js = format!(
            "(() => {{ const start = () => window.computer.start({config}); if (window.computer) start(); else window.addEventListener('computerReady', start, {{once:true}}); }})()"
        );
        self.eval(&js, cx);
    }

    fn close_view(&mut self, cx: &mut Context<Self>) {
        if self.loaded {
            self.eval("window.computer?.dispose()", cx);
        }
        if let Some(handle) = self.view.take().and_then(|v| v.handle) {
            let call = self
                .rpc(cx)
                .call::<methods::ComputerClose>(&ComputerHandleRef { handle });
            conduit_daemon::runtime::shared().spawn(async move {
                let _ = call.await;
            });
        }
    }

    /// The user controls whenever the response is idle and there is a
    /// screen (or an empty browser to open a tab in): mobile's rule.
    fn sync_control(&mut self, cx: &mut Context<Self>) {
        let control =
            !self.stopping && !self.working && matches!(self.phase, Phase::Live | Phase::Empty);
        if control == self.controlling {
            return;
        }
        self.controlling = control;
        if self.loaded {
            self.eval(&format!("window.computer?.control({control})"), cx);
        }
        cx.notify();
    }

    /// An idle chat starts a waiting browser tab's live view without asking.
    fn activate_when_idle(&mut self, cx: &mut Context<Self>) {
        if self.phase != Phase::Inactive || self.working || self.stopping {
            return;
        }
        let tab = self.view.as_ref().and_then(|v| v.tab_id.clone());
        if tab.is_some() {
            self.open_surface(tab, false, cx);
        }
    }

    fn on_viewer(&mut self, note: ViewerNote, cx: &mut Context<Self>) {
        match note {
            ViewerNote::Pointer => return,
            ViewerNote::State {
                title,
                url,
                back,
                forward,
            } => {
                self.title = title;
                self.url = url;
                self.can_back = back;
                self.can_forward = forward;
            }
            ViewerNote::Audio {
                available,
                enabled,
                failed,
            } => {
                if let Some(available) = available {
                    self.audio_available = available;
                }
                if failed && self.audio_on {
                    let text = cx.l10n().computer_audio_unavailable();
                    self.stores.toasts.update(cx, |t, cx| {
                        t.show(conduit_protocol::NoticeLevel::Warning, text, cx)
                    });
                }
                self.audio_on = enabled;
            }
            ViewerNote::Status(status) => {
                self.phase = match status.as_str() {
                    "live" => Phase::Live,
                    "connecting" => Phase::Connecting,
                    "reconnecting" => Phase::Reconnecting,
                    "unavailable" => Phase::Unavailable,
                    "watching" => {
                        self.controlling = false;
                        self.phase.clone()
                    }
                    _ => self.phase.clone(),
                };
                if self.phase != Phase::Live {
                    self.controlling = false;
                    self.zoomed = false;
                }
                if self.phase == Phase::Live
                    && self.surface == ComputerSurfaceKind::Browser
                    && (self.lower_data || self.desktop_site)
                {
                    self.eval(&self.display_js(), cx);
                }
                self.sync_control(cx);
            }
        }
        cx.notify();
    }

    fn display_js(&self) -> String {
        let quality = if self.lower_data { "low" } else { "crisp" };
        format!(
            "window.computer?.display({})",
            json!({"quality": quality, "desktopSite": self.desktop_site})
        )
    }

    /// The chat's response started or ended.
    fn set_working(&mut self, working: bool, cx: &mut Context<Self>) {
        if self.working == working {
            return;
        }
        self.working = working;
        if working {
            self.sync_control(cx);
        } else {
            self.stopping = false;
            self.sync_control(cx);
            self.activate_when_idle(cx);
        }
        cx.notify();
    }

    /// Take Control: stops the chat's response; control follows once it
    /// has ended.
    pub fn take_control(&mut self, cx: &mut Context<Self>) {
        if self.stopping || !self.working {
            return;
        }
        self.stopping = true;
        cx.notify();
        let call = self.rpc(cx).call::<methods::TurnsStop>(&StopTurn {
            chat_id: self.chat_id.clone(),
        });
        self._tasks.push(cx.spawn(async move |this, cx| {
            let result = call.await;
            this.update(cx, |w, cx| {
                if let Err(e) = result {
                    log::warn!("turns.stop for Computer: {e}");
                    w.stopping = false;
                    let text = cx.l10n().computer_stop_failed();
                    w.stores.toasts.update(cx, |t, cx| {
                        t.show(conduit_protocol::NoticeLevel::Error, text, cx)
                    });
                }
                cx.notify();
            })
            .ok();
        }));
    }

    pub fn select_surface(&mut self, surface: ComputerSurfaceKind, cx: &mut Context<Self>) {
        if self.surface == surface {
            return;
        }
        self.surface = surface;
        self.open_surface(None, false, cx);
    }

    fn load_tabs(&mut self, cx: &mut Context<Self>) {
        let call = self.rpc(cx).call::<methods::ComputerTabs>(&ComputerScope {
            chat_id: self.chat_id.clone(),
        });
        self._tasks.push(cx.spawn(async move |this, cx| {
            let result = call.await;
            this.update(cx, |w, cx| {
                match result {
                    Ok(tabs) => w.tabs = tabs.tabs,
                    Err(e) => log::warn!("computer.tabs: {e}"),
                }
                cx.notify();
            })
            .ok();
        }));
    }

    fn run_tabs(&mut self, command: &ComputerTabsMenu, cx: &mut Context<Self>) {
        match command {
            ComputerTabsMenu::Select(id) => self.open_surface(Some(id.clone()), false, cx),
            ComputerTabsMenu::New => self.open_surface(None, true, cx),
            ComputerTabsMenu::Refresh => self.load_tabs(cx),
            ComputerTabsMenu::Close(id) => {
                let call = self
                    .rpc(cx)
                    .call::<methods::ComputerCloseTab>(&ComputerTabRef {
                        chat_id: self.chat_id.clone(),
                        tab_id: id.clone(),
                    });
                let closing_shown = self.view.as_ref().and_then(|v| v.tab_id.as_ref()) == Some(id);
                self._tasks.push(cx.spawn(async move |this, cx| {
                    let _ = call.await;
                    this.update(cx, |w, cx| {
                        if closing_shown {
                            w.open_surface(None, false, cx);
                        } else {
                            w.load_tabs(cx);
                        }
                    })
                    .ok();
                }));
            }
        }
    }

    fn run_more(&mut self, command: MoreCommand, window: &mut Window, cx: &mut Context<Self>) {
        match command {
            MoreCommand::Paste => {
                if let Some(text) = cx.read_from_clipboard().and_then(|c| c.text()) {
                    self.eval(
                        &format!(
                            "window.computer?.command({})",
                            json!({"type": "paste", "text": text})
                        ),
                        cx,
                    );
                }
            }
            MoreCommand::Shortcut => {
                self.shortcut_open = true;
                self.shortcut.update(cx, |s, cx| {
                    s.focus(window, cx);
                    s.select_all(window, cx);
                });
            }
            MoreCommand::Zoom => {
                self.zoomed = !self.zoomed;
                self.eval(&format!("window.computer?.zoom({})", self.zoomed), cx);
            }
            MoreCommand::Sound => {
                let on = !self.audio_on;
                self.eval(&format!("window.computer?.audio({on})"), cx);
            }
            MoreCommand::DesktopSite => {
                self.desktop_site = !self.desktop_site;
                self.eval(&self.display_js(), cx);
            }
            MoreCommand::LowerDataUse => {
                self.lower_data = !self.lower_data;
                self.eval(&self.display_js(), cx);
            }
            MoreCommand::Reconnect => self.open_surface(None, false, cx),
        }
        cx.notify();
    }

    /// Sends the shortcut field's key combination (`ctrl+c`, `alt+Tab`).
    fn send_shortcut(&mut self, cx: &mut Context<Self>) {
        let key = self
            .shortcut
            .read(cx)
            .value()
            .trim()
            .replace(' ', "")
            .replace("Cmd", "super")
            .replace("cmd", "super");
        self.shortcut_open = false;
        cx.notify();
        let Some(handle) = self.view.as_ref().and_then(|v| v.handle.clone()) else {
            return;
        };
        if key.is_empty() {
            return;
        }
        let call = self
            .rpc(cx)
            .call::<methods::ComputerShortcut>(&ComputerShortcut { handle, key });
        self._tasks.push(cx.spawn(async move |this, cx| {
            if let Err(e) = call.await {
                log::warn!("computer.shortcut: {e}");
                this.update(cx, |w, cx| {
                    let text = cx.l10n().computer_input_failed();
                    w.stores.toasts.update(cx, |t, cx| {
                        t.show(conduit_protocol::NoticeLevel::Error, text, cx)
                    });
                })
                .ok();
            }
        }));
    }

    fn navigate(&mut self, cx: &mut Context<Self>) {
        let typed = self.address.read(cx).value().to_string();
        if typed.trim().is_empty() {
            return;
        }
        let url = address_url(&typed);
        self.eval(
            &format!(
                "window.computer?.command({})",
                json!({"type": "navigate", "url": url})
            ),
            cx,
        );
    }

    fn browser_command(&mut self, kind: &str, cx: &mut Context<Self>) {
        self.eval(
            &format!("window.computer?.command({})", json!({"type": kind})),
            cx,
        );
    }

    fn more_menu(
        &mut self,
        position: gpui_kit::Point<gpui_kit::Pixels>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let l = cx.l10n().clone();
        let live = self.phase == Phase::Live;
        let item = |c| Box::new(ComputerMore(c));
        let mut menu = NativeMenu::new()
            .menu_with_disabled(
                l.terminal_paste_action(),
                !self.controlling,
                item(MoreCommand::Paste),
            )
            .menu_with_disabled(
                format!("{}\u{2026}", l.computer_shortcut()),
                !self.controlling,
                item(MoreCommand::Shortcut),
            )
            .separator()
            .menu_with_check(l.computer_zoom(), self.zoomed, item(MoreCommand::Zoom));
        if self.surface == ComputerSurfaceKind::Desktop && self.audio_available {
            menu =
                menu.menu_with_check(l.computer_sound(), self.audio_on, item(MoreCommand::Sound));
        }
        if self.surface == ComputerSurfaceKind::Browser {
            menu = menu
                .menu_with_check(
                    l.computer_desktop_site(),
                    self.desktop_site,
                    item(MoreCommand::DesktopSite),
                )
                .menu_with_check(
                    l.computer_quality_low(),
                    self.lower_data,
                    item(MoreCommand::LowerDataUse),
                );
        }
        menu = menu.separator().menu_with_disabled(
            l.desktop_terminal_reconnect(),
            live && !self.working,
            item(MoreCommand::Reconnect),
        );
        menu.show(position, window, cx);
    }

    fn tabs_menu(
        &mut self,
        position: gpui_kit::Point<gpui_kit::Pixels>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let l = cx.l10n().clone();
        let shown = self.view.as_ref().and_then(|v| v.tab_id.clone());
        let mut menu = NativeMenu::new();
        if self.tabs.is_empty() {
            menu = menu.menu_with_disabled(
                l.computer_no_tabs(),
                true,
                Box::new(ComputerTabsMenu::Refresh),
            );
        }
        for tab in &self.tabs {
            let title = if tab.title.trim().is_empty() {
                tab.url.clone()
            } else {
                tab.title.clone()
            };
            menu = menu.menu_with_check(
                title,
                shown.as_deref() == Some(tab.id.as_str()),
                Box::new(ComputerTabsMenu::Select(tab.id.clone())),
            );
        }
        menu = menu.separator().menu_with_disabled(
            l.computer_new_tab(),
            !self.controlling,
            Box::new(ComputerTabsMenu::New),
        );
        if let Some(id) = shown {
            menu = menu.menu_with_disabled(
                l.computer_close_tab(),
                !self.controlling,
                Box::new(ComputerTabsMenu::Close(id)),
            );
        }
        menu = menu.separator().menu(
            l.computer_refresh_tabs(),
            Box::new(ComputerTabsMenu::Refresh),
        );
        menu.show(position, window, cx);
    }

    fn status_text(&self, cx: &App) -> Option<String> {
        let l = cx.l10n();
        match self.phase {
            Phase::Live => None,
            Phase::Connecting => Some(l.computer_connecting()),
            Phase::Reconnecting => Some(l.computer_reconnecting()),
            Phase::Empty => Some(l.computer_no_tabs()),
            Phase::Inactive => Some(l.computer_browser_start_hint()),
            Phase::BrowserUnavailable => Some(l.computer_browser_unavailable()),
            Phase::Unavailable => Some(l.computer_disconnected()),
        }
    }
}

impl Render for ComputerWindow {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let t = cx.conduit().clone();
        let r = t.roles;
        let m = t.metrics;
        let l = cx.l10n().clone();
        let this = cx.entity().downgrade();
        let click = |f: fn(&mut ComputerWindow, &mut Window, &mut Context<ComputerWindow>)| {
            let this = this.clone();
            Rc::new(move |_: &ClickEvent, window: &mut Window, cx: &mut App| {
                this.update(cx, |w, cx| f(w, window, cx)).ok();
            }) as conduit_components::views::kit::ClickHandler
        };
        // Leading: the surface, as a segmented control when both exist.
        let surfaces: Vec<ComputerSurfaceKind> = [
            (self.status.desktop, ComputerSurfaceKind::Desktop),
            (self.status.browser, ComputerSurfaceKind::Browser),
        ]
        .into_iter()
        .filter_map(|(on, s)| on.then_some(s))
        .collect();
        let leading = if surfaces.len() > 1 {
            let pick = {
                let this = this.clone();
                let surfaces = surfaces.clone();
                Rc::new(move |i: usize, _: &mut Window, cx: &mut App| {
                    let surface = surfaces[i];
                    this.update(cx, |w, cx| w.select_surface(surface, cx)).ok();
                })
            };
            Segmented::new(
                "computer-surface",
                l.computer_title(),
                vec![
                    Segment::new(l.computer_desktop()).icon(IconName::Monitor),
                    Segment::new(l.computer_browser()).icon(IconName::Globe),
                ],
                usize::from(self.surface == ComputerSurfaceKind::Browser),
            )
            .on_select(pick)
            .into_any_element()
        } else {
            div()
                .id("computer-surface-title")
                .role(Role::Heading)
                .text_size(px(m.control))
                .font_weight(FontWeight::SEMIBOLD)
                .text_color(r.text)
                .child(SharedString::from(
                    if self.surface == ComputerSurfaceKind::Desktop {
                        l.computer_desktop()
                    } else {
                        l.computer_browser()
                    },
                ))
                .into_any_element()
        };
        // Middle: the agent's pill with Take Control, or the address.
        let middle = if self.working {
            let label = if self.stopping {
                l.computer_stopping()
            } else {
                l.computer_agent_working()
            };
            div()
                .flex_1()
                .flex()
                .justify_center()
                .child(
                    div()
                        .id("computer-agent")
                        .role(Role::Status)
                        .aria_label(SharedString::from(label.clone()))
                        .flex()
                        .items_center()
                        .gap(px(8.))
                        .pl(px(12.))
                        .pr(px(4.))
                        .h(px(28.))
                        .rounded_full()
                        .bg(conduit_components::theme::with_alpha(r.text, 0.08))
                        .text_size(px(m.small))
                        .text_color(r.text)
                        .child(div().size(px(7.)).rounded_full().bg(r.success))
                        .child(SharedString::from(label))
                        .child(
                            Button::new("computer-take-control", l.computer_take_control())
                                .primary()
                                .disabled(self.stopping)
                                .on_click(click(|w, _, cx| w.take_control(cx))),
                        ),
                )
                .into_any_element()
        } else if self.surface == ComputerSurfaceKind::Browser {
            let focused = self.address.focus_handle(cx).is_focused(window);
            let typed = self.address.read(cx).value().to_string();
            if let Some(url) = address_sync(&typed, &self.url, focused) {
                let url = url.to_string();
                self.address
                    .update(cx, |i, cx| i.set_value(url, window, cx));
            }
            div()
                .flex_1()
                .min_w_0()
                .px(px(8.))
                .child(
                    conduit_components::views::kit::field_frame(focused, 26., cx)
                        .rounded_full()
                        .child(conduit_components::assets::icon(
                            IconName::Globe,
                            12.,
                            r.text_subtle,
                        ))
                        .child(
                            div().flex_1().min_w_0().child(
                                bare_input(&self.address, l.computer_address(), m.small)
                                    .accessibility_id("computer-address"),
                            ),
                        ),
                )
                .into_any_element()
        } else {
            div()
                .flex_1()
                .min_w_0()
                .text_center()
                .truncate()
                .text_size(px(m.small))
                .text_color(r.text_subtle)
                .children(self.status_text(cx).map(SharedString::from))
                .into_any_element()
        };
        let browser = self.surface == ComputerSurfaceKind::Browser;
        let live = self.phase == Phase::Live && self.controlling;
        let mut trailing = div()
            .id("computer-tools")
            .role(Role::Toolbar)
            .flex()
            .items_center()
            .gap(px(2.));
        if browser {
            trailing = trailing
                .child(
                    IconButton::new("computer-back", IconName::ArrowLeft, l.back())
                        .size(28., 15.)
                        .disabled(!live || !self.can_back)
                        .on_click(click(|w, _, cx| w.browser_command("back", cx))),
                )
                .child(
                    IconButton::new(
                        "computer-forward",
                        IconName::ArrowRight,
                        l.computer_forward(),
                    )
                    .size(28., 15.)
                    .disabled(!live || !self.can_forward)
                    .on_click(click(|w, _, cx| w.browser_command("forward", cx))),
                )
                .child(
                    IconButton::new("computer-reload", IconName::RotateCw, l.computer_reload())
                        .size(28., 15.)
                        .disabled(!live)
                        .on_click(click(|w, _, cx| w.browser_command("reload", cx))),
                )
                .child(
                    IconButton::new("computer-tabs", IconName::Layers, l.computer_tabs())
                        .size(28., 15.)
                        .on_click({
                            let this = this.clone();
                            Rc::new(move |e: &ClickEvent, window: &mut Window, cx: &mut App| {
                                let position = e.position();
                                this.update(cx, |w, cx| w.tabs_menu(position, window, cx))
                                    .ok();
                            })
                        }),
                );
        }
        trailing = trailing.child(
            IconButton::new("computer-more", IconName::Ellipsis, l.more())
                .size(28., 15.)
                .on_click({
                    let this = this.clone();
                    Rc::new(move |e: &ClickEvent, window: &mut Window, cx: &mut App| {
                        let position = e.position();
                        this.update(cx, |w, cx| w.more_menu(position, window, cx))
                            .ok();
                    })
                }),
        );
        let toolbar = drag_region("computer-titlebar")
            .h(px(TOOLBAR_HEIGHT))
            .flex_none()
            .flex()
            .items_center()
            .gap(px(10.))
            .pl(px(TRAFFIC_LIGHTS_WIDTH + 6.))
            .pr(px(10.))
            .child(leading)
            .child(middle)
            .child(trailing);
        let shortcut_bar = self.shortcut_open.then(|| {
            let focused = self.shortcut.focus_handle(cx).is_focused(window);
            div()
                .id("computer-shortcut-bar")
                .flex_none()
                .h(px(40.))
                .px(px(14.))
                .flex()
                .items_center()
                .gap(px(8.))
                .border_b_1()
                .border_color(r.divider)
                .child(
                    div()
                        .text_size(px(m.small))
                        .text_color(r.text_subtle)
                        .child(SharedString::from(l.computer_shortcut())),
                )
                .child(
                    div().w(px(260.)).child(
                        conduit_components::views::kit::field_frame(focused, 28., cx).child(
                            bare_input(&self.shortcut, "Ctrl+A, Alt+Tab, Cmd+C", m.control)
                                .accessibility_id("computer-shortcut"),
                        ),
                    ),
                )
                .child(
                    Button::new("computer-shortcut-send", l.computer_send())
                        .primary()
                        .on_click(click(|w, _, cx| w.send_shortcut(cx))),
                )
                .child(
                    Button::new("computer-shortcut-cancel", l.cancel()).on_click(click(
                        |w, _, cx| {
                            w.shortcut_open = false;
                            cx.notify();
                        },
                    )),
                )
        });
        // Over the page while it has nothing to show: why, with New Tab
        // for an empty browser and Retry when it went away.
        let overlay = match self.phase {
            Phase::Live => None,
            Phase::Connecting | Phase::Reconnecting if !self.working || self.view.is_some() => None,
            _ => self.status_text(cx),
        }
        .map(|text| {
            let retry = matches!(self.phase, Phase::Unavailable).then(|| {
                Button::new("computer-retry", l.retry())
                    .on_click(click(|w, _, cx| w.open_surface(None, false, cx)))
            });
            let new_tab = matches!(self.phase, Phase::Empty).then(|| {
                Button::new("computer-new-tab", l.computer_new_tab())
                    .primary()
                    .disabled(!self.controlling)
                    .on_click(click(|w, _, cx| w.open_surface(None, true, cx)))
            });
            div()
                .absolute()
                .inset_0()
                .flex()
                .flex_col()
                .items_center()
                .justify_center()
                .gap(px(12.))
                .bg(r.content)
                .child(
                    div()
                        .id("computer-status")
                        .role(Role::Status)
                        .aria_label(SharedString::from(text.clone()))
                        .max_w(px(420.))
                        .text_center()
                        .text_size(px(m.control))
                        .text_color(r.text_subtle)
                        .child(SharedString::from(text)),
                )
                .children(retry)
                .children(new_tab)
        });
        div()
            .id("computer-window")
            .size_full()
            .flex()
            .flex_col()
            .bg(r.window)
            .on_action(cx.listener(|w, a: &ComputerMore, window, cx| w.run_more(a.0, window, cx)))
            .on_action(cx.listener(|w, a: &ComputerTabsMenu, _, cx| w.run_tabs(a, cx)))
            .child(toolbar)
            .children(shortcut_bar)
            .child(
                div()
                    .relative()
                    .flex_1()
                    .min_h_0()
                    .bg(r.content)
                    .child(self.webview.clone())
                    .children(overlay),
            )
    }
}

/// Opens the Computer viewer for `chat_id` (or brings it forward).
pub fn open(stores: Stores, chat_id: String, status: ComputerStatus, cx: &mut App) {
    if let Some((open_chat, handle, _)) = cx.default_global::<OpenComputer>().0.clone() {
        if open_chat == chat_id
            && handle
                .update(cx, |_, window, _| window.activate_window())
                .is_ok()
        {
            return;
        }
        let _ = handle.update(cx, |_, window, _| window.remove_window());
        cx.default_global::<OpenComputer>().0 = None;
    }
    let title = cx.l10n().computer_title();
    let bounds = Bounds::centered(None, size(px(1120.), px(780.)), cx);
    let mut options = conduit_components::window::window_options(&title, bounds, false, true);
    options.window_bounds = Some(WindowBounds::Windowed(bounds));
    options.window_min_size = Some(size(px(560.), px(420.)));
    let chat = chat_id.clone();
    let opened = open_window_clear_root(options, cx, move |window, cx| {
        let (tx, mut rx) = mpsc::unbounded::<Result<ViewerNote, ()>>();
        let (ipc, loaded) = (tx.clone(), tx);
        let builder = wry::WebViewBuilder::new()
            .with_incognito(true)
            .with_devtools(false)
            .with_transparent(true)
            // Only the page itself, loaded with mobile's origin.
            .with_navigation_handler(|url: String| {
                url == format!("{ORIGIN}/index.html") || url.starts_with("about:")
            })
            .with_new_window_req_handler(|_, _| wry::NewWindowResponse::Deny)
            .with_ipc_handler(move |request| {
                if let Some(note) = viewer_note(request.body()) {
                    let _ = ipc.unbounded_send(Ok(note));
                }
            })
            .with_on_page_load_handler(move |event, _| {
                if matches!(event, wry::PageLoadEvent::Finished) {
                    let _ = loaded.unbounded_send(Err(()));
                }
            });
        let webview = cx.new(|cx| {
            let webview =
                WebView::build(builder, window, cx).expect("a WKWebView always builds on macOS");
            crate::shell::web_media::guard(webview.raw());
            webview
        });
        load_viewer(&webview, cx);
        let address = cx.new(|cx| InputState::new(window, cx));
        let shortcut = cx.new(|cx| InputState::new(window, cx));
        let preferred = if status.desktop {
            ComputerSurfaceKind::Desktop
        } else {
            ComputerSurfaceKind::Browser
        };
        let working = chat_streaming(&chat, cx);
        cx.new(|cx| {
            let events = cx.spawn(async move |this, cx| {
                while let Some(note) = rx.next().await {
                    let alive = this
                        .update(cx, |w: &mut ComputerWindow, cx| match note {
                            Ok(note) => w.on_viewer(note, cx),
                            Err(()) => {
                                w.loaded = true;
                                w.start_viewer(cx);
                            }
                        })
                        .is_ok();
                    if !alive {
                        break;
                    }
                }
            });
            stores.connection.update(cx, |c, _| {
                c.subscribe(
                    "computer",
                    &[events::TURN_STARTED, events::TURN_FINISHED],
                    vec![chat.clone()],
                )
            });
            let subscriptions = vec![
                cx.subscribe(
                    &stores.connection,
                    |w: &mut ComputerWindow, _, e: &ConnectionEvent, cx| {
                        if let ConnectionEvent::Daemon(event) = e {
                            match event.as_ref() {
                                Event::TurnStarted(t) if t.chat_id == w.chat_id => {
                                    w.set_working(true, cx)
                                }
                                Event::TurnFinished(t) if t.chat_id == w.chat_id => {
                                    w.set_working(false, cx)
                                }
                                _ => {}
                            }
                        }
                    },
                ),
                cx.subscribe(&address, |w: &mut ComputerWindow, _, e: &InputEvent, cx| {
                    if let InputEvent::PressEnter { .. } = e {
                        w.navigate(cx);
                    }
                }),
                cx.subscribe(
                    &shortcut,
                    |w: &mut ComputerWindow, _, e: &InputEvent, cx| {
                        if let InputEvent::PressEnter { .. } = e {
                            w.send_shortcut(cx);
                        }
                    },
                ),
            ];
            let mut w = ComputerWindow {
                stores: stores.clone(),
                chat_id: chat.clone(),
                status,
                surface: preferred,
                view: None,
                phase: Phase::Connecting,
                working,
                stopping: false,
                controlling: false,
                zoomed: false,
                audio_available: false,
                audio_on: false,
                desktop_site: false,
                lower_data: false,
                url: String::new(),
                title: String::new(),
                can_back: false,
                can_forward: false,
                tabs: vec![],
                webview,
                loaded: false,
                address,
                shortcut,
                shortcut_open: false,
                generation: 0,
                _tasks: vec![events],
                _subscriptions: subscriptions,
            };
            w.open_surface(None, false, cx);
            w
        })
    });
    match opened {
        Ok((handle, view)) => {
            cx.default_global::<OpenComputer>().0 = Some((chat_id, handle, view.downgrade()));
            // The relay goes with the window.
            cx.observe_release(&view, |w, cx| {
                if let Some(h) = w.view.as_ref().and_then(|v| v.handle.clone()) {
                    let call = w
                        .stores
                        .connection
                        .read(cx)
                        .rpc()
                        .call::<methods::ComputerClose>(&ComputerHandleRef { handle: h });
                    conduit_daemon::runtime::shared().spawn(async move {
                        let _ = call.await;
                    });
                }
                w.stores
                    .connection
                    .update(cx, |c, _| c.subscribe("computer", &[], vec![]));
            })
            .detach();
        }
        Err(e) => log::error!("could not open Computer: {e}"),
    }
}

/// Whether the chat's response is running, as the main window's chat says.
fn chat_streaming(chat_id: &str, cx: &App) -> bool {
    let Some(view) = cx
        .try_global::<crate::AppState>()
        .and_then(|s| s.main_view.clone())
    else {
        return false;
    };
    let pane = view.read(cx).chat_pane.read(cx);
    pane.chat
        .as_ref()
        .map(|c| c.store.read(cx))
        .is_some_and(|s| s.chat_id() == chat_id && s.is_streaming())
}

/// Loads the viewer page with mobile's origin (`loadHTMLString:baseURL:`).
fn load_viewer(webview: &Entity<WebView>, cx: &App) {
    #[cfg(target_os = "macos")]
    {
        use objc2_foundation::{NSString, NSURL};
        use wry::WebViewExtMacOS as _;
        let view = webview.read(cx).raw().webview();
        let html = NSString::from_str(&document());
        let base = NSURL::URLWithString(&NSString::from_str(&format!("{ORIGIN}/index.html")));
        // SAFETY: a plain WKWebView load on the main thread.
        unsafe {
            let _ = view.loadHTMLString_baseURL(&html, base.as_deref());
        }
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = webview.read(cx).raw().load_html(&document());
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The address field shows where the page is now, and leaves what is
    /// being typed into it alone.
    #[test]
    fn the_address_field_follows_the_page_unless_being_edited() {
        assert_eq!(
            address_sync("", "https://docs.example.com/", false),
            Some("https://docs.example.com/")
        );
        assert_eq!(
            address_sync("https://a.example.com/", "https://b.example.com/", false),
            Some("https://b.example.com/")
        );
        assert_eq!(
            address_sync("https://a.example.com/", "https://b.example.com/", true),
            None,
            "typing in the field was overwritten"
        );
        assert_eq!(
            address_sync("https://a.example.com/", "https://a.example.com/", false),
            None
        );
        // Typed, then left without going there: the page's address comes back.
        assert_eq!(
            address_sync("https://half-typ", "https://a.example.com/", false),
            Some("https://a.example.com/")
        );
    }

    #[test]
    fn the_page_wraps_mobiles_viewer_and_reports_through_ipc() {
        let page = document();
        assert!(page.contains("connect-src ws://127.0.0.1:*"));
        assert!(page.contains("window.ipc.postMessage"));
        assert!(page.contains("window.computer="), "the viewer script is in");
        assert!(!page[page.find("<script>").unwrap()..].contains("</script>\n<"));
    }

    #[test]
    fn viewer_messages_read_as_mobile_reads_them() {
        assert_eq!(
            viewer_note(r#"{"status":"live"}"#),
            Some(ViewerNote::Status("live".into()))
        );
        assert_eq!(
            viewer_note(
                r#"{"status":"state","title":"Docs","url":"https://example.com/","canGoBack":true}"#
            ),
            Some(ViewerNote::State {
                title: "Docs".into(),
                url: "https://example.com/".into(),
                back: true,
                forward: false,
            })
        );
        assert_eq!(
            viewer_note(r#"{"status":"audio","available":true,"enabled":false}"#),
            Some(ViewerNote::Audio {
                available: Some(true),
                enabled: false,
                failed: false,
            })
        );
        assert_eq!(
            viewer_note(r#"{"status":"pointer","dragging":true}"#),
            Some(ViewerNote::Pointer)
        );
        assert_eq!(viewer_note("nonsense"), None);
    }

    #[test]
    fn typed_addresses_become_https_as_in_a_browser() {
        assert_eq!(address_url("example.com"), "https://example.com");
        assert_eq!(address_url(" localhost:3000 "), "https://localhost:3000");
        assert_eq!(
            address_url("http://localhost:3000/x"),
            "http://localhost:3000/x"
        );
        assert_eq!(address_url("about:blank"), "about:blank");
    }
}
