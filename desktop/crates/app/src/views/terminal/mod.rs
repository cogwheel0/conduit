//! The Terminal area: a terminal server's console and files, port
//! previews, and the Computer viewer.
//!
//! * [`emulator`]: `alacritty_terminal` behind a lock, no GPUI.
//! * [`keys`]: keystrokes as the shell reads them.
//! * [`console`]: the screen and its shell.
//! * [`pane`]: a server's pane (console or files, ports, status).
//! * [`files`], [`viewer`]: the file browser and showing a file.
//! * [`preview`]: a listening port's page in a window.
//! * [`chat`]: the terminal inside a chat (a shown file, Computer, the
//!   composer's Terminal section); [`computer`]: the Computer viewer.

pub mod chat;
pub mod computer;
pub mod console;
pub mod emulator;
pub mod files;
pub mod keys;
pub mod pane;
pub mod pdf;
pub mod preview;
pub mod viewer;

/// Closes the Computer viewer and every port preview: both reach the last
/// account's terminal with that account's credential, so another account
/// (or none) signing in ends them.
pub fn close_account_windows(cx: &mut gpui_kit::App) {
    cx.default_global::<AccountWindows>().0 += 1;
    if let Some((_, handle, _)) = cx.default_global::<computer::OpenComputer>().0.take() {
        let _ = handle.update(cx, |_, window, _| window.remove_window());
    }
    let previews = std::mem::take(&mut cx.default_global::<preview::OpenPreviews>().0);
    for (_, handle, _) in previews {
        let _ = handle.update(cx, |_, window, _| window.remove_window());
    }
}

/// Bumped each time an account change closes the terminal windows: a window
/// asked for before it (a preview whose answer is still on its way) opens
/// only if no change came in between.
#[derive(Default)]
pub struct AccountWindows(pub u64);

impl gpui_kit::Global for AccountWindows {}
