//! The event sheet: what an agenda row opens, as the phone's event sheet
//! shows it. An event's day and time, place, calendar, repeat, organizer and
//! people, its description, the account's answer to an invitation (Going,
//! Maybe, Can't Go), and Edit… / Delete… (the whole series for a repeating
//! event, as the server has no way to change one occurrence).
//!
//! A scheduled-task entry is the server's projection of a task, not an
//! event: its sheet opens the task, or the chat or channel a run produced.

use std::rc::Rc;

use conduit_components::ActiveConduitTheme as _;
use conduit_components::views::kit::{Button, Segment, Segmented, grouped_section, setting_row};
use conduit_protocol::{
    AppSettingsPatch, CalendarEventDetail, CalendarItemRef, CalendarRsvpEdit, RpcError, methods,
};
use gpui_kit::prelude::*;
use gpui_kit::{
    AnyElement, App, AsyncApp, Context, FontWeight, Role, SharedString, Subscription, WeakEntity,
    Window, div, px, relative,
};

use super::{color_dot, confirm_delete, format};
use crate::l10n::ActiveL10n as _;
use crate::stores::Stores;
use crate::stores::navigation::AreaItem;
use crate::views::sheet::{self, SheetBody};

/// The sheet's width.
pub const WIDTH: f32 = 460.;

/// Opens the sheet for the agenda item `key` on the main window.
pub fn open(stores: Stores, key: String, window: &mut Window, cx: &mut App) {
    sheet::open(window, WIDTH, cx, move |w, cx| {
        EventSheet::new(stores, key, w, cx)
    });
}

pub struct EventSheet {
    stores: Stores,
    pub key: String,
    pub detail: Option<CalendarEventDetail>,
    /// Reading the event failed.
    pub load_error: Option<RpcError>,
    /// An answer is on its way.
    pub responding: bool,
    /// The last change was refused: what to say.
    pub failure: Option<String>,
    /// The event and its answer are the opening account's: the sheet closes
    /// when another signs in.
    _account: Subscription,
}

impl EventSheet {
    pub fn new(stores: Stores, key: String, window: &mut Window, cx: &mut Context<Self>) -> Self {
        let account = sheet::close_with_account(&stores, cx);
        let mut this = Self {
            stores,
            key,
            detail: None,
            load_error: None,
            responding: false,
            failure: None,
            _account: account,
        };
        this.load(window, cx);
        this
    }

    fn load(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let rpc = self.stores.connection.read(cx).rpc();
        let call = rpc.call::<methods::CalendarEvent>(&CalendarItemRef {
            key: self.key.clone(),
        });
        let _ = window;
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result = call.await;
            let _ = this.update(cx, |s, cx| {
                match result {
                    Ok(detail) => s.detail = Some(detail),
                    Err(e) => {
                        log::warn!("calendar.event: {e}");
                        s.load_error = Some(e);
                    }
                }
                cx.notify();
            });
        })
        .detach();
    }

    /// Sends the account's answer (`accepted`, `tentative`, `declined`).
    pub fn respond(&mut self, answer: &str, cx: &mut Context<Self>) {
        if self.responding {
            return;
        }
        let Some(detail) = self.detail.as_mut() else {
            return;
        };
        let previous = detail.item.answer.clone();
        detail.item.answer = Some(answer.to_string());
        self.responding = true;
        self.failure = None;
        cx.notify();
        let rpc = self.stores.connection.read(cx).rpc();
        let call = rpc.call::<methods::CalendarRespond>(&CalendarRsvpEdit {
            key: self.key.clone(),
            answer: answer.to_string(),
        });
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result = call.await;
            let _ = this.update(cx, |s, cx| {
                s.responding = false;
                match result {
                    Ok(detail) => {
                        if let Some(shown) = s.detail.as_mut() {
                            shown.item.answer = detail.item.answer;
                        }
                    }
                    Err(e) => {
                        log::warn!("calendar.respond: {e}");
                        let l = cx.l10n().clone();
                        if let Some(shown) = s.detail.as_mut() {
                            shown.item.answer = previous;
                        }
                        s.failure = Some(format::failure_text(&e, l.calendar_rsvp_failed(), &l));
                    }
                }
                cx.notify();
            });
        })
        .detach();
    }

    pub fn edit(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let (stores, key) = (self.stores.clone(), self.key.clone());
        // One sheet at a time: this one goes, then the editor comes.
        sheet::dismiss(cx);
        let _ = window;
        cx.defer(move |cx| {
            with_main_window(cx, move |window, cx| {
                super::editor::open(stores, Some(key), None, window, cx)
            });
        });
    }

    pub fn delete(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(detail) = self.detail.clone() else {
            return;
        };
        // Once deleted, this sheet closes: not one opened meanwhile.
        let body = cx.entity();
        confirm_delete(
            self.stores.clone(),
            detail.item,
            Some(Box::new(move |cx: &mut App| {
                if sheet::current::<Self>(cx).is_some_and(|open| open == body) {
                    sheet::dismiss(cx);
                }
            })),
            window,
            cx,
        );
    }

    /// Opens what a scheduled entry leads to: the task, or a run's chat or
    /// channel.
    fn open_target(&mut self, target: Target, cx: &mut Context<Self>) {
        let stores = self.stores.clone();
        sheet::dismiss(cx);
        cx.defer(move |cx| match target {
            Target::Task(id) => {
                stores.tasks.update(cx, |t, cx| t.select(Some(id), cx));
                stores
                    .navigation
                    .update(cx, |n, cx| n.open_item(AreaItem::Automations, cx));
            }
            Target::Chat(id) => stores.navigation.update(cx, |n, cx| n.open(id, cx)),
            Target::Channel(id) => stores
                .navigation
                .update(cx, |n, cx| n.open_item(AreaItem::Channel(id), cx)),
            Target::Advanced => stores.app_settings.update(cx, |s, cx| {
                s.set(
                    AppSettingsPatch {
                        advanced_features_enabled: Some(true),
                        ..Default::default()
                    },
                    cx,
                )
            }),
        });
    }

    fn scheduled_body(
        &self,
        detail: &CalendarEventDetail,
        cx: &mut Context<Self>,
    ) -> Vec<AnyElement> {
        let t = cx.conduit().clone();
        let l = cx.l10n().clone();
        let item = &detail.item;
        let advanced = self.stores.session.read(cx).capabilities().scheduled_tasks;
        let mut out = vec![];
        if item.scheduled_state.as_deref() == Some("failed") {
            out.push(
                div()
                    .text_size(px(t.metrics.control))
                    .text_color(t.roles.danger)
                    .child(SharedString::from(l.calendar_scheduled_run_failed()))
                    .into_any_element(),
            );
        }
        if item.automation_id.is_some() && !advanced {
            // As the phone's task page says when Advanced is off.
            out.push(
                div()
                    .text_size(px(t.metrics.small + 0.5))
                    .line_height(relative(1.4))
                    .text_color(t.roles.text_subtle)
                    .child(SharedString::from(
                        l.advanced_required_message(&l.scheduled_tasks_title()),
                    ))
                    .into_any_element(),
            );
        }
        out
    }

    fn event_body(&self, detail: &CalendarEventDetail, cx: &mut Context<Self>) -> Vec<AnyElement> {
        let t = cx.conduit().clone();
        let r = t.roles;
        let l = cx.l10n().clone();
        let item = &detail.item;
        let mut out = vec![];
        let mut rows: Vec<AnyElement> = vec![];
        let value = |text: String| {
            div()
                .max_w(px(260.))
                .truncate()
                .text_size(px(t.metrics.control))
                .text_color(r.text_subtle)
                .child(SharedString::from(text))
        };
        if let Some(name) = detail.calendar_name.clone() {
            let dot = format::parse_color(detail.calendar_color.as_deref()).unwrap_or(r.text_faint);
            rows.push(
                setting_row(
                    l.calendar_field_calendar(),
                    None,
                    div()
                        .flex()
                        .items_center()
                        .gap(px(6.))
                        .child(color_dot(dot, 9.))
                        .child(value(name)),
                    cx,
                )
                .into_any_element(),
            );
        }
        if item.recurring {
            rows.push(
                setting_row(
                    l.calendar_field_repeat(),
                    None,
                    value(format::repeat_label(&detail.repeat, &l)),
                    cx,
                )
                .into_any_element(),
            );
        }
        if let Some(organizer) = detail.organizer.clone() {
            rows.push(
                setting_row(l.calendar_field_organizer(), None, value(organizer), cx)
                    .into_any_element(),
            );
        }
        if detail.attendee_count > 0 {
            rows.push(
                setting_row(
                    l.calendar_field_attendees(),
                    None,
                    value(detail.attendee_count.to_string()),
                    cx,
                )
                .into_any_element(),
            );
        }
        if !rows.is_empty() {
            out.push(
                grouped_section(
                    None,
                    rows,
                    item.recurring
                        .then(|| SharedString::from(l.calendar_event_series_note())),
                    cx,
                )
                .into_any_element(),
            );
        }
        if let Some(description) = detail.description.clone().filter(|d| !d.trim().is_empty()) {
            out.push(
                grouped_section(
                    Some(l.calendar_field_description().into()),
                    vec![
                        div()
                            .id("calendar-event-description")
                            .px(px(12.))
                            .py(px(10.))
                            .text_size(px(t.metrics.control))
                            .line_height(relative(1.4))
                            .text_color(r.text)
                            .child(SharedString::from(description))
                            .into_any_element(),
                    ],
                    None,
                    cx,
                )
                .into_any_element(),
            );
        }
        if item.invited && detail.status != "gone" {
            let answers = ["accepted", "tentative", "declined"];
            let selected = answers
                .iter()
                .position(|a| item.answer.as_deref() == Some(*a))
                .unwrap_or(answers.len());
            let view = cx.entity().downgrade();
            out.push(
                div()
                    .flex()
                    .flex_col()
                    .gap(px(6.))
                    .child(
                        div()
                            .id("calendar-rsvp-prompt")
                            .role(Role::Heading)
                            .px(px(12.))
                            .text_size(px(t.metrics.small))
                            .text_color(r.text_subtle)
                            .child(SharedString::from(l.calendar_rsvp_prompt())),
                    )
                    .child(
                        Segmented::new(
                            "calendar-rsvp",
                            l.calendar_rsvp_prompt(),
                            vec![
                                Segment::new(l.calendar_rsvp_accepted()),
                                Segment::new(l.calendar_rsvp_tentative()),
                                Segment::new(l.calendar_rsvp_declined()),
                            ],
                            selected,
                        )
                        .on_select(Rc::new(move |i, _, cx| {
                            let _ = view.update(cx, |s, cx| s.respond(answers[i], cx));
                        })),
                    )
                    .into_any_element(),
            );
        }
        let notice = if detail.status == "gone" {
            Some((l.calendar_event_gone(), true))
        } else if !detail.can_edit {
            Some((
                if item.invited {
                    l.calendar_event_read_only()
                } else {
                    l.calendar_event_read_only_not_invited()
                },
                false,
            ))
        } else {
            None
        };
        if let Some((text, error)) = notice {
            out.push(
                div()
                    .id("calendar-event-notice")
                    .role(Role::Status)
                    .px(px(4.))
                    .text_size(px(t.metrics.small + 0.5))
                    .line_height(relative(1.4))
                    .text_color(if error { r.danger } else { r.text_subtle })
                    .child(SharedString::from(text))
                    .into_any_element(),
            );
        }
        out
    }
}

/// Where a scheduled entry leads.
enum Target {
    Task(String),
    Chat(String),
    Channel(String),
    /// Settings' Advanced, which the task needs.
    Advanced,
}

/// Runs `f` on the main window, if there is one.
pub fn with_main_window(cx: &mut App, f: impl FnOnce(&mut Window, &mut App) + 'static) {
    if let Some(handle) = cx
        .try_global::<crate::AppState>()
        .and_then(|s| s.main_window)
    {
        let _ = handle.update(cx, |_, window, cx| f(window, cx));
    }
}

impl SheetBody for EventSheet {
    fn footer(&mut self, _: &mut Window, cx: &mut Context<Self>) -> Option<AnyElement> {
        let l = cx.l10n().clone();
        let view = cx.entity().downgrade();
        let mut row = div().w_full().flex().items_center().gap(px(8.));
        let done_view = view.clone();
        match self.detail.clone() {
            Some(detail) if detail.item.kind == "scheduled" => {
                let item = detail.item.clone();
                let advanced = self.stores.session.read(cx).capabilities().scheduled_tasks;
                if let Some(id) = item.automation_id.clone() {
                    let task_view = view.clone();
                    row = row.child(if advanced {
                        Button::new("calendar-open-task", l.desktop_calendar_open_task()).on_click(
                            Rc::new(move |_, _, cx| {
                                let id = id.clone();
                                let _ = task_view
                                    .update(cx, |s, cx| s.open_target(Target::Task(id), cx));
                            }),
                        )
                    } else {
                        Button::new("calendar-turn-on-advanced", l.advanced_turn_on()).on_click(
                            Rc::new(move |_, _, cx| {
                                let _ = task_view
                                    .update(cx, |s, cx| s.open_target(Target::Advanced, cx));
                            }),
                        )
                    });
                }
                let result = item
                    .result_channel_id
                    .clone()
                    .map(|c| (l.scheduled_task_view_channel(), Target::Channel(c)))
                    .or_else(|| {
                        item.result_chat_id
                            .clone()
                            .map(|c| (l.scheduled_task_view_chat(), Target::Chat(c)))
                    });
                if let Some((label, target)) = result {
                    let open_view = view.clone();
                    let target = Rc::new(std::cell::RefCell::new(Some(target)));
                    row = row.child(Button::new("calendar-view-result", label).on_click(Rc::new(
                        move |_, _, cx| {
                            if let Some(target) = target.borrow_mut().take() {
                                let _ = open_view.update(cx, |s, cx| s.open_target(target, cx));
                            }
                        },
                    )));
                }
            }
            Some(detail) if detail.can_edit => {
                let series = detail.item.recurring;
                let delete_view = view.clone();
                let edit_view = view.clone();
                row = row
                    .child(
                        Button::new(
                            "calendar-event-delete",
                            if series {
                                l.desktop_calendar_delete_series_ellipsis()
                            } else {
                                l.desktop_delete_ellipsis()
                            },
                        )
                        .danger()
                        .on_click(Rc::new(move |_, window, cx| {
                            let _ = delete_view.update(cx, |s, cx| s.delete(window, cx));
                        })),
                    )
                    .child(div().flex_1())
                    .child(
                        Button::new(
                            "calendar-event-edit",
                            if series {
                                l.desktop_calendar_edit_series_ellipsis()
                            } else {
                                l.desktop_edit_ellipsis()
                            },
                        )
                        .on_click(Rc::new(move |_, window, cx| {
                            let _ = edit_view.update(cx, |s, cx| s.edit(window, cx));
                        })),
                    );
            }
            _ => {}
        }
        Some(
            row.child(div().flex_1())
                .child(
                    Button::new("calendar-event-done", l.done())
                        .primary()
                        .on_click(Rc::new(move |_, window, cx| {
                            let _ = done_view.update(cx, |s, cx| s.cancel(window, cx));
                        })),
                )
                .into_any_element(),
        )
    }

    fn cancel(&mut self, _: &mut Window, cx: &mut Context<Self>) {
        sheet::dismiss(cx);
    }

    fn label(&self, cx: &App) -> SharedString {
        let l = cx.l10n();
        match &self.detail {
            Some(d) if d.item.kind == "scheduled" => l.desktop_calendar_scheduled_title().into(),
            _ => l.calendar_event_detail_title().into(),
        }
    }
}

impl Render for EventSheet {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let t = cx.conduit().clone();
        let r = t.roles;
        let l = cx.l10n().clone();
        let Some(detail) = self.detail.clone() else {
            let text = match &self.load_error {
                Some(e) => format::failure_text(e, l.calendar_event_load_failed(), &l),
                None => l.desktop_loading(),
            };
            return div()
                .id("calendar-event-loading")
                .role(Role::Status)
                .py(px(24.))
                .text_size(px(t.metrics.control))
                .text_color(r.text_subtle)
                .child(SharedString::from(text))
                .into_any_element();
        };
        let item = &detail.item;
        let scheduled = item.kind == "scheduled";
        let title = if item.title.trim().is_empty() {
            l.calendar_untitled_event()
        } else {
            item.title.clone()
        };
        let mut head = div()
            .flex()
            .flex_col()
            .gap(px(4.))
            .child(
                div()
                    .id("sheet-title")
                    .role(Role::Heading)
                    .text_size(px(t.metrics.body + 4.))
                    .font_weight(FontWeight::SEMIBOLD)
                    .text_color(if item.cancelled {
                        r.text_subtle
                    } else {
                        r.text
                    })
                    .when(item.cancelled, |d| d.line_through())
                    .child(SharedString::from(title)),
            )
            .child(
                div()
                    .id("calendar-event-when")
                    .text_size(px(t.metrics.control))
                    .text_color(r.text_subtle)
                    .child(SharedString::from(if scheduled {
                        format!(
                            "{} · {}",
                            format::when(item, &l),
                            format::scheduled_label(item, &l)
                        )
                    } else {
                        format::when(item, &l)
                    })),
            );
        if let Some(location) = item.location.clone().filter(|s| !s.trim().is_empty()) {
            head = head.child(
                div()
                    .id("calendar-event-location")
                    .text_size(px(t.metrics.control))
                    .text_color(r.text_subtle)
                    .child(SharedString::from(location)),
            );
        }
        let mut body = vec![head.into_any_element()];
        body.extend(if scheduled {
            self.scheduled_body(&detail, cx)
        } else {
            self.event_body(&detail, cx)
        });
        if let Some(failure) = self.failure.clone() {
            body.push(
                div()
                    .id("calendar-event-error")
                    .role(Role::Alert)
                    .text_size(px(t.metrics.small + 0.5))
                    .text_color(r.danger)
                    .child(SharedString::from(failure))
                    .into_any_element(),
            );
        }
        div()
            .flex()
            .flex_col()
            .gap(px(16.))
            .children(body)
            .into_any_element()
    }
}
