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
    Event, HermesCatalog, HermesConnections, HermesJobNotice, HermesJobs, HermesMcpServers,
    HermesRef, HermesSessionDto, HermesStatus, HermesToggle, NoParams, NoticeLevel, events,
    methods,
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

    /// Forgets everything (another account, a reconnect): read again when
    /// asked.
    pub fn reset(&mut self, cx: &mut Context<Self>) {
        self.connections = None;
        self.status = None;
        self.catalog = None;
        self.mcp = None;
        self.jobs = None;
        self.runs.clear();
        self.busy.clear();
        self.mcp_busy.clear();
        self.changed(cx);
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
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result = call.await;
            let _ = this.update(cx, |s, cx| match result {
                Ok(list) => s.adopt_connections(list, cx),
                Err(e) => log::info!("hermes.connections.list: {e}"),
            });
        })
        .detach();
    }

    /// The list an action answered with.
    pub fn adopt_connections(&mut self, list: HermesConnections, cx: &mut Context<Self>) {
        let switched = self.connections.as_ref().map(|l| l.active_id.clone())
            != Some(list.active_id.clone())
            || self.connections.as_ref().map(|l| l.enabled) != Some(list.enabled);
        self.connections = Some(list);
        if switched {
            // Another connection's status, catalog, servers and jobs.
            self.status = None;
            self.catalog = None;
            self.mcp = None;
            self.jobs = None;
            self.runs.clear();
            self.runs_open.clear();
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
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result = call.await;
            let _ = this.update(cx, |s, cx| {
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
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result = call.await;
            let _ = this.update(cx, |s, cx| {
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
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result = call.await;
            let _ = this.update(cx, |s, cx| {
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
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result = call.await;
            let _ = this.update(cx, |s, cx| match result {
                Ok(jobs) => s.adopt_jobs(jobs, cx),
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

    /// The jobs a read or an action answered with.
    pub fn adopt_jobs(&mut self, jobs: HermesJobs, cx: &mut Context<Self>) {
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
        let call = rpc.call::<methods::HermesJobsRuns>(&HermesRef { id: id.to_string() });
        let id = id.to_string();
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result = call.await;
            let _ = this.update(cx, |s, cx| {
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
            if matches!(event.as_ref(), Event::HermesChanged) {
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

/// Calls `call` and hands its answer to `done` on the store; a refusal is
/// a toast with `failure`.
pub fn act<T: Send + 'static>(
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
    act(
        stores,
        call,
        failure,
        move |a, list, cx| {
            a.adopt_connections(list, cx);
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
    act(
        stores,
        call,
        failure,
        move |a, list, cx| {
            a.adopt_connections(list, cx);
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
