//! A scheduled agent's editor: a window sheet on the main window, as the
//! phone's job dialog (`hermes_job_editor.dart`) asks it. Name, prompt and
//! schedule (checked as the phone checks them: required, bounded, a
//! schedule Hermes can read); on a Desktop Gateway also what to do with
//! runs missed while Hermes was not running, and where each run goes
//! (saved in Hermes, a messaging app's home channel, a bot's chat, a group
//! chat), as a checklist whose last target cannot be cleared. An edit
//! sends only the delivery and missed-run choices it changed.

use std::rc::Rc;

use conduit_components::ActiveConduitTheme as _;
use conduit_components::announce::{Priority, live_text};
use conduit_components::views::focus::{RadioGroupExt as _, radio_option_id};
use conduit_components::views::kit::{Button, grouped_section, radio_dot};
use conduit_protocol::{
    HermesDeliveryOptions, HermesDeliveryTargetDto, HermesJobDto, HermesJobEdit, NoParams,
    NoticeLevel, methods,
};
use gpui_kit::component::input::{InputEvent, InputState, Textarea, TextareaState};
use gpui_kit::prelude::*;
use gpui_kit::{
    AnyElement, App, AsyncApp, AsyncWindowContext, Context, ElementId, Entity, FontWeight, Role,
    SharedString, Subscription, WeakEntity, Window, div, px, relative,
};

use crate::l10n::{ActiveL10n as _, L10n};
use crate::shell::sheet::{SheetSpec, present_sheet};
use crate::stores::Stores;
use crate::views::forms;
use crate::views::panes::hermes_jobs::target_label;
use crate::views::settings::controls::checkbox;
use crate::views::sheet::{self, SheetBody};

pub const WIDTH: f32 = 560.;
/// The phone's bounds (core `hermes_job.dart`).
pub const MAX_NAME: usize = 200;
pub const MAX_PROMPT: usize = 5000;
pub const MAX_SCHEDULE: usize = 2048;
/// The missed-run choices, as Hermes stores them.
pub const CATCH_UP: [&str; 3] = ["default", "runOnce", "skip"];

/// Opens the editor for `job` (a new one when `None`) on `window`.
pub fn open(stores: &Stores, job: Option<HermesJobDto>, window: &mut Window, cx: &mut App) {
    let scheduling = stores
        .hermes_admin
        .read(cx)
        .jobs
        .as_ref()
        .and_then(crate::stores::hermes_admin::Loaded::ready)
        .is_some_and(|j| j.scheduling);
    let stores = stores.clone();
    sheet::open(window, WIDTH, cx, move |w, cx| {
        HermesJobSheet::new(stores, job, scheduling, w, cx)
    });
}

/// What is wrong with a field, once Save was pressed.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FieldError {
    Required,
    TooLong(usize),
    InvalidSchedule,
}

pub struct HermesJobSheet {
    stores: Stores,
    pub job: Option<HermesJobDto>,
    /// A Desktop Gateway: delivery and missed runs are asked.
    pub scheduling: bool,
    pub name: Entity<InputState>,
    pub prompt: Entity<TextareaState>,
    pub schedule: Entity<InputState>,
    pub catch_up: usize,
    /// The delivery targets chosen, in order.
    pub deliver: Vec<String>,
    /// What Hermes offers to deliver to (`None` while it is read).
    pub options: Option<HermesDeliveryOptions>,
    initial: (String, String, String, usize, Vec<String>),
    pub show_errors: bool,
    /// Counts the Saves refused, here or by the daemon: the one attempt
    /// every live region of the sheet takes, so each refusal is heard, even
    /// in the words of the one before.
    refusals: u64,
    /// The daemon refused a field: which, and why.
    pub refused: Option<(String, FieldError)>,
    pub busy: bool,
    pub error: Option<String>,
    /// The connection in use when the editor opened: the job is saved to
    /// it, or to none.
    opened: crate::stores::hermes_admin::Opened,
    /// The job a save made, as its answer named it: saved to from then on,
    /// whether or not the list that came with it has it yet.
    saved_id: Option<String>,
    /// A save made a job but named none: Save sends nothing more (it could
    /// only make another), the words stay.
    made_unnamed: bool,
    _subscriptions: Vec<Subscription>,
}

impl HermesJobSheet {
    pub fn new(
        stores: Stores,
        job: Option<HermesJobDto>,
        scheduling: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Self {
        let l = cx.l10n().clone();
        let name = forms::input(l.hermes_job_name_hint(), false, window, cx);
        let prompt_hint = l.hermes_job_prompt_hint();
        let prompt = cx.new(|cx| {
            TextareaState::new(window, cx)
                .auto_grow(3, 8)
                .placeholder(prompt_hint)
        });
        let schedule = forms::input(l.hermes_job_schedule_hint(), false, window, cx);
        let mut subscriptions = vec![];
        for input in [&name, &schedule] {
            subscriptions.push(cx.subscribe_in(
                input,
                window,
                |this: &mut Self, _, e: &InputEvent, window, cx| match e {
                    InputEvent::PressEnter { .. } => this.save(window, cx),
                    InputEvent::Change => {
                        this.refused = None;
                        this.error = None;
                        cx.notify();
                    }
                    _ => {}
                },
            ));
        }
        subscriptions.push(cx.subscribe(&prompt, |this, _, e: &InputEvent, cx| {
            if matches!(e, InputEvent::Change) {
                this.refused = None;
                cx.notify();
            }
        }));
        let (n, p, s) = match &job {
            Some(j) => (
                j.name.clone().unwrap_or_default(),
                j.prompt.clone(),
                j.schedule.clone(),
            ),
            None => (String::new(), String::new(), "0 9 * * *".to_string()),
        };
        name.update(cx, |i, cx| i.set_value(n.clone(), window, cx));
        prompt.update(cx, |i, cx| i.set_value(p.clone(), window, cx));
        schedule.update(cx, |i, cx| i.set_value(s.clone(), window, cx));
        let catch_up = job
            .as_ref()
            .and_then(|j| CATCH_UP.iter().position(|c| *c == j.catch_up))
            .unwrap_or(0);
        let deliver: Vec<String> = job
            .as_ref()
            .map(|j| j.deliver.iter().map(|d| d.target.clone()).collect())
            .filter(|d: &Vec<String>| !d.is_empty())
            .unwrap_or_else(|| vec!["local".to_string()]);
        name.update(cx, |i, cx| i.focus(window, cx));
        let opened = stores.hermes_admin.read(cx).opened();
        let mut this = Self {
            stores,
            job,
            scheduling,
            name,
            prompt,
            schedule,
            catch_up,
            initial: (n, p, s, catch_up, deliver.clone()),
            deliver,
            options: None,
            show_errors: false,
            refusals: 0,
            refused: None,
            busy: false,
            error: None,
            opened,
            saved_id: None,
            made_unnamed: false,
            _subscriptions: subscriptions,
        };
        if scheduling {
            this.load_options(cx);
        }
        this
    }

    fn load_options(&mut self, cx: &mut Context<Self>) {
        let call = self
            .stores
            .connection
            .read(cx)
            .rpc()
            .call::<methods::HermesJobsDelivery>(&NoParams);
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result = call.await;
            let _ = this.update(cx, |s, cx| {
                s.options = Some(result.unwrap_or_else(|_| HermesDeliveryOptions {
                    available: true,
                    options: vec![HermesDeliveryTargetDto {
                        target: "local".into(),
                        kind: "local".into(),
                        name: String::new(),
                        available: true,
                    }],
                }));
                cx.notify();
            });
        })
        .detach();
    }

    fn values(&self, cx: &App) -> (String, String, String) {
        (
            forms::text(&self.name, cx),
            self.prompt.read(cx).value().trim().to_string(),
            forms::text(&self.schedule, cx),
        )
    }

    fn dirty(&self, cx: &App) -> bool {
        let (n, p, s) = self.values(cx);
        let (n0, p0, s0, c0, d0) = &self.initial;
        n != n0.trim()
            || p != p0.trim()
            || s != s0.trim()
            || self.catch_up != *c0
            || self.deliver != *d0
    }

    /// The phone's per-field checks (the schedule's grammar is the daemon's).
    pub fn errors(&self, cx: &App) -> [Option<FieldError>; 3] {
        let (n, p, s) = self.values(cx);
        let bounded = |v: &str, max: usize| {
            if v.is_empty() {
                Some(FieldError::Required)
            } else if v.chars().count() > max {
                Some(FieldError::TooLong(max))
            } else {
                None
            }
        };
        let refused = |field: &str| {
            self.refused
                .as_ref()
                .filter(|(f, _)| f == field)
                .map(|(_, e)| *e)
        };
        [
            bounded(&n, MAX_NAME).or_else(|| refused("name")),
            bounded(&p, MAX_PROMPT).or_else(|| refused("prompt")),
            bounded(&s, MAX_SCHEDULE).or_else(|| refused("schedule")),
        ]
    }

    fn error_text(&self, error: Option<FieldError>, l: &L10n) -> Option<SharedString> {
        if !self.show_errors && self.refused.is_none() {
            return None;
        }
        Some(
            match error? {
                FieldError::Required => l.required_field_helper(),
                FieldError::TooLong(max) => l.hermes_job_too_long(max as i64),
                FieldError::InvalidSchedule => l.hermes_job_schedule_invalid(),
            }
            .into(),
        )
    }

    pub fn save(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.busy {
            return;
        }
        if self.refuse_fields(window, cx) {
            return;
        }
        if self.made_unnamed {
            self.refusals += 1;
            self.error = Some(cx.l10n().notification_targets_stale());
            cx.notify();
            return;
        }
        let admin = self.stores.hermes_admin.read(cx);
        let id = self
            .job
            .as_ref()
            .map(|j| j.id.clone())
            .or_else(|| self.saved_id.clone());
        let editing = id.is_some();
        if !admin.still_in_use(&self.opened) {
            self.refusals += 1;
            let l = cx.l10n();
            self.error = Some(if editing {
                l.hermes_job_update_failed()
            } else {
                l.hermes_job_create_failed()
            });
            cx.notify();
            return;
        }
        let (name, prompt, schedule) = self.values(cx);
        let sent = (
            name.clone(),
            prompt.clone(),
            schedule.clone(),
            self.catch_up,
            self.deliver.clone(),
        );
        let (_, _, _, c0, d0) = &self.initial;
        let deliver_changed = !editing || {
            let mut a = self.deliver.clone();
            let mut b = d0.clone();
            a.sort();
            b.sort();
            a != b
        };
        let catch_up_changed = !editing || self.catch_up != *c0;
        let edit = HermesJobEdit {
            id: id.clone(),
            name: Some(name),
            prompt,
            schedule,
            deliver: (self.scheduling && deliver_changed && self.delivery_known())
                .then(|| self.deliver.join(",")),
            catch_up: (self.scheduling && catch_up_changed)
                .then(|| CATCH_UP[self.catch_up].to_string()),
            connection: self.opened.connection.clone(),
        };
        let call = self
            .stores
            .connection
            .read(cx)
            .rpc()
            .call::<methods::HermesSaveJob>(&edit);
        // Its list is taken in the order it was asked, against the polls.
        let ticket = self.stores.hermes_admin.update(cx, |a, _| a.ask_jobs());
        self.busy = true;
        self.error = None;
        cx.notify();
        cx.spawn_in(
            window,
            async move |this: WeakEntity<Self>, cx: &mut AsyncWindowContext| {
                let result = call.await;
                let _ = this.update_in(cx, |s, window, cx| {
                    s.busy = false;
                    let l = cx.l10n().clone();
                    match result {
                        Ok(jobs) => {
                            // What was sent is saved; a new job is edited from
                            // now on (by the id the answer names), so a later
                            // Save changes it. A made job the answer does not
                            // name could only be made again: Save stops there.
                            if !editing {
                                match &jobs.saved_id {
                                    Some(id) => {
                                        s.saved_id = Some(id.clone());
                                        s.job = jobs.jobs.iter().find(|j| &j.id == id).cloned();
                                    }
                                    None => s.made_unnamed = true,
                                }
                            }
                            s.initial = sent;
                            s.stores.hermes_admin.update(cx, |a, cx| {
                                a.answer_jobs(ticket, jobs, cx);
                            });
                            let text = if editing {
                                l.hermes_job_updated()
                            } else {
                                l.hermes_job_created()
                            };
                            s.stores
                                .toasts
                                .update(cx, |t, cx| t.show(NoticeLevel::Success, text, cx));
                            // Words typed while the Save was out stay.
                            if !s.dirty(cx) {
                                sheet::dismiss(cx);
                            } else if s.made_unnamed {
                                s.error = Some(l.notification_targets_stale());
                            }
                        }
                        Err(e) => match (e.args.get("field"), e.args.get("reason")) {
                            (Some(field), Some(reason)) => {
                                let error = match reason.as_str() {
                                    "invalidSchedule" => FieldError::InvalidSchedule,
                                    "tooLong" => FieldError::TooLong(match field.as_str() {
                                        "name" => MAX_NAME,
                                        "prompt" => MAX_PROMPT,
                                        _ => MAX_SCHEDULE,
                                    }),
                                    _ => FieldError::Required,
                                };
                                s.refused = Some((field.clone(), error));
                                // As a refusal here: heard, and the field takes
                                // the focus.
                                s.refuse_fields(window, cx);
                            }
                            _ => {
                                log::info!("hermes.saveJob: {e}");
                                s.refusals += 1;
                                s.error = Some(if editing {
                                    l.hermes_job_update_failed()
                                } else {
                                    l.hermes_job_create_failed()
                                });
                            }
                        },
                    }
                    cx.notify();
                });
            },
        )
        .detach();
    }

    /// Save refused for a field (checked here, or refused by the daemon):
    /// the errors show, the refusal is counted so it is heard, and the first
    /// field in error takes the focus, as the phone's form moves to it.
    /// Whether one was.
    fn refuse_fields(&mut self, window: &mut Window, cx: &mut Context<Self>) -> bool {
        let Some(first) = self.errors(cx).iter().position(Option::is_some) else {
            return false;
        };
        self.show_errors = true;
        self.refusals += 1;
        match first {
            0 => self.name.update(cx, |i, cx| i.focus(window, cx)),
            1 => self.prompt.update(cx, |i, cx| i.focus(window, cx)),
            _ => self.schedule.update(cx, |i, cx| i.focus(window, cx)),
        }
        cx.notify();
        true
    }

    /// The job's stored routes could be read: only then are they shown and
    /// sent (an edit never replaces routes it never showed).
    fn delivery_known(&self) -> bool {
        self.job.as_ref().is_none_or(|j| j.delivery_known)
    }

    /// Ticks or clears delivery target `target`; the last one stays.
    pub fn toggle_target(&mut self, target: &str, cx: &mut Context<Self>) {
        if !self.delivery_known() {
            return;
        }
        if let Some(ix) = self.deliver.iter().position(|t| t == target) {
            if self.deliver.len() > 1 {
                self.deliver.remove(ix);
            }
        } else {
            self.deliver.push(target.to_string());
        }
        cx.notify();
    }

    fn catch_up_section(
        &self,
        l: &L10n,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let t = cx.conduit().clone();
        let this = cx.entity().downgrade();
        let labels = [
            l.hermes_job_catch_up_default(),
            l.hermes_job_catch_up_run_once(),
            l.hermes_job_catch_up_skip(),
        ];
        let select: conduit_components::views::kit::SelectHandler = {
            let this = this.clone();
            Rc::new(move |i, _, cx| {
                let _ = this.update(cx, |s, cx| {
                    s.catch_up = i;
                    cx.notify();
                });
            })
        };
        let _ = window;
        let options = labels.into_iter().enumerate().map(|(i, label)| {
            let on = i == self.catch_up;
            let select = select.clone();
            div()
                .id(radio_option_id("hermes-job-catch-up", i, on))
                .role(Role::RadioButton)
                .aria_label(SharedString::from(label.clone()))
                .aria_toggled(if on {
                    gpui_kit::Toggled::True
                } else {
                    gpui_kit::Toggled::False
                })
                .px(px(12.))
                .py(px(7.))
                .flex()
                .items_center()
                .gap(px(10.))
                .cursor_pointer()
                .child(radio_dot(on, &t))
                .child(
                    div()
                        .text_size(px(t.metrics.control))
                        .text_color(t.roles.text)
                        .child(SharedString::from(label)),
                )
                .radio_option_outline(on, 8., cx)
                .on_click(move |_, window, cx| select(i, window, cx))
                .into_any_element()
        });
        let group = div()
            .id("hermes-job-catch-up")
            .role(Role::RadioGroup)
            .aria_label(SharedString::from(l.hermes_job_catch_up_label()))
            .py(px(4.))
            .flex()
            .flex_col()
            .children(options)
            .radio_group(self.catch_up, CATCH_UP.len(), Some(select), cx);
        grouped_section(
            Some(l.hermes_job_catch_up_label().into()),
            vec![group.into_any_element()],
            Some(l.hermes_job_catch_up_hint().into()),
            cx,
        )
        .into_any_element()
    }

    fn deliver_section(&self, l: &L10n, window: &mut Window, cx: &mut Context<Self>) -> AnyElement {
        let t = cx.conduit().clone();
        let this = cx.entity().downgrade();
        let offered: Vec<HermesDeliveryTargetDto> = self
            .options
            .as_ref()
            .map(|o| o.options.clone())
            .unwrap_or_else(|| {
                vec![HermesDeliveryTargetDto {
                    target: "local".into(),
                    kind: "local".into(),
                    name: String::new(),
                    available: true,
                }]
            });
        // A target the job has that Hermes no longer lists stays, chosen.
        let mut all = offered.clone();
        for target in &self.deliver {
            if !all.iter().any(|o| &o.target == target) {
                all.push(HermesDeliveryTargetDto {
                    target: target.clone(),
                    kind: "other".into(),
                    name: target.clone(),
                    available: true,
                });
            }
        }
        let row = |option: &HermesDeliveryTargetDto, window: &mut Window, cx: &mut App| {
            let checked = self.deliver.contains(&option.target);
            let locked = (checked && self.deliver.len() <= 1) || (!checked && !option.available);
            let label = target_label(option, l);
            let this = this.clone();
            let target = option.target.clone();
            let toggle: conduit_components::views::kit::ClickHandler = Rc::new(move |_, _, cx| {
                if locked {
                    return;
                }
                let _ = this.update(cx, |s, cx| s.toggle_target(&target, cx));
            });
            div()
                .px(px(12.))
                .py(px(7.))
                .flex()
                .items_center()
                .gap(px(10.))
                .when(locked && !checked, |d| d.opacity(0.55))
                .child(checkbox(
                    ElementId::Name(format!("hermes-job-deliver-{}", option.target).into()),
                    label.clone(),
                    checked,
                    toggle,
                    window,
                    cx,
                ))
                .child(
                    div()
                        .flex()
                        .flex_col()
                        .gap(px(1.))
                        .child(
                            div()
                                .text_size(px(t.metrics.control))
                                .text_color(t.roles.text)
                                .child(SharedString::from(label)),
                        )
                        .when(!option.available, |d| {
                            d.child(
                                div()
                                    .text_size(px(t.metrics.small))
                                    .text_color(t.roles.text_subtle)
                                    .child(l.hermes_job_deliver_needs_home_channel()),
                            )
                        }),
                )
                .into_any_element()
        };
        let heading = |text: String| {
            div()
                .px(px(12.))
                .pt(px(8.))
                .text_size(px(t.metrics.small))
                .font_weight(FontWeight::SEMIBOLD)
                .text_color(t.roles.text_subtle)
                .child(SharedString::from(text))
                .into_any_element()
        };
        let of = |kinds: &[&str]| -> Vec<HermesDeliveryTargetDto> {
            all.iter()
                .filter(|o| kinds.contains(&o.kind.as_str()))
                .cloned()
                .collect()
        };
        let mut rows: Vec<AnyElement> = vec![];
        for option in of(&["local", "other"]) {
            rows.push(row(&option, window, cx));
        }
        let groups: [(&[&str], String); 3] = [
            (&["platform"], l.hermes_job_deliver_messaging()),
            (&["botChat"], l.hermes_job_deliver_bot_chats()),
            (&["room"], l.hermes_job_deliver_group_chats()),
        ];
        for (kinds, title) in groups {
            let options = of(kinds);
            if options.is_empty() {
                continue;
            }
            rows.push(heading(title));
            for option in options {
                rows.push(row(&option, window, cx));
            }
        }
        let rooms = !of(&["room"]).is_empty();
        let list = div()
            .id("hermes-job-deliver")
            .role(Role::Group)
            .aria_label(SharedString::from(l.hermes_job_deliver_label()))
            .py(px(4.))
            .flex()
            .flex_col()
            .children(rows);
        grouped_section(
            Some(l.hermes_job_deliver_label().into()),
            vec![list.into_any_element()],
            rooms.then(|| l.hermes_job_deliver_room_hint().into()),
            cx,
        )
        .into_any_element()
    }
}

impl SheetBody for HermesJobSheet {
    fn busy(&self, _: &App) -> bool {
        self.busy
    }

    /// Edits not saved, or a Save still out: Quit asks first.
    fn unsaved(&self, cx: &App) -> bool {
        self.busy || self.dirty(cx)
    }

    fn cancel(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.busy {
            return;
        }
        if !self.dirty(cx) {
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
        cx.spawn(async move |_, cx: &mut AsyncApp| {
            if ask.await {
                cx.update(sheet::dismiss);
            }
        })
        .detach();
    }

    fn label(&self, cx: &App) -> SharedString {
        let l = cx.l10n();
        if self.job.is_some() {
            l.hermes_job_editor_edit_title().into()
        } else {
            l.hermes_job_new().into()
        }
    }

    fn footer(&mut self, _: &mut Window, cx: &mut Context<Self>) -> Option<AnyElement> {
        let l = cx.l10n().clone();
        let view = cx.entity().downgrade();
        let cancel = view.clone();
        Some(
            forms::form_buttons(vec![
                Button::new("hermes-job-cancel", l.cancel())
                    .on_click(Rc::new(move |_, window, cx| {
                        let _ = cancel.update(cx, |v, cx| v.cancel(window, cx));
                    }))
                    .into_any_element(),
                Button::new(
                    "hermes-job-save",
                    if self.busy {
                        l.desktop_saving()
                    } else {
                        l.save()
                    },
                )
                .primary()
                .disabled(self.busy || self.made_unnamed)
                .on_click(Rc::new(move |_, window, cx| {
                    let _ = view.update(cx, |v, cx| v.save(window, cx));
                }))
                .into_any_element(),
            ])
            .into_any_element(),
        )
    }
}

impl Render for HermesJobSheet {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let l = cx.l10n().clone();
        let t = cx.conduit().clone();
        let [name_error, prompt_error, schedule_error] = self.errors(cx);
        let title = if self.job.is_some() {
            l.hermes_job_editor_edit_title()
        } else {
            l.hermes_job_new()
        };
        let prompt_error = self.error_text(prompt_error, &l);
        let prompt = div()
            .id("hermes-job-prompt")
            .p(px(12.))
            .flex()
            .flex_col()
            .gap(px(6.))
            .child(
                div()
                    .text_size(px(t.metrics.control))
                    .text_color(t.roles.text)
                    .child(l.hermes_job_prompt_label()),
            )
            .child(Textarea::new(&self.prompt))
            .when_some(prompt_error, |d, e| {
                d.child(
                    div()
                        .id("hermes-job-prompt-error")
                        .role(Role::Alert)
                        .text_size(px(t.metrics.small))
                        .text_color(t.roles.danger)
                        .child(e.clone())
                        // Said with the field's name: the Prompt has no
                        // row label of its own around the error.
                        .child(
                            live_text(
                                "live",
                                Some(format!("{}, {e}", l.hermes_job_prompt_label()).into()),
                                Priority::High,
                            )
                            .attempt(self.refusals),
                        ),
                )
            });
        let mut body = vec![
            div()
                .id("sheet-title")
                .role(Role::Heading)
                .text_size(px(t.metrics.body + 2.))
                .font_weight(FontWeight::SEMIBOLD)
                .child(SharedString::from(title.clone()))
                .into_any_element(),
            grouped_section(
                None,
                vec![
                    forms::field_answered(
                        l.name(),
                        &self.name,
                        None,
                        forms::Answer {
                            error: self.error_text(name_error, &l),
                            attempt: self.refusals,
                        },
                        false,
                        window,
                        cx,
                    )
                    .into_any_element(),
                    prompt.into_any_element(),
                ],
                None,
                cx,
            )
            .into_any_element(),
            grouped_section(
                None,
                vec![
                    forms::field_answered(
                        l.hermes_job_schedule_label(),
                        &self.schedule,
                        Some(l.hermes_job_schedule_help().into()),
                        forms::Answer {
                            error: self.error_text(schedule_error, &l),
                            attempt: self.refusals,
                        },
                        false,
                        window,
                        cx,
                    )
                    .into_any_element(),
                ],
                None,
                cx,
            )
            .into_any_element(),
        ];
        if self.scheduling {
            body.push(self.catch_up_section(&l, window, cx));
            // Routes that could not be read are not shown as a checklist:
            // ticking one would replace them all.
            if self.delivery_known() {
                body.push(self.deliver_section(&l, window, cx));
            }
        }
        div()
            .id("hermes-job-sheet")
            .role(Role::Form)
            .aria_label(SharedString::from(title))
            .w_full()
            .flex()
            .flex_col()
            .gap(px(16.))
            .on_key_down(cx.listener(|this, e: &gpui_kit::KeyDownEvent, window, cx| {
                let k = &e.keystroke;
                if k.key == "enter" && k.modifiers.platform {
                    this.save(window, cx);
                    cx.stop_propagation();
                }
            }))
            .children(body)
            .when_some(self.error.clone(), |d, e| {
                d.child(forms::form_error_answered(
                    "hermes-job-error",
                    e,
                    self.refusals,
                    cx,
                ))
            })
            .child(
                div()
                    .text_size(px(t.metrics.small))
                    .line_height(relative(1.35))
                    .text_color(t.roles.text_subtle),
            )
    }
}

#[cfg(test)]
mod tests {
    use gpui_kit::VisualTestContext;
    use serde_json::json;

    use super::*;
    use crate::views::sheet::bench::bench;

    fn list(active: &str) -> conduit_protocol::HermesConnections {
        serde_json::from_value(json!({
            "enabled": true,
            "activeId": active,
            "connection": format!("0a1b2c3d:{active}"),
            "connections": [
                {"id": "a", "name": "Potting shed", "baseUrl": "http://127.0.0.1:20401",
                 "mode": "desktop", "active": active == "a"},
                {"id": "b", "name": "Greenhouse", "baseUrl": "http://127.0.0.1:20402",
                 "mode": "desktop", "active": active == "b"},
            ],
        }))
        .unwrap()
    }

    fn job(name: &str) -> HermesJobDto {
        serde_json::from_value(json!({
            "id": "j1", "name": name, "prompt": "Water the seedlings", "schedule": "0 9 * * *",
        }))
        .unwrap()
    }

    fn jobs(name: &str) -> conduit_protocol::HermesJobs {
        serde_json::from_value(json!({"jobs": [serde_json::to_value(job(name)).unwrap()]})).unwrap()
    }

    fn use_connection(stores: &Stores, vcx: &mut VisualTestContext, id: &str) {
        stores
            .hermes_admin
            .update(vcx, |a, cx| a.adopt_connections(list(id), cx));
        vcx.run_until_parked();
    }

    fn open_job(stores: &Stores, vcx: &mut VisualTestContext) -> Entity<HermesJobSheet> {
        let s = stores.clone();
        vcx.update(|window, cx| open(&s, Some(job("Morning watering")), window, cx));
        vcx.run_until_parked();
        vcx.update(|_, cx| sheet::current::<HermesJobSheet>(cx))
            .expect("the editor opens")
    }

    fn on_sheet(
        vcx: &mut VisualTestContext,
        sheet: &Entity<HermesJobSheet>,
        f: impl FnOnce(&mut HermesJobSheet, &mut Window, &mut Context<HermesJobSheet>),
    ) {
        vcx.update(|_, cx| {
            let window = sheet::current_window(cx).expect("the sheet's window");
            let _ = window.update(cx, |_, window, cx| {
                sheet.update(cx, |s, cx| f(s, window, cx))
            });
        });
    }

    /// A prompt typed into the editor makes Quit ask before it goes.
    #[gpui_kit::test]
    fn a_typed_prompt_makes_quit_ask(cx: &mut gpui_kit::TestAppContext) {
        let (_daemon, stores, vcx) = bench(cx);
        use_connection(&stores, vcx, "a");
        let sheet = open_job(&stores, vcx);
        vcx.update(|_, cx| assert!(!sheet::has_unsaved(cx)));
        on_sheet(vcx, &sheet, |s, w, cx| {
            s.prompt.update(cx, |i, cx| {
                i.set_value("Water the seedlings and the herbs", w, cx)
            })
        });
        vcx.update(|_, cx| assert!(sheet::has_unsaved(cx), "Quit would drop the prompt"));
    }

    /// Save with the Prompt empty: the Prompt takes the focus, and its error
    /// is said with the field's name.
    #[gpui_kit::test]
    fn an_empty_prompt_is_named_and_focused(cx: &mut gpui_kit::TestAppContext) {
        use conduit_components::announce::AnnouncementLog;
        use gpui_kit::Focusable as _;
        let (_daemon, stores, vcx) = bench(cx);
        vcx.update(|_, cx| AnnouncementLog::install(cx));
        use_connection(&stores, vcx, "a");
        let sheet = open_job(&stores, vcx);
        let l = L10n::new("en");
        let named = format!(
            "{}, {}",
            l.hermes_job_prompt_label(),
            l.required_field_helper()
        );
        on_sheet(vcx, &sheet, |s, w, cx| {
            s.prompt.update(cx, |i, cx| i.set_value("", w, cx))
        });
        // Saved twice with nothing changed, the focus moved away between:
        // each refusal is heard, and each takes the focus to the Prompt.
        for round in 1..=2 {
            on_sheet(vcx, &sheet, |s, w, cx| {
                s.name.update(cx, |i, cx| i.focus(w, cx));
                s.save(w, cx);
            });
            vcx.update(|_, cx| {
                if let Some(handle) = sheet::current_window(cx) {
                    let _ = handle.update(cx, |_, window, cx| window.draw(cx).clear(cx));
                }
            });
            vcx.run_until_parked();
            let heard = vcx.update(|_, cx| {
                AnnouncementLog::texts(cx)
                    .iter()
                    .filter(|t| t.as_ref() == named)
                    .count()
            });
            assert_eq!(heard, round, "Save {round} was not heard");
            on_sheet(vcx, &sheet, |s, w, cx| {
                assert!(
                    s.prompt.read(cx).focus_handle(cx).is_focused(w),
                    "Save {round} did not take the focus to the Prompt"
                );
            });
        }
    }

    /// Save refused by the daemon for a field: that field takes the focus,
    /// as a refusal here does, and each refusal is heard.
    #[gpui_kit::test]
    fn a_field_the_daemon_refuses_takes_the_focus(cx: &mut gpui_kit::TestAppContext) {
        use conduit_components::announce::AnnouncementLog;
        use gpui_kit::Focusable as _;
        let (daemon, stores, vcx) = bench(cx);
        vcx.update(|_, cx| AnnouncementLog::install(cx));
        use_connection(&stores, vcx, "a");
        daemon.on::<methods::HermesSaveJob>(|_| {
            let mut e = conduit_daemon::RpcError::internal("the schedule is not one");
            e.args.insert("field".into(), "schedule".into());
            e.args.insert("reason".into(), "invalidSchedule".into());
            Err(e)
        });
        let sheet = open_job(&stores, vcx);
        let refused = L10n::new("en").hermes_job_schedule_invalid();
        for round in 1..=2 {
            on_sheet(vcx, &sheet, |s, w, cx| {
                s.name.update(cx, |i, cx| i.focus(w, cx));
                s.save(w, cx);
            });
            vcx.run_until_parked();
            vcx.update(|_, cx| {
                if let Some(handle) = sheet::current_window(cx) {
                    let _ = handle.update(cx, |_, window, cx| window.draw(cx).clear(cx));
                }
            });
            vcx.run_until_parked();
            on_sheet(vcx, &sheet, |s, w, cx| {
                assert!(
                    s.schedule.read(cx).focus_handle(cx).is_focused(w),
                    "refusal {round} did not take the focus to the schedule"
                );
            });
            let heard = vcx.update(|_, cx| {
                AnnouncementLog::texts(cx)
                    .iter()
                    .filter(|t| t.as_ref() == refused)
                    .count()
            });
            assert_eq!(heard, round, "refusal {round} was not heard");
        }
    }

    /// Words typed while a Save is out stay in the editor, still to save.
    #[gpui_kit::test]
    fn words_typed_during_a_save_stay(cx: &mut gpui_kit::TestAppContext) {
        let (daemon, stores, vcx) = bench(cx);
        use_connection(&stores, vcx, "a");
        daemon.returns::<methods::HermesSaveJob>(jobs("Evening watering"));
        let held = daemon.hold::<methods::HermesSaveJob>();
        let sheet = open_job(&stores, vcx);
        on_sheet(vcx, &sheet, |s, w, cx| {
            s.name
                .update(cx, |i, cx| i.set_value("Evening watering", w, cx));
            s.save(w, cx);
            s.prompt.update(cx, |i, cx| {
                i.set_value("Water the seedlings at dusk", w, cx)
            });
        });
        drop(held);
        vcx.run_until_parked();
        vcx.update(|_, cx| {
            assert!(
                sheet::current::<HermesJobSheet>(cx).is_some_and(|b| b == sheet),
                "the editor closed with words not saved"
            );
            assert!(
                sheet::has_unsaved(cx),
                "the words typed later count as saved"
            );
        });
    }

    /// Delete… confirmed after another connection came into use deletes
    /// nothing there.
    #[gpui_kit::test]
    fn a_delete_confirmed_after_a_switch_sends_nothing(cx: &mut gpui_kit::TestAppContext) {
        let (daemon, stores, vcx) = bench(cx);
        vcx.update(|_, cx| cx.set_global(crate::shell::sheet::AutoAnswer(Some(true))));
        use_connection(&stores, vcx, "a");
        let s = stores.clone();
        vcx.update(|window, cx| {
            crate::views::panes::hermes_jobs::confirm_delete(&s, "j1", window, cx);
            s.hermes_admin
                .update(cx, |a, cx| a.adopt_connections(list("b"), cx));
        });
        vcx.run_until_parked();
        assert!(
            daemon.calls::<methods::HermesDeleteJob>().is_empty(),
            "the delete went to the connection in use now"
        );
    }

    /// A new job saved while more was typed: the editor saves to the job
    /// the daemon says it made, even when another app made one meanwhile,
    /// never making a second.
    #[gpui_kit::test]
    fn a_new_job_saves_again_to_the_job_it_made(cx: &mut gpui_kit::TestAppContext) {
        let (daemon, stores, vcx) = bench(cx);
        use_connection(&stores, vcx, "a");
        daemon.returns::<methods::HermesSaveJob>(
            serde_json::from_value(json!({
                "jobs": [
                    {"id": "j-other", "name": "Made elsewhere", "prompt": "x", "schedule": "0 6 * * *"},
                    {"id": "j-new", "name": "Evening watering", "prompt": "Water", "schedule": "0 9 * * *"},
                ],
                "savedId": "j-new",
            }))
            .unwrap(),
        );
        let held = daemon.hold::<methods::HermesSaveJob>();
        let s = stores.clone();
        vcx.update(|window, cx| open(&s, None, window, cx));
        vcx.run_until_parked();
        let sheet = vcx
            .update(|_, cx| sheet::current::<HermesJobSheet>(cx))
            .expect("the editor opens");
        on_sheet(vcx, &sheet, |s, w, cx| {
            s.name
                .update(cx, |i, cx| i.set_value("Evening watering", w, cx));
            s.prompt.update(cx, |i, cx| i.set_value("Water", w, cx));
            s.save(w, cx);
            s.prompt.update(cx, |i, cx| {
                i.set_value("Water the seedlings at dusk", w, cx)
            });
        });
        held.release();
        vcx.run_until_parked();
        on_sheet(vcx, &sheet, |s, w, cx| s.save(w, cx));
        vcx.run_until_parked();
        let saves = daemon.calls::<methods::HermesSaveJob>();
        assert_eq!(saves.len(), 2);
        assert_eq!(
            saves[1]["id"],
            json!("j-new"),
            "the second Save made another job"
        );
    }

    fn type_and_save_held(
        daemon: &crate::stores::rpc::fake::FakeDaemon,
        stores: &Stores,
        vcx: &mut VisualTestContext,
        answer: serde_json::Value,
    ) -> Entity<HermesJobSheet> {
        daemon.returns::<methods::HermesSaveJob>(serde_json::from_value(answer).unwrap());
        let held = daemon.hold::<methods::HermesSaveJob>();
        let s = stores.clone();
        vcx.update(|window, cx| open(&s, None, window, cx));
        vcx.run_until_parked();
        let sheet = vcx
            .update(|_, cx| sheet::current::<HermesJobSheet>(cx))
            .expect("the editor opens");
        on_sheet(vcx, &sheet, |s, w, cx| {
            s.name
                .update(cx, |i, cx| i.set_value("Evening watering", w, cx));
            s.prompt.update(cx, |i, cx| i.set_value("Water", w, cx));
            s.save(w, cx);
            s.prompt.update(cx, |i, cx| {
                i.set_value("Water the seedlings at dusk", w, cx)
            });
        });
        held.release();
        vcx.run_until_parked();
        sheet
    }

    /// The job a save names is the one saved to next, even when the list
    /// that came with the answer does not have it yet.
    #[gpui_kit::test]
    fn a_new_job_named_but_not_listed_is_saved_to_again(cx: &mut gpui_kit::TestAppContext) {
        let (daemon, stores, vcx) = bench(cx);
        use_connection(&stores, vcx, "a");
        let sheet = type_and_save_held(
            &daemon,
            &stores,
            vcx,
            json!({"jobs": [], "savedId": "j-new"}),
        );
        on_sheet(vcx, &sheet, |s, w, cx| s.save(w, cx));
        vcx.run_until_parked();
        let saves = daemon.calls::<methods::HermesSaveJob>();
        assert_eq!(saves.len(), 2);
        assert_eq!(
            saves[1]["id"],
            json!("j-new"),
            "the second Save made another job"
        );
    }

    /// A save that names no job is never followed by another create: the
    /// editor keeps the words and says so, and Save sends nothing more.
    #[gpui_kit::test]
    fn a_new_job_saved_without_its_id_is_not_made_again(cx: &mut gpui_kit::TestAppContext) {
        let (daemon, stores, vcx) = bench(cx);
        use_connection(&stores, vcx, "a");
        let sheet = type_and_save_held(&daemon, &stores, vcx, json!({"jobs": []}));
        on_sheet(vcx, &sheet, |s, w, cx| s.save(w, cx));
        vcx.run_until_parked();
        assert_eq!(
            daemon.calls::<methods::HermesSaveJob>().len(),
            1,
            "a second Save made another job"
        );
        vcx.update(|_, cx| {
            assert!(sheet.read(cx).error.is_some(), "the editor says nothing");
            assert!(sheet::has_unsaved(cx), "the words typed later are dropped");
        });
    }

    /// A job whose delivery routes could not be read is saved without any
    /// delivery choice: the routes stored stay as they are.
    #[gpui_kit::test]
    fn unread_delivery_routes_are_never_replaced(cx: &mut gpui_kit::TestAppContext) {
        let (daemon, stores, vcx) = bench(cx);
        use_connection(&stores, vcx, "a");
        stores.hermes_admin.update(vcx, |a, cx| {
            a.adopt_jobs(
                serde_json::from_value(json!({"jobs": [], "scheduling": true})).unwrap(),
                cx,
            )
        });
        daemon.returns::<methods::HermesSaveJob>(jobs("Seed report"));
        daemon.returns::<methods::HermesJobsDelivery>(
            serde_json::from_value(json!({"available": true, "options": []})).unwrap(),
        );
        let unread: HermesJobDto = serde_json::from_value(json!({
            "id": "j1", "name": "Seed report", "prompt": "Report", "schedule": "0 6 * * *",
            "deliveryKnown": false,
        }))
        .unwrap();
        let s = stores.clone();
        vcx.update(|window, cx| open(&s, Some(unread), window, cx));
        vcx.run_until_parked();
        let sheet = vcx
            .update(|_, cx| sheet::current::<HermesJobSheet>(cx))
            .expect("the editor opens");
        on_sheet(vcx, &sheet, |s, w, cx| {
            s.toggle_target("telegram", cx);
            s.prompt
                .update(cx, |i, cx| i.set_value("Report the seed stock", w, cx));
            s.save(w, cx);
        });
        vcx.run_until_parked();
        let saves = daemon.calls::<methods::HermesSaveJob>();
        assert_eq!(saves.len(), 1);
        assert_eq!(
            saves[0]["deliver"],
            json!(null),
            "a delivery replacement was sent"
        );
    }

    /// An editor opened for one connection's job saves nothing once
    /// another connection is in use.
    #[gpui_kit::test]
    fn a_job_is_saved_only_to_its_own_connection(cx: &mut gpui_kit::TestAppContext) {
        let (daemon, stores, vcx) = bench(cx);
        use_connection(&stores, vcx, "a");
        daemon.returns::<methods::HermesSaveJob>(jobs("Evening watering"));
        let sheet = open_job(&stores, vcx);
        on_sheet(vcx, &sheet, |s, w, cx| {
            s.name
                .update(cx, |i, cx| i.set_value("Evening watering", w, cx))
        });
        use_connection(&stores, vcx, "b");
        on_sheet(vcx, &sheet, |s, w, cx| s.save(w, cx));
        vcx.run_until_parked();
        assert!(
            daemon.calls::<methods::HermesSaveJob>().is_empty(),
            "the job was saved to the connection in use now"
        );
    }
}
