//! Find in Chat (⌘F): the find bar's text in the open chat's transcript.
//!
//! * **What is searched:** every loaded row (older pages that have not
//!   loaded are not), the questions' text and the answers' text blocks as
//!   they are drawn: the rendered text, so `**bold**` is found as "bold".
//!   Rows off screen get their views made for it. Collapsed thoughts, tool
//!   output and previews are not searched, as Safari skips hidden text.
//! * **Matching** ignores case; matches do not overlap and come in reading
//!   order.
//! * **Highlights:** every match gets a soft fill and the current one a
//!   strong fill, in the text colour (the palette is monochrome). They paint
//!   behind the glyphs, so nothing moves.
//! * **Stepping:** Find Next and Find Previous (⌘G, ⇧⌘G, and ↩ / ⇧↩ in the
//!   field) wrap around. The current match is scrolled into view: its row
//!   first when it is off screen, then the line it is on.
//! * **Changing text:** an answer's text is parsed off the main thread, and
//!   a streaming one grows. While find is open each text state is observed
//!   and searched again when its rendered text changes; the current match
//!   stays current.

use std::collections::{HashMap, HashSet};
use std::ops::Range;

use conduit_components::ActiveConduitTheme as _;
use conduit_components::theme::{ConduitTheme, with_alpha};
use gpui_kit::base::text::{RangeHighlight, RenderedText};
use gpui_kit::component::text::TextViewState;
use gpui_kit::{App, Context, Entity, EntityId, Hsla, ListOffset, Subscription, px};

use super::Transcript;
use crate::views::chat::rows::RowView;

/// Where in a row a match is.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub enum FindPart {
    /// The question's text.
    Question,
    /// One of an answer's text states, by its key in the row.
    Answer(String),
}

/// One occurrence of the find text.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct FindMatch {
    /// The row's key.
    pub row: String,
    pub part: FindPart,
    /// Bytes of the question's text, or of the state's rendered text.
    pub range: Range<usize>,
}

/// The find bar's search, while it is open.
#[derive(Default)]
pub(super) struct Finder {
    query: String,
    matches: Vec<FindMatch>,
    current: Option<usize>,
    /// The answer text states searched, by row and key.
    states: HashMap<(String, String), Entity<TextViewState>>,
    /// The text each state had when it was last searched.
    searched: HashMap<EntityId, RenderedText>,
    observed: HashSet<EntityId>,
    /// What paints highlights now, to clear what no longer matches.
    painted: HashMap<EntityId, Entity<TextViewState>>,
    painted_rows: HashSet<String>,
    painted_dark: Option<bool>,
    /// Some text changed since the last search.
    dirty: bool,
    _subscriptions: Vec<Subscription>,
}

impl Finder {
    /// The rows whose text states Find holds.
    pub(super) fn searched_rows(&self) -> impl Iterator<Item = &String> {
        self.states.keys().map(|(row, _)| row)
    }
}

/// Where `needle` occurs in `haystack`, ignoring case: byte ranges of
/// `haystack` on character boundaries, left to right, never overlapping.
pub fn find_ranges(haystack: &str, needle: &str) -> Vec<Range<usize>> {
    let needle: Vec<char> = needle.chars().flat_map(char::to_lowercase).collect();
    if needle.is_empty() {
        return vec![];
    }
    // Each folded character with the bytes of the character it came from
    // (one may fold to several, as "İ" does).
    let folded: Vec<(char, usize, usize)> = haystack
        .char_indices()
        .flat_map(|(i, c)| {
            let end = i + c.len_utf8();
            c.to_lowercase().map(move |l| (l, i, end))
        })
        .collect();
    let mut out: Vec<Range<usize>> = vec![];
    let mut i = 0;
    while i + needle.len() <= folded.len() {
        let hit = folded[i..i + needle.len()]
            .iter()
            .map(|f| f.0)
            .eq(needle.iter().copied());
        if hit {
            let range = folded[i].1..folded[i + needle.len() - 1].2;
            if out.last().is_none_or(|last| last.end <= range.start) {
                out.push(range);
            }
            i += needle.len();
        } else {
            i += 1;
        }
    }
    out
}

/// The fills behind the matches and behind the current one.
pub fn find_fills(t: &ConduitTheme) -> (Hsla, Hsla) {
    let text = t.roles.text;
    if t.dark {
        (with_alpha(text, 0.2), with_alpha(text, 0.46))
    } else {
        (with_alpha(text, 0.1), with_alpha(text, 0.3))
    }
}

impl Transcript {
    /// Opens find with `query`, searching at once, or closes it (`None`),
    /// clearing every highlight.
    pub fn set_find(&mut self, query: Option<String>, cx: &mut Context<Self>) {
        match query {
            None => {
                if let Some(finder) = self.find.take() {
                    for state in finder.painted.values() {
                        state.update(cx, |s, cx| s.clear_range_highlights(cx));
                    }
                    for row in &finder.painted_rows {
                        if let Some(RowView::User(view)) = self.rows.get(row) {
                            view.update(cx, |r, cx| r.set_find_highlights(vec![], cx));
                        }
                    }
                }
                cx.notify();
            }
            Some(query) => {
                let finder = self.find.get_or_insert_with(Finder::default);
                if finder.query == query && !finder.dirty && finder.current.is_some() {
                    // The same text again (the bar reopened): show where it was.
                    self.reveal_match(cx);
                    return;
                }
                finder.query = query;
                finder.current = None;
                self.research(true, cx);
            }
        }
    }

    /// Find Next (`forward`) or Find Previous, wrapping around.
    pub fn find_step(&mut self, forward: bool, cx: &mut Context<Self>) {
        let Some(finder) = &mut self.find else {
            return;
        };
        let n = finder.matches.len();
        if n == 0 {
            return;
        }
        finder.current = Some(match finder.current {
            None if forward => 0,
            None => n - 1,
            Some(i) if forward => (i + 1) % n,
            Some(i) => (i + n - 1) % n,
        });
        self.paint_find(cx);
        self.reveal_match(cx);
        cx.notify();
    }

    /// `(current, count)` while there is text to find: the current match,
    /// counted from 1, and how many there are.
    pub fn find_status(&self) -> Option<(Option<usize>, usize)> {
        let finder = self.find.as_ref()?;
        if finder.query.is_empty() {
            return None;
        }
        Some((finder.current.map(|i| i + 1), finder.matches.len()))
    }

    /// The matches, in reading order (for tests and the capture).
    pub fn find_matches(&self) -> &[FindMatch] {
        self.find.as_ref().map_or(&[], |f| &f.matches)
    }

    /// The transcript's rows changed: search again on the next frame.
    pub(super) fn find_rows_changed(&mut self) {
        if let Some(finder) = &mut self.find {
            finder.dirty = true;
        }
    }

    /// Before a frame: search again if some text changed, or repaint in the
    /// appearance's colours.
    pub(super) fn refresh_find(&mut self, cx: &mut Context<Self>) {
        let Some(finder) = &self.find else {
            return;
        };
        let dark = cx.conduit().dark;
        if finder.dirty {
            self.research(false, cx);
        } else if finder.painted_dark != Some(dark) && !finder.matches.is_empty() {
            self.paint_find(cx);
        }
    }

    /// The view of row `ix`, made (not drawn) when it has none yet.
    pub(super) fn find_row_view(&mut self, ix: usize, cx: &mut App) -> Option<(String, RowView)> {
        let store = self.store.read(cx);
        let row = store.rows().get(ix).copied()?;
        let item = store.item(row)?;
        let key = store.row_key(row);
        let flags = self.flags(cx);
        let view = match self.rows.get(&key) {
            Some(view) if view.set(item.clone(), flags.clone(), cx) => view.clone(),
            _ => {
                let view = RowView::new(self.host.clone(), item, flags, cx);
                self.rows.insert(key.clone(), view.clone());
                view
            }
        };
        Some((key, view))
    }

    /// Searches every loaded row again. `reveal`: scroll to the current
    /// match (also done when the first match appears).
    fn research(&mut self, reveal: bool, cx: &mut Context<Self>) {
        let Some(mut finder) = self.find.take() else {
            return;
        };
        finder.dirty = false;
        let previous = finder.current.and_then(|i| finder.matches.get(i).cloned());
        finder.matches.clear();
        finder.states.clear();
        if !finder.query.is_empty() {
            for ix in 0..self.keys.len() {
                let Some((key, view)) = self.find_row_view(ix, cx) else {
                    continue;
                };
                match view {
                    RowView::User(row) => {
                        let text = row.read(cx).item_text();
                        for range in find_ranges(&text, &finder.query) {
                            finder.matches.push(FindMatch {
                                row: key.clone(),
                                part: FindPart::Question,
                                range,
                            });
                        }
                    }
                    RowView::Assistant(row) => {
                        let texts = row.update(cx, |r, cx| r.find_texts(cx));
                        for (part, state) in texts {
                            let id = state.entity_id();
                            if finder.observed.insert(id) {
                                finder._subscriptions.push(cx.observe(
                                    &state,
                                    |t: &mut Transcript, state, cx| {
                                        let Some(finder) = &mut t.find else {
                                            return;
                                        };
                                        let text = state.read(cx).rendered_text();
                                        if finder.searched.get(&state.entity_id()) != Some(&text) {
                                            finder.dirty = true;
                                            cx.notify();
                                        }
                                    },
                                ));
                            }
                            let text = state.read(cx).rendered_text();
                            for range in find_ranges(text.as_str(), &finder.query) {
                                finder.matches.push(FindMatch {
                                    row: key.clone(),
                                    part: FindPart::Answer(part.clone()),
                                    range,
                                });
                            }
                            finder.searched.insert(id, text);
                            finder.states.insert((key.clone(), part), state);
                        }
                    }
                }
            }
        }
        // The same match stays current; else the first from the top of the
        // view down, else the first.
        let top = self.list.logical_scroll_top().item_ix;
        let keys = &self.keys;
        let row_of = |m: &FindMatch| keys.iter().position(|k| *k == m.row);
        let had_current = previous.is_some();
        finder.current = previous
            .and_then(|p| finder.matches.iter().position(|m| *m == p))
            .or_else(|| {
                finder
                    .matches
                    .iter()
                    .position(|m| row_of(m).is_some_and(|ix| ix >= top))
            })
            .or_else(|| (!finder.matches.is_empty()).then_some(0));
        let reveal = reveal || (!had_current && finder.current.is_some());
        self.find = Some(finder);
        self.paint_find(cx);
        if reveal {
            self.reveal_match(cx);
        }
        cx.notify();
    }

    /// Paints every match, the current one stronger, and clears what no
    /// longer matches.
    fn paint_find(&mut self, cx: &mut Context<Self>) {
        let Some(mut finder) = self.find.take() else {
            return;
        };
        let t = cx.conduit().clone();
        let (soft, strong) = find_fills(&t);
        finder.painted_dark = Some(t.dark);
        let mut answers: HashMap<(String, String), Vec<RangeHighlight>> = HashMap::new();
        let mut questions: HashMap<String, Vec<(Range<usize>, Hsla)>> = HashMap::new();
        for (i, m) in finder.matches.iter().enumerate() {
            let fill = if finder.current == Some(i) {
                strong
            } else {
                soft
            };
            match &m.part {
                FindPart::Question => questions
                    .entry(m.row.clone())
                    .or_default()
                    .push((m.range.clone(), fill)),
                FindPart::Answer(part) => answers
                    .entry((m.row.clone(), part.clone()))
                    .or_default()
                    .push(RangeHighlight::new(m.range.clone(), fill)),
            }
        }
        let mut painted = HashMap::new();
        for (key, highlights) in answers {
            let Some(state) = finder.states.get(&key) else {
                continue;
            };
            // Text that changed since it was searched rejects the set; the
            // search runs again once it has (the state is observed).
            let ok = state.update(cx, |s, cx| s.set_range_highlights(highlights, cx).is_ok());
            if ok {
                painted.insert(state.entity_id(), state.clone());
            }
        }
        for (id, state) in &finder.painted {
            if !painted.contains_key(id) {
                state.update(cx, |s, cx| s.clear_range_highlights(cx));
            }
        }
        finder.painted = painted;
        let mut painted_rows = HashSet::new();
        for (row, ranges) in questions {
            if let Some(RowView::User(view)) = self.rows.get(&row) {
                view.update(cx, |r, cx| r.set_find_highlights(ranges, cx));
                painted_rows.insert(row);
            }
        }
        for row in &finder.painted_rows {
            if !painted_rows.contains(row)
                && let Some(RowView::User(view)) = self.rows.get(row)
            {
                view.update(cx, |r, cx| r.set_find_highlights(vec![], cx));
            }
        }
        finder.painted_rows = painted_rows;
        self.find = Some(finder);
    }

    /// Scrolls the current match into view: its row, then its line.
    fn reveal_match(&mut self, cx: &mut Context<Self>) {
        let Some(finder) = &self.find else {
            return;
        };
        let Some(m) = finder.current.and_then(|i| finder.matches.get(i)).cloned() else {
            return;
        };
        let Some(ix) = self.keys.iter().position(|k| *k == m.row) else {
            return;
        };
        let state = match &m.part {
            FindPart::Answer(part) => finder.states.get(&(m.row.clone(), part.clone())).cloned(),
            FindPart::Question => None,
        };
        self.stop_following();
        // Measured once is not on screen: a row below or above the view
        // comes in first.
        let shown = self.on_screen(ix);
        match (&state, shown) {
            // On screen: the answer scrolls to the line itself.
            (Some(_), true) => {}
            (None, true) => self.list.scroll_to_reveal_item(ix),
            // Off screen: its row comes in first.
            (_, false) => self.list.scroll_to(ListOffset {
                item_ix: ix,
                offset_in_item: px(0.),
            }),
        }
        if let Some(state) = state {
            // Every chunk of the answer laid out while it reveals: a chunk
            // held far from the view (`LazyChunk`) could not scroll to it.
            if let Some(RowView::Assistant(view)) = self.rows.get(&m.row) {
                view.update(cx, |r, cx| r.reveal_text(cx));
            }
            let range = m.range.clone();
            let _ = state.update(cx, |s, cx| s.reveal_range(range, cx));
        }
        cx.notify();
    }
}

#[cfg(test)]
mod tests {
    use std::rc::Rc;

    use conduit_components::theme::{DesignPrefs, install};
    use conduit_protocol::{
        ChatDetail, ChatMessageDto, ChatResult, ChatSummary, Event, MessageBlockDto,
        MessageBlockKind, TurnBlocks, methods,
    };
    use gpui_kit::{AppContext as _, ParentElement as _, Styled as _};
    use gpui_kit::{TestAppContext, VisualTestContext, div, point, size};

    use super::*;
    use crate::l10n::L10n;
    use crate::stores::chat::{ChatStore, Subscribe, empty_block};
    use crate::stores::rpc::fake::FakeDaemon;
    use crate::views::chat::rows::{RowHost, RowSink};

    fn message(id: &str, role: &str, content: &str) -> ChatMessageDto {
        ChatMessageDto {
            sibling_ids: vec![],
            parent_id: None,
            slot: None,
            merged: None,
            retry_without_effort: false,
            comparison: vec![],
            mergeable_ids: vec![],
            id: id.into(),
            role: role.into(),
            content: content.into(),
            timestamp_ms: 1,
            model: (role == "assistant").then(|| "m".into()),
            model_name: None,
            streaming: false,
            error_code: None,
            versions: vec![],
            sources: vec![],
            usage: None,
            rating: None,
            files: vec![],
            // The daemon sends an answer's text as a text block.
            blocks: if role == "assistant" && !content.is_empty() {
                vec![MessageBlockDto {
                    markdown: Some(content.into()),
                    ..empty_block(MessageBlockKind::Text)
                }]
            } else {
                vec![]
            },
            queued: None,
        }
    }

    /// `messages` open in a transcript, drawn once.
    fn open(
        messages: Vec<ChatMessageDto>,
        cx: &mut TestAppContext,
    ) -> (
        Entity<ChatStore>,
        Entity<Transcript>,
        &mut VisualTestContext,
    ) {
        cx.update(|cx| {
            gpui_kit::init(cx);
            install(
                ConduitTheme::new("conduit", false, DesignPrefs::default(), gpui_kit::black()),
                cx,
            );
            cx.set_global(L10n::new("en"));
            cx.set_global(conduit_components::Strings::default());
        });
        let daemon = FakeDaemon::new();
        daemon.returns::<methods::ChatsGet>(ChatResult {
            chat: Some(ChatDetail {
                hermes: None,
                abilities: Default::default(),
                temporary: false,
                share_id: None,
                read_only: false,
                summary: ChatSummary {
                    unread: false,
                    read_only: false,
                    id: "c1".into(),
                    title: "A chat".into(),
                    updated_at_ms: 1,
                    pinned: false,
                    archived: false,
                    folder_id: None,
                    model: None,
                    tags: vec![],
                    shared: false,
                    menu: Default::default(),
                },
                messages,
                system_prompt: None,
                tasks: vec![],
            }),
        });
        let subscribe: Subscribe = Rc::new(|_, _| {});
        let rpc = daemon.rpc();
        let store = cx.new(|cx| ChatStore::new(rpc, subscribe, "c1".into(), cx));
        cx.run_until_parked();
        let host = RowHost {
            store: store.downgrade(),
            pane: RowSink::None,
            server_id: None,
            composer: None,
        };
        let transcript = cx.new(|cx| Transcript::new(store.clone(), host, cx));
        let cx = cx.add_empty_window();
        draw(&transcript, cx);
        (store, transcript, cx)
    }

    /// Lays the transcript out 400 pt tall, then again once the text parsed
    /// off the main thread has landed.
    fn draw(transcript: &Entity<Transcript>, cx: &mut VisualTestContext) {
        for settle in [false, true, true] {
            if settle {
                cx.run_until_parked();
            }
            let view = transcript.clone();
            cx.draw(point(px(0.), px(0.)), size(px(800.), px(400.)), |_, _| {
                div().flex().flex_col().size_full().child(view)
            });
        }
    }

    fn find(transcript: &Entity<Transcript>, query: Option<&str>, cx: &mut VisualTestContext) {
        let query = query.map(str::to_string);
        transcript.update(cx, |t, cx| t.set_find(query, cx));
        draw(transcript, cx);
    }

    fn status(
        transcript: &Entity<Transcript>,
        cx: &mut VisualTestContext,
    ) -> Option<(Option<usize>, usize)> {
        transcript.read_with(cx, |t, _| t.find_status())
    }

    #[gpui_kit::test]
    fn finds_questions_and_answers_in_reading_order_and_wraps(cx: &mut TestAppContext) {
        let (_, transcript, cx) = open(
            vec![
                message("u1", "user", "How far is the moon?"),
                message(
                    "a1",
                    "assistant",
                    "The moon is about 384,400 km away.\n\nThe **Moon** orbits once a month.",
                ),
            ],
            cx,
        );
        find(&transcript, Some("MOON"), cx);
        let matches = transcript.read_with(cx, |t, _| t.find_matches().to_vec());
        let parts: Vec<_> = matches.iter().map(|m| m.part.clone()).collect();
        assert_eq!(matches.len(), 3, "{matches:?}");
        assert_eq!(parts[0], FindPart::Question);
        assert!(matches!(parts[1], FindPart::Answer(_)));
        // Markdown is found as drawn: the bold "Moon", not "**Moon**".
        assert!(matches!(parts[2], FindPart::Answer(_)));
        assert_eq!(status(&transcript, cx), Some((Some(1), 3)));
        let step = |forward: bool, cx: &mut VisualTestContext| {
            transcript.update(cx, |t, cx| t.find_step(forward, cx));
            status(&transcript, cx).and_then(|s| s.0)
        };
        assert_eq!(step(true, cx), Some(2));
        assert_eq!(step(true, cx), Some(3));
        assert_eq!(step(true, cx), Some(1), "wraps to the first");
        assert_eq!(step(false, cx), Some(3), "and back to the last");

        find(&transcript, Some("mars"), cx);
        assert_eq!(status(&transcript, cx), Some((None, 0)));
        find(&transcript, Some(""), cx);
        assert_eq!(status(&transcript, cx), None, "nothing to find");
        find(&transcript, None, cx);
        assert_eq!(status(&transcript, cx), None);
        assert!(transcript.read_with(cx, |t, _| t.find_matches().is_empty()));
    }

    #[gpui_kit::test]
    fn finds_rows_never_drawn_and_scrolls_to_them(cx: &mut TestAppContext) {
        let mut messages = vec![message("u0", "user", "Where is the lighthouse needle?")];
        for i in 1..40 {
            messages.push(message(
                &format!("a{i}"),
                "assistant",
                &format!("Answer {i} of many, long enough to take a line."),
            ));
            messages.push(message(&format!("u{i}"), "user", &format!("Question {i}?")));
        }
        let (_, transcript, cx) = open(messages, cx);
        let list = transcript.read_with(cx, |t, _| t.list_state().clone());
        // A tall chat sits at its end: the first question is not laid out.
        assert!(list.bounds_for_item(0).is_none());
        find(&transcript, Some("needle"), cx);
        assert_eq!(status(&transcript, cx), Some((Some(1), 1)));
        draw(&transcript, cx);
        assert!(
            list.bounds_for_item(0).is_some(),
            "the current match's row is scrolled into view"
        );
        // Answers off screen are searched too.
        find(&transcript, Some("answer 3"), cx);
        let count = status(&transcript, cx).map(|s| s.1);
        // "Answer 3", "Answer 30" … "Answer 39".
        assert_eq!(count, Some(11));
    }

    #[gpui_kit::test]
    fn an_answer_measured_once_but_off_screen_is_scrolled_to(cx: &mut TestAppContext) {
        let mut messages = vec![
            message("u0", "user", "First question?"),
            message("a0", "assistant", "The haystack hides one needle here."),
        ];
        for i in 1..40 {
            messages.push(message(&format!("u{i}"), "user", &format!("Question {i}?")));
            messages.push(message(
                &format!("a{i}"),
                "assistant",
                &format!("Answer {i} of many, long enough to take a line."),
            ));
        }
        let (_, transcript, cx) = open(messages, cx);
        let list = transcript.read_with(cx, |t, _| t.list_state().clone());
        // Drawn at the top once (so measured), then back at the end.
        list.scroll_to(ListOffset {
            item_ix: 0,
            offset_in_item: px(0.),
        });
        draw(&transcript, cx);
        assert!(list.bounds_for_item(1).is_some());
        list.scroll_to(ListOffset {
            item_ix: 79,
            offset_in_item: px(0.),
        });
        draw(&transcript, cx);
        assert_eq!(list.item_is_above_viewport(1), Some(true));
        find(&transcript, Some("needle"), cx);
        draw(&transcript, cx);
        assert_eq!(
            list.item_is_above_viewport(1),
            Some(false),
            "the answer with the match is scrolled into view"
        );
    }

    #[gpui_kit::test]
    fn an_answer_streaming_in_is_searched_as_it_grows(cx: &mut TestAppContext) {
        let (store, transcript, cx) = open(
            vec![
                message("u1", "user", "Tell me about tides."),
                message("a1", "assistant", ""),
            ],
            cx,
        );
        find(&transcript, Some("high water"), cx);
        assert_eq!(status(&transcript, cx), Some((None, 0)));
        for lines in [1, 3] {
            let text = (1..=lines)
                .map(|i| format!("High water number {i}."))
                .collect::<Vec<_>>()
                .join("\n\n");
            store.update(cx, |s, cx| {
                s.on_event(
                    &Event::TurnBlocks(TurnBlocks {
                        chat_id: "c1".into(),
                        message_id: "a1".into(),
                        blocks: vec![MessageBlockDto {
                            markdown: Some(text),
                            ..empty_block(MessageBlockKind::Text)
                        }],
                        tasks: None,
                    }),
                    cx,
                )
            });
            // The new words are released over the next frames (a steady
            // pace), and searched as they show.
            for _ in 0..20 {
                cx.executor()
                    .advance_clock(std::time::Duration::from_millis(16));
                draw(&transcript, cx);
            }
            assert_eq!(
                status(&transcript, cx).map(|s| s.1),
                Some(lines),
                "{lines} lines"
            );
        }
        // The first match became current as it arrived, and stays so.
        assert_eq!(status(&transcript, cx).and_then(|s| s.0), Some(1));
    }

    fn found<'a>(haystack: &'a str, needle: &str) -> Vec<&'a str> {
        find_ranges(haystack, needle)
            .into_iter()
            .map(|r| &haystack[r])
            .collect()
    }

    #[test]
    fn matches_ignore_case_and_never_overlap() {
        assert_eq!(
            found("Tide, tide and TIDE.", "tide"),
            ["Tide", "tide", "TIDE"]
        );
        assert_eq!(found("aaaa", "aa"), ["aa", "aa"]);
        assert!(found("moon", "").is_empty());
        assert!(found("moon", "sun").is_empty());
        assert!(found("", "x").is_empty());
    }

    #[test]
    fn ranges_land_on_character_boundaries() {
        let text = "Größe und GRÖSSE · Überblick über Ü";
        assert_eq!(found(text, "über"), ["Über", "über"]);
        assert_eq!(found(text, "größe"), ["Größe"]);
        // A character that folds to two keeps its own bytes.
        let dotted = "İstanbul";
        for r in find_ranges(dotted, "i") {
            assert!(dotted.is_char_boundary(r.start) && dotted.is_char_boundary(r.end));
        }
        assert_eq!(found("日本語のテキスト", "テキ"), ["テキ"]);
    }

    #[test]
    fn the_current_match_paints_stronger() {
        for dark in [false, true] {
            let t = ConduitTheme::new(
                "conduit",
                dark,
                conduit_components::theme::DesignPrefs::default(),
                gpui_kit::black(),
            );
            let (soft, strong) = find_fills(&t);
            assert!(strong.a > soft.a * 2.);
        }
    }
}
