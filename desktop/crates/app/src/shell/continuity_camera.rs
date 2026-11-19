//! Continuity Camera in the composer's + menu: Take Photo and Scan
//! Documents with a nearby iPhone or iPad (the phone's Camera, on the Mac).
//!
//! AppKit does it all, given two things:
//!
//! * **A context menu.** The + menu opens through
//!   `NSMenu.popUpContextMenu(_:with:for:)`, AppKit's documented path for
//!   a menu that is not in the menu bar: as it opens, AppKit adds each
//!   nearby device's items (Take Photo, Scan Documents, Add Sketch), in the
//!   system's words, when a requestor in the view's responder chain takes
//!   what they bring, and nothing when no device is near. GPUI Kit's
//!   `NativeMenu` builds its NSMenu out of reach, so the + menu's NSMenu is
//!   built here ([`popup`]), from the same entries, with the composer's
//!   actions, and opened at the + button's anchor by a synthesized event.
//! * **A requestor** in the main window's responder chain ([`install`]): it
//!   answers `validRequestorForSendType:returnType:` for pictures and PDFs
//!   (the types are registered with `registerServicesMenuSendTypes`), and
//!   AppKit hands the photo or scan to its `readSelectionFromPasteboard:`.
//!   What it reads goes through a channel to the app, which attaches it to
//!   the main window's composer ([`crate::desktop`]).
//!
//! The items work only with a device nearby (checked on a Mac with an
//! iPhone before release); `--e2e mac-extras-2` checks the menu and the
//! chain, and hands the requestor a synthetic picture through the same
//! callback ([`deliver`]).

/// The folder (under the temporary directory) a device's photos and scans
/// are saved in for the composer, one folder each; cleared with Send
/// Image's copies ([`crate::intents::prune_images`]).
pub const IMPORT_FOLDER: &str = "conduit-continuity-camera";

/// What came back from a device: one picture or one scanned PDF.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Imported {
    pub bytes: Vec<u8>,
    /// The file extension its type calls for (`jpeg`, `png`, `heic`,
    /// `tiff`, `pdf`).
    pub extension: &'static str,
    /// The ticket of the + menu session it was asked for in.
    pub target: ImportTarget,
}

impl Imported {
    /// The attachment's name: a photo or a scan, as the system's items call
    /// them (the composer turns a HEIC or TIFF photo into a JPEG).
    pub fn file_name(&self) -> String {
        let stem = if self.extension == "pdf" {
            "Scan"
        } else {
            "Photo"
        };
        format!("{stem}.{}", self.extension)
    }
}

/// The ticket a + menu session takes for what devices send through it: the
/// account scope (its `scope_key`; `None`, no account, is a scope too), the
/// composer's draft and which composition of it (its `draft_round`). Each
/// session's requestor holds its own, and every photo it hands over carries
/// it ([`Imported::target`]); a photo is attached only while all three are
/// still the composer's, and dropped otherwise (another account, another
/// chat, or the composition replaced, as Send Text replaces it).
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct ImportTarget {
    pub scope: Option<String>,
    pub draft: Option<crate::stores::composer::DraftKey>,
    pub round: u64,
}

/// The pasteboard types the requestor takes, in the order it prefers them,
/// with the extension each is saved as. A scan comes as a PDF; a photo as
/// a JPEG or HEIC (or PNG, TIFF).
pub const RETURN_TYPES: &[(&str, &str)] = &[
    ("public.jpeg", "jpeg"),
    ("public.heic", "heic"),
    ("public.png", "png"),
    ("com.adobe.pdf", "pdf"),
    ("public.tiff", "tiff"),
];

/// Whether the requestor takes `return_type` with nothing sent: Continuity
/// Camera asks for pictures and documents and sends nothing.
pub fn takes(send_type: Option<&str>, return_type: Option<&str>) -> bool {
    send_type.is_none_or(str::is_empty)
        && return_type.is_some_and(|t| RETURN_TYPES.iter().any(|(ty, _)| *ty == t))
}

/// One entry of the + menu as [`popup`] builds it.
#[derive(Clone, Debug, PartialEq)]
pub enum Entry {
    /// An item; `action` is its index in the caller's actions (none: a
    /// heading or a disabled row).
    Item {
        label: String,
        disabled: bool,
        checked: bool,
        action: Option<usize>,
    },
    Separator,
    /// Continuity Camera is offered: AppKit adds a nearby device's items to
    /// the context menu itself (no item of the app's own).
    ImportFromDevice,
}

#[cfg(target_os = "macos")]
pub use macos::{
    MenuReport, accepting, chain, deliver, install, popup, requestor_in_chain, set_accepting,
    while_menu_tracks,
};

#[cfg(target_os = "macos")]
mod macos {
    use std::cell::Cell;
    use std::sync::atomic::{AtomicBool, Ordering};

    use futures::channel::mpsc;
    use objc2::rc::Retained;
    use objc2::runtime::{AnyObject, Bool, NSObject};
    use objc2::{
        AnyThread, ClassType as _, DefinedClass, MainThreadMarker, MainThreadOnly, Message as _,
        class, define_class, msg_send, sel,
    };
    use objc2_app_kit::{NSApplication, NSPasteboard, NSResponder, NSView, NSWindow};
    use objc2_foundation::{NSArray, NSPoint, NSString};

    use super::{Entry, ImportTarget, Imported, RETURN_TYPES, takes};

    /// Whether the requestor answers AppKit now: only while the + menu
    /// that offers Continuity Camera is open ([`while_menu_tracks`]).
    /// Outside it, a Services request that brings a picture back finds no
    /// requestor here, so nothing reaches the composer without the menu.
    /// (A photo taken from the menu still lands afterwards: AppKit hands it
    /// to the requestor it was given while the menu was open.)
    static ACCEPTING: AtomicBool = AtomicBool::new(false);

    pub fn set_accepting(on: bool) {
        ACCEPTING.store(on, Ordering::SeqCst);
    }

    /// Whether the requestor answers AppKit now.
    pub fn accepting() -> bool {
        ACCEPTING.load(Ordering::SeqCst)
    }

    /// Runs `menu` (the + menu's tracking loop) with the requestor answering
    /// when `offer` is set, and stops it answering once `menu` returns, by
    /// any path (an unwinding panic included).
    pub fn while_menu_tracks<T>(offer: bool, menu: impl FnOnce() -> T) -> T {
        struct Stop;
        impl Drop for Stop {
            fn drop(&mut self) {
                set_accepting(false);
            }
        }
        let _stop = Stop;
        set_accepting(offer);
        menu()
    }

    struct RequestorIvars {
        imports: mpsc::UnboundedSender<Imported>,
        /// This + menu session's ticket, carried by what it hands over.
        target: ImportTarget,
    }

    define_class!(
        // SAFETY: NSResponder has no subclassing requirements and
        // `Requestor` does not implement Drop.
        #[unsafe(super(NSResponder))]
        #[thread_kind = MainThreadOnly]
        #[name = "ConduitImportRequestor"]
        #[ivars = RequestorIvars]
        struct Requestor;

        impl Requestor {
            #[unsafe(method(validRequestorForSendType:returnType:))]
            fn valid_requestor(
                &self,
                send_type: *mut NSString,
                return_type: *mut NSString,
            ) -> *mut AnyObject {
                // SAFETY: AppKit passes NSStrings or nil.
                let (send, ret) = unsafe {
                    (
                        send_type.as_ref().map(|s| s.to_string()),
                        return_type.as_ref().map(|s| s.to_string()),
                    )
                };
                if accepting() && takes(send.as_deref(), ret.as_deref()) {
                    return self as *const Self as *mut AnyObject;
                }
                // SAFETY: NSResponder's own answer (the next responder's).
                unsafe {
                    msg_send![super(self), validRequestorForSendType: send_type, returnType: return_type]
                }
            }

            #[unsafe(method(readSelectionFromPasteboard:))]
            fn read_selection(&self, pasteboard: &NSPasteboard) -> Bool {
                Bool::new(self.read(pasteboard))
            }

            #[unsafe(method(writeSelectionToPasteboard:types:))]
            fn write_selection(&self, _pasteboard: &NSPasteboard, _types: &NSArray<NSString>) -> Bool {
                // Nothing goes out: Continuity Camera only brings things in.
                Bool::NO
            }
        }
    );

    impl Requestor {
        fn read(&self, pasteboard: &NSPasteboard) -> bool {
            for (ty, extension) in RETURN_TYPES {
                let data = pasteboard.dataForType(&NSString::from_str(ty));
                if let Some(data) = data {
                    let bytes = data.to_vec();
                    if bytes.is_empty() {
                        continue;
                    }
                    log::info!("continuity camera: a {extension} came back");
                    let _ = self.ivars().imports.unbounded_send(Imported {
                        bytes,
                        extension,
                        target: self.ivars().target.clone(),
                    });
                    return true;
                }
            }
            log::warn!("continuity camera: nothing it can take on the pasteboard");
            false
        }
    }

    thread_local! {
        /// The last + menu session's requestor (in the responder chain).
        static REQUESTOR: std::cell::RefCell<Option<Retained<Requestor>>> =
            const { std::cell::RefCell::new(None) };
        /// Earlier sessions' requestors, kept so a photo still on its way
        /// to one finds it (the newest few).
        static EARLIER: std::cell::RefCell<std::collections::VecDeque<Retained<Requestor>>> =
            const { std::cell::RefCell::new(std::collections::VecDeque::new()) };
        static REGISTERED: Cell<bool> = const { Cell::new(false) };
    }

    /// How many earlier sessions' requestors are kept.
    const KEEP_EARLIER: usize = 8;

    /// Starts a + menu session: a requestor of its own, holding `target`,
    /// goes right after the window's first responder (GPUI's view, which
    /// takes every key and click) in its responder chain, in place of the
    /// last session's, and the types it takes are registered once; what
    /// devices send through it comes on `imports`, carrying `target`. (After
    /// the window itself it is never asked: NSWindow answers
    /// `validRequestorForSendType:` without its next responder.)
    pub fn install(
        window: &NSWindow,
        imports: mpsc::UnboundedSender<Imported>,
        target: ImportTarget,
    ) {
        let Some(mtm) = MainThreadMarker::new() else {
            return;
        };
        let Some(first) = window.firstResponder() else {
            return;
        };
        // The first responder is the window itself before GPUI's view takes
        // it: nothing to follow yet.
        if std::ptr::eq(&*first, &**window as &NSResponder) {
            return;
        }
        let requestor: Retained<Requestor> = {
            let this = Requestor::alloc(mtm).set_ivars(RequestorIvars { imports, target });
            // SAFETY: NSResponder's designated initializer.
            unsafe { msg_send![super(this), init] }
        };
        // SAFETY: the responder chain, on the main thread. The view keeps
        // whatever followed it (its superview) after the requestor, skipping
        // the last session's requestor, which stays alive (below) for a
        // photo still on its way to it.
        unsafe {
            let mut tail = first.nextResponder();
            if let Some(next) = tail.as_deref()
                && std::ptr::eq(next.class(), Requestor::class())
            {
                tail = next.nextResponder();
            }
            requestor.setNextResponder(tail.as_deref());
            first.setNextResponder(Some(&requestor));
        }
        if let Some(last) = REQUESTOR.with(|slot| slot.borrow_mut().replace(requestor)) {
            EARLIER.with(|kept| {
                let mut kept = kept.borrow_mut();
                kept.push_back(last);
                while kept.len() > KEEP_EARLIER {
                    kept.pop_front();
                }
            });
        }
        if REGISTERED.with(|r| r.replace(true)) {
            return;
        }
        let types: Vec<Retained<NSString>> = RETURN_TYPES
            .iter()
            .map(|(ty, _)| NSString::from_str(ty))
            .collect();
        let returns = NSArray::from_retained_slice(&types);
        let sends: Retained<NSArray<NSString>> = NSArray::new();
        let app = NSApplication::sharedApplication(mtm);
        // SAFETY: AppKit call on the main thread.
        unsafe {
            let _: () =
                msg_send![&*app, registerServicesMenuSendTypes: &*sends, returnTypes: &*returns];
        }
        log::info!("continuity camera: the requestor follows the main window");
    }

    /// Whether `window`'s responder chain, from its first responder, offers
    /// the requestor for `return_type` (as AppKit asks when the menu opens).
    pub fn requestor_in_chain(window: &NSWindow, return_type: &str) -> bool {
        let Some(requestor) = REQUESTOR.with(|slot| slot.borrow().clone()) else {
            return false;
        };
        let ret = NSString::from_str(return_type);
        let none = std::ptr::null_mut::<NSString>();
        // SAFETY: NSResponder's method on the main thread; nil send type.
        let found: *mut AnyObject = unsafe {
            match window.firstResponder() {
                Some(responder) => {
                    msg_send![&*responder, validRequestorForSendType: none, returnType: &*ret]
                }
                None => msg_send![window, validRequestorForSendType: none, returnType: &*ret],
            }
        };
        std::ptr::eq(
            found as *const AnyObject,
            &*requestor as *const Requestor as *const AnyObject,
        )
    }

    /// The classes in `window`'s responder chain from its first responder,
    /// for the log.
    pub fn chain(window: &NSWindow) -> Vec<String> {
        let mut out = vec![];
        let mut next = window.firstResponder();
        while let Some(responder) = next {
            out.push(responder.class().name().to_string_lossy().into_owned());
            if out.len() > 12 {
                break;
            }
            // SAFETY: reads on the main thread.
            next = unsafe { responder.nextResponder() };
        }
        out
    }

    /// Hands the requestor `bytes` of `pasteboard_type` through its own
    /// `readSelectionFromPasteboard:`, as AppKit does when a device sends a
    /// photo (on a private pasteboard: the user's clipboard is not touched).
    /// For `--e2e mac-extras-2`.
    pub fn deliver(pasteboard_type: &str, bytes: &[u8]) -> bool {
        let Some(requestor) = REQUESTOR.with(|slot| slot.borrow().clone()) else {
            return false;
        };
        let pasteboard = NSPasteboard::pasteboardWithUniqueName();
        let ty = NSString::from_str(pasteboard_type);
        let types = NSArray::from_retained_slice(std::slice::from_ref(&ty));
        // SAFETY: Foundation/AppKit calls on the main thread.
        let read = unsafe {
            pasteboard.declareTypes_owner(&types, None);
            let data = objc2_foundation::NSData::with_bytes(bytes);
            pasteboard.setData_forType(Some(&data), &ty);
            let read: Bool = msg_send![&*requestor, readSelectionFromPasteboard: &*pasteboard];
            read.as_bool()
        };
        // SAFETY: as above; the pasteboard is this call's own.
        unsafe {
            let _: () = msg_send![&*pasteboard, releaseGlobally];
        }
        read
    }

    /// What was chosen in the menu [`popup`] opened.
    #[derive(Debug, Default)]
    pub struct MenuReport {
        pub chosen: Option<usize>,
    }

    struct TargetIvars {
        chosen: Cell<isize>,
    }

    define_class!(
        // SAFETY: NSObject has no subclassing requirements and `Target`
        // does not implement Drop.
        #[unsafe(super(NSObject))]
        #[name = "ConduitPlusMenuTarget"]
        #[ivars = TargetIvars]
        struct Target;

        impl Target {
            #[unsafe(method(itemChosen:))]
            fn item_chosen(&self, sender: &AnyObject) {
                // SAFETY: an NSMenuItem.
                let tag: isize = unsafe { msg_send![sender, tag] };
                self.ivars().chosen.set(tag);
            }
        }
    );

    /// Shows the + menu as a context menu over `view` (the window's content
    /// view), at `location` (its coordinates, flipped as AppKit's are),
    /// runs it, and says which action was chosen. The event AppKit is
    /// handed is a right-click there, in the window's first responder (GPUI's
    /// view, which the requestor follows), so AppKit finds the requestor
    /// and adds Continuity Camera's items. Main thread, outside any GPUI
    /// borrow (AppKit's tracking loop runs here).
    pub fn popup(view: &NSView, entries: &[Entry], location: NSPoint) -> MenuReport {
        let mut report = MenuReport::default();
        let target = {
            let this = Target::alloc().set_ivars(TargetIvars {
                chosen: Cell::new(-1),
            });
            // SAFETY: NSObject's designated initializer.
            let target: Retained<Target> = unsafe { msg_send![super(this), init] };
            target
        };
        // SAFETY: AppKit calls on the main thread; the menu owns its items
        // and lives until the tracking loop ends.
        unsafe {
            let menu: Retained<AnyObject> = msg_send![class!(NSMenu), new];
            let _: () = msg_send![&*menu, setAutoenablesItems: false];
            for entry in entries {
                match entry {
                    Entry::Separator => {
                        let item: *mut AnyObject = msg_send![class!(NSMenuItem), separatorItem];
                        let _: () = msg_send![&*menu, addItem: item];
                    }
                    // AppKit adds a nearby device's items to the context
                    // menu itself.
                    Entry::ImportFromDevice => {}
                    Entry::Item {
                        label,
                        disabled,
                        checked,
                        action,
                    } => {
                        let item: Retained<AnyObject> = msg_send![class!(NSMenuItem), new];
                        let _: () = msg_send![&*item, setTitle: &*NSString::from_str(label)];
                        let _: () = msg_send![&*item, setEnabled: !*disabled];
                        if *checked {
                            let _: () = msg_send![&*item, setState: 1isize];
                        }
                        if let (Some(action), false) = (action, *disabled) {
                            let _: () = msg_send![&*item, setTag: *action as isize];
                            let _: () = msg_send![&*item, setTarget: &*target];
                            let _: () = msg_send![&*item, setAction: sel!(itemChosen:)];
                        }
                        let _: () = msg_send![&*menu, addItem: &*item];
                    }
                }
            }
            // The view AppKit asks for a requestor: the first responder
            // (GPUI's view; the requestor follows it), else `view`.
            let target: Retained<NSView> = view
                .window()
                .and_then(|w| w.firstResponder())
                .and_then(|r| r.downcast::<NSView>().ok())
                .unwrap_or_else(|| view.retain());
            let window = view.window();
            let at_in_window = view.convertPoint_toView(location, None);
            let window_number: isize = window.as_ref().map_or(0, |w| w.windowNumber());
            // NSEventTypeRightMouseDown.
            let event: *mut AnyObject = msg_send![
                class!(NSEvent),
                mouseEventWithType: 3usize,
                location: at_in_window,
                modifierFlags: 0usize,
                timestamp: 0f64,
                windowNumber: window_number,
                context: std::ptr::null_mut::<AnyObject>(),
                eventNumber: 0isize,
                clickCount: 1isize,
                pressure: 1f32
            ];
            if !event.is_null() {
                let _: () = msg_send![
                    class!(NSMenu),
                    popUpContextMenu: &*menu,
                    withEvent: event,
                    forView: &*target
                ];
            }
        }
        let chosen = target.ivars().chosen.get();
        report.chosen = (chosen >= 0).then_some(chosen as usize);
        report
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn takes_pictures_and_scans_with_nothing_sent() {
        assert!(takes(None, Some("public.jpeg")));
        assert!(takes(Some(""), Some("com.adobe.pdf")));
        assert!(takes(None, Some("public.heic")));
        // Services that want the selection, or bring text back: not ours.
        assert!(!takes(Some("public.utf8-plain-text"), Some("public.jpeg")));
        assert!(!takes(None, Some("public.utf8-plain-text")));
        assert!(!takes(None, None));
    }

    /// Outside the + menu a Services request that brings a picture back
    /// finds no requestor: only the open menu offers it.
    #[cfg(target_os = "macos")]
    #[test]
    fn the_requestor_answers_only_while_the_menu_is_open() {
        assert!(!accepting(), "before any menu opened");
        assert!(while_menu_tracks(true, accepting), "while the menu is open");
        assert!(!accepting(), "after the menu closed");
        assert!(
            !while_menu_tracks(false, accepting),
            "a menu without the items"
        );
        let unwound = std::panic::catch_unwind(|| while_menu_tracks(true, || panic!("menu")));
        assert!(unwound.is_err());
        assert!(!accepting(), "after a menu that unwound");
    }

    #[test]
    fn names_a_photo_or_a_scan() {
        let photo = Imported {
            bytes: vec![1],
            extension: "heic",
            target: ImportTarget::default(),
        };
        assert_eq!(photo.file_name(), "Photo.heic");
        let scan = Imported {
            bytes: vec![1],
            extension: "pdf",
            target: ImportTarget::default(),
        };
        assert_eq!(scan.file_name(), "Scan.pdf");
    }
}
