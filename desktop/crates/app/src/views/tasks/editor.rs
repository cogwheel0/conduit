//! The task editor, a sheet on the main window: New Scheduled Task or Edit
//! Scheduled Task, with the phone's fields. Name and Active; the
//! instructions; the server terminal it runs with, its working folder and
//! the model (a coding agent of that terminal among them, Open WebUI 0.13.3
//! and later); the schedule (Once, Daily or Weekly with native date and time
//! pickers, or a recurrence rule under Advanced Schedule); and where results
//! go (a new chat, optionally in a folder, or a channel).
//!
//! The daemon holds the draft (`automations.editor`), keeps whatever the
//! task stores that the editor does not show (unknown keys) and settles each
//! change (`automations.checkDraft`): a typed rule the controls can write
//! reads back as their kind, and the controls carry their rule. Another
//! terminal drops the old one's folder and agent; `automations.terminals`
//! lists the models again with the terminal's agents.

use std::rc::Rc;

use conduit_components::ActiveConduitTheme as _;
use conduit_components::announce::{Priority, live_text};
use conduit_components::assets::{IconName, icon};
use conduit_components::views::focus::{ControlExt as _, Ring};
use conduit_components::views::kit::{
    Button, Segment, Segmented, Switch, field_fill, field_fill_hover,
};
use conduit_protocol::{
    AutomationDraftEdit, AutomationDraftState, AutomationEditor, AutomationEditorOpen,
    AutomationFields, AutomationTerminals, methods,
};
use gpui_kit::component::input::{InputEvent, InputState, Textarea, TextareaState};
use gpui_kit::prelude::*;
use gpui_kit::{
    AnyElement, App, AsyncApp, Context, ElementId, Entity, FocusHandle, FontWeight, MouseButton,
    Role, SharedString, Subscription, Task, Toggled, WeakEntity, Window, div, px, relative,
};

use super::{error_text, failure_text, schedule_summary, weekday_codes, weekday_label};
use crate::actions::SettingsChoice;
use crate::l10n::{ActiveL10n as _, L10n};
use crate::shell::date_picker::{PickerMode, PickerSpec, WallClock, pick};
use crate::shell::sheet::{SheetSpec, present_sheet};
use crate::stores::Stores;
use crate::views::forms;
use crate::views::settings::controls::{self, Choice};
use crate::views::sheet::{self, SheetBody};

/// The sheet's width.
pub const WIDTH: f32 = 560.;

/// An example rule shown in the empty rule field (the phone's).
const RRULE_EXAMPLE: &str = "RRULE:FREQ=WEEKLY;BYDAY=MO,WE,FR;BYHOUR=9;BYMINUTE=0";
const KINDS: [&str; 3] = ["once", "daily", "weekly"];

/// Opens the editor for `id`, or a new task, on the main window.
pub fn open(stores: Stores, id: Option<String>, window: &mut Window, cx: &mut App) {
    sheet::open(window, WIDTH, cx, move |w, cx| {
        TaskEditor::new(stores, id, w, cx)
    });
}

/// What an issue says, in the phone's words.
pub fn issue_text(issue: &str, l: &L10n) -> String {
    match issue {
        "nameRequired" => l.scheduled_task_name_required(),
        "promptRequired" => l.scheduled_task_prompt_required(),
        "modelRequired" => l.scheduled_task_model_required(),
        "modelUnavailable" => l.scheduled_task_model_unavailable_issue(),
        "channelRequired" => l.scheduled_task_channel_required(),
        "channelUnavailable" => l.scheduled_task_channel_unavailable_issue(),
        "channelNoWrite" => l.scheduled_task_channel_no_write(),
        "folderUnavailable" => l.scheduled_task_folder_unavailable_issue(),
        "terminalRequired" => l.scheduled_task_terminal_required(),
        "agentNeedsChat" => l.scheduled_task_agent_needs_chat(),
        _ => l.scheduled_task_schedule_incomplete(),
    }
}

pub struct TaskEditor {
    stores: Stores,
    focus: FocusHandle,
    pub editor: Option<AutomationEditor>,
    pub fields: Option<AutomationFields>,
    pub issues: Vec<String>,
    pub attempted: bool,
    pub changed: bool,
    pub saving: bool,
    pub failure: Option<String>,
    /// Advanced Schedule is open.
    pub advanced: bool,
    name: Entity<InputState>,
    prompt: Entity<TextareaState>,
    rrule: Entity<TextareaState>,
    /// The working folder on the task's terminal.
    cwd: Entity<InputState>,
    /// The folder the field shows next, once a terminal change dropped it.
    cwd_pending: Option<String>,
    /// `automations.terminals` is asking the terminal for its agents.
    pub agents_loading: bool,
    terminals_call: Option<Task<()>>,
    /// The rule field is being typed in: its text is the user's.
    typing_rule: bool,
    /// A schedule kind chosen (Once, Daily, Weekly) whose check has not
    /// answered yet: every check until then carries it, so a check started
    /// for something else (another field, the terminal's agents) never drops
    /// the choice. A newer edit of the schedule itself (a rule typed, a
    /// schedule control) replaces it.
    pending_kind: Option<String>,
    /// The rule the field shows next, once the controls changed it.
    rrule_pending: Option<String>,
    check: Option<Task<()>>,
    _subscriptions: Vec<Subscription>,
}

impl TaskEditor {
    pub fn new(
        stores: Stores,
        id: Option<String>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Self {
        let l = cx.l10n().clone();
        let name = forms::input(l.scheduled_task_name_label(), false, window, cx);
        let prompt = cx.new(|cx| {
            TextareaState::new(window, cx)
                .auto_grow(4, 12)
                .placeholder(l.scheduled_task_prompt_hint())
        });
        let rrule = cx.new(|cx| {
            TextareaState::new(window, cx)
                .auto_grow(2, 4)
                .placeholder(RRULE_EXAMPLE)
        });
        let cwd = forms::input(l.scheduled_task_working_folder_hint(), false, window, cx);
        let mut subscriptions = vec![
            cx.subscribe_in(
                &cwd,
                window,
                |this, state, e: &InputEvent, window, cx| match e {
                    InputEvent::Change => {
                        let value = state.read(cx).value().trim().to_string();
                        let value = (!value.is_empty()).then_some(value);
                        if this.fields.as_ref().map(|f| &f.working_directory) == Some(&value) {
                            return;
                        }
                        this.edit(|f| f.working_directory = value, cx);
                        // The terminal is asked for its agents in that folder
                        // once the typing pauses.
                        this.refresh_terminals(Some(std::time::Duration::from_millis(600)), cx);
                    }
                    InputEvent::PressEnter { .. } => this.save(window, cx),
                    _ => {}
                },
            ),
            cx.subscribe_in(
                &name,
                window,
                |this, state, e: &InputEvent, window, cx| match e {
                    InputEvent::Change => {
                        let value = state.read(cx).value().to_string();
                        this.edit(|f| f.name = value, cx);
                    }
                    InputEvent::PressEnter { .. } => this.save(window, cx),
                    _ => {}
                },
            ),
            cx.subscribe_in(&prompt, window, |this, state, e: &InputEvent, _, cx| {
                if matches!(e, InputEvent::Change) {
                    let value = state.read(cx).value().to_string();
                    this.edit(|f| f.prompt = value, cx);
                }
            }),
            cx.subscribe_in(&rrule, window, |this, state, e: &InputEvent, _, cx| {
                if matches!(e, InputEvent::Change) {
                    let value = state.read(cx).value().to_string();
                    this.type_rule(value, cx);
                }
            }),
        ];
        // The task is saved for the account it opened under, never the next.
        subscriptions.push(sheet::close_with_account(&stores, cx));
        let mut this = Self {
            stores,
            focus: cx.focus_handle(),
            editor: None,
            fields: None,
            issues: vec![],
            attempted: false,
            changed: false,
            saving: false,
            failure: None,
            advanced: false,
            name,
            prompt,
            rrule,
            cwd,
            cwd_pending: None,
            agents_loading: false,
            terminals_call: None,
            typing_rule: false,
            pending_kind: None,
            rrule_pending: None,
            check: None,
            _subscriptions: subscriptions,
        };
        this.load(id, window, cx);
        this
    }

    fn rpc(&self, cx: &App) -> crate::stores::rpc::Rpc {
        self.stores.connection.read(cx).rpc()
    }

    fn load(&mut self, id: Option<String>, window: &mut Window, cx: &mut Context<Self>) {
        let call = self
            .rpc(cx)
            .call::<methods::AutomationsEditor>(&AutomationEditorOpen { id });
        let handle = window.window_handle();
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result = call.await;
            let _ = handle.update(cx, |_, window, cx| {
                let _ = this.update(cx, |s, cx| {
                    match result {
                        Ok(editor) => s.adopt(editor, window, cx),
                        Err(e) => {
                            log::warn!("automations.editor: {e}");
                            let l = cx.l10n().clone();
                            s.failure = Some(error_text(&e, l.scheduled_tasks_load_failed(), &l));
                        }
                    }
                    cx.notify();
                });
            });
        })
        .detach();
    }

    fn adopt(&mut self, editor: AutomationEditor, window: &mut Window, cx: &mut Context<Self>) {
        let f = editor.fields.clone();
        self.name
            .update(cx, |s, cx| s.set_value(f.name.clone(), window, cx));
        self.prompt
            .update(cx, |s, cx| s.set_value(f.prompt.clone(), window, cx));
        self.rrule.update(cx, |s, cx| {
            s.set_value(f.schedule.rrule.clone(), window, cx)
        });
        let folder = f.working_directory.clone().unwrap_or_default();
        self.cwd.update(cx, |s, cx| s.set_value(folder, window, cx));
        // A rule the controls cannot write opens where it can be read.
        self.advanced = f.schedule.kind == "custom";
        self.fields = Some(f);
        self.editor = Some(editor);
        self.typing_rule = false;
        self.check_now(None, cx);
        let name = self.name.clone();
        name.update(cx, |s, cx| s.focus(window, cx));
    }

    /// Types the name and instructions, as the user would (E2E).
    pub fn type_text(
        &mut self,
        name: &str,
        prompt: &str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let (name, prompt) = (name.to_string(), prompt.to_string());
        self.name
            .update(cx, |s, cx| s.set_value(name.clone(), window, cx));
        self.prompt
            .update(cx, |s, cx| s.set_value(prompt.clone(), window, cx));
        self.edit(
            |f| {
                f.name = name;
                f.prompt = prompt;
            },
            cx,
        );
    }

    /// Types the working folder, as the user would (E2E). Setting the
    /// field's value raises no change, so the draft follows here.
    pub fn type_folder(&mut self, folder: &str, window: &mut Window, cx: &mut Context<Self>) {
        let value = folder.to_string();
        self.cwd
            .update(cx, |s, cx| s.set_value(value.clone(), window, cx));
        self.edit(|f| f.working_directory = Some(value), cx);
        self.refresh_terminals(None, cx);
    }

    /// Changes the fields, then has the daemon settle them.
    pub fn edit(&mut self, change: impl FnOnce(&mut AutomationFields), cx: &mut Context<Self>) {
        let Some(fields) = self.fields.as_mut() else {
            return;
        };
        change(fields);
        self.failure = None;
        cx.notify();
        self.check_now(None, cx);
    }

    /// The schedule's controls changed: the rule follows them, and a kind
    /// chosen before (still unanswered) gives way to this newer edit.
    fn edit_schedule(
        &mut self,
        change: impl FnOnce(&mut AutomationFields),
        cx: &mut Context<Self>,
    ) {
        self.typing_rule = false;
        self.pending_kind = None;
        self.edit(change, cx);
    }

    /// Typed into the rule field: it is read as the controls' kind when they
    /// can write it.
    pub fn type_rule(&mut self, rule: String, cx: &mut Context<Self>) {
        let Some(fields) = self.fields.as_mut() else {
            return;
        };
        if fields.schedule.rrule == rule {
            return;
        }
        self.typing_rule = true;
        // A settled check's rule, not yet in the field, gives way to this,
        // and so does a kind chosen before whose check has not answered.
        self.rrule_pending = None;
        self.pending_kind = None;
        fields.schedule.kind = "custom".into();
        fields.schedule.rrule = rule;
        cx.notify();
        self.check_now(None, cx);
    }

    /// Once, Daily or Weekly, starting from the current schedule's time.
    pub fn choose_kind(&mut self, kind: &str, cx: &mut Context<Self>) {
        self.typing_rule = false;
        self.check_now(Some(kind.to_string()), cx);
    }

    fn check_now(&mut self, choose_kind: Option<String>, cx: &mut Context<Self>) {
        let (Some(editor), Some(fields)) = (self.editor.as_ref(), self.fields.clone()) else {
            return;
        };
        let choose_kind = choose_kind.or_else(|| self.pending_kind.clone());
        self.pending_kind = choose_kind.clone();
        let call = self
            .rpc(cx)
            .call::<methods::AutomationsCheckDraft>(&AutomationDraftEdit {
                token: editor.token.clone(),
                fields,
                choose_kind,
            });
        self.check = Some(
            cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
                let result = call.await;
                let _ = this.update(cx, |s, cx| {
                    match result {
                        Ok(state) => {
                            // The choice is in the schedule now.
                            s.pending_kind = None;
                            s.take_state(state, cx)
                        }
                        Err(e) => {
                            // Not taken: a later check does not carry it.
                            s.pending_kind = None;
                            log::warn!("automations.checkDraft: {e}")
                        }
                    }
                    cx.notify();
                });
            }),
        );
    }

    fn take_state(&mut self, state: AutomationDraftState, _cx: &mut Context<Self>) {
        self.issues = state.issues;
        self.changed = state.changed;
        let Some(fields) = self.fields.as_mut() else {
            return;
        };
        // The folder and the model stay as the fields have them: a terminal
        // change dropped the old terminal's in the edit itself
        // ([`moved_to_terminal`]), so an answer (to that edit or a later one)
        // never puts them back or takes a folder typed since.
        let typed = std::mem::replace(&mut fields.schedule, state.fields.schedule);
        if self.typing_rule {
            // What the user typed stays as typed.
            fields.schedule.rrule = typed.rrule;
        } else {
            // The rule field follows the controls (set at the next frame,
            // where a window is at hand).
            self.rrule_pending = Some(fields.schedule.rrule.clone());
        }
    }

    pub fn on_choice(&mut self, a: &SettingsChoice, cx: &mut Context<Self>) {
        let value = a.value.clone();
        match a.menu.as_str() {
            "task-model" => self.edit(|f| f.model_id = value, cx),
            "task-terminal" => {
                let id = (!value.is_empty()).then_some(value);
                if self.fields.as_ref().map(|f| &f.terminal_id) == Some(&id) {
                    return;
                }
                self.edit(|f| moved_to_terminal(f, id), cx);
                self.cwd_pending = Some(String::new());
                self.refresh_terminals(None, cx);
            }
            "task-channel" => self.edit(|f| f.channel_id = Some(value), cx),
            "task-folder" => self.edit(|f| f.folder_id = (!value.is_empty()).then_some(value), cx),
            _ => {}
        }
    }

    /// `automations.terminals`: the terminals, and the models with the
    /// chosen terminal's coding agents in its working folder, after `delay`
    /// (typing in the folder field).
    pub fn refresh_terminals(
        &mut self,
        delay: Option<std::time::Duration>,
        cx: &mut Context<Self>,
    ) {
        let (Some(editor), Some(fields)) = (self.editor.as_ref(), self.fields.clone()) else {
            return;
        };
        let rpc = self.rpc(cx);
        let token = editor.token.clone();
        self.agents_loading = true;
        cx.notify();
        self.terminals_call = Some(cx.spawn(
            async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
                if let Some(delay) = delay {
                    cx.background_executor().timer(delay).await;
                }
                let result = rpc
                    .call::<methods::AutomationsTerminals>(&AutomationDraftEdit {
                        token,
                        fields,
                        choose_kind: None,
                    })
                    .await;
                let _ = this.update(cx, |s, cx| {
                    s.agents_loading = false;
                    match result {
                        Ok(found) => s.take_terminals(found),
                        Err(e) => log::warn!("automations.terminals: {e}"),
                    }
                    cx.notify();
                    // Whether the agent is still offered moved too.
                    s.check_now(None, cx);
                });
            },
        ));
    }

    fn take_terminals(&mut self, found: AutomationTerminals) {
        if let Some(editor) = self.editor.as_mut() {
            editor.terminals = found.terminals;
            editor.models = found.models;
            editor.agents_unknown = found.agents_unknown;
        }
    }

    pub fn set_target(&mut self, channel: bool, cx: &mut Context<Self>) {
        self.edit(
            |f| {
                let next = if channel { "channel" } else { "chat" };
                if f.target != next {
                    f.target = next.into();
                    f.channel_id = None;
                    if channel {
                        f.folder_id = None;
                    }
                }
            },
            cx,
        );
    }

    pub fn toggle_day(&mut self, code: &str, cx: &mut Context<Self>) {
        let code = code.to_string();
        self.edit_schedule(
            |f| {
                if let Some(i) = f.schedule.days.iter().position(|d| *d == code) {
                    f.schedule.days.remove(i);
                } else {
                    f.schedule.days.push(code);
                }
            },
            cx,
        );
    }

    fn pick(&mut self, mode: PickerMode, window: &mut Window, cx: &mut Context<Self>) {
        let Some(fields) = self.fields.as_ref() else {
            return;
        };
        let l = cx.l10n().clone();
        let s = &fields.schedule;
        let today = crate::shell::date_picker::wall_of(chrono::Local::now().timestamp())
            .unwrap_or_default();
        let value = WallClock {
            year: if s.year > 0 {
                s.year as i32
            } else {
                today.year
            },
            month: if s.month > 0 {
                s.month as u32
            } else {
                today.month
            },
            day: if s.day > 0 { s.day as u32 } else { today.day },
            hour: s.hour.clamp(0, 23) as u32,
            minute: s.minute.clamp(0, 59) as u32,
        };
        let asked = pick(
            window,
            PickerSpec {
                title: if mode == PickerMode::Date {
                    l.scheduled_task_date_label()
                } else {
                    l.scheduled_task_time_label()
                },
                mode,
                value,
                ok: l.done(),
                cancel: l.cancel(),
            },
            cx,
        );
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let Some(picked) = asked.await else {
                return;
            };
            let _ = this.update(cx, |s, cx| s.set_clock(mode, picked, cx));
        })
        .detach();
    }

    /// Sets the schedule's day (Once) or time of day.
    pub fn set_clock(&mut self, mode: PickerMode, picked: WallClock, cx: &mut Context<Self>) {
        self.edit_schedule(
            |f| match mode {
                PickerMode::Date => {
                    f.schedule.year = picked.year.into();
                    f.schedule.month = picked.month.into();
                    f.schedule.day = picked.day.into();
                }
                PickerMode::Time => {
                    f.schedule.hour = picked.hour.into();
                    f.schedule.minute = picked.minute.into();
                }
            },
            cx,
        );
    }

    pub fn save(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.saving {
            return;
        }
        let (Some(editor), Some(fields)) = (self.editor.as_ref(), self.fields.clone()) else {
            return;
        };
        self.saving = true;
        self.failure = None;
        cx.notify();
        let sent = fields.clone();
        let call = self
            .rpc(cx)
            .call::<methods::AutomationsSave>(&AutomationDraftEdit {
                token: editor.token.clone(),
                fields,
                choose_kind: None,
            });
        let _ = window;
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result = call.await;
            let _ = this.update(cx, |s, cx| {
                s.saving = false;
                let l = cx.l10n().clone();
                match result {
                    Ok(state) if state.saved => {
                        let id = state.id.clone();
                        s.stores.tasks.update(cx, |t, cx| {
                            t.refresh(cx);
                            if let Some(id) = id {
                                t.select(None, cx);
                                t.select(Some(id), cx);
                            }
                        });
                        if s.fields.as_ref() == Some(&sent) {
                            sheet::dismiss(cx);
                        } else {
                            // Typed while the save was out: it stays, to save
                            // next to the task just saved (the daemon's editor
                            // now edits that task).
                            if let Some(e) = s.editor.as_mut() {
                                e.is_new = false;
                                e.fields = sent;
                            }
                            s.check_now(None, cx);
                        }
                    }
                    Ok(state) => {
                        s.attempted = true;
                        if state.issues.iter().any(|i| i == "scheduleIncomplete")
                            && s.fields
                                .as_ref()
                                .is_some_and(|f| f.schedule.kind == "custom")
                        {
                            s.advanced = true;
                        }
                        s.issues = state.issues;
                        s.failure = state
                            .failure
                            .map(|f| failure_text(&f, l.scheduled_task_save_failed(), &l));
                    }
                    Err(e) => {
                        log::warn!("automations.save: {e}");
                        s.failure = Some(error_text(&e, l.scheduled_task_save_failed(), &l));
                    }
                }
                cx.notify();
            });
        })
        .detach();
    }

    fn issue(&self, issue: &str) -> bool {
        self.attempted && self.issues.iter().any(|i| i == issue)
    }

    fn issue_line(&self, issues: &[&str], l: &L10n, cx: &App) -> Option<AnyElement> {
        let found = issues.iter().find(|i| self.issue(i))?;
        Some(
            div()
                .id(SharedString::from(format!("task-issue-{found}")))
                .role(Role::Alert)
                .px(px(12.))
                .text_size(px(cx.conduit().metrics.small))
                .text_color(cx.conduit().roles.danger)
                .child(SharedString::from(issue_text(found, l)))
                .child(live_text(
                    "live",
                    Some(issue_text(found, l).into()),
                    Priority::High,
                ))
                .into_any_element(),
        )
    }

    // ── Drawing ────────────────────────────────────────────────────────

    fn picker_button(
        &self,
        id: &'static str,
        label: String,
        text: String,
        mode: PickerMode,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let t = cx.conduit().clone();
        let r = t.roles;
        let view = cx.entity().downgrade();
        div()
            .id(id)
            .role(Role::Button)
            .aria_label(SharedString::from(format!("{label}: {text}")))
            .h(px(t.metrics.control_height - 2.))
            .px(px(10.))
            .flex()
            .flex_none()
            .items_center()
            .gap(px(6.))
            .rounded(t.control_radius())
            .border_1()
            .border_color(r.border_strong)
            .bg(field_fill(&t))
            .hover(|s| s.bg(field_fill_hover(&t)))
            .cursor_pointer()
            .text_size(px(t.metrics.control))
            .child(SharedString::from(text))
            .child(icon(
                if mode == PickerMode::Date {
                    IconName::Calendar
                } else {
                    IconName::Clock
                },
                12.,
                r.text_subtle,
            ))
            .tip(label, None)
            .on_click(move |_, window, cx| {
                let _ = view.update(cx, |s, cx| s.pick(mode, window, cx));
            })
            .keyboard_control(Ring::Outset(f32::from(t.control_radius())), window, cx)
            .into_any_element()
    }

    fn schedule_rows(
        &self,
        fields: &AutomationFields,
        l: &L10n,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Vec<AnyElement> {
        let t = cx.conduit().clone();
        let r = t.roles;
        let view = cx.entity().downgrade();
        let s = &fields.schedule;
        let mut rows = vec![];
        let kind_view = view.clone();
        let selected = KINDS
            .iter()
            .position(|k| *k == s.kind)
            .unwrap_or(KINDS.len());
        rows.push(
            div()
                .p(px(10.))
                .child(
                    Segmented::new(
                        "task-kind",
                        l.scheduled_task_schedule_label(),
                        vec![
                            Segment::new(l.scheduled_task_schedule_once()),
                            Segment::new(l.scheduled_task_schedule_daily()),
                            Segment::new(l.scheduled_task_schedule_weekly()),
                        ],
                        selected,
                    )
                    .on_select(Rc::new(move |i, _, cx| {
                        let _ = kind_view.update(cx, |e, cx| e.choose_kind(KINDS[i], cx));
                    })),
                )
                .into_any_element(),
        );
        let clock =
            |s: &conduit_protocol::AutomationScheduleDto| conduit_protocol::CalendarWallTime {
                year: if s.year > 0 { s.year } else { 2024 },
                month: if s.month > 0 { s.month } else { 1 },
                day: if s.day > 0 { s.day } else { 1 },
                hour: s.hour,
                minute: s.minute,
            };
        match s.kind.as_str() {
            "custom" => {
                rows.push(
                    div()
                        .id("task-raw-summary")
                        .px(px(12.))
                        .py(px(10.))
                        .flex()
                        .flex_col()
                        .gap(px(2.))
                        .child(
                            div()
                                .text_size(px(t.metrics.control))
                                .child(SharedString::from(schedule_summary(s, l))),
                        )
                        .child(
                            div()
                                .text_size(px(t.metrics.small))
                                .line_height(relative(1.35))
                                .text_color(r.text_subtle)
                                .child(SharedString::from(l.scheduled_task_rrule_kept())),
                        )
                        .into_any_element(),
                );
            }
            kind => {
                let wall = clock(s);
                if kind == "once" {
                    rows.push(
                        forms::form_row(
                            l.scheduled_task_date_label(),
                            self.picker_button(
                                "task-date",
                                l.scheduled_task_date_label(),
                                crate::views::calendar::format::full_day(&wall, l),
                                PickerMode::Date,
                                window,
                                cx,
                            ),
                            cx,
                        )
                        .into_any_element(),
                    );
                }
                rows.push(
                    forms::form_row(
                        l.scheduled_task_time_label(),
                        self.picker_button(
                            "task-time",
                            l.scheduled_task_time_label(),
                            crate::views::calendar::format::time(&wall, l),
                            PickerMode::Time,
                            window,
                            cx,
                        ),
                        cx,
                    )
                    .into_any_element(),
                );
                if kind == "weekly" {
                    let days = weekday_codes().into_iter().enumerate().map(|(i, code)| {
                        let on = s.days.iter().any(|d| d.as_str() == code);
                        let day_view = view.clone();
                        let label = weekday_label(code, l);
                        div()
                            .id(ElementId::NamedInteger("task-day".into(), i as u64))
                            .role(Role::CheckBox)
                            .aria_label(SharedString::from(label.clone()))
                            .aria_toggled(if on { Toggled::True } else { Toggled::False })
                            .min_w(px(40.))
                            .h(px(26.))
                            .px(px(6.))
                            .flex()
                            .items_center()
                            .justify_center()
                            .rounded(px(13.))
                            .cursor_pointer()
                            .text_size(px(t.metrics.small))
                            .when(on, |d| d.bg(r.checked).text_color(r.checked_foreground))
                            .when(!on, |d| {
                                d.border_1()
                                    .border_color(r.border_strong)
                                    .hover(|s| s.bg(r.overlay_hover))
                            })
                            .child(SharedString::from(label))
                            .on_click(move |_, _, cx| {
                                let code = code.to_string();
                                let _ = day_view.update(cx, |e, cx| e.toggle_day(&code, cx));
                            })
                            .keyboard_control(Ring::Outset(13.), window, cx)
                    });
                    rows.push(
                        forms::form_row(
                            l.scheduled_task_days_label(),
                            div().flex().flex_wrap().gap(px(5.)).children(days),
                            cx,
                        )
                        .into_any_element(),
                    );
                }
            }
        }
        rows
    }

    fn advanced_section(
        &self,
        fields: &AutomationFields,
        l: &L10n,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let t = cx.conduit().clone();
        let r = t.roles;
        let view = cx.entity().downgrade();
        let open = self.advanced;
        let runs = if fields.schedule.kind == "custom" {
            l.scheduled_task_schedule_custom()
        } else {
            schedule_summary(&fields.schedule, l)
        };
        div()
            .flex()
            .flex_col()
            .gap(px(6.))
            .child(
                div()
                    .id("task-advanced")
                    .debug_selector(|| "task-advanced".into())
                    // Tab reaches it with Full Keyboard Access, as the
                    // editor's other controls.
                    .keyboard_control(Ring::Outset(6.), window, cx)
                    .role(Role::Button)
                    .aria_label(SharedString::from(l.scheduled_task_advanced_schedule()))
                    .aria_expanded(open)
                    .px(px(8.))
                    .py(px(4.))
                    .flex()
                    .items_center()
                    .gap(px(6.))
                    .cursor_pointer()
                    .rounded(px(6.))
                    .hover(|s| s.bg(r.overlay_hover))
                    .text_size(px(t.metrics.control))
                    .child(icon(
                        if open {
                            IconName::ChevronDown
                        } else {
                            IconName::ChevronRight
                        },
                        12.,
                        r.text_subtle,
                    ))
                    .child(SharedString::from(l.scheduled_task_advanced_schedule()))
                    .on_click(move |_, _, cx| {
                        let _ = view.update(cx, |e, cx| {
                            e.advanced = !e.advanced;
                            cx.notify();
                        });
                    }),
            )
            .when(open, |d| {
                d.child(forms::form_group(
                    vec![
                        div()
                            .p(px(10.))
                            .flex()
                            .flex_col()
                            .gap(px(6.))
                            .child(
                                div()
                                    .text_size(px(t.metrics.small))
                                    .text_color(r.text_subtle)
                                    .child(SharedString::from(l.scheduled_task_rrule_label())),
                            )
                            .child(
                                div()
                                    .font_family(conduit_components::theme::MONO_FONT)
                                    .child(Textarea::new(&self.rrule)),
                            )
                            .child(
                                div()
                                    .id("task-rrule-runs")
                                    .text_size(px(t.metrics.small))
                                    .text_color(r.text_subtle)
                                    .child(SharedString::from(l.scheduled_task_rrule_runs(&runs))),
                            )
                            .into_any_element(),
                    ],
                    cx,
                ))
            })
            .into_any_element()
    }

    /// The terminal (when the server has one for tasks, or the task has
    /// one), its working folder, and the model, as mobile's editor lays them
    /// out.
    fn model_rows(
        &self,
        fields: &AutomationFields,
        editor: &AutomationEditor,
        l: &L10n,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Vec<AnyElement> {
        let mut rows = vec![];
        let terminals = editor.terminals.clone().unwrap_or_default();
        let terminal = fields.terminal_id.clone().unwrap_or_default();
        if !terminals.is_empty() || !terminal.is_empty() {
            let mut choices = vec![Choice::new("", l.scheduled_task_folder_none())];
            choices.extend(
                terminals
                    .iter()
                    .map(|t| Choice::new(t.id.clone(), t.name.clone())),
            );
            if !terminal.is_empty()
                && editor.terminals.is_some()
                && !terminals.iter().any(|t| t.id == terminal)
            {
                choices.push(
                    Choice::new(
                        terminal.clone(),
                        l.scheduled_task_model_unavailable(&terminal),
                    )
                    .separated(),
                );
            }
            rows.push(
                forms::form_row(
                    l.terminal(),
                    controls::popup(
                        "task-terminal",
                        &l.terminal(),
                        choices,
                        &terminal,
                        editor.terminals.is_none(),
                        window,
                        cx,
                    ),
                    cx,
                )
                .into_any_element(),
            );
            if !terminal.is_empty() {
                rows.push(
                    forms::field(
                        l.scheduled_task_working_folder_label(),
                        &self.cwd,
                        None,
                        None,
                        window,
                        cx,
                    )
                    .into_any_element(),
                );
            }
        }
        let models = editor.models.clone().unwrap_or_default();
        let mut choices: Vec<Choice> = vec![];
        for (i, m) in models.iter().enumerate() {
            let choice = Choice::new(
                m.id.clone(),
                if m.name.trim().is_empty() {
                    m.id.clone()
                } else {
                    m.name.clone()
                },
            );
            // The terminal's agents follow the account's models.
            let first_agent = m.agent && models.get(i.wrapping_sub(1)).is_some_and(|p| !p.agent);
            choices.push(if first_agent {
                choice.separated()
            } else {
                choice
            });
        }
        let model_id = fields.model_id.trim().to_string();
        // An agent's id is an address: name it as the picker does.
        let agent_name = editor
            .agent_name
            .clone()
            .filter(|_| editor.fields.model_id.trim() == model_id);
        let shown = if model_id.is_empty() {
            l.scheduled_task_model_choose()
        } else {
            let listed = models.iter().any(|m| m.id == model_id);
            if !listed && (self.agents_loading && agent_name.is_some()) {
                choices.push(Choice::new(
                    model_id.clone(),
                    l.scheduled_task_agents_loading(),
                ));
            } else if !listed && editor.agents_unknown && agent_name.is_some() {
                // Whether the terminal still offers it is not known.
                choices.push(Choice::new(model_id.clone(), agent_name.clone().unwrap()));
            } else if !listed && editor.models.is_some() {
                choices.push(
                    Choice::new(
                        model_id.clone(),
                        l.scheduled_task_model_unavailable(
                            agent_name.as_deref().unwrap_or(&model_id),
                        ),
                    )
                    .separated(),
                );
            }
            model_id
        };
        rows.push(
            forms::form_row(
                l.scheduled_task_model_label(),
                controls::popup(
                    "task-model",
                    &l.scheduled_task_model_label(),
                    choices,
                    &shown,
                    false,
                    window,
                    cx,
                ),
                cx,
            )
            .into_any_element(),
        );
        rows
    }

    fn destination_rows(
        &self,
        fields: &AutomationFields,
        editor: &AutomationEditor,
        l: &L10n,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Vec<AnyElement> {
        let view = cx.entity().downgrade();
        let channel = fields.target == "channel";
        let mut rows = vec![
            div()
                .p(px(10.))
                .child(
                    Segmented::new(
                        "task-target",
                        l.scheduled_task_destination_label(),
                        vec![
                            Segment::new(l.scheduled_task_destination_chat()),
                            Segment::new(l.scheduled_task_destination_channel()),
                        ],
                        usize::from(channel),
                    )
                    .on_select(Rc::new(move |i, _, cx| {
                        let _ = view.update(cx, |e, cx| e.set_target(i == 1, cx));
                    })),
                )
                .into_any_element(),
        ];
        if channel {
            let channels = editor.channels.clone().unwrap_or_default();
            let selected = fields.channel_id.clone().unwrap_or_default();
            let mut choices: Vec<Choice> = channels
                .iter()
                .map(|c| Choice::new(c.id.clone(), format!("#{}", c.name)))
                .collect();
            let shown = if selected.is_empty() {
                l.scheduled_task_channel_choose()
            } else if channels.iter().any(|c| c.id == selected) {
                selected.clone()
            } else {
                choices.push(Choice::new(
                    selected.clone(),
                    l.scheduled_task_channel_unavailable(),
                ));
                selected.clone()
            };
            rows.push(
                forms::form_row(
                    l.scheduled_task_destination_channel(),
                    controls::popup(
                        "task-channel",
                        &l.scheduled_task_destination_channel(),
                        choices,
                        &shown,
                        editor.channels.is_none(),
                        window,
                        cx,
                    ),
                    cx,
                )
                .into_any_element(),
            );
        } else {
            let folders = editor.folders.clone().unwrap_or_default();
            let selected = fields.folder_id.clone().unwrap_or_default();
            let mut choices = vec![Choice::new("", l.scheduled_task_folder_none())];
            choices.extend(
                folders
                    .iter()
                    .map(|f| Choice::new(f.id.clone(), f.name.clone())),
            );
            if !selected.is_empty() && !folders.iter().any(|f| f.id == selected) {
                choices.push(Choice::new(
                    selected.clone(),
                    l.scheduled_task_folder_unavailable(),
                ));
            }
            rows.push(
                forms::form_row(
                    l.scheduled_task_folder_label(),
                    controls::popup(
                        "task-folder",
                        &l.scheduled_task_folder_label(),
                        choices,
                        &selected,
                        editor.folders.is_none(),
                        window,
                        cx,
                    ),
                    cx,
                )
                .into_any_element(),
            );
        }
        rows
    }
}

/// `fields` on terminal `id` (None: no terminal), as the core's
/// `AutomationDraft.withTerminal` moves a draft: another terminal starts from
/// its own folder (none typed) and keeps no coding agent of another terminal.
/// Done in the edit that changes the terminal, so every request after it
/// (the check, the terminals' list, a Save) carries the moved draft, whether
/// or not an answer to an earlier one reached the editor.
fn moved_to_terminal(fields: &mut AutomationFields, id: Option<String>) {
    if fields.terminal_id == id {
        return;
    }
    if agent_terminal(&fields.model_id).is_some_and(|on| Some(&on) != id.as_ref()) {
        fields.model_id = String::new();
    }
    fields.working_directory = None;
    fields.terminal_id = id;
}

/// The terminal a coding agent's model id names
/// (`agent:<terminal>:<agent>:<model>`, the terminal URL-encoded), or None
/// for another model.
fn agent_terminal(model_id: &str) -> Option<String> {
    let rest = model_id.trim().strip_prefix("agent:")?;
    let (terminal, after) = rest.split_once(':')?;
    let (agent, model) = after.split_once(':')?;
    if terminal.is_empty() || agent.is_empty() || model.is_empty() {
        return None;
    }
    Some(crate::stores::media::percent_decode(terminal))
}

/// Whether `model_id` names one of the terminal's coding agents the editor
/// offers (or the task's own, while the terminal is not asked).
fn is_agent(editor: &AutomationEditor, model_id: &str) -> bool {
    let id = model_id.trim();
    editor
        .models
        .as_ref()
        .is_some_and(|m| m.iter().any(|m| m.id == id && m.agent))
        || (editor.agent_name.is_some() && editor.fields.model_id.trim() == id)
}

impl SheetBody for TaskEditor {
    fn busy(&self, _: &App) -> bool {
        self.saving
    }

    fn footer(&mut self, _: &mut Window, cx: &mut Context<Self>) -> Option<AnyElement> {
        let l = cx.l10n().clone();
        let view = cx.entity().downgrade();
        let cancel_view = view.clone();
        Some(
            div()
                .w_full()
                .flex()
                .justify_end()
                .gap(px(8.))
                .child(Button::new("task-cancel", l.cancel()).on_click(Rc::new(
                    move |_, window, cx| {
                        let _ = cancel_view.update(cx, |s, cx| s.cancel(window, cx));
                    },
                )))
                .child(
                    Button::new("task-save", l.save())
                        .primary()
                        .disabled(self.saving || self.editor.is_none())
                        .on_click(Rc::new(move |_, window, cx| {
                            let _ = view.update(cx, |s, cx| s.save(window, cx));
                        })),
                )
                .into_any_element(),
        )
    }

    fn cancel(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.saving {
            return;
        }
        if !self.has_edits() {
            sheet::dismiss(cx);
            return;
        }
        let l = cx.l10n().clone();
        let spec = SheetSpec::new(
            l.desktop_discard_changes_title(),
            l.desktop_discard_changes_message(),
            l.desktop_discard(),
            l.cancel(),
        )
        .destructive();
        let ask = present_sheet(window, spec, cx);
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            if ask.await {
                // Discard closes this editor only: the question can outlive
                // it (another account's sign-in closed it), and the sheet
                // open by then is another editor, whose edits stay.
                cx.update(|cx| {
                    if let Some(this) = this.upgrade()
                        && sheet::current::<Self>(cx).is_some_and(|open| open == this)
                    {
                        sheet::dismiss(cx);
                    }
                });
            }
        })
        .detach();
    }

    fn label(&self, cx: &App) -> SharedString {
        let l = cx.l10n();
        if self.editor.as_ref().is_some_and(|e| !e.is_new) {
            l.scheduled_task_edit_title().into()
        } else {
            l.scheduled_task_new_title().into()
        }
    }

    /// Edits not saved, or a save still out: Quit asks first.
    fn unsaved(&self, _: &App) -> bool {
        self.saving || self.has_edits()
    }
}

impl TaskEditor {
    /// A new task differs from the draft it opened with.
    fn dirty_new(&self) -> bool {
        match (&self.editor, &self.fields) {
            (Some(e), Some(f)) => &e.fields != f,
            _ => false,
        }
    }

    /// Something was changed: typed since the editor opened (before its
    /// check is back, too), or a saved task the daemon says changed.
    fn has_edits(&self) -> bool {
        self.dirty_new() || self.changed && !self.editor.as_ref().is_some_and(|e| e.is_new)
    }
}

impl Render for TaskEditor {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let t = cx.conduit().clone();
        let r = t.roles;
        let l = cx.l10n().clone();
        if let Some(rule) = self.rrule_pending.take() {
            self.rrule.update(cx, |s, cx| s.set_value(rule, window, cx));
        }
        if let Some(folder) = self.cwd_pending.take() {
            self.cwd.update(cx, |s, cx| s.set_value(folder, window, cx));
        }
        let focus = self.focus.clone();
        let mut body: Vec<AnyElement> = vec![
            div()
                .id("sheet-title")
                .role(Role::Heading)
                .text_size(px(t.metrics.body + 2.))
                .font_weight(FontWeight::SEMIBOLD)
                .child(self.label(cx))
                .into_any_element(),
        ];
        if let (Some(editor), Some(fields)) = (self.editor.clone(), self.fields.clone()) {
            let view = cx.entity().downgrade();
            let active_view = view.clone();
            body.push(
                forms::form_group(
                    vec![
                        forms::field(
                            l.scheduled_task_name_label(),
                            &self.name,
                            None,
                            self.issue("nameRequired")
                                .then(|| l.scheduled_task_name_required().into()),
                            window,
                            cx,
                        )
                        .into_any_element(),
                        forms::form_row(
                            l.scheduled_task_active_label(),
                            Switch::new(
                                "task-active",
                                l.scheduled_task_active_label(),
                                fields.active,
                            )
                            .on_click(Rc::new({
                                let on = fields.active;
                                move |_, _, cx| {
                                    let _ = active_view
                                        .update(cx, |e, cx| e.edit(|f| f.active = !on, cx));
                                }
                            })),
                            cx,
                        )
                        .into_any_element(),
                    ],
                    cx,
                )
                .into_any_element(),
            );
            // Instructions.
            let mut prompt = div()
                .flex()
                .flex_col()
                .gap(px(6.))
                .child(
                    div()
                        .px(px(12.))
                        .text_size(px(t.metrics.small))
                        .text_color(r.text_subtle)
                        .child(SharedString::from(l.scheduled_task_prompt_label())),
                )
                .child(forms::form_group(
                    vec![
                        div()
                            .p(px(10.))
                            .child(Textarea::new(&self.prompt))
                            .into_any_element(),
                    ],
                    cx,
                ));
            if let Some(line) = self.issue_line(&["promptRequired"], &l, cx) {
                prompt = prompt.child(line);
            }
            body.push(prompt.into_any_element());
            // Terminal, its working folder, and the model (the terminal's
            // coding agents after the account's models).
            let rows = self.model_rows(&fields, &editor, &l, window, cx);
            let mut model = div()
                .flex()
                .flex_col()
                .gap(px(6.))
                .child(forms::form_group(rows, cx));
            if let Some(line) = self.issue_line(
                &["modelRequired", "modelUnavailable", "terminalRequired"],
                &l,
                cx,
            ) {
                model = model.child(line);
            }
            body.push(model.into_any_element());
            // Schedule.
            let schedule = self.schedule_rows(&fields, &l, window, cx);
            let mut group = div()
                .flex()
                .flex_col()
                .gap(px(6.))
                .child(
                    div()
                        .px(px(12.))
                        .text_size(px(t.metrics.small))
                        .text_color(r.text_subtle)
                        .child(SharedString::from(l.scheduled_task_schedule_label())),
                )
                .child(forms::form_group(schedule, cx));
            if let Some(line) = self.issue_line(&["scheduleIncomplete"], &l, cx) {
                group = group.child(line);
            }
            group = group
                .child(forms::group_footer(l.scheduled_task_timezone_note(), cx))
                .child(self.advanced_section(&fields, &l, window, cx));
            body.push(group.into_any_element());
            // Destination.
            let destination = self.destination_rows(&fields, &editor, &l, window, cx);
            let mut group = div()
                .flex()
                .flex_col()
                .gap(px(6.))
                .child(
                    div()
                        .px(px(12.))
                        .text_size(px(t.metrics.small))
                        .text_color(r.text_subtle)
                        .child(SharedString::from(l.scheduled_task_destination_label())),
                )
                .child(forms::form_group(destination, cx));
            if let Some(line) = self.issue_line(
                &[
                    "channelRequired",
                    "channelUnavailable",
                    "channelNoWrite",
                    "folderUnavailable",
                    "agentNeedsChat",
                ],
                &l,
                cx,
            ) {
                group = group.child(line);
            } else if is_agent(&editor, &fields.model_id) && fields.target != "channel" {
                // A coding agent posts only to a new chat: said where the
                // results go.
                group = group.child(forms::group_footer(l.scheduled_task_agent_needs_chat(), cx));
            }
            body.push(group.into_any_element());
        } else if self.failure.is_none() {
            body.push(
                div()
                    .py(px(20.))
                    .text_size(px(t.metrics.control))
                    .text_color(r.text_subtle)
                    .child(SharedString::from(l.desktop_loading()))
                    .into_any_element(),
            );
        }
        if let Some(failure) = &self.failure {
            body.push(forms::form_error("task-error", failure.clone(), cx).into_any_element());
        }
        div()
            .id("task-editor")
            .track_focus(&self.focus)
            .w_full()
            .flex()
            .flex_col()
            .gap(px(16.))
            .on_mouse_down(MouseButton::Left, move |_, window, cx| {
                if !focus.contains_focused(window, cx) {
                    window.focus(&focus, cx);
                }
            })
            .on_key_down(cx.listener(|this, e: &gpui_kit::KeyDownEvent, window, cx| {
                let k = &e.keystroke;
                if (k.key == "enter" || k.key == "s") && k.modifiers.platform {
                    this.save(window, cx);
                    cx.stop_propagation();
                }
            }))
            .on_action(cx.listener(|this, a: &SettingsChoice, _, cx| this.on_choice(a, cx)))
            .children(body)
    }
}

#[cfg(test)]
mod tests {
    use conduit_protocol::methods;
    use gpui_kit::VisualTestContext;

    use super::*;
    use crate::views::sheet::bench::bench;

    fn draw_sheet(vcx: &mut VisualTestContext) {
        vcx.update(|_, cx| {
            if let Some(handle) = sheet::current_window(cx) {
                let _ = handle.update(cx, |_, window, cx| window.draw(cx).clear(cx));
            }
        });
        vcx.run_until_parked();
    }

    /// A rule typed after a schedule check has settled, before the rule
    /// field took the check's rule, is the one shown and kept.
    #[gpui_kit::test]
    fn a_rule_typed_as_a_check_settles_stays(cx: &mut gpui_kit::TestAppContext) {
        let (daemon, stores, vcx) = bench(cx);
        daemon.on::<methods::AutomationsEditor>(|_| {
            Ok(serde_json::json!({
                "token": "te-1",
                "isNew": true,
                "fields": {
                    "name": "Allotment digest",
                    "prompt": "List what to sow this week",
                    "modelId": "m1",
                    "active": true,
                    "schedule": {
                        "kind": "daily", "year": 0, "month": 0, "day": 0,
                        "hour": 9, "minute": 0, "days": [],
                        "rrule": "RRULE:FREQ=DAILY;BYHOUR=9;BYMINUTE=0"
                    },
                    "target": "chat"
                },
                "terminal": false
            }))
        });
        daemon.on::<methods::AutomationsCheckDraft>(|p| {
            Ok(serde_json::json!({"fields": p["fields"], "changed": true}))
        });
        let s = stores.clone();
        vcx.update(|window, cx| open(s, None, window, cx));
        vcx.run_until_parked();
        draw_sheet(vcx);
        let task = vcx
            .update(|_, cx| sheet::current::<TaskEditor>(cx))
            .expect("the editor opens");
        // A schedule control's check settles, and before the field shows its
        // rule (the next frame), a rule is typed.
        let typed = "RRULE:FREQ=WEEKLY;BYDAY=MO;BYHOUR=6;BYMINUTE=30";
        vcx.update(|_, cx| {
            let window = sheet::current_window(cx).expect("the sheet's window");
            let _ = window.update(cx, |_, window, cx| {
                task.update(cx, |e, cx| {
                    let mut settled = e.fields.clone().expect("the fields");
                    settled.schedule.hour = 7;
                    settled.schedule.rrule = "RRULE:FREQ=DAILY;BYHOUR=7;BYMINUTE=0".into();
                    e.take_state(
                        AutomationDraftState {
                            fields: settled,
                            issues: vec![],
                            changed: true,
                            saved: false,
                            id: None,
                            failure: None,
                        },
                        cx,
                    );
                    // Typing: the field's text, then its change.
                    e.rrule
                        .update(cx, |r, cx| r.set_value(typed.to_string(), window, cx));
                    e.type_rule(typed.to_string(), cx);
                })
            });
        });
        vcx.run_until_parked();
        draw_sheet(vcx);
        vcx.update(|_, cx| {
            let e = task.read(cx);
            assert_eq!(
                e.rrule.read(cx).value().to_string(),
                typed,
                "the typed rule was replaced"
            );
            assert_eq!(
                e.fields.as_ref().map(|f| f.schedule.rrule.as_str()),
                Some(typed),
                "the rule kept is not the one typed"
            );
        });
    }

    /// Another terminal is chosen and another field edited before the
    /// daemon answers the change: every request from the change on carries
    /// the moved draft (no folder of the old terminal, none of its agents),
    /// so a Save never puts the old terminal's folder on the new one.
    #[gpui_kit::test]
    fn a_terminal_change_moves_every_request_after_it(cx: &mut gpui_kit::TestAppContext) {
        let (daemon, stores, vcx) = bench(cx);
        daemon.on::<methods::AutomationsEditor>(|_| {
            Ok(serde_json::json!({
                "token": "te-1",
                "isNew": true,
                "fields": {
                    "name": "Nightly lint",
                    "prompt": "Run the linter and summarise",
                    "modelId": "agent:term%2Dnorth:codex:gpt-test",
                    "active": true,
                    "schedule": {
                        "kind": "daily", "year": 0, "month": 0, "day": 0,
                        "hour": 2, "minute": 0, "days": [],
                        "rrule": "RRULE:FREQ=DAILY;BYHOUR=2;BYMINUTE=0"
                    },
                    "target": "chat",
                    "terminalId": "term-north",
                    "workingDirectory": "/srv/north-repo"
                },
                "terminal": true
            }))
        });
        daemon.on::<methods::AutomationsCheckDraft>(|p| {
            Ok(serde_json::json!({"fields": p["fields"], "changed": true}))
        });
        daemon.on::<methods::AutomationsTerminals>(|_| {
            Ok(serde_json::json!({"terminals": [], "models": [], "agentsUnknown": false}))
        });
        let s = stores.clone();
        vcx.update(|window, cx| open(s, None, window, cx));
        vcx.run_until_parked();
        draw_sheet(vcx);
        let task = vcx
            .update(|_, cx| sheet::current::<TaskEditor>(cx))
            .expect("the editor opens");
        let before = daemon.calls::<methods::AutomationsCheckDraft>().len();
        // The change's check is still unanswered when the name is edited:
        // its answer never reaches the editor.
        let held = daemon.hold::<methods::AutomationsCheckDraft>();
        vcx.update(|_, cx| {
            task.update(cx, |e, cx| {
                e.on_choice(
                    &SettingsChoice {
                        menu: "task-terminal".into(),
                        value: "term-south".into(),
                    },
                    cx,
                );
                e.edit(|f| f.name = "Nightly lint (south)".into(), cx);
            })
        });
        vcx.run_until_parked();
        held.release();
        vcx.run_until_parked();
        let checks = daemon.calls::<methods::AutomationsCheckDraft>();
        let lists = daemon.calls::<methods::AutomationsTerminals>();
        let sent: Vec<&serde_json::Value> = checks[before..]
            .iter()
            .chain(lists.iter())
            .map(|p| &p["fields"])
            .collect();
        assert!(
            sent.len() >= 3,
            "the change, the edit and the terminals' list went out"
        );
        for fields in sent {
            assert_eq!(fields["terminalId"], "term-south");
            assert!(
                fields.get("workingDirectory").is_none_or(|v| v.is_null()),
                "a request after the change carried the old terminal's folder: {fields}"
            );
            assert_eq!(
                fields["modelId"], "",
                "a request after the change kept the old terminal's agent"
            );
        }
        vcx.update(|_, cx| {
            let f = task.read(cx).fields.clone().expect("the fields");
            assert_eq!(f.working_directory, None);
            assert_eq!(f.model_id, "");
        });
    }

    /// Weekly is chosen while the terminal's agents are still being asked
    /// for: the check that follows their answer carries the choice, so the
    /// schedule the editor keeps (and saves) is the one chosen.
    #[gpui_kit::test]
    fn a_terminal_answer_never_drops_a_schedule_choice(cx: &mut gpui_kit::TestAppContext) {
        let (daemon, stores, vcx) = bench(cx);
        daemon.on::<methods::AutomationsEditor>(|_| {
            Ok(serde_json::json!({
                "token": "te-1",
                "isNew": true,
                "fields": {
                    "name": "Allotment digest",
                    "prompt": "List what to sow this week",
                    "modelId": "m1",
                    "active": true,
                    "schedule": {
                        "kind": "daily", "year": 0, "month": 0, "day": 0,
                        "hour": 9, "minute": 0, "days": [],
                        "rrule": "RRULE:FREQ=DAILY;BYHOUR=9;BYMINUTE=0"
                    },
                    "target": "chat",
                    "terminalId": "term-north"
                },
                "terminal": true
            }))
        });
        daemon.on::<methods::AutomationsCheckDraft>(|p| {
            Ok(serde_json::json!({"fields": p["fields"], "changed": true}))
        });
        daemon.on::<methods::AutomationsTerminals>(|_| {
            Ok(serde_json::json!({"terminals": [], "models": [], "agentsUnknown": false}))
        });
        let s = stores.clone();
        vcx.update(|window, cx| open(s, None, window, cx));
        vcx.run_until_parked();
        draw_sheet(vcx);
        let task = vcx
            .update(|_, cx| sheet::current::<TaskEditor>(cx))
            .expect("the editor opens");
        let before = daemon.calls::<methods::AutomationsCheckDraft>().len();
        // Weekly's check has not answered when the terminal's agents do.
        let held = daemon.hold::<methods::AutomationsCheckDraft>();
        vcx.update(|_, cx| {
            task.update(cx, |e, cx| {
                e.choose_kind("weekly", cx);
                e.refresh_terminals(None, cx);
            })
        });
        vcx.run_until_parked();
        held.release();
        vcx.run_until_parked();
        let checks = daemon.calls::<methods::AutomationsCheckDraft>();
        let after: Vec<_> = checks[before..].iter().collect();
        assert!(
            after.len() >= 2,
            "the choice and the terminals' recheck went out"
        );
        assert_eq!(
            after.last().expect("a check")["chooseKind"],
            "weekly",
            "the check after the terminal's answer dropped the schedule choice"
        );
    }

    /// Weekly is chosen, then a rule typed before Weekly's check answers:
    /// the typed rule is the newer edit, and no check after it carries the
    /// older choice, so the schedule kept (and saved) is the rule typed.
    #[gpui_kit::test]
    fn a_rule_typed_after_a_kind_choice_wins(cx: &mut gpui_kit::TestAppContext) {
        let (daemon, stores, vcx) = bench(cx);
        daemon.on::<methods::AutomationsEditor>(|_| {
            Ok(serde_json::json!({
                "token": "te-1",
                "isNew": true,
                "fields": {
                    "name": "Allotment digest",
                    "prompt": "List what to sow this week",
                    "modelId": "m1",
                    "active": true,
                    "schedule": {
                        "kind": "daily", "year": 0, "month": 0, "day": 0,
                        "hour": 9, "minute": 0, "days": [],
                        "rrule": "RRULE:FREQ=DAILY;BYHOUR=9;BYMINUTE=0"
                    },
                    "target": "chat"
                },
                "terminal": false
            }))
        });
        daemon.on::<methods::AutomationsCheckDraft>(|p| {
            Ok(serde_json::json!({"fields": p["fields"], "changed": true}))
        });
        let s = stores.clone();
        vcx.update(|window, cx| open(s, None, window, cx));
        vcx.run_until_parked();
        draw_sheet(vcx);
        let task = vcx
            .update(|_, cx| sheet::current::<TaskEditor>(cx))
            .expect("the editor opens");
        let before = daemon.calls::<methods::AutomationsCheckDraft>().len();
        let monthly = "RRULE:FREQ=MONTHLY;BYMONTHDAY=1;BYHOUR=9;BYMINUTE=0";
        let held = daemon.hold::<methods::AutomationsCheckDraft>();
        vcx.update(|_, cx| {
            task.update(cx, |e, cx| {
                e.choose_kind("weekly", cx);
                e.type_rule(monthly.to_string(), cx);
            })
        });
        vcx.run_until_parked();
        held.release();
        vcx.run_until_parked();
        let checks = daemon.calls::<methods::AutomationsCheckDraft>();
        let last = checks[before..].last().expect("a check");
        assert!(
            last.get("chooseKind").is_none_or(|k| k.is_null()),
            "the typed rule's check carried the older kind choice: {last}"
        );
        assert_eq!(last["fields"]["schedule"]["rrule"], monthly);
        vcx.update(|_, cx| {
            let f = task.read(cx).fields.clone().expect("the fields");
            assert_eq!(f.schedule.rrule, monthly);
            assert_eq!(f.schedule.kind, "custom");
        });
    }

    /// Weekly's check fails: the choice is not carried by a later check of
    /// another field (it was not taken), so that check never turns the
    /// schedule Weekly behind the user's back.
    #[gpui_kit::test]
    fn a_failed_kind_check_drops_the_choice(cx: &mut gpui_kit::TestAppContext) {
        let (daemon, stores, vcx) = bench(cx);
        daemon.on::<methods::AutomationsEditor>(|_| {
            Ok(serde_json::json!({
                "token": "te-1",
                "isNew": true,
                "fields": {
                    "name": "Allotment digest",
                    "prompt": "List what to sow this week",
                    "modelId": "m1",
                    "active": true,
                    "schedule": {
                        "kind": "daily", "year": 0, "month": 0, "day": 0,
                        "hour": 9, "minute": 0, "days": [],
                        "rrule": "RRULE:FREQ=DAILY;BYHOUR=9;BYMINUTE=0"
                    },
                    "target": "chat"
                },
                "terminal": false
            }))
        });
        daemon.on::<methods::AutomationsCheckDraft>(|p| {
            Ok(serde_json::json!({"fields": p["fields"], "changed": true}))
        });
        let s = stores.clone();
        vcx.update(|window, cx| open(s, None, window, cx));
        vcx.run_until_parked();
        draw_sheet(vcx);
        let task = vcx
            .update(|_, cx| sheet::current::<TaskEditor>(cx))
            .expect("the editor opens");
        let before = daemon.calls::<methods::AutomationsCheckDraft>().len();
        daemon.once::<methods::AutomationsCheckDraft>(Err(conduit_daemon::protocol::error(
            "rpc.serverError",
            "the check was refused",
        )));
        vcx.update(|_, cx| task.update(cx, |e, cx| e.choose_kind("weekly", cx)));
        vcx.run_until_parked();
        vcx.update(|_, cx| {
            task.update(cx, |e, cx| {
                e.edit(|f| f.name = "Allotment digest (late)".into(), cx)
            })
        });
        vcx.run_until_parked();
        let checks = daemon.calls::<methods::AutomationsCheckDraft>();
        assert_eq!(checks[before]["chooseKind"], "weekly");
        let last = checks.last().expect("a check");
        assert!(
            last.get("chooseKind").is_none_or(|k| k.is_null()),
            "a check after the failed one carried its kind choice: {last}"
        );
    }

    /// A Daily task's editor, open, with checks that echo what they are sent.
    fn daily_editor(
        daemon: &crate::stores::rpc::fake::FakeDaemon,
        stores: &crate::stores::Stores,
        vcx: &mut VisualTestContext,
    ) -> Entity<TaskEditor> {
        daemon.on::<methods::AutomationsEditor>(|_| {
            Ok(serde_json::json!({
                "token": "te-1",
                "isNew": true,
                "fields": {
                    "name": "Allotment digest",
                    "prompt": "List what to sow this week",
                    "modelId": "m1",
                    "active": true,
                    "schedule": {
                        "kind": "daily", "year": 0, "month": 0, "day": 0,
                        "hour": 9, "minute": 0, "days": [],
                        "rrule": "RRULE:FREQ=DAILY;BYHOUR=9;BYMINUTE=0"
                    },
                    "target": "chat"
                },
                "terminal": false
            }))
        });
        daemon.on::<methods::AutomationsCheckDraft>(|p| {
            Ok(serde_json::json!({"fields": p["fields"], "changed": true}))
        });
        let s = stores.clone();
        vcx.update(|window, cx| open(s, None, window, cx));
        vcx.run_until_parked();
        draw_sheet(vcx);
        vcx.update(|_, cx| sheet::current::<TaskEditor>(cx))
            .expect("the editor opens")
    }

    /// Weekly is chosen and, before its check answers, `then` edits the
    /// editor: the kind the last check carries.
    fn kind_after(
        cx: &mut gpui_kit::TestAppContext,
        then: impl FnOnce(&mut TaskEditor, &mut Context<TaskEditor>),
    ) -> serde_json::Value {
        let (daemon, stores, vcx) = bench(cx);
        let task = daily_editor(&daemon, &stores, vcx);
        let held = daemon.hold::<methods::AutomationsCheckDraft>();
        vcx.update(|_, cx| {
            task.update(cx, |e, cx| {
                e.choose_kind("weekly", cx);
                then(e, cx);
            })
        });
        vcx.run_until_parked();
        held.release();
        vcx.run_until_parked();
        let checks = daemon.calls::<methods::AutomationsCheckDraft>();
        checks.last().expect("a check")["chooseKind"].clone()
    }

    /// Another kind chosen before Weekly's check answers replaces it.
    #[gpui_kit::test]
    fn another_kind_replaces_a_pending_choice(cx: &mut gpui_kit::TestAppContext) {
        let kind = kind_after(cx, |e, cx| e.choose_kind("once", cx));
        assert_eq!(kind, "once");
    }

    /// A schedule control changed before Weekly's check answers is the
    /// newer schedule edit: no check after it carries Weekly.
    #[gpui_kit::test]
    fn a_schedule_edit_drops_a_pending_choice(cx: &mut gpui_kit::TestAppContext) {
        let kind = kind_after(cx, |e, cx| e.edit_schedule(|f| f.schedule.hour = 7, cx));
        assert!(
            kind.is_null(),
            "a check after the schedule edit carried Weekly: {kind}"
        );
    }

    /// The name edited before Weekly's check answers is no schedule edit:
    /// its check carries Weekly, so the choice is not lost to it.
    #[gpui_kit::test]
    fn a_name_edit_keeps_a_pending_choice(cx: &mut gpui_kit::TestAppContext) {
        let kind = kind_after(cx, |e, cx| {
            e.edit(|f| f.name = "Allotment digest (late)".into(), cx)
        });
        assert_eq!(kind, "weekly");
    }

    /// With Full Keyboard Access on, Tab reaches Advanced Schedule and
    /// Space opens it, as every other control in the editor.
    #[gpui_kit::test]
    fn tab_reaches_advanced_schedule(cx: &mut gpui_kit::TestAppContext) {
        let app = cx.clone();
        let (daemon, stores, vcx) = bench(cx);
        vcx.update(|_, cx| {
            cx.set_global(conduit_components::views::focus::KeyboardAccess { all_controls: true })
        });
        daemon.on::<methods::AutomationsEditor>(|_| {
            Ok(serde_json::json!({
                "token": "te-1",
                "isNew": true,
                "fields": {
                    "name": "Allotment digest",
                    "prompt": "List what to sow this week",
                    "modelId": "m1",
                    "active": true,
                    "schedule": {
                        "kind": "daily", "year": 0, "month": 0, "day": 0,
                        "hour": 9, "minute": 0, "days": [],
                        "rrule": "RRULE:FREQ=DAILY;BYHOUR=9;BYMINUTE=0"
                    },
                    "target": "chat"
                },
                "terminal": false
            }))
        });
        daemon.on::<methods::AutomationsCheckDraft>(|p| {
            Ok(serde_json::json!({"fields": p["fields"], "changed": false}))
        });
        let s = stores.clone();
        vcx.update(|window, cx| open(s, None, window, cx));
        vcx.run_until_parked();
        draw_sheet(vcx);
        let task = vcx
            .update(|_, cx| sheet::current::<TaskEditor>(cx))
            .expect("the editor opens");
        let window = vcx
            .update(|_, cx| sheet::current_window(cx))
            .expect("the sheet's window");
        let mut sheet_cx = VisualTestContext::from_window(window, &app);
        let disclosure = sheet_cx
            .debug_bounds("task-advanced")
            .expect("Advanced Schedule is drawn");
        let mut reached = false;
        for _ in 0..40 {
            sheet_cx.update(|window, cx| {
                window.focus_next(cx);
                window.draw(cx).clear(cx)
            });
            if sheet_cx
                .debug_bounds("focus-ring")
                .is_some_and(|ring| ring.intersects(&disclosure))
            {
                reached = true;
                break;
            }
        }
        assert!(reached, "Tab never reached Advanced Schedule");
        assert!(!task.read_with(vcx, |e, _| e.advanced));
        sheet_cx.simulate_keystrokes("space");
        sheet_cx.simulate_event(gpui_kit::KeyUpEvent {
            keystroke: gpui_kit::Keystroke::parse("space").unwrap(),
        });
        vcx.run_until_parked();
        assert!(
            task.read_with(vcx, |e, _| e.advanced),
            "Space on Advanced Schedule did not open it"
        );
    }
}
