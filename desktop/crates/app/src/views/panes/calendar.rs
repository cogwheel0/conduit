//! The calendar's pane: the agenda beside the calendars
//! ([`crate::views::calendar::CalendarPane`]), made once and kept, so the
//! range and the chosen row survive a visit to a chat.

use gpui_kit::{AppContext as _, Context, Entity, Window};

use crate::stores::Stores;
use crate::views::calendar::CalendarPane;

/// The calendar pane (made the first time, and read again each time it is
/// shown).
pub fn pane<V: 'static>(
    slot: &mut Option<Entity<CalendarPane>>,
    shown: bool,
    stores: &Stores,
    window: &mut Window,
    cx: &mut Context<V>,
) -> Entity<CalendarPane> {
    match slot {
        Some(pane) => {
            if !shown {
                pane.update(cx, |p, cx| p.show(cx));
            }
            pane.clone()
        }
        None => {
            let stores = stores.clone();
            let pane = cx.new(|cx| CalendarPane::new(stores, window, cx));
            *slot = Some(pane.clone());
            pane
        }
    }
}
