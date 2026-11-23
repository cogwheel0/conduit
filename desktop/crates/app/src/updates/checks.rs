//! The Windows and Linux updaters' "Check for Updates Automatically" (on
//! by default, as the Mac's) and when the Linux notice last read its feed,
//! kept in `update-checks.json` under userData. WinSparkle keeps its own
//! last check; the app sets its "check automatically" from this switch at
//! each launch, so WinSparkle never asks the user itself.

#[cfg(not(target_os = "macos"))]
use std::path::{Path, PathBuf};
#[cfg(any(target_os = "linux", test))]
use std::time::Duration;

use serde::{Deserialize, Serialize};

#[cfg(any(target_os = "linux", test))]
use super::config::CHECK_INTERVAL_SECS;

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
}

impl Default for Checks {
    fn default() -> Self {
        Self {
            automatic: true,
            last_check: None,
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

#[cfg(test)]
mod tests {
    use super::*;

    const NOW: i64 = 1_800_000_000;
    const HOUR: u64 = 3_600;

    fn checks(automatic: bool, last_check: Option<i64>) -> Checks {
        Checks {
            automatic,
            last_check,
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
}
