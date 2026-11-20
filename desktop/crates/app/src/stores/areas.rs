//! The sidebar's other areas: which ones the account can use, and what each
//! lists.
//!
//! * **Which areas.** [`visible_areas`] reads the active account's
//!   capabilities (`system.capabilities`, refetched on
//!   `capabilities.changed`), which the daemon takes from the core's own
//!   rule for the phone's tabs: Chats unless Hermes is the only backend,
//!   Hermes when it is on, Notes, the terminal and Channels on an Open
//!   WebUI server that has them, and the workspace sections, the calendar
//!   and scheduled tasks the account may use.
//! * **Lists**, for the areas shown: `notes.list` (pinned first, then
//!   recent) on `notes.changed`; `channels.list` (with unread counts) on
//!   `channels.changed`; `hermes.sessions` (pinned, conversations,
//!   archived) on `hermes.changed`, and when an answer in a Hermes chat
//!   ends (a new chat is a new session); `terminal.servers` when the area
//!   appears, and on any Open WebUI account, whose composer offers its
//!   terminals with or without the area. Everything is refetched after a
//!   reconnect or an event gap, and forgotten when the account changes.
//!   Nothing is patched locally.
//!
//! Hermes sessions never come in `chats.list` (their chats are the
//! daemon's `local:hermes_*` ids, which are not stored), so listing them
//! here lists them once.

use std::collections::{BTreeSet, HashMap};

use conduit_protocol::{
    Capabilities, ChannelSummary, Event, HermesSessionDto, HermesSessions, NoParams, NoteQuery,
    NoteSummary, TerminalScope, TerminalServerDto, events, methods,
};
use gpui_kit::{App, AsyncApp, Context, Task, WeakEntity};

use super::Stores;
use super::connection::ConnectionEvent;
use super::navigation::{Area, WorkspaceSection};
use super::rpc::Rpc;
use super::session::{Backend, Route};

/// The areas `capabilities` lets the account use, in the sidebar's order.
pub fn visible_areas(capabilities: &Capabilities) -> Vec<Area> {
    Area::ALL
        .into_iter()
        .filter(|area| match area {
            Area::Chats => !capabilities.hermes_only,
            Area::Hermes => capabilities.hermes,
            Area::Notes => capabilities.notes,
            Area::Terminal => capabilities.terminal,
            Area::Channels => capabilities.channels,
            Area::Workspace => capabilities.workspace,
            Area::Calendar => capabilities.calendar,
            // As the phone offers them: with Settings' Advanced on.
            Area::Automations => capabilities.scheduled_tasks,
        })
        .collect()
}

/// The workspace sections the account may manage, in the workspace's order.
pub fn workspace_sections(capabilities: &Capabilities) -> Vec<WorkspaceSection> {
    WorkspaceSection::ALL
        .into_iter()
        .filter(|section| match section {
            WorkspaceSection::Models => capabilities.workspace_models,
            WorkspaceSection::Knowledge => capabilities.workspace_knowledge,
            WorkspaceSection::Prompts => capabilities.workspace_prompts,
            WorkspaceSection::Tools => capabilities.workspace_tools,
            WorkspaceSection::Skills => capabilities.workspace_skills,
        })
        .collect()
}

/// Whether `chat_id` is a Hermes session's chat (the daemon's
/// `local:hermes_<session>`).
pub fn is_hermes_chat(chat_id: &str) -> bool {
    chat_id
        .strip_prefix("local:hermes_")
        .is_some_and(|session| !session.is_empty())
}

/// The areas whose lists come from the daemon.
const LISTED: [Area; 4] = [Area::Notes, Area::Channels, Area::Hermes, Area::Terminal];

#[derive(Default)]
pub struct AreasStore {
    rpc: Option<Rpc>,
    /// `None` until listed (for this account).
    pub notes: Option<Vec<NoteSummary>>,
    pub channels: Option<Vec<ChannelSummary>>,
    /// The account may make a channel (New Channel…).
    pub channels_can_create: bool,
    pub hermes: Option<HermesSessions>,
    /// Hermes's Hidden Chats, read when its pane opens: `None` until read,
    /// `Err` when the read failed.
    pub hermes_hidden: Option<Result<Vec<HermesSessionDto>, String>>,
    /// The Hidden Chats last listed, kept through a refresh that fails: an
    /// open hidden session is still found (its title, its More menu).
    hermes_hidden_known: Vec<HermesSessionDto>,
    pub terminals: Option<Vec<TerminalServerDto>>,
    /// The areas whose list could not be read (and none is held): the
    /// sidebar offers Try Again instead of a loading line.
    pub failed: BTreeSet<Area>,
    /// The server chats send as `terminal_id` (`terminal.select`).
    pub terminal_selected: Option<String>,
    /// The areas whose lists are kept: those shown, and the terminals the
    /// composer offers.
    wanted: BTreeSet<Area>,
    /// Bumped whenever a list changes (the sidebar's rows cache).
    revision: u64,
    /// Bumped per account: answers for the previous one are dropped.
    generation: u64,
    fetches: HashMap<Area, Task<()>>,
    hidden_fetch: Option<Task<()>>,
}

impl AreasStore {
    pub fn new(rpc: Rpc) -> Self {
        Self {
            rpc: Some(rpc),
            ..Self::default()
        }
    }

    pub fn revision(&self) -> u64 {
        self.revision
    }

    /// A note the list holds.
    pub fn note(&self, id: &str) -> Option<&NoteSummary> {
        self.notes.iter().flatten().find(|n| n.id == id)
    }

    pub fn channel(&self, id: &str) -> Option<&ChannelSummary> {
        self.channels.iter().flatten().find(|c| c.id == id)
    }

    /// A Hermes session, listed, archived or hidden.
    pub fn hermes_session(&self, id: &str) -> Option<&HermesSessionDto> {
        self.hermes
            .iter()
            .flat_map(|h| h.sessions.iter().chain(h.archived.iter()))
            .chain(self.hermes_hidden_known.iter())
            .find(|s| s.id == id)
    }

    /// Session `id` is gone (deleted): not found through the Hidden Chats
    /// last listed either.
    pub fn forget_hermes_hidden(&mut self, id: &str) {
        self.hermes_hidden_known.retain(|s| s.id != id);
    }

    /// The Hermes list as an action on a session answered it.
    pub fn adopt_hermes(&mut self, sessions: HermesSessions, cx: &mut Context<Self>) {
        self.hermes = Some(sessions);
        self.failed.remove(&Area::Hermes);
        self.changed(cx);
    }

    /// Reads Hermes's Hidden Chats again (`hermes.hidden.list`).
    pub fn refresh_hermes_hidden(&mut self, cx: &mut Context<Self>) {
        let Some(rpc) = self.rpc.clone() else {
            return;
        };
        let generation = self.generation;
        let call = rpc.call::<methods::HermesHiddenList>(&NoParams);
        self.hidden_fetch = Some(cx.spawn(
            async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
                let result = call.await;
                this.update(cx, |s, cx| {
                    if s.generation != generation {
                        return;
                    }
                    s.hermes_hidden = Some(match result {
                        Ok(list) => {
                            s.hermes_hidden_known = list.sessions.clone();
                            Ok(list.sessions)
                        }
                        Err(e) => {
                            log::warn!("hermes.hidden.list: {e}");
                            Err(e.to_string())
                        }
                    });
                    s.changed(cx);
                })
                .ok();
            },
        ));
    }

    pub fn terminal(&self, id: &str) -> Option<&TerminalServerDto> {
        self.terminals.iter().flatten().find(|t| t.id == id)
    }

    /// Keeps the lists of `areas` from now on: lists each one new, and
    /// forgets the lists of those that went.
    pub fn set_wanted(&mut self, areas: &[Area], cx: &mut Context<Self>) {
        let next: BTreeSet<Area> = areas.iter().copied().collect();
        if next == self.wanted {
            return;
        }
        let added: Vec<Area> = next.difference(&self.wanted).copied().collect();
        let removed: Vec<Area> = self.wanted.difference(&next).copied().collect();
        self.wanted = next;
        for area in removed {
            self.fetches.remove(&area);
            self.clear(area);
        }
        for area in added {
            self.refresh(area, cx);
        }
        self.changed(cx);
    }

    fn clear(&mut self, area: Area) {
        self.failed.remove(&area);
        match area {
            Area::Notes => self.notes = None,
            Area::Channels => {
                self.channels = None;
                // One account's right: the next one's list says whether it
                // has it.
                self.channels_can_create = false;
            }
            Area::Hermes => {
                self.hermes = None;
                self.hermes_hidden = None;
                self.hermes_hidden_known.clear();
            }
            Area::Terminal => {
                self.terminals = None;
                // The account's pick: the next account's list says its own.
                self.terminal_selected = None;
            }
            _ => {}
        }
    }

    /// Another account (or none): every list goes.
    pub fn reset(&mut self, cx: &mut Context<Self>) {
        self.generation += 1;
        self.fetches.clear();
        self.wanted.clear();
        for area in LISTED {
            self.clear(area);
        }
        self.changed(cx);
    }

    /// Lists every area shown again.
    pub fn refresh_all(&mut self, cx: &mut Context<Self>) {
        for area in self.wanted.clone() {
            self.refresh(area, cx);
        }
    }

    /// Lists `area` again, if it is shown.
    pub fn refresh(&mut self, area: Area, cx: &mut Context<Self>) {
        if !self.wanted.contains(&area) {
            return;
        }
        let Some(rpc) = self.rpc.clone() else {
            return;
        };
        if self.failed.remove(&area) {
            self.changed(cx);
        }
        let generation = self.generation;
        let task = match area {
            Area::Notes => {
                let call = rpc.call::<methods::NotesList>(&NoteQuery::default());
                cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
                    let result = call.await;
                    this.update(cx, |s, cx| {
                        if s.generation == generation {
                            match result {
                                Ok(list) => s.notes = Some(list.notes),
                                Err(e) => {
                                    log::warn!("notes.list: {e}");
                                    s.failed.insert(Area::Notes);
                                }
                            }
                            s.changed(cx);
                        }
                    })
                    .ok();
                })
            }
            Area::Channels => {
                let call = rpc.call::<methods::ChannelsList>(&NoParams);
                cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
                    let result = call.await;
                    this.update(cx, |s, cx| {
                        if s.generation == generation {
                            match result {
                                Ok(list) => {
                                    s.channels_can_create = list.can_create;
                                    s.channels = Some(list.channels);
                                }
                                Err(e) => {
                                    log::warn!("channels.list: {e}");
                                    s.failed.insert(Area::Channels);
                                }
                            }
                            s.changed(cx);
                        }
                    })
                    .ok();
                })
            }
            Area::Hermes => {
                // Hidden Chats, while its pane has been read, follows too.
                if self.hermes_hidden.is_some() {
                    self.refresh_hermes_hidden(cx);
                }
                let call = rpc.call::<methods::HermesSessions>(&NoParams);
                cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
                    let result = call.await;
                    this.update(cx, |s, cx| {
                        if s.generation == generation {
                            match result {
                                Ok(sessions) => s.hermes = Some(sessions),
                                Err(e) => {
                                    log::warn!("hermes.sessions: {e}");
                                    s.failed.insert(Area::Hermes);
                                }
                            }
                            s.changed(cx);
                        }
                    })
                    .ok();
                })
            }
            Area::Terminal => {
                let call = rpc.call::<methods::TerminalServers>(&TerminalScope::default());
                cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
                    let result = call.await;
                    this.update(cx, |s, cx| {
                        if s.generation == generation {
                            match result {
                                Ok(list) => {
                                    s.terminals = Some(list.servers);
                                    s.terminal_selected = list.selected_id;
                                }
                                Err(e) => {
                                    log::warn!("terminal.servers: {e}");
                                    s.failed.insert(Area::Terminal);
                                }
                            }
                            s.changed(cx);
                        }
                    })
                    .ok();
                })
            }
            // These areas load their lists in their own stores and panes.
            Area::Chats | Area::Workspace | Area::Calendar | Area::Automations => return,
        };
        self.fetches.insert(area, task);
    }

    /// The terminal servers and the selection, as `terminal.select`
    /// answered them.
    pub fn set_terminals(
        &mut self,
        servers: conduit_protocol::TerminalServers,
        cx: &mut Context<Self>,
    ) {
        // A list read asked before this answer is older: it must not put
        // the last pick back.
        self.fetches.remove(&Area::Terminal);
        self.terminals = Some(servers.servers);
        self.terminal_selected = servers.selected_id;
        self.changed(cx);
    }

    fn changed(&mut self, cx: &mut Context<Self>) {
        self.revision += 1;
        cx.notify();
    }
}

/// Follows the daemon's events and the session for `stores.areas`.
pub fn wire(stores: &Stores, cx: &mut App) {
    stores.connection.update(cx, |c, _| {
        c.subscribe(
            "areas",
            &[
                events::NOTES_CHANGED,
                events::CHANNELS_CHANGED,
                events::HERMES_CHANGED,
                events::CAPABILITIES_CHANGED,
                events::TURN_FINISHED,
            ],
            vec![],
        )
    });
    {
        let s = stores.clone();
        cx.subscribe(&stores.connection, move |_, event, cx| {
            let area = match event {
                ConnectionEvent::Connected { .. } | ConnectionEvent::Gap => {
                    s.areas.update(cx, |a, cx| a.refresh_all(cx));
                    return;
                }
                ConnectionEvent::Daemon(event) => match event.as_ref() {
                    Event::NotesChanged(_) => Area::Notes,
                    Event::ChannelsChanged => Area::Channels,
                    Event::HermesChanged(_) => Area::Hermes,
                    Event::TurnFinished(done) if is_hermes_chat(&done.chat_id) => Area::Hermes,
                    // A terminal server comes and goes with the account's
                    // capabilities.
                    Event::CapabilitiesChanged => Area::Terminal,
                    _ => return,
                },
                _ => return,
            };
            s.areas.update(cx, |a, cx| a.refresh(area, cx));
        })
        .detach();
    }
    let last_account: std::rc::Rc<std::cell::RefCell<Option<Option<String>>>> = Default::default();
    let check = {
        let s = stores.clone();
        move |cx: &mut App| {
            let account = s
                .accounts
                .read(cx)
                .list
                .as_ref()
                .and_then(|l| l.active_account_id.clone());
            let changed = last_account
                .borrow()
                .as_ref()
                .is_some_and(|last| *last != account);
            *last_account.borrow_mut() = Some(account);
            if changed {
                s.areas.update(cx, |a, cx| a.reset(cx));
            }
            let session = s.session.read(cx);
            let wanted = if session.route(cx) == Route::Main {
                let mut wanted = visible_areas(&session.capabilities());
                // The composer offers Open WebUI's terminals in chats, also
                // when the Terminal area is hidden because each one needs a
                // saved chat.
                if session.backend(cx) == Some(Backend::OpenWebUi) {
                    wanted.push(Area::Terminal);
                }
                wanted
            } else {
                vec![]
            };
            s.areas.update(cx, |a, cx| a.set_wanted(&wanted, cx));
        }
    };
    let check = std::rc::Rc::new(check);
    {
        let check = check.clone();
        cx.observe(&stores.session, move |_, cx| check(cx)).detach();
    }
    cx.observe(&stores.accounts, move |_, cx| check(cx))
        .detach();
}

#[cfg(test)]
mod tests {
    use gpui_kit::{AppContext as _, TestAppContext};

    use super::*;
    use crate::stores::rpc::fake::FakeDaemon;

    fn note(id: &str, pinned: bool) -> NoteSummary {
        serde_json::from_value(serde_json::json!({
            "id": id, "title": id, "updatedAtMs": 1, "pinned": pinned,
        }))
        .unwrap()
    }

    #[test]
    fn areas_follow_the_capabilities_in_the_sidebars_order() {
        let open_webui = Capabilities {
            notes: true,
            channels: true,
            terminal: true,
            workspace: true,
            workspace_prompts: true,
            workspace_models: true,
            calendar: true,
            ..Default::default()
        };
        assert_eq!(
            visible_areas(&open_webui),
            [
                Area::Chats,
                Area::Notes,
                Area::Terminal,
                Area::Channels,
                Area::Workspace,
                Area::Calendar
            ]
        );
        assert_eq!(
            workspace_sections(&open_webui),
            [WorkspaceSection::Models, WorkspaceSection::Prompts]
        );
        let hermes_only = Capabilities {
            hermes: true,
            hermes_only: true,
            ..Default::default()
        };
        assert_eq!(visible_areas(&hermes_only), [Area::Hermes]);
        assert!(is_hermes_chat("local:hermes_s1"));
        assert!(!is_hermes_chat("local:hermes_") && !is_hermes_chat("c1"));
        assert_eq!(visible_areas(&Capabilities::default()), [Area::Chats]);
        // Scheduled tasks are offered with Settings' Advanced on, as on the
        // phone: the server allowing them is not enough.
        let tasks = |advanced: bool| Capabilities {
            automations: true,
            scheduled_tasks: advanced,
            ..Default::default()
        };
        assert_eq!(visible_areas(&tasks(false)), [Area::Chats]);
        assert_eq!(
            visible_areas(&tasks(true)),
            [Area::Chats, Area::Automations]
        );
    }

    #[gpui_kit::test]
    fn only_shown_areas_are_listed_and_a_reset_forgets_them(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        daemon.returns::<methods::NotesList>(conduit_protocol::NoteList {
            notes: vec![note("pinned", true), note("recent", false)],
        });
        daemon.returns::<methods::ChannelsList>(conduit_protocol::ChannelList::default());
        let store = cx.new(|_| AreasStore::new(daemon.rpc()));
        store.update(cx, |s, cx| s.set_wanted(&[Area::Chats, Area::Notes], cx));
        cx.run_until_parked();
        store.read_with(cx, |s, _| {
            let ids: Vec<&str> = s.notes.iter().flatten().map(|n| n.id.as_str()).collect();
            assert_eq!(ids, ["pinned", "recent"]);
            assert!(s.note("recent").is_some());
            assert!(s.channels.is_none(), "channels are not shown");
        });
        assert!(daemon.calls::<methods::ChannelsList>().is_empty());
        // An event for a shown area lists it again; one for another does not.
        store.update(cx, |s, cx| {
            s.refresh(Area::Notes, cx);
            s.refresh(Area::Channels, cx);
        });
        cx.run_until_parked();
        assert_eq!(daemon.calls::<methods::NotesList>().len(), 2);
        assert!(daemon.calls::<methods::ChannelsList>().is_empty());
        // Notes hidden: their list goes.
        store.update(cx, |s, cx| s.set_wanted(&[Area::Chats], cx));
        store.read_with(cx, |s, _| assert!(s.notes.is_none()));
        store.update(cx, |s, cx| {
            s.set_wanted(&[Area::Channels], cx);
            s.reset(cx);
        });
        cx.run_until_parked();
        store.read_with(cx, |s, _| assert!(s.channels.is_none()));
    }
    /// A Hidden Chats refresh that fails says so in its pane, but the
    /// sessions it last listed are still found (an open hidden session's
    /// title and More menu).
    #[gpui_kit::test]
    fn a_failed_hidden_refresh_keeps_the_last_sessions_found(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        let session: HermesSessionDto = serde_json::from_value(
            serde_json::json!({"id": "s1", "chatId": "local:hermes_s1", "title": "Tide tables"}),
        )
        .unwrap();
        daemon.once::<methods::HermesHiddenList>(Ok(HermesSessions {
            sessions: vec![session],
            ..Default::default()
        }));
        daemon.once::<methods::HermesHiddenList>(Err(conduit_daemon::protocol::error(
            "rpc.daemonUnavailable",
            "offline",
        )));
        let store = cx.new(|_| AreasStore::new(daemon.rpc()));
        store.update(cx, |s, cx| s.refresh_hermes_hidden(cx));
        cx.run_until_parked();
        store.read_with(cx, |s, _| assert!(s.hermes_session("s1").is_some()));
        store.update(cx, |s, cx| s.refresh_hermes_hidden(cx));
        cx.run_until_parked();
        store.read_with(cx, |s, _| {
            assert!(
                matches!(s.hermes_hidden, Some(Err(_))),
                "the pane says the list failed"
            );
            assert_eq!(
                s.hermes_session("s1").map(|h| h.title.as_str()),
                Some("Tide tables"),
                "a failed refresh lost the hidden session"
            );
        });
        // Another account: nothing of the last one's is found.
        store.update(cx, |s, cx| s.reset(cx));
        store.read_with(cx, |s, _| assert!(s.hermes_session("s1").is_none()));
    }

    /// New Channel is one account's right: the next account's channels
    /// list says whether it has it, and until then it is not offered.
    #[gpui_kit::test]
    fn another_account_is_offered_no_new_channel_before_its_list(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        daemon.once::<methods::ChannelsList>(Ok(conduit_protocol::ChannelList {
            enabled: true,
            can_create: true,
            ..Default::default()
        }));
        daemon.once::<methods::ChannelsList>(Err(conduit_daemon::protocol::error(
            "rpc.daemonUnavailable",
            "offline",
        )));
        let store = cx.new(|_| AreasStore::new(daemon.rpc()));
        store.update(cx, |s, cx| s.set_wanted(&[Area::Channels], cx));
        cx.run_until_parked();
        store.read_with(cx, |s, _| assert!(s.channels_can_create));
        // Another account: its first list fails.
        store.update(cx, |s, cx| {
            s.reset(cx);
            s.set_wanted(&[Area::Channels], cx);
        });
        store.read_with(cx, |s, _| {
            assert!(
                !s.channels_can_create,
                "the last account's New Channel was offered"
            )
        });
        cx.run_until_parked();
        store.read_with(cx, |s, _| assert!(!s.channels_can_create));
    }

    #[gpui_kit::test]
    fn a_list_that_fails_says_so_until_it_is_asked_again(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        daemon.once::<methods::NotesList>(Err(conduit_daemon::protocol::error(
            "rpc.daemonUnavailable",
            "offline",
        )));
        daemon.returns::<methods::NotesList>(conduit_protocol::NoteList {
            notes: vec![note("n1", false)],
        });
        let store = cx.new(|_| AreasStore::new(daemon.rpc()));
        store.update(cx, |s, cx| s.set_wanted(&[Area::Chats, Area::Notes], cx));
        cx.run_until_parked();
        store.read_with(cx, |s, _| {
            assert!(s.notes.is_none());
            assert!(
                s.failed.contains(&Area::Notes),
                "a failed list is not loading"
            );
        });
        // Try Again: loading while asked, then the list.
        store.update(cx, |s, cx| s.refresh(Area::Notes, cx));
        store.read_with(cx, |s, _| assert!(s.failed.is_empty()));
        cx.run_until_parked();
        store.read_with(cx, |s, _| {
            assert_eq!(s.notes.as_ref().map(Vec::len), Some(1));
            assert!(s.failed.is_empty());
        });
    }

    /// An Open WebUI account whose every terminal needs a saved chat (Open
    /// WebUI 0.13.4's chat-scoped templates) has no Terminal area, since the
    /// page opens terminals outside any chat. Its chats still get them: a
    /// saved chat is offered them, a new one is not.
    #[gpui_kit::test]
    fn chats_are_offered_terminals_the_hidden_terminal_area_cannot_open(cx: &mut TestAppContext) {
        use crate::stores::Stores;
        use crate::stores::accounts::tests::{account, list};
        use crate::stores::session::tests::{auth, handshake, request};
        use crate::views::terminal::chat::offered;

        let daemon = FakeDaemon::new();
        daemon.returns::<methods::AccountsList>(list(vec![account("a", "Avery", true, true)]));
        daemon
            .returns::<methods::AuthStatus>(auth(conduit_protocol::AuthPhase::Authenticated, true));
        daemon
            .on::<methods::SystemHandshake>(|_| Ok(serde_json::json!({"needsOnboarding": false})));
        daemon.returns::<methods::SystemCapabilities>(Capabilities {
            notes: true,
            ..Default::default()
        });
        daemon.returns::<methods::TerminalServers>(conduit_protocol::TerminalServers {
            servers: vec![TerminalServerDto {
                id: "per-chat".into(),
                name: "Chat bench".into(),
                kind: "system".into(),
                requires_saved_chat: true,
                device: false,
            }],
            selected_id: None,
        });
        let scratch =
            std::env::temp_dir().join(format!("conduit-areas-terminals-{}", std::process::id()));
        let stores = cx.update(|cx| {
            let stores = Stores::for_test(daemon.rpc(), &scratch, cx);
            wire(&stores, cx);
            stores
        });
        stores
            .session
            .update(cx, |s, cx| s.on_connected(&handshake(None), request(), cx));
        cx.run_until_parked();

        let capabilities = stores.session.read_with(cx, |s, cx| {
            assert_eq!(s.route(cx), Route::Main);
            s.capabilities()
        });
        assert_eq!(
            visible_areas(&capabilities),
            [Area::Chats, Area::Notes],
            "the Terminal area was shown, but it can open none of these terminals"
        );
        stores.areas.read_with(cx, |a, _| {
            let servers = a.terminals.as_deref().unwrap_or_default();
            let selected = a.terminal_selected.as_deref();
            assert_eq!(
                offered(servers, selected, Some("chat-harbour")),
                [(
                    "per-chat".to_string(),
                    "Chat bench".to_string(),
                    false,
                    false
                )],
                "a saved chat was offered none of the account's terminals"
            );
            assert!(
                offered(servers, selected, None).is_empty(),
                "a new chat was offered a terminal that needs a saved chat"
            );
        });
    }

    fn servers(selected: &str) -> conduit_protocol::TerminalServers {
        serde_json::from_value(serde_json::json!({
            "servers": [
                {"id": "box", "name": "Workbench", "kind": "system"},
                {"id": "lab", "name": "Lab", "kind": "system"},
            ],
            "selectedId": selected,
        }))
        .unwrap()
    }

    /// Another account: the terminal chats send goes with the list, and a
    /// `terminal.select` answer is not undone by a list read asked before it.
    #[gpui_kit::test]
    fn the_terminal_selection_is_the_accounts_and_the_newest(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        daemon.returns::<methods::TerminalServers>(servers("box"));
        let store = cx.new(|_| AreasStore::new(daemon.rpc()));
        store.update(cx, |s, cx| s.set_wanted(&[Area::Chats, Area::Terminal], cx));
        cx.run_until_parked();
        store.read_with(cx, |s, _| {
            assert_eq!(s.terminal_selected.as_deref(), Some("box"))
        });

        store.update(cx, |s, cx| s.reset(cx));
        store.read_with(cx, |s, _| {
            assert_eq!(
                s.terminal_selected, None,
                "the last account's terminal outlived its list"
            )
        });

        let older = daemon.hold::<methods::TerminalServers>();
        store.update(cx, |s, cx| s.set_wanted(&[Area::Chats, Area::Terminal], cx));
        cx.run_until_parked();
        store.update(cx, |s, cx| s.set_terminals(servers("lab"), cx));
        drop(older);
        cx.run_until_parked();
        store.read_with(cx, |s, _| {
            assert_eq!(
                s.terminal_selected.as_deref(),
                Some("lab"),
                "a list read asked before the pick undid it"
            )
        });
    }
}
