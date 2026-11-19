//! Pictures in an answer's markdown that it does not carry inline
//! (`![alt](https://…)`, `![alt](/api/v1/files/…)`).
//!
//! * **The account's server:** its files load through the daemon's
//!   authenticated `/files`, as attachments do, with no prompt.
//! * **Another site:** a compact placeholder names the site (and the
//!   picture's alt text) with Load Image, which loads that one picture, and
//!   a menu (also its context menu) with Always Load Images from <site>,
//!   which loads every picture from it, now and later (Settings › Chats
//!   lists those sites). A picture from anywhere can be a tracking pixel,
//!   so none is fetched before the user asks. The daemon fetches it
//!   (`stores::media`): no cookies, credentials or `Referer`, within a size
//!   and a time limit, once.
//! * **Loaded,** a picture behaves as the answer's other pictures: a click
//!   opens the viewer, and its context menu has Open Image, Copy Image and
//!   Save Image…. A failure says why, with Try Again.

use std::cell::RefCell;
use std::collections::HashMap;
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
    AnyElement, App, ElementId, ImageSource, MouseButton, MouseDownEvent, Role, SharedString,
    Window, div, img, px,
};

use super::blocks::{fit_image, spinner};
use crate::l10n::{ActiveL10n as _, L10n};
use crate::stores::files::{file_image_state, retry_file_image};
use crate::stores::media::{
    self, LinkTarget, LoadedImage, MediaError, ServerOrigin, classify, image_state,
};
use crate::views::image_viewer::{self, ViewerImage};

/// What a markdown picture holds.
#[derive(Clone, Debug)]
struct ImageLink {
    url: String,
    alt: String,
}

/// `![alt](url)` that is not a `data:` picture (TextView draws those).
pub struct ImagePlugin;

impl MarkdownPlugin for ImagePlugin {
    fn name(&self) -> &str {
        "conduit-chat-image"
    }

    fn parse(&self, node: &mdast::Node, _: &MarkdownParseContext<'_>) -> Option<MarkdownNode> {
        let mdast::Node::Image(image) = node else {
            return None;
        };
        if image.url.trim().starts_with("data:") {
            return None;
        }
        let alt = image.alt.trim().to_string();
        Some(
            MarkdownNode::new(
                "conduit-chat-image",
                ImageLink {
                    url: image.url.trim().to_string(),
                    alt: alt.clone(),
                },
            )
            .text(alt.clone())
            .accessibility_label(alt),
        )
    }

    fn render_inline(
        &self,
        node: &MarkdownNode,
        _: &InlineRenderContext,
        window: &mut Window,
        cx: &mut App,
    ) -> Option<InlineElement> {
        let link = node.data::<ImageLink>()?.clone();
        Some(InlineElement::new(markdown_image(
            &link.url, &link.alt, window, cx,
        )))
    }
}

/// One picture or PDF link of a paragraph that holds nothing else.
#[derive(Clone, Debug)]
enum MediaItem {
    Image { url: String, alt: String },
    Pdf { url: String, label: String },
}

/// A paragraph of pictures and PDF links and nothing else (the usual way
/// an answer shows them), drawn as blocks, one under another, as the
/// phone draws a picture standing alone: a placeholder at its own width,
/// a PDF as its card. In a sentence they stay inline ([`ImagePlugin`],
/// `pdf_card::PdfLinkPlugin`'s chip): an inline element can't take a line
/// of its own.
pub struct MediaBlockPlugin;

/// The paragraph's pictures and PDF links, when that is all it holds.
fn media_items(paragraph: &mdast::Paragraph) -> Option<Vec<MediaItem>> {
    let mut items = vec![];
    for child in &paragraph.children {
        match child {
            mdast::Node::Image(i) if !i.url.trim().starts_with("data:") => {
                items.push(MediaItem::Image {
                    url: i.url.trim().to_string(),
                    alt: i.alt.trim().to_string(),
                })
            }
            mdast::Node::Link(l) => {
                let label = super::pdf_card::node_text(child);
                if !super::pdf_card::is_pdf_link(&l.url)
                    && !super::pdf_card::is_named_pdf_file(&label, &l.url)
                {
                    return None;
                }
                items.push(MediaItem::Pdf {
                    url: l.url.trim().to_string(),
                    label,
                });
            }
            mdast::Node::Text(t) if t.value.trim().is_empty() => {}
            mdast::Node::Break(_) => {}
            _ => return None,
        }
    }
    (!items.is_empty()).then_some(items)
}

impl MarkdownPlugin for MediaBlockPlugin {
    fn is_block(&self) -> bool {
        true
    }

    fn name(&self) -> &str {
        "conduit-chat-media"
    }

    fn parse(&self, node: &mdast::Node, _: &MarkdownParseContext<'_>) -> Option<MarkdownNode> {
        let mdast::Node::Paragraph(p) = node else {
            return None;
        };
        let items = media_items(p)?;
        let text: Vec<String> = items
            .iter()
            .map(|i| match i {
                MediaItem::Image { alt, .. } => alt.clone(),
                MediaItem::Pdf { label, .. } => label.clone(),
            })
            .collect();
        Some(MarkdownNode::new("conduit-chat-media", items).text(text.join("\n")))
    }

    fn render(&self, node: &MarkdownNode, window: &mut Window, cx: &mut App) -> impl IntoElement {
        let items = node.data::<Vec<MediaItem>>().cloned().unwrap_or_default();
        let t = cx.conduit().clone();
        let children: Vec<AnyElement> = items
            .iter()
            .map(|item| match item {
                MediaItem::Image { url, alt } => markdown_image(url, alt, window, cx),
                MediaItem::Pdf { url, label } => super::pdf_card::pdf_card(url, label, window, cx)
                    .unwrap_or_else(|| {
                        div()
                            .text_color(t.roles.text_subtle)
                            .child(SharedString::from(label.clone()))
                            .into_any_element()
                    }),
            })
            .collect();
        // Each at its own width (a picture's frame hugs it), not stretched.
        div()
            .w_full()
            .flex()
            .flex_col()
            .items_start()
            .gap(px(4.))
            .children(children)
    }
}

/// What a context menu or the placeholder's menu asks for.
#[derive(Clone, Debug, PartialEq, gpui_kit::Action)]
#[action(namespace = conduit_images, no_json)]
pub enum ImageAction {
    /// Load Image: this address.
    Load(String),
    /// Always Load Images from this host.
    AllowHost(String),
    /// Open Image, Copy Image, Save Image…: the picture drawn under this
    /// key ([`remember`]).
    Open(String),
    Copy(String),
    Save(String),
    /// A PDF card's Open: an address in the browser, or a server file
    /// (`server id`, `file id`, name) in its app.
    OpenUrl(String),
    OpenFile(String, String, String),
}

thread_local! {
    /// The pictures drawn, by key, for their context menus' actions.
    static DRAWN: RefCell<HashMap<String, ViewerImage>> = RefCell::new(HashMap::new());
}

/// Keeps `image` under `key` for its menu (an action carries the key).
fn remember(key: &str, image: &ViewerImage) {
    DRAWN.with(|d| {
        let mut d = d.borrow_mut();
        if !d.contains_key(key) {
            if d.len() > 512 {
                d.clear();
            }
            d.insert(key.to_string(), image.clone());
        }
    });
}

fn drawn(key: &str) -> Option<ViewerImage> {
    DRAWN.with(|d| d.borrow().get(key).cloned())
}

/// The handlers for [`ImageAction`], app-wide: a native menu dispatches
/// to the window, where nothing else handles them.
pub fn register(cx: &mut App) {
    cx.on_action(|action: &ImageAction, cx| match action {
        ImageAction::Load(url) => media::load_once(url, cx),
        ImageAction::AllowHost(host) => media::allow_host(host, cx),
        ImageAction::Open(key) => {
            if let Some(image) = drawn(key) {
                image_viewer::open(vec![image], 0, cx);
            }
        }
        ImageAction::Copy(key) => {
            if let Some(image) = drawn(key) {
                image_viewer::copy_image(image, cx);
            }
        }
        ImageAction::Save(key) => {
            if let Some(image) = drawn(key) {
                image_viewer::save_image(image, cx);
            }
        }
        ImageAction::OpenUrl(url) => super::markdown::open_web_link(url, cx),
        ImageAction::OpenFile(server_id, file_id, name) => {
            crate::stores::files::open_attachment(
                crate::stores::files::FileRef {
                    server_id: server_id.clone(),
                    file_id: file_id.clone(),
                },
                name,
                crate::stores::files::OpenWith::DefaultApp,
                cx,
            )
            .detach();
        }
    });
}

/// A file name for a picture at `url`: its last path segment when that
/// names a picture, else its alt text, else "Image".
pub fn image_name(url: &str, alt: &str, l10n: &L10n) -> String {
    let segment = url::Url::parse(url)
        .ok()
        .and_then(|u| {
            u.path_segments()
                .and_then(|mut s| s.next_back().map(str::to_string))
        })
        .or_else(|| url.rsplit('/').next().map(str::to_string))
        .map(|s| {
            crate::stores::media::percent_decode(&s)
                .split(['?', '#'])
                .next()
                .unwrap_or_default()
                .to_string()
        })
        .filter(|s| s.contains('.') && !s.starts_with('.'));
    segment
        .or_else(|| (!alt.is_empty()).then(|| alt.to_string()))
        .unwrap_or_else(|| l10n.desktop_image_name())
}

fn key_of(url: &str, alt: &str) -> String {
    use std::hash::{Hash, Hasher};
    let mut h = std::collections::hash_map::DefaultHasher::new();
    url.hash(&mut h);
    alt.hash(&mut h);
    format!("{:x}", h.finish())
}

/// The element for a markdown picture at `url`.
pub fn markdown_image(url: &str, alt: &str, window: &mut Window, cx: &mut App) -> AnyElement {
    let t = cx.conduit().clone();
    let l10n = cx.l10n().clone();
    let server = ServerOrigin::active(cx);
    let key = key_of(url, alt);
    let name = image_name(url, alt, &l10n);
    match classify(url, server.as_ref()) {
        LinkTarget::ServerFile(file) => {
            let state = match file_image_state(&file, window, cx) {
                Some(Ok(render)) => Load::Ready(render, None),
                Some(Err(e)) if media::is_untrusted_svg(&e) => Load::Failed(MediaError::Untrusted),
                Some(Err(_)) => Load::Failed(MediaError::Failed),
                None => Load::Loading,
            };
            let viewer = ViewerImage::File {
                file: file.clone(),
                name: name.clone(),
            };
            let retry: Rc<dyn Fn(&mut App)> = Rc::new(move |cx| retry_file_image(&file, cx));
            let address = server
                .as_ref()
                .and_then(|s| url::Url::parse(&s.url).ok())
                .and_then(|base| base.join(url).ok())
                .map(|u| u.to_string());
            image_tile(
                &key, alt, &name, state, viewer, None, retry, address, &l10n, &t,
            )
        }
        LinkTarget::Server(url) => loaded_or_loading(&key, &url, None, alt, &name, window, cx),
        LinkTarget::Remote { url, host } => {
            if media::may_load(&url, &host, cx) {
                loaded_or_loading(&key, &url, Some(&host), alt, &name, window, cx)
            } else {
                placeholder(&key, &url, &host, alt, &l10n, &t)
            }
        }
        LinkTarget::Inline | LinkTarget::Unsupported => div()
            .text_color(t.roles.text_subtle)
            .child(SharedString::from(alt.to_string()))
            .into_any_element(),
    }
}

/// What a picture's tile shows.
enum Load {
    Loading,
    /// The frames, and its bytes when the tile has them (for the viewer).
    Ready(
        std::sync::Arc<gpui_kit::RenderImage>,
        Option<std::sync::Arc<gpui_kit::Image>>,
    ),
    Failed(MediaError),
}

#[allow(clippy::too_many_arguments)]
fn loaded_or_loading(
    key: &str,
    url: &str,
    host: Option<&str>,
    alt: &str,
    name: &str,
    window: &mut Window,
    cx: &mut App,
) -> AnyElement {
    let t = cx.conduit().clone();
    let l10n = cx.l10n().clone();
    let state = match image_state(url, window, cx) {
        Some(Ok(LoadedImage { encoded, render })) => Load::Ready(render, Some(encoded)),
        Some(Err(e)) => Load::Failed(e),
        None => Load::Loading,
    };
    let viewer = match &state {
        Load::Ready(_, Some(encoded)) => ViewerImage::Data {
            image: encoded.clone(),
            name: name.to_string(),
        },
        // Not drawn yet: nothing to open, copy or save.
        _ => ViewerImage::Data {
            image: std::sync::Arc::new(gpui_kit::Image::from_bytes(
                gpui_kit::ImageFormat::Png,
                vec![],
            )),
            name: name.to_string(),
        },
    };
    let retry_url = url.to_string();
    let retry: Rc<dyn Fn(&mut App)> = Rc::new(move |cx| media::retry_image(&retry_url, cx));
    let host = host
        .filter(|h| !media::host_allowed(h, cx))
        .map(str::to_string);
    image_tile(
        key,
        alt,
        name,
        state,
        viewer,
        host,
        retry,
        Some(url.to_string()),
        &l10n,
        &t,
    )
}

/// A loaded picture, its loading tile, or why it failed.
#[allow(clippy::too_many_arguments)]
fn image_tile(
    key: &str,
    alt: &str,
    name: &str,
    state: Load,
    viewer: ViewerImage,
    allow_host: Option<String>,
    retry: Rc<dyn Fn(&mut App)>,
    address: Option<String>,
    l10n: &L10n,
    t: &ConduitTheme,
) -> AnyElement {
    let r = t.roles;
    let m = t.metrics;
    let id = |part: &str| ElementId::Name(format!("md-image-{key}{part}").into());
    let label = SharedString::from(if alt.is_empty() {
        super::blocks::image_label(name).unwrap_or_else(|| l10n.desktop_attachment_image(name))
    } else {
        alt.to_string()
    });
    match state {
        Load::Ready(render, _) => {
            remember(key, &viewer);
            let size = render.size(0);
            let (w, h) = fit_image(size.width.0 as f32, size.height.0 as f32);
            let render = if t.dark {
                super::diagram::themed(&render, r.raised, r.text).unwrap_or(render)
            } else {
                render
            };
            let open_key = key.to_string();
            let menu_key = key.to_string();
            let menu = (
                l10n.desktop_open_image_menu(),
                l10n.desktop_copy_image(),
                l10n.desktop_save_image(),
                allow_host.map(|h| (l10n.desktop_always_load_images_from(&h), h)),
            );
            div()
                .id(id(""))
                .role(Role::Image)
                .aria_label(label)
                .aria_description(SharedString::from(name.to_string()))
                .flex_none()
                .my(px(4.))
                .rounded(t.card_radius())
                .overflow_hidden()
                .border_1()
                .border_color(if t.dark {
                    conduit_components::theme::dark_step(t.surfaces.panel, r.text, 3)
                } else {
                    r.border
                })
                .cursor_pointer()
                .child(img(ImageSource::Render(render)).w(px(w)).h(px(h)))
                .on_click(move |_, window, cx| {
                    cx.stop_propagation();
                    window.dispatch_action(Box::new(ImageAction::Open(open_key.clone())), cx);
                })
                .on_mouse_down(MouseButton::Right, move |e: &MouseDownEvent, window, cx| {
                    let (open, copy, save, allow) = menu.clone();
                    let mut native = NativeMenu::new()
                        .menu(open, Box::new(ImageAction::Open(menu_key.clone())))
                        .separator()
                        .menu(copy, Box::new(ImageAction::Copy(menu_key.clone())))
                        .menu(save, Box::new(ImageAction::Save(menu_key.clone())));
                    if let Some((text, host)) = allow {
                        native = native
                            .separator()
                            .menu(text, Box::new(ImageAction::AllowHost(host)));
                    }
                    native.show(e.position, window, cx);
                    cx.stop_propagation();
                })
                .into_any_element()
        }
        Load::Loading => div()
            .id(id(""))
            .role(Role::Image)
            .aria_label(label)
            .aria_description(SharedString::from(l10n.desktop_image_loading()))
            .my(px(4.))
            .w(px(288.))
            .h(px(144.))
            .flex()
            .items_center()
            .justify_center()
            .rounded(t.card_radius())
            .bg(r.raised)
            .border_1()
            .border_color(r.border)
            .child(spinner(id("-spinner"), 16., r.text_subtle))
            .into_any_element(),
        Load::Failed(error) => {
            let why = match error {
                MediaError::TooLarge => l10n.desktop_image_too_large(),
                MediaError::WrongType => l10n.desktop_image_not_an_image(),
                MediaError::TimedOut | MediaError::Failed | MediaError::Untrusted => {
                    l10n.desktop_image_load_failed()
                }
            };
            let action = failed_action(&error, address);
            div()
                .id(id(""))
                .role(Role::Group)
                .aria_label(SharedString::from(format!("{label}, {why}")))
                .my(px(4.))
                .w_full()
                .max_w(px(480.))
                .min_h(px(52.))
                .px(px(12.))
                .py(px(8.))
                .flex()
                .items_center()
                .gap(px(10.))
                .rounded(t.card_radius())
                .border_1()
                .border_color(r.border)
                .bg(r.raised)
                .child(icon(IconName::ImageOff, 18., r.text_subtle).flex_none())
                .child(
                    div()
                        .flex_1()
                        .min_w_0()
                        .flex()
                        .flex_col()
                        .child(
                            div()
                                .truncate()
                                .text_size(px(m.control))
                                .text_color(r.text)
                                .child(SharedString::from(name.to_string())),
                        )
                        .child(
                            div()
                                .text_size(px(m.small))
                                .text_color(r.text_subtle)
                                .child(SharedString::from(why)),
                        ),
                )
                .child(match action {
                    // An SVG from outside the app is never drawn here: the
                    // browser can show it.
                    FailedAction::OpenInBrowser(address) => {
                        Button::new(id("-open"), l10n.desktop_preview_open_in_browser()).on_click(
                            Rc::new(move |_, _, cx| super::markdown::open_web_link(&address, cx)),
                        )
                    }
                    FailedAction::Retry => Button::new(id("-retry"), l10n.desktop_try_again())
                        .on_click(Rc::new(move |_, window, cx| {
                            retry(cx);
                            window.refresh();
                        })),
                    FailedAction::None => {
                        Button::new(id("-retry"), l10n.desktop_try_again()).disabled(true)
                    }
                })
                .into_any_element()
        }
    }
}

/// What a picture that did not load offers.
#[derive(Debug, PartialEq, Eq)]
enum FailedAction {
    Retry,
    /// An SVG from outside the app, at its address.
    OpenInBrowser(String),
    /// An SVG from outside the app with no address to open.
    None,
}

/// [`FailedAction`] for `error`, the picture at `address`.
fn failed_action(error: &MediaError, address: Option<String>) -> FailedAction {
    match (error, address) {
        (MediaError::Untrusted, Some(address)) => FailedAction::OpenInBrowser(address),
        (MediaError::Untrusted, None) => FailedAction::None,
        _ => FailedAction::Retry,
    }
}

/// A placeholder's width: one width for every one, so a run of them lines
/// up (a long site name or alt text is cut short).
const PLACEHOLDER_WIDTH: f32 = 360.;

/// A picture from another site, not loaded: the site, the alt text, Load
/// Image, and a menu with Always Load Images from the site.
#[allow(clippy::too_many_arguments)]
fn placeholder(
    key: &str,
    url: &str,
    host: &str,
    alt: &str,
    l10n: &L10n,
    t: &ConduitTheme,
) -> AnyElement {
    let r = t.roles;
    let m = t.metrics;
    let id = |part: &str| ElementId::Name(format!("md-image-{key}{part}").into());
    let title = l10n.desktop_remote_image_from(host);
    let mut spoken = l10n.desktop_remote_image_label(host);
    if !alt.is_empty() {
        spoken = format!("{spoken}: {alt}");
    }
    let menu = {
        let load = (l10n.desktop_load_image(), url.to_string());
        let always = (l10n.desktop_always_load_images_from(host), host.to_string());
        move |position, window: &mut Window, cx: &mut App| {
            NativeMenu::new()
                .menu(load.0.clone(), Box::new(ImageAction::Load(load.1.clone())))
                .separator()
                .menu(
                    always.0.clone(),
                    Box::new(ImageAction::AllowHost(always.1.clone())),
                )
                .show(position, window, cx);
        }
    };
    let context_menu = menu.clone();
    let load_url = url.to_string();
    div()
        .id(id(""))
        .role(Role::Group)
        .aria_label(SharedString::from(spoken))
        .my(px(4.))
        .w_full()
        .max_w(px(PLACEHOLDER_WIDTH))
        .h(px(if alt.is_empty() { 44. } else { 52. }))
        .pl(px(12.))
        .pr(px(6.))
        .flex()
        .items_center()
        .gap(px(10.))
        .rounded(t.card_radius())
        .border_1()
        .border_color(r.border)
        .bg(conduit_components::views::kit::raised_fill(t))
        .child(icon(IconName::Image, 18., r.text_subtle).flex_none())
        .child(
            div()
                .flex_1()
                .min_w_0()
                .flex()
                .flex_col()
                .child(
                    div()
                        .truncate()
                        .text_size(px(m.control))
                        .text_color(r.text)
                        .child(SharedString::from(title)),
                )
                .when(!alt.is_empty(), |d| {
                    d.child(
                        div()
                            .truncate()
                            .text_size(px(m.small))
                            .text_color(r.text_subtle)
                            .child(SharedString::from(alt.to_string())),
                    )
                }),
        )
        .child(
            Button::new(id("-load"), l10n.desktop_load_image()).on_click(Rc::new(
                move |_, _, cx| {
                    cx.stop_propagation();
                    media::load_once(&load_url, cx);
                },
            )),
        )
        .child(
            IconButton::new(
                id("-options"),
                IconName::ChevronDown,
                l10n.desktop_image_options(),
            )
            .size(24., 14.)
            .round()
            .on_click(Rc::new(move |e, window, cx| {
                cx.stop_propagation();
                menu(e.position(), window, cx)
            })),
        )
        .on_mouse_down(MouseButton::Right, move |e: &MouseDownEvent, window, cx| {
            context_menu(e.position, window, cx);
            cx.stop_propagation();
        })
        .into_any_element()
}

/// The context menu and click for an answer's attached picture (the
/// `files` block), so every picture offers the same commands.
pub fn file_image_menu(
    key: &str,
    image: &ViewerImage,
    l10n: &L10n,
) -> impl Fn(&MouseDownEvent, &mut Window, &mut App) + 'static {
    remember(key, image);
    let key = key.to_string();
    let (open, copy, save) = (
        l10n.desktop_open_image_menu(),
        l10n.desktop_copy_image(),
        l10n.desktop_save_image(),
    );
    move |e, window, cx| {
        NativeMenu::new()
            .menu(open.clone(), Box::new(ImageAction::Open(key.clone())))
            .separator()
            .menu(copy.clone(), Box::new(ImageAction::Copy(key.clone())))
            .menu(save.clone(), Box::new(ImageAction::Save(key.clone())))
            .show(e.position, window, cx);
        cx.stop_propagation();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn text(v: &str) -> mdast::Node {
        mdast::Node::Text(mdast::Text {
            value: v.into(),
            position: None,
        })
    }

    fn image(url: &str) -> mdast::Node {
        mdast::Node::Image(mdast::Image {
            alt: "Tide chart".into(),
            url: url.into(),
            title: None,
            position: None,
        })
    }

    fn link(url: &str, label: &str) -> mdast::Node {
        mdast::Node::Link(mdast::Link {
            children: vec![text(label)],
            url: url.into(),
            title: None,
            position: None,
        })
    }

    fn paragraph(children: Vec<mdast::Node>) -> mdast::Paragraph {
        mdast::Paragraph {
            children,
            position: None,
        }
    }

    #[test]
    fn a_paragraph_of_pictures_and_pdfs_alone_is_drawn_as_blocks() {
        let items = media_items(&paragraph(vec![
            image("https://pictures.example.org/tide.png"),
            text("\n"),
            link("https://docs.example.org/guide.pdf", "Guide"),
        ]))
        .expect("pictures and PDFs alone");
        assert_eq!(items.len(), 2);
        // With words around them they stay inline.
        assert!(
            media_items(&paragraph(vec![
                text("See "),
                image("https://p.example.org/a.png")
            ]))
            .is_none()
        );
        assert!(
            media_items(&paragraph(vec![
                text("Read "),
                link("https://d.example.org/n.pdf", "the notes")
            ]))
            .is_none()
        );
        // A link that is not a PDF, or an inline `data:` picture.
        assert!(media_items(&paragraph(vec![link("https://example.org/", "site")])).is_none());
        assert!(media_items(&paragraph(vec![image("data:image/png;base64,AA")])).is_none());
    }

    /// A `%` before a character of several bytes (untrusted markdown) is
    /// kept as written, never sliced through.
    #[test]
    fn a_percent_before_a_wide_character_is_kept() {
        let l10n = L10n::new("en");
        assert_eq!(image_name("/%€-picture.png", "", &l10n), "%€-picture.png");
        assert_eq!(image_name("chart%中.png", "", &l10n), "chart%中.png");
    }

    /// An SVG from outside the app offers Open in Browser (it is never
    /// drawn here); any other failure offers Try Again.
    #[test]
    fn an_svg_from_outside_offers_open_in_browser() {
        let address = || Some("https://pictures.example/chart.svg".to_string());
        assert_eq!(
            failed_action(&MediaError::Untrusted, address()),
            FailedAction::OpenInBrowser("https://pictures.example/chart.svg".into())
        );
        assert_eq!(
            failed_action(&MediaError::Untrusted, None),
            FailedAction::None
        );
        assert_eq!(
            failed_action(&MediaError::Failed, address()),
            FailedAction::Retry
        );
        assert_eq!(
            failed_action(&MediaError::TooLarge, address()),
            FailedAction::Retry
        );
    }

    #[test]
    fn pictures_are_named_by_their_file_then_their_alt_text() {
        let l10n = L10n::new("en");
        assert_eq!(
            image_name(
                "https://pictures.example.org/tides/high%20water.png?x=1",
                "",
                &l10n
            ),
            "high water.png"
        );
        assert_eq!(
            image_name(
                "https://pictures.example.org/render?id=9",
                "Harbour map",
                &l10n
            ),
            "Harbour map"
        );
        assert_eq!(
            image_name("https://pictures.example.org/", "", &l10n),
            "Image"
        );
    }
}
