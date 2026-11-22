//! The app's link to `conduitd`: the supervisor and the RPC client behind
//! one GPUI entity, the connection state the window draws, and the event
//! fan-out every other store listens to.
//!
//! * **Status** ([`Status`]) is derived from the supervisor phase, the RPC
//!   state and whether the session store has routed yet; [`derive_status`]
//!   is pure and tested. Routing itself is the session store's
//!   ([`super::session`]).
//! * **Events:** each daemon event is decoded into a typed
//!   [`conduit_protocol::Event`] and re-emitted as
//!   [`ConnectionEvent::Daemon`]; a new daemon session is
//!   [`ConnectionEvent::Connected`] and a `seq` gap [`ConnectionEvent::Gap`],
//!   both of which mean "refetch".
//! * **Subscriptions:** stores register the events and scopes they want
//!   ([`ConnectionStore::subscribe`]); the union goes out as one
//!   `events.subscribe` and again after every reconnect.
//! * **Window duties:** `shell.openUrl` (http(s) only), and `system.network`
//!   pushed from NWPathMonitor.

use std::collections::{BTreeMap, BTreeSet};
use std::path::PathBuf;
use std::sync::Arc;
use std::time::{Duration, SystemTime};

use conduit_daemon::http::HttpClient;
use conduit_daemon::paths::{AppPaths, move_aside};
use conduit_daemon::rpc::{ClientEvent, ConnectionState, Handshake, RpcClient, RpcConfig};
use conduit_daemon::secrets::{FreshStart, MasterKeyItems};
use conduit_daemon::supervisor::{FatalReason, Supervisor, SupervisorConfig, SupervisorEvent};
use conduit_daemon::{runtime, secrets};
use conduit_protocol::{Event, HandshakeRequest, NetworkReport, NoParams, events, methods};
use gpui_kit::{App, AppContext as _, AsyncApp, Context, Entity, EventEmitter, WeakEntity};

use super::files::FileAccess;
use super::rpc::Rpc;
use crate::shell::open_url;

/// The supervisor's view of the daemon process.
#[derive(Clone, Debug, PartialEq)]
pub enum DaemonPhase {
    Starting,
    Running { pid: u32, port: u16 },
    Restarting,
    Fatal(FatalReason),
    Stopped,
}

/// What the window shows about the connection.
#[derive(Clone, Debug, PartialEq)]
pub enum Status {
    /// Starting the daemon, or connecting for the first time.
    Connecting,
    /// Connected, while the core starts (the route is still unknown).
    CoreStarting,
    Connected,
    /// Lost after having been connected; trying again.
    Reconnecting {
        attempt: u32,
    },
    /// Gave up; Retry starts over.
    Failed {
        detail: String,
    },
    /// Exit 77: the secure store does not open. Offers "Reset local data".
    StoreUnreadable,
    /// Reading the master key would make macOS ask for the login keychain
    /// password, so conduitd waits for Continue or Start Fresh. `busy`: one
    /// of them is running; `failures`: how many Continues did not get the
    /// key.
    KeychainPrompt {
        busy: bool,
        failures: u32,
    },
    /// Fatal: the app and its daemon speak different protocol versions.
    VersionMismatch {
        daemon: String,
        app: String,
    },
}

impl Status {
    /// Whether the window should replace its content with this status
    /// (rather than show the content with a banner). `routed`: the session
    /// knows where the window goes.
    pub fn blocks(&self, routed: bool) -> bool {
        match self {
            Self::Failed { .. }
            | Self::StoreUnreadable
            | Self::KeychainPrompt { .. }
            | Self::VersionMismatch { .. } => true,
            Self::Connecting | Self::CoreStarting | Self::Reconnecting { .. } => !routed,
            Self::Connected => false,
        }
    }
}

/// The status for a set of facts. Fatal states win, then the RPC state.
/// `routed`: the session has routed; `session_error`: why it could not.
pub fn derive_status(
    startup_error: Option<&str>,
    daemon: &DaemonPhase,
    rpc: &ConnectionState,
    routed: bool,
    session_error: Option<&str>,
    ever_connected: bool,
) -> Status {
    if let Some(e) = startup_error {
        return Status::Failed {
            detail: e.to_string(),
        };
    }
    match daemon {
        DaemonPhase::Fatal(FatalReason::SecureStoreUnreadable) => return Status::StoreUnreadable,
        DaemonPhase::Fatal(reason) => {
            return Status::Failed {
                detail: match reason {
                    FatalReason::Usage => "conduitd refused its arguments (exit 64)".into(),
                    FatalReason::TooManyRestarts { restarts } => {
                        format!("conduitd stopped {restarts} times in a minute")
                    }
                    FatalReason::SpawnFailed(e) => e.clone(),
                    FatalReason::SecureStoreUnreadable => unreachable!(),
                },
            };
        }
        _ => {}
    }
    match rpc {
        ConnectionState::VersionMismatch { daemon, app } => Status::VersionMismatch {
            daemon: daemon.clone(),
            app: app.clone(),
        },
        ConnectionState::Failed { error } => Status::Failed {
            detail: error.clone(),
        },
        ConnectionState::Connected(_) => match (routed, session_error) {
            (false, Some(e)) => Status::Failed {
                detail: e.to_string(),
            },
            (false, None) => Status::CoreStarting,
            _ => Status::Connected,
        },
        ConnectionState::Reconnecting { attempt, .. } if ever_connected => {
            Status::Reconnecting { attempt: *attempt }
        }
        _ if ever_connected
            && matches!(daemon, DaemonPhase::Restarting | DaemonPhase::Starting) =>
        {
            Status::Reconnecting { attempt: 1 }
        }
        _ => Status::Connecting,
    }
}

/// Settings › About's export.
#[derive(Clone, Debug, PartialEq)]
pub enum Diagnostics {
    Idle,
    Exporting,
    Saved(PathBuf),
    Failed(String),
}

/// Emitted for the app and the stores to act on.
#[derive(Clone, Debug, PartialEq)]
pub enum ConnectionEvent {
    /// userData was moved aside; app-side files must be written again.
    LocalDataReset { moved_to: PathBuf },
    /// A new daemon session (first connect, reconnect, restarted daemon):
    /// everything is refetched.
    Connected {
        handshake: Box<Handshake>,
        request: HandshakeRequest,
    },
    /// Events were lost within a session: refetch rather than patch.
    Gap,
    /// A daemon event, decoded.
    Daemon(Box<Event>),
}

/// The events this window services itself, whatever the stores ask for.
const WINDOW_EVENTS: &[&str] = &[events::OPEN_URL];

pub struct ConnectionStore {
    paths: AppPaths,
    token: String,
    master_key: Option<String>,
    keychain: Option<KeychainQuestion>,
    /// Whether the client's and the supervisor's events are followed
    /// ([`Self::start`]).
    follow: bool,
    binary: PathBuf,
    rpc_config: RpcConfig,
    supervisor: Option<Supervisor>,
    pub client: RpcClient,
    rpc_handle: Rpc,
    http: Option<HttpClient>,
    pub daemon: DaemonPhase,
    pub rpc: ConnectionState,
    pub handshake: Option<Handshake>,
    startup_error: Option<String>,
    ever_connected: bool,
    online: Option<bool>,
    /// Each registrant's events and scopes; their union is subscribed.
    subscriptions: BTreeMap<&'static str, (Vec<&'static str>, Vec<String>)>,
    pub diagnostics: Diagnostics,
    pub reset_error: Option<String>,
    /// Clearing local data: stopping, moving aside, starting again.
    pub clearing: bool,
    /// A restart (no clear) is under way: the old daemon's stop is part of
    /// it, so the window keeps saying it reconnects.
    restarting: bool,
    /// URLs opened for `shell.openUrl` (for tests and diagnostics).
    pub opened_urls: Vec<String>,
}

impl EventEmitter<ConnectionEvent> for ConnectionStore {}

/// Starting parameters.
pub struct ConnectionOptions {
    pub paths: AppPaths,
    pub binary: PathBuf,
    pub master_key: MasterKey,
    pub locale: String,
    pub client_version: String,
}

/// The master key the connection starts with.
pub enum MasterKey {
    Ready(String),
    /// Reading the stored key would make macOS ask for the login keychain
    /// password: the window asks first, and conduitd waits.
    WouldPrompt(KeychainChoice),
    /// The Keychain could not give a key.
    Failed(String),
}

/// What the keychain card's choices act on.
pub struct KeychainChoice {
    pub items: Arc<dyn MasterKeyItems + Send + Sync>,
    /// The account whose read would prompt.
    pub account: String,
    /// The lock Start Fresh holds ([`conduit_daemon::paths::master_key_lock`]).
    pub lock: PathBuf,
}

/// The keychain card's question, while it is asked.
struct KeychainQuestion {
    choice: Arc<KeychainChoice>,
    busy: bool,
    failures: u32,
    /// Where a Start Fresh that then failed moved the profile.
    moved_to: Option<PathBuf>,
}

impl ConnectionStore {
    /// Starts the daemon and the connection. In tests neither the client's
    /// nor the supervisor's events are followed, whoever starts it (a view
    /// test's stores or a fixture's): nothing on the daemon's I/O thread may
    /// wake a test's tasks, which the test scheduler refuses as not
    /// deterministic.
    pub fn start(options: ConnectionOptions, cx: &mut App) -> Entity<Self> {
        cx.new(|cx| Self::new(options, !cfg!(test), cx))
    }

    fn new(options: ConnectionOptions, follow: bool, cx: &mut Context<Self>) -> Self {
        let rt = runtime::shared();
        let token = secrets::new_session_token();
        let mut rpc_config = RpcConfig::new(token.clone(), options.client_version.clone());
        rpc_config.locale = options.locale.clone();
        let (client, client_events) = RpcClient::start(rpc_config.clone(), &rt);
        client.subscribe(WINDOW_EVENTS, &[]);

        let (master_key, startup_error, keychain) = match options.master_key {
            MasterKey::Ready(key) => (Some(key), None, None),
            MasterKey::WouldPrompt(choice) => (
                None,
                None,
                Some(KeychainQuestion {
                    choice: Arc::new(choice),
                    busy: false,
                    failures: 0,
                    moved_to: None,
                }),
            ),
            MasterKey::Failed(e) => {
                log::error!("no master key: {e}");
                (None, Some(e), None)
            }
        };
        if follow {
            pump(cx, client_events, |s, e, cx| s.on_client(e, cx));
        }

        let mut this = Self {
            paths: options.paths,
            token,
            master_key,
            keychain,
            follow,
            binary: options.binary,
            rpc_config,
            supervisor: None,
            rpc_handle: Rpc::new(client.clone()),
            client,
            http: None,
            daemon: DaemonPhase::Starting,
            rpc: ConnectionState::WaitingForDaemon,
            handshake: None,
            startup_error,
            ever_connected: false,
            online: None,
            subscriptions: BTreeMap::new(),
            diagnostics: Diagnostics::Idle,
            reset_error: None,
            clearing: false,
            restarting: false,
            opened_urls: vec![],
        };
        this.spawn_supervisor(cx);
        this
    }

    fn spawn_supervisor(&mut self, cx: &mut Context<Self>) {
        let Some(master_key) = self.master_key.clone() else {
            return;
        };
        let mut config = SupervisorConfig::new(
            self.binary.clone(),
            self.paths.user_data.clone(),
            self.paths.logs.clone(),
            self.token.clone(),
            master_key,
        );
        // Run from the checkout: the daemon's logo catalog is the repo's
        // (a bundle has its own beside conduitd).
        let catalog = crate::views::model_logo::MODEL_LOGO_CATALOG_DIR;
        if std::env::var_os("CONDUIT_MODEL_LOGOS").is_none()
            && std::path::Path::new(catalog).join("catalog.json").exists()
        {
            config
                .env
                .push(("CONDUIT_MODEL_LOGOS".into(), catalog.into()));
        }
        let (supervisor, events) = Supervisor::spawn(config, &runtime::shared());
        if self.follow {
            pump(cx, events, |s, e, cx| s.on_supervisor(e, cx));
        }
        self.supervisor = Some(supervisor);
    }

    /// Keeps [`FileAccess`] (the `/files` loader's client) current.
    fn publish_file_access(&self, cx: &mut App) {
        let port = match self.daemon {
            DaemonPhase::Running { port, .. } if self.http.is_some() => Some(port),
            _ => None,
        };
        let staging = self
            .handshake
            .as_ref()
            .and_then(|h| h.response.as_ref())
            .map(|r| PathBuf::from(&r.paths.staging));
        cx.set_global(FileAccess {
            http: self.http.clone(),
            port,
            staging,
        });
    }

    /// Answers the windows' calls from `rpc` (a scripted daemon).
    #[cfg(test)]
    pub fn set_rpc_for_test(&mut self, rpc: Rpc) {
        self.rpc_handle = rpc;
    }

    /// A view test's connection, read as a daemon still starting rather
    /// than one that failed for want of a master key: a routed window
    /// shows its main frame.
    #[cfg(test)]
    pub fn set_starting_for_test(&mut self) {
        self.startup_error = None;
    }

    /// The handle stores call the daemon through.
    pub fn rpc(&self) -> Rpc {
        self.rpc_handle.clone()
    }

    /// The window's status. `routed` and `session_error` come from the
    /// session store.
    pub fn status(&self, routed: bool, session_error: Option<&str>) -> Status {
        if let Some(q) = &self.keychain {
            return Status::KeychainPrompt {
                busy: q.busy,
                failures: q.failures,
            };
        }
        derive_status(
            self.startup_error.as_deref(),
            &self.daemon,
            &self.rpc,
            routed,
            session_error,
            self.ever_connected,
        )
    }

    pub fn is_connected(&self) -> bool {
        matches!(self.rpc, ConnectionState::Connected(_))
    }

    /// The window's view of the network (NWPathMonitor), once known.
    pub fn online(&self) -> Option<bool> {
        self.online
    }

    pub fn http(&self) -> Option<&HttpClient> {
        self.http.as_ref()
    }

    /// `HandshakeRequest` this window sends.
    pub fn handshake_request(&self) -> HandshakeRequest {
        self.rpc_config.handshake_request()
    }

    /// Registers what `key` wants delivered; the union of every key's events
    /// and scopes is subscribed (now, and after each reconnect). A follower
    /// leaves by subscribing its key to nothing, which removes the key.
    pub fn subscribe(&mut self, key: &'static str, events: &[&'static str], scopes: Vec<String>) {
        if events.is_empty() && scopes.is_empty() {
            self.subscriptions.remove(key);
        } else {
            // A key is one follower's: it may change its scopes, but another
            // follower's events under the same key would replace these (the
            // union is built from one entry per key).
            debug_assert!(
                self.subscriptions
                    .get(key)
                    .is_none_or(|(held, _)| held.as_slice() == events),
                "two followers share the event subscription key {key:?}"
            );
            self.subscriptions.insert(key, (events.to_vec(), scopes));
        }
        let mut names: BTreeSet<&'static str> = WINDOW_EVENTS.iter().copied().collect();
        let mut all_scopes: BTreeSet<String> = BTreeSet::new();
        for (events, scopes) in self.subscriptions.values() {
            names.extend(events.iter().copied());
            all_scopes.extend(scopes.iter().cloned());
        }
        let names: Vec<&str> = names.into_iter().collect();
        let scopes: Vec<String> = all_scopes.into_iter().collect();
        self.client.subscribe(&names, &scopes);
    }

    pub fn paths(&self) -> &AppPaths {
        &self.paths
    }

    fn on_supervisor(&mut self, event: SupervisorEvent, cx: &mut Context<Self>) {
        log::info!("supervisor: {event:?}");
        match event {
            SupervisorEvent::Starting { .. } => {
                self.daemon = DaemonPhase::Starting;
                self.client.set_endpoint(None);
            }
            SupervisorEvent::Ready { port, pid } => {
                self.daemon = DaemonPhase::Running { pid, port };
                self.http = Some(HttpClient::new(port, self.token.clone()));
                self.client.set_endpoint(Some(port));
                self.publish_file_access(cx);
            }
            SupervisorEvent::Exited { .. } => {
                self.http = None;
                self.client.set_endpoint(None);
                self.publish_file_access(cx);
            }
            SupervisorEvent::Restarting { .. } => self.daemon = DaemonPhase::Restarting,
            SupervisorEvent::Fatal(reason) => self.daemon = DaemonPhase::Fatal(reason),
            // The stop a restart asked for: the next daemon is on its way.
            SupervisorEvent::Stopped(_) if self.restarting => {}
            SupervisorEvent::Stopped(_) => self.daemon = DaemonPhase::Stopped,
        }
        cx.notify();
    }

    fn on_client(&mut self, event: ClientEvent, cx: &mut Context<Self>) {
        match event {
            ClientEvent::State(state) => {
                log::info!("rpc: {}", describe_state(&state));
                let connected = match &state {
                    ConnectionState::Connected(h) => Some(h.clone()),
                    _ => None,
                };
                self.rpc = state;
                if let Some(h) = connected {
                    self.ever_connected = true;
                    self.handshake = Some(h.clone());
                    self.publish_file_access(cx);
                    if let Some(online) = self.online {
                        self.push_network(online, cx);
                    }
                    cx.emit(ConnectionEvent::Connected {
                        handshake: Box::new(h),
                        request: self.handshake_request(),
                    });
                }
            }
            ClientEvent::Event(envelope) => match Event::try_from(envelope) {
                Ok(Event::OpenUrl(open)) => match open_url::validate(&open.url) {
                    Some(url) => {
                        log::info!(
                            "opening {} for the daemon",
                            url.origin().ascii_serialization()
                        );
                        let intercepted =
                            cx.try_global::<open_url::Intercept>().is_some_and(|i| i.0);
                        if !intercepted {
                            cx.open_url(url.as_str());
                        }
                        self.opened_urls.push(url.to_string());
                    }
                    None => log::warn!("refused a shell.openUrl that is not http(s)"),
                },
                Ok(Event::Unknown { name, .. }) => log::debug!("unknown event {name}"),
                Ok(event) => cx.emit(ConnectionEvent::Daemon(Box::new(event))),
                Err(e) => log::warn!("undecodable event: {e}"),
            },
            ClientEvent::Gap { expected, got } => {
                log::warn!("event gap: expected seq {expected}, got {got}");
                cx.emit(ConnectionEvent::Gap);
            }
        }
        cx.notify();
    }

    /// The window's view of the network changed.
    pub fn set_online(&mut self, online: bool, cx: &mut Context<Self>) {
        if self.online == Some(online) {
            return;
        }
        self.online = Some(online);
        if matches!(self.rpc, ConnectionState::Connected(_)) {
            self.push_network(online, cx);
        }
    }

    fn push_network(&self, online: bool, cx: &mut Context<Self>) {
        log::info!("system.network online={online}");
        let call = self
            .client
            .call::<methods::SystemNetwork>(&NetworkReport { online });
        cx.background_spawn(async move {
            if let Err(e) = call.await {
                log::debug!("system.network: {e}");
            }
        })
        .detach();
    }

    /// Retry after a failure: restart the daemon or reconnect, whichever
    /// failed. Returns whether the session should refetch instead (the
    /// connection is fine).
    pub fn retry(&mut self, cx: &mut Context<Self>) -> bool {
        self.reset_error = None;
        let refetch = match (&self.daemon, &self.rpc) {
            (DaemonPhase::Fatal(_), _) => {
                if let Some(s) = &self.supervisor {
                    s.restart();
                }
                false
            }
            (_, ConnectionState::Failed { .. }) => {
                self.client.retry();
                false
            }
            (_, ConnectionState::Connected(_)) => true,
            _ => false,
        };
        cx.notify();
        refetch
    }

    /// The keychain card's Continue: reads the profile's key, and macOS
    /// asks for the login keychain password. Off the main thread: the read
    /// waits for the answer in macOS's dialog.
    pub fn keychain_continue(&mut self, cx: &mut Context<Self>) {
        let Some(choice) = self.begin_keychain_choice(cx) else {
            return;
        };
        let user_data = self.paths.user_data.clone();
        let read = cx.background_spawn(async move {
            let account = secrets::profile_key_account(&user_data);
            secrets::read_master_key(choice.items.as_ref(), &account)
        });
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let read = read.await;
            let _ = this.update(cx, |s, cx| {
                match read {
                    Ok(key) => s.start_with_key(key, cx),
                    Err(e) => s.keychain_choice_failed(format!("Continue: {e}")),
                }
                cx.notify();
            });
        })
        .detach();
    }

    /// The keychain card's Start Fresh ([`secrets::start_fresh`]), off the
    /// main thread. Whatever fails, the card stays with its choices.
    pub fn keychain_start_fresh(&mut self, cx: &mut Context<Self>) {
        let Some(choice) = self.begin_keychain_choice(cx) else {
            return;
        };
        let user_data = self.paths.user_data.clone();
        let fresh = cx.background_spawn(async move {
            secrets::start_fresh(
                choice.items.as_ref(),
                &user_data,
                &choice.account,
                &choice.lock,
                SystemTime::now(),
            )
        });
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let fresh = fresh.await;
            let _ = this.update(cx, |s, cx| {
                match fresh {
                    FreshStart::Started { key, moved_to } => {
                        s.keep_moved_to(moved_to);
                        s.start_with_key(key, cx);
                    }
                    FreshStart::AlreadyFresh(key) => s.start_with_key(key, cx),
                    FreshStart::MoveFailed(e) => {
                        s.keychain_choice_failed(format!("Start Fresh: {e}"));
                        s.reset_error = Some(e);
                    }
                    FreshStart::KeyFailed { error, moved_to } => {
                        s.keep_moved_to(moved_to);
                        s.keychain_choice_failed(format!("Start Fresh: {error}"));
                    }
                }
                cx.notify();
            });
        })
        .detach();
    }

    /// The card's choice, unless one is already running.
    fn begin_keychain_choice(&mut self, cx: &mut Context<Self>) -> Option<Arc<KeychainChoice>> {
        let q = self.keychain.as_mut().filter(|q| !q.busy)?;
        q.busy = true;
        self.reset_error = None;
        cx.notify();
        Some(q.choice.clone())
    }

    fn keychain_choice_failed(&mut self, why: String) {
        log::warn!("keychain: {why}");
        if let Some(q) = &mut self.keychain {
            q.busy = false;
            q.failures += 1;
        }
    }

    fn keep_moved_to(&mut self, moved_to: Option<PathBuf>) {
        if let Some(q) = &mut self.keychain {
            q.moved_to = q.moved_to.take().or(moved_to);
        }
    }

    fn start_with_key(&mut self, key: String, cx: &mut Context<Self>) {
        if let Some(moved_to) = self.keychain.take().and_then(|q| q.moved_to) {
            log::warn!(
                "start fresh: moved local data aside to {}",
                moved_to.display()
            );
            cx.emit(ConnectionEvent::LocalDataReset { moved_to });
        }
        self.master_key = Some(key);
        self.spawn_supervisor(cx);
    }

    /// "Reset local data" (after exit 77): moves userData aside with a
    /// timestamp (nothing is deleted) and starts the daemon fresh.
    pub fn reset_local_data(&mut self, cx: &mut Context<Self>) {
        if !matches!(self.daemon, DaemonPhase::Fatal(_)) {
            return;
        }
        match move_aside(&self.paths.user_data, SystemTime::now()) {
            Ok(moved_to) => {
                log::warn!("moved local data aside to {}", moved_to.display());
                self.reset_error = None;
                cx.emit(ConnectionEvent::LocalDataReset { moved_to });
                if let Some(s) = &self.supervisor {
                    s.restart();
                }
            }
            Err(e) => {
                log::warn!("reset local data: {e}");
                self.reset_error = Some(e.to_string());
            }
        }
        cx.notify();
    }

    /// Settings › Data › "Clear local data": stops the daemon, moves
    /// userData aside (accounts, sessions, the local database; nothing is
    /// deleted, the folder keeps a timestamp) and starts a fresh daemon,
    /// which sends the window back to onboarding.
    /// Whether Clear Local Data can start: no clear running, and a daemon
    /// to stop (running, failed or out of reach: it needs no connection).
    pub fn can_clear(&self) -> bool {
        !self.clearing && self.supervisor.is_some()
    }

    pub fn clear_local_data(&mut self, cx: &mut Context<Self>) {
        self.stop_and_respawn(true, Duration::ZERO, cx);
    }

    /// Stops the daemon through its supervisor and starts a fresh one, as a
    /// crash and restart would look (the capture's reconnecting state). Only
    /// the supervisor signals the daemon, and never once it has exited.
    #[cfg(feature = "harness")]
    pub fn restart_daemon(&mut self, cx: &mut Context<Self>) -> bool {
        self.stop_and_respawn(false, Duration::ZERO, cx)
    }

    /// [`Self::restart_daemon`], with the fresh daemon started `hold` after
    /// the old one stopped: a stop and start take a few milliseconds, too
    /// short for the reconnecting state to be seen and photographed.
    #[cfg(feature = "harness")]
    pub fn restart_daemon_after(&mut self, hold: Duration, cx: &mut Context<Self>) -> bool {
        self.stop_and_respawn(false, hold, cx)
    }

    /// `move_data`: move userData aside between the stop and the start.
    /// `hold`: how long to wait before the start.
    fn stop_and_respawn(
        &mut self,
        move_data: bool,
        hold: Duration,
        cx: &mut Context<Self>,
    ) -> bool {
        if self.clearing {
            return false;
        }
        let Some(supervisor) = self.supervisor.take() else {
            return false;
        };
        self.clearing = true;
        self.restarting = !move_data;
        self.reset_error = None;
        self.daemon = DaemonPhase::Restarting;
        self.client.set_endpoint(None);
        self.http = None;
        cx.notify();
        let user_data = self.paths.user_data.clone();
        let (tx, rx) = futures::channel::oneshot::channel();
        runtime::shared().spawn(async move {
            let outcome = supervisor.stop().await;
            let _ = tx.send(outcome);
        });
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let stopped = rx.await;
            log::info!("daemon stopped for a restart: {stopped:?}");
            if !hold.is_zero() {
                cx.background_executor().timer(hold).await;
            }
            let moved = move_data.then(|| move_aside(&user_data, SystemTime::now()));
            let _ = this.update(cx, |s, cx| {
                s.clearing = false;
                s.restarting = false;
                match moved {
                    Some(Ok(moved_to)) => {
                        log::warn!("cleared local data: moved to {}", moved_to.display());
                        cx.emit(ConnectionEvent::LocalDataReset { moved_to });
                    }
                    Some(Err(e)) => {
                        log::warn!("clear local data: {e}");
                        s.reset_error = Some(e.to_string());
                    }
                    None => {}
                }
                s.spawn_supervisor(cx);
                cx.notify();
            });
        })
        .detach();
        true
    }

    /// `system.exportDiagnostics`, then reveal the zip in Finder.
    pub fn export_diagnostics(&mut self, cx: &mut Context<Self>) {
        if self.diagnostics == Diagnostics::Exporting {
            return;
        }
        self.diagnostics = Diagnostics::Exporting;
        let call = self
            .client
            .call::<methods::SystemExportDiagnostics>(&NoParams);
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result = call.await;
            let _ = this.update(cx, |s, cx| {
                s.diagnostics = match result {
                    Ok(export) => {
                        let path = PathBuf::from(export.path);
                        cx.reveal_path(&path);
                        Diagnostics::Saved(path)
                    }
                    Err(e) => Diagnostics::Failed(e.to_string()),
                };
                cx.notify();
            });
        })
        .detach();
        cx.notify();
    }

    /// Stops the daemon (stdin EOF → SIGTERM → SIGKILL) and closes the
    /// connection. Blocks: called on quit.
    pub fn shutdown(&mut self) {
        self.client.shutdown();
        if let Some(s) = self.supervisor.take() {
            let outcome = s.stop_blocking();
            log::info!("daemon stopped: {outcome:?}");
        }
    }
}

fn describe_state(state: &ConnectionState) -> String {
    match state {
        ConnectionState::Connected(h) => format!(
            "connected (daemon {}, protocol {}, needsOnboarding {:?})",
            h.daemon_version, h.protocol_version, h.needs_onboarding
        ),
        other => format!("{other:?}"),
    }
}

/// Drains a tokio channel into the store on the UI thread.
fn pump<E: Send + 'static>(
    cx: &mut Context<ConnectionStore>,
    mut rx: tokio::sync::mpsc::UnboundedReceiver<E>,
    handle: impl Fn(&mut ConnectionStore, E, &mut Context<ConnectionStore>) + 'static,
) {
    cx.spawn(
        async move |this: WeakEntity<ConnectionStore>, cx: &mut AsyncApp| {
            while let Some(event) = rx.recv().await {
                if this.update(cx, |s, cx| handle(s, event, cx)).is_err() {
                    break;
                }
            }
        },
    )
    .detach();
}

#[cfg(test)]
mod tests {
    use super::*;
    use conduit_daemon::rpc::Handshake;
    use conduit_daemon::secrets::SecretError;
    use serde_json::json;
    use std::path::Path;

    fn connected() -> ConnectionState {
        ConnectionState::Connected(Handshake {
            protocol_version: "1.50.0".into(),
            daemon_version: "0.1.0".into(),
            session_id: "s".into(),
            platform: "macos".into(),
            needs_onboarding: Some(false),
            response: None,
            raw: json!({}),
        })
    }

    fn status(daemon: DaemonPhase, rpc: ConnectionState, routed: bool, ever: bool) -> Status {
        derive_status(None, &daemon, &rpc, routed, None, ever)
    }

    #[test]
    fn first_start_is_connecting_then_core_starting_then_connected() {
        assert_eq!(
            status(
                DaemonPhase::Starting,
                ConnectionState::WaitingForDaemon,
                false,
                false
            ),
            Status::Connecting
        );
        let running = DaemonPhase::Running { pid: 1, port: 2 };
        assert_eq!(
            status(
                running.clone(),
                ConnectionState::Connecting { attempt: 1 },
                false,
                false
            ),
            Status::Connecting
        );
        assert_eq!(
            status(running.clone(), connected(), false, true),
            Status::CoreStarting
        );
        assert_eq!(status(running, connected(), true, true), Status::Connected);
    }

    #[test]
    fn fatal_states_win() {
        assert_eq!(
            status(
                DaemonPhase::Fatal(FatalReason::SecureStoreUnreadable),
                connected(),
                true,
                true
            ),
            Status::StoreUnreadable
        );
        assert!(matches!(
            status(
                DaemonPhase::Fatal(FatalReason::TooManyRestarts { restarts: 5 }),
                ConnectionState::WaitingForDaemon,
                true,
                true
            ),
            Status::Failed { .. }
        ));
        assert_eq!(
            status(
                DaemonPhase::Running { pid: 1, port: 2 },
                ConnectionState::VersionMismatch {
                    daemon: "1".into(),
                    app: "2".into()
                },
                false,
                false
            ),
            Status::VersionMismatch {
                daemon: "1".into(),
                app: "2".into()
            }
        );
        assert!(matches!(
            derive_status(
                Some("keychain: denied"),
                &DaemonPhase::Starting,
                &ConnectionState::WaitingForDaemon,
                false,
                None,
                false
            ),
            Status::Failed { .. }
        ));
    }

    #[test]
    fn a_restart_after_connecting_is_a_reconnect() {
        assert_eq!(
            status(
                DaemonPhase::Restarting,
                ConnectionState::WaitingForDaemon,
                true,
                true
            ),
            Status::Reconnecting { attempt: 1 }
        );
        assert_eq!(
            status(
                DaemonPhase::Running { pid: 1, port: 2 },
                ConnectionState::Reconnecting {
                    attempt: 3,
                    delay: Default::default(),
                    error: String::new()
                },
                true,
                true
            ),
            Status::Reconnecting { attempt: 3 }
        );
    }

    #[test]
    fn a_failed_session_is_a_failure_until_the_route_is_known() {
        let running = DaemonPhase::Running { pid: 1, port: 2 };
        assert!(matches!(
            derive_status(
                None,
                &running,
                &connected(),
                false,
                Some("rpc.daemonUnavailable"),
                true
            ),
            Status::Failed { .. }
        ));
        assert_eq!(
            derive_status(None, &running, &connected(), true, Some("x"), true),
            Status::Connected
        );
    }

    #[test]
    fn only_fatal_or_unrouted_states_replace_the_content() {
        assert!(Status::StoreUnreadable.blocks(true));
        assert!(
            Status::KeychainPrompt {
                busy: false,
                failures: 0
            }
            .blocks(true)
        );
        assert!(Status::Connecting.blocks(false));
        assert!(!Status::Reconnecting { attempt: 2 }.blocks(true));
        assert!(!Status::Connected.blocks(false));
    }

    /// A follower leaves by subscribing its key to nothing (Computer does when
    /// its window closes): the key goes, so the follower can come back later
    /// with its events, as Computer does when it opens again.
    #[gpui_kit::test]
    fn a_follower_leaves_by_subscribing_to_nothing(cx: &mut gpui_kit::TestAppContext) {
        let scratch =
            std::env::temp_dir().join(format!("conduit-connection-follow-{}", std::process::id()));
        let connection = cx.update(|cx| {
            ConnectionStore::start(
                ConnectionOptions {
                    paths: AppPaths {
                        flavor: conduit_daemon::paths::Flavor::Dev,
                        user_data: scratch.join("user-data"),
                        logs: scratch.join("logs"),
                    },
                    binary: PathBuf::from("/nonexistent/conduitd"),
                    master_key: MasterKey::Failed("test".into()),
                    locale: "en".into(),
                    client_version: "0".into(),
                },
                cx,
            )
        });
        let follows = [events::TURN_STARTED, events::TURN_FINISHED];
        connection.update(cx, |c, _| {
            c.subscribe("computer", &follows, vec!["chat-1".into()]);
            c.subscribe("computer", &[], vec![]);
            assert!(!c.subscriptions.contains_key("computer"));
            c.subscribe("computer", &follows, vec!["chat-2".into()]);
            assert_eq!(
                c.subscriptions.get("computer"),
                Some(&(follows.to_vec(), vec!["chat-2".to_string()]))
            );
        });
    }

    /// A keychain whose key another build stored: reading it needs macOS's
    /// prompt, which gives the key when `answers` (else as Deny does). The
    /// next `refused_adds` adds fail (a keychain that locked meanwhile).
    struct OtherBuildsKeychain {
        items: std::sync::Mutex<BTreeMap<String, String>>,
        answers: bool,
        refused_adds: std::sync::Mutex<u32>,
    }

    impl OtherBuildsKeychain {
        fn new(answers: bool) -> Arc<Self> {
            Arc::new(Self {
                items: std::sync::Mutex::new(BTreeMap::from([(
                    secrets::MASTER_KEY_ACCOUNT.to_string(),
                    secrets::new_master_key(),
                )])),
                answers,
                refused_adds: Default::default(),
            })
        }

        fn key(&self, account: &str) -> Option<String> {
            self.items.lock().unwrap().get(account).cloned()
        }
    }

    struct OtherBuildsItem<'a>(&'a OtherBuildsKeychain, String);

    impl secrets::MasterKeyStore for OtherBuildsItem<'_> {
        fn load(&self) -> Result<Option<String>, SecretError> {
            match self.0.key(&self.1) {
                Some(_) if self.1 == secrets::MASTER_KEY_ACCOUNT && !self.0.answers => {
                    Err(SecretError::Store("the user denied access (-128)".into()))
                }
                key => Ok(key),
            }
        }

        fn load_without_asking(&self) -> Result<Option<String>, SecretError> {
            match self.0.key(&self.1) {
                Some(_) if self.1 == secrets::MASTER_KEY_ACCOUNT => Err(SecretError::WouldPrompt),
                key => Ok(key),
            }
        }

        fn add(&self, key: &str) -> Result<bool, SecretError> {
            let mut refused = self.0.refused_adds.lock().unwrap();
            if *refused > 0 {
                *refused -= 1;
                return Err(SecretError::Store("the keychain is locked (-25308)".into()));
            }
            let mut items = self.0.items.lock().unwrap();
            if items.contains_key(&self.1) {
                return Ok(false);
            }
            items.insert(self.1.clone(), key.to_string());
            Ok(true)
        }
    }

    impl MasterKeyItems for OtherBuildsKeychain {
        fn accounts(&self) -> Result<Vec<String>, SecretError> {
            Ok(self.items.lock().unwrap().keys().cloned().collect())
        }

        fn item(&self, account: &str) -> Box<dyn secrets::MasterKeyStore + '_> {
            Box::new(OtherBuildsItem(self, account.to_string()))
        }
    }

    /// A store asking about `keychain`'s `masterKey`, its profile under
    /// `profiles` and everything else (the lock, the logs) under `own`.
    fn start_with(
        keychain: Arc<OtherBuildsKeychain>,
        profiles: &Path,
        own: &Path,
        cx: &mut gpui_kit::TestAppContext,
    ) -> Entity<ConnectionStore> {
        cx.update(|cx| {
            ConnectionStore::start(
                ConnectionOptions {
                    paths: AppPaths {
                        flavor: conduit_daemon::paths::Flavor::Production,
                        user_data: profiles.join("user-data"),
                        logs: own.join("logs"),
                    },
                    binary: PathBuf::from("/nonexistent/conduitd"),
                    master_key: MasterKey::WouldPrompt(KeychainChoice {
                        items: keychain,
                        account: secrets::MASTER_KEY_ACCOUNT.into(),
                        lock: own.join("master-key.lock"),
                    }),
                    locale: "en".into(),
                    client_version: "0".into(),
                },
                cx,
            )
        })
    }

    fn card(busy: bool, failures: u32) -> Status {
        Status::KeychainPrompt { busy, failures }
    }

    /// The key a pre-release build stored: the card asks before macOS does,
    /// and conduitd waits for the answer.
    #[gpui_kit::test]
    fn a_key_that_would_prompt_holds_conduitd_for_the_keychain_card(
        cx: &mut gpui_kit::TestAppContext,
    ) {
        let (profiles, own) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
        let keychain = OtherBuildsKeychain::new(true);
        let connection = start_with(keychain, profiles.path(), own.path(), cx);
        connection.update(cx, |c, _| {
            assert_eq!(c.status(false, None), card(false, 0));
            assert!(!c.can_clear(), "conduitd never started");
        });
    }

    /// Deny in macOS's dialog: the card comes back saying so, and a choice
    /// made while the first one runs is ignored.
    #[gpui_kit::test]
    fn a_continue_macos_refuses_brings_the_card_back_with_the_failed_line(
        cx: &mut gpui_kit::TestAppContext,
    ) {
        let (profiles, own) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
        let keychain = OtherBuildsKeychain::new(false);
        let connection = start_with(keychain.clone(), profiles.path(), own.path(), cx);
        connection.update(cx, |c, cx| {
            c.keychain_continue(cx);
            c.keychain_start_fresh(cx);
            assert_eq!(c.status(false, None), card(true, 0));
        });
        cx.run_until_parked();
        connection.update(cx, |c, _| {
            assert_eq!(c.status(false, None), card(false, 1));
            assert!(!c.can_clear(), "conduitd still waits");
        });
        assert_eq!(
            keychain.accounts().unwrap(),
            [secrets::MASTER_KEY_ACCOUNT],
            "Start Fresh never ran"
        );
    }

    /// The keychain refuses Start Fresh's new key once (it locked after the
    /// card appeared): the card stays, with its choices and the failed
    /// line, and the next Start Fresh starts conduitd with its key.
    #[gpui_kit::test]
    fn a_start_fresh_the_keychain_refuses_keeps_the_card_for_another_try(
        cx: &mut gpui_kit::TestAppContext,
    ) {
        let (profiles, own) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
        let keychain = OtherBuildsKeychain::new(true);
        *keychain.refused_adds.lock().unwrap() = 1;
        let connection = start_with(keychain.clone(), profiles.path(), own.path(), cx);
        connection.update(cx, |c, cx| c.keychain_start_fresh(cx));
        cx.run_until_parked();
        connection.update(cx, |c, _| {
            assert_eq!(c.status(false, None), card(false, 1));
            assert!(!c.can_clear(), "conduitd still waits");
        });
        connection.update(cx, |c, cx| c.keychain_start_fresh(cx));
        cx.run_until_parked();
        connection.update(cx, |c, _| {
            assert!(c.can_clear(), "conduitd started");
            assert_eq!(c.master_key, keychain.key("masterKey.2"));
            assert_ne!(c.status(false, None), card(false, 1));
        });
    }

    /// The profile can't be moved aside: conduitd stays stopped (a profile
    /// without a secure store would otherwise open as it was), the card
    /// says so, and its Start Fresh moves the profile once it can and
    /// starts conduitd with one new key.
    #[cfg(unix)]
    #[gpui_kit::test]
    fn a_profile_that_cannot_move_keeps_conduitd_stopped_until_it_moves(
        cx: &mut gpui_kit::TestAppContext,
    ) {
        use std::os::unix::fs::PermissionsExt as _;
        let (profiles, own) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
        let user_data = profiles.path().join("user-data");
        std::fs::create_dir_all(user_data.join("db")).unwrap();
        std::fs::write(user_data.join("db/server.sqlite"), b"old chats").unwrap();
        let keychain = OtherBuildsKeychain::new(true);
        let connection = start_with(keychain.clone(), profiles.path(), own.path(), cx);
        let mode = |m| std::fs::Permissions::from_mode(m);
        std::fs::set_permissions(profiles.path(), mode(0o555)).unwrap();
        connection.update(cx, |c, cx| c.keychain_start_fresh(cx));
        cx.run_until_parked();
        std::fs::set_permissions(profiles.path(), mode(0o755)).unwrap();
        connection.update(cx, |c, _| {
            assert_eq!(c.status(false, None), card(false, 1));
            assert!(c.reset_error.is_some(), "the card says the move failed");
            assert!(!c.can_clear(), "conduitd still waits");
        });
        assert_eq!(
            keychain.accounts().unwrap(),
            [secrets::MASTER_KEY_ACCOUNT],
            "no key for a profile that stayed"
        );
        assert!(user_data.join("db/server.sqlite").exists());
        connection.update(cx, |c, cx| c.keychain_start_fresh(cx));
        cx.run_until_parked();
        connection.update(cx, |c, _| {
            assert!(c.can_clear(), "conduitd started");
            assert_eq!(c.master_key, keychain.key("masterKey.2"));
            assert!(c.reset_error.is_none());
        });
        assert_eq!(
            keychain.accounts().unwrap(),
            [secrets::MASTER_KEY_ACCOUNT, "masterKey.2"]
        );
        assert!(!user_data.join("db").exists(), "moved aside");
        assert_eq!(secrets::profile_key_account(&user_data), "masterKey.2");
    }
}
