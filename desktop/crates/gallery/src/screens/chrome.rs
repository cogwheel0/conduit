//! The main window off the Mac (D13): Windows' ☰ with caption buttons, and
//! GNOME's header bars with a ☰ primary menu, drawn by the app's own chrome
//! components (`conduit_components::chrome`) on synthetic data.
//!
//! ☰ opens through its real path: its items are greyed by what answers
//! their actions in this window (the screen answers most of them; Back,
//! Forward, Actual Size and the editing items have nothing to act on), and
//! the highlighted row is where a pointer hovered.

use std::rc::Rc;
use std::time::Duration;

use conduit_components::ActiveConduitTheme;
use conduit_components::assets::IconName;
use conduit_components::chrome::menu::{ChromeMenuItem, ZoomPart, ZoomRow};
use conduit_components::chrome::{
    ActiveChrome, ButtonLayout, Chrome, ChromeStyle, ClientFrame, ControlLabels, Header, MainMenu,
    MenuItems,
};
use conduit_components::views::composer::{Composer, ComposerToggle};
use conduit_components::views::focus::ShortcutHints;
use conduit_components::views::kit::IconButton;
use conduit_components::views::message::{AssistantMessageView, UserMessageView};
use conduit_components::views::model::{SidebarModel, UserMessage};
use conduit_components::views::shell::{ChatColumn, ChatToolbar, MainWindowFrame};
use conduit_components::views::sidebar::Sidebar;
use gpui_kit::prelude::*;
use gpui_kit::{Action, Context, Decorations, Entity, SharedString, Tiling, Window, actions, div};

use crate::fake;

actions!(
    gallery_menu,
    [
        NewChat,
        NewTemporaryChat,
        NewFolder,
        NewChannel,
        CloseWindow,
        Undo,
        Redo,
        Cut,
        Copy,
        Paste,
        SelectAll,
        FindInChat,
        FindNext,
        FindPrevious,
        SearchChats,
        ToggleSidebar,
        OpenPalette,
        ActualSize,
        ZoomIn,
        ZoomOut,
        ToggleFullScreen,
        GoBack,
        GoForward,
        GoChats,
        GoNotes,
        GoWorkspace,
        NextArea,
        PreviousArea,
        Pin,
        Rename,
        Archive,
        Delete,
        ChooseModel,
        Regenerate,
        ReadAloud,
        QuickAsk,
        OpenSettings,
        Help,
        Shortcuts,
        CheckForUpdates,
        About,
        Exit,
    ]
);

/// One chrome screen.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct ChromeShot {
    pub style: ChromeStyle,
    pub menu_open: bool,
    pub sidebar: bool,
    /// GNOME's controls at the start (`close,minimize,maximize:`).
    pub start_controls: bool,
}

impl ChromeShot {
    /// The shadow GNOME's client-side frame draws around the window.
    pub fn inset(self) -> f32 {
        match self.style {
            ChromeStyle::Windows => 0.,
            ChromeStyle::Gnome => conduit_components::chrome::controls::SHADOW,
        }
    }

    fn buttons(self) -> ButtonLayout {
        match self.style {
            ChromeStyle::Windows => ButtonLayout::windows(),
            ChromeStyle::Gnome if self.start_controls => {
                ButtonLayout::parse("close,minimize,maximize:appmenu")
            }
            // Ubuntu's layout, as the design pass mocked it.
            ChromeStyle::Gnome => ButtonLayout::parse("appmenu:minimize,maximize,close"),
        }
    }
}

fn act(label: &str, action: impl Action, shortcut: Option<&str>) -> ChromeMenuItem {
    ChromeMenuItem::Action {
        label: label.to_string().into(),
        action: Box::new(action),
        shortcut: shortcut.map(|s| s.to_string().into()),
        checked: false,
        disabled: false,
    }
}

/// ☰ as `menus::primary_menu` builds it for the Windows build, with the
/// chords `describe` writes off the Mac.
fn windows_items() -> Vec<ChromeMenuItem> {
    use ChromeMenuItem::Separator as Sep;
    vec![
        act("New Chat", NewChat, Some("Ctrl+N")),
        act("New Temporary Chat", NewTemporaryChat, Some("Ctrl+Shift+N")),
        act("New Folder", NewFolder, None),
        act("New Channel\u{2026}", NewChannel, None),
        Sep,
        act("Close Window", CloseWindow, Some("Ctrl+W")),
        Sep,
        ChromeMenuItem::submenu(
            "Edit",
            vec![
                act("Undo", Undo, Some("Ctrl+Z")),
                act("Redo", Redo, Some("Ctrl+Shift+Z")),
                Sep,
                act("Cut", Cut, Some("Ctrl+X")),
                act("Copy", Copy, Some("Ctrl+C")),
                act("Paste", Paste, Some("Ctrl+V")),
                act("Select All", SelectAll, Some("Ctrl+A")),
                Sep,
                ChromeMenuItem::submenu(
                    "Find",
                    vec![
                        act("Find\u{2026}", FindInChat, Some("Ctrl+F")),
                        act("Find Next", FindNext, Some("Ctrl+G")),
                        act("Find Previous", FindPrevious, Some("Ctrl+Shift+G")),
                        Sep,
                        act("Search Chats", SearchChats, Some("Ctrl+Alt+F")),
                    ],
                ),
            ],
        ),
        ChromeMenuItem::submenu(
            "View",
            vec![
                act("Hide Sidebar", ToggleSidebar, Some("Ctrl+S")),
                Sep,
                act(
                    "Search Chats and Commands\u{2026}",
                    OpenPalette,
                    Some("Ctrl+K"),
                ),
                Sep,
                act("Actual Size", ActualSize, Some("Ctrl+0")),
                act("Zoom In", ZoomIn, Some("Ctrl++")),
                act("Zoom Out", ZoomOut, Some("Ctrl+-")),
                Sep,
                act("Enter Full Screen", ToggleFullScreen, Some("Ctrl+F")),
            ],
        ),
        ChromeMenuItem::submenu(
            "Go",
            vec![
                act("Back", GoBack, Some("Ctrl+[")),
                act("Forward", GoForward, Some("Ctrl+]")),
                Sep,
                act("Chats", GoChats, Some("Ctrl+1")),
                act("Notes", GoNotes, Some("Ctrl+2")),
                act("Workspace", GoWorkspace, Some("Ctrl+3")),
                Sep,
                act("Move Focus to Next Area", NextArea, None),
                act("Move Focus to Previous Area", PreviousArea, None),
            ],
        ),
        ChromeMenuItem::submenu(
            "Chat",
            vec![
                act("Unpin", Pin, None),
                act("Rename\u{2026}", Rename, None),
                act("Archive", Archive, None),
                Sep,
                act("Delete\u{2026}", Delete, None),
                Sep,
                act("Choose Model\u{2026}", ChooseModel, None),
                act("Regenerate", Regenerate, Some("Ctrl+R")),
                act("Read Aloud", ReadAloud, None),
            ],
        ),
        Sep,
        act("Quick Ask", QuickAsk, Some("Ctrl+Shift+Space")),
        act("Settings\u{2026}", OpenSettings, Some("Ctrl+,")),
        ChromeMenuItem::submenu(
            "Help",
            vec![
                act("Conduit Help", Help, None),
                act("Keyboard Shortcuts", Shortcuts, None),
                Sep,
                act("Check for Updates\u{2026}", CheckForUpdates, None),
                act("About Conduit", About, None),
            ],
        ),
        Sep,
        act("Exit", Exit, None),
    ]
}

/// GNOME's primary menu, as `menus::primary_menu` builds it.
fn gnome_items() -> Vec<ChromeMenuItem> {
    use ChromeMenuItem::Separator as Sep;
    vec![
        act("New Temporary Chat", NewTemporaryChat, Some("Ctrl+Shift+N")),
        act("New Folder", NewFolder, None),
        act("New Channel\u{2026}", NewChannel, None),
        Sep,
        ChromeMenuItem::Zoom(ZoomRow {
            level: "100%".into(),
            out: ZoomPart {
                label: "Zoom Out".into(),
                action: Box::new(ZoomOut),
                disabled: false,
            },
            reset: ZoomPart {
                label: "Actual Size".into(),
                action: Box::new(ActualSize),
                disabled: false,
            },
            zoom_in: ZoomPart {
                label: "Zoom In".into(),
                action: Box::new(ZoomIn),
                disabled: false,
            },
        }),
        Sep,
        act("Preferences", OpenSettings, Some("Ctrl+,")),
        act("Keyboard Shortcuts", Shortcuts, None),
        act("Help", Help, None),
        act("About Conduit", About, None),
    ]
}

/// Answers the items a real main window answers here, so the rest grey.
fn answer<E: InteractiveElement>(el: E) -> E {
    macro_rules! on {
        ($el:expr, $($a:ident),*) => { $el$(.on_action(|_: &$a, _, _| {}))* };
    }
    on!(
        el,
        NewChat,
        NewTemporaryChat,
        NewFolder,
        NewChannel,
        CloseWindow,
        Copy,
        SelectAll,
        FindInChat,
        FindNext,
        FindPrevious,
        SearchChats,
        ToggleSidebar,
        OpenPalette,
        ZoomIn,
        ZoomOut,
        ToggleFullScreen,
        GoChats,
        GoNotes,
        GoWorkspace,
        NextArea,
        PreviousArea,
        Pin,
        Rename,
        Archive,
        Delete,
        ChooseModel,
        Regenerate,
        ReadAloud,
        QuickAsk,
        OpenSettings,
        Help,
        Shortcuts,
        CheckForUpdates,
        About,
        Exit
    )
}

pub struct ChromeScreen {
    shot: ChromeShot,
    menu: Entity<MainMenu>,
    sidebar: SidebarModel,
    user: UserMessage,
    answer: Entity<AssistantMessageView>,
    composer: Entity<Composer>,
    focus: gpui_kit::FocusHandle,
}

impl ChromeScreen {
    pub fn new(shot: ChromeShot, window: &mut Window, cx: &mut Context<Self>) -> Self {
        let composer = cx.new(|cx| {
            let mut c = Composer::new("Message Conduit", fake::MODEL, window, cx);
            c.toggles = vec![ComposerToggle {
                label: "Web search".into(),
                icon: IconName::Globe,
                on: false,
            }];
            c
        });
        let items: MenuItems = match shot.style {
            ChromeStyle::Windows => Rc::new(|_, _| windows_items()),
            ChromeStyle::Gnome => Rc::new(|_, _| gnome_items()),
        };
        let menu = cx.new(|cx| MainMenu::new(shot.style, "Main Menu", items, window, cx));
        let mut msg = fake::orbit_streaming();
        msg.streaming = false;
        msg.show_actions = true;
        let answer = cx.new(|cx| AssistantMessageView::new(msg, cx));
        let focus = cx.focus_handle();
        window.focus(&focus, cx);
        // The chords the app's tooltips and search field show off the Mac.
        cx.set_global(ShortcutHints {
            new_chat: Some("Ctrl+N".into()),
            toggle_sidebar: Some("Ctrl+S".into()),
            settings: Some("Ctrl+,".into()),
            palette: Some("Ctrl+K".into()),
            find: Some("Ctrl+Alt+F".into()),
            ..ShortcutHints::default()
        });
        if shot.menu_open {
            // Opened once the window is up and active: greying asks the
            // active window what answers each item.
            let open = menu.clone();
            cx.spawn_in(window, async move |_, cx| {
                cx.background_executor()
                    .timer(Duration::from_millis(350))
                    .await;
                let _ = open.update_in(cx, |m, window, cx| m.open(false, window, cx));
                cx.background_executor()
                    .timer(Duration::from_millis(150))
                    .await;
                // The pointer rests on View, as the design pass showed it.
                open.update(cx, |m, cx| match m.style() {
                    ChromeStyle::Windows => {
                        m.hover(0, 8, cx);
                        m.hover(1, 2, cx);
                    }
                    ChromeStyle::Gnome => m.hover(0, 6, cx),
                });
            })
            .detach();
        }
        Self {
            shot,
            menu,
            sidebar: fake::sidebar(Some("c-orbit")),
            user: fake::orbit_user(),
            answer,
            composer,
            focus,
        }
    }

    fn chrome(&self) -> Chrome {
        Chrome {
            style: self.shot.style,
            buttons: self.shot.buttons(),
            decorations: Decorations::Client {
                tiling: Tiling::default(),
            },
            maximized: false,
            menu: self.menu.clone(),
            labels: ControlLabels {
                minimize: "Minimize".into(),
                maximize: "Maximize".into(),
                restore: match self.shot.style {
                    ChromeStyle::Windows => "Restore Down".into(),
                    ChromeStyle::Gnome => "Restore".into(),
                },
                close: "Close".into(),
            },
            title: "Conduit".into(),
            on_close: None,
        }
    }
}

impl Render for ChromeScreen {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let chrome = self.chrome();
        // As the main window does: the chrome is set before the content
        // that reads it draws.
        cx.set_global(ActiveChrome(Some(chrome.clone())));
        let t = cx.conduit().clone();
        let shown = self.shot.sidebar;
        let placement = chrome.placement(shown);
        let rooms = chrome.rooms(shown);
        let mut toolbar = ChatToolbar::new("Orbital period of a moon", fake::MODEL);
        // The toggle leads the content's header wherever the placement puts
        // it there (GNOME always; Windows without the sidebar).
        if placement.sidebar_toggle.0 == Header::Content {
            let label: SharedString = if shown {
                "Hide Sidebar".into()
            } else {
                "Show Sidebar".into()
            };
            toolbar = toolbar.leading(
                IconButton::new("toggle-sidebar-content", IconName::PanelLeft, label)
                    .size(30., 16.)
                    .round(),
            );
            if !shown {
                toolbar = toolbar.leading_reveal(rooms.start + 8., 1.);
            }
        }
        let column = ChatColumn::new(
            vec![
                UserMessageView::new(self.user.clone()).into_any_element(),
                self.answer.clone().into_any_element(),
            ],
            self.composer.clone(),
        );
        let mut frame = MainWindowFrame::new(
            div()
                .size_full()
                .flex()
                .flex_col()
                .child(toolbar)
                .child(column),
        )
        .sidebar_reveal(if shown { 1. } else { 0. });
        if shown {
            frame = frame.sidebar(Sidebar::new(self.sidebar.clone()));
        }
        let root = answer(
            div()
                .id("chrome-screen")
                .track_focus(&self.focus)
                .size_full()
                .text_color(t.roles.text),
        )
        .child(frame);
        ClientFrame::new(chrome.style, chrome.decorations, false, true, root)
    }
}
