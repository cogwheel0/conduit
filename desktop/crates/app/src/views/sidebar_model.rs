//! What the sidebar draws, decided from `chats.list` without drawing
//! anything, plus the flat row list the virtualized sidebar renders and the
//! relative times its rows show.
//!
//! Every chat lands in exactly one section, and none is dropped:
//!
//! * Archived wins over everything. An archived chat that is also pinned is
//!   still archived; showing it under Pinned would un-archive it in all but
//!   name.
//! * Pinned wins over a folder, as it does in Open WebUI.
//! * A chat whose folder is unknown (deleted elsewhere, or not synced yet)
//!   goes to the dated list rather than vanishing.
//! * A folder whose parent is unknown is shown at the top level, and a
//!   parent cycle (which a half-applied sync can briefly produce) is broken
//!   rather than followed forever.
//!
//! Dates are *calendar days* in the local time zone, not elapsed hours: a
//! chat from 23:50 last night is "Yesterday" at 00:10.

use std::collections::{BTreeSet, HashMap, HashSet};

use chrono::{DateTime, Datelike, NaiveDate, TimeZone, Weekday};
use conduit_protocol::{
    ChannelSummary, ChatList, ChatSearchHit, ChatSummary, FolderSummary, HermesBotDto,
    HermesRoomDto, HermesRooms, HermesSessionDto, HermesSessions, NoteSummary, TerminalServerDto,
};

use crate::stores::navigation::{Area, AreaItem, WorkspaceSection};

/// The date section a chat sits under, as the phone groups its chats (and
/// Notes its notes): Today, Yesterday, Previous 7 Days, Previous 30 Days,
/// then each earlier calendar month. Sections sort newest first by
/// [`DateBucket::order`].
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum DateBucket {
    Today,
    Yesterday,
    /// Two to seven calendar days ago.
    Previous7Days,
    /// Eight to thirty calendar days ago.
    Previous30Days,
    /// A calendar month (1–12), for anything older than thirty days.
    Month {
        year: i32,
        month: u32,
    },
}

impl DateBucket {
    /// A key that sorts sections newest first.
    pub fn order(&self) -> (u8, i64) {
        match *self {
            Self::Today => (0, 0),
            Self::Yesterday => (1, 0),
            Self::Previous7Days => (2, 0),
            Self::Previous30Days => (3, 0),
            Self::Month { year, month } => (4, -(year as i64 * 12 + month as i64)),
        }
    }
}

/// A folder with what is in it.
#[derive(Clone, Debug, PartialEq)]
pub struct FolderNode {
    pub folder: FolderSummary,
    pub children: Vec<FolderNode>,
    pub chats: Vec<ChatSummary>,
}

impl FolderNode {
    /// Chats here and in every folder below, for the count beside the name.
    pub fn total_chats(&self) -> usize {
        self.chats.len()
            + self
                .children
                .iter()
                .map(FolderNode::total_chats)
                .sum::<usize>()
    }
}

/// The sidebar, sorted into the sections it draws.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct SidebarSections {
    pub pinned: Vec<ChatSummary>,
    /// Top-level folders; nested ones hang off [`FolderNode::children`].
    pub folders: Vec<FolderNode>,
    /// Non-empty date sections only, newest first.
    pub recent: Vec<(DateBucket, Vec<ChatSummary>)>,
    pub archived: Vec<ChatSummary>,
}

/// The local calendar day of `ms` in `now`'s time zone.
fn day_of<Tz: TimeZone>(ms: i64, now: &DateTime<Tz>) -> NaiveDate {
    now.timezone()
        .timestamp_millis_opt(ms)
        .earliest()
        .map(|t| t.date_naive())
        .unwrap_or_else(|| now.date_naive())
}

/// Which date section a timestamp belongs to, measured in calendar days in
/// `now`'s time zone. A time a little ahead of `now` (clock skew) is today.
pub fn bucket_for<Tz: TimeZone>(updated_at_ms: i64, now: &DateTime<Tz>) -> DateBucket {
    let day = day_of(updated_at_ms, now);
    match (now.date_naive() - day).num_days() {
        ..=0 => DateBucket::Today,
        1 => DateBucket::Yesterday,
        2..=7 => DateBucket::Previous7Days,
        8..=30 => DateBucket::Previous30Days,
        _ => DateBucket::Month {
            year: day.year(),
            month: day.month(),
        },
    }
}

/// Whether following `parent`'s ancestors from `node` comes back around.
fn creates_cycle(node: &str, parent: &str, by_id: &HashMap<&str, &FolderSummary>) -> bool {
    let mut seen: HashSet<&str> = HashSet::from([node]);
    let mut cursor = Some(parent);
    while let Some(id) = cursor {
        if !seen.insert(id) {
            return true;
        }
        cursor = by_id
            .get(id)
            .and_then(|f| f.parent_id.as_deref())
            .filter(|p| by_id.contains_key(p));
    }
    false
}

/// Sorts `list` into sections.
pub fn build_sidebar<Tz: TimeZone>(list: &ChatList, now: &DateTime<Tz>) -> SidebarSections {
    let by_id: HashMap<&str, &FolderSummary> =
        list.folders.iter().map(|f| (f.id.as_str(), f)).collect();
    // Each folder's parent, when it has one that exists and no cycle.
    let mut children_of: HashMap<&str, Vec<&str>> = HashMap::new();
    let mut roots: Vec<&str> = vec![];
    for folder in &list.folders {
        match folder
            .parent_id
            .as_deref()
            .filter(|p| by_id.contains_key(p))
        {
            Some(parent) if !creates_cycle(&folder.id, parent, &by_id) => {
                children_of.entry(parent).or_default().push(&folder.id)
            }
            _ => roots.push(&folder.id),
        }
    }

    let mut pinned = vec![];
    let mut archived = vec![];
    let mut filed: HashMap<&str, Vec<ChatSummary>> = HashMap::new();
    let mut dated: HashMap<DateBucket, Vec<ChatSummary>> = HashMap::new();
    for chat in &list.chats {
        if chat.archived {
            archived.push(chat.clone());
        } else if chat.pinned {
            pinned.push(chat.clone());
        } else if let Some(id) = chat
            .folder_id
            .as_deref()
            .filter(|id| by_id.contains_key(id))
        {
            filed.entry(id).or_default().push(chat.clone());
        } else {
            dated
                .entry(bucket_for(chat.updated_at_ms, now))
                .or_default()
                .push(chat.clone());
        }
    }

    fn node(
        id: &str,
        by_id: &HashMap<&str, &FolderSummary>,
        children_of: &HashMap<&str, Vec<&str>>,
        filed: &mut HashMap<&str, Vec<ChatSummary>>,
    ) -> FolderNode {
        let mut children: Vec<FolderNode> = children_of
            .get(id)
            .map(|ids| {
                ids.iter()
                    .map(|c| node(c, by_id, children_of, filed))
                    .collect()
            })
            .unwrap_or_default();
        sort_by_name(&mut children);
        FolderNode {
            folder: (*by_id[id]).clone(),
            children,
            chats: filed.remove(id).unwrap_or_default(),
        }
    }
    let mut folders: Vec<FolderNode> = roots
        .iter()
        .map(|id| node(id, &by_id, &children_of, &mut filed))
        .collect();
    sort_by_name(&mut folders);

    SidebarSections {
        pinned,
        folders,
        recent: {
            let mut recent: Vec<(DateBucket, Vec<ChatSummary>)> = dated.into_iter().collect();
            recent.sort_by_key(|(b, _)| b.order());
            recent
        },
        archived,
    }
}

fn sort_by_name(level: &mut [FolderNode]) {
    level.sort_by_key(|n| n.folder.name.to_lowercase());
}

/// The folders, outermost first, that hold `chat_id`, or `None` when it is
/// in none of them.
pub fn folder_path_to(chat_id: &str, roots: &[FolderNode]) -> Option<Vec<String>> {
    for node in roots {
        if node.chats.iter().any(|c| c.id == chat_id) {
            return Some(vec![node.folder.id.clone()]);
        }
        if let Some(inner) = folder_path_to(chat_id, &node.children) {
            let mut path = vec![node.folder.id.clone()];
            path.extend(inner);
            return Some(path);
        }
    }
    None
}

/// `list` with the chats `chats.folder` returned for open folders that the
/// loaded page stops short of. Only plain filed chats are added: a pinned or
/// archived one beyond the page would otherwise appear in a section the
/// list has not reached yet.
pub fn with_folder_contents(
    list: &ChatList,
    contents: &HashMap<String, Vec<ChatSummary>>,
) -> ChatList {
    if contents.is_empty() {
        return list.clone();
    }
    let mut out = list.clone();
    let mut known: HashSet<String> = list.chats.iter().map(|c| c.id.clone()).collect();
    let mut folders: Vec<&String> = contents.keys().collect();
    folders.sort();
    for folder in folders {
        for chat in &contents[folder] {
            if !chat.archived
                && !chat.pinned
                && chat.folder_id.as_deref() == Some(folder.as_str())
                && known.insert(chat.id.clone())
            {
                out.chats.push(chat.clone());
            }
        }
    }
    out
}

/// A section heading.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Section {
    Pinned,
    Folders,
    /// A date section of the unfiled chats.
    Date(DateBucket),
    /// Search hits, replacing the list while a query is typed.
    Results,
}

impl Section {
    /// The name its open or closed state is kept under, per account.
    pub fn key(&self) -> String {
        match self {
            Self::Pinned => "chats.pinned".into(),
            Self::Folders => "chats.folders".into(),
            Self::Date(DateBucket::Today) => "chats.date.today".into(),
            Self::Date(DateBucket::Yesterday) => "chats.date.yesterday".into(),
            Self::Date(DateBucket::Previous7Days) => "chats.date.previous7".into(),
            Self::Date(DateBucket::Previous30Days) => "chats.date.previous30".into(),
            Self::Date(DateBucket::Month { year, month }) => {
                format!("chats.date.{year}-{month:02}")
            }
            Self::Results => "chats.results".into(),
        }
    }

    /// Whether the section can be closed from its header: every section of
    /// the list, as in Finder's and Mail's sidebars (not search results).
    pub fn collapsible(&self) -> bool {
        !matches!(self, Self::Results)
    }

    /// Whether its header shows the disclosure chevron only while hovered
    /// or closed: the date sections, which the phone draws without one.
    pub fn quiet_chevron(&self) -> bool {
        matches!(self, Self::Date(_))
    }
}

/// Why the list shows a line of text instead of rows.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Hint {
    /// Nothing loaded yet.
    Loading,
    /// The list is empty and the first sync has finished (or there is no
    /// server to sync with).
    NoChats,
    /// The list is empty while the first sync is still filling it.
    Syncing,
    /// The search found nothing, and the index is complete.
    NoResults,
    /// The search index may still be missing chats.
    SearchIncomplete,
    /// The list or the search could not be had.
    Failed,
}

/// How many items a long area lists before its Show All row, as Finder's
/// and Mail's sidebars keep a long section short.
pub const AREA_FIRST: usize = 5;

/// A row of an area other than Chats.
#[derive(Clone, Debug, PartialEq)]
pub struct AreaRow {
    pub item: AreaItem,
    /// Its name as the list has it; empty for an untitled one (the view
    /// names the rows that have no name of their own: the workspace
    /// sections, Calendar, Scheduled Tasks).
    pub title: String,
    pub updated_at_ms: Option<i64>,
    /// Unread messages (a channel).
    pub unread: i64,
    pub pinned: bool,
    /// A Hermes session's row: the session (its commands, its running
    /// reply), drawn as a chat's row is.
    pub session: Option<HermesSessionDto>,
    /// Its own glyph, where its kind says more than its area's (a direct
    /// message, a group, a private channel).
    pub icon: Option<conduit_components::assets::IconName>,
    /// Drawn quieter: a channel set to notify for mentions only (as Open
    /// WebUI's sidebar dims it), which shows no unread count either.
    pub dimmed: bool,
    /// A bot's row: the bot (its face; a click opens its Bot Chat).
    pub bot: Option<Box<HermesBotDto>>,
    /// A Group Chat's row: the room (its faces, its news, its work).
    pub room: Option<Box<HermesRoomDto>>,
}

impl AreaRow {
    fn of(item: AreaItem) -> Self {
        Self {
            item,
            title: String::new(),
            updated_at_ms: None,
            unread: 0,
            pinned: false,
            session: None,
            icon: None,
            dimmed: false,
            bot: None,
            room: None,
        }
    }
}

/// Why an area shows a line of text instead of rows.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AreaHint {
    Loading,
    Empty,
    /// Its list could not be read: Try Again.
    Failed,
    /// Hermes's archived sessions could not be read (its conversations
    /// still show): Try Again.
    ArchivedFailed,
}

/// What the areas other than Chats list (`None`: not listed yet).
#[derive(Clone, Copy, Debug, Default)]
pub struct AreaLists<'a> {
    pub notes: Option<&'a [NoteSummary]>,
    pub channels: Option<&'a [ChannelSummary]>,
    pub hermes: Option<&'a HermesSessions>,
    /// The Hermes connection in use, by name, and how many are saved: the
    /// section's switcher row.
    pub hermes_connection: Option<(&'a str, usize)>,
    /// The connection runs scheduled agents: their row.
    pub hermes_jobs: bool,
    pub terminals: Option<&'a [TerminalServerDto]>,
    /// The areas whose list could not be read.
    pub failed: &'a [Area],
    /// The workspace sections the account may manage.
    pub workspace: &'a [WorkspaceSection],
    /// Hermes's Bot Mode bots (none: no Bots group).
    pub bots: &'a [HermesBotDto],
    /// Hermes's Group Chats (`None`, or not available: no Rooms group).
    pub rooms: Option<&'a HermesRooms>,
    /// Which of Hermes's groups are open.
    pub bots_open: bool,
    pub rooms_open: bool,
}

/// A group of Hermes's section, as the phone's Hermes tab heads them.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum HermesGroup {
    Bots,
    Rooms,
    /// The sessions, headed only while bots or rooms show above them.
    Conversations,
}

impl HermesGroup {
    /// The name its open or closed state is kept under (the Conversations
    /// heading does not close).
    pub fn key(self) -> &'static str {
        match self {
            Self::Bots => "hermes.bots",
            Self::Rooms => "hermes.rooms",
            Self::Conversations => "hermes.conversations",
        }
    }

    pub fn collapsible(self) -> bool {
        self != Self::Conversations
    }
}

/// One row of the virtualized sidebar.
#[derive(Clone, Debug, PartialEq)]
pub enum SidebarItem {
    /// An area's heading, while the sidebar shows more than one area.
    AreaHeader {
        area: Area,
        expanded: bool,
    },
    /// An item of an area other than Chats.
    AreaRow(AreaRow),
    /// After an area's first [`AREA_FIRST`] items: Show All, or Show Less
    /// once they all show (`all`).
    ShowAll {
        area: Area,
        all: bool,
    },
    AreaHint {
        area: Area,
        hint: AreaHint,
    },
    /// How many scheduled agents' runs Hermes's lists leave out while Show
    /// Scheduled Runs is off, with Show (the phone's row).
    HermesScheduledHidden {
        count: usize,
    },
    /// Hermes's Archived row, as the phone's, with how many there are.
    HermesArchived {
        count: usize,
        visible: bool,
    },
    /// A heading of Hermes's section: Bots, Rooms (with New Room when a
    /// room can be made), Conversations.
    HermesGroup {
        group: HermesGroup,
        count: usize,
        expanded: bool,
        can_create: bool,
    },
    /// The Hermes connection in use, atop its section (the phone's
    /// switcher tile): with more than one saved, it switches.
    HermesConnection {
        name: String,
        count: usize,
    },
    Header(Section),
    Folder {
        folder: FolderSummary,
        depth: usize,
        expanded: bool,
        count: usize,
    },
    Chat {
        chat: ChatSummary,
        depth: usize,
    },
    LoadMore,
    /// The Archived toggle, with how many there are.
    Archived {
        count: i64,
        visible: bool,
    },
    SearchHit(ChatSearchHit),
    Hint(Hint),
    /// A folder being made: its name field, in `parent` (`None`: the top
    /// level) until Return makes it.
    NewFolder {
        parent: Option<String>,
        depth: usize,
    },
}

/// `rows` with the new-folder row in its place: first in its parent's
/// folder (which `rows` shows open), or first under the Folders heading,
/// which is added after the pinned chats when there is none yet. `None`
/// when the parent is not listed open.
pub fn with_new_folder(
    mut rows: Vec<SidebarItem>,
    parent: Option<&str>,
) -> Option<Vec<SidebarItem>> {
    match parent {
        Some(id) => {
            let (ix, depth) = rows.iter().enumerate().find_map(|(ix, r)| match r {
                SidebarItem::Folder {
                    folder,
                    depth,
                    expanded: true,
                    ..
                } if folder.id == id => Some((ix, *depth)),
                _ => None,
            })?;
            rows.insert(
                ix + 1,
                SidebarItem::NewFolder {
                    parent: Some(id.to_string()),
                    depth: depth + 1,
                },
            );
        }
        None => {
            let draft = SidebarItem::NewFolder {
                parent: None,
                depth: 0,
            };
            match rows
                .iter()
                .position(|r| *r == SidebarItem::Header(Section::Folders))
            {
                Some(ix) => rows.insert(ix + 1, draft),
                None => {
                    // After the pinned chats: before the first row of any
                    // other section, or at the end.
                    let at = rows
                        .iter()
                        .position(|r| {
                            !matches!(
                                r,
                                SidebarItem::Header(Section::Pinned) | SidebarItem::Chat { .. }
                            )
                        })
                        .unwrap_or(rows.len());
                    // An empty list's hint goes: the new folder is a row.
                    if matches!(rows.get(at), Some(SidebarItem::Hint(_))) {
                        rows.remove(at);
                    }
                    rows.insert(at, draft);
                    rows.insert(at, SidebarItem::Header(Section::Folders));
                }
            }
        }
    }
    Some(rows)
}

impl SidebarItem {
    /// The chat a row stands for, if it is one.
    pub fn chat_id(&self) -> Option<&str> {
        match self {
            Self::Chat { chat, .. } => Some(&chat.id),
            Self::SearchHit(hit) => Some(&hit.chat_id),
            _ => None,
        }
    }

    /// The area item a row stands for, if it is one.
    pub fn area_item(&self) -> Option<&AreaItem> {
        match self {
            Self::AreaRow(row) => Some(&row.item),
            _ => None,
        }
    }
}

/// An area's list as rows: its first [`AREA_FIRST`] items and a Show All
/// row when there are more (all of them, and Show Less, with `all`); a
/// hint while it loads or holds nothing. Hermes adds its Archived row, its
/// archived sessions under it while `archived` is open. Chats are not here:
/// their rows are [`flatten`]'s.
pub fn area_rows(area: Area, lists: &AreaLists, all: bool, archived: bool) -> Vec<SidebarItem> {
    let missing = |area: Area| {
        if lists.failed.contains(&area) {
            AreaHint::Failed
        } else {
            AreaHint::Loading
        }
    };
    fn listed<T>(
        area: Area,
        items: Option<&[T]>,
        all: bool,
        missing: AreaHint,
        row: impl Fn(&T) -> AreaRow,
    ) -> Vec<SidebarItem> {
        let Some(items) = items else {
            return vec![SidebarItem::AreaHint {
                area,
                hint: missing,
            }];
        };
        if items.is_empty() {
            return vec![SidebarItem::AreaHint {
                area,
                hint: AreaHint::Empty,
            }];
        }
        let shown = if all {
            items.len()
        } else {
            items.len().min(AREA_FIRST)
        };
        let mut out: Vec<SidebarItem> = items[..shown]
            .iter()
            .map(|i| SidebarItem::AreaRow(row(i)))
            .collect();
        if items.len() > AREA_FIRST {
            out.push(SidebarItem::ShowAll { area, all });
        }
        out
    }
    let session = |s: &HermesSessionDto| AreaRow {
        title: s.title.clone(),
        updated_at_ms: s.updated_at_ms,
        pinned: s.pinned,
        session: Some(s.clone()),
        ..AreaRow::of(AreaItem::HermesSession(s.id.clone()))
    };
    match area {
        Area::Chats => vec![],
        // All Notes first, as Mail's All Inboxes: the list pane, with
        // search and the time groups. It shows while the list loads or is
        // empty too, where New Note is.
        Area::Notes => std::iter::once(SidebarItem::AreaRow(AreaRow::of(AreaItem::AllNotes)))
            .chain(listed(area, lists.notes, all, missing(area), |n| AreaRow {
                title: n.title.clone(),
                updated_at_ms: Some(n.updated_at_ms),
                pinned: n.pinned,
                ..AreaRow::of(AreaItem::Note(n.id.clone()))
            }))
            .collect(),
        Area::Channels => listed(area, lists.channels, all, missing(area), |c| AreaRow {
            // A direct message is titled by the people in it.
            title: if c.title.trim().is_empty() {
                c.name.clone()
            } else {
                c.title.clone()
            },
            unread: if c.muted { 0 } else { c.unread },
            icon: Some(crate::views::channels::channel_icon(c)),
            dimmed: c.muted,
            ..AreaRow::of(AreaItem::Channel(c.id.clone()))
        }),
        Area::Terminal => {
            // The page opens a terminal outside any chat: one that needs a
            // saved chat is the composer's only.
            let page: Option<Vec<&TerminalServerDto>> = lists
                .terminals
                .map(|t| t.iter().filter(|t| !t.requires_saved_chat).collect());
            listed(area, page.as_deref(), all, missing(area), |t| AreaRow {
                title: if t.name.trim().is_empty() {
                    t.id.clone()
                } else {
                    t.name.clone()
                },
                ..AreaRow::of(AreaItem::Terminal(t.id.clone()))
            })
        }
        Area::Hermes => {
            // The phone's Hermes tab: the connection in use (its switcher),
            // Scheduled Agents, the bots, the rooms, then the conversations
            // under their own heading. The phone sets Scheduled Agents
            // apart as a card after the rooms; a source list's row there
            // would read as a room, so it stands under the switcher, both
            // the connection's own.
            let mut out: Vec<SidebarItem> = lists
                .hermes_connection
                .map(|(name, count)| SidebarItem::HermesConnection {
                    name: name.to_string(),
                    count,
                })
                .into_iter()
                .collect();
            if lists.hermes_jobs {
                out.push(SidebarItem::AreaRow(AreaRow::of(AreaItem::HermesJobs)));
            }
            let groups = hermes_groups(lists);
            if !groups.is_empty() {
                out.extend(groups);
                out.push(SidebarItem::HermesGroup {
                    group: HermesGroup::Conversations,
                    count: lists.hermes.map_or(0, |h| h.sessions.len()),
                    expanded: true,
                    can_create: false,
                });
            }
            let Some(hermes) = lists.hermes else {
                out.push(SidebarItem::AreaHint {
                    area,
                    hint: missing(area),
                });
                return out;
            };
            let hidden_runs = hermes.hidden_scheduled_runs.max(0) as usize;
            // Only runs left out: the row says so, rather than "no
            // conversations".
            if !(hermes.sessions.is_empty() && (!hermes.archived.is_empty() || hidden_runs > 0)) {
                out.extend(listed(
                    area,
                    Some(&hermes.sessions),
                    all,
                    AreaHint::Empty,
                    session,
                ));
            }
            if hidden_runs > 0 {
                out.push(SidebarItem::HermesScheduledHidden { count: hidden_runs });
            }
            if !hermes.archived.is_empty() {
                out.push(SidebarItem::HermesArchived {
                    count: hermes.archived.len(),
                    visible: archived,
                });
                if archived {
                    out.extend(
                        hermes
                            .archived
                            .iter()
                            .map(|s| SidebarItem::AreaRow(session(s))),
                    );
                }
            }
            // The archived row has its own failure, as on a phone.
            if hermes.archived_failed {
                out.push(SidebarItem::AreaHint {
                    area,
                    hint: AreaHint::ArchivedFailed,
                });
            }
            // The only way to the sessions hidden from every list, as
            // Photos keeps its Hidden album in the sidebar.
            out.push(SidebarItem::AreaRow(AreaRow::of(AreaItem::HermesHidden)));
            out
        }
        Area::Workspace => lists
            .workspace
            .iter()
            .map(|s| SidebarItem::AreaRow(AreaRow::of(AreaItem::Workspace(*s))))
            .collect(),
        Area::Calendar => vec![SidebarItem::AreaRow(AreaRow::of(AreaItem::Calendar))],
        Area::Automations => vec![SidebarItem::AreaRow(AreaRow::of(AreaItem::Automations))],
    }
}

/// Hermes's Bots and Rooms groups: each under its heading (with its
/// count), its rows while it is open. Bots only on a gateway with Bot Mode;
/// Rooms where Hermes hosts Group Chats and there are rooms or one can be
/// made (its heading then carries New Room).
fn hermes_groups(lists: &AreaLists) -> Vec<SidebarItem> {
    let mut out = vec![];
    if !lists.bots.is_empty() {
        out.push(SidebarItem::HermesGroup {
            group: HermesGroup::Bots,
            count: lists.bots.len(),
            expanded: lists.bots_open,
            can_create: false,
        });
        if lists.bots_open {
            out.extend(lists.bots.iter().map(|bot| {
                SidebarItem::AreaRow(AreaRow {
                    title: bot.title.clone(),
                    updated_at_ms: bot.last_active_ms,
                    bot: Some(Box::new(bot.clone())),
                    ..AreaRow::of(AreaItem::HermesBot(bot.name.clone()))
                })
            }));
        }
    }
    if let Some(rooms) = lists.rooms.filter(|r| r.available) {
        out.push(SidebarItem::HermesGroup {
            group: HermesGroup::Rooms,
            count: rooms.rooms.len(),
            expanded: lists.rooms_open,
            can_create: rooms.can_create,
        });
        if lists.rooms_open {
            out.extend(rooms.rooms.iter().map(|room| {
                SidebarItem::AreaRow(AreaRow {
                    title: room.name.clone(),
                    updated_at_ms: room.updated_at_ms,
                    room: Some(Box::new(room.clone())),
                    ..AreaRow::of(AreaItem::HermesRoom(room.id.clone()))
                })
            }));
        }
    }
    out
}

/// The sidebar's rows for `areas`: with more than one, each under its
/// heading, a closed one's rows left out (as Finder's sidebar closes a
/// section); with one, its rows alone, as the list was before areas (a
/// Direct setup has Chats only, Hermes alone its sessions). `chats` are the
/// Chats area's rows.
pub fn compose(
    areas: &[Area],
    chats: Vec<SidebarItem>,
    mut rows_of: impl FnMut(Area) -> Vec<SidebarItem>,
    collapsed: impl Fn(Area) -> bool,
) -> Vec<SidebarItem> {
    match areas {
        [] | [Area::Chats] => chats,
        [only] => rows_of(*only),
        _ => {
            let mut chats = Some(chats);
            let mut out = vec![];
            for &area in areas {
                let expanded = !collapsed(area);
                out.push(SidebarItem::AreaHeader { area, expanded });
                if !expanded {
                    continue;
                }
                if area == Area::Chats {
                    out.extend(chats.take().unwrap_or_default());
                } else {
                    out.extend(rows_of(area));
                }
            }
            out
        }
    }
}

/// The flat rows for `sections`, folders opened as `expanded` says.
/// Within an open folder its subfolders come first, then its chats.
pub fn flatten(
    sections: &SidebarSections,
    expanded: &BTreeSet<String>,
    list: &ChatList,
) -> Vec<SidebarItem> {
    let mut out = vec![];
    if !sections.pinned.is_empty() {
        out.push(SidebarItem::Header(Section::Pinned));
        out.extend(sections.pinned.iter().map(|c| SidebarItem::Chat {
            chat: c.clone(),
            depth: 0,
        }));
    }
    if !sections.folders.is_empty() {
        out.push(SidebarItem::Header(Section::Folders));
        fn walk(
            nodes: &[FolderNode],
            depth: usize,
            expanded: &BTreeSet<String>,
            out: &mut Vec<SidebarItem>,
        ) {
            for node in nodes {
                let open = expanded.contains(&node.folder.id);
                out.push(SidebarItem::Folder {
                    folder: node.folder.clone(),
                    depth,
                    expanded: open,
                    count: node.total_chats(),
                });
                if open {
                    walk(&node.children, depth + 1, expanded, out);
                    out.extend(node.chats.iter().map(|c| SidebarItem::Chat {
                        chat: c.clone(),
                        depth: depth + 1,
                    }));
                }
            }
        }
        walk(&sections.folders, 0, expanded, &mut out);
    }
    for (bucket, chats) in &sections.recent {
        out.push(SidebarItem::Header(Section::Date(*bucket)));
        out.extend(chats.iter().map(|chat| SidebarItem::Chat {
            chat: chat.clone(),
            depth: 0,
        }));
    }
    if list.has_more {
        out.push(SidebarItem::LoadMore);
    }
    if list.archived_count > 0 {
        out.push(SidebarItem::Archived {
            count: list.archived_count,
            visible: list.archived_visible,
        });
        if list.archived_visible {
            out.extend(sections.archived.iter().map(|c| SidebarItem::Chat {
                chat: c.clone(),
                depth: 0,
            }));
        }
    }
    out
}

/// `rows` without the rows of the sections `collapsed` says are closed: a
/// closed section keeps its header, as the phone's Pinned and Folders do.
pub fn collapse(rows: Vec<SidebarItem>, collapsed: impl Fn(&Section) -> bool) -> Vec<SidebarItem> {
    let mut hidden = false;
    rows.into_iter()
        .filter(|item| match item {
            SidebarItem::Header(section) => {
                hidden = collapsed(section);
                true
            }
            // The archived toggle and paging close the dated list; they
            // belong to no section.
            SidebarItem::LoadMore | SidebarItem::Archived { .. } => {
                hidden = false;
                true
            }
            _ => !hidden,
        })
        .collect()
}

/// How a row dates its chat after the title, as the phone (and Mail) dates
/// a message: the time for today, "Yesterday", the weekday within the last
/// week, else the date.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Stamp {
    /// Today, or a little ahead of now (clock skew).
    Time,
    Yesterday,
    /// Two to six days ago; from seven the name would repeat today's.
    Weekday(Weekday),
    Date,
}

/// The stamp a row shows for `ms`, counted in calendar days in `now`'s time
/// zone.
pub fn stamp_for<Tz: TimeZone>(ms: i64, now: &DateTime<Tz>) -> Stamp {
    let day = day_of(ms, now);
    match (now.date_naive() - day).num_days() {
        ..=0 => Stamp::Time,
        1 => Stamp::Yesterday,
        2..=6 => Stamp::Weekday(day.weekday()),
        _ => Stamp::Date,
    }
}

/// `snippet` with the search index's match markers (U+2068 … U+2069)
/// removed, and the byte ranges they enclosed.
pub fn parse_snippet(snippet: &str) -> (String, Vec<std::ops::Range<usize>>) {
    let mut text = String::with_capacity(snippet.len());
    let mut ranges = vec![];
    let mut start = None;
    for ch in snippet.chars() {
        match ch {
            '\u{2068}' => start = Some(text.len()),
            '\u{2069}' => {
                if let Some(s) = start.take()
                    && s < text.len()
                {
                    ranges.push(s..text.len());
                }
            }
            c => text.push(c),
        }
    }
    (text, ranges)
}

#[cfg(test)]
mod tests {
    use chrono::{Duration, Utc};

    use super::*;

    fn at(y: i32, m: u32, d: u32, h: u32, min: u32) -> DateTime<Utc> {
        Utc.with_ymd_and_hms(y, m, d, h, min, 0).unwrap()
    }

    fn now() -> DateTime<Utc> {
        at(2026, 9, 22, 14, 0)
    }

    fn chat(id: &str) -> ChatSummary {
        ChatSummary {
            unread: false,
            read_only: false,
            id: id.into(),
            title: id.into(),
            updated_at_ms: now().timestamp_millis(),
            pinned: false,
            archived: false,
            folder_id: None,
            model: None,
            tags: vec![],
            shared: false,
            menu: Default::default(),
        }
    }

    fn dated(id: &str, when: DateTime<Utc>) -> ChatSummary {
        ChatSummary {
            updated_at_ms: when.timestamp_millis(),
            ..chat(id)
        }
    }

    fn filed(id: &str, folder: &str) -> ChatSummary {
        ChatSummary {
            folder_id: Some(folder.into()),
            ..chat(id)
        }
    }

    fn folder(id: &str, name: &str, parent: Option<&str>) -> FolderSummary {
        FolderSummary {
            id: id.into(),
            name: name.into(),
            parent_id: parent.map(Into::into),
            expanded: false,
            shared: false,
            owner_name: None,
            can_write: true,
            icon: None,
        }
    }

    fn list(chats: Vec<ChatSummary>, folders: Vec<FolderSummary>) -> ChatList {
        ChatList {
            chats,
            has_more: false,
            archived_count: 0,
            archived_visible: false,
            folders,
            folders_enabled: true,
        }
    }

    // bucketFor

    #[test]
    fn buckets_count_calendar_days_not_elapsed_hours() {
        // Twenty minutes ago, but before midnight: yesterday to anyone
        // reading the heading.
        let just_after_midnight = at(2026, 9, 22, 0, 10);
        assert_eq!(
            bucket_for(
                at(2026, 9, 21, 23, 50).timestamp_millis(),
                &just_after_midnight
            ),
            DateBucket::Yesterday
        );
    }

    #[test]
    fn buckets_place_each_range() {
        let n = now();
        assert_eq!(bucket_for(n.timestamp_millis(), &n), DateBucket::Today);
        assert_eq!(
            bucket_for(at(2026, 9, 18, 0, 0).timestamp_millis(), &n),
            DateBucket::Previous7Days
        );
        // Seven calendar days back is still the previous week, as on the
        // phone; the eighth is not.
        assert_eq!(
            bucket_for(at(2026, 9, 15, 0, 0).timestamp_millis(), &n),
            DateBucket::Previous7Days
        );
        assert_eq!(
            bucket_for(at(2026, 9, 14, 0, 0).timestamp_millis(), &n),
            DateBucket::Previous30Days
        );
        assert_eq!(
            bucket_for(at(2026, 9, 1, 0, 0).timestamp_millis(), &n),
            DateBucket::Previous30Days
        );
        assert_eq!(
            bucket_for(at(2025, 1, 1, 0, 0).timestamp_millis(), &n),
            DateBucket::Month {
                year: 2025,
                month: 1
            }
        );
    }

    #[test]
    fn a_clock_ahead_of_the_server_is_still_today() {
        let n = now();
        let ahead = (n + Duration::minutes(3)).timestamp_millis();
        assert_eq!(bucket_for(ahead, &n), DateBucket::Today);
    }

    // buildSidebar

    #[test]
    fn every_chat_lands_in_exactly_one_section() {
        let mut pinned = chat("pinned");
        pinned.pinned = true;
        let mut archived = chat("archived");
        archived.archived = true;
        let model = build_sidebar(
            &list(
                vec![pinned, archived, filed("in-folder", "f1"), chat("today")],
                vec![folder("f1", "Work", None)],
            ),
            &now(),
        );
        let mut placed: Vec<String> = model
            .pinned
            .iter()
            .chain(&model.archived)
            .chain(model.folders.iter().flat_map(|f| &f.chats))
            .chain(model.recent.iter().flat_map(|(_, c)| c))
            .map(|c| c.id.clone())
            .collect();
        placed.sort();
        assert_eq!(placed, ["archived", "in-folder", "pinned", "today"]);
    }

    #[test]
    fn archived_wins_over_pinned() {
        let mut a = chat("a");
        a.pinned = true;
        a.archived = true;
        let model = build_sidebar(&list(vec![a], vec![]), &now());
        assert!(model.pinned.is_empty());
        assert_eq!(model.archived.len(), 1);
        assert_eq!(model.archived[0].id, "a");
    }

    #[test]
    fn pinned_wins_over_a_folder() {
        let mut a = filed("a", "f1");
        a.pinned = true;
        let model = build_sidebar(&list(vec![a], vec![folder("f1", "W", None)]), &now());
        assert_eq!(model.pinned[0].id, "a");
        assert!(model.folders[0].chats.is_empty());
    }

    #[test]
    fn a_chat_in_an_unknown_folder_is_not_lost() {
        let model = build_sidebar(&list(vec![filed("a", "gone")], vec![]), &now());
        assert_eq!(model.recent.len(), 1);
        assert_eq!(model.recent[0].1[0].id, "a");
    }

    #[test]
    fn folders_nest_and_sort_by_name_at_every_level() {
        let model = build_sidebar(
            &list(
                vec![],
                vec![
                    folder("z", "zeta", None),
                    folder("a", "Alpha", None),
                    folder("a2", "beta", Some("a")),
                    folder("a1", "Aardvark", Some("a")),
                ],
            ),
            &now(),
        );
        let names = |nodes: &[FolderNode]| -> Vec<String> {
            nodes.iter().map(|n| n.folder.name.clone()).collect()
        };
        assert_eq!(names(&model.folders), ["Alpha", "zeta"]);
        assert_eq!(names(&model.folders[0].children), ["Aardvark", "beta"]);
    }

    #[test]
    fn an_orphaned_or_cyclic_folder_surfaces_at_the_top() {
        // Both are states a half-applied sync can briefly produce, and
        // following a cycle would hang the window.
        let model = build_sidebar(
            &list(
                vec![],
                vec![
                    folder("orphan", "Orphan", Some("missing")),
                    folder("x", "X", Some("y")),
                    folder("y", "Y", Some("x")),
                ],
            ),
            &now(),
        );
        assert!(model.folders.iter().any(|f| f.folder.id == "orphan"));
        fn count(level: &[FolderNode]) -> usize {
            level.iter().map(|n| 1 + count(&n.children)).sum()
        }
        // Every folder is reachable from the roots.
        assert_eq!(count(&model.folders), 3);
    }

    #[test]
    fn empty_buckets_are_not_drawn() {
        let model = build_sidebar(&list(vec![chat("a")], vec![]), &now());
        let buckets: Vec<DateBucket> = model.recent.iter().map(|(b, _)| *b).collect();
        assert_eq!(buckets, [DateBucket::Today]);
    }

    #[test]
    fn a_folder_counts_what_is_inside_its_subfolders() {
        let model = build_sidebar(
            &list(
                vec![filed("a", "parent"), filed("b", "child")],
                vec![
                    folder("parent", "P", None),
                    folder("child", "C", Some("parent")),
                ],
            ),
            &now(),
        );
        assert_eq!(model.folders.len(), 1);
        assert_eq!(model.folders[0].total_chats(), 2);
    }

    // Date sections

    #[test]
    fn dates_group_as_the_phone_groups_them() {
        let model = build_sidebar(
            &list(
                vec![
                    chat("now"),
                    dated("yesterday", at(2026, 9, 21, 9, 0)),
                    dated("last week", at(2026, 9, 17, 0, 0)),
                    dated("last month", at(2026, 9, 1, 0, 0)),
                    dated("august", at(2025, 8, 3, 0, 0)),
                    dated("september", at(2025, 9, 1, 0, 0)),
                ],
                vec![],
            ),
            &now(),
        );
        let order: Vec<DateBucket> = model.recent.iter().map(|(g, _)| *g).collect();
        assert_eq!(
            order,
            [
                DateBucket::Today,
                DateBucket::Yesterday,
                DateBucket::Previous7Days,
                DateBucket::Previous30Days,
                DateBucket::Month {
                    year: 2025,
                    month: 9
                },
                DateBucket::Month {
                    year: 2025,
                    month: 8
                },
            ]
        );
    }

    #[test]
    fn an_empty_group_is_left_out() {
        let model = build_sidebar(
            &list(vec![dated("old", at(2025, 1, 1, 0, 0))], vec![]),
            &now(),
        );
        let groups: Vec<DateBucket> = model.recent.iter().map(|(g, _)| *g).collect();
        assert_eq!(
            groups,
            [DateBucket::Month {
                year: 2025,
                month: 1
            }]
        );
    }

    #[test]
    fn a_collapsed_section_keeps_only_its_header() {
        let mut pinned = chat("p");
        pinned.pinned = true;
        let l = list(vec![pinned, chat("now")], vec![]);
        let sections = build_sidebar(&l, &now());
        let rows = flatten(&sections, &BTreeSet::new(), &l);
        let closed = collapse(rows, |s| *s == Section::Pinned);
        let shown: Vec<String> = closed
            .iter()
            .map(|r| match r {
                SidebarItem::Header(s) => format!("{s:?}"),
                SidebarItem::Chat { chat, .. } => chat.id.clone(),
                _ => String::new(),
            })
            .collect();
        assert_eq!(shown, ["Pinned", "Date(Today)", "now"]);
    }

    #[test]
    fn every_section_closes_and_dates_reveal_their_chevron_on_hover() {
        let mut pinned = chat("p");
        pinned.pinned = true;
        let l = list(vec![pinned, chat("now")], vec![]);
        let sections = build_sidebar(&l, &now());
        let rows = flatten(&sections, &BTreeSet::new(), &l);
        let today = Section::Date(DateBucket::Today);
        let closed = collapse(rows, |s| *s == today);
        let chats: Vec<&str> = closed
            .iter()
            .filter_map(|r| match r {
                SidebarItem::Chat { chat, .. } => Some(chat.id.as_str()),
                _ => None,
            })
            .collect();
        assert_eq!(chats, ["p"], "Today's chats are hidden under its header");
        for s in [Section::Pinned, Section::Folders, today] {
            assert!(s.collapsible(), "{s:?}");
        }
        assert!(!Section::Results.collapsible());
        assert!(today.quiet_chevron() && !Section::Pinned.quiet_chevron());
    }

    // folderPathTo

    #[test]
    fn folder_path_names_the_folders_around_a_chat_outermost_first() {
        let model = build_sidebar(
            &list(
                vec![filed("deep", "inner"), chat("loose")],
                vec![
                    folder("outer", "Outer", None),
                    folder("inner", "Inner", Some("outer")),
                ],
            ),
            &now(),
        );
        assert_eq!(
            folder_path_to("deep", &model.folders),
            Some(vec!["outer".to_string(), "inner".to_string()])
        );
        assert_eq!(folder_path_to("loose", &model.folders), None);
    }

    // Beyond the Dart suite: the flat rows, folder contents, times and
    // snippets.

    #[test]
    fn flat_rows_follow_the_sections_and_open_folders() {
        let mut pinned = chat("p");
        pinned.pinned = true;
        let mut archived = chat("old");
        archived.archived = true;
        let mut l = list(
            vec![
                pinned,
                filed("deep", "inner"),
                filed("top", "outer"),
                chat("today"),
                archived,
            ],
            vec![
                folder("outer", "Outer", None),
                folder("inner", "Inner", Some("outer")),
            ],
        );
        l.has_more = true;
        l.archived_count = 1;
        let sections = build_sidebar(&l, &now());

        let closed = flatten(&sections, &BTreeSet::new(), &l);
        assert_eq!(
            closed
                .iter()
                .map(|i| match i {
                    SidebarItem::Header(s) => format!("[{s:?}]"),
                    SidebarItem::Folder { folder, count, .. } => {
                        format!("{} ({count})", folder.name)
                    }
                    SidebarItem::Chat { chat, depth } => format!("{}@{depth}", chat.id),
                    SidebarItem::LoadMore => "more".into(),
                    SidebarItem::Archived { count, visible } =>
                        format!("archived {count} {visible}"),
                    other => format!("{other:?}"),
                })
                .collect::<Vec<_>>(),
            [
                "[Pinned]",
                "p@0",
                "[Folders]",
                "Outer (2)",
                "[Date(Today)]",
                "today@0",
                "more",
                "archived 1 false",
            ]
        );

        let open: BTreeSet<String> = ["outer".to_string(), "inner".to_string()].into();
        let rows = flatten(&sections, &open, &l);
        let ids: Vec<String> = rows
            .iter()
            .filter_map(|i| match i {
                SidebarItem::Folder { folder, depth, .. } => Some(format!("{}#{depth}", folder.id)),
                SidebarItem::Chat { chat, depth } => Some(format!("{}@{depth}", chat.id)),
                _ => None,
            })
            .collect();
        // Subfolders before the folder's own chats.
        assert_eq!(
            ids,
            ["p@0", "outer#0", "inner#1", "deep@2", "top@1", "today@0"]
        );

        l.archived_visible = true;
        let sections = build_sidebar(&l, &now());
        let rows = flatten(&sections, &BTreeSet::new(), &l);
        assert_eq!(rows.last().and_then(SidebarItem::chat_id), Some("old"));
    }

    #[test]
    fn folder_contents_fill_in_past_the_loaded_page() {
        let l = list(vec![filed("a", "f")], vec![folder("f", "F", None)]);
        let mut pinned = filed("p", "f");
        pinned.pinned = true;
        let contents = HashMap::from([(
            "f".to_string(),
            vec![
                filed("a", "f"),
                filed("b", "f"),
                pinned,
                filed("elsewhere", "g"),
            ],
        )]);
        let merged = with_folder_contents(&l, &contents);
        let ids: Vec<&str> = merged.chats.iter().map(|c| c.id.as_str()).collect();
        assert_eq!(ids, ["a", "b"]);
    }

    #[test]
    fn a_shared_folder_holds_its_owners_chats_read_only() {
        // Another user's chats never come in `chats.list`; the shared
        // folder's `chats.folder` answer brings them, read-only, as a
        // phone's drawer lists them (issue #710).
        let mut shared = folder("s", "Trip planning", None);
        shared.shared = true;
        shared.owner_name = Some("Riley Example".into());
        shared.can_write = false;
        let l = list(vec![dated("mine", now())], vec![shared]);
        let foreign = |id: &str| ChatSummary {
            read_only: true,
            ..filed(id, "s")
        };
        let contents = HashMap::from([("s".to_string(), vec![foreign("r1"), foreign("r2")])]);
        let merged = with_folder_contents(&l, &contents);
        let sections = build_sidebar(&merged, &now());
        let open = BTreeSet::from(["s".to_string()]);
        let rows = flatten(&sections, &open, &merged);
        let in_folder: Vec<(&str, usize, bool)> = rows
            .iter()
            .filter_map(|r| match r {
                SidebarItem::Chat { chat, depth } if chat.folder_id.as_deref() == Some("s") => {
                    Some((chat.id.as_str(), *depth, chat.read_only))
                }
                _ => None,
            })
            .collect();
        assert_eq!(in_folder, [("r1", 1, true), ("r2", 1, true)]);
        assert!(rows.iter().any(|r| matches!(
            r,
            SidebarItem::Folder { folder, count: 2, .. } if folder.shared && !folder.can_write
        )));
        // Only the account's own chat is in the dated sections.
        let recent: Vec<&str> = sections
            .recent
            .iter()
            .flat_map(|(_, chats)| chats.iter().map(|c| c.id.as_str()))
            .collect();
        assert_eq!(recent, ["mine"]);
    }

    #[test]
    fn stamps_date_rows_as_mail_does() {
        let n = now();
        let ago = |d: Duration| (n - d).timestamp_millis();
        assert_eq!(stamp_for(ago(Duration::minutes(5)), &n), Stamp::Time);
        assert_eq!(stamp_for(ago(Duration::hours(3)), &n), Stamp::Time);
        assert_eq!(
            stamp_for((n + Duration::minutes(2)).timestamp_millis(), &n),
            Stamp::Time
        );
        assert_eq!(
            stamp_for(at(2026, 9, 21, 9, 0).timestamp_millis(), &n),
            Stamp::Yesterday
        );
        // 22 Sep 2026 is a Tuesday; the 18th was a Friday.
        assert_eq!(
            stamp_for(at(2026, 9, 18, 9, 0).timestamp_millis(), &n),
            Stamp::Weekday(Weekday::Fri)
        );
        // A week back would repeat today's name: the date instead.
        assert_eq!(
            stamp_for(at(2026, 9, 15, 9, 0).timestamp_millis(), &n),
            Stamp::Date
        );
        assert_eq!(
            stamp_for(at(2025, 12, 31, 9, 0).timestamp_millis(), &n),
            Stamp::Date
        );
    }

    #[test]
    fn snippets_lose_their_markers_and_keep_the_ranges() {
        let (text, ranges) = parse_snippet("…feed the \u{2068}starter\u{2069} at 8 am…");
        assert_eq!(text, "…feed the starter at 8 am…");
        assert_eq!(&text[ranges[0].clone()], "starter");
        assert_eq!(parse_snippet("plain"), ("plain".to_string(), vec![]));
    }

    #[test]
    fn a_new_folder_row_goes_where_the_folder_will_be() {
        let mut garden = folder("garden", "Garden", None);
        garden.expanded = true;
        let l = list(vec![chat("a")], vec![garden]);
        let now = chrono::Local::now();
        let open: BTreeSet<String> = ["garden".to_string()].into();
        let rows = flatten(&build_sidebar(&l, &now), &open, &l);
        // At the top level: first under the Folders heading.
        let top = with_new_folder(rows.clone(), None).unwrap();
        let at = top
            .iter()
            .position(|r| *r == SidebarItem::Header(Section::Folders))
            .unwrap();
        assert_eq!(
            top[at + 1],
            SidebarItem::NewFolder {
                parent: None,
                depth: 0
            }
        );
        // In an open folder: first inside it, a level in.
        let inside = with_new_folder(rows.clone(), Some("garden")).unwrap();
        let at = inside
            .iter()
            .position(|r| matches!(r, SidebarItem::Folder { folder, .. } if folder.id == "garden"))
            .unwrap();
        assert_eq!(
            inside[at + 1],
            SidebarItem::NewFolder {
                parent: Some("garden".into()),
                depth: 1
            }
        );
        // A closed or unknown parent: nowhere to show it.
        assert!(with_new_folder(rows, Some("elsewhere")).is_none());
        // No folders yet: a Folders heading is added for it, before the
        // dated chats.
        let bare = list(vec![chat("a")], vec![]);
        let rows = flatten(&build_sidebar(&bare, &now), &BTreeSet::new(), &bare);
        let first = with_new_folder(rows, None).unwrap();
        assert_eq!(first[0], SidebarItem::Header(Section::Folders));
        assert!(matches!(first[1], SidebarItem::NewFolder { .. }));
        assert!(matches!(first[2], SidebarItem::Header(Section::Date(_))));
    }

    // Areas

    fn note(id: &str) -> conduit_protocol::NoteSummary {
        serde_json::from_value(serde_json::json!({
            "id": id, "title": id, "updatedAtMs": 1,
        }))
        .unwrap()
    }

    fn labels(rows: &[SidebarItem]) -> Vec<String> {
        rows.iter()
            .map(|r| match r {
                SidebarItem::AreaHeader { area, expanded } => {
                    format!("[{}{}]", area.id(), if *expanded { "" } else { " closed" })
                }
                SidebarItem::AreaRow(row) => format!("{:?}", row.item),
                SidebarItem::ShowAll { all, .. } => format!("show all {all}"),
                SidebarItem::AreaHint { hint, .. } => format!("{hint:?}"),
                SidebarItem::Header(s) => format!("<{s:?}>"),
                SidebarItem::Chat { chat, .. } => chat.id.clone(),
                other => format!("{other:?}"),
            })
            .collect()
    }

    #[test]
    fn a_long_area_lists_its_first_items_then_show_all() {
        let notes: Vec<_> = (0..7).map(|i| note(&format!("n{i}"))).collect();
        let lists = AreaLists {
            notes: Some(&notes),
            ..Default::default()
        };
        let first = area_rows(Area::Notes, &lists, false, false);
        // All Notes, the first few, Show All.
        assert_eq!(first.len(), 1 + AREA_FIRST + 1);
        assert_eq!(
            first[0],
            SidebarItem::AreaRow(AreaRow::of(AreaItem::AllNotes))
        );
        assert_eq!(
            first.last(),
            Some(&SidebarItem::ShowAll {
                area: Area::Notes,
                all: false
            })
        );
        let all = area_rows(Area::Notes, &lists, true, false);
        assert_eq!(all.len(), 1 + 7 + 1, "every note, then Show Less");
        // Nothing listed yet, or nothing at all: a hint.
        assert_eq!(
            labels(&area_rows(
                Area::Channels,
                &AreaLists::default(),
                false,
                false
            )),
            ["Loading"]
        );
        let none = AreaLists {
            channels: Some(&[]),
            ..Default::default()
        };
        assert_eq!(
            labels(&area_rows(Area::Channels, &none, false, false)),
            ["Empty"]
        );
    }

    #[test]
    fn an_area_whose_list_failed_offers_try_again() {
        let failed = AreaLists {
            failed: &[Area::Channels, Area::Hermes],
            ..Default::default()
        };
        for area in [Area::Channels, Area::Hermes] {
            assert_eq!(labels(&area_rows(area, &failed, false, false)), ["Failed"]);
        }
        // All Notes leads the section whatever its list does.
        assert_eq!(
            labels(&area_rows(Area::Notes, &failed, false, false)),
            ["AllNotes", "Loading"]
        );
        // A list still held shows, whatever the last read did.
        let held = AreaLists {
            channels: Some(&[]),
            failed: &[Area::Channels],
            ..Default::default()
        };
        assert_eq!(
            labels(&area_rows(Area::Channels, &held, false, false)),
            ["Empty"]
        );
    }

    #[test]
    fn the_terminal_page_leaves_out_a_terminal_that_needs_a_saved_chat() {
        let terminal = |id: &str, requires_saved_chat: bool| TerminalServerDto {
            id: id.into(),
            name: id.into(),
            kind: "system".into(),
            requires_saved_chat,
            device: false,
        };
        let both = [terminal("box", false), terminal("per-chat", true)];
        let only_chats = [terminal("per-chat", true)];
        let rows = |terminals: &[TerminalServerDto]| {
            labels(&area_rows(
                Area::Terminal,
                &AreaLists {
                    terminals: Some(terminals),
                    ..Default::default()
                },
                false,
                false,
            ))
        };
        assert_eq!(rows(&both), [r#"Terminal("box")"#]);
        assert_eq!(rows(&only_chats), ["Empty"]);
    }

    #[test]
    fn hermes_lists_its_sessions_and_an_archived_row() {
        let session = |id: &str, archived: bool| HermesSessionDto {
            id: id.into(),
            chat_id: format!("local:hermes_{id}"),
            title: id.into(),
            preview: None,
            updated_at_ms: None,
            pinned: false,
            archived,
            hidden: false,
            source: None,
            running: false,
        };
        let hermes = HermesSessions {
            sessions: vec![session("s1", false)],
            archived: vec![session("old", true)],
            archived_failed: false,
            hidden_scheduled_runs: 0,
        };
        let lists = AreaLists {
            hermes: Some(&hermes),
            ..Default::default()
        };
        let closed = area_rows(Area::Hermes, &lists, false, false);
        assert_eq!(closed.len(), 3);
        assert_eq!(
            closed[1],
            SidebarItem::HermesArchived {
                count: 1,
                visible: false
            }
        );
        // Hidden Chats closes the section, always.
        assert_eq!(
            closed.last().and_then(SidebarItem::area_item),
            Some(&AreaItem::HermesHidden)
        );
        // A session's row carries the session, for its menu and spinner.
        assert!(matches!(
            &closed[0],
            SidebarItem::AreaRow(AreaRow { session: Some(s), .. }) if s.id == "s1"
        ));
        let open = area_rows(Area::Hermes, &lists, false, true);
        assert_eq!(
            open[open.len() - 2].area_item(),
            Some(&AreaItem::HermesSession("old".into()))
        );
        // The archived row's own failure; the list's, with nothing read.
        let failed = HermesSessions {
            archived_failed: true,
            ..hermes.clone()
        };
        let rows = area_rows(
            Area::Hermes,
            &AreaLists {
                hermes: Some(&failed),
                ..Default::default()
            },
            false,
            false,
        );
        assert!(rows.contains(&SidebarItem::AreaHint {
            area: Area::Hermes,
            hint: AreaHint::ArchivedFailed
        }));
        let rows = area_rows(
            Area::Hermes,
            &AreaLists {
                failed: &[Area::Hermes],
                ..Default::default()
            },
            false,
            false,
        );
        assert_eq!(
            rows,
            [SidebarItem::AreaHint {
                area: Area::Hermes,
                hint: AreaHint::Failed
            }]
        );
        // Scheduled runs left out: said after the conversations, with Show;
        // with nothing else listed, instead of "no conversations".
        let hiding = HermesSessions {
            hidden_scheduled_runs: 3,
            ..hermes.clone()
        };
        let rows = area_rows(
            Area::Hermes,
            &AreaLists {
                hermes: Some(&hiding),
                ..Default::default()
            },
            false,
            false,
        );
        assert_eq!(rows[1], SidebarItem::HermesScheduledHidden { count: 3 });
        let only_runs = HermesSessions {
            sessions: vec![],
            archived: vec![],
            hidden_scheduled_runs: 2,
            ..hermes.clone()
        };
        let rows = area_rows(
            Area::Hermes,
            &AreaLists {
                hermes: Some(&only_runs),
                ..Default::default()
            },
            false,
            false,
        );
        assert_eq!(rows[0], SidebarItem::HermesScheduledHidden { count: 2 });
        assert!(
            !rows
                .iter()
                .any(|r| matches!(r, SidebarItem::AreaHint { .. }))
        );
    }

    #[test]
    fn hermes_follows_the_phones_tab_switcher_agents_bots_rooms_then_chats() {
        let session = |id: &str| HermesSessionDto {
            id: id.into(),
            chat_id: format!("local:hermes_{id}"),
            title: id.into(),
            preview: None,
            updated_at_ms: None,
            pinned: false,
            archived: false,
            hidden: false,
            source: None,
            running: false,
        };
        let hermes = HermesSessions {
            sessions: vec![session("s1")],
            archived: vec![],
            archived_failed: false,
            hidden_scheduled_runs: 0,
        };
        let bots: Vec<HermesBotDto> =
            serde_json::from_value(serde_json::json!([{"name": "fern", "title": "Fern"}])).unwrap();
        let rooms: HermesRooms = serde_json::from_value(serde_json::json!({
            "available": true, "canCreate": true,
            "rooms": [{"id": "r1", "name": "Greenhouse crew"}],
        }))
        .unwrap();
        let lists = AreaLists {
            hermes: Some(&hermes),
            hermes_connection: Some(("Shed", 2)),
            hermes_jobs: true,
            bots: &bots,
            rooms: Some(&rooms),
            bots_open: true,
            rooms_open: true,
            ..Default::default()
        };
        let rows = area_rows(Area::Hermes, &lists, false, false);
        let kinds: Vec<String> = rows
            .iter()
            .map(|r| match r {
                SidebarItem::HermesConnection { name, .. } => format!("switcher {name}"),
                SidebarItem::HermesGroup { group, .. } => format!("<{group:?}>"),
                SidebarItem::AreaRow(row) => format!("{:?}", row.item),
                other => format!("{other:?}"),
            })
            .collect();
        assert_eq!(
            kinds,
            [
                "switcher Shed",
                "HermesJobs",
                "<Bots>",
                "HermesBot(\"fern\")",
                "<Rooms>",
                "HermesRoom(\"r1\")",
                "<Conversations>",
                "HermesSession(\"s1\")",
                "HermesHidden",
            ]
        );
        // With no bots or rooms the chats need no heading: Scheduled Agents
        // stands with the switcher, above them.
        let agents_only = AreaLists {
            hermes: Some(&hermes),
            hermes_jobs: true,
            ..Default::default()
        };
        let rows = area_rows(Area::Hermes, &agents_only, false, false);
        assert_eq!(rows[0].area_item(), Some(&AreaItem::HermesJobs));
        assert!(
            !rows
                .iter()
                .any(|r| matches!(r, SidebarItem::HermesGroup { .. }))
        );
        // Under the groups, even with no chats yet: the hint is the
        // conversations', not the rooms'.
        let empty = HermesSessions {
            sessions: vec![],
            ..hermes.clone()
        };
        let no_chats = AreaLists {
            hermes: Some(&empty),
            ..lists
        };
        let rows = area_rows(Area::Hermes, &no_chats, false, false);
        let heading = rows.iter().position(|r| {
            matches!(
                r,
                SidebarItem::HermesGroup {
                    group: HermesGroup::Conversations,
                    count: 0,
                    ..
                }
            )
        });
        let hint = rows.iter().position(|r| {
            matches!(
                r,
                SidebarItem::AreaHint {
                    hint: AreaHint::Empty,
                    ..
                }
            )
        });
        assert!(matches!((heading, hint), (Some(h), Some(e)) if e == h + 1));
    }

    #[test]
    fn areas_compose_under_headings_and_a_lone_area_has_none() {
        let chats = vec![SidebarItem::Header(Section::Pinned), chat_item("c1")];
        let workspace = [WorkspaceSection::Prompts];
        let lists = AreaLists {
            workspace: &workspace,
            ..Default::default()
        };
        let rows_of = |a: Area| area_rows(a, &lists, false, false);
        // Direct, or no capabilities yet: the chats as they were.
        assert_eq!(
            labels(&compose(&[Area::Chats], chats.clone(), rows_of, |_| false)),
            ["<Pinned>", "c1"]
        );
        // Hermes alone: its sessions, no heading.
        assert_eq!(
            labels(&compose(&[Area::Hermes], chats.clone(), rows_of, |_| false)),
            ["Loading"]
        );
        let areas = [Area::Chats, Area::Workspace, Area::Calendar];
        assert_eq!(
            labels(&compose(&areas, chats.clone(), rows_of, |a| a == Area::Calendar)),
            [
                "[chats]",
                "<Pinned>",
                "c1",
                "[workspace]",
                "Workspace(Prompts)",
                "[calendar closed]",
            ]
        );
        // Every area keeps its own key, and the Chats sections theirs.
        assert_eq!(Section::Pinned.key(), "chats.pinned");
        assert_eq!(
            Section::Date(DateBucket::Month {
                year: 2025,
                month: 3
            })
            .key(),
            "chats.date.2025-03"
        );
    }

    fn chat_item(id: &str) -> SidebarItem {
        SidebarItem::Chat {
            chat: chat(id),
            depth: 0,
        }
    }
}
