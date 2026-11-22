//! The main window's sidebar over [`ChatListStore`].
//!
//! * **Rows.** The list is sorted by [`sidebar_model`] and flattened into
//!   rows that a GPUI Kit virtual list draws, so only what is on screen is
//!   laid out (5,000 chats scroll as smoothly as 50). Rows follow the
//!   density's height; the flat list is rebuilt only when the store, the
//!   density or the day changes.
//! * **Rows act.** A click opens the chat ([`NavigationStore::open`]);
//!   hover shows "…" in the date's place; a right click opens a native menu
//!   ([`ChatMenu`]) with pin, rename, share, move to folder, archive, select
//!   and delete; a row dragged onto a folder moves it there (onto a date
//!   section, out of any folder). Rename is inline; delete asks with a
//!   native sheet.
//! * **Folders** are made, renamed and deleted here, as Finder's: New Folder
//!   (File menu, the Folders heading's "+", or a folder's New Subfolder)
//!   adds a row whose name is edited in place and made on Return; Rename…
//!   (or Return on a selected folder) edits the name in place; Delete
//!   Folder… (or ⌘⌫) asks first, and says the chats in it are kept. Another
//!   user's folder offers only what its grant allows.
//! * **Multiple selection** (when the server supports `chats.bulk`), as
//!   Mail's and Finder's lists: ⌘-click adds or removes a chat, ⇧-click (or
//!   ⇧↑/⇧↓) takes in the range from the anchor; the selected rows draw as
//!   the selection, and the bar above the list, their context menu, ⌘⌫ and
//!   the Chat menu's Archive and Delete… act on all of them. "Select Chats…"
//!   is the same selection with a checkbox on every row (the fallback for
//!   anyone not using modifier keys).
//! * **Search** replaces the list with `chats.search` hits as you type,
//!   on the list's own rows, the matched words marked as the palette marks
//!   them.
//! * **Edges.** The list fades out under the search field and into the
//!   footer's rule instead of cutting rows off: on the translucent sidebar
//!   by a Core Animation mask on the window's content (`ListEdges`),
//!   which shows the real material through; on a solid one, by painting its
//!   colour.
//! * The open chat is highlighted, and its folders open and the list
//!   scrolls to it when it is chosen elsewhere (the palette).
//! * **Areas.** With more than one area to show (an Open WebUI account
//!   with notes or channels, Hermes beside chats), each is a section under
//!   a Finder-style heading: Chats (all of the above), Hermes, Notes,
//!   Terminal, Channels, Workspace, Calendar and Scheduled Tasks, in the
//!   phone's tab order with the Mac's own sections after. A heading closes
//!   its section (the chevron shows on hover, ← and → close and open it),
//!   and what is closed is kept per account ([`SectionsStore`]). A long
//!   list shows its first few and Show All. An item opens its area's pane
//!   ([`crate::views::panes`]).
//!
//! Every row and control carries an AccessKit role and label.
//!
//! [`SectionsStore`]: crate::stores::sections::SectionsStore
//!
//! [`ChatListStore`]: crate::stores::chat_list::ChatListStore
//! [`NavigationStore::open`]: crate::stores::navigation::NavigationStore::open
//! [`sidebar_model`]: super::sidebar_model

#[cfg(target_os = "macos")]
use std::cell::RefCell;
use std::collections::BTreeSet;
use std::rc::Rc;
use std::time::Duration;

use chrono::{DateTime, Local, NaiveDate};
use conduit_components::ActiveConduitTheme as _;
use conduit_components::assets::{IconName, icon};
use conduit_components::theme::{ConduitTheme, SidebarStyle, with_alpha};
use conduit_components::views::focus::{on_selection, selection_fill};
use conduit_components::views::kit::{Button, ClickHandler, IconButton, bare_input};
use conduit_components::views::model::{Account, Backend, ChatRow, SyncState};
use conduit_components::views::palette::{find_words, match_highlight};
use conduit_components::views::sidebar::{
    AREA_GAP, FaceLine, FolderLine, ItemLine, ROW_ACTION_SLOT, ROW_CONTENT_INSET,
    ROW_STATUS_GUTTER, RowAction, RowState, SECTION_HEADER_HEIGHT, SidebarFrame, area_header,
    chat_row, face_row, folder_row, item_row, more_row, quiet_section_header, section_header,
};
use conduit_protocol::{
    BulkChatAction, ChatSearchHit, ChatSummary, FolderSummary, HermesBotDto, HermesRoomDto,
    HermesSessionDto, NoticeLevel,
};
use gpui_kit::component::input::{InputEvent, InputState};
use gpui_kit::component::native_menu::NativeMenu;
use gpui_kit::component::{VirtualListScrollHandle, v_virtual_list};
use gpui_kit::prelude::*;
use gpui_kit::{
    Action, AnyElement, App, ClickEvent, Context, DragMoveEvent, ElementId, Entity, FocusHandle,
    FontWeight, KeyDownEvent, MouseButton, MouseDownEvent, Pixels, Point, Role, ScrollStrategy,
    SharedString, Size, StyledText, Subscription, Task, Toggled, WeakEntity, Window, div, px, size,
};

use super::dates;
use super::sidebar_keys::{
    KeyRow, ListKey, ListMove, Pick, Picked, index_of, initial_cursor, navigate, pick,
    selection_row,
};
use super::sidebar_model::{
    AreaHint, AreaLists, AreaRow, DateBucket, HermesGroup, Hint, Section, SidebarItem, area_rows,
    build_sidebar, collapse, compose, flatten, parse_snippet, with_new_folder,
};
use crate::actions::{DeleteChat, FocusComposer, NewChat, OpenSettings, ToggleSidebar};
use crate::l10n::{ActiveL10n as _, L10n};
use crate::menus::{ChatCommandSlot, SIDEBAR_LIST_CONTEXT};
#[cfg(target_os = "macos")]
use crate::shell::macos::{EdgeBand, ListEdges};
use crate::shell::sheet::{SheetSpec, present_sheet};
use crate::stores::Stores;
use crate::stores::areas::{visible_areas, workspace_sections};
use crate::stores::chat_list::{ChatAction, ChatListEvent, ChatListStore};
use crate::stores::hermes_rooms::HermesRoomsStore;
use crate::stores::navigation::{Area, AreaItem, NavigationEvent, Selection, WorkspaceSection};
use crate::stores::session;
use crate::views::accounts::account_row;
use crate::views::forms::host_of;
use crate::views::privacy;
use conduit_components::views::focus::ControlExt as _;

/// A chat-row command, from the context menu or a hover button.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ChatCommand {
    Pin,
    Unpin,
    Rename,
    Archive,
    Unarchive,
    Delete,
    Share,
    /// File it in this folder.
    MoveTo(String),
    RemoveFromFolder,
    /// Start selection mode with this chat chosen.
    Select,
    /// Mark as Unread, and back (Mark as Read).
    MarkUnread,
    MarkRead,
    GenerateTitle,
    /// Export › Backup (JSON)… or Transcript (Markdown)….
    Export(conduit_protocol::ChatExportFormat),
    /// Duplicate Chat: a LibreChat chat copied whole, on its server.
    Duplicate,
}

/// The context menu's action: `command` on `chat_id`.
#[derive(Clone, Debug, PartialEq, Action)]
#[action(namespace = conduit_sidebar, no_json)]
pub struct ChatMenu {
    pub chat_id: String,
    pub command: ChatCommand,
}

/// A folder's right-click menu command.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum FolderCommand {
    /// A new chat, filed in the folder once its first message is sent.
    NewChat,
    /// Open or close it.
    Toggle,
    /// A new folder inside it, named in place.
    NewSubfolder,
    /// Its name, edited in place.
    Rename,
    /// Delete it (and its subfolders), after asking; the chats are kept.
    Delete,
    /// Its settings sheet: name, icon, prompt, models, knowledge.
    Settings,
    /// Who may read or edit it.
    Share,
}

/// A folder's context menu action: `command` on `folder_id`.
#[derive(Clone, Debug, PartialEq, Action)]
#[action(namespace = conduit_sidebar, no_json)]
pub struct FolderMenu {
    pub folder_id: String,
    pub command: FolderCommand,
}

/// Selection mode's "Move to…" menu: the folder, or none.
#[derive(Clone, Debug, PartialEq, Action)]
#[action(namespace = conduit_sidebar, no_json)]
pub struct MoveSelected {
    pub folder_id: Option<String>,
}

/// The selected chats' context menu: archive them, or delete them (after
/// asking).
#[derive(Clone, Debug, PartialEq, Action)]
#[action(namespace = conduit_sidebar, no_json)]
pub struct ActOnSelected {
    pub action: BulkChatAction,
}

/// A chat being dragged (with the rest of the selection, when it is one of
/// the checked chats), and its drag preview.
#[derive(Clone, Debug)]
pub struct DraggedChat {
    pub chat_id: String,
    pub title: SharedString,
    pub folder_id: Option<String>,
    /// Every chat the drag moves: this one, or the whole selection.
    pub chat_ids: Vec<String>,
    /// Where the pointer took hold, from the row's top-left corner (the
    /// preview hangs off the pointer from there).
    pub grab: Point<Pixels>,
}

/// The drag image's place from the pointer: just below and to the right,
/// as Finder's and Mail's drag images hang off the pointer.
pub const DRAG_IMAGE_OFFSET: (f32, f32) = (4., 4.);

/// How strongly the drag image's row draws: a snapshot of the row,
/// slightly lifted off the list, on an opaque card so nothing under it
/// shows through.
pub const DRAG_IMAGE_OPACITY: f32 = 0.85;

impl Render for DraggedChat {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let t = cx.conduit().clone();
        let r = t.roles;
        let m = t.metrics;
        let count = self.chat_ids.len();
        // GPUI draws the drag view at the pointer less `grab`: padding by
        // `grab` puts its corner on the pointer, and the offset beyond it.
        let (dx, dy) = DRAG_IMAGE_OFFSET;
        // The row itself, lifted: its glyph and title at a row's height and
        // radius, on the opaque menu surface with a soft shadow (the rows
        // beneath never show through it), the content at 85%; and how many
        // chats move when there are several.
        div()
            .debug_selector(|| "drag-image".into())
            .pl(self.grab.x + px(dx))
            .pt(self.grab.y + px(dy))
            .child(
                div()
                    .relative()
                    .pt(px(6.))
                    .pr(px(8.))
                    .child(
                        div()
                            // A sidebar row's width (the list's 10 pt
                            // margins taken off).
                            .w(px(m.sidebar_width - 20.))
                            .h(px(m.row_height))
                            .px(px(ROW_CONTENT_INSET))
                            .flex()
                            .items_center()
                            .gap(px(7.))
                            .rounded(t.row_radius())
                            .bg(r.overlay)
                            .border_1()
                            .border_color(r.border_strong)
                            .shadow(conduit_components::views::kit::overlay_shadow(&t))
                            // Whole over the list's faded ends.
                            .relative()
                            .child(conduit_components::views::overlays::overlay_marker())
                            .child(
                                div()
                                    .flex()
                                    .flex_1()
                                    .min_w_0()
                                    .items_center()
                                    .gap(px(7.))
                                    .opacity(DRAG_IMAGE_OPACITY)
                                    .child(icon(IconName::MessageSquare, 14., r.text_subtle))
                                    .child(
                                        div()
                                            .flex_1()
                                            .min_w_0()
                                            .truncate()
                                            .text_size(px(m.control))
                                            .text_color(r.text)
                                            .child(self.title.clone()),
                                    ),
                            ),
                    )
                    .when(count > 1, |d| {
                        d.child(
                            div()
                                .absolute()
                                .top_0()
                                .right_0()
                                .min_w(px(18.))
                                .h(px(18.))
                                .px(px(5.))
                                .rounded_full()
                                .bg(r.primary)
                                .flex()
                                .items_center()
                                .justify_center()
                                .text_size(px(11.))
                                .font_weight(FontWeight::SEMIBOLD)
                                .text_color(r.primary_foreground)
                                .child(SharedString::from(count.to_string())),
                        )
                    }),
            )
    }
}

/// What the flat rows were built from.
#[derive(Clone, Debug, PartialEq)]
struct RowsKey {
    revision: u64,
    /// The other areas' lists.
    areas_revision: u64,
    /// Hermes's bots and rooms.
    hermes_rooms: u64,
    /// Hermes's connections and jobs (the switcher and jobs rows).
    hermes_admin: u64,
    /// Bumped when a section opens or closes, or shows all.
    sections: u64,
    /// The areas shown, and the workspace sections.
    areas: Vec<Area>,
    workspace: Vec<WorkspaceSection>,
    hermes_archived: bool,
    row_height: f32,
    today: NaiveDate,
    /// The sidebar has a server to sync (the empty hint differs).
    has_account: bool,
    /// A folder being made, and where (`Some(None)`: the top level).
    new_folder: Option<Option<String>>,
}

/// What an inline name field edits.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum NameTarget {
    Chat(String),
    Folder(String),
    /// A Hermes session, by its session id.
    HermesSession(String),
    /// A folder not made yet, in `parent` (`None`: the top level): Return
    /// (or leaving the field) makes it, Esc drops it.
    NewFolder {
        parent: Option<String>,
    },
}

/// An inline rename (or a new folder's name) in progress.
struct Rename {
    target: NameTarget,
    /// The name it started with.
    original: String,
    input: Entity<InputState>,
    /// Where focus was before the field took it, and goes back to.
    restore: Option<gpui_kit::FocusHandle>,
    _subscription: Subscription,
}

/// An area's name, as its heading, the Go menu and its pane say it.
pub fn area_label(area: Area, l: &L10n) -> String {
    match area {
        Area::Chats => l.sidebar_chats_tab(),
        Area::Hermes => l.sidebar_hermes_tab(),
        Area::Notes => l.sidebar_notes_tab(),
        Area::Terminal => l.sidebar_terminal_tab(),
        Area::Channels => l.sidebar_channels_tab(),
        Area::Workspace => l.workspace_title(),
        Area::Calendar => l.calendar_title(),
        Area::Automations => l.scheduled_tasks_title(),
    }
}

/// A workspace section's name.
pub fn workspace_label(section: WorkspaceSection, l: &L10n) -> String {
    match section {
        WorkspaceSection::Models => l.workspace_models(),
        WorkspaceSection::Knowledge => l.workspace_knowledge(),
        WorkspaceSection::Prompts => l.workspace_prompts(),
        WorkspaceSection::Tools => l.workspace_tools(),
        WorkspaceSection::Skills => l.workspace_skills(),
    }
}

/// An area item's glyph, as the phone draws its tab or section.
pub fn item_icon(item: &AreaItem) -> IconName {
    match item {
        AreaItem::AllNotes => IconName::NotebookPen,
        AreaItem::Note(_) => IconName::FileText,
        AreaItem::Channel(_) => IconName::Hash,
        AreaItem::HermesSession(_) => IconName::Sparkles,
        AreaItem::HermesHidden => IconName::EyeOff,
        AreaItem::HermesBot(_) => IconName::Bot,
        AreaItem::HermesRoom(_) => IconName::Users,
        AreaItem::HermesJobs => IconName::CalendarClock,
        AreaItem::Workspace(WorkspaceSection::Models) => IconName::Network,
        AreaItem::Workspace(WorkspaceSection::Knowledge) => IconName::LibraryBig,
        AreaItem::Workspace(WorkspaceSection::Prompts) => IconName::TextQuote,
        AreaItem::Workspace(WorkspaceSection::Tools) => IconName::Wrench,
        AreaItem::Workspace(WorkspaceSection::Skills) => IconName::WandSparkles,
        AreaItem::Terminal(_) => IconName::SquareTerminal,
        AreaItem::Calendar => IconName::Calendar,
        AreaItem::Automations => IconName::CalendarClock,
    }
}

/// An area item's name: its own, or what the account's lists call it, or
/// "Untitled" (a note or session with none, or one not listed yet).
pub fn item_title(item: &AreaItem, listed: Option<&str>, l: &L10n) -> String {
    let named = listed.map(str::trim).filter(|t| !t.is_empty());
    match item {
        AreaItem::Workspace(section) => workspace_label(*section, l),
        AreaItem::Calendar => l.desktop_calendar_upcoming(),
        AreaItem::Automations => l.desktop_scheduled_tasks_all(),
        AreaItem::HermesHidden => l.hermes_hidden_chats_title(),
        AreaItem::AllNotes => l.desktop_all_notes(),
        AreaItem::HermesJobs => l.hermes_scheduled_agents_title(),
        AreaItem::HermesSession(_) => named
            .map(String::from)
            .unwrap_or_else(|| l.hermes_session_untitled()),
        AreaItem::Note(_)
        | AreaItem::Channel(_)
        | AreaItem::Terminal(_)
        | AreaItem::HermesBot(_)
        | AreaItem::HermesRoom(_) => named.map(String::from).unwrap_or_else(|| l.untitled()),
    }
}

/// The scope the sidebar's sections are kept under: the Open WebUI account
/// by id, or the setup in use (Direct, Hermes, the demo).
pub fn sections_scope(stores: &Stores, cx: &App) -> String {
    let accounts = stores.accounts.read(cx);
    if accounts.libre_chat_in_charge()
        && let Some(account) = accounts.libre_chat_active()
    {
        return format!("account:{}", account.id);
    }
    if let Some(account) = accounts.active() {
        return format!("account:{}", account.id);
    }
    match stores.session.read(cx).backend(cx) {
        Some(session::Backend::Direct) => "direct".into(),
        Some(session::Backend::Hermes) => "hermes".into(),
        Some(session::Backend::Demo) => "demo".into(),
        Some(session::Backend::OpenWebUi | session::Backend::LibreChat) | None => "none".into(),
    }
}

/// A chat's title, or "New Chat" for one still untitled.
fn display_title(title: &str, l10n: &L10n) -> SharedString {
    if title.trim().is_empty() {
        l10n.new_chat().into()
    } else {
        title.to_string().into()
    }
}

/// A folder name not yet taken beside `siblings`: `base`, else `base 2`,
/// `base 3`… (as Finder numbers "untitled folder 2").
pub fn unused_folder_name<'a>(
    base: &str,
    siblings: impl Iterator<Item = &'a str> + Clone,
) -> String {
    let taken = |name: &str| {
        siblings
            .clone()
            .any(|s| s.to_lowercase() == name.to_lowercase())
    };
    if !taken(base) {
        return base.to_string();
    }
    (2..)
        .map(|n| format!("{base} {n}"))
        .find(|name| !taken(name))
        .unwrap_or_else(|| base.to_string())
}

/// The footer's sync state.
pub fn sync_state(store: &ChatListStore, l: &L10n) -> SyncState {
    match &store.sync {
        Some(s) if !s.online => SyncState::Offline {
            detail: l.desktop_sync_offline().into(),
        },
        Some(s) if s.running => SyncState::Syncing {
            detail: match s.progress {
                Some(p) => l.desktop_syncing_percent((p * 100.).round() as i64),
                None => l.desktop_syncing(),
            }
            .into(),
        },
        Some(s) if s.last_error.is_some() => SyncState::Offline {
            detail: l.desktop_sync_failed().into(),
        },
        _ => SyncState::Synced {
            detail: l.desktop_synced().into(),
        },
    }
}

/// The account in the sidebar footer.
pub fn footer_account(stores: &Stores, cx: &App) -> Account {
    let l10n = cx.l10n().clone();
    let session = stores.session.read(cx);
    let accounts = stores.accounts.read(cx);
    if accounts.libre_chat_in_charge()
        && let Some(active) = accounts.libre_chat_active()
    {
        return crate::views::accounts::libre_chat_account_row(active, cx);
    }
    if let Some(active) = accounts.active() {
        return account_row(active, cx);
    }
    let (name, backend, server) = match session.backend(cx) {
        Some(session::Backend::Direct) => {
            let first = session
                .direct
                .as_ref()
                .and_then(|d| d.connections.iter().find(|c| c.enabled));
            (
                first
                    .map(|c| c.name.clone())
                    .unwrap_or_else(|| l10n.direct_connections_title()),
                Backend::Direct,
                first
                    .map(|c| privacy::host(&host_of(&c.base_url), cx))
                    .unwrap_or_default(),
            )
        }
        Some(session::Backend::Hermes) => (
            l10n.desktop_hermes_agent(),
            Backend::Hermes,
            session
                .hermes
                .as_ref()
                .map(|h| privacy::host(&host_of(&h.base_url), cx))
                .unwrap_or_default(),
        ),
        Some(session::Backend::Demo) => {
            (l10n.demo_mode_active(), Backend::OpenWebUi, String::new())
        }
        _ => ("Conduit".into(), Backend::OpenWebUi, String::new()),
    };
    Account {
        id: "app".into(),
        name: name.into(),
        email: SharedString::default(),
        server: server.into(),
        backend,
        active: true,
        needs_sign_in: false,
    }
}

/// The share link for `share_id` on the active account's server.
pub fn share_url(server: &str, share_id: &str) -> String {
    format!("{}/s/{share_id}", server.trim_end_matches('/'))
}

/// What a command does to the chosen chats ([`SidebarView::on_selection`]).
#[derive(Clone, Debug, PartialEq)]
pub enum OnSelection {
    Bulk(BulkChatAction, Option<String>),
    Nothing,
}

/// The action `command` takes on all of the chosen chats, and its folder:
/// Archive, Move to, Remove from Folder and Delete…. `None` for a command
/// for one chat, which chosen chats leave undone (and the Chat menu greys).
pub fn bulk_action(command: &ChatCommand) -> Option<(BulkChatAction, Option<String>)> {
    match command {
        ChatCommand::Archive => Some((BulkChatAction::Archive, None)),
        ChatCommand::Delete => Some((BulkChatAction::Delete, None)),
        ChatCommand::MoveTo(f) => Some((BulkChatAction::Move, Some(f.clone()))),
        ChatCommand::RemoveFromFolder => Some((BulkChatAction::Move, None)),
        _ => None,
    }
}

pub struct SidebarView {
    pub stores: Stores,
    /// The search field.
    pub search: Entity<InputState>,
    rows: Rc<Vec<SidebarItem>>,
    sizes: Rc<Vec<Size<Pixels>>>,
    key: Option<RowsKey>,
    scroll: VirtualListScrollHandle,
    /// The row under the pointer (a chat or folder id).
    hovered: Option<String>,
    /// The chat a context menu was opened for.
    context_target: Option<String>,
    /// Hermes's archived sessions are listed (its Archived row is open).
    hermes_archived: bool,
    /// The rows are under area headings (more than one area shows).
    areas_shown: bool,
    /// An area item to scroll to once the rows hold it.
    pending_reveal_item: Option<AreaItem>,
    renaming: Option<Rename>,
    /// The chosen chats (two or more, or any number with checkboxes).
    pub selecting: Option<BTreeSet<String>>,
    /// The active account the selection belongs to.
    account: Option<String>,
    /// The chosen chats show checkboxes ("Select Chats…"), rather than
    /// being drawn as selected rows (⌘- and ⇧-click).
    checkboxes: bool,
    /// Where a ⇧-click or ⇧-arrow range starts (else the open chat).
    anchor: Option<String>,
    /// A chat to scroll to once the rows hold it.
    pending_reveal: Option<String>,
    /// A folder just made, to scroll to once the rows hold it.
    pending_reveal_folder: Option<String>,
    /// The new-folder row, to scroll to once the rows hold it.
    pending_new_folder: bool,
    /// The list as a keyboard stop (a source list: Tab reaches it, arrows
    /// move in it).
    pub list_focus: FocusHandle,
    /// The row the keyboard stands on while the list has focus: the
    /// list's selection then (a folder too, without opening it).
    cursor: Option<KeyRow>,
    /// The list had focus when it was last drawn (its selection is drawn
    /// darker, and is the cursor's row).
    list_focused: bool,
    /// [`Self::selection`] as of this frame (worked out once per render).
    selected_row: Option<KeyRow>,
    /// The folder a dragged chat would drop into (outlined).
    drop_target: Option<String>,
    /// A closed folder held under a drag, which springs open after
    /// [`SPRING_LOAD_DELAY`] (Finder's spring-loaded folders).
    spring: Option<(String, Task<()>)>,
    /// Time spent building rows since the last [`Self::take_work`] (the
    /// perf fixture reads it).
    work: std::cell::Cell<Duration>,
    /// The list's faded ends on the translucent sidebar (a mask on the
    /// window's content), made once the window is known.
    #[cfg(target_os = "macos")]
    edges: Rc<RefCell<Option<ListEdges>>>,
    _ticker: Task<()>,
    _subscriptions: Vec<Subscription>,
}

impl SidebarView {
    pub fn new(stores: Stores, window: &mut Window, cx: &mut Context<Self>) -> Self {
        let placeholder = cx.l10n().desktop_search();
        // Esc is handled here (`escape_search`): it clears the field, then
        // leaves it, as NSSearchField's.
        let search = cx.new(|cx| InputState::new(window, cx).placeholder(placeholder));
        let subscriptions = vec![
            cx.observe(&stores.chat_list, |_, _, cx| cx.notify()),
            cx.observe(&stores.navigation, |_, _, cx| cx.notify()),
            cx.observe(&stores.areas, |_, _, cx| cx.notify()),
            cx.observe(&stores.hermes_rooms, |_, _, cx| cx.notify()),
            cx.observe(&stores.hermes_admin, |_, _, cx| cx.notify()),
            cx.observe(&stores.sections, |_, _, cx| cx.notify()),
            // Each account keeps its own sections.
            cx.observe(&stores.session, |this, _, cx| {
                this.sync_scope(cx);
                cx.notify()
            }),
            cx.observe(&stores.accounts, |this, accounts, cx| {
                this.sync_scope(cx);
                // Another account: nothing chosen carries over.
                let active = accounts.read(cx).scope_key();
                if active != this.account {
                    this.account = active;
                    this.selecting = None;
                    this.checkboxes = false;
                    this.anchor = None;
                    this.cursor = None;
                    // A name being typed is the last account's: dropped
                    // unsaved, with the field that would save it.
                    this.renaming = None;
                }
                cx.notify()
            }),
            cx.subscribe_in(&search, window, |this, input, e: &InputEvent, _, cx| {
                if let InputEvent::Change = e {
                    let q = input.read(cx).value().to_string();
                    this.stores.chat_list.update(cx, |c, cx| c.set_query(q, cx));
                }
            }),
            cx.subscribe(&stores.navigation, |this, _, e: &NavigationEvent, cx| {
                // The selection follows a chat opened anywhere (the palette,
                // a new chat): the keyboard starts from there.
                let NavigationEvent::Changed(selection) = e;
                this.cursor = KeyRow::of_selection(selection);
                // Only the newest selection is revealed once its list loads.
                this.pending_reveal = None;
                this.pending_reveal_item = None;
                match selection {
                    Selection::Chat(id) => this.reveal(id.clone(), cx),
                    Selection::Area(item) => {
                        // Chosen chats are no selection for a note or channel.
                        this.end_selection(cx);
                        this.reveal_item(item.clone(), cx)
                    }
                    Selection::New { .. } => {}
                }
            }),
            cx.subscribe(&stores.chat_list, |this, _, e: &ChatListEvent, cx| {
                this.toast_failure(e, cx)
            }),
        ];
        // Relative times move on; a new day regroups the list.
        let ticker = cx.spawn(async move |this: WeakEntity<Self>, cx| {
            loop {
                cx.background_executor()
                    .timer(Duration::from_secs(60))
                    .await;
                if this.update(cx, |_, cx| cx.notify()).is_err() {
                    break;
                }
            }
        });
        let account = stores.accounts.read(cx).scope_key();
        Self {
            stores,
            search,
            rows: Rc::new(vec![]),
            sizes: Rc::new(vec![]),
            key: None,
            scroll: VirtualListScrollHandle::new(),
            hovered: None,
            context_target: None,
            hermes_archived: false,
            areas_shown: false,
            pending_reveal_item: None,
            renaming: None,
            selecting: None,
            account,
            checkboxes: false,
            anchor: None,
            pending_reveal: None,
            pending_reveal_folder: None,
            pending_new_folder: false,
            list_focus: cx.focus_handle().tab_stop(true),
            cursor: None,
            list_focused: false,
            selected_row: None,
            drop_target: None,
            spring: None,
            work: Default::default(),
            #[cfg(target_os = "macos")]
            edges: Rc::default(),
            _ticker: ticker,
            _subscriptions: subscriptions,
        }
    }

    /// The flat rows as last drawn (tests and the E2E read them).
    pub fn rows(&self) -> &[SidebarItem] {
        &self.rows
    }

    /// Draws `chat_id` as hovered, or nothing (the fixture's AccessKit pass:
    /// hover actions exist only while hovered).
    pub fn hover(&mut self, chat_id: Option<&str>, cx: &mut Context<Self>) {
        self.hovered = chat_id.map(String::from);
        cx.notify();
    }

    /// Time spent rendering since the last call.
    pub fn take_work(&self) -> Duration {
        self.work.take()
    }

    /// The list's scroll handle (the perf pass scrolls it).
    pub fn scroll_handle(&self) -> &VirtualListScrollHandle {
        &self.scroll
    }

    fn bulk_supported(&self, cx: &App) -> bool {
        self.stores.session.read(cx).capabilities().bulk_selection
    }

    fn has_server(&self, cx: &App) -> bool {
        self.stores.accounts.read(cx).active().is_some()
    }

    fn toast(&self, level: NoticeLevel, text: String, cx: &mut App) {
        self.stores
            .toasts
            .update(cx, |t, cx| t.show(level, text, cx));
    }

    fn toast_failure(&mut self, e: &ChatListEvent, cx: &mut Context<Self>) {
        let l = cx.l10n().clone();
        let retry = match e {
            ChatListEvent::Failed { retry, .. } => retry.clone(),
            ChatListEvent::PartlyFailed { .. } => None,
        };
        let text = match e {
            ChatListEvent::Failed {
                action: ChatAction::Share,
                ..
            } => l.desktop_share_failed(),
            // A fixed sentence; the reason goes to the log.
            ChatListEvent::Failed { action, error, .. } => {
                log::warn!("chat change {action:?} failed: {error}");
                l.desktop_chat_change_failed()
            }
            ChatListEvent::PartlyFailed { failed, .. } => {
                l.desktop_bulk_partly_failed(failed.len() as i64)
            }
        };
        self.stores.toasts.update(cx, |t, cx| {
            t.show_with_retry(NoticeLevel::Error, text, retry, cx)
        });
    }

    // Rows.

    /// The areas the sidebar shows now: those the account's capabilities
    /// allow, once the main frame is up.
    pub fn areas(&self, cx: &App) -> Vec<Area> {
        let session = self.stores.session.read(cx);
        if session.route(cx) != session::Route::Main {
            return vec![Area::Chats];
        }
        visible_areas(&session.capabilities())
    }

    /// The sections' store follows the account in use.
    fn sync_scope(&mut self, cx: &mut Context<Self>) {
        let scope = sections_scope(&self.stores, cx);
        self.stores
            .sections
            .update(cx, |s, cx| s.set_scope(scope, cx));
    }

    fn rebuild_if_needed(&mut self, cx: &mut Context<Self>) {
        let t = cx.conduit().clone();
        let has_account = self.has_server(cx);
        let areas = self.areas(cx);
        let workspace = workspace_sections(&self.stores.session.read(cx).capabilities());
        let store = self.stores.chat_list.read(cx);
        let now = Local::now();
        let new_folder = match self.renaming.as_ref().map(|r| &r.target) {
            Some(NameTarget::NewFolder { parent }) => Some(parent.clone()),
            _ => None,
        };
        let key = RowsKey {
            revision: store.revision(),
            areas_revision: self.stores.areas.read(cx).revision(),
            hermes_rooms: self.stores.hermes_rooms.read(cx).revision(),
            hermes_admin: self.stores.hermes_admin.read(cx).revision(),
            sections: self.stores.sections.read(cx).revision(),
            areas: areas.clone(),
            workspace: workspace.clone(),
            hermes_archived: self.hermes_archived,
            row_height: t.metrics.row_height,
            today: now.date_naive(),
            has_account,
            new_folder: new_folder.clone(),
        };
        if self.key.as_ref() == Some(&key) {
            return;
        }
        let sections = self.stores.sections.read(cx);
        let mut chats = collapse(build_rows(store, has_account, &now), |s| {
            sections.is_collapsed(&s.key())
        });
        // A folder being made shows where it will go (its parent is open).
        if let Some(parent) = &new_folder
            && !store.is_searching()
            && let Some(with) = with_new_folder(chats.clone(), parent.as_deref())
        {
            chats = with;
        }
        // Search lists chats alone; otherwise every area, each under its
        // heading when there is more than one.
        let rows = if store.is_searching() {
            chats
        } else {
            let lists = self.stores.areas.read(cx);
            let failed: Vec<Area> = lists.failed.iter().copied().collect();
            let hermes_rooms = self.stores.hermes_rooms.read(cx);
            let admin = self.stores.hermes_admin.read(cx);
            let connection = admin.active().map(|c| c.name.clone());
            let connections = admin
                .connections
                .as_ref()
                .map(|l| l.connections.len())
                .unwrap_or(0);
            let area_lists = AreaLists {
                notes: lists.notes.as_deref(),
                channels: lists.channels.as_deref(),
                hermes: lists.hermes.as_ref(),
                hermes_connection: connection.as_deref().map(|name| (name, connections)),
                hermes_jobs: hermes_jobs_shown(admin),
                terminals: lists.terminals.as_deref(),
                failed: &failed,
                workspace: &workspace,
                bots: hermes_rooms.bot_list(),
                rooms: hermes_rooms.rooms.as_ref(),
                bots_open: !sections.is_collapsed(HermesGroup::Bots.key()),
                rooms_open: !sections.is_collapsed(HermesGroup::Rooms.key()),
            };
            compose(
                &areas,
                chats,
                |area| {
                    area_rows(
                        area,
                        &area_lists,
                        sections.shows_all(area.id()),
                        self.hermes_archived,
                    )
                },
                |area| sections.is_collapsed(area.id()),
            )
        };
        self.areas_shown = rows
            .first()
            .is_some_and(|r| matches!(r, SidebarItem::AreaHeader { .. }));
        let last = rows.len().saturating_sub(1);
        // The list runs down to the footer's rule, so rows scroll under it
        // rather than being cut short of it; the last row keeps a little
        // room under it instead.
        let sizes = rows
            .iter()
            .enumerate()
            .map(|(i, item)| {
                let tail = if i == last { LIST_TAIL } else { 0. };
                let previous = i.checked_sub(1).and_then(|p| rows.get(p));
                size(px(0.), px(row_height(item, previous, &t) + tail))
            })
            .collect();
        self.rows = Rc::new(rows);
        self.sizes = Rc::new(sizes);
        self.key = Some(key);
        if let Some(item) = self.pending_reveal_item.clone()
            && let Some(ix) = self.rows.iter().position(|r| r.area_item() == Some(&item))
        {
            self.scroll.scroll_to_item(ix, ScrollStrategy::Nearest);
            self.pending_reveal_item = None;
        }
        if let Some(id) = self.pending_reveal.clone()
            && let Some(ix) = self.rows.iter().position(|r| r.chat_id() == Some(&id))
        {
            self.scroll.scroll_to_item(ix, ScrollStrategy::Nearest);
            self.pending_reveal = None;
        }
        if let Some(id) = self.pending_reveal_folder.clone()
            && let Some(ix) = self
                .rows
                .iter()
                .position(|r| matches!(r, SidebarItem::Folder { folder, .. } if folder.id == id))
        {
            self.scroll.scroll_to_item(ix, ScrollStrategy::Nearest);
            self.pending_reveal_folder = None;
        }
        if self.pending_new_folder
            && let Some(ix) = self
                .rows
                .iter()
                .position(|r| matches!(r, SidebarItem::NewFolder { .. }))
        {
            self.scroll.scroll_to_item(ix, ScrollStrategy::Nearest);
            self.pending_new_folder = false;
        }
    }

    /// Opens the area holding `item` and scrolls to its row.
    fn reveal_item(&mut self, item: AreaItem, cx: &mut Context<Self>) {
        let area = item.area();
        self.stores
            .sections
            .update(cx, |s, cx| s.set_collapsed(area.id(), false, cx));
        // An archived Hermes session shows under its Archived row.
        if let AreaItem::HermesSession(id) = &item
            && self
                .stores
                .areas
                .read(cx)
                .hermes
                .as_ref()
                .is_some_and(|h| h.archived.iter().any(|s| &s.id == id))
        {
            self.hermes_archived = true;
        }
        match self.rows.iter().position(|r| r.area_item() == Some(&item)) {
            Some(ix) => self.scroll.scroll_to_item(ix, ScrollStrategy::Nearest),
            None => {
                // Past the area's first rows (or not listed yet): all of
                // them, so the row is there to scroll to.
                self.stores
                    .sections
                    .update(cx, |s, cx| s.set_show_all(area.id(), true, cx));
                self.pending_reveal_item = Some(item);
            }
        }
        cx.notify();
    }

    /// Go › a section (⌘1…): the area opened and scrolled to, the list
    /// focused with the keyboard on its heading (on its first row when the
    /// sidebar shows no headings). The section holding the chat on screen
    /// puts the keyboard on that chat's row instead, so it stays the
    /// selection.
    pub fn go_to_area(&mut self, area: Area, window: &mut Window, cx: &mut Context<Self>) {
        // Search lists chats alone: the sections come back first.
        if !self.search.read(cx).value().is_empty() || self.stores.chat_list.read(cx).is_searching()
        {
            self.clear_search(window, cx);
        }
        self.stores
            .sections
            .update(cx, |s, cx| s.set_collapsed(area.id(), false, cx));
        self.rebuild_if_needed(cx);
        let target = KeyRow::Area(area);
        let ix = index_of(&self.rows, &target).or_else(|| {
            self.rows
                .iter()
                .position(|r| KeyRow::of(r).is_some_and(|k| !matches!(k, KeyRow::Area(_))))
        });
        let shown = self.stores.navigation.read(cx).selection();
        let on_screen = (shown.chat_id().is_some() && shown.area() == area)
            .then(|| self.open_row(cx))
            .flatten()
            .and_then(|row| index_of(&self.rows, &row).map(|at| (at, row)));
        self.list_focus.focus(window, cx);
        if let Some(ix) = ix {
            self.cursor = KeyRow::of(&self.rows[ix]);
            self.scroll_to_top(ix);
        }
        if let Some((at, row)) = on_screen {
            self.cursor = Some(row);
            self.scroll.scroll_to_item(at, ScrollStrategy::Nearest);
        }
        cx.notify();
    }

    /// Whether `row` shows in the top half of the list, or the list is
    /// scrolled as far as it goes (the E2E checks Go with it).
    pub fn row_near_top(&self, row: &KeyRow) -> bool {
        let Some(ix) = index_of(&self.rows, row) else {
            return false;
        };
        let top: f32 = self.sizes[..ix].iter().map(|s| f32::from(s.height)).sum();
        // A heading's row starts with the gap above it, which
        // [`Self::scroll_to_top`] scrolls past.
        let previous = ix.checked_sub(1).and_then(|p| self.rows.get(p));
        let gap = self.rows.get(ix).map_or(0., |r| header_gap(r, previous));
        let scrolled = -f32::from(self.scroll.offset().y);
        let visible = f32::from(self.scroll.base_handle().bounds().size.height);
        let at_end = scrolled + 1. >= f32::from(self.scroll.max_offset().y);
        top + gap + 1. >= scrolled
            && (top < scrolled + visible / 2. || at_end && top < scrolled + visible)
    }

    /// Scrolls row `ix` to the top of the list, as Finder brings a sidebar
    /// group into view (Kit's virtual list scrolls only as far as the
    /// nearest edge, which would leave a heading at the bottom). The list
    /// keeps the offset within its bounds when it lays out.
    fn scroll_to_top(&mut self, ix: usize) {
        let above: f32 = self.sizes[..ix.min(self.sizes.len())]
            .iter()
            .map(|s| f32::from(s.height))
            .sum();
        // A heading's row carries the gap above it: past that gap.
        let previous = ix.checked_sub(1).and_then(|p| self.rows.get(p));
        let gap = self.rows.get(ix).map_or(0., |r| header_gap(r, previous));
        self.scroll
            .base_handle()
            .set_offset(gpui_kit::point(px(0.), px(-(above + gap))));
    }

    /// Opens or closes area `area`'s section.
    pub fn toggle_area(&mut self, area: Area, cx: &mut Context<Self>) {
        self.stores
            .sections
            .update(cx, |s, cx| s.toggle_collapsed(area.id(), cx));
    }

    /// Whether area `area`'s section is closed (tests and the E2E).
    pub fn area_collapsed(&self, area: Area, cx: &App) -> bool {
        self.stores.sections.read(cx).is_collapsed(area.id())
    }

    /// Opens the folders around `chat_id` and scrolls to it.
    fn reveal(&mut self, chat_id: String, cx: &mut Context<Self>) {
        self.stores
            .sections
            .update(cx, |s, cx| s.set_collapsed(Area::Chats.id(), false, cx));
        self.stores
            .chat_list
            .update(cx, |c, cx| c.reveal_chat(&chat_id, cx));
        match self.rows.iter().position(|r| r.chat_id() == Some(&chat_id)) {
            Some(ix) => self.scroll.scroll_to_item(ix, ScrollStrategy::Nearest),
            None => self.pending_reveal = Some(chat_id),
        }
        cx.notify();
    }

    fn render_rows(
        &mut self,
        range: std::ops::Range<usize>,
        cx: &mut Context<Self>,
    ) -> Vec<AnyElement> {
        let started = std::time::Instant::now();
        let t = cx.conduit().clone();
        let now = Local::now();
        let len = self.rows.len();
        let rows: Vec<AnyElement> = range
            .filter(move |ix| *ix < len)
            .map(|ix| {
                let height = self.sizes.get(ix).map_or(px(0.), |s| s.height);
                let item = self.rows[ix].clone();
                let previous = ix.checked_sub(1).and_then(|p| self.rows.get(p));
                let gap = header_gap(&item, previous);
                let el = self.render_item(&item, &now, &t, cx);
                div()
                    .h(height)
                    .w_full()
                    .px(px(10.))
                    .when(gap > 0., |d| d.pt(px(gap)))
                    .child(el)
                    .into_any_element()
            })
            .collect();
        self.work.set(self.work.get() + started.elapsed());
        rows
    }

    fn render_item(
        &mut self,
        item: &SidebarItem,
        now: &DateTime<Local>,
        t: &ConduitTheme,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let l = cx.l10n().clone();
        let r = t.roles;
        match item {
            SidebarItem::AreaHeader { area, expanded } => {
                self.area_heading(*area, *expanded, t, cx)
            }
            SidebarItem::AreaRow(row) => self.area_row(row, now, t, cx),
            SidebarItem::ShowAll { area, all } => {
                let (area, all) = (*area, *all);
                let label: SharedString = if all {
                    l.markdown_show_less()
                } else {
                    l.desktop_show_all()
                }
                .into();
                let row = KeyRow::ShowAll(area);
                more_row(area.id(), &label, self.row_state(&row, area.id()), t)
                    .aria_expanded(all)
                    .when(self.is_cursor(&row), |d| d.aria_active_descendant())
                    .on_hover(self.hover_listener(format!("more-{}", area.id()), cx))
                    .on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
                        this.cursor = Some(KeyRow::ShowAll(area));
                        this.toggle_show_all(area, cx);
                    }))
                    .into_any_element()
            }
            SidebarItem::HermesConnection { name, count } => {
                let count = *count;
                let selected = self.is_selection(&KeyRow::HermesConnection);
                hermes_connection_row(name, count, selected, self.list_focused, t, &l)
                    .when(self.areas_shown, |d| {
                        d.pl(px(ROW_CONTENT_INSET + ROW_STATUS_GUTTER))
                    })
                    .on_click(cx.listener(move |this, _: &ClickEvent, window, cx| {
                        this.cursor = Some(KeyRow::HermesConnection);
                        this.hermes_connection_menu(window, cx);
                    }))
                    .into_any_element()
            }
            SidebarItem::HermesArchived { count, visible } => {
                let visible = *visible;
                footer_button(
                    "hermes-archived",
                    l.archived(),
                    Some(visible),
                    Some(count.to_string()),
                    self.is_selection(&KeyRow::HermesArchived),
                    self.list_focused,
                    t,
                )
                .when(self.areas_shown, |d| {
                    d.pl(px(ROW_CONTENT_INSET + ROW_STATUS_GUTTER))
                })
                .aria_description(SharedString::from(l.desktop_chat_count(*count as i64)))
                .on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
                    this.cursor = Some(KeyRow::HermesArchived);
                    this.hermes_archived = !visible;
                    cx.notify();
                }))
                .into_any_element()
            }
            SidebarItem::HermesGroup {
                group,
                count,
                expanded,
                can_create,
            } => self.hermes_group(*group, *count, *expanded, *can_create, t, cx),
            // The phone's row: how many runs Show Scheduled Runs leaves
            // out, and Show, which turns it back on.
            SidebarItem::HermesScheduledHidden { count } => {
                let text = l.hermes_scheduled_runs_hidden(*count as i64);
                let stores = self.stores.clone();
                // A stop for the arrows (Return shows the runs), drawn
                // selected as the other footer rows are.
                let selected = self.is_selection(&KeyRow::HermesScheduledHidden);
                let fill = selection_fill(t, self.list_focused);
                div()
                    .id("hermes-scheduled-hidden")
                    .role(Role::Status)
                    .aria_label(SharedString::from(text.clone()))
                    .aria_selected(selected)
                    .when(selected, |d| d.aria_active_descendant().bg(fill))
                    .rounded(t.row_radius())
                    .h(px(t.metrics.row_height))
                    .pl(px(ROW_CONTENT_INSET + ROW_STATUS_GUTTER))
                    .pr(px(ROW_CONTENT_INSET))
                    .flex()
                    .items_center()
                    .gap(px(6.))
                    .text_size(px(t.metrics.small))
                    .text_color(r.sidebar_text_subtle)
                    .child(div().flex_1().min_w_0().truncate().child(text))
                    .child(
                        conduit_components::views::kit::Button::new(
                            "hermes-show-scheduled",
                            l.hermes_show_scheduled_runs_action(),
                        )
                        .ghost()
                        .on_click(Rc::new(move |_, _, cx| {
                            crate::views::settings::hermes::set_show_scheduled_runs(
                                &stores, true, cx,
                            );
                        })),
                    )
                    .into_any_element()
            }
            SidebarItem::AreaHint { area, hint } => {
                let text = area_hint_text(*area, *hint, &l);
                let retry = matches!(hint, AreaHint::Failed | AreaHint::ArchivedFailed);
                let area = *area;
                div()
                    .id(ElementId::Name(
                        format!("hint-{}-{}", area.id(), format!("{hint:?}").to_lowercase()).into(),
                    ))
                    .role(Role::Status)
                    .aria_label(SharedString::from(text.clone()))
                    .h(px(t.metrics.row_height))
                    .pl(px(ROW_CONTENT_INSET + ROW_STATUS_GUTTER))
                    .pr(px(ROW_CONTENT_INSET))
                    .flex()
                    .items_center()
                    .gap(px(6.))
                    .text_size(px(t.metrics.small))
                    .text_color(r.sidebar_text_subtle)
                    .child(div().flex_1().min_w_0().truncate().child(text))
                    // As the phone's archived row: Try Again.
                    .when(retry, |d| {
                        let areas = self.stores.areas.downgrade();
                        d.child(
                            conduit_components::views::kit::Button::new(
                                ElementId::Name(format!("retry-{}", area.id()).into()),
                                l.desktop_try_again(),
                            )
                            .ghost()
                            .on_click(Rc::new(move |_, _, cx| {
                                let _ = areas.update(cx, |a, cx| a.refresh(area, cx));
                            })),
                        )
                    })
                    .into_any_element()
            }
            SidebarItem::NewFolder { parent, depth } => {
                self.new_folder_row(parent.as_deref(), *depth, t, cx)
            }
            SidebarItem::Header(section) => self.header(*section, t, cx),
            SidebarItem::Folder {
                folder,
                depth,
                expanded,
                count,
            } => self.folder(folder, *depth, *expanded, *count, t, cx),
            SidebarItem::Chat { chat, depth } => self.chat(chat, *depth, now, t, cx),
            SidebarItem::SearchHit(hit) => self.search_hit(hit, now, t, cx),
            SidebarItem::LoadMore => {
                let (loading, failed) = {
                    let c = self.stores.chat_list.read(cx);
                    (c.loading_more, c.more_failed)
                };
                // Reaching the end of the loaded page loads the next one,
                // but not again after a failure (Load More asks again).
                if !loading && !failed {
                    let chat_list = self.stores.chat_list.clone();
                    cx.defer(move |cx| chat_list.update(cx, |c, cx| c.load_more(cx)));
                }
                footer_button(
                    "load-more",
                    if loading {
                        l.loading_short()
                    } else {
                        l.desktop_load_more()
                    },
                    None,
                    None,
                    self.is_selection(&KeyRow::LoadMore),
                    self.list_focused,
                    t,
                )
                // Under an area's heading, a row of that area: in at the
                // titles' column, as its sections' headers are.
                .when(self.areas_shown, |d| {
                    d.pl(px(ROW_CONTENT_INSET + ROW_STATUS_GUTTER))
                })
                .on_click(cx.listener(|this, _: &ClickEvent, _, cx| {
                    this.stores.chat_list.update(cx, |c, cx| c.load_more(cx))
                }))
                .into_any_element()
            }
            SidebarItem::Archived { count, visible } => {
                let visible = *visible;
                footer_button(
                    "archived",
                    l.archived(),
                    Some(visible),
                    Some(count.to_string()),
                    self.is_selection(&KeyRow::Archived),
                    self.list_focused,
                    t,
                )
                .when(self.areas_shown, |d| {
                    d.pl(px(ROW_CONTENT_INSET + ROW_STATUS_GUTTER))
                })
                .aria_description(SharedString::from(l.desktop_chat_count(*count)))
                .on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
                    this.stores
                        .chat_list
                        .update(cx, |c, cx| c.set_archived_visible(!visible, cx))
                        .detach();
                }))
                .into_any_element()
            }
            SidebarItem::Hint(hint) => div()
                .id(ElementId::Name(format!("hint-{hint:?}").into()))
                .role(Role::Status)
                .aria_label(SharedString::from(hint_text(*hint, &l)))
                .px(px(8.))
                .py(px(10.))
                .text_size(px(t.metrics.small))
                .text_color(r.sidebar_text_subtle)
                .child(hint_text(*hint, &l))
                .into_any_element(),
        }
    }

    /// How a row of the areas draws: selected, hovered, the list key.
    fn row_state(&self, row: &KeyRow, hover_id: &str) -> RowState {
        RowState {
            selected: self.is_selection(row),
            hovered: self.hovered.as_deref() == Some(hover_id),
            keyboard: self.list_focused,
            ..Default::default()
        }
    }

    /// Whether the keyboard stands on `row` (its AccessKit focus).
    fn is_cursor(&self, row: &KeyRow) -> bool {
        self.list_focused && self.cursor.as_ref() == Some(row)
    }

    fn hover_listener(
        &self,
        id: String,
        cx: &mut Context<Self>,
    ) -> impl Fn(&bool, &mut Window, &mut App) + 'static {
        cx.listener(move |this, on: &bool, _, cx| this.set_hovered(&id, *on, cx))
    }

    /// An area's heading: a click (or ← and →) closes and opens it.
    fn area_heading(
        &mut self,
        area: Area,
        expanded: bool,
        t: &ConduitTheme,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let l = cx.l10n().clone();
        let label: SharedString = area_label(area, &l).into();
        let row = KeyRow::Area(area);
        // Channels carry New Channel… ("+"), as Folders carry New Folder,
        // for an account that may make one.
        let add =
            (area == Area::Channels && self.stores.areas.read(cx).channels_can_create).then(|| {
                IconButton::new("new-channel", IconName::Plus, l.desktop_new_channel())
                    .size(20., 13.)
                    .on_click(Rc::new(|_, window, cx| {
                        // The heading under it would close the section.
                        cx.stop_propagation();
                        window.dispatch_action(Box::new(crate::views::channels::NewChannel), cx);
                    }))
            });
        area_header(area.id(), &label, expanded, self.row_state(&row, ""), t)
            .children(add)
            .when(self.is_cursor(&row), |d| d.aria_active_descendant())
            .on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
                this.cursor = Some(KeyRow::Area(area));
                this.toggle_area(area, cx);
            }))
            .into_any_element()
    }

    /// An item of another area: a click opens it in its pane.
    fn area_row(
        &mut self,
        row: &AreaRow,
        now: &DateTime<Local>,
        t: &ConduitTheme,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        if let Some(session) = &row.session {
            return self.hermes_row(session, now, t, cx);
        }
        if let Some(bot) = &row.bot {
            return self.bot_row(bot, now, t, cx);
        }
        if let Some(room) = &row.room {
            return self.room_row(room, now, t, cx);
        }
        let l = cx.l10n().clone();
        let item = row.item.clone();
        let id = area_item_id(&item);
        let key = KeyRow::Item(item.clone());
        let (trailing, description, emphasized) = if row.unread > 0 {
            let spoken = l.desktop_unread_count(row.unread);
            (Some(row.unread.to_string()), Some(spoken), true)
        } else if let Some(ms) = row.updated_at_ms {
            let (time, spoken) = dates::stamp(ms, now, &l);
            (Some(time), Some(spoken), false)
        } else if row.dimmed {
            // A channel set to mentions only says so.
            (None, Some(l.channel_notify_mentions_only()), false)
        } else {
            (None, None, false)
        };
        let line = ItemLine {
            id: id.clone().into(),
            icon: row.icon.unwrap_or_else(|| item_icon(&item)),
            title: item_title(&item, Some(&row.title), &l).into(),
            trailing: trailing.map(Into::into),
            description: description.map(Into::into),
            pinned: row.pinned,
            emphasized,
        };
        // A channel's own menu: Mark as Read, Notifications, Edit, Leave,
        // Delete.
        let menu_item = item.clone();
        // A note's row has the note's menu (Open, Copy, Pin, Share
        // Access…, Delete…), as the list pane's rows do.
        let note = match &row.item {
            AreaItem::Note(note_id) => self.stores.areas.read(cx).note(note_id).cloned(),
            _ => None,
        };
        let menu_key = key.clone();
        item_row(&line, self.row_state(&key, &id), t)
            .when(row.dimmed, |d| d.opacity(0.6))
            .when(self.is_cursor(&key), |d| d.aria_active_descendant())
            .on_mouse_down(
                gpui_kit::MouseButton::Right,
                cx.listener(move |this, e: &gpui_kit::MouseDownEvent, window, cx| {
                    let AreaItem::Channel(channel_id) = &menu_item else {
                        return;
                    };
                    let Some(channel) = this.stores.areas.read(cx).channel(channel_id).cloned()
                    else {
                        return;
                    };
                    let menu = crate::views::channels::channel_menu(&channel, true, cx.l10n());
                    // Its own menu only: not the list's New Folder after it.
                    cx.stop_propagation();
                    menu.show(e.position, window, cx);
                }),
            )
            .on_hover(self.hover_listener(id, cx))
            .on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
                this.cursor = Some(KeyRow::Item(item.clone()));
                let item = item.clone();
                this.stores
                    .navigation
                    .update(cx, |n, cx| n.open_item(item, cx));
            }))
            .when_some(note, |d, note| {
                d.on_mouse_down(
                    MouseButton::Right,
                    cx.listener(move |this, ev: &MouseDownEvent, window, cx| {
                        cx.stop_propagation();
                        this.cursor = Some(menu_key.clone());
                        let l = cx.l10n().clone();
                        crate::views::notes::note_menu(&note, &l).show(ev.position, window, cx);
                        cx.notify();
                    }),
                )
            })
            .into_any_element()
    }

    /// A Hermes session: drawn as a chat's row (its date, its pin, a
    /// spinner while a reply is written in it), its commands on "…" and in
    /// its context menu, its name edited in place.
    fn hermes_row(
        &mut self,
        session: &HermesSessionDto,
        now: &DateTime<Local>,
        t: &ConduitTheme,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let l = cx.l10n().clone();
        let item = AreaItem::HermesSession(session.id.clone());
        let id = area_item_id(&item);
        let title = hermes_title(session, &l);
        let (time, spoken) = session
            .updated_at_ms
            .map(|ms| dates::stamp(ms, now, &l))
            .unwrap_or_default();
        let row = ChatRow {
            id: id.clone().into(),
            title: title.clone().into(),
            time: time.into(),
            time_spoken: spoken.into(),
            pinned: session.pinned,
            streaming: session.running,
            working: session.running,
            reduce_motion: cx.reduce_motion(),
            status: Some(l.desktop_chat_running().into()),
            ..Default::default()
        };
        let key = KeyRow::Item(item.clone());
        let hovered = self.hovered.as_deref() == Some(id.as_str());
        let field = self.name_field_for(&NameTarget::HermesSession(session.id.clone()), t, cx);
        let actions = if hovered && field.is_none() {
            let quoted = format!("\u{201c}{title}\u{201d}");
            let this = cx.entity().downgrade();
            let menu_id = session.id.clone();
            vec![
                RowAction::new(
                    format!("more-{id}"),
                    IconName::Ellipsis,
                    l.desktop_more_actions_for(&quoted),
                )
                .tooltip(l.more())
                .on_click(Rc::new(move |e, window, cx| {
                    // The row under the button would open the chat too.
                    cx.stop_propagation();
                    let (id, position) = (menu_id.clone(), e.position());
                    this.update(cx, |s, cx| {
                        s.hermes_context_menu(&id, vec![], position, window, cx)
                    })
                    .ok();
                })),
            ]
        } else {
            vec![]
        };
        let state = RowState {
            selected: self.is_selection(&key),
            hovered,
            context: self.context_target.as_deref() == Some(id.as_str()),
            keyboard: self.list_focused,
            ..Default::default()
        };
        let menu_id = session.id.clone();
        chat_row(&row, state, 0., actions, field, t)
            .when(self.is_cursor(&key), |d| d.aria_active_descendant())
            .on_hover(self.hover_listener(id, cx))
            .on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
                this.cursor = Some(KeyRow::Item(item.clone()));
                let item = item.clone();
                this.stores
                    .navigation
                    .update(cx, |n, cx| n.open_item(item, cx));
            }))
            .on_mouse_down(
                MouseButton::Right,
                cx.listener(move |this, ev: &MouseDownEvent, window, cx| {
                    cx.stop_propagation();
                    this.hermes_context_menu(&menu_id, vec![], ev.position, window, cx)
                }),
            )
            .into_any_element()
    }

    /// A heading of Hermes's section: Bots and Rooms open and close (their
    /// counts beside them, as the phone's), Rooms carries New Room ("+");
    /// Conversations heads the sessions under them.
    fn hermes_group(
        &mut self,
        group: HermesGroup,
        count: usize,
        expanded: bool,
        can_create: bool,
        t: &ConduitTheme,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let l = cx.l10n().clone();
        let name = match group {
            HermesGroup::Bots => l.hermes_bots_title(),
            HermesGroup::Rooms => l.hermes_rooms_title(),
            HermesGroup::Conversations => l.hermes_conversations_title(),
        };
        let label: SharedString = name.into();
        // The count beside the name, in the heading's own tone, as the
        // phone's headers show it.
        let counted = (group.collapsible() && count > 0).then(|| {
            div()
                .flex_none()
                .text_size(px(t.metrics.small))
                .text_color(t.roles.sidebar_text_subtle)
                .child(SharedString::from(count.to_string()))
                .into_any_element()
        });
        let add = (group == HermesGroup::Rooms && can_create).then(|| {
            let stores = self.stores.clone();
            IconButton::new("hermes-new-room", IconName::Plus, l.hermes_room_new())
                .size(20., 13.)
                .on_click(Rc::new(move |_, window, cx| {
                    // The heading under it would close the group.
                    cx.stop_propagation();
                    crate::views::hermes_room_sheets::open_create(stores.clone(), window, cx);
                }))
                .into_any_element()
        });
        let id = format!("hermes-{}", group.key().trim_start_matches("hermes."));
        let trailing = match (counted, add) {
            (None, None) => None,
            (counted, add) => Some(
                div()
                    .flex()
                    .items_center()
                    .gap(px(6.))
                    .children(counted)
                    .children(add)
                    .into_any_element(),
            ),
        };
        let header = section_header(
            &id,
            &label,
            trailing,
            group.collapsible().then_some(expanded),
            t,
        )
        .when(self.areas_shown, |d| {
            d.pl(px(ROW_CONTENT_INSET + ROW_STATUS_GUTTER))
                .aria_level(3)
        });
        if !group.collapsible() {
            return header.into_any_element();
        }
        let key = group.key();
        let header = header.on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
            this.stores
                .sections
                .update(cx, |s, cx| s.toggle_collapsed(key, cx));
        }));
        if group == HermesGroup::Rooms && can_create {
            let menu_stores = self.stores.clone();
            header
                .on_mouse_down(
                    MouseButton::Right,
                    cx.listener(move |_, ev: &MouseDownEvent, window, cx| {
                        cx.stop_propagation();
                        let l = cx.l10n().clone();
                        let _ = &menu_stores;
                        NativeMenu::new()
                            .menu(
                                l.desktop_hermes_new_room_menu(),
                                Box::new(crate::views::hermes_rooms::NewRoom),
                            )
                            .show(ev.position, window, cx);
                    }),
                )
                .into_any_element()
        } else {
            header.into_any_element()
        }
    }

    /// A bot: its face and name; a click (or Return) opens its Bot Chat,
    /// whose session is then the selection (the row reads as selected).
    fn bot_row(
        &mut self,
        bot: &HermesBotDto,
        now: &DateTime<Local>,
        t: &ConduitTheme,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let l = cx.l10n().clone();
        let item = AreaItem::HermesBot(bot.name.clone());
        let id = area_item_id(&item);
        let key = KeyRow::Item(item.clone());
        let rooms = self.stores.hermes_rooms.read(cx);
        let opening = rooms.opening_bot.as_deref() == Some(bot.name.as_str());
        let face = crate::views::hermes_faces::bot_face(bot, rooms);
        if bot.has_avatar && face.image.is_none() {
            crate::views::hermes_faces::request_avatars(
                [bot.name.as_str()],
                &self.stores.hermes_rooms,
                cx,
            );
        }
        let (time, spoken) = bot
            .last_active_ms
            .map(|ms| dates::stamp(ms, now, &l))
            .unwrap_or_default();
        let line = FaceLine {
            id: id.clone().into(),
            title: bot.title.clone().into(),
            trailing: (!time.is_empty()).then(|| time.into()),
            description: (!spoken.is_empty()).then(|| spoken.into()),
            working: opening,
            reduce_motion: cx.reduce_motion(),
            working_spoken: Some(l.loading_short().into()),
            ..Default::default()
        };
        // Its chat open: the session's selection is the bot's row.
        let state = RowState {
            selected: self.is_selection(&key),
            hovered: self.hovered.as_deref() == Some(id.as_str()),
            context: self.context_target.as_deref() == Some(id.as_str()),
            keyboard: self.list_focused,
            ..Default::default()
        };
        let name = bot.name.clone();
        let menu_name = bot.name.clone();
        let menu_target = id.clone();
        face_row(
            &line,
            crate::views::hermes_faces::face(
                ElementId::Name(format!("face-{id}").into()),
                &face,
                18.,
                false,
                true,
            ),
            state,
            vec![],
            t,
        )
        .when(self.is_cursor(&key), |d| d.aria_active_descendant())
        .on_hover(self.hover_listener(id, cx))
        .on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
            this.cursor = Some(KeyRow::Item(AreaItem::HermesBot(name.clone())));
            crate::views::hermes_rooms::open_bot(&this.stores, &name, cx);
        }))
        .on_mouse_down(
            MouseButton::Right,
            cx.listener(move |this, ev: &MouseDownEvent, window, cx| {
                cx.stop_propagation();
                this.show_context_menu(
                    menu_target.clone(),
                    crate::views::hermes_rooms::bot_menu(&menu_name, cx.l10n()),
                    ev.position,
                    window,
                    cx,
                );
            }),
        )
        .into_any_element()
    }

    /// A Group Chat: its bots' faces, its name, when it was last active;
    /// a dot when something was said since it was shown, a spinner while
    /// its bots work. A click opens it; "…" and its context menu offer
    /// Room Info…, Rename…, Stop All Work and Disband Room….
    fn room_row(
        &mut self,
        room: &HermesRoomDto,
        now: &DateTime<Local>,
        t: &ConduitTheme,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let l = cx.l10n().clone();
        let item = AreaItem::HermesRoom(room.id.clone());
        let id = area_item_id(&item);
        let key = KeyRow::Item(item.clone());
        let rooms = self.stores.hermes_rooms.read(cx);
        let faces: Vec<_> = HermesRoomsStore::faces(room)
            .iter()
            .map(|m| crate::views::hermes_faces::member_face(m, rooms))
            .collect();
        let (time, spoken) = room
            .updated_at_ms
            .map(|ms| dates::stamp(ms, now, &l))
            .unwrap_or_default();
        let mut description = vec![l.hermes_room_bot_count(room.members.len() as i64)];
        if !spoken.is_empty() {
            description.push(spoken);
        }
        if room.needs_you {
            description.push(l.hermes_room_needs_you());
        }
        let line = FaceLine {
            id: id.clone().into(),
            title: room.name.clone().into(),
            trailing: (!time.is_empty()).then(|| time.into()),
            description: Some(description.join(", ").into()),
            unread: room.unread || room.needs_you,
            working: room.working,
            reduce_motion: cx.reduce_motion(),
            unread_spoken: Some(l.desktop_unread().into()),
            working_spoken: Some(l.hermes_room_working().into()),
        };
        let hovered = self.hovered.as_deref() == Some(id.as_str());
        let actions = if hovered {
            let quoted = format!("\u{201c}{}\u{201d}", room.name);
            let this = cx.entity().downgrade();
            let (menu_id, target) = (room.id.clone(), id.clone());
            vec![
                RowAction::new(
                    format!("more-{id}"),
                    IconName::Ellipsis,
                    l.desktop_more_actions_for(&quoted),
                )
                .tooltip(l.more())
                .on_click(Rc::new(move |e, window, cx| {
                    cx.stop_propagation();
                    let (room_id, target, position) =
                        (menu_id.clone(), target.clone(), e.position());
                    this.update(cx, |s, cx| {
                        let menu = crate::views::hermes_rooms::native_menu(&s.stores, &room_id, cx);
                        s.show_context_menu(target, menu, position, window, cx)
                    })
                    .ok();
                })),
            ]
        } else {
            vec![]
        };
        let state = RowState {
            selected: self.is_selection(&key),
            hovered,
            context: self.context_target.as_deref() == Some(id.as_str()),
            keyboard: self.list_focused,
            ..Default::default()
        };
        let (menu_id, menu_target) = (room.id.clone(), id.clone());
        face_row(
            &line,
            crate::views::hermes_faces::stack(&format!("faces-{id}"), &faces, 20., true),
            state,
            actions,
            t,
        )
        .when(self.is_cursor(&key), |d| d.aria_active_descendant())
        .on_hover(self.hover_listener(id, cx))
        .on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
            this.cursor = Some(KeyRow::Item(item.clone()));
            let item = item.clone();
            this.stores
                .navigation
                .update(cx, |n, cx| n.open_item(item, cx));
        }))
        .on_mouse_down(
            MouseButton::Right,
            cx.listener(move |this, ev: &MouseDownEvent, window, cx| {
                cx.stop_propagation();
                let menu = crate::views::hermes_rooms::native_menu(&this.stores, &menu_id, cx);
                this.show_context_menu(menu_target.clone(), menu, ev.position, window, cx);
            }),
        )
        .into_any_element()
    }

    /// Shows `menu` at `position` for the row `target` (outlined while it
    /// is open).
    fn show_context_menu(
        &mut self,
        target: String,
        menu: NativeMenu,
        position: Point<Pixels>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.context_target = Some(target);
        cx.notify();
        menu.show(position, window, cx);
        cx.spawn(async move |this: WeakEntity<Self>, cx| {
            cx.background_executor()
                .timer(Duration::from_millis(300))
                .await;
            this.update(cx, |s, cx| {
                s.context_target = None;
                cx.notify();
            })
            .ok();
        })
        .detach();
    }

    /// Opens Hermes session `session_id`'s menu at `position`, with the
    /// open chat's own items (the toolbar's More) before Delete….
    pub fn hermes_context_menu(
        &mut self,
        session_id: &str,
        open_items: Vec<(String, Box<dyn Action>)>,
        position: Point<Pixels>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let Some(session) = self
            .stores
            .areas
            .read(cx)
            .hermes_session(session_id)
            .cloned()
        else {
            return;
        };
        let menu = crate::views::hermes_sessions::native_menu(&session, open_items, cx.l10n());
        let target = area_item_id(&AreaItem::HermesSession(session.id));
        self.context_target = Some(target);
        cx.notify();
        menu.show(position, window, cx);
        cx.spawn(async move |this: WeakEntity<Self>, cx| {
            cx.background_executor()
                .timer(Duration::from_millis(300))
                .await;
            this.update(cx, |s, cx| {
                s.context_target = None;
                cx.notify();
            })
            .ok();
        })
        .detach();
    }

    /// The Hermes switcher: the saved connections, the one in use checked,
    /// then Hermes Settings…; with one connection, Settings › Hermes.
    pub fn hermes_connection_menu(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let l = cx.l10n().clone();
        let admin = self.stores.hermes_admin.read(cx);
        let Some(list) = admin.connections.clone() else {
            return;
        };
        if list.connections.len() <= 1 {
            window.dispatch_action(Box::new(crate::actions::OpenHermesSettings), cx);
            return;
        }
        let mut menu = NativeMenu::new();
        for c in &list.connections {
            menu = menu.menu_with_check(
                c.name.clone(),
                c.active,
                Box::new(crate::actions::HermesSwitchConnection {
                    connection_id: c.id.clone(),
                }),
            );
        }
        menu.separator()
            .menu(
                l.desktop_hermes_settings_ellipsis(),
                Box::new(crate::actions::OpenHermesSettings),
            )
            .show(window.mouse_position(), window, cx);
    }

    /// Carries out `command` on Hermes session `session_id`: Rename here,
    /// in its row; the rest through the daemon.
    pub fn run_hermes(
        &mut self,
        session_id: &str,
        command: crate::views::hermes_sessions::HermesCommand,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        use crate::views::hermes_sessions::HermesCommand;
        if command == HermesCommand::Rename {
            self.start_rename_hermes(session_id, window, cx);
            return;
        }
        crate::views::hermes_sessions::run(&self.stores, session_id, command, window, cx);
    }

    /// Starts renaming Hermes session `session_id` in its row, which is
    /// shown first (its section open, its archived row too).
    pub fn start_rename_hermes(
        &mut self,
        session_id: &str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let Some(session) = self
            .stores
            .areas
            .read(cx)
            .hermes_session(session_id)
            .cloned()
            .filter(|s| !s.hidden)
        else {
            return;
        };
        let item = AreaItem::HermesSession(session.id.clone());
        self.stores.sections.update(cx, |s, cx| {
            s.set_collapsed(Area::Hermes.id(), false, cx);
            // Past the first few: every session listed.
            if !s.shows_all(Area::Hermes.id()) && !session.archived {
                s.set_show_all(Area::Hermes.id(), true, cx);
            }
        });
        if session.archived {
            self.hermes_archived = true;
        }
        self.cursor = Some(KeyRow::Item(item.clone()));
        self.reveal_row(|r| r.area_item() == Some(&item));
        self.edit_name(
            NameTarget::HermesSession(session.id),
            session.title,
            window,
            cx,
        );
    }

    /// Lists all of `area`, or its first few again.
    pub fn toggle_show_all(&mut self, area: Area, cx: &mut Context<Self>) {
        self.stores.sections.update(cx, |s, cx| {
            let all = !s.shows_all(area.id());
            s.set_show_all(area.id(), all, cx)
        });
    }

    fn header(&mut self, section: Section, t: &ConduitTheme, cx: &mut Context<Self>) -> AnyElement {
        let l = cx.l10n();
        let label: SharedString = match section {
            Section::Pinned => l.pinned(),
            Section::Folders => l.folders(),
            Section::Date(DateBucket::Today) => l.today(),
            Section::Date(DateBucket::Yesterday) => l.yesterday(),
            Section::Date(DateBucket::Previous7Days) => l.previous7_days(),
            Section::Date(DateBucket::Previous30Days) => l.previous30_days(),
            Section::Date(DateBucket::Month { year, month }) => {
                dates::month_title(year, month, &Local::now(), l.locale())
            }
            Section::Results => l.desktop_palette_results(),
        }
        .into();
        let id = match section {
            Section::Date(DateBucket::Month { year, month }) => format!("month-{year}-{month}"),
            Section::Date(b) => format!("{b:?}").to_lowercase(),
            other => format!("{other:?}").to_lowercase(),
        };
        let key = section.key();
        let expanded = section
            .collapsible()
            .then(|| !self.stores.sections.read(cx).is_collapsed(&key));
        // The Folders heading carries New Folder ("+"), as the phone's
        // drawer and the design's sidebar head that section: always there,
        // so it can be pointed at, tabbed to and named by VoiceOver.
        let add = (section == Section::Folders && self.can_make_folders(cx)).then(|| {
            let this = cx.entity().downgrade();
            IconButton::new("new-folder", IconName::Plus, l.desktop_new_folder())
                .size(20., 13.)
                .on_click(Rc::new(move |_, window, cx| {
                    // The heading under it would close the section.
                    cx.stop_propagation();
                    this.update(cx, |s, cx| s.start_new_folder(None, window, cx))
                        .ok();
                }))
                .into_any_element()
        });
        let header = match expanded {
            Some(open) if section.quiet_chevron() => quiet_section_header(&id, &label, open, t),
            _ => section_header(&id, &label, add, expanded, t),
        };
        // Under an area's heading, the Chats area's own sections step in to
        // the titles' column, a level below it.
        let header = if self.areas_shown {
            header
                .pl(px(ROW_CONTENT_INSET + ROW_STATUS_GUTTER))
                .aria_level(3)
        } else {
            header
        };
        let header = if expanded.is_some() {
            header.on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
                this.stores
                    .sections
                    .update(cx, |s, cx| s.toggle_collapsed(&key, cx));
            }))
        } else {
            header
        };
        // A date section takes a chat dragged out of its folder.
        if matches!(section, Section::Date(_)) {
            let hover = t.roles.selected;
            header
                .can_drop(|d, _, _| {
                    d.downcast_ref::<DraggedChat>()
                        .is_some_and(|d| d.folder_id.is_some() || d.chat_ids.len() > 1)
                })
                .drag_over::<DraggedChat>(move |s, _, _, _| s.bg(hover))
                .on_drop(cx.listener(|this, d: &DraggedChat, _, cx| this.drop_on(None, d, cx)))
                .into_any_element()
        } else {
            header.into_any_element()
        }
    }

    fn folder(
        &mut self,
        folder: &FolderSummary,
        depth: usize,
        expanded: bool,
        count: usize,
        t: &ConduitTheme,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let l = cx.l10n().clone();
        let id = folder.id.clone();
        let row = KeyRow::Folder(folder.id.clone());
        let state = RowState {
            selected: self.is_selection(&row),
            hovered: self.hovered.as_deref() == Some(&folder.id),
            keyboard: self.list_focused,
            drop_target: self.drop_target.as_deref() == Some(folder.id.as_str()),
            ..Default::default()
        };
        let hover = with_alpha(t.roles.selected_icon, if t.dark { 0.3 } else { 0.16 });
        let (toggle_id, drop_id, hover_id, target, menu_id, move_id) = (
            id.clone(),
            id.clone(),
            id.clone(),
            id.clone(),
            id.clone(),
            id.clone(),
        );
        // A shared folder's chats load when it opens; until then its count
        // is not known. Only a folder chats may be put in takes a drop.
        let known = !folder.shared || self.stores.chat_list.read(cx).has_folder_contents(&id);
        let writable = folder.can_write;
        let cursor = self.cursor.as_ref() == Some(&row);
        let field = self.name_field_for(&NameTarget::Folder(id.clone()), t, cx);
        let renaming = field.is_some();
        folder_row(
            &FolderLine {
                id: folder.id.clone().into(),
                name: folder.name.clone().into(),
                count: known.then_some(count),
                count_label: l.desktop_chat_count(count as i64).into(),
                expanded,
                badge: folder.shared.then(|| l.shared_badge().into()),
                emoji: folder.icon.clone().map(Into::into),
            },
            depth as f32 * NEST_INDENT,
            state,
            field,
            t,
        )
        .aria_level(depth + 1)
        .when(cursor && self.list_focused, |d| d.aria_active_descendant())
        .on_hover(cx.listener(move |this, on: &bool, _, cx| this.set_hovered(&hover_id, *on, cx)))
        .on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
            // A click in its own name field edits the name.
            if renaming {
                return;
            }
            this.cursor = Some(KeyRow::Folder(toggle_id.clone()));
            this.stores
                .chat_list
                .update(cx, |c, cx| c.toggle_folder(&toggle_id, cx));
        }))
        .on_mouse_down(
            MouseButton::Right,
            cx.listener(move |this, ev: &MouseDownEvent, window, cx| {
                // Not the list's own menu as well.
                cx.stop_propagation();
                this.folder_menu(&menu_id, expanded, ev.position, window, cx)
            }),
        )
        .can_drop(move |d, _, _| {
            writable
                && d.downcast_ref::<DraggedChat>()
                    .is_some_and(|d| accepts(d, &target))
        })
        .drag_over::<DraggedChat>(move |s, _, _, _| s.bg(hover))
        // Track the folder under the drag: outlined, and a closed one
        // springs open after a moment.
        .on_drag_move(
            cx.listener(move |this, e: &DragMoveEvent<DraggedChat>, _, cx| {
                let over = e.bounds.contains(&e.event.position);
                let takes = writable && accepts(e.drag(cx), &move_id);
                this.drag_over_folder(&move_id, over && takes, !expanded, cx);
            }),
        )
        .on_drop(cx.listener(move |this, d: &DraggedChat, _, cx| {
            this.end_drag(cx);
            this.drop_on(Some(drop_id.clone()), d, cx)
        }))
        .into_any_element()
    }

    /// The inline name field, when `target` is what it edits: a field
    /// filling the title's place, outlined in the focus colour, as Finder
    /// edits a name.
    fn name_field_for(
        &self,
        target: &NameTarget,
        t: &ConduitTheme,
        cx: &App,
    ) -> Option<AnyElement> {
        let rename = self.renaming.as_ref().filter(|r| &r.target == target)?;
        let l = cx.l10n();
        let (placeholder, ax_id) = match target {
            NameTarget::Chat(id) => (l.desktop_rename_prompt(), format!("rename-{id}")),
            NameTarget::Folder(id) => (l.folder_name(), format!("rename-folder-{id}")),
            NameTarget::HermesSession(id) => {
                (l.hermes_session_name_hint(), format!("rename-hermes-{id}"))
            }
            NameTarget::NewFolder { .. } => (l.folder_name(), "new-folder-name".to_string()),
        };
        Some(
            div()
                .flex_1()
                .min_w_0()
                .h(px(t.metrics.row_height - 6.))
                .px(px(5.))
                .flex()
                .items_center()
                .rounded(px(5.))
                // The composer's raised tone in dark (#181818), not the
                // column's #000, which read as a hole in the sidebar.
                .bg(conduit_components::views::kit::raised_fill(t))
                .border_1()
                .border_color(t.roles.focus)
                .child(
                    bare_input(&rename.input, placeholder, t.metrics.control)
                        .accessibility_id(SharedString::from(ax_id)),
                )
                .into_any_element(),
        )
    }

    /// The row of a folder being made: a folder glyph and its name field,
    /// where the folder will be.
    fn new_folder_row(
        &mut self,
        parent: Option<&str>,
        depth: usize,
        t: &ConduitTheme,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let target = NameTarget::NewFolder {
            parent: parent.map(String::from),
        };
        let field = self.name_field_for(&target, t, cx);
        let l = cx.l10n();
        folder_row(
            &FolderLine {
                id: "new".into(),
                name: SharedString::default(),
                count: None,
                count_label: SharedString::default(),
                expanded: false,
                badge: None,
                emoji: None,
            },
            depth as f32 * NEST_INDENT,
            RowState::default(),
            field,
            t,
        )
        .aria_label(SharedString::from(l.desktop_new_folder()))
        .aria_level(depth + 1)
        .into_any_element()
    }

    fn set_hovered(&mut self, id: &str, on: bool, cx: &mut Context<Self>) {
        let next = if on {
            Some(id.to_string())
        } else if self.hovered.as_deref() == Some(id) {
            None
        } else {
            return;
        };
        if self.hovered != next {
            self.hovered = next;
            cx.notify();
        }
    }

    /// Whether chat `chat`'s row shows the Unread dot: not on the chat on
    /// screen, which is being read, whichever row the keyboard stands on,
    /// unless it was marked unread here, until it is read again.
    fn shows_unread(&self, chat: &ChatSummary, cx: &App) -> bool {
        chat.unread
            && (self.stores.navigation.read(cx).selected_chat() != Some(chat.id.as_str())
                || self
                    .stores
                    .chat_list
                    .read(cx)
                    .marked_unread_here
                    .contains(&chat.id))
    }

    /// Chat `chat`'s row as the list draws it, and its state.
    fn chat_row_model(
        &self,
        chat: &ChatSummary,
        depth: usize,
        now: &DateTime<Local>,
        cx: &App,
    ) -> (ChatRow, RowState) {
        let l = cx.l10n();
        let id = chat.id.clone();
        // Dated the one way (as Notes dates its notes); under a date heading
        // (an unfiled chat's section) a date needs only its day and month.
        let dated = if depth == 0 && !chat.pinned && !chat.archived {
            dates::Dated::ByHeading
        } else {
            dates::Dated::Alone
        };
        let (time, spoken) = dates::stamp_in(chat.updated_at_ms, now, dated, l);
        let row = ChatRow {
            id: id.clone().into(),
            title: display_title(&chat.title, l),
            time: time.into(),
            time_spoken: spoken.into(),
            pinned: chat.pinned,
            streaming: false,
            working: false,
            reduce_motion: false,
            status: None,
            // Another user's chat in a shared folder: opened and read,
            // nothing else (the server refuses every change to it).
            note: chat.read_only.then(|| l.read_only().into()),
            unread: self.shows_unread(chat, cx),
            unread_spoken: Some(l.desktop_unread().into()),
        };
        let state = RowState {
            selected: self.is_selection(&KeyRow::Chat(id.clone())),
            hovered: self.hovered.as_deref() == Some(id.as_str()),
            context: self.context_target.as_deref() == Some(id.as_str()),
            drop_target: false,
            // A read-only chat takes no bulk change either: no checkbox.
            checked: self
                .selecting
                .as_ref()
                .filter(|_| self.checkboxes && !chat.read_only)
                .map(|s| s.contains(&id)),
            keyboard: self.list_focused,
        };
        (row, state)
    }

    fn chat(
        &mut self,
        chat: &ChatSummary,
        depth: usize,
        now: &DateTime<Local>,
        t: &ConduitTheme,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let l = cx.l10n().clone();
        let id = chat.id.clone();
        let read_only = chat.read_only;
        let (row, state) = self.chat_row_model(chat, depth, now, cx);
        let title = row.title.clone();
        let key_row = KeyRow::Chat(id.clone());
        let cursor = self.cursor.as_ref() == Some(&key_row);
        let hovered = state.hovered;
        let checked = state.checked;
        let in_selection = self.selecting.as_ref().is_some_and(|s| s.contains(&id));
        let field = self.name_field_for(&NameTarget::Chat(id.clone()), t, cx);
        // Hovering shows "…" alone, in place of the date: the commands are
        // in its menu (the row's context menu), as Mail's and Notes' rows
        // keep them, so the title keeps its room.
        let actions = if hovered && field.is_none() && !read_only {
            let quoted = format!("\u{201c}{title}\u{201d}");
            let this = cx.entity().downgrade();
            let menu_id = id.clone();
            vec![
                RowAction::new(
                    format!("more-{id}"),
                    IconName::Ellipsis,
                    l.desktop_more_actions_for(&quoted),
                )
                .tooltip(l.more())
                .on_click(Rc::new(move |e, window, cx| {
                    // The row under the button would open the chat too.
                    cx.stop_propagation();
                    let (id, position) = (menu_id.clone(), e.position());
                    this.update(cx, |s, cx| s.context_menu(&id, position, window, cx))
                        .ok();
                })),
            ]
        } else {
            vec![]
        };
        let (hover_id, click_id, menu_id) = (id.clone(), id.clone(), id.clone());
        let mut el = chat_row(&row, state, depth as f32 * NEST_INDENT, actions, field, t)
            .aria_level(depth + 1)
            .when(cursor && self.list_focused, |d| d.aria_active_descendant())
            .on_hover(
                cx.listener(move |this, on: &bool, _, cx| this.set_hovered(&hover_id, *on, cx)),
            )
            .on_click(cx.listener(move |this, ev: &ClickEvent, window, cx| {
                this.click(&click_id, ev, window, cx)
            }))
            .on_mouse_down(
                MouseButton::Right,
                cx.listener(move |this, ev: &MouseDownEvent, window, cx| {
                    // Not the list's own menu as well.
                    cx.stop_propagation();
                    this.context_menu(&menu_id, ev.position, window, cx)
                }),
            );
        if let Some(checked) = checked {
            el = el
                .role(Role::CheckBox)
                .aria_toggled(if checked {
                    Toggled::True
                } else {
                    Toggled::False
                })
                .aria_label(SharedString::from(l.desktop_select_chat(&title)));
        }
        // A selected chat drags the whole selection along; another drags
        // alone (with checkboxes, only the checked ones drag).
        let drags_selection = in_selection;
        let may_drag = self.selecting.is_none() || !self.checkboxes || drags_selection;
        if self.renaming.is_none() && may_drag && !read_only {
            let chat_ids = if drags_selection {
                self.selecting.iter().flatten().cloned().collect()
            } else {
                vec![id.clone()]
            };
            let dragged = DraggedChat {
                chat_id: id.clone(),
                title,
                folder_id: chat.folder_id.clone(),
                chat_ids,
                grab: Point::default(),
            };
            el = el.on_drag(dragged, |d: &DraggedChat, grab: Point<Pixels>, _, cx| {
                cx.new(|_| DraggedChat { grab, ..d.clone() })
            });
        }
        el.into_any_element()
    }

    /// A search hit, on a chat row's own metrics: its height (and the
    /// list's pitch), the title where every row's title starts, the date in
    /// the same slot, and the words that matched marked as the ⌘K palette
    /// marks them. A hit whose match is in the conversation, not the title,
    /// adds the matching line under it.
    fn search_hit(
        &mut self,
        hit: &ChatSearchHit,
        now: &DateTime<Local>,
        t: &ConduitTheme,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let l = cx.l10n().clone();
        let r = t.roles;
        let m = t.metrics;
        let id = hit.chat_id.clone();
        let title = display_title(&hit.title, &l);
        let (time, spoken) = dates::stamp(hit.updated_at_ms, now, &l);
        let key_row = KeyRow::Chat(id.clone());
        let selected = self.is_selection(&key_row);
        let cursor = self.cursor.as_ref() == Some(&key_row);
        let snippet = visible_snippet(hit);
        let query = self.stores.chat_list.read(cx).searched().to_string();
        let label = match &snippet {
            Some((text, _)) => format!("{title}, {text}"),
            None => title.to_string(),
        };
        let click_id = id.clone();
        let key = selected && self.list_focused;
        let ink = on_selection(r.sidebar_text, t, key);
        let subtle = if selected {
            on_selection(r.selected_text_subtle, t, key)
        } else {
            r.sidebar_text_subtle
        };
        let mut mark = match_highlight(t, ink);
        if key {
            // The palette's wash would vanish on the inverted fill.
            mark.background_color = Some(with_alpha(ink, 0.25));
        }
        let marked = |text: SharedString, ranges: Vec<std::ops::Range<usize>>| {
            StyledText::new(text)
                .with_highlights(ranges.into_iter().map(|rg| (rg, mark)).collect::<Vec<_>>())
        };
        let title_marks = find_words(&title, &query);
        let fill = selection_fill(t, self.list_focused);
        // A chat row's height; a snippet adds its line (as `row_height`).
        let height = m.row_height + if snippet.is_some() { SNIPPET_LINE } else { 0. };
        // Where a chat row's title starts: past its status column.
        let text_inset = ROW_CONTENT_INSET + ROW_STATUS_GUTTER;
        div()
            .id(ElementId::Name(format!("hit-{id}").into()))
            .role(Role::TreeItem)
            .aria_label(SharedString::from(label))
            .aria_description(SharedString::from(spoken))
            .aria_selected(selected)
            .when(cursor && self.list_focused, |d| d.aria_active_descendant())
            .w_full()
            .h(px(height))
            .pl(px(text_inset))
            .pr(px(ROW_CONTENT_INSET))
            .flex()
            .flex_col()
            .justify_center()
            .rounded(t.row_radius())
            .when(selected, |d| d.bg(fill))
            .when(!selected, |d| d.hover(|s| s.bg(r.hover)))
            .active(|s| {
                s.bg(conduit_components::views::focus::pressed_fill(
                    if selected { fill } else { r.hover },
                    t,
                ))
            })
            .cursor_pointer()
            .child(
                div()
                    .h(px(m.row_height))
                    .flex()
                    .flex_none()
                    .items_center()
                    .gap(px(8.))
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .truncate()
                            .text_size(px(m.control))
                            .text_color(ink)
                            .child(marked(title.clone(), title_marks)),
                    )
                    .child(
                        div()
                            .flex_none()
                            .min_w(px(ROW_ACTION_SLOT))
                            .flex()
                            .justify_end()
                            .text_size(px(m.small))
                            .text_color(subtle)
                            .child(time),
                    ),
            )
            .when_some(snippet, |d, (text, ranges)| {
                d.child(
                    div()
                        .mt(px(-SNIPPET_LIFT))
                        .pb(px(SNIPPET_LIFT))
                        .truncate()
                        .text_size(px(m.caption))
                        .text_color(subtle)
                        .child(marked(text.into(), ranges)),
                )
            })
            .on_click(cx.listener(move |this, ev: &ClickEvent, window, cx| {
                this.click(&click_id, ev, window, cx)
            }))
            .into_any_element()
    }

    // The keyboard.

    /// The list's one selection: while it has focus, the row the arrows
    /// stand on (a folder or footer row too); otherwise the open chat.
    pub fn selection(&self, cx: &App) -> Option<KeyRow> {
        selection_row(
            &self.rows,
            self.list_focused,
            self.cursor.as_ref(),
            self.open_row(cx).as_ref(),
        )
    }

    /// The row standing for what the main window shows.
    fn open_row(&self, cx: &App) -> Option<KeyRow> {
        KeyRow::of_selection(self.stores.navigation.read(cx).selection()).map(|row| {
            // A Bot Chat (a session no list shows) is its bot's row.
            match &row {
                KeyRow::Item(AreaItem::HermesSession(session))
                    if index_of(&self.rows, &row).is_none() =>
                {
                    self.stores
                        .hermes_rooms
                        .read(cx)
                        .bot_of_session(session)
                        .map(|b| KeyRow::Item(AreaItem::HermesBot(b.name.clone())))
                        .unwrap_or(row)
                }
                _ => row,
            }
        })
    }

    /// Whether `row` is drawn selected this frame: one of several selected
    /// chats, else the list's one selection.
    fn is_selection(&self, row: &KeyRow) -> bool {
        if let Some(set) = self.selecting.as_ref().filter(|_| !self.checkboxes) {
            return row.chat_id().is_some_and(|id| set.contains(id));
        }
        self.selected_row.as_ref() == Some(row)
    }

    // Dragging chats onto folders.

    /// The pointer moved over (`over`) or off folder `id` during a drag of
    /// chats it takes; a closed one (`closed`) springs open after
    /// [`SPRING_LOAD_DELAY`] under the pointer.
    fn drag_over_folder(&mut self, id: &str, over: bool, closed: bool, cx: &mut Context<Self>) {
        let here = self.drop_target.as_deref() == Some(id);
        if over && !here {
            self.drop_target = Some(id.to_string());
            self.spring = closed.then(|| {
                let folder = id.to_string();
                let task = cx.spawn(async move |this: WeakEntity<Self>, cx| {
                    cx.background_executor().timer(SPRING_LOAD_DELAY).await;
                    this.update(cx, |s, cx| s.spring_open(&folder, cx)).ok();
                });
                (id.to_string(), task)
            });
            cx.notify();
        } else if !over && here {
            self.drop_target = None;
            self.spring = None;
            cx.notify();
        }
    }

    /// The spring-load timer fired: open the folder still under the drag.
    fn spring_open(&mut self, id: &str, cx: &mut Context<Self>) {
        let still = self.drop_target.as_deref() == Some(id)
            && self.spring.as_ref().is_some_and(|(f, _)| f == id)
            && cx.has_active_drag();
        self.spring = None;
        if still && !self.stores.chat_list.read(cx).is_expanded(id) {
            self.stores
                .chat_list
                .update(cx, |c, cx| c.toggle_folder(id, cx));
        }
    }

    /// The drag ended (dropped, or let go elsewhere).
    fn end_drag(&mut self, cx: &mut Context<Self>) {
        if self.drop_target.take().is_some() | self.spring.take().is_some() {
            cx.notify();
        }
    }

    /// The folder a drag would drop into (tests and the capture read it).
    pub fn drop_target(&self) -> Option<&str> {
        self.drop_target.as_deref()
    }

    /// Moves focus into the list (Tab does too), the cursor on the open
    /// chat.
    pub fn focus_list(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.list_focus.focus(window, cx);
        self.ensure_cursor(cx);
        cx.notify();
    }

    /// Edit › Find… (⌘F): the search field, its text selected.
    pub fn focus_search(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.search.update(cx, |s, cx| {
            s.focus(window, cx);
            s.select_all(window, cx);
        });
    }

    /// Esc in the search field: clears a query, as NSSearchField's cancel
    /// does; in an empty field, leaves it for the message field.
    pub fn escape_search(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.search.read(cx).value().is_empty() {
            window.dispatch_action(Box::new(FocusComposer), cx);
        } else {
            self.clear_search(window, cx);
        }
    }

    /// The search field's ⓧ (or Esc): empties it, the list back.
    pub fn clear_search(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.search.update(cx, |s, cx| s.set_value("", window, cx));
        self.stores
            .chat_list
            .update(cx, |c, cx| c.set_query(String::new(), cx));
    }

    /// The row the keyboard stands on (tests and the capture read it).
    pub fn cursor(&self) -> Option<&KeyRow> {
        self.cursor.as_ref()
    }

    fn ensure_cursor(&mut self, cx: &App) {
        let listed = self
            .cursor
            .as_ref()
            .is_some_and(|c| index_of(&self.rows, c).is_some());
        if !listed {
            let open = KeyRow::of_selection(self.stores.navigation.read(cx).selection());
            self.cursor = initial_cursor(&self.rows, open.as_ref());
        }
    }

    /// An arrow key in the list.
    pub fn key(&mut self, key: ListKey, cx: &mut Context<Self>) {
        // A plain arrow goes back to one selection, as in Finder.
        if self.has_multiple_selection() {
            self.end_selection(cx);
        }
        self.ensure_cursor(cx);
        let at = self.cursor.as_ref().and_then(|c| index_of(&self.rows, c));
        match navigate(&self.rows, at, key) {
            ListMove::Cursor(ix) => {
                let Some(row) = KeyRow::of(&self.rows[ix]) else {
                    return;
                };
                self.scroll.scroll_to_item(ix, ScrollStrategy::Nearest);
                if let Some(id) = row.chat_id() {
                    let id = id.to_string();
                    self.stores.navigation.update(cx, |n, cx| n.open(id, cx));
                } else if let KeyRow::Item(item) = &row
                    // A bot's row opens its chat on Return or a click
                    // only: passing over it makes nothing.
                    && !matches!(item, AreaItem::HermesBot(_))
                {
                    let item = item.clone();
                    self.stores
                        .navigation
                        .update(cx, |n, cx| n.open_item(item, cx));
                }
                self.cursor = Some(row);
            }
            ListMove::Toggle(folder) => {
                self.stores
                    .chat_list
                    .update(cx, |c, cx| c.toggle_folder(&folder, cx));
            }
            ListMove::ToggleArea(area) => self.toggle_area(area, cx),
            ListMove::Stay => {}
        }
        cx.notify();
    }

    /// ⇧↑ or ⇧↓ in the list: the cursor moves to the chat before or after,
    /// and the selection runs from the anchor to it (Finder's and Mail's
    /// extend-selection keys).
    pub fn extend(&mut self, key: ListKey, cx: &mut Context<Self>) {
        if !matches!(key, ListKey::Up | ListKey::Down) || !self.bulk_supported(cx) {
            return;
        }
        self.ensure_cursor(cx);
        let Some(mut at) = self.cursor.as_ref().and_then(|c| index_of(&self.rows, c)) else {
            return;
        };
        // The range starts where the cursor stood, unless one is under way.
        if !self.has_multiple_selection() {
            self.anchor = self
                .cursor
                .as_ref()
                .and_then(|c| c.chat_id())
                .map(String::from);
        }
        // On to the next chat row, past folders and footers.
        let to = loop {
            match navigate(&self.rows, Some(at), key) {
                ListMove::Cursor(ix) => {
                    at = ix;
                    if let Some(id) =
                        KeyRow::of(&self.rows[ix]).and_then(|k| k.chat_id().map(String::from))
                    {
                        break id;
                    }
                }
                _ => return,
            }
        };
        self.scroll.scroll_to_item(at, ScrollStrategy::Nearest);
        self.cursor = Some(KeyRow::Chat(to.clone()));
        self.pick_chat(&to, Pick::Range, cx);
    }

    /// Return in the list: on to the composer from a chat; a folder's name
    /// is edited in place, as Finder renames on Return (another user's
    /// folder, which takes no rename, opens or closes instead).
    fn confirm(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.ensure_cursor(cx);
        match self.cursor.clone() {
            Some(KeyRow::Folder(id)) if self.owns_folder(&id, cx) => {
                self.start_rename_folder(&id, window, cx);
            }
            Some(KeyRow::Folder(id)) => {
                self.stores
                    .chat_list
                    .update(cx, |c, cx| c.toggle_folder(&id, cx));
            }
            Some(KeyRow::LoadMore) => {
                self.stores.chat_list.update(cx, |c, cx| c.load_more(cx));
            }
            Some(KeyRow::Archived) => {
                let visible = self
                    .stores
                    .chat_list
                    .read(cx)
                    .list
                    .as_ref()
                    .is_some_and(|l| l.archived_visible);
                self.stores
                    .chat_list
                    .update(cx, |c, cx| c.set_archived_visible(!visible, cx))
                    .detach();
            }
            Some(KeyRow::Area(area)) => self.toggle_area(area, cx),
            Some(KeyRow::ShowAll(area)) => self.toggle_show_all(area, cx),
            Some(KeyRow::HermesArchived) => {
                self.hermes_archived = !self.hermes_archived;
                cx.notify();
            }
            Some(KeyRow::Item(AreaItem::HermesBot(name))) => {
                crate::views::hermes_rooms::open_bot(&self.stores, &name, cx);
            }
            Some(KeyRow::HermesConnection) => self.hermes_connection_menu(window, cx),
            Some(KeyRow::HermesScheduledHidden) => {
                crate::views::settings::hermes::set_show_scheduled_runs(&self.stores, true, cx);
            }
            // Already shown in its pane.
            Some(KeyRow::Item(_)) => {}
            Some(KeyRow::Chat(_)) | None => {
                window.dispatch_action(Box::new(FocusComposer), cx);
            }
        }
    }

    /// Whether `folder_id` is the account's own folder (renamed and deleted
    /// by its owner only).
    fn owns_folder(&self, folder_id: &str, cx: &App) -> bool {
        self.stores
            .chat_list
            .read(cx)
            .folder(folder_id)
            .is_some_and(|f| !f.shared)
    }

    /// Whether New Folder is offered: an Open WebUI account whose server
    /// has folders on.
    pub fn can_make_folders(&self, cx: &App) -> bool {
        self.has_server(cx) && self.stores.chat_list.read(cx).folders_enabled()
    }

    /// The commands a folder's menu offers, in order (`None`: a
    /// separator), as Finder's and Mail's: new things in it, then its name
    /// and disclosure, then Delete apart at the end. Another user's folder
    /// offers only what its grant allows (a chat or subfolder in it with a
    /// write grant), never rename or delete.
    pub fn folder_menu_items(
        &self,
        folder: &FolderSummary,
        expanded: bool,
        cx: &App,
    ) -> Vec<Option<(String, FolderCommand)>> {
        let l = cx.l10n();
        let own = !folder.shared;
        let mut items = vec![];
        if folder.can_write {
            items.push(Some((l.desktop_folder_new_chat(), FolderCommand::NewChat)));
            if self.can_make_folders(cx) {
                items.push(Some((
                    l.desktop_new_subfolder(),
                    FolderCommand::NewSubfolder,
                )));
            }
            items.push(None);
        }
        // Its settings: the owner's name and icon, a writer's project
        // defaults (as mobile's folder page); sharing for the owner (the
        // sheet says when the server allows none).
        if offers_folder_settings(folder) {
            items.push(Some((
                l.desktop_folder_settings_menu(),
                FolderCommand::Settings,
            )));
        }
        if own && self.has_server(cx) {
            items.push(Some((l.desktop_share_folder_menu(), FolderCommand::Share)));
        }
        if own || folder.can_write {
            items.push(None);
        }
        if own {
            items.push(Some((l.desktop_rename_ellipsis(), FolderCommand::Rename)));
        }
        items.push(Some((
            if expanded {
                l.desktop_folder_collapse()
            } else {
                l.desktop_folder_expand()
            },
            FolderCommand::Toggle,
        )));
        if own {
            items.push(None);
            items.push(Some((
                l.desktop_delete_folder_ellipsis(),
                FolderCommand::Delete,
            )));
        }
        items
    }

    /// A folder's right-click menu ([`Self::folder_menu_items`]).
    fn folder_menu(
        &mut self,
        folder_id: &str,
        expanded: bool,
        position: Point<Pixels>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let Some(folder) = self.stores.chat_list.read(cx).folder(folder_id).cloned() else {
            return;
        };
        let mut menu = NativeMenu::new();
        for item in self.folder_menu_items(&folder, expanded, cx) {
            menu = match item {
                Some((label, command)) => menu.menu(
                    label,
                    Box::new(FolderMenu {
                        folder_id: folder_id.to_string(),
                        command,
                    }),
                ),
                None => menu.separator(),
            };
        }
        self.cursor = Some(KeyRow::Folder(folder_id.to_string()));
        cx.notify();
        menu.show(position, window, cx);
    }

    /// The list's own menu (a right click between rows): New Folder.
    fn list_menu(&mut self, position: Point<Pixels>, window: &mut Window, cx: &mut Context<Self>) {
        if !self.can_make_folders(cx) || self.stores.chat_list.read(cx).is_searching() {
            return;
        }
        let label = cx.l10n().desktop_new_folder();
        NativeMenu::new()
            .menu(label, Box::new(crate::actions::NewFolder))
            .show(position, window, cx);
    }

    /// Carries out a folder menu command.
    pub fn run_folder(
        &mut self,
        folder_id: &str,
        command: FolderCommand,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        match command {
            FolderCommand::Toggle => {
                self.stores
                    .chat_list
                    .update(cx, |c, cx| c.toggle_folder(folder_id, cx));
            }
            FolderCommand::NewChat => {
                let folder = folder_id.to_string();
                self.stores
                    .navigation
                    .update(cx, |n, cx| n.new_chat_in_folder(folder, cx));
                window.dispatch_action(Box::new(FocusComposer), cx);
            }
            FolderCommand::NewSubfolder => {
                self.start_new_folder(Some(folder_id.to_string()), window, cx)
            }
            FolderCommand::Rename => self.start_rename_folder(folder_id, window, cx),
            FolderCommand::Delete => self.confirm_delete_folder(folder_id, window, cx),
            FolderCommand::Settings => {
                crate::views::folder_settings::open(self.stores.clone(), folder_id, window, cx)
            }
            FolderCommand::Share => {
                let name = self
                    .stores
                    .chat_list
                    .read(cx)
                    .folder(folder_id)
                    .map(|f| f.name.clone())
                    .unwrap_or_default();
                crate::views::access_sheet::open_for_folder(
                    self.stores.clone(),
                    folder_id,
                    name,
                    window,
                    cx,
                )
            }
        }
    }

    // Acting on rows.

    fn click(
        &mut self,
        chat_id: &str,
        ev: &ClickEvent,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.is_renaming(Some(chat_id)) {
            return;
        }
        self.cursor = Some(KeyRow::Chat(chat_id.to_string()));
        // With checkboxes, any click ticks or unticks.
        if self.selecting.is_some() && self.checkboxes {
            if !self.is_read_only(chat_id, cx) {
                self.toggle_selected(chat_id, cx);
            }
            return;
        }
        let m = ev.modifiers();
        let how = if self.bulk_supported(cx) {
            Pick::of(m.platform, m.shift)
        } else {
            Pick::Only
        };
        self.pick_chat(chat_id, how, cx);
        // A selection gesture makes the list key, as clicking Finder's
        // does: ⌘⌫, the arrows and Esc then act on the selection. A plain
        // click leaves focus where it was (the message field).
        if how != Pick::Only {
            self.list_focus.focus(window, cx);
        }
    }

    /// Picks `chat_id` as a click with `how`'s modifiers would (the E2E and
    /// the capture call it for ⌘- and ⇧-clicks).
    pub fn pick_chat(&mut self, chat_id: &str, how: Pick, cx: &mut Context<Self>) {
        if how != Pick::Only && self.is_read_only(chat_id, cx) {
            return;
        }
        let store = self.stores.chat_list.read(cx);
        let pickable = |id: &str| store.find(id).is_none_or(|c| !c.read_only);
        let picked = pick(
            &self.rows,
            self.selecting.as_ref().filter(|_| !self.checkboxes),
            self.stores.navigation.read(cx).selected_chat(),
            self.anchor.as_deref(),
            chat_id,
            how,
            &pickable,
        );
        self.apply_pick(picked, cx);
    }

    fn apply_pick(&mut self, picked: Picked, cx: &mut Context<Self>) {
        match picked {
            Picked::Open(id) => {
                self.selecting = None;
                self.anchor = None;
                self.open(&id, cx);
            }
            Picked::Many { chats, anchor } => {
                self.selecting = Some(chats);
                self.checkboxes = false;
                self.anchor = Some(anchor);
            }
            Picked::Nothing => {
                self.selecting = None;
                self.anchor = None;
            }
        }
        cx.notify();
    }

    /// The folder the keyboard is on while the list has focus: what ⌘I
    /// (Get Info) opens the settings of.
    pub fn focused_folder(&self, window: &Window) -> Option<String> {
        if !self.list_focus.is_focused(window) {
            return None;
        }
        match &self.cursor {
            Some(KeyRow::Folder(id)) => Some(id.clone()),
            _ => None,
        }
    }

    /// The folder the keyboard is on, when its menu offers its settings.
    fn settings_folder(&self, window: &Window, cx: &App) -> Option<String> {
        self.focused_folder(window).filter(|id| {
            self.stores
                .chat_list
                .read(cx)
                .folder(id)
                .is_some_and(offers_folder_settings)
        })
    }

    /// Whether chats are chosen, by rows or checkboxes: the Chat menu's
    /// commands act on them or do nothing ([`Self::on_selection`]).
    pub fn has_selection(&self) -> bool {
        self.selecting.is_some()
    }

    /// Whether several chats are selected as rows (⌘- or ⇧-click), not by
    /// checkboxes.
    pub fn has_multiple_selection(&self) -> bool {
        self.selecting.is_some() && !self.checkboxes
    }

    /// Opens `chat_id` (a row's click).
    pub fn open(&mut self, chat_id: &str, cx: &mut Context<Self>) {
        let id = chat_id.to_string();
        self.stores.navigation.update(cx, |n, cx| n.open(id, cx));
    }

    /// Another user's chat in a shared folder, which takes no changes.
    fn is_read_only(&self, chat_id: &str, cx: &App) -> bool {
        self.stores
            .chat_list
            .read(cx)
            .find(chat_id)
            .is_some_and(|c| c.read_only)
    }

    /// Ticks or unticks `chat_id` with checkboxes ("Select Chats…",
    /// starting it).
    pub fn toggle_selected(&mut self, chat_id: &str, cx: &mut Context<Self>) {
        if self.selecting.is_none() {
            self.checkboxes = true;
        }
        let set = self.selecting.get_or_insert_with(BTreeSet::new);
        if !set.remove(chat_id) {
            set.insert(chat_id.to_string());
        }
        cx.notify();
    }

    /// Ends the multiple selection (or the checkboxes).
    pub fn end_selection(&mut self, cx: &mut Context<Self>) {
        self.anchor = None;
        if self.selecting.take().is_some() {
            cx.notify();
        }
    }

    /// Opens the native context menu for `chat_id` at `position`.
    pub fn context_menu(
        &mut self,
        chat_id: &str,
        position: Point<Pixels>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.context_menu_with(chat_id, vec![], position, window, cx)
    }

    /// [`Self::context_menu`] with the open chat's own items (the toolbar's
    /// More menu adds Chat Settings…, Tool Settings… and Show Branches…), in
    /// a group just before Delete…, where the Chat menu has them.
    pub fn context_menu_with(
        &mut self,
        chat_id: &str,
        open_items: Vec<(String, Box<dyn Action>)>,
        position: Point<Pixels>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let Some(chat) = self.stores.chat_list.read(cx).find(chat_id).cloned() else {
            return;
        };
        // Pin, rename, move, archive and delete all fail on another user's
        // chat; a phone offers no menu for it either.
        if chat.read_only {
            return;
        }
        // On a row of a multiple selection, the menu acts on all of it (as
        // Mail's); on another row it is that row's, and the selection goes.
        if self.has_multiple_selection() {
            if self.selecting.as_ref().is_some_and(|s| s.contains(chat_id)) {
                self.selected_menu(cx).show(position, window, cx);
                return;
            }
            self.end_selection(cx);
        }
        let menu = self.menu_for(NativeMenu::new(), &chat, open_items, cx);
        self.context_target = Some(chat_id.to_string());
        cx.notify();
        menu.show(position, window, cx);
        // The menu runs its own loop; the outline goes once it closes.
        cx.spawn(async move |this: WeakEntity<Self>, cx| {
            cx.background_executor()
                .timer(Duration::from_millis(300))
                .await;
            this.update(cx, |s, cx| {
                s.context_target = None;
                cx.notify();
            })
            .ok();
        })
        .detach();
    }

    /// The context menu's items for `chat`: what its menus offer by the
    /// core's rule for its backend (`ChatSummary::menu`: an Open WebUI
    /// chat's server actions, a LibreChat chat's Duplicate and links, none
    /// of either for an on-device Direct chat), in the order every chat
    /// menu shares.
    pub fn menu_items(&self, chat: &ChatSummary, cx: &App) -> Vec<(String, ChatCommand)> {
        if chat.read_only {
            return vec![];
        }
        let l = cx.l10n();
        let offered = &chat.menu;
        let mut items = vec![
            if chat.pinned {
                (l.desktop_unpin_chat(), ChatCommand::Unpin)
            } else {
                (l.desktop_pin_chat(), ChatCommand::Pin)
            },
            (l.desktop_rename_ellipsis(), ChatCommand::Rename),
        ];
        if offered.duplicate {
            items.push((l.libre_chat_duplicate_chat(), ChatCommand::Duplicate));
        }
        if offered.mark_unread {
            items.push(if chat.unread {
                (l.desktop_mark_as_read(), ChatCommand::MarkRead)
            } else {
                (l.mark_as_unread(), ChatCommand::MarkUnread)
            });
        }
        if offered.generate_title {
            items.push((l.generate_title(), ChatCommand::GenerateTitle));
        }
        if offered.share {
            items.push((l.desktop_share_chat_sheet(), ChatCommand::Share));
        }
        if offered.export {
            items.push((
                format!("{}…", l.chat_export_json()),
                ChatCommand::Export(conduit_protocol::ChatExportFormat::Json),
            ));
            items.push((
                format!("{}…", l.chat_export_markdown()),
                ChatCommand::Export(conduit_protocol::ChatExportFormat::Markdown),
            ));
        }
        if offered.r#move && chat.folder_id.is_some() {
            items.push((
                l.desktop_remove_from_folder(),
                ChatCommand::RemoveFromFolder,
            ));
        }
        items.push(if chat.archived {
            (l.unarchive(), ChatCommand::Unarchive)
        } else {
            (l.desktop_archive_chat(), ChatCommand::Archive)
        });
        if self.bulk_supported(cx) {
            items.push((l.desktop_select_chats(), ChatCommand::Select));
        }
        items.push((l.desktop_delete_ellipsis(), ChatCommand::Delete));
        // The order every chat menu shares (the Chat menu's too).
        items.sort_by_key(|(_, c)| ChatCommandSlot::of(c).rank());
        items
    }

    fn menu_for(
        &self,
        menu: NativeMenu,
        chat: &ChatSummary,
        open_items: Vec<(String, Box<dyn Action>)>,
        cx: &App,
    ) -> NativeMenu {
        let mut open_items = Some(open_items);
        let l = cx.l10n();
        let action = |command: ChatCommand| -> Box<dyn Action> {
            Box::new(ChatMenu {
                chat_id: chat.id.clone(),
                command,
            })
        };
        let folders = self
            .stores
            .chat_list
            .read(cx)
            .list
            .as_ref()
            .map(|l| l.folders.clone())
            .unwrap_or_default();
        let mut menu = menu;
        // Move To where the core's rule offers it (not a LibreChat or an
        // on-device chat) and there is a folder to move to.
        let mut filed = !chat.menu.r#move || folders.is_empty();
        let mut export: Option<NativeMenu> = None;
        for (label, command) in self.menu_items(chat, cx) {
            // Export's two formats go in one submenu, in its place.
            if let ChatCommand::Export(_) = command {
                export = Some(export.unwrap_or_default().menu(label, action(command)));
                continue;
            }
            if let Some(sub) = export.take() {
                menu = menu.submenu(l.chat_export_action(), sub);
            }
            // Move To takes its place in the shared order: after Share,
            // before the folder and archive items.
            if !filed && ChatCommandSlot::of(&command).rank() > ChatCommandSlot::MoveTo.rank() {
                // Only folders chats may be put in, as on a phone.
                let mut sorted: Vec<_> = folders.iter().filter(|f| f.can_write).cloned().collect();
                sorted.sort_by_key(|f| f.name.to_lowercase());
                let mut sub = NativeMenu::new();
                for f in sorted {
                    sub = sub.menu_with_check(
                        f.name.clone(),
                        chat.folder_id.as_deref() == Some(f.id.as_str()),
                        action(ChatCommand::MoveTo(f.id.clone())),
                    );
                }
                menu = menu.submenu(l.desktop_move_to_menu(), sub);
                filed = true;
            }
            if command == ChatCommand::Delete {
                menu = menu.separator();
                let open = open_items.take().unwrap_or_default();
                if !open.is_empty() {
                    for (label, item) in open {
                        menu = menu.menu(label, item);
                    }
                    menu = menu.separator();
                }
            }
            menu = menu.menu(label, action(command));
        }
        menu
    }

    /// Carries out `command` on `chat_id`.
    pub fn run(
        &mut self,
        chat_id: &str,
        command: ChatCommand,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.is_read_only(chat_id, cx) {
            return;
        }
        let id = chat_id.to_string();
        let list = self.stores.chat_list.clone();
        match command {
            ChatCommand::Pin | ChatCommand::Unpin => {
                let pin = command == ChatCommand::Pin;
                list.update(cx, |c, cx| c.set_pinned(&id, pin, cx)).detach();
            }
            ChatCommand::Archive | ChatCommand::Unarchive => {
                let archive = command == ChatCommand::Archive;
                list.update(cx, |c, cx| c.set_archived(&id, archive, cx))
                    .detach();
            }
            ChatCommand::Rename => self.start_rename(&id, window, cx),
            ChatCommand::Delete => self.confirm_delete(vec![id], window, cx),
            ChatCommand::Share => {
                crate::views::chat::share_sheet::open(id, window, cx);
            }
            ChatCommand::MarkUnread | ChatCommand::MarkRead => {
                let unread = command == ChatCommand::MarkUnread;
                list.update(cx, |c, cx| {
                    if unread {
                        c.marked_unread_here.insert(id.clone());
                    }
                    c.mark_unread(&id, unread, cx)
                })
                .detach();
            }
            ChatCommand::GenerateTitle => self.generate_title(&id, cx),
            ChatCommand::Duplicate => self.duplicate(&id, cx),
            ChatCommand::Export(format) => {
                crate::views::chat::export::export(id, format, window, cx)
            }
            ChatCommand::MoveTo(folder) => {
                list.update(cx, |c, cx| c.move_to(&id, Some(&folder), cx))
                    .detach();
            }
            ChatCommand::RemoveFromFolder => {
                list.update(cx, |c, cx| c.move_to(&id, None, cx)).detach();
            }
            ChatCommand::Select => {
                self.selecting = Some(BTreeSet::from([id]));
                self.checkboxes = true;
                cx.notify();
            }
        }
    }

    /// What a Chat menu command does while chats are chosen, by rows or
    /// checkboxes: Archive, Move to, Remove from Folder and Delete… act on
    /// them; the other commands do nothing, and the Chat menu greys them.
    /// `None` with nothing chosen, when it is the open chat's. A selection
    /// never falls through to the open chat.
    pub fn on_selection(&self, command: &ChatCommand) -> Option<OnSelection> {
        self.selecting.as_ref()?;
        Some(match bulk_action(command) {
            Some((action, folder)) => OnSelection::Bulk(action, folder),
            None => OnSelection::Nothing,
        })
    }

    /// Runs a Chat menu command on the chosen chats ([`Self::on_selection`]).
    /// False when nothing is chosen: the command is the open chat's.
    pub fn run_on_selection(
        &mut self,
        command: &ChatCommand,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> bool {
        match self.on_selection(command) {
            None => false,
            Some(OnSelection::Nothing) => true,
            Some(OnSelection::Bulk(action, folder)) => {
                self.bulk(action, folder, window, cx);
                true
            }
        }
    }

    /// A chat dropped on a folder (or, `None`, on a date section).
    pub fn drop_on(&mut self, folder_id: Option<String>, d: &DraggedChat, cx: &mut Context<Self>) {
        // Several chats: moved together, as the selection bar's Move does.
        if d.chat_ids.len() > 1 {
            let ids = d.chat_ids.clone();
            self.stores
                .chat_list
                .update(cx, |c, cx| c.bulk(ids, BulkChatAction::Move, folder_id, cx))
                .detach();
            self.selecting = None;
            cx.notify();
            return;
        }
        if d.folder_id == folder_id {
            return;
        }
        let id = d.chat_id.clone();
        self.stores
            .chat_list
            .update(cx, |c, cx| c.move_to(&id, folder_id.as_deref(), cx))
            .detach();
    }

    /// Starts renaming `chat_id` in place.
    pub fn start_rename(&mut self, chat_id: &str, window: &mut Window, cx: &mut Context<Self>) {
        let Some(chat) = self.stores.chat_list.read(cx).find(chat_id).cloned() else {
            return;
        };
        self.edit_name(
            NameTarget::Chat(chat_id.to_string()),
            chat.title,
            window,
            cx,
        );
    }

    /// Starts renaming folder `folder_id` in place (the account's own).
    pub fn start_rename_folder(
        &mut self,
        folder_id: &str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let Some(folder) = self
            .stores
            .chat_list
            .read(cx)
            .folder(folder_id)
            .filter(|f| !f.shared)
            .cloned()
        else {
            return;
        };
        self.cursor = Some(KeyRow::Folder(folder_id.to_string()));
        self.reveal_row(
            |r| matches!(r, SidebarItem::Folder { folder: f, .. } if f.id == folder.id),
        );
        self.edit_name(NameTarget::Folder(folder.id), folder.name, window, cx);
    }

    /// File › New Folder, the Folders heading's "+", or a folder's New
    /// Subfolder: a folder row with its name field, in `parent` (opened)
    /// or at the top of the Folders section, named "New Folder" (numbered
    /// when that is taken), the name selected. Return makes it.
    pub fn start_new_folder(
        &mut self,
        parent: Option<String>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if !self.can_make_folders(cx) {
            return;
        }
        // Search hides the folders; the new one is made in the list.
        if self.stores.chat_list.read(cx).is_searching() {
            self.search.update(cx, |s, cx| s.set_value("", window, cx));
            self.stores
                .chat_list
                .update(cx, |c, cx| c.set_query(String::new(), cx));
        }
        let siblings: Vec<String> = self
            .stores
            .chat_list
            .read(cx)
            .list
            .iter()
            .flat_map(|l| l.folders.iter())
            .filter(|f| !f.shared && f.parent_id == parent)
            .map(|f| f.name.clone())
            .collect();
        let name = unused_folder_name(
            &cx.l10n().desktop_new_folder(),
            siblings.iter().map(String::as_str),
        );
        // Its parent open, and the folders around it.
        if let Some(id) = &parent {
            let mut path = vec![id.clone()];
            let store = self.stores.chat_list.read(cx);
            let mut cursor = store.folder(id).and_then(|f| f.parent_id.clone());
            while let Some(up) = cursor.filter(|u| !path.contains(u)) {
                cursor = store.folder(&up).and_then(|f| f.parent_id.clone());
                path.push(up);
            }
            self.stores
                .chat_list
                .update(cx, |c, cx| c.reveal_folders(&path, cx));
        }
        // Where it will be is open: the Chats area and its Folders.
        self.stores.sections.update(cx, |s, cx| {
            s.set_collapsed(Area::Chats.id(), false, cx);
            s.set_collapsed(&Section::Folders.key(), false, cx);
        });
        self.edit_name(NameTarget::NewFolder { parent }, name, window, cx);
        // Scrolled to once the rows hold it (next frame).
        self.pending_new_folder = true;
    }

    /// Opens the inline name field for `target`, holding `name`, selected.
    fn edit_name(
        &mut self,
        target: NameTarget,
        name: String,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        // A second rename keeps the first one's way back.
        let restore = match self.renaming.take() {
            Some(previous) => previous.restore,
            None => window.focused(cx),
        };
        let input = cx.new(|cx| {
            let mut s = InputState::new(window, cx);
            s.set_value(name.clone(), window, cx);
            s
        });
        let subscription =
            cx.subscribe_in(&input, window, |this, _, e: &InputEvent, window, cx| {
                if let InputEvent::PressEnter { .. } | InputEvent::Blur = e {
                    this.commit_rename(window, cx)
                }
            });
        input.update(cx, |s, cx| {
            s.focus(window, cx);
            s.select_all(window, cx);
        });
        self.renaming = Some(Rename {
            target,
            original: name,
            input,
            restore,
            _subscription: subscription,
        });
        cx.notify();
    }

    /// Scrolls the list to the first row `matches` picks.
    fn reveal_row(&mut self, matches: impl Fn(&SidebarItem) -> bool) {
        if let Some(ix) = self.rows.iter().position(matches) {
            self.scroll.scroll_to_item(ix, ScrollStrategy::Nearest);
        }
    }

    /// Gives focus back after a rename. The field goes away with it, and a
    /// window with nothing focused dispatches actions (the context menu's
    /// included) to its root only, past the main window's handlers.
    fn end_rename(rename: Rename, window: &mut Window, cx: &mut Context<Self>) {
        if gpui_kit::Focusable::focus_handle(rename.input.read(cx), cx).is_focused(window)
            && let Some(focus) = rename.restore
        {
            window.focus(&focus, cx);
        }
    }

    /// Saves the name field: a chat's title, a folder's name, or a new
    /// folder by that name. An empty or unchanged name saves nothing (a new
    /// folder is then not made). A folder name another folder beside it
    /// has is refused with Finder's alert, and the field opens again.
    pub fn commit_rename(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(rename) = self.renaming.take() else {
            return;
        };
        let name = rename.input.read(cx).value().trim().to_string();
        let target = rename.target.clone();
        // A new folder keeps its suggested name; anything else unchanged
        // has nothing to save.
        let unchanged = !matches!(target, NameTarget::NewFolder { .. }) && name == rename.original;
        Self::end_rename(rename, window, cx);
        cx.notify();
        if name.is_empty() || unchanged {
            return;
        }
        let list = self.stores.chat_list.clone();
        match target {
            NameTarget::Chat(id) => {
                list.update(cx, |c, cx| c.rename(&id, &name, cx)).detach();
            }
            NameTarget::HermesSession(id) => {
                crate::views::hermes_sessions::rename(&self.stores, &id, &name, cx);
            }
            NameTarget::Folder(id) => {
                let parent = list.read(cx).folder(&id).and_then(|f| f.parent_id.clone());
                if self.folder_name_taken(&name, parent.as_deref(), Some(&id), cx) {
                    self.name_taken(NameTarget::Folder(id), name, window, cx);
                    return;
                }
                list.update(cx, |c, cx| c.rename_folder(&id, &name, cx))
                    .detach();
            }
            NameTarget::NewFolder { parent } => {
                if self.folder_name_taken(&name, parent.as_deref(), None, cx) {
                    self.name_taken(NameTarget::NewFolder { parent }, name, window, cx);
                    return;
                }
                let task = list.update(cx, |c, cx| c.create_folder(&name, parent.as_deref(), cx));
                cx.spawn(async move |this: WeakEntity<Self>, cx| {
                    let Ok(folder) = task.await else {
                        return;
                    };
                    // The new folder is selected, as Finder selects it.
                    this.update(cx, |s, cx| {
                        s.cursor = Some(KeyRow::Folder(folder.id.clone()));
                        // Scrolled to now if the rows already hold it, else
                        // once they do.
                        let id = folder.id;
                        match s.rows.iter().position(
                            |r| matches!(r, SidebarItem::Folder { folder, .. } if folder.id == id),
                        ) {
                            Some(ix) => s.scroll.scroll_to_item(ix, ScrollStrategy::Nearest),
                            None => s.pending_reveal_folder = Some(id),
                        }
                        cx.notify();
                    })
                    .ok();
                })
                .detach();
            }
        }
    }

    /// Whether a folder of the account beside `parent` is already called
    /// `name` (in any case, as Open WebUI compares), other than `except`.
    fn folder_name_taken(
        &self,
        name: &str,
        parent: Option<&str>,
        except: Option<&str>,
        cx: &App,
    ) -> bool {
        let lower = name.to_lowercase();
        self.stores
            .chat_list
            .read(cx)
            .list
            .iter()
            .flat_map(|l| l.folders.iter())
            .any(|f| {
                Some(f.id.as_str()) != except
                    && !f.shared
                    && f.parent_id.as_deref() == parent
                    && f.name.to_lowercase() == lower
            })
    }

    /// Finder's answer to a taken name: an alert, then the field again with
    /// the name as typed, selected.
    fn name_taken(
        &mut self,
        target: NameTarget,
        name: String,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let l = cx.l10n().clone();
        let spec = SheetSpec::notice(
            l.desktop_folder_name_taken(&name),
            l.desktop_folder_name_taken_message(),
            l.ok(),
        );
        let ask = present_sheet(window, spec, cx);
        let window_handle = window.window_handle();
        cx.spawn(async move |this: WeakEntity<Self>, cx| {
            ask.await;
            window_handle
                .update(cx, |_, window, cx| {
                    this.update(cx, |s, cx| s.edit_name(target, name, window, cx))
                        .ok();
                })
                .ok();
        })
        .detach();
    }

    /// Esc while a name field has focus: leaves it without saving, and the
    /// key goes no further.
    fn leave_name_field(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let focused = self.renaming.as_ref().is_some_and(|r| {
            gpui_kit::Focusable::focus_handle(r.input.read(cx), cx).is_focused(window)
        });
        if focused {
            self.cancel_rename(window, cx);
            cx.stop_propagation();
        }
    }

    /// Leaves the name field without saving (a new folder is not made).
    pub fn cancel_rename(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if let Some(rename) = self.renaming.take() {
            Self::end_rename(rename, window, cx);
            cx.notify();
        }
    }

    /// Whether a chat's rename field is open (for `chat_id`, when given).
    pub fn is_renaming(&self, chat_id: Option<&str>) -> bool {
        self.renaming.as_ref().is_some_and(|r| match &r.target {
            NameTarget::Chat(id) => chat_id.is_none_or(|c| c == id),
            _ => chat_id.is_none(),
        })
    }

    /// What the open name field edits.
    pub fn name_target(&self) -> Option<&NameTarget> {
        self.renaming.as_ref().map(|r| &r.target)
    }

    /// The rename field, while one is open.
    pub fn rename_input(&self) -> Option<Entity<InputState>> {
        self.renaming.as_ref().map(|r| r.input.clone())
    }

    /// Delete Folder… (or ⌘⌫ on a folder): asks first, saying the chats in
    /// it are kept, then deletes the folder and its subfolders. The open
    /// chat stays open (it only leaves the folder).
    pub fn confirm_delete_folder(
        &mut self,
        folder_id: &str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let store = self.stores.chat_list.read(cx);
        let Some(folder) = store.folder(folder_id).filter(|f| !f.shared).cloned() else {
            return;
        };
        let has_subfolders = store
            .list
            .iter()
            .flat_map(|l| l.folders.iter())
            .any(|f| f.parent_id.as_deref() == Some(folder.id.as_str()));
        let l = cx.l10n().clone();
        let spec = SheetSpec::new(
            l.desktop_delete_folder_title(&folder.name),
            if has_subfolders {
                l.desktop_delete_folder_with_subfolders()
            } else {
                l.desktop_delete_folder_keeps_chats()
            },
            l.delete(),
            l.cancel(),
        )
        .destructive();
        let ask = present_sheet(window, spec, cx);
        let id = folder.id;
        cx.spawn(async move |this: WeakEntity<Self>, cx| {
            if !ask.await {
                return;
            }
            this.update(cx, |s, cx| {
                if s.cursor == Some(KeyRow::Folder(id.clone())) {
                    s.cursor = None;
                }
                s.stores
                    .chat_list
                    .update(cx, |c, cx| c.delete_folder(&id, cx))
                    .detach();
                cx.notify();
            })
            .ok();
        })
        .detach();
    }

    fn confirm_delete(&mut self, ids: Vec<String>, window: &mut Window, cx: &mut Context<Self>) {
        let l = cx.l10n().clone();
        let spec = if ids.len() == 1 {
            SheetSpec::new(
                l.delete_chat_title(),
                l.desktop_confirm_delete(),
                l.delete(),
                l.cancel(),
            )
        } else {
            SheetSpec::new(
                l.desktop_bulk_delete_confirm(ids.len() as i64),
                l.desktop_confirm_delete(),
                l.delete(),
                l.cancel(),
            )
        }
        .destructive();
        let ask = present_sheet(window, spec, cx);
        cx.spawn(async move |this: WeakEntity<Self>, cx| {
            if !ask.await {
                return;
            }
            this.update(cx, |s, cx| {
                // The open chat goes too: show a new one instead.
                let open = s
                    .stores
                    .navigation
                    .read(cx)
                    .selected_chat()
                    .map(String::from);
                if open.is_some_and(|o| ids.contains(&o)) {
                    s.stores
                        .navigation
                        .update(cx, |n, cx| n.new_chat(false, cx));
                }
                let list = s.stores.chat_list.clone();
                if let [id] = ids.as_slice() {
                    list.update(cx, |c, cx| c.delete(id, cx)).detach();
                    // A selection of just this chat is done with too.
                    if s.selecting.as_ref().is_some_and(|sel| sel.contains(id)) {
                        s.selecting = None;
                    }
                } else {
                    list.update(cx, |c, cx| c.bulk(ids, BulkChatAction::Delete, None, cx))
                        .detach();
                    s.selecting = None;
                }
                cx.notify();
            })
            .ok();
        })
        .detach();
    }

    /// Generate Title: the server's model titles the chat; says so when it
    /// wrote none, or could not.
    fn generate_title(&mut self, chat_id: &str, cx: &mut Context<Self>) {
        let task = self
            .stores
            .chat_list
            .update(cx, |c, cx| c.generate_title(chat_id, cx));
        cx.spawn(async move |this: WeakEntity<Self>, cx| {
            let result = task.await;
            this.update(cx, |s, cx| {
                let l = cx.l10n().clone();
                match result {
                    Ok(t) if t.outcome == conduit_protocol::GenerateTitleOutcome::None => {
                        s.toast(NoticeLevel::Info, l.generate_title_none(), cx)
                    }
                    Ok(_) => {}
                    Err(_) => s.toast(NoticeLevel::Error, l.generate_title_failed(), cx),
                }
            })
            .ok();
        })
        .detach();
    }

    /// Duplicate Chat: LibreChat copies the chat whole, on its server
    /// (`librechat.duplicate`); the copy opens, as on the phone.
    fn duplicate(&mut self, chat_id: &str, cx: &mut Context<Self>) {
        let rpc = self.stores.connection.read(cx).rpc();
        let call =
            rpc.call::<conduit_protocol::methods::LibrechatDuplicate>(&conduit_protocol::ChatRef {
                id: chat_id.to_string(),
            });
        let navigation = self.stores.navigation.clone();
        let list = self.stores.chat_list.clone();
        // The copy is the account's the command was given under: once
        // another one is in charge, it is not opened in its window.
        let accounts = self.stores.accounts.clone();
        let scope = accounts.read(cx).scope_key();
        cx.spawn(async move |this: WeakEntity<Self>, cx| {
            let result = call.await;
            let _ = this.update(cx, |s, cx| match result {
                Ok(_) if accounts.read(cx).scope_key() != scope => {}
                Ok(copy) => {
                    list.update(cx, |l, cx| l.refresh(cx));
                    navigation.update(cx, |n, cx| n.open(copy.chat_id, cx));
                }
                Err(e) => {
                    log::warn!("librechat.duplicate: {e}");
                    let l = cx.l10n().clone();
                    s.toast(NoticeLevel::Error, l.libre_chat_copy_failed(), cx);
                }
            });
        })
        .detach();
    }

    #[allow(dead_code)]
    fn share(&mut self, chat_id: &str, cx: &mut Context<Self>) {
        let server = self
            .stores
            .accounts
            .read(cx)
            .active()
            .map(|a| a.connection.url.clone());
        let Some(server) = server else {
            return;
        };
        let task = self
            .stores
            .chat_list
            .update(cx, |c, cx| c.share(chat_id, true, None, cx));
        cx.spawn(async move |this: WeakEntity<Self>, cx| {
            let Ok(share) = task.await else {
                return;
            };
            let Some(share_id) = share.share_id else {
                return;
            };
            let url = share_url(&server, &share_id);
            this.update(cx, |s, cx| {
                cx.write_to_clipboard(gpui_kit::ClipboardItem::new_string(url));
                let text = cx.l10n().desktop_share_link_copied();
                s.toast(NoticeLevel::Success, text, cx);
            })
            .ok();
        })
        .detach();
    }

    // The list's ends.

    /// How far the list's ends fade, at most: about a row's height, the
    /// transcript's own fade under the toolbar.
    const LIST_FADE: f32 = 16.;

    /// What fades the list's ends instead of cutting rows off: under the
    /// search field once scrolled, and into the footer's rule while more is
    /// below, each easing in over as far as it is scrolled (up to
    /// [`Self::LIST_FADE`]), so the list at rest is whole.
    ///
    /// On the translucent sidebar, a mask on the window's content
    /// (`ListEdges`), synced from where the list was painted (a canvas
    /// filling it), with any tooltip or drag image kept whole; on a solid
    /// sidebar, its colour painted over the ends.
    fn edges(&self, window: &Window, t: &ConduitTheme, cx: &App) -> AnyElement {
        let offset = (-f32::from(self.scroll.offset().y)).max(0.);
        let max = f32::from(self.scroll.max_offset().y).max(0.);
        let fade_top = offset.min(Self::LIST_FADE);
        let fade_bottom = (max - offset).clamp(0., Self::LIST_FADE);
        let material = t.prefs.sidebar == SidebarStyle::Material;
        if !material {
            self.clear_edges(window);
            let surface = t.roles.sidebar;
            let fade = |height: f32, angle: f32| {
                div()
                    .absolute()
                    .left_0()
                    .right_0()
                    .h(px(height))
                    .bg(gpui_kit::linear_gradient(
                        angle,
                        gpui_kit::linear_color_stop(surface, 0.),
                        gpui_kit::linear_color_stop(with_alpha(surface, 0.), 1.),
                    ))
            };
            return div()
                .absolute()
                .size_full()
                .top_0()
                .left_0()
                .when(fade_top > 0.5, |d| d.child(fade(fade_top, 180.).top_0()))
                .when(fade_bottom > 0.5, |d| {
                    d.child(fade(fade_bottom, 0.).bottom_0())
                })
                .into_any_element();
        }
        #[cfg(target_os = "macos")]
        {
            let edges = self.edges.clone();
            // Sliding in or out: the mask stays off until the panel has
            // stood still (it would run ahead of it; `edge_strength`).
            let moving = crate::views::main_window::SidebarReveal::of(true, cx) < 1.;
            gpui_kit::canvas(
                |_, _, _| {},
                move |bounds, _, window, cx| {
                    let keep = conduit_components::views::overlays::take_overlays(window, cx);
                    let mut edges = edges.borrow_mut();
                    let edges = edges.get_or_insert_with(ListEdges::default);
                    let (strength, coming) = edges.settle(moving, cx.reduce_motion());
                    if coming {
                        window.request_animation_frame();
                    }
                    // Nothing scrolled past either end: no mask at all.
                    let band =
                        (strength > 0. && (fade_top > 0.5 || fade_bottom > 0.5)).then(|| {
                            EdgeBand {
                                left: f32::from(bounds.left()),
                                right: f32::from(bounds.right()),
                                top: f32::from(bounds.top()),
                                bottom: f32::from(bounds.bottom()),
                                fade_top,
                                fade_bottom,
                                strength,
                            }
                        });
                    edges.sync(window, band, &keep);
                },
            )
            .absolute()
            .top_0()
            .left_0()
            .size_full()
            .into_any_element()
        }
        #[cfg(not(target_os = "macos"))]
        {
            let _ = (fade_top, fade_bottom, cx);
            div().into_any_element()
        }
    }

    /// Takes the list's fade off the window (the sidebar is not drawn, or
    /// is solid).
    pub fn clear_edges(&self, window: &Window) {
        #[cfg(target_os = "macos")]
        if let Some(edges) = self.edges.borrow_mut().as_mut() {
            edges.sync(window, None, &[]);
            edges.forget_rest();
        }
        #[cfg(not(target_os = "macos"))]
        let _ = window;
    }

    // Selection mode.

    /// Archives, deletes or moves the chosen chats.
    pub fn bulk(
        &mut self,
        action: BulkChatAction,
        folder_id: Option<String>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let ids: Vec<String> = self.selecting.iter().flatten().cloned().collect();
        if ids.is_empty() {
            return;
        }
        if action == BulkChatAction::Delete {
            self.confirm_delete(ids, window, cx);
            return;
        }
        self.stores
            .chat_list
            .update(cx, |c, cx| c.bulk(ids, action, folder_id, cx))
            .detach();
        self.selecting = None;
        cx.notify();
    }

    /// The chosen chats' "Move to" menu: No Folder, then every folder chats
    /// may be put in, by name.
    fn move_selected_menu(&self, cx: &App) -> NativeMenu {
        let mut folders: Vec<FolderSummary> = self
            .stores
            .chat_list
            .read(cx)
            .list
            .as_ref()
            .map(|l| l.folders.iter().filter(|f| f.can_write).cloned().collect())
            .unwrap_or_default();
        folders.sort_by_key(|f| f.name.to_lowercase());
        let mut menu = NativeMenu::new().menu(
            cx.l10n().desktop_no_folder(),
            Box::new(MoveSelected { folder_id: None }),
        );
        if !folders.is_empty() {
            menu = menu.separator();
        }
        for f in folders {
            menu = menu.menu(
                f.name.clone(),
                Box::new(MoveSelected {
                    folder_id: Some(f.id.clone()),
                }),
            );
        }
        menu
    }

    /// The context menu of a multiple selection: what the bar above the
    /// list does, in the chat menus' order (Mail's menu with several
    /// messages selected).
    fn selected_menu(&self, cx: &App) -> NativeMenu {
        let l = cx.l10n();
        NativeMenu::new()
            .submenu(l.desktop_move_to_menu(), self.move_selected_menu(cx))
            .menu(
                l.desktop_archive_chat(),
                Box::new(ActOnSelected {
                    action: BulkChatAction::Archive,
                }),
            )
            .separator()
            .menu(
                l.desktop_delete_ellipsis(),
                Box::new(ActOnSelected {
                    action: BulkChatAction::Delete,
                }),
            )
    }

    fn selection_bar(&mut self, t: &ConduitTheme, cx: &mut Context<Self>) -> Option<AnyElement> {
        let count = self.selecting.as_ref()?.len();
        let l = cx.l10n().clone();
        let r = t.roles;
        let this = cx.entity().downgrade();
        let act = |action: BulkChatAction| -> ClickHandler {
            let this = this.clone();
            Rc::new(move |_, window, cx| {
                this.update(cx, |s, cx| s.bulk(action, None, window, cx))
                    .ok();
            })
        };
        let move_menu: ClickHandler = {
            let this = this.clone();
            Rc::new(move |ev, window, cx| {
                let position = ev.position();
                if let Ok(menu) = this.update(cx, |s, cx| s.move_selected_menu(cx)) {
                    menu.show(position, window, cx);
                }
            })
        };
        let checkboxes = self.checkboxes;
        // ⌘⌫ deletes the selection while the list is key.
        let delete_keys = self.list_focused.then(|| {
            SharedString::from(crate::keymap::describe(
                &crate::keymap::fixed_stroke(crate::keymap::FixedCommand::DeleteChat),
                cfg!(target_os = "macos"),
            ))
        });
        let done: ClickHandler = {
            let this = this.clone();
            Rc::new(move |_, _, cx| {
                this.update(cx, |s, cx| s.end_selection(cx)).ok();
            })
        };
        let summary = l.desktop_selected_count(count as i64);
        Some(
            div()
                .id("selection-bar")
                .role(Role::Toolbar)
                .aria_label(SharedString::from(summary.clone()))
                .flex_none()
                .mx(px(10.))
                .mb(px(6.))
                .h(px(t.metrics.control_height + 4.))
                .px(px(6.))
                .flex()
                .items_center()
                .gap(px(2.))
                .rounded(t.control_radius())
                .bg(with_alpha(r.text, if t.dark { 0.08 } else { 0.05 }))
                .child(
                    div()
                        .flex_1()
                        .min_w_0()
                        .truncate()
                        .pl(px(4.))
                        .text_size(px(t.metrics.small))
                        .text_color(r.sidebar_text)
                        .child(summary),
                )
                .child(
                    IconButton::new("bulk-archive", IconName::Archive, l.desktop_archive_chat())
                        .size(26., 16.)
                        .on_click(act(BulkChatAction::Archive)),
                )
                .child(
                    IconButton::new("bulk-move", IconName::Folder, l.desktop_move_selected())
                        .size(26., 16.)
                        .on_click(move_menu),
                )
                .child(
                    IconButton::new("bulk-delete", IconName::Trash, l.desktop_delete_ellipsis())
                        .size(26., 16.)
                        .shortcut(delete_keys)
                        .on_click(act(BulkChatAction::Delete)),
                )
                // Done in words, as Mail's Edit/Done: what ends the
                // checkboxes reads as a command, not as one more glyph beside
                // the three actions. A selection made with ⌘ or ⇧ ends as
                // Finder's does (a plain click, an arrow, Esc).
                .when(checkboxes, |d| {
                    d.child(div().w(px(4.)))
                        .child(Button::new("bulk-done", l.done()).ghost().on_click(done))
                })
                .into_any_element(),
        )
    }
}

/// How long a closed folder stays under a dragged chat before it springs
/// open (Finder waits about as long).
pub const SPRING_LOAD_DELAY: Duration = Duration::from_millis(700);

/// A folder's menu offers Folder Settings… (and ⌘I opens them): its owner's
/// folder, or one shared with a write grant.
fn offers_folder_settings(folder: &FolderSummary) -> bool {
    !folder.shared || folder.can_write
}

/// Whether folder `folder_id` takes the dragged chats: several always, one
/// unless it is already there.
fn accepts(d: &DraggedChat, folder_id: &str) -> bool {
    d.chat_ids.len() > 1 || d.folder_id.as_deref() != Some(folder_id)
}

/// A button row under the list ("Load more", "Archived"), selected when
/// the arrows stand on it.
fn footer_button(
    id: &'static str,
    label: String,
    expanded: Option<bool>,
    trailing: Option<String>,
    selected: bool,
    list_key: bool,
    t: &ConduitTheme,
) -> gpui_kit::Stateful<gpui_kit::Div> {
    let r = t.roles;
    let m = t.metrics;
    let fill = selection_fill(t, list_key);
    // The phone's Archived row: a section-style label, its count, and a
    // disclosure chevron at the trailing edge.
    div()
        .id(id)
        .role(Role::TreeItem)
        .aria_label(SharedString::from(label.clone()))
        .aria_selected(selected)
        .when(selected, |d| d.aria_active_descendant())
        .when_some(expanded, |d, e| d.aria_expanded(e))
        .h(px(m.row_height))
        .px(px(conduit_components::views::sidebar::ROW_CONTENT_INSET))
        .flex()
        .items_center()
        .gap(px(6.))
        .rounded(t.row_radius())
        .cursor_pointer()
        .when(selected, |d| d.bg(fill))
        .when(!selected, |d| d.hover(|s| s.bg(r.hover)))
        .active(|s| {
            s.bg(conduit_components::views::focus::pressed_fill(
                if selected { fill } else { r.hover },
                t,
            ))
        })
        .text_size(px(m.small))
        .font_weight(FontWeight::SEMIBOLD)
        .text_color(on_selection(r.sidebar_text_subtle, t, selected && list_key))
        .child(div().flex_1().child(label))
        .when_some(trailing, |d, tr| {
            d.child(
                div()
                    .font_weight(FontWeight::NORMAL)
                    .text_size(px(m.small))
                    .child(tr),
            )
        })
        .when_some(expanded, |d, e| {
            d.child(icon(
                if e {
                    IconName::ChevronDown
                } else {
                    IconName::ChevronRight
                },
                12.,
                r.sidebar_text_subtle,
            ))
        })
}

/// Whether the sidebar lists Hermes's Scheduled Agents: the connection
/// in use is reachable for jobs (as far as its status says; until it is
/// read, as long as one is in use).
fn hermes_jobs_shown(admin: &crate::stores::hermes_admin::HermesAdminStore) -> bool {
    if admin.active().is_none() || !admin.connections.as_ref().is_some_and(|l| l.enabled) {
        return false;
    }
    admin
        .status
        .as_ref()
        .and_then(crate::stores::hermes_admin::Loaded::ready)
        .is_none_or(|s| s.capabilities.jobs || !s.reachable)
}

/// The Hermes section's switcher row: the connection in use, by its
/// initials and name, and with more than one saved, the pop-up's ⌃⌄.
fn hermes_connection_row(
    name: &str,
    count: usize,
    selected: bool,
    list_key: bool,
    t: &ConduitTheme,
    l: &L10n,
) -> gpui_kit::Stateful<gpui_kit::Div> {
    let r = t.roles;
    let m = t.metrics;
    let fill = selection_fill(t, list_key);
    let switches = count > 1;
    let initials = hermes_initials(name);
    div()
        .id("hermes-connection-switcher")
        .role(if switches {
            Role::ComboBox
        } else {
            Role::TreeItem
        })
        .aria_label(SharedString::from(name.to_string()))
        .when(switches, |d| {
            d.aria_description(SharedString::from(l.hermes_switch_connection_title()))
        })
        .aria_selected(selected)
        .when(selected, |d| d.aria_active_descendant())
        .h(px(m.row_height + 4.))
        .px(px(conduit_components::views::sidebar::ROW_CONTENT_INSET))
        .flex()
        .items_center()
        .gap(px(8.))
        .rounded(t.row_radius())
        .when(selected, |d| d.bg(fill))
        .when(switches && !selected, |d| d.hover(|s| s.bg(r.hover)))
        .when(switches, |d| {
            d.cursor_pointer().active(|s| {
                s.bg(conduit_components::views::focus::pressed_fill(
                    if selected { fill } else { r.hover },
                    t,
                ))
            })
        })
        .when(switches, |d| {
            d.tip(l.hermes_switch_connection_title(), None)
        })
        .child(
            div()
                .size(px(20.))
                .flex_none()
                .rounded_full()
                .flex()
                .items_center()
                .justify_center()
                .bg(conduit_components::theme::with_alpha(
                    r.text,
                    if t.dark { 0.14 } else { 0.08 },
                ))
                .text_size(px(9.5))
                .font_weight(FontWeight::BOLD)
                .text_color(r.sidebar_text_subtle)
                .child(SharedString::from(initials)),
        )
        .child(
            div()
                .flex_1()
                .min_w_0()
                .truncate()
                .text_size(px(m.control))
                .font_weight(FontWeight::SEMIBOLD)
                .text_color(on_selection(r.sidebar_text, t, selected && list_key))
                .child(SharedString::from(name.to_string())),
        )
        .when(switches, |d| {
            d.child(icon(IconName::ChevronsUpDown, 12., r.sidebar_text_subtle))
        })
}

/// Up to two initials for a Hermes connection's name, as the phone's
/// switcher draws them ("HA", Hermes Agent, without a usable name).
pub fn hermes_initials(name: &str) -> String {
    let words: Vec<&str> = name
        .split(|c: char| c.is_whitespace() || c == '.' || c == '_' || c == '-')
        .filter(|w| !w.is_empty())
        .collect();
    let initials: String = match words.as_slice() {
        [] => "HA".into(),
        [one] => one.chars().take(2).collect(),
        [a, b, ..] => a.chars().take(1).chain(b.chars().take(1)).collect(),
    };
    initials.to_uppercase()
}

fn hint_text(hint: Hint, l: &L10n) -> String {
    match hint {
        Hint::Loading => l.loading_short(),
        Hint::NoChats => l.desktop_no_chats_yet(),
        Hint::Syncing => l.desktop_syncing(),
        Hint::NoResults => l.desktop_search_no_results(),
        Hint::SearchIncomplete => l.desktop_search_incomplete(),
        Hint::Failed => l.desktop_action_failed(),
    }
}

/// A hit's snippet without its markers, unless it only repeats the title.
fn visible_snippet(hit: &ChatSearchHit) -> Option<(String, Vec<std::ops::Range<usize>>)> {
    hit.snippet
        .as_deref()
        .map(parse_snippet)
        .filter(|(text, _)| text.trim() != hit.title.trim())
}

/// How far each level of folders steps in: a subfolder's glyph sits about
/// under its parent's name (as in Finder's outline), its chats clearly in
/// from it.
const NEST_INDENT: f32 = 20.;

/// Room under the last row, inside the list (which runs down to the
/// footer's rule).
const LIST_TAIL: f32 = 6.;

/// The line a search hit's snippet adds under its title, and how far it
/// tucks up under it.
const SNIPPET_LINE: f32 = 16.;
const SNIPPET_LIFT: f32 = 4.;

/// The gap above a heading: an area's, the space Finder leaves between its
/// groups; a section's, a line's worth, except right under its area's
/// heading or at the top.
fn header_gap(item: &SidebarItem, previous: Option<&SidebarItem>) -> f32 {
    match (item, previous) {
        (_, None) => 0.,
        (SidebarItem::AreaHeader { .. }, Some(_)) => AREA_GAP,
        (
            SidebarItem::Header(_) | SidebarItem::HermesGroup { .. },
            Some(SidebarItem::AreaHeader { .. }),
        ) => 0.,
        (SidebarItem::Header(_) | SidebarItem::HermesGroup { .. }, Some(_)) => 10.,
        _ => 0.,
    }
}

/// A row's height. Headings carry the gap above them.
fn row_height(item: &SidebarItem, previous: Option<&SidebarItem>, t: &ConduitTheme) -> f32 {
    let row = t.metrics.row_height + 1.;
    match item {
        SidebarItem::Header(_)
        | SidebarItem::AreaHeader { .. }
        | SidebarItem::HermesGroup { .. } => SECTION_HEADER_HEIGHT + header_gap(item, previous),
        SidebarItem::SearchHit(hit) if visible_snippet(hit).is_some() => row + SNIPPET_LINE,
        SidebarItem::Hint(_) => 52.,
        _ => row,
    }
}

/// A Hermes session's name in its row, as the phone's tile: its title,
/// else (Hermes left it untitled: a cron or messaging session) the start
/// of what it says, else "Untitled Conversation".
pub fn hermes_title(session: &HermesSessionDto, l: &L10n) -> String {
    let title = session.title.trim();
    if !title.is_empty() && title != "Untitled session" {
        return title.to_string();
    }
    session
        .preview
        .as_deref()
        .map(str::trim)
        .filter(|p| !p.is_empty())
        .map(|p| p.lines().next().unwrap_or(p).to_string())
        .unwrap_or_else(|| l.hermes_session_untitled())
}

/// An area item's id among the rows (hover, AccessKit, the E2E).
pub fn area_item_id(item: &AreaItem) -> String {
    match item {
        AreaItem::AllNotes => "all-notes".into(),
        AreaItem::Note(id) => format!("note-{id}"),
        AreaItem::Channel(id) => format!("channel-{id}"),
        AreaItem::HermesSession(id) => format!("hermes-{id}"),
        AreaItem::HermesHidden => "hermes-hidden".into(),
        AreaItem::HermesBot(name) => format!("bot-{name}"),
        AreaItem::HermesRoom(id) => format!("room-{id}"),
        AreaItem::HermesJobs => "hermes-jobs".into(),
        AreaItem::Workspace(section) => format!("workspace-{}", section.id()),
        AreaItem::Terminal(id) => format!("terminal-{id}"),
        AreaItem::Calendar => "calendar".into(),
        AreaItem::Automations => "automations".into(),
    }
}

/// What an area says instead of rows.
fn area_hint_text(area: Area, hint: AreaHint, l: &L10n) -> String {
    match (area, hint) {
        (_, AreaHint::Loading) => l.loading_short(),
        (Area::Notes, AreaHint::Empty) => l.no_notes_yet(),
        (Area::Channels, AreaHint::Empty) => l.channel_empty_state(),
        (Area::Hermes, AreaHint::Empty) => l.hermes_no_conversations_message(),
        (_, AreaHint::Empty) => l.terminal_no_servers_configured(),
        (Area::Notes, AreaHint::Failed) => l.failed_to_load_notes(),
        (Area::Channels, AreaHint::Failed) => l.channel_load_error(),
        (Area::Hermes, AreaHint::Failed) => l.desktop_hermes_sessions_failed(),
        (_, AreaHint::Failed) => l.desktop_action_failed(),
        (_, AreaHint::ArchivedFailed) => l.hermes_archived_load_error(),
    }
}

/// The rows for the store as it is: search hits while a query is typed,
/// else the sections; a hint when there is nothing to list.
fn build_rows(store: &ChatListStore, has_account: bool, now: &DateTime<Local>) -> Vec<SidebarItem> {
    if store.is_searching() {
        let mut rows = vec![SidebarItem::Header(Section::Results)];
        // Hits for another query (one still on its way, or one that failed)
        // are not this query's.
        let current = store
            .results
            .as_ref()
            .filter(|_| store.searched() == store.query().trim());
        match current {
            Some(results) => {
                rows.extend(results.hits.iter().cloned().map(SidebarItem::SearchHit));
                if results.hits.is_empty() && results.complete {
                    rows.push(SidebarItem::Hint(Hint::NoResults));
                }
                if !results.complete {
                    rows.push(SidebarItem::Hint(Hint::SearchIncomplete));
                }
            }
            None if !store.searching && store.search_error.is_some() => {
                rows.push(SidebarItem::Hint(Hint::Failed))
            }
            None => rows.push(SidebarItem::Hint(Hint::Loading)),
        }
        return rows;
    }
    let Some(list) = store.merged() else {
        return vec![SidebarItem::Hint(if store.load_error.is_some() {
            Hint::Failed
        } else {
            Hint::Loading
        })];
    };
    let sections = build_sidebar(&list, now);
    let rows = flatten(&sections, &store.expanded(), &list);
    if rows.is_empty() {
        // "No conversations yet" is only true once a sync has finished, or
        // when there is no server to sync with (direct or Hermes only).
        let synced = store.sync.as_ref().is_none_or(|s| s.ever_completed);
        return vec![SidebarItem::Hint(if synced || !has_account {
            Hint::NoChats
        } else {
            Hint::Syncing
        })];
    }
    rows
}

impl Render for SidebarView {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let started = std::time::Instant::now();
        self.rebuild_if_needed(cx);
        let focused = self.list_focus.is_focused(window);
        if focused && !self.list_focused {
            self.ensure_cursor(cx);
        }
        self.list_focused = focused;
        self.selected_row = self.selection(cx);
        let t = cx.conduit().clone();
        let l = cx.l10n().clone();
        let sync = sync_state(self.stores.chat_list.read(cx), &l);
        let account = footer_account(&self.stores, cx);
        let banner = self.selection_bar(&t, cx);
        let list = v_virtual_list(
            cx.entity(),
            "sidebar-rows",
            self.sizes.clone(),
            |this, range, _, cx| this.render_rows(range, cx),
        )
        .track_scroll(&self.scroll)
        .size_full();
        // A drag that ended anywhere leaves no outline or timer behind.
        if !cx.has_active_drag() && (self.drop_target.is_some() || self.spring.is_some()) {
            self.drop_target = None;
            self.spring = None;
        }
        let body = div()
            .id("sidebar-list")
            // An outline, as Finder's and Mail's sidebars: rows with their
            // level, selected and expanded states.
            .role(Role::Tree)
            .aria_label(SharedString::from(l.desktop_chats_label()))
            .key_context(SIDEBAR_LIST_CONTEXT)
            .track_focus(&self.list_focus)
            // ⌘I (Get Info) on a folder with settings: they open. Anywhere
            // else no handler here, so Chat › Chat Settings… is the open
            // chat's, greyed while it offers none.
            .when(self.settings_folder(window, cx).is_some(), |d| {
                d.on_action(
                    cx.listener(|this, _: &crate::actions::ChatSettings, window, cx| {
                        match this.settings_folder(window, cx) {
                            Some(id) => crate::views::folder_settings::open(
                                this.stores.clone(),
                                &id,
                                window,
                                cx,
                            ),
                            None => cx.propagate(),
                        }
                    }),
                )
            })
            // A click opens a row without taking focus from the composer;
            // Tab is the way in, as in a source list.
            .on_mouse_down(MouseButton::Left, |_, window, _| window.prevent_default())
            .on_key_down(cx.listener(|this, ev: &KeyDownEvent, window, cx| {
                // A row's name field passes on the keys it has no use for
                // (Return, ↑ and ↓, ← at its start): they are not the list's.
                if !this.list_focus.is_focused(window) {
                    return;
                }
                let k = &ev.keystroke;
                let m = &k.modifiers;
                if m.shift && !(m.platform || m.alt || m.control) {
                    if let Some(key) = ListKey::from_key(&k.key) {
                        this.extend(key, cx);
                        cx.stop_propagation();
                    }
                    return;
                }
                if m.platform || m.alt || m.control || m.shift {
                    return;
                }
                if let Some(key) = ListKey::from_key(&k.key) {
                    this.key(key, cx);
                    cx.stop_propagation();
                } else if k.key == "enter" {
                    this.confirm(window, cx);
                    cx.stop_propagation();
                }
            }))
            // ⌘⌫ (Chat › Delete…) on the row the keyboard is on: a chat, or
            // the account's own folder (Delete Folder…, which asks first).
            .on_action(cx.listener(|this, _: &DeleteChat, window, cx| {
                if this.run_on_selection(&ChatCommand::Delete, window, cx) {
                    return;
                }
                match this.cursor.clone() {
                    Some(KeyRow::Chat(id)) => this.run(&id, ChatCommand::Delete, window, cx),
                    Some(KeyRow::Folder(id)) => this.confirm_delete_folder(&id, window, cx),
                    _ => {}
                }
            }))
            // A right click between rows: the list's own menu (New Folder).
            .on_mouse_down(
                MouseButton::Right,
                cx.listener(|this, ev: &MouseDownEvent, window, cx| {
                    this.list_menu(ev.position, window, cx)
                }),
            )
            .flex_1()
            .min_h_0()
            .relative()
            .child(list)
            .child(self.edges(window, &t, cx));
        let search = bare_input(&self.search, l.desktop_search_chats(), t.metrics.control)
            .accessibility_id("sidebar-search-field");
        // While it holds a query: its ⓧ, in the hint's place.
        let clear_search: Option<ClickHandler> =
            (!self.search.read(cx).value().is_empty()).then(|| {
                let this = cx.entity().downgrade();
                Rc::new(move |_: &ClickEvent, window: &mut Window, cx: &mut App| {
                    this.update(cx, |s, cx| s.clear_search(window, cx)).ok();
                }) as ClickHandler
            });
        let stores = self.stores.clone();
        // Rows can run under the footer once the list is taller than its
        // space (laid out last frame; a new length shows a frame later).
        let overflows = self.scroll.max_offset().y > px(1.);
        let frame = SidebarFrame::new(body, sync, account)
            .overflows(overflows)
            .search(search)
            .on_clear_search(clear_search)
            .banner(banner)
            .on_toggle(Rc::new(|_, window, cx| {
                window.dispatch_action(Box::new(ToggleSidebar), cx)
            }))
            .on_new_chat(Rc::new(|_, window, cx| {
                window.dispatch_action(Box::new(NewChat), cx)
            }))
            .on_settings(Rc::new(|_, window, cx| {
                window.dispatch_action(Box::new(OpenSettings), cx)
            }))
            .on_account(Rc::new(|_, _, cx| {
                crate::open_settings(Some(crate::views::settings::Tab::Accounts), cx)
            }))
            .on_sync(Rc::new(move |_, _, cx| {
                stores.chat_list.update(cx, |c, cx| {
                    c.refresh(cx);
                    c.refresh_sync(cx);
                })
            }));
        self.work.set(self.work.get() + started.elapsed());
        div()
            .id("sidebar-root")
            .h_full()
            .flex_none()
            // Esc in the search field (the field passes it on): clears it,
            // then leaves it.
            .on_action(
                cx.listener(|this, _: &gpui_kit::component::input::Escape, window, cx| {
                    // Only the search field's (a name field's Esc is the
                    // capture handlers' below).
                    if gpui_kit::Focusable::focus_handle(this.search.read(cx), cx)
                        .is_focused(window)
                    {
                        this.escape_search(window, cx)
                    } else {
                        cx.propagate();
                    }
                }),
            )
            // Esc in a name field leaves it without saving. The app's Esc
            // (Stop Generating) and the field would take the key first; the
            // capture phase reaches the sidebar before either.
            .capture_action(cx.listener(
                |this, _: &gpui_kit::component::input::Escape, window, cx| {
                    this.leave_name_field(window, cx)
                },
            ))
            .capture_action(
                cx.listener(|this, _: &crate::actions::StopGenerating, window, cx| {
                    this.leave_name_field(window, cx)
                }),
            )
            // Esc leaves a rename without saving, then selection mode.
            .capture_key_down(cx.listener(|this, ev: &KeyDownEvent, window, cx| {
                if ev.keystroke.key == "escape" {
                    if this.is_renaming(None) {
                        this.cancel_rename(window, cx);
                        cx.stop_propagation();
                    } else if this.selecting.is_some() {
                        this.end_selection(cx);
                        cx.stop_propagation();
                    }
                }
            }))
            .child(frame)
    }
}

#[cfg(test)]
mod selection_tests {
    use gpui_kit::{TestAppContext, VisualTestContext};

    use super::*;
    use crate::stores::accounts::tests::{account, list};
    use crate::stores::rpc::fake::FakeDaemon;

    fn bench(cx: &mut TestAppContext) -> (Stores, Entity<SidebarView>, &mut VisualTestContext) {
        bench_on(FakeDaemon::new(), cx)
    }

    fn bench_on(
        daemon: FakeDaemon,
        cx: &mut TestAppContext,
    ) -> (Stores, Entity<SidebarView>, &mut VisualTestContext) {
        let scratch = std::env::temp_dir().join(format!("conduit-sidebar-{}", std::process::id()));
        let stores = cx.update(|cx| {
            gpui_kit::init(cx);
            conduit_components::theme::install(
                conduit_components::theme::ConduitTheme::new(
                    "conduit",
                    false,
                    conduit_components::theme::DesignPrefs::default(),
                    gpui_kit::black(),
                ),
                cx,
            );
            cx.set_global(conduit_components::Strings::default());
            cx.set_global(crate::l10n::L10n::new("en"));
            Stores::for_test(daemon.rpc(), &scratch, cx)
        });
        stores.accounts.update(cx, |a, cx| {
            a.adopt(list(vec![account("a", "Avery", true, true)]), cx)
        });
        let s = stores.clone();
        let (view, vcx) = cx.add_window_view(move |window, cx| SidebarView::new(s, window, cx));
        (stores, view, vcx)
    }

    /// Two chats and an empty folder of the account's own, as the daemon
    /// lists them (a rename answers with the same list).
    fn two_chats_and_a_folder() -> FakeDaemon {
        use conduit_protocol::methods;
        let now = Local::now().timestamp_millis();
        let list: conduit_protocol::ChatList = serde_json::from_value(serde_json::json!({
            "chats": [
                {"id": "chat-a", "title": "Tide tables", "updatedAtMs": now},
                {"id": "chat-b", "title": "Bread starter", "updatedAtMs": now - 1},
            ],
            "folders": [{"id": "recipes", "name": "Recipes"}],
        }))
        .unwrap();
        let daemon = FakeDaemon::new();
        daemon.returns::<methods::ChatsList>(list.clone());
        daemon.returns::<methods::ChatsRename>(list);
        daemon
    }

    /// Return in a chat's name field saves the name typed, with the list's
    /// keyboard row on a folder (where a click on it leaves the row): not
    /// the list's Return, which edits that folder's name instead.
    #[gpui_kit::test]
    fn return_in_a_name_field_saves_it_whatever_row_the_keyboard_is_on(cx: &mut TestAppContext) {
        use conduit_protocol::methods;
        let daemon = two_chats_and_a_folder();
        let (stores, view, vcx) = bench_on(daemon.clone(), cx);
        stores.chat_list.update(vcx, |c, cx| c.refresh(cx));
        vcx.run_until_parked();
        view.update_in(vcx, |s, window, cx| {
            s.cursor = Some(KeyRow::Folder("recipes".into()));
            s.start_rename("chat-a", window, cx);
        });
        vcx.simulate_input("tide charts");
        vcx.simulate_keystrokes("enter");
        assert_eq!(
            daemon.calls::<methods::ChatsRename>(),
            vec![serde_json::json!({"id": "chat-a", "title": "tide charts"})]
        );
        view.read_with(vcx, |s, _| {
            assert_eq!(s.name_target(), None, "a name field is still open")
        });
    }

    /// The arrows, Home and End in a name field are the field's: they move
    /// its caret, never the list's keyboard row, the open chat or the
    /// chosen chats.
    #[gpui_kit::test]
    fn arrows_in_a_name_field_move_its_caret_not_the_list(cx: &mut TestAppContext) {
        let (stores, view, vcx) = bench_on(two_chats_and_a_folder(), cx);
        stores.chat_list.update(vcx, |c, cx| c.refresh(cx));
        stores.navigation.update(vcx, |n, cx| n.open("chat-a", cx));
        vcx.run_until_parked();
        view.update_in(vcx, |s, window, cx| {
            s.cursor = Some(KeyRow::Chat("chat-a".into()));
            s.start_rename("chat-a", window, cx);
        });
        vcx.simulate_input("neap");
        // ↑ and ↓ have no line to go to in the field; → at its end and ←
        // at its start nowhere either. Each is checked on its own: ↓ then
        // ↑ would come back to the same row.
        for key in ["down", "up", "right", "shift-down", "home", "left"] {
            vcx.simulate_keystrokes(key);
            view.read_with(vcx, |s, _| {
                assert_eq!(s.cursor(), Some(&KeyRow::Chat("chat-a".into())), "{key}");
                assert!(s.selecting.is_none(), "{key} chose chats");
            });
            stores.navigation.read_with(vcx, |n, _| {
                assert_eq!(
                    n.selected_chat(),
                    Some("chat-a"),
                    "{key} opened another chat"
                )
            });
        }
        vcx.simulate_input("spring ");
        view.read_with(vcx, |s, cx| {
            assert_eq!(
                s.rename_input().map(|i| i.read(cx).value().to_string()),
                Some("spring neap".to_string())
            );
        });
    }

    /// Esc in a name field leaves it without saving. The window's own Esc,
    /// Stop Generating, which the chat pane takes anywhere, does not get it
    /// first (and stop a reply).
    #[gpui_kit::test]
    fn esc_in_a_name_field_leaves_it_and_stops_no_reply(cx: &mut TestAppContext) {
        use crate::actions::StopGenerating;
        use conduit_protocol::methods;
        let daemon = two_chats_and_a_folder();
        let (stores, view, vcx) = bench_on(daemon.clone(), cx);
        stores.chat_list.update(vcx, |c, cx| c.refresh(cx));
        vcx.run_until_parked();
        // Esc as the default keymap binds it, taken on the app as the chat
        // pane takes it.
        let stopped = Rc::new(std::cell::Cell::new(false));
        vcx.update(|_, cx| {
            cx.bind_keys([gpui_kit::KeyBinding::new("escape", StopGenerating, None)]);
            let stopped = stopped.clone();
            cx.on_action(move |_: &StopGenerating, _| stopped.set(true));
        });
        view.update_in(vcx, |s, window, cx| s.start_rename("chat-a", window, cx));
        vcx.simulate_input("neap");
        vcx.simulate_keystrokes("escape");
        view.read_with(vcx, |s, _| {
            assert_eq!(s.name_target(), None, "the name field is still open")
        });
        assert!(!stopped.get(), "Esc in the name field stopped a reply");
        assert!(daemon.calls::<methods::ChatsRename>().is_empty());
    }

    /// With chats chosen, the Chat menu greys what the selection would
    /// swallow (Rename… and the other commands for one chat: a selection
    /// never falls through to the open chat), and keeps what acts on all
    /// of the chosen chats.
    #[gpui_kit::test]
    fn the_chat_menu_greys_one_chat_commands_while_chats_are_chosen(cx: &mut TestAppContext) {
        use crate::menus::{ChatMenuState, MenuState, build_menus, export_disabled};
        let (stores, view, vcx) = bench_on(two_chats_and_a_folder(), cx);
        stores.chat_list.update(vcx, |c, cx| c.refresh(cx));
        stores.navigation.update(vcx, |n, cx| n.open("chat-a", cx));
        vcx.run_until_parked();
        // The open chat as the menu bar reads it, everything offered.
        let state = |choosing: bool| MenuState {
            choosing,
            chat: Some(ChatMenuState {
                pinned: false,
                archived: false,
                folder_id: None,
                unread: false,
                offered: conduit_protocol::ChatMenuAbilities {
                    share: true,
                    duplicate: true,
                    r#move: true,
                    mark_unread: true,
                    generate_title: true,
                    export: true,
                },
                branches: false,
            }),
            ..MenuState::default()
        };
        let greyed = |state: &MenuState| -> Vec<String> {
            let menus = build_menus(&L10n::new("en"), state);
            let chat = menus.iter().find(|m| m.name.as_ref() == "Chat").unwrap();
            chat.items
                .iter()
                .filter_map(|i| match i {
                    gpui_kit::MenuItem::Action { name, disabled, .. } if *disabled => {
                        Some(name.to_string())
                    }
                    _ => None,
                })
                .collect()
        };
        let one_chat = [
            "Pin",
            "Mark as Unread",
            "Rename…",
            "Duplicate Chat",
            "Generate Title",
            "Share Chat…",
        ];

        // ⌘-click on B, A open: both chosen.
        view.update(vcx, |s, cx| s.pick_chat("chat-b", Pick::Toggle, cx));
        let chosen = state(view.read_with(vcx, |s, _| s.has_selection()));
        let off = greyed(&chosen);
        for name in one_chat {
            assert!(off.iter().any(|o| o == name), "{name} is on: {off:?}");
        }
        assert!(export_disabled(&chosen), "Export Chat is on");
        for name in ["Archive", "Delete…"] {
            assert!(!off.iter().any(|o| o == name), "{name} is off");
        }

        // A plain click: A alone, its commands back.
        view.update(vcx, |s, cx| s.pick_chat("chat-a", Pick::Only, cx));
        let one = state(view.read_with(vcx, |s, _| s.has_selection()));
        let off = greyed(&one);
        for name in one_chat {
            assert!(!off.iter().any(|o| o == name), "{name} is off: {off:?}");
        }
        assert!(!export_disabled(&one));
    }

    #[gpui_kit::test]
    fn a_checkbox_selection_never_falls_through_to_the_open_chat(cx: &mut TestAppContext) {
        let (stores, view, vcx) = bench(cx);
        // Chat A open; "Select Chats…" on B.
        stores.navigation.update(vcx, |n, cx| n.open("chat-a", cx));
        view.update_in(vcx, |s, window, cx| {
            s.run("chat-b", ChatCommand::Select, window, cx)
        });
        view.read_with(vcx, |s, _| {
            assert_eq!(
                s.on_selection(&ChatCommand::Delete),
                Some(OnSelection::Bulk(BulkChatAction::Delete, None))
            );
            assert_eq!(
                s.selecting
                    .as_ref()
                    .map(|c| c.iter().cloned().collect::<Vec<_>>()),
                Some(vec!["chat-b".to_string()])
            );
            // Commands for one chat do nothing while chats are chosen.
            assert_eq!(
                s.on_selection(&ChatCommand::Pin),
                Some(OnSelection::Nothing)
            );
            assert_eq!(
                s.on_selection(&ChatCommand::Rename),
                Some(OnSelection::Nothing)
            );
        });
        // Every box unticked: still nothing for the open chat.
        view.update(vcx, |s, cx| s.toggle_selected("chat-b", cx));
        view.read_with(vcx, |s, _| {
            assert_eq!(
                s.on_selection(&ChatCommand::Delete),
                Some(OnSelection::Bulk(BulkChatAction::Delete, None))
            );
        });
        view.update(vcx, |s, cx| s.end_selection(cx));
        view.read_with(vcx, |s, _| {
            assert_eq!(s.on_selection(&ChatCommand::Delete), None)
        });
    }

    /// Go › a section and back (⌘2, then ⌘1) leaves the chat on screen
    /// selected: the keyboard comes back to its row, not to the heading.
    /// Another section's heading, or Chats with a note shown, keeps the
    /// keyboard on the heading.
    #[gpui_kit::test]
    fn going_back_to_chats_selects_the_chat_on_screen(cx: &mut TestAppContext) {
        let (stores, view, vcx) = bench_on(two_chats_and_a_folder(), cx);
        stores.session.update(vcx, |s, cx| {
            s.system_capabilities = Some(conduit_protocol::Capabilities {
                notes: true,
                ..Default::default()
            });
            s.preview_route(Some(crate::stores::session::Route::Main), cx)
        });
        stores.chat_list.update(vcx, |c, cx| c.refresh(cx));
        stores.navigation.update(vcx, |n, cx| n.open("chat-a", cx));
        vcx.run_until_parked();
        view.update_in(vcx, |s, window, cx| s.go_to_area(Area::Notes, window, cx));
        vcx.run_until_parked();
        view.read_with(vcx, |s, cx| {
            assert_eq!(s.cursor(), Some(&KeyRow::Area(Area::Notes)));
            assert_eq!(s.selection(cx), Some(KeyRow::Area(Area::Notes)));
        });
        view.update_in(vcx, |s, window, cx| s.go_to_area(Area::Chats, window, cx));
        vcx.run_until_parked();
        view.read_with(vcx, |s, cx| {
            assert_eq!(
                s.selection(cx),
                Some(KeyRow::Chat("chat-a".into())),
                "the chat on screen lost its selection"
            );
            assert_eq!(s.cursor(), Some(&KeyRow::Chat("chat-a".into())));
        });
        stores
            .navigation
            .update(vcx, |n, cx| n.open_item(AreaItem::Note("n1".into()), cx));
        vcx.run_until_parked();
        view.update_in(vcx, |s, window, cx| s.go_to_area(Area::Chats, window, cx));
        vcx.run_until_parked();
        view.read_with(vcx, |s, _| {
            assert_eq!(s.cursor(), Some(&KeyRow::Area(Area::Chats)));
        });
    }

    /// The chat on screen never shows the Unread dot, whichever row the
    /// keyboard stands on: it is being read.
    #[gpui_kit::test]
    fn the_chat_on_screen_never_shows_unread(cx: &mut TestAppContext) {
        use conduit_protocol::methods;
        let now = Local::now().timestamp_millis();
        let daemon = FakeDaemon::new();
        daemon.returns::<methods::ChatsList>(
            serde_json::from_value(serde_json::json!({
                "chats": [
                    {"id": "chat-a", "title": "Tide tables", "updatedAtMs": now, "unread": true},
                    {"id": "chat-b", "title": "Bread starter", "updatedAtMs": now - 1, "unread": true},
                ],
                "folders": [],
            }))
            .unwrap(),
        );
        let (stores, view, vcx) = bench_on(daemon, cx);
        stores.chat_list.update(vcx, |c, cx| c.refresh(cx));
        stores.navigation.update(vcx, |n, cx| n.open("chat-a", cx));
        vcx.run_until_parked();
        view.update_in(vcx, |s, window, cx| s.go_to_area(Area::Notes, window, cx));
        vcx.run_until_parked();
        view.read_with(vcx, |s, cx| {
            let unread = |id: &str| {
                let chat = s.stores.chat_list.read(cx).find(id).cloned().unwrap();
                s.shows_unread(&chat, cx)
            };
            assert!(!unread("chat-a"), "the chat on screen shows Unread");
            assert!(unread("chat-b"), "another chat lost its Unread");
        });
    }

    /// Mark as Unread on the chat on screen shows its mark, the dot and
    /// VoiceOver's "Unread", whenever its row is not the list's selection,
    /// until it is read again. A selected row draws no mark, as before.
    #[gpui_kit::test]
    fn a_chat_on_screen_marked_unread_shows_its_mark(cx: &mut TestAppContext) {
        use conduit_protocol::methods;
        let now = Local::now().timestamp_millis();
        let listed = |unread: bool| -> conduit_protocol::ChatList {
            serde_json::from_value(serde_json::json!({
                "chats": [
                    {"id": "chat-a", "title": "Tide tables", "updatedAtMs": now, "unread": unread},
                    {"id": "chat-b", "title": "Bread starter", "updatedAtMs": now - 1},
                ],
                "folders": [],
            }))
            .unwrap()
        };
        let daemon = FakeDaemon::new();
        daemon.returns::<methods::ChatsList>(listed(false));
        daemon.returns::<methods::ChatsMarkUnread>(listed(true));
        let (stores, view, vcx) = bench_on(daemon, cx);
        stores.session.update(vcx, |s, cx| {
            s.system_capabilities = Some(conduit_protocol::Capabilities {
                notes: true,
                ..Default::default()
            });
            s.preview_route(Some(crate::stores::session::Route::Main), cx)
        });
        stores.chat_list.update(vcx, |c, cx| c.refresh(cx));
        stores.navigation.update(vcx, |n, cx| n.open("chat-a", cx));
        vcx.run_until_parked();
        let label = |vcx: &mut VisualTestContext| {
            view.read_with(vcx, |s, cx| {
                let chat = s.stores.chat_list.read(cx).find("chat-a").cloned().unwrap();
                let (row, state) = s.chat_row_model(&chat, 0, &Local::now(), cx);
                conduit_components::views::sidebar::chat_row_label(&row, state)
            })
        };

        view.update_in(vcx, |s, window, cx| {
            s.run("chat-a", ChatCommand::MarkUnread, window, cx)
        });
        vcx.run_until_parked();
        view.update_in(vcx, |s, window, cx| s.go_to_area(Area::Notes, window, cx));
        vcx.run_until_parked();
        assert_eq!(
            label(vcx),
            "Tide tables, Unread",
            "the chat on screen marked unread showed no mark"
        );

        view.update_in(vcx, |s, window, cx| s.go_to_area(Area::Chats, window, cx));
        vcx.run_until_parked();
        assert_eq!(label(vcx), "Tide tables", "the selected row drew a mark");
    }

    /// A LibreChat copy made under one account, answered after another
    /// signs in, is not opened in the new account's window.
    #[gpui_kit::test]
    fn a_late_duplicate_does_not_open_in_another_account(cx: &mut TestAppContext) {
        use conduit_protocol::methods;
        let daemon = FakeDaemon::new();
        daemon.returns::<methods::LibrechatDuplicate>(conduit_protocol::ChatForked {
            chat_id: "copy-1".into(),
        });
        let held = daemon.hold::<methods::LibrechatDuplicate>();
        let (stores, view, vcx) = bench_on(daemon, cx);
        view.update(vcx, |s, cx| s.duplicate("chat-a", cx));
        vcx.run_until_parked();
        stores.accounts.update(vcx, |a, cx| {
            a.adopt(
                list(vec![
                    account("a", "Avery", false, true),
                    account("b", "Blake", true, true),
                ]),
                cx,
            )
        });
        vcx.run_until_parked();
        held.release();
        vcx.run_until_parked();
        stores.navigation.read_with(vcx, |n, _| {
            assert_ne!(
                n.selected_chat(),
                Some("copy-1"),
                "the last account's copy opened in the new account"
            );
        });
    }

    #[gpui_kit::test]
    fn go_to_a_section_ends_a_search_and_opening_a_chat_opens_chats(cx: &mut TestAppContext) {
        let (stores, view, vcx) = bench(cx);
        view.update_in(vcx, |s, window, cx| {
            s.search
                .update(cx, |i, cx| i.set_value("bread", window, cx));
        });
        stores
            .chat_list
            .update(vcx, |c, cx| c.set_query("bread", cx));
        view.update_in(vcx, |s, window, cx| s.go_to_area(Area::Notes, window, cx));
        stores.chat_list.read_with(vcx, |c, _| {
            assert!(!c.is_searching(), "Go stayed on the search's chats");
        });
        view.read_with(vcx, |s, cx| assert!(s.search.read(cx).value().is_empty()));
        stores
            .sections
            .update(vcx, |s, cx| s.set_collapsed(Area::Chats.id(), true, cx));
        stores.navigation.update(vcx, |n, cx| n.open("chat-a", cx));
        vcx.run_until_parked();
        stores.sections.read_with(vcx, |s, _| {
            assert!(
                !s.is_collapsed(Area::Chats.id()),
                "the opened chat's row is hidden"
            );
        });
    }

    #[gpui_kit::test]
    fn opening_a_note_ends_a_chat_selection_and_an_older_reveal(cx: &mut TestAppContext) {
        let (stores, view, vcx) = bench(cx);
        view.update(vcx, |s, cx| s.toggle_selected("chat-a", cx));
        stores
            .navigation
            .update(vcx, |n, cx| n.open_item(AreaItem::Note("n7".into()), cx));
        vcx.run_until_parked();
        view.read_with(vcx, |s, _| {
            assert!(s.selecting.is_none(), "chats stay chosen")
        });
        // Another item while the note still waits for its list.
        stores
            .navigation
            .update(vcx, |n, cx| n.open_item(AreaItem::Channel("c9".into()), cx));
        vcx.run_until_parked();
        view.read_with(vcx, |s, _| {
            assert_eq!(s.pending_reveal_item, Some(AreaItem::Channel("c9".into())));
        });
        stores.navigation.update(vcx, |n, cx| n.new_chat(false, cx));
        vcx.run_until_parked();
        view.read_with(vcx, |s, _| assert_eq!(s.pending_reveal_item, None));
    }

    #[gpui_kit::test]
    fn an_item_opened_past_its_areas_first_rows_shows_them_all(cx: &mut TestAppContext) {
        let (stores, view, vcx) = bench(cx);
        stores
            .sections
            .update(vcx, |s, cx| s.set_show_all(Area::Notes.id(), false, cx));
        stores
            .navigation
            .update(vcx, |n, cx| n.open_item(AreaItem::Note("n7".into()), cx));
        vcx.run_until_parked();
        stores.sections.read_with(vcx, |s, _| {
            assert!(
                s.shows_all(Area::Notes.id()),
                "the opened note's row is not drawn"
            );
        });
        view.read_with(vcx, |s, _| {
            assert_eq!(s.pending_reveal_item, Some(AreaItem::Note("n7".into())));
        });
    }

    #[test]
    fn search_shows_only_this_querys_hits_and_says_when_it_failed() {
        let now = Local::now();
        let mut store = ChatListStore::new(FakeDaemon::new().rpc());
        store.set_query_for_test("bread", "bre");
        store.results = Some(conduit_protocol::ChatSearchResults {
            hits: vec![
                serde_json::from_value(serde_json::json!({
                    "chatId": "c1", "title": "Bread", "updatedAtMs": 0
                }))
                .unwrap(),
            ],
            complete: true,
        });
        let hint = |store: &ChatListStore| build_rows(store, true, &now)[1..].to_vec();
        // Typed on: the old hits are not this query's.
        store.searching = true;
        assert_eq!(hint(&store), vec![SidebarItem::Hint(Hint::Loading)]);
        // And that search failed.
        store.searching = false;
        store.search_error = Some(conduit_daemon::protocol::error("rpc.timeout", "slow"));
        assert_eq!(hint(&store), vec![SidebarItem::Hint(Hint::Failed)]);
        // The first list failed: not "Loading" for ever.
        store.set_query_for_test("", "");
        store.load_error = Some(conduit_daemon::protocol::error("rpc.timeout", "slow"));
        assert_eq!(
            build_rows(&store, true, &now),
            vec![SidebarItem::Hint(Hint::Failed)]
        );
    }

    #[gpui_kit::test]
    fn another_account_starts_with_nothing_chosen(cx: &mut TestAppContext) {
        let (stores, view, vcx) = bench(cx);
        view.update(vcx, |s, cx| s.toggle_selected("chat-a", cx));
        // A new folder's name being typed, which a later Enter would make.
        view.update_in(vcx, |s, window, cx| {
            let target = NameTarget::NewFolder { parent: None };
            s.edit_name(target, "Plans".into(), window, cx);
            assert!(s.renaming.is_some());
        });
        stores.accounts.update(vcx, |a, cx| {
            a.adopt(
                list(vec![
                    account("a", "Avery", false, true),
                    account("b", "Blake", true, true),
                ]),
                cx,
            )
        });
        vcx.run_until_parked();
        view.read_with(vcx, |s, _| {
            assert!(s.selecting.is_none());
            assert!(
                s.renaming.is_none(),
                "the last account's name edit stayed open"
            );
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn share_links_use_the_server_address() {
        assert_eq!(
            share_url("https://chat.example.org/", "abc"),
            "https://chat.example.org/s/abc"
        );
        assert_eq!(
            share_url("http://127.0.0.1:8162", "x1"),
            "http://127.0.0.1:8162/s/x1"
        );
    }

    #[test]
    fn a_new_folder_is_named_like_finders() {
        let taken = ["New Folder", "new folder 2", "Recipes"];
        assert_eq!(
            unused_folder_name("New Folder", ["Recipes"].into_iter()),
            "New Folder"
        );
        assert_eq!(
            unused_folder_name("New Folder", taken.into_iter()),
            "New Folder 3"
        );
    }
}
