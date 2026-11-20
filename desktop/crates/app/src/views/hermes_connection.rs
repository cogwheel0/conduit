//! A Hermes connection's editor: a window sheet on Settings, as the
//! phone's connection page (`hermes_settings_page.dart`) and Mail's
//! account sheet present one.
//!
//! Name, server URL and connection type; for an API server its key and
//! its memory key; for a Desktop Gateway how it signs in (Hermes Sign-In
//! in the browser, its legacy session token, which only this form sends,
//! or the dashboard's own sign-in in a window of the app's) and its profile,
//! picked from the gateway's list (Refresh reads it again; when it cannot
//! be read the profile stays and the menu says why, as on a phone); the
//! headers every request carries (Cloudflare Access and the like) and
//! whether an unverified certificate is accepted. Test Connection tries
//! the form without saving it (and names the connection after what the
//! server reports, when it was left unnamed); Save keeps it. A saved one
//! that is not in use offers Use This Connection; Delete… asks first.
//! Credentials about to travel unencrypted are asked for, as on a phone.
//! Secrets are never shown: a kept one says so in its field's placeholder,
//! a saved header's value too.

use std::rc::Rc;
use std::time::Duration;

use conduit_components::ActiveConduitTheme as _;
use conduit_components::assets::IconName;
use conduit_components::views::kit::{
    Button, IconButton, Segment, Segmented, Switch, grouped_section, setting_row,
};
use conduit_daemon::RpcError;
use conduit_protocol::{
    ErrorCode, HermesAccessHeaderEdit, HermesConnectionDto, HermesConnectionEdit,
    HermesConnections, HermesDashboardStart, HermesRef, HermesSignInRequest, NoParams, NoticeLevel,
    methods,
};
use gpui_kit::component::input::{InputEvent, InputState};
use gpui_kit::prelude::*;
use gpui_kit::{
    AnyElement, App, AsyncApp, Context, Entity, EntityId, FontWeight, Role, SharedString,
    Subscription, WeakEntity, Window, div, px, relative,
};

use crate::actions::SettingsChoice;
use crate::l10n::{ActiveL10n as _, L10n};
use crate::shell::sheet::{SheetSpec, present_sheet};
use crate::shell::sso::{self, DashboardOutcome};
use crate::stores::Stores;
use crate::stores::hermes_admin;
use crate::views::forms::{self, HeaderRow};
use crate::views::settings::controls::{self, Choice};
use crate::views::sheet::{self, SheetBody};
use crate::views::words;

/// The sheet's width: room for the three ways a Desktop Gateway signs in.
pub const WIDTH: f32 = 580.;
/// The `SettingsChoice` menu the profile pop-up sends.
pub const PROFILE_MENU: &str = "hermes-connection-profile";
/// The profile menu's Refresh Profiles item.
const REFRESH: &str = "\u{0}refresh";
/// How many headers a connection may send (the core's limit).
const MAX_HEADERS: usize = 10;
/// How long the form rests before its profiles are read again after an
/// edit that changes who is asking (the phone reads at once; a URL typed
/// here would ask once a keystroke).
const PROFILES_SETTLE: Duration = Duration::from_millis(600);

/// Opens the editor for connection `id` (a new one when `None`) on the
/// window `window` (Settings).
pub fn open(stores: &Stores, id: Option<String>, window: &mut Window, cx: &mut App) {
    let existing = id.and_then(|id| {
        stores
            .hermes_admin
            .read(cx)
            .connections
            .as_ref()?
            .connections
            .iter()
            .find(|c| c.id == id)
            .cloned()
    });
    let stores = stores.clone();
    sheet::open(window, WIDTH, cx, move |w, cx| {
        HermesConnectionSheet::new(stores, existing, w, cx)
    });
}

/// How a Desktop Gateway signs in.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum Auth {
    /// Hermes Sign-In in the browser (native PKCE).
    Native,
    /// The gateway's session token.
    #[default]
    Token,
    /// The dashboard's own sign-in, in a window of the app's.
    Dashboard,
}

impl Auth {
    fn from_kind(kind: &str) -> Self {
        match kind {
            "nativePkce" => Self::Native,
            "dashboardCookie" => Self::Dashboard,
            _ => Self::Token,
        }
    }

    pub fn kind(self) -> &'static str {
        match self {
            Self::Native => "nativePkce",
            Self::Token => "legacyToken",
            Self::Dashboard => "dashboardCookie",
        }
    }

    /// Its segment, in the order the control shows them.
    fn index(self) -> usize {
        match self {
            Self::Native => 0,
            Self::Token => 1,
            Self::Dashboard => 2,
        }
    }

    fn from_index(i: usize) -> Self {
        match i {
            0 => Self::Native,
            2 => Self::Dashboard,
            _ => Self::Token,
        }
    }
}

/// What the form holds, to tell an edited form from an untouched one.
#[derive(Clone, Debug, Default, PartialEq)]
struct Form {
    name: String,
    url: String,
    desktop: bool,
    auth: Auth,
    api_key: String,
    memory_key: String,
    memory_cleared: bool,
    token: String,
    profile: String,
    headers: Vec<(String, String)>,
    self_signed: bool,
}

impl Form {
    /// What counts as saved once a Save of `sent` answered: a field as it
    /// shows now (`now`) where it was not touched while the Save was out
    /// (`before` still equals `sent`), else what was sent, so words typed
    /// meanwhile stay to save.
    fn saved(sent: &Form, before: &Form, now: Form) -> Form {
        fn pick<T: PartialEq + Clone>(sent: &T, before: &T, now: T) -> T {
            if before == sent { now } else { sent.clone() }
        }
        Form {
            name: pick(&sent.name, &before.name, now.name),
            url: pick(&sent.url, &before.url, now.url),
            desktop: pick(&sent.desktop, &before.desktop, now.desktop),
            auth: pick(&sent.auth, &before.auth, now.auth),
            api_key: pick(&sent.api_key, &before.api_key, now.api_key),
            memory_key: pick(&sent.memory_key, &before.memory_key, now.memory_key),
            memory_cleared: pick(
                &sent.memory_cleared,
                &before.memory_cleared,
                now.memory_cleared,
            ),
            token: pick(&sent.token, &before.token, now.token),
            profile: pick(&sent.profile, &before.profile, now.profile),
            headers: pick(&sent.headers, &before.headers, now.headers),
            self_signed: pick(&sent.self_signed, &before.self_signed, now.self_signed),
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub enum Note {
    Tested { ok: bool, text: String },
    SigningIn,
    SigningInDashboard,
}

/// The gateway's profiles, as the form last read them.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Profiles {
    pub names: Vec<String>,
    pub loading: bool,
    /// Why none could be read: `noUrl`, `testFirst`, `empty`,
    /// `signInFirst` (the daemon's codes).
    pub issue: Option<String>,
}

pub struct HermesConnectionSheet {
    stores: Stores,
    /// The saved connection edited; `None` for a new one until it is saved.
    pub existing: Option<HermesConnectionDto>,
    pub name: Entity<InputState>,
    pub url: Entity<InputState>,
    pub api_key: Entity<InputState>,
    pub memory_key: Entity<InputState>,
    /// The saved memory key is to be cleared at the next Save.
    pub memory_cleared: bool,
    pub token: Entity<InputState>,
    pub desktop: bool,
    pub auth: Auth,
    /// The profile chosen (the gateway's, or the one saved).
    pub profile: String,
    pub profiles: Profiles,
    /// Who the last profile read asked as (URL, sign-in, token, headers),
    /// and its turn: an answer for an older turn is dropped.
    profiles_asked: Option<String>,
    profiles_turn: u64,
    /// Bumped by each profile picked by hand: a profile read asked before
    /// a pick lists its profiles but leaves the pick alone.
    profile_picks: u64,
    pub headers: Vec<HeaderRow>,
    /// For each header row, the saved header it shows (its value is kept
    /// while the row's value is left blank).
    header_saved: Vec<Option<String>>,
    pub header_error: Option<String>,
    header_error_row: Option<usize>,
    pub self_signed: bool,
    /// The user agreed to send this URL's credentials unencrypted.
    plain_http_ok: Option<String>,
    initial: Form,
    pub busy: bool,
    pub note: Option<Note>,
    pub error: Option<String>,
    _subscriptions: Vec<Subscription>,
}

impl HermesConnectionSheet {
    pub fn new(
        stores: Stores,
        existing: Option<HermesConnectionDto>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Self {
        let l = cx.l10n().clone();
        let name = forms::input(l.desktop_optional(), false, window, cx);
        let url = forms::input("http://127.0.0.1:8642", false, window, cx);
        let api_key = forms::input(l.hermes_api_key_placeholder(), true, window, cx);
        let memory_key = forms::input(l.desktop_optional(), true, window, cx);
        let token = forms::input(l.hermes_legacy_session_token_hint(), true, window, cx);
        let mut this = Self {
            stores,
            existing: existing.clone(),
            name,
            url,
            api_key,
            memory_key,
            memory_cleared: false,
            token,
            desktop: false,
            auth: Auth::Token,
            profile: "default".into(),
            profiles: Profiles::default(),
            profiles_asked: None,
            profiles_turn: 0,
            profile_picks: 0,
            headers: vec![],
            header_saved: vec![],
            header_error: None,
            header_error_row: None,
            self_signed: false,
            plain_http_ok: None,
            initial: Form::default(),
            busy: false,
            note: None,
            error: None,
            _subscriptions: vec![],
        };
        for input in [
            this.name.clone(),
            this.url.clone(),
            this.api_key.clone(),
            this.memory_key.clone(),
            this.token.clone(),
        ] {
            this.watch(&input, window, cx);
        }
        if let Some(c) = existing {
            this.desktop = c.mode == "desktop";
            this.auth = Auth::from_kind(&c.desktop_auth_kind);
            this.self_signed = c.allow_self_signed_certificates;
            this.profile = c.desktop_profile.clone();
            let (n, u) = (c.name.clone(), c.base_url.clone());
            this.name.update(cx, |i, cx| i.set_value(n, window, cx));
            this.url.update(cx, |i, cx| i.set_value(u, window, cx));
            if c.has_api_key {
                forms::set_hint(&this.api_key, l.hermes_configured_replace_placeholder(), cx);
            }
            if c.has_memory_key {
                forms::set_hint(
                    &this.memory_key,
                    l.hermes_configured_replace_placeholder(),
                    cx,
                );
            }
            if c.has_legacy_token {
                forms::set_hint(&this.token, l.hermes_configured_replace_placeholder(), cx);
            }
            // A saved header shows its name; its value stays in the daemon
            // and is kept while the field is left blank.
            for saved in &c.access_header_names {
                let row = this.header_row(window, cx);
                let saved_name = saved.clone();
                row.name
                    .update(cx, |i, cx| i.set_value(saved_name, window, cx));
                forms::set_hint(&row.value, l.hermes_configured_replace_placeholder(), cx);
                this.headers.push(row);
                this.header_saved.push(Some(saved.clone()));
            }
        } else {
            // A new connection: a Desktop Gateway signing in with its token
            // is what a gateway on this Mac asks for.
            this.desktop = true;
            this.auth = Auth::Token;
        }
        this.initial = this.form(cx);
        let focus = this.url.clone();
        focus.update(cx, |i, cx| i.focus(window, cx));
        // As the phone's section, the profiles are read when it opens.
        if this.desktop && this.existing.is_some() {
            this.load_profiles(window, cx);
        }
        this
    }

    /// Follows `input`: Return saves, an edit clears what was said about the
    /// form and, when it changes who asks, reads the profiles again.
    fn watch(&mut self, input: &Entity<InputState>, window: &mut Window, cx: &mut Context<Self>) {
        self._subscriptions.push(cx.subscribe_in(
            input,
            window,
            |this: &mut Self, _, e: &InputEvent, window, cx| match e {
                InputEvent::PressEnter { .. } if this.can_save(cx) => this.save(window, cx),
                InputEvent::Change => {
                    this.note = None;
                    this.error = None;
                    this.header_error = None;
                    this.header_error_row = None;
                    this.profiles_changed(window, cx);
                    cx.notify();
                }
                _ => {}
            },
        ));
    }

    /// A new header row (name, then its value, masked as on a phone).
    fn header_row(&mut self, window: &mut Window, cx: &mut Context<Self>) -> HeaderRow {
        // The fields are labelled; no placeholders restating the labels.
        let name = forms::input("", false, window, cx);
        let value = forms::input("", true, window, cx);
        self.watch(&name, window, cx);
        self.watch(&value, window, cx);
        HeaderRow { name, value }
    }

    fn form(&self, cx: &App) -> Form {
        Form {
            name: forms::text(&self.name, cx),
            url: forms::text(&self.url, cx),
            desktop: self.desktop,
            auth: self.auth,
            api_key: forms::raw(&self.api_key, cx),
            memory_key: forms::raw(&self.memory_key, cx),
            memory_cleared: self.memory_cleared,
            token: forms::raw(&self.token, cx),
            profile: self.profile.clone(),
            headers: self
                .headers
                .iter()
                .map(|r| (forms::raw(&r.name, cx), forms::raw(&r.value, cx)))
                .collect(),
            self_signed: self.self_signed,
        }
    }

    fn dirty(&self, cx: &App) -> bool {
        self.form(cx) != self.initial
    }

    pub fn can_save(&self, cx: &App) -> bool {
        !self.busy && forms::filled(&[&self.url], cx)
    }

    /// The header rows as the daemon takes them, or `Ok(None)` when they
    /// are as saved; a row the form can already refuse is `Err` with its
    /// index and the reason.
    fn header_edits(
        &self,
        cx: &App,
    ) -> Result<Option<Vec<HermesAccessHeaderEdit>>, (usize, String)> {
        let l = cx.l10n().clone();
        let mut out = vec![];
        for (i, row) in self.headers.iter().enumerate() {
            let name = forms::raw(&row.name, cx).trim().to_string();
            let value = forms::raw(&row.value, cx);
            let saved = self.header_saved.get(i).cloned().flatten();
            if name.is_empty() && value.is_empty() && saved.is_none() {
                continue;
            }
            if name.is_empty() {
                return Err((i, l.desktop_direct_header_name_required()));
            }
            let token = name
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b"!#$%&'*+-.^_`|~".contains(&b));
            if !token {
                return Err((i, l.header_name_invalid_chars()));
            }
            if out
                .iter()
                .any(|h: &HermesAccessHeaderEdit| h.name.eq_ignore_ascii_case(&name))
            {
                return Err((i, l.desktop_header_already_exists(&name)));
            }
            let keep = value.is_empty() && saved.is_some();
            out.push(HermesAccessHeaderEdit {
                saved_name: saved.filter(|s| keep && s != &name),
                value: (!keep).then_some(value),
                name,
            });
        }
        if out.len() > MAX_HEADERS {
            return Err((MAX_HEADERS, l.desktop_hermes_headers_too_many()));
        }
        // As saved only when the rows are the daemon's headers, each kept
        // under its own name, in order: a header removed (the last one too)
        // or renamed is a change to send.
        let held: &[String] = self
            .existing
            .as_ref()
            .map_or(&[], |c| c.access_header_names.as_slice());
        let unchanged = out.len() == held.len()
            && out
                .iter()
                .zip(held)
                .all(|(h, name)| h.value.is_none() && h.saved_name.is_none() && &h.name == name);
        Ok((!unchanged).then_some(out))
    }

    /// The edit the form makes, or why it cannot be sent (said in the form
    /// when `say`).
    fn edit_with(&mut self, say: bool, cx: &mut Context<Self>) -> Option<HermesConnectionEdit> {
        let l = cx.l10n().clone();
        let Some(base_url) = forms::normalize_url(&forms::text(&self.url, cx)) else {
            if say {
                self.error = Some(l.desktop_invalid_server_address());
                cx.notify();
            }
            return None;
        };
        let access_headers = match self.header_edits(cx) {
            Ok(headers) => headers,
            Err((row, message)) => {
                if say {
                    self.header_error = Some(message);
                    self.header_error_row = Some(row);
                    cx.notify();
                }
                return None;
            }
        };
        let name = forms::text(&self.name, cx);
        let key = forms::raw(&self.api_key, cx);
        let memory = forms::raw(&self.memory_key, cx);
        let token = forms::raw(&self.token, cx);
        let renamed = self.existing.as_ref().is_none_or(|c| c.name != name);
        Some(HermesConnectionEdit {
            id: self.existing.as_ref().map(|c| c.id.clone()),
            // Untouched, the saved name stays; empty, the server's host.
            name: renamed.then_some(name),
            allow_plain_http: self.plain_http_ok.as_deref() == Some(base_url.as_str()),
            base_url,
            mode: if self.desktop { "desktop" } else { "responses" }.into(),
            desktop_auth_kind: self.auth.kind().into(),
            desktop_profile: if self.profile.is_empty() {
                "default".into()
            } else {
                self.profile.clone()
            },
            // A blank secret field keeps the saved secret.
            api_key: (!self.desktop && !key.trim().is_empty()).then_some(key),
            // A key typed replaces it; cleared, the daemon makes one.
            memory_key: if self.desktop {
                None
            } else if !memory.trim().is_empty() {
                Some(memory)
            } else {
                self.memory_cleared.then(String::new)
            },
            legacy_token: (self.desktop && self.auth == Auth::Token && !token.trim().is_empty())
                .then_some(token),
            allow_self_signed_certificates: self.self_signed,
            access_headers,
        })
    }

    fn edit(&mut self, cx: &mut Context<Self>) -> Option<HermesConnectionEdit> {
        self.edit_with(true, cx)
    }

    /// The field to focus for what the form refused: the header row it
    /// named, else the server URL.
    fn invalid_field(&self) -> Entity<InputState> {
        self.header_error
            .as_ref()
            .and(self.header_error_row)
            .and_then(|i| self.headers.get(i))
            .map(|r| r.name.clone())
            .unwrap_or_else(|| self.url.clone())
    }

    /// Who reading the profiles asks as: the address, the sign-in and its
    /// token, the headers (the phone's `_authDraftIdentity`).
    fn profiles_asker(&self, cx: &App) -> String {
        let headers: Vec<String> = self
            .headers
            .iter()
            .map(|r| {
                format!(
                    "{}={}",
                    forms::raw(&r.name, cx).trim().to_ascii_lowercase(),
                    forms::raw(&r.value, cx)
                )
            })
            .collect();
        format!(
            "{}\u{0}{}\u{0}{}\u{0}{}",
            forms::normalize_url(&forms::text(&self.url, cx)).unwrap_or_default(),
            self.auth.kind(),
            if self.auth == Auth::Token {
                forms::raw(&self.token, cx)
            } else {
                String::new()
            },
            headers.join("\u{0}"),
        )
    }

    /// After an edit: the profiles are read again, once the form rests,
    /// when it changed who asks.
    fn profiles_changed(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if !self.desktop || self.profiles_asked.is_none() {
            return;
        }
        if self.profiles_asked.as_deref() == Some(self.profiles_asker(cx).as_str()) {
            return;
        }
        self.profiles_turn += 1;
        let turn = self.profiles_turn;
        self.profiles = Profiles::default();
        let handle = window.window_handle();
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            cx.background_executor().timer(PROFILES_SETTLE).await;
            let _ = handle.update(cx, |_, window, cx| {
                let _ = this.update(cx, |s, cx| {
                    if s.profiles_turn == turn {
                        s.load_profiles(window, cx);
                    }
                });
            });
        })
        .detach();
    }

    /// Reads the gateway's profiles for the form (Refresh Profiles), as the
    /// phone's section: a profile no longer listed gives way to `default`,
    /// else the first; none listed keeps it and says why.
    pub fn load_profiles(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.profiles_turn += 1;
        let turn = self.profiles_turn;
        let picks = self.profile_picks;
        self.profiles_asked = Some(self.profiles_asker(cx));
        let Some(edit) = self.edit_with(false, cx) else {
            let url_ok = forms::normalize_url(&forms::text(&self.url, cx)).is_some();
            self.profiles = Profiles {
                names: vec![],
                loading: false,
                issue: (!url_ok).then(|| "noUrl".into()),
            };
            cx.notify();
            return;
        };
        let call = self
            .stores
            .connection
            .read(cx)
            .rpc()
            .call::<methods::HermesConnectionsProfiles>(&edit);
        self.profiles.loading = true;
        cx.notify();
        let handle = window.window_handle();
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result = call.await;
            let _ = handle.update(cx, |_, _, cx| {
                let _ = this.update(cx, |s, cx| {
                    if s.profiles_turn != turn {
                        return;
                    }
                    s.profiles = match result {
                        Ok(r) => {
                            if s.profile_picks == picks
                                && let Some(selected) = r.selected.filter(|p| *p != s.profile)
                            {
                                s.profile = selected;
                            }
                            Profiles {
                                names: r.profiles,
                                loading: false,
                                issue: r.issue,
                            }
                        }
                        Err(e) => {
                            log::info!("hermes profiles: {e}");
                            Profiles {
                                names: vec![],
                                loading: false,
                                issue: Some("signInFirst".into()),
                            }
                        }
                    };
                    cx.notify();
                });
            });
        })
        .detach();
    }

    fn on_choice(&mut self, action: &SettingsChoice, window: &mut Window, cx: &mut Context<Self>) {
        if action.menu != PROFILE_MENU {
            return;
        }
        self.choose_profile(&action.value, window, cx);
    }

    /// A pick from the profile menu: a profile, or Refresh Profiles.
    pub fn choose_profile(&mut self, value: &str, window: &mut Window, cx: &mut Context<Self>) {
        if value == REFRESH {
            self.load_profiles(window, cx);
        } else {
            self.profile = value.to_string();
            self.profile_picks += 1;
            self.note = None;
        }
        cx.notify();
    }

    /// Clear (by the memory key): the saved key goes at the next Save, and
    /// the daemon makes one, as before a key was set. A replacement typed
    /// before goes too; one typed after is the key saved.
    /// The Mode control: the API (`desktop` false) or a Desktop Gateway.
    /// A Gateway Save carries no memory key, so switching to a Gateway
    /// discards the memory-key edit still pending (a Clear and any
    /// replacement typed): none outlives a Save that did not carry it, and
    /// the discarded edit no longer counts as unsaved.
    pub fn choose_mode(&mut self, desktop: bool, window: &mut Window, cx: &mut Context<Self>) {
        if desktop {
            self.discard_memory_key_edit(window, cx);
        }
        self.desktop = desktop;
        self.note = None;
        if self.desktop && self.profiles_asked.is_none() && self.existing.is_some() {
            self.load_profiles(window, cx);
        }
        cx.notify();
    }

    /// The memory key field as the sheet opened it: empty, saying a saved
    /// key is kept, with no Clear pending.
    fn discard_memory_key_edit(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.memory_cleared = false;
        self.memory_key
            .update(cx, |i, cx| i.set_value("", window, cx));
        let l = cx.l10n().clone();
        let hint = if self.existing.as_ref().is_some_and(|c| c.has_memory_key) {
            l.hermes_configured_replace_placeholder()
        } else {
            l.desktop_optional()
        };
        forms::set_hint(&self.memory_key, hint, cx);
    }

    pub fn clear_memory_key(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.memory_cleared = true;
        self.memory_key
            .update(cx, |i, cx| i.set_value("", window, cx));
        let hint = cx.l10n().desktop_optional();
        forms::set_hint(&self.memory_key, hint, cx);
        self.memory_key.update(cx, |i, cx| i.focus(window, cx));
        self.note = None;
        cx.notify();
    }

    /// Add Header: a new row. As on a phone, a header-protected gateway
    /// cannot be signed in to natively (the core refuses it), so Hermes
    /// Sign-In gives way. A phone turns to the dashboard's sign-in, which
    /// this Mac's sign-in window can't send headers through either, so
    /// here it turns to the one way that sends them: a session token.
    pub fn add_header(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.headers.len() >= MAX_HEADERS {
            return;
        }
        let row = self.header_row(window, cx);
        let focus = row.name.clone();
        self.headers.push(row);
        self.header_saved.push(None);
        self.header_error = None;
        self.header_error_row = None;
        if self.desktop && self.auth == Auth::Native {
            self.auth = Auth::Token;
        }
        focus.update(cx, |i, cx| i.focus(window, cx));
        cx.notify();
    }

    pub fn remove_header(&mut self, i: usize, window: &mut Window, cx: &mut Context<Self>) {
        if i < self.headers.len() {
            self.headers.remove(i);
            self.header_saved.remove(i);
        }
        self.header_error = None;
        self.header_error_row = None;
        self.profiles_changed(window, cx);
        cx.notify();
    }

    /// Words a refusal of the headers (`reason: accessHeader`).
    fn header_refusal(&mut self, e: &RpcError, l: &L10n, cx: &App) {
        let header = e.args.get("header").cloned().unwrap_or_default();
        let row = self
            .headers
            .iter()
            .position(|r| forms::raw(&r.name, cx).trim() == header);
        self.header_error = Some(match e.args.get("issue").map(String::as_str) {
            Some("tooMany") => l.desktop_hermes_headers_too_many(),
            Some("duplicate") => l.desktop_header_already_exists(&header),
            Some("reserved") => l.header_name_reserved(&header),
            Some("tooLong") if header.len() > 64 => l.header_name_too_long(),
            Some("tooLong") => l.header_value_too_long(),
            Some("invalidValue") => l.header_value_invalid_chars(),
            _ => l.header_name_invalid_chars(),
        });
        self.header_error_row = row;
    }

    /// Asks before credentials go unencrypted; `then` sends the form again
    /// (and carries on with what was asked) when the user agreed.
    fn ask_plain_http(
        &mut self,
        url: String,
        window: &mut Window,
        cx: &mut Context<Self>,
        then: impl FnOnce(&mut Self, &mut Window, &mut Context<Self>) + 'static,
    ) {
        let l = cx.l10n().clone();
        let spec = SheetSpec::new(
            l.direct_mcp_insecure_credentials_title(),
            l.hermes_insecure_credentials_message(),
            l.direct_mcp_insecure_credentials_confirm(),
            l.cancel(),
        );
        let ask = present_sheet(window, spec, cx);
        let handle = window.window_handle();
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            if !ask.await {
                return;
            }
            let _ = handle.update(cx, |_, window, cx| {
                let _ = this.update(cx, |s, cx| {
                    s.plain_http_ok = Some(url);
                    then(s, window, cx);
                });
            });
        })
        .detach();
    }

    pub fn test(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(edit) = self.edit(cx) else {
            forms::focus_invalid(&self.invalid_field(), window, cx);
            return;
        };
        let url = edit.base_url.clone();
        let call = self
            .stores
            .connection
            .read(cx)
            .rpc()
            .call::<methods::HermesConnectionsTest>(&edit);
        self.busy = true;
        self.note = None;
        self.error = None;
        cx.notify();
        let handle = window.window_handle();
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result = call.await;
            let _ = handle.update(cx, |_, window, cx| {
                let _ = this.update(cx, |s, cx| {
                    s.busy = false;
                    let l = cx.l10n().clone();
                    match result {
                        Ok(r) if r.ok => {
                            // Unnamed: named after what the server reports.
                            if let Some(name) = r
                                .suggested_name
                                .filter(|_| forms::text(&s.name, cx).is_empty())
                            {
                                s.name.update(cx, |i, cx| i.set_value(name, window, cx));
                            }
                            s.note = Some(Note::Tested {
                                ok: true,
                                text: l.desktop_hermes_test_ok(),
                            });
                            // As on a phone: once the server answers, its
                            // profiles can be listed (a plain-HTTP consent
                            // given here counts).
                            if s.desktop && s.profiles.issue.is_some() {
                                s.load_profiles(window, cx);
                            }
                        }
                        Ok(r) => {
                            let text = match r.reason.as_deref() {
                                Some("unauthorized") => l.desktop_hermes_test_unauthorized(),
                                Some("keyRequired") => l.desktop_hermes_test_key_required(),
                                Some("invalid") => l.desktop_invalid_server_address(),
                                _ => l.desktop_hermes_test_unreachable(),
                            };
                            s.note = Some(Note::Tested { ok: false, text });
                        }
                        Err(e) if is_plain_http(&e) => {
                            s.ask_plain_http(url, window, cx, |s, w, cx| s.test(w, cx));
                        }
                        Err(e) if is_header_refusal(&e) => {
                            s.header_refusal(&e, &l, cx);
                            forms::focus_invalid(&s.invalid_field(), window, cx);
                        }
                        Err(e) => s.error = Some(words::connect_error(&e, &l)),
                    }
                    cx.notify();
                });
            });
        })
        .detach();
    }

    pub fn save(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.save_then(window, cx, |s, list, _, cx| {
            let text = cx.l10n().saved();
            s.stores
                .toasts
                .update(cx, |t, cx| t.show(NoticeLevel::Success, text, cx));
            let _ = list;
            // Words typed while the Save was out stay, still to save.
            if !s.dirty(cx) {
                sheet::dismiss(cx);
            }
        });
    }

    /// Saves the form, then `done` with the saved list (the editor knows
    /// its connection's id from then on). What was sent is what counts as
    /// saved: words typed meanwhile are still to save.
    fn save_then(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
        done: fn(&mut Self, HermesConnections, &mut Window, &mut Context<Self>),
    ) {
        let Some(edit) = self.edit(cx) else {
            forms::focus_invalid(&self.invalid_field(), window, cx);
            return;
        };
        let url = edit.base_url.clone();
        let sent = self.form(cx);
        let sent_rows = self.sent_rows(cx);
        let call = self
            .stores
            .connection
            .read(cx)
            .rpc()
            .call::<methods::HermesConnectionsSave>(&edit);
        let ticket = self.stores.hermes_admin.update(cx, |a, _| a.ask_list());
        self.busy = true;
        self.error = None;
        cx.notify();
        let handle = window.window_handle();
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result = call.await;
            let _ = handle.update(cx, |_, window, cx| {
                let _ = this.update(cx, |s, cx| {
                    s.busy = false;
                    let l = cx.l10n().clone();
                    match result {
                        Ok(list) => {
                            let saved = list
                                .saved_id
                                .as_ref()
                                .and_then(|id| list.connections.iter().find(|c| &c.id == id))
                                .cloned();
                            // Fields untouched since the Save went out show
                            // the saved state (a kept secret's field
                            // empties); words typed meanwhile stay to save.
                            let before = s.form(cx);
                            if let Some(saved) = saved {
                                s.adopt_saved(saved, &sent, &sent_rows, window, cx);
                            }
                            s.initial = Form::saved(&sent, &before, s.form(cx));
                            let admin = s.stores.hermes_admin.clone();
                            let adopted = list.clone();
                            admin.update(cx, |a, cx| a.answer_list(ticket, adopted, cx));
                            done(s, list, window, cx);
                        }
                        Err(e) if is_plain_http(&e) => {
                            s.ask_plain_http(url, window, cx, move |s, w, cx| {
                                s.save_then(w, cx, done)
                            });
                        }
                        Err(e) if is_header_refusal(&e) => {
                            s.header_refusal(&e, &l, cx);
                            forms::focus_invalid(&s.invalid_field(), window, cx);
                        }
                        Err(e) => {
                            s.error = Some(match e.args.get("reason").map(String::as_str) {
                                Some("invalidUrl") => l.desktop_invalid_server_address(),
                                Some("keyRequired") => l.desktop_hermes_test_key_required(),
                                _ => words::connect_error(&e, &l),
                            });
                        }
                    }
                    cx.notify();
                });
            });
        })
        .detach();
    }

    /// The connection as saved: its secrets now kept, so their fields are
    /// emptied and say so, and its headers' values too -- each only while
    /// it still holds what `sent` saved (a value typed since stays).
    /// Each header row as a Save sends it, by the row (its name field's
    /// entity, which stays the row's however it is renamed): its name and
    /// value then.
    fn sent_rows(&self, cx: &App) -> Vec<(EntityId, String, String)> {
        self.headers
            .iter()
            .map(|r| {
                (
                    r.name.entity_id(),
                    forms::raw(&r.name, cx),
                    forms::raw(&r.value, cx),
                )
            })
            .collect()
    }

    fn adopt_saved(
        &mut self,
        saved: HermesConnectionDto,
        sent: &Form,
        sent_rows: &[(EntityId, String, String)],
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let l = cx.l10n().clone();
        for (input, kept, was) in [
            (self.api_key.clone(), saved.has_api_key, &sent.api_key),
            (
                self.memory_key.clone(),
                saved.has_memory_key,
                &sent.memory_key,
            ),
            (self.token.clone(), saved.has_legacy_token, &sent.token),
        ] {
            let now = forms::raw(&input, cx);
            if kept && !now.is_empty() && &now == was {
                input.update(cx, |i, cx| i.set_value("", window, cx));
                forms::set_hint(&input, l.hermes_configured_replace_placeholder(), cx);
            }
        }
        // The Save carried the clear: the saved key went, or a replacement
        // typed after Clear took its place. Either way it is done, so a
        // later Save leaves the key as saved. (Clear can't be pressed while
        // a Save is out, and a Gateway Save never has one: switching to a
        // Gateway discards it.)
        if sent.memory_cleared {
            self.memory_cleared = false;
        }
        // Each row is followed by its identity (the row, not its name): a
        // row the Save sent now stands for the header saved under the name
        // it was sent as, however it was renamed before or since. Unchanged
        // since, it shows the saved state (dropped when the daemon did not
        // keep it); edited since, it stays as it is, still to save. A row
        // added since stands for what it did.
        let rows = std::mem::take(&mut self.headers);
        let stood_for = std::mem::take(&mut self.header_saved);
        let mut kept = vec![];
        for (row, was) in rows.into_iter().zip(stood_for) {
            let now = (forms::raw(&row.name, cx), forms::raw(&row.value, cx));
            let Some((_, name, value)) = sent_rows
                .iter()
                .find(|(id, _, _)| *id == row.name.entity_id())
            else {
                let was = was.filter(|n| saved.access_header_names.contains(n));
                kept.push((row, was));
                continue;
            };
            let sent_as = name.trim().to_string();
            let held = saved.access_header_names.contains(&sent_as);
            let unchanged = &now.0 == name && &now.1 == value;
            if unchanged && !held {
                continue;
            }
            if unchanged && !now.1.is_empty() {
                row.value.update(cx, |i, cx| i.set_value("", window, cx));
                forms::set_hint(&row.value, l.hermes_configured_replace_placeholder(), cx);
            }
            kept.push((row, held.then_some(sent_as)));
        }
        self.header_saved = kept.iter().map(|(_, n)| n.clone()).collect();
        self.headers = kept.into_iter().map(|(r, _)| r).collect();
        self.existing = Some(saved);
        self.profiles_asked = Some(self.profiles_asker(cx));
    }

    /// Hermes Sign-In needs the live connection, as on a phone: the form
    /// is saved, put in use, then signed in through the browser.
    pub fn sign_in(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.save_then(window, cx, |s, list, window, cx| {
            let Some(id) = s.existing.as_ref().map(|c| c.id.clone()) else {
                return;
            };
            let rpc = s.stores.connection.read(cx).rpc();
            let activate = (list.active_id.as_deref() != Some(id.as_str())).then(|| {
                rpc.call::<methods::HermesConnectionsActivate>(&HermesRef { id: id.clone() })
            });
            // Already in use: the connection the save's answer named.
            let mut connection = list.connection.clone();
            s.busy = true;
            s.note = Some(Note::SigningIn);
            cx.notify();
            let handle = window.window_handle();
            cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
                let mut failed: Option<RpcError> = None;
                if let Some(activate) = activate {
                    match activate.await.and_then(|now| put_in_use(now, &id)) {
                        Ok(now) => connection = now,
                        Err(e) => failed = Some(e),
                    }
                }
                // Asked only once the connection is in use (a call goes out
                // as soon as it is made), for that connection: another
                // window's switch in between is refused, not signed in to.
                if failed.is_none()
                    && let Err(e) = rpc
                        .call::<methods::HermesSignIn>(&HermesSignInRequest { connection })
                        .await
                {
                    failed = Some(e);
                }
                let _ = handle.update(cx, |_, window, cx| {
                    let _ = this.update(cx, |s, cx| {
                        s.busy = false;
                        s.note = None;
                        let l = cx.l10n().clone();
                        if let Some(e) = failed {
                            s.error = Some(match e.code.as_str() {
                                "rpc.unauthorized" => l.desktop_hermes_test_unauthorized(),
                                _ => words::connect_error(&e, &l),
                            });
                        } else {
                            s.load_profiles(window, cx);
                        }
                        s.stores
                            .hermes_admin
                            .update(cx, |a, cx| a.refresh_connections(cx));
                        cx.notify();
                    });
                });
            })
            .detach();
        });
    }

    /// The dashboard's own sign-in, as on a phone: the form is saved and
    /// put in use, the dashboard's sign-in page opens in a window of the
    /// app's, and the session it ends with is handed to the daemon. Then
    /// the profiles are read again and the connection tested.
    pub fn sign_in_dashboard(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.save_then(window, cx, |s, list, window, cx| {
            let Some(id) = s.existing.as_ref().map(|c| c.id.clone()) else {
                return;
            };
            let rpc = s.stores.connection.read(cx).rpc();
            let activate = (list.active_id.as_deref() != Some(id.as_str())).then(|| {
                rpc.call::<methods::HermesConnectionsActivate>(&HermesRef { id: id.clone() })
            });
            // Already in use: the connection the save's answer named.
            let mut connection = list.connection.clone();
            s.busy = true;
            s.note = Some(Note::SigningInDashboard);
            cx.notify();
            let handle = window.window_handle();
            cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
                let mut failed: Option<RpcError> = None;
                if let Some(activate) = activate {
                    match activate.await.and_then(|now| put_in_use(now, &id)) {
                        Ok(now) => connection = now,
                        Err(e) => failed = Some(e),
                    }
                }
                // Started only once the connection is in use (a call goes
                // out as soon as it is made), for that connection: another
                // window's switch in between is refused, not signed in to.
                let plan = match failed {
                    None => {
                        rpc.call::<methods::HermesDashboardStart>(&HermesDashboardStart {
                            id: id.clone(),
                            connection: connection.clone(),
                        })
                        .await
                    }
                    Some(e) => Err(e),
                };
                let outcome = match plan {
                    Ok(plan) if !plan.supported => None,
                    Ok(plan) => {
                        let title =
                            cx.update(|cx| cx.l10n().desktop_hermes_dashboard_window_title());
                        let task = cx.update(|cx| {
                            sso::run_hermes_dashboard(plan, id, connection, title, rpc, cx)
                        });
                        Some(Ok(task.await))
                    }
                    Err(e) => Some(Err(e)),
                };
                let _ = handle.update(cx, |_, window, cx| {
                    let _ = this.update(cx, |s, cx| {
                        s.busy = false;
                        s.note = None;
                        let l = cx.l10n().clone();
                        match outcome {
                            None => {
                                s.error = Some(l.desktop_hermes_dashboard_headers_unsupported())
                            }
                            // The list it answered with is not taken out of
                            // order: the read just below brings it.
                            Some(Ok(DashboardOutcome::SignedIn(_))) => {
                                s.load_profiles(window, cx);
                                s.test(window, cx);
                            }
                            // Closed: nothing to say, as on a phone.
                            Some(Ok(DashboardOutcome::Cancelled)) => {}
                            Some(Ok(DashboardOutcome::TimedOut)) => {
                                s.error = Some(l.desktop_hermes_dashboard_timed_out());
                            }
                            Some(Ok(DashboardOutcome::Failed(e))) => {
                                log::info!("hermes dashboard: {e}");
                                s.error = Some(l.desktop_hermes_dashboard_failed());
                            }
                            Some(Err(e)) => s.error = Some(words::connect_error(&e, &l)),
                        }
                        s.stores
                            .hermes_admin
                            .update(cx, |a, cx| a.refresh_connections(cx));
                        cx.notify();
                    });
                });
            })
            .detach();
        });
    }

    pub fn sign_out(&mut self, _: &mut Window, cx: &mut Context<Self>) {
        let call = self
            .stores
            .connection
            .read(cx)
            .rpc()
            .call::<methods::HermesSignOut>(&NoParams);
        let admin = self.stores.hermes_admin.downgrade();
        let failure = cx.l10n().hermes_sign_out_failed();
        let toasts = self.stores.toasts.downgrade();
        cx.spawn(async move |_, cx: &mut AsyncApp| {
            if call.await.is_err() {
                let _ = toasts.update(cx, |t, cx| t.show(NoticeLevel::Error, failure, cx));
            }
            let _ = admin.update(cx, |a, cx| a.refresh_connections(cx));
        })
        .detach();
    }

    /// Use This Connection: puts it in use and closes.
    pub fn use_it(&mut self, _: &mut Window, cx: &mut Context<Self>) {
        let Some(c) = self.existing.clone() else {
            return;
        };
        hermes_admin::activate(&self.stores, &c.id, cx);
        let text = cx.l10n().desktop_hermes_using_connection(&c.name);
        self.stores
            .toasts
            .update(cx, |t, cx| t.show(NoticeLevel::Success, text, cx));
        sheet::dismiss(cx);
    }

    pub fn delete(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(c) = self.existing.clone() else {
            return;
        };
        let l = cx.l10n().clone();
        let spec = SheetSpec::new(
            l.hermes_delete_connection_title(),
            l.hermes_delete_connection_message(&c.name),
            l.delete(),
            l.cancel(),
        )
        .destructive();
        let ask = present_sheet(window, spec, cx);
        let stores = self.stores.clone();
        cx.spawn(async move |_, cx: &mut AsyncApp| {
            if !ask.await {
                return;
            }
            cx.update(|cx| {
                let rpc = stores.connection.read(cx).rpc();
                let call =
                    rpc.call::<methods::HermesConnectionsDelete>(&HermesRef { id: c.id.clone() });
                let failure = cx.l10n().hermes_delete_connection_failed();
                hermes_admin::act_on_list(
                    &stores,
                    call,
                    failure,
                    |a, list, ticket, cx| {
                        a.answer_list(ticket, list, cx);
                    },
                    cx,
                );
                sheet::dismiss(cx);
            });
        })
        .detach();
    }

    /// The connection as the store has it now (signed in or not).
    fn current(&self, cx: &App) -> Option<HermesConnectionDto> {
        let id = self.existing.as_ref().map(|c| c.id.as_str());
        self.stores
            .hermes_admin
            .read(cx)
            .connections
            .as_ref()
            .and_then(|l| l.connections.iter().find(|c| Some(c.id.as_str()) == id))
            .cloned()
    }

    /// Whether the connection is the one in use now (it may have been put
    /// in use since the sheet opened: a sign-in does).
    fn is_active(&self, cx: &App) -> bool {
        self.current(cx)
            .or_else(|| self.existing.clone())
            .is_some_and(|c| c.active)
    }

    fn signed_in(&self, cx: &App) -> bool {
        self.current(cx).is_some_and(|c| c.desktop_signed_in)
    }

    /// The note under the sign-in choice on a Desktop Gateway: how the
    /// chosen way signs in, or why it can't while access headers are set
    /// (neither the browser's Hermes Sign-In nor this Mac's dashboard
    /// window can send them; a session token can).
    pub fn sign_in_note(&self, has_headers: bool, active: bool, l: &L10n) -> Option<String> {
        match self.auth {
            Auth::Token => None,
            Auth::Dashboard if has_headers => {
                Some(l.desktop_hermes_dashboard_headers_unsupported())
            }
            Auth::Dashboard if !active => Some(format!(
                "{} {}",
                l.hermes_dashboard_auth_help(),
                l.hermes_sign_in_activates_connection()
            )),
            Auth::Dashboard => Some(l.hermes_dashboard_auth_help()),
            Auth::Native if has_headers => Some(l.desktop_hermes_native_headers_unsupported()),
            Auth::Native if !active => Some(l.hermes_sign_in_activates_connection()),
            Auth::Native => Some(l.desktop_hermes_mode_gateway_help()),
        }
    }

    /// The note the editor shows now under its sign-in choice: the E2E.
    pub fn shown_sign_in_note(&self, cx: &App) -> Option<String> {
        let l = cx.l10n().clone();
        self.sign_in_note(self.has_headers(cx), self.is_active(cx), &l)
    }

    fn dashboard_signed_in(&self, cx: &App) -> bool {
        self.current(cx).is_some_and(|c| c.dashboard_signed_in)
    }

    /// Whether any header row is filled in (the dashboard's sign-in window
    /// cannot send them).
    fn has_headers(&self, cx: &App) -> bool {
        self.headers.iter().enumerate().any(|(i, r)| {
            !forms::raw(&r.name, cx).trim().is_empty()
                || self.header_saved.get(i).is_some_and(Option::is_some)
        })
    }

    /// The profile row: the gateway's profiles in a pop-up (the one chosen
    /// listed even when the gateway's list could not be read), Refresh
    /// Profiles at its end and beside it.
    fn profile_row(&self, window: &mut Window, cx: &mut Context<Self>) -> AnyElement {
        let l = cx.l10n().clone();
        let mut names = vec![self.profile.clone()];
        for p in &self.profiles.names {
            if !names.contains(p) {
                names.push(p.clone());
            }
        }
        let mut choices: Vec<Choice> = names
            .iter()
            .map(|p| Choice::new(p.clone(), p.clone()))
            .collect();
        choices.push(Choice::new(REFRESH, l.hermes_refresh_profiles()).separated());
        let popup = controls::popup(
            PROFILE_MENU,
            &l.hermes_profile_label(),
            choices,
            &self.profile,
            self.busy || self.profiles.loading,
            window,
            cx,
        );
        let refresh = {
            let this = cx.entity().downgrade();
            IconButton::new(
                "hermes-connection-refresh-profiles",
                IconName::RotateCw,
                l.hermes_refresh_profiles(),
            )
            .tooltip(l.hermes_refresh_profiles())
            .disabled(self.busy || self.profiles.loading)
            .on_click(Rc::new(move |_, window, cx| {
                cx.stop_propagation();
                let _ = this.update(cx, |s, cx| s.load_profiles(window, cx));
            }))
        };
        forms::form_row(
            l.hermes_profile_label(),
            div()
                .flex()
                .items_center()
                .gap(px(6.))
                .child(popup)
                .child(refresh),
            cx,
        )
        .into_any_element()
    }
}

/// The daemon refused to send credentials unencrypted unasked.
/// The connection an activation's answer `now` names, when it put `id` in
/// use. Another window put another connection in use while it was out: not
/// signed in to, and said as the daemon's refusal of a stale sign-in is.
fn put_in_use(now: HermesConnections, id: &str) -> Result<Option<String>, RpcError> {
    if now.active_id.as_deref() == Some(id) {
        Ok(now.connection)
    } else {
        Err(RpcError::new(ErrorCode::SessionExpired))
    }
}

fn is_plain_http(e: &RpcError) -> bool {
    e.args.get("reason").map(String::as_str) == Some("plainHttpConsent")
}

/// The daemon refused the headers.
fn is_header_refusal(e: &RpcError) -> bool {
    e.args.get("reason").map(String::as_str) == Some("accessHeader")
}

/// What a profile list issue says under the profile row.
fn profiles_issue_text(issue: &str, l: &L10n) -> String {
    match issue {
        "noUrl" => l.desktop_hermes_profiles_no_url(),
        "testFirst" => l.desktop_hermes_profiles_test_first(),
        "empty" => l.desktop_hermes_profiles_empty(),
        _ => l.desktop_hermes_profiles_sign_in_first(),
    }
}

impl SheetBody for HermesConnectionSheet {
    /// A save, test, activation or sign-in is out: set when one starts and
    /// cleared only when it ends (an edit clears the note, never this).
    fn busy(&self, _: &App) -> bool {
        self.busy
    }

    fn cancel(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.busy && !matches!(self.note, Some(Note::SigningIn | Note::SigningInDashboard)) {
            return;
        }
        if !self.dirty(cx) {
            sheet::dismiss(cx);
            return;
        }
        let l = cx.l10n().clone();
        let spec = SheetSpec::new(
            l.desktop_discard_changes_title(),
            l.desktop_discard_changes_message(),
            l.desktop_discard(),
            l.cancel(),
        )
        .destructive();
        let ask = present_sheet(window, spec, cx);
        cx.spawn(async move |_, cx: &mut AsyncApp| {
            if ask.await {
                cx.update(sheet::dismiss);
            }
        })
        .detach();
    }

    /// Edits not saved yet: Quit asks first.
    fn unsaved(&self, cx: &App) -> bool {
        self.dirty(cx)
    }

    fn label(&self, cx: &App) -> SharedString {
        match &self.existing {
            Some(c) => c.name.clone().into(),
            None => cx.l10n().hermes_new_connection_title().into(),
        }
    }

    fn footer(&mut self, _: &mut Window, cx: &mut Context<Self>) -> Option<AnyElement> {
        let l = cx.l10n().clone();
        let view = cx.entity().downgrade();
        let act = |f: fn(&mut Self, &mut Window, &mut Context<Self>)| {
            let view = view.clone();
            Rc::new(
                move |_: &gpui_kit::ClickEvent, window: &mut Window, cx: &mut App| {
                    let _ = view.update(cx, |v, cx| f(v, window, cx));
                },
            )
        };
        let active = self.is_active(cx);
        Some(
            div()
                .w_full()
                .flex()
                .items_center()
                .gap(px(8.))
                .when(self.existing.is_some(), |d| {
                    d.child(
                        Button::new("hermes-connection-delete", l.desktop_delete_ellipsis())
                            .disabled(self.busy)
                            .on_click(act(|s, w, cx| s.delete(w, cx))),
                    )
                })
                .when(self.existing.is_some() && !active, |d| {
                    d.child(
                        Button::new("hermes-connection-use", l.hermes_use_connection())
                            .disabled(self.busy || self.dirty(cx))
                            .on_click(act(|s, w, cx| s.use_it(w, cx))),
                    )
                })
                .child(div().flex_1())
                .child(
                    Button::new("hermes-connection-test", l.desktop_test_connection())
                        .disabled(!self.can_save(cx))
                        .on_click(act(|s, w, cx| s.test(w, cx))),
                )
                .child(
                    Button::new("hermes-connection-cancel", l.cancel())
                        .on_click(act(|s, w, cx| s.cancel(w, cx))),
                )
                .child(
                    Button::new(
                        "hermes-connection-save",
                        if self.busy {
                            l.desktop_saving()
                        } else {
                            l.save()
                        },
                    )
                    .primary()
                    .disabled(!self.can_save(cx))
                    .on_click(act(|s, w, cx| s.save(w, cx))),
                )
                .into_any_element(),
        )
    }
}

impl Render for HermesConnectionSheet {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let l = cx.l10n().clone();
        let t = cx.conduit().clone();
        let this = cx.entity().downgrade();
        let saved = self.existing.clone();
        let active = self.is_active(cx);
        let title = saved
            .as_ref()
            .map(|c| c.name.clone())
            .unwrap_or_else(|| l.hermes_new_connection_title());
        let mode = {
            let this = this.clone();
            Segmented::new(
                "hermes-connection-mode",
                l.desktop_hermes_mode(),
                vec![
                    Segment::new(l.desktop_hermes_mode_api()),
                    Segment::new(l.hermes_desktop_gateway()),
                ],
                usize::from(self.desktop),
            )
            .on_select(Rc::new(move |i, window, cx| {
                let _ = this.update(cx, |s, cx| s.choose_mode(i == 1, window, cx));
            }))
        };
        let derived = forms::host_of(&forms::text(&self.url, cx));
        let name_hint = if derived.is_empty() {
            l.hermes_agent_settings_title()
        } else {
            derived
        };
        let details = vec![
            forms::field_hinted(
                l.name(),
                &self.name,
                Some(name_hint.into()),
                Some(l.hermes_connection_name_hint().into()),
                None,
                window,
                cx,
            )
            .into_any_element(),
            forms::field(
                l.hermes_server_url_title(),
                &self.url,
                None,
                None,
                window,
                cx,
            )
            .into_any_element(),
            forms::form_row(l.desktop_hermes_mode(), mode, cx).into_any_element(),
        ];
        let mut auth: Vec<AnyElement> = vec![];
        let has_headers = self.has_headers(cx);
        if self.desktop {
            let this2 = this.clone();
            let kind = Segmented::new(
                "hermes-connection-auth",
                l.desktop_hermes_sign_in_with(),
                vec![
                    Segment::new(l.desktop_hermes_auth_native()),
                    Segment::new(l.desktop_hermes_auth_token()),
                    Segment::new(l.hermes_auth_dashboard()),
                ],
                self.auth.index(),
            )
            .on_select(Rc::new(move |i, window, cx| {
                let _ = this2.update(cx, |s, cx| {
                    s.auth = Auth::from_index(i);
                    s.note = None;
                    s.error = None;
                    s.profiles_changed(window, cx);
                    cx.notify();
                });
            }));
            auth.push(
                forms::form_row(l.desktop_hermes_sign_in_with(), kind, cx).into_any_element(),
            );
            match self.auth {
                Auth::Token => auth.push(
                    forms::field(
                        l.hermes_legacy_session_token(),
                        &self.token,
                        Some(l.desktop_hermes_auth_token_help().into()),
                        None,
                        window,
                        cx,
                    )
                    .into_any_element(),
                ),
                Auth::Native | Auth::Dashboard => {
                    let dashboard = self.auth == Auth::Dashboard;
                    let signed_in = if dashboard {
                        self.dashboard_signed_in(cx)
                    } else {
                        self.signed_in(cx)
                    };
                    let button = if signed_in && active {
                        let this = this.clone();
                        Button::new("hermes-connection-sign-out", l.desktop_sign_out_of_hermes())
                            .disabled(self.busy)
                            .on_click(Rc::new(move |_, w, cx| {
                                let _ = this.update(cx, |s, cx| s.sign_out(w, cx));
                            }))
                    } else if dashboard {
                        let this = this.clone();
                        Button::new(
                            "hermes-connection-dashboard-sign-in",
                            l.hermes_dashboard_sign_in(),
                        )
                        .disabled(!self.can_save(cx) || has_headers)
                        .on_click(Rc::new(move |_, w, cx| {
                            let _ = this.update(cx, |s, cx| s.sign_in_dashboard(w, cx));
                        }))
                    } else {
                        let this = this.clone();
                        Button::new("hermes-connection-sign-in", l.desktop_sign_in_with_hermes())
                            .disabled(!self.can_save(cx) || has_headers)
                            .on_click(Rc::new(move |_, w, cx| {
                                let _ = this.update(cx, |s, cx| s.sign_in(w, cx));
                            }))
                    };
                    auth.push(
                        setting_row(
                            if dashboard {
                                l.hermes_auth_dashboard()
                            } else {
                                l.desktop_hermes_auth_native()
                            },
                            Some(
                                if signed_in {
                                    l.desktop_mcp_signed_in()
                                } else {
                                    l.desktop_mcp_not_signed_in()
                                }
                                .into(),
                            ),
                            button,
                            cx,
                        )
                        .into_any_element(),
                    );
                }
            }
            auth.push(self.profile_row(window, cx));
        } else {
            auth.push(
                forms::field(
                    l.hermes_api_key_title(),
                    &self.api_key,
                    None,
                    None,
                    window,
                    cx,
                )
                .into_any_element(),
            );
            auth.push(
                forms::field(
                    l.hermes_memory_key_field_label(),
                    &self.memory_key,
                    Some(l.hermes_memory_key_description().into()),
                    None,
                    window,
                    cx,
                )
                .into_any_element(),
            );
            if saved.as_ref().is_some_and(|c| c.has_memory_key) && !self.memory_cleared {
                let this = this.clone();
                auth.push(
                    div()
                        .px(px(12.))
                        .py(px(6.))
                        .flex()
                        .justify_end()
                        .child(
                            Button::new("hermes-memory-key-clear", l.clear())
                                .ghost()
                                .disabled(self.busy)
                                .on_click(Rc::new(move |_, window, cx| {
                                    let _ = this.update(cx, |s, cx| s.clear_memory_key(window, cx));
                                })),
                        )
                        .into_any_element(),
                );
            }
        }
        let profiles_note = self
            .desktop
            .then(|| {
                self.profiles
                    .issue
                    .as_deref()
                    .map(|i| profiles_issue_text(i, &l))
            })
            .flatten();
        let auth_footer = if self.desktop {
            let sign_in = self.sign_in_note(has_headers, active, &l);
            match (sign_in, profiles_note) {
                (Some(a), Some(b)) => Some(format!("{a} {b}")),
                (a, b) => a.or(b),
            }
        } else {
            Some(l.desktop_hermes_mode_api_help())
        };
        let toggle = {
            let this = this.clone();
            Rc::new(
                move |_: &gpui_kit::ClickEvent, _: &mut Window, cx: &mut App| {
                    let _ = this.update(cx, |s, cx| {
                        s.self_signed = !s.self_signed;
                        cx.notify();
                    });
                },
            )
        };
        let add_header = {
            let this = this.clone();
            Rc::new(
                move |_: &gpui_kit::ClickEvent, window: &mut Window, cx: &mut App| {
                    let _ = this.update(cx, |s, cx| s.add_header(window, cx));
                },
            )
        };
        let remove_header = {
            let this = this.clone();
            Rc::new(move |i: usize, window: &mut Window, cx: &mut App| {
                let _ = this.update(cx, |s, cx| s.remove_header(i, window, cx));
            })
        };
        let headers = div()
            .id("hermes-connection-headers")
            .px(px(12.))
            .py(px(8.))
            .flex()
            .flex_col()
            .gap(px(8.))
            .child(
                setting_row(
                    l.desktop_custom_headers(),
                    Some(l.desktop_custom_headers_help().into()),
                    Button::new("hermes-connection-add-header", l.desktop_add_header())
                        .icon(IconName::Plus)
                        .disabled(self.busy || self.headers.len() >= MAX_HEADERS)
                        .on_click(add_header),
                    cx,
                )
                .px_0(),
            )
            .child(forms::header_rows(
                &self.headers,
                l.desktop_header_name().into(),
                l.desktop_header_value().into(),
                l.desktop_remove_header().into(),
                remove_header,
                cx,
            ))
            .when_some(self.header_error.clone(), |d, e| {
                d.child(forms::form_error("hermes-connection-header-error", e, cx))
            });
        let note = self.note.as_ref().map(|n| match n {
            Note::Tested { ok, text } => (text.clone(), *ok),
            Note::SigningIn => (l.desktop_hermes_signing_in(), false),
            Note::SigningInDashboard => (l.desktop_hermes_dashboard_signing_in(), false),
        });
        let inactive_notice =
            (saved.is_some() && !active).then(|| l.hermes_inactive_connection_notice());
        div()
            .id("hermes-connection-sheet")
            .role(Role::Form)
            .aria_label(SharedString::from(title.clone()))
            .w_full()
            .flex()
            .flex_col()
            .gap(px(16.))
            .on_action(
                cx.listener(|this, a: &SettingsChoice, window, cx| this.on_choice(a, window, cx)),
            )
            .on_key_down(cx.listener(|this, e: &gpui_kit::KeyDownEvent, window, cx| {
                let k = &e.keystroke;
                if k.key == "enter" && k.modifiers.platform && this.can_save(cx) {
                    this.save(window, cx);
                    cx.stop_propagation();
                }
            }))
            .child(
                div()
                    .flex()
                    .flex_col()
                    .gap(px(4.))
                    .child(
                        div()
                            .id("sheet-title")
                            .role(Role::Heading)
                            .text_size(px(t.metrics.body + 2.))
                            .font_weight(FontWeight::SEMIBOLD)
                            .child(SharedString::from(title)),
                    )
                    .when_some(inactive_notice, |d, n| {
                        d.child(
                            div()
                                .text_size(px(t.metrics.small + 0.5))
                                .line_height(relative(1.4))
                                .text_color(t.roles.text_subtle)
                                .child(n),
                        )
                    }),
            )
            .child(grouped_section(None, details, None, cx))
            .child(grouped_section(
                Some(if self.desktop {
                    l.hermes_desktop_authentication().into()
                } else {
                    l.hermes_api_key_title().into()
                }),
                auth,
                auth_footer.map(SharedString::from),
                cx,
            ))
            .child(grouped_section(
                Some(l.hermes_gateway_access_headers().into()),
                vec![
                    headers.into_any_element(),
                    setting_row(
                        l.desktop_allow_unverified_certificate(),
                        None,
                        Switch::new(
                            "hermes-connection-self-signed",
                            l.desktop_allow_unverified_certificate(),
                            self.self_signed,
                        )
                        .on_click(toggle),
                        cx,
                    )
                    .into_any_element(),
                ],
                Some(l.hermes_gateway_access_headers_help().into()),
                cx,
            ))
            .when_some(self.error.clone(), |d, e| {
                d.child(forms::form_error("hermes-connection-error", e, cx))
            })
            .when_some(note, |d, (text, ok)| {
                d.child(forms::form_note(text, ok, cx))
            })
    }
}

/// What the E2E reads of an open editor.
pub fn summary(sheet: &HermesConnectionSheet, l: &L10n) -> String {
    let _ = l;
    format!(
        "{}{}",
        sheet
            .existing
            .as_ref()
            .map(|c| c.name.as_str())
            .unwrap_or("new"),
        if sheet.busy { " (busy)" } else { "" }
    )
}

#[cfg(test)]
mod tests {
    use gpui_kit::VisualTestContext;
    use serde_json::json;

    use super::*;
    use crate::stores::rpc::fake::FakeDaemon;
    use crate::views::sheet::bench::bench;

    fn list(active: &str, saved: Option<&str>, auth: &str) -> HermesConnections {
        serde_json::from_value(json!({
            "enabled": true,
            "activeId": active,
            "connection": format!("0a1b2c3d:{active}"),
            "savedId": saved,
            "connections": [
                {"id": "a", "name": "Potting shed", "baseUrl": "http://127.0.0.1:20401",
                 "mode": "desktop", "desktopAuthKind": "nativePkce", "active": active == "a"},
                {"id": "b", "name": "Greenhouse", "baseUrl": "http://192.168.20.40:20402",
                 "mode": "desktop", "desktopAuthKind": auth, "active": active == "b"},
            ],
        }))
        .unwrap()
    }

    fn open_b(
        stores: &Stores,
        vcx: &mut VisualTestContext,
        auth: &str,
    ) -> Entity<HermesConnectionSheet> {
        stores
            .hermes_admin
            .update(vcx, |a, cx| a.adopt_connections(list("a", None, auth), cx));
        let s = stores.clone();
        vcx.update(|window, cx| open(&s, Some("b".into()), window, cx));
        vcx.run_until_parked();
        vcx.update(|_, cx| sheet::current::<HermesConnectionSheet>(cx))
            .expect("the editor opens")
    }

    fn on_sheet(
        vcx: &mut VisualTestContext,
        sheet: &Entity<HermesConnectionSheet>,
        f: impl FnOnce(&mut HermesConnectionSheet, &mut Window, &mut Context<HermesConnectionSheet>),
    ) {
        vcx.update(|_, cx| {
            let window = sheet::current_window(cx).expect("the sheet's window");
            let _ = window.update(cx, |_, window, cx| {
                sheet.update(cx, |s, cx| f(s, window, cx))
            });
        });
    }

    /// Sign In puts the connection in use first, and only then asks the
    /// daemon to sign in: never while the one before is still in use.
    #[gpui_kit::test]
    fn sign_in_waits_for_the_connection_to_be_in_use(cx: &mut gpui_kit::TestAppContext) {
        let (daemon, stores, vcx) = bench(cx);
        daemon.returns::<methods::HermesConnectionsSave>(list("a", Some("b"), "nativePkce"));
        daemon.once::<methods::HermesConnectionsActivate>(Err(serde_json::from_value(
            json!({"code": "hermes.unreachable"}),
        )
        .unwrap()));
        daemon.on::<methods::HermesSignIn>(|_| Ok(json!({})));
        let held = daemon.hold::<methods::HermesConnectionsActivate>();
        let sheet = open_b(&stores, vcx, "nativePkce");
        on_sheet(vcx, &sheet, |s, w, cx| s.sign_in(w, cx));
        vcx.run_until_parked();
        assert_eq!(
            daemon.calls::<methods::HermesConnectionsActivate>().len(),
            1
        );
        assert!(
            daemon.calls::<methods::HermesSignIn>().is_empty(),
            "sign-in was asked before the connection was in use"
        );
        drop(held);
        vcx.run_until_parked();
        assert!(
            daemon.calls::<methods::HermesSignIn>().is_empty(),
            "sign-in was asked though the connection could not be put in use"
        );
    }

    /// Sign In names the connection its activation put in use (or the one
    /// already in use): a switch from another window in between is refused
    /// by conduitd rather than signed in to.
    #[gpui_kit::test]
    fn sign_in_names_the_connection_it_put_in_use(cx: &mut gpui_kit::TestAppContext) {
        let (daemon, stores, vcx) = bench(cx);
        daemon.returns::<methods::HermesConnectionsSave>(list("a", Some("b"), "nativePkce"));
        daemon.returns::<methods::HermesConnectionsActivate>(list("b", None, "nativePkce"));
        daemon.on::<methods::HermesSignIn>(|_| Ok(json!({})));
        daemon.returns::<methods::HermesConnectionsList>(list("b", None, "nativePkce"));
        let sheet = open_b(&stores, vcx, "nativePkce");
        on_sheet(vcx, &sheet, |s, w, cx| s.sign_in(w, cx));
        vcx.run_until_parked();
        let asked = daemon.calls::<methods::HermesSignIn>();
        assert_eq!(asked.len(), 1);
        assert_eq!(
            asked[0]["connection"],
            json!("0a1b2c3d:b"),
            "sign-in named no connection, or not the one put in use"
        );
    }

    /// Quit while a sign-in is out beeps, and still does after a field is
    /// edited (which clears the "Signing in" note, not the sign-in).
    #[gpui_kit::test]
    fn quit_during_a_sign_in_beeps_even_after_an_edit(cx: &mut gpui_kit::TestAppContext) {
        let (daemon, stores, vcx) = bench(cx);
        daemon.returns::<methods::HermesConnectionsSave>(list("a", Some("b"), "nativePkce"));
        daemon.returns::<methods::HermesConnectionsActivate>(list("b", None, "nativePkce"));
        daemon.on::<methods::HermesSignIn>(|_| Ok(json!({})));
        daemon.returns::<methods::HermesConnectionsList>(list("b", None, "nativePkce"));
        let held = daemon.hold::<methods::HermesSignIn>();
        let sheet = open_b(&stores, vcx, "nativePkce");
        on_sheet(vcx, &sheet, |s, w, cx| {
            s.name.update(cx, |i, cx| i.set_value("Cold frame", w, cx));
            s.sign_in(w, cx);
        });
        vcx.run_until_parked();
        assert_eq!(daemon.calls::<methods::HermesSignIn>().len(), 1);
        let quits = std::rc::Rc::new(std::cell::Cell::new(0));
        let quit = |vcx: &mut VisualTestContext| {
            let counted = quits.clone();
            vcx.update(|_, cx| {
                sheet::quit_with(
                    cx,
                    std::rc::Rc::new(move |_| counted.set(counted.get() + 1)),
                )
            });
            vcx.run_until_parked();
        };
        let beeps = |vcx: &mut VisualTestContext| {
            vcx.update(|_, cx| cx.global::<crate::shell::sheet::Beeps>().0)
        };
        quit(vcx);
        assert_eq!(beeps(vcx), 1, "Quit during the sign-in did not beep");
        on_sheet(vcx, &sheet, |s, w, cx| {
            s.name
                .update(cx, |i, cx| i.set_value("Cold frame east", w, cx));
        });
        vcx.run_until_parked();
        quit(vcx);
        assert_eq!(beeps(vcx), 2, "an edit made the sign-in look over");
        assert_eq!(quits.get(), 0);
        assert!(vcx.update(|_, cx| sheet::current::<HermesConnectionSheet>(cx).is_some()));
        drop(held);
    }

    /// Quit while the editor asks to send credentials unencrypted (its
    /// Save's consent question is up): Quit queues nothing behind it, no
    /// discard question comes; the sheet comes forward with a beep.
    #[gpui_kit::test]
    fn quit_while_the_consent_question_is_up_beeps(cx: &mut gpui_kit::TestAppContext) {
        let (daemon, stores, vcx) = bench(cx);
        daemon.once::<methods::HermesConnectionsSave>(Err(serde_json::from_value(
            json!({"code": "rpc.invalidParams", "args": {"reason": "plainHttpConsent"}}),
        )
        .unwrap()));
        daemon.returns::<methods::HermesConnectionsSave>(list("a", Some("b"), "nativePkce"));
        let sheet = open_b(&stores, vcx, "nativePkce");
        vcx.update(|_, cx| cx.set_global(crate::shell::sheet::HeldAnswers::default()));
        on_sheet(vcx, &sheet, |s, w, cx| {
            s.name.update(cx, |i, cx| i.set_value("Cold frame", w, cx));
            s.save(w, cx);
        });
        vcx.run_until_parked();
        let held = |vcx: &mut VisualTestContext| {
            vcx.update(|_, cx| cx.global::<crate::shell::sheet::HeldAnswers>().0.len())
        };
        assert_eq!(held(vcx), 1, "the consent question is not up");
        let quits = std::rc::Rc::new(std::cell::Cell::new(0));
        let counted = quits.clone();
        vcx.update(|_, cx| {
            sheet::quit_with(
                cx,
                std::rc::Rc::new(move |_| counted.set(counted.get() + 1)),
            )
        });
        vcx.run_until_parked();
        assert_eq!(
            held(vcx),
            1,
            "a discard question was queued behind the consent"
        );
        assert_eq!(
            vcx.update(|_, cx| cx
                .try_global::<crate::shell::sheet::Beeps>()
                .map_or(0, |b| b.0)),
            1,
            "Quit over the consent question did not beep"
        );
        assert_eq!(quits.get(), 0);
        assert!(vcx.update(|_, cx| sheet::current::<HermesConnectionSheet>(cx).is_some()));
    }

    /// The dashboard's sign-in starts only once its connection is in use,
    /// and names that connection, as Sign In does.
    #[gpui_kit::test]
    fn dashboard_sign_in_starts_after_activation_for_its_connection(
        cx: &mut gpui_kit::TestAppContext,
    ) {
        let (daemon, stores, vcx) = bench(cx);
        daemon.returns::<methods::HermesConnectionsSave>(list("a", Some("b"), "dashboardCookie"));
        daemon.returns::<methods::HermesConnectionsActivate>(list("b", None, "dashboardCookie"));
        // Not supported here: no sign-in window opens in the test.
        daemon.on::<methods::HermesDashboardStart>(|_| {
            Ok(json!({"loginUrl": "http://127.0.0.1:20402/login",
                      "origin": "http://127.0.0.1:20402", "supported": false}))
        });
        daemon.returns::<methods::HermesConnectionsList>(list("b", None, "dashboardCookie"));
        let held = daemon.hold::<methods::HermesConnectionsActivate>();
        let sheet = open_b(&stores, vcx, "dashboardCookie");
        on_sheet(vcx, &sheet, |s, w, cx| s.sign_in_dashboard(w, cx));
        vcx.run_until_parked();
        assert!(
            daemon.calls::<methods::HermesDashboardStart>().is_empty(),
            "the dashboard sign-in started before its connection was in use"
        );
        drop(held);
        vcx.run_until_parked();
        let asked = daemon.calls::<methods::HermesDashboardStart>();
        assert_eq!(asked.len(), 1);
        assert_eq!(asked[0]["connection"], json!("0a1b2c3d:b"));
    }

    /// Agreeing to send credentials unencrypted carries on with what was
    /// asked: Sign In still signs in.
    #[gpui_kit::test]
    fn plain_http_consent_keeps_sign_in_going(cx: &mut gpui_kit::TestAppContext) {
        let (daemon, stores, vcx) = bench(cx);
        vcx.update(|_, cx| cx.set_global(crate::shell::sheet::AutoAnswer(Some(true))));
        daemon.once::<methods::HermesConnectionsSave>(Err(serde_json::from_value(
            json!({"code": "rpc.invalidParams", "args": {"reason": "plainHttpConsent"}}),
        )
        .unwrap()));
        daemon.returns::<methods::HermesConnectionsSave>(list("a", Some("b"), "nativePkce"));
        daemon.returns::<methods::HermesConnectionsActivate>(list("b", None, "nativePkce"));
        daemon.on::<methods::HermesSignIn>(|_| Ok(json!({})));
        daemon.returns::<methods::HermesConnectionsList>(list("b", None, "nativePkce"));
        let sheet = open_b(&stores, vcx, "nativePkce");
        on_sheet(vcx, &sheet, |s, w, cx| s.sign_in(w, cx));
        vcx.run_until_parked();
        let saves = daemon.calls::<methods::HermesConnectionsSave>();
        assert_eq!(
            saves.len(),
            2,
            "the form was not sent again after the consent"
        );
        assert_eq!(saves[1]["allowPlainHttp"], json!(true));
        assert_eq!(
            daemon.calls::<methods::HermesSignIn>().len(),
            1,
            "the consent dropped the sign-in"
        );
    }

    /// Words typed while a Save is out stay in the editor, still to save:
    /// the Save's answer neither closes it nor counts them as saved.
    #[gpui_kit::test]
    fn words_typed_during_a_save_stay_unsaved(cx: &mut gpui_kit::TestAppContext) {
        let (daemon, stores, vcx) = bench(cx);
        daemon.returns::<methods::HermesConnectionsSave>(list("a", Some("b"), "nativePkce"));
        let held = daemon.hold::<methods::HermesConnectionsSave>();
        let sheet = open_b(&stores, vcx, "nativePkce");
        on_sheet(vcx, &sheet, |s, w, cx| {
            s.name.update(cx, |i, cx| i.set_value("Cold frame", w, cx));
            s.save(w, cx);
            s.name
                .update(cx, |i, cx| i.set_value("Cold frame east", w, cx));
        });
        drop(held);
        vcx.run_until_parked();
        let saves = daemon.calls::<methods::HermesConnectionsSave>();
        assert_eq!(saves.len(), 1);
        assert_eq!(saves[0]["name"], json!("Cold frame"));
        vcx.update(|_, cx| {
            assert!(
                sheet::current::<HermesConnectionSheet>(cx).is_some_and(|b| b == sheet),
                "the editor closed with words not saved"
            );
            assert!(
                sheet.read(cx).dirty(cx),
                "the words typed later count as saved"
            );
            assert!(sheet::has_unsaved(cx), "Quit would not ask about them");
        });
    }

    /// A Save that keeps the typed token closes the editor: the emptied
    /// field ("kept, not shown") is the saved state, not an edit. A token
    /// typed while the Save was out stays, still to save.
    #[gpui_kit::test]
    fn a_saved_token_closes_the_editor_and_a_newer_one_stays(cx: &mut gpui_kit::TestAppContext) {
        let saved = || {
            let mut l = list("a", Some("b"), "legacyToken");
            l.connections[1].has_legacy_token = true;
            l
        };
        let (daemon, stores, vcx) = bench(cx);
        daemon.returns::<methods::HermesConnectionsSave>(saved());
        let sheet = open_b(&stores, vcx, "legacyToken");
        on_sheet(vcx, &sheet, |s, w, cx| {
            s.token
                .update(cx, |i, cx| i.set_value("demo-token-one", w, cx));
            s.save(w, cx);
        });
        vcx.run_until_parked();
        vcx.update(|_, cx| {
            assert!(
                sheet::current::<HermesConnectionSheet>(cx).is_none(),
                "the editor stayed open over a saved token"
            )
        });

        let (daemon, stores, vcx) = bench(cx);
        daemon.returns::<methods::HermesConnectionsSave>(saved());
        let held = daemon.hold::<methods::HermesConnectionsSave>();
        let sheet = open_b(&stores, vcx, "legacyToken");
        on_sheet(vcx, &sheet, |s, w, cx| {
            s.token
                .update(cx, |i, cx| i.set_value("demo-token-one", w, cx));
            s.save(w, cx);
            s.token
                .update(cx, |i, cx| i.set_value("demo-token-two", w, cx));
        });
        drop(held);
        vcx.run_until_parked();
        vcx.update(|_, cx| {
            assert!(
                sheet::current::<HermesConnectionSheet>(cx).is_some_and(|b| b == sheet),
                "the editor closed over a token not saved"
            );
            assert_eq!(forms::raw(&sheet.read(cx).token, cx), "demo-token-two");
            assert!(sheet.read(cx).dirty(cx), "the newer token counts as saved");
        });
    }

    /// A connection signing in some other way (a dashboard cookie) keeps
    /// it when saved untouched.
    #[gpui_kit::test]
    fn an_untouched_sign_in_method_is_kept(cx: &mut gpui_kit::TestAppContext) {
        let (daemon, stores, vcx) = bench(cx);
        daemon.returns::<methods::HermesConnectionsSave>(list("a", Some("b"), "dashboardCookie"));
        let sheet = open_b(&stores, vcx, "dashboardCookie");
        on_sheet(vcx, &sheet, |s, w, cx| s.save(w, cx));
        vcx.run_until_parked();
        let saves = daemon.calls::<methods::HermesConnectionsSave>();
        assert_eq!(saves.len(), 1);
        assert_eq!(saves[0]["desktopAuthKind"], json!("dashboardCookie"));
    }

    /// The activation's answer names another connection in use (another
    /// window switched while it was out): neither sign-in goes out, and the
    /// editor says why.
    #[gpui_kit::test]
    fn sign_in_stops_when_another_connection_was_put_in_use(cx: &mut gpui_kit::TestAppContext) {
        for dashboard in [false, true] {
            let auth = if dashboard {
                "dashboardCookie"
            } else {
                "nativePkce"
            };
            let (daemon, stores, vcx) = bench(cx);
            daemon.returns::<methods::HermesConnectionsSave>(list("a", Some("b"), auth));
            daemon.returns::<methods::HermesConnectionsActivate>(list("a", None, auth));
            daemon.on::<methods::HermesSignIn>(|_| Ok(json!({})));
            daemon.on::<methods::HermesDashboardStart>(|_| {
                Ok(json!({"loginUrl": "http://127.0.0.1:20402/login",
                          "origin": "http://127.0.0.1:20402", "supported": true}))
            });
            daemon.returns::<methods::HermesConnectionsList>(list("a", None, auth));
            let sheet = open_b(&stores, vcx, auth);
            on_sheet(vcx, &sheet, |s, w, cx| {
                if dashboard {
                    s.sign_in_dashboard(w, cx)
                } else {
                    s.sign_in(w, cx)
                }
            });
            vcx.run_until_parked();
            assert!(
                daemon.calls::<methods::HermesSignIn>().is_empty()
                    && daemon.calls::<methods::HermesDashboardStart>().is_empty(),
                "signed in to the connection another window put in use (dashboard: {dashboard})"
            );
            sheet.read_with(vcx, |s, _| {
                assert!(s.error.is_some(), "the editor did not say why");
                assert!(!s.busy);
            });
        }
    }

    /// [`list`] with B holding `headers`.
    fn with_headers(active: &str, saved: Option<&str>, headers: &[&str]) -> HermesConnections {
        let mut l = list(active, saved, "dashboardCookie");
        l.connections[1].access_header_names = headers.iter().map(|h| h.to_string()).collect();
        l
    }

    fn header_names(sheet: &HermesConnectionSheet, cx: &App) -> Vec<String> {
        sheet
            .headers
            .iter()
            .map(|r| forms::raw(&r.name, cx))
            .collect()
    }

    /// A saved header removed stops being sent: the Save names the headers
    /// left (none, for the last one), never "keep what is saved".
    #[gpui_kit::test]
    fn a_removed_header_is_no_longer_saved(cx: &mut gpui_kit::TestAppContext) {
        let (daemon, stores, vcx) = bench(cx);
        daemon.returns::<methods::HermesConnectionsSave>(with_headers("a", Some("b"), &[]));
        stores.hermes_admin.update(vcx, |a, cx| {
            a.adopt_connections(with_headers("a", None, &["X-Gate"]), cx)
        });
        let s = stores.clone();
        vcx.update(|window, cx| open(&s, Some("b".into()), window, cx));
        vcx.run_until_parked();
        let sheet = vcx
            .update(|_, cx| sheet::current::<HermesConnectionSheet>(cx))
            .expect("the editor opens");
        on_sheet(vcx, &sheet, |s, w, cx| {
            s.remove_header(0, w, cx);
            s.save(w, cx);
        });
        vcx.run_until_parked();
        let saves = daemon.calls::<methods::HermesConnectionsSave>();
        assert_eq!(saves.len(), 1);
        assert_eq!(
            saves[0]["accessHeaders"],
            json!([]),
            "the header is still sent"
        );

        let (daemon, stores, vcx) = bench(cx);
        daemon.returns::<methods::HermesConnectionsSave>(with_headers("a", Some("b"), &["X-Zone"]));
        stores.hermes_admin.update(vcx, |a, cx| {
            a.adopt_connections(with_headers("a", None, &["X-Gate", "X-Zone"]), cx)
        });
        let s = stores.clone();
        vcx.update(|window, cx| open(&s, Some("b".into()), window, cx));
        vcx.run_until_parked();
        let sheet = vcx
            .update(|_, cx| sheet::current::<HermesConnectionSheet>(cx))
            .expect("the editor opens");
        on_sheet(vcx, &sheet, |s, w, cx| {
            s.remove_header(0, w, cx);
            s.save(w, cx);
        });
        vcx.run_until_parked();
        let saves = daemon.calls::<methods::HermesConnectionsSave>();
        let sent = saves[0]["accessHeaders"]
            .as_array()
            .expect("the headers are sent");
        assert_eq!(sent.len(), 1);
        assert_eq!(sent[0]["name"], json!("X-Zone"));
    }

    /// Header rows added or renamed while a Save is out stay in the editor,
    /// still to save; only rows that were sent take the saved state.
    #[gpui_kit::test]
    fn headers_edited_during_a_save_stay_unsaved(cx: &mut gpui_kit::TestAppContext) {
        let (daemon, stores, vcx) = bench(cx);
        daemon.returns::<methods::HermesConnectionsSave>(with_headers(
            "a",
            Some("b"),
            &["X-Gate", "X-Zone"],
        ));
        stores.hermes_admin.update(vcx, |a, cx| {
            a.adopt_connections(with_headers("a", None, &["X-Gate"]), cx)
        });
        let s = stores.clone();
        vcx.update(|window, cx| open(&s, Some("b".into()), window, cx));
        vcx.run_until_parked();
        let sheet = vcx
            .update(|_, cx| sheet::current::<HermesConnectionSheet>(cx))
            .expect("the editor opens");
        let held = daemon.hold::<methods::HermesConnectionsSave>();
        on_sheet(vcx, &sheet, |s, w, cx| {
            s.add_header(w, cx);
            s.headers[1]
                .name
                .update(cx, |i, cx| i.set_value("X-Zone", w, cx));
            s.headers[1]
                .value
                .update(cx, |i, cx| i.set_value("zone-1", w, cx));
            s.save(w, cx);
            // Meanwhile: the saved header renamed, and one more added.
            s.headers[0]
                .name
                .update(cx, |i, cx| i.set_value("X-Gate-2", w, cx));
            s.add_header(w, cx);
            s.headers[2]
                .name
                .update(cx, |i, cx| i.set_value("X-New", w, cx));
            s.headers[2]
                .value
                .update(cx, |i, cx| i.set_value("new-1", w, cx));
        });
        drop(held);
        vcx.run_until_parked();
        vcx.update(|_, cx| {
            assert!(
                sheet::current::<HermesConnectionSheet>(cx).is_some_and(|b| b == sheet),
                "the editor closed over headers not saved"
            );
            let s = sheet.read(cx);
            assert_eq!(header_names(s, cx), ["X-Gate-2", "X-Zone", "X-New"]);
            assert_eq!(
                forms::raw(&s.headers[1].value, cx),
                "",
                "the saved value shows"
            );
            assert_eq!(forms::raw(&s.headers[2].value, cx), "new-1");
            assert!(s.dirty(cx), "the later headers count as saved");
        });
        on_sheet(vcx, &sheet, |s, w, cx| s.save(w, cx));
        vcx.run_until_parked();
        let saves = daemon.calls::<methods::HermesConnectionsSave>();
        assert_eq!(saves.len(), 2);
        let sent = saves[1]["accessHeaders"]
            .as_array()
            .expect("the headers are sent");
        assert_eq!(sent.len(), 3);
        assert_eq!(
            (&sent[0]["name"], &sent[0]["savedName"]),
            (&json!("X-Gate-2"), &json!("X-Gate")),
            "the renamed header keeps its saved value"
        );
        assert_eq!(sent[2]["value"], json!("new-1"));
    }

    /// A header renamed by a Save, then renamed again while that Save is
    /// out, keeps its saved value: the next Save renames the header the
    /// first one saved, and sends no value.
    #[gpui_kit::test]
    fn a_header_renamed_again_during_its_save_keeps_its_value(cx: &mut gpui_kit::TestAppContext) {
        let (daemon, stores, vcx) = bench(cx);
        daemon.returns::<methods::HermesConnectionsSave>(with_headers(
            "a",
            Some("b"),
            &["X-Gate-2"],
        ));
        stores.hermes_admin.update(vcx, |a, cx| {
            a.adopt_connections(with_headers("a", None, &["X-Gate"]), cx)
        });
        let s = stores.clone();
        vcx.update(|window, cx| open(&s, Some("b".into()), window, cx));
        vcx.run_until_parked();
        let sheet = vcx
            .update(|_, cx| sheet::current::<HermesConnectionSheet>(cx))
            .expect("the editor opens");
        let held = daemon.hold::<methods::HermesConnectionsSave>();
        on_sheet(vcx, &sheet, |s, w, cx| {
            s.headers[0]
                .name
                .update(cx, |i, cx| i.set_value("X-Gate-2", w, cx));
            s.save(w, cx);
            s.headers[0]
                .name
                .update(cx, |i, cx| i.set_value("X-Gate-3", w, cx));
        });
        drop(held);
        vcx.run_until_parked();
        on_sheet(vcx, &sheet, |s, w, cx| s.save(w, cx));
        vcx.run_until_parked();
        let saves = daemon.calls::<methods::HermesConnectionsSave>();
        assert_eq!(saves.len(), 2);
        let first = saves[0]["accessHeaders"]
            .as_array()
            .expect("the rename is sent");
        assert_eq!(
            (&first[0]["name"], &first[0]["savedName"]),
            (&json!("X-Gate-2"), &json!("X-Gate"))
        );
        let next = saves[1]["accessHeaders"]
            .as_array()
            .expect("the rename is sent");
        assert_eq!(next.len(), 1);
        assert_eq!(
            (&next[0]["name"], &next[0]["savedName"]),
            (&json!("X-Gate-3"), &json!("X-Gate-2")),
            "the saved value is lost"
        );
        assert!(
            next[0].get("value").is_none_or(|v| v.is_null()),
            "an empty value is sent"
        );
    }

    /// A profile picked while Refresh Profiles is out stays picked.
    #[gpui_kit::test]
    fn a_profile_picked_during_a_refresh_stays(cx: &mut gpui_kit::TestAppContext) {
        let (daemon, stores, vcx) = bench(cx);
        daemon.returns::<methods::HermesConnectionsProfiles>(
            serde_json::from_value(json!({
                "profiles": ["default", "research"],
                "selected": "default",
            }))
            .unwrap(),
        );
        let held = daemon.hold::<methods::HermesConnectionsProfiles>();
        let sheet = open_b(&stores, vcx, "nativePkce");
        on_sheet(vcx, &sheet, |s, w, cx| s.choose_profile("research", w, cx));
        drop(held);
        vcx.run_until_parked();
        vcx.update(|_, cx| {
            let s = sheet.read(cx);
            assert_eq!(s.profile, "research", "the refresh undid the pick");
            assert_eq!(s.profiles.names, ["default", "research"]);
        });
    }

    /// A saved memory key can be cleared (the daemon then makes one).
    #[gpui_kit::test]
    fn a_saved_memory_key_can_be_cleared(cx: &mut gpui_kit::TestAppContext) {
        let api = |saved: Option<&str>, has_key: bool| {
            let mut l = list("a", saved, "nativePkce");
            l.connections[1].mode = "responses".into();
            l.connections[1].has_memory_key = has_key;
            l
        };
        let (daemon, stores, vcx) = bench(cx);
        daemon.returns::<methods::HermesConnectionsSave>(api(Some("b"), false));
        stores
            .hermes_admin
            .update(vcx, |a, cx| a.adopt_connections(api(None, true), cx));
        let s = stores.clone();
        vcx.update(|window, cx| open(&s, Some("b".into()), window, cx));
        vcx.run_until_parked();
        let sheet = vcx
            .update(|_, cx| sheet::current::<HermesConnectionSheet>(cx))
            .expect("the editor opens");
        vcx.update(|_, cx| assert!(!sheet.read(cx).dirty(cx)));
        on_sheet(vcx, &sheet, |s, w, cx| s.clear_memory_key(w, cx));
        vcx.update(|_, cx| assert!(sheet::has_unsaved(cx), "Quit would not ask"));
        on_sheet(vcx, &sheet, |s, w, cx| s.save(w, cx));
        vcx.run_until_parked();
        let saves = daemon.calls::<methods::HermesConnectionsSave>();
        assert_eq!(saves.len(), 1);
        assert_eq!(saves[0]["memoryKey"], json!(""), "the saved key is kept");
        vcx.update(|_, cx| {
            assert!(
                sheet::current::<HermesConnectionSheet>(cx).is_none(),
                "the editor stayed open once the key was cleared"
            )
        });
    }

    /// Clear after a replacement key was typed clears (the typed key goes
    /// too); a key typed after Clear is the one saved.
    #[gpui_kit::test]
    fn clear_and_typing_each_win_when_they_come_last(cx: &mut gpui_kit::TestAppContext) {
        let api = |saved: Option<&str>| {
            let mut l = list("a", saved, "nativePkce");
            l.connections[1].mode = "responses".into();
            l.connections[1].has_memory_key = true;
            l
        };
        for clear_last in [true, false] {
            let (daemon, stores, vcx) = bench(cx);
            daemon.returns::<methods::HermesConnectionsSave>(api(Some("b")));
            stores
                .hermes_admin
                .update(vcx, |a, cx| a.adopt_connections(api(None), cx));
            let s = stores.clone();
            vcx.update(|window, cx| open(&s, Some("b".into()), window, cx));
            vcx.run_until_parked();
            let sheet = vcx
                .update(|_, cx| sheet::current::<HermesConnectionSheet>(cx))
                .expect("the editor opens");
            on_sheet(vcx, &sheet, |s, w, cx| {
                let type_key =
                    |s: &mut HermesConnectionSheet,
                     w: &mut Window,
                     cx: &mut Context<HermesConnectionSheet>| {
                        s.memory_key
                            .update(cx, |i, cx| i.set_value("synthetic-memory-key", w, cx))
                    };
                if clear_last {
                    type_key(s, w, cx);
                    s.clear_memory_key(w, cx);
                } else {
                    s.clear_memory_key(w, cx);
                    type_key(s, w, cx);
                }
                s.save(w, cx);
            });
            vcx.run_until_parked();
            let saves = daemon.calls::<methods::HermesConnectionsSave>();
            assert_eq!(saves.len(), 1);
            let want = if clear_last {
                ""
            } else {
                "synthetic-memory-key"
            };
            assert_eq!(
                saves[0]["memoryKey"],
                json!(want),
                "clear last: {clear_last}"
            );
        }
    }

    /// Clear, then a replacement typed and saved: the Save carried the
    /// clear (the replacement is what it saved), so a later Save that
    /// leaves the key alone keeps the replacement instead of clearing it.
    #[gpui_kit::test]
    fn a_saved_replacement_ends_the_clear(cx: &mut gpui_kit::TestAppContext) {
        let api = |saved: Option<&str>| {
            let mut l = list("a", saved, "nativePkce");
            l.connections[1].mode = "responses".into();
            l.connections[1].has_memory_key = true;
            l
        };
        let (daemon, stores, vcx) = bench(cx);
        daemon.returns::<methods::HermesConnectionsSave>(api(Some("b")));
        stores
            .hermes_admin
            .update(vcx, |a, cx| a.adopt_connections(api(None), cx));
        let s = stores.clone();
        vcx.update(|window, cx| open(&s, Some("b".into()), window, cx));
        vcx.run_until_parked();
        let sheet = vcx
            .update(|_, cx| sheet::current::<HermesConnectionSheet>(cx))
            .expect("the editor opens");
        let held = daemon.hold::<methods::HermesConnectionsSave>();
        on_sheet(vcx, &sheet, |s, w, cx| {
            s.clear_memory_key(w, cx);
            s.memory_key
                .update(cx, |i, cx| i.set_value("synthetic-memory-key", w, cx));
            s.save(w, cx);
        });
        // A word typed while the Save is out keeps the editor open.
        on_sheet(vcx, &sheet, |s, w, cx| {
            s.name.update(cx, |i, cx| i.set_value("Cold frame", w, cx))
        });
        drop(held);
        vcx.run_until_parked();
        vcx.update(|_, cx| assert!(sheet::current::<HermesConnectionSheet>(cx).is_some()));
        on_sheet(vcx, &sheet, |s, w, cx| s.save(w, cx));
        vcx.run_until_parked();
        let saves = daemon.calls::<methods::HermesConnectionsSave>();
        assert_eq!(saves.len(), 2);
        assert_eq!(saves[0]["memoryKey"], json!("synthetic-memory-key"));
        assert!(
            saves[1]["memoryKey"].is_null(),
            "the second Save cleared the saved replacement: {}",
            saves[1]["memoryKey"]
        );
    }

    /// "b" on the API with a memory key saved; `saved` names the connection
    /// a Save answers for.
    fn api_with_memory_key(saved: Option<&str>) -> HermesConnections {
        let mut l = list("a", saved, "nativePkce");
        l.connections[1].mode = "responses".into();
        l.connections[1].has_memory_key = true;
        l
    }

    /// A Gateway Save of the open sheet, kept open by a word typed while it
    /// is out, answered with "b" as a Gateway that still has its key.
    fn gateway_save(
        daemon: &FakeDaemon,
        vcx: &mut VisualTestContext,
        sheet: &Entity<HermesConnectionSheet>,
    ) {
        let mut gateway = api_with_memory_key(Some("b"));
        gateway.connections[1].mode = "desktop".into();
        daemon.returns::<methods::HermesConnectionsSave>(gateway);
        let held = daemon.hold::<methods::HermesConnectionsSave>();
        on_sheet(vcx, sheet, |s, w, cx| s.save(w, cx));
        on_sheet(vcx, sheet, |s, w, cx| {
            s.name.update(cx, |i, cx| i.set_value("Cold frame", w, cx))
        });
        drop(held);
        vcx.run_until_parked();
        vcx.update(|_, cx| assert!(sheet::current::<HermesConnectionSheet>(cx).is_some()));
    }

    /// Clear, then the Mode switched to a Desktop Gateway: a Gateway Save
    /// carries no memory key, so the pending Clear is discarded and no
    /// longer counts as unsaved. After a Gateway Save and back to the API,
    /// the saved key is kept and the next API Save sends no memory key.
    #[gpui_kit::test]
    fn switching_to_a_gateway_discards_a_pending_clear(cx: &mut gpui_kit::TestAppContext) {
        let (daemon, stores, vcx) = bench(cx);
        stores.hermes_admin.update(vcx, |a, cx| {
            a.adopt_connections(api_with_memory_key(None), cx)
        });
        let s = stores.clone();
        vcx.update(|window, cx| open(&s, Some("b".into()), window, cx));
        vcx.run_until_parked();
        let sheet = vcx
            .update(|_, cx| sheet::current::<HermesConnectionSheet>(cx))
            .expect("the editor opens");
        on_sheet(vcx, &sheet, |s, w, cx| s.clear_memory_key(w, cx));
        vcx.update(|_, cx| assert!(sheet::has_unsaved(cx)));
        on_sheet(vcx, &sheet, |s, w, cx| {
            s.choose_mode(true, w, cx);
            s.choose_mode(false, w, cx);
        });
        vcx.update(|_, cx| {
            assert!(!sheet.read(cx).memory_cleared);
            assert!(!sheet::has_unsaved(cx), "the discarded Clear still counts");
        });
        on_sheet(vcx, &sheet, |s, w, cx| {
            s.clear_memory_key(w, cx);
            s.choose_mode(true, w, cx);
        });
        gateway_save(&daemon, vcx, &sheet);
        on_sheet(vcx, &sheet, |s, w, cx| {
            s.choose_mode(false, w, cx);
            s.save(w, cx);
        });
        vcx.run_until_parked();
        let saves = daemon.calls::<methods::HermesConnectionsSave>();
        assert_eq!(saves.len(), 2, "{saves:?}");
        assert!(saves[0]["memoryKey"].is_null(), "{}", saves[0]["memoryKey"]);
        assert!(
            saves[1]["memoryKey"].is_null(),
            "the saved key was cleared: {}",
            saves[1]["memoryKey"]
        );
    }

    /// Clear and a replacement typed, then the Mode switched to a Desktop
    /// Gateway: both are discarded (the field is empty again), so nothing
    /// is blanked by the Gateway Save's answer or cleared by a later API
    /// Save.
    #[gpui_kit::test]
    fn switching_to_a_gateway_discards_a_typed_replacement(cx: &mut gpui_kit::TestAppContext) {
        let (daemon, stores, vcx) = bench(cx);
        stores.hermes_admin.update(vcx, |a, cx| {
            a.adopt_connections(api_with_memory_key(None), cx)
        });
        let s = stores.clone();
        vcx.update(|window, cx| open(&s, Some("b".into()), window, cx));
        vcx.run_until_parked();
        let sheet = vcx
            .update(|_, cx| sheet::current::<HermesConnectionSheet>(cx))
            .expect("the editor opens");
        on_sheet(vcx, &sheet, |s, w, cx| {
            s.clear_memory_key(w, cx);
            s.memory_key
                .update(cx, |i, cx| i.set_value("synthetic-memory-key", w, cx));
            s.choose_mode(true, w, cx);
        });
        vcx.update(|_, cx| {
            let s = sheet.read(cx);
            assert!(!s.memory_cleared);
            assert_eq!(forms::raw(&s.memory_key, cx), "");
        });
        gateway_save(&daemon, vcx, &sheet);
        on_sheet(vcx, &sheet, |s, w, cx| {
            s.choose_mode(false, w, cx);
            s.save(w, cx);
        });
        vcx.run_until_parked();
        let saves = daemon.calls::<methods::HermesConnectionsSave>();
        assert_eq!(saves.len(), 2, "{saves:?}");
        assert!(saves[0]["memoryKey"].is_null(), "{}", saves[0]["memoryKey"]);
        assert!(
            saves[1]["memoryKey"].is_null(),
            "the saved key was cleared or replaced: {}",
            saves[1]["memoryKey"]
        );
    }

    /// Typed words make Quit ask first.
    #[gpui_kit::test]
    fn typed_words_make_quit_ask(cx: &mut gpui_kit::TestAppContext) {
        let (_daemon, stores, vcx) = bench(cx);
        let sheet = open_b(&stores, vcx, "nativePkce");
        vcx.update(|_, cx| assert!(!sheet::has_unsaved(cx)));
        on_sheet(vcx, &sheet, |s, w, cx| {
            s.name.update(cx, |i, cx| i.set_value("Cold frame", w, cx))
        });
        vcx.update(|_, cx| assert!(sheet::has_unsaved(cx), "Quit would not ask"));
    }
}
