//! The sidebar as a source list: where the arrow keys move, and what is
//! selected.
//!
//! With the list focused (Tab reaches it, as AppKit's lists), ↑/↓ move the
//! selection itself through the chats, folders and every area's items, and
//! across the areas' headings (a chat or item it lands on opens; a folder
//! or heading is selected without opening), ← closes a folder or an area,
//! or goes up to the folder or heading holding the row, → opens a folder or
//! an area or steps into it, Home/End go to the ends. The Chats area's own
//! headers and hints are passed over. The list has one selection: the
//! arrows' row while it has focus, else what the main window shows. Pure
//! functions over the flat rows, so they test without a window.

use std::collections::BTreeSet;

use super::sidebar_model::SidebarItem;
use crate::stores::navigation::{Area, AreaItem, Selection};

/// A row the keyboard can stand on.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub enum KeyRow {
    Chat(String),
    Folder(String),
    /// "Load more" at the end of a page.
    LoadMore,
    /// The Archived toggle.
    Archived,
    /// An area's heading.
    Area(Area),
    /// An item of an area other than Chats.
    Item(AreaItem),
    /// An area's Show All (or Show Less) row.
    ShowAll(Area),
    /// Hermes's Archived toggle.
    HermesArchived,
    /// Hermes's connection switcher.
    HermesConnection,
}

impl KeyRow {
    pub fn of(item: &SidebarItem) -> Option<Self> {
        match item {
            SidebarItem::Chat { chat, .. } => Some(Self::Chat(chat.id.clone())),
            SidebarItem::SearchHit(hit) => Some(Self::Chat(hit.chat_id.clone())),
            SidebarItem::Folder { folder, .. } => Some(Self::Folder(folder.id.clone())),
            SidebarItem::LoadMore => Some(Self::LoadMore),
            SidebarItem::Archived { .. } => Some(Self::Archived),
            SidebarItem::AreaHeader { area, .. } => Some(Self::Area(*area)),
            SidebarItem::AreaRow(row) => Some(Self::Item(row.item.clone())),
            SidebarItem::ShowAll { area, .. } => Some(Self::ShowAll(*area)),
            SidebarItem::HermesArchived { .. } => Some(Self::HermesArchived),
            SidebarItem::HermesConnection { .. } => Some(Self::HermesConnection),
            SidebarItem::Header(_)
            | SidebarItem::HermesGroup { .. }
            | SidebarItem::Hint(_)
            | SidebarItem::AreaHint { .. }
            | SidebarItem::HermesScheduledHidden { .. }
            | SidebarItem::NewFolder { .. } => None,
        }
    }

    /// The row standing for what the main window shows, when it is one.
    pub fn of_selection(selection: &Selection) -> Option<Self> {
        match selection {
            Selection::Chat(id) => Some(Self::Chat(id.clone())),
            Selection::Area(item) => Some(Self::Item(item.clone())),
            Selection::New { .. } => None,
        }
    }

    pub fn chat_id(&self) -> Option<&str> {
        match self {
            Self::Chat(id) => Some(id),
            _ => None,
        }
    }

    /// Whether `item` is this row (without building a row for it).
    pub fn is(&self, item: &SidebarItem) -> bool {
        match (self, item) {
            (Self::Chat(id), SidebarItem::Chat { chat, .. }) => chat.id == *id,
            (Self::Chat(id), SidebarItem::SearchHit(hit)) => hit.chat_id == *id,
            (Self::Folder(id), SidebarItem::Folder { folder, .. }) => folder.id == *id,
            (Self::LoadMore, SidebarItem::LoadMore) => true,
            (Self::Archived, SidebarItem::Archived { .. }) => true,
            (Self::Area(a), SidebarItem::AreaHeader { area, .. }) => a == area,
            (Self::Item(i), SidebarItem::AreaRow(row)) => *i == row.item,
            (Self::ShowAll(a), SidebarItem::ShowAll { area, .. }) => a == area,
            (Self::HermesArchived, SidebarItem::HermesArchived { .. }) => true,
            (Self::HermesConnection, SidebarItem::HermesConnection { .. }) => true,
            _ => false,
        }
    }
}

/// A key the list answers.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ListKey {
    Up,
    Down,
    Left,
    Right,
    Home,
    End,
}

impl ListKey {
    /// GPUI's key name, unmodified.
    pub fn from_key(key: &str) -> Option<Self> {
        Some(match key {
            "up" => Self::Up,
            "down" => Self::Down,
            "left" => Self::Left,
            "right" => Self::Right,
            "home" => Self::Home,
            "end" => Self::End,
            _ => return None,
        })
    }
}

/// What a key does.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ListMove {
    /// The cursor goes to row `index` (a chat there opens).
    Cursor(usize),
    /// The folder opens or closes, the cursor staying on it.
    Toggle(String),
    /// The area opens or closes, the cursor staying on its heading.
    ToggleArea(Area),
    /// Nothing to do (the edge of the list).
    Stay,
}

fn depth(item: &SidebarItem) -> usize {
    match item {
        SidebarItem::Chat { depth, .. } | SidebarItem::Folder { depth, .. } => *depth,
        _ => 0,
    }
}

/// The row `cursor` stands on, if it is still listed.
pub fn index_of(rows: &[SidebarItem], cursor: &KeyRow) -> Option<usize> {
    rows.iter().position(|r| cursor.is(r))
}

/// The row the cursor starts on when the list takes focus: what the main
/// window shows when it is listed, else the first row.
pub fn initial_cursor(rows: &[SidebarItem], open: Option<&KeyRow>) -> Option<KeyRow> {
    open.filter(|o| index_of(rows, o).is_some())
        .cloned()
        .or_else(|| {
            rows.iter().filter_map(KeyRow::of).find(|k| {
                matches!(
                    k,
                    KeyRow::Chat(_) | KeyRow::Folder(_) | KeyRow::Area(_) | KeyRow::Item(_)
                )
            })
        })
}

/// The list's one selection: while the list has focus, the cursor's row
/// when it is still listed (a folder, heading or footer row too); otherwise
/// what the main window shows.
pub fn selection_row(
    rows: &[SidebarItem],
    list_focused: bool,
    cursor: Option<&KeyRow>,
    open: Option<&KeyRow>,
) -> Option<KeyRow> {
    if list_focused && let Some(c) = cursor.filter(|c| index_of(rows, c).is_some()) {
        return Some(c.clone());
    }
    open.cloned()
}

/// The heading of the area row `at` is in, when areas have headings.
fn heading_of(rows: &[SidebarItem], at: usize) -> Option<usize> {
    rows[..at]
        .iter()
        .rposition(|r| matches!(r, SidebarItem::AreaHeader { .. }))
}

/// Where `key` takes the cursor from row `at` (none yet: from outside the
/// list, so ↓ lands on the first row and ↑ on the last).
pub fn navigate(rows: &[SidebarItem], at: Option<usize>, key: ListKey) -> ListMove {
    let stops: Vec<usize> = rows
        .iter()
        .enumerate()
        .filter(|(_, r)| KeyRow::of(r).is_some())
        .map(|(i, _)| i)
        .collect();
    let (Some(&first), Some(&last)) = (stops.first(), stops.last()) else {
        return ListMove::Stay;
    };
    let Some(at) = at.filter(|i| stops.contains(i)) else {
        return match key {
            ListKey::Up | ListKey::End => ListMove::Cursor(last),
            _ => ListMove::Cursor(first),
        };
    };
    let next = stops.iter().copied().find(|&i| i > at);
    let prev = stops.iter().rev().copied().find(|&i| i < at);
    match key {
        ListKey::Down => next.map_or(ListMove::Stay, ListMove::Cursor),
        ListKey::Up => prev.map_or(ListMove::Stay, ListMove::Cursor),
        ListKey::Home if at != first => ListMove::Cursor(first),
        ListKey::End if at != last => ListMove::Cursor(last),
        ListKey::Home | ListKey::End => ListMove::Stay,
        ListKey::Right => match &rows[at] {
            SidebarItem::Folder {
                folder,
                expanded: false,
                ..
            } => ListMove::Toggle(folder.id.clone()),
            // Into an open folder: its first row, one level deeper.
            SidebarItem::Folder { depth: d, .. } => next
                .filter(|&n| depth(&rows[n]) > *d)
                .map_or(ListMove::Stay, ListMove::Cursor),
            SidebarItem::AreaHeader {
                area,
                expanded: false,
            } => ListMove::ToggleArea(*area),
            // Into an open area: its first row.
            SidebarItem::AreaHeader { .. } => next
                .filter(|&n| !matches!(rows[n], SidebarItem::AreaHeader { .. }))
                .map_or(ListMove::Stay, ListMove::Cursor),
            _ => ListMove::Stay,
        },
        ListKey::Left => match &rows[at] {
            SidebarItem::Folder {
                folder,
                expanded: true,
                ..
            } => ListMove::Toggle(folder.id.clone()),
            SidebarItem::AreaHeader {
                area,
                expanded: true,
            } => ListMove::ToggleArea(*area),
            SidebarItem::AreaHeader { .. } => ListMove::Stay,
            row if depth(row) > 0 => {
                let want = depth(row) - 1;
                rows[..at]
                    .iter()
                    .rposition(|r| matches!(r, SidebarItem::Folder { depth, .. } if *depth == want))
                    .map_or(ListMove::Stay, ListMove::Cursor)
            }
            // A row at an area's top level: up to the area's heading.
            _ => heading_of(rows, at).map_or(ListMove::Stay, ListMove::Cursor),
        },
    }
}

/// How a click (or ⇧-arrow) picks chats, from its modifiers: as Finder's
/// and Mail's lists, ⌘ adds or removes one row, ⇧ takes in the range from
/// the anchor, ⌘⇧ adds that range to what is selected.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Pick {
    /// A plain click: this chat alone.
    Only,
    /// ⌘-click: in or out of the selection.
    Toggle,
    /// ⇧-click: the range from the anchor, replacing the rest.
    Range,
    /// ⌘⇧-click: the range from the anchor, added to the rest.
    AddRange,
}

impl Pick {
    pub fn of(platform: bool, shift: bool) -> Self {
        match (platform, shift) {
            (false, false) => Self::Only,
            (true, false) => Self::Toggle,
            (false, true) => Self::Range,
            (true, true) => Self::AddRange,
        }
    }
}

/// What a pick leaves selected.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Picked {
    /// One chat: it opens, and there is no multiple selection.
    Open(String),
    /// Two chats or more; a range starts from `anchor` next time.
    Many {
        chats: BTreeSet<String>,
        anchor: String,
    },
    /// Nothing (the last chosen chat was ⌘-clicked away): the open chat
    /// stays open.
    Nothing,
}

/// Every chat row from `from` to `to` in list order, both ends included
/// (`to` alone when `from` is not listed), less those `pickable` refuses.
pub fn chat_range(
    rows: &[SidebarItem],
    from: &str,
    to: &str,
    pickable: &dyn Fn(&str) -> bool,
) -> Vec<String> {
    let at = |id: &str| index_of(rows, &KeyRow::Chat(id.to_string()));
    let Some(end) = at(to) else {
        return vec![];
    };
    let start = at(from).unwrap_or(end);
    let (lo, hi) = (start.min(end), start.max(end));
    rows[lo..=hi]
        .iter()
        .filter_map(|r| KeyRow::of(r)?.chat_id().map(String::from))
        .filter(|id| pickable(id))
        .collect()
}

/// The selection after `how` on chat `clicked`. `selected` is the multiple
/// selection there is (if any), `open` the open chat (what ⌘ and ⇧ start
/// from when nothing else is selected), `anchor` where the last range
/// started. `pickable` leaves out chats no bulk change can touch (another
/// user's).
pub fn pick(
    rows: &[SidebarItem],
    selected: Option<&BTreeSet<String>>,
    open: Option<&str>,
    anchor: Option<&str>,
    clicked: &str,
    how: Pick,
    pickable: &dyn Fn(&str) -> bool,
) -> Picked {
    let listed = |id: &str| index_of(rows, &KeyRow::Chat(id.to_string())).is_some();
    // What a ⌘ or ⇧ click adds to: the selection, else the open chat.
    let base = || -> BTreeSet<String> {
        match selected {
            Some(s) => s.clone(),
            None => open
                .filter(|o| listed(o) && pickable(o))
                .map(|o| BTreeSet::from([o.to_string()]))
                .unwrap_or_default(),
        }
    };
    let (chats, anchor) = match how {
        Pick::Only => return Picked::Open(clicked.to_string()),
        Pick::Toggle => {
            let mut set = base();
            if !set.remove(clicked) && pickable(clicked) {
                set.insert(clicked.to_string());
            }
            (set, clicked.to_string())
        }
        Pick::Range | Pick::AddRange => {
            let from = anchor
                .filter(|a| listed(a))
                .or(open.filter(|o| listed(o)))
                .unwrap_or(clicked)
                .to_string();
            let mut set: BTreeSet<String> = if how == Pick::AddRange {
                base()
            } else {
                BTreeSet::new()
            };
            set.extend(chat_range(rows, &from, clicked, pickable));
            (set, from)
        }
    };
    match chats.len() {
        0 => Picked::Nothing,
        1 => Picked::Open(chats.into_iter().next().unwrap_or_default()),
        _ => Picked::Many { chats, anchor },
    }
}

/// The next chat after (`forward`) or before the open one, in the list's
/// order, wrapping at the ends as ⌃Tab cycles tabs; from no open chat (or
/// one not listed), the first or the last. `None` without chats.
pub fn step_chat(rows: &[SidebarItem], open: Option<&str>, forward: bool) -> Option<String> {
    let chats: Vec<&str> = rows
        .iter()
        .filter_map(|r| match r {
            SidebarItem::Chat { chat, .. } => Some(chat.id.as_str()),
            SidebarItem::SearchHit(hit) => Some(hit.chat_id.as_str()),
            _ => None,
        })
        .collect();
    let last = chats.len().checked_sub(1)?;
    let next = match open.and_then(|o| chats.iter().position(|c| *c == o)) {
        Some(i) if forward => (i + 1) % chats.len(),
        Some(0) => last,
        Some(i) => i - 1,
        None if forward => 0,
        None => last,
    };
    Some(chats[next].to_string())
}

#[cfg(test)]
mod tests {
    use conduit_protocol::{ChatSummary, FolderSummary};

    use super::super::sidebar_model::{DateBucket, Hint, Section};
    use super::*;

    fn chat(id: &str, depth: usize) -> SidebarItem {
        SidebarItem::Chat {
            chat: serde_json::from_value::<ChatSummary>(serde_json::json!({
                "id": id,
                "title": id,
                "updatedAtMs": 0,
            }))
            .unwrap(),
            depth,
        }
    }

    fn folder(id: &str, depth: usize, expanded: bool) -> SidebarItem {
        SidebarItem::Folder {
            folder: serde_json::from_value::<FolderSummary>(serde_json::json!({
                "id": id,
                "name": id,
            }))
            .unwrap(),
            depth,
            expanded,
            count: 1,
        }
    }

    /// Pinned: p1 / Folders: garden (open) › seeds (closed), g1 / Today: t1, t2
    fn rows() -> Vec<SidebarItem> {
        vec![
            SidebarItem::Header(Section::Pinned),
            chat("p1", 0),
            SidebarItem::Header(Section::Folders),
            folder("garden", 0, true),
            folder("seeds", 1, false),
            chat("g1", 1),
            SidebarItem::Header(Section::Date(DateBucket::Today)),
            chat("t1", 0),
            chat("t2", 0),
            SidebarItem::Hint(Hint::NoResults),
        ]
    }

    #[test]
    fn arrows_skip_headers_and_stop_at_the_ends() {
        let r = rows();
        assert_eq!(navigate(&r, Some(1), ListKey::Down), ListMove::Cursor(3));
        assert_eq!(navigate(&r, Some(5), ListKey::Down), ListMove::Cursor(7));
        assert_eq!(navigate(&r, Some(7), ListKey::Up), ListMove::Cursor(5));
        assert_eq!(navigate(&r, Some(8), ListKey::Down), ListMove::Stay);
        assert_eq!(navigate(&r, Some(1), ListKey::Up), ListMove::Stay);
        assert_eq!(navigate(&r, Some(5), ListKey::Home), ListMove::Cursor(1));
        assert_eq!(navigate(&r, Some(5), ListKey::End), ListMove::Cursor(8));
    }

    #[test]
    fn from_outside_the_list_down_starts_at_the_top_and_up_at_the_bottom() {
        let r = rows();
        assert_eq!(navigate(&r, None, ListKey::Down), ListMove::Cursor(1));
        assert_eq!(navigate(&r, None, ListKey::Up), ListMove::Cursor(8));
        assert_eq!(navigate(&[], None, ListKey::Down), ListMove::Stay);
    }

    #[test]
    fn left_and_right_close_open_and_climb_folders() {
        let r = rows();
        // An open folder closes; a closed one opens.
        assert_eq!(
            navigate(&r, Some(3), ListKey::Left),
            ListMove::Toggle("garden".into())
        );
        assert_eq!(
            navigate(&r, Some(4), ListKey::Right),
            ListMove::Toggle("seeds".into())
        );
        // A row inside a folder goes up to it.
        assert_eq!(navigate(&r, Some(5), ListKey::Left), ListMove::Cursor(3));
        assert_eq!(navigate(&r, Some(4), ListKey::Left), ListMove::Cursor(3));
        // → on an open folder steps into it.
        assert_eq!(navigate(&r, Some(3), ListKey::Right), ListMove::Cursor(4));
        // A top-level chat has nowhere to go sideways.
        assert_eq!(navigate(&r, Some(7), ListKey::Left), ListMove::Stay);
        assert_eq!(navigate(&r, Some(7), ListKey::Right), ListMove::Stay);
    }

    #[test]
    fn the_arrows_select_a_folder_without_opening_it() {
        let r = rows();
        // ↓ from the pinned chat lands on the open Garden folder, then the
        // closed Seeds: both selected as they are, neither toggled.
        assert_eq!(navigate(&r, Some(1), ListKey::Down), ListMove::Cursor(3));
        assert_eq!(navigate(&r, Some(3), ListKey::Down), ListMove::Cursor(4));
        let seeds = KeyRow::Folder("seeds".into());
        let t1 = KeyRow::Chat("t1".into());
        assert_eq!(
            selection_row(&r, true, Some(&seeds), Some(&t1)),
            Some(seeds.clone()),
            "the folder is the one selection while the list has focus"
        );
    }

    #[test]
    fn the_open_chat_is_selected_while_the_list_is_not_focused() {
        let r = rows();
        let seeds = KeyRow::Folder("seeds".into());
        let (t1, t2) = (KeyRow::Chat("t1".into()), KeyRow::Chat("t2".into()));
        assert_eq!(
            selection_row(&r, false, Some(&seeds), Some(&t1)),
            Some(t1.clone())
        );
        // A cursor no longer listed (its folder closed) gives way too.
        let gone = KeyRow::Chat("gone".into());
        assert_eq!(
            selection_row(&r, true, Some(&gone), Some(&t2)),
            Some(t2.clone())
        );
        assert_eq!(selection_row(&r, false, None, None), None);
    }

    fn set(ids: &[&str]) -> BTreeSet<String> {
        ids.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn command_click_adds_to_the_open_chat_and_takes_rows_back_out() {
        let r = rows();
        let any = |_: &str| true;
        assert_eq!(Pick::of(true, false), Pick::Toggle);
        assert_eq!(Pick::of(false, true), Pick::Range);
        assert_eq!(Pick::of(true, true), Pick::AddRange);
        assert_eq!(Pick::of(false, false), Pick::Only);
        // ⌘-click beside the open chat: both selected, anchored on the click.
        let two = pick(&r, None, Some("t1"), None, "p1", Pick::Toggle, &any);
        assert_eq!(
            two,
            Picked::Many {
                chats: set(&["p1", "t1"]),
                anchor: "p1".into()
            }
        );
        // A third, then that one out again.
        let three = pick(
            &r,
            Some(&set(&["p1", "t1"])),
            Some("t1"),
            Some("p1"),
            "g1",
            Pick::Toggle,
            &any,
        );
        assert!(matches!(&three, Picked::Many { chats, .. } if chats == &set(&["g1", "p1", "t1"])));
        // Down to one chat: that one opens, with no multiple selection.
        assert_eq!(
            pick(
                &r,
                Some(&set(&["p1", "t1"])),
                Some("t1"),
                Some("p1"),
                "p1",
                Pick::Toggle,
                &any
            ),
            Picked::Open("t1".into())
        );
        // ⌘-click on the open chat alone deselects everything.
        assert_eq!(
            pick(&r, None, Some("t1"), None, "t1", Pick::Toggle, &any),
            Picked::Nothing
        );
        // A plain click is that chat alone.
        assert_eq!(
            pick(
                &r,
                Some(&set(&["p1", "t1"])),
                Some("t1"),
                None,
                "t2",
                Pick::Only,
                &any
            ),
            Picked::Open("t2".into())
        );
    }

    #[test]
    fn shift_click_takes_in_the_chats_between_in_list_order() {
        let r = rows();
        let any = |_: &str| true;
        // From the open chat (no anchor yet) up to the pinned chat: every
        // chat row between, folders and headers passed over.
        assert_eq!(
            pick(&r, None, Some("t1"), None, "p1", Pick::Range, &any),
            Picked::Many {
                chats: set(&["g1", "p1", "t1"]),
                anchor: "t1".into()
            }
        );
        // A range replaces what was picked; ⌘⇧ adds to it.
        let picked = set(&["p1", "t2"]);
        assert_eq!(
            pick(
                &r,
                Some(&picked),
                Some("t2"),
                Some("g1"),
                "t1",
                Pick::Range,
                &any
            ),
            Picked::Many {
                chats: set(&["g1", "t1"]),
                anchor: "g1".into()
            }
        );
        assert!(matches!(
            pick(&r, Some(&picked), Some("t2"), Some("g1"), "t1", Pick::AddRange, &any),
            Picked::Many { chats, .. } if chats == set(&["g1", "p1", "t1", "t2"])
        ));
        // Another user's chat is never picked.
        let not_g1 = |id: &str| id != "g1";
        assert_eq!(
            chat_range(&r, "p1", "t2", &not_g1),
            vec!["p1".to_string(), "t1".into(), "t2".into()]
        );
        assert_eq!(chat_range(&r, "gone", "t2", &any), vec!["t2".to_string()]);
        assert!(chat_range(&r, "p1", "gone", &any).is_empty());
    }

    #[test]
    fn next_and_previous_chat_follow_the_list_and_wrap() {
        let r = rows();
        // p1, g1, t1, t2: folders and headers passed over.
        assert_eq!(step_chat(&r, Some("p1"), true).as_deref(), Some("g1"));
        assert_eq!(step_chat(&r, Some("g1"), true).as_deref(), Some("t1"));
        assert_eq!(step_chat(&r, Some("t2"), true).as_deref(), Some("p1"));
        assert_eq!(step_chat(&r, Some("p1"), false).as_deref(), Some("t2"));
        assert_eq!(step_chat(&r, Some("t1"), false).as_deref(), Some("g1"));
        // A new chat (none open): the first, or the last going back.
        assert_eq!(step_chat(&r, None, true).as_deref(), Some("p1"));
        assert_eq!(step_chat(&r, None, false).as_deref(), Some("t2"));
        assert_eq!(step_chat(&r, Some("gone"), true).as_deref(), Some("p1"));
        assert_eq!(step_chat(&[], None, true), None);
    }

    #[test]
    fn focus_starts_on_the_open_chat() {
        let r = rows();
        assert_eq!(
            initial_cursor(&r, Some(&KeyRow::Chat("t1".into()))),
            Some(KeyRow::Chat("t1".into()))
        );
        assert_eq!(
            initial_cursor(&r, Some(&KeyRow::Chat("gone".into()))),
            Some(KeyRow::Chat("p1".into()))
        );
        assert_eq!(index_of(&r, &KeyRow::Folder("seeds".into())), Some(4));
        assert_eq!(ListKey::from_key("down"), Some(ListKey::Down));
        assert_eq!(ListKey::from_key("j"), None);
    }

    /// [Chats] c1 / [Notes] n1, Show All / [Calendar] (closed)
    fn area_rows() -> Vec<SidebarItem> {
        use crate::views::sidebar_model::AreaRow;
        let row = |item: AreaItem| {
            SidebarItem::AreaRow(AreaRow {
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
            })
        };
        vec![
            SidebarItem::AreaHeader {
                area: Area::Chats,
                expanded: true,
            },
            SidebarItem::Header(Section::Date(DateBucket::Today)),
            chat("c1", 0),
            SidebarItem::AreaHeader {
                area: Area::Notes,
                expanded: true,
            },
            row(AreaItem::Note("n1".into())),
            SidebarItem::ShowAll {
                area: Area::Notes,
                all: false,
            },
            SidebarItem::AreaHeader {
                area: Area::Calendar,
                expanded: false,
            },
        ]
    }

    #[test]
    fn arrows_cross_areas_and_their_headings() {
        let r = area_rows();
        // ↓ from the last chat: the next area's heading, then its item.
        assert_eq!(navigate(&r, Some(2), ListKey::Down), ListMove::Cursor(3));
        assert_eq!(navigate(&r, Some(3), ListKey::Down), ListMove::Cursor(4));
        assert_eq!(navigate(&r, Some(5), ListKey::Down), ListMove::Cursor(6));
        // ↑ from the first chat: the Chats heading (the date header is not
        // a stop).
        assert_eq!(navigate(&r, Some(2), ListKey::Up), ListMove::Cursor(0));
        // ← on an item goes up to its heading; ← there closes it; → on a
        // closed one opens it, and on an open one steps in.
        assert_eq!(navigate(&r, Some(4), ListKey::Left), ListMove::Cursor(3));
        assert_eq!(navigate(&r, Some(2), ListKey::Left), ListMove::Cursor(0));
        assert_eq!(
            navigate(&r, Some(3), ListKey::Left),
            ListMove::ToggleArea(Area::Notes)
        );
        assert_eq!(
            navigate(&r, Some(6), ListKey::Right),
            ListMove::ToggleArea(Area::Calendar)
        );
        assert_eq!(navigate(&r, Some(6), ListKey::Left), ListMove::Stay);
        assert_eq!(navigate(&r, Some(3), ListKey::Right), ListMove::Cursor(4));
        assert_eq!(navigate(&r, Some(0), ListKey::Right), ListMove::Cursor(2));
    }

    #[test]
    fn an_open_item_is_the_selection_and_where_focus_starts() {
        let r = area_rows();
        let note = KeyRow::Item(AreaItem::Note("n1".into()));
        let open = KeyRow::of_selection(&Selection::Area(AreaItem::Note("n1".into())));
        assert_eq!(open.as_ref(), Some(&note));
        assert_eq!(
            selection_row(&r, false, None, open.as_ref()),
            Some(note.clone())
        );
        assert_eq!(initial_cursor(&r, open.as_ref()), Some(note));
        assert_eq!(
            KeyRow::of_selection(&Selection::New { temporary: false }),
            None
        );
        // Nothing open: the first heading.
        assert_eq!(initial_cursor(&r, None), Some(KeyRow::Area(Area::Chats)));
    }
}
