//! VoiceOver gate for the sidebar and the ⌘K palette: runs the app's
//! `--fixture a11y` (a real window over canned chats, no daemon), which
//! reads the AccessKit tree GPUI hands to AppKit. Every control must carry
//! a role and a label, and the controls a VoiceOver user needs must be
//! there: rows, hover actions, selection checkboxes, the palette's field
//! and options.
//!
//! Needs a logged-in macOS session (it opens a window). Set
//! `CONDUIT_SKIP_UI_TESTS=1` to skip on a headless machine.

#![cfg(target_os = "macos")]

use std::collections::BTreeMap;
use std::process::Command;

fn screens() -> BTreeMap<String, Vec<String>> {
    let out = Command::new(env!("CARGO_BIN_EXE_conduit-desktop"))
        .args(["--fixture", "a11y"])
        .output()
        .expect("run conduit-desktop --fixture a11y");
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
fn the_sidebar_and_palette_are_voiceover_operable() {
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

    // The sidebar: search, header and footer controls, folders and rows.
    for (role, label) in [
        ("TextInput", "Search chats"),
        ("Button", "New Chat"),
        ("Button", "Hide Sidebar"),
        ("Button", "Settings"),
        ("Button", "Sync Now"),
        ("Button", "Avery Example"),
        ("TreeItem", "Garden"),
        ("TreeItem", "Sourdough starter schedule"),
    ] {
        missing("sidebar", role, label);
    }

    // The rows are an outline's: every section title is a heading that
    // says whether its section is open (dates too), and folders say
    // whether they are.
    let sidebar = &s["sidebar"];
    let open_or_closed = |c: &String| c.contains("expanded") || c.contains("collapsed");
    let headings: Vec<&String> = sidebar
        .iter()
        .filter(|c| c.starts_with("Heading:"))
        .collect();
    assert!(headings.len() >= 3, "section headings: {sidebar:#?}");
    assert!(
        headings.iter().all(|h| open_or_closed(h)),
        "every section heading can close: {headings:#?}"
    );
    assert!(
        sidebar
            .iter()
            .any(|c| c.starts_with("TreeItem:Garden") && open_or_closed(c)),
        "folders say whether they are open: {sidebar:#?}"
    );

    // ↓ into the list selects a folder without opening it, and VoiceOver
    // hears that row (not "List Chats").
    let keys = &s["sidebar-keys"];
    let current: Vec<&String> = keys
        .iter()
        .filter(|c| c.starts_with("TreeItem:") && c.contains("selected"))
        .collect();
    assert_eq!(current.len(), 1, "one selection: {keys:#?}");
    assert!(
        current[0].contains("focused") && open_or_closed(current[0]),
        "the selection is a focused folder: {current:?}"
    );

    // A hovered row shows "…" alone (its commands are in that menu), named
    // for the chat it acts on.
    let hovered = &s["sidebar-hover"];
    assert!(
        hovered
            .iter()
            .any(|c| c.starts_with("Button:More Actions for \u{201c}")),
        "no More action in {hovered:#?}"
    );
    for verb in ["Pin", "Unpin", "Rename", "Archive", "Delete"] {
        assert!(
            !hovered
                .iter()
                .any(|c| c.starts_with(&format!("Button:{verb} \u{201c}"))),
            "a {verb} button on the hovered row in {hovered:#?}"
        );
    }

    // Selection mode: rows become labelled checkboxes, with the bar's
    // actions.
    let select = &s["sidebar-select"];
    assert!(
        select
            .iter()
            .filter(|c| c.starts_with("CheckBox:Select "))
            .count()
            >= 5
    );
    for label in ["Archive", "Move to\u{2026}", "Delete\u{2026}", "Done"] {
        missing("sidebar-select", "Button", label);
    }

    // The palette: its field, six recent chats and the five commands.
    missing("palette", "TextInput", "Search chats and commands");
    let options = s["palette"]
        .iter()
        .filter(|c| c.starts_with("ListBoxOption:"))
        .count();
    assert_eq!(options, 6 + 5, "{:#?}", s["palette"]);
    for label in [
        "New Chat",
        "New Temporary Chat",
        "Choose a Model",
        "Settings",
        "Keyboard Shortcuts",
    ] {
        missing("palette", "ListBoxOption", label);
    }

    // A query lists the matching chats.
    missing(
        "palette-search",
        "ListBoxOption",
        "Orbital period of a moon",
    );
}
