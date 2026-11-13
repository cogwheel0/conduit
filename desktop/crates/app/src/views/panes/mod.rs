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
pub mod terminal;
pub mod workspace;

use std::collections::HashMap;
use std::rc::Rc;

use conduit_components::ActiveConduitTheme as _;
use conduit_components::assets::{IconName, icon};
use conduit_components::theme::ConduitTheme;
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
    /// Dropped (and their handles let go) when the account changes.
    terminals: HashMap<String, Entity<crate::views::terminal::pane::TerminalPane>>,
    /// The account the terminal panes belong to.
    terminals_account: Option<String>,
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
            // Hidden Chats reads its list each time it opens.
            cx.subscribe(&stores.navigation, |this, _, event, cx| {
                let crate::stores::navigation::NavigationEvent::Changed(selection) = event;
                if *selection == crate::stores::navigation::Selection::Area(AreaItem::HermesHidden)
                {
                    this.stores
                        .areas
                        .update(cx, |a, cx| a.refresh_hermes_hidden(cx));
                }
            }),
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
            cx.observe(&layout, |_, _, cx| cx.notify()),
            cx.observe(&notes, |_, _, cx| cx.notify()),
        ];
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
            terminals_account: None,
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
        let account = self.stores.accounts.read(cx).active().map(|a| a.id.clone());
        if account != self.terminals_account {
            for (_, pane) in self.terminals.drain() {
                pane.update(cx, |p, cx| p.release(cx));
            }
            self.terminals_account = account;
        }
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
        AreaItem::HermesHidden => None,
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
            return div().size_full().bg(r.content).into_any_element();
        };
        let returning = self.last_item.as_ref() == Some(&item);
        self.last_item = Some(item.clone());
        channels::sync(self, Some(&item), window, cx);
        let title = channels::shown_title(self, &item, cx)
            .unwrap_or_else(|| title_of(&item, &self.stores, cx));
        let terminal = match &item {
            AreaItem::Terminal(id) => Some(self.terminal(id, window, cx)),
            _ => None,
        };
        // The shown item's own buttons, at the toolbar's trailing edge: a
        // note's or a channel's. A terminal's sit beside its
        // leading title instead (below).
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
                        .child(
                            div()
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
                                .child(SharedString::from(title.clone())),
                        ),
                )
                .child(div().flex_1())
                .children(trailing)
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
