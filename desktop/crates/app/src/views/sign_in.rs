//! Sign-in for the active Open WebUI account: email and password, LDAP, an
//! API key (`auth.*`), or single sign-on in a browser window
//! (`auth.completeExternal`).
//!
//! The account comes from the session: its server shows in a chip at the
//! top. An addition (from Accounts) can be cancelled back to the account it
//! started from (`accounts.cancelAdd`); a first account can go back to a
//! different server (the unfinished account is removed).

use std::rc::Rc;

use conduit_components::ActiveConduitTheme as _;
use conduit_components::assets::IconName;
use conduit_components::theme::with_alpha;
use conduit_components::views::kit::{Button, Segment, Segmented, icon_tile};
use conduit_components::views::onboarding::{back_link, title_block};
use conduit_daemon::RpcError;
use conduit_protocol::{
    ApiKeyLogin, AuthPhase, AuthSnapshot, ExternalAuthCompletion, PasswordLogin, methods,
};
use gpui_kit::component::input::{InputEvent, InputState};
use gpui_kit::prelude::*;
use gpui_kit::{
    App, AsyncWindowContext, ClickEvent, Context, Entity, Role, SharedString, Subscription,
    WeakEntity, Window, div, px,
};

use crate::l10n::ActiveL10n as _;
use crate::shell::sso::{SsoOutcome, run_sso};
use crate::stores::Stores;
use crate::stores::accounts::AccountChange;
use crate::views::forms::{
    self, field, field_hinted, form_buttons, form_error, form_group, form_note, host_of,
};
use crate::views::{privacy, words};

/// How the user signs in.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Method {
    Password,
    Ldap,
    ApiKey,
}

impl Method {
    pub const ALL: [Self; 3] = [Self::Password, Self::Ldap, Self::ApiKey];
}

pub struct SignInView {
    stores: Stores,
    pub method: Method,
    pub email: Entity<InputState>,
    pub password: Entity<InputState>,
    pub api_key: Entity<InputState>,
    pub busy: bool,
    /// Single sign-on is running in its window.
    pub sso: bool,
    pub error: Option<String>,
    /// A neutral line (a proxy let the user through, SSO cancelled).
    pub note: Option<String>,
    _subscriptions: Vec<Subscription>,
}

impl SignInView {
    pub fn new(stores: Stores, window: &mut Window, cx: &mut Context<Self>) -> Self {
        // An example, or "Required", as System Settings › Internet
        // Accounts' forms say what goes in each field.
        let l10n = cx.l10n().clone();
        let email = forms::input(l10n.desktop_email_placeholder(), false, window, cx);
        let password = forms::input(l10n.desktop_required_placeholder(), true, window, cx);
        let api_key = forms::input(l10n.desktop_required_placeholder(), true, window, cx);
        let on_input = |this: &mut Self,
                        _: &Entity<InputState>,
                        e: &InputEvent,
                        window: &mut Window,
                        cx: &mut Context<Self>| match e {
            // Return is the default button's: nothing while it is off.
            InputEvent::PressEnter { .. } if this.ready(cx) => this.submit(window, cx),
            // Typing clears the last error and may turn Sign In on.
            InputEvent::Change => {
                this.error = None;
                cx.notify();
            }
            _ => {}
        };
        let subscriptions = vec![
            cx.subscribe_in(&email, window, on_input),
            cx.subscribe_in(&password, window, on_input),
            cx.subscribe_in(&api_key, window, on_input),
            // A new account to sign in to clears what the last one left.
            cx.observe(&stores.accounts, |this: &mut Self, _, cx| {
                if !this.busy && this.error.is_some() {
                    cx.notify();
                }
            }),
        ];
        Self {
            stores,
            method: Method::Password,
            email,
            password,
            api_key,
            busy: false,
            sso: false,
            error: None,
            note: None,
            _subscriptions: subscriptions,
        }
    }

    /// Empties the fields (after a sign-in, or for the next account).
    pub fn reset(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        for input in [&self.email, &self.password, &self.api_key] {
            input.update(cx, |i, cx| i.set_value("", window, cx));
        }
        self.busy = false;
        self.sso = false;
        self.error = None;
        self.note = None;
        cx.notify();
    }

    pub fn set_method(&mut self, method: Method, cx: &mut Context<Self>) {
        self.method = method;
        self.error = None;
        cx.notify();
    }

    /// Whether Sign In can go: not busy, and the method's fields filled.
    pub fn ready(&self, cx: &App) -> bool {
        !self.busy
            && match self.method {
                Method::Password | Method::Ldap => {
                    forms::filled(&[&self.email, &self.password], cx)
                }
                Method::ApiKey => forms::filled(&[&self.api_key], cx),
            }
    }

    /// The active account's server: its display name and address.
    fn server(&self, cx: &App) -> Option<(String, String)> {
        let accounts = self.stores.accounts.read(cx);
        let a = accounts.active()?;
        Some((a.connection.name.clone(), a.connection.url.clone()))
    }

    pub fn submit(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.busy {
            return;
        }
        let l10n = cx.l10n().clone();
        self.error = None;
        self.note = None;
        let rpc = self.stores.connection.read(cx).rpc();
        let call = match self.method {
            Method::Password | Method::Ldap => {
                let username = forms::text(&self.email, cx);
                let password = forms::raw(&self.password, cx);
                if username.is_empty() || password.is_empty() {
                    self.error = Some(l10n.desktop_sign_in_fields_required());
                    let empty = if username.is_empty() {
                        &self.email
                    } else {
                        &self.password
                    };
                    forms::focus_invalid(&empty.clone(), window, cx);
                    cx.notify();
                    return;
                }
                let login = PasswordLogin { username, password };
                if self.method == Method::Ldap {
                    futures::FutureExt::boxed(rpc.call::<methods::AuthLoginWithLdap>(&login))
                } else {
                    futures::FutureExt::boxed(rpc.call::<methods::AuthLoginWithPassword>(&login))
                }
            }
            Method::ApiKey => {
                let api_key = forms::text(&self.api_key, cx);
                if api_key.is_empty() {
                    self.error = Some(l10n.direct_connection_api_key_required());
                    forms::focus_invalid(&self.api_key.clone(), window, cx);
                    cx.notify();
                    return;
                }
                futures::FutureExt::boxed(
                    rpc.call::<methods::AuthLoginWithApiKey>(&ApiKeyLogin { api_key }),
                )
            }
        };
        self.busy = true;
        cx.notify();
        cx.spawn_in(
            window,
            async move |this: WeakEntity<Self>, cx: &mut AsyncWindowContext| {
                let result = call.await;
                let _ = this.update_in(cx, |s, window, cx| s.finish(result, window, cx));
            },
        )
        .detach();
    }

    fn finish(
        &mut self,
        result: Result<AuthSnapshot, RpcError>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let l10n = cx.l10n().clone();
        self.busy = false;
        self.sso = false;
        match result {
            Ok(snapshot) if snapshot.is_authenticated => {
                self.stores
                    .session
                    .update(cx, |s, cx| s.adopt_auth(snapshot, cx));
                self.reset(window, cx);
            }
            Ok(snapshot) => {
                let code = snapshot.error_code.clone().unwrap_or_else(|| {
                    if snapshot.phase == AuthPhase::CredentialError {
                        "auth.invalidCredentials".into()
                    } else {
                        String::new()
                    }
                });
                self.error = Some(words::sign_in_error(&code, &l10n));
                self.stores
                    .session
                    .update(cx, |s, cx| s.adopt_auth(snapshot, cx));
                self.focus_secret(window, cx);
            }
            Err(e) => {
                self.error = Some(words::sign_in_error(e.code.as_str(), &l10n));
                self.focus_secret(window, cx);
            }
        }
        cx.notify();
    }

    /// After a refused sign-in: the password (or key) to retype, selected,
    /// as Mail's account sheet does; never Back.
    fn focus_secret(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let field = match self.method {
            Method::Password | Method::Ldap => self.password.clone(),
            Method::ApiKey => self.api_key.clone(),
        };
        forms::focus_invalid(&field, window, cx);
    }

    /// Single sign-on in a browser window, then `auth.completeExternal`.
    pub fn start_sso(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.busy {
            return;
        }
        let Some((name, url)) = self.server(cx) else {
            return;
        };
        let l10n = cx.l10n().clone();
        self.error = None;
        self.note = None;
        self.busy = true;
        self.sso = true;
        cx.notify();
        let rpc = self.stores.connection.read(cx).rpc();
        let outcome = run_sso(&url, l10n.desktop_sso_window_title(&name), cx);
        cx.spawn_in(
            window,
            async move |this: WeakEntity<Self>, cx: &mut AsyncWindowContext| {
                let outcome = outcome.await;
                let completion = match outcome {
                    SsoOutcome::Captured {
                        origin,
                        cookies,
                        token,
                    } => ExternalAuthCompletion {
                        origin,
                        cookies,
                        token,
                    },
                    other => {
                        let _ = this.update(cx, |s, cx| {
                            s.busy = false;
                            s.sso = false;
                            match other {
                                SsoOutcome::Cancelled => {
                                    s.note = Some(l10n.desktop_sso_cancelled())
                                }
                                SsoOutcome::TimedOut => {
                                    s.error = Some(l10n.desktop_sso_timed_out())
                                }
                                _ => s.error = Some(l10n.desktop_sso_failed()),
                            }
                            cx.notify();
                        });
                        return;
                    }
                };
                let result = rpc.call::<methods::AuthCompleteExternal>(&completion).await;
                let _ = this.update_in(cx, |s, window, cx| {
                    if let Ok(snapshot) = &result
                        && !snapshot.is_authenticated
                        && snapshot.error_code.is_none()
                    {
                        // A proxy let the user through; Open WebUI still wants
                        // its own sign-in.
                        s.busy = false;
                        s.sso = false;
                        s.note = Some(l10n.desktop_sso_needs_password());
                        cx.notify();
                        return;
                    }
                    s.finish(result, window, cx);
                });
            },
        )
        .detach();
    }

    /// Cancel an addition, or (first account) go back to a different server.
    pub fn back(&mut self, cx: &mut Context<Self>) {
        if self.busy {
            return;
        }
        let accounts = self.stores.accounts.clone();
        let (adding, never_signed_in) = {
            let a = accounts.read(cx);
            (
                a.adding(),
                a.active()
                    .map(|a| (a.id.clone(), a.user.is_none() && !a.has_session)),
            )
        };
        let change = if adding {
            AccountChange::CancelAdd
        } else if let Some((id, true)) = never_signed_in {
            AccountChange::Remove { account_id: id }
        } else {
            return;
        };
        accounts
            .update(cx, |a, cx| a.change(change, true, cx))
            .detach();
        self.error = None;
        cx.notify();
    }
}

impl Render for SignInView {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let l10n = cx.l10n().clone();
        let t = cx.conduit().clone();
        let r = t.roles;
        let m = t.metrics;
        let this = cx.entity().downgrade();
        let (server_name, server_host) = self
            .server(cx)
            .map(|(n, u)| (privacy::host(&n, cx), privacy::host(&host_of(&u), cx)))
            .unwrap_or_default();
        let (adding, can_go_back, expired) = {
            let a = self.stores.accounts.read(cx);
            let active = a.active();
            (
                a.adding(),
                active.is_some_and(|a| a.user.is_none() && !a.has_session),
                active.is_some_and(|a| a.user.is_some()),
            )
        };
        let back_label: Option<SharedString> = if adding {
            Some(l10n.cancel().into())
        } else if can_go_back {
            Some(l10n.desktop_use_different_server().into())
        } else {
            None
        };
        let handler = |f: fn(&mut SignInView, &mut Window, &mut Context<SignInView>)| {
            let this = this.clone();
            Rc::new(move |_: &ClickEvent, window: &mut Window, cx: &mut App| {
                let _ = this.update(cx, |s, cx| f(s, window, cx));
            })
        };
        let methods = Segmented::new(
            "sign-in-method",
            l10n.desktop_sign_in_method(),
            vec![
                Segment::new(l10n.password()),
                Segment::new(l10n.ldap()),
                Segment::new(l10n.desktop_api_key()),
            ],
            Method::ALL
                .iter()
                .position(|m| *m == self.method)
                .unwrap_or(0),
        )
        .on_select({
            let this = this.clone();
            Rc::new(move |i, _, cx| {
                let _ = this.update(cx, |s, cx| s.set_method(Method::ALL[i], cx));
            })
        });
        let ldap = self.method == Method::Ldap;
        let fields = form_group(
            match self.method {
                Method::Password | Method::Ldap => vec![
                    // An address as the example; an LDAP name has none.
                    field_hinted(
                        if ldap {
                            l10n.ldap_username()
                        } else {
                            l10n.desktop_email_or_username()
                        },
                        &self.email,
                        Some(
                            if ldap {
                                l10n.desktop_required_placeholder()
                            } else {
                                l10n.desktop_email_placeholder()
                            }
                            .into(),
                        ),
                        None,
                        None,
                        window,
                        cx,
                    )
                    .into_any_element(),
                    field(l10n.password(), &self.password, None, None, window, cx)
                        .into_any_element(),
                ],
                Method::ApiKey => vec![
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
            },
            cx,
        );
        let chip = div()
            .id("server-chip")
            .role(Role::Group)
            .aria_label(l10n.desktop_server_chip_label(&server_name, &server_host))
            .h(px(30.))
            .pl(px(6.))
            .pr(px(12.))
            .flex()
            .items_center()
            .gap(px(7.))
            .rounded_full()
            .border_1()
            .border_color(r.border)
            .bg(t.surfaces.panel)
            .child(icon_tile(
                IconName::Server,
                20.,
                with_alpha(r.text, if t.dark { 0.14 } else { 0.07 }),
                r.text_subtle,
                10.,
            ))
            .child(
                div()
                    .text_size(px(m.small))
                    .text_color(r.text)
                    .child(server_name.clone()),
            )
            .child(
                div()
                    .text_size(px(m.small))
                    .text_color(r.text_subtle)
                    .child(server_host.clone()),
            );
        let subtitle = if expired {
            l10n.desktop_sign_in_again_body()
        } else {
            // The server's chip is above the title: no "below".
            l10n.desktop_sign_in_subtitle()
        };
        div()
            .id("sign-in")
            .role(Role::Form)
            .aria_label(l10n.desktop_sign_in())
            .flex()
            .flex_col()
            .gap(px(18.))
            .when_some(back_label, |d, label| {
                d.child(back_link(label, Some(handler(|s, _, cx| s.back(cx))), cx))
            })
            .child(
                div()
                    .flex()
                    .flex_col()
                    .items_center()
                    .gap(px(14.))
                    .child(chip)
                    .child(title_block(&l10n.desktop_sign_in(), &subtitle, false, cx)),
            )
            .child(div().flex().justify_center().child(methods))
            .child(fields)
            .when_some(self.error.clone(), |d, e| {
                d.child(form_error("sign-in-error", e, cx))
            })
            .when_some(self.note.clone(), |d, n| d.child(form_note(n, false, cx)))
            // A Mac dialog's buttons: at the trailing edge, the default one
            // (Return) last and off until its fields are filled, the other
            // way in beside it (Mail's account sheet).
            .child(form_buttons(vec![
                Button::new(
                    "sso",
                    if self.sso {
                        l10n.desktop_signing_in()
                    } else {
                        l10n.desktop_sign_in_with_sso()
                    },
                )
                .disabled(self.busy)
                .on_click(handler(|s, window, cx| s.start_sso(window, cx)))
                .into_any_element(),
                Button::new(
                    "sign-in",
                    if self.busy && !self.sso {
                        l10n.desktop_signing_in()
                    } else if ldap {
                        l10n.desktop_sign_in_with_ldap()
                    } else {
                        l10n.desktop_sign_in()
                    },
                )
                .primary()
                .disabled(!self.ready(cx))
                .on_click(handler(|s, window, cx| s.submit(window, cx)))
                .into_any_element(),
            ]))
    }
}
