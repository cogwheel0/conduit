//! Single sign-on in a browser window.
//!
//! SSO (an identity provider linked from Open WebUI's sign-in page) and
//! reverse-proxy sign-ins (oauth2-proxy, Authelia, Cloudflare Access) need a
//! real browser: a redirect chain, third-party cookies, a hardware key. So
//! [`run_sso`] opens a `gpui-webview` (WKWebView) window with a
//! **non-persistent** data store at the server's `/auth` page and waits.
//!
//! * **Done** when a page finishes loading on the server's origin and either
//!   Open WebUI's `token` cookie is set, or the flow left the origin and came
//!   back (a proxy let the user through; the daemon then decides whether
//!   Open WebUI still wants a sign-in).
//! * **Cookies** are read with wry's `cookies()` (every cookie, HttpOnly
//!   ones included) and matched to the server's host here
//!   ([`cookie_matches`]): `cookies_for_url` misses IP hosts and
//!   parent-domain cookies. They go to the daemon in
//!   `auth.completeExternal`, which proves them against the server before
//!   anything is saved.
//! * **Cancel** by closing the window; after 5 minutes the window closes
//!   and the flow times out. The store is discarded with the window.
//! * Only http(s) navigations are allowed in the window.

use std::collections::BTreeMap;
use std::time::Duration;

use gpui_kit::{App, AppContext as _, AsyncApp, Task};

/// How long a sign-in may take.
pub const SSO_TIMEOUT: Duration = Duration::from_secs(5 * 60);

/// Test hook (the `--shots` E2E pass): a script the window runs once on the
/// server's own sign-in page, standing in for the user at an identity
/// provider. Never set in normal use.
#[derive(Clone, Debug, Default)]
pub struct SsoScript(pub Option<String>);

impl gpui_kit::Global for SsoScript {}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SsoOutcome {
    Captured {
        origin: String,
        cookies: BTreeMap<String, String>,
        token: Option<String>,
    },
    /// The user closed the window.
    Cancelled,
    TimedOut,
    Failed(String),
}

/// `scheme://host[:port]` of `url`.
pub fn origin_of(url: &str) -> Option<String> {
    let u = url::Url::parse(url).ok()?;
    if !matches!(u.scheme(), "http" | "https") {
        return None;
    }
    Some(u.origin().ascii_serialization())
}

/// Where the flow starts: Open WebUI's sign-in page, under the server's
/// path prefix when it has one (a query stays; a fragment goes).
pub fn start_url(server_url: &str) -> Option<String> {
    origin_of(server_url)?;
    let mut url = url::Url::parse(server_url).ok()?;
    url.set_fragment(None);
    let path = format!("{}/auth", url.path().trim_end_matches('/'));
    url.set_path(&path);
    Some(url.to_string())
}

/// A cookie as the sign-in window's store holds it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Captured<'a> {
    /// The host for a host-only cookie, the domain (no dot) for the rest.
    pub domain: Option<&'a str>,
    /// Set without a Domain attribute: sent to its own host only.
    pub host_only: bool,
    pub secure: bool,
    pub path: Option<&'a str>,
    pub name: &'a str,
    pub value: &'a str,
}

/// Whether `cookie` is one a browser would send with a request to `url`
/// (RFC 6265: domain, host-only, path and Secure).
pub fn cookie_sent_to(cookie: &Captured<'_>, url: &url::Url) -> bool {
    let Some(host) = url.host_str() else {
        return false;
    };
    let domain_ok = if cookie.host_only {
        cookie.domain.is_some_and(|d| {
            d.trim_start_matches('.')
                .eq_ignore_ascii_case(host.trim_start_matches('[').trim_end_matches(']'))
        })
    } else {
        cookie_matches(cookie.domain, host)
    };
    let secure_ok = !cookie.secure || url.scheme() == "https";
    domain_ok && secure_ok && path_matches(cookie.path.unwrap_or("/"), url.path())
}

/// RFC 6265 path-match: the same path, or a prefix ending at a `/`.
fn path_matches(cookie_path: &str, request_path: &str) -> bool {
    let request_path = if request_path.is_empty() {
        "/"
    } else {
        request_path
    };
    request_path == cookie_path
        || (request_path.starts_with(cookie_path)
            && (cookie_path.ends_with('/') || request_path[cookie_path.len()..].starts_with('/')))
}

/// The cookies the server at `server_url` would be sent, by name. When two
/// match, the more specific one wins (the longer path, then the longer
/// domain), as a browser orders them.
pub fn cookies_for_server<'a>(
    cookies: impl IntoIterator<Item = Captured<'a>>,
    server_url: &str,
) -> BTreeMap<String, String> {
    let Ok(mut url) = url::Url::parse(server_url) else {
        return BTreeMap::new();
    };
    // Requests go under the server's path (its prefix, when it has one).
    if !url.path().ends_with('/') {
        let path = format!("{}/", url.path());
        url.set_path(&path);
    }
    let mut matched: Vec<_> = cookies
        .into_iter()
        .filter(|c| cookie_sent_to(c, &url))
        .collect();
    matched.sort_by_key(|c| (c.path.map_or(1, str::len), c.domain.map_or(0, str::len)));
    matched
        .into_iter()
        .map(|c| (c.name.to_string(), c.value.to_string()))
        .collect()
}

/// Whether a cookie set for `cookie_domain` (as WebKit reports it: the
/// host for a host-only cookie, `.example.org` for a domain cookie) is sent
/// to `host`. RFC 6265 domain matching: the same host, or `host` ends with
/// `.` + the domain; an IP address only matches itself.
pub fn cookie_matches(cookie_domain: Option<&str>, host: &str) -> bool {
    let Some(domain) = cookie_domain else {
        return false;
    };
    let domain = domain.trim_start_matches('.').to_ascii_lowercase();
    let host = host
        .trim_start_matches('[')
        .trim_end_matches(']')
        .to_ascii_lowercase();
    if domain.is_empty() {
        return false;
    }
    if domain == host {
        return true;
    }
    if host.parse::<std::net::IpAddr>().is_ok() {
        return false;
    }
    host.ends_with(&format!(".{domain}"))
}

/// Whether a page that finished loading at `url` ends the flow.
pub fn is_done(url: &str, server_origin: &str, left_origin: bool, has_token: bool) -> bool {
    origin_of(url).as_deref() == Some(server_origin) && (has_token || left_origin)
}

/// Opens the sign-in window for `server_url` and resolves when it is done,
/// closed or out of time. `title` is the window's title.
pub fn run_sso(server_url: &str, title: String, cx: &mut App) -> Task<SsoOutcome> {
    let (Some(origin), Some(start)) = (origin_of(server_url), start_url(server_url)) else {
        return Task::ready(SsoOutcome::Failed("not an http(s) server address".into()));
    };
    #[cfg(target_os = "macos")]
    {
        macos::run(origin, start, server_url.to_string(), title, cx)
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = (origin, start, title, cx);
        Task::ready(SsoOutcome::Failed("SSO needs macOS for now".into()))
    }
}

#[cfg(target_os = "macos")]
mod macos {
    use conduit_components::ActiveConduitTheme as _;
    use conduit_components::window::{TOOLBAR_HEIGHT, drag_region, open_window_clear_root};
    use futures::channel::{mpsc, oneshot};
    use futures::{FutureExt as _, StreamExt as _};
    use gpui_kit::prelude::*;
    use gpui_kit::{
        AnyWindowHandle, Bounds, Context, Entity, SharedString, Window, WindowBounds, div, px, size,
    };
    use gpui_webview::WebView;

    use super::*;

    struct SsoWindow {
        title: SharedString,
        webview: Entity<WebView>,
        /// Dropped with the window: that is how closing it cancels.
        _closed: oneshot::Sender<()>,
    }

    impl Render for SsoWindow {
        fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
            let t = cx.conduit().clone();
            div()
                .size_full()
                .flex()
                .flex_col()
                .bg(t.roles.window)
                .child(
                    drag_region("sso-titlebar")
                        .h(px(TOOLBAR_HEIGHT))
                        .flex_none()
                        .flex()
                        .items_center()
                        .justify_center()
                        .text_size(px(t.metrics.control))
                        .text_color(t.roles.text_subtle)
                        .child(self.title.clone()),
                )
                .child(div().flex_1().min_h_0().child(self.webview.clone()))
        }
    }

    pub fn run(
        origin: String,
        start: String,
        server_url: String,
        title: String,
        cx: &mut App,
    ) -> Task<SsoOutcome> {
        let (loads_tx, mut loads) = mpsc::unbounded::<String>();
        // Set by any navigation away from the server, redirects included:
        // a flow that goes through a provider only by redirects never
        // finishes a page there.
        let left = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
        let (left_seen, nav_origin) = (left.clone(), origin.clone());
        let (closed_tx, closed) = oneshot::channel::<()>();
        let bounds = Bounds::centered(None, size(px(520.), px(700.)), cx);
        let mut options = conduit_components::window::window_options(&title, bounds, false, true);
        options.window_bounds = Some(WindowBounds::Windowed(bounds));
        options.window_min_size = Some(size(px(420.), px(480.)));
        let opened = open_window_clear_root(options, cx, |window, cx| {
            let builder = wry::WebViewBuilder::new()
                // A fresh, non-persistent WKWebsiteDataStore: only cookies
                // this flow sets can be read, and none outlive the window.
                .with_incognito(true)
                .with_url(&start)
                .with_navigation_handler(move |url: String| {
                    if super::origin_of(&url).as_deref() != Some(nav_origin.as_str()) {
                        left_seen.store(true, std::sync::atomic::Ordering::Relaxed);
                    }
                    url::Url::parse(&url).is_ok_and(|u| matches!(u.scheme(), "http" | "https"))
                })
                .with_on_page_load_handler(move |event, url: String| {
                    if matches!(event, wry::PageLoadEvent::Finished) {
                        let _ = loads_tx.unbounded_send(url);
                    }
                });
            let webview = cx.new(|cx| {
                WebView::build(builder, window, cx).expect("a WKWebView always builds on macOS")
            });
            cx.new(|_| SsoWindow {
                title: title.clone().into(),
                webview,
                _closed: closed_tx,
            })
        });
        let (handle, view): (AnyWindowHandle, Entity<SsoWindow>) = match opened {
            Ok(opened) => opened,
            Err(e) => return Task::ready(SsoOutcome::Failed(e.to_string())),
        };
        let view = view.downgrade();
        cx.spawn(async move |cx: &mut AsyncApp| {
            let mut closed = closed.fuse();
            let mut timeout = cx.background_executor().timer(SSO_TIMEOUT).fuse();
            let mut left_origin = false;
            let mut script = cx.update(|cx| cx.try_global::<SsoScript>().and_then(|s| s.0.clone()));
            loop {
                let url = futures::select_biased! {
                    _ = closed => return SsoOutcome::Cancelled,
                    _ = timeout => {
                        close(handle, cx);
                        return SsoOutcome::TimedOut;
                    }
                    url = loads.next() => match url {
                        Some(url) => url,
                        None => return SsoOutcome::Cancelled,
                    },
                };
                let at_origin = super::origin_of(&url).as_deref() == Some(origin.as_str());
                log::info!("sso: page loaded (at server: {at_origin})");
                if left.swap(false, std::sync::atomic::Ordering::Relaxed) {
                    left_origin = true;
                }
                if !at_origin {
                    left_origin = true;
                    continue;
                }
                // Read outside any GPUI borrow: wry pumps the run loop while
                // it waits for WKHTTPCookieStore.
                let Ok(webview) = view.read_with(cx, |v, cx| v.webview.read(cx).handle()) else {
                    return SsoOutcome::Cancelled;
                };
                let all = match webview.raw().cookies() {
                    Ok(all) => all,
                    Err(e) => {
                        close(handle, cx);
                        return SsoOutcome::Failed(e.to_string());
                    }
                };
                let cookies = cookies_for_server(
                    all.iter().map(|c| Captured {
                        domain: c.domain(),
                        host_only: host_only(c),
                        secure: c.secure().unwrap_or(false),
                        path: c.path(),
                        name: c.name(),
                        value: c.value(),
                    }),
                    &server_url,
                );
                let token = cookies.get("token").filter(|t| !t.is_empty()).cloned();
                if token.is_none()
                    && let Some(js) = script.take()
                {
                    log::info!("sso: running the test script on the sign-in page");
                    let _ = webview.raw().evaluate_script(&js);
                    // The script signs in from the page and navigates; the
                    // next load at the server is checked again.
                    left_origin = false;
                    continue;
                }
                if is_done(&url, &origin, left_origin, token.is_some()) {
                    log::info!(
                        "sso: done ({} cookies, token: {})",
                        cookies.len(),
                        token.is_some()
                    );
                    close(handle, cx);
                    return SsoOutcome::Captured {
                        origin: origin.clone(),
                        cookies,
                        token,
                    };
                }
            }
        })
    }

    /// Whether WebKit holds `cookie` as host-only: NSHTTPCookie names a
    /// domain cookie's domain with a leading dot, which wry keeps in the
    /// cookie it builds, though `domain()` strips it.
    pub(super) fn host_only(cookie: &wry::cookie::Cookie<'_>) -> bool {
        !format!("{cookie:?}").contains("domain: Some(Concrete(\".")
    }

    fn close(handle: AnyWindowHandle, cx: &mut AsyncApp) {
        let _ = handle.update(cx, |_, window, _| window.remove_window());
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cookie_domains_match_like_a_browser() {
        // Host-only and domain cookies.
        assert!(cookie_matches(Some("chat.example.org"), "chat.example.org"));
        assert!(cookie_matches(Some(".example.org"), "chat.example.org"));
        assert!(cookie_matches(Some("example.org"), "chat.example.org"));
        assert!(cookie_matches(Some("CHAT.Example.org"), "chat.example.org"));
        // Not a suffix on a label boundary, or another site.
        assert!(!cookie_matches(Some("ample.org"), "chat.example.org"));
        assert!(!cookie_matches(Some("other.org"), "chat.example.org"));
        assert!(!cookie_matches(
            Some("sub.chat.example.org"),
            "chat.example.org"
        ));
        // IP hosts match only themselves (cookies_for_url missed these).
        assert!(cookie_matches(Some("192.168.1.10"), "192.168.1.10"));
        assert!(!cookie_matches(Some(".168.1.10"), "192.168.1.10"));
        assert!(cookie_matches(Some("::1"), "[::1]"));
        assert!(!cookie_matches(None, "chat.example.org"));
        assert!(!cookie_matches(Some("."), "chat.example.org"));
    }

    fn c<'a>(domain: &'a str, host_only: bool, name: &'a str, value: &'a str) -> Captured<'a> {
        Captured {
            domain: Some(domain),
            host_only,
            secure: false,
            path: Some("/"),
            name,
            value,
        }
    }

    #[test]
    fn the_more_specific_cookie_wins() {
        let jar = [
            c("chat.example.org", true, "token", "host"),
            c("example.org", false, "token", "parent"),
            c("example.org", false, "_oauth2_proxy", "p"),
            c("evil.org", false, "token", "no"),
        ];
        let got = cookies_for_server(jar, "https://chat.example.org");
        assert_eq!(got.get("token").map(String::as_str), Some("host"));
        assert_eq!(got.get("_oauth2_proxy").map(String::as_str), Some("p"));
        assert_eq!(got.len(), 2);
    }

    #[test]
    fn only_what_a_browser_would_send_the_server_is_taken() {
        // An identity provider on the parent host: its host-only session
        // is never the server's.
        let idp = c("example.org", true, "idp_session", "s");
        let shared = c("example.org", false, "_proxy", "p");
        let got = cookies_for_server([idp, shared.clone()], "https://chat.example.org");
        assert_eq!(got.keys().collect::<Vec<_>>(), vec!["_proxy"]);
        // A Secure cookie never goes to a plain-http server.
        let secure = Captured {
            secure: true,
            ..shared.clone()
        };
        assert!(cookies_for_server([secure.clone()], "http://chat.example.org").is_empty());
        assert_eq!(
            cookies_for_server([secure], "https://chat.example.org").len(),
            1
        );
        // Paths: a provider's token under /idp is not the app's under /owui.
        let jar = [
            Captured {
                path: Some("/idp"),
                ..c("chat.example.org", true, "token", "provider")
            },
            Captured {
                path: Some("/owui"),
                ..c("example.org", false, "token", "owui")
            },
        ];
        let got = cookies_for_server(jar, "https://chat.example.org/owui");
        assert_eq!(got.get("token").map(String::as_str), Some("owui"));
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn a_domain_cookie_is_told_from_a_host_only_one_as_wry_builds_them() {
        let domain = wry::cookie::CookieBuilder::new("a", "1")
            .domain(".example.org")
            .build();
        let host = wry::cookie::CookieBuilder::new("a", "1")
            .domain("example.org")
            .build();
        assert!(!macos::host_only(&domain));
        assert!(macos::host_only(&host));
    }

    #[test]
    fn the_flow_ends_back_on_the_server() {
        let origin = "https://chat.example.org";
        // The sign-in page itself, no token yet: keep going.
        assert!(!is_done(
            "https://chat.example.org/auth",
            origin,
            false,
            false
        ));
        // Back from the identity provider with a session.
        assert!(is_done(
            "https://chat.example.org/auth#token",
            origin,
            true,
            true
        ));
        // A proxy let the user through: the daemon decides.
        assert!(is_done("https://chat.example.org/", origin, true, false));
        // A token already (a trusted-header proxy).
        assert!(is_done("https://chat.example.org/", origin, false, true));
        // Still at the provider.
        assert!(!is_done(
            "https://idp.example.com/login",
            origin,
            true,
            true
        ));
    }

    #[test]
    fn start_urls_keep_a_path_prefix() {
        assert_eq!(
            start_url("https://chat.example.org/").as_deref(),
            Some("https://chat.example.org/auth")
        );
        assert_eq!(
            start_url("http://10.0.0.2:8080/owui").as_deref(),
            Some("http://10.0.0.2:8080/owui/auth")
        );
        assert_eq!(start_url("file:///x"), None);
        // A query stays in the query, a fragment goes.
        assert_eq!(
            start_url("https://chat.example.org/owui?tenant=a#top").as_deref(),
            Some("https://chat.example.org/owui/auth?tenant=a")
        );
        assert_eq!(
            origin_of("http://10.0.0.2:8080/owui/auth").as_deref(),
            Some("http://10.0.0.2:8080")
        );
    }
}
