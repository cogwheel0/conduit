//! Markdown for message text blocks: GPUI Kit's TextView plus Conduit's
//! plugins.
//!
//! * inline `$…$` and display `$$…$$` math through ratex-gpui (TextView parses
//!   math but ships no renderer). The daemon escapes prose `$` as `\$`, so
//!   only real math reaches these plugins;
//! * fenced code as a [`CodeBlock`]: language label, Copy, and Preview for
//!   html/mermaid/chart, highlighted by tree-sitter;
//! * `[n](conduit-cite:n)` links as inline citation pills.

use std::collections::HashMap;
use std::sync::{Arc, Mutex, OnceLock};

use gpui_kit::base::text::{
    InlineElement, InlineRenderContext, MarkdownNode, MarkdownParseContext, MarkdownPlugin,
    markdown_ast as mdast,
};
use gpui_kit::component::ActiveTheme as _;
use gpui_kit::component::highlighter::SyntaxHighlighter;
use gpui_kit::component::text::{TextView, TextViewState};
use gpui_kit::prelude::*;
use gpui_kit::{
    App, ClipboardItem, ElementId, Entity, FontWeight, HighlightStyle, Hsla, RenderImage, Rgba,
    Role, SharedString, StyledText, Window, div, img, px, relative,
};

use crate::assets::{IconName, icon};
use crate::strings::ActiveStrings as _;
use crate::theme::{ActiveConduitTheme, MONO_FONT, with_alpha};
use crate::views::focus::{ControlExt as _, Ring};
use crate::views::kit::ClickHandler;

/// The URL scheme the daemon writes for citation markers.
pub const CITE_SCHEME: &str = "conduit-cite:";

/// A TextView over `state` with every Conduit plugin.
pub fn text_view(state: &Entity<TextViewState>) -> TextView {
    TextView::new(state)
        .plugin(InlineMath)
        .plugin(BlockMath)
        .plugin(CodeBlockPlugin::default())
        .plugin(CitationPlugin)
}

/// Opens a Preview of a code block: `(language, code, window, cx)`. A plain
/// function, because markdown plugins must be `Send + Sync`.
pub type PreviewFn = fn(&str, &str, &mut Window, &mut App);

/// Languages whose blocks get a Preview button (rendered in a sandboxed
/// webview window in v1).
pub fn previewable(lang: &str) -> bool {
    matches!(
        lang.to_ascii_lowercase().as_str(),
        "html" | "svg" | "mermaid" | "chart" | "vega-lite"
    )
}

// ── Math ─────────────────────────────────────────────────────────────────

#[derive(Clone)]
struct Math {
    latex: String,
}

type MathKey = (String, u32, u32, u32);
type MathImage = (Arc<RenderImage>, f32, f32, f32);

fn math_cache() -> &'static Mutex<HashMap<MathKey, Option<MathImage>>> {
    static CACHE: OnceLock<Mutex<HashMap<MathKey, Option<MathImage>>>> = OnceLock::new();
    CACHE.get_or_init(Default::default)
}

/// Renders (cached) `latex`: image, width, height and baseline from the top.
fn render_math(latex: &str, font_size: f32, scale: f32, color: Hsla) -> Option<MathImage> {
    let c: Rgba = color.into();
    let rgb = ((c.r * 255.) as u32) << 16 | ((c.g * 255.) as u32) << 8 | (c.b * 255.) as u32;
    let key = (
        latex.to_string(),
        (font_size * 10.) as u32,
        (scale * 10.) as u32,
        rgb,
    );
    if let Some(hit) = math_cache().lock().ok()?.get(&key) {
        return hit.clone();
    }
    let rendered = ratex_gpui::render::render_latex(latex, font_size, scale, color).map(|r| {
        // Baseline: the raster padding plus the formula's height above it.
        let height_em = ratex_parser::parser::parse(latex)
            .ok()
            .map(|nodes| {
                ratex_layout::layout(&nodes, &ratex_layout::LayoutOptions::default()).height as f32
            })
            .unwrap_or(0.8);
        (
            r.image,
            r.width,
            r.height,
            ratex_gpui::render::PAD + height_em * font_size,
        )
    });
    if let Ok(mut cache) = math_cache().lock() {
        bounded_insert(&mut cache, key, rendered.clone());
    }
    rendered
}

/// Formulas kept rendered. A streamed formula passes through many partial
/// strings, so the cache starts over once it holds this many.
const MATH_CACHE_MAX: usize = 256;

fn bounded_insert<K: std::hash::Hash + Eq, V>(cache: &mut HashMap<K, V>, key: K, value: V) {
    if cache.len() >= MATH_CACHE_MAX {
        cache.clear();
    }
    cache.insert(key, value);
}

/// `$…$`, through ratex-gpui.
pub struct InlineMath;

impl MarkdownPlugin for InlineMath {
    fn name(&self) -> &str {
        "conduit-inline-math"
    }

    fn parse(&self, node: &mdast::Node, _: &MarkdownParseContext<'_>) -> Option<MarkdownNode> {
        let mdast::Node::InlineMath(m) = node else {
            return None;
        };
        Some(
            MarkdownNode::new(
                "conduit-inline-math",
                Math {
                    latex: m.value.clone(),
                },
            )
            .text(format!("${}$", m.value))
            .accessibility_label(format!("math: {}", m.value)),
        )
    }

    fn render_inline(
        &self,
        node: &MarkdownNode,
        context: &InlineRenderContext,
        window: &mut Window,
        cx: &mut App,
    ) -> Option<InlineElement> {
        let math = node.data::<Math>()?;
        let size = f32::from(context.font_size());
        let color = cx.theme().foreground;
        let (image, w, h, baseline) = render_math(&math.latex, size, window.scale_factor(), color)?;
        // Pull in the raster padding so neighbouring words keep their gap.
        let pad = ratex_gpui::render::PAD;
        Some(
            InlineElement::new(img(image).w(px(w)).h(px(h)).mx(px(-pad + 1.)).my(px(-pad)))
                .with_baseline(px(baseline - pad)),
        )
    }
}

/// `$$…$$`, through ratex-gpui.
pub struct BlockMath;

impl MarkdownPlugin for BlockMath {
    fn is_block(&self) -> bool {
        true
    }

    fn name(&self) -> &str {
        "conduit-block-math"
    }

    fn parse(&self, node: &mdast::Node, _: &MarkdownParseContext<'_>) -> Option<MarkdownNode> {
        let mdast::Node::Math(m) = node else {
            return None;
        };
        Some(
            MarkdownNode::new(
                "conduit-block-math",
                Math {
                    latex: m.value.clone(),
                },
            )
            .text(m.value.clone())
            .accessibility_label(format!("math: {}", m.value)),
        )
    }

    fn render(&self, node: &MarkdownNode, window: &mut Window, cx: &mut App) -> impl IntoElement {
        let latex = node
            .data::<Math>()
            .map(|m| m.latex.clone())
            .unwrap_or_default();
        let color = cx.theme().foreground;
        let size = cx.conduit().metrics.body * 1.3;
        let body = match render_math(&latex, size, window.scale_factor(), color) {
            Some((image, w, h, _)) => img(image).w(px(w)).h(px(h)).into_any_element(),
            None => div()
                .font_family(MONO_FONT)
                .child(SharedString::from(latex.clone()))
                .into_any_element(),
        };
        div()
            .id(ElementId::Name(format!("math-{}", latex.len()).into()))
            .role(Role::Math)
            .aria_label(format!("math: {latex}"))
            .w_full()
            .flex()
            .justify_center()
            .py(px(2.))
            .child(body)
    }
}

// ── Code blocks ──────────────────────────────────────────────────────────

#[derive(Clone)]
struct CodeData {
    lang: Option<String>,
    code: String,
}

/// Fenced code as a [`CodeBlock`]; previewable languages get Preview when
/// `on_preview` is set.
#[derive(Default)]
pub struct CodeBlockPlugin {
    pub on_preview: Option<PreviewFn>,
}

impl MarkdownPlugin for CodeBlockPlugin {
    fn is_block(&self) -> bool {
        true
    }

    fn name(&self) -> &str {
        "conduit-code-block"
    }

    fn parse(&self, node: &mdast::Node, _: &MarkdownParseContext<'_>) -> Option<MarkdownNode> {
        let mdast::Node::Code(c) = node else {
            return None;
        };
        Some(
            MarkdownNode::new(
                "conduit-code-block",
                CodeData {
                    lang: c.lang.clone(),
                    code: c.value.clone(),
                },
            )
            .text(c.value.clone()),
        )
    }

    fn render(&self, node: &MarkdownNode, _: &mut Window, _: &mut App) -> impl IntoElement {
        let data = node.data::<CodeData>().cloned().unwrap_or(CodeData {
            lang: None,
            code: String::new(),
        });
        let block = CodeBlock::new(data.code.clone()).lang(data.lang.clone());
        match (self.on_preview, data.lang) {
            (Some(open), Some(lang)) if previewable(&lang) => {
                let code = data.code;
                block.on_preview(std::rc::Rc::new(move |_, window, cx| {
                    open(&lang, &code, window, cx)
                }))
            }
            _ => block,
        }
    }
}

type Highlights = Vec<(std::ops::Range<usize>, HighlightStyle)>;
type HighlightKey = (String, u64, bool);

/// Highlighted code kept: a block streaming into an open fence is a new
/// text every frame, so the cache is emptied when it outgrows this.
const HIGHLIGHT_CACHE_MAX: usize = 512;

thread_local! {
    /// One highlighter per language, kept for the next block: making one
    /// compiles the language's tree-sitter queries (several milliseconds,
    /// every frame while code streams into an open fence), while parsing a
    /// block with it again takes microseconds. `update` without an edit
    /// parses the new text from scratch, so a reused highlighter styles
    /// exactly as a new one does.
    static HIGHLIGHTERS: std::cell::RefCell<HashMap<String, SyntaxHighlighter>> =
        Default::default();
}

/// Runs `f` with the kept highlighter for `lang`, made the first time.
fn with_highlighter<R>(lang: &str, f: impl FnOnce(&mut SyntaxHighlighter) -> R) -> R {
    HIGHLIGHTERS.with(|h| {
        let mut h = h.borrow_mut();
        let highlighter = h
            .entry(lang.to_string())
            .or_insert_with(|| SyntaxHighlighter::new(lang));
        f(highlighter)
    })
}

fn highlights(lang: &str, code: &str, cx: &App) -> Highlights {
    use std::hash::{Hash, Hasher};
    thread_local! {
        static CACHE: std::cell::RefCell<HashMap<HighlightKey, Highlights>> = Default::default();
    }
    let theme = cx.theme().highlight_theme.clone();
    let dark = cx.theme().is_dark();
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    code.hash(&mut hasher);
    let key = (lang.to_string(), hasher.finish(), dark);
    if let Some(hit) = CACHE.with(|c| c.borrow().get(&key).cloned()) {
        return hit;
    }
    let rope = gpui_kit::component::Rope::from_str(code);
    let styles = with_highlighter(lang, |highlighter| {
        highlighter.update(None, &rope, None);
        highlighter.styles(&(0..code.len()), theme.as_ref())
    });
    CACHE.with(|c| {
        let mut c = c.borrow_mut();
        if c.len() >= HIGHLIGHT_CACHE_MAX {
            c.clear();
        }
        c.insert(key, styles.clone())
    });
    styles
}

/// Warms tree-sitter for `langs`, so the first code block of each doesn't
/// hitch the main thread (35–60 ms each). The highlighters are kept for the
/// blocks to come.
pub fn preload_grammars(langs: &[&str]) {
    for lang in langs {
        with_highlighter(lang, |h| {
            h.update(None, &gpui_kit::component::Rope::from_str("x"), None);
        });
    }
}

/// A fence's language as people write it ("Python", "HTML", "C++"),
/// as the phone heads a code block; an unknown one with a capital.
pub fn language_name(lang: &str) -> String {
    let known = match lang.to_ascii_lowercase().as_str() {
        "py" | "python" => "Python",
        "html" | "htm" => "HTML",
        "css" => "CSS",
        "js" | "javascript" => "JavaScript",
        "jsx" => "JSX",
        "ts" | "typescript" => "TypeScript",
        "tsx" => "TSX",
        "json" => "JSON",
        "yaml" | "yml" => "YAML",
        "toml" => "TOML",
        "xml" => "XML",
        "sql" => "SQL",
        "sh" | "bash" => "Bash",
        "zsh" => "Zsh",
        "shell" | "console" => "Shell",
        "rs" | "rust" => "Rust",
        "go" | "golang" => "Go",
        "c" => "C",
        "cpp" | "c++" | "cc" => "C++",
        "cs" | "csharp" | "c#" => "C#",
        "java" => "Java",
        "kt" | "kotlin" => "Kotlin",
        "swift" => "Swift",
        "dart" => "Dart",
        "rb" | "ruby" => "Ruby",
        "php" => "PHP",
        "md" | "markdown" => "Markdown",
        "mermaid" => "Mermaid",
        "latex" | "tex" => "LaTeX",
        "text" | "txt" | "plaintext" => "Text",
        _ => "",
    };
    if !known.is_empty() {
        return known.to_string();
    }
    let mut chars = lang.chars();
    match chars.next() {
        Some(first) => first.to_uppercase().chain(chars).collect(),
        None => String::new(),
    }
}

/// Whether a code block shows Preview: a previewable language, and
/// something to open it.
fn shows_preview(lang: Option<&str>, has_handler: bool) -> bool {
    has_handler && lang.is_some_and(previewable)
}

/// A fenced code block: header with the language and Copy (plus Preview for
/// previewable languages, when it has a handler), then the highlighted code.
#[derive(IntoElement)]
pub struct CodeBlock {
    code: SharedString,
    lang: Option<String>,
    on_preview: Option<ClickHandler>,
}

impl CodeBlock {
    pub fn new(code: impl Into<SharedString>) -> Self {
        Self {
            code: code.into(),
            lang: None,
            on_preview: None,
        }
    }
    pub fn lang(mut self, lang: Option<String>) -> Self {
        self.lang = lang.filter(|l| !l.is_empty());
        self
    }
    pub fn on_preview(mut self, handler: ClickHandler) -> Self {
        self.on_preview = Some(handler);
        self
    }
}

impl RenderOnce for CodeBlock {
    fn render(self, window: &mut Window, cx: &mut App) -> impl IntoElement {
        let t = cx.conduit().clone();
        let r = t.roles;
        let lang = self.lang.clone().unwrap_or_else(|| "text".into());
        let styles = self
            .lang
            .as_deref()
            .map(|l| highlights(l, &self.code, cx))
            .unwrap_or_default();
        let code = self.code.clone();
        let header_fg = r.text_subtle;
        let preview = shows_preview(self.lang.as_deref(), self.on_preview.is_some());
        let id = format!("code-{}-{}", lang, self.code.len());
        let small = t.metrics.small;
        let hover = r.hover;
        let pressed = crate::views::focus::pressed_fill(r.hover, &t);
        let header_button = move |id: String, label: SharedString, ic: IconName, shown: bool| {
            div()
                .id(ElementId::Name(id.into()))
                .role(Role::Button)
                .aria_label(label.clone())
                .h(px(22.))
                .px(px(6.))
                .flex()
                .items_center()
                .gap(px(4.))
                .rounded(px(5.))
                .cursor_pointer()
                .hover(move |s| s.bg(hover))
                .active(move |s| s.bg(pressed))
                .text_size(px(small))
                .text_color(header_fg)
                .child(icon(ic, 13., header_fg))
                // An icon alone names itself in a tooltip.
                .when(!shown, |d| d.tip(label.clone(), None))
                .when(shown, |d| d.child(label))
        };
        let on_preview = self.on_preview.clone();
        let strings = cx.strings().clone();
        div()
            .id(ElementId::Name(id.clone().into()))
            .role(Role::Group)
            .aria_label(crate::strings::fill(
                &strings.code_block,
                &[("name", &language_name(&lang))],
            ))
            .w_full()
            .my(px(4.))
            .flex()
            .flex_col()
            .rounded(t.card_radius())
            .border_1()
            .border_color(r.border)
            .bg(crate::theme::composite(r.raised, t.surfaces.panel))
            .overflow_hidden()
            .child(
                div()
                    .h(px(32.))
                    .pl(px(12.))
                    .pr(px(6.))
                    .flex()
                    .items_center()
                    .gap(px(4.))
                    .border_b_1()
                    .border_color(with_alpha(r.border, 0.8))
                    // The language by its name, as the phone heads a block.
                    .child(
                        div()
                            .flex_1()
                            .text_size(px(small))
                            .text_color(header_fg)
                            .child(SharedString::from(language_name(&lang))),
                    )
                    .when(preview, |d| {
                        d.child(
                            header_button(
                                format!("{id}-preview"),
                                strings.preview.clone(),
                                IconName::Eye,
                                true,
                            )
                            .on_click(move |ev, w, cx| {
                                if let Some(h) = &on_preview {
                                    h(ev, w, cx)
                                }
                            })
                            .keyboard_control(
                                Ring::Outset(5.),
                                window,
                                cx,
                            ),
                        )
                    })
                    .child(
                        header_button(
                            format!("{id}-copy"),
                            strings.copy.clone(),
                            IconName::Copy,
                            false,
                        )
                        .on_click(move |_, _, cx| {
                            cx.write_to_clipboard(ClipboardItem::new_string(code.to_string()));
                            // Heard as the phone says it; nothing changes on
                            // screen to look at.
                            let said = cx.strings().code_copied.clone();
                            crate::announce::announce(said, crate::announce::Priority::Medium, cx);
                        })
                        .keyboard_control(Ring::Outset(5.), window, cx),
                    ),
            )
            .child(
                div()
                    .px(px(14.))
                    .py(px(11.))
                    .font_family(MONO_FONT)
                    .text_size(px(t.metrics.code))
                    .line_height(relative(1.55))
                    .text_color(r.text)
                    .flex()
                    .flex_col()
                    .children(code_lines(&self.code, &styles)),
            )
    }
}

/// A line this long may wrap in the column; shorter ones never do.
const WRAP_RISK: usize = 60;

/// How a code block's text is laid out (byte ranges into the code).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum CodeSegment {
    /// Consecutive short lines, drawn as one text.
    Lines(std::ops::Range<usize>),
    /// A line long enough to wrap: its leading indentation, then the rest.
    Long {
        indent: std::ops::Range<usize>,
        rest: std::ops::Range<usize>,
    },
}

/// Splits `code` into [`CodeSegment`]s.
pub fn code_segments(code: &str) -> Vec<CodeSegment> {
    let mut out = vec![];
    let mut run: Option<std::ops::Range<usize>> = None;
    let mut start = 0;
    for line in code.split_inclusive('\n') {
        let body = line.trim_end_matches(['\n', '\r']);
        let body_end = start + body.len();
        if body.chars().count() < WRAP_RISK {
            run = Some(match run {
                Some(r) => r.start..body_end,
                None => start..body_end,
            });
        } else {
            out.extend(run.take().map(CodeSegment::Lines));
            let indent = body.len() - body.trim_start_matches([' ', '\t']).len();
            out.push(CodeSegment::Long {
                indent: start..start + indent,
                rest: start + indent..body_end,
            });
        }
        start += line.len();
    }
    out.extend(run.map(CodeSegment::Lines));
    out
}

/// The code as text elements: runs of short lines as one text (cheap), and
/// each line long enough to wrap as a row of its own whose leading
/// indentation is a fixed spacer, so its wrapped part hangs at the line's
/// indent instead of starting back at the left edge.
pub fn code_lines(
    code: &str,
    styles: &[(std::ops::Range<usize>, HighlightStyle)],
) -> Vec<gpui_kit::AnyElement> {
    let text = |r: std::ops::Range<usize>| {
        let highlights: Highlights = styles
            .iter()
            .filter(|(h, _)| h.start < r.end && h.end > r.start)
            .map(|(h, style)| {
                (
                    h.start.max(r.start) - r.start..h.end.min(r.end) - r.start,
                    *style,
                )
            })
            .collect();
        // An empty line (alone, or ending a run) still takes a line's
        // height.
        let mut content = code[r].to_string();
        if content.is_empty() || content.ends_with('\n') {
            content.push(' ');
        }
        StyledText::new(SharedString::from(content)).with_highlights(highlights)
    };
    code_segments(code)
        .into_iter()
        .map(|segment| match segment {
            CodeSegment::Lines(r) => div().child(text(r)).into_any_element(),
            CodeSegment::Long { indent, rest } => div()
                .flex()
                .when(!indent.is_empty(), |d| {
                    d.child(div().flex_none().child(text(indent)))
                })
                .child(div().flex_1().min_w_0().child(text(rest)))
                .into_any_element(),
        })
        .collect()
}

// ── Citations ────────────────────────────────────────────────────────────

#[derive(Clone)]
struct Cite {
    n: String,
}

struct CitationPlugin;

impl MarkdownPlugin for CitationPlugin {
    fn name(&self) -> &str {
        "conduit-citation"
    }

    fn parse(&self, node: &mdast::Node, _: &MarkdownParseContext<'_>) -> Option<MarkdownNode> {
        let mdast::Node::Link(link) = node else {
            return None;
        };
        let n = link.url.strip_prefix(CITE_SCHEME)?.to_string();
        Some(
            MarkdownNode::new("conduit-citation", Cite { n: n.clone() })
                .text(format!("[{n}]"))
                .accessibility_label(format!("source {n}")),
        )
    }

    fn render_inline(
        &self,
        node: &MarkdownNode,
        context: &InlineRenderContext,
        _: &mut Window,
        cx: &mut App,
    ) -> Option<InlineElement> {
        let cite = node.data::<Cite>()?;
        let t = cx.conduit();
        let r = t.roles;
        let size = (f32::from(context.font_size()) * 0.72).round();
        let h = size + 6.;
        let pill = div()
            .h(px(h))
            .min_w(px(h))
            .px(px(4.))
            .mx(px(1.))
            .flex()
            .items_center()
            .justify_center()
            .rounded(px(h / 2.))
            .bg(with_alpha(r.text, if t.dark { 0.14 } else { 0.08 }))
            .text_size(px(size))
            .font_weight(FontWeight::MEDIUM)
            .text_color(r.text_subtle)
            .child(SharedString::from(cite.n.clone()));
        // Sit the pill on the text baseline, a little raised.
        Some(InlineElement::new(pill).with_baseline(px(h - 3.)))
    }
}

#[cfg(test)]
mod code_tests {
    use super::{CodeSegment, SyntaxHighlighter, code_segments, with_highlighter};
    use gpui_kit::component::Rope;
    use gpui_kit::component::highlighter::HighlightTheme;

    #[test]
    fn a_kept_highlighter_styles_each_block_as_a_new_one_does() {
        let theme = HighlightTheme::default_light();
        // A block streaming in, then others (shorter, unrelated, broken).
        let full = "fn orbit(period: f64) -> f64 {\n    // degrees a day\n    360.0 / period\n}\n";
        let mut texts: Vec<String> = (1..=full.len())
            .step_by(7)
            .map(|n| full[..n].to_string())
            .collect();
        texts.extend([
            "let x = \"tide\";".into(),
            "}{ unbalanced (".into(),
            full.into(),
            String::new(),
        ]);
        for lang in ["rust", "python"] {
            for code in &texts {
                let rope = Rope::from_str(code);
                let kept = with_highlighter(lang, |h| {
                    h.update(None, &rope, None);
                    h.styles(&(0..code.len()), theme.as_ref())
                });
                let mut fresh = SyntaxHighlighter::new(lang);
                fresh.update(None, &rope, None);
                assert_eq!(
                    kept,
                    fresh.styles(&(0..code.len()), theme.as_ref()),
                    "{lang}: {code:?}"
                );
            }
        }
    }

    #[test]
    fn long_code_lines_get_their_own_row_with_the_indent_apart() {
        let long = format!("    return {}", "x".repeat(70));
        let code = format!("def f():\n\n{long}\nend");
        let segments = code_segments(&code);
        assert_eq!(segments.len(), 3, "{segments:?}");
        assert_eq!(segments[0], CodeSegment::Lines(0..9));
        let at = 10;
        assert_eq!(
            segments[1],
            CodeSegment::Long {
                indent: at..at + 4,
                rest: at + 4..at + long.len()
            }
        );
        assert_eq!(&code[at + 4..at + 10], "return");
        let tail = at + long.len() + 1;
        assert_eq!(segments[2], CodeSegment::Lines(tail..tail + 3));
        assert_eq!(code_segments("a\nb"), vec![CodeSegment::Lines(0..3)]);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn preview_shows_only_with_something_to_open() {
        assert!(!shows_preview(Some("html"), false));
        assert!(shows_preview(Some("html"), true));
        assert!(!shows_preview(Some("rust"), true));
        assert!(!shows_preview(None, true));
    }

    #[test]
    fn the_math_cache_stays_bounded() {
        let mut cache = HashMap::new();
        for n in 0..MATH_CACHE_MAX * 3 {
            bounded_insert(&mut cache, n, ());
            assert!(cache.len() <= MATH_CACHE_MAX);
        }
        assert!(cache.contains_key(&(MATH_CACHE_MAX * 3 - 1)));
    }
}
