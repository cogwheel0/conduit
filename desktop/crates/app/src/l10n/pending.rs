//! PENDING APPROVAL: words the Windows and Linux chrome shows that the
//! catalogs don't have yet. Each is English in every language until the
//! maintainer approves it; then its key goes in `lib/l10n/desktop/` and the
//! accessor replaces the function here, a change in this file only.

/// ☰'s accessible name and the open menu's (`desktopMainMenu`).
pub fn main_menu() -> String {
    "Main Menu".into()
}

/// Windows' ☰ › Exit, the Mac's Quit Conduit (`desktopMenuExit`).
pub fn exit() -> String {
    "Exit".into()
}

/// GNOME's primary menu › Preferences, the Mac's Settings…
/// (`desktopMenuPreferences`).
pub fn preferences() -> String {
    "Preferences".into()
}
