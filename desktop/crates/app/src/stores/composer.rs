//! What the composer offers and holds, apart from its text.
//!
//! * **Models:** `models.list` (refetched on `models.changed`) and
//!   `models.select`, which the daemon keeps per account. `@` picks a model
//!   for the next message only ([`ComposerStore::mention`]).
//! * **Features:** `composer.options` says which switches the server and
//!   model allow (web search, image generation, tools); switches it does
//!   not offer are turned off.
//! * **`/` prompts:** `prompts.list` (fetched when the menu first opens) and
//!   `prompts.render`, which answers either the final text or the fields to
//!   fill in first. **`#` knowledge:** `composer.knowledge`, a moment after
//!   typing stops.
//! * **Attachments:** each file uploads through the daemon's `/upload` as
//!   soon as it is added, with its own progress; Send waits until all are
//!   done ([`ComposerStore::uploading`]).
//! * **Triggers:** [`trigger_at`] finds the `/`, `@` or `#` word being typed
//!   at the caret.
//!
//! [`ComposerStore::take_turn`] collects the turn's options and clears what
//! applies to one message only (the `@` model, `#` knowledge, attachments).

use std::collections::BTreeSet;
use std::future::Future;
use std::path::{Path, PathBuf};
use std::pin::Pin;
use std::sync::Arc;
use std::time::Duration;

use conduit_daemon::RpcError;
use conduit_protocol::{
    ChatFileDto, ComposerOptions, KnowledgeQuery, KnowledgeSummary, ModelList, ModelSummary,
    NoParams, PromptSummary, RenderPrompt, RenderedPrompt, SelectModel, UploadedFile, methods,
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
}

pub type UploadFuture = Pin<Box<dyn Future<Output = Result<UploadedFile, String>> + Send>>;

/// Uploads a file through the daemon (the app passes the HTTP client's
/// `/upload`; tests a fake).
pub type Uploader = Arc<dyn Fn(UploadRequest) -> UploadFuture + Send + Sync>;

#[derive(Clone, Debug, PartialEq)]
pub enum UploadState {
    Reading,
    Uploading { sent: u64, total: u64 },
    Done { file_id: String },
    Failed(String),
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
    /// 0–1 while uploading.
    pub fn progress(&self) -> Option<f32> {
        match self.state {
            UploadState::Reading => Some(0.),
            UploadState::Uploading { sent, total } if total > 0 => {
                Some((sent as f32 / total as f32).min(1.))
            }
            UploadState::Uploading { .. } => Some(0.),
            _ => None,
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub enum ComposerEvent {
    /// A file could not be added or uploaded.
    AttachmentFailed { name: String },
    /// `models.select` was refused.
    ModelNotSelected(String),
}

pub struct ComposerStore {
    rpc: Rpc,
    uploader: Option<Uploader>,
    pub models: Option<ModelList>,
    pub options: ComposerOptions,
    pub prompts: Option<Vec<PromptSummary>>,
    pub knowledge_results: Vec<KnowledgeSummary>,
    knowledge_query: Option<String>,
    pub attachments: Vec<Attachment>,
    pub web_search: bool,
    pub image_generation: bool,
    pub code_interpreter: bool,
    pub tool_ids: BTreeSet<String>,
    /// `@`: the model for the next message only.
    pub mention: Option<ModelSummary>,
    /// `#`: knowledge for the next message.
    pub knowledge: Vec<KnowledgeSummary>,
    next_id: u64,
    _models: Option<Task<()>>,
    _options: Option<Task<()>>,
    _knowledge: Option<Task<()>>,
}

impl EventEmitter<ComposerEvent> for ComposerStore {}

impl ComposerStore {
    pub fn new(rpc: Rpc, uploader: Option<Uploader>) -> Self {
        Self {
            rpc,
            uploader,
            models: None,
            options: ComposerOptions::default(),
            prompts: None,
            knowledge_results: vec![],
            knowledge_query: None,
            attachments: vec![],
            web_search: false,
            image_generation: false,
            code_interpreter: false,
            tool_ids: BTreeSet::new(),
            mention: None,
            knowledge: vec![],
            next_id: 0,
            _models: None,
            _options: None,
            _knowledge: None,
        }
    }

    // ── Models and options ──────────────────────────────────────────────

    /// The model new turns use: the account's selection, else the first
    /// model offered, which is what the daemon runs a turn with when none
    /// is selected (right after sign-in nothing is, until the first send).
    /// The composer shows that model rather than "Choose a model".
    pub fn selected_model(&self) -> Option<&ModelSummary> {
        let list = self.models.as_ref()?;
        list.selected_id
            .as_deref()
            .and_then(|id| list.models.iter().find(|m| m.id == id))
            .or_else(|| list.models.first())
    }

    /// The model the next message goes to: the `@` one, else the selected.
    pub fn next_model(&self) -> Option<&ModelSummary> {
        self.mention.as_ref().or_else(|| self.selected_model())
    }

    /// `models.list`, then `composer.options` (which depends on it).
    pub fn refresh_models(&mut self, cx: &mut Context<Self>) {
        let call = self.rpc.call::<methods::ModelsList>(&NoParams);
        self._models = Some(
            cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
                let result = call.await;
                let _ = this.update(cx, |s, cx| match result {
                    Ok(list) => {
                        s.set_models(list, cx);
                        s.refresh_options(cx);
                    }
                    Err(e) => log::info!("models.list: {e}"),
                });
            }),
        );
    }

    fn set_models(&mut self, list: ModelList, cx: &mut Context<Self>) {
        // An `@` model that is no longer offered is dropped.
        if let Some(m) = &self.mention
            && !list.models.iter().any(|o| o.id == m.id)
        {
            self.mention = None;
        }
        self.models = Some(list);
        cx.notify();
    }

    /// `models.select`: the daemon keeps it with the account.
    pub fn select_model(&mut self, id: &str, cx: &mut Context<Self>) {
        // Shown at once; the daemon's answer replaces it.
        if let Some(list) = &mut self.models {
            list.selected_id = Some(id.to_string());
        }
        cx.notify();
        let call = self
            .rpc
            .call::<methods::ModelsSelect>(&SelectModel { id: id.to_string() });
        self._models = Some(
            cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
                let result = call.await;
                let _ = this.update(cx, |s, cx| match result {
                    Ok(list) => {
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

    /// `composer.options`; switches it no longer offers go off.
    pub fn refresh_options(&mut self, cx: &mut Context<Self>) {
        let call = self.rpc.call::<methods::ComposerOptions>(&NoParams);
        self._options = Some(
            cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
                if let Ok(options) = call.await {
                    let _ = this.update(cx, |s, cx| s.set_options(options, cx));
                }
            }),
        );
    }

    fn set_options(&mut self, options: ComposerOptions, cx: &mut Context<Self>) {
        self.web_search &= options.web_search;
        self.image_generation &= options.image_generation;
        let offered: BTreeSet<&str> = options
            .tools
            .iter()
            .chain(&options.mcp_tools)
            .map(|t| t.id.as_str())
            .collect();
        self.tool_ids.retain(|id| offered.contains(id.as_str()));
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

    pub fn set_mention(&mut self, model: Option<ModelSummary>, cx: &mut Context<Self>) {
        self.mention = model;
        cx.notify();
    }

    // ── Prompts and knowledge ───────────────────────────────────────────

    /// `prompts.list`, once (and again after `reset`).
    pub fn load_prompts(&mut self, cx: &mut Context<Self>) {
        if self.prompts.is_some() {
            return;
        }
        self.prompts = Some(vec![]);
        let call = self.rpc.call::<methods::PromptsList>(&NoParams);
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result = call.await;
            let _ = this.update(cx, |s, cx| {
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
    pub fn render_prompt(
        &self,
        request: RenderPrompt,
        cx: &mut Context<Self>,
    ) -> Task<Result<RenderedPrompt, RpcError>> {
        let call = self.rpc.call::<methods::PromptsRender>(&request);
        cx.background_spawn(call)
    }

    /// `composer.knowledge` for `query`, 150 ms after it last changed.
    pub fn search_knowledge(&mut self, query: &str, cx: &mut Context<Self>) {
        if self.knowledge_query.as_deref() == Some(query) {
            return;
        }
        self.knowledge_query = Some(query.to_string());
        let call = self
            .rpc
            .call::<methods::ComposerKnowledge>(&KnowledgeQuery {
                query: query.to_string(),
            });
        self._knowledge = Some(
            cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
                cx.background_executor()
                    .timer(Duration::from_millis(150))
                    .await;
                let result = call.await;
                let _ = this.update(cx, |s, cx| {
                    s.knowledge_results = result.map(|l| l.items).unwrap_or_default();
                    cx.notify();
                });
            }),
        );
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

    /// Adds files by path: each is read and uploaded on its own.
    pub fn add_paths(&mut self, paths: &[PathBuf], cx: &mut Context<Self>) {
        for path in paths {
            let name = path
                .file_name()
                .map(|n| n.to_string_lossy().to_string())
                .unwrap_or_else(|| "file".into());
            let size = std::fs::metadata(path).map(|m| m.len()).unwrap_or(0);
            let id = self.push(name.clone(), size, content_type_for(&name));
            if path.is_dir() {
                self.fail(id, "a folder cannot be attached".into(), cx);
                continue;
            }
            if size > MAX_ATTACHMENT_BYTES {
                self.fail(id, "larger than 256 MB".into(), cx);
                continue;
            }
            let path = path.clone();
            let read = cx
                .background_executor()
                .spawn(async move { std::fs::read(&path).map_err(|e| e.to_string()) });
            cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
                let bytes = read.await;
                let _ = this.update(cx, |s, cx| match bytes {
                    Ok(bytes) => s.upload(id, bytes, cx),
                    Err(e) => s.fail(id, e, cx),
                });
            })
            .detach();
        }
        cx.notify();
    }

    /// Adds an image from the clipboard.
    pub fn add_image(&mut self, image: &Image, cx: &mut Context<Self>) {
        let ext = extension_for(image.format);
        let name = format!("Pasted image.{ext}");
        let bytes = image.bytes.clone();
        let id = self.push(
            name,
            bytes.len() as u64,
            Some(mime_for(image.format).into()),
        );
        self.upload(id, bytes, cx);
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
        });
        id
    }

    fn get(&mut self, id: u64) -> Option<&mut Attachment> {
        self.attachments.iter_mut().find(|a| a.local_id == id)
    }

    fn fail(&mut self, id: u64, error: String, cx: &mut Context<Self>) {
        if let Some(a) = self.get(id) {
            log::warn!("attachment {}: {error}", a.name);
            let name = a.name.clone();
            a.state = UploadState::Failed(error);
            cx.emit(ComposerEvent::AttachmentFailed { name });
        }
        cx.notify();
    }

    fn upload(&mut self, id: u64, bytes: Vec<u8>, cx: &mut Context<Self>) {
        let Some(uploader) = self.uploader.clone() else {
            self.fail(id, "the daemon is not running".into(), cx);
            return;
        };
        let Some(a) = self.get(id) else {
            return; // removed while reading
        };
        let total = bytes.len() as u64;
        a.size = total;
        a.state = UploadState::Uploading { sent: 0, total };
        if a.content_type
            .as_deref()
            .is_some_and(|t| t.starts_with("image/"))
            && let Some(format) = a.content_type.as_deref().and_then(format_for_mime)
        {
            a.image = Some(Arc::new(Image::from_bytes(format, bytes.clone())));
        }
        let request_name = a.name.clone();
        let content_type = a.content_type.clone();
        let (tx, mut rx) = futures::channel::mpsc::unbounded::<(u64, u64)>();
        let progress: Progress = Arc::new(move |sent, total| {
            let _ = tx.unbounded_send((sent, total));
        });
        let future = uploader(UploadRequest {
            name: request_name,
            content_type,
            bytes,
            progress,
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
                        a.state = UploadState::Done { file_id: file.id };
                    }
                    cx.notify();
                }
                Err(e) => s.fail(id, e, cx),
            });
        })
        .detach();
        cx.notify();
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
                UploadState::Reading | UploadState::Uploading { .. }
            )
        })
    }

    /// Something to send besides text.
    pub fn has_attachments(&self) -> bool {
        self.attachments
            .iter()
            .any(|a| matches!(a.state, UploadState::Done { .. }))
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

    /// The options for the next turn. Clears what applies to one message.
    pub fn take_turn(&mut self, cx: &mut Context<Self>) -> TurnOptions {
        let options = TurnOptions {
            model: self.mention.take().map(|m| m.id),
            tool_ids: self.tool_ids.iter().cloned().collect(),
            knowledge: std::mem::take(&mut self.knowledge),
            web_search: self.web_search,
            image_generation: self.image_generation,
            code_interpreter: self.code_interpreter,
            file_ids: self
                .attachments
                .iter()
                .filter_map(|a| match &a.state {
                    UploadState::Done { file_id } => Some(file_id.clone()),
                    _ => None,
                })
                .collect(),
        };
        self.attachments.clear();
        cx.notify();
        options
    }

    /// Another account: start over.
    pub fn reset(&mut self, cx: &mut Context<Self>) {
        self.models = None;
        self.options = ComposerOptions::default();
        self.prompts = None;
        self.knowledge_results.clear();
        self.knowledge_query = None;
        self.attachments.clear();
        self.mention = None;
        self.knowledge.clear();
        self.tool_ids.clear();
        self.web_search = false;
        self.image_generation = false;
        self.refresh_models(cx);
    }
}

// ── Triggers ───────────────────────────────────────────────────────────────

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TriggerKind {
    /// `/prompt`
    Prompt,
    /// `@model`
    Model,
    /// `#knowledge`
    Knowledge,
}

/// A `/`, `@` or `#` word being typed at the caret.
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
        _ => return None,
    };
    let rest = chars.as_str();
    let sigil = word.chars().next()?;
    if rest.contains(sigil) {
        return None;
    }
    Some(Trigger {
        kind,
        start,
        query: rest.to_lowercase(),
    })
}

/// How a model is named on screen: with its direct connection, when it
/// comes from one.
pub fn model_label(model: &ModelSummary) -> String {
    match &model.connection {
        Some(c) => format!("{} \u{b7} {c}", model.name),
        None => model.name.clone(),
    }
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
    use std::sync::Mutex;

    use conduit_protocol::{ToolSummary, UploadedFile};
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
    fn uploader(outcome: Arc<Mutex<Vec<Result<UploadedFile, String>>>>) -> Uploader {
        Arc::new(move |req: UploadRequest| {
            let total = req.bytes.len() as u64;
            (req.progress)(total / 2, total);
            let answer = outcome.lock().unwrap().remove(0);
            Box::pin(async move { answer })
        })
    }

    fn uploaded(id: &str) -> Result<UploadedFile, String> {
        Ok(UploadedFile {
            id: id.into(),
            name: "x".into(),
            size: 1,
            content_type: None,
        })
    }

    fn store(
        daemon: &FakeDaemon,
        outcome: Arc<Mutex<Vec<Result<UploadedFile, String>>>>,
        cx: &mut TestAppContext,
    ) -> Entity<ComposerStore> {
        let rpc = daemon.rpc();
        cx.new(|_| ComposerStore::new(rpc, Some(uploader(outcome))))
    }

    #[gpui_kit::test]
    fn attachments_upload_on_their_own_and_send_waits_for_them(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        let outcome = Arc::new(Mutex::new(vec![
            uploaded("f1"),
            Err("too big for the server".into()),
        ]));
        let store = store(&daemon, outcome, cx);
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
            assert!(matches!(s.attachments[1].state, UploadState::Failed(_)));
            assert_eq!(s.pending_files().len(), 1);
            // The failed one is removed by the user; the turn takes the rest.
            let failed = s.attachments[1].local_id;
            s.remove_attachment(failed, cx);
            let turn = s.take_turn(cx);
            assert_eq!(turn.file_ids, vec!["f1".to_string()]);
            assert!(s.attachments.is_empty());
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

    /// Right after sign-in the daemon has selected nothing yet and runs the
    /// first turn with the first model offered: the composer names that
    /// model instead of asking to choose one.
    #[gpui_kit::test]
    fn with_nothing_selected_the_first_model_is_the_one_in_use(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        daemon.returns::<methods::ModelsList>(ModelList {
            models: vec![model("k", "Kestrel"), model("b", "B")],
            selected_id: None,
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
        });
        store.update(cx, |s, cx| s.refresh_models(cx));
        cx.run_until_parked();
        store.read_with(cx, |s, _| {
            assert_eq!(s.selected_model().map(|m| m.id.as_str()), Some("b"));
        });
    }

    #[gpui_kit::test]
    fn one_message_choices_clear_and_switches_follow_the_options(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        daemon.returns::<methods::ModelsList>(ModelList {
            models: vec![model("a", "A"), model("b", "B")],
            selected_id: Some("a".into()),
        });
        daemon.returns::<methods::ComposerOptions>(ComposerOptions {
            web_search: true,
            image_generation: false,
            tools: vec![ToolSummary {
                id: "calc".into(),
                name: "Calculator".into(),
                description: None,
            }],
            mcp_tools: vec![],
        });
        daemon.returns::<methods::ModelsSelect>(ModelList {
            models: vec![model("a", "A"), model("b", "B")],
            selected_id: Some("b".into()),
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
            let turn = s.take_turn(cx);
            assert_eq!(turn.model.as_deref(), Some("b"));
            assert!(turn.web_search && !turn.image_generation);
            assert_eq!(turn.tool_ids, vec!["calc".to_string()]);
            assert_eq!(turn.knowledge.len(), 1);
            // The `@` model and `#` knowledge were for that message only.
            let again = s.take_turn(cx);
            assert_eq!(again.model, None);
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
}
