//! The macOS shell extras' state, as the views read it:
//!
//! * the **inbox**: `conduit://` links, "Open with" files and notification
//!   clicks that arrived before the app could act on them. Requests that
//!   need the main frame wait until the main window exists and the session
//!   routes to Main (cold launch, or a launch at login); Settings opens at
//!   once;
//! * what the system answered for each service: the Quick Ask hotkey, the
//!   notification permission, the login item, and whether the menu-bar
//!   item is installed;
//! * whether the Quick Ask window shows.
//!
//! The services themselves live in [`crate::desktop`], which writes their
//! outcomes here; this store has no platform code, so the views and the
//! tests can use it anywhere.

use std::collections::VecDeque;

use gpui_kit::Context;

use crate::shell::deep_link::OpenRequest;

/// The Quick Ask shortcut, as the hot key API took it.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum HotkeyState {
    /// Not applied yet, or Quick Ask's shortcut is off.
    #[default]
    Off,
    Registered,
    /// Another app holds the chord.
    Taken,
    /// The chord's key can't be a hot key.
    Invalid,
    /// The hot key manager didn't start.
    Unavailable,
}

/// Whether the app may notify.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum NotificationAccess {
    /// Not checked yet.
    #[default]
    Unknown,
    /// Outside an app bundle (a bare binary): no notifications.
    Unavailable,
    /// The system hasn't asked the user yet.
    NotDetermined,
    Denied,
    Allowed,
    /// Allowed quietly (Notification Center only).
    Quiet,
}

/// The login item, as `SMAppService` reports it.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum LoginState {
    #[default]
    Unknown,
    Off,
    On,
    /// Registered; the user has to allow it in System Settings.
    NeedsApproval,
    /// The system can't find the app.
    NotFound,
}

impl LoginState {
    pub fn is_on(self) -> bool {
        matches!(self, Self::On | Self::NeedsApproval)
    }
}

#[derive(Default)]
pub struct ShellStore {
    pending: VecDeque<OpenRequest>,
    pub hotkey: HotkeyState,
    pub notifications: NotificationAccess,
    pub login: LoginState,
    /// The last time changing the login item failed: the system's reason.
    pub login_error: Option<String>,
    /// The menu-bar item is installed.
    pub menu_bar_item: bool,
    /// The Quick Ask window is on screen.
    pub quick_ask_visible: bool,
    /// The app started for the login item (or with `--hidden`).
    pub hidden_start: bool,
}

impl ShellStore {
    pub fn new() -> Self {
        Self::default()
    }

    /// Queues `request`. Files for a new chat join the new chat with files
    /// queued last, so one "Open with" burst makes one chat; after another
    /// request they start a chat of their own.
    pub fn push(&mut self, request: OpenRequest, cx: &mut Context<Self>) {
        queue(&mut self.pending, request);
        cx.notify();
    }

    /// What can be acted on now: Settings at once, the rest once
    /// `main_ready` (the main window shows the main frame). The others stay
    /// queued, in order.
    pub fn take_ready(&mut self, main_ready: bool) -> Vec<OpenRequest> {
        take_ready(&mut self.pending, main_ready)
    }

    /// Whether something waits for the main frame.
    pub fn waits_for_main(&self) -> bool {
        self.pending.iter().any(OpenRequest::needs_main)
    }

    pub fn pending(&self) -> impl Iterator<Item = &OpenRequest> {
        self.pending.iter()
    }

    pub fn set_hotkey(&mut self, state: HotkeyState, cx: &mut Context<Self>) {
        if self.hotkey != state {
            self.hotkey = state;
            cx.notify();
        }
    }

    pub fn set_notifications(&mut self, access: NotificationAccess, cx: &mut Context<Self>) {
        if self.notifications != access {
            self.notifications = access;
            cx.notify();
        }
    }

    pub fn set_login(&mut self, state: LoginState, error: Option<String>, cx: &mut Context<Self>) {
        self.login = state;
        self.login_error = error;
        cx.notify();
    }

    pub fn set_menu_bar_item(&mut self, installed: bool, cx: &mut Context<Self>) {
        if self.menu_bar_item != installed {
            self.menu_bar_item = installed;
            cx.notify();
        }
    }

    pub fn set_quick_ask_visible(&mut self, visible: bool, cx: &mut Context<Self>) {
        if self.quick_ask_visible != visible {
            self.quick_ask_visible = visible;
            cx.notify();
        }
    }
}

fn queue(pending: &mut VecDeque<OpenRequest>, request: OpenRequest) {
    if let OpenRequest::NewChat {
        text: None,
        files: incoming,
    } = &request
        && !incoming.is_empty()
        && let Some(OpenRequest::NewChat { files, .. }) = pending
            .back_mut()
            .filter(|r| matches!(r, OpenRequest::NewChat { files, .. } if !files.is_empty()))
    {
        for f in incoming {
            if !files.contains(f) {
                files.push(f.clone());
            }
        }
        return;
    }
    pending.push_back(request);
}

fn take_ready(pending: &mut VecDeque<OpenRequest>, main_ready: bool) -> Vec<OpenRequest> {
    let mut ready = vec![];
    let mut waiting = VecDeque::new();
    for request in pending.drain(..) {
        if main_ready || !request.needs_main() {
            ready.push(request);
        } else {
            waiting.push_back(request);
        }
    }
    *pending = waiting;
    ready
}

#[cfg(test)]
mod tests {
    use std::path::PathBuf;

    use super::*;

    fn chat(id: &str) -> OpenRequest {
        OpenRequest::Chat { id: id.into() }
    }

    fn files(names: &[&str]) -> OpenRequest {
        OpenRequest::NewChat {
            text: None,
            files: names.iter().map(PathBuf::from).collect(),
        }
    }

    #[test]
    fn requests_wait_for_the_main_frame_but_settings_does_not() {
        let mut q = VecDeque::new();
        queue(&mut q, chat("c1"));
        queue(&mut q, OpenRequest::Settings { tab: None });
        queue(
            &mut q,
            OpenRequest::NewChat {
                text: Some("hi".into()),
                files: vec![],
            },
        );
        // Cold launch: no main frame yet. Settings goes; the rest waits.
        assert_eq!(
            take_ready(&mut q, false),
            vec![OpenRequest::Settings { tab: None }]
        );
        assert_eq!(q.len(), 2);
        assert_eq!(take_ready(&mut q, false), vec![]);
        // Routed to Main: the rest, in order.
        let ready = take_ready(&mut q, true);
        assert_eq!(ready[0], chat("c1"));
        assert!(matches!(ready[1], OpenRequest::NewChat { .. }));
        assert!(q.is_empty());
    }

    #[test]
    fn one_open_with_burst_makes_one_new_chat() {
        let mut q = VecDeque::new();
        queue(&mut q, files(&["/a.md"]));
        queue(&mut q, files(&["/b.pdf", "/a.md"]));
        queue(&mut q, chat("c1"));
        assert_eq!(q.len(), 2);
        assert_eq!(q[0], files(&["/a.md", "/b.pdf"]));
        // A text link is its own request.
        queue(
            &mut q,
            OpenRequest::NewChat {
                text: Some("x".into()),
                files: vec![],
            },
        );
        assert_eq!(q.len(), 3);
        // Files after another request are a chat of their own, in order.
        queue(&mut q, files(&["/c.txt"]));
        assert_eq!(q.len(), 4);
        assert_eq!(q[0], files(&["/a.md", "/b.pdf"]));
        assert_eq!(q[3], files(&["/c.txt"]));
    }

    #[gpui_kit::test]
    fn the_store_reports_what_waits(cx: &mut gpui_kit::TestAppContext) {
        use gpui_kit::AppContext as _;
        let store = cx.new(|_| ShellStore::new());
        store.update(cx, |s, cx| {
            assert!(!s.waits_for_main());
            s.push(chat("c1"), cx);
            assert!(s.waits_for_main());
            assert!(s.take_ready(false).is_empty());
            assert_eq!(s.take_ready(true), vec![chat("c1")]);
            assert!(!s.waits_for_main());
            s.set_login(LoginState::NeedsApproval, None, cx);
            assert!(s.login.is_on());
        });
    }
}
