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

/// The app's flags that take a value: the argument after one is that value,
/// never a flag (`--cwd --shots` names a folder called `--shots`).
const VALUE_FLAGS: [&str; 15] = [
    "--cwd",
    "--shots",
    "--e2e",
    "--e2e-env",
    "--capture",
    "--capture-env",
    "--capture-only",
    "--probe",
    "--fixture",
    "--chat-fixture",
    "--channel-fixture",
    "--calendar-fixture",
    "--tasks-fixture",
    "--workspace-fixture",
    "--preview-route",
];

/// The arguments in an option's place, with where each is, past the
/// program's name: a flag's value is skipped, whatever it looks like.
pub fn option_positions(args: &[String]) -> impl Iterator<Item = (usize, &str)> {
    let mut rest = args
        .iter()
        .map(String::as_str)
        .enumerate()
        .skip(1)
        .peekable();
    std::iter::from_fn(move || {
        let (at, arg) = rest.next()?;
        if VALUE_FLAGS.contains(&arg) {
            let value = rest.next().map(|(_, value)| value);
            // `--fixture perf comfortable`: the perf fixture's layout is a
            // second value (`fixture::Mode::from_args`).
            if arg == "--fixture"
                && value == Some("perf")
                && rest.peek().is_some_and(|(_, next)| *next == "comfortable")
            {
                rest.next();
            }
        }
        Some((at, arg))
    })
}

/// The arguments in an option's place ([`option_positions`]).
pub fn options(args: &[String]) -> impl Iterator<Item = &str> {
    option_positions(args).map(|(_, arg)| arg)
}

/// The value after `flag`, where `flag` is in an option's place.
pub fn value(args: &[String], flag: &str) -> Option<String> {
    let (at, _) = option_positions(args).find(|(_, arg)| *arg == flag)?;
    args.get(at + 1).cloned()
}

/// The smoke pass's flags, in every build.
const PASS_FLAGS: [&str; 2] = ["--shots", "--smoke-reset"];

/// The test harness's flag in `args`, if any: an E2E pass (`--e2e`,
/// `--e2e-env`), the capture (`--capture…`), a probe, or a fixture
/// (`--fixture`, `--chat-fixture` and the rest). Builds without the
/// `harness` feature refuse them.
pub fn harness_flag(args: &[String]) -> Option<&str> {
    options(args).find(|a| {
        a.starts_with("--e2e")
            || a.starts_with("--capture")
            || *a == "--probe"
            || (a.starts_with("--") && a.ends_with("fixture"))
    })
}

/// Whether `args` make a scripted launch.
pub fn requested(args: &[String]) -> bool {
    options(args).any(|a| PASS_FLAGS.contains(&a)) || harness_flag(args).is_some()
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

    /// A flag's values are never options: one each, and the perf
    /// fixture's layout after `--fixture perf` too.
    #[test]
    fn a_flags_values_are_not_options() {
        let args = |a: &[&str]| a.iter().map(|s| s.to_string()).collect::<Vec<_>>();
        let options = |a: &[&str]| options(&args(a)).map(String::from).collect::<Vec<_>>();
        assert_eq!(
            options(&["app", "--fixture", "perf", "comfortable", "notes.md"]),
            ["--fixture", "notes.md"]
        );
        assert_eq!(
            options(&["app", "--fixture", "a11y", "comfortable"]),
            ["--fixture", "comfortable"],
            "only perf takes a layout"
        );
        assert_eq!(
            options(&["app", "--cwd", "--shots", "--hidden"]),
            ["--cwd", "--hidden"]
        );
    }

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
