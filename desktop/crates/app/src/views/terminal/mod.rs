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
pub mod preview;
pub mod viewer;
