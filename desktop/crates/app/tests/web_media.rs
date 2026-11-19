//! The web views' media policy (`shell::web_media`): runs the app's
//! `--fixture web-media`, which builds real web views in a real window (an
//! inline embed, a windowed one as Preview and SSO are, one built without
//! the policy's guard, and a call's page) and asks each one's UI delegate,
//! as WebKit does for `getUserMedia`, whether its page may use the
//! microphone or the camera. Only the call page's microphone, at its own
//! origin in its main frame, is granted; nothing is ever captured.
//!
//! Needs a logged-in macOS session (it opens a window). Set
//! `CONDUIT_SKIP_UI_TESTS=1` to skip on a headless machine.

#![cfg(target_os = "macos")]

use std::process::Command;

#[test]
fn only_a_call_page_may_use_the_microphone() {
    if std::env::var_os("CONDUIT_SKIP_UI_TESTS").is_some() {
        eprintln!("skipped: CONDUIT_SKIP_UI_TESTS is set");
        return;
    }
    let out = Command::new(env!("CARGO_BIN_EXE_conduit-desktop"))
        .args(["--fixture", "web-media"])
        .output()
        .expect("run conduit-desktop --fixture web-media");
    let stdout = String::from_utf8_lossy(&out.stdout);
    let answers = stdout
        .lines()
        .find_map(|l| l.strip_prefix("FIXTURE web-media "))
        .and_then(|json| serde_json::from_str::<Vec<serde_json::Value>>(json).ok())
        .unwrap_or_default();
    let failed: Vec<_> = answers.iter().filter(|a| a["pass"] != true).collect();
    assert!(
        out.status.success() && stdout.contains("FIXTURE passed") && failed.is_empty(),
        "the web media fixture failed: {failed:#?}\n{stdout}\nstderr: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    // Every kind of web view was asked, the call page granted once.
    for view in ["inline", "windowed", "unguarded", "call"] {
        assert!(
            answers.iter().any(|a| a["view"] == view),
            "no answer from the {view} web view: {answers:#?}"
        );
    }
    let granted: Vec<_> = answers.iter().filter(|a| a["got"] == 1).collect();
    assert_eq!(granted.len(), 1, "granted: {granted:#?}");
    assert_eq!(granted[0]["view"], "call");
}
