//! The calendar's agenda (`calendar.*`), as the Calendar pane shows it.
//!
//! The daemon holds the agenda (core's `CalendarAgenda`): the range, the
//! calendars, which of them are shown, and the events and scheduled-task
//! runs in the range. This store only keeps its last answer. It reads it
//! when the pane is shown (again from the server, as the phone does when its
//! page reopens), on `calendar.changed`, and after a reconnect, and drops it
//! when the account changes.

use conduit_protocol::{
    CalendarAgenda, CalendarAgendaQuery, CalendarRef, CalendarVisibility, CalendarWallTime, Event,
    RpcError, events, methods,
};
use gpui_kit::{App, AsyncApp, Context, Task, WeakEntity};

use super::Stores;
use super::connection::ConnectionEvent;
use super::rpc::Rpc;

#[derive(Default)]
pub struct CalendarStore {
    rpc: Option<Rpc>,
    /// The daemon's last answer, for this account.
    pub agenda: Option<CalendarAgenda>,
    /// The first answer is on its way.
    pub loading: bool,
    /// A move to another range is on its way.
    pub paging: bool,
    /// The last call was refused; the pane words it.
    pub error: Option<RpcError>,
    /// A visibility or default change is on its way.
    pub busy: bool,
    /// The pane has been shown, so changes are followed.
    wanted: bool,
    /// Bumped per account: answers for the previous one are dropped.
    generation: u64,
    /// Bumped per agenda request: only the newest one lands.
    request: u64,
    fetch: Option<Task<()>>,
}

impl CalendarStore {
    pub fn new(rpc: Rpc) -> Self {
        Self {
            rpc: Some(rpc),
            ..Self::default()
        }
    }

    /// The pane is showing: the first time it loads, after that it reads the
    /// server again, as the phone's page does when it reopens.
    pub fn show(&mut self, cx: &mut Context<Self>) {
        self.wanted = true;
        let refresh = self.agenda.is_some();
        self.query(
            CalendarAgendaQuery {
                refresh,
                ..Default::default()
            },
            false,
            cx,
        );
    }

    /// Reads the server again for the same range (Try Again, ⌘R).
    pub fn refresh(&mut self, cx: &mut Context<Self>) {
        self.query(
            CalendarAgendaQuery {
                refresh: true,
                ..Default::default()
            },
            false,
            cx,
        );
    }

    /// Moves the range by `pages` (−1 earlier, 1 later).
    pub fn shift(&mut self, pages: i64, cx: &mut Context<Self>) {
        self.query(
            CalendarAgendaQuery {
                shift: pages,
                ..Default::default()
            },
            true,
            cx,
        );
    }

    /// Moves the range to start today.
    pub fn today(&mut self, cx: &mut Context<Self>) {
        self.query(
            CalendarAgendaQuery {
                today: true,
                ..Default::default()
            },
            true,
            cx,
        );
    }

    /// Moves the range to start on `day`.
    pub fn go_to(&mut self, day: CalendarWallTime, cx: &mut Context<Self>) {
        self.query(
            CalendarAgendaQuery {
                first_day: Some(day),
                ..Default::default()
            },
            true,
            cx,
        );
    }

    /// Whether the range starts today already.
    pub fn starts_today(&self) -> bool {
        self.agenda
            .as_ref()
            .is_some_and(|a| a.first_day.is_some() && a.first_day == a.today)
    }

    fn query(&mut self, query: CalendarAgendaQuery, paging: bool, cx: &mut Context<Self>) {
        let Some(rpc) = self.rpc.clone() else {
            return;
        };
        self.request += 1;
        let (request, generation) = (self.request, self.generation);
        self.loading = self.agenda.is_none();
        self.paging = paging;
        cx.notify();
        let call = rpc.call::<methods::CalendarAgenda>(&query);
        self.fetch = Some(
            cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
                let result = call.await;
                this.update(cx, |s, cx| {
                    if s.generation != generation || s.request != request {
                        return;
                    }
                    s.loading = false;
                    s.paging = false;
                    match result {
                        Ok(agenda) => {
                            s.agenda = Some(agenda);
                            s.error = None;
                        }
                        Err(e) => {
                            log::warn!("calendar.agenda: {e}");
                            s.error = Some(e);
                        }
                    }
                    cx.notify();
                })
                .ok();
            }),
        );
    }

    /// `calendar.changed`: the agenda as the daemon now holds it.
    fn changed(&mut self, cx: &mut Context<Self>) {
        if self.wanted && !self.paging {
            self.query(CalendarAgendaQuery::default(), false, cx);
        }
    }

    /// Which account's agenda this is: bumped when another signs in.
    pub fn generation(&self) -> u64 {
        self.generation
    }

    /// Takes an answer a change came back with.
    pub fn adopt(&mut self, agenda: CalendarAgenda, cx: &mut Context<Self>) {
        // A change answered after a newer request started still lands: it is
        // what the daemon holds now.
        self.agenda = Some(agenda);
        self.error = None;
        cx.notify();
    }

    /// Shows or hides `calendar_id`'s events.
    pub fn set_visible(&mut self, calendar_id: &str, visible: bool, cx: &mut Context<Self>) {
        let Some(rpc) = self.rpc.clone() else {
            return;
        };
        // Shown at once; the answer settles it.
        if let Some(agenda) = self.agenda.as_mut()
            && let Some(c) = agenda.calendars.iter_mut().find(|c| c.id == calendar_id)
        {
            c.visible = visible;
        }
        self.busy = true;
        cx.notify();
        let call = rpc.call::<methods::CalendarSetVisible>(&CalendarVisibility {
            calendar_id: calendar_id.to_string(),
            visible,
        });
        self.after(call, "calendar.setVisible", cx);
    }

    /// Makes `calendar_id` the account's default.
    pub fn make_default(&mut self, calendar_id: &str, cx: &mut Context<Self>) {
        let Some(rpc) = self.rpc.clone() else {
            return;
        };
        self.busy = true;
        cx.notify();
        let call = rpc.call::<methods::CalendarMakeDefault>(&CalendarRef {
            calendar_id: calendar_id.to_string(),
        });
        self.after(call, "calendar.makeDefault", cx);
    }

    fn after(
        &mut self,
        call: impl std::future::Future<Output = Result<CalendarAgenda, RpcError>> + 'static,
        name: &'static str,
        cx: &mut Context<Self>,
    ) {
        let generation = self.generation;
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result = call.await;
            this.update(cx, |s, cx| {
                if s.generation != generation {
                    return;
                }
                s.busy = false;
                match result {
                    Ok(agenda) => s.adopt(agenda, cx),
                    Err(e) => {
                        log::warn!("{name}: {e}");
                        s.error = Some(e);
                        // Undo the optimistic change.
                        s.changed(cx);
                    }
                }
                cx.notify();
            })
            .ok();
        })
        .detach();
    }

    /// Another account (or none): the agenda goes.
    pub fn reset(&mut self, cx: &mut Context<Self>) {
        self.generation += 1;
        self.agenda = None;
        self.error = None;
        self.loading = false;
        self.paging = false;
        self.busy = false;
        self.fetch = None;
        cx.notify();
        // A pane still showing reads the new account's agenda.
        if self.wanted {
            self.query(CalendarAgendaQuery::default(), false, cx);
        }
    }
}

/// Follows the daemon's events and the account for `stores.calendar`.
pub fn wire(stores: &Stores, cx: &mut App) {
    stores.connection.update(cx, |c, _| {
        c.subscribe("calendar", &[events::CALENDAR_CHANGED], vec![])
    });
    {
        let s = stores.clone();
        cx.subscribe(&stores.connection, move |_, event, cx| match event {
            ConnectionEvent::Connected { .. } | ConnectionEvent::Gap => {
                s.calendar.update(cx, |c, cx| {
                    if c.wanted {
                        c.refresh(cx);
                    }
                });
            }
            ConnectionEvent::Daemon(event) if matches!(event.as_ref(), Event::CalendarChanged) => {
                s.calendar.update(cx, |c, cx| c.changed(cx));
            }
            _ => {}
        })
        .detach();
    }
    let last: std::rc::Rc<std::cell::RefCell<Option<Option<String>>>> = Default::default();
    let s = stores.clone();
    cx.observe(&stores.accounts, move |accounts, cx| {
        let account = accounts
            .read(cx)
            .list
            .as_ref()
            .and_then(|l| l.active_account_id.clone());
        let changed = last
            .borrow()
            .as_ref()
            .is_some_and(|before| *before != account);
        *last.borrow_mut() = Some(account);
        if changed {
            s.calendar.update(cx, |c, cx| c.reset(cx));
        }
    })
    .detach();
}

#[cfg(test)]
mod tests {
    use conduit_protocol::{CalendarDto, CalendarWallTime};
    use gpui_kit::{AppContext as _, TestAppContext};

    use super::*;
    use crate::stores::rpc::fake::FakeDaemon;

    fn day(d: i64) -> CalendarWallTime {
        CalendarWallTime {
            year: 2026,
            month: 11,
            day: d,
            hour: 0,
            minute: 0,
        }
    }

    fn calendar(id: &str, visible: bool) -> CalendarDto {
        CalendarDto {
            id: id.into(),
            name: id.into(),
            color: None,
            is_default: false,
            scheduled: false,
            owned: true,
            writable: true,
            can_make_default: true,
            visible,
        }
    }

    #[gpui_kit::test]
    fn the_agenda_loads_then_reads_the_server_again_when_shown(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        daemon.returns::<methods::CalendarAgenda>(CalendarAgenda {
            available: true,
            first_day: Some(day(11)),
            today: Some(day(11)),
            calendars: vec![calendar("a", true), calendar("b", true)],
            ..Default::default()
        });
        let store = cx.new(|_| CalendarStore::new(daemon.rpc()));
        store.update(cx, |s, cx| s.show(cx));
        cx.run_until_parked();
        store.read_with(cx, |s, _| {
            assert!(s.agenda.is_some() && !s.loading);
            assert!(s.starts_today());
        });
        store.update(cx, |s, cx| {
            s.show(cx);
            s.shift(1, cx);
        });
        cx.run_until_parked();
        let calls = daemon.calls::<methods::CalendarAgenda>();
        assert_eq!(calls.len(), 3);
        assert_eq!(calls[0]["refresh"], false, "the first show only loads");
        assert_eq!(calls[1]["refresh"], true, "a later show reads again");
        assert_eq!(calls[2]["shift"], 1);
    }

    #[gpui_kit::test]
    fn hiding_a_calendar_shows_at_once_and_takes_the_daemons_answer(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        daemon.returns::<methods::CalendarAgenda>(CalendarAgenda {
            available: true,
            calendars: vec![calendar("a", true), calendar("b", true)],
            ..Default::default()
        });
        daemon.returns::<methods::CalendarSetVisible>(CalendarAgenda {
            available: true,
            calendars: vec![calendar("a", false), calendar("b", true)],
            filterable: true,
            ..Default::default()
        });
        let store = cx.new(|_| CalendarStore::new(daemon.rpc()));
        store.update(cx, |s, cx| s.show(cx));
        cx.run_until_parked();
        store.update(cx, |s, cx| s.set_visible("a", false, cx));
        store.read_with(cx, |s, _| {
            assert!(s.busy);
            assert!(!s.agenda.as_ref().unwrap().calendars[0].visible);
        });
        cx.run_until_parked();
        store.read_with(cx, |s, _| {
            assert!(!s.busy);
            assert!(s.agenda.as_ref().unwrap().filterable);
        });
        let calls = daemon.calls::<methods::CalendarSetVisible>();
        assert_eq!(calls[0]["calendarId"], "a");
        assert_eq!(calls[0]["visible"], false);
        // Another account: the agenda goes.
        store.update(cx, |s, cx| s.reset(cx));
        store.read_with(cx, |s, _| assert!(s.agenda.is_none()));
    }
}
