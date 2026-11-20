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

use gpui_kit::{
    App, Element, ElementId, Global, GlobalElementId, InspectorElementId, IntoElement, LayoutId,
    Pixels, SharedString, Style, Window, px,
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
    use gpui_kit::prelude::*;
    use gpui_kit::{Context, TestAppContext, VisualTestContext, div};

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
