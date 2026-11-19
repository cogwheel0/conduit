//! VoiceOver gate for the Mac extras' windows: runs the app's `--fixture shell` (real
//! windows over a canned daemon, no hotkey, menu-bar item or login item),
//! which reads the AccessKit tree GPUI hands to AppKit for Settings ›
//! Desktop and the Quick Ask window. Every control must carry a label, and
//! the ones a VoiceOver user needs must be there.
//!
//! Needs a logged-in macOS session (it opens windows). Set
//! `CONDUIT_SKIP_UI_TESTS=1` to skip on a headless machine.

#![cfg(target_os = "macos")]

use std::collections::BTreeMap;
use std::process::Command;

fn screens() -> BTreeMap<String, Vec<String>> {
    let out = Command::new(env!("CARGO_BIN_EXE_conduit-desktop"))
        .args(["--fixture", "shell"])
        .output()
        .expect("run conduit-desktop --fixture shell");
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(
        out.status.success() && stdout.contains("FIXTURE passed") && !stdout.contains("FAILED"),
        "the fixture failed:\n{stdout}\nstderr: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    stdout
        .lines()
        .filter_map(|l| l.strip_prefix("FIXTURE "))
        .filter_map(|l| l.split_once(' '))
        .filter_map(|(name, json)| {
            serde_json::from_str::<Vec<String>>(json)
                .ok()
                .map(|c| (name.to_string(), c))
        })
        .collect()
}

fn has(controls: &[String], role: &str, label: &str) -> bool {
    controls
        .iter()
        .any(|c| c.starts_with(&format!("{role}:")) && c.contains(label))
}

#[test]
fn settings_desktop_and_quick_ask_are_voiceover_operable() {
    if std::env::var_os("CONDUIT_SKIP_UI_TESTS").is_some() {
        eprintln!("skipped: CONDUIT_SKIP_UI_TESTS is set");
        return;
    }
    let s = screens();
    let missing = |screen: &str, role: &str, label: &str| {
        assert!(
            has(&s[screen], role, label),
            "{screen}: no {role} labelled {label:?} in {:#?}",
            s[screen]
        )
    };

    // Settings › Desktop: the three switches and the shortcut's button;
    // notifications have their own tab.
    for label in [
        "Close to the Menu Bar",
        "Open at Login",
        "Open Quick Ask from Anywhere",
    ] {
        missing("settings-desktop", "Switch", label);
    }
    missing("settings-desktop", "Button", "Change");
    missing("settings-desktop", "Tab", "General");
    missing("settings-desktop", "Tab", "Notifications");

    // Quick Ask: its actions and the composer.
    // Nothing typed: the call button stands where Send is, as on the phone.
    for label in ["New Chat", "Open in Conduit", "Close", "Start Voice Call"] {
        missing("quick-ask", "Button", label);
    }
    assert!(
        s["quick-ask"]
            .iter()
            .any(|c| c.starts_with("MultilineTextInput:") || c.starts_with("TextInput:")),
        "no text field in {:#?}",
        s["quick-ask"]
    );
}
