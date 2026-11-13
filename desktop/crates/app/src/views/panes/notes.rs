//! A note's pane: a placeholder until the note editor.

use conduit_components::theme::ConduitTheme;
use gpui_kit::AnyElement;

use crate::l10n::L10n;
use crate::stores::navigation::AreaItem;

/// Note `id`, titled `title`.
pub fn pane(id: &str, title: &str, t: &ConduitTheme, l: &L10n) -> AnyElement {
    super::placeholder(&AreaItem::Note(id.to_string()), title, t, l)
}
