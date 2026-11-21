//! Answer and channel notifications: what the window knows about one, and
//! what it says.
//!
//! On `turn.finished` (unscoped, so it arrives for chats that are not open)
//! and `channels.posted`, the app tells the core what only it knows (whether
//! the app is in front, and whether the chat or channel is on screen in a
//! window that has the user's attention: the main window is key and shows
//! it, or the Quick Ask window is key and shows the chat), and the core
//! decides (`notifications.route`): an in-app banner, a system notification,
//! silence, or nothing. Failed turns notify too, with an error title.
//!
//! A notification carries the chat's title and a short neutral line, never
//! the answer: notifications show on the lock screen and on shared screens.

use super::deep_link::valid_id;

/// Which notification a finished turn gets.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum NotificationKind {
    /// The answer is ready.
    Ready,
    /// The turn failed.
    Failed,
}

/// What the user can see right now.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct OnScreen {
    /// The app is in front (active).
    pub app_active: bool,
    /// The main window is the key window (visible, focused, app active).
    pub main_key: bool,
    /// The stored chat the main window shows.
    pub main_chat: Option<String>,
    /// The Quick Ask window is the key window.
    pub quick_ask_key: bool,
    /// The chat the Quick Ask window shows.
    pub quick_ask_chat: Option<String>,
    /// The channel the main window shows.
    pub main_channel: Option<String>,
}

impl OnScreen {
    /// Whether `chat_id` is in front of the user.
    pub fn shows(&self, chat_id: &str) -> bool {
        (self.main_key && self.main_chat.as_deref() == Some(chat_id))
            || (self.quick_ask_key && self.quick_ask_chat.as_deref() == Some(chat_id))
    }

    /// Whether `channel_id` is in front of the user.
    pub fn shows_channel(&self, channel_id: &str) -> bool {
        self.main_key && self.main_channel.as_deref() == Some(channel_id)
    }
}

/// How a turn ended, as `turn.finished` says.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Outcome {
    /// With an answer (a stopped one counts).
    Answered,
    /// It failed.
    Failed,
    /// Its request waits in the outbox (sent while offline), or the server
    /// holds its question until another reply ends: no answer yet, and
    /// none failed.
    Queued,
}

impl Outcome {
    /// From `turn.finished`'s `ok` and `queued`.
    pub fn of(ok: bool, queued: bool) -> Self {
        if queued {
            Self::Queued
        } else if ok {
            Self::Answered
        } else {
            Self::Failed
        }
    }
}

/// Which notification a `turn.finished` would get. A queued answer gets
/// none: nothing is ready until it goes out, and its own turn ends then.
/// Whether it goes out, and how, is the core's decision.
pub fn kind_for(outcome: Outcome) -> Option<NotificationKind> {
    match outcome {
        Outcome::Answered => Some(NotificationKind::Ready),
        Outcome::Failed => Some(NotificationKind::Failed),
        Outcome::Queued => None,
    }
}

/// The longest title a notification carries.
pub const MAX_TITLE: usize = 120;

/// A notification, ready for the system.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Notification {
    /// The request identifier: one per chat, so a newer notification for
    /// the same chat replaces the older one.
    pub id: String,
    pub title: String,
    pub body: String,
    /// A system notification makes the system's sound.
    pub sound: bool,
}

/// The words a notification uses (localized by the caller).
pub struct Words<'a> {
    /// A chat without a title yet ("New conversation").
    pub untitled: &'a str,
    /// The neutral line under a ready answer ("Answer ready").
    pub ready: &'a str,
    /// The title of a failed turn ("The answer didn't finish").
    pub failed: &'a str,
}

/// The notification for `chat_id`, titled `chat_title`. Only the title and
/// a fixed line: no message content.
pub fn notification(
    kind: NotificationKind,
    chat_id: &str,
    chat_title: Option<&str>,
    words: &Words<'_>,
) -> Notification {
    let title = chat_title
        .map(str::trim)
        .filter(|t| !t.is_empty())
        .unwrap_or(words.untitled);
    let title = truncate(title, MAX_TITLE);
    let (title, body) = match kind {
        NotificationKind::Ready => (title, words.ready.to_string()),
        NotificationKind::Failed => (words.failed.to_string(), title),
    };
    Notification {
        id: identifier(chat_id),
        title,
        body,
        sound: false,
    }
}

fn truncate(s: &str, max: usize) -> String {
    if s.chars().count() <= max {
        return s.to_string();
    }
    let mut out: String = s.chars().take(max - 1).collect();
    out.push('\u{2026}');
    out
}

// ── Channel messages ─────────────────────────────────────────────────────

/// The words a channel notification uses (localized by the caller).
pub struct ChannelWords<'a> {
    /// "{author} in {channel}", for `author` and `channel`.
    pub title_in: &'a dyn Fn(&str, &str) -> String,
    /// "New message".
    pub message: &'a str,
    /// "Mentioned you".
    pub mention: &'a str,
    /// Someone the server did not name.
    pub unknown: &'a str,
}

/// A channel message's notification: who posted where, and whether it
/// mentions the user, never the message. One per channel: a newer one
/// replaces it.
pub fn channel_notification(
    channel_id: &str,
    author: &str,
    channel_title: &str,
    mention: bool,
    words: &ChannelWords<'_>,
) -> Notification {
    let author = Some(author.trim())
        .filter(|a| !a.is_empty())
        .unwrap_or(words.unknown);
    let channel = channel_title.trim();
    // A direct message is named by who wrote it.
    let title = if channel.is_empty() {
        author.to_string()
    } else {
        (words.title_in)(author, channel)
    };
    Notification {
        id: channel_identifier(channel_id),
        title: truncate(&title, MAX_TITLE),
        body: if mention {
            words.mention
        } else {
            words.message
        }
        .to_string(),
        sound: false,
    }
}

const CHANNEL_PREFIX: &str = "channel:";

/// The request identifier for a channel's notification.
pub fn channel_identifier(channel_id: &str) -> String {
    format!("{CHANNEL_PREFIX}{channel_id}")
}

/// The channel a clicked notification opens.
pub fn channel_for(identifier: &str) -> Option<String> {
    identifier
        .strip_prefix(CHANNEL_PREFIX)
        .filter(|id| valid_id(id))
        .map(str::to_string)
}

const PREFIX: &str = "chat:";

/// The request identifier for a chat's notification.
pub fn identifier(chat_id: &str) -> String {
    format!("{PREFIX}{chat_id}")
}

/// The chat a clicked notification opens; `None` for identifiers this app
/// did not write (they are as untrusted as a link).
pub fn chat_for(identifier: &str) -> Option<String> {
    identifier
        .strip_prefix(PREFIX)
        .filter(|id| valid_id(id))
        .map(str::to_string)
}

#[cfg(test)]
mod tests {
    use super::*;

    const WORDS: Words<'static> = Words {
        untitled: "New conversation",
        ready: "Answer ready",
        failed: "The answer didn't finish",
    };

    fn screen(main_key: bool, main: Option<&str>, qa_key: bool, qa: Option<&str>) -> OnScreen {
        OnScreen {
            app_active: main_key || qa_key,
            main_key,
            main_chat: main.map(String::from),
            quick_ask_key: qa_key,
            quick_ask_chat: qa.map(String::from),
            main_channel: None,
        }
    }

    #[test]
    fn a_channel_is_on_screen_only_in_the_key_main_window() {
        let mut on_screen = screen(true, None, false, None);
        on_screen.main_channel = Some("c1".into());
        assert!(on_screen.shows_channel("c1"));
        assert!(!on_screen.shows_channel("c2"));
        on_screen.main_key = false;
        assert!(!on_screen.shows_channel("c1"));
        let title_in = |a: &str, c: &str| format!("{a} in {c}");
        let words = ChannelWords {
            title_in: &title_in,
            message: "New message",
            mention: "Mentioned you",
            unknown: "Unknown",
        };
        let n = channel_notification("c1", "Juniper", "garden-club", false, &words);
        assert_eq!(n.title, "Juniper in garden-club");
        assert_eq!(n.body, "New message");
        assert_eq!(channel_for(&n.id), Some("c1".into()));
        let dm = channel_notification("d1", "", "", true, &words);
        assert_eq!(
            (dm.title.as_str(), dm.body.as_str()),
            ("Unknown", "Mentioned you")
        );
        assert_eq!(channel_for("chat:c1"), None);
        assert_eq!(chat_for(&n.id), None);
    }

    #[test]
    fn a_chat_is_on_screen_in_the_key_window_that_shows_it() {
        // The chat in the key main window.
        assert!(screen(true, Some("c1"), false, None).shows("c1"));
        // Another chat, or the main window not key.
        assert!(!screen(true, Some("c2"), false, None).shows("c1"));
        assert!(!screen(false, Some("c1"), false, None).shows("c1"));
        // A new chat on screen (nothing stored selected).
        assert!(!screen(true, None, false, None).shows("c1"));
        // Quick Ask in front with that chat; hidden, it is not.
        assert!(screen(false, None, true, Some("q1")).shows("q1"));
        assert!(!screen(false, Some("c1"), true, Some("q1")).shows("c1"));
        assert!(!screen(false, None, false, Some("q1")).shows("q1"));
    }

    #[test]
    fn a_finished_turn_notifies_unless_its_answer_waits_in_the_outbox() {
        // The daemon hands a queued answer off with `ok` and `queued`.
        assert_eq!(Outcome::of(true, true), Outcome::Queued);
        assert_eq!(Outcome::of(true, false), Outcome::Answered);
        assert_eq!(Outcome::of(false, false), Outcome::Failed);
        assert_eq!(kind_for(Outcome::Queued), None);
        assert_eq!(kind_for(Outcome::Answered), Some(NotificationKind::Ready));
        assert_eq!(kind_for(Outcome::Failed), Some(NotificationKind::Failed));
    }

    #[test]
    fn says_the_title_and_a_neutral_line_never_the_answer() {
        let n = notification(
            NotificationKind::Ready,
            "c1",
            Some("Trip to Lisbon"),
            &WORDS,
        );
        assert_eq!(n.title, "Trip to Lisbon");
        assert_eq!(n.body, "Answer ready");
        assert_eq!(n.id, "chat:c1");

        let f = notification(
            NotificationKind::Failed,
            "c1",
            Some("Trip to Lisbon"),
            &WORDS,
        );
        assert_eq!(f.title, "The answer didn't finish");
        assert_eq!(f.body, "Trip to Lisbon");

        let untitled = notification(NotificationKind::Ready, "c2", Some("  "), &WORDS);
        assert_eq!(untitled.title, "New conversation");
        let none = notification(NotificationKind::Ready, "c2", None, &WORDS);
        assert_eq!(none.title, "New conversation");

        let long = "x".repeat(MAX_TITLE + 30);
        let cut = notification(NotificationKind::Ready, "c3", Some(&long), &WORDS);
        assert_eq!(cut.title.chars().count(), MAX_TITLE);
        assert!(cut.title.ends_with('\u{2026}'));
    }

    #[test]
    fn a_click_opens_only_the_chats_this_app_named() {
        assert_eq!(chat_for(&identifier("c1")), Some("c1".into()));
        assert_eq!(chat_for("chat:local:abc"), Some("local:abc".into()));
        assert_eq!(chat_for("chat:../x"), None);
        assert_eq!(chat_for("other:c1"), None);
        assert_eq!(chat_for("chat:"), None);
    }
}
