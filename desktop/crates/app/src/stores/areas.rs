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
//! * **Lists**, for the areas shown only: `notes.list` (pinned first, then
//!   recent) on `notes.changed`; `channels.list` (with unread counts) on
//!   `channels.changed`; `hermes.sessions` (pinned, conversations,
//!   archived) on `hermes.changed`, and when an answer in a Hermes chat
//!   ends (a new chat is a new session); `terminal.servers` when the area
//!   appears. Everything is refetched after a reconnect or an event gap,
//!   and forgotten when the account changes. Nothing is patched locally.
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
use super::session::Route;

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
            Area::Automations => capabilities.automations,
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
    pub hermes: Option<HermesSessions>,
    pub terminals: Option<Vec<TerminalServerDto>>,
    /// The areas whose list could not be read (and none is held): the
    /// sidebar offers Try Again instead of a loading line.
    pub failed: BTreeSet<Area>,
    /// The areas shown, whose lists are kept.
    wanted: BTreeSet<Area>,
    /// Bumped whenever a list changes (the sidebar's rows cache).
    revision: u64,
    /// Bumped per account: answers for the previous one are dropped.
    generation: u64,
    fetches: HashMap<Area, Task<()>>,
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

    /// A Hermes session, listed or archived.
    pub fn hermes_session(&self, id: &str) -> Option<&HermesSessionDto> {
        self.hermes
            .iter()
            .flat_map(|h| h.sessions.iter().chain(h.archived.iter()))
            .find(|s| s.id == id)
    }

    pub fn terminal(&self, id: &str) -> Option<&TerminalServerDto> {
        self.terminals.iter().flatten().find(|t| t.id == id)
    }

    /// Shows `areas` from now on: lists each one newly shown, and forgets
    /// the lists of those that went.
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
            Area::Channels => self.channels = None,
            Area::Hermes => self.hermes = None,
            Area::Terminal => self.terminals = None,
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
                                Ok(list) => s.channels = Some(list.channels),
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
                                Ok(list) => s.terminals = Some(list.servers),
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
                    Event::HermesChanged => Area::Hermes,
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
                visible_areas(&session.capabilities())
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
}
