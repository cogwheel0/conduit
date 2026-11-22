//! The rebindable shortcuts: the table, its matching rules, the stored form
//! of a chord, and conflict detection, plus the bridge to GPUI key bindings.
//!
//! The table has 15 bindings; a 16th, `toggleSidePane`, waits for the
//! right-hand pane, which is post-v1. Only [`ShortcutAction::is_live`] ones
//! are bound to GPUI actions today; the rest keep their chords (rebindable
//! and conflict-checked) until a view binds them.
//!
//! Off the Mac ([`KeyOs`]) the primary modifier is Ctrl, no chord uses the
//! Windows or Super key, and none uses Ctrl+Alt, which Windows (and X
//! layouts) report for AltGr: Czech and Hungarian type @ with AltGr+V,
//! Polish ć with AltGr+C. Each ⌘ chord keeps its letter with Ctrl, except:
//!
//! | Mac | Windows | Linux | Why |
//! |---|---|---|---|
//! | ⌃⌘S Toggle Sidebar | Ctrl+Shift+S | F9 | ⌃ and ⌘ are both Ctrl; F9 is the Linux file managers' |
//! | ⌃⌘F Full Screen | F11 | F11 | as every Windows and Linux app |
//! | ⌃⇥, ⌃⇧⇥ Next and Previous Chat | Ctrl+Tab, Ctrl+Shift+Tab | the same | ⌃ is Ctrl |
//! | ⌥⌘↩, ⌥⌘⌫ Allow and Deny | Ctrl+Shift+Enter, Ctrl+Shift+Backspace | the same | AltGr; X ends the session on Ctrl+Alt+Backspace where that option is on |
//! | ⌥⌘R Read Aloud, ⌥⌘V Voice Call | Ctrl+Shift+R, Ctrl+Shift+P | the same | AltGr |
//! | ⌥⌘F Search Chats | Ctrl+Shift+F | the same | AltGr |
//! | ⌘G, ⇧⌘G Find Next and Previous | F3 and Ctrl+G, Shift+F3 and Ctrl+Shift+G | Ctrl+G and F3, … | Windows' and KDE's F3, GNOME's Ctrl+G |
//! | ⌘[, ⌘] Back and Forward | Alt+←, Alt+→ | the same | as browsers and file managers |
//! | ⌥⌘\`, ⌥⌘~ Next and Previous Area | F6, Shift+F6 | the same | Windows' and GTK's pane keys |
//! | ⌘⌫ Delete (a chat, an event, a task) | Delete | Delete | |
//! | ⌘Q Quit | not bound | Ctrl+Q | Windows closes with Alt+F4 |
//! | ⌘H, ⌥⌘H, ⌘M | not bound | not bound | hiding apps is the Mac's; Ctrl+M is KDE's Show Menubar |
//! | ⌘C, ⌘V, ⌘A, ⌘F, ⌥⌘K in a terminal | Ctrl+Shift+C, V, A, F, K | the same | Ctrl and a letter are the shell's ([`shell_chords`]) |
//! | ⌥⌘C Code Block, ⌥⇧⌘V Paste as Plain Text, in Notes | Ctrl+Shift+C, Ctrl+Shift+V | the same | AltGr |
//!
//! [`os_conflicts`] lists the chords the OS or a desktop may take first.

use std::collections::BTreeMap;

/// The platform a key table is for: the Mac's ⌘ chords, or the Ctrl ones of
/// Windows and Linux.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum KeyOs {
    Mac,
    Windows,
    Linux,
}

impl KeyOs {
    /// The one this build runs on.
    pub const CURRENT: Self = if cfg!(target_os = "macos") {
        Self::Mac
    } else if cfg!(target_os = "windows") {
        Self::Windows
    } else {
        Self::Linux
    };

    pub fn is_mac(self) -> bool {
        self == Self::Mac
    }
}

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
    /// it can fire while a field is being typed in. Off the Mac a function
    /// key types nothing either (F9 is Linux's sidebar key).
    pub fn is_chord(&self) -> bool {
        self.is_chord_on(KeyOs::CURRENT)
    }

    /// [`Self::is_chord`] for `os`.
    pub fn is_chord_on(&self, os: KeyOs) -> bool {
        self.has_modifier() || (!os.is_mac() && is_function_key(&self.key))
    }

    /// Holds ⌘, ⌥ or ⌃ (Ctrl or Alt off the Mac). Quick Ask's system-wide
    /// hotkey needs one on every OS: a bare F-key would take that key from
    /// every app.
    pub fn has_modifier(&self) -> bool {
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
    default_shortcuts_on(KeyOs::CURRENT)
}

/// [`default_shortcuts`] for `os` (see the module's table).
pub fn default_shortcuts_on(os: KeyOs) -> Vec<Shortcut> {
    use ShortcutAction as A;
    let mut table = mac_default_shortcuts();
    if !os.is_mac() {
        let k = KeyStroke::new;
        for s in &mut table {
            match s.action {
                A::ToggleSidebar if os == KeyOs::Linux => s.stroke = k("f9"),
                A::ToggleSidebar => s.stroke = k("s").primary().shift(),
                A::AllowRequest => s.stroke = k("enter").primary().shift(),
                A::DenyRequest => s.stroke = k("backspace").primary().shift(),
                A::ReadAloud => s.stroke = k("r").primary().shift(),
                A::VoiceCall => s.stroke = k("p").primary().shift(),
                _ => {}
            }
        }
    }
    table
}

fn mac_default_shortcuts() -> Vec<Shortcut> {
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
    if !mac && is_function_key(key) {
        return key.to_uppercase();
    }
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

/// F1 to F24.
fn is_function_key(key: &str) -> bool {
    key.strip_prefix('f')
        .and_then(|n| n.parse::<u8>().ok())
        .is_some_and(|n| (1..=24).contains(&n))
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

/// `stroke` as `os` binds it: off the Mac a stored ⌃ (from a Mac) is the
/// Ctrl that ⌘ is there too.
pub fn for_os(mut stroke: KeyStroke, os: KeyOs) -> KeyStroke {
    if !os.is_mac() && stroke.ctrl {
        stroke.ctrl = false;
        stroke.primary = true;
    }
    stroke
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
    apply_overrides_on(overrides, KeyOs::CURRENT)
}

/// [`apply_overrides`] for `os`.
pub fn apply_overrides_on(overrides: &BTreeMap<String, String>, os: KeyOs) -> Vec<Shortcut> {
    let defaults = default_shortcuts_on(os);
    let mut table: Vec<Shortcut> = defaults
        .iter()
        .cloned()
        .map(|s| {
            match overrides
                .get(s.action.name())
                .and_then(|e| decode(e))
                .map(|stroke| for_os(stroke, os))
            {
                Some(stroke) => Shortcut {
                    action: s.action,
                    // A chord keeps working while typing; a bare key must not.
                    while_typing: stroke.is_chord_on(os),
                    stroke,
                },
                None => s,
            }
        })
        .collect();
    if !os.is_mac() {
        // A Mac profile's ⌃J and ⌘J are both Ctrl+J here: the first keeps
        // it, and a later one goes back to its default, or to no chord when
        // another has that too.
        for i in 0..table.len() {
            let taken = |stroke: &KeyStroke, table: &[Shortcut]| {
                table
                    .iter()
                    .enumerate()
                    .any(|(j, s)| j != i && &s.stroke == stroke)
            };
            if !table[..i].iter().any(|s| s.stroke == table[i].stroke) {
                continue;
            }
            table[i] = if taken(&defaults[i].stroke, &table) {
                Shortcut {
                    stroke: KeyStroke::new(""),
                    while_typing: false,
                    ..defaults[i].clone()
                }
            } else {
                defaults[i].clone()
            };
        }
    }
    table
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
    fixed_shortcuts_on(KeyOs::CURRENT)
}

/// [`fixed_shortcuts`] for `os` (see the module's table).
pub fn fixed_shortcuts_on(os: KeyOs) -> Vec<(FixedCommand, KeyStroke)> {
    use FixedCommand as F;
    let table = mac_fixed_shortcuts();
    if os.is_mac() {
        return table;
    }
    let k = KeyStroke::new;
    let mut out = vec![];
    for (command, stroke) in table {
        let strokes = match command {
            F::Hide | F::HideOthers | F::Minimize => vec![],
            F::Quit if os == KeyOs::Windows => vec![],
            F::FullScreen => vec![k("f11")],
            F::NextChat => vec![k("tab").primary()],
            F::PreviousChat => vec![k("tab").primary().shift()],
            F::SearchChats => vec![k("f").primary().shift()],
            F::FindNext if os == KeyOs::Windows => vec![k("f3"), stroke],
            F::FindNext => vec![stroke, k("f3")],
            F::FindPrevious if os == KeyOs::Windows => vec![k("f3").shift(), stroke],
            F::FindPrevious => vec![stroke, k("f3").shift()],
            F::Back => vec![k("arrowleft").alt()],
            F::Forward => vec![k("arrowright").alt()],
            F::NextArea => vec![k("f6")],
            F::PreviousArea => vec![k("f6").shift()],
            F::DeleteChat => vec![k("delete")],
            _ => vec![stroke],
        };
        out.extend(strokes.into_iter().map(|s| (command, s)));
    }
    out
}

fn mac_fixed_shortcuts() -> Vec<(FixedCommand, KeyStroke)> {
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
    fixed_stroke_on(command, KeyOs::CURRENT)
}

/// [`fixed_stroke`] for `os`.
pub fn fixed_stroke_on(command: FixedCommand, os: KeyOs) -> KeyStroke {
    fixed_shortcuts_on(os)
        .into_iter()
        .find(|(c, _)| *c == command)
        .map(|(_, s)| s)
        .unwrap_or_else(|| KeyStroke::new(""))
}

/// The fixed command `stroke` belongs to, unless it stands beside `action`
/// (`None` for Quick Ask, which stands beside none).
pub fn fixed_conflict(stroke: &KeyStroke, action: Option<ShortcutAction>) -> Option<FixedCommand> {
    fixed_conflict_on(stroke, action, KeyOs::CURRENT)
}

/// [`fixed_conflict`] for `os`.
pub fn fixed_conflict_on(
    stroke: &KeyStroke,
    action: Option<ShortcutAction>,
    os: KeyOs,
) -> Option<FixedCommand> {
    fixed_shortcuts_on(os)
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
    area_shortcuts_on(KeyOs::CURRENT)
}

/// [`area_shortcuts`] for `os`: off the Mac a terminal's Find, Copy, Paste
/// and Select All take Shift as well, as the Linux terminals and Windows
/// Terminal write them, since Ctrl and a letter are the shell's.
pub fn area_shortcuts_on(os: KeyOs) -> Vec<(AreaKey, KeyStroke)> {
    use AreaKey as A;
    let mut table = mac_area_shortcuts();
    if !os.is_mac() {
        let k = KeyStroke::new;
        for (key, stroke) in &mut table {
            match key {
                A::TerminalFind | A::TerminalCopy | A::TerminalPaste | A::TerminalSelectAll => {
                    stroke.shift = true
                }
                A::TerminalClearScrollback => *stroke = k("k").primary().shift(),
                A::CodeBlock => *stroke = k("c").primary().shift(),
                A::DeleteCalendarItem | A::DeleteScheduledTask => *stroke = k("delete"),
                _ => {}
            }
        }
    }
    table
}

fn mac_area_shortcuts() -> Vec<(AreaKey, KeyStroke)> {
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
    area_stroke_on(key, KeyOs::CURRENT)
}

/// [`area_stroke`] for `os`.
pub fn area_stroke_on(key: AreaKey, os: KeyOs) -> KeyStroke {
    area_shortcuts_on(os)
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

    /// [`Self::table`] for `os`.
    pub fn table_on(&self, os: KeyOs) -> Vec<Shortcut> {
        apply_overrides_on(&self.overrides, os)
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
    to_gpui_on(stroke, KeyOs::CURRENT)
}

/// [`to_gpui`] for `os`. Off the Mac ⌃ and ⌘ are both Ctrl.
pub fn to_gpui_on(stroke: &KeyStroke, os: KeyOs) -> String {
    let mut parts = vec![];
    if os.is_mac() {
        if stroke.ctrl {
            parts.push("ctrl");
        }
        if stroke.primary {
            parts.push("cmd");
        }
    } else if stroke.primary || stroke.ctrl {
        parts.push("ctrl");
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
/// or a chord using Fn (which the table cannot store), or off the Mac the
/// Windows or Super key (the OS's own).
pub fn from_gpui(ks: &gpui_kit::Keystroke) -> Option<KeyStroke> {
    from_gpui_on(ks, KeyOs::CURRENT)
}

/// [`from_gpui`] for `os`.
pub fn from_gpui_on(ks: &gpui_kit::Keystroke, os: KeyOs) -> Option<KeyStroke> {
    let m = &ks.modifiers;
    if m.function || (!os.is_mac() && m.platform) {
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
        primary: if os.is_mac() { m.platform } else { m.control },
        shift: m.shift,
        alt: m.alt,
        ctrl: os.is_mac() && m.control,
    })
}

/// The modifiers held, as the shortcut table names them: `primary` is ⌘ on
/// the Mac and Ctrl elsewhere; `ctrl` is the other of the two, the Mac's ⌃
/// or the Windows or Super key, which no shortcut off the Mac uses.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Held {
    pub primary: bool,
    pub ctrl: bool,
    pub alt: bool,
    pub shift: bool,
}

impl Held {
    /// The primary modifier and no other: ⌘S, or Ctrl+S off the Mac.
    pub fn only_primary(self) -> bool {
        self.primary && !(self.ctrl || self.alt || self.shift)
    }
}

/// What `m` holds, on this build's platform.
pub fn held(m: &gpui_kit::Modifiers) -> Held {
    held_on(m, KeyOs::CURRENT)
}

/// [`held`] for `os`.
pub fn held_on(m: &gpui_kit::Modifiers, os: KeyOs) -> Held {
    let (primary, ctrl) = if os.is_mac() {
        (m.platform, m.control)
    } else {
        // Ctrl with Alt is how Windows reports AltGr, which types a
        // character (Polish AltGr+S is ś): never the primary modifier.
        (m.control && !m.alt, m.platform)
    };
    Held {
        primary,
        ctrl,
        alt: m.alt,
        shift: m.shift,
    }
}

/// The Ctrl chords a terminal's console gives the shell off the Mac, though
/// the app or GPUI Kit binds them elsewhere: Ctrl and a letter, and the
/// punctuation that types a control character (Ctrl+[ is Esc to vi, Ctrl+/
/// is readline's undo). Ctrl+Tab stays Next Chat. None on the Mac, where ⌘
/// and ⌃ are different keys.
pub fn shell_chords(os: KeyOs) -> Vec<KeyStroke> {
    if os.is_mac() {
        return vec![];
    }
    ('a'..='z')
        .map(String::from)
        .chain(["[", "]", "\\", "/", " "].map(String::from))
        .map(|key| KeyStroke::new(&key).primary())
        .collect()
}

/// The chords the app keeps while a terminal's console has the keyboard
/// (its interceptor sends every other key to the shell first): off the
/// Mac, those it binds where the console is (the table with `keymap`'s
/// overrides, New Chat's alias, Quick Ask's and the fixed chords, and the
/// terminal's own Edit keys) that hold Ctrl, Alt or a function key, less
/// the shell's ([`shell_chords`]). Keys like Esc, Tab and Return stay the
/// shell's, as on the Mac, where none is kept (the app's are ⌘ chords, which
/// the console never sends).
pub fn console_app_chords(
    keymap: &Keymap,
    quick_ask: Option<&KeyStroke>,
    os: KeyOs,
) -> Vec<KeyStroke> {
    if os.is_mac() {
        return vec![];
    }
    let shell = shell_chords(os);
    app_chords(keymap, quick_ask, os)
        .into_iter()
        .chain(
            area_shortcuts_on(os)
                .into_iter()
                .filter(|(k, _)| k.group() == KeyGroup::Terminal)
                .map(|(_, s)| s),
        )
        .filter(|s| (s.primary || s.alt || is_function_key(&s.key)) && !shell.contains(s))
        .collect()
}

/// Every chord the app binds everywhere on `os`: the table with `keymap`'s
/// overrides (the commands it carries out), New Chat's alias, Quick Ask's
/// and the fixed chords.
pub fn app_chords(keymap: &Keymap, quick_ask: Option<&KeyStroke>, os: KeyOs) -> Vec<KeyStroke> {
    keymap
        .table_on(os)
        .into_iter()
        .filter(|s| s.action.is_live() && s.while_typing)
        .map(|s| s.stroke)
        .chain([new_chat_alias()])
        // A Mac profile's ⌃⇧J is the Ctrl+Shift+J the menus bind here.
        .chain(quick_ask.cloned().map(|s| for_os(s, os)))
        .chain(fixed_shortcuts_on(os).into_iter().map(|(_, s)| s))
        .collect()
}

/// A key that deletes the selected item (a chat, an event, a task): ⌘⌫ or
/// ⌘⌦ on the Mac, Delete alone elsewhere.
pub fn deletes_item(key: &str, m: &gpui_kit::Modifiers) -> bool {
    deletes_item_on(key, m, KeyOs::CURRENT)
}

/// [`deletes_item`] for `os`.
pub fn deletes_item_on(key: &str, m: &gpui_kit::Modifiers, os: KeyOs) -> bool {
    if os.is_mac() {
        matches!(key, "backspace" | "delete") && held_on(m, os).only_primary()
    } else {
        key == "delete" && !m.modified()
    }
}

/// Chords the OS, the desktop or the keyboard layout may take before the
/// app sees them. No binding may take one ([`reserved_chords`]); these are
/// the ones the app binds anyway, each with why it stays.
pub fn os_conflicts(os: KeyOs) -> Vec<(&'static str, &'static str)> {
    match os {
        KeyOs::Mac => vec![],
        KeyOs::Windows => vec![
            (
                "ctrl-shift-f",
                "Microsoft Pinyin switches Simplified and Traditional Chinese with Ctrl+Shift+F \
                 while it is the input method: Search Chats.",
            ),
            (
                "ctrl-.",
                "Microsoft Pinyin switches Chinese and English punctuation with Ctrl+. while it \
                 is the input method: Stop Speaking.",
            ),
        ],
        KeyOs::Linux => vec![
            (
                "ctrl-shift-u",
                "GTK and IBus start a Unicode code point with Ctrl+Shift+U where an IBus engine \
                 is active: Notes' Mark as Checked.",
            ),
            (
                "ctrl-shift-e",
                "Some IBus versions start emoji typing with Ctrl+Shift+E: Expand Editor.",
            ),
        ],
    }
}

/// Chords the OS or desktop keeps for itself, which no binding may take.
pub fn reserved_chords(os: KeyOs) -> Vec<&'static str> {
    match os {
        KeyOs::Mac => vec!["cmd-tab", "cmd-space", "cmd-`", "cmd-alt-escape"],
        KeyOs::Windows => vec![
            "alt-f4",
            "alt-tab",
            "alt-escape",
            "alt-space",
            "ctrl-escape",
            "ctrl-shift-escape",
            "ctrl-alt-delete",
            "ctrl-space",
        ],
        KeyOs::Linux => vec![
            "alt-f1",
            "alt-f2",
            "alt-f4",
            "alt-tab",
            "alt-`",
            "alt-space",
            "ctrl-alt-backspace",
            "ctrl-alt-delete",
            "ctrl-alt-t",
            "ctrl-alt-l",
            "ctrl-alt-d",
            "ctrl-alt-tab",
            "ctrl-alt-left",
            "ctrl-alt-right",
            "ctrl-alt-up",
            "ctrl-alt-down",
            "ctrl-escape",
            "ctrl-f1",
            "ctrl-f2",
            "ctrl-f3",
            "ctrl-f4",
            "ctrl-space",
        ],
    }
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
        let t = default_shortcuts_on(KeyOs::Mac);
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
            resolve(
                &t,
                &for_os(KeyStroke::new("n").ctrl(), KeyOs::CURRENT),
                true
            ),
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
        // The Mac's own chords, as Settings › Keyboard writes them there.
        let area_stroke_mac = |k| area_stroke_on(k, KeyOs::Mac);
        let fixed_stroke_mac = |c| fixed_stroke_on(c, KeyOs::Mac);
        let fixed_conflict_mac = |s: &KeyStroke, a| fixed_conflict_on(s, a, KeyOs::Mac);
        // The Calendar's and Scheduled Tasks' keys as their panes take them
        // (views/calendar, views/tasks: ⌘⌫ also as ⌘Delete, ⌘S also as
        // ⌘Return in the editors).
        let shown = |k| describe(&area_stroke_mac(k), true);
        assert_eq!(shown(AreaKey::CalendarEarlier), "⌘←");
        assert_eq!(shown(AreaKey::CalendarLater), "⌘→");
        assert_eq!(shown(AreaKey::CalendarToday), "⌘T");
        assert_eq!(shown(AreaKey::DeleteCalendarItem), "⌘⌫");
        assert_eq!(shown(AreaKey::SaveScheduledTask), "⌘S");
        assert_eq!(describe(&area_stroke_mac(AreaKey::NewNote), true), "⌘N");
        assert_eq!(describe(&area_stroke_mac(AreaKey::Link), true), "⌘K");
        assert_eq!(describe(&area_stroke_mac(AreaKey::CodeBlock), true), "⌥⌘C");
        // The terminal: Terminal's ⌥⌘K Clear Scrollback, which no command
        // has (⌘K stays the palette, as the console leaves ⌘ chords to the
        // app); its Find, Copy, Paste and Select All are the Edit menu's.
        let clear = area_stroke_mac(AreaKey::TerminalClearScrollback);
        assert_eq!(describe(&clear, true), "⌥⌘K");
        assert_eq!(fixed_conflict_mac(&clear, None), None);
        assert!(
            default_shortcuts_on(KeyOs::Mac)
                .iter()
                .all(|s| s.stroke != clear)
        );
        assert_eq!(
            area_stroke_mac(AreaKey::TerminalFind),
            fixed_stroke_mac(FixedCommand::FindInChat)
        );
        // A terminal's PDF window saves with ⌘S, as an editor does; no
        // command takes ⌘S everywhere.
        let save_pdf = area_stroke_mac(AreaKey::SavePdf);
        assert_eq!(describe(&save_pdf, true), "⌘S");
        assert_eq!(fixed_conflict_mac(&save_pdf, None), None);
        assert!(
            default_shortcuts_on(KeyOs::Mac)
                .iter()
                .all(|s| s.stroke != save_pdf)
        );
        assert_eq!(shown(AreaKey::SendInRoom), "⌘↩");
        assert_eq!(shown(AreaKey::SaveHermesJob), "⌘↩");
        // Start Voice Call takes no chord the menus have.
        let call = default_shortcuts_on(KeyOs::Mac)
            .into_iter()
            .find(|s| s.action == ShortcutAction::VoiceCall)
            .unwrap();
        assert_eq!(describe(&call.stroke, true), "⌥⌘V");
        assert_eq!(fixed_conflict_mac(&call.stroke, None), None);
        // Read Aloud beside Regenerate's ⌘R; Stop Speaking is the Mac's ⌘.
        let read_aloud = default_shortcuts_on(KeyOs::Mac)
            .into_iter()
            .find(|s| s.action == ShortcutAction::ReadAloud)
            .unwrap();
        assert_eq!(describe(&read_aloud.stroke, true), "⌥⌘R");
        assert_eq!(fixed_conflict_mac(&read_aloud.stroke, None), None);
        assert_eq!(
            describe(&fixed_stroke_mac(FixedCommand::StopSpeaking), true),
            "⌘."
        );
        // Go › Back and Forward are Finder's ⌘[ and ⌘].
        assert_eq!(describe(&fixed_stroke_mac(FixedCommand::Back), true), "⌘[");
        assert_eq!(
            describe(&fixed_stroke_mac(FixedCommand::Forward), true),
            "⌘]"
        );
        assert_eq!(
            describe(&fixed_stroke_mac(FixedCommand::GoToSection(3)), true),
            "⌘3"
        );
        // The way out of the terminal (whose Tab is the shell's): ⌥⌘` and
        // ⌥⌘~, which no command, default or terminal key takes.
        for (command, shown) in [
            (FixedCommand::NextArea, "⌥⌘`"),
            (FixedCommand::PreviousArea, "⌥⌘~"),
        ] {
            let stroke = fixed_stroke_mac(command);
            assert_eq!(describe(&stroke, true), shown);
            assert_eq!(fixed_conflict_mac(&stroke, None), Some(command));
            assert!(
                default_shortcuts_on(KeyOs::Mac)
                    .iter()
                    .all(|s| s.stroke != stroke)
            );
            assert!(
                area_shortcuts_on(KeyOs::Mac)
                    .iter()
                    .all(|(_, s)| *s != stroke)
            );
        }
        // The composer's larger editor and Ask Conduit.
        assert_eq!(
            describe(&fixed_stroke_mac(FixedCommand::ExpandEditor), true),
            "⇧⌘E"
        );
        assert_eq!(
            describe(&fixed_stroke_mac(FixedCommand::AskConduit), true),
            "⇧⌘A"
        );
        // Next and Previous Chat are ⌃⇥ and ⌃⇧⇥, as Safari's tabs.
        assert_eq!(
            describe(&fixed_stroke_mac(FixedCommand::NextChat), true),
            "⌃⇥"
        );
        assert_eq!(
            describe(&fixed_stroke_mac(FixedCommand::PreviousChat), true),
            "⌃⇧⇥"
        );
    }

    #[test]
    fn fixed_chords_are_taken_but_settings_keeps_its_own() {
        let fixed_conflict_mac = |s: &KeyStroke, a| fixed_conflict_on(s, a, KeyOs::Mac);
        let k = KeyStroke::new;
        assert_eq!(
            fixed_conflict_mac(&k("r").primary(), Some(A::NewChat)),
            Some(FixedCommand::Regenerate)
        );
        assert_eq!(
            fixed_conflict_mac(&k("=").primary(), None),
            Some(FixedCommand::ZoomIn)
        );
        assert_eq!(
            fixed_conflict_mac(&k("q").primary(), Some(A::OpenPalette)),
            Some(FixedCommand::Quit)
        );
        // ⌘, is Open Settings' default as well as the fixed chord.
        assert_eq!(
            fixed_conflict_mac(&k(",").primary(), Some(A::OpenSettings)),
            None
        );
        assert_eq!(
            fixed_conflict_mac(&k(",").primary(), Some(A::NewChat)),
            Some(FixedCommand::Settings)
        );
        assert_eq!(
            fixed_conflict_mac(&k("j").primary(), Some(A::NewChat)),
            None
        );
        // No default takes another command's fixed chord.
        for s in default_shortcuts_on(KeyOs::Mac) {
            assert_eq!(
                fixed_conflict_mac(&s.stroke, Some(s.action)),
                None,
                "{:?}",
                s.action
            );
        }
        assert_eq!(
            fixed_stroke_on(FixedCommand::ZoomIn, KeyOs::Mac),
            k("+").primary()
        );
        // Off the Mac too, no default takes a fixed chord.
        for os in [KeyOs::Windows, KeyOs::Linux] {
            for s in default_shortcuts_on(os) {
                assert_eq!(
                    fixed_conflict_on(&s.stroke, Some(s.action), os),
                    None,
                    "{os:?} {:?}",
                    s.action
                );
            }
        }
    }

    /// Every chord the app binds everywhere on `os`, as GPUI writes it, with
    /// what it does: the rebindable defaults, New Chat's alias, Quick Ask's
    /// default and the fixed chords.
    fn bound_everywhere(os: KeyOs) -> Vec<(String, String)> {
        let mut out: Vec<(String, String)> = default_shortcuts_on(os)
            .into_iter()
            .map(|s| (to_gpui_on(&s.stroke, os), format!("{:?}", s.action)))
            .collect();
        out.push((to_gpui_on(&new_chat_alias(), os), "NewChat".into()));
        let quick_ask = decode(crate::prefs::DEFAULT_QUICK_ASK_SHORTCUT).unwrap();
        out.push((to_gpui_on(&quick_ask, os), "QuickAsk".into()));
        out.extend(
            fixed_shortcuts_on(os)
                .into_iter()
                .map(|(c, s)| (to_gpui_on(&s, os), format!("{c:?}"))),
        );
        out
    }

    /// The Mac's chords, as `menus::bind_keys` wrote them by hand before the
    /// table drove it.
    #[test]
    fn the_mac_table_binds_what_it_always_did() {
        let mac = |command| -> Vec<String> {
            fixed_shortcuts_on(KeyOs::Mac)
                .into_iter()
                .filter(|(c, _)| *c == command)
                .map(|(_, s)| to_gpui_on(&s, KeyOs::Mac))
                .collect()
        };
        use FixedCommand as F;
        let parse = |s: &str| gpui_kit::Keystroke::parse_with_os(s, gpui_kit::OperatingSystem::Mac);
        for (command, written) in [
            (F::Quit, vec!["cmd-q"]),
            (F::Settings, vec!["cmd-,"]),
            (F::Hide, vec!["cmd-h"]),
            (F::HideOthers, vec!["alt-cmd-h"]),
            (F::CloseWindow, vec!["cmd-w"]),
            (F::Minimize, vec!["cmd-m"]),
            (F::FullScreen, vec!["ctrl-cmd-f"]),
            (F::FindInChat, vec!["cmd-f"]),
            (F::FindNext, vec!["cmd-g"]),
            (F::FindPrevious, vec!["cmd-shift-g"]),
            (F::SearchChats, vec!["alt-cmd-f"]),
            (F::NewTemporaryChat, vec!["shift-cmd-n"]),
            (F::Regenerate, vec!["cmd-r"]),
            (F::StopSpeaking, vec!["cmd-."]),
            (F::ExpandEditor, vec!["shift-cmd-e"]),
            (F::AskConduit, vec!["shift-cmd-a"]),
            (F::ChatSettings, vec!["cmd-i"]),
            (F::PreviousChat, vec!["ctrl-shift-tab"]),
            (F::NextChat, vec!["ctrl-tab"]),
            (F::ActualSize, vec!["cmd-0"]),
            (F::ZoomIn, vec!["cmd-+", "cmd-="]),
            (F::ZoomOut, vec!["cmd--"]),
            (F::DeleteChat, vec!["cmd-backspace"]),
            (F::Back, vec!["cmd-["]),
            (F::Forward, vec!["cmd-]"]),
            (F::GoToSection(1), vec!["cmd-1"]),
            (F::GoToSection(8), vec!["cmd-8"]),
            (F::NextArea, vec!["alt-cmd-`"]),
            (F::PreviousArea, vec!["alt-cmd-~"]),
        ] {
            let ours: Vec<_> = mac(command).iter().map(|s| parse(s).unwrap()).collect();
            let theirs: Vec<_> = written.iter().map(|s| parse(s).unwrap()).collect();
            assert_eq!(ours, theirs, "{command:?}");
        }
        assert_eq!(
            to_gpui_on(
                &area_stroke_on(AreaKey::TerminalClearScrollback, KeyOs::Mac),
                KeyOs::Mac
            ),
            "cmd-alt-k"
        );
        for key in [
            AreaKey::TerminalCopy,
            AreaKey::TerminalPaste,
            AreaKey::TerminalSelectAll,
            AreaKey::TerminalFind,
        ] {
            assert!(!area_stroke_on(key, KeyOs::Mac).shift, "{key:?}");
        }
        assert!(shell_chords(KeyOs::Mac).is_empty());
        assert_eq!(
            default_shortcuts_on(KeyOs::Mac),
            mac_default_shortcuts(),
            "the Mac's defaults"
        );
    }

    /// Off the Mac every ⌘ chord is a Ctrl one; nothing lands on the Windows
    /// or Super key, nothing on Ctrl+Alt (AltGr: Czech and Hungarian type @
    /// with AltGr+V), nothing on a chord the OS keeps, and no two commands
    /// share a chord.
    #[test]
    fn off_the_mac_every_chord_is_a_ctrl_chord_and_none_collide() {
        let unparse = |chord: &str| {
            gpui_kit::Keystroke::parse_with_os(chord, gpui_kit::OperatingSystem::Linux)
                .unwrap()
                .unparse(gpui_kit::OperatingSystem::Linux)
        };
        for os in [KeyOs::Windows, KeyOs::Linux] {
            let mut bound = bound_everywhere(os);
            bound.extend(
                area_shortcuts_on(os)
                    .into_iter()
                    .map(|(k, s)| (to_gpui_on(&s, os), format!("{k:?}"))),
            );
            for (chord, what) in &bound {
                let ks =
                    gpui_kit::Keystroke::parse_with_os(chord, gpui_kit::OperatingSystem::Linux)
                        .unwrap();
                assert!(!ks.modifiers.platform, "{os:?}: {what} on {chord}");
                assert!(
                    !(ks.modifiers.control && ks.modifiers.alt),
                    "{os:?}: {what} on {chord}, AltGr's"
                );
            }
            let mut seen: BTreeMap<String, String> = BTreeMap::new();
            for (chord, what) in bound_everywhere(os) {
                let parsed = unparse(&chord);
                if let Some(other) = seen.get(&parsed) {
                    // Open Settings' default is ⌘, as Settings' own.
                    let same = [other.as_str(), what.as_str()] == ["OpenSettings", "Settings"]
                        || *other == what;
                    assert!(same, "{os:?}: {other} and {what} both on {parsed}");
                }
                seen.insert(parsed, what);
            }
            for reserved in reserved_chords(os) {
                let reserved = unparse(reserved);
                assert!(
                    !seen.contains_key(&reserved),
                    "{os:?}: {} takes the system's {reserved}",
                    seen[&reserved]
                );
            }
        }
    }

    #[test]
    fn the_macs_chords_off_the_mac() {
        use FixedCommand as F;
        let pair = |a: &str, b: &str| (a.to_string(), b.to_string());
        for os in [KeyOs::Windows, KeyOs::Linux] {
            let default = |a| {
                let s = default_shortcuts_on(os)
                    .into_iter()
                    .find(|s| s.action == a)
                    .unwrap()
                    .stroke;
                (to_gpui_on(&s, os), describe(&s, false))
            };
            let fixed = |c| -> Vec<(String, String)> {
                fixed_shortcuts_on(os)
                    .into_iter()
                    .filter(|(f, _)| *f == c)
                    .map(|(_, s)| (to_gpui_on(&s, os), describe(&s, false)))
                    .collect()
            };
            assert_eq!(
                default(A::AllowRequest),
                pair("ctrl-shift-enter", "Ctrl+Shift+Enter")
            );
            assert_eq!(
                default(A::DenyRequest),
                pair("ctrl-shift-backspace", "Ctrl+Shift+Backspace")
            );
            assert_eq!(default(A::NewChat), pair("ctrl-n", "Ctrl+N"));
            assert_eq!(default(A::ReadAloud), pair("ctrl-shift-r", "Ctrl+Shift+R"));
            assert_eq!(default(A::VoiceCall), pair("ctrl-shift-p", "Ctrl+Shift+P"));
            assert_eq!(fixed(F::FullScreen), vec![pair("f11", "F11")]);
            assert_eq!(fixed(F::NextChat), vec![pair("ctrl-tab", "Ctrl+Tab")]);
            assert_eq!(
                fixed(F::PreviousChat),
                vec![pair("ctrl-shift-tab", "Ctrl+Shift+Tab")]
            );
            assert_eq!(
                fixed(F::SearchChats),
                vec![pair("ctrl-shift-f", "Ctrl+Shift+F")]
            );
            assert_eq!(fixed(F::FindInChat), vec![pair("ctrl-f", "Ctrl+F")]);
            assert_eq!(fixed(F::Back), vec![pair("alt-left", "Alt+←")]);
            assert_eq!(fixed(F::Forward), vec![pair("alt-right", "Alt+→")]);
            assert_eq!(fixed(F::NextArea), vec![pair("f6", "F6")]);
            assert_eq!(fixed(F::PreviousArea), vec![pair("shift-f6", "Shift+F6")]);
            assert_eq!(fixed(F::DeleteChat), vec![pair("delete", "Delete")]);
            for mac_only in [F::Hide, F::HideOthers, F::Minimize] {
                assert!(fixed(mac_only).is_empty(), "{mac_only:?}");
            }
            // A terminal's Edit commands take Shift, as the shell has Ctrl
            // and a letter; Notes' Ctrl+Alt ones take Shift for AltGr.
            let area = |k| to_gpui_on(&area_stroke_on(k, os), os);
            assert_eq!(area(AreaKey::TerminalCopy), "ctrl-shift-c");
            assert_eq!(area(AreaKey::TerminalPaste), "ctrl-shift-v");
            assert_eq!(area(AreaKey::TerminalSelectAll), "ctrl-shift-a");
            assert_eq!(area(AreaKey::TerminalFind), "ctrl-shift-f");
            assert_eq!(area(AreaKey::TerminalClearScrollback), "ctrl-shift-k");
            assert_eq!(area(AreaKey::CodeBlock), "ctrl-shift-c");
            assert_eq!(area(AreaKey::DeleteCalendarItem), "delete");
            assert_eq!(area(AreaKey::Bold), "ctrl-b");
            let shell: Vec<String> = shell_chords(os).iter().map(|s| to_gpui_on(s, os)).collect();
            for chord in [
                "ctrl-c",
                "ctrl-r",
                "ctrl-w",
                "ctrl-k",
                "ctrl-[",
                "ctrl-/",
                "ctrl-space",
            ] {
                assert!(shell.iter().any(|s| s == chord), "{os:?}: {chord}");
            }
            assert!(
                !shell
                    .iter()
                    .any(|s| s == "ctrl-tab" || s == "f6" || s == "alt-left")
            );
        }
        // Per OS: the sidebar is Linux's F9 and Windows' Ctrl+Shift+S; Find
        // Next is Windows' F3 first, GNOME's Ctrl+G first; Windows quits
        // with Alt+F4 alone.
        let first = |os, c| {
            fixed_shortcuts_on(os)
                .into_iter()
                .find(|(f, _)| *f == c)
                .map(|(_, s)| to_gpui_on(&s, os))
        };
        let sidebar = |os| {
            let s = default_shortcuts_on(os)
                .into_iter()
                .find(|s| s.action == A::ToggleSidebar)
                .unwrap();
            assert!(s.stroke.is_chord_on(os) && s.while_typing);
            to_gpui_on(&s.stroke, os)
        };
        assert_eq!(sidebar(KeyOs::Linux), "f9");
        assert_eq!(sidebar(KeyOs::Windows), "ctrl-shift-s");
        assert_eq!(first(KeyOs::Windows, F::FindNext).as_deref(), Some("f3"));
        assert_eq!(first(KeyOs::Linux, F::FindNext).as_deref(), Some("ctrl-g"));
        assert_eq!(first(KeyOs::Windows, F::Quit), None);
        assert_eq!(first(KeyOs::Linux, F::Quit).as_deref(), Some("ctrl-q"));
        // F9 is a chord off the Mac (it types nothing), a bare key there.
        assert!(KeyStroke::new("f9").is_chord_on(KeyOs::Linux));
        assert!(!KeyStroke::new("f9").is_chord_on(KeyOs::Mac));
    }

    /// While a terminal has the keyboard off the Mac, the app keeps its own
    /// chords (Ctrl+Shift, Alt, the F-keys it binds, Ctrl with a digit or
    /// punctuation) and the shell gets Ctrl and a letter, and Esc, Tab and
    /// the F-keys the app doesn't bind (htop's F10). The Mac keeps none.
    #[test]
    fn a_terminal_lets_the_apps_chords_through_and_keeps_the_shells() {
        let quick_ask = decode(crate::prefs::DEFAULT_QUICK_ASK_SHORTCUT).unwrap();
        assert!(console_app_chords(&Keymap::default(), Some(&quick_ask), KeyOs::Mac).is_empty());
        for os in [KeyOs::Windows, KeyOs::Linux] {
            let app: Vec<String> = console_app_chords(&Keymap::default(), Some(&quick_ask), os)
                .iter()
                .map(|s| to_gpui_on(s, os))
                .collect();
            let keeps = |chord: &str| app.iter().any(|a| a == chord);
            for chord in [
                "ctrl-shift-n",
                "ctrl-shift-c",
                "ctrl-shift-v",
                "ctrl-shift-k",
                "ctrl-shift-space",
                "f6",
                "shift-f6",
                "f3",
                "f11",
                "alt-left",
                "ctrl-1",
                "ctrl-,",
                "ctrl-tab",
            ] {
                assert!(keeps(chord), "{os:?}: the app keeps {chord}");
            }
            for chord in [
                "ctrl-r",
                "ctrl-c",
                "ctrl-f",
                "ctrl-w",
                "ctrl-k",
                "ctrl-[",
                "escape",
                "shift-escape",
                "tab",
                "f1",
                "f10",
            ] {
                assert!(!keeps(chord), "{os:?}: the shell keeps {chord}");
            }
        }
        // A Mac profile's Quick Ask (⌃⇧J) is Ctrl+Shift+J here, the app's,
        // not a line feed for the shell.
        let mac_quick_ask = decode("ctrl+shift+j").unwrap();
        let app = console_app_chords(&Keymap::default(), Some(&mac_quick_ask), KeyOs::Linux);
        assert!(app.contains(&KeyStroke::new("j").primary().shift()));
        // A rebound chord moves with the user's keymap.
        let k = Keymap::new(BTreeMap::from([("newChat".into(), "mod+shift+j".into())]));
        let app = console_app_chords(&k, None, KeyOs::Linux);
        assert!(app.contains(&KeyStroke::new("j").primary().shift()));
    }

    /// Windows reports AltGr as Ctrl+Alt: off the Mac that is never the
    /// primary modifier, so AltGr+S (ś) types rather than saves. A recorded
    /// chord keeps what was pressed.
    #[test]
    fn altgr_is_never_the_primary_modifier_off_the_mac() {
        let ks = |s: &'static str| gpui_kit::Keystroke::parse(s).unwrap();
        for os in [KeyOs::Windows, KeyOs::Linux] {
            assert!(!held_on(&ks("ctrl-alt-s").modifiers, os).primary, "{os:?}");
            assert!(held_on(&ks("ctrl-s").modifiers, os).primary, "{os:?}");
            assert!(held_on(&ks("ctrl-shift-s").modifiers, os).primary, "{os:?}");
            assert_eq!(
                from_gpui_on(&ks("ctrl-alt-s"), os),
                Some(KeyStroke::new("s").primary().alt())
            );
        }
        assert!(held_on(&ks("cmd-alt-s").modifiers, KeyOs::Mac).primary);
    }

    /// A Mac profile's ⌃J and ⌘J are one chord off the Mac: the first
    /// command keeps it, the other goes back to its default (or to none
    /// when that is taken). The Mac keeps both.
    #[test]
    fn a_mac_profiles_chords_that_meet_off_the_mac_do_not_collide() {
        let overrides = BTreeMap::from([
            ("newChat".to_string(), "ctrl+j".to_string()),
            ("openPalette".to_string(), "mod+j".to_string()),
        ]);
        let k = Keymap::new(overrides);
        let stroke = |table: &[Shortcut], a| {
            table
                .iter()
                .find(|s| s.action == a)
                .map(|s| s.stroke.clone())
                .unwrap()
        };
        let mac = k.table_on(KeyOs::Mac);
        assert_eq!(stroke(&mac, A::NewChat), KeyStroke::new("j").ctrl());
        assert_eq!(stroke(&mac, A::OpenPalette), KeyStroke::new("j").primary());
        for os in [KeyOs::Windows, KeyOs::Linux] {
            let t = k.table_on(os);
            assert_eq!(stroke(&t, A::NewChat), KeyStroke::new("j").primary());
            assert_eq!(stroke(&t, A::OpenPalette), KeyStroke::new("k").primary());
            let mut chords: Vec<_> = t.iter().map(|s| &s.stroke).collect();
            let n = chords.len();
            chords.sort_by_key(|s| encode(s));
            chords.dedup();
            assert_eq!(chords.len(), n, "{os:?}: a chord twice");
        }
        // The default taken too: the later command has no chord.
        let k = Keymap::new(BTreeMap::from([
            ("newChat".to_string(), "ctrl+j".to_string()),
            ("openPalette".to_string(), "mod+j".to_string()),
            ("focusComposer".to_string(), "mod+k".to_string()),
        ]));
        let t = k.table_on(KeyOs::Linux);
        assert_eq!(stroke(&t, A::OpenPalette), KeyStroke::new(""));
        assert!(
            !t.iter()
                .find(|s| s.action == A::OpenPalette)
                .unwrap()
                .while_typing
        );
    }

    /// Deleting the selected item: ⌘⌫ on the Mac, Delete alone elsewhere.
    #[test]
    fn delete_is_the_platforms_own() {
        let ks = |s: &'static str| gpui_kit::Keystroke::parse(s).unwrap();
        let deletes = |s, os| {
            let k = ks(s);
            deletes_item_on(&k.key, &k.modifiers, os)
        };
        assert!(deletes("cmd-backspace", KeyOs::Mac));
        assert!(!deletes("delete", KeyOs::Mac));
        assert!(deletes("delete", KeyOs::Windows));
        assert!(!deletes("ctrl-backspace", KeyOs::Linux));
        assert!(!deletes("shift-delete", KeyOs::Linux));
    }

    /// One area's keys share no chord off the Mac either.
    #[test]
    fn an_areas_keys_stay_apart_off_the_mac() {
        for os in [KeyOs::Windows, KeyOs::Linux] {
            let all = area_shortcuts_on(os);
            for (i, (a, s)) in all.iter().enumerate() {
                for (b, t) in &all[i + 1..] {
                    assert!(
                        a.group() != b.group() || s != t,
                        "{os:?}: {a:?} and {b:?} both on {s:?}"
                    );
                }
            }
        }
    }

    /// A pressed chord reads back as the table writes it: Ctrl is primary
    /// off the Mac, and the Windows or Super key is never recorded.
    #[test]
    fn a_pressed_chord_reads_by_the_platforms_primary_modifier() {
        let ks = |s: &'static str| gpui_kit::Keystroke::parse(s).unwrap();
        assert_eq!(
            from_gpui_on(&ks("ctrl-shift-s"), KeyOs::Linux),
            Some(KeyStroke::new("s").primary().shift())
        );
        assert_eq!(from_gpui_on(&ks("cmd-k"), KeyOs::Windows), None);
        assert_eq!(
            from_gpui_on(&ks("cmd-k"), KeyOs::Mac),
            Some(KeyStroke::new("k").primary())
        );
        assert_eq!(
            from_gpui_on(&ks("ctrl-cmd-s"), KeyOs::Mac),
            Some(KeyStroke::new("s").primary().ctrl())
        );
        let held = |s: &'static str, os| held_on(&ks(s).modifiers, os);
        assert!(held("cmd-s", KeyOs::Mac).only_primary());
        assert!(!held("ctrl-s", KeyOs::Mac).only_primary());
        assert!(held("ctrl-s", KeyOs::Windows).only_primary());
        assert!(!held("cmd-s", KeyOs::Linux).only_primary());
        assert!(!held("ctrl-cmd-s", KeyOs::Linux).only_primary());
        assert!(held("ctrl-shift-s", KeyOs::Linux).primary);
        // A Mac override with ⌃ read off the Mac stays a Ctrl chord, never
        // a bare key.
        assert_eq!(
            to_gpui_on(&KeyStroke::new("tab").ctrl(), KeyOs::Linux),
            "ctrl-tab"
        );
        // ... and conflicts with the Ctrl chord it is there.
        let mac_stored = KeyStroke::new("s").primary().ctrl();
        assert_eq!(
            for_os(mac_stored.clone(), KeyOs::Windows),
            KeyStroke::new("s").primary()
        );
        assert_eq!(for_os(mac_stored.clone(), KeyOs::Mac), mac_stored);
    }

    /// The conflicts listed for the OS are the app's chords (the list stays
    /// true as the table changes).
    #[test]
    fn the_listed_os_conflicts_are_chords_the_app_binds() {
        for os in [KeyOs::Windows, KeyOs::Linux] {
            let mut chords: Vec<String> =
                bound_everywhere(os).into_iter().map(|(c, _)| c).collect();
            chords.extend(area_shortcuts_on(os).iter().map(|(_, s)| to_gpui_on(s, os)));
            let conflicts = os_conflicts(os);
            assert!(!conflicts.is_empty(), "{os:?}");
            for (chord, why) in conflicts {
                assert!(!why.is_empty());
                assert!(
                    chords.iter().any(|c| c.starts_with(chord)),
                    "{os:?}: {chord} is not bound"
                );
            }
        }
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
