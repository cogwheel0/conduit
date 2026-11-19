//! The main pane for the sidebar's other areas: what an item opens when it
//! is not a chat.
//!
//! [`AreaPane`] draws the toolbar every pane shares (the item's title, and
//! the sidebar's toggle while the sidebar is hidden) and hands the body to
//! the item's area, one module each, so an area's changes stay in its own
//! module:
//!
//! * notes ([`crate::views::notes`]), [`channels`], [`workspace`],
//!   [`terminal`], [`calendar`] and [`automations`], [`hermes`].
//!
//! An item no module draws shows a neutral page: the item's glyph, its
//! title and the area it is in.

pub mod automations;
pub mod calendar;
pub mod channels;
pub mod hermes;
pub mod hermes_jobs;
pub mod terminal;
pub mod workspace;

use std::collections::HashMap;
use std::rc::Rc;

use conduit_components::ActiveConduitTheme as _;
use conduit_components::assets::{IconName, icon};
use conduit_components::theme::ConduitTheme;
use conduit_components::views::focus::ControlExt as _;
use conduit_components::views::kit::{IconButton, heading};
use conduit_components::views::shell::toolbar_capsule;
use conduit_components::window::{TOOLBAR_HEIGHT, TRAFFIC_LIGHTS_WIDTH, drag_region};
use gpui_kit::prelude::*;
use gpui_kit::{
    AnyElement, App, Context, Entity, FontWeight, Role, SharedString, Subscription, Window, div, px,
};

use crate::actions::ToggleSidebar;
use crate::l10n::{ActiveL10n as _, L10n};
use crate::stores::Stores;
use crate::stores::layout::LayoutStore;
use crate::stores::navigation::AreaItem;
use crate::views::main_window::SidebarReveal;
use crate::views::notes::area::NotesArea;
use crate::views::sidebar::{area_label, item_icon, item_title};

/// The pane the main window shows for an area item.
pub struct AreaPane {
    stores: Stores,
    layout: Entity<LayoutStore>,
    /// The workspace's pane, once a section was shown.
    pub workspace: Option<Entity<crate::views::workspace::WorkspacePane>>,
    /// The open channel's pane, while a channel is shown.
    pub channel: Option<Entity<crate::views::channels::ChannelPane>>,
    /// The Notes section's list and note panes.
    pub notes: Entity<NotesArea>,
    /// The calendar's pane, once it was shown.
    pub calendar: Option<Entity<crate::views::calendar::CalendarPane>>,
    /// Scheduled tasks' pane, once it was shown.
    pub tasks: Option<Entity<crate::views::tasks::TasksPane>>,
    /// The item the pane showed last, so an area that comes back is read
    /// again (as the phone's page is when it reopens).
    last_item: Option<AreaItem>,
    /// Each terminal server's pane, once opened: its shell and folder live
    /// on while another item shows, as mobile's terminal tab keeps alive.
    /// Dropped (and their handles let go) as soon as the account changes.
    terminals: HashMap<String, Entity<crate::views::terminal::pane::TerminalPane>>,
    /// The account the terminal panes belong to.
    terminals_account: Option<String>,
    /// The Group Chat shown, while one is (its timeline and composer).
    pub room: Option<Entity<crate::views::hermes_room::HermesRoomPane>>,
    _subscriptions: Vec<Subscription>,
}

impl AreaPane {
    pub fn new(
        stores: Stores,
        layout: Entity<LayoutStore>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Self {
        let notes = {
            let stores = stores.clone();
            cx.new(|cx| NotesArea::new(stores, window, cx))
        };
        let subscriptions = vec![
            // Hidden Chats reads its list each time it opens; Scheduled
            // Agents is polled while it shows.
            cx.subscribe(&stores.navigation, |this, _, event, cx| {
                let crate::stores::navigation::NavigationEvent::Changed(selection) = event;
                if *selection == crate::stores::navigation::Selection::Area(AreaItem::HermesHidden)
                {
                    this.stores
                        .areas
                        .update(cx, |a, cx| a.refresh_hermes_hidden(cx));
                }
                let jobs =
                    *selection == crate::stores::navigation::Selection::Area(AreaItem::HermesJobs);
                this.stores
                    .hermes_admin
                    .update(cx, |a, cx| a.watch_jobs(jobs, cx));
            }),
            cx.observe(&stores.hermes_admin, |_, _, cx| cx.notify()),
            cx.observe(&stores.navigation, |this: &mut Self, nav, cx| {
                // A channel left (for a chat, say, which this pane does not
                // draw) closes at once: it is no longer in front.
                channels::on_navigation(this, cx);
                // A chat in between: an area that comes back is new again.
                if nav.read(cx).selected_item().is_none() {
                    this.last_item = None;
                }
                cx.notify()
            }),
            cx.observe(&stores.areas, |_, _, cx| cx.notify()),
            // Another account (or none): the last one's terminals go now,
            // not when the next terminal opens.
            cx.observe(&stores.accounts, |this: &mut Self, _, cx| {
                this.follow_account(cx)
            }),
            cx.observe(&stores.hermes_rooms, |_, _, cx| cx.notify()),
            cx.observe(&layout, |_, _, cx| cx.notify()),
            cx.observe(&notes, |_, _, cx| cx.notify()),
        ];
        let terminals_account = stores.accounts.read(cx).active().map(|a| a.id.clone());
        Self {
            stores,
            layout,
            workspace: None,
            channel: None,
            notes,
            calendar: None,
            tasks: None,
            last_item: None,
            terminals: HashMap::new(),
            terminals_account,
            room: None,
            _subscriptions: subscriptions,
        }
    }

    /// The pane of terminal server `id`, made on first use.
    pub fn terminal(
        &mut self,
        id: &str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Entity<crate::views::terminal::pane::TerminalPane> {
        self.follow_account(cx);
        if let Some(pane) = self.terminals.get(id) {
            return pane.clone();
        }
        let stores = self.stores.clone();
        let server = id.to_string();
        let pane = cx
            .new(|cx| crate::views::terminal::pane::TerminalPane::new(stores, server, window, cx));
        self._subscriptions
            .push(cx.observe(&pane, |_, _, cx| cx.notify()));
        self.terminals.insert(id.to_string(), pane.clone());
        pane
    }

    /// When the account in use is another than the terminals', lets every
    /// terminal pane's handle go and closes the Computer viewer and the port
    /// previews: all of them hold the last account's terminal.
    fn follow_account(&mut self, cx: &mut Context<Self>) {
        let account = self.stores.accounts.read(cx).active().map(|a| a.id.clone());
        if account == self.terminals_account {
            return;
        }
        self.terminals_account = account;
        for (_, pane) in self.terminals.drain() {
            pane.update(cx, |p, cx| p.release(cx));
        }
        crate::views::terminal::close_account_windows(cx);
        cx.notify();
    }

    /// The pane of the terminal server shown now, if any.
    pub fn shown_terminal(
        &self,
        cx: &App,
    ) -> Option<Entity<crate::views::terminal::pane::TerminalPane>> {
        match self.item(cx)? {
            AreaItem::Terminal(id) => self.terminals.get(&id).cloned(),
            _ => None,
        }
    }

    /// The item shown, if the main window shows one.
    pub fn item(&self, cx: &App) -> Option<AreaItem> {
        self.stores.navigation.read(cx).selected_item().cloned()
    }

    /// The shown item's title, as its pane and toolbar say it.
    pub fn title(&self, cx: &App) -> Option<String> {
        let item = self.item(cx)?;
        Some(
            channels::shown_title(self, &item, cx)
                .unwrap_or_else(|| title_of(&item, &self.stores, cx)),
        )
    }
}

/// `item`'s title, from the account's lists ("Untitled" until listed).
pub fn title_of(item: &AreaItem, stores: &Stores, cx: &App) -> String {
    let areas = stores.areas.read(cx);
    let listed = match item {
        AreaItem::Note(id) => areas.note(id).map(|n| n.title.clone()),
        AreaItem::Channel(id) => areas
            .channel(id)
            .map(|c| crate::views::channels::display_title(c, cx.l10n())),
        AreaItem::HermesSession(id) => areas.hermes_session(id).map(|s| s.title.clone()),
        AreaItem::HermesHidden | AreaItem::HermesJobs => None,
        AreaItem::HermesBot(name) => stores
            .hermes_rooms
            .read(cx)
            .bot(name)
            .map(|b| b.title.clone()),
        AreaItem::HermesRoom(id) => stores
            .hermes_rooms
            .read(cx)
            .room(id)
            .map(|r| r.name.clone()),
        AreaItem::Terminal(id) => areas
            .terminal(id)
            .map(|t| t.name.clone())
            .filter(|n| !n.trim().is_empty())
            .or_else(|| Some(id.clone())),
        AreaItem::AllNotes
        | AreaItem::Workspace(_)
        | AreaItem::Calendar
        | AreaItem::Automations => None,
    };
    item_title(item, listed.as_deref(), cx.l10n())
}

/// The page an area shows until its own pane lands: the item's glyph, its
/// title as the page's heading, and the area it is in.
pub fn placeholder(item: &AreaItem, title: &str, t: &ConduitTheme, l: &L10n) -> AnyElement {
    let r = t.roles;
    let area = area_label(item.area(), l);
    div()
        .id("area-pane-body")
        .role(Role::Group)
        .aria_label(SharedString::from(format!("{title}, {area}")))
        .flex_1()
        .min_h_0()
        .flex()
        .flex_col()
        .items_center()
        .justify_center()
        .gap(px(8.))
        .px(px(32.))
        .pb(px(TOOLBAR_HEIGHT))
        .child(icon(item_icon(item), 32., r.text_faint))
        .child(
            heading(
                "area-pane-title",
                SharedString::from(title.to_string()),
                1,
                22.,
                FontWeight::SEMIBOLD,
                r.text,
            )
            .max_w(px(480.))
            .text_center(),
        )
        .child(
            div()
                .text_size(px(t.metrics.control))
                .text_color(r.text_subtle)
                .child(SharedString::from(area)),
        )
        .into_any_element()
}

impl Render for AreaPane {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let t = cx.conduit().clone();
        let l = cx.l10n().clone();
        let r = t.roles;
        let Some(item) = self.item(cx) else {
            channels::sync(self, None, window, cx);
            self.last_item = None;
            self.room = None;
            return div().size_full().bg(r.content).into_any_element();
        };
        let returning = self.last_item.as_ref() == Some(&item);
        self.last_item = Some(item.clone());
        channels::sync(self, Some(&item), window, cx);
        // A Group Chat keeps its pane (its composer, its scroll) while it
        // stays shown.
        match &item {
            AreaItem::HermesRoom(id) => {
                // A pane holds one account's words for one gateway's room:
                // another key (an account or gateway change) gets its own.
                let key = self.stores.hermes_rooms.read(cx).room_key(id);
                if self.room.as_ref().is_none_or(|p| p.read(cx).key != key) {
                    let (stores, id) = (self.stores.clone(), id.clone());
                    self.room = Some(cx.new(|cx| {
                        crate::views::hermes_room::HermesRoomPane::new(stores, id, window, cx)
                    }));
                }
            }
            _ => self.room = None,
        }
        let title = channels::shown_title(self, &item, cx)
            .unwrap_or_else(|| title_of(&item, &self.stores, cx));
        let terminal = match &item {
            AreaItem::Terminal(id) => Some(self.terminal(id, window, cx)),
            _ => None,
        };
        // The shown item's own buttons, at the toolbar's trailing edge: a
        // note's or a channel's; a room's follow. A
        // terminal's sit beside its leading title instead (below).
        let trailing = match &item {
            AreaItem::Note(_) => self
                .notes
                .read(cx)
                .note_pane()
                .cloned()
                .and_then(|p| p.update(cx, |p, cx| p.toolbar(&t, cx)))
                .map(|trailing| {
                    toolbar_capsule(&t)
                        .p(px(2.))
                        .relative()
                        .child(trailing)
                        .into_any_element()
                }),
            _ => channels::toolbar_items(self, cx),
        };
        let body = match &item {
            AreaItem::AllNotes | AreaItem::Note(_) => self.notes.clone().into_any_element(),
            AreaItem::Channel(id) => channels::pane(self, id, &title, &t, &l),
            // Shown in the chat pane; here only while the main window
            // switches over.
            AreaItem::HermesSession(_) => placeholder(&item, &title, &t, &l),
            AreaItem::HermesHidden => hermes::hidden_pane(&self.stores, &t, &l, cx),
            AreaItem::HermesRoom(_) => match &self.room {
                Some(room) => room.clone().into_any_element(),
                None => placeholder(&item, &title, &t, &l),
            },
            // A bot opens its Bot Chat in the chat pane.
            AreaItem::HermesBot(_) => placeholder(&item, &title, &t, &l),
            AreaItem::HermesJobs => hermes_jobs::pane(&self.stores, cx),
            AreaItem::Workspace(section) => {
                workspace::pane(&mut self.workspace, &self.stores, *section, window, cx)
                    .into_any_element()
            }
            AreaItem::Terminal(_) => match &terminal {
                Some(pane) => terminal::pane(pane),
                None => placeholder(&item, &title, &t, &l),
            },
            AreaItem::Calendar => {
                calendar::pane(&mut self.calendar, returning, &self.stores, window, cx)
                    .into_any_element()
            }
            AreaItem::Automations => {
                automations::pane(&mut self.tasks, returning, &self.stores, window, cx)
                    .into_any_element()
            }
        };
        // As the chat's toolbar: with the sidebar hidden it starts after
        // the traffic lights and offers the sidebar back.
        let sidebar_visible = self.layout.read(cx).state.sidebar_visible;
        let reveal = SidebarReveal::of(sidebar_visible, cx);
        let shown = ((0.3 - reveal) / 0.25).clamp(0., 1.);
        let covered = t.metrics.sidebar_width * reveal;
        let inset = if reveal < 1. {
            (TRAFFIC_LIGHTS_WIDTH + 8. - covered).max(10.)
        } else {
            10.
        };
        let keys = conduit_components::views::focus::hints(cx);
        let room_actions = match &item {
            AreaItem::HermesRoom(id) => Some(crate::views::hermes_room::toolbar_actions(
                &self.stores,
                id,
                cx,
            ))
            .filter(|a| !a.is_empty()),
            _ => None,
        };
        let toolbar = drag_region("area-pane-toolbar")
            .role(Role::Toolbar)
            .aria_label(SharedString::from(title.clone()))
            .relative()
            .h(px(TOOLBAR_HEIGHT))
            .flex_none()
            .flex()
            .items_center()
            .pl(px(inset))
            .pr(px(10.))
            .when(reveal < 1., |d| {
                d.child(
                    toolbar_capsule(&t).p(px(2.)).opacity(shown).child(
                        IconButton::new(
                            "show-sidebar",
                            IconName::PanelLeft,
                            l.desktop_menu_show_sidebar(),
                        )
                        .size(30., 16.)
                        .round()
                        .shortcut(keys.toggle_sidebar.clone())
                        .on_click(Rc::new(|_, window, cx| {
                            window.dispatch_action(Box::new(ToggleSidebar), cx)
                        })),
                    ),
                )
            })
            .when(terminal.is_none(), |d| {
                d.child(
                    div()
                        .absolute()
                        .top_0()
                        .bottom_0()
                        .left(px(TRAFFIC_LIGHTS_WIDTH + 48.))
                        .right(px(TRAFFIC_LIGHTS_WIDTH + 48.))
                        .flex()
                        .items_center()
                        .justify_center()
                        .child(match &item {
                            // A room names itself with its bots' faces and who
                            // is at work; a click opens Room Info.
                            AreaItem::HermesRoom(id) => {
                                crate::views::hermes_room::toolbar_title(&self.stores, id, &t, cx)
                            }
                            _ => div()
                                .id("area-pane-title")
                                // The item's name, as VoiceOver's headings list
                                // finds it (a note's own title is a field).
                                .role(Role::Heading)
                                .aria_level(1)
                                .aria_label(SharedString::from(title.clone()))
                                .truncate()
                                .text_size(px(t.metrics.control))
                                .font_weight(FontWeight::SEMIBOLD)
                                .text_color(r.text)
                                .child(SharedString::from(title.clone()))
                                .into_any_element(),
                        }),
                )
                .child(div().flex_1())
                .children(trailing)
                .when_some(room_actions, |d, actions| {
                    d.child(
                        toolbar_capsule(&t)
                            .p(px(2.))
                            .flex()
                            .gap(px(2.))
                            .children(actions),
                    )
                })
            })
            // A terminal's controls fill the trailing edge, so its title
            // leads, as a unified toolbar's does.
            .when_some(terminal.as_ref(), |d, pane| {
                let subtitle = pane.read(cx).shell_title().map(str::to_string);
                d.child(
                    div()
                        .flex_1()
                        .min_w_0()
                        .pl(px(if reveal < 1. { 10. } else { 4. }))
                        .flex()
                        .flex_col()
                        .child({
                            // The server picker: the title opens a menu of the
                            // account's terminal servers.
                            let current = pane.read(cx).server_id().to_string();
                            let focus = gpui_kit::Focusable::focus_handle(pane.read(cx), cx);
                            div()
                                .id("area-pane-title")
                                .role(Role::Button)
                                .aria_label(SharedString::from(
                                    l.desktop_terminal_server_picker(&title),
                                ))
                                .flex()
                                .items_center()
                                .gap(px(4.))
                                .max_w_full()
                                .px(px(6.))
                                .ml(px(-6.))
                                .rounded(px(6.))
                                .cursor_pointer()
                                .hover(|s| s.bg(r.hover))
                                .keyboard_shadow(cx)
                                .on_click(move |e, window, cx| {
                                    // The menu's command goes through the pane.
                                    window.focus(&focus, cx);
                                    crate::views::terminal::pane::server_menu(
                                        &current,
                                        e.position(),
                                        window,
                                        cx,
                                    );
                                })
                                .child(
                                    div()
                                        .truncate()
                                        .text_size(px(t.metrics.control))
                                        .font_weight(FontWeight::SEMIBOLD)
                                        .text_color(r.text)
                                        .child(SharedString::from(title.clone())),
                                )
                                .child(icon(IconName::ChevronDown, 11., r.text_subtle))
                        })
                        .when_some(subtitle, |d, sub| {
                            d.child(
                                div()
                                    .truncate()
                                    .text_size(px(t.metrics.small))
                                    .text_color(r.text_subtle)
                                    .child(SharedString::from(sub)),
                            )
                        }),
                )
                .child(crate::views::terminal::pane::TerminalPane::toolbar(
                    pane, window, cx,
                ))
            });
        div()
            .id("area-pane")
            .on_action(cx.listener(
                |this, a: &crate::views::terminal::pane::SwitchServer, _, cx| {
                    let item = AreaItem::Terminal(a.0.clone());
                    this.stores
                        .navigation
                        .update(cx, |n, cx| n.open_item(item, cx));
                },
            ))
            .size_full()
            .flex()
            .flex_col()
            .bg(r.content)
            .child(toolbar)
            .child(body)
            .into_any_element()
    }
}

#[cfg(test)]
mod tests {
    use conduit_protocol::{TerminalAttached, methods};
    use gpui_kit::{AppContext as _, TestAppContext};

    use super::AreaPane;
    use crate::stores::Stores;
    use crate::stores::accounts::tests::{account, list};
    use crate::stores::layout::LayoutStore;
    use crate::stores::rpc::fake::FakeDaemon;

    /// Another account signing in lets the last one's terminal go at once:
    /// its handle is detached without another terminal being opened.
    #[gpui_kit::test]
    fn an_account_change_lets_the_last_accounts_terminals_go(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        daemon.returns::<methods::TerminalAttach>(TerminalAttached {
            handle: "handle-avery".into(),
            cwd: "/".into(),
            supported: false,
        });
        let scratch = std::env::temp_dir().join(format!("conduit-panes-{}", std::process::id()));
        let stores = cx.update(|cx| {
            crate::views::test_globals(cx);
            Stores::for_test(daemon.rpc(), &scratch, cx)
        });
        stores.accounts.update(cx, |a, cx| {
            a.adopt(list(vec![account("a", "Avery", true, true)]), cx)
        });
        let layout = cx.new(|_| LayoutStore::load(scratch.join("layout.json")));
        let s = stores.clone();
        let (area, vcx) =
            cx.add_window_view(move |window, cx| AreaPane::new(s, layout, window, cx));
        vcx.update(|window, cx| {
            area.update(cx, |a, cx| {
                a.terminal("box", window, cx);
            })
        });
        vcx.run_until_parked();
        assert!(daemon.calls::<methods::TerminalDetach>().is_empty());

        stores.accounts.update(vcx, |a, cx| {
            a.adopt(
                list(vec![
                    account("a", "Avery", false, true),
                    account("b", "Blair", true, true),
                ]),
                cx,
            )
        });
        vcx.run_until_parked();
        assert_eq!(
            daemon.calls::<methods::TerminalDetach>(),
            vec![serde_json::json!({"handle": "handle-avery"})],
            "the last account's terminal stayed attached"
        );
    }

    /// The terminals are the Open WebUI account's: when it is parked for a
    /// LibreChat account taking charge, they go with it.
    #[gpui_kit::test]
    fn the_open_webui_account_parked_for_librechat_takes_its_terminals(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        daemon.returns::<methods::TerminalAttach>(TerminalAttached {
            handle: "handle-avery".into(),
            cwd: "/".into(),
            supported: false,
        });
        let scratch = std::env::temp_dir().join(format!("conduit-panes-lc-{}", std::process::id()));
        let stores = cx.update(|cx| {
            crate::views::test_globals(cx);
            Stores::for_test(daemon.rpc(), &scratch, cx)
        });
        stores.accounts.update(cx, |a, cx| {
            a.adopt(list(vec![account("a", "Avery", true, true)]), cx)
        });
        let layout = cx.new(|_| LayoutStore::load(scratch.join("layout.json")));
        let s = stores.clone();
        let (area, vcx) =
            cx.add_window_view(move |window, cx| AreaPane::new(s, layout, window, cx));
        vcx.update(|window, cx| {
            area.update(cx, |a, cx| {
                a.terminal("box", window, cx);
            })
        });
        vcx.run_until_parked();

        // LibreChat takes charge: the Open WebUI account is parked (no
        // longer the one in use).
        let mut parked = list(vec![account("a", "Avery", false, true)]);
        parked.primary = conduit_protocol::PrimaryAccount::LibreChat;
        parked.active_account_id = None;
        parked.active_libre_chat_account_id = Some("lc-blake".into());
        stores.accounts.update(vcx, |a, cx| a.adopt(parked, cx));
        vcx.run_until_parked();
        assert_eq!(
            daemon.calls::<methods::TerminalDetach>(),
            vec![serde_json::json!({"handle": "handle-avery"})],
            "the parked account's terminal stayed attached"
        );
    }
}
