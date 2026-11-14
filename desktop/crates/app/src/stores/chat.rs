//! One open chat: its stored transcript, the answer streaming into it, the
//! message this window just sent, and this window's own choices about it.
//!
//! * **Stored copy:** `chats.get`, whose assistant messages carry typed
//!   `blocks`. Refetched on `chats.changed` for this chat (or a general
//!   one), on a reconnect or an event gap, and after a turn ends. Every
//!   fetch has a generation, so a slow answer never overwrites a newer one.
//! * **Live overlay:** the turn streaming into this chat, from the scoped
//!   `turn.*` events. Each `turn.blocks` *replaces* the blocks wholesale
//!   (they are full snapshots), and kinds this build does not know are
//!   skipped. The overlay takes the place of the stored row with its id
//!   (the empty placeholder the server made), or of the answer a
//!   regenerate replaces; otherwise it goes at the end. Once the turn has
//!   ended and the stored copy has the answer, the overlay *settles* and
//!   the stored row shows. `turn.failed` keeps the partial answer and adds
//!   the error block when the daemon's blocks have none. An answer the
//!   daemon queued instead of starting (sent while the server is away) has
//!   no turn events; its overlay settles once the stored row shows it
//!   queued.
//! * **Pending message:** what this window sent, until the stored copy has
//!   it. An edit hides the question it replaces and everything after it.
//!   While `turns.send` (or `turns.edit`) is on its way the answer's header
//!   and "Waiting for the answer…" show under it ([`Row::Waiting`]) and the
//!   chat counts as streaming (Stop shows), until the turn's own overlay
//!   takes over; a Stop pressed meanwhile is sent once the turn exists.
//! * **Subscription:** `turn.*` events are scoped to the chat id, so the
//!   store asks for its scope through the `subscribe` hook (the app passes
//!   [`super::connection::ConnectionStore::subscribe`]). Subscribing again
//!   makes the daemon replay a running turn (and one that ended while this
//!   window was not listening), which is how reopening a chat mid-answer,
//!   or a reconnect, catches up.
//! * **Remaps:** `route.remap` moves the store to the chat's new id; it
//!   resubscribes and refetches.
//! * **Versions and branches:** a version's arrows, the version list and
//!   Continue from This Response make another answer the chat's current
//!   one on the server (`chats.setCurrent`); the chosen answer shows at once
//!   and the stored copy the daemon answers with replaces the transcript.
//!   A chat that cannot branch (temporary, read-only) only changes which
//!   version this window shows.
//! * **Compare Models:** a comparison turn's other answers (the
//!   `companionIds` of `turn.started`) stream as overlays of their own,
//!   drawn as columns beside the first.
//! * **This window only:** which answer version each message shows,
//!   ratings given here that the stored copy may not show yet (rolled back
//!   if refused), and how many of the newest messages the transcript shows
//!   (older ones load a page at a time as the user scrolls up).

use std::collections::HashMap;
use std::rc::Rc;

use conduit_daemon::RpcError;
use conduit_protocol::{
    AcceptedResult, ChatAbilities, ChatCurrent, ChatDetail, ChatFileDto, ChatForked,
    ChatMessageDto, ChatPromptAnswer, ChatPromptAnswerItem, ChatPromptDecision, ChatPromptDto,
    ChatPromptRef, ChatPromptState, ChatRef, ChatSourceDto, ChatTaskDto, ChatUsageDto,
    ComposerMentionDto, ContextAttachmentDto, DeleteMessages, EditTurn, Event, ForkChat,
    KnowledgeSummary, McpAppEvent, MergeProgress, MergeTurn, MessageBlockDto, MessageBlockKind,
    QueueAdd, QueueDraftRef, QueueEdit, QueueSendNowResult, QueueState, QueuedCompletionDto,
    QueuedTurnRef, RateTurn, RegenerateTurn, SendTurn, SendTurnAccepted, SteerResult, SteerTurn,
    StopTurn, events, methods,
};
use gpui_kit::{
    App, AppContext as _, AsyncApp, Context, Entity, EventEmitter, Subscription, Task, WeakEntity,
};

use super::hermes_work::HermesWorkStore;
use super::rpc::Rpc;

/// The events an open chat follows (`turn.*` scoped to its id;
/// `chats.changed` and `turn.finished` are unscoped).
pub const CHAT_EVENTS: &[&str] = &[
    events::TURN_STARTED,
    events::TURN_DELTA,
    events::TURN_BLOCKS,
    events::TURN_COMPLETED,
    events::TURN_FAILED,
    events::TURN_FINISHED,
    events::CHATS_CHANGED,
    events::QUEUE_CHANGED,
    events::MESSAGES_MERGE,
    events::CHAT_PROMPTS_CHANGED,
    events::MCP_APPS_EVENT,
    events::HERMES_WORK_CHANGED,
    // Words the core gives the chat's composer (a kept Hermes message).
    events::COMPOSER_INSERT_TEXT,
    // A model's terminal tool showing a file (the chat pane opens it).
    events::TERMINAL_DISPLAY_FILE,
];

/// How many of the newest messages show at first, and how many more each
/// "load older" adds.
pub const PAGE: usize = 100;

/// How often, and how far apart, a finished answer is fetched again while
/// the stored copy is still behind it, before the stored copy wins anyway.
const BEHIND_TRIES: u8 = 8;
const BEHIND_RETRY: std::time::Duration = std::time::Duration::from_millis(250);

/// Asks the connection for `Some(chat id)`'s scope (or none).
pub type Subscribe = Rc<dyn Fn(Option<&str>, &mut App)>;

/// Where a live turn is.
#[derive(Clone, Debug, PartialEq)]
pub enum LivePhase {
    Streaming,
    Completed,
    Failed {
        code: String,
        /// The server's own words, when it gave any.
        detail: Option<String>,
        /// Their code, when the daemon knows one (an error block's `type`,
        /// such as Apple's engine's `appleFailure.*`).
        kind: Option<String>,
    },
}

/// The answer streaming into this chat (or just finished, until the
/// stored copy has it).
#[derive(Clone, Debug, PartialEq)]
pub struct LiveTurn {
    pub message_id: String,
    pub model: Option<String>,
    /// The raw text so far (for copying).
    pub text: String,
    /// The last `turn.blocks` snapshot, unknown kinds removed.
    pub blocks: Vec<MessageBlockDto>,
    pub phase: LivePhase,
    /// A regenerate answered under a new id: the answer it replaces, whose
    /// row the overlay takes over until it settles.
    pub replaces: Option<String>,
    /// A regenerate that keeps the answer's id (Direct does): the old text,
    /// which the stored copy still has until the new answer is synced.
    pub stale_text: Option<String>,
    /// A regenerate made before the daemon named its answer: the overlay
    /// stands under the old answer's id until `turns.regenerate` replies or
    /// the turn's first event names the new one, whichever comes first.
    pub awaiting_id: bool,
    /// Fetches since the turn ended that found the stored copy behind the
    /// answer (see [`stored_behind`]).
    pub behind: u8,
    /// A `turn.*` event has named this answer. The overlay this window
    /// opens for its own send, edit or regenerate has not been named yet;
    /// one the daemon queued instead of starting (sent while the server is
    /// away) never is, and gives way to the stored row that shows it
    /// queued ([`ChatStore::settle`]).
    pub heard: bool,
}

impl LiveTurn {
    fn new(message_id: impl Into<String>) -> Self {
        Self {
            message_id: message_id.into(),
            model: None,
            text: String::new(),
            blocks: vec![],
            phase: LivePhase::Streaming,
            replaces: None,
            stale_text: None,
            awaiting_id: false,
            behind: 0,
            heard: false,
        }
    }

    pub fn streaming(&self) -> bool {
        self.phase == LivePhase::Streaming
    }

    /// The blocks to draw: the snapshot, plus the error when the turn
    /// failed and the snapshot does not say so.
    pub fn display_blocks(&self) -> Vec<MessageBlockDto> {
        let mut blocks = self.blocks.clone();
        if let LivePhase::Failed { detail, kind, .. } = &self.phase
            && !blocks.iter().any(|b| b.kind == MessageBlockKind::Error)
        {
            let mut error = empty_block(MessageBlockKind::Error);
            error.error = Some(detail.clone().unwrap_or_default());
            error.r#type = kind.clone();
            // Before sources and follow-ups, after the content.
            let at = blocks
                .iter()
                .position(|b| {
                    matches!(
                        b.kind,
                        MessageBlockKind::CodeExecution
                            | MessageBlockKind::Sources
                            | MessageBlockKind::FollowUps
                    )
                })
                .unwrap_or(blocks.len());
            blocks.insert(at, error);
        }
        blocks
    }
}

/// A block with only its kind set.
pub fn empty_block(kind: MessageBlockKind) -> MessageBlockDto {
    MessageBlockDto {
        kind,
        markdown: None,
        summary: None,
        title: None,
        duration_seconds: None,
        done: None,
        pending: None,
        body: None,
        calls: None,
        code: None,
        language: None,
        output: None,
        id: None,
        name: None,
        error: None,
        is_error: None,
        r#type: None,
        statuses: None,
        files: None,
        sources: None,
        follow_ups: None,
        embeds: None,
        changed_files: None,
        hermes_error: None,
    }
}

/// Whether `blocks` draw anything in the answer's body: a text with more
/// than white space, a status with a line to show, files, or any other
/// section. Sources and suggestions are drawn under the answer, not in it.
pub fn shows_anything(blocks: &[MessageBlockDto]) -> bool {
    blocks.iter().any(shows)
}

/// Whether `block` draws anything in the answer's body (see
/// [`shows_anything`]).
pub fn shows(block: &MessageBlockDto) -> bool {
    let words = |s: Option<&str>| s.is_some_and(|s| !s.trim().is_empty());
    match block.kind {
        MessageBlockKind::Text => words(block.markdown.as_deref()),
        MessageBlockKind::Sources | MessageBlockKind::FollowUps | MessageBlockKind::Unknown => {
            false
        }
        MessageBlockKind::Files => block.files.as_ref().is_some_and(|f| !f.is_empty()),
        MessageBlockKind::Status => {
            words(block.summary.as_deref())
                || words(
                    block
                        .statuses
                        .as_ref()
                        .and_then(|s| s.last())
                        .map(|s| s.description.as_str()),
                )
        }
        _ => true,
    }
}

/// `blocks` without the kinds this build cannot draw.
pub fn known_blocks(blocks: &[MessageBlockDto]) -> Vec<MessageBlockDto> {
    blocks
        .iter()
        .filter(|b| b.kind != MessageBlockKind::Unknown)
        .cloned()
        .collect()
}

/// What this window sent, until the stored copy has it.
#[derive(Clone, Debug, PartialEq)]
pub struct PendingMessage {
    /// Known once `turns.send` (or `turns.edit`) answers.
    pub message_id: Option<String>,
    pub text: String,
    pub files: Vec<ChatFileDto>,
    /// The question an edit replaces.
    pub replaces: Option<String>,
}

impl PendingMessage {
    pub fn new(text: impl Into<String>) -> Self {
        Self {
            message_id: None,
            text: text.into(),
            files: vec![],
            replaces: None,
        }
    }
}

/// One row of the transcript.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Row {
    /// `messages[i]` of the stored copy.
    Stored(usize),
    Pending,
    /// The answer to a message still on its way to the daemon: its header
    /// and a waiting line, until the turn's own overlay shows.
    Waiting,
    Live,
}

/// A row as the views draw it.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct RowItem {
    /// Stable across frames: the message id, or `pending`.
    pub key: String,
    pub role: Role,
    /// The message's text (the shown version's, for answers).
    pub text: String,
    /// Answers: the shown version's blocks.
    pub blocks: Vec<MessageBlockDto>,
    pub files: Vec<ChatFileDto>,
    pub sources: Vec<ChatSourceDto>,
    pub model: Option<String>,
    /// The name the answer's model went by when it answered, as the stored
    /// copy keeps it: the header's fallback for a model not on offer.
    pub model_name: Option<String>,
    pub timestamp_ms: Option<i64>,
    pub streaming: bool,
    /// The thumb shown (this window's override first).
    pub rating: Option<i64>,
    /// `(shown, total)`, 1-based, when an answer has other versions.
    pub version: Option<(usize, usize)>,
    /// Shown as the stored copy has it (not a pending or live row).
    pub stored: bool,
    /// The newest answer of the transcript, with nothing sent after it
    /// (follow-ups show only here).
    pub last_answer: bool,
    /// A regenerate's old answer, shown dimmed until the new one starts.
    pub stale: bool,
    /// Tokens and timing, when the provider reported them (Usage).
    pub usage: Option<ChatUsageDto>,
    /// The merged response (Merge Responses): saved, or arriving.
    pub merged: Option<String>,
    /// A merge is writing into this answer now.
    pub merging: bool,
    /// Retry Without Reasoning Effort applies (the daemon's reading of the
    /// error).
    pub retry_without_effort: bool,
    /// A Compare Models answer: each model's column, in order (two or
    /// more); empty for an ordinary answer.
    pub columns: Vec<CompareColumn>,
    /// Of the columns' answers, those Merge Responses may read.
    pub mergeable: Vec<String>,
    /// The message and its versions, by id, in the server's order (for the
    /// version list); empty without versions.
    pub siblings: Vec<String>,
    /// An answer waiting to go out (sent while offline, or failed).
    pub queued: Option<QueuedCompletionDto>,
}

/// One model's answer in a Compare Models row.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct CompareColumn {
    pub answer_id: String,
    pub model: Option<String>,
    pub text: String,
    pub blocks: Vec<MessageBlockDto>,
    pub streaming: bool,
    /// The answer the chat goes on from (the transcript's own message).
    pub current: bool,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum Role {
    #[default]
    User,
    Assistant,
}

/// What a failed action was, for the window's notice.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ChatAction {
    Load,
    Send,
    Stop,
    Regenerate,
    Edit,
    Rate,
    /// A `queue.*` change the daemon refused.
    Queue,
    /// Another version or branch (`chats.setCurrent`) was refused.
    Branch,
    /// `messages.delete` was refused.
    Delete,
    /// Fork Chat was refused; the reason is the core's `ChatBranchFailure`.
    Fork,
    /// Merge Responses failed; the reason is the core's
    /// `ComparisonMergeFailure` (`unavailable`, `notMergeable`, ...).
    Merge,
    /// Save Chat (a temporary chat) was refused.
    Save,
    /// Answering an Open WebUI prompt failed.
    Prompt,
    /// Retrying or removing a queued answer failed.
    Queued,
}

#[derive(Clone, Debug, PartialEq)]
pub enum ChatStoreEvent {
    /// An action the daemon refused (the store already rolled back).
    /// `reason` is the daemon's own word for why, when it gave one.
    Failed {
        action: ChatAction,
        error: String,
        reason: Option<String>,
    },
    /// The chat no longer exists (deleted elsewhere).
    Missing,
    /// An MCP App's host has something for its view.
    McpApp(McpAppEvent),
    /// Words the core gives the chat's composer (`composer.insertText`): a
    /// Hermes message kept back when a model switch was declined, or what
    /// Hermes prefills. `only_into_empty` text goes in only while the
    /// composer holds nothing.
    InsertText { text: String, only_into_empty: bool },
}

/// Where a step of an answer's version arrows landed: version `index`
/// (1-based) of `total`, and whether it switched the chat's branch on the
/// server (what VoiceOver is told: "Continuing from version 2 of 3", or the
/// arrows' own "Answer 2 of 3").
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct VersionStep {
    pub index: usize,
    pub total: usize,
    pub branch: bool,
}

impl VersionStep {
    /// What VoiceOver hears for this step, in the phone's words.
    pub fn spoken(self, l: &crate::l10n::L10n) -> String {
        if self.branch {
            l.chat_branch_selected_notice(self.index as i64, self.total as i64)
        } else {
            l.desktop_version_of(self.index as i64, self.total as i64)
        }
    }
}

pub struct ChatStore {
    rpc: Rpc,
    subscribe: Subscribe,
    chat_id: String,
    /// A temporary chat: never stored, no history to branch.
    pub temporary: bool,
    /// The model the next answer is from, for the live row's name until
    /// `turn.started` says (a new chat subscribes after it went out).
    pub model_hint: Option<String>,
    /// A Compare Models turn's models, in order: the other answers' names
    /// while they stream.
    pub compare_hint: Vec<String>,
    pub detail: Option<ChatDetail>,
    pub loading: bool,
    pub missing: bool,
    pub live: Option<LiveTurn>,
    pub pending: Option<PendingMessage>,
    /// `turns.send` or `turns.edit` is on its way: an answer is coming.
    awaiting: bool,
    /// Stop was pressed before the daemon took the turn: sent once it has.
    stop_requested: bool,
    /// Shown answer version per message (index into `versions`, or
    /// `versions.len()` for the message's own content).
    versions: HashMap<String, usize>,
    /// Ratings given here, until the stored copy agrees.
    ratings: HashMap<String, i64>,
    /// A regenerate's answer (by its new id) and the row key it keeps: the
    /// key of the answer it replaced, so the transcript's row (and what it
    /// is fading) stays one row from the first event to the stored copy.
    row_keys: HashMap<String, String>,
    /// Each such key's newest answer: the one its row shows.
    newest_for_key: HashMap<String, String>,
    /// How many of the newest messages show.
    window: usize,
    rows: Vec<Row>,
    hidden: usize,
    generation: u64,
    /// Bumped when anything but the live answer changes (rows, the stored
    /// copy, versions, ratings), and when the live answer does.
    stored_rev: u64,
    live_rev: u64,
    /// Messages queued behind the running answer (`queue.*`), and whether
    /// one typed now would be.
    pub queue: QueueState,
    /// A Compare Models turn's other answers, streaming beside `live`.
    pub companions: Vec<LiveTurn>,
    /// The merge writing into an answer (`messages.merge`), until the stored
    /// copy has it.
    pub merge: Option<MergeProgress>,
    /// A version switch on its way to the daemon.
    switching: bool,
    /// A version chosen while a switch was on its way: made the chat's once
    /// that one has landed (the last choice wins).
    queued_version: Option<String>,
    /// Open WebUI's question or approval waiting in this chat.
    pub prompt: Option<ChatPromptDto>,
    /// Its answer is on its way.
    pub prompt_busy: bool,
    /// Its last answer failed.
    pub prompt_failed: bool,
    /// Open WebUI's task checklist for this chat.
    pub tasks: Vec<ChatTaskDto>,
    /// A Hermes agent's work in this chat: subagents, processes, plan.
    pub hermes: Entity<HermesWorkStore>,
    /// Queued answers whose Retry or Remove is on its way.
    pub queued_busy: std::collections::HashSet<String>,
    /// Bumped by every `chatPrompts.get` asked and every
    /// `chatPrompts.changed`: a reply asked before the latest is dropped.
    prompt_round: u64,
    /// The `chatPrompts.get` on its way.
    _prompt_fetch: Option<Task<()>>,
    /// The answer or decision on its way (never dropped by a fetch, which
    /// would leave the card busy).
    _prompt: Option<Task<()>>,
    _fetch: Option<Task<()>>,
    _refetch: Option<Task<()>>,
    _queue: Option<Task<()>>,
    _hermes: Subscription,
}

impl EventEmitter<ChatStoreEvent> for ChatStore {}

impl ChatStore {
    /// Opens `chat_id`: subscribes to its scope and fetches it.
    pub fn new(rpc: Rpc, subscribe: Subscribe, chat_id: String, cx: &mut Context<Self>) -> Self {
        let hermes = cx.new(|_| HermesWorkStore::new(rpc.clone(), chat_id.clone()));
        let hermes_seen = cx.observe(&hermes, |_, _, cx| cx.notify());
        let mut store = Self {
            rpc,
            subscribe,
            chat_id,
            temporary: false,
            model_hint: None,
            compare_hint: vec![],
            detail: None,
            loading: true,
            missing: false,
            live: None,
            pending: None,
            awaiting: false,
            stop_requested: false,
            versions: HashMap::new(),
            ratings: HashMap::new(),
            row_keys: HashMap::new(),
            newest_for_key: HashMap::new(),
            window: PAGE,
            rows: vec![],
            hidden: 0,
            generation: 0,
            stored_rev: 0,
            live_rev: 0,
            queue: empty_queue(String::new()),
            companions: vec![],
            merge: None,
            switching: false,
            queued_version: None,
            prompt: None,
            prompt_busy: false,
            prompt_failed: false,
            prompt_round: 0,
            _prompt_fetch: None,
            tasks: vec![],
            hermes,
            queued_busy: Default::default(),
            _prompt: None,
            _fetch: None,
            _refetch: None,
            _queue: None,
            _hermes: hermes_seen,
        };
        store.queue.chat_id = store.chat_id.clone();
        store.resubscribe(cx);
        store.fetch(cx);
        store.refresh_queue(cx);
        store
    }

    // ── Open WebUI prompts ──────────────────────────────────────────────

    /// `chatPrompts.get`: the question or approval waiting in this chat (a
    /// saved one is looked up again each time).
    pub fn refresh_prompt(&mut self, cx: &mut Context<Self>) {
        if self.temporary {
            return;
        }
        let call = self.rpc.call::<methods::ChatPromptsGet>(&ChatPromptRef {
            chat_id: self.chat_id.clone(),
        });
        self.prompt_round += 1;
        let round = self.prompt_round;
        self._prompt_fetch = Some(cx.spawn(
            async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
                if let Ok(state) = call.await {
                    let _ = this.update(cx, |s, cx| {
                        // A `chatPrompts.changed` came after it was asked.
                        if s.prompt_round == round {
                            s.set_prompt(state, cx);
                        }
                    });
                }
            },
        ));
    }

    fn set_prompt(&mut self, state: ChatPromptState, cx: &mut Context<Self>) {
        if state.chat_id != self.chat_id {
            return;
        }
        let same = self.prompt.as_ref().map(|p| &p.id) == state.prompt.as_ref().map(|p| &p.id);
        if !same {
            self.prompt_busy = false;
            self.prompt_failed = false;
        }
        if self.prompt != state.prompt || !same {
            self.prompt = state.prompt;
            cx.notify();
        }
    }

    /// Answers the waiting `askUser` prompt's questions.
    pub fn answer_prompt(&mut self, answers: Vec<ChatPromptAnswerItem>, cx: &mut Context<Self>) {
        let Some(prompt) = &self.prompt else { return };
        if self.prompt_busy {
            return;
        }
        let call = self
            .rpc
            .call::<methods::ChatPromptsAnswer>(&ChatPromptAnswer {
                chat_id: self.chat_id.clone(),
                prompt_id: prompt.id.clone(),
                answers,
            });
        self.prompt_call(call, cx);
    }

    /// Approves or refuses the waiting approval or confirmation, or
    /// declines the questions.
    pub fn decide_prompt(&mut self, approved: bool, cx: &mut Context<Self>) {
        let Some(prompt) = &self.prompt else { return };
        if self.prompt_busy {
            return;
        }
        let call = self
            .rpc
            .call::<methods::ChatPromptsDecide>(&ChatPromptDecision {
                chat_id: self.chat_id.clone(),
                prompt_id: prompt.id.clone(),
                approved,
            });
        self.prompt_call(call, cx);
    }

    fn prompt_call(
        &mut self,
        call: impl std::future::Future<Output = Result<AcceptedResult, RpcError>> + 'static,
        cx: &mut Context<Self>,
    ) {
        self.prompt_busy = true;
        self.prompt_failed = false;
        cx.notify();
        self._prompt = Some(
            cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
                let result = call.await;
                let _ = this.update(cx, |s, cx| match result {
                    // The card goes with `chatPrompts.changed`; until then
                    // it stays busy.
                    Ok(AcceptedResult { accepted: true }) => {}
                    // Already answered (elsewhere, or timed out).
                    Ok(_) => {
                        s.prompt_busy = false;
                        s.refresh_prompt(cx);
                    }
                    Err(e) => {
                        s.prompt_busy = false;
                        s.prompt_failed = true;
                        s.failed(ChatAction::Prompt, &e, cx);
                        cx.notify();
                    }
                });
            }),
        );
    }

    // ── Queued answers ──────────────────────────────────────────────────

    /// Sends a queued answer again now (optionally without the reasoning
    /// effort the provider refused).
    pub fn retry_queued(
        &mut self,
        message_id: &str,
        without_reasoning_effort: bool,
        cx: &mut Context<Self>,
    ) {
        let call = self.rpc.call::<methods::TurnsRetryQueued>(&QueuedTurnRef {
            chat_id: self.chat_id.clone(),
            message_id: message_id.to_string(),
            without_reasoning_effort,
        });
        self.queued_call(message_id, call, cx);
    }

    /// Removes a queued answer before it goes out.
    pub fn remove_queued(&mut self, message_id: &str, cx: &mut Context<Self>) {
        let call = self.rpc.call::<methods::TurnsRemoveQueued>(&QueuedTurnRef {
            chat_id: self.chat_id.clone(),
            message_id: message_id.to_string(),
            without_reasoning_effort: false,
        });
        self.queued_call(message_id, call, cx);
    }

    fn queued_call(
        &mut self,
        message_id: &str,
        call: impl std::future::Future<Output = Result<conduit_protocol::OkResult, RpcError>> + 'static,
        cx: &mut Context<Self>,
    ) {
        if !self.queued_busy.insert(message_id.to_string()) {
            return;
        }
        cx.notify();
        let id = message_id.to_string();
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result = call.await;
            let _ = this.update(cx, |s, cx| {
                s.queued_busy.remove(&id);
                if let Err(e) = result {
                    s.failed(ChatAction::Queued, &e, cx);
                }
                s.fetch(cx);
                cx.notify();
            });
        })
        .detach();
    }

    // ── Queue ───────────────────────────────────────────────────────────

    /// A message typed now would be queued behind the running answer, or
    /// behind an answer that waits in the outbox (sent while offline): the
    /// daemon still writes that one, and a turn sent beside it is refused
    /// as the chat is busy. Queued, it goes out once that answer has (as
    /// on the phone).
    pub fn queue_offered(&self) -> bool {
        self.queue.offer && (self.is_streaming() || self.answer_queued())
    }

    /// The newest answer waits in the outbox: its stored row shows it
    /// queued.
    pub fn answer_queued(&self) -> bool {
        self.messages()
            .last()
            .is_some_and(|m| m.role == "assistant" && m.queued.is_some())
    }

    /// `queue.get`: the chat's queue as the daemon has it now.
    pub fn refresh_queue(&mut self, cx: &mut Context<Self>) {
        if self.temporary {
            return;
        }
        let call = self.rpc.call::<methods::QueueGet>(&ChatRef {
            id: self.chat_id.clone(),
        });
        self._queue = Some(
            cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
                if let Ok(queue) = call.await {
                    let _ = this.update(cx, |s, cx| s.set_queue(queue, cx));
                }
            }),
        );
    }

    fn set_queue(&mut self, queue: QueueState, cx: &mut Context<Self>) {
        if queue.chat_id == self.chat_id && queue != self.queue {
            self.queue = queue;
            cx.notify();
        }
    }

    /// Runs a `queue.*` call and shows the queue it answers with; a refusal
    /// is reported (the task says whether it went through).
    fn queue_call<M>(&mut self, params: M::Params, cx: &mut Context<Self>) -> Task<bool>
    where
        M: conduit_daemon::protocol::RpcMethod<Result = QueueState>,
    {
        let call = self.rpc.call::<M>(&params);
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result = call.await;
            this.update(cx, |s, cx| match result {
                Ok(queue) => {
                    s.set_queue(queue, cx);
                    true
                }
                Err(e) => {
                    s.failed(ChatAction::Queue, &e, cx);
                    false
                }
            })
            .unwrap_or(false)
        })
    }

    /// Queues a message behind the running answer.
    pub fn queue_add(&mut self, add: QueueAdd, cx: &mut Context<Self>) -> Task<bool> {
        self.queue_call::<methods::QueueAdd>(add, cx)
    }

    pub fn queue_edit(&mut self, draft_id: &str, text: &str, cx: &mut Context<Self>) -> Task<bool> {
        let edit = QueueEdit {
            chat_id: self.chat_id.clone(),
            draft_id: draft_id.to_string(),
            text: text.to_string(),
        };
        self.queue_call::<methods::QueueEdit>(edit, cx)
    }

    pub fn queue_remove(&mut self, draft_id: &str, cx: &mut Context<Self>) -> Task<bool> {
        let draft = QueueDraftRef {
            chat_id: self.chat_id.clone(),
            draft_id: draft_id.to_string(),
        };
        self.queue_call::<methods::QueueRemove>(draft, cx)
    }

    pub fn queue_retry(&mut self, cx: &mut Context<Self>) -> Task<bool> {
        let chat = ChatRef {
            id: self.chat_id.clone(),
        };
        self.queue_call::<methods::QueueRetry>(chat, cx)
    }

    /// Stops the running answer and sends one queued message now. The task
    /// says the core's outcome (`admitted`, `stopFailed`, ...).
    pub fn queue_send_now(
        &mut self,
        draft_id: &str,
        cx: &mut Context<Self>,
    ) -> Task<Option<String>> {
        let call = self.rpc.call::<methods::QueueSendNow>(&QueueDraftRef {
            chat_id: self.chat_id.clone(),
            draft_id: draft_id.to_string(),
        });
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result = call.await;
            this.update(cx, |s, cx| match result {
                Ok(QueueSendNowResult { outcome, queue }) => {
                    s.set_queue(queue, cx);
                    Some(outcome)
                }
                Err(e) => {
                    s.failed(ChatAction::Queue, &e, cx);
                    None
                }
            })
            .ok()
            .flatten()
        })
    }

    // ── Hermes busy turn ────────────────────────────────────────────────

    /// A message typed while Hermes works: steers the running turn, or goes
    /// as the next message (`turns.steer`).
    pub fn steer(
        &mut self,
        text: String,
        mentions: Vec<ComposerMentionDto>,
        steer: bool,
        cx: &mut Context<Self>,
    ) -> Task<Result<SteerResult, RpcError>> {
        let call = self.rpc.call::<methods::TurnsSteer>(&SteerTurn {
            chat_id: self.chat_id.clone(),
            text,
            mentions,
            steer,
        });
        cx.background_spawn(call)
    }

    /// A chat this window just started with `turns.send`: the message sent
    /// and the answer it waits for show at once.
    pub fn started(
        &mut self,
        pending: PendingMessage,
        accepted: &SendTurnAccepted,
        temporary: bool,
        cx: &mut Context<Self>,
    ) {
        self.temporary = temporary;
        self.pending = Some(PendingMessage {
            message_id: Some(accepted.user_message_id.clone()),
            ..pending
        });
        self.expect_answer(&accepted.assistant_message_id, None);
        self.rebuild(cx);
    }

    /// The daemon, for what a chat's views call themselves (an MCP App).
    pub fn rpc(&self) -> Rpc {
        self.rpc.clone()
    }

    pub fn chat_id(&self) -> &str {
        &self.chat_id
    }

    pub fn title(&self) -> Option<&str> {
        self.detail.as_ref().map(|d| d.summary.title.as_str())
    }

    pub fn messages(&self) -> &[ChatMessageDto] {
        self.detail
            .as_ref()
            .map(|d| d.messages.as_slice())
            .unwrap_or_default()
    }

    fn resubscribe(&self, cx: &mut App) {
        (self.subscribe)(Some(&self.chat_id), cx);
    }

    // ── Fetching ────────────────────────────────────────────────────────

    /// `chats.get`, then settle what the stored copy now has.
    pub fn fetch(&mut self, cx: &mut Context<Self>) {
        // A saved prompt goes and comes with the stored copy.
        self.refresh_prompt(cx);
        self.generation += 1;
        let generation = self.generation;
        let call = self.rpc.call::<methods::ChatsGet>(&ChatRef {
            id: self.chat_id.clone(),
        });
        self.loading = self.detail.is_none();
        self._fetch = Some(
            cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
                let result = call.await;
                let _ = this.update(cx, |s, cx| s.fetched(generation, result, cx));
            }),
        );
    }

    fn fetched(
        &mut self,
        generation: u64,
        result: Result<conduit_protocol::ChatResult, RpcError>,
        cx: &mut Context<Self>,
    ) {
        if generation != self.generation {
            return;
        }
        self.loading = false;
        match result {
            Ok(result) => match result.chat {
                Some(detail) => {
                    self.tasks = detail.tasks.clone();
                    // A Hermes agent works here: follow its work while the
                    // chat is open.
                    if detail.abilities.hermes_work && !self.hermes.read(cx).watching() {
                        self.hermes.update(cx, |h, cx| h.watch(cx));
                    }
                    self.detail = Some(detail);
                    self.missing = false;
                    if self.settle() {
                        self.fetch_again(cx);
                    }
                }
                // A temporary chat is not stored until the daemon has it in
                // memory; only a chat that is neither pending nor live is
                // gone.
                None if self.pending.is_none() && self.live.is_none() => {
                    self.missing = true;
                    cx.emit(ChatStoreEvent::Missing);
                }
                None => {}
            },
            Err(e) => {
                log::warn!("chats.get: {e}");
                cx.emit(ChatStoreEvent::Failed {
                    action: ChatAction::Load,
                    error: e.to_string(),
                    reason: None,
                });
            }
        }
        self.rebuild(cx);
    }

    /// Drops the pending message and a finished (or queued) overlay once
    /// the stored copy has them, and ratings the stored copy now agrees
    /// with. Returns whether the overlay stays because the stored copy is
    /// behind it.
    ///
    /// The answer finishes in place: right after a turn ends the server
    /// can still hold the copy it saved mid-stream, the answer's opening
    /// words. Swapping that in would collapse the answer for a moment, so
    /// the overlay stays until the stored copy has caught up (or a few
    /// fetches later, when the stored copy wins).
    fn settle(&mut self) -> bool {
        let Some(detail) = &self.detail else {
            return false;
        };
        let messages = &detail.messages;
        if let Some(pending) = &self.pending
            && let Some(id) = &pending.message_id
            && messages.iter().any(|m| &m.id == id)
        {
            self.pending = None;
        }
        let mut behind = false;
        // An answer the daemon queued instead of starting gets no turn
        // events, so its overlay never stops streaming: the stored row that
        // shows it queued takes its place. An answer that has streamed
        // keeps its overlay until the turn's own events end it.
        if let Some(live) = &self.live
            && (!live.streaming() || (!live.heard && stored_queued(messages, &live.message_id)))
            && stored_has_answer(messages, &live.message_id, live.stale_text.as_deref())
        {
            if live.behind < BEHIND_TRIES && stored_behind(messages, &live.message_id, &live.text) {
                behind = true;
            } else {
                self.live = None;
            }
        }
        // A comparison's other answers settle once the stored copy has each
        // (they are versions of the first answer there).
        if self.live.is_none() {
            self.companions
                .retain(|c| c.streaming() || !stored_has_answer(messages, &c.message_id, None));
        }
        // A finished merge, once the stored copy shows it (or it failed).
        if let Some(merge) = &self.merge
            && !merge.running
            && (merge.error.is_some() || stored_merged(messages, &merge.target_id).is_some())
        {
            self.merge = None;
        }
        self.ratings.retain(|id, rating| {
            !messages
                .iter()
                .any(|m| &m.id == id && m.rating == Some(*rating))
        });
        behind
    }

    /// The stored copy is behind the finished answer: fetch again shortly.
    fn fetch_again(&mut self, cx: &mut Context<Self>) {
        let Some(live) = &mut self.live else {
            return;
        };
        live.behind += 1;
        self._refetch = Some(
            cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
                cx.background_executor().timer(BEHIND_RETRY).await;
                let _ = this.update(cx, |s, cx| s.fetch(cx));
            }),
        );
    }

    // ── Events ──────────────────────────────────────────────────────────

    /// A daemon event (the window forwards every one; the store picks its
    /// own).
    pub fn on_event(&mut self, event: &Event, cx: &mut Context<Self>) {
        // A comparison's other answers: their own overlays, never `live`.
        if self.on_companion_event(event, cx) {
            return;
        }
        match event {
            Event::TurnStarted(e) if e.chat_id == self.chat_id => {
                let live = self.live_for(&e.message_id);
                live.heard = true;
                live.model = Some(e.model.clone());
                live.phase = LivePhase::Streaming;
                let hints = self.compare_hint.clone();
                self.companions = e
                    .companion_ids
                    .iter()
                    .filter(|id| **id != e.message_id)
                    .enumerate()
                    .map(|(i, id)| LiveTurn {
                        model: hints.get(i + 1).cloned(),
                        ..LiveTurn::new(id.clone())
                    })
                    .collect();
                self.rebuild(cx);
            }
            Event::MessagesMerge(p) if p.chat_id == self.chat_id => {
                let ended = !p.running;
                if let Some(error) = &p.error {
                    cx.emit(ChatStoreEvent::Failed {
                        action: ChatAction::Merge,
                        error: error.clone(),
                        reason: Some(error.clone()),
                    });
                }
                self.merge = Some(p.clone());
                self.stored_rev += 1;
                if ended {
                    self.fetch(cx);
                }
                cx.notify();
            }
            Event::TurnDelta(e) if e.chat_id == self.chat_id => {
                let live = self.live_for(&e.message_id);
                live.heard = true;
                if live.streaming() {
                    live.text = e.text.clone();
                }
                self.live_rev += 1;
                cx.notify();
            }
            Event::TurnBlocks(e) if e.chat_id == self.chat_id => {
                if let Some(tasks) = &e.tasks
                    && *tasks != self.tasks
                {
                    self.tasks = tasks.clone();
                }
                let blocks = known_blocks(&e.blocks);
                let live = self.live_for(&e.message_id);
                live.heard = true;
                live.blocks = blocks;
                self.live_rev += 1;
                // The overlay is new or it changed size: rows are rebuilt
                // only when it first appears.
                if !self.rows.contains(&Row::Live) {
                    self.rebuild(cx);
                } else {
                    cx.notify();
                }
            }
            Event::TurnCompleted(e) if e.chat_id == self.chat_id => {
                let live = self.live_for(&e.message_id);
                live.heard = true;
                live.text = e.text.clone();
                live.phase = LivePhase::Completed;
                self.fetch(cx);
                self.rebuild(cx);
            }
            Event::TurnFailed(e) if e.chat_id == self.chat_id => {
                let live = self.live_for(&e.message_id);
                live.heard = true;
                if live.text.is_empty() {
                    live.text = e.partial_text.clone();
                }
                live.phase = LivePhase::Failed {
                    code: e.code.clone(),
                    detail: e.args.get("detail").cloned().filter(|d| !d.is_empty()),
                    kind: e.args.get("type").cloned().filter(|d| !d.is_empty()),
                };
                self.fetch(cx);
                self.rebuild(cx);
            }
            // Unscoped; a fallback for a lost `turn.completed`/`turn.failed`.
            // A queued hand-off (`queued`) ends the overlay as a finished
            // answer would: the stored row, fetched now, shows it queued.
            Event::TurnFinished(e) if e.chat_id == self.chat_id => {
                if let Some(live) = &mut self.live
                    && live.message_id == e.message_id
                    && live.streaming()
                {
                    live.phase = if e.ok {
                        LivePhase::Completed
                    } else {
                        LivePhase::Failed {
                            code: e.code.clone().unwrap_or_default(),
                            detail: None,
                            kind: None,
                        }
                    };
                    self.fetch(cx);
                    self.rebuild(cx);
                }
            }
            Event::ChatsChanged(e)
                if e.chat_id.is_none() || e.chat_id.as_deref() == Some(&self.chat_id) =>
            {
                self.fetch(cx);
            }
            Event::QueueChanged(queue) => self.set_queue(queue.clone(), cx),
            Event::ComposerInsertText(e) if e.chat_id == self.chat_id => {
                cx.emit(ChatStoreEvent::InsertText {
                    text: e.text.clone(),
                    only_into_empty: e.only_into_empty,
                })
            }
            Event::ChatPromptsChanged(state) if state.chat_id == self.chat_id => {
                self.prompt_round += 1;
                self.set_prompt(state.clone(), cx);
            }
            Event::McpAppsEvent(event) => cx.emit(ChatStoreEvent::McpApp(event.clone())),
            Event::HermesWorkChanged(_) => self.hermes.update(cx, |h, cx| h.on_event(event, cx)),
            _ => {}
        }
    }

    /// Routes a `turn.*` event for one of a comparison's other answers to
    /// its overlay. True when it was one.
    fn on_companion_event(&mut self, event: &Event, cx: &mut Context<Self>) -> bool {
        let (chat, id) = match event {
            Event::TurnDelta(e) => (&e.chat_id, &e.message_id),
            Event::TurnBlocks(e) => (&e.chat_id, &e.message_id),
            Event::TurnCompleted(e) => (&e.chat_id, &e.message_id),
            Event::TurnFailed(e) => (&e.chat_id, &e.message_id),
            _ => return false,
        };
        if *chat != self.chat_id {
            return false;
        }
        let Some(c) = self.companions.iter_mut().find(|c| &c.message_id == id) else {
            return false;
        };
        match event {
            Event::TurnDelta(e) if c.streaming() => c.text = e.text.clone(),
            Event::TurnBlocks(e) => c.blocks = known_blocks(&e.blocks),
            Event::TurnCompleted(e) => {
                c.text = e.text.clone();
                c.phase = LivePhase::Completed;
                self.fetch(cx);
            }
            Event::TurnFailed(e) => {
                if c.text.is_empty() {
                    c.text = e.partial_text.clone();
                }
                c.phase = LivePhase::Failed {
                    code: e.code.clone(),
                    detail: e.args.get("detail").cloned().filter(|d| !d.is_empty()),
                    kind: e.args.get("type").cloned().filter(|d| !d.is_empty()),
                };
                self.fetch(cx);
            }
            _ => {}
        }
        self.live_rev += 1;
        cx.notify();
        true
    }

    /// The overlay for `message_id`, made if it is a new turn. A regenerate
    /// still waiting for its answer's id takes the first one named: the
    /// daemon runs one turn per chat, so it is that answer (its events can
    /// come before `turns.regenerate` replies).
    fn live_for(&mut self, message_id: &str) -> &mut LiveTurn {
        if let Some(live) = &mut self.live
            && live.awaiting_id
            && live.message_id != message_id
        {
            let old = std::mem::replace(&mut live.message_id, message_id.to_string());
            live.awaiting_id = false;
            // A new id never holds the old text.
            live.stale_text = None;
            self.keep_row_key(message_id, &old);
            return self.live.as_mut().expect("just checked");
        }
        let fresh = self
            .live
            .as_ref()
            .is_none_or(|l| l.message_id != message_id);
        if fresh {
            // A regenerate's reply can arrive after its first events: keep
            // what it replaces when the ids agree later (`expect_answer`).
            let mut live = LiveTurn::new(message_id);
            // An answer that goes on where it stopped (a prompt answered, a
            // queued answer sent) starts from what it already says.
            if let Some(stored) = self
                .messages()
                .iter()
                .find(|m| m.id == message_id && m.role == "assistant")
            {
                live.text = stored.content.clone();
                live.blocks = known_blocks(&stored.blocks);
            }
            self.live = Some(live);
        }
        self.live.as_mut().expect("just set")
    }

    /// An answer is on its way under `message_id` (a send, edit or
    /// regenerate was accepted); `replaces` is the answer it takes over.
    fn expect_answer(&mut self, message_id: &str, replaces: Option<String>) {
        let live = self.live_for(message_id);
        if replaces.as_deref() != Some(message_id) {
            live.replaces = replaces.or(live.replaces.take());
        }
    }

    /// `new` (a regenerate's answer) keeps the row key of `old`, the answer
    /// it replaces.
    fn keep_row_key(&mut self, new: &str, old: &str) {
        if new == old {
            return;
        }
        let key = self
            .row_keys
            .get(old)
            .cloned()
            .unwrap_or_else(|| old.to_string());
        self.row_keys.insert(new.to_string(), key.clone());
        self.newest_for_key.insert(key, new.to_string());
    }

    /// A new daemon session or lost events: subscribe again (the daemon
    /// replays a running turn) and refetch.
    pub fn on_reconnected(&mut self, cx: &mut Context<Self>) {
        self.resubscribe(cx);
        self.fetch(cx);
        // A queue read that failed, or one the new daemon session holds.
        self.refresh_queue(cx);
        self.hermes.update(cx, |h, cx| h.on_reconnected(cx));
    }

    /// `route.remap`: the chat is now `to`.
    pub fn remap(&mut self, from: &str, to: &str, cx: &mut Context<Self>) {
        if self.chat_id != from || from == to {
            return;
        }
        self.chat_id = to.to_string();
        self.queue.chat_id = self.chat_id.clone();
        self.hermes.update(cx, |h, cx| h.remap(to, cx));
        self.resubscribe(cx);
        self.fetch(cx);
        self.refresh_queue(cx);
        cx.notify();
    }

    // ── Rows ────────────────────────────────────────────────────────────

    /// Recomputes which rows show, in order.
    fn rebuild(&mut self, cx: &mut Context<Self>) {
        let messages = self.messages();
        let pending_shown = self.pending.as_ref().filter(|p| {
            p.message_id
                .as_ref()
                .is_none_or(|id| !messages.iter().any(|m| &m.id == id))
        });
        // An edit in flight hides the question it replaces and what follows.
        let cut = pending_shown
            .and_then(|p| p.replaces.as_ref())
            .and_then(|id| messages.iter().position(|m| &m.id == id))
            .unwrap_or(messages.len());
        let hidden = cut.saturating_sub(self.window);
        let mut rows = Vec::with_capacity(cut - hidden + 2);
        // The overlay takes the place of the stored row with its own id (the
        // empty placeholder the server made), else of the answer a
        // regenerate replaces, else goes at the end.
        let live_at = self.live.as_ref().and_then(|live| {
            messages
                .iter()
                .position(|m| m.id == live.message_id)
                .or_else(|| {
                    live.replaces
                        .as_deref()
                        .and_then(|old| messages.iter().position(|m| m.id == old))
                })
        });
        // Never a row of its own: an answer another message carries as one
        // of its versions (a sibling branch, which a copy saved mid-regenerate
        // can list beside the new answer), or one a regenerate here replaced
        // once the stored copy has the new answer. Not the message itself: a
        // regenerate that keeps the answer's id (Hermes, Direct) lists what
        // it said before under that same id.
        let versions: std::collections::HashSet<&str> = messages
            .iter()
            .flat_map(|m| {
                m.versions
                    .iter()
                    .filter(move |v| v.id != m.id)
                    .map(|v| v.id.as_str())
            })
            .collect();
        let present: std::collections::HashSet<&str> =
            messages.iter().map(|m| m.id.as_str()).collect();
        let replaced = |id: &str| {
            let key = self.row_keys.get(id).map_or(id, String::as_str);
            self.newest_for_key
                .get(key)
                .is_some_and(|newest| newest != id && present.contains(newest.as_str()))
        };
        let mut live_placed = false;
        for (i, m) in messages.iter().enumerate().take(cut).skip(hidden) {
            if live_at == Some(i) {
                rows.push(Row::Live);
                live_placed = true;
                continue;
            }
            if let Some(live) = &self.live
                && (live.message_id == m.id || live.replaces.as_deref() == Some(&m.id))
            {
                continue;
            }
            if m.role == "assistant" && (versions.contains(m.id.as_str()) || replaced(&m.id)) {
                continue;
            }
            rows.push(Row::Stored(i));
        }
        if pending_shown.is_some() {
            rows.push(Row::Pending);
        }
        if self.live.is_some() && !live_placed {
            rows.push(Row::Live);
        }
        if self.waits() {
            rows.push(Row::Waiting);
        }
        self.rows = rows;
        self.hidden = hidden;
        self.stored_rev += 1;
        self.live_rev += 1;
        cx.notify();
    }

    /// `(stored, live)` change counters: the transcript remeasures every
    /// row when the first moves, and only the live one when the second
    /// does.
    pub fn revisions(&self) -> (u64, u64) {
        (self.stored_rev, self.live_rev)
    }

    pub fn rows(&self) -> &[Row] {
        &self.rows
    }

    /// Stored messages older than the shown window.
    pub fn hidden(&self) -> usize {
        self.hidden
    }

    /// Shows another page of older messages. Returns how many rows came in
    /// at the top.
    pub fn load_older(&mut self, cx: &mut Context<Self>) -> usize {
        if self.hidden == 0 {
            return 0;
        }
        let before = self.rows.len();
        self.window += PAGE;
        self.rebuild(cx);
        self.rows.len() - before
    }

    /// The row showing `key` (its row key or its message's id), if one
    /// does.
    pub fn row_for_key(&self, key: &str) -> Option<Row> {
        self.rows
            .iter()
            .copied()
            .find(|r| self.row_key(*r) == key || self.message_key(*r) == key)
    }

    /// The key a row keeps across frames: its message's id, or for a
    /// regenerate's answer the key of the answer it replaced (the row is
    /// the same row from the regenerate to the stored copy).
    pub fn row_key(&self, row: Row) -> String {
        let id = self.message_key(row);
        self.row_keys.get(&id).cloned().unwrap_or(id)
    }

    /// The id of the message a row shows (`pending`, `waiting` for those).
    fn message_key(&self, row: Row) -> String {
        match row {
            Row::Stored(i) => self.messages()[i].id.clone(),
            Row::Pending => "pending".into(),
            Row::Waiting => "waiting".into(),
            Row::Live => self
                .live
                .as_ref()
                .map(|l| l.message_id.clone())
                .unwrap_or_default(),
        }
    }

    /// The row's view model.
    pub fn item(&self, row: Row) -> Option<RowItem> {
        let last_answer = self.last_answer_row() == Some(row);
        match row {
            Row::Stored(i) => {
                let m = self.messages().get(i)?;
                let assistant = m.role == "assistant";
                // The version this window shows: the message itself, or (a
                // switch on its way, or a chat that cannot branch) another.
                let shown_ix = self
                    .versions
                    .get(&m.id)
                    .copied()
                    .filter(|ix| *ix < m.versions.len());
                let shown = shown_ix.map(|ix| &m.versions[ix]);
                let shown_id = shown.map_or(m.id.as_str(), |v| v.id.as_str());
                let compared = assistant && m.comparison.len() > 1;
                let version = if compared {
                    None
                } else if m.sibling_ids.len() > 1
                    && let Some(at) = m.sibling_ids.iter().position(|id| id == shown_id)
                {
                    Some((at + 1, m.sibling_ids.len()))
                } else if !m.versions.is_empty() {
                    let at = shown_ix.unwrap_or(m.versions.len());
                    Some((at + 1, m.versions.len() + 1))
                } else {
                    None
                };
                let (text, blocks, sources, (model, model_name), usage, stored_merged) = match shown
                {
                    Some(v) => (
                        v.content.clone(),
                        if assistant {
                            known_blocks(&v.blocks)
                        } else {
                            vec![]
                        },
                        v.sources.clone(),
                        // A version with a model of its own goes by its own
                        // name; one without, by the message's.
                        match &v.model {
                            Some(own) => (Some(own.clone()), v.model_name.clone()),
                            None => (
                                m.model.clone(),
                                v.model_name.clone().or(m.model_name.clone()),
                            ),
                        },
                        v.usage.clone(),
                        v.merged.clone(),
                    ),
                    None => (
                        m.content.clone(),
                        if assistant {
                            known_blocks(&m.blocks)
                        } else {
                            vec![]
                        },
                        m.sources.clone(),
                        (m.model.clone(), m.model_name.clone()),
                        m.usage.clone(),
                        m.merged.clone(),
                    ),
                };
                let merge = self.merge.as_ref().filter(|p| p.target_id == shown_id);
                let merged = match merge {
                    Some(p) if p.running || stored_merged.is_none() => {
                        (!p.text.is_empty()).then(|| p.text.clone())
                    }
                    _ => stored_merged.filter(|t| !t.trim().is_empty()),
                };
                let columns = if compared { compare_columns(m) } else { vec![] };
                // An older version's rating is not stored: no thumb.
                let current = shown.is_none();
                Some(RowItem {
                    key: m.id.clone(),
                    role: if assistant {
                        Role::Assistant
                    } else {
                        Role::User
                    },
                    text,
                    blocks,
                    files: m.files.clone(),
                    sources: if assistant { sources } else { vec![] },
                    model,
                    model_name: model_name.filter(|_| assistant),
                    timestamp_ms: Some(m.timestamp_ms),
                    streaming: m.streaming,
                    rating: current
                        .then(|| self.ratings.get(&m.id).copied().or(m.rating))
                        .flatten(),
                    version,
                    stored: true,
                    last_answer,
                    stale: false,
                    usage: usage.filter(|_| assistant),
                    merged,
                    merging: merge.is_some_and(|p| p.running),
                    retry_without_effort: current && m.retry_without_effort,
                    columns,
                    mergeable: m.mergeable_ids.clone(),
                    siblings: m.sibling_ids.clone(),
                    queued: if assistant { m.queued.clone() } else { None },
                })
            }
            Row::Pending => {
                let p = self.pending.as_ref()?;
                Some(RowItem {
                    key: "pending".into(),
                    role: Role::User,
                    text: p.text.clone(),
                    blocks: vec![],
                    files: p.files.clone(),
                    sources: vec![],
                    model: None,
                    timestamp_ms: None,
                    streaming: false,
                    rating: None,
                    version: None,
                    stored: false,
                    last_answer: false,
                    stale: false,
                    ..Default::default()
                })
            }
            Row::Waiting => Some(RowItem {
                key: "waiting".into(),
                role: Role::Assistant,
                text: String::new(),
                blocks: vec![],
                files: vec![],
                sources: vec![],
                model: self.model_hint.clone(),
                timestamp_ms: None,
                streaming: true,
                rating: None,
                version: None,
                stored: false,
                last_answer,
                stale: false,
                ..Default::default()
            }),
            Row::Live => {
                let l = self.live.as_ref()?;
                // A regenerate: the answer will be the newest of one more
                // version than the one it replaces had, so the pager keeps
                // its place in the action row from the start.
                let version = l
                    .replaces
                    .as_deref()
                    .or(l.stale_text.is_some().then_some(l.message_id.as_str()))
                    .and_then(|id| self.messages().iter().find(|m| m.id == id))
                    .map(|m| (m.versions.len() + 2, m.versions.len() + 2));
                // A regenerate with nothing new to show yet (no blocks, or
                // only an empty text): the answer it replaces, dimmed
                // (rather than a "waiting" line for a moment).
                if l.streaming()
                    && !shows_anything(&l.blocks)
                    && let Some(old) = self.messages().iter().find(|m| {
                        m.id == l.replaces.as_deref().unwrap_or(&l.message_id)
                            && m.role == "assistant"
                            && !m.blocks.is_empty()
                    })
                {
                    return Some(RowItem {
                        key: l.message_id.clone(),
                        role: Role::Assistant,
                        text: old.content.clone(),
                        blocks: known_blocks(&old.blocks)
                            .into_iter()
                            .filter(|b| b.kind != MessageBlockKind::FollowUps)
                            .collect(),
                        files: vec![],
                        sources: vec![],
                        model: l.model.clone().or_else(|| old.model.clone()),
                        timestamp_ms: None,
                        streaming: true,
                        rating: None,
                        version,
                        stored: false,
                        last_answer,
                        stale: true,
                        ..Default::default()
                    });
                }
                let blocks = l.display_blocks();
                let sources = blocks
                    .iter()
                    .find(|b| b.kind == MessageBlockKind::Sources)
                    .and_then(|b| b.sources.clone())
                    .unwrap_or_default();
                // A comparison: the first model's answer and the others'
                // overlays, side by side.
                let columns = if self.companions.is_empty() {
                    vec![]
                } else {
                    let model = l.model.clone().or_else(|| self.model_hint.clone());
                    std::iter::once(CompareColumn {
                        answer_id: l.message_id.clone(),
                        model,
                        text: l.text.clone(),
                        blocks: blocks.clone(),
                        streaming: l.streaming(),
                        current: true,
                    })
                    .chain(self.companions.iter().map(|c| CompareColumn {
                        answer_id: c.message_id.clone(),
                        model: c.model.clone(),
                        text: c.text.clone(),
                        blocks: c.display_blocks(),
                        streaming: c.streaming(),
                        current: false,
                    }))
                    .collect()
                };
                Some(RowItem {
                    key: l.message_id.clone(),
                    role: Role::Assistant,
                    text: l.text.clone(),
                    blocks,
                    files: vec![],
                    sources,
                    model: l.model.clone().or_else(|| self.model_hint.clone()),
                    timestamp_ms: None,
                    streaming: l.streaming() || self.companions.iter().any(LiveTurn::streaming),
                    rating: self.ratings.get(&l.message_id).copied(),
                    version,
                    stored: false,
                    last_answer,
                    stale: false,
                    columns,
                    ..Default::default()
                })
            }
        }
    }

    fn last_answer_row(&self) -> Option<Row> {
        self.rows.iter().rev().copied().find(|row| match row {
            Row::Live | Row::Waiting => true,
            // A message sent and not answered yet: no answer is the last
            // (its suggestions go at once).
            Row::Pending => true,
            Row::Stored(i) => self
                .messages()
                .get(*i)
                .is_some_and(|m| m.role == "assistant"),
        })
    }

    // ── State ───────────────────────────────────────────────────────────

    /// An answer is being written, or one is on its way (Stop shows
    /// instead of Send).
    pub fn is_streaming(&self) -> bool {
        self.awaiting
            || self.live.as_ref().is_some_and(LiveTurn::streaming)
            || self.companions.iter().any(LiveTurn::streaming)
            || self.messages().last().is_some_and(|m| m.streaming)
    }

    /// The waiting row shows: a turn is on its way and its overlay has not
    /// started streaming yet.
    fn waits(&self) -> bool {
        self.awaiting && !self.live.as_ref().is_some_and(LiveTurn::streaming)
    }

    /// `turns.send` or `turns.edit` came back: the waiting row gives way to
    /// the turn's overlay (or to nothing, if it was refused). A Stop
    /// pressed while it was on its way goes out now.
    fn answered(&mut self, accepted: bool, cx: &mut Context<Self>) {
        self.awaiting = false;
        if std::mem::take(&mut self.stop_requested) && accepted {
            self.stop(cx);
        }
    }

    /// Another user's chat, reached through a folder shared with this
    /// account: it can be read but not answered, branched or rated.
    pub fn read_only(&self) -> bool {
        self.detail
            .as_ref()
            .is_some_and(|d| d.read_only || d.summary.read_only)
    }

    /// Edit, regenerate and rate apply: a stored chat of this account with
    /// nothing streaming (and not a Hermes session another Hermes app owns).
    pub fn can_branch(&self) -> bool {
        !self.temporary && !self.read_only() && !self.hermes_read_only() && !self.is_streaming()
    }

    /// A Hermes session's chat: its session, and whether this app may
    /// continue it.
    pub fn hermes(&self) -> Option<&conduit_protocol::HermesChatDto> {
        self.detail.as_ref().and_then(|d| d.hermes.as_ref())
    }

    /// A Hermes session another Hermes app owns: read here, continued in a
    /// session of this app's (the read-only notice).
    pub fn hermes_read_only(&self) -> bool {
        self.hermes().is_some_and(|h| h.read_only)
    }

    /// The newest stored answer's id (Chat › Regenerate).
    pub fn last_answer_id(&self) -> Option<String> {
        self.messages()
            .iter()
            .rev()
            .find(|m| m.role == "assistant")
            .map(|m| m.id.clone())
    }

    /// The newest answer's text (the live one while it streams).
    pub fn last_reply(&self) -> Option<String> {
        if let Some(live) = &self.live
            && !live.text.is_empty()
        {
            return Some(live.text.clone());
        }
        self.messages()
            .iter()
            .rev()
            .find(|m| m.role == "assistant" && !m.content.trim().is_empty())
            .map(|m| m.content.clone())
    }

    /// What the chat offers, as the daemon says (nothing until it is
    /// loaded).
    pub fn abilities(&self) -> ChatAbilities {
        self.detail
            .as_ref()
            .map(|d| d.abilities.clone())
            .unwrap_or_default()
    }

    /// The text of answer (or question) `id`: a message, or one of its
    /// versions.
    pub fn version_text(&self, id: &str) -> Option<String> {
        self.messages().iter().find_map(|m| {
            if m.id == id {
                return Some(m.content.clone());
            }
            m.versions
                .iter()
                .find(|v| v.id == id)
                .map(|v| v.content.clone())
        })
    }

    /// Makes `message_id` the chat's current answer on the server (the
    /// branch through it), in place of `alternative_to` when that is what
    /// the window shows. The stored copy the daemon answers with replaces
    /// the transcript. The task says whether it went through.
    pub fn set_current(
        &mut self,
        message_id: &str,
        alternative_to: Option<&str>,
        cx: &mut Context<Self>,
    ) -> Task<bool> {
        let asked = self.chat_id.clone();
        let call = self.rpc.call::<methods::ChatsSetCurrent>(&ChatCurrent {
            chat_id: self.chat_id.clone(),
            message_id: message_id.to_string(),
            alternative_to: alternative_to.map(str::to_string),
        });
        self.switching = true;
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result = call.await;
            this.update(cx, |s, cx| {
                s.switching = false;
                // Saved under a new id meanwhile (Save Chat): its own fetch
                // shows it, never this answer's copy of the old id.
                if s.chat_id != asked {
                    return result.is_ok();
                }
                // A fetch already on its way would put the old branch back.
                s.generation += 1;
                let ok = match result {
                    Ok(result) => {
                        if let Some(chat) = result.chat {
                            s.detail = Some(chat);
                        }
                        true
                    }
                    Err(e) => {
                        s.failed(ChatAction::Branch, &e, cx);
                        false
                    }
                };
                s.versions.clear();
                s.rebuild(cx);
                // A version chosen meanwhile: the switch to it goes out now.
                if let Some(target) = s.queued_version.take()
                    && let Some(m) = s
                        .messages()
                        .iter()
                        .find(|m| m.sibling_ids.contains(&target))
                        .map(|m| m.id.clone())
                    && m != target
                {
                    s.choose_version(&m, &target, cx);
                }
                ok
            })
            .unwrap_or(false)
        })
    }

    /// Shows version `target` of `message_id` (by its id): on the server
    /// when the chat can branch (the version shows at once, and the stored
    /// copy follows), else in this window only.
    pub fn choose_version(&mut self, message_id: &str, target: &str, cx: &mut Context<Self>) {
        let Some(m) = self.messages().iter().find(|m| m.id == message_id) else {
            return;
        };
        let local = m.versions.iter().position(|v| v.id == target);
        if target != message_id && local.is_none() {
            return;
        }
        let branch = self.abilities().branch && !self.is_streaming();
        if branch && self.switching {
            self.queued_version = Some(target.to_string());
        }
        match local {
            Some(ix) => self.show_version(message_id, ix, cx),
            None => {
                self.versions.remove(message_id);
                self.stored_rev += 1;
                cx.notify();
            }
        }
        if branch && !self.switching && target != message_id {
            self.set_current(target, Some(message_id), cx).detach();
        }
    }

    /// The version shown of `m`, by id.
    fn shown_version_id(&self, m: &ChatMessageDto) -> String {
        self.versions
            .get(&m.id)
            .and_then(|ix| m.versions.get(*ix))
            .map_or(m.id.clone(), |v| v.id.clone())
    }

    /// Shows `index` of `message_id`'s versions (`versions.len()` is the
    /// message's own content).
    pub fn show_version(&mut self, message_id: &str, index: usize, cx: &mut Context<Self>) {
        self.versions.insert(message_id.to_string(), index);
        self.stored_rev += 1;
        cx.notify();
    }

    /// Steps the shown version by `delta`, within bounds: in the server's
    /// order, switching the chat's branch when it can branch. Says where it
    /// landed, when it moved.
    pub fn step_version(
        &mut self,
        message_id: &str,
        delta: isize,
        cx: &mut Context<Self>,
    ) -> Option<VersionStep> {
        let m = self.messages().iter().find(|m| m.id == message_id)?;
        if m.sibling_ids.len() > 1 {
            let shown = self.shown_version_id(m);
            let at = m.sibling_ids.iter().position(|id| *id == shown)?;
            let total = m.sibling_ids.len();
            let next = (at as isize + delta).clamp(0, total as isize - 1) as usize;
            if next == at {
                return None;
            }
            let target = m.sibling_ids[next].clone();
            let branch = self.abilities().branch && !self.is_streaming();
            self.choose_version(message_id, &target, cx);
            return Some(VersionStep {
                index: next + 1,
                total,
                branch,
            });
        }
        let total = m.versions.len();
        let shown = self
            .versions
            .get(message_id)
            .copied()
            .unwrap_or(total)
            .min(total);
        let next = (shown as isize + delta).clamp(0, total as isize) as usize;
        if next == shown {
            return None;
        }
        self.show_version(message_id, next, cx);
        Some(VersionStep {
            index: next + 1,
            total: total + 1,
            branch: false,
        })
    }

    // ── Actions ─────────────────────────────────────────────────────────

    /// A branch switch (`chats.setCurrent`) is on its way.
    pub fn is_switching(&self) -> bool {
        self.switching
    }

    pub(crate) fn failed(&mut self, action: ChatAction, e: &RpcError, cx: &mut Context<Self>) {
        log::warn!("{action:?} failed: {e}");
        cx.emit(ChatStoreEvent::Failed {
            action,
            error: e.to_string(),
            reason: e.args.get("reason").cloned(),
        });
    }

    /// Sends a message in this chat. The message shows at once; the task
    /// resolves with the daemon's answer (the composer restores its text
    /// on an error).
    pub fn send(
        &mut self,
        mut turn: SendTurn,
        pending: PendingMessage,
        cx: &mut Context<Self>,
    ) -> Task<Result<SendTurnAccepted, RpcError>> {
        turn.chat_id = Some(self.chat_id.clone());
        self.pending = Some(pending.clone());
        self.awaiting = true;
        self.rebuild(cx);
        let call = self.rpc.call::<methods::TurnsSend>(&turn);
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result = call.await;
            let _ = this.update(cx, |s, cx| match &result {
                Ok(accepted) => {
                    s.pending = Some(PendingMessage {
                        message_id: Some(accepted.user_message_id.clone()),
                        ..pending
                    });
                    s.expect_answer(&accepted.assistant_message_id, None);
                    s.answered(true, cx);
                    s.rebuild(cx);
                }
                Err(e) => {
                    s.pending = None;
                    s.answered(false, cx);
                    s.failed(ChatAction::Send, e, cx);
                    s.rebuild(cx);
                }
            });
            result
        })
    }

    /// `turns.stop`. Before the daemon has taken the turn there is nothing
    /// to stop yet: it goes out once it has ([`Self::answered`]).
    pub fn stop(&mut self, cx: &mut Context<Self>) {
        // A regenerate's placeholder streams at once, before the daemon has
        // taken the turn: its Stop waits for that too.
        let regenerate_pending = self.live.as_ref().is_some_and(|l| l.awaiting_id);
        if self.waits() || regenerate_pending {
            self.stop_requested = true;
            return;
        }
        let call = self.rpc.call::<methods::TurnsStop>(&StopTurn {
            chat_id: self.chat_id.clone(),
        });
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            if let Err(e) = call.await {
                let _ = this.update(cx, |s, cx| s.failed(ChatAction::Stop, &e, cx));
            }
        })
        .detach();
    }

    /// Runs `message_id` (an answer) again, optionally with `model`.
    pub fn regenerate(&mut self, message_id: &str, model: Option<String>, cx: &mut Context<Self>) {
        self.regenerate_with(message_id, model, false, cx);
    }

    /// Runs `message_id` again: with `model` (Regenerate With), and, with
    /// `without_effort`, after setting the reasoning effort the chat and the
    /// picker sent back to automatic (Retry Without Reasoning Effort).
    pub fn regenerate_with(
        &mut self,
        message_id: &str,
        model: Option<String>,
        without_effort: bool,
        cx: &mut Context<Self>,
    ) {
        if !self.can_branch() {
            return;
        }
        let call = self.rpc.call::<methods::TurnsRegenerate>(&RegenerateTurn {
            chat_id: self.chat_id.clone(),
            message_id: message_id.to_string(),
            model,
            without_reasoning_effort: without_effort,
        });
        // Shown as an answer on its way straight away, over the old one.
        let old = message_id.to_string();
        let stale_text = self
            .messages()
            .iter()
            .find(|m| m.id == old)
            .map(|m| m.content.clone());
        self.live = Some(LiveTurn {
            replaces: Some(old.clone()),
            stale_text,
            awaiting_id: true,
            ..LiveTurn::new(old.clone())
        });
        self.versions.remove(&old);
        self.rebuild(cx);
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result = call.await;
            let _ = this.update(cx, |s, cx| match result {
                Ok(accepted) => {
                    // The placeholder made above stands for the new answer
                    // (unless its first event named it already).
                    if let Some(live) = &mut s.live
                        && live.message_id == old
                    {
                        live.awaiting_id = false;
                        if accepted.assistant_message_id != old {
                            live.message_id = accepted.assistant_message_id.clone();
                            // A new id never holds the old text.
                            live.stale_text = None;
                        }
                    }
                    s.keep_row_key(&accepted.assistant_message_id, &old);
                    s.expect_answer(&accepted.assistant_message_id, Some(old));
                    s.rebuild(cx);
                    // A Stop pressed while it was on its way goes out now.
                    if std::mem::take(&mut s.stop_requested) {
                        s.stop(cx);
                    }
                }
                Err(e) => {
                    s.stop_requested = false;
                    if s.live.as_ref().is_some_and(|l| l.message_id == old) {
                        s.live = None;
                    }
                    s.failed(ChatAction::Regenerate, &e, cx);
                    s.rebuild(cx);
                }
            });
        })
        .detach();
    }

    /// Replaces the question `message_id` with `text` and answers it (a new
    /// branch on the server).
    pub fn edit(&mut self, message_id: &str, text: String, cx: &mut Context<Self>) {
        if !self.can_branch() || text.trim().is_empty() {
            return;
        }
        let call = self.rpc.call::<methods::TurnsEdit>(&EditTurn {
            chat_id: self.chat_id.clone(),
            message_id: message_id.to_string(),
            text: text.clone(),
            model: None,
        });
        let pending = PendingMessage {
            replaces: Some(message_id.to_string()),
            ..PendingMessage::new(text)
        };
        self.pending = Some(pending.clone());
        self.awaiting = true;
        self.rebuild(cx);
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result = call.await;
            let _ = this.update(cx, |s, cx| {
                match result {
                    Ok(accepted) => {
                        s.pending = Some(PendingMessage {
                            message_id: Some(accepted.user_message_id.clone()),
                            ..pending
                        });
                        s.expect_answer(&accepted.assistant_message_id, None);
                        s.answered(true, cx);
                    }
                    Err(e) => {
                        s.pending = None;
                        s.answered(false, cx);
                        s.failed(ChatAction::Edit, &e, cx);
                    }
                }
                s.rebuild(cx);
            });
        })
        .detach();
    }

    /// Rates an answer: shown at once, taken back if the daemon refuses.
    pub fn rate(&mut self, message_id: &str, rating: i64, cx: &mut Context<Self>) {
        if self.temporary {
            return;
        }
        let previous = self.ratings.insert(message_id.to_string(), rating);
        self.stored_rev += 1;
        cx.notify();
        let call = self.rpc.call::<methods::TurnsRate>(&RateTurn {
            chat_id: self.chat_id.clone(),
            message_id: message_id.to_string(),
            rating,
        });
        let id = message_id.to_string();
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let refused = match call.await {
                Ok(r) if r.rated => None,
                Ok(_) => Some(conduit_daemon::protocol::error(
                    "rating.refused",
                    "the server did not take the rating",
                )),
                Err(e) => Some(e),
            };
            if let Some(e) = refused {
                let _ = this.update(cx, |s, cx| {
                    // Only if nothing newer replaced it meanwhile.
                    if s.ratings.get(&id) == Some(&rating) {
                        match previous {
                            Some(p) => s.ratings.insert(id.clone(), p),
                            None => s.ratings.remove(&id),
                        };
                    }
                    s.stored_rev += 1;
                    s.failed(ChatAction::Rate, &e, cx);
                    cx.notify();
                });
            }
        })
        .detach();
    }
}

impl ChatStore {
    /// How many messages deleting `ids` removes (the answers to a question
    /// go with it), for the confirmation; nothing is deleted.
    pub fn delete_count(&self, ids: Vec<String>, cx: &App) -> Task<Result<i64, RpcError>> {
        let call = self.rpc.call::<methods::MessagesDelete>(&DeleteMessages {
            chat_id: self.chat_id.clone(),
            message_ids: ids,
            dry_run: true,
        });
        cx.background_spawn(async move { call.await.map(|r| r.count) })
    }

    /// Deletes `ids` (with the answers to them); the stored copy the
    /// daemon answers with replaces the transcript.
    pub fn delete_messages(&mut self, ids: Vec<String>, cx: &mut Context<Self>) {
        let asked = self.chat_id.clone();
        let call = self.rpc.call::<methods::MessagesDelete>(&DeleteMessages {
            chat_id: self.chat_id.clone(),
            message_ids: ids,
            dry_run: false,
        });
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result = call.await;
            let _ = this.update(cx, |s, cx| {
                match result {
                    // Saved under a new id meanwhile: its own fetch shows it.
                    Ok(_) if s.chat_id != asked => {}
                    Ok(done) => {
                        s.generation += 1;
                        if let Some(chat) = done.chat {
                            s.detail = Some(chat);
                        }
                        // A finished answer's overlay whose message went
                        // with the deletion goes too (no fetch would find
                        // it to clear it).
                        if let Some(live) = &s.live
                            && live.phase != LivePhase::Streaming
                            && !s.messages().iter().any(|m| {
                                m.id == live.message_id
                                    || m.versions.iter().any(|v| v.id == live.message_id)
                            })
                        {
                            s.live = None;
                        }
                    }
                    Err(e) => s.failed(ChatAction::Delete, &e, cx),
                }
                s.rebuild(cx);
            });
        })
        .detach();
    }

    /// Fork Chat: a new chat from the start of this one to `message_id`.
    pub fn fork(&mut self, message_id: &str, cx: &mut Context<Self>) -> Task<Option<ChatForked>> {
        let call = self.rpc.call::<methods::ChatsFork>(&ForkChat {
            chat_id: self.chat_id.clone(),
            message_id: message_id.to_string(),
        });
        cx.spawn(
            async move |this: WeakEntity<Self>, cx: &mut AsyncApp| match call.await {
                Ok(forked) => Some(forked),
                Err(e) => {
                    let _ = this.update(cx, |s, cx| s.failed(ChatAction::Fork, &e, cx));
                    None
                }
            },
        )
    }

    /// Merge Responses: `sources` (two or more answers of the comparison in
    /// `message_id`) merged into one, saved on `target`. The text arrives as
    /// `messages.merge`.
    pub fn merge(
        &mut self,
        message_id: &str,
        target: &str,
        sources: Vec<String>,
        cx: &mut Context<Self>,
    ) {
        let call = self.rpc.call::<methods::TurnsMerge>(&MergeTurn {
            chat_id: self.chat_id.clone(),
            message_id: message_id.to_string(),
            target_id: target.to_string(),
            source_ids: sources,
            stop: false,
        });
        // Shown as running at once; the first `messages.merge` follows.
        self.merge = Some(MergeProgress {
            chat_id: self.chat_id.clone(),
            message_id: message_id.to_string(),
            target_id: target.to_string(),
            text: String::new(),
            running: true,
            error: None,
        });
        self.stored_rev += 1;
        cx.notify();
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            if let Err(e) = call.await {
                let _ = this.update(cx, |s, cx| {
                    s.merge = None;
                    s.stored_rev += 1;
                    s.failed(ChatAction::Merge, &e, cx);
                    cx.notify();
                });
            }
        })
        .detach();
    }

    /// A merge is running in this chat.
    pub fn merging(&self) -> bool {
        self.merge.as_ref().is_some_and(|m| m.running)
    }

    /// Stops the merge running in this chat (what arrived is kept).
    pub fn stop_merge(&mut self, cx: &mut Context<Self>) {
        let Some(merge) = self.merge.clone() else {
            return;
        };
        let call = self.rpc.call::<methods::TurnsMerge>(&MergeTurn {
            chat_id: self.chat_id.clone(),
            message_id: merge.message_id,
            target_id: merge.target_id,
            source_ids: vec![],
            stop: true,
        });
        cx.background_spawn(async move {
            if let Err(e) = call.await {
                log::warn!("turns.merge (stop): {e}");
            }
        })
        .detach();
    }

    /// Save Chat: this temporary chat becomes a stored one. The daemon
    /// answers with its new id (and `route.remap` moves the windows to it).
    pub fn save_temporary(&mut self, cx: &mut Context<Self>) -> Task<Option<ChatForked>> {
        let call = self.rpc.call::<methods::ChatsSaveTemporary>(&ChatRef {
            id: self.chat_id.clone(),
        });
        cx.spawn(
            async move |this: WeakEntity<Self>, cx: &mut AsyncApp| match call.await {
                Ok(saved) => {
                    let _ = this.update(cx, |s, cx| {
                        s.temporary = false;
                        let from = s.chat_id.clone();
                        s.remap(&from, &saved.chat_id, cx);
                    });
                    Some(saved)
                }
                Err(e) => {
                    let _ = this.update(cx, |s, cx| s.failed(ChatAction::Save, &e, cx));
                    None
                }
            },
        )
    }
}

/// Whether the stored transcript has `message_id`'s answer: the message
/// with content, an error or blocks and no longer streaming (and not still
/// the `stale` text a same-id regenerate replaces), a version of another
/// message with content, or the answer queued (its request waits to go
/// out, which the stored row shows).
pub fn stored_has_answer(
    messages: &[ChatMessageDto],
    message_id: &str,
    stale: Option<&str>,
) -> bool {
    messages.iter().any(|m| {
        (m.id == message_id && m.queued.is_some())
            || (m.id == message_id
                && !m.streaming
                && stale.is_none_or(|old| old != m.content)
                && (!m.content.trim().is_empty() || m.error_code.is_some() || !m.blocks.is_empty()))
            || m.versions
                .iter()
                .any(|v| v.id == message_id && !v.content.trim().is_empty())
    })
}

/// Whether the stored `message_id` shows its answer queued: its request
/// waits to go out, and nothing streams it.
pub fn stored_queued(messages: &[ChatMessageDto], message_id: &str) -> bool {
    messages
        .iter()
        .any(|m| m.id == message_id && m.queued.is_some())
}

/// Whether the stored `message_id` is a strict beginning of the answer
/// `live` (the copy the server saved mid-stream, not the finished one).
pub fn stored_behind(messages: &[ChatMessageDto], message_id: &str, live: &str) -> bool {
    let live = live.trim_end();
    messages.iter().any(|m| {
        let stored = m.content.trim_end();
        m.id == message_id && stored.len() < live.len() && live.starts_with(stored)
    })
}

/// The merged response the stored copy has on answer `id` (a message or
/// one of its versions).
pub fn stored_merged(messages: &[ChatMessageDto], id: &str) -> Option<String> {
    messages.iter().find_map(|m| {
        if m.id == id {
            return m.merged.clone();
        }
        m.versions
            .iter()
            .find(|v| v.id == id)
            .and_then(|v| v.merged.clone())
    })
}

/// A stored Compare Models answer's columns: each model's newest answer,
/// from the message itself or its versions.
pub fn compare_columns(m: &ChatMessageDto) -> Vec<CompareColumn> {
    m.comparison
        .iter()
        .filter_map(|slot| {
            let id = slot.answer_ids.last()?;
            if *id == m.id {
                return Some(CompareColumn {
                    answer_id: m.id.clone(),
                    model: m.model.clone().or(slot.model.clone()),
                    text: m.content.clone(),
                    blocks: known_blocks(&m.blocks),
                    streaming: m.streaming,
                    current: true,
                });
            }
            let v = m.versions.iter().find(|v| &v.id == id)?;
            Some(CompareColumn {
                answer_id: v.id.clone(),
                model: v.model.clone().or(slot.model.clone()),
                text: v.content.clone(),
                blocks: known_blocks(&v.blocks),
                streaming: v.streaming,
                current: false,
            })
        })
        .collect()
}

/// The parameters of a new turn, from the composer.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct TurnOptions {
    pub model: Option<String>,
    pub tool_ids: Vec<String>,
    pub filter_ids: Vec<String>,
    pub knowledge: Vec<KnowledgeSummary>,
    /// Notes, knowledge files, web pages and transcripts.
    pub context: Vec<ContextAttachmentDto>,
    /// `@` users and channels and `$` skills in the text.
    pub mentions: Vec<ComposerMentionDto>,
    pub web_search: bool,
    pub image_generation: bool,
    pub code_interpreter: bool,
    pub file_ids: Vec<String>,
    /// Compare Models: the two models to answer side by side.
    pub compare_models: Vec<String>,
    /// A new chat made in this folder (New Chat in Folder).
    pub folder_id: Option<String>,
    /// A new chat's own settings (Chat Settings on a new chat).
    pub chat_params: Option<serde_json::Value>,
}

/// A chat's queue with nothing in it.
pub fn empty_queue(chat_id: String) -> QueueState {
    QueueState {
        chat_id,
        drafts: vec![],
        phase: conduit_protocol::QueuePhase::Idle,
        admission_failed: false,
        offer: false,
    }
}

impl TurnOptions {
    pub fn into_turn(self, text: String, chat_id: Option<String>, temporary: bool) -> SendTurn {
        SendTurn {
            chat_id,
            model: self.model,
            text,
            tool_ids: self.tool_ids,
            knowledge: self.knowledge,
            web_search: self.web_search,
            image_generation: self.image_generation,
            code_interpreter: self.code_interpreter,
            file_ids: self.file_ids,
            context: self.context,
            mentions: self.mentions,
            filter_ids: self.filter_ids,
            // A temporary chat is never compared: the server stores no
            // second answer for it.
            compare_models: if temporary {
                vec![]
            } else {
                self.compare_models
            },
            temporary,
            folder_id: self.folder_id,
            chat_params: self.chat_params,
        }
    }

    /// The same message queued behind the running answer of `chat_id`. Its
    /// knowledge bases go as context, as the core attaches a whole base (a
    /// knowledge entry with no file). The switches and tools are the chat's
    /// own when the queue sends it.
    pub fn into_queued(self, text: String, chat_id: String) -> QueueAdd {
        let mut context = self.context;
        context.extend(self.knowledge.into_iter().map(|k| ContextAttachmentDto {
            id: k.id,
            kind: conduit_protocol::ContextAttachmentKind::Knowledge,
            name: k.name,
            url: None,
            content: k.description,
            collection_name: None,
            file_id: None,
        }));
        QueueAdd {
            chat_id,
            text,
            mentions: self.mentions,
            file_ids: self.file_ids,
            context,
        }
    }
}

#[cfg(test)]
mod tests {
    use std::cell::RefCell;
    use std::collections::BTreeMap;

    use conduit_protocol::{
        ChatMessageVersionDto, ChatResult, ChatSummary, ChatsChanged, RatedResult, StoppedResult,
        TurnBlocks, TurnCompleted, TurnDelta, TurnFailed, TurnFinished, TurnStarted,
    };
    use futures::FutureExt as _;
    use gpui_kit::{Entity, TestAppContext};
    use serde_json::json;

    use super::*;
    use crate::stores::rpc::fake::FakeDaemon;

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
            blocks: if role == "assistant" && !content.is_empty() {
                vec![text_block(content)]
            } else {
                vec![]
            },
            queued: None,
        }
    }

    fn text_block(md: &str) -> MessageBlockDto {
        MessageBlockDto {
            markdown: Some(md.into()),
            ..empty_block(MessageBlockKind::Text)
        }
    }

    fn chat(id: &str, messages: Vec<ChatMessageDto>) -> ChatResult {
        ChatResult {
            chat: Some(ChatDetail {
                hermes: None,
                abilities: Default::default(),
                temporary: false,
                share_id: None,
                read_only: false,
                summary: ChatSummary {
                    unread: false,
                    read_only: false,
                    id: id.into(),
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
        }
    }

    fn blocks(chat: &str, message: &str, blocks: Vec<MessageBlockDto>) -> Event {
        Event::TurnBlocks(TurnBlocks {
            chat_id: chat.into(),
            message_id: message.into(),
            blocks,
            tasks: None,
        })
    }

    type Subscribed = Rc<RefCell<Vec<Option<String>>>>;

    fn open(
        daemon: &FakeDaemon,
        id: &str,
        cx: &mut TestAppContext,
    ) -> (Entity<ChatStore>, Subscribed) {
        let seen: Subscribed = Rc::default();
        let subscribe: Subscribe = {
            let seen = seen.clone();
            Rc::new(move |id, _| seen.borrow_mut().push(id.map(String::from)))
        };
        let rpc = daemon.rpc();
        let id = id.to_string();
        let store = cx.new(|cx| ChatStore::new(rpc, subscribe, id, cx));
        cx.run_until_parked();
        (store, seen)
    }

    #[gpui_kit::test]
    fn a_queue_that_failed_to_load_is_asked_again_on_reconnect(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        daemon.once::<methods::QueueGet>(Err(conduit_daemon::protocol::error(
            "rpc.daemonUnavailable",
            "busy",
        )));
        daemon.returns::<methods::QueueGet>(
            serde_json::from_value(serde_json::json!({
                "chatId": "c1",
                "drafts": [{"id": "q1", "text": "Waiting turn"}]
            }))
            .unwrap(),
        );
        let (store, _) = open(&daemon, "c1", cx);
        assert!(store.read_with(cx, |s, _| s.queue.drafts.is_empty()));
        store.update(cx, |s, cx| s.on_reconnected(cx));
        cx.run_until_parked();
        let texts = store.read_with(cx, |s, _| {
            s.queue
                .drafts
                .iter()
                .map(|d| d.text.clone())
                .collect::<Vec<_>>()
        });
        assert_eq!(texts, vec!["Waiting turn".to_string()]);
    }

    fn keys(store: &Entity<ChatStore>, cx: &mut TestAppContext) -> Vec<String> {
        store.read_with(cx, |s, _| {
            s.rows().iter().map(|r| s.row_key(*r)).collect::<Vec<_>>()
        })
    }

    fn prompt(id: &str) -> ChatPromptDto {
        serde_json::from_value(json!({
            "id": id, "chatId": "c1", "kind": "confirmation", "title": "Proceed?",
        }))
        .unwrap()
    }

    #[gpui_kit::test]
    fn a_prompt_fetched_before_it_was_answered_never_comes_back(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        daemon.returns::<methods::ChatsGet>(chat("c1", vec![]));
        daemon.returns::<methods::ChatPromptsGet>(ChatPromptState {
            chat_id: "c1".into(),
            prompt: Some(prompt("p1")),
        });
        let (store, _) = open(&daemon, "c1", cx);
        store.read_with(cx, |s, _| assert!(s.prompt.is_some()));
        // A fetch on its way while the prompt is answered elsewhere.
        let held = daemon.hold::<methods::ChatPromptsGet>();
        store.update(cx, |s, cx| {
            s.refresh_prompt(cx);
            s.on_event(
                &Event::ChatPromptsChanged(ChatPromptState {
                    chat_id: "c1".into(),
                    prompt: None,
                }),
                cx,
            );
        });
        cx.run_until_parked();
        held.release();
        cx.run_until_parked();
        store.read_with(cx, |s, _| {
            assert!(s.prompt.is_none(), "the answered card came back")
        });
    }

    #[gpui_kit::test]
    fn a_fetch_never_leaves_an_answer_busy(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        daemon.returns::<methods::ChatsGet>(chat("c1", vec![]));
        daemon.returns::<methods::ChatPromptsGet>(ChatPromptState {
            chat_id: "c1".into(),
            prompt: Some(prompt("p1")),
        });
        daemon.on::<methods::ChatPromptsDecide>(|_| {
            Err(conduit_daemon::protocol::error("rpc.timeout", "slow"))
        });
        let (store, _) = open(&daemon, "c1", cx);
        let held = daemon.hold::<methods::ChatPromptsDecide>();
        store.update(cx, |s, cx| {
            s.decide_prompt(true, cx);
            // The chat is read again while the decision is on its way.
            s.refresh_prompt(cx);
        });
        cx.run_until_parked();
        held.release();
        cx.run_until_parked();
        store.read_with(cx, |s, _| {
            assert!(!s.prompt_busy, "the card stayed busy");
            assert!(s.prompt_failed);
        });
    }

    #[gpui_kit::test]
    fn opening_subscribes_to_the_chat_and_loads_it(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        daemon.returns::<methods::ChatsGet>(chat(
            "c1",
            vec![
                message("u1", "user", "hi"),
                message("a1", "assistant", "hello"),
            ],
        ));
        let (store, seen) = open(&daemon, "c1", cx);
        assert_eq!(*seen.borrow(), vec![Some("c1".to_string())]);
        assert_eq!(
            daemon.calls::<methods::ChatsGet>(),
            vec![json!({"id": "c1"})]
        );
        assert_eq!(keys(&store, cx), vec!["u1", "a1"]);
        store.read_with(cx, |s, _| {
            let item = s.item(s.rows()[1]).unwrap();
            assert_eq!(item.role, Role::Assistant);
            assert!(item.last_answer && item.stored);
            assert_eq!(s.title(), Some("A chat"));
        });
    }

    #[gpui_kit::test]
    fn a_chat_shared_by_another_user_is_read_only(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        let mut shared = chat(
            "c1",
            vec![
                message("u1", "user", "hi"),
                message("a1", "assistant", "hello"),
            ],
        );
        if let Some(detail) = shared.chat.as_mut() {
            detail.read_only = true;
            detail.summary.read_only = true;
        }
        daemon.returns::<methods::ChatsGet>(shared);
        let (store, _) = open(&daemon, "c1", cx);
        store.read_with(cx, |s, _| {
            assert!(s.read_only());
            // No edit, regenerate or rating on a stored chat that isn't ours.
            assert!(!s.can_branch());
        });

        // The account's own chat branches as before.
        let own = FakeDaemon::new();
        own.returns::<methods::ChatsGet>(chat("c2", vec![message("u1", "user", "hi")]));
        let (store, _) = open(&own, "c2", cx);
        store.read_with(cx, |s, _| {
            assert!(!s.read_only());
            assert!(s.can_branch());
        });
    }

    #[gpui_kit::test]
    fn each_blocks_snapshot_replaces_the_overlay_and_skips_unknown_kinds(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        daemon.returns::<methods::ChatsGet>(chat(
            "c1",
            vec![message("u1", "user", "hi"), message("a1", "assistant", "")],
        ));
        let (store, _) = open(&daemon, "c1", cx);
        store.update(cx, |s, cx| {
            s.on_event(
                &blocks(
                    "c1",
                    "a1",
                    vec![text_block("Hel"), empty_block(MessageBlockKind::Unknown)],
                ),
                cx,
            );
            // Another chat's turn paints nothing here.
            s.on_event(&blocks("other", "x", vec![text_block("no")]), cx);
        });
        // The overlay takes the empty placeholder's place.
        assert_eq!(keys(&store, cx), vec!["u1", "a1"]);
        store.update(cx, |s, cx| {
            s.on_event(&blocks("c1", "a1", vec![text_block("Hello there")]), cx);
        });
        store.read_with(cx, |s, _| {
            assert_eq!(s.rows()[1], Row::Live);
            let item = s.item(Row::Live).unwrap();
            assert_eq!(item.blocks, vec![text_block("Hello there")]);
            assert!(item.streaming);
            assert!(s.is_streaming());
        });
    }

    #[gpui_kit::test]
    fn a_finished_overlay_settles_once_the_stored_copy_has_the_answer(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        daemon.once::<methods::ChatsGet>(Ok(chat("c1", vec![])));
        let (store, _) = open(&daemon, "c1", cx);
        let accepted = SendTurnAccepted {
            chat_id: "c1".into(),
            user_message_id: "u1".into(),
            assistant_message_id: "a1".into(),
        };
        store.update(cx, |s, cx| {
            s.started(PendingMessage::new("hi"), &accepted, false, cx)
        });
        assert_eq!(keys(&store, cx), vec!["pending", "a1"]);

        // Finished, but the stored copy is still the empty placeholder.
        daemon.once::<methods::ChatsGet>(Ok(chat(
            "c1",
            vec![message("u1", "user", "hi"), message("a1", "assistant", "")],
        )));
        store.update(cx, |s, cx| {
            s.on_event(&blocks("c1", "a1", vec![text_block("Hello")]), cx);
            s.on_event(
                &Event::TurnCompleted(TurnCompleted {
                    chat_id: "c1".into(),
                    message_id: "a1".into(),
                    text: "Hello".into(),
                    reasoning: None,
                    usage: None,
                }),
                cx,
            );
        });
        cx.run_until_parked();
        store.read_with(cx, |s, _| {
            assert!(s.pending.is_none(), "the stored copy has the question");
            assert_eq!(s.rows(), &[Row::Stored(0), Row::Live]);
            assert!(!s.is_streaming());
        });

        // `chats.changed` after the sync: the stored answer takes over.
        daemon.returns::<methods::ChatsGet>(chat(
            "c1",
            vec![
                message("u1", "user", "hi"),
                message("a1", "assistant", "Hello"),
            ],
        ));
        store.update(cx, |s, cx| {
            s.on_event(
                &Event::ChatsChanged(ChatsChanged {
                    chat_id: Some("c1".into()),
                }),
                cx,
            )
        });
        cx.run_until_parked();
        store.read_with(cx, |s, _| {
            assert!(s.live.is_none());
            assert_eq!(s.rows(), &[Row::Stored(0), Row::Stored(1)]);
            assert_eq!(s.last_reply().as_deref(), Some("Hello"));
        });
        // Another chat's change does not refetch.
        let before = daemon.calls::<methods::ChatsGet>().len();
        store.update(cx, |s, cx| {
            s.on_event(
                &Event::ChatsChanged(ChatsChanged {
                    chat_id: Some("c2".into()),
                }),
                cx,
            )
        });
        cx.run_until_parked();
        assert_eq!(daemon.calls::<methods::ChatsGet>().len(), before);
    }

    #[gpui_kit::test]
    fn a_finished_answer_stays_whole_while_the_stored_copy_is_behind(cx: &mut TestAppContext) {
        let full = "The orbital speed is $v = \\sqrt{GM/r}$ for a circular orbit.\n\n$$T = 2\\pi$$";
        let daemon = FakeDaemon::new();
        daemon.returns::<methods::ChatsGet>(chat(
            "c1",
            vec![
                message("u1", "user", "math"),
                message("a1", "assistant", ""),
            ],
        ));
        let (store, _) = open(&daemon, "c1", cx);
        let shown = |store: &Entity<ChatStore>, cx: &mut TestAppContext| {
            store.read_with(cx, |s, _| {
                let row = *s.rows().last().unwrap();
                s.item(row).unwrap().blocks[0].markdown.clone().unwrap()
            })
        };
        store.update(cx, |s, cx| {
            s.on_event(&blocks("c1", "a1", vec![text_block(full)]), cx);
        });
        // The turn ends while the server still has the copy it saved
        // mid-stream: only the answer's opening words.
        daemon.returns::<methods::ChatsGet>(chat(
            "c1",
            vec![
                message("u1", "user", "math"),
                ChatMessageDto {
                    blocks: vec![text_block("The orbital speed is $v = \\sqrt{GM/r}$")],
                    ..message("a1", "assistant", "The orbital speed is $v = \\sqrt{GM/r}$")
                },
            ],
        ));
        store.update(cx, |s, cx| {
            s.on_event(
                &Event::TurnCompleted(TurnCompleted {
                    chat_id: "c1".into(),
                    message_id: "a1".into(),
                    text: full.into(),
                    reasoning: None,
                    usage: None,
                }),
                cx,
            );
        });
        cx.run_until_parked();
        // No frame shows less than the answer: the overlay stays, finished.
        assert_eq!(shown(&store, cx), full);
        store.read_with(cx, |s, _| {
            assert_eq!(s.rows().last(), Some(&Row::Live));
            assert!(!s.item(Row::Live).unwrap().streaming);
        });
        let before = daemon.calls::<methods::ChatsGet>().len();

        // A moment later the stored copy has caught up and takes over.
        daemon.returns::<methods::ChatsGet>(chat(
            "c1",
            vec![
                message("u1", "user", "math"),
                ChatMessageDto {
                    blocks: vec![text_block(full)],
                    ..message("a1", "assistant", full)
                },
            ],
        ));
        cx.executor().advance_clock(BEHIND_RETRY);
        cx.run_until_parked();
        assert!(
            daemon.calls::<methods::ChatsGet>().len() > before,
            "it asked again"
        );
        store.read_with(cx, |s, _| {
            assert!(s.live.is_none());
            assert_eq!(s.rows(), &[Row::Stored(0), Row::Stored(1)]);
        });
        assert_eq!(shown(&store, cx), full);
    }

    #[gpui_kit::test]
    fn a_stored_copy_that_stays_behind_wins_after_a_few_tries(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        daemon.returns::<methods::ChatsGet>(chat(
            "c1",
            vec![
                message("u1", "user", "hi"),
                message("a1", "assistant", "Hel"),
            ],
        ));
        let (store, _) = open(&daemon, "c1", cx);
        store.update(cx, |s, cx| {
            s.on_event(&blocks("c1", "a1", vec![text_block("Hello there")]), cx);
            s.on_event(
                &Event::TurnCompleted(TurnCompleted {
                    chat_id: "c1".into(),
                    message_id: "a1".into(),
                    text: "Hello there".into(),
                    reasoning: None,
                    usage: None,
                }),
                cx,
            );
        });
        for _ in 0..=BEHIND_TRIES {
            cx.executor().advance_clock(BEHIND_RETRY);
            cx.run_until_parked();
        }
        store.read_with(cx, |s, _| assert!(s.live.is_none(), "the stored copy won"));
    }

    #[gpui_kit::test]
    fn a_failed_turn_keeps_its_partial_answer_with_the_error(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        daemon.returns::<methods::ChatsGet>(chat("c1", vec![message("u1", "user", "hi")]));
        let (store, _) = open(&daemon, "c1", cx);
        store.update(cx, |s, cx| {
            s.on_event(
                &Event::TurnStarted(TurnStarted {
                    companion_ids: vec![],
                    chat_id: "c1".into(),
                    message_id: "a1".into(),
                    model: "m".into(),
                }),
                cx,
            );
            s.on_event(
                &Event::TurnDelta(TurnDelta {
                    chat_id: "c1".into(),
                    message_id: "a1".into(),
                    text: "Partial".into(),
                    reasoning: None,
                }),
                cx,
            );
            s.on_event(&blocks("c1", "a1", vec![text_block("Partial")]), cx);
            s.on_event(
                &Event::TurnFailed(TurnFailed {
                    chat_id: "c1".into(),
                    message_id: "a1".into(),
                    code: "server.error".into(),
                    args: BTreeMap::from([("detail".into(), "Model is overloaded".into())]),
                    partial_text: "Partial".into(),
                }),
                cx,
            );
        });
        cx.run_until_parked();
        store.read_with(cx, |s, _| {
            // The stored copy has no answer: the overlay stays.
            assert_eq!(s.rows(), &[Row::Stored(0), Row::Live]);
            let item = s.item(Row::Live).unwrap();
            assert!(!item.streaming);
            let kinds: Vec<_> = item.blocks.iter().map(|b| b.kind).collect();
            assert_eq!(kinds, vec![MessageBlockKind::Text, MessageBlockKind::Error]);
            assert_eq!(item.blocks[1].error.as_deref(), Some("Model is overloaded"));
            assert_eq!(s.last_reply().as_deref(), Some("Partial"));
        });
    }

    #[gpui_kit::test]
    fn finished_falls_back_when_completed_was_missed(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        daemon.returns::<methods::ChatsGet>(chat("c1", vec![message("u1", "user", "hi")]));
        let (store, _) = open(&daemon, "c1", cx);
        store.update(cx, |s, cx| {
            s.on_event(&blocks("c1", "a1", vec![text_block("Done")]), cx);
            s.on_event(
                &Event::TurnFinished(TurnFinished {
                    chat_id: "c1".into(),
                    message_id: "a1".into(),
                    ok: true,
                    code: None,
                    queued: false,
                }),
                cx,
            );
        });
        cx.run_until_parked();
        store.read_with(cx, |s, _| {
            assert_eq!(s.live.as_ref().unwrap().phase, LivePhase::Completed);
        });
    }

    #[gpui_kit::test]
    fn a_remap_moves_the_store_resubscribes_and_refetches(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        daemon.returns::<methods::ChatsGet>(chat("x", vec![message("u1", "user", "hi")]));
        let (store, seen) = open(&daemon, "local:1", cx);
        store.update(cx, |s, cx| {
            s.remap("other", "y", cx);
            s.remap("local:1", "c42", cx);
        });
        cx.run_until_parked();
        assert_eq!(
            *seen.borrow(),
            vec![Some("local:1".to_string()), Some("c42".to_string())]
        );
        assert_eq!(
            daemon.calls::<methods::ChatsGet>(),
            vec![json!({"id": "local:1"}), json!({"id": "c42"})]
        );
        store.update(cx, |s, cx| {
            // Events now come under the new id.
            s.on_event(&blocks("c42", "a1", vec![text_block("ok")]), cx);
        });
        store.read_with(cx, |s, _| {
            assert_eq!(s.chat_id(), "c42");
            assert!(s.live.is_some());
        });
    }

    #[gpui_kit::test]
    fn a_reconnect_resubscribes_so_the_daemon_replays_the_turn(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        let mut streaming = message("a1", "assistant", "Hal");
        streaming.streaming = true;
        daemon
            .returns::<methods::ChatsGet>(chat("c1", vec![message("u1", "user", "hi"), streaming]));
        let (store, seen) = open(&daemon, "c1", cx);
        // Opened mid-answer: the stored copy says it is streaming.
        assert!(store.read_with(cx, |s, _| s.is_streaming()));
        store.update(cx, |s, cx| s.on_reconnected(cx));
        cx.run_until_parked();
        assert_eq!(seen.borrow().len(), 2);
        assert_eq!(daemon.calls::<methods::ChatsGet>().len(), 2);
        // The replayed snapshot (`turn.delta` + `turn.blocks`) takes the
        // stored row's place.
        store.update(cx, |s, cx| {
            s.on_event(&blocks("c1", "a1", vec![text_block("Hallo, Welt")]), cx);
        });
        store.read_with(cx, |s, _| {
            assert_eq!(s.rows(), &[Row::Stored(0), Row::Live]);
            assert_eq!(
                s.item(Row::Live).unwrap().blocks,
                vec![text_block("Hallo, Welt")]
            );
        });
    }

    #[gpui_kit::test]
    fn send_shows_the_message_at_once_and_drops_it_on_refusal(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        daemon.returns::<methods::ChatsGet>(chat("c1", vec![]));
        daemon.once::<methods::TurnsSend>(Err(conduit_daemon::protocol::error(
            "server.error",
            "nope",
        )));
        let (store, _) = open(&daemon, "c1", cx);
        let events: Rc<RefCell<Vec<ChatStoreEvent>>> = Rc::default();
        cx.update(|cx| {
            let events = events.clone();
            cx.subscribe(&store, move |_, e: &ChatStoreEvent, _| {
                events.borrow_mut().push(e.clone())
            })
            .detach();
        });
        let task = store.update(cx, |s, cx| {
            let turn = TurnOptions::default().into_turn("hi".into(), None, false);
            let task = s.send(turn, PendingMessage::new("hi"), cx);
            // The question and, under it, the answer's waiting line; Stop
            // shows from the same frame.
            assert_eq!(s.rows(), &[Row::Pending, Row::Waiting]);
            assert!(s.is_streaming());
            let waiting = s.item(Row::Waiting).unwrap();
            assert!(waiting.streaming && waiting.last_answer && waiting.blocks.is_empty());
            task
        });
        cx.run_until_parked();
        assert!(matches!(task.now_or_never(), Some(Err(_))));
        assert_eq!(
            daemon.calls::<methods::TurnsSend>()[0]["chatId"],
            json!("c1")
        );
        store.read_with(cx, |s, _| {
            assert!(s.rows().is_empty());
            assert!(!s.is_streaming());
        });
        assert!(matches!(
            events.borrow()[0],
            ChatStoreEvent::Failed {
                action: ChatAction::Send,
                ..
            }
        ));

        daemon.returns::<methods::TurnsSend>(SendTurnAccepted {
            chat_id: "c1".into(),
            user_message_id: "u9".into(),
            assistant_message_id: "a9".into(),
        });
        store.update(cx, |s, cx| {
            let turn = TurnOptions::default().into_turn("again".into(), None, false);
            s.send(turn, PendingMessage::new("again"), cx).detach();
        });
        cx.run_until_parked();
        // The turn's own overlay takes the waiting row's place.
        assert_eq!(keys(&store, cx), vec!["pending", "a9"]);
        assert!(store.read_with(cx, |s, _| s.is_streaming()));
    }

    #[gpui_kit::test]
    fn a_stop_pressed_before_the_turn_starts_goes_out_once_it_has(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        daemon.returns::<methods::ChatsGet>(chat("c1", vec![]));
        daemon.returns::<methods::TurnsStop>(StoppedResult { stopped: true });
        daemon.returns::<methods::TurnsSend>(SendTurnAccepted {
            chat_id: "c1".into(),
            user_message_id: "u9".into(),
            assistant_message_id: "a9".into(),
        });
        let (store, _) = open(&daemon, "c1", cx);
        store.update(cx, |s, cx| {
            let turn = TurnOptions::default().into_turn("hi".into(), None, false);
            s.send(turn, PendingMessage::new("hi"), cx).detach();
            // Stop, while `turns.send` is still on its way: nothing to stop
            // yet on the daemon.
            s.stop(cx);
        });
        assert!(daemon.calls::<methods::TurnsStop>().is_empty());
        cx.run_until_parked();
        assert_eq!(
            daemon.calls::<methods::TurnsStop>(),
            vec![json!({"chatId": "c1"})]
        );
    }

    #[gpui_kit::test]
    fn a_stop_pressed_while_a_regenerate_starts_goes_out_once_it_has(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        daemon.returns::<methods::ChatsGet>(chat(
            "c1",
            vec![
                message("u1", "user", "q"),
                message("a1", "assistant", "old"),
            ],
        ));
        daemon.returns::<methods::TurnsStop>(StoppedResult { stopped: true });
        daemon.returns::<methods::TurnsRegenerate>(SendTurnAccepted {
            chat_id: "c1".into(),
            user_message_id: "u1".into(),
            assistant_message_id: "a2".into(),
        });
        let (store, _) = open(&daemon, "c1", cx);
        let held = daemon.hold::<methods::TurnsRegenerate>();
        store.update(cx, |s, cx| {
            s.regenerate("a1", None, cx);
            assert!(s.is_streaming());
            s.stop(cx);
        });
        cx.run_until_parked();
        assert!(
            daemon.calls::<methods::TurnsStop>().is_empty(),
            "nothing to stop before the daemon takes the regenerate"
        );
        held.release();
        cx.run_until_parked();
        assert_eq!(
            daemon.calls::<methods::TurnsStop>(),
            vec![json!({"chatId": "c1"})]
        );
    }

    #[gpui_kit::test]
    fn an_edit_hides_the_old_branch_until_the_new_one_is_stored(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        daemon.returns::<methods::ChatsGet>(chat(
            "c1",
            vec![
                message("u1", "user", "first"),
                message("a1", "assistant", "one"),
                message("u2", "user", "second"),
                message("a2", "assistant", "two"),
            ],
        ));
        daemon.returns::<methods::TurnsEdit>(SendTurnAccepted {
            chat_id: "c1".into(),
            user_message_id: "u3".into(),
            assistant_message_id: "a3".into(),
        });
        let (store, _) = open(&daemon, "c1", cx);
        store.update(cx, |s, cx| s.edit("u2", "second, better".into(), cx));
        assert_eq!(keys(&store, cx), vec!["u1", "a1", "pending", "waiting"]);
        cx.run_until_parked();
        assert_eq!(keys(&store, cx), vec!["u1", "a1", "pending", "a3"]);
        assert_eq!(
            daemon.calls::<methods::TurnsEdit>(),
            vec![json!({"chatId": "c1", "messageId": "u2", "text": "second, better"})]
        );
    }

    #[gpui_kit::test]
    fn a_regenerate_dims_the_old_answer_until_the_new_one_starts(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        daemon.returns::<methods::ChatsGet>(chat(
            "c1",
            vec![
                message("u1", "user", "q"),
                ChatMessageDto {
                    blocks: vec![text_block("old")],
                    ..message("a1", "assistant", "old")
                },
            ],
        ));
        daemon.returns::<methods::TurnsRegenerate>(SendTurnAccepted {
            chat_id: "c1".into(),
            user_message_id: "u1".into(),
            assistant_message_id: "a2".into(),
        });
        let (store, _) = open(&daemon, "c1", cx);
        store.update(cx, |s, cx| s.regenerate("a1", None, cx));
        cx.run_until_parked();
        // The old answer, marked stale, streaming; the pager it will have
        // (this answer and the one before) is known already.
        store.read_with(cx, |s, _| {
            let item = s.item(Row::Live).unwrap();
            assert!(item.stale && item.streaming);
            assert_eq!(item.blocks, vec![text_block("old")]);
            assert_eq!(item.version, Some((2, 2)));
        });
        // A first snapshot with nothing in it yet (an empty text) leaves the
        // old answer showing: its height is kept until there are words.
        store.update(cx, |s, cx| {
            s.on_event(&blocks("c1", "a2", vec![text_block("  ")]), cx);
        });
        store.read_with(cx, |s, _| {
            let item = s.item(Row::Live).unwrap();
            assert!(item.stale, "an empty snapshot is not the new answer yet");
            assert_eq!(item.blocks, vec![text_block("old")]);
        });
        // The first words of the new answer take its place.
        store.update(cx, |s, cx| {
            s.on_event(&blocks("c1", "a2", vec![text_block("new")]), cx);
        });
        store.read_with(cx, |s, _| {
            let item = s.item(Row::Live).unwrap();
            assert!(!item.stale);
            assert_eq!(item.blocks, vec![text_block("new")]);
            assert_eq!(item.version, Some((2, 2)), "the pager keeps its place");
        });
    }

    #[test]
    fn only_what_draws_in_the_body_counts_as_the_answer_started() {
        let text = |md: &str| MessageBlockDto {
            markdown: Some(md.into()),
            ..empty_block(MessageBlockKind::Text)
        };
        assert!(!shows_anything(&[]));
        assert!(!shows_anything(&[text(" \n")]));
        assert!(shows_anything(&[text("Here")]));
        // Drawn under the answer, or nothing yet to say.
        assert!(!shows_anything(&[
            empty_block(MessageBlockKind::Sources),
            empty_block(MessageBlockKind::FollowUps),
            empty_block(MessageBlockKind::Status),
            empty_block(MessageBlockKind::Files),
            text(""),
        ]));
        let status = MessageBlockDto {
            summary: Some("Searching the web".into()),
            ..empty_block(MessageBlockKind::Status)
        };
        assert!(shows_anything(&[status]));
        assert!(shows_anything(&[empty_block(MessageBlockKind::Reasoning)]));
    }

    #[gpui_kit::test]
    fn an_answer_row_carries_the_name_its_model_went_by(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        // A Hermes answer after a confirmed model switch: an agent id no
        // model on offer has, and the name the answer kept.
        let mut answer = message("a2", "assistant", "Basil and thyme.");
        answer.model = Some("hermes:agent:desktop:7f3a9c".into());
        answer.model_name = Some("Demo Model Large".into());
        let version = |id: &str, model: Option<&str>, name: Option<&str>| ChatMessageVersionDto {
            slot: None,
            merged: None,
            streaming: false,
            error_code: None,
            id: id.into(),
            content: "Rosemary.".into(),
            timestamp_ms: 1,
            model: model.map(Into::into),
            model_name: name.map(Into::into),
            sources: vec![],
            usage: None,
            blocks: vec![text_block("Rosemary.")],
        };
        answer.versions = vec![
            version("a0", Some("demo-model"), Some("Demo Model")),
            version("a1", None, None),
        ];
        daemon.returns::<methods::ChatsGet>(chat("c1", vec![message("u1", "user", "q"), answer]));
        let (store, _) = open(&daemon, "c1", cx);
        store.update(cx, |s, cx| {
            let named = |s: &ChatStore| {
                let item = s.item(Row::Stored(1)).unwrap();
                (item.model, item.model_name)
            };
            assert_eq!(
                named(s),
                (
                    Some("hermes:agent:desktop:7f3a9c".into()),
                    Some("Demo Model Large".into())
                )
            );
            // A version with a model of its own goes by its own name...
            s.show_version("a2", 0, cx);
            assert_eq!(
                named(s),
                (Some("demo-model".into()), Some("Demo Model".into()))
            );
            // ...and one without, by the message's.
            s.show_version("a2", 1, cx);
            assert_eq!(
                named(s),
                (
                    Some("hermes:agent:desktop:7f3a9c".into()),
                    Some("Demo Model Large".into())
                )
            );
            // A question has no model name to show.
            assert_eq!(s.item(Row::Stored(0)).unwrap().model_name, None);
        });
    }

    #[gpui_kit::test]
    fn sending_ends_the_last_answer_so_its_suggestions_go_at_once(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        daemon.returns::<methods::ChatsGet>(chat(
            "c1",
            vec![
                message("u1", "user", "q"),
                message("a1", "assistant", "answer"),
            ],
        ));
        let (store, _) = open(&daemon, "c1", cx);
        store.read_with(cx, |s, _| {
            assert!(s.item(Row::Stored(1)).unwrap().last_answer);
        });
        store.update(cx, |s, cx| {
            let turn = TurnOptions::default().into_turn("next".into(), None, false);
            s.send(turn, PendingMessage::new("next"), cx).detach();
        });
        store.read_with(cx, |s, _| {
            assert!(s.rows().contains(&Row::Pending));
            assert!(!s.item(Row::Stored(1)).unwrap().last_answer);
        });
    }

    #[gpui_kit::test]
    fn regenerate_takes_over_the_old_answer_until_it_settles(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        daemon.returns::<methods::ChatsGet>(chat(
            "c1",
            vec![
                message("u1", "user", "q"),
                message("a1", "assistant", "old"),
            ],
        ));
        daemon.returns::<methods::TurnsRegenerate>(SendTurnAccepted {
            chat_id: "c1".into(),
            user_message_id: "u1".into(),
            assistant_message_id: "a2".into(),
        });
        let (store, _) = open(&daemon, "c1", cx);
        store.update(cx, |s, cx| s.regenerate("a1", None, cx));
        store.read_with(cx, |s, _| {
            assert_eq!(s.rows(), &[Row::Stored(0), Row::Live]);
            assert!(s.is_streaming() && !s.can_branch());
        });
        cx.run_until_parked();
        store.update(cx, |s, cx| {
            s.on_event(&blocks("c1", "a2", vec![text_block("new")]), cx);
            // A second regenerate while streaming is refused.
            s.regenerate("a1", None, cx);
        });
        cx.run_until_parked();
        assert_eq!(daemon.calls::<methods::TurnsRegenerate>().len(), 1);
        // The new answer keeps the old one's row key: one row throughout.
        assert_eq!(keys(&store, cx), vec!["u1", "a1"]);

        // Stored: the new answer carries the old one as a version.
        let mut answer = message("a2", "assistant", "new");
        answer.versions = vec![ChatMessageVersionDto {
            slot: None,
            merged: None,
            streaming: false,
            error_code: None,
            id: "a1".into(),
            content: "old".into(),
            timestamp_ms: 1,
            model: Some("m".into()),
            model_name: None,
            sources: vec![],
            usage: None,
            blocks: vec![text_block("old")],
        }];
        daemon.returns::<methods::ChatsGet>(chat("c1", vec![message("u1", "user", "q"), answer]));
        store.update(cx, |s, cx| {
            s.on_event(
                &Event::TurnCompleted(TurnCompleted {
                    chat_id: "c1".into(),
                    message_id: "a2".into(),
                    text: "new".into(),
                    reasoning: None,
                    usage: None,
                }),
                cx,
            )
        });
        cx.run_until_parked();
        store.update(cx, |s, cx| {
            assert!(s.live.is_none());
            let item = s.item(s.rows()[1]).unwrap();
            assert_eq!(item.version, Some((2, 2)));
            assert_eq!(item.text, "new");
            let step = s.step_version("a2", -1, cx);
            assert_eq!(
                step,
                Some(VersionStep {
                    index: 1,
                    total: 2,
                    branch: false
                })
            );
            let item = s.item(s.rows()[1]).unwrap();
            assert_eq!(item.version, Some((1, 2)));
            assert_eq!(item.blocks, vec![text_block("old")]);
            // No thumb on an older version.
            assert_eq!(item.rating, None);
            assert_eq!(s.step_version("a2", -1, cx), None, "already the first");
            assert_eq!(s.item(s.rows()[1]).unwrap().version, Some((1, 2)));
        });
        assert_eq!(keys(&store, cx), vec!["u1", "a1"], "settled, the same row");
    }

    /// A regenerate whose first events come before `turns.regenerate`
    /// replies, then a copy saved mid-regenerate that lists the old answer
    /// on its own (ahead of the question): the transcript keeps one row for
    /// the answer, in its place, from the first event to the stored copy.
    #[gpui_kit::test]
    fn a_regenerate_stays_one_row_in_place_whatever_order_things_arrive(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        let old = ChatMessageDto {
            blocks: vec![text_block("old")],
            ..message("a1", "assistant", "old")
        };
        daemon.returns::<methods::ChatsGet>(chat(
            "c1",
            vec![message("u1", "user", "q"), old.clone()],
        ));
        daemon.returns::<methods::TurnsRegenerate>(SendTurnAccepted {
            chat_id: "c1".into(),
            user_message_id: "u1".into(),
            assistant_message_id: "a2".into(),
        });
        let (store, _) = open(&daemon, "c1", cx);
        let seen = std::rc::Rc::new(RefCell::new(vec![]));
        let _watch = cx.update({
            let seen = seen.clone();
            |cx| {
                cx.observe(&store, move |s, cx| {
                    let s = s.read(cx);
                    let keys: Vec<String> = s.rows().iter().map(|r| s.row_key(*r)).collect();
                    seen.borrow_mut().push(keys);
                })
            }
        });
        store.update(cx, |s, cx| {
            s.regenerate("a1", None, cx);
            // The turn's first events, before the reply is read.
            s.on_event(
                &Event::TurnStarted(TurnStarted {
                    companion_ids: vec![],
                    chat_id: "c1".into(),
                    message_id: "a2".into(),
                    model: "m".into(),
                }),
                cx,
            );
            s.on_event(&blocks("c1", "a2", vec![text_block("new")]), cx);
        });
        cx.run_until_parked();
        store.read_with(cx, |s, _| {
            let live = s.live.as_ref().unwrap();
            assert_eq!(live.message_id, "a2");
            assert_eq!(live.replaces.as_deref(), Some("a1"));
            assert_eq!(s.item(Row::Live).unwrap().key, "a2", "actions use the id");
        });
        // Done; the copy saved mid-regenerate has the old answer on its own
        // ahead of the question, emptied, and the new one carrying it.
        let mut new = ChatMessageDto {
            blocks: vec![text_block("new")],
            ..message("a2", "assistant", "new")
        };
        new.versions = vec![ChatMessageVersionDto {
            slot: None,
            merged: None,
            streaming: false,
            error_code: None,
            id: "a1".into(),
            content: "old".into(),
            timestamp_ms: 1,
            model: Some("m".into()),
            model_name: None,
            sources: vec![],
            usage: None,
            blocks: vec![text_block("old")],
        }];
        daemon.returns::<methods::ChatsGet>(chat(
            "c1",
            vec![
                message("a1", "assistant", ""),
                message("u1", "user", "q"),
                new.clone(),
            ],
        ));
        store.update(cx, |s, cx| {
            s.on_event(
                &Event::TurnCompleted(TurnCompleted {
                    chat_id: "c1".into(),
                    message_id: "a2".into(),
                    text: "new".into(),
                    reasoning: None,
                    usage: None,
                }),
                cx,
            )
        });
        cx.run_until_parked();
        // Then the copy as it settles: the old answer gone from the list.
        daemon.returns::<methods::ChatsGet>(chat("c1", vec![message("u1", "user", "q"), new]));
        store.update(cx, |s, cx| s.fetch(cx));
        cx.run_until_parked();
        store.read_with(cx, |s, _| assert!(s.live.is_none()));
        let seen = seen.borrow();
        assert!(seen.len() > 3, "{seen:?}");
        for keys in seen.iter() {
            assert_eq!(keys, &vec!["u1".to_string(), "a1".to_string()], "{seen:?}");
        }
    }

    #[gpui_kit::test]
    fn a_rating_shows_at_once_and_rolls_back_when_refused(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        daemon.returns::<methods::ChatsGet>(chat(
            "c1",
            vec![message("u1", "user", "q"), message("a1", "assistant", "a")],
        ));
        daemon.once::<methods::TurnsRate>(Ok(RatedResult { rated: true }));
        daemon.once::<methods::TurnsRate>(Err(conduit_daemon::protocol::error(
            "transport.disconnected",
            "dropped",
        )));
        let (store, _) = open(&daemon, "c1", cx);
        let rating = |store: &Entity<ChatStore>, cx: &mut TestAppContext| {
            store.read_with(cx, |s, _| s.item(Row::Stored(1)).unwrap().rating)
        };
        store.update(cx, |s, cx| s.rate("a1", 1, cx));
        assert_eq!(rating(&store, cx), Some(1));
        cx.run_until_parked();
        assert_eq!(rating(&store, cx), Some(1));
        store.update(cx, |s, cx| s.rate("a1", -1, cx));
        assert_eq!(rating(&store, cx), Some(-1), "optimistic");
        cx.run_until_parked();
        assert_eq!(rating(&store, cx), Some(1), "rolled back to the last one");
        assert_eq!(
            daemon.calls::<methods::TurnsRate>()[1],
            json!({"chatId": "c1", "messageId": "a1", "rating": -1})
        );
    }

    #[gpui_kit::test]
    fn older_messages_load_a_page_at_a_time(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        let messages: Vec<_> = (0..250)
            .map(|i| {
                if i % 2 == 0 {
                    message(&format!("m{i}"), "user", "q")
                } else {
                    message(&format!("m{i}"), "assistant", "a")
                }
            })
            .collect();
        daemon.returns::<methods::ChatsGet>(chat("c1", messages));
        let (store, _) = open(&daemon, "c1", cx);
        store.read_with(cx, |s, _| {
            assert_eq!(s.rows().len(), PAGE);
            assert_eq!(s.hidden(), 150);
            assert_eq!(s.row_key(s.rows()[0]), "m150");
        });
        assert_eq!(store.update(cx, |s, cx| s.load_older(cx)), PAGE);
        assert_eq!(store.update(cx, |s, cx| s.load_older(cx)), 50);
        assert_eq!(store.update(cx, |s, cx| s.load_older(cx)), 0);
        store.read_with(cx, |s, _| assert_eq!(s.row_key(s.rows()[0]), "m0"));
    }

    #[gpui_kit::test]
    fn stop_names_the_chat_and_a_deleted_chat_says_so(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        daemon.returns::<methods::ChatsGet>(ChatResult { chat: None });
        daemon.returns::<methods::TurnsStop>(StoppedResult { stopped: true });
        let (store, _) = open(&daemon, "gone", cx);
        assert!(store.read_with(cx, |s, _| s.missing));
        store.update(cx, |s, cx| s.stop(cx));
        cx.run_until_parked();
        assert_eq!(
            daemon.calls::<methods::TurnsStop>(),
            vec![json!({"chatId": "gone"})]
        );
    }

    #[gpui_kit::test]
    fn an_answer_that_lists_its_earlier_text_under_its_own_id_still_shows(cx: &mut TestAppContext) {
        // A Hermes Retry keeps the answer's id; the failed text it replaced
        // is a version under that same id.
        let daemon = FakeDaemon::new();
        let mut answer = message("a1", "assistant", "This time it went through.");
        answer.versions = vec![ChatMessageVersionDto {
            slot: None,
            merged: None,
            streaming: false,
            error_code: Some("rateLimit".into()),
            id: "a1".into(),
            content: String::new(),
            timestamp_ms: 1,
            model: Some("m".into()),
            model_name: None,
            sources: vec![],
            usage: None,
            blocks: vec![],
        }];
        daemon.returns::<methods::ChatsGet>(chat(
            "local:hermes_s1",
            vec![message("u1", "user", "Book the ferry"), answer],
        ));
        let (store, _) = open(&daemon, "local:hermes_s1", cx);
        assert_eq!(keys(&store, cx), vec!["u1", "a1"]);
        store.read_with(cx, |s, _| {
            let item = s.item(s.rows()[1]).unwrap();
            assert_eq!(item.text, "This time it went through.");
        });
    }

    #[test]
    fn an_answer_counts_as_stored_once_it_has_content_or_is_a_version() {
        let mut streaming = message("a1", "assistant", "partial");
        streaming.streaming = true;
        assert!(!stored_has_answer(&[streaming], "a1", None));
        assert!(!stored_has_answer(
            &[message("a1", "assistant", "")],
            "a1",
            None
        ));
        assert!(stored_has_answer(
            &[message("a1", "assistant", "x")],
            "a1",
            None
        ));
        let mut failed = message("a1", "assistant", "");
        failed.error_code = Some("server.error".into());
        assert!(stored_has_answer(&[failed], "a1", None));
        let mut newer = message("a2", "assistant", "new");
        newer.versions = vec![ChatMessageVersionDto {
            slot: None,
            merged: None,
            streaming: false,
            error_code: None,
            id: "a1".into(),
            content: "old".into(),
            timestamp_ms: 1,
            model: None,
            model_name: None,
            sources: vec![],
            usage: None,
            blocks: vec![],
        }];
        assert!(stored_has_answer(&[newer], "a1", None));
        // A same-id regenerate: the old text is not the answer yet.
        let old = message("a1", "assistant", "old");
        assert!(!stored_has_answer(
            std::slice::from_ref(&old),
            "a1",
            Some("old")
        ));
        assert!(stored_has_answer(&[old], "a1", Some("older")));
        // Queued: still a placeholder, but the stored row shows the wait.
        let mut queued = message("a1", "assistant", "");
        queued.streaming = true;
        queued.queued = Some(QueuedCompletionDto {
            offline: true,
            ..Default::default()
        });
        assert!(stored_has_answer(&[queued], "a1", None));
    }

    /// The stored copy with `a9`, the answer to "again", queued: its
    /// request waits for the server.
    fn queued_answer() -> ChatResult {
        let mut answer = message("a9", "assistant", "");
        answer.queued = Some(QueuedCompletionDto {
            offline: true,
            ..Default::default()
        });
        chat(
            "c1",
            vec![
                message("u1", "user", "hi"),
                message("a1", "assistant", "hello"),
                message("u9", "user", "again"),
                answer,
            ],
        )
    }

    #[gpui_kit::test]
    fn a_send_the_daemon_queued_gives_way_to_the_queued_row(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        daemon.returns::<methods::ChatsGet>(chat(
            "c1",
            vec![
                message("u1", "user", "hi"),
                message("a1", "assistant", "hello"),
            ],
        ));
        // The server is away: the daemon queues the answer before its turn
        // starts, answers `turns.send` and sends no turn events for it.
        daemon.returns::<methods::TurnsSend>(SendTurnAccepted {
            chat_id: "c1".into(),
            user_message_id: "u9".into(),
            assistant_message_id: "a9".into(),
        });
        let (store, _) = open(&daemon, "c1", cx);
        store.update(cx, |s, cx| {
            let turn = TurnOptions::default().into_turn("again".into(), None, false);
            s.send(turn, PendingMessage::new("again"), cx).detach();
        });
        cx.run_until_parked();
        assert!(store.read_with(cx, |s, _| s.is_streaming()));

        // ... and tells the windows the chat changed, where it shows queued.
        daemon.returns::<methods::ChatsGet>(queued_answer());
        store.update(cx, |s, cx| {
            s.on_event(
                &Event::ChatsChanged(ChatsChanged {
                    chat_id: Some("c1".into()),
                }),
                cx,
            );
        });
        cx.run_until_parked();
        assert_eq!(keys(&store, cx), vec!["u1", "a1", "u9", "a9"]);
        store.read_with(cx, |s, _| {
            assert!(s.live.is_none());
            assert!(!s.is_streaming());
            let answer = s.item(*s.rows().last().unwrap()).unwrap();
            assert!(answer.stored);
            assert!(answer.queued.as_ref().is_some_and(|q| q.offline));
        });
    }

    #[gpui_kit::test]
    fn a_new_chat_the_daemon_queued_shows_its_answer_queued(cx: &mut TestAppContext) {
        // As the chat pane starts a new chat: the store is made and told
        // what was sent before its first copy arrives, which already shows
        // the answer queued.
        let daemon = FakeDaemon::new();
        daemon.returns::<methods::ChatsGet>(queued_answer());
        let accepted = SendTurnAccepted {
            chat_id: "c1".into(),
            user_message_id: "u9".into(),
            assistant_message_id: "a9".into(),
        };
        let rpc = daemon.rpc();
        let store = cx.new(|cx| ChatStore::new(rpc, Rc::new(|_, _| {}), "c1".into(), cx));
        store.update(cx, |s, cx| {
            s.started(PendingMessage::new("again"), &accepted, false, cx)
        });
        cx.run_until_parked();
        store.read_with(cx, |s, _| {
            assert!(s.live.is_none());
            assert!(!s.is_streaming());
            let answer = s.item(*s.rows().last().unwrap()).unwrap();
            assert!(answer.queued.is_some());
        });
    }

    #[gpui_kit::test]
    fn behind_a_queued_answer_a_new_message_is_queued(cx: &mut TestAppContext) {
        // The answer waits in the outbox and nothing streams here; the
        // daemon still offers the queue for it (its core writes that
        // answer, and a turn sent beside it would be refused as busy).
        let daemon = FakeDaemon::new();
        daemon.returns::<methods::ChatsGet>(queued_answer());
        let (store, _) = open(&daemon, "c1", cx);
        cx.run_until_parked();
        let offered = |offer: bool, cx: &mut TestAppContext| {
            store.update(cx, |s, cx| {
                let mut queue = empty_queue("c1".into());
                queue.offer = offer;
                s.on_event(&Event::QueueChanged(queue), cx);
            });
            cx.run_until_parked();
            store.read_with(cx, |s, _| s.queue_offered())
        };
        store.read_with(cx, |s, _| {
            assert!(s.answer_queued());
            assert!(!s.is_streaming());
        });
        assert!(offered(true, cx), "queued behind it, as on the phone");
        // Without the daemon's offer (its request failed for good, say),
        // Send sends.
        assert!(!offered(false, cx));
    }

    #[gpui_kit::test]
    fn an_answer_streaming_keeps_its_overlay_over_a_queued_copy(cx: &mut TestAppContext) {
        // A queued answer that went out streams as a turn of its own; a
        // copy fetched just before it went still shows it queued.
        let daemon = FakeDaemon::new();
        daemon.returns::<methods::ChatsGet>(queued_answer());
        let (store, _) = open(&daemon, "c1", cx);
        store.update(cx, |s, cx| {
            s.on_event(
                &Event::TurnStarted(TurnStarted {
                    chat_id: "c1".into(),
                    message_id: "a9".into(),
                    model: "m".into(),
                    companion_ids: vec![],
                }),
                cx,
            );
            s.fetch(cx);
        });
        cx.run_until_parked();
        store.read_with(cx, |s, _| {
            assert!(s.live.as_ref().is_some_and(LiveTurn::streaming));
            assert!(s.is_streaming());
        });

        daemon.returns::<methods::ChatsGet>(chat(
            "c1",
            vec![
                message("u1", "user", "hi"),
                message("a1", "assistant", "hello"),
                message("u9", "user", "again"),
                message("a9", "assistant", "tern"),
            ],
        ));
        store.update(cx, |s, cx| {
            s.on_event(
                &Event::TurnCompleted(TurnCompleted {
                    chat_id: "c1".into(),
                    message_id: "a9".into(),
                    text: "tern".into(),
                    reasoning: None,
                    usage: None,
                }),
                cx,
            );
        });
        cx.run_until_parked();
        store.read_with(cx, |s, _| {
            assert!(s.live.is_none());
            assert!(!s.is_streaming());
        });
    }
}
