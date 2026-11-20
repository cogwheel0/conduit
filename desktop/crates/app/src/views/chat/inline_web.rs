//! A native web view (WKWebView, through wry) drawn inline in a GPUI
//! window: an embed or an MCP App in the transcript.
//!
//! GPUI draws into one Metal layer; a native view sits above all of it. So
//! each inline web view lives in a clipping container (`clipsToBounds`), a
//! subview of the window's content view, which every frame that draws it
//! is set to the part of its place that shows (the transcript's content
//! mask), with the web view offset inside it. It never covers the toolbar
//! or the composer, which lie outside that mask.
//!
//! A frame that does not draw it (scrolled out of the virtualized list, or
//! another pane shown) must hide it, or it would stay where it last was.
//! [`frame_start`] and [`frame_end`] bracket a window's root: each frame
//! counts, every inline view drawn records the count, and the end hides
//! the window's views that were not drawn. Dropping the view takes it out
//! of the window.

use std::cell::{Cell, RefCell};
use std::collections::HashMap;
use std::rc::{Rc, Weak};

use gpui_kit::prelude::*;
use gpui_kit::{AnyElement, App, Bounds, HitboxBehavior, Pixels, Window, canvas, div, px};

/// The windows' frame counts and the inline views drawn in them.
#[derive(Default)]
struct Frames {
    count: u64,
    views: Vec<Weak<InlineWebView>>,
}

thread_local! {
    static FRAMES: RefCell<HashMap<u64, Frames>> = RefCell::new(HashMap::new());
}

fn window_key(window: &Window) -> u64 {
    window.window_handle().window_id().as_u64()
}

/// Opens a frame of `window`: put first in its root.
pub fn frame_start() -> AnyElement {
    canvas(
        |_, window, _| {
            let key = window_key(window);
            FRAMES.with(|f| f.borrow_mut().entry(key).or_default().count += 1);
        },
        |_, _, _, _| {},
    )
    .absolute()
    .size_0()
    .into_any_element()
}

/// Closes a frame of `window`: put last in its root. Hides the inline
/// views it did not draw.
pub fn frame_end() -> AnyElement {
    canvas(
        |_, window, _| {
            let key = window_key(window);
            let stale: Vec<Rc<InlineWebView>> = FRAMES.with(|f| {
                let mut frames = f.borrow_mut();
                let Some(frame) = frames.get_mut(&key) else {
                    return vec![];
                };
                let count = frame.count;
                frame.views.retain(|v| v.strong_count() > 0);
                frame
                    .views
                    .iter()
                    .filter_map(Weak::upgrade)
                    .filter(|v| v.seen.get() != count)
                    .collect()
            });
            for view in stale {
                view.hide();
            }
        },
        |_, _, _, _| {},
    )
    .absolute()
    .size_0()
    .into_any_element()
}

/// One inline web view and its clipping container.
pub struct InlineWebView {
    #[cfg(target_os = "macos")]
    inner: mac::Inner,
    seen: Cell<u64>,
    shown: Cell<bool>,
}

impl InlineWebView {
    /// Builds `builder` as a web view in `window`, hidden until drawn.
    #[cfg(target_os = "macos")]
    pub fn new(builder: wry::WebViewBuilder, window: &Window) -> Option<Rc<Self>> {
        let inner = mac::Inner::new(builder, window)?;
        Some(Rc::new(Self {
            inner,
            seen: Cell::new(0),
            shown: Cell::new(false),
        }))
    }

    #[cfg(not(target_os = "macos"))]
    pub fn new(_: wry::WebViewBuilder, _: &Window) -> Option<Rc<Self>> {
        None
    }

    /// A video player (AVPlayerView, with its own controls and full-screen
    /// button) for the movie at `path`, hidden until drawn; it starts
    /// playing.
    #[cfg(target_os = "macos")]
    pub fn player(path: &std::path::Path, window: &Window) -> Option<Rc<Self>> {
        let inner = mac::Inner::player(path, window)?;
        Some(Rc::new(Self {
            inner,
            seen: Cell::new(0),
            shown: Cell::new(false),
        }))
    }

    #[cfg(not(target_os = "macos"))]
    pub fn player(_: &std::path::Path, _: &Window) -> Option<Rc<Self>> {
        None
    }

    /// The web view, to run scripts in (none for a player).
    #[cfg(target_os = "macos")]
    pub fn webview(&self) -> &wry::WebView {
        match &self.inner.content {
            mac::Content::Web(w) => w,
            mac::Content::View(_) => unreachable!("a player has no web view"),
        }
    }

    /// The player takes the whole screen (AVPlayerView's own full screen).
    pub fn enter_full_screen(&self) {
        #[cfg(target_os = "macos")]
        self.inner.enter_full_screen();
    }

    /// Stops the player's sound and picture (it goes with its view).
    pub fn pause(&self) {
        #[cfg(target_os = "macos")]
        self.inner.pause();
    }

    /// Hides it (not drawn this frame); a playing video stops, rather than
    /// go on playing sound where it can't be seen.
    fn hide(&self) {
        if self.shown.replace(false) {
            #[cfg(target_os = "macos")]
            {
                self.inner.set_hidden(true);
                self.inner.pause();
            }
        }
    }

    /// Puts the view at `document` (window coordinates), showing only the
    /// part inside `clip`.
    fn place(&self, document: Bounds<Pixels>, clip: Bounds<Pixels>) {
        let visible = document.intersect(&clip);
        if visible.size.width <= px(0.) || visible.size.height <= px(0.) {
            self.hide();
            return;
        }
        #[cfg(target_os = "macos")]
        self.inner.place(document, visible);
        if !self.shown.replace(true) {
            #[cfg(target_os = "macos")]
            self.inner.set_hidden(false);
        }
    }
}

/// The element that shows `view` in its place: as wide as its parent and
/// `height` tall.
pub fn inline_web(view: Rc<InlineWebView>, height: f32) -> AnyElement {
    let placed = view.clone();
    div()
        .w_full()
        .h(px(height))
        .child(
            canvas(
                move |bounds, window, _: &mut App| {
                    let key = window_key(window);
                    let count = FRAMES.with(|f| {
                        let mut frames = f.borrow_mut();
                        let frame = frames.entry(key).or_default();
                        if !frame
                            .views
                            .iter()
                            .any(|v| v.as_ptr() == Rc::as_ptr(&placed))
                        {
                            frame.views.push(Rc::downgrade(&placed));
                        }
                        frame.count
                    });
                    placed.seen.set(count);
                    let clip = window.content_mask().bounds;
                    placed.place(bounds, clip);
                    // The native view takes the clicks over its part; GPUI
                    // content under it must not.
                    let visible = bounds.intersect(&clip);
                    (visible.size.width > px(0.) && visible.size.height > px(0.))
                        .then(|| window.insert_hitbox(visible, HitboxBehavior::BlockMouse))
                },
                |_, _, _, _| {},
            )
            .size_full(),
        )
        .into_any_element()
}

#[cfg(target_os = "macos")]
mod mac {
    use std::ffi::c_void;
    use std::ptr::NonNull;

    use gpui_kit::{Bounds, Pixels, Window};
    use objc2::MainThreadMarker;
    use objc2::rc::Retained;
    use objc2_app_kit::NSView;
    use objc2_foundation::{NSPoint, NSRect, NSSize};
    use raw_window_handle::{
        AppKitWindowHandle, HandleError, HasWindowHandle, RawWindowHandle, WindowHandle,
    };

    pub enum Content {
        Web(wry::WebView),
        /// A native view (the video player).
        View(Retained<NSView>),
    }

    pub struct Inner {
        pub content: Content,
        container: Retained<NSView>,
        parent: Retained<NSView>,
    }

    #[link(name = "AVKit", kind = "framework")]
    unsafe extern "C" {}
    #[link(name = "AVFoundation", kind = "framework")]
    unsafe extern "C" {}

    fn parts(window: &Window) -> Option<(MainThreadMarker, Retained<NSView>, Retained<NSView>)> {
        let mtm = MainThreadMarker::new()?;
        let RawWindowHandle::AppKit(handle) = HasWindowHandle::window_handle(window).ok()?.as_raw()
        else {
            return None;
        };
        // SAFETY: GPUI's content view, alive as long as its window.
        let parent: Retained<NSView> =
            unsafe { Retained::retain(handle.ns_view.as_ptr().cast::<NSView>())? };
        let container = NSView::initWithFrame(
            mtm.alloc::<NSView>(),
            NSRect::new(NSPoint::new(0., 0.), NSSize::new(0., 0.)),
        );
        container.setWantsLayer(true);
        container.setClipsToBounds(true);
        container.setHidden(true);
        parent.addSubview(&container);
        Some((mtm, parent, container))
    }

    /// The container, as the parent wry builds its web view in.
    struct Parent(NonNull<c_void>);

    impl HasWindowHandle for Parent {
        fn window_handle(&self) -> Result<WindowHandle<'_>, HandleError> {
            let raw = RawWindowHandle::AppKit(AppKitWindowHandle::new(self.0));
            // SAFETY: the container outlives the build that borrows it.
            Ok(unsafe { WindowHandle::borrow_raw(raw) })
        }
    }

    impl Inner {
        pub fn new(builder: wry::WebViewBuilder, window: &Window) -> Option<Self> {
            let (_, parent, container) = parts(window)?;
            let raw = Retained::as_ptr(&container) as *mut c_void;
            let webview = match builder.build_as_child(&Parent(NonNull::new(raw)?)) {
                Ok(w) => {
                    crate::shell::web_media::guard(&w);
                    w
                }
                Err(e) => {
                    log::warn!("inline web view: {e}");
                    container.removeFromSuperview();
                    return None;
                }
            };
            Some(Self {
                content: Content::Web(webview),
                container,
                parent,
            })
        }

        pub fn player(path: &std::path::Path, window: &Window) -> Option<Self> {
            use objc2::msg_send;
            use objc2::runtime::{AnyClass, AnyObject};
            use objc2_foundation::{NSString, NSURL};
            let (_, parent, container) = parts(window)?;
            let url = NSURL::fileURLWithPath(&NSString::from_str(&path.to_string_lossy()));
            let player_class = AnyClass::get(c"AVPlayer")?;
            let view_class = AnyClass::get(c"AVPlayerView")?;
            // SAFETY: AVKit's documented API, on the main thread.
            let view: Retained<NSView> = unsafe {
                let player: Retained<AnyObject> = msg_send![player_class, playerWithURL: &*url];
                let alloc: objc2::rc::Allocated<AnyObject> = msg_send![view_class, alloc];
                let view: Retained<AnyObject> = msg_send![
                    alloc,
                    initWithFrame: NSRect::new(NSPoint::new(0., 0.), NSSize::new(0., 0.))
                ];
                let _: () = msg_send![&*view, setPlayer: &*player];
                // AVPlayerViewControlsStyleInline.
                let _: () = msg_send![&*view, setControlsStyle: 1isize];
                let _: () = msg_send![&*view, setShowsFullScreenToggleButton: true];
                let _: () = msg_send![&*player, play];
                Retained::cast_unchecked::<NSView>(view)
            };
            container.addSubview(&view);
            Some(Self {
                content: Content::View(view),
                container,
                parent,
            })
        }

        pub fn enter_full_screen(&self) {
            use objc2::msg_send;
            use objc2::runtime::Sel;
            if let Content::View(view) = &self.content {
                let selector = Sel::register(c"enterFullScreen:");
                // SAFETY: only when AVPlayerView answers it.
                unsafe {
                    let responds: bool = msg_send![&**view, respondsToSelector: selector];
                    if responds {
                        let _: () = msg_send![&**view, enterFullScreen: std::ptr::null::<objc2::runtime::AnyObject>()];
                    }
                }
            }
        }

        pub fn pause(&self) {
            use objc2::msg_send;
            use objc2::runtime::AnyObject;
            if let Content::View(view) = &self.content {
                // SAFETY: AVPlayerView's player, if it has one.
                unsafe {
                    let player: Option<Retained<AnyObject>> = msg_send![&**view, player];
                    if let Some(player) = player {
                        let _: () = msg_send![&*player, pause];
                    }
                }
            }
        }

        pub fn set_hidden(&self, hidden: bool) {
            self.container.setHidden(hidden);
        }

        pub fn place(&self, document: Bounds<Pixels>, visible: Bounds<Pixels>) {
            let f = |p: Pixels| f64::from(f32::from(p));
            let parent_height = self.parent.frame().size.height;
            let y = if self.parent.isFlipped() {
                f(visible.origin.y)
            } else {
                parent_height - f(visible.origin.y) - f(visible.size.height)
            };
            self.container.setFrame(NSRect::new(
                NSPoint::new(f(visible.origin.x), y),
                NSSize::new(f(visible.size.width), f(visible.size.height)),
            ));
            let (x, y) = (
                f(document.origin.x - visible.origin.x),
                f(document.origin.y - visible.origin.y),
            );
            let (w, h) = (f(document.size.width), f(document.size.height));
            match &self.content {
                Content::Web(webview) => {
                    let rect = wry::Rect {
                        position: wry::dpi::LogicalPosition::new(x, y).into(),
                        size: wry::dpi::LogicalSize::new(w, h).into(),
                    };
                    let _ = webview.set_bounds(rect);
                }
                Content::View(view) => {
                    // The container is not flipped: y runs up from its bottom.
                    let container_height = f(visible.size.height);
                    view.setFrame(NSRect::new(
                        NSPoint::new(x, container_height - y - h),
                        NSSize::new(w, h),
                    ));
                }
            }
        }
    }

    impl Drop for Inner {
        fn drop(&mut self) {
            self.pause();
            self.container.removeFromSuperview();
        }
    }
}
