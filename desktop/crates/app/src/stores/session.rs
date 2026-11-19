//! The session: who is signed in where, and where the window goes.
//!
//! Holds the auth snapshot (`auth.status`), the active server's live status
//! (`servers.status`), the Direct connections and the Hermes connection (for
//! the direct-only and Hermes-only signals), and the core's onboarding
//! answer. The account list and the active account live in
//! [`AccountsStore`], which this observes.
//!
//! **Tri-state routing.** [`Route::Unknown`] until every input is known, so
//! the window never redirects on a guess. The handshake's `needsOnboarding`
//! is not routed on: while the core is still starting the daemon answers
//! `false` as a guess. The core is asked again after a core-gated call
//! (`accounts.list`, which the client retries through
//! `rpc.daemonUnavailable`) has answered, and that answer, from mobile's own
//! routing policy in the core, routes, together with the account list, the
//! auth snapshot. With no account the core's answer decides alone, as on a
//! phone: a Direct or Hermes setup finished in onboarding is the core's
//! preferred backend (`direct.setPreferred`, `hermes.saveSettings` with
//! `onboarding`), and one chosen but not finished (a gateway still to sign
//! in) is still onboarding. The Direct/Hermes signals pick the backend the
//! main window chats through.
//!
//! Everything is refetched, never patched: on a new daemon session, on
//! `accounts.changed` (through the accounts store), on `hermes.changed` and
//! `capabilities.changed`, and after the window changes something.
//!
//! **Capabilities.** What the active account can use comes from
//! `system.capabilities`, the daemon's reading of the core's rules (the
//! phone's tabs and feature gates), asked again on `capabilities.changed`
//! and with every refresh; the handshake's copy stands in until it
//! answers.
//!
//! **Asked again until it routes.** A daemon that restarted while starting,
//! or a core still restoring the session, answers `loading` or nothing at
//! first, and no event follows when that settles. So while the route is
//! unknown the session asks again, quickly at first, for about half a minute
//! ([`RESOLVE_ATTEMPTS`]). After that, the window shows the last error with
//! Retry instead of "Opening your data" for ever.
//!
//! **Offline.** Routing never waits on the server: the account, its auth and
//! its chats come from what the daemon stored. `servers.status` follows on
//! its own. While it says the server is out of reach, the session asks again
//! every [`SERVER_RECHECK`], and [`SessionEvent::ServerBack`] tells the stores
//! when the server answers again.

use std::time::Duration;

use conduit_daemon::{Handshake, RpcError};
use conduit_protocol::{
    AccountList, AuthPhase, AuthSnapshot, Capabilities, DirectConnectionList, HandshakeRequest,
    HandshakeResponse, HermesSettings, LibreChatSessionPhase, NoParams, PrimaryAccount,
    ServerReachability, ServerStatus, methods,
};
use gpui_kit::{AsyncApp, Context, Entity, EventEmitter, Subscription, Task, WeakEntity};
use serde_json::Value;

use super::accounts::AccountsStore;
use super::rpc::Rpc;

/// How many more times the session asks while the route is unknown before
/// it says why (about 35 s with [`resolve_delay`]).
pub const RESOLVE_ATTEMPTS: u32 = 20;

/// The wait before ask number `attempt` (from 0). It is short at first,
/// because a core restoring a session settles in moments, then 2 s.
pub fn resolve_delay(attempt: u32) -> Duration {
    Duration::from_millis(match attempt {
        0 => 250,
        1 => 500,
        2 => 1000,
        _ => 2000,
    })
}

/// How long to wait before asking about a server that was out of reach.
pub const SERVER_RECHECK: Duration = Duration::from_secs(5);

/// The code of the error shown when the route stayed unknown.
pub const UNRESOLVED: &str = "session.unresolved";

/// What the session tells the stores.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SessionEvent {
    /// The active server answers again after being out of reach. Lists
    /// that were served from what the daemon stored can catch up now.
    ServerBack,
}

/// Where the window sends the user.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Route {
    /// Not known yet: never redirect on a guess.
    Unknown,
    /// No backend chosen yet: the backend chooser.
    Onboarding,
    /// An Open WebUI account is active and needs a sign-in (a first sign-in,
    /// an addition, or an expired session), or the LibreChat account in
    /// charge needs one (its session ended).
    SignIn,
    /// The active Open WebUI account kept its session, but the server turns
    /// it away (a sign-in proxy whose session expired, or a refused
    /// request): the phone's Connection Issue, with Try Again, Sign In to
    /// Proxy Again and Sign Out, never a sign-out of its own.
    ConnectionIssue,
    /// Ready: signed in, or a Direct-only or Hermes-only setup.
    Main,
}

/// What the main window chats through.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Backend {
    OpenWebUi,
    /// A LibreChat account owns the chats.
    LibreChat,
    Direct,
    Hermes,
    /// The reviewer/demo session, with no server.
    Demo,
}

/// The facts a route is decided on.
#[derive(Clone, Copy, Debug, Default)]
pub struct RouteInputs<'a> {
    /// The core's confirmed onboarding answer.
    pub needs_onboarding: Option<bool>,
    pub accounts: Option<&'a AccountList>,
    pub auth: Option<&'a AuthSnapshot>,
    /// The Direct and Hermes answers are in: with no account, they are
    /// what the main window chats through.
    pub backends_known: bool,
}

/// The route for `inputs`; [`Route::Unknown`] while any is missing.
pub fn derive_route(inputs: RouteInputs<'_>) -> Route {
    // Even the handshake's `true` waits for the rest: an account restored
    // here would otherwise flash onboarding on every launch.
    let (Some(accounts), Some(auth)) = (inputs.accounts, inputs.auth) else {
        return Route::Unknown;
    };
    if auth.is_reviewer_mode {
        return Route::Main;
    }
    if accounts.adding_account {
        return Route::SignIn;
    }
    // A LibreChat account owns the chats: its own session routes, and Open
    // WebUI (parked) does not.
    if accounts.primary == PrimaryAccount::LibreChat
        && accounts.active_libre_chat_account_id.is_some()
    {
        return match accounts.libre_chat_session {
            LibreChatSessionPhase::SignedIn => Route::Main,
            LibreChatSessionPhase::NeedsSignIn => Route::SignIn,
            _ => Route::Unknown,
        };
    }
    if accounts.active_account_id.is_some() {
        if auth.is_authenticated {
            return Route::Main;
        }
        return match auth.phase {
            // Restoring a session: wait rather than flash the sign-in form.
            AuthPhase::Initial | AuthPhase::Loading => Route::Unknown,
            _ if auth.is_loading => Route::Unknown,
            // The session is kept: a connection issue, as the phone's router
            // reads an error with a token.
            AuthPhase::Error if auth.has_token => Route::ConnectionIssue,
            _ => Route::SignIn,
        };
    }
    match inputs.needs_onboarding {
        Some(true) => Route::Onboarding,
        // No account, but the core says there is a backend: Direct or
        // Hermes, chosen and ready, once their answers say which.
        Some(false) if inputs.backends_known => Route::Main,
        Some(false) => Route::Unknown,
        None => Route::Unknown,
    }
}

pub struct SessionStore {
    rpc: Rpc,
    accounts: Entity<AccountsStore>,
    pub auth: Option<AuthSnapshot>,
    pub server: Option<ServerStatus>,
    /// The account in charge `auth` and `server` were asked for (its
    /// [`AccountsStore::scope_key`]; `None`: no account). Another account's
    /// are dropped, never routed on: one LibreChat account after another
    /// changes no Open WebUI id.
    facts_for: Option<String>,
    pub direct: Option<DirectConnectionList>,
    pub hermes: Option<HermesSettings>,
    /// `system.capabilities`, once it has answered for this session.
    pub system_capabilities: Option<Capabilities>,
    /// The core's onboarding answer, once confirmed (see the module docs).
    pub needs_onboarding: Option<bool>,
    /// The connect handshake: daemon paths and capabilities.
    pub handshake: Option<HandshakeResponse>,
    /// The account the handshake's capabilities describe: the first one
    /// listed after connecting (`None` until then). Another account never
    /// falls back on them.
    handshake_for: Option<Option<String>>,
    /// What this window handshakes with, to ask the core's onboarding
    /// answer again.
    request: Option<HandshakeRequest>,
    pub error: Option<RpcError>,
    /// Shows `route` instead of the derived one (the `--shots` pass).
    pub preview: Option<Route>,
    /// Every read carries the generation it started in, and its answer
    /// applies only while that is current ([`Self::read`]). A refresh, an
    /// account change or a new daemon session bumps it; a retry keeps it.
    generation: u64,
    /// The account-list signature the last refresh saw.
    seen_accounts: Option<String>,
    /// Asks made since the route was last known ([`RESOLVE_ATTEMPTS`]).
    resolve_attempts: u32,
    /// `direct.list`/`hermes.settings` answers still to come in this
    /// generation: a retry leaves them in flight rather than asking again.
    backends_pending: u8,
    _refresh: Option<Task<()>>,
    _auth: Option<Task<()>>,
    _backends: Vec<Task<()>>,
    _status: Option<Task<()>>,
    _resolve: Option<Task<()>>,
    _recheck: Option<Task<()>>,
    _capabilities: Option<Task<()>>,
    _accounts: Subscription,
}

impl EventEmitter<SessionEvent> for SessionStore {}

fn signature(list: &AccountList) -> String {
    let mut s = format!(
        "{:?}|{}|{:?}|{:?}|{:?}",
        list.active_account_id,
        list.adding_account,
        list.primary,
        list.active_libre_chat_account_id,
        list.libre_chat_session,
    );
    for a in &list.accounts {
        s.push_str(&format!("|{}:{}", a.id, a.has_session));
    }
    for a in &list.libre_chat_accounts {
        s.push_str(&format!("|{}:{}", a.id, a.has_session));
    }
    s
}

impl SessionStore {
    pub fn new(rpc: Rpc, accounts: Entity<AccountsStore>, cx: &mut Context<Self>) -> Self {
        let subscription = cx.observe(&accounts, |this, accounts, cx| {
            let list = accounts.read(cx).list.as_ref();
            let sig = list.map(signature);
            if list.is_some() {
                let in_charge = accounts.read(cx).scope_key();
                this.forget_other_account(in_charge);
            }
            if sig.is_some() && sig != this.seen_accounts {
                this.seen_accounts = sig;
                this.refresh(cx);
            }
            cx.notify();
        });
        Self {
            rpc,
            accounts,
            auth: None,
            server: None,
            facts_for: None,
            direct: None,
            hermes: None,
            system_capabilities: None,
            needs_onboarding: None,
            handshake: None,
            handshake_for: None,
            request: None,
            error: None,
            preview: None,
            generation: 0,
            seen_accounts: None,
            resolve_attempts: 0,
            backends_pending: 0,
            _refresh: None,
            _auth: None,
            _backends: vec![],
            _status: None,
            _resolve: None,
            _recheck: None,
            _capabilities: None,
            _accounts: subscription,
        }
    }

    pub fn accounts(&self) -> &Entity<AccountsStore> {
        &self.accounts
    }

    pub fn route(&self, cx: &gpui_kit::App) -> Route {
        if let Some(route) = self.preview {
            return route;
        }
        derive_route(RouteInputs {
            needs_onboarding: self.needs_onboarding,
            accounts: self.accounts.read(cx).list.as_ref(),
            auth: self.auth.as_ref(),
            backends_known: self.direct.is_some() && self.hermes.is_some(),
        })
    }

    /// Direct connections chosen and usable, with no Open WebUI account.
    pub fn direct_only(&self, cx: &gpui_kit::App) -> bool {
        self.accounts.read(cx).active().is_none()
            && !self.accounts.read(cx).libre_chat_in_charge()
            && self
                .direct
                .as_ref()
                .is_some_and(|d| d.preferred && d.usable)
    }

    /// Hermes usable, with no Open WebUI account and no Direct preference.
    pub fn hermes_only(&self, cx: &gpui_kit::App) -> bool {
        self.accounts.read(cx).active().is_none()
            && !self.accounts.read(cx).libre_chat_in_charge()
            && !self.direct_only(cx)
            && self.hermes.as_ref().is_some_and(|h| h.usable)
    }

    pub fn backend(&self, cx: &gpui_kit::App) -> Option<Backend> {
        if self.auth.as_ref().is_some_and(|a| a.is_reviewer_mode) {
            return Some(Backend::Demo);
        }
        if self.accounts.read(cx).libre_chat_in_charge()
            && self.accounts.read(cx).libre_chat_active().is_some()
        {
            return Some(Backend::LibreChat);
        }
        if self.accounts.read(cx).active().is_some() {
            return Some(Backend::OpenWebUi);
        }
        if self.direct_only(cx) {
            return Some(Backend::Direct);
        }
        if self.hermes_only(cx) {
            return Some(Backend::Hermes);
        }
        None
    }

    /// The active Open WebUI server is out of reach, as `servers.status`
    /// last said. The window still shows what the daemon stored.
    pub fn server_unreachable(&self, cx: &gpui_kit::App) -> bool {
        self.backend(cx) == Some(Backend::OpenWebUi)
            && self
                .server
                .as_ref()
                .is_some_and(|s| s.reachability == ServerReachability::Unreachable)
    }

    /// What the active account can use: `system.capabilities`, else the
    /// server status's or the handshake's copy until it answers.
    pub fn capabilities(&self) -> Capabilities {
        self.system_capabilities
            .clone()
            .or_else(|| self.server.as_ref().map(|s| s.capabilities.clone()))
            .or_else(|| {
                self.handshake
                    .as_ref()
                    .filter(|_| self.handshake_for.as_ref() == Some(&self.facts_for))
                    .map(|h| h.capabilities.clone())
            })
            .unwrap_or_default()
    }

    /// Drops the auth snapshot and server status when they were asked for
    /// another account in charge than `active`: the route waits for the new
    /// account's own answers rather than pairing it with the last one's.
    fn forget_other_account(&mut self, active: Option<String>) {
        if self.handshake_for.is_none() {
            self.handshake_for = Some(active.clone());
        }
        if self.facts_for != active {
            self.facts_for = active;
            self.auth = None;
            self.server = None;
            self.system_capabilities = None;
            self._status = None;
            self._recheck = None;
            self._capabilities = None;
        }
    }

    /// Asks `system.capabilities` again (`capabilities.changed`).
    pub fn refresh_capabilities(&mut self, cx: &mut Context<Self>) {
        let call = self.rpc.call::<methods::SystemCapabilities>(&NoParams);
        self._capabilities = Some(self.read(
            call,
            |s, result, cx| match result {
                Ok(capabilities) => {
                    if s.system_capabilities.as_ref() != Some(&capabilities) {
                        s.system_capabilities = Some(capabilities);
                        cx.notify();
                    }
                }
                Err(e) => log::warn!("system.capabilities: {e}"),
            },
            cx,
        ));
    }

    /// A new daemon session: forget everything and ask again. Only a `true`
    /// onboarding answer from the handshake is taken as it is.
    pub fn on_connected(
        &mut self,
        handshake: &Handshake,
        request: HandshakeRequest,
        cx: &mut Context<Self>,
    ) {
        self.request = Some(request);
        self.auth = None;
        self.server = None;
        self.direct = None;
        self.hermes = None;
        self.system_capabilities = None;
        self.error = None;
        self.seen_accounts = None;
        self._recheck = None;
        self._capabilities = None;
        self.handshake = handshake.response.as_deref().cloned();
        self.handshake_for = None;
        self.needs_onboarding = (handshake.needs_onboarding == Some(true)).then_some(true);
        self.accounts.update(cx, |a, cx| {
            a.reset(cx);
            a.refresh(cx);
        });
        self.refresh(cx);
        cx.notify();
    }

    /// Refetches the session in a new generation: once `accounts.list` has
    /// answered (the core is up), `auth.status`, `direct.list`,
    /// `hermes.settings` and the core's onboarding answer; `servers.status`
    /// follows on its own, since it costs a request to the server. Asks
    /// again while the route stays unknown (see the module docs), with a
    /// fresh count of attempts.
    pub fn refresh(&mut self, cx: &mut Context<Self>) {
        self.resolve_attempts = 0;
        if self.route(cx) == Route::Unknown {
            // Retry after giving up: "Opening your data" again, not the
            // old error, while it asks.
            self.error = None;
            cx.notify();
        }
        self.generation += 1;
        self._refresh = None;
        self._auth = None;
        self._backends = vec![];
        self.backends_pending = 0;
        self._status = None;
        self._resolve = None;
        // A check of an out-of-reach server dropped with the old generation:
        // keep checking, or it is never seen coming back.
        if self.server_unreachable_now() {
            self.recheck_server(cx);
        }
        self.fetch(cx);
    }

    /// Starts `read` in the current generation; `apply` gets its answer only
    /// if that generation is still current then. Every read of this store
    /// goes through here.
    fn read<T: 'static>(
        &self,
        read: impl std::future::Future<Output = T> + 'static,
        apply: impl FnOnce(&mut Self, T, &mut Context<Self>) + 'static,
        cx: &mut Context<Self>,
    ) -> Task<()> {
        let generation = self.generation;
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let answer = read.await;
            let _ = this.update(cx, |s, cx| {
                if s.generation == generation {
                    apply(s, answer, cx);
                }
            });
        })
    }

    /// One attempt in the current generation (a first ask or a retry).
    fn fetch(&mut self, cx: &mut Context<Self>) {
        let accounts = self.rpc.call::<methods::AccountsList>(&NoParams);
        self._refresh = Some(self.read(
            accounts,
            |s, answer, cx| match answer {
                Ok(list) => s.accounts_listed(list, cx),
                Err(e) => {
                    log::warn!("session: core not answering: {e}");
                    s.keep_resolving(Some(e), cx);
                }
            },
            cx,
        ));
    }

    /// The daemon's account list, which the accounts store shows too (its
    /// own fetch may have failed while the core started). Account-scoped
    /// reads start only once the store shows this list.
    fn accounts_listed(&mut self, list: AccountList, cx: &mut Context<Self>) {
        let seen = self.seen_accounts.replace(signature(&list));
        if !self.accounts.update(cx, |a, cx| a.adopt(list, cx)) {
            // A change of the accounts store is in flight: the list it shows
            // afterwards refreshes the session, or the retry asks again.
            self.seen_accounts = seen;
            self.keep_resolving(None, cx);
            return;
        }
        let in_charge = self.accounts.read(cx).scope_key();
        self.forget_other_account(in_charge);
        let auth = self.rpc.call::<methods::AuthStatus>(&NoParams);
        // Asked again now that the core is up: its own answer.
        let rpc = self.rpc.clone();
        let request = self.request.clone();
        let onboarding = async move {
            match &request {
                Some(request) => rpc.call::<OnboardingProbe>(request).await,
                None => Ok(Value::Null),
            }
        };
        self._auth = Some(self.read(
            async move { futures::join!(auth, onboarding) },
            |s, (auth, onboarding), cx| {
                s.error = None;
                let mut failed = None;
                match auth {
                    Ok(a) => s.auth = Some(a),
                    Err(e) => failed = Some(e),
                }
                match onboarding {
                    Ok(v) => {
                        if let Some(needs) = v.get("needsOnboarding").and_then(Value::as_bool) {
                            s.needs_onboarding = Some(needs);
                        }
                    }
                    Err(e) => failed = failed.or(Some(e)),
                }
                s.refresh_server(cx);
                s.refresh_capabilities(cx);
                s.keep_resolving(failed, cx);
                cx.notify();
            },
            cx,
        ));
        // A retry leaves backend reads of this generation in flight: a
        // backend slower than the retries would otherwise never land.
        if self.backends_pending == 0 {
            self.read_backends(cx);
        }
    }

    /// While the route is unknown, asks again after [`resolve_delay`], in the
    /// same generation; after [`RESOLVE_ATTEMPTS`], shows why. A known route
    /// ends the asking.
    fn keep_resolving(&mut self, failed: Option<RpcError>, cx: &mut Context<Self>) {
        if self.preview.is_some() || self.route(cx) != Route::Unknown {
            self.resolve_attempts = 0;
            self._resolve = None;
            return;
        }
        if self.resolve_attempts >= RESOLVE_ATTEMPTS {
            log::warn!("session: still no route after {RESOLVE_ATTEMPTS} attempts");
            self.error = Some(failed.unwrap_or_else(|| {
                conduit_daemon::protocol::error(
                    UNRESOLVED,
                    "the core did not finish opening the account",
                )
            }));
            cx.notify();
            return;
        }
        let delay = resolve_delay(self.resolve_attempts);
        self.resolve_attempts += 1;
        let timer = cx.background_executor().timer(delay);
        self._resolve = Some(self.read(timer, |s, _, cx| s.fetch(cx), cx));
    }

    /// Refetches `servers.status` (reachability, version, capabilities).
    pub fn refresh_server(&mut self, cx: &mut Context<Self>) {
        let call = self.rpc.call::<methods::ServersStatus>(&NoParams);
        self._status = Some(self.read(
            call,
            |s, result, cx| {
                match result {
                    Ok(status) => s.adopt_server(status, cx),
                    Err(e) => {
                        log::warn!("servers.status: {e}");
                        // Out of reach still, as far as we know: keep
                        // checking, or it is never seen coming back.
                        if s.server_unreachable_now() {
                            s.recheck_server(cx);
                        }
                    }
                }
                cx.notify();
            },
            cx,
        ));
    }

    /// The last `servers.status` answer said out of reach.
    fn server_unreachable_now(&self) -> bool {
        self.server
            .as_ref()
            .is_some_and(|s| s.reachability == ServerReachability::Unreachable)
    }

    /// Takes a `servers.status` answer. Out of reach: asked again after
    /// [`SERVER_RECHECK`]. Back from that: [`SessionEvent::ServerBack`].
    fn adopt_server(&mut self, status: ServerStatus, cx: &mut Context<Self>) {
        let was_unreachable = self.server_unreachable_now();
        let unreachable = status.reachability == ServerReachability::Unreachable;
        let back = was_unreachable && status.reachability == ServerReachability::Reachable;
        self.server = Some(status);
        if unreachable {
            self.recheck_server(cx);
        } else {
            self._recheck = None;
        }
        if back {
            log::info!("session: the server answers again");
            cx.emit(SessionEvent::ServerBack);
        }
    }

    /// `direct.list` and `hermes.settings` may wait on a server: each lands
    /// as soon as it answers, and neither holds back the other.
    fn read_backends(&mut self, cx: &mut Context<Self>) {
        self.backends_pending = 2;
        let direct = self.rpc.call::<methods::DirectList>(&NoParams);
        let hermes = self.rpc.call::<methods::HermesSettings>(&NoParams);
        self._backends = vec![
            self.read(
                direct,
                |s, direct, cx| {
                    s.direct = keep_on_error(s.direct.take(), direct);
                    s.backend_landed(cx);
                },
                cx,
            ),
            self.read(
                hermes,
                |s, hermes, cx| {
                    s.hermes = keep_on_error(s.hermes.take(), hermes);
                    s.backend_landed(cx);
                },
                cx,
            ),
        ];
    }

    /// A Direct or Hermes answer came (a daemon without one answers as
    /// none; a failed read keeps the last answer): it may have been what
    /// the route waited for.
    fn backend_landed(&mut self, cx: &mut Context<Self>) {
        self.backends_pending = self.backends_pending.saturating_sub(1);
        if self.route(cx) != Route::Unknown {
            self.resolve_attempts = 0;
            self._resolve = None;
        }
        cx.notify();
    }

    /// Asks `servers.status` again after [`SERVER_RECHECK`]. The timer spans
    /// generations; the read it starts is the current one's.
    fn recheck_server(&mut self, cx: &mut Context<Self>) {
        self._recheck = Some(
            cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
                cx.background_executor().timer(SERVER_RECHECK).await;
                let _ = this.update(cx, |s, cx| s.refresh_server(cx));
            }),
        );
    }

    /// Adopts an auth snapshot the daemon answered a sign-in with, then
    /// refetches the rest (the account list changes with it).
    pub fn adopt_auth(&mut self, snapshot: AuthSnapshot, cx: &mut Context<Self>) {
        self.auth = Some(snapshot);
        cx.notify();
        self.accounts.update(cx, |a, cx| a.refresh(cx));
        self.refresh(cx);
    }

    /// Shows `route` without asking the daemon (the `--shots` pass).
    pub fn preview_route(&mut self, route: Option<Route>, cx: &mut Context<Self>) {
        self.preview = route;
        cx.notify();
    }
}

/// The new answer, or on an error the last one (none yet: the default).
fn keep_on_error<T: Default>(last: Option<T>, answer: Result<T, RpcError>) -> Option<T> {
    match answer {
        Ok(value) => Some(value),
        Err(e) => {
            log::warn!("session: {e}");
            Some(last.unwrap_or_default())
        }
    }
}

/// `system.handshake` again, for the core's onboarding answer: the reply is
/// read as a value because only `needsOnboarding` matters here, and a
/// missing one must stay unknown rather than read as `false`.
struct OnboardingProbe;

impl conduit_protocol::RpcMethod for OnboardingProbe {
    const NAME: &'static str = <methods::SystemHandshake as conduit_protocol::RpcMethod>::NAME;
    type Params = HandshakeRequest;
    type Result = Value;
}

#[cfg(test)]
pub(crate) mod tests {
    use std::collections::BTreeMap;

    use gpui_kit::{AppContext as _, TestAppContext};
    use serde_json::json;

    use super::*;
    use crate::stores::accounts::AccountChange;
    use crate::stores::accounts::tests::{account, list};
    use crate::stores::rpc::fake::FakeDaemon;

    pub(crate) fn auth(phase: AuthPhase, authenticated: bool) -> AuthSnapshot {
        AuthSnapshot {
            phase,
            is_authenticated: authenticated,
            is_loading: false,
            has_token: authenticated,
            user: None,
            error_code: None,
            error_args: BTreeMap::new(),
            is_reviewer_mode: false,
            two_step: None,
            can_renew_proxy: false,
        }
    }

    fn route(onb: Option<bool>, accounts: Option<&AccountList>, a: Option<&AuthSnapshot>) -> Route {
        derive_route(RouteInputs {
            needs_onboarding: onb,
            accounts,
            auth: a,
            backends_known: true,
        })
    }

    #[test]
    fn unknown_until_every_input_is_known() {
        let signed_in = auth(AuthPhase::Authenticated, true);
        let one = list(vec![account("a", "Avery", true, true)]);
        assert_eq!(route(None, None, None), Route::Unknown);
        assert_eq!(route(Some(false), None, Some(&signed_in)), Route::Unknown);
        assert_eq!(route(Some(false), Some(&one), None), Route::Unknown);
        // Not even the handshake's `true` routes on its own.
        assert_eq!(route(Some(true), None, None), Route::Unknown);
    }

    #[test]
    fn a_signed_in_account_goes_to_main() {
        let one = list(vec![account("a", "Avery", true, true)]);
        let signed_in = auth(AuthPhase::Authenticated, true);
        assert_eq!(
            route(Some(false), Some(&one), Some(&signed_in)),
            Route::Main
        );
        // Even if the onboarding answer is stale.
        assert_eq!(route(Some(true), Some(&one), Some(&signed_in)), Route::Main);
    }

    #[test]
    fn an_active_account_without_a_session_signs_in() {
        let one = list(vec![account("a", "Avery", true, false)]);
        for phase in [
            AuthPhase::Unauthenticated,
            AuthPhase::TokenExpired,
            AuthPhase::CredentialError,
            AuthPhase::Error,
        ] {
            assert_eq!(
                route(Some(false), Some(&one), Some(&auth(phase, false))),
                Route::SignIn,
                "{phase:?}"
            );
        }
        // Restoring: no guess.
        for phase in [AuthPhase::Initial, AuthPhase::Loading] {
            assert_eq!(
                route(Some(false), Some(&one), Some(&auth(phase, false))),
                Route::Unknown
            );
        }
    }

    #[test]
    fn a_kept_session_the_server_turns_away_is_a_connection_issue() {
        let one = list(vec![account("a", "Avery", true, true)]);
        let mut issue = auth(AuthPhase::Error, false);
        issue.has_token = true;
        assert_eq!(
            route(Some(false), Some(&one), Some(&issue)),
            Route::ConnectionIssue
        );
        // Without the session it is a sign-in, as before.
        issue.has_token = false;
        assert_eq!(route(Some(false), Some(&one), Some(&issue)), Route::SignIn);
        // A session expired outright asks for the sign-in again.
        let mut expired = auth(AuthPhase::TokenExpired, false);
        expired.has_token = true;
        assert_eq!(
            route(Some(false), Some(&one), Some(&expired)),
            Route::SignIn
        );
    }

    #[test]
    fn adding_an_account_signs_in_even_while_signed_in() {
        let mut adding = list(vec![
            account("a", "Avery", false, true),
            account("n", "New", true, false),
        ]);
        adding.adding_account = true;
        let signed_in = auth(AuthPhase::Authenticated, true);
        assert_eq!(
            route(Some(false), Some(&adding), Some(&signed_in)),
            Route::SignIn
        );
    }

    #[test]
    fn no_account_follows_the_core() {
        let none = list(vec![]);
        let out = auth(AuthPhase::Unauthenticated, false);
        assert_eq!(
            route(Some(true), Some(&none), Some(&out)),
            Route::Onboarding
        );
        // Direct-only or Hermes-only: the core says there is a backend.
        assert_eq!(route(Some(false), Some(&none), Some(&out)), Route::Main);
        assert_eq!(route(None, Some(&none), Some(&out)), Route::Unknown);
        let mut demo = out.clone();
        demo.is_reviewer_mode = true;
        assert_eq!(route(Some(true), Some(&none), Some(&demo)), Route::Main);
        // A Hermes or Direct setup the core says is chosen and ready is Main
        // only once the account list and auth are known.
        assert_eq!(route(Some(false), None, Some(&out)), Route::Unknown);
    }

    pub(crate) fn handshake(needs: Option<bool>) -> Handshake {
        let mut raw = json!({
            "protocolVersion": conduit_protocol::PROTOCOL_VERSION,
            "daemonVersion": "0.1.0",
            "sessionId": "s",
            "platform": "macos",
            "capabilities": {},
            "paths": {"userData": "/u", "database": "/d", "cache": "/c", "logs": "/l", "staging": "/s"},
        });
        if let Some(n) = needs {
            raw["needsOnboarding"] = json!(n);
        }
        Handshake::from_value(raw)
    }

    pub(crate) fn request() -> HandshakeRequest {
        HandshakeRequest {
            protocol_version: conduit_protocol::PROTOCOL_VERSION.into(),
            client_name: "test".into(),
            client_version: "0".into(),
            window_kind: conduit_protocol::WindowKind::Main,
            locale: "en".into(),
        }
    }

    fn session(cx: &mut TestAppContext, daemon: &FakeDaemon) -> Entity<SessionStore> {
        let rpc = daemon.rpc();
        let accounts = cx.new(|_| AccountsStore::new(rpc.clone()));
        cx.new(|cx| SessionStore::new(rpc, accounts, cx))
    }

    #[gpui_kit::test]
    fn an_early_false_is_not_trusted_until_the_core_confirms(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        // The core is still starting: every core-gated call fails.
        daemon.on::<methods::AccountsList>(|_| {
            Err(conduit_daemon::protocol::error(
                "rpc.daemonUnavailable",
                "starting",
            ))
        });
        let store = session(cx, &daemon);
        store.update(cx, |s, cx| {
            s.on_connected(&handshake(Some(false)), request(), cx)
        });
        cx.run_until_parked();
        assert_eq!(store.read_with(cx, |s, cx| s.route(cx)), Route::Unknown);

        // Up: no account, and the core's own answer is "onboard".
        daemon.returns::<methods::AccountsList>(list(vec![]));
        daemon.returns::<methods::AuthStatus>(auth(AuthPhase::Unauthenticated, false));
        daemon.on::<OnboardingProbe>(|_| Ok(json!({"needsOnboarding": true})));
        store.update(cx, |s, cx| s.refresh(cx));
        cx.run_until_parked();
        assert_eq!(store.read_with(cx, |s, cx| s.route(cx)), Route::Onboarding);
        assert!(
            daemon
                .log()
                .iter()
                .filter(|m| **m == "system.handshake")
                .count()
                >= 1,
            "asked the core again"
        );
    }

    #[gpui_kit::test]
    fn a_true_handshake_still_waits_for_the_core(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        daemon.on::<methods::AccountsList>(|_| {
            Err(conduit_daemon::protocol::error(
                "rpc.daemonUnavailable",
                "starting",
            ))
        });
        let store = session(cx, &daemon);
        store.update(cx, |s, cx| {
            s.on_connected(&handshake(Some(true)), request(), cx)
        });
        cx.run_until_parked();
        assert_eq!(store.read_with(cx, |s, cx| s.route(cx)), Route::Unknown);
        // Up, with Hermes chosen in onboarding: the core's own answer.
        daemon.returns::<methods::AccountsList>(list(vec![]));
        daemon.returns::<methods::AuthStatus>(auth(AuthPhase::Unauthenticated, false));
        daemon.on::<OnboardingProbe>(|_| Ok(json!({"needsOnboarding": false})));
        daemon.returns::<methods::HermesSettings>(HermesSettings {
            usable: true,
            ..Default::default()
        });
        let accounts = store.read_with(cx, |s, _| s.accounts().clone());
        accounts.update(cx, |a, cx| a.refresh(cx));
        cx.run_until_parked();
        assert_eq!(store.read_with(cx, |s, cx| s.route(cx)), Route::Main);
        assert_eq!(
            store.read_with(cx, |s, cx| s.backend(cx)),
            Some(Backend::Hermes)
        );
    }

    #[gpui_kit::test]
    fn a_usable_backend_the_core_does_not_count_is_still_onboarding(cx: &mut TestAppContext) {
        // Hermes saved and usable, but not the backend the app is used
        // through (saved from settings, or a gateway that still has to sign
        // in): the core says onboarding, and that decides.
        let daemon = FakeDaemon::new();
        daemon.returns::<methods::AccountsList>(list(vec![]));
        daemon.returns::<methods::AuthStatus>(auth(AuthPhase::Unauthenticated, false));
        daemon.on::<OnboardingProbe>(|_| Ok(json!({"needsOnboarding": true})));
        daemon.returns::<methods::HermesSettings>(HermesSettings {
            usable: true,
            ..Default::default()
        });
        let store = session(cx, &daemon);
        store.update(cx, |s, cx| s.on_connected(&handshake(None), request(), cx));
        cx.run_until_parked();
        assert_eq!(store.read_with(cx, |s, cx| s.route(cx)), Route::Onboarding);
    }

    #[gpui_kit::test]
    fn signing_in_moves_from_sign_in_to_main(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        daemon.returns::<methods::AccountsList>(list(vec![account("a", "Avery", true, false)]));
        daemon.returns::<methods::AuthStatus>(auth(AuthPhase::Unauthenticated, false));
        daemon.on::<OnboardingProbe>(|_| Ok(json!({"needsOnboarding": false})));
        let store = session(cx, &daemon);
        store.update(cx, |s, cx| {
            s.on_connected(&handshake(Some(false)), request(), cx)
        });
        cx.run_until_parked();
        assert_eq!(store.read_with(cx, |s, cx| s.route(cx)), Route::SignIn);

        // `accounts.changed` → the accounts store refetches → the session
        // sees a new signature and refetches auth.
        daemon.returns::<methods::AccountsList>(list(vec![account("a", "Avery", true, true)]));
        daemon.returns::<methods::AuthStatus>(auth(AuthPhase::Authenticated, true));
        let accounts = store.read_with(cx, |s, _| s.accounts().clone());
        accounts.update(cx, |a, cx| a.refresh(cx));
        cx.run_until_parked();
        assert_eq!(store.read_with(cx, |s, cx| s.route(cx)), Route::Main);
        assert_eq!(
            store.read_with(cx, |s, cx| s.backend(cx)),
            Some(Backend::OpenWebUi)
        );
    }

    fn loading() -> AuthSnapshot {
        let mut a = auth(AuthPhase::Loading, false);
        a.is_loading = true;
        a
    }

    fn signed_in() -> AccountList {
        list(vec![account("a", "Avery", true, true)])
    }

    fn server(reachability: ServerReachability) -> ServerStatus {
        ServerStatus {
            active_server_id: Some("a".into()),
            capabilities: Capabilities::default(),
            reachability,
            version: None,
            is_version_supported: true,
            max_supported_version: "0.13.2".into(),
            error_code: None,
        }
    }

    fn route_of(store: &Entity<SessionStore>, cx: &mut TestAppContext) -> Route {
        store.read_with(cx, |s, cx| s.route(cx))
    }

    /// Lets every pending ask run, one [`resolve_delay`] after another.
    fn wait_asks(n: u32, cx: &mut TestAppContext) {
        for attempt in 0..n {
            cx.executor().advance_clock(resolve_delay(attempt));
            cx.run_until_parked();
        }
    }

    #[gpui_kit::test]
    fn a_core_still_restoring_the_session_is_asked_again(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        daemon.returns::<methods::AccountsList>(signed_in());
        daemon.returns::<methods::AuthStatus>(loading());
        daemon.on::<OnboardingProbe>(|_| Ok(json!({"needsOnboarding": false})));
        let store = session(cx, &daemon);
        store.update(cx, |s, cx| {
            s.on_connected(&handshake(Some(false)), request(), cx)
        });
        cx.run_until_parked();
        assert_eq!(route_of(&store, cx), Route::Unknown);

        // It settles, and no event says so: the session asks again.
        daemon.returns::<methods::AuthStatus>(auth(AuthPhase::Authenticated, true));
        wait_asks(1, cx);
        assert_eq!(route_of(&store, cx), Route::Main);
        assert!(store.read_with(cx, |s, _| s.error.is_none()));
    }

    #[gpui_kit::test]
    fn a_daemon_that_restarts_mid_start_is_routed_after_the_reconnect(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        // The first daemon dies while the window asks.
        daemon.on::<methods::AccountsList>(|_| {
            Err(conduit_daemon::protocol::error(
                conduit_daemon::protocol::codes::DISCONNECTED,
                "the daemon went away",
            ))
        });
        let store = session(cx, &daemon);
        store.update(cx, |s, cx| {
            s.on_connected(&handshake(Some(false)), request(), cx)
        });
        cx.run_until_parked();
        assert_eq!(route_of(&store, cx), Route::Unknown);
        // Asking again, not failing: the supervisor is bringing it back.
        assert!(store.read_with(cx, |s, _| s.error.is_none()));

        // The restarted daemon: its core restores the session first.
        daemon.returns::<methods::AccountsList>(signed_in());
        daemon.returns::<methods::AuthStatus>(loading());
        daemon.on::<OnboardingProbe>(|_| Ok(json!({"needsOnboarding": false})));
        store.update(cx, |s, cx| {
            s.on_connected(&handshake(Some(false)), request(), cx)
        });
        cx.run_until_parked();
        assert_eq!(route_of(&store, cx), Route::Unknown);

        daemon.returns::<methods::AuthStatus>(auth(AuthPhase::Authenticated, true));
        wait_asks(2, cx);
        assert_eq!(route_of(&store, cx), Route::Main);
    }

    #[gpui_kit::test]
    fn a_route_that_never_comes_says_why_and_retry_starts_over(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        daemon.returns::<methods::AccountsList>(signed_in());
        daemon.returns::<methods::AuthStatus>(loading());
        daemon.on::<OnboardingProbe>(|_| Ok(json!({"needsOnboarding": false})));
        let store = session(cx, &daemon);
        store.update(cx, |s, cx| {
            s.on_connected(&handshake(Some(false)), request(), cx)
        });
        cx.run_until_parked();
        wait_asks(RESOLVE_ATTEMPTS + 1, cx);
        let asked = daemon.calls::<methods::AuthStatus>().len();
        store.read_with(cx, |s, cx| {
            assert_eq!(s.route(cx), Route::Unknown);
            let error = s.error.as_ref().expect("an error to show with Retry");
            assert_eq!(
                error.code,
                conduit_protocol::ErrorCode::from_code(UNRESOLVED)
            );
        });
        // Bounded: no more asks once it has said why.
        wait_asks(3, cx);
        assert_eq!(daemon.calls::<methods::AuthStatus>().len(), asked);

        // Retry: asked again from the start, and this time it settles.
        daemon.returns::<methods::AuthStatus>(auth(AuthPhase::Authenticated, true));
        store.update(cx, |s, cx| s.refresh(cx));
        cx.run_until_parked();
        store.read_with(cx, |s, cx| {
            assert_eq!(s.route(cx), Route::Main);
            assert!(s.error.is_none());
        });
    }

    #[gpui_kit::test]
    fn an_unreachable_server_still_opens_main_and_says_when_it_is_back(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        daemon.returns::<methods::AccountsList>(signed_in());
        daemon.returns::<methods::AuthStatus>(auth(AuthPhase::Authenticated, true));
        daemon.on::<OnboardingProbe>(|_| Ok(json!({"needsOnboarding": false})));
        daemon.returns::<methods::ServersStatus>(server(ServerReachability::Unreachable));
        let store = session(cx, &daemon);
        let back = std::rc::Rc::new(std::cell::Cell::new(0));
        {
            let back = back.clone();
            cx.update(|cx| {
                cx.subscribe(&store, move |_, event, _| {
                    if *event == SessionEvent::ServerBack {
                        back.set(back.get() + 1);
                    }
                })
                .detach()
            });
        }
        store.update(cx, |s, cx| {
            s.on_connected(&handshake(Some(false)), request(), cx)
        });
        cx.run_until_parked();
        store.read_with(cx, |s, cx| {
            assert_eq!(s.route(cx), Route::Main);
            assert!(s.server_unreachable(cx));
        });

        // Still down at the next check, then back.
        cx.executor().advance_clock(SERVER_RECHECK);
        cx.run_until_parked();
        assert!(store.read_with(cx, |s, cx| s.server_unreachable(cx)));
        assert_eq!(back.get(), 0);
        daemon.returns::<methods::ServersStatus>(server(ServerReachability::Reachable));
        cx.executor().advance_clock(SERVER_RECHECK);
        cx.run_until_parked();
        assert!(!store.read_with(cx, |s, cx| s.server_unreachable(cx)));
        assert_eq!(back.get(), 1);

        // Reachable: no more checks of its own.
        let checks = daemon.calls::<methods::ServersStatus>().len();
        cx.executor().advance_clock(SERVER_RECHECK * 3);
        cx.run_until_parked();
        assert_eq!(daemon.calls::<methods::ServersStatus>().len(), checks);
    }

    #[gpui_kit::test]
    fn a_slow_direct_list_does_not_hold_back_the_route(cx: &mut TestAppContext) {
        // Offline start-up: `direct.list` waits on the server, the account and
        // its auth come from what the daemon stored.
        let daemon = FakeDaemon::new();
        daemon.returns::<methods::AccountsList>(signed_in());
        daemon.returns::<methods::AuthStatus>(auth(AuthPhase::Authenticated, true));
        daemon.on::<OnboardingProbe>(|_| Ok(json!({"needsOnboarding": false})));
        daemon.returns::<methods::DirectList>(DirectConnectionList::default());
        let held = daemon.hold::<methods::DirectList>();
        let store = session(cx, &daemon);
        store.update(cx, |s, cx| {
            s.on_connected(&handshake(Some(false)), request(), cx)
        });
        cx.run_until_parked();
        assert_eq!(route_of(&store, cx), Route::Main);
        held.release();
        cx.run_until_parked();
        store.read_with(cx, |s, cx| {
            assert_eq!(s.route(cx), Route::Main);
            assert!(s.direct.is_some());
        });
    }

    #[gpui_kit::test]
    fn with_no_account_main_waits_for_the_backend_answers(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        daemon.returns::<methods::AccountsList>(list(vec![]));
        daemon.returns::<methods::AuthStatus>(auth(AuthPhase::Unauthenticated, false));
        daemon.on::<OnboardingProbe>(|_| Ok(json!({"needsOnboarding": false})));
        daemon.returns::<methods::DirectList>(DirectConnectionList {
            preferred: true,
            usable: true,
            ..Default::default()
        });
        let held = daemon.hold::<methods::DirectList>();
        let store = session(cx, &daemon);
        store.update(cx, |s, cx| s.on_connected(&handshake(None), request(), cx));
        cx.run_until_parked();
        // Main without a backend would be a window that chats through nothing.
        assert_eq!(route_of(&store, cx), Route::Unknown);
        // A read slower than the retries is kept, not asked again.
        cx.executor().advance_clock(Duration::from_secs(10));
        cx.run_until_parked();
        assert_eq!(daemon.calls::<methods::DirectList>().len(), 1);
        held.release();
        cx.run_until_parked();
        store.read_with(cx, |s, cx| {
            assert_eq!(s.route(cx), Route::Main);
            assert_eq!(s.backend(cx), Some(Backend::Direct));
            assert!(s.error.is_none());
        });
    }

    #[gpui_kit::test]
    fn each_backend_answer_lands_on_its_own(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        daemon.returns::<methods::AccountsList>(signed_in());
        daemon.returns::<methods::AuthStatus>(auth(AuthPhase::Authenticated, true));
        daemon.on::<OnboardingProbe>(|_| Ok(json!({"needsOnboarding": false})));
        daemon.returns::<methods::HermesSettings>(HermesSettings {
            usable: true,
            ..Default::default()
        });
        let held = daemon.hold::<methods::DirectList>();
        let store = session(cx, &daemon);
        store.update(cx, |s, cx| {
            s.on_connected(&handshake(Some(false)), request(), cx)
        });
        cx.run_until_parked();
        store.read_with(cx, |s, _| {
            assert!(
                s.hermes.as_ref().is_some_and(|h| h.usable),
                "Hermes waited for Direct"
            );
            assert!(s.direct.is_none());
        });
        drop(held);
    }

    #[gpui_kit::test]
    fn a_refresh_drops_a_backend_answer_asked_before_it(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        daemon.returns::<methods::AccountsList>(list(vec![]));
        daemon.returns::<methods::AuthStatus>(auth(AuthPhase::Unauthenticated, false));
        daemon.on::<OnboardingProbe>(|_| Ok(json!({"needsOnboarding": false})));
        daemon.returns::<methods::HermesSettings>(HermesSettings {
            usable: true,
            ..Default::default()
        });
        let hermes = daemon.hold::<methods::HermesSettings>();
        let store = session(cx, &daemon);
        store.update(cx, |s, cx| s.on_connected(&handshake(None), request(), cx));
        cx.run_until_parked();
        // Hermes stops being usable; the refresh's own read has not started.
        daemon.returns::<methods::HermesSettings>(HermesSettings::default());
        let accounts = daemon.hold::<methods::AccountsList>();
        store.update(cx, |s, cx| s.refresh(cx));
        hermes.release();
        cx.run_until_parked();
        store.read_with(cx, |s, cx| {
            assert_eq!(s.route(cx), Route::Unknown);
            assert!(s.hermes.is_none(), "the old Hermes answer landed");
        });
        accounts.release();
        cx.run_until_parked();
        store.read_with(cx, |s, _| {
            assert!(!s.hermes.as_ref().is_some_and(|h| h.usable));
        });
    }

    /// The kinds of read the session starts, and what each one sets.
    #[derive(Clone, Copy, Debug)]
    enum Kind {
        Accounts,
        Auth,
        Direct,
        Hermes,
        Server,
    }

    /// What makes every read started before it stale.
    #[derive(Clone, Copy, Debug)]
    enum Change {
        Refresh,
        AccountSwitch,
        Reset,
    }

    /// The daemon's answer for `kind`: the one before the change, or after.
    fn answer(daemon: &FakeDaemon, kind: Kind, after: bool) {
        match kind {
            Kind::Accounts if after => daemon.returns::<methods::AccountsList>(list(vec![
                account("a", "Avery", true, true),
                account("c", "Casey", false, true),
            ])),
            Kind::Accounts => daemon.returns::<methods::AccountsList>(signed_in()),
            Kind::Auth => daemon.returns::<methods::AuthStatus>(if after {
                auth(AuthPhase::Authenticated, true)
            } else {
                auth(AuthPhase::Unauthenticated, false)
            }),
            Kind::Direct => daemon.returns::<methods::DirectList>(DirectConnectionList {
                preferred: !after,
                ..Default::default()
            }),
            Kind::Hermes => daemon.returns::<methods::HermesSettings>(HermesSettings {
                usable: !after,
                ..Default::default()
            }),
            Kind::Server => daemon.returns::<methods::ServersStatus>(server(if after {
                ServerReachability::Reachable
            } else {
                ServerReachability::Unreachable
            })),
        };
    }

    /// Whether the session holds the answer from after the change.
    fn holds_the_later_answer(s: &SessionStore, kind: Kind, cx: &gpui_kit::App) -> bool {
        match kind {
            Kind::Accounts => {
                s.accounts.read(cx).list.as_ref().map(|l| l.accounts.len()) == Some(2)
            }
            Kind::Auth => s.auth.as_ref().is_some_and(|a| a.is_authenticated),
            Kind::Direct => s.direct.as_ref().is_some_and(|d| !d.preferred),
            Kind::Hermes => s.hermes.as_ref().is_some_and(|h| !h.usable),
            Kind::Server => s
                .server
                .as_ref()
                .is_some_and(|s| s.reachability == ServerReachability::Reachable),
        }
    }

    #[gpui_kit::test]
    fn a_read_started_before_a_change_never_applies_after_it(cx: &mut TestAppContext) {
        let switched = list(vec![
            account("a", "Avery", false, true),
            account("b", "Blake", true, true),
        ]);
        for change in [Change::Refresh, Change::AccountSwitch, Change::Reset] {
            for kind in [
                Kind::Accounts,
                Kind::Auth,
                Kind::Direct,
                Kind::Hermes,
                Kind::Server,
            ] {
                let daemon = FakeDaemon::new();
                daemon.returns::<methods::AccountsList>(signed_in());
                daemon.returns::<methods::AuthStatus>(auth(AuthPhase::Authenticated, true));
                daemon.on::<OnboardingProbe>(|_| Ok(json!({"needsOnboarding": false})));
                daemon.returns::<methods::ServersStatus>(server(ServerReachability::Reachable));
                answer(&daemon, kind, false);
                // The session's first read of its kind (the accounts store
                // lists the accounts first, on its own).
                let held = match kind {
                    Kind::Accounts => daemon.hold_one::<methods::AccountsList>(1),
                    Kind::Auth => daemon.hold_one::<methods::AuthStatus>(0),
                    Kind::Direct => daemon.hold_one::<methods::DirectList>(0),
                    Kind::Hermes => daemon.hold_one::<methods::HermesSettings>(0),
                    Kind::Server => daemon.hold_one::<methods::ServersStatus>(0),
                };
                let store = session(cx, &daemon);
                store.update(cx, |s, cx| {
                    s.on_connected(&handshake(Some(false)), request(), cx)
                });
                cx.run_until_parked();
                answer(&daemon, kind, true);
                match change {
                    Change::Refresh => store.update(cx, |s, cx| s.refresh(cx)),
                    Change::AccountSwitch => {
                        daemon.returns::<methods::AccountsList>(switched.clone());
                        let accounts = store.read_with(cx, |s, _| s.accounts().clone());
                        accounts.update(cx, |a, cx| a.adopt(switched.clone(), cx));
                    }
                    Change::Reset => store.update(cx, |s, cx| {
                        s.on_connected(&handshake(Some(false)), request(), cx)
                    }),
                }
                cx.run_until_parked();
                held.release();
                cx.run_until_parked();
                store.read_with(cx, |s, cx| {
                    assert!(
                        holds_the_later_answer(s, kind, cx),
                        "{kind:?} asked before a {change:?} applied after it"
                    );
                });
            }
        }
    }

    /// Another LibreChat account in charge, with Open WebUI's account as it
    /// was: the last account's capabilities are not kept for it.
    #[gpui_kit::test]
    fn another_librechat_account_drops_the_last_ones_facts(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        let store = session(cx, &daemon);
        let accounts = store.read_with(cx, |s, _| s.accounts().clone());
        let in_charge = |id: &str| {
            let mut l = list(vec![account("a", "Avery", true, true)]);
            l.primary = PrimaryAccount::LibreChat;
            l.active_libre_chat_account_id = Some(id.into());
            l
        };
        accounts.update(cx, |a, cx| a.adopt(in_charge("lc-avery"), cx));
        cx.run_until_parked();
        store.update(cx, |s, _| {
            s.system_capabilities = Some(Capabilities {
                notes: true,
                ..Default::default()
            })
        });
        accounts.update(cx, |a, cx| a.adopt(in_charge("lc-blake"), cx));
        cx.run_until_parked();
        store.read_with(cx, |s, _| {
            assert!(
                s.system_capabilities.is_none(),
                "the last LibreChat account's capabilities stayed"
            )
        });
    }

    #[gpui_kit::test]
    fn a_list_the_accounts_store_refuses_starts_no_account_read(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        daemon.returns::<methods::AccountsList>(signed_in());
        daemon.returns::<methods::AuthStatus>(auth(AuthPhase::Authenticated, true));
        daemon.on::<OnboardingProbe>(|_| Ok(json!({"needsOnboarding": false})));
        let store = session(cx, &daemon);
        store.update(cx, |s, cx| {
            s.on_connected(&handshake(Some(false)), request(), cx)
        });
        cx.run_until_parked();
        // A switch to B in flight; the daemon already lists B.
        let switching = daemon.hold::<methods::AccountsSwitch>();
        let accounts = store.read_with(cx, |s, _| s.accounts().clone());
        let _switch = accounts.update(cx, |a, cx| {
            a.change(
                AccountChange::Switch {
                    account_id: "b".into(),
                },
                false,
                cx,
            )
        });
        daemon.returns::<methods::AccountsList>(list(vec![
            account("a", "Avery", false, true),
            account("b", "Blake", true, true),
        ]));
        let auth_reads = daemon.calls::<methods::AuthStatus>().len();
        store.update(cx, |s, cx| s.refresh(cx));
        cx.run_until_parked();
        assert_eq!(daemon.calls::<methods::AuthStatus>().len(), auth_reads);
        store.read_with(cx, |s, _| assert_eq!(s.facts_for.as_deref(), Some("a")));
        drop(switching);
    }

    #[gpui_kit::test]
    fn a_refresh_keeps_checking_a_server_out_of_reach(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        daemon.returns::<methods::AccountsList>(signed_in());
        daemon.returns::<methods::AuthStatus>(auth(AuthPhase::Authenticated, true));
        daemon.on::<OnboardingProbe>(|_| Ok(json!({"needsOnboarding": false})));
        daemon.returns::<methods::ServersStatus>(server(ServerReachability::Unreachable));
        let store = session(cx, &daemon);
        store.update(cx, |s, cx| {
            s.on_connected(&handshake(Some(false)), request(), cx)
        });
        cx.run_until_parked();
        // A check in flight when a refresh starts, whose own reads fail.
        let check = daemon.hold::<methods::ServersStatus>();
        cx.executor().advance_clock(SERVER_RECHECK);
        cx.run_until_parked();
        daemon.on::<methods::AccountsList>(|_| {
            Err(conduit_daemon::protocol::error(
                "rpc.daemonUnavailable",
                "x",
            ))
        });
        store.update(cx, |s, cx| s.refresh(cx));
        drop(check);
        cx.run_until_parked();
        daemon.returns::<methods::ServersStatus>(server(ServerReachability::Reachable));
        let before = daemon.calls::<methods::ServersStatus>().len();
        cx.executor().advance_clock(SERVER_RECHECK);
        cx.run_until_parked();
        assert!(daemon.calls::<methods::ServersStatus>().len() > before);
        assert!(!store.read_with(cx, |s, cx| s.server_unreachable(cx)));
    }

    #[gpui_kit::test]
    fn another_accounts_auth_and_server_never_route_the_new_one(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        daemon.returns::<methods::AccountsList>(signed_in());
        daemon.returns::<methods::AuthStatus>(auth(AuthPhase::Authenticated, true));
        daemon.on::<OnboardingProbe>(|_| Ok(json!({"needsOnboarding": false})));
        daemon.returns::<methods::ServersStatus>(server(ServerReachability::Unreachable));
        let store = session(cx, &daemon);
        store.update(cx, |s, cx| {
            s.on_connected(&handshake(Some(false)), request(), cx)
        });
        cx.run_until_parked();
        store.read_with(cx, |s, cx| {
            assert_eq!(s.route(cx), Route::Main);
            assert!(s.server_unreachable(cx));
        });

        // Switched to B, which has no session; its auth answer fails at first
        // and its server status is slow.
        let b = list(vec![
            account("a", "Avery", false, true),
            account("b", "Blair", true, false),
        ]);
        daemon.returns::<methods::AccountsList>(b);
        daemon.once::<methods::AuthStatus>(Err(conduit_daemon::protocol::error(
            "rpc.daemonUnavailable",
            "busy",
        )));
        daemon.returns::<methods::AuthStatus>(auth(AuthPhase::Unauthenticated, false));
        let held = daemon.hold::<methods::ServersStatus>();
        let accounts = store.read_with(cx, |s, _| s.accounts().clone());
        accounts.update(cx, |a, cx| a.refresh(cx));
        cx.run_until_parked();
        store.read_with(cx, |s, cx| {
            assert_eq!(s.route(cx), Route::Unknown, "A's sign-in is not B's");
            assert!(!s.server_unreachable(cx), "A's server is not B's");
        });
        wait_asks(1, cx);
        assert_eq!(route_of(&store, cx), Route::SignIn);
        drop(held);
    }

    #[gpui_kit::test]
    fn a_failed_check_of_an_unreachable_server_is_tried_again(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        daemon.returns::<methods::AccountsList>(signed_in());
        daemon.returns::<methods::AuthStatus>(auth(AuthPhase::Authenticated, true));
        daemon.on::<OnboardingProbe>(|_| Ok(json!({"needsOnboarding": false})));
        daemon.returns::<methods::ServersStatus>(server(ServerReachability::Unreachable));
        let store = session(cx, &daemon);
        store.update(cx, |s, cx| {
            s.on_connected(&handshake(Some(false)), request(), cx)
        });
        cx.run_until_parked();
        assert!(store.read_with(cx, |s, cx| s.server_unreachable(cx)));
        // The next check fails outright; the one after finds the server.
        daemon.once::<methods::ServersStatus>(Err(conduit_daemon::protocol::error(
            "rpc.timeout",
            "slow",
        )));
        daemon.returns::<methods::ServersStatus>(server(ServerReachability::Reachable));
        cx.executor().advance_clock(SERVER_RECHECK);
        cx.run_until_parked();
        cx.executor().advance_clock(SERVER_RECHECK);
        cx.run_until_parked();
        assert!(!store.read_with(cx, |s, cx| s.server_unreachable(cx)));
    }

    #[gpui_kit::test]
    fn a_failed_direct_list_keeps_the_last_answer(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        daemon.returns::<methods::AccountsList>(list(vec![]));
        daemon.returns::<methods::AuthStatus>(auth(AuthPhase::Unauthenticated, false));
        daemon.on::<OnboardingProbe>(|_| Ok(json!({"needsOnboarding": false})));
        daemon.returns::<methods::DirectList>(DirectConnectionList {
            preferred: true,
            usable: true,
            ..Default::default()
        });
        let store = session(cx, &daemon);
        store.update(cx, |s, cx| s.on_connected(&handshake(None), request(), cx));
        cx.run_until_parked();
        assert_eq!(
            store.read_with(cx, |s, cx| s.backend(cx)),
            Some(Backend::Direct)
        );
        daemon.once::<methods::DirectList>(Err(conduit_daemon::protocol::error(
            "rpc.timeout",
            "slow",
        )));
        store.update(cx, |s, cx| s.refresh(cx));
        cx.run_until_parked();
        assert_eq!(
            store.read_with(cx, |s, cx| s.backend(cx)),
            Some(Backend::Direct)
        );
    }

    #[gpui_kit::test]
    fn direct_and_hermes_only_signals(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        daemon.returns::<methods::AccountsList>(list(vec![]));
        daemon.returns::<methods::AuthStatus>(auth(AuthPhase::Unauthenticated, false));
        daemon.on::<OnboardingProbe>(|_| Ok(json!({"needsOnboarding": false})));
        daemon.returns::<methods::DirectList>(DirectConnectionList {
            preferred: true,
            usable: true,
            ..Default::default()
        });
        let store = session(cx, &daemon);
        store.update(cx, |s, cx| s.on_connected(&handshake(None), request(), cx));
        cx.run_until_parked();
        store.read_with(cx, |s, cx| {
            assert_eq!(s.route(cx), Route::Main);
            assert!(s.direct_only(cx));
            assert!(!s.hermes_only(cx));
            assert_eq!(s.backend(cx), Some(Backend::Direct));
        });

        daemon.returns::<methods::DirectList>(DirectConnectionList::default());
        daemon.returns::<methods::HermesSettings>(HermesSettings {
            usable: true,
            ..Default::default()
        });
        store.update(cx, |s, cx| s.refresh(cx));
        cx.run_until_parked();
        store.read_with(cx, |s, cx| {
            assert!(!s.direct_only(cx));
            assert!(s.hermes_only(cx));
            assert_eq!(s.backend(cx), Some(Backend::Hermes));
        });
    }

    #[gpui_kit::test]
    fn another_account_never_takes_the_handshakes_capabilities(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        daemon.returns::<methods::AccountsList>(list(vec![account("a", "Avery", true, true)]));
        let _held = daemon.hold::<methods::SystemCapabilities>();
        let store = session(cx, &daemon);
        let connected = Handshake::from_value(json!({
            "protocolVersion": conduit_protocol::PROTOCOL_VERSION,
            "daemonVersion": "0.1.0",
            "sessionId": "s",
            "platform": "macos",
            "capabilities": {"notes": true},
            "paths": {"userData": "/u", "database": "/d", "cache": "/c", "logs": "/l", "staging": "/s"},
        }));
        store.update(cx, |s, cx| s.on_connected(&connected, request(), cx));
        cx.run_until_parked();
        // The account it was made for: its areas until system.capabilities.
        store.read_with(cx, |s, _| assert!(s.capabilities().notes));
        let switched = list(vec![
            account("a", "Avery", false, true),
            account("b", "Blake", true, true),
        ]);
        daemon.returns::<methods::AccountsList>(switched.clone());
        let accounts = store.read_with(cx, |s, _| s.accounts.clone());
        accounts.update(cx, |a, cx| a.adopt(switched, cx));
        cx.run_until_parked();
        store.read_with(cx, |s, _| {
            assert!(!s.capabilities().notes, "B shows A's areas");
        });
    }
}
