//! Updates: the platform's updater as a GPUI global, the app menu's
//! "Check for Updates…", and what Settings › About shows.
//!
//! Each platform plugs in an [`Updater`]: Sparkle on the Mac, in release
//! bundles only (see [`crate::shell::updater`]); WinSparkle on Windows
//! ([`winsparkle`]) and a signed "new version available" notice on Linux
//! ([`notice`]), in builds their packaging gave a feed and a public key
//! ([`config`]). Without one, the menu item stays disabled (GPUI's menus
//! disable items whose action has no handler) and About says updates come
//! with the installed app. Releases are stable only: there is no channel to
//! choose.

use futures::channel::oneshot;
use gpui_kit::{App, Global};

use crate::actions::CheckForUpdates;

#[cfg(any(not(target_os = "macos"), test))]
mod checks;
#[cfg(any(not(target_os = "macos"), test))]
mod config;
#[cfg(any(target_os = "linux", test))]
mod feed;
#[cfg(target_os = "linux")]
mod notice;
#[cfg(windows)]
mod winsparkle;

/// What the menu and Settings › About ask of a platform's updater.
pub trait Updater {
    /// Whether a check can start now (not while one runs).
    fn can_check(&self) -> bool;
    /// "Check for Updates…": the updater shows what it finds itself.
    fn check_for_updates(&self);
    /// "Check automatically", a setting the updater keeps.
    fn automatic_checks(&self) -> bool;
    fn set_automatic_checks(&self, on: bool);
    /// A check that shows nothing unless it finds a newer version; what it
    /// comes to goes to [`next_outcome`]. False for an updater that reports
    /// no outcome (Sparkle).
    fn check_quietly(&self) -> bool {
        false
    }
    /// What this updater's checks came to, for About to say (the Linux
    /// notice; Sparkle and WinSparkle say it in their own windows).
    fn status(&self) -> Option<Status> {
        None
    }
}

/// What About says of the Linux notice's checks.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Status {
    /// A newer release, which About offers to download.
    Available(Found),
    UpToDate,
    Failed,
}

/// A newer release the user installs themselves.
#[derive(Clone, Debug, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct Found {
    pub version: String,
    /// Where they get it (its GitHub release).
    pub page: String,
}

/// What a check on Windows or Linux came to.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Outcome {
    UpToDate,
    /// A newer version: its number when the updater says (WinSparkle names
    /// it only in its own window).
    Found(Option<String>),
    Failed(String),
}

impl std::fmt::Display for Outcome {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::UpToDate => f.write_str("up to date"),
            Self::Found(Some(version)) => write!(f, "found {version}"),
            Self::Found(None) => f.write_str("found a newer version"),
            Self::Failed(why) => write!(f, "failed: {why}"),
        }
    }
}

/// The running updater, when this build has one.
pub struct Updates {
    updater: Option<Box<dyn Updater>>,
    /// Waiting for the next check's outcome.
    waiting: Vec<oneshot::Sender<Outcome>>,
}

impl Global for Updates {}

/// Starts this platform's updater, if it has one.
pub fn install(cx: &mut App) {
    let updater = start(cx);
    let available = updater.is_some();
    cx.set_global(Updates {
        updater,
        waiting: Vec::new(),
    });
    if available {
        cx.on_action(|_: &CheckForUpdates, cx| check_for_updates(cx));
    }
}

#[cfg(target_os = "macos")]
fn start(_cx: &mut App) -> Option<Box<dyn Updater>> {
    match crate::shell::updater::Sparkle::start() {
        Ok(sparkle) => {
            log::info!("updates: Sparkle started");
            Some(Box::new(sparkle))
        }
        Err(why) => {
            log::info!("updates: no updater ({why:?})");
            None
        }
    }
}

#[cfg(any(windows, target_os = "linux"))]
fn start(cx: &mut App) -> Option<Box<dyn Updater>> {
    let config =
        config::Config::from_build(config::FEED_URL, config::PUBLIC_ED_KEY, crate::VERSION);
    let config = match config {
        Ok(config) => config,
        Err(why) => {
            log::info!("updates: no updater ({why:?})");
            return None;
        }
    };
    log::info!(
        "updates: {} (build {}) reads {}, signed by {}",
        config.version,
        config.build,
        config.feed_url,
        config.public_key
    );
    let user_data = cx.try_global::<crate::AppState>()?.paths.user_data.clone();
    let checks = checks::Checks::path(&user_data);
    #[cfg(windows)]
    {
        use crate::l10n::ActiveL10n as _;
        let locale = cx.l10n().locale().to_string();
        match winsparkle::WinSparkle::start(&config, &locale, checks, cx) {
            Ok(updater) => {
                log::info!("updates: WinSparkle started");
                Some(Box::new(updater))
            }
            Err(why) => {
                log::info!("updates: no updater ({why:?})");
                None
            }
        }
    }
    #[cfg(target_os = "linux")]
    {
        let key = config::parse_public_key(&config.public_key)?;
        Some(Box::new(notice::Notice::start(config, key, checks, cx)))
    }
}

#[cfg(not(any(target_os = "macos", windows, target_os = "linux")))]
fn start(_cx: &mut App) -> Option<Box<dyn Updater>> {
    None
}

fn updater(cx: &App) -> Option<&dyn Updater> {
    cx.try_global::<Updates>()
        .and_then(|u| u.updater.as_deref())
}

/// Whether this build updates itself.
pub fn available(cx: &App) -> bool {
    updater(cx).is_some()
}

/// Whether "Check for Updates…" can start now.
pub fn can_check(cx: &App) -> bool {
    updater(cx).is_some_and(|u| u.can_check())
}

/// "Check for Updates…" (the app menu and Settings › About).
pub fn check_for_updates(cx: &mut App) {
    if let Some(updater) = updater(cx) {
        updater.check_for_updates();
    }
}

/// The updater's "check automatically"; `None` without an updater.
pub fn automatic_checks(cx: &App) -> Option<bool> {
    updater(cx).map(|u| u.automatic_checks())
}

pub fn set_automatic_checks(on: bool, cx: &mut App) {
    if let Some(updater) = updater(cx) {
        updater.set_automatic_checks(on);
    }
}

/// What the updater's checks came to, for About (Linux).
pub fn status(cx: &App) -> Option<Status> {
    updater(cx).and_then(|u| u.status())
}

/// A check that shows nothing unless it finds a newer version (the
/// `--smoke` pass's); false when the updater reports no outcome.
pub fn check_quietly(cx: &mut App) -> bool {
    updater(cx).is_some_and(|u| u.check_quietly())
}

/// What the next check that ends comes to.
pub fn next_outcome(cx: &mut App) -> oneshot::Receiver<Outcome> {
    let (tx, rx) = oneshot::channel();
    if cx.has_global::<Updates>() {
        cx.global_mut::<Updates>().waiting.push(tx);
    }
    rx
}

/// What a check came to: logged, and handed to whoever waits for it.
#[cfg(any(windows, target_os = "linux"))]
fn report(outcome: Outcome, cx: &mut App) {
    log::info!("updates: {outcome}");
    if cx.has_global::<Updates>() {
        for tx in std::mem::take(&mut cx.global_mut::<Updates>().waiting) {
            let _ = tx.send(outcome.clone());
        }
    }
}
