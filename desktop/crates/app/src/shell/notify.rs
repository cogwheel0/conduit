//! Answer notifications: when one goes out, and what it says.
//!
//! On `turn.finished` (unscoped, so it arrives for chats that are not open),
//! the app notifies unless the chat is on screen in a window that has the
//! user's attention: the main window is key and shows that chat, or the
//! Quick Ask window is key and shows it. Failed turns notify too, with an
//! error title.
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
}

/// How a turn ended, as `turn.finished` says.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Outcome {
    /// With an answer (a stopped one counts).
    Answered,
    /// It failed.
    Failed,
    /// Its request waits in the outbox (sent while offline): no answer
    /// yet, and none failed.
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

/// The notification a `turn.finished` gets, if any. `enabled` is the
/// "Notify when an answer finishes" setting. A queued answer gets none:
/// nothing is ready until it goes out, and its own turn ends then.
pub fn decide(
    enabled: bool,
    chat_id: &str,
    outcome: Outcome,
    on_screen: &OnScreen,
) -> Option<NotificationKind> {
    if !enabled || on_screen.shows(chat_id) {
        return None;
    }
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

/// Whether someone else's message in `channel_id` notifies: the setting is
/// on, the daemon says it alerts (the channel notifies for every message,
/// or it mentions the user), and the channel is not in front of the user.
pub fn decide_channel(enabled: bool, alert: bool, channel_id: &str, on_screen: &OnScreen) -> bool {
    enabled
        && alert
        && !(on_screen.main_key && on_screen.main_channel.as_deref() == Some(channel_id))
}

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
            main_key,
            main_chat: main.map(String::from),
            quick_ask_key: qa_key,
            quick_ask_chat: qa.map(String::from),
            main_channel: None,
        }
    }

    #[test]
    fn a_channel_message_notifies_unless_its_channel_is_in_front() {
        let mut on_screen = screen(true, None, false, None);
        on_screen.main_channel = Some("c1".into());
        assert!(!decide_channel(true, true, "c1", &on_screen));
        assert!(decide_channel(true, true, "c2", &on_screen));
        // Not alerting (mentions only, no mention), or switched off.
        assert!(!decide_channel(true, false, "c2", &on_screen));
        assert!(!decide_channel(false, true, "c2", &on_screen));
        // The window not key: the channel is not in front.
        on_screen.main_key = false;
        assert!(decide_channel(true, true, "c1", &on_screen));
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
    fn notifies_unless_the_chat_is_in_front_of_the_user() {
        use NotificationKind::*;
        // The chat is on screen in the key main window: nothing.
        assert_eq!(
            decide(
                true,
                "c1",
                Outcome::Answered,
                &screen(true, Some("c1"), false, None)
            ),
            None
        );
        // Another chat on screen, or the main window not key: a notification.
        assert_eq!(
            decide(
                true,
                "c1",
                Outcome::Answered,
                &screen(true, Some("c2"), false, None)
            ),
            Some(Ready)
        );
        assert_eq!(
            decide(
                true,
                "c1",
                Outcome::Answered,
                &screen(false, Some("c1"), false, None)
            ),
            Some(Ready)
        );
        // A new chat on screen (nothing stored selected).
        assert_eq!(
            decide(
                true,
                "c1",
                Outcome::Answered,
                &screen(true, None, false, None)
            ),
            Some(Ready)
        );
        // Quick Ask in front with that chat: nothing; with another: notify.
        assert_eq!(
            decide(
                true,
                "q1",
                Outcome::Answered,
                &screen(false, None, true, Some("q1"))
            ),
            None
        );
        assert_eq!(
            decide(
                true,
                "c1",
                Outcome::Answered,
                &screen(false, Some("c1"), true, Some("q1"))
            ),
            Some(Ready)
        );
        // Quick Ask hidden (not key) with its chat: notify.
        assert_eq!(
            decide(
                true,
                "q1",
                Outcome::Answered,
                &screen(false, None, false, Some("q1"))
            ),
            Some(Ready)
        );
        // Failed turns notify too.
        assert_eq!(
            decide(true, "c1", Outcome::Failed, &OnScreen::default()),
            Some(Failed)
        );
        // The setting off: never.
        assert_eq!(
            decide(false, "c1", Outcome::Answered, &OnScreen::default()),
            None
        );
        assert_eq!(
            decide(false, "c1", Outcome::Failed, &OnScreen::default()),
            None
        );
    }

    #[test]
    fn a_queued_answer_is_not_ready_and_gets_no_notification() {
        // The daemon hands a queued answer off with `ok` and `queued`.
        assert_eq!(Outcome::of(true, true), Outcome::Queued);
        assert_eq!(Outcome::of(true, false), Outcome::Answered);
        assert_eq!(Outcome::of(false, false), Outcome::Failed);
        assert_eq!(
            decide(true, "c1", Outcome::Queued, &OnScreen::default()),
            None
        );
        // When it goes out and ends, its own turn says Answer Ready.
        assert_eq!(
            decide(true, "c1", Outcome::Answered, &OnScreen::default()),
            Some(NotificationKind::Ready)
        );
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
