//! Add Tool Server, Edit Tool Server, Add Terminal and Edit Terminal: one
//! personal connection in a sheet on the Settings window, as the phone's
//! editor has it.
//!
//! A tool server has a name and description, its URL, where its OpenAPI
//! document comes from (fetched from a path, or pasted as JSON) and how it
//! authenticates (a bearer key, or none). A terminal has a name, URL, path
//! and key. The stored key never comes back: an edit keeps it unless a new
//! one is typed or Remove Saved Key is chosen. Test Connection reads the
//! document (or checks the terminal) with the form as it stands, without
//! saving. A connection the editor cannot read (another auth mode) shows
//! what it can and can still be switched or deleted. The drafts, checks and
//! patches are core's (`integrations.*`).

use std::rc::Rc;

use conduit_components::ActiveConduitTheme as _;
use conduit_components::views::kit::{Button, Segment, Segmented, Switch, setting_row};
use conduit_components::views::settings::settings_section;
use conduit_daemon::RpcError;
use conduit_protocol::{
    PersonalConnectionDraft, PersonalConnectionDto, PersonalConnectionSave, PersonalConnectionTest,
    PersonalConnectionTestResult, PersonalConnections, PersonalEditOp, PersonalKeyMode,
    PersonalKind, PersonalProbeFailure, methods,
};
use gpui_kit::component::input::{InputState, Textarea, TextareaState};
use gpui_kit::prelude::*;
use gpui_kit::{
    AnyElement, App, AsyncApp, Context, Entity, FontWeight, Role, SharedString, WeakEntity, Window,
    div, px, relative,
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
    pub testing: bool,
    pub deleting: bool,
    pub issues: Issues,
    pub attempt: Option<Attempt>,
    pub error: Option<String>,
    /// The form as it opened, to tell whether it was changed.
    initial: String,
    on_change: OnChange,
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
                spec_type = if e.spec_type == "json" { "json" } else { "url" };
                auth_type = if e.auth_type == "none" {
                    "none"
                } else {
                    "bearer"
                };
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
            cx.observe(state, |this: &mut Self, _, cx| this.changed(cx))
                .detach();
        }
        cx.observe(&key, |this: &mut Self, key, cx| {
            // Typing a key replaces the stored one; clearing it keeps it.
            if this.entry.as_ref().is_some_and(|e| e.has_key) {
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
        cx.observe(&spec, |this: &mut Self, _, cx| this.changed(cx))
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
            testing: false,
            deleting: false,
            issues: Issues::default(),
            attempt: None,
            error: None,
            initial: String::new(),
            on_change,
        };
        this.initial = this.fingerprint(cx);
        this
    }

    fn tool(&self) -> bool {
        self.kind == PersonalKind::ToolServer
    }

    fn read_only(&self) -> bool {
        self.entry.as_ref().is_some_and(|e| !e.editable)
    }

    pub fn busy(&self) -> bool {
        self.saving || self.testing || self.deleting
    }

    /// Test Connection, as its button presses it.
    pub fn press_test(&mut self, cx: &mut Context<Self>) {
        self.test(cx);
    }

    /// Delete…, as its button presses it.
    pub fn press_delete(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.delete(window, cx);
    }

    /// Any change makes an earlier test result out of date.
    fn changed(&mut self, cx: &mut Context<Self>) {
        self.attempt = None;
        cx.notify();
    }

    fn fingerprint(&self, cx: &App) -> String {
        format!(
            "{}|{}|{}|{}|{}|{}|{}|{}|{:?}|{}",
            forms::raw(&self.name, cx),
            forms::raw(&self.description, cx),
            forms::raw(&self.url, cx),
            forms::raw(&self.path, cx),
            self.spec.read(cx).value(),
            !forms::raw(&self.key, cx).is_empty(),
            self.spec_type,
            self.auth_type,
            self.key_mode,
            self.enabled,
        )
    }

    pub fn is_dirty(&self, cx: &App) -> bool {
        !self.read_only() && self.fingerprint(cx) != self.initial
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
        if self.busy() || self.read_only() {
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
            });
        self.saving = true;
        self.error = None;
        cx.notify();
        let on_change = self.on_change.clone();
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result = call.await;
            let _ = this.update(cx, |s, cx| {
                s.saving = false;
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
                            Some(issues) => s.issues = issues,
                            None => s.error = Some(save_error(&e, &l10n)),
                        }
                    }
                }
                cx.notify();
            });
        })
        .detach();
    }

    fn test(&mut self, cx: &mut Context<Self>) {
        if self.busy() || self.read_only() {
            return;
        }
        let call = self
            .rpc(cx)
            .call::<methods::IntegrationsTest>(&PersonalConnectionTest {
                owner: self.owner.clone(),
                kind: self.kind,
                identity: self.entry.as_ref().map(|e| e.identity.clone()),
                draft: self.draft(cx),
            });
        self.testing = true;
        self.attempt = None;
        self.error = None;
        cx.notify();
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result = call.await;
            let _ = this.update(cx, |s, cx| {
                s.testing = false;
                let l10n = cx.l10n().clone();
                match result {
                    Ok(result) => {
                        s.issues = Issues::default();
                        s.attempt = Some(attempt(&result, &l10n));
                    }
                    Err(e) => match Self::issues_from(&e, &l10n) {
                        Some(issues) => s.issues = issues,
                        None => {
                            s.attempt = Some(Attempt {
                                ok: false,
                                text: save_error(&e, &l10n),
                            })
                        }
                    },
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
        if self.busy() {
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
                    })
            }) else {
                return;
            };
            let result = call.await;
            let _ = this.update(cx, |s, cx| {
                s.deleting = false;
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
        let busy = self.busy();
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
        let help: Option<SharedString> = if removing {
            Some(l10n.personal_connections_key_will_remove().into())
        } else if stored && self.key_mode == PersonalKeyMode::Keep {
            Some(l10n.personal_connections_key_kept().into())
        } else {
            None
        };
        let field = forms::field(l10n.api_key(), &self.key, help, None, window, cx);
        if !stored {
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
        .disabled(self.busy())
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
        let mut identity =
            vec![forms::field(l10n.name(), &self.name, None, None, window, cx).into_any_element()];
        if tool {
            identity.push(
                forms::field(
                    l10n.personal_connections_description_field(),
                    &self.description,
                    None,
                    None,
                    window,
                    cx,
                )
                .into_any_element(),
            );
        }
        identity.push(
            forms::field(
                l10n.personal_connections_url(),
                &self.url,
                None,
                self.issues.url.clone().map(SharedString::from),
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
                forms::field(
                    l10n.personal_connections_path(),
                    &self.path,
                    None,
                    self.issues.path.clone().map(SharedString::from),
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
                    .child(Textarea::new(&self.spec))
                    .when_some(self.issues.spec.clone(), |d, e| {
                        d.child(
                            div()
                                .id("connection-spec-issue")
                                .role(Role::Alert)
                                .text_size(px(t.metrics.small))
                                .text_color(t.roles.danger)
                                .child(e),
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
            .disabled(self.busy())
            .on_click(Rc::new(move |_, _, cx| {
                let _ = view.update(cx, |v, cx| {
                    v.enabled = !on;
                    v.changed(cx);
                });
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
fn attempt(result: &PersonalConnectionTestResult, l10n: &L10n) -> Attempt {
    if result.ok {
        return Attempt {
            ok: true,
            text: match result.operation_count {
                Some(n) => l10n.personal_connections_test_ok(n),
                None => l10n.personal_connections_test_ok_terminal(),
            },
        };
    }
    Attempt {
        ok: false,
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
    fn footer(&mut self, _: &mut Window, cx: &mut Context<Self>) -> Option<AnyElement> {
        let l10n = cx.l10n().clone();
        let busy = self.busy();
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
            body.push(forms::form_error("connection-error", error.clone(), cx).into_any_element());
        } else if let Some(attempt) = &self.attempt {
            body.push(if attempt.ok {
                forms::form_note(attempt.text.clone(), true, cx).into_any_element()
            } else {
                forms::form_error("connection-test-failed", attempt.text.clone(), cx)
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
