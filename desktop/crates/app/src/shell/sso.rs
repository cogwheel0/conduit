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
//!
//! A Hermes Desktop Gateway's dashboard sign-in ([`run_hermes_dashboard`])
//! runs in the same window, as the phone's `HermesDashboardAuthPage` runs
//! its WebView: at the dashboard's `/login`, done once a page back on the
//! dashboard (not its sign-in page) has a session the daemon accepts
//! (`hermes.dashboard.complete`, which keeps the cookies and sends the
//! dashboard's requests with them from then on).

use std::collections::BTreeMap;
use std::time::Duration;

use gpui_kit::{App, Task};

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

/// What [`run_hermes_dashboard`] ends with.
#[derive(Clone, Debug, PartialEq)]
pub enum DashboardOutcome {
    /// The daemon took the session; the connections as they are now.
    SignedIn(Option<conduit_protocol::HermesConnections>),
    /// The user closed the window.
    Cancelled,
    TimedOut,
    Failed(String),
}

/// Where the dashboard sign-in window may go, as the phone's
/// `hermesDashboardNavigationTransition`: the dashboard's own pages; an
/// HTTPS identity provider until the flow came back to the dashboard;
/// nothing else after that, so a page on the dashboard cannot walk the
/// window (and its cookies) elsewhere.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct DashboardNav {
    pub left: bool,
    pub returned: bool,
}

impl DashboardNav {
    /// Whether a main-frame navigation to `target` is followed, and the
    /// state after it.
    pub fn step(self, target: &str, origin: &str) -> (bool, Self) {
        let exact = origin_of(target).is_some_and(|o| o.eq_ignore_ascii_case(origin));
        if exact {
            return (
                true,
                Self {
                    left: self.left,
                    returned: self.returned || self.left,
                },
            );
        }
        let https = url::Url::parse(target).is_ok_and(|u| u.scheme() == "https");
        let allowed = !self.returned && https;
        (
            allowed,
            Self {
                left: self.left || allowed,
                returned: self.returned,
            },
        )
    }
}

/// Whether a page that finished loading at `url` may be signed in: on the
/// dashboard's origin and not its sign-in page (the phone's
/// `hermesDashboardShouldCheckSignIn`).
pub fn dashboard_page_signed_in_maybe(url: &str, origin: &str) -> bool {
    let Ok(u) = url::Url::parse(url) else {
        return false;
    };
    origin_of(url).is_some_and(|o| o.eq_ignore_ascii_case(origin)) && !u.path().ends_with("/login")
}

/// Whether cookie `name` holds a dashboard session: `hermes_session_at` or
/// `_rt`, with or without a `__Host-`/`__Secure-` prefix and a gateway's
/// `_<16 hex>` suffix.
pub fn is_dashboard_session_cookie(name: &str) -> bool {
    let bare = name
        .strip_prefix("__Host-")
        .or_else(|| name.strip_prefix("__Secure-"))
        .unwrap_or(name);
    let base = match bare.rsplit_once('_') {
        Some((head, tail))
            if tail.len() == 16
                && tail
                    .bytes()
                    .all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase()) =>
        {
            head
        }
        _ => bare,
    };
    matches!(base, "hermes_session_at" | "hermes_session_rt")
}

/// A Desktop Gateway's dashboard sign-in, as `plan` says (from
/// `hermes.dashboard.start`): a browser window at its `/login`; each page
/// back on the dashboard with a session cookie hands its cookies to the
/// daemon for connection `connection_id`, until the daemon accepts them.
pub fn run_hermes_dashboard(
    plan: conduit_protocol::HermesDashboardPlan,
    connection_id: String,
    connection: Option<String>,
    title: String,
    rpc: crate::stores::rpc::Rpc,
    cx: &mut App,
) -> Task<DashboardOutcome> {
    if origin_of(&plan.login_url).is_none() {
        return Task::ready(DashboardOutcome::Failed(
            "not an http(s) server address".into(),
        ));
    }
    #[cfg(target_os = "macos")]
    {
        macos::run_hermes_dashboard(plan, connection_id, connection, title, rpc, cx)
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = (plan, connection_id, connection, title, rpc, cx);
        Task::ready(DashboardOutcome::Failed("needs macOS for now".into()))
    }
}

/// What the LibreChat sign-in window does with one navigation (the core's
/// `libreChatSsoNavigation`, which the phone's web view follows too; the
/// window must decide inside WebKit's navigation callback, so it is read
/// here, from the daemon's [`LibreChatSsoPlan`]).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LibreChatNav {
    /// The provider's pages, and LibreChat's own sign-in routes.
    Allow,
    /// LibreChat's OAuth callback: the provider sent the browser back, and
    /// this response sets the session. It loads.
    ProviderReturned,
    /// A page of LibreChat's outside its sign-in routes: once the provider
    /// has returned, the sign-in finished, and this hop to its web app is
    /// cancelled (the web app would renew the session and rotate its
    /// cookie).
    AppPage,
    /// LibreChat sent the browser back to its sign-in page with an error.
    Fail,
}

/// [`LibreChatNav`] for `url` on a server at `origins` under `base_path`.
pub fn librechat_nav(url: &str, origins: &[String], base_path: &str) -> LibreChatNav {
    let Ok(u) = url::Url::parse(url) else {
        return LibreChatNav::Allow;
    };
    let origin = u.origin().ascii_serialization();
    if !origins.iter().any(|o| o.eq_ignore_ascii_case(&origin)) {
        return LibreChatNav::Allow;
    }
    let base = base_path.trim_end_matches('/');
    let mut path = u.path();
    if !base.is_empty() && (path == base || path.starts_with(&format!("{base}/"))) {
        path = &path[base.len()..];
    }
    let segments: Vec<&str> = path.split('/').filter(|s| !s.is_empty()).collect();
    if let Some(oauth) = segments.iter().rposition(|s| *s == "oauth")
        && oauth + 3 == segments.len()
        && segments.last() == Some(&"callback")
    {
        return LibreChatNav::ProviderReturned;
    }
    if segments.contains(&"oauth") || segments.contains(&"api") {
        return LibreChatNav::Allow;
    }
    if segments.last() == Some(&"login") && u.query_pairs().any(|(k, _)| k == "error") {
        return LibreChatNav::Fail;
    }
    LibreChatNav::AppPage
}

/// Single sign-on to a LibreChat server, as `plan` says (from
/// `librechat.ssoStart`): a browser window at its `/oauth/{provider}`,
/// stopped at the hop to its web app, and the cookies of its
/// `cookie_url` handed back for `librechat.completeSso`.
pub fn run_librechat_sso(
    plan: conduit_protocol::LibreChatSsoPlan,
    title: String,
    cx: &mut App,
) -> Task<SsoOutcome> {
    if origin_of(&plan.start_url).is_none() {
        return Task::ready(SsoOutcome::Failed("not an http(s) server address".into()));
    }
    #[cfg(target_os = "macos")]
    {
        macos::run_librechat(plan, title, cx)
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = (plan, title, cx);
        Task::ready(SsoOutcome::Failed("SSO needs macOS for now".into()))
    }
}

/// Whether `url` is one of Open WebUI's own sign-in pages on the server at
/// `server_url` (under its path prefix): `/auth`, `/auth/…`, `/oauth/…` or
/// `/api/v1/auths/…`, as the phone's proxy sign-in reads it
/// (`isKnownOpenWebUiProxyAuthPath`). Reaching one means a sign-in proxy in
/// front of the server let the window through.
pub fn is_open_webui_auth_page(url: &str, server_url: &str) -> bool {
    let (Ok(page), Ok(server)) = (url::Url::parse(url), url::Url::parse(server_url)) else {
        return false;
    };
    if page.origin() != server.origin() {
        return false;
    }
    let prefix = server.path().trim_end_matches('/');
    let path = page.path().to_ascii_lowercase();
    let Some(path) = path.strip_prefix(&prefix.to_ascii_lowercase()) else {
        return false;
    };
    path == "/auth"
        || path.starts_with("/auth/")
        || path.contains("/oauth/")
        || path.contains("/api/v1/auths/")
}

/// Opens the sign-in window for `server_url` and resolves when it is done,
/// closed or out of time. `title` is the window's title.
pub fn run_sso(server_url: &str, title: String, cx: &mut App) -> Task<SsoOutcome> {
    run_sign_in_window(server_url, title, false, cx)
}

/// The sign-in window again for a sign-in proxy whose session expired: done
/// as soon as the proxy lets it through to Open WebUI's own sign-in page,
/// with the proxy's new cookies (and Open WebUI's token, if it signed in
/// there too).
pub fn run_proxy_sso(server_url: &str, title: String, cx: &mut App) -> Task<SsoOutcome> {
    run_sign_in_window(server_url, title, true, cx)
}

fn run_sign_in_window(
    server_url: &str,
    title: String,
    proxy: bool,
    cx: &mut App,
) -> Task<SsoOutcome> {
    let (Some(origin), Some(start)) = (origin_of(server_url), start_url(server_url)) else {
        return Task::ready(SsoOutcome::Failed("not an http(s) server address".into()));
    };
    #[cfg(target_os = "macos")]
    {
        macos::run(origin, start, server_url.to_string(), title, proxy, cx)
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = (origin, start, title, proxy, cx);
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
        AnyWindowHandle, AsyncApp, Bounds, Context, Entity, SharedString, Window, WindowBounds,
        div, px, size,
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

    /// `proxy`: the window renews a sign-in proxy's session
    /// ([`super::run_proxy_sso`]) and is done once the proxy lets it through.
    pub fn run(
        origin: String,
        start: String,
        server_url: String,
        title: String,
        proxy: bool,
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
                let webview = WebView::build(builder, window, cx)
                    .expect("a WKWebView always builds on macOS");
                crate::shell::web_media::guard(webview.raw());
                webview
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
                let through_proxy = proxy
                    && !cookies.is_empty()
                    && super::is_open_webui_auth_page(&url, &server_url);
                if through_proxy || is_done(&url, &origin, left_origin, token.is_some()) {
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

    /// `cookie` as the daemon takes it: a domain cookie's domain keeps its
    /// leading dot ([`host_only`]), so a session set for a parent domain
    /// (`Domain=example.org`) is still sent to the gateway's host.
    pub(super) fn dashboard_cookie(
        cookie: &wry::cookie::Cookie<'_>,
        host: &str,
    ) -> conduit_protocol::HermesCookieDto {
        let domain = cookie.domain().unwrap_or(host);
        conduit_protocol::HermesCookieDto {
            name: cookie.name().to_string(),
            value: cookie.value().to_string(),
            domain: if host_only(cookie) {
                domain.to_string()
            } else {
                format!(".{domain}")
            },
            path: cookie.path().unwrap_or("/").to_string(),
            secure: cookie.secure().unwrap_or(false),
            http_only: cookie.http_only().unwrap_or(false),
            expires_ms: cookie.expires_datetime().map(|t| t.unix_timestamp() * 1000),
        }
    }

    /// What the LibreChat window's navigation callback tells the flow.
    enum LibreChatSignal {
        Loaded,
        Finished,
        Failed,
    }

    pub fn run_librechat(
        plan: conduit_protocol::LibreChatSsoPlan,
        title: String,
        cx: &mut App,
    ) -> Task<SsoOutcome> {
        use std::sync::Arc;
        use std::sync::atomic::{AtomicBool, Ordering};

        let (signals_tx, mut signals) = mpsc::unbounded::<LibreChatSignal>();
        let (closed_tx, closed) = oneshot::channel::<()>();
        let returned = Arc::new(AtomicBool::new(false));
        let bounds = Bounds::centered(None, size(px(520.), px(700.)), cx);
        let mut options = conduit_components::window::window_options(&title, bounds, false, true);
        options.window_bounds = Some(WindowBounds::Windowed(bounds));
        options.window_min_size = Some(size(px(420.), px(480.)));
        let origins = plan.server_origins.clone();
        let base_path = plan.base_path.clone();
        let start = plan.start_url.clone();
        let opened = open_window_clear_root(options, cx, |window, cx| {
            let nav_tx = signals_tx.clone();
            let load_tx = signals_tx.clone();
            let returned = returned.clone();
            let builder = wry::WebViewBuilder::new()
                // A fresh, non-persistent store: no earlier sign-in's cookies
                // can sign this one in, and none outlive the window.
                .with_incognito(true)
                .with_url(&start)
                .with_navigation_handler(move |url: String| {
                    if !url::Url::parse(&url).is_ok_and(|u| matches!(u.scheme(), "http" | "https"))
                    {
                        return false;
                    }
                    match super::librechat_nav(&url, &origins, &base_path) {
                        LibreChatNav::Allow => true,
                        LibreChatNav::ProviderReturned => {
                            returned.store(true, Ordering::SeqCst);
                            true
                        }
                        LibreChatNav::AppPage => {
                            if returned.load(Ordering::SeqCst) {
                                let _ = nav_tx.unbounded_send(LibreChatSignal::Finished);
                                false
                            } else {
                                true
                            }
                        }
                        LibreChatNav::Fail => {
                            let _ = nav_tx.unbounded_send(LibreChatSignal::Failed);
                            false
                        }
                    }
                })
                .with_on_page_load_handler(move |event, url: String| {
                    if matches!(event, wry::PageLoadEvent::Finished) {
                        let _ = (url, load_tx.unbounded_send(LibreChatSignal::Loaded));
                    }
                });
            let webview = cx.new(|cx| {
                let webview = WebView::build(builder, window, cx)
                    .expect("a WKWebView always builds on macOS");
                crate::shell::web_media::guard(webview.raw());
                webview
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
        let cookie_url = plan.cookie_url.clone();
        let origin = plan
            .server_origins
            .first()
            .cloned()
            .unwrap_or_else(|| super::origin_of(&plan.start_url).unwrap_or_default());
        cx.spawn(async move |cx: &mut AsyncApp| {
            let mut closed = closed.fuse();
            let mut timeout = cx.background_executor().timer(SSO_TIMEOUT).fuse();
            let mut script = cx.update(|cx| cx.try_global::<SsoScript>().and_then(|s| s.0.clone()));
            loop {
                let signal = futures::select_biased! {
                    _ = closed => return SsoOutcome::Cancelled,
                    _ = timeout => {
                        close(handle, cx);
                        return SsoOutcome::TimedOut;
                    }
                    signal = signals.next() => match signal {
                        Some(signal) => signal,
                        None => return SsoOutcome::Cancelled,
                    },
                };
                match signal {
                    LibreChatSignal::Loaded => {
                        // The test hook stands in for the user at the
                        // provider's page, once.
                        if let Some(js) = script.take() {
                            let Ok(webview) =
                                view.read_with(cx, |v, cx| v.webview.read(cx).handle())
                            else {
                                return SsoOutcome::Cancelled;
                            };
                            log::info!("sso: running the test script on the provider's page");
                            let _ = webview.raw().evaluate_script(&js);
                        }
                    }
                    LibreChatSignal::Failed => {
                        close(handle, cx);
                        return SsoOutcome::Failed("the server refused the sign-in".into());
                    }
                    LibreChatSignal::Finished => {
                        // Read outside any GPUI borrow: wry pumps the run
                        // loop while it waits for WKHTTPCookieStore.
                        let Ok(webview) = view.read_with(cx, |v, cx| v.webview.read(cx).handle())
                        else {
                            return SsoOutcome::Cancelled;
                        };
                        let all = match webview.raw().cookies() {
                            Ok(all) => all,
                            Err(e) => {
                                close(handle, cx);
                                return SsoOutcome::Failed(e.to_string());
                            }
                        };
                        // Those a browser would send to the LibreChat server
                        // (RFC 6265), as for Open WebUI.
                        let cookies = cookies_for_server(
                            all.iter().map(|c| Captured {
                                domain: c.domain(),
                                host_only: host_only(c),
                                secure: c.secure().unwrap_or(false),
                                path: c.path(),
                                name: c.name(),
                                value: c.value(),
                            }),
                            &cookie_url,
                        );
                        log::info!(
                            "sso: LibreChat sign-in finished ({} cookies)",
                            cookies.len()
                        );
                        close(handle, cx);
                        return SsoOutcome::Captured {
                            origin: origin.clone(),
                            cookies,
                            token: None,
                        };
                    }
                }
            }
        })
    }

    pub fn run_hermes_dashboard(
        plan: conduit_protocol::HermesDashboardPlan,
        connection_id: String,
        connection: Option<String>,
        title: String,
        rpc: crate::stores::rpc::Rpc,
        cx: &mut App,
    ) -> Task<DashboardOutcome> {
        use std::sync::{Arc, Mutex};

        use conduit_protocol::{
            HermesCookieDto, HermesDashboardCancel, HermesDashboardCookies, methods,
        };
        use std::sync::atomic::{AtomicU64, Ordering};

        // This window's sign-in: closing it cancels what it still asks.
        static ATTEMPTS: AtomicU64 = AtomicU64::new(0);
        let attempt = format!("dashboard-{}", ATTEMPTS.fetch_add(1, Ordering::Relaxed) + 1);

        let (loads_tx, mut loads) = mpsc::unbounded::<String>();
        let (closed_tx, closed) = oneshot::channel::<()>();
        let bounds = Bounds::centered(None, size(px(520.), px(700.)), cx);
        let mut options = conduit_components::window::window_options(&title, bounds, false, true);
        options.window_bounds = Some(WindowBounds::Windowed(bounds));
        options.window_min_size = Some(size(px(420.), px(480.)));
        let origin = plan.origin.clone();
        let nav = Arc::new(Mutex::new(DashboardNav::default()));
        let opened = open_window_clear_root(options, cx, |window, cx| {
            let nav_origin = origin.clone();
            let builder = wry::WebViewBuilder::new()
                // A fresh, non-persistent store: no earlier sign-in's
                // cookies can sign this one in, and none outlive the window
                // (the daemon keeps the session it is handed).
                .with_incognito(true)
                .with_url(&plan.login_url)
                .with_navigation_handler(move |url: String| {
                    if !url::Url::parse(&url).is_ok_and(|u| matches!(u.scheme(), "http" | "https"))
                    {
                        return false;
                    }
                    let Ok(mut state) = nav.lock() else {
                        return false;
                    };
                    let (allowed, next) = state.step(&url, &nav_origin);
                    *state = next;
                    allowed
                })
                .with_on_page_load_handler(move |event, url: String| {
                    if matches!(event, wry::PageLoadEvent::Finished) {
                        let _ = loads_tx.unbounded_send(url);
                    }
                });
            let webview = cx.new(|cx| {
                let webview = WebView::build(builder, window, cx)
                    .expect("a WKWebView always builds on macOS");
                crate::shell::web_media::guard(webview.raw());
                webview
            });
            cx.new(|_| SsoWindow {
                title: title.clone().into(),
                webview,
                _closed: closed_tx,
            })
        });
        let (handle, view): (AnyWindowHandle, Entity<SsoWindow>) = match opened {
            Ok(opened) => opened,
            Err(e) => return Task::ready(DashboardOutcome::Failed(e.to_string())),
        };
        let view = view.downgrade();
        let host = url::Url::parse(&origin)
            .ok()
            .and_then(|u| u.host_str().map(str::to_string))
            .unwrap_or_default();
        cx.spawn(async move |cx: &mut AsyncApp| {
            let mut closed = closed.fuse();
            let mut timeout = cx.background_executor().timer(SSO_TIMEOUT).fuse();
            let mut script = cx.update(|cx| cx.try_global::<SsoScript>().and_then(|s| s.0.clone()));
            loop {
                let url = futures::select_biased! {
                    _ = closed => return DashboardOutcome::Cancelled,
                    _ = timeout => {
                        close(handle, cx);
                        return DashboardOutcome::TimedOut;
                    }
                    url = loads.next() => match url {
                        Some(url) => url,
                        None => return DashboardOutcome::Cancelled,
                    },
                };
                let at_origin =
                    super::origin_of(&url).is_some_and(|o| o.eq_ignore_ascii_case(&origin));
                log::info!("hermes dashboard: page loaded (at dashboard: {at_origin})");
                let Ok(webview) = view.read_with(cx, |v, cx| v.webview.read(cx).handle()) else {
                    return DashboardOutcome::Cancelled;
                };
                if !super::dashboard_page_signed_in_maybe(&url, &origin) {
                    // The test hook stands in for the user on the sign-in
                    // page, once.
                    if at_origin && let Some(js) = script.take() {
                        log::info!("hermes dashboard: running the test script on the sign-in page");
                        let _ = webview.raw().evaluate_script(&js);
                    }
                    continue;
                }
                // Read outside any GPUI borrow: wry pumps the run loop while
                // it waits for WKHTTPCookieStore.
                let all = match webview.raw().cookies() {
                    Ok(all) => all,
                    Err(e) => {
                        close(handle, cx);
                        return DashboardOutcome::Failed(e.to_string());
                    }
                };
                let cookies: Vec<HermesCookieDto> = all
                    .iter()
                    .filter(|c| cookie_matches(c.domain(), &host))
                    .map(|c| dashboard_cookie(c, &host))
                    .collect();
                if !cookies
                    .iter()
                    .any(|c| super::is_dashboard_session_cookie(&c.name))
                {
                    continue;
                }
                // For the connection the sign-in started under: refused once
                // another is in use.
                let call = rpc
                    .call::<methods::HermesDashboardComplete>(&HermesDashboardCookies {
                        id: connection_id.clone(),
                        cookies,
                        connection: connection.clone(),
                        attempt: Some(attempt.clone()),
                    })
                    .fuse();
                futures::pin_mut!(call);
                // Closed (or out of time) while the daemon checks the
                // session: the sign-in is cancelled, and the daemon keeps
                // nothing it has not kept already. What it says then is
                // the outcome: signed in only if it kept the session first.
                let ended = futures::select_biased! {
                    answer = call => Ok(answer),
                    _ = closed => Err(DashboardOutcome::Cancelled),
                    _ = timeout => Err(DashboardOutcome::TimedOut),
                };
                let answer = match ended {
                    Ok(answer) => answer,
                    Err(outcome) => {
                        let cancel =
                            rpc.call::<methods::HermesDashboardCancel>(&HermesDashboardCancel {
                                attempt: attempt.clone(),
                            });
                        let _ = cancel.await;
                        close(handle, cx);
                        return match call.await {
                            Ok(result) if result.signed_in => {
                                DashboardOutcome::SignedIn(result.connections)
                            }
                            _ => outcome,
                        };
                    }
                };
                match answer {
                    Ok(result) if result.signed_in => {
                        log::info!("hermes dashboard: signed in");
                        close(handle, cx);
                        return DashboardOutcome::SignedIn(result.connections);
                    }
                    Ok(_) => log::info!("hermes dashboard: not signed in yet"),
                    Err(e) => {
                        close(handle, cx);
                        return DashboardOutcome::Failed(e.to_string());
                    }
                }
            }
        })
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

    #[cfg(target_os = "macos")]
    #[test]
    fn a_parent_domain_session_reaches_the_daemon_as_a_domain_cookie() {
        let parent = wry::cookie::CookieBuilder::new("hermes_session_at", "1")
            .domain(".example.org")
            .build();
        let own = wry::cookie::CookieBuilder::new("hermes_session_at", "1")
            .domain("agent.example.org")
            .build();
        assert_eq!(
            macos::dashboard_cookie(&parent, "agent.example.org").domain,
            ".example.org"
        );
        assert_eq!(
            macos::dashboard_cookie(&own, "agent.example.org").domain,
            "agent.example.org"
        );
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
    fn librechat_navigations_read_as_the_core_reads_them() {
        let origins = vec!["https://chat.example.com".to_string()];
        let nav = |url: &str| librechat_nav(url, &origins, "");
        // The provider's own pages, and LibreChat's sign-in routes.
        assert_eq!(
            nav("https://idp.example.org/authorize"),
            LibreChatNav::Allow
        );
        assert_eq!(
            nav("https://chat.example.com/oauth/openid"),
            LibreChatNav::Allow
        );
        assert_eq!(
            nav("https://chat.example.com/api/auth/refresh"),
            LibreChatNav::Allow
        );
        // Back from the provider.
        assert_eq!(
            nav("https://chat.example.com/oauth/openid/callback?code=x"),
            LibreChatNav::ProviderReturned
        );
        // The web app, and its sign-in page with an error.
        assert_eq!(nav("https://chat.example.com/c/new"), LibreChatNav::AppPage);
        assert_eq!(nav("https://chat.example.com/"), LibreChatNav::AppPage);
        assert_eq!(
            nav("https://chat.example.com/login?error=auth_failed"),
            LibreChatNav::Fail
        );
        assert_eq!(nav("https://chat.example.com/login"), LibreChatNav::AppPage);
        // Another port is another origin.
        assert_eq!(
            nav("https://chat.example.com:8443/c/new"),
            LibreChatNav::Allow
        );
    }

    #[test]
    fn a_librechat_server_under_a_path_keeps_its_routes() {
        let origins = vec!["https://example.com".to_string()];
        let nav = |url: &str| librechat_nav(url, &origins, "/oauth/librechat");
        // Its web app under `/oauth/librechat` is not an OAuth route.
        assert_eq!(
            nav("https://example.com/oauth/librechat/c/new"),
            LibreChatNav::AppPage
        );
        assert_eq!(
            nav("https://example.com/oauth/librechat/oauth/github/callback"),
            LibreChatNav::ProviderReturned
        );
    }

    #[test]
    fn a_proxy_lets_the_window_through_to_open_webuis_sign_in() {
        let server = "https://chat.example.org";
        for page in [
            "https://chat.example.org/auth",
            "https://chat.example.org/auth?redirect=%2F",
            "https://chat.example.org/auth/",
            "https://chat.example.org/oauth/oidc/callback",
            "https://chat.example.org/api/v1/auths/",
        ] {
            assert!(is_open_webui_auth_page(page, server), "{page}");
        }
        for page in [
            "https://chat.example.org/",
            "https://chat.example.org/oauth2/sign_in",
            "https://login.example.org/auth",
            "http://chat.example.org/auth",
            "not a url",
        ] {
            assert!(!is_open_webui_auth_page(page, server), "{page}");
        }
        // Under a path prefix.
        assert!(is_open_webui_auth_page(
            "https://example.org/owui/auth",
            "https://example.org/owui/"
        ));
        assert!(!is_open_webui_auth_page(
            "https://example.org/auth",
            "https://example.org/owui"
        ));
    }

    #[test]
    fn the_dashboard_window_goes_where_the_phones_does() {
        let origin = "http://127.0.0.1:8642";
        let start = DashboardNav::default();
        // The dashboard's own pages.
        let (ok, s) = start.step("http://127.0.0.1:8642/login", origin);
        assert!(ok);
        assert_eq!(s, start);
        // Out to an HTTPS identity provider once, and back.
        let (ok, s) = s.step("https://idp.example.org/authorize", origin);
        assert!(ok);
        assert!(s.left && !s.returned);
        let (ok, s) = s.step("http://127.0.0.1:8642/auth/callback", origin);
        assert!(ok);
        assert!(s.returned);
        // Never out again, and never to plain HTTP elsewhere.
        assert!(!s.step("https://idp.example.org/again", origin).0);
        assert!(!start.step("http://evil.example/", origin).0);
        // Another port is another origin.
        assert!(!start.step("http://127.0.0.1:9000/", origin).0);
    }

    #[test]
    fn a_signed_in_page_is_one_back_on_the_dashboard() {
        let origin = "https://agent.example.org";
        assert!(dashboard_page_signed_in_maybe(
            "https://agent.example.org/",
            origin
        ));
        assert!(dashboard_page_signed_in_maybe(
            "https://agent.example.org/sessions",
            origin
        ));
        assert!(!dashboard_page_signed_in_maybe(
            "https://agent.example.org/login?next=/",
            origin
        ));
        assert!(!dashboard_page_signed_in_maybe(
            "https://idp.example.org/",
            origin
        ));
    }

    #[test]
    fn dashboard_session_cookies_by_their_base_name() {
        assert!(is_dashboard_session_cookie("hermes_session_at"));
        assert!(is_dashboard_session_cookie("__Host-hermes_session_rt"));
        assert!(is_dashboard_session_cookie(
            "__Secure-hermes_session_at_0123456789abcdef"
        ));
        assert!(!is_dashboard_session_cookie("hermes_session_provider"));
        assert!(!is_dashboard_session_cookie("hermes_session_at_XYZ"));
        assert!(!is_dashboard_session_cookie("token"));
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
