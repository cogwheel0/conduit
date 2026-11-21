//! VoiceOver check: opens screens 4, 5 and 8 (the empty chat, a streaming
//! answer and ⌘K) in a real window, activates accessibility, and walks the
//! AccessKit tree
//! GPUI sends to AppKit. Every control needs a role and a non-empty label,
//! and every message must be a labelled Article.
//!
//! Needs a logged-in macOS session (it opens windows). Set
//! `CONDUIT_SKIP_UI_TESTS=1` to skip on a headless machine.
#![cfg(target_os = "macos")]

use std::process::Command;

use serde_json::Value;

fn run(screen: &str) -> Value {
    let out = Command::new(env!("CARGO_BIN_EXE_conduit-gallery"))
        .args(["--a11y", screen])
        .output()
        .expect("run conduit-gallery");
    let stdout = String::from_utf8_lossy(&out.stdout);
    let report: Value = serde_json::from_str(&stdout).unwrap_or_else(|e| {
        panic!(
            "{screen}: no JSON report ({e})\nstdout: {stdout}\nstderr: {}",
            String::from_utf8_lossy(&out.stderr)
        )
    });
    assert!(
        out.status.success(),
        "{screen} failed the AccessKit check:\n{report:#}"
    );
    report
}

fn labels(report: &Value, role: &str) -> Vec<String> {
    report["controls"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|c| c["role"] == role)
        .map(|c| c["label"].as_str().unwrap_or_default().to_string())
        .collect()
}

#[test]
fn screens_4_5_and_8_are_voiceover_operable() {
    if std::env::var_os("CONDUIT_SKIP_UI_TESTS").is_some() {
        eprintln!("skipped: CONDUIT_SKIP_UI_TESTS is set");
        return;
    }

    // 4: empty chat. The composer, send and the sidebar rows are reachable.
    let empty = run("main-empty");
    assert!(empty["failures"].as_array().unwrap().is_empty());
    assert_eq!(labels(&empty, "MultilineTextInput"), vec!["Message"]);
    let buttons = labels(&empty, "Button");
    for expected in ["Send", "New Chat", "Search chats", "Settings"] {
        assert!(
            buttons.iter().any(|b| b == expected),
            "missing button {expected}"
        );
    }
    // The sidebar's chats are rows of its outline.
    assert!(
        labels(&empty, "TreeItem")
            .iter()
            .any(|r| r == "Orbital period of a moon"),
        "missing row Orbital period of a moon"
    );

    // 5: streaming answer. Both messages are labelled articles carrying
    // their text; disclosures, code copy, sources and Stop are controls.
    let streaming = run("main-streaming");
    let articles: Vec<&str> = streaming["articles"]
        .as_array()
        .unwrap()
        .iter()
        .filter_map(Value::as_str)
        .collect();
    // The report lists them in the tree dump's order, not the screen's.
    assert_eq!(articles.len(), 2, "{articles:?}");
    assert!(
        articles
            .iter()
            .any(|a| a.starts_with("You: How long does a moon")),
        "{articles:?}"
    );
    assert!(
        articles
            .iter()
            .any(|a| a.starts_with("Aster 2 Pro (writing): For a small body")),
        "{articles:?}"
    );
    let buttons = labels(&streaming, "Button");
    for expected in ["Stop Generating", "Copy", "Thought for 6 seconds"] {
        assert!(
            buttons.iter().any(|b| b == expected),
            "missing button {expected}"
        );
    }
    assert_eq!(labels(&streaming, "Link").len(), 3, "three source chips");

    // 8: the palette, both states. A labelled query field and one option
    // per result.
    for (screen, results) in [("palette-recent", 9), ("palette-search", 4)] {
        let palette = run(screen);
        assert_eq!(
            labels(&palette, "TextInput"),
            vec!["Search chats and commands"],
            "{screen}"
        );
        assert_eq!(labels(&palette, "ListBoxOption").len(), results, "{screen}");
    }
}
