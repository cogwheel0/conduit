//! The ⌘K palette: what it offers and how it narrows, and its search.
//!
//! * With an empty query: the [`RECENT_COUNT`] most recent chats, then every
//!   command.
//! * With a query: `chats.search` hits (limit [`PALETTE_LIMIT`], searched
//!   [`PALETTE_DEBOUNCE`] after the last keystroke), then the commands whose
//!   label holds every word of the query, in any order.
//! * Arrow keys move the highlight and wrap at both ends: the row most often
//!   wanted after the first is the last.
//!
//! Only commands that lead somewhere are listed. "Choose model" dispatches
//! `FocusModelPicker`, which the chat view handles.

use std::time::Duration;

use conduit_protocol::{ChatSearchQuery, ChatSearchResults, ChatSummary, methods};
use gpui_kit::{AsyncApp, Context, Task, WeakEntity};

use super::rpc::Rpc;
use crate::keymap::ShortcutAction;

/// How long the palette waits after the last keystroke.
pub const PALETTE_DEBOUNCE: Duration = Duration::from_millis(150);
/// How many search hits the palette shows.
pub const PALETTE_LIMIT: i64 = 8;
/// How many recent chats show before anything is typed.
pub const RECENT_COUNT: usize = 6;

/// Something the palette can do other than open a chat.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum PaletteCommand {
    NewChat,
    NewTemporaryChat,
    ChooseModel,
    OpenSettings,
    ShowShortcuts,
}

impl PaletteCommand {
    pub const ALL: [Self; 5] = [
        Self::NewChat,
        Self::NewTemporaryChat,
        Self::ChooseModel,
        Self::OpenSettings,
        Self::ShowShortcuts,
    ];

    /// The fixed chord that does the same thing (⇧⌘N for New Temporary
    /// Chat), shown as the rebindable ones are.
    pub fn fixed(self) -> Option<crate::keymap::FixedCommand> {
        match self {
            Self::NewTemporaryChat => Some(crate::keymap::FixedCommand::NewTemporaryChat),
            _ => None,
        }
    }

    /// The shortcut that does the same thing, shown so the palette teaches
    /// it.
    pub fn shortcut(self) -> Option<ShortcutAction> {
        match self {
            Self::NewChat => Some(ShortcutAction::NewChat),
            Self::NewTemporaryChat => None,
            Self::ChooseModel => Some(ShortcutAction::FocusModelPicker),
            Self::OpenSettings => Some(ShortcutAction::OpenSettings),
            Self::ShowShortcuts => Some(ShortcutAction::ShowShortcuts),
        }
    }
}

/// A command row: what it does, its label and its chord.
#[derive(Clone, Debug, PartialEq)]
pub struct CommandItem {
    pub command: PaletteCommand,
    pub label: String,
    pub shortcut: Option<String>,
}

impl CommandItem {
    pub fn new(command: PaletteCommand, label: impl Into<String>) -> Self {
        Self {
            command,
            label: label.into(),
            shortcut: None,
        }
    }
}

/// One palette row.
#[derive(Clone, Debug, PartialEq)]
pub enum PaletteEntry {
    Chat {
        chat_id: String,
        title: String,
        /// Where the match was, when it was in the chat rather than the
        /// title (with the index's match markers).
        snippet: Option<String>,
        updated_at_ms: i64,
    },
    Command(CommandItem),
}

/// The lowercased words of `query`.
fn words(query: &str) -> Vec<String> {
    query.split_whitespace().map(str::to_lowercase).collect()
}

/// Whether `label` holds every word of `query`, in any order.
pub fn matches_every_word(label: &str, query: &str) -> bool {
    let label = label.to_lowercase();
    words(query).iter().all(|w| label.contains(w.as_str()))
}

/// The commands whose label holds every word of `query`. Words rather
/// than the whole string, in any order: "new temp" and "temporary new" mean
/// the same command.
pub fn match_commands(query: &str, commands: &[CommandItem]) -> Vec<CommandItem> {
    commands
        .iter()
        .filter(|c| matches_every_word(&c.label, query))
        .cloned()
        .collect()
}

/// The highlighted row after an arrow key, wrapping at both ends.
pub fn move_index(index: usize, count: usize, down: bool) -> usize {
    if count == 0 {
        return 0;
    }
    let index = index.min(count - 1);
    if down {
        (index + 1) % count
    } else {
        (index + count - 1) % count
    }
}

/// The rows for `query`: chats first (recent ones, or search hits), then
/// the commands that match.
pub fn entries(
    query: &str,
    commands: &[CommandItem],
    recent: &[ChatSummary],
    results: Option<&ChatSearchResults>,
) -> Vec<PaletteEntry> {
    let query = query.trim();
    let mut out: Vec<PaletteEntry> = if query.is_empty() {
        recent
            .iter()
            .take(RECENT_COUNT)
            .map(|c| PaletteEntry::Chat {
                chat_id: c.id.clone(),
                title: c.title.clone(),
                snippet: None,
                updated_at_ms: c.updated_at_ms,
            })
            .collect()
    } else {
        results
            .map(|r| r.hits.as_slice())
            .unwrap_or_default()
            .iter()
            .take(PALETTE_LIMIT as usize)
            .map(|hit| {
                let plain = |s: &str| s.replace(['\u{2068}', '\u{2069}'], "");
                PaletteEntry::Chat {
                    chat_id: hit.chat_id.clone(),
                    title: hit.title.clone(),
                    // Said once: a match in the title comes back as a
                    // snippet of the title.
                    snippet: hit
                        .snippet
                        .clone()
                        .filter(|s| plain(s).trim() != hit.title.trim()),
                    updated_at_ms: hit.updated_at_ms,
                }
            })
            .collect()
    };
    out.extend(
        match_commands(query, commands)
            .into_iter()
            .map(PaletteEntry::Command),
    );
    out
}

pub struct PaletteStore {
    rpc: Rpc,
    pub open: bool,
    query: String,
    /// The last answer, for [`Self::searched`]; stays up while the next
    /// keystroke's search runs, so the list does not blank per letter.
    pub results: Option<ChatSearchResults>,
    searched: String,
    pub searching: bool,
    /// The highlighted row.
    pub index: usize,
    generation: u64,
    _search: Option<Task<()>>,
}

impl PaletteStore {
    pub fn new(rpc: Rpc) -> Self {
        Self {
            rpc,
            open: false,
            query: String::new(),
            results: None,
            searched: String::new(),
            searching: false,
            index: 0,
            generation: 0,
            _search: None,
        }
    }

    pub fn query(&self) -> &str {
        &self.query
    }

    pub fn searched(&self) -> &str {
        &self.searched
    }

    /// Opens it empty, on the first row.
    pub fn show(&mut self, cx: &mut Context<Self>) {
        self.open = true;
        self.reset_query();
        cx.notify();
    }

    pub fn hide(&mut self, cx: &mut Context<Self>) {
        if self.open {
            self.open = false;
            self.reset_query();
            cx.notify();
        }
    }

    fn reset_query(&mut self) {
        self.generation += 1;
        self.query.clear();
        self.results = None;
        self.searched.clear();
        self.searching = false;
        self.index = 0;
        self._search = None;
    }

    /// Sets the query; searches [`PALETTE_DEBOUNCE`] after the last change.
    pub fn set_query(&mut self, query: impl Into<String>, cx: &mut Context<Self>) {
        let query = query.into();
        if query == self.query {
            return;
        }
        self.query = query;
        self.index = 0;
        self.generation += 1;
        let trimmed = self.query.trim().to_string();
        if trimmed.is_empty() {
            self._search = None;
            self.searching = false;
            cx.notify();
            return;
        }
        self.searching = true;
        let generation = self.generation;
        let rpc = self.rpc.clone();
        self._search = Some(
            cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
                cx.background_executor().timer(PALETTE_DEBOUNCE).await;
                let result = rpc
                    .call::<methods::ChatsSearch>(&ChatSearchQuery {
                        query: trimmed.clone(),
                        limit: PALETTE_LIMIT,
                    })
                    .await;
                this.update(cx, |s, cx| {
                    if s.generation != generation {
                        return;
                    }
                    s.searching = false;
                    match result {
                        Ok(results) => {
                            s.results = Some(results);
                            s.searched = trimmed;
                        }
                        Err(e) => log::warn!("chats.search (palette): {e}"),
                    }
                    cx.notify();
                })
                .ok();
            }),
        );
        cx.notify();
    }

    /// Moves the highlight among `count` rows.
    pub fn move_selection(&mut self, down: bool, count: usize, cx: &mut Context<Self>) {
        self.index = move_index(self.index, count, down);
        cx.notify();
    }

    pub fn set_index(&mut self, index: usize, cx: &mut Context<Self>) {
        if self.index != index {
            self.index = index;
            cx.notify();
        }
    }
}

#[cfg(test)]
mod tests {
    use conduit_protocol::ChatSearchHit;
    use gpui_kit::{AppContext as _, TestAppContext};
    use serde_json::json;

    use super::*;
    use crate::stores::rpc::fake::FakeDaemon;

    fn commands() -> Vec<CommandItem> {
        vec![
            CommandItem::new(PaletteCommand::NewChat, "New Chat"),
            CommandItem::new(PaletteCommand::NewTemporaryChat, "New temporary chat"),
            CommandItem::new(PaletteCommand::OpenSettings, "Settings"),
        ]
    }

    fn matched(query: &str) -> Vec<PaletteCommand> {
        match_commands(query, &commands())
            .into_iter()
            .map(|c| c.command)
            .collect()
    }

    // matchCommands

    #[test]
    fn an_empty_query_offers_everything() {
        assert_eq!(matched("  ").len(), 3);
    }

    #[test]
    fn matching_ignores_case() {
        assert_eq!(matched("SETT"), [PaletteCommand::OpenSettings]);
    }

    #[test]
    fn every_word_must_match_in_any_order() {
        assert_eq!(matched("temp new"), [PaletteCommand::NewTemporaryChat]);
        assert_eq!(
            matched("new"),
            [PaletteCommand::NewChat, PaletteCommand::NewTemporaryChat]
        );
    }

    #[test]
    fn a_word_that_matches_nothing_rules_the_command_out() {
        assert!(matched("new zebra").is_empty());
    }

    // movePaletteIndex

    #[test]
    fn the_highlight_moves_and_wraps_at_both_ends() {
        assert_eq!(move_index(0, 3, true), 1);
        assert_eq!(move_index(2, 3, true), 0);
        assert_eq!(move_index(0, 3, false), 2);
    }

    #[test]
    fn an_empty_list_stays_at_zero() {
        assert_eq!(move_index(0, 0, true), 0);
        // A highlight past a shrunken list starts from its last row.
        assert_eq!(move_index(7, 3, true), 0);
    }

    // The rows (command_palette.dart).

    fn summary(id: &str, at: i64) -> ChatSummary {
        ChatSummary {
            unread: false,
            read_only: false,
            id: id.into(),
            title: format!("Chat {id}"),
            updated_at_ms: at,
            pinned: false,
            archived: false,
            folder_id: None,
            model: None,
            tags: vec![],
            shared: false,
            menu: Default::default(),
        }
    }

    #[test]
    fn empty_query_lists_recent_chats_then_every_command() {
        let recent: Vec<ChatSummary> = (0..9).map(|i| summary(&format!("c{i}"), i)).collect();
        let rows = entries(" ", &commands(), &recent, None);
        assert_eq!(rows.len(), RECENT_COUNT + 3);
        assert!(matches!(&rows[0], PaletteEntry::Chat { chat_id, .. } if chat_id == "c0"));
        assert!(matches!(
            &rows[RECENT_COUNT],
            PaletteEntry::Command(CommandItem {
                command: PaletteCommand::NewChat,
                ..
            })
        ));
    }

    #[test]
    fn a_query_lists_hits_then_matching_commands_and_says_a_title_once() {
        let results = ChatSearchResults {
            hits: vec![
                ChatSearchHit {
                    chat_id: "a".into(),
                    title: "New sourdough".into(),
                    snippet: Some("\u{2068}New\u{2069} sourdough".into()),
                    updated_at_ms: 2,
                },
                ChatSearchHit {
                    chat_id: "b".into(),
                    title: "Bread".into(),
                    snippet: Some("a \u{2068}new\u{2069} starter".into()),
                    updated_at_ms: 1,
                },
            ],
            complete: true,
        };
        let rows = entries("new", &commands(), &[], Some(&results));
        assert_eq!(rows.len(), 4);
        assert!(matches!(&rows[0], PaletteEntry::Chat { snippet: None, .. }));
        assert!(matches!(
            &rows[1],
            PaletteEntry::Chat {
                snippet: Some(_),
                ..
            }
        ));
        assert!(
            matches!(&rows[3], PaletteEntry::Command(c) if c.command == PaletteCommand::NewTemporaryChat)
        );
    }

    #[gpui_kit::test]
    fn the_palette_searches_after_a_pause_for_eight_hits(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        daemon.on::<methods::ChatsSearch>(|_| Ok(json!({"hits": [], "complete": true})));
        let store = cx.new(|_| PaletteStore::new(daemon.rpc()));
        store.update(cx, |s, cx| {
            s.show(cx);
            s.set_query("bre", cx);
            s.move_selection(true, 3, cx);
            s.set_query("bread", cx);
        });
        store.read_with(cx, |s, _| {
            assert_eq!(s.index, 0, "a new query starts at the top")
        });
        cx.executor().advance_clock(Duration::from_millis(100));
        cx.run_until_parked();
        assert!(daemon.calls::<methods::ChatsSearch>().is_empty());
        cx.executor().advance_clock(PALETTE_DEBOUNCE);
        cx.run_until_parked();
        assert_eq!(
            daemon.calls::<methods::ChatsSearch>(),
            vec![json!({"query": "bread", "limit": 8})]
        );
        store.read_with(cx, |s, _| {
            assert_eq!(s.searched(), "bread");
            assert!(!s.searching);
        });
        store.update(cx, |s, cx| s.hide(cx));
        store.read_with(cx, |s, _| {
            assert!(!s.open);
            assert_eq!(s.query(), "");
            assert!(s.results.is_none());
        });
    }
}
