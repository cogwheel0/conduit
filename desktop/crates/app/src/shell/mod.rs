//! The OS side of the shell: logging, crash files, URL opening, native
//! sheets, the SSO browser window, the AppKit / Network.framework calls,
//! images of the app's own windows ([`grab`]), and the Mac extras:
//! `conduit://` links and "Open with" ([`deep_link`],
//! [`open_files`]), answer notifications ([`notify`], [`notifications`]),
//! the Quick Ask hotkey and placement ([`hotkey`], [`placement`]), the
//! menu-bar item ([`tray`]) and open at login ([`login_item`]); Sparkle
//! updates ([`updater`]); Reduce Motion ([`reduce_motion`]); read
//! aloud's voices and player ([`speech_engine`]) and Now Playing
//! ([`now_playing`]); the desktop widget's snapshot ([`widget`]); the
//! Share extension's inbox ([`share_inbox`]) and "Ask Conduit" in the
//! Services menu ([`services`]); and Apple's on-device model
//! ([`apple_models`]).

pub mod apple_models;
#[cfg(target_os = "macos")]
pub mod continuity_camera;
pub mod crash;
pub mod date_picker;
pub mod deep_link;
#[cfg(target_os = "macos")]
pub mod grab;
#[cfg(target_os = "macos")]
pub mod hotkey;
pub mod location;
pub mod logger;
#[cfg(target_os = "macos")]
pub mod login_item;
#[cfg(target_os = "macos")]
pub mod macos;
#[cfg(target_os = "macos")]
pub mod notifications;
pub mod notify;
pub mod now_playing;
pub mod open_files;
pub mod open_url;
pub mod placement;
pub mod reduce_motion;
pub mod services;
pub mod share;
pub mod share_inbox;
pub mod sheet;
pub mod speech;
pub mod speech_engine;
pub mod sso;
#[cfg(target_os = "macos")]
pub mod tray;
#[cfg(target_os = "macos")]
pub mod updater;
pub mod web_media;
pub mod widget;
