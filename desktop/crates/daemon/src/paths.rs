//! Where Conduit Desktop keeps things, per build flavour.
//!
//! Dev builds never share state with the packaged app: they use
//! `~/Library/Application Support/Conduit Dev`, `~/Library/Logs/Conduit Dev`
//! (and the Windows and Linux equivalents, [`AppPaths::standard`]) and
//! their own Keychain service. A rebuilt dev binary would otherwise hit
//! Keychain prompts on the production item, and a developer's own data
//! under `Conduit`.

use std::ffi::OsString;
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

    /// The folder name on macOS and Windows.
    pub fn app_name(self) -> &'static str {
        match self {
            Self::Dev => "Conduit Dev",
            Self::Production => "Conduit",
        }
    }

    /// The folder name in Linux's XDG folders (lower case, no spaces).
    pub fn unix_name(self) -> &'static str {
        match self {
            Self::Dev => "conduit-dev",
            Self::Production => "conduit",
        }
    }

    /// The service the master key is stored under (the Keychain's, and
    /// Windows' and Linux's secret stores).
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
    /// The standard locations for `flavor` on this OS. `CONDUIT_USER_DATA`
    /// and `CONDUIT_LOGS` override them (tests, smoke runs).
    pub fn for_flavor(flavor: Flavor) -> Self {
        let env = |key: &str| std::env::var_os(key);
        let mut paths = Self::standard(Os::CURRENT, flavor, &env);
        if let Some(dir) = env("CONDUIT_USER_DATA") {
            paths.user_data = PathBuf::from(dir);
        }
        if let Some(dir) = env("CONDUIT_LOGS") {
            paths.logs = PathBuf::from(dir);
        }
        paths
    }

    /// `os`'s standard locations for `flavor`, reading the environment
    /// through `vars`:
    ///
    /// * macOS: `~/Library/Application Support/<name>` and
    ///   `~/Library/Logs/<name>`.
    /// * Windows: `%LOCALAPPDATA%\<name>\User Data` and `…\<name>\Logs`
    ///   (local, not roaming). Reset renames the data folder, and Windows
    ///   cannot rename a folder holding the open app log, so the two are
    ///   siblings as on the Mac.
    /// * Linux: `$XDG_DATA_HOME/<name>` and `$XDG_STATE_HOME/<name>/logs`.
    pub fn standard(os: Os, flavor: Flavor, vars: &dyn Fn(&str) -> Option<OsString>) -> Self {
        let (user_data, logs) = match os {
            Os::MacOs => {
                let home = home(vars);
                (
                    home.join("Library/Application Support")
                        .join(flavor.app_name()),
                    home.join("Library/Logs").join(flavor.app_name()),
                )
            }
            Os::Windows => {
                let root = local_app_data(vars).join(flavor.app_name());
                (root.join("User Data"), root.join("Logs"))
            }
            Os::Linux => {
                let name = flavor.unix_name();
                (
                    xdg(vars, "XDG_DATA_HOME", ".local/share").join(name),
                    xdg(vars, "XDG_STATE_HOME", ".local/state")
                        .join(name)
                        .join("logs"),
                )
            }
        };
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

/// The operating systems the app's paths are laid out for.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Os {
    MacOs,
    Windows,
    Linux,
}

impl Os {
    pub const CURRENT: Os = if cfg!(target_os = "macos") {
        Os::MacOs
    } else if cfg!(windows) {
        Os::Windows
    } else {
        Os::Linux
    };

    /// The name `dart build cli` gives this OS in its output folder.
    fn dart_name(self) -> &'static str {
        match self {
            Self::MacOs => "macos",
            Self::Windows => "windows",
            Self::Linux => "linux",
        }
    }

    /// `name` as an executable file name on this OS.
    fn executable(self, name: &str) -> String {
        match self {
            Self::Windows => format!("{name}.exe"),
            Self::MacOs | Self::Linux => name.to_string(),
        }
    }
}

/// The lock file launches take turns on to create `service`'s master key
/// where the secret store's write replaces
/// ([`crate::secrets::LockedStore`]). The key is the service's, whatever the
/// profile (as the Keychain item is on the Mac), so the lock is one per
/// user and service, outside every profile:
///
/// * Windows: `%LOCALAPPDATA%\<service>.master-key.lock`. Windows sets
///   `LOCALAPPDATA` whenever a user profile is loaded; with a stripped
///   environment it is `%USERPROFILE%\AppData\Local`, the same folder.
/// * Linux: `~/.local/state/<service>.master-key.lock`, from `HOME` alone:
///   `XDG_RUNTIME_DIR` and `XDG_STATE_HOME` can differ between a desktop
///   session's launch and an ssh or cron one, which would split the lock.
/// * macOS (its stores need none): under `~/Library/Caches`.
pub fn master_key_lock(os: Os, service: &str, vars: &dyn Fn(&str) -> Option<OsString>) -> PathBuf {
    let folder = match os {
        Os::MacOs => home(vars).join("Library/Caches"),
        Os::Windows => local_app_data(vars),
        Os::Linux => home(vars).join(".local/state"),
    };
    folder.join(format!("{service}.master-key.lock"))
}

fn home(vars: &dyn Fn(&str) -> Option<OsString>) -> PathBuf {
    vars("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(std::env::temp_dir)
}

/// `%LOCALAPPDATA%` (local, not roaming), never a `HOME`.
fn local_app_data(vars: &dyn Fn(&str) -> Option<OsString>) -> PathBuf {
    vars("LOCALAPPDATA")
        .map(PathBuf::from)
        .or_else(|| vars("USERPROFILE").map(|p| PathBuf::from(p).join("AppData").join("Local")))
        .unwrap_or_else(std::env::temp_dir)
}

/// An XDG base folder from `key`, else `fallback` under `HOME`. The spec
/// says to ignore a relative path in these. (A rooted one: Linux's absolute
/// paths, read on any host.)
fn xdg(vars: &dyn Fn(&str) -> Option<OsString>, key: &str, fallback: &str) -> PathBuf {
    vars(key)
        .map(PathBuf::from)
        .filter(|p| p.has_root())
        .unwrap_or_else(|| home(vars).join(fallback))
}

/// The packaged daemon for an executable at `exe`, if it exists.
pub fn packaged_daemon(exe: &Path) -> Option<PathBuf> {
    packaged_daemon_for(Os::CURRENT, exe)
}

/// Where a packaged build keeps the daemon, if it is there:
///
/// * macOS: `<bundle>/Contents/Resources/conduitd/bin/conduitd` for an
///   executable at `<bundle>/Contents/MacOS/<exe>`.
/// * Windows and Linux: `conduitd/bin/conduitd[.exe]` beside the
///   executable (the install folder; `/usr/lib/conduit`, `/app/lib/conduit`
///   in a Flatpak).
pub fn packaged_daemon_for(os: Os, exe: &Path) -> Option<PathBuf> {
    let candidate = match os {
        Os::MacOs => exe
            .parent()?
            .parent()?
            .join("Resources/conduitd/bin/conduitd"),
        Os::Windows | Os::Linux => exe
            .parent()?
            .join("conduitd")
            .join("bin")
            .join(os.executable("conduitd")),
    };
    candidate.is_file().then_some(candidate)
}

/// The `dart build cli` output in this repo.
pub fn dev_daemon() -> PathBuf {
    dev_daemon_for(Os::CURRENT, std::env::consts::ARCH)
}

/// The `dart build cli` output for `os` on `arch` (a Rust arch name), in
/// Dart's `<os>_<arch>` folder naming.
pub fn dev_daemon_for(os: Os, arch: &str) -> PathBuf {
    let arch = match arch {
        "aarch64" => "arm64",
        "x86_64" => "x64",
        other => other,
    };
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../../apps/daemon/build/cli")
        .join(format!("{}_{arch}", os.dart_name()))
        .join("bundle/bin")
        .join(os.executable("conduitd"))
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

    fn vars(pairs: &[(&str, &str)]) -> impl Fn(&str) -> Option<OsString> + use<> {
        let pairs: Vec<(String, OsString)> = pairs
            .iter()
            .map(|(k, v)| (k.to_string(), OsString::from(v)))
            .collect();
        move |key| pairs.iter().find(|(k, _)| k == key).map(|(_, v)| v.clone())
    }

    #[test]
    fn the_mac_layout_is_unchanged() {
        let paths = AppPaths::standard(Os::MacOs, Flavor::Dev, &vars(&[("HOME", "/Users/avery")]));
        assert_eq!(
            paths.user_data,
            Path::new("/Users/avery/Library/Application Support/Conduit Dev")
        );
        assert_eq!(
            paths.logs,
            Path::new("/Users/avery/Library/Logs/Conduit Dev")
        );
    }

    #[test]
    fn windows_keeps_data_and_logs_under_local_app_data_never_tmp() {
        let local = Path::new(r"C:\Users\avery\AppData\Local");
        let env = vars(&[("LOCALAPPDATA", local.to_str().unwrap())]);
        let paths = AppPaths::standard(Os::Windows, Flavor::Production, &env);
        assert_eq!(paths.user_data, local.join("Conduit").join("User Data"));
        assert_eq!(paths.logs, local.join("Conduit").join("Logs"));
        // Reset moves the data folder aside, so the logs (which the app
        // keeps open) must not be inside it.
        assert!(!paths.logs.starts_with(&paths.user_data));

        // No LOCALAPPDATA (and never a HOME): the profile's own copy.
        let profile = Path::new(r"C:\Users\avery");
        let paths = AppPaths::standard(
            Os::Windows,
            Flavor::Dev,
            &vars(&[
                ("USERPROFILE", profile.to_str().unwrap()),
                ("HOME", "/home/x"),
            ]),
        );
        assert_eq!(
            paths.user_data,
            profile
                .join("AppData")
                .join("Local")
                .join("Conduit Dev")
                .join("User Data")
        );
        assert!(!paths.user_data.starts_with("/tmp"));
        assert!(!paths.logs.starts_with("/tmp"));
    }

    #[test]
    fn linux_follows_the_xdg_base_directories() {
        let paths = AppPaths::standard(
            Os::Linux,
            Flavor::Production,
            &vars(&[
                ("HOME", "/home/avery"),
                ("XDG_DATA_HOME", "/srv/avery/data"),
                ("XDG_STATE_HOME", "/srv/avery/state"),
            ]),
        );
        assert_eq!(paths.user_data, Path::new("/srv/avery/data/conduit"));
        assert_eq!(paths.logs, Path::new("/srv/avery/state/conduit/logs"));

        // Unset, or relative (which the spec says to ignore): under HOME.
        let paths = AppPaths::standard(
            Os::Linux,
            Flavor::Dev,
            &vars(&[("HOME", "/home/avery"), ("XDG_DATA_HOME", "relative/data")]),
        );
        assert_eq!(
            paths.user_data,
            Path::new("/home/avery/.local/share/conduit-dev")
        );
        assert_eq!(
            paths.logs,
            Path::new("/home/avery/.local/state/conduit-dev/logs")
        );
    }

    #[test]
    fn off_the_mac_the_packaged_daemon_sits_beside_the_executable() {
        // Its own new folder, removed when it drops: never one an earlier
        // run left a daemon in.
        let root = tempfile::Builder::new()
            .prefix("conduit-packaged-")
            .tempdir()
            .expect("a temporary folder");
        for (os, exe, daemon) in [
            (Os::Windows, "Conduit.exe", "conduitd/bin/conduitd.exe"),
            (Os::Linux, "conduit", "conduitd/bin/conduitd"),
        ] {
            let dir = root.path().join(format!("{os:?}"));
            std::fs::create_dir_all(dir.join("conduitd/bin")).unwrap();
            let exe = dir.join(exe);
            assert_eq!(packaged_daemon_for(os, &exe), None);
            std::fs::write(dir.join(daemon), b"").unwrap();
            assert_eq!(packaged_daemon_for(os, &exe), Some(dir.join(daemon)));
        }
    }

    #[test]
    fn the_master_key_lock_is_per_user_and_service_never_per_profile() {
        let service = "app.example.conduit";
        // Windows: in the user's local app data, whatever the profile, and
        // the same folder when only the profile root is known.
        let profile = Path::new(r"C:\Users\avery");
        let local = profile.join("AppData").join("Local");
        let windows = |pairs: &[(&str, &str)]| master_key_lock(Os::Windows, service, &vars(pairs));
        let expected = local.join("app.example.conduit.master-key.lock");
        assert_eq!(
            windows(&[
                ("LOCALAPPDATA", local.to_str().unwrap()),
                ("CONDUIT_USER_DATA", r"D:\profiles\one"),
            ]),
            expected
        );
        assert_eq!(
            windows(&[
                ("USERPROFILE", profile.to_str().unwrap()),
                ("CONDUIT_USER_DATA", r"D:\profiles\two"),
            ]),
            expected
        );
        // Linux: from HOME alone. A desktop session's launch (with
        // XDG_RUNTIME_DIR), an ssh or cron one (without), and a shell that
        // sets XDG_STATE_HOME all take the one lock.
        let linux = |pairs: &[(&str, &str)]| master_key_lock(Os::Linux, service, &vars(pairs));
        let expected = Path::new("/home/avery/.local/state/app.example.conduit.master-key.lock");
        for launch in [
            &[
                ("HOME", "/home/avery"),
                ("XDG_RUNTIME_DIR", "/run/user/1000"),
                ("CONDUIT_USER_DATA", "/srv/one"),
            ][..],
            &[("HOME", "/home/avery"), ("CONDUIT_USER_DATA", "/srv/two")],
            &[("HOME", "/home/avery"), ("XDG_STATE_HOME", "/srv/state")],
        ] {
            assert_eq!(linux(launch), expected, "{launch:?}");
        }
        // Each service has its own.
        let home = vars(&[("HOME", "/home/avery")]);
        assert_ne!(
            master_key_lock(Os::Linux, "app.example.conduit", &home),
            master_key_lock(Os::Linux, "app.example.conduit.dev", &home)
        );
    }

    #[test]
    fn the_dev_daemon_is_the_dart_build_for_this_os_and_arch() {
        let tail = |os, arch| {
            let path = dev_daemon_for(os, arch);
            let parts: Vec<_> = path.components().rev().take(4).collect();
            parts
                .iter()
                .rev()
                .map(|c| c.as_os_str().to_string_lossy().into_owned())
                .collect::<Vec<_>>()
                .join("/")
        };
        assert_eq!(
            tail(Os::MacOs, "aarch64"),
            "macos_arm64/bundle/bin/conduitd"
        );
        assert_eq!(
            tail(Os::Windows, "x86_64"),
            "windows_x64/bundle/bin/conduitd.exe"
        );
        assert_eq!(
            tail(Os::Linux, "aarch64"),
            "linux_arm64/bundle/bin/conduitd"
        );
        assert_eq!(tail(Os::Linux, "x86_64"), "linux_x64/bundle/bin/conduitd");
    }

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
