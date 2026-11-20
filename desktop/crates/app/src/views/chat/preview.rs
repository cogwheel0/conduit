//! Preview for html, svg, mermaid and chart code blocks: a `gpui-webview`
//! (WKWebView) window that cannot reach the network.
//!
//! * The page is built here ([`preview_document`]) and loaded as a string
//!   into a non-persistent (incognito) store.
//! * Its Content-Security-Policy allows inline scripts and styles and
//!   `data:`/`blob:` images and fonts, and nothing else: no fetches, no
//!   remote scripts, frames, forms or base URLs.
//! * Model-written HTML runs inside an `<iframe sandbox="allow-scripts"
//!   srcdoc>`: an opaque origin with no same-origin access, top
//!   navigation, popups or forms, which inherits the page's policy.
//! * Mermaid and Chart.js are bundled (`assets/preview`, and the repo's
//!   `assets/chartjs.min.js`), never loaded from a CDN.
//! * Every navigation away from the document is refused, and so are new
//!   windows.
//!
//! The window's toolbar names what it previews and, under that, the chat it
//! came from (a window subtitle), and offers Copy Code, Save… (the block as
//! a file: `.html`, `.mmd` or `.json`) and Open in Browser (the same
//! sandboxed page, written to a temporary file).

use gpui_kit::{App, Window};

/// mermaid 12.2.0, pinned by its SHA-256 in `assets/preview/README.md`.
/// The inline diagram renderer ([`super::diagram`]) uses this copy too.
/// Statics, not consts: a const's 5.5 MB literal is copied into each
/// codegen unit that uses it, and the binary carried it twice.
pub(crate) static MERMAID_JS: &str = include_str!("../../../assets/preview/mermaid.min.js");
/// Chart.js 4.5.0, the copy the mobile app ships.
pub(crate) static CHART_JS: &str = include_str!("../../../../../../assets/chartjs.min.js");

/// The policy every preview page carries.
pub const CSP: &str = "default-src 'none'; script-src 'unsafe-inline'; \
    style-src 'unsafe-inline'; img-src data: blob:; font-src data:; \
    media-src data: blob:; frame-src 'self' about:; child-src 'self' about:; \
    connect-src 'none'; form-action 'none'; base-uri 'none'";

/// What a code block previews as.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PreviewKind {
    Html,
    Mermaid,
    Chart,
}

pub fn preview_kind(lang: &str) -> Option<PreviewKind> {
    match lang.to_ascii_lowercase().as_str() {
        "html" | "htm" | "svg" | "xml" => Some(PreviewKind::Html),
        "mermaid" | "mmd" => Some(PreviewKind::Mermaid),
        "chart" | "chartjs" | "chart.js" => Some(PreviewKind::Chart),
        _ => None,
    }
}

/// Escapes text for an HTML attribute or element body.
pub fn escape_html(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 16);
    for c in s.chars() {
        match c {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            '\'' => out.push_str("&#39;"),
            _ => out.push(c),
        }
    }
    out
}

/// A script's text, safe inside `<script>`: only `</script` (any case)
/// ends the element, so only that is escaped. Escaping every `</` would
/// break regex literals such as `/^</` in the bundles.
fn script_safe(s: &str) -> String {
    let lower = s.to_ascii_lowercase();
    let mut out = String::with_capacity(s.len());
    let mut last = 0;
    for (at, _) in lower.match_indices("</script") {
        out.push_str(&s[last..at]);
        out.push_str("<\\/");
        last = at + 2;
    }
    out.push_str(&s[last..]);
    out
}

/// The window's colours, for the page: the app's content frame, its text,
/// and the greys a diagram is drawn in. Opaque `#RRGGBB`.
#[derive(Clone, Debug, PartialEq)]
pub struct PreviewTheme {
    pub dark: bool,
    pub background: String,
    pub text: String,
    /// Lines, borders and arrows.
    pub line: String,
    /// Node fills.
    pub fill: String,
    pub fill_alt: String,
}

impl PreviewTheme {
    /// From the active theme, so a preview matches the window it came from.
    pub fn from_theme(t: &conduit_components::theme::ConduitTheme) -> Self {
        use conduit_components::theme::{composite, mix};
        let r = t.roles;
        let hex = |c: gpui_kit::Hsla| {
            let mut h = conduit_components::theme::palette::to_hex(composite(c, r.content));
            h.truncate(7);
            h
        };
        Self {
            dark: t.dark,
            background: hex(r.content),
            text: hex(r.text),
            line: hex(r.text_subtle),
            fill: hex(mix(r.content, r.text, if t.dark { 0.12 } else { 0.05 })),
            fill_alt: hex(mix(r.content, r.text, if t.dark { 0.2 } else { 0.1 })),
        }
    }

    /// Plain black-on-white or white-on-black (tests and fallbacks).
    pub fn plain(dark: bool) -> Self {
        let s = |v: &str| v.to_string();
        if dark {
            Self {
                dark,
                background: s("#000000"),
                text: s("#ececec"),
                line: s("#9595a6"),
                fill: s("#1c1c1c"),
                fill_alt: s("#2f2f2f"),
            }
        } else {
            Self {
                dark,
                background: s("#ffffff"),
                text: s("#000000"),
                line: s("#6a6a7c"),
                fill: s("#f2f2f2"),
                fill_alt: s("#e6e6e6"),
            }
        }
    }

    fn scheme(&self) -> &'static str {
        if self.dark { "dark" } else { "light" }
    }
}

fn page(theme: &PreviewTheme, head: &str, body: &str) -> String {
    let (bg, fg, scheme) = (&theme.background, &theme.text, theme.scheme());
    format!(
        "<!doctype html><html><head><meta charset=\"utf-8\">\
         <meta http-equiv=\"Content-Security-Policy\" content=\"{CSP}\">\
         <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\
         <meta name=\"color-scheme\" content=\"{scheme}\">\
         <style>html,body{{margin:0;height:100%;background:{bg};color:{fg};\
         color-scheme:{scheme};font-family:-apple-system,BlinkMacSystemFont,sans-serif}}\
         iframe{{border:0;width:100%;height:100%;display:block;background:{bg}}}\
         .wrap{{padding:20px;box-sizing:border-box;min-height:100%;display:flex;\
         align-items:center;justify-content:center}}\
         .error{{color:#d33;white-space:pre-wrap;font:13px ui-monospace,monospace}}</style>\
         {head}</head><body>{body}</body></html>"
    )
}

/// `snippet` placed at the start of `html`'s head: after `<head>` when it
/// has one, else after `<html>`, else after a doctype, else first.
fn into_head(html: &str, snippet: &str) -> String {
    let lower = html.to_ascii_lowercase();
    let after_tag = |tag: &str| -> Option<usize> {
        let mut from = 0;
        while let Some(at) = lower[from..].find(tag).map(|i| i + from) {
            let next = lower[at + tag.len()..].chars().next();
            if matches!(next, Some('>') | Some(' ') | Some('\n') | Some('\t')) {
                return lower[at..].find('>').map(|end| at + end + 1);
            }
            from = at + tag.len();
        }
        None
    };
    let at = after_tag("<head")
        .or_else(|| after_tag("<html"))
        .or_else(|| {
            lower
                .trim_start()
                .starts_with("<!doctype")
                .then(|| lower.find('>').map(|e| e + 1))
                .flatten()
        })
        .unwrap_or(0);
    format!("{}{snippet}{}", &html[..at], &html[at..])
}

/// The page that previews `code` as `kind`.
pub fn preview_document(kind: PreviewKind, code: &str, theme: &PreviewTheme) -> String {
    let dark = theme.dark;
    match kind {
        PreviewKind::Html => {
            // The page's own colours win; one that sets none follows the
            // window's mode, as Safari's Reader does.
            let mut head = format!(
                "<meta name=\"color-scheme\" content=\"{scheme}\">\
                 <style>:root{{color-scheme:{scheme}}}\
                 html{{background:{bg};color:{fg}}}</style>",
                scheme = theme.scheme(),
                bg = theme.background,
                fg = theme.text,
            );
            // Chart.js is offered to pages that use it (its CDN is blocked).
            if code.contains("Chart") || code.contains("chart.js") {
                head.push_str(&format!("<script>{}</script>", script_safe(CHART_JS)));
            }
            let inner = into_head(code, &head);
            page(
                theme,
                "",
                &format!(
                    "<iframe sandbox=\"allow-scripts\" srcdoc=\"{}\"></iframe>",
                    escape_html(&inner)
                ),
            )
        }
        // Monochrome, in the window's own greys: Mermaid's `base` theme
        // with every colour set, so no default lavender shows through.
        PreviewKind::Mermaid => page(
            theme,
            &format!("<script>{}</script>", script_safe(MERMAID_JS)),
            &format!(
                "<div class=\"wrap\"><pre class=\"mermaid\">{code}</pre></div>\
                 <script>try{{mermaid.initialize({{startOnLoad:true,\
                 securityLevel:'strict',theme:'base',themeVariables:{{\
                 darkMode:{dark},background:'{bg}',fontFamily:'-apple-system,\
                 BlinkMacSystemFont,sans-serif',fontSize:'14px',\
                 primaryColor:'{fill}',primaryTextColor:'{fg}',\
                 primaryBorderColor:'{line}',secondaryColor:'{alt}',\
                 secondaryTextColor:'{fg}',secondaryBorderColor:'{line}',\
                 tertiaryColor:'{alt}',tertiaryTextColor:'{fg}',\
                 tertiaryBorderColor:'{line}',lineColor:'{line}',textColor:'{fg}',\
                 mainBkg:'{fill}',nodeBorder:'{line}',clusterBkg:'{alt}',\
                 clusterBorder:'{line}',edgeLabelBackground:'{bg}',\
                 titleColor:'{fg}',noteBkgColor:'{alt}',noteTextColor:'{fg}',\
                 noteBorderColor:'{line}',actorBkg:'{fill}',actorBorder:'{line}',\
                 actorTextColor:'{fg}',signalColor:'{fg}',signalTextColor:'{fg}',\
                 labelBoxBkgColor:'{fill}',labelBoxBorderColor:'{line}',\
                 labelTextColor:'{fg}'}}}});}}catch(e){{\
                 document.body.innerHTML='<p class=error></p>';\
                 document.querySelector('.error').textContent=String(e);}}</script>",
                code = escape_html(code),
                bg = theme.background,
                fg = theme.text,
                line = theme.line,
                fill = theme.fill,
                alt = theme.fill_alt,
            ),
        ),
        PreviewKind::Chart => {
            // A Chart.js config as JSON, or a script that draws into
            // `#chart`.
            let run = if serde_json::from_str::<serde_json::Value>(code).is_ok() {
                format!(
                    "new Chart(document.getElementById('chart'),{});",
                    script_safe(code)
                )
            } else {
                script_safe(code)
            };
            let inner = page(
                theme,
                &format!("<script>{}</script>", script_safe(CHART_JS)),
                &format!(
                    "<div class=\"wrap\"><canvas id=\"chart\"></canvas></div>\
                     <script>(function(){{var g=document.getElementById.bind(document);\
                     document.getElementById=function(i){{return g(i)||g('chart');}};\
                     try{{{run}}}catch(e){{var p=document.createElement('p');\
                     p.className='error';p.textContent=String(e);\
                     document.body.appendChild(p);}}}})();</script>"
                ),
            );
            // The model's code runs in the sandboxed frame, as HTML's does:
            // it cannot navigate the page, open windows or reach the
            // network, in the window or in a browser (Open in Browser).
            page(
                theme,
                "",
                &format!(
                    "<iframe sandbox=\"allow-scripts\" srcdoc=\"{}\"></iframe>",
                    escape_html(&inner)
                ),
            )
        }
    }
}

/// An embed's reported height is kept in these bounds (the phone's
/// `kWebEmbedMinHeight`/`kWebEmbedMaxHeight`), and starts at the default.
pub const EMBED_MIN_HEIGHT: f32 = 220.;
pub const EMBED_MAX_HEIGHT: f32 = 900.;
pub const EMBED_DEFAULT_HEIGHT: f32 = 360.;

/// A string as a JavaScript literal that cannot close a `<script>` or start
/// markup inside one (the core's `jsonForInlineScript`).
pub fn js_string(value: &str) -> String {
    serde_json::to_string(value)
        .unwrap_or_else(|_| "\"\"".into())
        .replace('&', "\\u0026")
        .replace('<', "\\u003C")
        .replace('>', "\\u003E")
}

/// What an embedded page tells its host, from every frame (the phone's
/// `webEmbedAllFrameBootstrapScript`): its height, and a link the user
/// clicked, which opens in the browser rather than in the frame. The
/// height is the content's, measured from the body: the document's own
/// scroll height is never less than the frame, so an embed could grow but
/// never shrink to a short page.
pub const EMBED_FRAME_SCRIPT: &str = "(()=>{\
const report=()=>{const b=document.body;if(!b)return;\
const r=b.getBoundingClientRect(),m=parseFloat(getComputedStyle(b).marginBottom)||0;\
const height=Math.ceil(Math.max(r.bottom,r.top+b.scrollHeight)+scrollY+m);\
if(parent!==window)parent.postMessage({type:'conduit-embed-height',height},'*');};\
addEventListener('load',report);\
if(typeof ResizeObserver!=='undefined'){const o=new ResizeObserver(report);\
const go=()=>{if(document.documentElement)o.observe(document.documentElement);\
if(document.body)o.observe(document.body);};\
if(document.readyState==='loading'){document.addEventListener('DOMContentLoaded',go,{once:true});}\
else{go();}}\
setTimeout(report,0);setTimeout(report,250);setTimeout(report,1000);\
addEventListener('click',(e)=>{if(!e.isTrusted||parent===window)return;\
const a=e.target&&e.target.closest?e.target.closest('a[href]'):null;if(!a)return;\
const url=a.href;if(!/^https?:/i.test(url))return;e.preventDefault();\
parent.postMessage({type:'conduit-open-link',url},'*');},true);})();";

/// The host page's half: what the embed's frame posts goes on to the app
/// through its own handler (the top document's only: see `web_guard`), as
/// `{"type":"height","height":N}` or `{"type":"open","url":"…"}`. The app
/// opens a link only after a click or key press it saw in the web view.
const EMBED_HOST_SCRIPT: &str = "<script>window.addEventListener('message',(e)=>{\
const f=document.getElementById('embed-frame');if(!f||e.source!==f.contentWindow)return;\
const d=e.data||{};\
const host=(m)=>window.webkit.messageHandlers.conduitHost.postMessage(JSON.stringify(m));\
if(d.type==='conduit-embed-height'){const h=Number(d.height);\
if(Number.isFinite(h)&&h>0)host({type:'height',height:h});}\
else if(d.type==='conduit-open-link'&&typeof d.url==='string'){\
host({type:'open',url:d.url});}});</script>";

/// The page for HTML or SVG a tool returned, shown inline in an answer:
/// the Preview window's page and policy (no network: inline scripts and
/// styles, `data:`/`blob:` media, nothing fetched), the markup in a
/// `sandbox="allow-scripts allow-forms"` frame, given the tool call's
/// arguments as `window.args` (as the phone gives them) and reporting its
/// height. Chart.js is offered to a page that uses it, its CDN being
/// blocked.
pub fn embed_document(source: &str, args_text: &str, theme: &PreviewTheme) -> String {
    let mut head = format!(
        "<meta name=\"color-scheme\" content=\"{scheme}\">\
         <style>:root{{color-scheme:{scheme}}}\
         html{{background:transparent;color:{fg}}}</style>",
        scheme = theme.scheme(),
        fg = theme.text,
    );
    if !args_text.trim().is_empty() {
        head.push_str(&format!(
            "<script>window.args = {};</script>",
            js_string(args_text)
        ));
    }
    head.push_str(&format!("<script>{EMBED_FRAME_SCRIPT}</script>"));
    if source.contains("Chart") || source.contains("chart.js") {
        head.push_str(&format!("<script>{}</script>", script_safe(CHART_JS)));
    }
    let inner = into_head(source, &head);
    embed_page(
        theme,
        CSP,
        &format!(
            "<iframe id=\"embed-frame\" sandbox=\"allow-scripts allow-forms\" \
             referrerpolicy=\"no-referrer\" srcdoc=\"{}\"></iframe>",
            escape_html(&inner)
        ),
    )
}

/// The page for a web page an answer embeds by its address: the page in a
/// `sandbox="allow-scripts allow-forms"` frame, and nothing else reachable
/// from the host page itself. The page is the network's, as on the phone.
pub fn remote_embed_document(url: &url::Url, theme: &PreviewTheme) -> String {
    let origin = url.origin().ascii_serialization();
    let csp = format!(
        "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; \
         frame-src {origin}; child-src {origin}; connect-src 'none'; \
         form-action 'none'; base-uri 'none'"
    );
    embed_page(
        theme,
        &csp,
        &format!(
            "<iframe id=\"embed-frame\" sandbox=\"allow-scripts allow-forms\" \
             referrerpolicy=\"no-referrer\" src=\"{}\"></iframe>",
            escape_html(url.as_str())
        ),
    )
}

/// The host page around an embed's frame, which fills it.
fn embed_page(theme: &PreviewTheme, csp: &str, body: &str) -> String {
    let scheme = theme.scheme();
    format!(
        "<!doctype html><html><head><meta charset=\"utf-8\">\
         <meta http-equiv=\"Content-Security-Policy\" content=\"{csp}\">\
         <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\
         <meta name=\"color-scheme\" content=\"{scheme}\">\
         <style>html,body{{margin:0;height:100%;background:transparent;\
         color-scheme:{scheme};overflow:hidden}}\
         iframe{{border:0;width:100%;height:100%;display:block;background:transparent}}</style>\
         {EMBED_HOST_SCRIPT}</head><body>{body}</body></html>"
    )
}

/// Opens a Preview window for a code block (the markdown plugin's hook):
/// subtitled with the main window's open chat when the block is in it
/// (Quick Ask's has no title of its own to show).
pub fn open_code_preview(lang: &str, code: &str, window: &mut Window, cx: &mut App) {
    let main = cx
        .try_global::<crate::AppState>()
        .and_then(|s| s.main_window)
        .is_some_and(|h| h == window.window_handle());
    let subtitle = if main { open_chat_title(cx) } else { None };
    open_preview_titled(lang, code, subtitle, cx);
}

/// The main window's open chat's title, if it has one.
fn open_chat_title(cx: &App) -> Option<String> {
    let state = cx.try_global::<crate::AppState>()?;
    let id = state.stores.navigation.read(cx).selected_chat()?;
    let title = state
        .stores
        .chat_list
        .read(cx)
        .find(id)?
        .title
        .trim()
        .to_string();
    (!title.is_empty()).then_some(title)
}

/// Opens a Preview window for a block of the main window's open chat;
/// returns it.
pub fn open_preview(lang: &str, code: &str, cx: &mut App) -> Option<gpui_kit::AnyWindowHandle> {
    let subtitle = open_chat_title(cx);
    open_preview_titled(lang, code, subtitle, cx)
}

/// The file a block saves as: its kind's extension on `stem` (the chat's
/// title, or the window's), with what a file name can't hold taken out.
pub fn save_name(kind: PreviewKind, stem: &str) -> String {
    let ext = match kind {
        PreviewKind::Html => "html",
        PreviewKind::Mermaid => "mmd",
        PreviewKind::Chart => "json",
    };
    let clean: String = stem
        .chars()
        .map(|c| {
            if matches!(c, '/' | ':' | '\\') || c.is_control() {
                '-'
            } else {
                c
            }
        })
        .collect();
    let clean = clean.trim().trim_start_matches('.');
    let stem = if clean.is_empty() { "Preview" } else { clean };
    format!("{stem}.{ext}")
}

/// Opens a Preview window subtitled `subtitle` (the chat's title).
pub fn open_preview_titled(
    lang: &str,
    code: &str,
    subtitle: Option<String>,
    cx: &mut App,
) -> Option<gpui_kit::AnyWindowHandle> {
    let kind = preview_kind(lang)?;
    let theme = PreviewTheme::from_theme(conduit_components::ActiveConduitTheme::conduit(cx));
    let html = preview_document(kind, code, &theme);
    let l10n = crate::l10n::ActiveL10n::l10n(cx);
    let title = match kind {
        PreviewKind::Html => l10n.desktop_preview_html_title(),
        PreviewKind::Mermaid => l10n.desktop_preview_diagram_title(),
        PreviewKind::Chart => l10n.desktop_preview_chart_title(),
    };
    #[cfg(target_os = "macos")]
    {
        macos::open(
            macos::Opened {
                title,
                subtitle,
                kind,
                code: code.to_string(),
                html,
            },
            &theme,
            cx,
        )
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = (title, subtitle, html, theme, cx);
        None
    }
}

#[cfg(target_os = "macos")]
mod macos {
    use std::rc::Rc;
    use std::time::Duration;

    use conduit_components::ActiveConduitTheme as _;
    use conduit_components::assets::IconName;
    use conduit_components::views::kit::IconButton;
    use conduit_components::window::{
        TOOLBAR_HEIGHT, TRAFFIC_LIGHTS_WIDTH, drag_region, open_window_clear_root,
    };
    use gpui_kit::prelude::*;
    use gpui_kit::{
        App, Bounds, ClipboardItem, Context, Entity, FontWeight, Role, SharedString, Task,
        WeakEntity, Window, WindowBounds, div, px, size,
    };
    use gpui_webview::WebView;

    use super::{PreviewKind, save_name};
    use crate::l10n::ActiveL10n as _;

    /// What a Preview window shows and offers.
    pub struct Opened {
        /// What it previews ("HTML Preview").
        pub title: String,
        /// The chat it came from.
        pub subtitle: Option<String>,
        pub kind: PreviewKind,
        /// The block's code (Copy Code, Save…).
        pub code: String,
        /// The sandboxed page (Open in Browser).
        pub html: String,
    }

    struct PreviewWindow {
        opened: Opened,
        webview: Entity<WebView>,
        /// Copy Code just ran: its button shows a check for a moment.
        copied: bool,
        /// Saving failed: said in the toolbar.
        save_failed: bool,
        _reset: Option<Task<()>>,
    }

    impl PreviewWindow {
        fn copy(&mut self, cx: &mut Context<Self>) {
            cx.write_to_clipboard(ClipboardItem::new_string(self.opened.code.clone()));
            let said = cx.l10n().desktop_code_copied();
            conduit_components::announce::announce(
                said,
                conduit_components::announce::Priority::Medium,
                cx,
            );
            self.copied = true;
            self._reset = Some(cx.spawn(async move |this: WeakEntity<Self>, cx| {
                cx.background_executor()
                    .timer(Duration::from_millis(1500))
                    .await;
                this.update(cx, |s, cx| {
                    s.copied = false;
                    cx.notify();
                })
                .ok();
            }));
            cx.notify();
        }

        /// Save…: the block as a file, where the save panel says (in
        /// Downloads at first, named after the chat).
        fn save(&mut self, cx: &mut Context<Self>) {
            let stem = self
                .opened
                .subtitle
                .clone()
                .unwrap_or_else(|| self.opened.title.clone());
            let name = save_name(self.opened.kind, &stem);
            let dir = dirs_downloads();
            let asked = cx.prompt_for_new_path(&dir, Some(&name));
            let code = self.opened.code.clone();
            cx.spawn(async move |this: WeakEntity<Self>, cx| {
                let Ok(Ok(Some(path))) = asked.await else {
                    return;
                };
                let failed = match std::fs::write(&path, code) {
                    Ok(()) => false,
                    Err(e) => {
                        log::warn!("preview: save to {}: {e}", path.display());
                        true
                    }
                };
                this.update(cx, |s, cx| {
                    s.save_failed = failed;
                    cx.notify();
                })
                .ok();
            })
            .detach();
        }

        /// Open in Browser: the same sandboxed, network-less page, written
        /// to a temporary file the default browser opens.
        fn open_in_browser(&mut self, cx: &mut Context<Self>) {
            // One file per export: two windows with the same title never
            // write over each other's page.
            static EXPORTS: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
            let n = EXPORTS.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
            let dir = std::env::temp_dir().join("conduit-previews");
            let name = format!(
                "{}-{n}-{}",
                std::process::id(),
                save_name(PreviewKind::Html, &self.opened.title)
            );
            let path = dir.join(name);
            let written = std::fs::create_dir_all(&dir)
                .and_then(|_| std::fs::write(&path, self.opened.html.as_bytes()));
            match written {
                Ok(()) => cx.open_with_system(&path),
                Err(e) => log::warn!("preview: open in browser: {e}"),
            }
        }
    }

    /// The user's Downloads folder (the save panel's first place), else
    /// home.
    fn dirs_downloads() -> std::path::PathBuf {
        let home = std::env::var_os("HOME")
            .map(std::path::PathBuf::from)
            .unwrap_or_else(|| std::path::PathBuf::from("/"));
        let downloads = home.join("Downloads");
        if downloads.is_dir() { downloads } else { home }
    }

    impl Render for PreviewWindow {
        fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
            let t = cx.conduit().clone();
            let r = t.roles;
            let m = t.metrics;
            let l10n = cx.l10n().clone();
            let this = cx.entity().downgrade();
            let act = |f: fn(&mut PreviewWindow, &mut Context<PreviewWindow>)| {
                let this = this.clone();
                Rc::new(
                    move |_: &gpui_kit::ClickEvent, _: &mut Window, cx: &mut App| {
                        this.update(cx, f).ok();
                    },
                ) as conduit_components::views::kit::ClickHandler
            };
            // A unified toolbar, as Preview's and Safari's: the title with
            // the chat under it beside the traffic lights, the commands at
            // the trailing edge.
            let heading = div()
                .flex()
                .flex_col()
                .min_w_0()
                .child(
                    div()
                        .truncate()
                        .text_size(px(m.control))
                        .font_weight(FontWeight::SEMIBOLD)
                        .text_color(r.text)
                        .child(SharedString::from(self.opened.title.clone())),
                )
                .when_some(self.opened.subtitle.clone(), |d, sub| {
                    d.child(
                        div()
                            .id("preview-subtitle")
                            .truncate()
                            .text_size(px(m.small))
                            .text_color(r.text_subtle)
                            .child(SharedString::from(sub)),
                    )
                });
            let toolbar = div()
                .id("preview-toolbar")
                .role(Role::Toolbar)
                .flex()
                .flex_none()
                .items_center()
                .gap(px(4.))
                .when(self.save_failed, |d| {
                    d.child(
                        div()
                            .id("preview-save-failed")
                            .role(Role::Status)
                            .pr(px(6.))
                            .text_size(px(m.small))
                            .text_color(r.danger)
                            .child(SharedString::from(l10n.desktop_preview_save_failed())),
                    )
                })
                .child(
                    IconButton::new(
                        "preview-copy",
                        if self.copied {
                            IconName::Check
                        } else {
                            IconName::Copy
                        },
                        l10n.desktop_preview_copy_code(),
                    )
                    .size(30., 16.)
                    .round()
                    .tooltip(if self.copied {
                        l10n.desktop_copied()
                    } else {
                        l10n.desktop_preview_copy_code()
                    })
                    .on_click(act(Self::copy)),
                )
                .child(
                    IconButton::new(
                        "preview-save",
                        IconName::Download,
                        l10n.desktop_preview_save(),
                    )
                    .size(30., 16.)
                    .round()
                    .on_click(act(Self::save)),
                )
                .child(
                    IconButton::new(
                        "preview-open-in-browser",
                        IconName::Globe,
                        l10n.desktop_preview_open_in_browser(),
                    )
                    .size(30., 16.)
                    .round()
                    .on_click(act(Self::open_in_browser)),
                );
            div()
                .size_full()
                .flex()
                .flex_col()
                .bg(r.window)
                .child(
                    drag_region("preview-titlebar")
                        .h(px(TOOLBAR_HEIGHT))
                        .flex_none()
                        .flex()
                        .items_center()
                        .gap(px(12.))
                        .pl(px(TRAFFIC_LIGHTS_WIDTH + 6.))
                        .pr(px(12.))
                        .child(div().flex_1().min_w_0().child(heading))
                        .child(toolbar),
                )
                .child(div().flex_1().min_h_0().child(self.webview.clone()))
        }
    }

    pub fn open(
        opened: Opened,
        theme: &super::PreviewTheme,
        cx: &mut App,
    ) -> Option<gpui_kit::AnyWindowHandle> {
        let title = opened.title.clone();
        let html = opened.html.clone();
        // The page's background, so nothing flashes white while it loads.
        let bg = {
            let hex = theme.background.trim_start_matches('#');
            let byte = |i: usize| u8::from_str_radix(&hex[i..i + 2], 16).unwrap_or(0);
            (byte(0), byte(2), byte(4), 255)
        };
        let bounds = Bounds::centered(None, size(px(860.), px(640.)), cx);
        let mut options = conduit_components::window::window_options(&title, bounds, false, true);
        options.window_bounds = Some(WindowBounds::Windowed(bounds));
        options.window_min_size = Some(size(px(360.), px(280.)));
        let opened = open_window_clear_root(options, cx, |window, cx| {
            let builder = wry::WebViewBuilder::new()
                .with_incognito(true)
                .with_devtools(false)
                .with_background_color(bg)
                .with_html(html)
                // Only the document itself (and its about:srcdoc frame).
                .with_navigation_handler(|url: String| {
                    url.starts_with("about:") || url.starts_with("data:")
                })
                .with_new_window_req_handler(|_, _| wry::NewWindowResponse::Deny);
            let webview = cx.new(|cx| {
                let webview = WebView::build(builder, window, cx)
                    .expect("a WKWebView always builds on macOS");
                crate::shell::web_media::guard(webview.raw());
                webview
            });
            cx.new(|_| PreviewWindow {
                opened,
                webview,
                copied: false,
                save_failed: false,
                _reset: None,
            })
        });
        match opened {
            Ok((handle, _)) => Some(handle),
            Err(e) => {
                log::error!("could not open a preview: {e}");
                None
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The vendored mermaid is the version its README pins: the file's
    /// SHA-256 is the one written there.
    #[test]
    fn the_bundled_mermaid_is_the_pinned_one() {
        use sha2::{Digest as _, Sha256};
        let readme = include_str!("../../../assets/preview/README.md");
        let pinned = readme
            .split("SHA-256 of the file:")
            .nth(1)
            .and_then(|rest| rest.split('`').nth(1))
            .expect("the README names the file's SHA-256");
        let actual: String = Sha256::digest(MERMAID_JS.as_bytes())
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect();
        assert_eq!(
            actual, pinned,
            "assets/preview/mermaid.min.js changed: update its version and \
             SHA-256 in assets/preview/README.md with it"
        );
        assert!(readme.contains("mermaid 12.2.0"));
    }

    #[test]
    fn a_block_saves_as_its_kind_named_after_the_chat() {
        assert_eq!(
            save_name(PreviewKind::Html, "Tide board"),
            "Tide board.html"
        );
        assert_eq!(save_name(PreviewKind::Mermaid, "a/b: c"), "a-b- c.mmd");
        assert_eq!(save_name(PreviewKind::Chart, " .. "), "Preview.json");
        assert_eq!(save_name(PreviewKind::Chart, ".hidden"), "hidden.json");
    }

    #[test]
    fn languages_map_to_previews() {
        assert_eq!(preview_kind("HTML"), Some(PreviewKind::Html));
        assert_eq!(preview_kind("svg"), Some(PreviewKind::Html));
        assert_eq!(preview_kind("mermaid"), Some(PreviewKind::Mermaid));
        assert_eq!(preview_kind("chart"), Some(PreviewKind::Chart));
        assert_eq!(preview_kind("rust"), None);
    }

    #[test]
    fn html_runs_sandboxed_under_a_no_network_policy() {
        let doc = preview_document(
            PreviewKind::Html,
            "<h1 onclick=\"x()\">Hi</h1><script src=\"https://cdn.example/x.js\"></script>",
            &PreviewTheme::plain(false),
        );
        assert!(doc.contains("Content-Security-Policy"));
        assert!(doc.contains("connect-src 'none'") && doc.contains("default-src 'none'"));
        assert!(doc.contains("<iframe sandbox=\"allow-scripts\" srcdoc=\""));
        // The model's markup is an attribute value, not markup of the page.
        assert!(doc.contains("&lt;h1 onclick=&quot;x()&quot;&gt;Hi&lt;/h1&gt;"));
        assert!(!doc.contains("allow-same-origin"));
        // No Chart.js unless the page uses it.
        assert!(!doc.contains("Chart.js v4"));
        let chart = preview_document(
            PreviewKind::Html,
            "<head></head><canvas id=c></canvas><script>new Chart(c,{})</script>",
            &PreviewTheme::plain(true),
        );
        assert!(chart.contains("Chart.js v4"));
    }

    #[test]
    fn embeds_run_sandboxed_with_their_arguments_and_no_network() {
        let doc = embed_document(
            "<p>Board</p><script>draw(window.args)</script>",
            "{\"port\":\"</script>\"}",
            &PreviewTheme::plain(false),
        );
        assert!(doc.contains("connect-src 'none'") && doc.contains("default-src 'none'"));
        assert!(doc.contains("sandbox=\"allow-scripts allow-forms\" referrerpolicy"));
        assert!(!doc.contains("allow-same-origin") && !doc.contains("allow-popups"));
        // The arguments are a string the frame cannot break out of.
        assert_eq!(
            js_string("{\"port\":\"</script>\"}"),
            "\"{\\\"port\\\":\\\"\\u003C/script\\u003E\\\"}\""
        );
        assert!(doc.contains("window.args = "));
        assert!(!doc.contains("</script>\"}"));
        assert!(
            doc.contains("conduit-embed-height") && doc.contains("messageHandlers.conduitHost")
        );
        let remote = remote_embed_document(
            &url::Url::parse("https://example.com/harbour?cam=1").unwrap(),
            &PreviewTheme::plain(true),
        );
        assert!(remote.contains("frame-src https://example.com;"));
        assert!(remote.contains("src=\"https://example.com/harbour?cam=1\""));
        assert!(remote.contains("connect-src 'none'"));
    }

    #[test]
    fn mermaid_and_chart_pages_bundle_their_scripts() {
        let m = preview_document(
            PreviewKind::Mermaid,
            "graph TD\nA-->B",
            &PreviewTheme::plain(true),
        );
        assert!(m.contains("securityLevel:'strict'") && m.contains("theme:'base'"));
        // Monochrome: the window's greys, never Mermaid's lavender.
        assert!(m.contains("darkMode:true") && m.contains("primaryColor:'#1c1c1c'"));
        let init = &m[m.find("mermaid.initialize").unwrap()..];
        assert!(!init.contains("theme:'default'") && !init.contains("theme:'dark'"));
        assert!(m.contains("A--&gt;B"));
        assert!(m.len() > 1_000_000, "mermaid is inlined");
        let c = preview_document(
            PreviewKind::Chart,
            "{\"type\":\"bar\",\"data\":{}}",
            &PreviewTheme::plain(false),
        );
        assert!(c.contains(
            "new Chart(document.getElementById(&#39;chart&#39;),{&quot;type&quot;:&quot;bar&quot;"
        ));
        let script = preview_document(
            PreviewKind::Chart,
            "draw('</SCRIPT>')",
            &PreviewTheme::plain(false),
        );
        assert!(script.contains("draw(&#39;&lt;\\/SCRIPT&gt;&#39;)"));
        assert!(!script.contains("draw('</SCRIPT>')"));
        // Other `</` stay as they are (regex literals in the bundles).
        assert_eq!(script_safe("a=/^</,b=\"</div>\""), "a=/^</,b=\"</div>\"");
        assert!(m.contains("startAngleBracket:/^</,"));
    }

    #[test]
    fn chart_code_runs_sandboxed_and_cannot_navigate() {
        let code = "location.replace('https://preview-collector.example/?v=1')";
        let doc = preview_document(PreviewKind::Chart, code, &PreviewTheme::plain(false));
        // Only the sandboxed frame holds the model's code: the page itself
        // (all Open in Browser has) runs none of it.
        let (page, frame) = doc
            .split_once("<iframe sandbox=\"allow-scripts\" srcdoc=\"")
            .unwrap();
        assert!(!page.contains("location.replace"));
        assert!(frame.contains("location.replace(&#39;https://preview-collector.example"));
        assert!(!doc.contains("allow-top-navigation") && !doc.contains("allow-same-origin"));
        assert!(page.contains("default-src 'none'") && page.contains("connect-src 'none'"));
        assert!(
            !frame.contains("<script"),
            "the frame's markup is one attribute value"
        );
    }

    #[test]
    fn html_follows_the_window_mode_unless_it_sets_its_own_colours() {
        let dark = PreviewTheme::plain(true);
        let doc = preview_document(PreviewKind::Html, "<p>Tide board</p>", &dark);
        // Inside the sandboxed frame (escaped into srcdoc) and on the page.
        assert!(doc.contains("color-scheme:dark"));
        assert!(
            doc.contains("&lt;meta name=&quot;color-scheme&quot; content=&quot;dark&quot;&gt;")
        );
        assert!(!doc.contains("background:#fff"));
        // Placed in the page's head, after its doctype and <head>.
        let html =
            "<!DOCTYPE html><html lang=en><head><title>x</title></head><body>b</body></html>";
        let placed = into_head(html, "<!--s-->");
        assert!(placed.starts_with("<!DOCTYPE html><html lang=en><head><!--s--><title>"));
        assert_eq!(into_head("<p>a</p>", "<!--s-->"), "<!--s--><p>a</p>");
        assert_eq!(
            into_head("<!doctype html><p>a</p>", "<!--s-->"),
            "<!doctype html><!--s--><p>a</p>"
        );
        // <header> is not <head>.
        assert_eq!(
            into_head("<header>h</header>", "<!--s-->"),
            "<!--s--><header>h</header>"
        );
    }
}
