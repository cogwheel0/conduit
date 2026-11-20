//! The Calendar pane (the sidebar's Calendar › Upcoming): the account's
//! calendars in a column, as Calendar's sidebar lists them, beside an agenda
//! of the days in the range, as the phone's Calendar page shows it.
//!
//! * **Calendars**: a checkbox shows or hides each calendar's events (one
//!   stays shown), a dot gives its colour, and its badges say Default,
//!   Shared or Read-only. Its context menu makes one of the account's own
//!   its default; New Calendar… creates a private one.
//! * **Agenda**: the range's days, each with its events and scheduled-task
//!   runs; ‹ and › (⌘← ⌘→) move a page, Today (⌘T) comes back. A row opens
//!   the event sheet ([`event_sheet`]); New Event opens the editor
//!   ([`editor`]). ↑/↓ choose a row, ↩ opens it, ⌘⌫ deletes an event.
//!
//! Everything comes from the daemon (`calendar.*`, [`CalendarStore`]); the
//! pane only draws it and sends the user's changes.
//!
//! [`CalendarStore`]: crate::stores::calendar::CalendarStore

pub mod editor;
pub mod event_sheet;
pub mod format;
pub mod new_calendar;

use std::rc::Rc;

use conduit_components::ActiveConduitTheme as _;
use conduit_components::announce::{Priority, live_text};
use conduit_components::assets::{IconName, icon};
use conduit_components::theme::with_alpha;
use conduit_components::views::focus::{ControlExt as _, Ring};
use conduit_components::views::kit::{Button, IconButton, heading};
use conduit_protocol::{CalendarAgenda, CalendarDto, CalendarItemDto, CalendarItemRef, methods};
use gpui_kit::component::native_menu::NativeMenu;
use gpui_kit::component::{VirtualListScrollHandle, v_virtual_list};
use gpui_kit::prelude::*;
use gpui_kit::{
    AnyElement, App, AsyncApp, Context, ElementId, FocusHandle, Focusable, FontWeight, Hsla,
    MouseButton, MouseDownEvent, Pixels, Point, Role, SharedString, Subscription, Window, div, px,
    size,
};

use crate::actions::CalendarMenu;
use crate::l10n::{ActiveL10n as _, L10n};
use crate::shell::sheet::SheetSpec;
use crate::stores::Stores;
use crate::views::settings::controls;

/// The calendars column's width.
pub const CALENDARS_WIDTH: f32 = 224.;
const DAY_HEIGHT: f32 = 34.;
const ITEM_HEIGHT: f32 = 50.;
const NOTICE_HEIGHT: f32 = 44.;
/// The agenda's width as the virtual list measures rows (it stretches).
const AGENDA_WIDTH: f32 = 640.;

/// One row of the agenda as drawn.
#[derive(Clone, Debug, PartialEq)]
pub enum AgendaRow {
    /// The agenda may be out of date.
    Stale,
    Day(usize),
    /// An item under day `.0`, at `.1` among its items.
    Item(usize, usize),
}

/// The agenda's rows, in order.
pub fn agenda_rows(agenda: &CalendarAgenda) -> Vec<AgendaRow> {
    let mut rows = vec![];
    if agenda.stale {
        rows.push(AgendaRow::Stale);
    }
    for (d, day) in agenda.days.iter().enumerate() {
        rows.push(AgendaRow::Day(d));
        for i in 0..day.items.len() {
            rows.push(AgendaRow::Item(d, i));
        }
    }
    rows
}

pub struct CalendarPane {
    stores: Stores,
    focus: FocusHandle,
    scroll: VirtualListScrollHandle,
    /// The chosen row: an item's key and the day it is listed under.
    pub selected: Option<(String, usize)>,
    _subscriptions: Vec<Subscription>,
}

impl CalendarPane {
    pub fn new(stores: Stores, window: &mut Window, cx: &mut Context<Self>) -> Self {
        let _ = window;
        let subscriptions = vec![cx.observe(&stores.calendar, |_, _, cx| cx.notify())];
        stores.calendar.update(cx, |c, cx| c.show(cx));
        Self {
            stores,
            focus: cx.focus_handle(),
            scroll: VirtualListScrollHandle::new(),
            selected: None,
            _subscriptions: subscriptions,
        }
    }

    /// The agenda's scroll (the perf fixture scrolls it).
    pub fn scroll_handle(&self) -> &VirtualListScrollHandle {
        &self.scroll
    }

    /// The pane is shown again: the agenda is read again.
    pub fn show(&mut self, cx: &mut Context<Self>) {
        self.stores.calendar.update(cx, |c, cx| c.show(cx));
    }

    fn agenda(&self, cx: &App) -> Option<CalendarAgenda> {
        self.stores.calendar.read(cx).agenda.clone()
    }

    fn item<'a>(agenda: &'a CalendarAgenda, key: &str) -> Option<&'a CalendarItemDto> {
        agenda
            .days
            .iter()
            .flat_map(|d| d.items.iter())
            .find(|i| i.key == key)
    }

    // ── Actions ────────────────────────────────────────────────────────

    pub fn previous(&mut self, cx: &mut Context<Self>) {
        self.stores.calendar.update(cx, |c, cx| c.shift(-1, cx));
    }

    pub fn next(&mut self, cx: &mut Context<Self>) {
        self.stores.calendar.update(cx, |c, cx| c.shift(1, cx));
    }

    pub fn today(&mut self, cx: &mut Context<Self>) {
        self.stores.calendar.update(cx, |c, cx| c.today(cx));
    }

    pub fn new_event(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let day = self.agenda(cx).and_then(|a| a.first_day);
        editor::open(self.stores.clone(), None, day, window, cx);
    }

    pub fn open(&mut self, key: &str, window: &mut Window, cx: &mut Context<Self>) {
        event_sheet::open(self.stores.clone(), key.to_string(), window, cx);
    }

    pub fn new_calendar(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        new_calendar::open(self.stores.clone(), window, cx);
    }

    /// Asks, then deletes the event behind `key` (its whole series).
    pub fn delete(&mut self, key: &str, window: &mut Window, cx: &mut Context<Self>) {
        let Some(agenda) = self.agenda(cx) else {
            return;
        };
        let Some(item) = Self::item(&agenda, key).cloned() else {
            return;
        };
        if item.kind != "event" || !item.editable {
            return;
        }
        confirm_delete(self.stores.clone(), item, None, window, cx);
    }

    pub fn on_menu(&mut self, a: &CalendarMenu, window: &mut Window, cx: &mut Context<Self>) {
        match a.command.as_str() {
            "make-default" => {
                let id = a.id.clone();
                self.stores
                    .calendar
                    .update(cx, |c, cx| c.make_default(&id, cx));
            }
            "only" => self.show_only(&a.id.clone(), cx),
            "open" => self.open(&a.id.clone(), window, cx),
            "edit" => editor::open(self.stores.clone(), Some(a.id.clone()), None, window, cx),
            "delete" => self.delete(&a.id.clone(), window, cx),
            _ => {}
        }
    }

    /// Shows `calendar_id` alone, hiding the others.
    fn show_only(&mut self, calendar_id: &str, cx: &mut Context<Self>) {
        let Some(agenda) = self.agenda(cx) else {
            return;
        };
        let calendar = self.stores.calendar.clone();
        calendar.update(cx, |c, cx| {
            if !agenda
                .calendars
                .iter()
                .any(|x| x.id == calendar_id && x.visible)
            {
                c.set_visible(calendar_id, true, cx);
            }
        });
        for other in agenda
            .calendars
            .iter()
            .filter(|c| c.id != calendar_id && c.visible)
        {
            let id = other.id.clone();
            calendar.update(cx, |c, cx| c.set_visible(&id, false, cx));
        }
    }

    fn set_visible(&mut self, id: &str, visible: bool, cx: &mut Context<Self>) {
        let id = id.to_string();
        self.stores
            .calendar
            .update(cx, |c, cx| c.set_visible(&id, visible, cx));
    }

    fn calendar_menu(
        &mut self,
        calendar: &CalendarDto,
        position: Point<Pixels>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let l = cx.l10n().clone();
        if !self.focus.contains_focused(window, cx) {
            window.focus(&self.focus, cx);
        }
        let agenda = self.agenda(cx);
        let mut menu = NativeMenu::new();
        if calendar.can_make_default {
            menu = menu.menu(
                l.calendar_make_default(),
                Box::new(CalendarMenu {
                    command: "make-default".into(),
                    id: calendar.id.clone(),
                }),
            );
        }
        if agenda.as_ref().is_some_and(|a| a.filterable) {
            menu = menu.menu(
                l.desktop_calendar_show_only(),
                Box::new(CalendarMenu {
                    command: "only".into(),
                    id: calendar.id.clone(),
                }),
            );
        }
        menu.show(position, window, cx);
    }

    fn item_menu(
        &mut self,
        item: &CalendarItemDto,
        position: Point<Pixels>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let l = cx.l10n().clone();
        if !self.focus.contains_focused(window, cx) {
            window.focus(&self.focus, cx);
        }
        let entry = |command: &str| {
            Box::new(CalendarMenu {
                command: command.into(),
                id: item.key.clone(),
            })
        };
        let mut menu = NativeMenu::new().menu(l.desktop_calendar_open_event(), entry("open"));
        if item.kind == "event" && item.editable {
            let (edit, delete) = if item.recurring {
                (
                    l.desktop_calendar_edit_series_ellipsis(),
                    l.desktop_calendar_delete_series_ellipsis(),
                )
            } else {
                (l.desktop_edit_ellipsis(), l.desktop_delete_ellipsis())
            };
            menu = menu
                .menu(edit, entry("edit"))
                .separator()
                .menu(delete, entry("delete"));
        }
        menu.show(position, window, cx);
    }

    fn on_key(
        &mut self,
        e: &gpui_kit::KeyDownEvent,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> bool {
        // The pane or an agenda row Tab reached.
        if !crate::views::list_has_keys(&self.focus, &[], window, cx) {
            return false;
        }
        let k = &e.keystroke;
        let m = &k.modifiers;
        let plain = !(m.platform || m.alt || m.control || m.shift);
        let command = m.platform && !(m.alt || m.control || m.shift);
        match k.key.as_str() {
            "left" if command => {
                self.previous(cx);
                true
            }
            "right" if command => {
                self.next(cx);
                true
            }
            "t" if command => {
                self.today(cx);
                true
            }
            "up" | "down" if plain => {
                self.move_selection(k.key == "down", cx);
                true
            }
            "enter" | "space" if plain => {
                if let Some((key, _)) = self.selected.clone() {
                    self.open(&key, window, cx);
                }
                true
            }
            "backspace" | "delete" if command => {
                if let Some((key, _)) = self.selected.clone() {
                    self.delete(&key, window, cx);
                }
                true
            }
            _ => false,
        }
    }

    fn move_selection(&mut self, down: bool, cx: &mut Context<Self>) {
        let Some(agenda) = self.agenda(cx) else {
            return;
        };
        let rows = agenda_rows(&agenda);
        let items: Vec<(usize, String, usize)> = rows
            .iter()
            .enumerate()
            .filter_map(|(r, row)| match row {
                AgendaRow::Item(d, i) => Some((r, agenda.days[*d].items[*i].key.clone(), *d)),
                _ => None,
            })
            .collect();
        if items.is_empty() {
            return;
        }
        let current = self
            .selected
            .as_ref()
            .and_then(|(key, d)| items.iter().position(|(_, k, day)| k == key && day == d));
        let next = match (down, current) {
            (true, None) => 0,
            (false, None) => items.len() - 1,
            (true, Some(i)) => (i + 1).min(items.len() - 1),
            (false, Some(i)) => i.saturating_sub(1),
        };
        let (row, key, day) = items[next].clone();
        // The pane has the keyboard, not the row: say which.
        if let Some(item) = agenda.days[day].items.iter().find(|i| i.key == key) {
            // With the day it is under and its time on that day, as the row
            // shows them: two events of one name are told apart, and so are
            // the two rows of an event that runs past midnight.
            // An event that goes on past this day says when it ends too
            // (the row's own time leaves that out).
            let l = cx.l10n();
            let on = &agenda.days[day].day;
            let mut row = format!(
                "{}, {}, {}",
                shown_title(item, l),
                format::day_heading(on, agenda.today.as_ref(), l),
                format::row_time(&item.time, l)
            );
            if let Some(ends) = format::ends_after(item, on, l) {
                row = format!("{row}, {ends}");
            }
            crate::views::a11y::announce_row(&row, next, items.len(), cx);
        }
        self.selected = Some((key, day));
        self.scroll
            .scroll_to_item(row, gpui_kit::ScrollStrategy::Nearest);
        cx.notify();
    }

    // ── Drawing ────────────────────────────────────────────────────────

    fn calendars_column(
        &mut self,
        agenda: Option<&CalendarAgenda>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let t = cx.conduit().clone();
        let r = t.roles;
        let l = cx.l10n().clone();
        let busy = self.stores.calendar.read(cx).busy;
        let entity = cx.entity().downgrade();
        let calendars: Vec<CalendarDto> = agenda
            .map(|a| {
                a.calendars
                    .iter()
                    // The scheduled-tasks calendar is one of several, as on
                    // the phone; alone it would only repeat the agenda.
                    .filter(|c| !c.scheduled || a.calendars.len() > 1)
                    .cloned()
                    .collect()
            })
            .unwrap_or_default();
        let filterable = agenda.is_some_and(|a| a.filterable);
        let shown = calendars.iter().filter(|c| c.visible).count();
        let rows: Vec<AnyElement> = calendars
            .iter()
            .enumerate()
            .map(|(i, calendar)| {
                let badges = badges(calendar, &l);
                let only = calendar.visible && shown <= 1;
                let dot = format::parse_color(calendar.color.as_deref()).unwrap_or(r.text_faint);
                let id = calendar.id.clone();
                let menu_calendar = calendar.clone();
                let toggle_entity = entity.clone();
                let label = if badges.is_empty() {
                    calendar.name.clone()
                } else {
                    format!("{}, {badges}", calendar.name)
                };
                let check = controls::checkbox(
                    ElementId::NamedInteger("calendar-visible".into(), i as u64),
                    SharedString::from(label.clone()),
                    calendar.visible,
                    Rc::new({
                        let id = id.clone();
                        let visible = calendar.visible;
                        move |_, _, cx| {
                            if !filterable || (visible && only) || busy {
                                return;
                            }
                            let id = id.clone();
                            let _ =
                                toggle_entity.update(cx, |p, cx| p.set_visible(&id, !visible, cx));
                        }
                    }),
                    window,
                    cx,
                )
                .when(!filterable || only, |d| d.opacity(0.55))
                .tip(
                    if !filterable || only {
                        l.desktop_calendar_last_shown()
                    } else if calendar.visible {
                        l.desktop_calendar_hide_events()
                    } else {
                        l.desktop_calendar_show_events()
                    },
                    None,
                );
                div()
                    .id(ElementId::NamedInteger("calendar-row".into(), i as u64))
                    .role(Role::Row)
                    .aria_label(SharedString::from(label))
                    .min_h(px(36.))
                    .px(px(12.))
                    .py(px(4.))
                    .flex()
                    .items_center()
                    .gap(px(9.))
                    .rounded(px(7.))
                    .hover(|s| s.bg(r.overlay_hover))
                    .child(check)
                    .child(color_dot(dot, 10.))
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .flex()
                            .flex_col()
                            .child(
                                div()
                                    .truncate()
                                    .text_size(px(t.metrics.control))
                                    .text_color(r.text)
                                    .child(SharedString::from(calendar.name.clone())),
                            )
                            .when(!badges.is_empty(), |d| {
                                d.child(
                                    div()
                                        .truncate()
                                        .text_size(px(t.metrics.small))
                                        .text_color(r.text_subtle)
                                        .child(SharedString::from(badges.clone())),
                                )
                            }),
                    )
                    .on_mouse_down(
                        MouseButton::Right,
                        cx.listener(move |this, ev: &MouseDownEvent, window, cx| {
                            cx.stop_propagation();
                            this.calendar_menu(&menu_calendar, ev.position, window, cx)
                        }),
                    )
                    .into_any_element()
            })
            .collect();
        let new_entity = entity.clone();
        div()
            .id("calendar-calendars")
            .role(Role::List)
            .aria_label(SharedString::from(l.calendar_calendars_title()))
            .w(px(CALENDARS_WIDTH))
            .flex_none()
            .h_full()
            .flex()
            .flex_col()
            .border_r_1()
            .border_color(r.divider)
            .child(
                div()
                    .flex_none()
                    .h(px(40.))
                    .pl(px(18.))
                    .pr(px(8.))
                    .flex()
                    .items_center()
                    .child(
                        heading(
                            "calendar-calendars-title",
                            SharedString::from(l.calendar_calendars_title()),
                            2,
                            t.metrics.small,
                            FontWeight::SEMIBOLD,
                            r.text_subtle,
                        )
                        .flex_1(),
                    )
                    .child(
                        IconButton::new(
                            "calendar-new-calendar",
                            IconName::Plus,
                            l.desktop_calendar_new_calendar_ellipsis(),
                        )
                        .size(26., 14.)
                        .round()
                        .disabled(agenda.is_none())
                        .on_click(Rc::new(move |_, window, cx| {
                            let _ = new_entity.update(cx, |p, cx| p.new_calendar(window, cx));
                        })),
                    ),
            )
            .child(
                div()
                    .id("calendar-calendars-body")
                    .flex_1()
                    .min_h_0()
                    .overflow_y_scroll()
                    .px(px(6.))
                    .flex()
                    .flex_col()
                    .gap(px(1.))
                    .children(rows),
            )
            .child(
                div()
                    .flex_none()
                    .px(px(16.))
                    .py(px(10.))
                    .border_t_1()
                    .border_color(r.divider)
                    .text_size(px(t.metrics.small))
                    .text_color(r.text_subtle)
                    .child(SharedString::from(if filterable {
                        format!(
                            "{} {}",
                            l.desktop_calendar_visibility_footer(),
                            l.calendar_timezone_note()
                        )
                    } else {
                        l.calendar_timezone_note()
                    })),
            )
            .into_any_element()
    }

    fn header(&mut self, agenda: Option<&CalendarAgenda>, cx: &mut Context<Self>) -> AnyElement {
        let t = cx.conduit().clone();
        let r = t.roles;
        let l = cx.l10n().clone();
        let store = self.stores.calendar.read(cx);
        let paging = store.paging;
        let starts_today = store.starts_today();
        let entity = cx.entity().downgrade();
        let (prev_e, next_e, today_e, new_e) = (
            entity.clone(),
            entity.clone(),
            entity.clone(),
            entity.clone(),
        );
        let days = agenda.map(|a| a.day_count).unwrap_or(14);
        let range = agenda
            .map(|a| format::range_label(a, &l))
            .unwrap_or_default();
        div()
            .flex_none()
            .h(px(52.))
            .px(px(16.))
            .flex()
            .items_center()
            .gap(px(6.))
            .border_b_1()
            .border_color(r.divider)
            .child(
                IconButton::new(
                    "calendar-earlier",
                    IconName::ChevronLeft,
                    l.calendar_previous_days(days),
                )
                .size(28., 15.)
                .round()
                .shortcut(Some("⌘←".into()))
                .disabled(agenda.is_none())
                .on_click(Rc::new(move |_, _, cx| {
                    let _ = prev_e.update(cx, |p, cx| p.previous(cx));
                })),
            )
            .child(
                IconButton::new(
                    "calendar-later",
                    IconName::ChevronRight,
                    l.calendar_next_days(days),
                )
                .size(28., 15.)
                .round()
                .shortcut(Some("⌘→".into()))
                .disabled(agenda.is_none())
                .on_click(Rc::new(move |_, _, cx| {
                    let _ = next_e.update(cx, |p, cx| p.next(cx));
                })),
            )
            .child(
                div()
                    .flex_1()
                    .min_w_0()
                    .flex()
                    .items_center()
                    .gap(px(8.))
                    .pl(px(4.))
                    .child(
                        heading(
                            "calendar-range",
                            SharedString::from(range.clone()),
                            2,
                            t.metrics.body + 3.,
                            FontWeight::SEMIBOLD,
                            r.text,
                        )
                        .truncate(),
                    )
                    // The range is heard as the arrows move it, as the
                    // phone's header is.
                    .child(live_text(
                        "calendar-range-live",
                        (!range.is_empty()).then(|| range.into()),
                        Priority::Medium,
                    ))
                    .when(paging, |d| {
                        d.child(
                            div()
                                .id("calendar-paging")
                                .role(Role::ProgressIndicator)
                                .aria_label(SharedString::from(l.desktop_loading()))
                                .text_size(px(t.metrics.small))
                                .text_color(r.text_subtle)
                                .child(SharedString::from(l.desktop_loading())),
                        )
                    }),
            )
            .child(
                Button::new("calendar-today", l.calendar_today())
                    .shortcut("⌘T")
                    .disabled(agenda.is_none() || starts_today)
                    .on_click(Rc::new(move |_, _, cx| {
                        let _ = today_e.update(cx, |p, cx| p.today(cx));
                    })),
            )
            .child(
                Button::new("calendar-add-event", l.calendar_add_event())
                    .icon(IconName::Plus)
                    .disabled(agenda.is_none_or(|a| !a.can_create))
                    .on_click(Rc::new(move |_, window, cx| {
                        let _ = new_e.update(cx, |p, cx| p.new_event(window, cx));
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
        let Some(agenda) = self.agenda(cx) else {
            return vec![];
        };
        let rows = agenda_rows(&agenda);
        range
            .map(|i| match rows.get(i) {
                Some(AgendaRow::Stale) => self.stale_row(cx),
                Some(AgendaRow::Day(d)) => self.day_row(&agenda, *d, cx),
                Some(AgendaRow::Item(d, n)) => {
                    let item = agenda.days[*d].items[*n].clone();
                    self.item_row(&agenda, &item, *d, i, window, cx)
                }
                None => div().into_any_element(),
            })
            .collect()
    }

    fn stale_row(&self, cx: &mut Context<Self>) -> AnyElement {
        let t = cx.conduit().clone();
        let l = cx.l10n().clone();
        let entity = cx.entity().downgrade();
        div()
            .id("calendar-stale")
            .role(Role::Status)
            .h(px(NOTICE_HEIGHT))
            .px(px(18.))
            .flex()
            .items_center()
            .gap(px(10.))
            .child(icon(IconName::TriangleAlert, 14., t.roles.warning))
            .child(
                div()
                    .flex_1()
                    .text_size(px(t.metrics.control))
                    .text_color(t.roles.text_subtle)
                    .child(SharedString::from(l.calendar_stale())),
            )
            .child(
                Button::new("calendar-stale-retry", l.desktop_try_again()).on_click(Rc::new(
                    move |_, _, cx| {
                        let _ = entity.update(cx, |p, cx| {
                            p.stores.calendar.update(cx, |c, cx| c.refresh(cx))
                        });
                    },
                )),
            )
            .into_any_element()
    }

    fn day_row(&self, agenda: &CalendarAgenda, d: usize, cx: &mut Context<Self>) -> AnyElement {
        let t = cx.conduit().clone();
        let r = t.roles;
        let l = cx.l10n().clone();
        let day = &agenda.days[d].day;
        let today = agenda
            .today
            .as_ref()
            .is_some_and(|t| format::same_day(day, t));
        div()
            .id(ElementId::NamedInteger("calendar-day".into(), d as u64))
            .h(px(DAY_HEIGHT))
            .px(px(20.))
            .pt(px(10.))
            .flex()
            .items_end()
            .child(heading(
                ElementId::NamedInteger("calendar-day-title".into(), d as u64),
                SharedString::from(format::day_heading(day, agenda.today.as_ref(), &l)),
                3,
                t.metrics.small + 0.5,
                FontWeight::SEMIBOLD,
                if today { r.text } else { r.text_subtle },
            ))
            .into_any_element()
    }

    fn item_row(
        &mut self,
        agenda: &CalendarAgenda,
        item: &CalendarItemDto,
        d: usize,
        row: usize,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let t = cx.conduit().clone();
        let r = t.roles;
        let l = cx.l10n().clone();
        let selected = self
            .selected
            .as_ref()
            .is_some_and(|(key, day)| key == &item.key && *day == d);
        let scheduled = item.kind == "scheduled";
        let title = shown_title(item, &l);
        let time = format::row_time(&item.time, &l);
        let mut detail = vec![time.clone()];
        if scheduled {
            detail.push(format::scheduled_label(item, &l));
        } else {
            if let Some(location) = item.location.as_deref().filter(|s| !s.trim().is_empty()) {
                detail.push(location.to_string());
            }
            if item.recurring {
                detail.push(l.calendar_repeats_marker());
            }
        }
        let detail = detail.join(" · ");
        let answer = item
            .invited
            .then(|| format::answer_label(item.answer.as_deref(), &l));
        let calendar = agenda
            .calendars
            .iter()
            .find(|c| c.id == item.calendar_id)
            .map(|c| c.name.clone());
        let failed = item.scheduled_state.as_deref() == Some("failed");
        let label = [
            Some(title.clone()),
            Some(time),
            if scheduled {
                Some(format::scheduled_label(item, &l))
            } else {
                item.location.clone()
            },
            calendar,
            (item.recurring && !scheduled).then(|| l.calendar_repeats_marker()),
            answer.clone(),
        ]
        .into_iter()
        .flatten()
        .collect::<Vec<_>>()
        .join(", ");
        let dot = format::parse_color(item.color.as_deref()).unwrap_or(r.text_faint);
        let sub = if selected {
            r.selected_text_subtle
        } else {
            r.text_subtle
        };
        let entity = cx.entity().downgrade();
        let open_key = item.key.clone();
        let menu_item = item.clone();
        div()
            .id(ElementId::NamedInteger("calendar-item".into(), row as u64))
            .role(Role::Row)
            .aria_label(SharedString::from(label))
            .aria_selected(selected)
            .h(px(ITEM_HEIGHT))
            .px(px(10.))
            .py(px(2.))
            .child(
                div()
                    .size_full()
                    .px(px(10.))
                    .flex()
                    .items_center()
                    .gap(px(12.))
                    .rounded(px(8.))
                    .cursor_pointer()
                    .when(selected, |d| d.bg(r.selected))
                    .when(!selected, |d| d.hover(|s| s.bg(r.overlay_hover)))
                    .child(if scheduled {
                        icon(IconName::CalendarClock, 13., dot).into_any_element()
                    } else {
                        color_dot(dot, 10.).into_any_element()
                    })
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .flex()
                            .flex_col()
                            .gap(px(1.))
                            .child(
                                div()
                                    .truncate()
                                    .text_size(px(t.metrics.body))
                                    .font_weight(FontWeight::MEDIUM)
                                    .text_color(if item.cancelled { sub } else { r.text })
                                    .when(item.cancelled, |d| d.line_through())
                                    .child(SharedString::from(title)),
                            )
                            .child(
                                div()
                                    .truncate()
                                    .text_size(px(t.metrics.small))
                                    .text_color(if failed { r.danger } else { sub })
                                    .child(SharedString::from(detail)),
                            ),
                    )
                    .when_some(answer, |d, answer| {
                        d.child(
                            div()
                                .flex_none()
                                .text_size(px(t.metrics.small))
                                .text_color(sub)
                                .child(SharedString::from(answer)),
                        )
                    }),
            )
            .on_click({
                let key = item.key.clone();
                move |_, window, cx| {
                    let key = key.clone();
                    let _ = entity.update(cx, |p, cx| {
                        if !p.focus.contains_focused(window, cx) {
                            window.focus(&p.focus, cx);
                        }
                        p.selected = Some((key.clone(), d));
                        cx.notify();
                        p.open(&key, window, cx);
                    });
                }
            })
            .on_mouse_down(
                MouseButton::Right,
                cx.listener(move |this, ev: &MouseDownEvent, window, cx| {
                    cx.stop_propagation();
                    this.selected = Some((open_key.clone(), d));
                    this.item_menu(&menu_item, ev.position, window, cx)
                }),
            )
            .keyboard_list_item(Ring::Inset(8.), window, cx)
            .into_any_element()
    }

    fn agenda_body(
        &mut self,
        agenda: Option<&CalendarAgenda>,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let t = cx.conduit().clone();
        let r = t.roles;
        let l = cx.l10n().clone();
        let store = self.stores.calendar.read(cx);
        let entity = cx.entity().downgrade();
        let message = |text: String, action: Option<(&'static str, String, bool)>| {
            let entity = entity.clone();
            div()
                .id("calendar-empty")
                .role(Role::Status)
                .flex_1()
                .flex()
                .flex_col()
                .items_center()
                .justify_center()
                .gap(px(12.))
                .px(px(32.))
                .pb(px(40.))
                .text_center()
                .child(icon(IconName::Calendar, 28., r.text_faint))
                .child(
                    div()
                        .text_size(px(t.metrics.control))
                        .text_color(r.text_subtle)
                        .child(SharedString::from(text)),
                )
                .when_some(action, |d, (id, label, retry)| {
                    d.child(
                        Button::new(id, label).on_click(Rc::new(move |_, window, cx| {
                            let _ = entity.update(cx, |p, cx| {
                                if retry {
                                    p.stores.calendar.update(cx, |c, cx| c.refresh(cx));
                                } else {
                                    p.new_event(window, cx);
                                }
                            });
                        })),
                    )
                })
                .into_any_element()
        };
        let Some(agenda) = agenda else {
            if store.loading || store.error.is_none() {
                return message(l.desktop_loading(), None);
            }
            let text = store
                .error
                .as_ref()
                .map(|e| format::failure_text(e, l.calendar_load_failed(), &l))
                .unwrap_or_else(|| l.calendar_load_failed());
            return message(text, Some(("calendar-retry", l.desktop_try_again(), true)));
        };
        if let Some(failure) = agenda.failure.as_deref() {
            let text = match failure {
                "unavailable" => l.calendar_unavailable(),
                "accountChanged" => l.calendar_account_changed(),
                _ => l.calendar_load_failed(),
            };
            return message(text, Some(("calendar-retry", l.desktop_try_again(), true)));
        }
        if agenda.days.is_empty() && !agenda.stale {
            return message(
                l.calendar_empty(),
                agenda
                    .can_create
                    .then(|| ("calendar-empty-add", l.calendar_add_event(), false)),
            );
        }
        let sizes = Rc::new(
            agenda_rows(agenda)
                .iter()
                .map(|row| {
                    size(
                        px(AGENDA_WIDTH),
                        px(match row {
                            AgendaRow::Stale => NOTICE_HEIGHT,
                            AgendaRow::Day(_) => DAY_HEIGHT,
                            AgendaRow::Item(..) => ITEM_HEIGHT,
                        }),
                    )
                })
                .collect::<Vec<_>>(),
        );
        v_virtual_list(
            cx.entity(),
            "calendar-agenda-rows",
            sizes,
            |this, range, window, cx| this.render_rows(range, window, cx),
        )
        .track_scroll(&self.scroll)
        .flex_1()
        .pb(px(12.))
        .into_any_element()
    }
}

/// What a calendar's row says about it: Default, Shared, Read-only.
fn badges(calendar: &CalendarDto, l: &L10n) -> String {
    if calendar.scheduled {
        return l.calendar_read_only_badge();
    }
    let mut out = vec![];
    if calendar.owned && calendar.is_default {
        out.push(l.calendar_default_badge());
    }
    if !calendar.owned {
        out.push(l.calendar_shared_badge());
    }
    if !calendar.writable {
        out.push(l.calendar_read_only_badge());
    }
    out.join(" · ")
}

/// A calendar's colour as a dot.
pub fn color_dot(color: Hsla, size: f32) -> gpui_kit::Div {
    div()
        .flex_none()
        .size(px(size))
        .rounded_full()
        .bg(color)
        .border_1()
        .border_color(with_alpha(gpui_kit::black(), 0.12))
}

/// What runs once a deleted event is gone (the sheet it was deleted from
/// closing).
pub type AfterDelete = Box<dyn FnOnce(&mut App)>;

/// Asks before deleting `item`'s event (its whole series when it repeats),
/// then deletes it. `after` runs once it is gone (the sheet closing).
pub fn confirm_delete(
    stores: Stores,
    item: CalendarItemDto,
    after: Option<AfterDelete>,
    window: &mut Window,
    cx: &mut App,
) {
    let l = cx.l10n().clone();
    let title = shown_title(&item, &l);
    let spec = if item.recurring {
        SheetSpec::new(
            l.calendar_event_delete_series_confirm(&title),
            l.calendar_event_series_note(),
            l.calendar_event_delete_series(),
            l.cancel(),
        )
    } else {
        SheetSpec::new(
            l.calendar_event_delete_confirm(&title),
            String::new(),
            l.calendar_event_delete(),
            l.cancel(),
        )
    }
    .destructive();
    // Asked, and sent, only for the account the event is shown for.
    let ask = crate::views::sheet::ask_for_account(&stores, window, spec, cx);
    let rpc = stores.connection.read(cx).rpc();
    // The agenda the answer comes back with is this account's: another
    // account signed in meanwhile shows its own.
    let generation = stores.calendar.read(cx).generation();
    cx.spawn(async move |cx: &mut AsyncApp| {
        if !ask.await || cx.update(|cx| stores.calendar.read(cx).generation()) != generation {
            return;
        }
        let result = rpc
            .call::<methods::CalendarDeleteEvent>(&CalendarItemRef {
                key: item.key.clone(),
            })
            .await;
        cx.update(|cx| match result {
            _ if stores.calendar.read(cx).generation() != generation => {}
            Ok(agenda) => {
                stores.calendar.update(cx, |c, cx| c.adopt(agenda, cx));
                if let Some(after) = after {
                    after(cx);
                }
            }
            Err(e) => {
                let l = cx.l10n().clone();
                let text = format::failure_text(&e, l.calendar_event_delete_failed(), &l);
                stores.toasts.update(cx, |t, cx| {
                    t.show(conduit_protocol::NoticeLevel::Error, text, cx)
                });
            }
        });
    })
    .detach();
}

impl Focusable for CalendarPane {
    fn focus_handle(&self, _: &App) -> FocusHandle {
        self.focus.clone()
    }
}

impl Render for CalendarPane {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let l = cx.l10n().clone();
        let t = cx.conduit().clone();
        let agenda = self.agenda(cx);
        // A selection whose item left the agenda goes with it.
        if let (Some((key, day)), Some(a)) = (&self.selected, &agenda)
            && a.days
                .get(*day)
                .is_none_or(|d| !d.items.iter().any(|i| &i.key == key))
        {
            self.selected = None;
        }
        let calendars = self.calendars_column(agenda.as_ref(), window, cx);
        let header = self.header(agenda.as_ref(), cx);
        let body = self.agenda_body(agenda.as_ref(), cx);
        let focus = self.focus.clone();
        div()
            .id("calendar-pane")
            .key_context("CalendarPane")
            .track_focus(&self.focus)
            .flex_1()
            .min_h_0()
            .w_full()
            .flex()
            .bg(t.roles.content)
            // Any click in the pane brings the keyboard here: the arrows,
            // ⌘← ⌘→ ⌘T and the context menus' commands answer along it.
            .on_mouse_down(MouseButton::Left, move |_, window, cx| {
                if !focus.contains_focused(window, cx) {
                    window.focus(&focus, cx);
                }
            })
            .on_action(
                cx.listener(|this, a: &CalendarMenu, window, cx| this.on_menu(a, window, cx)),
            )
            .on_key_down(cx.listener(|this, e: &gpui_kit::KeyDownEvent, window, cx| {
                if this.on_key(e, window, cx) {
                    cx.stop_propagation();
                }
            }))
            .child(calendars)
            .child(
                div()
                    .id("calendar-agenda")
                    .role(Role::List)
                    .aria_label(SharedString::from(l.desktop_calendar_agenda()))
                    .flex_1()
                    .min_w_0()
                    .h_full()
                    .flex()
                    .flex_col()
                    .child(header)
                    .child(body),
            )
    }
}

/// An item's title as its row draws it and VoiceOver says it: an untitled
/// event has the localized "Untitled event".
fn shown_title(item: &CalendarItemDto, l: &L10n) -> String {
    if item.title.trim().is_empty() {
        l.calendar_untitled_event()
    } else {
        item.title.clone()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use conduit_protocol::{CalendarAgendaDay, CalendarRowTimeDto, CalendarWallTime};

    fn item(key: &str) -> CalendarItemDto {
        CalendarItemDto {
            key: key.into(),
            kind: "event".into(),
            id: key.into(),
            calendar_id: "c".into(),
            title: key.into(),
            location: None,
            color: None,
            recurring: false,
            all_day: false,
            cancelled: false,
            start: CalendarWallTime {
                year: 2026,
                month: 11,
                day: 12,
                hour: 9,
                minute: 0,
            },
            end: None,
            last_day: None,
            time: CalendarRowTimeDto {
                kind: "allDay".into(),
                start: None,
                end: None,
            },
            invited: false,
            answer: None,
            editable: true,
            automation_id: None,
            run_id: None,
            result_chat_id: None,
            result_channel_id: None,
            scheduled_state: None,
        }
    }

    #[test]
    fn the_agenda_lists_each_day_then_its_items() {
        let day = |items: Vec<CalendarItemDto>| CalendarAgendaDay {
            day: CalendarWallTime {
                year: 2026,
                month: 11,
                day: 12,
                hour: 0,
                minute: 0,
            },
            items,
        };
        let agenda = CalendarAgenda {
            stale: true,
            days: vec![day(vec![item("a"), item("b")]), day(vec![item("c")])],
            ..Default::default()
        };
        assert_eq!(
            agenda_rows(&agenda),
            [
                AgendaRow::Stale,
                AgendaRow::Day(0),
                AgendaRow::Item(0, 0),
                AgendaRow::Item(0, 1),
                AgendaRow::Day(1),
                AgendaRow::Item(1, 0),
            ]
        );
    }

    fn make_active(stores: &Stores, id: &str, vcx: &mut gpui_kit::VisualTestContext) {
        use crate::stores::accounts::tests::{account, list};
        stores.accounts.update(vcx, |a, cx| {
            a.adopt(
                list(vec![
                    account("a", "Avery", id == "a", true),
                    account("b", "Blake", id == "b", true),
                ]),
                cx,
            )
        });
        vcx.run_until_parked();
    }

    /// A calendar sheet opened for one account closes when another signs in
    /// (in Settings' own window): nothing it shows or would create, answer
    /// or save goes to the next account.
    #[gpui_kit::test]
    fn calendar_sheets_close_on_another_account(cx: &mut gpui_kit::TestAppContext) {
        use crate::views::sheet::{self, bench::bench};
        let (daemon, stores, vcx) = bench(cx);
        type Open = Box<dyn Fn(Stores, &mut Window, &mut App)>;
        let open: Vec<(&str, Open)> = vec![
            ("New Calendar", Box::new(new_calendar::open)),
            (
                "the event's sheet",
                Box::new(|s, w, cx| event_sheet::open(s, "k1".into(), w, cx)),
            ),
            (
                "the event editor",
                Box::new(|s, w, cx| editor::open(s, None, None, w, cx)),
            ),
        ];
        for (i, (name, open)) in open.iter().enumerate() {
            let s = stores.clone();
            vcx.update(|window, cx| open(s, window, cx));
            vcx.run_until_parked();
            assert!(vcx.update(|_, cx| sheet::is_open(cx)), "{name} opens");
            make_active(&stores, if i % 2 == 0 { "b" } else { "a" }, vcx);
            assert!(
                !vcx.update(|_, cx| sheet::is_open(cx)),
                "{name} stayed open over the next account"
            );
        }
        assert!(daemon.calls::<methods::CalendarCreateCalendar>().is_empty());
    }

    /// Words typed in the event editor are not dropped without a question,
    /// whether Cancel or Quit comes before the daemon has checked them.
    #[gpui_kit::test]
    fn cancel_and_quit_ask_before_typed_event_words_go(cx: &mut gpui_kit::TestAppContext) {
        use crate::views::sheet::{self, SheetBody as _, bench::bench};
        let (daemon, stores, vcx) = bench(cx);
        daemon.on::<methods::CalendarEditor>(|_| {
            Ok(serde_json::json!({
                "token": "ed-1",
                "isNew": true,
                "series": false,
                "fields": {
                    "title": "",
                    "description": "",
                    "location": "",
                    "calendarId": "c",
                    "allDay": false,
                    "start": {"year": 2026, "month": 11, "day": 12, "hour": 9, "minute": 0},
                    "repeat": "none",
                    "attendees": []
                },
                "calendars": []
            }))
        });
        // The daemon has not answered a check yet.
        let _held = daemon.hold::<methods::CalendarCheckDraft>();
        let s = stores.clone();
        vcx.update(|window, cx| editor::open(s, None, None, window, cx));
        vcx.run_until_parked();
        let editor = vcx
            .update(|_, cx| sheet::current::<editor::EventEditor>(cx))
            .expect("the editor opens");
        vcx.update(|window, cx| {
            editor.update(cx, |e, cx| {
                e.type_title("Seed swap at the allotment", window, cx)
            })
        });
        // Cancel, then Quit; each question is answered Keep Editing.
        vcx.update(|window, cx| editor.update(cx, |e, cx| e.cancel(window, cx)));
        vcx.run_until_parked();
        assert!(
            vcx.update(|_, cx| sheet::current::<editor::EventEditor>(cx))
                .is_some(),
            "Cancel dropped the typed title without asking"
        );
        vcx.update(|_, cx| sheet::quit(cx));
        vcx.run_until_parked();
        assert!(
            vcx.update(|_, cx| sheet::current::<editor::EventEditor>(cx))
                .is_some(),
            "Quit dropped the typed title without asking"
        );
    }

    /// A delete answered after another account signed in leaves the next
    /// account's calendar alone: the last account's agenda is not shown.
    #[gpui_kit::test]
    fn a_delete_answered_after_an_account_switch_is_not_shown(cx: &mut gpui_kit::TestAppContext) {
        use crate::views::sheet::bench::bench;
        let (daemon, stores, vcx) = bench(cx);
        // The calendar follows the account, as the app wires it.
        vcx.update(|_, cx| {
            crate::stores::calendar::wire(&stores, cx);
            cx.set_global(crate::shell::sheet::AutoAnswer(Some(true)))
        });
        make_active(&stores, "a", vcx);
        daemon.returns::<methods::CalendarDeleteEvent>(CalendarAgenda {
            available: true,
            calendars: vec![CalendarDto {
                id: "avery-garden".into(),
                name: "Avery's garden".into(),
                color: None,
                is_default: true,
                scheduled: false,
                owned: true,
                writable: true,
                can_make_default: true,
                visible: true,
            }],
            ..Default::default()
        });
        let held = daemon.hold::<methods::CalendarDeleteEvent>();
        let s = stores.clone();
        vcx.update(|window, cx| confirm_delete(s, item("k1"), None, window, cx));
        vcx.run_until_parked();
        assert_eq!(daemon.calls::<methods::CalendarDeleteEvent>().len(), 1);
        make_active(&stores, "b", vcx);
        drop(held);
        vcx.run_until_parked();
        assert!(
            stores.calendar.read_with(vcx, |c, _| c.agenda.is_none()),
            "Avery's agenda is shown under Blake's account"
        );

        // Blake signs in while Avery's question is still up: the delete is
        // never sent, under either account.
        make_active(&stores, "a", vcx);
        let s = stores.clone();
        vcx.update(|window, cx| {
            confirm_delete(s.clone(), item("k2"), None, window, cx);
            s.accounts.update(cx, |a, cx| {
                use crate::stores::accounts::tests::{account, list};
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
        assert_eq!(
            daemon.calls::<methods::CalendarDeleteEvent>().len(),
            1,
            "Avery's delete went out under Blake's account"
        );
        assert!(
            stores.calendar.read_with(vcx, |c, _| c.agenda.is_none()),
            "Avery's agenda is shown under Blake's account"
        );
    }

    /// A delete answered once the event's sheet has gone closes nothing: an
    /// editor opened meanwhile stays, with what is typed in it.
    #[gpui_kit::test]
    fn an_event_delete_closes_only_its_own_sheet(cx: &mut gpui_kit::TestAppContext) {
        use crate::views::sheet::{self, bench::bench};
        let (daemon, stores, vcx) = bench(cx);
        vcx.update(|_, cx| cx.set_global(crate::shell::sheet::AutoAnswer(Some(true))));
        let detail = serde_json::json!({"item": serde_json::to_value(item("k1")).unwrap()});
        daemon.on::<methods::CalendarEvent>(move |_| Ok(detail.clone()));
        daemon.returns::<methods::CalendarDeleteEvent>(CalendarAgenda {
            available: true,
            ..Default::default()
        });
        let s = stores.clone();
        vcx.update(|window, cx| event_sheet::open(s, "k1".into(), window, cx));
        vcx.run_until_parked();
        let shown = vcx
            .update(|_, cx| sheet::current::<event_sheet::EventSheet>(cx))
            .expect("the event's sheet opens");
        let held = daemon.hold::<methods::CalendarDeleteEvent>();
        vcx.update(|window, cx| shown.update(cx, |e, cx| e.delete(window, cx)));
        vcx.run_until_parked();
        // Meanwhile the sheet goes and the event editor comes up.
        vcx.update(|_, cx| sheet::dismiss(cx));
        vcx.run_until_parked();
        let s = stores.clone();
        vcx.update(|window, cx| editor::open(s, None, None, window, cx));
        vcx.run_until_parked();
        assert!(
            vcx.update(|_, cx| sheet::current::<editor::EventEditor>(cx))
                .is_some()
        );
        drop(held);
        vcx.run_until_parked();
        assert!(
            vcx.update(|_, cx| sheet::current::<editor::EventEditor>(cx))
                .is_some(),
            "the delete closed the editor opened after it"
        );
    }

    /// Words typed while a save is out stay in the editor, which stays open
    /// on the event saved, and the next Save takes them.
    #[gpui_kit::test]
    fn words_typed_while_an_event_saves_stay_for_the_next_save(cx: &mut gpui_kit::TestAppContext) {
        use crate::views::sheet::{self, bench::bench};
        let (daemon, stores, vcx) = bench(cx);
        daemon.on::<methods::CalendarEditor>(|_| {
            Ok(serde_json::json!({
                "token": "ed-1",
                "isNew": true,
                "series": false,
                "fields": {
                    "title": "",
                    "description": "",
                    "location": "",
                    "calendarId": "c",
                    "allDay": false,
                    "start": {"year": 2026, "month": 11, "day": 12, "hour": 9, "minute": 0},
                    "repeat": "none",
                    "attendees": []
                },
                "calendars": []
            }))
        });
        daemon.on::<methods::CalendarCheckDraft>(|p| {
            Ok(serde_json::json!({"fields": p["fields"], "changed": true}))
        });
        daemon.on::<methods::CalendarSave>(|p| {
            Ok(serde_json::json!({"fields": p["fields"], "saved": true}))
        });
        let s = stores.clone();
        vcx.update(|window, cx| editor::open(s, None, None, window, cx));
        vcx.run_until_parked();
        let editor = vcx
            .update(|_, cx| sheet::current::<editor::EventEditor>(cx))
            .expect("the editor opens");
        vcx.update(|window, cx| editor.update(cx, |e, cx| e.type_title("Seed swap", window, cx)));
        vcx.run_until_parked();
        let held = daemon.hold_one::<methods::CalendarSave>(0);
        vcx.update(|window, cx| editor.update(cx, |e, cx| e.save(window, cx)));
        vcx.run_until_parked();
        // Typed while the save is out.
        vcx.update(|window, cx| {
            editor.update(cx, |e, cx| {
                e.type_location("The allotment shed", window, cx)
            })
        });
        drop(held);
        vcx.run_until_parked();
        assert!(
            vcx.update(|_, cx| sheet::current::<editor::EventEditor>(cx))
                .is_some_and(|e| e == editor),
            "the editor closed over the location typed while it saved"
        );
        vcx.update(|window, cx| editor.update(cx, |e, cx| e.save(window, cx)));
        vcx.run_until_parked();
        let saves = daemon.calls::<methods::CalendarSave>();
        assert_eq!(saves.len(), 2);
        assert_eq!(saves[1]["fields"]["location"], "The allotment shed");
        assert!(
            !vcx.update(|_, cx| sheet::is_open(cx)),
            "the editor stays open once everything typed is saved"
        );
    }

    /// A Discard answered for an event editor that has gone closes nothing
    /// else: the editor open by then (another account's) keeps its edits.
    #[gpui_kit::test]
    fn a_late_discard_closes_only_its_own_event_editor(cx: &mut gpui_kit::TestAppContext) {
        use crate::views::sheet::{self, SheetBody as _, bench::bench};
        let (daemon, stores, vcx) = bench(cx);
        daemon.on::<methods::CalendarEditor>(|_| {
            Ok(serde_json::json!({
                "token": "ed-1",
                "isNew": true,
                "series": false,
                "fields": {
                    "title": "",
                    "description": "",
                    "location": "",
                    "calendarId": "c",
                    "allDay": false,
                    "start": {"year": 2026, "month": 11, "day": 12, "hour": 9, "minute": 0},
                    "repeat": "none",
                    "attendees": []
                },
                "calendars": []
            }))
        });
        let open = |vcx: &mut gpui_kit::VisualTestContext, title: &str| {
            let s = stores.clone();
            vcx.update(|window, cx| editor::open(s, None, None, window, cx));
            let event = vcx
                .update(|_, cx| sheet::current::<editor::EventEditor>(cx))
                .expect("the editor opens");
            vcx.run_until_parked();
            vcx.update(|window, cx| event.update(cx, |e, cx| e.type_title(title, window, cx)));
            event
        };
        let first = open(vcx, "Avery's seed swap");
        // Avery's editor asks to discard; the answer will be Discard.
        vcx.update(|_, cx| cx.set_global(crate::shell::sheet::AutoAnswer(Some(true))));
        vcx.update(|window, cx| first.update(cx, |e, cx| e.cancel(window, cx)));
        // Before it answers, Blake signs in (Avery's editor closes) and opens
        // an event editor of his own.
        stores.accounts.update(vcx, |a, cx| {
            use crate::stores::accounts::tests::{account, list};
            a.adopt(
                list(vec![
                    account("a", "Avery", false, true),
                    account("b", "Blake", true, true),
                ]),
                cx,
            )
        });
        let second = open(vcx, "Blake's plot visit");
        vcx.run_until_parked();
        assert!(
            vcx.update(|_, cx| sheet::current::<editor::EventEditor>(cx))
                .is_some_and(|open| open == second),
            "Avery's Discard closed Blake's event editor"
        );
    }

    /// Once Tab has reached an agenda row, the arrows move the selection as
    /// they do from the pane itself (Full Keyboard Access or not).
    #[gpui_kit::test]
    fn the_arrows_move_from_a_focused_agenda_row(cx: &mut gpui_kit::TestAppContext) {
        use conduit_protocol::Capabilities;

        use crate::stores::accounts::tests::{account, list};
        use crate::stores::rpc::fake::FakeDaemon;
        let daemon = FakeDaemon::new();
        let day = CalendarWallTime {
            year: 2026,
            month: 11,
            day: 12,
            hour: 0,
            minute: 0,
        };
        daemon.returns::<methods::CalendarAgenda>(CalendarAgenda {
            available: true,
            first_day: Some(day.clone()),
            today: Some(day.clone()),
            days: vec![CalendarAgendaDay {
                day,
                items: vec![item("k1"), item("k2")],
            }],
            ..Default::default()
        });
        let scratch =
            std::env::temp_dir().join(format!("conduit-agenda-keys-{}", std::process::id()));
        let stores = cx.update(|cx| {
            crate::views::test_globals(cx);
            Stores::for_test(daemon.rpc(), &scratch, cx)
        });
        stores.accounts.update(cx, |a, cx| {
            a.adopt(list(vec![account("a", "Avery", true, true)]), cx)
        });
        stores.session.update(cx, |s, cx| {
            s.system_capabilities = Some(Capabilities {
                calendar: true,
                ..Default::default()
            });
            cx.notify();
        });
        let s = stores.clone();
        let (pane, vcx) = cx.add_window_view(move |window, cx| CalendarPane::new(s, window, cx));
        vcx.run_until_parked();
        let draw = |vcx: &mut gpui_kit::VisualTestContext| {
            vcx.update(|window, cx| window.draw(cx).clear(cx));
            vcx.run_until_parked();
        };
        draw(vcx);
        let on_a_row = |vcx: &mut gpui_kit::VisualTestContext| {
            vcx.update(|window, cx| {
                let p = pane.read(cx);
                p.focus.contains_focused(window, cx) && !p.focus.is_focused(window)
            })
        };
        for _ in 0..12 {
            if on_a_row(vcx) {
                break;
            }
            vcx.update(|window, cx| window.focus_next(cx));
            draw(vcx);
        }
        assert!(on_a_row(vcx), "Tab never reached an agenda row");
        let before = pane.read_with(vcx, |p, _| p.selected.clone());
        vcx.simulate_keystrokes("down");
        vcx.run_until_parked();
        assert_ne!(
            pane.read_with(vcx, |p, _| p.selected.clone()),
            before,
            "Down on a focused agenda row moved nothing"
        );
    }

    /// Arrowing onto an untitled event says the name its row shows, so
    /// VoiceOver never goes quiet on a row.
    #[gpui_kit::test]
    fn an_untitled_event_is_said_by_the_name_its_row_shows(cx: &mut gpui_kit::TestAppContext) {
        use conduit_components::announce::AnnouncementLog;
        use conduit_protocol::Capabilities;

        use crate::stores::accounts::tests::{account, list};
        use crate::stores::rpc::fake::FakeDaemon;
        let daemon = FakeDaemon::new();
        let day = CalendarWallTime {
            year: 2026,
            month: 11,
            day: 12,
            hour: 0,
            minute: 0,
        };
        let mut untitled = item("k2");
        untitled.title = " ".into();
        daemon.returns::<methods::CalendarAgenda>(CalendarAgenda {
            available: true,
            first_day: Some(day.clone()),
            today: Some(day.clone()),
            days: vec![CalendarAgendaDay {
                day: day.clone(),
                items: vec![item("k1"), untitled],
            }],
            ..Default::default()
        });
        let scratch =
            std::env::temp_dir().join(format!("conduit-agenda-say-{}", std::process::id()));
        let stores = cx.update(|cx| {
            crate::views::test_globals(cx);
            AnnouncementLog::install(cx);
            Stores::for_test(daemon.rpc(), &scratch, cx)
        });
        stores.accounts.update(cx, |a, cx| {
            a.adopt(list(vec![account("a", "Avery", true, true)]), cx)
        });
        stores.session.update(cx, |s, cx| {
            s.system_capabilities = Some(Capabilities {
                calendar: true,
                ..Default::default()
            });
            cx.notify();
        });
        let s = stores.clone();
        let (pane, vcx) = cx.add_window_view(move |window, cx| CalendarPane::new(s, window, cx));
        vcx.run_until_parked();
        assert!(
            stores.calendar.read_with(vcx, |c, _| c.agenda.is_some()),
            "the agenda loaded"
        );
        pane.update(vcx, |p, cx| {
            p.move_selection(true, cx);
            p.move_selection(true, cx);
        });
        let l = L10n::new("en");
        let when = format!(
            "{}, {}",
            format::day_heading(&day, Some(&day), &l),
            format::row_time(&item("k1").time, &l)
        );
        let said: Vec<String> = vcx.update(|_, cx| {
            AnnouncementLog::texts(cx)
                .iter()
                .map(ToString::to_string)
                .collect()
        });
        assert_eq!(
            said,
            [
                format!("k1, {when}, 1 of 2"),
                format!("{}, {when}, 2 of 2", l.calendar_untitled_event()),
            ]
        );
    }

    /// Two events of one name are told apart as the arrows reach them: each
    /// is said with the day it is under and its time on that day. So are
    /// the two rows of an event that runs past midnight.
    #[gpui_kit::test]
    fn two_events_of_one_name_are_said_with_their_times(cx: &mut gpui_kit::TestAppContext) {
        use conduit_components::announce::AnnouncementLog;
        use conduit_protocol::Capabilities;

        use crate::stores::accounts::tests::{account, list};
        use crate::stores::rpc::fake::FakeDaemon;
        let daemon = FakeDaemon::new();
        let day = CalendarWallTime {
            year: 2026,
            month: 11,
            day: 12,
            hour: 0,
            minute: 0,
        };
        let next = format::next_day(&day);
        let standup = |key: &str, hour: i64| {
            let mut i = item(key);
            i.title = "Standup".into();
            i.start.hour = hour;
            i.time = CalendarRowTimeDto {
                kind: "at".into(),
                start: Some(i.start.clone()),
                end: None,
            };
            i
        };
        let (morning, afternoon) = (standup("k1", 9), standup("k2", 15));
        // 22:00 to 02:00 the next day: listed under both days.
        let mut late = standup("k3", 22);
        late.end = Some(CalendarWallTime {
            hour: 2,
            ..next.clone()
        });
        late.last_day = Some(next.clone());
        late.time = CalendarRowTimeDto {
            kind: "startsAt".into(),
            start: Some(late.start.clone()),
            end: None,
        };
        // All day on both days.
        let mut fair = standup("k4", 0);
        fair.title = "Harvest fair".into();
        fair.all_day = true;
        fair.last_day = Some(next.clone());
        fair.time = CalendarRowTimeDto {
            kind: "allDay".into(),
            start: None,
            end: None,
        };
        let mut late_end = late.clone();
        late_end.time = CalendarRowTimeDto {
            kind: "endsAt".into(),
            start: None,
            end: late.end.clone(),
        };
        daemon.returns::<methods::CalendarAgenda>(CalendarAgenda {
            available: true,
            first_day: Some(day.clone()),
            today: Some(day.clone()),
            days: vec![
                CalendarAgendaDay {
                    day: day.clone(),
                    items: vec![
                        morning.clone(),
                        afternoon.clone(),
                        late.clone(),
                        fair.clone(),
                    ],
                },
                CalendarAgendaDay {
                    day: next.clone(),
                    items: vec![late_end.clone(), fair.clone()],
                },
            ],
            ..Default::default()
        });
        let scratch =
            std::env::temp_dir().join(format!("conduit-agenda-times-{}", std::process::id()));
        let stores = cx.update(|cx| {
            crate::views::test_globals(cx);
            AnnouncementLog::install(cx);
            Stores::for_test(daemon.rpc(), &scratch, cx)
        });
        stores.accounts.update(cx, |a, cx| {
            a.adopt(list(vec![account("a", "Avery", true, true)]), cx)
        });
        stores.session.update(cx, |s, cx| {
            s.system_capabilities = Some(Capabilities {
                calendar: true,
                ..Default::default()
            });
            cx.notify();
        });
        let s = stores.clone();
        let (pane, vcx) = cx.add_window_view(move |window, cx| CalendarPane::new(s, window, cx));
        vcx.run_until_parked();
        pane.update(vcx, |p, cx| {
            for _ in 0..6 {
                p.move_selection(true, cx);
            }
        });
        let l = L10n::new("en");
        let said: Vec<String> = vcx.update(|_, cx| {
            AnnouncementLog::texts(cx)
                .iter()
                .map(ToString::to_string)
                .collect()
        });
        let today = format::day_heading(&day, Some(&day), &l);
        let tomorrow = format::day_heading(&next, Some(&day), &l);
        let at = |i: &CalendarItemDto| format::row_time(&i.time, &l);
        // A row of an event that goes on past its day says when it ends.
        let ends_late = l.calendar_ends_at(&format!(
            "{} {}",
            format::day(&next, &l),
            format::time(late.end.as_ref().unwrap(), &l)
        ));
        let ends_fair = l.calendar_ends_at(&format::day(&next, &l));
        assert_eq!(
            said,
            [
                format!("Standup, {today}, {}, 1 of 6", at(&morning)),
                format!("Standup, {today}, {}, 2 of 6", at(&afternoon)),
                format!("Standup, {today}, {}, {ends_late}, 3 of 6", at(&late)),
                format!("Harvest fair, {today}, {}, {ends_fair}, 4 of 6", at(&fair)),
                format!("Standup, {tomorrow}, {}, 5 of 6", at(&late_end)),
                format!("Harvest fair, {tomorrow}, {}, 6 of 6", at(&fair)),
            ]
        );
        assert_ne!(at(&morning), at(&afternoon));
        assert_ne!(today, tomorrow);
        assert_ne!(at(&late), at(&late_end));
    }
}
