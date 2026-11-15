//! A workspace section's pane: a placeholder until the section's list
//! and editors.

use conduit_components::theme::ConduitTheme;
use gpui_kit::AnyElement;

use crate::l10n::L10n;
use crate::stores::navigation::{AreaItem, WorkspaceSection};

/// Workspace section `section`, named `title`.
pub fn pane(section: WorkspaceSection, title: &str, t: &ConduitTheme, l: &L10n) -> AnyElement {
    super::placeholder(&AreaItem::Workspace(section), title, t, l)
}
