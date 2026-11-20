//! The skill editor: a skill's name, id and description, and its
//! instructions in Markdown (written, or previewed), as the phone's skill
//! editor; switched on and off from the list or here.

use std::rc::Rc;

use conduit_components::ActiveConduitTheme as _;
use conduit_components::views::kit::{Segment, Segmented, Switch};
use conduit_components::views::markdown::text_view;
use conduit_protocol::{
    NoticeLevel, WorkspaceDetail, WorkspaceKind, WorkspaceRef, WorkspaceSave,
    WorkspaceSectionAccess, WorkspaceSkillDto, methods,
};
use gpui_kit::component::input::{InputEvent, InputState, Textarea, TextareaState};
use gpui_kit::component::text::TextViewState;
use gpui_kit::prelude::*;
use gpui_kit::{
    AnyElement, App, AsyncApp, Context, Entity, EventEmitter, Role, Subscription, Task, WeakEntity,
    Window, div, px,
};

use super::WorkspacePane;
use super::editor::{self, EditorEvent, Frame, ItemEditor};
use super::prompt::{command_from_name, command_is_valid};
use crate::actions::SettingsChoice;
use crate::l10n::{ActiveL10n as _, L10n};
use crate::stores::Stores;
use crate::stores::navigation::WorkspaceSection;
use crate::stores::rpc::Rpc;
use crate::views::forms;

#[derive(Clone, Debug, Default, PartialEq)]
struct SkillForm {
    name: String,
    id: String,
    description: String,
    content: String,
}

pub struct SkillEditor {
    stores: Stores,
    rpc: Rpc,
    pane: WeakEntity<WorkspacePane>,
    id: Option<String>,
    access: WorkspaceSectionAccess,
    pub detail: Option<WorkspaceDetail>,
    name: Entity<InputState>,
    skill_id: Entity<InputState>,
    description: Entity<InputState>,
    content: Entity<TextareaState>,
    preview: Option<Entity<TextViewState>>,
    initial: SkillForm,
    id_typed: bool,
    submitted: bool,
    saving: bool,
    loading: bool,
    failure: Option<String>,
    _subscriptions: Vec<Subscription>,
    _load: Option<Task<()>>,
}

impl EventEmitter<EditorEvent> for SkillEditor {}

impl SkillEditor {
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
        let name = forms::input(l.desktop_workspace_skill_name_hint(), false, window, cx);
        let skill_id = forms::input(l.desktop_workspace_skill_id_hint(), false, window, cx);
        let description = forms::input(
            l.desktop_workspace_skill_description_hint(),
            false,
            window,
            cx,
        );
        let content = cx.new(|cx| {
            TextareaState::new(window, cx)
                .auto_grow(8, 28)
                .placeholder(l.desktop_workspace_skill_content_hint())
        });
        let subscriptions = vec![
            cx.subscribe_in(&name, window, |this, state, e: &InputEvent, window, cx| {
                if matches!(e, InputEvent::Change) {
                    if this.id.is_none() && !this.id_typed {
                        let slug = command_from_name(&state.read(cx).value());
                        this.skill_id
                            .update(cx, |s, cx| s.set_value(slug, window, cx));
                    }
                    this.failure = None;
                    cx.notify();
                }
            }),
            cx.subscribe_in(&skill_id, window, |this, _, e: &InputEvent, _, cx| {
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
            skill_id,
            description,
            content,
            preview: None,
            initial: SkillForm::default(),
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
        }
        this
    }

    fn form(&self, cx: &App) -> SkillForm {
        SkillForm {
            name: self.name.read(cx).value().trim().to_string(),
            id: self.skill_id.read(cx).value().trim().to_string(),
            description: self.description.read(cx).value().trim().to_string(),
            content: self.content.read(cx).value().to_string(),
        }
    }

    fn dto(&self) -> Option<&WorkspaceSkillDto> {
        self.detail.as_ref()?.skill.as_ref()
    }

    fn writable(&self) -> bool {
        self.access.manage && self.detail.as_ref().is_none_or(|d| d.write_access)
    }

    /// A save answered while the form had changed since it was sent: the
    /// saved item is the one shown now (its id, its detail, what counts as
    /// unchanged), and the form keeps what was typed since.
    fn saved_under_edits(
        &mut self,
        detail: WorkspaceDetail,
        mut sent: SkillForm,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let Some(id) = detail.skill.as_ref().map(|i| i.id.clone()) else {
            return;
        };
        // Made: its id is the one it was made with, whatever the field
        // holds now, so the next Save updates this item.
        self.skill_id
            .update(cx, |s, cx| s.set_value(id.clone(), window, cx));
        sent.id = id.clone();
        self.id = Some(id);
        self.detail = Some(detail);
        self.initial = sent;
        self.submitted = false;
    }

    fn adopt(&mut self, detail: WorkspaceDetail, window: &mut Window, cx: &mut Context<Self>) {
        let Some(skill) = detail.skill.clone() else {
            return;
        };
        self.id = Some(skill.id.clone());
        self.name
            .update(cx, |s, cx| s.set_value(skill.name.clone(), window, cx));
        self.skill_id
            .update(cx, |s, cx| s.set_value(skill.id.clone(), window, cx));
        self.description.update(cx, |s, cx| {
            s.set_value(skill.description.clone(), window, cx)
        });
        self.content
            .update(cx, |s, cx| s.set_value(skill.content.clone(), window, cx));
        self.preview = None;
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
                .then(|| l.desktop_workspace_skill_name_required()),
            if form.id.is_empty() {
                Some(l.desktop_workspace_skill_id_required())
            } else if self.id.is_none() && !command_is_valid(&form.id) {
                // Only a skill being made: one made elsewhere keeps its id.
                Some(l.desktop_workspace_skill_id_invalid())
            } else {
                None
            },
            form.content
                .trim()
                .is_empty()
                .then(|| l.desktop_workspace_skill_content_required()),
        )
    }

    fn valid(&self, cx: &App) -> bool {
        let l = cx.l10n().clone();
        let (a, b, c) = self.errors(true, &l, cx);
        a.is_none() && b.is_none() && c.is_none()
    }
}

impl SkillEditor {
    /// Types `value` into field `field` (`name`, `id`, `description`,
    /// `content`): the E2E pass.
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
                    let slug = command_from_name(&value);
                    self.skill_id
                        .update(cx, |s, cx| s.set_value(slug, window, cx));
                }
                self.name.update(cx, |s, cx| s.set_value(value, window, cx))
            }
            "id" => {
                // As typed: the name no longer moves it (a programmatic set
                // sends no change event).
                self.id_typed = true;
                self.skill_id
                    .update(cx, |s, cx| s.set_value(value, window, cx))
            }
            "description" => self
                .description
                .update(cx, |s, cx| s.set_value(value, window, cx)),
            "content" => self
                .content
                .update(cx, |s, cx| s.set_value(value, window, cx)),
            _ => {}
        }
        cx.notify();
    }
}

impl ItemEditor for SkillEditor {
    fn item_id(&self) -> Option<String> {
        self.id.clone()
    }

    fn is_dirty(&self, cx: &App) -> bool {
        if self.id.is_none() {
            return self.form(cx) != SkillForm::default();
        }
        self.detail.is_some() && self.form(cx) != self.initial
    }

    fn reload(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(id) = self.id.clone() else {
            return;
        };
        self.loading = self.detail.is_none();
        let call = self.rpc.call::<methods::WorkspaceGet>(&WorkspaceRef {
            kind: WorkspaceKind::Skills,
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
                                log::warn!("workspace.get skill: {e}");
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
        let skill = WorkspaceSkillDto {
            id: form.id,
            name: form.name,
            description: form.description,
            content: form.content,
            active: self.dto().is_none_or(|s| s.active),
        };
        let detail = WorkspaceDetail {
            kind: WorkspaceKind::Skills,
            model: None,
            knowledge: None,
            prompt: None,
            tool: None,
            skill: Some(skill),
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
                                t.show(NoticeLevel::Success, l.desktop_workspace_skill_saved(), cx)
                            });
                            cx.emit(if creating && !kept {
                                EditorEvent::Created(id)
                            } else {
                                EditorEvent::Saved(id)
                            });
                        }
                        Err(e) => {
                            log::warn!("workspace.save skill: {e}");
                            s.failure = Some(editor::failure_text(&e, &l));
                        }
                    }
                    cx.notify();
                });
            });
        })
        .detach();
    }

    fn on_choice(&mut self, action: &SettingsChoice, _: &mut Window, cx: &mut Context<Self>) {
        if action.menu == "skill-tab" {
            self.preview = (action.value == "preview")
                .then(|| cx.new(|cx| TextViewState::markdown(&self.content.read(cx).value(), cx)));
            cx.notify();
        }
    }
}

impl Render for SkillEditor {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let t = cx.conduit().clone();
        let l = cx.l10n().clone();
        let writable = self.writable();
        let creating = self.id.is_none();
        let (name_error, id_error, content_error) = self.errors(false, &l, cx);
        let form = self.form(cx);
        let mut basics = vec![
            forms::field(
                l.desktop_workspace_skill_name(),
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
                    l.desktop_workspace_skill_id(),
                    &self.skill_id,
                    None,
                    id_error.map(Into::into),
                    window,
                    cx,
                )
                .into_any_element(),
            );
        } else {
            basics.push(
                forms::form_row(
                    l.desktop_workspace_skill_id(),
                    crate::views::settings::controls::value(form.id.clone(), cx),
                    cx,
                )
                .into_any_element(),
            );
        }
        basics.push(
            forms::field(
                l.desktop_workspace_skill_description(),
                &self.description,
                None,
                None,
                window,
                cx,
            )
            .into_any_element(),
        );
        if let Some(skill) = self.dto()
            && !creating
        {
            let id = skill.id.clone();
            basics.push(
                forms::form_row(
                    l.desktop_workspace_active(),
                    Switch::new("skill-active", l.desktop_workspace_active(), skill.active)
                        .disabled(!writable)
                        .on_click(Rc::new(move |_, window, cx| {
                            editor::dispatch_toggle(
                                WorkspaceSection::Skills,
                                id.clone(),
                                window,
                                cx,
                            )
                        })),
                    cx,
                )
                .into_any_element(),
            );
        }
        let previewing = self.preview.is_some();
        let view = cx.entity().downgrade();
        let tabs = Segmented::new(
            "skill-content-tab",
            l.desktop_workspace_skill_content(),
            vec![
                Segment::new(l.desktop_workspace_skill_write_tab()),
                Segment::new(l.desktop_workspace_skill_preview_tab()),
            ],
            usize::from(previewing),
        )
        .on_select(Rc::new(move |i, window, cx| {
            let _ = view.update(cx, |v, cx| {
                v.on_choice(
                    &SettingsChoice {
                        menu: "skill-tab".into(),
                        value: if i == 1 { "preview" } else { "write" }.into(),
                    },
                    window,
                    cx,
                )
            });
        }));
        let content: AnyElement = match &self.preview {
            Some(_) if form.content.trim().is_empty() => div()
                .min_h(px(160.))
                .text_color(t.roles.text_subtle)
                .child(l.desktop_workspace_skill_preview_empty())
                .into_any_element(),
            Some(preview) => div()
                .id("skill-preview")
                .min_h(px(160.))
                .child(text_view(preview))
                .into_any_element(),
            None => Textarea::new(&self.content).into_any_element(),
        };
        let body: Vec<AnyElement> = vec![
            forms::form_group(basics, cx).into_any_element(),
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
                                        .child(l.desktop_workspace_skill_content()),
                                )
                                .child(tabs),
                        )
                        .child(content)
                        .when_some(content_error, |d, e| {
                            d.child(
                                div()
                                    .id("skill-content-error")
                                    .role(Role::Alert)
                                    .text_size(px(t.metrics.small))
                                    .text_color(t.roles.danger)
                                    .child(e),
                            )
                        })
                        .into_any_element(),
                ],
                cx,
            )
            .into_any_element(),
        ];
        let item = self
            .detail
            .as_ref()
            .and_then(|d| editor::listed_item(&self.pane, WorkspaceSection::Skills, d, cx));
        let title = if creating {
            l.workspace_skill_create_title()
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
        editor::frame(
            "skill-editor",
            Frame {
                section: WorkspaceSection::Skills,
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

/// Import Markdown…: a `.md` file picked with an open panel (the E2E pass's
/// [`super::transfer::TransferHook`] file instead) fills a new skill, which
/// the user reviews and saves. The daemon reads the front-matter as the
/// phone does (`workspace.skillFromMarkdown`).
pub fn import_markdown(
    pane: &mut WorkspacePane,
    window: &mut Window,
    cx: &mut Context<WorkspacePane>,
) {
    let rpc = pane.rpc().clone();
    let toasts = pane.stores().toasts.clone();
    let hooked = cx
        .try_global::<super::transfer::TransferHook>()
        .and_then(|h| h.import_file.clone());
    let weak = cx.entity().downgrade();
    window
        .spawn(cx, async move |cx: &mut gpui_kit::AsyncWindowContext| {
            let path = match hooked {
                Some(path) => path,
                None => {
                    let Ok(asked) = cx.update(|_, cx| {
                        cx.prompt_for_paths(gpui_kit::PathPromptOptions {
                            files: true,
                            directories: false,
                            multiple: false,
                            prompt: None,
                        })
                    }) else {
                        return;
                    };
                    let Ok(Ok(Some(mut paths))) = asked.await else {
                        return;
                    };
                    let Some(path) = paths.pop() else {
                        return;
                    };
                    path
                }
            };
            let read = match std::fs::read_to_string(&path) {
                Ok(text) => {
                    rpc.call::<methods::WorkspaceSkillFromMarkdown>(
                        &conduit_protocol::WorkspaceMarkdown { text },
                    )
                    .await
                }
                Err(e) => Err(conduit_daemon::protocol::error(
                    conduit_daemon::protocol::codes::INVALID_PARAMS,
                    e.to_string(),
                )),
            };
            let _ = cx.update(|window, cx| {
                let l = cx.l10n().clone();
                let skill = match read {
                    Ok(skill) => skill,
                    Err(e) => {
                        log::warn!("workspace.skillFromMarkdown: {e}");
                        toasts.update(cx, |t, cx| {
                            t.show(
                                NoticeLevel::Error,
                                l.desktop_workspace_skill_import_markdown_failed(),
                                cx,
                            )
                        });
                        return;
                    }
                };
                let _ = weak.update(cx, |p, cx| {
                    p.after_discard_then(window, cx, move |p, window, cx| {
                        p.open_now(WorkspaceSection::Skills, None, window, cx);
                        if let Some(super::EditorView::Skill(editor)) =
                            p.editors.get(&WorkspaceSection::Skills).cloned()
                        {
                            editor.update(cx, |e, cx| {
                                e.set_field("content", &skill.content, window, cx);
                                if !skill.name.is_empty() {
                                    e.set_field("name", &skill.name, window, cx);
                                }
                                if !skill.id.is_empty() {
                                    e.set_field("id", &skill.id, window, cx);
                                }
                                if !skill.description.is_empty() {
                                    e.set_field("description", &skill.description, window, cx);
                                }
                            });
                        }
                        let l = cx.l10n().clone();
                        let toasts = p.stores().toasts.clone();
                        toasts.update(cx, |t, cx| {
                            t.show(
                                NoticeLevel::Info,
                                l.desktop_workspace_skill_import_markdown_loaded(),
                                cx,
                            )
                        });
                    });
                });
            });
        })
        .detach();
}

#[cfg(test)]
mod tests {
    use super::*;

    /// An id typed while the new item was being made gives way to the id it
    /// was made with: the next Save updates that item, never another.
    #[gpui_kit::test]
    fn a_made_skill_keeps_the_id_it_was_made_with(cx: &mut gpui_kit::TestAppContext) {
        use crate::views::workspace::editor::bench;
        let (daemon, stores, vcx) = crate::views::sheet::bench::bench(cx);
        daemon.returns::<methods::WorkspaceSave>(bench::detail(
            WorkspaceKind::Skills,
            serde_json::json!({"id": "trail_skill", "name": "Trail skill", "description": "", "content": "Pick a trail.", "active": true}),
        ));
        let editor = vcx.update(|window, cx| {
            cx.new(|cx| {
                SkillEditor::new(
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
        set("name", "Trail skill", vcx);
        set("id", "trail_skill", vcx);
        set("content", "Pick a trail.", vcx);
        let held = daemon.hold::<methods::WorkspaceSave>();
        vcx.update(|window, cx| editor.update(cx, |e, cx| e.save(window, cx)));
        vcx.run_until_parked();
        set("id", "other_skill", vcx);
        drop(held);
        vcx.run_until_parked();
        editor.read_with(vcx, |e, cx| {
            assert_eq!(e.id.as_deref(), Some("trail_skill"));
            assert_eq!(
                e.skill_id.read(cx).value().to_string(),
                "trail_skill",
                "the id field names another item than the one made"
            );
        });
    }

    /// A skill made elsewhere whose id is not command-shaped (a dot, a
    /// space) still saves: the command form is checked only when making one.
    #[gpui_kit::test]
    fn a_skill_made_elsewhere_saves_with_its_own_id(cx: &mut gpui_kit::TestAppContext) {
        use crate::views::workspace::editor::bench;
        let (daemon, stores, vcx) = crate::views::sheet::bench::bench(cx);
        daemon.returns::<methods::WorkspaceGet>(bench::detail(
            WorkspaceKind::Skills,
            serde_json::json!({"id": "trail.skill v2", "name": "Trail skill", "description": "", "content": "Pick a trail.", "active": true}),
        ));
        let editor = vcx.update(|window, cx| {
            cx.new(|cx| {
                SkillEditor::new(
                    stores.clone(),
                    WeakEntity::new_invalid(),
                    Some("trail.skill v2".into()),
                    bench::manage(),
                    window,
                    cx,
                )
            })
        });
        vcx.run_until_parked();
        vcx.update(|window, cx| {
            editor.update(cx, |e, cx| {
                e.set_field("description", "Day trails", window, cx)
            })
        });
        assert!(
            editor.read_with(vcx, |e, cx| e.valid(cx)),
            "an existing skill's id was checked as a new command"
        );
        // A new skill's id is still checked.
        let fresh = vcx.update(|window, cx| {
            cx.new(|cx| {
                SkillEditor::new(
                    stores.clone(),
                    WeakEntity::new_invalid(),
                    None,
                    bench::manage(),
                    window,
                    cx,
                )
            })
        });
        vcx.update(|window, cx| {
            fresh.update(cx, |e, cx| {
                e.set_field("name", "Trail skill", window, cx);
                e.set_field("id", "trail.skill v2", window, cx);
                e.set_field("content", "Pick a trail.", window, cx);
            })
        });
        assert!(!fresh.read_with(vcx, |e, cx| e.valid(cx)));
    }

    /// An id a Markdown import brought stays when the name is changed
    /// afterwards, as an id typed by hand does.
    #[gpui_kit::test]
    fn an_imported_id_stays_when_the_name_changes(cx: &mut gpui_kit::TestAppContext) {
        use crate::views::workspace::editor::bench;
        let (_daemon, stores, vcx) = crate::views::sheet::bench::bench(cx);
        let editor = vcx.update(|window, cx| {
            cx.new(|cx| {
                SkillEditor::new(
                    stores.clone(),
                    WeakEntity::new_invalid(),
                    None,
                    bench::manage(),
                    window,
                    cx,
                )
            })
        });
        // As Import Markdown fills the form.
        vcx.update(|window, cx| {
            editor.update(cx, |e, cx| {
                e.set_field("content", "Pick a trail.", window, cx);
                e.set_field("name", "Trail skill", window, cx);
                e.set_field("id", "ridge_walks", window, cx);
            })
        });
        vcx.update(|window, cx| {
            editor.update(cx, |e, cx| e.set_field("name", "Ridge walks", window, cx))
        });
        editor.read_with(vcx, |e, cx| {
            assert_eq!(
                e.skill_id.read(cx).value().to_string(),
                "ridge_walks",
                "the imported id followed the name"
            );
        });
    }

    /// Text typed while a save is out is kept, still to save.
    #[gpui_kit::test]
    fn text_typed_while_a_skill_saves_stays(cx: &mut gpui_kit::TestAppContext) {
        use crate::views::workspace::editor::bench;
        let (daemon, stores, vcx) = crate::views::sheet::bench::bench(cx);
        let item = |description: &str| {
            bench::detail(
                WorkspaceKind::Skills,
                serde_json::json!({"id": "trail_skill", "name": "Trail skill", "description": description, "content": "Pick a trail.", "active": true}),
            )
        };
        daemon.returns::<methods::WorkspaceGet>(item("Picks trails"));
        daemon.returns::<methods::WorkspaceSave>(item("Picks day trails"));
        let editor = vcx.update(|window, cx| {
            cx.new(|cx| {
                SkillEditor::new(
                    stores.clone(),
                    WeakEntity::new_invalid(),
                    Some("trail_skill".into()),
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
        set("Picks day trails", vcx);
        let held = daemon.hold::<methods::WorkspaceSave>();
        vcx.update(|window, cx| editor.update(cx, |e, cx| e.save(window, cx)));
        vcx.run_until_parked();
        set("Picks day trails nearby", vcx);
        drop(held);
        vcx.run_until_parked();
        editor.read_with(vcx, |e, cx| {
            assert_eq!(
                e.description.read(cx).value().to_string(),
                "Picks day trails nearby",
                "the save's answer replaced what was typed since"
            );
            assert!(e.is_dirty(cx), "the later words count as saved");
        });
        assert_eq!(daemon.calls::<methods::WorkspaceSave>().len(), 1);
    }
}
