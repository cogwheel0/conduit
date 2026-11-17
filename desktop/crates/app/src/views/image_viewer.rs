//! The image viewer: an image from a reply or an attachment in a window of
//! its own, as the phone's `FullScreenImageViewer` shows it, with the Mac's
//! Preview conventions.
//!
//! * The picture fits the window (Zoom to Fit, ⌘9) or shows at its own
//!   size and more (Actual Size ⌘0, Zoom In ⌘+, Zoom Out ⌘−; a
//!   double-click toggles fit and actual size). Zoomed past the window it
//!   scrolls.
//! * The other images of the same message are a step away (← →, or the
//!   toolbar's arrows); the subtitle says which one this is.
//! * Share… (the system share menu) and Save… (a save panel, in Downloads
//!   first); the green button makes it full screen. Esc or ⌘W closes it.
//!
//! An image from the server is the one the transcript loaded through the
//! daemon's `/files`; Share and Save stage it in the daemon's staging
//! folder first.

use std::rc::Rc;
use std::sync::Arc;

use conduit_components::ActiveConduitTheme as _;
use conduit_components::assets::IconName;
use conduit_components::views::kit::IconButton;
use conduit_components::window::{
    TOOLBAR_HEIGHT, TRAFFIC_LIGHTS_WIDTH, drag_region, open_window_clear_root,
};
use gpui_kit::prelude::*;
use gpui_kit::{
    App, Bounds, Context, ElementId, FocusHandle, Focusable, FontWeight, Image, ImageSource,
    ObjectFit, RenderImage, Role, SharedString, Window, WindowBounds, div, img, px, size,
};

use crate::actions::{ActualSize, CloseWindow, ZoomIn, ZoomOut};
use crate::l10n::ActiveL10n as _;
use crate::stores::files::{FileRef, file_image_state, stage_bytes, stage_file};

/// One picture the viewer can show.
#[derive(Clone)]
pub enum ViewerImage {
    /// On the server, through the daemon's `/files`.
    File { file: FileRef, name: String },
    /// Carried inline by the message (a `data:` image).
    Data { image: Arc<Image>, name: String },
}

impl ViewerImage {
    pub fn name(&self) -> &str {
        match self {
            Self::File { name, .. } | Self::Data { name, .. } => name,
        }
    }
}

/// How large the picture is drawn.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Zoom {
    Fit,
    /// Times its own size.
    Scale(f32),
}

const ZOOM_STEPS: [f32; 9] = [0.25, 0.5, 0.75, 1., 1.5, 2., 3., 4., 6.];

/// The next zoom step from `zoom` (`fit` is the scale fitting the window).
pub fn step_zoom(zoom: Zoom, fit: f32, up: bool) -> Zoom {
    let current = match zoom {
        Zoom::Fit => fit,
        Zoom::Scale(s) => s,
    };
    let next = if up {
        ZOOM_STEPS.iter().copied().find(|s| *s > current + 0.01)
    } else {
        ZOOM_STEPS
            .iter()
            .rev()
            .copied()
            .find(|s| *s < current - 0.01)
    };
    Zoom::Scale(next.unwrap_or(current))
}

/// The scale at which a `w`×`h` picture fits `bw`×`bh` (never above its own
/// size, as Preview's Zoom to Fit for a small picture).
pub fn fit_scale(w: f32, h: f32, bw: f32, bh: f32) -> f32 {
    if w <= 0. || h <= 0. || bw <= 0. || bh <= 0. {
        return 1.;
    }
    (bw / w).min(bh / h).min(1.)
}

/// Opens the viewer on `images[start]`.
pub fn open(images: Vec<ViewerImage>, start: usize, cx: &mut App) {
    if images.is_empty() {
        return;
    }
    let start = start.min(images.len() - 1);
    let title = images[start].name().to_string();
    let bounds = Bounds::centered(None, size(px(900.), px(680.)), cx);
    let mut options = conduit_components::window::window_options(&title, bounds, false, true);
    options.window_bounds = Some(WindowBounds::Windowed(bounds));
    options.window_min_size = Some(size(px(360.), px(280.)));
    if let Err(e) = open_window_clear_root(options, cx, move |window, cx| {
        cx.new(|cx| ImageViewer::new(images, start, window, cx))
    }) {
        log::error!("could not open the image viewer: {e}");
    }
}

pub struct ImageViewer {
    images: Vec<ViewerImage>,
    index: usize,
    zoom: Zoom,
    focus: FocusHandle,
    /// The picture area's size last frame, for fit and zoom steps.
    area: Rc<std::cell::Cell<(f32, f32)>>,
    /// Decoded inline pictures, by index.
    decoded: std::collections::HashMap<usize, Arc<RenderImage>>,
    save_failed: bool,
}

impl ImageViewer {
    pub fn new(
        images: Vec<ViewerImage>,
        index: usize,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Self {
        let focus = cx.focus_handle();
        window.focus(&focus, cx);
        Self {
            images,
            index,
            zoom: Zoom::Fit,
            focus,
            area: Rc::new(std::cell::Cell::new((0., 0.))),
            decoded: Default::default(),
            save_failed: false,
        }
    }

    pub fn index(&self) -> usize {
        self.index
    }

    pub fn zoom(&self) -> Zoom {
        self.zoom
    }

    fn current(&self) -> &ViewerImage {
        &self.images[self.index]
    }

    /// The picture as GPUI draws it, once loaded.
    fn picture(&mut self, window: &mut Window, cx: &mut Context<Self>) -> Option<Arc<RenderImage>> {
        self.load(window, cx).ok().flatten()
    }

    /// The picture: `Ok(None)` while it loads, `Err` when it could not be
    /// read or decoded (the viewer says so, not "loading" for ever).
    fn load(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Result<Option<Arc<RenderImage>>, ()> {
        match self.current().clone() {
            ViewerImage::File { file, .. } => match file_image_state(&file, window, cx) {
                None => Ok(None),
                Some(result) => result.map(Some).map_err(|_| ()),
            },
            ViewerImage::Data { image, .. } => {
                if let Some(done) = self.decoded.get(&self.index) {
                    return Ok(Some(done.clone()));
                }
                let decoded = crate::stores::media::decode_picture(&image, cx.svg_renderer())
                    .map_err(|_| ())?;
                self.decoded.insert(self.index, decoded.clone());
                Ok(Some(decoded))
            }
        }
    }

    /// Try Again on a server picture that failed.
    fn retry(&mut self, _: &mut Window, cx: &mut Context<Self>) {
        if let ViewerImage::File { file, .. } = self.current().clone() {
            crate::stores::files::retry_file_image(&file, cx);
            cx.notify();
        }
    }

    pub fn go(&mut self, by: isize, window: &mut Window, cx: &mut Context<Self>) {
        let n = self.images.len() as isize;
        if n < 2 {
            return;
        }
        self.index = (self.index as isize + by).rem_euclid(n) as usize;
        self.zoom = Zoom::Fit;
        self.save_failed = false;
        window.set_window_title(self.current().name());
        cx.notify();
    }

    pub fn set_zoom(&mut self, zoom: Zoom, cx: &mut Context<Self>) {
        self.zoom = zoom;
        cx.notify();
    }

    fn step(&mut self, up: bool, window: &mut Window, cx: &mut Context<Self>) {
        let (aw, ah) = self.area.get();
        let fit = self
            .picture(window, cx)
            .map(|p| {
                let s = p.size(0);
                fit_scale(s.width.0 as f32, s.height.0 as f32, aw, ah)
            })
            .unwrap_or(1.);
        self.set_zoom(step_zoom(self.zoom, fit, up), cx);
    }

    /// Stages the picture as a file (Share, Save…).
    fn staged(&self, cx: &mut App) -> gpui_kit::Task<Result<std::path::PathBuf, String>> {
        match self.current().clone() {
            ViewerImage::File { file, name } => stage_file(file, &name, cx),
            ViewerImage::Data { image, name } => {
                let key = format!("inline-{:x}", hash(&image.bytes));
                gpui_kit::Task::ready(stage_bytes(image.bytes.clone(), &key, &name, cx))
            }
        }
    }

    fn save(&mut self, cx: &mut Context<Self>) {
        let name = crate::stores::files::safe_name(self.current().name());
        let dir = downloads();
        let asked = cx.prompt_for_new_path(&dir, Some(&name));
        let staged = self.staged(cx);
        cx.spawn(async move |this, cx| {
            let Ok(Ok(Some(path))) = asked.await else {
                return;
            };
            let failed = match staged.await {
                Ok(from) => std::fs::copy(&from, &path).is_err(),
                Err(e) => {
                    log::warn!("viewer: save: {e}");
                    true
                }
            };
            let _ = this.update(cx, |s: &mut Self, cx| {
                s.save_failed = failed;
                cx.notify();
            });
        })
        .detach();
    }

    fn share(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let staged = self.staged(cx);
        #[cfg(target_os = "macos")]
        let anchor = crate::shell::macos::ns_window(window);
        #[cfg(not(target_os = "macos"))]
        let _ = window;
        cx.spawn(async move |_, _| match staged.await {
            Ok(path) => {
                #[cfg(target_os = "macos")]
                if let Some(ns) = anchor {
                    share_file(&ns, &path);
                }
                #[cfg(not(target_os = "macos"))]
                let _ = path;
            }
            Err(e) => log::warn!("viewer: share: {e}"),
        })
        .detach();
    }
}

/// Copy Image: the picture on the clipboard, as its own bytes (a server
/// file is fetched first).
pub fn copy_image(image: ViewerImage, cx: &mut App) {
    match image {
        ViewerImage::Data { image, .. } => {
            cx.write_to_clipboard(gpui_kit::ClipboardItem::new_image(&image));
        }
        ViewerImage::File { file, name } => {
            let staged = stage_file(file, &name, cx);
            cx.spawn(async move |cx| match staged.await {
                Ok(path) => {
                    let Ok(bytes) = std::fs::read(&path) else {
                        return;
                    };
                    let Some(format) = crate::stores::files::image_format("", &bytes) else {
                        return;
                    };
                    let image = Image::from_bytes(format, bytes);
                    cx.update(|cx| {
                        cx.write_to_clipboard(gpui_kit::ClipboardItem::new_image(&image))
                    });
                }
                Err(e) => log::warn!("copy image: {e}"),
            })
            .detach();
        }
    }
}

/// Save Image…: a save panel (in Downloads at first), then the picture's
/// own bytes where it says.
pub fn save_image(image: ViewerImage, cx: &mut App) {
    let name = crate::stores::files::safe_name(image.name());
    let asked = cx.prompt_for_new_path(&downloads(), Some(&name));
    let staged = match image {
        ViewerImage::File { file, name } => stage_file(file, &name, cx),
        ViewerImage::Data { image, name } => {
            let key = format!("inline-{:x}", hash(&image.bytes));
            gpui_kit::Task::ready(stage_bytes(image.bytes.clone(), &key, &name, cx))
        }
    };
    cx.spawn(async move |_| {
        let Ok(Ok(Some(path))) = asked.await else {
            return;
        };
        match staged.await {
            Ok(from) => {
                if let Err(e) = std::fs::copy(&from, &path) {
                    log::warn!("save image: {e}");
                }
            }
            Err(e) => log::warn!("save image: {e}"),
        }
    })
    .detach();
}

fn hash(bytes: &[u8]) -> u64 {
    use std::hash::{Hash, Hasher};
    let mut h = std::collections::hash_map::DefaultHasher::new();
    bytes.hash(&mut h);
    h.finish()
}

fn downloads() -> std::path::PathBuf {
    let home = std::env::var_os("HOME")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|| std::path::PathBuf::from("/"));
    let d = home.join("Downloads");
    if d.is_dir() { d } else { home }
}

/// The system share menu for `path`, from the window's toolbar (where its
/// Share button is).
#[cfg(target_os = "macos")]
fn share_file(window: &objc2::rc::Retained<objc2_app_kit::NSWindow>, path: &std::path::Path) {
    use objc2::AnyThread as _;
    use objc2_app_kit::{NSSharingServicePicker, NSView};
    use objc2_foundation::{NSArray, NSPoint, NSRect, NSRectEdge, NSSize, NSString, NSURL};
    let Some(view): Option<objc2::rc::Retained<NSView>> = window.contentView() else {
        return;
    };
    let url = NSURL::fileURLWithPath(&NSString::from_str(&path.to_string_lossy()));
    let items = NSArray::from_retained_slice(&[objc2::rc::Retained::into_super(
        objc2::rc::Retained::into_super(url),
    )]);
    // SAFETY: an array of one file URL, as the picker takes.
    let picker =
        unsafe { NSSharingServicePicker::initWithItems(NSSharingServicePicker::alloc(), &items) };
    let frame = view.frame();
    // Under the toolbar's trailing end, where the Share button sits.
    let rect = NSRect::new(
        NSPoint::new(
            frame.size.width - 120.,
            frame.size.height - f64::from(TOOLBAR_HEIGHT),
        ),
        NSSize::new(24., f64::from(TOOLBAR_HEIGHT)),
    );
    picker.showRelativeToRect_ofView_preferredEdge(rect, &view, NSRectEdge::MinY);
}

impl Focusable for ImageViewer {
    fn focus_handle(&self, _: &App) -> FocusHandle {
        self.focus.clone()
    }
}

impl Render for ImageViewer {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let t = cx.conduit().clone();
        let r = t.roles;
        let m = t.metrics;
        let l10n = cx.l10n().clone();
        let count = self.images.len();
        let name = self.current().name().to_string();
        let title = if name.trim().is_empty() {
            l10n.desktop_image_viewer_title()
        } else {
            name.clone()
        };
        let loaded = self.load(window, cx);
        let failed = loaded.is_err();
        let picture = loaded.ok().flatten();
        let this = cx.entity().downgrade();
        let act = |f: fn(&mut ImageViewer, &mut Window, &mut Context<ImageViewer>)| {
            let this = this.clone();
            Rc::new(
                move |_: &gpui_kit::ClickEvent, window: &mut Window, cx: &mut App| {
                    let _ = this.update(cx, |s, cx| f(s, window, cx));
                },
            ) as conduit_components::views::kit::ClickHandler
        };
        let button = |id: &str, glyph: IconName, label: String, keys: Option<&str>| {
            let mut b = IconButton::new(
                ElementId::Name(format!("viewer-{id}").into()),
                glyph,
                label.clone(),
            )
            .size(28., 15.)
            .tooltip(label);
            if let Some(k) = keys {
                b = b.shortcut(Some(SharedString::from(k.to_string())));
            }
            b
        };
        let mut tools: Vec<gpui_kit::AnyElement> = vec![];
        if count > 1 {
            tools.push(
                button(
                    "previous",
                    IconName::ChevronLeft,
                    l10n.desktop_image_viewer_previous(),
                    Some("\u{2190}"),
                )
                .on_click(act(|s, w, cx| s.go(-1, w, cx)))
                .into_any_element(),
            );
            tools.push(
                button(
                    "next",
                    IconName::ChevronRight,
                    l10n.desktop_image_viewer_next(),
                    Some("\u{2192}"),
                )
                .on_click(act(|s, w, cx| s.go(1, w, cx)))
                .into_any_element(),
            );
        }
        tools.push(
            button(
                "zoom-out",
                IconName::ZoomOut,
                l10n.desktop_image_viewer_zoom_out(),
                Some("\u{2318}\u{2212}"),
            )
            .on_click(act(|s, w, cx| s.step(false, w, cx)))
            .into_any_element(),
        );
        tools.push(
            button(
                "zoom-in",
                IconName::ZoomIn,
                l10n.desktop_image_viewer_zoom_in(),
                Some("\u{2318}+"),
            )
            .on_click(act(|s, w, cx| s.step(true, w, cx)))
            .into_any_element(),
        );
        tools.push(if self.zoom == Zoom::Fit {
            button(
                "actual",
                IconName::Maximize2,
                l10n.desktop_image_viewer_actual_size(),
                Some("\u{2318}0"),
            )
            .on_click(act(|s, _, cx| s.set_zoom(Zoom::Scale(1.), cx)))
            .into_any_element()
        } else {
            button(
                "fit",
                IconName::Minimize2,
                l10n.desktop_image_viewer_zoom_to_fit(),
                Some("\u{2318}9"),
            )
            .on_click(act(|s, _, cx| s.set_zoom(Zoom::Fit, cx)))
            .into_any_element()
        });
        tools.push(
            button(
                "share",
                IconName::Share,
                l10n.desktop_image_viewer_share(),
                None,
            )
            .on_click(act(|s, w, cx| s.share(w, cx)))
            .into_any_element(),
        );
        tools.push(
            button(
                "save",
                IconName::Download,
                l10n.desktop_preview_save(),
                Some("\u{2318}S"),
            )
            .on_click(act(|s, _, cx| s.save(cx)))
            .into_any_element(),
        );
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
                    .child(SharedString::from(title.clone())),
            )
            .when(count > 1, |d| {
                d.child(
                    div()
                        .id("viewer-position")
                        .text_size(px(m.small))
                        .text_color(r.text_subtle)
                        .child(SharedString::from(l10n.desktop_image_viewer_position(
                            &(self.index + 1).to_string(),
                            &count.to_string(),
                        ))),
                )
            });
        let area = self.area.clone();
        let probe = gpui_kit::canvas(
            move |bounds: Bounds<gpui_kit::Pixels>, _, _| {
                area.set((f32::from(bounds.size.width), f32::from(bounds.size.height)));
            },
            |_, _, _, _| {},
        )
        .absolute()
        .size_full();
        let retryable = matches!(self.current(), ViewerImage::File { .. });
        let body: gpui_kit::AnyElement = match (&picture, self.zoom) {
            (None, _) if failed => div()
                .id("viewer-failed")
                .size_full()
                .flex()
                .flex_col()
                .gap(px(10.))
                .items_center()
                .justify_center()
                .child(
                    div()
                        .id("viewer-failed-text")
                        .role(Role::Status)
                        .text_size(px(m.small))
                        .text_color(r.text_subtle)
                        .child(SharedString::from(l10n.desktop_image_load_failed())),
                )
                .when(retryable, |d| {
                    d.child(
                        conduit_components::views::kit::Button::new(
                            "viewer-retry",
                            l10n.desktop_try_again(),
                        )
                        .on_click(act(Self::retry)),
                    )
                })
                .into_any_element(),
            (None, _) => div()
                .size_full()
                .flex()
                .items_center()
                .justify_center()
                .child(super::chat::blocks::spinner(
                    "viewer-loading",
                    18.,
                    r.text_subtle,
                ))
                .into_any_element(),
            (Some(p), Zoom::Fit) => img(ImageSource::Render(p.clone()))
                .size_full()
                .object_fit(ObjectFit::ScaleDown)
                .into_any_element(),
            (Some(p), Zoom::Scale(scale)) => {
                let s = p.size(0);
                let (w, h) = (s.width.0 as f32 * scale, s.height.0 as f32 * scale);
                div()
                    .id("viewer-scroll")
                    .size_full()
                    .overflow_scroll()
                    .child(
                        div()
                            .min_w_full()
                            .min_h_full()
                            .flex()
                            .items_center()
                            .justify_center()
                            .child(img(ImageSource::Render(p.clone())).w(px(w)).h(px(h))),
                    )
                    .into_any_element()
            }
        };
        let image_label = crate::views::chat::blocks::image_label(&name)
            .unwrap_or_else(|| l10n.desktop_attachment_image(&name));
        div()
            .id("image-viewer")
            .key_context("ConduitImageViewer")
            .track_focus(&self.focus)
            .size_full()
            .flex()
            .flex_col()
            .bg(r.content)
            .on_action(cx.listener(|_, _: &CloseWindow, window, _| window.remove_window()))
            // ⌘+, ⌘− and ⌘0 are the app's text-size shortcuts elsewhere:
            // here they zoom the picture (the key handler below never sees
            // them, the actions come first).
            .on_action(cx.listener(|this, _: &ZoomIn, window, cx| this.step(true, window, cx)))
            .on_action(cx.listener(|this, _: &ZoomOut, window, cx| this.step(false, window, cx)))
            .on_action(
                cx.listener(|this, _: &ActualSize, _, cx| this.set_zoom(Zoom::Scale(1.), cx)),
            )
            .on_key_down(cx.listener(|this, e: &gpui_kit::KeyDownEvent, window, cx| {
                let k = &e.keystroke;
                let cmd = k.modifiers.platform;
                match (cmd, k.key.as_str()) {
                    (false, "escape") | (false, "space") => window.remove_window(),
                    (false, "left") => this.go(-1, window, cx),
                    (false, "right") => this.go(1, window, cx),
                    (true, "=") | (true, "+") => this.step(true, window, cx),
                    (true, "-") => this.step(false, window, cx),
                    (true, "0") => this.set_zoom(Zoom::Scale(1.), cx),
                    (true, "9") => this.set_zoom(Zoom::Fit, cx),
                    (true, "s") => this.save(cx),
                    _ => return,
                }
                cx.stop_propagation();
            }))
            .child(
                drag_region("viewer-titlebar")
                    .h(px(TOOLBAR_HEIGHT))
                    .flex_none()
                    .flex()
                    .items_center()
                    .gap(px(12.))
                    .pl(px(TRAFFIC_LIGHTS_WIDTH + 6.))
                    .pr(px(12.))
                    .child(div().flex_1().min_w_0().child(heading))
                    .when(self.save_failed, |d| {
                        d.child(
                            div()
                                .id("viewer-save-failed")
                                .role(Role::Status)
                                .text_size(px(m.small))
                                .text_color(r.danger)
                                .child(SharedString::from(l10n.desktop_preview_save_failed())),
                        )
                    })
                    .child(
                        div()
                            .id("viewer-toolbar")
                            .role(Role::Toolbar)
                            .flex()
                            .items_center()
                            .gap(px(2.))
                            .children(tools),
                    ),
            )
            .child(
                div()
                    .id("viewer-image")
                    .role(Role::Image)
                    .aria_label(SharedString::from(image_label))
                    .relative()
                    .flex_1()
                    .min_h_0()
                    .p(px(12.))
                    .child(probe)
                    .on_click(cx.listener(|this, e: &gpui_kit::ClickEvent, _, cx| {
                        // A double-click toggles fit and actual size.
                        if e.click_count() == 2 {
                            let next = if this.zoom == Zoom::Fit {
                                Zoom::Scale(1.)
                            } else {
                                Zoom::Fit
                            };
                            this.set_zoom(next, cx);
                        }
                    }))
                    .child(body),
            )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[gpui_kit::test]
    fn a_picture_that_cannot_be_decoded_says_so(cx: &mut gpui_kit::TestAppContext) {
        cx.update(crate::views::test_globals);
        let broken = ViewerImage::Data {
            image: Arc::new(gpui_kit::Image::from_bytes(
                gpui_kit::ImageFormat::Png,
                b"not a picture".to_vec(),
            )),
            name: "chart.png".into(),
        };
        let (view, vcx) =
            cx.add_window_view(move |window, cx| ImageViewer::new(vec![broken], 0, window, cx));
        view.update_in(vcx, |v, window, cx| {
            assert_eq!(
                v.load(window, cx).map(|p| p.is_some()),
                Err(()),
                "loading for ever"
            );
        });
    }

    #[gpui_kit::test]
    fn the_zoom_shortcuts_zoom_the_picture(cx: &mut gpui_kit::TestAppContext) {
        cx.update(crate::views::test_globals);
        let none: Vec<ViewerImage> = vec![ViewerImage::Data {
            image: Arc::new(gpui_kit::Image::from_bytes(
                gpui_kit::ImageFormat::Png,
                vec![],
            )),
            name: String::new(),
        }];
        let (view, vcx) =
            cx.add_window_view(move |window, cx| ImageViewer::new(none, 0, window, cx));
        vcx.run_until_parked();
        vcx.dispatch_action(ActualSize);
        view.read_with(vcx, |v, _| assert_eq!(v.zoom(), Zoom::Scale(1.)));
        vcx.dispatch_action(ZoomOut);
        view.read_with(vcx, |v, _| {
            assert!(matches!(v.zoom(), Zoom::Scale(s) if s < 1.))
        });
    }

    #[test]
    fn zoom_steps_from_the_fit_or_the_scale() {
        assert_eq!(step_zoom(Zoom::Fit, 0.4, true), Zoom::Scale(0.5));
        assert_eq!(step_zoom(Zoom::Fit, 0.4, false), Zoom::Scale(0.25));
        assert_eq!(step_zoom(Zoom::Scale(1.), 1., true), Zoom::Scale(1.5));
        assert_eq!(step_zoom(Zoom::Scale(6.), 1., true), Zoom::Scale(6.));
        assert_eq!(step_zoom(Zoom::Scale(0.25), 1., false), Zoom::Scale(0.25));
    }

    #[test]
    fn a_small_picture_fits_at_its_own_size() {
        assert_eq!(fit_scale(200., 100., 800., 600.), 1.);
        assert!((fit_scale(1600., 1200., 800., 600.) - 0.5).abs() < 1e-6);
        assert_eq!(fit_scale(0., 10., 800., 600.), 1.);
    }
}
