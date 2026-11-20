//! The event editor, a sheet on the main window: New Event, Edit Event or
//! Edit Series, with the phone's fields. Title and location; All Day; when
//! it starts and ends (native date and time pickers); how it repeats (a rule
//! the editor does not write is kept until another repeat is chosen); the
//! calendar; the people invited; a description.
//!
//! The daemon holds the draft it opened (`calendar.editor`), so Save sends
//! only what changed and an untouched start keeps its exact instant. Each
//! change is checked there (`calendar.checkDraft`): a start moved past the
//! end takes the end along, and what stops a save comes back as issues.

use std::rc::Rc;
use std::time::Duration;

use conduit_components::ActiveConduitTheme as _;
use conduit_components::announce::{Priority, live_text};
use conduit_components::assets::{IconName, icon};
use conduit_components::views::focus::{ControlExt as _, Ring};
use conduit_components::views::kit::{Button, IconButton, Switch, field_fill, field_fill_hover};
use conduit_protocol::{
    AccessPrincipal, AccessPrincipalQuery, CalendarAttendeeDto, CalendarDraftEdit,
    CalendarDraftState, CalendarEditor, CalendarEditorOpen, CalendarEventFields, CalendarWallTime,
    methods,
};
use gpui_kit::component::input::{Input, InputEvent, InputState, Textarea, TextareaState};
use gpui_kit::prelude::*;
use gpui_kit::{
    AnyElement, App, AsyncApp, Context, ElementId, Entity, FocusHandle, FontWeight, MouseButton,
    Role, SharedString, Subscription, Task, WeakEntity, Window, div, px, relative,
};

use super::format;
use crate::actions::SettingsChoice;
use crate::l10n::{ActiveL10n as _, L10n};
use crate::shell::date_picker::{PickerMode, PickerSpec, pick};
use crate::shell::sheet::{SheetSpec, present_sheet};
use crate::stores::Stores;
use crate::views::forms;
use crate::views::settings::controls::{self, Choice};
use crate::views::sheet::{self, SheetBody};

/// The sheet's width.
pub const WIDTH: f32 = 540.;

/// How many people a search offers.
const PEOPLE: usize = 6;

/// Opens the editor on the main window: for the stored event behind the
/// agenda item `key`, or a new event on `day`.
pub fn open(
    stores: Stores,
    key: Option<String>,
    day: Option<CalendarWallTime>,
    window: &mut Window,
    cx: &mut App,
) {
    sheet::open(window, WIDTH, cx, move |w, cx| {
        EventEditor::new(stores, key, day, w, cx)
    });
}

/// Which boundary a picker sets.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Boundary {
    Start,
    End,
}

pub struct EventEditor {
    stores: Stores,
    focus: FocusHandle,
    pub editor: Option<CalendarEditor>,
    pub fields: Option<CalendarEventFields>,
    /// What stops a save, as the daemon last said.
    pub issues: Vec<String>,
    /// Save was pressed: every issue shows.
    pub attempted: bool,
    pub changed: bool,
    pub saving: bool,
    pub failure: Option<String>,
    title: Entity<InputState>,
    location: Entity<InputState>,
    description: Entity<TextareaState>,
    people: Entity<InputState>,
    pub people_results: Vec<AccessPrincipal>,
    /// The person search field is showing.
    pub adding_people: bool,
    search: Option<Task<()>>,
    check: Option<Task<()>>,
    /// A start the user picked that the daemon has not settled yet.
    pending_start: Option<CalendarWallTime>,
    _subscriptions: Vec<Subscription>,
}

impl EventEditor {
    pub fn new(
        stores: Stores,
        key: Option<String>,
        day: Option<CalendarWallTime>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Self {
        let l = cx.l10n().clone();
        let title = forms::input(l.calendar_field_title(), false, window, cx);
        let location = forms::input(l.calendar_field_location(), false, window, cx);
        let people = forms::input(l.desktop_calendar_search_people(), false, window, cx);
        let description = cx.new(|cx| {
            TextareaState::new(window, cx)
                .auto_grow(3, 10)
                .placeholder(l.calendar_field_description())
        });
        let mut subscriptions = vec![
            cx.subscribe_in(
                &title,
                window,
                |this, state, e: &InputEvent, window, cx| match e {
                    InputEvent::Change => {
                        let value = state.read(cx).value().to_string();
                        this.edit(|f| f.title = value, cx);
                    }
                    InputEvent::PressEnter { .. } => this.save(window, cx),
                    _ => {}
                },
            ),
            cx.subscribe_in(&location, window, |this, state, e: &InputEvent, _, cx| {
                if matches!(e, InputEvent::Change) {
                    let value = state.read(cx).value().to_string();
                    this.edit(|f| f.location = value, cx);
                }
            }),
            cx.subscribe_in(
                &description,
                window,
                |this, state, e: &InputEvent, _, cx| {
                    if matches!(e, InputEvent::Change) {
                        let value = state.read(cx).value().to_string();
                        this.edit(|f| f.description = value, cx);
                    }
                },
            ),
            cx.subscribe_in(&people, window, |this, state, e: &InputEvent, _, cx| {
                if matches!(e, InputEvent::Change) {
                    let value = state.read(cx).value().to_string();
                    this.search_people(&value, cx);
                }
            }),
        ];
        // The event is saved for the account it opened under, never the next.
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
            title,
            location,
            description,
            people,
            people_results: vec![],
            adding_people: false,
            search: None,
            check: None,
            pending_start: None,
            _subscriptions: subscriptions,
        };
        this.load(key, day, window, cx);
        this
    }

    fn rpc(&self, cx: &App) -> crate::stores::rpc::Rpc {
        self.stores.connection.read(cx).rpc()
    }

    fn load(
        &mut self,
        key: Option<String>,
        day: Option<CalendarWallTime>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let call = self
            .rpc(cx)
            .call::<methods::CalendarEditor>(&CalendarEditorOpen { key, day });
        let handle = window.window_handle();
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result = call.await;
            let _ = handle.update(cx, |_, window, cx| {
                let _ = this.update(cx, |s, cx| {
                    match result {
                        Ok(editor) => s.adopt(editor, window, cx),
                        Err(e) => {
                            log::warn!("calendar.editor: {e}");
                            let l = cx.l10n().clone();
                            s.failure =
                                Some(format::failure_text(&e, l.calendar_event_load_failed(), &l));
                        }
                    }
                    cx.notify();
                });
            });
        })
        .detach();
    }

    fn adopt(&mut self, editor: CalendarEditor, window: &mut Window, cx: &mut Context<Self>) {
        let f = editor.fields.clone();
        self.title
            .update(cx, |s, cx| s.set_value(f.title.clone(), window, cx));
        self.location
            .update(cx, |s, cx| s.set_value(f.location.clone(), window, cx));
        self.description
            .update(cx, |s, cx| s.set_value(f.description.clone(), window, cx));
        self.fields = Some(f);
        self.editor = Some(editor);
        self.check_now(None, cx);
        // The title takes the keyboard, as a new event's does.
        let title = self.title.clone();
        title.update(cx, |s, cx| s.focus(window, cx));
    }

    /// Types the title, as the user would (E2E).
    pub fn type_title(&mut self, text: &str, window: &mut Window, cx: &mut Context<Self>) {
        let value = text.to_string();
        self.title
            .update(cx, |s, cx| s.set_value(value.clone(), window, cx));
        self.edit(|f| f.title = value, cx);
    }

    /// Types the location, as the user would (E2E).
    pub fn type_location(&mut self, text: &str, window: &mut Window, cx: &mut Context<Self>) {
        let value = text.to_string();
        self.location
            .update(cx, |s, cx| s.set_value(value.clone(), window, cx));
        self.edit(|f| f.location = value, cx);
    }

    /// Changes the fields, then checks them with the daemon.
    pub fn edit(&mut self, change: impl FnOnce(&mut CalendarEventFields), cx: &mut Context<Self>) {
        let Some(fields) = self.fields.as_mut() else {
            return;
        };
        change(fields);
        self.failure = None;
        cx.notify();
        self.check_now(None, cx);
    }

    /// Moves the start to `start`; the daemon moves the end along when it
    /// would fall before.
    pub fn set_start(&mut self, start: CalendarWallTime, cx: &mut Context<Self>) {
        self.check_now(Some(start), cx);
    }

    fn check_now(&mut self, moved_start: Option<CalendarWallTime>, cx: &mut Context<Self>) {
        // A start move the daemon has not settled yet rides along with every
        // later check, which replaces the one in flight.
        if moved_start.is_some() {
            self.pending_start = moved_start.clone();
        }
        let moved_start = moved_start.or_else(|| self.pending_start.clone());
        let (Some(editor), Some(fields)) = (self.editor.as_ref(), self.fields.clone()) else {
            return;
        };
        let call = self
            .rpc(cx)
            .call::<methods::CalendarCheckDraft>(&CalendarDraftEdit {
                token: editor.token.clone(),
                fields,
                moved_start: moved_start.clone(),
            });
        self.check = Some(
            cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
                let result = call.await;
                let _ = this.update(cx, |s, cx| {
                    match result {
                        Ok(state) => s.take_state(state, moved_start.is_some()),
                        Err(e) => {
                            log::warn!("calendar.checkDraft: {e}");
                            // A start the daemon could not settle is not
                            // saved behind the one the Start row shows.
                            if moved_start.is_some() && s.pending_start == moved_start {
                                s.pending_start = None;
                            }
                        }
                    }
                    cx.notify();
                });
            }),
        );
    }

    fn take_state(&mut self, state: CalendarDraftState, moved: bool) {
        self.issues = state.issues;
        self.changed = state.changed;
        if moved && let Some(fields) = self.fields.as_mut() {
            // The start (and the end it took along) are the daemon's; what
            // was typed meanwhile stays.
            fields.start = state.fields.start;
            fields.end = state.fields.end;
            self.pending_start = None;
        }
    }

    pub fn set_all_day(&mut self, all_day: bool, cx: &mut Context<Self>) {
        self.edit(|f| f.all_day = all_day, cx);
    }

    pub fn set_end(&mut self, end: Option<CalendarWallTime>, cx: &mut Context<Self>) {
        self.edit(|f| f.end = end, cx);
    }

    /// Add End Time: an hour after the start (the start's day when all day).
    fn add_end(&mut self, cx: &mut Context<Self>) {
        let Some(fields) = self.fields.as_ref() else {
            return;
        };
        let start = fields.start.clone();
        let end = if fields.all_day {
            start
        } else {
            let ms = format::wall_ms(&start) + 3_600_000;
            crate::shell::date_picker::wall_of(ms / 1000)
                .map(format::wall_of)
                .unwrap_or(start)
        };
        self.set_end(Some(end), cx);
    }

    pub fn on_choice(&mut self, a: &SettingsChoice, cx: &mut Context<Self>) {
        let value = a.value.clone();
        match a.menu.as_str() {
            "calendar-repeat" => self.edit(|f| f.repeat = value, cx),
            "calendar-calendar" => self.edit(|f| f.calendar_id = value, cx),
            _ => {}
        }
    }

    fn pick(
        &mut self,
        boundary: Boundary,
        mode: PickerMode,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let Some(fields) = self.fields.as_ref() else {
            return;
        };
        let l = cx.l10n().clone();
        let current = match boundary {
            // A start picked and not settled yet: the time is picked on its day.
            Boundary::Start => self
                .pending_start
                .clone()
                .unwrap_or_else(|| fields.start.clone()),
            Boundary::End => fields.end.clone().unwrap_or_else(|| fields.start.clone()),
        };
        let title = match (boundary, mode) {
            (Boundary::Start, PickerMode::Date) => l.calendar_field_starts(),
            (Boundary::Start, PickerMode::Time) => l.calendar_field_start_time(),
            (Boundary::End, PickerMode::Date) => l.calendar_field_ends(),
            (Boundary::End, PickerMode::Time) => l.calendar_field_end_time(),
        };
        let asked = pick(
            window,
            PickerSpec {
                title,
                mode,
                value: format::clock_of(&current),
                ok: l.done(),
                cancel: l.cancel(),
            },
            cx,
        );
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let Some(picked) = asked.await else {
                return;
            };
            let wall = format::wall_of(picked);
            let _ = this.update(cx, |s, cx| match boundary {
                Boundary::Start => s.set_start(wall, cx),
                Boundary::End => s.set_end(Some(wall), cx),
            });
        })
        .detach();
    }

    // ── People ─────────────────────────────────────────────────────────

    fn search_people(&mut self, query: &str, cx: &mut Context<Self>) {
        let query = query.trim().to_string();
        if query.is_empty() {
            self.people_results.clear();
            self.search = None;
            cx.notify();
            return;
        }
        let rpc = self.rpc(cx);
        self.search = Some(
            cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
                cx.background_executor()
                    .timer(Duration::from_millis(200))
                    .await;
                let result = rpc
                    .call::<methods::AccessPrincipals>(&AccessPrincipalQuery { query })
                    .await;
                let _ = this.update(cx, |s, cx| {
                    match result {
                        Ok(list) => {
                            let invited: Vec<String> = s
                                .fields
                                .as_ref()
                                .map(|f| f.attendees.iter().map(|a| a.user_id.clone()).collect())
                                .unwrap_or_default();
                            s.people_results = list
                                .items
                                .into_iter()
                                .filter(|p| p.r#type == "user" && !invited.contains(&p.id))
                                .take(PEOPLE)
                                .collect();
                        }
                        Err(e) => log::warn!("access.principals: {e}"),
                    }
                    cx.notify();
                });
            }),
        );
    }

    /// Invites `person`.
    pub fn add_person(
        &mut self,
        person: &AccessPrincipal,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let attendee = CalendarAttendeeDto {
            user_id: person.id.clone(),
            name: Some(if person.name.trim().is_empty() {
                person.email.clone().unwrap_or_default()
            } else {
                person.name.clone()
            }),
        };
        self.people
            .update(cx, |s, cx| s.set_value(String::new(), window, cx));
        self.people_results.clear();
        self.adding_people = false;
        self.edit(
            |f| {
                if !f.attendees.iter().any(|a| a.user_id == attendee.user_id) {
                    f.attendees.push(attendee);
                }
            },
            cx,
        );
    }

    pub fn remove_person(&mut self, user_id: &str, cx: &mut Context<Self>) {
        let id = user_id.to_string();
        self.edit(|f| f.attendees.retain(|a| a.user_id != id), cx);
    }

    fn show_people_search(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.adding_people = true;
        let people = self.people.clone();
        people.update(cx, |s, cx| s.focus(window, cx));
        cx.notify();
    }

    // ── Save ───────────────────────────────────────────────────────────

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
        let sent = (fields.clone(), self.pending_start.clone());
        let call = self
            .rpc(cx)
            .call::<methods::CalendarSave>(&CalendarDraftEdit {
                token: editor.token.clone(),
                fields,
                // A start move not settled yet still counts.
                moved_start: self.pending_start.clone(),
            });
        let _ = window;
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result = call.await;
            let _ = this.update(cx, |s, cx| {
                s.saving = false;
                match result {
                    Ok(state) if state.saved => {
                        if (s.fields.as_ref(), &s.pending_start) == (Some(&sent.0), &sent.1) {
                            sheet::dismiss(cx);
                        } else {
                            // Typed while the save was out: it stays, to save
                            // next to the event just saved (the daemon's
                            // editor now edits that event).
                            if let Some(e) = s.editor.as_mut() {
                                e.is_new = false;
                                e.fields = sent.0;
                            }
                            s.check_now(None, cx);
                        }
                    }
                    Ok(state) => {
                        s.attempted = true;
                        s.issues = state.issues;
                    }
                    Err(e) => {
                        log::warn!("calendar.save: {e}");
                        let l = cx.l10n().clone();
                        s.failure = Some(format::failure_text(&e, l.calendar_save_failed(), &l));
                    }
                }
                cx.notify();
            });
        })
        .detach();
    }

    fn issue(&self, issue: &str) -> bool {
        self.issues.iter().any(|i| i == issue)
    }

    // ── Drawing ────────────────────────────────────────────────────────

    /// A field-like button that opens a picker.
    #[allow(clippy::too_many_arguments)]
    fn picker_button(
        &self,
        id: &'static str,
        label: String,
        text: String,
        boundary: Boundary,
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
            .text_color(r.text)
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
                let _ = view.update(cx, |s, cx| s.pick(boundary, mode, window, cx));
            })
            .keyboard_control(Ring::Outset(f32::from(t.control_radius())), window, cx)
            .into_any_element()
    }

    fn when_rows(
        &self,
        fields: &CalendarEventFields,
        l: &L10n,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Vec<AnyElement> {
        let view = cx.entity().downgrade();
        let mut rows = vec![];
        let all_day_view = view.clone();
        rows.push(
            forms::form_row(
                l.calendar_field_all_day(),
                Switch::new(
                    "calendar-editor-all-day",
                    l.calendar_field_all_day(),
                    fields.all_day,
                )
                .on_click(Rc::new({
                    let on = fields.all_day;
                    move |_, _, cx| {
                        let _ = all_day_view.update(cx, |s, cx| s.set_all_day(!on, cx));
                    }
                })),
                cx,
            )
            .into_any_element(),
        );
        let boundary_row = |this: &Self,
                            label: String,
                            boundary: Boundary,
                            wall: &CalendarWallTime,
                            window: &mut Window,
                            cx: &mut Context<Self>| {
            let (date_id, time_id, time_label) = match boundary {
                Boundary::Start => (
                    "calendar-editor-start-date",
                    "calendar-editor-start-time",
                    l.calendar_field_start_time(),
                ),
                Boundary::End => (
                    "calendar-editor-end-date",
                    "calendar-editor-end-time",
                    l.calendar_field_end_time(),
                ),
            };
            let mut control = div()
                .flex()
                .items_center()
                .gap(px(8.))
                .child(this.picker_button(
                    date_id,
                    label.clone(),
                    format::full_day(wall, l),
                    boundary,
                    PickerMode::Date,
                    window,
                    cx,
                ));
            if !fields.all_day {
                control = control.child(this.picker_button(
                    time_id,
                    time_label,
                    format::time(wall, l),
                    boundary,
                    PickerMode::Time,
                    window,
                    cx,
                ));
            }
            (label, control)
        };
        let (label, control) = boundary_row(
            self,
            l.calendar_field_starts(),
            Boundary::Start,
            &fields.start,
            window,
            cx,
        );
        rows.push(forms::form_row(label, control, cx).into_any_element());
        match fields.end.clone() {
            Some(end) => {
                let (label, control) = boundary_row(
                    self,
                    l.calendar_field_ends(),
                    Boundary::End,
                    &end,
                    window,
                    cx,
                );
                let remove_view = view.clone();
                let control = control.child(
                    IconButton::new(
                        "calendar-editor-remove-end",
                        IconName::X,
                        l.calendar_remove_end(),
                    )
                    .size(24., 12.)
                    .round()
                    .on_click(Rc::new(move |_, _, cx| {
                        let _ = remove_view.update(cx, |s, cx| s.set_end(None, cx));
                    })),
                );
                let mut row = forms::form_row(label, control, cx);
                if self.issue("endBeforeStart") {
                    row = row.child(
                        div()
                            .id("calendar-editor-end-error")
                            .role(Role::Alert)
                            .px(px(12.))
                            .pb(px(8.))
                            .text_size(px(cx.conduit().metrics.small))
                            .text_color(cx.conduit().roles.danger)
                            .child(SharedString::from(l.calendar_end_before_start()))
                            .child(live_text(
                                "live",
                                Some(l.calendar_end_before_start().into()),
                                Priority::High,
                            )),
                    );
                }
                rows.push(row.into_any_element());
            }
            None => {
                let add_view = view.clone();
                rows.push(
                    forms::form_row(
                        l.calendar_field_ends(),
                        Button::new("calendar-editor-add-end", l.calendar_add_end())
                            .icon(IconName::Plus)
                            .on_click(Rc::new(move |_, _, cx| {
                                let _ = add_view.update(cx, |s, cx| s.add_end(cx));
                            })),
                        cx,
                    )
                    .into_any_element(),
                );
            }
        }
        let editor = self.editor.as_ref();
        let custom = editor.is_some_and(|e| e.rule.is_some());
        let mut choices: Vec<Choice> = format::REPEATS
            .iter()
            .map(|r| Choice::new(*r, format::repeat_label(r, l)))
            .collect();
        if custom || fields.repeat == "custom" {
            choices.push(Choice::new("custom", l.calendar_repeat_custom()).separated());
        }
        rows.push(
            forms::form_row(
                l.calendar_field_repeat(),
                controls::popup(
                    "calendar-repeat",
                    &l.calendar_field_repeat(),
                    choices,
                    &fields.repeat,
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

    fn people_rows(
        &self,
        fields: &CalendarEventFields,
        l: &L10n,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Vec<AnyElement> {
        let t = cx.conduit().clone();
        let r = t.roles;
        let view = cx.entity().downgrade();
        let mut rows: Vec<AnyElement> = fields
            .attendees
            .iter()
            .enumerate()
            .map(|(i, person)| {
                let name = person
                    .name
                    .clone()
                    .filter(|n| !n.trim().is_empty())
                    .unwrap_or_else(|| l.calendar_invited_person());
                let remove_view = view.clone();
                let id = person.user_id.clone();
                div()
                    .id(ElementId::NamedInteger(
                        "calendar-editor-person".into(),
                        i as u64,
                    ))
                    .min_h(px(36.))
                    .px(px(12.))
                    .flex()
                    .items_center()
                    .gap(px(10.))
                    .child(icon(IconName::User, 13., r.text_subtle))
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .truncate()
                            .text_size(px(t.metrics.control))
                            .child(SharedString::from(name.clone())),
                    )
                    .child(
                        IconButton::new(
                            ElementId::NamedInteger("calendar-editor-remove".into(), i as u64),
                            IconName::X,
                            l.calendar_remove_person(&name),
                        )
                        .size(24., 12.)
                        .round()
                        .on_click(Rc::new(move |_, _, cx| {
                            let id = id.clone();
                            let _ = remove_view.update(cx, |s, cx| s.remove_person(&id, cx));
                        })),
                    )
                    .into_any_element()
            })
            .collect();
        if self.adding_people {
            let mut search = div()
                .px(px(12.))
                .py(px(8.))
                .flex()
                .flex_col()
                .gap(px(4.))
                .child(Input::new(&self.people));
            let typed = !self.people.read(cx).value().trim().is_empty();
            if typed && self.people_results.is_empty() {
                search = search.child(
                    div()
                        .px(px(4.))
                        .text_size(px(t.metrics.small))
                        .text_color(r.text_subtle)
                        .child(SharedString::from(l.desktop_calendar_no_people())),
                );
            }
            for (i, person) in self.people_results.iter().enumerate() {
                let pick_view = view.clone();
                let chosen = person.clone();
                let name = if person.name.trim().is_empty() {
                    person.email.clone().unwrap_or_default()
                } else {
                    person.name.clone()
                };
                search = search.child(
                    div()
                        .id(ElementId::NamedInteger(
                            "calendar-editor-person-result".into(),
                            i as u64,
                        ))
                        .role(Role::Button)
                        .aria_label(SharedString::from(name.clone()))
                        .px(px(8.))
                        .py(px(5.))
                        .rounded(px(6.))
                        .cursor_pointer()
                        .hover(|s| s.bg(r.overlay_hover))
                        .flex()
                        .flex_col()
                        .child(
                            div()
                                .text_size(px(t.metrics.control))
                                .child(SharedString::from(name)),
                        )
                        .when_some(person.email.clone(), |d, email| {
                            d.child(
                                div()
                                    .text_size(px(t.metrics.small))
                                    .text_color(r.text_subtle)
                                    .child(SharedString::from(email)),
                            )
                        })
                        .on_click(move |_, window, cx| {
                            let chosen = chosen.clone();
                            let _ = pick_view.update(cx, |s, cx| s.add_person(&chosen, window, cx));
                        })
                        .keyboard_list_item(Ring::Inset(6.), window, cx),
                );
            }
            rows.push(search.into_any_element());
        } else {
            let add_view = view.clone();
            rows.push(
                div()
                    .px(px(12.))
                    .py(px(8.))
                    .flex()
                    .child(
                        Button::new("calendar-editor-add-people", l.calendar_add_people())
                            .icon(IconName::UserPlus)
                            .on_click(Rc::new(move |_, window, cx| {
                                let _ =
                                    add_view.update(cx, |s, cx| s.show_people_search(window, cx));
                            })),
                    )
                    .into_any_element(),
            );
        }
        rows
    }
}

impl SheetBody for EventEditor {
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
                .items_center()
                .justify_end()
                .gap(px(8.))
                .child(
                    Button::new("calendar-editor-cancel", l.cancel()).on_click(Rc::new(
                        move |_, window, cx| {
                            let _ = cancel_view.update(cx, |s, cx| s.cancel(window, cx));
                        },
                    )),
                )
                .child(
                    Button::new("calendar-editor-save", l.save())
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
        sheet_title(self.editor.as_ref(), cx.l10n()).into()
    }

    /// Edits not saved, or a save still out: Quit asks first.
    fn unsaved(&self, _: &App) -> bool {
        self.saving || self.has_edits()
    }
}

impl EventEditor {
    /// Something was changed: as the daemon last said, or typed (or a start
    /// picked) since, before its check is back.
    fn has_edits(&self) -> bool {
        self.changed
            || self.pending_start.is_some()
            || self.fields.as_ref() != self.editor.as_ref().map(|e| &e.fields)
    }
}

fn sheet_title(editor: Option<&CalendarEditor>, l: &L10n) -> String {
    match editor {
        Some(e) if e.series => l.calendar_edit_series_title(),
        Some(e) if !e.is_new => l.calendar_edit_event_title(),
        _ => l.calendar_new_event_title(),
    }
}

impl Render for EventEditor {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let t = cx.conduit().clone();
        let r = t.roles;
        let l = cx.l10n().clone();
        let focus = self.focus.clone();
        let mut body: Vec<AnyElement> = vec![
            div()
                .id("sheet-title")
                .role(Role::Heading)
                .text_size(px(t.metrics.body + 2.))
                .font_weight(FontWeight::SEMIBOLD)
                .child(SharedString::from(sheet_title(self.editor.as_ref(), &l)))
                .into_any_element(),
        ];
        if let (Some(editor), Some(fields)) = (self.editor.clone(), self.fields.clone()) {
            let show = |issue: &str| self.attempted && self.issue(issue);
            body.push(
                forms::form_group(
                    vec![
                        forms::field(
                            l.calendar_field_title(),
                            &self.title,
                            None,
                            show("titleRequired").then(|| l.calendar_title_required().into()),
                            window,
                            cx,
                        )
                        .into_any_element(),
                        forms::field(
                            l.calendar_field_location(),
                            &self.location,
                            None,
                            None,
                            window,
                            cx,
                        )
                        .into_any_element(),
                    ],
                    cx,
                )
                .into_any_element(),
            );
            let when = self.when_rows(&fields, &l, window, cx);
            let mut when_group = div()
                .flex()
                .flex_col()
                .gap(px(6.))
                .child(forms::form_group(when, cx));
            if fields.repeat == "custom" {
                when_group = when_group.child(forms::group_footer(
                    format!(
                        "{} {}",
                        l.calendar_repeat_kept(),
                        editor.rule.clone().unwrap_or_default()
                    ),
                    cx,
                ));
            } else if fields.repeat != "none" {
                when_group = when_group.child(forms::group_footer(
                    l.calendar_recurrence_timezone_note(),
                    cx,
                ));
            }
            body.push(when_group.into_any_element());

            let calendars: Vec<Choice> = editor
                .calendars
                .iter()
                .map(|c| Choice::new(c.id.clone(), c.name.clone()))
                .collect();
            let mut calendar_group = div().flex().flex_col().gap(px(6.));
            if calendars.is_empty() {
                calendar_group = calendar_group.child(forms::form_error(
                    "calendar-editor-no-calendar",
                    l.calendar_no_writable_calendar(),
                    cx,
                ));
            } else {
                let selected = if fields.calendar_id.is_empty() {
                    l.calendar_choose_calendar()
                } else {
                    fields.calendar_id.clone()
                };
                calendar_group = calendar_group.child(forms::form_group(
                    vec![
                        forms::form_row(
                            l.calendar_field_calendar(),
                            controls::popup(
                                "calendar-calendar",
                                &l.calendar_field_calendar(),
                                calendars,
                                &selected,
                                false,
                                window,
                                cx,
                            ),
                            cx,
                        )
                        .into_any_element(),
                    ],
                    cx,
                ));
                if show("calendarRequired") {
                    calendar_group = calendar_group.child(
                        div()
                            .id("calendar-editor-calendar-error")
                            .role(Role::Alert)
                            .px(px(12.))
                            .text_size(px(t.metrics.small))
                            .text_color(r.danger)
                            .child(SharedString::from(l.calendar_calendar_required()))
                            .child(live_text(
                                "live",
                                Some(l.calendar_calendar_required().into()),
                                Priority::High,
                            )),
                    );
                }
            }
            body.push(calendar_group.into_any_element());

            let people = self.people_rows(&fields, &l, window, cx);
            body.push(
                div()
                    .flex()
                    .flex_col()
                    .gap(px(6.))
                    .child(
                        div()
                            .px(px(12.))
                            .text_size(px(t.metrics.small))
                            .text_color(r.text_subtle)
                            .child(SharedString::from(l.calendar_field_attendees())),
                    )
                    .child(forms::form_group(people, cx))
                    .child(forms::group_footer(l.calendar_attendees_note(), cx))
                    .into_any_element(),
            );
            body.push(
                div()
                    .flex()
                    .flex_col()
                    .gap(px(6.))
                    .child(
                        div()
                            .px(px(12.))
                            .text_size(px(t.metrics.small))
                            .text_color(r.text_subtle)
                            .child(SharedString::from(l.calendar_field_description())),
                    )
                    .child(forms::form_group(
                        vec![
                            div()
                                .p(px(10.))
                                .child(Textarea::new(&self.description))
                                .into_any_element(),
                        ],
                        cx,
                    ))
                    .into_any_element(),
            );
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
            body.push(
                forms::form_error("calendar-editor-error", failure.clone(), cx).into_any_element(),
            );
        }
        div()
            .id("calendar-editor")
            .track_focus(&self.focus)
            .w_full()
            .flex()
            .flex_col()
            .gap(px(16.))
            .line_height(relative(1.3))
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
    use crate::shell::date_picker::{AutoPick, WallClock};
    use crate::stores::rpc::fake::FakeDaemon;
    use crate::views::sheet::bench::bench;

    fn wall(day: i64, hour: i64, minute: i64) -> CalendarWallTime {
        CalendarWallTime {
            year: 2026,
            month: 11,
            day,
            hour,
            minute,
        }
    }

    /// An editor for a new event starting on the 12th at 9:00, its first
    /// check answered.
    fn editor(
        cx: &mut gpui_kit::TestAppContext,
    ) -> (FakeDaemon, Entity<EventEditor>, &mut VisualTestContext) {
        let (daemon, stores, vcx) = bench(cx);
        daemon.on::<methods::CalendarEditor>(|_| {
            Ok(serde_json::json!({
                "token": "ed-1",
                "isNew": true,
                "series": false,
                "fields": {
                    "title": "Seed swap",
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
        daemon.on::<methods::CalendarSave>(|p| {
            Ok(serde_json::json!({"fields": p["fields"], "saved": true}))
        });
        vcx.update(|window, cx| open(stores, None, None, window, cx));
        vcx.run_until_parked();
        let editor = vcx
            .update(|_, cx| sheet::current::<EventEditor>(cx))
            .expect("the editor opens");
        (daemon, editor, vcx)
    }

    /// A start time picked while the day picked before it is still being
    /// checked starts from that day: Save keeps both.
    #[gpui_kit::test]
    fn a_start_time_picked_before_the_day_settles_keeps_the_day(cx: &mut gpui_kit::TestAppContext) {
        let (daemon, editor, vcx) = editor(cx);
        daemon.on::<methods::CalendarCheckDraft>(|p| {
            Ok(serde_json::json!({"fields": p["fields"], "changed": true}))
        });
        vcx.run_until_parked();
        let _held = daemon.hold::<methods::CalendarCheckDraft>();
        // The 13th, picked; its check is still out.
        vcx.update(|_, cx| editor.update(cx, |e, cx| e.set_start(wall(13, 9, 0), cx)));
        // Then 10:30 in the start's time picker.
        vcx.update(|window, cx| {
            cx.set_global(AutoPick(Some(Some(WallClock {
                hour: 10,
                minute: 30,
                ..WallClock::default()
            }))));
            editor.update(cx, |e, cx| {
                e.pick(Boundary::Start, PickerMode::Time, window, cx)
            })
        });
        vcx.run_until_parked();
        vcx.update(|window, cx| editor.update(cx, |e, cx| e.save(window, cx)));
        vcx.run_until_parked();
        let saves = daemon.calls::<methods::CalendarSave>();
        assert_eq!(
            saves.last().map(|s| s["movedStart"].clone()),
            Some(serde_json::to_value(wall(13, 10, 30)).unwrap()),
            "the day picked before the time was lost"
        );
    }

    /// A start whose check failed is not saved behind the start shown: what
    /// the Start row shows is what Save sends.
    #[gpui_kit::test]
    fn a_start_whose_check_failed_is_not_saved_unseen(cx: &mut gpui_kit::TestAppContext) {
        let (daemon, editor, vcx) = editor(cx);
        daemon.on::<methods::CalendarCheckDraft>(|p| {
            if p["movedStart"].is_null() {
                Ok(serde_json::json!({"fields": p["fields"], "changed": false}))
            } else {
                Err(conduit_daemon::protocol::error("rpc.timeout", "slow"))
            }
        });
        vcx.run_until_parked();
        vcx.update(|_, cx| editor.update(cx, |e, cx| e.set_start(wall(13, 9, 0), cx)));
        vcx.run_until_parked();
        let shown = editor.read_with(vcx, |e, _| e.fields.as_ref().map(|f| f.start.clone()));
        assert_eq!(shown, Some(wall(12, 9, 0)));
        vcx.update(|window, cx| editor.update(cx, |e, cx| e.save(window, cx)));
        vcx.run_until_parked();
        let saves = daemon.calls::<methods::CalendarSave>();
        assert_eq!(
            saves.last().map(|s| s["movedStart"].clone()),
            Some(serde_json::Value::Null),
            "Save sent a start the Start row does not show"
        );
    }
}
