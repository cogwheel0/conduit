//! Settings › Personalization, the phone's page: the model new chats start
//! with (or the server's), OpenRouter's image model, and for an Open WebUI
//! account "Your system prompt" and Memory (on or off, and the memories
//! themselves: add, edit, delete, clear all; type and path with Advanced).
//! With a LibreChat account in charge, its memories instead
//! ([`super::librechat_memories`]).

use std::rc::Rc;

use conduit_components::ActiveConduitTheme as _;
use conduit_components::views::kit::{Button, Segment, Segmented, Switch, setting_row};
use conduit_components::views::settings::settings_section;
use conduit_protocol::{
    AccountSettingsDto, AccountSettingsPatch, AppSettingsPatch, MemoryDto, MemoryEdit, MemoryList,
    MemoryRef, MemoryToggle, ModelList, NoParams, methods,
};
use gpui_kit::component::input::{InputState, Textarea, TextareaState};
use gpui_kit::prelude::*;
use gpui_kit::{
    AnyElement, App, AsyncWindowContext, Context, ElementId, Entity, SharedString, WeakEntity,
    Window, div, px,
};

use crate::l10n::{ActiveL10n as _, L10n};
use crate::shell::sheet::{SheetSpec, present_sheet};
use crate::stores::Stores;
use crate::views::forms;

use super::controls::{self, Choice, popup};

/// A memory being written: a new one (`id` None) or an edit.
pub struct MemoryEditor {
    pub id: Option<String>,
    /// `user` or `context`.
    pub kind: String,
    pub saving: bool,
    pub failed: bool,
}

pub struct PersonalizationPane {
    stores: Stores,
    pub models: Option<ModelList>,
    pub account: Option<AccountSettingsDto>,
    pub memories: Option<MemoryList>,
    pub system_prompt: Entity<TextareaState>,
    pub image_model: Entity<InputState>,
    /// The image model field holds the loaded settings' value.
    image_filled: bool,
    pub memory_input: Entity<TextareaState>,
    pub memory_path: Entity<InputState>,
    pub editor: Option<MemoryEditor>,
    /// What the editor's last Save sent: its words, and with Advanced on
    /// its type and path.
    editor_saved: Option<MemoryEdit>,
    /// The memory ids listed when a new memory's Save started.
    editor_known: Option<std::collections::HashSet<String>>,
    pub busy: bool,
    /// Saved, or failed, under the system prompt.
    pub prompt_note: Option<bool>,
    pub memory_failed: bool,
    /// A LibreChat account's memories, once shown.
    pub librechat: Option<Entity<super::librechat_memories::LibreChatMemoriesView>>,
}

impl PersonalizationPane {
    pub fn new(stores: Stores, window: &mut Window, cx: &mut Context<Self>) -> Self {
        let l10n = cx.l10n().clone();
        let system_prompt = cx.new(|cx| {
            TextareaState::new(window, cx)
                .auto_grow(3, 12)
                .placeholder(l10n.enter_system_prompt())
        });
        let memory_input = cx.new(|cx| {
            TextareaState::new(window, cx)
                .auto_grow(2, 8)
                .placeholder(l10n.memory_hint())
        });
        let image_model = forms::input("openai/gpt-5-image", false, window, cx);
        let memory_path = forms::input(l10n.memory_path_hint(), false, window, cx);
        // Opened before settings.get answered: the saved image model goes in
        // the field once it is in (not over what was typed since).
        cx.observe_in(
            &stores.app_settings,
            window,
            |this: &mut Self, store, window, cx| {
                if !this.image_filled && store.read(cx).loaded {
                    this.image_filled = true;
                    if this.image_model.read(cx).value().is_empty() {
                        let image = store
                            .read(cx)
                            .settings()
                            .open_router_image_generation_model
                            .clone()
                            .unwrap_or_default();
                        this.image_model
                            .update(cx, |s, cx| s.set_value(image, window, cx));
                    }
                }
                cx.notify()
            },
        )
        .detach();
        let mut this = Self {
            stores,
            models: None,
            account: None,
            memories: None,
            system_prompt,
            image_model,
            memory_input,
            memory_path,
            editor: None,
            editor_saved: None,
            editor_known: None,
            image_filled: false,
            busy: false,
            prompt_note: None,
            memory_failed: false,
            librechat: None,
        };
        this.refresh(window, cx);
        this
    }

    fn rpc(&self, cx: &App) -> crate::stores::rpc::Rpc {
        self.stores.connection.read(cx).rpc()
    }

    pub fn refresh(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if let Some(view) = self.librechat.clone() {
            view.update(cx, |v, cx| v.refresh(window, cx));
        }
        let rpc = self.rpc(cx);
        let models = rpc.call::<methods::ModelsList>(&conduit_protocol::ModelListQuery::default());
        let account = rpc.call::<methods::SettingsGetAccount>(&NoParams);
        let memories = rpc.call::<methods::MemoriesList>(&NoParams);
        let store = self.stores.app_settings.read(cx);
        self.image_filled = store.loaded;
        let image = store
            .settings()
            .open_router_image_generation_model
            .clone()
            .unwrap_or_default();
        self.image_model
            .update(cx, |s, cx| s.set_value(image, window, cx));
        cx.spawn_in(
            window,
            async move |this: WeakEntity<Self>, cx: &mut AsyncWindowContext| {
                let models = models.await;
                let account = account.await;
                let memories = memories.await;
                let _ = this.update_in(cx, |s, window, cx| {
                    match models {
                        Ok(m) => s.models = Some(m),
                        Err(e) => log::warn!("models.list: {e}"),
                    }
                    match account {
                        Ok(a) => {
                            let prompt = a.system_prompt.clone().unwrap_or_default();
                            s.system_prompt
                                .update(cx, |i, cx| i.set_value(prompt, window, cx));
                            s.account = Some(a);
                        }
                        Err(e) => log::warn!("settings.getAccount: {e}"),
                    }
                    match memories {
                        Ok(m) => s.memories = Some(m),
                        Err(e) => log::warn!("memories.list: {e}"),
                    }
                    cx.notify();
                });
            },
        )
        .detach();
    }

    /// The Default Model pop-up's choice: `""` is the server's.
    pub fn choose_default_model(&mut self, value: &str, cx: &mut Context<Self>) {
        let patch = if value.is_empty() {
            AppSettingsPatch {
                clear: vec!["defaultModel".into()],
                ..Default::default()
            }
        } else {
            AppSettingsPatch {
                default_model: Some(value.to_string()),
                ..Default::default()
            }
        };
        self.stores
            .app_settings
            .update(cx, |s, cx| s.set(patch, cx));
    }

    pub fn save_image_model(&mut self, cx: &mut Context<Self>) {
        let model = forms::text(&self.image_model, cx);
        // Before the settings are in, an empty field is no choice: nothing
        // is cleared.
        if model.is_empty() && !self.stores.app_settings.read(cx).loaded {
            return;
        }
        let patch = if model.is_empty() {
            AppSettingsPatch {
                clear: vec!["openRouterImageGenerationModel".into()],
                ..Default::default()
            }
        } else {
            AppSettingsPatch {
                open_router_image_generation_model: Some(model),
                ..Default::default()
            }
        };
        self.stores
            .app_settings
            .update(cx, |s, cx| s.set(patch, cx));
    }

    pub fn save_system_prompt(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let prompt = self.system_prompt.read(cx).value().to_string();
        let call = self
            .rpc(cx)
            .call::<methods::SettingsSetAccount>(&AccountSettingsPatch {
                system_prompt: Some(prompt),
            });
        self.busy = true;
        self.prompt_note = None;
        cx.notify();
        cx.spawn_in(
            window,
            async move |this: WeakEntity<Self>, cx: &mut AsyncWindowContext| {
                let result = call.await;
                let _ = this.update(cx, |s, cx| {
                    s.busy = false;
                    match result {
                        Ok(a) => {
                            s.account = Some(a);
                            s.prompt_note = Some(true);
                        }
                        Err(e) => {
                            log::warn!("settings.setAccount: {e}");
                            s.prompt_note = Some(false);
                        }
                    }
                    cx.notify();
                });
            },
        )
        .detach();
    }

    /// Runs a `memories.*` call and shows the list it answers.
    fn memories_call(
        &mut self,
        call: impl std::future::Future<Output = Result<MemoryList, conduit_daemon::RpcError>>
        + Send
        + 'static,
        closes_editor: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.busy = true;
        self.memory_failed = false;
        // Only the editor's own Save holds it; a switch or a delete
        // meanwhile leaves a pending save as it is.
        if closes_editor && let Some(e) = self.editor.as_mut() {
            e.saving = true;
            e.failed = false;
        }
        cx.notify();
        cx.spawn_in(
            window,
            async move |this: WeakEntity<Self>, cx: &mut AsyncWindowContext| {
                let result = call.await;
                let _ = this.update(cx, |s, cx| {
                    s.busy = false;
                    match result {
                        Ok(list) => {
                            // The memory this add made (the one id the list
                            // did not have before it): what a kept editor
                            // updates from now on, rather than adding another.
                            // Not exactly one new id: none, so nothing else
                            // is ever overwritten. Only the editor's own save
                            // takes it: a switch or delete answered meanwhile
                            // leaves it for the add.
                            let known = if closes_editor {
                                s.editor_known.take()
                            } else {
                                None
                            };
                            let made = known.and_then(|known| {
                                let mut new = list.items.iter().filter(|m| !known.contains(&m.id));
                                match (new.next(), new.next()) {
                                    (Some(m), None) => Some(m.id.clone()),
                                    _ => None,
                                }
                            });
                            s.memories = Some(list);
                            if closes_editor {
                                // Typed on (or another type or path chosen)
                                // while the save was out: the editor stays
                                // with it, to be saved again.
                                let now = s.editor_edit(cx);
                                if now.is_some() && now == s.editor_saved {
                                    s.editor = None;
                                } else if let Some(editor) = s.editor.as_mut() {
                                    editor.saving = false;
                                    if editor.id.is_none() {
                                        editor.id = made;
                                    }
                                }
                            }
                        }
                        Err(e) => {
                            log::warn!("memories: {e}");
                            s.memory_failed = true;
                            if closes_editor && let Some(editor) = s.editor.as_mut() {
                                editor.saving = false;
                                editor.failed = true;
                            }
                        }
                    }
                    cx.notify();
                });
            },
        )
        .detach();
    }

    pub fn set_memory_enabled(&mut self, on: bool, window: &mut Window, cx: &mut Context<Self>) {
        let call = self
            .rpc(cx)
            .call::<methods::MemoriesSetEnabled>(&MemoryToggle { enabled: on });
        self.memories_call(call, false, window, cx);
    }

    /// Add Memory… (no memory) or Edit… on one.
    pub fn open_editor(
        &mut self,
        memory: Option<&MemoryDto>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.editor = Some(MemoryEditor {
            id: memory.map(|m| m.id.clone()),
            kind: memory
                .and_then(|m| m.r#type.clone())
                .unwrap_or_else(|| "user".into()),
            saving: false,
            failed: false,
        });
        let content = memory.map(|m| m.content.clone()).unwrap_or_default();
        let path = memory.and_then(|m| m.path.clone()).unwrap_or_default();
        self.memory_input
            .update(cx, |s, cx| s.set_value(content, window, cx));
        self.memory_path
            .update(cx, |s, cx| s.set_value(path, window, cx));
        window.focus(
            &gpui_kit::Focusable::focus_handle(self.memory_input.read(cx), cx),
            cx,
        );
        cx.notify();
    }

    /// What the editor holds now, as Save would send it (None: no editor).
    fn editor_edit(&self, cx: &App) -> Option<MemoryEdit> {
        let editor = self.editor.as_ref()?;
        let advanced = self
            .stores
            .app_settings
            .read(cx)
            .settings()
            .advanced_features_enabled;
        Some(MemoryEdit {
            id: editor.id.clone(),
            content: self.memory_input.read(cx).value().trim().to_string(),
            r#type: advanced.then(|| editor.kind.clone()),
            path: advanced.then(|| forms::text(&self.memory_path, cx)),
        })
    }

    pub fn save_memory(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(edit) = self.editor_edit(cx) else {
            return;
        };
        if edit.content.is_empty() {
            return;
        }
        self.editor_saved = Some(edit.clone());
        self.editor_known = edit.id.is_none().then(|| {
            self.memories
                .iter()
                .flat_map(|l| l.items.iter().map(|m| m.id.clone()))
                .collect()
        });
        let rpc = self.rpc(cx);
        if edit.id.is_some() {
            let call = rpc.call::<methods::MemoriesUpdate>(&edit);
            self.memories_call(call, true, window, cx);
        } else {
            let call = rpc.call::<methods::MemoriesAdd>(&edit);
            self.memories_call(call, true, window, cx);
        }
    }

    /// Delete…: asks with a sheet, as the phone does.
    pub fn delete_memory(&mut self, id: String, window: &mut Window, cx: &mut Context<Self>) {
        let l10n = cx.l10n().clone();
        let spec = SheetSpec::new(
            l10n.delete_memory(),
            l10n.delete_memory_confirm(),
            l10n.delete(),
            l10n.cancel(),
        )
        .destructive();
        let ask = present_sheet(window, spec, cx);
        cx.spawn_in(
            window,
            async move |this: WeakEntity<Self>, cx: &mut AsyncWindowContext| {
                if !ask.await {
                    return;
                }
                let _ = this.update_in(cx, |s, window, cx| {
                    let call = s.rpc(cx).call::<methods::MemoriesDelete>(&MemoryRef { id });
                    s.memories_call(call, false, window, cx);
                });
            },
        )
        .detach();
    }

    pub fn clear_memories(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let l10n = cx.l10n().clone();
        let spec = SheetSpec::new(
            l10n.clear_all_memories(),
            l10n.clear_all_memories_description(),
            l10n.desktop_clear_all(),
            l10n.cancel(),
        )
        .destructive();
        let ask = present_sheet(window, spec, cx);
        cx.spawn_in(
            window,
            async move |this: WeakEntity<Self>, cx: &mut AsyncWindowContext| {
                if !ask.await {
                    return;
                }
                let _ = this.update_in(cx, |s, window, cx| {
                    let call = s.rpc(cx).call::<methods::MemoriesClear>(&NoParams);
                    s.memories_call(call, false, window, cx);
                });
            },
        )
        .detach();
    }

    pub fn choose_memory_kind(&mut self, kind: &str, cx: &mut Context<Self>) {
        if let Some(e) = self.editor.as_mut() {
            e.kind = kind.to_string();
            cx.notify();
        }
    }

    fn model_groups(
        &self,
        l10n: &L10n,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Vec<AnyElement> {
        let s = self.stores.app_settings.read(cx).settings().clone();
        let mut choices = vec![Choice::new("", l10n.auto_select())];
        let models = self.models.clone().unwrap_or_default();
        for (i, m) in models.models.iter().enumerate() {
            let label = match &m.connection {
                Some(c) => format!("{} — {c}", m.name),
                None => m.name.clone(),
            };
            let choice = Choice::new(m.id.clone(), label);
            choices.push(if i == 0 { choice.separated() } else { choice });
        }
        let selected = s.default_model.clone().unwrap_or_default();
        let default = popup(
            "default-model",
            &l10n.default_model(),
            choices,
            &selected,
            self.models.is_none(),
            window,
            cx,
        );
        let mut out = vec![
            settings_section(
                SharedString::default(),
                s.default_model
                    .is_none()
                    .then(|| l10n.auto_select_description().into()),
                vec![setting_row(l10n.default_model(), None, default, cx).into_any_element()],
                cx,
            )
            .into_any_element(),
        ];
        // OpenRouter's image model, when one of its models makes images.
        let openrouter = models.models.iter().any(|m| {
            m.capabilities.iter().any(|c| c == "openrouter")
                && m.capabilities.iter().any(|c| c == "image_generation")
        });
        if openrouter {
            let view = cx.entity().downgrade();
            out.push(
                div()
                    .flex()
                    .flex_col()
                    .gap(px(8.))
                    .child(forms::form_group(
                        vec![
                            forms::field(
                                l10n.default_image_generation_model(),
                                &self.image_model,
                                None,
                                None,
                                window,
                                cx,
                            )
                            .into_any_element(),
                        ],
                        cx,
                    ))
                    .child(forms::group_footer(
                        l10n.default_image_generation_model_description(),
                        cx,
                    ))
                    .child(controls::buttons(vec![
                        Button::new("image-model-save", l10n.save())
                            .on_click(Rc::new(move |_, _, cx| {
                                let _ = view.update(cx, |v, cx| v.save_image_model(cx));
                            }))
                            .into_any_element(),
                    ]))
                    .into_any_element(),
            );
        }
        out
    }

    fn prompt_group(&self, l10n: &L10n, cx: &mut Context<Self>) -> AnyElement {
        let view = cx.entity().downgrade();
        let note = self.prompt_note.map(|ok| {
            forms::form_note(
                if ok {
                    l10n.desktop_saved()
                } else {
                    l10n.desktop_action_failed()
                },
                ok,
                cx,
            )
        });
        div()
            .flex()
            .flex_col()
            .gap(px(8.))
            .child(settings_section(
                l10n.your_system_prompt(),
                Some(l10n.your_system_prompt_description().into()),
                vec![
                    div()
                        .p(px(12.))
                        .child(Textarea::new(&self.system_prompt))
                        .into_any_element(),
                ],
                cx,
            ))
            .children(note)
            .child(controls::buttons(vec![
                Button::new("system-prompt-save", l10n.save())
                    .disabled(self.busy)
                    .on_click(Rc::new(move |_, window, cx| {
                        let _ = view.update(cx, |v, cx| v.save_system_prompt(window, cx));
                    }))
                    .into_any_element(),
            ]))
            .into_any_element()
    }

    fn memory_groups(
        &self,
        list: &MemoryList,
        l10n: &L10n,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Vec<AnyElement> {
        let t = cx.conduit().clone();
        let view = cx.entity().downgrade();
        let enabled = list.enabled;
        let toggle =
            Switch::new("memory-enabled", l10n.memory_title(), enabled).on_click(Rc::new({
                let view = view.clone();
                move |_, window, cx| {
                    let _ = view.update(cx, |v, cx| v.set_memory_enabled(!enabled, window, cx));
                }
            }));
        let mut out = vec![
            settings_section(
                SharedString::default(),
                Some(
                    if enabled {
                        l10n.memory_enabled_description()
                    } else {
                        l10n.memory_disabled_description()
                    }
                    .into(),
                ),
                vec![setting_row(l10n.memory_title(), None, toggle, cx).into_any_element()],
                cx,
            )
            .into_any_element(),
        ];
        let mut rows = vec![];
        for (i, m) in list.items.iter().enumerate() {
            let when =
                crate::views::dates::stamp(m.updated_at * 1000, &chrono::Local::now(), l10n).0;
            let mut subtitle = l10n.memory_updated_at(&when);
            match m.r#type.as_deref() {
                Some("user") => subtitle = format!("{subtitle} · {}", l10n.memory_type_user()),
                Some("context") => {
                    subtitle = format!("{subtitle} · {}", l10n.memory_type_context())
                }
                _ => {}
            }
            if let Some(path) = m.path.as_deref().filter(|p| !p.is_empty()) {
                subtitle = format!("{subtitle} · {path}");
            }
            let memory = m.clone();
            let edit = Button::new(
                ElementId::NamedInteger("memory-edit".into(), i as u64),
                l10n.desktop_edit_ellipsis(),
            )
            .disabled(self.busy)
            .on_click(Rc::new({
                let view = view.clone();
                move |_, window, cx| {
                    let memory = memory.clone();
                    let _ = view.update(cx, |v, cx| v.open_editor(Some(&memory), window, cx));
                }
            }));
            let id = m.id.clone();
            let delete = Button::new(
                ElementId::NamedInteger("memory-delete".into(), i as u64),
                l10n.desktop_delete_ellipsis(),
            )
            .ghost()
            .disabled(self.busy)
            .on_click(Rc::new({
                let view = view.clone();
                move |_, window, cx| {
                    let id = id.clone();
                    let _ = view.update(cx, |v, cx| v.delete_memory(id, window, cx));
                }
            }));
            rows.push(
                setting_row(
                    m.content.clone(),
                    Some(subtitle.into()),
                    div().flex().gap(px(6.)).child(edit).child(delete),
                    cx,
                )
                .into_any_element(),
            );
        }
        if rows.is_empty() {
            rows.push(
                div()
                    .px(px(12.))
                    .py(px(12.))
                    .text_size(px(t.metrics.control))
                    .text_color(t.roles.text_subtle)
                    .child(SharedString::from(l10n.no_memories_saved()))
                    .into_any_element(),
            );
        }
        let footer = if self.memory_failed {
            l10n.desktop_action_failed()
        } else {
            l10n.manage_memories_description()
        };
        out.push(
            div()
                .flex()
                .flex_col()
                .gap(px(10.))
                .child(settings_section(
                    l10n.manage_memories(),
                    Some(footer.into()),
                    rows,
                    cx,
                ))
                .child(controls::buttons(vec![
                    Button::new("memory-clear", l10n.desktop_clear_all_memories_ellipsis())
                        .danger()
                        .disabled(self.busy || list.items.is_empty())
                        .on_click(Rc::new({
                            let view = view.clone();
                            move |_, window, cx| {
                                let _ = view.update(cx, |v, cx| v.clear_memories(window, cx));
                            }
                        }))
                        .into_any_element(),
                    Button::new("memory-add", l10n.desktop_add_memory_ellipsis())
                        .disabled(self.busy || self.editor.as_ref().is_some_and(|e| e.id.is_none()))
                        .on_click(Rc::new({
                            let view = view.clone();
                            move |_, window, cx| {
                                let _ = view.update(cx, |v, cx| v.open_editor(None, window, cx));
                            }
                        }))
                        .into_any_element(),
                ]))
                .into_any_element(),
        );
        if let Some(editor) = &self.editor {
            out.push(self.editor_group(editor, l10n, window, cx));
        }
        out
    }

    fn editor_group(
        &self,
        editor: &MemoryEditor,
        l10n: &L10n,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let advanced = self
            .stores
            .app_settings
            .read(cx)
            .settings()
            .advanced_features_enabled;
        let view = cx.entity().downgrade();
        let mut rows = vec![
            div()
                .p(px(12.))
                .child(Textarea::new(&self.memory_input))
                .into_any_element(),
        ];
        if advanced {
            let kinds = ["user", "context"];
            let kind = Segmented::new(
                "memory-type",
                l10n.memory_type_label(),
                vec![
                    Segment::new(l10n.memory_type_user()),
                    Segment::new(l10n.memory_type_context()),
                ],
                kinds.iter().position(|k| *k == editor.kind).unwrap_or(0),
            )
            .on_select(Rc::new({
                let view = view.clone();
                move |i, _, cx| {
                    let _ = view.update(cx, |v, cx| v.choose_memory_kind(kinds[i], cx));
                }
            }));
            let help = if editor.kind == "context" {
                l10n.personalization_memory_type_context_description()
            } else {
                l10n.personalization_memory_type_user_description()
            };
            rows.push(
                setting_row(l10n.memory_type_label(), Some(help.into()), kind, cx)
                    .into_any_element(),
            );
            rows.push(
                forms::field(
                    l10n.memory_path_label(),
                    &self.memory_path,
                    None,
                    None,
                    window,
                    cx,
                )
                .into_any_element(),
            );
        }
        let footer = if editor.failed {
            l10n.desktop_action_failed()
        } else {
            l10n.memory_editor_description()
        };
        let can_save = !self.memory_input.read(cx).value().trim().is_empty() && !editor.saving;
        div()
            .flex()
            .flex_col()
            .gap(px(10.))
            .child(settings_section(
                if editor.id.is_some() {
                    l10n.edit_memory()
                } else {
                    l10n.add_memory()
                },
                Some(footer.into()),
                rows,
                cx,
            ))
            .child(controls::buttons(vec![
                Button::new("memory-cancel", l10n.cancel())
                    .on_click(Rc::new({
                        let view = view.clone();
                        move |_, _, cx| {
                            let _ = view.update(cx, |v, cx| {
                                v.editor = None;
                                cx.notify();
                            });
                        }
                    }))
                    .into_any_element(),
                Button::new("memory-save", l10n.save())
                    .primary()
                    .disabled(!can_save)
                    .on_click(Rc::new(move |_, window, cx| {
                        let _ = view.update(cx, |v, cx| v.save_memory(window, cx));
                    }))
                    .into_any_element(),
            ]))
            .into_any_element()
    }
}

impl Render for PersonalizationPane {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let l10n = cx.l10n().clone();
        let mut sections = self.model_groups(&l10n, window, cx);
        if self.account.as_ref().is_some_and(|a| a.available) {
            sections.push(self.prompt_group(&l10n, cx));
        }
        if let Some(list) = self.memories.clone().filter(|m| m.available) {
            sections.extend(self.memory_groups(&list, &l10n, window, cx));
        }
        if super::librechat_memories::shown(&self.stores, cx) {
            let view = match self.librechat.clone() {
                Some(view) => view,
                None => {
                    let rpc = self.rpc(cx);
                    let view = cx.new(|cx| {
                        super::librechat_memories::LibreChatMemoriesView::new(rpc, window, cx)
                    });
                    self.librechat = Some(view.clone());
                    view
                }
            };
            sections.push(view.into_any_element());
        } else {
            self.librechat = None;
        }
        div().flex().flex_col().gap(px(22.)).children(sections)
    }
}

#[cfg(test)]
mod tests {
    use gpui_kit::TestAppContext;

    use super::*;
    use crate::stores::rpc::fake::FakeDaemon;

    #[gpui_kit::test]
    fn the_image_model_shows_once_settings_load_and_is_never_cleared_before(
        cx: &mut TestAppContext,
    ) {
        let daemon = FakeDaemon::new();
        let scratch = std::env::temp_dir().join(format!("conduit-image-{}", std::process::id()));
        let stores = cx.update(|cx| {
            crate::views::test_globals(cx);
            Stores::for_test(daemon.rpc(), &scratch, cx)
        });
        let s = stores.clone();
        let (view, vcx) =
            cx.add_window_view(move |window, cx| PersonalizationPane::new(s, window, cx));
        vcx.run_until_parked();
        // Saved before the settings are in: nothing is cleared.
        view.update(vcx, |p, cx| p.save_image_model(cx));
        vcx.run_until_parked();
        assert!(
            daemon.calls::<methods::SettingsSet>().is_empty(),
            "the saved model was cleared"
        );
        let mut loaded = stores
            .app_settings
            .read_with(vcx, |s, _| s.settings().clone());
        loaded.open_router_image_generation_model = Some("vendor/image-model".into());
        stores.app_settings.update(vcx, |s, cx| s.adopt(loaded, cx));
        vcx.run_until_parked();
        view.read_with(vcx, |p, cx| {
            assert_eq!(p.image_model.read(cx).value(), "vendor/image-model");
        });
    }

    #[gpui_kit::test]
    fn the_memory_switch_never_reopens_a_pending_save(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        let list = serde_json::json!({"available": true, "enabled": true, "memories": []});
        for_methods(&daemon, list);
        let held = daemon.hold::<methods::MemoriesAdd>();
        let scratch = std::env::temp_dir().join(format!("conduit-memory-{}", std::process::id()));
        let stores = cx.update(|cx| {
            crate::views::test_globals(cx);
            Stores::for_test(daemon.rpc(), &scratch, cx)
        });
        let (view, vcx) =
            cx.add_window_view(move |window, cx| PersonalizationPane::new(stores, window, cx));
        vcx.run_until_parked();
        view.update_in(vcx, |p, window, cx| {
            p.open_editor(None, window, cx);
            p.memory_input
                .update(cx, |i, cx| i.set_value("Prefers tea", window, cx));
            p.save_memory(window, cx);
            p.set_memory_enabled(false, window, cx);
        });
        vcx.run_until_parked();
        view.read_with(vcx, |p, _| {
            assert!(
                p.editor.as_ref().is_some_and(|e| e.saving),
                "Save is open again"
            );
        });
        held.release();
        vcx.run_until_parked();
        view.read_with(vcx, |p, _| assert!(p.editor.is_none()));
        assert_eq!(daemon.calls::<methods::MemoriesAdd>().len(), 1);
    }

    #[gpui_kit::test]
    fn a_memory_typed_on_while_its_save_is_out_is_kept(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        let list = serde_json::json!({"available": true, "enabled": true, "memories": []});
        for_methods(&daemon, list);
        let held = daemon.hold::<methods::MemoriesAdd>();
        let scratch =
            std::env::temp_dir().join(format!("conduit-memory-typed-{}", std::process::id()));
        let stores = cx.update(|cx| {
            crate::views::test_globals(cx);
            Stores::for_test(daemon.rpc(), &scratch, cx)
        });
        let (view, vcx) =
            cx.add_window_view(move |window, cx| PersonalizationPane::new(stores, window, cx));
        vcx.run_until_parked();
        view.update_in(vcx, |p, window, cx| {
            p.open_editor(None, window, cx);
            p.memory_input
                .update(cx, |i, cx| i.set_value("Prefers tea", window, cx));
            p.save_memory(window, cx);
            p.memory_input
                .update(cx, |i, cx| i.set_value("Prefers green tea", window, cx));
        });
        vcx.run_until_parked();
        held.release();
        vcx.run_until_parked();
        view.read_with(vcx, |p, cx| {
            assert!(p.editor.is_some(), "the editor closed over what was typed");
            assert_eq!(p.memory_input.read(cx).value(), "Prefers green tea");
        });
    }

    #[gpui_kit::test]
    fn a_memory_type_changed_while_its_save_is_out_is_kept(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        let list = serde_json::json!({"available": true, "enabled": true, "memories": []});
        for_methods(&daemon, list);
        let held = daemon.hold::<methods::MemoriesAdd>();
        let scratch =
            std::env::temp_dir().join(format!("conduit-memory-kind-{}", std::process::id()));
        let stores = cx.update(|cx| {
            crate::views::test_globals(cx);
            Stores::for_test(daemon.rpc(), &scratch, cx)
        });
        let mut advanced = stores
            .app_settings
            .read_with(cx, |s, _| s.settings().clone());
        advanced.advanced_features_enabled = true;
        stores
            .app_settings
            .update(cx, |s, cx| s.adopt(advanced, cx));
        let (view, vcx) =
            cx.add_window_view(move |window, cx| PersonalizationPane::new(stores, window, cx));
        vcx.run_until_parked();
        view.update_in(vcx, |p, window, cx| {
            p.open_editor(None, window, cx);
            p.memory_input
                .update(cx, |i, cx| i.set_value("Prefers tea", window, cx));
            p.save_memory(window, cx);
            // Same words, another type, while the save is out.
            p.choose_memory_kind("context", cx);
        });
        vcx.run_until_parked();
        held.release();
        vcx.run_until_parked();
        view.read_with(vcx, |p, _| {
            assert!(
                p.editor.as_ref().is_some_and(|e| e.kind == "context"),
                "the editor closed over the type chosen while saving"
            );
        });
    }

    fn for_methods(daemon: &FakeDaemon, list: serde_json::Value) {
        let a = list.clone();
        daemon.on::<methods::MemoriesList>(move |_| Ok(a.clone()));
        let a = list.clone();
        daemon.on::<methods::MemoriesAdd>(move |_| Ok(a.clone()));
        daemon.on::<methods::MemoriesSetEnabled>(move |_| Ok(list.clone()));
    }

    #[gpui_kit::test]
    fn a_new_memory_kept_open_after_its_save_is_updated_not_added_again(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        let empty = serde_json::json!({"available": true, "enabled": true, "items": []});
        let e = empty.clone();
        daemon.on::<methods::MemoriesList>(move |_| Ok(e.clone()));
        daemon.on::<methods::MemoriesAdd>(|p| {
            Ok(
                serde_json::json!({"available": true, "enabled": true, "items": [
                    {"id": "m1", "content": p["content"], "updatedAt": 1}
                ]}),
            )
        });
        daemon.on::<methods::MemoriesUpdate>(|p| {
            Ok(
                serde_json::json!({"available": true, "enabled": true, "items": [
                    {"id": p["id"], "content": p["content"], "updatedAt": 2}
                ]}),
            )
        });
        let held = daemon.hold::<methods::MemoriesAdd>();
        let scratch =
            std::env::temp_dir().join(format!("conduit-memory-id-{}", std::process::id()));
        let stores = cx.update(|cx| {
            crate::views::test_globals(cx);
            Stores::for_test(daemon.rpc(), &scratch, cx)
        });
        let (view, vcx) =
            cx.add_window_view(move |window, cx| PersonalizationPane::new(stores, window, cx));
        vcx.run_until_parked();
        view.update_in(vcx, |p, window, cx| {
            p.open_editor(None, window, cx);
            p.memory_input
                .update(cx, |i, cx| i.set_value("Prefers tea", window, cx));
            p.save_memory(window, cx);
            p.memory_input
                .update(cx, |i, cx| i.set_value("Prefers green tea", window, cx));
        });
        vcx.run_until_parked();
        held.release();
        vcx.run_until_parked();
        view.update_in(vcx, |p, window, cx| p.save_memory(window, cx));
        vcx.run_until_parked();
        assert_eq!(
            daemon.calls::<methods::MemoriesAdd>().len(),
            1,
            "a second memory was added"
        );
        let updates = daemon.calls::<methods::MemoriesUpdate>();
        assert_eq!(updates.len(), 1);
        assert_eq!(updates[0]["id"], "m1");
        assert_eq!(updates[0]["content"], "Prefers green tea");
        view.read_with(vcx, |p, _| assert!(p.editor.is_none()));
    }

    #[gpui_kit::test]
    fn a_memory_switch_during_an_add_leaves_the_kept_editor_its_memory(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        let empty = serde_json::json!({"available": true, "enabled": true, "items": []});
        let e = empty.clone();
        daemon.on::<methods::MemoriesList>(move |_| Ok(e.clone()));
        daemon.on::<methods::MemoriesSetEnabled>(move |_| Ok(empty.clone()));
        daemon.on::<methods::MemoriesAdd>(|p| {
            Ok(
                serde_json::json!({"available": true, "enabled": true, "items": [
                    {"id": "m1", "content": p["content"], "updatedAt": 1}
                ]}),
            )
        });
        daemon.on::<methods::MemoriesUpdate>(|p| {
            Ok(
                serde_json::json!({"available": true, "enabled": true, "items": [
                    {"id": p["id"], "content": p["content"], "updatedAt": 2}
                ]}),
            )
        });
        let held = daemon.hold::<methods::MemoriesAdd>();
        let scratch =
            std::env::temp_dir().join(format!("conduit-memory-switch-{}", std::process::id()));
        let stores = cx.update(|cx| {
            crate::views::test_globals(cx);
            Stores::for_test(daemon.rpc(), &scratch, cx)
        });
        let (view, vcx) =
            cx.add_window_view(move |window, cx| PersonalizationPane::new(stores, window, cx));
        vcx.run_until_parked();
        view.update_in(vcx, |p, window, cx| {
            p.open_editor(None, window, cx);
            p.memory_input
                .update(cx, |i, cx| i.set_value("Prefers tea", window, cx));
            p.save_memory(window, cx);
            p.memory_input
                .update(cx, |i, cx| i.set_value("Prefers green tea", window, cx));
            // Memory switched while the add is out: its answer comes first.
            p.set_memory_enabled(true, window, cx);
        });
        vcx.run_until_parked();
        held.release();
        vcx.run_until_parked();
        view.update_in(vcx, |p, window, cx| p.save_memory(window, cx));
        vcx.run_until_parked();
        assert_eq!(
            daemon.calls::<methods::MemoriesAdd>().len(),
            1,
            "the kept editor added its memory again"
        );
        let updates = daemon.calls::<methods::MemoriesUpdate>();
        assert_eq!(updates.len(), 1);
        assert_eq!(updates[0]["id"], "m1");
    }

    #[gpui_kit::test]
    fn a_kept_new_memory_updates_itself_not_an_older_one_with_the_same_text(
        cx: &mut TestAppContext,
    ) {
        let daemon = FakeDaemon::new();
        let one = serde_json::json!({"available": true, "enabled": true, "items": [
            {"id": "m0", "content": "x", "updatedAt": 1}
        ]});
        let o = one.clone();
        daemon.on::<methods::MemoriesList>(move |_| Ok(o.clone()));
        // Newest first, as the daemon sorts them: the new "x" before the old.
        daemon.on::<methods::MemoriesAdd>(|_| {
            Ok(
                serde_json::json!({"available": true, "enabled": true, "items": [
                    {"id": "m1", "content": "x", "updatedAt": 2},
                    {"id": "m0", "content": "x", "updatedAt": 1}
                ]}),
            )
        });
        daemon.on::<methods::MemoriesUpdate>(|p| {
            Ok(
                serde_json::json!({"available": true, "enabled": true, "items": [
                    {"id": p["id"], "content": p["content"], "updatedAt": 3}
                ]}),
            )
        });
        let held = daemon.hold::<methods::MemoriesAdd>();
        let scratch =
            std::env::temp_dir().join(format!("conduit-memory-same-{}", std::process::id()));
        let stores = cx.update(|cx| {
            crate::views::test_globals(cx);
            Stores::for_test(daemon.rpc(), &scratch, cx)
        });
        let (view, vcx) =
            cx.add_window_view(move |window, cx| PersonalizationPane::new(stores, window, cx));
        vcx.run_until_parked();
        view.update_in(vcx, |p, window, cx| {
            p.open_editor(None, window, cx);
            p.memory_input
                .update(cx, |i, cx| i.set_value("x", window, cx));
            p.save_memory(window, cx);
            p.memory_input
                .update(cx, |i, cx| i.set_value("x and more", window, cx));
        });
        vcx.run_until_parked();
        held.release();
        vcx.run_until_parked();
        view.update_in(vcx, |p, window, cx| p.save_memory(window, cx));
        vcx.run_until_parked();
        let updates = daemon.calls::<methods::MemoriesUpdate>();
        assert_eq!(updates.len(), 1);
        assert_eq!(updates[0]["id"], "m1", "the older memory was overwritten");
        assert_eq!(updates[0]["content"], "x and more");
        assert_eq!(daemon.calls::<methods::MemoriesAdd>().len(), 1);
    }
}
