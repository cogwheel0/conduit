//! The calendar's pane: a placeholder until the agenda.

use conduit_components::theme::ConduitTheme;
use gpui_kit::AnyElement;

use crate::l10n::L10n;
use crate::stores::navigation::AreaItem;

/// The calendar's coming events, titled `title`.
pub fn pane(title: &str, t: &ConduitTheme, l: &L10n) -> AnyElement {
    super::placeholder(&AreaItem::Calendar, title, t, l)
}
