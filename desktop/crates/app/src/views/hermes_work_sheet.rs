//! The background work sheet: what a Hermes chat's agent has running
//! besides its reply, as the phone's `HermesBackgroundWorkSheet` lists it.
//!
//! * **Agents:** each subagent with its goal, model, how long it has run
//!   and its last tool. A click shows it in full: its live output (the end
//!   of its transcript, newest at the bottom, read every 2 s while it runs),
//!   a field to steer it (Hermes passes the words on after its current
//!   step), and Stop Agent.
//! * **Processes:** each running command with how long it has run; Kill
//!   Process asks first (an alert on the sheet), then says what happened.
//!
//! The list follows `hermes.work.changed`; the elapsed times move on once a
//! second while the sheet is open. Done (or Esc) closes it.

use std::collections::HashSet;
use std::rc::Rc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use conduit_components::ActiveConduitTheme as _;
use conduit_components::announce::{Priority, live_text};
use conduit_components::assets::{IconName, icon};
use conduit_components::theme::MONO_FONT;
use conduit_components::views::focus::{ControlExt as _, Ring};
use conduit_components::views::kit::{
    Button, ButtonKind, IconButton, bare_input, field_frame, heading, section_label,
};
use conduit_protocol::{HermesProcessKillStatus, HermesSubagentDto, HermesWork};
use gpui_kit::component::input::{InputEvent, InputState};
use gpui_kit::prelude::*;
use gpui_kit::{
    AnyElement, App, Context, ElementId, Entity, FontWeight, Role, SharedString, Subscription,
    Task, Window, div, px, relative,
};

use crate::l10n::{ActiveL10n as _, L10n};
use crate::stores::hermes_work::HermesWorkStore;
use crate::views::forms;
use crate::views::sheet::{self, SheetBody};

/// The sheet's width.
const WIDTH: f32 = 540.;

/// Opens the background work sheet for the chat `hermes` follows.
pub fn open(hermes: Entity<HermesWorkStore>, window: &mut Window, cx: &mut App) {
    let _ = sheet::open(window, WIDTH, cx, move |window, cx| {
        BackgroundWorkSheet::new(hermes, window, cx)
    });
}

/// A line under the list: what an action did.
#[derive(Clone, Debug, PartialEq)]
struct Notice {
    text: String,
    error: bool,
}

pub struct BackgroundWorkSheet {
    hermes: Entity<HermesWorkStore>,
    /// The subagent shown in full, and what the list said of it last (kept
    /// once it finishes).
    selected: Option<String>,
    known: Option<HermesSubagentDto>,
    steer: Entity<InputState>,
    busy: bool,
    killing: HashSet<String>,
    notice: Option<Notice>,
    /// Counts the actions that answered: each answer is heard, even in the
    /// words of the one before (a Steer refused twice).
    answers: u64,
    /// The steer was queued: its field empties on the next frame.
    clear_steer: bool,
    _subscriptions: Vec<Subscription>,
    _clock: Task<()>,
}

/// How long ago `started_ms` was: "45s", "1m05s", "2h03m" (the phone's
/// words); none when unknown.
pub fn elapsed(started_ms: Option<i64>, now_ms: i64) -> Option<String> {
    let started = started_ms?;
    let seconds = ((now_ms - started).max(0) / 1000) as u64;
    Some(if seconds < 60 {
        format!("{seconds}s")
    } else if seconds < 3600 {
        format!("{}m{:02}s", seconds / 60, seconds % 60)
    } else {
        format!("{}h{:02}m", seconds / 3600, (seconds % 3600) / 60)
    })
}

fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or_default()
}

/// "demo-model · 1m05s · last tool: web_search".
fn details(subagent: &HermesSubagentDto, l10n: &L10n) -> String {
    let mut parts = vec![];
    if let Some(model) = &subagent.model {
        parts.push(model.clone());
    }
    if subagent.status.as_deref() == Some("queued") {
        parts.push(l10n.hermes_subagent_queued());
    } else if subagent.running
        && let Some(time) = elapsed(subagent.started_at_ms, now_ms())
    {
        parts.push(time);
    }
    if let Some(tool) = &subagent.last_tool {
        parts.push(l10n.hermes_subagent_last_tool(tool));
    }
    parts.join(" \u{b7} ")
}

impl BackgroundWorkSheet {
    fn new(hermes: Entity<HermesWorkStore>, window: &mut Window, cx: &mut Context<Self>) -> Self {
        let hint = cx.l10n().hermes_subagent_steer_hint();
        let steer = forms::input(hint.clone(), false, window, cx);
        steer.update(cx, |i, cx| i.set_placeholder(hint, window, cx));
        let subscriptions = vec![
            cx.observe(&hermes, |this: &mut Self, hermes, cx| {
                // What the list says of the shown subagent, kept once it is
                // gone from it.
                if let Some(id) = &this.selected
                    && let Some(found) = hermes
                        .read(cx)
                        .work
                        .as_ref()
                        .and_then(|w| w.subagents.iter().find(|s| &s.id == id))
                {
                    this.known = Some(found.clone());
                }
                cx.notify();
            }),
            cx.subscribe_in(
                &steer,
                window,
                |this: &mut Self, _, e: &InputEvent, _, cx| match e {
                    InputEvent::PressEnter { .. } => this.send_steer(cx),
                    InputEvent::Change => cx.notify(),
                    _ => {}
                },
            ),
        ];
        // The elapsed times move on.
        let clock = cx.spawn(async move |this, cx| {
            loop {
                cx.background_executor().timer(Duration::from_secs(1)).await;
                if this.update(cx, |_, cx| cx.notify()).is_err() {
                    break;
                }
            }
        });
        Self {
            hermes,
            selected: None,
            known: None,
            steer,
            busy: false,
            killing: HashSet::new(),
            notice: None,
            answers: 0,
            clear_steer: false,
            _subscriptions: subscriptions,
            _clock: clock,
        }
    }

    fn work(&self, cx: &App) -> Option<HermesWork> {
        self.hermes.read(cx).work.clone()
    }

    fn listed(&self, cx: &App) -> Option<HermesSubagentDto> {
        let id = self.selected.as_ref()?;
        self.work(cx)?.subagents.into_iter().find(|s| &s.id == id)
    }

    /// Shows subagent `id` in full (none: the list), as a click on its row.
    pub fn show_subagent(
        &mut self,
        id: Option<String>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.select(id, window, cx);
    }

    /// Shows `id` in full (none: back to the list).
    fn select(&mut self, id: Option<String>, window: &mut Window, cx: &mut Context<Self>) {
        self.known = id.as_ref().and_then(|id| {
            self.work(cx)
                .and_then(|w| w.subagents.into_iter().find(|s| &s.id == id))
        });
        self.selected = id.clone();
        self.notice = None;
        self.steer.update(cx, |i, cx| i.set_value("", window, cx));
        self.hermes.update(cx, |h, cx| h.read_output(id, cx));
        cx.notify();
    }

    fn finished(&self, cx: &App) -> bool {
        !self.listed(cx).is_some_and(|s| s.running)
    }

    fn can_steer(&self, cx: &App) -> bool {
        !self.finished(cx) && !self.busy && self.listed(cx).is_some_and(|s| s.accepting_steer)
    }

    fn send_steer(&mut self, cx: &mut Context<Self>) {
        let text = forms::text(&self.steer, cx);
        let Some(id) = self.selected.clone() else {
            return;
        };
        if text.is_empty() || !self.can_steer(cx) {
            return;
        }
        let call = self.hermes.read(cx).steer(&id, &text);
        self.busy = true;
        self.notice = None;
        cx.notify();
        cx.spawn(async move |this, cx| {
            let result = call.await;
            let _ = this.update(cx, |s, cx| {
                s.busy = false;
                let l = cx.l10n().clone();
                s.answers += 1;
                s.notice = Some(match result {
                    Ok(r) if r.ok => {
                        s.clear_steer = true;
                        Notice {
                            text: l.hermes_subagent_steer_queued(),
                            error: false,
                        }
                    }
                    Ok(_) => Notice {
                        text: l.hermes_subagent_steer_rejected(),
                        error: true,
                    },
                    Err(_) => Notice {
                        text: l.hermes_background_action_failed(),
                        error: true,
                    },
                });
                cx.notify();
            });
        })
        .detach();
    }

    fn stop(&mut self, cx: &mut Context<Self>) {
        let Some(id) = self.selected.clone() else {
            return;
        };
        if self.busy || self.finished(cx) {
            return;
        }
        let call = self.hermes.read(cx).stop(&id);
        self.busy = true;
        self.notice = None;
        cx.notify();
        cx.spawn(async move |this, cx| {
            let result = call.await;
            let _ = this.update(cx, |s, cx| {
                s.busy = false;
                let l = cx.l10n().clone();
                s.answers += 1;
                s.notice = Some(match result {
                    Ok(r) if r.ok => Notice {
                        text: l.hermes_subagent_stopped(),
                        error: false,
                    },
                    Ok(_) => Notice {
                        text: l.hermes_subagent_finished(),
                        error: false,
                    },
                    Err(_) => Notice {
                        text: l.hermes_background_action_failed(),
                        error: true,
                    },
                });
                cx.notify();
            });
        })
        .detach();
    }

    /// Kill Process: asks first, then says what happened.
    fn kill(&mut self, id: String, command: String, window: &mut Window, cx: &mut Context<Self>) {
        use crate::shell::sheet::{SheetSpec, present_sheet};
        if self.killing.contains(&id) {
            return;
        }
        let l = cx.l10n().clone();
        let spec = SheetSpec::new(
            l.desktop_hermes_kill_process_title(),
            l.hermes_process_kill_message(&command),
            l.hermes_process_kill(),
            l.cancel(),
        )
        .destructive();
        let ask = present_sheet(window, spec, cx);
        let hermes = self.hermes.clone();
        cx.spawn(async move |this, cx| {
            if !ask.await {
                return;
            }
            let Ok(call) = this.update(cx, |s, cx| {
                s.killing.insert(id.clone());
                s.notice = None;
                cx.notify();
                hermes.read(cx).kill(&id)
            }) else {
                return;
            };
            let result = call.await;
            let _ = this.update(cx, |s, cx| {
                s.killing.remove(&id);
                let l = cx.l10n().clone();
                s.answers += 1;
                s.notice = Some(match result {
                    Ok(r) => match r.status {
                        HermesProcessKillStatus::Killed => Notice {
                            text: l.hermes_process_killed(),
                            error: false,
                        },
                        HermesProcessKillStatus::AlreadyExited
                        | HermesProcessKillStatus::NotFound => Notice {
                            text: l.hermes_process_already_stopped(),
                            error: false,
                        },
                        _ => Notice {
                            text: match r.error {
                                Some(e) => l.hermes_process_kill_failed(&e),
                                None => l.hermes_background_action_failed(),
                            },
                            error: true,
                        },
                    },
                    Err(_) => Notice {
                        text: l.hermes_background_action_failed(),
                        error: true,
                    },
                });
                cx.notify();
            });
        })
        .detach();
    }

    fn close(&mut self, cx: &mut Context<Self>) {
        self.hermes.update(cx, |h, cx| h.read_output(None, cx));
        sheet::dismiss(cx);
    }

    fn notice_line(&self, cx: &App) -> Option<AnyElement> {
        let notice = self.notice.as_ref()?;
        let t = cx.conduit();
        Some(
            div()
                .id("hermes-work-notice")
                .role(Role::Status)
                .aria_label(SharedString::from(notice.text.clone()))
                .text_size(px(t.metrics.small))
                .text_color(if notice.error {
                    t.roles.danger
                } else {
                    t.roles.text_subtle
                })
                .child(SharedString::from(notice.text.clone()))
                // Said when it appears, as the phone's notice is.
                .child(
                    live_text(
                        "live",
                        Some(SharedString::from(notice.text.clone())),
                        if notice.error {
                            Priority::High
                        } else {
                            Priority::Medium
                        },
                    )
                    .attempt(self.answers),
                )
                .into_any_element(),
        )
    }

    fn list(&mut self, window: &mut Window, cx: &mut Context<Self>) -> AnyElement {
        let t = cx.conduit().clone();
        let r = t.roles;
        let m = t.metrics;
        let l10n = cx.l10n().clone();
        let work = self.work(cx);
        let view = cx.entity().downgrade();
        let subagents = work
            .as_ref()
            .map(|w| w.subagents.clone())
            .unwrap_or_default();
        let processes: Vec<_> = work
            .as_ref()
            .map(|w| w.processes.iter().filter(|p| p.running).cloned().collect())
            .unwrap_or_default();
        let now = now_ms();
        let mut body = div().flex().flex_col().gap(px(4.));
        if !work.as_ref().is_some_and(|w| w.loaded) {
            body = body.child(
                div()
                    .py(px(16.))
                    .text_size(px(m.small))
                    .text_color(r.text_subtle)
                    .child(SharedString::from(l10n.desktop_loading())),
            );
        } else if subagents.is_empty() && processes.is_empty() {
            body = body.child(
                div()
                    .py(px(16.))
                    .text_size(px(m.control))
                    .text_color(r.text_subtle)
                    .child(SharedString::from(l10n.hermes_background_work_empty())),
            );
        }
        if !subagents.is_empty() {
            let count = subagents.len();
            body = body
                .child(
                    div()
                        .pt(px(6.))
                        .child(section_label(l10n.hermes_background_agents(), cx)),
                )
                .child(
                    div()
                        .id("hermes-agents")
                        .role(Role::List)
                        .aria_label(SharedString::from(l10n.hermes_background_agents()))
                        .flex()
                        .flex_col()
                        .children(subagents.into_iter().enumerate().map(|(i, s)| {
                            let detail = details(&s, &l10n);
                            let goal = if s.goal.is_empty() {
                                s.id.clone()
                            } else {
                                s.goal.clone()
                            };
                            let view = view.clone();
                            let id = s.id.clone();
                            div()
                                .id(ElementId::Name(format!("hermes-agent-{}", s.id).into()))
                                .role(Role::ListItem)
                                .aria_label(SharedString::from(format!("{goal}. {detail}")))
                                .aria_position_in_set(i + 1)
                                .aria_size_of_set(count)
                                .pl(px(8. + 14. * s.depth.clamp(0, 3) as f32))
                                .pr(px(8.))
                                .py(px(7.))
                                .flex()
                                .items_center()
                                .gap(px(10.))
                                .rounded(px(7.))
                                .cursor_pointer()
                                .hover(|st| st.bg(r.hover))
                                .child(icon(
                                    if s.running {
                                        IconName::Network
                                    } else {
                                        IconName::CircleCheck
                                    },
                                    16.,
                                    if s.running { r.text_subtle } else { r.success },
                                ))
                                .child(
                                    div()
                                        .flex_1()
                                        .min_w_0()
                                        .flex()
                                        .flex_col()
                                        .gap(px(1.))
                                        .child(
                                            div()
                                                .text_size(px(m.control))
                                                .font_weight(FontWeight::MEDIUM)
                                                .text_color(r.text)
                                                .line_clamp(2)
                                                .child(SharedString::from(goal)),
                                        )
                                        .when(!detail.is_empty(), |d| {
                                            d.child(
                                                div()
                                                    .truncate()
                                                    .text_size(px(m.small))
                                                    .text_color(r.text_subtle)
                                                    .child(SharedString::from(detail)),
                                            )
                                        }),
                                )
                                .child(icon(IconName::ChevronRight, 13., r.text_faint))
                                .on_click(move |_, window, cx| {
                                    let _ = view
                                        .update(cx, |v, cx| v.select(Some(id.clone()), window, cx));
                                })
                                .keyboard_list_item(Ring::Inset(7.), window, cx)
                                .into_any_element()
                        })),
                );
        }
        if !processes.is_empty() {
            let count = processes.len();
            body = body
                .child(
                    div()
                        .pt(px(6.))
                        .child(section_label(l10n.hermes_background_processes(), cx)),
                )
                .child(
                    div()
                        .id("hermes-processes")
                        .role(Role::List)
                        .aria_label(SharedString::from(l10n.hermes_background_processes()))
                        .flex()
                        .flex_col()
                        .children(processes.into_iter().enumerate().map(|(i, p)| {
                            let killing = self.killing.contains(&p.id);
                            let time = elapsed(p.started_at_ms, now);
                            let view = view.clone();
                            let (id, command) = (p.id.clone(), p.command.clone());
                            div()
                                .id(ElementId::Name(format!("hermes-process-{}", p.id).into()))
                                .role(Role::ListItem)
                                .aria_label(SharedString::from(match &time {
                                    Some(time) => format!("{}, {time}", p.command),
                                    None => p.command.clone(),
                                }))
                                .aria_position_in_set(i + 1)
                                .aria_size_of_set(count)
                                .px(px(8.))
                                .py(px(5.))
                                .flex()
                                .items_center()
                                .gap(px(10.))
                                .child(icon(IconName::SquareTerminal, 16., r.text_subtle))
                                .child(
                                    div()
                                        .flex_1()
                                        .min_w_0()
                                        .flex()
                                        .flex_col()
                                        .gap(px(1.))
                                        .child(
                                            div()
                                                .font_family(MONO_FONT)
                                                .text_size(px(m.code))
                                                .text_color(r.text)
                                                .line_clamp(2)
                                                .child(SharedString::from(p.command.clone())),
                                        )
                                        .when_some(time, |d, time| {
                                            d.child(
                                                div()
                                                    .text_size(px(m.small))
                                                    .text_color(r.text_subtle)
                                                    .child(SharedString::from(time)),
                                            )
                                        }),
                                )
                                .child(if killing {
                                    icon(IconName::LoaderCircle, 15., r.text_faint)
                                        .into_any_element()
                                } else {
                                    IconButton::new(
                                        ElementId::Name(format!("hermes-kill-{}", p.id).into()),
                                        IconName::CircleX,
                                        l10n.desktop_hermes_kill_process(),
                                    )
                                    .tooltip(l10n.desktop_hermes_kill_process())
                                    .color(r.danger)
                                    .on_click(Rc::new(move |_, window, cx| {
                                        let (id, command) = (id.clone(), command.clone());
                                        let _ = view
                                            .update(cx, |v, cx| v.kill(id, command, window, cx));
                                    }))
                                    .into_any_element()
                                })
                                .into_any_element()
                        })),
                );
        }
        body.into_any_element()
    }

    fn detail(&mut self, _: &mut Window, cx: &mut Context<Self>) -> AnyElement {
        let t = cx.conduit().clone();
        let r = t.roles;
        let m = t.metrics;
        let l10n = cx.l10n().clone();
        let view = cx.entity().downgrade();
        let id = self.selected.clone().unwrap_or_default();
        let known = self.listed(cx).or_else(|| self.known.clone());
        let finished = self.finished(cx);
        let can_steer = self.can_steer(cx);
        let typed = !forms::text(&self.steer, cx).is_empty();
        let goal = known
            .as_ref()
            .map(|k| k.goal.clone())
            .filter(|g| !g.is_empty())
            .unwrap_or_else(|| id.clone());
        let detail = known
            .as_ref()
            .map(|k| details(k, &l10n))
            .unwrap_or_default();
        let output = self
            .hermes
            .read(cx)
            .work
            .as_ref()
            .and_then(|w| w.output.clone())
            .filter(|o| o.subagent_id == id);
        let output_body: AnyElement = match output {
            Some(o) if o.failed => div()
                .text_size(px(m.small))
                .text_color(r.text_subtle)
                .child(SharedString::from(l10n.hermes_subagent_output_failed()))
                .into_any_element(),
            Some(o) if o.loaded && (!o.available || o.text.trim().is_empty()) => div()
                .text_size(px(m.small))
                .text_color(r.text_subtle)
                .child(SharedString::from(l10n.hermes_subagent_no_output()))
                .into_any_element(),
            Some(o) if o.loaded => div()
                .flex()
                .flex_col()
                .gap(px(4.))
                .when(o.truncated, |d| {
                    d.child(
                        div()
                            .text_size(px(m.caption))
                            .text_color(r.text_faint)
                            .child(SharedString::from(l10n.hermes_subagent_output_truncated())),
                    )
                })
                .child(
                    div()
                        .id("hermes-subagent-output")
                        .role(Role::Log)
                        .aria_label(SharedString::from(l10n.desktop_hermes_live_output()))
                        .max_h(px(240.))
                        .overflow_y_scroll()
                        .px(px(10.))
                        .py(px(8.))
                        .rounded(px(8.))
                        .border_1()
                        .border_color(r.border)
                        .bg(r.raised)
                        .font_family(MONO_FONT)
                        .text_size(px(m.code - 1.))
                        .line_height(relative(1.45))
                        .text_color(r.text)
                        .child(SharedString::from(o.text.trim_end().to_string())),
                )
                .into_any_element(),
            _ => div()
                .text_size(px(m.small))
                .text_color(r.text_faint)
                .child(SharedString::from(l10n.desktop_loading()))
                .into_any_element(),
        };
        let back = {
            let view = view.clone();
            IconButton::new("hermes-subagent-back", IconName::ChevronLeft, l10n.back())
                .tooltip(l10n.back())
                .on_click(Rc::new(move |_, window, cx| {
                    let _ = view.update(cx, |v, cx| v.select(None, window, cx));
                }))
        };
        div()
            .flex()
            .flex_col()
            .gap(px(12.))
            .child(
                div().flex().items_start().gap(px(8.)).child(back).child(
                    div()
                        .flex_1()
                        .min_w_0()
                        .pt(px(2.))
                        .flex()
                        .flex_col()
                        .gap(px(2.))
                        .child(
                            div()
                                .text_size(px(m.control + 1.))
                                .font_weight(FontWeight::SEMIBOLD)
                                .text_color(r.text)
                                .child(SharedString::from(goal)),
                        )
                        .when(!detail.is_empty(), |d| {
                            d.child(
                                div()
                                    .text_size(px(m.small))
                                    .text_color(r.text_subtle)
                                    .child(SharedString::from(detail)),
                            )
                        }),
                ),
            )
            .when(finished, |d| {
                d.child(
                    div()
                        .text_size(px(m.small))
                        .text_color(r.text_subtle)
                        .child(SharedString::from(l10n.hermes_subagent_finished())),
                )
            })
            .child(section_label(l10n.desktop_hermes_live_output(), cx))
            .child(output_body)
            .child(
                field_frame(false, m.control_height + 4., cx)
                    .when(!can_steer, |d| d.opacity(0.5))
                    .child(div().flex_1().child(bare_input(
                        &self.steer,
                        l10n.hermes_subagent_steer_hint(),
                        m.control,
                    ))),
            )
            .child(
                div()
                    .flex()
                    .justify_end()
                    .gap(px(8.))
                    .child({
                        let view = view.clone();
                        Button::new("hermes-subagent-stop", l10n.desktop_hermes_stop_agent())
                            .kind(ButtonKind::Danger)
                            .disabled(finished || self.busy)
                            .on_click(Rc::new(move |_, _, cx| {
                                let _ = view.update(cx, |v, cx| v.stop(cx));
                            }))
                    })
                    .child(
                        Button::new("hermes-subagent-steer", l10n.hermes_subagent_steer())
                            .disabled(!can_steer || !typed)
                            .on_click(Rc::new(move |_, _, cx| {
                                let _ = view.update(cx, |v, cx| v.send_steer(cx));
                            })),
                    ),
            )
            .into_any_element()
    }
}

impl SheetBody for BackgroundWorkSheet {
    fn cancel(&mut self, _: &mut Window, cx: &mut Context<Self>) {
        self.close(cx);
    }

    fn label(&self, cx: &App) -> SharedString {
        cx.l10n().desktop_hermes_background_work().into()
    }

    fn footer(&mut self, _: &mut Window, cx: &mut Context<Self>) -> Option<AnyElement> {
        let l10n = cx.l10n().clone();
        let view = cx.entity().downgrade();
        Some(
            forms::form_buttons(vec![
                Button::new("hermes-work-done", l10n.desktop_done())
                    .primary()
                    .on_click(Rc::new(move |_, _, cx| {
                        let _ = view.update(cx, |v, cx| v.close(cx));
                    }))
                    .into_any_element(),
            ])
            .into_any_element(),
        )
    }
}

impl Render for BackgroundWorkSheet {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let t = cx.conduit().clone();
        let l10n = cx.l10n().clone();
        if self.clear_steer {
            self.clear_steer = false;
            self.steer.update(cx, |i, cx| i.set_value("", window, cx));
        }
        let content = if self.selected.is_some() {
            self.detail(window, cx)
        } else {
            self.list(window, cx)
        };
        div()
            .id("hermes-work-sheet")
            .flex()
            .flex_col()
            .gap(px(8.))
            .child(heading(
                "hermes-work-title",
                l10n.desktop_hermes_background_work(),
                1,
                t.metrics.control + 2.,
                FontWeight::BOLD,
                t.roles.text,
            ))
            .children(self.notice_line(cx))
            .child(content)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn elapsed_reads_as_the_phone_writes_it() {
        assert_eq!(elapsed(Some(0), 45_000), Some("45s".into()));
        assert_eq!(elapsed(Some(0), 65_000), Some("1m05s".into()));
        assert_eq!(elapsed(Some(0), 7_380_000), Some("2h03m".into()));
        assert_eq!(
            elapsed(Some(10_000), 0),
            Some("0s".into()),
            "never negative"
        );
        assert_eq!(elapsed(None, 1), None);
    }
}
