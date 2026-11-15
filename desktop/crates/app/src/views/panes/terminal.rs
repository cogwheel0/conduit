//! A terminal server's pane: a placeholder until the terminal.

use conduit_components::theme::ConduitTheme;
use gpui_kit::AnyElement;

use crate::l10n::L10n;
use crate::stores::navigation::AreaItem;

/// Terminal server `id`, named `title`.
pub fn pane(id: &str, title: &str, t: &ConduitTheme, l: &L10n) -> AnyElement {
    super::placeholder(&AreaItem::Terminal(id.to_string()), title, t, l)
}
