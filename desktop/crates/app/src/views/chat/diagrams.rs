//! Mermaid diagrams and Chart.js charts drawn inline in an answer, as the
//! phone draws them, with Copy Code, Show Code and Open in Preview (the
//! larger, sandboxed window, [`super::preview`]).
//!
//! **How they are drawn: once, to a picture.** Each window has one hidden
//! web view (WKWebView through wry, with the embeds' `InlineWebView`), the
//! *renderer*, which loads the bundled Mermaid and Chart.js once, under the
//! Preview page's no-network policy. A diagram is sent to it, drawn there
//! (Mermaid to SVG with plain-SVG labels, then onto a canvas; Chart.js onto
//! a canvas with animation off) and comes back as a PNG at the window's
//! scale, which the transcript draws like any other picture. Diagrams are
//! drawn one at a time, only when their block is on screen (the list is
//! virtualized), and kept by code, kind, theme and scale.
//!
//! Why not a live web view per diagram: each is a native view above GPUI
//! (moved every frame while the list scrolls) and a WebContent process's
//! memory (tens of MB). Fifty of them cost hundreds of MB and a native view
//! move per frame each; fifty pictures cost a few MB and scroll like text.
//!
//! * **Streaming:** a diagram's code shows as code until its fence closes
//!   (or the answer ends), then it is drawn.
//! * **Failure** (Mermaid's syntax error, a chart that is not a config, a
//!   page that does not answer in time): the code, with a short note.
//! * **Charts:** a Chart.js config as JSON, or as a JavaScript object
//!   literal (loosened to JSON here: quoted keys, double quotes, no
//!   trailing commas or comments). A script that draws a chart never runs
//!   in the renderer, which every chat's diagrams share: it shows as code,
//!   and Preview runs it in its own sandbox, as before.
//! * **Appearance:** the theme's colours are part of a picture's key, so a
//!   change of light, dark or palette draws it again. A chart keeps
//!   Chart.js's own palette for its data, as the phone draws it; only its
//!   text and grid take the window's tones (setting `defaults.borderColor`
//!   would turn that palette off).
//! * **Reduce Motion:** a picture that just arrived fades in, unless Reduce
//!   Motion is on.

use std::cell::RefCell;
use std::collections::{HashMap, HashSet, VecDeque};
use std::rc::Rc;
use std::sync::Arc;
use std::time::{Duration, Instant};

use conduit_components::ActiveConduitTheme as _;
use conduit_components::assets::{IconName, icon};
use conduit_components::theme::{ConduitTheme, MONO_FONT, with_alpha};
use conduit_components::views::focus::{ControlExt as _, Ring};
use conduit_components::views::markdown::{CodeBlock, code_lines, language_name};
use gpui_kit::base::text::{
    MarkdownNode, MarkdownParseContext, MarkdownPlugin, markdown_ast as mdast,
};
use gpui_kit::prelude::*;
use gpui_kit::{
    Animation, AnimationExt as _, AnyElement, AnyWindowHandle, App, ClipboardItem, ElementId,
    Image, ImageFormat, ImageSource, RenderImage, Role, SharedString, Window, div, img, px,
    relative,
};

use super::inline_web::InlineWebView;
use super::preview::{self, PreviewTheme};
use crate::l10n::ActiveL10n as _;

/// What a fenced block draws as inline.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum DiagramKind {
    Mermaid,
    Chart,
}

impl DiagramKind {
    fn name(self) -> &'static str {
        match self {
            Self::Mermaid => "mermaid",
            Self::Chart => "chart",
        }
    }
}

/// A fence's language as a diagram, if it is one (HTML stays code with
/// Preview).
pub fn diagram_kind(lang: &str) -> Option<DiagramKind> {
    match lang.trim().to_ascii_lowercase().as_str() {
        "mermaid" | "mmd" => Some(DiagramKind::Mermaid),
        "chart" | "chartjs" | "chart.js" => Some(DiagramKind::Chart),
        _ => None,
    }
}

// ── The code-block plugin ───────────────────────────────────────────────

#[derive(Clone)]
struct CodeData {
    lang: Option<String>,
    code: String,
    /// The fence has its closing line.
    closed: bool,
}

/// Whether a fenced block's source ends with its closing fence.
pub fn fence_closed(source: &str) -> bool {
    let mut lines = source.trim_end_matches(['\n', '\r']).lines();
    let Some(open) = lines.next() else {
        return false;
    };
    let open = open.trim_start();
    let Some(c) = open.chars().next().filter(|c| *c == '`' || *c == '~') else {
        // An indented block: complete as it stands.
        return true;
    };
    let run = open.chars().take_while(|x| *x == c).count();
    match lines.next_back() {
        Some(last) => {
            let last = last.trim();
            last.chars().count() >= run && last.chars().all(|x| x == c)
        }
        None => false,
    }
}

/// Fenced code in a message: Mermaid and charts drawn inline once complete
/// (see the module notes), everything else a code block with Copy and,
/// for HTML, Preview.
pub struct ChatCodePlugin {
    /// The message, for the Show Code switch.
    pub key: SharedString,
    /// The message is still being written.
    pub streaming: bool,
}

impl MarkdownPlugin for ChatCodePlugin {
    fn is_block(&self) -> bool {
        true
    }

    fn name(&self) -> &str {
        "conduit-chat-code-block"
    }

    fn parse(&self, node: &mdast::Node, cx: &MarkdownParseContext<'_>) -> Option<MarkdownNode> {
        let mdast::Node::Code(c) = node else {
            return None;
        };
        let closed = cx.node_source(node).is_none_or(fence_closed);
        Some(
            MarkdownNode::new(
                "conduit-chat-code-block",
                CodeData {
                    lang: c.lang.clone(),
                    code: c.value.clone(),
                    closed,
                },
            )
            .text(c.value.clone()),
        )
    }

    fn render(&self, node: &MarkdownNode, window: &mut Window, cx: &mut App) -> impl IntoElement {
        let data = node.data::<CodeData>().cloned().unwrap_or(CodeData {
            lang: None,
            code: String::new(),
            closed: true,
        });
        let kind = data.lang.as_deref().and_then(diagram_kind);
        match kind {
            Some(kind) if data.closed || !self.streaming => {
                diagram_block(&self.key, kind, &data.code, window, cx)
            }
            _ => code_block(data.lang, data.code),
        }
    }
}

/// Code as a code block, with Preview for HTML, Mermaid and charts.
fn code_block(lang: Option<String>, code: String) -> AnyElement {
    let block = CodeBlock::new(code.clone()).lang(lang.clone());
    match lang {
        Some(lang) if preview::preview_kind(&lang).is_some() => block
            .on_preview(Rc::new(move |_, window, cx| {
                preview::open_code_preview(&lang, &code, window, cx)
            }))
            .into_any_element(),
        _ => block.into_any_element(),
    }
}

// ── The cache and the renderer ──────────────────────────────────────────

/// A drawn picture's key: kind, code, theme and scale.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
struct Key {
    kind: DiagramKind,
    code: u64,
    theme: u64,
    scale: u32,
}

#[derive(Clone)]
enum Drawn {
    /// Asked for, not drawn yet.
    Pending,
    /// The picture, its size in points, and when it arrived.
    Ready {
        image: Arc<RenderImage>,
        width: f32,
        height: f32,
        at: Instant,
    },
    Failed,
}

/// How many drawn (or failed) pictures are kept: diagrams still on their
/// way do not count, and are never dropped.
const CACHE_CAP: usize = 96;
/// A picture drawn by a message this recently is in use (on screen): it is
/// never what goes to make room. Each frame that shows it marks it again.
const IN_USE: Duration = Duration::from_secs(10);
/// How long one diagram may take before it counts as failed (and the
/// renderer, which may be stuck, is made anew).
const RENDER_TIMEOUT: Duration = Duration::from_secs(10);

/// The diagrams asked for, by key (each once): pending, drawn or failed,
/// and when a message last drew each.
struct Cache {
    drawn: HashMap<Key, Drawn>,
    used: HashMap<Key, Instant>,
}

impl Cache {
    fn new() -> Self {
        Self {
            drawn: HashMap::new(),
            used: HashMap::new(),
        }
    }

    #[cfg(test)]
    fn get(&self, key: &Key) -> Option<Drawn> {
        self.drawn.get(key).cloned()
    }

    /// `key`'s entry as a message drawing it at `now` sees it, which marks
    /// it in use.
    fn touch(&mut self, key: &Key, now: Instant) -> Option<Drawn> {
        let drawn = self.drawn.get(key).cloned()?;
        self.used.insert(key.clone(), now);
        Some(drawn)
    }

    /// Keeps `value` for `key` at `now`. A finished one (drawn or failed)
    /// may make room: past [`CACHE_CAP`] finished pictures, the least
    /// recently drawn one goes, but never `key` itself, one in use
    /// ([`IN_USE`]) or one still on its way. With none to drop, the cap
    /// waits (it is exceeded for a while), so nothing is ever drawn twice
    /// in a loop.
    fn put(&mut self, key: Key, value: Drawn, now: Instant) {
        let finished = !matches!(value, Drawn::Pending);
        self.drawn.insert(key.clone(), value);
        self.used.insert(key.clone(), now);
        if !finished {
            return;
        }
        while self.finished() > CACHE_CAP {
            let idle = |k: &Key| {
                self.used
                    .get(k)
                    .is_none_or(|at| now.saturating_duration_since(*at) >= IN_USE)
            };
            let Some(old) = self
                .drawn
                .iter()
                .filter(|(k, d)| !matches!(d, Drawn::Pending) && **k != key && idle(k))
                .min_by_key(|(k, _)| self.used.get(*k).copied())
                .map(|(k, _)| k.clone())
            else {
                break;
            };
            self.remove(&old);
        }
    }

    /// How many pictures are drawn or failed (not on their way).
    fn finished(&self) -> usize {
        self.drawn
            .values()
            .filter(|d| !matches!(d, Drawn::Pending))
            .count()
    }

    /// Forgets `key` everywhere.
    fn remove(&mut self, key: &Key) {
        self.drawn.remove(key);
        self.used.remove(key);
    }
}

/// A diagram on its way to the renderer.
struct Job {
    id: u64,
    key: Key,
    kind: DiagramKind,
    code: String,
    theme: String,
    scale: f32,
}

/// One window's renderer.
struct Renderer {
    view: Option<Rc<InlineWebView>>,
    loaded: bool,
    /// When it was made: a page that has not loaded by [`LOAD_TIMEOUT`]
    /// never will.
    created: Instant,
    queue: VecDeque<Job>,
    in_flight: Option<(Job, Instant)>,
}

/// How many diagrams may wait for one renderer (beside the one it draws).
const QUEUE_CAP: usize = 32;

/// How long the renderer's page may take to load its scripts.
const LOAD_TIMEOUT: Duration = Duration::from_secs(15);

/// Why a renderer is given up on.
enum Stuck {
    /// A diagram never came back (a page stuck in a loop): the others are
    /// asked for again, of a new renderer.
    Job,
    /// The page never loaded: what waited for it fails (shows its code).
    Page,
}

thread_local! {
    static CACHE: RefCell<Cache> = RefCell::new(Cache::new());
    static RENDERERS: RefCell<HashMap<u64, Renderer>> = RefCell::new(HashMap::new());
    static NEXT_JOB: std::cell::Cell<u64> = const { std::cell::Cell::new(1) };
    /// Whether closing a window ends its renderer ([`follow_window_closes`]).
    static FOLLOWING_CLOSES: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
    /// Show Code, by message and code.
    static SHOWN_CODE: RefCell<HashSet<(String, u64)>> = RefCell::new(HashSet::new());
}

fn hash_of(s: &str) -> u64 {
    use std::hash::{Hash, Hasher};
    let mut h = std::collections::hash_map::DefaultHasher::new();
    s.hash(&mut h);
    h.finish()
}

/// The colours a picture is drawn in, as the renderer reads them.
fn theme_json(t: &ConduitTheme) -> String {
    let p = PreviewTheme::from_theme(t);
    serde_json::json!({
        "dark": p.dark,
        "bg": p.background,
        "text": p.text,
        "line": p.line,
        "fill": p.fill,
        "fillAlt": p.fill_alt,
        // The lines' grey, faint: a chart's grid.
        "grid": format!("{}40", p.line),
    })
    .to_string()
}

/// `code`'s picture as `kind` for this window: asks the renderer the first
/// time.
fn drawn(kind: DiagramKind, code: &str, window: &mut Window, cx: &mut App) -> Drawn {
    let t = cx.conduit().clone();
    let theme = theme_json(&t);
    let scale = window.scale_factor().max(1.);
    let key = Key {
        kind,
        code: hash_of(code),
        theme: hash_of(&theme),
        scale: (scale * 100.) as u32,
    };
    let now = Instant::now();
    if let Some(hit) = CACHE.with(|c| c.borrow_mut().touch(&key, now)) {
        return hit;
    }
    let source = match kind {
        DiagramKind::Mermaid => Some(code.to_string()),
        DiagramKind::Chart => chart_config(code),
    };
    let Some(source) = source else {
        CACHE.with(|c| c.borrow_mut().put(key, Drawn::Failed, now));
        return Drawn::Failed;
    };
    let id = NEXT_JOB.with(|n| {
        let id = n.get();
        n.set(id + 1);
        id
    });
    enqueue(
        Job {
            id,
            key,
            kind,
            code: source,
            theme,
            scale,
        },
        window,
        cx,
    );
    Drawn::Pending
}

fn window_key(window: &Window) -> u64 {
    window.window_handle().window_id().as_u64()
}

/// A window's renderer belongs to the window: once it closes, the
/// renderer (its hidden web view) goes, and what waited on it is asked for
/// again wherever it shows next. Idempotent.
fn forget_window(wk: u64) {
    let Some(renderer) = RENDERERS.with(|r| r.borrow_mut().remove(&wk)) else {
        return;
    };
    CACHE.with(|c| {
        let mut c = c.borrow_mut();
        let waiting = renderer
            .queue
            .iter()
            .chain(renderer.in_flight.iter().map(|(job, _)| job));
        for job in waiting {
            if matches!(c.drawn.get(&job.key), Some(Drawn::Pending)) {
                c.remove(&job.key);
            }
        }
    });
}

/// Ends each window's renderer as the window closes, once per app.
fn follow_window_closes(cx: &mut App) {
    if FOLLOWING_CLOSES.with(|f| f.replace(true)) {
        return;
    }
    cx.on_window_closed(|_, id| forget_window(id.as_u64()))
        .detach();
}

fn enqueue(job: Job, window: &mut Window, cx: &mut App) {
    let wk = window_key(window);
    let has = RENDERERS.with(|r| r.borrow().contains_key(&wk));
    if !has {
        follow_window_closes(cx);
        let view = make_renderer(window.window_handle(), window, cx);
        RENDERERS.with(|r| {
            r.borrow_mut().insert(
                wk,
                Renderer {
                    view,
                    loaded: false,
                    created: Instant::now(),
                    queue: VecDeque::new(),
                    in_flight: None,
                },
            )
        });
    }
    RENDERERS.with(|r| {
        if let Some(renderer) = r.borrow_mut().get_mut(&wk) {
            CACHE.with(|c| admit(&mut renderer.queue, job, &mut c.borrow_mut()));
        }
    });
    if !has {
        // Gives up on a page that never loads.
        cx.spawn(async move |cx| {
            cx.background_executor()
                .timer(LOAD_TIMEOUT + Duration::from_millis(50))
                .await;
            cx.update(|cx| pump(wk, cx));
        })
        .detach();
    }
    pump(wk, cx);
}

/// Puts `job` on `queue`, once per key, and marks its picture on its way.
/// A full queue ([`QUEUE_CAP`]) turns it away and keeps nothing for it: a
/// message still showing it asks again on a later frame (each finished
/// diagram draws the window again). A waiting job never leaves but to be
/// drawn, so the front always drains in order and a transcript that shows
/// diagrams faster than they are drawn never piles up their sources.
fn admit(queue: &mut VecDeque<Job>, job: Job, cache: &mut Cache) {
    if queue.iter().any(|j| j.key == job.key) || queue.len() >= QUEUE_CAP {
        return;
    }
    cache.put(job.key.clone(), Drawn::Pending, Instant::now());
    queue.push_back(job);
}

/// What the renderer page says.
#[derive(serde::Deserialize)]
struct PageMessage {
    #[serde(rename = "type")]
    kind: String,
    #[serde(default)]
    id: u64,
    #[serde(default)]
    ok: bool,
    #[serde(default)]
    png: Option<String>,
    /// Absent or null when the page had no finite size to give.
    #[serde(default)]
    width: Option<f64>,
    #[serde(default)]
    height: Option<f64>,
}

/// The largest side a diagram is drawn at, in points: the renderer scales
/// a larger one down to fit (and to [`MAX_AREA`]), and a size past it is
/// not drawn.
const MAX_SIDE: u32 = 2400;
/// The largest area a diagram is drawn at, in square points.
const MAX_AREA: u32 = 4_000_000;
/// The longest picture the renderer may send back (base64).
const MAX_PNG_BASE64: usize = 48 * 1024 * 1024;

/// The size a diagram is drawn at, from what the page sent: none unless
/// both sides are finite, above zero and within [`MAX_SIDE`], and the area
/// within [`MAX_AREA`] (the page rounds, so each gets a point to spare).
fn drawable_size(width: Option<f64>, height: Option<f64>) -> Option<(f32, f32)> {
    let fits = |v: f64| v.is_finite() && v > 0. && v <= f64::from(MAX_SIDE) + 1.;
    match (width, height) {
        (Some(w), Some(h)) if fits(w) && fits(h) && (w - 1.) * (h - 1.) <= f64::from(MAX_AREA) => {
            Some((w as f32, h as f32))
        }
        _ => None,
    }
}

fn make_renderer(
    handle: AnyWindowHandle,
    window: &mut Window,
    cx: &mut App,
) -> Option<Rc<InlineWebView>> {
    let (tx, mut rx) = futures::channel::mpsc::unbounded::<String>();
    let builder = wry::WebViewBuilder::new()
        .with_incognito(true)
        .with_devtools(false)
        .with_transparent(true)
        .with_bounds(wry::Rect {
            position: wry::dpi::LogicalPosition::new(0., 0.).into(),
            size: wry::dpi::LogicalSize::new(1600., 1200.).into(),
        })
        .with_html(renderer_page())
        .with_navigation_handler(|url: String| {
            url.starts_with("about:") || url.starts_with("data:")
        })
        .with_new_window_req_handler(|_, _| wry::NewWindowResponse::Deny)
        .with_ipc_handler(move |request| {
            let _ = tx.unbounded_send(request.into_body());
        });
    let view = InlineWebView::new(builder, window)?;
    let wk = window_key(window);
    let renderer = cx.svg_renderer();
    cx.spawn(async move |cx| {
        use futures::StreamExt as _;
        while let Some(body) = rx.next().await {
            let Ok(message) = serde_json::from_str::<PageMessage>(&body) else {
                continue;
            };
            if message.kind == "ready" {
                cx.update(|cx| {
                    RENDERERS.with(|r| {
                        if let Some(renderer) = r.borrow_mut().get_mut(&wk) {
                            renderer.loaded = true;
                        }
                    });
                    pump(wk, cx);
                });
                continue;
            }
            // The job it answers, if it is still the one in flight.
            let job = RENDERERS.with(|r| {
                let mut r = r.borrow_mut();
                let renderer = r.get_mut(&wk)?;
                match &renderer.in_flight {
                    Some((job, _)) if job.id == message.id => {
                        renderer.in_flight.take().map(|(j, _)| j)
                    }
                    _ => None,
                }
            });
            let Some(job) = job else {
                continue;
            };
            let size = drawable_size(message.width, message.height);
            let decoded = match (message.ok, size, message.png) {
                (true, Some(_), Some(png)) => {
                    let renderer = renderer.clone();
                    cx.background_spawn(async move { decode_png(&png, renderer) })
                        .await
                }
                _ => None,
            };
            cx.update(|cx| {
                let value = match (decoded, size) {
                    (Some(image), Some((width, height))) => Drawn::Ready {
                        image,
                        width,
                        height,
                        at: Instant::now(),
                    },
                    _ => Drawn::Failed,
                };
                // Replaces the pending entry; never itself what makes room.
                CACHE.with(|c| c.borrow_mut().put(job.key.clone(), value, Instant::now()));
                pump(wk, cx);
                let _ = handle.update(cx, |_, window, _| window.refresh());
            });
        }
    })
    .detach();
    Some(view)
}

/// A `data:image/png;base64,…` URL as frames GPUI draws: none when it is
/// longer than [`MAX_PNG_BASE64`] or says (in its header) it unpacks to
/// more pixels than a picture from a site may.
fn decode_png(data_url: &str, renderer: gpui_kit::SvgRenderer) -> Option<Arc<RenderImage>> {
    use base64::Engine as _;
    let b64 = data_url.strip_prefix("data:image/png;base64,")?;
    if b64.len() > MAX_PNG_BASE64 {
        return None;
    }
    let bytes = base64::engine::general_purpose::STANDARD.decode(b64).ok()?;
    if crate::stores::media::too_many_pixels(&bytes) {
        return None;
    }
    Image::from_bytes(ImageFormat::Png, bytes)
        .to_image_data(renderer)
        .ok()
}

/// Sends the window's next diagram, once its page has loaded and nothing
/// else is being drawn; a diagram that took too long fails, and the
/// renderer is made anew.
fn pump(wk: u64, cx: &mut App) {
    let script = RENDERERS.with(|r| {
        let mut r = r.borrow_mut();
        let renderer = r.get_mut(&wk)?;
        let stuck = if renderer
            .in_flight
            .as_ref()
            .is_some_and(|(_, at)| at.elapsed() >= RENDER_TIMEOUT)
        {
            Some(Stuck::Job)
        } else if !renderer.loaded && renderer.created.elapsed() >= LOAD_TIMEOUT {
            Some(Stuck::Page)
        } else {
            None
        };
        if let Some(stuck) = stuck {
            if let Some((job, _)) = renderer.in_flight.take() {
                log::warn!("diagram renderer: {} timed out", job.kind.name());
                CACHE.with(|c| {
                    if let Some(slot) = c.borrow_mut().drawn.get_mut(&job.key) {
                        *slot = Drawn::Failed;
                    }
                });
            } else {
                log::warn!("diagram renderer: its page did not load");
            }
            return Some(Err(stuck));
        }
        if renderer.in_flight.is_some() {
            return None;
        }
        if !renderer.loaded {
            return None;
        }
        let job = renderer.queue.pop_front()?;
        let script = format!(
            "window.conduitRender({},{},{},{},{});",
            job.id,
            preview::js_string(job.kind.name()),
            preview::js_string(&job.code),
            job.theme,
            job.scale,
        );
        renderer.in_flight = Some((job, Instant::now()));
        Some(Ok(script))
    });
    match script {
        Some(Ok(script)) => {
            let view = RENDERERS.with(|r| r.borrow().get(&wk).and_then(|r| r.view.clone()));
            #[cfg(target_os = "macos")]
            if let Some(view) = view {
                let _ = view.webview().evaluate_script(&script);
            }
            #[cfg(not(target_os = "macos"))]
            let _ = (view, script);
            // Checks the timeout while it draws.
            cx.spawn(async move |cx| {
                cx.background_executor()
                    .timer(RENDER_TIMEOUT + Duration::from_millis(50))
                    .await;
                cx.update(|cx| pump(wk, cx));
            })
            .detach();
        }
        // Given up: the renderer goes. After a stuck diagram, what was
        // waiting is asked for again (of a new renderer, made at the next
        // request); after a page that never loaded, it fails.
        Some(Err(stuck)) => {
            let waiting: Vec<Key> = RENDERERS.with(|r| {
                r.borrow_mut()
                    .remove(&wk)
                    .map(|r| r.queue.into_iter().map(|j| j.key).collect())
                    .unwrap_or_default()
            });
            CACHE.with(|c| {
                let mut c = c.borrow_mut();
                for key in waiting {
                    match stuck {
                        Stuck::Job => {
                            c.remove(&key);
                        }
                        Stuck::Page => {
                            if let Some(slot) = c.drawn.get_mut(&key) {
                                *slot = Drawn::Failed;
                            }
                        }
                    }
                }
            });
            cx.refresh_windows();
        }
        None => {}
    }
}

// Mermaid's and Chart.js's bundles: the Preview window's copies.
use super::preview::{CHART_JS, MERMAID_JS};

/// The renderer's own script: `conduitRender(id, kind, code, theme,
/// scale)` draws one diagram and posts `{type:'done', id, ok, png, width,
/// height}`; the page posts `{type:'ready'}` once loaded.
const RENDERER_JS: &str = r#"(function(){
const post=(m)=>window.ipc.postMessage(JSON.stringify(m));
const MAX_SIDE=2400,MAX_AREA=4000000;
function bound(w,h){
if(!(Number.isFinite(w)&&Number.isFinite(h)&&w>0&&h>0))throw new Error('no size');
const k=Math.min(1,MAX_SIDE/w,MAX_SIDE/h,Math.sqrt(MAX_AREA/(w*h)));
return [w*k,h*k];}
const stage=document.getElementById('stage');
let seq=0;
function themeVars(t){return {darkMode:!!t.dark,background:t.bg,
fontFamily:'-apple-system,BlinkMacSystemFont,sans-serif',fontSize:'14px',
primaryColor:t.fill,primaryTextColor:t.text,primaryBorderColor:t.line,
secondaryColor:t.fillAlt,secondaryTextColor:t.text,secondaryBorderColor:t.line,
tertiaryColor:t.fillAlt,tertiaryTextColor:t.text,tertiaryBorderColor:t.line,
lineColor:t.line,textColor:t.text,mainBkg:t.fill,nodeBorder:t.line,clusterBkg:t.fillAlt,
clusterBorder:t.line,edgeLabelBackground:t.bg,titleColor:t.text,noteBkgColor:t.fillAlt,
noteTextColor:t.text,noteBorderColor:t.line,actorBkg:t.fill,actorBorder:t.line,
actorTextColor:t.text,signalColor:t.text,signalTextColor:t.text,labelBoxBkgColor:t.fill,
labelBoxBorderColor:t.line,labelTextColor:t.text};}
async function svgPng(text,w,h,scale){
const img=new Image();
img.src='data:image/svg+xml;charset=utf-8,'+encodeURIComponent(text);
await img.decode();
const c=document.createElement('canvas');
c.width=Math.max(1,Math.ceil(w*scale));c.height=Math.max(1,Math.ceil(h*scale));
const x=c.getContext('2d');x.scale(scale,scale);x.drawImage(img,0,0,w,h);
return c.toDataURL('image/png');}
async function mermaidPng(code,t,scale){
mermaid.initialize({startOnLoad:false,securityLevel:'strict',theme:'base',
suppressErrorRendering:true,htmlLabels:false,flowchart:{htmlLabels:false},
themeVariables:themeVars(t)});
const id='conduit-diagram-'+(++seq);
let out;
try{out=await mermaid.render(id,code);}
finally{const left=document.getElementById(id);if(left)left.remove();
const d=document.getElementById('d'+id);if(d)d.remove();}
const doc=new DOMParser().parseFromString(out.svg,'image/svg+xml');
const el=doc.documentElement;
if(!el||el.nodeName.toLowerCase()!=='svg')throw new Error('no picture');
const vb=(el.getAttribute('viewBox')||'').split(/[\s,]+/).map(Number);
let w=vb.length===4&&vb[2]>0?vb[2]:parseFloat(el.getAttribute('width'))||0;
let h=vb.length===4&&vb[3]>0?vb[3]:parseFloat(el.getAttribute('height'))||0;
if(!(w>0&&h>0))throw new Error('empty picture');
[w,h]=bound(w,h);
el.setAttribute('width',String(w));el.setAttribute('height',String(h));
el.removeAttribute('style');
const text=new XMLSerializer().serializeToString(el);
return {png:await svgPng(text,w,h,scale),width:w,height:h};}
function chartPng(code,t,scale){
const cfg=JSON.parse(code);
if(!cfg||typeof cfg!=='object'||!cfg.data)throw new Error('not a chart');
const type=String(cfg.type||'');
const round=['pie','doughnut','polarArea','radar'].includes(type);
const o=cfg.options=(cfg.options&&typeof cfg.options==='object')?cfg.options:{};
const r=Number(o.aspectRatio);
const ar=Number.isFinite(r)&&r>=0.2&&r<=10?r:(round?1:2);
const [w,h]=bound(round?420:640,Math.max(120,Math.round((round?420:640)/ar)));
o.animation=false;o.responsive=false;o.maintainAspectRatio=false;o.devicePixelRatio=scale;
Chart.defaults.color=t.text;Chart.defaults.scale.grid.color=t.grid;
Chart.defaults.font.family='-apple-system,BlinkMacSystemFont,sans-serif';
Chart.defaults.font.size=12;
stage.innerHTML='';
const c=document.createElement('canvas');
c.style.width=w+'px';c.style.height=h+'px';c.width=Math.round(w*scale);c.height=Math.round(h*scale);
stage.appendChild(c);
try{new Chart(c,cfg);return {png:c.toDataURL('image/png'),width:w,height:h};}
finally{const made=Chart.getChart(c);if(made)made.destroy();stage.innerHTML='';}}
window.conduitRender=async function(id,kind,code,t,scale){
try{const r=kind==='mermaid'?await mermaidPng(code,t,scale):chartPng(code,t,scale);
post({type:'done',id,ok:true,png:r.png,width:r.width,height:r.height});}
catch(e){post({type:'done',id,ok:false});}};
post({type:'ready'});})();"#;

fn renderer_page() -> String {
    // The Preview page's no-network policy: inline scripts and styles and
    // `data:`/`blob:` pictures only.
    let csp = preview::CSP;
    format!(
        "<!doctype html><html><head><meta charset=\"utf-8\">\
         <meta http-equiv=\"Content-Security-Policy\" content=\"{csp}\">\
         <style>html,body{{margin:0;background:transparent;\
         font-family:-apple-system,BlinkMacSystemFont,sans-serif}}\
         #stage{{position:absolute;left:0;top:0;width:1600px}}</style>\
         <script>{}</script><script>{}</script></head>\
         <body><div id=\"stage\"></div><script>{RENDERER_JS}</script></body></html>",
        script_safe(MERMAID_JS),
        script_safe(CHART_JS),
    )
}

/// `s` safe inside `<script>`: only `</script` ends the element.
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

/// How many diagrams of each state the cache holds, `(ready, pending,
/// failed)`, for the E2E pass.
pub fn drawn_counts() -> (usize, usize, usize) {
    CACHE.with(|c| {
        c.borrow()
            .drawn
            .values()
            .fold((0, 0, 0), |(r, p, f), d| match d {
                Drawn::Ready { .. } => (r + 1, p, f),
                Drawn::Pending => (r, p + 1, f),
                Drawn::Failed => (r, p, f + 1),
            })
    })
}

// ── Charts: the config as JSON ──────────────────────────────────────────

/// A chart block's Chart.js config as JSON: the code itself when it is
/// JSON, else a JavaScript object literal loosened to JSON (keys quoted,
/// single-quoted strings, trailing commas and comments dropped). `None`
/// for anything else (a script, a function in the config).
pub fn chart_config(code: &str) -> Option<String> {
    let code = code.trim();
    if let Ok(v) = serde_json::from_str::<serde_json::Value>(code) {
        return v.is_object().then(|| v.to_string());
    }
    if !code.starts_with('{') {
        return None;
    }
    let loose = loosen(code)?;
    let v = serde_json::from_str::<serde_json::Value>(&loose).ok()?;
    v.is_object().then(|| v.to_string())
}

/// A JavaScript object literal as JSON text (see [`chart_config`]).
fn loosen(src: &str) -> Option<String> {
    let chars: Vec<char> = src.chars().collect();
    let mut out = String::with_capacity(src.len() + 16);
    let mut i = 0;
    while i < chars.len() {
        let c = chars[i];
        match c {
            '/' if chars.get(i + 1) == Some(&'/') => {
                while i < chars.len() && chars[i] != '\n' {
                    i += 1;
                }
            }
            '/' if chars.get(i + 1) == Some(&'*') => {
                i += 2;
                while i + 1 < chars.len() && !(chars[i] == '*' && chars[i + 1] == '/') {
                    i += 1;
                }
                i += 2;
            }
            '"' | '\'' => {
                let quote = c;
                let mut s = String::new();
                i += 1;
                loop {
                    let ch = *chars.get(i)?;
                    if ch == '\\' {
                        let next = *chars.get(i + 1)?;
                        if next == quote {
                            s.push(next);
                        } else {
                            s.push('\\');
                            s.push(next);
                        }
                        i += 2;
                        continue;
                    }
                    if ch == quote {
                        i += 1;
                        break;
                    }
                    s.push(ch);
                    i += 1;
                }
                // Re-escaped for JSON.
                out.push('"');
                for ch in s.chars() {
                    match ch {
                        '"' => out.push_str("\\\""),
                        '\n' => out.push_str("\\n"),
                        _ => out.push(ch),
                    }
                }
                out.push('"');
            }
            ',' => {
                // A trailing comma before `}` or `]` goes.
                let mut j = i + 1;
                while j < chars.len() && chars[j].is_whitespace() {
                    j += 1;
                }
                if !matches!(chars.get(j), Some('}') | Some(']')) {
                    out.push(',');
                }
                i += 1;
            }
            c if c.is_alphabetic() || c == '_' || c == '$' => {
                let start = i;
                while i < chars.len()
                    && (chars[i].is_alphanumeric() || chars[i] == '_' || chars[i] == '$')
                {
                    i += 1;
                }
                let word: String = chars[start..i].iter().collect();
                let mut j = i;
                while j < chars.len() && chars[j].is_whitespace() {
                    j += 1;
                }
                if chars.get(j) == Some(&':') {
                    out.push('"');
                    out.push_str(&word);
                    out.push('"');
                } else if matches!(word.as_str(), "true" | "false" | "null") {
                    out.push_str(&word);
                } else {
                    // `function`, `undefined`, a variable: not a config.
                    return None;
                }
            }
            _ => {
                out.push(c);
                i += 1;
            }
        }
    }
    Some(out)
}

// ── The block ────────────────────────────────────────────────────────────

/// A short spoken name for a diagram: Mermaid's `accTitle`, a `title`
/// line, or a chart's title plugin text.
pub fn diagram_title(kind: DiagramKind, code: &str) -> Option<String> {
    match kind {
        DiagramKind::Mermaid => code.lines().find_map(|l| {
            let l = l.trim();
            l.strip_prefix("accTitle:")
                .or_else(|| l.strip_prefix("accTitle :"))
                .or_else(|| l.strip_prefix("title:"))
                .or_else(|| l.strip_prefix("title "))
                .or_else(|| l.strip_prefix("pie title "))
                .map(|t| t.trim().to_string())
                .filter(|t| !t.is_empty())
        }),
        DiagramKind::Chart => {
            let config: serde_json::Value = serde_json::from_str(&chart_config(code)?).ok()?;
            let title = config.pointer("/options/plugins/title/text")?;
            match title {
                serde_json::Value::String(s) => Some(s.clone()),
                serde_json::Value::Array(lines) => Some(
                    lines
                        .iter()
                        .filter_map(|l| l.as_str())
                        .collect::<Vec<_>>()
                        .join(" "),
                ),
                _ => None,
            }
            .filter(|t| !t.trim().is_empty())
        }
    }
}

/// Room for a diagram still being drawn.
fn pending_height(kind: DiagramKind) -> f32 {
    match kind {
        DiagramKind::Mermaid => 220.,
        DiagramKind::Chart => 320.,
    }
}

/// How long a picture that just arrived takes to fade in.
const FADE_IN: Duration = Duration::from_millis(180);

/// A diagram's block: its header (the kind, Show Code, Copy Code, Open in
/// Preview) over the picture, or the code with a note when it could not be
/// drawn.
pub fn diagram_block(
    message: &str,
    kind: DiagramKind,
    code: &str,
    window: &mut Window,
    cx: &mut App,
) -> AnyElement {
    let t = cx.conduit().clone();
    let l10n = cx.l10n().clone();
    let r = t.roles;
    let m = t.metrics;
    let state = drawn(kind, code, window, cx);
    let code_hash = hash_of(code);
    let show_key = (message.to_string(), code_hash);
    let failed = matches!(state, Drawn::Failed);
    let showing_code = failed || SHOWN_CODE.with(|s| s.borrow().contains(&show_key));
    let id = |part: &str| ElementId::Name(format!("diagram-{message}-{code_hash:x}{part}").into());
    let lang = kind.name();
    let kind_label = match kind {
        DiagramKind::Mermaid => l10n.desktop_diagram(),
        DiagramKind::Chart => l10n.desktop_chart(),
    };
    let header_fg = r.text_subtle;
    let hover = r.hover;
    let pressed = conduit_components::views::focus::pressed_fill(r.hover, &t);
    let small = m.small;
    let button = move |part: &str, label: String, glyph: IconName, active: bool| {
        div()
            .id(id(part))
            .role(Role::Button)
            .aria_label(SharedString::from(label.clone()))
            .when(active, |d| d.aria_selected(true))
            .h(px(22.))
            .w(px(26.))
            .flex()
            .items_center()
            .justify_center()
            .rounded(px(5.))
            .cursor_pointer()
            .when(active, move |d| d.bg(hover))
            .hover(move |s| s.bg(hover))
            .active(move |s| s.bg(pressed))
            .child(icon(glyph, 13., header_fg))
            .tip(SharedString::from(label), None)
    };
    let toggle_key = show_key.clone();
    let copy_code = code.to_string();
    let preview_code = code.to_string();
    let header = div()
        .h(px(32.))
        .pl(px(12.))
        .pr(px(6.))
        .flex()
        .items_center()
        .gap(px(2.))
        .border_b_1()
        .border_color(with_alpha(r.border, 0.8))
        .child(
            div()
                .flex_1()
                .text_size(px(small))
                .text_color(header_fg)
                .child(SharedString::from(language_name(lang))),
        )
        .when(!failed, |d| {
            d.child(
                button(
                    "-show-code",
                    if showing_code {
                        l10n.desktop_hide_code()
                    } else {
                        l10n.desktop_show_code()
                    },
                    IconName::Code,
                    showing_code,
                )
                .on_click(move |_, window, _| {
                    SHOWN_CODE.with(|s| {
                        let mut s = s.borrow_mut();
                        if !s.remove(&toggle_key) {
                            s.insert(toggle_key.clone());
                        }
                    });
                    window.refresh();
                })
                .keyboard_control(Ring::Outset(5.), window, cx),
            )
        })
        .child(
            button(
                "-copy",
                l10n.desktop_preview_copy_code(),
                IconName::Copy,
                false,
            )
            .on_click(move |_, _, cx| {
                cx.write_to_clipboard(ClipboardItem::new_string(copy_code.clone()));
                let said = cx.l10n().desktop_code_copied();
                conduit_components::announce::announce(
                    said,
                    conduit_components::announce::Priority::Medium,
                    cx,
                );
            })
            .keyboard_control(Ring::Outset(5.), window, cx),
        )
        .child(
            button(
                "-preview",
                l10n.desktop_open_in_preview(),
                IconName::Maximize2,
                false,
            )
            .on_click(move |_, window, cx| {
                preview::open_code_preview(lang, &preview_code, window, cx)
            })
            .keyboard_control(Ring::Outset(5.), window, cx),
        );
    let picture: Option<AnyElement> = match &state {
        Drawn::Ready {
            image,
            width,
            height,
            at,
        } => {
            let spoken = match diagram_title(kind, code) {
                Some(title) => format!("{kind_label}: {title}"),
                None => kind_label.clone(),
            };
            let picture = div()
                .id(id("-picture"))
                .role(Role::Image)
                .aria_label(SharedString::from(spoken))
                .w_full()
                .flex()
                .justify_center()
                .px(px(12.))
                .py(px(12.))
                .child(
                    img(ImageSource::Render(image.clone()))
                        .w_full()
                        .max_w(px(*width))
                        .aspect_ratio(width / height),
                );
            let fresh = at.elapsed() < FADE_IN && !cx.reduce_motion();
            Some(if fresh {
                picture
                    .with_animation(id("-fade"), Animation::new(FADE_IN), |d, delta| {
                        d.opacity(delta)
                    })
                    .into_any_element()
            } else {
                picture.into_any_element()
            })
        }
        Drawn::Pending => Some(
            div()
                .id(id("-pending"))
                .role(Role::Image)
                .aria_label(SharedString::from(
                    l10n.desktop_diagram_drawing(&kind_label),
                ))
                .w_full()
                .h(px(pending_height(kind)))
                .flex()
                .items_center()
                .justify_center()
                .child(super::blocks::spinner(id("-spinner"), 16., r.text_subtle))
                .into_any_element(),
        ),
        Drawn::Failed => None,
    };
    let note = failed.then(|| {
        div()
            .id(id("-failed"))
            .role(Role::Status)
            .px(px(12.))
            .pt(px(9.))
            .flex()
            .items_center()
            .gap(px(6.))
            .text_size(px(small))
            .text_color(r.text_subtle)
            .child(icon(IconName::TriangleAlert, 13., r.text_subtle))
            .child(SharedString::from(match kind {
                DiagramKind::Mermaid => l10n.desktop_diagram_failed(),
                DiagramKind::Chart => l10n.desktop_chart_failed(),
            }))
    });
    let code_view = showing_code.then(|| {
        div()
            .when(!failed, |d| {
                d.border_t_1().border_color(with_alpha(r.border, 0.8))
            })
            .px(px(14.))
            .py(px(11.))
            .font_family(MONO_FONT)
            .text_size(px(m.code))
            .line_height(relative(1.55))
            .text_color(r.text)
            .flex()
            .flex_col()
            .children(code_lines(code, &[]))
    });
    div()
        .id(id(""))
        .role(Role::Group)
        .aria_label(SharedString::from(kind_label.clone()))
        .w_full()
        .my(px(4.))
        .flex()
        .flex_col()
        .rounded(t.card_radius())
        .border_1()
        .border_color(r.border)
        .overflow_hidden()
        .child(header)
        .children(note)
        .children(picture)
        .children(code_view)
        .into_any_element()
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A size the page could not give (an aspect ratio of almost nothing
    /// makes a height of Infinity, which JSON sends as null) ends that
    /// diagram as failed, never a message that cannot be read and a job
    /// left in flight; a size past the limit is not drawn either.
    #[test]
    fn a_diagram_without_a_size_it_can_draw_fails() {
        let message: PageMessage = serde_json::from_str(
            r#"{"type":"done","id":3,"ok":true,"png":"data:image/png;base64,AA","width":640,"height":null}"#,
        )
        .expect("read, with no height");
        assert_eq!(message.id, 3);
        assert_eq!(drawable_size(message.width, message.height), None);
        assert_eq!(drawable_size(Some(640.), Some(320.)), Some((640., 320.)));
        assert_eq!(drawable_size(Some(640.), Some(1e9)), None);
        assert_eq!(drawable_size(Some(f64::INFINITY), Some(10.)), None);
        assert_eq!(drawable_size(Some(0.), Some(10.)), None);
        // Each side within the limit, the area past it.
        assert_eq!(drawable_size(Some(2400.), Some(2400.)), None);
        assert_eq!(
            drawable_size(Some(2400.), Some(1600.)),
            Some((2400., 1600.))
        );
        // The page bounds what it draws the same way.
        assert!(RENDERER_JS.contains("Number.isFinite(r)&&r>=0.2&&r<=10"));
        assert!(RENDERER_JS.contains(&format!("MAX_SIDE={MAX_SIDE},MAX_AREA={MAX_AREA};")));
        // A chart whose type does not exist registers itself before it
        // throws: whatever was registered on the canvas is destroyed.
        let chart = RENDERER_JS
            .find("try{new Chart(c,cfg);")
            .expect("built inside the try");
        let cleanup = RENDERER_JS[chart..]
            .find("finally{const made=Chart.getChart(c);if(made)made.destroy();")
            .expect("destroyed in finally");
        assert!(cleanup > 0);
        assert!(!RENDERER_JS.contains("const chart=new Chart(c,cfg);"));
    }

    fn key_n(n: u64) -> Key {
        Key {
            kind: DiagramKind::Mermaid,
            code: n,
            theme: 1,
            scale: 200,
        }
    }

    /// More diagrams than the cache holds, all still on their way: none is
    /// evicted (each would be asked for again, in a loop), and each key is
    /// held once; taken out, a key is gone everywhere.
    #[test]
    fn diagrams_on_their_way_stay_and_each_key_is_kept_once() {
        let t0 = Instant::now();
        let mut cache = Cache::new();
        let n = CACHE_CAP as u64 + 1;
        for k in 0..n {
            cache.put(key_n(k), Drawn::Pending, t0);
        }
        assert!((0..n).all(|k| matches!(cache.get(&key_n(k)), Some(Drawn::Pending))));
        cache.put(key_n(0), Drawn::Pending, t0);
        assert_eq!(cache.drawn.len(), n as usize);
        cache.remove(&key_n(7));
        assert!(cache.get(&key_n(7)).is_none() && !cache.used.contains_key(&key_n(7)));
        cache.put(key_n(7), Drawn::Pending, t0);
        assert_eq!(cache.drawn.len(), cache.used.len());
    }

    fn job_n(n: u64) -> Job {
        Job {
            id: n,
            key: key_n(n),
            kind: DiagramKind::Mermaid,
            code: format!("graph TD; A{n}-->B"),
            theme: String::new(),
            scale: 2.,
        }
    }

    /// A stable transcript shows more diagrams than may wait: each frame
    /// asks for every picture not yet cached, in the same order, and each
    /// time the renderer finishes one the window draws again. The queue
    /// never holds more than [`QUEUE_CAP`]; a job that waits is never put
    /// out of the queue (only drawing takes it), one past the cap is not
    /// on its way (nothing pending is kept for it, so a later frame asks
    /// again), and every diagram is drawn, each once.
    #[test]
    fn a_full_queue_turns_new_diagrams_away_and_every_one_is_drawn() {
        let t0 = Instant::now();
        let mut cache = Cache::new();
        let mut queue: VecDeque<Job> = VecDeque::new();
        let n = QUEUE_CAP as u64 * 2 + 7;
        let mut drawn = Vec::new();
        for _frame in 0..(n * 4) {
            for k in 0..n {
                if cache.get(&key_n(k)).is_some() {
                    continue;
                }
                let before: Vec<Key> = queue.iter().map(|j| j.key.clone()).collect();
                admit(&mut queue, job_n(k), &mut cache);
                let after: Vec<Key> = queue.iter().map(|j| j.key.clone()).collect();
                assert!(after.len() <= QUEUE_CAP, "{} wait", after.len());
                assert!(
                    after.starts_with(&before),
                    "a waiting diagram left the queue"
                );
                let queued = after.contains(&key_n(k));
                assert_eq!(
                    matches!(cache.get(&key_n(k)), Some(Drawn::Pending)),
                    queued,
                    "{k} is pending exactly when it waits"
                );
            }
            // The renderer draws the front one; the window draws again.
            let Some(job) = queue.pop_front() else {
                break;
            };
            cache.put(job.key.clone(), Drawn::Failed, t0);
            drawn.push(job.key.code);
        }
        let mut each = drawn.clone();
        each.sort_unstable();
        each.dedup();
        assert_eq!(each.len(), drawn.len(), "a diagram was drawn twice");
        assert_eq!(drawn.len() as u64, n, "every diagram is drawn");
    }

    /// More diagrams than the cache holds, all on screen: each is drawn
    /// once and shown; the one that just arrived is never what goes, nor
    /// one a message just drew, so nothing is asked for again.
    #[test]
    fn more_diagrams_than_the_cache_holds_each_render_once() {
        let t0 = Instant::now();
        let mut cache = Cache::new();
        let n = CACHE_CAP as u64 + 1;
        let mut renders = vec![0u32; n as usize];
        for k in 0..n {
            cache.put(key_n(k), Drawn::Pending, t0);
            renders[k as usize] += 1;
        }
        for k in 0..n {
            let now = t0 + Duration::from_millis(100 * (k + 1));
            cache.put(key_n(k), Drawn::Failed, now);
            // The window draws again: every message shows its diagram.
            for v in 0..n {
                if cache.touch(&key_n(v), now).is_none() {
                    cache.put(key_n(v), Drawn::Pending, now);
                    renders[v as usize] += 1;
                }
            }
        }
        assert!(
            renders.iter().all(|r| *r == 1),
            "renders per key: {renders:?}"
        );
        assert_eq!(
            cache.finished(),
            n as usize,
            "over the cap while all are shown"
        );
    }

    /// Room is made from pictures no message has drawn lately: the least
    /// recently drawn one goes, never the one that just arrived.
    #[test]
    fn room_is_made_from_pictures_no_longer_shown() {
        let t0 = Instant::now();
        let mut cache = Cache::new();
        for k in 0..CACHE_CAP as u64 {
            cache.put(key_n(k), Drawn::Failed, t0 + Duration::from_millis(k));
        }
        // Long after, one is drawn again and a new one arrives.
        let later = t0 + IN_USE + Duration::from_secs(1);
        cache.touch(&key_n(0), later);
        cache.put(key_n(500), Drawn::Failed, later);
        assert!(
            cache.get(&key_n(1)).is_none(),
            "the least recently drawn went"
        );
        assert!(cache.get(&key_n(0)).is_some(), "the one just drawn stayed");
        assert!(
            cache.get(&key_n(500)).is_some(),
            "the one that arrived stayed"
        );
        assert_eq!(cache.finished(), CACHE_CAP);
    }

    /// A renderer (with a diagram waiting) belongs to its window: closing
    /// the window ends it, and the diagram is asked for again elsewhere.
    #[gpui_kit::test]
    fn a_closed_windows_renderer_goes_with_it(cx: &mut gpui_kit::TestAppContext) {
        let vcx = cx.add_empty_window();
        let wk = vcx.update(|window, _| window_key(window));
        let key = Key {
            kind: DiagramKind::Mermaid,
            code: 7,
            theme: 7,
            scale: 200,
        };
        vcx.update(|_, cx| {
            follow_window_closes(cx);
            CACHE.with(|c| {
                c.borrow_mut()
                    .put(key.clone(), Drawn::Pending, Instant::now())
            });
            RENDERERS.with(|r| {
                r.borrow_mut().insert(
                    wk,
                    Renderer {
                        view: None,
                        loaded: true,
                        created: Instant::now(),
                        queue: VecDeque::from([Job {
                            id: 1,
                            key: key.clone(),
                            kind: DiagramKind::Mermaid,
                            code: "graph TD; A-->B".into(),
                            theme: "{}".into(),
                            scale: 2.,
                        }]),
                        in_flight: None,
                    },
                )
            });
        });
        vcx.update(|window, _| window.remove_window());
        cx.run_until_parked();
        assert!(RENDERERS.with(|r| !r.borrow().contains_key(&wk)));
        assert!(CACHE.with(|c| c.borrow().get(&key).is_none()));
        // Again: nothing left to end.
        forget_window(wk);
    }

    #[test]
    fn diagrams_are_mermaid_and_charts_and_html_stays_code() {
        assert_eq!(diagram_kind("Mermaid"), Some(DiagramKind::Mermaid));
        assert_eq!(diagram_kind("mmd"), Some(DiagramKind::Mermaid));
        assert_eq!(diagram_kind("chartjs"), Some(DiagramKind::Chart));
        assert_eq!(diagram_kind("chart.js"), Some(DiagramKind::Chart));
        assert_eq!(diagram_kind("html"), None);
        assert_eq!(diagram_kind("rust"), None);
    }

    #[test]
    fn a_fence_is_complete_once_its_closing_line_arrives() {
        assert!(fence_closed("```mermaid\ngraph TD\nA-->B\n```"));
        assert!(fence_closed("```mermaid\ngraph TD\nA-->B\n```\n"));
        assert!(fence_closed("~~~~chart\n{}\n~~~~"));
        assert!(!fence_closed("```mermaid\ngraph TD\nA-->B"));
        assert!(!fence_closed("```mermaid\ngraph TD\nA-->B\n``"));
        // A shorter run does not close a longer fence.
        assert!(!fence_closed("````mermaid\nA\n```"));
        assert!(!fence_closed("```mermaid"));
        // An indented block has no fence to wait for.
        assert!(fence_closed("    let x = 1;"));
    }

    #[test]
    fn chart_configs_are_json_or_an_object_literal_never_a_script() {
        let json = r#"{"type":"bar","data":{"labels":["a"],"datasets":[{"data":[1]}]}}"#;
        assert!(chart_config(json).is_some());
        let literal = "{\n  // tides\n  type: 'line', /* daily */\n  data: { labels: ['Mon', 'Tue',], \
                       datasets: [{ label: \"High water\", data: [4.1, 4.3], fill: false, }] },\n}";
        let config: serde_json::Value =
            serde_json::from_str(&chart_config(literal).unwrap()).unwrap();
        assert_eq!(config["type"], "line");
        assert_eq!(config["data"]["labels"][1], "Tue");
        assert_eq!(config["data"]["datasets"][0]["fill"], false);
        // A script, or a config with code in it, is not drawn inline.
        assert!(chart_config("new Chart(ctx, { type: 'bar' })").is_none());
        assert!(chart_config("{ type: 'bar', options: { onClick: function() {} } }").is_none());
        assert!(chart_config("{ type: 'bar', data: undefined }").is_none());
        assert!(chart_config("[1, 2]").is_none());
        // Quotes inside strings survive.
        let quoted = chart_config("{ title: 'It\\'s \"high\"' }").unwrap();
        let v: serde_json::Value = serde_json::from_str(&quoted).unwrap();
        assert_eq!(v["title"], "It's \"high\"");
    }

    #[test]
    fn diagrams_are_named_by_their_title() {
        assert_eq!(
            diagram_title(
                DiagramKind::Mermaid,
                "graph TD\naccTitle: Tide cycle\nA-->B"
            )
            .as_deref(),
            Some("Tide cycle")
        );
        assert_eq!(
            diagram_title(DiagramKind::Mermaid, "pie title Harbour use\n\"Boats\": 3").as_deref(),
            Some("Harbour use")
        );
        assert_eq!(diagram_title(DiagramKind::Mermaid, "graph TD\nA-->B"), None);
        let chart =
            r#"{"type":"bar","data":{},"options":{"plugins":{"title":{"text":"Water levels"}}}}"#;
        assert_eq!(
            diagram_title(DiagramKind::Chart, chart).as_deref(),
            Some("Water levels")
        );
        assert_eq!(diagram_title(DiagramKind::Chart, "{}"), None);
    }

    #[test]
    fn the_renderer_page_bundles_its_scripts_under_the_no_network_policy() {
        let page = renderer_page();
        assert!(page.contains("connect-src 'none'") && page.contains("default-src 'none'"));
        assert!(!page.contains("unsafe-eval"));
        assert!(page.contains("window.conduitRender") && page.contains("htmlLabels:false"));
        assert!(page.len() > 1_000_000, "mermaid is inlined");
    }
}
