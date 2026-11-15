//! Direct connections: model APIs with no Open WebUI server (an
//! OpenAI-compatible API or Ollama). The form tests (`direct.test`) and
//! saves (`direct.save`); in onboarding, saving also prefers Direct
//! (`direct.setPreferred`) so the window goes straight to chat once the
//! connection works. Settings lists the saved ones with an on/off switch
//! (`direct.setEnabled`), Edit, and Remove (`direct.remove`, after a sheet).

use std::rc::Rc;

use conduit_components::ActiveConduitTheme as _;
use conduit_components::assets::IconName;
use conduit_components::views::kit::{Button, Segment, Segmented, Switch, grouped, setting_row};
use conduit_daemon::RpcError;
use conduit_protocol::{
    DirectApiMode, DirectConnectionEdit, DirectConnectionList, DirectConnectionSummary,
    DirectEnable, DirectKind, DirectPreferred, DirectRef, DirectTestResult, NoParams, methods,
};
use gpui_kit::component::input::{InputEvent, InputState};
use gpui_kit::prelude::*;
use gpui_kit::{
    AnyElement, App, AsyncWindowContext, ClickEvent, Context, ElementId, Entity, EventEmitter,
    Role, SharedString, WeakEntity, Window, div, px,
};

use crate::l10n::ActiveL10n as _;
use crate::shell::sheet::{SheetSpec, present_sheet};
use crate::stores::Stores;
use crate::views::forms::{
    self, field, form_error, form_group, form_note, form_row, normalize_url,
};
use crate::views::words;

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

pub struct DirectView {
    stores: Stores,
    /// Onboarding: one connection, preferred on save.
    pub onboarding: bool,
    pub list: Option<DirectConnectionList>,
    /// The connection being edited (`None` = a new one).
    pub editing: Option<String>,
    /// The saved connection being edited: what the form does not show is
    /// sent back as it was.
    saved: Option<DirectConnectionSummary>,
    /// The form is open (always, in onboarding).
    pub form_open: bool,
    pub kind: DirectKind,
    pub name: Entity<InputState>,
    pub base_url: Entity<InputState>,
    pub api_key: Entity<InputState>,
    pub self_signed: bool,
    pub busy: bool,
    pub error: Option<String>,
    pub note: Option<DirectNote>,
    /// Under the list in Settings: what direct connections are.
    pub footer: Option<SharedString>,
}

impl EventEmitter<DirectEvent> for DirectView {}

impl DirectView {
    pub fn new(
        stores: Stores,
        onboarding: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Self {
        let l10n = cx.l10n().clone();
        let name = forms::input(l10n.desktop_my_provider(), false, window, cx);
        let base_url = forms::input("https://api.example.com/v1", false, window, cx);
        // A key is optional (a local server takes none; an edit keeps it).
        let api_key = forms::input(l10n.desktop_optional(), true, window, cx);
        // Return is Save's (while it is on); typing may turn it on.
        for input in [&name, &base_url, &api_key] {
            cx.subscribe_in(
                input,
                window,
                |this: &mut Self, _, e: &InputEvent, window, cx| match e {
                    InputEvent::PressEnter { .. } if this.can_save(cx) => this.save(window, cx),
                    // A Test's result was for the draft as it was.
                    InputEvent::Change => {
                        this.note = None;
                        cx.notify()
                    }
                    _ => {}
                },
            )
            .detach();
        }
        let mut this = Self {
            stores,
            onboarding,
            list: None,
            editing: None,
            saved: None,
            form_open: onboarding,
            kind: DirectKind::Openai,
            name,
            base_url,
            api_key,
            self_signed: false,
            busy: false,
            error: None,
            note: None,
            footer: None,
        };
        this.refresh(window, cx);
        this
    }

    pub fn refresh(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let call = self
            .stores
            .connection
            .read(cx)
            .rpc()
            .call::<methods::DirectList>(&NoParams);
        cx.spawn_in(
            window,
            async move |this: WeakEntity<Self>, cx: &mut AsyncWindowContext| {
                let result = call.await;
                let _ = this.update(cx, |s, cx| {
                    match result {
                        Ok(list) => s.list = Some(list),
                        Err(e) => log::warn!("direct.list: {e}"),
                    }
                    cx.notify();
                });
            },
        )
        .detach();
    }

    pub fn open_new(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.editing = None;
        self.saved = None;
        self.kind = DirectKind::Openai;
        self.self_signed = false;
        for i in [&self.name, &self.base_url, &self.api_key] {
            i.update(cx, |i, cx| i.set_value("", window, cx));
        }
        self.form_open = true;
        self.error = None;
        self.note = None;
        cx.notify();
    }

    pub fn open_edit(
        &mut self,
        c: &DirectConnectionSummary,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.editing = Some(c.id.clone());
        self.saved = Some(c.clone());
        self.kind = c.kind;
        self.self_signed = c.allow_self_signed_certificates;
        let (name, url) = (c.name.clone(), c.base_url.clone());
        self.name.update(cx, |i, cx| i.set_value(name, window, cx));
        self.base_url
            .update(cx, |i, cx| i.set_value(url, window, cx));
        // A saved key is never sent back; empty keeps it.
        self.api_key.update(cx, |i, cx| i.set_value("", window, cx));
        self.form_open = true;
        self.error = None;
        self.note = None;
        cx.notify();
    }

    /// Whether Save (and Test) can go: not busy, and an address typed.
    pub fn can_save(&self, cx: &App) -> bool {
        !self.busy && forms::filled(&[&self.base_url], cx)
    }

    /// The edit to send, or why not.
    pub fn edit(&mut self, cx: &mut Context<Self>) -> Option<DirectConnectionEdit> {
        let l10n = cx.l10n().clone();
        let name = forms::text(&self.name, cx);
        let name = if name.is_empty() {
            match self.kind {
                DirectKind::Ollama => l10n.ollama(),
                _ => l10n.desktop_my_provider(),
            }
        } else {
            name
        };
        let raw = forms::text(&self.base_url, cx);
        let Some(base_url) = normalize_url(&raw) else {
            self.error = Some(l10n.desktop_invalid_server_address());
            cx.notify();
            return None;
        };
        let key = forms::raw(&self.api_key, cx);
        // An edit keeps what this form does not show (the API mode and
        // version, the header, prefix, enabled state, model ids and tags);
        // a new connection starts from the defaults.
        let saved = self
            .saved
            .as_ref()
            .filter(|c| Some(&c.id) == self.editing.as_ref());
        Some(DirectConnectionEdit {
            id: self.editing.clone(),
            name,
            kind: self.kind,
            base_url,
            api_mode: saved.map_or(DirectApiMode::Chat, |c| c.api_mode),
            api_version: saved.and_then(|c| c.api_version.clone()),
            api_key_header: saved.is_some_and(|c| c.api_key_header),
            model_id_prefix: saved.and_then(|c| c.model_id_prefix.clone()),
            enabled: saved.is_none_or(|c| c.enabled),
            open_web_ui: saved.is_some_and(|c| c.open_web_ui),
            api_key: (!key.is_empty()).then_some(key),
            custom_headers: None,
            manual_model_ids: saved
                .map(|c| c.manual_model_ids.clone())
                .unwrap_or_default(),
            allow_self_signed_certificates: self.self_signed,
            tags: saved.map(|c| c.tags.clone()).unwrap_or_default(),
            certificate_pem: None,
            certificate_label: None,
            private_key_pem: None,
            private_key_label: None,
            private_key_password: None,
        })
    }

    /// After a failed Test or Save: the field to fix, its text selected.
    /// A refused key is the key's fault; anything else (no answer, a bad
    /// address) the address's.
    fn focus_invalid(&mut self, error: Option<&RpcError>, window: &mut Window, cx: &mut App) {
        let field = match error {
            Some(e) if words::is_unauthorized(e) => &self.api_key,
            _ => &self.base_url,
        };
        forms::focus_invalid(&field.clone(), window, cx);
    }

    pub fn test(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.busy {
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
                    s.busy = false;
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
        if self.busy {
            return;
        }
        self.error = None;
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
        let known = self.list.as_ref().map(ids);
        cx.spawn_in(
            window,
            async move |this: WeakEntity<Self>, cx: &mut AsyncWindowContext| {
                // What was saved before this one, to tell the new connection
                // in the answer: asked now if the list never loaded. With
                // no such list, nothing is taken for the new one.
                let before = match known {
                    Some(known) => Some(known),
                    None if edit.id.is_none() => rpc
                        .call::<methods::DirectList>(&NoParams)
                        .await
                        .ok()
                        .map(|l| ids(&l)),
                    None => None,
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
                        s.editing = Some(made.id.clone());
                        s.saved = Some(made.clone());
                    }
                    let result = match (saved, preferred) {
                        (Ok(list), Some(Err(e))) => {
                            s.list = Some(list);
                            Err(e)
                        }
                        (Ok(_), Some(Ok(list))) | (Ok(list), None) => Ok(list),
                        (Err(e), _) => Err(e),
                    };
                    match result {
                        Ok(list) => {
                            s.list = Some(list);
                            s.note = Some(DirectNote::Saved);
                            if !s.onboarding {
                                s.form_open = false;
                            }
                            cx.emit(DirectEvent::Saved);
                        }
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

    fn set_enabled(
        &mut self,
        id: String,
        enabled: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let call = self
            .stores
            .connection
            .read(cx)
            .rpc()
            .call::<methods::DirectSetEnabled>(&DirectEnable { id, enabled });
        let session = self.stores.session.clone();
        cx.spawn_in(
            window,
            async move |this: WeakEntity<Self>, cx: &mut AsyncWindowContext| {
                let result = call.await;
                session.update(cx, |s, cx| s.refresh(cx));
                let _ = this.update(cx, |s, cx| {
                    if let Ok(list) = result {
                        // An open form saves the switch as it is now.
                        if let Some(saved) = s.saved.as_mut()
                            && let Some(c) = list.connections.iter().find(|c| c.id == saved.id)
                        {
                            saved.enabled = c.enabled;
                        }
                        s.list = Some(list);
                    }
                    cx.notify();
                });
            },
        )
        .detach();
    }

    fn remove(&mut self, c: DirectConnectionSummary, window: &mut Window, cx: &mut Context<Self>) {
        let l10n = cx.l10n().clone();
        let spec = SheetSpec::new(
            l10n.direct_connection_delete_title(),
            l10n.direct_connection_delete_message(&c.name),
            l10n.delete(),
            l10n.cancel(),
        )
        .destructive();
        let ask = present_sheet(window, spec, cx);
        let rpc = self.stores.connection.read(cx).rpc();
        let session = self.stores.session.clone();
        cx.spawn_in(
            window,
            async move |this: WeakEntity<Self>, cx: &mut AsyncWindowContext| {
                if !ask.await {
                    return;
                }
                let result = rpc
                    .call::<methods::DirectRemove>(&DirectRef { id: c.id })
                    .await;
                session.update(cx, |s, cx| s.refresh(cx));
                let _ = this.update(cx, |s, cx| {
                    match result {
                        Ok(list) => s.list = Some(list),
                        Err(e) => s.error = Some(words::connect_error(&e, &l10n)),
                    }
                    cx.notify();
                });
            },
        )
        .detach();
    }

    /// The form's rows.
    pub fn form(&self, window: &mut Window, cx: &mut Context<Self>) -> AnyElement {
        let l10n = cx.l10n().clone();
        let this = cx.entity().downgrade();
        let kinds = [DirectKind::Openai, DirectKind::Ollama];
        let kind = Segmented::new(
            "direct-kind",
            l10n.desktop_provider_type(),
            vec![
                Segment::new(l10n.desktop_open_ai_compatible()),
                Segment::new(l10n.ollama()),
            ],
            kinds.iter().position(|k| *k == self.kind).unwrap_or(0),
        )
        .on_select({
            let this = this.clone();
            Rc::new(move |i, _, cx| {
                let _ = this.update(cx, |s, cx| {
                    s.kind = kinds[i];
                    cx.notify();
                });
            })
        });
        let act = |f: fn(&mut DirectView, &mut Window, &mut Context<DirectView>)| {
            let this = this.clone();
            Rc::new(move |_: &ClickEvent, window: &mut Window, cx: &mut App| {
                let _ = this.update(cx, |s, cx| f(s, window, cx));
            })
        };
        let toggle = {
            let this = this.clone();
            Rc::new(move |_: &ClickEvent, _: &mut Window, cx: &mut App| {
                let _ = this.update(cx, |s, cx| {
                    s.self_signed = !s.self_signed;
                    cx.notify();
                });
            })
        };
        let note = self.note.as_ref().map(|n| match n {
            DirectNote::Tested(r) if r.reachable => (
                l10n.desktop_direct_test_ok(r.model_count.unwrap_or(0)),
                true,
            ),
            DirectNote::Tested(_) => (l10n.desktop_direct_test_failed(), false),
            DirectNote::Saved => (l10n.saved(), true),
        });
        div()
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
            // The connection in one group, as Settings' groups are drawn.
            .child(form_group(
                vec![
                    form_row(l10n.desktop_provider_type(), kind, cx).into_any_element(),
                    field(
                        l10n.desktop_connection_name(),
                        &self.name,
                        None,
                        None,
                        window,
                        cx,
                    )
                    .into_any_element(),
                    field(
                        l10n.desktop_server_address(),
                        &self.base_url,
                        Some(l10n.direct_base_url_description().into()),
                        None,
                        window,
                        cx,
                    )
                    .into_any_element(),
                    field(
                        l10n.desktop_api_key(),
                        &self.api_key,
                        None,
                        None,
                        window,
                        cx,
                    )
                    .into_any_element(),
                ],
                cx,
            ))
            .child(grouped(
                vec![
                    setting_row(
                        l10n.desktop_allow_unverified_certificate(),
                        None,
                        Switch::new(
                            "direct-self-signed",
                            l10n.desktop_allow_unverified_certificate(),
                            self.self_signed,
                        )
                        .on_click(toggle),
                        cx,
                    )
                    .into_any_element(),
                ],
                cx,
            ))
            .when_some(self.error.clone(), |d, e| {
                d.child(form_error("direct-error", e, cx))
            })
            .when_some(note, |d, (text, ok)| d.child(form_note(text, ok, cx)))
            .child(
                div()
                    .flex()
                    .justify_end()
                    .gap(px(8.))
                    .when(!self.onboarding, |d| {
                        d.child(Button::new("direct-cancel", l10n.cancel()).on_click({
                            let this = this.clone();
                            Rc::new(move |_, _, cx| {
                                let _ = this.update(cx, |s, cx| {
                                    s.form_open = false;
                                    cx.notify();
                                });
                            })
                        }))
                    })
                    .child(
                        Button::new("direct-test", l10n.desktop_test_connection())
                            .disabled(!self.can_save(cx))
                            .on_click(act(|s, w, cx| s.test(w, cx))),
                    )
                    .child(
                        // First run: one verb on every connection form
                        // ("Connect"); in Settings it saves an edit.
                        Button::new(
                            "direct-save",
                            match (self.busy, self.onboarding) {
                                (true, true) => l10n.desktop_connecting(),
                                (true, false) => l10n.desktop_saving(),
                                (false, true) => l10n.desktop_connect(),
                                (false, false) => l10n.save(),
                            },
                        )
                        .primary()
                        .disabled(!self.can_save(cx))
                        .on_click(act(|s, w, cx| s.save(w, cx))),
                    ),
            )
            .into_any_element()
    }

    /// The saved connections, for Settings.
    pub fn list_rows(&self, cx: &mut Context<Self>) -> AnyElement {
        let l10n = cx.l10n().clone();
        let t = cx.conduit().clone();
        let this = cx.entity().downgrade();
        let connections = self
            .list
            .as_ref()
            .map(|l| l.connections.clone())
            .unwrap_or_default();
        if connections.is_empty() {
            // The empty group holds its own way out, as Internet Accounts'
            // empty list does: the sentence, and Add Connection… beside it.
            return grouped(
                vec![
                    setting_row(l10n.desktop_direct_none(), None, self.add_button(cx), cx)
                        .into_any_element(),
                ],
                cx,
            )
            .into_any_element();
        }
        let rows: Vec<AnyElement> = connections
            .into_iter()
            .map(|c| {
                let id = c.id.clone();
                let subtitle: SharedString = format!(
                    "{} \u{b7} {}",
                    match c.kind {
                        DirectKind::Ollama => l10n.ollama(),
                        _ => l10n.desktop_open_ai_compatible(),
                    },
                    forms::host_of(&c.base_url)
                )
                .into();
                let toggle = {
                    let (this, id, on) = (this.clone(), id.clone(), c.enabled);
                    Rc::new(move |_: &ClickEvent, window: &mut Window, cx: &mut App| {
                        let _ = this.update(cx, |s, cx| s.set_enabled(id.clone(), !on, window, cx));
                    })
                };
                let edit = {
                    let (this, c) = (this.clone(), c.clone());
                    Rc::new(move |_: &ClickEvent, window: &mut Window, cx: &mut App| {
                        let _ = this.update(cx, |s, cx| s.open_edit(&c, window, cx));
                    })
                };
                let remove = {
                    let (this, c) = (this.clone(), c.clone());
                    Rc::new(move |_: &ClickEvent, window: &mut Window, cx: &mut App| {
                        let _ = this.update(cx, |s, cx| s.remove(c.clone(), window, cx));
                    })
                };
                setting_row(
                    c.name.clone(),
                    Some(subtitle),
                    div()
                        .flex()
                        .items_center()
                        .gap(px(8.))
                        .child(
                            Button::new(
                                ElementId::Name(format!("direct-edit-{id}").into()),
                                l10n.edit(),
                            )
                            .ghost()
                            .on_click(edit),
                        )
                        .child(
                            Button::new(
                                ElementId::Name(format!("direct-remove-{id}").into()),
                                l10n.desktop_delete_ellipsis(),
                            )
                            .ghost()
                            .on_click(remove),
                        )
                        .child(
                            Switch::new(
                                ElementId::Name(format!("direct-enabled-{id}").into()),
                                l10n.desktop_direct_enable(&c.name),
                                c.enabled,
                            )
                            .on_click(toggle),
                        ),
                    cx,
                )
                .into_any_element()
            })
            .collect();
        let _ = t;
        grouped(rows, cx).into_any_element()
    }
}

impl DirectView {
    /// Add Connection…: in the empty group, or under the list.
    fn add_button(&self, cx: &mut Context<Self>) -> Button {
        let l10n = cx.l10n().clone();
        let this = cx.entity().downgrade();
        let add = Rc::new(move |_: &ClickEvent, window: &mut Window, cx: &mut App| {
            let _ = this.update(cx, |s, cx| s.open_new(window, cx));
        });
        Button::new("direct-add", l10n.desktop_add_connection_ellipsis())
            .icon(IconName::Plus)
            .disabled(self.form_open && self.editing.is_none())
            .on_click(add)
    }

    fn has_connections(&self) -> bool {
        self.list
            .as_ref()
            .is_some_and(|l| !l.connections.is_empty())
    }
}

impl Render for DirectView {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        if self.onboarding {
            return div().child(self.form(window, cx));
        }
        // The list is the page's group (Settings' 12 pt inset, not a card
        // inside a card), its note under it, then Add Connection… (which
        // the empty group holds itself).
        let listed = self.has_connections();
        div()
            .flex()
            .flex_col()
            .gap(px(12.))
            .child(
                div()
                    .flex()
                    .flex_col()
                    .gap(px(6.))
                    .child(self.list_rows(cx))
                    .children(self.footer.clone().map(|f| forms::group_footer(f, cx))),
            )
            .when(listed, |d| {
                d.child(div().flex().justify_end().child(self.add_button(cx)))
            })
            .when(self.form_open, |d| d.child(self.form(window, cx)))
    }
}

#[cfg(test)]
mod tests {
    use conduit_protocol::methods;
    use gpui_kit::{Entity, TestAppContext, VisualTestContext};
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
        onboarding: bool,
        cx: &mut TestAppContext,
    ) -> (FakeDaemon, Entity<DirectView>, &mut VisualTestContext) {
        let daemon = FakeDaemon::new();
        let scratch = std::env::temp_dir().join(format!("conduit-direct-{}", std::process::id()));
        let stores = cx.update(|cx| {
            crate::views::test_globals(cx);
            Stores::for_test(daemon.rpc(), &scratch, cx)
        });
        let (view, vcx) =
            cx.add_window_view(move |window, cx| DirectView::new(stores, onboarding, window, cx));
        (daemon, view, vcx)
    }

    #[gpui_kit::test]
    fn a_switch_flipped_while_the_form_is_open_is_kept(cx: &mut TestAppContext) {
        let (daemon, view, vcx) = bench(false, cx);
        let mut on = connection("c1");
        on.enabled = true;
        daemon.returns::<methods::DirectSetEnabled>(list(vec![on.clone()]));
        daemon.returns::<methods::DirectSave>(list(vec![on]));
        view.update_in(vcx, |v, window, cx| {
            v.open_edit(&connection("c1"), window, cx);
            v.set_enabled("c1".into(), true, window, cx);
        });
        vcx.run_until_parked();
        view.update_in(vcx, |v, window, cx| v.save(window, cx));
        vcx.run_until_parked();
        assert_eq!(daemon.calls::<methods::DirectSave>()[0]["enabled"], true);
    }

    #[gpui_kit::test]
    fn renaming_a_connection_keeps_what_the_form_does_not_show(cx: &mut TestAppContext) {
        let (daemon, view, vcx) = bench(false, cx);
        daemon.returns::<methods::DirectSave>(list(vec![connection("c1")]));
        view.update_in(vcx, |v, window, cx| {
            v.open_edit(&connection("c1"), window, cx);
            v.name
                .update(cx, |i, cx| i.set_value("Lab two", window, cx));
            v.save(window, cx);
        });
        vcx.run_until_parked();
        let sent = &daemon.calls::<methods::DirectSave>()[0];
        assert_eq!(sent["name"], "Lab two");
        assert_eq!(sent["apiMode"], "responses");
        assert_eq!(sent["apiVersion"], "2025-01-01");
        assert_eq!(sent["apiKeyHeader"], true);
        assert_eq!(sent["modelIdPrefix"], "lab/");
        assert_eq!(sent["enabled"], false);
        assert_eq!(sent["manualModelIds"], json!(["synthetic-model"]));
        assert_eq!(sent["tags"], json!(["work"]));
    }

    #[gpui_kit::test]
    fn without_a_list_a_retry_never_takes_over_another_connection(cx: &mut TestAppContext) {
        let (daemon, view, vcx) = bench(true, cx);
        daemon.on::<methods::DirectList>(|_| {
            Err(conduit_daemon::protocol::error("rpc.timeout", "slow"))
        });
        daemon.returns::<methods::DirectSave>(list(vec![connection("old"), connection("made")]));
        daemon.once::<methods::DirectSetPreferred>(Err(conduit_daemon::protocol::error(
            "rpc.timeout",
            "slow",
        )));
        daemon.returns::<methods::DirectSetPreferred>(list(vec![connection("made")]));
        view.update_in(vcx, |v, window, cx| {
            v.list = None;
            v.open_new(window, cx);
            v.base_url.update(cx, |i, cx| {
                i.set_value("http://127.0.0.1:11434/v1", window, cx)
            });
            v.save(window, cx);
        });
        vcx.run_until_parked();
        view.update_in(vcx, |v, window, cx| v.save(window, cx));
        vcx.run_until_parked();
        let sent = daemon.calls::<methods::DirectSave>();
        assert_eq!(sent.len(), 2);
        assert_ne!(
            sent[1]["id"], "old",
            "another connection was taken for the new one"
        );
    }

    #[gpui_kit::test]
    fn a_save_that_went_through_is_not_added_twice(cx: &mut TestAppContext) {
        let (daemon, view, vcx) = bench(true, cx);
        daemon.returns::<methods::DirectList>(list(vec![]));
        daemon.returns::<methods::DirectSave>(list(vec![connection("made")]));
        daemon.once::<methods::DirectSetPreferred>(Err(conduit_daemon::protocol::error(
            "rpc.timeout",
            "slow",
        )));
        daemon.returns::<methods::DirectSetPreferred>(list(vec![connection("made")]));
        view.update_in(vcx, |v, window, cx| {
            v.open_new(window, cx);
            v.base_url.update(cx, |i, cx| {
                i.set_value("http://127.0.0.1:11434/v1", window, cx)
            });
            v.save(window, cx);
        });
        vcx.run_until_parked();
        view.update_in(vcx, |v, window, cx| v.save(window, cx));
        vcx.run_until_parked();
        let sent = daemon.calls::<methods::DirectSave>();
        assert_eq!(sent.len(), 2);
        assert_eq!(sent[0]["id"], serde_json::Value::Null);
        assert_eq!(
            sent[1]["id"], "made",
            "the second Connect edits what the first made"
        );
    }
}
