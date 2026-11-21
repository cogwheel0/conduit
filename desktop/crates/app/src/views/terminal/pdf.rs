//! A PDF from a terminal in a window of its own, opened at the page a model
//! names (`display_file`'s `page`), as mobile's terminal preview opens it
//! (`terminal_files_section.dart`: page 1 when none, or none that fits).
//! Quick Look cannot be told a page, so the page is PDFKit's: a `PDFView`
//! laid over the window's body, under the app's own toolbar (the file's
//! name, "Page 3 of 12", Save…). Scrolling, zoom and text selection are
//! PDFKit's own.

#[cfg(target_os = "macos")]
use std::cell::Cell;
use std::rc::Rc;
use std::sync::Arc;

use conduit_components::ActiveConduitTheme as _;
use conduit_components::assets::IconName;
use conduit_components::views::kit::IconButton;
#[cfg(target_os = "macos")]
use conduit_components::window::open_window_clear_root;
use conduit_components::window::{TOOLBAR_HEIGHT, TRAFFIC_LIGHTS_WIDTH, drag_region};
#[cfg(target_os = "macos")]
use futures::StreamExt as _;
use gpui_kit::prelude::*;
use gpui_kit::{App, Context, FocusHandle, FontWeight, Role, SharedString, Task, Window, div, px};
#[cfg(target_os = "macos")]
use gpui_kit::{Bounds, Pixels, WindowBounds, size};

use crate::actions::CloseWindow;
use crate::l10n::ActiveL10n as _;

/// The page a viewer opens at (0-based), for a model's 1-based `page` in a
/// document of `count` pages: the first when none is named or it is out of
/// range, as mobile's viewer.
pub fn start_index(page: Option<i64>, count: usize) -> usize {
    match page {
        Some(p) if p >= 1 && (p as usize) <= count => p as usize - 1,
        _ => 0,
    }
}

/// Opens `bytes` (a PDF called `name`) at `page`. False when PDFKit cannot
/// read it: the caller says the preview is unavailable.
pub fn open(bytes: Vec<u8>, name: String, page: Option<i64>, cx: &mut App) -> bool {
    #[cfg(target_os = "macos")]
    {
        let Some(document) = native::Document::read(&bytes) else {
            return false;
        };
        let bounds = Bounds::centered(None, size(px(760.), px(900.)), cx);
        let mut options = conduit_components::window::window_options(&name, bounds, false, true);
        options.window_bounds = Some(WindowBounds::Windowed(bounds));
        options.window_min_size = Some(size(px(360.), px(320.)));
        let start = start_index(page, document.count());
        let bytes = Arc::new(bytes);
        let opened = open_window_clear_root(options, cx, move |window, cx| {
            cx.new(|cx| PdfViewer::new(name, bytes, document, start, window, cx))
        });
        match opened {
            Ok((handle, view)) => {
                let open = &mut cx.default_global::<OpenPdfs>().0;
                open.retain(|(_, v)| v.upgrade().is_some());
                open.push((handle, view.downgrade()));
                true
            }
            Err(e) => {
                log::error!("could not open the PDF viewer: {e}");
                false
            }
        }
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = (bytes, name, page, cx);
        false
    }
}

/// The PDF windows open now (the E2E pass finds them here).
#[derive(Default)]
pub struct OpenPdfs(pub Vec<(gpui_kit::AnyWindowHandle, gpui_kit::WeakEntity<PdfViewer>)>);

impl gpui_kit::Global for OpenPdfs {}

pub struct PdfViewer {
    name: String,
    bytes: Arc<Vec<u8>>,
    #[cfg(target_os = "macos")]
    pdf: Option<Rc<native::Pdf>>,
    count: usize,
    /// The page in view, 0-based.
    page: usize,
    focus: FocusHandle,
    save_failed: bool,
    _pages: Option<Task<()>>,
}

impl PdfViewer {
    #[cfg(target_os = "macos")]
    fn new(
        name: String,
        bytes: Arc<Vec<u8>>,
        document: native::Document,
        start: usize,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Self {
        let focus = cx.focus_handle();
        window.focus(&focus, cx);
        let count = document.count();
        let (pages_tx, mut pages_rx) = futures::channel::mpsc::unbounded::<()>();
        let pdf = crate::shell::macos::ns_window(window)
            .and_then(|ns| native::Pdf::attach(&ns, document, pages_tx))
            .map(Rc::new);
        if pdf.is_none() {
            log::warn!("pdf viewer: PDFKit's view could not be attached");
        }
        // PDFKit goes to a page only once its view has a size and has laid
        // the document out: try each tick until the page asked for is in
        // view (two seconds at most).
        if start > 0 {
            cx.spawn(async move |this, cx| {
                for _ in 0..20 {
                    cx.background_executor()
                        .timer(std::time::Duration::from_millis(100))
                        .await;
                    let done = this
                        .update(cx, |s: &mut Self, cx| {
                            let Some(pdf) = s.pdf.as_ref() else {
                                return true;
                            };
                            if !pdf.has_size() {
                                return false;
                            }
                            pdf.go_to(start);
                            let at = pdf.current_page();
                            if at != s.page {
                                s.page = at;
                                cx.notify();
                            }
                            at == start
                        })
                        .unwrap_or(true);
                    if done {
                        break;
                    }
                }
            })
            .detach();
        }
        // The page in view follows PDFKit's page-changed notification.
        let pages = cx.spawn(async move |this, cx| {
            while pages_rx.next().await.is_some() {
                let alive = this.update(cx, |s: &mut Self, cx| {
                    if let Some(page) = s.pdf.as_ref().map(|p| p.current_page())
                        && page != s.page
                    {
                        s.page = page;
                        cx.notify();
                    }
                });
                if alive.is_err() {
                    break;
                }
            }
        });
        Self {
            name,
            bytes,
            pdf,
            count,
            page: start,
            focus,
            save_failed: false,
            _pages: Some(pages),
        }
    }

    /// The page in view (1-based) and the page count: the E2E pass.
    pub fn position(&self) -> (usize, usize) {
        (self.page + 1, self.count)
    }

    pub fn name(&self) -> &str {
        &self.name
    }

    /// Save…: the PDF as the terminal had it, where the user picks.
    fn save(&mut self, cx: &mut Context<Self>) {
        let name = crate::stores::files::safe_name(&self.name);
        let home = std::env::var_os("HOME")
            .map(std::path::PathBuf::from)
            .unwrap_or_else(|| std::path::PathBuf::from("/"));
        let dir = home.join("Downloads");
        let dir = if dir.is_dir() { dir } else { home };
        let asked = cx.prompt_for_new_path(&dir, Some(&name));
        let bytes = self.bytes.clone();
        cx.spawn(async move |this, cx| {
            let Ok(Ok(Some(path))) = asked.await else {
                return;
            };
            let failed = std::fs::write(&path, bytes.as_slice()).is_err();
            let _ = this.update(cx, |s: &mut Self, cx| {
                s.save_failed = failed;
                cx.notify();
            });
        })
        .detach();
    }
}

impl Render for PdfViewer {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let t = cx.conduit().clone();
        let r = t.roles;
        let m = t.metrics;
        let l10n = cx.l10n().clone();
        let position =
            l10n.desktop_pdf_page_position(&(self.page + 1).to_string(), &self.count.to_string());
        let save_label = l10n.desktop_preview_save();
        let save = IconButton::new("pdf-save", IconName::Download, save_label.clone())
            .size(28., 15.)
            .tooltip(save_label)
            .shortcut(Some(SharedString::from("\u{2318}S")))
            .on_click(Rc::new(cx.listener(|this, _, _, cx| this.save(cx))));
        #[cfg(target_os = "macos")]
        let place = {
            let pdf = self.pdf.clone();
            let last: Rc<Cell<Option<Bounds<Pixels>>>> = Rc::new(Cell::new(None));
            gpui_kit::canvas(
                move |bounds: Bounds<Pixels>, window: &mut Window, _: &mut App| {
                    if last.get() != Some(bounds) {
                        last.set(Some(bounds));
                        if let Some(pdf) = &pdf {
                            pdf.place(bounds, window);
                        }
                    }
                },
                |_, _, _, _| {},
            )
            .size_full()
        };
        #[cfg(not(target_os = "macos"))]
        let place = div();
        div()
            .id("pdf-viewer")
            .key_context("ConduitPdfViewer")
            .track_focus(&self.focus)
            .size_full()
            .flex()
            .flex_col()
            .bg(r.content)
            .on_action(cx.listener(|_, _: &CloseWindow, window, _| window.remove_window()))
            .on_key_down(cx.listener(|this, e: &gpui_kit::KeyDownEvent, window, cx| {
                let k = &e.keystroke;
                match (k.modifiers.platform, k.key.as_str()) {
                    (false, "escape") => window.remove_window(),
                    (true, "s") => this.save(cx),
                    _ => return,
                }
                cx.stop_propagation();
            }))
            .child(
                drag_region("pdf-titlebar")
                    .h(px(TOOLBAR_HEIGHT))
                    .flex_none()
                    .flex()
                    .items_center()
                    .gap(px(12.))
                    .pl(px(TRAFFIC_LIGHTS_WIDTH + 6.))
                    .pr(px(12.))
                    .border_b_1()
                    .border_color(r.border)
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .flex()
                            .flex_col()
                            .child(
                                div()
                                    .id("pdf-title")
                                    .role(Role::Heading)
                                    .aria_label(SharedString::from(self.name.clone()))
                                    .truncate()
                                    .text_size(px(m.control))
                                    .font_weight(FontWeight::SEMIBOLD)
                                    .text_color(r.text)
                                    .child(SharedString::from(self.name.clone())),
                            )
                            .child(
                                div()
                                    .id("pdf-position")
                                    .role(Role::Status)
                                    .text_size(px(m.small))
                                    .text_color(r.text_subtle)
                                    .child(SharedString::from(position)),
                            ),
                    )
                    .when(self.save_failed, |d| {
                        d.child(
                            div()
                                .id("pdf-save-failed")
                                .role(Role::Status)
                                .text_size(px(m.small))
                                .text_color(r.danger)
                                .child(SharedString::from(l10n.desktop_preview_save_failed())),
                        )
                    })
                    .child(
                        div()
                            .id("pdf-toolbar")
                            .role(Role::Toolbar)
                            .flex()
                            .items_center()
                            .child(save),
                    ),
            )
            .child(
                div()
                    .id("pdf-document")
                    .role(Role::Document)
                    .aria_label(SharedString::from(self.name.clone()))
                    .relative()
                    .flex_1()
                    .min_h_0()
                    .child(place),
            )
    }
}

#[cfg(target_os = "macos")]
mod native {
    use std::cell::Cell;

    use block2::RcBlock;
    use futures::channel::mpsc::UnboundedSender;
    use gpui_kit::{Bounds, Pixels, Window};
    use objc2::rc::{Allocated, Retained};
    use objc2::runtime::{AnyClass, AnyObject, Bool};
    use objc2::{class, msg_send};
    use objc2_foundation::{NSPoint, NSRect, NSSize, NSString};

    // PDFKit is part of macOS (10.4+); linked here, as nothing else does.
    #[link(name = "PDFKit", kind = "framework")]
    unsafe extern "C" {}

    /// `kPDFDisplaySinglePageContinuous`.
    const SINGLE_PAGE_CONTINUOUS: isize = 1;

    /// A parsed PDF (`PDFDocument`).
    pub struct Document {
        document: Retained<AnyObject>,
    }

    impl Document {
        /// None when PDFKit cannot read `bytes`, or it has no pages.
        pub fn read(bytes: &[u8]) -> Option<Self> {
            let class = AnyClass::get(c"PDFDocument")?;
            // SAFETY: Foundation and PDFKit on the main thread; every object
            // is retained by its `Retained`.
            unsafe {
                let data: Option<Retained<AnyObject>> = msg_send![
                    class!(NSData),
                    dataWithBytes: bytes.as_ptr().cast::<std::ffi::c_void>(),
                    length: bytes.len()
                ];
                let alloc: Allocated<AnyObject> = msg_send![class, alloc];
                let document: Option<Retained<AnyObject>> = msg_send![alloc, initWithData: &*data?];
                let document = document?;
                let count: usize = msg_send![&*document, pageCount];
                (count > 0).then_some(Self { document })
            }
        }

        pub fn count(&self) -> usize {
            // SAFETY: a read-only property.
            unsafe { msg_send![&*self.document, pageCount] }
        }
    }

    /// PDFKit's view, in a window's content view.
    pub struct Pdf {
        view: Retained<AnyObject>,
        document: Document,
        observer: Retained<AnyObject>,
        /// The frame last given (width, height).
        frame: Cell<(f64, f64)>,
    }

    impl Pdf {
        /// Puts a `PDFView` showing `document` into `window`; `pages` hears
        /// each change of the page in view.
        pub fn attach(
            window: &objc2_app_kit::NSWindow,
            document: Document,
            pages: UnboundedSender<()>,
        ) -> Option<Self> {
            let content = window.contentView()?;
            let class = AnyClass::get(c"PDFView")?;
            // SAFETY: AppKit on the main thread; the view is retained here
            // and by its superview, the observer token until drop.
            unsafe {
                let alloc: Allocated<AnyObject> = msg_send![class, alloc];
                let frame = NSRect::new(NSPoint::new(0., 0.), NSSize::new(10., 10.));
                let view: Option<Retained<AnyObject>> = msg_send![alloc, initWithFrame: frame];
                let view = view?;
                let _: () = msg_send![&*view, setAutoScales: Bool::YES];
                let _: () = msg_send![&*view, setDisplayMode: SINGLE_PAGE_CONTINUOUS];
                let _: () = msg_send![&*view, setDisplaysPageBreaks: Bool::YES];
                let _: () = msg_send![&*view, setDocument: &*document.document];
                let _: () = msg_send![&*content, addSubview: &*view];
                let block = RcBlock::new(move |_: *mut AnyObject| {
                    let _ = pages.unbounded_send(());
                });
                let name = NSString::from_str("PDFViewPageChangedNotification");
                let center: *mut AnyObject = msg_send![class!(NSNotificationCenter), defaultCenter];
                let queue: *mut AnyObject = msg_send![class!(NSOperationQueue), mainQueue];
                let observer: Option<Retained<AnyObject>> = msg_send![
                    center,
                    addObserverForName: &*name,
                    object: &*view,
                    queue: queue,
                    usingBlock: &*block
                ];
                let _: Bool = msg_send![window, makeFirstResponder: &*view];
                Some(Self {
                    view,
                    document,
                    observer: observer?,
                    frame: Cell::new((0., 0.)),
                })
            }
        }

        /// Lays the view over `bounds` (the window's body, in GPUI's
        /// top-left coordinates).
        pub fn place(&self, bounds: Bounds<Pixels>, window: &mut Window) {
            let Some(ns) = crate::shell::macos::ns_window(window) else {
                return;
            };
            let Some(content) = ns.contentView() else {
                return;
            };
            let height = content.frame().size.height;
            let (x, y, w, h) = (
                f64::from(f32::from(bounds.origin.x)),
                f64::from(f32::from(bounds.origin.y)),
                f64::from(f32::from(bounds.size.width)),
                f64::from(f32::from(bounds.size.height)),
            );
            let y = if content.isFlipped() {
                y
            } else {
                height - y - h
            };
            let frame = NSRect::new(NSPoint::new(x, y), NSSize::new(w, h));
            self.frame.set((w, h));
            // SAFETY: AppKit on the main thread.
            unsafe {
                let _: () = msg_send![&*self.view, setFrame: frame];
            }
        }

        /// Whether the view has been laid over the window's body.
        pub fn has_size(&self) -> bool {
            let (w, h) = self.frame.get();
            w > 10. && h > 10.
        }

        /// Shows page `index` (0-based).
        pub fn go_to(&self, index: usize) {
            // SAFETY: AppKit and PDFKit on the main thread.
            unsafe {
                let _: () = msg_send![&*self.view, layoutDocumentView];
                let page: Option<Retained<AnyObject>> =
                    msg_send![&*self.document.document, pageAtIndex: index];
                if let Some(page) = page {
                    let _: () = msg_send![&*self.view, goToPage: &*page];
                }
            }
        }

        /// The page in view, 0-based.
        pub fn current_page(&self) -> usize {
            // SAFETY: read-only properties.
            unsafe {
                let page: Option<Retained<AnyObject>> = msg_send![&*self.view, currentPage];
                match page {
                    Some(page) => msg_send![&*self.document.document, indexForPage: &*page],
                    None => 0,
                }
            }
        }
    }

    impl Drop for Pdf {
        fn drop(&mut self) {
            // SAFETY: AppKit on the main thread.
            unsafe {
                let center: *mut AnyObject = msg_send![class!(NSNotificationCenter), defaultCenter];
                let _: () = msg_send![center, removeObserver: &*self.observer];
                let _: () = msg_send![&*self.view, removeFromSuperview];
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_viewer_opens_at_the_named_page_or_the_first() {
        assert_eq!(start_index(Some(3), 12), 2);
        assert_eq!(start_index(Some(1), 12), 0);
        assert_eq!(start_index(Some(12), 12), 11);
        // None, nought, past the end: the first page, as mobile's viewer.
        assert_eq!(start_index(None, 12), 0);
        assert_eq!(start_index(Some(0), 12), 0);
        assert_eq!(start_index(Some(-2), 12), 0);
        assert_eq!(start_index(Some(13), 12), 0);
    }
}
