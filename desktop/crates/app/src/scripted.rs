//! Whether this launch is a scripted one: an E2E or smoke pass
//! (`--shots`, `--e2e`), the capture harness (`--capture`), a probe or a
//! fixture. A scripted run never asks macOS for a permission: the system's
//! prompt (microphone, speech recognition, notifications) would wait on
//! screen for someone to answer it, for an app no one is using. A
//! permission the system has not asked about yet counts as not given; the
//! passes use stand-ins (a WAV for the microphone, a server for speech) or
//! skip what needs the real thing.

use std::sync::atomic::{AtomicBool, Ordering};

static SCRIPTED: AtomicBool = AtomicBool::new(false);

/// The smoke pass's flags, in every build.
const PASS_FLAGS: [&str; 2] = ["--shots", "--smoke-reset"];

/// The test harness's flag in `args`, if any: an E2E pass (`--e2e`,
/// `--e2e-env`), the capture (`--capture…`), a probe, or a fixture
/// (`--fixture`, `--chat-fixture` and the rest). Builds without the
/// `harness` feature refuse them.
pub fn harness_flag(args: &[String]) -> Option<&str> {
    args.iter().map(String::as_str).find(|a| {
        a.starts_with("--e2e")
            || a.starts_with("--capture")
            || *a == "--probe"
            || (a.starts_with("--") && a.ends_with("fixture"))
    })
}

/// Whether `args` make a scripted launch.
pub fn requested(args: &[String]) -> bool {
    args.iter().any(|a| PASS_FLAGS.contains(&a.as_str())) || harness_flag(args).is_some()
}

/// Marks this launch scripted (at start, from its arguments).
pub fn set(on: bool) {
    SCRIPTED.store(on, Ordering::Relaxed);
}

/// Whether this launch is scripted: never ask for a permission.
pub fn active() -> bool {
    SCRIPTED.load(Ordering::Relaxed)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn passes_and_fixtures_are_scripted_and_a_plain_launch_is_not() {
        let args = |a: &[&str]| a.iter().map(|s| s.to_string()).collect::<Vec<_>>();
        assert!(requested(&args(&[
            "app", "--shots", "/tmp/s", "--e2e", "chat"
        ])));
        assert!(requested(&args(&["app", "--capture", "/tmp/c"])));
        assert!(requested(&args(&["app", "--fixture", "web-media"])));
        assert!(requested(&args(&["app", "--tasks-fixture", "perf"])));
        assert!(!requested(&args(&["app"])));
        assert!(!requested(&args(&["app", "--hidden", "--cwd", "/x"])));
    }

    #[test]
    fn harness_flags_are_told_apart_from_the_apps_own() {
        let args = |a: &[&str]| a.iter().map(|s| s.to_string()).collect::<Vec<_>>();
        for flag in [
            "--e2e",
            "--e2e-env",
            "--capture",
            "--capture-only",
            "--probe",
            "--fixture",
            "--chat-fixture",
            "--tasks-fixture",
        ] {
            assert_eq!(harness_flag(&args(&["app", flag, "x"])), Some(flag));
        }
        for flag in [
            "--shots",
            "--smoke-reset",
            "--hidden",
            "--cwd",
            "--preview-route",
        ] {
            assert_eq!(harness_flag(&args(&["app", flag, "x"])), None, "{flag}");
        }
        // A value that ends like one is not a flag.
        assert_eq!(harness_flag(&args(&["app", "--cwd", "/tmp/fixture"])), None);
    }
}
