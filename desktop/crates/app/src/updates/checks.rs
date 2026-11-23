//! The Windows and Linux updaters' "Check for Updates Automatically" (on
//! by default, as the Mac's), and when the Linux notice last read its feed
//! and what newer release it found, kept in `update-checks.json` under
//! userData. WinSparkle keeps its own last check; the app sets its "check
//! automatically" from this switch at each launch, so WinSparkle never asks
//! the user itself.

#[cfg(not(target_os = "macos"))]
use std::path::{Path, PathBuf};
#[cfg(any(target_os = "linux", test))]
use std::time::Duration;

use serde::{Deserialize, Serialize};

use super::Found;
#[cfg(any(target_os = "linux", test))]
use super::config::{CHECK_INTERVAL_SECS, build_number};

/// After a check that failed (no network, a feed refused), the next try:
/// an hour later, or the next daily check if that comes later.
#[cfg(any(target_os = "linux", test))]
pub const RETRY_SECS: i64 = 3_600;

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Checks {
    pub automatic: bool,
    /// When a check last read the feed (Unix seconds).
    pub last_check: Option<i64>,
    /// The newer release that check found (Linux): offered again after a
    /// restart, until a check finds none.
    pub found: Option<Found>,
}

impl Default for Checks {
    fn default() -> Self {
        Self {
            automatic: true,
            last_check: None,
            found: None,
        }
    }
}

#[cfg(not(target_os = "macos"))]
impl Checks {
    pub fn path(user_data: &Path) -> PathBuf {
        user_data.join("update-checks.json")
    }
}

/// How long until the next automatic check at `now`: zero when one is due,
/// `None` while automatic checks are off. A last check dated after `now`
/// (the clock was set back) makes one due.
#[cfg(any(target_os = "linux", test))]
pub fn next_check(checks: &Checks, last_failure: Option<i64>, now: i64) -> Option<Duration> {
    if !checks.automatic {
        return None;
    }
    let mut due = match checks.last_check {
        Some(last) if last <= now => last.saturating_add(CHECK_INTERVAL_SECS),
        _ => now,
    };
    if let Some(failed) = last_failure.filter(|&f| f <= now) {
        due = due.max(failed.saturating_add(RETRY_SECS));
    }
    Some(Duration::from_secs(due.saturating_sub(now).max(0) as u64))
}

/// The release the last check found, while it is still newer than the
/// app's `build` (the user may have installed it since) and its page is
/// https. The file is the user's to change, so it's checked again.
#[cfg(any(target_os = "linux", test))]
pub fn found_for(checks: &Checks, build: u64) -> Option<Found> {
    checks
        .found
        .clone()
        .filter(|f| build_number(&f.version).is_some_and(|b| b > build))
        .filter(|f| f.page.starts_with("https://"))
}

#[cfg(test)]
mod tests {
    use super::*;

    const NOW: i64 = 1_800_000_000;
    const HOUR: u64 = 3_600;

    fn checks(automatic: bool, last_check: Option<i64>) -> Checks {
        Checks {
            automatic,
            last_check,
            found: None,
        }
    }

    fn found(version: &str, page: &str) -> Checks {
        Checks {
            found: Some(Found {
                version: version.into(),
                page: page.into(),
            }),
            ..Checks::default()
        }
    }

    #[test]
    fn automatic_checks_are_on_until_the_user_turns_them_off() {
        assert!(Checks::default().automatic);
        let read: Checks = serde_json::from_str("{}").unwrap();
        assert_eq!(read, Checks::default());
        assert_eq!(next_check(&checks(false, None), None, NOW), None);
    }

    #[test]
    fn the_first_check_is_due_at_once() {
        assert_eq!(
            next_check(&Checks::default(), None, NOW),
            Some(Duration::ZERO)
        );
    }

    #[test]
    fn a_check_is_due_a_day_after_the_last() {
        let two_hours_ago = checks(true, Some(NOW - 2 * HOUR as i64));
        assert_eq!(
            next_check(&two_hours_ago, None, NOW),
            Some(Duration::from_secs(22 * HOUR))
        );
        let a_day_ago = checks(true, Some(NOW - 24 * HOUR as i64));
        assert_eq!(next_check(&a_day_ago, None, NOW), Some(Duration::ZERO));
        let a_week_ago = checks(true, Some(NOW - 7 * 24 * HOUR as i64));
        assert_eq!(next_check(&a_week_ago, None, NOW), Some(Duration::ZERO));
    }

    #[test]
    fn a_last_check_in_the_future_makes_one_due() {
        let ahead = checks(true, Some(NOW + 5 * HOUR as i64));
        assert_eq!(next_check(&ahead, None, NOW), Some(Duration::ZERO));
    }

    #[test]
    fn a_failed_check_is_tried_again_an_hour_later() {
        let ten_minutes_ago = NOW - 600;
        assert_eq!(
            next_check(&checks(true, None), Some(ten_minutes_ago), NOW),
            Some(Duration::from_secs(HOUR - 600))
        );
        // A daily check due later than the retry waits for its own time.
        let recent = checks(true, Some(NOW - HOUR as i64));
        assert_eq!(
            next_check(&recent, Some(ten_minutes_ago), NOW),
            Some(Duration::from_secs(23 * HOUR))
        );
    }

    #[test]
    fn a_release_found_before_is_offered_again_until_the_app_has_it() {
        let page = "https://example.org/releases/tag/desktop-v1.3.0";
        let kept = found("1.3.0", page);
        assert_eq!(found_for(&kept, 1_020_099), kept.found.clone());
        // Installed since (or a newer one): nothing to offer.
        assert_eq!(found_for(&kept, 1_030_099), None);
        assert_eq!(found_for(&kept, 1_040_099), None);
        // What a check would never have kept.
        assert_eq!(found_for(&found("1.3", page), 99), None);
        assert_eq!(found_for(&found("1.3.0", "javascript:alert(1)"), 99), None);
        assert_eq!(found_for(&Checks::default(), 99), None);
    }

    #[test]
    fn the_file_keeps_what_was_found() {
        let kept = found("1.3.0", "https://example.org/releases/tag/desktop-v1.3.0");
        let json = serde_json::to_string(&kept).unwrap();
        assert_eq!(serde_json::from_str::<Checks>(&json).unwrap(), kept);
    }
}
