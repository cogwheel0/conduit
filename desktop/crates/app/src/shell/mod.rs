//! The OS side of the shell: logging, crash files, URL opening, native
//! sheets, the SSO browser window, the AppKit / Network.framework calls,
//! images of the app's own windows ([`grab`]), and the Mac extras:
//! `conduit://` links and "Open with" ([`deep_link`],
//! [`open_files`]), answer notifications ([`notify`], [`notifications`]),
//! the Quick Ask hotkey and placement ([`hotkey`], [`placement`]), the
//! menu-bar item ([`tray`]) and open at login ([`login_item`]); Sparkle
//! updates ([`updater`]); and Reduce Motion ([`reduce_motion`]).

pub mod crash;
pub mod deep_link;
#[cfg(target_os = "macos")]
#[cfg(target_os = "macos")]
pub mod grab;
pub mod hotkey;
pub mod logger;
#[cfg(target_os = "macos")]
pub mod login_item;
#[cfg(target_os = "macos")]
pub mod macos;
#[cfg(target_os = "macos")]
pub mod notifications;
pub mod notify;
pub mod open_files;
pub mod open_url;
pub mod placement;
pub mod reduce_motion;
pub mod share;
pub mod sheet;
pub mod speech;
pub mod sso;
#[cfg(target_os = "macos")]
pub mod tray;
#[cfg(target_os = "macos")]
pub mod updater;
