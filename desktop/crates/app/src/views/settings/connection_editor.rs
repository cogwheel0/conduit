//! Add Tool Server, Edit Tool Server, Add Terminal and Edit Terminal: one
//! personal connection in a sheet on the Settings window, as the phone's
//! editor has it.
//!
//! A tool server has a name and description, its URL, where its OpenAPI
//! document comes from (fetched from a path, or pasted as JSON) and how it
//! authenticates (a bearer key, or none). A terminal has a name, URL, path
//! and key. The stored key never comes back: an edit keeps it unless a new
//! one is typed or Remove Saved Key is chosen, and never past an origin
//! change: a URL on another scheme, host or port removes it unless a new
//! key is typed. The daemon decides that against the entry as stored when
//! it saves (or tests), so the editor sends Keep unless asked to replace or
//! remove the key; the form only says so ([`key_goes`]). Test Connection reads the
//! document (or checks the terminal) with the form as it stands, without
//! saving. A connection the editor cannot read (another auth mode) shows
//! what it can and can still be switched or deleted. The drafts, checks and
//! patches are core's (`integrations.*`).

use std::rc::Rc;

use conduit_components::ActiveConduitTheme as _;
use conduit_components::announce::{Priority, live_text};
use conduit_components::views::kit::{Button, Segment, Segmented, Switch, setting_row};
use conduit_components::views::settings::settings_section;
use conduit_daemon::RpcError;
use conduit_protocol::{
    NoParams, PersonalConnectionDraft, PersonalConnectionDto, PersonalConnectionSave,
    PersonalConnectionTest, PersonalConnectionTestResult, PersonalConnections, PersonalEditOp,
    PersonalKeyMode, PersonalKind, PersonalProbeFailure, methods,
};
use gpui_kit::component::input::{InputState, Textarea, TextareaState};
use gpui_kit::prelude::*;
use gpui_kit::{
    AnyElement, AnyWindowHandle, App, AsyncApp, Context, Entity, FontWeight, Role, SharedString,
    WeakEntity, Window, div, px, relative,
};

use crate::l10n::{ActiveL10n as _, L10n};
use crate::shell::sheet::{SheetSpec, present_sheet};
use crate::stores::Stores;
use crate::views::forms;
use crate::views::sheet::{self, SheetBody};

use super::connections::save_error;
use super::controls;

/// The sheet's width.
pub const WIDTH: f32 = 580.;

/// What runs with the list a change answered.
pub type OnChange = Rc<dyn Fn(PersonalConnections, &mut App)>;

const SPEC_TYPES: [&str; 2] = ["url", "json"];
const AUTH_TYPES: [&str; 2] = ["bearer", "none"];

/// What the form says about each field, from the core's checks.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Issues {
    pub url: Option<String>,
    pub path: Option<String>,
    pub spec: Option<String>,
}

/// A test's outcome, shown under the form until a field changes.
#[derive(Clone, Debug, PartialEq)]
pub struct Attempt {
    pub ok: bool,
    pub text: String,
    /// The answer it came from ([`ConnectionEditorSheet::answers`]): its
    /// live region's attempt, so a later answer does not say it again.
    pub answer: u64,
}

/// The text fields' values, field by field.
#[derive(Clone, Debug, Default, PartialEq)]
struct Texts {
    name: String,
    description: String,
    url: String,
    path: String,
    key: String,
    spec: String,
}

/// What the form holds, field by field: compared as fields, so text in one
/// field can never pass for text in the next.
#[derive(Clone, Debug, PartialEq)]
struct Fingerprint {
    name: String,
    description: String,
    url: String,
    path: String,
    spec: String,
    key_typed: bool,
    spec_type: String,
    auth_type: String,
    key_mode: PersonalKeyMode,
    enabled: bool,
}

pub struct ConnectionEditorSheet {
    stores: Stores,
    owner: String,
    pub kind: PersonalKind,
    /// The entry edited; None for a new one.
    pub entry: Option<PersonalConnectionDto>,
    pub name: Entity<InputState>,
    pub description: Entity<InputState>,
    pub url: Entity<InputState>,
    pub path: Entity<InputState>,
    pub key: Entity<InputState>,
    pub spec: Entity<TextareaState>,
    pub spec_type: String,
    pub auth_type: String,
    pub key_mode: PersonalKeyMode,
    pub enabled: bool,
    pub saving: bool,
    /// A conflict reload's list read is out: the form is locked until it
    /// settles.
    pub reloading: bool,
    pub testing: bool,
    pub deleting: bool,
    pub issues: Issues,
    /// Counts the requests answered (Save, Test, the switch, Delete). Each
    /// piece of feedback takes the count of the answer it came from as its
    /// live region's attempt (the form's error, always the latest answer's;
    /// [`Attempt::answer`]; [`Self::issues_answer`]), so each answer is
    /// heard, even in the words of the one before, and neither a redraw nor
    /// a later answer says an earlier one's again.
    answers: u64,
    /// The answer [`Self::issues`] came from.
    issues_answer: u64,
    pub attempt: Option<Attempt>,
    pub error: Option<String>,
    /// The form as it opened, to tell whether it was changed.
    initial: Fingerprint,
    /// The text fields as last seen: an input's notification is an edit
    /// only when one of them differs (unlocking a field, or drawing it,
    /// notifies too, and must not clear the feedback a request just gave).
    seen: Texts,
    on_change: OnChange,
    /// The sheet's window, to fill the fields again after a reload.
    window: AnyWindowHandle,
}

impl ConnectionEditorSheet {
    pub fn open(
        stores: Stores,
        owner: String,
        kind: PersonalKind,
        entry: Option<PersonalConnectionDto>,
        on_change: OnChange,
        parent: &Window,
        cx: &mut App,
    ) -> Option<Entity<Self>> {
        sheet::open(parent, WIDTH, cx, move |window, cx| {
            Self::new(stores, owner, kind, entry, on_change, window, cx)
        })
    }

    fn new(
        stores: Stores,
        owner: String,
        kind: PersonalKind,
        entry: Option<PersonalConnectionDto>,
        on_change: OnChange,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Self {
        let l10n = cx.l10n().clone();
        let tool = kind == PersonalKind::ToolServer;
        let name = forms::input(l10n.name(), false, window, cx);
        let description = forms::input(String::new(), false, window, cx);
        let url = forms::input("https://tools.example.com", false, window, cx);
        let path = forms::input(
            if tool {
                "openapi.json"
            } else {
                "/openapi.json"
            },
            false,
            window,
            cx,
        );
        let key = forms::input(String::new(), true, window, cx);
        let spec = cx.new(|cx| TextareaState::new(window, cx).auto_grow(4, 12));
        let fill = |state: &Entity<InputState>, value: &str, window: &mut Window, cx: &mut App| {
            let value = value.to_string();
            state.update(cx, |s, cx| s.set_value(value, window, cx));
        };
        let (spec_type, auth_type, key_mode, enabled);
        match &entry {
            Some(e) => {
                fill(&name, &e.name, window, cx);
                fill(&description, &e.description, window, cx);
                fill(&url, &e.url, window, cx);
                fill(&path, &e.path, window, cx);
                let text = e.spec.clone();
                spec.update(cx, |s, cx| s.set_value(text, window, cx));
                spec_type = spec_type_of(e);
                auth_type = auth_type_of(e);
                key_mode = PersonalKeyMode::Keep;
                enabled = e.enabled;
            }
            None => {
                // The core's new drafts: a tool server reads openapi.json
                // with a bearer key and starts on; a terminal starts off.
                fill(
                    &path,
                    if tool {
                        "openapi.json"
                    } else {
                        "/openapi.json"
                    },
                    window,
                    cx,
                );
                spec_type = "url";
                auth_type = "bearer";
                key_mode = PersonalKeyMode::Replace;
                enabled = tool;
            }
        }
        for state in [&name, &description, &url, &path] {
            cx.observe(state, |this: &mut Self, _, cx| this.typed(cx))
                .detach();
        }
        cx.observe(&key, |this: &mut Self, key, cx| {
            if !this.text_changed(cx) {
                return;
            }
            // On an entry, typing a key replaces the stored one (or gives a
            // keyless one its first); clearing it keeps what is stored.
            if this.entry.is_some() {
                let typed = !forms::raw(&key, cx).is_empty();
                if typed {
                    this.key_mode = PersonalKeyMode::Replace;
                } else if this.key_mode == PersonalKeyMode::Replace {
                    this.key_mode = PersonalKeyMode::Keep;
                }
            }
            this.changed(cx);
        })
        .detach();
        cx.observe(&spec, |this: &mut Self, _, cx| this.typed(cx))
            .detach();
        name.update(cx, |s, cx| s.focus(window, cx));
        let mut this = Self {
            stores,
            owner,
            kind,
            entry,
            name,
            description,
            url,
            path,
            key,
            spec,
            spec_type: spec_type.into(),
            auth_type: auth_type.into(),
            key_mode,
            enabled,
            saving: false,
            reloading: false,
            testing: false,
            deleting: false,
            issues: Issues::default(),
            answers: 0,
            issues_answer: 0,
            attempt: None,
            error: None,
            initial: Fingerprint {
                name: String::new(),
                description: String::new(),
                url: String::new(),
                path: String::new(),
                spec: String::new(),
                key_typed: false,
                spec_type: String::new(),
                auth_type: String::new(),
                key_mode,
                enabled,
            },
            on_change,
            seen: Texts::default(),
            window: window.window_handle(),
        };
        this.initial = this.fingerprint(cx);
        this.seen = this.texts(cx);
        this
    }

    fn tool(&self) -> bool {
        self.kind == PersonalKind::ToolServer
    }

    fn read_only(&self) -> bool {
        self.entry.as_ref().is_some_and(|e| !e.editable)
    }

    pub fn in_flight(&self) -> bool {
        self.saving || self.reloading || self.testing || self.deleting
    }

    /// Test Connection, as its button presses it.
    pub fn press_test(&mut self, cx: &mut Context<Self>) {
        self.test(cx);
    }

    /// Enabled, as its switch presses it: the form's value, or on a
    /// connection the editor can't read (no Save), a change saved at once.
    pub fn press_switch(&mut self, cx: &mut Context<Self>) {
        if self.read_only() {
            self.switch_now(!self.enabled, cx);
        } else {
            self.enabled = !self.enabled;
            self.changed(cx);
        }
    }

    /// Delete…, as its button presses it.
    pub fn press_delete(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.delete(window, cx);
    }

    fn texts(&self, cx: &App) -> Texts {
        Texts {
            name: forms::raw(&self.name, cx),
            description: forms::raw(&self.description, cx),
            url: forms::raw(&self.url, cx),
            path: forms::raw(&self.path, cx),
            key: forms::raw(&self.key, cx),
            spec: self.spec.read(cx).value().to_string(),
        }
    }

    /// Whether a text field's value differs from the last one seen (and now
    /// it is the one seen): the one test of a real edit for every input's
    /// notification.
    fn text_changed(&mut self, cx: &App) -> bool {
        let now = self.texts(cx);
        if now == self.seen {
            return false;
        }
        self.seen = now;
        true
    }

    /// An input notified: [`Self::changed`] only for a real edit.
    fn typed(&mut self, cx: &mut Context<Self>) {
        if self.text_changed(cx) {
            self.changed(cx);
        }
    }

    /// Any change makes an earlier test result, and the issues the core
    /// found in the form as it was, out of date.
    fn changed(&mut self, cx: &mut Context<Self>) {
        self.attempt = None;
        self.issues = Issues::default();
        cx.notify();
    }

    /// The fields take no typing while a save or test is out: its answer is
    /// about the form as it stands, so a save never closes over words typed
    /// after it went and a test never judges a newer form. (The segments,
    /// switch and key button already wait on [`Self::in_flight`].)
    fn locked(&self) -> bool {
        self.in_flight()
    }

    fn fingerprint(&self, cx: &App) -> Fingerprint {
        Fingerprint {
            name: forms::raw(&self.name, cx),
            description: forms::raw(&self.description, cx),
            url: forms::raw(&self.url, cx),
            path: forms::raw(&self.path, cx),
            spec: self.spec.read(cx).value().to_string(),
            key_typed: !forms::raw(&self.key, cx).is_empty(),
            spec_type: self.spec_type.clone(),
            auth_type: self.auth_type.clone(),
            key_mode: self.key_mode,
            enabled: self.enabled,
        }
    }

    pub fn is_dirty(&self, cx: &App) -> bool {
        !self.read_only() && self.fingerprint(cx) != self.initial
    }

    /// What the form says happens to the saved key: the form's mode, except
    /// that a kept key goes when the save takes the connection, or where
    /// its OpenAPI document is fetched from, to another origin
    /// ([`key_goes`], the core's `mergePersonalConnectionEdit` rule). Only
    /// shown: Save and Test send the form's own mode, and the daemon
    /// removes a kept key against the entry as stored then. That is the
    /// entry this editor holds whenever a save lands: one another client
    /// changed since is refused, and the form fills from it again.
    fn key_mode_now(&self, cx: &App) -> PersonalKeyMode {
        match &self.entry {
            Some(e)
                if self.key_mode == PersonalKeyMode::Keep
                    && key_goes(
                        e,
                        &forms::raw(&self.url, cx),
                        &self.spec_type,
                        &forms::raw(&self.path, cx),
                    ) =>
            {
                PersonalKeyMode::Clear
            }
            _ => self.key_mode,
        }
    }

    pub fn draft(&self, cx: &App) -> PersonalConnectionDraft {
        PersonalConnectionDraft {
            name: forms::raw(&self.name, cx),
            description: forms::raw(&self.description, cx),
            url: forms::raw(&self.url, cx),
            spec_type: self.spec_type.clone(),
            path: forms::raw(&self.path, cx),
            spec: self.spec.read(cx).value().to_string(),
            auth_type: self.auth_type.clone(),
            key: forms::raw(&self.key, cx),
            key_mode: self.key_mode,
            enabled: self.enabled,
        }
    }

    fn rpc(&self, cx: &App) -> crate::stores::rpc::Rpc {
        self.stores.connection.read(cx).rpc()
    }

    /// The core's issues for each field, in the phone's words.
    fn issues_from(e: &RpcError, l10n: &L10n) -> Option<Issues> {
        let text = |field: &str| {
            e.args.get(field).map(|issue| match issue.as_str() {
                "urlRequired" => l10n.personal_connections_url_required(),
                "urlInvalid" => l10n.personal_connections_url_invalid(),
                "pathRequired" => l10n.personal_connections_path_required(),
                "specInvalid" => l10n.personal_connections_spec_invalid(),
                _ => l10n.personal_connections_save_failed(),
            })
        };
        let issues = Issues {
            url: text("url"),
            path: text("path"),
            spec: text("spec"),
        };
        (issues != Issues::default()).then_some(issues)
    }

    pub fn save(&mut self, cx: &mut Context<Self>) {
        if self.in_flight() || self.read_only() {
            return;
        }
        let (op, identity) = match &self.entry {
            Some(e) => (PersonalEditOp::Patch, Some(e.identity.clone())),
            None => (PersonalEditOp::Add, None),
        };
        let call = self
            .rpc(cx)
            .call::<methods::IntegrationsSave>(&PersonalConnectionSave {
                owner: self.owner.clone(),
                kind: self.kind,
                op,
                identity,
                draft: Some(self.draft(cx)),
                enabled: None,
                fingerprint: self.entry.as_ref().map(|e| e.fingerprint.clone()),
            });
        self.saving = true;
        self.error = None;
        cx.notify();
        let on_change = self.on_change.clone();
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result = call.await;
            let _ = this.update(cx, |s, cx| {
                s.saving = false;
                s.answers += 1;
                let l10n = cx.l10n().clone();
                match result {
                    Ok(list) => {
                        let stale = list.saved_for_previous_account;
                        on_change(list, cx);
                        if stale {
                            // Saved for the account this was opened under;
                            // the form stays to say so.
                            s.error = Some(l10n.personal_connections_saved_for_previous_account());
                        } else {
                            sheet::dismiss(cx);
                        }
                    }
                    Err(e) => {
                        log::warn!("integrations.save: {e}");
                        match Self::issues_from(&e, &l10n) {
                            Some(issues) => {
                                s.issues = issues;
                                s.issues_answer = s.answers;
                            }
                            None => s.error = Some(save_error(&e, &l10n)),
                        }
                        s.reload_if_changed(&e, cx);
                    }
                }
                cx.notify();
            });
        })
        .detach();
    }

    fn test(&mut self, cx: &mut Context<Self>) {
        if self.in_flight() || self.read_only() {
            return;
        }
        let call = self
            .rpc(cx)
            .call::<methods::IntegrationsTest>(&PersonalConnectionTest {
                owner: self.owner.clone(),
                kind: self.kind,
                identity: self.entry.as_ref().map(|e| e.identity.clone()),
                draft: self.draft(cx),
                fingerprint: self.entry.as_ref().map(|e| e.fingerprint.clone()),
            });
        self.testing = true;
        self.attempt = None;
        self.error = None;
        cx.notify();
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result = call.await;
            let _ = this.update(cx, |s, cx| {
                s.testing = false;
                s.answers += 1;
                let l10n = cx.l10n().clone();
                match result {
                    Ok(result) => {
                        s.issues = Issues::default();
                        s.attempt = Some(attempt(&result, s.answers, &l10n));
                    }
                    Err(e) => {
                        match Self::issues_from(&e, &l10n) {
                            Some(issues) => {
                                s.issues = issues;
                                s.issues_answer = s.answers;
                            }
                            None => {
                                s.attempt = Some(Attempt {
                                    ok: false,
                                    text: save_error(&e, &l10n),
                                    answer: s.answers,
                                })
                            }
                        }
                        s.reload_if_changed(&e, cx);
                    }
                }
                cx.notify();
            });
        })
        .detach();
    }

    /// The daemon refused a save or test because the entry changed since this
    /// editor opened it (reason `changed`): the list is read again and the
    /// form fills from the entry as it is now, its typed changes gone (the
    /// refusal says so); an entry that went stays as it was. The read is in
    /// flight like a save: the form is locked until it settles, either way.
    /// Only a list this account's read gave in full replaces the pane's and
    /// fills the form; a failed one leaves both (the form keeps its
    /// fingerprint, so its next Save is refused and reloads again).
    fn reload_if_changed(&mut self, e: &RpcError, cx: &mut Context<Self>) {
        if e.args.get("reason").map(String::as_str) != Some("changed") {
            return;
        }
        let Some(identity) = self.entry.as_ref().map(|e| e.identity.clone()) else {
            return;
        };
        let call = self.rpc(cx).call::<methods::IntegrationsList>(&NoParams);
        let on_change = self.on_change.clone();
        let handle = self.window;
        self.reloading = true;
        cx.notify();
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result = call.await;
            let settled = handle.update(cx, |_, window, cx| {
                let _ = this.update(cx, |s, cx| {
                    s.reloading = false;
                    if let Ok(list) = result
                        && !list.failed
                        && list.owner == s.owner
                    {
                        let fresh = list
                            .tool_servers
                            .iter()
                            .chain(&list.terminals)
                            .find(|e| e.kind == s.kind && e.identity == identity)
                            .cloned();
                        on_change(list, cx);
                        if let Some(entry) = fresh {
                            s.fill(entry, window, cx);
                        }
                    }
                    cx.notify();
                });
            });
            if settled.is_err() {
                let _ = this.update(cx, |s, cx| {
                    s.reloading = false;
                    cx.notify();
                });
            }
        })
        .detach();
    }

    /// The form as [`Self::new`] fills it from `entry`, which becomes the
    /// entry edited (its fingerprint the one sent back).
    fn fill(&mut self, entry: PersonalConnectionDto, window: &mut Window, cx: &mut Context<Self>) {
        for (state, value) in [
            (&self.name, entry.name.clone()),
            (&self.description, entry.description.clone()),
            (&self.url, entry.url.clone()),
            (&self.path, entry.path.clone()),
            (&self.key, String::new()),
        ] {
            state.update(cx, |s, cx| s.set_value(value, window, cx));
        }
        let text = entry.spec.clone();
        self.spec.update(cx, |s, cx| s.set_value(text, window, cx));
        self.spec_type = spec_type_of(&entry).into();
        self.auth_type = auth_type_of(&entry).into();
        self.key_mode = PersonalKeyMode::Keep;
        self.enabled = entry.enabled;
        self.entry = Some(entry);
        self.initial = self.fingerprint(cx);
        self.seen = self.texts(cx);
    }

    /// A connection the editor can't read has no Save: its switch saves at
    /// once (`setEnabled`), as its row's switch does, and goes back with the
    /// reason when that is refused.
    fn switch_now(&mut self, on: bool, cx: &mut Context<Self>) {
        let Some(entry) = self.entry.clone() else {
            return;
        };
        if self.in_flight() {
            return;
        }
        let call = self
            .rpc(cx)
            .call::<methods::IntegrationsSave>(&PersonalConnectionSave {
                owner: self.owner.clone(),
                kind: self.kind,
                op: PersonalEditOp::SetEnabled,
                identity: Some(entry.identity.clone()),
                draft: None,
                enabled: Some(on),
                fingerprint: None,
            });
        self.saving = true;
        self.enabled = on;
        self.error = None;
        cx.notify();
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result = call.await;
            let _ = this.update(cx, |s, cx| {
                s.saving = false;
                s.answers += 1;
                let l10n = cx.l10n().clone();
                match result {
                    Ok(list) => {
                        if list.saved_for_previous_account {
                            s.error = Some(l10n.personal_connections_saved_for_previous_account());
                        } else if let Some(saved) = list
                            .tool_servers
                            .iter()
                            .chain(&list.terminals)
                            .find(|e| e.kind == s.kind && e.identity == entry.identity)
                        {
                            s.enabled = saved.enabled;
                            s.entry = Some(saved.clone());
                        }
                        (s.on_change)(list, cx);
                    }
                    Err(e) => {
                        log::warn!("integrations.save setEnabled: {e}");
                        s.enabled = !on;
                        s.error = Some(save_error(&e, &l10n));
                    }
                }
                cx.notify();
            });
        })
        .detach();
    }

    fn delete(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(entry) = self.entry.clone() else {
            return;
        };
        if self.in_flight() {
            return;
        }
        let l10n = cx.l10n().clone();
        let spec = SheetSpec::new(
            l10n.personal_connections_delete_title(),
            l10n.personal_connections_delete_message(&entry.name),
            l10n.delete(),
            l10n.cancel(),
        )
        .destructive();
        let ask = present_sheet(window, spec, cx);
        let owner = self.owner.clone();
        let kind = self.kind;
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            if !ask.await {
                return;
            }
            let Ok(call) = this.update(cx, |s, cx| {
                s.deleting = true;
                s.error = None;
                cx.notify();
                s.rpc(cx)
                    .call::<methods::IntegrationsSave>(&PersonalConnectionSave {
                        owner,
                        kind,
                        op: PersonalEditOp::Remove,
                        identity: Some(entry.identity.clone()),
                        draft: None,
                        enabled: None,
                        fingerprint: None,
                    })
            }) else {
                return;
            };
            let result = call.await;
            let _ = this.update(cx, |s, cx| {
                s.deleting = false;
                s.answers += 1;
                match result {
                    Ok(list) => {
                        (s.on_change)(list, cx);
                        sheet::dismiss(cx);
                    }
                    Err(e) => {
                        log::warn!("integrations.save remove: {e}");
                        s.error = Some(save_error(&e, &cx.l10n().clone()));
                    }
                }
                cx.notify();
            });
        })
        .detach();
    }

    fn segmented(
        &self,
        id: &'static str,
        label: String,
        options: [(&'static str, String); 2],
        selected: &str,
        set: fn(&mut Self, &'static str),
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let view = cx.entity().downgrade();
        let busy = self.in_flight();
        let index = options
            .iter()
            .position(|(v, _)| *v == selected)
            .unwrap_or(0);
        let values: [&'static str; 2] = [options[0].0, options[1].0];
        Segmented::new(
            id,
            label,
            options
                .iter()
                .map(|(_, l)| Segment::new(l.clone()))
                .collect(),
            index,
        )
        .on_select(Rc::new(move |i, _, cx| {
            if busy {
                return;
            }
            let _ = view.update(cx, |v, cx| {
                set(v, values[i]);
                v.changed(cx);
            });
        }))
        .into_any_element()
    }

    fn key_row(&self, l10n: &L10n, window: &Window, cx: &mut Context<Self>) -> AnyElement {
        let stored = self.entry.as_ref().is_some_and(|e| e.has_key);
        let removing = self.key_mode == PersonalKeyMode::Clear;
        // Another origin: the saved key goes unless one is typed, and there
        // is no keeping it.
        let moved = stored
            && self.key_mode == PersonalKeyMode::Keep
            && self.key_mode_now(cx) == PersonalKeyMode::Clear;
        let help: Option<SharedString> = if removing || moved {
            Some(l10n.personal_connections_key_will_remove().into())
        } else if stored && self.key_mode == PersonalKeyMode::Keep {
            Some(l10n.personal_connections_key_kept().into())
        } else {
            None
        };
        let field = forms::field_locked(
            l10n.api_key(),
            &self.key,
            help,
            None,
            self.locked(),
            window,
            cx,
        );
        if !stored || moved {
            return field.into_any_element();
        }
        let view = cx.entity().downgrade();
        let toggle = Button::new(
            "connection-key-mode",
            if removing {
                l10n.personal_connections_key_keep()
            } else {
                l10n.personal_connections_key_remove()
            },
        )
        .ghost()
        .disabled(self.in_flight())
        .on_click(Rc::new(move |_, window, cx| {
            let _ = view.update(cx, |v, cx| {
                v.key_mode = if removing {
                    PersonalKeyMode::Keep
                } else {
                    PersonalKeyMode::Clear
                };
                v.key.update(cx, |s, cx| s.set_value("", window, cx));
                v.changed(cx);
            });
        }));
        div()
            .flex()
            .flex_col()
            .child(field)
            .child(
                controls::buttons(vec![toggle.into_any_element()])
                    .px(px(12.))
                    .pb(px(8.)),
            )
            .into_any_element()
    }

    fn form(&self, l10n: &L10n, window: &mut Window, cx: &mut Context<Self>) -> Vec<AnyElement> {
        let tool = self.tool();
        let locked = self.locked();
        let mut identity = vec![
            forms::field_locked(l10n.name(), &self.name, None, None, locked, window, cx)
                .into_any_element(),
        ];
        if tool {
            identity.push(
                forms::field_locked(
                    l10n.personal_connections_description_field(),
                    &self.description,
                    None,
                    None,
                    locked,
                    window,
                    cx,
                )
                .into_any_element(),
            );
        }
        identity.push(
            forms::field_answered(
                l10n.personal_connections_url(),
                &self.url,
                None,
                forms::Answer {
                    error: self.issues.url.clone().map(SharedString::from),
                    attempt: self.issues_answer,
                },
                locked,
                window,
                cx,
            )
            .into_any_element(),
        );
        let mut groups = vec![forms::form_group(identity, cx).into_any_element()];

        let mut access = vec![];
        if tool {
            access.push(
                setting_row(
                    l10n.personal_connections_auth(),
                    None,
                    self.segmented(
                        "connection-auth",
                        l10n.personal_connections_auth(),
                        [
                            ("bearer", l10n.direct_mcp_auth_bearer()),
                            ("none", l10n.direct_mcp_auth_none()),
                        ],
                        &self.auth_type,
                        |v, value| v.auth_type = value.into(),
                        cx,
                    ),
                    cx,
                )
                .into_any_element(),
            );
        }
        if !tool || self.auth_type == AUTH_TYPES[0] {
            access.push(self.key_row(l10n, window, cx));
        }
        groups.push(forms::form_group(access, cx).into_any_element());

        let mut document = vec![];
        if tool {
            document.push(
                setting_row(
                    l10n.personal_connections_spec_source(),
                    None,
                    self.segmented(
                        "connection-spec-type",
                        l10n.personal_connections_spec_source(),
                        [
                            ("url", l10n.personal_connections_spec_from_url()),
                            ("json", l10n.personal_connections_spec_inline()),
                        ],
                        &self.spec_type,
                        |v, value| v.spec_type = value.into(),
                        cx,
                    ),
                    cx,
                )
                .into_any_element(),
            );
        }
        if !tool || self.spec_type == SPEC_TYPES[0] {
            document.push(
                forms::field_answered(
                    l10n.personal_connections_path(),
                    &self.path,
                    None,
                    forms::Answer {
                        error: self.issues.path.clone().map(SharedString::from),
                        attempt: self.issues_answer,
                    },
                    locked,
                    window,
                    cx,
                )
                .into_any_element(),
            );
        } else {
            let t = cx.conduit().clone();
            document.push(
                div()
                    .p(px(12.))
                    .flex()
                    .flex_col()
                    .gap(px(6.))
                    .child(
                        div()
                            .text_size(px(t.metrics.control))
                            .child(l10n.personal_connections_spec_json()),
                    )
                    .child(Textarea::new(&self.spec).disabled(locked))
                    .when_some(self.issues.spec.clone(), |d, e| {
                        d.child(
                            div()
                                .id("connection-spec-issue")
                                .role(Role::Alert)
                                .text_size(px(t.metrics.small))
                                .text_color(t.roles.danger)
                                .child(e.clone())
                                .child(
                                    live_text("live", Some(e.into()), Priority::High)
                                        .attempt(self.issues_answer),
                                ),
                        )
                    })
                    .into_any_element(),
            );
        }
        groups.push(forms::form_group(document, cx).into_any_element());
        groups.push(self.enabled_group(l10n, cx));
        groups
    }

    fn enabled_group(&self, l10n: &L10n, cx: &mut Context<Self>) -> AnyElement {
        let view = cx.entity().downgrade();
        let on = self.enabled;
        let switch = Switch::new("connection-enabled", l10n.enabled_label(), on)
            .disabled(self.in_flight())
            .on_click(Rc::new(move |_, _, cx| {
                let _ = view.update(cx, |v, cx| v.press_switch(cx));
            }));
        settings_section(
            SharedString::default(),
            (!self.tool())
                .then(|| SharedString::from(l10n.personal_connections_terminal_one_active())),
            vec![setting_row(l10n.enabled_label(), None, switch, cx).into_any_element()],
            cx,
        )
        .into_any_element()
    }

    /// A connection the editor can't read: what it can show.
    fn read_only_form(&self, l10n: &L10n, cx: &mut Context<Self>) -> Vec<AnyElement> {
        let Some(entry) = &self.entry else {
            return vec![];
        };
        vec![
            controls::lead(l10n.personal_connections_unsupported(), cx).into_any_element(),
            settings_section(
                SharedString::default(),
                None,
                vec![
                    setting_row(
                        l10n.name(),
                        None,
                        controls::value(entry.name.clone(), cx),
                        cx,
                    )
                    .into_any_element(),
                    setting_row(
                        l10n.personal_connections_url(),
                        None,
                        controls::value(entry.endpoint.clone(), cx),
                        cx,
                    )
                    .into_any_element(),
                ],
                cx,
            )
            .into_any_element(),
        ]
    }

    fn title(&self, l10n: &L10n) -> String {
        match (self.tool(), self.entry.is_some()) {
            (true, false) => l10n.personal_connections_add_tool_server(),
            (true, true) => l10n.personal_connections_edit_tool_server(),
            (false, false) => l10n.personal_connections_add_terminal(),
            (false, true) => l10n.personal_connections_edit_terminal(),
        }
    }
}

/// A test result in the phone's words.
/// [`Attempt::answer`] is [answer].
fn attempt(result: &PersonalConnectionTestResult, answer: u64, l10n: &L10n) -> Attempt {
    if result.ok {
        return Attempt {
            ok: true,
            answer,
            text: match result.operation_count {
                Some(n) => l10n.personal_connections_test_ok(n),
                None => l10n.personal_connections_test_ok_terminal(),
            },
        };
    }
    Attempt {
        ok: false,
        answer,
        text: match result.failure {
            Some(PersonalProbeFailure::InvalidTarget) => {
                l10n.personal_connections_test_invalid_target()
            }
            Some(PersonalProbeFailure::UnsupportedAuth) => {
                l10n.personal_connections_test_unsupported_auth()
            }
            Some(PersonalProbeFailure::Unauthorized) => {
                l10n.personal_connections_test_unauthorized()
            }
            Some(PersonalProbeFailure::InvalidSpec) => {
                l10n.personal_connections_test_invalid_spec()
            }
            _ => l10n.personal_connections_test_unreachable(),
        },
    }
}

impl SheetBody for ConnectionEditorSheet {
    /// A save, test or delete is out (from its start until it ends): Quit
    /// beeps instead of asking.
    fn busy(&self, _: &App) -> bool {
        self.in_flight()
    }

    /// A form changed: Quit asks first, as Cancel does.
    fn unsaved(&self, cx: &App) -> bool {
        self.is_dirty(cx)
    }

    fn footer(&mut self, _: &mut Window, cx: &mut Context<Self>) -> Option<AnyElement> {
        let l10n = cx.l10n().clone();
        let busy = self.in_flight();
        let read_only = self.read_only();
        let view = cx.entity().downgrade();
        let delete = self.entry.is_some().then(|| {
            let view = view.clone();
            Button::new("connection-delete", l10n.desktop_delete_ellipsis())
                .disabled(busy)
                .on_click(Rc::new(move |_, window, cx| {
                    let _ = view.update(cx, |v, cx| v.delete(window, cx));
                }))
        });
        let test = (!read_only).then(|| {
            let view = view.clone();
            Button::new(
                "connection-test",
                if self.testing {
                    l10n.desktop_testing()
                } else {
                    l10n.personal_connections_test_connection()
                },
            )
            .disabled(busy)
            .on_click(Rc::new(move |_, _, cx| {
                let _ = view.update(cx, |v, cx| v.test(cx));
            }))
        });
        let cancel = {
            let view = view.clone();
            Button::new("connection-cancel", l10n.cancel())
                .disabled(self.saving || self.deleting)
                .on_click(Rc::new(move |_, window, cx| {
                    let _ = view.update(cx, |v, cx| v.cancel(window, cx));
                }))
        };
        let save = (!read_only).then(|| {
            Button::new(
                "connection-save",
                if self.saving {
                    l10n.desktop_saving()
                } else {
                    l10n.save()
                },
            )
            .primary()
            .disabled(busy)
            .on_click(Rc::new(move |_, _, cx| {
                let _ = view.update(cx, |v, cx| v.save(cx));
            }))
        });
        Some(
            div()
                .w_full()
                .flex()
                .items_center()
                .gap(px(8.))
                .children(delete)
                .child(div().flex_1())
                .children(test)
                .child(cancel)
                .children(save)
                .into_any_element(),
        )
    }

    fn cancel(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.saving || self.deleting {
            return;
        }
        if !self.is_dirty(cx) {
            sheet::dismiss(cx);
            return;
        }
        let l10n = cx.l10n().clone();
        let spec = SheetSpec::new(
            l10n.desktop_discard_changes_title(),
            l10n.desktop_discard_changes_message(),
            l10n.desktop_discard(),
            l10n.cancel(),
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

    fn label(&self, cx: &App) -> SharedString {
        self.title(&cx.l10n().clone()).into()
    }
}

impl Render for ConnectionEditorSheet {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let l10n = cx.l10n().clone();
        let t = cx.conduit().clone();
        let mut body = if self.read_only() {
            self.read_only_form(&l10n, cx)
        } else {
            self.form(&l10n, window, cx)
        };
        if self.read_only() {
            body.push(self.enabled_group(&l10n, cx));
        }
        if let Some(error) = &self.error {
            body.push(
                forms::form_error_answered("connection-error", error.clone(), self.answers, cx)
                    .into_any_element(),
            );
        } else if let Some(attempt) = &self.attempt {
            body.push(if attempt.ok {
                forms::form_note_answered(attempt.text.clone(), true, attempt.answer, cx)
                    .into_any_element()
            } else {
                forms::form_error_answered(
                    "connection-test-failed",
                    attempt.text.clone(),
                    attempt.answer,
                    cx,
                )
                .into_any_element()
            });
        }
        div()
            .id("connection-editor")
            .w_full()
            .flex()
            .flex_col()
            .gap(px(16.))
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
                            .child(self.title(&l10n)),
                    )
                    .child(
                        div()
                            .text_size(px(t.metrics.small + 0.5))
                            .line_height(relative(1.4))
                            .text_color(t.roles.text_subtle)
                            .child(l10n.personal_connections_key_storage_note()),
                    ),
            )
            .children(body)
    }
}

/// The spec type the form shows for `e`: `json` or `url`.
fn spec_type_of(e: &PersonalConnectionDto) -> &'static str {
    if e.spec_type == "json" { "json" } else { "url" }
}

/// The auth type the form shows for `e`: `none` or `bearer`.
fn auth_type_of(e: &PersonalConnectionDto) -> &'static str {
    if e.auth_type == "none" {
        "none"
    } else {
        "bearer"
    }
}

/// Whether a kept key goes when `saved` is saved with the URL, document
/// source (`spec_type`) and document `path` the form now has: as the core's
/// `mergePersonalConnectionEdit` decides, when the URL, or where the OpenAPI
/// document is fetched from, moves to another origin ([`key_moves`]).
pub fn key_goes(saved: &PersonalConnectionDto, url: &str, spec_type: &str, path: &str) -> bool {
    key_moves(&saved.url, url)
        || key_moves(
            document_location(&saved.url, &saved.spec_type, &saved.path),
            document_location(url, spec_type, path),
        )
}

/// Where a connection's key goes for its OpenAPI document, as the core's
/// `_documentLocation` says: for a document it fetches (any source but
/// `json`), an absolute `path` itself, else the connection's URL (a relative
/// path stays on its origin). An inline document is fetched from nowhere.
fn document_location<'a>(url: &'a str, spec_type: &str, path: &'a str) -> &'a str {
    let path = path.trim();
    if spec_type.trim() != "json" && path.contains("://") {
        path
    } else {
        url
    }
}

/// Whether a saved key would reach another origin: `url` names another
/// scheme, host or port than `saved` (an unreadable URL counts as another
/// one unless it is the saved text itself).
pub fn key_moves(saved: &str, url: &str) -> bool {
    let (saved, url) = (saved.trim(), url.trim());
    if saved == url {
        return false;
    }
    match (url::Url::parse(saved), url::Url::parse(url)) {
        (Ok(a), Ok(b)) => a.origin() != b.origin(),
        _ => true,
    }
}

#[cfg(test)]
mod tests {
    use std::cell::Cell;
    use std::rc::Rc;

    use conduit_protocol::{PersonalConnectionDto, PersonalConnections, PersonalKind, methods};
    use gpui_kit::{App, Entity, VisualTestContext};
    use serde_json::json;

    use super::ConnectionEditorSheet;
    use crate::stores::Stores;
    use crate::views::sheet::{self, bench::bench};

    fn entry(has_key: bool, editable: bool) -> PersonalConnectionDto {
        serde_json::from_value(json!({
            "kind": "toolServer",
            "identity": "conduit-1",
            "name": "Seed catalogue",
            "endpoint": "https://tools.example.com",
            "enabled": true,
            "editable": editable,
            "url": "https://tools.example.com",
            "specType": "url",
            "path": "openapi.json",
            "authType": "bearer",
            "hasKey": has_key,
        }))
        .unwrap()
    }

    fn listed(entry: PersonalConnectionDto) -> PersonalConnections {
        PersonalConnections {
            owner: "p1".into(),
            tool_servers: vec![entry],
            ..Default::default()
        }
    }

    fn open(
        stores: &Stores,
        entry: Option<PersonalConnectionDto>,
        vcx: &mut VisualTestContext,
    ) -> Entity<ConnectionEditorSheet> {
        open_with(stores, entry, Rc::new(|_, _: &mut App| {}), vcx)
    }

    fn open_with(
        stores: &Stores,
        entry: Option<PersonalConnectionDto>,
        on_change: super::OnChange,
        vcx: &mut VisualTestContext,
    ) -> Entity<ConnectionEditorSheet> {
        let stores = stores.clone();
        let sheet = vcx
            .update(|window, cx| {
                ConnectionEditorSheet::open(
                    stores,
                    "p1".into(),
                    PersonalKind::ToolServer,
                    entry,
                    on_change,
                    window,
                    cx,
                )
            })
            .expect("the editor opens");
        vcx.run_until_parked();
        sheet
    }

    fn type_into(
        sheet: &Entity<ConnectionEditorSheet>,
        field: fn(&ConnectionEditorSheet) -> Entity<gpui_kit::component::input::InputState>,
        text: &str,
        vcx: &mut VisualTestContext,
    ) {
        let state = sheet.read_with(vcx, |s, _| field(s));
        let text = text.to_string();
        vcx.update(|window, cx| state.update(cx, |s, cx| s.set_value(text, window, cx)));
        vcx.run_until_parked();
    }

    fn draw_sheet(vcx: &mut VisualTestContext) {
        vcx.update(|_, cx| {
            if let Some(handle) = sheet::current_window(cx) {
                let _ = handle.update(cx, |_, window, cx| window.draw(cx).clear(cx));
            }
        });
        vcx.run_until_parked();
    }

    /// A key typed into a connection that has none yet is its first key:
    /// Save and Test send it to replace (nothing), not to keep.
    #[gpui_kit::test]
    fn a_first_key_typed_on_a_keyless_connection_is_sent(cx: &mut gpui_kit::TestAppContext) {
        let (daemon, stores, vcx) = bench(cx);
        daemon.returns::<methods::IntegrationsSave>(listed(entry(true, true)));
        daemon.returns::<methods::IntegrationsTest>(Default::default());
        let sheet = open(&stores, Some(entry(false, true)), vcx);
        type_into(&sheet, |s| s.key.clone(), "seed-token", vcx);
        sheet.update(vcx, |s, cx| s.press_test(cx));
        vcx.run_until_parked();
        sheet.update(vcx, |s, cx| s.save(cx));
        vcx.run_until_parked();
        let tests = daemon.calls::<methods::IntegrationsTest>();
        assert_eq!(tests[0]["draft"]["keyMode"], "replace");
        assert_eq!(tests[0]["draft"]["key"], "seed-token");
        let saves = daemon.calls::<methods::IntegrationsSave>();
        assert_eq!(saves[0]["draft"]["keyMode"], "replace");
        assert_eq!(saves[0]["draft"]["key"], "seed-token");
    }

    /// The editor never removes a saved key on its own: on another origin
    /// than the one it opened with, Save and Test still send Keep (the form
    /// says the key goes), and the daemon removes a kept key against the
    /// entry as stored when it saves. So a path edit after another client
    /// moved the server, and saved its key, keeps that key. A key typed for
    /// the new origin is the one sent.
    #[gpui_kit::test]
    fn the_editor_sends_keep_and_the_save_decides_an_origin_change(
        cx: &mut gpui_kit::TestAppContext,
    ) {
        let (daemon, stores, vcx) = bench(cx);
        daemon.returns::<methods::IntegrationsSave>(listed(entry(true, true)));
        daemon.returns::<methods::IntegrationsTest>(Default::default());
        let sheet = open(&stores, Some(entry(true, true)), vcx);
        // The URL kept, the document fetched from another origin: the key
        // goes too, as the save decides. Fetched from the same origin, or
        // pasted inline (fetched from nowhere), it stays.
        for (spec_type, path, mode) in [
            (
                "url",
                "https://elsewhere.example.org/openapi.json",
                super::PersonalKeyMode::Clear,
            ),
            (
                "url",
                "https://tools.example.com/v2/openapi.json",
                super::PersonalKeyMode::Keep,
            ),
            (
                "json",
                "https://elsewhere.example.org/openapi.json",
                super::PersonalKeyMode::Keep,
            ),
        ] {
            sheet.update(vcx, |s, cx| {
                s.spec_type = spec_type.into();
                cx.notify();
            });
            type_into(&sheet, |s| s.path.clone(), path, vcx);
            sheet.read_with(vcx, |s, cx| {
                assert_eq!(s.key_mode_now(cx), mode, "{spec_type} {path}");
            });
        }
        sheet.update(vcx, |s, cx| {
            s.spec_type = "url".into();
            cx.notify();
        });
        type_into(&sheet, |s| s.path.clone(), "openapi.json", vcx);
        for url in [
            "https://tools.example.com/v2",
            "https://elsewhere.example.org/v2",
            "http://tools.example.com",
            "https://tools.example.com:8443",
        ] {
            type_into(&sheet, |s| s.url.clone(), url, vcx);
            sheet.update(vcx, |s, cx| s.press_test(cx));
            vcx.run_until_parked();
        }
        // The form says a key on another origin goes.
        sheet.read_with(vcx, |s, cx| {
            assert_eq!(s.key_mode_now(cx), super::PersonalKeyMode::Clear);
        });
        sheet.update(vcx, |s, cx| s.save(cx));
        vcx.run_until_parked();
        let tests = daemon.calls::<methods::IntegrationsTest>();
        assert_eq!(tests.len(), 4);
        for test in &tests {
            assert_eq!(test["draft"]["keyMode"], "keep", "{}", test["draft"]["url"]);
        }
        let saves = daemon.calls::<methods::IntegrationsSave>();
        assert_eq!(saves[0]["draft"]["keyMode"], "keep");
        // A key typed for the new origin is the one sent.
        let sheet = open(&stores, Some(entry(true, true)), vcx);
        type_into(
            &sheet,
            |s| s.url.clone(),
            "https://elsewhere.example.org",
            vcx,
        );
        type_into(&sheet, |s| s.key.clone(), "seed-token", vcx);
        sheet.update(vcx, |s, cx| s.press_test(cx));
        vcx.run_until_parked();
        let tests = daemon.calls::<methods::IntegrationsTest>();
        assert_eq!(tests[4]["draft"]["keyMode"], "replace");
        assert_eq!(tests[4]["draft"]["key"], "seed-token");
    }

    /// Nothing can be typed while a save is out, so the sheet never closes
    /// over words typed after the save went.
    #[gpui_kit::test]
    fn nothing_typed_while_a_connection_saves_is_dropped(cx: &mut gpui_kit::TestAppContext) {
        let app = cx.clone();
        let (daemon, stores, vcx) = bench(cx);
        daemon.returns::<methods::IntegrationsSave>(listed(entry(false, true)));
        let sheet = open(&stores, Some(entry(false, true)), vcx);
        type_into(&sheet, |s| s.name.clone(), "Seed swap", vcx);
        let held = daemon.hold_one::<methods::IntegrationsSave>(0);
        sheet.update(vcx, |s, cx| s.save(cx));
        vcx.run_until_parked();
        draw_sheet(vcx);
        let window = vcx
            .update(|_, cx| sheet::current_window(cx))
            .expect("the sheet's window");
        let mut sheet_cx = VisualTestContext::from_window(window, &app);
        // The name field has the caret; this is typed while the save is out.
        sheet_cx.simulate_input(" club");
        vcx.run_until_parked();
        let typed = sheet.read_with(vcx, |s, cx| super::forms::raw(&s.name, cx));
        drop(held);
        vcx.run_until_parked();
        let saves = daemon.calls::<methods::IntegrationsSave>();
        assert_eq!(saves.len(), 1);
        assert_eq!(
            saves[0]["draft"]["name"], typed,
            "the sheet closed over words typed while it saved"
        );
    }

    /// A Save refused twice in the same words, with no edit between, is
    /// heard twice, whichever field it names (the JSON document, the URL);
    /// a redraw says nothing more.
    #[gpui_kit::test]
    fn each_refusal_is_heard(cx: &mut gpui_kit::TestAppContext) {
        use conduit_components::announce::AnnouncementLog;
        let l = crate::l10n::L10n::new("en");
        for (field, issue, refused) in [
            ("spec", "specInvalid", l.personal_connections_spec_invalid()),
            ("url", "urlInvalid", l.personal_connections_url_invalid()),
        ] {
            let (daemon, stores, vcx) = bench(cx);
            vcx.update(|_, cx| AnnouncementLog::install(cx));
            daemon.on::<methods::IntegrationsSave>(move |_| {
                let mut e = conduit_daemon::RpcError::internal("the form has a problem");
                e.args.insert(field.into(), issue.into());
                Err(e)
            });
            let sheet = open(&stores, None, vcx);
            if field == "spec" {
                sheet.update(vcx, |s, cx| {
                    s.spec_type = "json".into();
                    cx.notify();
                });
            }
            let heard = |vcx: &mut VisualTestContext| {
                vcx.update(|_, cx| AnnouncementLog::texts(cx))
                    .iter()
                    .filter(|t| t.as_ref() == refused)
                    .count()
            };
            for _ in 0..2 {
                sheet.update(vcx, |s, cx| s.save(cx));
                vcx.run_until_parked();
                draw_sheet(vcx);
            }
            draw_sheet(vcx);
            assert_eq!(heard(vcx), 2, "the second {field} refusal was not heard");
            vcx.update(|_, cx| sheet::dismiss(cx));
        }
    }

    /// Each piece of feedback keeps the answer it came from: a Save refused
    /// for a field after a Test that passed says the refusal, not the Test's
    /// result again, and a Save that fails after a Test refused a field does
    /// not say that field again.
    #[gpui_kit::test]
    fn a_save_never_says_an_earlier_test_again(cx: &mut gpui_kit::TestAppContext) {
        use conduit_components::announce::AnnouncementLog;
        use conduit_protocol::PersonalConnectionTestResult;
        let l = crate::l10n::L10n::new("en");
        let refused = || {
            let mut e = conduit_daemon::RpcError::internal("the form has a problem");
            e.args.insert("url".into(), "urlInvalid".into());
            e
        };
        let failed = conduit_daemon::RpcError::internal("the server did not answer");
        let passed = l.personal_connections_test_ok(3);
        let url_refused = l.personal_connections_url_invalid();
        let save_failed = super::save_error(&failed, &l);
        for test_refuses in [false, true] {
            let (daemon, stores, vcx) = bench(cx);
            vcx.update(|_, cx| AnnouncementLog::install(cx));
            // The log is the app's: this case's announcements are the ones after.
            let before = vcx.update(|_, cx| AnnouncementLog::texts(cx)).len();
            if test_refuses {
                daemon.on::<methods::IntegrationsTest>(move |_| Err(refused()));
                let failed = failed.clone();
                daemon.on::<methods::IntegrationsSave>(move |_| Err(failed.clone()));
            } else {
                daemon.returns::<methods::IntegrationsTest>(PersonalConnectionTestResult {
                    ok: true,
                    operation_count: Some(3),
                    failure: None,
                });
                daemon.on::<methods::IntegrationsSave>(move |_| Err(refused()));
            }
            let sheet = open(&stores, None, vcx);
            sheet.update(vcx, |s, cx| s.press_test(cx));
            vcx.run_until_parked();
            draw_sheet(vcx);
            sheet.update(vcx, |s, cx| s.save(cx));
            vcx.run_until_parked();
            draw_sheet(vcx);
            let texts = vcx.update(|_, cx| AnnouncementLog::texts(cx));
            let heard = |text: &str| {
                texts[before..]
                    .iter()
                    .filter(|t| t.as_ref() == text)
                    .count()
            };
            if test_refuses {
                assert_eq!(heard(&url_refused), 1, "the Test's refusal was said again");
                assert_eq!(heard(&save_failed), 1, "the Save's failure was not heard");
            } else {
                assert_eq!(heard(&passed), 1, "the Test's result was said again");
                assert_eq!(heard(&url_refused), 1, "the Save's refusal was not heard");
            }
            vcx.update(|_, cx| sheet::dismiss(cx));
        }
    }

    /// An issue the core found goes once its field changes.
    #[gpui_kit::test]
    fn a_corrected_field_drops_its_old_issue(cx: &mut gpui_kit::TestAppContext) {
        let (daemon, stores, vcx) = bench(cx);
        daemon.on::<methods::IntegrationsSave>(|_| {
            let mut e = conduit_daemon::RpcError::internal("the form has a problem");
            e.args.insert("url".into(), "urlInvalid".into());
            Err(e)
        });
        let sheet = open(&stores, None, vcx);
        type_into(&sheet, |s| s.url.clone(), "tools", vcx);
        sheet.update(vcx, |s, cx| s.save(cx));
        vcx.run_until_parked();
        assert!(sheet.read_with(vcx, |s, _| s.issues.url.is_some()));
        type_into(&sheet, |s| s.url.clone(), "https://tools.example.com", vcx);
        assert_eq!(
            sheet.read_with(vcx, |s, _| s.issues.clone()),
            super::Issues::default()
        );
    }

    /// Edits not saved: Quit asks first (and keeps them on "keep editing").
    #[gpui_kit::test]
    fn quit_asks_before_dropping_an_edited_connection(cx: &mut gpui_kit::TestAppContext) {
        let (_daemon, stores, vcx) = bench(cx);
        let sheet = open(&stores, Some(entry(false, true)), vcx);
        type_into(&sheet, |s| s.name.clone(), "Seed swap", vcx);
        let quits = Rc::new(Cell::new(0));
        let q = quits.clone();
        vcx.update(|_, cx| sheet::quit_with(cx, Rc::new(move |_| q.set(q.get() + 1))));
        vcx.run_until_parked();
        assert_eq!(quits.get(), 0, "Quit dropped the edited connection");
        assert!(
            vcx.update(|_, cx| sheet::current::<ConnectionEditorSheet>(cx))
                .is_some()
        );
    }

    /// A connection the editor can't read has no Save: its switch saves at
    /// once, and goes back when that is refused.
    #[gpui_kit::test]
    fn an_unsupported_connections_switch_saves_at_once(cx: &mut gpui_kit::TestAppContext) {
        let (daemon, stores, vcx) = bench(cx);
        let mut off = entry(false, false);
        off.enabled = false;
        daemon.returns::<methods::IntegrationsSave>(listed(off));
        let sheet = open(&stores, Some(entry(false, false)), vcx);
        sheet.update(vcx, |s, cx| s.press_switch(cx));
        vcx.run_until_parked();
        let saves = daemon.calls::<methods::IntegrationsSave>();
        assert_eq!(saves.len(), 1);
        assert_eq!(saves[0]["op"], "setEnabled");
        assert_eq!(saves[0]["enabled"], false);
        assert!(!sheet.read_with(vcx, |s, _| s.enabled));

        daemon.on::<methods::IntegrationsSave>(|_| {
            Err(conduit_daemon::RpcError::internal("refused"))
        });
        sheet.update(vcx, |s, cx| s.press_switch(cx));
        vcx.run_until_parked();
        sheet.read_with(vcx, |s, _| {
            assert!(!s.enabled, "the switch stayed on although nothing saved");
            assert!(s.error.is_some());
        });
    }

    fn quit_counted(vcx: &mut VisualTestContext) -> Rc<Cell<u32>> {
        let quits = Rc::new(Cell::new(0));
        let counted = quits.clone();
        vcx.update(|_, cx| sheet::quit_with(cx, Rc::new(move |_| counted.set(counted.get() + 1))));
        vcx.run_until_parked();
        quits
    }

    fn settle(vcx: &mut VisualTestContext) {
        for _ in 0..2 {
            vcx.run_until_parked();
            vcx.executor()
                .advance_clock(std::time::Duration::from_secs(5));
        }
        vcx.run_until_parked();
    }

    fn beeps(vcx: &mut VisualTestContext) -> u32 {
        vcx.update(|_, cx| cx.global::<crate::shell::sheet::Beeps>().0)
    }

    fn editor_up(vcx: &mut VisualTestContext) -> bool {
        vcx.update(|_, cx| sheet::current::<ConnectionEditorSheet>(cx))
            .is_some()
    }

    /// The entry's fingerprint goes back with Test and Save. A Save the
    /// daemon refuses because the entry changed since the editor opened it
    /// (another window saved it) says so with the "changed or removed
    /// elsewhere" words and fills the form again from the entry as it is
    /// now, the typed change gone; the next Save sends the new fingerprint.
    #[gpui_kit::test]
    fn a_stale_save_is_refused_and_the_editor_reloads(cx: &mut gpui_kit::TestAppContext) {
        use crate::l10n::ActiveL10n as _;
        use crate::views::sheet::SheetBody as _;
        let (daemon, stores, vcx) = bench(cx);
        let mut changed = conduit_daemon::RpcError::new(conduit_protocol::ErrorCode::Conflict);
        changed.args.insert("reason".into(), "changed".into());
        daemon.once::<methods::IntegrationsSave>(Err(changed));
        daemon.returns::<methods::IntegrationsTest>(Default::default());
        let mut now = entry(true, true);
        now.name = "Seed renamed".into();
        now.fingerprint = "fp-2".into();
        daemon.returns::<methods::IntegrationsList>(listed(now.clone()));
        let mut opened = entry(true, true);
        opened.fingerprint = "fp-1".into();
        let sheet = open(&stores, Some(opened), vcx);
        sheet.update(vcx, |s, cx| s.press_test(cx));
        vcx.run_until_parked();
        type_into(&sheet, |s| s.description.clone(), "Typed here", vcx);
        type_into(&sheet, |s| s.key.clone(), "typed-secret", vcx);
        sheet.update(vcx, |s, cx| s.save(cx));
        settle(vcx);
        assert_eq!(
            daemon.calls::<methods::IntegrationsTest>()[0]["fingerprint"],
            "fp-1"
        );
        assert_eq!(
            daemon.calls::<methods::IntegrationsSave>()[0]["fingerprint"],
            "fp-1"
        );
        sheet.read_with(vcx, |s, cx| {
            assert_eq!(
                s.error.as_deref(),
                Some(cx.l10n().personal_connections_not_found().as_str())
            );
            assert_eq!(
                s.entry.as_ref().map(|e| e.fingerprint.as_str()),
                Some("fp-2")
            );
            assert_eq!(super::forms::raw(&s.name, cx), "Seed renamed");
            assert_eq!(super::forms::raw(&s.description, cx), now.description);
            // The typed key goes too, and the saved one is kept: nothing
            // shown is left out of the next save.
            assert_eq!(super::forms::raw(&s.key, cx), "");
            assert_eq!(s.key_mode, conduit_protocol::PersonalKeyMode::Keep);
            assert!(!s.unsaved(cx), "the reloaded form counts as edited");
        });
        daemon.returns::<methods::IntegrationsSave>(listed(now));
        type_into(&sheet, |s| s.name.clone(), "Seed again", vcx);
        sheet.update(vcx, |s, cx| s.save(cx));
        settle(vcx);
        assert_eq!(
            daemon.calls::<methods::IntegrationsSave>()[1]["fingerprint"],
            "fp-2"
        );
    }

    /// A Save refused as `changed`.
    fn changed() -> conduit_daemon::RpcError {
        let mut e = conduit_daemon::RpcError::new(conduit_protocol::ErrorCode::Conflict);
        e.args.insert("reason".into(), "changed".into());
        e
    }

    /// Nothing can be typed while a conflict reload reads the list, so its
    /// refill never erases words typed meanwhile; the form unlocks once the
    /// read settles.
    #[gpui_kit::test]
    fn nothing_is_typed_while_a_conflict_reload_reads_the_list(cx: &mut gpui_kit::TestAppContext) {
        let app = cx.clone();
        let (daemon, stores, vcx) = bench(cx);
        daemon.once::<methods::IntegrationsSave>(Err(changed()));
        let mut now = entry(true, true);
        now.name = "Seed renamed".into();
        now.fingerprint = "fp-2".into();
        daemon.returns::<methods::IntegrationsList>(listed(now));
        let held = daemon.hold_one::<methods::IntegrationsList>(0);
        let sheet = open(&stores, Some(entry(true, true)), vcx);
        sheet.update(vcx, |s, cx| s.save(cx));
        vcx.run_until_parked();
        assert!(
            sheet.read_with(vcx, |s, _| s.in_flight()),
            "the reload left the form open"
        );
        draw_sheet(vcx);
        let window = vcx
            .update(|_, cx| sheet::current_window(cx))
            .expect("the sheet's window");
        let mut sheet_cx = VisualTestContext::from_window(window, &app);
        // The name field has the caret; this is typed while the list is read.
        sheet_cx.simulate_input(" club");
        vcx.run_until_parked();
        let typed = sheet.read_with(vcx, |s, cx| super::forms::raw(&s.name, cx));
        assert_eq!(
            typed, "Seed catalogue",
            "a word went in while the reload was out"
        );
        drop(held);
        vcx.run_until_parked();
        sheet.read_with(vcx, |s, cx| {
            assert!(!s.in_flight());
            assert_eq!(super::forms::raw(&s.name, cx), "Seed renamed");
        });
    }

    /// A reload whose list could not be read keeps the pane's last list and
    /// the form as it is, its fingerprint too (the next Save is refused and
    /// reloads again), and unlocks it.
    #[gpui_kit::test]
    fn a_failed_conflict_reload_leaves_the_list_and_the_form(cx: &mut gpui_kit::TestAppContext) {
        let (daemon, stores, vcx) = bench(cx);
        daemon.once::<methods::IntegrationsSave>(Err(changed()));
        daemon.returns::<methods::IntegrationsList>(PersonalConnections {
            owner: "p1".into(),
            failed: true,
            ..Default::default()
        });
        let lists = Rc::new(Cell::new(0));
        let counted = lists.clone();
        let mut opened = entry(true, true);
        opened.fingerprint = "fp-1".into();
        let sheet = open_with(
            &stores,
            Some(opened),
            Rc::new(move |_, _: &mut App| counted.set(counted.get() + 1)),
            vcx,
        );
        type_into(&sheet, |s| s.description.clone(), "Typed here", vcx);
        sheet.update(vcx, |s, cx| s.save(cx));
        settle(vcx);
        assert_eq!(lists.get(), 0, "a failed list replaced the pane's");
        sheet.read_with(vcx, |s, cx| {
            assert!(!s.in_flight());
            assert_eq!(
                s.entry.as_ref().map(|e| e.fingerprint.as_str()),
                Some("fp-1")
            );
            assert_eq!(super::forms::raw(&s.description, cx), "Typed here");
        });
    }

    /// Quit while a save is out queues nothing: a beep, no question (the
    /// bench would answer it No) and no quit, and the sheet stays.
    #[gpui_kit::test]
    fn quit_during_a_save_beeps_and_stays(cx: &mut gpui_kit::TestAppContext) {
        let (daemon, stores, vcx) = bench(cx);
        daemon.once::<methods::IntegrationsSave>(Err(conduit_daemon::RpcError::internal("down")));
        let sheet = open(&stores, Some(entry(false, true)), vcx);
        type_into(&sheet, |s| s.name.clone(), "Seed swap", vcx);
        let held = daemon.hold::<methods::IntegrationsSave>();
        sheet.update(vcx, |s, cx| s.save(cx));
        let quits = quit_counted(vcx);
        assert_eq!(beeps(vcx), 1, "Quit during the save did not beep");
        assert!(editor_up(vcx));
        drop(held);
        settle(vcx);
        assert!(editor_up(vcx), "the failed save's sheet closed");
        assert_eq!(quits.get(), 0, "a Quit waited on the save");
    }

    /// After a save fails the sheet is idle and dirty: Quit asks, and
    /// Discard quits.
    #[gpui_kit::test]
    fn after_a_failed_save_quit_asks_and_discard_quits(cx: &mut gpui_kit::TestAppContext) {
        let (daemon, stores, vcx) = bench(cx);
        daemon.once::<methods::IntegrationsSave>(Err(conduit_daemon::RpcError::internal("down")));
        let sheet = open(&stores, Some(entry(false, true)), vcx);
        type_into(&sheet, |s| s.name.clone(), "Seed swap", vcx);
        sheet.update(vcx, |s, cx| s.save(cx));
        settle(vcx);
        assert!(sheet.read_with(vcx, |s, _| s.error.is_some()));
        vcx.update(|_, cx| cx.set_global(crate::shell::sheet::AutoAnswer(Some(true))));
        let quits = quit_counted(vcx);
        settle(vcx);
        assert!(!editor_up(vcx), "Discard left the sheet open");
        assert_eq!(quits.get(), 1, "Discard after the failed save did not quit");
        assert_eq!(beeps(vcx), 0);
    }

    /// Text moved from one field to the next is a change: Cancel and Quit
    /// still ask before dropping it.
    #[gpui_kit::test]
    fn text_moved_between_fields_is_still_a_change(cx: &mut gpui_kit::TestAppContext) {
        let (_daemon, stores, vcx) = bench(cx);
        let mut start = entry(false, true);
        start.name = "Seed|catalogue".into();
        start.description = "local".into();
        let sheet = open(&stores, Some(start), vcx);
        type_into(&sheet, |s| s.name.clone(), "Seed", vcx);
        type_into(&sheet, |s| s.description.clone(), "catalogue|local", vcx);
        assert!(
            sheet.read_with(vcx, |s, cx| s.is_dirty(cx)),
            "the edit read as the form it opened with"
        );
    }

    /// Feedback a request gave while the fields were locked stays when they
    /// unlock with nothing typed (unlocking notifies each input without
    /// changing it); a real edit still clears it.
    #[gpui_kit::test]
    fn feedback_given_while_locked_stays_after_unlock(cx: &mut gpui_kit::TestAppContext) {
        let (daemon, stores, vcx) = bench(cx);
        daemon.on::<methods::IntegrationsSave>(|_| {
            let mut e = conduit_daemon::RpcError::internal("the form has a problem");
            e.args.insert("url".into(), "urlInvalid".into());
            Err(e)
        });
        daemon.returns::<methods::IntegrationsTest>(Default::default());
        let sheet = open(&stores, Some(entry(true, true)), vcx);
        type_into(&sheet, |s| s.url.clone(), "tools", vcx);
        // Each input notifies with its value unchanged, as unlocking does.
        let unlock = |vcx: &mut VisualTestContext| {
            let inputs = sheet.read_with(vcx, |s, _| {
                [
                    s.name.clone(),
                    s.description.clone(),
                    s.url.clone(),
                    s.path.clone(),
                    s.key.clone(),
                ]
            });
            let spec = sheet.read_with(vcx, |s, _| s.spec.clone());
            vcx.update(|_, cx| {
                for input in &inputs {
                    input.update(cx, |_, cx| cx.notify());
                }
                spec.update(cx, |_, cx| cx.notify());
            });
            vcx.run_until_parked();
        };
        sheet.update(vcx, |s, cx| s.save(cx));
        vcx.run_until_parked();
        unlock(vcx);
        assert!(
            sheet.read_with(vcx, |s, _| s.issues.url.is_some()),
            "the save's issue went when the fields unlocked"
        );
        sheet.update(vcx, |s, cx| s.press_test(cx));
        vcx.run_until_parked();
        unlock(vcx);
        assert!(
            sheet.read_with(vcx, |s, _| s.attempt.is_some()),
            "the test's result went when the fields unlocked"
        );
        type_into(&sheet, |s| s.url.clone(), "https://tools.example.com", vcx);
        sheet.read_with(vcx, |s, _| {
            assert!(s.attempt.is_none() && s.issues == super::Issues::default())
        });
    }
}
