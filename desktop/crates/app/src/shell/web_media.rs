//! The microphone and the camera in the app's web views: denied, except the
//! microphone for a Hermes GPT-Live call's own page.
//!
//! wry's `WKUIDelegate` (`WryWebViewUIDelegate`, one class for every wry web
//! view) grants every media capture request from any origin. Once the app
//! has the microphone (dictation, calls) or the camera, any page in any web
//! view (an MCP App, a model-written embed, the Preview window, an SSO
//! page) could capture without asking. The phone denies capture in every
//! in-app web view (`onPermissionRequest` → DENY, and flutter_inappwebview's
//! default is DENY), so the Mac does too.
//!
//! [`guard`] runs after every web view is built: it puts the app's decision
//! ([`decision`]) on wry's delegate class (once, for every wry web view,
//! built before or after), and if that class ever cannot be found, gives
//! that web view a delegate of the app's own that only denies. A call's page
//! registers itself ([`CallPage`]); only its main frame, at its own origin
//! (`conduit-call://`), may use the microphone, never the camera.

/// `WKPermissionDecision`.
pub const GRANT: isize = 1;
pub const DENY: isize = 2;
/// `WKMediaCaptureType`.
pub const CAMERA: isize = 0;
pub const MICROPHONE: isize = 1;
pub const CAMERA_AND_MICROPHONE: isize = 2;

/// Whether a media capture request is granted: only a call page's main
/// frame, at the call page's own origin, for the microphone alone.
pub fn decision(call_page: bool, scheme: Option<&str>, main_frame: bool, kind: isize) -> isize {
    let call_microphone =
        call_page && main_frame && kind == MICROPHONE && scheme == Some(crate::voice::peer::SCHEME);
    if call_microphone { GRANT } else { DENY }
}

/// Puts the app's media decision on `webview` (see the module). Call it
/// right after building any web view.
pub fn guard(webview: &wry::WebView) {
    #[cfg(target_os = "macos")]
    mac::guard(webview);
    #[cfg(not(target_os = "macos"))]
    let _ = webview;
}

/// A call page, allowed the microphone while this lives.
pub struct CallPage {
    #[cfg(target_os = "macos")]
    key: usize,
}

impl CallPage {
    pub fn register(webview: &wry::WebView) -> Self {
        #[cfg(target_os = "macos")]
        {
            let key = mac::key(webview);
            mac::CALL_PAGES.with(|pages| pages.borrow_mut().push(key));
            Self { key }
        }
        #[cfg(not(target_os = "macos"))]
        {
            let _ = webview;
            Self {}
        }
    }
}

impl Drop for CallPage {
    fn drop(&mut self) {
        #[cfg(target_os = "macos")]
        mac::CALL_PAGES.with(|pages| pages.borrow_mut().retain(|k| *k != self.key));
    }
}

#[cfg(target_os = "macos")]
pub(crate) mod mac {
    use std::cell::{Cell, RefCell};

    #[cfg(feature = "harness")]
    use objc2::DefinedClass as _;
    use objc2::rc::Retained;
    use objc2::runtime::{AnyClass, AnyObject, NSObject, NSObjectProtocol, Sel};
    use objc2::{AnyThread as _, define_class, msg_send, sel};
    use objc2_foundation::NSString;
    use wry::WebViewExtMacOS as _;

    use super::{DENY, decision};

    thread_local! {
        /// The call pages' WKWebViews, by address (main thread only).
        pub(super) static CALL_PAGES: RefCell<Vec<usize>> = const { RefCell::new(Vec::new()) };
        /// Whether wry's delegate class now carries the app's decision.
        static INSTALLED: Cell<bool> = const { Cell::new(false) };
        /// Delegates of the app's own, for web views wry's class could not
        /// be fixed for (WebKit holds a UI delegate weakly).
        static FALLBACKS: RefCell<Vec<Retained<MediaPolicy>>> = const { RefCell::new(Vec::new()) };
    }

    const WRY_DELEGATE: &std::ffi::CStr = c"WryWebViewUIDelegate";
    /// `-webView:requestMediaCapturePermissionForOrigin:initiatedByFrame:type:decisionHandler:`:
    /// void, self, _cmd, WKWebView, WKSecurityOrigin, WKFrameInfo,
    /// WKMediaCaptureType (NSInteger), block.
    const TYPES: &std::ffi::CStr = c"v@:@@@q@?";

    fn selector() -> Sel {
        sel!(webView:requestMediaCapturePermissionForOrigin:initiatedByFrame:type:decisionHandler:)
    }

    pub fn key(webview: &wry::WebView) -> usize {
        Retained::as_ptr(&webview.webview()) as usize
    }

    /// The app's decision for a request from `web_view`.
    ///
    /// # Safety
    /// `origin` and `frame` are a WKSecurityOrigin and a WKFrameInfo, or
    /// objects answering `protocol` and `isMainFrame` as they do.
    unsafe fn decide(
        web_view: *const AnyObject,
        origin: &AnyObject,
        frame: &AnyObject,
        kind: isize,
    ) -> isize {
        let call_page = CALL_PAGES.with(|pages| pages.borrow().contains(&(web_view as usize)));
        // SAFETY: the caller's.
        let (scheme, main): (Option<Retained<NSString>>, bool) =
            unsafe { (msg_send![origin, protocol], msg_send![frame, isMainFrame]) };
        let scheme = scheme.map(|s| s.to_string());
        let answer = decision(call_page, scheme.as_deref(), main, kind);
        if answer == DENY {
            log::warn!(
                "web view: refused media capture (type {kind}) for {} (call page: {call_page})",
                scheme.as_deref().unwrap_or("?")
            );
        }
        answer
    }

    /// The method put on wry's delegate class.
    unsafe extern "C-unwind" fn replaced(
        _this: *mut AnyObject,
        _cmd: Sel,
        web_view: *mut AnyObject,
        origin: *mut AnyObject,
        frame: *mut AnyObject,
        kind: isize,
        handler: *mut block2::Block<dyn Fn(isize)>,
    ) {
        // SAFETY: WebKit's arguments, as the selector's signature has them.
        unsafe {
            let answer = match (origin.as_ref(), frame.as_ref()) {
                (Some(origin), Some(frame)) => decide(web_view, origin, frame, kind),
                _ => DENY,
            };
            if let Some(handler) = handler.as_ref() {
                handler.call((answer,));
            }
        }
    }

    define_class!(
        // SAFETY: NSObject has no subclassing requirements and the delegate
        // does not implement Drop.
        #[unsafe(super(NSObject))]
        #[name = "ConduitWebMediaPolicy"]
        pub struct MediaPolicy;

        unsafe impl NSObjectProtocol for MediaPolicy {}

        impl MediaPolicy {
            #[unsafe(method(webView:requestMediaCapturePermissionForOrigin:initiatedByFrame:type:decisionHandler:))]
            fn request_media(
                &self,
                web_view: &AnyObject,
                origin: &AnyObject,
                frame: &AnyObject,
                kind: isize,
                handler: &block2::Block<dyn Fn(isize)>,
            ) {
                // SAFETY: WebKit's arguments.
                let answer = unsafe { decide(web_view, origin, frame, kind) };
                handler.call((answer,));
            }
        }
    );

    impl MediaPolicy {
        fn new() -> Retained<Self> {
            let this = Self::alloc().set_ivars(());
            // SAFETY: NSObject's designated initializer.
            unsafe { msg_send![super(this), init] }
        }
    }

    /// Puts the decision on wry's delegate class, once; whether it is there.
    fn install() -> bool {
        if INSTALLED.get() {
            return true;
        }
        let Some(class) = AnyClass::get(WRY_DELEGATE) else {
            return false;
        };
        if class.instance_method(selector()).is_none() {
            return false;
        }
        // SAFETY: `replaced` has the selector's signature (TYPES); the
        // class is wry's, registered, and this runs on the main thread.
        unsafe {
            let imp: objc2::runtime::Imp = std::mem::transmute(
                replaced
                    as unsafe extern "C-unwind" fn(
                        *mut AnyObject,
                        Sel,
                        *mut AnyObject,
                        *mut AnyObject,
                        *mut AnyObject,
                        isize,
                        *mut block2::Block<dyn Fn(isize)>,
                    ),
            );
            let class = class as *const AnyClass as *mut AnyClass;
            objc2::ffi::class_replaceMethod(class, selector(), imp, TYPES.as_ptr());
        }
        INSTALLED.set(true);
        log::info!("web views: media capture denied except a call page's microphone");
        true
    }

    pub fn guard(webview: &wry::WebView) {
        let wk = webview.webview();
        // SAFETY: WKWebView's UI delegate, read on the main thread.
        let delegate: Option<Retained<AnyObject>> = unsafe { msg_send![&*wk, UIDelegate] };
        let wry_delegate = delegate
            .as_ref()
            .is_some_and(|d| d.class().name().to_bytes() == WRY_DELEGATE.to_bytes());
        if wry_delegate && install() {
            return;
        }
        if delegate
            .as_ref()
            .is_some_and(|d| d.class().name().to_bytes() == b"ConduitWebMediaPolicy")
        {
            return;
        }
        // Not wry's delegate, or wry's could not be fixed: one that denies.
        log::warn!("web view: the app's own media policy in place of its UI delegate");
        let policy = MediaPolicy::new();
        // SAFETY: WebKit holds it weakly; FALLBACKS keeps it.
        unsafe {
            let _: () = msg_send![&*wk, setUIDelegate: &*policy];
        }
        FALLBACKS.with(|f| f.borrow_mut().push(policy));
    }

    #[cfg(feature = "harness")]
    /// What `webview`'s UI delegate answers a media capture request with:
    /// the fixture's check (it never opens a microphone or a camera).
    pub fn ask(
        webview: &wry::WebView,
        scheme: &str,
        main_frame: bool,
        kind: isize,
    ) -> Option<isize> {
        use std::rc::Rc;
        let wk = webview.webview();
        // SAFETY: WKWebView's UI delegate, on the main thread.
        let delegate: Option<Retained<AnyObject>> = unsafe { msg_send![&*wk, UIDelegate] };
        let delegate = delegate?;
        let origin = FakeOrigin::new(scheme);
        let frame = FakeFrame::new(main_frame);
        let answer = Rc::new(Cell::new(None));
        let handler = {
            let answer = answer.clone();
            block2::RcBlock::new(move |decision: isize| answer.set(Some(decision)))
        };
        // SAFETY: the delegate's method, with stand-ins answering what it
        // reads of an origin and a frame.
        unsafe {
            let _: () = msg_send![
                &*delegate,
                webView: &*wk,
                requestMediaCapturePermissionForOrigin: &*origin,
                initiatedByFrame: &*frame,
                type: kind,
                decisionHandler: &*handler
            ];
        }
        answer.get()
    }

    #[cfg(feature = "harness")]
    struct FakeOriginIvars {
        scheme: Retained<NSString>,
    }

    #[cfg(feature = "harness")]
    define_class!(
        // SAFETY: NSObject has no subclassing requirements.
        #[unsafe(super(NSObject))]
        #[ivars = FakeOriginIvars]
        #[name = "ConduitFakeSecurityOrigin"]
        struct FakeOrigin;

        unsafe impl NSObjectProtocol for FakeOrigin {}

        impl FakeOrigin {
            #[unsafe(method_id(protocol))]
            fn protocol(&self) -> Retained<NSString> {
                self.ivars().scheme.clone()
            }

            #[unsafe(method_id(host))]
            fn host(&self) -> Retained<NSString> {
                NSString::from_str("fixture")
            }
        }
    );

    #[cfg(feature = "harness")]
    impl FakeOrigin {
        fn new(scheme: &str) -> Retained<Self> {
            let this = Self::alloc().set_ivars(FakeOriginIvars {
                scheme: NSString::from_str(scheme),
            });
            // SAFETY: NSObject's designated initializer.
            unsafe { msg_send![super(this), init] }
        }
    }

    #[cfg(feature = "harness")]
    struct FakeFrameIvars {
        main: bool,
    }

    #[cfg(feature = "harness")]
    define_class!(
        // SAFETY: NSObject has no subclassing requirements.
        #[unsafe(super(NSObject))]
        #[ivars = FakeFrameIvars]
        #[name = "ConduitFakeFrameInfo"]
        struct FakeFrame;

        unsafe impl NSObjectProtocol for FakeFrame {}

        impl FakeFrame {
            #[unsafe(method(isMainFrame))]
            fn is_main_frame(&self) -> bool {
                self.ivars().main
            }
        }
    );

    #[cfg(feature = "harness")]
    impl FakeFrame {
        fn new(main: bool) -> Retained<Self> {
            let this = Self::alloc().set_ivars(FakeFrameIvars { main });
            // SAFETY: NSObject's designated initializer.
            unsafe { msg_send![super(this), init] }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_a_call_pages_microphone_at_its_own_origin_is_granted() {
        let scheme = Some(crate::voice::peer::SCHEME);
        assert_eq!(decision(true, scheme, true, MICROPHONE), GRANT);
        // Never the camera, nor both.
        assert_eq!(decision(true, scheme, true, CAMERA), DENY);
        assert_eq!(decision(true, scheme, true, CAMERA_AND_MICROPHONE), DENY);
        // Never a frame inside it, nor another origin in it.
        assert_eq!(decision(true, scheme, false, MICROPHONE), DENY);
        assert_eq!(decision(true, Some("https"), true, MICROPHONE), DENY);
        assert_eq!(decision(true, None, true, MICROPHONE), DENY);
        // Never any other web view, whatever origin it claims.
        assert_eq!(decision(false, scheme, true, MICROPHONE), DENY);
        assert_eq!(decision(false, Some("https"), true, MICROPHONE), DENY);
        assert_eq!(decision(false, Some("about"), true, CAMERA), DENY);
    }

    /// [text] without its comments, so a comment naming the guard (a TODO)
    /// never counts as one: line comments and block comments outside
    /// string literals become blanks.
    fn code_only(text: &str) -> String {
        let mut out = String::with_capacity(text.len());
        let mut chars = text.chars().peekable();
        let mut in_string = false;
        while let Some(c) = chars.next() {
            if in_string {
                out.push(c);
                match c {
                    '\\' => {
                        if let Some(next) = chars.next() {
                            out.push(next);
                        }
                    }
                    '"' => in_string = false,
                    _ => {}
                }
                continue;
            }
            match (c, chars.peek()) {
                ('/', Some('/')) => {
                    for skipped in chars.by_ref() {
                        if skipped == '\n' {
                            out.push('\n');
                            break;
                        }
                    }
                }
                ('/', Some('*')) => {
                    chars.next();
                    let mut last = ' ';
                    for skipped in chars.by_ref() {
                        if last == '*' && skipped == '/' {
                            break;
                        }
                        last = skipped;
                    }
                    out.push(' ');
                }
                ('"', _) => {
                    in_string = true;
                    out.push(c);
                }
                // A char literal: `'"'` and `'\\"'` open no string.
                ('\'', Some('"' | '\\')) => {
                    out.push(c);
                    if let Some(next) = chars.next() {
                        out.push(next);
                        if next == '\\'
                            && let Some(escaped) = chars.next()
                        {
                            out.push(escaped);
                        }
                    }
                }
                _ => out.push(c),
            }
        }
        out
    }

    #[test]
    fn comments_never_count_as_code() {
        let text = "a('\"'); // web_media::guard(x)\n/* web_media::guard( */ b(\"//\");\n";
        let code = code_only(text);
        assert!(!code.contains("web_media::guard("), "{code}");
        assert!(code.contains("b(\"//\")"), "{code}");
    }

    /// Every place the app builds a web view puts the media policy on it.
    #[test]
    fn every_web_view_the_app_builds_is_guarded() {
        let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("src");
        let mut unguarded = vec![];
        let mut stack = vec![root];
        while let Some(dir) = stack.pop() {
            for entry in std::fs::read_dir(&dir).unwrap().flatten() {
                let path = entry.path();
                if path.is_dir() {
                    stack.push(path);
                    continue;
                }
                if path.extension().is_none_or(|e| e != "rs")
                    || path.ends_with("web_media.rs")
                    // Builds one without the guard on purpose, to check
                    // that wry's own delegate denies too.
                    || path.ends_with("web_media_fixture.rs")
                {
                    continue;
                }
                let text = code_only(&std::fs::read_to_string(&path).unwrap());
                let builds = text.matches("build_as_child(").count()
                    + text.matches("WebView::build(").count();
                let guards = text.matches("web_media::guard(").count();
                if builds > guards {
                    unguarded.push(format!(
                        "{} ({builds} builds, {guards} guards)",
                        path.display()
                    ));
                }
            }
        }
        assert!(
            unguarded.is_empty(),
            "web views built without the media policy: {unguarded:#?}"
        );
    }
}
