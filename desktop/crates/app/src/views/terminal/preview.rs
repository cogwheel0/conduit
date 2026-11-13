//! A listening port's page in a window of its own, as mobile's port
//! preview: Back, Forward, Reload and Open in Browser, the page's address
//! (`localhost:5173/docs`) in the title bar.
//!
//! The page loads from the daemon's preview listener on this Mac
//! (`terminal.previewPort`), which adds the terminal's credential and a
//! sign-in proxy's cookies on the way through, so the web view holds
//! neither. The core's navigation script follows the links Open WebUI's
//! proxy reports instead of following them; a page's link to the port
//! (`http://localhost:5173/x`) stays in the preview, any other web address
//! opens in the default browser, and anything else is refused.

use std::rc::Rc;

use conduit_components::ActiveConduitTheme as _;
use conduit_components::assets::IconName;
use conduit_components::views::kit::IconButton;
use conduit_components::window::{
    TOOLBAR_HEIGHT, TRAFFIC_LIGHTS_WIDTH, drag_region, open_window_clear_root,
};
use conduit_protocol::{TerminalPortRef, methods};
use futures::StreamExt as _;
use futures::channel::mpsc;
use gpui_kit::prelude::*;
use gpui_kit::{
    App, Bounds, ClickEvent, Context, Entity, FontWeight, Role, SharedString, Task, Window,
    WindowBounds, div, px, size,
};
use gpui_webview::WebView;

use crate::l10n::ActiveL10n as _;
use crate::stores::Stores;

/// Where a navigation the page starts may go.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Route {
    /// The preview's own page, or `about:`: load it.
    Allow,
    /// The port's address on the terminal's machine: load this instead.
    Load(String),
    /// Another web address: the default browser.
    External(String),
    Block,
}

/// `url`'s route in the preview served at `origin` (`http://127.0.0.1:P`)
/// for `port` on the terminal's machine.
pub fn route(url: &str, origin: &str, port: u16) -> Route {
    if url.starts_with("about:") {
        return Route::Allow;
    }
    let Ok(parsed) = url::Url::parse(url) else {
        return Route::Block;
    };
    if !matches!(parsed.scheme(), "http" | "https") {
        return Route::Block;
    }
    let own = url::Url::parse(origin).ok();
    if own.as_ref().is_some_and(|o| {
        o.host_str() == parsed.host_str()
            && o.port_or_known_default() == parsed.port_or_known_default()
    }) {
        return Route::Allow;
    }
    let local = matches!(
        parsed.host_str(),
        Some("localhost" | "127.0.0.1" | "0.0.0.0" | "[::1]" | "::1")
    );
    if local && parsed.port_or_known_default() == Some(port) {
        let mut path = parsed.path().to_string();
        if let Some(q) = parsed.query() {
            path.push('?');
            path.push_str(q);
        }
        if let Some(f) = parsed.fragment() {
            path.push('#');
            path.push_str(f);
        }
        return Route::Load(format!("{origin}{path}"));
    }
    if local {
        // Another port on the terminal's machine (or this Mac): not shown.
        return Route::Block;
    }
    Route::External(url.to_string())
}

/// What the title bar says for a page at `url`: `localhost:5173/docs`.
pub fn address(url: &str, origin: &str, port: u16) -> String {
    let rest = url.strip_prefix(origin).unwrap_or("/");
    let rest = if rest == "/" { "" } else { rest };
    let rest = if rest.starts_with("/.conduit-preview/") {
        ""
    } else {
        rest
    };
    format!("localhost:{port}{rest}")
}

/// The entry address with the page to land on: Open in Browser.
pub fn entry_to(entry: &str, url: &str, origin: &str) -> String {
    let path = url.strip_prefix(origin).unwrap_or("/");
    let path = if path.is_empty() || path.starts_with("/.conduit-preview/") {
        "/"
    } else {
        path
    };
    let encoded: String = url::form_urlencoded::byte_serialize(path.as_bytes()).collect();
    format!("{entry}?to={encoded}")
}

enum PageEvent {
    Loaded(String),
    Load(String),
    External(String),
}

pub struct PortPreview {
    webview: Entity<WebView>,
    origin: String,
    entry: String,
    port: u16,
    url: String,
    can_back: bool,
    can_forward: bool,
    _events: Task<()>,
    /// The app's rules for a page it did not write: no file picker,
    /// capture or new window, and a link out only right after a click or
    /// key press in the page ([`crate::views::chat::web_guard`]).
    #[cfg(target_os = "macos")]
    _guard: Option<crate::views::chat::web_guard::Guard>,
}

impl PortPreview {
    /// What the title bar says: `localhost:5173/about`.
    pub fn address(&self) -> String {
        address(&self.url, &self.origin, self.port)
    }

    /// Runs `js` in the page (the E2E's clicks).
    pub fn eval(&self, js: &str, cx: &App) {
        let _ = self.webview.read(cx).raw().evaluate_script(js);
    }

    fn back(&mut self, cx: &mut Context<Self>) {
        self.webview.update(cx, |w, _| {
            let _ = w.back();
        });
    }

    fn forward(&mut self, cx: &mut Context<Self>) {
        self.webview.update(cx, |w, _| {
            let _ = w.forward();
        });
    }

    /// Whether the user just clicked or pressed a key in the page (used up
    /// by the one link it lets open).
    fn user_activated(&self, cx: &App) -> bool {
        #[cfg(target_os = "macos")]
        {
            crate::views::chat::web_guard::take_activation(self.webview.read(cx).raw())
        }
        #[cfg(not(target_os = "macos"))]
        {
            let _ = cx;
            false
        }
    }

    fn reload(&mut self, cx: &mut Context<Self>) {
        let _ = self.webview.read(cx).raw().reload();
    }

    fn open_in_browser(&mut self, cx: &mut Context<Self>) {
        cx.open_url(&entry_to(&self.entry, &self.url, &self.origin));
    }

    fn on_page(&mut self, event: PageEvent, cx: &mut Context<Self>) {
        match event {
            PageEvent::Loaded(url) => {
                self.url = url;
                #[cfg(target_os = "macos")]
                {
                    use wry::WebViewExtMacOS as _;
                    let view = self.webview.read(cx).raw().webview();
                    // SAFETY: plain property reads on the main thread.
                    unsafe {
                        self.can_back = view.canGoBack();
                        self.can_forward = view.canGoForward();
                    }
                }
                cx.notify();
            }
            PageEvent::Load(url) => {
                self.webview.update(cx, |w, _| w.load_url(&url));
            }
            // A link the page opens elsewhere: http(s) or mailto only, and
            // only right after a click or key press in the page (a page
            // navigating on its own opens nothing).
            PageEvent::External(url) => {
                if self.user_activated(cx) {
                    crate::views::chat::markdown::open_web_link(&url, cx);
                } else {
                    log::warn!("a port preview asked to open a link without a click: refused");
                }
            }
        }
    }
}

impl Render for PortPreview {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let t = cx.conduit().clone();
        let r = t.roles;
        let m = t.metrics;
        let l = cx.l10n().clone();
        let title = address(&self.url, &self.origin, self.port);
        let this = cx.entity().downgrade();
        let act = |f: fn(&mut PortPreview, &mut Context<PortPreview>)| {
            let this = this.clone();
            Rc::new(move |_: &ClickEvent, _: &mut Window, cx: &mut App| {
                this.update(cx, f).ok();
            }) as conduit_components::views::kit::ClickHandler
        };
        let toolbar = div()
            .id("port-preview-toolbar")
            .role(Role::Toolbar)
            .flex()
            .items_center()
            .gap(px(2.))
            .child(
                IconButton::new("port-preview-back", IconName::ArrowLeft, l.back())
                    .size(30., 16.)
                    .round()
                    .disabled(!self.can_back)
                    .on_click(act(Self::back)),
            )
            .child(
                IconButton::new(
                    "port-preview-forward",
                    IconName::ArrowRight,
                    l.terminal_port_preview_forward(),
                )
                .size(30., 16.)
                .round()
                .disabled(!self.can_forward)
                .on_click(act(Self::forward)),
            )
            .child(
                IconButton::new(
                    "port-preview-reload",
                    IconName::RotateCw,
                    l.terminal_port_preview_reload(),
                )
                .size(30., 16.)
                .round()
                .on_click(act(Self::reload)),
            );
        let open = IconButton::new(
            "port-preview-open-in-browser",
            IconName::ExternalLink,
            l.terminal_open_in_browser_action(),
        )
        .size(30., 16.)
        .round()
        .on_click(act(Self::open_in_browser));
        div()
            .size_full()
            .flex()
            .flex_col()
            .bg(r.window)
            .child(
                drag_region("port-preview-titlebar")
                    .h(px(TOOLBAR_HEIGHT))
                    .flex_none()
                    .flex()
                    .items_center()
                    .gap(px(10.))
                    .pl(px(TRAFFIC_LIGHTS_WIDTH + 6.))
                    .pr(px(12.))
                    .child(toolbar)
                    .child(
                        div()
                            .id("port-preview-address")
                            .role(Role::Heading)
                            .aria_label(SharedString::from(title.clone()))
                            .flex_1()
                            .min_w_0()
                            .truncate()
                            .text_center()
                            .text_size(px(m.control))
                            .font_weight(FontWeight::SEMIBOLD)
                            .text_color(r.text)
                            .child(SharedString::from(title)),
                    )
                    .child(open),
            )
            .child(div().flex_1().min_h_0().child(self.webview.clone()))
    }
}

/// Asks the daemon for a preview of `port` and opens it in a window.
pub fn open(stores: Stores, handle: String, port: u16, cx: &mut App) {
    let asked_under = cx.default_global::<super::AccountWindows>().0;
    let rpc = stores.connection.read(cx).rpc();
    let call = rpc.call::<methods::TerminalPreviewPort>(&TerminalPortRef {
        handle,
        port: port.into(),
    });
    cx.spawn(async move |cx| match call.await {
        Ok(preview) => {
            cx.update(|cx| {
                // Another account signed in meanwhile: the preview was the
                // last account's, and its windows are closed.
                if cx.default_global::<super::AccountWindows>().0 == asked_under {
                    open_window(preview.url, preview.scripts, port, cx);
                }
            });
        }
        Err(e) => {
            log::warn!("terminal.previewPort: {e}");
            cx.update(|cx| {
                let text = cx.l10n().terminal_port_preview_load_failed();
                stores.toasts.update(cx, |t, cx| {
                    t.show(conduit_protocol::NoticeLevel::Error, text, cx)
                });
            });
        }
    })
    .detach();
}

/// The preview windows open now, for the E2E.
#[derive(Default)]
/// Weak: a closed preview's page goes with its window.
pub struct OpenPreviews(
    pub  Vec<(
        u16,
        gpui_kit::AnyWindowHandle,
        gpui_kit::WeakEntity<PortPreview>,
    )>,
);

impl gpui_kit::Global for OpenPreviews {}

fn open_window(entry: String, scripts: Vec<String>, port: u16, cx: &mut App) {
    let Ok(parsed) = url::Url::parse(&entry) else {
        return;
    };
    let origin = format!(
        "{}://{}:{}",
        parsed.scheme(),
        parsed.host_str().unwrap_or("127.0.0.1"),
        parsed.port_or_known_default().unwrap_or(80)
    );
    let title = format!("localhost:{port}");
    let bounds = Bounds::centered(None, size(px(1000.), px(720.)), cx);
    let mut options = conduit_components::window::window_options(&title, bounds, false, true);
    options.window_bounds = Some(WindowBounds::Windowed(bounds));
    options.window_min_size = Some(size(px(420.), px(320.)));
    let opened = open_window_clear_root(options, cx, move |window, cx| {
        let (tx, mut rx) = mpsc::unbounded::<PageEvent>();
        let (nav, loads) = (tx.clone(), tx);
        let nav_origin = origin.clone();
        let mut builder = wry::WebViewBuilder::new()
            .with_incognito(true)
            .with_devtools(false)
            .with_url(entry.clone())
            .with_navigation_handler(move |url: String| match route(&url, &nav_origin, port) {
                Route::Allow => true,
                Route::Load(to) => {
                    let _ = nav.unbounded_send(PageEvent::Load(to));
                    false
                }
                Route::External(to) => {
                    let _ = nav.unbounded_send(PageEvent::External(to));
                    false
                }
                Route::Block => false,
            })
            .with_on_page_load_handler(move |event, url| {
                if matches!(event, wry::PageLoadEvent::Finished) {
                    let _ = loads.unbounded_send(PageEvent::Loaded(url));
                }
            })
            .with_new_window_req_handler(|_, _| wry::NewWindowResponse::Deny);
        for script in scripts {
            builder = builder.with_initialization_script(script);
        }
        let webview = cx.new(|cx| {
            let webview =
                WebView::build(builder, window, cx).expect("a WKWebView always builds on macOS");
            crate::shell::web_media::guard(webview.raw());
            webview
        });
        cx.new(|cx| {
            let events = cx.spawn(async move |this, cx| {
                while let Some(event) = rx.next().await {
                    if this
                        .update(cx, |p: &mut PortPreview, cx| p.on_page(event, cx))
                        .is_err()
                    {
                        break;
                    }
                }
            });
            #[cfg(target_os = "macos")]
            let guard = crate::views::chat::web_guard::guard(webview.read(cx).raw(), |_| {});
            PortPreview {
                #[cfg(target_os = "macos")]
                _guard: guard,
                webview,
                origin: origin.clone(),
                entry: entry.clone(),
                port,
                url: format!("{origin}/"),
                can_back: false,
                can_forward: false,
                _events: events,
            }
        })
    });
    match opened {
        Ok((handle, view)) => {
            let open = &mut cx.default_global::<OpenPreviews>().0;
            open.retain(|(_, _, v)| v.upgrade().is_some());
            open.push((port, handle, view.downgrade()));
        }
        Err(e) => log::error!("could not open a port preview: {e}"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const ORIGIN: &str = "http://127.0.0.1:50123";

    /// A preview answered after another account signed in opens no window:
    /// the account change already ended the last account's previews.
    #[gpui_kit::test]
    fn a_preview_answered_after_an_account_change_opens_nothing(cx: &mut gpui_kit::TestAppContext) {
        use crate::stores::rpc::fake::FakeDaemon;
        let daemon = FakeDaemon::new();
        daemon.returns::<methods::TerminalPreviewPort>(conduit_protocol::TerminalPreview {
            url: "http://127.0.0.1:50123/?key=k".into(),
            scripts: vec![],
        });
        let scratch = std::env::temp_dir().join(format!("conduit-preview-{}", std::process::id()));
        let stores = cx.update(|cx| {
            crate::views::test_globals(cx);
            Stores::for_test(daemon.rpc(), &scratch, cx)
        });
        let late = daemon.hold::<methods::TerminalPreviewPort>();
        cx.update(|cx| open(stores.clone(), "handle-avery".into(), 5173, cx));
        cx.run_until_parked();
        cx.update(super::super::close_account_windows);
        drop(late);
        cx.run_until_parked();
        cx.update(|cx| {
            assert!(
                cx.default_global::<OpenPreviews>().0.is_empty(),
                "the last account's preview opened after the change"
            )
        });
    }

    #[test]
    fn the_preview_keeps_its_own_pages_and_the_port() {
        assert_eq!(
            route("http://127.0.0.1:50123/about", ORIGIN, 5173),
            Route::Allow
        );
        assert_eq!(route("about:blank", ORIGIN, 5173), Route::Allow);
        assert_eq!(
            route("http://localhost:5173/docs?a=1#b", ORIGIN, 5173),
            Route::Load(format!("{ORIGIN}/docs?a=1#b"))
        );
        assert_eq!(
            route("http://127.0.0.1:5173/", ORIGIN, 5173),
            Route::Load(format!("{ORIGIN}/"))
        );
    }

    #[test]
    fn other_addresses_leave_or_are_refused() {
        assert_eq!(
            route("https://example.com/x", ORIGIN, 5173),
            Route::External("https://example.com/x".into())
        );
        assert_eq!(route("http://localhost:8080/", ORIGIN, 5173), Route::Block);
        assert_eq!(route("file:///etc/hosts", ORIGIN, 5173), Route::Block);
        assert_eq!(route("javascript:alert(1)", ORIGIN, 5173), Route::Block);
    }

    #[test]
    fn the_title_and_open_in_browser_name_the_page() {
        assert_eq!(
            address(&format!("{ORIGIN}/"), ORIGIN, 5173),
            "localhost:5173"
        );
        assert_eq!(
            address(&format!("{ORIGIN}/docs?p=2"), ORIGIN, 5173),
            "localhost:5173/docs?p=2"
        );
        assert_eq!(
            address(&format!("{ORIGIN}/.conduit-preview/k"), ORIGIN, 5173),
            "localhost:5173"
        );
        assert_eq!(
            entry_to(
                &format!("{ORIGIN}/.conduit-preview/k"),
                &format!("{ORIGIN}/a b?x=1"),
                ORIGIN
            ),
            format!("{ORIGIN}/.conduit-preview/k?to=%2Fa+b%3Fx%3D1")
        );
    }
}
