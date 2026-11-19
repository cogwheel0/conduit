//! Sign-in for the active Open WebUI account: email and password, LDAP, a
//! session token (`auth.*`; the phone's Token, never an API key), or single
//! sign-on in a browser window (`auth.completeExternal`). A password or LDAP
//! sign-in the server answers with a second step continues in
//! [`TwoStepView`], in place of the form.
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
    AnyElement, App, AsyncWindowContext, ClickEvent, Context, Entity, Role, SharedString,
    Subscription, WeakEntity, Window, div, px,
};

use crate::l10n::ActiveL10n as _;
use crate::shell::sso::{SsoOutcome, run_sso};
use crate::stores::Stores;
use crate::stores::accounts::AccountChange;
use crate::views::forms::{
    self, field, field_hinted, form_buttons, form_error, form_group, form_note, group_footer,
    host_of,
};
use crate::views::two_step::TwoStepView;
use crate::views::{privacy, words};

/// How the user signs in.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Method {
    Password,
    Ldap,
    /// A session token (JWT) copied from Open WebUI on the web, as the
    /// phone's Token: Open WebUI's API keys (`sk-…`) cannot sign in.
    Token,
}

impl Method {
    pub const ALL: [Self; 3] = [Self::Password, Self::Ldap, Self::Token];
}

pub struct SignInView {
    stores: Stores,
    pub method: Method,
    pub email: Entity<InputState>,
    pub password: Entity<InputState>,
    pub token: Entity<InputState>,
    /// The second step, when the server asks for one.
    pub two_step: Entity<TwoStepView>,
    pub busy: bool,
    /// Single sign-on is running in its window.
    pub sso: bool,
    pub error: Option<String>,
    /// A neutral line (a proxy let the user through, SSO cancelled).
    pub note: Option<String>,
    /// The account the fields are for ([`sign_in_scope`]).
    scope: (Option<String>, bool),
    _subscriptions: Vec<Subscription>,
}

/// The account a sign-in form is for: the active one, and whether it is
/// being added.
pub(crate) fn sign_in_scope(
    accounts: &crate::stores::accounts::AccountsStore,
) -> (Option<String>, bool) {
    (accounts.active().map(|a| a.id.clone()), accounts.adding())
}

impl SignInView {
    pub fn new(stores: Stores, window: &mut Window, cx: &mut Context<Self>) -> Self {
        // An example, or "Required", as System Settings › Internet
        // Accounts' forms say what goes in each field.
        let l10n = cx.l10n().clone();
        let email = forms::input(l10n.desktop_email_placeholder(), false, window, cx);
        let password = forms::input(l10n.desktop_required_placeholder(), true, window, cx);
        let token = forms::input(l10n.desktop_required_placeholder(), true, window, cx);
        let two_step = cx.new(|cx| TwoStepView::new(stores.clone(), window, cx));
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
            cx.subscribe_in(&token, window, on_input),
            cx.observe(&two_step, |_, _, cx| cx.notify()),
            // Another account to sign in to (a switch, Back, an addition)
            // starts with empty fields: one account's password or key is
            // never sent to another's server.
            cx.observe_in(
                &stores.accounts,
                window,
                |this: &mut Self, accounts, window, cx| {
                    let scope = sign_in_scope(accounts.read(cx));
                    if scope != this.scope {
                        this.scope = scope;
                        this.clear(window, cx);
                    }
                },
            ),
        ];
        let scope = sign_in_scope(stores.accounts.read(cx));
        Self {
            scope,
            stores,
            method: Method::Password,
            email,
            password,
            token,
            two_step,
            busy: false,
            sso: false,
            error: None,
            note: None,
            _subscriptions: subscriptions,
        }
    }

    /// Empties the fields (after a sign-in, or for the next account).
    pub fn reset(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.clear(window, cx);
        self.busy = false;
        self.sso = false;
        self.error = None;
        self.note = None;
        cx.notify();
    }

    /// Empties the fields and what they last said.
    fn clear(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        for input in [&self.email, &self.password, &self.token] {
            input.update(cx, |i, cx| i.set_value("", window, cx));
        }
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
                Method::Token => forms::filled(&[&self.token], cx),
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
            Method::Token => {
                let token = forms::text(&self.token, cx);
                if token.is_empty() {
                    self.error = Some(l10n.desktop_sign_in_token_required());
                    forms::focus_invalid(&self.token.clone(), window, cx);
                    cx.notify();
                    return;
                }
                // The daemon refuses an API key, or a token too short to be
                // one, before it asks the server (the phone's form checks).
                futures::FutureExt::boxed(
                    rpc.call::<methods::AuthLoginWithApiKey>(&ApiKeyLogin { api_key: token }),
                )
            }
        };
        self.busy = true;
        let scope = self.scope.clone();
        cx.notify();
        cx.spawn_in(
            window,
            async move |this: WeakEntity<Self>, cx: &mut AsyncWindowContext| {
                let result = call.await;
                let _ = this.update_in(cx, |s, window, cx| {
                    if s.drop_if_moved_on(&scope, cx) {
                        return;
                    }
                    s.finish(result, window, cx)
                });
            },
        )
        .detach();
    }

    /// A sign-in answered after the form moved on to another account:
    /// nothing of it is shown or adopted here (true).
    fn drop_if_moved_on(&mut self, scope: &(Option<String>, bool), cx: &mut Context<Self>) -> bool {
        if &self.scope == scope {
            return false;
        }
        self.busy = false;
        self.sso = false;
        cx.notify();
        true
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
            // The password was right; the server asks for a second step,
            // which the page shows in place of the form.
            Ok(snapshot) if snapshot.two_step.is_some() => {
                self.stores
                    .session
                    .update(cx, |s, cx| s.adopt_auth(snapshot, cx));
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
            Method::Token => self.token.clone(),
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
        let scope = self.scope.clone();
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
                        // The account this form is for: the daemon refuses
                        // the capture once another one is in charge.
                        account: scope.0.clone(),
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
                // The browser flow can take minutes: what it captured is never
                // sent once the form has moved on to another account.
                let moved_on = this
                    .update(cx, |s, cx| s.drop_if_moved_on(&scope, cx))
                    .unwrap_or(true);
                if moved_on {
                    return;
                }
                let result = rpc.call::<methods::AuthCompleteExternal>(&completion).await;
                let _ = this.update_in(cx, |s, window, cx| {
                    if s.drop_if_moved_on(&scope, cx) {
                        return;
                    }
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
        // A second step in progress replaces the form.
        if self.two_step.read(cx).challenge(cx).is_some() {
            return div()
                .id("sign-in")
                .child(self.two_step.clone())
                .into_any_element();
        }
        self.form(window, cx).into_any_element()
    }
}

impl SignInView {
    fn form(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let l10n = cx.l10n().clone();
        let this = cx.entity().downgrade();
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
                Segment::new(l10n.jwt()),
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
                Method::Token => vec![
                    field(
                        l10n.auth_token_field_label(),
                        &self.token,
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
        let chip = server_chip(&self.stores, cx);
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
            // Where a token comes from, and that an API key won't do.
            .when(self.method == Method::Token, |d| {
                d.child(group_footer(l10n.token_hint(), cx))
            })
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

/// The active account's server, as a chip above the page's title: its name
/// and host (masked in `--shots`).
pub fn server_chip(stores: &Stores, cx: &App) -> AnyElement {
    let t = cx.conduit().clone();
    let r = t.roles;
    let m = t.metrics;
    let l10n = cx.l10n().clone();
    let (server_name, server_host) = {
        let accounts = stores.accounts.read(cx);
        accounts
            .active()
            .map(|a| {
                (
                    privacy::host(&a.connection.name, cx),
                    privacy::host(&host_of(&a.connection.url), cx),
                )
            })
            .unwrap_or_default()
    };
    div()
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
        )
        .into_any_element()
}

#[cfg(test)]
mod scope_tests {
    use gpui_kit::TestAppContext;

    use super::*;
    use crate::stores::accounts::tests::{account, list};
    use crate::stores::rpc::fake::FakeDaemon;

    #[gpui_kit::test]
    fn another_account_never_gets_the_last_ones_password(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        let scratch = std::env::temp_dir().join(format!("conduit-sign-in-{}", std::process::id()));
        let stores = cx.update(|cx| {
            crate::views::test_globals(cx);
            Stores::for_test(daemon.rpc(), &scratch, cx)
        });
        stores.accounts.update(cx, |a, cx| {
            a.adopt(
                list(vec![
                    account("a", "Avery", true, false),
                    account("b", "Blake", false, false),
                ]),
                cx,
            )
        });
        let s = stores.clone();
        let (view, vcx) = cx.add_window_view(move |window, cx| SignInView::new(s, window, cx));
        view.update_in(vcx, |v, window, cx| {
            v.email
                .update(cx, |i, cx| i.set_value("avery@example.org", window, cx));
            v.password
                .update(cx, |i, cx| i.set_value("synthetic-secret", window, cx));
            v.token
                .update(cx, |i, cx| i.set_value("synthetic-token", window, cx));
        });
        // Switched to B (through Settings, say).
        stores.accounts.update(vcx, |a, cx| {
            a.adopt(
                list(vec![
                    account("a", "Avery", false, false),
                    account("b", "Blake", true, false),
                ]),
                cx,
            )
        });
        vcx.run_until_parked();
        view.read_with(vcx, |v, cx| {
            for input in [&v.email, &v.password, &v.token] {
                assert_eq!(input.read(cx).value().as_ref(), "");
            }
        });
    }

    #[gpui_kit::test]
    fn a_sign_in_answered_after_another_account_is_dropped(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        let mut signed_in: AuthSnapshot = serde_json::from_value(serde_json::json!({
            "phase": "authenticated", "isAuthenticated": true, "hasToken": true
        }))
        .unwrap();
        signed_in.is_loading = false;
        daemon.returns::<methods::AuthLoginWithPassword>(signed_in);
        let held = daemon.hold::<methods::AuthLoginWithPassword>();
        let scratch =
            std::env::temp_dir().join(format!("conduit-sign-in-late-{}", std::process::id()));
        let stores = cx.update(|cx| {
            crate::views::test_globals(cx);
            Stores::for_test(daemon.rpc(), &scratch, cx)
        });
        let two = |active_a: bool| {
            list(vec![
                account("a", "Avery", active_a, false),
                account("b", "Blake", !active_a, false),
            ])
        };
        stores.accounts.update(cx, |a, cx| a.adopt(two(true), cx));
        let s = stores.clone();
        let (view, vcx) = cx.add_window_view(move |window, cx| SignInView::new(s, window, cx));
        view.update_in(vcx, |v, window, cx| {
            v.email
                .update(cx, |i, cx| i.set_value("avery@example.org", window, cx));
            v.password
                .update(cx, |i, cx| i.set_value("synthetic-secret", window, cx));
            v.submit(window, cx);
        });
        stores.accounts.update(vcx, |a, cx| a.adopt(two(false), cx));
        vcx.run_until_parked();
        held.release();
        vcx.run_until_parked();
        view.read_with(vcx, |v, _| assert!(!v.busy && v.error.is_none()));
        assert!(
            stores.session.read_with(vcx, |s, _| s.auth.is_none()),
            "A's answer was adopted for B"
        );
    }
}
