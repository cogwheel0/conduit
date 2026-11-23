//! Updates: the platform's updater as a GPUI global, the app menu's
//! "Check for Updates…", and what Settings › About shows.
//!
//! Each platform plugs in an [`Updater`]: Sparkle on the Mac, in release
//! bundles only (see [`crate::shell::updater`]); none on Windows and Linux
//! yet. Without one, the menu item stays disabled (GPUI's menus disable items
//! whose action has no handler) and About says updates come with the
//! installed app. Releases are stable only: there is no channel to choose.

use gpui_kit::{App, Global};

use crate::actions::CheckForUpdates;

/// What the menu and Settings › About ask of a platform's updater.
pub trait Updater {
    /// Whether a check can start now (not while one runs).
    fn can_check(&self) -> bool;
    /// "Check for Updates…": the updater shows what it finds itself.
    fn check_for_updates(&self);
    /// "Check automatically", a setting the updater keeps.
    fn automatic_checks(&self) -> bool;
    fn set_automatic_checks(&self, on: bool);
}

/// The running updater, when this build has one.
pub struct Updates {
    updater: Option<Box<dyn Updater>>,
}

impl Global for Updates {}

/// Starts this platform's updater, if it has one.
pub fn install(cx: &mut App) {
    let updater = start();
    let available = updater.is_some();
    cx.set_global(Updates { updater });
    if available {
        cx.on_action(|_: &CheckForUpdates, cx| check_for_updates(cx));
    }
}

#[cfg(target_os = "macos")]
fn start() -> Option<Box<dyn Updater>> {
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

#[cfg(not(target_os = "macos"))]
fn start() -> Option<Box<dyn Updater>> {
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
