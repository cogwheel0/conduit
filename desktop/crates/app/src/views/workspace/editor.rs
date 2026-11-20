//! What every workspace editor shares: the events it sends the pane, the
//! frame around its form (a heading with the item's name and its Share
//! Access… and More buttons, the form scrolling under it, Revert and Save
//! along the bottom edge), and the error words.

use std::rc::Rc;

use conduit_components::ActiveConduitTheme as _;
use conduit_components::assets::{IconName, icon};
use conduit_components::views::kit::{Button, IconButton};
use conduit_protocol::{RpcError, WorkspaceDetail, WorkspaceItem};
use gpui_kit::component::native_menu::NativeMenu;
use gpui_kit::prelude::*;
use gpui_kit::{
    AnyElement, App, Context, Entity, FontWeight, Role, SharedString, WeakEntity, Window, div, px,
    relative,
};

use super::{ItemCommand, WorkspaceMenu, WorkspacePane, display_name};
use crate::l10n::{ActiveL10n as _, L10n};
use crate::stores::navigation::WorkspaceSection;
use crate::views::forms;

/// What an editor tells the pane.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum EditorEvent {
    /// A new item was made, with this id.
    Created(String),
    /// The item was saved.
    Saved(String),
    /// The item was deleted from its editor.
    Deleted(String),
    /// A new item's editor was cancelled.
    Closed,
}

/// The editor of one item.
pub trait ItemEditor {
    /// The item it edits; None while it makes a new one.
    fn item_id(&self) -> Option<String>;
    /// The form differs from what was loaded.
    fn is_dirty(&self, cx: &App) -> bool;
    /// Reads the item again.
    fn reload(&mut self, window: &mut Window, cx: &mut Context<Self>)
    where
        Self: Sized;
    /// Saves (or makes) the item.
    fn save(&mut self, window: &mut Window, cx: &mut Context<Self>)
    where
        Self: Sized;
    /// A pop-up of its form picked `value`.
    fn on_choice(
        &mut self,
        action: &crate::actions::SettingsChoice,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) where
        Self: Sized;
}

/// The id of the item `detail` holds.
pub fn detail_id(detail: &WorkspaceDetail) -> Option<String> {
    detail
        .model
        .as_ref()
        .map(|m| m.id.clone())
        .or_else(|| detail.knowledge.as_ref().map(|k| k.id.clone()))
        .or_else(|| detail.prompt.as_ref().map(|p| p.id.clone()))
        .or_else(|| detail.tool.as_ref().map(|t| t.id.clone()))
        .or_else(|| detail.skill.as_ref().map(|s| s.id.clone()))
}

/// What a failed workspace call says: the server's own reason when it gave
/// one (a taken id, a limit), else a plain sentence.
pub fn failure_text(e: &RpcError, l: &L10n) -> String {
    if let Some(detail) = e.args.get("detail").filter(|d| !d.trim().is_empty()) {
        return detail.clone();
    }
    match e.code.as_str() {
        "rpc.unauthorized" | "auth.unauthorized" => l.desktop_workspace_denied(),
        "rpc.notFound" | "resource.notFound" => l.desktop_workspace_not_found(),
        _ => l.error_message(),
    }
}

/// A form row with its label over a full-width control (a text area, the
/// code editor), as Mail's signature editor.
pub fn stacked_row(
    label: impl Into<SharedString>,
    control: impl IntoElement,
    help: Option<SharedString>,
    cx: &App,
) -> gpui_kit::Div {
    let t = cx.conduit().clone();
    div()
        .w_full()
        .p(px(12.))
        .flex()
        .flex_col()
        .gap(px(6.))
        .child(
            div()
                .text_size(px(t.metrics.control))
                .text_color(t.roles.text)
                .child(label.into()),
        )
        .child(control)
        .when_some(help, |d, h| {
            d.child(
                div()
                    .text_size(px(t.metrics.small))
                    .line_height(relative(1.35))
                    .text_color(t.roles.text_subtle)
                    .child(h),
            )
        })
}

/// A section heading over a group of rows in an editor.
pub fn group_heading(text: impl Into<SharedString>, cx: &App) -> gpui_kit::Div {
    let t = cx.conduit().clone();
    div()
        .px(px(12.))
        .pt(px(6.))
        .text_size(px(t.metrics.small + 0.5))
        .font_weight(FontWeight::SEMIBOLD)
        .text_color(t.roles.text_subtle)
        .child(text.into())
}

/// The frame's state, from the editor.
pub struct Frame {
    pub section: WorkspaceSection,
    pub title: String,
    pub subtitle: Option<String>,
    /// The item as listed, for the More menu; None while new.
    pub item: Option<WorkspaceItem>,
    pub dirty: bool,
    pub saving: bool,
    /// The default button may run (required fields filled).
    pub can_save: bool,
    pub read_only: bool,
    pub creating: bool,
    pub loading: bool,
    pub failure: Option<String>,
    /// The body's scroll position, when the editor keeps one (to bring a
    /// section into view).
    pub scroll: Option<gpui_kit::ScrollHandle>,
}

/// The item of `section` that `detail` holds, as the pane lists it, or as
/// `detail` says.
pub fn listed_item(
    pane: &WeakEntity<WorkspacePane>,
    section: WorkspaceSection,
    detail: &WorkspaceDetail,
    cx: &App,
) -> Option<WorkspaceItem> {
    let id = detail_id(detail)?;
    let listed = pane.upgrade().and_then(|p| {
        p.read(cx)
            .lists
            .get(&section)
            .and_then(|l| l.item(&id))
            .cloned()
    });
    Some(listed.unwrap_or_else(|| {
        let (name, active, hidden) = match section {
            WorkspaceSection::Models => detail
                .model
                .as_ref()
                .map(|m| (m.name.clone(), Some(m.active), m.hidden))
                .unwrap_or_default(),
            WorkspaceSection::Knowledge => detail
                .knowledge
                .as_ref()
                .map(|k| (k.name.clone(), None, false))
                .unwrap_or_default(),
            WorkspaceSection::Prompts => detail
                .prompt
                .as_ref()
                .map(|p| (p.name.clone(), Some(p.active), false))
                .unwrap_or_default(),
            WorkspaceSection::Tools => detail
                .tool
                .as_ref()
                .map(|t| (t.name.clone(), t.active, false))
                .unwrap_or_default(),
            WorkspaceSection::Skills => detail
                .skill
                .as_ref()
                .map(|s| (s.name.clone(), Some(s.active), false))
                .unwrap_or_default(),
        };
        WorkspaceItem {
            kind: super::kind_of(section),
            id,
            name,
            subtitle: None,
            owner_name: detail.owner_name.clone(),
            write_access: detail.write_access,
            active,
            public: false,
            updated_at_ms: detail.updated_at_ms,
            tags: vec![],
            external: detail.knowledge.as_ref().is_some_and(|k| k.external),
            hidden,
            function_count: None,
        }
    }))
}

/// What an editor runs from the frame's buttons.
pub type EditorFn<V> = Rc<dyn Fn(&mut V, &mut Window, &mut Context<V>)>;

/// Draws an editor: its heading, `body` (rows and groups, scrolling), and
/// the buttons along the bottom. `revert` (Cancel for a new item) and
/// `save` run the editor's.
#[allow(clippy::too_many_arguments)]
pub fn frame<V: 'static>(
    id: &'static str,
    frame: Frame,
    pane: WeakEntity<WorkspacePane>,
    body: Vec<AnyElement>,
    revert: EditorFn<V>,
    save: EditorFn<V>,
    cx: &mut Context<V>,
) -> AnyElement {
    let t = cx.conduit().clone();
    let r = t.roles;
    let l = cx.l10n().clone();
    let section = frame.section;
    let item = frame.item.clone();
    let commands: Vec<Option<(String, ItemCommand)>> = match (&item, pane.upgrade()) {
        (Some(item), Some(p)) => p
            .read(cx)
            .item_commands(section, item, &l)
            .into_iter()
            .filter(|c| !matches!(c, Some((_, ItemCommand::Edit))))
            .collect(),
        _ => vec![],
    };
    let shareable = commands
        .iter()
        .any(|c| matches!(c, Some((_, ItemCommand::Share))));
    let item_id = item.as_ref().map(|i| i.id.clone()).unwrap_or_default();
    let heading = div()
        .flex_none()
        .px(px(24.))
        .pt(px(14.))
        .pb(px(10.))
        .flex()
        .items_start()
        .gap(px(10.))
        .child(
            div()
                .flex_1()
                .min_w_0()
                .flex()
                .flex_col()
                .gap(px(2.))
                .child(
                    div()
                        .id("workspace-editor-title")
                        .role(Role::Heading)
                        .truncate()
                        .text_size(px(t.metrics.body + 4.))
                        .font_weight(FontWeight::SEMIBOLD)
                        .text_color(r.text)
                        .child(frame.title.clone()),
                )
                .when_some(frame.subtitle.clone(), |d, s| {
                    d.child(
                        div()
                            .truncate()
                            .text_size(px(t.metrics.small + 0.5))
                            .text_color(r.text_subtle)
                            .child(s),
                    )
                }),
        )
        .when(shareable, |d| {
            let action = WorkspaceMenu {
                section,
                id: item_id.clone(),
                command: ItemCommand::Share,
            };
            d.child(
                Button::new("workspace-editor-share", l.desktop_share_access_ellipsis())
                    .icon(IconName::Users)
                    .on_click(Rc::new(move |_, window, cx| {
                        window.dispatch_action(Box::new(action.clone()), cx)
                    })),
            )
        })
        .when(!commands.is_empty(), |d| {
            let id = item_id.clone();
            d.child(
                IconButton::new(
                    "workspace-editor-more",
                    IconName::Ellipsis,
                    l.workspace_editor_more_actions(),
                )
                .size(28., 15.)
                .on_click(Rc::new(move |e, window, cx| {
                    let mut menu = NativeMenu::new();
                    for entry in commands.clone() {
                        menu = match entry {
                            Some((label, command)) => menu.menu(
                                label,
                                Box::new(WorkspaceMenu {
                                    section,
                                    id: id.clone(),
                                    command,
                                }),
                            ),
                            None => menu.separator(),
                        };
                    }
                    menu.show(e.position(), window, cx);
                })),
            )
        });
    let mut content = body;
    if let Some(failure) = frame.failure.clone() {
        content.push(forms::form_error("workspace-editor-failure", failure, cx).into_any_element());
    }
    let scroll = div()
        .id(SharedString::from(format!("{id}-scroll")))
        .flex_1()
        .min_h_0()
        .overflow_y_scroll()
        .when_some(frame.scroll.clone(), |d, h| d.track_scroll(&h))
        .child(
            div()
                .w_full()
                .max_w(px(760.))
                .px(px(24.))
                .pb(px(24.))
                .flex()
                .flex_col()
                .gap(px(16.))
                .children(content),
        );
    let footer = (!frame.read_only && !frame.loading).then(|| {
        let revert_view = cx.entity().downgrade();
        let save_view = cx.entity().downgrade();
        let revert_fn = revert.clone();
        let save_fn = save.clone();
        let left = if frame.creating {
            Button::new("workspace-editor-cancel", l.cancel())
                .disabled(frame.saving)
                .on_click(Rc::new(move |_, window, cx| {
                    let f = revert_fn.clone();
                    let _ = revert_view.update(cx, |v, cx| f(v, window, cx));
                }))
        } else {
            Button::new("workspace-editor-revert", l.desktop_workspace_revert())
                .disabled(!frame.dirty || frame.saving)
                .on_click(Rc::new(move |_, window, cx| {
                    let f = revert_fn.clone();
                    let _ = revert_view.update(cx, |v, cx| f(v, window, cx));
                }))
        };
        let label = if frame.saving {
            l.desktop_saving()
        } else if frame.creating {
            l.create()
        } else {
            l.save()
        };
        div()
            .flex_none()
            .px(px(24.))
            .py(px(12.))
            .flex()
            .items_center()
            .gap(px(8.))
            .border_t_1()
            .border_color(r.divider)
            .when(frame.dirty && !frame.creating, |d| {
                d.child(
                    div()
                        .id("workspace-editor-edited")
                        .role(Role::Status)
                        .flex()
                        .items_center()
                        .gap(px(6.))
                        .text_size(px(t.metrics.small))
                        .text_color(r.text_subtle)
                        .child(icon(IconName::Pencil, 12., r.text_subtle))
                        .child(l.desktop_workspace_edited()),
                )
            })
            .child(div().flex_1())
            .child(left)
            .child(
                Button::new("workspace-editor-save", label)
                    .primary()
                    .shortcut("⌘S")
                    .disabled(!frame.can_save || frame.saving || (!frame.dirty && !frame.creating))
                    .on_click(Rc::new(move |_, window, cx| {
                        let f = save_fn.clone();
                        let _ = save_view.update(cx, |v, cx| f(v, window, cx));
                    })),
            )
    });
    let save_key = save.clone();
    let key_view = cx.entity().downgrade();
    div()
        .id(id)
        .role(Role::Form)
        .aria_label(SharedString::from(frame.title.clone()))
        .size_full()
        .flex()
        .flex_col()
        // The grouped page tone, as Settings' and the sheets' forms: the
        // groups' cards show on it in light and dark.
        .bg(conduit_components::views::kit::grouped_tones(&t).0)
        // ⌘S saves, from any field of the form.
        .on_key_down(move |e: &gpui_kit::KeyDownEvent, window, cx| {
            let k = &e.keystroke;
            let m = &k.modifiers;
            if k.key == "s" && m.platform && !(m.alt || m.control || m.shift) {
                let f = save_key.clone();
                let _ = key_view.update(cx, |v, cx| f(v, window, cx));
                cx.stop_propagation();
            }
        })
        .child(heading)
        .child(if frame.loading {
            div()
                .flex_1()
                .flex()
                .items_center()
                .justify_center()
                .text_color(r.text_subtle)
                .child(frame.failure.clone().unwrap_or_else(|| l.desktop_loading()))
                .into_any_element()
        } else {
            scroll.into_any_element()
        })
        .children(footer)
        .into_any_element()
}

/// The subtitle under an item's name: its owner, and Read-only when the
/// account may only look.
pub fn subtitle(owner: Option<&str>, writable: bool, l: &L10n) -> Option<String> {
    let mut parts = vec![];
    if let Some(owner) = owner.filter(|o| !o.trim().is_empty()) {
        parts.push(l.desktop_workspace_owned_by(owner));
    }
    if !writable {
        parts.push(l.workspace_read_only_badge());
    }
    (!parts.is_empty()).then(|| parts.join(" · "))
}

/// Switches item `id` on or off through the pane (an editor's switch).
pub fn dispatch_toggle(section: WorkspaceSection, id: String, window: &mut Window, cx: &mut App) {
    window.dispatch_action(
        Box::new(WorkspaceMenu {
            section,
            id,
            command: ItemCommand::Toggle,
        }),
        cx,
    );
}

/// An input's text as typed.
pub fn value(state: &Entity<gpui_kit::component::input::InputState>, cx: &App) -> String {
    state.read(cx).value().to_string()
}

/// `item`'s name for messages.
pub fn item_name(item: &WorkspaceItem) -> String {
    display_name(item)
}

/// Splits comma-separated text into trimmed, non-empty parts.
pub fn split_list(text: &str) -> Vec<String> {
    text.split(',')
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(str::to_string)
        .collect()
}

/// Editor tests' shared pieces.
#[cfg(test)]
pub mod bench {
    use conduit_protocol::{WorkspaceDetail, WorkspaceKind, WorkspaceSectionAccess};

    /// Rights to change a section.
    pub fn manage() -> WorkspaceSectionAccess {
        WorkspaceSectionAccess {
            manage: true,
            ..Default::default()
        }
    }

    /// `kind`'s item as `workspace.get`/`save` answer it, from its JSON.
    pub fn detail(kind: WorkspaceKind, item: serde_json::Value) -> WorkspaceDetail {
        let field = match kind {
            WorkspaceKind::Models => "model",
            WorkspaceKind::Knowledge => "knowledge",
            WorkspaceKind::Prompts => "prompt",
            WorkspaceKind::Tools => "tool",
            WorkspaceKind::Skills => "skill",
            WorkspaceKind::Unknown => "unknown",
        };
        let mut json = serde_json::json!({"kind": kind, "writeAccess": true, "grants": []});
        json[field] = item;
        serde_json::from_value(json).expect("a workspace detail")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lists_split_on_commas_and_drop_blanks() {
        assert_eq!(split_list(" a, b ,,c "), ["a", "b", "c"]);
        assert!(split_list("  ").is_empty());
    }
}
