//! A terminal server's pane: [`crate::views::terminal::pane`], kept alive
//! per server by [`super::AreaPane`] so a shell survives a trip to a chat.

use gpui_kit::{AnyElement, Entity, IntoElement as _};

use crate::views::terminal::pane::TerminalPane;

/// The pane for a server, drawn.
pub fn pane(pane: &Entity<TerminalPane>) -> AnyElement {
    pane.clone().into_any_element()
}
