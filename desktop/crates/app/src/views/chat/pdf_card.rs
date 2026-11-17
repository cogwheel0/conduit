//! A link to a PDF in an answer, as a card with its first page, as the
//! phone's `PdfInlineView` shows it.
//!
//! * **Which links:** those whose path (not query) ends in `.pdf`, core's
//!   `isPdfLink` rule; the card is titled by core's `pdfTitle` rule: the
//!   link's text without a leading 📄, else the file's name, else "PDF
//!   Document".
//! * **The preview:** the top of the first page, drawn by Quartz off the
//!   main thread (`stores::media`, never a web view), and the page count.
//!   A file on the account's server loads through the daemon's
//!   authenticated `/files`; a PDF on another site follows the pictures'
//!   rule: Load Preview loads that one, Always Load Previews from <site>
//!   every one from it (the same list as Always Load Images).
//! * **A click** opens the PDF as a link to it opens: a server file in its
//!   app (staged first, as attachments are), anything else in the browser.

use std::rc::Rc;

use conduit_components::ActiveConduitTheme as _;
use conduit_components::assets::{IconName, icon};
use conduit_components::theme::ConduitTheme;
use conduit_components::views::kit::{Button, IconButton};
use gpui_kit::base::text::{
    InlineElement, InlineRenderContext, MarkdownNode, MarkdownParseContext, MarkdownPlugin,
    markdown_ast as mdast,
};
use gpui_kit::component::native_menu::NativeMenu;
use gpui_kit::prelude::*;
use gpui_kit::{
    AnyElement, App, ElementId, FontWeight, ImageSource, MouseButton, MouseDownEvent, ObjectFit,
    Role, SharedString, Window, div, img, px,
};

use super::remote_image::ImageAction;
use crate::l10n::{ActiveL10n as _, L10n};
use crate::stores::files::{OpenWith, open_attachment};
use crate::stores::media::{
    self, LinkTarget, MediaError, PdfPreview, PdfSource, ServerOrigin, classify, pdf_state,
};

/// The card's widest (the phone's 560) and its preview's height.
const CARD_MAX: f32 = 560.;
const PREVIEW_HEIGHT: f32 = 180.;

/// Whether `href` points at a PDF: its path, not its query, ends in
/// `.pdf` (core's `isPdfLink`).
pub fn is_pdf_link(href: &str) -> bool {
    let href = href.trim();
    if href.is_empty() || href.starts_with(conduit_components::views::markdown::CITE_SCHEME) {
        return false;
    }
    let path = match url::Url::parse(href) {
        Ok(url) => url.path().to_string(),
        Err(_) => href
            .split(['?', '#'])
            .next()
            .unwrap_or_default()
            .to_string(),
    };
    crate::stores::media::percent_decode(&path)
        .to_lowercase()
        .ends_with(".pdf")
}

/// A server file (`/api/v1/files/{id}/content`, whose path never ends in
/// `.pdf`) that its link names as a PDF: `[harbour-guide.pdf](/api/…)`.
pub fn is_named_pdf_file(label: &str, href: &str) -> bool {
    let path = match url::Url::parse(href.trim()) {
        Ok(u) => u.path().to_string(),
        Err(_) => href
            .trim()
            .split(['?', '#'])
            .next()
            .unwrap_or_default()
            .to_string(),
    };
    label.trim().to_lowercase().ends_with(".pdf") && crate::stores::media::file_id(&path).is_some()
}

/// The card's title (core's `pdfTitle`): the link's text without a
/// leading 📄 when it says more than the address, else the file's name,
/// else `fallback`.
pub fn pdf_title(label: &str, url: &str, fallback: &str) -> String {
    let label = label.trim_start();
    let label = label.strip_prefix('\u{1F4C4}').unwrap_or(label).trim();
    if !label.is_empty() && label != url.trim() {
        return label.to_string();
    }
    let path = match url::Url::parse(url.trim()) {
        Ok(u) => u.path().to_string(),
        Err(_) => url
            .trim()
            .split(['?', '#'])
            .next()
            .unwrap_or_default()
            .to_string(),
    };
    path.split('/')
        .rfind(|s| !s.is_empty())
        .map(|s| crate::stores::media::percent_decode(s).trim().to_string())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| fallback.to_string())
}

/// The name a server PDF is staged under to open: its title, ending in
/// `.pdf` once.
fn pdf_file_name(title: &str) -> String {
    if title.to_lowercase().ends_with(".pdf") {
        title.to_string()
    } else {
        format!("{title}.pdf")
    }
}

#[derive(Clone, Debug)]
struct PdfLink {
    url: String,
    label: String,
}

/// `[text](….pdf)` as a card.
pub struct PdfLinkPlugin;

impl MarkdownPlugin for PdfLinkPlugin {
    fn name(&self) -> &str {
        "conduit-chat-pdf"
    }

    fn parse(&self, node: &mdast::Node, cx: &MarkdownParseContext<'_>) -> Option<MarkdownNode> {
        let mdast::Node::Link(link) = node else {
            return None;
        };
        // The link's text as written, without its markup.
        let label = node_text(node);
        if !is_pdf_link(&link.url) && !is_named_pdf_file(&label, &link.url) {
            return None;
        }
        let _ = cx;
        Some(
            MarkdownNode::new(
                "conduit-chat-pdf",
                PdfLink {
                    url: link.url.trim().to_string(),
                    label: label.clone(),
                },
            )
            .text(label.clone())
            .accessibility_label(label),
        )
    }

    fn render_inline(
        &self,
        node: &MarkdownNode,
        _: &InlineRenderContext,
        window: &mut Window,
        cx: &mut App,
    ) -> Option<InlineElement> {
        let link = node.data::<PdfLink>()?.clone();
        // In a sentence, a chip that opens it (a card on its own line is
        // `remote_image::MediaBlockPlugin`'s); a link with nothing to load
        // stays text.
        let _ = window;
        pdf_chip(&link.url, &link.label, cx).map(InlineElement::new)
    }
}

/// A node's text, its markup dropped.
pub(crate) fn node_text(node: &mdast::Node) -> String {
    match node {
        mdast::Node::Text(t) => t.value.clone(),
        mdast::Node::InlineCode(c) => c.value.clone(),
        other => other
            .children()
            .map(|c| c.iter().map(node_text).collect())
            .unwrap_or_default(),
    }
}

/// How a card opens its PDF.
#[derive(Clone)]
enum Opens {
    /// A server file: staged, then its app.
    File(crate::stores::files::FileRef, String),
    /// The browser.
    Url(String),
}

fn open(opens: &Opens, cx: &mut App) {
    match opens {
        Opens::File(file, name) => {
            open_attachment(file.clone(), name, OpenWith::DefaultApp, cx).detach();
        }
        Opens::Url(url) => super::markdown::open_web_link(url, cx),
    }
}

/// How `url` opens, for the account's server; `None` when it can't.
fn opens_of(url: &str, title: &str, cx: &App) -> Option<Opens> {
    let server = ServerOrigin::active(cx);
    match classify(url, server.as_ref()) {
        LinkTarget::ServerFile(file) => Some(Opens::File(file, pdf_file_name(title))),
        LinkTarget::Server(u) | LinkTarget::Remote { url: u, .. } => Some(Opens::Url(u)),
        LinkTarget::Inline | LinkTarget::Unsupported => None,
    }
}

/// A PDF link inside a sentence: a chip with its icon and title that opens
/// it, as a link would. Nothing is fetched for it; `None` for a link with
/// nothing to open.
pub fn pdf_chip(url: &str, label: &str, cx: &mut App) -> Option<AnyElement> {
    let t = cx.conduit().clone();
    let l10n = cx.l10n().clone();
    let r = t.roles;
    let title = pdf_title(label, url, &l10n.desktop_pdf_document());
    let opens = opens_of(url, &title, cx)?;
    let key = {
        use std::hash::{Hash, Hasher};
        let mut h = std::collections::hash_map::DefaultHasher::new();
        url.hash(&mut h);
        format!("{:x}", h.finish())
    };
    Some(
        div()
            .id(ElementId::Name(format!("pdf-chip-{key}").into()))
            .role(Role::Link)
            .aria_label(SharedString::from(l10n.desktop_open_pdf(&title)))
            .mx(px(1.))
            .px(px(5.))
            .h(px(t.metrics.body + 6.))
            .flex()
            .items_center()
            .gap(px(4.))
            .rounded(px(5.))
            .bg(conduit_components::theme::with_alpha(
                r.text,
                if t.dark { 0.12 } else { 0.06 },
            ))
            .hover(|s| s.bg(r.hover))
            .cursor_pointer()
            .child(icon(IconName::FileText, 13., r.text_subtle))
            .child(
                div()
                    .max_w(px(260.))
                    .truncate()
                    .text_color(r.text)
                    .child(SharedString::from(title)),
            )
            .on_click(move |_, _, cx| {
                cx.stop_propagation();
                open(&opens, cx)
            })
            .into_any_element(),
    )
}

/// The card for a PDF link; `None` for one with nothing to load (another
/// scheme, or a relative path with no server to resolve it against).
pub fn pdf_card(url: &str, label: &str, window: &mut Window, cx: &mut App) -> Option<AnyElement> {
    let t = cx.conduit().clone();
    let l10n = cx.l10n().clone();
    let title = pdf_title(label, url, &l10n.desktop_pdf_document());
    let key = {
        use std::hash::{Hash, Hasher};
        let mut h = std::collections::hash_map::DefaultHasher::new();
        url.hash(&mut h);
        format!("{:x}", h.finish())
    };
    let scale = window.scale_factor().max(1.);
    let (w, h) = (
        (CARD_MAX * scale).round() as u32,
        (PREVIEW_HEIGHT * scale).round() as u32,
    );
    let server = ServerOrigin::active(cx);
    // What it shows, and how it opens.
    let (preview, opens, remote): (Preview, Opens, Option<(String, String)>) =
        match classify(url, server.as_ref()) {
            LinkTarget::ServerFile(file) => {
                let source = PdfSource::File(file.clone());
                (
                    Preview::of(pdf_state(&source, w, h, window, cx), source),
                    Opens::File(file, pdf_file_name(&title)),
                    None,
                )
            }
            LinkTarget::Server(u) => {
                let source = PdfSource::Url(u.clone());
                (
                    Preview::of(pdf_state(&source, w, h, window, cx), source),
                    Opens::Url(u),
                    None,
                )
            }
            LinkTarget::Remote { url, host } => {
                if media::may_load(&url, &host, cx) {
                    let source = PdfSource::Url(url.clone());
                    (
                        Preview::of(pdf_state(&source, w, h, window, cx), source),
                        Opens::Url(url),
                        None,
                    )
                } else {
                    (
                        Preview::NotLoaded,
                        Opens::Url(url.clone()),
                        Some((url, host)),
                    )
                }
            }
            LinkTarget::Inline | LinkTarget::Unsupported => return None,
        };
    Some(card(
        &key,
        &title,
        preview,
        opens,
        remote,
        (w, h),
        &l10n,
        &t,
    ))
}

/// What a card's preview area shows.
enum Preview {
    NotLoaded,
    Loading,
    Ready(PdfPreview),
    /// Why, and the source to try again.
    Failed(MediaError, Option<PdfSource>),
}

impl Preview {
    fn of(state: Option<Result<PdfPreview, MediaError>>, source: PdfSource) -> Self {
        match state {
            None => Self::Loading,
            Some(Ok(p)) => Self::Ready(p),
            Some(Err(e)) => Self::Failed(e, Some(source)),
        }
    }
}

#[allow(clippy::too_many_arguments)]
fn card(
    key: &str,
    title: &str,
    preview: Preview,
    opens: Opens,
    remote: Option<(String, String)>,
    size: (u32, u32),
    l10n: &L10n,
    t: &ConduitTheme,
) -> AnyElement {
    let r = t.roles;
    let m = t.metrics;
    let id = |part: &str| ElementId::Name(format!("pdf-card-{key}{part}").into());
    let pages = match &preview {
        Preview::Ready(p) => Some(p.pages),
        _ => None,
    };
    let spoken = match (&preview, &remote) {
        (Preview::NotLoaded, Some((_, host))) => l10n.desktop_pdf_not_loaded(title, host),
        _ => title.to_string(),
    };
    let area = div()
        .id(id("-preview"))
        .w_full()
        .h(px(PREVIEW_HEIGHT))
        .flex()
        .items_center()
        .justify_center()
        .overflow_hidden()
        .bg(if matches!(preview, Preview::Ready(_)) {
            gpui_kit::white()
        } else {
            r.content
        });
    let area = match preview {
        Preview::Ready(p) => area
            .items_start()
            .child(
                img(ImageSource::Render(p.page))
                    .w_full()
                    .h(px(PREVIEW_HEIGHT))
                    .object_fit(ObjectFit::Cover),
            )
            .into_any_element(),
        Preview::Loading => area
            .child(super::blocks::spinner(id("-spinner"), 16., r.text_subtle))
            .into_any_element(),
        Preview::NotLoaded => {
            let (url, host) = remote.clone().unwrap_or_default();
            let menu_url = url.clone();
            let menu_host = host.clone();
            let menu_text = (
                l10n.desktop_load_preview(),
                l10n.desktop_always_load_previews_from(&host),
            );
            area.flex_col()
                .gap(px(8.))
                .child(icon(IconName::FileText, 28., r.text_subtle))
                .child(
                    div()
                        .text_size(px(m.small))
                        .text_color(r.text_subtle)
                        .child(SharedString::from(l10n.desktop_pdf_from(&host))),
                )
                .child(
                    div()
                        .flex()
                        .items_center()
                        .gap(px(4.))
                        .child(
                            Button::new(id("-load"), l10n.desktop_load_preview()).on_click(
                                Rc::new(move |_, _, cx| {
                                    cx.stop_propagation();
                                    media::load_once(&url, cx);
                                }),
                            ),
                        )
                        .child(
                            IconButton::new(
                                id("-options"),
                                IconName::ChevronDown,
                                l10n.desktop_preview_options(),
                            )
                            .size(24., 14.)
                            .round()
                            .on_click(Rc::new(move |e, window, cx| {
                                cx.stop_propagation();
                                NativeMenu::new()
                                    .menu(
                                        menu_text.0.clone(),
                                        Box::new(ImageAction::Load(menu_url.clone())),
                                    )
                                    .separator()
                                    .menu(
                                        menu_text.1.clone(),
                                        Box::new(ImageAction::AllowHost(menu_host.clone())),
                                    )
                                    .show(e.position(), window, cx);
                            })),
                        ),
                )
                .into_any_element()
        }
        Preview::Failed(error, source) => {
            let why = match error {
                MediaError::TooLarge => l10n.desktop_pdf_too_large(),
                _ => l10n.desktop_pdf_preview_failed(),
            };
            let (w, h) = size;
            area.flex_col()
                .gap(px(8.))
                .child(icon(IconName::FileText, 28., r.text_subtle))
                .child(
                    div()
                        .text_size(px(m.small))
                        .text_color(r.text_subtle)
                        .child(SharedString::from(why)),
                )
                .when_some(source, |d, source| {
                    d.child(
                        Button::new(id("-retry"), l10n.desktop_try_again()).on_click(Rc::new(
                            move |_, window, cx| {
                                cx.stop_propagation();
                                media::retry_pdf(&source, w, h, cx);
                                window.refresh();
                            },
                        )),
                    )
                })
                .into_any_element()
        }
    };
    let open_label = match pages {
        Some(n) => format!(
            "{}, {}",
            l10n.desktop_open_pdf(title),
            l10n.desktop_pdf_pages(n as i64)
        ),
        None => l10n.desktop_open_pdf(title),
    };
    let bar = div()
        .id(id("-open"))
        .role(Role::Button)
        .aria_label(SharedString::from(open_label))
        .h(px(44.))
        .px(px(12.))
        .flex()
        .items_center()
        .gap(px(8.))
        .border_t_1()
        .border_color(r.border)
        .child(icon(IconName::FileText, 16., r.text_subtle).flex_none())
        .child(
            div()
                .flex_1()
                .min_w_0()
                .flex()
                .items_baseline()
                .gap(px(6.))
                .child(
                    div()
                        .min_w_0()
                        .truncate()
                        .text_size(px(m.control))
                        .font_weight(FontWeight::SEMIBOLD)
                        .text_color(r.text)
                        .child(SharedString::from(title.to_string())),
                )
                .when_some(pages, |d, n| {
                    d.child(
                        div()
                            .flex_none()
                            .text_size(px(m.small))
                            .text_color(r.text_subtle)
                            .child(SharedString::from(l10n.desktop_pdf_pages(n as i64))),
                    )
                }),
        )
        .child(icon(IconName::ArrowUpRight, 15., r.text_subtle).flex_none());
    let click = opens.clone();
    let context_opens = opens;
    let open_text = l10n.desktop_open_pdf_menu();
    let allow = remote.map(|(_, host)| (l10n.desktop_always_load_previews_from(&host), host));
    div()
        .id(id(""))
        .role(Role::Group)
        .aria_label(SharedString::from(spoken))
        .my(px(4.))
        .w_full()
        .max_w(px(CARD_MAX))
        .flex()
        .flex_col()
        .rounded(t.card_radius())
        .border_1()
        .border_color(r.border)
        .bg(conduit_components::views::kit::raised_fill(t))
        .overflow_hidden()
        .cursor_pointer()
        .hover(|s| s.border_color(r.text_faint))
        .child(area)
        .child(bar)
        .on_click(move |_, _, cx| open(&click, cx))
        .on_mouse_down(MouseButton::Right, move |e: &MouseDownEvent, window, cx| {
            let opens = context_opens.clone();
            let mut menu = NativeMenu::new();
            match &opens {
                Opens::Url(url) => {
                    menu = menu.menu(
                        open_text.clone(),
                        Box::new(ImageAction::OpenUrl(url.clone())),
                    );
                }
                Opens::File(file, name) => {
                    menu = menu.menu(
                        open_text.clone(),
                        Box::new(ImageAction::OpenFile(
                            file.server_id.clone(),
                            file.file_id.clone(),
                            name.clone(),
                        )),
                    );
                }
            }
            if let Some((text, host)) = allow.clone() {
                menu = menu
                    .separator()
                    .menu(text, Box::new(ImageAction::AllowHost(host)));
            }
            menu.show(e.position, window, cx);
            cx.stop_propagation();
        })
        .into_any_element()
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A `%` before a character of several bytes (untrusted markdown) is
    /// kept as written, never sliced through.
    #[test]
    fn a_percent_before_a_wide_character_is_kept() {
        assert!(is_pdf_link("/%€-guide.pdf"));
        assert!(is_pdf_link("report%中.pdf"));
        assert_eq!(pdf_title("", "report%中.pdf", "PDF"), "report%中.pdf");
    }

    #[test]
    fn pdf_links_end_in_pdf_by_their_path() {
        assert!(is_pdf_link("https://docs.example.org/tide-tables.pdf"));
        assert!(is_pdf_link(
            "https://docs.example.org/Tide%20Tables.PDF?download=1"
        ));
        assert!(is_pdf_link("/api/v1/files/f-1/content/notes.pdf"));
        assert!(!is_pdf_link("https://docs.example.org/view?file=a.pdf"));
        assert!(!is_pdf_link("https://docs.example.org/a.pdf.html"));
        assert!(!is_pdf_link("conduit-cite:1"));
        assert!(!is_pdf_link(""));
        // A server file the link names as a PDF.
        assert!(is_named_pdf_file(
            "harbour-guide.pdf",
            "/api/v1/files/f-9/content"
        ));
        assert!(!is_named_pdf_file(
            "Harbour guide",
            "/api/v1/files/f-9/content"
        ));
        assert!(!is_named_pdf_file(
            "guide.pdf",
            "https://docs.example.org/view"
        ));
    }

    #[test]
    fn cards_are_titled_by_the_link_then_the_file() {
        let u = "https://docs.example.org/files/harbour%20guide.pdf";
        assert_eq!(
            pdf_title("\u{1F4C4} Harbour Guide", u, "PDF Document"),
            "Harbour Guide"
        );
        assert_eq!(pdf_title(u, u, "PDF Document"), "harbour guide.pdf");
        assert_eq!(pdf_title("", u, "PDF Document"), "harbour guide.pdf");
        assert_eq!(
            pdf_title("", "https://docs.example.org/", "PDF Document"),
            "PDF Document"
        );
    }
}
