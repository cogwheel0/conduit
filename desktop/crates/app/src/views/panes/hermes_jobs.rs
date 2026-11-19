//! Hermes's Scheduled Agents: the connection's cron jobs, as the phone's
//! `hermes_jobs_page.dart` lists them. Each job's card says its name, its
//! schedule (in words, and as written when the words leave it out), and
//! on a Desktop Gateway where it delivers, when it ran and runs next,
//! whether a run is going (Running Now, Stopping…) or how the last one
//! ended. Its switch pauses or resumes it; Run Now, Stop, Edit… and
//! Delete… (asked first) act on it; Run History lists the chats its runs
//! wrote, each opening as a Hermes chat. New Scheduled Job… opens the
//! editor ([`crate::views::hermes_job`]). A server that does not let jobs
//! be changed lists them read-only.
//!
//! The list is polled while the pane shows ([`crate::stores::hermes_admin`]).

use std::rc::Rc;

use chrono::Local;
use conduit_components::ActiveConduitTheme as _;
use conduit_components::assets::{IconName, icon};
use conduit_components::theme::ConduitTheme;
use conduit_components::views::kit::{Button, Switch, raised_fill};
use conduit_protocol::{
    HermesCadenceDto, HermesCadenceKind, HermesJobDto, HermesJobRef, HermesJobToggle, NoticeLevel,
    methods,
};
use gpui_kit::prelude::*;
use gpui_kit::{
    AnyElement, App, AsyncApp, ElementId, FontWeight, Role, SharedString, Window, div, px, relative,
};

use crate::l10n::{ActiveL10n as _, L10n};
use crate::shell::sheet::{SheetSpec, present_sheet};
use crate::stores::Stores;
use crate::stores::hermes_admin::{self, Loaded};
use crate::stores::navigation::AreaItem;
use crate::views::dates::{self, Form};

/// The Scheduled Agents page.
pub fn pane(stores: &Stores, cx: &mut App) -> AnyElement {
    let t = cx.conduit().clone();
    let l = cx.l10n().clone();
    let admin = stores.hermes_admin.read(cx);
    let jobs = admin.jobs.clone();
    let busy = admin.busy.clone();
    let runs_open = admin.runs_open.clone();
    let runs = admin.runs.clone();
    let mut body: Vec<AnyElement> = vec![];
    match &jobs {
        None | Some(Loaded::Loading) => {
            body.push(note("hermes-jobs-loading", l.loading_short(), &t))
        }
        Some(Loaded::Failed(_)) => {
            let store = stores.hermes_admin.downgrade();
            body.push(note("hermes-jobs-failed", l.hermes_job_load_failed(), &t));
            body.push(
                div()
                    .flex()
                    .justify_center()
                    .child(
                        Button::new("hermes-jobs-retry", l.desktop_try_again()).on_click(Rc::new(
                            move |_, _, cx| {
                                let _ = store.update(cx, |a, cx| a.refresh_jobs(cx));
                            },
                        )),
                    )
                    .into_any_element(),
            );
        }
        Some(Loaded::Ready(list)) => {
            body.push(header(stores, list.writable, &l, &t));
            if list.jobs.is_empty() {
                body.push(note(
                    "hermes-jobs-empty",
                    format!(
                        "{}\n{}",
                        l.hermes_no_schedules_yet(),
                        l.hermes_job_empty_message()
                    ),
                    &t,
                ));
            } else {
                let count = list.jobs.len();
                let cards: Vec<AnyElement> = list
                    .jobs
                    .iter()
                    .enumerate()
                    .map(|(ix, job)| {
                        card(
                            stores,
                            job,
                            CardState {
                                writable: list.writable,
                                scheduling: list.scheduling,
                                busy: busy.contains(&job.id),
                                runs_open: runs_open.contains(&job.id),
                                runs: runs.get(&job.id),
                                last: ix + 1 == count,
                            },
                            &l,
                            &t,
                        )
                    })
                    .collect();
                body.push(
                    div()
                        .id("hermes-jobs-list")
                        .role(Role::List)
                        .aria_label(SharedString::from(l.hermes_scheduled_agents_title()))
                        .w_full()
                        .rounded(px(10.))
                        .border_1()
                        .border_color(t.roles.border)
                        .bg(raised_fill(&t))
                        .overflow_hidden()
                        .flex()
                        .flex_col()
                        .children(cards)
                        .into_any_element(),
                );
                if list.scheduling {
                    body.push(
                        div()
                            .px(px(12.))
                            .text_size(px(t.metrics.small))
                            .text_color(t.roles.text_subtle)
                            .child(l.desktop_hermes_jobs_note())
                            .into_any_element(),
                    );
                }
            }
        }
    }
    div()
        .id("area-pane-body")
        .role(Role::Group)
        .aria_label(SharedString::from(l.hermes_scheduled_agents_title()))
        .flex_1()
        .min_h_0()
        .overflow_y_scroll()
        .flex()
        .flex_col()
        .items_center()
        .px(px(32.))
        .pt(px(12.))
        .pb(px(32.))
        .child(
            div()
                .w_full()
                .max_w(px(640.))
                .flex()
                .flex_col()
                .gap(px(10.))
                .children(body),
        )
        .into_any_element()
}

fn note(id: &'static str, text: String, t: &ConduitTheme) -> AnyElement {
    div()
        .id(id)
        .role(Role::Status)
        .aria_label(SharedString::from(text.clone()))
        .w_full()
        .py(px(24.))
        .text_center()
        .text_size(px(t.metrics.small))
        .line_height(relative(1.45))
        .text_color(t.roles.text_subtle)
        .child(SharedString::from(text))
        .into_any_element()
}

fn header(stores: &Stores, writable: bool, l: &L10n, t: &ConduitTheme) -> AnyElement {
    let new_job = {
        let stores = stores.clone();
        Button::new("hermes-job-new", l.desktop_hermes_job_new_ellipsis())
            .icon(IconName::Plus)
            .primary()
            .disabled(!writable)
            .on_click(Rc::new(move |_, window, cx| {
                crate::views::hermes_job::open(&stores, None, window, cx)
            }))
    };
    div()
        .w_full()
        .flex()
        .items_center()
        .gap(px(12.))
        .child(
            div()
                .flex_1()
                .min_w_0()
                .text_size(px(t.metrics.small))
                .line_height(relative(1.4))
                .text_color(t.roles.text_subtle)
                .when(!writable, |d| d.child(l.hermes_job_admin_disabled())),
        )
        .child(new_job)
        .into_any_element()
}

struct CardState<'a> {
    writable: bool,
    scheduling: bool,
    busy: bool,
    runs_open: bool,
    runs: Option<&'a Loaded<Vec<conduit_protocol::HermesSessionDto>>>,
    last: bool,
}

/// A job's schedule in this language, from what core read of its cron
/// (`scheduleText` is the English): the time of day as this Mac writes it.
/// None for a cadence this build doesn't know.
pub fn cadence_text(c: &HermesCadenceDto, l: &L10n) -> Option<String> {
    let at = || {
        let (hour, minute) = (c.hour.unwrap_or(0), c.minute.unwrap_or(0));
        time_of_day(hour as u32, minute as u32, l.locale())
    };
    let past = || format!("{:02}", c.minute.unwrap_or(0));
    let every = c.every.unwrap_or(2);
    Some(match c.kind {
        HermesCadenceKind::None => l.desktop_hermes_cadence_none(),
        HermesCadenceKind::EveryMinute => l.desktop_hermes_cadence_every_minute(),
        HermesCadenceKind::EveryMinutes => l.desktop_hermes_cadence_every_minutes(every),
        HermesCadenceKind::EveryHour if c.minute.unwrap_or(0) == 0 => {
            l.desktop_hermes_cadence_every_hour()
        }
        HermesCadenceKind::EveryHour => l.desktop_hermes_cadence_every_hour_at(&past()),
        HermesCadenceKind::EveryHours if c.minute.unwrap_or(0) == 0 => {
            l.desktop_hermes_cadence_every_hours(every)
        }
        HermesCadenceKind::EveryHours => l.desktop_hermes_cadence_every_hours_at(every, &past()),
        HermesCadenceKind::Daily => l.desktop_hermes_cadence_daily(&at()),
        HermesCadenceKind::Weekdays => l.desktop_hermes_cadence_weekdays(&at()),
        HermesCadenceKind::Weekends => l.desktop_hermes_cadence_weekends(&at()),
        HermesCadenceKind::Weekly => {
            let day = c.weekday.unwrap_or(0).rem_euclid(7).to_string();
            l.desktop_hermes_cadence_weekly(&day, &at())
        }
        HermesCadenceKind::Monthly => l.desktop_hermes_cadence_monthly(c.day.unwrap_or(1), &at()),
        HermesCadenceKind::Unknown => return None,
    })
}

/// `hour`:`minute` as this Mac writes a time of day in `locale`.
fn time_of_day(hour: u32, minute: u32, locale: &str) -> String {
    use chrono::TimeZone as _;
    let ms = chrono::Local
        .with_ymd_and_hms(2026, 1, 15, hour.min(23), minute.min(59), 0)
        .earliest()
        .map_or(0, |t| t.timestamp_millis());
    dates::format(ms, Form::Time, locale)
}

/// A time as a job card says it: the day and month, then the time.
fn when(ms: i64, l: &L10n) -> String {
    let locale = l.locale();
    format!(
        "{} {}",
        dates::format(ms, Form::DayMonth, locale),
        dates::format(ms, Form::Time, locale)
    )
}

/// A delivery target as a card names it ("Bot Chat: Helper").
pub fn target_label(target: &conduit_protocol::HermesDeliveryTargetDto, l: &L10n) -> String {
    match target.kind.as_str() {
        "local" => l.hermes_job_deliver_local(),
        "botChat" => l.hermes_job_deliver_bot_chat(&target.name),
        "room" => l.hermes_job_deliver_group_chat(&target.name),
        "other" => target.target.clone(),
        _ => target.name.clone(),
    }
}

/// Hermes's word for a job's state, in the app's.
fn state_label(job: &HermesJobDto, l: &L10n) -> String {
    match job.state.as_deref() {
        Some("scheduled") => l.desktop_hermes_job_state_scheduled(),
        Some("paused") => l.hermes_job_paused(),
        Some("completed") => l.desktop_hermes_job_state_completed(),
        Some(other) if !other.trim().is_empty() => other.to_string(),
        _ if job.enabled => l.desktop_hermes_job_state_scheduled(),
        _ => l.hermes_job_paused(),
    }
}

/// What the card says of the job's run: going, stopping, or how the last
/// one ended (and its errors).
fn run_lines(job: &HermesJobDto, l: &L10n) -> Vec<(String, Tone)> {
    let mut out = vec![];
    if job.running {
        out.push((
            if job.stopping {
                l.hermes_job_stopping()
            } else {
                l.hermes_job_running()
            },
            Tone::Live,
        ));
    } else if let Some(reason) = &job.last_cancel_reason {
        out.push((
            if reason.trim().is_empty() {
                l.hermes_job_last_cancelled_no_reason()
            } else {
                l.hermes_job_last_cancelled(reason)
            },
            Tone::Quiet,
        ));
    } else if let Some(status) = job.last_status.as_deref().filter(|s| !s.trim().is_empty()) {
        out.push((
            match status {
                "ok" | "success" | "completed" => l.desktop_hermes_job_last_ok(),
                "error" | "failed" => l.desktop_hermes_job_last_failed(),
                other => other.to_string(),
            },
            Tone::Quiet,
        ));
    }
    if let Some(error) = job.last_error.as_deref().filter(|e| !e.trim().is_empty()) {
        out.push((error.to_string(), Tone::Danger));
    }
    if let Some(error) = job
        .last_delivery_error
        .as_deref()
        .filter(|e| !e.trim().is_empty())
    {
        out.push((l.desktop_hermes_job_delivery_error(error), Tone::Danger));
    }
    out
}

#[derive(Clone, Copy)]
enum Tone {
    Live,
    Quiet,
    Danger,
}

fn card(
    stores: &Stores,
    job: &HermesJobDto,
    state: CardState,
    l: &L10n,
    t: &ConduitTheme,
) -> AnyElement {
    let r = t.roles;
    let name = job
        .name
        .clone()
        .filter(|n| !n.trim().is_empty())
        .unwrap_or_else(|| job.prompt.lines().next().unwrap_or_default().to_string());
    let id = job.id.clone();
    let schedule = job
        .cadence
        .as_ref()
        .and_then(|c| cadence_text(c, l))
        .or_else(|| job.schedule_text.clone())
        .filter(|s| !s.trim().is_empty())
        .unwrap_or_else(|| job.schedule.clone());
    let raw = (schedule != job.schedule).then(|| job.schedule.clone());
    let toggle = {
        let stores = stores.clone();
        let id = id.clone();
        let enabled = job.enabled;
        Switch::new(
            ElementId::Name(format!("hermes-job-enabled-{id}").into()),
            name.clone(),
            enabled,
        )
        .disabled(!state.writable || state.busy)
        .on_click(Rc::new(move |_, _, cx| {
            set_enabled(&stores, &id, !enabled, cx)
        }))
    };
    let mut facts: Vec<String> = vec![];
    if state.scheduling {
        facts.push(format!(
            "{}: {}",
            l.hermes_job_state_label(),
            state_label(job, l)
        ));
        let deliver: Vec<String> = job.deliver.iter().map(|d| target_label(d, l)).collect();
        if !deliver.is_empty() {
            facts.push(format!(
                "{}: {}",
                l.hermes_job_delivery_label(),
                deliver.join(", ")
            ));
        }
    }
    if let Some(ms) = job.last_run_at_ms {
        facts.push(format!("{}: {}", l.hermes_job_last_label(), when(ms, l)));
    }
    if let Some(ms) = job.next_run_at_ms.filter(|_| job.enabled) {
        facts.push(format!("{}: {}", l.hermes_job_next_label(), when(ms, l)));
    }
    let lines = run_lines(job, l);
    let spoken = {
        let mut parts = vec![name.clone(), schedule.clone()];
        if !job.enabled {
            parts.push(l.hermes_job_paused());
        }
        parts.extend(lines.iter().map(|(text, _)| text.clone()));
        parts.join(", ")
    };
    let mut actions: Vec<AnyElement> = vec![];
    if state.writable {
        let stores_run = stores.clone();
        let run_id = id.clone();
        actions.push(
            Button::new(
                ElementId::Name(format!("hermes-job-run-{id}").into()),
                l.hermes_job_run_now(),
            )
            .disabled(state.busy || job.running)
            .on_click(Rc::new(move |_, _, cx| run_now(&stores_run, &run_id, cx)))
            .into_any_element(),
        );
        if state.scheduling && (job.running || job.stopping) {
            let stores_stop = stores.clone();
            let stop_id = id.clone();
            actions.push(
                Button::new(
                    ElementId::Name(format!("hermes-job-stop-{id}").into()),
                    if job.stopping {
                        l.hermes_job_stopping()
                    } else {
                        l.hermes_job_stop()
                    },
                )
                .danger()
                .disabled(job.stopping)
                .on_click(Rc::new(move |_, _, cx| stop(&stores_stop, &stop_id, cx)))
                .into_any_element(),
            );
        }
    }
    actions.push(div().flex_1().into_any_element());
    if state.scheduling {
        let store = stores.hermes_admin.downgrade();
        let runs_id = id.clone();
        actions.push(
            Button::new(
                ElementId::Name(format!("hermes-job-history-{id}").into()),
                if state.runs_open {
                    l.desktop_hermes_job_hide_runs()
                } else {
                    l.hermes_job_run_history()
                },
            )
            .ghost()
            .icon(if state.runs_open {
                IconName::ChevronDown
            } else {
                IconName::ChevronRight
            })
            .on_click(Rc::new(move |_, _, cx| {
                let _ = store.update(cx, |a, cx| a.toggle_runs(&runs_id, cx));
            }))
            .into_any_element(),
        );
    }
    if state.writable {
        let stores_edit = stores.clone();
        let job_edit = job.clone();
        actions.push(
            Button::new(
                ElementId::Name(format!("hermes-job-edit-{id}").into()),
                l.desktop_edit_ellipsis(),
            )
            .disabled(state.busy)
            .on_click(Rc::new(move |_, window, cx| {
                crate::views::hermes_job::open(&stores_edit, Some(job_edit.clone()), window, cx)
            }))
            .into_any_element(),
        );
        let stores_delete = stores.clone();
        let delete_id = id.clone();
        actions.push(
            Button::new(
                ElementId::Name(format!("hermes-job-delete-{id}").into()),
                l.desktop_delete_ellipsis(),
            )
            .disabled(state.busy)
            .on_click(Rc::new(move |_, window, cx| {
                confirm_delete(&stores_delete, &delete_id, window, cx)
            }))
            .into_any_element(),
        );
    }
    let history = state
        .runs_open
        .then(|| run_history(stores, state.runs, l, t));
    div()
        .id(ElementId::Name(format!("hermes-job-{id}").into()))
        .role(Role::ListItem)
        .aria_label(SharedString::from(spoken))
        .w_full()
        .px(px(14.))
        .py(px(12.))
        .flex()
        .flex_col()
        .gap(px(6.))
        .when(!state.last, |d| d.border_b_1().border_color(r.border))
        .child(
            div()
                .flex()
                .items_start()
                .gap(px(10.))
                .child(
                    div()
                        .flex_1()
                        .min_w_0()
                        .flex()
                        .flex_col()
                        .gap(px(3.))
                        .child(
                            div()
                                .flex()
                                .items_center()
                                .gap(px(8.))
                                .child(
                                    div()
                                        .min_w_0()
                                        .truncate()
                                        .text_size(px(t.metrics.control + 1.))
                                        .font_weight(FontWeight::SEMIBOLD)
                                        .text_color(r.text)
                                        .child(SharedString::from(name.clone())),
                                )
                                .when(!job.enabled, |d| {
                                    d.child(
                                        div()
                                            .px(px(6.))
                                            .py(px(1.))
                                            .rounded(px(4.))
                                            .bg(conduit_components::theme::with_alpha(r.text, 0.08))
                                            .text_size(px(t.metrics.small - 1.))
                                            .text_color(r.text_subtle)
                                            .child(l.hermes_job_paused()),
                                    )
                                }),
                        )
                        .child(
                            div()
                                .flex()
                                .items_center()
                                .gap(px(5.))
                                .text_size(px(t.metrics.small))
                                .text_color(r.text_subtle)
                                .child(icon(IconName::Clock, 12., r.text_subtle))
                                .child(SharedString::from(schedule.clone()))
                                .when_some(raw, |d, raw| {
                                    d.child(
                                        div()
                                            .font_family(conduit_components::theme::MONO_FONT)
                                            .child(SharedString::from(format!("· {raw}"))),
                                    )
                                }),
                        ),
                )
                .child(toggle),
        )
        .when(!facts.is_empty(), |d| {
            d.child(
                div()
                    .text_size(px(t.metrics.small))
                    .line_height(relative(1.4))
                    .text_color(r.text_subtle)
                    .child(SharedString::from(facts.join("  ·  "))),
            )
        })
        .children(lines.into_iter().map(|(text, tone)| {
            let color = match tone {
                Tone::Live => r.success,
                Tone::Quiet => r.text_subtle,
                Tone::Danger => r.danger,
            };
            div()
                .text_size(px(t.metrics.small))
                .line_height(relative(1.4))
                .text_color(conduit_components::theme::legible_text(
                    color,
                    r.text,
                    raised_fill(t),
                    4.5,
                ))
                .when(matches!(tone, Tone::Live), |d| {
                    d.font_weight(FontWeight::SEMIBOLD)
                })
                .child(SharedString::from(text))
        }))
        .child(
            div()
                .pt(px(4.))
                .flex()
                .flex_wrap()
                .items_center()
                .gap(px(8.))
                .children(actions),
        )
        .children(history)
        .into_any_element()
}

fn run_history(
    stores: &Stores,
    runs: Option<&Loaded<Vec<conduit_protocol::HermesSessionDto>>>,
    l: &L10n,
    t: &ConduitTheme,
) -> AnyElement {
    let r = t.roles;
    let now = Local::now();
    let rows: Vec<AnyElement> = match runs {
        None | Some(Loaded::Loading) => vec![quiet(l.loading_short(), t)],
        Some(Loaded::Failed(_)) => vec![quiet(l.desktop_hermes_job_runs_failed(), t)],
        Some(Loaded::Ready(runs)) if runs.is_empty() => {
            vec![quiet(l.desktop_hermes_job_no_runs(), t)]
        }
        Some(Loaded::Ready(runs)) => runs
            .iter()
            .map(|run| {
                let title = if run.title.trim().is_empty() {
                    l.hermes_session_untitled()
                } else {
                    run.title.clone()
                };
                let stamp = run.updated_at_ms.map(|ms| dates::stamp(ms, &now, l));
                let open_stores = stores.clone();
                let session = run.id.clone();
                let spoken = match &stamp {
                    Some((_, long)) => format!("{title}, {long}"),
                    None => title.clone(),
                };
                div()
                    .id(ElementId::Name(
                        format!("hermes-job-run-row-{}", run.id).into(),
                    ))
                    .role(Role::Button)
                    .aria_label(SharedString::from(spoken))
                    .w_full()
                    .px(px(8.))
                    .py(px(5.))
                    .flex()
                    .items_center()
                    .gap(px(8.))
                    .rounded(px(6.))
                    .cursor_pointer()
                    .hover(|s| s.bg(r.hover))
                    .active(|s| s.bg(conduit_components::views::focus::pressed_fill(r.hover, t)))
                    .tip(l.desktop_hermes_job_open_run(), None)
                    .child(icon(IconName::MessageSquare, 13., r.text_subtle))
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .truncate()
                            .text_size(px(t.metrics.small + 0.5))
                            .text_color(r.text)
                            .child(SharedString::from(title)),
                    )
                    .when_some(stamp, |d, (short, _)| {
                        d.child(
                            div()
                                .text_size(px(t.metrics.small))
                                .text_color(r.text_subtle)
                                .child(SharedString::from(short)),
                        )
                    })
                    .on_click(move |_, _, cx| {
                        let item = AreaItem::HermesSession(session.clone());
                        open_stores
                            .navigation
                            .update(cx, |n, cx| n.open_item(item, cx));
                    })
                    .into_any_element()
            })
            .collect(),
    };
    div()
        .id("hermes-job-runs")
        .role(Role::List)
        .aria_label(SharedString::from(l.hermes_job_run_history()))
        .mt(px(2.))
        .p(px(4.))
        .rounded(px(8.))
        .bg(conduit_components::theme::with_alpha(
            r.text,
            if t.dark { 0.05 } else { 0.03 },
        ))
        .flex()
        .flex_col()
        .children(rows)
        .into_any_element()
}

fn quiet(text: String, t: &ConduitTheme) -> AnyElement {
    div()
        .px(px(8.))
        .py(px(6.))
        .text_size(px(t.metrics.small))
        .text_color(t.roles.text_subtle)
        .child(SharedString::from(text))
        .into_any_element()
}

use conduit_components::views::focus::ControlExt as _;

/// Job `id` of the connection in use, as the daemon names it: refused once
/// another is in use.
fn job_ref(stores: &Stores, id: &str, cx: &App) -> HermesJobRef {
    HermesJobRef {
        id: id.to_string(),
        connection: stores.hermes_admin.read(cx).connection(),
    }
}

fn set_enabled(stores: &Stores, id: &str, enabled: bool, cx: &mut App) {
    let rpc = stores.connection.read(cx).rpc();
    let call = rpc.call::<methods::HermesSetJobEnabled>(&HermesJobToggle {
        id: id.to_string(),
        enabled,
        connection: stores.hermes_admin.read(cx).connection(),
    });
    let l = cx.l10n().clone();
    let (failure, success) = if enabled {
        (l.hermes_job_resume_failed(), l.hermes_job_resumed())
    } else {
        (l.hermes_job_pause_failed(), l.hermes_job_paused_success())
    };
    busy_call(stores, id, call, failure, Some(success), cx);
}

fn run_now(stores: &Stores, id: &str, cx: &mut App) {
    let rpc = stores.connection.read(cx).rpc();
    let call = rpc.call::<methods::HermesRunJob>(&job_ref(stores, id, cx));
    let l = cx.l10n().clone();
    busy_call(
        stores,
        id,
        call,
        l.hermes_job_run_failed(),
        Some(l.hermes_job_started()),
        cx,
    );
}

fn stop(stores: &Stores, id: &str, cx: &mut App) {
    let rpc = stores.connection.read(cx).rpc();
    let call = rpc.call::<methods::HermesJobsStop>(&job_ref(stores, id, cx));
    let l = cx.l10n().clone();
    // Its list is taken in the order it was asked, against the polls.
    let ticket = stores.hermes_admin.update(cx, |a, _| a.ask_jobs());
    hermes_admin::act(
        stores,
        call,
        l.hermes_job_stop_failed(),
        move |a, jobs, cx| {
            a.answer_jobs(ticket, jobs, cx);
        },
        cx,
    );
}

/// An action on job `id` with its buttons waiting meanwhile; `success`
/// is said when it is done.
fn busy_call(
    stores: &Stores,
    id: &str,
    call: impl std::future::Future<
        Output = Result<conduit_protocol::HermesJobs, conduit_daemon::RpcError>,
    > + Send
    + 'static,
    failure: String,
    success: Option<String>,
    cx: &mut App,
) {
    stores
        .hermes_admin
        .update(cx, |a, cx| a.set_busy(id, true, cx));
    let generation = stores.hermes_admin.read(cx).generation();
    // Its list is taken in the order it was asked, against the polls.
    let ticket = stores.hermes_admin.update(cx, |a, _| a.ask_jobs());
    let admin = stores.hermes_admin.downgrade();
    let toasts = stores.toasts.downgrade();
    let id = id.to_string();
    cx.spawn(async move |cx: &mut AsyncApp| {
        let result = call.await;
        let _ = admin.update(cx, |a, cx| {
            // Asked under another connection (or before a reset): its mark
            // and its list are not the connection in use's.
            if !a.is_current(generation) {
                return;
            }
            a.set_busy(&id, false, cx);
            if let Ok(jobs) = &result {
                a.answer_jobs(ticket, jobs.clone(), cx);
            }
        });
        let (level, text) = match result {
            Ok(_) => match success {
                Some(text) => (NoticeLevel::Success, text),
                None => return,
            },
            Err(e) => {
                log::info!("hermes job action: {e}");
                (NoticeLevel::Error, failure)
            }
        };
        let _ = toasts.update(cx, |t, cx| t.show(level, text, cx));
    })
    .detach();
}

/// Delete…: asks, then deletes job `id`.
pub fn confirm_delete(stores: &Stores, id: &str, window: &mut Window, cx: &mut App) {
    let l = cx.l10n().clone();
    let spec = SheetSpec::new(
        l.hermes_job_delete_title(),
        l.hermes_job_delete_message(),
        l.delete(),
        l.cancel(),
    )
    .destructive();
    let ask = present_sheet(window, spec, cx);
    let stores = stores.clone();
    let id = id.to_string();
    // The job asked about is the connection in use now's.
    let opened = stores.hermes_admin.read(cx).opened();
    cx.spawn(async move |cx: &mut AsyncApp| {
        if !ask.await {
            return;
        }
        cx.update(|cx| {
            if !stores.hermes_admin.read(cx).still_in_use(&opened) {
                return;
            }
            let rpc = stores.connection.read(cx).rpc();
            let call = rpc.call::<methods::HermesDeleteJob>(&HermesJobRef {
                id: id.clone(),
                connection: opened.connection.clone(),
            });
            let l = cx.l10n().clone();
            busy_call(
                &stores,
                &id,
                call,
                l.hermes_job_delete_failed(),
                Some(l.hermes_job_deleted()),
                cx,
            );
        });
    })
    .detach();
}

#[cfg(test)]
mod tests {
    use gpui_kit::VisualTestContext;
    use serde_json::json;

    use super::*;
    use crate::views::sheet::bench::bench;

    fn use_connection(stores: &Stores, vcx: &mut VisualTestContext, id: &str) {
        let list: conduit_protocol::HermesConnections = serde_json::from_value(json!({
            "enabled": true,
            "activeId": id,
            "connection": format!("0a1b2c3d:{id}"),
            "connections": [
                {"id": "a", "name": "Potting shed", "baseUrl": "http://127.0.0.1:20401",
                 "mode": "desktop", "active": id == "a"},
                {"id": "b", "name": "Greenhouse", "baseUrl": "http://127.0.0.1:20402",
                 "mode": "desktop", "active": id == "b"},
            ],
        }))
        .unwrap();
        stores
            .hermes_admin
            .update(vcx, |a, cx| a.adopt_connections(list, cx));
        vcx.run_until_parked();
    }

    /// A Run Now answered after a newer poll does not put back its older
    /// list (the run shown going again after the poll saw it end).
    #[gpui_kit::test]
    fn a_late_action_answer_does_not_replace_a_newer_poll(cx: &mut gpui_kit::TestAppContext) {
        let (daemon, stores, vcx) = bench(cx);
        let job = |running: bool| -> conduit_protocol::HermesJobs {
            serde_json::from_value(json!({"jobs": [{
                "id": "j1", "name": "Morning watering", "prompt": "Water",
                "schedule": "0 9 * * *", "running": running,
            }]}))
            .unwrap()
        };
        daemon.returns::<methods::HermesRunJob>(job(true));
        daemon.returns::<methods::HermesJobs>(job(false));
        let held = daemon.hold::<methods::HermesRunJob>();
        use_connection(&stores, vcx, "a");
        vcx.update(|_, cx| run_now(&stores, "j1", cx));
        stores.hermes_admin.update(vcx, |a, cx| a.refresh_jobs(cx));
        vcx.run_until_parked();
        drop(held);
        vcx.run_until_parked();
        stores.hermes_admin.read_with(vcx, |a, _| {
            let running = a
                .jobs
                .as_ref()
                .and_then(crate::stores::hermes_admin::Loaded::ready)
                .map(|j| j.jobs[0].running);
            assert_eq!(running, Some(false), "the older answer put the run back");
        });
    }

    /// Run Now answered for the last connection leaves the busy mark of the
    /// same job's Run Now on the connection in use.
    #[gpui_kit::test]
    fn an_old_action_leaves_the_new_ones_busy_mark(cx: &mut gpui_kit::TestAppContext) {
        let (daemon, stores, vcx) = bench(cx);
        daemon
            .returns::<methods::HermesRunJob>(serde_json::from_value(json!({"jobs": []})).unwrap());
        let held = daemon.hold::<methods::HermesRunJob>();
        use_connection(&stores, vcx, "a");
        vcx.update(|_, cx| run_now(&stores, "j1", cx));
        use_connection(&stores, vcx, "b");
        vcx.update(|_, cx| run_now(&stores, "j1", cx));
        held.release_one();
        vcx.run_until_parked();
        stores.hermes_admin.read_with(vcx, |a, _| {
            assert!(
                a.busy.contains("j1"),
                "the run now on the connection in use lost its mark"
            )
        });
    }
}
