//! What the app enforces itself, natively, for the web views that show an
//! answer's untrusted pages (HTML or SVG a tool returned, a remote page, an
//! MCP App): the page's scripts can't get around any of it.
//!
//! * **Only the top document talks to the app.** Messages come through the
//!   app's own script handler ([`HOST_HANDLER`]), which drops anything a
//!   child frame posts (`WKFrameInfo.isMainFrame`), instead of wry's `ipc`
//!   handler, which takes every frame's. For an embed the top document is
//!   the app's host page; for an MCP App it is the app's document.
//! * **No file picker, camera or microphone, and no new windows.** The web
//!   view's UI delegate is the app's, which refuses `<input type=file>`'s
//!   open panel and media capture (wry's opens the panel and grants
//!   capture), and makes no window for `window.open`.
//! * **A link opens only after a click or key press in that web view.** A
//!   page asking to open a URL is honoured only within
//!   [`ACTIVATION_WINDOW`] of a mouse-up or a Return, Enter or Space key
//!   press the app saw itself (an `NSEvent` monitor) whose target was that
//!   web view: the view the click hit (`hitTest:` when it happened) or the
//!   key's first responder is the web view or inside it ([`landed_in`]).
//!   Where the web view is now plays no part, so a click on another control
//!   in the same place never counts. Each one opens at most one link — a
//!   page can't open tabs on its own, whatever its scripts post.

use std::time::{Duration, Instant};

/// The app's script handler: `window.webkit.messageHandlers.conduitHost`.
pub const HOST_HANDLER: &str = "conduitHost";

/// How long after a click or key press in a web view a link it asks for
/// may still open.
pub const ACTIVATION_WINDOW: Duration = Duration::from_secs(1);

/// The last click or key press, and where it was; used up by the one link
/// it lets open. A click counts where its mouse-down went (a mouse-up goes
/// to the view the press began in, so a drag released over a web view is
/// not a click in it), and only once its mouse-up follows.
#[derive(Debug)]
pub struct Gate<T> {
    last: Option<(Instant, T)>,
    /// A mouse-down, and the view it hit, waiting for its mouse-up.
    pressed: Option<T>,
}

impl<T> Default for Gate<T> {
    fn default() -> Self {
        Self {
            last: None,
            pressed: None,
        }
    }
}

impl<T> Gate<T> {
    /// A key press at `at`, on `target`.
    pub fn record(&mut self, at: Instant, target: T) {
        self.pressed = None;
        self.last = Some((at, target));
    }

    /// A mouse-down on `target`.
    pub fn press(&mut self, target: T) {
        self.pressed = Some(target);
        self.last = None;
    }

    /// A mouse-up at `at`: the click its mouse-down began, if there was
    /// one. A mouse-up alone counts for nothing.
    pub fn release(&mut self, at: Instant) {
        if let Some(target) = self.pressed.take() {
            self.last = Some((at, target));
        }
    }

    /// Whether a link may open at `now` for the web view `inside` tells
    /// apart: only after a recent click or key press in it, and only once
    /// per click or key press.
    pub fn take(&mut self, now: Instant, inside: impl Fn(&T) -> bool) -> bool {
        let fresh = self.last.as_ref().is_some_and(|(at, target)| {
            now.checked_duration_since(*at)
                .is_some_and(|d| d <= ACTIVATION_WINDOW)
                && inside(target)
        });
        if fresh {
            self.last = None;
        }
        fresh
    }
}

/// Whether the view a click or key press went to, `hit`, is `webview` or
/// inside it, walking up through `parent` (a view's superview).
pub fn landed_in<V: PartialEq>(hit: &V, webview: &V, parent: impl Fn(&V) -> Option<V>) -> bool {
    if hit == webview {
        return true;
    }
    let mut up = parent(hit);
    while let Some(view) = up {
        if &view == webview {
            return true;
        }
        up = parent(&view);
    }
    false
}

/// The JavaScript that sends `payload` (a string expression) to the app.
/// Looked up when sent: the handler is added just after the web view is
/// made, which a script run at document start could come before.
pub fn post_script(payload: &str) -> String {
    format!("window.webkit.messageHandlers.{HOST_HANDLER}.postMessage({payload})")
}

#[cfg(target_os = "macos")]
pub use macos::{Guard, guard, take_activation};

#[cfg(target_os = "macos")]
mod macos {
    use std::cell::RefCell;
    use std::ptr::{NonNull, null_mut};
    use std::time::Instant;

    use block2::RcBlock;
    use objc2::rc::Retained;
    use objc2::runtime::{AnyObject, ProtocolObject};
    use objc2::{DefinedClass, MainThreadMarker, MainThreadOnly, Message, define_class, msg_send};
    use objc2_app_kit::{NSEvent, NSEventMask, NSEventType, NSResponder, NSView};
    use objc2_foundation::{NSArray, NSObject, NSObjectProtocol, NSString, NSURL};
    use objc2_web_kit::{
        WKFrameInfo, WKMediaCaptureType, WKOpenPanelParameters, WKPermissionDecision,
        WKScriptMessage, WKScriptMessageHandler, WKSecurityOrigin, WKUIDelegate,
        WKUserContentController, WKWebView,
    };

    use super::{Gate, HOST_HANDLER, landed_in};

    /// The view a click hit, or the responder a key press went to.
    enum Target {
        /// A mouse-up: the view under it when it happened.
        Click(Retained<NSView>),
        /// A key press with this responder first.
        Key(Retained<NSResponder>),
    }

    thread_local! {
        static GATE: RefCell<Gate<Target>> = RefCell::new(Gate::default());
        static MONITOR: RefCell<Option<Retained<AnyObject>>> = const { RefCell::new(None) };
    }

    /// Return, keypad Enter and Space: the keys that follow a focused link.
    const ACTIVATING_KEYS: [u16; 3] = [36, 76, 49];

    /// Watches the app's clicks and key presses, once.
    fn watch() {
        if MONITOR.with(|m| m.borrow().is_some()) {
            return;
        }
        let block = RcBlock::new(|event: NonNull<NSEvent>| -> *mut NSEvent {
            // SAFETY: AppKit hands the monitor a live event on the main
            // thread.
            let e = unsafe { event.as_ref() };
            let Some(mtm) = MainThreadMarker::new() else {
                return event.as_ptr();
            };
            match e.r#type() {
                // The view the press went to, as AppKit hit-tests it now
                // (the content view's superview uses window coordinates);
                // its mouse-up then makes it a click.
                NSEventType::LeftMouseDown => {
                    let hit = e
                        .window(mtm)
                        .and_then(|w| w.contentView())
                        .and_then(|content| content.hitTest(e.locationInWindow()));
                    GATE.with(|g| match hit {
                        Some(hit) => g.borrow_mut().press(Target::Click(hit)),
                        None => *g.borrow_mut() = Gate::default(),
                    });
                }
                NSEventType::LeftMouseUp => {
                    GATE.with(|g| g.borrow_mut().release(Instant::now()));
                }
                NSEventType::KeyDown if ACTIVATING_KEYS.contains(&e.keyCode()) => {
                    if let Some(target) = e.window(mtm).and_then(|w| w.firstResponder()) {
                        GATE.with(|g| g.borrow_mut().record(Instant::now(), Target::Key(target)));
                    }
                }
                _ => {}
            }
            event.as_ptr()
        });
        // SAFETY: the block returns the event it was given.
        let monitor = unsafe {
            NSEvent::addLocalMonitorForEventsMatchingMask_handler(
                NSEventMask::LeftMouseDown | NSEventMask::LeftMouseUp | NSEventMask::KeyDown,
                &block,
            )
        };
        MONITOR.with(|m| *m.borrow_mut() = monitor);
    }

    /// Whether `target` went to `webview` (or a view inside it).
    fn inside(webview: &WKWebView, target: &Target) -> bool {
        let view: &NSView = webview;
        let hit: Option<Retained<NSView>> = match target {
            Target::Click(hit) => Some(hit.clone()),
            Target::Key(responder) => responder.clone().downcast::<NSView>().ok(),
        };
        let Some(hit) = hit else { return false };
        // SAFETY: main-thread AppKit calls on live views.
        landed_in(&hit, &view.retain(), |v| unsafe { v.superview() })
    }

    /// Whether `webview` may open a link now (and uses up the click or key
    /// press that lets it).
    pub fn take_activation(webview: &wry::WebView) -> bool {
        use wry::WebViewExtMacOS as _;
        let webview = webview.webview();
        GATE.with(|g| {
            g.borrow_mut()
                .take(Instant::now(), |target| inside(&webview, target))
        })
    }

    struct HostIvars {
        on_message: Box<dyn Fn(String)>,
    }

    define_class!(
        // SAFETY: NSObject has no subclassing requirements and `Host` does
        // not implement Drop.
        #[unsafe(super(NSObject))]
        #[thread_kind = MainThreadOnly]
        #[ivars = HostIvars]
        struct Host;

        unsafe impl NSObjectProtocol for Host {}

        unsafe impl WKScriptMessageHandler for Host {
            #[unsafe(method(userContentController:didReceiveScriptMessage:))]
            fn did_receive(
                &self,
                _controller: &WKUserContentController,
                message: &WKScriptMessage,
            ) {
                // SAFETY: WebKit hands the handler a live message.
                let (main, body) = unsafe { (message.frameInfo().isMainFrame(), message.body()) };
                if !main {
                    log::warn!("a web view's child frame posted to the app: dropped");
                    return;
                }
                if let Ok(body) = body.downcast::<NSString>() {
                    (self.ivars().on_message)(body.to_string());
                }
            }
        }
    );

    impl Host {
        fn new(mtm: MainThreadMarker, on_message: Box<dyn Fn(String)>) -> Retained<Self> {
            let this = Self::alloc(mtm).set_ivars(HostIvars { on_message });
            // SAFETY: NSObject's designated initializer.
            unsafe { msg_send![super(this), init] }
        }
    }

    define_class!(
        // SAFETY: NSObject has no subclassing requirements and `Refusing`
        // does not implement Drop.
        #[unsafe(super(NSObject))]
        #[thread_kind = MainThreadOnly]
        struct Refusing;

        unsafe impl NSObjectProtocol for Refusing {}

        // No `webView:createWebViewWithConfiguration:…`: WebKit makes no
        // window for `window.open` or a `target=_blank` link.
        unsafe impl WKUIDelegate for Refusing {
            #[unsafe(method(webView:runOpenPanelWithParameters:initiatedByFrame:completionHandler:))]
            fn open_panel(
                &self,
                _webview: &WKWebView,
                _parameters: &WKOpenPanelParameters,
                _frame: &WKFrameInfo,
                completion_handler: &block2::DynBlock<dyn Fn(*mut NSArray<NSURL>)>,
            ) {
                log::info!("a web view asked for a file: refused");
                completion_handler.call((null_mut(),));
            }

            #[unsafe(method(webView:requestMediaCapturePermissionForOrigin:initiatedByFrame:type:decisionHandler:))]
            fn media_capture(
                &self,
                _webview: &WKWebView,
                _origin: &WKSecurityOrigin,
                _frame: &WKFrameInfo,
                _kind: WKMediaCaptureType,
                decision_handler: &block2::DynBlock<dyn Fn(WKPermissionDecision)>,
            ) {
                decision_handler.call((WKPermissionDecision::Deny,));
            }
        }
    );

    impl Refusing {
        fn new(mtm: MainThreadMarker) -> Retained<Self> {
            let this = Self::alloc(mtm).set_ivars(());
            // SAFETY: NSObject's designated initializer.
            unsafe { msg_send![super(this), init] }
        }
    }

    /// The app's handler and UI delegate for one web view: kept as long as
    /// the web view (WebKit holds the delegate weakly).
    pub struct Guard {
        controller: Retained<WKUserContentController>,
        _host: Retained<Host>,
        _ui: Retained<Refusing>,
    }

    impl Drop for Guard {
        fn drop(&mut self) {
            // SAFETY: removes the handler this guard added.
            unsafe {
                self.controller
                    .removeScriptMessageHandlerForName(&NSString::from_str(HOST_HANDLER));
            }
        }
    }

    /// Puts `webview` under the app's rules: only its top document's
    /// messages reach `on_message`, it gets no file picker, capture or new
    /// window, and the app watches clicks for [`take_activation`].
    pub fn guard(webview: &wry::WebView, on_message: impl Fn(String) + 'static) -> Option<Guard> {
        use wry::WebViewExtMacOS as _;
        let mtm = MainThreadMarker::new()?;
        watch();
        let view = webview.webview();
        let controller = webview.manager();
        let host = Host::new(mtm, Box::new(on_message));
        let ui = Refusing::new(mtm);
        // SAFETY: main-thread WebKit calls on a live web view; the guard
        // keeps both objects alive while it is.
        unsafe {
            controller.addScriptMessageHandler_name(
                ProtocolObject::from_ref(&*host),
                &NSString::from_str(HOST_HANDLER),
            );
            view.setUIDelegate(Some(ProtocolObject::from_ref(&*ui)));
        }
        Some(Guard {
            controller,
            _host: host,
            _ui: ui,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_link_opens_only_once_after_a_click_in_its_web_view() {
        let t0 = Instant::now();
        let mut gate = Gate::<&str>::default();
        // Nothing clicked: a page can't open a link on its own.
        assert!(!gate.take(t0, |_| true));
        // A click elsewhere (another web view, the transcript).
        gate.record(t0, "elsewhere");
        assert!(!gate.take(t0, |t| *t == "embed"));
        // A click in it: one link, not two.
        gate.record(t0, "embed");
        assert!(gate.take(t0 + Duration::from_millis(30), |t| *t == "embed"));
        assert!(!gate.take(t0 + Duration::from_millis(40), |t| *t == "embed"));
        // Too long after the click.
        gate.record(t0, "embed");
        assert!(
            !gate.take(t0 + ACTIVATION_WINDOW + Duration::from_millis(1), |t| {
                *t == "embed"
            })
        );
    }

    #[test]
    fn a_click_counts_only_if_it_went_to_the_web_view() {
        // window ─ content ─┬─ gpui (draws every control, the whole window)
        //                   └─ clip ─ webview ─ wk-content
        let parent = |v: &&str| match *v {
            "content" => Some("window"),
            "gpui" | "clip" => Some("content"),
            "webview" => Some("clip"),
            "wk-content" => Some("webview"),
            _ => None,
        };
        // A button drawn where the web view is (another embed's Open
        // Preview, under a replacement web view): the hit is GPUI's view.
        assert!(!landed_in(&"gpui", &"webview", parent));
        assert!(!landed_in(&"clip", &"webview", parent));
        // In the page: WebKit's own view inside the web view.
        assert!(landed_in(&"wk-content", &"webview", parent));
        assert!(landed_in(&"webview", &"webview", parent));
        // And the gate only lets a link through for such a click.
        let t0 = Instant::now();
        let mut gate = Gate::<&str>::default();
        gate.press("gpui");
        gate.release(t0);
        assert!(!gate.take(t0, |hit| landed_in(hit, &"webview", parent)));
        gate.press("wk-content");
        gate.release(t0);
        assert!(gate.take(t0, |hit| landed_in(hit, &"webview", parent)));
    }

    #[test]
    fn a_drag_released_over_the_web_view_opens_nothing() {
        fn parent(v: &&'static str) -> Option<&'static str> {
            match *v {
                "gpui" | "webview" => Some("content"),
                "wk-content" => Some("webview"),
                _ => None,
            }
        }
        let inside = |hit: &&'static str| landed_in(hit, &"webview", parent);
        let t0 = Instant::now();
        let mut gate = Gate::<&str>::default();
        // Pressed in the transcript, released over the embed: the press's
        // view is the click's.
        gate.press("gpui");
        gate.release(t0);
        assert!(!gate.take(t0, inside));
        // A mouse-up with no mouse-down the app saw counts for nothing.
        gate.release(t0);
        assert!(!gate.take(t0, inside));
        // Pressed in the page and released: one link.
        gate.press("wk-content");
        assert!(!gate.take(t0, inside), "a press alone is not a click");
        gate.release(t0);
        assert!(gate.take(t0, inside));
    }

    #[test]
    fn pages_post_through_the_apps_own_handler() {
        assert_eq!(
            post_script("p"),
            "window.webkit.messageHandlers.conduitHost.postMessage(p)"
        );
    }
}
