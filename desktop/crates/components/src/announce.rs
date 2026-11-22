//! VoiceOver announcements: words spoken for something that changed where
//! the user isn't looking ("Copied", a menu's highlighted row, an error that
//! appeared under a form).
//!
//! * [`announce`] speaks a text once, now. On macOS it posts
//!   `NSAccessibilityAnnouncementRequestedNotification` with the text and a
//!   priority on the key window (AppKit's way for an app to speak without
//!   moving the VoiceOver cursor); elsewhere it does nothing. With VoiceOver
//!   off the notification goes nowhere, so it never needs a permission.
//! * [`live_text`] is a live region: a zero-size element that announces its
//!   text when it first draws with one, and again whenever the text
//!   changes. GPUI has no `aria-live` (AccessKit's macOS adapter only
//!   speaks nodes marked live, and GPUI never marks any), so a node's
//!   `Role::Alert` or `Role::Status` alone is silent: put a `live_text`
//!   beside it with the same words. A region that shows what an action
//!   answered gives it the action's [`LiveText::attempt`], so a retry
//!   answered in the same words is heard again.
//!
//! An [`AnnouncementLog`] global, when installed, keeps every announcement,
//! so tests and the E2E passes can check what VoiceOver would have heard.
//!
//! Off the Mac, [`install_live_regions`] makes announcements AccessKit live
//! regions, which Narrator and NVDA (UIA) and Orca (AT-SPI) speak: each
//! window's root draws the announcements made while it was in front as new
//! live nodes ([`LiveRegion`]), so the same words twice are heard twice.
//! They wait in a queue and go out one per frame: AccessKit hands the nodes
//! one tree update adds to the screen reader in no set order, so a burst
//! (a form's errors) would otherwise be heard out of order. [`live_text`]
//! speaks through [`announce`], so it follows.

use gpui_kit::base::{Root, RootPlugin};
use gpui_kit::prelude::*;
use gpui_kit::{
    AnyWindowHandle, App, Context, Element, ElementId, Global, GlobalElementId, InspectorElementId,
    IntoElement, LayoutId, Live, Pixels, Role, SharedString, Style, Subscription, Window, div, px,
};

/// How urgently VoiceOver speaks an announcement: `High` interrupts what it
/// is saying (a menu's highlighted row, which the next arrow press replaces;
/// an error), `Medium` waits its turn (a confirmation such as "Copied"),
/// `Low` may be dropped when VoiceOver is busy.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Priority {
    Low,
    Medium,
    High,
}

/// One announcement, as the [`AnnouncementLog`] keeps it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Announcement {
    pub text: SharedString,
    pub priority: Priority,
}

/// Every announcement made while this global is installed, oldest first.
#[derive(Clone, Debug, Default)]
pub struct AnnouncementLog(pub Vec<Announcement>);

impl Global for AnnouncementLog {}

impl AnnouncementLog {
    /// Starts keeping announcements (tests, E2E passes).
    pub fn install(cx: &mut App) {
        if !cx.has_global::<Self>() {
            cx.set_global(Self::default());
        }
    }

    /// The texts announced so far, oldest first.
    pub fn texts(cx: &App) -> Vec<SharedString> {
        cx.try_global::<Self>()
            .map(|log| log.0.iter().map(|a| a.text.clone()).collect())
            .unwrap_or_default()
    }

    /// The last announcement, if any.
    pub fn last(cx: &App) -> Option<Announcement> {
        cx.try_global::<Self>()
            .and_then(|log| log.0.last().cloned())
    }

    /// How many announcements were made so far.
    pub fn len(cx: &App) -> usize {
        cx.try_global::<Self>().map_or(0, |log| log.0.len())
    }
}

/// Speaks `text` to VoiceOver once, now. Blank text says nothing.
pub fn announce(text: impl Into<SharedString>, priority: Priority, cx: &mut App) {
    let text: SharedString = text.into();
    if text.trim().is_empty() {
        return;
    }
    if cx.has_global::<AnnouncementLog>() {
        cx.global_mut::<AnnouncementLog>().0.push(Announcement {
            text: text.clone(),
            priority,
        });
    }
    #[cfg(target_os = "macos")]
    macos::post(&text, priority);
    if cx.has_global::<LiveAnnouncements>() {
        let window = cx.active_window().or_else(|| cx.windows().first().copied());
        let live = cx.global_mut::<LiveAnnouncements>();
        live.serial += 1;
        let announcement = LiveAnnouncement {
            serial: live.serial,
            window,
            text,
            priority,
        };
        let pending = live.pending.get_mut();
        if pending.len() == LIVE_PENDING_CAP {
            pending.pop_front();
        }
        pending.push_back(announcement);
    }
}

/// A safety cap on announcements waiting for their frame (one goes out per
/// frame, so only a runaway loop comes near it).
pub const LIVE_PENDING_CAP: usize = 256;

/// The announcements waiting for their window's live region (off the Mac).
#[derive(Default)]
pub struct LiveAnnouncements {
    serial: u64,
    // Taken through `cx.global`: `global_mut` would notify every window's
    // region on each take, redrawing them all and, in tests, draining the
    // queue in one update.
    pending: std::cell::RefCell<std::collections::VecDeque<LiveAnnouncement>>,
}

impl Global for LiveAnnouncements {}

impl LiveAnnouncements {
    fn waiting(&self, window: AnyWindowHandle) -> bool {
        self.pending
            .borrow()
            .iter()
            .any(|a| a.window == Some(window))
    }

    /// The oldest announcement waiting for `window`, taken off the queue.
    fn take_next(&self, window: AnyWindowHandle) -> Option<LiveAnnouncement> {
        let mut pending = self.pending.borrow_mut();
        let at = pending.iter().position(|a| a.window == Some(window))?;
        pending.remove(at)
    }

    /// How many are waiting, for every window.
    pub fn waiting_count(&self) -> usize {
        self.pending.borrow().len()
    }
}

/// One announcement as a live region speaks it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LiveAnnouncement {
    /// Which announcement: each is a new node, heard even in the words of
    /// the last.
    pub serial: u64,
    /// The window in front when it was made (else the first open).
    pub window: Option<AnyWindowHandle>,
    pub text: SharedString,
    pub priority: Priority,
}

/// Makes [`announce`] speak through AccessKit live regions in every window
/// opened after this (Windows and Linux; the Mac posts to VoiceOver).
pub fn install_live_regions(cx: &mut App) {
    if !cx.has_global::<LiveAnnouncements>() {
        cx.set_global(LiveAnnouncements::default());
    }
    Root::register_plugin::<LiveRegion>(cx, LiveRegion::new);
}

/// A window's live region: a zero-size node over the content, drawn again
/// whenever an announcement is made. Each frame it takes at most one
/// waiting announcement and shows it as a new node, asking for another
/// frame while more wait.
pub struct LiveRegion {
    _announced: Subscription,
    shown: Option<LiveAnnouncement>,
}

impl LiveRegion {
    fn new(_: &mut Window, cx: &mut Context<Self>) -> Self {
        Self {
            _announced: cx.observe_global::<LiveAnnouncements>(|_, cx| cx.notify()),
            shown: None,
        }
    }

    /// The announcement the last frame drew, if any.
    pub fn shown(&self) -> Option<&LiveAnnouncement> {
        self.shown.as_ref()
    }
}

impl RootPlugin for LiveRegion {}

impl gpui_kit::Render for LiveRegion {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let me = window.window_handle();
        if let Some(live) = cx.try_global::<LiveAnnouncements>()
            && let Some(next) = live.take_next(me)
        {
            self.shown = Some(next);
            if live.waiting(me) {
                window.request_animation_frame();
            }
        }
        div()
            .absolute()
            .size_0()
            .children(self.shown.iter().cloned().map(|a| {
                let (role, live) = match a.priority {
                    Priority::High => (Role::Alert, Live::Assertive),
                    Priority::Low | Priority::Medium => (Role::Status, Live::Polite),
                };
                div()
                    .id(("announcement", a.serial))
                    .role(role)
                    .aria_live(live)
                    .aria_label(a.text)
                    .absolute()
                    .size_0()
            }))
    }
}

/// A live region of `text`: announced when it first draws with text, and
/// whenever the text (or its [`LiveText::attempt`]) changes after. `None`
/// keeps quiet, and the next text counts as new. `id` must be stable across
/// frames (with the ids of the elements around it, it names the region).
pub fn live_text(
    id: impl Into<ElementId>,
    text: Option<SharedString>,
    priority: Priority,
) -> LiveText {
    LiveText {
        id: id.into(),
        text: text.filter(|t| !t.trim().is_empty()),
        attempt: 0,
        priority,
    }
}

/// See [`live_text`].
pub struct LiveText {
    id: ElementId,
    text: Option<SharedString>,
    attempt: u64,
    priority: Priority,
}

impl LiveText {
    /// Which completed action the text answers: a count its view adds one
    /// to as each request, Save or step finishes, and never on a redraw. A
    /// new attempt is heard even in the words of the last one (a retry that
    /// failed the same way); the same attempt drawn again stays quiet.
    pub fn attempt(mut self, attempt: u64) -> Self {
        self.attempt = attempt;
        self
    }
}

/// What a live region showed on a frame: its text and the attempt it
/// answered.
type Shown = (Option<SharedString>, u64);

impl IntoElement for LiveText {
    type Element = Self;

    fn into_element(self) -> Self::Element {
        self
    }
}

/// Whether a live region showing `now`, after `before` on the previous
/// frame, speaks: it has text, and the text or the attempt is new.
fn speaks(before: Option<&Shown>, now: &Shown) -> bool {
    now.0.is_some() && before != Some(now)
}

impl Element for LiveText {
    type RequestLayoutState = ();
    type PrepaintState = ();

    fn id(&self) -> Option<ElementId> {
        Some(self.id.clone())
    }

    fn source_location(&self) -> Option<&'static std::panic::Location<'static>> {
        None
    }

    fn request_layout(
        &mut self,
        _: Option<&GlobalElementId>,
        _: Option<&InspectorElementId>,
        window: &mut Window,
        cx: &mut App,
    ) -> (LayoutId, Self::RequestLayoutState) {
        // Out of the flow: no size, and no share of a flex row's gap.
        let mut style = Style {
            position: gpui_kit::Position::Absolute,
            ..Style::default()
        };
        style.size.width = px(0.).into();
        style.size.height = px(0.).into();
        (window.request_layout(style, None, cx), ())
    }

    fn prepaint(
        &mut self,
        global_id: Option<&GlobalElementId>,
        _: Option<&InspectorElementId>,
        _: gpui_kit::Bounds<Pixels>,
        _: &mut Self::RequestLayoutState,
        window: &mut Window,
        cx: &mut App,
    ) -> Self::PrepaintState {
        let Some(global_id) = global_id else {
            return;
        };
        let now: Shown = (self.text.clone(), self.attempt);
        let speak = window.with_element_state(global_id, |before: Option<Shown>, _| {
            (speaks(before.as_ref(), &now), now.clone())
        });
        if speak && let Some(text) = now.0 {
            announce(text, self.priority, cx);
        }
    }

    fn paint(
        &mut self,
        _: Option<&GlobalElementId>,
        _: Option<&InspectorElementId>,
        _: gpui_kit::Bounds<Pixels>,
        _: &mut Self::RequestLayoutState,
        _: &mut Self::PrepaintState,
        _: &mut Window,
        _: &mut App,
    ) {
    }
}

#[cfg(target_os = "macos")]
mod macos {
    use super::Priority;
    use objc2::MainThreadMarker;
    use objc2::rc::Retained;
    use objc2::runtime::{AnyObject, ProtocolObject};
    use objc2_app_kit::{
        NSAccessibilityAnnouncementKey, NSAccessibilityAnnouncementRequestedNotification,
        NSAccessibilityPostNotificationWithUserInfo, NSAccessibilityPriorityKey,
        NSAccessibilityPriorityLevel, NSApplication,
    };
    use objc2_foundation::{NSMutableDictionary, NSNumber, NSString};

    fn level(priority: Priority) -> NSAccessibilityPriorityLevel {
        match priority {
            Priority::Low => NSAccessibilityPriorityLevel::Low,
            Priority::Medium => NSAccessibilityPriorityLevel::Medium,
            Priority::High => NSAccessibilityPriorityLevel::High,
        }
    }

    /// Posts the announcement on the key window (else the main window, else
    /// the app), as AppKit's own controls do. Off the main thread (unit
    /// tests) it does nothing.
    pub(super) fn post(text: &str, priority: Priority) {
        let Some(mtm) = MainThreadMarker::new() else {
            return;
        };
        let app = NSApplication::sharedApplication(mtm);
        let element: Retained<AnyObject> = match app.keyWindow().or_else(|| app.mainWindow()) {
            Some(window) => window.into_super().into_super().into_super(),
            None => app.into_super().into_super().into_super(),
        };
        let info = NSMutableDictionary::<NSString, AnyObject>::new();
        let text = NSString::from_str(text);
        let level = NSNumber::new_isize(level(priority).0);
        // SAFETY: AppKit's constants; the dictionary holds an NSString and
        // an NSNumber under the keys the notification documents, and the
        // element is a live NSWindow or NSApplication on the main thread.
        unsafe {
            info.setObject_forKey(
                &*text,
                ProtocolObject::from_ref(NSAccessibilityAnnouncementKey),
            );
            info.setObject_forKey(
                &*level,
                ProtocolObject::from_ref(NSAccessibilityPriorityKey),
            );
            NSAccessibilityPostNotificationWithUserInfo(
                &element,
                NSAccessibilityAnnouncementRequestedNotification,
                Some(&info),
            );
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use gpui_kit::{TestAppContext, VisualTestContext};

    #[gpui_kit::test]
    fn announce_keeps_text_and_priority_and_skips_blank(cx: &mut TestAppContext) {
        cx.update(|cx| {
            AnnouncementLog::install(cx);
            announce("Copied", Priority::Medium, cx);
            announce("   ", Priority::High, cx);
            announce("Branch 2 of 3", Priority::High, cx);
            let log = cx.global::<AnnouncementLog>().0.clone();
            assert_eq!(
                log,
                vec![
                    Announcement {
                        text: "Copied".into(),
                        priority: Priority::Medium
                    },
                    Announcement {
                        text: "Branch 2 of 3".into(),
                        priority: Priority::High
                    },
                ]
            );
        });
    }

    #[gpui_kit::test]
    fn announce_without_a_log_is_harmless(cx: &mut TestAppContext) {
        cx.update(|cx| {
            announce("Copied", Priority::Medium, cx);
            assert_eq!(AnnouncementLog::len(cx), 0);
        });
    }

    struct Blank;

    impl Render for Blank {
        fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
            div()
        }
    }

    /// Off the Mac an announcement is the window in front's live region,
    /// a new one each time, so the same words twice are heard twice.
    #[gpui_kit::test]
    fn off_the_mac_an_announcement_is_the_front_windows_live_region(cx: &mut TestAppContext) {
        cx.update(|cx| {
            gpui_kit::init(cx);
            install_live_regions(cx);
        });
        let open = |cx: &mut TestAppContext| -> AnyWindowHandle {
            cx.update(|cx| {
                cx.open_window(Default::default(), |window, cx| {
                    let view = cx.new(|_| Blank);
                    cx.new(|cx| Root::new(view, window, cx))
                })
                .unwrap()
                .into()
            })
        };
        let front = open(cx);
        let back = open(cx);
        cx.update(|cx| {
            front
                .update(cx, |_, window, _| window.activate_window())
                .unwrap()
        });
        cx.run_until_parked();
        // The node a window's live region drew last. A test window draws
        // as soon as an update leaves it dirty, as the platform would on
        // its next frame.
        let shown = |cx: &mut TestAppContext, window: AnyWindowHandle| {
            cx.update(|cx| {
                window
                    .update(cx, |_, window, cx| {
                        Root::read(window, cx)
                            .plugin::<LiveRegion>()
                            .and_then(|r| r.read(cx).shown().cloned())
                    })
                    .unwrap()
            })
        };
        // The platform's next frame: whether the window asked for one.
        let next_frame = |cx: &mut TestAppContext, window: AnyWindowHandle| {
            cx.update(|cx| {
                window
                    .update(cx, |_, window, cx| window.simulate_next_frame(cx) > 0)
                    .unwrap()
            })
        };
        let waiting = |cx: &mut TestAppContext| {
            cx.update(|cx| cx.global::<LiveAnnouncements>().waiting_count())
        };
        cx.update(|cx| announce("Copied", Priority::Medium, cx));
        let first = shown(cx, front).unwrap();
        assert_eq!(first.text, SharedString::from("Copied"));
        assert_eq!(first.priority, Priority::Medium);
        assert_eq!(shown(cx, back), None);
        cx.update(|cx| announce("Copied", Priority::Medium, cx));
        let again = shown(cx, front).unwrap();
        assert_ne!(again.serial, first.serial, "the same words, a new node");
        assert!(!next_frame(cx, front), "nothing waits, no frame asked for");

        // A burst in one update goes out one per frame, in order: AccessKit
        // speaks the nodes one update adds in no set order.
        cx.update(|cx| {
            announce("Name is required.", Priority::High, cx);
            announce("Server address is not valid.", Priority::High, cx);
        });
        let text = |a: Option<LiveAnnouncement>| a.map(|a| a.text);
        assert_eq!(text(shown(cx, front)), Some("Name is required.".into()));
        assert_eq!(waiting(cx), 1);
        assert!(next_frame(cx, front));
        assert_eq!(
            text(shown(cx, front)),
            Some("Server address is not valid.".into())
        );
        // Nothing new: the last stays, and no frame is asked for.
        assert!(!next_frame(cx, front));
        assert_eq!(
            text(shown(cx, front)),
            Some("Server address is not valid.".into())
        );
        // A long burst loses none before its frame.
        cx.update(|cx| {
            for n in 0..20 {
                announce(format!("Step {n}"), Priority::Low, cx);
            }
        });
        for n in 0..20 {
            if n > 0 {
                assert!(next_frame(cx, front), "frame {n} asked for");
            }
            assert_eq!(
                text(shown(cx, front)),
                Some(format!("Step {n}").into()),
                "frame {n}"
            );
        }
        assert_eq!(waiting(cx), 0);
        assert!(!next_frame(cx, front));
        // Each window's root carries a live region.
        for window in [front, back] {
            let has_region = cx
                .update(|cx| {
                    window.update(cx, |_, window, cx| {
                        Root::read(window, cx).plugin::<LiveRegion>().is_some()
                    })
                })
                .unwrap();
            assert!(has_region);
        }
    }

    /// Without live regions installed (the Mac) nothing is kept for them.
    #[gpui_kit::test]
    fn the_mac_keeps_no_live_regions(cx: &mut TestAppContext) {
        cx.update(|cx| {
            announce("Copied", Priority::Medium, cx);
            assert!(!cx.has_global::<LiveAnnouncements>());
        });
    }

    #[test]
    fn a_live_region_speaks_new_and_changed_text_only() {
        let a = |n| (Some(SharedString::from("Wrong password.")), n);
        let b = |n| (Some(SharedString::from("Too many tries.")), n);
        let none = |n| (None, n);
        assert!(speaks(None, &a(0)));
        assert!(!speaks(Some(&a(0)), &a(0)));
        assert!(speaks(Some(&a(0)), &b(0)));
        assert!(!speaks(Some(&a(0)), &none(0)));
        assert!(!speaks(None, &none(0)));
        // A new attempt answered in the same words is heard; none still
        // says nothing.
        assert!(speaks(Some(&a(0)), &a(1)));
        assert!(!speaks(Some(&a(0)), &none(1)));
    }

    struct Form {
        error: Option<SharedString>,
        attempt: u64,
    }

    impl Render for Form {
        fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
            div()
                .id("form")
                .size_full()
                .child(live_text("error", self.error.clone(), Priority::High).attempt(self.attempt))
        }
    }

    fn draw(vcx: &mut VisualTestContext) {
        vcx.update(|window, cx| window.draw(cx).clear(cx));
        vcx.run_until_parked();
    }

    #[gpui_kit::test]
    fn a_live_region_in_a_window_announces_once_per_change(cx: &mut TestAppContext) {
        cx.update(AnnouncementLog::install);
        let (view, vcx) = cx.add_window_view(|_, _| Form {
            error: None,
            attempt: 0,
        });
        draw(vcx);
        assert_eq!(vcx.update(|_, cx| AnnouncementLog::len(cx)), 0);

        vcx.update(|_, cx| {
            view.update(cx, |f, cx| {
                f.error = Some("Wrong password.".into());
                cx.notify();
            })
        });
        draw(vcx);
        draw(vcx);
        let texts = vcx.update(|_, cx| AnnouncementLog::texts(cx));
        assert_eq!(texts, vec![SharedString::from("Wrong password.")]);

        // Cleared, then the same words again: a new error, heard again.
        vcx.update(|_, cx| {
            view.update(cx, |f, cx| {
                f.error = None;
                cx.notify();
            })
        });
        draw(vcx);
        vcx.update(|_, cx| {
            view.update(cx, |f, cx| {
                f.error = Some("Wrong password.".into());
                cx.notify();
            })
        });
        draw(vcx);
        assert_eq!(vcx.update(|_, cx| AnnouncementLog::len(cx)), 2);
        assert_eq!(
            vcx.update(|_, cx| AnnouncementLog::last(cx)),
            Some(Announcement {
                text: "Wrong password.".into(),
                priority: Priority::High
            })
        );

        // A retry answered in the same words, with no frame between: the
        // next attempt is heard once, and its redraws stay quiet.
        vcx.update(|_, cx| {
            view.update(cx, |f, cx| {
                f.attempt += 1;
                cx.notify();
            })
        });
        draw(vcx);
        draw(vcx);
        assert_eq!(vcx.update(|_, cx| AnnouncementLog::len(cx)), 3);
    }
}
