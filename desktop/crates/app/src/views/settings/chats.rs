//! Settings › Chat, the phone's Chat page: the composer's switches (Send
//! with Enter, Save Drafts as Notes, Start Temporary Chats), its Quick
//! Actions, the message actions shown below a response (Automatic, or a
//! chosen set in order), citation titles, the Computer, the models' own
//! system prompts (Prompt Overrides) and the Advanced switch.
//!
//! Every switch writes core's `AppSettings` through `settings.set`; the
//! pane shows what the daemon answers ([`AppSettingsStore`]).

use std::rc::Rc;

use conduit_components::ActiveConduitTheme as _;
use conduit_components::assets::IconName;
use conduit_components::views::kit::{Button, IconButton, Switch, setting_row};
use conduit_components::views::settings::settings_section;
use conduit_protocol::{
    AppSettingsDto, AppSettingsPatch, ModelList, ModelPrompt, ModelPromptEdit, ModelPromptRef,
    NoParams, QuickPillOptions, methods,
};
use gpui_kit::component::input::{Textarea, TextareaState};
use gpui_kit::prelude::*;
use gpui_kit::{
    AnyElement, App, AsyncWindowContext, ClickEvent, Context, ElementId, Entity, SharedString,
    WeakEntity, Window, div, px,
};

use crate::l10n::{ActiveL10n as _, L10n};
use crate::stores::Stores;
use crate::stores::app_settings::AppSettingsStore;

use super::controls::{self, checkbox};

/// A model's prompt open for editing under Prompt Overrides.
pub struct PromptEditor {
    pub model_id: String,
    pub model_name: String,
    /// What the server said, once it has.
    pub prompt: Option<ModelPrompt>,
    pub saving: bool,
    pub error: bool,
}

pub struct ChatsPane {
    stores: Stores,
    pub pills: Option<QuickPillOptions>,
    pub models: Option<ModelList>,
    pub editor: Option<PromptEditor>,
    pub prompt_input: Entity<TextareaState>,
}

impl ChatsPane {
    pub fn new(stores: Stores, window: &mut Window, cx: &mut Context<Self>) -> Self {
        let l10n = cx.l10n().clone();
        let prompt_input = cx.new(|cx| {
            TextareaState::new(window, cx)
                .auto_grow(4, 14)
                .placeholder(l10n.enter_system_prompt())
        });
        cx.observe(&stores.app_settings, |_, _, cx| cx.notify())
            .detach();
        let mut this = Self {
            stores,
            pills: None,
            models: None,
            editor: None,
            prompt_input,
        };
        this.refresh(window, cx);
        this
    }

    fn store(&self) -> Entity<AppSettingsStore> {
        self.stores.app_settings.clone()
    }

    fn signed_in(&self, cx: &App) -> bool {
        self.stores.accounts.read(cx).active().is_some()
    }

    /// The pills on offer and the models (for Prompt Overrides).
    pub fn refresh(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let rpc = self.stores.connection.read(cx).rpc();
        let pills = rpc.call::<methods::SettingsQuickPills>(&NoParams);
        let models = rpc.call::<methods::ModelsList>(&conduit_protocol::ModelListQuery::default());
        cx.spawn_in(
            window,
            async move |this: WeakEntity<Self>, cx: &mut AsyncWindowContext| {
                let (pills, models) = (pills.await, models.await);
                let _ = this.update(cx, |s, cx| {
                    match pills {
                        Ok(p) => s.pills = Some(p),
                        Err(e) => log::warn!("settings.quickPills: {e}"),
                    }
                    match models {
                        Ok(m) => s.models = Some(m),
                        Err(e) => log::warn!("models.list: {e}"),
                    }
                    cx.notify();
                });
            },
        )
        .detach();
    }

    fn set(&self, patch: AppSettingsPatch, cx: &mut App) {
        self.store().update(cx, |s, cx| s.set(patch, cx));
    }

    /// A switch row writing one boolean of `AppSettings`.
    fn switch_row(
        &self,
        id: &'static str,
        title: String,
        subtitle: Option<String>,
        on: bool,
        patch: fn(bool) -> AppSettingsPatch,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let store = self.store();
        let switch = Switch::new(id, title.clone(), on).on_click(Rc::new(move |_, _, cx| {
            store.update(cx, |s, cx| s.set(patch(!on), cx));
        }));
        setting_row(title, subtitle.map(SharedString::from), switch, cx).into_any_element()
    }

    /// Turns a quick pill on or off, keeping the order they were chosen in.
    pub fn toggle_pill(&mut self, id: &str, cx: &mut Context<Self>) {
        let mut pills = self.store().read(cx).settings().quick_pills.clone();
        if let Some(i) = pills.iter().position(|p| p == id) {
            pills.remove(i);
        } else {
            pills.push(id.to_string());
        }
        self.set(
            AppSettingsPatch {
                quick_pills: Some(pills),
                ..Default::default()
            },
            cx,
        );
    }

    /// Automatic on: the default layout (null); off: core's defaults as a
    /// list to change from, as the phone writes them.
    pub fn set_automatic(&mut self, automatic: bool, cx: &mut Context<Self>) {
        let patch = if automatic {
            AppSettingsPatch {
                clear: vec!["inlineMessageActions".into()],
                ..Default::default()
            }
        } else {
            let defaults = self
                .store()
                .read(cx)
                .settings()
                .default_inline_message_actions
                .clone();
            AppSettingsPatch {
                inline_message_actions: Some(defaults),
                ..Default::default()
            }
        };
        self.set(patch, cx);
    }

    /// Shows `id` below responses (at the end) or moves it to More.
    pub fn toggle_action(&mut self, id: &str, cx: &mut Context<Self>) {
        let mut inline = self.store().read(cx).inline_message_actions();
        if let Some(i) = inline.iter().position(|a| a == id) {
            inline.remove(i);
        } else {
            inline.push(id.to_string());
        }
        self.write_actions(inline, cx);
    }

    /// Moves an inline action up (`-1`) or down (`1`).
    pub fn move_action(&mut self, id: &str, by: isize, cx: &mut Context<Self>) {
        let mut inline = self.store().read(cx).inline_message_actions();
        let Some(i) = inline.iter().position(|a| a == id) else {
            return;
        };
        let j = i as isize + by;
        if j < 0 || j as usize >= inline.len() {
            return;
        }
        inline.swap(i, j as usize);
        self.write_actions(inline, cx);
    }

    fn write_actions(&self, inline: Vec<String>, cx: &mut App) {
        self.set(
            AppSettingsPatch {
                inline_message_actions: Some(inline),
                ..Default::default()
            },
            cx,
        );
    }

    /// Opens `model`'s prompt for editing, reading it from the server.
    pub fn edit_prompt(
        &mut self,
        model_id: String,
        model_name: String,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.editor = Some(PromptEditor {
            model_id: model_id.clone(),
            model_name,
            prompt: None,
            saving: false,
            error: false,
        });
        self.prompt_input
            .update(cx, |s, cx| s.set_value("", window, cx));
        cx.notify();
        let call = self
            .stores
            .connection
            .read(cx)
            .rpc()
            .call::<methods::SettingsModelPrompt>(&ModelPromptRef {
                model_id: model_id.clone(),
            });
        cx.spawn_in(
            window,
            async move |this: WeakEntity<Self>, cx: &mut AsyncWindowContext| {
                let result = call.await;
                let _ = this.update_in(cx, |s, window, cx| {
                    // Another model's editor opened meanwhile: not its prompt.
                    let Some(editor) = s.editor.as_mut().filter(|e| e.model_id == model_id) else {
                        return;
                    };
                    match result {
                        Ok(prompt) => {
                            let text = prompt.prompt.clone();
                            editor.prompt = Some(prompt);
                            s.prompt_input
                                .update(cx, |i, cx| i.set_value(text, window, cx));
                        }
                        Err(e) => {
                            log::warn!("settings.modelPrompt: {e}");
                            editor.error = true;
                        }
                    }
                    cx.notify();
                });
            },
        )
        .detach();
    }

    pub fn save_prompt(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(editor) = self.editor.as_mut() else {
            return;
        };
        editor.saving = true;
        editor.error = false;
        let edit = ModelPromptEdit {
            model_id: editor.model_id.clone(),
            prompt: self.prompt_input.read(cx).value().to_string(),
        };
        let model_id = edit.model_id.clone();
        let call = self
            .stores
            .connection
            .read(cx)
            .rpc()
            .call::<methods::SettingsSetModelPrompt>(&edit);
        cx.notify();
        cx.spawn_in(
            window,
            async move |this: WeakEntity<Self>, cx: &mut AsyncWindowContext| {
                let result = call.await;
                let _ = this.update(cx, |s, cx| {
                    // Only the editor this save came from closes or says so.
                    if s.editor.as_ref().is_none_or(|e| e.model_id != model_id) {
                        return;
                    }
                    match result {
                        Ok(_) => s.editor = None,
                        Err(e) => {
                            log::warn!("settings.setModelPrompt: {e}");
                            if let Some(editor) = s.editor.as_mut() {
                                editor.saving = false;
                                editor.error = true;
                            }
                        }
                    }
                    cx.notify();
                });
            },
        )
        .detach();
    }

    fn composer_group(
        &self,
        s: &AppSettingsDto,
        l10n: &L10n,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let rows = vec![
            self.switch_row(
                "send-on-enter",
                l10n.send_on_enter(),
                Some(l10n.desktop_send_on_enter_description()),
                s.send_on_enter,
                |v| AppSettingsPatch {
                    send_on_enter: Some(v),
                    ..Default::default()
                },
                cx,
            ),
            self.switch_row(
                "composer-notes-button",
                l10n.show_composer_notes_button(),
                Some(l10n.show_composer_notes_button_description()),
                s.show_composer_notes_button,
                |v| AppSettingsPatch {
                    show_composer_notes_button: Some(v),
                    ..Default::default()
                },
                cx,
            ),
            // Mobile's #1053: the empty message box names the selected model.
            self.switch_row(
                "model-name-in-composer",
                l10n.show_model_name_in_composer(),
                Some(l10n.show_model_name_in_composer_description()),
                s.show_model_name_in_composer,
                |v| AppSettingsPatch {
                    show_model_name_in_composer: Some(v),
                    ..Default::default()
                },
                cx,
            ),
            self.switch_row(
                "temporary-by-default",
                l10n.temporary_chat_by_default(),
                Some(l10n.temporary_chat_by_default_description()),
                s.temporary_chat_by_default,
                |v| AppSettingsPatch {
                    temporary_chat_by_default: Some(v),
                    ..Default::default()
                },
                cx,
            ),
        ];
        settings_section(SharedString::default(), None, rows, cx).into_any_element()
    }

    fn pills_group(
        &self,
        s: &AppSettingsDto,
        l10n: &L10n,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Option<AnyElement> {
        let pills = self.pills.as_ref()?;
        let chosen = |id: &str| s.quick_pills.iter().any(|p| p == id);
        let count = pills.options.iter().filter(|o| chosen(&o.id)).count();
        let rows = pills
            .options
            .iter()
            .enumerate()
            .map(|(i, option)| {
                let label = match option.kind.as_str() {
                    "web" => l10n.web(),
                    "image" => l10n.image_gen(),
                    _ => option.name.clone(),
                };
                let on = chosen(&option.id);
                let view = cx.entity().downgrade();
                let id = option.id.clone();
                let toggle = Rc::new(move |_: &ClickEvent, _: &mut Window, cx: &mut App| {
                    let id = id.clone();
                    let _ = view.update(cx, |v, cx| v.toggle_pill(&id, cx));
                });
                setting_row(
                    label.clone(),
                    None,
                    checkbox(
                        ElementId::NamedInteger("quick-pill".into(), i as u64),
                        label,
                        on,
                        toggle,
                        window,
                        cx,
                    ),
                    cx,
                )
                .into_any_element()
            })
            .collect();
        Some(
            settings_section(
                l10n.quick_actions_description(),
                Some(l10n.quick_actions_selected_count(count as i64).into()),
                rows,
                cx,
            )
            .into_any_element(),
        )
    }

    fn action_label(id: &str, l10n: &L10n) -> String {
        match id {
            "copy" => l10n.copy(),
            "tts" => l10n.tts_listen(),
            "regenerate" => l10n.regenerate(),
            "retry-without-effort" => l10n.retry_without_reasoning_effort(),
            "merge" => l10n.chat_merge_responses_action(),
            "usage" => l10n.usage_info(),
            "fork" => l10n.chat_branch_fork_chat(),
            "share" => l10n.share_system_sheet(),
            "delete" => l10n.delete(),
            other => other.to_string(),
        }
    }

    fn actions_group(
        &self,
        s: &AppSettingsDto,
        l10n: &L10n,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let automatic = s.inline_message_actions.is_none();
        let view = cx.entity().downgrade();
        let auto_switch = Switch::new(
            "message-actions-automatic",
            l10n.message_actions_automatic(),
            automatic,
        )
        .on_click(Rc::new(move |_, _, cx| {
            let _ = view.update(cx, |v, cx| v.set_automatic(!automatic, cx));
        }));
        let mut rows = vec![
            setting_row(l10n.message_actions_automatic(), None, auto_switch, cx).into_any_element(),
        ];
        let mut extra = vec![];
        if !automatic {
            let inline = self.store().read(cx).inline_message_actions();
            // Below Responses, in their order; then the rest, in More.
            let mut order: Vec<String> = inline.clone();
            order.extend(
                s.message_actions
                    .iter()
                    .filter(|a| !inline.contains(a))
                    .cloned(),
            );
            for (i, id) in order.iter().enumerate() {
                let on = inline.contains(id);
                let label = Self::action_label(id, l10n);
                let pos = inline.iter().position(|a| a == id);
                let mut trailing = div().flex().items_center().gap(px(4.));
                if let Some(pos) = pos {
                    for (by, icon, text, enabled) in [
                        (
                            -1isize,
                            IconName::ChevronUp,
                            l10n.desktop_move_up(),
                            pos > 0,
                        ),
                        (
                            1,
                            IconName::ChevronDown,
                            l10n.desktop_move_down(),
                            pos + 1 < inline.len(),
                        ),
                    ] {
                        let view = cx.entity().downgrade();
                        let action = id.clone();
                        trailing = trailing.child(
                            IconButton::new(
                                ElementId::Name(format!("move-{by}-{id}").into()),
                                icon,
                                format!("{text}: {label}"),
                            )
                            .size(24., 13.)
                            .disabled(!enabled)
                            .on_click(Rc::new(move |_, _, cx| {
                                let action = action.clone();
                                let _ = view.update(cx, |v, cx| v.move_action(&action, by, cx));
                            })),
                        );
                    }
                }
                let view = cx.entity().downgrade();
                let action = id.clone();
                trailing = trailing.child(checkbox(
                    ElementId::NamedInteger("message-action".into(), i as u64),
                    label.clone(),
                    on,
                    Rc::new(move |_, _, cx| {
                        let action = action.clone();
                        let _ = view.update(cx, |v, cx| v.toggle_action(&action, cx));
                    }),
                    window,
                    cx,
                ));
                let subtitle = if on {
                    l10n.message_actions_inline()
                } else {
                    l10n.more()
                };
                rows.push(
                    setting_row(label, Some(subtitle.into()), trailing, cx).into_any_element(),
                );
            }
            let view = cx.entity().downgrade();
            extra.push(
                controls::buttons(vec![
                    Button::new("message-actions-reset", l10n.message_actions_reset())
                        .on_click(Rc::new(move |_, _, cx| {
                            let _ = view.update(cx, |v, cx| v.set_automatic(true, cx));
                        }))
                        .into_any_element(),
                ])
                .into_any_element(),
            );
        }
        div()
            .flex()
            .flex_col()
            .gap(px(10.))
            .child(settings_section(
                l10n.message_actions_title(),
                Some(l10n.desktop_message_actions_footer().into()),
                rows,
                cx,
            ))
            .children(extra)
            .into_any_element()
    }

    fn prompts_group(
        &self,
        l10n: &L10n,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Option<AnyElement> {
        let models = self.models.as_ref()?;
        if models.models.is_empty() {
            return None;
        }
        let mut rows = vec![];
        for (i, model) in models.models.iter().enumerate() {
            let view = cx.entity().downgrade();
            let (id, name) = (model.id.clone(), model.name.clone());
            let open = self.editor.as_ref().is_some_and(|e| e.model_id == model.id);
            rows.push(
                setting_row(
                    model.name.clone(),
                    model.connection.clone().map(SharedString::from),
                    Button::new(
                        ElementId::NamedInteger("model-prompt".into(), i as u64),
                        l10n.desktop_edit_ellipsis(),
                    )
                    .disabled(open)
                    .on_click(Rc::new(move |_, window, cx| {
                        let (id, name) = (id.clone(), name.clone());
                        let _ = view.update(cx, |v, cx| v.edit_prompt(id, name, window, cx));
                    })),
                    cx,
                )
                .into_any_element(),
            );
        }
        let mut out = div().flex().flex_col().gap(px(12.)).child(settings_section(
            l10n.prompt_overrides_title(),
            Some(
                l10n.accessible_models_count(models.models.len() as i64)
                    .into(),
            ),
            rows,
            cx,
        ));
        if let Some(editor) = &self.editor {
            out = out.child(self.prompt_editor(editor, l10n, window, cx));
        }
        Some(out.into_any_element())
    }

    fn prompt_editor(
        &self,
        editor: &PromptEditor,
        l10n: &L10n,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let t = cx.conduit().clone();
        let writable = editor.prompt.as_ref().is_some_and(|p| p.writable);
        let editable = editor.prompt.as_ref().is_none_or(|p| p.editable);
        let note: SharedString = match &editor.prompt {
            None if editor.error => l10n.desktop_action_failed().into(),
            None => l10n.desktop_loading().into(),
            Some(p) if !p.editable => l10n.model_no_editable_server_record().into(),
            Some(p) if !p.writable => l10n.model_no_write_access_description().into(),
            Some(_) if editor.error => l10n.desktop_action_failed().into(),
            Some(_) => l10n.model_system_prompt_editor_description().into(),
        };
        let view = cx.entity().downgrade();
        let cancel = Button::new("model-prompt-cancel", l10n.cancel()).on_click(Rc::new({
            let view = view.clone();
            move |_, _, cx| {
                let _ = view.update(cx, |v, cx| {
                    v.editor = None;
                    cx.notify();
                });
            }
        }));
        let save = Button::new("model-prompt-save", l10n.save())
            .primary()
            .disabled(!writable || editor.saving)
            .on_click(Rc::new(move |_, window, cx| {
                let _ = view.update(cx, |v, cx| v.save_prompt(window, cx));
            }));
        let mut body = div().p(px(12.)).flex().flex_col().gap(px(10.));
        if editable {
            body = body.child(
                div()
                    .w_full()
                    .child(Textarea::new(&self.prompt_input).disabled(!writable)),
            );
        }
        let _ = (window, &t);
        settings_section(
            l10n.model_system_prompt_title(&editor.model_name),
            Some(note),
            vec![
                body.into_any_element(),
                div()
                    .px(px(12.))
                    .pb(px(12.))
                    .child(controls::buttons(vec![
                        cancel.into_any_element(),
                        save.into_any_element(),
                    ]))
                    .into_any_element(),
            ],
            cx,
        )
        .into_any_element()
    }
}

/// Remote Content: the sites whose pictures and PDF previews load without
/// a click (Always Load Images from …), each with Remove. Kept on this Mac
/// for every account (see `prefs::Preferences::remote_image_hosts`).
fn remote_content_section(l10n: &crate::l10n::L10n, cx: &mut Context<ChatsPane>) -> AnyElement {
    let Some(settings) = cx
        .try_global::<crate::AppState>()
        .map(|s| s.settings.clone())
    else {
        return div().into_any_element();
    };
    let hosts = settings.read(cx).prefs.remote_image_hosts.clone();
    let t = cx.conduit().clone();
    let rows: Vec<AnyElement> = if hosts.is_empty() {
        vec![
            div()
                .id("remote-content-none")
                .w_full()
                .min_h(px(t.metrics.row_height + 16.))
                .px(px(12.))
                .flex()
                .items_center()
                .text_size(px(t.metrics.control))
                .text_color(t.roles.text_subtle)
                .child(SharedString::from(l10n.desktop_remote_content_none()))
                .into_any_element(),
        ]
    } else {
        hosts
            .iter()
            .enumerate()
            .map(|(i, host)| {
                let settings = settings.clone();
                let forget = host.clone();
                let remove = Button::new(
                    ElementId::Name(format!("remote-content-remove-{i}").into()),
                    l10n.desktop_remove_site(),
                )
                .on_click(Rc::new(move |_, _, cx| {
                    settings.update(cx, |s, cx| s.forget_image_host(&forget, cx));
                }));
                setting_row(host.clone(), None, remove, cx).into_any_element()
            })
            .collect()
    };
    settings_section(
        l10n.desktop_remote_content(),
        Some(
            if hosts.is_empty() {
                l10n.desktop_remote_content_footer_empty()
            } else {
                l10n.desktop_remote_content_footer()
            }
            .into(),
        ),
        rows,
        cx,
    )
    .into_any_element()
}

impl Render for ChatsPane {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let l10n = cx.l10n().clone();
        let s = self.store().read(cx).settings().clone();
        let signed_in = self.signed_in(cx);
        let mut sections = vec![self.composer_group(&s, &l10n, cx)];
        if signed_in && let Some(pills) = self.pills_group(&s, &l10n, window, cx) {
            sections.push(pills);
        }
        sections.push(self.actions_group(&s, &l10n, window, cx));
        sections.push(
            settings_section(
                SharedString::default(),
                None,
                vec![
                    self.switch_row(
                        "citation-titles",
                        l10n.citation_show_titles(),
                        Some(l10n.citation_show_titles_description()),
                        s.citation_show_titles,
                        |v| AppSettingsPatch {
                            citation_show_titles: Some(v),
                            ..Default::default()
                        },
                        cx,
                    ),
                    // The phone's Highlight Citations (its Appearance page
                    // has it beside the titles switch).
                    self.switch_row(
                        "citation-background",
                        l10n.citation_background(),
                        Some(l10n.citation_background_description()),
                        s.citation_background,
                        |v| AppSettingsPatch {
                            citation_background: Some(v),
                            ..Default::default()
                        },
                        cx,
                    ),
                    self.switch_row(
                        "computer-enabled",
                        l10n.computer_title(),
                        Some(l10n.computer_enabled_description()),
                        s.computer_enabled,
                        |v| AppSettingsPatch {
                            computer_enabled: Some(v),
                            ..Default::default()
                        },
                        cx,
                    ),
                ],
                cx,
            )
            .into_any_element(),
        );
        sections.push(remote_content_section(&l10n, cx));
        if signed_in && let Some(prompts) = self.prompts_group(&l10n, window, cx) {
            sections.push(prompts);
        }
        sections.push(
            settings_section(
                SharedString::default(),
                Some(l10n.advanced_features_footer().into()),
                vec![self.switch_row(
                    "advanced-features",
                    l10n.advanced_features(),
                    Some(l10n.advanced_features_description()),
                    s.advanced_features_enabled,
                    |v| AppSettingsPatch {
                        advanced_features_enabled: Some(v),
                        ..Default::default()
                    },
                    cx,
                )],
                cx,
            )
            .into_any_element(),
        );
        div().flex().flex_col().gap(px(22.)).children(sections)
    }
}

#[cfg(test)]
mod tests {
    use gpui_kit::TestAppContext;

    use super::*;
    use crate::stores::rpc::fake::FakeDaemon;

    #[gpui_kit::test]
    fn a_late_prompt_never_lands_in_another_models_editor(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        daemon.on::<methods::SettingsModelPrompt>(|p| {
            let id = p["modelId"].as_str().unwrap_or_default().to_string();
            Ok(serde_json::json!({
                "modelId": id, "editable": true, "writable": true,
                "prompt": format!("Prompt of {id}"),
            }))
        });
        let held = daemon.hold_one::<methods::SettingsModelPrompt>(0);
        let scratch = std::env::temp_dir().join(format!("conduit-chats-{}", std::process::id()));
        let stores = cx.update(|cx| {
            crate::views::test_globals(cx);
            Stores::for_test(daemon.rpc(), &scratch, cx)
        });
        let (view, vcx) = cx.add_window_view(move |window, cx| ChatsPane::new(stores, window, cx));
        view.update_in(vcx, |p, window, cx| {
            p.edit_prompt("alpha".into(), "Alpha".into(), window, cx);
            p.edit_prompt("beta".into(), "Beta".into(), window, cx);
        });
        vcx.run_until_parked();
        held.release();
        vcx.run_until_parked();
        view.read_with(vcx, |p, cx| {
            let editor = p.editor.as_ref().unwrap();
            assert_eq!(editor.model_id, "beta");
            assert_eq!(
                editor.prompt.as_ref().map(|p| p.model_id.as_str()),
                Some("beta")
            );
            assert_eq!(p.prompt_input.read(cx).value(), "Prompt of beta");
        });
    }
}
