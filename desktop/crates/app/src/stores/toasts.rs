//! Toasts: `notify.show` from the daemon, and the window's own short
//! notices (an account switched, a sign-out handed over). Newest last; each
//! leaves after its time, errors stay longer, and the user can dismiss one.
//!
//! VoiceOver hears each one as it is shown ([`announce`]: errors and
//! warnings at once, the rest in turn), even when it repeats the toast on
//! screen, which shows once: a second Copy is heard as a second "Copied".
//! A toast's `Role::Alert`/`Status` node alone would be silent (GPUI marks
//! no node live), so nothing else announces what a toast says.

use std::rc::Rc;
use std::time::Duration;

use conduit_components::announce::{Priority, announce};
use conduit_protocol::NoticeLevel;
use gpui_kit::{App, AsyncApp, Context, WeakEntity};

#[derive(Clone, Debug, PartialEq)]
pub struct Toast {
    pub id: u64,
    pub level: NoticeLevel,
    pub message: String,
    /// What "Try Again" does, on an error whose change can be sent again.
    pub retry: Option<Retry>,
    /// The action button's label in place of "Try Again" (a notification
    /// banner's Open).
    pub action_label: Option<String>,
}

/// Sends a failed change again (the toast's "Try Again").
#[derive(Clone)]
pub struct Retry(pub Rc<dyn Fn(&mut App)>);

impl Retry {
    pub fn new(run: impl Fn(&mut App) + 'static) -> Self {
        Self(Rc::new(run))
    }
}

impl std::fmt::Debug for Retry {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("Retry")
    }
}

/// Two retries are the same when they are the same closure.
impl PartialEq for Retry {
    fn eq(&self, other: &Self) -> bool {
        Rc::ptr_eq(&self.0, &other.0)
    }
}

/// How long a toast of `level` stays.
pub fn lifetime(level: NoticeLevel) -> Duration {
    match level {
        NoticeLevel::Error => Duration::from_secs(10),
        NoticeLevel::Warning => Duration::from_secs(7),
        _ => Duration::from_secs(5),
    }
}

/// How urgently VoiceOver speaks a toast of `level`.
pub fn priority(level: NoticeLevel) -> Priority {
    match level {
        NoticeLevel::Error | NoticeLevel::Warning => Priority::High,
        _ => Priority::Medium,
    }
}

/// At most this many show; the oldest goes first.
pub const MAX_TOASTS: usize = 3;

#[derive(Default)]
pub struct ToastStore {
    pub toasts: Vec<Toast>,
    next: u64,
}

impl ToastStore {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn show(&mut self, level: NoticeLevel, message: impl Into<String>, cx: &mut Context<Self>) {
        self.show_with_retry(level, message, None, cx);
    }

    /// [`Self::show`], with "Try Again" when `retry` is given (pressing it
    /// dismisses the toast and runs it).
    pub fn show_with_retry(
        &mut self,
        level: NoticeLevel,
        message: impl Into<String>,
        retry: Option<Retry>,
        cx: &mut Context<Self>,
    ) {
        self.push(level, message.into(), retry, None, cx);
    }

    /// A toast whose button says `label` and runs `run` (pressing it
    /// dismisses the toast first): an in-app notification banner.
    pub fn show_with_action(
        &mut self,
        level: NoticeLevel,
        message: impl Into<String>,
        label: impl Into<String>,
        run: Retry,
        cx: &mut Context<Self>,
    ) {
        self.push(level, message.into(), Some(run), Some(label.into()), cx);
    }

    fn push(
        &mut self,
        level: NoticeLevel,
        message: String,
        retry: Option<Retry>,
        action_label: Option<String>,
        cx: &mut Context<Self>,
    ) {
        if message.trim().is_empty() {
            return;
        }
        announce(message.clone(), priority(level), cx);
        // The same notice twice in a row is one.
        if self
            .toasts
            .last()
            .is_some_and(|t| t.message == message && t.level == level)
        {
            return;
        }
        self.next += 1;
        let id = self.next;
        self.toasts.push(Toast {
            id,
            level,
            message,
            retry,
            action_label,
        });
        while self.toasts.len() > MAX_TOASTS {
            self.toasts.remove(0);
        }
        cx.notify();
        let after = lifetime(level);
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            cx.background_executor().timer(after).await;
            let _ = this.update(cx, |s, cx| s.dismiss(id, cx));
        })
        .detach();
    }

    pub fn dismiss(&mut self, id: u64, cx: &mut Context<Self>) {
        let before = self.toasts.len();
        self.toasts.retain(|t| t.id != id);
        if self.toasts.len() != before {
            cx.notify();
        }
    }
}

#[cfg(test)]
mod tests {
    use gpui_kit::{AppContext as _, TestAppContext};

    use super::*;

    #[gpui_kit::test]
    fn toasts_expire_and_cap(cx: &mut TestAppContext) {
        let store = cx.new(|_| ToastStore::new());
        store.update(cx, |s, cx| {
            s.show(NoticeLevel::Info, "one", cx);
            s.show(NoticeLevel::Info, "one", cx);
            s.show(NoticeLevel::Error, "two", cx);
            s.show(NoticeLevel::Success, "three", cx);
            s.show(NoticeLevel::Warning, "four", cx);
            s.show(NoticeLevel::Info, "  ", cx);
        });
        let messages = store.read_with(cx, |s, _| {
            s.toasts
                .iter()
                .map(|t| t.message.clone())
                .collect::<Vec<_>>()
        });
        assert_eq!(messages, ["two", "three", "four"]);
        cx.executor().advance_clock(Duration::from_secs(8));
        cx.run_until_parked();
        let left = store.read_with(cx, |s, _| {
            s.toasts
                .iter()
                .map(|t| t.message.clone())
                .collect::<Vec<_>>()
        });
        assert_eq!(left, ["two"], "errors stay longest");
        cx.executor().advance_clock(Duration::from_secs(3));
        cx.run_until_parked();
        assert!(store.read_with(cx, |s, _| s.toasts.is_empty()));
    }

    #[gpui_kit::test]
    fn each_toast_is_announced_even_when_it_shows_once(cx: &mut TestAppContext) {
        use conduit_components::announce::{Announcement, AnnouncementLog};
        cx.update(AnnouncementLog::install);
        let store = cx.new(|_| ToastStore::new());
        store.update(cx, |s, cx| {
            s.show(NoticeLevel::Info, "Copied", cx);
            s.show(NoticeLevel::Info, "Copied", cx);
            s.show(NoticeLevel::Error, "Couldn't rename the chat.", cx);
            s.show(NoticeLevel::Info, " ", cx);
        });
        assert_eq!(store.read_with(cx, |s, _| s.toasts.len()), 2);
        let log = cx.update(|cx| cx.global::<AnnouncementLog>().0.clone());
        assert_eq!(
            log,
            [
                Announcement {
                    text: "Copied".into(),
                    priority: Priority::Medium
                },
                Announcement {
                    text: "Copied".into(),
                    priority: Priority::Medium
                },
                Announcement {
                    text: "Couldn't rename the chat.".into(),
                    priority: Priority::High
                },
            ]
        );
    }

    #[gpui_kit::test]
    fn a_retryable_error_keeps_what_try_again_does(cx: &mut TestAppContext) {
        let store = cx.new(|_| ToastStore::new());
        let tries = Rc::new(std::cell::Cell::new(0));
        let retry = {
            let tries = tries.clone();
            Retry::new(move |_| tries.set(tries.get() + 1))
        };
        store.update(cx, |s, cx| {
            s.show_with_retry(NoticeLevel::Error, "failed", Some(retry.clone()), cx);
            s.show(NoticeLevel::Info, "plain", cx);
        });
        let kept = store.read_with(cx, |s, _| {
            s.toasts.iter().map(|t| t.retry.clone()).collect::<Vec<_>>()
        });
        assert_eq!(kept, [Some(retry), None]);
        let run = kept[0].clone().unwrap();
        cx.update(|cx| (run.0)(cx));
        assert_eq!(tries.get(), 1);
    }
}
