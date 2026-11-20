//! GPUI entities the views read.
//!
//! * [`connection`]: supervisor + RPC client, the connection status, and the
//!   event fan-out.
//! * [`session`]: auth, server status, Direct/Hermes signals and the
//!   tri-state route; [`accounts`]: the account list and its changes.
//! * [`ui_requests`]: `ui.request` → a queue, answered with `ui.respond`.
//! * [`router`]: `route.remap`; [`toasts`]: `notify.show` and the window's
//!   own notices.
//! * [`navigation`]: which chat the main window shows (the sidebar sets it,
//!   the chat pane follows it).
//! * [`chat_list`]: the sidebar's chats, folders, sync state and search;
//!   [`palette`]: the ⌘K palette's query and hits.
//! * [`areas`]: the sidebar's other areas (which ones the account can use,
//!   and their lists); [`sections`]: which sections are closed, per
//!   account.
//! * [`chat`]: one open chat (the chat pane's): its transcript, the live
//!   answer and this window's choices about it; [`composer`]: models,
//!   features, prompts and attachments for the next message.
//! * [`files`]: `/files` images (bearer token added) and attachment opening.
//! * [`settings`] and [`layout`]: preferences and window geometry.
//! * [`speech`]: read aloud, which the daemon runs and this window speaks.
//! * [`apple_models`]: Apple's on-device model, which the daemon's chats
//!   use and this window runs.
//! * [`location`]: the Mac's location, which the daemon asks for when a
//!   prompt names `{{USER_LOCATION}}`.
//! * [`call`]: a voice call, which the daemon runs and this window hears
//!   and, for a realtime voice, plays.
//! * [`calendar`] and [`tasks`]: the calendar's agenda and the scheduled
//!   tasks, as the daemon keeps them.
//! * [`shell`]: the macOS shell extras' state (links waiting for the main
//!   window, the hotkey, notification and login-item statuses).
//!
//! [`Stores`] owns them; [`Stores::install`] wires each to the daemon
//! events it follows. Every store mutates through the daemon and refetches;
//! none patches what the daemon answered.

pub mod accounts;
pub mod app_settings;
pub mod apple_models;
pub mod areas;
pub mod calendar;
pub mod call;
pub mod channel;
pub mod chat;
pub mod chat_list;
pub mod composer;
pub mod connection;
pub mod dictation;
pub mod files;
pub mod hermes_admin;
pub mod hermes_rooms;
pub mod hermes_work;
pub mod layout;
pub mod location;
pub mod media;
pub mod navigation;
pub mod notifications;
pub mod palette;
pub mod router;
pub mod rpc;
pub mod sections;
pub mod session;
pub mod settings;
pub mod shell;
pub mod speech;
pub mod tasks;
pub mod toasts;
pub mod ui_requests;

use conduit_protocol::{Event, NoticeLevel, events};
use gpui_kit::{App, AppContext as _, Entity};

use accounts::{AccountsEvent, AccountsStore};
use areas::AreasStore;
use chat_list::ChatListStore;
use connection::{ConnectionEvent, ConnectionStore};
use navigation::NavigationStore;
use palette::PaletteStore;
use router::RouterStore;
use sections::SectionsStore;
use session::{SessionEvent, SessionStore};
use toasts::ToastStore;
use ui_requests::UiRequestsStore;

/// The session layer the sidebar and the chat view build on.
#[derive(Clone)]
pub struct Stores {
    pub connection: Entity<ConnectionStore>,
    pub accounts: Entity<AccountsStore>,
    pub session: Entity<SessionStore>,
    pub ui_requests: Entity<UiRequestsStore>,
    pub router: Entity<RouterStore>,
    pub toasts: Entity<ToastStore>,
    pub navigation: Entity<NavigationStore>,
    pub chat_list: Entity<ChatListStore>,
    pub palette: Entity<PaletteStore>,
    pub areas: Entity<AreasStore>,
    /// Hermes's connections, status, catalog, MCP servers and jobs.
    pub hermes_admin: Entity<hermes_admin::HermesAdminStore>,
    pub sections: Entity<SectionsStore>,
    /// Core's `AppSettings` and the socket's health (Settings, composer).
    pub app_settings: Entity<app_settings::AppSettingsStore>,
    /// Settings › Notifications.
    pub notifications: Entity<notifications::NotificationsStore>,
    /// Read aloud: the reading, and this window's voice and player.
    pub speech: Entity<speech::SpeechStore>,
    /// A voice call: the call the daemon runs, and this window's ears and
    /// realtime audio.
    pub call: Entity<call::CallStore>,
    pub calendar: Entity<calendar::CalendarStore>,
    pub tasks: Entity<tasks::TasksStore>,
    /// Hermes's bots and Group Chats, and the room the main window shows.
    pub hermes_rooms: Entity<hermes_rooms::HermesRoomsStore>,
    /// Apple's on-device model: the Swift engine the daemon's chats use.
    pub apple: Entity<apple_models::AppleModelsStore>,
    /// The Mac's location services, for `{{USER_LOCATION}}`.
    pub location: Entity<location::LocationStore>,
}

/// The session-wide events the stores follow (the views add their own scopes
/// with [`ConnectionStore::subscribe`]).
pub const SESSION_EVENTS: &[&str] = &[
    events::ACCOUNTS_CHANGED,
    events::UI_REQUEST,
    events::UI_SETTLED,
    events::NOTIFY_SHOW,
    events::ROUTE_REMAP,
    events::HERMES_CHANGED,
    events::CAPABILITIES_CHANGED,
    events::AUTH_CHANGED,
];

impl Stores {
    /// Stores over `rpc` for view tests: the connection never starts a
    /// daemon, and nothing is wired.
    #[cfg(test)]
    pub fn for_test(rpc: rpc::Rpc, scratch: &std::path::Path, cx: &mut App) -> Self {
        use conduit_daemon::paths::{AppPaths, Flavor};
        let connection = ConnectionStore::start(
            connection::ConnectionOptions {
                paths: AppPaths {
                    flavor: Flavor::Dev,
                    user_data: scratch.join("user-data"),
                    logs: scratch.join("logs"),
                },
                binary: std::path::PathBuf::from("/nonexistent/conduitd"),
                master_key: Err("test".into()),
                locale: "en".into(),
                client_version: "0".into(),
            },
            cx,
        );
        connection.update(cx, |c, _| c.set_rpc_for_test(rpc.clone()));
        let accounts = cx.new(|_| AccountsStore::new(rpc.clone()));
        let session = {
            let (rpc, accounts) = (rpc.clone(), accounts.clone());
            cx.new(|cx| SessionStore::new(rpc, accounts, cx))
        };
        Self {
            connection: connection.clone(),
            accounts,
            session,
            ui_requests: cx.new(|_| UiRequestsStore::new(rpc.clone())),
            router: cx.new(|_| RouterStore::new()),
            toasts: cx.new(|_| ToastStore::new()),
            navigation: cx.new(|_| NavigationStore::new()),
            chat_list: cx.new(|_| ChatListStore::new(rpc.clone())),
            palette: cx.new(|_| PaletteStore::new(rpc.clone())),
            areas: cx.new(|_| AreasStore::new(rpc.clone())),
            sections: cx.new(|_| SectionsStore::load(None)),
            app_settings: cx.new(|_| app_settings::AppSettingsStore::new(rpc.clone())),
            speech: cx.new(|cx| speech::SpeechStore::new(rpc.clone(), connection.clone(), cx)),
            call: cx.new(|cx| call::CallStore::new(rpc.clone(), connection, cx)),
            calendar: cx.new(|_| calendar::CalendarStore::new(rpc.clone())),
            tasks: cx.new(|_| tasks::TasksStore::new(rpc.clone())),
            hermes_rooms: cx.new(|_| hermes_rooms::HermesRoomsStore::new(rpc.clone())),
            hermes_admin: cx.new(|_| hermes_admin::HermesAdminStore::new(rpc.clone())),
            apple: cx.new(|_| apple_models::AppleModelsStore::for_test(rpc.clone())),
            notifications: cx.new(|_| notifications::NotificationsStore::new(rpc.clone())),
            location: cx.new(|_| location::LocationStore::new(rpc)),
        }
    }

    /// Creates the stores over `connection` and wires the events.
    pub fn install(connection: Entity<ConnectionStore>, cx: &mut App) -> Self {
        let rpc = connection.read(cx).rpc();
        let accounts = cx.new(|_| AccountsStore::new(rpc.clone()));
        let session = {
            let accounts = accounts.clone();
            let rpc = rpc.clone();
            cx.new(|cx| SessionStore::new(rpc, accounts, cx))
        };
        let ui_requests = cx.new(|_| UiRequestsStore::new(rpc.clone()));
        let router = cx.new(|_| RouterStore::new());
        let toasts = cx.new(|_| ToastStore::new());
        let navigation = cx.new(|_| NavigationStore::new());
        let chat_list = cx.new(|_| ChatListStore::new(rpc.clone()));
        let palette = cx.new(|_| PaletteStore::new(rpc.clone()));
        let areas = cx.new(|_| AreasStore::new(rpc.clone()));
        let hermes_admin = cx.new(|_| hermes_admin::HermesAdminStore::new(rpc.clone()));
        let sections_file = connection
            .read(cx)
            .paths()
            .user_data
            .join("sidebar-sections.json");
        let sections = cx.new(|_| SectionsStore::load(Some(sections_file)));
        let app_settings = cx.new(|_| app_settings::AppSettingsStore::new(rpc.clone()));
        let notifications = cx.new(|_| notifications::NotificationsStore::new(rpc.clone()));
        let speech = {
            let connection = connection.clone();
            let rpc = rpc.clone();
            cx.new(|cx| speech::SpeechStore::new(rpc, connection, cx))
        };
        let call = {
            let connection = connection.clone();
            let rpc = rpc.clone();
            cx.new(|cx| call::CallStore::new(rpc, connection, cx))
        };
        let calendar = cx.new(|_| calendar::CalendarStore::new(rpc.clone()));
        let tasks = cx.new(|_| tasks::TasksStore::new(rpc.clone()));
        let hermes_rooms = cx.new(|_| hermes_rooms::HermesRoomsStore::new(rpc.clone()));
        let apple = {
            let rpc = rpc.clone();
            cx.new(|cx| apple_models::AppleModelsStore::new(rpc, cx))
        };
        let location = cx.new(|_| location::LocationStore::new(rpc.clone()));
        let stores = Self {
            connection: connection.clone(),
            accounts,
            session,
            ui_requests,
            router,
            toasts,
            navigation,
            chat_list,
            palette,
            areas,
            hermes_admin,
            sections,
            app_settings,
            notifications,
            speech,
            call,
            calendar,
            tasks,
            hermes_rooms,
            apple,
            location,
        };
        connection.update(cx, |c, _| c.subscribe("session", SESSION_EVENTS, vec![]));
        chat_list::wire(&stores, cx);
        areas::wire(&stores, cx);
        hermes_admin::wire(&stores, cx);
        app_settings::wire(&stores, cx);
        notifications::wire(&stores, cx);
        speech::wire(&stores, cx);
        call::wire(&stores, cx);
        calendar::wire(&stores, cx);
        tasks::wire(&stores, cx);
        hermes_rooms::wire(&stores, cx);
        apple_models::wire(&stores, cx);
        location::wire(&stores, cx);
        {
            // The server answers again after the window opened without it:
            // the session (a token may have lapsed meanwhile) and the chat
            // list (the daemon pulls on a list) catch up without a relaunch.
            let s = stores.clone();
            cx.subscribe(&stores.session, move |_, event, cx| match event {
                SessionEvent::ServerBack => {
                    s.session.update(cx, |s, cx| s.refresh(cx));
                    if s.session.read(cx).route(cx) == session::Route::Main {
                        s.chat_list.update(cx, |c, cx| {
                            c.refresh(cx);
                            c.refresh_sync(cx);
                        });
                    }
                }
            })
            .detach();
        }
        {
            let s = stores.clone();
            cx.subscribe(&connection, move |_, event, cx| s.on_connection(event, cx))
                .detach();
        }
        stores
    }

    fn on_connection(&self, event: &ConnectionEvent, cx: &mut App) {
        match event {
            ConnectionEvent::Connected { handshake, request } => {
                self.ui_requests.update(cx, |u, cx| u.reset(cx));
                self.router.update(cx, |r, _| r.reset());
                let request = request.clone();
                self.session
                    .update(cx, |s, cx| s.on_connected(handshake, request, cx));
            }
            ConnectionEvent::Gap => {
                self.accounts.update(cx, |a, cx| a.refresh(cx));
                self.session.update(cx, |s, cx| s.refresh(cx));
            }
            ConnectionEvent::LocalDataReset { .. } => {}
            ConnectionEvent::Daemon(event) => self.on_event(event, cx),
        }
    }

    fn on_event(&self, event: &Event, cx: &mut App) {
        match event {
            Event::AccountsChanged(_) => {
                self.accounts.update(cx, |a, cx| a.refresh(cx));
                // A session read still on its way holds the list from before
                // the change: it starts over, so it never adopts that list.
                self.session.update(cx, |s, cx| s.refresh(cx));
            }
            Event::UiRequest(request) => {
                let request = request.clone();
                self.ui_requests
                    .update(cx, |u, cx| u.on_request(request, cx));
            }
            Event::UiSettled(settled) => {
                let id = settled.request_id.clone();
                self.ui_requests.update(cx, |u, cx| u.on_settled(&id, cx));
            }
            Event::NotifyShow(notice) => {
                let (level, message) = (notice.level, notice.message.clone());
                self.toasts.update(cx, |t, cx| t.show(level, message, cx));
            }
            Event::RouteRemap(remap) => {
                let (from, to) = (remap.from_id.clone(), remap.to_id.clone());
                self.navigation
                    .update(cx, |n, cx| n.on_remap(&from, &to, cx));
                self.router.update(cx, |r, cx| r.on_remap(from, to, cx));
            }
            Event::HermesChanged(_) => self.session.update(cx, |s, cx| s.refresh(cx)),
            // A second step, or a kept session turned away by its server:
            // the account list stays the same, so the session asks again.
            Event::AuthChanged => self.session.update(cx, |s, cx| s.refresh(cx)),
            // What decides the route may have changed with them: Apple's
            // on-device model, which answers only once the window's engine
            // says so (after launch, and after the core's first onboarding
            // answer), makes Direct usable. The whole session is asked
            // again, as a Hermes change does.
            Event::CapabilitiesChanged => self.session.update(cx, |s, cx| {
                s.refresh(cx);
                s.refresh_capabilities(cx);
                s.refresh_server(cx);
            }),
            _ => {}
        }
    }

    /// Shows account notices as toasts. `word` turns one into text.
    pub fn toast_account_notices(
        &self,
        word: impl Fn(&accounts::AccountNotice, &App) -> Option<(NoticeLevel, String)> + 'static,
        cx: &mut App,
    ) {
        let toasts = self.toasts.clone();
        cx.subscribe(&self.accounts, move |_, event, cx| {
            if let AccountsEvent::Notice(notice) = event
                && let Some((level, text)) = word(notice, cx)
            {
                toasts.update(cx, |t, cx| t.show(level, text, cx));
            }
        })
        .detach();
    }
}

#[cfg(test)]
mod event_tests {
    use conduit_protocol::{AccountsChanged, methods};
    use gpui_kit::TestAppContext;

    use super::*;
    use crate::stores::accounts::tests::{account, list};
    use crate::stores::rpc::fake::FakeDaemon;

    #[gpui_kit::test]
    fn a_model_that_answers_after_launch_takes_the_window_out_of_onboarding(
        cx: &mut TestAppContext,
    ) {
        use crate::stores::session::tests::{auth, handshake, request};
        use crate::stores::session::{Backend, Route};
        use conduit_protocol::{AuthPhase, DirectConnectionList};

        let daemon = FakeDaemon::new();
        let scratch =
            std::env::temp_dir().join(format!("conduit-stores-apple-{}", std::process::id()));
        let stores = cx.update(|cx| Stores::for_test(daemon.rpc(), &scratch, cx));
        // A cold launch with Apple On-Device as the only Direct model,
        // before the window's engine has said it answers: the core says
        // onboarding.
        daemon.returns::<methods::AccountsList>(list(vec![]));
        daemon.returns::<methods::AuthStatus>(auth(AuthPhase::Unauthenticated, false));
        daemon.on::<methods::SystemHandshake>(|_| Ok(serde_json::json!({"needsOnboarding": true})));
        daemon.returns::<methods::DirectList>(DirectConnectionList {
            preferred: true,
            ..Default::default()
        });
        stores
            .session
            .update(cx, |s, cx| s.on_connected(&handshake(None), request(), cx));
        cx.run_until_parked();
        assert_eq!(
            stores.session.read_with(cx, |s, cx| s.route(cx)),
            Route::Onboarding
        );

        // The model answers: the daemon's capabilities change with it.
        daemon
            .on::<methods::SystemHandshake>(|_| Ok(serde_json::json!({"needsOnboarding": false})));
        daemon.returns::<methods::DirectList>(DirectConnectionList {
            preferred: true,
            usable: true,
            ..Default::default()
        });
        cx.update(|cx| stores.on_event(&Event::CapabilitiesChanged, cx));
        cx.run_until_parked();
        assert_eq!(
            stores.session.read_with(cx, |s, cx| s.route(cx)),
            Route::Main
        );
        assert_eq!(
            stores.session.read_with(cx, |s, cx| s.backend(cx)),
            Some(Backend::Direct)
        );
    }

    #[gpui_kit::test]
    fn an_older_session_read_never_brings_back_the_last_account(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        let scratch =
            std::env::temp_dir().join(format!("conduit-stores-events-{}", std::process::id()));
        let stores = cx.update(|cx| Stores::for_test(daemon.rpc(), &scratch, cx));
        let on_a = list(vec![
            account("a", "Avery", true, true),
            account("b", "Blake", false, true),
        ]);
        let on_b = list(vec![
            account("a", "Avery", false, true),
            account("b", "Blake", true, true),
        ]);
        daemon.returns::<methods::AccountsList>(on_a);
        let held = daemon.hold::<methods::AccountsList>();
        // The session's read, answered with the list before the switch.
        stores.session.update(cx, |s, cx| s.refresh(cx));
        cx.run_until_parked();
        // The switch, and its accounts.changed.
        daemon.returns::<methods::AccountsList>(on_b);
        cx.update(|cx| {
            stores.on_event(
                &Event::AccountsChanged(AccountsChanged {
                    active_account_id: Some("b".into()),
                }),
                cx,
            )
        });
        cx.run_until_parked();
        held.release();
        cx.run_until_parked();
        let active = stores
            .accounts
            .read_with(cx, |a, _| a.active().map(|a| a.id.clone()));
        assert_eq!(active.as_deref(), Some("b"));
    }
}
