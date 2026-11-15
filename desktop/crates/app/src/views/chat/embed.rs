//! Rich content in an answer, as the phone's `WebContentEmbed` and
//! `McpAppEmbed` show it: a card that loads it only when the user opens
//! it, then the content inline in the transcript, sized to it, in a sealed
//! web view ([`super::inline_web`]).
//!
//! * **HTML a tool returned:** the Preview window's page and rules ([`super::preview::embed_document`]):
//!   no network, a sandboxed frame, the tool's arguments as `window.args`.
//!   The page reports its height (kept within 220–900 pt, as on the
//!   phone); a link the user clicks opens in the browser.
//! * **A page by its address:** the page in a sandboxed frame; it may load
//!   what it needs, as on the phone. Nothing else is reachable.
//! * **An MCP App:** the daemon reads the page through the server's app RPC
//!   and hosts its bridge (`mcpApps.*`); the page carries the server's
//!   content security policy. Its messages go to the daemon over wry's IPC,
//!   and the daemon's come back as `mcpApps.event` (through the chat's
//!   store), with its height (100–1600 pt) and its start. Tool calls and
//!   links it asks for are confirmed on the approvals card. An app that
//!   does not start in 30 s, or that the server refuses, says so, with
//!   Retry.
//!
//! Every web view is incognito, has no developer tools, refuses new
//! windows and every navigation but its own page's.

use std::rc::Rc;

use conduit_components::ActiveConduitTheme as _;
use conduit_components::assets::{IconName, icon};
use conduit_components::theme::ConduitTheme;
use conduit_components::views::kit::Button;
use conduit_protocol::{
    EmbedDto, EmbedKind, McpAppEvent, McpAppEventKind, McpAppMessage, McpAppOpen, McpAppRef,
    methods,
};
use futures::StreamExt as _;
use gpui_kit::prelude::*;
use gpui_kit::{
    AnyElement, AsyncWindowContext, Context, ElementId, FontWeight, Role, SharedString,
    Subscription, WeakEntity, Window, div, px,
};

use super::inline_web::{InlineWebView, inline_web};
use super::preview::{self, EMBED_DEFAULT_HEIGHT, EMBED_MAX_HEIGHT, EMBED_MIN_HEIGHT};
use crate::l10n::ActiveL10n as _;
use crate::stores::chat::{ChatStore, ChatStoreEvent};

/// An MCP App's view: its first height, and the bounds a height it asks for
/// is kept in (the phone's).
const APP_INITIAL_HEIGHT: f32 = 300.;
const APP_MIN_HEIGHT: f32 = 100.;
const APP_MAX_HEIGHT: f32 = 1600.;

#[derive(Clone, Debug, PartialEq)]
enum State {
    /// The card: nothing loaded yet.
    Closed,
    /// An app's page is on its way.
    Loading,
    Open,
    Failed(String),
}

/// What the page sent over IPC.
#[derive(Debug, PartialEq)]
pub enum PageMessage {
    Height(f32),
    Open(String),
}

/// Reads what an embed's host page sends (`{"type":"height",…}`,
/// `{"type":"open",…}`).
pub fn page_message(body: &str) -> Option<PageMessage> {
    let value: serde_json::Value = serde_json::from_str(body).ok()?;
    match value.get("type")?.as_str()? {
        "height" => {
            let h = value.get("height")?.as_f64()? as f32;
            (h.is_finite() && h > 0.).then_some(PageMessage::Height(h))
        }
        "open" => {
            let url = value.get("url")?.as_str()?;
            let parsed = url::Url::parse(url).ok()?;
            matches!(parsed.scheme(), "http" | "https")
                .then(|| PageMessage::Open(parsed.to_string()))
        }
        _ => None,
    }
}

/// The script an MCP App's page starts with: what it posts over the MCP
/// Apps bridge goes to the app over IPC, and the host's messages arrive as
/// `message` events from the page's parent, which in a web view is the
/// page itself, through `deliver`. Popups, forms, workers and device access
/// are refused, as in a sandboxed frame (the phone's `mcpAppBridgeScript`).
pub fn app_bridge_script(deliver: &str) -> String {
    format!(
        "(()=>{{'use strict';\
const native=window.postMessage.bind(window);\
window.postMessage=(m,...rest)=>{{if(m&&typeof m==='object'&&m.jsonrpc==='2.0'){{\
let p;try{{p=JSON.stringify(m);}}catch(_){{return;}}{post};}}\
else{{native(m,...rest);}}}};\
Object.defineProperty(window,{deliver},{{value:(payload)=>{{let data;\
try{{data=JSON.parse(payload);}}catch(_){{return;}}\
window.dispatchEvent(new MessageEvent('message',{{data,source:window,origin:location.origin}}));}},\
writable:false,configurable:false}});\
window.open=()=>null;\
addEventListener('submit',(e)=>{{e.preventDefault();}},true);\
const denied=()=>Promise.reject(new DOMException('Denied','NotAllowedError'));\
const replace=(o,n,v)=>{{try{{Object.defineProperty(o,n,{{value:v,configurable:false}});}}catch(_){{}}}};\
if(navigator.serviceWorker)replace(navigator.serviceWorker,'register',denied);\
if(navigator.clipboard){{replace(navigator.clipboard,'read',denied);replace(navigator.clipboard,'readText',denied);}}\
if(navigator.mediaDevices)replace(navigator.mediaDevices,'getUserMedia',denied);\
if(navigator.geolocation){{replace(navigator.geolocation,'getCurrentPosition',(_,e)=>e&&e({{code:1}}));\
replace(navigator.geolocation,'watchPosition',(_,e)=>{{e&&e({{code:1}});return 0;}});}}}})();",
        deliver = preview::js_string(deliver),
        post = super::web_guard::post_script("p"),
    )
}

pub struct EmbedView {
    id: String,
    embed: EmbedDto,
    /// Returned by a tool call (its card says "Tool Output").
    tool: bool,
    store: WeakEntity<ChatStore>,
    /// The daemon (a call is sent as it is made, so a dropped view can
    /// still close its app).
    rpc: Option<crate::stores::rpc::Rpc>,
    state: State,
    height: f32,
    view: Option<Rc<InlineWebView>>,
    /// The app's own message handler and UI delegate on `view`.
    #[cfg(target_os = "macos")]
    guard: Option<super::web_guard::Guard>,
    /// The app's run, once the daemon started it.
    app_id: Option<String>,
    /// The app finished its handshake.
    started: bool,
    /// Where the host's messages go in the page.
    deliver: String,
    _page: Option<gpui_kit::Task<()>>,
    _store: Option<Subscription>,
}

impl EmbedView {
    pub fn new(
        id: String,
        embed: EmbedDto,
        tool: bool,
        store: WeakEntity<ChatStore>,
        cx: &mut Context<Self>,
    ) -> Self {
        let rpc = store.upgrade().map(|s| s.read(cx).rpc());
        let subscription = store.upgrade().map(|store| {
            cx.subscribe(&store, |this: &mut Self, _, event: &ChatStoreEvent, cx| {
                if let ChatStoreEvent::McpApp(event) = event {
                    this.app_event(event, cx);
                }
            })
        });
        Self {
            id,
            embed,
            tool,
            store,
            rpc,
            state: State::Closed,
            height: EMBED_DEFAULT_HEIGHT,
            view: None,
            #[cfg(target_os = "macos")]
            guard: None,
            app_id: None,
            started: false,
            deliver: format!("__conduitDeliver{}", uuid_like()),
            _page: None,
            _store: subscription,
        }
    }

    /// The same embed drawn again: a new one (another version of the
    /// answer) closes what was open.
    pub fn set(&mut self, embed: &EmbedDto, cx: &mut Context<Self>) {
        if *embed != self.embed {
            self.close(cx);
            self.embed = embed.clone();
        }
    }

    /// Takes the web view out, with its guard.
    fn drop_view(&mut self) {
        #[cfg(target_os = "macos")]
        {
            self.guard = None;
        }
        self.view = None;
    }

    fn close(&mut self, cx: &mut Context<Self>) {
        self.stop_app(cx);
        self.drop_view();
        self._page = None;
        self.state = State::Closed;
        self.started = false;
        cx.notify();
    }

    fn stop_app(&mut self, _: &mut Context<Self>) {
        if let (Some(app_id), Some(rpc)) = (self.app_id.take(), &self.rpc) {
            // Sent as it is made; nothing waits for the answer.
            drop(rpc.call::<methods::McpAppsClose>(&McpAppRef { app_id }));
        }
    }

    /// What it embeds.
    pub fn embed(&self) -> &EmbedDto {
        &self.embed
    }

    /// Open, its page or app loaded.
    pub fn is_open(&self) -> bool {
        self.state == State::Open && self.view.is_some()
    }

    /// The app finished its handshake.
    pub fn started(&self) -> bool {
        self.started
    }

    /// Its height now, in points.
    pub fn height(&self) -> f32 {
        self.height
    }

    /// Why it could not be shown, if it could not.
    pub fn failure(&self) -> Option<&str> {
        match &self.state {
            State::Failed(reason) => Some(reason),
            _ => None,
        }
    }

    pub fn open(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        match self.embed.kind {
            EmbedKind::McpApp => self.open_app(window, cx),
            EmbedKind::Html | EmbedKind::Url => self.open_page(window, cx),
            EmbedKind::Unknown => {}
        }
    }

    fn builder(&self, cx: &Context<Self>) -> wry::WebViewBuilder<'static> {
        let t = cx.conduit();
        let theme = preview::PreviewTheme::from_theme(t);
        let bg = {
            let hex = theme.background.trim_start_matches('#');
            let byte = |i: usize| u8::from_str_radix(&hex[i..i + 2], 16).unwrap_or(0);
            (byte(0), byte(2), byte(4), 255)
        };
        wry::WebViewBuilder::new()
            .with_incognito(true)
            .with_devtools(false)
            .with_background_color(bg)
            .with_new_window_req_handler(|_, _| wry::NewWindowResponse::Deny)
    }

    /// A page from the answer: the card opens to it.
    fn open_page(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let theme = preview::PreviewTheme::from_theme(cx.conduit());
        let source = self.embed.source.clone().unwrap_or_default();
        let (document, remote) = match self.embed.kind {
            EmbedKind::Url => match url::Url::parse(&source) {
                Ok(url) if matches!(url.scheme(), "http" | "https") => {
                    (preview::remote_embed_document(&url, &theme), true)
                }
                _ => {
                    self.state = State::Failed(cx.l10n().desktop_embed_load_failed());
                    cx.notify();
                    return;
                }
            },
            _ => (
                preview::embed_document(&source, &self.embed.args_text, &theme),
                false,
            ),
        };
        let mut builder = self
            .builder(cx)
            .with_html(document)
            // Its own page and frame; a remote page may go where the web
            // takes it inside its frame, as on the phone.
            .with_navigation_handler(move |url: String| {
                url.starts_with("about:")
                    || url.starts_with("data:")
                    || (remote && (url.starts_with("https://") || url.starts_with("http://")))
            });
        if remote {
            // The height and link reports in the remote frame too.
            builder = builder.with_initialization_script_for_main_only(
                preview::EMBED_FRAME_SCRIPT.to_string(),
                false,
            );
        }
        self.height = EMBED_DEFAULT_HEIGHT;
        self.show(builder, window, cx);
    }

    /// Shows the web view `builder` makes, its top document's messages
    /// going to [`Self::on_page`] through the app's own handler (see
    /// [`super::web_guard`]); no wry IPC handler, which takes every frame's.
    fn show(
        &mut self,
        builder: wry::WebViewBuilder<'static>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let (tx, mut rx) = futures::channel::mpsc::unbounded::<String>();
        match InlineWebView::new(builder, window) {
            Some(view) => {
                #[cfg(target_os = "macos")]
                {
                    self.guard = super::web_guard::guard(view.webview(), move |body| {
                        let _ = tx.unbounded_send(body);
                    });
                }
                #[cfg(not(target_os = "macos"))]
                drop(tx);
                self.view = Some(view);
                self.state = State::Open;
                self._page = Some(cx.spawn_in(
                    window,
                    async move |this: WeakEntity<Self>, cx: &mut AsyncWindowContext| {
                        while let Some(body) = rx.next().await {
                            if this.update(cx, |s, cx| s.on_page(body, cx)).is_err() {
                                break;
                            }
                        }
                    },
                ));
            }
            None => {
                // An app the daemon started for a view that never showed
                // ends with it (Try Again starts another).
                self.stop_app(cx);
                self.state = State::Failed(cx.l10n().desktop_embed_load_failed());
            }
        }
        cx.notify();
    }

    /// What the page sent.
    fn on_page(&mut self, body: String, cx: &mut Context<Self>) {
        if self.embed.kind == EmbedKind::McpApp {
            if let (Some(app_id), Some(rpc)) = (self.app_id.clone(), &self.rpc) {
                drop(rpc.call::<methods::McpAppsMessage>(&McpAppMessage {
                    app_id,
                    payload: body,
                }));
            }
            return;
        }
        match page_message(&body) {
            Some(PageMessage::Height(h)) => {
                let h = h.clamp(EMBED_MIN_HEIGHT, EMBED_MAX_HEIGHT);
                if (h - self.height).abs() >= 1. {
                    self.height = h;
                    cx.notify();
                }
            }
            // A link the user clicked opens in the browser, as on the
            // phone: only right after a click or key press in this web
            // view, which the app saw itself (a page posting on its own
            // opens nothing). Only http(s) or mailto, as any link in a chat.
            Some(PageMessage::Open(url)) => {
                if self.user_activated() {
                    super::markdown::open_web_link(&url, cx);
                } else {
                    log::warn!("an embed asked to open a link without a click: refused");
                }
            }
            None => {}
        }
    }

    /// Whether the user just clicked or pressed a key in this embed's web
    /// view (used up by the one link it lets open).
    fn user_activated(&self) -> bool {
        #[cfg(target_os = "macos")]
        {
            self.view
                .as_ref()
                .is_some_and(|v| super::web_guard::take_activation(v.webview()))
        }
        #[cfg(not(target_os = "macos"))]
        false
    }

    /// An MCP App: the daemon loads its page and starts its host.
    fn open_app(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let (Some(app), Some(store)) = (self.embed.app.clone(), self.store.upgrade()) else {
            return;
        };
        let t = cx.conduit();
        let call = store
            .read(cx)
            .rpc()
            .call::<methods::McpAppsOpen>(&McpAppOpen {
                chat_id: store.read(cx).chat_id().to_string(),
                app,
                theme: if t.dark {
                    "dark".into()
                } else {
                    "light".into()
                },
                locale: cx.l10n().locale().to_string(),
                width: 0.,
            });
        self.state = State::Loading;
        self.started = false;
        self.height = APP_INITIAL_HEIGHT;
        cx.notify();
        self._page = Some(cx.spawn_in(
            window,
            async move |this: WeakEntity<Self>, cx: &mut AsyncWindowContext| {
                let result = call.await;
                let _ = this.update_in(cx, |s, window, cx| match result {
                    Ok(session) => s.start_app(session, window, cx),
                    Err(e) => {
                        let reason = e
                            .args
                            .get("detail")
                            .cloned()
                            .filter(|d| !d.is_empty())
                            .unwrap_or_else(|| cx.l10n().error_message());
                        s.state = State::Failed(cx.l10n().mcp_app_load_failed(&reason));
                        cx.notify();
                    }
                });
            },
        ));
    }

    fn start_app(
        &mut self,
        session: conduit_protocol::McpAppSession,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.app_id = Some(session.app_id.clone());
        let builder = self
            .builder(cx)
            .with_html(session.document)
            .with_initialization_script_for_main_only(app_bridge_script(&self.deliver), true)
            // The page is loaded once and never navigates; its links go
            // through the bridge (confirmed first).
            .with_navigation_handler(|url: String| {
                url.starts_with("about:") || url.starts_with("data:")
            });
        self.show(builder, window, cx);
    }

    fn app_event(&mut self, event: &McpAppEvent, cx: &mut Context<Self>) {
        if self.app_id.as_deref() != Some(event.app_id.as_str()) {
            return;
        }
        match event.kind {
            McpAppEventKind::Deliver => {
                if let (Some(view), Some(message)) = (&self.view, &event.message) {
                    #[cfg(target_os = "macos")]
                    {
                        let _ = view.webview().evaluate_script(&format!(
                            "{}({});",
                            self.deliver,
                            preview::js_string(message)
                        ));
                    }
                    #[cfg(not(target_os = "macos"))]
                    let _ = (view, message);
                }
            }
            McpAppEventKind::Resize => {
                if let Some(h) = event.height {
                    self.height = (h as f32).clamp(APP_MIN_HEIGHT, APP_MAX_HEIGHT);
                    cx.notify();
                }
            }
            McpAppEventKind::Started => {
                self.started = true;
                cx.notify();
            }
            McpAppEventKind::Closed => {
                self.app_id = None;
                self.drop_view();
                self._page = None;
                self.state = State::Failed(if self.started {
                    cx.l10n().desktop_embed_load_failed()
                } else {
                    cx.l10n().mcp_app_did_not_start()
                });
                cx.notify();
            }
            McpAppEventKind::Unknown => {}
        }
    }

    fn card(
        &self,
        title: String,
        message: String,
        action: Option<(String, bool)>,
        t: &ConduitTheme,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let r = t.roles;
        let m = t.metrics;
        let this = cx.entity().downgrade();
        let glyph = if self.embed.kind == EmbedKind::McpApp {
            IconName::AppWindow
        } else {
            IconName::Globe
        };
        div()
            .id(ElementId::Name(format!("embed-card-{}", self.id).into()))
            .role(Role::Group)
            .aria_label(SharedString::from(title.clone()))
            .w_full()
            .px(px(12.))
            .py(px(10.))
            .flex()
            .flex_col()
            .gap(px(6.))
            .rounded(t.card_radius())
            .border_1()
            .border_color(r.border)
            .bg(conduit_components::views::kit::raised_fill(t))
            .child(
                div()
                    .flex()
                    .items_center()
                    .gap(px(8.))
                    .child(icon(glyph, 14., r.text_subtle))
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .truncate()
                            .text_size(px(m.control))
                            .font_weight(FontWeight::SEMIBOLD)
                            .text_color(r.text)
                            .child(SharedString::from(title)),
                    ),
            )
            .child(
                div()
                    .text_size(px(m.small))
                    .text_color(r.text_subtle)
                    .child(SharedString::from(message)),
            )
            .when_some(action, |d, (label, busy)| {
                d.child(
                    div().flex().child(
                        Button::new(
                            ElementId::Name(format!("embed-open-{}", self.id).into()),
                            label,
                        )
                        .disabled(busy)
                        .on_click(Rc::new(move |_, window, cx| {
                            let _ = this.update(cx, |s, cx| s.open(window, cx));
                        })),
                    ),
                )
            })
            .into_any_element()
    }
}

impl Drop for EmbedView {
    fn drop(&mut self) {
        // The daemon's host for the app goes with its view.
        if let (Some(app_id), Some(rpc)) = (self.app_id.take(), &self.rpc) {
            drop(rpc.call::<methods::McpAppsClose>(&McpAppRef { app_id }));
        }
    }
}

impl Render for EmbedView {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let t = cx.conduit().clone();
        let l10n = cx.l10n().clone();
        let r = t.roles;
        let app = self.embed.app.clone();
        let title = match (&app, self.tool) {
            (Some(app), _) => app.tool_name.clone(),
            (None, true) => l10n.desktop_embed_tool_title(),
            (None, false) => l10n.desktop_embed_title(),
        };
        match &self.state {
            State::Closed => {
                let (message, action) = match (&app, self.embed.kind) {
                    (Some(app), _) => (
                        l10n.mcp_app_preview_description(&app.server_id),
                        l10n.mcp_app_open(),
                    ),
                    (None, EmbedKind::Url) => (
                        self.embed.source.clone().unwrap_or_default(),
                        l10n.open_preview(),
                    ),
                    _ => (l10n.desktop_embed_description(), l10n.open_preview()),
                };
                self.card(title, message, Some((action, false)), &t, cx)
            }
            State::Loading => self.card(title, l10n.desktop_loading(), None, &t, cx),
            State::Failed(reason) => {
                let reason = reason.clone();
                self.card(title, reason, Some((l10n.retry(), false)), &t, cx)
            }
            State::Open => {
                let Some(view) = self.view.clone() else {
                    return div().into_any_element();
                };
                let this = cx.entity().downgrade();
                let waiting = self.embed.kind == EmbedKind::McpApp && !self.started;
                div()
                    .id(ElementId::Name(format!("embed-{}", self.id).into()))
                    .role(Role::Group)
                    .aria_label(SharedString::from(title.clone()))
                    .w_full()
                    .flex()
                    .flex_col()
                    .gap(px(4.))
                    .child(
                        div()
                            .relative()
                            .w_full()
                            .rounded(t.card_radius())
                            .overflow_hidden()
                            .border_1()
                            .border_color(r.border)
                            .child(inline_web(view, self.height))
                            .when(waiting, |d| {
                                d.child(
                                    div()
                                        .absolute()
                                        .inset_0()
                                        .flex()
                                        .items_center()
                                        .justify_center()
                                        .child(super::blocks::spinner(
                                            ElementId::Name(
                                                format!("embed-wait-{}", self.id).into(),
                                            ),
                                            16.,
                                            r.text_subtle,
                                        )),
                                )
                            }),
                    )
                    .child(
                        div().flex().justify_end().child(
                            conduit_components::views::kit::IconButton::new(
                                ElementId::Name(format!("embed-close-{}", self.id).into()),
                                IconName::X,
                                l10n.desktop_embed_close(),
                            )
                            .size(24., 12.)
                            .tooltip(l10n.desktop_embed_close())
                            .on_click(Rc::new(move |_, _, cx| {
                                let _ = this.update(cx, |s, cx| s.close(cx));
                            })),
                        ),
                    )
                    .into_any_element()
            }
        }
    }
}

/// A name no page can guess, for the app's delivery function.
fn uuid_like() -> String {
    use std::hash::{BuildHasher, Hasher};
    let mut h = std::collections::hash_map::RandomState::new().build_hasher();
    h.write_u128(
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or_default(),
    );
    format!("{:016x}", h.finish())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn page_messages_are_read_strictly() {
        assert_eq!(
            page_message(r#"{"type":"height","height":412.5}"#),
            Some(PageMessage::Height(412.5))
        );
        assert_eq!(page_message(r#"{"type":"height","height":-1}"#), None);
        assert_eq!(
            page_message(r#"{"type":"open","url":"https://example.com/a"}"#),
            Some(PageMessage::Open("https://example.com/a".into()))
        );
        assert_eq!(
            page_message(r#"{"type":"open","url":"file:///etc/hosts"}"#),
            None
        );
        assert_eq!(page_message("not json"), None);
    }

    #[test]
    fn the_app_bridge_hands_json_rpc_to_the_host_only() {
        let script = app_bridge_script("__conduitDeliverab12");
        assert!(script.contains("m.jsonrpc==='2.0'"));
        assert!(script.contains("messageHandlers.conduitHost.postMessage(p)"));
        assert!(script.contains("\"__conduitDeliverab12\""));
        assert!(script.contains("window.open=()=>null"));
    }

    #[gpui_kit::test]
    fn an_app_whose_view_never_showed_is_closed(cx: &mut gpui_kit::TestAppContext) {
        use std::rc::Rc;

        use gpui_kit::AppContext as _;

        use crate::stores::chat::{ChatStore, Subscribe};
        use crate::stores::rpc::fake::FakeDaemon;

        cx.update(crate::views::test_globals);
        let daemon = FakeDaemon::new();
        daemon.on::<methods::McpAppsOpen>(|_| {
            Ok(serde_json::json!({"appId": "app-1", "document": "<p>Synthetic app</p>"}))
        });
        daemon.on::<methods::McpAppsClose>(|_| Ok(serde_json::json!({"accepted": true})));
        let subscribe: Subscribe = Rc::new(|_, _| {});
        let rpc = daemon.rpc();
        let store = cx.new(|cx| ChatStore::new(rpc, subscribe, "c1".into(), cx));
        let embed: EmbedDto = serde_json::from_value(serde_json::json!({
            "kind": "mcpApp",
            "app": {"serverId": "s1", "toolName": "board", "binding": "ui://board"},
        }))
        .unwrap();
        let weak = store.downgrade();
        let (view, vcx) =
            cx.add_window_view(move |_, cx| EmbedView::new("e0.0".into(), embed, true, weak, cx));
        // A test window has no native view: the web view can't be made.
        view.update_in(vcx, |v, window, cx| v.open(window, cx));
        vcx.run_until_parked();
        view.read_with(vcx, |v, _| assert!(v.failure().is_some()));
        assert_eq!(
            daemon.calls::<methods::McpAppsClose>(),
            vec![serde_json::json!({"appId": "app-1"})],
            "the daemon's app stayed open"
        );
    }
}
