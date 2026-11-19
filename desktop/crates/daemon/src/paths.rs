//! Where Conduit Desktop keeps things, per build flavour.
//!
//! Dev builds never share state with the packaged app: they use
//! `~/Library/Application Support/Conduit Dev`, `~/Library/Logs/Conduit Dev`
//! and their own Keychain service. A rebuilt dev binary would otherwise hit
//! Keychain prompts on the production item, and a developer's own data
//! under `Conduit`.

use std::path::{Path, PathBuf};
use std::time::SystemTime;

/// The packaged app's bundle id, which is also its Keychain service.
pub const BUNDLE_ID: &str = "app.cogwheel.conduit.desktop";

/// Which set of paths and secrets a build uses.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Flavor {
    Dev,
    Production,
}

impl Flavor {
    /// Production only for a release build running from a packaged bundle;
    /// `CONDUIT_FLAVOR=dev|production` overrides.
    pub fn detect() -> Self {
        match std::env::var("CONDUIT_FLAVOR").as_deref() {
            Ok("dev") => return Self::Dev,
            Ok("production") => return Self::Production,
            _ => {}
        }
        let packaged = std::env::current_exe()
            .ok()
            .and_then(|exe| packaged_daemon(&exe))
            .is_some();
        if packaged && !cfg!(debug_assertions) {
            Self::Production
        } else {
            Self::Dev
        }
    }

    /// The folder name under Application Support and Logs.
    pub fn app_name(self) -> &'static str {
        match self {
            Self::Dev => "Conduit Dev",
            Self::Production => "Conduit",
        }
    }

    pub fn keychain_service(self) -> String {
        match self {
            Self::Dev => format!("{BUNDLE_ID}.dev"),
            Self::Production => BUNDLE_ID.to_string(),
        }
    }
}

/// The app's directories.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AppPaths {
    pub flavor: Flavor,
    /// The daemon's `--user-data`, plus the app's own prefs files.
    pub user_data: PathBuf,
    /// Daemon stderr, the app log and crash files.
    pub logs: PathBuf,
}

impl AppPaths {
    /// The standard macOS locations for `flavor`. `CONDUIT_USER_DATA` and
    /// `CONDUIT_LOGS` override them (tests, smoke runs).
    pub fn for_flavor(flavor: Flavor) -> Self {
        let home = std::env::var_os("HOME")
            .map(PathBuf::from)
            .unwrap_or_else(|| PathBuf::from("/tmp"));
        let user_data = std::env::var_os("CONDUIT_USER_DATA")
            .map(PathBuf::from)
            .unwrap_or_else(|| {
                home.join("Library/Application Support")
                    .join(flavor.app_name())
            });
        let logs = std::env::var_os("CONDUIT_LOGS")
            .map(PathBuf::from)
            .unwrap_or_else(|| home.join("Library/Logs").join(flavor.app_name()));
        Self {
            flavor,
            user_data,
            logs,
        }
    }

    pub fn window_state_file(&self) -> PathBuf {
        self.user_data.join("window-state.json")
    }

    pub fn prefs_file(&self) -> PathBuf {
        self.user_data.join("desktop-preferences.json")
    }
}

/// `<bundle>/Contents/Resources/conduitd/bin/conduitd` for an executable at
/// `<bundle>/Contents/MacOS/<exe>`, if it exists.
pub fn packaged_daemon(exe: &Path) -> Option<PathBuf> {
    let contents = exe.parent()?.parent()?;
    let candidate = contents.join("Resources/conduitd/bin/conduitd");
    candidate.is_file().then_some(candidate)
}

/// The `dart build cli` output in this repo.
pub fn dev_daemon() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../../apps/daemon/build/cli/macos_arm64/bundle/bin/conduitd")
}

/// The daemon binary: `CONDUITD_PATH`, else the packaged copy next to the
/// running executable, else the dev build.
pub fn locate_daemon() -> PathBuf {
    if let Some(p) = std::env::var_os("CONDUITD_PATH") {
        return PathBuf::from(p);
    }
    if let Some(p) = std::env::current_exe()
        .ok()
        .and_then(|e| packaged_daemon(&e))
    {
        return p;
    }
    dev_daemon()
}

/// Moves `dir` aside as `<dir> (reset <timestamp>)` and returns the new
/// path. Nothing is deleted: "Reset local data" keeps the old folder for the
/// user (and support) to look at.
pub fn move_aside(dir: &Path, now: SystemTime) -> std::io::Result<PathBuf> {
    let secs = now
        .duration_since(SystemTime::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or_default();
    let stamp = format_utc(secs);
    let name = dir
        .file_name()
        .map(|n| n.to_string_lossy().to_string())
        .unwrap_or_else(|| "userData".into());
    let parent = dir.parent().unwrap_or(Path::new("."));
    let mut target = parent.join(format!("{name} (reset {stamp})"));
    let mut n = 2;
    while target.exists() {
        target = parent.join(format!("{name} (reset {stamp} {n})"));
        n += 1;
    }
    std::fs::rename(dir, &target)?;
    Ok(target)
}

/// `YYYY-MM-DD HH.MM.SS` (UTC), safe in a file name.
pub fn format_utc(secs: u64) -> String {
    let days = secs / 86_400;
    let rem = secs % 86_400;
    let (y, m, d) = civil_from_days(days as i64);
    format!(
        "{y:04}-{m:02}-{d:02} {:02}.{:02}.{:02}",
        rem / 3600,
        (rem % 3600) / 60,
        rem % 60
    )
}

/// Howard Hinnant's days → civil date.
fn civil_from_days(z: i64) -> (i64, u32, u32) {
    let z = z + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    (if m <= 2 { y + 1 } else { y }, m, d)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn flavours_never_share_paths_or_keychain() {
        assert_ne!(Flavor::Dev.app_name(), Flavor::Production.app_name());
        assert_ne!(
            Flavor::Dev.keychain_service(),
            Flavor::Production.keychain_service()
        );
        assert_eq!(Flavor::Production.keychain_service(), BUNDLE_ID);
    }

    #[test]
    fn utc_formatting() {
        assert_eq!(format_utc(0), "1970-01-01 00.00.00");
        // 2026-11-08 12:34:56 UTC
        assert_eq!(format_utc(1_794_141_296), "2026-11-08 12.34.56");
    }

    #[test]
    fn move_aside_keeps_the_folder() {
        let root = std::env::temp_dir().join(format!("conduit-paths-test-{}", std::process::id()));
        let dir = root.join("Conduit Dev");
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("secure_store.bin"), b"old").unwrap();
        let now = SystemTime::UNIX_EPOCH + std::time::Duration::from_secs(1_794_141_296);
        let moved = move_aside(&dir, now).unwrap();
        assert!(!dir.exists());
        assert_eq!(
            moved.file_name().unwrap().to_string_lossy(),
            "Conduit Dev (reset 2026-11-08 12.34.56)"
        );
        assert_eq!(
            std::fs::read(moved.join("secure_store.bin")).unwrap(),
            b"old"
        );
        // A second reset in the same second gets its own name.
        std::fs::create_dir_all(&dir).unwrap();
        let again = move_aside(&dir, now).unwrap();
        assert_ne!(again, moved);
    }

    #[test]
    fn packaged_daemon_needs_the_bundle_layout() {
        assert!(
            packaged_daemon(Path::new("/nonexistent/Conduit.app/Contents/MacOS/Conduit")).is_none()
        );
    }
}
