//! A Hermes session's pane: a placeholder until the session's transcript
//! (read-only sessions with Continue Here).

use conduit_components::theme::ConduitTheme;
use gpui_kit::AnyElement;

use crate::l10n::L10n;
use crate::stores::navigation::AreaItem;

/// Hermes session `id`, titled `title`.
pub fn pane(id: &str, title: &str, t: &ConduitTheme, l: &L10n) -> AnyElement {
    super::placeholder(&AreaItem::HermesSession(id.to_string()), title, t, l)
}
