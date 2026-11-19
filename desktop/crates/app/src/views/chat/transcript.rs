//! The transcript: a virtualized GPUI `list` over the open chat's rows.
//!
//! * **Fills from the top**, as the phone's does: a chat shorter than the
//!   window starts under the toolbar, and the rows it gains go below. Once
//!   it is taller than the window, its end sits at the bottom (following).
//! * **Rows** are built lazily: only rows on screen ask the store for their
//!   view model, and each keeps its own view (and TextView states) across
//!   frames, keyed by message id.
//! * **Changes** reach the list as small edits: rows that came or went are
//!   spliced in by key (common prefix and suffix); a refetch remeasures
//!   every row (keeping the scroll position); a streaming tick remeasures
//!   only the live row.
//! * **Stick to bottom** while streaming: the list follows its tail until
//!   the user scrolls up, and again once they scroll back down. Sending a
//!   message jumps to the end. (Following must be paused before a
//!   programmatic `scroll_by`, or the list snaps back.) Following lays out
//!   from the end, and a top-aligned list clamps what does not fill the
//!   window to the top, so the change from a short chat to a tall one is
//!   continuous: no jump the moment it overflows.
//! * **Eased follow:** when the answer grows (a streaming tick, a row
//!   added at the end) the list's own following is paused, so what is on
//!   screen stays put that frame, and a critically damped spring
//!   ([`Chase`]) carries the view to the new end over about 200 ms,
//!   keeping its speed when more text lands. It hands back to the list's
//!   following once there, and lets go the moment the user scrolls. Under
//!   Reduce Motion the end is followed at once, as before.
//! * **Older messages** load a page at a time when the top row comes into
//!   view, spliced in above without moving what is on screen.
//! * **Citations:** a click on `[n]` opens a popover with the sources it
//!   names; choosing one opens it in the browser.
//! * **Find in Chat** (⌘F) highlights the find bar's text in every loaded
//!   row and scrolls to the current match ([`find`]).

mod find;
pub use find::find_fills;
mod reading;
pub use find::{FindMatch, FindPart, find_ranges};

use std::collections::{HashMap, HashSet};

use conduit_components::ActiveConduitTheme as _;

use conduit_components::motion::{self, Chase, specs};
use conduit_components::views::shell::CHAT_COLUMN;
use conduit_protocol::ChatSourceDto;
use gpui_kit::prelude::*;
use gpui_kit::{
    Anchor, AnyElement, App, Bounds, Context, ElementId, Entity, FocusHandle, FollowMode,
    FontWeight, ListAlignment, ListState, PathBuilder, Pixels, Point, Role, SharedString,
    Subscription, Window, anchored, canvas, deferred, div, list, point, px,
};

use super::CitationTarget;
use super::rows::{RowFlags, RowHost, RowView};
use crate::l10n::ActiveL10n as _;
use crate::stores::chat::{ChatStore, Row};

struct Citation {
    key: String,
    numbers: Vec<usize>,
    position: Point<Pixels>,
    /// Opened by hovering the pill: it closes once the pointer leaves the
    /// pill and the preview. A click keeps it open.
    by_hover: bool,
}

/// What a row's popover shows.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RowPopoverKind {
    /// An answer's usage (Info).
    Usage,
    /// A message's versions.
    Versions,
}

#[derive(Clone, Debug, PartialEq)]
struct RowPopover {
    kind: RowPopoverKind,
    key: String,
    position: Point<Pixels>,
}

/// Opens a row's popover in the transcript on screen, hung from `position`
/// (where its button was clicked).
pub fn show_row_popover(kind: RowPopoverKind, key: String, position: Point<Pixels>, cx: &mut App) {
    let Some(target) = cx.try_global::<CitationTarget>().map(|t| t.0.clone()) else {
        return;
    };
    let _ = target.update(cx, |t, cx| {
        t.row_popover = Some(RowPopover {
            kind,
            key,
            position,
        });
        cx.notify();
    });
}

pub struct Transcript {
    store: Entity<ChatStore>,
    host: RowHost,
    list: ListState,
    keys: Vec<String>,
    rows: HashMap<String, RowView>,
    /// Rows drawn since the cache was last pruned.
    drawn: HashSet<String>,
    seen: (u64, u64),
    citation: Option<Citation>,
    /// The popover just closed, drawn while it fades out.
    leaving_citation: Option<Citation>,
    /// Where the transcript was drawn last (window coordinates), so the
    /// citation popover stays inside the chat column.
    bounds: std::rc::Rc<std::cell::Cell<Bounds<Pixels>>>,
    at_top: bool,
    /// Easing toward the end (see the module doc), with its last frame.
    chase: Option<(Chase, std::time::Instant)>,
    /// The end moved since the list last laid out: its new place is known
    /// only after the next layout, so the chase cannot have arrived yet.
    chase_fresh: bool,
    /// Frames in a row the chase has sat at the end.
    chase_quiet: u8,
    focus: FocusHandle,
    /// What had focus when last drawn: Tab moving onto a row's buttons
    /// scrolls that row into view.
    last_focus: Option<FocusHandle>,
    /// Whether the edges fade by painting the content colour over them
    /// (exactly an alpha fade on the opaque chat column). Off where the
    /// surface is translucent and the window masks GPUI's layer instead
    /// (Quick Ask).
    painted_fades: bool,
    /// Find in Chat, while its bar is open.
    find: Option<find::Finder>,
    /// A row's Usage or Versions popover, and the one fading out.
    row_popover: Option<RowPopover>,
    leaving_row_popover: Option<RowPopover>,
    /// Settings › Chat › Message Actions: the actions shown under each
    /// answer, in order, or `None` for Automatic.
    action_prefs: Option<Vec<String>>,
    /// The answer being read aloud (its shown version's id).
    reading: Option<String>,
    /// Its sentence and word, marked in place.
    reader: Option<reading::Reader>,
    /// Show All Branches… in the version list: the chat pane opens them.
    on_branches: Option<super::popovers::ShowBranches>,
    /// A hover on a citation pill: the preview opens after a moment, and
    /// one opened by hover closes a moment after the pointer leaves.
    citation_hover: Option<gpui_kit::Task<()>>,
    /// The pointer is over the preview.
    citation_preview_hovered: bool,
    _subscriptions: Vec<Subscription>,
}

/// Where keyboard focus is, as Tab walks the chat: on a row's controls,
/// below the transcript (the composer and what is docked over it), or
/// elsewhere (the toolbar, the sidebar).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Spot {
    Row(usize),
    Below,
    Elsewhere,
}

/// The rows a Tab move from `from` to `to` passed over without stopping, of
/// `rows` rows (`back`: Shift-Tab). A move that came round the window's
/// order the other way (from the first row drawn back to the composer, say,
/// when nothing above it was drawn) passed over every row on its way. Moves
/// that do not cross rows (within one, within the composer) pass over none.
pub fn passed_over(back: bool, from: Spot, to: Spot, rows: usize) -> std::ops::Range<usize> {
    use Spot::*;
    let none = 0..0;
    match (back, from, to) {
        (true, Below, Row(t)) => t + 1..rows,
        (true, Below, Elsewhere) => 0..rows,
        (true, Row(r), Row(t)) if t < r => t + 1..r,
        (true, Row(r), Row(t)) if t > r => 0..r,
        (true, Row(r), Below | Elsewhere) => 0..r,
        (false, Row(r), Row(t)) if t > r => r + 1..t,
        (false, Row(r), Row(t)) if t < r => r + 1..rows,
        (false, Row(r), Below | Elsewhere) => r + 1..rows,
        _ => none,
    }
}

/// How quickly the view catches up with a growing answer (the spring's
/// response, in seconds).
const FOLLOW_RESPONSE: f32 = 0.2;

/// Rows kept beyond those on screen before the cache is pruned.
const ROW_CACHE: usize = 400;

/// The fade at the top that earlier messages slide under.
const TOP_FADE: f32 = 20.;
/// How long a pointer rests on a citation before its preview opens, and how
/// long a preview opened that way stays once the pointer has left.
const CITATION_HOVER_MS: u64 = 450;
const CITATION_LEAVE_MS: u64 = 250;

/// The citation popover's width, and its tail's height.
const POPOVER_WIDTH: f32 = 320.;
pub(crate) const TAIL_HEIGHT: f32 = 8.;

/// The popover's tail: a small triangle in the card's fill with its
/// outline on the two slanted edges, its tip `x` from the card's left, on
/// the top edge (`up`) or the bottom one. It overlaps the card's border by
/// a point so the two read as one shape.
pub(crate) fn popover_tail(
    x: Pixels,
    up: bool,
    fill: gpui_kit::Hsla,
    line: gpui_kit::Hsla,
) -> AnyElement {
    let half = px(TAIL_HEIGHT);
    canvas(
        |_, _, _| {},
        move |bounds, _, window, _| {
            let o = bounds.origin;
            let (base_y, tip_y) = if up {
                (o.y + px(TAIL_HEIGHT + 1.), o.y)
            } else {
                (
                    o.y + bounds.size.height - px(TAIL_HEIGHT + 1.),
                    o.y + bounds.size.height,
                )
            };
            let (l, tip, r) = (
                point(o.x + x - half, base_y),
                point(o.x + x, tip_y),
                point(o.x + x + half, base_y),
            );
            let mut shape = PathBuilder::fill();
            shape.move_to(l);
            shape.line_to(tip);
            shape.line_to(r);
            shape.close();
            if let Ok(path) = shape.build() {
                window.paint_path(path, fill);
            }
            let mut edge = PathBuilder::stroke(px(1.));
            edge.move_to(l);
            edge.line_to(tip);
            edge.line_to(r);
            if let Ok(path) = edge.build() {
                window.paint_path(path, line);
            }
        },
    )
    .absolute()
    .top_0()
    .left_0()
    .size_full()
    .into_any_element()
}
/// Above the first row, so a chat's start clears the top fade (with a row's
/// own room above its message, its first line sits ~22 pt down).
const TOP_INSET: f32 = 12.;
/// Below the last row (an answer keeps no room of its own under its action
/// row), so a chat's end clears the fade over the composer: an answer's
/// last line, or its Suggestions, end ~32 pt above the composer.
const BOTTOM_INSET: f32 = TOP_FADE + 12.;

impl Transcript {
    /// Selects the newest answer's first text block whole, as a drag across
    /// it would (the E2E pass's selection for Ask Conduit).
    pub fn select_newest_answer(&mut self, cx: &mut Context<Self>) -> bool {
        let store = self.store.read(cx);
        let newest = store
            .rows()
            .iter()
            .rev()
            .find(|r| {
                store
                    .item(**r)
                    .is_some_and(|i| i.role == crate::stores::chat::Role::Assistant)
            })
            .map(|r| store.row_key(*r));
        let Some(RowView::Assistant(row)) = newest.and_then(|k| self.rows.get(&k)) else {
            return false;
        };
        let state = row.read(cx).texts.values().next().map(|(_, s)| s.clone());
        match state {
            Some(state) => {
                state.update(cx, |s, cx| s.select_all(cx));
                true
            }
            None => false,
        }
    }

    /// The text selected in an answer, if any (as selected: not trimmed),
    /// for Ask Conduit and Copy.
    pub fn selected_reply_text(&self, cx: &App) -> Option<String> {
        self.rows.values().find_map(|row| match row {
            RowView::Assistant(a) => a.read(cx).selected_text(cx),
            RowView::User(_) => None,
        })
    }

    pub fn new(store: Entity<ChatStore>, host: RowHost, cx: &mut Context<Self>) -> Self {
        // Top-aligned, so a short chat starts under the toolbar; following
        // the tail keeps a tall one's end at the bottom (see the module doc).
        let list = ListState::new(0, ListAlignment::Top, px(800.));
        list.set_follow_mode(FollowMode::Tail);
        let weak = cx.entity().downgrade();
        list.set_scroll_handler(move |event, _, cx| {
            let at_top = event.visible_range.start == 0;
            let _ = weak.update(cx, |t, cx| {
                // The user took the wheel: stop easing toward the end.
                t.chase = None;
                t.scrolled(at_top, cx)
            });
        });
        let mut subscriptions = vec![cx.observe(&store, |this, _, cx| this.sync(cx))];
        // A chat a coding agent answers offers no Regenerate or Edit: the
        // rows follow the composer's word on it.
        if let Some(composer) = host
            .composer
            .as_ref()
            .and_then(gpui_kit::WeakEntity::upgrade)
        {
            let mut agent_chat = composer.read(cx).agent_chat();
            subscriptions.push(cx.observe(&composer, move |_, composer, cx| {
                let now = composer.read(cx).agent_chat();
                if now != agent_chat {
                    agent_chat = now;
                    cx.notify();
                }
            }));
        }
        let mut this = Self {
            store,
            host,
            list,
            keys: vec![],
            rows: HashMap::new(),
            drawn: HashSet::new(),
            seen: (u64::MAX, u64::MAX),
            citation: None,
            leaving_citation: None,
            citation_hover: None,
            citation_preview_hovered: false,
            bounds: Default::default(),
            at_top: false,
            chase: None,
            chase_fresh: false,
            chase_quiet: 0,
            focus: cx.focus_handle(),
            last_focus: None,
            painted_fades: true,
            find: None,
            row_popover: None,
            leaving_row_popover: None,
            action_prefs: None,
            reading: None,
            reader: None,
            on_branches: None,
            _subscriptions: subscriptions,
        };
        this.sync(cx);
        this
    }

    /// Settings › Chat › Message Actions, as the rows lay out their actions.
    /// Which answer is being read aloud (its Read Aloud says Stop Speaking).
    pub fn set_reading(&mut self, reading: Option<String>, cx: &mut Context<Self>) {
        if self.reading != reading {
            self.reading = reading;
            cx.notify();
        }
    }

    pub fn set_action_prefs(&mut self, prefs: Option<Vec<String>>, cx: &mut Context<Self>) {
        if self.action_prefs != prefs {
            self.action_prefs = prefs;
            cx.notify();
        }
    }

    /// What Show All Branches… does (the chat pane's Branches sheet).
    pub fn set_on_branches(&mut self, f: super::popovers::ShowBranches) {
        self.on_branches = Some(f);
    }

    /// The flags every row is drawn with now.
    pub(super) fn flags(&self, cx: &App) -> RowFlags {
        let store = self.store.read(cx);
        RowFlags {
            can_branch: store.can_branch(),
            can_follow_up: !store.missing && !store.read_only(),
            abilities: store.abilities(),
            merging: store.merging(),
            actions: self.action_prefs.clone(),
            reading: self.reading.clone(),
            hermes: store.hermes().is_some(),
            agent_chat: self.host.agent_chat(cx),
        }
    }

    /// Which row popover shows, if one does (the E2E pass checks it).
    pub fn row_popover_open(&self) -> Option<(RowPopoverKind, String)> {
        self.row_popover.as_ref().map(|p| (p.kind, p.key.clone()))
    }

    pub fn close_row_popover(&mut self, cx: &mut Context<Self>) {
        if let Some(p) = self.row_popover.take() {
            self.leaving_row_popover = Some(p);
            cx.notify();
        }
    }

    /// Leaves the edge fades to the window (see `painted_fades`).
    pub fn without_painted_fades(mut self) -> Self {
        self.painted_fades = false;
        self
    }

    /// The fade at each edge, in points.
    pub const EDGE_FADE: f32 = TOP_FADE;

    pub fn list_state(&self) -> &ListState {
        &self.list
    }

    /// Follows the end again (after sending).
    pub fn scroll_to_end(&mut self, cx: &mut Context<Self>) {
        self.chase = None;
        self.list.set_follow_mode(FollowMode::Tail);
        self.list.scroll_to_end();
        cx.notify();
    }

    /// Stops following the end (and easing toward it) until the view is
    /// sent back to the end: for a caller that scrolls the list itself.
    pub fn stop_following(&mut self) {
        self.chase = None;
        self.list.set_follow_mode(FollowMode::Normal);
    }

    /// Scrolls by `delta` (negative is up), pausing tail-following first so
    /// the list does not snap back.
    pub fn scroll_by(&mut self, delta: Pixels, cx: &mut Context<Self>) {
        self.chase = None;
        self.list.pause_following_tail();
        self.list.scroll_by(delta);
        cx.notify();
    }

    /// Applies the store's change to the list.
    fn sync(&mut self, cx: &mut Context<Self>) {
        let store = self.store.read(cx);
        let keys: Vec<String> = store.rows().iter().map(|r| store.row_key(*r)).collect();
        let revisions = store.revisions();
        let live_ix = store.rows().iter().position(|r| *r == Row::Live);
        let mut grows = false;
        if keys != self.keys {
            let old = &self.keys;
            let prefix = old.iter().zip(&keys).take_while(|(a, b)| a == b).count();
            let max_suffix = old.len().min(keys.len()) - prefix;
            let suffix = old
                .iter()
                .rev()
                .zip(keys.iter().rev())
                .take(max_suffix)
                .take_while(|(a, b)| a == b)
                .count();
            if old.is_empty() {
                self.list.reset(keys.len());
                self.list.set_follow_mode(FollowMode::Tail);
            } else {
                // Rows only added at the end: the answer arriving.
                grows = suffix == 0 && prefix == old.len();
                // One answer row taking another's place (a regenerate's
                // answer under the id the server gave it, the waiting row
                // becoming the answer): the view goes with it, so what it
                // is fading carries on.
                if old.len() - suffix - prefix == 1 && keys.len() - suffix - prefix == 1 {
                    let (from, to) = (&old[prefix], &keys[prefix]);
                    if !self.rows.contains_key(to)
                        && let Some(view @ RowView::Assistant(_)) = self.rows.get(from).cloned()
                    {
                        self.rows.remove(from);
                        self.rows.insert(to.clone(), view);
                    }
                }
                self.list
                    .splice(prefix..old.len() - suffix, keys.len() - prefix - suffix);
            }
            self.keys = keys;
        }
        if revisions.0 != self.seen.0 {
            self.list.remeasure();
        } else if revisions.1 != self.seen.1
            && let Some(ix) = live_ix
        {
            self.list.remeasure_items(ix..ix + 1);
            grows = true;
        }
        self.seen = revisions;
        if grows {
            self.ease_to_end(cx);
        }
        self.find_rows_changed();
        cx.notify();
    }

    /// The end is about to move: keep what is on screen still this frame
    /// and ease after it (when following, and motion is welcome).
    fn ease_to_end(&mut self, cx: &mut Context<Self>) {
        if cx.reduce_motion() || (self.chase.is_none() && !self.list.is_following_tail()) {
            return;
        }
        self.list.pause_following_tail();
        self.chase_fresh = true;
        if self.chase.is_none() {
            let at = self.scroll_offset();
            self.chase = Some((
                Chase::new(at, FOLLOW_RESPONSE),
                cx.background_executor().now(),
            ));
        }
    }

    /// Following the end, by the list or by the eased chase.
    pub fn follows_end(&self) -> bool {
        self.chase.is_some() || self.list.is_following_tail()
    }

    /// How far the list is scrolled, in points from its top.
    fn scroll_offset(&self) -> f32 {
        -f32::from(self.list.scroll_px_offset_for_scrollbar().y)
    }

    /// One frame of easing toward the end. The chase keeps the list's own
    /// following paused for as long as the answer streams (its text is
    /// parsed off the main thread, so a line can land a frame or two after
    /// its tick, and following would jump to it); once the answer is done
    /// and the end has held still for a few frames it hands back.
    fn step_chase(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let fresh = std::mem::take(&mut self.chase_fresh);
        let Some((mut chase, last)) = self.chase.take() else {
            return;
        };
        let now = cx.background_executor().now();
        let dt = now.saturating_duration_since(last).as_secs_f32();
        let at = self.scroll_offset();
        // The list can move on its own (rows remeasured): go on from there.
        if (chase.position - at).abs() > 1. {
            chase.position = at;
        }
        // The end as last laid out: the rows, the list's insets above and
        // below them (the end stays clear of the fade over the composer),
        // the viewport.
        let end =
            (f32::from(self.list.max_offset_for_scrollbar().y) + TOP_INSET + BOTTOM_INSET).max(0.);
        let next = chase.step(end, dt);
        self.chase_quiet = if !fresh && chase.settled(end) {
            self.chase_quiet.saturating_add(1)
        } else {
            0
        };
        let streaming = self.store.read(cx).is_streaming();
        if (!streaming && self.chase_quiet >= 3) || cx.reduce_motion() {
            // Following again, exactly at the end.
            self.list.scroll_to_end();
            return;
        }
        if (next - at).abs() > 0.01 {
            self.list.scroll_by(px(next - at));
        }
        // The list re-engages following when it finds itself at the end;
        // the chase keeps it.
        self.list.pause_following_tail();
        self.chase = Some((chase, now));
        window.request_animation_frame();
    }

    fn scrolled(&mut self, at_top: bool, cx: &mut Context<Self>) {
        if at_top != self.at_top {
            self.at_top = at_top;
            cx.notify();
        }
        if at_top && self.store.read(cx).hidden() > 0 {
            self.load_older(cx);
        }
    }

    /// Shows another page of older messages above, keeping the view still.
    pub fn load_older(&mut self, cx: &mut Context<Self>) {
        // `sync` (through the store's notify) splices the new rows in at
        // the top; the list keeps its anchor on the same row.
        self.store.update(cx, |s, cx| {
            s.load_older(cx);
        });
    }

    /// Every rich content view the drawn answers hold (the E2E pass opens
    /// them).
    pub fn embed_views(&self, cx: &App) -> Vec<Entity<super::embed::EmbedView>> {
        self.rows.values().flat_map(|r| r.embeds(cx)).collect()
    }

    /// Whether the citation preview is open.
    pub fn citation_open(&self) -> bool {
        self.citation.is_some()
    }

    /// A citation pill or link was clicked.
    pub fn show_citation(
        &mut self,
        key: String,
        numbers: Vec<usize>,
        position: Point<Pixels>,
        _: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.citation_hover = None;
        self.citation = Some(Citation {
            key,
            numbers,
            position,
            by_hover: false,
        });
        cx.notify();
    }

    /// The pointer came onto (`hovered`) or left a citation pill: the
    /// preview opens after a moment's hover, and one opened that way
    /// closes a moment after the pointer has left it and the pill.
    pub fn hover_citation(
        &mut self,
        key: String,
        numbers: Vec<usize>,
        position: Point<Pixels>,
        hovered: bool,
        cx: &mut Context<Self>,
    ) {
        if hovered {
            if self
                .citation
                .as_ref()
                .is_some_and(|c| c.key == key && c.numbers == numbers)
            {
                self.citation_hover = None;
                return;
            }
            self.citation_hover = Some(cx.spawn(async move |this, cx| {
                cx.background_executor()
                    .timer(std::time::Duration::from_millis(CITATION_HOVER_MS))
                    .await;
                let _ = this.update(cx, |t, cx| {
                    t.citation = Some(Citation {
                        key,
                        numbers,
                        position,
                        by_hover: true,
                    });
                    cx.notify();
                });
            }));
        } else {
            self.citation_hover = None;
            self.close_hovered_citation(cx);
        }
    }

    /// Closes a preview opened by hover, a moment from now, unless the
    /// pointer is on it by then.
    fn close_hovered_citation(&mut self, cx: &mut Context<Self>) {
        if !self.citation.as_ref().is_some_and(|c| c.by_hover) {
            return;
        }
        self.citation_hover = Some(cx.spawn(async move |this, cx| {
            cx.background_executor()
                .timer(std::time::Duration::from_millis(CITATION_LEAVE_MS))
                .await;
            let _ = this.update(cx, |t, cx| {
                if !t.citation_preview_hovered && t.citation.as_ref().is_some_and(|c| c.by_hover) {
                    t.close_citation(cx);
                }
            });
        }));
    }

    /// What a citation pill reads: its first source's site (or title, with
    /// Settings › Chat › Show Citation Titles), with "+N" for more, and
    /// whether it sits on a filled badge (Citation Background).
    pub fn citation_label(
        &self,
        key: &str,
        numbers: &[usize],
        cx: &App,
    ) -> Option<(String, Option<usize>, bool)> {
        let (show_titles, background) = cx
            .try_global::<crate::AppState>()
            .map(|s| {
                let settings = s.stores.app_settings.read(cx).settings();
                (settings.citation_show_titles, settings.citation_background)
            })
            .unwrap_or((false, true));
        // The row's own view, by its key: a pill draws every frame, so no
        // walk over the transcript and no copy of the answer.
        let sources = match self.rows.get(key) {
            Some(row) => row.sources(cx)?,
            // A regenerate's answer keeps the row of the one it replaced.
            None => {
                let store = self.store.read(cx);
                store.item(store.row_for_key(key)?)?.sources
            }
        };
        let (label, more) = super::sources::inline_label(&sources, numbers, show_titles)?;
        Some((label, more, background))
    }

    pub fn close_citation(&mut self, cx: &mut Context<Self>) {
        if let Some(citation) = self.citation.take() {
            self.leaving_citation = Some(citation);
            cx.notify();
        }
    }

    fn render_row(&mut self, ix: usize, cx: &mut App) -> AnyElement {
        let store = self.store.read(cx);
        let Some(row) = store.rows().get(ix).copied() else {
            return div().into_any_element();
        };
        let Some(item) = store.item(row) else {
            return div().into_any_element();
        };
        // The row's key, not its message's id: a regenerate's answer is the
        // same row (and view) from the regenerate to the stored copy.
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
        self.drawn.insert(key);
        // Each kind keeps its own room (rows::rhythm): a question close over
        // its answer, a constant gap between turns.
        let (top, bottom) = view.padding();
        div()
            .w_full()
            .flex()
            .justify_center()
            .px(px(32.))
            .pt(px(top))
            .pb(px(bottom))
            .child(div().w_full().max_w(px(CHAT_COLUMN)).child(view.element()))
            .into_any_element()
    }

    /// Drops cached rows that have not been drawn lately.
    fn prune(&mut self) {
        if self.rows.len() > ROW_CACHE {
            let drawn = std::mem::take(&mut self.drawn);
            // Find holds the text states of the rows it searched: those rows
            // stay while it is open, or a match would light a state no row
            // draws.
            let found: std::collections::HashSet<_> = self
                .find
                .iter()
                .flat_map(|f| f.searched_rows().cloned())
                .collect();
            self.rows
                .retain(|k, _| drawn.contains(k) || found.contains(k));
        }
    }

    /// The sources a citation names, from the pill: fades in over 120 ms,
    /// dropping 4 pt from it, and out over 100 ms (taking nothing while it
    /// goes); under Reduce Motion it only crossfades.
    fn citation_popover(&self, window: &mut Window, cx: &mut Context<Self>) -> Option<AnyElement> {
        let open = self.citation.is_some();
        let shown = motion::appear(
            "citation-motion",
            open,
            specs::POPOVER_IN,
            specs::POPOVER_OUT,
            window,
            cx,
        );
        if !shown.visible {
            return None;
        }
        let citation = self.citation.as_ref().or(self.leaving_citation.as_ref())?;
        let store = self.store.read(cx);
        let row = store.row_for_key(&citation.key)?;
        let sources: Vec<(usize, ChatSourceDto)> = {
            let item = store.item(row)?;
            citation
                .numbers
                .iter()
                .filter_map(|n| item.sources.get(n - 1).map(|s| (*n, s.clone())))
                .collect()
        };
        if sources.is_empty() {
            return None;
        }
        let t = cx.conduit().clone();
        let l10n = cx.l10n().clone();
        let r = t.roles;
        let m = t.metrics;
        let weak = cx.entity().downgrade();
        let card = div()
            .id("citation-popover")
            .role(Role::Dialog)
            .aria_label(SharedString::from(l10n.desktop_sources()))
            .occlude()
            .w(px(POPOVER_WIDTH))
            .p(px(6.))
            .flex()
            .flex_col()
            .gap(px(2.))
            .rounded(t.overlay_radius())
            .border_1()
            .border_color(r.border_strong)
            .bg(r.overlay)
            .shadow(conduit_components::views::kit::overlay_shadow(&t))
            .on_hover(cx.listener(|this, hovered: &bool, _, cx| {
                this.citation_preview_hovered = *hovered;
                if *hovered {
                    this.citation_hover = None;
                } else {
                    this.close_hovered_citation(cx);
                }
            }))
            .on_mouse_down_out(move |_, _, cx| {
                let _ = weak.update(cx, |t, cx| t.close_citation(cx));
            })
            .children(sources.into_iter().map(|(n, s)| {
                // The phone's preview: the source's name, its site, a
                // short excerpt; here also its address, and Open.
                let (title, site, excerpt) = super::sources::preview(&s);
                let url = s.url.clone();
                let close = cx.entity().downgrade();
                let open = url.clone().map(|u| {
                    let close = close.clone();
                    conduit_components::views::kit::Button::new(
                        ElementId::Name(format!("citation-open-{n}").into()),
                        l10n.citation_preview_open(),
                    )
                    .on_click(std::rc::Rc::new(move |_, _, cx| {
                        super::markdown::open_web_link(&u, cx);
                        let _ = close.update(cx, |t, cx| t.close_citation(cx));
                    }))
                });
                div()
                    .id(ElementId::Name(format!("citation-source-{n}").into()))
                    .role(Role::Group)
                    .aria_label(SharedString::from(
                        l10n.desktop_source_label(n as i64, &title),
                    ))
                    .px(px(8.))
                    .py(px(6.))
                    .flex()
                    .flex_col()
                    .gap(px(3.))
                    .rounded(px(7.))
                    .child(
                        div()
                            .flex()
                            .items_center()
                            .gap(px(6.))
                            .child(
                                div()
                                    .flex_none()
                                    .text_size(px(m.caption))
                                    .font_weight(FontWeight::SEMIBOLD)
                                    .text_color(r.text_subtle)
                                    .child(SharedString::from(n.to_string())),
                            )
                            .child(
                                div()
                                    .flex_1()
                                    .min_w_0()
                                    .truncate()
                                    .text_size(px(m.control))
                                    .font_weight(FontWeight::MEDIUM)
                                    .text_color(r.text)
                                    .child(SharedString::from(title)),
                            ),
                    )
                    .when_some(site, |d, site| {
                        d.child(
                            div()
                                .text_size(px(m.caption))
                                .text_color(r.text_subtle)
                                .child(SharedString::from(site)),
                        )
                    })
                    .when_some(excerpt, |d, excerpt| {
                        d.child(
                            div()
                                .text_size(px(m.small))
                                .line_height(gpui_kit::relative(1.4))
                                .text_color(r.text_subtle)
                                .child(SharedString::from(excerpt)),
                        )
                    })
                    .when_some(url.clone(), |d, url| {
                        d.child(
                            div()
                                .id(ElementId::Name(format!("citation-url-{n}").into()))
                                .truncate()
                                .text_size(px(m.caption))
                                .text_color(r.text_faint)
                                .child(SharedString::from(url)),
                        )
                    })
                    .when_some(open, |d, open| {
                        d.child(div().pt(px(2.)).flex().justify_end().child(open))
                    })
            }));
        // Hung from the pill by a tail, below it (above when the column
        // has no room under it), and kept inside the chat column.
        let count = store.item(row).map_or(1, |i| i.sources.len().max(1)).min(4);
        let b = self.bounds.get();
        let column = (b.size.width - px(64.))
            .min(px(CHAT_COLUMN))
            .max(px(POPOVER_WIDTH));
        let column_left = b.origin.x + (b.size.width - column) / 2.;
        let at = citation.position;
        let left = (at.x - px(32.))
            .max(column_left)
            .min(column_left + column - px(POPOVER_WIDTH));
        let tail_x = (at.x - left).clamp(px(18.), px(POPOVER_WIDTH - 18.));
        let room_below = b.bottom() - at.y;
        let below = room_below > px(40. + 70. * count as f32) || b.size.height == px(0.);
        let tail = popover_tail(tail_x, below, r.overlay, r.border_strong);
        // Eases in from the pill's side, and fades out after it closes.
        let card = div()
            .relative()
            .top(px(shown.offset(if below { -4. } else { 4. })))
            .opacity(shown.opacity)
            .when(below, |d| d.pt(px(TAIL_HEIGHT)))
            .when(!below, |d| d.pb(px(TAIL_HEIGHT)))
            .child(card)
            .child(tail)
            .when(!open, |d| {
                d.child(div().id("citation-leaving").absolute().inset_0().occlude())
            });
        Some(
            deferred(
                anchored()
                    .anchor(if below {
                        Anchor::TopLeft
                    } else {
                        Anchor::BottomLeft
                    })
                    .position(point(
                        left,
                        if below {
                            at.y + px(10.)
                        } else {
                            at.y - px(10.)
                        },
                    ))
                    .snap_to_window_with_margin(px(8.))
                    .child(card),
            )
            .with_priority(2)
            .into_any_element(),
        )
    }
}

impl Transcript {
    /// A row's Usage or Versions popover, hung from the button that opened
    /// it as the citation popover is (and with its motion).
    fn row_popover_card(&self, window: &mut Window, cx: &mut Context<Self>) -> Option<AnyElement> {
        let open = self.row_popover.is_some();
        let shown = motion::appear(
            "row-popover-motion",
            open,
            specs::POPOVER_IN,
            specs::POPOVER_OUT,
            window,
            cx,
        );
        if !shown.visible {
            return None;
        }
        let p = self
            .row_popover
            .as_ref()
            .or(self.leaving_row_popover.as_ref())?
            .clone();
        let store = self.store.read(cx);
        let row = store.row_for_key(&p.key)?;
        let item = store.item(row)?;
        let t = cx.conduit().clone();
        let l10n = cx.l10n().clone();
        let r = t.roles;
        let weak = cx.entity().downgrade();
        let (body, label, lines) = match p.kind {
            RowPopoverKind::Usage => {
                let usage = item.usage.clone()?;
                let n = super::popovers::usage_lines(&usage, &l10n).len();
                (
                    super::popovers::usage_card(&p.key, &usage, cx),
                    l10n.usage_info_title(),
                    n + 1,
                )
            }
            RowPopoverKind::Versions => {
                let shown_id = store.messages().iter().find(|m| m.id == p.key).map(|_| {
                    item.version
                        .and_then(|(at, _)| item.siblings.get(at - 1).cloned())
                        .unwrap_or(p.key.clone())
                })?;
                let entries = super::popovers::version_entries(
                    &item.siblings,
                    &shown_id,
                    |id| store.version_text(id),
                    &l10n,
                );
                let n = entries.len() * 2 + 2;
                let pick_store = self.store.downgrade();
                let pick_key = p.key.clone();
                let close = weak.clone();
                let on_pick: super::popovers::PickVersion = std::rc::Rc::new(move |id, _, cx| {
                    let _ = pick_store.update(cx, |s, cx| s.choose_version(&pick_key, &id, cx));
                    let _ = close.update(cx, |t, cx| t.close_row_popover(cx));
                });
                let branches = self
                    .on_branches
                    .clone()
                    .filter(|_| store.abilities().branch);
                let close = weak.clone();
                let on_branches = branches.map(|f| {
                    std::rc::Rc::new(move |window: &mut Window, cx: &mut App| {
                        let _ = close.update(cx, |t, cx| t.close_row_popover(cx));
                        f(window, cx)
                    }) as super::popovers::ShowBranches
                });
                (
                    super::popovers::versions_card(&p.key, entries, on_pick, on_branches, cx),
                    l10n.chat_branch_sheet_title(),
                    n,
                )
            }
        };
        let close = weak.clone();
        let card = div()
            .id("row-popover")
            .role(Role::Dialog)
            .aria_label(SharedString::from(label))
            .occlude()
            .w(px(ROW_POPOVER_WIDTH))
            .p(px(6.))
            .rounded(t.overlay_radius())
            .border_1()
            .border_color(r.border_strong)
            .bg(r.overlay)
            .shadow(conduit_components::views::kit::overlay_shadow(&t))
            .on_mouse_down_out(move |_, _, cx| {
                let _ = close.update(cx, |t, cx| t.close_row_popover(cx));
            })
            .on_key_down({
                let close = weak.clone();
                move |e: &gpui_kit::KeyDownEvent, _, cx| {
                    if e.keystroke.key == "escape" {
                        let _ = close.update(cx, |t, cx| t.close_row_popover(cx));
                        cx.stop_propagation();
                    }
                }
            })
            .child(body);
        Some(self.hang(
            "row-popover",
            card,
            ROW_POPOVER_WIDTH,
            24. * lines as f32,
            p.position,
            open,
            shown,
            cx,
        ))
    }

    /// Hangs `card` (`width` wide, about `height` tall) from `at` by a tail:
    /// below it, or above when the transcript has no room under it, inside
    /// the chat column. Fades and drops in with `shown`.
    #[allow(clippy::too_many_arguments)]
    fn hang(
        &self,
        id: &str,
        card: gpui_kit::Stateful<gpui_kit::Div>,
        width: f32,
        height: f32,
        at: Point<Pixels>,
        open: bool,
        shown: motion::Appear,
        cx: &App,
    ) -> AnyElement {
        let t = cx.conduit().clone();
        let r = t.roles;
        let b = self.bounds.get();
        let column = (b.size.width - px(64.)).min(px(CHAT_COLUMN)).max(px(width));
        let column_left = b.origin.x + (b.size.width - column) / 2.;
        let left = (at.x - px(32.))
            .max(column_left)
            .min(column_left + column - px(width));
        let tail_x = (at.x - left).clamp(px(18.), px(width - 18.));
        let room_below = b.bottom() - at.y;
        let below = room_below > px(40. + height) || b.size.height == px(0.);
        let tail = popover_tail(tail_x, below, r.overlay, r.border_strong);
        let card = div()
            .relative()
            .top(px(shown.offset(if below { -4. } else { 4. })))
            .opacity(shown.opacity)
            .when(below, |d| d.pt(px(TAIL_HEIGHT)))
            .when(!below, |d| d.pb(px(TAIL_HEIGHT)))
            .child(card)
            .child(tail)
            .when(!open, |d| {
                d.child(
                    div()
                        .id(ElementId::Name(format!("{id}-leaving").into()))
                        .absolute()
                        .inset_0()
                        .occlude(),
                )
            });
        deferred(
            anchored()
                .anchor(if below {
                    Anchor::TopLeft
                } else {
                    Anchor::BottomLeft
                })
                .position(point(
                    left,
                    if below {
                        at.y + px(10.)
                    } else {
                        at.y - px(10.)
                    },
                ))
                .snap_to_window_with_margin(px(8.))
                .child(card),
        )
        .with_priority(2)
        .into_any_element()
    }
}

/// The Usage and Versions popovers' width.
const ROW_POPOVER_WIDTH: f32 = 300.;

impl Transcript {
    /// Tab moved onto a row's buttons. The control brings itself into view,
    /// 24 pt clear of the edges, as it is drawn (the window's focus reveal,
    /// [`conduit_components::window::FOCUS_REVEAL_INSET`]); following the
    /// end would pull the view straight back, so it stops (and starts again
    /// once the view is back at the end). A row above the top that has not
    /// been laid out is scrolled to first.
    fn reveal_focused(&mut self, window: &Window, cx: &App) {
        let focused = window.focused(cx);
        if focused == self.last_focus {
            return;
        }
        self.last_focus = focused.clone();
        if focused.is_none() || !self.focus.contains_focused(window, cx) {
            return;
        }
        let Some(key) = self
            .rows
            .iter()
            .find(|(_, row)| row.has_focus(window, cx))
            .map(|(k, _)| k.clone())
        else {
            return;
        };
        let Some(ix) = self.keys.iter().position(|k| *k == key) else {
            return;
        };
        self.chase = None;
        self.list.pause_following_tail();
        if self.list.bounds_for_item(ix).is_none() && ix < self.list.logical_scroll_top().item_ix {
            self.list.scroll_to(gpui_kit::ListOffset {
                item_ix: ix,
                offset_in_item: px(0.),
            });
        }
    }
}

impl Transcript {
    /// Where focus is (see [`Spot`]); `below` is the composer dock's scope.
    pub fn spot(&self, below: &FocusHandle, window: &Window, cx: &App) -> Spot {
        if below.contains_focused(window, cx) {
            return Spot::Below;
        }
        if self.focus.contains_focused(window, cx)
            && let Some(ix) = self.keys.iter().position(|k| {
                self.rows
                    .get(k)
                    .is_some_and(|row| row.contains_focus(window, cx))
            })
        {
            return Spot::Row(ix);
        }
        Spot::Elsewhere
    }

    /// Whether row `ix` was drawn last frame (so its controls were Tab
    /// stops): GPUI's list draws only the rows on screen.
    fn on_screen(&self, ix: usize) -> bool {
        self.list.item_is_above_viewport(ix) == Some(false)
            && self.list.item_is_below_viewport(ix) == Some(false)
    }

    /// Whether row `ix` can have a control to stop on (the answer being
    /// written, or the waiting line, has none yet).
    fn has_stops(&self, ix: usize, cx: &App) -> bool {
        let store = self.store.read(cx);
        match store.rows().get(ix) {
            Some(Row::Waiting) | None => false,
            Some(row) => store.item(*row).is_some_and(|i| !i.streaming),
        }
    }

    /// Tab (or Shift-Tab, `back`) from a row or, backward, from the
    /// composer: the focus order of the messages, not only of the rows on
    /// screen. GPUI's order holds only what was drawn, so when a move passed
    /// over rows off screen (the last answer and its suggestions below the
    /// view, as Shift-Tab from the composer meets them) the nearest such row
    /// is scrolled in (its end for Shift-Tab, its start for Tab) and, once
    /// it is drawn, focus lands on its last control (its first for Tab). The
    /// control focused brings itself into view (the window's focus reveal;
    /// focus is let go meanwhile, so nothing reveals the control the move
    /// first reached). Returns false when focus is not somewhere this
    /// handles, or Tab reaches only fields (Full Keyboard Access off): the
    /// caller lets the window's own Tab have it.
    pub fn tab(
        &mut self,
        back: bool,
        below: FocusHandle,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> bool {
        if !conduit_components::views::focus::full_keyboard_access(cx) {
            return false;
        }
        let from = self.spot(&below, window, cx);
        if !matches!(from, Spot::Row(_)) && !(back && from == Spot::Below) {
            return false;
        }
        if back {
            window.focus_prev(cx);
        } else {
            window.focus_next(cx);
        }
        let to = self.spot(&below, window, cx);
        let mut over = passed_over(back, from, to, self.keys.len());
        let missed = if back {
            over.rev()
                .find(|ix| !self.on_screen(*ix) && self.has_stops(*ix, cx))
        } else {
            over.find(|ix| !self.on_screen(*ix) && self.has_stops(*ix, cx))
        };
        let Some(target) = missed else {
            return true;
        };
        window.blur(cx);
        self.chase = None;
        self.list.set_follow_mode(FollowMode::Normal);
        let above = self.list.item_is_above_viewport(target) != Some(false);
        if back && !above {
            // Its end (where its last controls are) at the bottom.
            self.list.scroll_to_reveal_item(target);
        } else if back {
            // Its end at the bottom of the view, as far as it is known.
            let viewport = f32::from(self.list.viewport_bounds().size.height);
            let height = self
                .list
                .bounds_for_item(target)
                .map_or(0., |b| f32::from(b.size.height));
            self.list.scroll_to(gpui_kit::ListOffset {
                item_ix: target,
                offset_in_item: px((height - viewport + BOTTOM_INSET).max(0.)),
            });
        } else {
            // Its start at the top.
            self.list.scroll_to(gpui_kit::ListOffset {
                item_ix: target,
                offset_in_item: px(0.),
            });
        }
        cx.notify();
        // Drawn in the next frame; its stops are in the order the frame
        // after that one starts with.
        cx.on_next_frame(window, move |_, window, cx| {
            cx.on_next_frame(window, move |this, window, cx| {
                this.land(back, target, window, cx);
            });
        });
        true
    }

    /// Focus on row `target`'s first control (`back`: its last), once the
    /// row is drawn: from the row's own scope (in the order before its
    /// controls), forward through them.
    fn land(&mut self, back: bool, target: usize, window: &mut Window, cx: &mut Context<Self>) {
        let Some(root) = self
            .keys
            .get(target)
            .and_then(|k| self.rows.get(k))
            .and_then(|row| row.row_focus(cx))
        else {
            return;
        };
        let in_target = |window: &Window, cx: &App| root.contains_focused(window, cx);
        window.focus(&root, cx);
        window.focus_next(cx);
        if !in_target(window, cx) {
            // Nothing to stop on after all: focus stays on the row.
            window.focus(&root, cx);
            return;
        }
        if back {
            let mut last = window.focused(cx);
            for _ in 0..64 {
                window.focus_next(cx);
                if !in_target(window, cx) {
                    break;
                }
                last = window.focused(cx);
            }
            if let Some(last) = last {
                window.focus(&last, cx);
            }
        }
    }
}

impl Render for Transcript {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        cx.set_global(CitationTarget(cx.entity().downgrade()));
        self.prune();
        self.refresh_find(cx);
        self.refresh_reading(cx);
        self.step_chase(window, cx);
        self.reveal_focused(window, cx);
        let t = cx.conduit().clone();
        let l10n = cx.l10n().clone();
        let r = t.roles;
        let hidden = self.store.read(cx).hidden();
        let content = r.content;
        let older = (hidden > 0 && self.at_top).then(|| {
            div()
                .absolute()
                .top(px(8.))
                .left_0()
                .right_0()
                .flex()
                .justify_center()
                .child(
                    conduit_components::views::kit::Button::new(
                        "load-older",
                        l10n.desktop_load_older_messages(),
                    )
                    .on_click(std::rc::Rc::new({
                        let weak = cx.entity().downgrade();
                        move |_, _, cx| {
                            let _ = weak.update(cx, |t, cx| t.load_older(cx));
                        }
                    })),
                )
        });
        let popover = self.citation_popover(window, cx);
        let row_popover = self.row_popover_card(window, cx);
        let bounds = self.bounds.clone();
        div()
            .id("transcript")
            .role(Role::Log)
            .aria_label(SharedString::from(l10n.desktop_messages()))
            .track_focus(&self.focus)
            // A double-click on a word of the answer being read aloud moves
            // the reading to its sentence (the text has selected the word
            // by the time the button comes up).
            .on_mouse_up(
                gpui_kit::MouseButton::Left,
                cx.listener(|this, e: &gpui_kit::MouseUpEvent, _, cx| {
                    if e.click_count != 2 || this.reader.is_none() {
                        return;
                    }
                    let Some(sentence) = this.reading_sentence_at_selection(cx) else {
                        return;
                    };
                    if let Some(speech) = cx
                        .try_global::<crate::AppState>()
                        .map(|s| s.stores.speech.clone())
                    {
                        speech.update(cx, |s, cx| s.seek_sentence(sentence, cx));
                    }
                }),
            )
            .relative()
            .flex_1()
            .min_h_0()
            .w_full()
            .child(
                list(
                    self.list.clone(),
                    cx.processor(|this, ix, _, cx| this.render_row(ix, cx)),
                )
                .size_full()
                .pt(px(TOP_INSET))
                .pb(px(BOTTOM_INSET)),
            )
            // Earlier messages slide under the toolbar through a fade.
            .when(self.painted_fades, |d| {
                d.child(
                    div()
                        .absolute()
                        .top_0()
                        .left_0()
                        .right_0()
                        .h(px(TOP_FADE))
                        .bg(gpui_kit::linear_gradient(
                            180.,
                            gpui_kit::linear_color_stop(content, 0.),
                            gpui_kit::linear_color_stop(
                                conduit_components::theme::with_alpha(content, 0.),
                                1.,
                            ),
                        )),
                )
                // ...and later ones under the composer the same way, so the
                // column's two edges match.
                .child(
                    div()
                        .absolute()
                        .bottom_0()
                        .left_0()
                        .right_0()
                        .h(px(TOP_FADE))
                        .bg(gpui_kit::linear_gradient(
                            0.,
                            gpui_kit::linear_color_stop(content, 0.),
                            gpui_kit::linear_color_stop(
                                conduit_components::theme::with_alpha(content, 0.),
                                1.,
                            ),
                        )),
                )
            })
            .child(
                canvas(move |b, _, _| bounds.set(b), |_, _, _, _| {})
                    .absolute()
                    .size_full(),
            )
            .children(older)
            .children(popover)
            .children(row_popover)
    }
}

#[cfg(test)]
mod tests {
    use std::rc::Rc;

    use conduit_components::theme::{ConduitTheme, DesignPrefs, install};
    use conduit_protocol::{
        ChatDetail, ChatMessageDto, ChatResult, ChatSummary, Event, MessageBlockDto,
        MessageBlockKind, TurnBlocks, methods,
    };
    use gpui_kit::{TestAppContext, VisualTestContext, size};

    use super::*;
    use crate::l10n::L10n;
    use crate::stores::chat::{Subscribe, empty_block};
    use crate::stores::rpc::fake::FakeDaemon;
    use crate::views::chat::rows::{self, RowSink};

    const VIEWPORT: f32 = 400.;

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
            streaming: false,
            error_code: None,
            versions: vec![],
            sources: vec![],
            usage: None,
            rating: None,
            files: vec![],
            blocks: vec![],
            queued: None,
        }
    }

    /// A question and its empty answer, open in a transcript.
    fn open(
        cx: &mut TestAppContext,
    ) -> (
        Entity<ChatStore>,
        Entity<Transcript>,
        &mut VisualTestContext,
    ) {
        let (store, transcript, cx, _) = open_with(
            vec![
                message("u1", "user", "How far is the moon?"),
                message("a1", "assistant", ""),
            ],
            cx,
        );
        (store, transcript, cx)
    }

    /// `messages` open in a transcript, with the fake daemon behind it.
    fn open_with(
        messages: Vec<ChatMessageDto>,
        cx: &mut TestAppContext,
    ) -> (
        Entity<ChatStore>,
        Entity<Transcript>,
        &mut VisualTestContext,
        FakeDaemon,
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
        (store, transcript, cx.add_empty_window(), daemon)
    }

    /// A finished answer of `lines` paragraphs, optionally with suggestions.
    fn answer(id: &str, lines: usize, follow_ups: &[&str]) -> ChatMessageDto {
        let text = (1..=lines)
            .map(|i| format!("Line {i} of answer {id}."))
            .collect::<Vec<_>>()
            .join("\n\n");
        let mut blocks = vec![MessageBlockDto {
            markdown: Some(text.clone()),
            ..empty_block(MessageBlockKind::Text)
        }];
        if !follow_ups.is_empty() {
            blocks.push(MessageBlockDto {
                follow_ups: Some(follow_ups.iter().map(|f| f.to_string()).collect()),
                ..empty_block(MessageBlockKind::FollowUps)
            });
        }
        ChatMessageDto {
            blocks,
            ..message(id, "assistant", &text)
        }
    }

    /// One frame `ms` later.
    fn frame(transcript: &Entity<Transcript>, ms: u64, cx: &mut VisualTestContext) {
        cx.executor()
            .advance_clock(std::time::Duration::from_millis(ms));
        draw(transcript, cx);
    }

    /// Row `ix`'s painted height.
    fn height(list: &ListState, ix: usize) -> f32 {
        let (top, bottom) = painted(list, ix).expect("the row is on screen");
        bottom - top
    }

    #[gpui_kit::test]
    fn a_regenerate_keeps_the_old_answer_in_place_then_crossfades_into_the_new(
        cx: &mut TestAppContext,
    ) {
        let (store, transcript, cx, daemon) = open_with(
            vec![
                message("u1", "user", "How far is the moon?"),
                answer("a1", 4, &["How long is a day there?", "Show it as code"]),
            ],
            cx,
        );
        daemon.returns::<methods::TurnsRegenerate>(conduit_protocol::SendTurnAccepted {
            chat_id: "c1".into(),
            user_message_id: "u1".into(),
            assistant_message_id: "a2".into(),
        });
        let list = transcript.read_with(cx, |t, _| t.list_state().clone());
        for _ in 0..3 {
            frame(&transcript, 16, cx);
        }
        let before = height(&list, 1);
        let view = |cx: &mut VisualTestContext, key: &str| {
            transcript.read_with(cx, |t, _| match t.rows.get(key) {
                Some(RowView::Assistant(e)) => Some(e.entity_id()),
                _ => None,
            })
        };
        let row = view(cx, "a1").expect("the answer's view");

        // Regenerate: dimmed, the waiting line where the actions were, the
        // suggestions fading where they stand. Nothing moves, through the
        // server taking the turn under a new id.
        store.update(cx, |s, cx| s.regenerate("a1", None, cx));
        cx.run_until_parked();
        for _ in 0..20 {
            frame(&transcript, 16, cx);
            let h = height(&list, 1);
            assert!(
                (h - before).abs() < 0.5,
                "the old answer kept its height: {h} vs {before}"
            );
        }
        assert_eq!(
            view(cx, "a1"),
            Some(row),
            "the same view carries on, the new answer keeping the row's key"
        );

        // The first words: the old answer crossfades into them over 150 ms,
        // the height following from the old one's, never in one frame.
        let blocks = vec![MessageBlockDto {
            markdown: Some("The new answer.".into()),
            ..empty_block(MessageBlockKind::Text)
        }];
        store.update(cx, |s, cx| {
            s.on_event(
                &Event::TurnBlocks(TurnBlocks {
                    chat_id: "c1".into(),
                    message_id: "a2".into(),
                    blocks,
                    tasks: None,
                }),
                cx,
            )
        });
        draw(&transcript, cx);
        let mut heights = vec![height(&list, 1)];
        for _ in 0..14 {
            frame(&transcript, 16, cx);
            heights.push(height(&list, 1));
        }
        let end = *heights.last().unwrap();
        assert!(
            end < before * 0.6,
            "it ends at the new answer's height: {heights:?}"
        );
        assert!(
            heights[0] > before - 2.,
            "no collapse the frame it starts: {heights:?}"
        );
        let steps: Vec<f32> = heights.windows(2).map(|w| w[0] - w[1]).collect();
        let largest = steps.iter().copied().fold(0., f32::max);
        assert!(
            largest < (before - end) * 0.4,
            "eased, not cut: {heights:?}"
        );
        let landed = heights.iter().position(|h| (h - end).abs() < 0.5).unwrap();
        assert!(
            (7..=11).contains(&landed),
            "about 150 ms: {landed} frames, {heights:?}"
        );
    }

    /// A regenerate from start to stored copy, its events arriving before
    /// `turns.regenerate` replies and a copy saved mid-regenerate listing
    /// the old answer on its own: one row, one view, and nothing above it
    /// moves (the question's y, the scroll offset), frame by frame.
    #[gpui_kit::test]
    fn a_regenerate_never_moves_the_rows_above_it_through_the_end_of_the_stream(
        cx: &mut TestAppContext,
    ) {
        // A short chat (it starts at the top), as the capture's.
        let (store, transcript, cx, daemon) = open_with(
            vec![
                message("u1", "user", "How far is the moon?"),
                answer("a1", 2, &["How long is a day there?"]),
            ],
            cx,
        );
        daemon.returns::<methods::TurnsRegenerate>(conduit_protocol::SendTurnAccepted {
            chat_id: "c1".into(),
            user_message_id: "u1".into(),
            assistant_message_id: "a2".into(),
        });
        let list = transcript.read_with(cx, |t, _| t.list_state().clone());
        for _ in 0..3 {
            frame(&transcript, 16, cx);
        }
        let (_, end) = painted(&list, 1).expect("the answer is on screen");
        assert!(
            end < VIEWPORT - BOTTOM_INSET - 60.,
            "short, with room for the new answer: {end}"
        );
        let view = |cx: &mut VisualTestContext| {
            transcript.read_with(cx, |t, _| {
                assert_eq!(t.keys, vec!["u1".to_string(), "a1".to_string()]);
                match t.rows.get("a1") {
                    Some(RowView::Assistant(e)) => e.entity_id(),
                    _ => panic!("the answer's view"),
                }
            })
        };
        let row = view(cx);
        let (top, _) = painted(&list, 0).expect("the question is on screen");
        let offset = list.logical_scroll_top();
        let mut frames = 0;
        let mut check = |cx: &mut VisualTestContext| {
            frame(&transcript, 16, cx);
            frames += 1;
            let (y, _) = painted(&list, 0).expect("the question stays on screen");
            assert!(
                (y - top).abs() < 0.5,
                "frame {frames}: the question moved {}",
                y - top
            );
            assert_eq!(
                list.logical_scroll_top(),
                offset,
                "frame {frames}: scrolled"
            );
            assert_eq!(view(cx), row, "frame {frames}: a new view");
        };

        // The first events come before the reply is read.
        let snapshot = |n: usize| {
            vec![MessageBlockDto {
                markdown: Some(
                    (1..=n)
                        .map(|i| format!("New line {i}."))
                        .collect::<Vec<_>>()
                        .join("\n\n"),
                ),
                ..empty_block(MessageBlockKind::Text)
            }]
        };
        store.update(cx, |s, cx| {
            s.regenerate("a1", None, cx);
            s.on_event(
                &Event::TurnStarted(conduit_protocol::TurnStarted {
                    companion_ids: vec![],
                    chat_id: "c1".into(),
                    message_id: "a2".into(),
                    model: "m".into(),
                }),
                cx,
            );
        });
        check(cx);
        for n in 1..=3 {
            store.update(cx, |s, cx| {
                s.on_event(
                    &Event::TurnBlocks(TurnBlocks {
                        chat_id: "c1".into(),
                        message_id: "a2".into(),
                        blocks: snapshot(n),
                        tasks: None,
                    }),
                    cx,
                )
            });
            cx.run_until_parked();
            for _ in 0..6 {
                check(cx);
            }
        }

        // The end of the stream, then a copy saved mid-regenerate (the old
        // answer emptied, on its own, ahead of the question), then the
        // settled copy with the suggestions.
        let mut new = ChatMessageDto {
            blocks: snapshot(3),
            ..message("a2", "assistant", "New line 1.")
        };
        new.versions = vec![conduit_protocol::ChatMessageVersionDto {
            slot: None,
            merged: None,
            streaming: false,
            error_code: None,
            id: "a1".into(),
            content: "old".into(),
            timestamp_ms: 1,
            model: Some("m".into()),
            sources: vec![],
            usage: None,
            blocks: vec![],
        }];
        let detail = |messages: Vec<ChatMessageDto>| ChatResult {
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
        };
        daemon.returns::<methods::ChatsGet>(detail(vec![
            message("a1", "assistant", ""),
            message("u1", "user", "How far is the moon?"),
            new.clone(),
        ]));
        store.update(cx, |s, cx| {
            s.on_event(
                &Event::TurnCompleted(conduit_protocol::TurnCompleted {
                    chat_id: "c1".into(),
                    message_id: "a2".into(),
                    text: "New line 1.".into(),
                    reasoning: None,
                    usage: None,
                }),
                cx,
            )
        });
        cx.run_until_parked();
        for _ in 0..10 {
            check(cx);
        }
        new.blocks.push(MessageBlockDto {
            follow_ups: Some(vec!["Why?".into()]),
            ..empty_block(MessageBlockKind::FollowUps)
        });
        daemon.returns::<methods::ChatsGet>(detail(vec![
            message("u1", "user", "How far is the moon?"),
            new,
        ]));
        store.update(cx, |s, cx| s.fetch(cx));
        cx.run_until_parked();
        for _ in 0..40 {
            check(cx);
        }
        store.read_with(cx, |s, _| assert!(s.live.is_none(), "settled"));
    }

    /// The end of an answer: its last words, then its actions and its
    /// suggestions together, the suggestions at their whole height in one
    /// frame (fading in), never uncovered a row at a time.
    #[gpui_kit::test]
    fn suggestions_come_in_whole_with_the_actions(cx: &mut TestAppContext) {
        let (store, transcript, cx, daemon) = open_with(
            vec![
                message("u1", "user", "How far is the moon?"),
                message("a1", "assistant", ""),
            ],
            cx,
        );
        let list = transcript.read_with(cx, |t, _| t.list_state().clone());
        stream(&store, 2, cx);
        settle(&transcript, cx);
        let text = "Line 1 of the answer.\n\nLine 2 of the answer.";
        let finished = ChatMessageDto {
            blocks: vec![MessageBlockDto {
                markdown: Some(text.into()),
                ..empty_block(MessageBlockKind::Text)
            }],
            ..message("a1", "assistant", text)
        };
        let detail = |answer: ChatMessageDto| ChatResult {
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
                messages: vec![message("u1", "user", "How far is the moon?"), answer],
                system_prompt: None,
                tasks: vec![],
            }),
        };
        daemon.returns::<methods::ChatsGet>(detail(finished.clone()));
        store.update(cx, |s, cx| {
            s.on_event(
                &Event::TurnCompleted(conduit_protocol::TurnCompleted {
                    chat_id: "c1".into(),
                    message_id: "a1".into(),
                    text: text.into(),
                    reasoning: None,
                    usage: None,
                }),
                cx,
            )
        });
        cx.run_until_parked();
        let mut heights = vec![];
        for _ in 0..12 {
            frame(&transcript, 16, cx);
            heights.push(height(&list, 1));
        }
        // The suggestions, 300 ms after the turn.
        let mut with = finished;
        with.blocks.push(MessageBlockDto {
            follow_ups: Some(vec!["Why?".into(), "How?".into(), "When?".into()]),
            ..empty_block(MessageBlockKind::FollowUps)
        });
        daemon.returns::<methods::ChatsGet>(detail(with));
        store.update(cx, |s, cx| s.fetch(cx));
        cx.run_until_parked();
        for _ in 0..30 {
            frame(&transcript, 16, cx);
            heights.push(height(&list, 1));
        }
        let before = heights[11];
        let after = *heights.last().unwrap();
        assert!(after > before + 60., "the suggestions came: {heights:?}");
        // From the answer's height to its height with the suggestions in one
        // step: no frame in between.
        let came = heights.iter().position(|h| *h > before + 0.5).unwrap();
        assert!(
            heights[came..].iter().all(|h| (*h - after).abs() < 0.5),
            "{heights:?}"
        );
    }

    /// The transcript in a real window, `VIEWPORT` tall, drawn a full frame
    /// at a time (element state, focus handles included, carries over).
    struct Hosted(Entity<Transcript>);

    impl Render for Hosted {
        fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
            div()
                .w(px(800.))
                .h(px(VIEWPORT))
                .flex()
                .flex_col()
                .child(self.0.clone())
        }
    }

    fn real_frame(cx: &mut VisualTestContext) {
        cx.executor()
            .advance_clock(std::time::Duration::from_millis(16));
        cx.update(|window, cx| window.draw(cx).clear(cx));
        cx.run_until_parked();
    }

    #[gpui_kit::test]
    fn tab_into_an_earlier_answer_brings_its_buttons_into_view(cx: &mut TestAppContext) {
        let mut messages = vec![];
        for k in 0..4 {
            messages.push(message(&format!("u{k}"), "user", "Another question?"));
            messages.push(answer(&format!("a{k}"), 12, &[]));
        }
        let (_, transcript, _, _) = open_with(messages, cx);
        let host = transcript.clone();
        let (_, cx) = cx.add_window_view(move |_, _| Hosted(host));
        cx.update(|window, _| {
            window.set_focus_reveal_inset(Some(px(conduit_components::window::FOCUS_REVEAL_INSET)))
        });
        let list = transcript.read_with(cx, |t, _| t.list_state().clone());
        for _ in 0..4 {
            real_frame(cx);
        }
        let top = f32::from(list.viewport_bounds().top()) + TOP_INSET;
        let bottom = f32::from(list.viewport_bounds().top()) + VIEWPORT;
        // An earlier answer taller than the window, scrolled so only its
        // last few points show at the top (its buttons under the fade), as
        // Shift-Tab from the answers below meets it.
        let ix = 5;
        list.scroll_to(gpui_kit::ListOffset {
            item_ix: ix,
            offset_in_item: px(0.),
        });
        real_frame(cx);
        let tall = height(&list, ix);
        assert!(tall > VIEWPORT, "taller than the window: {tall}");
        list.scroll_to(gpui_kit::ListOffset {
            item_ix: ix,
            offset_in_item: px(tall - 12.),
        });
        real_frame(cx);
        let (_, end) = painted(&list, ix).unwrap();
        assert!(
            end < top + 24.,
            "its buttons start out of view: {end} vs {top}"
        );
        let handle = transcript
            .read_with(cx, |t, cx| {
                t.rows.get("a2").and_then(|r| r.actions_focus(cx))
            })
            .expect("the earlier answer's actions are drawn");
        // Focus a click gave (the pointer was the last input) scrolls
        // nothing: what was clicked is in view, and moving it between press
        // and release would lose the click.
        let before = list.logical_scroll_top();
        cx.simulate_mouse_move(
            gpui_kit::point(px(200.), px(200.)),
            None,
            gpui_kit::Modifiers::none(),
        );
        cx.update(|window, cx| window.focus(&handle, cx));
        real_frame(cx);
        real_frame(cx);
        assert_eq!(list.logical_scroll_top(), before, "a click never scrolls");
        cx.update(|window, cx| window.blur(cx));
        real_frame(cx);
        // Focus the keyboard moves (as Tab does) brings the control in.
        cx.simulate_keystrokes("f13");
        cx.update(|window, cx| window.focus(&handle, cx));
        real_frame(cx);
        real_frame(cx);
        // Its action row (the bottom of the answer) is in view, 24 pt clear
        // of the top: not the top of the message, which would leave the
        // buttons off screen below.
        let (_, end) = painted(&list, ix).expect("on screen");
        let actions_top = end - rows::rhythm::ACTIONS_HEIGHT;
        assert!(actions_top >= top + 24. - 0.5, "{actions_top} vs top {top}");
        assert!(end <= bottom - 24. + 0.5, "{end} vs bottom {bottom}");
        // Focus that comes back to a control already in view moves nothing.
        let offset = list.logical_scroll_top();
        cx.update(|window, cx| window.blur(cx));
        real_frame(cx);
        cx.update(|window, cx| window.focus(&handle, cx));
        real_frame(cx);
        assert_eq!(list.logical_scroll_top(), offset);
    }

    /// The transcript over a stand-in for the composer's dock: one control,
    /// after the transcript in the window's Tab order.
    struct WithDock {
        transcript: Entity<Transcript>,
        dock: FocusHandle,
        button: FocusHandle,
    }

    impl Render for WithDock {
        fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
            div()
                .w(px(800.))
                .h(px(VIEWPORT + 40.))
                .flex()
                .flex_col()
                .child(self.transcript.clone())
                .child(
                    div().track_focus(&self.dock).h(px(40.)).child(
                        div()
                            .id("dock-button")
                            .track_focus(&self.button)
                            .w(px(40.))
                            .h(px(20.)),
                    ),
                )
        }
    }

    #[test]
    fn a_tab_move_passes_over_the_rows_between_in_the_messages_order() {
        use Spot::*;
        // Back from the composer to the third of 8 rows: the 5 after it.
        assert_eq!(passed_over(true, Below, Row(2), 8), 3..8);
        // Back within a row, or within the composer: none.
        assert_eq!(passed_over(true, Row(4), Row(4), 8), 0..0);
        assert_eq!(passed_over(true, Below, Below, 8), 0..0);
        // Back from a row's first control round to the composer (nothing
        // above it drawn): every row above.
        assert_eq!(passed_over(true, Row(7), Below, 8), 0..7);
        assert_eq!(passed_over(true, Row(7), Row(7), 8), 0..0);
        // Forward past rows, and round from the last drawn to the toolbar.
        assert_eq!(passed_over(false, Row(1), Row(5), 8), 2..5);
        assert_eq!(passed_over(false, Row(5), Elsewhere, 8), 6..8);
        assert_eq!(passed_over(false, Row(5), Row(1), 8), 6..8);
        // From the toolbar: the window's own order.
        assert_eq!(passed_over(false, Elsewhere, Row(3), 8), 0..0);
    }

    #[gpui_kit::test]
    fn shift_tab_from_the_composer_reaches_the_rows_below_the_view(cx: &mut TestAppContext) {
        let mut messages = vec![];
        for k in 0..4 {
            messages.push(message(&format!("u{k}"), "user", "Another question?"));
            let follow_ups: &[&str] = if k == 3 { &["Why?", "How?"] } else { &[] };
            messages.push(answer(&format!("a{k}"), 12, follow_ups));
        }
        let (_, transcript, _, _) = open_with(messages, cx);
        let host = transcript.clone();
        let (view, cx) = cx.add_window_view(move |_, cx| WithDock {
            transcript: host,
            dock: cx.focus_handle(),
            button: cx.focus_handle().tab_stop(true),
        });
        cx.update(|window, _| {
            window.set_focus_reveal_inset(Some(px(conduit_components::window::FOCUS_REVEAL_INSET)))
        });
        let list = transcript.read_with(cx, |t, _| t.list_state().clone());
        let frames = |cx: &mut VisualTestContext, n: usize| {
            for _ in 0..n {
                real_frame(cx);
                cx.update(|window, cx| window.simulate_next_frame(cx));
            }
        };
        frames(cx, 4);
        // Read up to the third answer: the last question and the last
        // answer (with its suggestions) are below the view, not drawn.
        list.scroll_to(gpui_kit::ListOffset {
            item_ix: 5,
            offset_in_item: px(0.),
        });
        frames(cx, 2);
        assert_eq!(list.item_is_below_viewport(7), Some(true));
        assert_eq!(list.item_is_below_viewport(6), Some(true));
        let (dock, button) = view.read_with(cx, |v, _| (v.dock.clone(), v.button.clone()));
        // The keyboard in the composer.
        cx.simulate_keystrokes("f13");
        cx.update(|window, cx| window.focus(&button, cx));
        frames(cx, 1);
        let spot = |cx: &mut VisualTestContext| {
            let dock = dock.clone();
            cx.update(|window, cx| transcript.read(cx).spot(&dock, window, cx))
        };
        assert_eq!(spot(cx), Spot::Below);

        // Shift-Tab: the last answer's last control, scrolled into view.
        let step = |cx: &mut VisualTestContext| {
            let dock = dock.clone();
            cx.update(|window, cx| {
                transcript.update(cx, |t, cx| assert!(t.tab(true, dock, window, cx)))
            });
            frames(cx, 4);
        };
        step(cx);
        assert_eq!(spot(cx), Spot::Row(7), "the last answer, not the third");
        assert_eq!(list.item_is_below_viewport(7), Some(false), "in view");
        assert_eq!(list.item_is_above_viewport(7), Some(false), "in view");
        // Its last control (the last suggestion): one Tab on leaves the row.
        let landed = cx.update(|window, cx| window.focused(cx)).unwrap();
        cx.update(|window, cx| window.focus_next(cx));
        assert_eq!(spot(cx), Spot::Below, "the last of the answer's controls");
        cx.update(|window, cx| window.focus(&landed, cx));
        frames(cx, 1);
        // On up through it to the last question, then the third answer.
        let mut seen = vec![spot(cx)];
        for _ in 0..12 {
            step(cx);
            let now = spot(cx);
            if seen.last() != Some(&now) {
                seen.push(now);
            }
            if now == Spot::Row(5) {
                break;
            }
        }
        assert_eq!(
            seen,
            vec![Spot::Row(7), Spot::Row(6), Spot::Row(5)],
            "every row, in the messages' order"
        );
    }

    /// Streams the answer's next snapshot: `lines` paragraphs.
    fn stream(store: &Entity<ChatStore>, lines: usize, cx: &mut VisualTestContext) {
        let text = (1..=lines)
            .map(|i| format!("Line {i} of the answer."))
            .collect::<Vec<_>>()
            .join("\n\n");
        let blocks = vec![MessageBlockDto {
            markdown: Some(text),
            ..empty_block(MessageBlockKind::Text)
        }];
        store.update(cx, |s, cx| {
            s.on_event(
                &Event::TurnBlocks(TurnBlocks {
                    chat_id: "c1".into(),
                    message_id: "a1".into(),
                    blocks,
                    tasks: None,
                }),
                cx,
            )
        });
    }

    /// Lays the transcript out `VIEWPORT` tall, then again once the
    /// answer's text has been parsed (off the main thread).
    fn draw(transcript: &Entity<Transcript>, cx: &mut VisualTestContext) {
        for settle in [false, true] {
            if settle {
                cx.run_until_parked();
            }
            let view = transcript.clone();
            cx.draw(
                point(px(0.), px(0.)),
                size(px(800.), px(VIEWPORT)),
                |_, _| div().flex().flex_col().size_full().child(view),
            );
        }
    }

    /// Draws frames 16 ms apart until the view has caught up with the end
    /// (the eased follow) and held still, returning where the answer's end
    /// was painted in each frame.
    fn settle(transcript: &Entity<Transcript>, cx: &mut VisualTestContext) -> Vec<f32> {
        let list = transcript.read_with(cx, |t, _| t.list_state().clone());
        let mut ends: Vec<f32> = vec![];
        for _ in 0..90 {
            draw(transcript, cx);
            if let Some((_, end)) = painted(&list, 1) {
                ends.push(end);
            }
            let still = ends.len() >= 4
                && ends[ends.len() - 4..]
                    .windows(2)
                    .all(|w| (w[0] - w[1]).abs() < 0.01);
            if transcript.read_with(cx, |t, _| t.chase.is_none()) || still {
                break;
            }
            cx.executor()
                .advance_clock(std::time::Duration::from_millis(16));
        }
        ends
    }

    /// Where row `ix` is painted, top and bottom, if it is on screen. The
    /// list paints its top padding above the rows, which `bounds_for_item`
    /// leaves out.
    fn painted(list: &ListState, ix: usize) -> Option<(f32, f32)> {
        let b = list.bounds_for_item(ix)?;
        Some((
            f32::from(b.top()) + TOP_INSET,
            f32::from(b.bottom()) + TOP_INSET,
        ))
    }

    #[gpui_kit::test]
    fn a_short_chat_starts_at_the_top_and_a_tall_one_follows_its_end(cx: &mut TestAppContext) {
        let (store, transcript, cx) = open(cx);
        let list = transcript.read_with(cx, |t, _| t.list_state().clone());
        let (mut fitting, mut overflowing) = (0, 0);
        for lines in 1..=80 {
            stream(&store, lines, cx);
            settle(&transcript, cx);
            let top = f32::from(list.viewport_bounds().top());
            // A tall chat's end stays one inset above the bottom, clear of
            // the fade over the composer.
            let bottom = top + VIEWPORT - BOTTOM_INSET;
            let (_, end) = painted(&list, 1).expect("the answer is on screen");
            let Some((start, _)) = painted(&list, 0) else {
                // The question has scrolled away: the end stays put.
                assert!(
                    (end - bottom).abs() < 0.5,
                    "{lines}: end {end}, bottom {bottom}"
                );
                overflowing += 1;
                if overflowing > 4 {
                    break;
                }
                continue;
            };
            // Short, the rows start under the inset; tall, they move up by
            // exactly what does not fit. Both at once: no jump as the
            // answer outgrows the window.
            let rows = end - start;
            let overflow = (TOP_INSET + rows + BOTTOM_INSET - VIEWPORT).max(0.);
            assert!(
                (start - (top + TOP_INSET - overflow)).abs() < 0.5,
                "{lines} lines: rows {rows} start at {start}, overflow {overflow}"
            );
            if overflow > 0. {
                assert!(
                    (end - bottom).abs() < 0.5,
                    "{lines}: end {end}, bottom {bottom}"
                );
                overflowing += 1;
            } else {
                assert!(end < bottom, "{lines}: a short chat leaves room below");
                fitting += 1;
            }
        }
        assert!(
            fitting > 0 && overflowing > 4,
            "fitting {fitting}, overflowing {overflowing}"
        );
        assert!(
            transcript.read_with(cx, |t, _| t.follows_end()),
            "it followed the answer to its end"
        );
    }

    #[gpui_kit::test]
    fn a_growing_answer_is_followed_smoothly_never_in_a_jump(cx: &mut TestAppContext) {
        let (store, transcript, cx) = open(cx);
        let list = transcript.read_with(cx, |t, _| t.list_state().clone());
        stream(&store, 40, cx);
        settle(&transcript, cx);
        // The end, one inset above the bottom (clear of the composer fade).
        let bottom = f32::from(list.viewport_bounds().top()) + VIEWPORT - BOTTOM_INSET;
        let (top_before, before) = painted(&list, 1).unwrap();
        assert!((before - bottom).abs() < 0.5, "settled at the end");

        // Six more lines at once (about 140 pt).
        stream(&store, 46, cx);
        draw(&transcript, cx);
        // The frame the text lands in, nothing on screen moves: the new
        // lines are below the fold.
        let (top, _) = painted(&list, 1).unwrap();
        assert!(
            (top - top_before).abs() < 0.5,
            "the answer moved {}",
            top - top_before
        );
        // Then the new lines are released over the next frames (a steady
        // pace) and the view eases after them: the answer only ever moves
        // up, in steps far smaller than what it grew, and lands on the end.
        let mut tops = vec![top];
        let mut frames = 0;
        for _ in 0..60 {
            cx.executor()
                .advance_clock(std::time::Duration::from_millis(16));
            draw(&transcript, cx);
            frames += 1;
            tops.push(painted(&list, 1).unwrap().0);
            let (_, end) = painted(&list, 1).unwrap();
            if (end - bottom).abs() < 0.5
                && transcript.read_with(cx, |t, _| t.chase.is_none() || t.list.is_following_tail())
                && frames > 8
            {
                break;
            }
        }
        let grown = height(&list, 1) - (before - top_before);
        assert!(grown > 100., "it grew {grown}");
        let steps: Vec<f32> = tops.windows(2).map(|w| w[0] - w[1]).collect();
        assert!(steps.iter().all(|d| *d >= -0.01), "never back: {steps:?}");
        let largest = steps.iter().copied().fold(0., f32::max);
        assert!(largest < grown * 0.3, "largest step {largest} of {grown}");
        let near = tops
            .iter()
            .position(|t| (t - (top_before - grown)).abs() < 2.)
            .unwrap_or(usize::MAX);
        assert!(
            (6..=30).contains(&near),
            "released and eased over ~100-500 ms: {near} frames, {tops:?}"
        );
        let (_, end) = painted(&list, 1).unwrap();
        assert!((end - bottom).abs() < 0.5, "at the end: {end} vs {bottom}");
        assert!(transcript.read_with(cx, |t, _| t.follows_end()));

        // The answer finishes: the list follows on its own again.
        store.update(cx, |s, cx| {
            s.on_event(
                &Event::TurnCompleted(conduit_protocol::TurnCompleted {
                    chat_id: "c1".into(),
                    message_id: "a1".into(),
                    text: String::new(),
                    reasoning: None,
                    usage: None,
                }),
                cx,
            )
        });
        for _ in 0..6 {
            draw(&transcript, cx);
            cx.executor()
                .advance_clock(std::time::Duration::from_millis(16));
        }
        assert!(transcript.read_with(cx, |t, _| t.chase.is_none()));
        assert!(list.is_following_tail(), "and following again");
    }

    #[gpui_kit::test]
    fn under_reduce_motion_the_end_is_followed_at_once(cx: &mut TestAppContext) {
        let (store, transcript, cx) = open(cx);
        cx.update(|_, cx| cx.set_reduce_motion(true));
        let list = transcript.read_with(cx, |t, _| t.list_state().clone());
        stream(&store, 40, cx);
        draw(&transcript, cx);
        stream(&store, 46, cx);
        draw(&transcript, cx);
        let bottom = f32::from(list.viewport_bounds().top()) + VIEWPORT - BOTTOM_INSET;
        let (_, end) = painted(&list, 1).unwrap();
        assert!((end - bottom).abs() < 0.5, "{end} vs {bottom}");
        assert!(transcript.read_with(cx, |t, _| t.chase.is_none()));
    }
}
