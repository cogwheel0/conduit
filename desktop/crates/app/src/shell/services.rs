//! "Ask Conduit" and "New Conduit Chat With Selection" in the Services
//! menu: every app's application menu › Services, and the menu a right
//! click on selected text opens (the Mac counterpart of Android's Process
//! Text "Ask Conduit").
//!
//! Info.plist's `NSServices` names the two messages ([`ASK`],
//! [`NEW_CHAT`]); macOS calls them on the [`Provider`] set as the
//! application's services provider, with the selected text on a
//! pasteboard, launching the app first if needed. The text goes through a
//! channel to [`crate::desktop`], which opens Quick Ask with it quoted (or
//! a new chat, when Quick Ask is off or not ready), or a new chat with it
//! as is.
//!
//! The menu titles are localized by `ServicesMenu.strings` in the bundle
//! (packaging/macos/share/build.sh writes them from the ARB catalogs).

/// What a Services item asks for.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ServiceRequest {
    /// Ask Conduit: a question about the text.
    Ask(String),
    /// New Conduit Chat With Selection: the text as the message.
    NewChat(String),
}

/// The `NSMessage` of "Ask Conduit" in Info.plist's `NSServices`.
pub const ASK: &str = "askConduit";
/// The `NSMessage` of "New Conduit Chat With Selection".
pub const NEW_CHAT: &str = "newChatWithSelection";

/// The longest selection taken, in characters.
pub const MAX_TEXT: usize = super::share_inbox::MAX_TEXT;

/// The selection, cut to [`MAX_TEXT`]; `None` when it is blank.
pub fn selection(text: &str) -> Option<String> {
    let text = text.replace("\r\n", "\n").replace('\r', "\n");
    (!text.trim().is_empty()).then(|| text.chars().take(MAX_TEXT).collect())
}

/// `text` as a Markdown quote with an empty line after it, so the question
/// is typed below what it is about. Blank lines at either end are dropped;
/// a blank line inside stays in the quote.
pub fn quote(text: &str) -> String {
    let lines: Vec<&str> = text.lines().map(str::trim_end).collect();
    let first = lines.iter().position(|l| !l.is_empty());
    let last = lines.iter().rposition(|l| !l.is_empty());
    let (Some(first), Some(last)) = (first, last) else {
        return String::new();
    };
    let mut out = String::new();
    for line in &lines[first..=last] {
        if line.is_empty() {
            out.push_str(">\n");
        } else {
            out.push_str("> ");
            out.push_str(line);
            out.push('\n');
        }
    }
    out.push('\n');
    out
}

#[cfg(target_os = "macos")]
pub use macos::{Provider, install, perform};

#[cfg(target_os = "macos")]
mod macos {
    use futures::channel::mpsc;
    use objc2::rc::Retained;
    use objc2::runtime::{NSObject, NSObjectProtocol};
    use objc2::{AnyThread as _, DefinedClass, MainThreadMarker, define_class, msg_send};
    use objc2_app_kit::{
        NSApplication, NSPasteboard, NSPasteboardTypeString, NSUpdateDynamicServices,
    };
    use objc2_foundation::NSString;

    use super::{ServiceRequest, selection};

    pub struct ProviderIvars {
        requests: mpsc::UnboundedSender<ServiceRequest>,
    }

    define_class!(
        // SAFETY: NSObject has no subclassing requirements and `Provider`
        // does not implement Drop. AppKit calls the service methods on the
        // main thread; the channel is thread-safe anyway.
        #[unsafe(super(NSObject))]
        #[ivars = ProviderIvars]
        pub struct Provider;

        unsafe impl NSObjectProtocol for Provider {}

        impl Provider {
            // The NSServices messages: `<NSMessage>:userData:error:`.
            #[unsafe(method(askConduit:userData:error:))]
            fn ask_conduit(
                &self,
                pboard: &NSPasteboard,
                _user_data: Option<&NSString>,
                _error: *mut *mut NSString,
            ) {
                self.forward(pboard, ServiceRequest::Ask);
            }

            #[unsafe(method(newChatWithSelection:userData:error:))]
            fn new_chat_with_selection(
                &self,
                pboard: &NSPasteboard,
                _user_data: Option<&NSString>,
                _error: *mut *mut NSString,
            ) {
                self.forward(pboard, ServiceRequest::NewChat);
            }
        }
    );

    impl Provider {
        fn new(requests: mpsc::UnboundedSender<ServiceRequest>) -> Retained<Self> {
            let this = Self::alloc().set_ivars(ProviderIvars { requests });
            // SAFETY: NSObject's designated initializer.
            unsafe { msg_send![super(this), init] }
        }

        fn forward(&self, pboard: &NSPasteboard, make: fn(String) -> ServiceRequest) {
            // SAFETY: an AppKit constant.
            let text = pboard.stringForType(unsafe { NSPasteboardTypeString });
            match text
                .as_deref()
                .map(NSString::to_string)
                .as_deref()
                .and_then(selection)
            {
                Some(text) => {
                    log::info!(
                        "services: a selection of {} characters",
                        text.chars().count()
                    );
                    let _ = self.ivars().requests.unbounded_send(make(text));
                }
                None => log::info!("services: no text on the pasteboard"),
            }
        }
    }

    /// Makes the provider and sets it as the application's; its requests
    /// arrive on the returned receiver. Called while the app finishes
    /// launching, so a launch made for a service finds it. `None` off the
    /// main thread.
    pub fn install() -> Option<(Retained<Provider>, mpsc::UnboundedReceiver<ServiceRequest>)> {
        let mtm = MainThreadMarker::new()?;
        let (tx, rx) = mpsc::unbounded();
        let provider = Provider::new(tx);
        let app = NSApplication::sharedApplication(mtm);
        // SAFETY: the provider responds to the messages Info.plist names
        // and lives as long as the app (the caller keeps it).
        unsafe { app.setServicesProvider(Some(&provider)) };
        let bundle = objc2_foundation::NSBundle::mainBundle();
        if bundle.bundlePath().to_string().ends_with(".app") {
            // Has the system read this bundle's NSServices (a first launch,
            // an update)?
            NSUpdateDynamicServices();
        }
        Some((provider, rx))
    }

    /// Calls the service `message` ([`super::ASK`] or
    /// [`super::NEW_CHAT`]) on `provider` with `text` on a pasteboard of
    /// its own, as the Services menu does (the E2E pass's entry point).
    pub fn perform(provider: &Provider, message: &str, text: &str) {
        let pboard = NSPasteboard::pasteboardWithUniqueName();
        pboard.clearContents();
        // SAFETY: an AppKit constant.
        pboard.setString_forType(&NSString::from_str(text), unsafe { NSPasteboardTypeString });
        let mut error: *mut NSString = std::ptr::null_mut();
        let user_data: Option<&NSString> = None;
        // SAFETY: both methods take (NSPasteboard*, NSString*, NSString**)
        // and return void; `provider` defines them.
        unsafe {
            if message == super::ASK {
                let _: () = msg_send![
                    provider,
                    askConduit: &*pboard,
                    userData: user_data,
                    error: &mut error
                ];
            } else {
                let _: () = msg_send![
                    provider,
                    newChatWithSelection: &*pboard,
                    userData: user_data,
                    error: &mut error
                ];
            }
        }
        // The unique pasteboard goes with this call (objc2 has no binding).
        // SAFETY: `releaseGlobally` takes nothing and returns void.
        unsafe {
            let _: () = msg_send![&*pboard, releaseGlobally];
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn quotes_the_selection_with_room_for_the_question() {
        assert_eq!(quote("One line"), "> One line\n\n");
        assert_eq!(
            quote("\n\nFirst  \n\nThird\n\n"),
            "> First\n>\n> Third\n\n",
            "blank lines at the ends go, inner ones stay"
        );
        assert_eq!(quote(" \n "), "");
        assert_eq!(quote("> already quoted"), "> > already quoted\n\n");
    }

    #[test]
    fn takes_text_up_to_the_limit() {
        assert_eq!(selection("  \n\t "), None);
        assert_eq!(selection("a\r\nb\rc").as_deref(), Some("a\nb\nc"));
        let long = "x".repeat(MAX_TEXT + 3);
        assert_eq!(selection(&long).unwrap().chars().count(), MAX_TEXT);
    }
}
