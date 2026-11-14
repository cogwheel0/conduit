//! One transcript row each: the user's messages (right-aligned bubbles,
//! edited in place) and the answers (typed blocks, then the action row).
//!
//! Every message is a labelled `Role::Article` carrying its text (a bare
//! TextView is invisible to VoiceOver). Actions:
//!
//! * answers: the message actions ([`super::actions`]: Copy, Regenerate,
//!   Retry Without Reasoning Effort, Merge Responses, Info, Branch in New
//!   Chat, Share and Delete, inline or in More as Settings › Chat says),
//!   Regenerate With, Copy as Markdown and the thumbs (`turns.rate`) in
//!   More, the version arrows and their list (`n / N`, switching the
//!   chat's branch on the server), and the sources pill once finished;
//!   a Compare Models answer draws each model's answer as a column, with
//!   Continue from Here on the others, and a merged response under them;
//! * questions: copy, edit in place (`turns.edit`), their versions, and
//!   Delete in More.
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

use super::actions::{MessageAction, RowCommand, RowContext, RunRowCommand};
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
                let _ = p.update(cx, |p, cx| p.send_text(text, vec![], window, cx));
            }
            Self::QuickAsk(q) => {
                let _ = q.update(cx, |q, cx| q.send_text(text, vec![], window, cx));
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
    /// The models on offer, by id and name (Regenerate With).
    pub fn models(&self, cx: &App) -> Vec<(String, String)> {
        self.composer
            .as_ref()
            .and_then(WeakEntity::upgrade)
            .and_then(|c| {
                c.read(cx).models.as_ref().map(|m| {
                    m.models
                        .iter()
                        .map(|m| (m.id.clone(), m.name.clone()))
                        .collect()
                })
            })
            .unwrap_or_default()
    }

    /// `model` (an id) as the picker names it (a coding agent as "Codex ·
    /// gpt-5.1", even once its terminal no longer offers it), else as it is.
    pub fn model_name(&self, model: &str, cx: &App) -> String {
        self.composer
            .as_ref()
            .and_then(WeakEntity::upgrade)
            .and_then(|c| {
                let list = c.read(cx).models.as_ref()?;
                crate::stores::composer::find_model(list, model)
                    .map(|m| m.name.clone())
                    .or_else(|| list.agent_names.get(model).cloned())
            })
            .unwrap_or_else(|| model.to_string())
    }

    /// The chat talks to a coding agent (the composer's
    /// `ComposerOptions.agentChat`).
    pub fn agent_chat(&self, cx: &App) -> bool {
        self.composer
            .as_ref()
            .and_then(WeakEntity::upgrade)
            .is_some_and(|c| c.read(cx).options.agent_chat)
    }
}

/// Per-row flags from the chat.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct RowFlags {
    /// Edit, regenerate and rate apply (a stored chat, nothing streaming).
    pub can_branch: bool,
    /// Follow-ups are offered (never in a read-only chat).
    pub can_follow_up: bool,
    /// What the chat offers (fork, delete, merge, branch, ...).
    pub abilities: conduit_protocol::ChatAbilities,
    /// A merge runs in the chat.
    pub merging: bool,
    /// Settings › Chat › Message Actions: the actions shown inline, in
    /// order, or `None` for Automatic.
    pub actions: Option<Vec<String>>,
    /// The answer being read aloud (its shown version's id), if any.
    pub reading: Option<String>,
    /// A Hermes session's chat: its answers are not rated, nor run again
    /// with another model (the agent is the model).
    pub hermes: bool,
    /// A coding agent answers the chat (`ComposerOptions.agentChat`): Open
    /// WebUI takes only a new message at its end, so no answer is run
    /// again (Regenerate, Retry) and no message is edited.
    pub agent_chat: bool,
}

impl RowFlags {
    /// An answer may be run again (Regenerate, Retry, Regenerate With).
    pub fn can_regenerate(&self) -> bool {
        self.can_branch && !self.agent_chat
    }

    /// A sent message may be edited and sent again.
    pub fn can_edit(&self) -> bool {
        self.can_branch && !self.agent_chat
    }
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
    super::actions::register(cx);
    super::speech_bar::register(cx);
    super::composer::register_actions(cx);
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
    /// The message actions it offers, in Settings' order (laid out inline
    /// or in More by [`super::actions::layout`]).
    pub available: Vec<MessageAction>,
    /// Good Answer / Bad Answer in More.
    pub rate: bool,
    /// More › Regenerate With, beside Regenerate.
    pub regenerate_with: bool,
    /// More › Copy Error Details, with what it copies.
    pub copy_error: Option<String>,
    /// More › Copy as Markdown.
    pub copy_markdown: bool,
}

impl AnswerActions {
    /// What an answer offers. A failed answer's banner has Retry, which is
    /// the way on: its row keeps no second Retry (Regenerate), no Copy of
    /// nothing and no rating; More copies what went wrong (and what was
    /// written before it failed). Retry Without Reasoning Effort, Info,
    /// Branch in New Chat and Delete still apply. `pane` is the main
    /// window's chat (Quick Ask keeps to copying and regenerating).
    pub fn of(item: &RowItem, flags: &RowFlags, pane: bool, l10n: &crate::l10n::L10n) -> Self {
        use MessageAction as A;
        let error = item
            .blocks
            .iter()
            .find(|b| b.kind == MessageBlockKind::Error)
            .map(|b| error_text(b, l10n));
        let ab = &flags.abilities;
        let stored = item.stored && !item.streaming;
        let mut available = vec![];
        if error.is_none() {
            available.push(A::Copy);
            // The main window's: its bar follows the reading.
            if pane && !item.streaming && !answer_markdown(item).trim().is_empty() {
                available.push(A::ReadAloud);
            }
            if flags.can_regenerate() {
                available.push(A::Regenerate);
            }
        }
        if item.retry_without_effort && flags.can_regenerate() {
            available.push(A::RetryWithoutEffort);
        }
        let mergeable = item.columns.len() > 1 && item.mergeable.len() > 1;
        if pane && error.is_none() && ((ab.merge && mergeable && !flags.merging) || item.merging) {
            available.push(A::Merge);
        }
        if super::popovers::has_usage(item.usage.as_ref()) {
            available.push(A::Usage);
        }
        if pane && ab.fork && stored && flags.can_branch {
            available.push(A::Fork);
        }
        // A Hermes chat's history, from the reply its session keeps (not an
        // older version shown in its place); Undo from its last reply.
        let kept = item.version.is_none_or(|(s, n)| s == n);
        if pane && ab.branch_from_here && stored && flags.can_branch && kept {
            available.push(A::BranchFromHere);
        }
        if pane && ab.undo_last_turn && stored && flags.can_branch && item.last_answer {
            available.push(A::UndoLastTurn);
        }
        if error.is_none() && !answer_markdown(item).is_empty() && !item.streaming {
            available.push(A::Share);
        }
        if pane && ab.delete_messages && stored && flags.can_branch {
            available.push(A::Delete);
        }
        let current = item.version.is_none_or(|(s, n)| s == n) || !item.siblings.is_empty();
        Self {
            available,
            rate: error.is_none() && flags.can_branch && current && !flags.hermes,
            regenerate_with: error.is_none() && flags.can_regenerate() && !flags.hermes,
            copy_markdown: error.is_none() || !answer_markdown(item).is_empty(),
            copy_error: error,
        }
    }
}

/// An action's glyph. `reading`: the answer is being read aloud.
fn action_icon(a: MessageAction, merging: bool, reading: bool) -> IconName {
    match a {
        MessageAction::Copy => IconName::Copy,
        MessageAction::ReadAloud if reading => IconName::Square,
        MessageAction::ReadAloud => IconName::AudioLines,
        MessageAction::Regenerate => IconName::RotateCcw,
        MessageAction::RetryWithoutEffort => IconName::CircleSlash,
        MessageAction::Merge if merging => IconName::Square,
        MessageAction::Merge => IconName::GitMerge,
        MessageAction::Usage => IconName::Info,
        MessageAction::Fork => IconName::GitBranch,
        MessageAction::BranchFromHere => IconName::Split,
        MessageAction::UndoLastTurn => IconName::Undo2,
        MessageAction::Share => IconName::Share,
        MessageAction::Delete => IconName::Trash,
    }
}

/// An action's label (its tooltip, VoiceOver's name, its menu item).
fn action_label(
    a: MessageAction,
    merging: bool,
    reading: bool,
    menu: bool,
    l10n: &crate::l10n::L10n,
) -> String {
    match a {
        MessageAction::Copy => l10n.copy(),
        MessageAction::ReadAloud if reading => l10n.desktop_stop_speaking(),
        MessageAction::ReadAloud => l10n.desktop_read_aloud(),
        MessageAction::Regenerate => l10n.regenerate(),
        MessageAction::RetryWithoutEffort => l10n.retry_without_reasoning_effort(),
        MessageAction::Merge if merging => l10n.chat_merge_stop_action(),
        MessageAction::Merge => l10n.chat_merge_responses_action(),
        MessageAction::Usage => l10n.usage_info(),
        MessageAction::Fork => l10n.chat_branch_fork_chat(),
        MessageAction::BranchFromHere => l10n.hermes_branch_from_here(),
        MessageAction::UndoLastTurn => l10n.hermes_undo_last_turn(),
        MessageAction::Share => l10n.share_system_sheet(),
        MessageAction::Delete if menu => l10n.desktop_delete_ellipsis(),
        MessageAction::Delete => l10n.delete(),
    }
}

/// What choosing `a` does for `item`.
fn action_command(a: MessageAction, item: &RowItem) -> RowCommand {
    match a {
        MessageAction::Copy => RowCommand::Copy(item.text.clone()),
        MessageAction::ReadAloud => RowCommand::ReadAloud,
        MessageAction::Regenerate => RowCommand::Regenerate(None),
        MessageAction::RetryWithoutEffort => RowCommand::RetryWithoutEffort,
        MessageAction::Merge if item.merging => RowCommand::StopMerge,
        MessageAction::Merge => RowCommand::Merge,
        MessageAction::Usage => RowCommand::Usage,
        MessageAction::Fork => RowCommand::Fork,
        MessageAction::BranchFromHere => RowCommand::BranchFromHere,
        MessageAction::UndoLastTurn => RowCommand::UndoLastTurn,
        MessageAction::Share => RowCommand::Share(answer_markdown(item)),
        MessageAction::Delete => RowCommand::Delete,
    }
}

/// The id of the answer `item` shows (a version's while one is shown).
pub fn shown_answer_id(item: &RowItem) -> String {
    item.version
        .and_then(|(at, _)| item.siblings.get(at.wrapping_sub(1)).cloned())
        .unwrap_or_else(|| item.key.clone())
}

impl RowHost {
    /// The context an action on `item` runs in, asked at `position`.
    pub fn context(
        &self,
        item: &RowItem,
        position: gpui_kit::Point<gpui_kit::Pixels>,
    ) -> RowContext {
        let target = shown_answer_id(item);
        RowContext {
            store: self.store.clone(),
            pane: match &self.pane {
                RowSink::Pane(p) => Some(p.clone()),
                _ => None,
            },
            key: item.key.clone(),
            target,
            mergeable: item.mergeable.clone(),
            position,
        }
    }
}

/// Says which version the arrows landed on (VoiceOver; focus stays on the
/// arrow), as the phone's switcher says it.
fn announce_version(step: Option<crate::stores::chat::VersionStep>, cx: &mut App) {
    if let Some(step) = step {
        let text = step.spoken(cx.l10n());
        conduit_components::announce::announce(
            text,
            conduit_components::announce::Priority::High,
            cx,
        );
    }
}

fn copy_text(text: &str, pane: &RowSink, cx: &mut App) {
    cx.write_to_clipboard(ClipboardItem::new_string(text.to_string()));
    pane.copied(cx);
}

/// A question as it reads: Open WebUI's mention tokens (`<@U:id|Riley>`,
/// `<$id|Plain English>`) shown as their names (`@Riley`, `$Plain English`),
/// as conduit_markdown's `MentionInlineSyntax` shows the `@` ones on the
/// phone.
pub fn shown_mentions(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut rest = text;
    while let Some(at) = rest.find('<') {
        out.push_str(&rest[..at]);
        let tail = &rest[at..];
        let token = tail.find('>').and_then(|end| {
            let inner = &tail[1..end];
            let (head, label) = inner.split_once('|')?;
            let sigil = if let Some(id) = head.strip_prefix('$') {
                (!id.is_empty()).then_some('$')
            } else {
                let kind = head.strip_prefix('@')?;
                let (t, id) = kind.split_once(':')?;
                (t.len() == 1 && t.chars().all(|c| c.is_ascii_uppercase()) && !id.is_empty())
                    .then_some('@')
            }?;
            (!label.is_empty() && !label.contains('<')).then(|| (format!("{sigil}{label}"), end))
        });
        match token {
            Some((shown, end)) => {
                out.push_str(&shown);
                rest = &tail[end + 1..];
            }
            None => {
                out.push('<');
                rest = &tail[1..];
            }
        }
    }
    out.push_str(rest);
    out
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
    /// A Compare Models answer's columns: one view each, by answer id.
    compare: Vec<(String, Entity<AssistantRow>)>,
    /// This view draws one column of a comparison.
    column_of: Option<ColumnOf>,
    /// Rich content in the answer, by its place (kept across frames, so
    /// an opened page stays open).
    embeds: HashMap<String, Entity<super::embed::EmbedView>>,
}

/// One column of a Compare Models answer.
#[derive(Clone, Debug, PartialEq)]
struct ColumnOf {
    /// The answer the chat goes on from.
    current: bool,
    /// The message the comparison belongs to.
    message: String,
}

/// What a regenerate's old answer showed, drawn while it crossfades into
/// the new one.
struct Leaving {
    item: RowItem,
    texts: HashMap<String, (String, Entity<TextViewState>)>,
    /// Its disclosures that were open.
    expanded: HashSet<String>,
    /// Its pages and MCP Apps, its own while it fades (the new answer's
    /// embeds may have the same keys).
    embeds: HashMap<String, Entity<super::embed::EmbedView>>,
    follow_ups: Option<Vec<String>>,
    start: Instant,
}

/// What a queued answer's button does.
#[derive(Clone, Copy)]
enum QueuedAction {
    Retry,
    RetryWithout,
    Remove,
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
            actions_focus: None,
            finished: None,
            _settle: None,
            motion_key: format!("answer{}", ROW_SERIAL.fetch_add(1, Ordering::Relaxed)),
            paces: HashMap::new(),
            follow_ups_shown: None,
            stale_follow_ups: None,
            leaving: None,
            row_focus: None,
            compare: vec![],
            column_of: None,
            embeds: HashMap::new(),
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
                embeds: std::mem::take(&mut self.embeds),
                follow_ups: self.stale_follow_ups.take(),
                start: now,
            });
            self.opening.clear();
            self.paces.clear();
        }
        self.item = item;
        self.flags = flags;
        // An embed the answer no longer has (a new version, a replaced
        // answer) goes, its page and MCP App with it; a leaving answer keeps
        // its own until it has faded.
        let keep = super::blocks::embed_ids(&self.item.blocks);
        self.embeds.retain(|id, _| keep.contains(id));
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
    /// The view for rich content at `id` in the answer: kept while the
    /// row is, so an opened page stays open as the answer redraws.
    pub(super) fn embed_view(
        &mut self,
        id: &str,
        embed: &conduit_protocol::EmbedDto,
        tool: bool,
        cx: &mut Context<Self>,
    ) -> Entity<super::embed::EmbedView> {
        if let Some(view) = self.embeds.get(id) {
            view.update(cx, |v, cx| v.set(embed, cx));
            return view.clone();
        }
        let key = format!("{}-{id}", self.item.key);
        let store = self.host.store.clone();
        let embed = embed.clone();
        let view = cx.new(|cx| super::embed::EmbedView::new(key, embed, tool, store, cx));
        self.embeds.insert(id.to_string(), view.clone());
        view
    }

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

    /// The text selected in this answer, unless the selection is blank
    /// (the core's `askConduitInsertionText`: offered for a non-blank
    /// selection, inserted as selected).
    pub fn selected_text(&self, cx: &App) -> Option<String> {
        self.texts
            .values()
            .map(|(_, state)| state.read(cx).selected_text())
            .find(|text| !text.trim().is_empty())
            // A Compare Models answer's text is in its columns' views.
            .or_else(|| {
                self.compare
                    .iter()
                    .find_map(|(_, column)| column.read(cx).selected_text(cx))
            })
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
            .h(px(24.))
            .px(px(9.))
            .ml(px(4.))
            .flex()
            .items_center()
            .gap(px(5.))
            .rounded_full()
            .border_1()
            .border_color(r.border)
            .hover(|s| s.bg(r.hover))
            .active(|s| s.bg(conduit_components::views::focus::pressed_fill(r.hover, t)))
            .cursor_pointer()
            .keyboard_border(cx)
            .text_size(px(t.metrics.small))
            .text_color(r.text_subtle)
            .child(icon(IconName::Globe, 12., r.text_subtle))
            .child(SharedString::from(label))
            .on_click({
                let sources = sources.to_vec();
                move |_, window, cx| {
                    super::sources::open_sheet(sources.clone(), window, cx);
                }
            })
            .into_any_element()
    }
}

impl AssistantRow {
    /// The merged response (Merge Responses) under a comparison: its title
    /// and text, with a spinner while it is written.
    fn merged_panel(
        &mut self,
        item: &RowItem,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let t = cx.conduit().clone();
        let l10n = cx.l10n().clone();
        let (r, m) = (t.roles, t.metrics);
        let key = item.key.clone();
        let md = item.merged.clone().unwrap_or_default();
        let state = (!md.trim().is_empty()).then(|| self.text_state("merged", &md, window, cx));
        let title = l10n.chat_merged_response_title();
        div()
            .id(ElementId::Name(format!("merged-{key}").into()))
            .role(Role::Group)
            .aria_label(SharedString::from(title.clone()))
            .rounded(t.card_radius())
            .border_1()
            .border_color(r.border)
            .px(px(12.))
            .py(px(10.))
            .flex()
            .flex_col()
            .gap(px(6.))
            .child(
                div()
                    .flex()
                    .items_center()
                    .gap(px(6.))
                    .child(icon(IconName::GitMerge, 13., r.text_subtle))
                    .child(
                        div()
                            .text_size(px(m.small))
                            .font_weight(FontWeight::SEMIBOLD)
                            .text_color(r.text_subtle)
                            .child(SharedString::from(title)),
                    )
                    .when(item.merging, |d| {
                        d.child(spinner(
                            ElementId::Name(format!("merging-{key}").into()),
                            12.,
                            r.text_faint,
                        ))
                    }),
            )
            .children(state.map(|state| {
                div()
                    .text_size(px(m.body))
                    .line_height(relative(m.leading))
                    .text_color(r.text)
                    .child(super::markdown::chat_text(&state, key.clone().into()))
            }))
            .into_any_element()
    }

    /// A Compare Models answer's columns, side by side: each model's answer
    /// in a view of its own (so its text, disclosures and pace are its
    /// own), a hairline between them.
    fn columns(&mut self, item: &RowItem, _: &mut Window, cx: &mut Context<Self>) -> AnyElement {
        let r = cx.conduit().roles;
        let mut next = vec![];
        for col in &item.columns {
            let col_item = RowItem {
                key: col.answer_id.clone(),
                role: MessageRole::Assistant,
                text: col.text.clone(),
                blocks: col.blocks.clone(),
                model: col.model.clone(),
                streaming: col.streaming,
                stored: item.stored,
                ..Default::default()
            };
            let mut flags = self.flags.clone();
            flags.can_follow_up = false;
            let of = ColumnOf {
                current: col.current,
                message: item.key.clone(),
            };
            let view = match self.compare.iter().find(|(id, _)| *id == col.answer_id) {
                Some((_, view)) => {
                    view.update(cx, |row, cx| {
                        if row.column_of.as_ref() != Some(&of) {
                            row.column_of = Some(of.clone());
                            cx.notify();
                        }
                        row.set(col_item.clone(), flags.clone(), cx)
                    });
                    view.clone()
                }
                None => {
                    let host = self.host.clone();
                    cx.new(|_| {
                        let mut row = AssistantRow::new(host, col_item.clone(), flags.clone());
                        row.column_of = Some(of.clone());
                        row
                    })
                }
            };
            next.push((col.answer_id.clone(), view));
        }
        self.compare = next;
        div()
            .id(ElementId::Name(format!("compare-{}", item.key).into()))
            .role(Role::Group)
            .aria_label(SharedString::from(cx.l10n().chat_compare_models_action()))
            .w_full()
            .flex()
            .gap(px(14.))
            .children(self.compare.iter().enumerate().map(|(i, (_, view))| {
                div()
                    .flex_1()
                    .min_w_0()
                    .when(i > 0, |d| d.pl(px(14.)).border_l_1().border_color(r.border))
                    .child(view.clone())
            }))
            .into_any_element()
    }

    /// A column's own actions: Copy, and Continue from Here on an answer
    /// the chat does not go on from.
    fn column_actions(&self, item: &RowItem, of: &ColumnOf, cx: &App) -> AnyElement {
        let t = cx.conduit().clone();
        let l10n = cx.l10n().clone();
        let (r, m) = (t.roles, t.metrics);
        let key = item.key.clone();
        let copy = item.text.clone();
        let host = self.host.clone();
        let continues = !of.current
            && self.flags.abilities.branch
            && self.flags.can_branch
            && item.stored
            && !item.streaming;
        let (store, message, answer) = (host.store.clone(), of.message.clone(), key.clone());
        let pane = host.pane.clone();
        div()
            .ml(px(-6.))
            .mt(px(rhythm::ACTIONS_GAP - 10.))
            .h(px(rhythm::ACTIONS_HEIGHT))
            .flex()
            .items_center()
            .gap(px(4.))
            // The current answer's Copy is the row's own, under the columns.
            .when(!of.current, |d| {
                d.child(
                    small_action(
                        format!("copy-{key}"),
                        IconName::Copy,
                        l10n.copy().into(),
                        false,
                        &t,
                    )
                    .on_click(std::rc::Rc::new(move |_, _, cx| {
                        copy_text(&copy, &pane, cx)
                    })),
                )
            })
            .when(continues, |d| {
                let label = l10n.chat_branch_continue_from_response();
                d.child(
                    div()
                        .id(ElementId::Name(format!("continue-{key}").into()))
                        .role(Role::Button)
                        .aria_label(SharedString::from(label.clone()))
                        .h(px(24.))
                        .px(px(9.))
                        .flex()
                        .items_center()
                        .gap(px(5.))
                        .rounded_full()
                        .border_1()
                        .border_color(r.border)
                        .hover(|s| s.bg(r.hover))
                        .active(|s| {
                            s.bg(conduit_components::views::focus::pressed_fill(r.hover, &t))
                        })
                        .cursor_pointer()
                        .keyboard_border(cx)
                        .text_size(px(m.small))
                        .text_color(r.text)
                        .child(icon(IconName::CornerDownLeft, 12., r.text_subtle))
                        .child(SharedString::from(label))
                        .on_click(move |_, _, cx| {
                            let _ = store.update(cx, |s, cx| {
                                s.set_current(&answer, Some(&message), cx).detach();
                            });
                        }),
                )
            })
            .into_any_element()
    }
}

/// An answer's or a question's `n / N` with its arrows: each arrow makes
/// the version before or after the chat's (on the server); the label opens
/// the list of every version.
fn version_pager(
    key: &str,
    shown: usize,
    total: usize,
    host: &RowHost,
    item: &RowItem,
    t: &ConduitTheme,
    l10n: &crate::l10n::L10n,
) -> AnyElement {
    let r = t.roles;
    let m = t.metrics;
    let (prev_store, next_store) = (host.store.clone(), host.store.clone());
    let (prev_key, next_key) = (key.to_string(), key.to_string());
    let (list_host, list_item) = (host.clone(), item.clone());
    let label = l10n.desktop_version_of(shown as i64, total as i64);
    div()
        .id(ElementId::Name(format!("versions-{key}").into()))
        .role(Role::Group)
        .aria_label(SharedString::from(label.clone()))
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
            .disabled(shown <= 1)
            .on_click(std::rc::Rc::new(move |_, _, cx| {
                let step = prev_store.update(cx, |s, cx| s.step_version(&prev_key, -1, cx));
                announce_version(step.ok().flatten(), cx);
            })),
        )
        .child(
            div()
                .id(ElementId::Name(format!("version-list-{key}").into()))
                .role(Role::Button)
                .aria_label(SharedString::from(l10n.chat_branch_sheet_title()))
                .h(px(22.))
                .px(px(4.))
                .flex()
                .items_center()
                .rounded(px(5.))
                .cursor_pointer()
                .hover(|s| s.bg(r.hover))
                .text_size(px(m.small))
                .text_color(r.text_subtle)
                .child(SharedString::from(format!("{shown} / {total}")))
                .tooltip(conduit_components::views::focus::tooltip_builder(
                    l10n.chat_branch_sheet_title().into(),
                    None,
                ))
                .on_click(move |e, window, cx| {
                    let ctx = list_host.context(&list_item, e.position());
                    super::actions::run(ctx, RowCommand::Versions, window, cx);
                }),
        )
        .child(
            IconButton::new(
                ElementId::Name(format!("next-version-{key}").into()),
                IconName::ChevronRight,
                l10n.desktop_next_answer(),
            )
            .size(24., 14.)
            .color(r.text_faint)
            .disabled(shown >= total)
            .on_click(std::rc::Rc::new(move |_, _, cx| {
                let step = next_store.update(cx, |s, cx| s.step_version(&next_key, 1, cx));
                announce_version(step.ok().flatten(), cx);
            })),
        )
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
        if !leaving && item.columns.len() > 1 {
            body = vec![self.columns(&item, window, cx)];
        }
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
        // (A comparison's columns say it for themselves.)
        if item.streaming
            && !stale
            && self.leaving.is_none()
            && item.columns.len() < 2
            && !self.draws_anything(&item)
        {
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
        let pane_row = matches!(self.host.pane, RowSink::Pane(_));
        let offer = AnswerActions::of(&item, &self.flags, pane_row, &l10n);
        let reading = self.flags.reading.as_deref() == Some(shown_answer_id(&item).as_str());
        let (inline, more) =
            super::actions::layout(&offer.available, self.flags.actions.as_deref());
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
        let models = self.host.models(cx);
        let column_actions = self
            .column_of
            .clone()
            .filter(|_| show_actions && !item.streaming)
            .map(|of| self.column_actions(&item, &of, cx));
        let show_actions = show_actions && self.column_of.is_none();
        let actions = show_actions.then(|| {
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
                    d.child(version_pager(&key, shown, total, &host, &item, &t, &l10n))
                })
                .children(inline.iter().map(|a| {
                    let a = *a;
                    let command = action_command(a, &item);
                    let (host, it) = (host.clone(), item.clone());
                    let mut button = small_action(
                        format!("{}-{key}", a.id()),
                        action_icon(a, item.merging, reading),
                        action_label(a, item.merging, reading, false, &l10n).into(),
                        (a == MessageAction::Merge && item.merging)
                            || (a == MessageAction::ReadAloud && reading),
                        &t,
                    );
                    if let Some(k) = &chords {
                        button = match a {
                            MessageAction::Copy => button.shortcut(k.copy_last_reply.clone()),
                            MessageAction::Regenerate => button.shortcut(k.regenerate.clone()),
                            MessageAction::ReadAloud => button.shortcut(k.read_aloud.clone()),
                            _ => button,
                        };
                    }
                    button.on_click(std::rc::Rc::new(
                        move |e: &gpui_kit::ClickEvent, window, cx| {
                            let ctx = host.context(&it, e.position());
                            super::actions::run(ctx, command.clone(), window, cx);
                        },
                    ))
                }))
                .when(!sources.is_empty(), |d| {
                    d.child(self.sources_pill(&sources, &t, cx))
                })
                // More: what is not inline, Regenerate With, Copy as Markdown
                // and the rating, then Delete… on its own.
                .child({
                    let rating = item.rating;
                    let (store, more_key) = (host.store.clone(), key.clone());
                    let (good, bad) = (l10n.desktop_good_response(), l10n.desktop_bad_response());
                    let copy_md = l10n.desktop_copy_as_markdown();
                    let markdown = answer_markdown(&item);
                    let copy_error = offer
                        .copy_error
                        .clone()
                        .map(|e| (l10n.desktop_copy_error_details(), e));
                    let offer = offer.clone();
                    let more = more.clone();
                    let models = models.clone();
                    let (host, it) = (host.clone(), item.clone());
                    let labels: Vec<String> = more
                        .iter()
                        .map(|a| action_label(*a, it.merging, reading, true, &l10n))
                        .collect();
                    let regenerate_with = l10n.desktop_regenerate_with();
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
                            let ctx = host.context(&it, e.position());
                            let run = |command: RowCommand| -> Box<dyn gpui_kit::Action> {
                                Box::new(RunRowCommand {
                                    ctx: ctx.clone(),
                                    command,
                                })
                            };
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
                            let mut delete = None;
                            for (a, label) in more.iter().zip(&labels) {
                                if *a == MessageAction::Delete {
                                    delete = Some(label.clone());
                                    continue;
                                }
                                menu = menu.menu(label.clone(), run(action_command(*a, &it)));
                            }
                            if offer.regenerate_with && models.len() > 1 {
                                let mut sub = NativeMenu::new();
                                for (id, name) in &models {
                                    sub = sub.menu_with_check(
                                        name.clone(),
                                        it.model.as_deref() == Some(id.as_str()),
                                        run(RowCommand::Regenerate(Some(id.clone()))),
                                    );
                                }
                                menu = menu.submenu(regenerate_with.clone(), sub);
                            }
                            if !menu.is_empty() {
                                menu = menu.separator();
                            }
                            if let Some((label, error)) = &copy_error {
                                menu = menu.menu(label.clone(), copy(error.clone()));
                            }
                            if offer.copy_markdown {
                                menu = menu.menu(copy_md.clone(), copy(markdown.clone()));
                            }
                            if offer.rate {
                                menu = menu
                                    .separator()
                                    .menu_with_check(good.clone(), rating == Some(1), rate(1))
                                    .menu_with_check(bad.clone(), rating == Some(-1), rate(-1));
                            }
                            if let Some(label) = delete {
                                menu = menu.separator().menu(label, run(RowCommand::Delete));
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

        let merged = (!leaving && (item.merged.is_some() || item.merging))
            .then(|| self.merged_panel(&item, window, cx));
        // An answer waiting to go out says so, with Retry and Remove, and
        // has no actions until it has gone (as on the phone).
        let queued = (!leaving)
            .then(|| item.queued.clone())
            .flatten()
            .map(|q| self.queued_banner(&key, &q, &t, cx));
        let actions = if queued.is_some() { None } else { actions };
        div()
            .flex()
            .flex_col()
            .gap(px(rhythm::BLOCK_GAP))
            .children(body)
            .children(merged)
            .children(queued)
            .children(actions)
            .children(column_actions)
            .children(waiting_slot)
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

    /// The banner on an answer waiting to go out (the phone's
    /// `_buildQueuedCompletionBanner`): queued while offline, waiting to be
    /// sent, or failed; Retry (and Retry Without Reasoning Effort when the
    /// provider refused it) and Remove.
    fn queued_banner(
        &self,
        key: &str,
        queued: &conduit_protocol::QueuedCompletionDto,
        t: &ConduitTheme,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let l10n = cx.l10n().clone();
        let r = t.roles;
        let m = t.metrics;
        let (title, message, glyph) = if queued.failed {
            (
                l10n.chat_queued_failed_title(),
                l10n.desktop_queued_failed_message(),
                IconName::CircleAlert,
            )
        } else if queued.offline {
            (
                l10n.chat_queued_offline_title(),
                l10n.chat_queued_offline_message(),
                IconName::CloudOff,
            )
        } else {
            (
                l10n.chat_queued_pending_title(),
                l10n.chat_queued_pending_message(),
                IconName::Clock,
            )
        };
        let accent = if queued.failed { r.danger } else { r.text };
        let busy = self
            .host
            .store
            .upgrade()
            .is_some_and(|s| s.read(cx).queued_busy.contains(key));
        let button = |id: &str, label: String, glyph: Option<IconName>, run: QueuedAction| {
            let store = self.host.store.clone();
            let message = key.to_string();
            let mut b = conduit_components::views::kit::Button::new(
                ElementId::Name(format!("queued-{id}-{key}").into()),
                label,
            )
            .disabled(busy)
            .on_click(std::rc::Rc::new(move |_, _, cx| {
                let _ = store.update(cx, |s, cx| match run {
                    QueuedAction::Retry => s.retry_queued(&message, false, cx),
                    QueuedAction::RetryWithout => s.retry_queued(&message, true, cx),
                    QueuedAction::Remove => s.remove_queued(&message, cx),
                });
            }));
            if let Some(g) = glyph {
                b = b.icon(g);
            }
            b.into_any_element()
        };
        let mut buttons = vec![button(
            "retry",
            l10n.retry(),
            Some(IconName::RotateCcw),
            QueuedAction::Retry,
        )];
        if queued.reasoning_effort_rejected {
            buttons.push(button(
                "retry-without",
                l10n.retry_without_reasoning_effort(),
                None,
                QueuedAction::RetryWithout,
            ));
        }
        buttons.push(button(
            "remove",
            l10n.desktop_queued_remove(),
            Some(IconName::X),
            QueuedAction::Remove,
        ));
        div()
            .id(ElementId::Name(format!("queued-{key}").into()))
            .role(Role::Status)
            .aria_label(SharedString::from(format!("{title}. {message}")))
            .max_w(px(560.))
            .p(px(12.))
            .flex()
            .flex_col()
            .gap(px(8.))
            .rounded(px(8.))
            .border_1()
            .border_color(with_alpha(accent, 0.22))
            .bg(with_alpha(accent, if t.dark { 0.10 } else { 0.05 }))
            .child(
                div()
                    .flex()
                    .items_start()
                    .gap(px(8.))
                    .child(div().pt(px(1.)).child(icon(glyph, 16., accent)))
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .flex()
                            .flex_col()
                            .gap(px(2.))
                            .child(
                                div()
                                    .text_size(px(m.control))
                                    .font_weight(FontWeight::SEMIBOLD)
                                    .text_color(r.text)
                                    .child(SharedString::from(title)),
                            )
                            .child(
                                div()
                                    .text_size(px(m.small))
                                    .text_color(r.text_subtle)
                                    .child(SharedString::from(message)),
                            )
                            .when_some(queued.error.clone().filter(|_| queued.failed), |d, e| {
                                d.child(
                                    div()
                                        .text_size(px(m.caption))
                                        .text_color(r.text_faint)
                                        .child(SharedString::from(e)),
                                )
                            }),
                    ),
            )
            .child(div().flex().flex_wrap().gap(px(6.)).children(buttons))
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
        std::mem::swap(&mut self.embeds, &mut l.embeds);
        let opening = std::mem::take(&mut self.opening);
        self.leaving = Some(l);
        let column = self.column(true, now, window, cx);
        let mut l = self.leaving.take().expect("put back above");
        std::mem::swap(&mut self.item, &mut l.item);
        std::mem::swap(&mut self.texts, &mut l.texts);
        std::mem::swap(&mut self.expanded, &mut l.expanded);
        std::mem::swap(&mut self.embeds, &mut l.embeds);
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
        let compared = item.columns.len() > 1;
        // A Bot Chat's replies are its bot's: its name and face.
        let bot = self
            .host
            .store
            .upgrade()
            .and_then(|s| s.read(cx).hermes().and_then(|h| h.bot.clone()));
        let name = if let Some(bot) = &bot {
            bot.title.clone()
        } else if compared {
            l10n.chat_compare_models_action()
        } else if model.is_empty() {
            "Assistant".to_string()
        } else {
            model.clone()
        };
        let current_column = self.column_of.as_ref().is_some_and(|c| c.current);
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
            // A right-click on selected text: Ask Conduit, and Copy.
            .on_mouse_down(
                gpui_kit::MouseButton::Right,
                cx.listener(|this, e: &gpui_kit::MouseDownEvent, window, cx| {
                    if this.selected_text(cx).is_some() {
                        let l10n = cx.l10n().clone();
                        gpui_kit::component::native_menu::NativeMenu::new()
                            .menu(
                                l10n.ask_conduit_action(),
                                Box::new(crate::actions::AskConduit),
                            )
                            .separator()
                            .menu(l10n.copy(), Box::new(crate::actions::CopySelection))
                            .show(e.position, window, cx);
                        cx.stop_propagation();
                    }
                }),
            )
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
                    .child(match &bot {
                        Some(bot) => {
                            let face = cx
                                .try_global::<crate::stores::hermes_rooms::HermesRoomsGlobal>()
                                .map(|g| crate::views::hermes_faces::bot_face(bot, g.0.read(cx)))
                                .unwrap_or_else(|| crate::views::hermes_faces::Face {
                                    shape: bot.shape.clone(),
                                    color: crate::views::hermes_faces::parse_color(&bot.color),
                                    image: None,
                                });
                            crate::views::hermes_faces::face(
                                ElementId::Name(format!("answer-face-{key}").into()),
                                &face,
                                16.,
                                false,
                                true,
                            )
                        }
                        None => icon(
                            if compared {
                                IconName::Columns2
                            } else {
                                IconName::Sparkles
                            },
                            15.,
                            r.text_subtle,
                        )
                        .into_any_element(),
                    })
                    .child(
                        div()
                            .text_size(px(m.small))
                            .text_color(r.text_subtle)
                            .child(SharedString::from(name)),
                    )
                    .when(current_column, |d| {
                        d.child(
                            div()
                                .text_size(px(m.caption))
                                .text_color(r.text_faint)
                                .child(SharedString::from(l10n.desktop_compare_current())),
                        )
                    }),
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

    /// The question's text, as the bubble shows it (mentions by name), so
    /// Find's ranges fall on what is drawn.
    pub fn item_text(&self) -> String {
        shown_mentions(&self.item.text)
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
        if !self.flags.can_edit() || !self.item.stored {
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
        let label = format!("{}: {}", l10n.you(), shown_mentions(&item.text));
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
        let copy_value = shown_mentions(&item.text);
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
            .when(self.flags.can_edit() && item.stored, |d| {
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
            })
            // More: Delete… (the question takes its answers with it).
            .when(
                matches!(self.host.pane, RowSink::Pane(_))
                    && self.flags.abilities.delete_messages
                    && self.flags.can_branch
                    && item.stored,
                |d| {
                    let (host, it) = (self.host.clone(), item.clone());
                    let delete = l10n.desktop_delete_ellipsis();
                    d.child(
                        small_action(
                            format!("more-{key}"),
                            IconName::Ellipsis,
                            l10n.more().into(),
                            false,
                            &t,
                        )
                        .on_click(std::rc::Rc::new(
                            move |e: &gpui_kit::ClickEvent, window, cx| {
                                let ctx = host.context(&it, e.position());
                                gpui_kit::component::native_menu::NativeMenu::new()
                                    .menu(
                                        delete.clone(),
                                        Box::new(RunRowCommand {
                                            ctx,
                                            command: RowCommand::Delete,
                                        }),
                                    )
                                    .show(e.position(), window, cx);
                            },
                        )),
                    )
                },
            );
        // An edited question's versions, under it (its answers follow it).
        let versions = item
            .version
            .filter(|_| item.stored)
            .map(|(shown, total)| version_pager(&key, shown, total, &self.host, &item, &t, &l10n));
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
                    gpui_kit::StyledText::new(SharedString::from(shown_mentions(&item.text)))
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
        article
            .children(files)
            .child(
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
            .children(versions.map(|v| div().opacity(if visible { 1. } else { 0.6 }).child(v)))
    }
}

/// A row's view: an answer or a question.
#[derive(Clone)]
pub enum RowView {
    Assistant(Entity<AssistantRow>),
    User(Entity<UserRow>),
}

impl RowView {
    /// What an answer row's `[n]` cite, as it draws them.
    pub fn sources(&self, cx: &App) -> Option<Vec<ChatSourceDto>> {
        match self {
            Self::Assistant(row) => Some(row.read(cx).item().sources.clone()),
            Self::User(_) => None,
        }
    }

    /// The rich content views an answer row holds (for the E2E pass).
    pub fn embeds(&self, cx: &App) -> Vec<Entity<super::embed::EmbedView>> {
        match self {
            Self::Assistant(row) => row.read(cx).embeds.values().cloned().collect(),
            Self::User(_) => vec![],
        }
    }

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
            usage: None,
            merged: None,
            merging: false,
            retry_without_effort: false,
            columns: vec![],
            mergeable: vec![],
            siblings: vec![],
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
            queued: None,
        }
    }

    #[test]
    fn find_reads_a_question_as_its_bubble_shows_it() {
        let mut item = answer(vec![], "Ask <@U:u-1|Riley> about bread");
        item.role = MessageRole::User;
        let host = RowHost {
            store: WeakEntity::new_invalid(),
            pane: RowSink::None,
            server_id: None,
            composer: None,
        };
        let row = UserRow::new(host, item, RowFlags::default());
        // "bread" is found where it is drawn, after "@Riley".
        assert_eq!(row.item_text(), "Ask @Riley about bread");
    }

    #[test]
    fn a_failed_answer_offers_only_more_beside_its_retry() {
        use crate::stores::chat::empty_block;
        use MessageAction as A;
        let l10n = crate::l10n::L10n::new("en");
        let flags = RowFlags {
            can_branch: true,
            can_follow_up: true,
            ..Default::default()
        };
        let error = conduit_protocol::MessageBlockDto {
            error: Some("The tide service did not answer in time.".into()),
            ..empty_block(MessageBlockKind::Error)
        };
        // Nothing written before it failed: More copies the error alone.
        let offer = AnswerActions::of(&answer(vec![error.clone()], ""), &flags, true, &l10n);
        assert!(offer.available.is_empty() && !offer.rate && !offer.copy_markdown);
        assert_eq!(
            offer.copy_error.as_deref(),
            Some("The tide service did not answer in time.")
        );
        // Some words, then the error: they can be copied from More too.
        let text = conduit_protocol::MessageBlockDto {
            markdown: Some("High water is at".into()),
            ..empty_block(MessageBlockKind::Text)
        };
        let failed = answer(vec![text.clone(), error], "");
        let offer = AnswerActions::of(&failed, &flags, true, &l10n);
        assert!(offer.available.is_empty() && !offer.rate);
        assert!(offer.copy_markdown && offer.copy_error.is_some());
        // A rejected reasoning effort: the retry that drops it.
        let effort = RowItem {
            retry_without_effort: true,
            ..failed
        };
        let offer = AnswerActions::of(&effort, &flags, true, &l10n);
        assert_eq!(offer.available, vec![A::RetryWithoutEffort]);
        // A server that gave no words: a plain sentence.
        let bare = empty_block(MessageBlockKind::Error);
        let offer = AnswerActions::of(&answer(vec![bare], ""), &flags, true, &l10n);
        assert_eq!(
            offer.copy_error.as_deref(),
            Some(l10n.desktop_something_went_wrong().as_str())
        );
        // A finished answer keeps Copy, Read Aloud, Regenerate, Share and
        // the rating; Quick Ask has no Read Aloud (no playback bar there).
        let finished = answer(vec![text], "High water is at");
        let offer = AnswerActions::of(&finished, &flags, true, &l10n);
        assert_eq!(
            offer.available,
            vec![A::Copy, A::ReadAloud, A::Regenerate, A::Share]
        );
        let quick = AnswerActions::of(&finished, &flags, false, &l10n);
        assert!(!quick.available.contains(&A::ReadAloud));
        assert!(offer.rate && offer.copy_markdown && offer.regenerate_with);
        assert_eq!(offer.copy_error, None);
    }

    #[test]
    fn what_the_chat_offers_decides_the_rest() {
        use MessageAction as A;
        let l10n = crate::l10n::L10n::new("en");
        let text = conduit_protocol::MessageBlockDto {
            markdown: Some("Two coats.".into()),
            ..crate::stores::chat::empty_block(MessageBlockKind::Text)
        };
        let mut item = answer(vec![text], "Two coats.");
        item.usage = Some(conduit_protocol::ChatUsageDto {
            generation_per_second: None,
            generation_tokens: Some(12),
            prompt_per_second: None,
            prompt_tokens: None,
            reasoning_tokens: None,
            total_tokens: None,
            total_seconds: None,
            queue_seconds: None,
            load_seconds: None,
            context_length: None,
            context_tokens: None,
            incomplete: false,
        });
        item.columns = vec![Default::default(), Default::default()];
        item.mergeable = vec!["a".into(), "b".into()];
        let flags = RowFlags {
            can_branch: true,
            can_follow_up: true,
            abilities: conduit_protocol::ChatAbilities {
                fork: true,
                merge: true,
                delete_messages: true,
                ..Default::default()
            },
            ..Default::default()
        };
        let all = vec![
            A::Copy,
            A::ReadAloud,
            A::Regenerate,
            A::Merge,
            A::Usage,
            A::Fork,
            A::Share,
            A::Delete,
        ];
        assert_eq!(AnswerActions::of(&item, &flags, true, &l10n).available, all);
        // Quick Ask: no merging, branching or deleting there.
        let quick = AnswerActions::of(&item, &flags, false, &l10n).available;
        assert_eq!(quick, vec![A::Copy, A::Regenerate, A::Usage, A::Share]);
        // A merge running elsewhere in the chat: not a second one.
        let busy = RowFlags {
            merging: true,
            ..flags.clone()
        };
        assert!(
            !AnswerActions::of(&item, &busy, true, &l10n)
                .available
                .contains(&A::Merge)
        );
        // Automatic: three inline, the rest in More.
        let (inline, more) = super::super::actions::layout(&all, None);
        assert_eq!(inline, vec![A::Copy, A::ReadAloud, A::Regenerate]);
        assert_eq!(more, vec![A::Merge, A::Usage, A::Fork, A::Share, A::Delete]);
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

#[cfg(test)]
mod embed_tests {
    use std::rc::Rc;

    use conduit_protocol::{EmbedDto, EmbedKind, MessageBlockDto, MessageBlockKind};
    use gpui_kit::TestAppContext;

    use super::*;
    use crate::stores::chat::{ChatStore, Subscribe, empty_block};
    use crate::stores::rpc::fake::FakeDaemon;

    fn page(source: &str) -> EmbedDto {
        EmbedDto {
            kind: EmbedKind::Html,
            source: Some(source.into()),
            ..serde_json::from_value(serde_json::json!({"kind": "html"})).unwrap()
        }
    }

    fn embeds(sources: &[&str]) -> Vec<MessageBlockDto> {
        vec![MessageBlockDto {
            embeds: Some(sources.iter().map(|s| page(s)).collect()),
            ..empty_block(MessageBlockKind::Embeds)
        }]
    }

    #[test]
    fn embed_keys_follow_the_blocks_that_draw_them() {
        let mut blocks = vec![empty_block(MessageBlockKind::Text)];
        blocks.extend(embeds(&["<p>a</p>", "<p>b</p>"]));
        let ids = super::super::blocks::embed_ids(&blocks);
        assert_eq!(ids.len(), 2);
        assert!(ids.contains("e1.0") && ids.contains("e1.1"));
    }

    #[gpui_kit::test]
    fn an_embed_the_answer_no_longer_has_lets_go_of_its_view(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        let subscribe: Subscribe = Rc::new(|_, _| {});
        let rpc = daemon.rpc();
        let store = cx.new(|cx| ChatStore::new(rpc, subscribe, "c1".into(), cx));
        let host = RowHost {
            store: store.downgrade(),
            pane: RowSink::None,
            server_id: None,
            composer: None,
        };
        let item = RowItem {
            key: "a1".into(),
            blocks: embeds(&["<p>a</p>"]),
            ..Default::default()
        };
        let row = cx.new(|_| AssistantRow::new(host, item.clone(), RowFlags::default()));
        row.update(cx, |r, cx| {
            let embed = page("<p>a</p>");
            r.embed_view("e0.0", &embed, false, cx);
            assert_eq!(r.embeds.len(), 1);
            // Another version of the answer, without the embed.
            r.set(
                RowItem {
                    blocks: vec![empty_block(MessageBlockKind::Text)],
                    ..item
                },
                RowFlags::default(),
                cx,
            );
            assert!(r.embeds.is_empty(), "the old page kept running");
        });
    }

    #[gpui_kit::test]
    fn a_regenerated_answer_and_the_one_it_replaces_keep_their_own_embeds(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        let subscribe: Subscribe = Rc::new(|_, _| {});
        let rpc = daemon.rpc();
        let store = cx.new(|cx| ChatStore::new(rpc, subscribe, "c1".into(), cx));
        let host = RowHost {
            store: store.downgrade(),
            pane: RowSink::None,
            server_id: None,
            composer: None,
        };
        let old = RowItem {
            key: "a1".into(),
            blocks: embeds(&["<p>old</p>"]),
            ..Default::default()
        };
        let row = cx.new(|_| AssistantRow::new(host, old.clone(), RowFlags::default()));
        row.update(cx, |r, cx| {
            let first = r.embed_view("e0.0", &page("<p>old</p>"), false, cx);
            // Regenerate: stale, then its first words with an embed of the
            // same key.
            r.set(
                RowItem {
                    stale: true,
                    ..old.clone()
                },
                RowFlags::default(),
                cx,
            );
            r.set(
                RowItem {
                    blocks: embeds(&["<p>new</p>"]),
                    ..old.clone()
                },
                RowFlags::default(),
                cx,
            );
            let second = r.embed_view("e0.0", &page("<p>new</p>"), false, cx);
            assert_ne!(
                first.entity_id(),
                second.entity_id(),
                "both answers share one page"
            );
            assert_eq!(first.read(cx).embed().source.as_deref(), Some("<p>old</p>"));
            assert_eq!(
                second.read(cx).embed().source.as_deref(),
                Some("<p>new</p>")
            );
        });
    }
}
