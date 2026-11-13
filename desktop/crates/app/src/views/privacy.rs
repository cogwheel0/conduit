//! Synthetic names for screenshots.
//!
//! The `--shots` pass runs against real servers and accounts, and its
//! screenshots must not show them (AGENTS.md). With [`Redact`] on, the
//! views draw account names, emails and server hosts as stable synthetic
//! stand-ins; nothing else changes. Off in normal use.

use std::collections::hash_map::DefaultHasher;
use std::hash::{Hash, Hasher};

use gpui_kit::{App, Global};

#[derive(Clone, Copy, Debug, Default)]
pub struct Redact(pub bool);

impl Global for Redact {}

const NAMES: [&str; 4] = [
    "Avery Example",
    "Blake Sample",
    "Casey Demo",
    "Drew Placeholder",
];
const EMAILS: [&str; 4] = [
    "avery@example.org",
    "blake@example.org",
    "casey@example.net",
    "drew@example.net",
];
const HOSTS: [&str; 4] = [
    "chat.example.org",
    "lab.example.net",
    "ai.example.com",
    "owui.example.org",
];

fn on(cx: &App) -> bool {
    cx.try_global::<Redact>().is_some_and(|r| r.0)
}

fn pick(value: &str, from: &[&str; 4]) -> String {
    let mut h = DefaultHasher::new();
    value.hash(&mut h);
    from[(h.finish() % 4) as usize].to_string()
}

pub fn name(value: &str, cx: &App) -> String {
    if on(cx) && !value.is_empty() {
        pick(value, &NAMES)
    } else {
        value.to_string()
    }
}

pub fn email(value: &str, cx: &App) -> String {
    if on(cx) && !value.is_empty() {
        pick(value, &EMAILS)
    } else {
        value.to_string()
    }
}

/// `notice` with its account names masked (toasts in `--shots`).
pub fn notice(
    notice: &crate::stores::accounts::AccountNotice,
    cx: &App,
) -> crate::stores::accounts::AccountNotice {
    use crate::stores::accounts::AccountNotice as N;
    if !on(cx) {
        return notice.clone();
    }
    let n = |v: &String| name(v, cx);
    match notice {
        N::SwitchedTo { name } => N::SwitchedTo { name: n(name) },
        N::SwitchedNeedsSignIn { name } => N::SwitchedNeedsSignIn { name: n(name) },
        N::AlreadyActive { name } => N::AlreadyActive { name: n(name) },
        N::SignedOut { name, next } => N::SignedOut {
            name: n(name),
            next: next.as_ref().map(n),
        },
        N::SignedOutNextNeedsSignIn { name, next } => N::SignedOutNextNeedsSignIn {
            name: n(name),
            next: n(next),
        },
        N::AddCancelled { name } => N::AddCancelled {
            name: name.as_ref().map(n),
        },
        other => other.clone(),
    }
}

pub fn host(value: &str, cx: &App) -> String {
    if on(cx) && !value.is_empty() {
        pick(value, &HOSTS)
    } else {
        value.to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stand_ins_are_stable_and_synthetic() {
        assert_eq!(pick("real person", &NAMES), pick("real person", &NAMES));
        assert!(NAMES.contains(&pick("x", &NAMES).as_str()));
        assert!(HOSTS.iter().all(|h| h.contains("example")));
        assert!(EMAILS.iter().all(|h| h.contains("@example.")));
    }
}
