//! Hermes's administration, as the phone's Hermes settings pages hold it:
//!
//! * the switch and the saved connections (`hermes.connections.*`), read
//!   when Settings › Hermes or the sidebar's switcher needs them and again
//!   on `hermes.changed`;
//! * the connection's status (`hermes.status`), catalog (`hermes.catalog`:
//!   skills, toolsets, and the `/` commands of a Hermes chat) and MCP
//!   servers (`hermes.mcp.*`);
//! * its scheduled agents (`hermes.jobs`, `hermes.jobs.*`): polled while
//!   the Scheduled Agents pane shows them, every 2 s while a run is going
//!   or being stopped and every 15 s otherwise (the phone's page's pace),
//!   so a run the scheduler or another app starts shows up with its Stop.
//!
//! Actions answer with the new list, and a failure is a toast.

use std::collections::{HashMap, HashSet};
use std::time::Duration;

use conduit_daemon::RpcError;
use conduit_protocol::{
    Event, HermesCatalog, HermesConnections, HermesJobNotice, HermesJobRef, HermesJobs,
    HermesMcpServers, HermesRef, HermesSessionDto, HermesStatus, HermesToggle, NoParams,
    NoticeLevel, events, methods,
};
use gpui_kit::{App, AsyncApp, Context, Task, WeakEntity};

use crate::l10n::{ActiveL10n as _, L10n};
use crate::stores::Stores;
use crate::stores::connection::ConnectionEvent;
use crate::stores::rpc::Rpc;

/// How often the jobs are read while a run is going or being stopped: a
/// Stop lands at the run's next check, about a second after it is asked.
pub const LIVE_POLL: Duration = Duration::from_secs(2);
/// How often an idle list is read, so a run started elsewhere shows up.
pub const IDLE_POLL: Duration = Duration::from_secs(15);

/// The connection a sheet or question was opened under.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Opened {
    active_id: Option<String>,
    /// The daemon's name for it, sent with the request.
    pub connection: Option<String>,
}

/// Something read from the daemon: not yet, read, or refused.
#[derive(Clone, Debug, PartialEq)]
pub enum Loaded<T> {
    Loading,
    Ready(T),
    Failed(String),
}

impl<T> Loaded<T> {
    pub fn ready(&self) -> Option<&T> {
        match self {
            Self::Ready(value) => Some(value),
            _ => None,
        }
    }
}

#[derive(Default)]
pub struct HermesAdminStore {
    rpc: Option<Rpc>,
    pub connections: Option<HermesConnections>,
    pub status: Option<Loaded<HermesStatus>>,
    pub catalog: Option<Loaded<HermesCatalog>>,
    pub mcp: Option<Loaded<HermesMcpServers>>,
    pub jobs: Option<Loaded<HermesJobs>>,
    /// Each job's run history, read when its disclosure opens.
    pub runs: HashMap<String, Loaded<Vec<HermesSessionDto>>>,
    /// The jobs whose run history is open.
    pub runs_open: HashSet<String>,
    /// Jobs with an action of the window's in flight (a toggle, Run Now,
    /// Delete): their buttons wait.
    pub busy: HashSet<String>,
    /// MCP servers with an action in flight.
    pub mcp_busy: HashSet<String>,
    /// The Scheduled Agents pane is shown: the list is polled.
    watching_jobs: bool,
    poll: Option<Task<()>>,
    poll_every: Option<Duration>,
    /// Notices the last list brought, for the window to say once.
    pending_notices: Vec<HermesJobNotice>,
    revision: u64,
    /// Moves on when another connection comes into use and on a reset: an
    /// answer to a read or action asked before is about the connection
    /// before, and is dropped.
    generation: u64,
    /// The last jobs read asked, and the newest one whose list was taken:
    /// an older poll answered late does not put its list back.
    jobs_asked: u64,
    jobs_taken: u64,
    /// The same for the connections list (reads and the actions that
    /// answer with it).
    list_asked: u64,
    list_taken: u64,
}

/// A connections-list read or action, as it was asked (its place in the
/// order they were asked in): answered only if it is newer than the last
/// list taken and than the last reset. A list that switches connections
/// does not make the ones asked after it older.
#[derive(Clone, Copy, Debug)]
pub struct ListTicket {
    list: u64,
}

impl HermesAdminStore {
    pub fn new(rpc: Rpc) -> Self {
        Self {
            rpc: Some(rpc),
            ..Self::default()
        }
    }

    pub fn revision(&self) -> u64 {
        self.revision
    }

    fn rpc(&self) -> Option<Rpc> {
        self.rpc.clone()
    }

    fn changed(&mut self, cx: &mut Context<Self>) {
        self.revision += 1;
        cx.notify();
    }

    /// The connection (and reset) a read or action is asked under: its
    /// answer is taken only while [`Self::generation`] still says the same.
    pub fn generation(&self) -> u64 {
        self.generation
    }

    /// The one check for an answer: asked under `generation`, it is taken
    /// only while no switch or reset came since.
    pub fn is_current(&self, generation: u64) -> bool {
        self.generation == generation
    }

    /// Forgets everything (another account, a reconnect): read again when
    /// asked.
    pub fn reset(&mut self, cx: &mut Context<Self>) {
        self.connections = None;
        self.status = None;
        self.catalog = None;
        self.mcp = None;
        self.jobs = None;
        self.runs.clear();
        self.runs_open.clear();
        self.busy.clear();
        self.mcp_busy.clear();
        self.pending_notices.clear();
        self.generation += 1;
        // Lists asked before the reset are not taken; those asked after are.
        self.list_taken = self.list_asked;
        self.changed(cx);
    }

    /// The connection in use as the daemon names it
    /// (`HermesChanged.connection`): sent with a request bound to it, which
    /// the daemon refuses once another is in use.
    pub fn connection(&self) -> Option<String> {
        self.connections.as_ref()?.connection.clone()
    }

    /// The connection in use now, for a sheet or question to keep.
    pub fn opened(&self) -> Opened {
        Opened {
            active_id: self.connections.as_ref().and_then(|l| l.active_id.clone()),
            connection: self.connection(),
        }
    }

    /// Whether `opened` (the connection in use when a sheet opened) is
    /// still the one in use, as far as this window knows: a sheet sends
    /// nothing once another has come into use (and the daemon refuses
    /// what this window has not heard of yet).
    pub fn still_in_use(&self, opened: &Opened) -> bool {
        self.connections.as_ref().is_none_or(|l| {
            l.active_id == opened.active_id
                && (opened.connection.is_none() || l.connection == opened.connection)
        })
    }

    /// The connection in use, if any.
    pub fn active(&self) -> Option<&conduit_protocol::HermesConnectionDto> {
        let list = self.connections.as_ref()?;
        let id = list.active_id.as_deref()?;
        list.connections.iter().find(|c| c.id == id)
    }

    // ── Connections ──────────────────────────────────────────────────

    /// Reads the switch and the saved connections.
    pub fn refresh_connections(&mut self, cx: &mut Context<Self>) {
        let Some(rpc) = self.rpc() else { return };
        let call = rpc.call::<methods::HermesConnectionsList>(&NoParams);
        let ticket = self.ask_list();
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result = call.await;
            let _ = this.update(cx, |s, cx| match result {
                Ok(list) => {
                    s.answer_list(ticket, list, cx);
                }
                Err(e) => log::info!("hermes.connections.list: {e}"),
            });
        })
        .detach();
    }

    /// A connections-list read or action about to be asked.
    pub fn ask_list(&mut self) -> ListTicket {
        self.list_asked += 1;
        ListTicket {
            list: self.list_asked,
        }
    }

    /// The list `ticket`'s read or action answered with: taken unless a
    /// reset came since or a newer one was taken. Whether it was.
    pub fn answer_list(
        &mut self,
        ticket: ListTicket,
        list: HermesConnections,
        cx: &mut Context<Self>,
    ) -> bool {
        if ticket.list <= self.list_taken {
            return false;
        }
        self.list_taken = ticket.list;
        self.take_list(list, cx);
        true
    }

    /// A list that answered just now (newer than any read still out).
    pub fn adopt_connections(&mut self, list: HermesConnections, cx: &mut Context<Self>) {
        let ticket = self.ask_list();
        self.answer_list(ticket, list, cx);
    }

    fn take_list(&mut self, list: HermesConnections, cx: &mut Context<Self>) {
        // Another connection, Hermes turned off or on, or the one in use
        // changed under the same name (another address, other credentials:
        // the daemon names it anew).
        let switched = self.connections.as_ref().map(|l| l.active_id.clone())
            != Some(list.active_id.clone())
            || self.connections.as_ref().map(|l| l.enabled) != Some(list.enabled)
            || self
                .connections
                .as_ref()
                .is_some_and(|l| l.connection.is_some() && l.connection != list.connection);
        self.connections = Some(list);
        if switched {
            // Another connection's status, catalog, servers and jobs.
            self.status = None;
            self.catalog = None;
            self.mcp = None;
            self.jobs = None;
            self.runs.clear();
            self.runs_open.clear();
            self.pending_notices.clear();
            self.busy.clear();
            self.mcp_busy.clear();
            self.generation += 1;
            if self.watching_jobs {
                self.refresh_jobs(cx);
            }
        }
        self.changed(cx);
    }

    // ── Status, catalog ──────────────────────────────────────────────

    pub fn refresh_status(&mut self, cx: &mut Context<Self>) {
        let Some(rpc) = self.rpc() else { return };
        if self.status.is_none() {
            self.status = Some(Loaded::Loading);
        }
        let call = rpc.call::<methods::HermesStatus>(&NoParams);
        let generation = self.generation;
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result = call.await;
            let _ = this.update(cx, |s, cx| {
                if !s.is_current(generation) {
                    return;
                }
                s.status = Some(match result {
                    Ok(status) => Loaded::Ready(status),
                    Err(e) => Loaded::Failed(e.to_string()),
                });
                s.changed(cx);
            });
        })
        .detach();
    }

    pub fn refresh_catalog(&mut self, cx: &mut Context<Self>) {
        let Some(rpc) = self.rpc() else { return };
        if self.catalog.is_none() {
            self.catalog = Some(Loaded::Loading);
        }
        let call = rpc.call::<methods::HermesCatalog>(&NoParams);
        let generation = self.generation;
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result = call.await;
            let _ = this.update(cx, |s, cx| {
                if !s.is_current(generation) {
                    return;
                }
                s.catalog = Some(match result {
                    Ok(catalog) => Loaded::Ready(catalog),
                    Err(e) => Loaded::Failed(e.to_string()),
                });
                s.changed(cx);
            });
        })
        .detach();
    }

    // ── MCP servers ──────────────────────────────────────────────────

    pub fn refresh_mcp(&mut self, cx: &mut Context<Self>) {
        let Some(rpc) = self.rpc() else { return };
        if self.mcp.is_none() {
            self.mcp = Some(Loaded::Loading);
        }
        let call = rpc.call::<methods::HermesMcpList>(&NoParams);
        let generation = self.generation;
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result = call.await;
            let _ = this.update(cx, |s, cx| {
                if !s.is_current(generation) {
                    return;
                }
                s.mcp = Some(match result {
                    Ok(servers) => Loaded::Ready(servers),
                    Err(e) => Loaded::Failed(e.to_string()),
                });
                s.changed(cx);
            });
        })
        .detach();
    }

    /// The servers an action answered with.
    pub fn adopt_mcp(&mut self, servers: HermesMcpServers, cx: &mut Context<Self>) {
        self.mcp = Some(Loaded::Ready(servers));
        self.changed(cx);
    }

    pub fn set_mcp_busy(&mut self, name: &str, busy: bool, cx: &mut Context<Self>) {
        if busy {
            self.mcp_busy.insert(name.to_string());
        } else {
            self.mcp_busy.remove(name);
        }
        self.changed(cx);
    }

    // ── Scheduled agents ─────────────────────────────────────────────

    /// The Scheduled Agents pane opened or closed: the list is read now and
    /// polled while it shows.
    pub fn watch_jobs(&mut self, watching: bool, cx: &mut Context<Self>) {
        if self.watching_jobs == watching {
            return;
        }
        self.watching_jobs = watching;
        if watching {
            self.refresh_jobs(cx);
        } else {
            self.poll = None;
            self.poll_every = None;
        }
    }

    pub fn watching_jobs(&self) -> bool {
        self.watching_jobs
    }

    pub fn refresh_jobs(&mut self, cx: &mut Context<Self>) {
        let Some(rpc) = self.rpc() else { return };
        if self.jobs.is_none() {
            self.jobs = Some(Loaded::Loading);
            self.changed(cx);
        }
        let call = rpc.call::<methods::HermesJobs>(&NoParams);
        let generation = self.generation;
        self.jobs_asked += 1;
        let asked = self.jobs_asked;
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result = call.await;
            let _ = this.update(cx, |s, cx| match result {
                _ if !s.is_current(generation) => {}
                Ok(jobs) if asked <= s.jobs_taken => {
                    // A newer list is shown: only what this one says once.
                    s.pending_notices.extend(jobs.notices);
                    s.changed(cx);
                }
                Ok(jobs) => s.take_jobs(asked, jobs, cx),
                Err(_) if asked <= s.jobs_taken => {}
                Err(e) => {
                    // A failed poll keeps the list shown; a first read says so.
                    if !matches!(s.jobs, Some(Loaded::Ready(_))) {
                        s.jobs = Some(Loaded::Failed(e.to_string()));
                    }
                    s.changed(cx);
                    s.sync_poll(cx);
                }
            });
        })
        .detach();
    }

    /// The jobs an action answered with: newer than any read still out.
    pub fn adopt_jobs(&mut self, jobs: HermesJobs, cx: &mut Context<Self>) {
        self.jobs_asked += 1;
        self.take_jobs(self.jobs_asked, jobs, cx);
    }

    /// The jobs read `asked` (or an action) answered with.
    fn take_jobs(&mut self, asked: u64, jobs: HermesJobs, cx: &mut Context<Self>) {
        self.jobs_taken = asked;
        // A run that ended has its final title in the history.
        let was_running: HashSet<String> = self
            .jobs
            .as_ref()
            .and_then(Loaded::ready)
            .map(|j| {
                j.jobs
                    .iter()
                    .filter(|j| j.running)
                    .map(|j| j.id.clone())
                    .collect()
            })
            .unwrap_or_default();
        let ended: Vec<String> = jobs
            .jobs
            .iter()
            .filter(|j| !j.running && was_running.contains(&j.id))
            .map(|j| j.id.clone())
            .collect();
        self.pending_notices.extend(jobs.notices.iter().cloned());
        self.jobs = Some(Loaded::Ready(jobs));
        for id in ended {
            if self.runs_open.contains(&id) {
                self.load_runs(&id, cx);
            } else {
                self.runs.remove(&id);
            }
        }
        self.changed(cx);
        self.sync_poll(cx);
    }

    /// The notices the window has not said yet.
    pub fn take_notices(&mut self) -> Vec<HermesJobNotice> {
        std::mem::take(&mut self.pending_notices)
    }

    /// Polls quickly while a run is going or being stopped, slowly
    /// otherwise, and not at all while the pane is not shown.
    fn sync_poll(&mut self, cx: &mut Context<Self>) {
        if !self.watching_jobs {
            self.poll = None;
            self.poll_every = None;
            return;
        }
        let live = self
            .jobs
            .as_ref()
            .and_then(Loaded::ready)
            .is_some_and(|j| j.jobs.iter().any(|j| j.running || j.stopping));
        let every = if live { LIVE_POLL } else { IDLE_POLL };
        if self.poll.is_some() && self.poll_every == Some(every) {
            return;
        }
        self.poll_every = Some(every);
        self.poll = Some(
            cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
                loop {
                    cx.background_executor().timer(every).await;
                    let go_on = this
                        .update(cx, |s, cx| {
                            if !s.watching_jobs || s.poll_every != Some(every) {
                                return false;
                            }
                            s.refresh_jobs(cx);
                            true
                        })
                        .unwrap_or(false);
                    if !go_on {
                        break;
                    }
                }
            }),
        );
    }

    pub fn set_busy(&mut self, id: &str, busy: bool, cx: &mut Context<Self>) {
        if busy {
            self.busy.insert(id.to_string());
        } else {
            self.busy.remove(id);
        }
        self.changed(cx);
    }

    /// Opens or closes job `id`'s run history (read when it opens).
    pub fn toggle_runs(&mut self, id: &str, cx: &mut Context<Self>) {
        if self.runs_open.remove(id) {
            self.changed(cx);
            return;
        }
        self.runs_open.insert(id.to_string());
        self.load_runs(id, cx);
        self.changed(cx);
    }

    pub fn load_runs(&mut self, id: &str, cx: &mut Context<Self>) {
        let Some(rpc) = self.rpc() else { return };
        if !self.runs.contains_key(id) {
            self.runs.insert(id.to_string(), Loaded::Loading);
        }
        let call = rpc.call::<methods::HermesJobsRuns>(&HermesJobRef {
            id: id.to_string(),
            connection: self.connection(),
        });
        let id = id.to_string();
        let generation = self.generation;
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result = call.await;
            let _ = this.update(cx, |s, cx| {
                if !s.is_current(generation) {
                    return;
                }
                s.runs.insert(
                    id,
                    match result {
                        Ok(runs) => Loaded::Ready(runs.sessions),
                        Err(e) => Loaded::Failed(e.to_string()),
                    },
                );
                s.changed(cx);
            });
        })
        .detach();
    }
}

/// What a notice says, as the phone's page words it.
pub fn notice_text(kind: &str, l: &L10n) -> Option<(NoticeLevel, String)> {
    Some(match kind {
        "stopped" => (NoticeLevel::Success, l.hermes_job_stopped()),
        "finishedBeforeStop" => (NoticeLevel::Info, l.hermes_job_finished_before_stop()),
        "nothingToStop" => (NoticeLevel::Info, l.hermes_job_nothing_to_stop()),
        "stopUnsupported" => (NoticeLevel::Warning, l.hermes_job_stop_unsupported()),
        "stopFailed" => (NoticeLevel::Error, l.hermes_job_stop_failed()),
        "runFailed" => (NoticeLevel::Error, l.hermes_job_run_failed()),
        _ => return None,
    })
}

/// The toast for a refused admin call: the phone's failure line for it.
pub fn toast_failure(stores: &Stores, message: String, cx: &mut App) {
    stores
        .toasts
        .update(cx, |t, cx| t.show(NoticeLevel::Error, message, cx));
}

/// Follows the daemon for `stores.hermes_admin`: a Hermes change reads the
/// connections again (and the jobs, while shown); a reconnect forgets.
pub fn wire(stores: &Stores, cx: &mut App) {
    stores.connection.update(cx, |c, _| {
        c.subscribe("hermes-admin", &[events::HERMES_CHANGED], vec![])
    });
    let s = stores.clone();
    cx.subscribe(&stores.connection, move |_, event, cx| match event {
        ConnectionEvent::Connected { .. } | ConnectionEvent::Gap => {
            s.hermes_admin.update(cx, |a, cx| {
                a.reset(cx);
                a.refresh_connections(cx);
                if a.watching_jobs {
                    a.refresh_jobs(cx);
                }
            });
        }
        ConnectionEvent::Daemon(event) => {
            if matches!(event.as_ref(), Event::HermesChanged(_)) {
                s.hermes_admin.update(cx, |a, cx| {
                    a.refresh_connections(cx);
                    if matches!(a.mcp, Some(Loaded::Ready(_))) {
                        a.refresh_mcp(cx);
                    }
                    if a.watching_jobs {
                        a.refresh_jobs(cx);
                    }
                });
            }
        }
        _ => {}
    })
    .detach();
    // Toasts for what the jobs' notices say, whichever read brought them.
    let s = stores.clone();
    cx.observe(&stores.hermes_admin, move |admin, cx| {
        let notices = admin.update(cx, |a, _| a.take_notices());
        if notices.is_empty() {
            return;
        }
        let l = cx.l10n().clone();
        for notice in notices {
            if let Some((level, text)) = notice_text(&notice.kind, &l) {
                s.toasts.update(cx, |t, cx| t.show(level, text, cx));
            }
        }
    })
    .detach();
}

/// Calls `call`, an action on the connection in use, and hands its answer
/// to `done` on the store, unless another connection came into use (or the
/// store was reset) meanwhile; a refusal is a toast with `failure`.
pub fn act<T: Send + 'static>(
    stores: &Stores,
    call: impl std::future::Future<Output = Result<T, RpcError>> + Send + 'static,
    failure: String,
    done: impl FnOnce(&mut HermesAdminStore, T, &mut Context<HermesAdminStore>) + 'static,
    cx: &mut App,
) {
    let generation = stores.hermes_admin.read(cx).generation;
    answer(
        stores,
        call,
        failure,
        move |a, value, cx| {
            if a.is_current(generation) {
                done(a, value, cx);
            }
        },
        cx,
    );
}

/// [`act`] for an action on the saved connections themselves, which
/// answers with their list: `done` gets the action's [`ListTicket`] for
/// [`HermesAdminStore::answer_list`], so an answer older than a list taken
/// since (or from before a reset) is not taken.
pub fn act_on_list<T: Send + 'static>(
    stores: &Stores,
    call: impl std::future::Future<Output = Result<T, RpcError>> + Send + 'static,
    failure: String,
    done: impl FnOnce(&mut HermesAdminStore, T, ListTicket, &mut Context<HermesAdminStore>) + 'static,
    cx: &mut App,
) {
    let ticket = stores.hermes_admin.update(cx, |a, _| a.ask_list());
    answer(
        stores,
        call,
        failure,
        move |a, value, cx| done(a, value, ticket, cx),
        cx,
    );
}

/// Hands `call`'s answer to `done` on the store, or says `failure`.
fn answer<T: Send + 'static>(
    stores: &Stores,
    call: impl std::future::Future<Output = Result<T, RpcError>> + Send + 'static,
    failure: String,
    done: impl FnOnce(&mut HermesAdminStore, T, &mut Context<HermesAdminStore>) + 'static,
    cx: &mut App,
) {
    let admin = stores.hermes_admin.downgrade();
    let toasts = stores.toasts.downgrade();
    cx.spawn(async move |cx: &mut AsyncApp| {
        let result = call.await;
        match result {
            Ok(value) => {
                let _ = admin.update(cx, |a, cx| done(a, value, cx));
            }
            Err(e) => {
                log::info!("hermes admin: {e}");
                let _ = toasts.update(cx, |t, cx| t.show(NoticeLevel::Error, failure, cx));
            }
        }
    })
    .detach();
}

/// Turns Hermes on or off. Off, a Hermes chat or page left open makes way
/// for a new chat, as its section goes.
pub fn set_enabled(stores: &Stores, enabled: bool, cx: &mut App) {
    let rpc = stores.connection.read(cx).rpc();
    let call = rpc.call::<methods::HermesConnectionsSetEnabled>(&HermesToggle { enabled });
    let failure = cx.l10n().hermes_action_failed();
    let navigation = stores.navigation.downgrade();
    act_on_list(
        stores,
        call,
        failure,
        move |a, list, ticket, cx| {
            a.answer_list(ticket, list, cx);
            if !enabled {
                leave_hermes(&navigation, cx);
            }
        },
        cx,
    );
}

/// Opens a new chat when the main window shows something of Hermes's (a
/// session, Hidden Chats, Scheduled Agents) that is no longer there.
fn leave_hermes(navigation: &WeakEntity<crate::stores::navigation::NavigationStore>, cx: &mut App) {
    let _ = navigation.update(cx, |n, cx| {
        if let crate::stores::navigation::Selection::Area(item) = n.selection()
            && item.area() == crate::stores::navigation::Area::Hermes
        {
            n.new_chat(false, cx);
        }
    });
}

/// Puts connection `id` in use: Hermes's sessions follow. A Hermes chat of
/// the connection left behind cannot stay open: a new chat takes its place.
pub fn activate(stores: &Stores, id: &str, cx: &mut App) {
    let rpc = stores.connection.read(cx).rpc();
    let call = rpc.call::<methods::HermesConnectionsActivate>(&HermesRef { id: id.to_string() });
    let failure = cx.l10n().hermes_switch_connection_failed();
    let navigation = stores.navigation.downgrade();
    act_on_list(
        stores,
        call,
        failure,
        move |a, list, ticket, cx| {
            a.answer_list(ticket, list, cx);
            let _ = navigation.update(cx, |n, cx| {
                if matches!(
                    n.selection(),
                    crate::stores::navigation::Selection::Area(
                        crate::stores::navigation::AreaItem::HermesSession(_)
                    )
                ) {
                    n.new_chat(false, cx);
                }
            });
        },
        cx,
    );
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;
    use std::sync::atomic::{AtomicUsize, Ordering};

    use gpui_kit::{AppContext as _, TestAppContext};
    use serde_json::json;

    use super::*;
    use crate::stores::rpc::fake::FakeDaemon;

    fn list(active: &str) -> HermesConnections {
        serde_json::from_value(json!({
            "enabled": true,
            "activeId": active,
            "connections": [
                {"id": "a", "name": "Potting shed", "baseUrl": "http://127.0.0.1:20401",
                 "mode": "desktop", "active": active == "a"},
                {"id": "b", "name": "Greenhouse", "baseUrl": "http://127.0.0.1:20402",
                 "mode": "desktop", "active": active == "b"},
            ],
        }))
        .unwrap()
    }

    fn servers(name: &str) -> HermesMcpServers {
        serde_json::from_value(json!({
            "available": true,
            "servers": [{"name": name, "enabled": true}],
        }))
        .unwrap()
    }

    fn jobs(name: &str, notice: Option<&str>) -> HermesJobs {
        let notices: Vec<_> = notice
            .map(|kind| json!({"jobId": "j1", "kind": kind}))
            .into_iter()
            .collect();
        serde_json::from_value(json!({
            "jobs": [{"id": "j1", "name": name, "prompt": "Water the seedlings", "schedule": "0 9 * * *"}],
            "notices": notices,
        }))
        .unwrap()
    }

    /// Reads still out when another connection comes into use answer for
    /// the connection before it: none of them lands under the new one.
    #[gpui_kit::test]
    fn reads_from_the_connection_before_a_switch_are_dropped(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        daemon.returns::<methods::HermesMcpList>(servers("seed-catalogue"));
        daemon.returns::<methods::HermesStatus>(
            serde_json::from_value(json!({"configured": true, "reachable": true})).unwrap(),
        );
        daemon.returns::<methods::HermesCatalog>(serde_json::from_value(json!({})).unwrap());
        daemon.returns::<methods::HermesJobs>(jobs("Morning watering", None));
        daemon.returns::<methods::HermesJobsRuns>(
            serde_json::from_value(json!({"sessions": []})).unwrap(),
        );
        let held = [
            daemon.hold::<methods::HermesMcpList>(),
            daemon.hold::<methods::HermesStatus>(),
            daemon.hold::<methods::HermesCatalog>(),
            daemon.hold::<methods::HermesJobs>(),
            daemon.hold::<methods::HermesJobsRuns>(),
        ];
        let store = cx.new(|_| HermesAdminStore::new(daemon.rpc()));
        store.update(cx, |s, cx| {
            s.adopt_connections(list("a"), cx);
            s.refresh_mcp(cx);
            s.refresh_status(cx);
            s.refresh_catalog(cx);
            s.refresh_jobs(cx);
            s.load_runs("j1", cx);
            s.adopt_connections(list("b"), cx);
        });
        drop(held);
        cx.run_until_parked();
        store.read_with(cx, |s, _| {
            assert_eq!(s.mcp, None, "the last connection's servers landed");
            assert_eq!(s.status, None, "the last connection's status landed");
            assert_eq!(s.catalog, None, "the last connection's catalog landed");
            assert_eq!(s.jobs, None, "the last connection's jobs landed");
            assert!(
                s.runs.is_empty(),
                "the last connection's run history landed"
            );
        });
    }

    /// The connection in use named anew by the daemon (another address,
    /// other credentials, under the same saved connection) is another one:
    /// what was read of it before is not kept.
    #[gpui_kit::test]
    fn a_connection_named_anew_is_another(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        daemon.returns::<methods::HermesMcpList>(servers("seed-catalogue"));
        let held = daemon.hold::<methods::HermesMcpList>();
        let named = |key: &str| {
            let mut l = list("a");
            l.connection = Some(key.to_string());
            l
        };
        let store = cx.new(|_| HermesAdminStore::new(daemon.rpc()));
        store.update(cx, |s, cx| {
            s.adopt_connections(named("0a1b2c3d:1"), cx);
            s.refresh_mcp(cx);
            s.adopt_connections(named("0a1b2c3d:2"), cx);
        });
        drop(held);
        cx.run_until_parked();
        store.read_with(cx, |s, _| {
            assert_eq!(s.mcp, None, "the connection before's servers landed");
            assert_eq!(s.connection().as_deref(), Some("0a1b2c3d:2"));
        });
    }

    /// A list read answered after a newer one, or after a reset, is not
    /// taken: the window never goes back to a connection the daemon left.
    #[gpui_kit::test]
    fn an_older_list_read_is_never_taken(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        let n = Arc::new(AtomicUsize::new(0));
        let count = n.clone();
        daemon.on::<methods::HermesConnectionsList>(move |_| {
            let first = count.fetch_add(1, Ordering::SeqCst) == 0;
            Ok(serde_json::to_value(list(if first { "a" } else { "b" })).unwrap())
        });
        let older = daemon.hold_one::<methods::HermesConnectionsList>(0);
        let store = cx.new(|_| HermesAdminStore::new(daemon.rpc()));
        store.update(cx, |s, cx| {
            s.refresh_connections(cx);
            s.refresh_connections(cx);
        });
        cx.run_until_parked();
        drop(older);
        cx.run_until_parked();
        store.read_with(cx, |s, _| {
            assert_eq!(
                s.connections.as_ref().and_then(|l| l.active_id.as_deref()),
                Some("b"),
                "the older list came back"
            )
        });
        // Asked before a reset: dropped.
        let held = daemon.hold::<methods::HermesConnectionsList>();
        store.update(cx, |s, cx| {
            s.refresh_connections(cx);
            s.reset(cx);
        });
        drop(held);
        cx.run_until_parked();
        store.read_with(cx, |s, _| {
            assert!(
                s.connections.is_none(),
                "a list asked before the reset was taken"
            )
        });
    }

    /// A list that switches connections does not throw away a newer list
    /// asked before it came: with two reads out across a switch, the newer
    /// one is what the window shows.
    #[gpui_kit::test]
    fn the_newest_list_wins_across_a_switch(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        let n = Arc::new(AtomicUsize::new(0));
        let count = n.clone();
        daemon.on::<methods::HermesConnectionsList>(move |_| {
            // The first read sees B in use; by the second, A is back.
            let first = count.fetch_add(1, Ordering::SeqCst) == 0;
            Ok(serde_json::to_value(list(if first { "b" } else { "a" })).unwrap())
        });
        let store = cx.new(|_| HermesAdminStore::new(daemon.rpc()));
        store.update(cx, |s, cx| s.adopt_connections(list("a"), cx));
        let held = daemon.hold::<methods::HermesConnectionsList>();
        store.update(cx, |s, cx| {
            s.refresh_connections(cx);
            s.refresh_connections(cx);
        });
        cx.run_until_parked();
        held.release_one();
        cx.run_until_parked();
        store.read_with(cx, |s, _| {
            assert_eq!(
                s.connections.as_ref().and_then(|l| l.active_id.as_deref()),
                Some("b")
            )
        });
        drop(held);
        cx.run_until_parked();
        store.read_with(cx, |s, _| {
            assert_eq!(
                s.connections.as_ref().and_then(|l| l.active_id.as_deref()),
                Some("a"),
                "the newer list was thrown away by the switch before it"
            )
        });
    }

    /// Another connection in use leaves no job or server of the last one
    /// marked busy.
    #[gpui_kit::test]
    fn a_switch_clears_busy_marks(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        let store = cx.new(|_| HermesAdminStore::new(daemon.rpc()));
        store.update(cx, |s, cx| {
            s.adopt_connections(list("a"), cx);
            s.set_busy("j1", true, cx);
            s.set_mcp_busy("seed-catalogue", true, cx);
            s.adopt_connections(list("b"), cx);
        });
        store.read_with(cx, |s, _| {
            assert!(s.busy.is_empty(), "a job of the last connection stays busy");
            assert!(
                s.mcp_busy.is_empty(),
                "a server of the last connection stays busy"
            );
        });
    }

    /// An action's answer that comes back after a switch is not taken as
    /// the new connection's either.
    #[gpui_kit::test]
    fn an_action_answered_after_a_switch_is_dropped(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        daemon.returns::<methods::HermesMcpSetEnabled>(servers("seed-catalogue"));
        let held = daemon.hold::<methods::HermesMcpSetEnabled>();
        let stores = cx.update(|cx| {
            crate::views::test_globals(cx);
            let scratch =
                std::env::temp_dir().join(format!("conduit-hadmin-{}", std::process::id()));
            Stores::for_test(daemon.rpc(), &scratch, cx)
        });
        stores
            .hermes_admin
            .update(cx, |a, cx| a.adopt_connections(list("a"), cx));
        cx.update(|cx| {
            let call = stores
                .connection
                .read(cx)
                .rpc()
                .call::<methods::HermesMcpSetEnabled>(&conduit_protocol::HermesMcpToggle {
                    name: "seed-catalogue".into(),
                    enabled: false,
                    connection: None,
                });
            act(
                &stores,
                call,
                "failed".into(),
                |a, servers, cx| a.adopt_mcp(servers, cx),
                cx,
            );
        });
        stores
            .hermes_admin
            .update(cx, |a, cx| a.adopt_connections(list("b"), cx));
        drop(held);
        cx.run_until_parked();
        stores.hermes_admin.read_with(cx, |a, _| {
            assert_eq!(a.mcp, None, "the last connection's servers landed")
        });
    }

    /// A reset (a reconnect, another account) forgets the notices not said
    /// yet and the open run histories, and its reads still out are dropped.
    #[gpui_kit::test]
    fn a_reset_forgets_notices_open_histories_and_reads_out(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        daemon.returns::<methods::HermesStatus>(
            serde_json::from_value(json!({"configured": true, "reachable": true})).unwrap(),
        );
        daemon.returns::<methods::HermesJobsRuns>(
            serde_json::from_value(json!({"sessions": []})).unwrap(),
        );
        let store = cx.new(|_| HermesAdminStore::new(daemon.rpc()));
        store.update(cx, |s, cx| {
            s.adopt_connections(list("a"), cx);
            s.adopt_jobs(jobs("Morning watering", Some("stopped")), cx);
            s.toggle_runs("j1", cx);
        });
        cx.run_until_parked();
        let held = daemon.hold::<methods::HermesStatus>();
        store.update(cx, |s, cx| {
            s.refresh_status(cx);
            s.reset(cx);
        });
        drop(held);
        cx.run_until_parked();
        store.update(cx, |s, _| {
            assert!(
                s.take_notices().is_empty(),
                "a notice from before the reset is left"
            );
            assert!(
                s.runs_open.is_empty(),
                "a run history from before the reset is open"
            );
            assert_eq!(s.status, None, "a status read before the reset landed");
        });
    }

    /// A poll answered after a newer one does not put its older list back,
    /// though what it says once (its notices) is still said.
    #[gpui_kit::test]
    fn an_older_poll_does_not_replace_a_newer_list(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        let n = Arc::new(AtomicUsize::new(0));
        let count = n.clone();
        daemon.on::<methods::HermesJobs>(move |_| {
            let older = count.fetch_add(1, Ordering::SeqCst) == 0;
            Ok(serde_json::to_value(if older {
                jobs("Older list", Some("runFailed"))
            } else {
                jobs("Newer list", None)
            })
            .unwrap())
        });
        let first = daemon.hold_one::<methods::HermesJobs>(0);
        let store = cx.new(|_| HermesAdminStore::new(daemon.rpc()));
        store.update(cx, |s, cx| {
            s.adopt_connections(list("a"), cx);
            s.refresh_jobs(cx);
            s.refresh_jobs(cx);
        });
        cx.run_until_parked();
        drop(first);
        cx.run_until_parked();
        store.update(cx, |s, _| {
            let name = s
                .jobs
                .as_ref()
                .and_then(Loaded::ready)
                .and_then(|j| j.jobs[0].name.clone());
            assert_eq!(
                name.as_deref(),
                Some("Newer list"),
                "the older poll's list came back"
            );
            let notices: Vec<String> = s.take_notices().into_iter().map(|n| n.kind).collect();
            assert_eq!(
                notices,
                vec!["runFailed".to_string()],
                "the older poll's notice was lost"
            );
        });
    }
}
