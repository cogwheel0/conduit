//! A channel's pane: a placeholder until the channel's timeline.

use conduit_components::theme::ConduitTheme;
use gpui_kit::AnyElement;

use crate::l10n::L10n;
use crate::stores::navigation::AreaItem;

/// Channel `id`, named `title`.
pub fn pane(id: &str, title: &str, t: &ConduitTheme, l: &L10n) -> AnyElement {
    super::placeholder(&AreaItem::Channel(id.to_string()), title, t, l)
}
