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

    /// The Linux desktop entry's name, less `.desktop`: the package's
    /// (packaging/linux), or the dev one `crates/app/run.sh
    /// --register-scheme` writes. The windows carry it as their app id
    /// (X11's `WM_CLASS`, Wayland's app id), so docks group them with the
    /// launcher.
    pub fn desktop_entry(self) -> &'static str {
        match self {
            Self::Dev => "conduit-dev",
            Self::Production => "conduit-desktop",
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
    pub fn for_flavor(flavor: Flavor) -> Result<Self, NoUserFolder> {
        let mut paths = Self::standard(Os::CURRENT, flavor, &System)?;
        if let Some(dir) = System.var("CONDUIT_USER_DATA") {
            paths.user_data = PathBuf::from(dir);
        }
        if let Some(dir) = System.var("CONDUIT_LOGS") {
            paths.logs = PathBuf::from(dir);
        }
        Ok(paths)
    }

    /// `os`'s standard locations for `flavor` on `host`:
    ///
    /// * macOS: `~/Library/Application Support/<name>` and
    ///   `~/Library/Logs/<name>`.
    /// * Windows: `<Local AppData>\<name>\User Data` and `…\<name>\Logs`
    ///   (local, not roaming; the known folder, [`local_app_data`]). Reset
    ///   renames the data folder, and Windows cannot rename a folder holding
    ///   the open app log, so the two are siblings as on the Mac.
    /// * Linux: `$XDG_DATA_HOME/<name>` and `$XDG_STATE_HOME/<name>/logs`.
    ///
    /// On macOS and Linux they are under the user's home folder ([`home`]),
    /// and on Windows under Local AppData ([`local_app_data`]); with none,
    /// [`NoUserFolder`].
    pub fn standard(os: Os, flavor: Flavor, host: &dyn Host) -> Result<Self, NoUserFolder> {
        let (user_data, logs) = match os {
            Os::MacOs => {
                let home = home(host).ok_or(NoUserFolder::Home)?;
                (
                    home.join("Library/Application Support")
                        .join(flavor.app_name()),
                    home.join("Library/Logs").join(flavor.app_name()),
                )
            }
            Os::Windows => {
                let root = local_app_data(host)?.join(flavor.app_name());
                (root.join("User Data"), root.join("Logs"))
            }
            Os::Linux => {
                let name = flavor.unix_name();
                (
                    xdg(host, "XDG_DATA_HOME", ".local/share")?.join(name),
                    xdg(host, "XDG_STATE_HOME", ".local/state")?
                        .join(name)
                        .join("logs"),
                )
            }
        };
        Ok(Self {
            flavor,
            user_data,
            logs,
        })
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

/// A folder Windows keeps for the user (`SHGetKnownFolderPath`), which
/// follows a redirected profile folder whatever the environment says.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum KnownFolder {
    /// `FOLDERID_LocalAppData`.
    LocalAppData,
    /// `FOLDERID_Downloads`.
    Downloads,
    /// `FOLDERID_Profile`.
    Profile,
}

/// What the app's paths are worked out from: the environment, Windows'
/// known folders, small settings files and the user's id. [`System`] reads
/// this computer's.
pub trait Host {
    fn var(&self, key: &str) -> Option<OsString>;
    /// The known folder on Windows; `None` on other systems.
    fn known_folder(&self, folder: KnownFolder) -> Option<PathBuf>;
    /// A small text file's contents (Linux's `user-dirs.dirs`).
    fn read_text(&self, path: &Path) -> Option<String>;
    /// The user's id on Linux and macOS; 0 on Windows.
    fn uid(&self) -> u32;
    /// The home folder the user's account names (the passwd entry's), for a
    /// launch with no `HOME`; `None` on Windows or when there is none.
    fn account_home(&self) -> Option<PathBuf>;
}

/// No folder of the user's to keep the profile and the key in. They never
/// go to a shared folder, or a stale one, instead.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum NoUserFolder {
    /// macOS and Linux: `HOME` is unset and the account names none.
    Home,
    /// Windows: the Local AppData known folder can't be resolved.
    LocalAppData,
}

impl std::fmt::Display for NoUserFolder {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(match self {
            Self::Home => {
                "no home folder: HOME is unset and the account names none, \
                 so there is no private place for the profile and its key"
            }
            Self::LocalAppData => {
                "Windows can't say where Local AppData is, \
                 so there is no place for the profile and its key"
            }
        })
    }
}

impl std::error::Error for NoUserFolder {}

/// This computer.
pub struct System;

impl Host for System {
    fn var(&self, key: &str) -> Option<OsString> {
        std::env::var_os(key)
    }

    fn known_folder(&self, folder: KnownFolder) -> Option<PathBuf> {
        #[cfg(windows)]
        {
            windows_known_folder(folder)
        }
        #[cfg(not(windows))]
        {
            let _ = folder;
            None
        }
    }

    fn read_text(&self, path: &Path) -> Option<String> {
        std::fs::read_to_string(path).ok()
    }

    fn uid(&self) -> u32 {
        #[cfg(unix)]
        {
            // SAFETY: getuid has no preconditions and cannot fail.
            unsafe { libc::getuid() }
        }
        #[cfg(not(unix))]
        {
            0
        }
    }

    fn account_home(&self) -> Option<PathBuf> {
        #[cfg(unix)]
        {
            passwd_home()
        }
        #[cfg(not(unix))]
        {
            None
        }
    }
}

/// The home folder in this user's passwd entry (`getpwuid_r`).
#[cfg(unix)]
fn passwd_home() -> Option<PathBuf> {
    use std::os::unix::ffi::OsStrExt as _;
    let mut buffer = vec![0u8; 4096];
    // SAFETY: an all-zero passwd is valid for getpwuid_r to fill.
    let mut entry: libc::passwd = unsafe { std::mem::zeroed() };
    let mut found: *mut libc::passwd = std::ptr::null_mut();
    loop {
        // SAFETY: `entry`, `buffer` (of the length given) and `found` are
        // valid for writes for the call.
        let status = unsafe {
            libc::getpwuid_r(
                libc::geteuid(),
                &mut entry,
                buffer.as_mut_ptr().cast(),
                buffer.len(),
                &mut found,
            )
        };
        if status == libc::ERANGE && buffer.len() < 1 << 20 {
            buffer.resize(buffer.len() * 2, 0);
            continue;
        }
        if status != 0 || found.is_null() || entry.pw_dir.is_null() {
            return None;
        }
        break;
    }
    // SAFETY: getpwuid_r succeeded, so pw_dir is a NUL-terminated string in
    // `buffer`, which outlives this use.
    let dir = unsafe { std::ffi::CStr::from_ptr(entry.pw_dir) };
    Some(PathBuf::from(std::ffi::OsStr::from_bytes(dir.to_bytes()))).filter(|p| p.has_root())
}

#[cfg(windows)]
fn windows_known_folder(folder: KnownFolder) -> Option<PathBuf> {
    use std::os::windows::ffi::OsStringExt as _;
    use windows::Win32::System::Com::CoTaskMemFree;
    use windows::Win32::UI::Shell::{
        FOLDERID_Downloads, FOLDERID_LocalAppData, FOLDERID_Profile, KF_FLAG_DEFAULT,
        KF_FLAG_DONT_VERIFY, SHGetKnownFolderPath,
    };
    // Local AppData is where it is configured, reachable or not: the profile
    // and the key's lock never move with the network. Downloads and the
    // profile folder are looked at only to open a save panel.
    let (id, flags) = match folder {
        KnownFolder::LocalAppData => (&FOLDERID_LocalAppData, KF_FLAG_DONT_VERIFY),
        KnownFolder::Downloads => (&FOLDERID_Downloads, KF_FLAG_DEFAULT),
        KnownFolder::Profile => (&FOLDERID_Profile, KF_FLAG_DEFAULT),
    };
    // SAFETY: `id` is a valid known-folder id; the returned string is the
    // caller's to free with CoTaskMemFree, after it is copied.
    unsafe {
        let raw = SHGetKnownFolderPath(id, flags, None).ok()?;
        let path = PathBuf::from(std::ffi::OsString::from_wide(raw.as_wide()));
        CoTaskMemFree(Some(raw.0 as *const _));
        Some(path).filter(|p| p.has_root())
    }
}

/// What launches take turns on to create `service`'s master key where the
/// secret store's write replaces ([`crate::secrets::LockedStore`]).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum KeyLock {
    /// A lock file.
    File(PathBuf),
    /// A Linux abstract socket name: held while it is bound, by one process
    /// at a time, and gone with the process. No file, so nothing in it comes
    /// from `HOME`.
    Abstract(String),
}

/// The lock for `service`'s master key. The key is the service's, whatever
/// the profile (as the Keychain item is on the Mac), so the lock is one per
/// user and service, outside every profile:
///
/// * Windows: `<Local AppData>\<service>.master-key.lock`, in the known
///   folder ([`local_app_data`]): a redirected Local AppData and a stripped
///   environment still meet in one folder.
/// * Linux: the abstract socket `<service>.master-key.<uid>`, from the
///   user's id alone. `HOME`, `XDG_RUNTIME_DIR` and `XDG_STATE_HOME` can
///   differ between a desktop session's launch and an ssh, cron or `env -i`
///   one, which would split a lock file.
/// * macOS: under `~/Library/Caches`, held by Start Fresh
///   ([`crate::secrets::start_fresh`]).
pub fn master_key_lock(os: Os, service: &str, host: &dyn Host) -> KeyLock {
    match os {
        // With no home the app stops before it asks (`AppPaths::for_flavor`).
        Os::MacOs => KeyLock::File(
            home(host)
                .unwrap_or_else(std::env::temp_dir)
                .join("Library/Caches")
                .join(format!("{service}.master-key.lock")),
        ),
        // With no Local AppData the app stops before it asks.
        Os::Windows => KeyLock::File(
            local_app_data(host)
                .unwrap_or_else(|_| std::env::temp_dir())
                .join(format!("{service}.master-key.lock")),
        ),
        Os::Linux => KeyLock::Abstract(format!("{service}.master-key.{}", host.uid())),
    }
}

/// Where D12's opt-in key file keeps `service`'s master key on Linux:
/// `$XDG_DATA_HOME/<service>.master-key`, beside the profiles rather than in
/// one, as the key is the service's.
pub fn master_key_file(service: &str, host: &dyn Host) -> Result<PathBuf, NoUserFolder> {
    Ok(xdg(host, "XDG_DATA_HOME", ".local/share")?.join(format!("{service}.master-key")))
}

/// The folder save panels open in: the user's Downloads folder when it is
/// there ([`standard_downloads`]), else the home folder, else the temporary
/// folder.
pub fn downloads() -> PathBuf {
    let host = System;
    standard_downloads(Os::CURRENT, &host)
        .filter(|d| d.is_dir())
        .or_else(|| user_home(Os::CURRENT, &host).filter(|h| h.is_dir()))
        .unwrap_or_else(std::env::temp_dir)
}

/// `os`'s Downloads folder on `host`:
///
/// * macOS: `~/Downloads`.
/// * Windows: the Downloads known folder (it moves with the user's choice
///   in its Properties), else `%USERPROFILE%\Downloads`.
/// * Linux: `XDG_DOWNLOAD_DIR` in `$XDG_CONFIG_HOME/user-dirs.dirs` (it
///   carries the folder's name in the user's language), else `~/Downloads`.
pub fn standard_downloads(os: Os, host: &dyn Host) -> Option<PathBuf> {
    match os {
        Os::MacOs => user_home(os, host).map(|h| h.join("Downloads")),
        Os::Windows => host
            .known_folder(KnownFolder::Downloads)
            .or_else(|| user_home(os, host).map(|p| p.join("Downloads"))),
        Os::Linux => {
            let home = user_home(os, host);
            let config = xdg(host, "XDG_CONFIG_HOME", ".config").ok();
            config
                .and_then(|c| host.read_text(&c.join("user-dirs.dirs")))
                .and_then(|text| user_dir(&text, "XDG_DOWNLOAD_DIR", home.as_deref()))
                .or_else(|| home.map(|h| h.join("Downloads")))
        }
    }
}

/// `key`'s folder in a `user-dirs.dirs` file: `"$HOME/<path>"` (none when
/// `home` isn't known) or an absolute `"/<path>"`, as xdg-user-dirs writes
/// them. Anything else is ignored.
fn user_dir(text: &str, key: &str, home: Option<&Path>) -> Option<PathBuf> {
    let value = text
        .lines()
        .map(str::trim)
        .filter(|line| !line.starts_with('#'))
        .filter_map(|line| line.strip_prefix(key)?.strip_prefix('='))
        .next_back()?
        .trim();
    let value = value
        .strip_prefix('"')
        .and_then(|v| v.strip_suffix('"'))
        .unwrap_or(value);
    if value == "$HOME" {
        return home.map(Path::to_path_buf);
    }
    if let Some(rest) = value.strip_prefix("$HOME/") {
        // `$HOME//Downloads` too: an absolute rest would replace home.
        return home.map(|h| h.join(unescape_user_dir(rest.trim_start_matches('/'))));
    }
    let path = unescape_user_dir(value);
    path.starts_with('/').then(|| PathBuf::from(path))
}

/// A `user-dirs.dirs` value's backslash escapes (`\$`, `\\`, `\"`, `` \` ``,
/// as xdg-user-dirs writes them) read back as the characters. Nothing is
/// evaluated; any other backslash stays, as in a shell's double quotes.
fn unescape_user_dir(value: &str) -> String {
    let mut out = String::with_capacity(value.len());
    let mut chars = value.chars().peekable();
    while let Some(c) = chars.next() {
        if c == '\\'
            && let Some(&next) = chars.peek()
            && matches!(next, '$' | '\\' | '"' | '`')
        {
            out.push(next);
            chars.next();
        } else {
            out.push(c);
        }
    }
    out
}

/// The user's home folder: [`home`] on macOS and Linux; the profile known
/// folder on Windows, else `%USERPROFILE%`.
fn user_home(os: Os, host: &dyn Host) -> Option<PathBuf> {
    match os {
        Os::MacOs | Os::Linux => home(host),
        Os::Windows => host
            .known_folder(KnownFolder::Profile)
            .or_else(|| host.var("USERPROFILE").map(PathBuf::from)),
    }
}

/// The user's home folder: `HOME`, else the one the account names. `None`
/// when neither says, never a shared folder such as the temporary one,
/// where another user could reach the profile or the key.
fn home(host: &dyn Host) -> Option<PathBuf> {
    host.var("HOME")
        .map(PathBuf::from)
        .filter(|p| p.has_root())
        .or_else(|| host.account_home().filter(|p| p.has_root()))
}

/// Windows' Local AppData (local, not roaming): the known folder where it
/// is configured, even while it can't be reached (a redirected folder
/// offline). Never `%LOCALAPPDATA%` or a `HOME`, which may name an older
/// place: a launch there would open another profile beside another lock.
pub fn local_app_data(host: &dyn Host) -> Result<PathBuf, NoUserFolder> {
    host.known_folder(KnownFolder::LocalAppData)
        .ok_or(NoUserFolder::LocalAppData)
}

/// An XDG base folder from `key`, else `fallback` under the home folder.
/// The spec says to ignore a relative path in these. (A rooted one: Linux's
/// absolute paths, read on any host.)
fn xdg(host: &dyn Host, key: &str, fallback: &str) -> Result<PathBuf, NoUserFolder> {
    host.var(key)
        .map(PathBuf::from)
        .filter(|p| p.has_root())
        .or_else(|| home(host).map(|h| h.join(fallback)))
        .ok_or(NoUserFolder::Home)
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

/// The third-party notices installed with the executable at `exe`, if any.
pub fn packaged_notices(exe: &Path) -> Option<PathBuf> {
    packaged_notices_for(Os::CURRENT, exe)
}

/// Where a packaged build's `THIRD_PARTY_NOTICES.md` is, if it is there:
///
/// * macOS: `<bundle>/Contents/Resources/` for an executable at
///   `<bundle>/Contents/MacOS/<exe>`.
/// * Windows: beside the executable (the install folder).
/// * Linux: beside the executable (`/usr/lib/conduit`), else
///   `<prefix>/share/doc/conduit-desktop/` for an executable in
///   `<prefix>/lib/conduit/`. The packages install both; a minimized
///   system (dpkg's `path-exclude`, rpm's `nodocs`) drops the doc folder's.
pub fn packaged_notices_for(os: Os, exe: &Path) -> Option<PathBuf> {
    const NAME: &str = "THIRD_PARTY_NOTICES.md";
    let dir = exe.parent()?;
    let candidates = match os {
        Os::MacOs => vec![dir.parent()?.join("Resources").join(NAME)],
        Os::Windows => vec![dir.join(NAME)],
        Os::Linux => {
            let mut found = vec![dir.join(NAME)];
            if let Some(prefix) = dir.parent().and_then(Path::parent) {
                found.push(
                    prefix
                        .join("share")
                        .join("doc")
                        .join("conduit-desktop")
                        .join(NAME),
                );
            }
            found
        }
    };
    candidates.into_iter().find(|p| p.is_file())
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
/// user (and support) to look at. Restoring one by hand means moving both
/// the folder and its `.master-key-account` file over the current ones, or
/// removing the current record when the archive has none.
pub fn move_aside(dir: &Path, now: SystemTime) -> std::io::Result<PathBuf> {
    let target = aside_path(dir, now);
    std::fs::rename(dir, &target)?;
    Ok(target)
}

/// Where [`move_aside`] would move `dir` now: a name no folder has yet.
pub fn aside_path(dir: &Path, now: SystemTime) -> PathBuf {
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
    target
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
pub(crate) mod tests {
    use super::*;

    /// A computer for tests: its environment, known folders, files and user.
    #[derive(Clone, Default)]
    pub(crate) struct Fake {
        vars: Vec<(String, OsString)>,
        known: Vec<(KnownFolder, PathBuf)>,
        files: Vec<(PathBuf, String)>,
        uid: u32,
        account_home: Option<PathBuf>,
    }

    impl Fake {
        pub(crate) fn known(mut self, folder: KnownFolder, path: impl Into<PathBuf>) -> Self {
            self.known.push((folder, path.into()));
            self
        }

        pub(crate) fn file(mut self, path: impl Into<PathBuf>, text: &str) -> Self {
            self.files.push((path.into(), text.into()));
            self
        }

        pub(crate) fn uid(mut self, uid: u32) -> Self {
            self.uid = uid;
            self
        }

        pub(crate) fn account_home(mut self, home: impl Into<PathBuf>) -> Self {
            self.account_home = Some(home.into());
            self
        }
    }

    impl Host for Fake {
        fn var(&self, key: &str) -> Option<OsString> {
            self.vars
                .iter()
                .find(|(k, _)| k == key)
                .map(|(_, v)| v.clone())
        }
        fn known_folder(&self, folder: KnownFolder) -> Option<PathBuf> {
            self.known
                .iter()
                .find(|(f, _)| *f == folder)
                .map(|(_, p)| p.clone())
        }
        fn read_text(&self, path: &Path) -> Option<String> {
            self.files
                .iter()
                .find(|(p, _)| p == path)
                .map(|(_, t)| t.clone())
        }
        fn uid(&self) -> u32 {
            self.uid
        }
        fn account_home(&self) -> Option<PathBuf> {
            self.account_home.clone()
        }
    }

    /// A computer whose environment is `pairs`, and nothing else.
    pub(crate) fn vars(pairs: &[(&str, &str)]) -> Fake {
        Fake {
            vars: pairs
                .iter()
                .map(|(k, v)| (k.to_string(), OsString::from(v)))
                .collect(),
            ..Fake::default()
        }
    }

    #[test]
    fn windows_takes_local_app_data_from_the_known_folder_never_the_environment() {
        // Local AppData redirected (a roaming-profile policy, a moved
        // folder): the known folder says where it is, and a launch whose
        // environment still names the old place, or none, agrees.
        let known = Path::new(r"D:\Profiles\avery\AppData\Local");
        let service = "app.example.conduit";
        let expected_lock = KeyLock::File(known.join("app.example.conduit.master-key.lock"));
        for env in [
            &[("LOCALAPPDATA", r"C:\Users\avery\AppData\Local")][..],
            &[("USERPROFILE", r"C:\Users\avery")],
            &[],
        ] {
            let host = vars(env).known(KnownFolder::LocalAppData, known);
            let paths = AppPaths::standard(Os::Windows, Flavor::Production, &host).unwrap();
            assert_eq!(
                paths.user_data,
                known.join("Conduit").join("User Data"),
                "{env:?}"
            );
            assert_eq!(paths.logs, known.join("Conduit").join("Logs"), "{env:?}");
            assert_eq!(
                master_key_lock(Os::Windows, service, &host),
                expected_lock,
                "{env:?}"
            );
        }
    }

    #[test]
    fn the_linux_master_key_lock_comes_from_the_user_id_never_home() {
        let service = "app.example.conduit";
        // One user, launched from a desktop session, over ssh, from cron,
        // with another HOME, and with none at all: one lock.
        let expected = KeyLock::Abstract("app.example.conduit.master-key.1000".into());
        for env in [
            &[
                ("HOME", "/home/avery"),
                ("XDG_RUNTIME_DIR", "/run/user/1000"),
            ][..],
            &[("HOME", "/home/avery")],
            &[("HOME", "/srv/elsewhere"), ("XDG_STATE_HOME", "/srv/state")],
            &[],
        ] {
            assert_eq!(
                master_key_lock(Os::Linux, service, &vars(env).uid(1000)),
                expected,
                "{env:?}"
            );
        }
        // Another user, or another service: another lock.
        let home = vars(&[("HOME", "/home/avery")]);
        assert_ne!(
            master_key_lock(Os::Linux, service, &home.clone().uid(1001)),
            expected
        );
        assert_ne!(
            master_key_lock(Os::Linux, "app.example.conduit.dev", &home.uid(1000)),
            expected
        );
    }

    /// With no `HOME`, the profile and the key file go under the home the
    /// account names; with neither, nowhere: never the shared temporary
    /// folder, where another user could reach them.
    #[test]
    fn without_home_the_profile_and_key_go_to_the_accounts_home_or_nowhere() {
        let account = vars(&[]).account_home("/home/avery");
        let paths = AppPaths::standard(Os::Linux, Flavor::Dev, &account).unwrap();
        assert_eq!(
            paths.user_data,
            Path::new("/home/avery/.local/share/conduit-dev")
        );
        assert_eq!(
            paths.logs,
            Path::new("/home/avery/.local/state/conduit-dev/logs")
        );
        assert_eq!(
            master_key_file("app.example.conduit", &account),
            Ok(PathBuf::from(
                "/home/avery/.local/share/app.example.conduit.master-key"
            ))
        );
        let mac = AppPaths::standard(Os::MacOs, Flavor::Dev, &account).unwrap();
        assert_eq!(
            mac.user_data,
            Path::new("/home/avery/Library/Application Support/Conduit Dev")
        );

        let nobody = vars(&[]);
        assert_eq!(
            AppPaths::standard(Os::Linux, Flavor::Dev, &nobody),
            Err(NoUserFolder::Home)
        );
        assert_eq!(
            AppPaths::standard(Os::MacOs, Flavor::Dev, &nobody),
            Err(NoUserFolder::Home)
        );
        assert_eq!(
            master_key_file("app.example.conduit", &nobody),
            Err(NoUserFolder::Home)
        );
        // Absolute XDG folders need no home.
        let xdg = vars(&[
            ("XDG_DATA_HOME", "/srv/data"),
            ("XDG_STATE_HOME", "/srv/state"),
        ]);
        assert!(AppPaths::standard(Os::Linux, Flavor::Dev, &xdg).is_ok());
    }

    #[test]
    fn the_key_file_sits_beside_the_profiles_never_in_one() {
        let host = vars(&[("HOME", "/home/avery")]);
        assert_eq!(
            master_key_file("app.example.conduit", &host).unwrap(),
            Path::new("/home/avery/.local/share/app.example.conduit.master-key")
        );
        let profile = AppPaths::standard(Os::Linux, Flavor::Production, &host)
            .unwrap()
            .user_data;
        assert!(
            !master_key_file("app.example.conduit", &host)
                .unwrap()
                .starts_with(&profile)
        );
        let host = vars(&[("HOME", "/home/avery"), ("XDG_DATA_HOME", "/srv/data")]);
        assert_eq!(
            master_key_file("app.example.conduit", &host).unwrap(),
            Path::new("/srv/data/app.example.conduit.master-key")
        );
    }

    #[test]
    fn downloads_is_each_systems_own_folder() {
        // macOS: ~/Downloads.
        assert_eq!(
            standard_downloads(Os::MacOs, &vars(&[("HOME", "/Users/avery")])),
            Some(PathBuf::from("/Users/avery/Downloads"))
        );
        // Windows: the known folder, wherever the user moved it.
        let host = vars(&[("USERPROFILE", r"C:\Users\avery"), ("HOME", "/home/x")])
            .known(KnownFolder::Downloads, r"E:\Downloads");
        assert_eq!(
            standard_downloads(Os::Windows, &host),
            Some(PathBuf::from(r"E:\Downloads"))
        );
        // Linux: user-dirs.dirs names it, in the user's language.
        let home = [("HOME", "/home/avery")];
        let dirs = "# written by xdg-user-dirs-update\n\
                    XDG_DESKTOP_DIR=\"$HOME/Schreibtisch\"\n\
                    XDG_DOWNLOAD_DIR=\"$HOME/Downloads-de\"\n";
        let host = vars(&home).file("/home/avery/.config/user-dirs.dirs", dirs);
        assert_eq!(
            standard_downloads(Os::Linux, &host),
            Some(PathBuf::from("/home/avery/Downloads-de"))
        );
        // In XDG_CONFIG_HOME, and an absolute folder.
        let host = vars(&[("HOME", "/home/avery"), ("XDG_CONFIG_HOME", "/srv/config")]).file(
            "/srv/config/user-dirs.dirs",
            "XDG_DOWNLOAD_DIR=\"/data/incoming\"\n",
        );
        assert_eq!(
            standard_downloads(Os::Linux, &host),
            Some(PathBuf::from("/data/incoming"))
        );
        // Set to home itself (the folder turned off): home.
        let host = vars(&home).file(
            "/home/avery/.config/user-dirs.dirs",
            "XDG_DOWNLOAD_DIR=\"$HOME\"\n",
        );
        assert_eq!(
            standard_downloads(Os::Linux, &host),
            Some(PathBuf::from("/home/avery"))
        );
        // No file, or nothing usable in it: ~/Downloads.
        for host in [
            vars(&home),
            vars(&home).file(
                "/home/avery/.config/user-dirs.dirs",
                "XDG_DOWNLOAD_DIR=\"relative/place\"\n",
            ),
        ] {
            assert_eq!(
                standard_downloads(Os::Linux, &host),
                Some(PathBuf::from("/home/avery/Downloads"))
            );
        }
    }

    /// With no `HOME`, an absolute folder in `$XDG_CONFIG_HOME/user-dirs.dirs`
    /// still names Downloads; only one under `$HOME` can't be worked out.
    #[test]
    fn downloads_without_home_takes_an_absolute_user_dir() {
        let config = [("XDG_CONFIG_HOME", "/srv/config")];
        let dirs = "/srv/config/user-dirs.dirs";
        let host = vars(&config).file(dirs, "XDG_DOWNLOAD_DIR=\"/data/incoming\"\n");
        assert_eq!(
            standard_downloads(Os::Linux, &host),
            Some(PathBuf::from("/data/incoming"))
        );
        let host = vars(&config).file(dirs, "XDG_DOWNLOAD_DIR=\"$HOME/Downloads\"\n");
        assert_eq!(standard_downloads(Os::Linux, &host), None);
        assert_eq!(standard_downloads(Os::Linux, &vars(&[])), None);
    }

    /// xdg-user-dirs writes a folder name's `$`, `\`, `"` and `` ` `` with a
    /// backslash before them; they are read back as the characters, never
    /// evaluated, and only an unescaped `$HOME` is the home folder.
    #[test]
    fn user_dirs_escapes_are_decoded_never_evaluated() {
        let dirs = "/home/avery/.config/user-dirs.dirs";
        let downloads = |value: &str| {
            let host =
                vars(&[("HOME", "/home/avery")]).file(dirs, &format!("XDG_DOWNLOAD_DIR={value}\n"));
            standard_downloads(Os::Linux, &host).unwrap()
        };
        for (value, expected) in [
            (r#""$HOME/Team \$ Files""#, "/home/avery/Team $ Files"),
            (r#""$HOME//Downloads""#, "/home/avery/Downloads"),
            (r#""$HOME/back\\slash""#, r"/home/avery/back\slash"),
            (r#""$HOME/\"quoted\"""#, r#"/home/avery/"quoted""#),
            (r#""$HOME/tick\`s""#, "/home/avery/tick`s"),
            (r#""/srv/\$HOME/in""#, "/srv/$HOME/in"),
            // An escaped `$HOME` is a folder name, not home, and not absolute.
            (r#""\$HOME/in""#, "/home/avery/Downloads"),
        ] {
            assert_eq!(downloads(value), PathBuf::from(expected), "{value}");
        }
    }

    #[test]
    fn the_mac_layout_is_unchanged() {
        let paths =
            AppPaths::standard(Os::MacOs, Flavor::Dev, &vars(&[("HOME", "/Users/avery")])).unwrap();
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
        let env = vars(&[]).known(KnownFolder::LocalAppData, local);
        let paths = AppPaths::standard(Os::Windows, Flavor::Production, &env).unwrap();
        assert_eq!(paths.user_data, local.join("Conduit").join("User Data"));
        assert_eq!(paths.logs, local.join("Conduit").join("Logs"));
        // Reset moves the data folder aside, so the logs (which the app
        // keeps open) must not be inside it.
        assert!(!paths.logs.starts_with(&paths.user_data));

        // No known folder: no profile, never one the environment names
        // (it may be stale) or the temporary folder.
        for env in [
            &[("LOCALAPPDATA", local.to_str().unwrap())][..],
            &[("USERPROFILE", r"C:\Users\avery"), ("HOME", "/home/x")],
        ] {
            assert_eq!(
                AppPaths::standard(Os::Windows, Flavor::Dev, &vars(env)),
                Err(NoUserFolder::LocalAppData),
                "{env:?}"
            );
        }
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
        )
        .unwrap();
        assert_eq!(paths.user_data, Path::new("/srv/avery/data/conduit"));
        assert_eq!(paths.logs, Path::new("/srv/avery/state/conduit/logs"));

        // Unset, or relative (which the spec says to ignore): under HOME.
        let paths = AppPaths::standard(
            Os::Linux,
            Flavor::Dev,
            &vars(&[("HOME", "/home/avery"), ("XDG_DATA_HOME", "relative/data")]),
        )
        .unwrap();
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
    fn a_packaged_build_finds_the_notices_its_package_installs() {
        // Its own new folder, removed when it drops.
        let root = tempfile::Builder::new()
            .prefix("conduit-notices-")
            .tempdir()
            .expect("a temporary folder");
        for (os, exe, notices) in [
            (
                Os::MacOs,
                "Conduit.app/Contents/MacOS/Conduit",
                "Conduit.app/Contents/Resources/THIRD_PARTY_NOTICES.md",
            ),
            (
                Os::Windows,
                "Programs/Conduit/conduit-desktop.exe",
                "Programs/Conduit/THIRD_PARTY_NOTICES.md",
            ),
            (
                Os::Linux,
                "usr/lib/conduit/conduit-desktop",
                "usr/share/doc/conduit-desktop/THIRD_PARTY_NOTICES.md",
            ),
        ] {
            let dir = root.path().join(format!("{os:?}"));
            let (exe, notices) = (dir.join(exe), dir.join(notices));
            std::fs::create_dir_all(exe.parent().unwrap()).unwrap();
            std::fs::create_dir_all(notices.parent().unwrap()).unwrap();
            // A build with no notices beside it (a dev build) finds none.
            assert_eq!(packaged_notices_for(os, &exe), None, "{os:?}");
            std::fs::write(&notices, b"").unwrap();
            assert_eq!(packaged_notices_for(os, &exe), Some(notices), "{os:?}");
        }
        // Linux: the copy beside the app first, which a minimized system
        // (dpkg's path-exclude, rpm's nodocs) keeps when it drops the doc
        // folder's.
        let lib = root
            .path()
            .join("Linux/usr/lib/conduit/THIRD_PARTY_NOTICES.md");
        let exe = root.path().join("Linux/usr/lib/conduit/conduit-desktop");
        std::fs::write(&lib, b"").unwrap();
        assert_eq!(packaged_notices_for(Os::Linux, &exe), Some(lib.clone()));
        std::fs::remove_file(
            root.path()
                .join("Linux/usr/share/doc/conduit-desktop/THIRD_PARTY_NOTICES.md"),
        )
        .unwrap();
        assert_eq!(packaged_notices_for(Os::Linux, &exe), Some(lib));
    }

    #[test]
    fn the_master_key_lock_is_per_user_and_service_never_per_profile() {
        let service = "app.example.conduit";
        // Windows: in the user's Local AppData, whatever the profile.
        let local = Path::new(r"C:\Users\avery\AppData\Local");
        let windows = |profile: &str| {
            let host =
                vars(&[("CONDUIT_USER_DATA", profile)]).known(KnownFolder::LocalAppData, local);
            master_key_lock(Os::Windows, service, &host)
        };
        let expected = KeyLock::File(local.join("app.example.conduit.master-key.lock"));
        assert_eq!(windows(r"D:\profiles\one"), expected);
        assert_eq!(windows(r"D:\profiles\two"), expected);
        // Linux: the user's, whatever the profile.
        let linux = |profile: &str| {
            master_key_lock(
                Os::Linux,
                service,
                &vars(&[("HOME", "/home/avery"), ("CONDUIT_USER_DATA", profile)]).uid(1000),
            )
        };
        assert_eq!(linux("/srv/one"), linux("/srv/two"));
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
    fn the_windows_app_id_names_the_desktop_entry_that_launches_them() {
        let packaging = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../packaging/linux");
        let id = Flavor::Production.desktop_entry();
        let entry = std::fs::read_to_string(packaging.join(format!("{id}.desktop")))
            .expect("the package's desktop entry is named for the app id");
        assert!(
            entry.lines().any(|l| l == format!("StartupWMClass={id}")),
            "the package's desktop entry has no StartupWMClass={id}"
        );
        let run =
            std::fs::read_to_string(Path::new(env!("CARGO_MANIFEST_DIR")).join("../app/run.sh"))
                .unwrap();
        let dev = Flavor::Dev.desktop_entry();
        // By line: a Windows checkout (core.autocrlf) ends them with CRLF.
        assert!(
            run.lines()
                .any(|l| l.trim() == format!("entry_name={dev}.desktop")),
            "run.sh's dev entry is not {dev}.desktop"
        );
        assert_ne!(id, dev);
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
