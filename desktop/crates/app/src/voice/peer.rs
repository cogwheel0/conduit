//! A Hermes GPT-Live call's WebRTC peer: a hidden web view (WKWebView,
//! through wry) whose bundled page (`assets/call/peer.html`) runs the
//! `RTCPeerConnection`. The microphone is WebKit's, with the system's echo
//! cancellation (`getUserMedia` with `echoCancellation`), so the voice it
//! plays is not heard back; a dev build's stand-in loops a WAV's samples
//! instead and never touches the microphone.
//!
//! The daemon's GPT-Live engine (the core's) signals through the call store,
//! which relays between the page (wry IPC one way, a script call the other)
//! and the call's socket (`WS /calls/{handle}`): the offer, the gateway's
//! answer, the voice's data channel, the microphone switch, the
//! connection's state and both sides' loudness.
//!
//! The page lives only during a call, in a window of its own: one point,
//! transparent, click-through, never key, out of the Window menu, Mission
//! Control and screen sharing. It stays ordered out (AppKit would count it
//! as a visible window, and the Dock icon would no longer bring the main
//! window back) except while the microphone opens, as WebKit opens it only
//! for a page it thinks is on screen.
//!
//! Microphone access is the app's (asked before the page opens) plus the
//! web views' media policy ([`crate::shell::web_media`]): this page alone,
//! its main frame at its own origin, may use the microphone; never the
//! camera, and no other web view anything.
//!
//! Hidden, the page must not be suspended: WebKit stops a hidden page's
//! process a few seconds in, so its page-visibility process suppression and
//! hidden-page timer throttling are off (private switches, set where this
//! WebKit has them; [`PeerStats::switches`] lists the ones it took).
//!
//! Its ICE candidate filtering is off: this is the app's own page, talking
//! only to the voice's server, and its host candidates go there as they do
//! from the phone's WebRTC. With filtering on (a page without the
//! microphone), WebKit hides them behind mDNS names it registers on the
//! local network, and macOS asks for Local Network access.
//!
//! The E2E pass's stand-in call uses only a TURN relay on 127.0.0.1
//! ([`Relay`]): the test never reaches the local network at all. A call with
//! the microphone never has a relay.

#[cfg(any(target_os = "macos", test))]
use base64::Engine as _;
use serde_json::Value;

/// The page, bundled.
pub const PAGE: &str = include_str!("../../assets/call/peer.html");
/// The page's own scheme: its origin, the only one granted the microphone.
pub const SCHEME: &str = "conduit-call";
#[cfg(target_os = "macos")]
const PAGE_URL: &str = "conduit-call://peer/";

/// What the page's microphone is.
#[derive(Clone, Debug, PartialEq)]
pub enum Source {
    /// WebKit's microphone, echo-cancelled.
    Microphone,
    /// A dev build's stand-in: 16-bit mono samples at `rate`, looped.
    Samples { rate: u32, pcm: Vec<i16> },
}

impl Source {
    /// A stand-in WAV's samples.
    pub fn from_wav(path: &std::path::Path) -> Result<Self, String> {
        let bytes = std::fs::read(path).map_err(|e| e.to_string())?;
        let (samples, rate) = super::pcm::decode_wav(&bytes)?;
        let pcm = samples
            .iter()
            .map(|s| (s.clamp(-1.0, 1.0) * f32::from(i16::MAX)) as i16)
            .collect();
        Ok(Self::Samples { rate, pcm })
    }
}

/// A TURN relay on loopback that a stand-in call uses alone (the E2E pass:
/// `tool/local_hermes_live`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Relay {
    /// `turn:127.0.0.1:<port>?transport=udp`.
    pub url: String,
    pub username: String,
    pub credential: String,
}

impl Relay {
    /// A relay is only ever on loopback.
    pub fn is_loopback(&self) -> bool {
        self.url.starts_with("turn:127.0.0.1:")
    }
}

/// How the page runs.
#[derive(Clone, Debug)]
pub struct Options {
    pub source: Source,
    /// Plays the voice aloud; false for a null speaker (the E2E pass).
    pub play: bool,
    /// Only this relay, for a stand-in call (never with the microphone).
    pub relay: Option<Relay>,
}

impl Options {
    /// The script that hands the page its options before it runs.
    #[cfg(any(target_os = "macos", test))]
    fn script(&self) -> String {
        let mut options = match &self.source {
            Source::Microphone => serde_json::json!({
                "source": "microphone",
                "play": self.play,
            }),
            Source::Samples { rate, pcm } => {
                let bytes: Vec<u8> = pcm.iter().flat_map(|s| s.to_le_bytes()).collect();
                serde_json::json!({
                    "source": "samples",
                    "rate": rate,
                    "pcm": base64::engine::general_purpose::STANDARD.encode(bytes),
                    "play": self.play,
                })
            }
        };
        if let (Source::Samples { .. }, Some(relay)) = (&self.source, &self.relay) {
            options["ice"] = serde_json::json!({
                "iceServers": [{
                    "urls": relay.url,
                    "username": relay.username,
                    "credential": relay.credential,
                }],
                "iceTransportPolicy": "relay",
            });
        }
        format!("window.conduitPeerOptions = {options};")
    }
}

/// What the call store and the E2E pass know of the page.
#[derive(Clone, Debug, Default)]
pub struct PeerStats {
    /// Pages opened, and closed.
    pub opened: usize,
    pub closed: usize,
    /// What the page said it can do when it loaded: `secure`, `visible`,
    /// `getUserMedia`, `webrtc`, `worklet`.
    pub ready: Option<Value>,
    /// The page's visibility as it made its offer.
    pub offer_visible: Option<String>,
    /// The connection's states, in order.
    pub states: Vec<String>,
    /// Whether the voice's data channel is open.
    pub channel_open: bool,
    /// Data-channel messages from the voice, and sent to it.
    pub received: usize,
    pub sent: Vec<String>,
    /// The microphone's switch, as the daemon set it last.
    pub microphone_on: bool,
    /// Loudness now and at its loudest since [`PeerStats::reset_peaks`].
    pub input: f64,
    pub output: f64,
    pub input_peak: f64,
    pub output_peak: f64,
    /// Audio bytes the connection sent and received.
    pub bytes_sent: u64,
    pub bytes_received: u64,
    /// What failed in the page.
    pub failures: Vec<String>,
    /// The private WebKit switches this WebKit took (see the module).
    pub switches: Vec<&'static str>,
}

/// What a page or daemon message is.
#[derive(Debug, PartialEq, Eq)]
pub enum Said {
    /// The page made its offer, or could not: it can be hidden again.
    OfferDone,
    /// The daemon asks for the offer: the page must be on screen while the
    /// microphone opens.
    OfferAsked,
    /// The daemon ends the peer.
    Stop,
    Other,
}

fn kind(value: &Value) -> &str {
    value.get("type").and_then(Value::as_str).unwrap_or("")
}

impl PeerStats {
    /// Notes what the page said.
    pub fn from_page(&mut self, value: &Value) -> Said {
        let number = |key: &str| value.get(key).and_then(Value::as_f64).unwrap_or(0.0);
        match kind(value) {
            "ready" => self.ready = Some(value.clone()),
            "offer" => {
                self.offer_visible = value
                    .get("visible")
                    .and_then(Value::as_str)
                    .map(str::to_string);
                return Said::OfferDone;
            }
            "failure" => {
                self.failures.push(format!(
                    "{}: {}",
                    value.get("reason").and_then(Value::as_str).unwrap_or(""),
                    value.get("message").and_then(Value::as_str).unwrap_or("")
                ));
                return Said::OfferDone;
            }
            "state" => {
                if let Some(state) = value.get("state").and_then(Value::as_str) {
                    self.states.push(state.to_string());
                }
            }
            "channel" => {
                self.channel_open = value.get("open").and_then(Value::as_bool) == Some(true);
            }
            "message" => self.received += 1,
            "levels" => {
                self.input = number("input");
                self.output = number("output");
                self.input_peak = self.input_peak.max(self.input);
                self.output_peak = self.output_peak.max(self.output);
            }
            "stats" => {
                self.bytes_sent = number("sent") as u64;
                self.bytes_received = number("received") as u64;
            }
            _ => {}
        }
        Said::Other
    }

    /// Notes what the daemon asked of the page.
    pub fn from_daemon(&mut self, value: &Value) -> Said {
        match kind(value) {
            "offer" => {
                self.microphone_on = true;
                Said::OfferAsked
            }
            "send" => {
                // The event's type, never what it says.
                let event = value
                    .get("text")
                    .and_then(Value::as_str)
                    .and_then(|t| serde_json::from_str::<Value>(t).ok())
                    .map(|e| kind(&e).to_string())
                    .unwrap_or_default();
                self.sent.push(event);
                Said::Other
            }
            "mic" => {
                self.microphone_on = value.get("enabled").and_then(Value::as_bool) == Some(true);
                Said::Other
            }
            "stop" => Said::Stop,
            _ => Said::Other,
        }
    }

    /// Starts measuring the loudest from now (the E2E pass, around mute).
    pub fn reset_peaks(&mut self) {
        self.input_peak = 0.0;
        self.output_peak = 0.0;
    }
}

/// The page, in its hidden window.
pub struct PeerHost {
    #[cfg(target_os = "macos")]
    inner: mac::Host,
}

impl PeerHost {
    /// Opens the page; `on_message` hears each of its messages (JSON), on
    /// the main thread.
    #[cfg(target_os = "macos")]
    pub fn open(options: &Options, on_message: impl Fn(String) + 'static) -> Result<Self, String> {
        let relayed = matches!(options.source, Source::Samples { .. }) && options.relay.is_some();
        Ok(Self {
            inner: mac::Host::open(options.script(), relayed, on_message)?,
        })
    }

    #[cfg(not(target_os = "macos"))]
    pub fn open(_: &Options, _: impl Fn(String) + 'static) -> Result<Self, String> {
        Err("a WebRTC peer needs macOS".into())
    }

    /// Hands the page a message from the daemon (JSON).
    pub fn post(&self, json: &str) {
        #[cfg(target_os = "macos")]
        self.inner.post(json);
        #[cfg(not(target_os = "macos"))]
        let _ = json;
    }

    /// The private WebKit switches the page took.
    pub fn switches(&self) -> Vec<&'static str> {
        #[cfg(target_os = "macos")]
        return self.inner.switches.clone();
        #[cfg(not(target_os = "macos"))]
        vec![]
    }

    /// The page's web view.
    pub fn webview(&self) -> Option<&wry::WebView> {
        #[cfg(target_os = "macos")]
        return Some(&self.inner.webview);
        #[cfg(not(target_os = "macos"))]
        None
    }

    /// Whether the page is on screen (still invisible).
    pub fn on_screen(&self) -> bool {
        #[cfg(target_os = "macos")]
        return self.inner.on_screen();
        #[cfg(not(target_os = "macos"))]
        false
    }

    /// Puts the page on screen (still invisible) or takes it off.
    pub fn set_on_screen(&self, on: bool) {
        #[cfg(target_os = "macos")]
        self.inner.set_on_screen(on);
        #[cfg(not(target_os = "macos"))]
        let _ = on;
    }
}

#[cfg(target_os = "macos")]
mod mac {
    use std::borrow::Cow;
    use std::ffi::c_void;
    use std::ptr::NonNull;

    use objc2::rc::Retained;
    use objc2::runtime::{AnyObject, Sel};
    use objc2::{MainThreadMarker, msg_send};
    use objc2_app_kit::{
        NSBackingStoreType, NSColor, NSWindow, NSWindowCollectionBehavior, NSWindowSharingType,
        NSWindowStyleMask,
    };
    use objc2_foundation::{NSPoint, NSRect, NSSize, NSString};
    use raw_window_handle::{
        AppKitWindowHandle, HandleError, HasWindowHandle, RawWindowHandle, WindowHandle,
    };
    use wry::WebViewExtMacOS as _;

    use super::{PAGE, PAGE_URL, SCHEME};

    /// NSActivityUserInitiated | NSActivityLatencyCritical: the call's
    /// messages pass through this process, which must not nap.
    const ACTIVITY: u64 = 0x00FF_FFFF | (1 << 20) | 0xFF_0000_0000;
    /// Above the Dock and other apps' windows, so nothing occludes it.
    const STATUS_LEVEL: isize = 25;

    /// The window's content view, as the parent wry builds in.
    struct Parent(NonNull<c_void>);

    impl HasWindowHandle for Parent {
        fn window_handle(&self) -> Result<WindowHandle<'_>, HandleError> {
            let raw = RawWindowHandle::AppKit(AppKitWindowHandle::new(self.0));
            // SAFETY: the view outlives the build that borrows it.
            Ok(unsafe { WindowHandle::borrow_raw(raw) })
        }
    }

    pub struct Host {
        window: Retained<NSWindow>,
        pub webview: wry::WebView,
        /// The microphone, for this page alone (`shell::web_media`).
        _call_page: crate::shell::web_media::CallPage,
        activity: Option<Retained<AnyObject>>,
        pub switches: Vec<&'static str>,
    }

    /// Sets a private boolean switch where `object` has it; whether it did.
    ///
    /// # Safety
    /// `selector` must take one BOOL.
    unsafe fn switch(object: &AnyObject, selector: &'static std::ffi::CStr, on: bool) -> bool {
        if !responds(object, selector) {
            return false;
        }
        use objc2::runtime::{Bool, MessageReceiver as _};
        let selector = Sel::register(selector);
        // SAFETY: the caller's; the selector answers and takes one BOOL.
        unsafe { object.send_message::<(Bool,), ()>(selector, (Bool::new(on),)) };
        true
    }

    fn responds(object: &AnyObject, selector: &std::ffi::CStr) -> bool {
        let selector = Sel::register(selector);
        // SAFETY: NSObject's respondsToSelector:.
        unsafe { msg_send![object, respondsToSelector: selector] }
    }

    impl Host {
        pub fn open(
            script: String,
            relayed: bool,
            on_message: impl Fn(String) + 'static,
        ) -> Result<Self, String> {
            let mtm = MainThreadMarker::new().ok_or("not on the main thread")?;
            let frame = NSRect::new(NSPoint::new(0., 0.), NSSize::new(1., 1.));
            // SAFETY: AppKit's designated initializer, on the main thread.
            let window = unsafe {
                NSWindow::initWithContentRect_styleMask_backing_defer(
                    mtm.alloc::<NSWindow>(),
                    frame,
                    NSWindowStyleMask::Borderless,
                    NSBackingStoreType::Buffered,
                    false,
                )
            };
            // SAFETY: plain AppKit setters on the main thread.
            unsafe {
                window.setReleasedWhenClosed(false);
            }
            window.setOpaque(false);
            window.setBackgroundColor(Some(&NSColor::clearColor()));
            window.setAlphaValue(0.0);
            window.setHasShadow(false);
            window.setIgnoresMouseEvents(true);
            window.setExcludedFromWindowsMenu(true);
            window.setSharingType(NSWindowSharingType::None);
            window.setLevel(STATUS_LEVEL);
            window.setCollectionBehavior(
                NSWindowCollectionBehavior::CanJoinAllSpaces
                    | NSWindowCollectionBehavior::Stationary
                    | NSWindowCollectionBehavior::IgnoresCycle
                    | NSWindowCollectionBehavior::Transient
                    | NSWindowCollectionBehavior::FullScreenAuxiliary,
            );
            // Nothing for VoiceOver: the page shows nothing.
            // SAFETY: NSAccessibility's setter on the main thread.
            unsafe {
                let _: () = msg_send![&*window, setAccessibilityElement: false];
            }
            let view = window.contentView().ok_or("no content view")?;
            let raw = Retained::as_ptr(&view) as *mut c_void;
            let builder = wry::WebViewBuilder::new()
                .with_incognito(true)
                .with_devtools(false)
                .with_autoplay(true)
                .with_bounds(wry::Rect {
                    position: wry::dpi::LogicalPosition::new(0., 0.).into(),
                    size: wry::dpi::LogicalSize::new(1., 1.).into(),
                })
                .with_custom_protocol(SCHEME.into(), |_, _| {
                    wry::http::Response::builder()
                        .header("Content-Type", "text/html; charset=utf-8")
                        .body(Cow::Borrowed(PAGE.as_bytes()))
                        .unwrap_or_default()
                })
                .with_initialization_script(script)
                .with_navigation_handler(|url: String| url.starts_with(PAGE_URL))
                .with_new_window_req_handler(|_, _| wry::NewWindowResponse::Deny)
                .with_ipc_handler(move |request| on_message(request.into_body()))
                .with_url(PAGE_URL);
            let parent = Parent(NonNull::new(raw).ok_or("no content view")?);
            let webview = builder.build_as_child(&parent).map_err(|e| e.to_string())?;
            // The app's media policy, under which this page alone may use
            // the microphone (its main frame, at its own origin).
            crate::shell::web_media::guard(&webview);
            let call_page = crate::shell::web_media::CallPage::register(&webview);
            let wk = webview.webview();
            let mut switches = vec![];
            // SAFETY: private BOOL switches WKWebView and its preferences
            // answer to.
            unsafe {
                let preferences: Retained<AnyObject> = {
                    let configuration: Retained<AnyObject> = msg_send![&*wk, configuration];
                    msg_send![&*configuration, preferences]
                };
                let mut set = |object: &AnyObject, name: &'static std::ffi::CStr, on: bool| {
                    if switch(object, name, on) {
                        switches.push(name.to_str().unwrap_or_default());
                    }
                };
                // WebKit opens the microphone only for a page it thinks is
                // seen: the window is on screen meanwhile, and these say
                // the rest.
                set(&preferences, c"_setGetUserMediaRequiresFocus:", false);
                set(&wk, c"_setWindowOcclusionDetectionEnabled:", false);
                // Hidden the rest of the call, yet never suspended.
                set(
                    &preferences,
                    c"_setPageVisibilityBasedProcessSuppressionEnabled:",
                    false,
                );
                set(
                    &preferences,
                    c"_setHiddenPageDOMTimerThrottlingEnabled:",
                    false,
                );
                // No mDNS name is ever registered for a candidate.
                set(&preferences, c"_setICECandidateFilteringEnabled:", false);
            }
            log::info!("call peer: WebKit switches {switches:?}");
            if relayed {
                log::info!("call peer: a stand-in call, on the loopback relay only");
            }
            // SAFETY: NSProcessInfo's activity API on the main thread; the
            // token is ended when the call's page closes.
            let activity: Option<Retained<AnyObject>> = unsafe {
                let info: Retained<AnyObject> =
                    msg_send![objc2::class!(NSProcessInfo), processInfo];
                let reason = NSString::from_str("Voice call");
                msg_send![&*info, beginActivityWithOptions: ACTIVITY, reason: &*reason]
            };
            Ok(Self {
                window,
                webview,
                _call_page: call_page,
                activity,
                switches,
            })
        }

        pub fn post(&self, json: &str) {
            let script = format!("window.conduitPeer && window.conduitPeer.receive({json});");
            if let Err(e) = self.webview.evaluate_script(&script) {
                log::warn!("call peer: {e}");
            }
        }

        pub fn on_screen(&self) -> bool {
            self.window.isVisible()
        }

        pub fn set_on_screen(&self, on: bool) {
            if on {
                self.window.setFrameOrigin(NSPoint::new(0., 0.));
                self.window.orderFrontRegardless();
            } else {
                self.window.orderOut(None);
            }
        }
    }

    impl Drop for Host {
        fn drop(&mut self) {
            self.post(r#"{"type":"stop"}"#);
            self.window.orderOut(None);
            self.window.close();
            if let Some(activity) = self.activity.take() {
                // SAFETY: the token beginActivity returned.
                unsafe {
                    let info: Retained<AnyObject> =
                        msg_send![objc2::class!(NSProcessInfo), processInfo];
                    let _: () = msg_send![&*info, endActivity: &*activity];
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn the_page_gets_its_stand_in_as_base64_samples() {
        let options = Options {
            source: Source::Samples {
                rate: 16_000,
                pcm: vec![1, -1],
            },
            play: false,
            relay: Some(Relay {
                url: "turn:127.0.0.1:19336?transport=udp".into(),
                username: "u".into(),
                credential: "c".into(),
            }),
        };
        let script = options.script();
        let json = script
            .strip_prefix("window.conduitPeerOptions = ")
            .and_then(|s| s.strip_suffix(';'))
            .unwrap();
        let value: Value = serde_json::from_str(json).unwrap();
        assert_eq!(value["source"], "samples");
        assert_eq!(value["rate"], 16_000);
        assert_eq!(value["pcm"], "AQD//w==");
        assert_eq!(value["play"], false);
        assert_eq!(value["ice"]["iceTransportPolicy"], "relay");
        assert_eq!(
            value["ice"]["iceServers"][0]["urls"],
            "turn:127.0.0.1:19336?transport=udp"
        );
        // The microphone never goes through a relay.
        let mic = Options {
            source: Source::Microphone,
            play: true,
            relay: options.relay.clone(),
        };
        assert!(mic.script().contains(r#""source":"microphone""#));
        assert!(!mic.script().contains("iceTransportPolicy"));
        assert!(options.relay.as_ref().is_some_and(Relay::is_loopback));
        assert!(
            !Relay {
                url: "turn:10.0.0.2:3478".into(),
                username: String::new(),
                credential: String::new(),
            }
            .is_loopback()
        );
    }

    #[test]
    fn the_stats_follow_the_page_and_the_daemon() {
        let mut stats = PeerStats::default();
        assert_eq!(
            stats.from_daemon(&json!({"type": "offer"})),
            Said::OfferAsked
        );
        assert!(stats.microphone_on);
        assert_eq!(
            stats.from_page(&json!({"type": "offer", "sdp": "v=0", "visible": "visible"})),
            Said::OfferDone
        );
        assert_eq!(stats.offer_visible.as_deref(), Some("visible"));
        stats.from_page(&json!({"type": "levels", "input": 0.3, "output": 0.1}));
        stats.from_page(&json!({"type": "levels", "input": 0.1, "output": 0.2}));
        assert_eq!((stats.input_peak, stats.output_peak), (0.3, 0.2));
        stats.reset_peaks();
        assert_eq!(stats.input_peak, 0.0);
        stats.from_daemon(&json!({"type": "send", "text": "{\"type\":\"session.close\"}"}));
        assert_eq!(stats.sent, vec!["session.close"]);
        stats.from_daemon(&json!({"type": "mic", "enabled": false}));
        assert!(!stats.microphone_on);
        assert_eq!(
            stats.from_page(
                &json!({"type": "failure", "reason": "microphone", "message": "NotAllowedError"})
            ),
            Said::OfferDone
        );
        assert_eq!(stats.failures, vec!["microphone: NotAllowedError"]);
        assert_eq!(stats.from_daemon(&json!({"type": "stop"})), Said::Stop);
    }

    #[test]
    fn the_page_is_bundled_with_its_bridge() {
        assert!(PAGE.contains("window.conduitPeer = {"));
        assert!(PAGE.contains("echoCancellation: true"));
        assert!(PAGE.contains("window.ipc.postMessage"));
    }
}
