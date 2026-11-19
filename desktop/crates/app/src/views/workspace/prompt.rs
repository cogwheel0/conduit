//! The prompt editor: name, slash command, tags and content (written, or
//! previewed as the chat would show it), the commit message a save
//! records, and the version history: each saved version, the one in
//! production marked Live, with Compare with Production, Restore, Set as
//! Production and Delete Version (the phone's version sheet).

use std::rc::Rc;

use conduit_components::ActiveConduitTheme as _;
use conduit_components::assets::IconName;
use conduit_components::views::kit::{
    Button, IconButton, Segment, Segmented, Switch, badge, grouped_section,
};
use conduit_components::views::markdown::text_view;
use conduit_protocol::{
    NoticeLevel, WorkspaceDetail, WorkspaceKind, WorkspacePromptDiffQuery, WorkspacePromptDto,
    WorkspacePromptHistory, WorkspacePromptVersion, WorkspacePromptVersionRef, WorkspaceRef,
    WorkspaceSave, WorkspaceSectionAccess, methods,
};
use gpui_kit::component::input::{InputEvent, InputState, Textarea, TextareaState};
use gpui_kit::component::native_menu::NativeMenu;
use gpui_kit::component::text::TextViewState;
use gpui_kit::prelude::*;
use gpui_kit::{
    AnyElement, App, AsyncApp, Context, ElementId, Entity, EventEmitter, FontWeight, Role,
    SharedString, Subscription, Task, WeakEntity, Window, div, px, relative,
};

use super::editor::{self, EditorEvent, Frame, ItemEditor};
use super::{WorkspacePane, sheets};
use crate::actions::SettingsChoice;
use crate::l10n::{ActiveL10n as _, L10n};
use crate::shell::sheet::{SheetSpec, present_sheet};
use crate::stores::Stores;
use crate::stores::navigation::WorkspaceSection;
use crate::stores::rpc::Rpc;
use crate::views::forms;

/// A prompt command's legal characters: letters, digits, `-` and `_`.
pub fn command_is_valid(command: &str) -> bool {
    let bare = command.trim().trim_start_matches('/');
    !bare.is_empty()
        && bare
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
}

/// A command from a prompt's name, while the command is untouched (the
/// phone fills it the same way): lower case, spaces to hyphens, the rest
/// left out. The daemon checks what is saved.
pub fn command_from_name(name: &str) -> String {
    name.trim()
        .to_lowercase()
        .split_whitespace()
        .collect::<Vec<_>>()
        .join("-")
        .chars()
        .filter(|c| c.is_ascii_alphanumeric() || *c == '-' || *c == '_')
        .collect()
}

/// What the form holds, for the edits check.
#[derive(Clone, Debug, Default, PartialEq)]
struct PromptForm {
    name: String,
    command: String,
    tags: String,
    content: String,
}

pub struct PromptEditor {
    stores: Stores,
    rpc: Rpc,
    pane: WeakEntity<WorkspacePane>,
    id: Option<String>,
    access: WorkspaceSectionAccess,
    pub detail: Option<WorkspaceDetail>,
    name: Entity<InputState>,
    command: Entity<InputState>,
    tags: Entity<InputState>,
    content: Entity<TextareaState>,
    commit: Entity<InputState>,
    /// A save puts the new version in production.
    production: bool,
    preview: Option<Entity<TextViewState>>,
    pub history: Option<WorkspacePromptHistory>,
    history_failed: bool,
    initial: PromptForm,
    /// The command was typed, so the name no longer fills it.
    command_typed: bool,
    /// The form was submitted once: its errors show.
    submitted: bool,
    saving: bool,
    loading: bool,
    failure: Option<String>,
    _subscriptions: Vec<Subscription>,
    _load: Option<Task<()>>,
    _history: Option<Task<()>>,
}

impl EventEmitter<EditorEvent> for PromptEditor {}

impl PromptEditor {
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
        let name = forms::input(l.desktop_workspace_prompt_name(), false, window, cx);
        let command = forms::input("summarize", false, window, cx);
        let tags = forms::input(l.desktop_workspace_comma_separated(), false, window, cx);
        let commit = forms::input(
            l.desktop_workspace_prompt_commit_message_hint(),
            false,
            window,
            cx,
        );
        let content = cx.new(|cx| {
            TextareaState::new(window, cx)
                .auto_grow(6, 24)
                .placeholder(l.desktop_workspace_prompt_content_hint())
        });
        let subscriptions = vec![
            cx.subscribe_in(&name, window, |this, state, e: &InputEvent, window, cx| {
                if matches!(e, InputEvent::Change) {
                    if this.id.is_none() && !this.command_typed {
                        let slug = command_from_name(&state.read(cx).value());
                        this.command
                            .update(cx, |c, cx| c.set_value(slug, window, cx));
                    }
                    this.failure = None;
                    cx.notify();
                }
            }),
            cx.subscribe_in(&command, window, |this, _, e: &InputEvent, _, cx| {
                if matches!(e, InputEvent::Change) {
                    this.command_typed = true;
                    this.failure = None;
                    cx.notify();
                }
            }),
            cx.subscribe_in(&tags, window, |_, _, e: &InputEvent, _, cx| {
                if matches!(e, InputEvent::Change) {
                    cx.notify();
                }
            }),
            cx.subscribe_in(&content, window, |this, _, e: &InputEvent, _, cx| {
                if matches!(e, InputEvent::Change) {
                    this.preview = None;
                    this.failure = None;
                    cx.notify();
                }
            }),
        ];
        let mut this = Self {
            stores,
            rpc,
            pane,
            id,
            access,
            detail: None,
            name,
            command,
            tags,
            content,
            commit,
            production: true,
            preview: None,
            history: None,
            history_failed: false,
            initial: PromptForm::default(),
            command_typed: false,
            submitted: false,
            saving: false,
            loading: false,
            failure: None,
            _subscriptions: subscriptions,
            _load: None,
            _history: None,
        };
        if this.id.is_some() {
            this.reload(window, cx);
        }
        this
    }

    fn form(&self, cx: &App) -> PromptForm {
        PromptForm {
            name: self.name.read(cx).value().trim().to_string(),
            command: self
                .command
                .read(cx)
                .value()
                .trim()
                .trim_start_matches('/')
                .to_string(),
            tags: editor::split_list(&self.tags.read(cx).value()).join(", "),
            content: self.content.read(cx).value().to_string(),
        }
    }

    fn writable(&self) -> bool {
        self.detail.as_ref().is_none_or(|d| d.write_access)
    }

    /// A save answered while the form had changed since it was sent: the
    /// saved item is the one shown now (its id, its detail, what counts as
    /// unchanged), and the form keeps what was typed since.
    fn saved_under_edits(&mut self, detail: WorkspaceDetail, sent: PromptForm) {
        let Some(id) = detail.prompt.as_ref().map(|i| i.id.clone()) else {
            return;
        };
        self.id = Some(id);
        self.detail = Some(detail);
        self.initial = sent;
        self.submitted = false;
    }

    /// Fills the form from `detail`.
    fn adopt(&mut self, detail: WorkspaceDetail, window: &mut Window, cx: &mut Context<Self>) {
        let Some(prompt) = detail.prompt.clone() else {
            return;
        };
        self.id = Some(prompt.id.clone());
        self.name
            .update(cx, |s, cx| s.set_value(prompt.name.clone(), window, cx));
        self.command
            .update(cx, |s, cx| s.set_value(prompt.command.clone(), window, cx));
        self.tags
            .update(cx, |s, cx| s.set_value(prompt.tags.join(", "), window, cx));
        self.content
            .update(cx, |s, cx| s.set_value(prompt.content.clone(), window, cx));
        self.commit.update(cx, |s, cx| s.set_value("", window, cx));
        self.command_typed = true;
        self.production = true;
        self.preview = None;
        self.detail = Some(detail);
        self.initial = self.form(cx);
        self.submitted = false;
        cx.notify();
    }

    fn load_history(&mut self, cx: &mut Context<Self>) {
        let Some(id) = self.id.clone() else {
            return;
        };
        let call = self
            .rpc
            .call::<methods::WorkspacePromptHistory>(&WorkspaceRef {
                kind: WorkspaceKind::Prompts,
                id,
            });
        self._history = Some(
            cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
                let result = call.await;
                let _ = this.update(cx, |s, cx| {
                    match result {
                        Ok(history) => {
                            s.history = Some(history);
                            s.history_failed = false;
                        }
                        Err(e) => {
                            log::warn!("workspace.promptHistory: {e}");
                            s.history_failed = true;
                        }
                    }
                    cx.notify();
                });
            }),
        );
    }

    /// The field errors, once the form was submitted.
    fn errors(&self, l: &L10n, cx: &App) -> (Option<String>, Option<String>, Option<String>) {
        if !self.submitted {
            return (None, None, None);
        }
        let form = self.form(cx);
        let name = form
            .name
            .is_empty()
            .then(|| l.desktop_workspace_prompt_name_required());
        let command = if form.command.is_empty() {
            Some(l.desktop_workspace_prompt_command_required())
        } else if !command_is_valid(&form.command) {
            Some(l.desktop_workspace_prompt_command_invalid())
        } else {
            None
        };
        let content = form
            .content
            .trim()
            .is_empty()
            .then(|| l.desktop_workspace_prompt_content_required());
        (name, command, content)
    }

    fn valid(&self, cx: &App) -> bool {
        let form = self.form(cx);
        !form.name.is_empty() && command_is_valid(&form.command) && !form.content.trim().is_empty()
    }

    fn dto(&self, cx: &App) -> WorkspacePromptDto {
        let form = self.form(cx);
        let loaded = self.detail.as_ref().and_then(|d| d.prompt.clone());
        let commit = self.commit.read(cx).value().trim().to_string();
        WorkspacePromptDto {
            id: self.id.clone().unwrap_or_default(),
            command: form.command,
            name: form.name,
            content: form.content,
            tags: editor::split_list(&form.tags),
            active: loaded.as_ref().is_none_or(|p| p.active),
            version_id: loaded.and_then(|p| p.version_id),
            commit_message: (!commit.is_empty()).then_some(commit),
            production: self.production,
        }
    }

    fn submit(&mut self, metadata_only: bool, window: &mut Window, cx: &mut Context<Self>) {
        if self.saving || !self.writable() {
            return;
        }
        self.submitted = true;
        if !self.valid(cx) {
            cx.notify();
            return;
        }
        let creating = self.id.is_none();
        let sent = self.form(cx);
        self.saving = true;
        self.failure = None;
        cx.notify();
        let detail = WorkspaceDetail {
            kind: WorkspaceKind::Prompts,
            model: None,
            knowledge: None,
            prompt: Some(self.dto(cx)),
            tool: None,
            skill: None,
            grants: vec![],
            write_access: true,
            owner_name: None,
            updated_at_ms: None,
        };
        let call = self.rpc.call::<methods::WorkspaceSave>(&WorkspaceSave {
            detail,
            create: creating,
            metadata_only,
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
                            // Update Details saves the name, command and
                            // tags only: the words stay as typed, unsaved.
                            let mut saved = sent.clone();
                            if metadata_only && let Some(p) = detail.prompt.as_ref() {
                                saved.content = p.content.clone();
                            }
                            let kept = s.form(cx) != saved;
                            if kept {
                                s.saved_under_edits(detail, saved);
                            } else {
                                s.adopt(detail, window, cx);
                            }
                            s.load_history(cx);
                            s.stores.toasts.update(cx, |t, cx| {
                                t.show(
                                    NoticeLevel::Success,
                                    if metadata_only {
                                        l.desktop_workspace_prompt_details_saved()
                                    } else {
                                        l.desktop_workspace_prompt_saved()
                                    },
                                    cx,
                                )
                            });
                            cx.emit(if creating && !kept {
                                EditorEvent::Created(id)
                            } else {
                                EditorEvent::Saved(id)
                            });
                        }
                        Err(e) => {
                            log::warn!("workspace.save prompt: {e}");
                            s.failure = Some(editor::failure_text(&e, &l));
                        }
                    }
                    cx.notify();
                });
            });
        })
        .detach();
    }

    fn revert(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        match self.detail.clone() {
            Some(detail) => self.adopt(detail, window, cx),
            None => cx.emit(EditorEvent::Closed),
        }
    }

    // ── Versions ───────────────────────────────────────────────────────

    fn version(&self, id: &str) -> Option<WorkspacePromptVersion> {
        self.history
            .as_ref()?
            .versions
            .iter()
            .find(|v| v.id == id)
            .cloned()
    }

    fn production_version(&self) -> Option<WorkspacePromptVersion> {
        self.history
            .as_ref()?
            .versions
            .iter()
            .find(|v| v.production)
            .cloned()
    }

    /// Runs `op` (`compare`, `restore`, `production`, `delete`) on version
    /// `version_id`.
    pub fn version_command(
        &mut self,
        op: &str,
        version_id: &str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let Some(prompt_id) = self.id.clone() else {
            return;
        };
        let Some(version) = self.version(version_id) else {
            return;
        };
        let l = cx.l10n().clone();
        match op {
            "compare" => {
                let Some(production) = self.production_version() else {
                    return;
                };
                let call =
                    self.rpc
                        .call::<methods::WorkspacePromptDiff>(&WorkspacePromptDiffQuery {
                            prompt_id,
                            from_id: production.id.clone(),
                            to_id: version.id.clone(),
                        });
                let handle = window.window_handle();
                let stores = self.stores.clone();
                let account = super::active_account(&stores, cx);
                cx.spawn(async move |_, cx: &mut AsyncApp| {
                    let result = call.await;
                    let _ = handle.update(cx, |_, window, cx| match result {
                        // Another account's now: this one's prompt is not
                        // shown to it.
                        _ if super::active_account(&stores, cx) != account => {}
                        Ok(diff) => sheets::open_diff(&stores, diff, window, cx),
                        Err(e) => {
                            log::warn!("workspace.promptDiff: {e}");
                            let text = cx.l10n().desktop_workspace_prompt_history_diff_failed();
                            stores
                                .toasts
                                .update(cx, |t, cx| t.show(NoticeLevel::Error, text, cx));
                        }
                    });
                })
                .detach();
            }
            "restore" => {
                // Into the form, to be saved as a new version.
                self.content
                    .update(cx, |s, cx| s.set_value(version.content.clone(), window, cx));
                if !version.name.is_empty() {
                    self.name
                        .update(cx, |s, cx| s.set_value(version.name.clone(), window, cx));
                }
                self.stores.toasts.update(cx, |t, cx| {
                    t.show(
                        NoticeLevel::Info,
                        l.desktop_workspace_prompt_history_restored(),
                        cx,
                    )
                });
                cx.notify();
            }
            "production" => {
                let call = self.rpc.call::<methods::WorkspacePromptSetVersion>(
                    &WorkspacePromptVersionRef {
                        prompt_id,
                        version_id: version.id.clone(),
                    },
                );
                let handle = window.window_handle();
                cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
                    let result = call.await;
                    let _ = handle.update(cx, |_, window, cx| {
                        let _ = this.update(cx, |s, cx| {
                            let l = cx.l10n().clone();
                            match result {
                                Ok(detail) => {
                                    if !s.is_dirty(cx) {
                                        s.adopt(detail, window, cx);
                                    } else {
                                        s.detail = Some(detail);
                                    }
                                    s.load_history(cx);
                                    s.stores.toasts.update(cx, |t, cx| {
                                        t.show(
                                            NoticeLevel::Success,
                                            l.desktop_workspace_prompt_history_production_set(),
                                            cx,
                                        )
                                    });
                                }
                                Err(e) => {
                                    log::warn!("workspace.promptSetVersion: {e}");
                                    s.failure = Some(editor::failure_text(&e, &l));
                                }
                            }
                            cx.notify();
                        });
                    });
                })
                .detach();
            }
            "delete" => {
                if version.production {
                    self.failure = Some(l.desktop_workspace_prompt_history_delete_production());
                    cx.notify();
                    return;
                }
                let spec = SheetSpec::new(
                    l.desktop_workspace_prompt_history_delete_confirm_title(),
                    l.desktop_workspace_prompt_history_delete_confirm_message(),
                    l.delete(),
                    l.cancel(),
                )
                .destructive();
                let ask = present_sheet(window, spec, cx);
                let call_rpc = self.rpc.clone();
                let version_id = version.id.clone();
                let stores = self.stores.clone();
                let account = super::active_account(&stores, cx);
                cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
                    if !ask.await {
                        return;
                    }
                    // Asked under one account: never deleted under the next.
                    if cx.update(|cx| super::active_account(&stores, cx)) != account {
                        return;
                    }
                    let result = call_rpc
                        .call::<methods::WorkspacePromptDeleteVersion>(&WorkspacePromptVersionRef {
                            prompt_id,
                            version_id,
                        })
                        .await;
                    let _ = this.update(cx, |s, cx| {
                        let l = cx.l10n().clone();
                        match result {
                            Ok(_) => {
                                s.load_history(cx);
                                s.stores.toasts.update(cx, |t, cx| {
                                    t.show(
                                        NoticeLevel::Success,
                                        l.desktop_workspace_prompt_history_deleted(),
                                        cx,
                                    )
                                });
                            }
                            Err(e) => {
                                log::warn!("workspace.promptDeleteVersion: {e}");
                                s.failure = Some(editor::failure_text(&e, &l));
                            }
                        }
                        cx.notify();
                    });
                })
                .detach();
            }
            _ => {}
        }
    }

    fn version_row(
        &self,
        index: usize,
        version: &WorkspacePromptVersion,
        l: &L10n,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let t = cx.conduit().clone();
        let r = t.roles;
        let now = chrono::Local::now();
        let when = if version.created_at_ms > 0 {
            crate::views::dates::stamp(version.created_at_ms, &now, l).0
        } else {
            String::new()
        };
        let message = version
            .commit_message
            .clone()
            .filter(|m| !m.trim().is_empty())
            .unwrap_or_else(|| l.desktop_workspace_prompt_history_commit_fallback());
        let detail = [version.author_name.clone().unwrap_or_default(), when]
            .into_iter()
            .filter(|s| !s.is_empty())
            .collect::<Vec<_>>()
            .join(" · ");
        let writable = self.writable();
        let id = version.id.clone();
        let production = version.production;
        let has_production = self.production_version().is_some();
        let label = SharedString::from(format!("{message}, {detail}"));
        div()
            .id(ElementId::NamedInteger(
                "prompt-version".into(),
                index as u64,
            ))
            .role(Role::Row)
            .aria_label(label)
            .px(px(12.))
            .min_h(px(46.))
            .flex()
            .items_center()
            .gap(px(10.))
            .child(
                div()
                    .flex_1()
                    .min_w_0()
                    .flex()
                    .flex_col()
                    .child(
                        div()
                            .flex()
                            .items_center()
                            .gap(px(6.))
                            .child(div().min_w_0().truncate().child(message))
                            .when(production, |d| {
                                d.child(badge(
                                    l.desktop_workspace_prompt_history_live(),
                                    conduit_components::theme::with_alpha(r.success, 0.16),
                                    r.text,
                                    cx,
                                ))
                            }),
                    )
                    .child(
                        div()
                            .truncate()
                            .text_size(px(t.metrics.small))
                            .text_color(r.text_subtle)
                            .child(detail),
                    ),
            )
            .child(
                IconButton::new(
                    ElementId::NamedInteger("prompt-version-menu".into(), index as u64),
                    IconName::Ellipsis,
                    l.workspace_editor_more_actions(),
                )
                .size(26., 14.)
                .on_click(Rc::new({
                    let l = l.clone();
                    move |e, window, cx| {
                        let choice = |op: &str| -> Box<dyn gpui_kit::Action> {
                            Box::new(SettingsChoice {
                                menu: "prompt-version".into(),
                                value: format!("{op}:{id}"),
                            })
                        };
                        let mut menu = NativeMenu::new();
                        if has_production && !production {
                            menu = menu.menu(l.workspace_prompt_history_diff(), choice("compare"));
                        }
                        if writable {
                            menu =
                                menu.menu(l.workspace_prompt_history_restore(), choice("restore"));
                            if !production {
                                menu = menu
                                    .menu(
                                        l.workspace_prompt_history_set_production(),
                                        choice("production"),
                                    )
                                    .separator()
                                    .menu(l.workspace_prompt_history_delete(), choice("delete"));
                            }
                        }
                        if !menu.is_empty() {
                            menu.show(e.position(), window, cx);
                        }
                    }
                })),
            )
            .into_any_element()
    }

    fn history_section(&self, l: &L10n, cx: &mut Context<Self>) -> AnyElement {
        let t = cx.conduit().clone();
        let mut rows: Vec<AnyElement> = vec![];
        match &self.history {
            None => rows.push(
                div()
                    .px(px(12.))
                    .py(px(10.))
                    .text_color(t.roles.text_subtle)
                    .child(if self.history_failed {
                        l.desktop_workspace_prompt_history_load_failed()
                    } else {
                        l.desktop_loading()
                    })
                    .into_any_element(),
            ),
            Some(history) if history.versions.is_empty() => rows.push(
                div()
                    .px(px(12.))
                    .py(px(10.))
                    .text_color(t.roles.text_subtle)
                    .child(l.desktop_workspace_prompt_history_empty())
                    .into_any_element(),
            ),
            Some(history) => {
                let versions = history.versions.clone();
                for (i, v) in versions.iter().enumerate() {
                    rows.push(self.version_row(i, v, l, cx));
                }
            }
        }
        grouped_section(Some(l.workspace_prompt_history().into()), rows, None, cx)
            .into_any_element()
    }
}

impl PromptEditor {
    /// Types `value` into field `field` (`name`, `command`, `tags`,
    /// `content`, `commit`): the E2E pass.
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
                if self.id.is_none() && !self.command_typed {
                    let slug = command_from_name(&value);
                    self.command
                        .update(cx, |s, cx| s.set_value(slug, window, cx));
                }
                self.name.update(cx, |s, cx| s.set_value(value, window, cx))
            }
            "command" => self
                .command
                .update(cx, |s, cx| s.set_value(value, window, cx)),
            "tags" => self.tags.update(cx, |s, cx| s.set_value(value, window, cx)),
            "content" => self
                .content
                .update(cx, |s, cx| s.set_value(value, window, cx)),
            "commit" => self
                .commit
                .update(cx, |s, cx| s.set_value(value, window, cx)),
            _ => {}
        }
        cx.notify();
    }
}

impl ItemEditor for PromptEditor {
    fn item_id(&self) -> Option<String> {
        self.id.clone()
    }

    fn is_dirty(&self, cx: &App) -> bool {
        if self.id.is_none() {
            let form = self.form(cx);
            return form != PromptForm::default();
        }
        self.detail.is_some() && self.form(cx) != self.initial
    }

    fn reload(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(id) = self.id.clone() else {
            return;
        };
        self.loading = self.detail.is_none();
        let call = self.rpc.call::<methods::WorkspaceGet>(&WorkspaceRef {
            kind: WorkspaceKind::Prompts,
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
                                log::warn!("workspace.get prompt: {e}");
                                s.failure = Some(editor::failure_text(&e, &cx.l10n().clone()));
                            }
                        }
                        cx.notify();
                    });
                });
            }),
        );
        self.load_history(cx);
        cx.notify();
    }

    fn save(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.submit(false, window, cx);
    }

    fn on_choice(&mut self, action: &SettingsChoice, window: &mut Window, cx: &mut Context<Self>) {
        if action.menu == "prompt-version"
            && let Some((op, id)) = action.value.split_once(':')
        {
            let (op, id) = (op.to_string(), id.to_string());
            self.version_command(&op, &id, window, cx);
        } else if action.menu == "prompt-tab" {
            self.preview = (action.value == "preview")
                .then(|| cx.new(|cx| TextViewState::markdown(&self.content.read(cx).value(), cx)));
            cx.notify();
        }
    }
}

impl Render for PromptEditor {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let t = cx.conduit().clone();
        let l = cx.l10n().clone();
        let writable = self.writable() && self.access.manage;
        let creating = self.id.is_none();
        let (name_error, command_error, content_error) = self.errors(&l, cx);
        let form = self.form(cx);
        let title = if creating {
            l.workspace_prompt_create_title()
        } else if form.name.is_empty() {
            self.detail
                .as_ref()
                .and_then(|d| d.prompt.as_ref())
                .map(|p| p.name.clone())
                .unwrap_or_default()
        } else {
            form.name.clone()
        };
        let mut body: Vec<AnyElement> = vec![];
        body.push(
            forms::form_group(
                vec![
                    forms::field(
                        l.desktop_workspace_prompt_name(),
                        &self.name,
                        None,
                        name_error.map(Into::into),
                        window,
                        cx,
                    )
                    .into_any_element(),
                    forms::field(
                        l.desktop_workspace_prompt_command(),
                        &self.command,
                        Some(l.desktop_workspace_prompt_command_hint().into()),
                        command_error.map(Into::into),
                        window,
                        cx,
                    )
                    .into_any_element(),
                    forms::field(
                        l.desktop_workspace_prompt_tags(),
                        &self.tags,
                        None,
                        None,
                        window,
                        cx,
                    )
                    .into_any_element(),
                ],
                cx,
            )
            .into_any_element(),
        );
        // Content: written, or previewed.
        let previewing = self.preview.is_some();
        let view = cx.entity().downgrade();
        let tabs = Segmented::new(
            "prompt-content-tab",
            l.workspace_prompt_content(),
            vec![
                Segment::new(l.desktop_workspace_prompt_write_tab()),
                Segment::new(l.desktop_workspace_prompt_preview_tab()),
            ],
            usize::from(previewing),
        )
        .on_select(Rc::new(move |i, window, cx| {
            let _ = view.update(cx, |v, cx| {
                v.on_choice(
                    &SettingsChoice {
                        menu: "prompt-tab".into(),
                        value: if i == 1 { "preview" } else { "write" }.into(),
                    },
                    window,
                    cx,
                )
            });
        }));
        let content: AnyElement = match &self.preview {
            Some(preview) if form.content.trim().is_empty() => div()
                .min_h(px(120.))
                .text_color(t.roles.text_subtle)
                .child(l.desktop_workspace_prompt_preview_empty())
                .into_any_element(),
            Some(preview) => div()
                .id("prompt-preview")
                .min_h(px(120.))
                .child(text_view(preview))
                .into_any_element(),
            None => Textarea::new(&self.content).into_any_element(),
        };
        body.push(
            forms::form_group(
                vec![
                    div()
                        .p(px(12.))
                        .flex()
                        .flex_col()
                        .gap(px(8.))
                        .child(
                            div()
                                .flex()
                                .items_center()
                                .child(
                                    div()
                                        .flex_1()
                                        .text_size(px(t.metrics.control))
                                        .child(l.workspace_prompt_content()),
                                )
                                .child(tabs),
                        )
                        .child(content)
                        .when_some(content_error, |d, e| {
                            d.child(
                                div()
                                    .id("prompt-content-error")
                                    .role(Role::Alert)
                                    .text_size(px(t.metrics.small))
                                    .text_color(t.roles.danger)
                                    .child(e),
                            )
                        })
                        .when(!previewing, |d| {
                            d.child(
                                div()
                                    .text_size(px(t.metrics.small))
                                    .line_height(relative(1.35))
                                    .text_color(t.roles.text_subtle)
                                    .child(l.desktop_workspace_prompt_variables_hint()),
                            )
                        })
                        .into_any_element(),
                ],
                cx,
            )
            .into_any_element(),
        );
        if writable {
            let mut rows = vec![
                forms::field(
                    l.workspace_prompt_commit_message(),
                    &self.commit,
                    None,
                    None,
                    window,
                    cx,
                )
                .into_any_element(),
            ];
            if !creating {
                let view = cx.entity().downgrade();
                rows.push(
                    forms::form_row(
                        l.workspace_prompt_set_production(),
                        Switch::new(
                            "prompt-production",
                            l.workspace_prompt_set_production(),
                            self.production,
                        )
                        .on_click(Rc::new(move |_, _, cx| {
                            let _ = view.update(cx, |v, cx| {
                                v.production = !v.production;
                                cx.notify();
                            });
                        })),
                        cx,
                    )
                    .into_any_element(),
                );
            }
            let footer = (!creating).then(|| l.desktop_workspace_prompt_set_production_subtitle());
            body.push(
                grouped_section(
                    Some(l.desktop_workspace_prompt_version_section().into()),
                    rows,
                    footer.map(Into::into),
                    cx,
                )
                .into_any_element(),
            );
            if !creating {
                let view = cx.entity().downgrade();
                let changed = self.is_dirty(cx);
                body.push(
                    div()
                        .flex()
                        .justify_end()
                        .child(
                            Button::new("prompt-save-details", l.workspace_prompt_update_details())
                                .ghost()
                                .disabled(!changed || self.saving)
                                .on_click(Rc::new(move |_, window, cx| {
                                    let _ = view.update(cx, |v, cx| v.submit(true, window, cx));
                                })),
                        )
                        .into_any_element(),
                );
            }
        }
        if !creating {
            body.push(self.history_section(&l, cx));
        }
        let item = self
            .detail
            .as_ref()
            .and_then(|d| editor::listed_item(&self.pane, WorkspaceSection::Prompts, d, cx));
        let subtitle = self.detail.as_ref().and_then(|d| {
            let command = d.prompt.as_ref().map(|p| format!("/{}", p.command));
            let base = editor::subtitle(d.owner_name.as_deref(), d.write_access, &l);
            match (command, base) {
                (Some(c), Some(b)) => Some(format!("{c} · {b}")),
                (c, b) => c.or(b),
            }
        });
        let dirty = self.is_dirty(cx);
        let can_save = self.valid(cx) || !self.submitted;
        let _ = FontWeight::NORMAL;
        editor::frame(
            "prompt-editor",
            Frame {
                section: WorkspaceSection::Prompts,
                title,
                subtitle,
                item,
                dirty,
                saving: self.saving,
                can_save,
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

    /// Update Details saves the name, command and tags: words changed
    /// beside them stay, still to save.
    #[gpui_kit::test]
    fn update_details_keeps_the_words_changed_beside_them(cx: &mut gpui_kit::TestAppContext) {
        use crate::views::workspace::editor::bench;
        let (daemon, stores, vcx) = crate::views::sheet::bench::bench(cx);
        let item = |name: &str| {
            bench::detail(
                WorkspaceKind::Prompts,
                serde_json::json!({"id": "p1", "command": "trail", "name": name,
                                   "content": "Plan a hike", "tags": [], "active": true,
                                   "production": true}),
            )
        };
        daemon.returns::<methods::WorkspaceGet>(item("Trail"));
        daemon.returns::<methods::WorkspaceSave>(item("Trail walk"));
        let editor = vcx.update(|window, cx| {
            cx.new(|cx| {
                PromptEditor::new(
                    stores.clone(),
                    WeakEntity::new_invalid(),
                    Some("p1".into()),
                    bench::manage(),
                    window,
                    cx,
                )
            })
        });
        vcx.run_until_parked();
        vcx.update(|window, cx| {
            editor.update(cx, |e, cx| {
                e.set_field("name", "Trail walk", window, cx);
                e.set_field("content", "Plan a day hike", window, cx);
                e.submit(true, window, cx);
            })
        });
        vcx.run_until_parked();
        editor.read_with(vcx, |e, cx| {
            assert_eq!(
                e.content.read(cx).value().to_string(),
                "Plan a day hike",
                "Update Details put the saved words back over the changed ones"
            );
            assert!(e.is_dirty(cx), "the changed words count as saved");
        });
    }

    /// A comparison read, or a version delete asked, under one account is
    /// neither shown nor done once another signs in.
    #[gpui_kit::test]
    fn nothing_asked_about_a_version_reaches_another_account(cx: &mut gpui_kit::TestAppContext) {
        use crate::views::sheet::bench::{bench, switch_account};
        use crate::views::workspace::editor::bench as editor_bench;
        let (daemon, stores, vcx) = bench(cx);
        let version = |id: &str, production: bool| {
            serde_json::json!({"id": id, "createdAtMs": 0, "name": "Trail", "command": "trail",
                               "content": "Plan a hike", "production": production})
        };
        daemon.returns::<methods::WorkspaceGet>(editor_bench::detail(
            WorkspaceKind::Prompts,
            serde_json::json!({"id": "p1", "command": "trail", "name": "Trail",
                               "content": "Plan a hike", "tags": [], "active": true,
                               "production": true}),
        ));
        daemon.returns::<methods::WorkspacePromptHistory>(
            serde_json::from_value(serde_json::json!({
                "promptId": "p1", "versions": [version("v1", true), version("v2", false)]
            }))
            .unwrap(),
        );
        daemon.returns::<methods::WorkspacePromptDiff>(
            serde_json::from_value(serde_json::json!({"lines": ["-Plan a hike", "+Plan a walk"]}))
                .unwrap(),
        );
        let editor = vcx.update(|window, cx| {
            cx.new(|cx| {
                PromptEditor::new(
                    stores.clone(),
                    WeakEntity::new_invalid(),
                    Some("p1".into()),
                    editor_bench::manage(),
                    window,
                    cx,
                )
            })
        });
        vcx.run_until_parked();
        assert!(editor.read_with(vcx, |e, _| e.version("v2").is_some()));
        let held = daemon.hold::<methods::WorkspacePromptDiff>();
        // Delete is answered "yes" only once the next account signed in.
        vcx.update(|_, cx| cx.set_global(crate::shell::sheet::AutoAnswer(Some(true))));
        vcx.update(|window, cx| {
            editor.update(cx, |e, cx| {
                e.version_command("compare", "v2", window, cx);
                e.version_command("delete", "v2", window, cx);
            })
        });
        switch_account(&stores, vcx);
        drop(held);
        vcx.run_until_parked();
        assert!(
            vcx.update(|_, cx| crate::views::sheet::current::<sheets::DiffSheet>(cx))
                .is_none(),
            "Avery's prompt was shown under Blake"
        );
        assert!(
            daemon
                .calls::<methods::WorkspacePromptDeleteVersion>()
                .is_empty(),
            "Avery's version was deleted under Blake"
        );
    }

    /// Text typed while a save is out is kept, still to save.
    #[gpui_kit::test]
    fn text_typed_while_a_prompt_saves_stays(cx: &mut gpui_kit::TestAppContext) {
        use crate::views::workspace::editor::bench;
        let (daemon, stores, vcx) = crate::views::sheet::bench::bench(cx);
        let item = |content: &str| {
            bench::detail(
                WorkspaceKind::Prompts,
                serde_json::json!({"id": "p1", "command": "trail", "name": "Trail", "content": content, "tags": [], "active": true, "production": true}),
            )
        };
        daemon.returns::<methods::WorkspaceGet>(item("Plan a hike"));
        daemon.returns::<methods::WorkspaceSave>(item("Plan a day hike"));
        let editor = vcx.update(|window, cx| {
            cx.new(|cx| {
                PromptEditor::new(
                    stores.clone(),
                    WeakEntity::new_invalid(),
                    Some("p1".into()),
                    bench::manage(),
                    window,
                    cx,
                )
            })
        });
        vcx.run_until_parked();
        let set = |text: &str, vcx: &mut gpui_kit::VisualTestContext| {
            vcx.update(|window, cx| {
                editor.update(cx, |e, cx| e.set_field("content", text, window, cx))
            })
        };
        set("Plan a day hike", vcx);
        let held = daemon.hold::<methods::WorkspaceSave>();
        vcx.update(|window, cx| editor.update(cx, |e, cx| e.save(window, cx)));
        vcx.run_until_parked();
        set("Plan a day hike with a picnic", vcx);
        drop(held);
        vcx.run_until_parked();
        editor.read_with(vcx, |e, cx| {
            assert_eq!(
                e.content.read(cx).value().to_string(),
                "Plan a day hike with a picnic",
                "the save's answer replaced what was typed since"
            );
            assert!(e.is_dirty(cx), "the later words count as saved");
        });
        assert_eq!(daemon.calls::<methods::WorkspaceSave>().len(), 1);
    }

    #[test]
    fn commands_take_letters_digits_hyphens_and_underscores() {
        assert!(command_is_valid("summarize"));
        assert!(command_is_valid("/trail_notes-2"));
        assert!(!command_is_valid(""));
        assert!(!command_is_valid("/"));
        assert!(!command_is_valid("two words"));
        assert!(!command_is_valid("café"));
    }

    #[test]
    fn a_name_fills_the_command_until_one_is_typed() {
        assert_eq!(command_from_name("  Trail Notes 2 "), "trail-notes-2");
        assert_eq!(command_from_name("Ünïcode & more"), "ncode--more");
    }
}
