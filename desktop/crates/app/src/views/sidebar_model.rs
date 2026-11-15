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
use conduit_protocol::{ChatList, ChatSearchHit, ChatSummary, FolderSummary};

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

/// One row of the virtualized sidebar.
#[derive(Clone, Debug, PartialEq)]
pub enum SidebarItem {
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

/// `rows` without the rows of the sections in `collapsed`: a closed
/// section keeps its header, as the phone's Pinned and Folders do.
pub fn collapse(rows: Vec<SidebarItem>, collapsed: &HashSet<Section>) -> Vec<SidebarItem> {
    if collapsed.is_empty() {
        return rows;
    }
    let mut hidden = false;
    rows.into_iter()
        .filter(|item| match item {
            SidebarItem::Header(section) => {
                hidden = collapsed.contains(section);
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
        let closed = collapse(rows, &HashSet::from([Section::Pinned]));
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
        let closed = collapse(rows, &HashSet::from([today]));
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
}
