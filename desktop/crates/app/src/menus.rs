//! The native menu bar (Conduit / File / Edit / View / Chat / Window /
//! Help) and the key bindings behind it.
//!
//! Menus follow the app's state ([`MenuState`]): View offers "Hide Sidebar"
//! or "Show Sidebar" and "Enter" or "Exit Full Screen", and greys out the
//! zoom item that would go past the text size's bounds; the Chat menu acts
//! on the open chat (pinned or not, its folder) and is disabled without one.
//! [`refresh_menus`] rebuilds the bar only when that state changes.
//!
//! The Chat menu lists the chat's commands in the order the sidebar's
//! context menu and the toolbar's More menu do ([`CHAT_COMMAND_ORDER`]), as
//! Mail keeps its Message menu and context menu in step.
//!
//! Items whose action has no handler where focus is show disabled: GPUI's
//! macOS menus validate each item against the actions available, and an
//! item's own `disabled` never reaches AppKit (only a submenu's is applied,
//! in [`install`]). So an item that greys out has no handler on the app
//! (`App::on_action` answers always): a window takes it only while it acts,
//! by the rule the item is built with ([`app_commands`] for the zoom items
//! and Stop Speaking). Each item
//! shows the first chord bound to its action, so New Chat reads ⌘N while
//! ⇧⌘O keeps working.

use gpui_kit::component::input::{Copy, Cut, Paste, Redo, SelectAll, Undo};
use gpui_kit::prelude::FluentBuilder;
use gpui_kit::{
    App, Entity, Global, InteractiveElement, KeyBinding, Menu, MenuItem, OsAction, SharedString,
    SystemMenuType,
};

use conduit_components::views::focus::ShortcutHints;

use crate::AppState;
use crate::actions::*;
use crate::keymap::{
    FixedCommand, KeyStroke, Keymap, ShortcutAction, describe, fixed_stroke, new_chat_alias,
    to_gpui,
};
use crate::l10n::{ActiveL10n as _, L10n};
use crate::prefs::{Appearance, TEXT_SIZE_MAX, TEXT_SIZE_MIN};
use crate::stores::navigation::Area;
use crate::stores::settings::SettingsStore;
use crate::stores::speech::SpeechStore;
use crate::views::sidebar::ChatCommand;

/// GPUI Kit's own key bindings, captured after `gpui_kit::init` so a
/// keymap rebuild can restore them.
pub struct KitBindings(pub Vec<KeyBinding>);

impl Global for KitBindings {}

impl KitBindings {
    pub fn capture(cx: &mut App) {
        let bindings = cx.key_bindings().borrow().bindings().cloned().collect();
        cx.set_global(Self(bindings));
    }
}

/// The key context of the sidebar's chat list while it has focus.
pub const SIDEBAR_LIST_CONTEXT: &str = "ConduitSidebarList";

/// The fixed chords (not rebindable, as macOS fixes them): ⌘F finds in the
/// open chat, ⌥⌘F searches the chats (Mail's Mailbox Search).
pub fn find_stroke() -> KeyStroke {
    KeyStroke::new("f").primary()
}

/// Edit › Find › Search Chats: the sidebar's search field.
pub fn search_chats_stroke() -> KeyStroke {
    KeyStroke::new("f").primary().alt()
}

/// The chat commands in the one order every chat menu shows them: the
/// Chat menu, the sidebar's context menu and the toolbar's More menu.
/// `MoveTo` stands for the Move To submenu; a menu leaves out what does not
/// apply (Remove from Folder for a chat in none, Select in the menu bar).
/// Fork and Hide are a Hermes session's (its chat menus fill the slots
/// they share with every chat: Pin, Rename…, Archive and Delete…);
/// Duplicate is a LibreChat chat's.
pub const CHAT_COMMAND_ORDER: [ChatCommandSlot; 14] = [
    ChatCommandSlot::Pin,
    ChatCommandSlot::MarkUnread,
    ChatCommandSlot::Rename,
    ChatCommandSlot::Duplicate,
    ChatCommandSlot::GenerateTitle,
    ChatCommandSlot::Share,
    ChatCommandSlot::Export,
    ChatCommandSlot::Fork,
    ChatCommandSlot::MoveTo,
    ChatCommandSlot::RemoveFromFolder,
    ChatCommandSlot::Archive,
    ChatCommandSlot::Hide,
    ChatCommandSlot::Select,
    ChatCommandSlot::Delete,
];

/// A place in [`CHAT_COMMAND_ORDER`].
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ChatCommandSlot {
    /// Pin or Unpin.
    Pin,
    /// Mark as Unread or Mark as Read.
    MarkUnread,
    Rename,
    /// Duplicate Chat (a LibreChat chat's copy, on its server).
    Duplicate,
    GenerateTitle,
    Share,
    /// The Export submenu (Backup, Transcript).
    Export,
    /// A Hermes session's Fork.
    Fork,
    MoveTo,
    RemoveFromFolder,
    /// Archive or Unarchive.
    Archive,
    /// A Hermes session's Hide (Unhide in Hidden Chats).
    Hide,
    Select,
    Delete,
}

impl ChatCommandSlot {
    /// The slot a sidebar command fills.
    pub fn of(command: &ChatCommand) -> Self {
        match command {
            ChatCommand::Pin | ChatCommand::Unpin => Self::Pin,
            ChatCommand::Rename => Self::Rename,
            ChatCommand::Duplicate => Self::Duplicate,
            ChatCommand::MarkUnread | ChatCommand::MarkRead => Self::MarkUnread,
            ChatCommand::GenerateTitle => Self::GenerateTitle,
            ChatCommand::Export(_) => Self::Export,
            ChatCommand::Share => Self::Share,
            ChatCommand::MoveTo(_) => Self::MoveTo,
            ChatCommand::RemoveFromFolder => Self::RemoveFromFolder,
            ChatCommand::Archive | ChatCommand::Unarchive => Self::Archive,
            ChatCommand::Select => Self::Select,
            ChatCommand::Delete => Self::Delete,
        }
    }

    /// Where it stands in the order.
    pub fn rank(self) -> usize {
        CHAT_COMMAND_ORDER
            .iter()
            .position(|s| *s == self)
            .unwrap_or(usize::MAX)
    }
}

/// A View menu zoom step.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ZoomStep {
    /// Back to the density's own size.
    Actual,
    In,
    Out,
}

/// Applies `step` to the message text size (Settings › Appearance › Text
/// Size), a point at a time within its bounds. False when nothing changed.
pub fn zoom(appearance: &mut Appearance, step: ZoomStep) -> bool {
    let now = appearance.effective_text_size();
    let next = match step {
        ZoomStep::Actual => {
            return appearance.text_size.take().is_some();
        }
        ZoomStep::In => (now.round() + 1.).min(TEXT_SIZE_MAX),
        ZoomStep::Out => (now.round() - 1.).max(TEXT_SIZE_MIN),
    };
    if (next - now).abs() < 0.01 {
        return false;
    }
    appearance.text_size = Some(next);
    true
}

/// Which zoom items can act: in, out, back to the actual size.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ZoomState {
    pub can_zoom_in: bool,
    pub can_zoom_out: bool,
    pub can_reset: bool,
}

impl ZoomState {
    pub fn of(appearance: &Appearance) -> Self {
        let size = appearance.effective_text_size();
        Self {
            can_zoom_in: size < TEXT_SIZE_MAX - 0.01,
            can_zoom_out: size > TEXT_SIZE_MIN + 0.01,
            can_reset: appearance.text_size.is_some(),
        }
    }
}

impl Default for ZoomState {
    fn default() -> Self {
        Self {
            can_zoom_in: true,
            can_zoom_out: true,
            can_reset: false,
        }
    }
}

/// View › Actual Size, Zoom In and Zoom Out (the message text size) and
/// Chat › Stop Speaking (the reading), on the root of a window that shows
/// chat text: the main window, Settings (Appearance shows the size change,
/// Audio's preview reads) and Quick Ask. Each only while it would act, by
/// the rule its item is built with ([`ZoomState`], `SpeechStore::is_active`
/// in [`menu_state`]), so AppKit greys it otherwise.
pub fn app_commands<E: InteractiveElement + FluentBuilder>(
    el: E,
    settings: &Entity<SettingsStore>,
    speech: &Entity<SpeechStore>,
    cx: &App,
) -> E {
    let zoom = ZoomState::of(&settings.read(cx).prefs.appearance);
    el.when(zoom.can_reset, |el| {
        let settings = settings.clone();
        el.on_action(move |_: &ActualSize, _, cx| zoom_text(&settings, ZoomStep::Actual, cx))
    })
    .when(zoom.can_zoom_in, |el| {
        let settings = settings.clone();
        el.on_action(move |_: &ZoomIn, _, cx| zoom_text(&settings, ZoomStep::In, cx))
    })
    .when(zoom.can_zoom_out, |el| {
        let settings = settings.clone();
        el.on_action(move |_: &ZoomOut, _, cx| zoom_text(&settings, ZoomStep::Out, cx))
    })
    .when(speech.read(cx).is_active(), |el| {
        let speech = speech.clone();
        el.on_action(move |_: &StopSpeaking, _, cx| speech.update(cx, |s, cx| s.stop(cx)))
    })
}

/// Steps Settings › Appearance › Text Size (View › Zoom In and the rest).
fn zoom_text(settings: &Entity<SettingsStore>, step: ZoomStep, cx: &mut App) {
    settings.update(cx, |s, cx| {
        s.set_appearance(
            |a| {
                zoom(a, step);
            },
            cx,
        )
    });
}

/// Rebuilds every key binding: Kit's, the fixed macOS ones, and the live
/// rebindable shortcuts; then the tooltips' copy of them.
pub fn bind_keys(keymap: &Keymap, cx: &mut App) {
    let kit = cx
        .try_global::<KitBindings>()
        .map(|k| k.0.clone())
        .unwrap_or_default();
    cx.clear_key_bindings();
    cx.bind_keys(kit);
    cx.bind_keys([
        KeyBinding::new("cmd-q", Quit, None),
        KeyBinding::new("cmd-,", OpenSettings, None),
        KeyBinding::new("cmd-h", Hide, None),
        KeyBinding::new("alt-cmd-h", HideOthers, None),
        KeyBinding::new("cmd-w", CloseWindow, None),
        KeyBinding::new("cmd-m", Minimize, None),
        KeyBinding::new("ctrl-cmd-f", ToggleFullScreen, None),
        // Edit › Find › Find…: also from a text field, where Kit's own ⌘F
        // (search inside a code editor) would otherwise take it.
        KeyBinding::new("cmd-f", FindInChat, None),
        KeyBinding::new("cmd-f", FindInChat, Some("Input")),
        KeyBinding::new("cmd-g", FindNext, None),
        KeyBinding::new("cmd-shift-g", FindPrevious, None),
        // Edit › Find › Search Chats, as Mail's Mailbox Search.
        KeyBinding::new("alt-cmd-f", FindChats, None),
        // File › New Temporary Chat, as Safari's New Private Window.
        KeyBinding::new("shift-cmd-n", NewTemporaryChat, None),
        // Chat › Regenerate.
        KeyBinding::new("cmd-r", RegenerateLastAnswer, None),
        // Chat › Stop Speaking: ⌘., the Mac's Cancel, from a text field too.
        KeyBinding::new("cmd-.", crate::actions::StopSpeaking, None),
        KeyBinding::new("cmd-.", crate::actions::StopSpeaking, Some("Input")),
        // Chat › Expand Editor and Ask Conduit, from the message field too.
        KeyBinding::new("shift-cmd-e", crate::actions::ExpandEditor, None),
        KeyBinding::new("shift-cmd-a", crate::actions::AskConduit, None),
        // Chat › Chat Settings… (Get Info's chord).
        KeyBinding::new("cmd-i", crate::actions::ChatSettings, None),
        // Chat › Previous Chat and Next Chat, as ⌃⇥ steps through Safari's
        // tabs (from a text field too).
        KeyBinding::new("ctrl-shift-tab", PreviousChat, None),
        KeyBinding::new("ctrl-tab", NextChat, None),
        // View › Actual Size, Zoom In (⌘+, and ⌘= without Shift) and Zoom
        // Out. The first binding is the one the menu shows.
        KeyBinding::new("cmd-0", ActualSize, None),
        KeyBinding::new("cmd-+", ZoomIn, None),
        KeyBinding::new("cmd-=", ZoomIn, None),
        KeyBinding::new("cmd--", ZoomOut, None),
        // Edit › Clear Scrollback in a terminal's console: Terminal's own
        // ⌥⌘K (its ⌘K, Clear to Start, stays the palette here).
        KeyBinding::new(
            "alt-cmd-k",
            crate::views::terminal::console::ClearScrollback,
            Some(crate::views::terminal::console::CONSOLE_CONTEXT),
        ),
        // Chat › Delete…, from the sidebar's list (a text field keeps ⌘⌫
        // for deleting to the start of the line).
        KeyBinding::new("cmd-backspace", DeleteChat, Some(SIDEBAR_LIST_CONTEXT)),
        // Go › Back and Forward (Finder's ⌘[ and ⌘]); Go › the sidebar's
        // sections, ⌘1… in its order (the phone's ⌘1–⌘5 pick its tabs).
        KeyBinding::new("cmd-[", GoBack, None),
        KeyBinding::new("cmd-]", GoForward, None),
        KeyBinding::new("cmd-1", GoToSection { index: 1 }, None),
        KeyBinding::new("cmd-2", GoToSection { index: 2 }, None),
        KeyBinding::new("cmd-3", GoToSection { index: 3 }, None),
        KeyBinding::new("cmd-4", GoToSection { index: 4 }, None),
        KeyBinding::new("cmd-5", GoToSection { index: 5 }, None),
        KeyBinding::new("cmd-6", GoToSection { index: 6 }, None),
        KeyBinding::new("cmd-7", GoToSection { index: 7 }, None),
        KeyBinding::new("cmd-8", GoToSection { index: 8 }, None),
        // Go › Move Focus to Next and Previous Area: ⌥⌘` and ⌥⌘~ (the Mac
        // reports Shift with ` as ~), as Xcode's, from a text field and the
        // terminal too.
        KeyBinding::new("alt-cmd-`", crate::actions::MoveFocusToNextArea, None),
        KeyBinding::new("alt-cmd-~", crate::actions::MoveFocusToPreviousArea, None),
        // Tab through the chat in the messages' order, rows off screen
        // included (the window's own order holds only what is drawn).
        KeyBinding::new(
            "tab",
            crate::actions::FocusNextControl,
            Some(crate::views::chat_pane::CHAT_PANE_CONTEXT),
        ),
        KeyBinding::new(
            "shift-tab",
            crate::actions::FocusPreviousControl,
            Some(crate::views::chat_pane::CHAT_PANE_CONTEXT),
        ),
    ]);
    let table = keymap.table();
    let mut bindings = vec![];
    for shortcut in &table {
        if !shortcut.action.is_live() {
            continue;
        }
        // A bare key would eat that letter out of every text field; it is
        // bound once the views can tell typing apart.
        if !shortcut.while_typing {
            log::info!("{} is a bare key; not bound", shortcut.action.name());
            continue;
        }
        match KeyBinding::load(
            &to_gpui(&shortcut.stroke),
            for_shortcut(shortcut.action),
            None,
            false,
            None,
            cx,
        ) {
            Ok(b) => bindings.push(b),
            Err(e) => log::warn!("cannot bind {}: {e:?}", shortcut.action.name()),
        }
    }
    // ⇧⌘O, Open WebUI's New Chat, keeps working beside ⌘N while nothing
    // else has it (bound after, so menus show ⌘N).
    let alias = new_chat_alias();
    if table.iter().all(|s| s.stroke != alias)
        && let Ok(b) = KeyBinding::load(&to_gpui(&alias), Box::new(NewChat), None, false, None, cx)
    {
        bindings.push(b);
    }
    // Window › Quick Ask shows its chord. With the global shortcut on, the
    // system hot key takes the press before any window sees it; this
    // binding answers while Conduit is in front either way (as any menu
    // item's shortcut), and labels the menu item.
    if let Some(stroke) = quick_ask_stroke(cx)
        && table.iter().all(|s| s.stroke != stroke)
        && let Ok(b) = KeyBinding::load(
            &to_gpui(&stroke),
            Box::new(ToggleQuickAsk),
            None,
            false,
            None,
            cx,
        )
    {
        bindings.push(b);
    }
    cx.bind_keys(bindings);
    // Notes: the editor's and the list's own keys, and ⌘N as New
    // Note while the Notes section is shown (Notes' File › New Note).
    // Bound after the shortcut table: GPUI ranks a binding without a
    // context as deep as the focus, and the later of two equals wins, so
    // bound before, New Chat would take ⌘N and the palette ⌘K (Link).
    cx.bind_keys(crate::views::notes::editor::bindings());
    cx.bind_keys(crate::views::notes::list::bindings());
    cx.bind_keys([
        KeyBinding::new(
            "cmd-n",
            crate::views::notes::NewNote,
            Some(crate::views::notes::list::NOTES_LIST_CONTEXT),
        ),
        KeyBinding::new(
            "cmd-n",
            crate::views::notes::NewNote,
            Some(crate::views::notes::pane::NOTE_PANE_CONTEXT),
        ),
    ]);
    cx.set_global(shortcut_hints(keymap, quick_ask_stroke(cx).as_ref()));
}

/// The Quick Ask chord (Settings › Desktop), global or not.
fn quick_ask_stroke(cx: &App) -> Option<KeyStroke> {
    let settings = cx.try_global::<AppState>()?.settings.read(cx);
    Some(settings.prefs.desktop.quick_ask_stroke())
}

/// The chords tooltips show, as menus write them.
pub fn shortcut_hints(keymap: &Keymap, quick_ask: Option<&KeyStroke>) -> ShortcutHints {
    let mac = cfg!(target_os = "macos");
    let table = keymap.table();
    let chord = |action: ShortcutAction| -> Option<SharedString> {
        table
            .iter()
            .find(|s| s.action == action && action.is_live() && s.while_typing)
            .map(|s| describe(&s.stroke, mac).into())
    };
    ShortcutHints {
        new_chat: chord(ShortcutAction::NewChat),
        toggle_sidebar: chord(ShortcutAction::ToggleSidebar),
        settings: Some(describe(&KeyStroke::new(",").primary(), mac).into()),
        palette: chord(ShortcutAction::OpenPalette),
        model_picker: chord(ShortcutAction::FocusModelPicker),
        stop: chord(ShortcutAction::StopGenerating),
        send: Some(describe(&KeyStroke::new("enter"), mac).into()),
        copy_last_reply: chord(ShortcutAction::CopyLastResponse),
        quick_ask: quick_ask.map(|s| describe(s, mac).into()),
        // The sidebar's search field teaches its own chord.
        find: Some(describe(&search_chats_stroke(), mac).into()),
        temporary_chat: Some(describe(&fixed_stroke(FixedCommand::NewTemporaryChat), mac).into()),
        regenerate: Some(describe(&fixed_stroke(FixedCommand::Regenerate), mac).into()),
        dictate: chord(ShortcutAction::Dictate),
        read_aloud: chord(ShortcutAction::ReadAloud),
        voice_call: chord(ShortcutAction::VoiceCall),
    }
}

/// The open chat, as the Chat menu acts on it.
#[derive(Clone, Debug, PartialEq)]
pub struct ChatMenuState {
    pub pinned: bool,
    pub archived: bool,
    pub folder_id: Option<String>,
    /// It has an unread dot (Mark as Read offered instead).
    pub unread: bool,
    /// What its menus offer, by the core's rule for its backend (Share,
    /// Duplicate, Move To, Mark as Unread, Generate Title, Export): the
    /// sidebar's context menu reads the same.
    pub offered: conduit_protocol::ChatMenuAbilities,
    /// Show Branches…: the open chat's versions live on the server (the
    /// core's branch rule, from the chat's detail once loaded).
    pub branches: bool,
}

/// What the menu bar follows.
#[derive(Clone, Debug, PartialEq)]
pub struct MenuState {
    /// The Go menu's sections: the areas the sidebar shows, in its order
    /// (⌘1 the first). Empty without the main frame.
    pub areas: Vec<Area>,
    pub can_go_back: bool,
    pub can_go_forward: bool,
    pub sidebar_visible: bool,
    pub full_screen: bool,
    /// The open chat, when it takes changes (not another user's).
    pub chat: Option<ChatMenuState>,
    /// The open Hermes session, whose commands the Chat menu has instead.
    pub hermes: Option<conduit_protocol::HermesSessionDto>,
    /// Chats are chosen in the sidebar: Archive, Move to and Delete… act
    /// on them, and the commands for one chat are off
    /// (`SidebarView::on_selection`).
    pub choosing: bool,
    /// Folders a chat may be filed in: `(id, name)`, by name.
    pub folders: Vec<(String, String)>,
    /// The View menu's zoom items.
    pub zoom: ZoomState,
    /// Chat › Chat Settings… and Tool Settings… have something to show.
    pub chat_settings: bool,
    pub tool_settings: bool,
    /// Chat › Save Chat: a temporary chat with messages is open.
    pub save_chat: bool,
    /// The open chat is a Hermes session: Chat › Context & Usage….
    pub hermes_context: bool,
    /// The composer is dictating: Chat › Stop Dictation.
    pub dictating: bool,
    /// The main window shows a chat whose composer takes Chat › Ask
    /// Conduit's selection: a temporary or Hermes chat too, not a read-only
    /// one (`ChatPane::can_ask_conduit`).
    pub ask_conduit: bool,
    /// The main window shows a chat to read from (Chat › Read Aloud): a
    /// read-only, temporary or Hermes chat too.
    pub read_aloud: bool,
    /// Something is being read aloud (Chat › Stop Speaking).
    pub speaking: bool,
    /// A voice call is on (Chat › End Voice Call).
    pub in_call: bool,
    /// A call can start in the open chat (Chat › Start Voice Call): the
    /// composer's call button is ready, and the window online.
    pub call_ready: bool,
}

impl Default for MenuState {
    fn default() -> Self {
        Self {
            areas: vec![],
            can_go_back: false,
            can_go_forward: false,
            sidebar_visible: true,
            full_screen: false,
            chat: None,
            hermes: None,
            choosing: false,
            folders: vec![],
            zoom: ZoomState::default(),
            chat_settings: false,
            tool_settings: false,
            save_chat: false,
            hermes_context: false,
            dictating: false,
            ask_conduit: false,
            read_aloud: false,
            speaking: false,
            in_call: false,
            call_ready: false,
        }
    }
}

/// The menu bar as last installed, and whether the main window is full
/// screen (its bounds observer reports it).
#[derive(Default)]
struct MenuSnapshot {
    state: Option<MenuState>,
    full_screen: bool,
}

impl Global for MenuSnapshot {}

/// The main window entered or left full screen.
pub fn set_full_screen(full_screen: bool, cx: &mut App) {
    if cx.default_global::<MenuSnapshot>().full_screen != full_screen {
        cx.global_mut::<MenuSnapshot>().full_screen = full_screen;
        refresh_menus(cx);
    }
}

/// The state the menus should show now.
pub fn menu_state(cx: &App) -> MenuState {
    let full_screen = cx
        .try_global::<MenuSnapshot>()
        .is_some_and(|s| s.full_screen);
    let Some(state) = cx.try_global::<AppState>() else {
        return MenuState {
            full_screen,
            ..MenuState::default()
        };
    };
    let sidebar_visible = state.layout.read(cx).state.sidebar_visible;
    let zoom = ZoomState::of(&state.settings.read(cx).prefs.appearance);
    let chat_list = state.stores.chat_list.read(cx);
    let branches = state
        .main_view
        .as_ref()
        .is_some_and(|v| v.read(cx).chat_pane.read(cx).branches(cx));
    let chat = state
        .stores
        .navigation
        .read(cx)
        .selected_chat()
        .and_then(|id| chat_list.find(id))
        .filter(|c| !c.read_only)
        .map(|c| ChatMenuState {
            pinned: c.pinned,
            archived: c.archived,
            folder_id: c.folder_id.clone(),
            unread: c.unread,
            offered: c.menu.clone(),
            branches,
        });
    let mut folders: Vec<(String, String)> = chat_list
        .list
        .as_ref()
        .map(|l| {
            l.folders
                .iter()
                .filter(|f| f.can_write)
                .map(|f| (f.id.clone(), f.name.clone()))
                .collect()
        })
        .unwrap_or_default();
    folders.sort_by_key(|(_, name)| name.to_lowercase());
    let main = state
        .main_view
        .as_ref()
        .is_some_and(|v| v.read(cx).shows_main(cx));
    let areas = if main {
        crate::stores::areas::visible_areas(&state.stores.session.read(cx).capabilities())
    } else {
        vec![]
    };
    let usable = |step: &crate::stores::navigation::Selection| areas.contains(&step.area());
    let navigation = state.stores.navigation.read(cx);
    let (can_go_back, can_go_forward) = (
        main && navigation.can_go_back(usable),
        main && navigation.can_go_forward(usable),
    );
    let offer = state
        .main_view
        .as_ref()
        .filter(|_| main)
        .map(|v| v.read(cx).chat_pane.read(cx).settings_offer.clone())
        .unwrap_or_default();
    let save_chat = state
        .main_view
        .as_ref()
        .filter(|_| main)
        .is_some_and(|v| v.read(cx).chat_pane.read(cx).can_save_temporary(cx));
    let hermes = match navigation.selected_item() {
        Some(crate::stores::navigation::AreaItem::HermesSession(id)) if main => {
            state.stores.areas.read(cx).hermes_session(id).cloned()
        }
        _ => None,
    };
    let dictating = state.main_view.as_ref().filter(|_| main).is_some_and(|v| {
        let composer = v.read(cx).chat_pane.read(cx).composer.clone();
        composer.read(cx).dictating(cx)
    });
    let choosing = state
        .main_view
        .as_ref()
        .filter(|_| main)
        .is_some_and(|v| v.read(cx).sidebar.read(cx).has_selection());
    MenuState {
        areas,
        can_go_back,
        can_go_forward,
        sidebar_visible,
        full_screen,
        chat,
        hermes,
        choosing,
        folders,
        zoom,
        chat_settings: state
            .main_view
            .as_ref()
            .filter(|_| main)
            .is_some_and(|v| v.read(cx).chat_pane.read(cx).can_open_chat_settings(cx)),
        tool_settings: !offer.tool_targets.is_empty(),
        save_chat,
        hermes_context: state
            .main_view
            .as_ref()
            .filter(|_| main)
            .is_some_and(|v| v.read(cx).chat_pane.read(cx).hermes_context(cx)),
        dictating,
        ask_conduit: state
            .main_view
            .as_ref()
            .filter(|_| main)
            .is_some_and(|v| v.read(cx).chat_pane.read(cx).can_ask_conduit(cx)),
        read_aloud: state
            .main_view
            .as_ref()
            .filter(|_| main)
            .is_some_and(|v| v.read(cx).chat_pane.read(cx).can_read_aloud(cx)),
        speaking: state.stores.speech.read(cx).is_active(),
        in_call: state.stores.call.read(cx).is_active(),
        call_ready: state
            .main_view
            .as_ref()
            .filter(|_| main)
            .is_some_and(|v| v.read(cx).chat_pane.read(cx).call_startable(cx)),
    }
}

/// Installs the menus again when what they show has changed.
pub fn refresh_menus(cx: &mut App) {
    let state = menu_state(cx);
    if cx
        .try_global::<MenuSnapshot>()
        .and_then(|s| s.state.as_ref())
        == Some(&state)
    {
        return;
    }
    install(state, cx);
}

/// Installs the localized menu bar.
pub fn set_menus(cx: &mut App) {
    let state = menu_state(cx);
    install(state, cx);
}

fn install(state: MenuState, cx: &mut App) {
    let l: L10n = cx.l10n().clone();
    let menus = build_menus(&l, &state);
    let move_disabled = move_to_disabled(&state);
    let export_disabled = export_disabled(&state);
    cx.default_global::<MenuSnapshot>().state = Some(state);
    cx.set_menus(menus);
    // GPUI's `disabled` on a submenu does not reach AppKit, which enables
    // every item holding a submenu.
    #[cfg(target_os = "macos")]
    {
        let mut off = vec![];
        if move_disabled {
            off.push(l.desktop_menu_move_to());
        }
        if export_disabled {
            off.push(l.chat_export_action());
        }
        if !off.is_empty() {
            crate::shell::macos::disable_submenus(&l.desktop_menu_chat(), &off);
        }
        // GPUI writes "tab" as the key equivalent's text (AppKit draws T).
        crate::shell::macos::tab_key_equivalents(
            &l.desktop_menu_chat(),
            &[
                (l.desktop_menu_previous_chat(), true),
                (l.desktop_menu_next_chat(), false),
            ],
        );
    }
    #[cfg(not(target_os = "macos"))]
    let _ = (move_disabled, export_disabled);
}

/// Chat › Export Chat has nothing to export: no chat open, or one whose
/// backend offers no export (the core's rule, as the menu item reads it).
pub fn export_disabled(state: &MenuState) -> bool {
    !state.chat.as_ref().is_some_and(|c| c.offered.export)
        || taken_by_selection(
            state,
            &ChatCommand::Export(conduit_protocol::ChatExportFormat::Json),
        )
}

/// A command for one chat while chats are chosen: they take it and leave
/// it undone, so its item is greyed.
fn taken_by_selection(state: &MenuState, command: &ChatCommand) -> bool {
    state.choosing && crate::views::sidebar::bulk_action(command).is_none()
}

/// Chat › Move to has nothing to act on: no chat open (or another user's),
/// or no folder to file it in.
pub fn move_to_disabled(state: &MenuState) -> bool {
    !state.chat.as_ref().is_some_and(|c| c.offered.r#move) || state.folders.is_empty()
}

/// The menu bar for `state`, in `l`'s words.
pub fn build_menus(l10n: &L10n, state: &MenuState) -> Vec<Menu> {
    let zoom = state.zoom;
    let notes = state.areas.contains(&Area::Notes);
    let mut menus = vec![
        Menu::new("Conduit").items([
            MenuItem::action(l10n.about_conduit(), About),
            MenuItem::action(l10n.desktop_check_for_updates(), CheckForUpdates),
            MenuItem::separator(),
            MenuItem::action(l10n.desktop_menu_settings(), OpenSettings),
            MenuItem::separator(),
            MenuItem::os_submenu(l10n.desktop_menu_services(), SystemMenuType::Services),
            MenuItem::separator(),
            MenuItem::action(l10n.desktop_menu_hide(), Hide),
            MenuItem::action(l10n.desktop_menu_hide_others(), HideOthers),
            MenuItem::action(l10n.desktop_menu_show_all(), ShowAll),
            MenuItem::separator(),
            MenuItem::action(l10n.desktop_menu_quit(), Quit),
        ]),
        Menu::new(l10n.file()).items(
            [
                MenuItem::action(l10n.new_chat(), NewChat),
                MenuItem::action(l10n.desktop_new_temporary_chat(), NewTemporaryChat),
                // Finder's and Notes' New Folder: greyed where folders cannot
                // be made (no handler answers it then).
                MenuItem::action(l10n.desktop_new_folder(), NewFolder),
                // New Channel… likewise, for an account that may make one.
                MenuItem::action(
                    l10n.desktop_new_channel(),
                    crate::views::channels::NewChannel,
                ),
            ]
            .into_iter()
            // With Hermes on: New Room…, greyed where no room can be made.
            .chain(state.areas.contains(&Area::Hermes).then(|| {
                MenuItem::action(
                    l10n.desktop_hermes_new_room_menu(),
                    crate::views::hermes_rooms::NewRoom,
                )
            }))
            .chain([
                MenuItem::separator(),
                MenuItem::action(l10n.desktop_menu_close_window(), CloseWindow),
            ]),
        ),
        Menu::new(l10n.edit()).items([
            MenuItem::os_action(l10n.desktop_menu_undo(), Undo, OsAction::Undo),
            MenuItem::os_action(l10n.desktop_menu_redo(), Redo, OsAction::Redo),
            MenuItem::separator(),
            MenuItem::os_action(l10n.desktop_menu_cut(), Cut, OsAction::Cut),
            MenuItem::os_action(l10n.copy(), Copy, OsAction::Copy),
            MenuItem::os_action(l10n.desktop_menu_paste(), Paste, OsAction::Paste),
            MenuItem::os_action(
                l10n.desktop_menu_select_all(),
                SelectAll,
                OsAction::SelectAll,
            ),
            // Terminal's Clear Scrollback, greyed where no console has the
            // keys (no handler answers it then).
            MenuItem::action(
                l10n.desktop_terminal_clear_scrollback(),
                crate::views::terminal::console::ClearScrollback,
            ),
            MenuItem::separator(),
            // Mail's Find submenu: find in what is open, then search the
            // whole list.
            MenuItem::submenu(Menu::new(l10n.desktop_menu_find_submenu()).items([
                MenuItem::action(l10n.desktop_menu_find(), FindInChat),
                MenuItem::action(l10n.desktop_find_next(), FindNext),
                MenuItem::action(l10n.desktop_find_previous(), FindPrevious),
                MenuItem::separator(),
                MenuItem::action(l10n.desktop_menu_search_chats(), FindChats),
            ])),
        ]),
        Menu::new(l10n.desktop_menu_view()).items([
            MenuItem::action(
                if state.sidebar_visible {
                    l10n.desktop_menu_hide_sidebar()
                } else {
                    l10n.desktop_menu_show_sidebar()
                },
                ToggleSidebar,
            ),
            MenuItem::separator(),
            MenuItem::action(l10n.desktop_menu_search_chats_and_commands(), OpenPalette),
            MenuItem::separator(),
            MenuItem::action(l10n.desktop_menu_actual_size(), ActualSize).disabled(!zoom.can_reset),
            MenuItem::action(l10n.desktop_menu_zoom_in(), ZoomIn).disabled(!zoom.can_zoom_in),
            MenuItem::action(l10n.desktop_menu_zoom_out(), ZoomOut).disabled(!zoom.can_zoom_out),
            MenuItem::separator(),
            MenuItem::action(
                if state.full_screen {
                    l10n.desktop_menu_exit_full_screen()
                } else {
                    l10n.desktop_menu_enter_full_screen()
                },
                ToggleFullScreen,
            ),
        ]),
        Menu::new(l10n.desktop_menu_go()).items(go_menu_items(l10n, state)),
        Menu::new(l10n.desktop_menu_chat()).items(chat_menu_items(l10n, state)),
        Menu::new(l10n.desktop_menu_window()).items([
            MenuItem::action(l10n.desktop_minimize_window(), Minimize),
            MenuItem::action(l10n.desktop_menu_zoom(), Zoom),
            MenuItem::separator(),
            MenuItem::action(l10n.desktop_tray_quick_ask(), ToggleQuickAsk),
            MenuItem::separator(),
            MenuItem::action(l10n.desktop_menu_bring_all_to_front(), BringAllToFront),
        ]),
        Menu::new(l10n.desktop_menu_help()).items([
            MenuItem::action(l10n.desktop_menu_conduit_help(), OpenHelp),
            MenuItem::action(l10n.desktop_menu_keyboard_shortcuts(), ShowShortcuts),
        ]),
    ];
    if notes {
        // File › New Note, after New Temporary Chat (⌘N while the Notes
        // section is shown, as Notes' own).
        if let Some(file) = menus.get_mut(1) {
            file.items.insert(
                2,
                MenuItem::action(l10n.desktop_new_note(), crate::views::notes::NewNote),
            );
        }
        // Format, after Edit, as Notes' and TextEdit's: greyed unless a
        // note is being edited (the editor answers its actions).
        menus.insert(3, format_menu(l10n));
    }
    menus
}

/// The Format menu: a note's paragraph styles, text styles, lists and
/// blocks, with the editor's keys.
fn format_menu(l10n: &L10n) -> Menu {
    use crate::views::notes::editor as e;
    Menu::new(l10n.desktop_note_format()).items([
        MenuItem::action(l10n.desktop_note_style_title(), e::Title),
        MenuItem::action(l10n.desktop_note_style_heading(), e::Heading),
        MenuItem::action(l10n.desktop_note_style_subheading(), e::Subheading),
        MenuItem::action(l10n.desktop_note_style_body(), e::Body),
        MenuItem::separator(),
        MenuItem::action(l10n.desktop_note_bold(), e::ToggleBold),
        MenuItem::action(l10n.desktop_note_italic(), e::ToggleItalic),
        MenuItem::action(l10n.desktop_note_strikethrough(), e::ToggleStrike),
        MenuItem::action(l10n.desktop_note_code(), e::ToggleCode),
        MenuItem::action(l10n.desktop_add_link_ellipsis(), e::AddLink),
        MenuItem::separator(),
        MenuItem::action(l10n.desktop_note_bulleted_list(), e::BulletList),
        MenuItem::action(l10n.desktop_note_numbered_list(), e::NumberedList),
        MenuItem::action(l10n.desktop_note_checklist(), e::Checklist),
        MenuItem::action(l10n.desktop_note_mark_checked(), e::ToggleChecked),
        MenuItem::separator(),
        MenuItem::action(l10n.desktop_note_quote(), e::QuoteBlock),
        MenuItem::action(l10n.desktop_note_code_block(), e::CodeBlock),
    ])
}

/// The Go menu, as Finder's: Back and Forward, then each section the
/// sidebar shows, ⌘1 for the first.
fn go_menu_items(l10n: &L10n, state: &MenuState) -> Vec<MenuItem> {
    let mut items = vec![
        MenuItem::action(l10n.desktop_menu_back(), GoBack).disabled(!state.can_go_back),
        MenuItem::action(l10n.desktop_menu_forward(), GoForward).disabled(!state.can_go_forward),
    ];
    if !state.areas.is_empty() {
        items.push(MenuItem::separator());
    }
    for (i, area) in state.areas.iter().take(GO_SECTIONS).enumerate() {
        items.push(MenuItem::action(
            crate::views::sidebar::area_label(*area, l10n),
            GoToSection { index: i + 1 },
        ));
    }
    // The keyboard's way between the window's areas, and out of the
    // terminal, whose Tab is the shell's.
    items.push(MenuItem::separator());
    items.push(MenuItem::action(
        l10n.desktop_menu_next_area(),
        crate::actions::MoveFocusToNextArea,
    ));
    items.push(MenuItem::action(
        l10n.desktop_menu_previous_area(),
        crate::actions::MoveFocusToPreviousArea,
    ));
    items
}

/// The Chat menu: the open chat's commands in [`CHAT_COMMAND_ORDER`] (as its
/// context menu lists them), then its sheets (Chat Settings…, Tool
/// Settings…, Show Branches…, Save Chat) just before Delete…, as the
/// toolbar's More menu has them, then the model and the message field, then
/// the answer's.
fn chat_menu_items(l10n: &L10n, state: &MenuState) -> Vec<MenuItem> {
    let no_chat = state.chat.is_none();
    let swallowed = |command: ChatCommand| taken_by_selection(state, &command);
    let chat = state.chat.clone();
    let offered = chat.as_ref().map(|c| c.offered.clone()).unwrap_or_default();
    let filed = chat
        .as_ref()
        .is_some_and(|c| c.folder_id.is_some() && c.offered.r#move);
    let move_to = state
        .folders
        .iter()
        .map(|(id, name)| {
            MenuItem::action(
                name.clone(),
                MoveChatTo {
                    folder_id: Some(id.clone()),
                },
            )
            .checked(chat.as_ref().and_then(|c| c.folder_id.as_deref()) == Some(id.as_str()))
        })
        .collect::<Vec<_>>();
    let move_disabled = move_to_disabled(state);
    let mut move_to = Some(move_to);
    let mut items = vec![];
    // A Hermes session: its own commands, in the same slots.
    let hermes = state.hermes.as_ref().map(|session| {
        (
            session.id.clone(),
            crate::views::hermes_sessions::commands(session),
        )
    });
    for slot in CHAT_COMMAND_ORDER {
        if let Some((session_id, commands)) = &hermes {
            for command in commands.iter().filter(|c| c.slot() == slot) {
                if slot == ChatCommandSlot::Delete {
                    items.push(MenuItem::separator());
                    // The open session's own sheet, as the toolbar's More
                    // has it before Delete….
                    if state.hermes_context {
                        items.extend([
                            MenuItem::action(
                                l10n.desktop_hermes_context_usage_menu(),
                                crate::actions::ShowContextUsage,
                            ),
                            MenuItem::separator(),
                        ]);
                    }
                }
                items.push(MenuItem::action(
                    command.label(l10n),
                    crate::views::hermes_sessions::HermesMenu {
                        session_id: session_id.clone(),
                        command: *command,
                    },
                ));
            }
            continue;
        }
        match slot {
            ChatCommandSlot::Pin => items.push(
                MenuItem::action(
                    if chat.as_ref().is_some_and(|c| c.pinned) {
                        l10n.desktop_unpin_chat()
                    } else {
                        l10n.desktop_pin_chat()
                    },
                    TogglePinChat,
                )
                .disabled(no_chat || swallowed(ChatCommand::Pin)),
            ),
            ChatCommandSlot::Rename => items.push(
                MenuItem::action(l10n.desktop_menu_rename_chat(), RenameChat)
                    .disabled(no_chat || swallowed(ChatCommand::Rename)),
            ),
            // Only a LibreChat chat has it.
            ChatCommandSlot::Duplicate if offered.duplicate => items.push(
                MenuItem::action(l10n.libre_chat_duplicate_chat(), DuplicateChat)
                    .disabled(swallowed(ChatCommand::Duplicate)),
            ),
            ChatCommandSlot::Duplicate => {}
            ChatCommandSlot::MarkUnread => items.push(
                MenuItem::action(
                    if chat.as_ref().is_some_and(|c| c.unread) {
                        l10n.desktop_mark_as_read()
                    } else {
                        l10n.mark_as_unread()
                    },
                    MarkChatUnread,
                )
                .disabled(!offered.mark_unread || swallowed(ChatCommand::MarkUnread)),
            ),
            ChatCommandSlot::GenerateTitle => items.push(
                MenuItem::action(l10n.generate_title(), GenerateChatTitle)
                    .disabled(!offered.generate_title || swallowed(ChatCommand::GenerateTitle)),
            ),
            ChatCommandSlot::Export => items.push(MenuItem::submenu(
                Menu::new(l10n.chat_export_action())
                    .items(vec![
                        MenuItem::action(
                            format!("{}…", l10n.chat_export_json()),
                            ExportChatAs {
                                format: conduit_protocol::ChatExportFormat::Json,
                            },
                        ),
                        MenuItem::action(
                            format!("{}…", l10n.chat_export_markdown()),
                            ExportChatAs {
                                format: conduit_protocol::ChatExportFormat::Markdown,
                            },
                        ),
                    ])
                    .disabled(export_disabled(state)),
            )),
            ChatCommandSlot::Share => items.push(
                MenuItem::action(l10n.desktop_share_chat_sheet(), ShareChat)
                    .disabled(!offered.share || swallowed(ChatCommand::Share)),
            ),
            ChatCommandSlot::MoveTo => items.push(MenuItem::submenu(
                Menu::new(l10n.desktop_menu_move_to())
                    .items(move_to.take().unwrap_or_default())
                    .disabled(move_disabled),
            )),
            ChatCommandSlot::RemoveFromFolder if filed => items.push(MenuItem::action(
                l10n.desktop_menu_remove_from_folder(),
                MoveChatTo { folder_id: None },
            )),
            ChatCommandSlot::RemoveFromFolder => {}
            ChatCommandSlot::Archive => {
                let archived = chat.as_ref().is_some_and(|c| c.archived);
                items.push(
                    MenuItem::action(
                        if archived {
                            l10n.unarchive()
                        } else {
                            l10n.desktop_archive_chat()
                        },
                        ArchiveChat,
                    )
                    .disabled(
                        no_chat
                            || swallowed(if archived {
                                ChatCommand::Unarchive
                            } else {
                                ChatCommand::Archive
                            }),
                    ),
                )
            }
            // Selecting is the sidebar's own mode: its menus only. Fork and
            // Hide are a Hermes session's.
            ChatCommandSlot::Select | ChatCommandSlot::Fork | ChatCommandSlot::Hide => {}
            ChatCommandSlot::Delete => {
                items.extend([
                    MenuItem::separator(),
                    MenuItem::action(
                        l10n.desktop_chat_settings_menu(),
                        crate::actions::ChatSettings,
                    )
                    .disabled(!state.chat_settings),
                    MenuItem::action(
                        l10n.desktop_tool_settings_menu(),
                        crate::actions::ToolSettings,
                    )
                    .disabled(!state.tool_settings),
                    MenuItem::action(l10n.desktop_menu_show_branches(), ShowBranches)
                        .disabled(!chat.as_ref().is_some_and(|c| c.branches)),
                ]);
                // Only a Hermes chat has a context window to show.
                if state.hermes_context {
                    items.push(MenuItem::action(
                        l10n.desktop_hermes_context_usage_menu(),
                        crate::actions::ShowContextUsage,
                    ));
                }
                items.extend([
                    MenuItem::action(l10n.save_chat(), SaveTemporaryChat)
                        .disabled(!state.save_chat),
                    MenuItem::separator(),
                    MenuItem::action(l10n.desktop_menu_delete_chat(), DeleteChat).disabled(no_chat),
                ]);
            }
        }
    }
    items.extend([
        MenuItem::separator(),
        // The chat before or after in the sidebar (Safari's Show Previous
        // Tab and Show Next Tab, in that order).
        MenuItem::action(l10n.desktop_menu_previous_chat(), PreviousChat),
        MenuItem::action(l10n.desktop_menu_next_chat(), NextChat),
        MenuItem::separator(),
        MenuItem::action(l10n.desktop_menu_choose_model(), FocusModelPicker),
        MenuItem::action(l10n.desktop_shortcut_focus_composer(), FocusComposer),
        MenuItem::action(l10n.desktop_expand_editor(), crate::actions::ExpandEditor),
        MenuItem::action(
            if state.dictating {
                l10n.desktop_stop_dictation()
            } else {
                l10n.start_dictation()
            },
            crate::actions::Dictate,
        ),
        MenuItem::action(l10n.ask_conduit_action(), crate::actions::AskConduit)
            .disabled(!state.ask_conduit),
        MenuItem::separator(),
        MenuItem::action(l10n.regenerate(), RegenerateLastAnswer).disabled(no_chat),
        MenuItem::action(l10n.desktop_stop_generating(), StopGenerating),
        MenuItem::separator(),
        MenuItem::action(l10n.desktop_read_aloud(), crate::actions::ReadAloud)
            .disabled(!state.read_aloud),
        MenuItem::action(l10n.desktop_stop_speaking(), crate::actions::StopSpeaking)
            .disabled(!state.speaking),
        MenuItem::action(
            if state.in_call {
                l10n.desktop_end_voice_call()
            } else {
                l10n.desktop_start_voice_call()
            },
            crate::actions::VoiceCall,
        )
        .disabled(!state.in_call && !state.call_ready),
        MenuItem::separator(),
        MenuItem::action(l10n.desktop_menu_copy_last_reply(), CopyLastResponse),
        MenuItem::action(l10n.desktop_menu_copy_last_code_block(), CopyLastCodeBlock),
    ]);
    items
}

/// Whether AppKit enables the menu item for `action` with `vcx`'s window in
/// front: its validation asks `App::is_action_available` (the key window's
/// focus path, then the app's own handlers), outside any window update.
#[cfg(test)]
pub(crate) fn appkit_enables(
    vcx: &mut gpui_kit::VisualTestContext,
    action: &dyn gpui_kit::Action,
) -> bool {
    vcx.update(|window, _| window.activate_window());
    vcx.cx.update(|cx| cx.is_action_available(action))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn titles(menu: &Menu) -> Vec<String> {
        menu.items
            .iter()
            .map(|i| match i {
                MenuItem::Separator => "—".to_string(),
                MenuItem::Action { name, .. } => name.to_string(),
                MenuItem::Submenu(m) => format!("{} ▸", m.name),
                MenuItem::SystemMenu(m) => format!("{} ▸", m.name),
            })
            .collect()
    }

    fn menu<'a>(menus: &'a [Menu], name: &str) -> &'a Menu {
        menus.iter().find(|m| m.name.as_ref() == name).unwrap()
    }

    fn submenu<'a>(menu: &'a Menu, name: &str) -> &'a Menu {
        menu.items
            .iter()
            .find_map(|i| match i {
                MenuItem::Submenu(m) if m.name.as_ref() == name => Some(m),
                _ => None,
            })
            .unwrap()
    }

    fn disabled(menu: &Menu, name: &str) -> bool {
        menu.items
            .iter()
            .find_map(|i| match i {
                MenuItem::Action {
                    name: n, disabled, ..
                } if n.as_ref() == name => Some(*disabled),
                _ => None,
            })
            .unwrap_or_else(|| panic!("no {name}"))
    }

    fn open_chat(folder: Option<&str>) -> MenuState {
        MenuState {
            chat: Some(ChatMenuState {
                pinned: true,
                archived: false,
                folder_id: folder.map(str::to_string),
                unread: false,
                // An Open WebUI chat's, as the core offers them.
                offered: conduit_protocol::ChatMenuAbilities {
                    share: true,
                    duplicate: false,
                    r#move: true,
                    mark_unread: true,
                    generate_title: true,
                    export: true,
                },
                branches: true,
            }),
            folders: vec![("f1".into(), "Garden".into()), ("f2".into(), "Work".into())],
            ..MenuState::default()
        }
    }

    /// Chat › Read Aloud follows the main window showing a chat, not the
    /// chat commands: a read-only chat, a temporary one and a Hermes
    /// session's are read too, as their answers' own Read Aloud does.
    #[test]
    fn read_aloud_follows_a_shown_chat_not_the_chat_commands() {
        let l = L10n::new("en");
        // A read-only chat: no chat commands, still read aloud.
        let read_only = build_menus(
            &l,
            &MenuState {
                read_aloud: true,
                ..MenuState::default()
            },
        );
        assert!(!disabled(menu(&read_only, "Chat"), "Read Aloud"));
        // No chat shown: nothing to read.
        let none = build_menus(&l, &MenuState::default());
        assert!(disabled(menu(&none, "Chat"), "Read Aloud"));
    }

    /// Chat › Ask Conduit follows a shown chat with a composer, not the
    /// chat commands: a temporary chat and a Hermes session's take it, as
    /// their answers' own Ask Conduit does, with no chat commands.
    #[test]
    fn ask_conduit_follows_a_chat_with_a_composer_not_the_chat_commands() {
        let l = L10n::new("en");
        let temporary = build_menus(
            &l,
            &MenuState {
                ask_conduit: true,
                ..MenuState::default()
            },
        );
        assert!(!disabled(menu(&temporary, "Chat"), "Ask Conduit"));
        assert!(disabled(menu(&temporary, "Chat"), "Rename…"));
        let no_composer = build_menus(&l, &open_chat(None));
        assert!(disabled(menu(&no_composer, "Chat"), "Ask Conduit"));
    }

    #[test]
    fn go_lists_back_forward_and_the_shown_sections_in_order() {
        let l = L10n::new("en");
        let none = build_menus(&l, &MenuState::default());
        // Moving focus between the window's areas is always there: the
        // keyboard's way out of the terminal, whose Tab is the shell's.
        let focus = ["Move Focus to Next Area", "Move Focus to Previous Area"];
        assert_eq!(
            titles(menu(&none, "Go")),
            ["Back", "Forward", "—", focus[0], focus[1]]
        );
        assert!(disabled(menu(&none, "Go"), "Back"));
        let state = MenuState {
            areas: vec![Area::Chats, Area::Notes, Area::Channels],
            can_go_back: true,
            ..MenuState::default()
        };
        let menus = build_menus(&l, &state);
        let go = menu(&menus, "Go");
        assert_eq!(
            titles(go),
            [
                "Back", "Forward", "—", "Chats", "Notes", "Channels", "—", focus[0], focus[1]
            ]
        );
        assert!(!disabled(go, "Back"));
        assert!(disabled(go, "Forward"));
        // Between View and Chat, as Finder's sits after View.
        let names: Vec<String> = menus.iter().map(|m| m.name.to_string()).collect();
        let at = |n: &str| names.iter().position(|m| m == n).unwrap();
        assert_eq!(at("Go"), at("View") + 1);
        assert_eq!(at("Chat"), at("Go") + 1);
    }

    #[test]
    fn view_names_what_the_sidebar_toggle_will_do() {
        let l = L10n::new("en");
        let shown = build_menus(&l, &MenuState::default());
        assert_eq!(titles(menu(&shown, "View"))[0], "Hide Sidebar");
        assert_eq!(
            titles(menu(&shown, "View")).last().map(String::as_str),
            Some("Enter Full Screen")
        );
        let hidden = build_menus(
            &l,
            &MenuState {
                sidebar_visible: false,
                full_screen: true,
                ..MenuState::default()
            },
        );
        assert_eq!(titles(menu(&hidden, "View"))[0], "Show Sidebar");
        assert_eq!(
            titles(menu(&hidden, "View")).last().map(String::as_str),
            Some("Exit Full Screen")
        );
    }

    #[test]
    fn every_bound_command_has_a_menu_item() {
        let l = L10n::new("en");
        let menus = build_menus(&l, &open_chat(None));
        assert_eq!(
            titles(menu(&menus, "File")),
            [
                "New Chat",
                "New Temporary Chat",
                "New Folder",
                "New Channel…",
                "—",
                "Close Window"
            ]
        );
        assert_eq!(
            titles(menu(&menus, "View")),
            [
                "Hide Sidebar",
                "—",
                "Search Chats and Commands…",
                "—",
                "Actual Size",
                "Zoom In",
                "Zoom Out",
                "—",
                "Enter Full Screen"
            ]
        );
        assert_eq!(
            titles(submenu(menu(&menus, "Edit"), "Find")),
            ["Find…", "Find Next", "Find Previous", "—", "Search Chats"]
        );
        let chat = titles(menu(&menus, "Chat"));
        for item in [
            "Choose a Model…",
            "Go to Message Field",
            "Regenerate",
            "Stop Generating",
            "Share Chat…",
        ] {
            assert!(chat.iter().any(|t| t == item), "{item} in {chat:?}");
        }
    }

    #[test]
    fn notes_add_new_note_and_a_format_menu() {
        let l = L10n::new("en");
        let state = MenuState {
            areas: vec![Area::Chats, Area::Notes],
            ..MenuState::default()
        };
        let menus = build_menus(&l, &state);
        assert_eq!(
            titles(menu(&menus, "File"))[..4],
            ["New Chat", "New Temporary Chat", "New Note", "New Folder"]
        );
        let names: Vec<String> = menus.iter().map(|m| m.name.to_string()).collect();
        let edit = names.iter().position(|n| n == "Edit").unwrap();
        assert_eq!(names[edit + 1], "Format");
        let format = titles(menu(&menus, "Format"));
        for item in [
            "Title",
            "Bold",
            "Add Link…",
            "Checklist",
            "Mark as Checked",
            "Code Block",
        ] {
            assert!(format.iter().any(|t| t == item), "{item} in {format:?}");
        }
        // Without notes, neither.
        let none = build_menus(&l, &MenuState::default());
        assert!(none.iter().all(|m| m.name.as_ref() != "Format"));
    }

    #[test]
    fn the_chat_menu_follows_the_open_chat() {
        let l = L10n::new("en");
        let none = build_menus(&l, &MenuState::default());
        let chat_menu = menu(&none, "Chat");
        // Every item that changes the chat is off without one, and the
        // settings sheets while there is nothing to show in them.
        for name in [
            "Rename…",
            "Delete…",
            "Regenerate",
            "Share Chat…",
            "Pin",
            "Ask Conduit",
            "Chat Settings…",
            "Tool Settings…",
            "Mark as Unread",
            "Generate Title",
            "Show Branches…",
            "Save Chat",
        ] {
            assert!(disabled(chat_menu, name), "{name}");
        }
        // A stored chat: nothing to save.
        assert!(disabled(
            menu(&build_menus(&l, &open_chat(None)), "Chat"),
            "Save Chat"
        ));
        let offered = build_menus(
            &l,
            &MenuState {
                chat_settings: true,
                tool_settings: true,
                save_chat: true,
                ..open_chat(None)
            },
        );
        assert!(!disabled(menu(&offered, "Chat"), "Chat Settings…"));
        assert!(!disabled(menu(&offered, "Chat"), "Tool Settings…"));
        assert!(!disabled(menu(&offered, "Chat"), "Save Chat"));
        // Export, as Move to, is told to AppKit too: off without a chat
        // the server holds.
        assert!(export_disabled(&MenuState::default()));
        assert!(!export_disabled(&open_chat(None)));
        // Move to too (AppKit is told again after the bar is installed,
        // since it enables any item holding a submenu).
        assert!(move_to_disabled(&MenuState::default()));
        assert!(submenu(chat_menu, "Move to").disabled);
        assert!(!move_to_disabled(&open_chat(None)));
        let no_folders = MenuState {
            folders: vec![],
            ..open_chat(None)
        };
        assert!(move_to_disabled(&no_folders));
        // Previous and Next Chat work from a new chat too (the first or
        // the last chat).
        assert!(!disabled(chat_menu, "Next Chat"));
        assert!(!disabled(chat_menu, "Previous Chat"));
        let filed = build_menus(&l, &open_chat(Some("f1")));
        let items = titles(menu(&filed, "Chat"));
        assert_eq!(
            items,
            [
                "Unpin",
                "Mark as Unread",
                "Rename…",
                "Generate Title",
                "Share Chat…",
                "Export Chat ▸",
                "Move to ▸",
                "Remove from Folder",
                "Archive",
                "—",
                "Chat Settings…",
                "Tool Settings…",
                "Show Branches…",
                "Save Chat",
                "—",
                "Delete…",
                "—",
                "Previous Chat",
                "Next Chat",
                "—",
                "Choose a Model…",
                "Go to Message Field",
                "Expand Editor",
                "Start Dictation",
                "Ask Conduit",
                "—",
                "Regenerate",
                "Stop Generating",
                "—",
                "Read Aloud",
                "Stop Speaking",
                "Start Voice Call",
                "—",
                "Copy Last Answer",
                "Copy Last Code Block"
            ]
        );
        // While dictating, the same item stops it.
        let dictating = build_menus(
            &l,
            &MenuState {
                dictating: true,
                ..open_chat(None)
            },
        );
        assert!(titles(menu(&dictating, "Chat")).contains(&"Stop Dictation".to_string()));
        // A call on: the same item ends it.
        let calling = build_menus(
            &l,
            &MenuState {
                in_call: true,
                ..open_chat(None)
            },
        );
        assert!(titles(menu(&calling, "Chat")).contains(&"End Voice Call".to_string()));
        assert!(titles(menu(&dictating, "Chat")).contains(&"Start Voice Call".to_string()));
        // Start Voice Call as the composer's call button: only when the core
        // admits a call; End Voice Call always.
        assert!(disabled(menu(&dictating, "Chat"), "Start Voice Call"));
        let ready = build_menus(
            &l,
            &MenuState {
                call_ready: true,
                ..open_chat(None)
            },
        );
        assert!(!disabled(menu(&ready, "Chat"), "Start Voice Call"));
        assert!(!disabled(menu(&calling, "Chat"), "End Voice Call"));
        let move_to = submenu(menu(&filed, "Chat"), "Move to");
        assert_eq!(titles(move_to), ["Garden", "Work"]);
        assert!(move_to.items[0].is_checked());
        assert!(!move_to.items[1].is_checked());
        // Not in a folder: nothing to remove it from.
        let loose = build_menus(&l, &open_chat(None));
        assert!(
            !titles(menu(&loose, "Chat"))
                .iter()
                .any(|t| t == "Remove from Folder")
        );
        // Without a server to hold the link, Share Chat is off.
        let mut local = open_chat(None);
        local.chat.as_mut().unwrap().offered.share = false;
        assert!(disabled(
            menu(&build_menus(&l, &local), "Chat"),
            "Share Chat…"
        ));
        // A Hermes session with a context window: Context & Usage… before
        // Delete…, as an ordinary chat's sheets are.
        let hermes = build_menus(
            &l,
            &MenuState {
                hermes: Some(conduit_protocol::HermesSessionDto {
                    id: "s1".into(),
                    chat_id: "local:hermes_s1".into(),
                    title: "Pond plants".into(),
                    preview: None,
                    updated_at_ms: None,
                    pinned: false,
                    archived: false,
                    hidden: false,
                    source: None,
                    running: false,
                }),
                hermes_context: true,
                ..MenuState::default()
            },
        );
        let items = titles(menu(&hermes, "Chat"));
        let context = items.iter().position(|t| t == "Context & Usage…");
        let delete = items.iter().position(|t| t == "Delete…");
        assert!(
            context.is_some_and(|c| delete.is_some_and(|d| c < d)),
            "{items:?}"
        );
        assert!(!disabled(menu(&hermes, "Chat"), "Context & Usage…"));
    }

    #[test]
    fn a_hermes_sessions_chat_menu_has_its_commands_and_context_before_delete() {
        let l = L10n::new("en");
        let session: conduit_protocol::HermesSessionDto = serde_json::from_value(
            serde_json::json!({"id": "s1", "chatId": "local:hermes_s1", "title": "Tide tables"}),
        )
        .expect("a session");
        let state = MenuState {
            hermes: Some(session),
            hermes_context: true,
            ..open_chat(None)
        };
        let items = titles(menu(&build_menus(&l, &state), "Chat"));
        let head: Vec<&str> = items
            .iter()
            .take_while(|t| *t != "Previous Chat")
            .map(String::as_str)
            .collect();
        assert_eq!(
            head,
            [
                "Pin",
                "Rename…",
                "Fork",
                "Archive",
                "Hide",
                "—",
                "Context & Usage…",
                "—",
                "Delete…",
                "—"
            ]
        );
        // Without a context window to read, Delete… stands alone.
        let state = MenuState {
            hermes_context: false,
            ..state
        };
        let items = titles(menu(&build_menus(&l, &state), "Chat"));
        assert!(!items.iter().any(|t| t == "Context & Usage…"));
    }

    #[test]
    fn only_a_librechat_chat_offers_duplicate() {
        let l = L10n::new("en");
        let owui = titles(menu(&build_menus(&l, &open_chat(None)), "Chat"));
        assert!(!owui.iter().any(|t| t == "Duplicate Chat"));
        let mut lc = open_chat(None);
        if let Some(chat) = lc.chat.as_mut() {
            // A LibreChat chat's, as the core offers them.
            chat.offered = conduit_protocol::ChatMenuAbilities {
                share: true,
                duplicate: true,
                ..Default::default()
            };
        }
        lc.folders.clear();
        let names = titles(menu(&build_menus(&l, &lc), "Chat"));
        let at = |t: &str| names.iter().position(|n| n == t);
        // After Rename…, before Share Chat…, as on the phone.
        assert!(at("Duplicate Chat").is_some());
        assert!(at("Rename…") < at("Duplicate Chat"));
        assert!(at("Duplicate Chat") < at("Share Chat…"));
    }

    #[test]
    fn chat_commands_keep_one_order() {
        // The order is total and every command has a place in it.
        let ranks: Vec<usize> = CHAT_COMMAND_ORDER.iter().map(|s| s.rank()).collect();
        assert_eq!(ranks, (0..CHAT_COMMAND_ORDER.len()).collect::<Vec<_>>());
        for command in [
            ChatCommand::Pin,
            ChatCommand::Unpin,
            ChatCommand::Rename,
            ChatCommand::Duplicate,
            ChatCommand::MarkUnread,
            ChatCommand::MarkRead,
            ChatCommand::GenerateTitle,
            ChatCommand::Export(conduit_protocol::ChatExportFormat::Json),
            ChatCommand::Share,
            ChatCommand::MoveTo("f".into()),
            ChatCommand::RemoveFromFolder,
            ChatCommand::Archive,
            ChatCommand::Unarchive,
            ChatCommand::Select,
            ChatCommand::Delete,
        ] {
            assert!(ChatCommandSlot::of(&command).rank() < CHAT_COMMAND_ORDER.len());
        }
        // The menu bar's chat commands come in that order (a subset of it).
        let l = L10n::new("en");
        let filed = build_menus(&l, &open_chat(Some("f1")));
        let names = titles(menu(&filed, "Chat"));
        let slot = |t: &str| match t {
            "Pin" | "Unpin" => Some(ChatCommandSlot::Pin),
            "Mark as Unread" | "Mark as Read" => Some(ChatCommandSlot::MarkUnread),
            "Rename…" => Some(ChatCommandSlot::Rename),
            "Duplicate Chat" => Some(ChatCommandSlot::Duplicate),
            "Generate Title" => Some(ChatCommandSlot::GenerateTitle),
            "Share Chat…" => Some(ChatCommandSlot::Share),
            "Export Chat ▸" => Some(ChatCommandSlot::Export),
            "Move to ▸" => Some(ChatCommandSlot::MoveTo),
            "Remove from Folder" => Some(ChatCommandSlot::RemoveFromFolder),
            "Archive" | "Unarchive" => Some(ChatCommandSlot::Archive),
            "Delete…" => Some(ChatCommandSlot::Delete),
            _ => None,
        };
        let order: Vec<usize> = names
            .iter()
            .filter_map(|t| slot(t))
            .map(|s| s.rank())
            .collect();
        assert_eq!(order.len(), 10);
        assert!(order.windows(2).all(|w| w[0] < w[1]), "{names:?}");
    }

    #[test]
    fn menus_end_in_an_ellipsis_only_when_they_ask_for_more() {
        let l = L10n::new("en");
        let menus = build_menus(&l, &open_chat(None));
        let find = titles(submenu(menu(&menus, "Edit"), "Find"));
        assert_eq!(find[0], "Find…");
        let help = titles(menu(&menus, "Help"));
        assert_eq!(help[1], "Keyboard Shortcuts");
        // No item uses three dots for an ellipsis.
        for m in &menus {
            for t in titles(m) {
                assert!(!t.contains("..."), "{t}");
            }
        }
    }

    #[test]
    fn zoom_steps_a_point_within_the_text_size_bounds() {
        let mut a = Appearance::default();
        let start = a.effective_text_size();
        assert_eq!(
            ZoomState::of(&a),
            ZoomState {
                can_zoom_in: true,
                can_zoom_out: true,
                can_reset: false
            }
        );
        assert!(zoom(&mut a, ZoomStep::In));
        assert_eq!(a.effective_text_size(), start + 1.);
        assert!(ZoomState::of(&a).can_reset);
        assert!(zoom(&mut a, ZoomStep::Out));
        assert!(zoom(&mut a, ZoomStep::Out));
        assert_eq!(a.effective_text_size(), start - 1.);
        // Actual Size follows the density again.
        assert!(zoom(&mut a, ZoomStep::Actual));
        assert_eq!(a.text_size, None);
        assert!(!zoom(&mut a, ZoomStep::Actual), "already actual");
        // It stops at the bounds, and the menu greys the item out there.
        for _ in 0..40 {
            zoom(&mut a, ZoomStep::In);
        }
        assert_eq!(a.effective_text_size(), TEXT_SIZE_MAX);
        assert!(!zoom(&mut a, ZoomStep::In));
        assert!(!ZoomState::of(&a).can_zoom_in);
        for _ in 0..40 {
            zoom(&mut a, ZoomStep::Out);
        }
        assert_eq!(a.effective_text_size(), TEXT_SIZE_MIN);
        assert!(!ZoomState::of(&a).can_zoom_out);
        let l = L10n::new("en");
        let menus = build_menus(
            &l,
            &MenuState {
                zoom: ZoomState::of(&a),
                ..MenuState::default()
            },
        );
        let view = menu(&menus, "View");
        assert!(disabled(view, "Zoom Out"));
        assert!(!disabled(view, "Zoom In"));
        assert!(!disabled(view, "Actual Size"));
    }

    #[cfg(target_os = "macos")]
    #[gpui_kit::test]
    fn find_and_zoom_chords_are_bound_as_macos_writes_them(cx: &mut gpui_kit::TestAppContext) {
        cx.update(|cx| {
            cx.set_global(L10n::new("en"));
            bind_keys(&Keymap::default(), cx);
            let first = |action: &dyn gpui_kit::Action| -> String {
                cx.key_bindings()
                    .borrow()
                    .bindings_for_action(action)
                    .find(|b| b.predicate().is_none())
                    .map(|b| {
                        b.keystrokes()
                            .iter()
                            .map(|k| k.unparse(gpui_kit::OperatingSystem::Mac))
                            .collect::<Vec<_>>()
                            .join(" ")
                    })
                    .unwrap_or_default()
            };
            assert_eq!(first(&FindInChat), "cmd-f");
            assert_eq!(first(&FindNext), "cmd-g");
            assert_eq!(first(&FindPrevious), "cmd-shift-g");
            assert_eq!(first(&FindChats), "alt-cmd-f");
            assert_eq!(first(&NewTemporaryChat), "cmd-shift-n");
            assert_eq!(first(&NextChat), "ctrl-tab");
            assert_eq!(first(&PreviousChat), "ctrl-shift-tab");
            assert_eq!(first(&RegenerateLastAnswer), "cmd-r");
            assert_eq!(first(&ActualSize), "cmd-0");
            assert_eq!(first(&ZoomIn), "cmd-+");
            assert_eq!(first(&ZoomOut), "cmd--");
            // The rebindable ones label their menu items too.
            assert_eq!(first(&OpenPalette), "cmd-k");
            assert_eq!(first(&FocusModelPicker), "cmd-shift-m");
            assert_eq!(first(&FocusComposer), "shift-escape");
        });
    }

    /// The action a fixed chord fires.
    #[cfg(target_os = "macos")]
    fn fixed_action(command: crate::keymap::FixedCommand) -> Box<dyn gpui_kit::Action> {
        use crate::keymap::FixedCommand as F;
        match command {
            F::NewTemporaryChat => Box::new(NewTemporaryChat),
            F::SearchChats => Box::new(FindChats),
            F::DeleteChat => Box::new(DeleteChat),
            F::NextChat => Box::new(NextChat),
            F::PreviousChat => Box::new(PreviousChat),
            F::Regenerate => Box::new(RegenerateLastAnswer),
            F::StopSpeaking => Box::new(crate::actions::StopSpeaking),
            F::ExpandEditor => Box::new(crate::actions::ExpandEditor),
            F::AskConduit => Box::new(crate::actions::AskConduit),
            F::ChatSettings => Box::new(crate::actions::ChatSettings),
            F::FindInChat => Box::new(FindInChat),
            F::FindNext => Box::new(FindNext),
            F::FindPrevious => Box::new(FindPrevious),
            F::ActualSize => Box::new(ActualSize),
            F::ZoomIn => Box::new(ZoomIn),
            F::ZoomOut => Box::new(ZoomOut),
            F::Settings => Box::new(OpenSettings),
            F::Quit => Box::new(Quit),
            F::Hide => Box::new(Hide),
            F::HideOthers => Box::new(HideOthers),
            F::CloseWindow => Box::new(CloseWindow),
            F::Minimize => Box::new(Minimize),
            F::FullScreen => Box::new(ToggleFullScreen),
            F::Back => Box::new(GoBack),
            F::Forward => Box::new(GoForward),
            F::GoToSection(n) => Box::new(GoToSection {
                index: usize::from(n),
            }),
            F::NextArea => Box::new(crate::actions::MoveFocusToNextArea),
            F::PreviousArea => Box::new(crate::actions::MoveFocusToPreviousArea),
        }
    }

    /// Settings › Keyboard's Notes keys are the ones Notes binds.
    #[cfg(target_os = "macos")]
    #[gpui_kit::test]
    fn the_notes_chords_settings_shows_are_bound(cx: &mut gpui_kit::TestAppContext) {
        use crate::keymap::AreaKey as K;
        use crate::views::notes::editor as e;
        cx.update(|cx| {
            cx.set_global(L10n::new("en"));
            bind_keys(&Keymap::default(), cx);
            for (key, stroke) in crate::keymap::area_shortcuts() {
                let action: Box<dyn gpui_kit::Action> = match key {
                    K::NewNote => Box::new(crate::views::notes::NewNote),
                    K::Title => Box::new(e::Title),
                    K::Heading => Box::new(e::Heading),
                    K::Subheading => Box::new(e::Subheading),
                    K::Body => Box::new(e::Body),
                    K::Bold => Box::new(e::ToggleBold),
                    K::Italic => Box::new(e::ToggleItalic),
                    K::Strikethrough => Box::new(e::ToggleStrike),
                    K::Code => Box::new(e::ToggleCode),
                    K::Link => Box::new(e::AddLink),
                    K::BulletedList => Box::new(e::BulletList),
                    K::NumberedList => Box::new(e::NumberedList),
                    K::Checklist => Box::new(e::Checklist),
                    K::MarkChecked => Box::new(e::ToggleChecked),
                    K::Quote => Box::new(e::QuoteBlock),
                    K::CodeBlock => Box::new(e::CodeBlock),
                    K::TerminalFind => Box::new(FindInChat),
                    K::TerminalClearScrollback => {
                        Box::new(crate::views::terminal::console::ClearScrollback)
                    }
                    // The Workspace editor, the Calendar, Scheduled Tasks,
                    // a room's field, the scheduled agent sheet and a
                    // terminal's PDF window take theirs in their own key
                    // handlers; the console answers the Edit menu's Copy,
                    // Paste and Select All.
                    K::SaveWorkspaceItem
                    | K::SavePdf
                    | K::CalendarEarlier
                    | K::CalendarLater
                    | K::CalendarToday
                    | K::DeleteCalendarItem
                    | K::SaveCalendarEvent
                    | K::DeleteScheduledTask
                    | K::SaveScheduledTask
                    | K::TerminalCopy
                    | K::TerminalPaste
                    | K::TerminalSelectAll
                    | K::SendInRoom
                    | K::SaveHermesJob => continue,
                };
                let bound = cx
                    .key_bindings()
                    .borrow()
                    .bindings_for_action(action.as_ref())
                    .any(|b| {
                        b.keystrokes().len() == 1
                            && crate::keymap::from_gpui(b.keystrokes()[0].inner()).as_ref()
                                == Some(&stroke)
                    });
                assert!(bound, "{key:?} is not bound to {stroke:?}");
            }
        });
    }

    /// In Notes, ⌘N is New Note and the editor's ⌘K is Add Link, though
    /// the shortcut table gives both chords to New Chat and the palette
    /// everywhere else.
    #[cfg(target_os = "macos")]
    #[gpui_kit::test]
    fn notes_keys_win_over_the_shortcut_table(cx: &mut gpui_kit::TestAppContext) {
        cx.update(|cx| {
            cx.set_global(L10n::new("en"));
            bind_keys(&Keymap::default(), cx);
            let winner = |stroke: &'static str, stack: &[&str]| -> &'static str {
                let input = [gpui_kit::Keystroke::parse(stroke).unwrap()];
                let contexts: Vec<gpui_kit::KeyContext> = stack
                    .iter()
                    .map(|c| gpui_kit::KeyContext::parse(c).unwrap())
                    .collect();
                let (bindings, _) = cx
                    .key_bindings()
                    .borrow()
                    .bindings_for_input(&input, &contexts);
                bindings.first().map_or("", |b| b.action().name())
            };
            use crate::views::notes::{editor, list, pane};
            use gpui_kit::Action as _;
            let new_note = crate::views::notes::NewNote.name();
            assert_eq!(
                winner("cmd-n", &["Window", list::NOTES_LIST_CONTEXT]),
                new_note
            );
            assert_eq!(
                winner("cmd-n", &["Window", pane::NOTE_PANE_CONTEXT]),
                new_note
            );
            assert_eq!(
                winner(
                    "cmd-k",
                    &["Window", pane::NOTE_PANE_CONTEXT, editor::EDITOR_CONTEXT]
                ),
                editor::AddLink.name()
            );
            // Elsewhere the table's own.
            assert_eq!(winner("cmd-n", &["Window"]), NewChat.name());
        });
    }

    /// Settings › Keyboard's fixed chords are the ones bound (it shows
    /// them, and refuses them to other commands).
    #[cfg(target_os = "macos")]
    #[gpui_kit::test]
    fn the_fixed_chords_settings_shows_are_bound(cx: &mut gpui_kit::TestAppContext) {
        cx.update(|cx| {
            cx.set_global(L10n::new("en"));
            bind_keys(&Keymap::default(), cx);
            for (command, stroke) in crate::keymap::fixed_shortcuts() {
                let action = fixed_action(command);
                let bound = cx
                    .key_bindings()
                    .borrow()
                    .bindings_for_action(action.as_ref())
                    .any(|b| {
                        b.keystrokes().len() == 1
                            && crate::keymap::from_gpui(b.keystrokes()[0].inner()).as_ref()
                                == Some(&stroke)
                    });
                assert!(bound, "{command:?} is not bound to {stroke:?}");
            }
        });
    }

    #[test]
    fn tooltips_learn_the_bound_chords() {
        let keymap = Keymap::default();
        let hints = shortcut_hints(&keymap, Some(&KeyStroke::new(" ").primary().shift()));
        if cfg!(target_os = "macos") {
            assert_eq!(hints.new_chat.as_deref(), Some("⌘N"));
            assert_eq!(hints.toggle_sidebar.as_deref(), Some("⌃⌘S"));
            assert_eq!(hints.settings.as_deref(), Some("⌘,"));
            // The sidebar's search field: ⌥⌘F, since ⌘F finds in the chat.
            assert_eq!(hints.find.as_deref(), Some("⌥⌘F"));
            assert_eq!(hints.quick_ask.as_deref(), Some("⇧⌘Space"));
            assert_eq!(hints.stop.as_deref(), Some("⎋"));
            // Every icon control whose command has a chord teaches it.
            assert_eq!(hints.temporary_chat.as_deref(), Some("⇧⌘N"));
            assert_eq!(hints.regenerate.as_deref(), Some("⌘R"));
            assert_eq!(hints.copy_last_reply.as_deref(), Some("⇧⌘C"));
            assert_eq!(hints.model_picker.as_deref(), Some("⇧⌘M"));
        }
        // A rebound shortcut is what the tooltip teaches.
        let mut k = Keymap::default();
        k.set(ShortcutAction::NewChat, KeyStroke::new("j").primary())
            .unwrap();
        assert_eq!(
            shortcut_hints(&k, None).new_chat.as_deref(),
            Some(describe(&KeyStroke::new("j").primary(), cfg!(target_os = "macos")).as_str())
        );
        assert!(shortcut_hints(&k, None).quick_ask.is_none());
    }
}
