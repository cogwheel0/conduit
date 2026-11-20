//! The model editor: a custom model over a base model, as the phone's
//! model editor and Open WebUI's own. Its profile image, name and id, the
//! base model, description and tags; the system prompt and suggested
//! prompts; capabilities and the features a new chat starts with; the
//! knowledge, tools, skills, filters and actions it brings (each chosen in
//! a sheet); and the advanced parameters, stop sequences, terminal, voice
//! and built-in tools (a JSON object, as the phone edits them). Keys
//! the editor does not show are kept by the daemon, which saves over the
//! model as the server has it.

use std::collections::BTreeMap;
use std::rc::Rc;
use std::sync::Arc;

use base64::Engine as _;
use conduit_components::ActiveConduitTheme as _;
use conduit_components::assets::IconName;
use conduit_components::views::kit::{Button, IconButton, Switch, grouped_section};
use conduit_protocol::{
    NoticeLevel, WorkspaceDetail, WorkspaceImageSource, WorkspaceKind, WorkspaceModelDto,
    WorkspaceModelOptions, WorkspaceRef, WorkspaceRelation, WorkspaceSave, WorkspaceSectionAccess,
    methods,
};
use gpui_kit::component::input::{InputEvent, InputState, Textarea, TextareaState};
use gpui_kit::prelude::*;
use gpui_kit::{
    AnyElement, App, AsyncApp, Context, ElementId, Entity, EventEmitter, FontWeight, Image,
    ImageFormat, PathPromptOptions, Role, SharedString, Subscription, Task, WeakEntity, Window,
    div, img, px, relative,
};

use super::editor::{self, EditorEvent, Frame, ItemEditor};
use super::{WorkspacePane, prompt::command_from_name};
use crate::actions::SettingsChoice;
use crate::l10n::{ActiveL10n as _, L10n};
use crate::stores::Stores;
use crate::stores::media;
use crate::stores::navigation::WorkspaceSection;
use crate::stores::rpc::Rpc;
use crate::views::forms;
use crate::views::settings::controls::{self, Choice};
use crate::views::sheet::{self, SheetBody};

/// Open WebUI's model capabilities, in its editor's order.
pub const CAPABILITIES: [&str; 7] = [
    "vision",
    "file_upload",
    "web_search",
    "image_generation",
    "code_interpreter",
    "citations",
    "usage",
];

/// The features a new chat with the model can start with.
pub const DEFAULT_FEATURES: [&str; 3] = ["web_search", "image_generation", "code_interpreter"];

/// The biggest profile image the editor sends (the server stores it in
/// the model's record).
const MAX_IMAGE_BYTES: usize = 1024 * 1024;

fn capability_label(key: &str, l: &L10n) -> String {
    match key {
        "vision" => l.desktop_workspace_capability_vision(),
        "file_upload" => l.desktop_workspace_capability_file_upload(),
        "web_search" => l.web_search(),
        "image_generation" => l.image_generation(),
        "code_interpreter" => l.code_interpreter(),
        "citations" => l.desktop_workspace_capability_citations(),
        "usage" => l.desktop_workspace_capability_usage(),
        other => other.to_string(),
    }
}

/// The relationships a model has, each chosen in a sheet.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Relation {
    Knowledge,
    Tools,
    Skills,
    Filters,
    DefaultFilters,
    Actions,
}

impl Relation {
    pub const ALL: [Self; 6] = [
        Self::Knowledge,
        Self::Tools,
        Self::Skills,
        Self::Filters,
        Self::DefaultFilters,
        Self::Actions,
    ];

    fn label(self, l: &L10n) -> String {
        match self {
            Self::Knowledge => l.desktop_workspace_model_knowledge(),
            Self::Tools => l.desktop_workspace_model_tools(),
            Self::Skills => l.desktop_workspace_model_skills(),
            Self::Filters => l.desktop_workspace_model_filters(),
            Self::DefaultFilters => l.workspace_model_default_filters(),
            Self::Actions => l.desktop_workspace_model_actions(),
        }
    }

    fn id(self) -> &'static str {
        match self {
            Self::Knowledge => "knowledge",
            Self::Tools => "tools",
            Self::Skills => "skills",
            Self::Filters => "filters",
            Self::DefaultFilters => "default-filters",
            Self::Actions => "actions",
        }
    }

    fn options(self, o: &WorkspaceModelOptions) -> Vec<WorkspaceRelation> {
        match self {
            Self::Knowledge => o.knowledge.clone(),
            Self::Tools => o.tools.clone(),
            Self::Skills => o.skills.clone(),
            Self::Filters | Self::DefaultFilters => o.filters.clone(),
            Self::Actions => o.actions.clone(),
        }
    }

    fn selected(self, m: &WorkspaceModelDto) -> Vec<String> {
        match self {
            Self::Knowledge => m.knowledge.iter().map(|k| k.id.clone()).collect(),
            Self::Tools => m.tool_ids.clone(),
            Self::Skills => m.skill_ids.clone(),
            Self::Filters => m.filter_ids.clone(),
            Self::DefaultFilters => m.default_filter_ids.clone(),
            Self::Actions => m.action_ids.clone(),
        }
    }

    fn set(self, m: &mut WorkspaceModelDto, ids: Vec<String>, options: &[WorkspaceRelation]) {
        match self {
            Self::Knowledge => {
                m.knowledge = ids
                    .into_iter()
                    .map(|id| {
                        m.knowledge
                            .iter()
                            .chain(options.iter())
                            .find(|k| k.id == id)
                            .cloned()
                            .unwrap_or(WorkspaceRelation {
                                id,
                                name: String::new(),
                                subtitle: None,
                            })
                    })
                    .collect()
            }
            Self::Tools => m.tool_ids = ids,
            Self::Skills => m.skill_ids = ids,
            Self::Filters => m.filter_ids = ids,
            Self::DefaultFilters => m.default_filter_ids = ids,
            Self::Actions => m.action_ids = ids,
        }
    }
}

/// A new model: nothing but a base, active and shown.
fn blank_model() -> WorkspaceModelDto {
    WorkspaceModelDto {
        id: String::new(),
        name: String::new(),
        base_model_id: None,
        description: String::new(),
        image_url: None,
        image_source: WorkspaceImageSource::Server,
        tags: vec![],
        system: String::new(),
        stop: vec![],
        suggestion_prompts: vec![],
        capabilities: BTreeMap::new(),
        knowledge: vec![],
        tool_ids: vec![],
        skill_ids: vec![],
        filter_ids: vec![],
        default_filter_ids: vec![],
        action_ids: vec![],
        default_feature_ids: vec![],
        tts_voice: String::new(),
        terminal_id: String::new(),
        builtin_tools: serde_json::Value::Object(Default::default()),
        active: true,
        hidden: false,
        params: serde_json::Value::Object(Default::default()),
    }
}

/// The parameters as the text area shows them (pretty JSON; empty for
/// none).
pub fn params_text(params: &serde_json::Value) -> String {
    match params {
        serde_json::Value::Object(map) if map.is_empty() => String::new(),
        serde_json::Value::Null => String::new(),
        other => serde_json::to_string_pretty(other).unwrap_or_default(),
    }
}

/// The text area's parameters: a JSON object, or nothing.
pub fn parse_params(text: &str) -> Option<serde_json::Value> {
    let t = text.trim();
    if t.is_empty() {
        return Some(serde_json::Value::Object(Default::default()));
    }
    match serde_json::from_str::<serde_json::Value>(t) {
        Ok(v @ serde_json::Value::Object(_)) => Some(v),
        _ => None,
    }
}

/// An image in a `data:` URL, decoded to show.
pub fn data_url_image(url: &str) -> Option<Arc<Image>> {
    let rest = url.strip_prefix("data:")?;
    let (meta, data) = rest.split_once(',')?;
    let mime = meta.strip_suffix(";base64")?;
    let format = match mime {
        "image/png" => ImageFormat::Png,
        "image/jpeg" | "image/jpg" => ImageFormat::Jpeg,
        "image/gif" => ImageFormat::Gif,
        "image/webp" => ImageFormat::Webp,
        _ => return None,
    };
    let bytes = base64::engine::general_purpose::STANDARD
        .decode(data)
        .ok()?;
    Some(Arc::new(Image::from_bytes(format, bytes)))
}

/// The form's errors, by field: none until the first save, then each
/// field's own.
#[derive(Debug, Default, PartialEq)]
struct FieldErrors {
    name: Option<String>,
    id: Option<String>,
    base: Option<String>,
    params: Option<String>,
    builtin_tools: Option<String>,
}

/// What a capability or feature checkbox does to the model.
type FlagToggle = Rc<dyn Fn(&mut ModelEditor, &mut Context<ModelEditor>)>;

pub struct ModelEditor {
    stores: Stores,
    rpc: Rpc,
    pane: WeakEntity<WorkspacePane>,
    id: Option<String>,
    access: WorkspaceSectionAccess,
    pub detail: Option<WorkspaceDetail>,
    /// What the form holds beyond its text fields.
    pub model: WorkspaceModelDto,
    initial: WorkspaceModelDto,
    initial_params: String,
    initial_builtin: String,
    options: Option<WorkspaceModelOptions>,
    name: Entity<InputState>,
    model_id: Entity<InputState>,
    description: Entity<InputState>,
    tags: Entity<InputState>,
    system: Entity<TextareaState>,
    params: Entity<TextareaState>,
    stop: Entity<InputState>,
    terminal: Entity<InputState>,
    voice: Entity<InputState>,
    builtin_tools: Entity<TextareaState>,
    suggestions: Vec<Entity<InputState>>,
    /// A picture drawn here: picked, or kept in the model as a `data:` URL.
    image: Option<Arc<Image>>,
    /// The picture was removed here (not saved yet): the server's is not
    /// shown either.
    image_removed: bool,
    /// The body's scroll position (the E2E brings Advanced into view).
    pub scroll: gpui_kit::ScrollHandle,
    /// The last frame drew a picture, not the initial (the E2E pass).
    drew_picture: std::cell::Cell<bool>,
    id_typed: bool,
    submitted: bool,
    saving: bool,
    loading: bool,
    failure: Option<String>,
    _subscriptions: Vec<Subscription>,
    _load: Option<Task<()>>,
    _options: Option<Task<()>>,
}

impl EventEmitter<EditorEvent> for ModelEditor {}

impl ModelEditor {
    pub fn new(
        stores: Stores,
        pane: WeakEntity<WorkspacePane>,
        id: Option<String>,
        access: WorkspaceSectionAccess,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Self {
        let rpc = stores.connection.read(cx).rpc();
        let l = cx.l10n().clone();
        let name = forms::input(l.desktop_workspace_model_name(), false, window, cx);
        let model_id = forms::input("trail-guide", false, window, cx);
        let description = forms::input(l.desktop_workspace_model_description(), false, window, cx);
        let tags = forms::input(l.desktop_workspace_comma_separated(), false, window, cx);
        let stop = forms::input(l.desktop_workspace_model_stop_hint(), false, window, cx);
        let terminal = forms::input("", false, window, cx);
        let voice = forms::input("", false, window, cx);
        let builtin_tools = cx.new(|cx| {
            TextareaState::new(window, cx)
                .auto_grow(3, 12)
                .placeholder("{ \"memory\": false }")
        });
        let system = cx.new(|cx| {
            TextareaState::new(window, cx)
                .auto_grow(4, 16)
                .placeholder(l.enter_system_prompt())
        });
        let params = cx.new(|cx| {
            TextareaState::new(window, cx)
                .auto_grow(3, 12)
                .placeholder("{ \"temperature\": 0.7 }")
        });
        let mut subscriptions = vec![
            cx.subscribe_in(&name, window, |this, state, e: &InputEvent, window, cx| {
                if matches!(e, InputEvent::Change) {
                    if this.id.is_none() && !this.id_typed {
                        let slug = command_from_name(&state.read(cx).value());
                        this.model_id
                            .update(cx, |s, cx| s.set_value(slug, window, cx));
                    }
                    this.failure = None;
                    cx.notify();
                }
            }),
            cx.subscribe_in(&model_id, window, |this, _, e: &InputEvent, _, cx| {
                if matches!(e, InputEvent::Change) {
                    this.id_typed = true;
                    cx.notify();
                }
            }),
        ];
        for state in [&description, &tags, &stop, &terminal, &voice] {
            subscriptions.push(
                cx.subscribe_in(state, window, |_, _, e: &InputEvent, _, cx| {
                    if matches!(e, InputEvent::Change) {
                        cx.notify();
                    }
                }),
            );
        }
        for state in [&system, &params, &builtin_tools] {
            subscriptions.push(
                cx.subscribe_in(state, window, |this, _, e: &InputEvent, _, cx| {
                    if matches!(e, InputEvent::Change) {
                        this.failure = None;
                        cx.notify();
                    }
                }),
            );
        }
        let mut this = Self {
            stores,
            rpc,
            pane,
            id,
            access,
            detail: None,
            model: blank_model(),
            initial: blank_model(),
            initial_params: String::new(),
            initial_builtin: String::new(),
            options: None,
            name,
            model_id,
            description,
            tags,
            system,
            params,
            stop,
            terminal,
            voice,
            builtin_tools,
            suggestions: vec![],
            image: None,
            image_removed: false,
            scroll: gpui_kit::ScrollHandle::new(),
            drew_picture: std::cell::Cell::new(false),
            id_typed: false,
            submitted: false,
            saving: false,
            loading: false,
            failure: None,
            _subscriptions: subscriptions,
            _load: None,
            _options: None,
        };
        this.load_options(cx);
        if this.id.is_some() {
            this.reload(window, cx);
        }
        this
    }

    fn load_options(&mut self, cx: &mut Context<Self>) {
        let call = self
            .rpc
            .call::<methods::WorkspaceModelOptions>(&conduit_protocol::NoParams);
        self._options = Some(
            cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
                let result = call.await;
                let _ = this.update(cx, |s, cx| {
                    match result {
                        Ok(options) => {
                            // A new model starts on the first base model.
                            if s.id.is_none() && s.model.base_model_id.is_none() {
                                s.model.base_model_id =
                                    options.base_models.first().map(|b| b.id.clone());
                                s.initial.base_model_id = s.model.base_model_id.clone();
                            }
                            s.options = Some(options);
                        }
                        Err(e) => log::warn!("workspace.modelOptions: {e}"),
                    }
                    cx.notify();
                });
            }),
        );
    }

    /// Where the saved model's picture is on its server, when the window
    /// loads it from there: the model is saved, keeps no `data:` picture
    /// and none on another site.
    fn server_picture(
        &self,
        m: &WorkspaceModelDto,
        cx: &App,
    ) -> Option<crate::stores::files::ModelImageRef> {
        if m.id.is_empty() || m.image_source != WorkspaceImageSource::Server {
            return None;
        }
        let server_id = self
            .stores
            .accounts
            .read(cx)
            .active()
            .map(|a| a.connection.id.clone())?;
        Some(crate::stores::files::ModelImageRef {
            server_id,
            model_id: m.id.clone(),
        })
    }

    /// The picture the editor shows: one drawn here, else the server's
    /// once loaded, else one on another site once the user lets it load;
    /// None for the model's initial.
    fn picture(&self, window: &mut Window, cx: &mut App) -> Option<gpui_kit::ImageSource> {
        if let Some(image) = &self.image {
            return Some(gpui_kit::ImageSource::Image(image.clone()));
        }
        if self.image_removed {
            return None;
        }
        if let Some((url, host)) = self.remote_picture(cx) {
            if !media::may_load(&url, &host, cx) {
                return None;
            }
            return match media::image_state(&url, window, cx)? {
                Ok(loaded) => Some(gpui_kit::ImageSource::Render(loaded.render)),
                Err(_) => None,
            };
        }
        // The server's: only for a model it has.
        self.id.as_ref()?;
        let picture = self.server_picture(&self.model, cx)?;
        match crate::stores::files::model_image_state(&picture, window, cx)? {
            Ok(image) => Some(gpui_kit::ImageSource::Render(image)),
            Err(_) => None,
        }
    }

    /// A picture on another site ([`WorkspaceImageSource::Remote`]): its
    /// address and host. It follows an answer's pictures' rule
    /// ([`media::classify`]): fetching it tells that site the user opened
    /// the model, so it loads only after Load Image (until the app quits)
    /// or while its host is in Settings › Chats › Remote Content, and then
    /// through the daemon's anonymous `/media/image`.
    fn remote_picture(&self, cx: &App) -> Option<(String, String)> {
        if self.image.is_some()
            || self.image_removed
            || self.model.image_source != WorkspaceImageSource::Remote
        {
            return None;
        }
        let raw = self.model.image_url.as_deref()?;
        match media::classify(raw, media::ServerOrigin::active(cx).as_ref()) {
            media::LinkTarget::Remote { url, host } => Some((url, host)),
            _ => None,
        }
    }

    /// Whether the model has a picture on another site that has not been
    /// let load: the E2E pass.
    pub fn remote_picture_waits(&self, cx: &App) -> Option<String> {
        self.remote_picture(cx)
            .filter(|(url, host)| !media::may_load(url, host, cx))
            .map(|(_, host)| host)
    }

    /// The built-in tools field's error, once a save was tried: the E2E
    /// pass.
    pub fn builtin_tools_error(&self, cx: &App) -> Option<String> {
        let l = cx.l10n().clone();
        self.errors(false, &l, cx).builtin_tools
    }

    /// Whether the last frame drew a picture (not the initial): the E2E
    /// pass. (The picture itself loads only while drawing.)
    pub fn shows_picture(&self) -> bool {
        self.drew_picture.get()
    }

    fn writable(&self) -> bool {
        self.access.manage && self.detail.as_ref().is_none_or(|d| d.write_access)
    }

    /// The model as the form holds it now, with the text of its two JSON
    /// fields (the parameters, the built-in tools).
    fn form(&self, cx: &App) -> (WorkspaceModelDto, String, String) {
        let mut m = self.model.clone();
        m.name = self.name.read(cx).value().trim().to_string();
        m.id = self.model_id.read(cx).value().trim().to_string();
        m.description = self.description.read(cx).value().trim().to_string();
        m.tags = editor::split_list(&self.tags.read(cx).value());
        m.system = self.system.read(cx).value().to_string();
        m.stop = editor::split_list(&self.stop.read(cx).value());
        m.terminal_id = self.terminal.read(cx).value().trim().to_string();
        m.tts_voice = self.voice.read(cx).value().trim().to_string();
        m.suggestion_prompts = self
            .suggestions
            .iter()
            .map(|s| s.read(cx).value().trim().to_string())
            .filter(|s| !s.is_empty())
            .collect();
        (
            m,
            self.params.read(cx).value().to_string(),
            self.builtin_tools.read(cx).value().to_string(),
        )
    }

    fn set_suggestions(&mut self, prompts: &[String], window: &mut Window, cx: &mut Context<Self>) {
        self.suggestions = prompts
            .iter()
            .map(|p| {
                let s = forms::input("", false, window, cx);
                s.update(cx, |s, cx| s.set_value(p.clone(), window, cx));
                s
            })
            .collect();
        let subs: Vec<Subscription> = self
            .suggestions
            .iter()
            .map(|s| {
                cx.subscribe_in(s, window, |_, _, e: &InputEvent, _, cx| {
                    if matches!(e, InputEvent::Change) {
                        cx.notify();
                    }
                })
            })
            .collect();
        self._subscriptions.extend(subs);
    }

    /// A save answered while the form had changed since it was sent: the
    /// saved model is the item now (its id, its detail, what counts as
    /// unchanged), and the form keeps what was typed since.
    fn saved_under_edits(
        &mut self,
        detail: WorkspaceDetail,
        mut sent: (WorkspaceModelDto, String, String),
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let Some(m) = detail.model.as_ref() else {
            return;
        };
        // Made: its id is the one it was made with, whatever the field
        // holds now, so the next Save updates this model.
        let id = m.id.clone();
        self.model_id
            .update(cx, |s, cx| s.set_value(id.clone(), window, cx));
        sent.0.id = id.clone();
        self.id = Some(id);
        self.detail = Some(detail);
        (self.initial, self.initial_params, self.initial_builtin) = sent;
        self.id_typed = true;
        self.submitted = false;
    }

    fn adopt(&mut self, detail: WorkspaceDetail, window: &mut Window, cx: &mut Context<Self>) {
        let Some(m) = detail.model.clone() else {
            return;
        };
        self.id = Some(m.id.clone());
        self.name
            .update(cx, |s, cx| s.set_value(m.name.clone(), window, cx));
        self.model_id
            .update(cx, |s, cx| s.set_value(m.id.clone(), window, cx));
        self.description
            .update(cx, |s, cx| s.set_value(m.description.clone(), window, cx));
        self.tags
            .update(cx, |s, cx| s.set_value(m.tags.join(", "), window, cx));
        self.system
            .update(cx, |s, cx| s.set_value(m.system.clone(), window, cx));
        self.stop
            .update(cx, |s, cx| s.set_value(m.stop.join(", "), window, cx));
        self.terminal
            .update(cx, |s, cx| s.set_value(m.terminal_id.clone(), window, cx));
        self.voice
            .update(cx, |s, cx| s.set_value(m.tts_voice.clone(), window, cx));
        let params = params_text(&m.params);
        self.params
            .update(cx, |s, cx| s.set_value(params.clone(), window, cx));
        let builtin = params_text(&m.builtin_tools);
        self.builtin_tools
            .update(cx, |s, cx| s.set_value(builtin, window, cx));
        self.set_suggestions(&m.suggestion_prompts, window, cx);
        self.image = m.image_url.as_deref().and_then(data_url_image);
        self.image_removed = false;
        // The server's picture may have changed with this read or save.
        if let Some(picture) = self.server_picture(&m, cx) {
            crate::stores::files::forget_model_image(&picture, cx);
        }
        self.model = m;
        self.detail = Some(detail);
        let (form, params, builtin) = self.form(cx);
        self.initial = form;
        self.initial_params = params;
        self.initial_builtin = builtin;
        self.id_typed = true;
        self.submitted = false;
        cx.notify();
    }

    fn revert(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        match self.detail.clone() {
            Some(detail) => self.adopt(detail, window, cx),
            None => cx.emit(EditorEvent::Closed),
        }
    }

    /// The field errors: all of them with `all`, else once submitted.
    fn errors(&self, all: bool, l: &L10n, cx: &App) -> FieldErrors {
        if !all && !self.submitted {
            return FieldErrors::default();
        }
        let (m, params, builtin) = self.form(cx);
        FieldErrors {
            name: m
                .name
                .is_empty()
                .then(|| l.desktop_workspace_model_name_required()),
            id: m
                .id
                .is_empty()
                .then(|| l.desktop_workspace_model_id_required()),
            base: (self.id.is_none()
                && m.base_model_id.is_none()
                && self
                    .options
                    .as_ref()
                    .is_some_and(|o| !o.base_models.is_empty()))
            .then(|| l.workspace_model_base_model_required()),
            params: parse_params(&params)
                .is_none()
                .then(|| l.desktop_workspace_model_invalid_json()),
            builtin_tools: parse_params(&builtin)
                .is_none()
                .then(|| l.desktop_workspace_model_invalid_json()),
        }
    }

    fn valid(&self, cx: &App) -> bool {
        let l = cx.l10n().clone();
        self.errors(true, &l, cx) == FieldErrors::default()
    }

    // ── Image ──────────────────────────────────────────────────────────

    fn pick_image(&mut self, cx: &mut Context<Self>) {
        let paths = cx.prompt_for_paths(PathPromptOptions {
            files: true,
            directories: false,
            multiple: false,
            prompt: None,
        });
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let Ok(Ok(Some(mut paths))) = paths.await else {
                return;
            };
            let Some(path) = paths.pop() else {
                return;
            };
            let _ = this.update(cx, |s, cx| s.set_image_from(&path, cx));
        })
        .detach();
    }

    /// The profile image from the file at `path`, as a `data:` URL.
    pub fn set_image_from(&mut self, path: &std::path::Path, cx: &mut Context<Self>) {
        let l = cx.l10n().clone();
        let mime = match path
            .extension()
            .and_then(|e| e.to_str())
            .map(str::to_ascii_lowercase)
            .as_deref()
        {
            Some("png") => "image/png",
            Some("jpg" | "jpeg") => "image/jpeg",
            Some("gif") => "image/gif",
            Some("webp") => "image/webp",
            _ => {
                self.failure = Some(l.desktop_workspace_model_image_failed());
                cx.notify();
                return;
            }
        };
        match std::fs::read(path) {
            Ok(bytes) if bytes.len() <= MAX_IMAGE_BYTES => {
                let url = format!(
                    "data:{mime};base64,{}",
                    base64::engine::general_purpose::STANDARD.encode(&bytes)
                );
                self.image = data_url_image(&url);
                self.model.image_url = Some(url);
            }
            Ok(_) => self.failure = Some(l.desktop_workspace_image_too_large()),
            Err(_) => self.failure = Some(l.desktop_workspace_model_image_failed()),
        }
        cx.notify();
    }

    // ── Relationships ──────────────────────────────────────────────────

    fn choose(&mut self, relation: Relation, window: &mut Window, cx: &mut Context<Self>) {
        let Some(options) = self.options.as_ref().map(|o| relation.options(o)) else {
            return;
        };
        let selected = relation.selected(&self.model);
        let editor = cx.entity().downgrade();
        let title = relation.label(cx.l10n());
        sheet::open(window, 460., cx, move |_, _| RelationSheet {
            title,
            options,
            selected: selected.clone(),
            initial: selected,
            relation,
            editor,
        });
    }

    /// The sheet's choice for `relation`.
    pub fn set_relation(&mut self, relation: Relation, ids: Vec<String>, cx: &mut Context<Self>) {
        let options = self
            .options
            .as_ref()
            .map(|o| relation.options(o))
            .unwrap_or_default();
        relation.set(&mut self.model, ids, &options);
        cx.notify();
    }

    fn relation_row(&self, relation: Relation, l: &L10n, cx: &mut Context<Self>) -> AnyElement {
        let t = cx.conduit().clone();
        let selected = relation.selected(&self.model);
        let names: Vec<String> = {
            let options = self
                .options
                .as_ref()
                .map(|o| relation.options(o))
                .unwrap_or_default();
            selected
                .iter()
                .map(|id| {
                    options
                        .iter()
                        .chain(self.model.knowledge.iter())
                        .find(|o| &o.id == id && !o.name.is_empty())
                        .map(|o| o.name.clone())
                        .unwrap_or_else(|| id.clone())
                })
                .collect()
        };
        let summary = if names.is_empty() {
            l.desktop_workspace_model_select_none()
        } else {
            names.join(", ")
        };
        let writable = self.writable();
        let view = cx.entity().downgrade();
        forms::form_row(
            relation.label(l),
            div()
                .w_full()
                .flex()
                .items_center()
                .gap(px(8.))
                .child(
                    div()
                        .flex_1()
                        .min_w_0()
                        .truncate()
                        .text_size(px(t.metrics.control))
                        .text_color(t.roles.text_subtle)
                        .child(summary),
                )
                .when(writable, |d| {
                    d.child(
                        Button::new(
                            SharedString::from(format!("model-choose-{}", relation.id())),
                            l.desktop_workspace_choose(),
                        )
                        .disabled(self.options.is_none())
                        .on_click(Rc::new(move |_, window, cx| {
                            let _ = view.update(cx, |v, cx| v.choose(relation, window, cx));
                        })),
                    )
                }),
            cx,
        )
        .into_any_element()
    }

    fn flag_row(
        &self,
        id: String,
        label: String,
        on: bool,
        toggle: FlagToggle,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let view = cx.entity().downgrade();
        let writable = self.writable();
        div()
            .px(px(12.))
            .h(px(30.))
            .flex()
            .items_center()
            .gap(px(8.))
            .child(controls::checkbox(
                ElementId::Name(id.into()),
                label.clone(),
                on,
                if writable {
                    Rc::new(move |_, _, cx| {
                        let toggle = toggle.clone();
                        let _ = view.update(cx, |v, cx| toggle(v, cx));
                    })
                } else {
                    controls::noop()
                },
                window,
                cx,
            ))
            .child(label)
            .into_any_element()
    }
}

/// A sheet of checkboxes choosing a model's knowledge, tools, skills,
/// filters or actions.
pub struct RelationSheet {
    title: String,
    options: Vec<WorkspaceRelation>,
    pub selected: Vec<String>,
    initial: Vec<String>,
    relation: Relation,
    editor: WeakEntity<ModelEditor>,
}

impl RelationSheet {
    /// Ticks or unticks option `id`.
    pub fn toggle(&mut self, id: &str, cx: &mut Context<Self>) {
        if let Some(i) = self.selected.iter().position(|s| s == id) {
            self.selected.remove(i);
        } else {
            self.selected.push(id.to_string());
        }
        cx.notify();
    }

    pub fn done(&mut self, cx: &mut Context<Self>) {
        let (relation, ids) = (self.relation, self.selected.clone());
        let _ = self
            .editor
            .update(cx, |e, cx| e.set_relation(relation, ids, cx));
        sheet::dismiss(cx);
    }
}

impl SheetBody for RelationSheet {
    fn cancel(&mut self, _: &mut Window, cx: &mut Context<Self>) {
        sheet::dismiss(cx);
    }

    fn label(&self, _: &App) -> SharedString {
        self.title.clone().into()
    }

    fn footer(&mut self, _: &mut Window, cx: &mut Context<Self>) -> Option<AnyElement> {
        let l = cx.l10n().clone();
        let cancel = cx.entity().downgrade();
        let done = cx.entity().downgrade();
        Some(
            forms::form_buttons(vec![
                Button::new("relation-cancel", l.cancel())
                    .on_click(Rc::new(move |_, window, cx| {
                        let _ = cancel.update(cx, |v, cx| v.cancel(window, cx));
                    }))
                    .into_any_element(),
                Button::new("relation-done", l.desktop_done())
                    .primary()
                    .disabled(self.selected == self.initial)
                    .on_click(Rc::new(move |_, _, cx| {
                        let _ = done.update(cx, |v, cx| v.done(cx));
                    }))
                    .into_any_element(),
            ])
            .into_any_element(),
        )
    }
}

impl Render for RelationSheet {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let t = cx.conduit().clone();
        let l = cx.l10n().clone();
        let view = cx.entity().downgrade();
        let rows: Vec<AnyElement> = if self.options.is_empty() {
            vec![
                div()
                    .px(px(12.))
                    .py(px(10.))
                    .text_color(t.roles.text_subtle)
                    .child(l.desktop_workspace_model_relationship_empty())
                    .into_any_element(),
            ]
        } else {
            self.options
                .clone()
                .into_iter()
                .enumerate()
                .map(|(i, o)| {
                    let on = self.selected.contains(&o.id);
                    let view = view.clone();
                    let id = o.id.clone();
                    let name = if o.name.is_empty() {
                        o.id.clone()
                    } else {
                        o.name.clone()
                    };
                    div()
                        .px(px(12.))
                        .min_h(px(36.))
                        .flex()
                        .items_center()
                        .gap(px(10.))
                        .child(controls::checkbox(
                            ElementId::NamedInteger("relation-option".into(), i as u64),
                            name.clone(),
                            on,
                            Rc::new(move |_, _, cx| {
                                let _ = view.update(cx, |v, cx| v.toggle(&id, cx));
                            }),
                            window,
                            cx,
                        ))
                        .child(
                            div()
                                .flex_1()
                                .min_w_0()
                                .flex()
                                .flex_col()
                                .child(div().truncate().child(name))
                                .when_some(o.subtitle.clone().filter(|s| !s.is_empty()), |d, s| {
                                    d.child(
                                        div()
                                            .truncate()
                                            .text_size(px(t.metrics.small))
                                            .text_color(t.roles.text_subtle)
                                            .child(s),
                                    )
                                }),
                        )
                        .into_any_element()
                })
                .collect()
        };
        div()
            .id("workspace-relation-sheet")
            .w_full()
            .flex()
            .flex_col()
            .gap(px(14.))
            .child(
                div()
                    .id("sheet-title")
                    .role(Role::Heading)
                    .text_size(px(t.metrics.body + 2.))
                    .font_weight(FontWeight::SEMIBOLD)
                    .child(self.title.clone()),
            )
            .child(grouped_section(None, rows, None, cx))
    }
}

/// Hide from Selector / Show in Selector, from a context menu: the model
/// saved with `hidden` flipped.
pub fn toggle_hidden(pane: &mut WorkspacePane, id: String, cx: &mut Context<WorkspacePane>) {
    let rpc = pane.rpc().clone();
    let toasts = pane.stores().toasts.clone();
    let account = super::active_account(pane.stores(), cx);
    cx.spawn(
        async move |this: WeakEntity<WorkspacePane>, cx: &mut AsyncApp| {
            let detail = rpc
                .call::<methods::WorkspaceGet>(&WorkspaceRef {
                    kind: WorkspaceKind::Models,
                    id,
                })
                .await;
            // Read under one account, it is never saved under the next.
            let same = this
                .update(cx, |p, cx| super::active_account(p.stores(), cx) == account)
                .unwrap_or(false);
            if !same {
                return;
            }
            let result = match detail {
                Ok(mut detail) => {
                    if let Some(m) = detail.model.as_mut() {
                        m.hidden = !m.hidden;
                    }
                    rpc.call::<methods::WorkspaceSave>(&WorkspaceSave {
                        detail,
                        create: false,
                        metadata_only: false,
                    })
                    .await
                }
                Err(e) => Err(e),
            };
            let _ = this.update(cx, |p, cx| {
                let l = cx.l10n().clone();
                match result {
                    Ok(_) => p.load(WorkspaceSection::Models, false, cx),
                    Err(e) => {
                        log::warn!("hide model: {e}");
                        toasts.update(cx, |t, cx| {
                            t.show(NoticeLevel::Error, editor::failure_text(&e, &l), cx)
                        });
                    }
                }
            });
        },
    )
    .detach();
}

impl ModelEditor {
    /// Types `value` into field `field` (`name`, `id`, `description`,
    /// `system`, `params`, `terminal`, `builtin_tools`): the E2E pass.
    pub fn set_field(
        &mut self,
        field: &str,
        value: &str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let value = value.to_string();
        match field {
            "name" => {
                // As typing does: an untouched id follows the name (a
                // programmatic set sends no change event).
                if self.id.is_none() && !self.id_typed {
                    let slug = command_from_name(&value);
                    self.model_id
                        .update(cx, |s, cx| s.set_value(slug, window, cx));
                }
                self.name.update(cx, |s, cx| s.set_value(value, window, cx))
            }
            "id" => self
                .model_id
                .update(cx, |s, cx| s.set_value(value, window, cx)),
            "description" => self
                .description
                .update(cx, |s, cx| s.set_value(value, window, cx)),
            "system" => self
                .system
                .update(cx, |s, cx| s.set_value(value, window, cx)),
            "params" => self
                .params
                .update(cx, |s, cx| s.set_value(value, window, cx)),
            "terminal" => self
                .terminal
                .update(cx, |s, cx| s.set_value(value, window, cx)),
            "builtin_tools" => self
                .builtin_tools
                .update(cx, |s, cx| s.set_value(value, window, cx)),
            _ => {}
        }
        cx.notify();
    }

    /// The base models offered, once loaded.
    pub fn base_models(&self) -> Vec<String> {
        self.options
            .as_ref()
            .map(|o| o.base_models.iter().map(|b| b.id.clone()).collect())
            .unwrap_or_default()
    }
}

impl ItemEditor for ModelEditor {
    fn item_id(&self) -> Option<String> {
        self.id.clone()
    }

    fn is_dirty(&self, cx: &App) -> bool {
        let (form, params, builtin) = self.form(cx);
        // A new model: any field filled in or changed (its base, abilities,
        // relations and built-in tools too), as for a saved one.
        (self.id.is_none() || self.detail.is_some())
            && (form != self.initial
                || params != self.initial_params
                || builtin != self.initial_builtin)
    }

    fn reload(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(id) = self.id.clone() else {
            return;
        };
        self.loading = self.detail.is_none();
        let call = self.rpc.call::<methods::WorkspaceGet>(&WorkspaceRef {
            kind: WorkspaceKind::Models,
            id,
        });
        let handle = window.window_handle();
        self._load = Some(
            cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
                let result = call.await;
                let _ = handle.update(cx, |_, window, cx| {
                    let _ = this.update(cx, |s, cx| {
                        s.loading = false;
                        match result {
                            Ok(detail) => s.adopt(detail, window, cx),
                            Err(e) => {
                                log::warn!("workspace.get model: {e}");
                                s.failure = Some(editor::failure_text(&e, &cx.l10n().clone()));
                            }
                        }
                        cx.notify();
                    });
                });
            }),
        );
        cx.notify();
    }

    fn save(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.saving || !self.writable() {
            return;
        }
        self.submitted = true;
        if !self.valid(cx) {
            cx.notify();
            return;
        }
        let creating = self.id.is_none();
        let sent = self.form(cx);
        let (mut model, params, builtin) = sent.clone();
        model.params = parse_params(&params).unwrap_or_default();
        model.builtin_tools = parse_params(&builtin).unwrap_or_default();
        let detail = WorkspaceDetail {
            kind: WorkspaceKind::Models,
            model: Some(model),
            knowledge: None,
            prompt: None,
            tool: None,
            skill: None,
            grants: vec![],
            write_access: true,
            owner_name: None,
            updated_at_ms: None,
        };
        self.saving = true;
        self.failure = None;
        cx.notify();
        let call = self.rpc.call::<methods::WorkspaceSave>(&WorkspaceSave {
            detail,
            create: creating,
            metadata_only: false,
        });
        let handle = window.window_handle();
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result = call.await;
            let _ = handle.update(cx, |_, window, cx| {
                let _ = this.update(cx, |s, cx| {
                    s.saving = false;
                    let l = cx.l10n().clone();
                    match result {
                        Ok(detail) => {
                            let id = editor::detail_id(&detail).unwrap_or_default();
                            // Typed on while it saved: that stays, still to
                            // save, in this editor.
                            let kept = s.form(cx) != sent;
                            if kept {
                                s.saved_under_edits(detail, sent, window, cx);
                            } else {
                                s.adopt(detail, window, cx);
                            }
                            s.stores.toasts.update(cx, |t, cx| {
                                t.show(NoticeLevel::Success, l.desktop_workspace_model_saved(), cx)
                            });
                            cx.emit(if creating && !kept {
                                EditorEvent::Created(id)
                            } else {
                                EditorEvent::Saved(id)
                            });
                        }
                        Err(e) => {
                            log::warn!("workspace.save model: {e}");
                            s.failure = Some(editor::failure_text(&e, &l));
                        }
                    }
                    cx.notify();
                });
            });
        })
        .detach();
    }

    fn on_choice(&mut self, action: &SettingsChoice, _: &mut Window, cx: &mut Context<Self>) {
        if action.menu == "model-base" {
            self.model.base_model_id = (!action.value.is_empty()).then(|| action.value.clone());
            cx.notify();
        }
    }
}

impl Render for ModelEditor {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let t = cx.conduit().clone();
        let r = t.roles;
        let l = cx.l10n().clone();
        let writable = self.writable();
        let creating = self.id.is_none();
        let FieldErrors {
            name: name_error,
            id: id_error,
            base: base_error,
            params: params_error,
            builtin_tools: builtin_error,
        } = self.errors(false, &l, cx);
        let (form, _, _) = self.form(cx);
        let view = cx.entity().downgrade();
        let mut body: Vec<AnyElement> = vec![];

        // Profile image.
        let initials: String = form
            .name
            .chars()
            .next()
            .map(|c| c.to_uppercase().collect())
            .unwrap_or_else(|| "M".into());
        let picture = self.picture(window, cx);
        self.drew_picture.set(picture.is_some());
        let avatar: AnyElement = match picture {
            Some(picture) => img(picture)
                .id("model-image-picture")
                .size(px(56.))
                .rounded(px(14.))
                .object_fit(gpui_kit::ObjectFit::Cover)
                .into_any_element(),
            None => conduit_components::views::kit::avatar(
                &initials,
                56.,
                conduit_components::theme::with_alpha(r.text, if t.dark { 0.14 } else { 0.07 }),
                r.text_subtle,
            )
            .into_any_element(),
        };
        let pick = view.clone();
        let clear = view.clone();
        let has_image = self.model.image_url.is_some();
        let waiting = self.remote_picture_waits(cx).zip(self.remote_picture(cx));
        body.push(
            div()
                .id("model-image")
                .role(Role::Group)
                .aria_label(SharedString::from(l.workspace_model_profile_image()))
                .flex()
                .items_center()
                .gap(px(14.))
                .child(avatar)
                .when_some(waiting, |d, (host, (url, _))| {
                    d.child(remote_picture_prompt(&url, &host, &l, &t))
                })
                .when(writable, |d| {
                    d.child(
                        Button::new("model-image-change", l.desktop_workspace_change_image())
                            .on_click(Rc::new(move |_, _, cx| {
                                let _ = pick.update(cx, |v, cx| v.pick_image(cx));
                            })),
                    )
                    .when(has_image, |d| {
                        d.child(
                            Button::new("model-image-remove", l.workspace_model_remove_image())
                                .ghost()
                                .on_click(Rc::new(move |_, _, cx| {
                                    let _ = clear.update(cx, |v, cx| {
                                        v.model.image_url = None;
                                        v.image = None;
                                        v.image_removed = true;
                                        cx.notify();
                                    });
                                })),
                        )
                    })
                })
                .into_any_element(),
        );

        // Basics.
        let base_choices: Vec<Choice> = {
            let mut c = vec![];
            if let Some(o) = &self.options {
                for b in &o.base_models {
                    c.push(Choice::new(
                        b.id.clone(),
                        if b.name.is_empty() {
                            b.id.clone()
                        } else {
                            b.name.clone()
                        },
                    ));
                }
            }
            if let Some(current) = &self.model.base_model_id
                && !c.iter().any(|ch| &ch.value == current)
            {
                c.push(Choice::new(current.clone(), current.clone()));
            }
            c
        };
        let base_value = self.model.base_model_id.clone().unwrap_or_default();
        let base = controls::popup(
            "model-base",
            &l.workspace_model_base_model(),
            base_choices,
            &base_value,
            !writable || self.options.is_none(),
            window,
            cx,
        );
        let mut basics = vec![
            forms::field(
                l.desktop_workspace_model_name(),
                &self.name,
                None,
                name_error.map(Into::into),
                window,
                cx,
            )
            .into_any_element(),
        ];
        if creating {
            basics.push(
                forms::field(
                    l.desktop_workspace_model_id_label(),
                    &self.model_id,
                    None,
                    id_error.map(Into::into),
                    window,
                    cx,
                )
                .into_any_element(),
            );
        } else {
            basics.push(
                forms::form_row(
                    l.desktop_workspace_model_id_label(),
                    controls::value(form.id.clone(), cx),
                    cx,
                )
                .into_any_element(),
            );
        }
        basics.push(forms::form_row(l.workspace_model_base_model(), base, cx).into_any_element());
        if let Some(e) = base_error {
            basics.push(
                forms::group_footer(e, cx)
                    .text_color(r.danger)
                    .into_any_element(),
            );
        }
        basics.push(
            forms::field(
                l.desktop_workspace_model_description(),
                &self.description,
                None,
                None,
                window,
                cx,
            )
            .into_any_element(),
        );
        basics.push(
            forms::field(
                l.desktop_workspace_model_tags(),
                &self.tags,
                None,
                None,
                window,
                cx,
            )
            .into_any_element(),
        );
        let active_view = view.clone();
        let hidden_view = view.clone();
        basics.push(
            forms::form_row(
                l.desktop_workspace_active(),
                Switch::new(
                    "model-active",
                    l.desktop_workspace_active(),
                    self.model.active,
                )
                .disabled(!writable)
                .on_click(Rc::new(move |_, _, cx| {
                    let _ = active_view.update(cx, |v, cx| {
                        v.model.active = !v.model.active;
                        cx.notify();
                    });
                })),
                cx,
            )
            .into_any_element(),
        );
        basics.push(
            forms::form_row(
                l.desktop_workspace_show_in_picker(),
                Switch::new(
                    "model-shown",
                    l.desktop_workspace_show_in_picker(),
                    !self.model.hidden,
                )
                .disabled(!writable)
                .on_click(Rc::new(move |_, _, cx| {
                    let _ = hidden_view.update(cx, |v, cx| {
                        v.model.hidden = !v.model.hidden;
                        cx.notify();
                    });
                })),
                cx,
            )
            .into_any_element(),
        );
        body.push(
            grouped_section(
                Some(l.desktop_workspace_model_section_basics().into()),
                basics,
                None,
                cx,
            )
            .into_any_element(),
        );

        // Prompt.
        let mut prompt_rows = vec![
            editor::stacked_row(
                l.workspace_model_system_prompt(),
                Textarea::new(&self.system),
                None,
                cx,
            )
            .into_any_element(),
        ];
        let suggestions: Vec<AnyElement> = self
            .suggestions
            .iter()
            .enumerate()
            .map(|(i, s)| {
                let view = view.clone();
                div()
                    .flex()
                    .items_center()
                    .gap(px(6.))
                    .child(
                        conduit_components::views::kit::field_frame(
                            false,
                            t.metrics.control_height,
                            cx,
                        )
                        .flex_1()
                        .child(conduit_components::views::kit::bare_input(
                            s,
                            l.workspace_model_suggestion_prompts(),
                            t.metrics.control,
                        )),
                    )
                    .when(writable, |d| {
                        d.child(
                            IconButton::new(
                                ElementId::NamedInteger("model-suggestion-remove".into(), i as u64),
                                IconName::X,
                                l.workspace_model_remove_suggestion(),
                            )
                            .size(24., 13.)
                            .on_click(Rc::new(move |_, _, cx| {
                                let _ = view.update(cx, |v, cx| {
                                    if i < v.suggestions.len() {
                                        v.suggestions.remove(i);
                                        cx.notify();
                                    }
                                });
                            })),
                        )
                    })
                    .into_any_element()
            })
            .collect();
        let add_view = view.clone();
        prompt_rows.push(
            editor::stacked_row(
                l.workspace_model_suggestion_prompts(),
                div()
                    .flex()
                    .flex_col()
                    .gap(px(6.))
                    .children(suggestions)
                    .when(writable, |d| {
                        d.child(
                            div().child(
                                Button::new(
                                    "model-suggestion-add",
                                    l.workspace_model_add_suggestion(),
                                )
                                .ghost()
                                .icon(IconName::Plus)
                                .on_click(Rc::new(
                                    move |_, window, cx| {
                                        let _ = add_view.update(cx, |v, cx| {
                                            let s = forms::input("", false, window, cx);
                                            s.update(cx, |s, cx| s.focus(window, cx));
                                            let sub = cx.subscribe_in(
                                                &s,
                                                window,
                                                |_, _, e: &InputEvent, _, cx| {
                                                    if matches!(e, InputEvent::Change) {
                                                        cx.notify();
                                                    }
                                                },
                                            );
                                            v._subscriptions.push(sub);
                                            v.suggestions.push(s);
                                            cx.notify();
                                        });
                                    },
                                )),
                            ),
                        )
                    }),
                None,
                cx,
            )
            .into_any_element(),
        );
        body.push(
            grouped_section(
                Some(l.desktop_workspace_model_section_prompt().into()),
                prompt_rows,
                None,
                cx,
            )
            .into_any_element(),
        );

        // Capabilities and default features.
        let mut caps: Vec<AnyElement> = vec![];
        for key in CAPABILITIES {
            let on = self.model.capabilities.get(key).copied().unwrap_or(false);
            caps.push(self.flag_row(
                format!("model-capability-{key}"),
                capability_label(key, &l),
                on,
                Rc::new(move |v: &mut Self, cx| {
                    let now = v.model.capabilities.get(key).copied().unwrap_or(false);
                    v.model.capabilities.insert(key.to_string(), !now);
                    cx.notify();
                }),
                window,
                cx,
            ));
        }
        body.push(
            grouped_section(
                Some(l.desktop_workspace_model_capabilities().into()),
                caps,
                None,
                cx,
            )
            .into_any_element(),
        );
        let mut features: Vec<AnyElement> = vec![];
        for key in DEFAULT_FEATURES {
            let on = self.model.default_feature_ids.iter().any(|f| f == key);
            features.push(self.flag_row(
                format!("model-feature-{key}"),
                capability_label(key, &l),
                on,
                Rc::new(move |v: &mut Self, cx| {
                    let list = &mut v.model.default_feature_ids;
                    if let Some(i) = list.iter().position(|f| f == key) {
                        list.remove(i);
                    } else {
                        list.push(key.to_string());
                    }
                    cx.notify();
                }),
                window,
                cx,
            ));
        }
        body.push(
            grouped_section(
                Some(l.workspace_model_default_features().into()),
                features,
                Some(l.desktop_workspace_default_features_hint().into()),
                cx,
            )
            .into_any_element(),
        );

        // Relationships.
        let relations: Vec<AnyElement> = Relation::ALL
            .into_iter()
            .map(|rel| self.relation_row(rel, &l, cx))
            .collect();
        body.push(
            grouped_section(
                Some(l.desktop_workspace_model_section_relationships().into()),
                relations,
                None,
                cx,
            )
            .into_any_element(),
        );

        // Advanced.
        body.push(
            grouped_section(
                Some(l.desktop_workspace_model_section_advanced().into()),
                vec![
                    editor::stacked_row(
                        l.workspace_model_advanced_params(),
                        Textarea::new(&self.params),
                        params_error
                            .map(SharedString::from)
                            .or_else(|| Some(l.desktop_workspace_model_params_hint().into())),
                        cx,
                    )
                    .into_any_element(),
                    forms::field(
                        l.workspace_model_stop_sequences(),
                        &self.stop,
                        None,
                        None,
                        window,
                        cx,
                    )
                    .into_any_element(),
                    forms::field(
                        l.desktop_workspace_model_terminal(),
                        &self.terminal,
                        None,
                        None,
                        window,
                        cx,
                    )
                    .into_any_element(),
                    forms::field(
                        l.workspace_model_tts_voice(),
                        &self.voice,
                        None,
                        None,
                        window,
                        cx,
                    )
                    .into_any_element(),
                    editor::stacked_row(
                        l.desktop_workspace_model_builtin_tools(),
                        Textarea::new(&self.builtin_tools),
                        builtin_error.map(SharedString::from).or_else(|| {
                            Some(l.desktop_workspace_model_builtin_tools_hint().into())
                        }),
                        cx,
                    )
                    .into_any_element(),
                ],
                None,
                cx,
            )
            .into_any_element(),
        );

        let item = self
            .detail
            .as_ref()
            .and_then(|d| editor::listed_item(&self.pane, WorkspaceSection::Models, d, cx));
        let title = if creating {
            l.workspace_model_new_title()
        } else if form.name.is_empty() {
            form.id.clone()
        } else {
            form.name.clone()
        };
        let subtitle = self
            .detail
            .as_ref()
            .and_then(|d| editor::subtitle(d.owner_name.as_deref(), d.write_access, &l));
        let dirty = self.is_dirty(cx);
        let _ = relative(1.);
        editor::frame(
            "model-editor",
            Frame {
                section: WorkspaceSection::Models,
                title,
                subtitle,
                item,
                dirty,
                saving: self.saving,
                can_save: !self.submitted || self.valid(cx),
                read_only: !writable,
                creating,
                loading: self.loading,
                failure: self.failure.clone(),
                scroll: Some(self.scroll.clone()),
            },
            self.pane.clone(),
            body,
            Rc::new(|v: &mut Self, window, cx| v.revert(window, cx)),
            Rc::new(|v: &mut Self, window, cx| v.save(window, cx)),
            cx,
        )
    }
}

/// Beside a model's initial while its picture on another site waits:
/// where the picture is, Load Image, and a menu with Always Load Images
/// from that site, as an answer's picture offers.
fn remote_picture_prompt(
    url: &str,
    host: &str,
    l: &L10n,
    t: &conduit_components::theme::ConduitTheme,
) -> AnyElement {
    use crate::views::chat::remote_image::ImageAction;
    use gpui_kit::component::native_menu::NativeMenu;

    let r = t.roles;
    let load_url = url.to_string();
    let menu = {
        let load = (l.desktop_load_image(), url.to_string());
        let always = (l.desktop_always_load_images_from(host), host.to_string());
        move |position, window: &mut Window, cx: &mut App| {
            NativeMenu::new()
                .menu(load.0.clone(), Box::new(ImageAction::Load(load.1.clone())))
                .separator()
                .menu(
                    always.0.clone(),
                    Box::new(ImageAction::AllowHost(always.1.clone())),
                )
                .show(position, window, cx);
        }
    };
    div()
        .id("model-image-remote")
        .role(Role::Group)
        .aria_label(SharedString::from(l.desktop_remote_image_label(host)))
        .flex()
        .flex_col()
        .gap(px(4.))
        .min_w_0()
        .child(
            div()
                .truncate()
                .text_size(px(t.metrics.small))
                .text_color(r.text_subtle)
                .child(SharedString::from(l.desktop_remote_image_from(host))),
        )
        .child(
            div()
                .flex()
                .items_center()
                .gap(px(4.))
                .child(
                    Button::new("model-image-load", l.desktop_load_image())
                        .on_click(Rc::new(move |_, _, cx| media::load_once(&load_url, cx))),
                )
                .child(
                    IconButton::new(
                        "model-image-options",
                        IconName::ChevronDown,
                        l.desktop_image_options(),
                    )
                    .size(24., 14.)
                    .round()
                    .on_click(Rc::new(move |e, window, cx| menu(e.position(), window, cx))),
                ),
        )
        .into_any_element()
}

#[cfg(test)]
mod tests {
    use gpui_kit::VisualTestContext;

    use super::*;

    /// An id typed while the new item was being made gives way to the id it
    /// was made with: the next Save updates that item, never another.
    #[gpui_kit::test]
    fn a_made_model_keeps_the_id_it_was_made_with(cx: &mut gpui_kit::TestAppContext) {
        use crate::views::workspace::editor::bench;
        let (daemon, stores, vcx) = crate::views::sheet::bench::bench(cx);
        daemon.returns::<methods::WorkspaceSave>(bench::detail(
            WorkspaceKind::Models,
            serde_json::json!({"id": "trail-guide", "name": "Trail Guide", "baseModelId": "base"}),
        ));
        let editor = vcx.update(|window, cx| {
            cx.new(|cx| {
                ModelEditor::new(
                    stores.clone(),
                    WeakEntity::new_invalid(),
                    None,
                    bench::manage(),
                    window,
                    cx,
                )
            })
        });
        vcx.run_until_parked();
        let set = |field: &str, text: &str, vcx: &mut gpui_kit::VisualTestContext| {
            vcx.update(|window, cx| editor.update(cx, |e, cx| e.set_field(field, text, window, cx)))
        };
        set("name", "Trail Guide", vcx);
        set("id", "trail-guide", vcx);
        editor.update(vcx, |e, _| e.model.base_model_id = Some("base".into()));
        let held = daemon.hold::<methods::WorkspaceSave>();
        vcx.update(|window, cx| editor.update(cx, |e, cx| e.save(window, cx)));
        vcx.run_until_parked();
        set("id", "other-guide", vcx);
        drop(held);
        vcx.run_until_parked();
        editor.read_with(vcx, |e, cx| {
            assert_eq!(e.id.as_deref(), Some("trail-guide"));
            assert_eq!(
                e.model_id.read(cx).value().to_string(),
                "trail-guide",
                "the id field names another item than the one made"
            );
        });
    }
    use crate::views::sheet::bench::bench;

    fn editor(
        stores: &Stores,
        id: Option<&str>,
        vcx: &mut VisualTestContext,
    ) -> Entity<ModelEditor> {
        let stores = stores.clone();
        let id = id.map(str::to_string);
        let access = WorkspaceSectionAccess {
            manage: true,
            ..Default::default()
        };
        let editor = vcx.update(|window, cx| {
            cx.new(|cx| ModelEditor::new(stores, WeakEntity::new_invalid(), id, access, window, cx))
        });
        vcx.run_until_parked();
        editor
    }

    fn detail(name: &str, description: &str) -> WorkspaceDetail {
        WorkspaceDetail {
            kind: WorkspaceKind::Models,
            model: Some(WorkspaceModelDto {
                id: "trail-guide".into(),
                name: name.into(),
                base_model_id: Some("base".into()),
                description: description.into(),
                ..blank_model()
            }),
            knowledge: None,
            prompt: None,
            tool: None,
            skill: None,
            grants: vec![],
            write_access: true,
            owner_name: None,
            updated_at_ms: None,
        }
    }

    fn set(editor: &Entity<ModelEditor>, field: &str, text: &str, vcx: &mut VisualTestContext) {
        vcx.update(|window, cx| editor.update(cx, |e, cx| e.set_field(field, text, window, cx)));
    }

    /// A new model asks before its edits go, whichever field they are in.
    #[gpui_kit::test]
    fn a_new_models_description_alone_asks_before_it_goes(cx: &mut gpui_kit::TestAppContext) {
        let (_daemon, stores, vcx) = bench(cx);
        let editor = editor(&stores, None, vcx);
        assert!(!editor.read_with(vcx, |e, cx| e.is_dirty(cx)));
        set(&editor, "description", "Plans day hikes", vcx);
        assert!(
            editor.read_with(vcx, |e, cx| e.is_dirty(cx)),
            "a description typed into a new model went without asking"
        );
    }

    /// Text typed while a save is out is kept, still to save.
    #[gpui_kit::test]
    fn text_typed_while_a_model_saves_stays(cx: &mut gpui_kit::TestAppContext) {
        let (daemon, stores, vcx) = bench(cx);
        daemon.returns::<methods::WorkspaceGet>(detail("Trail Guide", "Plans hikes"));
        daemon.returns::<methods::WorkspaceSave>(detail("Trail Guide", "Plans day hikes"));
        let editor = editor(&stores, Some("trail-guide"), vcx);
        set(&editor, "description", "Plans day hikes", vcx);
        let held = daemon.hold::<methods::WorkspaceSave>();
        vcx.update(|window, cx| editor.update(cx, |e, cx| e.save(window, cx)));
        vcx.run_until_parked();
        set(&editor, "description", "Plans day hikes and picnics", vcx);
        drop(held);
        vcx.run_until_parked();
        editor.read_with(vcx, |e, cx| {
            assert_eq!(
                e.description.read(cx).value().to_string(),
                "Plans day hikes and picnics",
                "the save's answer replaced what was typed since"
            );
            assert!(e.is_dirty(cx), "the later words count as saved");
        });
        assert_eq!(daemon.calls::<methods::WorkspaceSave>().len(), 1);
    }

    #[test]
    fn parameters_are_a_json_object_or_nothing() {
        assert_eq!(parse_params(""), Some(serde_json::json!({})));
        assert_eq!(
            parse_params("{\"temperature\": 0.2}"),
            Some(serde_json::json!({"temperature": 0.2}))
        );
        assert_eq!(parse_params("[1, 2]"), None);
        assert_eq!(parse_params("{temperature"), None);
        assert_eq!(params_text(&serde_json::json!({})), "");
        assert!(params_text(&serde_json::json!({"top_k": 40})).contains("\"top_k\": 40"));
    }

    #[test]
    fn a_profile_image_decodes_from_its_data_url() {
        assert!(data_url_image("data:image/png;base64,iVBORw0KGgo=").is_some());
        assert!(data_url_image("/static/favicon.png").is_none());
        assert!(data_url_image("data:text/plain;base64,aGk=").is_none());
    }

    #[test]
    fn relationships_read_and_write_their_lists() {
        let mut m = blank_model();
        Relation::Tools.set(&mut m, vec!["web".into()], &[]);
        assert_eq!(Relation::Tools.selected(&m), ["web"]);
        let options = vec![WorkspaceRelation {
            id: "k1".into(),
            name: "Garden handbook".into(),
            subtitle: None,
        }];
        Relation::Knowledge.set(&mut m, vec!["k1".into()], &options);
        assert_eq!(m.knowledge[0].name, "Garden handbook");
    }
}
