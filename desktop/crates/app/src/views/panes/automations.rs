//! Scheduled tasks' pane: a placeholder until the task list.

use conduit_components::theme::ConduitTheme;
use gpui_kit::AnyElement;

use crate::l10n::L10n;
use crate::stores::navigation::AreaItem;

/// Every scheduled task, titled `title`.
pub fn pane(title: &str, t: &ConduitTheme, l: &L10n) -> AnyElement {
    super::placeholder(&AreaItem::Automations, title, t, l)
}
