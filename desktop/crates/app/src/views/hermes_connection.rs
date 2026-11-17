//! A Hermes connection's editor: a window sheet on Settings, as the
//! phone's connection page (`hermes_settings_page.dart`) and Mail's
//! account sheet present one.
//!
//! Name, server URL and connection type; for an API server its key; for a
//! Desktop Gateway how it signs in (Hermes Sign-In in the browser, or its
//! legacy session token, which only this form sends) and its profile; and
//! whether an unverified certificate is accepted. Test Connection tries
//! the form without saving it (and names the connection after what the
//! server reports, when it was left unnamed); Save keeps it. A saved one
//! that is not in use offers Use This Connection; Delete… asks first.
//! Credentials about to travel unencrypted are asked for, as on a phone.
//! Secrets are never shown: a kept one says so in its field's placeholder.

use std::rc::Rc;

use conduit_components::ActiveConduitTheme as _;
use conduit_components::views::kit::{
    Button, Segment, Segmented, Switch, grouped_section, setting_row,
};
use conduit_daemon::RpcError;
use conduit_protocol::{
    HermesConnectionDto, HermesConnectionEdit, HermesConnections, HermesRef, NoParams, NoticeLevel,
    methods,
};
use gpui_kit::component::input::{InputEvent, InputState};
use gpui_kit::prelude::*;
use gpui_kit::{
    AnyElement, App, AsyncApp, Context, Entity, FontWeight, Role, SharedString, Subscription,
    WeakEntity, Window, div, px, relative,
};

use crate::l10n::{ActiveL10n as _, L10n};
use crate::shell::sheet::{SheetSpec, present_sheet};
use crate::stores::Stores;
use crate::stores::hermes_admin;
use crate::views::forms;
use crate::views::sheet::{self, SheetBody};
use crate::views::words;

/// The sheet's width.
pub const WIDTH: f32 = 520.;

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

/// What the form holds, to tell an edited form from an untouched one.
#[derive(Clone, Debug, Default, PartialEq)]
struct Form {
    name: String,
    url: String,
    desktop: bool,
    token_auth: bool,
    api_key: String,
    token: String,
    profile: String,
    self_signed: bool,
}

#[derive(Clone, Debug, PartialEq)]
pub enum Note {
    Tested { ok: bool, text: String },
    SigningIn,
}

pub struct HermesConnectionSheet {
    stores: Stores,
    /// The saved connection edited; `None` for a new one until it is saved.
    pub existing: Option<HermesConnectionDto>,
    pub name: Entity<InputState>,
    pub url: Entity<InputState>,
    pub api_key: Entity<InputState>,
    pub token: Entity<InputState>,
    pub profile: Entity<InputState>,
    pub desktop: bool,
    /// A Desktop Gateway signs in with its session token, not natively.
    pub token_auth: bool,
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
        let token = forms::input(l.hermes_legacy_session_token_hint(), true, window, cx);
        let profile = forms::input("default", false, window, cx);
        let mut subscriptions = vec![];
        for input in [&name, &url, &api_key, &token, &profile] {
            subscriptions.push(cx.subscribe_in(
                input,
                window,
                |this: &mut Self, _, e: &InputEvent, window, cx| match e {
                    InputEvent::PressEnter { .. } if this.can_save(cx) => this.save(window, cx),
                    InputEvent::Change => {
                        this.note = None;
                        this.error = None;
                        cx.notify();
                    }
                    _ => {}
                },
            ));
        }
        let mut this = Self {
            stores,
            existing: existing.clone(),
            name,
            url,
            api_key,
            token,
            profile,
            desktop: false,
            token_auth: false,
            self_signed: false,
            plain_http_ok: None,
            initial: Form::default(),
            busy: false,
            note: None,
            error: None,
            _subscriptions: subscriptions,
        };
        if let Some(c) = existing {
            this.desktop = c.mode == "desktop";
            this.token_auth = c.desktop_auth_kind == "legacyToken";
            this.self_signed = c.allow_self_signed_certificates;
            let (n, u, p) = (
                c.name.clone(),
                c.base_url.clone(),
                c.desktop_profile.clone(),
            );
            this.name.update(cx, |i, cx| i.set_value(n, window, cx));
            this.url.update(cx, |i, cx| i.set_value(u, window, cx));
            this.profile.update(cx, |i, cx| i.set_value(p, window, cx));
            if c.has_api_key {
                forms::set_hint(&this.api_key, l.hermes_configured_replace_placeholder(), cx);
            }
            if c.has_legacy_token {
                forms::set_hint(&this.token, l.hermes_configured_replace_placeholder(), cx);
            }
        } else {
            // A new connection: a Desktop Gateway signing in with its token
            // is what a gateway on this Mac asks for.
            this.desktop = true;
            this.token_auth = true;
        }
        this.initial = this.form(cx);
        let focus = this.url.clone();
        focus.update(cx, |i, cx| i.focus(window, cx));
        this
    }

    fn form(&self, cx: &App) -> Form {
        Form {
            name: forms::text(&self.name, cx),
            url: forms::text(&self.url, cx),
            desktop: self.desktop,
            token_auth: self.token_auth,
            api_key: forms::raw(&self.api_key, cx),
            token: forms::raw(&self.token, cx),
            profile: forms::text(&self.profile, cx),
            self_signed: self.self_signed,
        }
    }

    fn dirty(&self, cx: &App) -> bool {
        self.form(cx) != self.initial
    }

    pub fn can_save(&self, cx: &App) -> bool {
        !self.busy && forms::filled(&[&self.url], cx)
    }

    /// The edit the form makes, or why it cannot be sent.
    fn edit(&mut self, cx: &mut Context<Self>) -> Option<HermesConnectionEdit> {
        let l = cx.l10n().clone();
        let Some(base_url) = forms::normalize_url(&forms::text(&self.url, cx)) else {
            self.error = Some(l.desktop_invalid_server_address());
            cx.notify();
            return None;
        };
        let name = forms::text(&self.name, cx);
        let key = forms::raw(&self.api_key, cx);
        let token = forms::raw(&self.token, cx);
        let profile = forms::text(&self.profile, cx);
        let renamed = self.existing.as_ref().is_none_or(|c| c.name != name);
        Some(HermesConnectionEdit {
            id: self.existing.as_ref().map(|c| c.id.clone()),
            // Untouched, the saved name stays; empty, the server's host.
            name: renamed.then_some(name),
            allow_plain_http: self.plain_http_ok.as_deref() == Some(base_url.as_str()),
            base_url,
            mode: if self.desktop { "desktop" } else { "responses" }.into(),
            // A method chosen here, or the saved one (a dashboard cookie,
            // which this form has no choice for) when left as it was.
            desktop_auth_kind: match &self.existing {
                Some(c) if self.token_auth == self.initial.token_auth => {
                    c.desktop_auth_kind.clone()
                }
                _ if self.token_auth => "legacyToken".into(),
                _ => "nativePkce".into(),
            },
            desktop_profile: if profile.is_empty() {
                "default".into()
            } else {
                profile
            },
            // A blank secret field keeps the saved secret.
            api_key: (!self.desktop && !key.trim().is_empty()).then_some(key),
            legacy_token: (self.desktop && self.token_auth && !token.trim().is_empty())
                .then_some(token),
            allow_self_signed_certificates: self.self_signed,
        })
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
            forms::focus_invalid(&self.url.clone(), window, cx);
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
            forms::focus_invalid(&self.url.clone(), window, cx);
            return;
        };
        let url = edit.base_url.clone();
        let sent = self.form(cx);
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
                            if saved.is_some() {
                                s.existing = saved;
                            }
                            s.initial = sent;
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

    /// Hermes Sign-In needs the live connection, as on a phone: the form
    /// is saved, put in use, then signed in through the browser.
    pub fn sign_in(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.save_then(window, cx, |s, list, window, cx| {
            let Some(id) = s.existing.as_ref().map(|c| c.id.clone()) else {
                return;
            };
            let rpc = s.stores.connection.read(cx).rpc();
            let activate = (list.active_id.as_deref() != Some(id.as_str()))
                .then(|| rpc.call::<methods::HermesConnectionsActivate>(&HermesRef { id }));
            s.busy = true;
            s.note = Some(Note::SigningIn);
            cx.notify();
            let handle = window.window_handle();
            cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
                let mut failed: Option<RpcError> = None;
                if let Some(activate) = activate
                    && let Err(e) = activate.await
                {
                    failed = Some(e);
                }
                // Asked only once the connection is in use: a call goes out
                // as soon as it is made.
                if failed.is_none()
                    && let Err(e) = rpc.call::<methods::HermesSignIn>(&NoParams).await
                {
                    failed = Some(e);
                }
                let _ = handle.update(cx, |_, _, cx| {
                    let _ = this.update(cx, |s, cx| {
                        s.busy = false;
                        s.note = None;
                        let l = cx.l10n().clone();
                        if let Some(e) = failed {
                            s.error = Some(match e.code.as_str() {
                                "rpc.unauthorized" => l.desktop_hermes_test_unauthorized(),
                                _ => words::connect_error(&e, &l),
                            });
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

    fn signed_in(&self, cx: &App) -> bool {
        let id = self.existing.as_ref().map(|c| c.id.as_str());
        self.stores
            .hermes_admin
            .read(cx)
            .connections
            .as_ref()
            .and_then(|l| l.connections.iter().find(|c| Some(c.id.as_str()) == id))
            .is_some_and(|c| c.desktop_signed_in)
    }
}

/// The daemon refused to send credentials unencrypted unasked.
fn is_plain_http(e: &RpcError) -> bool {
    e.args.get("reason").map(String::as_str) == Some("plainHttpConsent")
}

impl SheetBody for HermesConnectionSheet {
    fn cancel(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.busy && self.note != Some(Note::SigningIn) {
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
        let active = self.existing.as_ref().is_some_and(|c| c.active);
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
            .on_select(Rc::new(move |i, _, cx| {
                let _ = this.update(cx, |s, cx| {
                    s.desktop = i == 1;
                    s.note = None;
                    cx.notify();
                });
            }))
        };
        let derived = forms::host_of(&forms::text(&self.url, cx));
        let name_hint = if derived.is_empty() {
            l.hermes_agent_settings_title()
        } else {
            derived
        };
        let mut details = vec![
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
        let _ = &mut details;
        let mut auth: Vec<AnyElement> = vec![];
        if self.desktop {
            let this2 = this.clone();
            let kind = Segmented::new(
                "hermes-connection-auth",
                l.desktop_hermes_sign_in_with(),
                vec![
                    Segment::new(l.desktop_hermes_auth_native()),
                    Segment::new(l.desktop_hermes_auth_token()),
                ],
                usize::from(self.token_auth),
            )
            .on_select(Rc::new(move |i, _, cx| {
                let _ = this2.update(cx, |s, cx| {
                    s.token_auth = i == 1;
                    s.note = None;
                    cx.notify();
                });
            }));
            auth.push(
                forms::form_row(l.desktop_hermes_sign_in_with(), kind, cx).into_any_element(),
            );
            if self.token_auth {
                auth.push(
                    forms::field(
                        l.hermes_legacy_session_token(),
                        &self.token,
                        Some(l.desktop_hermes_auth_token_help().into()),
                        None,
                        window,
                        cx,
                    )
                    .into_any_element(),
                );
            } else {
                let signed_in = self.signed_in(cx);
                let active = saved.as_ref().is_some_and(|c| c.active);
                let button = if signed_in && active {
                    let this = this.clone();
                    Button::new("hermes-connection-sign-out", l.desktop_sign_out_of_hermes())
                        .disabled(self.busy)
                        .on_click(Rc::new(move |_, w, cx| {
                            let _ = this.update(cx, |s, cx| s.sign_out(w, cx));
                        }))
                } else {
                    let this = this.clone();
                    Button::new("hermes-connection-sign-in", l.desktop_sign_in_with_hermes())
                        .disabled(!self.can_save(cx))
                        .on_click(Rc::new(move |_, w, cx| {
                            let _ = this.update(cx, |s, cx| s.sign_in(w, cx));
                        }))
                };
                auth.push(
                    setting_row(
                        l.desktop_hermes_auth_native(),
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
            auth.push(
                forms::field(
                    l.hermes_profile_label(),
                    &self.profile,
                    None,
                    None,
                    window,
                    cx,
                )
                .into_any_element(),
            );
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
        }
        let auth_footer = if self.desktop {
            if self.token_auth {
                None
            } else if saved.as_ref().is_none_or(|c| !c.active) {
                Some(l.hermes_sign_in_activates_connection())
            } else {
                Some(l.desktop_hermes_mode_gateway_help())
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
        let note = self.note.as_ref().map(|n| match n {
            Note::Tested { ok, text } => (text.clone(), *ok),
            Note::SigningIn => (l.desktop_hermes_signing_in(), false),
        });
        let inactive_notice = saved
            .as_ref()
            .filter(|c| !c.active)
            .map(|_| l.hermes_inactive_connection_notice());
        div()
            .id("hermes-connection-sheet")
            .role(Role::Form)
            .aria_label(SharedString::from(title.clone()))
            .w_full()
            .flex()
            .flex_col()
            .gap(px(16.))
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
                None,
                vec![
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
                None,
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
