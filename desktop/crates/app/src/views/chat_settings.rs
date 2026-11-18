//! Chat Settings: a chat's own system prompt and parameters (Open WebUI's
//! `chat.params`), as mobile's Chat Settings sheet edits them, in a window
//! sheet on the main window (Chat › Chat Settings…, ⌘I, or the chat's More
//! menu).
//!
//! A sheet rather than an inspector: the edit is explicit (Save writes
//! only what changed, Cancel asks before throwing edits away), as on the
//! phone, and an occasional per-chat form should not take width from the
//! transcript while it is open. Every rule (what may be edited, how a value
//! parses, what a save writes) is the daemon's (`chatSettings.*`, over
//! core's form); this view draws the form it answers with and sends back
//! what the fields hold.
//!
//! Without Settings › Chat › Advanced, a chat with saved settings shows a
//! read-only summary instead, with Turn On Advanced to Change Them, as on
//! the phone.

use std::collections::BTreeMap;
use std::rc::Rc;
use std::time::Duration;

use conduit_components::ActiveConduitTheme as _;
use conduit_components::announce::{Priority, live_text};
use conduit_components::assets::IconName;
use conduit_components::views::kit::{Button, IconButton, Segment, Segmented, grouped_section};
use conduit_protocol::{
    AppSettingsPatch, ChatSettingError, ChatSettingField, ChatSettingFieldEdit, ChatSettingKind,
    ChatSettingMode, ChatSettingsEdit, ChatSettingsEntry, ChatSettingsQuery, ChatSettingsState,
    NoticeLevel, methods,
};
use gpui_kit::component::input::{InputEvent, InputState, Textarea, TextareaState};
use gpui_kit::prelude::*;
use gpui_kit::{
    AnyElement, App, AsyncApp, Context, Entity, FontWeight, Role, SharedString, Subscription, Task,
    WeakEntity, Window, div, px, relative,
};
use serde_json::Value;

use crate::actions::SettingsChoice;
use crate::l10n::{ActiveL10n as _, L10n};
use crate::shell::sheet::{SheetSpec, present_sheet};
use crate::stores::Stores;
use crate::stores::rpc::Rpc;
use crate::views::forms;
use crate::views::settings::controls::{self, Choice};
use crate::views::sheet::{self, SheetBody};

/// The sheet's width.
pub const WIDTH: f32 = 560.;

/// How long the form waits after a keystroke before the daemon checks it.
const CHECK_DELAY: Duration = Duration::from_millis(150);

/// The pop-up value for "Your Default" and for the model's own default.
const INHERIT: &str = "__inherit__";
const MODEL_DEFAULT: &str = "__default__";

/// What the sheet edits.
#[derive(Clone, Debug, PartialEq)]
pub struct ChatSettingsTarget {
    /// None: the next new chat, whose settings are [`Self::draft`].
    pub chat_id: Option<String>,
    /// The model the chat runs on (its reasoning choices).
    pub model_id: Option<String>,
    /// A new chat's settings so far.
    pub draft: Value,
}

/// Where a new chat's saved settings go (the composer keeps them for its
/// first message).
pub type DraftSink = Rc<dyn Fn(Value, &mut App)>;

pub struct ChatSettingsSheet {
    stores: Stores,
    rpc: Rpc,
    target: ChatSettingsTarget,
    on_draft: Option<DraftSink>,
    /// The daemon's last answer.
    pub state: Option<ChatSettingsState>,
    /// The editor rather than the read-only summary.
    editing: bool,
    /// What the fields hold, and what they held when the sheet opened.
    pub edits: Vec<ChatSettingFieldEdit>,
    initial: Vec<ChatSettingFieldEdit>,
    system: Entity<TextareaState>,
    inputs: Vec<(String, Entity<InputState>)>,
    /// The daemon's verdict on what the fields hold.
    errors: BTreeMap<String, ChatSettingError>,
    saving: bool,
    pub failure: Option<String>,
    generation: u64,
    _subscriptions: Vec<Subscription>,
    _load: Option<Task<()>>,
    _check: Option<Task<()>>,
    /// Closes the sheet when another account becomes active.
    _account: Subscription,
}

impl ChatSettingsSheet {
    pub fn new(
        stores: Stores,
        target: ChatSettingsTarget,
        on_draft: Option<DraftSink>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Self {
        let rpc = stores.connection.read(cx).rpc();
        let placeholder = cx.l10n().enter_system_prompt();
        let system = cx.new(|cx| {
            TextareaState::new(window, cx)
                .auto_grow(3, 10)
                .placeholder(placeholder)
        });
        let subscriptions =
            vec![
                cx.subscribe_in(&system, window, |this, state, e: &InputEvent, _, cx| {
                    if matches!(e, InputEvent::Change) {
                        let text = state.read(cx).value().to_string();
                        this.set_edit("system", ChatSettingMode::Custom, text, cx);
                    }
                }),
            ];
        let account = sheet::close_with_account(&stores, cx);
        let mut this = Self {
            _account: account,
            stores,
            rpc,
            target,
            on_draft,
            state: None,
            editing: false,
            edits: vec![],
            initial: vec![],
            system,
            inputs: vec![],
            errors: BTreeMap::new(),
            saving: false,
            failure: None,
            generation: 0,
            _subscriptions: subscriptions,
            _load: None,
            _check: None,
        };
        this.load(window, cx);
        this
    }

    /// `chatSettings.get`, then the fields as it answers.
    fn load(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let call = self
            .rpc
            .call::<methods::ChatSettingsGet>(&ChatSettingsQuery {
                chat_id: self.target.chat_id.clone(),
                model_id: self.target.model_id.clone(),
                draft: self.target.draft.clone(),
            });
        let window_handle = window.window_handle();
        self._load = Some(
            cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
                let result = call.await;
                let _ = window_handle.update(cx, |_, window, cx| {
                    let _ = this.update(cx, |s, cx| match result {
                        Ok(state) => s.adopt(state, window, cx),
                        Err(e) => {
                            log::warn!("chatSettings.get: {e}");
                            s.failure = Some(cx.l10n().error_message());
                            cx.notify();
                        }
                    });
                });
            }),
        );
    }

    fn adopt(&mut self, state: ChatSettingsState, window: &mut Window, cx: &mut Context<Self>) {
        self.editing = state.entry == ChatSettingsEntry::Editor;
        let edits: Vec<ChatSettingFieldEdit> = std::iter::once(&state.system_prompt)
            .chain(state.parameters.iter())
            .map(|f| ChatSettingFieldEdit {
                key: f.key.clone(),
                mode: f.mode,
                text: f.text.clone(),
            })
            .collect();
        self.initial = edits.clone();
        self.edits = edits;
        self.errors.clear();
        // The fields, holding what is saved.
        let text = state.system_prompt.text.clone();
        self.system
            .update(cx, |s, cx| s.set_value(text, window, cx));
        let l10n = cx.l10n().clone();
        let mut inputs = vec![];
        let mut subscriptions = vec![];
        for field in &state.parameters {
            if field.kind == ChatSettingKind::Choice {
                continue;
            }
            let input = forms::input(placeholder(field, &l10n), false, window, cx);
            let value = field.text.clone();
            input.update(cx, |s, cx| s.set_value(value, window, cx));
            let key = field.key.clone();
            subscriptions.push(cx.subscribe_in(
                &input,
                window,
                move |this, state, e: &InputEvent, window, cx| match e {
                    InputEvent::Change => {
                        let text = state.read(cx).value().to_string();
                        this.set_edit(&key, ChatSettingMode::Custom, text, cx);
                    }
                    InputEvent::PressEnter { .. } => this.save(window, cx),
                    _ => {}
                },
            ));
            inputs.push((field.key.clone(), input));
        }
        self.inputs = inputs;
        self._subscriptions.truncate(1);
        self._subscriptions.extend(subscriptions);
        self.state = Some(state);
        cx.notify();
    }

    /// Types `text` into `key`'s field, as the user would (the system
    /// prompt switches to Custom).
    pub fn type_field(
        &mut self,
        key: &str,
        text: &str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let value = text.to_string();
        if key == "system" {
            self.system
                .update(cx, |s, cx| s.set_value(value, window, cx));
        } else if let Some((_, input)) = self.inputs.iter().find(|(k, _)| k == key) {
            input.update(cx, |s, cx| s.set_value(value, window, cx));
        }
        self.set_edit(key, ChatSettingMode::Custom, text.to_string(), cx);
    }

    /// The daemon's verdict on `key`, once it checked.
    pub fn error_of(&self, key: &str) -> Option<ChatSettingError> {
        self.errors.get(key).copied()
    }

    /// Whether a save is on its way.
    pub fn saving(&self) -> bool {
        self.saving
    }

    fn edit(&self, key: &str) -> Option<&ChatSettingFieldEdit> {
        self.edits.iter().find(|e| e.key == key)
    }

    /// The user changed `key`'s field.
    fn set_edit(&mut self, key: &str, mode: ChatSettingMode, text: String, cx: &mut Context<Self>) {
        let Some(edit) = self.edits.iter_mut().find(|e| e.key == key) else {
            return;
        };
        if edit.mode == mode && edit.text == text {
            return;
        }
        edit.mode = mode;
        edit.text = text;
        self.failure = None;
        self.schedule_check(cx);
        cx.notify();
    }

    /// Puts `key` back to the user's default, its field emptied.
    pub fn inherit(&mut self, key: &str, window: &mut Window, cx: &mut Context<Self>) {
        if key == "system" {
            self.system.update(cx, |s, cx| s.set_value("", window, cx));
        } else if let Some((_, input)) = self.inputs.iter().find(|(k, _)| k == key) {
            input.update(cx, |s, cx| s.set_value("", window, cx));
        }
        self.set_edit(key, ChatSettingMode::Inherit, String::new(), cx);
    }

    /// Reset All: everything this account may change goes back to its
    /// default.
    pub fn reset_all(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(state) = &self.state else {
            return;
        };
        let mut keys = vec![];
        if state.can_edit_system_prompt {
            keys.push("system".to_string());
        }
        if state.can_edit_parameters {
            keys.extend(state.parameters.iter().map(|f| f.key.clone()));
        }
        for key in keys {
            self.inherit(&key, window, cx);
        }
    }

    /// Whether the fields differ from what is saved.
    pub fn is_dirty(&self) -> bool {
        self.edits != self.initial
    }

    fn schedule_check(&mut self, cx: &mut Context<Self>) {
        self.generation += 1;
        let generation = self.generation;
        let edit = self.request();
        let rpc = self.rpc.clone();
        self._check = Some(
            cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
                cx.background_executor().timer(CHECK_DELAY).await;
                let result = rpc.call::<methods::ChatSettingsCheck>(&edit).await;
                let _ = this.update(cx, |s, cx| {
                    if s.generation != generation {
                        return;
                    }
                    // A check that could not run holds nothing against the
                    // fields: Save asks the daemon, which checks again.
                    s.errors = match result {
                        Ok(state) => errors_of(&state),
                        Err(e) => {
                            log::info!("chatSettings.check: {e}");
                            BTreeMap::new()
                        }
                    };
                    cx.notify();
                });
            }),
        );
    }

    fn request(&self) -> ChatSettingsEdit {
        ChatSettingsEdit {
            chat_id: self.target.chat_id.clone(),
            model_id: self.target.model_id.clone(),
            draft: self.target.draft.clone(),
            fields: self.edits.clone(),
        }
    }

    fn can_save(&self) -> bool {
        let Some(state) = &self.state else {
            return false;
        };
        self.editing
            && !self.saving
            && self.is_dirty()
            && self.errors.is_empty()
            && (state.can_edit_system_prompt || state.can_edit_parameters)
    }

    /// Save: only what changed is written. Errors stay on the form.
    pub fn save(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if !self.can_save() {
            return;
        }
        self.saving = true;
        self.failure = None;
        cx.notify();
        // A check on its way answers for older text.
        self.generation += 1;
        let sent = self.edits.clone();
        let call = self.rpc.call::<methods::ChatSettingsSave>(&self.request());
        let window_handle = window.window_handle();
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result = call.await;
            let _ = window_handle.update(cx, |_, _, cx| {
                let _ = this.update(cx, |s, cx| s.saved(result, sent, cx));
            });
        })
        .detach();
    }

    /// `sent`: the fields the save carried. Edits made while it was on its
    /// way stay in the sheet, to be saved.
    fn saved(
        &mut self,
        result: Result<ChatSettingsState, conduit_protocol::RpcError>,
        sent: Vec<ChatSettingFieldEdit>,
        cx: &mut Context<Self>,
    ) {
        self.saving = false;
        let l10n = cx.l10n().clone();
        match result {
            Ok(state) if state.saved => {
                if self.target.chat_id.is_none()
                    && let Some(sink) = self.on_draft.clone()
                {
                    sink(state.params.clone(), cx);
                }
                self.stores
                    .toasts
                    .update(cx, |t, cx| t.show(NoticeLevel::Info, l10n.saved(), cx));
                // The chat's More menu and the Chat menu follow.
                cx.defer(crate::menus::refresh_menus);
                let changed_since = self.edits != sent;
                self.initial = sent;
                if !changed_since {
                    sheet::dismiss(cx);
                }
            }
            Ok(state) => {
                self.errors = errors_of(&state);
            }
            Err(e) => {
                log::warn!("chatSettings.save: {e}");
                self.failure = Some(match e.args.get("reason").map(String::as_str) {
                    Some("permissionDenied") => l10n.chat_settings_parameters_locked(),
                    Some("ownerChanged") => l10n.chat_settings_owner_changed(),
                    _ => l10n.error_message(),
                });
            }
        }
        cx.notify();
    }

    /// Turn On Advanced to Change Them: Settings › Chat › Advanced, then the
    /// editor in place of the summary.
    fn turn_on_advanced(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let call = self.rpc.call::<methods::SettingsSet>(&AppSettingsPatch {
            advanced_features_enabled: Some(true),
            ..Default::default()
        });
        let settings = self.stores.app_settings.clone();
        let window_handle = window.window_handle();
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result = call.await;
            let _ = window_handle.update(cx, |_, window, cx| match result {
                Ok(dto) => {
                    settings.update(cx, |s, cx| s.adopt(dto, cx));
                    let _ = this.update(cx, |s, cx| s.load(window, cx));
                }
                Err(e) => {
                    log::warn!("settings.set: {e}");
                    let _ = this.update(cx, |s, cx| {
                        s.failure = Some(cx.l10n().error_message());
                        cx.notify();
                    });
                }
            });
        })
        .detach();
    }

    // ── Drawing ────────────────────────────────────────────────────────

    fn header(&self, title: String, description: String, cx: &App) -> AnyElement {
        let t = cx.conduit();
        div()
            .flex()
            .flex_col()
            .gap(px(4.))
            .child(
                div()
                    .id("sheet-title")
                    .role(Role::Heading)
                    .text_size(px(t.metrics.body + 2.))
                    .font_weight(FontWeight::SEMIBOLD)
                    .child(title),
            )
            .child(
                div()
                    .text_size(px(t.metrics.small + 0.5))
                    .line_height(relative(1.4))
                    .text_color(t.roles.text_subtle)
                    .child(description),
            )
            .into_any_element()
    }

    fn system_section(
        &self,
        state: &ChatSettingsState,
        l10n: &L10n,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let t = cx.conduit().clone();
        if !state.can_edit_system_prompt {
            return grouped_section(
                Some(l10n.chat_settings_system_prompt().into()),
                vec![note_row(l10n.chat_settings_system_prompt_locked(), cx)],
                None,
                cx,
            )
            .into_any_element();
        }
        let custom = self
            .edit("system")
            .is_some_and(|e| e.mode == ChatSettingMode::Custom);
        let view = cx.entity().downgrade();
        let segmented = Segmented::new(
            "chat-settings-system-mode",
            l10n.chat_settings_system_prompt(),
            vec![
                Segment::new(l10n.chat_settings_inherit()),
                Segment::new(l10n.chat_settings_custom()),
            ],
            usize::from(custom),
        )
        .on_select(Rc::new(move |i, window, cx| {
            let _ = view.update(cx, |v, cx| {
                if i == 0 {
                    v.inherit("system", window, cx);
                } else {
                    let text = v.system.read(cx).value().to_string();
                    v.set_edit("system", ChatSettingMode::Custom, text, cx);
                    v.system.update(cx, |s, cx| s.focus(window, cx));
                }
            });
        }));
        let mut rows = vec![
            forms::form_row(l10n.chat_settings_system_prompt(), segmented, cx).into_any_element(),
        ];
        if custom {
            let empty = self.system.read(cx).value().trim().is_empty();
            rows.push(
                div()
                    .id("chat-settings-system-field")
                    .p(px(12.))
                    .flex()
                    .flex_col()
                    .gap(px(6.))
                    .child(Textarea::new(&self.system))
                    .when(empty, |d| {
                        d.child(
                            div()
                                .text_size(px(t.metrics.small))
                                .line_height(relative(1.35))
                                .text_color(t.roles.text_subtle)
                                .child(l10n.chat_settings_system_prompt_empty_note()),
                        )
                    })
                    .into_any_element(),
            );
        }
        let _ = window;
        grouped_section(None, rows, None, cx).into_any_element()
    }

    fn parameters_section(
        &self,
        state: &ChatSettingsState,
        l10n: &L10n,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let title: SharedString = l10n.desktop_chat_settings_parameters().into();
        if !state.can_edit_parameters {
            return grouped_section(
                Some(title),
                vec![note_row(l10n.chat_settings_parameters_locked(), cx)],
                None,
                cx,
            )
            .into_any_element();
        }
        let rows = state
            .parameters
            .iter()
            .map(|field| match field.kind {
                ChatSettingKind::Choice => self.choice_row(field, l10n, window, cx),
                _ => self.text_row(field, l10n, window, cx),
            })
            .collect();
        grouped_section(
            Some(title),
            rows,
            state
                .other_kept
                .then(|| l10n.chat_settings_other_kept().into()),
            cx,
        )
        .into_any_element()
    }

    fn text_row(
        &self,
        field: &ChatSettingField,
        l10n: &L10n,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let Some((_, input)) = self.inputs.iter().find(|(k, _)| *k == field.key) else {
            return div().into_any_element();
        };
        let mode = self.edit(&field.key).map(|e| e.mode).unwrap_or(field.mode);
        let error = self
            .errors
            .get(&field.key)
            .map(|e| error_text(*e, field, l10n).into());
        let label = param_label(&field.key, l10n);
        let key = field.key.clone();
        let view = cx.entity().downgrade();
        let reset = IconButton::new(
            gpui_kit::ElementId::Name(format!("chat-setting-reset-{}", field.key).into()),
            IconName::RotateCcw,
            l10n.chat_settings_use_your_default(),
        )
        .size(26., 14.)
        .disabled(mode == ChatSettingMode::Inherit)
        .on_click(Rc::new(move |_, window, cx| {
            let _ = view.update(cx, |v, cx| v.inherit(&key, window, cx));
        }));
        div()
            .id(gpui_kit::ElementId::Name(
                format!("chat-setting-{}", field.key).into(),
            ))
            .w_full()
            .flex()
            .items_start()
            .child(
                div()
                    .flex_1()
                    .min_w_0()
                    .child(forms::field(label, input, None, error, window, cx)),
            )
            .child(div().pt(px(9.)).pr(px(8.)).child(reset))
            .into_any_element()
    }

    fn choice_row(
        &self,
        field: &ChatSettingField,
        l10n: &L10n,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let reasoning = field.key == "reasoning_effort";
        let edit = self.edit(&field.key);
        let mode = edit.map(|e| e.mode).unwrap_or(field.mode);
        let text = edit.map(|e| e.text.clone()).unwrap_or_default();
        let mut choices = vec![
            Choice::new(INHERIT, l10n.chat_settings_inherit()),
            Choice::new(
                MODEL_DEFAULT,
                if reasoning {
                    l10n.desktop_effort_automatic()
                } else {
                    l10n.chat_settings_model_default()
                },
            ),
        ];
        for (i, choice) in field.choices.iter().enumerate() {
            let label = if reasoning {
                effort_label(choice, l10n)
            } else {
                tool_calling_label(choice, l10n)
            };
            let item = Choice::new(choice.clone(), label);
            choices.push(if i == 0 { item.separated() } else { item });
        }
        // A saved value the choices do not offer stays as it is.
        if mode == ChatSettingMode::Custom && !field.choices.contains(&text) {
            choices.push(Choice::new(text.clone(), text.clone()).separated());
        }
        let selected = match mode {
            ChatSettingMode::Inherit | ChatSettingMode::Unknown => INHERIT.to_string(),
            ChatSettingMode::ModelDefault => MODEL_DEFAULT.to_string(),
            ChatSettingMode::Custom => text,
        };
        let label = param_label(&field.key, l10n);
        let popup = controls::popup(
            &format!("chat-setting:{}", field.key),
            &label,
            choices,
            &selected,
            self.saving,
            window,
            cx,
        );
        let error = self
            .errors
            .get(&field.key)
            .map(|e| error_text(*e, field, l10n));
        let t = cx.conduit().clone();
        div()
            .child(forms::form_row(label, popup, cx))
            .when_some(error, |d, e| {
                d.child(
                    div()
                        .id(gpui_kit::ElementId::Name(
                            format!("chat-setting-error-{}", field.key).into(),
                        ))
                        .role(Role::Alert)
                        .px(px(12.))
                        .pb(px(8.))
                        .text_size(px(t.metrics.small))
                        .text_color(t.roles.danger)
                        .child(e.clone())
                        .child(live_text("live", Some(e.into()), Priority::High)),
                )
            })
            .into_any_element()
    }

    pub fn on_choice(&mut self, action: &SettingsChoice, cx: &mut Context<Self>) {
        let Some(key) = action.menu.strip_prefix("chat-setting:") else {
            return;
        };
        let (mode, text) = match action.value.as_str() {
            INHERIT => (ChatSettingMode::Inherit, String::new()),
            MODEL_DEFAULT => (ChatSettingMode::ModelDefault, String::new()),
            other => (ChatSettingMode::Custom, other.to_string()),
        };
        self.set_edit(key, mode, text, cx);
    }

    fn editor(
        &self,
        state: &ChatSettingsState,
        l10n: &L10n,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Vec<AnyElement> {
        let mut out = vec![
            self.header(
                l10n.chat_settings_title(),
                l10n.chat_settings_description(),
                cx,
            ),
            self.system_section(state, l10n, window, cx),
            self.parameters_section(state, l10n, window, cx),
        ];
        if let Some(failure) = &self.failure {
            out.push(
                forms::form_error("chat-settings-failure", failure.clone(), cx).into_any_element(),
            );
        }
        out
    }

    fn summary(
        &self,
        state: &ChatSettingsState,
        l10n: &L10n,
        cx: &mut Context<Self>,
    ) -> Vec<AnyElement> {
        let t = cx.conduit().clone();
        let rows: Vec<AnyElement> = state
            .applied
            .iter()
            .map(|row| {
                let value = row
                    .value
                    .clone()
                    .unwrap_or_else(|| l10n.chat_settings_model_default());
                let value = if row.key == "reasoning_effort" {
                    effort_label(&value, l10n)
                } else {
                    value
                };
                div()
                    .px(px(12.))
                    .py(px(10.))
                    .flex()
                    .items_start()
                    .gap(px(12.))
                    .child(
                        div()
                            .w(px(forms::LABEL_COLUMN))
                            .flex_none()
                            .text_size(px(t.metrics.control))
                            .child(param_label(&row.key, l10n)),
                    )
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .text_size(px(t.metrics.control))
                            .line_height(relative(1.35))
                            .text_color(t.roles.text_subtle)
                            .child(value),
                    )
                    .into_any_element()
            })
            .collect();
        vec![
            self.header(
                l10n.chat_settings_applied(),
                l10n.chat_settings_applied_description(),
                cx,
            ),
            grouped_section(None, rows, None, cx).into_any_element(),
        ]
    }

    /// The editor's buttons: Reset All, then Cancel and Save.
    fn editor_buttons(
        &self,
        state: &ChatSettingsState,
        l10n: &L10n,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let view = cx.entity().downgrade();
        let can_edit = state.can_edit_system_prompt || state.can_edit_parameters;
        let reset_view = view.clone();
        let cancel_view = view.clone();
        let save_view = view;
        div()
            .w_full()
            .flex()
            .items_center()
            .gap(px(8.))
            .when(can_edit, |d| {
                d.child(
                    Button::new("chat-settings-reset-all", l10n.chat_settings_reset_all())
                        .disabled(self.saving)
                        .on_click(Rc::new(move |_, window, cx| {
                            let _ = reset_view.update(cx, |v, cx| v.reset_all(window, cx));
                        })),
                )
            })
            .child(div().flex_1())
            .child(
                Button::new("chat-settings-cancel", l10n.cancel()).on_click(Rc::new(
                    move |_, window, cx| {
                        let _ = cancel_view.update(cx, |v, cx| v.cancel(window, cx));
                    },
                )),
            )
            .child(
                Button::new("chat-settings-save", l10n.save())
                    .primary()
                    .shortcut("⌘↩")
                    .disabled(!self.can_save())
                    .on_click(Rc::new(move |_, window, cx| {
                        let _ = save_view.update(cx, |v, cx| v.save(window, cx));
                    })),
            )
            .into_any_element()
    }

    /// The summary's buttons: Turn On Advanced to Change Them, then Done.
    fn summary_buttons(
        &self,
        state: &ChatSettingsState,
        l10n: &L10n,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let view = cx.entity().downgrade();
        let can_edit = state.can_edit_system_prompt || state.can_edit_parameters;
        let advanced_view = view;
        div()
            .w_full()
            .flex()
            .items_center()
            .gap(px(8.))
            .child(div().flex_1())
            .when(!state.advanced && can_edit, |d| {
                d.child(
                    Button::new(
                        "chat-settings-turn-on-advanced",
                        l10n.chat_settings_turn_on_advanced(),
                    )
                    .on_click(Rc::new(move |_, window, cx| {
                        let _ = advanced_view.update(cx, |v, cx| v.turn_on_advanced(window, cx));
                    })),
                )
            })
            .child(
                Button::new("chat-settings-done", l10n.done())
                    .primary()
                    .on_click(Rc::new(move |_, _, cx| sheet::dismiss(cx))),
            )
            .into_any_element()
    }
}

impl SheetBody for ChatSettingsSheet {
    fn busy(&self, _: &App) -> bool {
        self.saving
    }

    fn unsaved(&self, _: &App) -> bool {
        ChatSettingsSheet::is_dirty(self)
    }

    fn footer(&mut self, _: &mut Window, cx: &mut Context<Self>) -> Option<AnyElement> {
        let state = self.state.clone()?;
        let l10n = cx.l10n().clone();
        Some(if self.editing {
            self.editor_buttons(&state, &l10n, cx)
        } else {
            self.summary_buttons(&state, &l10n, cx)
        })
    }

    fn cancel(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.saving {
            return;
        }
        if !self.editing || !self.is_dirty() {
            sheet::dismiss(cx);
            return;
        }
        let l10n = cx.l10n().clone();
        let spec = SheetSpec::new(
            l10n.desktop_discard_changes_title(),
            l10n.desktop_discard_changes_message(),
            l10n.desktop_discard(),
            l10n.cancel(),
        )
        .destructive();
        let ask = present_sheet(window, spec, cx);
        cx.spawn(async move |_, cx: &mut AsyncApp| {
            if ask.await {
                cx.update(sheet::dismiss);
            }
        })
        .detach();
    }

    fn label(&self, cx: &App) -> SharedString {
        cx.l10n().chat_settings_title().into()
    }
}

impl Render for ChatSettingsSheet {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let l10n = cx.l10n().clone();
        let t = cx.conduit().clone();
        let body: Vec<AnyElement> =
            match self.state.clone() {
                None => vec![self.header(l10n.chat_settings_title(), l10n.desktop_loading(), cx)]
                    .into_iter()
                    .chain(self.failure.clone().map(|f| {
                        forms::form_error("chat-settings-failure", f, cx).into_any_element()
                    }))
                    .collect(),
                Some(state) if self.editing => self.editor(&state, &l10n, window, cx),
                Some(state) => self.summary(&state, &l10n, cx),
            };
        div()
            .id("chat-settings")
            .w_full()
            .flex()
            .flex_col()
            .gap(px(16.))
            .text_size(px(t.metrics.control))
            // ⌘↩ saves from anywhere in the form (Return makes new lines in
            // the prompt).
            .on_key_down(cx.listener(|this, e: &gpui_kit::KeyDownEvent, window, cx| {
                let k = &e.keystroke;
                if k.key == "enter" && k.modifiers.platform {
                    this.save(window, cx);
                    cx.stop_propagation();
                }
            }))
            .on_action(cx.listener(|this, a: &SettingsChoice, _, cx| this.on_choice(a, cx)))
            .children(body)
    }
}

/// The daemon's errors, by key.
fn errors_of(state: &ChatSettingsState) -> BTreeMap<String, ChatSettingError> {
    std::iter::once(&state.system_prompt)
        .chain(state.parameters.iter())
        .filter_map(|f| f.error.map(|e| (f.key.clone(), e)))
        .collect()
}

/// A row in a locked section: why it cannot be changed.
fn note_row(text: String, cx: &App) -> AnyElement {
    let t = cx.conduit();
    div()
        .px(px(12.))
        .py(px(10.))
        .text_size(px(t.metrics.control))
        .text_color(t.roles.text_subtle)
        .child(text)
        .into_any_element()
}

/// A text field's placeholder: "Your Default" (the stop list says it is
/// comma-separated), or "Model Default" for a saved explicit default.
fn placeholder(field: &ChatSettingField, l10n: &L10n) -> String {
    if field.mode == ChatSettingMode::ModelDefault {
        l10n.chat_settings_model_default()
    } else if field.key == "stop" {
        l10n.chat_settings_stop_hint()
    } else {
        l10n.chat_settings_inherit()
    }
}

/// A parameter's name, as mobile's sheet calls it.
pub fn param_label(key: &str, l10n: &L10n) -> String {
    match key {
        "system" => l10n.chat_settings_system_prompt(),
        "temperature" => l10n.chat_setting_temperature(),
        "top_p" => l10n.chat_setting_top_p(),
        "top_k" => l10n.chat_setting_top_k(),
        "min_p" => l10n.chat_setting_min_p(),
        "frequency_penalty" => l10n.chat_setting_frequency_penalty(),
        "presence_penalty" => l10n.chat_setting_presence_penalty(),
        "max_tokens" => l10n.chat_setting_max_tokens(),
        "seed" => l10n.chat_setting_seed(),
        "stop" => l10n.chat_setting_stop(),
        "reasoning_effort" => l10n.desktop_reasoning_effort(),
        "function_calling" => l10n.chat_setting_function_calling(),
        "format" => l10n.chat_setting_response_format(),
        other => other.to_string(),
    }
}

/// A reasoning effort's name; one the app does not know shows as it is.
pub fn effort_label(effort: &str, l10n: &L10n) -> String {
    match effort {
        "automatic" => l10n.desktop_effort_automatic(),
        "none" => l10n.desktop_effort_none(),
        "minimal" => l10n.desktop_effort_minimal(),
        "low" => l10n.desktop_effort_low(),
        "medium" => l10n.desktop_effort_medium(),
        "high" => l10n.desktop_effort_high(),
        "xhigh" => l10n.desktop_effort_extra_high(),
        "max" => l10n.desktop_effort_maximum(),
        "light" => l10n.reasoning_effort_light(),
        "moderate" => l10n.reasoning_effort_moderate(),
        "deep" => l10n.reasoning_effort_deep(),
        other => other.to_string(),
    }
}

fn tool_calling_label(choice: &str, l10n: &L10n) -> String {
    match choice {
        "native" => l10n.desktop_tool_calling_native(),
        "legacy" => l10n.desktop_tool_calling_legacy(),
        other => other.to_string(),
    }
}

/// What a field's error says, with its range.
fn error_text(error: ChatSettingError, field: &ChatSettingField, l10n: &L10n) -> String {
    let number = |n: f64| {
        if n.fract() == 0. {
            format!("{}", n as i64)
        } else {
            format!("{n}")
        }
    };
    match error {
        ChatSettingError::Required => l10n.chat_setting_error_required(),
        ChatSettingError::NotANumber => l10n.chat_setting_error_not_a_number(),
        ChatSettingError::NotAWholeNumber => l10n.chat_setting_error_not_a_whole_number(),
        ChatSettingError::OutOfRange => match (field.min, field.max) {
            (Some(min), Some(max)) => l10n.chat_setting_error_range(&number(min), &number(max)),
            (min, _) => l10n.chat_setting_error_minimum(&number(min.unwrap_or(0.))),
        },
        ChatSettingError::NotJson => l10n.chat_setting_error_not_json(),
        ChatSettingError::NotAChoice | ChatSettingError::Unknown => {
            l10n.chat_setting_error_not_a_choice()
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_editable_parameter_has_a_name_of_its_own() {
        let l10n = L10n::new("en");
        for key in [
            "temperature",
            "top_p",
            "top_k",
            "min_p",
            "frequency_penalty",
            "presence_penalty",
            "max_tokens",
            "seed",
            "stop",
            "reasoning_effort",
            "function_calling",
            "format",
        ] {
            assert_ne!(param_label(key, &l10n), key, "{key}");
        }
    }

    #[test]
    fn efforts_read_as_words_and_an_unknown_one_as_typed() {
        let l10n = L10n::new("en");
        assert_eq!(effort_label("high", &l10n), "High");
        assert_eq!(effort_label("xhigh", &l10n), "Extra High");
        assert_eq!(effort_label("turbo-9", &l10n), "turbo-9");
    }

    #[test]
    fn a_range_error_names_its_bounds() {
        let l10n = L10n::new("en");
        let field = ChatSettingField {
            key: "temperature".into(),
            kind: ChatSettingKind::Decimal,
            mode: ChatSettingMode::Custom,
            text: "9".into(),
            choices: vec![],
            allows_custom: false,
            min: Some(0.),
            max: Some(2.),
            error: None,
        };
        assert_eq!(
            error_text(ChatSettingError::OutOfRange, &field, &l10n),
            "Enter a value from 0 to 2."
        );
    }

    mod sheet_tests {
        use gpui_kit::VisualTestContext;

        use super::super::*;
        use crate::views::sheet::bench::bench;

        fn state(temperature: &str) -> ChatSettingsState {
            serde_json::from_value(serde_json::json!({
                "chatId": "c1", "entry": "editor", "advanced": true,
                "canEditSystemPrompt": true, "canEditParameters": true,
                "systemPrompt": {"key": "system", "kind": "text", "mode": "inherit"},
                "parameters": [{"key": "temperature", "kind": "decimal", "mode": "custom",
                                "text": temperature, "min": 0.0, "max": 2.0}],
                "saved": true
            }))
            .unwrap()
        }

        fn open(stores: &Stores, vcx: &mut VisualTestContext) -> Entity<ChatSettingsSheet> {
            let stores = stores.clone();
            let target = ChatSettingsTarget {
                chat_id: Some("c1".into()),
                model_id: Some("m".into()),
                draft: serde_json::json!({}),
            };
            let sheet = vcx
                .update(|window, cx| {
                    sheet::open(window, WIDTH, cx, move |w, cx| {
                        ChatSettingsSheet::new(stores, target, None, w, cx)
                    })
                })
                .unwrap();
            vcx.run_until_parked();
            sheet
        }

        #[gpui_kit::test]
        fn a_failed_check_never_holds_save_back(cx: &mut gpui_kit::TestAppContext) {
            let (daemon, stores, vcx) = bench(cx);
            daemon.returns::<methods::ChatSettingsGet>(state("0.3"));
            daemon.on::<methods::ChatSettingsCheck>(|_| {
                Err(conduit_daemon::protocol::error(
                    "rpc.daemonUnavailable",
                    "away",
                ))
            });
            let sheet = open(&stores, vcx);
            sheet.update(vcx, |s, cx| {
                s.errors
                    .insert("temperature".into(), ChatSettingError::OutOfRange);
                s.set_edit("temperature", ChatSettingMode::Custom, "0.4".into(), cx);
            });
            vcx.executor().advance_clock(CHECK_DELAY);
            vcx.run_until_parked();
            sheet.read_with(vcx, |s, _| {
                assert!(
                    s.errors.is_empty(),
                    "the old error stayed after a check that failed"
                );
                assert!(s.can_save());
            });
        }

        #[gpui_kit::test]
        fn edits_made_while_saving_stay_to_be_saved(cx: &mut gpui_kit::TestAppContext) {
            let (daemon, stores, vcx) = bench(cx);
            daemon.returns::<methods::ChatSettingsGet>(state("0.3"));
            daemon.returns::<methods::ChatSettingsCheck>(state("0.4"));
            daemon.returns::<methods::ChatSettingsSave>(state("0.4"));
            let sheet = open(&stores, vcx);
            sheet.update(vcx, |s, cx| {
                s.set_edit("temperature", ChatSettingMode::Custom, "0.4".into(), cx)
            });
            vcx.executor().advance_clock(CHECK_DELAY);
            vcx.run_until_parked();
            let held = daemon.hold::<methods::ChatSettingsSave>();
            vcx.update(|window, cx| sheet.update(cx, |s, cx| s.save(window, cx)));
            sheet.update(vcx, |s, cx| {
                s.set_edit("temperature", ChatSettingMode::Custom, "0.5".into(), cx)
            });
            drop(held);
            vcx.run_until_parked();
            assert!(
                vcx.update(|_, cx| sheet::current::<ChatSettingsSheet>(cx))
                    .is_some(),
                "closed with 0.5 unsaved"
            );
            sheet.read_with(vcx, |s, _| assert!(s.is_dirty()));
        }
    }
}
