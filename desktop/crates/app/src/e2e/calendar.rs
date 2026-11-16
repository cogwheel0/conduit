//! `--e2e calendar`: the Calendar pane on the seeded server.
//!
//! Signs in to the local Open WebUI (whose second user has invited the
//! admin to an event three days ahead), opens Calendar › Upcoming, then:
//! the agenda starts today and lists the invitation; an event is created in
//! the editor (its start moved, the end following), opened and edited; the
//! invitation is answered (Going), and the row says so; a daily event is
//! created, one of its later days is opened, and Edit Series renames every
//! day of it; a calendar is hidden and shown again; the range moves a page
//! and comes back to Today; a calendar is created and made the default;
//! the events are deleted (the series as a whole). Screenshots in light and
//! dark, and AccessKit checks of the pane and its sheets.

use std::path::Path;
use std::time::Duration;

use conduit_protocol::{CalendarAgenda, CalendarItemDto, CalendarWallTime};
use gpui_kit::{App, AsyncApp, Entity};

use super::{E2eInputs, NO_SERVER, ax, has, main_window, ok, settle, shoot_main, wait_until};
use crate::AppState;
use crate::actions::{CalendarMenu, SettingsChoice};
use crate::stores::navigation::AreaItem;
use crate::views::calendar::editor::EventEditor;
use crate::views::calendar::event_sheet::EventSheet;
use crate::views::calendar::new_calendar::NewCalendarSheet;
use crate::views::calendar::{CalendarPane, format};
use crate::views::sheet;

fn agenda(cx: &mut App) -> Option<CalendarAgenda> {
    cx.global::<AppState>()
        .stores
        .calendar
        .read(cx)
        .agenda
        .clone()
}

/// Every agenda item titled `title`, in order.
fn titled(title: &str, cx: &mut App) -> Vec<CalendarItemDto> {
    agenda(cx)
        .map(|a| {
            a.days
                .into_iter()
                .flat_map(|d| d.items)
                .filter(|i| i.title == title)
                .collect()
        })
        .unwrap_or_default()
}

fn pane(cx: &mut App) -> Option<Entity<CalendarPane>> {
    let view = cx.global::<AppState>().main_view.clone()?;
    view.read(cx).area_pane.read(cx).calendar.clone()
}

/// Runs `f` on the calendar pane, in the main window.
fn in_pane<R>(
    cx: &mut AsyncApp,
    f: impl FnOnce(&mut CalendarPane, &mut gpui_kit::Window, &mut gpui_kit::Context<CalendarPane>) -> R,
) -> Option<R> {
    let (handle, _) = cx.update(main_window)?;
    let pane = cx.update(pane)?;
    cx.update(|cx| {
        handle
            .update(cx, |_, window, cx| {
                pane.update(cx, |p, cx| f(p, window, cx))
            })
            .ok()
    })
}

fn sheet_of<V: 'static>(cx: &mut App) -> Option<Entity<V>> {
    sheet::current::<V>(cx)
}

async fn wait_sheet<V: 'static>(cx: &mut AsyncApp, loaded: impl Fn(&V) -> bool + 'static) -> bool {
    wait_until(cx, Duration::from_secs(20), move |cx| {
        sheet_of::<V>(cx).is_some_and(|s| loaded(s.read(cx)))
    })
    .await
}

async fn wait_closed(cx: &mut AsyncApp) -> bool {
    wait_until(cx, Duration::from_secs(20), |cx| !sheet::is_open(cx)).await
}

fn in_sheet<V: 'static, R>(
    cx: &mut AsyncApp,
    f: impl FnOnce(&mut V, &mut gpui_kit::Window, &mut gpui_kit::Context<V>) -> R,
) -> Option<R> {
    let handle = cx.update(|cx| sheet::current_window(cx))?;
    let entity = cx.update(sheet_of::<V>)?;
    cx.update(|cx| {
        handle
            .update(cx, |_, window, cx| {
                entity.update(cx, |v, cx| f(v, window, cx))
            })
            .ok()
    })
}

/// `days` after the agenda's today, at `hour`.
fn day_at(today: &CalendarWallTime, days: i64, hour: i64) -> CalendarWallTime {
    let mut day = today.clone();
    for _ in 0..days {
        day = format::next_day(&day);
    }
    CalendarWallTime {
        hour,
        minute: 0,
        ..day
    }
}

/// Opens a new event's editor, names it, moves its start, and saves it.
async fn create(
    title: &str,
    start: CalendarWallTime,
    repeat: Option<&str>,
    cx: &mut AsyncApp,
) -> bool {
    in_pane(cx, |p, window, cx| p.new_event(window, cx));
    if !wait_sheet::<EventEditor>(cx, |e| e.fields.is_some()).await {
        return ok(&format!("{title}: the editor opened"), false);
    }
    let (t, s) = (title.to_string(), start.clone());
    in_sheet::<EventEditor, _>(cx, move |e, window, cx| {
        e.type_title(&t, window, cx);
        e.set_start(s, cx);
    });
    if let Some(repeat) = repeat {
        let value = repeat.to_string();
        in_sheet::<EventEditor, _>(cx, move |e, _, cx| {
            e.on_choice(
                &SettingsChoice {
                    menu: "calendar-repeat".into(),
                    value,
                },
                cx,
            )
        });
    }
    let moved = wait_until(cx, Duration::from_secs(10), move |cx| {
        sheet_of::<EventEditor>(cx).is_some_and(|e| {
            e.read(cx)
                .fields
                .as_ref()
                .is_some_and(|f| f.start == start && f.end.is_some())
        })
    })
    .await;
    let saved_title = title.to_string();
    in_sheet::<EventEditor, _>(cx, |e, window, cx| e.save(window, cx));
    let closed = wait_closed(cx).await;
    let listed = wait_until(cx, Duration::from_secs(20), move |cx| {
        !titled(&saved_title, cx).is_empty()
    })
    .await;
    ok(
        &format!("{title}: the start moved and the end followed"),
        moved,
    ) & ok(&format!("{title}: Save closed the editor"), closed)
        & ok(&format!("{title}: the agenda lists it"), listed)
}

pub async fn run(inputs: &E2eInputs, dir: &Path, cx: &mut AsyncApp) -> bool {
    let Some((url, email, password)) = inputs.owui() else {
        return ok(NO_SERVER, false);
    };
    let invite = inputs
        .get("OWUI_INVITE_TITLE")
        .unwrap_or_else(|| "Seed swap at the garden".into());
    let mut pass = super::chat::sign_in(&url, &email, &password, cx).await;
    let offered = wait_until(cx, Duration::from_secs(60), |cx| {
        cx.global::<AppState>()
            .stores
            .session
            .read(cx)
            .capabilities()
            .calendar
    })
    .await;
    pass &= ok("the account may use the calendar", offered);
    let navigation = cx.update(|cx| cx.global::<AppState>().stores.navigation.clone());
    cx.update(|cx| navigation.update(cx, |n, cx| n.open_item(AreaItem::Calendar, cx)));
    let loaded = wait_until(cx, Duration::from_secs(30), |cx| {
        agenda(cx).is_some_and(|a| a.failure.is_none() && a.first_day.is_some())
    })
    .await;
    pass &= ok("Calendar › Upcoming shows the agenda", loaded);
    let Some(first) = cx.update(agenda) else {
        return ok("an agenda", false);
    };
    let today = first.today.clone().unwrap_or(CalendarWallTime {
        year: 2026,
        month: 1,
        day: 1,
        hour: 0,
        minute: 0,
    });
    pass &= ok(
        "the agenda starts today and spans two weeks",
        first.first_day.as_ref() == Some(&today) && first.day_count == 14,
    );
    pass &= ok(
        "the account's own default calendar is listed and takes events",
        first
            .calendars
            .iter()
            .any(|c| c.owned && c.is_default && c.writable)
            && first.can_create,
    );
    pass &= ok(
        "the scheduled-tasks calendar is listed, read-only",
        first.calendars.iter().any(|c| c.scheduled && !c.writable),
    );
    let invite_title = invite.clone();
    let invited = wait_until(cx, Duration::from_secs(10), move |cx| {
        titled(&invite_title, cx)
            .first()
            .is_some_and(|i| i.invited && !i.editable && i.answer.as_deref() == Some("pending"))
    })
    .await;
    pass &= ok(
        "the second user's invitation is listed, answerable but not editable",
        invited,
    );
    settle(cx, 600).await;
    shoot_main(dir, "calendar-agenda", cx).await;
    if let Some((main, _)) = cx.update(main_window) {
        let controls = ax(main, "calendar-agenda", dir, cx).await;
        pass &= ok(
            "the pane's controls are labelled: New Event, Today, the range and calendars",
            has(&controls, "Button", "New Event")
                && has(&controls, "Button", "Today")
                && has(&controls, "Button", "Previous 14 Days")
                && has(&controls, "Button", "New Calendar")
                && has(&controls, "CheckBox", "Scheduled Tasks"),
        );
    }

    // ── Create an event, open it, edit it ─────────────────────────────
    let tool_swap = "Garden tool swap";
    let start = day_at(&today, 1, 10);
    pass &= create(tool_swap, start.clone(), None, cx).await;
    let row = cx.update(|cx| titled(tool_swap, cx).first().cloned());
    pass &= ok(
        "its row says 10:00 to 11:00 tomorrow, and it can be changed",
        row.as_ref().is_some_and(|r| {
            r.time.kind == "range"
                && r.time.start.as_ref() == Some(&start)
                && r.time.end.as_ref().map(|e| e.hour) == Some(11)
                && r.editable
        }),
    );
    if let Some(row) = row {
        let key = row.key.clone();
        in_pane(cx, move |p, window, cx| p.open(&key, window, cx));
        let fresh = wait_sheet::<EventSheet>(cx, |s| {
            s.detail
                .as_ref()
                .is_some_and(|d| d.status == "fresh" && d.can_edit)
        })
        .await;
        pass &= ok(
            "the event sheet reads the event again and offers Edit",
            fresh,
        );
        settle(cx, 500).await;
        shoot_main(dir, "calendar-event", cx).await;
        if let Some(handle) = cx.update(|cx| sheet::current_window(cx)) {
            let controls = ax(handle, "calendar-event", dir, cx).await;
            pass &= ok(
                "the event sheet has Edit…, Delete… and Done",
                has(&controls, "Button", "Edit…")
                    && has(&controls, "Button", "Delete…")
                    && has(&controls, "Button", "Done"),
            );
        }
        in_sheet::<EventSheet, _>(cx, |s, window, cx| s.edit(window, cx));
        let editing = wait_sheet::<EventEditor>(cx, |e| {
            e.editor.as_ref().is_some_and(|ed| !ed.is_new) && e.fields.is_some()
        })
        .await;
        pass &= ok("Edit… opens the editor on the stored event", editing);
        in_sheet::<EventEditor, _>(cx, |e, window, cx| {
            e.type_title("Garden tool swap, moved", window, cx);
            e.type_location("Allotment gate", window, cx);
        });
        settle(cx, 600).await;
        shoot_main(dir, "calendar-editor", cx).await;
        if let Some(handle) = cx.update(|cx| sheet::current_window(cx)) {
            let controls = ax(handle, "calendar-editor", dir, cx).await;
            pass &= ok(
                "the editor's fields and pickers are labelled",
                has(&controls, "TextInput", "Title")
                    && has(&controls, "Switch", "All Day")
                    && has(&controls, "Button", "Starts")
                    && has(&controls, "ComboBox", "Repeat")
                    && has(&controls, "ComboBox", "Calendar")
                    && has(&controls, "Button", "Add People"),
            );
        }
        in_sheet::<EventEditor, _>(cx, |e, window, cx| e.save(window, cx));
        pass &= ok("Save closes the editor", wait_closed(cx).await);
        let renamed = wait_until(cx, Duration::from_secs(20), |cx| {
            titled(tool_swap, cx).is_empty()
                && titled("Garden tool swap, moved", cx)
                    .first()
                    .is_some_and(|i| i.location.as_deref() == Some("Allotment gate"))
        })
        .await;
        pass &= ok("the agenda shows the edit", renamed);
    }

    // ── Answer the invitation ─────────────────────────────────────────
    if let Some(row) = cx.update(|cx| titled(&invite, cx).first().cloned()) {
        let key = row.key.clone();
        in_pane(cx, move |p, window, cx| p.open(&key, window, cx));
        let opened = wait_sheet::<EventSheet>(cx, |s| {
            s.detail
                .as_ref()
                .is_some_and(|d| d.item.invited && !d.can_edit)
        })
        .await;
        pass &= ok(
            "the invitation's sheet asks for an answer, read-only",
            opened,
        );
        shoot_main(dir, "calendar-invitation", cx).await;
        if let Some(handle) = cx.update(|cx| sheet::current_window(cx)) {
            let controls = ax(handle, "calendar-invitation", dir, cx).await;
            pass &= ok(
                "the answers are labelled radio buttons",
                has(&controls, "RadioButton", "Going")
                    && has(&controls, "RadioButton", "Maybe")
                    && has(&controls, "RadioButton", "Can't Go"),
            );
        }
        in_sheet::<EventSheet, _>(cx, |s, _, cx| s.respond("accepted", cx));
        let answered = wait_until(cx, Duration::from_secs(15), |cx| {
            sheet_of::<EventSheet>(cx).is_some_and(|s| {
                let s = s.read(cx);
                !s.responding
                    && s.detail
                        .as_ref()
                        .is_some_and(|d| d.item.answer.as_deref() == Some("accepted"))
            })
        })
        .await;
        pass &= ok("Going is sent and kept", answered);
        in_sheet::<EventSheet, _>(cx, |s, window, cx| {
            use crate::views::sheet::SheetBody as _;
            s.cancel(window, cx)
        });
        let _ = wait_closed(cx).await;
        let invite_title = invite.clone();
        let row_says = wait_until(cx, Duration::from_secs(15), move |cx| {
            titled(&invite_title, cx)
                .first()
                .is_some_and(|i| i.answer.as_deref() == Some("accepted"))
        })
        .await;
        pass &= ok("the invitation's row says Going", row_says);
    } else {
        pass &= ok("the invitation is in the agenda", false);
    }

    // ── A daily event, edited from one of its days ────────────────────
    let watering = "Morning watering";
    let start = day_at(&today, 1, 7);
    pass &= create(watering, start.clone(), Some("daily"), cx).await;
    let days = cx.update(|cx| titled(watering, cx));
    pass &= ok(
        "a daily event repeats on each day of the range",
        days.len() >= 10 && days.iter().all(|d| d.recurring),
    );
    if let Some(third) = days.get(2).cloned() {
        let key = third.key.clone();
        in_pane(cx, move |p, window, cx| p.open(&key, window, cx));
        let opened = wait_sheet::<EventSheet>(cx, |s| {
            s.detail
                .as_ref()
                .is_some_and(|d| d.repeat == "daily" && d.can_edit)
        })
        .await;
        pass &= ok(
            "one of its later days opens, saying it repeats daily",
            opened,
        );
        if let Some(handle) = cx.update(|cx| sheet::current_window(cx)) {
            let controls = ax(handle, "calendar-series", dir, cx).await;
            pass &= ok(
                "a repeating event offers Edit Series… and Delete Series…",
                has(&controls, "Button", "Edit Series…")
                    && has(&controls, "Button", "Delete Series…"),
            );
        }
        in_sheet::<EventSheet, _>(cx, |s, window, cx| s.edit(window, cx));
        let start_check = start.clone();
        let series = wait_sheet::<EventEditor>(cx, move |e| {
            e.editor.as_ref().is_some_and(|ed| ed.series)
                && e.fields.as_ref().is_some_and(|f| f.start == start_check)
        })
        .await;
        pass &= ok("Edit Series opens the series, from its first day", series);
        in_sheet::<EventEditor, _>(cx, |e, window, cx| {
            e.type_title("Evening watering", window, cx)
        });
        settle(cx, 300).await;
        in_sheet::<EventEditor, _>(cx, |e, window, cx| e.save(window, cx));
        let _ = wait_closed(cx).await;
        let count = days.len();
        let renamed = wait_until(cx, Duration::from_secs(20), move |cx| {
            titled(watering, cx).is_empty() && titled("Evening watering", cx).len() == count
        })
        .await;
        pass &= ok("every day of the series is renamed", renamed);
        shoot_main(dir, "calendar-series", cx).await;
    }

    // ── Hide a calendar, show it again ────────────────────────────────
    let own = cx.update(|cx| {
        agenda(cx).and_then(|a| a.calendars.into_iter().find(|c| c.owned && c.is_default))
    });
    if let Some(own) = own {
        let id = own.id.clone();
        cx.update(|cx| {
            let calendar = cx.global::<AppState>().stores.calendar.clone();
            calendar.update(cx, |c, cx| c.set_visible(&id, false, cx));
        });
        let hidden = wait_until(cx, Duration::from_secs(15), |cx| {
            titled("Evening watering", cx).is_empty()
                && agenda(cx).is_some_and(|a| a.calendars.iter().any(|c| !c.visible))
        })
        .await;
        pass &= ok("a calendar hidden takes its events with it", hidden);
        shoot_main(dir, "calendar-hidden", cx).await;
        let id = own.id.clone();
        cx.update(|cx| {
            let calendar = cx.global::<AppState>().stores.calendar.clone();
            calendar.update(cx, |c, cx| c.set_visible(&id, true, cx));
        });
        let shown = wait_until(cx, Duration::from_secs(15), |cx| {
            !titled("Evening watering", cx).is_empty()
                && agenda(cx).is_some_and(|a| a.calendars.iter().all(|c| c.visible))
        })
        .await;
        pass &= ok("shown again, its events come back", shown);
    }

    // ── The range moves a page and comes back ─────────────────────────
    in_pane(cx, |p, _, cx| p.next(cx));
    let later = wait_until(cx, Duration::from_secs(15), |cx| {
        agenda(cx).is_some_and(|a| a.first_day != a.today)
    })
    .await;
    pass &= ok("› moves the agenda to the next two weeks", later);
    in_pane(cx, |p, _, cx| p.today(cx));
    let back = wait_until(cx, Duration::from_secs(15), |cx| {
        agenda(cx).is_some_and(|a| a.first_day.is_some() && a.first_day == a.today)
    })
    .await;
    pass &= ok("Today comes back", back);

    // ── A new calendar, made the default ──────────────────────────────
    in_pane(cx, |p, window, cx| p.new_calendar(window, cx));
    if wait_sheet::<NewCalendarSheet>(cx, |_| true).await {
        in_sheet::<NewCalendarSheet, _>(cx, |s, window, cx| {
            s.set_name("Trail walks", window, cx);
            s.set_color("#22c55e", cx);
        });
        settle(cx, 400).await;
        shoot_main(dir, "calendar-new-calendar", cx).await;
        if let Some(handle) = cx.update(|cx| sheet::current_window(cx)) {
            let controls = ax(handle, "calendar-new-calendar", dir, cx).await;
            pass &= ok(
                "the colours are labelled radio buttons",
                has(&controls, "RadioButton", "Green") && has(&controls, "RadioButton", "Blue"),
            );
        }
        in_sheet::<NewCalendarSheet, _>(cx, |s, window, cx| s.create(window, cx));
        pass &= ok("Create Calendar closes the sheet", wait_closed(cx).await);
        let made = wait_until(cx, Duration::from_secs(15), |cx| {
            agenda(cx).is_some_and(|a| {
                a.calendars.iter().any(|c| {
                    c.name == "Trail walks"
                        && c.owned
                        && c.writable
                        && c.color.as_deref() == Some("#22c55e")
                })
            })
        })
        .await;
        pass &= ok("the new calendar is listed, with its colour", made);
        let id = cx.update(|cx| {
            agenda(cx).and_then(|a| {
                a.calendars
                    .into_iter()
                    .find(|c| c.name == "Trail walks")
                    .map(|c| c.id)
            })
        });
        if let Some(id) = id {
            in_pane(cx, move |p, window, cx| {
                p.on_menu(
                    &CalendarMenu {
                        command: "make-default".into(),
                        id,
                    },
                    window,
                    cx,
                )
            });
            let default = wait_until(cx, Duration::from_secs(15), |cx| {
                agenda(cx).is_some_and(|a| {
                    a.calendars
                        .iter()
                        .any(|c| c.name == "Trail walks" && c.is_default)
                        && a.calendars.iter().filter(|c| c.is_default).count() == 1
                })
            })
            .await;
            pass &= ok("Make Default moves the default to it", default);
        }
    } else {
        pass &= ok("New Calendar… opens a sheet", false);
    }

    // ── Delete the events ─────────────────────────────────────────────
    if let Some(row) = cx.update(|cx| titled("Garden tool swap, moved", cx).first().cloned()) {
        let key = row.key.clone();
        in_pane(cx, move |p, window, cx| p.open(&key, window, cx));
        let _ =
            wait_sheet::<EventSheet>(cx, |s| s.detail.as_ref().is_some_and(|d| d.can_edit)).await;
        in_sheet::<EventSheet, _>(cx, |s, window, cx| s.delete(window, cx));
        let gone = wait_until(cx, Duration::from_secs(20), |cx| {
            titled("Garden tool swap, moved", cx).is_empty() && !sheet::is_open(cx)
        })
        .await;
        pass &= ok(
            "Delete… (confirmed) removes the event and closes its sheet",
            gone,
        );
    }
    if let Some(row) = cx.update(|cx| titled("Evening watering", cx).get(3).cloned()) {
        // ⌘⌫ on a chosen row, as the keyboard deletes.
        let key = row.key.clone();
        in_pane(cx, move |p, window, cx| p.delete(&key, window, cx));
        let gone = wait_until(cx, Duration::from_secs(20), |cx| {
            titled("Evening watering", cx).is_empty()
        })
        .await;
        pass &= ok("deleting one day deletes the whole series", gone);
    }
    settle(cx, 400).await;
    shoot_main(dir, "calendar-after", cx).await;
    pass
}
