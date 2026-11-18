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
//!
//! When another connection goes in use, or Hermes is turned off, the store
//! says so once ([`HermesAdminEvent::Switched`]), however that came about
//! (the sidebar's switcher, Settings, a deletion, another window). What
//! the main window showed of the connection left closes by whose page it
//! is ([`follow_pages`], [`left_behind`]); the bots and rooms follow the
//! connection `hermes.changed` names, in their own store.

use std::collections::{HashMap, HashSet};
use std::time::Duration;

use conduit_daemon::RpcError;
use conduit_protocol::{
    Event, HermesCatalog, HermesConnectionRef, HermesConnections, HermesJobNotice, HermesJobRef,
    HermesJobs, HermesMcpCatalogEntryDto, HermesMcpServers, HermesRef, HermesSessionDto,
    HermesStatus, HermesToggle, HermesToolsetToggle, NoParams, NoticeLevel, events, methods,
};
use gpui_kit::{App, AsyncApp, Context, EventEmitter, Task, WeakEntity};

use crate::l10n::{ActiveL10n as _, L10n};
use crate::stores::Stores;
use crate::stores::connection::ConnectionEvent;
use crate::stores::navigation::{Area, AreaItem, NavigationEvent, NavigationStore, Selection};
use crate::stores::rpc::Rpc;

/// How often the jobs are read while a run is going or being stopped: a
/// Stop lands at the run's next check, about a second after it is asked.
pub const LIVE_POLL: Duration = Duration::from_secs(2);
/// How often an idle list is read, so a run started elsewhere shows up.
pub const IDLE_POLL: Duration = Duration::from_secs(15);

/// How often the MCP servers are read again while a catalog install is
/// still going, and how many times at most (two minutes).
pub const INSTALL_REREAD: Duration = Duration::from_secs(5);
pub const INSTALL_REREADS: usize = 24;

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

/// What the store tells the window.
#[derive(Clone, Debug, PartialEq)]
pub enum HermesAdminEvent {
    /// Another connection is in use, or Hermes was turned on or off:
    /// `enabled` is the switch now.
    Switched { enabled: bool },
    /// The gateway read its skills again (Reload Skills): a Hermes chat's
    /// `/` list is read again.
    SkillsReloaded,
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
    /// The MCP catalog as Add from Catalog last showed it, and the
    /// connection it was read for ([`Self::take_catalog`]): a pick opens the
    /// entry's values sheet from it, or adds it to that connection.
    mcp_catalog: Vec<HermesMcpCatalogEntryDto>,
    mcp_catalog_for: Option<String>,
    /// Catalog servers Hermes is still installing, and whether each signs
    /// in with OAuth once listed: Settings says so until they are listed.
    pub mcp_installing: Vec<(String, bool)>,
    /// Toolsets being turned on or off: their switches wait.
    pub toolsets_busy: HashSet<String>,
    /// Reload Skills is in flight.
    pub skills_reloading: bool,
    /// The Scheduled Agents pane is shown: the list is polled.
    watching_jobs: bool,
    poll: Option<Task<()>>,
    /// Reads the MCP servers again while a catalog install is still going,
    /// so Settings lists it once Hermes finishes ([`Self::set_installing`]).
    install_poll: Option<Task<()>>,
    poll_every: Option<Duration>,
    /// Notices the last list brought, for the window to say once.
    pending_notices: Vec<HermesJobNotice>,
    revision: u64,
    /// Moves on when another connection comes into use and on a reset: an
    /// answer to a read or action asked before is about the connection
    /// before, and is dropped.
    generation: u64,
    /// The order each thing's reads and actions were asked in: an answer
    /// is taken only if it is newer than the last one taken for the same
    /// thing (an older read never undoes a newer action, nor a newer read).
    status_order: Order,
    catalog_order: Order,
    mcp_order: Order,
    jobs_order: Order,
    runs_order: HashMap<String, Order>,
    /// The connections list's order, which a switch leaves alone (only a
    /// reset drops what was asked before it).
    list_order: Order,
    /// The Hermes page shown, and the connection in use (as this window
    /// knew it; none with Hermes off) when it opened: what a switch's or
    /// Turn Off's clean-up may close is a page of another connection.
    /// The owner is unknown (None) for a page shown before the list was
    /// read; the first list read names it.
    shown_page: Option<(AreaItem, Option<Option<InUse>>)>,
}

/// When the reads and actions of one thing were asked, and the newest
/// whose answer was taken.
#[derive(Default)]
struct Order {
    asked: u64,
    taken: u64,
}

impl Order {
    fn ask(&mut self) -> u64 {
        self.asked += 1;
        self.asked
    }

    /// Whether answer `seq` is newer than the last one taken (and then it
    /// is the last one taken).
    fn take(&mut self, seq: u64) -> bool {
        if seq <= self.taken {
            return false;
        }
        self.taken = seq;
        true
    }

    /// Nothing asked so far is taken any more.
    fn forget(&mut self) {
        self.taken = self.asked;
    }
}

/// The connection a Hermes page opened under: its saved id and the
/// daemon's name for it.
type InUse = (Option<String>, Option<String>);

/// A read or action of the connection in use, as it was asked: its
/// answer is taken only while that connection is still the one (no switch
/// or reset since) and nothing asked later was taken first.
#[derive(Clone, Copy, Debug)]
pub struct Ticket {
    generation: u64,
    seq: u64,
}

impl Ticket {
    /// The store's generation it was asked under ([`HermesAdminStore::is_current`]).
    pub fn generation(&self) -> u64 {
        self.generation
    }
}

/// A catalog read as it was asked: the generation and connection in use.
#[derive(Clone, Debug)]
pub struct CatalogAsk {
    generation: u64,
    connection: Option<String>,
}

/// A connections-list read or action, as it was asked (its place in the
/// order they were asked in): answered only if it is newer than the last
/// list taken and than the last reset. A list that switches connections
/// does not make the ones asked after it older.
#[derive(Clone, Copy, Debug)]
pub struct ListTicket {
    list: u64,
}

impl EventEmitter<HermesAdminEvent> for HermesAdminStore {}

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

    fn ticket(&self, seq: u64) -> Ticket {
        Ticket {
            generation: self.generation,
            seq,
        }
    }

    /// The one check for an answer to `ticket`: the connection is still the
    /// one it was asked under, and nothing asked later of the same thing
    /// (`order`) was taken first.
    fn answers(&mut self, ticket: Ticket, order: impl FnOnce(&mut Self) -> &mut Order) -> bool {
        self.is_current(ticket.generation) && order(self).take(ticket.seq)
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
        self.list_order.forget();
        self.forget_catalog();
        self.mcp_installing.clear();
        self.install_poll = None;
        self.toolsets_busy.clear();
        self.skills_reloading = false;
        self.changed(cx);
    }

    /// The connection in use as the daemon names it
    /// (`HermesChanged.connection`): sent with a request bound to it, which
    /// the daemon refuses once another is in use.
    pub fn connection(&self) -> Option<String> {
        self.connections.as_ref()?.connection.clone()
    }

    /// What a catalog read is asked under: its answer is shown only while
    /// the same connection is in use ([`Self::take_catalog`]).
    pub fn ask_catalog(&self) -> CatalogAsk {
        CatalogAsk {
            generation: self.generation,
            connection: self.connection(),
        }
    }

    /// Keeps `entries`, read as `asked`, for the menu about to show them:
    /// false (nothing kept, no menu) once another connection came into use,
    /// so one connection's catalog never stands for another's.
    pub fn take_catalog(
        &mut self,
        asked: &CatalogAsk,
        entries: Vec<HermesMcpCatalogEntryDto>,
    ) -> bool {
        if !self.is_current(asked.generation) || self.connection() != asked.connection {
            return false;
        }
        self.mcp_catalog = entries;
        self.mcp_catalog_for = asked.connection.clone();
        true
    }

    /// Catalog entry `name` as the menu showed it, with the connection it
    /// was read for: none once another connection came into use (the
    /// catalog is forgotten then), so a pick from an earlier menu adds
    /// nothing to the connection in use now.
    pub fn catalog_entry(&self, name: &str) -> Option<(HermesMcpCatalogEntryDto, Option<String>)> {
        let entry = self.mcp_catalog.iter().find(|e| e.name == name)?;
        Some((entry.clone(), self.mcp_catalog_for.clone()))
    }

    fn forget_catalog(&mut self) {
        self.mcp_catalog.clear();
        self.mcp_catalog_for = None;
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
        // A sheet that knew no connection (opened before the list was read)
        // sends nothing: the daemon refuses a change that names none.
        opened.connection.is_some()
            && self.connections.as_ref().is_none_or(|l| {
                l.active_id == opened.active_id && l.connection == opened.connection
            })
    }

    /// The connection in use, none while Hermes is off: its saved id and
    /// the daemon's name for it (another gateway under the same saved id is
    /// another connection).
    fn in_use(&self) -> Option<InUse> {
        self.connections
            .as_ref()
            .filter(|l| l.enabled)
            .map(|l| (l.active_id.clone(), l.connection.clone()))
    }

    /// The navigation shows `selection`: a Hermes page newly shown is
    /// noted with the connection in use now.
    pub fn note_page(&mut self, selection: &Selection) {
        match selection {
            Selection::Area(item) if item.area() == Area::Hermes => {
                if self.shown_page.as_ref().map(|(shown, _)| shown) != Some(item) {
                    let owner = self.connections.is_some().then(|| self.in_use());
                    self.shown_page = Some((item.clone(), owner));
                }
            }
            _ => self.shown_page = None,
        }
    }

    /// Whether `selection` is a Hermes page that opened under another
    /// connection than the one in use now (or before Hermes was turned off):
    /// the only kind a switch's or Turn Off's clean-up closes, however late
    /// or often it runs.
    pub fn shows_another_connections_page(&self, selection: &Selection) -> bool {
        // Nothing is known while the list is being read (a reconnect): no
        // page is another connection's then.
        if self.connections.is_none() {
            return false;
        }
        match (selection, &self.shown_page) {
            (Selection::Area(item), Some((shown, Some(owner)))) => {
                item == shown && *owner != self.in_use()
            }
            _ => false,
        }
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

    /// The daemon said Hermes changed (another window's action, a run that
    /// ended): what is shown, or being read, is read again.
    pub fn hermes_changed(&mut self, cx: &mut Context<Self>) {
        self.refresh_connections(cx);
        // Shown, or still being read (a read from before the change could
        // answer last otherwise): read again, the newer read taken.
        if matches!(self.mcp, Some(Loaded::Ready(_) | Loaded::Loading)) {
            self.refresh_mcp(cx);
        }
        if self.watching_jobs {
            self.refresh_jobs(cx);
        }
    }

    /// A connections-list read or action about to be asked.
    pub fn ask_list(&mut self) -> ListTicket {
        ListTicket {
            list: self.list_order.ask(),
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
        if !self.list_order.take(ticket.list) {
            return false;
        }
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
        // A switch from a connection known before (not the first read after
        // a launch, a reconnect or another account).
        let left = self.connections.is_some() && switched;
        let enabled = list.enabled;
        // The connection in use now reaches its server another way (signed
        // in or out, another profile, other headers): what was read of it
        // through the old way is read again.
        let reached_anew = !switched && self.connections.is_some() && {
            let way = |l: &HermesConnections| {
                let id = l.active_id.as_deref()?;
                let c = l.connections.iter().find(|c| c.id == id)?;
                Some((
                    c.desktop_signed_in,
                    c.dashboard_signed_in,
                    c.desktop_auth_kind.clone(),
                    c.desktop_profile.clone(),
                    c.access_header_names.clone(),
                ))
            };
            self.connections.as_ref().and_then(way) != way(&list)
        };
        self.connections = Some(list);
        // A page shown before any list was read is the connection's this
        // first list names.
        let now = self.in_use();
        if let Some((_, owner @ None)) = &mut self.shown_page {
            *owner = Some(now);
        }
        if reached_anew {
            let (status, catalog, mcp) = (
                self.status.is_some(),
                self.catalog.is_some(),
                self.mcp.is_some(),
            );
            self.status = None;
            self.catalog = None;
            self.mcp = None;
            if status {
                self.refresh_status(cx);
            }
            if catalog {
                self.refresh_catalog(cx);
            }
            if mcp {
                self.refresh_mcp(cx);
            }
        }
        if left {
            cx.emit(HermesAdminEvent::Switched { enabled });
        }
        if switched {
            // Another connection's status, catalog, servers and jobs. Servers
            // shown or being read are read again for it, as `hermes.changed`
            // reads them (jobs too, while watched).
            let mcp_shown = self.mcp.is_some();
            self.status = None;
            self.catalog = None;
            self.mcp = None;
            self.forget_catalog();
            self.mcp_installing.clear();
            self.install_poll = None;
            self.jobs = None;
            self.runs.clear();
            self.runs_open.clear();
            self.pending_notices.clear();
            self.busy.clear();
            self.mcp_busy.clear();
            self.toolsets_busy.clear();
            self.skills_reloading = false;
            self.generation += 1;
            if mcp_shown {
                self.refresh_mcp(cx);
            }
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
        let seq = self.status_order.ask();
        let ticket = self.ticket(seq);
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result = call.await;
            let _ = this.update(cx, |s, cx| {
                if !s.is_current(ticket.generation) || !s.status_order.take(ticket.seq) {
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
        let seq = self.catalog_order.ask();
        let ticket = self.ticket(seq);
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result = call.await;
            let _ = this.update(cx, |s, cx| {
                if !s.is_current(ticket.generation) || !s.catalog_order.take(ticket.seq) {
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

    /// Turns toolset `name` on or off for new sessions (a Desktop
    /// Gateway's), as the phone's switch: the switch waits meanwhile, and a
    /// refusal is the phone's toast.
    pub fn set_toolset(
        &mut self,
        stores: &Stores,
        name: &str,
        enabled: bool,
        cx: &mut Context<Self>,
    ) {
        let Some(rpc) = self.rpc() else { return };
        if !self.toolsets_busy.insert(name.to_string()) {
            return;
        }
        self.changed(cx);
        // Made on the connection in use now, or not at all; the catalog it
        // answers with follows the order catalogs were asked in.
        let call = rpc.call::<methods::HermesToolsetsSet>(&HermesToolsetToggle {
            name: name.to_string(),
            enabled,
            connection: self.connection(),
        });
        let seq = self.catalog_order.ask();
        let ticket = self.ticket(seq);
        let name = name.to_string();
        let toasts = stores.toasts.downgrade();
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result = call.await;
            let _ = this.update(cx, |s, cx| {
                // After a switch the marks are the next connection's.
                if s.is_current(ticket.generation) {
                    s.toolsets_busy.remove(&name);
                }
                match result {
                    Ok(catalog) => {
                        if s.answers(ticket, |s| &mut s.catalog_order) {
                            s.catalog = Some(Loaded::Ready(catalog));
                        }
                    }
                    Err(e) => {
                        log::info!("hermes.toolsets.set: {e}");
                        let text = cx.l10n().hermes_toolset_update_failed();
                        let _ = toasts.update(cx, |t, cx| t.show(NoticeLevel::Error, text, cx));
                    }
                }
                s.changed(cx);
            });
        })
        .detach();
    }

    /// Reload Skills: the gateway reads its skills again; the catalog it
    /// answers with is shown, and Hermes chats read their `/` list again
    /// ([`HermesAdminEvent::SkillsReloaded`]). A refusal is the phone's
    /// toast.
    pub fn reload_skills(&mut self, stores: &Stores, cx: &mut Context<Self>) {
        let Some(rpc) = self.rpc() else { return };
        if self.skills_reloading {
            return;
        }
        self.skills_reloading = true;
        self.changed(cx);
        let call = rpc.call::<methods::HermesSkillsReload>(&HermesConnectionRef {
            connection: self.connection(),
        });
        let seq = self.catalog_order.ask();
        let ticket = self.ticket(seq);
        let toasts = stores.toasts.downgrade();
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result = call.await;
            let _ = this.update(cx, |s, cx| {
                if !s.is_current(ticket.generation) {
                    // Another connection's: its chats' `/` lists are their own.
                    if let Err(e) = &result {
                        log::info!("hermes.skills.reload: {e}");
                    }
                    return;
                }
                s.skills_reloading = false;
                match result {
                    Ok(catalog) => {
                        if s.answers(ticket, |s| &mut s.catalog_order) {
                            s.catalog = Some(Loaded::Ready(catalog));
                        }
                        cx.emit(HermesAdminEvent::SkillsReloaded);
                    }
                    Err(e) => {
                        log::info!("hermes.skills.reload: {e}");
                        let text = cx.l10n().hermes_action_failed();
                        let _ = toasts.update(cx, |t, cx| t.show(NoticeLevel::Error, text, cx));
                    }
                }
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
        let ticket = self.ask_mcp();
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result = call.await;
            let _ = this.update(cx, |s, cx| {
                if !s.answers(ticket, |s| &mut s.mcp_order) {
                    return;
                }
                s.mcp = Some(match result {
                    Ok(servers) => {
                        s.forget_installed(&servers);
                        Loaded::Ready(servers)
                    }
                    Err(e) => Loaded::Failed(e.to_string()),
                });
                s.changed(cx);
            });
        })
        .detach();
    }

    /// An MCP read or action about to be asked.
    pub fn ask_mcp(&mut self) -> Ticket {
        let seq = self.mcp_order.ask();
        self.ticket(seq)
    }

    /// The servers `ticket`'s action answered with: taken unless another
    /// connection came into use or something asked later was taken first.
    /// Whether they were.
    pub fn answer_mcp(
        &mut self,
        ticket: Ticket,
        servers: HermesMcpServers,
        cx: &mut Context<Self>,
    ) -> bool {
        if !self.answers(ticket, |s| &mut s.mcp_order) {
            return false;
        }
        // Made, but not read again after: the list shown stays, read anew.
        if servers.list_failed {
            self.refresh_mcp(cx);
            return true;
        }
        self.forget_installed(&servers);
        self.mcp = Some(Loaded::Ready(servers));
        self.changed(cx);
        true
    }

    /// Servers that answered just now (newer than any read still out).
    pub fn adopt_mcp(&mut self, servers: HermesMcpServers, cx: &mut Context<Self>) {
        let ticket = self.ask_mcp();
        self.answer_mcp(ticket, servers, cx);
    }

    /// Catalog server `name` is still being installed (`oauth`: it signs in
    /// once listed). One already listed (the install finished before the
    /// list was read) is not. The servers are read again every
    /// [`INSTALL_REREAD`] while an install is still going, at most
    /// [`INSTALL_REREADS`] times from the last install asked, so the
    /// finished server is listed without anything else asking.
    pub fn set_installing(&mut self, name: &str, oauth: bool, cx: &mut Context<Self>) {
        let listed = self
            .mcp
            .as_ref()
            .and_then(Loaded::ready)
            .is_some_and(|l| l.servers.iter().any(|s| s.name == name));
        if listed {
            return;
        }
        self.mcp_installing.retain(|(n, _)| n != name);
        self.mcp_installing.push((name.to_string(), oauth));
        // Each install read for gets the whole budget: a poll going is
        // replaced.
        {
            let generation = self.generation;
            self.install_poll = Some(cx.spawn(
                async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
                    for _ in 0..INSTALL_REREADS {
                        cx.background_executor().timer(INSTALL_REREAD).await;
                        let go_on = this
                            .update(cx, |s, cx| {
                                if !s.is_current(generation) || s.mcp_installing.is_empty() {
                                    return false;
                                }
                                s.refresh_mcp(cx);
                                true
                            })
                            .unwrap_or(false);
                        if !go_on {
                            break;
                        }
                    }
                },
            ));
        }
        self.changed(cx);
    }

    /// Installs that finished: listed now.
    fn forget_installed(&mut self, servers: &HermesMcpServers) {
        self.mcp_installing
            .retain(|(name, _)| !servers.servers.iter().any(|s| &s.name == name));
        if self.mcp_installing.is_empty() {
            self.install_poll = None;
        }
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
        let ticket = self.ask_jobs();
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result = call.await;
            let _ = this.update(cx, |s, cx| match result {
                Ok(jobs) => {
                    s.answer_jobs(ticket, jobs, cx);
                }
                Err(_) if !s.answers(ticket, |s| &mut s.jobs_order) => {}
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

    /// A jobs read or action about to be asked.
    pub fn ask_jobs(&mut self) -> Ticket {
        let seq = self.jobs_order.ask();
        self.ticket(seq)
    }

    /// The jobs `ticket`'s read or action answered with: taken unless
    /// another connection came into use or something asked later was taken
    /// first (then only what it says once, its notices, is kept). Whether
    /// they were.
    pub fn answer_jobs(
        &mut self,
        ticket: Ticket,
        jobs: HermesJobs,
        cx: &mut Context<Self>,
    ) -> bool {
        if !self.is_current(ticket.generation) {
            return false;
        }
        if !self.jobs_order.take(ticket.seq) {
            self.pending_notices.extend(jobs.notices);
            self.changed(cx);
            return false;
        }
        // Made, but not read again after: the list shown stays, read anew.
        if jobs.list_failed {
            self.refresh_jobs(cx);
            return true;
        }
        self.take_jobs(jobs, cx);
        true
    }

    /// Jobs that answered just now (newer than any read still out).
    pub fn adopt_jobs(&mut self, jobs: HermesJobs, cx: &mut Context<Self>) {
        let ticket = self.ask_jobs();
        self.answer_jobs(ticket, jobs, cx);
    }

    fn take_jobs(&mut self, jobs: HermesJobs, cx: &mut Context<Self>) {
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
        let seq = self.runs_order.entry(id.clone()).or_default().ask();
        let ticket = self.ticket(seq);
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result = call.await;
            let _ = this.update(cx, |s, cx| {
                // The job's newest history read of the connection in use.
                if !s.is_current(ticket.generation)
                    || !s.runs_order.entry(id.clone()).or_default().take(ticket.seq)
                {
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
    follow_pages(stores, cx);
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
                s.hermes_admin.update(cx, |a, cx| a.hermes_changed(cx));
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

/// Keeps `stores.hermes_admin` told which Hermes page is shown, and under
/// which connection it opened.
pub fn follow_pages(stores: &Stores, cx: &mut App) {
    let shown = stores.navigation.read(cx).selection().clone();
    stores.hermes_admin.update(cx, |a, _| a.note_page(&shown));
    let admin = stores.hermes_admin.clone();
    cx.subscribe(&stores.navigation, move |_, event, cx| {
        let NavigationEvent::Changed(selection) = event;
        admin.update(cx, |a, _| a.note_page(selection));
    })
    .detach();
    // Whatever changed the list (this window's action, another window's
    // switch heard through hermes.changed, a reconnect's read), a page of
    // another connection than the one in use goes: a chat, room or bot when
    // another connection is in use, any Hermes page with Hermes off
    // ([`left_behind`]).
    let navigation = stores.navigation.downgrade();
    cx.observe(&stores.hermes_admin, move |admin, cx| {
        let Some(navigation) = navigation.upgrade() else {
            return;
        };
        let selection = navigation.read(cx).selection().clone();
        let admin = admin.read(cx);
        let enabled = admin.in_use().is_some();
        let close = matches!(&selection, Selection::Area(item) if left_behind(item, enabled))
            && admin.shows_another_connections_page(&selection);
        if close {
            navigation.update(cx, |n, cx| n.new_chat(false, cx));
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
            // The list follows the order lists were asked in. Turned off, a
            // Hermes page that opened under another connection than the one
            // in use now (none, while Hermes stays off) goes.
            a.answer_list(ticket, list, cx);
            if !enabled {
                close_other_connections_page(a, &navigation, cx);
            }
        },
        cx,
    );
}

/// Opens a new chat when the main window shows something of Hermes's that
/// opened under another connection than the one in use and is no longer
/// there ([`left_behind`]).
fn close_other_connections_page(
    admin: &HermesAdminStore,
    navigation: &WeakEntity<NavigationStore>,
    cx: &mut App,
) {
    let enabled = admin.in_use().is_some();
    let _ = navigation.update(cx, |n, cx| {
        let selection = n.selection();
        if matches!(selection, Selection::Area(item) if left_behind(item, enabled))
            && admin.shows_another_connections_page(selection)
        {
            n.new_chat(false, cx);
        }
    });
}

/// Whether the main window's `item` belongs to the connection just left:
/// with Hermes off, everything of its section; with another connection in
/// use, its chats (a bot's Bot Chat too), its rooms and its bots (Scheduled
/// Agents and Hidden Chats show the new connection's).
pub fn left_behind(item: &AreaItem, enabled: bool) -> bool {
    if !enabled {
        return item.area() == Area::Hermes;
    }
    matches!(
        item,
        AreaItem::HermesSession(_) | AreaItem::HermesRoom(_) | AreaItem::HermesBot(_)
    )
}

/// Puts connection `id` in use: Hermes's sessions, bots and rooms follow.
/// A Hermes chat, room or bot of the connection left behind cannot stay
/// open: a new chat takes its place.
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
            // The list follows the order lists were asked in. The clean-up
            // goes by whose page is shown: a Hermes chat, room or bot that
            // opened under another connection than the one in use now
            // closes; one of the connection in use stays, however late this
            // answer comes.
            a.answer_list(ticket, list, cx);
            close_other_connections_page(a, &navigation, cx);
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
            "connection": format!("0a1b2c3d:{active}"),
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
    /// MCP servers shown (or being read) when another connection comes into
    /// use are read again for it, as `hermes.changed` reads them: the list
    /// does not stay empty until a window happens to ask.
    #[gpui_kit::test]
    fn a_switch_reads_the_shown_servers_again(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        let n = Arc::new(AtomicUsize::new(0));
        let count = n.clone();
        daemon.on::<methods::HermesMcpList>(move |_| {
            let first = count.fetch_add(1, Ordering::SeqCst) == 0;
            Ok(
                serde_json::to_value(servers(if first { "shed-tools" } else { "studio-tools" }))
                    .unwrap(),
            )
        });
        let store = cx.new(|_| HermesAdminStore::new(daemon.rpc()));
        store.update(cx, |s, cx| {
            s.adopt_connections(list("a"), cx);
            s.refresh_mcp(cx);
        });
        cx.run_until_parked();
        store.update(cx, |s, cx| s.adopt_connections(list("b"), cx));
        cx.run_until_parked();
        store.read_with(cx, |s, _| {
            assert_eq!(
                s.mcp,
                Some(Loaded::Ready(servers("studio-tools"))),
                "the servers were not read again for the connection in use"
            );
        });
    }

    /// A catalog server Hermes is still installing is listed once Hermes is
    /// done, with nothing else asking: the servers are read again while it
    /// installs, and no more once it is listed. One already listed is never
    /// said to be installing.
    #[gpui_kit::test]
    fn a_server_still_installing_is_listed_once_hermes_is_done(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        let reads = Arc::new(AtomicUsize::new(0));
        let count = reads.clone();
        daemon.on::<methods::HermesMcpList>(move |_| {
            let done = count.fetch_add(1, Ordering::SeqCst) > 0;
            let names: &[&str] = if done { &["shed-tools", "tide_charts"] } else { &["shed-tools"] };
            Ok(json!({
                "available": true,
                "servers": names.iter().map(|n| json!({"name": n, "enabled": true})).collect::<Vec<_>>(),
            }))
        });
        let store = cx.new(|_| HermesAdminStore::new(daemon.rpc()));
        store.update(cx, |s, cx| {
            s.adopt_connections(list("a"), cx);
            s.adopt_mcp(servers("shed-tools"), cx);
            s.set_installing("shed-tools", false, cx);
            assert!(
                s.mcp_installing.is_empty(),
                "a listed server was said to be installing"
            );
            s.set_installing("tide_charts", false, cx);
        });
        cx.run_until_parked();
        assert_eq!(reads.load(Ordering::SeqCst), 0);
        cx.executor().advance_clock(INSTALL_REREAD);
        cx.run_until_parked();
        store.read_with(cx, |s, _| assert_eq!(s.mcp_installing.len(), 1));
        cx.executor().advance_clock(INSTALL_REREAD);
        cx.run_until_parked();
        store.read_with(cx, |s, _| {
            assert!(
                s.mcp_installing.is_empty(),
                "the finished server was never listed"
            );
        });
        cx.executor().advance_clock(INSTALL_REREAD * 4);
        cx.run_until_parked();
        assert_eq!(
            reads.load(Ordering::SeqCst),
            2,
            "read again after it was listed"
        );
    }

    /// A catalog read of one connection is never shown or picked from once
    /// another is in use: its entries would ask for one server's values and
    /// send them to the other.
    #[gpui_kit::test]
    fn a_catalog_read_before_a_switch_is_never_picked_from(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        let store = cx.new(|_| HermesAdminStore::new(daemon.rpc()));
        let entry: HermesMcpCatalogEntryDto = serde_json::from_value(json!({
            "name": "tide_charts", "description": "Tide tables", "credentials": [],
            "canAdd": true, "fromDashboard": true, "oauth": false,
        }))
        .unwrap();
        store.update(cx, |s, cx| {
            s.adopt_connections(list("a"), cx);
            let asked = s.ask_catalog();
            s.adopt_connections(list("b"), cx);
            assert!(
                !s.take_catalog(&asked, vec![entry.clone()]),
                "the shed's catalog was kept for the greenhouse"
            );
            assert!(s.catalog_entry("tide_charts").is_none());

            let asked = s.ask_catalog();
            assert!(s.take_catalog(&asked, vec![entry.clone()]));
            let (_, read_for) = s.catalog_entry("tide_charts").unwrap();
            assert_eq!(read_for.as_deref(), Some("0a1b2c3d:b"));

            s.adopt_connections(list("a"), cx);
            assert!(
                s.catalog_entry("tide_charts").is_none(),
                "a pick from the greenhouse's menu would add to the shed"
            );
        });
    }

    #[gpui_kit::test]
    fn reads_from_the_connection_before_a_switch_are_dropped(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        let n = Arc::new(AtomicUsize::new(0));
        let count = n.clone();
        daemon.on::<methods::HermesMcpList>(move |_| {
            let first = count.fetch_add(1, Ordering::SeqCst) == 0;
            Ok(serde_json::to_value(servers(if first {
                "seed-catalogue"
            } else {
                "studio-tools"
            }))
            .unwrap())
        });
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
            // Read again for the connection in use; the last one's never land.
            assert_eq!(
                s.mcp,
                Some(Loaded::Ready(servers("studio-tools"))),
                "the last connection's servers landed"
            );
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
        let n = Arc::new(AtomicUsize::new(0));
        let count = n.clone();
        daemon.on::<methods::HermesMcpList>(move |_| {
            let first = count.fetch_add(1, Ordering::SeqCst) == 0;
            Ok(serde_json::to_value(servers(if first {
                "seed-catalogue"
            } else {
                "studio-tools"
            }))
            .unwrap())
        });
        let held = daemon.hold_one::<methods::HermesMcpList>(0);
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
            // Read again for the connection now named; the one before's never
            // land.
            assert_eq!(
                s.mcp,
                Some(Loaded::Ready(servers("studio-tools"))),
                "the connection before's servers landed"
            );
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

    /// A change whose list could not be read again after it keeps the
    /// list shown (it is not emptied) and reads it again.
    #[gpui_kit::test]
    fn a_change_whose_list_failed_keeps_the_list_and_reads_it_again(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        daemon.returns::<methods::HermesJobs>(jobs("Morning watering", None));
        daemon.returns::<methods::HermesMcpList>(servers("seed-catalogue"));
        let store = cx.new(|_| HermesAdminStore::new(daemon.rpc()));
        let failed_jobs: HermesJobs =
            serde_json::from_value(json!({"savedId": "j2", "listFailed": true})).unwrap();
        let failed_mcp: HermesMcpServers =
            serde_json::from_value(json!({"available": true, "listFailed": true})).unwrap();
        store.update(cx, |s, cx| {
            s.adopt_connections(list("a"), cx);
            s.adopt_jobs(jobs("Morning watering", None), cx);
            s.adopt_mcp(servers("seed-catalogue"), cx);
            s.adopt_jobs(failed_jobs, cx);
            s.adopt_mcp(failed_mcp, cx);
        });
        store.read_with(cx, |s, _| {
            assert_eq!(
                s.jobs
                    .as_ref()
                    .and_then(Loaded::ready)
                    .map(|j| j.jobs.len()),
                Some(1),
                "the jobs shown were emptied"
            );
            assert_eq!(
                s.mcp
                    .as_ref()
                    .and_then(Loaded::ready)
                    .map(|m| m.servers.len()),
                Some(1),
                "the servers shown were emptied"
            );
        });
        cx.run_until_parked();
        assert_eq!(
            daemon.calls::<methods::HermesJobs>().len(),
            1,
            "the jobs were not read again"
        );
        assert_eq!(
            daemon.calls::<methods::HermesMcpList>().len(),
            1,
            "the servers were not read again"
        );
    }

    /// hermes.changed while the first MCP read is still out reads the
    /// servers again: the first read's answer, from before the change, is
    /// not what stays.
    #[gpui_kit::test]
    fn hermes_changed_reads_servers_still_being_read_again(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        daemon.returns::<methods::HermesConnectionsList>(list("a"));
        let n = Arc::new(AtomicUsize::new(0));
        let count = n.clone();
        daemon.on::<methods::HermesMcpList>(move |_| {
            let first = count.fetch_add(1, Ordering::SeqCst) == 0;
            Ok(serde_json::to_value(servers(if first { "before" } else { "after" })).unwrap())
        });
        let first = daemon.hold_one::<methods::HermesMcpList>(0);
        let store = cx.new(|_| HermesAdminStore::new(daemon.rpc()));
        store.update(cx, |s, cx| {
            s.adopt_connections(list("a"), cx);
            s.refresh_mcp(cx);
            s.hermes_changed(cx);
        });
        cx.run_until_parked();
        drop(first);
        cx.run_until_parked();
        store.read_with(cx, |s, _| {
            let name = s
                .mcp
                .as_ref()
                .and_then(Loaded::ready)
                .map(|m| m.servers[0].name.clone());
            assert_eq!(
                name.as_deref(),
                Some("after"),
                "the servers from before the change stayed"
            );
        });
    }

    /// An MCP read asked before an action is answered after it: the
    /// action's servers stay (a server just turned off is not shown on).
    #[gpui_kit::test]
    fn an_older_mcp_read_does_not_undo_an_action(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        daemon.returns::<methods::HermesMcpList>(servers("seed-catalogue"));
        let held = daemon.hold::<methods::HermesMcpList>();
        let store = cx.new(|_| HermesAdminStore::new(daemon.rpc()));
        let mut off = servers("seed-catalogue");
        off.servers[0].enabled = false;
        store.update(cx, |s, cx| {
            s.adopt_connections(list("a"), cx);
            s.refresh_mcp(cx);
            s.adopt_mcp(off, cx);
        });
        drop(held);
        cx.run_until_parked();
        store.read_with(cx, |s, _| {
            let enabled = s
                .mcp
                .as_ref()
                .and_then(Loaded::ready)
                .map(|m| m.servers[0].enabled);
            assert_eq!(
                enabled,
                Some(false),
                "the older read turned the server back on"
            );
        });
    }

    /// A job's history read answered after a newer one (the run ended
    /// while the first was out) does not put its older history back.
    #[gpui_kit::test]
    fn an_older_history_read_does_not_replace_a_newer_one(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        let n = Arc::new(AtomicUsize::new(0));
        let count = n.clone();
        daemon.on::<methods::HermesJobsRuns>(move |_| {
            let older = count.fetch_add(1, Ordering::SeqCst) == 0;
            let sessions: Vec<_> = if older {
                vec![]
            } else {
                vec![json!({"id": "run-2", "chatId": "local:hermes_run-2", "title": "Watered at dusk"})]
            };
            Ok(json!({ "sessions": sessions }))
        });
        let older = daemon.hold_one::<methods::HermesJobsRuns>(0);
        let store = cx.new(|_| HermesAdminStore::new(daemon.rpc()));
        store.update(cx, |s, cx| {
            s.adopt_connections(list("a"), cx);
            s.load_runs("j1", cx);
            s.load_runs("j1", cx);
        });
        cx.run_until_parked();
        drop(older);
        cx.run_until_parked();
        store.read_with(cx, |s, _| {
            let titles: Vec<String> = s
                .runs
                .get("j1")
                .and_then(Loaded::ready)
                .map(|r| r.iter().map(|r| r.title.clone()).collect())
                .unwrap_or_default();
            assert_eq!(
                titles,
                vec!["Watered at dusk".to_string()],
                "the older history came back"
            );
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

    /// Connections a and b, `active` in use, Hermes on or off.
    fn list_of(active: Option<&str>, enabled: bool) -> HermesConnections {
        serde_json::from_value(json!({
            "enabled": enabled,
            "activeId": active,
            "connections": [
                {"id": "a", "name": "Shed"},
                {"id": "b", "name": "Studio"},
            ],
        }))
        .unwrap()
    }

    #[gpui_kit::test]
    fn a_sign_in_reads_the_status_and_catalog_again(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        let store = cx.new(|_| HermesAdminStore::new(daemon.rpc()));
        let with = |signed_in: bool| -> HermesConnections {
            serde_json::from_value(json!({
                "enabled": true,
                "activeId": "a",
                "connections": [{
                    "id": "a", "name": "Shed", "mode": "desktop",
                    "desktopAuthKind": "dashboardCookie",
                    "dashboardSignedIn": signed_in,
                }],
            }))
            .unwrap()
        };
        store.update(cx, |s, cx| {
            s.adopt_connections(with(false), cx);
            s.status = Some(Loaded::Failed("not signed in".into()));
            s.catalog = Some(Loaded::Failed("not signed in".into()));
        });
        // The same list again reads nothing.
        store.update(cx, |s, cx| s.adopt_connections(with(false), cx));
        cx.run_until_parked();
        assert!(daemon.calls::<methods::HermesStatus>().is_empty());
        // Signed in to its dashboard: what was read without the session is
        // read again, and no switch is said.
        store.update(cx, |s, cx| s.adopt_connections(with(true), cx));
        cx.run_until_parked();
        assert_eq!(daemon.calls::<methods::HermesStatus>().len(), 1);
        assert_eq!(daemon.calls::<methods::HermesCatalog>().len(), 1);
    }

    #[test]
    fn what_a_switch_leaves_behind() {
        use crate::stores::navigation::WorkspaceSection;

        let session = AreaItem::HermesSession("s1".into());
        let room = AreaItem::HermesRoom("r1".into());
        let bot = AreaItem::HermesBot("fern".into());
        // Another connection: its chats, rooms and bots go; Scheduled
        // Agents and Hidden Chats show the new one's.
        for item in [&session, &room, &bot] {
            assert!(left_behind(item, true), "{item:?}");
        }
        assert!(!left_behind(&AreaItem::HermesJobs, true));
        assert!(!left_behind(&AreaItem::HermesHidden, true));
        // Hermes off: everything of its section goes, nothing else.
        for item in [
            &session,
            &room,
            &bot,
            &AreaItem::HermesJobs,
            &AreaItem::HermesHidden,
        ] {
            assert!(left_behind(item, false), "{item:?}");
        }
        assert!(!left_behind(&AreaItem::Calendar, false));
        assert!(!left_behind(
            &AreaItem::Workspace(WorkspaceSection::Models),
            false
        ));
    }

    #[gpui_kit::test]
    fn a_switch_is_said_once_and_never_for_the_first_read(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        let store = cx.new(|_| HermesAdminStore::new(daemon.rpc()));
        let seen = std::rc::Rc::new(std::cell::RefCell::new(Vec::new()));
        {
            let seen = seen.clone();
            cx.update(|cx| {
                cx.subscribe(&store, move |_, event: &HermesAdminEvent, _| {
                    seen.borrow_mut().push(event.clone())
                })
                .detach()
            });
        }
        // The first read after a launch (or a reconnect's reset) is no switch.
        store.update(cx, |s, cx| {
            s.adopt_connections(list_of(Some("a"), true), cx)
        });
        // The same list again (an action's answer after `hermes.changed`).
        store.update(cx, |s, cx| {
            s.adopt_connections(list_of(Some("a"), true), cx)
        });
        cx.run_until_parked();
        assert!(seen.borrow().is_empty());
        // Another connection in use, then Hermes off.
        store.update(cx, |s, cx| {
            s.adopt_connections(list_of(Some("b"), true), cx)
        });
        store.update(cx, |s, cx| {
            s.adopt_connections(list_of(Some("b"), false), cx)
        });
        cx.run_until_parked();
        assert_eq!(
            *seen.borrow(),
            vec![
                HermesAdminEvent::Switched { enabled: true },
                HermesAdminEvent::Switched { enabled: false },
            ]
        );
        // A reconnect forgets the list: its first read says nothing.
        store.update(cx, |s, cx| {
            s.reset(cx);
            s.adopt_connections(list_of(Some("a"), true), cx)
        });
        cx.run_until_parked();
        assert_eq!(seen.borrow().len(), 2);
    }
}
