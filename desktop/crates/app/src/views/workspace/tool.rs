//! The tool editor: a tool's name, id and description, and its Python
//! source in a code editor highlighted as the chat's code blocks are (the
//! same tree-sitter grammar and theme). The functions the server read from
//! the source are listed once saved; Valves… and Your Valves… open the
//! tool's settings; Import from URL… fills the form from a GitHub file
//! (the daemon fetches only https GitHub addresses).

use std::rc::Rc;

use conduit_components::ActiveConduitTheme as _;
use conduit_components::assets::{IconName, icon};
use conduit_components::views::kit::{Button, Switch, grouped_section, warning_row};
use conduit_protocol::{
    NoticeLevel, WorkspaceDetail, WorkspaceKind, WorkspaceRef, WorkspaceSave,
    WorkspaceSectionAccess, WorkspaceToolDto, WorkspaceUrl, methods,
};
use gpui_kit::component::input::{Editor, EditorState, InputEvent, InputState};
use gpui_kit::prelude::*;
use gpui_kit::{
    AnyElement, App, AsyncApp, Context, Entity, EventEmitter, Role, SharedString, Subscription,
    Task, WeakEntity, Window, div, px, relative,
};

use super::WorkspacePane;
use super::editor::{self, EditorEvent, Frame, ItemEditor};
use super::sheets::{SheetField, SheetRun, open_form};
use crate::actions::SettingsChoice;
use crate::l10n::{ActiveL10n as _, L10n};
use crate::stores::Stores;
use crate::stores::navigation::WorkspaceSection;
use crate::stores::rpc::Rpc;
use crate::views::forms;

/// A new tool's source: Open WebUI's own starting point.
pub const BOILERPLATE: &str = r#""""
title: My Tool
description: Tools for performing various operations
required_open_webui_version: 0.10.2
version: 0.0.1
"""

import os
from pydantic import BaseModel, Field


class Tools:
    def __init__(self):
        pass

    # Add your custom tools using pure Python code here. Make sure to add type
    # hints and descriptions so the model knows how to call them.

    def get_current_time(self) -> str:
        """
        Get the current time in a human-readable format.
        """
        from datetime import datetime

        return datetime.now().strftime("%A, %B %d, %Y %I:%M:%S %p")
"#;

/// A tool id: a Python identifier (letters, digits and `_`, not starting
/// with a digit).
pub fn id_is_valid(id: &str) -> bool {
    let id = id.trim();
    let mut chars = id.chars();
    match chars.next() {
        Some(c) if c.is_ascii_alphabetic() || c == '_' => {}
        _ => return false,
    }
    chars.all(|c| c.is_ascii_alphanumeric() || c == '_')
}

/// A tool id from its name, while the id is untouched.
pub fn id_from_name(name: &str) -> String {
    let mut id: String = name
        .trim()
        .to_lowercase()
        .split_whitespace()
        .collect::<Vec<_>>()
        .join("_")
        .chars()
        .filter(|c| c.is_ascii_alphanumeric() || *c == '_')
        .collect();
    if id.chars().next().is_some_and(|c| c.is_ascii_digit()) {
        id.insert(0, '_');
    }
    id
}

#[derive(Clone, Debug, Default, PartialEq)]
struct ToolForm {
    name: String,
    id: String,
    description: String,
    content: String,
}

pub struct ToolEditor {
    stores: Stores,
    rpc: Rpc,
    pane: WeakEntity<WorkspacePane>,
    id: Option<String>,
    access: WorkspaceSectionAccess,
    pub detail: Option<WorkspaceDetail>,
    name: Entity<InputState>,
    tool_id: Entity<InputState>,
    description: Entity<InputState>,
    pub code: Entity<EditorState>,
    initial: ToolForm,
    id_typed: bool,
    submitted: bool,
    saving: bool,
    loading: bool,
    failure: Option<String>,
    _subscriptions: Vec<Subscription>,
    _load: Option<Task<()>>,
}

impl EventEmitter<EditorEvent> for ToolEditor {}

impl ToolEditor {
    pub fn new(
        stores: Stores,
        pane: WeakEntity<WorkspacePane>,
        id: Option<String>,
        access: WorkspaceSectionAccess,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Self {
        let rpc = stores.connection.read(cx).rpc();
        let l = cx.l10n().clone();
        let name = forms::input(l.desktop_workspace_tool_name_hint(), false, window, cx);
        let tool_id = forms::input("my_tools", false, window, cx);
        let description = forms::input(
            l.desktop_workspace_tool_description_hint(),
            false,
            window,
            cx,
        );
        let creating = id.is_none();
        let code = cx.new(|cx| {
            let state = EditorState::new(window, cx)
                .language("python")
                .line_number(true)
                .soft_wrap(false);
            if creating {
                state.default_value(BOILERPLATE)
            } else {
                state
            }
        });
        let mut subscriptions = vec![
            cx.subscribe_in(&name, window, |this, state, e: &InputEvent, window, cx| {
                if matches!(e, InputEvent::Change) {
                    if this.id.is_none() && !this.id_typed {
                        let slug = id_from_name(&state.read(cx).value());
                        this.tool_id
                            .update(cx, |s, cx| s.set_value(slug, window, cx));
                    }
                    this.failure = None;
                    cx.notify();
                }
            }),
            cx.subscribe_in(&tool_id, window, |this, _, e: &InputEvent, _, cx| {
                if matches!(e, InputEvent::Change) {
                    this.id_typed = true;
                    cx.notify();
                }
            }),
            cx.subscribe_in(&description, window, |_, _, e: &InputEvent, _, cx| {
                if matches!(e, InputEvent::Change) {
                    cx.notify();
                }
            }),
        ];
        subscriptions.push(
            cx.subscribe_in(&code, window, |this, _, e: &InputEvent, _, cx| {
                if matches!(e, InputEvent::Change) {
                    this.failure = None;
                    cx.notify();
                }
            }),
        );
        let mut this = Self {
            stores,
            rpc,
            pane,
            id,
            access,
            detail: None,
            name,
            tool_id,
            description,
            code,
            initial: ToolForm::default(),
            id_typed: false,
            submitted: false,
            saving: false,
            loading: false,
            failure: None,
            _subscriptions: subscriptions,
            _load: None,
        };
        if this.id.is_some() {
            this.reload(window, cx);
        } else {
            this.initial = this.form(cx);
        }
        this
    }

    fn form(&self, cx: &App) -> ToolForm {
        ToolForm {
            name: self.name.read(cx).value().trim().to_string(),
            id: self.tool_id.read(cx).value().trim().to_string(),
            description: self.description.read(cx).value().trim().to_string(),
            content: self.code.read(cx).value().to_string(),
        }
    }

    fn dto(&self) -> Option<&WorkspaceToolDto> {
        self.detail.as_ref()?.tool.as_ref()
    }

    fn writable(&self) -> bool {
        self.access.manage && self.detail.as_ref().is_none_or(|d| d.write_access)
    }

    /// Fills the form from `tool` (loaded, or from a URL).
    fn fill(&mut self, tool: &WorkspaceToolDto, window: &mut Window, cx: &mut Context<Self>) {
        self.name
            .update(cx, |s, cx| s.set_value(tool.name.clone(), window, cx));
        self.tool_id
            .update(cx, |s, cx| s.set_value(tool.id.clone(), window, cx));
        self.description.update(cx, |s, cx| {
            s.set_value(tool.description.clone(), window, cx)
        });
        self.code
            .update(cx, |s, cx| s.set_value(tool.content.clone(), window, cx));
    }

    /// A save answered while the form had changed since it was sent: the
    /// saved item is the one shown now (its id, its detail, what counts as
    /// unchanged), and the form keeps what was typed since.
    fn saved_under_edits(
        &mut self,
        detail: WorkspaceDetail,
        mut sent: ToolForm,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let Some(id) = detail.tool.as_ref().map(|i| i.id.clone()) else {
            return;
        };
        // Made: its id is the one it was made with, whatever the field
        // holds now, so the next Save updates this item.
        self.tool_id
            .update(cx, |s, cx| s.set_value(id.clone(), window, cx));
        sent.id = id.clone();
        self.id = Some(id);
        self.detail = Some(detail);
        self.initial = sent;
        self.submitted = false;
    }

    fn adopt(&mut self, detail: WorkspaceDetail, window: &mut Window, cx: &mut Context<Self>) {
        let Some(tool) = detail.tool.clone() else {
            return;
        };
        self.id = Some(tool.id.clone());
        self.fill(&tool, window, cx);
        self.detail = Some(detail);
        self.initial = self.form(cx);
        self.id_typed = true;
        self.submitted = false;
        cx.notify();
    }

    fn revert(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        match self.detail.clone() {
            Some(detail) => self.adopt(detail, window, cx),
            None => cx.emit(EditorEvent::Closed),
        }
    }

    fn errors(
        &self,
        all: bool,
        l: &L10n,
        cx: &App,
    ) -> (Option<String>, Option<String>, Option<String>) {
        if !all && !self.submitted {
            return (None, None, None);
        }
        let form = self.form(cx);
        (
            form.name
                .is_empty()
                .then(|| l.desktop_workspace_tool_name_required()),
            if form.id.is_empty() {
                Some(l.desktop_workspace_tool_id_required())
            } else if !id_is_valid(&form.id) {
                Some(l.desktop_workspace_tool_id_invalid())
            } else {
                None
            },
            form.content
                .trim()
                .is_empty()
                .then(|| l.desktop_workspace_tool_content_required()),
        )
    }

    fn valid(&self, cx: &App) -> bool {
        let l = cx.l10n().clone();
        let (a, b, c) = self.errors(true, &l, cx);
        a.is_none() && b.is_none() && c.is_none()
    }

    /// Import from URL…: a GitHub address; the tool it holds fills the form
    /// (a new tool, to be reviewed and saved).
    pub fn import_from_url(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let l = cx.l10n().clone();
        let rpc = self.rpc.clone();
        let weak = cx.entity().downgrade();
        let handle = window.window_handle();
        let run: SheetRun = Rc::new(move |values, cx| {
            let url = values
                .first()
                .cloned()
                .unwrap_or_default()
                .trim()
                .to_string();
            let call = rpc.call::<methods::WorkspaceToolFromUrl>(&WorkspaceUrl { url });
            let weak = weak.clone();
            cx.spawn(async move |cx: &mut AsyncApp| match call.await {
                Ok(tool) => {
                    let _ = handle.update(cx, |_, window, cx| {
                        let _ = weak.update(cx, |s, cx| {
                            s.fill(&tool, window, cx);
                            s.id_typed = true;
                            let l = cx.l10n().clone();
                            s.stores.toasts.update(cx, |t, cx| {
                                t.show(NoticeLevel::Info, l.workspace_tool_import_url_loaded(), cx)
                            });
                            cx.notify();
                        });
                    });
                    Ok(())
                }
                Err(e) => Err(cx.update(|cx| {
                    let l = cx.l10n().clone();
                    match e.code.as_str() {
                        "rpc.invalidParams" => l.desktop_workspace_tool_import_url_host(),
                        _ => e
                            .args
                            .get("detail")
                            .cloned()
                            .unwrap_or_else(|| l.desktop_workspace_tool_import_url_failed()),
                    }
                })),
            })
        });
        open_form(
            self.stores.clone(),
            l.workspace_tool_import_url_title(),
            Some(l.workspace_tool_import_url_hint()),
            l.desktop_workspace_import_run(),
            vec![
                SheetField::line(l.desktop_workspace_tool_import_url_label(), "")
                    .placeholder("https://github.com/…/tool.py"),
            ],
            run,
            window,
            cx,
        );
    }

    fn open_valves(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let (Some(id), Some(tool)) = (self.id.clone(), self.dto().cloned()) else {
            return;
        };
        let stores = self.stores.clone();
        let admin = self.writable();
        let server = tool.has_valves && admin;
        let user = tool.has_user_valves;
        if !server && !user {
            return;
        }
        crate::views::sheet::open(window, crate::views::valves::WIDTH, cx, move |w, cx| {
            crate::views::valves::ValvesSheet::for_tool(stores, id, tool.name, server, user, w, cx)
        });
    }
}

impl ToolEditor {
    /// Types `value` into field `field` (`name`, `id`, `description`,
    /// `code`): the E2E pass.
    pub fn set_field(
        &mut self,
        field: &str,
        value: &str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let value = value.to_string();
        match field {
            "name" => {
                // As typing does: an untouched id follows the name (a
                // programmatic set sends no change event).
                if self.id.is_none() && !self.id_typed {
                    let slug = id_from_name(&value);
                    self.tool_id
                        .update(cx, |s, cx| s.set_value(slug, window, cx));
                }
                self.name.update(cx, |s, cx| s.set_value(value, window, cx))
            }
            "id" => self
                .tool_id
                .update(cx, |s, cx| s.set_value(value, window, cx)),
            "description" => self
                .description
                .update(cx, |s, cx| s.set_value(value, window, cx)),
            "code" => self.code.update(cx, |s, cx| s.set_value(value, window, cx)),
            _ => {}
        }
        cx.notify();
    }

    /// Valves…: the tool's valves sheet.
    pub fn valves(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.open_valves(window, cx);
    }
}

impl ItemEditor for ToolEditor {
    fn item_id(&self) -> Option<String> {
        self.id.clone()
    }

    fn is_dirty(&self, cx: &App) -> bool {
        // A new tool: any field filled in or changed, as for a saved one.
        (self.id.is_none() || self.detail.is_some()) && self.form(cx) != self.initial
    }

    fn reload(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(id) = self.id.clone() else {
            return;
        };
        self.loading = self.detail.is_none();
        let call = self.rpc.call::<methods::WorkspaceGet>(&WorkspaceRef {
            kind: WorkspaceKind::Tools,
            id,
        });
        let handle = window.window_handle();
        self._load = Some(
            cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
                let result = call.await;
                let _ = handle.update(cx, |_, window, cx| {
                    let _ = this.update(cx, |s, cx| {
                        s.loading = false;
                        match result {
                            Ok(detail) => s.adopt(detail, window, cx),
                            Err(e) => {
                                log::warn!("workspace.get tool: {e}");
                                s.failure = Some(editor::failure_text(&e, &cx.l10n().clone()));
                            }
                        }
                        cx.notify();
                    });
                });
            }),
        );
        cx.notify();
    }

    fn save(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.saving || !self.writable() {
            return;
        }
        self.submitted = true;
        if !self.valid(cx) {
            cx.notify();
            return;
        }
        let creating = self.id.is_none();
        let form = self.form(cx);
        let sent = form.clone();
        let mut tool = self.dto().cloned().unwrap_or_default();
        tool.id = form.id;
        tool.name = form.name;
        tool.description = form.description;
        tool.content = form.content;
        let detail = WorkspaceDetail {
            kind: WorkspaceKind::Tools,
            model: None,
            knowledge: None,
            prompt: None,
            tool: Some(tool),
            skill: None,
            grants: vec![],
            write_access: true,
            owner_name: None,
            updated_at_ms: None,
        };
        self.saving = true;
        self.failure = None;
        cx.notify();
        let call = self.rpc.call::<methods::WorkspaceSave>(&WorkspaceSave {
            detail,
            create: creating,
            metadata_only: false,
        });
        let handle = window.window_handle();
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result = call.await;
            let _ = handle.update(cx, |_, window, cx| {
                let _ = this.update(cx, |s, cx| {
                    s.saving = false;
                    let l = cx.l10n().clone();
                    match result {
                        Ok(detail) => {
                            let id = editor::detail_id(&detail).unwrap_or_default();
                            // Typed on while it saved: that stays, still to
                            // save, in this editor.
                            let kept = s.form(cx) != sent;
                            if kept {
                                s.saved_under_edits(detail, sent, window, cx);
                            } else {
                                s.adopt(detail, window, cx);
                            }
                            s.stores.toasts.update(cx, |t, cx| {
                                t.show(NoticeLevel::Success, l.desktop_workspace_tool_saved(), cx)
                            });
                            cx.emit(if creating && !kept {
                                EditorEvent::Created(id)
                            } else {
                                EditorEvent::Saved(id)
                            });
                        }
                        Err(e) => {
                            log::warn!("workspace.save tool: {e}");
                            s.failure = Some(match e.args.get("version") {
                                Some(v) => l.desktop_workspace_tool_manifest_required_version(v),
                                None => editor::failure_text(&e, &l),
                            });
                        }
                    }
                    cx.notify();
                });
            });
        })
        .detach();
    }

    fn on_choice(&mut self, _: &SettingsChoice, _: &mut Window, _: &mut Context<Self>) {}
}

impl Render for ToolEditor {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let t = cx.conduit().clone();
        let r = t.roles;
        let l = cx.l10n().clone();
        let writable = self.writable();
        let creating = self.id.is_none();
        let (name_error, id_error, content_error) = self.errors(false, &l, cx);
        let form = self.form(cx);
        let view = cx.entity().downgrade();
        let mut body: Vec<AnyElement> = vec![];
        let mut basics = vec![
            forms::field(
                l.desktop_workspace_tool_name(),
                &self.name,
                None,
                name_error.map(Into::into),
                window,
                cx,
            )
            .into_any_element(),
        ];
        if creating {
            basics.push(
                forms::field(
                    l.desktop_workspace_tool_id(),
                    &self.tool_id,
                    Some(l.desktop_workspace_tool_id_hint().into()),
                    id_error.map(Into::into),
                    window,
                    cx,
                )
                .into_any_element(),
            );
        } else {
            basics.push(
                forms::form_row(
                    l.desktop_workspace_tool_id(),
                    crate::views::settings::controls::value(form.id.clone(), cx),
                    cx,
                )
                .into_any_element(),
            );
        }
        basics.push(
            forms::field(
                l.desktop_workspace_tool_description(),
                &self.description,
                None,
                None,
                window,
                cx,
            )
            .into_any_element(),
        );
        if let Some(active) = self.dto().and_then(|d| d.active)
            && !creating
        {
            let id = self.id.clone().unwrap_or_default();
            basics.push(
                forms::form_row(
                    l.desktop_workspace_active(),
                    Switch::new("tool-active", l.desktop_workspace_active(), active)
                        .disabled(!writable)
                        .on_click(Rc::new(move |_, window, cx| {
                            editor::dispatch_toggle(WorkspaceSection::Tools, id.clone(), window, cx)
                        })),
                    cx,
                )
                .into_any_element(),
            );
        }
        body.push(forms::form_group(basics, cx).into_any_element());
        if let Some(required) = self.dto().and_then(|d| d.requires_server_version.clone()) {
            body.push(
                forms::form_group(
                    vec![
                        warning_row(
                            l.desktop_workspace_tool_manifest(),
                            l.desktop_workspace_tool_manifest_required_version(&required),
                            div(),
                            cx,
                        )
                        .into_any_element(),
                    ],
                    cx,
                )
                .into_any_element(),
            );
        }
        // The source.
        let code = Editor::new(&self.code)
            .h(px(380.))
            .aria_label(l.workspace_tool_content())
            .readonly(!writable);
        body.push(
            forms::form_group(
                vec![
                    editor::stacked_row(
                        l.workspace_tool_content(),
                        div()
                            .id("tool-code")
                            .rounded(px(6.))
                            .overflow_hidden()
                            .child(code),
                        content_error
                            .map(SharedString::from)
                            .or_else(|| Some(l.workspace_tool_warning().into())),
                        cx,
                    )
                    .into_any_element(),
                ],
                cx,
            )
            .into_any_element(),
        );
        // What the server read from it.
        if let Some(tool) = self.dto().cloned()
            && !creating
        {
            let mut rows: Vec<AnyElement> = tool
                .functions
                .iter()
                .map(|f| {
                    div()
                        .px(px(12.))
                        .h(px(30.))
                        .flex()
                        .items_center()
                        .gap(px(8.))
                        .child(icon(IconName::Code, 13., r.text_subtle))
                        .child(
                            div()
                                .font_family(conduit_components::theme::MONO_FONT)
                                .text_size(px(t.metrics.small + 0.5))
                                .child(f.clone()),
                        )
                        .into_any_element()
                })
                .collect();
            if rows.is_empty() {
                rows.push(
                    div()
                        .px(px(12.))
                        .py(px(8.))
                        .text_color(r.text_subtle)
                        .child(l.desktop_workspace_tool_specs_empty())
                        .into_any_element(),
                );
            }
            body.push(
                grouped_section(
                    Some(
                        l.workspace_tool_function_count(tool.functions.len() as i64)
                            .into(),
                    ),
                    rows,
                    None,
                    cx,
                )
                .into_any_element(),
            );
            let server = tool.has_valves && writable;
            let user = tool.has_user_valves;
            if server || user {
                let open = view.clone();
                body.push(
                    div()
                        .flex()
                        .gap(px(8.))
                        .child(
                            Button::new("tool-valves", l.desktop_workspace_valves_ellipsis())
                                .icon(IconName::SlidersHorizontal)
                                .on_click(Rc::new(move |_, window, cx| {
                                    let _ = open.update(cx, |v, cx| v.open_valves(window, cx));
                                })),
                        )
                        .into_any_element(),
                );
            }
        }
        if creating && writable {
            let import = view.clone();
            body.push(
                div()
                    .flex()
                    .child(
                        Button::new("tool-import-url", l.desktop_workspace_import_from_url())
                            .ghost()
                            .icon(IconName::Link)
                            .on_click(Rc::new(move |_, window, cx| {
                                let _ = import.update(cx, |v, cx| v.import_from_url(window, cx));
                            })),
                    )
                    .into_any_element(),
            );
        }
        let item = self
            .detail
            .as_ref()
            .and_then(|d| editor::listed_item(&self.pane, WorkspaceSection::Tools, d, cx));
        let title = if creating {
            l.desktop_workspace_new_tool()
        } else if form.name.is_empty() {
            form.id.clone()
        } else {
            form.name.clone()
        };
        let subtitle = self
            .detail
            .as_ref()
            .and_then(|d| editor::subtitle(d.owner_name.as_deref(), d.write_access, &l));
        let dirty = self.is_dirty(cx);
        let _ = (Role::Group, relative(1.));
        editor::frame(
            "tool-editor",
            Frame {
                section: WorkspaceSection::Tools,
                title,
                subtitle,
                item,
                dirty,
                saving: self.saving,
                can_save: !self.submitted || self.valid(cx),
                read_only: !writable,
                creating,
                loading: self.loading,
                failure: self.failure.clone(),
                scroll: None,
            },
            self.pane.clone(),
            body,
            Rc::new(|v: &mut Self, window, cx| v.revert(window, cx)),
            Rc::new(|v: &mut Self, window, cx| v.save(window, cx)),
            cx,
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// An id typed while the new item was being made gives way to the id it
    /// was made with: the next Save updates that item, never another.
    #[gpui_kit::test]
    fn a_made_tool_keeps_the_id_it_was_made_with(cx: &mut gpui_kit::TestAppContext) {
        use crate::views::workspace::editor::bench;
        let (daemon, stores, vcx) = crate::views::sheet::bench::bench(cx);
        daemon.returns::<methods::WorkspaceSave>(bench::detail(
            WorkspaceKind::Tools,
            serde_json::json!({"id": "trail_tool", "name": "Trail tool", "description": "", "content": "class Tools:\n    pass\n"}),
        ));
        let editor = vcx.update(|window, cx| {
            cx.new(|cx| {
                ToolEditor::new(
                    stores.clone(),
                    WeakEntity::new_invalid(),
                    None,
                    bench::manage(),
                    window,
                    cx,
                )
            })
        });
        vcx.run_until_parked();
        let set = |field: &str, text: &str, vcx: &mut gpui_kit::VisualTestContext| {
            vcx.update(|window, cx| editor.update(cx, |e, cx| e.set_field(field, text, window, cx)))
        };
        set("name", "Trail tool", vcx);
        set("id", "trail_tool", vcx);
        let held = daemon.hold::<methods::WorkspaceSave>();
        vcx.update(|window, cx| editor.update(cx, |e, cx| e.save(window, cx)));
        vcx.run_until_parked();
        set("id", "other_tool", vcx);
        drop(held);
        vcx.run_until_parked();
        editor.read_with(vcx, |e, cx| {
            assert_eq!(e.id.as_deref(), Some("trail_tool"));
            assert_eq!(
                e.tool_id.read(cx).value().to_string(),
                "trail_tool",
                "the id field names another item than the one made"
            );
        });
    }

    /// A new tool asks before its edits go, whichever field they are in.
    #[gpui_kit::test]
    fn a_new_tools_description_alone_asks_before_it_goes(cx: &mut gpui_kit::TestAppContext) {
        use crate::views::workspace::editor::bench;
        let (_daemon, stores, vcx) = crate::views::sheet::bench::bench(cx);
        let editor = vcx.update(|window, cx| {
            cx.new(|cx| {
                ToolEditor::new(
                    stores.clone(),
                    WeakEntity::new_invalid(),
                    None,
                    bench::manage(),
                    window,
                    cx,
                )
            })
        });
        vcx.run_until_parked();
        assert!(!editor.read_with(vcx, |e, cx| e.is_dirty(cx)));
        vcx.update(|window, cx| {
            editor.update(cx, |e, cx| {
                e.set_field("description", "Finds trails", window, cx)
            })
        });
        assert!(
            editor.read_with(vcx, |e, cx| e.is_dirty(cx)),
            "a description typed into a new tool went without asking"
        );
    }

    /// Text typed while a save is out is kept, still to save.
    #[gpui_kit::test]
    fn text_typed_while_a_tool_saves_stays(cx: &mut gpui_kit::TestAppContext) {
        use crate::views::workspace::editor::bench;
        let (daemon, stores, vcx) = crate::views::sheet::bench::bench(cx);
        let item = |description: &str| {
            bench::detail(
                WorkspaceKind::Tools,
                serde_json::json!({"id": "trail_tool", "name": "Trail tool", "description": description, "content": "class Tools:\n    pass\n"}),
            )
        };
        daemon.returns::<methods::WorkspaceGet>(item("Finds trails"));
        daemon.returns::<methods::WorkspaceSave>(item("Finds day trails"));
        let editor = vcx.update(|window, cx| {
            cx.new(|cx| {
                ToolEditor::new(
                    stores.clone(),
                    WeakEntity::new_invalid(),
                    Some("trail_tool".into()),
                    bench::manage(),
                    window,
                    cx,
                )
            })
        });
        vcx.run_until_parked();
        let set = |text: &str, vcx: &mut gpui_kit::VisualTestContext| {
            vcx.update(|window, cx| {
                editor.update(cx, |e, cx| e.set_field("description", text, window, cx))
            })
        };
        set("Finds day trails", vcx);
        let held = daemon.hold::<methods::WorkspaceSave>();
        vcx.update(|window, cx| editor.update(cx, |e, cx| e.save(window, cx)));
        vcx.run_until_parked();
        set("Finds day trails nearby", vcx);
        drop(held);
        vcx.run_until_parked();
        editor.read_with(vcx, |e, cx| {
            assert_eq!(
                e.description.read(cx).value().to_string(),
                "Finds day trails nearby",
                "the save's answer replaced what was typed since"
            );
            assert!(e.is_dirty(cx), "the later words count as saved");
        });
        assert_eq!(daemon.calls::<methods::WorkspaceSave>().len(), 1);
    }

    #[test]
    fn tool_ids_are_python_identifiers() {
        assert!(id_is_valid("trail_weather"));
        assert!(id_is_valid("_private2"));
        assert!(!id_is_valid("2fast"));
        assert!(!id_is_valid("trail-weather"));
        assert!(!id_is_valid(""));
        assert_eq!(id_from_name("Trail Weather 2"), "trail_weather_2");
        assert_eq!(id_from_name("3D tools"), "_3d_tools");
    }
}
