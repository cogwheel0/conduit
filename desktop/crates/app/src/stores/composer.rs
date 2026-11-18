//! What the composer offers and holds, apart from its text.
//!
//! * **Models:** `models.list` (refetched on `models.changed`) and
//!   `models.select`, which the daemon keeps per account. `@` picks a model
//!   for the next message only ([`ComposerStore::mention`]).
//! * **Features:** `composer.options` says which switches the server and
//!   model allow (web search, image generation, the code interpreter, tools
//!   and filters); switches it does not offer are turned off. Quick pills
//!   ([`ComposerPrefs::quick_pills`]) put chosen ones one click away.
//! * **Triggers:** [`trigger_at`] finds the `/`, `@`, `#` or `$` word being
//!   typed at the caret. `/` lists saved prompts (`prompts.list`, then
//!   `prompts.render` with its fill-in fields); `@` models, and the server's
//!   users and channels (`mentions.search`); `#` notes, knowledge bases and
//!   their files (`context.search`); `$` Open WebUI skills
//!   (`skills.search`). Each search goes a moment after typing stops.
//! * **Attachments:** each file uploads through the daemon's `/upload` as
//!   soon as it is added, with its own progress; Send waits until all are
//!   done ([`ComposerStore::uploading`]). HEIC, RAW and BMP pictures are
//!   turned into JPEG first, as mobile does, and a failed upload is tried
//!   again by the core's rules (or, when the server may hold it already, by
//!   the user). Files already on the server come from `files.list`; a web
//!   page's text or a YouTube transcript from `context.fetchUrl`.
//! * **Drafts:** what is typed is kept per chat (`drafts.get` /
//!   `drafts.save`) a moment after typing stops, and at once when another
//!   chat opens.
//!
//! [`ComposerStore::take_turn`] collects the turn's options and clears what
//! applies to one message only (the `@` model, `#` context, attachments).

use std::collections::BTreeSet;
use std::future::Future;
use std::path::{Path, PathBuf};
use std::pin::Pin;
use std::sync::Arc;
use std::time::Duration;

use conduit_daemon::RpcError;
use conduit_protocol::{
    AppSettingsDto, ChatFileDto, ComposerMentionDto, ComposerOptions, ComposerSearch,
    ContextAttachmentDto, ContextSuggestion, Draft, DraftRef, DraftSave, FetchUrl, FetchedUrl,
    KnowledgeSummary, LibreChatComposer, LibreChatComposerTarget, MentionList, ModelList,
    ModelSummary, NoParams, PromptSummary, RenderPrompt, RenderedPrompt, SelectModel, ServerFile,
    ServerFileList, SkillSummary, UploadedFile, methods,
};
use gpui_kit::{
    AppContext as _, AsyncApp, Context, EventEmitter, Image, ImageFormat, Task, WeakEntity,
};

use super::chat::TurnOptions;
use super::rpc::Rpc;

/// The largest file the composer uploads (as Open with Conduit does).
pub const MAX_ATTACHMENT_BYTES: u64 = 256 * 1024 * 1024;

/// Bytes sent so far and the total, reported while a file uploads.
pub type Progress = Arc<dyn Fn(u64, u64) + Send + Sync>;

/// One file for `/upload`.
pub struct UploadRequest {
    pub name: String,
    pub content_type: Option<String>,
    pub bytes: Vec<u8>,
    pub progress: Progress,
    /// Which try this is (1 for the first), for the core's retry rules.
    pub attempt: u32,
    /// A channel's attachment: filed under the channel on the server, so
    /// its members may read it.
    pub channel_id: Option<String>,
}

/// What a failed upload says about trying again: the daemon answers with
/// the core's verdict (`classifyUploadFailure`) and its wait.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Retry {
    /// No connection was made: tried again after [`UploadError::wait`],
    /// without spending a try.
    Offline,
    /// The server answered and refused, or something else failed: tried
    /// again after the wait, a few times.
    Retryable,
    /// The server may hold the file already, or the tries are used up: only
    /// the user tries again (Try Again).
    Manual,
}

#[derive(Clone, Debug, PartialEq)]
pub struct UploadError {
    pub message: String,
    pub retry: Retry,
    pub wait: Duration,
}

impl UploadError {
    /// A failure with nothing to retry automatically.
    pub fn manual(message: impl Into<String>) -> Self {
        Self {
            message: message.into(),
            retry: Retry::Manual,
            wait: Duration::ZERO,
        }
    }

    /// The daemon's answer to a refused `/upload`: its error's `retry` and
    /// `retryAfterMs` args.
    pub fn from_rpc(e: &RpcError) -> Self {
        let retry = match e.args.get("retry").map(String::as_str) {
            Some("offline") => Retry::Offline,
            Some("retryable") => Retry::Retryable,
            _ => Retry::Manual,
        };
        let wait = e
            .args
            .get("retryAfterMs")
            .and_then(|ms| ms.parse::<u64>().ok())
            .map(Duration::from_millis)
            .unwrap_or(Duration::from_secs(5));
        Self {
            message: e.to_string(),
            retry,
            wait,
        }
    }
}

pub type UploadFuture = Pin<Box<dyn Future<Output = Result<UploadedFile, UploadError>> + Send>>;

/// Turns a picture into JPEG bytes (macOS ImageIO in the app, a fake in
/// tests): HEIC, RAW and BMP go up as JPEG, as from mobile.
pub type Converter = Arc<dyn Fn(&Path) -> Result<Vec<u8>, String> + Send + Sync>;

/// The Chats settings the composer follows: core's `AppSettings`, as
/// Settings › Chat changes them ([`ComposerPrefs::from_settings`]; the
/// chat pane and Quick Ask follow `stores.app_settings`).
#[derive(Clone, Debug, PartialEq)]
pub struct ComposerPrefs {
    /// `sendOnEnter`: Enter sends and Shift+Enter breaks the line; off, Enter
    /// breaks the line and ⌘↩ sends. ⌘↩ always sends.
    ///
    /// Mobile's default is off, for its software keyboard; on a Mac the
    /// keyboard is always a hardware one, so the daemon's host default turns
    /// it on until the user turns it off (core `AppSettingsHostDefaults`).
    pub send_on_enter: bool,
    /// `quickPills`: the ids chosen in Settings. The daemon says which of
    /// them this model can turn on ([`ComposerOptions::quick_pills`], by the
    /// core's rules); the composer draws those. None by default.
    pub quick_pills: Vec<String>,
    /// `showComposerNotesButton`: the + menu offers Save as Note.
    pub show_notes_button: bool,
    /// `temporaryChatByDefault`: a new chat starts temporary.
    pub temporary_by_default: bool,
    /// `showModelNameInComposer`: the empty message box names the selected
    /// model ("Ask Kestrel 8B"). Off by default, as on mobile.
    pub show_model_name: bool,
}

impl Default for ComposerPrefs {
    fn default() -> Self {
        Self {
            send_on_enter: true,
            quick_pills: vec![],
            show_notes_button: true,
            temporary_by_default: false,
            show_model_name: false,
        }
    }
}

impl ComposerPrefs {
    /// The composer's share of the daemon's app settings.
    pub fn from_settings(settings: &AppSettingsDto) -> Self {
        Self {
            send_on_enter: settings.send_on_enter,
            quick_pills: settings.quick_pills.clone(),
            show_notes_button: settings.show_composer_notes_button,
            temporary_by_default: settings.temporary_chat_by_default,
            show_model_name: settings.show_model_name_in_composer,
        }
    }
}

/// Which draft the composer holds: a stored chat's, or a new chat's (in a
/// folder, or none).
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct DraftKey {
    pub chat_id: Option<String>,
    pub folder_id: Option<String>,
}

/// Uploads a file through the daemon (the app passes the HTTP client's
/// `/upload`; tests a fake).
pub type Uploader = Arc<dyn Fn(UploadRequest) -> UploadFuture + Send + Sync>;

#[derive(Clone, Debug, PartialEq)]
pub enum UploadState {
    Reading,
    /// Being turned into a JPEG first.
    Converting,
    Uploading {
        sent: u64,
        total: u64,
    },
    /// Failed, and tried again after a wait.
    Waiting,
    Done {
        file_id: String,
    },
    /// Failed. `retry`: the user may try again (Try Again).
    Failed {
        error: String,
        retry: bool,
    },
}

/// The draft a new chat's settings were set in, its round, and which
/// assignment they were in it ([`ComposerStore::params_owner`]): every save
/// is its own owner, even two in one round. `folder`: the new chat's folder
/// (a temporary one keeps no draft key), so another folder's new chat
/// never takes them.
#[derive(Clone, Debug, PartialEq)]
pub struct ParamsOwner {
    draft: Option<DraftKey>,
    folder: Option<String>,
    round: u64,
    rev: u64,
}

/// What one message uses up ([`ComposerStore::one_shot`]).
#[derive(Clone, Debug, Default)]
pub struct OneShot {
    /// The account scope and the draft it was taken from: it is given back
    /// only to the same ones ([`ComposerStore::give_back`]).
    scope: u64,
    draft: u64,
    pub attachments: Vec<Attachment>,
    pub knowledge: Vec<KnowledgeSummary>,
    pub context: Vec<ContextAttachmentDto>,
    pub mention: Option<ModelSummary>,
    /// The message's `@`/`$` mentions, so its text comes back with them
    /// ([`OneShot::with_mentions`]).
    pub mentions: Vec<ComposerMentionDto>,
    /// Compare Models' second model.
    pub compare_with: Option<ModelSummary>,
    /// The draft's recordings the message took with it (a dictation hold):
    /// kept if it is refused.
    pub recordings: Option<u64>,
}

impl OneShot {
    /// The same, with the recordings the message took.
    pub fn with_recordings(mut self, recordings: Option<u64>) -> Self {
        self.recordings = recordings;
        self
    }

    /// The same, with the mentions the message carried.
    pub fn with_mentions(mut self, mentions: Vec<ComposerMentionDto>) -> Self {
        self.mentions = mentions;
        self
    }

    /// Two unsent messages for one draft kept as one, so neither one's words
    /// are lost: `first`'s words, a blank line, then `later`'s, with both
    /// messages' mentions and files (`later`'s knowledge, context and models
    /// unless it chose none). `first` from another account or draft scope is
    /// dropped, as [`ComposerStore::give_back`] would drop it.
    pub fn merge(
        first_text: &str,
        first: OneShot,
        later_text: &str,
        later: OneShot,
    ) -> (String, OneShot) {
        if first.scope != later.scope {
            return (later_text.to_string(), later);
        }
        let (text, mentions) = if later_text.trim().is_empty() {
            (first_text.to_string(), first.mentions)
        } else if first_text.trim().is_empty() {
            (later_text.to_string(), later.mentions)
        } else {
            let head = format!("{first_text}\n\n");
            let shift = head.encode_utf16().count() as i64;
            let mut mentions = first.mentions;
            mentions.extend(later.mentions.into_iter().map(|mut m| {
                m.start += shift;
                m.end += shift;
                m
            }));
            (format!("{head}{later_text}"), mentions)
        };
        let mut attachments = first.attachments;
        attachments.retain(|a| !later.attachments.iter().any(|b| b.local_id == a.local_id));
        attachments.extend(later.attachments);
        let merged = OneShot {
            scope: later.scope,
            draft: later.draft,
            attachments,
            knowledge: if later.knowledge.is_empty() {
                first.knowledge
            } else {
                later.knowledge
            },
            context: if later.context.is_empty() {
                first.context
            } else {
                later.context
            },
            mention: later.mention.or(first.mention),
            mentions,
            compare_with: later.compare_with.or(first.compare_with),
            recordings: later.recordings.or(first.recordings),
        };
        (text, merged)
    }
}

#[derive(Clone)]
pub struct Attachment {
    /// This window's id for it (the server's comes with `Done`).
    pub local_id: u64,
    pub name: String,
    pub size: u64,
    pub content_type: Option<String>,
    /// A thumbnail, for images.
    pub image: Option<Arc<Image>>,
    pub state: UploadState,
    /// What is uploaded, kept until it is done, to try again.
    bytes: Option<Arc<Vec<u8>>>,
    /// The try now running or next (1 for the first).
    attempt: u32,
    /// Already on the server (picked from its files): never uploaded.
    pub server_file: bool,
}

impl std::fmt::Debug for Attachment {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Attachment")
            .field("local_id", &self.local_id)
            .field("name", &self.name)
            .field("state", &self.state)
            .finish()
    }
}

impl Attachment {
    /// An attachment already uploaded as `file_id` (view tests).
    #[cfg(test)]
    pub fn uploaded_for_test(local_id: u64, name: &str, file_id: &str) -> Self {
        Self {
            local_id,
            name: name.into(),
            size: 3,
            content_type: None,
            image: None,
            state: UploadState::Done {
                file_id: file_id.into(),
            },
            bytes: None,
            attempt: 1,
            server_file: false,
        }
    }

    /// Still being read, converted or uploaded, or waiting to be tried again.
    fn in_flight(&self) -> bool {
        matches!(
            self.state,
            UploadState::Reading
                | UploadState::Converting
                | UploadState::Uploading { .. }
                | UploadState::Waiting
        )
    }

    /// 0–1 while uploading.
    pub fn progress(&self) -> Option<f32> {
        match self.state {
            UploadState::Reading => Some(0.),
            UploadState::Uploading { sent, total } if total > 0 => {
                Some((sent as f32 / total as f32).min(1.))
            }
            UploadState::Uploading { .. } | UploadState::Converting | UploadState::Waiting => {
                Some(0.)
            }
            _ => None,
        }
    }

    pub fn failed(&self) -> bool {
        matches!(self.state, UploadState::Failed { .. })
    }

    /// The user may try this one again.
    pub fn can_retry(&self) -> bool {
        matches!(self.state, UploadState::Failed { retry: true, .. })
    }
}

#[derive(Clone, Debug, PartialEq)]
pub enum ComposerEvent {
    /// A file could not be added or uploaded.
    AttachmentFailed { name: String },
    /// `models.setControl` was refused: the pick was put back.
    ControlNotSaved(String),
    /// `models.select` was refused.
    ModelNotSelected(String),
    /// Another chat's draft is now the composer's: what it showed goes.
    DraftSwitched,
    /// The draft for [`DraftKey`] was read: the composer shows it.
    DraftLoaded { key: DraftKey, text: String },
}

/// One of LibreChat's composer switches.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum LibreChatTool {
    WebSearch,
    CodeInterpreter,
    FileSearch,
    /// One of the user's MCP servers; one that `needs_connection` is
    /// connected in LibreChat's web app first.
    Mcp {
        name: String,
        needs_connection: bool,
    },
}

pub struct ComposerStore {
    rpc: Rpc,
    uploader: Option<Uploader>,
    converter: Option<Converter>,
    pub prefs: ComposerPrefs,
    pub models: Option<ModelList>,
    /// Keeps no draft, yet sends ordinary saved chats (Quick Ask): not a
    /// temporary chat, so its list offers coding agents.
    pub saves_without_draft: bool,
    /// Per chat (its draft key), the coding agent picked there, for this
    /// account ([`Self::reset`] forgets them): shown and sent for that chat
    /// whatever a later list offers, and never for another chat. A chat
    /// with no pick of its own has no agent.
    agent_picks: std::collections::HashMap<DraftKey, ModelSummary>,
    pub options: ComposerOptions,
    /// LibreChat's tools for the model, when it is a LibreChat one
    /// (`librechat.composer`): chosen in `tool_ids`, as Open WebUI's are.
    pub librechat: LibreChatComposer,
    pub prompts: Option<Vec<PromptSummary>>,
    /// `prompts` are a Hermes chat's `/` commands (the agent's skills, as
    /// on a phone), inserted as typed rather than rendered.
    pub prompts_hermes: bool,
    /// The Hermes connection a Hermes chat's commands were read from (the
    /// daemon's name for it): another one reads its own.
    prompts_connection: Option<String>,
    /// `@`: the server's users and channels for the query typed.
    pub mention_results: MentionList,
    /// A channel's composer: `@` lists the channel's members (and models,
    /// as tokens), and attachments are filed under the channel.
    pub channel: Option<String>,
    /// `#`: notes, knowledge bases and files for the query typed.
    pub context_results: Vec<ContextSuggestion>,
    /// `$`: skills for the query typed.
    pub skill_results: Vec<SkillSummary>,
    /// The query each list answers, once it has answered.
    searched: [Option<String>; 3],
    pub attachments: Vec<Attachment>,
    /// Files still being read or uploaded when their draft was taken
    /// ([`Self::take_draft`]): their upload lands here, and they go back
    /// with the draft ([`Self::put_draft`]), as they are by then.
    parked: Vec<Attachment>,
    pub web_search: bool,
    pub image_generation: bool,
    pub code_interpreter: bool,
    pub tool_ids: BTreeSet<String>,
    /// The model's toggle filters that are on.
    pub filter_ids: BTreeSet<String>,
    /// The user turned a filter on or off: a new model's defaults no longer
    /// replace the choice.
    filters_touched: bool,
    /// `@`: the model for the next message only.
    pub mention: Option<ModelSummary>,
    /// Compare Models: the second model to answer the next message, beside
    /// the one it goes to.
    pub compare_with: Option<ModelSummary>,
    /// `#`: knowledge bases for the next message.
    pub knowledge: Vec<KnowledgeSummary>,
    /// `#` notes and knowledge files, and web pages: context for the next
    /// message.
    pub context: Vec<ContextAttachmentDto>,
    /// A new chat's own settings (Chat Settings on a new chat): its first
    /// message takes them. Dropped once another chat, or another folder's
    /// new chat, opens, as mobile drops its pending settings.
    pub draft_params: serde_json::Value,
    /// Whose [`Self::draft_params`] they are: the draft (and its round)
    /// they were set in. A send forgets only settings it still owns.
    params_owner: Option<ParamsOwner>,
    /// Bumped whenever the settings change: a reply asked before then
    /// never puts older ones back.
    params_rev: u64,
    /// The model a new chat in a folder starts on: the folder's default
    /// (`folders.draftModel`), until the user picks another.
    pub draft_model: Option<String>,
    _draft_model: Option<Task<()>>,
    /// The picker's extras for the selected model: reasoning effort (an
    /// Ollama model's thinking level) and Hermes' Fast tier.
    pub model_options: Option<conduit_protocol::ModelOptionsDto>,
    _model_options: Option<Task<()>>,
    /// The selected model's own controls (a coding agent's reasoning
    /// effort or service tier: `models.controls`), drawn as rows under the
    /// picker's list.
    pub model_controls: Option<conduit_protocol::ModelControlList>,
    _model_controls: Option<Task<()>>,
    /// The draft the composer holds, and what was last kept of it.
    draft: Option<DraftKey>,
    /// A new chat's folder, kept apart from [`Self::draft`]: a temporary
    /// new chat keeps no draft, and its first send still goes to the
    /// folder, with the folder's model, prompt and knowledge.
    new_chat_folder: Option<String>,
    draft_saved: String,
    next_id: u64,
    /// Bumped by [`Self::reset`]: answers to an older account are dropped.
    scope: u64,
    /// Bumped whenever the draft starts over ([`Self::start_over`], or
    /// another account): a failed send's message is not given back to it.
    draft_round: u64,
    _models: Option<Task<()>>,
    _options: Option<Task<()>>,
    _searches: [Option<Task<()>>; 3],
    _draft: Option<Task<()>>,
}

/// Which composition an async result belongs to: the account scope and
/// the draft round when it started ([`ComposerStore::ticket`]). A result
/// that lands after either moved on (another account, another draft or
/// chat, a fresh composition: [`ComposerStore::start_over`]) writes nothing
/// into, and navigates nothing away from, the composition shown then
/// ([`ComposerStore::holds`]).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct CompositionTicket {
    scope: u64,
    round: u64,
}

/// Which list a search fills.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Search {
    Mentions = 0,
    Context = 1,
    Skills = 2,
}

impl EventEmitter<ComposerEvent> for ComposerStore {}

impl ComposerStore {
    pub fn new(rpc: Rpc, uploader: Option<Uploader>) -> Self {
        Self {
            rpc,
            uploader,
            converter: default_converter(),
            prefs: ComposerPrefs::default(),
            models: None,
            saves_without_draft: false,
            agent_picks: std::collections::HashMap::new(),
            options: ComposerOptions::default(),
            librechat: LibreChatComposer::default(),
            prompts: None,
            prompts_hermes: false,
            prompts_connection: None,
            mention_results: MentionList::default(),
            channel: None,
            context_results: vec![],
            skill_results: vec![],
            searched: [None, None, None],
            attachments: vec![],
            parked: vec![],
            web_search: false,
            image_generation: false,
            code_interpreter: false,
            tool_ids: BTreeSet::new(),
            filter_ids: BTreeSet::new(),
            filters_touched: false,
            mention: None,
            compare_with: None,
            knowledge: vec![],
            context: vec![],
            draft_params: serde_json::Value::Null,
            params_owner: None,
            params_rev: 0,
            draft_model: None,
            _draft_model: None,
            model_options: None,
            _model_options: None,
            model_controls: None,
            _model_controls: None,
            draft: None,
            new_chat_folder: None,
            draft_saved: String::new(),
            next_id: 0,
            scope: 0,
            draft_round: 0,
            _models: None,
            _options: None,
            _searches: [None, None, None],
            _draft: None,
        }
    }

    /// A channel's composer: `@` offers the channel's members and the
    /// models (as mentions), + attaches files and pictures, and nothing
    /// else a chat's composer offers applies.
    pub fn for_channel(mut self, channel_id: impl Into<String>) -> Self {
        self.channel = Some(channel_id.into());
        self.options = serde_json::from_value(serde_json::json!({
            "mentions": true,
            "attachments": {"files": true, "images": true},
        }))
        .unwrap_or_default();
        self
    }

    /// The daemon, for a panel that asks it directly (MCP Content).
    pub fn rpc(&self) -> Rpc {
        self.rpc.clone()
    }

    /// Replaces how pictures are turned into JPEG (tests).
    pub fn with_converter(mut self, converter: Option<Converter>) -> Self {
        self.converter = converter;
        self
    }

    pub fn set_prefs(&mut self, prefs: ComposerPrefs, cx: &mut Context<Self>) {
        if self.prefs == prefs {
            return;
        }
        // The daemon resolves the chosen pills against the model
        // (`composer.options`), so new choices are asked for again.
        let pills_moved = self.prefs.quick_pills != prefs.quick_pills;
        self.prefs = prefs;
        if pills_moved && self.models.is_some() {
            self.refresh_options(cx);
        }
        cx.notify();
    }

    // ── Models and options ──────────────────────────────────────────────

    /// The model new turns use: the account's selection, else the first
    /// model offered, which is what the daemon runs a turn with when none
    /// is selected (right after sign-in nothing is, until the first send).
    /// The composer shows that model rather than "Choose a model".
    pub fn selected_model(&self) -> Option<&ModelSummary> {
        let list = self.models.as_ref()?;
        // This chat's own coding agent, whatever the list offers now.
        if let Some(pick) = self.chat_pick() {
            return Some(pick);
        }
        // A new chat in a folder starts on the folder's model.
        if let Some(model) = self
            .draft_model
            .as_deref()
            .and_then(|id| find_model(list, id))
        {
            return Some(model);
        }
        list.selected_id
            .as_deref()
            // An agent the account selected is another chat's pick: a chat
            // with no pick of its own has none.
            .filter(|id| !is_agent_id(id))
            .and_then(|id| find_model(list, id))
            .or_else(|| list.models.first())
    }

    /// Where this composer keeps an agent pick: its draft's key (Quick Ask,
    /// which keeps no draft, has one key of its own); none in a temporary
    /// chat, where no agent can answer.
    fn pick_key(&self) -> Option<DraftKey> {
        self.draft.clone().or_else(|| {
            self.saves_without_draft.then_some(DraftKey {
                chat_id: None,
                folder_id: None,
            })
        })
    }

    /// The coding agent picked in this chat, if one was.
    fn chat_pick(&self) -> Option<&ModelSummary> {
        self.agent_picks.get(&self.pick_key()?)
    }

    /// The list has loaded but names no model this chat could send to
    /// (no regular model, and no agent of its own): the composer does not
    /// send, as a turn naming none would go to the account's selection.
    pub fn names_no_model(&self) -> bool {
        self.models.is_some() && self.mention.is_none() && self.selected_model().is_none()
    }

    /// The model the next message goes to: the `@` one, else the selected.
    pub fn next_model(&self) -> Option<&ModelSummary> {
        self.mention.as_ref().or_else(|| self.selected_model())
    }

    /// `models.list`, then `composer.options` (which depends on it).
    /// It replaces a list still on its way.
    pub fn refresh_models(&mut self, cx: &mut Context<Self>) {
        let call = self.rpc.call::<methods::ModelsList>(&self.list_query());
        let scope = self.scope;
        self._models = Some(
            cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
                let result = call.await;
                let _ = this.update(cx, |s, cx| match result {
                    _ if s.scope != scope => {}
                    Ok(list) => {
                        s.set_models(list, cx);
                        s.refresh_options(cx);
                    }
                    Err(e) => log::info!("models.list: {e}"),
                });
            }),
        );
    }

    /// The open chat (None for a new or temporary chat): a reasoning pick
    /// is saved on it.
    fn chat_id(&self) -> Option<String> {
        self.draft.as_ref().and_then(|k| k.chat_id.clone())
    }

    /// What `models.list` lists for: the open chat, or a new one (a chat
    /// that keeps no draft is a temporary one, where no coding agent
    /// answers).
    fn list_query(&self) -> conduit_protocol::ModelListQuery {
        conduit_protocol::ModelListQuery {
            chat_id: self.chat_id(),
            temporary: self.draft.is_none() && !self.saves_without_draft,
        }
    }

    /// Switch: the chat's saved agent [`Self::chat_agent`] for the next
    /// turns. A one-message model (`@`) goes, as choosing a model in the
    /// picker drops it, so the next message goes to the agent.
    pub fn switch_to_chat_agent(&mut self, id: &str, cx: &mut Context<Self>) {
        self.set_mention(None, cx);
        self.select_model(id, cx);
    }

    /// The coding agent the open chat was saved with, by id and as the
    /// picker names it, while another model is selected: the composer
    /// offers Switch to it. The daemon never selects it on its own.
    pub fn chat_agent(&self) -> Option<(String, String)> {
        let list = self.models.as_ref()?;
        let id = list.chat_agent.clone()?;
        if self.chat_pick().is_some_and(|pick| pick.id == id) {
            return None;
        }
        let name = list
            .agent_names
            .get(&id)
            .cloned()
            .or_else(|| find_model(list, &id).map(|m| m.name.clone()))
            .unwrap_or_else(|| id.clone());
        Some((id, name))
    }

    /// `models.controls` for the selected model: none for a model without.
    pub fn refresh_model_controls(&mut self, cx: &mut Context<Self>) {
        let Some(model_id) = self.selected_model().map(|m| m.id.clone()) else {
            self.model_controls = None;
            return;
        };
        let call =
            self.rpc
                .call::<methods::ModelsControls>(&conduit_protocol::ModelControlsQuery {
                    model_id: Some(model_id.clone()),
                    chat_id: self.chat_id(),
                });
        self._model_controls = Some(cx.spawn(
            async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
                let result = call.await;
                let _ = this.update(cx, |s, cx| match result {
                    Ok(list) if list.model_id.as_deref() == Some(model_id.as_str()) => {
                        s.model_controls = Some(list);
                        cx.notify();
                    }
                    Ok(_) => {}
                    Err(e) => log::info!("models.controls: {e}"),
                });
            },
        ));
    }

    /// Picks `value` for the selected model's control `key`, as its own
    /// settings on the server keep it; shown at once, and put back if the
    /// server refuses it.
    pub fn set_model_control(&mut self, key: &str, value: &str, cx: &mut Context<Self>) {
        let Some(model_id) = self.selected_model().map(|m| m.id.clone()) else {
            return;
        };
        let before = self.model_controls.clone();
        if let Some(list) = &mut self.model_controls
            && let Some(control) = list.controls.iter_mut().find(|c| c.key == key)
        {
            control.value = Some(value.to_string());
        }
        cx.notify();
        let call = self
            .rpc
            .call::<methods::ModelsSetControl>(&conduit_protocol::SetModelControl {
                model_id: Some(model_id),
                chat_id: self.chat_id(),
                key: key.to_string(),
                value: Some(value.to_string()),
            });
        self._model_controls = Some(cx.spawn(
            async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
                let result = call.await;
                let _ = this.update(cx, |s, cx| {
                    match result {
                        Ok(list) => s.model_controls = Some(list),
                        Err(e) => {
                            log::warn!("models.setControl: {e}");
                            s.model_controls = before;
                            cx.emit(ComposerEvent::ControlNotSaved(e.to_string()));
                        }
                    }
                    cx.notify();
                });
            },
        ));
    }

    /// `models.options` for the selected model.
    pub fn refresh_model_options(&mut self, cx: &mut Context<Self>) {
        let Some(model_id) = self.selected_model().map(|m| m.id.clone()) else {
            self.model_options = None;
            return;
        };
        let call = self
            .rpc
            .call::<methods::ModelsOptions>(&conduit_protocol::ModelOptionsQuery {
                model_id: Some(model_id.clone()),
                chat_id: self.chat_id(),
            });
        self._model_options = Some(cx.spawn(
            async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
                let result = call.await;
                let _ = this.update(cx, |s, cx| match result {
                    Ok(options) if options.model_id.as_deref() == Some(model_id.as_str()) => {
                        s.model_options = Some(options);
                        cx.notify();
                    }
                    Ok(_) => {}
                    Err(e) => log::info!("models.options: {e}"),
                });
            },
        ));
    }

    /// The picker's reasoning effort: `automatic`, a preset or a typed one.
    /// For a new chat it lands in its settings (as mobile's pending ones).
    pub fn set_reasoning_effort(&mut self, effort: &str, cx: &mut Context<Self>) {
        let Some(model_id) = self.selected_model().map(|m| m.id.clone()) else {
            return;
        };
        let chat_id = self.chat_id();
        let new_chat = chat_id.is_none();
        let (scope, round, asked) = (self.scope, self.draft_round, model_id.clone());
        let rev = self.params_rev;
        let call = self.rpc.call::<methods::ModelsSetReasoningEffort>(
            &conduit_protocol::SetReasoningEffort {
                model_id,
                chat_id,
                draft: if self.draft_params.is_null() {
                    serde_json::json!({})
                } else {
                    self.draft_params.clone()
                },
                effort: effort.to_string(),
            },
        );
        self._model_options = Some(cx.spawn(
            async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
                let result = call.await;
                let _ = this.update(cx, |s, cx| {
                    // Another draft, account or model since: not its answer.
                    if !s.still_asking(scope, round, &asked) {
                        return;
                    }
                    match result {
                        Ok(options) => {
                            // Settings saved since it was asked stay.
                            if new_chat
                                && s.params_rev == rev
                                && let Some(draft) = options.draft.clone()
                            {
                                s.set_params(draft);
                            }
                            s.model_options = Some(options);
                            cx.notify();
                        }
                        Err(e) => {
                            log::warn!("models.setReasoningEffort: {e}");
                            cx.emit(ComposerEvent::ModelNotSelected(e.to_string()));
                        }
                    }
                });
            },
        ));
    }

    /// Hermes' Fast tier, on or off.
    pub fn set_fast_tier(&mut self, on: bool, cx: &mut Context<Self>) {
        let model_id = self.selected_model().map(|m| m.id.clone());
        let (scope, round) = (self.scope, self.draft_round);
        let asked = model_id.clone().unwrap_or_default();
        let call = self
            .rpc
            .call::<methods::ModelsSetFastTier>(&conduit_protocol::SetFastTier { model_id, on });
        self._model_options = Some(cx.spawn(
            async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
                let result = call.await;
                let _ = this.update(cx, |s, cx| {
                    if !s.still_asking(scope, round, &asked) {
                        return;
                    }
                    match result {
                        Ok(options) => {
                            s.model_options = Some(options);
                            cx.notify();
                        }
                        Err(e) => {
                            log::warn!("models.setFastTier: {e}");
                            cx.emit(ComposerEvent::ModelNotSelected(e.to_string()));
                        }
                    }
                });
            },
        ));
    }

    /// Whether an answer asked in `scope` and draft `round` for `model_id`
    /// is still this composer's: same account, same draft, same model.
    fn still_asking(&self, scope: u64, round: u64, model_id: &str) -> bool {
        self.scope == scope
            && self.draft_round == round
            && self.selected_model().is_some_and(|m| m.id == model_id)
    }

    /// Pins or unpins a model in the account's settings.
    pub fn set_pinned(&mut self, id: &str, pinned: bool, cx: &mut Context<Self>) {
        // Shown at once; the daemon's answer replaces it.
        if let Some(list) = &mut self.models
            && let Some(m) = list.models.iter_mut().find(|m| m.id == id)
        {
            m.pinned = pinned;
        }
        cx.notify();
        let call = self
            .rpc
            .call::<methods::ModelsSetPinned>(&conduit_protocol::SetModelPinned {
                id: id.to_string(),
                pinned,
            });
        self._models = Some(
            cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
                let result = call.await;
                let _ = this.update(cx, |s, cx| match result {
                    Ok(list) => s.set_models(list, cx),
                    Err(e) => {
                        log::warn!("models.setPinned: {e}");
                        s.refresh_models(cx);
                    }
                });
            }),
        );
    }

    fn set_models(&mut self, mut list: ModelList, cx: &mut Context<Self>) {
        // A temporary chat offers no coding agent (none can answer there),
        // whichever answer the list came with (a pick's answer is for a
        // chat that is not temporary): a selected agent is then hidden, and
        // the next turn names the model shown.
        if self.list_query().temporary {
            list.agents.clear();
        }
        // An `@` model that is no longer offered is dropped.
        if let Some(m) = &self.mention
            && find_model(&list, &m.id).is_none()
        {
            self.mention = None;
        }
        self.models = Some(list);
        self.follow_model_options(cx);
        cx.notify();
    }

    /// Asks for the picker's extras again when the selected model is not
    /// the one they are for.
    fn follow_model_options(&mut self, cx: &mut Context<Self>) {
        let selected = self.selected_model().map(|m| m.id.clone());
        let shown = self.model_options.as_ref().and_then(|o| o.model_id.clone());
        if selected != shown {
            self.refresh_model_options(cx);
        }
        let controls = self
            .model_controls
            .as_ref()
            .and_then(|c| c.model_id.clone());
        if selected != controls {
            self.refresh_model_controls(cx);
        }
    }

    /// `models.select`: the daemon keeps it with the account.
    pub fn select_model(&mut self, id: &str, cx: &mut Context<Self>) {
        // A pick wins over a folder's default, including one still being
        // looked up.
        self.draft_model = None;
        self._draft_model = None;
        // Shown at once; the daemon's answer replaces it.
        if let Some(list) = &mut self.models {
            list.selected_id = Some(id.to_string());
        }
        // A coding agent picked is this chat's own, and any other pick ends
        // it, once the daemon took the pick (a refused one changes nothing).
        let key = self.pick_key();
        let agent = is_agent_id(id).then(|| {
            self.models
                .as_ref()
                .and_then(|list| {
                    find_model(list, id)
                        .cloned()
                        .or_else(|| list.agent_names.get(id).map(|name| agent_summary(id, name)))
                })
                .unwrap_or_else(|| agent_summary(id, id))
        });
        let scope = self.scope;
        cx.notify();
        let call = self.rpc.call::<methods::ModelsSelect>(&SelectModel {
            id: id.to_string(),
            chat_id: self.chat_id(),
        });
        self._models = Some(
            cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
                let result = call.await;
                let _ = this.update(cx, |s, cx| match result {
                    Ok(list) => {
                        if s.scope == scope
                            && let Some(key) = key
                        {
                            match agent {
                                Some(agent) => {
                                    s.agent_picks.insert(key, agent);
                                }
                                None => {
                                    s.agent_picks.remove(&key);
                                }
                            }
                        }
                        s.set_models(list, cx);
                        s.refresh_options(cx);
                    }
                    Err(e) => {
                        cx.emit(ComposerEvent::ModelNotSelected(e.to_string()));
                        s.refresh_models(cx);
                    }
                });
            }),
        );
    }

    /// `composer.options` (and `librechat.composer` for the model);
    /// switches they no longer offer go off.
    pub fn refresh_options(&mut self, cx: &mut Context<Self>) {
        // A channel's options are its own (`for_channel`), not a model's.
        if self.channel.is_some() {
            return;
        }
        // The options are the shown model's: the next turn goes to it.
        let model_id = self.selected_model().map(|m| m.id.clone());
        let call =
            self.rpc
                .call::<methods::ComposerOptions>(&conduit_protocol::ComposerOptionsQuery {
                    chat_id: self.chat_id(),
                    model_id: model_id.clone(),
                });
        let scope = self.scope;
        let librechat = self
            .rpc
            .call::<methods::LibrechatComposer>(&LibreChatComposerTarget { model_id });
        self._options = Some(
            cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
                let (options, librechat) = futures::join!(call, librechat);
                if let Ok(options) = options {
                    let _ = this.update(cx, |s, cx| {
                        // Another account's answers never fill this one's.
                        if s.scope != scope {
                            return;
                        }
                        // A daemon without LibreChat answers as none.
                        s.librechat = librechat.unwrap_or_default();
                        s.set_options(options, cx)
                    });
                }
            }),
        );
    }

    /// LibreChat's switches for the model: `(tool id, which)`.
    pub fn librechat_tools(&self) -> Vec<(String, LibreChatTool)> {
        let lc = &self.librechat;
        let mut tools = Vec::new();
        if let Some(id) = &lc.web_search_tool_id {
            tools.push((id.clone(), LibreChatTool::WebSearch));
        }
        if let Some(id) = &lc.code_interpreter_tool_id {
            tools.push((id.clone(), LibreChatTool::CodeInterpreter));
        }
        if let Some(id) = &lc.file_search_tool_id {
            tools.push((id.clone(), LibreChatTool::FileSearch));
        }
        for server in &lc.mcp_servers {
            tools.push((
                server.tool_id.clone(),
                LibreChatTool::Mcp {
                    name: server.name.clone(),
                    needs_connection: server.needs_connection,
                },
            ));
        }
        tools
    }

    fn set_options(&mut self, options: ComposerOptions, cx: &mut Context<Self>) {
        self.web_search &= options.web_search;
        self.image_generation &= options.image_generation;
        // A choice made stays visible to be turned off, with why it will not
        // run ([`Self::code_interpreter_block`]), as mobile's pill does; it
        // goes only where no Open WebUI turn will take it.
        if !options.code_interpreter && options.code_interpreter_block.is_none() {
            self.code_interpreter = false;
        }
        let librechat = self.librechat_tools();
        let offered: BTreeSet<&str> = options
            .tools
            .iter()
            .chain(&options.mcp_tools)
            .map(|t| t.id.as_str())
            .chain(librechat.iter().map(|(id, _)| id.as_str()))
            .collect();
        self.tool_ids.retain(|id| offered.contains(id.as_str()));
        // Filters start from the model's own defaults, until the user picks.
        let filters: BTreeSet<&str> = options.filters.iter().map(|f| f.id.as_str()).collect();
        if self.filters_touched {
            self.filter_ids.retain(|id| filters.contains(id.as_str()));
        } else {
            self.filter_ids = options
                .filter_defaults
                .iter()
                .filter(|id| filters.contains(id.as_str()))
                .cloned()
                .collect();
        }
        self.options = options;
        cx.notify();
    }

    pub fn toggle_web_search(&mut self, cx: &mut Context<Self>) {
        self.web_search = self.options.web_search && !self.web_search;
        cx.notify();
    }

    pub fn toggle_image_generation(&mut self, cx: &mut Context<Self>) {
        self.image_generation = self.options.image_generation && !self.image_generation;
        cx.notify();
    }

    pub fn toggle_tool(&mut self, id: &str, cx: &mut Context<Self>) {
        if !self.tool_ids.remove(id) {
            self.tool_ids.insert(id.to_string());
        }
        cx.notify();
    }

    pub fn toggle_filter(&mut self, id: &str, cx: &mut Context<Self>) {
        if !self.filter_ids.remove(id) {
            self.filter_ids.insert(id.to_string());
        }
        self.filters_touched = true;
        cx.notify();
    }

    /// The code interpreter, on or off. Turning it on needs the server's
    /// offer; turning it off always works.
    pub fn toggle_code_interpreter(&mut self, cx: &mut Context<Self>) {
        self.code_interpreter = !self.code_interpreter
            && self.options.code_interpreter
            && self.options.code_interpreter_block.is_none();
        cx.notify();
    }

    /// Why the chosen code interpreter will not run for this model (the
    /// core's `CodeInterpreterBlock` name), when it will not.
    pub fn code_interpreter_block(&self) -> Option<&str> {
        self.options.code_interpreter_block.as_deref()
    }

    pub fn set_mention(&mut self, model: Option<ModelSummary>, cx: &mut Context<Self>) {
        self.mention = model;
        cx.notify();
    }

    // ── Prompts and knowledge ───────────────────────────────────────────

    /// Whether the composer writes to Hermes: a Hermes session's chat, or
    /// the Hermes model chosen for a new one.
    pub fn is_hermes(&self) -> bool {
        self.chat_id()
            .is_some_and(|id| id.starts_with("local:hermes_"))
            || self
                .selected_model()
                .is_some_and(|m| m.id.starts_with("hermes:"))
    }

    /// The agent's skills were read again (Reload Skills) on
    /// `hermes_connection`, the one in use: a Hermes chat's `/` list is read
    /// again now, so a menu that is open shows them.
    pub fn reload_hermes_prompts(
        &mut self,
        hermes_connection: Option<String>,
        cx: &mut Context<Self>,
    ) {
        if !self.prompts_hermes {
            return;
        }
        self.prompts = None;
        if self.is_hermes() {
            self.load_prompts(hermes_connection, cx);
        }
    }

    /// What `/` lists, once (and again after `reset`, or when the chat
    /// moves between Hermes and the rest): saved prompts (`prompts.list`),
    /// or in a Hermes chat the agent's commands (`hermes.catalog`), as
    /// mobile's composer sources its `/` overlay.
    pub fn load_prompts(&mut self, hermes_connection: Option<String>, cx: &mut Context<Self>) {
        let hermes = self.is_hermes();
        if self.prompts.is_some()
            && self.prompts_hermes == hermes
            && (!hermes || self.prompts_connection == hermes_connection)
        {
            return;
        }
        self.prompts = Some(vec![]);
        self.prompts_hermes = hermes;
        self.prompts_connection = hermes.then(|| hermes_connection.clone()).flatten();
        let scope = self.scope;
        if hermes {
            let call = self.rpc.call::<methods::HermesCatalog>(&NoParams);
            cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
                let result = call.await;
                let _ = this.update(cx, |s, cx| {
                    // Another account's, the chat left Hermes since, or
                    // another connection's commands were asked for since.
                    if s.scope != scope
                        || !s.prompts_hermes
                        || s.prompts_connection != hermes_connection
                    {
                        return;
                    }
                    match result {
                        Ok(catalog) => s.prompts = Some(hermes_prompts(&catalog)),
                        Err(e) => {
                            log::info!("hermes.catalog: {e}");
                            s.prompts = None;
                        }
                    }
                    cx.notify();
                });
            })
            .detach();
            return;
        }
        let call = self.rpc.call::<methods::PromptsList>(&NoParams);
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result = call.await;
            let _ = this.update(cx, |s, cx| {
                // Another account's list never fills this one's, nor a
                // Hermes chat's (moved there since).
                if s.scope != scope || s.prompts_hermes {
                    return;
                }
                match result {
                    Ok(list) => s.prompts = Some(list.prompts),
                    Err(e) => {
                        log::info!("prompts.list: {e}");
                        s.prompts = None;
                    }
                }
                cx.notify();
            });
        })
        .detach();
    }

    /// `prompts.render`: the text, or the fields to ask for.
    /// The account scope: [`Self::reset`] moves it on.
    pub fn scope(&self) -> u64 {
        self.scope
    }

    pub fn render_prompt(
        &self,
        request: RenderPrompt,
        cx: &mut Context<Self>,
    ) -> Task<Result<RenderedPrompt, RpcError>> {
        let call = self.rpc.call::<methods::PromptsRender>(&request);
        cx.background_spawn(call)
    }

    /// `mentions.search` for what follows an `@`.
    pub fn search_mentions(&mut self, query: &str, cx: &mut Context<Self>) {
        if !self.options.mentions {
            return;
        }
        // In a channel: its members and the channels to link.
        if let Some(channel_id) = self.channel.clone() {
            let params = conduit_protocol::ChannelMentionQuery {
                channel_id,
                query: query.to_string(),
            };
            self.search::<methods::ChannelsMentions>(
                Search::Mentions,
                query,
                params,
                cx,
                |s, list| s.mention_results = list,
            );
            return;
        }
        self.search::<methods::MentionsSearch>(
            Search::Mentions,
            query,
            search(query),
            cx,
            |s, list| s.mention_results = list,
        );
    }

    /// `context.search` for what follows a `#`.
    pub fn search_context(&mut self, query: &str, cx: &mut Context<Self>) {
        self.search::<methods::ContextSearch>(
            Search::Context,
            query,
            search(query),
            cx,
            |s, list| s.context_results = list.items,
        );
    }

    /// `skills.search` for what follows a `$`.
    pub fn search_skills(&mut self, query: &str, cx: &mut Context<Self>) {
        self.search::<methods::SkillsSearch>(
            Search::Skills,
            query,
            search(query),
            cx,
            |s, list| s.skill_results = list.items,
        );
    }

    /// Asks `M` 150 ms after `query` last changed, and keeps its answer.
    /// Replacing the task drops a search still waiting: only the query
    /// typed last is asked, once its pause is over. A failed one empties
    /// its list and may be asked again; an older account's answer is
    /// dropped.
    fn search<M>(
        &mut self,
        kind: Search,
        query: &str,
        params: M::Params,
        cx: &mut Context<Self>,
        keep: fn(&mut Self, M::Result),
    ) where
        M: conduit_protocol::RpcMethod,
        M::Params: 'static,
        M::Result: Default + Send + 'static,
    {
        let slot = kind as usize;
        if self.searched[slot].as_deref() == Some(query) {
            return;
        }
        self.searched[slot] = Some(query.to_string());
        let rpc = self.rpc.clone();
        let scope = self.scope;
        self._searches[slot] = Some(cx.spawn(
            async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
                cx.background_executor()
                    .timer(Duration::from_millis(150))
                    .await;
                let result = rpc.call::<M>(&params).await;
                let _ = this.update(cx, |s, cx| {
                    if s.scope != scope {
                        return;
                    }
                    match result {
                        Ok(r) => keep(s, r),
                        Err(e) => {
                            log::info!("composer search: {e}");
                            keep(s, M::Result::default());
                            // The same query may be asked again.
                            s.searched[slot] = None;
                        }
                    }
                    cx.notify();
                });
            },
        ));
    }

    /// `files.list`: the account's files on the server, for the picker.
    pub fn server_files(
        &self,
        query: &str,
        cx: &mut Context<Self>,
    ) -> Task<Result<ServerFileList, RpcError>> {
        let call = self.rpc.call::<methods::FilesList>(&search(query));
        cx.background_spawn(call)
    }

    /// `context.fetchUrl`: a web page's text or a YouTube transcript.
    pub fn fetch_url(
        &self,
        url: &str,
        cx: &mut Context<Self>,
    ) -> Task<Result<FetchedUrl, RpcError>> {
        let call = self.rpc.call::<methods::ContextFetchUrl>(&FetchUrl {
            url: url.to_string(),
        });
        cx.background_spawn(call)
    }

    pub fn add_context(&mut self, item: ContextAttachmentDto, cx: &mut Context<Self>) {
        let same = |c: &ContextAttachmentDto| {
            c.kind == item.kind
                && match (&c.file_id, &item.file_id) {
                    (Some(a), Some(b)) => a == b,
                    _ => c.id == item.id || (c.url.is_some() && c.url == item.url),
                }
        };
        if !self.context.iter().any(same) {
            self.context.push(item);
        }
        cx.notify();
    }

    pub fn remove_context(&mut self, id: &str, cx: &mut Context<Self>) {
        self.context.retain(|c| c.id != id);
        cx.notify();
    }

    pub fn add_knowledge(&mut self, item: KnowledgeSummary, cx: &mut Context<Self>) {
        if !self.knowledge.iter().any(|k| k.id == item.id) {
            self.knowledge.push(item);
        }
        cx.notify();
    }

    pub fn remove_knowledge(&mut self, id: &str, cx: &mut Context<Self>) {
        self.knowledge.retain(|k| k.id != id);
        cx.notify();
    }

    // ── Attachments ─────────────────────────────────────────────────────

    /// Adds files by path: each is read (a HEIC, RAW or BMP picture turned
    /// into a JPEG) and uploaded on its own.
    pub fn add_paths(&mut self, paths: &[PathBuf], cx: &mut Context<Self>) {
        for path in paths {
            let mut name = path
                .file_name()
                .map(|n| n.to_string_lossy().to_string())
                .unwrap_or_else(|| "file".into());
            let size = std::fs::metadata(path).map(|m| m.len()).unwrap_or(0);
            let convert = self.converts(&name) && self.converter.is_some();
            if convert {
                name = jpeg_name(&name);
            }
            let id = self.push(name.clone(), size, content_type_for(&name));
            if path.is_dir() {
                self.fail(id, "a folder cannot be attached".into(), false, cx);
                continue;
            }
            if size > MAX_ATTACHMENT_BYTES {
                self.fail(id, "larger than 256 MB".into(), false, cx);
                continue;
            }
            let path = path.clone();
            let converter = self.converter.clone().filter(|_| convert);
            if converter.is_some()
                && let Some(a) = self.get(id)
            {
                a.state = UploadState::Converting;
            }
            let read = cx.background_executor().spawn(async move {
                match converter {
                    Some(convert) => convert(&path),
                    None => std::fs::read(&path).map_err(|e| e.to_string()),
                }
            });
            cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
                let bytes = read.await;
                let _ = this.update(cx, |s, cx| match bytes {
                    Ok(bytes) => s.upload(id, Arc::new(bytes), cx),
                    Err(e) => s.fail(id, e, false, cx),
                });
            })
            .detach();
        }
        cx.notify();
    }

    /// A picture the server would not read as it is (HEIC, RAW, BMP): sent
    /// as a JPEG, by the daemon's list.
    pub fn converts(&self, name: &str) -> bool {
        let ext = format!(".{}", extension(name));
        self.options.image_conversions.contains(&ext)
    }

    /// Adds an image from the clipboard.
    pub fn add_image(&mut self, image: &Image, cx: &mut Context<Self>) {
        let ext = extension_for(image.format);
        let name = format!("Pasted image.{ext}");
        let bytes = image.bytes.clone();
        if bytes.len() as u64 > MAX_ATTACHMENT_BYTES {
            let id = self.push(name, bytes.len() as u64, None);
            self.fail(id, "larger than 256 MB".into(), false, cx);
            return;
        }
        let id = self.push(
            name,
            bytes.len() as u64,
            Some(mime_for(image.format).into()),
        );
        self.upload(id, Arc::new(bytes), cx);
    }

    /// A file already on the server: attached as it is.
    pub fn add_server_file(&mut self, file: &ServerFile, cx: &mut Context<Self>) {
        let already = self
            .attachments
            .iter()
            .any(|a| matches!(&a.state, UploadState::Done { file_id } if *file_id == file.id));
        if already {
            return;
        }
        let content_type = file
            .content_type
            .clone()
            .or_else(|| content_type_for(&file.name));
        let id = self.push(
            file.name.clone(),
            file.size.unwrap_or(0).max(0) as u64,
            content_type,
        );
        if let Some(a) = self.get(id) {
            a.server_file = true;
            a.state = UploadState::Done {
                file_id: file.id.clone(),
            };
        }
        cx.notify();
    }

    fn push(&mut self, name: String, size: u64, content_type: Option<String>) -> u64 {
        self.next_id += 1;
        let id = self.next_id;
        self.attachments.push(Attachment {
            local_id: id,
            name,
            size,
            content_type,
            image: None,
            state: UploadState::Reading,
            bytes: None,
            attempt: 1,
            server_file: false,
        });
        id
    }

    /// The attachment `id`, shown or parked with a draft taken.
    fn get(&mut self, id: u64) -> Option<&mut Attachment> {
        match self.attachments.iter().position(|a| a.local_id == id) {
            Some(at) => self.attachments.get_mut(at),
            None => self.parked.iter_mut().find(|a| a.local_id == id),
        }
    }

    fn fail(&mut self, id: u64, error: String, retry: bool, cx: &mut Context<Self>) {
        if let Some(a) = self.get(id) {
            log::warn!("attachment {}: {error}", a.name);
            let name = a.name.clone();
            if !retry {
                a.bytes = None;
            }
            a.state = UploadState::Failed { error, retry };
            cx.emit(ComposerEvent::AttachmentFailed { name });
        }
        cx.notify();
    }

    fn upload(&mut self, id: u64, bytes: Arc<Vec<u8>>, cx: &mut Context<Self>) {
        let Some(uploader) = self.uploader.clone() else {
            self.fail(id, "the daemon is not running".into(), false, cx);
            return;
        };
        // The bytes read, not the size first seen: a file that grew since
        // is held to the same limit.
        if bytes.len() as u64 > MAX_ATTACHMENT_BYTES {
            self.fail(id, "larger than 256 MB".into(), false, cx);
            return;
        }
        let Some(a) = self.get(id) else {
            return; // removed while reading
        };
        let total = bytes.len() as u64;
        a.size = total;
        a.state = UploadState::Uploading { sent: 0, total };
        if a.image.is_none()
            && let Some(format) = a.content_type.as_deref().and_then(format_for_mime)
        {
            a.image = Some(Arc::new(Image::from_bytes(format, bytes.to_vec())));
        }
        a.bytes = Some(bytes.clone());
        let attempt = a.attempt;
        let request_name = a.name.clone();
        let content_type = a.content_type.clone();
        let (tx, mut rx) = futures::channel::mpsc::unbounded::<(u64, u64)>();
        let progress: Progress = Arc::new(move |sent, total| {
            let _ = tx.unbounded_send((sent, total));
        });
        let future = uploader(UploadRequest {
            name: request_name,
            content_type,
            bytes: bytes.to_vec(),
            progress,
            attempt,
            channel_id: self.channel.clone(),
        });
        // Progress, as it comes.
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            use futures::StreamExt as _;
            while let Some((sent, total)) = rx.next().await {
                let alive = this.update(cx, |s, cx| {
                    if let Some(a) = s.get(id)
                        && matches!(a.state, UploadState::Uploading { .. })
                    {
                        a.state = UploadState::Uploading { sent, total };
                        cx.notify();
                    }
                });
                if alive.is_err() {
                    break;
                }
            }
        })
        .detach();
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result = future.await;
            let _ = this.update(cx, |s, cx| match result {
                Ok(file) => {
                    if let Some(a) = s.get(id) {
                        a.bytes = None;
                        a.state = UploadState::Done { file_id: file.id };
                    }
                    cx.notify();
                }
                Err(e) => s.upload_failed(id, e, cx),
            });
        })
        .detach();
        cx.notify();
    }

    /// An upload failed: tried again after the core's wait when it may be
    /// (no connection, or a refusal with tries left), else left for the
    /// user to retry.
    fn upload_failed(&mut self, id: u64, e: UploadError, cx: &mut Context<Self>) {
        let Some(a) = self.get(id) else {
            return;
        };
        let bytes = a.bytes.clone();
        match (e.retry, bytes) {
            (Retry::Offline | Retry::Retryable, Some(bytes)) => {
                if e.retry == Retry::Retryable {
                    a.attempt += 1;
                }
                a.state = UploadState::Waiting;
                log::info!(
                    "attachment {}: {}; again in {:?}",
                    a.name,
                    e.message,
                    e.wait
                );
                cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
                    cx.background_executor().timer(e.wait).await;
                    let _ = this.update(cx, |s, cx| {
                        // Still waiting (not removed, not retried by hand).
                        if s.get(id).is_some_and(|a| a.state == UploadState::Waiting) {
                            s.upload(id, bytes, cx);
                        }
                    });
                })
                .detach();
                cx.notify();
            }
            (_, bytes) => self.fail(id, e.message, bytes.is_some(), cx),
        }
    }

    /// Try Again on a failed upload: from the first try.
    pub fn retry_attachment(&mut self, local_id: u64, cx: &mut Context<Self>) {
        let Some(a) = self.get(local_id) else {
            return;
        };
        let Some(bytes) = a.bytes.clone().filter(|_| a.can_retry()) else {
            return;
        };
        a.attempt = 1;
        self.upload(local_id, bytes, cx);
    }

    pub fn remove_attachment(&mut self, local_id: u64, cx: &mut Context<Self>) {
        self.attachments.retain(|a| a.local_id != local_id);
        cx.notify();
    }

    /// Some file is still being read or uploaded: Send waits.
    pub fn uploading(&self) -> bool {
        self.attachments.iter().any(|a| {
            matches!(
                a.state,
                UploadState::Reading
                    | UploadState::Converting
                    | UploadState::Uploading { .. }
                    | UploadState::Waiting
            )
        })
    }

    /// Something to send besides text.
    pub fn has_attachments(&self) -> bool {
        self.attachments
            .iter()
            .any(|a| matches!(a.state, UploadState::Done { .. }))
            || !self.context.is_empty()
    }

    /// The uploaded files, as the sent message shows them until it is
    /// stored.
    pub fn pending_files(&self) -> Vec<ChatFileDto> {
        self.attachments
            .iter()
            .filter_map(|a| match &a.state {
                UploadState::Done { file_id } => Some(ChatFileDto {
                    id: Some(file_id.clone()),
                    name: a.name.clone(),
                    image: a.image.is_some(),
                    content_type: a.content_type.clone(),
                    data_url: None,
                }),
                _ => None,
            })
            .collect()
    }

    fn file_ids(&self) -> Vec<String> {
        self.attachments
            .iter()
            .filter_map(|a| match &a.state {
                UploadState::Done { file_id } => Some(file_id.clone()),
                _ => None,
            })
            .collect()
    }

    /// The options the next turn would take, with `mentions` from the text,
    /// leaving the composer as it is.
    pub fn turn_options(&self, mentions: Vec<ComposerMentionDto>) -> TurnOptions {
        // A new chat's own: its folder and settings.
        let new_chat = self.draft.as_ref().is_none_or(|k| k.chat_id.is_none());
        TurnOptions {
            model: self
                .mention
                .as_ref()
                .map(|m| m.id.clone())
                .or_else(|| self.offered_draft_model())
                // Every turn names the model this chat shows (its own agent
                // included): never the account's selection of the moment,
                // which another chat's pick can change before this chat's
                // list catches up.
                .or_else(|| self.selected_model().map(|m| m.id.clone())),
            folder_id: new_chat.then(|| self.new_chat_folder.clone()).flatten(),
            chat_params: (new_chat && has_params(&self.draft_params))
                .then(|| self.draft_params.clone()),
            tool_ids: self.tool_ids.iter().cloned().collect(),
            filter_ids: self.filter_ids.iter().cloned().collect(),
            knowledge: self.knowledge.clone(),
            context: self.context.clone(),
            mentions,
            web_search: self.web_search,
            image_generation: self.image_generation,
            code_interpreter: self.code_interpreter,
            file_ids: self.file_ids(),
            compare_models: match (&self.compare_with, self.next_model()) {
                (Some(other), Some(first)) if other.id != first.id => {
                    vec![first.id.clone(), other.id.clone()]
                }
                _ => vec![],
            },
        }
    }

    /// Compare Models: the next message is also answered by `model`, side by
    /// side (`None`: by the one model only).
    pub fn set_compare_with(&mut self, model: Option<ModelSummary>, cx: &mut Context<Self>) {
        if self.compare_with != model {
            self.compare_with = model;
            cx.notify();
        }
    }

    /// The folder's model for a new chat, when this account is offered it
    /// (as [`Self::selected_model`] shows it); otherwise the turn goes to
    /// the model the composer shows.
    fn offered_draft_model(&self) -> Option<String> {
        let id = self.draft_model.as_ref()?;
        self.models
            .as_ref()?
            .models
            .iter()
            .any(|m| &m.id == id)
            .then(|| id.clone())
    }

    /// Settings sent with a new chat that was made after the user moved on
    /// ([`Self::new_chat_sent`] is for the chat that opens): they went with
    /// it, so the next new chat does not take them too.
    pub fn forget_sent_params(&mut self, sent: Option<&ParamsOwner>, cx: &mut Context<Self>) {
        // Only the settings that send carried, still owned by its draft:
        // never another draft's, even with the same values.
        if sent.is_some() && sent == self.params_owner.as_ref() {
            self.set_params(serde_json::Value::Null);
            cx.notify();
        }
    }

    /// Who owns the settings now: what a send takes with it, so its late
    /// answer forgets only those ([`Self::forget_sent_params`]).
    pub fn params_owner(&self) -> Option<ParamsOwner> {
        self.params_owner.clone()
    }

    /// The settings now, owned by this draft and round.
    fn set_params(&mut self, params: serde_json::Value) {
        self.params_rev += 1;
        self.params_owner = (!params.is_null()).then(|| ParamsOwner {
            draft: self.draft.clone(),
            folder: self.new_chat_folder.clone(),
            round: self.draft_round,
            rev: self.params_rev,
        });
        self.draft_params = params;
    }

    /// The draft open now and its round: what a Chat Settings sheet on a
    /// new chat saves to ([`Self::set_draft_params_for`]).
    pub fn draft_mark(&self) -> (Option<DraftKey>, u64) {
        (self.draft.clone(), self.draft_round)
    }

    /// [`Self::set_draft_params`], only while `mark`'s draft is still the
    /// one open (a first send since made its chat, or another chat opened:
    /// the settings belong to no draft here). False when refused.
    pub fn set_draft_params_for(
        &mut self,
        mark: &(Option<DraftKey>, u64),
        params: serde_json::Value,
        cx: &mut Context<Self>,
    ) -> bool {
        if self.draft_mark() != *mark {
            return false;
        }
        self.set_draft_params(params, cx);
        true
    }

    /// Keeps a new chat's settings for its first message.
    pub fn set_draft_params(&mut self, params: serde_json::Value, cx: &mut Context<Self>) {
        self.set_params(params);
        cx.notify();
    }

    /// A new chat was made with what this composer held for it.
    pub fn new_chat_sent(&mut self, cx: &mut Context<Self>) {
        // The new chat's draft is done with: a sheet still open on it (a
        // temporary chat keeps no draft key to tell it by) saves nowhere.
        self.draft_round += 1;
        self.set_params(serde_json::Value::Null);
        self.new_chat_folder = None;
        self.draft_model = None;
        self._draft_model = None;
        cx.notify();
    }

    /// The folder's default model for a new chat in `folder_id`.
    fn resolve_draft_model(&mut self, folder_id: String, cx: &mut Context<Self>) {
        let call = self
            .rpc
            .call::<methods::FoldersDraftModel>(&conduit_protocol::FolderRef {
                folder_id: folder_id.clone(),
            });
        self._draft_model = Some(cx.spawn(
            async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
                let result = call.await;
                let _ = this.update(cx, |s, cx| {
                    let still = s.draft.as_ref().is_none_or(|k| k.chat_id.is_none())
                        && s.new_chat_folder.as_deref() == Some(folder_id.as_str());
                    if !still {
                        return;
                    }
                    match result {
                        Ok(found) => {
                            s.draft_model = found.model_ids.first().cloned();
                            s.refresh_options(cx);
                            s.follow_model_options(cx);
                        }
                        Err(e) => log::info!("folders.draftModel: {e}"),
                    }
                    cx.notify();
                });
            },
        ));
    }

    /// Clears what applies to one message: the `@` model, `#` context,
    /// attachments.
    pub fn clear_message(&mut self, cx: &mut Context<Self>) {
        self.mention = None;
        self.compare_with = None;
        self.knowledge.clear();
        self.context.clear();
        self.attachments.clear();
        cx.notify();
    }

    /// The options for the next turn, with `mentions` from the text. Clears
    /// what applies to one message.
    pub fn take_turn(
        &mut self,
        mentions: Vec<ComposerMentionDto>,
        cx: &mut Context<Self>,
    ) -> TurnOptions {
        let options = self.turn_options(mentions);
        self.clear_message(cx);
        options
    }

    /// A chat's `local:` id became the server's: its draft follows, with
    /// nothing re-read.
    /// A first send made a new chat: what the composer holds (`text`, typed
    /// while the send waited) becomes that chat's draft. A save still
    /// pending goes under the new key, and one already made under the New
    /// Chat key is taken back from there.
    pub fn adopt_draft(&mut self, key: DraftKey, text: &str, cx: &mut Context<Self>) {
        let _ = cx;
        let Some(old) = self.draft.take() else {
            return;
        };
        // A new chat's state (its agent pick) is the chat's it became.
        self.move_per_chat(&old, &key);
        self._draft = None;
        if !self.draft_saved.is_empty() {
            self.save_now(&old, "");
        }
        if !text.is_empty() {
            self.save_now(&key, text);
        }
        self.draft_saved = text.to_string();
        self.draft = Some(key);
    }

    /// A chat's id moved (`route.remap`, open or not): everything this
    /// composer keeps for it (its draft key, its agent pick) moves with it.
    pub fn rekey_chat(&mut self, from: &str, to: &str) {
        let moved = |key: &DraftKey| DraftKey {
            chat_id: Some(to.to_string()),
            folder_id: key.folder_id.clone(),
        };
        let keys: Vec<DraftKey> = self
            .agent_picks
            .keys()
            .filter(|k| k.chat_id.as_deref() == Some(from))
            .cloned()
            .collect();
        for key in keys {
            self.move_per_chat(&key, &moved(&key));
        }
        if let Some(draft) = &self.draft
            && draft.chat_id.as_deref() == Some(from)
        {
            self.draft = Some(moved(draft));
        }
    }

    /// The one place per-chat state moves from one key to another (a new
    /// chat's first message, a chat's id remapped): every map kept by chat
    /// moves here.
    fn move_per_chat(&mut self, old: &DraftKey, new: &DraftKey) {
        if let Some(pick) = self.agent_picks.remove(old) {
            self.agent_picks.insert(new.clone(), pick);
        }
    }

    // ── Drafts ──────────────────────────────────────────────────────────

    /// The draft this composer holds now.
    pub fn draft_key(&self) -> Option<&DraftKey> {
        self.draft.as_ref()
    }

    /// Which composition of the draft this is: it moves on whenever the
    /// draft starts over ([`Self::start_over`], another draft or account).
    pub fn draft_round(&self) -> u64 {
        self.draft_round
    }

    /// This composition's ticket, for an async result to carry.
    pub fn ticket(&self) -> CompositionTicket {
        CompositionTicket {
            scope: self.scope,
            round: self.draft_round,
        }
    }

    /// Whether `ticket`'s composition is still the one shown.
    pub fn holds(&self, ticket: CompositionTicket) -> bool {
        self.ticket() == ticket
    }

    /// Another chat opened: `text` (what the composer held) is kept for the
    /// chat it held it for, and the new chat's draft is read (it arrives as
    /// [`ComposerEvent::DraftLoaded`]). `None`: a chat that keeps none (a
    /// temporary one).
    pub fn switch_draft(&mut self, key: Option<DraftKey>, text: &str, cx: &mut Context<Self>) {
        let folder = key
            .as_ref()
            .filter(|k| k.chat_id.is_none())
            .and_then(|k| k.folder_id.clone());
        self.switch_to(key, folder, text, cx);
    }

    /// A new chat opened in `folder` (or none): one that keeps a draft, or
    /// a `temporary` one, which keeps none but still starts in the folder.
    pub fn switch_new_chat(
        &mut self,
        folder: Option<String>,
        temporary: bool,
        text: &str,
        cx: &mut Context<Self>,
    ) {
        let key = (!temporary).then(|| DraftKey {
            chat_id: None,
            folder_id: folder.clone(),
        });
        self.switch_to(key, folder, text, cx);
    }

    /// [`Self::switch_draft`] with the new chat's folder (None for an
    /// opened chat).
    fn switch_to(
        &mut self,
        key: Option<DraftKey>,
        folder: Option<String>,
        text: &str,
        cx: &mut Context<Self>,
    ) {
        if self.draft == key && self.new_chat_folder == folder {
            return;
        }
        if let Some(old) = self.draft.take()
            && text != self.draft_saved
        {
            self.save_now(&old, text);
        }
        self._draft = None;
        self.draft_saved = String::new();
        self.draft = key.clone();
        self.new_chat_folder = folder.clone();
        // Another chat's draft: a send still on its way from the last one
        // gives nothing back to this one.
        self.draft_round += 1;
        // A folder's model belongs to its new chat alone; an opened chat
        // drops a new chat's settings (mobile drops its pending ones).
        self.draft_model = None;
        self._draft_model = None;
        // Another folder's new chat: settings saved on this one stay
        // behind (a temporary switch in the same folder keeps them).
        let opened = key.as_ref().is_some_and(|k| k.chat_id.is_some());
        let elsewhere = self
            .params_owner
            .as_ref()
            .is_some_and(|o| o.folder != folder);
        if opened || elsewhere {
            self.set_params(serde_json::Value::Null);
        }
        if !opened && let Some(folder) = folder {
            self.resolve_draft_model(folder, cx);
        }
        cx.emit(ComposerEvent::DraftSwitched);
        // The chat's coding agents, whether it is one's (Regenerate and
        // Edit follow it) and the agent it was saved with are the new
        // chat's. Asked even while the first list is on its way: that one
        // was for the chat before.
        if self.channel.is_none() {
            self.refresh_models(cx);
        }
        let Some(key) = key else {
            return;
        };
        let call = self.rpc.call::<methods::DraftsGet>(&DraftRef {
            chat_id: key.chat_id.clone(),
            folder_id: key.folder_id.clone(),
        });
        let ticket = self.ticket();
        self._draft = Some(
            cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
                let draft = call.await;
                let _ = this.update(cx, |s, cx| {
                    if s.draft.as_ref() != Some(&key) || !s.holds(ticket) {
                        return;
                    }
                    let text = draft.map(|d: Draft| d.text).unwrap_or_default();
                    s.draft_saved = text.clone();
                    cx.emit(ComposerEvent::DraftLoaded { key, text });
                });
            }),
        );
    }

    /// The text changed: kept 400 ms after it last did.
    pub fn draft_changed(&mut self, text: &str, cx: &mut Context<Self>) {
        let Some(key) = self.draft.clone() else {
            return;
        };
        if text == self.draft_saved {
            self._draft = None;
            return;
        }
        let text = text.to_string();
        self._draft = Some(
            cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
                cx.background_executor()
                    .timer(Duration::from_millis(400))
                    .await;
                let _ = this.update(cx, |s, _| {
                    if s.draft.as_ref() == Some(&key) {
                        s.save_now(&key, &text);
                        s.draft_saved = text;
                    }
                });
            }),
        );
    }

    /// The message went out: its draft goes at once.
    pub fn clear_draft(&mut self, cx: &mut Context<Self>) {
        let _ = cx;
        self._draft = None;
        if let Some(key) = self.draft.clone()
            && !self.draft_saved.is_empty()
        {
            self.save_now(&key, "");
        }
        self.draft_saved = String::new();
    }

    fn save_now(&self, key: &DraftKey, text: &str) {
        let call = self.rpc.call::<methods::DraftsSave>(&DraftSave {
            chat_id: key.chat_id.clone(),
            folder_id: key.folder_id.clone(),
            text: text.to_string(),
        });
        // A call goes out when it is made; its answer is not needed (a lost
        // save costs one draft, never a message).
        drop(call);
    }

    /// Takes attachments another window's composer hands over (Quick Ask's
    /// Open in Conduit), under this window's ids.
    pub fn adopt_attachments(&mut self, attachments: Vec<Attachment>, cx: &mut Context<Self>) {
        for mut a in attachments {
            self.next_id += 1;
            a.local_id = self.next_id;
            self.attachments.push(a);
        }
        cx.notify();
    }

    /// The uploaded attachments, taken out of this composer.
    pub fn take_uploaded(&mut self, cx: &mut Context<Self>) -> Vec<Attachment> {
        let (done, rest) = std::mem::take(&mut self.attachments)
            .into_iter()
            .partition(|a| matches!(a.state, UploadState::Done { .. }));
        self.attachments = rest;
        cx.notify();
        done
    }

    /// What [`Self::take_turn`] is about to use up for one message: the
    /// uploaded attachments, the chosen knowledge and context, and the `@`
    /// model.
    pub fn one_shot(&self) -> OneShot {
        OneShot {
            scope: self.scope,
            draft: self.draft_round,
            attachments: self
                .attachments
                .iter()
                .filter(|a| matches!(a.state, UploadState::Done { .. }))
                .cloned()
                .collect(),
            knowledge: self.knowledge.clone(),
            context: self.context.clone(),
            mention: self.mention.clone(),
            mentions: vec![],
            compare_with: self.compare_with.clone(),
            recordings: None,
        }
    }

    /// What a send that uses only its text (a steer, Save as Note) gives
    /// back ([`Self::give_back`]): nothing but the text, to the same account
    /// and draft.
    pub fn text_only(&self) -> OneShot {
        OneShot {
            scope: self.scope,
            draft: self.draft_round,
            ..OneShot::default()
        }
    }

    /// Puts back what a message that was not sent used up: its attachments
    /// before any added since, its knowledge, context and model unless
    /// chosen anew.
    /// Only to the account and draft it was taken from: after another
    /// account or a new draft it is dropped (false).
    pub fn give_back(&mut self, used: OneShot, cx: &mut Context<Self>) -> bool {
        if used.scope != self.scope || used.draft != self.draft_round {
            return false;
        }
        let mut attachments = used.attachments;
        attachments.retain(|a| !self.attachments.iter().any(|b| b.local_id == a.local_id));
        attachments.append(&mut self.attachments);
        self.attachments = attachments;
        if self.knowledge.is_empty() {
            self.knowledge = used.knowledge;
        }
        if self.context.is_empty() {
            self.context = used.context;
        }
        if self.mention.is_none() {
            self.mention = used.mention;
        }
        if self.compare_with.is_none() {
            self.compare_with = used.compare_with;
        }
        cx.notify();
        true
    }

    /// Another draft is shown in the same composer (a channel's thread
    /// composer, another thread): what one message would use is taken with
    /// it, to come back with [`Self::put_draft`], and a send still on its
    /// way gives nothing back to the next draft.
    /// Every file goes with it, those still reading, uploading or waiting
    /// too: their uploads land in [`Self::parked`] meanwhile.
    pub fn take_draft(&mut self, cx: &mut Context<Self>) -> OneShot {
        let mut used = self.one_shot();
        let all = std::mem::take(&mut self.attachments);
        self.parked
            .extend(all.iter().filter(|a| a.in_flight()).cloned());
        used.attachments = all;
        self.start_over(cx);
        used
    }

    /// Puts back what [`Self::take_draft`] (or a send that failed) took from
    /// a draft shown again, under the same account only.
    pub fn put_draft(&mut self, mut used: OneShot, cx: &mut Context<Self>) -> bool {
        if used.scope != self.scope {
            return false;
        }
        // Parked files come back as they are now (uploaded since, or failed).
        for a in &mut used.attachments {
            if let Some(at) = self.parked.iter().position(|p| p.local_id == a.local_id) {
                *a = self.parked.remove(at);
            }
        }
        used.draft = self.draft_round;
        self.give_back(used, cx)
    }

    /// A new draft: what one message would use goes (attachments,
    /// knowledge, context, the `@` model), and a send still on its way gives
    /// nothing back to it.
    pub fn start_over(&mut self, cx: &mut Context<Self>) {
        self.draft_round += 1;
        self.attachments.clear();
        self.knowledge.clear();
        self.context.clear();
        self.mention = None;
        self.compare_with = None;
        cx.notify();
    }

    /// Another account: start over. Answers to what the last account
    /// asked are dropped when they arrive.
    pub fn reset(&mut self, cx: &mut Context<Self>) {
        self.scope += 1;
        self.agent_picks.clear();
        self.draft_round += 1;
        self.parked.clear();
        self._searches = [None, None, None];
        self._options = None;
        self._model_options = None;
        self.model_options = None;
        self._model_controls = None;
        self.model_controls = None;
        self.models = None;
        self.options = ComposerOptions::default();
        self.librechat = LibreChatComposer::default();
        self.prompts = None;
        self.mention_results = MentionList::default();
        self.context_results.clear();
        self.skill_results.clear();
        self.searched = [None, None, None];
        self.attachments.clear();
        self.mention = None;
        self.compare_with = None;
        self.knowledge.clear();
        self.context.clear();
        self.tool_ids.clear();
        self.filter_ids.clear();
        self.filters_touched = false;
        self.web_search = false;
        self.image_generation = false;
        self.code_interpreter = false;
        self.draft = None;
        self.new_chat_folder = None;
        self.draft_saved = String::new();
        self._draft = None;
        self.set_params(serde_json::Value::Null);
        self.draft_model = None;
        self._draft_model = None;
        self.refresh_models(cx);
        // The last account's text, panel and prompt leave the field.
        cx.emit(ComposerEvent::DraftSwitched);
    }
}

/// Whether `params` holds any setting.
fn has_params(params: &serde_json::Value) -> bool {
    params.as_object().is_some_and(|o| !o.is_empty())
}

fn search(query: &str) -> ComposerSearch {
    ComposerSearch {
        query: query.to_string(),
    }
}

/// `photo.heic` → `photo.jpg`.
fn jpeg_name(name: &str) -> String {
    let stem = Path::new(name)
        .file_stem()
        .map(|s| s.to_string_lossy().to_string())
        .unwrap_or_else(|| "image".into());
    format!("{stem}.jpg")
}

#[cfg(target_os = "macos")]
fn default_converter() -> Option<Converter> {
    Some(Arc::new(|path: &Path| {
        crate::shell::macos::jpeg_from_image(path, 0.9)
    }))
}

#[cfg(not(target_os = "macos"))]
fn default_converter() -> Option<Converter> {
    None
}

// ── Triggers ───────────────────────────────────────────────────────────────

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TriggerKind {
    /// `/prompt`
    Prompt,
    /// `@model`
    Model,
    /// `#knowledge`: notes, knowledge bases and their files.
    Knowledge,
    /// `$skill`: an Open WebUI skill.
    Skill,
}

/// A `/`, `@`, `#` or `$` word being typed at the caret.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Trigger {
    pub kind: TriggerKind,
    /// Byte offset of the sigil, so choosing replaces just the word.
    pub start: usize,
    /// What follows the sigil, lower-cased.
    pub query: String,
}

/// The trigger word that ends at `cursor` (a byte offset into `text`).
///
/// Only at the start of a word, and only up to the caret: `src/main.rs` or
/// `1/2` in a sentence is not a request for the prompt menu, and neither is
/// an email address.
pub fn trigger_at(text: &str, cursor: usize) -> Option<Trigger> {
    let mut cursor = cursor.min(text.len());
    while !text.is_char_boundary(cursor) {
        cursor -= 1;
    }
    let before = &text[..cursor];
    let start = before
        .char_indices()
        .rev()
        .find(|(_, c)| c.is_whitespace())
        .map(|(i, c)| i + c.len_utf8())
        .unwrap_or(0);
    let word = &before[start..];
    let mut chars = word.chars();
    let kind = match chars.next()? {
        '/' => TriggerKind::Prompt,
        '@' => TriggerKind::Model,
        '#' => TriggerKind::Knowledge,
        '$' => TriggerKind::Skill,
        _ => return None,
    };
    let rest = chars.as_str();
    let sigil = word.chars().next()?;
    if rest.contains(sigil) {
        return None;
    }
    // `$5` is a price, not a skill.
    if kind == TriggerKind::Skill && rest.starts_with(|c: char| c.is_ascii_digit()) {
        return None;
    }
    Some(Trigger {
        kind,
        start,
        query: rest.to_lowercase(),
    })
}

// ── Mentions ───────────────────────────────────────────────────────────────

/// What an inline mention in the field stands for, kept in its token's id:
/// `U:<user id>`, `C:<channel id>` or `S:<skill id>`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum MentionTarget {
    User(String),
    Channel(String),
    Skill(String),
    /// A model asked in a channel (`<@M:id|Name>`), which answers there.
    Model(String),
}

impl MentionTarget {
    pub fn token_id(&self) -> String {
        match self {
            Self::User(id) => format!("U:{id}"),
            Self::Channel(id) => format!("C:{id}"),
            Self::Skill(id) => format!("S:{id}"),
            Self::Model(id) => format!("M:{id}"),
        }
    }

    pub fn from_token_id(token: &str) -> Option<Self> {
        let (kind, id) = token.split_once(':')?;
        match kind {
            "U" => Some(Self::User(id.to_string())),
            "C" => Some(Self::Channel(id.to_string())),
            "S" => Some(Self::Skill(id.to_string())),
            "M" => Some(Self::Model(id.to_string())),
            _ => None,
        }
    }

    /// The sigil the field shows before its name.
    pub fn sigil(&self) -> char {
        match self {
            Self::Skill(_) => '$',
            _ => '@',
        }
    }
}

/// The mentions in `text` (`(byte range, token id, label)` from the field's
/// inline tokens) as the daemon takes them: UTF-16 offsets, as the core's
/// tracker counts.
pub fn mentions_in(
    text: &str,
    tokens: impl IntoIterator<Item = (std::ops::Range<usize>, String, String)>,
) -> Vec<ComposerMentionDto> {
    tokens
        .into_iter()
        .filter_map(|(range, id, label)| {
            let target = MentionTarget::from_token_id(&id)?;
            if range.end > text.len()
                || !text.is_char_boundary(range.start)
                || !text.is_char_boundary(range.end)
            {
                return None;
            }
            let start = text[..range.start].encode_utf16().count() as i64;
            let end = start + text[range.clone()].encode_utf16().count() as i64;
            let (id_type, kind, id) = match target {
                MentionTarget::User(id) => ("U", conduit_protocol::MentionKind::Entity, id),
                MentionTarget::Channel(id) => ("C", conduit_protocol::MentionKind::Entity, id),
                MentionTarget::Skill(id) => ("M", conduit_protocol::MentionKind::Skill, id),
                MentionTarget::Model(id) => ("M", conduit_protocol::MentionKind::Entity, id),
            };
            Some(ComposerMentionDto {
                start,
                end,
                id,
                label,
                id_type: id_type.into(),
                kind,
            })
        })
        .collect()
}

/// The most of a model's name the empty message box shows, in characters
/// as a reader counts them (mobile's `kChatComposerPlaceholderMaxNameLength`).
pub const PLACEHOLDER_NAME_MAX: usize = 24;

/// `name` as the empty message box names the model (mobile's
/// `chatComposerPlaceholder`): its runs of white space as one space, and a
/// name past [`PLACEHOLDER_NAME_MAX`] characters cut to one less and an
/// ellipsis. None for a name with nothing to show.
pub fn placeholder_model_name(name: &str) -> Option<String> {
    use unicode_segmentation::UnicodeSegmentation as _;
    let name = name.split_whitespace().collect::<Vec<_>>().join(" ");
    if name.is_empty() {
        return None;
    }
    let graphemes: Vec<&str> = name.graphemes(true).collect();
    if graphemes.len() <= PLACEHOLDER_NAME_MAX {
        return Some(name);
    }
    let kept = graphemes[..PLACEHOLDER_NAME_MAX - 1].concat();
    Some(format!("{}\u{2026}", kept.trim_end()))
}

/// The model `id` among the account's models, then the coding agents.
/// Whether `id` names a coding agent (`agent:<terminal>:<agent>:<model>`).
fn is_agent_id(id: &str) -> bool {
    id.starts_with("agent:")
}

/// A coding agent known by its id and the name the picker gives it.
fn agent_summary(id: &str, name: &str) -> ModelSummary {
    ModelSummary {
        id: id.to_string(),
        name: name.to_string(),
        description: None,
        pinned: false,
        capabilities: vec![],
        connection: None,
        logo: None,
        agent: None,
    }
}

pub fn find_model<'a>(list: &'a ModelList, id: &str) -> Option<&'a ModelSummary> {
    list.models.iter().chain(&list.agents).find(|m| m.id == id)
}

/// How a model is named on screen: with its direct connection, when it
/// comes from one.
pub fn model_label(model: &ModelSummary) -> String {
    match &model.connection {
        // Apple On-Device's connection is named as the model is.
        Some(c) if c != &model.name => format!("{} \u{b7} {c}", model.name),
        _ => model.name.clone(),
    }
}

/// Whether `model` is Apple's on-device model: a Direct model the daemon's
/// Apple adapter lists (`apple_on_device` among its capabilities).
pub fn is_apple_on_device(model: &ModelSummary) -> bool {
    model.connection.is_some() && model.capabilities.iter().any(|c| c == "apple_on_device")
}

/// One row of the model picker's list.
// A picker holds a few dozen rows for as long as it is open: boxing every
// model to shrink the heading would buy nothing.
#[allow(clippy::large_enum_variant)]
#[derive(Clone, Debug, PartialEq)]
pub enum PickerRow {
    /// A group's title under More Models (an agent section).
    Heading(String),
    Model(ModelSummary),
}

/// Whether the picker has models past its featured ones (the coding agents
/// among them).
pub fn has_more_models(list: &ModelList) -> bool {
    !list.featured_ids.is_empty()
        && (list.more_sections.iter().any(|s| !s.ids.is_empty())
            || list
                .agents
                .iter()
                .any(|a| !list.featured_ids.contains(&a.id)))
}

/// The picker's rows, as mobile's sheet lays them out (the daemon says
/// which are featured): with a `query`, every match, pinned first; without,
/// the featured models (the pinned ones, or the first few, the default and
/// the selected), and with `more` the rest, each titled group under its
/// heading. A daemon that sent no layout gets every model. The selected
/// terminal's coding agents come last, under `agents_heading`, as mobile's
/// sheet lists them (one pinned or selected leads with the featured ones).
pub fn picker_rows(
    list: &ModelList,
    query: &str,
    more: bool,
    agents_heading: &str,
) -> Vec<PickerRow> {
    let by_id = |id: &str| find_model(list, id).cloned();
    let agents_section = |rows: &mut Vec<PickerRow>, agents: Vec<ModelSummary>| {
        if !agents.is_empty() {
            rows.push(PickerRow::Heading(agents_heading.to_string()));
            rows.extend(agents.into_iter().map(PickerRow::Model));
        }
    };
    if !query.trim().is_empty() || list.featured_ids.is_empty() {
        let matched = |models: &[ModelSummary]| -> Vec<ModelSummary> {
            let mut found: Vec<ModelSummary> = if query.trim().is_empty() {
                models.to_vec()
            } else {
                match_models(query.trim(), models, usize::MAX)
                    .into_iter()
                    .cloned()
                    .collect()
            };
            found.sort_by_key(|m| !m.pinned);
            found
        };
        let mut rows: Vec<PickerRow> = matched(&list.models)
            .into_iter()
            .map(PickerRow::Model)
            .collect();
        agents_section(&mut rows, matched(&list.agents));
        return rows;
    }
    let mut rows: Vec<PickerRow> = list
        .featured_ids
        .iter()
        .filter_map(|id| by_id(id))
        .map(PickerRow::Model)
        .collect();
    if more {
        for section in &list.more_sections {
            let models: Vec<_> = section.ids.iter().filter_map(|id| by_id(id)).collect();
            if models.is_empty() {
                continue;
            }
            if !section.label.is_empty() {
                rows.push(PickerRow::Heading(section.label.clone()));
            }
            rows.extend(models.into_iter().map(PickerRow::Model));
        }
        let agents = list
            .agents
            .iter()
            .filter(|a| !list.featured_ids.contains(&a.id))
            .cloned()
            .collect();
        agents_section(&mut rows, agents);
    }
    rows
}

/// Models whose name or id matches `query`: those that start with it first.
pub fn match_models<'a>(
    query: &str,
    models: &'a [ModelSummary],
    limit: usize,
) -> Vec<&'a ModelSummary> {
    let query = query.to_lowercase();
    let (mut starts, mut contains) = (vec![], vec![]);
    for m in models {
        let (name, id) = (m.name.to_lowercase(), m.id.to_lowercase());
        if name.starts_with(&query) || id.starts_with(&query) {
            starts.push(m);
        } else if name.contains(&query) || id.contains(&query) {
            contains.push(m);
        }
    }
    starts.extend(contains);
    starts.truncate(limit);
    starts
}

/// A Hermes catalog's `/` commands as the menu lists prompts: `/name`,
/// titled by what it does (its name when Hermes says nothing).
pub fn hermes_prompts(catalog: &conduit_protocol::HermesCatalog) -> Vec<PromptSummary> {
    catalog
        .commands
        .iter()
        .map(|c| {
            let description = c
                .description
                .as_deref()
                .map(str::trim)
                .filter(|d| !d.is_empty())
                .map(String::from);
            PromptSummary {
                command: format!("/{}", c.name),
                title: description.clone().unwrap_or_else(|| c.name.clone()),
                description,
                uses_clipboard: false,
            }
        })
        .collect()
}

/// Prompts whose command starts with `query`, then those whose title
/// contains it.
pub fn match_prompts<'a>(
    query: &str,
    prompts: &'a [PromptSummary],
    limit: usize,
) -> Vec<&'a PromptSummary> {
    let query = query.to_lowercase();
    let (mut by_command, mut by_title) = (vec![], vec![]);
    for p in prompts {
        let command = p.command.trim_start_matches('/').to_lowercase();
        if command.starts_with(&query) {
            by_command.push(p);
        } else if p.title.to_lowercase().contains(&query) {
            by_title.push(p);
        }
    }
    by_command.extend(by_title);
    by_command.truncate(limit);
    by_command
}

// ── File types ─────────────────────────────────────────────────────────────

fn extension(name: &str) -> String {
    Path::new(name)
        .extension()
        .and_then(|e| e.to_str())
        .unwrap_or_default()
        .to_ascii_lowercase()
}

/// A content type from the file name, for the upload and the thumbnail.
pub fn content_type_for(name: &str) -> Option<String> {
    let mime = match extension(name).as_str() {
        "png" => "image/png",
        "jpg" | "jpeg" => "image/jpeg",
        "gif" => "image/gif",
        "webp" => "image/webp",
        "bmp" => "image/bmp",
        "heic" => "image/heic",
        "heif" => "image/heif",
        "tif" | "tiff" => "image/tiff",
        "svg" => "image/svg+xml",
        "pdf" => "application/pdf",
        "txt" | "log" => "text/plain",
        "md" | "markdown" => "text/markdown",
        "csv" => "text/csv",
        "json" => "application/json",
        "html" | "htm" => "text/html",
        "docx" => "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        "xlsx" => "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        "pptx" => "application/vnd.openxmlformats-officedocument.presentationml.presentation",
        _ => return None,
    };
    Some(mime.into())
}

fn format_for_mime(mime: &str) -> Option<ImageFormat> {
    Some(match mime {
        "image/png" => ImageFormat::Png,
        "image/jpeg" => ImageFormat::Jpeg,
        "image/gif" => ImageFormat::Gif,
        "image/webp" => ImageFormat::Webp,
        "image/bmp" => ImageFormat::Bmp,
        "image/tiff" => ImageFormat::Tiff,
        "image/svg+xml" => ImageFormat::Svg,
        _ => return None,
    })
}

fn mime_for(format: ImageFormat) -> &'static str {
    match format {
        ImageFormat::Png => "image/png",
        ImageFormat::Jpeg => "image/jpeg",
        ImageFormat::Gif => "image/gif",
        ImageFormat::Webp => "image/webp",
        ImageFormat::Bmp => "image/bmp",
        ImageFormat::Tiff => "image/tiff",
        ImageFormat::Svg => "image/svg+xml",
        _ => "application/octet-stream",
    }
}

fn extension_for(format: ImageFormat) -> &'static str {
    match format {
        ImageFormat::Png => "png",
        ImageFormat::Jpeg => "jpg",
        ImageFormat::Gif => "gif",
        ImageFormat::Webp => "webp",
        ImageFormat::Bmp => "bmp",
        ImageFormat::Tiff => "tiff",
        ImageFormat::Svg => "svg",
        _ => "img",
    }
}

#[cfg(test)]
mod tests {
    fn summary(id: &str, pinned: bool) -> ModelSummary {
        ModelSummary {
            id: id.into(),
            name: id.into(),
            description: None,
            pinned,
            capabilities: vec![],
            connection: None,
            logo: None,
            agent: None,
        }
    }

    fn laid_out() -> ModelList {
        ModelList {
            models: vec![
                summary("a", true),
                summary("b", false),
                summary("c", false),
                summary("agent", false),
            ],
            selected_id: Some("a".into()),
            featured_ids: vec!["a".into()],
            more_sections: vec![
                conduit_protocol::ModelSection {
                    label: String::new(),
                    ids: vec!["b".into(), "c".into()],
                },
                conduit_protocol::ModelSection {
                    label: "Agents".into(),
                    ids: vec!["agent".into()],
                },
            ],
            can_pin: true,
            default_id: None,
            agents: vec![],
            agent_names: Default::default(),
            chat_agent: None,
        }
    }

    fn coding_agent(id: &str) -> ModelSummary {
        ModelSummary {
            agent: Some(conduit_protocol::TerminalAgentDto {
                terminal_id: "bench".into(),
                terminal_name: Some("Bench".into()),
                agent: "codex".into(),
                agent_name: "Codex".into(),
                model: id.into(),
            }),
            ..summary(id, false)
        }
    }

    #[test]
    fn the_message_box_names_a_model_in_at_most_24_characters() {
        assert_eq!(placeholder_model_name("  "), None);
        assert_eq!(
            placeholder_model_name(" Kestrel\n  8B ").as_deref(),
            Some("Kestrel 8B")
        );
        let exact = "a".repeat(24);
        assert_eq!(
            placeholder_model_name(&exact).as_deref(),
            Some(exact.as_str())
        );
        // Cut to 23 and an ellipsis, with no space before it.
        assert_eq!(
            placeholder_model_name("Harbour Pilot Assistant Long Edition").as_deref(),
            Some("Harbour Pilot Assistant\u{2026}")
        );
        // A flag is one character, as a reader counts it.
        let flags = "\u{1F1F3}\u{1F1F4}".repeat(30);
        let shown = placeholder_model_name(&flags).unwrap();
        assert_eq!(shown.chars().filter(|c| *c == '\u{2026}').count(), 1);
        assert_eq!(shown.chars().count(), 23 * 2 + 1);
    }

    #[test]
    fn coding_agents_follow_more_models_under_their_heading() {
        let mut list = laid_out();
        list.agents = vec![coding_agent("gpt-5.1"), coding_agent("gpt-5.1-mini")];
        // A selected agent leads with the featured ones, and only once.
        list.featured_ids.push("gpt-5.1".into());
        list.selected_id = Some("gpt-5.1".into());
        assert_eq!(
            ids(&picker_rows(&list, "", false, "Coding Agents")),
            ["a", "gpt-5.1"]
        );
        assert_eq!(
            ids(&picker_rows(&list, "", true, "Coding Agents")),
            [
                "a",
                "gpt-5.1",
                "b",
                "c",
                "# Agents",
                "agent",
                "# Coding Agents",
                "gpt-5.1-mini"
            ]
        );
        // A search finds them under their heading too.
        assert_eq!(
            ids(&picker_rows(&list, "mini", false, "Coding Agents")),
            ["# Coding Agents", "gpt-5.1-mini"]
        );
        assert_eq!(
            find_model(&list, "gpt-5.1").map(|m| m.id.as_str()),
            Some("gpt-5.1")
        );
        // Only agents past the featured ones: More Models still has some.
        list.more_sections.clear();
        assert!(has_more_models(&list));
        list.agents.truncate(1);
        assert!(!has_more_models(&list));
    }

    fn ids(rows: &[PickerRow]) -> Vec<String> {
        rows.iter()
            .map(|r| match r {
                PickerRow::Heading(h) => format!("# {h}"),
                PickerRow::Model(m) => m.id.clone(),
            })
            .collect()
    }

    #[test]
    fn the_picker_shows_the_featured_models_then_more_under_their_headings() {
        let list = laid_out();
        assert!(has_more_models(&list));
        assert_eq!(ids(&picker_rows(&list, "", false, "Coding Agents")), ["a"]);
        assert_eq!(
            ids(&picker_rows(&list, "", true, "Coding Agents")),
            ["a", "b", "c", "# Agents", "agent"]
        );
    }

    #[test]
    fn a_search_finds_every_model_pinned_first() {
        let mut list = laid_out();
        list.models[2].pinned = true;
        assert_eq!(ids(&picker_rows(&list, "c", false, "Coding Agents")), ["c"]);
        assert_eq!(ids(&picker_rows(&list, " ", false, "Coding Agents")), ["a"]);
        list.featured_ids.clear();
        assert!(!has_more_models(&list));
        assert_eq!(
            ids(&picker_rows(&list, "", false, "Coding Agents")),
            ["a", "c", "b", "agent"]
        );
    }

    use std::sync::Mutex;

    use conduit_protocol::{ContextSuggestions, ToolSummary, UploadedFile};
    use gpui_kit::{Entity, TestAppContext};
    use serde_json::json;

    use super::*;
    use crate::stores::rpc::fake::FakeDaemon;

    fn t(kind: TriggerKind, start: usize, query: &str) -> Option<Trigger> {
        Some(Trigger {
            kind,
            start,
            query: query.into(),
        })
    }

    #[test]
    fn triggers_start_a_word_and_end_at_the_caret() {
        let end = |s: &str| trigger_at(s, s.len());
        assert_eq!(end("/"), t(TriggerKind::Prompt, 0, ""));
        assert_eq!(end("/Sum"), t(TriggerKind::Prompt, 0, "sum"));
        assert_eq!(end("please /sum"), t(TriggerKind::Prompt, 7, "sum"));
        assert_eq!(end("line one\n@gpt"), t(TriggerKind::Model, 9, "gpt"));
        assert_eq!(end("#docs"), t(TriggerKind::Knowledge, 0, "docs"));
        // Not at the start of a word.
        assert_eq!(end("src/main.rs"), None);
        assert_eq!(end("1/2"), None);
        assert_eq!(end("me@example.org"), None);
        assert_eq!(end("issue#4"), None);
        // A finished word, or a path, is not a trigger.
        assert_eq!(end("/summarize "), None);
        assert_eq!(end("/usr/bin"), None);
        assert_eq!(end("plain text"), None);
        // Up to the caret, not the end of the text.
        assert_eq!(
            trigger_at("/sum and more", 4),
            t(TriggerKind::Prompt, 0, "sum")
        );
        // Non-ASCII before the caret.
        assert_eq!(end("ça /tr"), t(TriggerKind::Prompt, 4, "tr"));
        assert_eq!(trigger_at("é", 1), None);
    }

    fn model(id: &str, name: &str) -> ModelSummary {
        ModelSummary {
            id: id.into(),
            name: name.into(),
            description: None,
            pinned: false,
            capabilities: vec![],
            connection: None,
            logo: None,
            agent: None,
        }
    }

    fn prompt(command: &str, title: &str) -> PromptSummary {
        PromptSummary {
            command: command.into(),
            title: title.into(),
            description: None,
            uses_clipboard: false,
        }
    }

    #[test]
    fn matches_put_prefixes_first() {
        let models = vec![
            model("a/mini", "Big mini"),
            model("mini-2", "Mini 2"),
            model("x", "Other"),
        ];
        let names: Vec<_> = match_models("mini", &models, 8)
            .iter()
            .map(|m| m.id.as_str())
            .collect();
        assert_eq!(names, vec!["mini-2", "a/mini"]);
        assert_eq!(match_models("", &models, 2).len(), 2);
        let mut direct = model("d", "Llama");
        direct.connection = Some("Local".into());
        assert_eq!(model_label(&direct), "Llama \u{b7} Local");
        assert!(!is_apple_on_device(&direct));
        // Apple's model and its connection share a name: said once.
        let mut apple = model(
            "direct:apple-on-device:system-language-model",
            "Apple On-Device",
        );
        apple.connection = Some("Apple On-Device".into());
        apple.capabilities = vec!["apple_on_device".into(), "structured_outputs".into()];
        assert_eq!(model_label(&apple), "Apple On-Device");
        assert!(is_apple_on_device(&apple));
        // A server's model cannot claim to be Apple's: it has no connection.
        apple.connection = None;
        assert!(!is_apple_on_device(&apple));

        let prompts = vec![
            prompt("/translate", "Summarize in French"),
            prompt("/summarize", "Summary"),
        ];
        let commands: Vec<_> = match_prompts("sum", &prompts, 8)
            .iter()
            .map(|p| p.command.as_str())
            .collect();
        assert_eq!(commands, vec!["/summarize", "/translate"]);
    }

    /// Reports progress halfway, then answers from `outcome`.
    fn uploader(outcome: Arc<Mutex<Vec<Result<UploadedFile, UploadError>>>>) -> Uploader {
        Arc::new(move |req: UploadRequest| {
            let total = req.bytes.len() as u64;
            (req.progress)(total / 2, total);
            let answer = outcome.lock().unwrap().remove(0);
            Box::pin(async move { answer })
        })
    }

    /// Answers each file by its name, whichever is read first.
    fn uploader_by_name(
        outcome: Vec<(&'static str, Result<UploadedFile, UploadError>)>,
    ) -> Uploader {
        let outcome = Arc::new(Mutex::new(outcome));
        Arc::new(move |req: UploadRequest| {
            let mut outcome = outcome.lock().unwrap();
            let at = outcome.iter().position(|(n, _)| *n == req.name).unwrap();
            let answer = outcome.remove(at).1;
            Box::pin(async move { answer })
        })
    }

    fn uploaded(id: &str) -> Result<UploadedFile, UploadError> {
        Ok(UploadedFile {
            id: id.into(),
            name: "x".into(),
            size: 1,
            content_type: None,
        })
    }

    fn store(
        daemon: &FakeDaemon,
        outcome: Arc<Mutex<Vec<Result<UploadedFile, UploadError>>>>,
        cx: &mut TestAppContext,
    ) -> Entity<ComposerStore> {
        let rpc = daemon.rpc();
        cx.new(|_| ComposerStore::new(rpc, Some(uploader(outcome))))
    }

    #[gpui_kit::test]
    fn attachments_upload_on_their_own_and_send_waits_for_them(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        let rpc = daemon.rpc();
        let uploader = uploader_by_name(vec![
            ("notes.md", uploaded("f1")),
            (
                "big.pdf",
                Err(UploadError::manual("too big for the server")),
            ),
        ]);
        let store = cx.new(|_| ComposerStore::new(rpc, Some(uploader)));
        let dir = std::env::temp_dir().join(format!("p7-attach-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let (a, b) = (dir.join("notes.md"), dir.join("big.pdf"));
        std::fs::write(&a, b"# Notes").unwrap();
        std::fs::write(&b, b"%PDF-1.7").unwrap();
        store.update(cx, |s, cx| {
            s.add_paths(&[a.clone(), b.clone()], cx);
            assert!(s.uploading());
            assert_eq!(s.attachments.len(), 2);
            assert_eq!(
                s.attachments[0].content_type.as_deref(),
                Some("text/markdown")
            );
        });
        cx.run_until_parked();
        store.update(cx, |s, cx| {
            assert!(!s.uploading());
            assert_eq!(
                s.attachments[0].state,
                UploadState::Done {
                    file_id: "f1".into()
                }
            );
            assert!(matches!(s.attachments[1].state, UploadState::Failed { .. }));
            assert_eq!(s.pending_files().len(), 1);
            // The failed one is removed by the user; the turn takes the rest.
            let failed = s.attachments[1].local_id;
            s.remove_attachment(failed, cx);
            let turn = s.take_turn(vec![], cx);
            assert_eq!(turn.file_ids, vec!["f1".to_string()]);
            assert!(s.attachments.is_empty());
        });
    }

    /// Another thread shown while a file still uploads, and one whose
    /// upload failed: both are parked with their thread's draft, the upload
    /// lands there, and both come back with the draft (the failed one still
    /// offering Try Again).
    #[gpui_kit::test]
    fn a_draft_taken_mid_upload_keeps_its_files(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        let (tx, rx) = futures::channel::oneshot::channel::<Result<UploadedFile, UploadError>>();
        let pending = Arc::new(Mutex::new(Some(rx)));
        let upload: Uploader = Arc::new(move |req: UploadRequest| {
            if req.name.starts_with("Pasted") && pending.lock().unwrap().is_some() {
                let rx = pending.lock().unwrap().take().unwrap();
                return Box::pin(async move { rx.await.unwrap() });
            }
            Box::pin(async move { Err(UploadError::manual("refused")) })
        });
        let rpc = daemon.rpc();
        let store = cx.new(|_| ComposerStore::new(rpc, Some(upload)).with_converter(None));
        let png = Image::from_bytes(ImageFormat::Png, b"\x89PNG".to_vec());
        store.update(cx, |s, cx| s.add_image(&png, cx));
        let dir = std::env::temp_dir().join(format!("q3r-park-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let notes = dir.join("notes.md");
        std::fs::write(&notes, b"# Notes").unwrap();
        store.update(cx, |s, cx| s.add_paths(std::slice::from_ref(&notes), cx));
        cx.run_until_parked();
        store.read_with(cx, |s, _| {
            assert!(matches!(
                s.attachments[0].state,
                UploadState::Uploading { .. }
            ));
            assert!(s.attachments[1].can_retry());
        });
        let parked = store.update(cx, |s, cx| s.take_draft(cx));
        store.read_with(cx, |s, _| assert!(s.attachments.is_empty()));
        tx.send(uploaded("f9")).unwrap();
        cx.run_until_parked();
        store.update(cx, |s, cx| assert!(s.put_draft(parked, cx)));
        store.read_with(cx, |s, _| {
            assert_eq!(s.attachments.len(), 2, "a file went with the thread switch");
            assert_eq!(
                s.attachments[0].state,
                UploadState::Done {
                    file_id: "f9".into()
                },
                "the parked file's upload did not land in its draft"
            );
            assert!(s.attachments[1].can_retry());
        });
    }

    #[gpui_kit::test]
    fn a_pasted_image_uploads_with_a_thumbnail(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        let outcome = Arc::new(Mutex::new(vec![uploaded("img")]));
        let store = store(&daemon, outcome, cx);
        let png = Image::from_bytes(ImageFormat::Png, b"\x89PNG\r\n\x1a\nxxxx".to_vec());
        store.update(cx, |s, cx| s.add_image(&png, cx));
        store.read_with(cx, |s, _| {
            let a = &s.attachments[0];
            assert_eq!(a.name, "Pasted image.png");
            assert!(a.image.is_some());
        });
        cx.run_until_parked();
        store.read_with(cx, |s, _| assert!(s.has_attachments() && !s.uploading()));
    }

    /// A chat saved with a coding agent, opened while another model is
    /// selected: its list is asked even while the first list is on its way,
    /// the agent is offered (by the name the picker gives it) and never
    /// selected for the user, and Switch picks it for that chat. The
    /// composer's options are asked for the model it shows.
    #[gpui_kit::test]
    fn a_chat_saved_with_an_agent_offers_switch_to_it(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        let agent = "agent:north:codex:gpt-test";
        daemon.returns::<methods::ModelsList>(ModelList {
            models: vec![model("k", "Kestrel")],
            selected_id: Some("k".into()),
            agent_names: [(agent.to_string(), "Codex · gpt-test".to_string())].into(),
            chat_agent: Some(agent.into()),
            ..Default::default()
        });
        daemon.returns::<methods::ModelsSelect>(ModelList {
            models: vec![model("k", "Kestrel")],
            selected_id: Some(agent.into()),
            agents: vec![model(agent, "Codex · gpt-test")],
            ..Default::default()
        });
        daemon.returns::<methods::ComposerOptions>(ComposerOptions::default());
        daemon.returns::<methods::DraftsGet>(Draft::default());
        let store = store(&daemon, Arc::default(), cx);
        // The first list has not answered when the chat opens.
        let first = daemon.hold::<methods::ModelsList>();
        store.update(cx, |s, cx| s.refresh_models(cx));
        store.update(cx, |s, cx| {
            s.switch_draft(
                Some(DraftKey {
                    chat_id: Some("chat-7".into()),
                    folder_id: None,
                }),
                "",
                cx,
            )
        });
        first.release();
        cx.run_until_parked();
        let lists = daemon.calls::<methods::ModelsList>();
        assert!(
            lists.iter().any(|q| q["chatId"] == "chat-7"),
            "the opened chat was not listed: {lists:?}"
        );
        store.read_with(cx, |s, _| {
            assert_eq!(s.selected_model().map(|m| m.id.as_str()), Some("k"));
            assert_eq!(
                s.chat_agent(),
                Some((agent.to_string(), "Codex · gpt-test".to_string()))
            );
        });
        let options = daemon
            .calls::<methods::ComposerOptions>()
            .pop()
            .expect("options");
        assert_eq!(options["modelId"], "k");
        assert!(daemon.calls::<methods::ModelsSelect>().is_empty());
        // A one-message model is set; then Switch.
        store.update(cx, |s, cx| s.set_mention(Some(model("k", "Kestrel")), cx));
        store.update(cx, |s, cx| s.switch_to_chat_agent(agent, cx));
        cx.run_until_parked();
        let picks = daemon.calls::<methods::ModelsSelect>();
        assert_eq!(picks.len(), 1);
        assert_eq!(picks[0]["id"], agent);
        assert_eq!(picks[0]["chatId"], "chat-7");
        store.read_with(cx, |s, _| {
            assert_eq!(s.chat_agent(), None);
            assert!(s.mention.is_none(), "the one-message model outlived Switch");
            assert_eq!(
                s.selected_model().map(|m| m.id.as_str()),
                Some(agent),
                "Switch did not select the chat's agent"
            );
        });
    }

    /// A temporary chat picks a regular model: the pick's answer lists the
    /// terminal's agents (it is for a chat that is not temporary), but the
    /// composer offers none, so no agent can be picked or run there.
    #[gpui_kit::test]
    fn a_temporary_chat_offers_no_agent_after_a_pick(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        let agent = "agent:north:codex:gpt-test";
        let with_agents = |selected: &str| ModelList {
            models: vec![model("k", "Kestrel")],
            selected_id: Some(selected.into()),
            agents: vec![model(agent, "Codex · gpt-test")],
            ..Default::default()
        };
        daemon.returns::<methods::ModelsList>(ModelList {
            models: vec![model("k", "Kestrel")],
            selected_id: Some("k".into()),
            ..Default::default()
        });
        daemon.returns::<methods::ModelsSelect>(with_agents("k"));
        daemon.returns::<methods::ComposerOptions>(ComposerOptions::default());
        let store = store(&daemon, Arc::default(), cx);
        store.update(cx, |s, cx| s.refresh_models(cx));
        cx.run_until_parked();
        store.update(cx, |s, cx| s.select_model("k", cx));
        cx.run_until_parked();
        store.read_with(cx, |s, _| {
            let list = s.models.as_ref().expect("a list");
            assert!(list.agents.is_empty(), "a temporary chat offered an agent");
            assert!(find_model(list, agent).is_none());
        });
    }

    /// A coding agent picked in a chat is that chat's: a later list that
    /// does not offer it (empty, failed, stale) never changes it, it is
    /// shown, and every turn of the chat names it (the daemon sends a turn
    /// to an agent by its id, and the server refuses it, visibly, if it is
    /// gone), never another model.
    #[gpui_kit::test]
    fn a_chats_agent_pick_outlives_lists_that_lack_it(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        let agent = "agent:north:codex:gpt-test";
        let offering = ModelList {
            models: vec![model("k", "Kestrel")],
            selected_id: Some("k".into()),
            agents: vec![model(agent, "Codex · gpt-test")],
            ..Default::default()
        };
        daemon.returns::<methods::ComposerOptions>(ComposerOptions::default());
        daemon.returns::<methods::DraftsGet>(Draft::default());
        daemon.once::<methods::ModelsList>(Ok(offering.clone()));
        daemon.returns::<methods::ModelsSelect>(ModelList {
            selected_id: Some(agent.into()),
            ..offering
        });
        let store = store(&daemon, Arc::default(), cx);
        store.update(cx, |s, cx| {
            s.switch_draft(
                Some(DraftKey {
                    chat_id: Some("chat-7".into()),
                    folder_id: None,
                }),
                "",
                cx,
            )
        });
        cx.run_until_parked();
        store.update(cx, |s, cx| s.select_model(agent, cx));
        cx.run_until_parked();
        // The terminal answers with no agent now (and the daemon's
        // selection reads otherwise): the chat's pick stands.
        daemon.returns::<methods::ModelsList>(ModelList {
            models: vec![model("k", "Kestrel")],
            selected_id: Some("k".into()),
            ..Default::default()
        });
        store.update(cx, |s, cx| s.refresh_models(cx));
        cx.run_until_parked();
        store.read_with(cx, |s, _| {
            assert_eq!(s.selected_model().map(|m| m.id.as_str()), Some(agent));
            assert_eq!(s.turn_options(vec![]).model.as_deref(), Some(agent));
        });
    }

    /// A chat with no pick of its own has no agent: opening another chat
    /// after an agent was picked in one shows a regular model there, and
    /// its turn names that model, whatever the account's selection is.
    #[gpui_kit::test]
    fn another_chat_has_no_agent_of_its_own(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        let agent = "agent:north:codex:gpt-test";
        daemon.returns::<methods::ComposerOptions>(ComposerOptions::default());
        daemon.returns::<methods::DraftsGet>(Draft::default());
        daemon.returns::<methods::ModelsSelect>(ModelList {
            models: vec![model("k", "Kestrel")],
            selected_id: Some(agent.into()),
            agents: vec![model(agent, "Codex · gpt-test")],
            ..Default::default()
        });
        daemon.returns::<methods::ModelsList>(ModelList {
            models: vec![model("k", "Kestrel")],
            selected_id: Some(agent.into()),
            ..Default::default()
        });
        let store = store(&daemon, Arc::default(), cx);
        let chat = |id: &str| {
            Some(DraftKey {
                chat_id: Some(id.into()),
                folder_id: None,
            })
        };
        store.update(cx, |s, cx| s.switch_draft(chat("chat-7"), "", cx));
        cx.run_until_parked();
        store.update(cx, |s, cx| s.select_model(agent, cx));
        cx.run_until_parked();
        store.update(cx, |s, cx| s.switch_draft(chat("chat-8"), "", cx));
        cx.run_until_parked();
        store.read_with(cx, |s, _| {
            assert_eq!(s.selected_model().map(|m| m.id.as_str()), Some("k"));
            assert_eq!(s.turn_options(vec![]).model.as_deref(), Some("k"));
        });
        // Back in chat-7, its own agent.
        store.update(cx, |s, cx| s.switch_draft(chat("chat-7"), "", cx));
        cx.run_until_parked();
        store.read_with(cx, |s, _| {
            assert_eq!(s.selected_model().map(|m| m.id.as_str()), Some(agent));
        });
    }

    /// An agent picked in a new chat is the chat's once its first message
    /// made it.
    #[gpui_kit::test]
    fn a_new_chats_agent_pick_follows_it(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        let agent = "agent:north:codex:gpt-test";
        daemon.returns::<methods::ComposerOptions>(ComposerOptions::default());
        daemon.returns::<methods::DraftsGet>(Draft::default());
        daemon.returns::<methods::ModelsList>(ModelList {
            models: vec![model("k", "Kestrel")],
            selected_id: Some(agent.into()),
            agents: vec![model(agent, "Codex · gpt-test")],
            ..Default::default()
        });
        daemon.returns::<methods::ModelsSelect>(ModelList {
            models: vec![model("k", "Kestrel")],
            selected_id: Some(agent.into()),
            agents: vec![model(agent, "Codex · gpt-test")],
            ..Default::default()
        });
        let store = store(&daemon, Arc::default(), cx);
        store.update(cx, |s, cx| {
            s.switch_draft(
                Some(DraftKey {
                    chat_id: None,
                    folder_id: None,
                }),
                "",
                cx,
            )
        });
        cx.run_until_parked();
        store.update(cx, |s, cx| s.select_model(agent, cx));
        cx.run_until_parked();
        store.update(cx, |s, cx| {
            s.adopt_draft(
                DraftKey {
                    chat_id: Some("chat-9".into()),
                    folder_id: None,
                },
                "",
                cx,
            )
        });
        store.read_with(cx, |s, _| {
            assert_eq!(s.selected_model().map(|m| m.id.as_str()), Some(agent));
            assert_eq!(s.turn_options(vec![]).model.as_deref(), Some(agent));
        });
    }

    /// A pick the daemon refuses is not installed: the chat keeps what it
    /// had, and no turn names the refused agent.
    #[gpui_kit::test]
    fn a_refused_pick_leaves_the_chat_as_it_was(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        let agent = "agent:north:codex:gpt-test";
        daemon.returns::<methods::ComposerOptions>(ComposerOptions::default());
        daemon.returns::<methods::DraftsGet>(Draft::default());
        daemon.returns::<methods::ModelsList>(ModelList {
            models: vec![model("k", "Kestrel")],
            selected_id: Some("k".into()),
            agents: vec![model(agent, "Codex · gpt-test")],
            ..Default::default()
        });
        daemon.once::<methods::ModelsSelect>(Err(conduit_daemon::protocol::error(
            "rpc.notFound",
            "the terminal does not offer it here",
        )));
        let store = store(&daemon, Arc::default(), cx);
        store.update(cx, |s, cx| {
            s.switch_draft(
                Some(DraftKey {
                    chat_id: Some("chat-7".into()),
                    folder_id: None,
                }),
                "",
                cx,
            )
        });
        cx.run_until_parked();
        store.update(cx, |s, cx| s.select_model(agent, cx));
        cx.run_until_parked();
        store.read_with(cx, |s, _| {
            assert_eq!(s.selected_model().map(|m| m.id.as_str()), Some("k"));
            assert_ne!(s.turn_options(vec![]).model.as_deref(), Some(agent));
        });
    }

    /// A chat's id moving (`route.remap`), open or not, takes its agent
    /// pick along with its draft: the chat goes on with its agent.
    #[gpui_kit::test]
    fn a_remapped_chat_keeps_its_agent(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        let agent = "agent:north:codex:gpt-test";
        let offering = ModelList {
            models: vec![model("k", "Kestrel")],
            selected_id: Some(agent.into()),
            agents: vec![model(agent, "Codex · gpt-test")],
            ..Default::default()
        };
        daemon.returns::<methods::ComposerOptions>(ComposerOptions::default());
        daemon.returns::<methods::DraftsGet>(Draft::default());
        daemon.returns::<methods::ModelsList>(offering.clone());
        daemon.returns::<methods::ModelsSelect>(offering);
        let store = store(&daemon, Arc::default(), cx);
        let chat = |id: &str| {
            Some(DraftKey {
                chat_id: Some(id.into()),
                folder_id: None,
            })
        };
        store.update(cx, |s, cx| s.switch_draft(chat("local-1"), "", cx));
        cx.run_until_parked();
        store.update(cx, |s, cx| s.select_model(agent, cx));
        cx.run_until_parked();
        // Remapped while it is open.
        store.update(cx, |s, _| s.rekey_chat("local-1", "chat-9"));
        store.read_with(cx, |s, _| {
            assert_eq!(s.draft_key(), chat("chat-9").as_ref());
            assert_eq!(s.turn_options(vec![]).model.as_deref(), Some(agent));
        });
        // Remapped while another chat is open, then opened again.
        store.update(cx, |s, cx| s.switch_draft(chat("chat-8"), "", cx));
        cx.run_until_parked();
        store.update(cx, |s, _| s.rekey_chat("chat-9", "chat-9b"));
        store.update(cx, |s, cx| s.switch_draft(chat("chat-9b"), "", cx));
        cx.run_until_parked();
        store.read_with(cx, |s, _| {
            assert_eq!(s.turn_options(vec![]).model.as_deref(), Some(agent));
        });
    }

    /// A chat saved with a coding agent offers Switch while it has no pick
    /// of its own, even when the account picked that same agent in another
    /// chat: the offer and the model shown come from the chat, never from
    /// the account's selection.
    #[gpui_kit::test]
    fn a_saved_agent_is_offered_though_picked_elsewhere(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        let agent = "agent:north:codex:gpt-test";
        daemon.returns::<methods::ComposerOptions>(ComposerOptions::default());
        daemon.returns::<methods::DraftsGet>(Draft::default());
        daemon.returns::<methods::ModelsList>(ModelList {
            models: vec![model("k", "Kestrel")],
            selected_id: Some(agent.into()),
            agent_names: [(agent.to_string(), "Codex · gpt-test".to_string())].into(),
            chat_agent: Some(agent.into()),
            ..Default::default()
        });
        let store = store(&daemon, Arc::default(), cx);
        store.update(cx, |s, cx| {
            s.switch_draft(
                Some(DraftKey {
                    chat_id: Some("chat-agent".into()),
                    folder_id: None,
                }),
                "",
                cx,
            )
        });
        cx.run_until_parked();
        store.read_with(cx, |s, _| {
            assert_eq!(s.selected_model().map(|m| m.id.as_str()), Some("k"));
            assert_eq!(
                s.chat_agent(),
                Some((agent.to_string(), "Codex · gpt-test".to_string()))
            );
        });
    }

    /// Chat B shows Kestrel; another composer picks a coding agent (the
    /// account's selection) before B's list is read again: B's turn still
    /// names Kestrel, the model it shows, never the account's selection.
    #[gpui_kit::test]
    fn every_send_names_the_model_shown(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        daemon.returns::<methods::ComposerOptions>(ComposerOptions::default());
        daemon.returns::<methods::DraftsGet>(Draft::default());
        daemon.returns::<methods::ModelsList>(ModelList {
            models: vec![model("k", "Kestrel")],
            selected_id: Some("k".into()),
            ..Default::default()
        });
        let store = store(&daemon, Arc::default(), cx);
        store.update(cx, |s, cx| {
            s.switch_draft(
                Some(DraftKey {
                    chat_id: Some("chat-b".into()),
                    folder_id: None,
                }),
                "",
                cx,
            )
        });
        cx.run_until_parked();
        store.read_with(cx, |s, _| {
            assert_eq!(s.turn_options(vec![]).model.as_deref(), Some("k"));
        });
    }

    /// A list with no regular model, while the account's selection is a
    /// coding agent this chat never picked: no model is shown, and the
    /// composer does not send (a turn naming none would go to the agent).
    #[gpui_kit::test]
    fn no_send_without_a_model_shown(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        daemon.returns::<methods::ComposerOptions>(ComposerOptions::default());
        daemon.returns::<methods::DraftsGet>(Draft::default());
        daemon.returns::<methods::ModelsList>(ModelList {
            selected_id: Some("agent:north:codex:gpt-test".into()),
            ..Default::default()
        });
        let store = store(&daemon, Arc::default(), cx);
        store.update(cx, |s, cx| {
            s.switch_draft(
                Some(DraftKey {
                    chat_id: Some("chat-b".into()),
                    folder_id: None,
                }),
                "",
                cx,
            )
        });
        cx.run_until_parked();
        store.read_with(cx, |s, _| {
            assert!(s.selected_model().is_none());
            assert!(s.names_no_model());
        });
    }

    /// Quick Ask keeps no draft but sends ordinary chats: its list is for a
    /// chat that is not temporary, so its coding agents are offered.
    #[gpui_kit::test]
    fn quick_asks_list_is_not_a_temporary_chats(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        daemon.returns::<methods::ModelsList>(ModelList::default());
        daemon.returns::<methods::ComposerOptions>(ComposerOptions::default());
        let store = store(&daemon, Arc::default(), cx);
        store.update(cx, |s, cx| {
            s.saves_without_draft = true;
            s.refresh_models(cx)
        });
        cx.run_until_parked();
        let lists = daemon.calls::<methods::ModelsList>();
        assert_eq!(lists.last().expect("a list")["temporary"], false);
    }

    /// Right after sign-in the daemon has selected nothing yet and runs the
    /// first turn with the first model offered: the composer names that
    /// model instead of asking to choose one.
    #[gpui_kit::test]
    fn with_nothing_selected_the_first_model_is_the_one_in_use(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        daemon.returns::<methods::ModelsList>(ModelList {
            models: vec![model("k", "Kestrel"), model("b", "B")],
            selected_id: None,
            ..Default::default()
        });
        daemon.returns::<methods::ComposerOptions>(ComposerOptions::default());
        let store = store(&daemon, Arc::default(), cx);
        store.update(cx, |s, cx| s.refresh_models(cx));
        cx.run_until_parked();
        store.read_with(cx, |s, _| {
            assert_eq!(s.selected_model().map(|m| m.id.as_str()), Some("k"));
        });
        // A selection the list no longer has falls back the same way.
        daemon.returns::<methods::ModelsList>(ModelList {
            models: vec![model("b", "B")],
            selected_id: Some("gone".into()),
            ..Default::default()
        });
        store.update(cx, |s, cx| s.refresh_models(cx));
        cx.run_until_parked();
        store.read_with(cx, |s, _| {
            assert_eq!(s.selected_model().map(|m| m.id.as_str()), Some("b"));
        });
    }

    /// A new chat in a folder: the folder's model, the user's pick and the
    /// settings a reasoning pick gives it belong to that draft alone.
    #[gpui_kit::test]
    fn answers_for_a_draft_never_land_on_a_later_choice(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        let list = |selected: &str| ModelList {
            models: vec![model("a", "A"), model("b", "B")],
            selected_id: Some(selected.into()),
            ..Default::default()
        };
        daemon.returns::<methods::ModelsList>(list("a"));
        daemon.returns::<methods::ModelsSelect>(list("a"));
        daemon.returns::<methods::ComposerOptions>(ComposerOptions::default());
        daemon.returns::<methods::FoldersDraftModel>(
            serde_json::from_value(serde_json::json!({"folderId": "f", "modelIds": ["b"]}))
                .unwrap(),
        );
        let store = store(&daemon, Arc::default(), cx);
        store.update(cx, |s, cx| s.refresh_models(cx));
        cx.run_until_parked();
        // The folder's model is still being looked up when A is picked.
        let lookup = daemon.hold::<methods::FoldersDraftModel>();
        let folder = DraftKey {
            chat_id: None,
            folder_id: Some("f".into()),
        };
        store.update(cx, |s, cx| {
            s.switch_draft(Some(folder.clone()), "", cx);
            s.select_model("a", cx);
        });
        drop(lookup);
        cx.run_until_parked();
        store.read_with(cx, |s, _| {
            assert_eq!(
                s.draft_model, None,
                "the folder's model came back over the pick"
            );
            // The model shown, never the folder's.
            assert_eq!(s.turn_options(vec![]).model.as_deref(), Some("a"));
        });
        // A folder model this account is not offered is not sent either.
        store.update(cx, |s, _| s.draft_model = Some("gone".into()));
        store.read_with(cx, |s, _| {
            assert_eq!(s.selected_model().map(|m| m.id.as_str()), Some("a"));
            assert_eq!(s.turn_options(vec![]).model.as_deref(), Some("a"));
        });
        // A reasoning pick answered after another chat opened.
        daemon.returns::<methods::ModelsSetReasoningEffort>(conduit_protocol::ModelOptionsDto {
            model_id: Some("a".into()),
            draft: Some(serde_json::json!({"reasoning_effort": "high"})),
            ..Default::default()
        });
        let pick = daemon.hold::<methods::ModelsSetReasoningEffort>();
        store.update(cx, |s, cx| {
            s.set_reasoning_effort("high", cx);
            s.switch_draft(
                Some(DraftKey {
                    chat_id: Some("c1".into()),
                    folder_id: None,
                }),
                "",
                cx,
            );
        });
        drop(pick);
        cx.run_until_parked();
        store.read_with(cx, |s, _| {
            assert!(
                s.draft_params.is_null(),
                "the new chat's settings came back"
            );
        });
    }

    /// Chat Settings saved on one folder's new chat are that chat's: another
    /// folder's new chat starts without them, and a temporary switch in the
    /// same folder keeps them.
    #[gpui_kit::test]
    fn a_new_chats_settings_stay_with_its_folder(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        let store = store(&daemon, Arc::default(), cx);
        let saved = serde_json::json!({"temperature": 0.3});
        let new_chat = |folder: &str| DraftKey {
            chat_id: None,
            folder_id: Some(folder.into()),
        };
        store.update(cx, |s, cx| {
            s.switch_draft(Some(new_chat("trips")), "", cx);
            s.set_draft_params(saved.clone(), cx);
            s.switch_new_chat(Some("trips".into()), true, "", cx);
        });
        store.read_with(cx, |s, _| {
            assert_eq!(
                s.turn_options(vec![]).chat_params,
                Some(saved.clone()),
                "a temporary switch in the same folder dropped them"
            );
        });
        store.update(cx, |s, cx| {
            s.switch_draft(Some(new_chat("recipes")), "", cx)
        });
        store.read_with(cx, |s, _| {
            let options = s.turn_options(vec![]);
            assert_eq!(options.folder_id.as_deref(), Some("recipes"));
            assert_eq!(
                options.chat_params, None,
                "Trips' settings went with the other folder's first message"
            );
        });
    }

    #[gpui_kit::test]
    fn a_late_first_send_forgets_only_the_settings_it_carried(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        let store = store(&daemon, Arc::default(), cx);
        let saved = serde_json::json!({"temperature": 0.4});
        store.update(cx, |s, cx| {
            s.set_draft_params(serde_json::json!({"temperature": 0.3}), cx);
            let sent = s.params_owner();
            // Saved again in the same draft while that send is out.
            s.set_draft_params(saved.clone(), cx);
            s.forget_sent_params(sent.as_ref(), cx);
            assert_eq!(
                s.draft_params, saved,
                "the later save went with the first send"
            );
        });
    }

    #[gpui_kit::test]
    fn a_late_reasoning_reply_keeps_settings_saved_since(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        daemon.returns::<methods::ModelsList>(ModelList {
            models: vec![model("a", "A")],
            selected_id: Some("a".into()),
            ..Default::default()
        });
        daemon.returns::<methods::ComposerOptions>(ComposerOptions::default());
        daemon.returns::<methods::ModelsSetReasoningEffort>(conduit_protocol::ModelOptionsDto {
            model_id: Some("a".into()),
            draft: Some(serde_json::json!({"reasoning_effort": "high"})),
            ..Default::default()
        });
        let store = store(&daemon, Arc::default(), cx);
        store.update(cx, |s, cx| s.refresh_models(cx));
        cx.run_until_parked();
        let pick = daemon.hold::<methods::ModelsSetReasoningEffort>();
        let saved = serde_json::json!({"temperature": 0.2});
        store.update(cx, |s, cx| {
            s.set_reasoning_effort("high", cx);
            // Chat Settings saved while the pick is on its way.
            s.set_draft_params(saved.clone(), cx);
        });
        drop(pick);
        cx.run_until_parked();
        store.read_with(cx, |s, _| {
            assert_eq!(
                s.draft_params, saved,
                "the pick's reply put older settings back"
            );
        });
    }

    #[gpui_kit::test]
    fn a_comparison_is_one_messages_and_never_a_temporary_chats(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        daemon.returns::<methods::ModelsList>(ModelList {
            models: vec![model("a", "A"), model("b", "B")],
            selected_id: Some("a".into()),
            ..Default::default()
        });
        daemon.returns::<methods::ComposerOptions>(ComposerOptions::default());
        let store = store(&daemon, Arc::default(), cx);
        store.update(cx, |s, cx| s.refresh_models(cx));
        cx.run_until_parked();
        store.update(cx, |s, cx| {
            s.set_compare_with(Some(model("b", "B")), cx);
            let used = s.one_shot();
            let turn = s.take_turn(vec![], cx);
            assert_eq!(turn.compare_models, ["a", "b"]);
            // A temporary chat sends one model.
            assert!(
                turn.clone()
                    .into_turn("Hi".into(), None, true)
                    .compare_models
                    .is_empty()
            );
            assert!(s.compare_with.is_none());
            // Not sent: given back with the rest.
            assert!(s.give_back(used, cx));
            assert_eq!(s.compare_with.as_ref().map(|m| m.id.as_str()), Some("b"));
            // A new draft starts without it.
            s.start_over(cx);
            assert!(s.compare_with.is_none());
        });
    }

    #[gpui_kit::test]
    fn new_quick_pill_choices_ask_for_the_options_again(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        daemon.returns::<methods::ModelsList>(ModelList {
            models: vec![model("a", "A")],
            selected_id: Some("a".into()),
            ..Default::default()
        });
        daemon.returns::<methods::ComposerOptions>(ComposerOptions::default());
        let store = store(&daemon, Arc::default(), cx);
        // Before the models are read, nothing is asked: they ask for the
        // options themselves.
        store.update(cx, |s, cx| {
            s.set_prefs(
                ComposerPrefs {
                    quick_pills: vec!["web".into()],
                    ..ComposerPrefs::default()
                },
                cx,
            )
        });
        cx.run_until_parked();
        assert!(daemon.calls::<methods::ComposerOptions>().is_empty());
        store.update(cx, |s, cx| s.refresh_models(cx));
        cx.run_until_parked();
        let asked = daemon.calls::<methods::ComposerOptions>().len();
        assert!(asked >= 1);
        // Another setting leaves the options alone; new pills ask again.
        store.update(cx, |s, cx| {
            let prefs = ComposerPrefs {
                send_on_enter: false,
                ..s.prefs.clone()
            };
            s.set_prefs(prefs, cx)
        });
        cx.run_until_parked();
        assert_eq!(daemon.calls::<methods::ComposerOptions>().len(), asked);
        store.update(cx, |s, cx| {
            let prefs = ComposerPrefs {
                quick_pills: vec!["image".into()],
                ..s.prefs.clone()
            };
            s.set_prefs(prefs, cx)
        });
        cx.run_until_parked();
        assert_eq!(daemon.calls::<methods::ComposerOptions>().len(), asked + 1);
    }

    #[gpui_kit::test]
    fn one_message_choices_clear_and_switches_follow_the_options(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        daemon.returns::<methods::ModelsList>(ModelList {
            models: vec![model("a", "A"), model("b", "B")],
            selected_id: Some("a".into()),
            ..Default::default()
        });
        daemon.returns::<methods::ComposerOptions>(ComposerOptions {
            web_search: true,
            image_generation: false,
            tools: vec![ToolSummary {
                id: "calc".into(),
                name: "Calculator".into(),
                description: None,
            }],
            ..Default::default()
        });
        daemon.returns::<methods::ModelsSelect>(ModelList {
            models: vec![model("a", "A"), model("b", "B")],
            selected_id: Some("b".into()),
            ..Default::default()
        });
        let store = store(&daemon, Arc::default(), cx);
        store.update(cx, |s, cx| s.refresh_models(cx));
        cx.run_until_parked();
        store.update(cx, |s, cx| {
            assert_eq!(s.selected_model().map(|m| m.id.as_str()), Some("a"));
            s.toggle_web_search(cx);
            s.toggle_image_generation(cx);
            s.toggle_tool("calc", cx);
            s.set_mention(Some(model("b", "B")), cx);
            s.add_knowledge(
                KnowledgeSummary {
                    id: "k".into(),
                    name: "Docs".into(),
                    description: None,
                },
                cx,
            );
            assert_eq!(s.next_model().map(|m| m.id.as_str()), Some("b"));
            let turn = s.take_turn(vec![], cx);
            assert_eq!(turn.model.as_deref(), Some("b"));
            assert!(turn.web_search && !turn.image_generation);
            assert_eq!(turn.tool_ids, vec!["calc".to_string()]);
            assert_eq!(turn.knowledge.len(), 1);
            // The `@` model and `#` knowledge were for that message only:
            // the next turn names the model shown.
            let again = s.take_turn(vec![], cx);
            assert_eq!(again.model.as_deref(), Some("a"));
            assert!(again.knowledge.is_empty() && again.web_search);
            s.select_model("b", cx);
        });
        cx.run_until_parked();
        assert_eq!(
            daemon.calls::<methods::ModelsSelect>(),
            vec![json!({"id": "b"})]
        );
        store.read_with(cx, |s, _| {
            assert_eq!(s.selected_model().map(|m| m.id.as_str()), Some("b"))
        });
    }

    /// A Hermes chat's `/` list is the connection in use now's: another
    /// connection reads its own, and the last one's answer never fills it.
    #[gpui_kit::test]
    fn another_hermes_connection_reads_its_own_commands(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        daemon.returns::<methods::DraftsGet>(Draft::default());
        let n = Arc::new(Mutex::new(0usize));
        let count = n.clone();
        daemon.on::<methods::HermesCatalog>(move |_| {
            let mut n = count.lock().unwrap();
            *n += 1;
            let name = if *n == 1 { "prune-roses" } else { "sow-beans" };
            Ok(json!({"commands": [{"name": name}]}))
        });
        let first = daemon.hold_one::<methods::HermesCatalog>(0);
        let store = store(&daemon, Arc::default(), cx);
        store.update(cx, |s, cx| {
            s.switch_draft(Some(key(Some("local:hermes_s1"))), "", cx)
        });
        cx.run_until_parked();
        store.update(cx, |s, cx| {
            s.load_prompts(Some("0a1b2c3d:1".into()), cx);
            s.load_prompts(Some("0a1b2c3d:2".into()), cx);
        });
        cx.run_until_parked();
        drop(first);
        cx.run_until_parked();
        assert_eq!(daemon.calls::<methods::HermesCatalog>().len(), 2);
        store.read_with(cx, |s, _| {
            let commands: Vec<&str> = s
                .prompts
                .iter()
                .flatten()
                .map(|p| p.command.as_str())
                .collect();
            assert_eq!(
                commands,
                vec!["/sow-beans"],
                "the last connection's commands are shown"
            );
        });
    }

    #[gpui_kit::test]
    fn an_old_accounts_answers_never_fill_the_new_ones(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        daemon.returns::<methods::PromptsList>(
            serde_json::from_value(json!({
                "prompts": [{"command": "/old-account", "title": "A"}]
            }))
            .unwrap(),
        );
        let held = daemon.hold::<methods::PromptsList>();
        let store = store(&daemon, Arc::default(), cx);
        store.update(cx, |s, cx| {
            s.code_interpreter = true;
            s.load_prompts(None, cx);
            s.reset(cx);
        });
        held.release();
        cx.run_until_parked();
        store.read_with(cx, |s, _| {
            assert!(
                s.prompts.as_ref().is_none_or(|p| p.is_empty()),
                "{:?}",
                s.prompts
            );
            assert!(!s.code_interpreter);
        });
    }

    #[gpui_kit::test]
    fn a_search_is_asked_once_typing_pauses(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        daemon.returns::<methods::ContextSearch>(ContextSuggestions::default());
        let store = store(&daemon, Arc::default(), cx);
        store.update(cx, |s, cx| {
            for q in ["c", "ca", "cat"] {
                s.search_context(q, cx);
            }
        });
        cx.executor().advance_clock(Duration::from_millis(200));
        cx.run_until_parked();
        let calls = daemon.calls::<methods::ContextSearch>();
        assert_eq!(calls.len(), 1, "{calls:?}");
        assert_eq!(calls[0]["query"], "cat");
    }

    #[test]
    fn a_price_is_not_a_skill_and_mentions_go_out_in_utf16() {
        let end = |s: &str| trigger_at(s, s.len());
        assert_eq!(end("$pla"), t(TriggerKind::Skill, 0, "pla"));
        assert_eq!(end("costs $5"), None);
        assert_eq!(end("$"), t(TriggerKind::Skill, 0, ""));
        // `ç` is two bytes and one UTF-16 unit: the core counts units.
        let text = "ça @Riley ok";
        let mentions = mentions_in(text, [(4..10, "U:u-1".to_string(), "Riley".to_string())]);
        assert_eq!(mentions.len(), 1);
        assert_eq!((mentions[0].start, mentions[0].end), (3, 9));
        assert_eq!(mentions[0].id_type, "U");
        let skill = mentions_in(
            "$Plain",
            [(0..6, "S:plain".to_string(), "Plain".to_string())],
        );
        assert_eq!(skill[0].kind, conduit_protocol::MentionKind::Skill);
        // A token id that is not a mention, or a range off the text, is left out.
        assert!(mentions_in("hi", [(0..2, "other".to_string(), "x".to_string())]).is_empty());
        assert!(mentions_in("hi", [(0..9, "U:u".to_string(), "x".to_string())]).is_empty());
        assert_eq!(
            MentionTarget::from_token_id("C:ch-1"),
            Some(MentionTarget::Channel("ch-1".into()))
        );
    }

    fn filter(id: &str) -> ToolSummary {
        ToolSummary {
            id: id.into(),
            name: id.to_uppercase(),
            description: None,
        }
    }

    #[gpui_kit::test]
    fn filters_start_from_the_models_defaults_until_one_is_picked(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        let store = store(&daemon, Arc::default(), cx);
        store.update(cx, |s, cx| {
            s.set_options(
                ComposerOptions {
                    filters: vec![filter("tidy"), filter("short")],
                    filter_defaults: vec!["tidy".into()],
                    ..Default::default()
                },
                cx,
            );
            assert_eq!(s.filter_ids.iter().collect::<Vec<_>>(), ["tidy"]);
            // Another model, another default, until the user picks.
            s.set_options(
                ComposerOptions {
                    filters: vec![filter("tidy"), filter("short")],
                    filter_defaults: vec!["short".into()],
                    ..Default::default()
                },
                cx,
            );
            assert_eq!(s.filter_ids.iter().collect::<Vec<_>>(), ["short"]);
            s.toggle_filter("tidy", cx);
            s.set_options(
                ComposerOptions {
                    filters: vec![filter("tidy")],
                    filter_defaults: vec![],
                    ..Default::default()
                },
                cx,
            );
            // Picked ones stay while offered; the rest go.
            assert_eq!(s.filter_ids.iter().collect::<Vec<_>>(), ["tidy"]);
            assert_eq!(s.take_turn(vec![], cx).filter_ids, vec!["tidy".to_string()]);
            // The interpreter: on only where offered, off always.
            s.toggle_code_interpreter(cx);
            assert!(!s.code_interpreter);
            s.set_options(
                ComposerOptions {
                    code_interpreter: true,
                    ..Default::default()
                },
                cx,
            );
            s.toggle_code_interpreter(cx);
            assert!(s.code_interpreter);
            // It stays chosen, with why, where it will not run.
            s.set_options(
                ComposerOptions {
                    code_interpreter: false,
                    code_interpreter_block: Some("unsupportedEngine".into()),
                    ..Default::default()
                },
                cx,
            );
            assert!(s.code_interpreter);
            assert_eq!(s.code_interpreter_block(), Some("unsupportedEngine"));
            s.toggle_code_interpreter(cx);
            assert!(!s.code_interpreter);
        });
    }

    fn key(chat: Option<&str>) -> DraftKey {
        DraftKey {
            chat_id: chat.map(String::from),
            folder_id: None,
        }
    }

    #[gpui_kit::test]
    fn a_draft_is_read_for_its_chat_and_kept_when_typing_stops(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        daemon.returns::<methods::DraftsGet>(Draft {
            text: "kept".into(),
            stored: true,
        });
        daemon.returns::<methods::DraftsSave>(Draft::default());
        let store = store(&daemon, Arc::default(), cx);
        let seen: Arc<Mutex<Vec<ComposerEvent>>> = Arc::default();
        let log = seen.clone();
        cx.update(|cx| {
            cx.subscribe(&store, move |_, e: &ComposerEvent, _| {
                log.lock().unwrap().push(e.clone())
            })
            .detach()
        });
        store.update(cx, |s, cx| s.switch_draft(Some(key(Some("a"))), "", cx));
        cx.run_until_parked();
        assert_eq!(
            seen.lock().unwrap().last(),
            Some(&ComposerEvent::DraftLoaded {
                key: key(Some("a")),
                text: "kept".into()
            })
        );
        // Typed: kept 400 ms after the last change, once.
        store.update(cx, |s, cx| {
            s.draft_changed("ne", cx);
            s.draft_changed("new", cx);
        });
        cx.executor().advance_clock(Duration::from_millis(500));
        cx.run_until_parked();
        let saves = daemon.calls::<methods::DraftsSave>();
        assert_eq!(saves, vec![json!({"chatId": "a", "text": "new"})]);
        // Another chat: what was typed since is kept for the chat it was
        // typed in, at once.
        store.update(cx, |s, cx| {
            s.draft_changed("newer", cx);
            s.switch_draft(Some(key(None)), "newer", cx);
        });
        let saves = daemon.calls::<methods::DraftsSave>();
        assert_eq!(saves.last(), Some(&json!({"chatId": "a", "text": "newer"})));
        cx.run_until_parked();
        // Sent: its draft goes.
        store.update(cx, |s, cx| s.clear_draft(cx));
        assert_eq!(
            daemon.calls::<methods::DraftsSave>().last(),
            Some(&json!({"text": ""}))
        );
        // A temporary chat keeps none: nothing is read or saved.
        let before = daemon.calls::<methods::DraftsGet>().len();
        store.update(cx, |s, cx| {
            s.switch_draft(None, "", cx);
            s.draft_changed("private", cx);
        });
        cx.executor().advance_clock(Duration::from_millis(500));
        cx.run_until_parked();
        assert_eq!(daemon.calls::<methods::DraftsGet>().len(), before);
    }

    #[gpui_kit::test]
    fn a_refused_upload_is_tried_again_and_an_uncertain_one_waits_for_the_user(
        cx: &mut TestAppContext,
    ) {
        let daemon = FakeDaemon::new();
        let attempts: Arc<Mutex<Vec<u32>>> = Arc::default();
        let outcome = Arc::new(Mutex::new(vec![
            Err(UploadError {
                message: "busy".into(),
                retry: Retry::Retryable,
                wait: Duration::from_secs(5),
            }),
            uploaded("f1"),
            Err(UploadError::manual("the server may have it")),
            uploaded("f2"),
        ]));
        let seen = attempts.clone();
        let upload: Uploader = Arc::new(move |req: UploadRequest| {
            seen.lock().unwrap().push(req.attempt);
            let answer = outcome.lock().unwrap().remove(0);
            Box::pin(async move { answer })
        });
        let rpc = daemon.rpc();
        let store = cx.new(|_| ComposerStore::new(rpc, Some(upload)).with_converter(None));
        let png = Image::from_bytes(ImageFormat::Png, b"\x89PNG".to_vec());
        store.update(cx, |s, cx| s.add_image(&png, cx));
        cx.run_until_parked();
        store.read_with(cx, |s, _| {
            assert_eq!(s.attachments[0].state, UploadState::Waiting);
            assert!(s.uploading(), "Send waits while it waits");
        });
        cx.executor().advance_clock(Duration::from_secs(6));
        cx.run_until_parked();
        store.read_with(cx, |s, _| {
            assert_eq!(
                s.attachments[0].state,
                UploadState::Done {
                    file_id: "f1".into()
                }
            )
        });
        assert_eq!(*attempts.lock().unwrap(), vec![1, 2]);
        // The server may hold it already: only Try Again sends it again.
        store.update(cx, |s, cx| s.add_image(&png, cx));
        cx.run_until_parked();
        let id = store.read_with(cx, |s, _| {
            let a = &s.attachments[1];
            assert!(a.can_retry());
            a.local_id
        });
        store.update(cx, |s, cx| s.retry_attachment(id, cx));
        cx.run_until_parked();
        store.read_with(cx, |s, _| {
            assert_eq!(
                s.attachments[1].state,
                UploadState::Done {
                    file_id: "f2".into()
                }
            )
        });
        assert_eq!(*attempts.lock().unwrap(), vec![1, 2, 1, 1]);
    }

    #[gpui_kit::test]
    fn a_heic_goes_up_as_a_jpeg_and_a_server_file_as_it_is(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        type Sent = Vec<(String, Option<String>, Vec<u8>)>;
        let sent: Arc<Mutex<Sent>> = Arc::default();
        let log = sent.clone();
        let upload: Uploader = Arc::new(move |req: UploadRequest| {
            log.lock().unwrap().push((
                req.name.clone(),
                req.content_type.clone(),
                req.bytes.clone(),
            ));
            Box::pin(async move { uploaded("img") })
        });
        let convert: Converter = Arc::new(|_: &Path| Ok(b"JPEG".to_vec()));
        let rpc = daemon.rpc();
        let store = cx.new(|_| ComposerStore::new(rpc, Some(upload)).with_converter(Some(convert)));
        let dir = std::env::temp_dir().join(format!("c1-heic-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let heic = dir.join("Garden.HEIC");
        std::fs::write(&heic, b"heic bytes").unwrap();
        store.update(cx, |s, cx| {
            s.set_options(
                ComposerOptions {
                    image_conversions: vec![".heic".into(), ".bmp".into()],
                    ..Default::default()
                },
                cx,
            );
            s.add_paths(std::slice::from_ref(&heic), cx);
            assert_eq!(s.attachments[0].name, "Garden.jpg");
            assert_eq!(s.attachments[0].state, UploadState::Converting);
        });
        cx.run_until_parked();
        assert_eq!(
            *sent.lock().unwrap(),
            vec![(
                "Garden.jpg".to_string(),
                Some("image/jpeg".to_string()),
                b"JPEG".to_vec()
            )]
        );
        store.update(cx, |s, cx| {
            s.add_server_file(
                &ServerFile {
                    id: "f9".into(),
                    name: "budget.csv".into(),
                    size: Some(2048),
                    content_type: None,
                    updated_at_ms: None,
                },
                cx,
            );
            // Twice is once.
            s.add_server_file(
                &ServerFile {
                    id: "f9".into(),
                    name: "budget.csv".into(),
                    size: None,
                    content_type: None,
                    updated_at_ms: None,
                },
                cx,
            );
            assert_eq!(s.attachments.len(), 2);
            assert!(s.attachments[1].server_file);
            assert_eq!(
                s.take_turn(vec![], cx).file_ids,
                vec!["img".to_string(), "f9".to_string()]
            );
        });
        assert_eq!(
            sent.lock().unwrap().len(),
            1,
            "a server file is not uploaded"
        );
    }
}
