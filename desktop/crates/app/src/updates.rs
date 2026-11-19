//! Updates: the Sparkle updater as a GPUI global, the app menu's
//! "Check for Updates…", and what Settings › About shows.
//!
//! Only a release bundle has an updater (see [`crate::shell::updater`]).
//! Without one, the menu item stays disabled (GPUI's menus disable items
//! whose action has no handler) and About says updates come with the
//! installed app. Releases are stable only: there is no channel to choose.

use gpui_kit::{App, Global};

use crate::actions::CheckForUpdates;

/// The running updater, when this build has one.
pub struct Updates {
    #[cfg(target_os = "macos")]
    updater: Option<crate::shell::updater::Updater>,
}

impl Global for Updates {}

/// Starts the updater (release bundles only).
pub fn install(cx: &mut App) {
    #[cfg(target_os = "macos")]
    {
        let updater = match crate::shell::updater::Updater::start() {
            Ok(updater) => {
                log::info!("updates: Sparkle started");
                Some(updater)
            }
            Err(why) => {
                log::info!("updates: no updater ({why:?})");
                None
            }
        };
        let available = updater.is_some();
        cx.set_global(Updates { updater });
        if available {
            cx.on_action(|_: &CheckForUpdates, cx| check_for_updates(cx));
        }
    }
    #[cfg(not(target_os = "macos"))]
    cx.set_global(Updates {});
}

#[cfg(target_os = "macos")]
fn updater(cx: &App) -> Option<&crate::shell::updater::Updater> {
    cx.try_global::<Updates>().and_then(|u| u.updater.as_ref())
}

/// Whether this build updates itself.
pub fn available(cx: &App) -> bool {
    #[cfg(target_os = "macos")]
    return updater(cx).is_some();
    #[cfg(not(target_os = "macos"))]
    {
        let _ = cx;
        false
    }
}

/// Whether "Check for Updates…" can start now.
pub fn can_check(cx: &App) -> bool {
    #[cfg(target_os = "macos")]
    return updater(cx).is_some_and(|u| u.can_check());
    #[cfg(not(target_os = "macos"))]
    {
        let _ = cx;
        false
    }
}

/// "Check for Updates…" (the app menu and Settings › About).
pub fn check_for_updates(cx: &mut App) {
    #[cfg(target_os = "macos")]
    if let Some(updater) = updater(cx) {
        updater.check_for_updates();
    }
    #[cfg(not(target_os = "macos"))]
    let _ = cx;
}

/// Sparkle's "check automatically"; `None` without an updater.
pub fn automatic_checks(cx: &App) -> Option<bool> {
    #[cfg(target_os = "macos")]
    return updater(cx).map(|u| u.automatic_checks());
    #[cfg(not(target_os = "macos"))]
    {
        let _ = cx;
        None
    }
}

pub fn set_automatic_checks(on: bool, cx: &mut App) {
    #[cfg(target_os = "macos")]
    if let Some(updater) = updater(cx) {
        updater.set_automatic_checks(on);
    }
    #[cfg(not(target_os = "macos"))]
    let _ = (on, cx);
}
