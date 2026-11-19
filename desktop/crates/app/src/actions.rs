//! GPUI actions: the app menu's and the rebindable shortcuts'.

use gpui_kit::{Action, actions};

use crate::keymap::ShortcutAction;

actions!(
    conduit,
    [
        About,
        Quit,
        Hide,
        HideOthers,
        ShowAll,
        CloseWindow,
        Minimize,
        Zoom,
        ToggleFullScreen,
        BringAllToFront,
        OpenHelp,
        // The rebindable shortcuts (keymap.rs).
        NewChat,
        OpenPalette,
        FocusComposer,
        FocusModelPicker,
        StopGenerating,
        OpenSettings,
        ShowShortcuts,
        CopyLastResponse,
        CopyLastCodeBlock,
        AllowRequest,
        DenyRequest,
        Dictate,
        ToggleSidebar,
        ReadAloud,
        VoiceCall,
    ]
);

// Chat › Stop Speaking (⌘.): ends the reading, wherever it is.
actions!(conduit, [StopSpeaking]);

// The voice call's strip: Pause or Resume, Mute, Minimize or Expand, and
// the menu-bar item's Show Call.
actions!(
    conduit,
    [CallPause, CallMute, CallMinimize, ShowCall, EndCall]
);

// The ⌘K palette's "Choose model" command: opens the composer's model
// picker.
actions!(conduit, [ChooseModel]);

// The composer's larger editor (⇧⌘E), and Ask Conduit: the text selected in
// an answer, into the composer (⇧⌘A).
actions!(conduit, [ExpandEditor, AskConduit, CopySelection]);

// Chat › Chat Settings… (⌘I, as Get Info: on a folder selected in the
// sidebar it opens Folder Settings) and Tool Settings…: sheets on the main
// window.
actions!(conduit, [ChatSettings, ToolSettings]);

// Window › Quick Ask (also the global shortcut and the menu-bar item).
actions!(conduit, [ToggleQuickAsk]);

// The Dock icon's menu (`desktop::set_dock_menu`): the phone's home-screen
// quick actions, New Chat and Voice Call, and Quick Ask. Handled by the app
// (`desktop::install`), whichever window is in front, or none.
actions!(conduit, [DockNewChat, DockVoiceCall, DockQuickAsk]);

// Conduit › Check for Updates… (Sparkle; handled only when the build has
// an updater, so the item is disabled otherwise).
actions!(conduit, [CheckForUpdates]);

// Edit › Find › Search Chats (⌥⌘F, as Mail's Mailbox Search): the
// sidebar's search field, the sidebar shown first.
actions!(conduit, [FindChats]);

// Edit › Find: Find… (⌘F) opens the find bar over the open chat's
// transcript; Find Next (⌘G) and Find Previous (⇧⌘G) step through its
// matches.
actions!(conduit, [FindInChat, FindNext, FindPrevious]);

// File › New Temporary Chat (⇧⌘N, as Safari's New Private Window).
actions!(conduit, [NewTemporaryChat]);

// Tab and Shift-Tab in the chat pane: the messages' order, rows off screen
// included (`Transcript::tab`); elsewhere the window's own.
actions!(conduit, [FocusNextControl, FocusPreviousControl]);

// Go › Move Focus to Next Area (⌥⌘`) and Previous Area (⌥⌘~), as Xcode's,
// beside the system's ⌘` for the next window: the window's next or
// previous stop, as Tab and Shift-Tab, taken by the window before any view
// that keeps Tab for itself (the terminal's console, whose Tab is the
// shell's) can see it.
actions!(conduit, [MoveFocusToNextArea, MoveFocusToPreviousArea]);

// File › New Folder: a folder at the top of the sidebar's Folders, named in
// place (also the list's own right-click menu).
actions!(conduit, [NewFolder]);

// Chat › Previous Chat (⌃⇧⇥) and Next Chat (⌃⇥): the chat before or after
// the open one in the sidebar's order (wrapping), as ⌃⇥ steps through
// Safari's tabs.
actions!(conduit, [PreviousChat, NextChat]);

// View › Actual Size (⌘0), Zoom In (⌘+) and Zoom Out (⌘−): Settings ›
// Appearance › Text Size, a point at a time.
actions!(conduit, [ActualSize, ZoomIn, ZoomOut]);

// The Chat menu, on the open chat (disabled with none open): pin, rename,
// share, archive, delete (⌘⌫ in the sidebar list) and regenerate the last
// answer (⌘R).
actions!(
    conduit,
    [
        RenameChat,
        TogglePinChat,
        ShareChat,
        ArchiveChat,
        DeleteChat,
        RegenerateLastAnswer,
        // Mark as Unread / Mark as Read, Generate Title, Show Branches…
        // (the open chat's whole tree) and Save Chat (a temporary chat).
        MarkChatUnread,
        GenerateChatTitle,
        // A LibreChat chat copied whole, on its server.
        DuplicateChat,
        ShowBranches,
        SaveTemporaryChat,
        // Chat › Context & Usage… (a Hermes chat's context window).
        ShowContextUsage
    ]
);

/// Chat › Export › Backup (JSON)… or Transcript (Markdown)….
#[derive(Clone, Debug, PartialEq, Action)]
#[action(namespace = conduit, no_json)]
pub struct ExportChatAs {
    pub format: conduit_protocol::ChatExportFormat,
}

// Go › Back (⌘[) and Forward (⌘]): what the main window showed before,
// across the sidebar's areas, as Finder's.
actions!(conduit, [GoBack, GoForward]);

/// Go › a sidebar section (⌘1, ⌘2…): the `index`th area the sidebar shows
/// (from 1), in its order, as the phone's ⌘1–⌘5 pick its tabs.
#[derive(Clone, Debug, PartialEq, Action)]
#[action(namespace = conduit, no_json)]
pub struct GoToSection {
    pub index: usize,
}

/// How many sections ⌘1… reach (one per area).
pub const GO_SECTIONS: usize = 8;

/// Chat › Move To: files the open chat in `folder_id` (`None`: out of any
/// folder).
#[derive(Clone, Debug, PartialEq, Action)]
#[action(namespace = conduit, no_json)]
pub struct MoveChatTo {
    pub folder_id: Option<String>,
}

/// Settings › Language: `None` follows the system.
#[derive(Clone, Debug, PartialEq, Action)]
#[action(namespace = conduit, no_json)]
pub struct SetLocale {
    pub locale: Option<String>,
}

/// Settings › Accounts row menu: sign out of the account and remove it.
#[derive(Clone, Debug, PartialEq, Action)]
#[action(namespace = conduit, no_json)]
pub struct RemoveAccount {
    pub account_id: String,
}

/// The Hermes switcher's menu item: put connection `connection_id` in use.
#[derive(Clone, Debug, PartialEq, Action)]
#[action(namespace = conduit, no_json)]
pub struct HermesSwitchConnection {
    pub connection_id: String,
}

// Settings › Hermes, from the Hermes switcher's menu.
actions!(conduit, [OpenHermesSettings]);

/// A Settings pop-up button's menu item: `value` picked in the pop-up
/// named `menu` (Settings routes it to the pane that drew the pop-up).
#[derive(Clone, Debug, PartialEq, Action)]
#[action(namespace = conduit, no_json)]
pub struct SettingsChoice {
    pub menu: String,
    pub value: String,
}

/// A command from a Calendar pane menu (`make-default`, `open`, `edit`,
/// `delete`) for a calendar or agenda item.
#[derive(Clone, Debug, PartialEq, Action)]
#[action(namespace = conduit, no_json)]
pub struct CalendarMenu {
    pub command: String,
    pub id: String,
}

/// A command from a Scheduled Tasks menu (`run`, `edit`, `pause`, `resume`,
/// `delete`) for a task.
#[derive(Clone, Debug, PartialEq, Action)]
#[action(namespace = conduit, no_json)]
pub struct TaskMenu {
    pub command: String,
    pub id: String,
}

/// The GPUI action a shortcut dispatches.
pub fn for_shortcut(action: ShortcutAction) -> Box<dyn Action> {
    use ShortcutAction as S;
    match action {
        S::NewChat => Box::new(NewChat),
        S::OpenPalette => Box::new(OpenPalette),
        S::FocusComposer => Box::new(FocusComposer),
        S::FocusModelPicker => Box::new(FocusModelPicker),
        S::StopGenerating => Box::new(StopGenerating),
        S::OpenSettings => Box::new(OpenSettings),
        S::ShowShortcuts => Box::new(ShowShortcuts),
        S::CopyLastResponse => Box::new(CopyLastResponse),
        S::CopyLastCodeBlock => Box::new(CopyLastCodeBlock),
        S::AllowRequest => Box::new(AllowRequest),
        S::DenyRequest => Box::new(DenyRequest),
        S::Dictate => Box::new(Dictate),
        S::ToggleSidebar => Box::new(ToggleSidebar),
        S::ReadAloud => Box::new(ReadAloud),
        S::VoiceCall => Box::new(VoiceCall),
    }
}
