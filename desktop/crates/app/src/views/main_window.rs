//! The main window's root: the routing gate over the session.
//!
//! * A blocking [`Status`] (fatal, or nothing routed yet) replaces the
//!   content with its status card.
//! * [`Route::Main`]: the main frame, the [`SidebarView`] beside the
//!   [`ChatPane`] or, for an item of another area, its
//!   [`AreaPane`], with the ⌘K [`PaletteView`] over both.
//!   First run and sign-in live in the setup window ([`crate::windows`]);
//!   the main window closes when a session ends, so it shows its status
//!   card only for the moment before.
//! * Over the content: the card for the oldest `ui.request` (answered with
//!   ⌥⌘↩ / ⌥⌘⌫), toasts, and the reconnect banner.
//! * Actions handled here: New Chat (⌘N) and New Temporary Chat (⇧⌘N),
//!   the palette (⌘K), Find in Chat (⌘F, ⌘G, ⇧⌘G) and Search Chats (⌥⌘F),
//!   the Go menu (Back ⌘[, Forward ⌘], the sidebar's sections ⌘1…),
//!   ⌘W (which only hides the window with "Close to the menu bar" on), and
//!   the sidebar's context-menu commands ([`ChatMenu`], [`MoveSelected`]).
//!
//! The sidebar's NSVisualEffectView follows the sidebar setting, the
//! density's width and the sidebar's visibility.
//!
//! Hiding or showing the sidebar slides it over 220 ms on AppKit's
//! ease-in-ease-out, as NSSplitView collapses a pane
//! (`motion::specs::SIDEBAR`), interruptible, with the content reflowing
//! beside it; the toolbar's traffic-light room follows the same progress
//! ([`SidebarReveal`]). Under Reduce Motion it is instant.

use conduit_components::ActiveConduitTheme as _;
use conduit_components::motion::{self, Reduced, specs};
#[cfg(target_os = "macos")]
use conduit_components::theme::SidebarStyle;
use conduit_components::views::shell::MainWindowFrame;
use conduit_protocol::BulkChatAction;
use gpui_kit::prelude::*;
use gpui_kit::{
    AnyElement, App, Context, Entity, FocusHandle, Focusable, Global, Role, SharedString,
    Subscription, Window, div, px,
};

use crate::actions::{
    AllowRequest, ArchiveChat, AskConduit, ChatSettings, CloseWindow, DeleteChat, DenyRequest,
    DuplicateChat, ExportChatAs, FindChats, FindInChat, FindNext, FindPrevious, GenerateChatTitle,
    GoBack, GoForward, GoToSection, MarkChatUnread, MoveChatTo, NewChat, NewFolder,
    NewTemporaryChat, NextChat, OpenPalette, PreviousChat, ReadAloud, RegenerateLastAnswer,
    RenameChat, SaveTemporaryChat, ShareChat, ShowBranches, TogglePinChat, ToolSettings, VoiceCall,
};
use crate::l10n::ActiveL10n as _;
use crate::stores::Stores;
use crate::stores::connection::Status;
use crate::stores::layout::LayoutStore;
use crate::stores::navigation::AreaItem;
use crate::stores::session::Route;
use crate::stores::settings::SettingsStore;
use crate::views::approvals::ApprovalsView;
use crate::views::chat_pane::ChatPane;
use crate::views::hermes_sessions::{HermesCommand, HermesMenu};
use crate::views::palette::PaletteView;
use crate::views::panes::AreaPane;
use crate::views::sidebar::{
    ActOnSelected, ChatCommand, ChatMenu, FolderMenu, MoveSelected, SidebarView,
};
use crate::views::status::{offline_banner, reconnect_banner, status_screen};
use crate::views::toasts::toast_overlay;

/// How much of the sidebar shows (0…1) this frame, set by the main window
/// before its content draws: the chat toolbar keeps the traffic lights'
/// room as the sidebar slides away.
#[derive(Clone, Copy, Debug)]
pub struct SidebarReveal(pub f32);

impl Global for SidebarReveal {}

impl SidebarReveal {
    /// This frame's share, or the setting's when nothing set one.
    pub fn of(visible: bool, cx: &App) -> f32 {
        cx.try_global::<Self>()
            .map_or(if visible { 1. } else { 0. }, |r| r.0)
    }
}

/// What the window shows. When it changes, focus leaves the page that went
/// (as AppKit's first responder does when a window's content is swapped).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Page {
    Status,
    Main,
}

pub struct MainWindow {
    pub stores: Stores,
    settings: Entity<SettingsStore>,
    layout: Entity<LayoutStore>,
    pub chat_pane: Entity<ChatPane>,
    /// What an item of another area opens in.
    pub area_pane: Entity<AreaPane>,
    pub sidebar: Entity<SidebarView>,
    pub palette: Entity<PaletteView>,
    pub approvals: Entity<ApprovalsView>,
    focus: FocusHandle,
    /// The page drawn last.
    page: Option<Page>,
    #[cfg(target_os = "macos")]
    material: crate::shell::macos::SidebarMaterial,
    /// Frames drawn without the sidebar while its material is still up.
    #[cfg(target_os = "macos")]
    material_hold: MaterialHold,
    _subscriptions: Vec<Subscription>,
}

/// The sidebar's material leaves only after [`MaterialHold::FRAMES`] frames
/// drawn without the sidebar. AppKit shows a view's removal at once, while
/// GPUI's frames reach the screen a frame or more later: taken off in the
/// frame the sidebar went, the material left the sidebar GPUI still showed
/// over bare wallpaper for a frame (seen with Reduce Motion's instant hide).
/// Behind the content's opaque fill, a material kept a little longer shows
/// nothing; one asked for again meanwhile simply stays.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct MaterialHold(u8);

/// What to do with the material this frame.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum MaterialStep {
    /// Show it this wide, or take it off.
    Sync(Option<f64>),
    /// Keep it up, and draw again next frame.
    Hold,
}

impl MaterialHold {
    pub const FRAMES: u8 = 3;

    /// `want`: the material's width this frame (`None`: no sidebar);
    /// `shown`: whether it is up.
    pub fn step(&mut self, want: Option<f64>, shown: bool) -> MaterialStep {
        if want.is_some() || !shown || self.0 >= Self::FRAMES {
            self.0 = 0;
            return MaterialStep::Sync(want);
        }
        self.0 += 1;
        MaterialStep::Hold
    }
}

impl MainWindow {
    /// The window leaves the screen, hidden to the menu bar or closed,
    /// however that was asked for ([`crate::desktop::main_window_leaving`]):
    /// the chat it shows is left.
    pub fn leaving_screen(&mut self, cx: &mut Context<Self>) {
        self.chat_pane.update(cx, |p, cx| p.window_closing(cx));
    }

    pub fn new(
        stores: Stores,
        settings: Entity<SettingsStore>,
        layout: Entity<LayoutStore>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Self {
        let approvals = cx.new(|cx| ApprovalsView::new(stores.clone(), window, cx));
        let chat_pane = {
            let (stores, layout, approvals) = (stores.clone(), layout.clone(), approvals.clone());
            cx.new(|cx| ChatPane::new(stores, layout, approvals, window, cx))
        };
        let sidebar = cx.new(|cx| SidebarView::new(stores.clone(), window, cx));
        let area_pane = {
            let (stores, layout) = (stores.clone(), layout.clone());
            cx.new(|cx| AreaPane::new(stores, layout, window, cx))
        };
        let palette = cx.new(|cx| PaletteView::new(stores.clone(), window, cx));
        // The Chat menu greys its commands for one chat while chats are
        // chosen: it follows the choosing, not every redraw of the list.
        let mut choosing = false;
        let subscriptions = vec![
            cx.observe(&sidebar, move |_, sidebar, cx| {
                let now = sidebar.read(cx).has_selection();
                if now != choosing {
                    choosing = now;
                    cx.defer(crate::menus::refresh_menus);
                }
            }),
            cx.observe(&stores.connection, |_, _, cx| cx.notify()),
            cx.observe(&stores.session, |_, _, cx| cx.notify()),
            cx.observe(&stores.accounts, |_, _, cx| cx.notify()),
            cx.observe(&stores.toasts, |_, _, cx| cx.notify()),
            cx.observe(&approvals, |_, _, cx| cx.notify()),
            cx.observe(&stores.palette, |_, _, cx| cx.notify()),
            cx.observe(&stores.navigation, |_, _, cx| cx.notify()),
            cx.observe(&settings, |_, _, cx| cx.notify()),
            cx.observe(&layout, |_, _, cx| cx.notify()),
            // Geometry and the system's light/dark.
            cx.observe_window_bounds(window, |this, window, cx| {
                let bounds = window.window_bounds();
                this.layout.update(cx, |l, cx| l.set_bounds(bounds, cx));
                // View › Enter or Exit Full Screen.
                crate::menus::set_full_screen(window.is_fullscreen(), cx);
            }),
            // Keyboard Navigation may have been switched in System Settings.
            cx.observe_window_activation(window, |_, window, cx| {
                if window.is_window_active() {
                    crate::sync_keyboard_access(cx);
                }
            }),
            cx.observe_window_appearance(window, {
                let settings = settings.clone();
                move |_, window, cx| {
                    let dark = matches!(
                        window.appearance(),
                        gpui_kit::WindowAppearance::Dark | gpui_kit::WindowAppearance::VibrantDark
                    );
                    settings.update(cx, |s, cx| s.set_system_dark(dark, cx));
                }
            }),
        ];
        let focus = cx.focus_handle();
        window.focus(&focus, cx);
        Self {
            stores,
            settings,
            layout,
            chat_pane,
            area_pane,
            sidebar,
            palette,
            approvals,
            focus,
            page: None,
            #[cfg(target_os = "macos")]
            material: Default::default(),
            #[cfg(target_os = "macos")]
            material_hold: MaterialHold::default(),
            _subscriptions: subscriptions,
        }
    }

    /// The route, as the window shows it.
    pub fn route(&self, cx: &App) -> Route {
        self.stores.session.read(cx).route(cx)
    }

    /// Whether the main frame shows (routed there, nothing blocking).
    pub fn shows_main(&self, cx: &App) -> bool {
        let route = self.route(cx);
        let error = self
            .stores
            .session
            .read(cx)
            .error
            .as_ref()
            .map(|e| e.to_string());
        let status = self
            .stores
            .connection
            .read(cx)
            .status(route != Route::Unknown, error.as_deref());
        route == Route::Main && !status.blocks(route != Route::Unknown)
    }

    /// ⌘K: opens the palette (or closes it when open).
    pub fn toggle_palette(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if !self.shows_main(cx) {
            return;
        }
        self.palette.update(cx, |p, cx| {
            if p.is_open(cx) {
                p.close(window, cx)
            } else {
                p.open(window, cx)
            }
        });
    }

    /// New Chat (⌘N, File › New Chat, the sidebar's button, the palette):
    /// a new chat, with the composer focused to type into.
    /// ⌥⌘↩ / ⌥⌘⌫: the approvals card answers first, else the open chat's
    /// prompt card (its first or second button: Allow or Deny, Submit or
    /// Skip).
    pub fn answer_request(&mut self, allow: bool, cx: &mut Context<Self>) {
        let answered = self
            .approvals
            .update(cx, |a, cx| if allow { a.allow(cx) } else { a.deny(cx) });
        // The chat's prompt card only while its chat is what the window
        // shows (another area keeps the chat, and its card, out of sight).
        if !answered && answers_chat_prompt(self.shows_main(cx), self.shows_chat(cx)) {
            let card = self.chat_pane.read(cx).prompt_card.clone();
            card.update(cx, |p, cx| {
                if allow {
                    p.primary(cx);
                } else {
                    p.secondary(cx);
                }
            });
        }
    }

    pub fn new_chat(&mut self, temporary: bool, window: &mut Window, cx: &mut Context<Self>) {
        if !self.shows_main(cx) {
            return;
        }
        self.stores
            .navigation
            .update(cx, |n, cx| n.new_chat(temporary, cx));
        self.chat_pane
            .update(cx, |p, cx| p.focus_composer(window, cx));
    }

    /// The open chat's id, when the Chat menu can act on it (not another
    /// user's).
    fn menu_chat(&self, cx: &App) -> Option<String> {
        let id = self.stores.navigation.read(cx).selected_chat()?;
        self.stores
            .chat_list
            .read(cx)
            .find(id)
            .filter(|c| !c.read_only)
            .map(|c| c.id.clone())
    }

    /// The open Hermes session, as the sidebar lists it.
    pub fn open_hermes(&self, cx: &App) -> Option<conduit_protocol::HermesSessionDto> {
        match self.stores.navigation.read(cx).selected_item()? {
            AreaItem::HermesSession(id) => self.stores.areas.read(cx).hermes_session(id).cloned(),
            _ => None,
        }
    }

    /// A Hermes session's command, from any of its menus: Rename shows the
    /// sidebar first (the name is edited in its row).
    pub fn run_hermes(
        &mut self,
        session_id: &str,
        command: HermesCommand,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if command == HermesCommand::Rename && !self.layout.read(cx).state.sidebar_visible {
            self.layout.update(cx, |l, cx| l.toggle_sidebar(cx));
        }
        self.sidebar
            .update(cx, |s, cx| s.run_hermes(session_id, command, window, cx));
    }

    /// A Chat menu command on the open chat (the sidebar carries it out, as
    /// its context menu's).
    fn chat_command(
        &mut self,
        command: impl FnOnce(&conduit_protocol::ChatSummary) -> ChatCommand,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        // A Hermes session open: the same commands, on it.
        if let Some(session) = self.open_hermes(cx) {
            let probe = conduit_protocol::ChatSummary {
                id: session.chat_id.clone(),
                title: session.title.clone(),
                updated_at_ms: session.updated_at_ms.unwrap_or_default(),
                pinned: session.pinned,
                archived: session.archived,
                folder_id: None,
                model: None,
                tags: vec![],
                shared: false,
                read_only: false,
                unread: false,
                menu: Default::default(),
            };
            let hermes = match command(&probe) {
                ChatCommand::Pin => Some(HermesCommand::Pin),
                ChatCommand::Unpin => Some(HermesCommand::Unpin),
                ChatCommand::Rename => Some(HermesCommand::Rename),
                ChatCommand::Archive => Some(HermesCommand::Archive),
                ChatCommand::Unarchive => Some(HermesCommand::Unarchive),
                ChatCommand::Delete => Some(HermesCommand::Delete),
                _ => None,
            };
            if let Some(hermes) = hermes {
                self.run_hermes(&session.id, hermes, window, cx);
            }
            return;
        }
        let Some(id) = self.menu_chat(cx) else {
            return;
        };
        let Some(chat) = self.stores.chat_list.read(cx).find(&id).cloned() else {
            return;
        };
        let command = command(&chat);
        // With several chats selected in the sidebar, Archive, Move to and
        // Delete… act on all of them (as Mail's Message menu does).
        if self
            .sidebar
            .update(cx, |s, cx| s.run_on_selection(&command, window, cx))
        {
            return;
        }
        // Renaming happens in the sidebar's row: show it first.
        if command == ChatCommand::Rename && !self.layout.read(cx).state.sidebar_visible {
            self.layout.update(cx, |l, cx| l.toggle_sidebar(cx));
        }
        self.sidebar
            .update(cx, |s, cx| s.run(&id, command, window, cx));
    }

    /// Chat › Next Chat (⌃⇥) or Previous Chat (⌃⇧⇥): opens the chat after
    /// or before the open one in the sidebar's order, wrapping at the ends
    /// (from a new chat, the first or the last). A multiple selection ends,
    /// as an arrow ends Finder's.
    pub fn step_chat(&mut self, forward: bool, cx: &mut Context<Self>) {
        if !self.shows_main(cx) {
            return;
        }
        let open = self
            .stores
            .navigation
            .read(cx)
            .selected_chat()
            .map(String::from);
        let next = crate::views::sidebar_keys::step_chat(
            self.sidebar.read(cx).rows(),
            open.as_deref(),
            forward,
        );
        let Some(id) = next.filter(|n| open.as_deref() != Some(n.as_str())) else {
            return;
        };
        self.sidebar.update(cx, |s, cx| s.end_selection(cx));
        self.stores.navigation.update(cx, |n, cx| n.open(id, cx));
    }

    /// Edit › Find › Search Chats (⌥⌘F): the sidebar's search field (the
    /// sidebar shown first).
    pub fn find(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if !self.shows_main(cx) {
            return;
        }
        if !self.layout.read(cx).state.sidebar_visible {
            self.layout.update(cx, |l, cx| l.toggle_sidebar(cx));
        }
        self.sidebar.update(cx, |s, cx| s.focus_search(window, cx));
    }

    /// File › New Folder: the sidebar shown first, then a new folder named
    /// in place at the top of its Folders.
    pub fn new_folder(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if !self.shows_main(cx) {
            return;
        }
        if !self.layout.read(cx).state.sidebar_visible {
            self.layout.update(cx, |l, cx| l.toggle_sidebar(cx));
        }
        self.sidebar
            .update(cx, |s, cx| s.start_new_folder(None, window, cx));
    }

    /// Whether the main pane shows the chat pane (a chat, or a new one),
    /// not an item of another area.
    pub fn shows_chat(&self, cx: &App) -> bool {
        self.stores.navigation.read(cx).selection().is_chat()
    }

    /// Whether a step of history may be shown: its area is one the sidebar
    /// still shows.
    fn usable_step(
        &self,
        cx: &App,
    ) -> impl Fn(&crate::stores::navigation::Selection) -> bool + 'static {
        let areas = self.sidebar.read(cx).areas(cx);
        move |step| areas.contains(&step.area())
    }

    /// Go › Back (⌘[) or Forward (⌘]).
    pub fn go(&mut self, back: bool, cx: &mut Context<Self>) {
        if !self.shows_main(cx) {
            return;
        }
        let usable = self.usable_step(cx);
        self.stores.navigation.update(cx, |n, cx| {
            if back {
                n.go_back(usable, cx)
            } else {
                n.go_forward(usable, cx)
            }
        });
    }

    /// Go › a section (⌘1…): the `index`th area the sidebar shows, the
    /// sidebar shown first.
    pub fn go_to_section(&mut self, index: usize, window: &mut Window, cx: &mut Context<Self>) {
        if !self.shows_main(cx) {
            return;
        }
        let areas = self.sidebar.read(cx).areas(cx);
        let Some(area) = index.checked_sub(1).and_then(|i| areas.get(i)).copied() else {
            return;
        };
        if !self.layout.read(cx).state.sidebar_visible {
            self.layout.update(cx, |l, cx| l.toggle_sidebar(cx));
        }
        self.sidebar
            .update(cx, |s, cx| s.go_to_area(area, window, cx));
    }

    fn main_frame(&self, reveal: f32, cx: &App) -> AnyElement {
        let content: AnyElement = if self.shows_chat(cx) {
            self.chat_pane.clone().into_any_element()
        } else {
            self.area_pane.clone().into_any_element()
        };
        let mut frame = MainWindowFrame::new(content).sidebar_reveal(reveal);
        if reveal > 0. {
            frame = frame.sidebar(self.sidebar.clone());
        }
        // Always drawn: it fades out after it closes (and draws nothing
        // once gone).
        frame = frame.overlay(self.palette.clone());
        frame.into_any_element()
    }
}

/// Whether the approvals card floats over the window: everywhere but the
/// chat pane, which docks it above its composer.
fn floats_approvals(shows_main: bool, shows_chat: bool) -> bool {
    !(shows_main && shows_chat)
}

impl Focusable for MainWindow {
    fn focus_handle(&self, _: &gpui_kit::App) -> FocusHandle {
        self.focus.clone()
    }
}

impl Render for MainWindow {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let route = self.route(cx);
        let session_error = self
            .stores
            .session
            .read(cx)
            .error
            .as_ref()
            .map(|e| e.to_string());
        let status = self
            .stores
            .connection
            .read(cx)
            .status(route != Route::Unknown, session_error.as_deref());
        let blocked = status.blocks(route != Route::Unknown);
        let sidebar_visible = self.layout.read(cx).state.sidebar_visible;
        let t = cx.conduit().clone();
        let shows_main = !blocked && route == Route::Main;
        let reveal = motion::tween(
            "sidebar-reveal",
            if sidebar_visible { 1. } else { 0. },
            specs::SIDEBAR,
            Reduced::Snap,
            window,
            cx,
        );
        cx.set_global(SidebarReveal(reveal));
        let shows_sidebar = shows_main && reveal > 0.;

        // The material stays full width while any of the sidebar shows:
        // the opaque content beside the sliding sidebar covers the rest.
        // (Resized each frame it would run ahead of GPUI's frames, which
        // AppKit shows a frame or two later, and the desktop would show
        // through the gap.)
        #[cfg(target_os = "macos")]
        {
            let want = (shows_sidebar && t.prefs.sidebar == SidebarStyle::Material)
                .then_some(f64::from(t.metrics.sidebar_width));
            match self.material_hold.step(want, self.material.is_shown()) {
                MaterialStep::Sync(want) => self.material.sync(window, want),
                MaterialStep::Hold => window.request_animation_frame(),
            }
        }
        #[cfg(not(target_os = "macos"))]
        let _ = &t;
        // The list's faded ends are a mask on the window's content: off
        // while the sidebar is not drawn.
        if !shows_sidebar {
            self.sidebar.read(cx).clear_edges(window);
        }

        let (page, content): (Page, AnyElement) = if shows_main {
            (
                Page::Main,
                self.main_frame(if shows_sidebar { reveal } else { 0. }, cx),
            )
        } else {
            // Blocked, not routed yet, or a session that just ended (the
            // setup window is taking over).
            (
                Page::Status,
                status_screen(&status, &self.stores.connection, cx).into_any_element(),
            )
        };
        // A field of the page that went (the server form's address, after
        // Connect) would keep focus out of sight, and Tab would find no way
        // into the new page: once that page is drawn, focus comes back to
        // the window unless it already went somewhere on it.
        if self.page.is_some_and(|p| p != page) {
            let root = self.focus.clone();
            window.on_next_frame(move |window, cx| {
                if !root.contains_focused(window, cx) {
                    window.focus(&root, cx);
                }
            });
        }
        self.page = Some(page);
        let banner = match status {
            Status::Reconnecting { .. } if !blocked => Some(reconnect_banner(
                cx.l10n().desktop_core_reconnecting().into(),
                cx,
            )),
            Status::Connecting | Status::CoreStarting if !blocked => Some(reconnect_banner(
                cx.l10n().desktop_core_connecting().into(),
                cx,
            )),
            // Opened from what the daemon stored, with the server out of
            // reach: say so, as the phone does, until it answers again.
            _ if shows_main && self.stores.session.read(cx).server_unreachable(cx) => {
                Some(offline_banner(cx.l10n().desktop_offline().into(), cx))
            }
            // After an update: What's New, until it is read or closed.
            _ if shows_main => crate::views::release_notes::banner(window, cx),
            _ => None,
        };
        // On the main frame the chat pane docks the card above its composer;
        // over another area's pane it floats, as it does off the main frame.
        let floats = floats_approvals(shows_main, self.shows_chat(cx));
        let approvals =
            (!blocked && floats && self.approvals.read(cx).has_request(cx)).then(|| {
                div()
                    .absolute()
                    .bottom(px(20.))
                    .left_0()
                    .right_0()
                    .flex()
                    .justify_center()
                    .px(px(20.))
                    .child(self.approvals.clone())
            });
        // On the main frame the chat pane docks toasts above its composer.
        let toasts = if shows_main {
            None
        } else {
            toast_overlay(&self.stores.toasts, window, cx)
        };
        // Centred in the content pane, beside the sidebar (as far as it
        // has slid in).
        let banner = banner.map(|b| {
            b.when(shows_sidebar, |d| {
                d.pl(px(t.metrics.sidebar_width * reveal))
            })
        });
        // A window with nothing focused sends actions to its root only, past
        // these handlers (and the menus would read as unavailable): keep
        // focus somewhere.
        if window.focused(cx).is_none() {
            window.focus(&self.focus, cx);
        }
        // A menu item is greyed only when no handler answers its action:
        // AppKit asks GPUI whether the action is available, and an item's
        // `disabled` never reaches it. So a command that would do nothing
        // gets no handler, by the rules the menus are built with.
        let open_chat = self.menu_chat(cx).filter(|_| shows_main).and_then(|id| {
            let list = self.stores.chat_list.read(cx);
            list.find(&id).map(|c| (c.archived, c.menu.clone()))
        });
        let chat_menu = open_chat.is_some();
        let (archived, offered) = open_chat.unwrap_or_default();
        // With chats chosen, a command for one chat is left undone.
        let choosing = self.sidebar.read(cx).has_selection();
        let acts = |command: ChatCommand| {
            chat_menu && (!choosing || crate::views::sidebar::bulk_action(&command).is_some())
        };
        let archive = if archived {
            ChatCommand::Unarchive
        } else {
            ChatCommand::Archive
        };
        let (can_go_back, can_go_forward) = {
            let usable = self.usable_step(cx);
            let navigation = self.stores.navigation.read(cx);
            (
                shows_main && navigation.can_go_back(&usable),
                shows_main && navigation.can_go_forward(&usable),
            )
        };
        // Find in Chat: over any open chat, read-only ones too.
        let findable = shows_main && self.shows_chat(cx) && self.chat_pane.read(cx).chat.is_some();
        let makes_folders = shows_main && self.sidebar.read(cx).can_make_folders(cx);
        let makes_channels = shows_main && self.stores.areas.read(cx).channels_can_create;
        let makes_rooms = shows_main && self.stores.hermes_rooms.read(cx).can_create();
        // The chat pane's commands, as `menus::menu_state` reads them.
        let pane = self.chat_pane.read(cx);
        let asks_conduit = shows_main && pane.can_ask_conduit(cx);
        let reads_aloud = shows_main && pane.can_read_aloud(cx);
        let calls =
            self.stores.call.read(cx).is_active() || (shows_main && pane.call_startable(cx));
        let chat_settings = shows_main && pane.can_open_chat_settings(cx);
        let tool_settings = shows_main && !pane.settings_offer.tool_targets.is_empty();
        let (settings, speech) = (self.settings.clone(), self.stores.speech.clone());

        // A click on no control focuses the window itself (closing the model
        // picker, Stop): named, so VoiceOver says where focus went.
        div()
            .id("main-window")
            .role(Role::Group)
            .aria_label(SharedString::from(cx.l10n().app_title()))
            .key_context("ConduitMainWindow")
            .track_focus(&self.focus)
            .on_action(cx.listener(|this, _: &AllowRequest, _, cx| {
                this.answer_request(true, cx);
            }))
            .on_action(cx.listener(|this, _: &DenyRequest, _, cx| {
                this.answer_request(false, cx);
            }))
            .on_action(
                cx.listener(|this, _: &NewChat, window, cx| this.new_chat(false, window, cx)),
            )
            .on_action(
                cx.listener(|this, _: &NewTemporaryChat, window, cx| {
                    this.new_chat(true, window, cx)
                }),
            )
            // ⌘W: with "Close to the menu bar" on, the window only hides.
            .on_action(cx.listener(|this, _: &CloseWindow, window, cx| {
                if crate::desktop::closes_to_menu_bar(cx) {
                    log::info!("close window: hiding the main window");
                    crate::desktop::hide_main(cx);
                } else {
                    this.leaving_screen(cx);
                    window.remove_window();
                }
            }))
            .on_action(
                cx.listener(|this, _: &OpenPalette, window, cx| this.toggle_palette(window, cx)),
            )
            .on_action(cx.listener(|this, a: &ChatMenu, window, cx| {
                let (id, command) = (a.chat_id.clone(), a.command.clone());
                this.sidebar
                    .update(cx, |s, cx| s.run(&id, command, window, cx));
            }))
            .on_action(
                cx.listener(|this, a: &crate::actions::HermesSwitchConnection, _, cx| {
                    let id = a.connection_id.clone();
                    let name = this
                        .stores
                        .hermes_admin
                        .read(cx)
                        .connections
                        .as_ref()
                        .and_then(|l| l.connections.iter().find(|c| c.id == id))
                        .map(|c| c.name.clone());
                    crate::stores::hermes_admin::activate(&this.stores, &id, cx);
                    if let Some(name) = name {
                        let text = cx.l10n().desktop_hermes_using_connection(&name);
                        this.stores.toasts.update(cx, |t, cx| {
                            t.show(conduit_protocol::NoticeLevel::Success, text, cx)
                        });
                    }
                }),
            )
            .on_action(
                cx.listener(|_, _: &crate::actions::OpenHermesSettings, _, cx| {
                    crate::open_settings(Some(crate::views::settings::Tab::Hermes), cx);
                }),
            )
            .on_action(cx.listener(|this, a: &HermesMenu, window, cx| {
                let (id, command) = (a.session_id.clone(), a.command);
                this.run_hermes(&id, command, window, cx);
            }))
            .on_action(cx.listener(
                |this, a: &crate::views::hermes_rooms::RoomMenu, window, cx| {
                    crate::views::hermes_rooms::run(
                        &this.stores,
                        &a.room_id,
                        a.command,
                        window,
                        cx,
                    );
                },
            ))
            .on_action(
                cx.listener(|this, a: &crate::views::hermes_rooms::OpenBotChat, _, cx| {
                    crate::views::hermes_rooms::open_bot(&this.stores, &a.name, cx);
                }),
            )
            .on_action(cx.listener(|this, a: &MoveSelected, window, cx| {
                let folder = a.folder_id.clone();
                this.sidebar
                    .update(cx, |s, cx| s.bulk(BulkChatAction::Move, folder, window, cx));
            }))
            .on_action(cx.listener(|this, a: &ActOnSelected, window, cx| {
                let action = a.action;
                this.sidebar
                    .update(cx, |s, cx| s.bulk(action, None, window, cx));
            }))
            // A channel's menu (the sidebar's row, the pane's More), a
            // message's, and New Channel….
            .on_action(cx.listener(
                |this, a: &crate::views::channels::ChannelMenu, window, cx| {
                    let shown = this
                        .area_pane
                        .read(cx)
                        .channel
                        .clone()
                        .and_then(|p| p.read(cx).summary(cx));
                    crate::views::channels::run_channel_command(&this.stores, a, shown, window, cx)
                },
            ))
            .on_action(cx.listener(
                |this, a: &crate::views::channels::MessageMenu, window, cx| {
                    if let Some(pane) = this.area_pane.read(cx).channel.clone() {
                        pane.update(cx, |p, cx| p.run_message(a, window, cx));
                    }
                },
            ))
            // File › New Channel… and the sidebar's +: greyed where the
            // account may not make one (no handler answers it then).
            .when(makes_channels, |d| {
                d.on_action(cx.listener(
                    |this, _: &crate::views::channels::NewChannel, window, cx| {
                        crate::views::channels::form::open_new(this.stores.clone(), window, cx)
                    },
                ))
            })
            .on_action(cx.listener(|this, a: &FolderMenu, window, cx| {
                let (id, command) = (a.folder_id.clone(), a.command.clone());
                this.sidebar
                    .update(cx, |s, cx| s.run_folder(&id, command, window, cx));
            }))
            .when(can_go_back, |d| {
                d.on_action(cx.listener(|this, _: &GoBack, _, cx| this.go(true, cx)))
            })
            .when(can_go_forward, |d| {
                d.on_action(cx.listener(|this, _: &GoForward, _, cx| this.go(false, cx)))
            })
            .when(shows_main, |d| {
                d
                    // Go › Move Focus to Next and Previous Area: the window's
                    // next or previous stop, as Tab and Shift-Tab, out of a
                    // view that keeps Tab (the terminal's console) too.
                    .on_action(cx.listener(
                        |_, _: &crate::actions::MoveFocusToNextArea, window, cx| {
                            window.focus_next(cx);
                        },
                    ))
                    .on_action(cx.listener(
                        |_, _: &crate::actions::MoveFocusToPreviousArea, window, cx| {
                            window.focus_prev(cx);
                        },
                    ))
                    .on_action(cx.listener(|this, a: &GoToSection, window, cx| {
                        this.go_to_section(a.index, window, cx)
                    }))
                    .on_action(cx.listener(|this, _: &FindChats, window, cx| this.find(window, cx)))
                    // A Hermes session is no stored chat (no Chat menu
                    // gate): the pane checks it has a context window.
                    .on_action(cx.listener(
                        |this, _: &crate::actions::ShowContextUsage, window, cx| {
                            this.chat_pane.update(cx, |p, cx| {
                                p.show_context_usage(window, cx);
                            });
                        },
                    ))
                    .on_action(cx.listener(|this, _: &NextChat, _, cx| this.step_chat(true, cx)))
                    .on_action(
                        cx.listener(|this, _: &PreviousChat, _, cx| this.step_chat(false, cx)),
                    )
            })
            // File › New Room… (and the Rooms heading's "+" and menus).
            .when(makes_rooms, |d| {
                d.on_action(cx.listener(
                    |this, _: &crate::views::hermes_rooms::NewRoom, window, cx| {
                        crate::views::hermes_room_sheets::open_create(
                            this.stores.clone(),
                            window,
                            cx,
                        );
                    },
                ))
            })
            // File › New Folder (and the sidebar list's own menu).
            .when(makes_folders, |d| {
                d.on_action(
                    cx.listener(|this, _: &NewFolder, window, cx| this.new_folder(window, cx)),
                )
            })
            .when(findable, |d| {
                d.on_action(cx.listener(|this, _: &FindInChat, window, cx| {
                    this.chat_pane.update(cx, |p, cx| p.open_find(window, cx));
                }))
                .on_action(cx.listener(|this, _: &FindNext, window, cx| {
                    this.chat_pane
                        .update(cx, |p, cx| p.find_step(true, window, cx));
                }))
                .on_action(cx.listener(|this, _: &FindPrevious, window, cx| {
                    this.chat_pane
                        .update(cx, |p, cx| p.find_step(false, window, cx));
                }))
            })
            // The Chat menu: available only with a chat open that takes
            // changes, and what that chat offers.
            .when(acts(ChatCommand::Rename), |d| {
                d.on_action(cx.listener(|this, _: &RenameChat, window, cx| {
                    this.chat_command(|_| ChatCommand::Rename, window, cx)
                }))
            })
            .when(acts(ChatCommand::Pin), |d| {
                d.on_action(cx.listener(|this, _: &TogglePinChat, window, cx| {
                    this.chat_command(
                        |c| {
                            if c.pinned {
                                ChatCommand::Unpin
                            } else {
                                ChatCommand::Pin
                            }
                        },
                        window,
                        cx,
                    )
                }))
            })
            .when(acts(archive), |d| {
                d.on_action(cx.listener(|this, _: &ArchiveChat, window, cx| {
                    this.chat_command(
                        |c| {
                            if c.archived {
                                ChatCommand::Unarchive
                            } else {
                                ChatCommand::Archive
                            }
                        },
                        window,
                        cx,
                    )
                }))
            })
            .when(acts(ChatCommand::Delete), |d| {
                d.on_action(cx.listener(|this, _: &DeleteChat, window, cx| {
                    this.chat_command(|_| ChatCommand::Delete, window, cx)
                }))
            })
            .when(offered.share && acts(ChatCommand::Share), |d| {
                d.on_action(cx.listener(|this, _: &ShareChat, window, cx| {
                    this.chat_command(|_| ChatCommand::Share, window, cx)
                }))
            })
            .when(offered.mark_unread && acts(ChatCommand::MarkUnread), |d| {
                d.on_action(cx.listener(|this, _: &MarkChatUnread, window, cx| {
                    this.chat_command(
                        |c| {
                            if c.unread {
                                ChatCommand::MarkRead
                            } else {
                                ChatCommand::MarkUnread
                            }
                        },
                        window,
                        cx,
                    )
                }))
            })
            .when(
                offered.generate_title && acts(ChatCommand::GenerateTitle),
                |d| {
                    d.on_action(cx.listener(|this, _: &GenerateChatTitle, window, cx| {
                        this.chat_command(|_| ChatCommand::GenerateTitle, window, cx)
                    }))
                },
            )
            .when(acts(ChatCommand::Duplicate), |d| {
                d.on_action(cx.listener(|this, _: &DuplicateChat, window, cx| {
                    this.chat_command(|_| ChatCommand::Duplicate, window, cx)
                }))
            })
            .when(
                offered.export
                    && acts(ChatCommand::Export(
                        conduit_protocol::ChatExportFormat::Json,
                    )),
                |d| {
                    d.on_action(cx.listener(|this, a: &ExportChatAs, window, cx| {
                        let format = a.format;
                        this.chat_command(move |_| ChatCommand::Export(format), window, cx)
                    }))
                },
            )
            .when(chat_menu && self.chat_pane.read(cx).branches(cx), |d| {
                d.on_action(cx.listener(|this, _: &ShowBranches, window, cx| {
                    this.chat_pane.update(cx, |p, cx| {
                        p.show_branches(window, cx);
                    });
                }))
            })
            .when(chat_menu, |d| {
                d.on_action(cx.listener(|this, a: &MoveChatTo, window, cx| {
                    let folder = a.folder_id.clone();
                    this.chat_command(
                        move |_| match folder {
                            Some(f) => ChatCommand::MoveTo(f),
                            None => ChatCommand::RemoveFromFolder,
                        },
                        window,
                        cx,
                    )
                }))
            })
            // Regenerate: not in a chat a coding agent answers, which takes
            // only new messages at its end.
            .when(chat_menu && !self.chat_pane.read(cx).agent_chat(cx), |d| {
                d.on_action(cx.listener(|this, _: &RegenerateLastAnswer, _, cx| {
                    this.chat_pane.update(cx, |p, cx| p.regenerate_last(cx));
                }))
            })
            // Save Chat: a temporary chat with messages is open.
            .when(self.chat_pane.read(cx).can_save_temporary(cx), |d| {
                d.on_action(cx.listener(|this, _: &SaveTemporaryChat, window, cx| {
                    this.chat_pane
                        .update(cx, |p, cx| p.save_temporary(window, cx));
                }))
            })
            .when(asks_conduit, |d| {
                d.on_action(cx.listener(|this, _: &AskConduit, window, cx| {
                    this.chat_pane.update(cx, |p, cx| p.ask_conduit(window, cx));
                }))
            })
            .when(reads_aloud, |d| {
                d.on_action(cx.listener(|this, _: &ReadAloud, _, cx| {
                    this.chat_pane.update(cx, |p, cx| p.read_aloud_last(cx));
                }))
            })
            // Start Voice Call, or End Voice Call while one is on.
            .when(calls, |d| {
                d.on_action(cx.listener(|this, _: &VoiceCall, _, cx| {
                    this.chat_pane.update(cx, |p, cx| p.toggle_call(cx));
                }))
            })
            // ⌘I is Get Info: the chat's settings (the sidebar's list takes
            // it first for a folder its keyboard is on).
            .when(chat_settings, |d| {
                d.on_action(cx.listener(|this, _: &ChatSettings, window, cx| {
                    this.chat_pane
                        .update(cx, |p, cx| p.open_chat_settings(window, cx));
                }))
            })
            .when(tool_settings, |d| {
                d.on_action(cx.listener(|this, _: &ToolSettings, window, cx| {
                    this.chat_pane
                        .update(cx, |p, cx| p.open_tool_settings(window, cx));
                }))
            })
            .map(|d| crate::menus::app_commands(d, &settings, &speech, cx))
            .relative()
            .size_full()
            // Inline web views drawn this frame (embeds in the transcript)
            // are counted between these two; the rest hide.
            .child(crate::views::chat::inline_web::frame_start())
            .child(content)
            .children(approvals)
            .children(toasts)
            .children(banner)
            .child(crate::views::chat::inline_web::frame_end())
    }
}

/// Whether ⌥⌘↩ / ⌥⌘⌫ may answer the open chat's prompt card: only while
/// the chat pane is on screen.
fn answers_chat_prompt(shows_main: bool, shows_chat: bool) -> bool {
    shows_main && shows_chat
}

#[cfg(test)]
mod material_tests {
    use super::{MaterialHold, MaterialStep};

    #[test]
    fn the_material_leaves_only_after_frames_without_the_sidebar() {
        let mut hold = MaterialHold::default();
        assert_eq!(hold.step(Some(260.), false), MaterialStep::Sync(Some(260.)));
        assert_eq!(hold.step(Some(260.), true), MaterialStep::Sync(Some(260.)));
        // The sidebar went (Reduce Motion's instant hide): kept up while the
        // frames without it reach the screen, then taken off.
        for _ in 0..MaterialHold::FRAMES {
            assert_eq!(hold.step(None, true), MaterialStep::Hold);
        }
        assert_eq!(hold.step(None, true), MaterialStep::Sync(None));
        assert_eq!(hold.step(None, false), MaterialStep::Sync(None));
        // Back before it left: it stays, and the next hide waits again.
        assert_eq!(hold.step(None, true), MaterialStep::Hold);
        assert_eq!(hold.step(Some(260.), true), MaterialStep::Sync(Some(260.)));
        assert_eq!(hold.step(None, true), MaterialStep::Hold);
    }
}

#[cfg(test)]
mod approvals_tests {
    #[test]
    fn a_request_floats_over_every_pane_but_the_chats() {
        assert!(!super::floats_approvals(true, true));
        assert!(
            super::floats_approvals(true, false),
            "a note hides a chat's request"
        );
        assert!(super::floats_approvals(false, false));
    }

    #[test]
    fn a_hidden_chats_prompt_never_takes_the_shortcut() {
        assert!(super::answers_chat_prompt(true, true));
        assert!(
            !super::answers_chat_prompt(true, false),
            "a note's pane answered the chat"
        );
        assert!(!super::answers_chat_prompt(false, false));
    }
}

/// The menu bar greys an action item only when no handler on the focus path
/// answers its action (AppKit's validation asks GPUI, which ignores the
/// item's `disabled`), so these check the window itself.
#[cfg(test)]
mod chat_menu_tests {
    use chrono::Local;
    use gpui_kit::{Action, Entity, TestAppContext, VisualTestContext};

    use super::*;
    use crate::stores::accounts::tests::{account, list};
    use crate::stores::rpc::fake::FakeDaemon;
    use crate::views::sidebar_keys::Pick;

    /// Two chats whose menus offer everything, one whose menu offers
    /// nothing, an archived one, another user's (read-only), and a folder.
    /// Only A has branches.
    fn chats() -> FakeDaemon {
        use conduit_protocol::methods;
        let now = Local::now().timestamp_millis();
        let all = serde_json::json!({
            "share": true, "duplicate": true, "move": true,
            "markUnread": true, "generateTitle": true, "export": true,
        });
        let chats = serde_json::json!([
            {"id": "chat-a", "title": "Tide tables", "updatedAtMs": now, "menu": all},
            {"id": "chat-b", "title": "Bread starter", "updatedAtMs": now - 1, "menu": all},
            {"id": "chat-c", "title": "Kiln notes", "updatedAtMs": now - 2},
            {"id": "chat-d", "title": "Old maps", "updatedAtMs": now - 3, "archived": true, "menu": all},
            {"id": "chat-e", "title": "Shared survey", "updatedAtMs": now - 4, "readOnly": true},
        ]);
        let list: conduit_protocol::ChatList = serde_json::from_value(serde_json::json!({
            "chats": chats,
            "folders": [{"id": "recipes", "name": "Recipes", "canWrite": true}],
        }))
        .unwrap();
        let daemon = FakeDaemon::new();
        daemon.returns::<methods::ChatsList>(list);
        daemon.on::<methods::ChatsGet>(move |params| {
            let summary = chats
                .as_array()
                .and_then(|c| c.iter().find(|c| c["id"] == params["id"]))
                .cloned();
            Ok(
                serde_json::json!({"chat": summary.map(|summary| serde_json::json!({
                    "abilities": {"branch": summary["id"] == "chat-a"},
                    "summary": summary,
                }))}),
            )
        });
        daemon
    }

    fn bench<'a>(
        daemon: &FakeDaemon,
        cx: &'a mut TestAppContext,
    ) -> (Stores, Entity<MainWindow>, &'a mut VisualTestContext) {
        let (stores, _, view, vcx) = bench_with_settings(daemon, cx);
        (stores, view, vcx)
    }

    fn bench_with_settings<'a>(
        daemon: &FakeDaemon,
        cx: &'a mut TestAppContext,
    ) -> (
        Stores,
        Entity<SettingsStore>,
        Entity<MainWindow>,
        &'a mut VisualTestContext,
    ) {
        let scratch =
            std::env::temp_dir().join(format!("conduit-main-window-{}", std::process::id()));
        let stores = cx.update(|cx| {
            crate::views::test_globals(cx);
            Stores::for_test(daemon.rpc(), &scratch, cx)
        });
        stores
            .connection
            .update(cx, |c, _| c.set_starting_for_test());
        stores.accounts.update(cx, |a, cx| {
            a.adopt(list(vec![account("a", "Avery", true, true)]), cx)
        });
        stores.session.update(cx, |s, cx| {
            s.preview_route(Some(crate::stores::session::Route::Main), cx)
        });
        let settings =
            cx.new(|_| SettingsStore::load(scratch.join("prefs.json"), false, vec!["en".into()]));
        let layout = cx.new(|_| LayoutStore::load(scratch.join("window-state.json")));
        let (s, prefs) = (stores.clone(), settings.clone());
        let (view, vcx) =
            cx.add_window_view(move |window, cx| MainWindow::new(s, prefs, layout, window, cx));
        stores.chat_list.update(vcx, |c, cx| c.refresh(cx));
        vcx.run_until_parked();
        (stores, settings, view, vcx)
    }

    /// The chat's model takes calls, has settings to show and a tool with
    /// personal settings.
    fn offer_everything(daemon: &FakeDaemon) {
        use conduit_protocol::methods;
        daemon.returns::<methods::ModelsList>(
            serde_json::from_value(serde_json::json!({
                "models": [{"id": "m", "name": "M"}], "selectedId": "m"
            }))
            .unwrap(),
        );
        daemon.returns::<methods::ComposerOptions>(
            serde_json::from_value(serde_json::json!({"voiceCall": true})).unwrap(),
        );
        daemon.returns::<methods::ChatSettingsGet>(
            serde_json::from_value(serde_json::json!({
                "entry": "editor",
                "systemPrompt": {"key": "system", "kind": "text"}
            }))
            .unwrap(),
        );
        daemon.returns::<methods::ValvesTargets>(
            serde_json::from_value(serde_json::json!({
                "advanced": true,
                "targets": [{"kind": "tool", "id": "tool-tides", "label": "Tides"}]
            }))
            .unwrap(),
        );
    }

    /// The composer lists the models, online.
    fn list_models_online(pane: &Entity<ChatPane>, vcx: &mut VisualTestContext) {
        pane.update(vcx, |p, cx| {
            p.composer_store.update(cx, |c, cx| c.refresh_models(cx));
            // The bench has no connection to say it is online.
            p.composer.update(cx, |c, cx| {
                c.offline = false;
                cx.notify()
            });
        });
        vcx.run_until_parked();
    }

    fn available(vcx: &mut VisualTestContext, action: &dyn Action) -> bool {
        vcx.update(|window, cx| window.is_action_available(action, cx))
    }

    fn json_export() -> ExportChatAs {
        ExportChatAs {
            format: conduit_protocol::ChatExportFormat::Json,
        }
    }

    /// With chats chosen, Rename… and the other commands for one chat
    /// have no handler (a selection never falls through to the open chat),
    /// while Archive, Move to, Remove from Folder and Delete… act on all of
    /// the chosen chats.
    #[gpui_kit::test]
    fn chosen_chats_leave_the_commands_for_one_chat_unavailable(cx: &mut TestAppContext) {
        let daemon = chats();
        let (stores, main, vcx) = bench(&daemon, cx);
        stores.navigation.update(vcx, |n, cx| n.open("chat-a", cx));
        vcx.run_until_parked();
        let one_chat: [(&str, Box<dyn Action>); 7] = [
            ("Rename…", Box::new(RenameChat)),
            ("Pin", Box::new(TogglePinChat)),
            ("Mark as Unread", Box::new(MarkChatUnread)),
            ("Generate Title", Box::new(GenerateChatTitle)),
            ("Duplicate Chat", Box::new(DuplicateChat)),
            ("Share Chat…", Box::new(ShareChat)),
            ("Export Chat", Box::new(json_export())),
        ];
        let on_all: [(&str, Box<dyn Action>); 4] = [
            ("Archive", Box::new(ArchiveChat)),
            ("Delete…", Box::new(DeleteChat)),
            (
                "Move to",
                Box::new(MoveChatTo {
                    folder_id: Some("recipes".into()),
                }),
            ),
            (
                "Remove from Folder",
                Box::new(MoveChatTo { folder_id: None }),
            ),
        ];
        for (name, action) in one_chat.iter().chain(&on_all) {
            assert!(
                available(vcx, action.as_ref()),
                "{name} is off, nothing chosen"
            );
        }

        // ⌘-click on B, A open: both chosen.
        let sidebar = main.read_with(vcx, |m, _| m.sidebar.clone());
        sidebar.update(vcx, |s, cx| s.pick_chat("chat-b", Pick::Toggle, cx));
        vcx.run_until_parked();
        assert!(sidebar.read_with(vcx, |s, _| s.has_selection()));
        for (name, action) in &one_chat {
            assert!(
                !available(vcx, action.as_ref()),
                "{name} is on with chats chosen"
            );
        }
        for (name, action) in &on_all {
            assert!(
                available(vcx, action.as_ref()),
                "{name} is off with chats chosen"
            );
        }

        // The selection ends: the open chat's commands come back.
        sidebar.update(vcx, |s, cx| s.end_selection(cx));
        vcx.run_until_parked();
        for (name, action) in &one_chat {
            assert!(available(vcx, action.as_ref()), "{name} is still off");
        }
    }

    /// An archived chat open with chats chosen (Select Chats… on another):
    /// its Unarchive is for that chat alone.
    #[gpui_kit::test]
    fn chosen_chats_leave_an_archived_chats_unarchive_unavailable(cx: &mut TestAppContext) {
        let daemon = chats();
        let (stores, main, vcx) = bench(&daemon, cx);
        stores.navigation.update(vcx, |n, cx| n.open("chat-d", cx));
        vcx.run_until_parked();
        assert!(available(vcx, &ArchiveChat), "Unarchive is off");
        let sidebar = main.read_with(vcx, |m, _| m.sidebar.clone());
        sidebar.update_in(vcx, |s, window, cx| {
            s.run("chat-b", ChatCommand::Select, window, cx)
        });
        vcx.run_until_parked();
        assert!(sidebar.read_with(vcx, |s, _| s.has_selection()));
        assert!(!available(vcx, &ArchiveChat), "Unarchive is on");
    }

    /// Share, Mark as Unread, Generate Title and Export Chat only where
    /// the open chat's menu offers them, Show Branches… only where its
    /// detail allows branches.
    #[gpui_kit::test]
    fn commands_the_open_chat_does_not_offer_are_unavailable(cx: &mut TestAppContext) {
        let daemon = chats();
        let (stores, _, vcx) = bench(&daemon, cx);
        let offered: [(&str, Box<dyn Action>); 4] = [
            ("Share Chat…", Box::new(ShareChat)),
            ("Mark as Unread", Box::new(MarkChatUnread)),
            ("Generate Title", Box::new(GenerateChatTitle)),
            ("Export Chat", Box::new(json_export())),
        ];
        stores.navigation.update(vcx, |n, cx| n.open("chat-c", cx));
        vcx.run_until_parked();
        assert!(available(vcx, &RenameChat), "no chat menu at all");
        for (name, action) in &offered {
            assert!(
                !available(vcx, action.as_ref()),
                "{name} is on, not offered"
            );
        }
        assert!(!available(vcx, &ShowBranches), "Show Branches… is on");
        stores.navigation.update(vcx, |n, cx| n.open("chat-a", cx));
        vcx.run_until_parked();
        for (name, action) in &offered {
            assert!(available(vcx, action.as_ref()), "{name} is off, offered");
        }
        assert!(available(vcx, &ShowBranches), "Show Branches… is off");
    }

    /// Go › Back and Forward only with a step to go to.
    #[gpui_kit::test]
    fn back_and_forward_are_available_only_with_a_step_to_go_to(cx: &mut TestAppContext) {
        let daemon = chats();
        let (stores, _, vcx) = bench(&daemon, cx);
        assert!(!available(vcx, &GoBack), "Back with no step before");
        assert!(!available(vcx, &GoForward), "Forward with no step after");
        stores.navigation.update(vcx, |n, cx| n.open("chat-a", cx));
        vcx.run_until_parked();
        assert!(available(vcx, &GoBack), "Back is off after a step");
        assert!(!available(vcx, &GoForward), "Forward at the newest step");
        vcx.dispatch_action(GoBack);
        vcx.run_until_parked();
        assert_eq!(
            stores
                .navigation
                .read_with(vcx, |n, _| n.selected_chat().map(String::from)),
            None,
            "Back did not go back"
        );
        assert!(!available(vcx, &GoBack), "Back at the first step");
        assert!(available(vcx, &GoForward), "Forward is off after Back");
    }

    /// View › Actual Size, Zoom In and Zoom Out, as AppKit asks (the app's
    /// own handlers too): each only while its step would change the text
    /// size. ⌘− still steps it in the main window.
    #[gpui_kit::test]
    fn zoom_items_are_available_only_while_the_text_size_can_change(cx: &mut TestAppContext) {
        use crate::actions::{ActualSize, ZoomIn, ZoomOut};
        use crate::menus::appkit_enables;
        use crate::prefs::{TEXT_SIZE_MAX, TEXT_SIZE_MIN};
        let daemon = chats();
        let (_, settings, _, vcx) = bench_with_settings(&daemon, cx);
        vcx.cx.update(crate::register_actions);
        let size = |size: Option<f32>, vcx: &mut VisualTestContext| {
            settings.update(vcx, |s, cx| s.set_appearance(|a| a.text_size = size, cx));
            vcx.run_until_parked();
        };
        size(None, vcx);
        assert!(
            !appkit_enables(vcx, &ActualSize),
            "Actual Size is on at the actual size"
        );
        assert!(appkit_enables(vcx, &ZoomIn), "Zoom In is off");
        assert!(appkit_enables(vcx, &ZoomOut), "Zoom Out is off");
        size(Some(TEXT_SIZE_MAX), vcx);
        assert!(
            !appkit_enables(vcx, &ZoomIn),
            "Zoom In is on at the largest size"
        );
        assert!(appkit_enables(vcx, &ActualSize), "Actual Size is off");
        assert!(appkit_enables(vcx, &ZoomOut), "Zoom Out is off");
        size(Some(TEXT_SIZE_MIN), vcx);
        assert!(
            !appkit_enables(vcx, &ZoomOut),
            "Zoom Out is on at the smallest size"
        );
        assert!(appkit_enables(vcx, &ZoomIn), "Zoom In is off");

        size(Some(TEXT_SIZE_MAX), vcx);
        vcx.dispatch_action(ZoomOut);
        vcx.run_until_parked();
        assert_eq!(
            settings.read_with(vcx, |s, _| s.prefs.appearance.text_size),
            Some(TEXT_SIZE_MAX - 1.),
            "⌘− did not step the text size"
        );
    }

    /// Chat › Stop Speaking only while something is read (Settings' preview
    /// too), and ⌘. stops it from the main window.
    #[gpui_kit::test]
    fn stop_speaking_is_available_only_while_something_is_read(cx: &mut TestAppContext) {
        use conduit_protocol::{SpeechProgress, SpeechState, SpeechStatus, methods};

        use crate::actions::StopSpeaking;
        use crate::menus::appkit_enables;
        let daemon = chats();
        let (stores, _, vcx) = bench(&daemon, cx);
        vcx.cx.update(crate::register_actions);
        assert!(
            !appkit_enables(vcx, &StopSpeaking),
            "Stop Speaking is on with nothing read"
        );
        daemon.returns::<methods::SpeechGet>(SpeechState {
            progress: SpeechProgress {
                status: SpeechStatus::Speaking,
                reading: 1,
                message_id: Some("preview".into()),
                ..Default::default()
            },
            sentences: vec![],
        });
        daemon.returns::<methods::SpeechStop>(SpeechState {
            progress: SpeechProgress {
                reading: 1,
                ..Default::default()
            },
            sentences: vec![],
        });
        stores.speech.update(vcx, |s, cx| s.refresh(cx));
        vcx.run_until_parked();
        assert!(
            appkit_enables(vcx, &StopSpeaking),
            "Stop Speaking is off while reading"
        );
        vcx.dispatch_action(StopSpeaking);
        vcx.run_until_parked();
        assert_eq!(
            daemon.calls::<methods::SpeechStop>().len(),
            1,
            "⌘. ended nothing"
        );
        assert!(
            !appkit_enables(vcx, &StopSpeaking),
            "Stop Speaking is on after the reading ended"
        );
    }

    /// Chat › Ask Conduit, Read Aloud, Start Voice Call, Chat Settings… and
    /// Tool Settings… only where the menu offers them, as AppKit asks (the
    /// app answered them all, so every one was on with no chat open).
    #[gpui_kit::test]
    fn the_open_chats_commands_are_available_only_where_they_act(cx: &mut TestAppContext) {
        use conduit_protocol::methods;

        use crate::menus::appkit_enables;
        let daemon = chats();
        let (stores, main, vcx) = bench(&daemon, cx);
        vcx.cx.update(crate::register_actions);
        let in_chat: [(&str, Box<dyn Action>); 2] = [
            ("Ask Conduit", Box::new(AskConduit)),
            ("Read Aloud", Box::new(ReadAloud)),
        ];
        let offered: [(&str, Box<dyn Action>); 3] = [
            ("Start Voice Call", Box::new(VoiceCall)),
            ("Chat Settings…", Box::new(ChatSettings)),
            ("Tool Settings…", Box::new(ToolSettings)),
        ];
        for (name, action) in in_chat.iter().chain(&offered) {
            assert!(
                !appkit_enables(vcx, action.as_ref()),
                "{name} is on with no chat open"
            );
        }

        stores.navigation.update(vcx, |n, cx| n.open("chat-a", cx));
        vcx.run_until_parked();
        for (name, action) in &in_chat {
            assert!(
                appkit_enables(vcx, action.as_ref()),
                "{name} is off in an open chat"
            );
        }
        for (name, action) in &offered {
            assert!(
                !appkit_enables(vcx, action.as_ref()),
                "{name} is on, not offered"
            );
        }
        // Another user's chat is read, but has no composer to ask in.
        stores.navigation.update(vcx, |n, cx| n.open("chat-e", cx));
        vcx.run_until_parked();
        assert!(
            appkit_enables(vcx, &ReadAloud),
            "Read Aloud is off, read-only"
        );
        assert!(
            !appkit_enables(vcx, &AskConduit),
            "Ask Conduit is on with no composer"
        );
        stores.navigation.update(vcx, |n, cx| n.open("chat-a", cx));
        vcx.run_until_parked();

        offer_everything(&daemon);
        let pane = main.read_with(vcx, |m, _| m.chat_pane.clone());
        list_models_online(&pane, vcx);
        for (name, action) in &offered {
            assert!(
                appkit_enables(vcx, action.as_ref()),
                "{name} is off, offered"
            );
        }
        // ⌥⌘V still starts the call from the main window.
        vcx.dispatch_action(VoiceCall);
        vcx.run_until_parked();
        assert_eq!(
            daemon.calls::<methods::CallsStart>().len(),
            1,
            "Start Voice Call started nothing"
        );
    }

    /// ⌘I (Chat › Chat Settings…) with the sidebar's keyboard on a row:
    /// a folder whose menu offers its settings opens them; on a chat row
    /// it is the open chat's, so it is off when that chat offers none.
    #[gpui_kit::test]
    fn chat_settings_in_the_sidebar_is_available_only_where_it_acts(cx: &mut TestAppContext) {
        use crate::menus::appkit_enables;
        use crate::views::folder_settings::FolderSettingsSheet;
        use crate::views::sidebar_keys::{KeyRow, ListKey};
        let daemon = chats();
        let (stores, main, vcx) = bench(&daemon, cx);
        vcx.cx.update(crate::register_actions);
        stores.navigation.update(vcx, |n, cx| n.open("chat-c", cx));
        vcx.run_until_parked();
        let sidebar = main.read_with(vcx, |m, _| m.sidebar.clone());
        sidebar.update_in(vcx, |s, window, cx| s.focus_list(window, cx));
        vcx.run_until_parked();
        assert_eq!(
            sidebar.read_with(vcx, |s, _| s.cursor().cloned()),
            Some(KeyRow::Chat("chat-c".into()))
        );
        assert!(
            !appkit_enables(vcx, &ChatSettings),
            "Chat Settings… is on, on a chat that offers none"
        );

        let folder = KeyRow::Folder("recipes".into());
        let rows = sidebar.read_with(vcx, |s, _| s.rows().len());
        for _ in 0..rows {
            if sidebar.read_with(vcx, |s, _| s.cursor() == Some(&folder)) {
                break;
            }
            sidebar.update(vcx, |s, cx| s.key(ListKey::Up, cx));
            vcx.run_until_parked();
        }
        assert_eq!(
            sidebar.read_with(vcx, |s, _| s.cursor().cloned()),
            Some(folder)
        );
        assert!(
            appkit_enables(vcx, &ChatSettings),
            "Chat Settings… is off on a folder with settings"
        );
        vcx.dispatch_action(ChatSettings);
        vcx.run_until_parked();
        assert!(
            vcx.update(|_, cx| crate::views::sheet::current::<FolderSettingsSheet>(cx))
                .is_some(),
            "⌘I did not open the folder's settings"
        );
    }

    /// Start Voice Call is the composer's call button: never in a chat with
    /// no composer (another user's), whatever its model takes. A chat with
    /// one takes it.
    #[gpui_kit::test]
    fn start_voice_call_is_off_in_a_chat_with_no_composer(cx: &mut TestAppContext) {
        use crate::menus::appkit_enables;
        let daemon = chats();
        offer_everything(&daemon);
        let (stores, main, vcx) = bench(&daemon, cx);
        vcx.cx.update(crate::register_actions);
        let pane = main.read_with(vcx, |m, _| m.chat_pane.clone());
        stores.navigation.update(vcx, |n, cx| n.open("chat-e", cx));
        vcx.run_until_parked();
        list_models_online(&pane, vcx);
        assert!(
            pane.read_with(vcx, |p, cx| p.composer_store.read(cx).call_ready()),
            "the model takes no calls"
        );
        assert!(
            !appkit_enables(vcx, &VoiceCall),
            "Start Voice Call is on in a chat with no composer"
        );
        stores.navigation.update(vcx, |n, cx| n.open("chat-a", cx));
        vcx.run_until_parked();
        assert!(
            appkit_enables(vcx, &VoiceCall),
            "Start Voice Call is off in a chat with a composer"
        );
    }

    /// Chat Settings… is off while a new chat's first message is on its way
    /// (its settings went with it, and the chat it makes is not open yet):
    /// on before the send, and again once the chat opens.
    #[gpui_kit::test]
    fn chat_settings_waits_for_a_new_chats_first_message(cx: &mut TestAppContext) {
        use conduit_protocol::methods;

        use crate::menus::appkit_enables;
        let daemon = chats();
        offer_everything(&daemon);
        daemon.returns::<methods::TurnsSend>(
            serde_json::from_value(serde_json::json!({
                "chatId": "chat-a", "userMessageId": "m1", "assistantMessageId": "a1"
            }))
            .unwrap(),
        );
        let (stores, main, vcx) = bench(&daemon, cx);
        vcx.cx.update(crate::register_actions);
        let pane = main.read_with(vcx, |m, _| m.chat_pane.clone());
        list_models_online(&pane, vcx);
        assert!(
            appkit_enables(vcx, &ChatSettings),
            "Chat Settings… is off before the first message"
        );
        let held = daemon.hold::<methods::TurnsSend>();
        pane.update_in(vcx, |p, window, cx| {
            p.send_text("Plan the trip".into(), vec![], window, cx)
        });
        vcx.run_until_parked();
        assert!(
            !appkit_enables(vcx, &ChatSettings),
            "Chat Settings… is on while the first message is on its way"
        );
        drop(held);
        vcx.run_until_parked();
        assert_eq!(
            stores
                .navigation
                .read_with(vcx, |n, _| n.selected_chat().map(String::from)),
            Some("chat-a".into()),
            "the chat did not open"
        );
        assert!(
            appkit_enables(vcx, &ChatSettings),
            "Chat Settings… is off once the chat opened"
        );
    }

    /// ⌘W (Window › Close Window) takes the main window off the screen:
    /// the chat it shows is read then, and an answer that finishes after
    /// it is not read when the app quits.
    #[gpui_kit::test]
    fn close_window_reads_the_chat_it_shows_and_nothing_after(cx: &mut TestAppContext) {
        use conduit_protocol::methods;
        let daemon = chats();
        daemon.on::<methods::ChatsMarkUnread>(|_| Ok(serde_json::json!({"chats": []})));
        let (stores, main, vcx) = bench(&daemon, cx);
        stores.navigation.update(vcx, |n, cx| n.open("chat-a", cx));
        vcx.run_until_parked();
        let pane = main.read_with(vcx, |m, _| m.chat_pane.clone());
        // Its answer finished while it was open.
        daemon.on::<methods::ChatsList>(|_| {
            Ok(serde_json::json!({"chats": [
                {"id": "chat-a", "title": "Tide tables", "updatedAtMs": 1, "unread": true},
            ]}))
        });
        stores.chat_list.update(vcx, |c, cx| c.refresh(cx));
        vcx.run_until_parked();

        vcx.dispatch_action(CloseWindow);
        vcx.run_until_parked();
        assert_eq!(
            daemon.calls::<methods::ChatsMarkUnread>(),
            vec![serde_json::json!({"chatId": "chat-a", "unread": false})],
            "closing the window did not read its chat"
        );
        assert!(
            pane.update(vcx, |p, cx| p.leave_on_quit(cx)).is_none(),
            "quitting read the chat of a closed window"
        );
    }
}
