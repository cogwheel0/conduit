//! VoiceOver gate for the chat view: opens the transcript and the
//! composer over a fixture daemon (`--chat-fixture a11y`), activates
//! accessibility and reads GPUI's AccessKit tree. Every message must be a
//! labelled article carrying its text, and the composer's field, the model
//! picker, Send and the answer actions must be labelled controls.
//!
//! Needs a logged-in macOS session (it opens a window). Set
//! `CONDUIT_SKIP_UI_TESTS=1` to skip on a headless machine.

#![cfg(target_os = "macos")]

use std::process::Command;

use serde_json::Value;

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
fn messages_are_labelled_articles_and_the_composer_is_operable() {
    if std::env::var_os("CONDUIT_SKIP_UI_TESTS").is_some() {
        eprintln!("skipped: CONDUIT_SKIP_UI_TESTS is set");
        return;
    }
    // A throwaway profile: the fixture never starts conduitd, but the app
    // still reads its preferences and writes its log.
    let profile = std::path::Path::new(env!("CARGO_TARGET_TMPDIR")).join("chat-a11y");
    let out = Command::new(env!("CARGO_BIN_EXE_conduit-desktop"))
        .args(["--chat-fixture", "a11y"])
        .env("CONDUIT_USER_DATA", profile.join("user-data"))
        .env("CONDUIT_LOGS", profile.join("logs"))
        .output()
        .expect("run conduit-desktop");
    let stdout = String::from_utf8_lossy(&out.stdout);
    let line = stdout
        .lines()
        .rev()
        .find(|l| l.starts_with('{'))
        .unwrap_or_else(|| panic!("no JSON report\nstdout: {stdout}"));
    let report: Value = serde_json::from_str(line).unwrap();

    let articles: Vec<&str> = report["articles"]
        .as_array()
        .unwrap()
        .iter()
        .filter_map(Value::as_str)
        .collect();
    assert!(articles.len() >= 3, "{articles:?}");
    assert!(
        articles.iter().any(|a| a.starts_with("You: Question 9998")),
        "the user's messages read with their text: {articles:?}"
    );
    assert!(
        articles
            .iter()
            .any(|a| a.starts_with("Fixture model: Paragraph 9999")),
        "the answers read with their text: {articles:?}"
    );
    assert!(
        articles.iter().any(|a| a.contains("The answer, finished.")),
        "the live answer reads too: {articles:?}"
    );
    assert!(
        articles.iter().all(|a| !a.trim().is_empty()),
        "every article is labelled"
    );

    assert_eq!(labels(&report, "MultilineTextInput"), vec!["Message"]);
    let buttons = labels(&report, "Button");
    for expected in [
        "Model: Fixture model",
        "Send",
        "Attach Files",
        "Copy",
        "Regenerate",
        "More",
    ] {
        assert!(
            buttons.iter().any(|b| b == expected),
            "missing button {expected}: {buttons:?}"
        );
    }
    let unlabelled: Vec<_> = report["controls"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|c| {
            matches!(
                c["role"].as_str(),
                Some("Button" | "Switch" | "Link" | "MultilineTextInput" | "TextInput")
            ) && c["label"].as_str().unwrap_or_default().trim().is_empty()
        })
        .collect();
    assert!(unlabelled.is_empty(), "unlabelled controls: {unlabelled:?}");

    // The model picker exposes its highlighted model as the selected
    // option, as the ⌘K palette does, and ↓ wraps from the last to the
    // first. The model in use is the checked one throughout.
    let steps = report["picker"].as_array().expect("picker steps");
    assert_eq!(steps.len(), 3, "{steps:?}");
    let selected = |step: &Value| -> Vec<String> {
        step.as_array()
            .unwrap()
            .iter()
            .filter(|o| o["selected"] == Value::Bool(true))
            .map(|o| o["label"].as_str().unwrap_or_default().to_string())
            .collect()
    };
    let first = selected(&steps[0]);
    let second = selected(&steps[1]);
    let wrapped = selected(&steps[2]);
    assert_eq!(first.len(), 1, "one highlighted option: {steps:?}");
    assert_eq!(second.len(), 1, "{steps:?}");
    assert_ne!(first, second, "↓ moves the highlight: {steps:?}");
    assert_eq!(
        wrapped, first,
        "↓ on the last wraps to the first: {steps:?}"
    );
    for step in steps {
        let checked: Vec<_> = step
            .as_array()
            .unwrap()
            .iter()
            .filter(|o| o["toggled"].as_str() == Some("True"))
            .map(|o| o["label"].as_str().unwrap_or_default())
            .collect();
        // Moving the highlight never moves the check.
        assert_eq!(
            checked,
            vec!["Fixture model"],
            "the model in use is checked: {step:?}"
        );
    }
}
