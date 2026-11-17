//! Tool Settings: the user's own settings ("personal valves") for the
//! tools, filters and pipe a chat uses, as mobile's Tool Settings sheet,
//! in a window sheet on the main window (Chat › Tool Settings…). The
//! workspace's tool editor opens it too, for one tool's valves: the server
//! valves everyone's chats use, and the account's own (`workspace.valves`).
//!
//! The daemon reads each one's schema and values (`valves.get`, over core's
//! personal valves editor) and types what the form sends back; the sheet
//! draws one row per valve: Default or Custom, and for Custom a switch, a
//! pop-up or a field, by the valve's type.

use std::rc::Rc;

use conduit_components::ActiveConduitTheme as _;
use conduit_components::views::kit::{Button, Switch, grouped_section};
use conduit_protocol::{
    NoticeLevel, ValveEdit, ValveField, ValveFieldType, ValveTarget, ValveTargetKind,
    ValvesDocument, ValvesPhase, ValvesRef, ValvesSave, WorkspaceValves, WorkspaceValvesQuery,
    methods,
};
use gpui_kit::component::input::{InputEvent, InputState};
use gpui_kit::prelude::*;
use gpui_kit::{
    AnyElement, App, AsyncApp, Context, ElementId, Entity, FontWeight, Role, SharedString,
    Subscription, Task, WeakEntity, Window, div, px, relative,
};

use crate::actions::SettingsChoice;
use crate::l10n::{ActiveL10n as _, L10n};
use crate::shell::sheet::{SheetSpec, present_sheet};
use crate::stores::Stores;
use crate::stores::rpc::Rpc;
use crate::views::forms;
use crate::views::settings::controls::{self, Choice};
use crate::views::sheet::{self, SheetBody};

/// The sheet's width.
pub const WIDTH: f32 = 520.;

const DEFAULT: &str = "__default__";
/// Where a form row's value starts (its 12 pt inset, the label column and
/// the gap after it).
const VALUE_INSET: f32 = 12. + forms::LABEL_COLUMN + 12.;
const CUSTOM: &str = "__custom__";

pub struct ValvesSheet {
    stores: Stores,
    rpc: Rpc,
    /// A workspace tool's valves (its id), rather than a chat's own.
    tool: Option<String>,
    targets: Vec<ValveTarget>,
    selected: usize,
    pub document: Option<ValvesDocument>,
    /// What the rows hold, and what they held when the set loaded.
    pub edits: Vec<ValveEdit>,
    initial: Vec<ValveEdit>,
    inputs: Vec<(String, Entity<InputState>)>,
    saving: bool,
    pub failure: Option<String>,
    _subscriptions: Vec<Subscription>,
    _load: Option<Task<()>>,
    /// Closes the sheet when another account becomes active.
    _account: Subscription,
}

impl ValvesSheet {
    pub fn new(
        stores: Stores,
        targets: Vec<ValveTarget>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Self {
        let rpc = stores.connection.read(cx).rpc();
        let account = sheet::close_with_account(&stores, cx);
        let mut this = Self {
            _account: account,
            stores,
            rpc,
            tool: None,
            targets,
            selected: 0,
            document: None,
            edits: vec![],
            initial: vec![],
            inputs: vec![],
            saving: false,
            failure: None,
            _subscriptions: vec![],
            _load: None,
        };
        this.load(window, cx);
        this
    }

    /// A workspace tool's valves: the server's (`user` false) or the
    /// account's own, with a pop-up between them when it has both.
    pub fn for_tool(
        stores: Stores,
        tool_id: String,
        name: String,
        server: bool,
        user: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Self {
        let l10n = cx.l10n().clone();
        let mut targets = vec![];
        if server {
            targets.push(ValveTarget {
                kind: ValveTargetKind::Tool,
                id: "server".into(),
                label: l10n.workspace_tool_valves_server(),
            });
        }
        if user {
            targets.push(ValveTarget {
                kind: ValveTargetKind::Tool,
                id: "user".into(),
                label: l10n.workspace_tool_valves_user(),
            });
        }
        let rpc = stores.connection.read(cx).rpc();
        let _ = name;
        let account = sheet::close_with_account(&stores, cx);
        let mut this = Self {
            _account: account,
            stores,
            rpc,
            tool: Some(tool_id),
            targets,
            selected: 0,
            document: None,
            edits: vec![],
            initial: vec![],
            inputs: vec![],
            saving: false,
            failure: None,
            _subscriptions: vec![],
            _load: None,
        };
        this.load(window, cx);
        this
    }

    fn target(&self) -> Option<&ValveTarget> {
        self.targets.get(self.selected)
    }

    /// A workspace tool's valves as the form draws them.
    fn tool_document(target: &ValveTarget, valves: WorkspaceValves) -> ValvesDocument {
        ValvesDocument {
            kind: ValveTargetKind::Tool,
            id: target.id.clone(),
            label: target.label.clone(),
            phase: if valves.fields.is_empty() {
                ValvesPhase::Unavailable
            } else {
                ValvesPhase::Ready
            },
            fields: valves.fields,
        }
    }

    fn load(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(target) = self.target().cloned() else {
            return;
        };
        self.document = None;
        self.failure = None;
        if let Some(tool_id) = self.tool.clone() {
            let call = self
                .rpc
                .call::<methods::WorkspaceValves>(&WorkspaceValvesQuery {
                    tool_id,
                    user: target.id == "user",
                });
            let handle = window.window_handle();
            self._load = Some(
                cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
                    let result = call.await;
                    let _ = handle.update(cx, |_, window, cx| {
                        let _ = this.update(cx, |s, cx| match result {
                            Ok(valves) => {
                                let doc = Self::tool_document(&target, valves);
                                s.adopt(doc, window, cx)
                            }
                            Err(e) => {
                                log::warn!("workspace.valves: {e}");
                                s.failure =
                                    Some(cx.l10n().desktop_workspace_tool_valves_load_failed());
                                cx.notify();
                            }
                        });
                    });
                }),
            );
            cx.notify();
            return;
        }
        let call = self.rpc.call::<methods::ValvesGet>(&ValvesRef {
            kind: target.kind,
            id: target.id.clone(),
            label: target.label.clone(),
        });
        let handle = window.window_handle();
        self._load = Some(
            cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
                let result = call.await;
                let _ = handle.update(cx, |_, window, cx| {
                    let _ = this.update(cx, |s, cx| match result {
                        Ok(doc) => s.adopt(doc, window, cx),
                        Err(e) => {
                            log::warn!("valves.get: {e}");
                            s.failure = Some(cx.l10n().personal_tool_settings_load_failed());
                            cx.notify();
                        }
                    });
                });
            }),
        );
        cx.notify();
    }

    fn adopt(&mut self, doc: ValvesDocument, window: &mut Window, cx: &mut Context<Self>) {
        let edits: Vec<ValveEdit> = doc
            .fields
            .iter()
            .map(|f| ValveEdit {
                key: f.key.clone(),
                is_default: f.is_default,
                text: if f.is_default {
                    f.seed.clone()
                } else {
                    f.text.clone()
                },
            })
            .collect();
        self.initial = edits.clone();
        self.edits = edits;
        let mut inputs = vec![];
        let mut subscriptions = vec![];
        for field in &doc.fields {
            if matches!(
                field.r#type,
                ValveFieldType::Boolean | ValveFieldType::Choice
            ) {
                continue;
            }
            let input = forms::input(field.title.clone(), field.password, window, cx);
            let value = if field.is_default {
                field.seed.clone()
            } else {
                field.text.clone()
            };
            input.update(cx, |s, cx| s.set_value(value, window, cx));
            let key = field.key.clone();
            subscriptions.push(cx.subscribe_in(
                &input,
                window,
                move |this, state, e: &InputEvent, window, cx| match e {
                    InputEvent::Change => {
                        let text = state.read(cx).value().to_string();
                        this.set_text(&key, text, cx);
                    }
                    InputEvent::PressEnter { .. } => this.save(window, cx),
                    _ => {}
                },
            ));
            inputs.push((field.key.clone(), input));
        }
        self.inputs = inputs;
        self._subscriptions = subscriptions;
        self.document = Some(doc);
        cx.notify();
    }

    /// Gives valve `key` its own value `text` (the E2E pass).
    pub fn set_value(&mut self, key: &str, text: &str, cx: &mut Context<Self>) {
        self.set_text(key, text.to_string(), cx);
    }

    fn edit_mut(&mut self, key: &str) -> Option<&mut ValveEdit> {
        self.edits.iter_mut().find(|e| e.key == key)
    }

    fn set_text(&mut self, key: &str, text: String, cx: &mut Context<Self>) {
        if let Some(edit) = self.edit_mut(key) {
            edit.text = text;
            edit.is_default = false;
        }
        self.failure = None;
        cx.notify();
    }

    fn set_default(&mut self, key: &str, is_default: bool, cx: &mut Context<Self>) {
        if let Some(edit) = self.edit_mut(key) {
            edit.is_default = is_default;
        }
        self.failure = None;
        cx.notify();
    }

    pub fn is_dirty(&self) -> bool {
        // A valve at its default whose (unused) text moved is no change.
        self.edits.len() != self.initial.len()
            || self
                .edits
                .iter()
                .zip(&self.initial)
                .any(|(a, b)| a.is_default != b.is_default || (!a.is_default && a.text != b.text))
    }

    fn can_save(&self) -> bool {
        !self.saving
            && self.is_dirty()
            && self
                .document
                .as_ref()
                .is_some_and(|d| d.phase == ValvesPhase::Ready)
    }

    pub fn save(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if !self.can_save() {
            return;
        }
        let Some(target) = self.target().cloned() else {
            return;
        };
        self.saving = true;
        self.failure = None;
        cx.notify();
        let sent = self.edits.clone();
        if let Some(tool_id) = self.tool.clone() {
            let call = self
                .rpc
                .call::<methods::WorkspaceSaveValves>(&WorkspaceValves {
                    tool_id,
                    user: target.id == "user",
                    schema: Default::default(),
                    values: Default::default(),
                    fields: vec![],
                    edits: sent.clone(),
                });
            let handle = window.window_handle();
            cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
                let result = call.await;
                let _ = handle.update(cx, |_, window, cx| {
                    let _ = this.update(cx, |s, cx| {
                        s.saving = false;
                        let l10n = cx.l10n().clone();
                        match result {
                            Ok(valves) => {
                                let text = l10n.desktop_workspace_tool_valves_saved();
                                s.stores
                                    .toasts
                                    .update(cx, |t, cx| t.show(NoticeLevel::Info, text, cx));
                                if s.edits == sent {
                                    let doc = Self::tool_document(&target, valves);
                                    s.adopt(doc, window, cx);
                                    sheet::dismiss(cx);
                                } else {
                                    // Changed again while it saved: the rest
                                    // stays to be saved.
                                    s.initial = sent;
                                }
                            }
                            Err(e) => {
                                log::warn!("workspace.saveValves: {e}");
                                s.failure = Some(match e.args.get("detail") {
                                    Some(detail) => detail.clone(),
                                    None => l10n.desktop_workspace_tool_valves_save_failed(),
                                });
                            }
                        }
                        cx.notify();
                    });
                });
            })
            .detach();
            return;
        }
        let call = self.rpc.call::<methods::ValvesSave>(&ValvesSave {
            kind: target.kind,
            id: target.id,
            label: target.label,
            values: sent.clone(),
        });
        let handle = window.window_handle();
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result = call.await;
            let _ = handle.update(cx, |_, window, cx| {
                let _ = this.update(cx, |s, cx| {
                    s.saving = false;
                    let l10n = cx.l10n().clone();
                    match result {
                        // Answered, but nothing was written (the editor was
                        // not ready, the tool went, the owner changed): the
                        // edits stay, with why.
                        Ok(doc) if doc.phase != ValvesPhase::Ready => {
                            s.failure = Some(match doc.phase {
                                ValvesPhase::OwnerChanged => {
                                    l10n.personal_tool_settings_owner_changed()
                                }
                                ValvesPhase::Unavailable => {
                                    l10n.personal_tool_settings_unavailable()
                                }
                                _ => l10n.personal_tool_settings_save_failed(),
                            });
                        }
                        Ok(doc) => {
                            let text = l10n.personal_tool_settings_saved();
                            s.stores
                                .toasts
                                .update(cx, |t, cx| t.show(NoticeLevel::Info, text, cx));
                            if s.edits == sent {
                                s.adopt(doc, window, cx);
                                sheet::dismiss(cx);
                            } else {
                                // Changed again while it saved: the rest
                                // stays to be saved.
                                s.initial = sent;
                            }
                        }
                        Err(e) => {
                            log::warn!("valves.save: {e}");
                            s.failure = Some(match e.args.get("reason").map(String::as_str) {
                                Some("invalid") => match e.args.get("detail") {
                                    Some(detail) => format!(
                                        "{} {detail}",
                                        l10n.personal_tool_settings_invalid()
                                    ),
                                    None => l10n.personal_tool_settings_invalid(),
                                },
                                Some("ownerChanged") => l10n.personal_tool_settings_owner_changed(),
                                Some("unavailable") => l10n.personal_tool_settings_unavailable(),
                                _ => l10n.personal_tool_settings_save_failed(),
                            });
                        }
                    }
                    cx.notify();
                });
            });
        })
        .detach();
    }

    pub fn on_choice(
        &mut self,
        action: &SettingsChoice,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if action.menu == "valve-target" {
            let Ok(index) = action.value.parse::<usize>() else {
                return;
            };
            if index == self.selected {
                return;
            }
            if !self.is_dirty() {
                self.selected = index;
                self.load(window, cx);
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
            let handle = window.window_handle();
            cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
                if ask.await {
                    let _ = handle.update(cx, |_, window, cx| {
                        let _ = this.update(cx, |s, cx| {
                            s.selected = index;
                            s.load(window, cx);
                        });
                    });
                }
            })
            .detach();
        } else if let Some(key) = action.menu.strip_prefix("valve-mode:") {
            let is_default = action.value == DEFAULT;
            self.set_default(key, is_default, cx);
        } else if let Some(key) = action.menu.strip_prefix("valve-choice:") {
            self.set_text(key, action.value.clone(), cx);
        }
    }

    fn row(
        &self,
        field: &ValveField,
        l10n: &L10n,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let t = cx.conduit().clone();
        let edit = self.edits.iter().find(|e| e.key == field.key);
        let is_default = edit.is_none_or(|e| e.is_default);
        let text = edit.map(|e| e.text.clone()).unwrap_or_default();
        let title = if field.is_required {
            format!("{} ({})", field.title, l10n.desktop_valve_required())
        } else {
            field.title.clone()
        };
        let default_label = if field.has_default {
            l10n.desktop_valve_default()
        } else {
            l10n.desktop_valve_none()
        };
        let mode = controls::popup(
            &format!("valve-mode:{}", field.key),
            &title,
            vec![
                Choice::new(DEFAULT, default_label),
                Choice::new(CUSTOM, l10n.desktop_valve_custom()),
            ],
            if is_default { DEFAULT } else { CUSTOM },
            self.saving,
            window,
            cx,
        );
        let text_field = !matches!(
            field.r#type,
            ValveFieldType::Boolean | ValveFieldType::Choice
        );
        let control: Option<AnyElement> = (!is_default).then(|| match field.r#type {
            ValveFieldType::Boolean => {
                let on = text.trim().eq_ignore_ascii_case("true");
                let key = field.key.clone();
                let view = cx.entity().downgrade();
                Switch::new(
                    ElementId::Name(format!("valve-switch-{}", field.key).into()),
                    field.title.clone(),
                    on,
                )
                .on_click(Rc::new(move |_, _, cx| {
                    let _ = view.update(cx, |v, cx| {
                        v.set_text(&key, if on { "false" } else { "true" }.into(), cx)
                    });
                }))
                .into_any_element()
            }
            ValveFieldType::Choice => controls::popup(
                &format!("valve-choice:{}", field.key),
                &field.title,
                field
                    .options
                    .iter()
                    .map(|o| Choice::new(o.clone(), o.clone()))
                    .collect(),
                &text,
                self.saving,
                window,
                cx,
            )
            .into_any_element(),
            _ => match self.inputs.iter().find(|(k, _)| *k == field.key) {
                Some((_, input)) => div()
                    .w_full()
                    .child(forms::field_hinted(
                        SharedString::default(),
                        input,
                        None,
                        None,
                        None,
                        window,
                        cx,
                    ))
                    .into_any_element(),
                None => div().into_any_element(),
            },
        });
        div()
            .id(ElementId::Name(format!("valve-{}", field.key).into()))
            .w_full()
            .flex()
            .flex_col()
            .child(forms::form_row(title, mode, cx))
            // The control and the help under the pop-up, in the value
            // column (a text field draws its own row there).
            .when_some(control, |d, c| {
                d.child(if text_field {
                    c
                } else {
                    div()
                        .pl(px(VALUE_INSET))
                        .pr(px(12.))
                        .pb(px(8.))
                        .flex()
                        .child(c)
                        .into_any_element()
                })
            })
            .when_some(
                field.description.clone().filter(|d| !d.is_empty()),
                |d, text| {
                    d.child(
                        div()
                            .pl(px(VALUE_INSET))
                            .pr(px(12.))
                            .pb(px(10.))
                            .text_size(px(t.metrics.small))
                            .line_height(relative(1.35))
                            .text_color(t.roles.text_subtle)
                            .child(text),
                    )
                },
            )
            .into_any_element()
    }
}

impl SheetBody for ValvesSheet {
    fn busy(&self, _: &App) -> bool {
        self.saving
    }

    fn unsaved(&self, _: &App) -> bool {
        ValvesSheet::is_dirty(self)
    }

    fn footer(&mut self, _: &mut Window, cx: &mut Context<Self>) -> Option<AnyElement> {
        let l10n = cx.l10n().clone();
        let view = cx.entity().downgrade();
        let cancel_view = view.clone();
        Some(
            forms::form_buttons(vec![
                Button::new("valves-cancel", l10n.cancel())
                    .on_click(Rc::new(move |_, window, cx| {
                        let _ = cancel_view.update(cx, |v, cx| v.cancel(window, cx));
                    }))
                    .into_any_element(),
                Button::new("valves-save", l10n.save())
                    .primary()
                    .disabled(!self.can_save())
                    .on_click(Rc::new(move |_, window, cx| {
                        let _ = view.update(cx, |v, cx| v.save(window, cx));
                    }))
                    .into_any_element(),
            ])
            .into_any_element(),
        )
    }

    fn cancel(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.saving {
            return;
        }
        if !self.is_dirty() {
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
        if self.tool.is_some() {
            cx.l10n().desktop_workspace_tool_valves_title().into()
        } else {
            cx.l10n().personal_tool_settings().into()
        }
    }
}

impl Render for ValvesSheet {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let l10n = cx.l10n().clone();
        let t = cx.conduit().clone();
        let mut body: Vec<AnyElement> = vec![
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
                        .child(if self.tool.is_some() {
                            l10n.desktop_workspace_tool_valves_title()
                        } else {
                            l10n.personal_tool_settings()
                        }),
                )
                .when_some(
                    match &self.tool {
                        // A tool's own valves say whose they are; the
                        // server's need no note.
                        Some(_) => self
                            .target()
                            .filter(|t| t.id == "user")
                            .map(|_| l10n.desktop_workspace_valves_user_hint()),
                        None => Some(l10n.personal_tool_settings_description()),
                    },
                    |d, text| {
                        d.child(
                            div()
                                .text_size(px(t.metrics.small + 0.5))
                                .line_height(relative(1.4))
                                .text_color(t.roles.text_subtle)
                                .child(text),
                        )
                    },
                )
                .into_any_element(),
        ];
        if self.targets.len() > 1 {
            let choices = self
                .targets
                .iter()
                .enumerate()
                .map(|(i, target)| Choice::new(i.to_string(), target.label.clone()))
                .collect();
            let picker = controls::popup(
                "valve-target",
                &l10n.desktop_tool_settings_for(),
                choices,
                &self.selected.to_string(),
                self.saving,
                window,
                cx,
            );
            body.push(
                grouped_section(
                    None,
                    vec![
                        forms::form_row(l10n.desktop_tool_settings_for(), picker, cx)
                            .into_any_element(),
                    ],
                    None,
                    cx,
                )
                .into_any_element(),
            );
        }
        match self.document.clone() {
            None => body.push(
                div()
                    .px(px(4.))
                    .text_color(t.roles.text_subtle)
                    .child(l10n.desktop_loading())
                    .into_any_element(),
            ),
            Some(doc) if doc.phase != ValvesPhase::Ready => body.push(
                div()
                    .px(px(4.))
                    .text_color(t.roles.text_subtle)
                    .child(match doc.phase {
                        ValvesPhase::OwnerChanged => l10n.personal_tool_settings_owner_changed(),
                        ValvesPhase::LoadFailed => l10n.personal_tool_settings_load_failed(),
                        _ => l10n.personal_tool_settings_unavailable(),
                    })
                    .into_any_element(),
            ),
            Some(doc) => {
                let rows = doc
                    .fields
                    .iter()
                    .map(|f| self.row(f, &l10n, window, cx))
                    .collect();
                let title = self.target().map(|t| SharedString::from(t.label.clone()));
                body.push(grouped_section(title, rows, None, cx).into_any_element());
            }
        }
        if let Some(failure) = &self.failure {
            body.push(forms::form_error("valves-failure", failure.clone(), cx).into_any_element());
        }
        div()
            .id("tool-settings")
            .w_full()
            .flex()
            .flex_col()
            .gap(px(16.))
            .on_action(
                cx.listener(|this, a: &SettingsChoice, window, cx| this.on_choice(a, window, cx)),
            )
            .children(body)
    }
}

#[cfg(test)]
mod tests {
    use conduit_protocol::ValveTargetKind;
    use gpui_kit::VisualTestContext;

    use super::*;
    use crate::views::sheet::bench::{bench, switch_account};

    fn doc(phase: &str) -> ValvesDocument {
        serde_json::from_value(serde_json::json!({
            "kind": "tool", "id": "weather", "label": "Weather", "phase": phase,
            "fields": [{"key": "units", "title": "Units", "type": "text",
                        "isDefault": false, "text": "metric"}]
        }))
        .unwrap()
    }

    fn open(stores: &Stores, vcx: &mut VisualTestContext) -> Entity<ValvesSheet> {
        let stores = stores.clone();
        let target = ValveTarget {
            kind: ValveTargetKind::Tool,
            id: "weather".into(),
            label: "Weather".into(),
        };
        let sheet = vcx
            .update(|window, cx| {
                sheet::open(window, WIDTH, cx, move |w, cx| {
                    ValvesSheet::new(stores, vec![target], w, cx)
                })
            })
            .unwrap();
        vcx.run_until_parked();
        sheet
    }

    fn typed(sheet: &Entity<ValvesSheet>, text: &str, vcx: &mut VisualTestContext) {
        sheet.update(vcx, |s, cx| s.set_text("units", text.into(), cx));
    }

    #[gpui_kit::test]
    fn another_account_never_gets_these_settings(cx: &mut gpui_kit::TestAppContext) {
        let (daemon, stores, vcx) = bench(cx);
        daemon.returns::<methods::ValvesGet>(doc("ready"));
        let sheet = open(&stores, vcx);
        typed(&sheet, "imperial", vcx);
        switch_account(&stores, vcx);
        assert!(
            vcx.update(|_, cx| sheet::current::<ValvesSheet>(cx))
                .is_none(),
            "Avery's sheet stayed open over Blake's account"
        );
        assert!(daemon.calls::<methods::ValvesSave>().is_empty());
    }

    #[gpui_kit::test]
    fn quit_asks_before_throwing_edits_away(cx: &mut gpui_kit::TestAppContext) {
        let (daemon, stores, vcx) = bench(cx);
        daemon.returns::<methods::ValvesGet>(doc("ready"));
        let _sheet = open(&stores, vcx);
        typed(&_sheet, "imperial", vcx);
        vcx.update(|_, cx| sheet::quit(cx));
        vcx.run_until_parked();
        // Asked (the bench answers keep editing): still there, not quitting.
        assert!(
            vcx.update(|_, cx| sheet::current::<ValvesSheet>(cx))
                .is_some(),
            "Quit closed a sheet with unsaved edits"
        );
    }

    #[gpui_kit::test]
    fn a_save_that_wrote_nothing_keeps_the_edits(cx: &mut gpui_kit::TestAppContext) {
        let (daemon, stores, vcx) = bench(cx);
        daemon.returns::<methods::ValvesGet>(doc("ready"));
        daemon.returns::<methods::ValvesSave>(doc("ownerChanged"));
        let sheet = open(&stores, vcx);
        typed(&sheet, "imperial", vcx);
        vcx.update(|window, cx| sheet.update(cx, |s, cx| s.save(window, cx)));
        vcx.run_until_parked();
        assert!(
            vcx.update(|_, cx| sheet::current::<ValvesSheet>(cx))
                .is_some()
        );
        sheet.read_with(vcx, |s, cx| {
            assert_eq!(
                s.failure,
                Some(cx.l10n().personal_tool_settings_owner_changed())
            );
            assert_eq!(s.edits[0].text, "imperial");
        });
    }

    #[gpui_kit::test]
    fn edits_made_while_saving_stay_to_be_saved(cx: &mut gpui_kit::TestAppContext) {
        let (daemon, stores, vcx) = bench(cx);
        daemon.returns::<methods::ValvesGet>(doc("ready"));
        let mut saved = doc("ready");
        saved.fields[0].text = "imperial".into();
        daemon.returns::<methods::ValvesSave>(saved);
        let sheet = open(&stores, vcx);
        typed(&sheet, "imperial", vcx);
        let held = daemon.hold::<methods::ValvesSave>();
        vcx.update(|window, cx| sheet.update(cx, |s, cx| s.save(window, cx)));
        vcx.run_until_parked();
        typed(&sheet, "kelvin", vcx);
        drop(held);
        vcx.run_until_parked();
        assert!(
            vcx.update(|_, cx| sheet::current::<ValvesSheet>(cx))
                .is_some(),
            "closed with the later edit unsaved"
        );
        sheet.read_with(vcx, |s, _| {
            assert_eq!(s.edits[0].text, "kelvin");
            assert!(s.is_dirty());
        });
    }
}
