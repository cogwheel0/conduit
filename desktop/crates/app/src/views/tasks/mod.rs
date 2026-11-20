//! The Scheduled Tasks pane (the sidebar's Scheduled Tasks › All Tasks): the
//! account's tasks in a list beside the chosen task, as Mail lists messages
//! beside the one open, with the phone's pages' content.
//!
//! * **List**: search, All / Active / Paused, Load More; each row says how
//!   the task repeats, when it runs next, and whether it is paused or its
//!   last run failed. ↑/↓ choose, ⌘⌫ deletes, the context menu runs, edits,
//!   pauses or deletes.
//! * **Task**: Active, Run Now (watched until the run is in the history),
//!   Edit… ([`editor`]), Delete…; the schedule, model, where results go,
//!   the last and next runs, the instructions, and the history with each
//!   run's chat or channel.
//!
//! As on the phone, the section exists only with Settings' Advanced on;
//! reached another way (a calendar entry), the pane says so and offers to
//! turn it on.

pub mod editor;

use std::rc::Rc;
use std::time::Duration;

use conduit_components::ActiveConduitTheme as _;
use conduit_components::assets::{IconName, icon};
use conduit_components::views::focus::{ControlExt as _, Ring};
use conduit_components::views::kit::{
    Button, IconButton, Segment, Segmented, Switch, grouped_section, heading, setting_row,
};
use conduit_protocol::{
    AppSettingsPatch, AutomationDetail, AutomationRunDto, AutomationRunProgress,
    AutomationScheduleDto, AutomationSummary,
};
use gpui_kit::component::input::{Input, InputEvent, InputState};
use gpui_kit::component::native_menu::NativeMenu;
use gpui_kit::component::{VirtualListScrollHandle, v_virtual_list};
use gpui_kit::prelude::*;
use gpui_kit::{
    AnyElement, App, AsyncApp, Context, ElementId, Entity, FocusHandle, Focusable, FontWeight,
    MouseButton, MouseDownEvent, Pixels, Point, Role, SharedString, Subscription, Task, Window,
    div, px, relative, size,
};

use crate::actions::TaskMenu;
use crate::l10n::{ActiveL10n as _, L10n};
use crate::shell::sheet::SheetSpec;
use crate::stores::Stores;
use crate::stores::navigation::AreaItem;
use crate::views::dates::{Form, format};
use crate::views::forms;

/// The list column's width.
pub const LIST_WIDTH: f32 = 300.;
const ROW_HEIGHT: f32 = 60.;
const MORE_HEIGHT: f32 = 44.;
const STATUSES: [&str; 3] = ["all", "active", "paused"];

/// A task's schedule in words, as the phone's list says it.
/// A coding agent as the picker names it ("Codex · gpt-5.1").
pub fn agent_label(agent: &conduit_protocol::TerminalAgentDto) -> String {
    let name = if agent.agent_name.trim().is_empty() {
        &agent.agent
    } else {
        &agent.agent_name
    };
    format!("{name} \u{b7} {}", agent.model)
}

pub fn schedule_summary(schedule: &AutomationScheduleDto, l: &L10n) -> String {
    let clock = |hour: i64, minute: i64| {
        let wall = conduit_protocol::CalendarWallTime {
            year: 2024,
            month: 1,
            day: 1,
            hour,
            minute,
        };
        crate::views::calendar::format::time(&wall, l)
    };
    match schedule.kind.as_str() {
        "once" => {
            let wall = conduit_protocol::CalendarWallTime {
                year: schedule.year,
                month: schedule.month,
                day: schedule.day,
                hour: schedule.hour,
                minute: schedule.minute,
            };
            let ms = crate::views::calendar::format::wall_ms(&wall);
            l.scheduled_task_schedule_once_summary(&format(ms, Form::DateTime, l.locale()))
        }
        "daily" => l.scheduled_task_schedule_daily_summary(&clock(schedule.hour, schedule.minute)),
        "weekly" => {
            let days = weekday_codes()
                .iter()
                .filter(|c| schedule.days.iter().any(|d| d == *c))
                .map(|c| weekday_label(c, l))
                .collect::<Vec<_>>()
                .join(", ");
            l.scheduled_task_schedule_weekly_summary(&days, &clock(schedule.hour, schedule.minute))
        }
        _ => l.scheduled_task_schedule_custom(),
    }
}

/// The weekday codes, Monday first.
pub fn weekday_codes() -> [&'static str; 7] {
    ["MO", "TU", "WE", "TH", "FR", "SA", "SU"]
}

/// A weekday code's short name in the app's language.
pub fn weekday_label(code: &str, l: &L10n) -> String {
    let index = weekday_codes().iter().position(|c| *c == code).unwrap_or(0) as i64;
    // 1 January 2024 was a Monday.
    let wall = conduit_protocol::CalendarWallTime {
        year: 2024,
        month: 1,
        day: 1 + index,
        hour: 12,
        minute: 0,
    };
    crate::views::calendar::format::wall_in(&wall, Form::Weekday, l)
}

/// `ms` as a date and time.
pub fn when(ms: i64, l: &L10n) -> String {
    format(ms, Form::DateTime, l.locale())
}

/// What a refusal says: a reason the app words, or the server's own words.
pub fn failure_text(failure: &str, fallback: String, l: &L10n) -> String {
    match failure {
        "accountChanged" => l.scheduled_tasks_account_changed(),
        "unavailable" => l.scheduled_tasks_unavailable(),
        "notFound" => l.scheduled_tasks_not_found(),
        "failed" | "" => fallback,
        server => server.to_string(),
    }
}

/// [`failure_text`] for an RPC error.
pub fn error_text(e: &conduit_protocol::RpcError, fallback: String, l: &L10n) -> String {
    let reason = e.args.get("reason").map(String::as_str).unwrap_or("");
    if reason == "server" {
        return e.args.get("detail").cloned().unwrap_or(fallback);
    }
    failure_text(reason, fallback, l)
}

pub struct TasksPane {
    stores: Stores,
    focus: FocusHandle,
    scroll: VirtualListScrollHandle,
    search: Entity<InputState>,
    search_task: Option<Task<()>>,
    /// The list was asked for (the pane was shown while usable).
    asked: bool,
    _subscriptions: Vec<Subscription>,
}

impl TasksPane {
    pub fn new(stores: Stores, window: &mut Window, cx: &mut Context<Self>) -> Self {
        let l = cx.l10n().clone();
        let search =
            cx.new(|cx| InputState::new(window, cx).placeholder(l.scheduled_tasks_search_hint()));
        let mut account = stores.accounts.read(cx).active().map(|a| a.id.clone());
        let subscriptions = vec![
            cx.observe(&stores.tasks, |_, _, cx| cx.notify()),
            cx.observe(&stores.session, |_, _, cx| cx.notify()),
            // Another account: what was typed in search goes, and the search
            // waiting to go with it, so it never reaches the next account.
            cx.observe_in(
                &stores.accounts,
                window,
                move |this, accounts, window, cx| {
                    // A list being read again (a reconnect) names nobody.
                    let Some(now) = accounts.read(cx).active().map(|a| a.id.clone()) else {
                        return;
                    };
                    if account.as_ref() == Some(&now) {
                        return;
                    }
                    account = Some(now);
                    this.search_task = None;
                    this.search.update(cx, |s, cx| s.set_value("", window, cx));
                    cx.notify();
                },
            ),
            cx.subscribe_in(
                &search,
                window,
                |this, state, e: &InputEvent, _, cx| match e {
                    InputEvent::Change => {
                        let value = state.read(cx).value().to_string();
                        this.search_soon(value, cx);
                    }
                    InputEvent::PressEnter { .. } => {
                        let value = state.read(cx).value().to_string();
                        this.search_task = None;
                        this.stores.tasks.update(cx, |t, cx| t.search(&value, cx));
                    }
                    _ => {}
                },
            ),
        ];
        let mut this = Self {
            stores,
            focus: cx.focus_handle(),
            scroll: VirtualListScrollHandle::new(),
            search,
            search_task: None,
            asked: false,
            _subscriptions: subscriptions,
        };
        this.show(cx);
        this
    }

    /// The list takes the keys: the pane or a row has focus, not search.
    fn list_has_keys(&self, window: &Window, cx: &App) -> bool {
        crate::views::list_has_keys(&self.focus, &[self.search.focus_handle(cx)], window, cx)
    }

    fn usable(&self, cx: &App) -> bool {
        let c = self.stores.session.read(cx).capabilities();
        c.automations && c.scheduled_tasks
    }

    /// The list's scroll (the perf fixture scrolls it).
    pub fn scroll_handle(&self) -> &VirtualListScrollHandle {
        &self.scroll
    }

    /// The pane is shown again: the list and the chosen task are read again.
    pub fn show(&mut self, cx: &mut Context<Self>) {
        if self.usable(cx) {
            self.asked = true;
            self.stores.tasks.update(cx, |t, cx| t.show(cx));
        }
    }

    fn search_soon(&mut self, value: String, cx: &mut Context<Self>) {
        let tasks = self.stores.tasks.clone();
        self.search_task = Some(cx.spawn(async move |_, cx: &mut AsyncApp| {
            cx.background_executor()
                .timer(Duration::from_millis(300))
                .await;
            cx.update(|cx| tasks.update(cx, |t, cx| t.search(&value, cx)));
        }));
    }

    /// Types a search, as the user would (E2E).
    pub fn type_search(&mut self, value: &str, window: &mut Window, cx: &mut Context<Self>) {
        let v = value.to_string();
        self.search
            .update(cx, |s, cx| s.set_value(v.clone(), window, cx));
        self.search_task = None;
        self.stores.tasks.update(cx, |t, cx| t.search(&v, cx));
    }

    fn summaries(&self, cx: &App) -> Vec<AutomationSummary> {
        self.stores
            .tasks
            .read(cx)
            .list
            .as_ref()
            .map(|l| l.items.clone())
            .unwrap_or_default()
    }

    pub fn select(&mut self, id: &str, cx: &mut Context<Self>) {
        let id = id.to_string();
        self.stores.tasks.update(cx, |t, cx| t.select(Some(id), cx));
    }

    pub fn new_task(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        editor::open(self.stores.clone(), None, window, cx);
    }

    pub fn edit(&mut self, id: &str, window: &mut Window, cx: &mut Context<Self>) {
        editor::open(self.stores.clone(), Some(id.to_string()), window, cx);
    }

    pub fn run(&mut self, id: &str, cx: &mut Context<Self>) {
        let id = id.to_string();
        self.stores.tasks.update(cx, |t, cx| t.run(&id, cx));
    }

    pub fn set_active(&mut self, id: &str, active: bool, cx: &mut Context<Self>) {
        let id = id.to_string();
        self.stores
            .tasks
            .update(cx, |t, cx| t.set_active(&id, active, cx));
    }

    /// Asks, then deletes `id`.
    pub fn delete(&mut self, id: &str, window: &mut Window, cx: &mut Context<Self>) {
        let l = cx.l10n().clone();
        let name = self
            .summaries(cx)
            .into_iter()
            .find(|t| t.id == id)
            .map(|t| t.name)
            .or_else(|| {
                self.stores
                    .tasks
                    .read(cx)
                    .detail
                    .as_ref()
                    .filter(|d| d.summary.id == id)
                    .map(|d| d.summary.name.clone())
            })
            .unwrap_or_default();
        let spec = SheetSpec::new(
            l.scheduled_task_delete_title(),
            l.scheduled_task_delete_confirm(&name),
            l.delete(),
            l.cancel(),
        )
        .destructive();
        // Asked, and sent, only for the account the task is shown for.
        let ask = crate::views::sheet::ask_for_account(&self.stores, window, spec, cx);
        let tasks = self.stores.tasks.clone();
        let id = id.to_string();
        cx.spawn(async move |_, cx: &mut AsyncApp| {
            if ask.await {
                cx.update(|cx| tasks.update(cx, |t, cx| t.delete(&id, cx)));
            }
        })
        .detach();
    }

    /// Opens a run's chat or channel.
    pub fn open_result(&mut self, run: &AutomationRunDto, cx: &mut Context<Self>) {
        if let Some(channel) = run.result_channel_id.clone() {
            self.stores
                .navigation
                .update(cx, |n, cx| n.open_item(AreaItem::Channel(channel), cx));
        } else if let Some(chat) = run.result_chat_id.clone() {
            self.stores.navigation.update(cx, |n, cx| n.open(chat, cx));
        }
    }

    fn on_menu(&mut self, a: &TaskMenu, window: &mut Window, cx: &mut Context<Self>) {
        let id = a.id.clone();
        match a.command.as_str() {
            "run" => self.run(&id, cx),
            "edit" => self.edit(&id, window, cx),
            "pause" => self.set_active(&id, false, cx),
            "resume" => self.set_active(&id, true, cx),
            "delete" => self.delete(&id, window, cx),
            _ => {}
        }
    }

    fn row_menu(
        &mut self,
        task: &AutomationSummary,
        position: Point<Pixels>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let l = cx.l10n().clone();
        if !self.focus.contains_focused(window, cx) {
            window.focus(&self.focus, cx);
        }
        let entry = |command: &str| {
            Box::new(TaskMenu {
                command: command.into(),
                id: task.id.clone(),
            })
        };
        NativeMenu::new()
            .menu(l.scheduled_task_run_now(), entry("run"))
            .menu(l.desktop_edit_ellipsis(), entry("edit"))
            .menu(
                if task.active {
                    l.desktop_tasks_pause()
                } else {
                    l.desktop_tasks_resume()
                },
                entry(if task.active { "pause" } else { "resume" }),
            )
            .separator()
            .menu(l.desktop_delete_ellipsis(), entry("delete"))
            .show(position, window, cx);
    }

    fn on_key(
        &mut self,
        e: &gpui_kit::KeyDownEvent,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> bool {
        if !self.list_has_keys(window, cx) {
            return false;
        }
        let k = &e.keystroke;
        let m = &k.modifiers;
        let plain = !(m.platform || m.alt || m.control || m.shift);
        let items = self.summaries(cx);
        let selected = self.stores.tasks.read(cx).selected.clone();
        let current = selected
            .as_ref()
            .and_then(|id| items.iter().position(|t| &t.id == id));
        match k.key.as_str() {
            "up" | "down" if plain => {
                if items.is_empty() {
                    return true;
                }
                let next = match (k.key.as_str(), current) {
                    ("down", None) => 0,
                    ("up", None) => items.len() - 1,
                    ("down", Some(i)) => (i + 1).min(items.len() - 1),
                    (_, Some(i)) => i.saturating_sub(1),
                    _ => 0,
                };
                self.scroll
                    .scroll_to_item(next, gpui_kit::ScrollStrategy::Nearest);
                self.select(&items[next].id.clone(), cx);
                // The pane has the keyboard, not the row: say which.
                crate::views::a11y::announce_row(&items[next].name, next, items.len(), cx);
                true
            }
            "backspace" | "delete" if m.platform && !(m.alt || m.control || m.shift) => {
                if let Some(id) = selected {
                    self.delete(&id, window, cx);
                }
                true
            }
            _ => false,
        }
    }

    // ── Drawing: the list ─────────────────────────────────────────────

    fn list_header(&mut self, window: &mut Window, cx: &mut Context<Self>) -> AnyElement {
        let t = cx.conduit().clone();
        let r = t.roles;
        let l = cx.l10n().clone();
        let status = self.stores.tasks.read(cx).status.clone();
        let entity = cx.entity().downgrade();
        let new_entity = entity.clone();
        let _ = window;
        div()
            .flex_none()
            .px(px(12.))
            .pt(px(10.))
            .pb(px(8.))
            .flex()
            .flex_col()
            .gap(px(8.))
            .border_b_1()
            .border_color(r.divider)
            .child(
                div()
                    .flex()
                    .items_center()
                    .gap(px(6.))
                    .child(
                        div()
                            .id("tasks-search")
                            .flex_1()
                            .min_w_0()
                            .child(Input::new(&self.search).cleanable(true)),
                    )
                    .child(
                        IconButton::new("tasks-add", IconName::Plus, l.scheduled_tasks_add())
                            .size(28., 15.)
                            .round()
                            .on_click(Rc::new(move |_, window, cx| {
                                let _ = new_entity.update(cx, |p, cx| p.new_task(window, cx));
                            })),
                    ),
            )
            .child(
                Segmented::new(
                    "tasks-filter",
                    l.desktop_tasks_filter(),
                    vec![
                        Segment::new(l.scheduled_tasks_filter_all()),
                        Segment::new(l.scheduled_tasks_filter_active()),
                        Segment::new(l.scheduled_tasks_filter_paused()),
                    ],
                    STATUSES.iter().position(|s| *s == status).unwrap_or(0),
                )
                .on_select(Rc::new(move |i, _, cx| {
                    let _ = entity.update(cx, |p, cx| {
                        p.stores.tasks.update(cx, |t, cx| t.filter(STATUSES[i], cx))
                    });
                })),
            )
            .into_any_element()
    }

    fn render_rows(
        &mut self,
        range: std::ops::Range<usize>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Vec<AnyElement> {
        let items = self.summaries(cx);
        range
            .map(|i| {
                if let Some(task) = items.get(i) {
                    self.row(task, i, window, cx)
                } else {
                    self.more_row(cx)
                }
            })
            .collect()
    }

    fn more_row(&self, cx: &mut Context<Self>) -> AnyElement {
        let l = cx.l10n().clone();
        let loading = self.stores.tasks.read(cx).loading_more;
        let entity = cx.entity().downgrade();
        div()
            .h(px(MORE_HEIGHT))
            .flex()
            .items_center()
            .justify_center()
            .child(
                Button::new(
                    "tasks-load-more",
                    if loading {
                        l.desktop_loading()
                    } else {
                        l.scheduled_tasks_load_more()
                    },
                )
                .ghost()
                .disabled(loading)
                .on_click(Rc::new(move |_, _, cx| {
                    let _ = entity.update(cx, |p, cx| {
                        p.stores.tasks.update(cx, |t, cx| t.load_more(cx))
                    });
                })),
            )
            .into_any_element()
    }

    fn row(
        &mut self,
        task: &AutomationSummary,
        index: usize,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let t = cx.conduit().clone();
        let r = t.roles;
        let l = cx.l10n().clone();
        let selected = self.stores.tasks.read(cx).selected.as_deref() == Some(task.id.as_str());
        let sub = if selected {
            r.selected_text_subtle
        } else {
            r.text_subtle
        };
        let schedule = schedule_summary(&task.schedule, &l);
        let next = task
            .next_run_at
            .map(|ms| l.scheduled_task_next_run(&when(ms, &l)))
            .unwrap_or_else(|| l.scheduled_task_no_next_run());
        let detail = format!("{schedule} · {next}");
        // A task a coding agent runs names the agent, not a model the
        // account does not have (one made on the web, say).
        let agent = task.agent.as_ref().map(agent_label);
        let status = if task.active {
            l.scheduled_task_status_active()
        } else {
            l.scheduled_task_status_paused()
        };
        let label = [
            Some(task.name.clone()),
            Some(status),
            agent.clone(),
            task.last_run_failed
                .then(|| l.scheduled_task_last_run_failed()),
            Some(detail.clone()),
        ]
        .into_iter()
        .flatten()
        .collect::<Vec<_>>()
        .join(", ");
        let entity = cx.entity().downgrade();
        let id = task.id.clone();
        let menu_task = task.clone();
        div()
            .id(ElementId::NamedInteger("tasks-row".into(), index as u64))
            .role(Role::Row)
            .aria_label(SharedString::from(label))
            .aria_selected(selected)
            .h(px(ROW_HEIGHT))
            .px(px(6.))
            .py(px(2.))
            .child(
                div()
                    .size_full()
                    .px(px(10.))
                    .flex()
                    .items_center()
                    .gap(px(10.))
                    .rounded(px(7.))
                    .cursor_pointer()
                    .when(selected, |d| d.bg(r.selected))
                    .when(!selected, |d| d.hover(|s| s.bg(r.overlay_hover)))
                    .child(icon(
                        if task.active {
                            IconName::CalendarClock
                        } else {
                            IconName::CirclePause
                        },
                        16.,
                        if task.active { r.text } else { sub },
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
                                    .flex()
                                    .items_center()
                                    .gap(px(6.))
                                    .child(
                                        div()
                                            .min_w_0()
                                            .truncate()
                                            .text_size(px(t.metrics.body))
                                            .font_weight(FontWeight::MEDIUM)
                                            .text_color(if task.active { r.text } else { sub })
                                            .child(SharedString::from(task.name.clone())),
                                    )
                                    .when(!task.active, |d| {
                                        d.child(
                                            div()
                                                .flex_none()
                                                .text_size(px(t.metrics.small))
                                                .text_color(sub)
                                                .child(SharedString::from(
                                                    l.scheduled_task_status_paused(),
                                                )),
                                        )
                                    })
                                    .when_some(agent, |d, agent| {
                                        d.child(
                                            div()
                                                .id(ElementId::NamedInteger(
                                                    "tasks-row-agent".into(),
                                                    index as u64,
                                                ))
                                                .min_w_0()
                                                .flex()
                                                .items_center()
                                                .gap(px(3.))
                                                .text_size(px(t.metrics.small))
                                                .text_color(sub)
                                                .child(icon(IconName::SquareTerminal, 11., sub))
                                                .child(
                                                    div()
                                                        .truncate()
                                                        .child(SharedString::from(agent)),
                                                ),
                                        )
                                    }),
                            )
                            .child(
                                div()
                                    .truncate()
                                    .text_size(px(t.metrics.small))
                                    .text_color(sub)
                                    .child(SharedString::from(detail)),
                            )
                            .when(task.last_run_failed, |d| {
                                d.child(
                                    div()
                                        .truncate()
                                        .text_size(px(t.metrics.small))
                                        .text_color(r.danger)
                                        .child(SharedString::from(
                                            l.scheduled_task_last_run_failed(),
                                        )),
                                )
                            }),
                    ),
            )
            .on_click({
                let entity = entity.clone();
                move |_, window, cx| {
                    let id = id.clone();
                    let _ = entity.update(cx, |p, cx| {
                        // From the search field too: the list takes the
                        // keys of the task clicked.
                        if !p.list_has_keys(window, cx) {
                            window.focus(&p.focus, cx);
                        }
                        p.select(&id, cx);
                    });
                }
            })
            .on_mouse_down(
                MouseButton::Right,
                cx.listener(move |this, ev: &MouseDownEvent, window, cx| {
                    cx.stop_propagation();
                    this.select(&menu_task.id.clone(), cx);
                    this.row_menu(&menu_task, ev.position, window, cx)
                }),
            )
            .keyboard_list_item(Ring::Inset(7.), window, cx)
            .into_any_element()
    }

    fn list_body(&mut self, cx: &mut Context<Self>) -> AnyElement {
        let t = cx.conduit().clone();
        let r = t.roles;
        let l = cx.l10n().clone();
        let store = self.stores.tasks.read(cx);
        let list = store.list.clone();
        let entity = cx.entity().downgrade();
        let message = |text: String,
                       hint: Option<String>,
                       action: Option<(&'static str, String)>| {
            let entity = entity.clone();
            div()
                .id("tasks-empty")
                .role(Role::Status)
                .flex_1()
                .flex()
                .flex_col()
                .items_center()
                .justify_center()
                .gap(px(8.))
                .px(px(24.))
                .text_center()
                .child(
                    div()
                        .text_size(px(t.metrics.control))
                        .text_color(r.text_subtle)
                        .child(SharedString::from(text)),
                )
                .when_some(hint, |d, h| {
                    d.child(
                        div()
                            .text_size(px(t.metrics.small))
                            .line_height(relative(1.35))
                            .text_color(r.text_subtle)
                            .child(SharedString::from(h)),
                    )
                })
                .when_some(action, |d, (id, label)| {
                    d.child(
                        Button::new(id, label).on_click(Rc::new(move |_, window, cx| {
                            let _ = entity.update(cx, |p, cx| match id {
                                "tasks-retry" => p.stores.tasks.update(cx, |t, cx| t.refresh(cx)),
                                "tasks-show-all" => {
                                    p.search
                                        .update(cx, |s, cx| s.set_value(String::new(), window, cx));
                                    p.stores.tasks.update(cx, |t, cx| t.show_all(cx))
                                }
                                _ => p.new_task(window, cx),
                            });
                        })),
                    )
                })
                .into_any_element()
        };
        let Some(list) = list else {
            if store.error.is_some() {
                return message(
                    l.scheduled_tasks_load_failed(),
                    None,
                    Some(("tasks-retry", l.desktop_try_again())),
                );
            }
            return message(l.desktop_loading(), None, None);
        };
        if let Some(failure) = list.failure.as_deref() {
            return message(
                failure_text(failure, l.scheduled_tasks_load_failed(), &l),
                None,
                Some(("tasks-retry", l.desktop_try_again())),
            );
        }
        if list.items.is_empty() {
            let filtered = !list.query.is_empty() || list.status != "all";
            return if filtered {
                message(
                    l.scheduled_tasks_empty_filtered(),
                    None,
                    Some(("tasks-show-all", l.scheduled_tasks_show_all())),
                )
            } else {
                message(
                    l.scheduled_tasks_empty(),
                    Some(l.scheduled_tasks_empty_hint()),
                    Some(("tasks-empty-add", l.scheduled_tasks_add())),
                )
            };
        }
        let count = list.items.len() + usize::from(list.has_more);
        let mut sizes = vec![size(px(LIST_WIDTH), px(ROW_HEIGHT)); list.items.len()];
        if list.has_more {
            sizes.push(size(px(LIST_WIDTH), px(MORE_HEIGHT)));
        }
        let _ = count;
        div()
            .flex_1()
            .min_h_0()
            .flex()
            .flex_col()
            .when(list.stale, |d| {
                let entity = entity.clone();
                d.child(
                    div()
                        .id("tasks-stale")
                        .role(Role::Status)
                        .flex_none()
                        .px(px(14.))
                        .py(px(8.))
                        .flex()
                        .items_center()
                        .gap(px(8.))
                        .child(
                            div()
                                .flex_1()
                                .text_size(px(t.metrics.small))
                                .text_color(r.text_subtle)
                                .child(SharedString::from(l.desktop_tasks_stale())),
                        )
                        .child(
                            Button::new("tasks-stale-retry", l.desktop_try_again())
                                .ghost()
                                .on_click(Rc::new(move |_, _, cx| {
                                    let _ = entity.update(cx, |p, cx| {
                                        p.stores.tasks.update(cx, |t, cx| t.refresh(cx))
                                    });
                                })),
                        ),
                )
            })
            .child(
                v_virtual_list(
                    cx.entity(),
                    "tasks-rows",
                    Rc::new(sizes),
                    |this, range, window, cx| this.render_rows(range, window, cx),
                )
                .track_scroll(&self.scroll)
                .flex_1(),
            )
            .into_any_element()
    }

    // ── Drawing: the task ──────────────────────────────────────────────

    fn progress_notice(
        &self,
        progress: Option<&AutomationRunProgress>,
        l: &L10n,
        cx: &App,
    ) -> Option<AnyElement> {
        let t = cx.conduit();
        let r = t.roles;
        let p = progress?;
        let (text, error) = match p.phase.as_str() {
            "requesting" | "waiting" => (l.scheduled_task_running(), false),
            "finished" => (l.scheduled_task_run_finished(), false),
            "failed" => (l.scheduled_task_run_failed_notice(), true),
            "timedOut" => (l.scheduled_task_run_requested(), false),
            _ => (
                failure_text(
                    p.failure.as_deref()?,
                    l.scheduled_task_run_request_failed(),
                    l,
                ),
                true,
            ),
        };
        Some(
            div()
                .id("tasks-run-notice")
                .role(Role::Status)
                .text_size(px(t.metrics.small + 0.5))
                .line_height(relative(1.4))
                .text_color(if error { r.danger } else { r.text_subtle })
                .child(SharedString::from(text))
                .into_any_element(),
        )
    }

    fn detail_column(&mut self, window: &mut Window, cx: &mut Context<Self>) -> AnyElement {
        let t = cx.conduit().clone();
        let r = t.roles;
        let l = cx.l10n().clone();
        let store = self.stores.tasks.read(cx);
        let Some(id) = store.selected.clone() else {
            return div()
                .id("tasks-no-selection")
                .role(Role::Status)
                .flex_1()
                .min_w_0()
                .h_full()
                .flex()
                .flex_col()
                .items_center()
                .justify_center()
                .gap(px(8.))
                .px(px(32.))
                .text_center()
                .child(icon(IconName::CalendarClock, 28., r.text_faint))
                .child(
                    div()
                        .text_size(px(t.metrics.control))
                        .text_color(r.text_subtle)
                        .child(SharedString::from(l.desktop_tasks_select())),
                )
                .child(
                    div()
                        .max_w(px(360.))
                        .text_size(px(t.metrics.small))
                        .line_height(relative(1.35))
                        .text_color(r.text_subtle)
                        .child(SharedString::from(l.desktop_scheduled_tasks_description())),
                )
                .into_any_element();
        };
        let Some(detail) = store.detail.clone() else {
            let text = store
                .detail_error
                .as_ref()
                .map(|e| error_text(e, l.scheduled_tasks_load_failed(), &l))
                .unwrap_or_else(|| l.desktop_loading());
            return div()
                .id("tasks-detail-loading")
                .role(Role::Status)
                .flex_1()
                .flex()
                .items_center()
                .justify_center()
                .text_size(px(t.metrics.control))
                .text_color(r.text_subtle)
                .child(SharedString::from(text))
                .into_any_element();
        };
        let progress = store.progress.get(&id).cloned();
        let busy = store.busy;
        let runs = store.runs.clone();
        let runs_more = store.runs_more;
        let runs_loading = store.runs_loading;
        let runs_failed = store.runs_failed;
        let change_error = store
            .change_error
            .as_ref()
            .map(|e| error_text(e, l.scheduled_task_change_failed(), &l));
        let running = progress
            .as_ref()
            .is_some_and(|p| matches!(p.phase.as_str(), "requesting" | "waiting"));
        let entity = cx.entity().downgrade();
        let summary = detail.summary.clone();

        let (active_e, run_e, edit_e, delete_e) = (
            entity.clone(),
            entity.clone(),
            entity.clone(),
            entity.clone(),
        );
        let (run_id, edit_id, delete_id, toggle_id) =
            (id.clone(), id.clone(), id.clone(), id.clone());
        let header = div()
            .flex()
            .flex_col()
            .gap(px(10.))
            .child(
                div()
                    .flex()
                    .items_center()
                    .gap(px(12.))
                    .child(
                        heading(
                            "tasks-title",
                            SharedString::from(summary.name.clone()),
                            1,
                            t.metrics.body + 6.,
                            FontWeight::SEMIBOLD,
                            r.text,
                        )
                        .flex_1()
                        .min_w_0(),
                    )
                    .child(
                        div()
                            .flex()
                            .items_center()
                            .gap(px(8.))
                            .text_size(px(t.metrics.control))
                            .text_color(r.text_subtle)
                            .child(SharedString::from(l.scheduled_task_active_label()))
                            .child(
                                Switch::new(
                                    "tasks-active",
                                    l.scheduled_task_active_label(),
                                    summary.active,
                                )
                                .disabled(busy || running)
                                .on_click(Rc::new({
                                    let on = summary.active;
                                    move |_, _, cx| {
                                        let id = toggle_id.clone();
                                        let _ =
                                            active_e.update(cx, |p, cx| p.set_active(&id, !on, cx));
                                    }
                                })),
                            ),
                    ),
            )
            .child(
                div()
                    .flex()
                    .items_center()
                    .gap(px(8.))
                    .child(
                        Button::new("tasks-run", l.scheduled_task_run_now())
                            .icon(IconName::Play)
                            .disabled(running || busy)
                            .on_click(Rc::new(move |_, _, cx| {
                                let id = run_id.clone();
                                let _ = run_e.update(cx, |p, cx| p.run(&id, cx));
                            })),
                    )
                    .child(
                        Button::new("tasks-edit", l.desktop_edit_ellipsis()).on_click(Rc::new(
                            move |_, window, cx| {
                                let id = edit_id.clone();
                                let _ = edit_e.update(cx, |p, cx| p.edit(&id, window, cx));
                            },
                        )),
                    )
                    .child(div().flex_1())
                    .child(
                        Button::new("tasks-delete", l.desktop_delete_ellipsis())
                            .danger()
                            .disabled(busy)
                            .on_click(Rc::new(move |_, window, cx| {
                                let id = delete_id.clone();
                                let _ = delete_e.update(cx, |p, cx| p.delete(&id, window, cx));
                            })),
                    ),
            );

        let mut body: Vec<AnyElement> = vec![header.into_any_element()];
        if let Some(notice) = self.progress_notice(progress.as_ref(), &l, cx) {
            body.push(notice);
        }
        if let Some(error) = change_error {
            body.push(forms::form_error("tasks-error", error, cx).into_any_element());
        }
        body.push(self.info_group(&detail, &runs, &l, cx));
        body.push(self.next_runs(&detail, &l, cx));
        body.push(
            grouped_section(
                Some(l.scheduled_task_prompt_section().into()),
                vec![
                    div()
                        .id("tasks-prompt")
                        .px(px(12.))
                        .py(px(10.))
                        .text_size(px(t.metrics.control))
                        .line_height(relative(1.4))
                        .text_color(r.text)
                        .child(SharedString::from(detail.prompt.clone()))
                        .into_any_element(),
                ],
                None,
                cx,
            )
            .into_any_element(),
        );
        body.push(self.history(
            &id,
            &runs,
            runs_more,
            runs_loading,
            runs_failed,
            &l,
            window,
            cx,
        ));
        let (page, _) = conduit_components::views::kit::grouped_tones(&t);
        div()
            .id("tasks-detail")
            .flex_1()
            .min_w_0()
            .h_full()
            .bg(page)
            .overflow_y_scroll()
            .child(
                div()
                    .max_w(px(680.))
                    .px(px(28.))
                    .py(px(20.))
                    .flex()
                    .flex_col()
                    .gap(px(18.))
                    .children(body),
            )
            .into_any_element()
    }

    fn info_group(
        &self,
        detail: &AutomationDetail,
        runs: &[AutomationRunDto],
        l: &L10n,
        cx: &App,
    ) -> AnyElement {
        let t = cx.conduit();
        let value = |text: String| {
            div()
                .max_w(px(320.))
                .truncate()
                .text_size(px(t.metrics.control))
                .text_color(t.roles.text_subtle)
                .child(SharedString::from(text))
        };
        let destination = if detail.target == "channel" {
            [
                Some(l.scheduled_task_destination_channel()),
                detail.channel_name.clone().map(|n| format!("#{n}")),
            ]
            .into_iter()
            .flatten()
            .collect::<Vec<_>>()
            .join(" · ")
        } else {
            [
                Some(l.scheduled_task_destination_chat()),
                detail.folder_name.clone(),
            ]
            .into_iter()
            .flatten()
            .collect::<Vec<_>>()
            .join(" · ")
        };
        // The newest run known: the history's, else the list's.
        let last = runs
            .first()
            .and_then(|r| r.created_at)
            .or(detail.summary.last_run_at);
        let last = last
            .map(|ms| when(ms, l))
            .unwrap_or_else(|| l.scheduled_task_never_run());
        let model = detail
            .model_name
            .clone()
            .unwrap_or_else(|| detail.model_id.clone());
        grouped_section(
            None,
            vec![
                setting_row(
                    l.scheduled_task_schedule_label(),
                    None,
                    value(schedule_summary(&detail.summary.schedule, l)),
                    cx,
                )
                .into_any_element(),
                setting_row(l.scheduled_task_model_label(), None, value(model), cx)
                    .into_any_element(),
            ]
            .into_iter()
            .chain(detail.terminal_id.clone().map(|id| {
                let name = detail.terminal_name.clone().unwrap_or(id);
                setting_row(l.terminal(), None, value(name), cx).into_any_element()
            }))
            .chain(detail.working_directory.clone().map(|folder| {
                setting_row(
                    l.scheduled_task_working_folder_label(),
                    None,
                    value(folder),
                    cx,
                )
                .into_any_element()
            }))
            .chain([
                setting_row(
                    l.scheduled_task_destination_label(),
                    None,
                    value(destination),
                    cx,
                )
                .into_any_element(),
                setting_row(l.desktop_tasks_last_run(), None, value(last), cx).into_any_element(),
            ])
            .collect(),
            Some(l.scheduled_task_timezone_note().into()),
            cx,
        )
        .into_any_element()
    }

    fn next_runs(&self, detail: &AutomationDetail, l: &L10n, cx: &App) -> AnyElement {
        let t = cx.conduit();
        let rows: Vec<AnyElement> = if detail.next_runs.is_empty() {
            vec![
                div()
                    .id("tasks-no-next-runs")
                    .px(px(12.))
                    .py(px(10.))
                    .text_size(px(t.metrics.control))
                    .text_color(t.roles.text_subtle)
                    .child(SharedString::from(if detail.summary.active {
                        l.scheduled_task_no_next_run()
                    } else {
                        l.scheduled_task_status_paused()
                    }))
                    .into_any_element(),
            ]
        } else {
            detail
                .next_runs
                .iter()
                .enumerate()
                .map(|(i, ms)| {
                    div()
                        .id(ElementId::NamedInteger("tasks-next-run".into(), i as u64))
                        .px(px(12.))
                        .py(px(8.))
                        .text_size(px(t.metrics.control))
                        .child(SharedString::from(when(*ms, l)))
                        .into_any_element()
                })
                .collect()
        };
        grouped_section(
            Some(l.scheduled_task_next_runs_label().into()),
            rows,
            None,
            cx,
        )
        .into_any_element()
    }

    #[allow(clippy::too_many_arguments)]
    fn history(
        &self,
        id: &str,
        runs: &[AutomationRunDto],
        more: bool,
        loading: bool,
        failed: bool,
        l: &L10n,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let t = cx.conduit().clone();
        let r = t.roles;
        let entity = cx.entity().downgrade();
        let mut rows: Vec<AnyElement> = runs
            .iter()
            .enumerate()
            .map(|(i, run)| {
                let status = if run.succeeded {
                    l.scheduled_task_run_succeeded()
                } else {
                    l.scheduled_task_run_failed_status()
                };
                let time = run.created_at.map(|ms| when(ms, l)).unwrap_or_default();
                let subtitle = [Some(time), run.error.clone()]
                    .into_iter()
                    .flatten()
                    .filter(|s| !s.is_empty())
                    .collect::<Vec<_>>()
                    .join(" · ");
                let open = run
                    .result_channel_id
                    .as_ref()
                    .map(|_| l.scheduled_task_view_channel())
                    .or_else(|| {
                        run.result_chat_id
                            .as_ref()
                            .map(|_| l.scheduled_task_view_chat())
                    });
                let entity = entity.clone();
                let chosen = run.clone();
                div()
                    .id(ElementId::NamedInteger("tasks-run-row".into(), i as u64))
                    .child(setting_row(
                        status,
                        Some(subtitle.into()),
                        match open {
                            Some(label) => Button::new(
                                ElementId::NamedInteger("tasks-run-open".into(), i as u64),
                                label,
                            )
                            .on_click(Rc::new(move |_, _, cx| {
                                let run = chosen.clone();
                                let _ = entity.update(cx, |p, cx| p.open_result(&run, cx));
                            }))
                            .into_any_element(),
                            None => div().into_any_element(),
                        },
                        cx,
                    ))
                    .into_any_element()
            })
            .collect();
        let reload = |id: &str, more: bool| {
            let entity = entity.clone();
            let id = id.to_string();
            Rc::new(
                move |_: &gpui_kit::ClickEvent, _: &mut Window, cx: &mut App| {
                    let id = id.clone();
                    let _ = entity.update(cx, |p, cx| {
                        p.stores
                            .tasks
                            .update(cx, |t, cx| t.load_runs(&id, more, cx))
                    });
                },
            )
        };
        if failed {
            rows.push(
                setting_row(
                    l.scheduled_task_history_load_failed(),
                    None,
                    Button::new("tasks-history-retry", l.desktop_try_again())
                        .on_click(reload(id, !runs.is_empty())),
                    cx,
                )
                .into_any_element(),
            );
        } else if runs.is_empty() {
            rows.push(
                div()
                    .id("tasks-history-empty")
                    .px(px(12.))
                    .py(px(10.))
                    .text_size(px(t.metrics.control))
                    .text_color(r.text_subtle)
                    .child(SharedString::from(if loading {
                        l.desktop_loading()
                    } else {
                        l.scheduled_task_history_empty()
                    }))
                    .into_any_element(),
            );
        } else if more {
            rows.push(
                div()
                    .px(px(12.))
                    .py(px(6.))
                    .child(
                        Button::new(
                            "tasks-history-more",
                            if loading {
                                l.desktop_loading()
                            } else {
                                l.scheduled_tasks_load_more()
                            },
                        )
                        .ghost()
                        .disabled(loading)
                        .on_click(reload(id, true)),
                    )
                    .into_any_element(),
            );
        }
        let _ = window;
        grouped_section(
            Some(l.scheduled_task_history_title().into()),
            rows,
            None,
            cx,
        )
        .into_any_element()
    }

    /// What the pane shows when Advanced is off, or the server does not
    /// allow scheduled tasks.
    fn gate(&self, cx: &mut Context<Self>) -> AnyElement {
        let t = cx.conduit().clone();
        let r = t.roles;
        let l = cx.l10n().clone();
        let c = self.stores.session.read(cx).capabilities();
        let app_settings = self.stores.app_settings.clone();
        let mut page = div()
            .id("tasks-gate")
            .role(Role::Status)
            .flex_1()
            .flex()
            .flex_col()
            .items_center()
            .justify_center()
            .gap(px(10.))
            .px(px(40.))
            .pb(px(40.))
            .text_center()
            .child(icon(IconName::CalendarClock, 28., r.text_faint));
        if c.automations {
            page = page
                .child(
                    div()
                        .text_size(px(t.metrics.body + 2.))
                        .font_weight(FontWeight::SEMIBOLD)
                        .child(SharedString::from(l.advanced_required_title())),
                )
                .child(
                    div()
                        .max_w(px(420.))
                        .text_size(px(t.metrics.control))
                        .line_height(relative(1.4))
                        .text_color(r.text_subtle)
                        .child(SharedString::from(
                            l.advanced_required_message(&l.scheduled_tasks_title()),
                        )),
                )
                .child(
                    Button::new("tasks-turn-on-advanced", l.advanced_turn_on())
                        .primary()
                        .on_click(Rc::new(move |_, _, cx| {
                            app_settings.update(cx, |s, cx| {
                                s.set(
                                    AppSettingsPatch {
                                        advanced_features_enabled: Some(true),
                                        ..Default::default()
                                    },
                                    cx,
                                )
                            })
                        })),
                );
        } else {
            page = page.child(
                div()
                    .max_w(px(420.))
                    .text_size(px(t.metrics.control))
                    .text_color(r.text_subtle)
                    .child(SharedString::from(l.scheduled_tasks_unavailable())),
            );
        }
        page.into_any_element()
    }
}

impl Focusable for TasksPane {
    fn focus_handle(&self, _: &App) -> FocusHandle {
        self.focus.clone()
    }
}

impl Render for TasksPane {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let t = cx.conduit().clone();
        let r = t.roles;
        let l = cx.l10n().clone();
        if !self.usable(cx) {
            return div()
                .id("tasks-pane")
                .flex_1()
                .min_h_0()
                .w_full()
                .flex()
                .bg(r.content)
                .child(self.gate(cx))
                .into_any_element();
        }
        // Advanced just came on: the list is asked for once.
        if !self.asked {
            self.show(cx);
        }
        let header = self.list_header(window, cx);
        let body = self.list_body(cx);
        let detail = self.detail_column(window, cx);
        let focus = self.focus.clone();
        div()
            .id("tasks-pane")
            .key_context("TasksPane")
            .track_focus(&self.focus)
            .flex_1()
            .min_h_0()
            .w_full()
            .flex()
            .bg(r.content)
            .on_mouse_down(MouseButton::Left, move |_, window, cx| {
                if !focus.contains_focused(window, cx) {
                    window.focus(&focus, cx);
                }
            })
            .on_action(cx.listener(|this, a: &TaskMenu, window, cx| this.on_menu(a, window, cx)))
            .on_key_down(cx.listener(|this, e: &gpui_kit::KeyDownEvent, window, cx| {
                if this.on_key(e, window, cx) {
                    cx.stop_propagation();
                }
            }))
            .child(
                div()
                    .id("tasks-list")
                    .role(Role::List)
                    .aria_label(SharedString::from(l.scheduled_tasks_title()))
                    .w(px(LIST_WIDTH))
                    .flex_none()
                    .h_full()
                    .flex()
                    .flex_col()
                    .border_r_1()
                    .border_color(r.divider)
                    .child(header)
                    .child(body),
            )
            .child(detail)
            .into_any_element()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn schedules_read_as_the_phone_says_them() {
        let l = L10n::new("en");
        let schedule = |kind: &str| AutomationScheduleDto {
            kind: kind.into(),
            year: 0,
            month: 0,
            day: 0,
            hour: 9,
            minute: 0,
            days: vec![],
            rrule: String::new(),
        };
        let daily = AutomationScheduleDto {
            hour: 7,
            minute: 30,
            ..schedule("daily")
        };
        assert!(schedule_summary(&daily, &l).starts_with("Daily at "));
        let weekly = AutomationScheduleDto {
            days: vec!["FR".into(), "MO".into()],
            ..schedule("weekly")
        };
        let text = schedule_summary(&weekly, &l);
        assert!(
            text.find("Mon").unwrap() < text.find("Fri").unwrap(),
            "Monday first: {text}"
        );
        let custom = AutomationScheduleDto {
            rrule: "FREQ=MONTHLY".into(),
            ..schedule("custom")
        };
        assert_eq!(
            schedule_summary(&custom, &l),
            l.scheduled_task_schedule_custom()
        );
    }

    #[test]
    fn refusals_read_in_the_apps_words_or_the_servers() {
        let l = L10n::new("en");
        assert_eq!(
            failure_text("accountChanged", "x".into(), &l),
            l.scheduled_tasks_account_changed()
        );
        assert_eq!(failure_text("failed", "fallback".into(), &l), "fallback");
        assert_eq!(
            failure_text("Schedule too frequent.", "x".into(), &l),
            "Schedule too frequent."
        );
    }

    /// The task editor opened for one account closes when another signs in;
    /// words typed in it are not dropped without a question, whether Cancel
    /// or Quit comes before the daemon has checked them.
    #[gpui_kit::test]
    fn the_task_editor_asks_before_typed_words_go_and_closes_on_another_account(
        cx: &mut gpui_kit::TestAppContext,
    ) {
        use conduit_protocol::methods;

        use crate::views::sheet::{
            self, SheetBody as _,
            bench::{bench, switch_account},
        };
        let (daemon, stores, vcx) = bench(cx);
        daemon.on::<methods::AutomationsEditor>(|_| {
            Ok(serde_json::json!({
                "token": "te-1",
                "isNew": true,
                "fields": {
                    "name": "",
                    "prompt": "",
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
        // The daemon has not answered a check yet.
        let held = daemon.hold::<methods::AutomationsCheckDraft>();
        let s = stores.clone();
        vcx.update(|window, cx| editor::open(s, None, window, cx));
        vcx.run_until_parked();
        let task = vcx
            .update(|_, cx| sheet::current::<editor::TaskEditor>(cx))
            .expect("the editor opens");
        vcx.update(|window, cx| {
            task.update(cx, |e, cx| {
                e.type_text("Allotment digest", "List what to sow this week", window, cx)
            })
        });
        // Cancel, then Quit; each question is answered Keep Editing.
        vcx.update(|window, cx| task.update(cx, |e, cx| e.cancel(window, cx)));
        vcx.run_until_parked();
        assert!(
            vcx.update(|_, cx| sheet::current::<editor::TaskEditor>(cx))
                .is_some(),
            "Cancel dropped the typed task without asking"
        );
        vcx.update(|_, cx| sheet::quit(cx));
        vcx.run_until_parked();
        assert!(
            vcx.update(|_, cx| sheet::current::<editor::TaskEditor>(cx))
                .is_some(),
            "Quit dropped the typed task without asking"
        );
        drop(held);
        switch_account(&stores, vcx);
        assert!(
            !vcx.update(|_, cx| sheet::is_open(cx)),
            "Avery's task editor stayed open over Blake's account"
        );
        assert!(daemon.calls::<methods::AutomationsSave>().is_empty());
    }

    /// Words typed while a task saves stay in the editor, which stays open
    /// on the task saved, and the next Save takes them.
    #[gpui_kit::test]
    fn words_typed_while_a_task_saves_stay_for_the_next_save(cx: &mut gpui_kit::TestAppContext) {
        use conduit_protocol::methods;

        use crate::views::sheet::{self, bench::bench};
        let (daemon, stores, vcx) = bench(cx);
        daemon.on::<methods::AutomationsEditor>(|_| {
            Ok(serde_json::json!({
                "token": "te-1",
                "isNew": true,
                "fields": {
                    "name": "",
                    "prompt": "",
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
        daemon.on::<methods::AutomationsSave>(|p| {
            Ok(serde_json::json!({"fields": p["fields"], "saved": true, "id": "t1"}))
        });
        let s = stores.clone();
        vcx.update(|window, cx| editor::open(s, None, window, cx));
        vcx.run_until_parked();
        let task = vcx
            .update(|_, cx| sheet::current::<editor::TaskEditor>(cx))
            .expect("the editor opens");
        vcx.update(|window, cx| {
            task.update(cx, |e, cx| {
                e.type_text("Allotment digest", "List what to sow this week", window, cx)
            })
        });
        vcx.run_until_parked();
        let held = daemon.hold_one::<methods::AutomationsSave>(0);
        vcx.update(|window, cx| task.update(cx, |e, cx| e.save(window, cx)));
        vcx.run_until_parked();
        // Typed while the save is out.
        vcx.update(|window, cx| {
            task.update(cx, |e, cx| {
                e.type_text(
                    "Allotment digest",
                    "List what to sow and to harvest",
                    window,
                    cx,
                )
            })
        });
        drop(held);
        vcx.run_until_parked();
        assert!(
            vcx.update(|_, cx| sheet::current::<editor::TaskEditor>(cx))
                .is_some_and(|e| e == task),
            "the editor closed over the words typed while it saved"
        );
        vcx.update(|window, cx| task.update(cx, |e, cx| e.save(window, cx)));
        vcx.run_until_parked();
        let saves = daemon.calls::<methods::AutomationsSave>();
        assert_eq!(saves.len(), 2);
        assert_eq!(
            saves[1]["fields"]["prompt"],
            "List what to sow and to harvest"
        );
        assert!(
            !vcx.update(|_, cx| sheet::is_open(cx)),
            "the editor stays open once everything typed is saved"
        );
    }

    /// A task delete confirmed after another account signed in is never
    /// sent: the question closes with the account it was asked for.
    #[gpui_kit::test]
    fn a_task_delete_is_never_sent_under_another_account(cx: &mut gpui_kit::TestAppContext) {
        use conduit_protocol::methods;

        use crate::stores::accounts::tests::{account, list};
        use crate::views::sheet::bench::bench;
        let (daemon, stores, vcx) = bench(cx);
        vcx.update(|_, cx| cx.set_global(crate::shell::sheet::AutoAnswer(Some(true))));
        let s = stores.clone();
        let pane = vcx.update(|window, cx| cx.new(|cx| TasksPane::new(s, window, cx)));
        vcx.update(|window, cx| {
            pane.update(cx, |p, cx| p.delete("avery-digest", window, cx));
            stores.accounts.update(cx, |a, cx| {
                a.adopt(
                    list(vec![
                        account("a", "Avery", false, true),
                        account("b", "Blake", true, true),
                    ]),
                    cx,
                )
            });
        });
        vcx.run_until_parked();
        assert!(
            daemon.calls::<methods::AutomationsDelete>().is_empty(),
            "Avery's task delete went out under Blake's account"
        );
    }

    /// A Discard answered for a task editor that has gone closes nothing
    /// else: the editor open by then (another account's) keeps its edits.
    #[gpui_kit::test]
    fn a_late_discard_closes_only_its_own_task_editor(cx: &mut gpui_kit::TestAppContext) {
        use conduit_protocol::methods;

        use crate::stores::accounts::tests::{account, list};
        use crate::views::sheet::{self, SheetBody as _, bench::bench};
        let (daemon, stores, vcx) = bench(cx);
        daemon.on::<methods::AutomationsEditor>(|_| {
            Ok(serde_json::json!({
                "token": "te-1",
                "isNew": true,
                "fields": {
                    "name": "",
                    "prompt": "",
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
        let open = |vcx: &mut gpui_kit::VisualTestContext, words: &str| {
            let s = stores.clone();
            vcx.update(|window, cx| editor::open(s, None, window, cx));
            let task = vcx
                .update(|_, cx| sheet::current::<editor::TaskEditor>(cx))
                .expect("the editor opens");
            vcx.run_until_parked();
            vcx.update(|window, cx| {
                task.update(cx, |e, cx| {
                    e.type_text(words, "Sow by the moon", window, cx)
                })
            });
            task
        };
        let first = open(vcx, "Avery's digest");
        // Avery's editor asks to discard; the answer will be Discard.
        vcx.update(|_, cx| cx.set_global(crate::shell::sheet::AutoAnswer(Some(true))));
        vcx.update(|window, cx| first.update(cx, |e, cx| e.cancel(window, cx)));
        // Before it answers, Blake signs in (Avery's editor closes) and opens
        // a task editor of his own.
        stores.accounts.update(vcx, |a, cx| {
            a.adopt(
                list(vec![
                    account("a", "Avery", false, true),
                    account("b", "Blake", true, true),
                ]),
                cx,
            )
        });
        let second = open(vcx, "Blake's digest");
        vcx.run_until_parked();
        assert!(
            vcx.update(|_, cx| sheet::current::<editor::TaskEditor>(cx))
                .is_some_and(|open| open == second),
            "Avery's Discard closed Blake's task editor"
        );
    }

    /// A search typed under one account never goes to the next: another
    /// account's sign-in clears the field and the search waiting to go.
    #[gpui_kit::test]
    fn a_search_typed_for_one_account_never_goes_to_the_next(cx: &mut gpui_kit::TestAppContext) {
        use conduit_protocol::methods;

        use crate::views::sheet::bench::{bench, switch_account};
        let (daemon, stores, vcx) = bench(cx);
        let s = stores.clone();
        let pane = vcx.update(|window, cx| cx.new(|cx| TasksPane::new(s, window, cx)));
        // Avery types; the search waits a moment before it goes.
        vcx.update(|window, cx| {
            pane.update(cx, |p, cx| {
                p.search
                    .update(cx, |i, cx| i.set_value("allotment digest", window, cx));
                p.search_soon("allotment digest".into(), cx);
            })
        });
        switch_account(&stores, vcx);
        vcx.executor().advance_clock(Duration::from_secs(1));
        vcx.run_until_parked();
        assert!(
            daemon
                .calls::<methods::AutomationsList>()
                .iter()
                .all(|q| q["query"] != "allotment digest"),
            "Avery's search went to Blake's server"
        );
        assert_eq!(
            pane.read_with(vcx, |p, cx| p.search.read(cx).value().to_string()),
            "",
            "Avery's search stayed in the field"
        );
    }

    /// Once Tab has reached a task row, the arrows move the selection as
    /// they do from the list itself (Full Keyboard Access or not).
    #[gpui_kit::test]
    fn the_arrows_move_from_a_focused_task_row(cx: &mut gpui_kit::TestAppContext) {
        use conduit_protocol::{Capabilities, methods};

        use crate::stores::accounts::tests::{account, list};
        use crate::stores::rpc::fake::FakeDaemon;
        let daemon = FakeDaemon::new();
        let summary = |id: &str, name: &str| {
            serde_json::json!({
                "id": id,
                "name": name,
                "active": true,
                "schedule": {
                    "kind": "daily", "year": 0, "month": 0, "day": 0,
                    "hour": 8, "minute": 0, "days": [],
                    "rrule": "RRULE:FREQ=DAILY;BYHOUR=8;BYMINUTE=0"
                }
            })
        };
        let listed = serde_json::json!({
            "available": true,
            "items": [summary("t1", "Allotment digest"), summary("t2", "Seed order")],
            "total": 2,
            "hasMore": false
        });
        daemon.on::<methods::AutomationsList>(move |_| Ok(listed.clone()));
        let scratch =
            std::env::temp_dir().join(format!("conduit-tasks-keys-{}", std::process::id()));
        let stores = cx.update(|cx| {
            crate::views::test_globals(cx);
            Stores::for_test(daemon.rpc(), &scratch, cx)
        });
        stores.accounts.update(cx, |a, cx| {
            a.adopt(list(vec![account("a", "Avery", true, true)]), cx)
        });
        stores.session.update(cx, |s, cx| {
            s.system_capabilities = Some(Capabilities {
                automations: true,
                scheduled_tasks: true,
                ..Default::default()
            });
            cx.notify();
        });
        let s = stores.clone();
        let (pane, vcx) = cx.add_window_view(move |window, cx| TasksPane::new(s, window, cx));
        vcx.run_until_parked();
        let draw = |vcx: &mut gpui_kit::VisualTestContext| {
            vcx.update(|window, cx| window.draw(cx).clear(cx));
            vcx.run_until_parked();
        };
        draw(vcx);
        let on_a_row = |vcx: &mut gpui_kit::VisualTestContext| {
            vcx.update(|window, cx| {
                let p = pane.read(cx);
                p.focus.contains_focused(window, cx)
                    && !p.focus.is_focused(window)
                    && !p.search.read(cx).focus_handle(cx).is_focused(window)
            })
        };
        for _ in 0..12 {
            if on_a_row(vcx) {
                break;
            }
            vcx.update(|window, cx| window.focus_next(cx));
            draw(vcx);
        }
        assert!(on_a_row(vcx), "Tab never reached a task row");
        let before = stores.tasks.read_with(vcx, |t, _| t.selected.clone());
        vcx.simulate_keystrokes("down");
        vcx.run_until_parked();
        assert_ne!(
            stores.tasks.read_with(vcx, |t, _| t.selected.clone()),
            before,
            "Down on a focused task row moved nothing"
        );
    }
}
