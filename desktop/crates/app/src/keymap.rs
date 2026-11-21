//! The rebindable shortcuts: the table, its matching rules, the stored form
//! of a chord, and conflict detection, plus the bridge to GPUI key bindings.
//!
//! The table has 15 bindings; a 16th, `toggleSidePane`, waits for the
//! right-hand pane, which is post-v1. Only [`ShortcutAction::is_live`] ones
//! are bound to GPUI actions today; the rest keep their chords (rebindable
//! and conflict-checked) until a view binds them.

use std::collections::BTreeMap;

/// What a shortcut does.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum ShortcutAction {
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
    /// Read Aloud: the open chat's last answer (Chat › Read Aloud).
    ReadAloud,
    /// Chat › Start Voice Call in the open chat, or End Voice Call.
    VoiceCall,
}

impl ShortcutAction {
    pub const ALL: [Self; 15] = [
        Self::NewChat,
        Self::OpenPalette,
        Self::FocusComposer,
        Self::FocusModelPicker,
        Self::StopGenerating,
        Self::OpenSettings,
        Self::ShowShortcuts,
        Self::CopyLastResponse,
        Self::CopyLastCodeBlock,
        Self::AllowRequest,
        Self::DenyRequest,
        Self::Dictate,
        Self::ToggleSidebar,
        Self::ReadAloud,
        Self::VoiceCall,
    ];

    /// The stored name (`ShortcutAction.name` in Dart).
    pub fn name(self) -> &'static str {
        match self {
            Self::NewChat => "newChat",
            Self::OpenPalette => "openPalette",
            Self::FocusComposer => "focusComposer",
            Self::FocusModelPicker => "focusModelPicker",
            Self::StopGenerating => "stopGenerating",
            Self::OpenSettings => "openSettings",
            Self::ShowShortcuts => "showShortcuts",
            Self::CopyLastResponse => "copyLastResponse",
            Self::CopyLastCodeBlock => "copyLastCodeBlock",
            Self::AllowRequest => "allowRequest",
            Self::DenyRequest => "denyRequest",
            Self::Dictate => "dictate",
            Self::ToggleSidebar => "toggleSidebar",
            Self::ReadAloud => "readAloud",
            Self::VoiceCall => "voiceCall",
        }
    }

    pub fn from_name(name: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|a| a.name() == name)
    }

    /// Whether the app can carry this out yet. The others are listed in
    /// Settings › Keyboard as "not available yet" and are not bound.
    ///
    /// Every one is now (dictation came with voice input).
    pub fn is_live(self) -> bool {
        matches!(
            self,
            Self::NewChat
                | Self::OpenPalette
                | Self::OpenSettings
                | Self::ShowShortcuts
                | Self::ToggleSidebar
                | Self::AllowRequest
                | Self::DenyRequest
                | Self::FocusComposer
                | Self::FocusModelPicker
                | Self::StopGenerating
                | Self::CopyLastResponse
                | Self::CopyLastCodeBlock
                | Self::Dictate
                | Self::ReadAloud
                | Self::VoiceCall
        )
    }
}

/// A chord as the user describes it. `primary` is ⌘ on macOS and Ctrl
/// elsewhere; `ctrl` is macOS's ⌃ beside it (⌃⌘S), and unused elsewhere.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct KeyStroke {
    /// `KeyboardEvent.key`, lower-cased: `k`, `.`, `escape`, `enter`.
    pub key: String,
    pub primary: bool,
    pub shift: bool,
    pub alt: bool,
    pub ctrl: bool,
}

impl KeyStroke {
    pub fn new(key: &str) -> Self {
        Self {
            key: key.to_string(),
            primary: false,
            shift: false,
            alt: false,
            ctrl: false,
        }
    }
    pub fn primary(mut self) -> Self {
        self.primary = true;
        self
    }
    pub fn ctrl(mut self) -> Self {
        self.ctrl = true;
        self
    }
    /// Has a modifier that keeps it from typing a character (⌘, ⌥ or ⌃), so
    /// it can fire while a field is being typed in.
    pub fn is_chord(&self) -> bool {
        self.primary || self.alt || self.ctrl
    }
    pub fn shift(mut self) -> Self {
        self.shift = true;
        self
    }
    pub fn alt(mut self) -> Self {
        self.alt = true;
        self
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Shortcut {
    pub action: ShortcutAction,
    pub stroke: KeyStroke,
    /// Fires with the caret in a field. A bare letter must not, or it would
    /// eat that character out of the message being typed.
    pub while_typing: bool,
}

/// New Chat's second chord (Open WebUI's), bound beside ⌘N while no other
/// command has it, so hands that learned it keep working. Menus show ⌘N.
pub fn new_chat_alias() -> KeyStroke {
    KeyStroke::new("o").primary().shift()
}

/// The defaults: the macOS conventions (⌘N, ⌃⌘S as in Finder and Mail),
/// else Open WebUI's, for what the app does.
pub fn default_shortcuts() -> Vec<Shortcut> {
    use ShortcutAction as A;
    let s = |action, stroke| Shortcut {
        action,
        stroke,
        while_typing: true,
    };
    vec![
        s(A::NewChat, KeyStroke::new("n").primary()),
        s(A::OpenPalette, KeyStroke::new("k").primary()),
        // Shift+Esc: plain Esc stops a running turn.
        s(A::FocusComposer, KeyStroke::new("escape").shift()),
        s(A::FocusModelPicker, KeyStroke::new("m").primary().shift()),
        s(A::StopGenerating, KeyStroke::new("escape")),
        // ⌘, (the macOS standard), not ⌘.
        s(A::OpenSettings, KeyStroke::new(",").primary()),
        s(A::ShowShortcuts, KeyStroke::new("/").primary()),
        s(A::CopyLastResponse, KeyStroke::new("c").primary().shift()),
        s(A::AllowRequest, KeyStroke::new("enter").primary().alt()),
        s(A::DenyRequest, KeyStroke::new("backspace").primary().alt()),
        s(A::CopyLastCodeBlock, KeyStroke::new(";").primary().shift()),
        s(A::Dictate, KeyStroke::new("l").primary().shift()),
        s(A::ToggleSidebar, KeyStroke::new("s").primary().ctrl()),
        // ⌥ beside Regenerate's ⌘R: both act on the last answer.
        s(A::ReadAloud, KeyStroke::new("r").primary().alt()),
        // ⌥ as Read Aloud has: the voice's commands.
        s(A::VoiceCall, KeyStroke::new("v").primary().alt()),
    ]
}

/// The action `pressed` invokes, if any. `typing`: the event came from a
/// field being edited.
pub fn resolve(table: &[Shortcut], pressed: &KeyStroke, typing: bool) -> Option<ShortcutAction> {
    let s = table.iter().find(|s| &s.stroke == pressed)?;
    (!typing || s.while_typing).then_some(s.action)
}

/// How the chord reads: in Apple's modifier order on macOS (⌃⌥⇧⌘, so
/// `⇧⌘O`, `⌃⌘S`, `⌥⌘↩`), `Ctrl+Shift+O` elsewhere.
pub fn describe(stroke: &KeyStroke, mac: bool) -> String {
    let mut parts: Vec<String> = vec![];
    if mac {
        if stroke.ctrl {
            parts.push("⌃".into());
        }
        if stroke.alt {
            parts.push("⌥".into());
        }
        if stroke.shift {
            parts.push("⇧".into());
        }
        if stroke.primary {
            parts.push("⌘".into());
        }
        parts.push(describe_key(&stroke.key, mac));
        return parts.concat();
    }
    if stroke.primary || stroke.ctrl {
        parts.push("Ctrl".into());
    }
    if stroke.shift {
        parts.push("Shift".into());
    }
    if stroke.alt {
        parts.push("Alt".into());
    }
    parts.push(describe_key(&stroke.key, mac));
    parts.join("+")
}

fn describe_key(key: &str, mac: bool) -> String {
    match key {
        "escape" => if mac { "⎋" } else { "Esc" }.into(),
        "enter" => if mac { "↩" } else { "Enter" }.into(),
        "backspace" => if mac { "⌫" } else { "Backspace" }.into(),
        "arrowup" => "↑".into(),
        "arrowdown" => "↓".into(),
        "arrowleft" => "←".into(),
        "arrowright" => "→".into(),
        "tab" => if mac { "⇥" } else { "Tab" }.into(),
        "delete" => if mac { "⌦" } else { "Delete" }.into(),
        " " | "space" => "Space".into(),
        k if k.chars().count() == 1 => k.to_uppercase(),
        k => k.into(),
    }
}

/// The stored form, e.g. `mod+shift+o` (`ctrl+mod+s` with ⌃).
pub fn encode(stroke: &KeyStroke) -> String {
    let mut parts = vec![];
    if stroke.ctrl {
        parts.push("ctrl");
    }
    if stroke.primary {
        parts.push("mod");
    }
    if stroke.shift {
        parts.push("shift");
    }
    if stroke.alt {
        parts.push("alt");
    }
    parts.push(&stroke.key);
    parts.join("+")
}

/// The inverse of [`encode`]; `None` for anything it did not write.
pub fn decode(encoded: &str) -> Option<KeyStroke> {
    // The key itself may be `+`, which ends the string after its separator.
    let plus = encoded.ends_with("++");
    let body = if plus {
        &encoded[..encoded.len() - 2]
    } else {
        encoded
    };
    let mut parts: Vec<&str> = body.split('+').filter(|p| !p.is_empty()).collect();
    let key = if plus {
        "+".to_string()
    } else {
        parts.pop()?.to_string()
    };
    if key.is_empty() || key.chars().count() > 12 {
        return None;
    }
    let mut stroke = KeyStroke::new(&key);
    for m in parts {
        match m {
            "mod" => stroke.primary = true,
            "shift" => stroke.shift = true,
            "alt" => stroke.alt = true,
            "ctrl" => stroke.ctrl = true,
            _ => return None,
        }
    }
    Some(stroke)
}

/// The defaults with the user's keys (by action name) in place. An override
/// that cannot be read keeps the default.
pub fn apply_overrides(overrides: &BTreeMap<String, String>) -> Vec<Shortcut> {
    default_shortcuts()
        .into_iter()
        .map(
            |s| match overrides.get(s.action.name()).and_then(|e| decode(e)) {
                Some(stroke) => Shortcut {
                    action: s.action,
                    // A chord keeps working while typing; a bare key must not.
                    while_typing: stroke.is_chord(),
                    stroke,
                },
                None => s,
            },
        )
        .collect()
}

/// A command whose chord is fixed: the menus' standard ones and the app's
/// Find, zoom and chat commands (`menus::bind_keys` binds them). Settings ›
/// Keyboard lists the app's own read-only ([`FixedCommand::listed`]), and
/// no rebindable command, nor Quick Ask, may take one of their chords.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum FixedCommand {
    NewTemporaryChat,
    SearchChats,
    DeleteChat,
    NextChat,
    PreviousChat,
    Regenerate,
    /// The composer's larger editor, and back.
    ExpandEditor,
    /// Puts the text selected in an answer into the composer.
    AskConduit,
    /// The open chat's settings, or the selected folder's (⌘I, Get Info).
    ChatSettings,
    FindInChat,
    FindNext,
    FindPrevious,
    ActualSize,
    ZoomIn,
    ZoomOut,
    /// ⌘, opens Settings whatever Open Settings is rebound to.
    Settings,
    Quit,
    Hide,
    HideOthers,
    CloseWindow,
    Minimize,
    FullScreen,
    /// Go › Back (⌘[).
    Back,
    /// Go › Forward (⌘]).
    Forward,
    /// Go › the `n`th sidebar section (⌘1…⌘8; `n` from 1).
    GoToSection(u8),
    /// Go › Move Focus to Next Area (⌥⌘`): out of the terminal too.
    NextArea,
    /// Go › Move Focus to Previous Area (⌥⌘~, Shift with ⌥⌘`).
    PreviousArea,
    /// Chat › Stop Speaking (⌘., the Mac's Cancel; Esc too while it reads).
    StopSpeaking,
}

impl FixedCommand {
    /// Listed in Settings › Keyboard. The standard app and window chords
    /// (⌘Q, ⌘H, ⌘W, ⌘M, ⌃⌘F) are every Mac app's and are not; ⌘, is
    /// listed as Open Settings' own row.
    ///
    /// ⌘1…⌘8 are listed once, as one row ([`Self::GoToSection`] 1).
    pub fn listed(self) -> bool {
        !matches!(
            self,
            Self::Settings
                | Self::Quit
                | Self::Hide
                | Self::HideOthers
                | Self::CloseWindow
                | Self::Minimize
                | Self::FullScreen
        ) && !matches!(self, Self::GoToSection(n) if n != 1)
    }

    /// The rebindable command this one stands beside (⌘, is Open
    /// Settings' default too), so that command may keep its own chord.
    fn same_as(self, action: ShortcutAction) -> bool {
        self == Self::Settings && action == ShortcutAction::OpenSettings
    }
}

/// The fixed chords, as `menus::bind_keys` binds them (Zoom In's ⌘= alias
/// included: it is taken too).
pub fn fixed_shortcuts() -> Vec<(FixedCommand, KeyStroke)> {
    use FixedCommand as F;
    let k = KeyStroke::new;
    vec![
        (F::NewTemporaryChat, k("n").primary().shift()),
        (F::SearchChats, k("f").primary().alt()),
        (F::DeleteChat, k("backspace").primary()),
        (F::NextChat, k("tab").ctrl()),
        (F::PreviousChat, k("tab").ctrl().shift()),
        (F::Regenerate, k("r").primary()),
        (F::StopSpeaking, k(".").primary()),
        (F::ExpandEditor, k("e").primary().shift()),
        (F::AskConduit, k("a").primary().shift()),
        (F::ChatSettings, k("i").primary()),
        (F::FindInChat, k("f").primary()),
        (F::FindNext, k("g").primary()),
        (F::FindPrevious, k("g").primary().shift()),
        (F::ActualSize, k("0").primary()),
        (F::ZoomIn, k("+").primary()),
        (F::ZoomIn, k("=").primary()),
        (F::ZoomOut, k("-").primary()),
        (F::Settings, k(",").primary()),
        (F::Quit, k("q").primary()),
        (F::Hide, k("h").primary()),
        (F::HideOthers, k("h").primary().alt()),
        (F::CloseWindow, k("w").primary()),
        (F::Minimize, k("m").primary()),
        (F::FullScreen, k("f").primary().ctrl()),
        (F::Back, k("[").primary()),
        (F::Forward, k("]").primary()),
        (F::GoToSection(1), k("1").primary()),
        (F::GoToSection(2), k("2").primary()),
        (F::GoToSection(3), k("3").primary()),
        (F::GoToSection(4), k("4").primary()),
        (F::GoToSection(5), k("5").primary()),
        (F::GoToSection(6), k("6").primary()),
        (F::GoToSection(7), k("7").primary()),
        (F::GoToSection(8), k("8").primary()),
        // ⌥⌘` beside the system's ⌘` (next window), as Xcode's Next Area;
        // Shift with it types ~, which is the key the Mac reports.
        (F::NextArea, k("`").primary().alt()),
        (F::PreviousArea, k("~").primary().alt()),
    ]
}

/// The chord a fixed command shows (its first, as the menus show it).
pub fn fixed_stroke(command: FixedCommand) -> KeyStroke {
    fixed_shortcuts()
        .into_iter()
        .find(|(c, _)| *c == command)
        .map(|(_, s)| s)
        .unwrap_or_else(|| KeyStroke::new(""))
}

/// The fixed command `stroke` belongs to, unless it stands beside `action`
/// (`None` for Quick Ask, which stands beside none).
pub fn fixed_conflict(stroke: &KeyStroke, action: Option<ShortcutAction>) -> Option<FixedCommand> {
    fixed_shortcuts()
        .into_iter()
        .find(|(c, s)| s == stroke && !action.is_some_and(|a| c.same_as(a)))
        .map(|(c, _)| c)
}

/// A key that works in one area only, listed in Settings › Keyboard under
/// it: Notes' (its list and editor: New Note and the Format menu's chords),
/// Workspace's Save, the Calendar's and Scheduled Tasks' keys (their
/// panes' and editors' own key handlers), the terminal's (the Edit menu's
/// chords as its console answers them, and ⌥⌘K Clear Scrollback, Terminal's
/// own), a room's ⌘↩ Send and a scheduled agent's ⌘↩ Save. Some share a
/// chord with a command that works everywhere else (⌘N New Chat, ⌘K the
/// palette, ⌘I Chat Settings): Notes binds them in its own contexts after
/// the shortcut table, so they win there (`menus::bind_keys`), and they
/// take no chord from anything else. The terminal leaves ⌘K to the palette
/// and ⌃⇥ to Next Chat, as its console leaves every ⌘ chord to the app.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AreaKey {
    NewNote,
    Title,
    Heading,
    Subheading,
    Body,
    Bold,
    Italic,
    Strikethrough,
    Code,
    Link,
    BulletedList,
    NumberedList,
    Checklist,
    MarkChecked,
    Quote,
    CodeBlock,
    /// ⌘S in a Workspace editor.
    SaveWorkspaceItem,
    /// The agenda's earlier and later days, and today (⌘←, ⌘→, ⌘T).
    CalendarEarlier,
    CalendarLater,
    CalendarToday,
    /// ⌘⌫ on the agenda's selected event.
    DeleteCalendarItem,
    /// ⌘S in the event editor.
    SaveCalendarEvent,
    /// ⌘⌫ on the selected task.
    DeleteScheduledTask,
    /// ⌘S in the task editor.
    SaveScheduledTask,
    /// ⌘F, ⌘C, ⌘V and ⌘A in a terminal's console (its own Find bar, and
    /// the Edit menu's commands on its text).
    TerminalFind,
    TerminalCopy,
    TerminalPaste,
    TerminalSelectAll,
    /// ⌥⌘K in the console, as Terminal's Clear Scrollback.
    TerminalClearScrollback,
    /// ⌘S in the window of a PDF a terminal shows: Save….
    SavePdf,
    /// ⌘↩ in a Group Chat's field: sends, whatever Return is set to do.
    SendInRoom,
    /// ⌘↩ in the scheduled agent sheet.
    SaveHermesJob,
}

impl AreaKey {
    /// The Settings › Keyboard group it is listed under.
    pub fn group(self) -> KeyGroup {
        use AreaKey as A;
        match self {
            A::SaveWorkspaceItem => KeyGroup::Workspace,
            A::CalendarEarlier
            | A::CalendarLater
            | A::CalendarToday
            | A::DeleteCalendarItem
            | A::SaveCalendarEvent => KeyGroup::Calendar,
            A::DeleteScheduledTask | A::SaveScheduledTask => KeyGroup::ScheduledTasks,
            A::TerminalFind
            | A::TerminalCopy
            | A::TerminalPaste
            | A::TerminalSelectAll
            | A::TerminalClearScrollback
            | A::SavePdf => KeyGroup::Terminal,
            A::SendInRoom => KeyGroup::HermesRooms,
            A::SaveHermesJob => KeyGroup::HermesJobs,
            _ => KeyGroup::Notes,
        }
    }
}

/// The area keys and their chords, as Notes binds them (the Format menu
/// shows them) and a Workspace editor takes ⌘S.
pub fn area_shortcuts() -> Vec<(AreaKey, KeyStroke)> {
    use AreaKey as A;
    let k = KeyStroke::new;
    vec![
        (A::NewNote, k("n").primary()),
        (A::Title, k("t").primary().shift()),
        (A::Heading, k("h").primary().shift()),
        (A::Subheading, k("j").primary().shift()),
        (A::Body, k("b").primary().shift()),
        (A::Bold, k("b").primary()),
        (A::Italic, k("i").primary()),
        (A::Strikethrough, k("x").primary().shift()),
        (A::Code, k("e").primary()),
        (A::Link, k("k").primary()),
        (A::BulletedList, k("7").primary().shift()),
        (A::NumberedList, k("9").primary().shift()),
        (A::Checklist, k("8").primary().shift()),
        (A::MarkChecked, k("u").primary().shift()),
        (A::Quote, k("'").primary()),
        (A::CodeBlock, k("c").primary().alt()),
        (A::SaveWorkspaceItem, k("s").primary()),
        (A::CalendarEarlier, k("arrowleft").primary()),
        (A::CalendarLater, k("arrowright").primary()),
        (A::CalendarToday, k("t").primary()),
        (A::DeleteCalendarItem, k("backspace").primary()),
        (A::SaveCalendarEvent, k("s").primary()),
        (A::DeleteScheduledTask, k("backspace").primary()),
        (A::SaveScheduledTask, k("s").primary()),
        (A::TerminalFind, k("f").primary()),
        (A::TerminalCopy, k("c").primary()),
        (A::TerminalPaste, k("v").primary()),
        (A::TerminalSelectAll, k("a").primary()),
        (A::TerminalClearScrollback, k("k").primary().alt()),
        (A::SavePdf, k("s").primary()),
        (A::SendInRoom, k("enter").primary()),
        (A::SaveHermesJob, k("enter").primary()),
    ]
}

/// The chord an area key has.
pub fn area_stroke(key: AreaKey) -> KeyStroke {
    area_shortcuts()
        .into_iter()
        .find(|(k, _)| *k == key)
        .map(|(_, s)| s)
        .unwrap_or_else(|| KeyStroke::new(""))
}

/// A row of Settings › Keyboard.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum KeyRow {
    /// Recorded and rebound in place.
    Rebindable(ShortcutAction),
    /// Shown, not changed.
    Fixed(FixedCommand),
    /// Quick Ask's global shortcut (also in General, with its switch).
    QuickAsk,
    /// Works in one area only (Notes, Workspace, …); shown, not changed.
    Area(AreaKey),
}

/// Settings › Keyboard's groups, as the menus group the commands.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum KeyGroup {
    Chats,
    Messages,
    FindAndView,
    /// The Go menu: Back, Forward and the sidebar's sections.
    Go,
    Window,
    /// New Note and the Format menu, in Notes.
    Notes,
    /// Save, in a Workspace editor.
    Workspace,
    /// The agenda's days, Delete and Save, in Calendar.
    Calendar,
    /// Delete and Save, in Scheduled Tasks.
    ScheduledTasks,
    /// Find, the Edit menu's commands and Clear Scrollback, in a terminal;
    /// Save… in the window of a PDF it shows.
    Terminal,
    /// Send, in a Hermes Group Chat.
    HermesRooms,
    /// Save, in a Hermes scheduled agent's sheet.
    HermesJobs,
}

/// Every shortcut the app has, grouped: the rebindable ones the app can
/// carry out, the fixed ones it lists, and Quick Ask's.
pub fn keyboard_groups() -> Vec<(KeyGroup, Vec<KeyRow>)> {
    use FixedCommand as F;
    use KeyRow::{Fixed, QuickAsk, Rebindable as R};
    use ShortcutAction as A;
    vec![
        (
            KeyGroup::Chats,
            vec![
                R(A::NewChat),
                Fixed(F::NewTemporaryChat),
                R(A::OpenPalette),
                Fixed(F::SearchChats),
                Fixed(F::PreviousChat),
                Fixed(F::NextChat),
                Fixed(F::DeleteChat),
            ],
        ),
        (
            KeyGroup::Messages,
            vec![
                R(A::FocusComposer),
                R(A::Dictate),
                R(A::FocusModelPicker),
                R(A::StopGenerating),
                Fixed(F::Regenerate),
                R(A::ReadAloud),
                Fixed(F::StopSpeaking),
                R(A::VoiceCall),
                Fixed(F::ExpandEditor),
                Fixed(F::AskConduit),
                Fixed(F::ChatSettings),
                R(A::CopyLastResponse),
                R(A::CopyLastCodeBlock),
                R(A::AllowRequest),
                R(A::DenyRequest),
            ],
        ),
        (
            KeyGroup::FindAndView,
            vec![
                Fixed(F::FindInChat),
                Fixed(F::FindNext),
                Fixed(F::FindPrevious),
                R(A::ToggleSidebar),
                Fixed(F::ActualSize),
                Fixed(F::ZoomIn),
                Fixed(F::ZoomOut),
            ],
        ),
        (
            KeyGroup::Go,
            vec![
                Fixed(F::Back),
                Fixed(F::Forward),
                Fixed(F::GoToSection(1)),
                Fixed(F::NextArea),
                Fixed(F::PreviousArea),
            ],
        ),
        (
            KeyGroup::Window,
            vec![QuickAsk, R(A::OpenSettings), R(A::ShowShortcuts)],
        ),
        // The areas' own keys, in the sidebar's order (Hermes: Scheduled
        // Agents above the rooms; Notes, Terminal, Workspace, Calendar,
        // Automations).
        (KeyGroup::HermesJobs, area_rows(KeyGroup::HermesJobs)),
        (KeyGroup::HermesRooms, area_rows(KeyGroup::HermesRooms)),
        (KeyGroup::Notes, area_rows(KeyGroup::Notes)),
        (KeyGroup::Terminal, area_rows(KeyGroup::Terminal)),
        (KeyGroup::Workspace, area_rows(KeyGroup::Workspace)),
        (KeyGroup::Calendar, area_rows(KeyGroup::Calendar)),
        (
            KeyGroup::ScheduledTasks,
            area_rows(KeyGroup::ScheduledTasks),
        ),
    ]
}

/// One area's keys, as rows.
fn area_rows(group: KeyGroup) -> Vec<KeyRow> {
    area_shortcuts()
        .into_iter()
        .filter(|(k, _)| k.group() == group)
        .map(|(k, _)| KeyRow::Area(k))
        .collect()
}

/// The action other than `action` that `stroke` already fires.
pub fn conflict(
    table: &[Shortcut],
    action: ShortcutAction,
    stroke: &KeyStroke,
) -> Option<ShortcutAction> {
    table
        .iter()
        .find(|s| s.action != action && &s.stroke == stroke)
        .map(|s| s.action)
}

/// The user's overrides, with the edits Settings › Keyboard makes.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Keymap {
    pub overrides: BTreeMap<String, String>,
}

impl Keymap {
    pub fn new(overrides: BTreeMap<String, String>) -> Self {
        Self { overrides }
    }

    pub fn table(&self) -> Vec<Shortcut> {
        apply_overrides(&self.overrides)
    }

    /// `action`'s default chord.
    pub fn defaults_stroke(&self, action: ShortcutAction) -> Option<KeyStroke> {
        default_shortcuts()
            .into_iter()
            .find(|s| s.action == action)
            .map(|s| s.stroke)
    }

    pub fn stroke(&self, action: ShortcutAction) -> KeyStroke {
        self.table()
            .into_iter()
            .find(|s| s.action == action)
            .map(|s| s.stroke)
            .unwrap_or_else(|| KeyStroke::new(""))
    }

    /// Rebinds `action`, unless another action has `stroke`. A stroke equal
    /// to the default drops the override.
    pub fn set(&mut self, action: ShortcutAction, stroke: KeyStroke) -> Result<(), ShortcutAction> {
        if let Some(other) = conflict(&self.table(), action, &stroke) {
            return Err(other);
        }
        let default = default_shortcuts()
            .into_iter()
            .find(|s| s.action == action)
            .map(|s| s.stroke);
        if default.as_ref() == Some(&stroke) {
            self.overrides.remove(action.name());
        } else {
            self.overrides.insert(action.name().into(), encode(&stroke));
        }
        Ok(())
    }

    /// Puts `action` back on its default, unless another action has taken
    /// that chord since (the conflict is that action).
    pub fn reset(&mut self, action: ShortcutAction) -> Result<(), ShortcutAction> {
        if let Some(default) = default_shortcuts()
            .into_iter()
            .find(|s| s.action == action)
            .map(|s| s.stroke)
            && let Some(other) = conflict(&self.table(), action, &default)
        {
            return Err(other);
        }
        self.overrides.remove(action.name());
        Ok(())
    }

    pub fn reset_all(&mut self) {
        self.overrides.clear();
    }
}

/// GPUI's keystroke syntax for `stroke` (`cmd-shift-o`, `cmd-alt-enter`).
pub fn to_gpui(stroke: &KeyStroke) -> String {
    let mut parts = vec![];
    if stroke.ctrl && cfg!(target_os = "macos") {
        parts.push("ctrl");
    }
    if stroke.primary {
        parts.push(if cfg!(target_os = "macos") {
            "cmd"
        } else {
            "ctrl"
        });
    }
    if stroke.alt {
        parts.push("alt");
    }
    if stroke.shift {
        parts.push("shift");
    }
    let key = match stroke.key.as_str() {
        "arrowup" => "up",
        "arrowdown" => "down",
        "arrowleft" => "left",
        "arrowright" => "right",
        " " => "space",
        k => k,
    };
    parts.push(key);
    parts.join("-")
}

/// A captured GPUI keystroke as a [`KeyStroke`]; `None` for a bare modifier
/// or a chord using Fn (which the table cannot store).
pub fn from_gpui(ks: &gpui_kit::Keystroke) -> Option<KeyStroke> {
    let m = &ks.modifiers;
    if m.function {
        return None;
    }
    let key = match ks.key.as_str() {
        "up" => "arrowup".to_string(),
        "down" => "arrowdown".to_string(),
        "left" => "arrowleft".to_string(),
        "right" => "arrowright".to_string(),
        "space" => " ".to_string(),
        "" | "shift" | "alt" | "cmd" | "control" | "fn" | "platform" => return None,
        k => k.to_ascii_lowercase(),
    };
    Some(KeyStroke {
        key,
        primary: if cfg!(target_os = "macos") {
            m.platform
        } else {
            m.control
        },
        shift: m.shift,
        alt: m.alt,
        ctrl: cfg!(target_os = "macos") && m.control,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use ShortcutAction as A;

    #[test]
    fn matches_a_chord_exactly() {
        let t = default_shortcuts();
        assert_eq!(
            resolve(&t, &KeyStroke::new("k").primary(), false),
            Some(A::OpenPalette)
        );
        // Cmd+Shift+K is not Cmd+K.
        assert_eq!(
            resolve(&t, &KeyStroke::new("k").primary().shift(), false),
            None
        );
        assert_eq!(resolve(&t, &KeyStroke::new("q"), false), None);
    }

    #[test]
    fn while_typing() {
        let t = default_shortcuts();
        // Cmd+K reaches the palette from the composer.
        assert_eq!(
            resolve(&t, &KeyStroke::new("k").primary(), true),
            Some(A::OpenPalette)
        );
        // Esc reaches the running turn from inside the composer.
        assert_eq!(
            resolve(&t, &KeyStroke::new("escape"), true),
            Some(A::StopGenerating)
        );
        let bare = vec![Shortcut {
            action: A::NewChat,
            stroke: KeyStroke::new("n"),
            while_typing: false,
        }];
        assert_eq!(
            resolve(&bare, &KeyStroke::new("n"), false),
            Some(A::NewChat)
        );
        assert_eq!(resolve(&bare, &KeyStroke::new("n"), true), None);
    }

    #[test]
    fn every_default_is_reachable_and_unique() {
        let t = default_shortcuts();
        assert_eq!(t.len(), 15);
        let mut seen = std::collections::HashSet::new();
        for s in &t {
            assert!(
                seen.insert(s.stroke.clone()),
                "{:?} is bound twice",
                s.stroke
            );
            assert_eq!(resolve(&t, &s.stroke, false), Some(s.action));
        }
        // Every action has exactly one row.
        let actions: std::collections::HashSet<_> = t.iter().map(|s| s.action).collect();
        assert_eq!(actions.len(), ShortcutAction::ALL.len());
    }

    #[test]
    fn describes_with_the_platform_accelerator() {
        let s = KeyStroke::new("o").primary().shift();
        assert_eq!(describe(&s, true), "⇧⌘O");
        assert_eq!(describe(&s, false), "Ctrl+Shift+O");
        assert_eq!(describe(&KeyStroke::new("escape"), false), "Esc");
        assert_eq!(
            describe(&KeyStroke::new("enter").primary().alt(), true),
            "⌥⌘↩"
        );
    }

    #[test]
    fn mac_modifiers_read_in_apple_order() {
        // ⌃ ⌥ ⇧ ⌘, as every menu writes them.
        let all = KeyStroke::new("k").primary().shift().alt().ctrl();
        assert_eq!(describe(&all, true), "⌃⌥⇧⌘K");
        assert_eq!(describe(&KeyStroke::new("s").primary().ctrl(), true), "⌃⌘S");
        assert_eq!(
            describe(&KeyStroke::new("backspace").primary().alt(), true),
            "⌥⌘⌫"
        );
        assert_eq!(
            describe(&KeyStroke::new(" ").primary().shift(), true),
            "⇧⌘Space"
        );
    }

    #[test]
    fn mac_defaults_follow_the_system_conventions() {
        let t = default_shortcuts();
        let find = |a| t.iter().find(|s| s.action == a).unwrap().stroke.clone();
        assert_eq!(find(A::NewChat), KeyStroke::new("n").primary());
        assert_eq!(find(A::ToggleSidebar), KeyStroke::new("s").primary().ctrl());
        assert_eq!(find(A::OpenSettings), KeyStroke::new(",").primary());
        // ⇧⌘O stays free for New Chat's alias.
        assert!(t.iter().all(|s| s.stroke != new_chat_alias()));
    }

    #[test]
    fn control_chords_are_stored_and_bound() {
        let s = KeyStroke::new("s").primary().ctrl();
        assert_eq!(encode(&s), "ctrl+mod+s");
        assert_eq!(decode("ctrl+mod+s"), Some(s.clone()));
        if cfg!(target_os = "macos") {
            assert_eq!(to_gpui(&s), "ctrl-cmd-s");
            let parsed = gpui_kit::Keystroke::parse("ctrl-cmd-s").unwrap();
            assert_eq!(from_gpui(&parsed), Some(s));
        }
        // A ⌃ chord fires while typing, as a ⌘ one does.
        let t = apply_overrides(&BTreeMap::from([("newChat".into(), "ctrl+n".into())]));
        assert_eq!(
            resolve(&t, &KeyStroke::new("n").ctrl(), true),
            Some(A::NewChat)
        );
    }

    #[test]
    fn strokes_are_stored_and_read_back() {
        let s = KeyStroke::new("o").primary().shift();
        assert_eq!(encode(&s), "mod+shift+o");
        assert_eq!(decode("mod+shift+o"), Some(s));
        assert_eq!(decode("alt++"), Some(KeyStroke::new("+").alt()));
        assert_eq!(decode("hyper+o"), None);
        assert_eq!(decode(""), None);
        for s in default_shortcuts() {
            assert_eq!(decode(&encode(&s.stroke)), Some(s.stroke));
        }
    }

    #[test]
    fn an_override_replaces_one_default_and_keeps_the_rest() {
        let overrides = BTreeMap::from([
            ("newChat".to_string(), "mod+j".to_string()),
            ("openPalette".to_string(), "nonsense+k".to_string()),
        ]);
        let t = apply_overrides(&overrides);
        let find = |a| t.iter().find(|s| s.action == a).unwrap().clone();
        assert_eq!(find(A::NewChat).stroke, KeyStroke::new("j").primary());
        assert_eq!(
            find(A::OpenPalette),
            default_shortcuts()
                .into_iter()
                .find(|s| s.action == A::OpenPalette)
                .unwrap()
        );
        assert_eq!(t.len(), default_shortcuts().len());
    }

    #[test]
    fn a_bare_key_override_does_not_fire_while_typing() {
        let t = apply_overrides(&BTreeMap::from([("newChat".into(), "n".into())]));
        assert_eq!(resolve(&t, &KeyStroke::new("n"), true), None);
        assert_eq!(resolve(&t, &KeyStroke::new("n"), false), Some(A::NewChat));
    }

    #[test]
    fn a_key_another_command_has_is_a_conflict() {
        let t = default_shortcuts();
        assert_eq!(
            conflict(&t, A::NewChat, &KeyStroke::new("k").primary()),
            Some(A::OpenPalette)
        );
        assert_eq!(
            conflict(&t, A::OpenPalette, &KeyStroke::new("k").primary()),
            None,
            "its own key is no conflict"
        );
    }

    #[test]
    fn keymap_edits_persist_as_overrides() {
        let mut k = Keymap::default();
        assert_eq!(
            k.set(A::NewChat, KeyStroke::new("k").primary()),
            Err(A::OpenPalette)
        );
        assert!(k.overrides.is_empty());
        k.set(A::NewChat, KeyStroke::new("j").primary()).unwrap();
        assert_eq!(
            k.overrides.get("newChat").map(String::as_str),
            Some("mod+j")
        );
        // Survives a store/load through the prefs map.
        let reloaded = Keymap::new(k.overrides.clone());
        assert_eq!(reloaded.stroke(A::NewChat), KeyStroke::new("j").primary());
        // Setting the default back drops the override.
        k.set(A::NewChat, KeyStroke::new("n").primary()).unwrap();
        assert!(k.overrides.is_empty());
        // The freed chord can be taken by another action.
        k.set(A::ToggleSidebar, KeyStroke::new("b").primary())
            .unwrap();
        k.reset(A::ToggleSidebar).unwrap();
        assert!(k.overrides.is_empty());
        // A reset never takes back a default another action has since.
        k.set(A::NewChat, KeyStroke::new("j").primary()).unwrap();
        k.set(A::OpenPalette, KeyStroke::new("n").primary())
            .unwrap();
        assert_eq!(k.reset(A::NewChat), Err(A::OpenPalette));
        assert_eq!(k.stroke(A::NewChat), KeyStroke::new("j").primary());
        assert_eq!(
            resolve(&k.table(), &KeyStroke::new("n").primary(), false),
            Some(A::OpenPalette)
        );
        k.reset_all();
        k.set(A::Dictate, KeyStroke::new("d").primary()).unwrap();
        k.reset_all();
        assert_eq!(k, Keymap::default());
    }

    #[test]
    fn gpui_keystroke_syntax() {
        // The primary modifier is ⌘ on the Mac and Ctrl elsewhere.
        let primary = if cfg!(target_os = "macos") {
            "cmd"
        } else {
            "ctrl"
        };
        assert_eq!(
            to_gpui(&KeyStroke::new("o").primary().shift()),
            format!("{primary}-shift-o")
        );
        assert_eq!(
            to_gpui(&KeyStroke::new("enter").primary().alt()),
            format!("{primary}-alt-enter")
        );
        assert_eq!(to_gpui(&KeyStroke::new("escape").shift()), "shift-escape");
        for s in default_shortcuts() {
            // `Keystroke::parse` wants a 'static source (its error borrows it).
            let source: &'static str = Box::leak(to_gpui(&s.stroke).into_boxed_str());
            let parsed = gpui_kit::Keystroke::parse(source).unwrap();
            // Off the Mac a ⌃⌘ chord is the Ctrl one: Ctrl is the primary.
            let read_back = KeyStroke {
                ctrl: s.stroke.ctrl && cfg!(target_os = "macos"),
                ..s.stroke.clone()
            };
            assert_eq!(from_gpui(&parsed), Some(read_back), "{:?}", s.stroke);
        }
    }

    #[test]
    fn only_working_shortcuts_are_live() {
        let live: Vec<_> = ShortcutAction::ALL
            .into_iter()
            .filter(|a| a.is_live())
            .collect();
        assert_eq!(
            live,
            vec![
                A::NewChat,
                A::OpenPalette,
                A::FocusComposer,
                A::FocusModelPicker,
                A::StopGenerating,
                A::OpenSettings,
                A::ShowShortcuts,
                A::CopyLastResponse,
                A::CopyLastCodeBlock,
                A::AllowRequest,
                A::DenyRequest,
                A::Dictate,
                A::ToggleSidebar,
                A::ReadAloud,
                A::VoiceCall
            ]
        );
        for a in ShortcutAction::ALL {
            assert_eq!(ShortcutAction::from_name(a.name()), Some(a));
        }
    }

    #[test]
    fn the_keyboard_pane_lists_every_shortcut_once() {
        let rows: Vec<KeyRow> = keyboard_groups()
            .into_iter()
            .flat_map(|(_, rows)| rows)
            .collect();
        // Every command the app carries out, once.
        for a in ShortcutAction::ALL {
            let n = rows.iter().filter(|r| **r == KeyRow::Rebindable(a)).count();
            assert_eq!(n, usize::from(a.is_live()), "{a:?}");
        }
        let mut listed: Vec<FixedCommand> = fixed_shortcuts()
            .into_iter()
            .map(|(c, _)| c)
            .filter(|c| c.listed())
            .collect();
        listed.dedup();
        for c in &listed {
            let n = rows.iter().filter(|r| **r == KeyRow::Fixed(*c)).count();
            assert_eq!(n, 1, "{c:?}");
        }
        assert_eq!(rows.iter().filter(|r| **r == KeyRow::QuickAsk).count(), 1);
        for (key, _) in area_shortcuts() {
            let n = rows.iter().filter(|r| **r == KeyRow::Area(key)).count();
            assert_eq!(n, 1, "{key:?}");
        }
        // 15 rebindable, 20 fixed (⌘1…⌘8 as one row), Quick Ask, 16 in
        // Notes, Workspace's Save, 6 in the terminal (its PDF window's Save
        // among them), 5 in Calendar, 2 in Scheduled Tasks, a room's Send
        // and a scheduled agent's Save.
        assert_eq!(rows.len(), 69);
        // One area's keys share no chord among themselves (areas may: only
        // the one in front takes its keys); where one is a fixed command's
        // too (⌘I Chat Settings), Notes takes it only in its own contexts.
        for group in [
            KeyGroup::Notes,
            KeyGroup::Workspace,
            KeyGroup::Terminal,
            KeyGroup::Calendar,
            KeyGroup::ScheduledTasks,
            KeyGroup::HermesRooms,
            KeyGroup::HermesJobs,
        ] {
            let area: Vec<KeyStroke> = area_shortcuts()
                .into_iter()
                .filter(|(k, _)| k.group() == group)
                .map(|(_, s)| s)
                .collect();
            for (i, s) in area.iter().enumerate() {
                assert!(!area[i + 1..].contains(s), "{s:?} twice in {group:?}");
            }
        }
        // The Calendar's and Scheduled Tasks' keys as their panes take them
        // (views/calendar, views/tasks: ⌘⌫ also as ⌘Delete, ⌘S also as
        // ⌘Return in the editors).
        let shown = |k| describe(&area_stroke(k), true);
        assert_eq!(shown(AreaKey::CalendarEarlier), "⌘←");
        assert_eq!(shown(AreaKey::CalendarLater), "⌘→");
        assert_eq!(shown(AreaKey::CalendarToday), "⌘T");
        assert_eq!(shown(AreaKey::DeleteCalendarItem), "⌘⌫");
        assert_eq!(shown(AreaKey::SaveScheduledTask), "⌘S");
        assert_eq!(describe(&area_stroke(AreaKey::NewNote), true), "⌘N");
        assert_eq!(describe(&area_stroke(AreaKey::Link), true), "⌘K");
        assert_eq!(describe(&area_stroke(AreaKey::CodeBlock), true), "⌥⌘C");
        // The terminal: Terminal's ⌥⌘K Clear Scrollback, which no command
        // has (⌘K stays the palette, as the console leaves ⌘ chords to the
        // app); its Find, Copy, Paste and Select All are the Edit menu's.
        let clear = area_stroke(AreaKey::TerminalClearScrollback);
        assert_eq!(describe(&clear, true), "⌥⌘K");
        assert_eq!(fixed_conflict(&clear, None), None);
        assert!(default_shortcuts().iter().all(|s| s.stroke != clear));
        assert_eq!(
            area_stroke(AreaKey::TerminalFind),
            fixed_stroke(FixedCommand::FindInChat)
        );
        // A terminal's PDF window saves with ⌘S, as an editor does; no
        // command takes ⌘S everywhere.
        let save_pdf = area_stroke(AreaKey::SavePdf);
        assert_eq!(describe(&save_pdf, true), "⌘S");
        assert_eq!(fixed_conflict(&save_pdf, None), None);
        assert!(default_shortcuts().iter().all(|s| s.stroke != save_pdf));
        assert_eq!(shown(AreaKey::SendInRoom), "⌘↩");
        assert_eq!(shown(AreaKey::SaveHermesJob), "⌘↩");
        // Start Voice Call takes no chord the menus have.
        let call = default_shortcuts()
            .into_iter()
            .find(|s| s.action == ShortcutAction::VoiceCall)
            .unwrap();
        assert_eq!(describe(&call.stroke, true), "⌥⌘V");
        assert_eq!(fixed_conflict(&call.stroke, None), None);
        // Read Aloud beside Regenerate's ⌘R; Stop Speaking is the Mac's ⌘.
        let read_aloud = default_shortcuts()
            .into_iter()
            .find(|s| s.action == ShortcutAction::ReadAloud)
            .unwrap();
        assert_eq!(describe(&read_aloud.stroke, true), "⌥⌘R");
        assert_eq!(fixed_conflict(&read_aloud.stroke, None), None);
        assert_eq!(
            describe(&fixed_stroke(FixedCommand::StopSpeaking), true),
            "⌘."
        );
        // Go › Back and Forward are Finder's ⌘[ and ⌘].
        assert_eq!(describe(&fixed_stroke(FixedCommand::Back), true), "⌘[");
        assert_eq!(describe(&fixed_stroke(FixedCommand::Forward), true), "⌘]");
        assert_eq!(
            describe(&fixed_stroke(FixedCommand::GoToSection(3)), true),
            "⌘3"
        );
        // The way out of the terminal (whose Tab is the shell's): ⌥⌘` and
        // ⌥⌘~, which no command, default or terminal key takes.
        for (command, shown) in [
            (FixedCommand::NextArea, "⌥⌘`"),
            (FixedCommand::PreviousArea, "⌥⌘~"),
        ] {
            let stroke = fixed_stroke(command);
            assert_eq!(describe(&stroke, true), shown);
            assert_eq!(fixed_conflict(&stroke, None), Some(command));
            assert!(default_shortcuts().iter().all(|s| s.stroke != stroke));
            assert!(area_shortcuts().iter().all(|(_, s)| *s != stroke));
        }
        // The composer's larger editor and Ask Conduit.
        assert_eq!(
            describe(&fixed_stroke(FixedCommand::ExpandEditor), true),
            "⇧⌘E"
        );
        assert_eq!(
            describe(&fixed_stroke(FixedCommand::AskConduit), true),
            "⇧⌘A"
        );
        // Next and Previous Chat are ⌃⇥ and ⌃⇧⇥, as Safari's tabs.
        assert_eq!(describe(&fixed_stroke(FixedCommand::NextChat), true), "⌃⇥");
        assert_eq!(
            describe(&fixed_stroke(FixedCommand::PreviousChat), true),
            "⌃⇧⇥"
        );
    }

    #[test]
    fn fixed_chords_are_taken_but_settings_keeps_its_own() {
        let k = KeyStroke::new;
        assert_eq!(
            fixed_conflict(&k("r").primary(), Some(A::NewChat)),
            Some(FixedCommand::Regenerate)
        );
        assert_eq!(
            fixed_conflict(&k("=").primary(), None),
            Some(FixedCommand::ZoomIn)
        );
        assert_eq!(
            fixed_conflict(&k("q").primary(), Some(A::OpenPalette)),
            Some(FixedCommand::Quit)
        );
        // ⌘, is Open Settings' default as well as the fixed chord.
        assert_eq!(
            fixed_conflict(&k(",").primary(), Some(A::OpenSettings)),
            None
        );
        assert_eq!(
            fixed_conflict(&k(",").primary(), Some(A::NewChat)),
            Some(FixedCommand::Settings)
        );
        assert_eq!(fixed_conflict(&k("j").primary(), Some(A::NewChat)), None);
        // No default takes another command's fixed chord.
        for s in default_shortcuts() {
            assert_eq!(
                fixed_conflict(&s.stroke, Some(s.action)),
                None,
                "{:?}",
                s.action
            );
        }
        assert_eq!(fixed_stroke(FixedCommand::ZoomIn), k("+").primary());
    }

    /// The areas' keys are listed in the sidebar's order: in Hermes,
    /// Scheduled Agents stands under the switcher, above the rooms
    /// (sidebar_model's Hermes rows), then Notes, Terminal, Workspace,
    /// Calendar and Scheduled Tasks.
    #[test]
    fn the_areas_keys_follow_the_sidebar_order() {
        let areas: Vec<KeyGroup> = keyboard_groups()
            .into_iter()
            .map(|(g, _)| g)
            .skip_while(|g| *g != KeyGroup::Window)
            .skip(1)
            .collect();
        assert_eq!(
            areas,
            [
                KeyGroup::HermesJobs,
                KeyGroup::HermesRooms,
                KeyGroup::Notes,
                KeyGroup::Terminal,
                KeyGroup::Workspace,
                KeyGroup::Calendar,
                KeyGroup::ScheduledTasks,
            ]
        );
    }
}
