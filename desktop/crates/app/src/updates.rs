//! Updates: the Sparkle updater as a GPUI global, the app menu's
//! "Check for Updates…", and what Settings › About shows.
//!
//! Only a release bundle has an updater (see [`crate::shell::updater`]).
//! Without one, the menu item stays disabled (GPUI's menus disable items
//! whose action has no handler) and About says updates come with the
//! installed app. "Receive beta updates" is saved either way
//! (`desktop.betaUpdates`, off by default).

use gpui_kit::{App, Global};

use crate::AppState;
use crate::actions::CheckForUpdates;
use crate::stores::settings::SettingsEvent;

/// The running updater, when this build has one.
pub struct Updates {
    #[cfg(target_os = "macos")]
    updater: Option<crate::shell::updater::Updater>,
}

impl Global for Updates {}

fn beta_pref(cx: &App) -> bool {
    cx.try_global::<AppState>()
        .is_some_and(|s| s.settings.read(cx).prefs.desktop.beta_updates)
}

/// Starts the updater (release bundles only) and follows the beta switch.
pub fn install(cx: &mut App) {
    #[cfg(target_os = "macos")]
    {
        let beta = beta_pref(cx);
        let updater = match crate::shell::updater::Updater::start(beta) {
            Ok(updater) => {
                log::info!("updates: Sparkle started (betas {beta})");
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

    let Some(settings) = cx.try_global::<AppState>().map(|s| s.settings.clone()) else {
        return;
    };
    cx.subscribe(&settings, |_, event, cx| {
        if matches!(event, SettingsEvent::DesktopChanged) {
            let beta = beta_pref(cx);
            #[cfg(target_os = "macos")]
            if let Some(updater) = updater(cx)
                && updater.beta() != beta
            {
                log::info!("updates: betas {beta}");
                updater.set_beta(beta);
            }
            #[cfg(not(target_os = "macos"))]
            let _ = beta;
        }
    })
    .detach();
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
