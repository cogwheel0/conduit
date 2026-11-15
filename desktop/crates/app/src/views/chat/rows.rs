//! One transcript row each: the user's messages (right-aligned bubbles,
//! edited in place) and the answers (typed blocks, then the action row).
//!
//! Every message is a labelled `Role::Article` carrying its text (a bare
//! TextView is invisible to VoiceOver). Actions:
//!
//! * answers: copy, regenerate (`turns.regenerate`), thumbs up/down
//!   (`turns.rate`, shown at once and rolled back if refused), the version
//!   arrows (`n / N`), and the sources pill once the answer is finished;
//! * questions: copy and edit in place (`turns.edit`).
//!
//! The action row shows on hover, and always under the newest answer; it
//! is drawn transparent otherwise, so VoiceOver still reaches it.

use std::collections::{HashMap, HashSet};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Instant;

use conduit_components::ActiveConduitTheme as _;
use conduit_components::assets::{IconName, icon};
use conduit_components::motion::{self, Crossfade, Reduced, Reveal, Tween, specs};
use conduit_components::theme::{ConduitTheme, with_alpha};
use conduit_components::views::focus::ControlExt as _;
use conduit_components::views::kit::IconButton;
use conduit_protocol::{ChatSourceDto, MessageBlockKind};
use gpui_kit::component::input::{InputEvent, Textarea, TextareaState};
use gpui_kit::component::text::TextViewState;
use gpui_kit::prelude::*;
use gpui_kit::{
    AnyElement, App, ClipboardItem, Context, ElementId, Entity, EntityInputHandler as _,
    FontWeight, Role, SharedString, Subscription, Transformation, WeakEntity, Window, div,
    percentage, px, relative,
};

use super::blocks::{ACTIVITY_GAP, error_text, file_list, spinner};
use super::pace::Pace;
use crate::l10n::ActiveL10n as _;
use crate::stores::chat::{ChatStore, Role as MessageRole, RowItem, shows};
use crate::stores::composer::ComposerStore;
use crate::views::chat_pane::ChatPane;
use crate::views::quick_ask::QuickAskView;

/// The view a row reports to: the "Copied" toast and follow-up questions.
#[derive(Clone)]
pub enum RowSink {
    /// The main window's chat pane.
    Pane(WeakEntity<ChatPane>),
    /// The Quick Ask window.
    QuickAsk(WeakEntity<QuickAskView>),
    /// Nothing (fixtures).
    None,
}

impl RowSink {
    /// Something was copied.
    pub fn copied(&self, cx: &mut App) {
        match self {
            Self::Pane(p) => {
                let _ = p.update(cx, |p, cx| p.notify_copied(cx));
            }
            Self::QuickAsk(q) => {
                let _ = q.update(cx, |q, cx| q.notify_copied(cx));
            }
            Self::None => {}
        }
    }

    /// Sends `text` as the next message (a follow-up question).
    pub fn send(&self, text: String, window: &mut Window, cx: &mut App) {
        match self {
            Self::Pane(p) => {
                let _ = p.update(cx, |p, cx| p.send_text(text, window, cx));
            }
            Self::QuickAsk(q) => {
                let _ = q.update(cx, |q, cx| q.send_text(text, window, cx));
            }
            Self::None => {}
        }
    }
}

/// What a row acts through.
#[derive(Clone)]
pub struct RowHost {
    pub store: WeakEntity<ChatStore>,
    pub pane: RowSink,
    /// The active account's id, for `/files`.
    pub server_id: Option<String>,
    /// The models on offer, to name an answer's model by its name rather
    /// than its id (a Direct model's id is an opaque key).
    pub composer: Option<WeakEntity<ComposerStore>>,
}

impl RowHost {
    /// `model` (an id) as the picker names it, else as it is.
    pub fn model_name(&self, model: &str, cx: &App) -> String {
        self.composer
            .as_ref()
            .and_then(WeakEntity::upgrade)
            .and_then(|c| {
                c.read(cx)
                    .models
                    .as_ref()?
                    .models
                    .iter()
                    .find(|m| m.id == model)
                    .map(|m| m.name.clone())
            })
            .unwrap_or_else(|| model.to_string())
    }
}

/// Per-row flags from the chat.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct RowFlags {
    /// Edit, regenerate and rate apply (a stored chat, nothing streaming).
    pub can_branch: bool,
    /// Follow-ups are offered (never in a read-only chat).
    pub can_follow_up: bool,
}

/// The answer's More menu: rate it (`turns.rate`). Carries the chat's
/// store, so the app-wide handler ([`register_actions`]) reaches it
/// wherever focus is.
#[derive(Clone, Debug, PartialEq, gpui_kit::Action)]
#[action(namespace = conduit_chat, no_json)]
pub struct RateAnswer {
    pub store: WeakEntity<ChatStore>,
    pub key: String,
    pub rating: i64,
}

/// The answer's More menu: copy its text with the Markdown formatting kept.
/// Carries where to say "Copied".
#[derive(Clone, Debug, PartialEq, gpui_kit::Action)]
#[action(namespace = conduit_chat, no_json)]
pub struct CopyAnswerMarkdown {
    pub markdown: String,
    pub pane: Option<WeakEntity<ChatPane>>,
    pub quick_ask: Option<WeakEntity<QuickAskView>>,
}

/// Registers the rows' menu actions on the app.
pub fn register_actions(cx: &mut App) {
    cx.on_action(|a: &RateAnswer, cx| {
        let (key, rating) = (a.key.clone(), a.rating);
        let _ = a.store.update(cx, |s, cx| s.rate(&key, rating, cx));
    });
    cx.on_action(|a: &CopyAnswerMarkdown, cx| {
        let sink = match (&a.pane, &a.quick_ask) {
            (Some(p), _) => RowSink::Pane(p.clone()),
            (None, Some(q)) => RowSink::QuickAsk(q.clone()),
            (None, None) => RowSink::None,
        };
        copy_text(&a.markdown, &sink, cx);
    });
}

/// An answer as Markdown: its text blocks as written (no reasoning, tool
/// calls or sources), else its stored text.
pub fn answer_markdown(item: &RowItem) -> String {
    let parts: Vec<&str> = item
        .blocks
        .iter()
        .filter(|b| b.kind == MessageBlockKind::Text)
        .filter_map(|b| b.markdown.as_deref())
        .map(str::trim)
        .filter(|t| !t.is_empty())
        .collect();
    if parts.is_empty() {
        item.text.trim().to_string()
    } else {
        parts.join("\n\n")
    }
}

fn small_action(
    id: String,
    ic: IconName,
    label: SharedString,
    active: bool,
    t: &ConduitTheme,
) -> IconButton {
    IconButton::new(ElementId::Name(id.into()), ic, label)
        .size(28., 15.)
        .color(if active {
            t.roles.text
        } else {
            t.roles.text_subtle
        })
        .active(active)
}

/// Which of an answer's actions it offers.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub(super) struct AnswerActions {
    pub copy: bool,
    pub regenerate: bool,
    /// Good Answer / Bad Answer in More.
    pub rate: bool,
    /// More › Copy Error Details, with what it copies.
    pub copy_error: Option<String>,
    /// More › Copy as Markdown.
    pub copy_markdown: bool,
}

impl AnswerActions {
    /// A failed answer's banner has Retry, which is the way on: its row
    /// keeps only More (to copy what went wrong, and what was written before
    /// it failed, if anything), never a second Retry (Regenerate), a Copy
    /// of nothing or a rating. Any other answer: Copy, Regenerate where it
    /// can branch, and More with Copy as Markdown and the rating.
    pub fn of(item: &RowItem, flags: RowFlags, l10n: &crate::l10n::L10n) -> Self {
        let error = item
            .blocks
            .iter()
            .find(|b| b.kind == MessageBlockKind::Error)
            .map(|b| error_text(b, l10n));
        if let Some(error) = error {
            return Self {
                copy_error: Some(error),
                copy_markdown: !answer_markdown(item).is_empty(),
                ..Self::default()
            };
        }
        Self {
            copy: true,
            regenerate: flags.can_branch,
            rate: flags.can_branch && item.version.is_none_or(|(s, n)| s == n),
            copy_error: None,
            copy_markdown: true,
        }
    }
}

fn copy_text(text: &str, pane: &RowSink, cx: &mut App) {
    cx.write_to_clipboard(ClipboardItem::new_string(text.to_string()));
    pane.copied(cx);
}

// ── Answers ────────────────────────────────────────────────────────────────

/// Between a disclosure's line and its opened body.
const DISCLOSURE_GAP: f32 = 6.;

pub struct AssistantRow {
    pub(super) host: RowHost,
    pub(super) item: RowItem,
    pub(super) flags: RowFlags,
    pub(super) texts: HashMap<String, (String, Entity<TextViewState>)>,
    pub(super) expanded: HashSet<String>,
    /// Disclosures opening or closing: their height and chevron.
    opening: HashMap<String, Tween>,
    hovered: bool,
    sources_open: bool,
    /// The action row's focus scope, once drawn (the transcript scrolls a
    /// row Tab reaches into view).
    actions_focus: Option<gpui_kit::FocusHandle>,
    /// When this row's answer stopped streaming, if it was seen streaming:
    /// its actions and suggestions arrive together once it settles
    /// ([`motion::settled`]).
    finished: Option<Instant>,
    _settle: Option<gpui_kit::Task<()>>,
    /// Names this view's motion state. The row's key can change under it
    /// (a regenerate's answer gets its own id once the server takes it),
    /// and its fades carry on through that.
    motion_key: String,
    /// Each text block's steady release while the answer streams (by the
    /// block's ordinal).
    pub(super) paces: HashMap<usize, Pace>,
    /// The suggestions drawn last frame, if they were showing.
    follow_ups_shown: Option<Vec<String>>,
    /// A regenerate on its way: the old answer's suggestions, fading where
    /// they stand, their room kept until the new answer starts.
    stale_follow_ups: Option<Vec<String>>,
    /// The old answer crossfading into a regenerate's first words.
    leaving: Option<Leaving>,
    /// The whole row's focus scope (not a stop): which row Tab is in.
    row_focus: Option<gpui_kit::FocusHandle>,
}

/// What a regenerate's old answer showed, drawn while it crossfades into
/// the new one.
struct Leaving {
    item: RowItem,
    texts: HashMap<String, (String, Entity<TextViewState>)>,
    /// Its disclosures that were open.
    expanded: HashSet<String>,
    follow_ups: Option<Vec<String>>,
    start: Instant,
}

/// Every answer view's own motion key.
static ROW_SERIAL: AtomicU64 = AtomicU64::new(0);

impl AssistantRow {
    pub fn new(host: RowHost, item: RowItem, flags: RowFlags) -> Self {
        Self {
            host,
            item,
            flags,
            texts: HashMap::new(),
            expanded: HashSet::new(),
            opening: HashMap::new(),
            hovered: false,
            sources_open: false,
            actions_focus: None,
            finished: None,
            _settle: None,
            motion_key: format!("answer{}", ROW_SERIAL.fetch_add(1, Ordering::Relaxed)),
            paces: HashMap::new(),
            follow_ups_shown: None,
            stale_follow_ups: None,
            leaving: None,
            row_focus: None,
        }
    }

    /// The row's new content; text states are reused (incremental
    /// `set_text`) when the next render draws them.
    pub fn set(&mut self, item: RowItem, flags: RowFlags, cx: &mut Context<Self>) {
        if item == self.item && flags == self.flags {
            return;
        }
        if self.item.streaming && !item.streaming {
            // Just finished: draw again when the wait for its suggestions
            // is over, if they have not come by then.
            let now = cx.background_executor().now();
            self.finished = Some(now);
            self._settle = Some(cx.spawn(async move |this: WeakEntity<Self>, cx| {
                cx.background_executor().timer(motion::SETTLE_WAIT).await;
                let _ = this.update(cx, |_, cx| cx.notify());
            }));
        } else if item.streaming {
            self.finished = None;
        }
        let now = cx.background_executor().now();
        if !self.item.stale && item.stale {
            // A regenerate starts: the suggestions showing fade where they
            // stand, keeping their room.
            self.stale_follow_ups = self.follow_ups_shown.clone();
        } else if self.item.stale && !item.stale {
            // Its first words: the old answer crossfades into them.
            let old = std::mem::replace(&mut self.item, item.clone());
            self.leaving = Some(Leaving {
                item: old,
                texts: std::mem::take(&mut self.texts),
                expanded: std::mem::take(&mut self.expanded),
                follow_ups: self.stale_follow_ups.take(),
                start: now,
            });
            self.opening.clear();
            self.paces.clear();
            self.sources_open = false;
        }
        self.item = item;
        self.flags = flags;
        cx.notify();
    }

    pub fn item(&self) -> &RowItem {
        &self.item
    }

    /// The newest answer, just finished, whose suggestions may still come
    /// (they follow the turn by a few hundred milliseconds; the actions wait
    /// for them, [`motion::settled`]).
    pub(super) fn awaits_suggestions(&self, now: Instant) -> bool {
        self.flags.can_follow_up
            && self.item.last_answer
            && !self.item.streaming
            && !self
                .item
                .blocks
                .iter()
                .any(|b| b.kind == MessageBlockKind::FollowUps)
            && !motion::settled(self.finished, false, now)
    }

    /// Opens or closes disclosure `key`: its height and chevron follow
    /// over 180 ms, turning back from where they are if clicked again
    /// (instant under Reduce Motion).
    pub(super) fn toggle(&mut self, key: &str, cx: &mut Context<Self>) {
        let open = !self.expanded.remove(key);
        if open {
            self.expanded.insert(key.to_string());
        }
        let now = cx.background_executor().now();
        let target = if open { 1. } else { 0. };
        if cx.reduce_motion() {
            self.opening.remove(key);
        } else {
            self.opening
                .entry(key.to_string())
                .or_insert_with(|| Tween::at(1. - target, now))
                .retarget(target, specs::DISCLOSURE, 1., now);
        }
        cx.notify();
    }

    /// How open disclosure `key` is (0…1) at `now`.
    pub(super) fn open_progress(&self, key: &str, now: Instant) -> f32 {
        match self.opening.get(key) {
            Some(tween) => tween.value(now),
            None if self.expanded.contains(key) => 1.,
            None => 0.,
        }
    }

    /// Whether disclosure `key`'s body is drawn: open, or still closing.
    pub(super) fn shows(&self, key: &str, cx: &App) -> bool {
        self.expanded.contains(key)
            || self.open_progress(key, cx.background_executor().now()) > 0.001
    }

    /// The disclosure's chevron, turned a quarter as it opens.
    pub(super) fn chevron_for(&self, key: &str, t: &ConduitTheme, cx: &App) -> gpui_kit::Svg {
        let p = self.open_progress(key, cx.background_executor().now());
        icon(IconName::ChevronRight, 11., t.roles.text_subtle)
            .with_transformation(Transformation::rotate(percentage(0.25 * p)))
    }

    /// A disclosure's body, its height and opacity following how open it is.
    /// The space between its line and the body is part of what opens, so
    /// nothing below moves before the body starts to show.
    pub(super) fn reveal(&self, key: &str, body: impl IntoElement, cx: &App) -> AnyElement {
        let p = self.open_progress(key, cx.background_executor().now());
        // As much room under the body as over it, so the next line of a run
        // doesn't sit on it.
        let body = div()
            .pt(px(DISCLOSURE_GAP))
            .pb(px(DISCLOSURE_GAP))
            .child(body);
        if p >= 1. {
            return body.into_any_element();
        }
        Reveal::new(
            ElementId::Name(format!("reveal-{}-{key}", self.item.key).into()),
            p,
            div().opacity(p).child(body),
        )
        .into_any_element()
    }

    /// The TextView state for `key`, made or updated with `markdown`.
    pub(super) fn text_state(
        &mut self,
        key: &str,
        markdown: &str,
        _: &mut Window,
        cx: &mut Context<Self>,
    ) -> Entity<TextViewState> {
        self.ensure_text(key, markdown, cx)
    }

    /// [`Self::text_state`] outside a frame (Find in Chat makes the states
    /// of rows not drawn yet).
    pub(super) fn ensure_text(
        &mut self,
        key: &str,
        markdown: &str,
        cx: &mut Context<Self>,
    ) -> Entity<TextViewState> {
        match self.texts.get_mut(key) {
            Some((last, state)) => {
                if last != markdown {
                    *last = markdown.to_string();
                    state.update(cx, |s, cx| s.set_text(markdown, cx));
                }
                state.clone()
            }
            None => {
                let state = cx.new(|cx| TextViewState::markdown(markdown, cx).selectable(true));
                self.texts
                    .insert(key.to_string(), (markdown.to_string(), state.clone()));
                state
            }
        }
    }

    /// What VoiceOver reads for the answer: the text blocks as drawn (as
    /// written while the answer streams, which costs nothing per frame).
    fn spoken(&self, cx: &App) -> String {
        if self.item.streaming {
            return self
                .item
                .blocks
                .iter()
                .filter(|b| b.kind == MessageBlockKind::Text)
                .filter_map(|b| b.markdown.as_deref())
                .collect::<Vec<_>>()
                .join(" ");
        }
        let mut out = String::new();
        let mut ordinal = 0;
        for block in &self.item.blocks {
            if block.kind != MessageBlockKind::Text {
                continue;
            }
            let keys = spoken_keys(ordinal, |k| self.texts.contains_key(k));
            for key in keys {
                if let Some((_, state)) = self.texts.get(&key) {
                    let text = state.read(cx).rendered_text().as_str().to_string();
                    if !out.is_empty() {
                        out.push(' ');
                    }
                    out.push_str(text.trim());
                }
            }
            ordinal += 1;
        }
        if out.is_empty() {
            self.item.text.trim().to_string()
        } else {
            out
        }
    }

    fn sources_pill(
        &self,
        sources: &[ChatSourceDto],
        t: &ConduitTheme,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let l10n = cx.l10n().clone();
        let r = t.roles;
        let key = &self.item.key;
        let label = l10n.desktop_sources_count(sources.len() as i64);
        div()
            .id(ElementId::Name(format!("sources-pill-{key}").into()))
            .role(Role::Button)
            .aria_label(SharedString::from(label.clone()))
            .aria_expanded(self.sources_open)
            .h(px(24.))
            .px(px(9.))
            .ml(px(4.))
            .flex()
            .items_center()
            .gap(px(5.))
            .rounded_full()
            .border_1()
            .border_color(r.border)
            .when(self.sources_open, |d| d.bg(r.selected))
            .hover(|s| s.bg(r.hover))
            .active(|s| s.bg(conduit_components::views::focus::pressed_fill(r.hover, t)))
            .cursor_pointer()
            .keyboard_border(cx)
            .text_size(px(t.metrics.small))
            .text_color(r.text_subtle)
            .child(icon(IconName::Globe, 12., r.text_subtle))
            .child(SharedString::from(label))
            .on_click(cx.listener(|this, _, _, cx| {
                this.sources_open = !this.sources_open;
                cx.notify();
            }))
            .into_any_element()
    }
}

/// The sources an answer cites, as a list of links.
pub fn source_list(id: &str, sources: &[ChatSourceDto], cx: &App) -> AnyElement {
    let t = cx.conduit().clone();
    let l10n = cx.l10n().clone();
    let r = t.roles;
    let m = t.metrics;
    // A heading over the list, as Suggestions has one.
    let heading = div()
        .id(ElementId::Name(format!("sources-heading-{id}").into()))
        .role(Role::Heading)
        .aria_label(SharedString::from(l10n.desktop_sources()))
        .px(px(6.))
        .pb(px(2.))
        .text_size(px(m.small))
        .font_weight(FontWeight::SEMIBOLD)
        .text_color(r.text_subtle)
        .child(SharedString::from(l10n.desktop_sources()));
    let list = div()
        .id(ElementId::Name(format!("sources-{id}").into()))
        .role(Role::List)
        .aria_label(SharedString::from(l10n.desktop_sources()))
        .flex()
        .flex_col()
        .gap(px(2.))
        .children(sources.iter().enumerate().map(|(n, s)| {
            let url = s.url.clone();
            let host = url
                .as_deref()
                .and_then(|u| url::Url::parse(u).ok())
                .and_then(|u| {
                    u.host_str()
                        .map(|h| h.trim_start_matches("www.").to_string())
                })
                .unwrap_or_default();
            let label = l10n.desktop_source_label(n as i64 + 1, &s.label);
            div()
                .id(ElementId::Name(format!("source-{id}-{n}").into()))
                .role(Role::Link)
                .aria_label(SharedString::from(label))
                .min_h(px(28.))
                .px(px(6.))
                .py(px(3.))
                .flex()
                .items_center()
                .gap(px(8.))
                .rounded(t.control_radius())
                .when(url.is_some(), |d| {
                    d.cursor_pointer().hover(|s| s.bg(r.hover))
                })
                .child(
                    div()
                        .size(px(18.))
                        .flex_none()
                        .rounded_full()
                        .bg(with_alpha(r.text, if t.dark { 0.14 } else { 0.07 }))
                        .flex()
                        .items_center()
                        .justify_center()
                        .text_size(px(10.))
                        .font_weight(FontWeight::SEMIBOLD)
                        .text_color(r.text_subtle)
                        .child(SharedString::from((n + 1).to_string())),
                )
                .child(
                    div()
                        .flex_1()
                        .min_w_0()
                        .flex()
                        .flex_col()
                        .child(
                            div()
                                .truncate()
                                .text_size(px(m.small))
                                .text_color(r.text)
                                .child(SharedString::from(s.label.clone())),
                        )
                        .when(!host.is_empty(), |d| {
                            d.child(
                                div()
                                    .text_size(px(m.caption))
                                    .text_color(r.text_subtle)
                                    .child(SharedString::from(host)),
                            )
                        }),
                )
                .on_click(move |_, _, cx| {
                    if let Some(u) = &url {
                        super::markdown::open_web_link(u, cx)
                    }
                })
        }));
    div()
        .ml(px(-6.))
        .flex()
        .flex_col()
        .child(heading)
        .child(list)
        .into_any_element()
}

impl AssistantRow {
    /// The answer under its header: its blocks, then its actions (or, for a
    /// regenerate on its way, the waiting line in their place), sources and
    /// suggestions. `leaving` draws a regenerate's old answer as it was
    /// last shown, still, while it crossfades out.
    fn column(
        &mut self,
        leaving: bool,
        now: Instant,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let t = cx.conduit().clone();
        let l10n = cx.l10n().clone();
        let r = t.roles;
        let m = t.metrics;
        let item = self.item.clone();
        let key = item.key.clone();
        let mk = if leaving {
            format!("{}-leaving", self.motion_key)
        } else {
            self.motion_key.clone()
        };
        let stale = item.stale || leaving;
        if !leaving {
            // A text block that is gone (the stored copy has fewer) has
            // nothing left to release.
            let texts = item
                .blocks
                .iter()
                .filter(|b| b.kind == MessageBlockKind::Text)
                .count();
            self.paces.retain(|ordinal, _| *ordinal < texts);
        }

        let mut parts: Vec<(bool, AnyElement)> = vec![];
        let mut ordinals: HashMap<MessageBlockKind, usize> = HashMap::new();
        for (i, block) in item.blocks.iter().enumerate() {
            let ordinal = ordinals.entry(block.kind).or_default();
            let n = *ordinal;
            *ordinal += 1;
            if let Some(el) = self.render_block(i, n, block, window, cx) {
                parts.push((is_activity(block.kind), el));
            }
        }
        let mut body: Vec<AnyElement> = group_activity(parts);
        // A regenerate's old answer dims while the new one is on its way.
        let dim = if leaving {
            0.35
        } else {
            motion::tween(
                ElementId::Name(format!("stale-{mk}").into()),
                if item.stale { 0.35 } else { 1. },
                specs::STALE,
                Reduced::Keep,
                window,
                cx,
            )
        };
        if dim < 1. && !body.is_empty() {
            body = vec![
                div()
                    .flex()
                    .flex_col()
                    .gap(px(10.))
                    .opacity(dim)
                    .children(body)
                    .into_any_element(),
            ];
        }
        // An answer under way with nothing to show yet (no blocks, a text
        // with no words released yet, a status with nothing to say):
        // "Waiting for the answer…" with a soft shimmer, alone under the
        // header, until something is drawn.
        // (Not while a regenerate's old answer crossfades into the first
        // words: they are what comes in.)
        if item.streaming && !stale && self.leaving.is_none() && !self.draws_anything(&item) {
            body.push(waiting_line(&mk, &t, &l10n, window, cx));
        }
        // Suggestions open under the last answer once it is done (150 ms,
        // height and fade) and leave the moment the next message is sent
        // (150 ms). A row drawn with them already there shows them at once.
        // For a regenerate they fade where they stand (120 ms), keeping
        // their room until the new answer starts.
        let offered = self
            .flags
            .can_follow_up
            .then(|| {
                item.blocks
                    .iter()
                    .find(|b| b.kind == MessageBlockKind::FollowUps)
                    .and_then(|b| b.follow_ups.clone())
            })
            .flatten()
            .filter(|f| !f.is_empty());
        // A just-finished answer's actions wait for its suggestions (briefly)
        // and for its text to be all out, and the two arrive together in one
        // 150 ms fade.
        let settled = motion::settled(self.finished, offered.is_some(), now)
            && (leaving || self.paces.is_empty());
        let wanted = item.last_answer && !item.streaming && offered.is_some() && settled && !stale;
        let actions_in = if leaving {
            0.
        } else {
            motion::tween(
                ElementId::Name(format!("actions-motion-{mk}").into()),
                if !item.streaming && settled { 1. } else { 0. },
                specs::REVEAL,
                Reduced::Keep,
                window,
                cx,
            )
        };
        let open = if leaving {
            0.
        } else {
            motion::tween_with(
                ElementId::Name(format!("follow-ups-motion-{mk}").into()),
                if wanted { 1. } else { 0. },
                specs::REVEAL,
                if item.stale {
                    specs::REGEN_OUT
                } else {
                    specs::REVEAL_OUT
                },
                Reduced::Keep,
                window,
                cx,
            )
        };
        let (follow_ups, keep_room) = if leaving {
            (
                self.leaving.as_ref().and_then(|l| l.follow_ups.clone()),
                true,
            )
        } else if item.stale {
            (self.stale_follow_ups.clone(), true)
        } else {
            (offered.filter(|_| open > 0.001), false)
        };
        if !leaving {
            self.follow_ups_shown = follow_ups.clone().filter(|_| !stale && open > 0.5);
        }
        let sources = item.sources.clone();
        let offer = AnswerActions::of(&item, self.flags, &l10n);
        let show_actions = !item.streaming;
        let hovered = self.hovered;
        let host = self.host.clone();

        // The row shows while the pointer is over the answer, and while Tab
        // has one of its buttons.
        let actions_focus = conduit_components::views::focus::control_focus_handle(
            &ElementId::Name(format!("answer-actions-{key}").into()),
            window,
            cx,
        );
        if !leaving {
            self.actions_focus = Some(actions_focus.clone());
        }
        let actions_visible =
            item.last_answer || hovered || actions_focus.contains_focused(window, cx);
        let show_actions = show_actions && !leaving;
        // The last answer's Copy and Regenerate are Chat › Copy Last Answer
        // (⇧⌘C) and Regenerate (⌘R) in the main window: their tooltips say
        // so (Quick Ask has no such chords).
        let chords = (item.last_answer && matches!(host.pane, RowSink::Pane(_)))
            .then(|| conduit_components::views::focus::hints(cx));
        let actions = show_actions.then(|| {
            let copy_text_value = item.text.clone();
            let pane = host.pane.clone();
            let store_regen = host.store.clone();
            let regen_key = key.clone();
            div()
                .track_focus(&actions_focus)
                .on_mouse_down(gpui_kit::MouseButton::Left, |_, window, _| {
                    window.prevent_default()
                })
                .ml(px(-6.))
                // Close under the answer (the column's 10 pt gap less 8): its
                // room is kept whether or not it shows, inside the turn gap.
                .mt(px(rhythm::ACTIONS_GAP - 10.))
                .h(px(rhythm::ACTIONS_HEIGHT))
                .flex()
                .items_center()
                .gap(px(2.))
                .opacity(if actions_visible { actions_in } else { 0. })
                .when_some(item.version, |d, (shown, total)| {
                    let (prev_store, next_store) = (host.store.clone(), host.store.clone());
                    let (prev_key, next_key) = (key.clone(), key.clone());
                    d.child(
                        div()
                            .id(ElementId::Name(format!("versions-{key}").into()))
                            .role(Role::Group)
                            .aria_label(SharedString::from(
                                l10n.desktop_version_of(shown as i64, total as i64),
                            ))
                            .flex()
                            .items_center()
                            .gap(px(1.))
                            .child(
                                IconButton::new(
                                    ElementId::Name(format!("prev-version-{key}").into()),
                                    IconName::ChevronLeft,
                                    l10n.desktop_previous_answer(),
                                )
                                .size(24., 14.)
                                .color(r.text_faint)
                                .on_click(std::rc::Rc::new(
                                    move |_, _, cx| {
                                        let _ = prev_store
                                            .update(cx, |s, cx| s.step_version(&prev_key, -1, cx));
                                    },
                                )),
                            )
                            .child(
                                div()
                                    .text_size(px(m.small))
                                    .text_color(r.text_subtle)
                                    .child(SharedString::from(format!("{shown} / {total}"))),
                            )
                            .child(
                                IconButton::new(
                                    ElementId::Name(format!("next-version-{key}").into()),
                                    IconName::ChevronRight,
                                    l10n.desktop_next_answer(),
                                )
                                .size(24., 14.)
                                .color(r.text_faint)
                                .on_click(std::rc::Rc::new(
                                    move |_, _, cx| {
                                        let _ = next_store
                                            .update(cx, |s, cx| s.step_version(&next_key, 1, cx));
                                    },
                                )),
                            ),
                    )
                })
                .when(offer.copy, |d| {
                    d.child(
                        small_action(
                            format!("copy-{key}"),
                            IconName::Copy,
                            l10n.copy().into(),
                            false,
                            &t,
                        )
                        .shortcut(chords.as_ref().and_then(|k| k.copy_last_reply.clone()))
                        .on_click(std::rc::Rc::new(move |_, _, cx| {
                            copy_text(&copy_text_value, &pane, cx)
                        })),
                    )
                })
                .when(offer.regenerate, |d| {
                    d.child(
                        small_action(
                            format!("regen-{key}"),
                            IconName::RotateCcw,
                            l10n.regenerate().into(),
                            false,
                            &t,
                        )
                        .shortcut(chords.as_ref().and_then(|k| k.regenerate.clone()))
                        .on_click(std::rc::Rc::new(move |_, _, cx| {
                            let _ =
                                store_regen.update(cx, |s, cx| s.regenerate(&regen_key, None, cx));
                        })),
                    )
                })
                .when(!sources.is_empty(), |d| {
                    d.child(self.sources_pill(&sources, &t, cx))
                })
                // More: Copy as Markdown, and the rating (as the phone keeps
                // its row to copy, read aloud, regenerate and More).
                .child({
                    let can_rate = offer.rate;
                    let rating = item.rating;
                    let (store, more_key) = (host.store.clone(), key.clone());
                    let (good, bad) = (l10n.desktop_good_response(), l10n.desktop_bad_response());
                    let copy_md = l10n.desktop_copy_as_markdown();
                    let markdown = answer_markdown(&item);
                    let copy_error = offer
                        .copy_error
                        .clone()
                        .map(|e| (l10n.desktop_copy_error_details(), e));
                    let copy_markdown = offer.copy_markdown;
                    let (pane, quick_ask) = match &host.pane {
                        RowSink::Pane(p) => (Some(p.clone()), None),
                        RowSink::QuickAsk(q) => (None, Some(q.clone())),
                        RowSink::None => (None, None),
                    };
                    small_action(
                        format!("more-{key}"),
                        IconName::Ellipsis,
                        l10n.more().into(),
                        rating.is_some(),
                        &t,
                    )
                    .on_click(std::rc::Rc::new(
                        move |e: &gpui_kit::ClickEvent, window, cx| {
                            use gpui_kit::component::native_menu::NativeMenu;
                            let rate = |value: i64| -> Box<dyn gpui_kit::Action> {
                                Box::new(RateAnswer {
                                    store: store.clone(),
                                    key: more_key.clone(),
                                    rating: value,
                                })
                            };
                            let copy = |markdown: String| -> Box<dyn gpui_kit::Action> {
                                Box::new(CopyAnswerMarkdown {
                                    markdown,
                                    pane: pane.clone(),
                                    quick_ask: quick_ask.clone(),
                                })
                            };
                            let mut menu = NativeMenu::new();
                            if let Some((label, error)) = &copy_error {
                                menu = menu.menu(label.clone(), copy(error.clone()));
                            }
                            if copy_markdown {
                                menu = menu.menu(copy_md.clone(), copy(markdown.clone()));
                            }
                            if can_rate {
                                menu = menu
                                    .separator()
                                    .menu_with_check(good.clone(), rating == Some(1), rate(1))
                                    .menu_with_check(bad.clone(), rating == Some(-1), rate(-1));
                            }
                            menu.show(e.position(), window, cx);
                        },
                    ))
                })
        });

        // A regenerate on its way: the waiting line where the old answer's
        // actions were, so nothing under it moves.
        let waiting_slot = (stale && item.streaming).then(|| {
            let shown = if leaving {
                1.
            } else {
                motion::enter(
                    ElementId::Name(format!("waiting-in-{mk}").into()),
                    specs::REGEN_WAIT_IN,
                    Reduced::Keep,
                    window,
                    cx,
                )
            };
            div()
                .mt(px(rhythm::ACTIONS_GAP - 10.))
                .h(px(rhythm::ACTIONS_HEIGHT))
                .flex()
                .items_center()
                .opacity(shown)
                .child(waiting_line(&mk, &t, &l10n, window, cx))
        });

        div()
            .flex()
            .flex_col()
            .gap(px(rhythm::BLOCK_GAP))
            .children(body)
            .children(actions)
            .children(waiting_slot)
            .when(!leaving && self.sources_open && !sources.is_empty(), |d| {
                d.child(
                    div()
                        .pb(px(rhythm::AFTER_LIST))
                        .child(source_list(&key, &sources, cx)),
                )
            })
            .when_some(follow_ups, |d, items| {
                let list = div()
                    .relative()
                    .opacity(open)
                    .child(follow_up_list(&key, &items, &host, &t, cx))
                    .when(!wanted, |d| {
                        d.child(
                            div()
                                .id(ElementId::Name(format!("follow-ups-leaving-{mk}").into()))
                                .absolute()
                                .inset_0()
                                .occlude(),
                        )
                    });
                // Coming in, they take their whole room in the frame they
                // start to fade in with the actions (one change at the end of
                // the answer, which the view eases after), never a reveal
                // that uncovers them a row at a time; going, they close up.
                let height = if cx.reduce_motion() || keep_room || wanted {
                    1.
                } else {
                    open
                };
                d.child(Reveal::new(
                    ElementId::Name(format!("follow-ups-reveal-{mk}").into()),
                    height,
                    list,
                ))
            })
            .into_any_element()
    }

    /// Whether `item`'s body draws anything this frame: a text counts once
    /// words of it are released ([`super::pace::Pace`]).
    fn draws_anything(&self, item: &RowItem) -> bool {
        let mut ordinal = 0;
        item.blocks.iter().any(|b| {
            if b.kind != MessageBlockKind::Text {
                return shows(b);
            }
            let n = ordinal;
            ordinal += 1;
            let md = b.markdown.as_deref().unwrap_or_default();
            let shown = self.paces.get(&n).map_or(md.len(), |p| p.shown());
            md.get(..shown.min(md.len()))
                .is_some_and(|s| !s.trim().is_empty())
        })
    }

    /// The regenerate's old answer as it was last shown: drawn with its own
    /// item and text states, put back after.
    fn leaving_column(
        &mut self,
        now: Instant,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Option<AnyElement> {
        let mut l = self.leaving.take()?;
        std::mem::swap(&mut self.item, &mut l.item);
        std::mem::swap(&mut self.texts, &mut l.texts);
        std::mem::swap(&mut self.expanded, &mut l.expanded);
        let opening = std::mem::take(&mut self.opening);
        self.leaving = Some(l);
        let column = self.column(true, now, window, cx);
        let mut l = self.leaving.take().expect("put back above");
        std::mem::swap(&mut self.item, &mut l.item);
        std::mem::swap(&mut self.texts, &mut l.texts);
        std::mem::swap(&mut self.expanded, &mut l.expanded);
        self.opening = opening;
        self.leaving = Some(l);
        Some(column)
    }

    /// How far a regenerate's old answer has crossfaded into the new one
    /// (0…1), while it does.
    fn handover(&mut self, now: Instant) -> Option<f32> {
        let start = self.leaving.as_ref()?.start;
        let p = now.saturating_duration_since(start).as_secs_f32()
            / specs::REGEN_CROSSFADE.duration.as_secs_f32();
        if p >= 1. {
            self.leaving = None;
            return None;
        }
        Some(p.max(0.))
    }
}

impl Render for AssistantRow {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let now = cx.background_executor().now();
        self.opening.retain(|_, tween| tween.moving(now));
        if !self.opening.is_empty() {
            window.request_animation_frame();
        }
        let t = cx.conduit().clone();
        let l10n = cx.l10n().clone();
        let r = t.roles;
        let m = t.metrics;
        let item = self.item.clone();
        let key = item.key.clone();
        let mk = self.motion_key.clone();
        let model = item
            .model
            .as_deref()
            .map(|m| self.host.model_name(m, cx))
            .unwrap_or_default();

        let handover = self.handover(now);
        let column = self.column(false, now, window, cx);
        // A regenerate's first words: the old answer crossfades into the new
        // one in place (150 ms) and the height follows (at once under
        // Reduce Motion, which keeps the fade).
        let content = match handover.and_then(|p| Some((p, self.leaving_column(now, window, cx)?)))
        {
            Some((p, from)) => {
                window.request_animation_frame();
                let eased = specs::REGEN_CROSSFADE.curve.sample(p);
                let size = if cx.reduce_motion() { 1. } else { eased };
                Crossfade::new(
                    ElementId::Name(format!("answer-crossfade-{mk}").into()),
                    div().opacity(eased).child(column),
                )
                .from(
                    div()
                        .id(ElementId::Name(format!("answer-leaving-{mk}").into()))
                        .opacity(1. - eased)
                        .child(from),
                    size,
                )
                .into_any_element()
            }
            None => Crossfade::new(
                ElementId::Name(format!("answer-crossfade-{mk}").into()),
                column,
            )
            .into_any_element(),
        };

        let spoken = self.spoken(cx);
        let name = if model.is_empty() {
            "Assistant".to_string()
        } else {
            model.clone()
        };
        let label = if item.streaming {
            format!("{}: {spoken}", l10n.desktop_writing(&name))
        } else {
            format!("{name}: {spoken}")
        };

        let row_focus = self
            .row_focus
            .get_or_insert_with(|| cx.focus_handle())
            .clone();
        div()
            .id(ElementId::Name(format!("message-{key}").into()))
            .track_focus(&row_focus)
            .role(Role::Article)
            .aria_label(SharedString::from(label))
            .w_full()
            .flex()
            .flex_col()
            .gap(px(6.))
            .on_hover(cx.listener(|this, hovered: &bool, _, cx| {
                if this.hovered != *hovered {
                    this.hovered = *hovered;
                    cx.notify();
                }
            }))
            // The phone's answer header: the model's glyph and its name in
            // the secondary tone, over a reply that shares its edge. The
            // glyph stands alone at 15 pt (as an SF Symbol beside a label),
            // not shrunk into a tile.
            .child(
                div()
                    .h(px(16.))
                    .flex()
                    .items_center()
                    .gap(px(5.))
                    .child(icon(IconName::Sparkles, 15., r.text_subtle))
                    .child(
                        div()
                            .text_size(px(m.small))
                            .text_color(r.text_subtle)
                            .child(SharedString::from(name)),
                    ),
            )
            .child(content)
    }
}

/// "Waiting for the answer…": a soft band of highlight gliding along it, or
/// under Reduce Motion a still line beside a spinner (an activity
/// indicator, which macOS keeps turning under Reduce Motion).
fn waiting_line(
    mk: &str,
    t: &ConduitTheme,
    l10n: &crate::l10n::L10n,
    window: &mut Window,
    cx: &App,
) -> AnyElement {
    let (r, m) = (t.roles, t.metrics);
    let text = SharedString::from(l10n.desktop_waiting_for_answer());
    let line = div()
        .id(ElementId::Name(format!("waiting-{mk}").into()))
        .flex()
        .items_center()
        .gap(px(6.))
        .h(px(22.))
        .text_size(px(m.control))
        .text_color(r.text_subtle);
    if cx.reduce_motion() {
        line.child(spinner(
            ElementId::Name(format!("waiting-spinner-{mk}").into()),
            13.,
            r.text_faint,
        ))
        .child(text)
        .into_any_element()
    } else {
        line.child(motion::shimmer_text(
            text,
            m.control,
            r.text_subtle,
            r.text,
            window,
            cx,
        ))
        .into_any_element()
    }
}

fn follow_up_list(
    key: &str,
    items: &[String],
    host: &RowHost,
    t: &ConduitTheme,
    cx: &App,
) -> AnyElement {
    let r = t.roles;
    let m = t.metrics;
    let l10n = cx.l10n().clone();
    // The phone's suggestions: a heading, then one outlined row each across
    // the column.
    div()
        .flex()
        .flex_col()
        .gap(px(6.))
        .pt(px(4.))
        .child(
            div()
                .id(ElementId::Name(format!("follow-ups-heading-{key}").into()))
                .role(Role::Heading)
                .aria_label(SharedString::from(l10n.desktop_suggestions_heading()))
                .text_size(px(m.small))
                .font_weight(FontWeight::SEMIBOLD)
                .text_color(r.text_subtle)
                .child(SharedString::from(l10n.desktop_suggestions_heading())),
        )
        .child(
            div()
                .id(ElementId::Name(format!("follow-ups-{key}").into()))
                .role(Role::List)
                .aria_label(SharedString::from(l10n.desktop_suggestions_heading()))
                .flex()
                .flex_col()
                .gap(px(6.))
                .children(items.iter().enumerate().map(|(i, text)| {
                    let pane = host.pane.clone();
                    let send = text.clone();
                    // Quiet rows that share the column's card radius: a
                    // hairline at half strength, the text in the secondary
                    // tone until hovered, an arrow saying where it goes.
                    div()
                        .id(ElementId::Name(format!("follow-up-{key}-{i}").into()))
                        .role(Role::Button)
                        .aria_label(SharedString::from(text.clone()))
                        .w_full()
                        .min_h(px(m.row_height + 4.))
                        .px(px(10.))
                        .py(px(5.))
                        .flex()
                        .items_center()
                        .gap(px(8.))
                        .rounded(t.card_radius())
                        .border_1()
                        .border_color(with_alpha(r.border, 0.6))
                        .cursor_pointer()
                        .hover(|s| s.bg(r.hover))
                        .keyboard_border(cx)
                        .text_size(px(m.control))
                        .line_height(relative(1.35))
                        .text_color(r.text)
                        .child(
                            div()
                                .flex_1()
                                .min_w_0()
                                .child(SharedString::from(text.clone())),
                        )
                        .child(icon(IconName::ArrowUp, 12., r.text_subtle).flex_none())
                        .on_click(move |_, window, cx| {
                            let text = send.clone();
                            pane.send(text, window, cx);
                        })
                })),
        )
        .into_any_element()
}

// ── Questions ──────────────────────────────────────────────────────────────

pub struct UserRow {
    host: RowHost,
    item: RowItem,
    flags: RowFlags,
    hovered: bool,
    editor: Option<Entity<TextareaState>>,
    _editor: Option<Subscription>,
    actions_focus: Option<gpui_kit::FocusHandle>,
    /// The whole row's focus scope (not a stop): which row Tab is in.
    row_focus: Option<gpui_kit::FocusHandle>,
    /// Find in Chat's matches in the text, with their fills.
    find: Vec<(std::ops::Range<usize>, gpui_kit::Hsla)>,
}

impl UserRow {
    pub fn new(host: RowHost, item: RowItem, flags: RowFlags) -> Self {
        Self {
            host,
            item,
            flags,
            hovered: false,
            editor: None,
            _editor: None,
            actions_focus: None,
            row_focus: None,
            find: vec![],
        }
    }

    pub fn set(&mut self, item: RowItem, flags: RowFlags, cx: &mut Context<Self>) {
        if item == self.item && flags == self.flags {
            return;
        }
        self.item = item;
        self.flags = flags;
        cx.notify();
    }

    /// The question's text, as the bubble shows it.
    pub fn item_text(&self) -> &str {
        &self.item.text
    }

    /// Find in Chat's matches in the text (byte ranges), painted behind it.
    pub fn set_find_highlights(
        &mut self,
        ranges: Vec<(std::ops::Range<usize>, gpui_kit::Hsla)>,
        cx: &mut Context<Self>,
    ) {
        if ranges != self.find {
            self.find = ranges;
            cx.notify();
        }
    }

    pub fn editing(&self) -> bool {
        self.editor.is_some()
    }

    /// Edit in place: the bubble becomes a field with Cancel and Send.
    pub fn start_editing(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if !self.flags.can_branch || !self.item.stored {
            return;
        }
        let text = self.item.text.clone();
        let label = cx.l10n().desktop_edit_message_label();
        let editor = cx.new(|cx| {
            let mut s = TextareaState::new(window, cx)
                .auto_grow(1, 12)
                .submit_on_enter(true);
            s.set_value(text, window, cx);
            s
        });
        editor.update(cx, |s, cx| s.focus(window, cx));
        let sub = cx.subscribe_in(
            &editor,
            window,
            |this, state, e: &InputEvent, window, cx| {
                if let InputEvent::PressEnter {
                    shift: false,
                    secondary: false,
                } = e
                {
                    let composing =
                        state.update(cx, |s, cx| s.marked_text_range(window, cx).is_some());
                    if !composing {
                        this.save(cx);
                    }
                }
            },
        );
        let _ = label;
        self.editor = Some(editor);
        self._editor = Some(sub);
        cx.notify();
    }

    pub fn cancel(&mut self, cx: &mut Context<Self>) {
        self.editor = None;
        self._editor = None;
        cx.notify();
    }

    /// Sends the edited text (`turns.edit`).
    pub fn save(&mut self, cx: &mut Context<Self>) {
        let Some(editor) = &self.editor else {
            return;
        };
        let text = editor.read(cx).value().to_string();
        if text.trim().is_empty() || text == self.item.text {
            self.cancel(cx);
            return;
        }
        let key = self.item.key.clone();
        let _ = self
            .host
            .store
            .update(cx, |s, cx| s.edit(&key, text.trim().to_string(), cx));
        self.cancel(cx);
    }
}

impl Render for UserRow {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let t = cx.conduit().clone();
        let l10n = cx.l10n().clone();
        let r = t.roles;
        let m = t.metrics;
        let item = self.item.clone();
        let key = item.key.clone();
        let label = format!("{}: {}", l10n.you(), item.text);
        let files = (!item.files.is_empty()).then(|| {
            file_list(
                &format!("user-{key}"),
                &item.files,
                self.host.server_id.as_deref(),
                &l10n,
                &t,
                window,
                cx,
            )
            .justify_end()
        });

        let row_focus = self
            .row_focus
            .get_or_insert_with(|| cx.focus_handle())
            .clone();
        let article = div()
            .id(ElementId::Name(format!("message-{key}").into()))
            .track_focus(&row_focus)
            .role(Role::Article)
            .aria_label(SharedString::from(label))
            .w_full()
            .flex()
            .flex_col()
            .items_end()
            .gap(px(6.))
            .on_hover(cx.listener(|this, hovered: &bool, _, cx| {
                if this.hovered != *hovered {
                    this.hovered = *hovered;
                    cx.notify();
                }
            }));

        if let Some(editor) = &self.editor {
            return article.child(
                div()
                    .w_full()
                    .max_w(relative(0.85))
                    .p(px(8.))
                    .flex()
                    .flex_col()
                    .gap(px(6.))
                    .rounded(px(16.))
                    .border_1()
                    .border_color(r.focus)
                    .bg(t.surfaces.panel)
                    .child(
                        div().px(px(6.)).text_size(px(m.body)).child(
                            Textarea::new(editor)
                                .appearance(false)
                                .bordered(false)
                                .text_size(px(m.body))
                                .aria_label(l10n.desktop_edit_message_label())
                                .accessibility_id("edit-message-input"),
                        ),
                    )
                    .child(
                        div()
                            .flex()
                            .justify_end()
                            .gap(px(6.))
                            .child(
                                conduit_components::views::kit::Button::new(
                                    ElementId::Name(format!("edit-cancel-{key}").into()),
                                    l10n.cancel(),
                                )
                                .on_click(std::rc::Rc::new({
                                    let this = cx.entity().downgrade();
                                    move |_, _, cx| {
                                        let _ = this.update(cx, |row, cx| row.cancel(cx));
                                    }
                                })),
                            )
                            .child(
                                conduit_components::views::kit::Button::new(
                                    ElementId::Name(format!("edit-send-{key}").into()),
                                    l10n.send(),
                                )
                                .primary()
                                .on_click(std::rc::Rc::new({
                                    let this = cx.entity().downgrade();
                                    move |_, _, cx| {
                                        let _ = this.update(cx, |row, cx| row.save(cx));
                                    }
                                })),
                            ),
                    ),
            );
        }

        let actions_focus = conduit_components::views::focus::control_focus_handle(
            &ElementId::Name(format!("question-actions-{key}").into()),
            window,
            cx,
        );
        self.actions_focus = Some(actions_focus.clone());
        let visible = self.hovered || actions_focus.contains_focused(window, cx);
        let pane = self.host.pane.clone();
        let copy_value = item.text.clone();
        let this = cx.entity().downgrade();
        // Copy and Edit show beside the bubble, at its leading edge, on
        // hover (and while Tab has one): they take no height, so a question
        // sits as close over its answer whether or not they show.
        let actions = div()
            // Shown on hover, and while Tab has one of its buttons.
            .track_focus(&actions_focus)
            .on_mouse_down(gpui_kit::MouseButton::Left, |_, window, _| {
                window.prevent_default()
            })
            .flex_none()
            .flex()
            .items_center()
            .gap(px(2.))
            .opacity(if visible { 1. } else { 0. })
            .child(
                small_action(
                    format!("copy-{key}"),
                    IconName::Copy,
                    l10n.copy().into(),
                    false,
                    &t,
                )
                .on_click(std::rc::Rc::new(move |_, _, cx| {
                    copy_text(&copy_value, &pane, cx)
                })),
            )
            .when(self.flags.can_branch && item.stored, |d| {
                d.child(
                    small_action(
                        format!("edit-{key}"),
                        IconName::Pencil,
                        l10n.edit().into(),
                        false,
                        &t,
                    )
                    .on_click(std::rc::Rc::new(move |_, window, cx| {
                        let _ = this.update(cx, |row, cx| row.start_editing(window, cx));
                    })),
                )
            });
        let bubble = (!item.text.is_empty()).then(|| {
            div()
                .min_w_0()
                .max_w(relative(0.78))
                .px(px(14.))
                .py(px(9.))
                .rounded(px(18.))
                .bg(r.bubble)
                .text_size(px(m.body))
                .line_height(relative(m.leading - 0.05))
                .text_color(r.text)
                .child(
                    gpui_kit::StyledText::new(SharedString::from(item.text.clone()))
                        .with_highlights(self.find.iter().map(|(range, fill)| {
                            (
                                range.clone(),
                                gpui_kit::HighlightStyle {
                                    background_color: Some(*fill),
                                    ..Default::default()
                                },
                            )
                        })),
                )
        });
        article.children(files).child(
            div()
                .w_full()
                .flex()
                .justify_end()
                .items_end()
                .gap(px(4.))
                // Level with a one-line bubble; by its last line on a longer
                // one.
                .child(div().mb(px(5.)).child(actions))
                .children(bubble),
        )
    }
}

/// A row's view: an answer or a question.
#[derive(Clone)]
pub enum RowView {
    Assistant(Entity<AssistantRow>),
    User(Entity<UserRow>),
}

impl RowView {
    pub fn new(host: RowHost, item: RowItem, flags: RowFlags, cx: &mut App) -> Self {
        match item.role {
            MessageRole::Assistant => {
                Self::Assistant(cx.new(|_| AssistantRow::new(host, item, flags)))
            }
            MessageRole::User => Self::User(cx.new(|_| UserRow::new(host, item, flags))),
        }
    }

    /// Updates the row; false when it is the wrong kind for `item`.
    pub fn set(&self, item: RowItem, flags: RowFlags, cx: &mut App) -> bool {
        match (self, item.role) {
            (Self::Assistant(e), MessageRole::Assistant) => {
                e.update(cx, |r, cx| r.set(item, flags, cx));
                true
            }
            (Self::User(e), MessageRole::User) => {
                e.update(cx, |r, cx| r.set(item, flags, cx));
                true
            }
            _ => false,
        }
    }

    /// Whether keyboard focus is on one of the row's buttons.
    pub fn has_focus(&self, window: &Window, cx: &App) -> bool {
        let handle = match self {
            Self::Assistant(e) => e.read(cx).actions_focus.clone(),
            Self::User(e) => e.read(cx).actions_focus.clone(),
        };
        handle.is_some_and(|h| h.contains_focused(window, cx))
    }

    /// The row's own focus scope (not a stop), once drawn.
    pub fn row_focus(&self, cx: &App) -> Option<gpui_kit::FocusHandle> {
        match self {
            Self::Assistant(e) => e.read(cx).row_focus.clone(),
            Self::User(e) => e.read(cx).row_focus.clone(),
        }
    }

    /// Whether focus is anywhere in the row (its actions, suggestions, a
    /// disclosure, Retry…).
    pub fn contains_focus(&self, window: &Window, cx: &App) -> bool {
        let handle = match self {
            Self::Assistant(e) => e.read(cx).row_focus.clone(),
            Self::User(e) => e.read(cx).row_focus.clone(),
        };
        handle.is_some_and(|h| h.contains_focused(window, cx))
    }

    /// The action row's focus scope, once drawn.
    #[cfg(test)]
    pub fn actions_focus(&self, cx: &App) -> Option<gpui_kit::FocusHandle> {
        match self {
            Self::Assistant(e) => e.read(cx).actions_focus.clone(),
            Self::User(e) => e.read(cx).actions_focus.clone(),
        }
    }

    pub fn element(&self) -> AnyElement {
        match self {
            Self::Assistant(e) => e.clone().into_any_element(),
            Self::User(e) => e.clone().into_any_element(),
        }
    }

    /// The room the row keeps above and below its message (see
    /// [`rhythm`]).
    pub fn padding(&self) -> (f32, f32) {
        match self {
            Self::Assistant(_) => (rhythm::ANSWER_TOP, 0.),
            Self::User(_) => (rhythm::QUESTION_TOP, rhythm::QUESTION_BOTTOM),
        }
    }
}

/// Whether a block draws as an activity line ("Searched 3 sites",
/// "Thought for 6 seconds", "Used Tide Table · Port Wren", "Ran code").
fn is_activity(kind: MessageBlockKind) -> bool {
    matches!(
        kind,
        MessageBlockKind::Status
            | MessageBlockKind::Reasoning
            | MessageBlockKind::ToolCalls
            | MessageBlockKind::CodeInterpreter
            | MessageBlockKind::CodeExecution
            | MessageBlockKind::Details
    )
}

/// The runs of `flags` (start, end, value): consecutive equal flags.
fn runs(flags: &[bool]) -> Vec<(usize, usize, bool)> {
    let mut out: Vec<(usize, usize, bool)> = vec![];
    for (i, &f) in flags.iter().enumerate() {
        match out.last_mut() {
            Some((_, end, value)) if *value == f => *end = i + 1,
            _ => out.push((i, i + 1, f)),
        }
    }
    out
}

/// An answer's blocks with each run of activity lines as one group on one
/// pitch ([`ACTIVITY_ROW`] rows, [`ACTIVITY_GAP`] apart), standing
/// [`rhythm::ACTIVITY_RUN`] from the text around it.
fn group_activity(parts: Vec<(bool, AnyElement)>) -> Vec<AnyElement> {
    let flags: Vec<bool> = parts.iter().map(|(a, _)| *a).collect();
    let spans = runs(&flags);
    let count = spans.len();
    let mut parts = parts.into_iter();
    let mut out = vec![];
    for (n, (start, end, activity)) in spans.into_iter().enumerate() {
        let run: Vec<AnyElement> = parts.by_ref().take(end - start).map(|(_, e)| e).collect();
        if !activity {
            out.extend(run);
            continue;
        }
        // The column's own gap, plus what makes up a run's.
        let extra = rhythm::ACTIVITY_RUN - rhythm::BLOCK_GAP;
        out.push(
            div()
                .flex()
                .flex_col()
                .gap(px(ACTIVITY_GAP))
                .when(n > 0, |d| d.mt(px(extra)))
                .when(n + 1 < count, |d| d.mb(px(extra)))
                .children(run)
                .into_any_element(),
        );
    }
    out
}

/// The text states block `ordinal` is read from: one per chunk of a long
/// answer once it has them (the whole-block state made while it streamed
/// short holds only its start), else the one state.
fn spoken_keys(ordinal: usize, has: impl Fn(&str) -> bool) -> Vec<String> {
    let chunks: Vec<String> = (0..)
        .map(|k| format!("text{ordinal}.{k}"))
        .take_while(|k| has(k))
        .collect();
    if !chunks.is_empty() {
        return chunks;
    }
    let whole = format!("text{ordinal}");
    if has(&whole) { vec![whole] } else { vec![] }
}

#[cfg(test)]
mod activity_tests {
    use super::*;

    #[test]
    fn a_long_answer_is_spoken_from_its_chunks_not_its_first_state() {
        let made = ["text0", "text0.0", "text0.1", "text1"];
        let has = |k: &str| made.contains(&k);
        assert_eq!(spoken_keys(0, has), vec!["text0.0", "text0.1"]);
        assert_eq!(spoken_keys(1, has), vec!["text1"]);
        assert!(spoken_keys(2, has).is_empty());
    }

    #[test]
    fn activity_lines_run_together_between_text() {
        assert_eq!(runs(&[]), vec![]);
        assert_eq!(
            runs(&[true, true, true, false, true, false, false]),
            vec![(0, 3, true), (3, 4, false), (4, 5, true), (5, 7, false)]
        );
        assert!(is_activity(MessageBlockKind::Reasoning));
        assert!(is_activity(MessageBlockKind::ToolCalls));
        assert!(!is_activity(MessageBlockKind::Text));
        assert!(!is_activity(MessageBlockKind::Files));
        assert!(!is_activity(MessageBlockKind::Error));
    }

    fn answer(blocks: Vec<conduit_protocol::MessageBlockDto>, text: &str) -> RowItem {
        RowItem {
            key: "a1".into(),
            role: MessageRole::Assistant,
            text: text.into(),
            blocks,
            files: vec![],
            sources: vec![],
            model: None,
            timestamp_ms: None,
            streaming: false,
            rating: None,
            version: None,
            stored: true,
            last_answer: true,
            stale: false,
        }
    }

    #[test]
    fn a_failed_answer_offers_only_more_beside_its_retry() {
        use crate::stores::chat::empty_block;
        let l10n = crate::l10n::L10n::new("en");
        let flags = RowFlags {
            can_branch: true,
            can_follow_up: true,
        };
        let error = conduit_protocol::MessageBlockDto {
            error: Some("The tide service did not answer in time.".into()),
            ..empty_block(MessageBlockKind::Error)
        };
        // Nothing written before it failed: More copies the error alone.
        let offer = AnswerActions::of(&answer(vec![error.clone()], ""), flags, &l10n);
        assert_eq!(
            offer,
            AnswerActions {
                copy_error: Some("The tide service did not answer in time.".into()),
                ..AnswerActions::default()
            }
        );
        // Some words, then the error: they can be copied from More too.
        let text = conduit_protocol::MessageBlockDto {
            markdown: Some("High water is at".into()),
            ..empty_block(MessageBlockKind::Text)
        };
        let offer = AnswerActions::of(&answer(vec![text.clone(), error], ""), flags, &l10n);
        assert!(!offer.copy && !offer.regenerate && !offer.rate);
        assert!(offer.copy_markdown && offer.copy_error.is_some());
        // A server that gave no words: a plain sentence.
        let bare = empty_block(MessageBlockKind::Error);
        let offer = AnswerActions::of(&answer(vec![bare], ""), flags, &l10n);
        assert_eq!(
            offer.copy_error.as_deref(),
            Some(l10n.desktop_something_went_wrong().as_str())
        );
        // A finished answer keeps Copy, Regenerate and the rating.
        let offer = AnswerActions::of(&answer(vec![text], "High water is at"), flags, &l10n);
        assert!(offer.copy && offer.regenerate && offer.rate && offer.copy_markdown);
        assert_eq!(offer.copy_error, None);
    }
}

/// The transcript's vertical rhythm, as Messages and the chat apps group a
/// turn: a question sits close over its answer, and turns stand a constant
/// [`TURN_GAP`](rhythm::TURN_GAP) apart, whether or not an answer's action
/// row is showing (its room is kept, inside that gap).
pub mod rhythm {
    /// From a question's bubble to its answer's header.
    pub const QUESTION_TO_ANSWER: f32 = 24.;
    /// From the end of an answer's text (or of a list under its actions) to
    /// the next question.
    pub const TURN_GAP: f32 = 40.;
    /// Between an answer's blocks (text, images, files).
    pub const BLOCK_GAP: f32 = 10.;
    /// Between a run of activity lines and the text before or after it
    /// (the first heading).
    pub const ACTIVITY_RUN: f32 = 12.;
    /// From an answer's last block to its action row.
    pub const ACTIONS_GAP: f32 = 2.;
    /// The action row's height (its 28 pt buttons).
    pub const ACTIONS_HEIGHT: f32 = 28.;
    /// A question row's room above its bubble: what is left of the turn
    /// gap under the answer before it.
    pub const QUESTION_TOP: f32 = TURN_GAP - ACTIONS_GAP - ACTIONS_HEIGHT;
    pub const QUESTION_BOTTOM: f32 = 12.;
    pub const ANSWER_TOP: f32 = QUESTION_TO_ANSWER - QUESTION_BOTTOM;
    /// Under a list that follows the action row (sources), so the next
    /// question still sits a turn gap from its last line (whose row keeps
    /// ~6 pt of its own under the text).
    pub const AFTER_LIST: f32 = TURN_GAP - QUESTION_TOP - 6.;
}
