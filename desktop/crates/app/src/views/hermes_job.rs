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
use conduit_components::views::focus::{RadioGroupExt as _, radio_option_id};
use conduit_components::views::kit::{Button, grouped_section, radio_dot};
use conduit_protocol::{
    HermesDeliveryOptions, HermesDeliveryTargetDto, HermesJobDto, HermesJobEdit, NoParams,
    NoticeLevel, methods,
};
use gpui_kit::component::input::{InputEvent, InputState, Textarea, TextareaState};
use gpui_kit::prelude::*;
use gpui_kit::{
    AnyElement, App, AsyncApp, Context, ElementId, Entity, FontWeight, Role, SharedString,
    Subscription, WeakEntity, Window, div, px, relative,
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
    /// The daemon refused a field: which, and why.
    pub refused: Option<(String, FieldError)>,
    pub busy: bool,
    pub error: Option<String>,
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
            refused: None,
            busy: false,
            error: None,
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

    pub fn save(&mut self, _: &mut Window, cx: &mut Context<Self>) {
        if self.busy {
            return;
        }
        if self.errors(cx).iter().any(Option::is_some) {
            self.show_errors = true;
            cx.notify();
            return;
        }
        let (name, prompt, schedule) = self.values(cx);
        let editing = self.job.is_some();
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
            id: self.job.as_ref().map(|j| j.id.clone()),
            name: Some(name),
            prompt,
            schedule,
            deliver: (self.scheduling && deliver_changed).then(|| self.deliver.join(",")),
            catch_up: (self.scheduling && catch_up_changed)
                .then(|| CATCH_UP[self.catch_up].to_string()),
        };
        let call = self
            .stores
            .connection
            .read(cx)
            .rpc()
            .call::<methods::HermesSaveJob>(&edit);
        self.busy = true;
        self.error = None;
        cx.notify();
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result = call.await;
            let _ = this.update(cx, |s, cx| {
                s.busy = false;
                let l = cx.l10n().clone();
                match result {
                    Ok(jobs) => {
                        s.stores
                            .hermes_admin
                            .update(cx, |a, cx| a.adopt_jobs(jobs, cx));
                        let text = if editing {
                            l.hermes_job_updated()
                        } else {
                            l.hermes_job_created()
                        };
                        s.stores
                            .toasts
                            .update(cx, |t, cx| t.show(NoticeLevel::Success, text, cx));
                        sheet::dismiss(cx);
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
                        }
                        _ => {
                            log::info!("hermes.saveJob: {e}");
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
        })
        .detach();
    }

    /// Ticks or clears delivery target `target`; the last one stays.
    pub fn toggle_target(&mut self, target: &str, cx: &mut Context<Self>) {
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
                .disabled(self.busy)
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
                        .child(e),
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
                    forms::field(
                        l.name(),
                        &self.name,
                        None,
                        self.error_text(name_error, &l),
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
                    forms::field(
                        l.hermes_job_schedule_label(),
                        &self.schedule,
                        Some(l.hermes_job_schedule_help().into()),
                        self.error_text(schedule_error, &l),
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
            body.push(self.deliver_section(&l, window, cx));
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
                d.child(forms::form_error("hermes-job-error", e, cx))
            })
            .child(
                div()
                    .text_size(px(t.metrics.small))
                    .line_height(relative(1.35))
                    .text_color(t.roles.text_subtle),
            )
    }
}
