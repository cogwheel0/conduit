//! View models: the plain data the views draw.
//!
//! The app fills these from protocol DTOs (sidebar from `chats.list`,
//! messages from `chats.get` + `turn.blocks`); the gallery fills them by hand.
//! Nothing here knows about either source.

use gpui_kit::SharedString;

/// One chat in the sidebar or the palette.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct ChatRow {
    pub id: SharedString,
    pub title: SharedString,
    /// Short relative time ("2h", "Mon"), already formatted.
    pub time: SharedString,
    /// The same time spelled out for VoiceOver ("2 hours ago").
    pub time_spoken: SharedString,
    pub pinned: bool,
    /// A reply is streaming into this chat.
    pub streaming: bool,
    /// Draw a running reply as a spinner (a Hermes session's row, as the
    /// phone's), not the streaming dot.
    pub working: bool,
    /// The spinner stands still (Reduce Motion).
    pub reduce_motion: bool,
    /// What VoiceOver adds after the title while streaming ("Answering");
    /// English when unset.
    pub status: Option<SharedString>,
    /// What VoiceOver always adds after the title ("Read-only" for another
    /// user's chat in a shared folder).
    pub note: Option<SharedString>,
    /// Something arrived since it was read, or it was marked unread: a dot
    /// in the status column, as the phone's unread column has (never on the
    /// open chat). VoiceOver hears `unread_spoken` after the title.
    pub unread: bool,
    pub unread_spoken: Option<SharedString>,
}

impl ChatRow {
    pub fn new(
        id: impl Into<SharedString>,
        title: impl Into<SharedString>,
        time: impl Into<SharedString>,
    ) -> Self {
        let time = time.into();
        Self {
            id: id.into(),
            title: title.into(),
            time_spoken: time.clone(),
            time,
            ..Default::default()
        }
    }
    pub fn spoken(mut self, time: impl Into<SharedString>) -> Self {
        self.time_spoken = time.into();
        self
    }
    pub fn pinned(mut self) -> Self {
        self.pinned = true;
        self
    }
    pub fn streaming(mut self) -> Self {
        self.streaming = true;
        self
    }
}

/// A folder and the chats filed in it.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct FolderRow {
    pub id: SharedString,
    pub name: SharedString,
    pub expanded: bool,
    pub chats: Vec<ChatRow>,
}

/// A date group ("Today", "Yesterday", …) of unpinned, unfiled chats.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct ChatGroup {
    pub label: SharedString,
    pub chats: Vec<ChatRow>,
}

/// Sync status shown in the sidebar footer.
#[derive(Clone, Debug, PartialEq)]
pub enum SyncState {
    Synced { detail: SharedString },
    Syncing { detail: SharedString },
    Offline { detail: SharedString },
}

/// The signed-in account, for the sidebar footer and the Accounts page.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Account {
    pub id: SharedString,
    pub name: SharedString,
    pub email: SharedString,
    /// Server host or backend label ("chat.example.org", "Direct").
    pub server: SharedString,
    pub backend: Backend,
    pub active: bool,
    /// The saved session expired; the account needs a fresh sign-in.
    pub needs_sign_in: bool,
}

impl Account {
    pub fn initials(&self) -> String {
        self.name
            .split_whitespace()
            .filter_map(|w| w.chars().next())
            .take(2)
            .collect::<String>()
            .to_uppercase()
    }
}

/// Which backend a connection talks to.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum Backend {
    #[default]
    OpenWebUi,
    Direct,
    Hermes,
    LibreChat,
}

impl Backend {
    pub fn label(self) -> &'static str {
        match self {
            Self::OpenWebUi => "Open WebUI",
            Self::Direct => "Direct connection",
            Self::Hermes => "Hermes",
            Self::LibreChat => "LibreChat",
        }
    }
}

/// Everything the sidebar shows.
#[derive(Clone, Debug, PartialEq)]
pub struct SidebarModel {
    pub pinned: Vec<ChatRow>,
    pub folders: Vec<FolderRow>,
    pub groups: Vec<ChatGroup>,
    pub selected: Option<SharedString>,
    /// Row drawn hovered, with its actions (the app passes the real hover).
    pub hovered: Option<SharedString>,
    /// Row a context menu is open for (drawn with a focus outline).
    pub context_target: Option<SharedString>,
    pub sync: SyncState,
    pub account: Account,
}

/// Status of a tool call or code run.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RunStatus {
    Running,
    Done,
    Failed,
}

/// A web source behind a citation.
#[derive(Clone, Debug, PartialEq)]
pub struct Source {
    pub n: u32,
    pub title: SharedString,
    pub host: SharedString,
}

/// One typed block of an assistant message (the protocol's
/// `MessageBlockDto` kinds).
#[derive(Clone, Debug, PartialEq)]
pub enum Block {
    /// Markdown, already normalised by the daemon.
    Text(SharedString),
    Reasoning {
        /// "Thought for 8 seconds" / "Thinking…".
        summary: SharedString,
        body: SharedString,
        streaming: bool,
        expanded: bool,
    },
    ToolCall {
        /// Human title: "Searched the web".
        title: SharedString,
        /// One-line detail: the query, the file, the command.
        detail: SharedString,
        /// Tool id shown when expanded (`web_search`).
        tool: SharedString,
        arguments: Option<SharedString>,
        result: Option<SharedString>,
        status: RunStatus,
        expanded: bool,
    },
    CodeInterpreter {
        language: SharedString,
        code: SharedString,
        output: Option<SharedString>,
        status: RunStatus,
        expanded: bool,
    },
    Status {
        text: SharedString,
        done: bool,
    },
    Citations(Vec<Source>),
    FollowUps(Vec<SharedString>),
}

/// An assistant reply.
#[derive(Clone, Debug, PartialEq)]
pub struct AssistantMessage {
    pub id: SharedString,
    pub model: SharedString,
    pub time: SharedString,
    pub blocks: Vec<Block>,
    pub streaming: bool,
    /// Thumbs up (`Some(true)`) or down.
    pub rating: Option<bool>,
    /// (current, total) when the reply has been regenerated.
    pub version: Option<(usize, usize)>,
    /// Draw the action row (always for the last reply; on hover otherwise).
    pub show_actions: bool,
}

/// A file attached to a user message.
#[derive(Clone, Debug, PartialEq)]
pub struct Attachment {
    pub name: SharedString,
    pub detail: SharedString,
    pub image: bool,
    /// Upload progress 0–1 while uploading (composer only).
    pub progress: Option<f32>,
}

/// A user message.
#[derive(Clone, Debug, PartialEq)]
pub struct UserMessage {
    pub id: SharedString,
    pub author: SharedString,
    pub initials: SharedString,
    pub text: SharedString,
    pub time: SharedString,
    pub version: Option<(usize, usize)>,
    pub attachments: Vec<Attachment>,
    /// Draw the hover actions (copy, edit).
    pub show_actions: bool,
}

/// A model in the picker.
#[derive(Clone, Debug, PartialEq)]
pub struct ModelOption {
    pub id: SharedString,
    pub name: SharedString,
    /// Provider or connection ("Open WebUI", "Direct · Local").
    pub provider: SharedString,
    pub pinned: bool,
}
