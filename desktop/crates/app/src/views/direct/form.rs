//! The Direct connection form: everything a connection the app talks to
//! itself can carry, as mobile's editor has it. Onboarding draws it inline
//! (the first connection, preferred on save); Settings › Direct
//! Connections draws it in a sheet ([`super::editor`]).
//!
//! * **Connection**: the provider (OpenAI-compatible, OpenRouter or
//!   Ollama, local or Cloud), a name, the address, how the key is sent
//!   (a bearer token, Azure's `api-key` header, or none) and the key.
//! * **Advanced Settings**: the completion API (Chat Completions or
//!   Responses) and Azure's `api-version`; custom headers; a model-id
//!   prefix, tags and model ids for a server that can't list its own; and
//!   on this Mac only, an unverified certificate and a client certificate
//!   for mutual TLS (PEM files).
//!
//! The form tests (`direct.test`) and saves (`direct.save`). Secrets
//! follow the daemon's rule: a saved key, header value or PEM never comes
//! back, so an empty field keeps it, and a cleared one is sent empty. A
//! connection kept in the Open WebUI account names no provider or name of
//! its own (Open WebUI keeps neither) and has no certificates.

use std::rc::Rc;

use conduit_components::ActiveConduitTheme as _;
use conduit_components::assets::IconName;
use conduit_components::views::focus::ControlExt as _;
use conduit_components::views::kit::{Button, ClickHandler, Switch, grouped, setting_row};
use conduit_daemon::RpcError;
use conduit_protocol::{
    DirectApiMode, DirectConnectionEdit, DirectConnectionList, DirectConnectionSummary, DirectKind,
    DirectPreferred, DirectTestResult, ErrorCode, NoParams, methods,
};
use gpui_kit::component::input::{InputEvent, InputState, Textarea, TextareaState};
use gpui_kit::prelude::*;
use gpui_kit::{
    AnyElement, App, AsyncWindowContext, ClickEvent, Context, Entity, EventEmitter, FontWeight,
    Role, SharedString, Subscription, WeakEntity, Window, div, px, relative,
};

use crate::actions::SettingsChoice;
use crate::l10n::{ActiveL10n as _, L10n};
use crate::stores::Stores;
use crate::views::forms::{
    self, HeaderError, HeaderRow, PemError, PemFile, PemLabels, field, form_error, form_group,
    form_note, form_row, header_rows, headers_edit, headers_from_rows, normalize_url, pem_picker,
    pick_pem,
};
use crate::views::settings::controls::{self, Choice};
use crate::views::words;

/// OpenRouter's API root, which its connections must use.
pub const OPEN_ROUTER_URL: &str = "https://openrouter.ai/api/v1";
/// Where Ollama listens on this Mac.
pub const LOCAL_OLLAMA_URL: &str = "http://localhost:11434";

#[derive(Clone, Debug, PartialEq)]
pub enum DirectEvent {
    Saved,
}

/// What the last Test or Save said.
#[derive(Clone, Debug, PartialEq)]
pub enum DirectNote {
    Tested(DirectTestResult),
    Saved,
}

/// OpenRouter's API root, global or EU (the core's
/// `isOpenRouterApiBaseUrl`): the address the core tells OpenRouter apart
/// by, so an OpenRouter connection saves only with it.
pub fn is_open_router_url(value: &str) -> bool {
    let Ok(url) = url::Url::parse(value.trim()) else {
        return false;
    };
    url.scheme() == "https"
        && matches!(url.host_str(), Some("openrouter.ai" | "eu.openrouter.ai"))
        && url.port().is_none_or(|p| p == 443)
        && url.username().is_empty()
        && url.password().is_none()
        && url.query().is_none()
        && url.fragment().is_none()
        && matches!(url.path(), "/api/v1" | "/api/v1/")
}

/// The provider choice, as mobile's: OpenRouter is an OpenAI-compatible
/// server the core tells apart by its address.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Preset {
    OpenAi,
    OpenRouter,
    Ollama,
}

impl Preset {
    pub const ALL: [Preset; 3] = [Preset::OpenAi, Preset::OpenRouter, Preset::Ollama];

    pub fn value(self) -> &'static str {
        match self {
            Preset::OpenAi => "openai",
            Preset::OpenRouter => "openrouter",
            Preset::Ollama => "ollama",
        }
    }

    pub fn from_value(value: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|p| p.value() == value)
    }

    pub fn kind(self) -> DirectKind {
        match self {
            Preset::Ollama => DirectKind::Ollama,
            _ => DirectKind::Openai,
        }
    }

    pub fn label(self, l10n: &L10n) -> String {
        match self {
            Preset::OpenAi => l10n.desktop_open_ai_compatible(),
            Preset::OpenRouter => l10n.open_router_provider_name(),
            Preset::Ollama => l10n.ollama(),
        }
    }

    /// The address a new connection starts with, when this provider has
    /// one everyone uses.
    fn default_url(self) -> Option<&'static str> {
        match self {
            Preset::OpenAi => None,
            Preset::OpenRouter => Some(OPEN_ROUTER_URL),
            Preset::Ollama => Some(LOCAL_OLLAMA_URL),
        }
    }

    fn of(summary: &DirectConnectionSummary) -> Self {
        match summary.kind {
            DirectKind::Ollama => Preset::Ollama,
            _ if summary.open_router => Preset::OpenRouter,
            _ => Preset::OpenAi,
        }
    }
}

/// How the key is sent.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Auth {
    Bearer,
    /// Azure's `api-key` header.
    ApiKeyHeader,
    None,
}

impl Auth {
    pub fn value(self) -> &'static str {
        match self {
            Auth::Bearer => "bearer",
            Auth::ApiKeyHeader => "api-key",
            Auth::None => "none",
        }
    }

    pub fn from_value(value: &str) -> Option<Self> {
        [Auth::Bearer, Auth::ApiKeyHeader, Auth::None]
            .into_iter()
            .find(|a| a.value() == value)
    }

    fn label(self, l10n: &L10n) -> String {
        match self {
            Auth::Bearer => l10n.bearer_token(),
            Auth::ApiKeyHeader => l10n.direct_api_key_header(),
            Auth::None => l10n.no_authentication(),
        }
    }
}

/// The pop-ups' menu names ([`SettingsChoice::menu`]).
pub const MENU_PRESET: &str = "direct-form-preset";
pub const MENU_AUTH: &str = "direct-form-auth";
pub const MENU_API: &str = "direct-form-api";

/// A field the form refused, to focus and mark.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Invalid {
    Name,
    Url,
    Key,
    Header(usize),
}

pub struct DirectView {
    stores: Stores,
    /// Onboarding: one connection, preferred on save, no advanced extras
    /// that need a saved connection.
    pub onboarding: bool,
    /// The connection being edited (`None` = a new one).
    pub editing: Option<DirectConnectionSummary>,
    /// Kept in the Open WebUI account (a new one there, or one of those).
    pub open_web_ui: bool,
    pub preset: Preset,
    pub enabled: bool,
    pub name: Entity<InputState>,
    pub base_url: Entity<InputState>,
    pub api_key: Entity<InputState>,
    pub auth: Auth,
    pub api_mode: DirectApiMode,
    /// The user chose the API mode: it no longer follows the address.
    pub api_mode_picked: bool,
    pub api_version: Entity<InputState>,
    pub model_prefix: Entity<InputState>,
    pub tags: Entity<InputState>,
    pub manual_models: Entity<TextareaState>,
    pub headers: Vec<HeaderRow>,
    /// The saved headers are to go (only their names are known here).
    pub clear_headers: bool,
    pub certificate: Option<PemFile>,
    pub private_key: Option<PemFile>,
    pub clear_certificate: bool,
    pub clear_private_key: bool,
    pub key_password: Entity<InputState>,
    pub self_signed: bool,
    pub advanced: bool,
    /// Saving.
    pub busy: bool,
    pub testing: bool,
    pub error: Option<String>,
    pub invalid: Option<Invalid>,
    pub note: Option<DirectNote>,
    _subscriptions: Vec<Subscription>,
}

impl EventEmitter<DirectEvent> for DirectView {}

impl DirectView {
    /// A new connection on this Mac.
    pub fn new(
        stores: Stores,
        onboarding: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Self {
        let mut this = Self::blank(stores, onboarding, window, cx);
        this.set_preset(Preset::OpenAi, window, cx);
        this
    }

    /// A new connection kept in the Open WebUI account.
    pub fn new_open_web_ui(stores: Stores, window: &mut Window, cx: &mut Context<Self>) -> Self {
        let mut this = Self::blank(stores, false, window, cx);
        this.open_web_ui = true;
        this
    }

    /// `summary`, to change.
    pub fn editing(
        stores: Stores,
        summary: DirectConnectionSummary,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Self {
        let mut this = Self::blank(stores, false, window, cx);
        this.adopt(summary, window, cx);
        this
    }

    fn blank(
        stores: Stores,
        onboarding: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Self {
        let l10n = cx.l10n().clone();
        let name = forms::input(l10n.desktop_my_provider(), false, window, cx);
        let base_url = forms::input("https://api.openai.com/v1", false, window, cx);
        let api_key = forms::input(l10n.direct_api_key_placeholder(), true, window, cx);
        let api_version = forms::input("2024-10-21", false, window, cx);
        let model_prefix = forms::input("studio", false, window, cx);
        let tags = forms::input("local, private", false, window, cx);
        let key_password = forms::input(l10n.desktop_optional(), true, window, cx);
        let manual_models = cx.new(|cx| {
            TextareaState::new(window, cx)
                .auto_grow(3, 8)
                .placeholder("model-a\nmodel-b")
        });
        let mut subscriptions = vec![];
        // Return is Save's (while it is on); typing clears the last error.
        for input in [
            &name,
            &base_url,
            &api_key,
            &api_version,
            &model_prefix,
            &tags,
        ] {
            subscriptions.push(cx.subscribe_in(
                input,
                window,
                |this: &mut Self, _, e: &InputEvent, window, cx| match e {
                    InputEvent::PressEnter { .. } if this.can_save(cx) => this.save(window, cx),
                    InputEvent::Change => {
                        if this
                            .invalid
                            .is_some_and(|i| !matches!(i, Invalid::Header(_)))
                        {
                            this.invalid = None;
                            this.error = None;
                        }
                        // A Test's result was for the draft as it was.
                        this.note = None;
                        this.follow_url_mode(cx);
                        cx.notify();
                    }
                    _ => {}
                },
            ));
        }
        Self {
            stores,
            onboarding,
            editing: None,
            open_web_ui: false,
            preset: Preset::OpenAi,
            enabled: true,
            name,
            base_url,
            api_key,
            auth: Auth::Bearer,
            api_mode: DirectApiMode::Chat,
            api_mode_picked: false,
            api_version,
            model_prefix,
            tags,
            manual_models,
            headers: vec![],
            clear_headers: false,
            certificate: None,
            private_key: None,
            clear_certificate: false,
            clear_private_key: false,
            key_password,
            self_signed: false,
            advanced: false,
            busy: false,
            testing: false,
            error: None,
            invalid: None,
            note: None,
            _subscriptions: subscriptions,
        }
    }

    /// Fills the form from a saved connection.
    pub fn adopt(
        &mut self,
        c: DirectConnectionSummary,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let l10n = cx.l10n().clone();
        self.preset = Preset::of(&c);
        self.open_web_ui = c.open_web_ui;
        self.enabled = c.enabled;
        // No key saved signs in with none, in the account too: an edit asks
        // for no key it never had.
        self.auth = if c.api_key_header {
            Auth::ApiKeyHeader
        } else if c.has_api_key {
            Auth::Bearer
        } else {
            Auth::None
        };
        self.api_mode = c.api_mode;
        self.self_signed = c.allow_self_signed_certificates;
        let set = |state: &Entity<InputState>, value: String, window: &mut Window, cx: &mut App| {
            state.update(cx, |s, cx| s.set_value(value, window, cx));
        };
        set(&self.name, c.name.clone(), window, cx);
        set(&self.base_url, c.base_url.clone(), window, cx);
        // A saved key never comes back; empty keeps it.
        set(&self.api_key, String::new(), window, cx);
        set(
            &self.api_version,
            c.api_version.clone().unwrap_or_default(),
            window,
            cx,
        );
        set(
            &self.model_prefix,
            c.model_id_prefix.clone().unwrap_or_default(),
            window,
            cx,
        );
        set(&self.tags, c.tags.join(", "), window, cx);
        let models = c.manual_model_ids.join("\n");
        self.manual_models
            .update(cx, |s, cx| s.set_value(models, window, cx));
        if c.has_api_key {
            forms::set_hint(
                &self.api_key,
                l10n.direct_configured_replace_placeholder(),
                cx,
            );
        }
        // Something under Advanced is set: open it, so it is seen.
        self.advanced = c.api_mode == DirectApiMode::Responses
            || c.api_version.is_some()
            || !c.custom_header_names.is_empty()
            || c.model_id_prefix.is_some()
            || !c.tags.is_empty()
            || !c.manual_model_ids.is_empty()
            || c.certificate_label.is_some()
            || c.allow_self_signed_certificates;
        self.editing = Some(c);
        self.note = None;
        self.error = None;
        self.invalid = None;
        cx.notify();
    }

    /// A different provider: its address (for a new connection whose
    /// address is still another provider's or empty) and its options.
    pub fn set_preset(&mut self, preset: Preset, window: &mut Window, cx: &mut Context<Self>) {
        let l10n = cx.l10n().clone();
        let previous = self.preset;
        self.preset = preset;
        if self.editing.is_none() {
            let url = forms::text(&self.base_url, cx);
            let untouched = url.is_empty() || previous.default_url() == Some(url.as_str());
            if untouched {
                let next = preset.default_url().unwrap_or_default().to_string();
                self.base_url
                    .update(cx, |s, cx| s.set_value(next, window, cx));
            }
            let name = forms::text(&self.name, cx);
            let named_after = |p: Preset| match p {
                Preset::OpenAi => l10n.desktop_my_provider(),
                p => p.label(&l10n),
            };
            if name.is_empty() || Preset::ALL.iter().any(|p| named_after(*p) == name) {
                self.name.update(cx, |s, cx| s.set_value("", window, cx));
                forms::set_hint(&self.name, named_after(preset), cx);
            }
        }
        forms::set_hint(
            &self.base_url,
            match preset {
                Preset::OpenAi => "https://api.openai.com/v1",
                Preset::OpenRouter => OPEN_ROUTER_URL,
                Preset::Ollama => LOCAL_OLLAMA_URL,
            },
            cx,
        );
        // OpenRouter takes a bearer token and Chat Completions only.
        if preset == Preset::OpenRouter {
            self.auth = Auth::Bearer;
            self.api_mode = DirectApiMode::Chat;
        }
        if preset == Preset::Ollama && self.auth == Auth::ApiKeyHeader {
            self.auth = Auth::Bearer;
        }
        self.follow_url_mode(cx);
        if previous != preset {
            self.note = None;
        }
        cx.notify();
    }

    /// A new OpenAI-compatible connection, while its API mode is not
    /// chosen, uses the Responses API on the OpenAI platform itself and Chat
    /// Completions elsewhere, as on a phone. A saved one keeps its own.
    pub fn follow_url_mode(&mut self, cx: &App) {
        if self.editing.is_some() || self.api_mode_picked || self.preset != Preset::OpenAi {
            return;
        }
        self.api_mode = if is_openai_platform_url(&forms::text(&self.base_url, cx)) {
            DirectApiMode::Responses
        } else {
            DirectApiMode::Chat
        };
    }

    /// The authentication choices this connection offers.
    pub fn auth_choices(&self) -> Vec<Auth> {
        let mut out = vec![Auth::Bearer];
        if !self.open_web_ui && self.preset == Preset::OpenAi {
            out.push(Auth::ApiKeyHeader);
        }
        if self.open_web_ui || self.preset != Preset::OpenRouter {
            out.push(Auth::None);
        }
        out
    }

    /// A pop-up's pick ([`SettingsChoice`]).
    pub fn on_choice(
        &mut self,
        action: &SettingsChoice,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        match action.menu.as_str() {
            MENU_PRESET => {
                if let Some(p) = Preset::from_value(&action.value) {
                    self.set_preset(p, window, cx);
                }
            }
            MENU_AUTH => {
                if let Some(a) = Auth::from_value(&action.value)
                    && self.auth_choices().contains(&a)
                {
                    self.auth = a;
                    if self.invalid == Some(Invalid::Key) {
                        self.invalid = None;
                        self.error = None;
                    }
                    cx.notify();
                }
            }
            MENU_API => {
                self.api_mode_picked = true;
                self.api_mode = if action.value == "responses" {
                    DirectApiMode::Responses
                } else {
                    DirectApiMode::Chat
                };
                cx.notify();
            }
            _ => {}
        }
    }

    /// Whether Save (and Test) can go: not busy, and an address typed.
    pub fn can_save(&self, cx: &App) -> bool {
        !self.busy && !self.testing && forms::filled(&[&self.base_url], cx)
    }

    /// The saved connection has a key, a header or a PEM the daemon keeps.
    fn has_saved_secrets(&self) -> bool {
        self.editing.as_ref().is_some_and(|c| {
            c.has_api_key || !c.custom_header_names.is_empty() || c.certificate_label.is_some()
        })
    }

    /// The address moved to another server: the saved secrets stay behind
    /// unless typed again (the daemon's rule), and the form says so.
    pub fn secrets_stay_behind(&self, cx: &App) -> bool {
        let Some(saved) = &self.editing else {
            return false;
        };
        if !self.has_saved_secrets() {
            return false;
        }
        let origin = |u: &str| {
            url::Url::parse(u)
                .ok()
                .map(|u| u.origin().ascii_serialization())
        };
        let typed = normalize_url(&forms::text(&self.base_url, cx));
        let moved = typed.is_some_and(|t| origin(&t) != origin(&saved.base_url));
        moved && forms::raw(&self.api_key, cx).is_empty() && self.headers.is_empty()
    }

    /// The edit to send, or why not (with the field to fix).
    pub fn edit(&mut self, cx: &mut Context<Self>) -> Option<DirectConnectionEdit> {
        let l10n = cx.l10n().clone();
        let fail = |this: &mut Self, invalid: Invalid, message: String, cx: &mut Context<Self>| {
            this.invalid = Some(invalid);
            this.error = Some(message);
            cx.notify();
            None
        };
        let name = forms::text(&self.name, cx);
        let name = if !name.is_empty() || self.open_web_ui {
            name
        } else {
            forms::hint(&self.name, cx)
                .map(|h| h.to_string())
                .unwrap_or_else(|| l10n.desktop_my_provider())
        };
        let Some(base_url) = normalize_url(&forms::text(&self.base_url, cx)) else {
            return fail(
                self,
                Invalid::Url,
                l10n.desktop_invalid_server_address(),
                cx,
            );
        };
        if self.preset == Preset::OpenRouter && !is_open_router_url(&base_url) {
            return fail(
                self,
                Invalid::Url,
                l10n.desktop_direct_open_router_url(),
                cx,
            );
        }
        let key = forms::raw(&self.api_key, cx).trim().to_string();
        let saved_key = self.editing.as_ref().is_some_and(|c| c.has_api_key);
        let api_key = match self.auth {
            // No key at all: clear one that was saved.
            Auth::None => saved_key.then(String::new),
            _ if !key.is_empty() => Some(key),
            _ if saved_key => None,
            _ => {
                return fail(self, Invalid::Key, l10n.desktop_direct_key_required(), cx);
            }
        };
        let custom_headers = {
            let rows: Vec<(String, String)> = self
                .headers
                .iter()
                .map(|h| (forms::text(&h.name, cx), forms::raw(&h.value, cx)))
                .collect();
            let saved_names = self
                .editing
                .as_ref()
                .map(|c| c.custom_header_names.as_slice())
                .unwrap_or_default();
            match headers_from_rows(&rows) {
                Ok(map) => headers_edit(map, self.clear_headers, saved_names),
                Err(e) => {
                    let (row, message) = match e {
                        HeaderError::MissingName(i) => {
                            (i, l10n.desktop_direct_header_name_required())
                        }
                        HeaderError::InvalidName(i) => (i, l10n.header_name_invalid_chars()),
                        HeaderError::Duplicate(name) => {
                            let i = rows
                                .iter()
                                .rposition(|(n, _)| n.eq_ignore_ascii_case(&name))
                                .unwrap_or(0);
                            (i, l10n.desktop_header_already_exists(&name))
                        }
                    };
                    self.advanced = true;
                    return fail(self, Invalid::Header(row), message, cx);
                }
            }
        };
        let manual_model_ids = lines(self.manual_models.read(cx).value().as_ref());
        let tags = forms::text(&self.tags, cx)
            .split([',', '\n'])
            .map(str::trim)
            .filter(|t| !t.is_empty())
            .map(str::to_string)
            .collect();
        let optional = |s: String| (!s.is_empty()).then_some(s);
        let local = !self.open_web_ui;
        let (certificate_pem, certificate_label) = match (&self.certificate, self.clear_certificate)
        {
            (Some(f), _) if local => (Some(f.pem.clone()), Some(f.label.clone())),
            (None, true) => (Some(String::new()), None),
            _ => (None, None),
        };
        let (private_key_pem, private_key_label) = match (&self.private_key, self.clear_private_key)
        {
            (Some(f), _) if local => (Some(f.pem.clone()), Some(f.label.clone())),
            (None, true) => (Some(String::new()), None),
            _ => (None, None),
        };
        let password = forms::raw(&self.key_password, cx);
        self.invalid = None;
        Some(DirectConnectionEdit {
            id: self.editing.as_ref().map(|c| c.id.clone()),
            name,
            kind: self.preset.kind(),
            base_url,
            api_mode: if self.preset == Preset::OpenAi {
                self.api_mode
            } else {
                DirectApiMode::Chat
            },
            api_version: (self.preset == Preset::OpenAi)
                .then(|| optional(forms::text(&self.api_version, cx)))
                .flatten(),
            api_key_header: self.auth == Auth::ApiKeyHeader,
            model_id_prefix: optional(forms::text(&self.model_prefix, cx)),
            enabled: self.enabled,
            open_web_ui: self.open_web_ui,
            api_key,
            custom_headers,
            manual_model_ids,
            allow_self_signed_certificates: local && self.self_signed,
            tags,
            certificate_pem,
            certificate_label,
            private_key_pem: private_key_pem.clone(),
            private_key_label,
            private_key_password: (private_key_pem.is_some_and(|p| !p.is_empty())
                && !password.is_empty())
            .then_some(password),
        })
    }

    /// After a failed Test or Save: the field to fix, its text selected.
    /// A refused key is the key's fault; anything else (no answer, a bad
    /// address) the address's.
    fn focus_invalid(&mut self, error: Option<&RpcError>, window: &mut Window, cx: &mut App) {
        let field = match (self.invalid, error) {
            (Some(Invalid::Name), _) => self.name.clone(),
            (Some(Invalid::Key), _) => self.api_key.clone(),
            (Some(Invalid::Header(i)), _) => match self.headers.get(i) {
                Some(row) => row.name.clone(),
                None => self.base_url.clone(),
            },
            (_, Some(e)) if words::is_unauthorized(e) => self.api_key.clone(),
            _ => self.base_url.clone(),
        };
        forms::focus_invalid(&field, window, cx);
    }

    pub fn test(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.busy || self.testing {
            return;
        }
        self.error = None;
        self.note = None;
        let Some(edit) = self.edit(cx) else {
            self.focus_invalid(None, window, cx);
            return;
        };
        self.testing = true;
        cx.notify();
        let call = self
            .stores
            .connection
            .read(cx)
            .rpc()
            .call::<methods::DirectTest>(&edit);
        let l10n = cx.l10n().clone();
        cx.spawn_in(
            window,
            async move |this: WeakEntity<Self>, cx: &mut AsyncWindowContext| {
                let result = call.await;
                let _ = this.update_in(cx, |s, window, cx| {
                    s.testing = false;
                    match result {
                        Ok(r) => s.note = Some(DirectNote::Tested(r)),
                        Err(e) => {
                            s.error = Some(words::connect_error(&e, &l10n));
                            s.focus_invalid(Some(&e), window, cx);
                        }
                    }
                    cx.notify();
                });
            },
        )
        .detach();
    }

    pub fn save(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.busy || self.testing {
            return;
        }
        self.error = None;
        self.note = None;
        let Some(edit) = self.edit(cx) else {
            self.focus_invalid(None, window, cx);
            return;
        };
        self.busy = true;
        cx.notify();
        let rpc = self.stores.connection.read(cx).rpc();
        let session = self.stores.session.clone();
        let onboarding = self.onboarding;
        let l10n = cx.l10n().clone();
        let ids = |l: &DirectConnectionList| -> Vec<String> {
            l.connections.iter().map(|c| c.id.clone()).collect()
        };
        cx.spawn_in(
            window,
            async move |this: WeakEntity<Self>, cx: &mut AsyncWindowContext| {
                // What was saved before a new connection, to tell it in the
                // answer. With no list, nothing is taken for the new one.
                let before = match edit.id {
                    None => rpc
                        .call::<methods::DirectList>(&NoParams)
                        .await
                        .ok()
                        .map(|l| ids(&l)),
                    Some(_) => None,
                };
                let saved = rpc.call::<methods::DirectSave>(&edit).await;
                // Chosen on the welcome screen: Direct is how this Mac chats.
                let preferred = match &saved {
                    Ok(_) if onboarding => Some(
                        rpc.call::<methods::DirectSetPreferred>(&DirectPreferred {
                            preferred: true,
                        })
                        .await,
                    ),
                    _ => None,
                };
                session.update(cx, |s, cx| s.refresh(cx));
                let _ = this.update_in(cx, |s, window, cx| {
                    s.busy = false;
                    // A save that went through is kept whatever follows: a
                    // new connection is edited from here on (Connect again
                    // never adds it twice).
                    if let Ok(list) = &saved
                        && edit.id.is_none()
                        && let Some(before) = &before
                        && let Some(made) =
                            list.connections.iter().find(|c| !before.contains(&c.id))
                    {
                        s.editing = Some(made.clone());
                    }
                    let result = match (saved, preferred) {
                        (Ok(_), Some(Err(e))) | (Err(e), _) => Err(e),
                        (Ok(list), _) => Ok(list),
                    };
                    match result {
                        Ok(_) => {
                            s.note = Some(DirectNote::Saved);
                            cx.emit(DirectEvent::Saved);
                        }
                        Err(e) => {
                            s.error = Some(save_error(&e, &l10n));
                            s.focus_invalid(Some(&e), window, cx);
                        }
                    }
                    cx.notify();
                });
            },
        )
        .detach();
    }

    fn choose_pem(&mut self, key: bool, window: &mut Window, cx: &mut Context<Self>) {
        let marker = if key { "PRIVATE KEY" } else { "CERTIFICATE" };
        let pick = pick_pem(marker, cx);
        cx.spawn_in(
            window,
            async move |this: WeakEntity<Self>, cx: &mut AsyncWindowContext| {
                let picked = pick.await;
                let _ = this.update(cx, |s, cx| {
                    let l10n = cx.l10n().clone();
                    match picked {
                        Ok(Some(file)) => {
                            if key {
                                s.private_key = Some(file);
                                s.clear_private_key = false;
                            } else {
                                s.certificate = Some(file);
                                s.clear_certificate = false;
                            }
                            s.error = None;
                        }
                        Ok(None) => {}
                        Err(PemError::NotPem) => {
                            s.error = Some(if key {
                                l10n.mutual_tls_private_key_pem_required()
                            } else {
                                l10n.mutual_tls_certificate_pem_required()
                            })
                        }
                        Err(PemError::Unreadable(e)) => s.error = Some(e),
                    }
                    cx.notify();
                });
            },
        )
        .detach();
    }

    fn add_header(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        // The fields are labelled; no placeholders restating the labels.
        let name = forms::input("X-Custom-Header", false, window, cx);
        let value = forms::input("", true, window, cx);
        self.headers.push(HeaderRow { name, value });
        if matches!(self.invalid, Some(Invalid::Header(_))) {
            self.invalid = None;
            self.error = None;
        }
        cx.notify();
    }

    fn listener(
        &self,
        cx: &Context<Self>,
        f: impl Fn(&mut Self, &mut Window, &mut Context<Self>) + 'static,
    ) -> ClickHandler {
        let this = cx.entity().downgrade();
        let f = Rc::new(f);
        Rc::new(move |_: &ClickEvent, window: &mut Window, cx: &mut App| {
            let f = f.clone();
            let _ = this.update(cx, |s, cx| f(s, window, cx));
        })
    }

    /// The connection's group: provider, name, address, how the key is
    /// sent, and the key.
    fn connection_group(
        &self,
        l10n: &L10n,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let mut rows: Vec<AnyElement> = vec![];
        if self.open_web_ui {
            rows.push(
                form_row(
                    l10n.desktop_provider_type(),
                    controls::value(l10n.desktop_open_ai_compatible(), cx),
                    cx,
                )
                .into_any_element(),
            );
        } else {
            let presets = Preset::ALL
                .iter()
                .map(|p| Choice::new(p.value(), p.label(l10n)))
                .collect();
            rows.push(
                form_row(
                    l10n.desktop_provider_type(),
                    controls::popup(
                        MENU_PRESET,
                        &l10n.desktop_provider_type(),
                        presets,
                        self.preset.value(),
                        self.busy,
                        window,
                        cx,
                    ),
                    cx,
                )
                .into_any_element(),
            );
            rows.push(
                field(
                    l10n.desktop_connection_name(),
                    &self.name,
                    None,
                    (self.invalid == Some(Invalid::Name))
                        .then(|| self.error.clone().map(Into::into))
                        .flatten(),
                    window,
                    cx,
                )
                .into_any_element(),
            );
        }
        let url_help: SharedString = match self.preset {
            Preset::OpenAi => l10n.direct_base_url_description(),
            Preset::OpenRouter => l10n.direct_open_router_base_url_description(),
            Preset::Ollama => l10n.desktop_direct_ollama_url_help(),
        }
        .into();
        let url_help = if self.secrets_stay_behind(cx) {
            l10n.desktop_direct_secrets_stay_behind().into()
        } else {
            url_help
        };
        rows.push(
            field(
                l10n.desktop_server_address(),
                &self.base_url,
                Some(url_help),
                (self.invalid == Some(Invalid::Url))
                    .then(|| self.error.clone().map(Into::into))
                    .flatten(),
                window,
                cx,
            )
            .into_any_element(),
        );
        let choices = self.auth_choices();
        let auth = controls::popup(
            MENU_AUTH,
            &l10n.desktop_direct_authentication(),
            choices
                .iter()
                .map(|a| Choice::new(a.value(), a.label(l10n)))
                .collect(),
            self.auth.value(),
            self.busy,
            window,
            cx,
        );
        rows.push(form_row(l10n.desktop_direct_authentication(), auth, cx).into_any_element());
        if self.auth != Auth::None {
            let help: Option<SharedString> = match self.auth {
                Auth::ApiKeyHeader => {
                    Some(l10n.direct_api_key_header_azure_only_description().into())
                }
                Auth::Bearer if choices.contains(&Auth::ApiKeyHeader) => {
                    Some(l10n.direct_bearer_description().into())
                }
                _ => None,
            };
            rows.push(
                field(
                    l10n.desktop_api_key(),
                    &self.api_key,
                    help,
                    (self.invalid == Some(Invalid::Key))
                        .then(|| self.error.clone().map(Into::into))
                        .flatten(),
                    window,
                    cx,
                )
                .into_any_element(),
            );
        }
        form_group(rows, cx).into_any_element()
    }

    /// Advanced Settings' groups.
    fn advanced_groups(
        &self,
        l10n: &L10n,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Vec<AnyElement> {
        let t = cx.conduit().clone();
        let mut groups = vec![];
        // The completion API (OpenAI-compatible servers; OpenRouter uses
        // Chat Completions for its own tools).
        if self.preset != Preset::Ollama {
            let mut rows: Vec<AnyElement> = vec![];
            if self.preset == Preset::OpenRouter {
                rows.push(
                    form_row(
                        l10n.desktop_completion_api(),
                        controls::value(l10n.direct_chat_completions(), cx),
                        cx,
                    )
                    .into_any_element(),
                );
            } else {
                rows.push(
                    form_row(
                        l10n.desktop_completion_api(),
                        controls::popup(
                            MENU_API,
                            &l10n.desktop_completion_api(),
                            vec![
                                Choice::new("chat", l10n.direct_chat_completions()),
                                Choice::new("responses", l10n.direct_responses()),
                            ],
                            if self.api_mode == DirectApiMode::Responses {
                                "responses"
                            } else {
                                "chat"
                            },
                            self.busy,
                            window,
                            cx,
                        ),
                        cx,
                    )
                    .into_any_element(),
                );
                rows.push(
                    field(
                        l10n.direct_api_version(),
                        &self.api_version,
                        Some(l10n.desktop_direct_api_version_help().into()),
                        None,
                        window,
                        cx,
                    )
                    .into_any_element(),
                );
            }
            let note: SharedString = match (self.preset, self.api_mode) {
                (Preset::OpenRouter, _) => l10n.desktop_direct_open_router_api_help().into(),
                (_, DirectApiMode::Responses) => l10n.desktop_direct_responses_help().into(),
                _ => l10n.direct_chat_completions_description().into(),
            };
            groups.push(
                div()
                    .flex()
                    .flex_col()
                    .gap(px(6.))
                    .child(form_group(rows, cx))
                    .child(forms::group_footer(note, cx))
                    .into_any_element(),
            );
        }

        // Custom headers: the saved ones by name, new ones typed.
        let saved: Vec<String> = self
            .editing
            .as_ref()
            .map(|c| c.custom_header_names.clone())
            .unwrap_or_default();
        let header_error = match self.invalid {
            Some(Invalid::Header(_)) => self.error.clone(),
            _ => None,
        };
        let remove = {
            let this = cx.entity().downgrade();
            Rc::new(move |i: usize, _: &mut Window, cx: &mut App| {
                let _ = this.update(cx, |s, cx| {
                    if i < s.headers.len() {
                        s.headers.remove(i);
                    }
                    if matches!(s.invalid, Some(Invalid::Header(_))) {
                        s.invalid = None;
                        s.error = None;
                    }
                    cx.notify();
                });
            })
        };
        let configured = (!saved.is_empty() && !self.clear_headers).then(|| {
            let clear = self.listener(cx, |s, _, cx| {
                s.clear_headers = true;
                cx.notify();
            });
            div()
                .flex()
                .items_center()
                .gap(px(8.))
                .child(
                    div()
                        .flex_1()
                        .min_w_0()
                        .text_size(px(t.metrics.small))
                        .text_color(t.roles.text_subtle)
                        .child(l10n.desktop_mcp_headers_configured(&saved.join(", "))),
                )
                .child(
                    Button::new("direct-headers-clear", l10n.clear())
                        .ghost()
                        .on_click(clear),
                )
        });
        groups.push(
            form_group(
                vec![
                    div()
                        .px(px(12.))
                        .py(px(8.))
                        .flex()
                        .flex_col()
                        .gap(px(8.))
                        .child(
                            setting_row(
                                l10n.desktop_custom_headers(),
                                Some(l10n.desktop_custom_headers_help().into()),
                                Button::new("direct-add-header", l10n.desktop_add_header())
                                    .icon(IconName::Plus)
                                    .on_click(self.listener(cx, |s, w, cx| s.add_header(w, cx))),
                                cx,
                            )
                            .px_0(),
                        )
                        .children(configured)
                        .child(header_rows(
                            &self.headers,
                            l10n.desktop_header_name().into(),
                            l10n.desktop_header_value().into(),
                            l10n.desktop_remove_header().into(),
                            remove,
                            cx,
                        ))
                        .when_some(header_error, |d, e| {
                            d.child(form_error("direct-header-error", e, cx))
                        })
                        .into_any_element(),
                ],
                cx,
            )
            .into_any_element(),
        );

        // The connection's models in the picker.
        groups.push(
            form_group(
                vec![
                    field(
                        l10n.direct_model_id_prefix(),
                        &self.model_prefix,
                        Some(l10n.desktop_direct_prefix_help().into()),
                        None,
                        window,
                        cx,
                    )
                    .into_any_element(),
                    field(
                        l10n.direct_model_tags(),
                        &self.tags,
                        Some(l10n.desktop_direct_tags_help().into()),
                        None,
                        window,
                        cx,
                    )
                    .into_any_element(),
                    div()
                        .id("direct-manual-models")
                        .px(px(12.))
                        .py(px(10.))
                        .flex()
                        .gap(px(12.))
                        .child(
                            div()
                                .flex_none()
                                .w(px(forms::LABEL_COLUMN))
                                .pt(px(4.))
                                .text_size(px(t.metrics.control))
                                .text_color(t.roles.text)
                                .child(l10n.direct_manual_model_ids()),
                        )
                        .child(
                            div()
                                .flex_1()
                                .min_w_0()
                                .flex()
                                .flex_col()
                                .gap(px(4.))
                                .child(Textarea::new(&self.manual_models).disabled(self.busy))
                                .child(
                                    div()
                                        .text_size(px(t.metrics.small))
                                        .line_height(relative(1.35))
                                        .text_color(t.roles.text_subtle)
                                        .child(l10n.direct_manual_model_ids_description()),
                                ),
                        )
                        .into_any_element(),
                ],
                cx,
            )
            .into_any_element(),
        );

        // Certificates: this Mac's own connections only.
        if !self.open_web_ui {
            let labels = PemLabels {
                choose: l10n.desktop_choose_file().into(),
                replace: l10n.desktop_replace_file().into(),
                clear: l10n.clear().into(),
            };
            let saved_cert = self
                .editing
                .as_ref()
                .and_then(|c| c.certificate_label.clone())
                .filter(|_| !self.clear_certificate)
                .map(|label| PemFile {
                    label,
                    pem: String::new(),
                });
            let saved_key = self
                .editing
                .as_ref()
                .and_then(|c| c.private_key_label.clone())
                .filter(|_| !self.clear_private_key)
                .map(|label| PemFile {
                    label,
                    pem: String::new(),
                });
            let shown_cert = self.certificate.clone().or(saved_cert);
            let shown_key = self.private_key.clone().or(saved_key);
            let mut rows: Vec<AnyElement> = vec![
                setting_row(
                    l10n.desktop_allow_unverified_certificate(),
                    Some(l10n.desktop_self_signed_help().into()),
                    Switch::new(
                        "direct-self-signed",
                        l10n.desktop_allow_unverified_certificate(),
                        self.self_signed,
                    )
                    .on_click(self.listener(cx, |s, _, cx| {
                        s.self_signed = !s.self_signed;
                        cx.notify();
                    })),
                    cx,
                )
                .into_any_element(),
                setting_row(
                    l10n.mutual_tls_select_certificate(),
                    Some(l10n.desktop_client_certificate_help().into()),
                    pem_picker(
                        "direct-certificate",
                        shown_cert.as_ref(),
                        PemLabels {
                            choose: labels.choose.clone(),
                            replace: labels.replace.clone(),
                            clear: labels.clear.clone(),
                        },
                        self.listener(cx, |s, w, cx| s.choose_pem(false, w, cx)),
                        self.listener(cx, |s, _, cx| {
                            s.certificate = None;
                            s.clear_certificate = s
                                .editing
                                .as_ref()
                                .is_some_and(|c| c.certificate_label.is_some());
                            cx.notify();
                        }),
                        cx,
                    ),
                    cx,
                )
                .into_any_element(),
                setting_row(
                    l10n.desktop_private_key(),
                    None,
                    pem_picker(
                        "direct-private-key",
                        shown_key.as_ref(),
                        labels,
                        self.listener(cx, |s, w, cx| s.choose_pem(true, w, cx)),
                        self.listener(cx, |s, _, cx| {
                            s.private_key = None;
                            s.clear_private_key = s
                                .editing
                                .as_ref()
                                .is_some_and(|c| c.private_key_label.is_some());
                            cx.notify();
                        }),
                        cx,
                    ),
                    cx,
                )
                .into_any_element(),
            ];
            if self.private_key.is_some() {
                rows.push(
                    field(
                        l10n.desktop_private_key_password(),
                        &self.key_password,
                        None,
                        None,
                        window,
                        cx,
                    )
                    .into_any_element(),
                );
            }
            groups.push(grouped(rows, cx).into_any_element());
        }
        groups
    }

    /// The Advanced Settings disclosure.
    fn advanced_toggle(&self, l10n: &L10n, cx: &mut Context<Self>) -> AnyElement {
        let t = cx.conduit().clone();
        let open = self.advanced;
        div()
            .id("direct-advanced")
            .role(Role::Button)
            .aria_label(l10n.desktop_advanced_settings())
            .aria_expanded(open)
            .self_start()
            .flex()
            .items_center()
            .gap(px(4.))
            .cursor_pointer()
            .text_size(px(t.metrics.control))
            .font_weight(FontWeight::MEDIUM)
            .text_color(t.roles.text)
            .keyboard_outline(4., cx)
            .child(conduit_components::assets::icon(
                if open {
                    IconName::ChevronDown
                } else {
                    IconName::ChevronRight
                },
                13.,
                t.roles.text_subtle,
            ))
            .child(l10n.desktop_advanced_settings())
            .on_click(cx.listener(|s, _, _, cx| {
                s.advanced = !s.advanced;
                cx.notify();
            }))
            .into_any_element()
    }

    /// The status line under the form: a test's result or "Saved".
    pub fn note_text(&self, l10n: &L10n) -> Option<(String, bool)> {
        self.note.as_ref().map(|n| match n {
            DirectNote::Tested(r) if r.reachable => (
                l10n.desktop_direct_test_ok(r.model_count.unwrap_or(0)),
                true,
            ),
            DirectNote::Tested(_) => (l10n.desktop_direct_test_failed(), false),
            DirectNote::Saved => (l10n.saved(), true),
        })
    }

    /// The form without buttons: the sheet adds its own along its bottom
    /// edge; onboarding adds Test and Connect under it ([`Render`]).
    pub fn body(&self, window: &mut Window, cx: &mut Context<Self>) -> AnyElement {
        let l10n = cx.l10n().clone();
        let mut d = div()
            .id("direct-form")
            .role(Role::Form)
            .aria_label(if self.editing.is_some() {
                l10n.desktop_edit_connection()
            } else {
                l10n.desktop_add_connection()
            })
            .flex()
            .flex_col()
            .gap(px(14.))
            .on_action(cx.listener(|s, a: &SettingsChoice, window, cx| s.on_choice(a, window, cx)));
        if !self.onboarding {
            d = d.child(
                grouped(
                    vec![
                        setting_row(
                            l10n.enabled_label(),
                            Some(l10n.direct_connection_enabled_subtitle().into()),
                            Switch::new("direct-enabled", l10n.enabled_label(), self.enabled)
                                .on_click(self.listener(cx, |s, _, cx| {
                                    s.enabled = !s.enabled;
                                    cx.notify();
                                })),
                            cx,
                        )
                        .into_any_element(),
                    ],
                    cx,
                )
                .into_any_element(),
            );
        }
        d = d.child(self.connection_group(&l10n, window, cx));
        if self.open_web_ui && self.editing.as_ref().is_some_and(|c| !c.compatible) {
            d = d.child(form_error(
                "direct-unsupported",
                l10n.open_web_ui_direct_connection_unsupported_auth(),
                cx,
            ));
        }
        d = d.child(self.advanced_toggle(&l10n, cx));
        if self.advanced {
            d = d.children(self.advanced_groups(&l10n, window, cx));
        }
        // A field's own error is drawn under it; the rest here.
        if let Some(e) = self.error.clone().filter(|_| self.invalid.is_none()) {
            d = d.child(form_error("direct-error", e, cx));
        }
        if let Some((text, ok)) = self.note_text(&l10n) {
            d = d.child(form_note(text, ok, cx));
        }
        d.into_any_element()
    }
}

/// One model id per line, blanks dropped.
pub fn lines(text: &str) -> Vec<String> {
    text.lines()
        .map(str::trim)
        .filter(|l| !l.is_empty())
        .map(str::to_string)
        .collect()
}

/// Whether `value`, normalized as Test and Save send it ([`normalize_url`]:
/// no scheme means https), is the OpenAI platform's own API (`https`, the
/// default port, `api.openai.com` or a host under it): core's
/// `isOpenAiPlatformBaseUrl`, which the editor needs on every keystroke.
pub fn is_openai_platform_url(value: &str) -> bool {
    let Some(url) = normalize_url(value).and_then(|n| url::Url::parse(&n).ok()) else {
        return false;
    };
    if url.scheme() != "https"
        || url.port().is_some_and(|p| p != 443)
        || !url.username().is_empty()
        || url.password().is_some()
        || url.query().is_some()
        || url.fragment().is_some()
    {
        return false;
    }
    let host = url.host_str().unwrap_or_default().to_ascii_lowercase();
    host == "api.openai.com" || host.ends_with(".api.openai.com")
}

/// What a refused save says.
fn save_error(e: &RpcError, l10n: &L10n) -> String {
    match e.code {
        ErrorCode::Conflict => l10n.direct_connection_save_conflict(),
        ErrorCode::Unsupported => l10n.open_web_ui_direct_connection_unsupported_auth(),
        _ => words::connect_error(e, l10n),
    }
}

impl Render for DirectView {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        // The address as it is now, however it got there (typed, pasted,
        // set by a preset).
        self.follow_url_mode(cx);
        let l10n = cx.l10n().clone();
        let body = self.body(window, cx);
        if !self.onboarding {
            return div().child(body);
        }
        // First run: one verb on every connection form ("Connect").
        div().flex().flex_col().gap(px(14.)).child(body).child(
            div()
                .flex()
                .justify_end()
                .gap(px(8.))
                .child(
                    Button::new(
                        "direct-test",
                        if self.testing {
                            l10n.desktop_testing()
                        } else {
                            l10n.desktop_test_connection()
                        },
                    )
                    .disabled(!self.can_save(cx))
                    .on_click(self.listener(cx, |s, w, cx| s.test(w, cx))),
                )
                .child(
                    Button::new(
                        "direct-save",
                        if self.busy {
                            l10n.desktop_connecting()
                        } else {
                            l10n.desktop_connect()
                        },
                    )
                    .primary()
                    .disabled(!self.can_save(cx))
                    .on_click(self.listener(cx, |s, w, cx| s.save(w, cx))),
                ),
        )
    }
}

#[cfg(test)]
mod tests {
    use conduit_protocol::methods;
    use gpui_kit::{TestAppContext, VisualTestContext};
    use serde_json::json;

    use super::*;
    use crate::stores::rpc::fake::FakeDaemon;

    fn connection(id: &str) -> DirectConnectionSummary {
        serde_json::from_value(json!({
            "id": id, "name": "Lab", "kind": "openai", "baseUrl": "http://127.0.0.1:11434/v1",
            "apiMode": "responses", "apiVersion": "2025-01-01", "apiKeyHeader": true,
            "modelIdPrefix": "lab/", "enabled": false, "hasApiKey": true,
            "customHeaderNames": [], "manualModelIds": ["synthetic-model"],
            "allowSelfSignedCertificates": false, "openRouter": false, "ollamaCloud": false,
            "openWebUi": false, "compatible": true, "tags": ["work"]
        }))
        .unwrap()
    }

    fn list(connections: Vec<DirectConnectionSummary>) -> DirectConnectionList {
        DirectConnectionList {
            connections,
            ..Default::default()
        }
    }

    fn bench(
        cx: &mut TestAppContext,
        make: impl FnOnce(Stores, &mut Window, &mut Context<DirectView>) -> DirectView + 'static,
    ) -> (FakeDaemon, Entity<DirectView>, &mut VisualTestContext) {
        let daemon = FakeDaemon::new();
        let scratch = std::env::temp_dir().join(format!("conduit-direct-{}", std::process::id()));
        let stores = cx.update(|cx| {
            crate::views::test_globals(cx);
            Stores::for_test(daemon.rpc(), &scratch, cx)
        });
        let (view, vcx) = cx.add_window_view(move |window, cx| make(stores, window, cx));
        (daemon, view, vcx)
    }

    /// A saved connection switched to OpenRouter keeps its address, so Save
    /// asks for OpenRouter's (the core tells OpenRouter apart by it), as on a
    /// phone: it is never saved as an OpenAI-compatible server instead.
    #[gpui_kit::test]
    fn openrouter_takes_only_openrouters_address(cx: &mut TestAppContext) {
        let mut elsewhere = connection("c1");
        elsewhere.base_url = "https://llm.example.com/v1".into();
        let (daemon, view, vcx) = bench(cx, move |stores, window, cx| {
            DirectView::editing(stores, elsewhere, window, cx)
        });
        daemon.returns::<methods::DirectSave>(list(vec![connection("c1")]));
        view.update_in(vcx, |v, window, cx| {
            v.set_preset(Preset::OpenRouter, window, cx);
            v.save(window, cx);
        });
        vcx.run_until_parked();
        assert!(
            daemon.calls::<methods::DirectSave>().is_empty(),
            "saved as OpenRouter with another server's address"
        );
        view.read_with(vcx, |v, _| assert_eq!(v.invalid, Some(Invalid::Url)));
        // OpenRouter's own address (or its EU one) goes.
        view.update_in(vcx, |v, window, cx| {
            v.base_url.update(cx, |i, cx| {
                i.set_value("https://eu.openrouter.ai/api/v1", window, cx)
            });
            v.api_key
                .update(cx, |i, cx| i.set_value("sk-or-synthetic", window, cx));
            v.save(window, cx);
        });
        vcx.run_until_parked();
        assert_eq!(daemon.calls::<methods::DirectSave>().len(), 1);
    }

    #[gpui_kit::test]
    fn renaming_a_connection_keeps_its_other_settings(cx: &mut TestAppContext) {
        let (daemon, view, vcx) = bench(cx, |stores, window, cx| {
            DirectView::editing(stores, connection("c1"), window, cx)
        });
        daemon.returns::<methods::DirectSave>(list(vec![connection("c1")]));
        view.update_in(vcx, |v, window, cx| {
            v.name
                .update(cx, |i, cx| i.set_value("Lab two", window, cx));
            v.save(window, cx);
        });
        vcx.run_until_parked();
        let sent = &daemon.calls::<methods::DirectSave>()[0];
        assert_eq!(sent["id"], "c1");
        assert_eq!(sent["name"], "Lab two");
        assert_eq!(sent["apiMode"], "responses");
        assert_eq!(sent["apiVersion"], "2025-01-01");
        assert_eq!(sent["apiKeyHeader"], true);
        assert_eq!(sent["modelIdPrefix"], "lab/");
        assert_eq!(sent["enabled"], false);
        assert_eq!(sent["manualModelIds"], json!(["synthetic-model"]));
        assert_eq!(sent["tags"], json!(["work"]));
    }

    /// A connection kept in the account with no key signs in with none:
    /// renaming it asks for no key it never had.
    #[gpui_kit::test]
    fn an_account_connection_without_a_key_renames_without_one(cx: &mut TestAppContext) {
        let mut keyless = connection("c2");
        keyless.open_web_ui = true;
        keyless.has_api_key = false;
        keyless.api_key_header = false;
        let (daemon, view, vcx) = bench(cx, move |stores, window, cx| {
            DirectView::editing(stores, keyless, window, cx)
        });
        daemon.returns::<methods::DirectSave>(list(vec![connection("c2")]));
        view.update_in(vcx, |v, window, cx| {
            v.name
                .update(cx, |i, cx| i.set_value("Lab two", window, cx));
            v.save(window, cx);
        });
        vcx.run_until_parked();
        let sent = daemon.calls::<methods::DirectSave>();
        assert_eq!(sent.len(), 1, "the rename asked for a key");
        assert_eq!(sent[0]["name"], "Lab two");
        assert!(sent[0].get("apiKey").is_none_or(|k| k.is_null()));
    }

    fn new_connection(
        daemon: &FakeDaemon,
        view: &Entity<DirectView>,
        vcx: &mut VisualTestContext,
    ) -> Vec<serde_json::Value> {
        daemon.returns::<methods::DirectSave>(list(vec![connection("old"), connection("made")]));
        daemon.once::<methods::DirectSetPreferred>(Err(conduit_daemon::protocol::error(
            "rpc.timeout",
            "slow",
        )));
        daemon.returns::<methods::DirectSetPreferred>(list(vec![connection("made")]));
        view.update_in(vcx, |v, window, cx| {
            // No key to ask for: a local server.
            v.auth = Auth::None;
            v.base_url.update(cx, |i, cx| {
                i.set_value("http://127.0.0.1:11434/v1", window, cx)
            });
            v.save(window, cx);
        });
        vcx.run_until_parked();
        view.update_in(vcx, |v, window, cx| v.save(window, cx));
        vcx.run_until_parked();
        daemon.calls::<methods::DirectSave>()
    }

    #[gpui_kit::test]
    fn without_a_list_a_retry_never_takes_over_another_connection(cx: &mut TestAppContext) {
        let (daemon, view, vcx) = bench(cx, |stores, window, cx| {
            DirectView::new(stores, true, window, cx)
        });
        daemon.on::<methods::DirectList>(|_| {
            Err(conduit_daemon::protocol::error("rpc.timeout", "slow"))
        });
        let sent = new_connection(&daemon, &view, vcx);
        assert_eq!(sent.len(), 2);
        assert_ne!(
            sent[1]["id"], "old",
            "another connection was taken for the new one"
        );
    }

    #[gpui_kit::test]
    fn a_save_that_went_through_is_not_added_twice(cx: &mut TestAppContext) {
        let (daemon, view, vcx) = bench(cx, |stores, window, cx| {
            DirectView::new(stores, true, window, cx)
        });
        daemon.returns::<methods::DirectList>(list(vec![connection("old")]));
        let sent = new_connection(&daemon, &view, vcx);
        assert_eq!(sent.len(), 2);
        assert_eq!(sent[0]["id"], serde_json::Value::Null);
        assert_eq!(
            sent[1]["id"], "made",
            "the second Connect edits what the first made"
        );
    }

    #[test]
    fn the_openai_platform_is_known_by_its_own_address() {
        for yes in [
            "https://api.openai.com/v1",
            " https://API.openai.com/v1/ ",
            "https://api.openai.com:443/v1",
            "https://eu.api.openai.com/v1",
            // As Save sends them: no scheme is https.
            "api.openai.com/v1",
            " API.openai.com/v1 ",
        ] {
            assert!(is_openai_platform_url(yes), "{yes}");
        }
        for no in [
            "http://api.openai.com/v1",
            "https://api.openai.com:8443/v1",
            "https://user@api.openai.com/v1",
            "https://api.openai.com/v1?x=1",
            "https://api.openai.com.example.net/v1",
            "https://openrouter.ai/api/v1",
            "openrouter.ai/api/v1",
            "",
        ] {
            assert!(!is_openai_platform_url(no), "{no}");
        }
    }

    #[test]
    fn manual_model_ids_are_one_per_line() {
        assert_eq!(
            lines(" model-a \n\n model-b\n"),
            vec!["model-a".to_string(), "model-b".to_string()]
        );
        assert!(lines("  \n").is_empty());
    }

    #[test]
    fn presets_round_trip_and_name_their_kind() {
        for p in Preset::ALL {
            assert_eq!(Preset::from_value(p.value()), Some(p));
        }
        assert_eq!(Preset::Ollama.kind(), DirectKind::Ollama);
        assert_eq!(Preset::OpenRouter.kind(), DirectKind::Openai);
        assert_eq!(Preset::OpenRouter.default_url(), Some(OPEN_ROUTER_URL));
        assert_eq!(Preset::from_value("azure"), None);
        for a in [Auth::Bearer, Auth::ApiKeyHeader, Auth::None] {
            assert_eq!(Auth::from_value(a.value()), Some(a));
        }
    }
}
