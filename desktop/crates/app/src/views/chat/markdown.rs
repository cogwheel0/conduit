//! Message markdown: GPUI Kit's TextView with Conduit's math and code
//! plugins, plus what only the chat knows about:
//!
//! * `[n](conduit-cite:n)` (or `n,m`) citations: a pill that opens the
//!   transcript's source popover for `sources[n - 1]` (through the
//!   [`super::CitationTarget`] global, since markdown plugins and link
//!   handlers must be `Send + Sync` and cannot hold the view);
//! * links: `conduit-cite:` the same way, http(s) in the browser, anything
//!   else refused;
//! * images: `data:image/…` inline (decoded once and cached); any other
//!   picture through [`super::remote_image`]: the account's server's files
//!   load, another site's only after a click or once its site is allowed;
//! * links to a PDF as a card with its first page ([`super::pdf_card`]);
//! * code blocks: Mermaid and charts drawn inline ([`super::diagrams`]),
//!   with Preview (a sandboxed window, [`super::preview`]) for them and
//!   HTML.

use std::collections::HashMap;
use std::sync::{Arc, Mutex, OnceLock};

use base64::Engine as _;
use conduit_components::ActiveConduitTheme as _;
use conduit_components::theme::with_alpha;
use conduit_components::views::markdown::{BlockMath, CITE_SCHEME, InlineMath};
use gpui_kit::base::text::{
    InlineElement, InlineRenderContext, MarkdownNode, MarkdownParseContext, MarkdownPlugin,
    TextViewMotion, markdown_ast as mdast,
};
use gpui_kit::component::text::{TextView, TextViewState};
use gpui_kit::prelude::*;
use gpui_kit::{
    App, ClickEvent, ElementId, Entity, FontWeight, Image, ImageCacheError, ImageFormat,
    ImageSource, Pixels, Point, Role, SharedString, SharedUri, Window, div, px,
};

use super::CitationTarget;
use crate::l10n::ActiveL10n as _;

/// The TextView for one message's markdown. `key` names the message, so a
/// citation knows whose sources it points into.
pub fn chat_text(state: &Entity<TextViewState>, key: SharedString) -> TextView {
    chat_text_live(state, key, false)
}

/// [`chat_text`] for a message that may still be `streaming`: a diagram's
/// code shows as code until its fence closes.
pub fn chat_text_live(
    state: &Entity<TextViewState>,
    key: SharedString,
    streaming: bool,
) -> TextView {
    let link_key = key.clone();
    TextView::new(state)
        .motion(stream_motion())
        .plugin(InlineMath)
        .plugin(BlockMath)
        .plugin(super::diagrams::ChatCodePlugin {
            key: key.clone(),
            streaming,
        })
        .plugin(super::remote_image::MediaBlockPlugin)
        .plugin(super::pdf_card::PdfLinkPlugin)
        .plugin(super::remote_image::ImagePlugin)
        .plugin(CitePlugin { key })
        .image_source(resolve_image)
        .on_link_click(move |url, event, window, cx| {
            open_link(&link_key, url, event.position(), window, cx)
        })
}

/// Streamed text arrives as a steady reveal: each update's words fade in
/// one after another (a long update fades as one), so the answer reads as
/// it is written rather than in lumps. Only appended text fades; a stored
/// answer, or text replaced outright, shows at once, and Reduce Motion
/// shows everything at once.
pub fn stream_motion() -> TextViewMotion {
    TextViewMotion::default()
        .with_stream_fade(std::time::Duration::from_millis(220))
        .with_stream_fade_stagger(std::time::Duration::from_millis(24))
}

/// The source numbers a `conduit-cite:` target names: `1`, `1,2`.
pub fn cite_numbers(target: &str) -> Vec<usize> {
    target
        .split([',', ' '])
        .filter_map(|n| n.trim().parse::<usize>().ok())
        .filter(|n| *n > 0)
        .collect()
}

/// A link in a message was clicked.
pub fn open_link(key: &str, url: &str, position: Point<Pixels>, window: &mut Window, cx: &mut App) {
    if let Some(target) = url.strip_prefix(CITE_SCHEME) {
        show_citation(key, cite_numbers(target), position, window, cx);
    } else {
        open_web_link(url, cx);
    }
}

/// `url` when the system may open it from a chat: http, https or mailto.
/// Whatever a server or model wrote is checked here before it reaches the
/// system (no `file:`, no other app's scheme).
pub fn web_link(url: &str) -> Option<url::Url> {
    url::Url::parse(url)
        .ok()
        .filter(|u| matches!(u.scheme(), "http" | "https" | "mailto"))
}

/// Opens `url` from a chat (a link, a source, a status link) if
/// [`web_link`] allows it.
pub fn open_web_link(url: &str, cx: &mut App) {
    match web_link(url) {
        Some(parsed) => cx.open_url(parsed.as_str()),
        None => log::info!("ignored a link that is not http(s) or mailto"),
    }
}

fn show_citation(
    key: &str,
    numbers: Vec<usize>,
    position: Point<Pixels>,
    window: &mut Window,
    cx: &mut App,
) {
    if numbers.is_empty() {
        return;
    }
    let Some(target) = cx.try_global::<CitationTarget>().map(|t| t.0.clone()) else {
        return;
    };
    let key = key.to_string();
    let _ = target.update(cx, |t, cx| {
        t.show_citation(key, numbers, position, window, cx)
    });
}

#[derive(Clone)]
struct Cite {
    numbers: Vec<usize>,
    label: String,
}

/// Citation pills that open the source popover.
struct CitePlugin {
    key: SharedString,
}

impl MarkdownPlugin for CitePlugin {
    fn name(&self) -> &str {
        "conduit-chat-citation"
    }

    fn parse(&self, node: &mdast::Node, _: &MarkdownParseContext<'_>) -> Option<MarkdownNode> {
        let mdast::Node::Link(link) = node else {
            return None;
        };
        let target = link.url.strip_prefix(CITE_SCHEME)?;
        let numbers = cite_numbers(target);
        if numbers.is_empty() {
            return None;
        }
        let label = numbers
            .iter()
            .map(usize::to_string)
            .collect::<Vec<_>>()
            .join(",");
        Some(
            MarkdownNode::new(
                "conduit-chat-citation",
                Cite {
                    numbers,
                    label: label.clone(),
                },
            )
            .text(format!("[{label}]"))
            .accessibility_label(format!("source {label}")),
        )
    }

    fn render_inline(
        &self,
        node: &MarkdownNode,
        context: &InlineRenderContext,
        _: &mut Window,
        cx: &mut App,
    ) -> Option<InlineElement> {
        let cite = node.data::<Cite>()?.clone();
        let t = cx.conduit();
        let r = t.roles;
        let size = (f32::from(context.font_size()) * 0.72).round();
        let h = size + 6.;
        let key = self.key.to_string();
        let numbers = cite.numbers.clone();
        // The phone's badge: the source's site (or title), "+N" for more;
        // the numbers when there is nothing to name it by.
        let target = cx.try_global::<CitationTarget>().map(|t| t.0.clone());
        let named = target
            .as_ref()
            .and_then(|t| t.upgrade())
            .and_then(|t| t.read(cx).citation_label(&key, &numbers, cx));
        let (label, background) = match &named {
            Some((label, more, background)) => (
                match more {
                    Some(n) => format!(
                        "{label} {}",
                        cx.l10n().desktop_citation_more(&n.to_string())
                    ),
                    None => label.clone(),
                },
                *background,
            ),
            None => (cite.label.clone(), true),
        };
        let hover_key = key.clone();
        let hover_numbers = numbers.clone();
        let hover_target = target.clone();
        let pill = div()
            .id(ElementId::Name(
                format!("cite-{}-{}", self.key, cite.label).into(),
            ))
            .role(Role::Link)
            .aria_label(format!("Source {}", cite.label))
            .h(px(h))
            .min_w(px(h))
            .max_w(px(220.))
            .px(px(if named.is_some() { 7. } else { 4. }))
            .mx(px(1.))
            .flex()
            .items_center()
            .justify_center()
            .rounded(px(h / 2.))
            .when(background, |d| {
                d.bg(with_alpha(r.text, if t.dark { 0.14 } else { 0.08 }))
            })
            .hover(|s| s.bg(with_alpha(r.text, if t.dark { 0.22 } else { 0.14 })))
            .cursor_pointer()
            .text_size(px(size))
            .font_weight(FontWeight::MEDIUM)
            .text_color(r.text_subtle)
            .child(div().truncate().child(SharedString::from(label)))
            .on_hover(move |hovered: &bool, window, cx| {
                let Some(transcript) = hover_target.as_ref().and_then(|t| t.upgrade()) else {
                    return;
                };
                let position = window.mouse_position();
                let (key, numbers) = (hover_key.clone(), hover_numbers.clone());
                let hovered = *hovered;
                transcript.update(cx, |t, cx| {
                    t.hover_citation(key, numbers, position, hovered, cx)
                });
            })
            .on_click(move |event: &ClickEvent, window, cx| {
                cx.stop_propagation();
                show_citation(&key, numbers.clone(), event.position(), window, cx)
            });
        Some(InlineElement::new(pill).with_baseline(px(h - 3.)))
    }
}

type ImageCache = Mutex<HashMap<u64, Option<Arc<Image>>>>;

fn image_cache() -> &'static ImageCache {
    static CACHE: OnceLock<ImageCache> = OnceLock::new();
    CACHE.get_or_init(Default::default)
}

/// Decodes a `data:image/<type>;base64,…` URL.
pub fn decode_data_image(uri: &str) -> Option<Image> {
    let rest = uri.strip_prefix("data:")?;
    let (meta, data) = rest.split_once(',')?;
    let mut parts = meta.split(';');
    let mime = parts.next()?.to_ascii_lowercase();
    if !parts.any(|p| p.eq_ignore_ascii_case("base64")) {
        return None;
    }
    let format = match mime.as_str() {
        "image/png" => ImageFormat::Png,
        "image/jpeg" | "image/jpg" => ImageFormat::Jpeg,
        "image/gif" => ImageFormat::Gif,
        "image/webp" => ImageFormat::Webp,
        "image/bmp" => ImageFormat::Bmp,
        "image/svg+xml" => ImageFormat::Svg,
        _ => return None,
    };
    let bytes = base64::engine::general_purpose::STANDARD
        .decode(data.trim())
        .ok()?;
    Some(Image::from_bytes(format, bytes))
}

fn blocked() -> ImageSource {
    ImageSource::Custom(Arc::new(|_, _| {
        Some(Err(ImageCacheError::Other(Arc::new(anyhow::anyhow!(
            "remote images are not loaded"
        )))))
    }))
}

/// `data:` images inline; everything else is not fetched.
fn resolve_image(uri: &SharedUri) -> ImageSource {
    use std::hash::{Hash, Hasher};
    if !uri.starts_with("data:") {
        return blocked();
    }
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    uri.as_ref().hash(&mut hasher);
    let key = hasher.finish();
    let cached = image_cache().lock().ok().and_then(|c| c.get(&key).cloned());
    let image = match cached {
        Some(image) => image,
        None => {
            let image = decode_data_image(uri).map(Arc::new);
            if let Ok(mut cache) = image_cache().lock() {
                cache.insert(key, image.clone());
            }
            image
        }
    };
    match image {
        Some(image) => ImageSource::Image(image),
        None => blocked(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_web_and_mail_links_reach_the_system() {
        assert!(web_link("https://docs.example.org/a").is_some());
        assert!(web_link("http://127.0.0.1:8080").is_some());
        assert!(web_link("mailto:someone@example.org").is_some());
        for refused in [
            "file:///etc/hosts",
            "x-apple-systempreferences:com.apple.preference.security",
            "javascript:alert(1)",
            "conduit://settings",
            "not a url",
        ] {
            assert!(web_link(refused).is_none(), "{refused}");
        }
    }

    #[test]
    fn citation_targets_name_one_or_more_sources() {
        assert_eq!(cite_numbers("1"), vec![1]);
        assert_eq!(cite_numbers("1,2"), vec![1, 2]);
        assert_eq!(cite_numbers("3, 4"), vec![3, 4]);
        assert_eq!(cite_numbers("0,x"), Vec::<usize>::new());
    }

    #[test]
    fn data_images_decode_and_other_urls_do_not() {
        let png = "data:image/png;base64,iVBORw0KGgo=";
        let image = decode_data_image(png).unwrap();
        assert_eq!(image.format, ImageFormat::Png);
        assert!(image.bytes.starts_with(b"\x89PNG"));
        assert!(decode_data_image("data:text/plain;base64,aGk=").is_none());
        assert!(decode_data_image("data:image/png,raw").is_none());
        assert!(decode_data_image("https://example.org/pixel.gif").is_none());
    }
}

/// Text shorter than this is drawn as one TextView.
pub const CHUNK_MIN: usize = 1_000;

fn is_list_or_table(line: &str) -> bool {
    let t = line.trim_start();
    if t.starts_with('|') || t.starts_with("- ") || t.starts_with("* ") || t.starts_with("+ ") {
        return true;
    }
    let digits = t.chars().take_while(char::is_ascii_digit).count();
    digits > 0 && (t[digits..].starts_with(". ") || t[digits..].starts_with(") "))
}

/// Splits long markdown into chunks that each render on their own, at
/// blank lines that end a paragraph-level block: never inside a code fence
/// or display math, never between list items or table rows, and never
/// before an indented line. Every chunk is at least [`CHUNK_MIN`] long
/// (but the last). The chunks concatenate to `markdown`.
///
/// While an answer streams, only the last chunk changes, so TextView
/// re-lays out a couple of thousand characters a frame instead of the
/// whole answer (a full 32K re-layout costs most of a frame).
pub fn stable_chunks(markdown: &str) -> Vec<&str> {
    if markdown.len() < CHUNK_MIN * 2 {
        return vec![markdown];
    }
    let mut chunks = vec![];
    let mut start = 0;
    let mut fence: Option<(char, usize)> = None;
    let mut math = false;
    let mut prev_line = "";
    let mut offset = 0;
    let lines: Vec<&str> = markdown.split_inclusive('\n').collect();
    for (i, line) in lines.iter().enumerate() {
        let trimmed = line.trim();
        // Fences and display math.
        if let Some((c, run)) = fence {
            let n = trimmed.chars().take_while(|x| *x == c).count();
            if n >= run && trimmed.chars().all(|x| x == c) {
                fence = None;
            }
        } else if let Some(c) = trimmed.chars().next().filter(|c| *c == '`' || *c == '~') {
            let run = trimmed.chars().take_while(|x| *x == c).count();
            if run >= 3 {
                fence = Some((c, run));
            }
        } else if let Some(rest) = trimmed.strip_prefix("$$") {
            // `$$x$$` on one line opens and closes.
            if !rest.contains("$$") {
                math = !math;
            }
        }
        offset += line.len();
        let blank = trimmed.is_empty();
        if blank
            && fence.is_none()
            && !math
            && offset - start >= CHUNK_MIN
            && !is_list_or_table(prev_line)
            && let Some(next) = lines[i + 1..].iter().find(|l| !l.trim().is_empty())
            && !next.starts_with([' ', '\t'])
            && !is_list_or_table(next)
        {
            chunks.push(&markdown[start..offset]);
            start = offset;
        }
        if !blank {
            prev_line = line;
        }
    }
    chunks.push(&markdown[start..]);
    chunks
}

#[cfg(test)]
mod chunk_tests {
    use super::*;

    fn para(n: usize) -> String {
        format!("Paragraph {n}: {}\n\n", "word ".repeat(80))
    }

    #[test]
    fn short_text_is_one_chunk_and_long_text_splits_between_paragraphs() {
        assert_eq!(stable_chunks("short"), vec!["short"]);
        let text: String = (0..40).map(para).collect();
        let chunks = stable_chunks(&text);
        assert!(chunks.len() > 3, "{}", chunks.len());
        assert_eq!(chunks.concat(), text);
        for c in &chunks[..chunks.len() - 1] {
            assert!(c.len() >= CHUNK_MIN && c.ends_with("\n\n"));
        }
    }

    #[test]
    fn fences_math_lists_and_tables_stay_whole() {
        let filler = para(0).repeat(6);
        let code = format!("```python\n{}\n\nx = 1\n```\n\n", "y = 2\n".repeat(400));
        let math = format!(
            "$$\n{}\n\n\\\\frac{{a}}{{b}}\n$$\n\n",
            "a + b\n".repeat(400)
        );
        let list = format!("{}\n", "- item\n\n".repeat(400));
        let table = format!("| a | b |\n|---|---|\n{}\n", "| 1 | 2 |\n".repeat(300));
        let text = format!("{filler}{code}{filler}{math}{filler}{list}{filler}{table}{filler}");
        let chunks = stable_chunks(&text);
        assert_eq!(chunks.concat(), text);
        for c in &chunks {
            assert_eq!(c.matches("```").count() % 2, 0, "a fence was cut: {c:.60}");
            assert_eq!(c.matches("$$").count() % 2, 0, "math was cut");
            assert!(!c.starts_with("- item"), "a list was cut");
            assert!(!c.starts_with("| 1"), "a table was cut");
        }
    }

    #[test]
    fn earlier_chunks_do_not_change_as_the_text_grows() {
        let full: String = (0..60).map(para).collect();
        let mut seen: Vec<String> = vec![];
        for end in (500..full.len()).step_by(997) {
            let mut end = end;
            while !full.is_char_boundary(end) {
                end += 1;
            }
            let chunks = stable_chunks(&full[..end]);
            // A chunk that was not the growing tail never changes again.
            let settled = seen
                .len()
                .saturating_sub(1)
                .min(chunks.len().saturating_sub(1));
            for i in 0..settled {
                assert_eq!(seen[i], chunks[i], "chunk {i} changed");
            }
            seen = chunks.iter().map(|c| c.to_string()).collect();
        }
    }
}

// ── Streaming hold-back ──────────────────────────────────────────────────

/// Longest stretch an open span is held back before it is shown as it is
/// (a literal `$`, `*` or `[` that never closes must not stall the answer).
const HOLD_DISPLAY_MATH: usize = 4_000;
const HOLD_INLINE: usize = 300;
/// An escaped `\$` that may open math: inline spans are short, and a prose
/// dollar must not hold the line for long.
const HOLD_ESCAPED_MATH: usize = 160;
const HOLD_STRONG: usize = 200;
const HOLD_EMPHASIS: usize = 80;
const HOLD_LINK: usize = 600;

/// How much of a streaming answer's markdown to draw: all of it but a
/// trailing span that has not closed yet, whose markup would otherwise
/// show raw for a moment and then snap into place (`$$T` before the
/// formula, `**bol` before the bold, half a fence line):
///
/// * display math (`$$`, `\[`) and inline math (`$`, `\(`): the daemon
///   escapes a prose dollar, so any other `$` is math;
/// * math still being written: the daemon escapes every `$` that does not
///   close a span *yet*, so mid-stream `\$v = \sqrt` is the start of
///   `$v = \sqrt{GM/r}$`. An escaped `$` before something that can start a
///   formula (not a space or a digit, so `\$5` stays a price) is held up
///   to a line break and [`HOLD_ESCAPED_MATH`]; an escaped `$$` starting a
///   line is held as display math until the paragraph ends;
/// * a code span, a fence line still being typed, and a fence whose code
///   has not begun (its box mounts with the first character of code);
/// * strong, emphasis and strikethrough runs that open but have not closed;
/// * a link or image still being written (`[text](https://exa`);
/// * a trailing escape, list marker or heading marker with nothing after it.
///
/// Inline spans are let go at a line break, and every hold is capped
/// (`HOLD_*`), so a stray delimiter costs a moment, never the answer. Code
/// inside an open fence shows as it arrives. Returns a byte offset on a
/// char boundary; the text before it is what to draw.
pub fn streaming_cut(md: &str) -> usize {
    let b = md.as_bytes();
    let len = b.len();
    let mut cut = len;
    let mut hold = |pos: usize, cap: usize| {
        if len - pos <= cap {
            cut = cut.min(pos);
        }
    };

    let mut fence: Option<(u8, usize)> = None;
    let mut display: Option<usize> = None;
    let mut inline_math: Option<usize> = None;
    // Escaped `\$$` / `\$` that may be math still being written.
    let mut esc_display: Option<usize> = None;
    let mut esc_inline: Option<usize> = None;
    let mut code: Option<(usize, usize)> = None;
    let mut emphasis: Vec<(u8, usize, usize)> = vec![];
    let mut brackets: Vec<usize> = vec![];
    let mut link: Option<(usize, usize)> = None;
    let mut i = 0;
    while i < len {
        // ── A line: fences, blank lines, markers.
        let line_end = md[i..].find('\n').map_or(len, |n| i + n);
        let line = &md[i..line_end];
        let complete = line_end < len;
        let body = line.trim_start_matches(' ');
        let indent = line.len() - body.len();
        let run = |c: u8| body.bytes().take_while(|x| *x == c).count();
        if let Some((c, n)) = fence {
            let closing = indent < 4 && run(c) >= n && body.trim_end().bytes().all(|x| x == c);
            if closing && complete {
                fence = None;
            } else if !complete && !body.is_empty() && body.bytes().all(|x| x == c) {
                // A closing fence being typed: not code text.
                hold(i, HOLD_INLINE);
            }
            i = line_end + 1;
            continue;
        }
        if display.is_none() && esc_display.is_none() && indent < 4 {
            let opener = b"`~".iter().copied().find(|c| run(*c) >= 3);
            if let Some(c) = opener {
                // A fence ends whatever inline span was open.
                (inline_math, code, link, esc_inline) = (None, None, None, None);
                emphasis.clear();
                brackets.clear();
                // Held while being typed, and until its code has begun: the
                // block's chrome (its box and language bar) mounts with the
                // first character of code, never as an empty "Python" box.
                if !complete || md[line_end + 1..].trim().is_empty() {
                    hold(i, HOLD_INLINE);
                }
                fence = Some((c, run(c)));
                i = line_end + 1;
                continue;
            }
        }
        if line.trim().is_empty() && complete {
            // A blank line ends the paragraph: what never closed was text.
            (inline_math, code, link) = (None, None, None);
            (esc_inline, esc_display) = (None, None);
            emphasis.clear();
            brackets.clear();
            i = line_end + 1;
            continue;
        }
        if !complete && display.is_none() && is_bare_marker(body) {
            hold(i, HOLD_INLINE);
        }

        // ── Inline, within the line.
        let mut j = i;
        while j < line_end {
            let c = b[j];
            if let Some((_, ticks)) = code {
                if c == b'`' {
                    let n = b[j..line_end].iter().take_while(|x| **x == b'`').count();
                    if n == ticks {
                        code = None;
                    }
                    j += n;
                } else {
                    j += 1;
                }
                continue;
            }
            match c {
                b'\\' => {
                    match b.get(j + 1) {
                        None => hold(j, HOLD_INLINE),
                        Some(b'[') if inline_math.is_none() && display.is_none() => {
                            display = Some(j)
                        }
                        Some(b']') if display.is_some() => display = None,
                        Some(b'(') if inline_math.is_none() && display.is_none() => {
                            inline_math = Some(j)
                        }
                        Some(b')') if inline_math.is_some() => inline_math = None,
                        Some(b'$') if display.is_none() && inline_math.is_none() => {
                            if md[j + 2..].starts_with("\\$") {
                                // `\$\$`: display math, when it starts a line.
                                if esc_display.is_some() {
                                    esc_display = None;
                                } else if md[i..j].trim().is_empty() {
                                    esc_display = Some(j);
                                    esc_inline = None;
                                }
                                j += 4;
                                continue;
                            }
                            if esc_display.is_none() {
                                let next = md[j + 2..].chars().next();
                                esc_inline = match esc_inline {
                                    Some(_) => None,
                                    None if next.is_none_or(|c| {
                                        !c.is_whitespace() && !c.is_ascii_digit()
                                    }) =>
                                    {
                                        Some(j)
                                    }
                                    None => None,
                                };
                            }
                        }
                        _ => {}
                    }
                    j += 2;
                    continue;
                }
                b'$' => {
                    if b.get(j + 1) == Some(&b'$') {
                        display = if display.is_some() { None } else { Some(j) };
                        inline_math = None;
                        j += 2;
                    } else {
                        if display.is_none() {
                            inline_math = if inline_math.is_some() { None } else { Some(j) };
                        }
                        j += 1;
                    }
                    continue;
                }
                _ if display.is_some()
                    || inline_math.is_some()
                    || esc_display.is_some()
                    || esc_inline.is_some() => {}
                b'`' => {
                    let n = b[j..line_end].iter().take_while(|x| **x == b'`').count();
                    code = Some((j, n));
                    j += n;
                    continue;
                }
                b'*' | b'_' | b'~' => {
                    let n = b[j..line_end].iter().take_while(|x| **x == c).count();
                    let prev = md[..j].chars().next_back();
                    let next = md[j + n..].chars().next();
                    flank(&mut emphasis, c, n, j, prev, next);
                    j += n;
                    continue;
                }
                b'[' => brackets.push(j),
                b']' => {
                    if let Some(open) = brackets.pop() {
                        match b.get(j + 1) {
                            Some(b'(') => {
                                link = Some((open, 0));
                                j += 2;
                                continue;
                            }
                            // `](` may be next.
                            None => brackets.push(open),
                            _ => {}
                        }
                    }
                }
                b'(' => {
                    if let Some((_, depth)) = &mut link {
                        *depth += 1;
                    }
                }
                b')' => match &mut link {
                    Some((_, 0)) => link = None,
                    Some((_, depth)) => *depth -= 1,
                    None => {}
                },
                _ => {}
            }
            j += 1;
        }
        if complete {
            // Inline spans and single emphasis do not run across lines here.
            (inline_math, code, link, esc_inline) = (None, None, None, None);
            emphasis.retain(|(_, n, _)| *n >= 2);
            brackets.clear();
        }
        i = line_end + 1;
    }

    if let Some(p) = display {
        hold(p, HOLD_DISPLAY_MATH);
    }
    if let Some(p) = inline_math {
        hold(p, HOLD_INLINE);
    }
    if let Some(p) = esc_display {
        hold(p, HOLD_DISPLAY_MATH);
    }
    if let Some(p) = esc_inline {
        hold(p, HOLD_ESCAPED_MATH);
    }
    if let Some((p, _)) = code {
        hold(p, HOLD_INLINE);
    }
    for (_, n, p) in &emphasis {
        hold(*p, if *n >= 2 { HOLD_STRONG } else { HOLD_EMPHASIS });
    }
    if let Some(p) = brackets.first() {
        hold(*p, HOLD_INLINE);
    }
    if let Some((p, _)) = link {
        hold(p, HOLD_LINK);
    }
    // A link is held from its `[`, an image from its `!`.
    if cut > 0 && cut < len && b[cut] == b'[' && b[cut - 1] == b'!' {
        cut -= 1;
    }
    cut
}

/// A line that is only a list, heading or quote marker so far.
fn is_bare_marker(body: &str) -> bool {
    let t = body.trim_end();
    if t.is_empty() {
        return false;
    }
    if matches!(t, "-" | "*" | "+" | ">") || t.bytes().all(|c| c == b'#') && t.len() <= 6 {
        return true;
    }
    let digits = t.bytes().take_while(u8::is_ascii_digit).count();
    digits > 0 && digits <= 9 && matches!(&t[digits..], "." | ")")
}

/// A run of `n` `c`s at `pos` between `prev` and `next` (CommonMark's
/// flanking rules, simplified): it closes the innermost open run of the
/// same character at least as long, or opens one.
fn flank(
    open: &mut Vec<(u8, usize, usize)>,
    c: u8,
    n: usize,
    pos: usize,
    prev: Option<char>,
    next: Option<char>,
) {
    if c == b'~' && n != 2 {
        return;
    }
    let space = |ch: Option<char>| ch.is_none_or(char::is_whitespace);
    let punct = |ch: Option<char>| ch.is_some_and(|c| c.is_ascii_punctuation());
    let Some(_) = next else {
        // The run ends the text so far: an opener being typed.
        if space(prev) || punct(prev) {
            open.push((c, n, pos));
        } else if let Some(ix) = open.iter().rposition(|(oc, on, _)| *oc == c && *on <= n) {
            open.truncate(ix);
        } else {
            open.push((c, n, pos));
        }
        return;
    };
    let left = !space(next) && (!punct(next) || space(prev) || punct(prev));
    let right = !space(prev) && (!punct(prev) || space(next) || punct(next));
    let (can_open, can_close) = match c {
        b'_' => (
            left && (!right || punct(prev)),
            right && (!left || punct(next)),
        ),
        // A single `*` inside a word or number (`2*3`) is not emphasis
        // often enough here to wait on it.
        b'*' if n == 1 => (left && !prev.is_some_and(char::is_alphanumeric), right),
        _ => (left, right),
    };
    if can_close && let Some(ix) = open.iter().rposition(|(oc, on, _)| *oc == c && *on <= n) {
        open.truncate(ix);
        return;
    }
    if can_open {
        open.push((c, n, pos));
    }
}

#[cfg(test)]
mod hold_back_tests {
    use super::*;

    fn shown(md: &str) -> &str {
        &md[..streaming_cut(md)]
    }

    #[test]
    fn open_math_waits_for_its_closing_delimiter() {
        let answer = "The orbital speed is $v = \\sqrt{GM/r}$ for a circular orbit, and the \
                      period follows from\n\n$$T = 2\\pi\\sqrt{\\frac{r^3}{GM}}$$\n\n\
                      so doubling $r$ multiplies $T$ by $2\\sqrt{2}$.";
        // Every prefix the stream can stop at: no raw `$` ever shows.
        for end in 0..=answer.len() {
            if !answer.is_char_boundary(end) {
                continue;
            }
            let text = shown(&answer[..end]);
            let dollars = text.matches('$').count();
            let doubles = text.matches("$$").count();
            assert_eq!(dollars % 2, 0, "{end}: {text:?}");
            assert_eq!(doubles % 2, 0, "{end}: {text:?}");
        }
        assert_eq!(
            shown("The orbital speed is $v = \\sq"),
            "The orbital speed is "
        );
        assert_eq!(shown("follows from\n\n$$T = 2"), "follows from\n\n");
        assert_eq!(shown("from \\[ x + "), "from ");
        assert_eq!(shown("so \\(x"), "so ");
        assert_eq!(shown(answer), answer, "a closed answer shows whole");
    }

    #[test]
    fn math_the_daemon_escaped_mid_stream_waits_too() {
        // What the daemon sends while a span is open: every unclosed `$`
        // escaped (its plain-markdown pass leaves only closed spans as
        // math), then the span as math once its closing `$` arrives.
        assert_eq!(
            shown("The orbital speed is \\$v ="),
            "The orbital speed is "
        );
        assert_eq!(shown("is \\$\\sqrt{GM"), "is ");
        assert_eq!(shown("is \\$"), "is ");
        assert_eq!(shown("is \\"), "is ");
        assert_eq!(
            shown("follows from\n\n\\$\\$\nT = 2\\pi\\sqrt{"),
            "follows from\n\n"
        );
        assert_eq!(shown("follows from\n\n\\$\\$T = 2"), "follows from\n\n");
        // Prices and other prose dollars do not wait.
        assert_eq!(shown("It costs \\$5 a month"), "It costs \\$5 a month");
        assert_eq!(shown("a \\$ sign"), "a \\$ sign");
        assert_eq!(shown("from \\$5 to \\$10"), "from \\$5 to \\$10");
        // A closed pair shows (the daemon found it was not math).
        assert_eq!(shown("echo \\$HOME\\$x"), "echo \\$HOME\\$x");
        // A dollar that never closes is let go at the line break…
        assert_eq!(shown("the \\$PATH var\nnext"), "the \\$PATH var\nnext");
        // …and, on one long line, after a short while.
        let long = format!("the \\$PATH variable {}", "word ".repeat(40));
        assert_eq!(shown(&long), long);
        // `$$` inside a line is not display math.
        assert_eq!(shown("pay \\$\\$ twice"), "pay \\$\\$ twice");
    }

    #[test]
    fn open_code_waits_but_code_in_an_open_fence_shows() {
        assert_eq!(shown("Call `orbit(pe"), "Call ");
        assert_eq!(shown("Call `orbit()` now"), "Call `orbit()` now");
        assert_eq!(shown("Here:\n\n```pyt"), "Here:\n\n");
        // The box comes with its code, never empty.
        assert_eq!(shown("Here:\n\n```python\n"), "Here:\n\n");
        assert_eq!(shown("Here:\n\n```python\n  \n"), "Here:\n\n");
        let first = "Here:\n\n```python\nd";
        assert_eq!(shown(first), first);
        let open_fence = "Here:\n\n```python\ndef orbit(p):\n    return 360 / p";
        assert_eq!(shown(open_fence), open_fence);
        let closing = "```python\nx = 1\n``";
        assert_eq!(shown(closing), "```python\nx = 1\n");
        // Markup inside a fence is code, never held.
        let code = "```\nprice = $5 * 3 **\n";
        assert_eq!(shown(code), code);
    }

    #[test]
    fn open_emphasis_and_links_wait_until_they_close() {
        assert_eq!(shown("This is **bol"), "This is ");
        assert_eq!(shown("This is **bold** and *it"), "This is **bold** and ");
        assert_eq!(
            shown("This is **bold** and *it*"),
            "This is **bold** and *it*"
        );
        assert_eq!(shown("A ~~gone"), "A ");
        assert_eq!(shown("See [the docs](https://exa"), "See ");
        assert_eq!(shown("See ![a chart](data:image/png"), "See ");
        assert_eq!(
            shown("See [the docs](https://example.org) too"),
            "See [the docs](https://example.org) too"
        );
        assert_eq!(shown("A list:\n\n-"), "A list:\n\n");
        assert_eq!(shown("A list:\n\n- one"), "A list:\n\n- one");
        assert_eq!(shown("Next:\n\n##"), "Next:\n\n");
    }

    #[test]
    fn literal_delimiters_never_stall_the_answer() {
        // Arithmetic, snake_case and list bullets are not emphasis.
        for text in [
            "2*3 = 6 and more",
            "use snake_case_names here",
            "* item one\n* item two",
        ] {
            assert_eq!(shown(text), text);
        }
        // An unclosed span is let go at the end of its line or paragraph.
        assert_eq!(shown("costs $5\nand more"), "costs $5\nand more");
        assert_eq!(shown("a `tick\n\nnext"), "a `tick\n\nnext");
        assert_eq!(shown("an [aside\nnext"), "an [aside\nnext");
        // And after its cap.
        let long = format!("a **{}", "word ".repeat(60));
        assert_eq!(shown(&long), long);
        let math = format!("$${}", "x + ".repeat(1_100));
        assert_eq!(shown(&math), math);
    }

    #[test]
    fn what_is_shown_only_grows_as_the_answer_streams() {
        let answer = "Intro with **bold**, `code`, $x^2$ and a [link](https://example.org).\n\n\
                      $$\nT = 2\\pi\n$$\n\n- one *two*\n- three\n\n```rust\nfn main() {}\n```\n\nEnd.";
        let mut last = 0;
        for end in 0..=answer.len() {
            let cut = streaming_cut(&answer[..end]);
            assert!(cut <= end);
            // Monotonic except where a span opens: the row keeps what it
            // drew (rows.rs), so only check the end is reached.
            last = last.max(cut);
        }
        assert_eq!(last, answer.len());
        assert_eq!(streaming_cut(answer), answer.len());
    }
}
