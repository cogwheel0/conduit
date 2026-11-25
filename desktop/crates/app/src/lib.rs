//! Conduit Desktop: the native macOS app over the Dart daemon `conduitd`.
//!
//! [`run`] bootstraps the app: logging and the crash hook, preferences, the
//! Keychain master key, the daemon connection and the session layer
//! ([`stores`]), menus and key bindings ([`menus`], [`keymap`]), strings
//! ([`l10n`]), the main window ([`views::main_window`]) and Settings
//! ([`views::settings`]), and the macOS shell extras ([`desktop`]: links,
//! "Open with", notifications, Quick Ask, the menu-bar item, open at
//! login), and Sparkle updates ([`updates`]). `--shots <dir>` runs the
//! scripted smoke pass in [`smoke`]; off the Mac, `--smoke <file>` runs the
//! capture-free one in [`smoke_pass`].
//!
//! The test harness is behind the `harness` feature, which dev and test
//! builds turn on (`crates/app/run.sh`, `perf.sh`, `hc-capture.sh`, and
//! `cargo test` through the crate's dev-dependency on itself) and release
//! bundles leave off (`packaging/macos/bundle.sh`): the `--e2e` passes
//! ([`e2e`]), the screenshot and motion capture (`--capture`, `capture`),
//! `--probe`, and the `--fixture` runs over canned data. A build without
//! it refuses those flags.

pub mod actions;
#[cfg(all(target_os = "macos", feature = "harness"))]
pub mod calendar_fixture;
#[cfg(all(target_os = "macos", feature = "harness"))]
pub mod capture;
#[cfg(all(target_os = "macos", feature = "harness"))]
pub mod channel_fixture;
#[cfg(all(target_os = "macos", feature = "harness"))]
pub mod chat_fixture;
pub mod desktop;
#[cfg(all(target_os = "macos", feature = "harness"))]
pub mod diagram_fixture;
#[cfg(all(target_os = "macos", feature = "harness"))]
pub mod e2e;
#[cfg(all(target_os = "macos", feature = "harness"))]
pub mod fixture;
pub mod intents;
pub mod keymap;
pub mod l10n;
pub mod menus;
pub mod prefs;
#[cfg(all(target_os = "macos", feature = "harness"))]
pub mod rooms_fixture;
pub mod scripted;
pub mod shell;
#[cfg(target_os = "macos")]
pub mod smoke;
pub mod smoke_pass;
pub mod stores;
#[cfg(all(target_os = "macos", feature = "harness"))]
pub mod terminal_fixture;
pub mod updates;
pub mod views;
pub mod voice;
#[cfg(all(target_os = "macos", feature = "harness"))]
pub mod web_media_fixture;
pub mod windows;
#[cfg(all(target_os = "macos", feature = "harness"))]
pub mod workspace_fixture;

use std::path::PathBuf;

use conduit_components::window as cw;
use conduit_daemon::paths::{self, AppPaths, Flavor};
#[cfg(target_os = "linux")]
use conduit_daemon::secrets::SecretError;
use gpui_kit::{
    AnyWindowHandle, App, AppContext as _, Bounds, Entity, Global, WindowAppearance, px, size,
};

use crate::actions::*;
use crate::l10n::{ActiveL10n as _, L10n, locale};
use crate::stores::Stores;
use crate::stores::connection::{ConnectionEvent, ConnectionOptions, ConnectionStore, MasterKey};
use crate::stores::layout::LayoutStore;
use crate::stores::settings::{SettingsEvent, SettingsStore};
use crate::views::main_window::MainWindow;
use crate::views::settings::{SETTINGS_SIZE, SettingsView, Tab};

/// The app's version: `CONDUIT_VERSION` at build time (the release
/// bundle's `CFBundleShortVersionString`, e.g. `1.2.0`;
/// see packaging/macos/bundle.sh), else the crate version.
pub const VERSION: &str = match option_env!("CONDUIT_VERSION") {
    Some(v) => v,
    None => env!("CARGO_PKG_VERSION"),
};

/// The bundle's `CFBundleVersion` (`CONDUIT_BUILD` at build time); `None`
/// for builds outside the release script.
pub const BUILD: Option<&str> = option_env!("CONDUIT_BUILD");

/// Where the Help menu points.
pub const HELP_URL: &str = "https://github.com/cogwheel0/conduit#readme";

/// The app's long-lived state.
pub struct AppState {
    pub paths: AppPaths,
    pub connection: Entity<ConnectionStore>,
    /// The session layer: accounts, session, ui requests, router, toasts.
    pub stores: Stores,
    pub settings: Entity<SettingsStore>,
    pub layout: Entity<LayoutStore>,
    pub main_window: Option<AnyWindowHandle>,
    pub main_view: Option<Entity<MainWindow>>,
    /// First run and sign-in ([`windows`]), while there is no session.
    pub setup_window: Option<(AnyWindowHandle, Entity<views::setup_window::SetupWindow>)>,
    pub settings_window: Option<(AnyWindowHandle, Entity<SettingsView>)>,
    #[cfg(target_os = "macos")]
    _network: Option<shell::macos::NetworkMonitor>,
    #[cfg(not(target_os = "macos"))]
    _network: Option<conduit_daemon::network::NetworkMonitor>,
}

impl Global for AppState {}

fn arg(args: &[String], key: &str) -> Option<String> {
    scripted::value(args, key)
}

/// Whether `args` ask for a scripted run (`--shots`, `--smoke`, `--e2e`,
/// `--capture`, or a fixture: `--fixture`, `--chat-fixture` and the rest)
/// that drives, resets and photographs its profile, or saves settings to it
/// (a fixture's screenshot theme): a profile of its own, never the user's.
pub fn is_scripted(args: &[String]) -> bool {
    scripted::options(args).any(|a| {
        a == "--shots"
            || a == "--smoke"
            || a.starts_with("--e2e")
            || a.starts_with("--capture")
            || (a.starts_with("--") && a.ends_with("fixture"))
    })
}

/// The profile a scripted run uses: the one named by `named`
/// (`CONDUIT_USER_DATA`), which must not be the app's ordinary profile
/// (`ordinary`), or else a fresh folder under `scratch`. A scripted run
/// never touches a profile the caller did not name, or the user's own.
pub fn harness_profile(
    named: Option<PathBuf>,
    ordinary: Option<&std::path::Path>,
    scratch: &std::path::Path,
) -> Result<PathBuf, String> {
    match named {
        Some(named) => {
            if ordinary.is_some_and(|ordinary| same_folder(&named, ordinary)) {
                Err(format!(
                    "{} is the app's own profile; name a test profile in CONDUIT_USER_DATA",
                    named.display()
                ))
            } else {
                Ok(named)
            }
        }
        None => Ok(scratch.join("user-data")),
    }
}

/// Whether `a` and `b` name one folder.
fn same_folder(a: &std::path::Path, b: &std::path::Path) -> bool {
    let canon = |p: &std::path::Path| p.canonicalize().unwrap_or_else(|_| p.to_path_buf());
    canon(a) == canon(b)
}

/// The app's own profile for `flavor` (`~/Library/Application Support/
/// Conduit Dev`, or `Conduit`, on the Mac), which no scripted run may use.
/// `None` with no home folder, where the app has no profile.
pub fn app_profile(flavor: Flavor) -> Option<PathBuf> {
    AppPaths::standard(paths::Os::CURRENT, flavor, &paths::System)
        .ok()
        .map(|paths| paths.user_data)
}

/// Whether a scripted pass (E2E, capture) may reset the profile at
/// `paths`: never the app's own. The passes check it before every reset,
/// on top of `run()` never giving them that profile.
pub fn may_reset_profile(paths: &AppPaths) -> bool {
    app_profile(paths.flavor).is_some_and(|own| !same_folder(&paths.user_data, &own))
}

/// The Keychain service of a scripted run's master key: never the app's own.
fn harness_service(flavor: Flavor) -> String {
    format!("{}.harness", flavor.keychain_service())
}

/// The service a run's master key is stored under.
fn key_service(paths: &AppPaths, scripted: bool) -> String {
    if scripted {
        harness_service(paths.flavor)
    } else {
        paths.flavor.keychain_service()
    }
}

/// The master key from the Keychain (Credential Manager on Windows, the
/// Secret Service on Linux, or there the key file the user chose), created
/// on first run. The packaged Mac app first finds out, without a prompt,
/// whether reading it would make macOS ask for the login keychain
/// password, and then the window asks first. Retry asks again.
fn master_key(paths: &AppPaths, scripted: bool) -> MasterKey {
    #[cfg(target_os = "linux")]
    {
        linux_master_key(paths, scripted, false).into()
    }
    #[cfg(not(target_os = "linux"))]
    {
        use conduit_daemon::secrets::{MasterKeyStore, load_or_create_master_key};
        let service = key_service(paths, scripted);
        #[cfg(target_os = "macos")]
        let store: Box<dyn MasterKeyStore> = {
            use crate::stores::connection::KeychainChoice;
            use conduit_daemon::secrets::{
                Keychain, KeychainItems, MASTER_KEY_ACCOUNT, MasterKeyCheck, SecurityCli,
                check_master_key, profile_key,
            };
            match paths.flavor {
                // Dev builds go through /usr/bin/security so a rebuilt
                // (re-hashed) binary never meets a Keychain prompt; see
                // conduit_daemon::secrets.
                Flavor::Dev => Box::new(SecurityCli::new(service)),
                // A scripted run never shows the keychain card.
                Flavor::Production if scripted => {
                    Box::new(Keychain::new(service, MASTER_KEY_ACCOUNT))
                }
                Flavor::Production => {
                    let lock = paths::master_key_lock(paths::Os::CURRENT, &service, &paths::System);
                    let items = KeychainItems::new(service);
                    let profile = match profile_key(&paths.user_data) {
                        Ok(profile) => profile,
                        Err(e) => return MasterKey::Failed(e),
                    };
                    let check = check_master_key(&items, &profile);
                    let choice = |missing| KeychainChoice {
                        items: std::sync::Arc::new(items),
                        account: profile.account.clone(),
                        lock,
                        missing,
                    };
                    return match check {
                        Ok(MasterKeyCheck::Ready(key)) => MasterKey::Ready(key),
                        Ok(MasterKeyCheck::WouldPrompt) => MasterKey::WouldPrompt(choice(false)),
                        Ok(MasterKeyCheck::Missing) => MasterKey::WouldPrompt(choice(true)),
                        Err(e) => MasterKey::Failed(e),
                    };
                }
            }
        };
        // A first key is written holding the service's lock, so two first
        // launches, whatever their profiles, never both store theirs.
        #[cfg(windows)]
        let store: Box<dyn MasterKeyStore> = {
            let lock = paths::master_key_lock(paths::Os::CURRENT, &service, &paths::System);
            Box::new(conduit_daemon::secrets::LockedStore::new(
                conduit_daemon::secrets::CredentialManager::new(service),
                lock,
            ))
        };
        load_or_create_master_key(store.as_ref()).into()
    }
}

/// D12: the master key once the user chose the key file. It is chosen as
/// at start-up (`conduit_daemon::secrets::linux_master_key`): a key file
/// already there wins, a keyring that answers keeps the key, and only with
/// no keyring at all is the key file made.
#[cfg(target_os = "linux")]
fn key_file_master_key(paths: &AppPaths, scripted: bool) -> Result<String, SecretError> {
    linux_master_key(paths, scripted, true)
}

#[cfg(target_os = "linux")]
fn linux_master_key(
    paths: &AppPaths,
    scripted: bool,
    make_file: bool,
) -> Result<String, SecretError> {
    use conduit_daemon::secrets::{KeyFile, SecretService};
    let service = key_service(paths, scripted);
    let lock = paths::master_key_lock(paths::Os::CURRENT, &service, &paths::System);
    let file = KeyFile::new(
        paths::master_key_file(&service, &paths::System)
            .map_err(|e| SecretError::Store(e.to_string()))?,
    );
    let key = conduit_daemon::secrets::linux_master_key(
        &SecretService::new(service),
        &file,
        &lock,
        make_file,
    );
    if key.is_ok() && file.chosen() == Ok(true) {
        log::warn!("the master key is in a key file: {}", file.path.display());
    }
    key
}

/// Why `os` doesn't run a flag in `args`, flag first, or `None`. `--probe`
/// and `--shots` drive the Mac's shell and aren't built elsewhere, where they
/// would only open the app (`--probe` on its real profile, without the
/// single-instance check, beside the one already open). `--smoke` is their
/// pass off the Mac, whose exit code only GPUI's run returning can give:
/// AppKit ends a quitting app itself.
pub fn unsupported_flag(os: paths::Os, args: &[String]) -> Option<&'static str> {
    let mac = os == paths::Os::MacOs;
    scripted::options(args).find_map(|a| match a {
        "--probe" if !mac => Some("--probe runs only on macOS"),
        "--shots" if !mac => Some(
            "--shots runs only on macOS; on Windows and Linux the smoke pass is --smoke <file>",
        ),
        "--smoke" if mac => {
            Some("--smoke runs on Windows and Linux; on the Mac the smoke pass is --shots <dir>")
        }
        _ => None,
    })
}

/// The file `--smoke` writes its report to, when the launch asks for the
/// pass. Without one (or with a flag in its place) the launch would open the
/// app as usual, and whatever waits for the verdict would wait for good.
pub fn smoke_file(args: &[String]) -> Result<Option<String>, &'static str> {
    if !scripted::has(args, "--smoke") {
        return Ok(None);
    }
    match arg(args, "--smoke") {
        Some(file) if !file.starts_with('-') => Ok(Some(file)),
        _ => Err("--smoke needs the file to write its report to: --smoke <file>"),
    }
}

/// Whether to leave Wayland for XWayland: the session has both (`DISPLAY`
/// and `WAYLAND_DISPLAY` set), and `CONDUIT_WAYLAND` isn't `1`.
#[cfg_attr(not(target_os = "linux"), cfg(test))]
fn prefer_xwayland(
    display: Option<&std::ffi::OsStr>,
    wayland: Option<&std::ffi::OsStr>,
    keep_wayland: Option<&std::ffi::OsStr>,
) -> bool {
    let set = |value: Option<&std::ffi::OsStr>| value.is_some_and(|v| !v.is_empty());
    set(display) && set(wayland) && keep_wayland != Some(std::ffi::OsStr::new("1"))
}

/// The app's state around a main window a test made, with the links' queue,
/// so requests run through `desktop::handle_urls` as they do in the app.
#[cfg(test)]
pub(crate) fn install_main_for_test(
    stores: Stores,
    settings: Entity<SettingsStore>,
    view: Entity<MainWindow>,
    vcx: &mut gpui_kit::VisualTestContext,
) {
    use gpui_kit::VisualContext as _;
    let handle = vcx.window_handle();
    let scratch = std::env::temp_dir().join(format!("conduit-main-{}", std::process::id()));
    vcx.update(|_, cx| {
        let layout = cx.new(|_| LayoutStore::load(scratch.join("window-state.json")));
        cx.set_global(AppState {
            paths: AppPaths {
                flavor: Flavor::Dev,
                user_data: scratch.join("user-data"),
                logs: scratch.join("logs"),
            },
            connection: stores.connection.clone(),
            stores,
            settings,
            layout,
            main_window: Some(handle),
            main_view: Some(view),
            setup_window: None,
            settings_window: None,
            _network: None,
        });
        desktop::install_without_services(cx);
    });
}

/// Ends a launch the profile's app didn't take, saying why on stderr and
/// in [`REFUSED_LOG`]: the log file is the running app's, never touched
/// from here.
#[cfg(not(target_os = "macos"))]
fn refuse_launch(paths: &AppPaths, why: &str) -> ! {
    note_refused_launch(&paths.logs, std::time::SystemTime::now(), why);
    end_launch(1, why);
}

/// Ends a launch that can't go on, saying why on stderr with `code`.
fn end_launch(code: i32, why: &str) -> ! {
    #[cfg(windows)]
    attach_parent_console();
    eprintln!("conduit-desktop: {why}");
    std::process::exit(code);
}

/// A Windows release build has no console (main.rs): a message for the
/// command line goes to the console of what started the app, a terminal,
/// unless stderr was redirected. Only on the way out: a GUI program attached
/// to a console would also end with a Ctrl+C typed there later.
#[cfg(windows)]
fn attach_parent_console() {
    use ::windows::Win32::System::Console::{
        ATTACH_PARENT_PROCESS, AttachConsole, GetStdHandle, STD_ERROR_HANDLE,
    };
    // SAFETY: reads this process's standard handle, then attaches to its
    // parent's console, which fails harmlessly when there is none.
    unsafe {
        if GetStdHandle(STD_ERROR_HANDLE).is_err() {
            let _ = AttachConsole(ATTACH_PARENT_PROCESS);
        }
    }
}

/// Where a refused launch is noted, beside the app's rotating log.
#[cfg_attr(target_os = "macos", cfg(test))]
const REFUSED_LOG: &str = "launch-refused.log";

/// The most [`REFUSED_LOG`] keeps before it starts over.
#[cfg_attr(target_os = "macos", cfg(test))]
const MAX_REFUSED_LOG: u64 = 64 * 1024;

/// A refused launch's line: when (UTC) and why.
#[cfg_attr(target_os = "macos", cfg(test))]
fn refusal_line(now: std::time::SystemTime, why: &str) -> String {
    let at = chrono::DateTime::<chrono::Utc>::from(now).format("%Y-%m-%dT%H:%M:%SZ");
    format!("{at} {why}\n")
}

/// Adds a refused launch's line to [`REFUSED_LOG`] in `logs`, starting it
/// over past [`MAX_REFUSED_LOG`]. Best effort: the launch ends either way.
#[cfg_attr(target_os = "macos", cfg(test))]
fn note_refused_launch(logs: &std::path::Path, now: std::time::SystemTime, why: &str) {
    use std::io::Write as _;
    let _ = std::fs::create_dir_all(logs);
    let path = logs.join(REFUSED_LOG);
    let start_over = std::fs::metadata(&path).is_ok_and(|m| m.len() > MAX_REFUSED_LOG);
    let mut open = std::fs::OpenOptions::new();
    if start_over {
        open.write(true).truncate(true);
    } else {
        open.append(true);
    }
    if let Ok(mut file) = open.create(true).open(&path) {
        let _ = file.write_all(refusal_line(now, why).as_bytes());
    }
}

/// What a launch's arguments ask to open (Windows, Linux), or `None` for a
/// scripted launch: it runs on a profile of its own ([`is_scripted`], the
/// same test that gives it one), so it claims no instance, and its
/// arguments (`--shots <dir>`, a fixture's) are nothing to open. Any other
/// launch is on the app's profile and claims it, whatever its flags.
pub fn launch_urls(args: &[std::ffi::OsString], cwd: &std::path::Path) -> Option<Vec<String>> {
    if is_scripted(&as_text(args)) {
        return None;
    }
    Some(shell::deep_link::from_argv(args, cwd))
}

/// Arguments as text, for reading options (an argument that isn't UTF-8
/// is only ever a file, which `from_argv` reads from the bytes).
fn as_text(args: &[std::ffi::OsString]) -> Vec<String> {
    args.iter()
        .map(|a| a.to_string_lossy().into_owned())
        .collect()
}

/// This profile's single instance: the listener when this launch is the
/// app; ends the process when another launch is, after handing it `urls`,
/// and also when this user's app holds the profile but doesn't take the
/// launch, or when what holds it can't be identified (two apps on one
/// profile would share its data). Only a holder known to be another user's,
/// or a failure before any holder was found, leaves this launch on its own:
/// why, for the log, which isn't open yet.
#[cfg(not(target_os = "macos"))]
fn claim_instance(
    paths: &AppPaths,
    urls: &[String],
) -> Result<conduit_daemon::instance::Listener, String> {
    use conduit_daemon::instance::{Claim, claim};
    // Every launch names the profile the same way, made or not.
    let _ = std::fs::create_dir_all(&paths.user_data);
    let profile = paths
        .user_data
        .canonicalize()
        .unwrap_or_else(|_| paths.user_data.clone());
    match claim(&paths.flavor.keychain_service(), &profile, urls) {
        Ok(Claim::First(listener)) => Ok(listener),
        Ok(Claim::Forwarded) => {
            log::info!(
                "handed this launch ({} to open) to the running app",
                urls.len()
            );
            std::process::exit(0);
        }
        Ok(Claim::Busy) => {
            let why = "Conduit is already running for this profile but isn't responding; \
                       this launch quits rather than open the profile twice";
            refuse_launch(paths, why);
        }
        Ok(Claim::NotListening(e)) => {
            let why = format!(
                "this launch can't listen for the profile's later launches ({e}); \
                 it quits rather than open the profile where another launch could too"
            );
            refuse_launch(paths, &why);
        }
        Ok(Claim::Unidentified(e)) => {
            let why = format!(
                "something holds this profile and couldn't be reached ({e}); \
                 this launch quits rather than open the profile twice"
            );
            refuse_launch(paths, &why);
        }
        Err(e) => Err(format!("single instance: {e}; this launch runs on its own")),
    }
}

/// Bytes only a build with the test harness carries: the packaging scripts
/// look for them in the built binary and never sign it for distribution
/// (packaging/macos/lib.sh, `refuse_harness_distribution`), whatever flags
/// they were given.
#[cfg(feature = "harness")]
pub static HARNESS_MARKER: &[u8; 35] = b"conduit-desktop: test harness build";

pub fn run() {
    // D2: the web views embed only in X11 windows, so on Linux the app runs
    // on XWayland where the session has it, however it was started (a run
    // script, a registered `conduit://` link, the desktop entry), before
    // GPUI picks its backend. `CONDUIT_WAYLAND=1` keeps Wayland's windows.
    #[cfg(target_os = "linux")]
    if prefer_xwayland(
        std::env::var_os("DISPLAY").as_deref(),
        std::env::var_os("WAYLAND_DISPLAY").as_deref(),
        std::env::var_os("CONDUIT_WAYLAND").as_deref(),
    ) {
        // SAFETY: the process's first step, before any thread that could
        // read the environment starts.
        unsafe { std::env::remove_var("WAYLAND_DISPLAY") };
    }
    // Read natively: a file's name need not be UTF-8 (std::env::args
    // would panic on it). Options are read as text.
    let args_os: Vec<std::ffi::OsString> = std::env::args_os().collect();
    let args = as_text(&args_os);
    // Kept in the binary (never optimized out): the marker is how a harness
    // build is told from a release one after the fact.
    #[cfg(feature = "harness")]
    let _ = std::hint::black_box(HARNESS_MARKER);
    // A build without the test harness refuses its flags rather than
    // starting normally, so a script can never drive a real profile.
    #[cfg(not(feature = "harness"))]
    if let Some(flag) = scripted::harness_flag(&args) {
        end_launch(
            64,
            &format!("{flag} needs a build with the `harness` feature"),
        );
    }
    // An E2E pass runs inside the smoke pass (`--shots <dir>`): alone it
    // would open the app normally and report nothing.
    if scripted::options(&args).any(|a| a == "--e2e") && arg(&args, "--shots").is_none() {
        end_launch(64, "--e2e runs with --shots <dir>");
    }
    // A pass this OS doesn't run ends the launch before anything opens.
    if let Some(why) = unsupported_flag(paths::Os::CURRENT, &args) {
        end_launch(64, why);
    }
    // So does `--smoke` without its file.
    #[cfg(not(target_os = "macos"))]
    let smoke_path = smoke_file(&args).unwrap_or_else(|why| end_launch(64, why));
    // The smoke wrapper launches through `open`, which starts apps in `/`.
    if let Some((i, _)) = scripted::option_positions(&args).find(|(_, a)| *a == "--cwd")
        && let Some(dir) = args_os.get(i + 1)
    {
        std::env::set_current_dir(dir).ok();
    }
    // A scripted launch (a pass, the capture, a fixture) never asks for a
    // permission: see `scripted`.
    scripted::set(scripted::requested(&args));
    // The web views' media policy in real web views (tests/web_media.rs).
    #[cfg(all(target_os = "macos", feature = "harness"))]
    if web_media_fixture::requested(&args) {
        web_media_fixture::run();
        return;
    }
    // The sidebar and palette over canned data (tests/a11y.rs, perf).
    #[cfg(all(target_os = "macos", feature = "harness"))]
    if let Some(mode) = fixture::Mode::from_args(&args) {
        fixture::run(mode);
        return;
    }
    // The workspace's list over 2,000 canned prompts (perf).
    #[cfg(all(target_os = "macos", feature = "harness"))]
    if workspace_fixture::requested(&args) {
        workspace_fixture::run();
        return;
    }
    // The agenda and the task list over canned data (perf).
    #[cfg(all(target_os = "macos", feature = "harness"))]
    if let Some(which) = calendar_fixture::requested(&args) {
        calendar_fixture::run(which);
        return;
    }
    let flavor = Flavor::detect();
    // With no home folder there is no private place for the profile or its
    // key, and a shared one (the temporary folder) is never used instead.
    let mut app_paths = match AppPaths::for_flavor(flavor) {
        Ok(paths) => paths,
        Err(e) => end_launch(1, &e.to_string()),
    };
    // A scripted run gets its own profile, logs and Keychain item.
    let scripted_run = is_scripted(&args);
    if scripted_run {
        let ordinary = app_profile(flavor);
        let stamp = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |d| d.as_nanos());
        let scratch =
            std::env::temp_dir().join(format!("conduit-harness-{}-{stamp}", std::process::id()));
        let named = std::env::var_os("CONDUIT_USER_DATA").map(PathBuf::from);
        let fresh = named.is_none();
        match harness_profile(named, ordinary.as_deref(), &scratch) {
            Ok(user_data) => app_paths.user_data = user_data,
            Err(e) => end_launch(64, &e),
        }
        if fresh && std::env::var_os("CONDUIT_LOGS").is_none() {
            app_paths.logs = scratch.join("logs");
        }
    }
    shell::crash::install(app_paths.logs.clone(), VERSION);
    // Off the Mac, links and files come as arguments, and a second launch of
    // a profile that runs hands them to that app and ends here (AppKit does
    // both on the Mac). The log file is the running app's until then: a
    // launch that only hands over writes nothing there (nor rotates it).
    #[cfg(not(target_os = "macos"))]
    let (launch_urls, instance) =
        match launch_urls(&args_os, &std::env::current_dir().unwrap_or_default()) {
            Some(urls) => {
                let instance = claim_instance(&app_paths, &urls);
                (urls, Some(instance))
            }
            None => (vec![], None),
        };
    shell::logger::install(&app_paths.logs);
    log::info!(
        "Conduit Desktop {VERSION} ({flavor:?}), userData {}",
        app_paths.user_data.display()
    );
    #[cfg(not(target_os = "macos"))]
    let instance = match instance {
        Some(Ok(listener)) => Some(listener),
        Some(Err(why)) => {
            log::warn!("{why}");
            None
        }
        None => None,
    };
    let shots = arg(&args, "--shots").map(PathBuf::from);
    #[cfg(all(target_os = "macos", feature = "harness"))]
    let probe = arg(&args, "--probe").map(PathBuf::from);
    #[cfg(all(target_os = "macos", feature = "harness"))]
    if let Some(path) = &probe
        && e2e::shell::probe_files(path).is_none()
    {
        eprintln!(
            "conduit-desktop: --probe {}: name a file whose .cmd and .quit files are others (say, state.json)",
            path.display()
        );
        std::process::exit(64);
    }
    #[cfg(target_os = "macos")]
    let smoke_options = smoke::SmokeOptions::from_args(&args);
    #[cfg(all(target_os = "macos", feature = "harness"))]
    let chat_fixture = chat_fixture::requested(&args);
    #[cfg(all(target_os = "macos", feature = "harness"))]
    let channel_fixture = channel_fixture::requested(&args);
    #[cfg(all(target_os = "macos", feature = "harness"))]
    let terminal_fixture = terminal_fixture::requested(&args);
    #[cfg(all(target_os = "macos", feature = "harness"))]
    let rooms_fixture = rooms_fixture::requested(&args);
    // `--capture <dir>`: screenshots and motion strips of every screen,
    // for design review (capture/).
    #[cfg(all(target_os = "macos", feature = "harness"))]
    let capture = capture::CaptureOptions::from_args(&args);
    #[cfg(all(target_os = "macos", feature = "harness"))]
    let scripted = shots.is_some() || capture.is_some();
    #[cfg(all(target_os = "macos", not(feature = "harness")))]
    let scripted = shots.is_some();
    // `--smoke <file>`: the pass's report, made before anything opens (a
    // launch that can't write it ends here), and its verdict after the quit.
    #[cfg(not(target_os = "macos"))]
    let smoke = smoke_path.map(|path| {
        let report = smoke_pass::SmokeReport::create(std::path::Path::new(&path))
            .unwrap_or_else(|e| end_launch(64, &format!("--smoke {path}: {e}")));
        std::rc::Rc::new(std::cell::RefCell::new(report))
    });
    #[cfg(not(target_os = "macos"))]
    let scripted = shots.is_some() || smoke.is_some();
    // `{{USER_LOCATION}}`: a scripted run (any pass, the capture, a probe
    // or a fixture: `scripted::active`) answers with a stand-in and never
    // reaches CoreLocation (no test may raise the system's prompt).
    shell::location::choose(
        scripted::active(),
        std::env::var("CONDUIT_LOCATION_STANDIN").ok(),
    );

    let app = gpui_kit::application().with_assets(crate::views::model_logo::AppAssets);
    // `conduit://` links and "Open with" files, cold launch included: they
    // can come before the app state exists, so they wait in a channel.
    let (urls_tx, urls_rx) = desktop::url_channel();
    #[cfg(not(target_os = "macos"))]
    {
        if !launch_urls.is_empty() {
            let _ = urls_tx.unbounded_send(launch_urls);
        }
        if let Some(instance) = instance {
            let urls_tx = urls_tx.clone();
            instance.serve(move |urls| urls_tx.unbounded_send(urls).is_ok());
        }
    }
    app.on_open_urls(move |urls| {
        let _ = urls_tx.unbounded_send(urls);
    });
    // The Dock icon: the main window, made again or shown again (it may
    // have been closed to the menu bar).
    app.on_reopen(|cx| {
        if cx.has_global::<AppState>() {
            desktop::show_main(cx);
        }
    });
    let hidden_arg = scripted::has(&args, "--hidden");
    #[cfg(not(target_os = "macos"))]
    let smoke_in_app = smoke.clone();
    app.run(move |cx: &mut App| {
        // The open-application Apple event is current only now.
        #[cfg(target_os = "macos")]
        let hidden = hidden_arg || shell::login_item::launched_as_login_item();
        #[cfg(not(target_os = "macos"))]
        let hidden = hidden_arg;
        // The Services menu's provider, before anything else: a launch made
        // for "Ask Conduit" delivers its request right after this.
        #[cfg(target_os = "macos")]
        let services = shell::services::install();
        gpui_kit::init(cx);
        menus::KitBindings::capture(cx);
        #[cfg(target_os = "linux")]
        cx.set_global(conduit_components::window::WindowAppId(
            app_paths.flavor.desktop_entry().into(),
        ));
        // Off the Mac the app draws its questions (the Mac attaches NSAlert
        // sheets): keyboard-driven, and taken down when settled elsewhere.
        #[cfg(not(target_os = "macos"))]
        {
            shell::app_prompt::install(cx);
            // Announcements as AccessKit live regions, and the fonts this
            // system has, before any window opens.
            conduit_components::announce::install_live_regions(cx);
            shell::system_look::resolve_fonts(cx);
        }
        conduit_components::views::markdown::preload_grammars(&["python", "rust", "bash"]);

        let system_dark = matches!(
            cx.window_appearance(),
            WindowAppearance::Dark | WindowAppearance::VibrantDark
        );
        let settings = cx.new(|_| {
            SettingsStore::load(
                app_paths.prefs_file(),
                system_dark,
                locale::system_languages(),
            )
        });
        settings.update(cx, |s, cx| s.apply(cx));
        #[cfg(not(target_os = "macos"))]
        shell::system_look::follow_accent(settings.clone(), cx);
        install_component_strings(cx);
        // The chat view over a fixture daemon (perf and AccessKit checks).
        #[cfg(all(target_os = "macos", feature = "harness"))]
        if let Some((mode, shots)) = chat_fixture.clone() {
            chat_fixture::run(mode, shots, settings.clone(), cx);
            return;
        }
        // A channel's timeline over a fixture daemon (perf).
        #[cfg(all(target_os = "macos", feature = "harness"))]
        if let Some((mode, shots)) = channel_fixture.clone() {
            channel_fixture::run(mode, shots, cx);
            return;
        }
        // The console under a flood of output (perf).
        #[cfg(all(target_os = "macos", feature = "harness"))]
        if terminal_fixture {
            terminal_fixture::run(cx);
            return;
        }
        // A Group Chat's pane over a fixture daemon (perf).
        #[cfg(all(target_os = "macos", feature = "harness"))]
        if rooms_fixture {
            rooms_fixture::run(cx);
            return;
        }
        let layout = cx.new(|_| LayoutStore::load(app_paths.window_state_file()));

        let connection = ConnectionStore::start(
            ConnectionOptions {
                paths: app_paths.clone(),
                binary: paths::locate_daemon(),
                master_key: {
                    let paths = app_paths.clone();
                    std::sync::Arc::new(move || master_key(&paths, scripted_run))
                },
                #[cfg(target_os = "linux")]
                key_file: {
                    let paths = app_paths.clone();
                    Some(std::sync::Arc::new(move || {
                        key_file_master_key(&paths, scripted_run).into()
                    }))
                },
                #[cfg(not(target_os = "linux"))]
                key_file: None,
                key_in_background: cfg!(target_os = "linux"),
                locale: locale::bcp47(settings.read(cx).locale()),
                client_version: VERSION.into(),
            },
            cx,
        );
        {
            let (settings, layout) = (settings.clone(), layout.clone());
            cx.subscribe(&connection, move |_, event, cx| match event {
                ConnectionEvent::LocalDataReset { .. } => {
                    settings.read(cx).save();
                    layout.read(cx).save_now();
                }
                ConnectionEvent::Connected { .. } => {
                    // The daemon keeps the app preferences mobile shares
                    // (theme, palette, text size, language): read them, and
                    // take them when this Mac has no preferences file of
                    // its own yet; else tell the daemon ours.
                    read_app_preferences(&settings, cx);
                }
                _ => {}
            })
            .detach();
        }
        let stores = Stores::install(connection.clone(), cx);
        views::release_notes::install(&stores, cx);
        stores.toast_account_notices(
            |notice, cx| {
                views::words::account_notice(&views::privacy::notice(notice, cx), cx.l10n())
            },
            cx,
        );
        cx.subscribe(&settings, |settings, event, cx| match event {
            SettingsEvent::LocaleChanged => {
                install_component_strings(cx);
                menus::set_menus(cx);
            }
            SettingsEvent::AppPreferencesChanged => push_app_preferences(&settings, cx),
            SettingsEvent::KeymapChanged => {
                let keymap = settings.read(cx).keymap();
                menus::bind_keys(&keymap, cx);
                menus::set_menus(cx);
            }
            // The shell extras follow it themselves (desktop::install); the
            // menus show Quick Ask's chord.
            SettingsEvent::DesktopChanged => {
                let keymap = settings.read(cx).keymap();
                menus::bind_keys(&keymap, cx);
                menus::set_menus(cx);
            }
        })
        .detach();

        // Before any window opens: transitions read it on their first frame.
        shell::reduce_motion::install(cx);

        // `system.network`: NWPathMonitor on the Mac; Windows' network
        // status and the Linux portal elsewhere (conduit_daemon::network).
        let network = {
            let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel();
            let report = move |online| {
                let _ = tx.send(online);
            };
            #[cfg(target_os = "macos")]
            let monitor = shell::macos::NetworkMonitor::start(report);
            #[cfg(not(target_os = "macos"))]
            let monitor = conduit_daemon::network::NetworkMonitor::start(report);
            let connection = connection.clone();
            cx.spawn(async move |cx| {
                while let Some(online) = rx.recv().await {
                    connection.update(cx, |c, cx| c.set_online(online, cx));
                }
            })
            .detach();
            monitor
        };

        cx.set_global(AppState {
            paths: app_paths.clone(),
            connection: connection.clone(),
            stores,
            settings: settings.clone(),
            layout,
            main_window: None,
            main_view: None,
            setup_window: None,
            settings_window: None,
            _network: network,
        });

        let keymap = settings.read(cx).keymap();
        sync_keyboard_access(cx);
        menus::bind_keys(&keymap, cx);
        menus::set_menus(cx);
        install_menu_observers(cx);
        register_actions(cx);
        desktop::install(urls_rx, hidden, cx);
        #[cfg(target_os = "macos")]
        desktop::install_services(services, cx);
        // Shortcuts, Siri and Spotlight: requests that came with the launch
        // and those that follow.
        intents::install(cx);
        updates::install(cx);
        // The setup window and the main window follow the session.
        windows::install(cx);
        // Settings › Keyboard records chords before bindings see them.
        shell::app_prompt::intercept_behind(cx, |event, _, cx| {
            let Some(settings) = cx.try_global::<AppState>().map(|s| s.settings.clone()) else {
                return;
            };
            if settings.update(cx, |s, cx| s.record(&event.keystroke, cx)) {
                cx.stop_propagation();
            }
        })
        .detach();
        #[cfg(not(target_os = "macos"))]
        let smoke_on_quit = smoke_in_app.clone();
        cx.on_app_quit(move |cx| {
            desktop::read_shown_chats_on_quit(cx);
            if let Some(state) = cx.try_global::<AppState>() {
                let (connection, settings, layout) = (
                    state.connection.clone(),
                    state.settings.clone(),
                    state.layout.clone(),
                );
                layout.read(cx).save_now();
                settings.read(cx).save();
                let stopped = connection.update(cx, |c, _| c.shutdown());
                #[cfg(not(target_os = "macos"))]
                if let Some(report) = &smoke_on_quit {
                    report.borrow_mut().daemon_stopped(stopped);
                }
                #[cfg(target_os = "macos")]
                let _ = stopped;
            }
            async {}
        })
        .detach();

        // A login launch with "Close to menu bar" on starts in the menu bar.
        // Otherwise the window the app fronted last: the main window on a
        // Mac that is set up, the setup window on first run (the route,
        // known once the daemon answers, swaps them if it disagrees).
        if hidden && desktop::closes_to_menu_bar(cx) && !scripted {
            log::info!("hidden start: menu-bar item only");
        } else {
            windows::show_front(cx);
        }

        #[cfg(target_os = "macos")]
        if let Some(dir) = shots {
            smoke::run(dir, smoke_options, cx);
        }
        #[cfg(all(target_os = "macos", feature = "harness"))]
        if let Some(options) = capture {
            capture::run(options, cx);
        }
        // The state a shell driver checks after `open -a` (links, files).
        #[cfg(all(target_os = "macos", feature = "harness"))]
        if let Some(path) = probe {
            e2e::shell::probe(path, cx);
        }
        #[cfg(not(target_os = "macos"))]
        if let Some(report) = smoke_in_app {
            smoke_pass::run(report, cx);
        }
        #[cfg(not(target_os = "macos"))]
        let _ = shots;
    });
    // Off the Mac, GPUI's run returns once the app has quit (and stopped the
    // daemon): the smoke pass's verdict is the exit code.
    #[cfg(not(target_os = "macos"))]
    if let Some(report) = smoke {
        std::process::exit(report.borrow_mut().finish());
    }
}

/// Follows System Settings › Keyboard Navigation (re-read whenever a window
/// of ours becomes active); `CONDUIT_FULL_KEYBOARD_ACCESS=1` or `0`
/// overrides it (the capture harness turns it on).
pub fn sync_keyboard_access(cx: &mut App) {
    use conduit_components::views::focus::KeyboardAccess;
    let all_controls = match std::env::var("CONDUIT_FULL_KEYBOARD_ACCESS").as_deref() {
        Ok("1") | Ok("true") => true,
        Ok("0") | Ok("false") => false,
        _ => {
            #[cfg(target_os = "macos")]
            {
                shell::macos::full_keyboard_access()
            }
            #[cfg(not(target_os = "macos"))]
            {
                true
            }
        }
    };
    let next = KeyboardAccess { all_controls };
    if cx.try_global::<KeyboardAccess>() != Some(&next) {
        cx.set_global(next);
        cx.refresh_windows();
    }
}

/// The menu bar follows the sidebar, the open chat, the folders, the
/// account (sharing) and the text size (zoom).
fn install_menu_observers(cx: &mut App) {
    let Some(state) = cx.try_global::<AppState>() else {
        return;
    };
    let (layout, navigation, chat_list, settings, accounts, session, speech) = (
        state.layout.clone(),
        state.stores.navigation.clone(),
        state.stores.chat_list.clone(),
        state.settings.clone(),
        state.stores.accounts.clone(),
        state.stores.session.clone(),
        state.stores.speech.clone(),
    );
    cx.observe(&settings, |_, cx| menus::refresh_menus(cx))
        .detach();
    cx.observe(&accounts, |_, cx| menus::refresh_menus(cx))
        .detach();
    cx.observe(&layout, |_, cx| menus::refresh_menus(cx))
        .detach();
    cx.observe(&navigation, |_, cx| menus::refresh_menus(cx))
        .detach();
    cx.observe(&chat_list, |_, cx| menus::refresh_menus(cx))
        .detach();
    // The Go menu's sections follow the account's capabilities and route.
    cx.observe(&session, |_, cx| menus::refresh_menus(cx))
        .detach();
    // Chat › Stop Speaking follows whether anything is read: not every word.
    let mut reading = false;
    cx.observe(&speech, move |speech, cx| {
        let now = speech.read(cx).is_active();
        if now != reading {
            reading = now;
            menus::refresh_menus(cx);
        }
    })
    .detach();
}

/// Close Window (⌘W, Ctrl+W) for `w`, when nothing in it took the key.
fn close_window(w: AnyWindowHandle, cx: &mut App) {
    // A window with Add Account's sheet down: ⌘W cancels the sheet.
    if let Some((handle, view)) = cx
        .try_global::<AppState>()
        .and_then(|s| s.settings_window.clone())
        && let Some(sheet) = view.read(cx).add_sheet.clone()
        && (handle == w || sheet.handle == w)
    {
        sheet.view.update(cx, |s, cx| s.cancel(cx));
        return;
    }
    // The main window with "Close to menu bar" on only hides.
    let main = cx.try_global::<AppState>().and_then(|s| s.main_window);
    if main == Some(w) && desktop::closes_to_menu_bar(cx) {
        log::info!("close window: hiding the main window");
        desktop::hide_main(cx);
        return;
    }
    // Quick Ask hides; its exchange stays for next time.
    if desktop::is_quick_ask_window(w, cx) {
        desktop::hide_quick_ask(cx);
        return;
    }
    if main == Some(w) {
        desktop::main_window_leaving(cx);
    }
    let _ = w.update(cx, |_, window, _| window.remove_window());
}

/// Runs `f` on the window in front once it is free: a key's binding, and a
/// row of ☰, run inside that window's own update, where it can't be
/// updated again.
fn with_active_window(cx: &mut App, f: impl FnOnce(&mut gpui_kit::Window) + 'static) {
    let Some(w) = cx.active_window() else {
        return;
    };
    cx.defer(move |cx| {
        let _ = w.update(cx, |_, window, _| f(window));
    });
}

fn register_actions(cx: &mut App) {
    views::chat::remote_image::register(cx);
    cx.on_action(|_: &Quit, cx| crate::views::sheet::quit(cx));
    cx.on_action(|_: &About, cx| open_settings(Some(Tab::About), cx));
    cx.on_action(|_: &Hide, cx| cx.hide());
    cx.on_action(|_: &HideOthers, cx| cx.hide_other_apps());
    cx.on_action(|_: &ShowAll, cx| cx.unhide_other_apps());
    // ⌘W when no element took it (the main window and Quick Ask handle it
    // themselves when they have focus).
    cx.on_action(|_: &CloseWindow, cx| {
        let Some(w) = cx.active_window() else {
            log::info!("close window: no active window");
            return;
        };
        cx.defer(move |cx| close_window(w, cx));
    });
    cx.on_action(|_: &ToggleQuickAsk, cx| {
        cx.defer(desktop::toggle_quick_ask);
    });
    cx.on_action(|_: &Minimize, cx| {
        with_active_window(cx, |window| window.minimize_window());
    });
    cx.on_action(|_: &Zoom, cx| with_active_window(cx, |window| window.zoom_window()));
    cx.on_action(|_: &ToggleFullScreen, cx| {
        with_active_window(cx, |window| window.toggle_fullscreen());
    });
    cx.on_action(|_: &BringAllToFront, _| {
        #[cfg(target_os = "macos")]
        shell::macos::bring_all_to_front();
    });
    cx.on_action(|_: &OpenHelp, cx| cx.open_url(HELP_URL));
    views::chat_pane::register_actions(cx);
    views::chat::rows::register_actions(cx);
    cx.on_action(|_: &OpenSettings, cx| open_settings(None, cx));
    cx.on_action(|_: &ShowShortcuts, cx| open_settings(Some(Tab::Keyboard), cx));
    // New Chat and ⌘K from another window (Settings): the main window's.
    cx.on_action(|_: &NewChat, cx| {
        open_main_window(cx);
        with_main_view(cx, |view, window, cx| view.new_chat(false, window, cx));
    });
    cx.on_action(|_: &OpenPalette, cx| {
        open_main_window(cx);
        with_main_view(cx, |view, window, cx| view.toggle_palette(window, cx));
    });
    cx.on_action(|_: &NewTemporaryChat, cx| {
        open_main_window(cx);
        with_main_view(cx, |view, window, cx| view.new_chat(true, window, cx));
    });
    // The sidebar's menu commands, when nothing in the main window has
    // focus (the path from the root then misses its handlers).
    cx.on_action(|a: &views::sidebar::ChatMenu, cx| {
        let (id, command) = (a.chat_id.clone(), a.command.clone());
        with_main_view(cx, |view, window, cx| {
            view.sidebar
                .update(cx, |s, cx| s.run(&id, command, window, cx))
        });
    });
    cx.on_action(|a: &views::hermes_sessions::HermesMenu, cx| {
        let (id, command) = (a.session_id.clone(), a.command);
        with_main_view(cx, |view, window, cx| {
            view.run_hermes(&id, command, window, cx)
        });
    });
    // Notes: a note's menu, New Note, and the note pane's toolbar
    // menus, wherever the focus is.
    cx.on_action(|a: &views::notes::NoteMenu, cx| {
        let (id, command) = (a.note_id.clone(), a.command);
        with_main_view(cx, |view, window, cx| {
            let stores = view.stores.clone();
            views::notes::run(&stores, &id, command, window, cx)
        });
    });
    cx.on_action(|_: &views::notes::NewNote, cx| {
        let Some(stores) = cx.try_global::<AppState>().map(|s| s.stores.clone()) else {
            return;
        };
        // Only where the account has notes.
        if stores.session.read(cx).capabilities().notes {
            views::notes::new_note(&stores, cx);
        }
    });
    cx.on_action(|a: &views::notes::pane::PaneCommand, cx| {
        let (id, command) = (a.note_id.clone(), a.command.clone());
        with_main_view(cx, |view, window, cx| {
            let pane = view.area_pane.read(cx).notes.read(cx).note_pane().cloned();
            if let Some(pane) = pane
                && pane.read(cx).shows(&id)
            {
                pane.update(cx, |p, cx| p.run(command, window, cx));
            }
        });
    });
    cx.on_action(|a: &views::sidebar::FolderMenu, cx| {
        let (id, command) = (a.folder_id.clone(), a.command.clone());
        with_main_view(cx, |view, window, cx| {
            view.sidebar
                .update(cx, |s, cx| s.run_folder(&id, command, window, cx))
        });
    });
    cx.on_action(|a: &views::sidebar::ActOnSelected, cx| {
        let action = a.action;
        with_main_view(cx, |view, window, cx| {
            view.sidebar
                .update(cx, |s, cx| s.bulk(action, None, window, cx))
        });
    });
    cx.on_action(|a: &views::sidebar::MoveSelected, cx| {
        let folder = a.folder_id.clone();
        with_main_view(cx, |view, window, cx| {
            view.sidebar.update(cx, |s, cx| {
                s.bulk(conduit_protocol::BulkChatAction::Move, folder, window, cx)
            })
        });
    });
    cx.on_action(|_: &ToggleSidebar, cx| {
        if let Some(layout) = cx.try_global::<AppState>().map(|s| s.layout.clone()) {
            layout.update(cx, |l, cx| l.toggle_sidebar(cx));
        }
    });
    // ⌥⌘↩ / ⌥⌘⌫ when the main window does not have focus (Settings, the
    // SSO window): the main window's card answers.
    cx.on_action(|_: &AllowRequest, cx| {
        if let Some(view) = cx
            .try_global::<AppState>()
            .and_then(|s| s.main_view.clone())
        {
            view.update(cx, |v, cx| v.answer_request(true, cx));
        }
    });
    cx.on_action(|_: &DenyRequest, cx| {
        if let Some(view) = cx
            .try_global::<AppState>()
            .and_then(|s| s.main_view.clone())
        {
            view.update(cx, |v, cx| v.answer_request(false, cx));
        }
    });
    cx.on_action(|action: &SetLocale, cx| {
        if let Some(settings) = cx.try_global::<AppState>().map(|s| s.settings.clone()) {
            let locale = action.locale.clone();
            settings.update(cx, |s, cx| s.set_locale(locale, cx));
        }
    });
}

pub(crate) fn main_window_alive(cx: &mut App) -> bool {
    let Some(handle) = cx.try_global::<AppState>().and_then(|s| s.main_window) else {
        return false;
    };
    handle.update(cx, |_, _, _| ()).is_ok()
}

/// Opens (or raises) the window the app fronts with: the main window while
/// there is a session, else the setup window ([`windows`]). The Dock, the
/// menu-bar item, links and New Chat from another window come here.
pub fn open_main_window(cx: &mut App) {
    windows::open_front(cx);
}

/// Opens (or raises) the main window at the saved geometry.
pub(crate) fn open_main(cx: &mut App) {
    if main_window_alive(cx) {
        if let Some(h) = cx.global::<AppState>().main_window {
            let _ = h.update(cx, |_, window, cx| {
                conduit_components::chrome::activate(window, cx)
            });
        }
        return;
    }
    let state = cx.global::<AppState>();
    let (stores, settings, layout) = (
        state.stores.clone(),
        state.settings.clone(),
        state.layout.clone(),
    );
    let bounds = layout.read(cx).initial_bounds(cx);
    let rect = match bounds {
        gpui_kit::WindowBounds::Windowed(b)
        | gpui_kit::WindowBounds::Maximized(b)
        | gpui_kit::WindowBounds::Fullscreen(b) => b,
    };
    let mut options = cw::window_options("Conduit", rect, true, true);
    options.window_bounds = Some(bounds);
    // GNOME-style header bars are the window's frame. The window manager
    // may frame it anyway (no compositor); the chrome then draws no
    // window controls.
    if conduit_components::chrome::ChromeStyle::native()
        == Some(conduit_components::chrome::ChromeStyle::Gnome)
    {
        options.window_decorations = Some(gpui_kit::WindowDecorations::Client);
    }
    match cw::open_window_clear_root(options, cx, |window, cx| {
        cx.new(|cx| MainWindow::new(stores, settings, layout, window, cx))
    }) {
        Ok((handle, view)) => {
            let state = cx.global_mut::<AppState>();
            state.main_window = Some(handle);
            state.main_view = Some(view);
            // "Close to menu bar": closing hides the window instead.
            let _ = handle.update(cx, |_, window, cx| {
                window.on_window_should_close(cx, |_, cx| desktop::main_should_close(cx));
            });
            // Links that waited for the window.
            cx.defer(desktop::drain);
        }
        Err(e) => log::error!("could not open the main window: {e}"),
    }
}

/// Runs `f` on the main window's view, with its window.
pub(crate) fn with_main_view(
    cx: &mut App,
    f: impl FnOnce(&mut MainWindow, &mut gpui_kit::Window, &mut gpui_kit::Context<MainWindow>),
) {
    let Some(state) = cx.try_global::<AppState>() else {
        return;
    };
    let (Some(handle), Some(view)) = (state.main_window, state.main_view.clone()) else {
        return;
    };
    let _ = handle.update(cx, |_, window, cx| {
        conduit_components::chrome::activate(window, cx);
        view.update(cx, |v, cx| f(v, window, cx));
    });
}

/// "Add account" (Settings › Accounts): a window sheet on Settings, as
/// Mail and System Settings › Internet Accounts add an account; sign-in
/// for it follows in the setup window.
pub fn start_adding_account(cx: &mut App) {
    open_settings(Some(Tab::Accounts), cx);
    let Some((handle, view)) = cx
        .try_global::<AppState>()
        .and_then(|s| s.settings_window.clone())
    else {
        return;
    };
    let _ = handle.update(cx, |_, window, cx| {
        conduit_components::chrome::activate(window, cx);
        view.update(cx, |v, cx| v.open_add_sheet(window, cx));
    });
}

/// Brings the main window to the front.
pub fn activate_main_window(cx: &mut App) {
    if let Some(handle) = cx.try_global::<AppState>().and_then(|s| s.main_window) {
        let _ = handle.update(cx, |_, window, cx| {
            conduit_components::chrome::activate(window, cx)
        });
    }
}

/// `settings.getApp` at connect: a profile with no preferences file yet (a
/// first run, or the file was lost) takes the daemon's stored theme,
/// palette, text size and language; one with a file keeps its own and
/// sends them (`settings.setApp`), as before.
fn read_app_preferences(settings: &Entity<SettingsStore>, cx: &mut App) {
    let Some(state) = cx.try_global::<AppState>() else {
        return;
    };
    let connection = state.connection.read(cx);
    if !connection.is_connected() {
        return;
    }
    if settings.read(cx).has_file() {
        push_app_preferences(settings, cx);
        return;
    }
    let call = connection
        .rpc()
        .call::<conduit_protocol::methods::SettingsGetApp>(&conduit_protocol::NoParams);
    let settings = settings.clone();
    cx.spawn(async move |cx| {
        match call.await {
            Ok(stored) => {
                // A choice made on this Mac while the read was out wins.
                settings.update(cx, |s, cx| {
                    if !s.has_file() {
                        s.adopt_app_preferences(&stored, cx);
                    }
                });
                cx.update(|cx| push_app_preferences(&settings, cx));
            }
            // Unread, the account's own stay as they are: this Mac's
            // defaults never go over them (the next connect asks again).
            Err(e) => log::debug!("settings.getApp: {e}"),
        }
    })
    .detach();
}

/// `settings.setApp` with this window's appearance and language.
fn push_app_preferences(settings: &Entity<SettingsStore>, cx: &mut App) {
    let Some(state) = cx.try_global::<AppState>() else {
        // Before the app state exists: the first connect sends them.
        return;
    };
    let connection = state.connection.read(cx);
    if !connection.is_connected() {
        return;
    }
    let patch = stores::settings::app_preferences(&settings.read(cx).prefs);
    let call = connection
        .rpc()
        .call::<conduit_protocol::methods::SettingsSetApp>(&patch);
    cx.background_spawn(async move {
        if let Err(e) = call.await {
            log::debug!("settings.setApp: {e}");
        }
    })
    .detach();
}

/// The components' strings for the current locale.
pub(crate) fn install_component_strings(cx: &mut App) {
    let strings = cx
        .try_global::<L10n>()
        .map(l10n::components::component_strings)
        .unwrap_or_default();
    cx.set_global(strings);
}

/// Opens (or raises) Settings, on `tab` when given.
pub fn open_settings(tab: Option<Tab>, cx: &mut App) {
    if let Some((handle, view)) = cx.global::<AppState>().settings_window.clone()
        && handle
            .update(cx, |_, window, cx| {
                conduit_components::chrome::activate(window, cx)
            })
            .is_ok()
    {
        if let Some(tab) = tab {
            view.update(cx, |v, cx| v.show_tab(tab, cx));
        }
        return;
    }
    let state = cx.global::<AppState>();
    let (settings, stores) = (state.settings.clone(), state.stores.clone());
    let title = cx.l10n().desktop_settings_title();
    let bounds = Bounds::centered(None, size(px(SETTINGS_SIZE.0), px(SETTINGS_SIZE.1)), cx);
    let mut options = cw::window_options(&title, bounds, true, true);
    if let Some(titlebar) = options.titlebar.as_mut() {
        titlebar.appears_transparent = cw::OS_TITLE_BAR_TRANSPARENT;
    }
    let tab = tab.unwrap_or(Tab::FIRST);
    match cw::open_window_clear_root(options, cx, |window, cx| {
        cx.new(|cx| SettingsView::new(settings, stores, tab, window, cx))
    }) {
        Ok((handle, view)) => {
            cx.global_mut::<AppState>().settings_window = Some((handle, view));
            // A chord being recorded is the window's: once it closes, keys go
            // back to the app (the view itself lives on in AppState until
            // this lets it go).
            let _ = handle.update(cx, |_, window, cx| {
                window.on_window_should_close(cx, |_, cx| {
                    let settings = cx.global::<AppState>().settings.clone();
                    settings.update(cx, |s, cx| s.stop_recording(cx));
                    cx.global_mut::<AppState>().settings_window = None;
                    true
                });
            });
        }
        Err(e) => log::error!("could not open Settings: {e}"),
    }
}

#[cfg(test)]
mod window_action_tests {
    use super::*;
    use gpui_kit::prelude::*;
    use gpui_kit::{FocusHandle, KeyBinding, TestAppContext, VisualTestContext, div};

    /// A window whose view answers none of the window commands itself (as
    /// Settings): they reach the app's handlers.
    struct Plain(FocusHandle);

    impl gpui_kit::Render for Plain {
        fn render(
            &mut self,
            _: &mut gpui_kit::Window,
            _: &mut gpui_kit::Context<Self>,
        ) -> impl IntoElement {
            div().track_focus(&self.0).size_full()
        }
    }

    fn plain_window(cx: &mut TestAppContext) -> (AnyWindowHandle, &mut VisualTestContext) {
        cx.update(|cx| {
            register_actions(cx);
            cx.bind_keys([
                KeyBinding::new("f11", ToggleFullScreen, None),
                KeyBinding::new("ctrl-w", CloseWindow, None),
            ]);
        });
        let (_, vcx) = cx.add_window_view(|window, cx| {
            let focus = cx.focus_handle();
            window.focus(&focus, cx);
            Plain(focus)
        });
        let handle = vcx.update(|window, _| {
            window.activate_window();
            window.window_handle()
        });
        (handle, vcx)
    }

    /// A key's binding runs inside the window's own update, where that
    /// window can't be updated again: F11 (View › Enter Full Screen off the
    /// Mac, and ☰'s row) still reaches it.
    #[gpui_kit::test]
    fn full_screen_from_a_key_reaches_the_window(cx: &mut TestAppContext) {
        let (_, vcx) = plain_window(cx);
        vcx.simulate_keystrokes("f11");
        vcx.run_until_parked();
        assert!(
            vcx.update(|window, _| window.is_fullscreen()),
            "F11 left the window as it was"
        );
    }

    /// Ctrl+W in a window that doesn't answer Close Window itself (Settings
    /// off the Mac) closes it.
    #[gpui_kit::test]
    fn close_window_from_a_key_closes_the_window(cx: &mut TestAppContext) {
        let (handle, vcx) = plain_window(cx);
        vcx.simulate_keystrokes("ctrl-w");
        vcx.run_until_parked();
        assert!(
            vcx.cx.update(|cx| handle.update(cx, |_, _, _| ()).is_err()),
            "Ctrl+W left the window open"
        );
    }
}

#[cfg(test)]
mod harness_profile_tests {
    use super::*;

    /// `--probe` drives the Mac's shell only: elsewhere it is refused before
    /// anything opens, never a launch on the real profile beside the app.
    /// Linux runs on XWayland where the session has both (D2), whoever
    /// starts the app, unless `CONDUIT_WAYLAND=1` keeps Wayland.
    /// Every reader of the harness's flags agrees with `is_scripted` on what
    /// is a flag: a folder named `--capture` (or `--e2e`, `--fixture`, ...),
    /// given to `--cwd`, starts no capture, pass or fixture on the app's
    /// own profile, and a real flag still does.
    #[cfg(all(target_os = "macos", feature = "harness"))]
    #[test]
    fn no_harness_reader_takes_a_flags_value_for_a_flag() {
        let args = |a: &[&str]| a.iter().map(|s| s.to_string()).collect::<Vec<_>>();
        let capture = args(&["app", "--cwd", "--capture", "out"]);
        assert!(!is_scripted(&capture));
        assert!(crate::capture::CaptureOptions::from_args(&capture).is_none());
        assert!(
            crate::e2e::E2eInputs::from_args(&args(&["app", "--cwd", "--e2e", "chat"])).is_none()
        );
        assert!(fixture::Mode::from_args(&args(&["app", "--cwd", "--fixture", "a11y"])).is_none());
        assert!(
            chat_fixture::requested(&args(&["app", "--cwd", "--chat-fixture", "a11y"])).is_none()
        );
        assert!(!rooms_fixture::requested(&args(&[
            "app",
            "--cwd",
            "--rooms-fixture"
        ])));
        assert!(!web_media_fixture::requested(&args(&[
            "app",
            "--cwd",
            "--fixture",
            "web-media"
        ])));
        assert!(
            crate::capture::CaptureOptions::from_args(&args(&["app", "--capture", "out"]))
                .is_some()
        );
        assert!(rooms_fixture::requested(&args(&["app", "--rooms-fixture"])));
    }

    /// A launch the profile's app didn't take says why in a small file of
    /// its own beside the log, one line each, never in the running app's
    /// rotating log.
    #[test]
    fn a_refused_launch_is_noted_beside_the_log() {
        let logs = tempfile::tempdir().unwrap();
        let at = std::time::UNIX_EPOCH + std::time::Duration::from_secs(1_800_000_000);
        note_refused_launch(
            logs.path(),
            at,
            "Conduit is already running but isn't responding",
        );
        note_refused_launch(logs.path(), at, "something holds this profile");
        let noted = std::fs::read_to_string(logs.path().join("launch-refused.log")).unwrap();
        assert_eq!(
            noted,
            "2027-01-15T08:00:00Z Conduit is already running but isn't responding\n\
             2027-01-15T08:00:00Z something holds this profile\n"
        );
        assert!(!logs.path().join("conduit-desktop.log").exists());
    }

    #[test]
    fn linux_prefers_xwayland_unless_asked_not_to() {
        let os = |v: &'static str| Some(std::ffi::OsStr::new(v));
        assert!(prefer_xwayland(os(":0"), os("wayland-0"), None));
        assert!(prefer_xwayland(os(":0"), os("wayland-0"), os("0")));
        assert!(!prefer_xwayland(os(":0"), os("wayland-0"), os("1")));
        assert!(!prefer_xwayland(None, os("wayland-0"), None), "no X server");
        assert!(!prefer_xwayland(os(""), os("wayland-0"), None));
        assert!(!prefer_xwayland(os(":0"), None, None), "X11 already");
    }

    /// A pass or probe an OS doesn't run is refused there before anything
    /// opens (said with the flag first): `--probe` and `--shots` drive the
    /// Mac's shell, and `--smoke` is their pass off the Mac, whose exit code
    /// only Windows and Linux can give (AppKit ends a quitting app itself).
    #[test]
    fn each_pass_is_refused_where_it_does_not_run() {
        let args = |a: &[&str]| a.iter().map(|s| s.to_string()).collect::<Vec<_>>();
        let refused = |os, a: &[&str]| {
            unsupported_flag(os, &args(a)).map(|why| why.split(' ').next().unwrap().to_string())
        };
        let (mac, linux, windows) = (paths::Os::MacOs, paths::Os::Linux, paths::Os::Windows);
        let probe = ["app", "--probe", "state.json"];
        assert_eq!(refused(linux, &probe).as_deref(), Some("--probe"));
        assert_eq!(refused(windows, &probe).as_deref(), Some("--probe"));
        assert_eq!(refused(mac, &probe), None);
        let shots = ["app", "--shots", "/tmp/shots"];
        assert_eq!(refused(linux, &shots).as_deref(), Some("--shots"));
        assert_eq!(refused(windows, &shots).as_deref(), Some("--shots"));
        assert_eq!(refused(mac, &shots), None);
        let smoke = ["app", "--smoke", "/tmp/smoke.txt"];
        assert_eq!(refused(mac, &smoke).as_deref(), Some("--smoke"));
        assert_eq!(refused(linux, &smoke), None);
        assert_eq!(refused(windows, &smoke), None);
        assert_eq!(refused(linux, &["app", "--hidden"]), None);
        // A folder named `--probe` (or `--smoke`), given to `--cwd`, is a
        // folder.
        assert_eq!(
            refused(linux, &["app", "--cwd", "--probe", "notes.md"]),
            None
        );
        assert_eq!(refused(mac, &["app", "--cwd", "--smoke", "notes.md"]), None);
        assert_eq!(
            refused(
                windows,
                &["app", "--cwd", r"C:\notes", "--probe", "state.json"]
            )
            .as_deref(),
            Some("--probe")
        );
    }

    /// `--smoke` without its file is refused before anything opens, as is
    /// another flag where the file goes: either would open the app as usual,
    /// and whatever waits for the pass's verdict would wait for good.
    #[test]
    fn the_smoke_pass_needs_its_file() {
        let args = |a: &[&str]| a.iter().map(|s| s.to_string()).collect::<Vec<_>>();
        assert!(smoke_file(&args(&["app", "--smoke"])).is_err());
        assert!(smoke_file(&args(&["app", "--smoke", "--hidden"])).is_err());
        assert!(smoke_file(&args(&["app", "--hidden", "--smoke", "-"])).is_err());
        assert_eq!(
            smoke_file(&args(&["app", "--smoke", "/tmp/smoke.txt"])),
            Ok(Some("/tmp/smoke.txt".into()))
        );
        assert_eq!(smoke_file(&args(&["app", "--hidden"])), Ok(None));
        // A folder named `--smoke`, given to `--cwd`, asks for no pass.
        assert_eq!(
            smoke_file(&args(&["app", "--cwd", "--smoke", "notes.md"])),
            Ok(None)
        );
    }

    #[test]
    fn a_scripted_launch_opens_nothing_from_its_arguments() {
        let args = |a: &[&str]| a.iter().map(std::ffi::OsString::from).collect::<Vec<_>>();
        let cwd = std::path::Path::new("/tmp/launch");
        for scripted in [
            &["app", "--shots", "/tmp/shots", "--e2e", "chat"][..],
            &["app", "--chat-fixture", "shots"],
            &["app", "--shots", "/tmp/shots", "--smoke-reset"],
            &["app", "--smoke", "/tmp/smoke.txt"],
        ] {
            assert_eq!(launch_urls(&args(scripted), cwd), None, "{scripted:?}");
        }
        // On the app's own profile, a launch claims it whatever its flags:
        // `--smoke-reset` is an option of the `--shots` pass, and alone it
        // opens the app as usual. (`--probe` is refused off the Mac first.)
        assert_eq!(
            launch_urls(&args(&["app", "--smoke-reset"]), cwd),
            Some(vec![])
        );
        assert_eq!(
            launch_urls(&args(&["app", "--hidden", "conduit://chat/c1"]), cwd),
            Some(vec!["conduit://chat/c1".to_string()])
        );
    }

    #[test]
    fn a_scripted_run_never_uses_a_profile_it_was_not_given() {
        let args = |a: &[&str]| a.iter().map(|s| s.to_string()).collect::<Vec<_>>();
        assert!(is_scripted(&args(&[
            "app", "--shots", "/tmp/s", "--e2e", "chat"
        ])));
        assert!(is_scripted(&args(&["app", "--e2e", "chat"])));
        assert!(is_scripted(&args(&["app", "--capture", "/tmp/c"])));
        assert!(is_scripted(&args(&["app", "--smoke", "/tmp/smoke.txt"])));
        // A fixture saves its own settings (the shots' theme), with or
        // without `--shots`.
        assert!(is_scripted(&args(&["app", "--chat-fixture", "shots"])));
        assert!(is_scripted(&args(&["app", "--fixture", "web-media"])));
        assert!(!is_scripted(&args(&["app", "--hidden"])));
        assert!(!is_scripted(&args(&["app", "--cwd", "/tmp/fixture"])));
        // A flag's value is never a flag: a folder named `--shots`, given to
        // `--cwd`, is a folder, and the launch is the app's.
        let folder = args(&["app", "--cwd", "--shots", "notes.md"]);
        assert!(!is_scripted(&folder));
        assert!(!scripted::requested(&folder));
        assert_eq!(arg(&folder, "--shots"), None);
        assert_eq!(arg(&folder, "--cwd").as_deref(), Some("--shots"));
        // A launch folder absolute on every OS (Windows needs its drive).
        let launch = tempfile::tempdir().unwrap();
        let notes = url::Url::from_file_path(launch.path().join("notes.md")).unwrap();
        assert_eq!(
            launch_urls(
                &folder
                    .iter()
                    .map(std::ffi::OsString::from)
                    .collect::<Vec<_>>(),
                launch.path()
            ),
            Some(vec![notes.to_string()])
        );

        let ordinary =
            std::path::Path::new("/Users/example/Library/Application Support/Conduit Dev");
        let scratch = std::path::Path::new("/tmp/conduit-harness-1");
        // None named: a fresh one, never the app's own.
        assert_eq!(
            harness_profile(None, Some(ordinary), scratch).unwrap(),
            scratch.join("user-data")
        );
        // The app's own profile, named: refused.
        assert!(harness_profile(Some(ordinary.to_path_buf()), Some(ordinary), scratch).is_err());
        // Another profile the caller named: that one.
        let named = std::path::PathBuf::from("/tmp/e2e-profile-7");
        assert_eq!(
            harness_profile(Some(named.clone()), Some(ordinary), scratch).unwrap(),
            named
        );
        assert_eq!(
            harness_service(Flavor::Dev),
            "app.cogwheel.conduit.desktop.dev.harness"
        );
        // The passes' own check before a reset.
        let paths = |user_data: PathBuf| AppPaths {
            flavor: Flavor::Dev,
            user_data,
            logs: PathBuf::from("/tmp/logs"),
        };
        assert!(!may_reset_profile(&paths(
            app_profile(Flavor::Dev).unwrap()
        )));
        assert!(may_reset_profile(&paths(scratch.join("user-data"))));
    }
}
