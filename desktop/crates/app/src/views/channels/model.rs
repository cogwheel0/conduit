//! What a channel's timeline lists, as plain data: the rows in order, with
//! their keys, built from the store's messages.
//!
//! * A **day** row heads each day's first message ("Today", "Yesterday",
//!   the weekday, then the date), as Messages and Slack date a log.
//! * Messages from one sender **group** under one name and avatar while
//!   they follow each other within [`GROUP_WINDOW_MS`]; a day, another
//!   sender, a gap or an app's private answer starts a new group (the
//!   phone groups by sender alone; a desktop log is read across longer
//!   gaps).
//! * An app's **private answer** follows its message.
//! * **Older** heads the list while earlier messages are left to load.

use chrono::{Local, NaiveDate, TimeZone};
use conduit_protocol::{ChannelAppReplyEvent, ChannelMessageDto};

/// Within this, a sender's messages share one heading.
pub const GROUP_WINDOW_MS: i64 = 5 * 60 * 1000;

#[derive(Clone, Debug, PartialEq)]
pub enum TimelineRow {
    /// Earlier messages are left to load (or loading).
    Older,
    /// The day of the messages under it.
    Day(NaiveDate),
    Message {
        id: String,
        /// Draws the sender's name and avatar.
        group_start: bool,
    },
    /// An app's answer to the user alone, under message `message_id`.
    AppReply {
        message_id: String,
        app_id: String,
    },
    /// In a thread: the message it hangs off, then a line with how many
    /// replies it has.
    Parent(String),
    RepliesDivider,
    /// Nothing posted yet.
    Empty,
}

impl TimelineRow {
    /// What the list keys the row by: the same row keeps its key as rows
    /// come and go around it.
    pub fn key(&self) -> String {
        match self {
            Self::Older => "older".into(),
            Self::Day(d) => format!("day-{d}"),
            Self::Message { id, .. } => format!("m-{id}"),
            Self::AppReply { message_id, app_id } => format!("r-{message_id}-{app_id}"),
            Self::Parent(id) => format!("p-{id}"),
            Self::RepliesDivider => "replies".into(),
            Self::Empty => "empty".into(),
        }
    }
}

/// The local day of `ms`.
pub fn day_of(ms: i64) -> NaiveDate {
    Local
        .timestamp_millis_opt(ms)
        .earliest()
        .map(|t| t.date_naive())
        .unwrap_or_default()
}

/// A channel's rows: `messages` oldest first, `replies` the app answers on
/// show, `has_older` whether earlier messages are left.
pub fn channel_rows(
    messages: &[ChannelMessageDto],
    replies: &[ChannelAppReplyEvent],
    has_older: bool,
    loaded: bool,
) -> Vec<TimelineRow> {
    let mut rows = Vec::with_capacity(messages.len() + 8);
    if has_older {
        rows.push(TimelineRow::Older);
    }
    if messages.is_empty() {
        if loaded && !has_older {
            rows.push(TimelineRow::Empty);
        }
        return rows;
    }
    push_messages(&mut rows, messages, replies, true);
    rows
}

/// A thread's rows: its parent, how many replies, then the replies.
pub fn thread_rows(
    parent: Option<&ChannelMessageDto>,
    replies: &[ChannelMessageDto],
    app_replies: &[ChannelAppReplyEvent],
    has_older: bool,
) -> Vec<TimelineRow> {
    let mut rows = Vec::with_capacity(replies.len() + 4);
    if let Some(parent) = parent {
        rows.push(TimelineRow::Parent(parent.id.clone()));
        for r in app_replies.iter().filter(|r| r.message_id == parent.id) {
            rows.push(TimelineRow::AppReply {
                message_id: r.message_id.clone(),
                app_id: r.app_id.clone(),
            });
        }
        rows.push(TimelineRow::RepliesDivider);
    }
    if has_older {
        rows.push(TimelineRow::Older);
    }
    push_messages(&mut rows, replies, app_replies, false);
    rows
}

fn push_messages(
    rows: &mut Vec<TimelineRow>,
    messages: &[ChannelMessageDto],
    replies: &[ChannelAppReplyEvent],
    days: bool,
) {
    let mut previous: Option<&ChannelMessageDto> = None;
    let mut previous_day: Option<NaiveDate> = None;
    for message in messages {
        let day = day_of(message.created_at_ms);
        let new_day = previous_day != Some(day);
        if days && new_day {
            rows.push(TimelineRow::Day(day));
        }
        previous_day = Some(day);
        let had_replies = previous.is_some_and(|p| replies.iter().any(|r| r.message_id == p.id));
        let group_start = match previous {
            None => true,
            Some(p) => {
                new_day
                    || had_replies
                    || p.sender_key != message.sender_key
                    || p.sender_key.is_empty()
                    || message.created_at_ms - p.created_at_ms > GROUP_WINDOW_MS
                    // An inline reply shows what it answers: it heads itself.
                    || message.reply_to_id.is_some()
            }
        };
        rows.push(TimelineRow::Message {
            id: message.id.clone(),
            group_start,
        });
        for r in replies.iter().filter(|r| r.message_id == message.id) {
            rows.push(TimelineRow::AppReply {
                message_id: r.message_id.clone(),
                app_id: r.app_id.clone(),
            });
        }
        previous = Some(message);
    }
}

/// How `before` turns into `after` (by key): the rows kept at the start
/// and the end, so only the middle is spliced and the scroll position holds.
pub fn splice_range(before: &[String], after: &[String]) -> (usize, usize) {
    let prefix = before.iter().zip(after).take_while(|(a, b)| a == b).count();
    let max_suffix = before.len().min(after.len()) - prefix;
    let suffix = before
        .iter()
        .rev()
        .zip(after.iter().rev())
        .take(max_suffix)
        .take_while(|(a, b)| a == b)
        .count();
    (prefix, suffix)
}

/// Initials for a monogram avatar: the first letters of the first two
/// words ("Riley Example" → "RE"), or the first letter alone.
pub fn initials(name: &str) -> String {
    let mut words = name.split_whitespace().filter_map(|w| w.chars().next());
    match (words.next(), words.next()) {
        (Some(a), Some(b)) => format!("{}{}", a.to_uppercase(), b.to_uppercase()),
        (Some(a), None) => a.to_uppercase().to_string(),
        _ => "?".into(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn message(id: &str, sender: &str, at: i64) -> ChannelMessageDto {
        serde_json::from_value(serde_json::json!({
            "id": id, "channelId": "c1", "createdAtMs": at, "senderKey": sender,
        }))
        .unwrap()
    }

    fn reply(message_id: &str) -> ChannelAppReplyEvent {
        serde_json::from_value(serde_json::json!({
            "channelId": "c1", "messageId": message_id, "appId": "a1", "reply": {},
        }))
        .unwrap()
    }

    fn starts(rows: &[TimelineRow]) -> Vec<(String, bool)> {
        rows.iter()
            .filter_map(|r| match r {
                TimelineRow::Message { id, group_start } => Some((id.clone(), *group_start)),
                _ => None,
            })
            .collect()
    }

    #[test]
    fn a_senders_run_shares_one_heading_until_a_gap_or_another_sender() {
        let noon = Local.with_ymd_and_hms(2026, 11, 10, 12, 0, 0).unwrap();
        let t = noon.timestamp_millis();
        let messages = vec![
            message("a", "u1", t),
            message("b", "u1", t + 60_000),
            message("c", "u2", t + 120_000),
            message("d", "u2", t + 120_000 + GROUP_WINDOW_MS + 1),
            message("e", "u2", t + 120_000 + GROUP_WINDOW_MS + 2),
        ];
        let rows = channel_rows(&messages, &[reply("d")], true, true);
        assert_eq!(rows[0], TimelineRow::Older);
        assert_eq!(rows[1], TimelineRow::Day(noon.date_naive()));
        assert_eq!(
            starts(&rows),
            [
                ("a".into(), true),
                ("b".into(), false),
                ("c".into(), true),
                ("d".into(), true),
                // After an app's private answer, a new group.
                ("e".into(), true),
            ]
        );
        assert!(rows.iter().any(|r| r.key() == "r-d-a1"));
    }

    #[test]
    fn each_day_gets_its_heading_and_an_empty_channel_says_so() {
        let one = Local.with_ymd_and_hms(2026, 11, 9, 23, 59, 0).unwrap();
        let two = Local.with_ymd_and_hms(2026, 11, 10, 0, 1, 0).unwrap();
        let rows = channel_rows(
            &[
                message("a", "u1", one.timestamp_millis()),
                message("b", "u1", two.timestamp_millis()),
            ],
            &[],
            false,
            true,
        );
        let keys: Vec<String> = rows.iter().map(TimelineRow::key).collect();
        assert_eq!(keys, ["day-2026-11-09", "m-a", "day-2026-11-10", "m-b"]);
        assert_eq!(starts(&rows), [("a".into(), true), ("b".into(), true)]);
        assert_eq!(channel_rows(&[], &[], false, true), [TimelineRow::Empty]);
        assert!(channel_rows(&[], &[], false, false).is_empty());
    }

    #[test]
    fn a_thread_starts_with_its_parent() {
        let t = 1_790_000_000_000;
        let parent = message("p", "u1", t);
        let rows = thread_rows(Some(&parent), &[message("r1", "u2", t + 1)], &[], false);
        let keys: Vec<String> = rows.iter().map(TimelineRow::key).collect();
        assert_eq!(keys, ["p-p", "replies", "m-r1"]);
    }

    #[test]
    fn a_splice_keeps_what_did_not_change_at_either_end() {
        let k = |v: &[&str]| v.iter().map(|s| s.to_string()).collect::<Vec<_>>();
        assert_eq!(
            splice_range(&k(&["a", "b", "c"]), &k(&["a", "b", "c", "d"])),
            (3, 0)
        );
        assert_eq!(
            splice_range(&k(&["older", "a", "b"]), &k(&["older", "z", "a", "b"])),
            (1, 2)
        );
        assert_eq!(splice_range(&k(&["a", "b"]), &k(&["a", "b"])), (2, 0));
        assert_eq!(splice_range(&k(&["a"]), &k(&[])), (0, 0));
        assert_eq!(initials("Riley Example"), "RE");
        assert_eq!(initials("juniper"), "J");
        assert_eq!(initials(""), "?");
    }
}
