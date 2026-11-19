//! Scheduled tasks' pane: the task list beside the chosen task
//! ([`crate::views::tasks::TasksPane`]), made once and kept, so the search,
//! filter and chosen task survive a visit to a chat.

use gpui_kit::{AppContext as _, Context, Entity, Window};

use crate::stores::Stores;
use crate::views::tasks::TasksPane;

/// The tasks pane (made the first time, and read again each time it is
/// shown).
pub fn pane<V: 'static>(
    slot: &mut Option<Entity<TasksPane>>,
    shown: bool,
    stores: &Stores,
    window: &mut Window,
    cx: &mut Context<V>,
) -> Entity<TasksPane> {
    match slot {
        Some(pane) => {
            if !shown {
                pane.update(cx, |p, cx| p.show(cx));
            }
            pane.clone()
        }
        None => {
            let stores = stores.clone();
            let pane = cx.new(|cx| TasksPane::new(stores, window, cx));
            *slot = Some(pane.clone());
            pane
        }
    }
}
