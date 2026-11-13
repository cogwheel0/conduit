//! A workspace section's pane: the section's list and an editor beside it
//! ([`crate::views::workspace::WorkspacePane`]), made once and kept, so a
//! section's search, selection and unsaved edits survive a visit to a
//! chat.

use gpui_kit::{AppContext as _, Context, Entity, Window};

use crate::stores::Stores;
use crate::stores::navigation::WorkspaceSection;
use crate::views::workspace::WorkspacePane;

/// The workspace pane, showing `section` (made the first time).
pub fn pane<V: 'static>(
    slot: &mut Option<Entity<WorkspacePane>>,
    stores: &Stores,
    section: WorkspaceSection,
    window: &mut Window,
    cx: &mut Context<V>,
) -> Entity<WorkspacePane> {
    match slot {
        Some(pane) => {
            pane.update(cx, |p, cx| p.show(section, window, cx));
            pane.clone()
        }
        None => {
            let stores = stores.clone();
            let pane = cx.new(|cx| WorkspacePane::new(stores, section, window, cx));
            *slot = Some(pane.clone());
            pane
        }
    }
}
