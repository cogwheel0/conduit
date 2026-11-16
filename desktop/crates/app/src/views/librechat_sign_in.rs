//! Signing in to a LibreChat account, as the phone's LibreChat form does:
//!
//! 1. **Server**: the address, checked with `librechat.probe` (which also
//!    recognises an Open WebUI server and says so).
//! 2. **Sign in**: email (or LDAP user name) and password
//!    (`librechat.signIn`), and the server's single sign-on buttons, each
//!    run in a browser window ([`run_librechat_sso`]) and finished with
//!    `librechat.completeSso`.
//! 3. **Two-step verification**, when the account uses it: the
//!    authenticator code, or a recovery (backup) code (`librechat.verify`).
//!
//! Signed in, the daemon puts the account in charge of the chats (Open
//! WebUI is parked) and the window moves to chat. When an answer is still
//! being written in the account it replaces, the daemon asks first
//! (`blockedByActiveReply`): a sheet asks, then `accounts.switch` with
//! `force`.
//!
//! The form lives in onboarding, in Settings' Add Account sheet, and in the
//! setup window when the LibreChat account in charge needs to sign in again
//! (its session ended): then it starts at that server, saying so.

use std::collections::BTreeMap;
use std::rc::Rc;

use conduit_components::ActiveConduitTheme as _;
use conduit_components::assets::IconName;
use conduit_components::theme::with_alpha;
use conduit_components::views::kit::{Button, icon_tile};
use conduit_components::views::onboarding::{back_link, link, title_block};
use conduit_daemon::RpcError;
use conduit_protocol::{
    AccountChangeOutcome, AccountChangeResult, LibreChatProbe, LibreChatProbeOutcome,
    LibreChatServerDto, LibreChatSignIn, LibreChatSignInOutcome, LibreChatSignInResult,
    LibreChatSsoCompletion, LibreChatSsoStart, LibreChatVerify, methods,
};
use gpui_kit::component::input::{InputEvent, InputState};
use gpui_kit::prelude::*;
use gpui_kit::{
    App, AsyncWindowContext, ClickEvent, Context, Entity, EventEmitter, FontWeight, Role,
    SharedString, Subscription, Task, WeakEntity, Window, div, px,
};

use crate::l10n::{ActiveL10n as _, L10n};
use crate::shell::sheet::SheetSpec;
use crate::shell::sso::{SsoOutcome, run_librechat_sso};
use crate::stores::Stores;
use crate::stores::accounts::AccountChange;
use crate::views::forms::{self, field, field_hinted, form_buttons, form_error, form_group};
use crate::views::privacy;

/// Where the form stands.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Step {
    /// The server's address.
    Server,
    /// Its ways to sign in.
    Methods,
    /// A code from the authenticator app, or a recovery code.
    TwoFactor,
}

#[derive(Clone, Debug, PartialEq)]
pub enum LibreChatSignInEvent {
    /// Back from the first step (onboarding), or Cancel (a sheet).
    Back,
    /// Signed in; the account is in charge of the chats.
    SignedIn,
}

pub struct LibreChatSignInView {
    stores: Stores,
    pub step: Step,
    pub address: Entity<InputState>,
    pub email: Entity<InputState>,
    pub password: Entity<InputState>,
    pub code: Entity<InputState>,
    /// The server the probe found.
    pub server: Option<LibreChatServerDto>,
    flow_id: Option<String>,
    /// Two-step by a recovery (backup) code instead of the app's code.
    pub backup_code: bool,
    pub busy: bool,
    /// Single sign-on is running in its window.
    pub sso: bool,
    pub error: Option<String>,
    /// Drawn in Settings' Add Account sheet: a compact heading, Cancel.
    pub sheet: bool,
    /// The session of the account in charge ended: this names its server,
    /// and the form starts there.
    pub ended: Option<String>,
    /// Bumped each time the form starts over: an answer to an earlier
    /// start (a probe, a sign-in) is dropped, never applied to this one.
    round: u64,
    _subscriptions: Vec<Subscription>,
}

impl EventEmitter<LibreChatSignInEvent> for LibreChatSignInView {}

impl LibreChatSignInView {
    pub fn new(stores: Stores, window: &mut Window, cx: &mut Context<Self>) -> Self {
        let l10n = cx.l10n().clone();
        let address = forms::input(l10n.server_url_hint(), false, window, cx);
        let email = forms::input(l10n.desktop_email_placeholder(), false, window, cx);
        let password = forms::input(l10n.desktop_required_placeholder(), true, window, cx);
        let code = forms::input(l10n.desktop_required_placeholder(), false, window, cx);
        let on_input = |this: &mut Self,
                        _: &Entity<InputState>,
                        e: &InputEvent,
                        window: &mut Window,
                        cx: &mut Context<Self>| match e {
            InputEvent::PressEnter { .. } if this.ready(cx) => this.submit(window, cx),
            InputEvent::Change => {
                if this.error.take().is_some() {
                    cx.notify();
                }
                cx.notify();
            }
            _ => {}
        };
        let subscriptions = vec![
            cx.subscribe_in(&address, window, on_input),
            cx.subscribe_in(&email, window, on_input),
            cx.subscribe_in(&password, window, on_input),
            cx.subscribe_in(&code, window, on_input),
        ];
        Self {
            stores,
            step: Step::Server,
            address,
            email,
            password,
            code,
            server: None,
            flow_id: None,
            backup_code: false,
            busy: false,
            sso: false,
            error: None,
            sheet: false,
            ended: None,
            round: 0,
            _subscriptions: subscriptions,
        }
    }

    /// Starts again at the address, everything typed cleared.
    pub fn reset(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        for input in [&self.address, &self.email, &self.password, &self.code] {
            input.update(cx, |i, cx| i.set_value("", window, cx));
        }
        self.step = Step::Server;
        self.server = None;
        self.flow_id = None;
        self.backup_code = false;
        self.busy = false;
        self.sso = false;
        self.error = None;
        self.ended = None;
        self.round += 1;
        cx.notify();
    }

    /// Signing in again to an account whose session ended: straight to its
    /// server's ways to sign in, the address checked first.
    pub fn start_at(
        &mut self,
        base_url: &str,
        ended: Option<String>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.reset(window, cx);
        self.ended = ended;
        self.address
            .update(cx, |i, cx| i.set_value(base_url.to_string(), window, cx));
        self.probe(window, cx);
    }

    /// The field that takes the caret on this step.
    pub fn first_field(&self) -> Entity<InputState> {
        match self.step {
            Step::Server => self.address.clone(),
            Step::Methods => self.email.clone(),
            Step::TwoFactor => self.code.clone(),
        }
    }

    /// Whether the step's default button can go.
    pub fn ready(&self, cx: &App) -> bool {
        !self.busy
            && match self.step {
                Step::Server => forms::filled(&[&self.address], cx),
                Step::Methods => {
                    self.server.as_ref().is_some_and(|s| s.password_sign_in)
                        && forms::filled(&[&self.email, &self.password], cx)
                }
                Step::TwoFactor => forms::filled(&[&self.code], cx),
            }
    }

    pub fn submit(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        match self.step {
            Step::Server => self.probe(window, cx),
            Step::Methods => self.sign_in(window, cx),
            Step::TwoFactor => self.verify(window, cx),
        }
    }

    fn probe(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.busy {
            return;
        }
        let url = forms::text(&self.address, cx);
        let l10n = cx.l10n().clone();
        if url.is_empty() {
            self.error = Some(l10n.libre_chat_invalid_address());
            cx.notify();
            return;
        }
        self.busy = true;
        self.error = None;
        cx.notify();
        let round = self.round;
        let call = self
            .rpc(cx)
            .call::<methods::LibrechatProbe>(&LibreChatProbe { url: url.clone() });
        cx.spawn_in(
            window,
            async move |this: WeakEntity<Self>, cx: &mut AsyncWindowContext| {
                let result = call.await;
                let _ = this.update_in(cx, |s, window, cx| {
                    // The form started over meanwhile: this answer is not
                    // its.
                    if s.round != round {
                        return;
                    }
                    s.busy = false;
                    // The address changed while it was checked: the server
                    // found is not the one now typed. Continue checks again.
                    if forms::text(&s.address, cx) != url {
                        cx.notify();
                        return;
                    }
                    match result {
                        Ok(found) => match found.outcome {
                            LibreChatProbeOutcome::Found => {
                                s.server = found.server;
                                s.step = Step::Methods;
                                let first = s.first_field();
                                forms::focus_invalid(&first, window, cx);
                            }
                            other => s.error = Some(probe_error(other, &l10n)),
                        },
                        Err(e) => {
                            log::warn!("librechat.probe: {e}");
                            s.error = Some(l10n.libre_chat_unreachable());
                        }
                    }
                    cx.notify();
                });
            },
        )
        .detach();
    }

    fn sign_in(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(server) = self.server.clone() else {
            return;
        };
        if self.busy {
            return;
        }
        let email = forms::text(&self.email, cx);
        let password = forms::raw(&self.password, cx);
        if email.is_empty() || password.is_empty() {
            let l10n = cx.l10n().clone();
            self.error = Some(l10n.desktop_sign_in_fields_required());
            let empty = if email.is_empty() {
                self.email.clone()
            } else {
                self.password.clone()
            };
            forms::focus_invalid(&empty, window, cx);
            cx.notify();
            return;
        }
        let call = self
            .rpc(cx)
            .call::<methods::LibrechatSignIn>(&LibreChatSignIn {
                url: server.base_url,
                email,
                password,
                force: false,
            });
        self.run(call, window, cx);
    }

    fn verify(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(flow_id) = self.flow_id.clone() else {
            return;
        };
        if self.busy {
            return;
        }
        let code = forms::text(&self.code, cx);
        if code.is_empty() {
            return;
        }
        let call = self
            .rpc(cx)
            .call::<methods::LibrechatVerify>(&LibreChatVerify {
                flow_id,
                code,
                backup_code: self.backup_code,
                force: false,
            });
        self.run(call, window, cx);
    }

    /// Single sign-on with `provider`, in a browser window.
    pub fn start_sso(&mut self, provider: String, window: &mut Window, cx: &mut Context<Self>) {
        let Some(server) = self.server.clone() else {
            return;
        };
        if self.busy {
            return;
        }
        let l10n = cx.l10n().clone();
        // Google refuses sign-in inside an app's web view.
        if provider == "google" {
            self.error = Some(l10n.libre_chat_google_unsupported());
            cx.notify();
            return;
        }
        self.busy = true;
        self.sso = true;
        self.error = None;
        cx.notify();
        let rpc = self.rpc(cx);
        let plan = rpc.call::<methods::LibrechatSsoStart>(&LibreChatSsoStart {
            url: server.base_url.clone(),
            provider,
        });
        let title = l10n.desktop_sso_window_title(&server.title);
        let round = self.round;
        cx.spawn_in(
            window,
            async move |this: WeakEntity<Self>, cx: &mut AsyncWindowContext| {
                let plan = match plan.await {
                    Ok(plan) => plan,
                    Err(e) => {
                        log::warn!("librechat.ssoStart: {e}");
                        let _ = this.update(cx, |s, cx| {
                            if s.round != round {
                                return;
                            }
                            s.busy = false;
                            s.sso = false;
                            s.error = Some(l10n.libre_chat_sso_unfinished());
                            cx.notify();
                        });
                        return;
                    }
                };
                // The form started over meanwhile: no browser for the old one.
                if this.read_with(cx, |s, _| s.round != round).unwrap_or(true) {
                    return;
                }
                // The start these cookies belong to: conduitd completes only
                // the single sign-on it started last.
                let start_id = plan.start_id.clone();
                let Ok(outcome) = cx.update(|_, cx| run_librechat_sso(plan, title, cx)) else {
                    return;
                };
                let outcome = outcome.await;
                let cookies = match outcome {
                    SsoOutcome::Captured { cookies, .. } => cookies,
                    other => {
                        let _ = this.update(cx, |s, cx| {
                            if s.round != round {
                                return;
                            }
                            s.busy = false;
                            s.sso = false;
                            s.error = match other {
                                SsoOutcome::Cancelled => None,
                                SsoOutcome::TimedOut => Some(l10n.desktop_sso_timed_out()),
                                _ => Some(l10n.libre_chat_sso_unfinished()),
                            };
                            cx.notify();
                        });
                        return;
                    }
                };
                let _ = this.update_in(cx, |s, window, cx| {
                    s.complete_sso(round, server.base_url, cookies, start_id, window, cx)
                });
            },
        )
        .detach();
    }

    /// Single sign-on in form round `round` left `cookies`: conduitd makes
    /// them the account's session and puts it in charge.
    fn complete_sso(
        &mut self,
        round: u64,
        url: String,
        cookies: BTreeMap<String, String>,
        start_id: Option<String>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        // The form started over (another account's sign-in began): the old
        // round's cookies would put its account in charge again.
        if self.round != round {
            return;
        }
        let call = self
            .rpc(cx)
            .call::<methods::LibrechatCompleteSso>(&LibreChatSsoCompletion {
                url,
                cookies,
                force: false,
                start_id,
            });
        cx.spawn_in(
            window,
            async move |this: WeakEntity<Self>, cx: &mut AsyncWindowContext| {
                let result = call.await;
                let _ = this.update_in(cx, |s, window, cx| {
                    if s.round == round {
                        s.finish(result, window, cx)
                    }
                });
            },
        )
        .detach();
    }

    fn run(
        &mut self,
        call: impl std::future::Future<Output = Result<LibreChatSignInResult, RpcError>> + 'static,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.busy = true;
        self.error = None;
        cx.notify();
        let round = self.round;
        cx.spawn_in(
            window,
            async move |this: WeakEntity<Self>, cx: &mut AsyncWindowContext| {
                let result = call.await;
                let _ = this.update_in(cx, |s, window, cx| {
                    if s.round == round {
                        s.finish(result, window, cx)
                    }
                });
            },
        )
        .detach();
    }

    fn finish(
        &mut self,
        result: Result<LibreChatSignInResult, RpcError>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let l10n = cx.l10n().clone();
        self.busy = false;
        self.sso = false;
        let result = match result {
            Ok(result) => result,
            Err(e) => {
                log::warn!("librechat sign-in: {e}");
                self.error = Some(l10n.error_message());
                cx.notify();
                return;
            }
        };
        use LibreChatSignInOutcome as O;
        match result.outcome {
            O::SignedIn => self.signed_in(cx),
            O::TwoFactorRequired => {
                self.flow_id = result.flow_id;
                self.step = Step::TwoFactor;
                self.backup_code = false;
                self.code.update(cx, |i, cx| i.set_value("", window, cx));
                let code = self.code.clone();
                forms::focus_invalid(&code, window, cx);
            }
            O::BlockedByActiveReply => {
                // Saved, but an answer is still being written in the
                // account it replaces: ask, as switching does.
                if let Some(id) = result.account_id {
                    self.ask_to_switch(id, window, cx);
                }
            }
            O::InvalidCode => {
                self.error = Some(l10n.two_step_invalid_code());
                let code = self.code.clone();
                forms::focus_invalid(&code, window, cx);
            }
            O::Expired => {
                // The code came too late: the password again.
                self.step = Step::Methods;
                self.flow_id = None;
                self.error = Some(l10n.sign_in_two_step_verification_required());
            }
            O::Rejected => {
                self.error = Some(
                    result
                        .server_message
                        .filter(|m| !m.trim().is_empty())
                        .unwrap_or_else(|| l10n.desktop_sign_in_failed()),
                );
                let field = if self.step == Step::TwoFactor {
                    self.code.clone()
                } else {
                    self.password.clone()
                };
                forms::focus_invalid(&field, window, cx);
            }
            O::Unreachable => self.error = Some(l10n.libre_chat_unreachable()),
            O::SsoUnfinished => self.error = Some(l10n.libre_chat_sso_unfinished()),
            O::Failed | O::Unknown => self.error = Some(l10n.error_message()),
        }
        cx.notify();
    }

    fn signed_in(&mut self, cx: &mut Context<Self>) {
        self.stores.accounts.update(cx, |a, cx| a.refresh(cx));
        self.stores.session.update(cx, |s, cx| s.refresh(cx));
        cx.emit(LibreChatSignInEvent::SignedIn);
    }

    /// Asks before stopping the answer still being written, then switches
    /// to the account signed in to: only while the account it was asked
    /// over is still in charge (the question closes when another takes
    /// charge) and the form has not started over.
    fn ask_to_switch(&mut self, account_id: String, window: &mut Window, cx: &mut Context<Self>) {
        let l10n = cx.l10n().clone();
        let spec = SheetSpec::new(
            l10n.desktop_reply_in_progress(),
            l10n.accounts_switch_stops_reply(),
            l10n.desktop_switch_anyway(),
            l10n.cancel(),
        );
        let asked_under = self.stores.accounts.read(cx).scope_key();
        let asked_over = self.stores.accounts.read(cx).in_charge_id();
        let ask = crate::views::sheet::ask_for_account(&self.stores, window, spec, cx);
        let stores = self.stores.clone();
        let round = self.round;
        cx.spawn_in(
            window,
            async move |this: WeakEntity<Self>, cx: &mut AsyncWindowContext| {
                if !ask.await || this.read_with(cx, |s, _| s.round != round).unwrap_or(true) {
                    return;
                }
                // The answer is read some time after the question closed:
                // another account may have taken charge since.
                let Ok(Some(task)) = cx.update(|_, cx| {
                    switch_while_in_charge(&stores, &asked_under, asked_over, account_id, cx)
                }) else {
                    return;
                };
                if let Ok(result) = task.await
                    && result.outcome != AccountChangeOutcome::BlockedByActiveReply
                {
                    // The switch stands; the form tells it signed in only
                    // when it has not started over meanwhile.
                    let _ = this.update(cx, |s, cx| {
                        if s.round == round {
                            s.signed_in(cx);
                        } else {
                            s.stores.accounts.update(cx, |a, cx| a.refresh(cx));
                            s.stores.session.update(cx, |s, cx| s.refresh(cx));
                        }
                    });
                }
            },
        )
        .detach();
    }

    /// Back a step: from the code to the ways to sign in, from those to the
    /// address; from the address, out of the form.
    pub fn back(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.busy {
            return;
        }
        self.error = None;
        match self.step {
            Step::TwoFactor => {
                self.flow_id = None;
                self.code.update(cx, |i, cx| i.set_value("", window, cx));
                self.step = Step::Methods;
            }
            Step::Methods => {
                // What was typed for this server is not sent to the next.
                for input in [&self.email, &self.password] {
                    input.update(cx, |i, cx| i.set_value("", window, cx));
                }
                self.server = None;
                self.ended = None;
                self.step = Step::Server;
            }
            Step::Server => cx.emit(LibreChatSignInEvent::Back),
        }
        cx.notify();
    }

    pub fn toggle_backup_code(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.backup_code = !self.backup_code;
        self.error = None;
        self.code.update(cx, |i, cx| i.set_value("", window, cx));
        cx.notify();
    }

    fn rpc(&self, cx: &App) -> crate::stores::rpc::Rpc {
        self.stores.connection.read(cx).rpc()
    }
}

/// Why an address was not taken.
pub fn probe_error(outcome: LibreChatProbeOutcome, l10n: &L10n) -> String {
    match outcome {
        LibreChatProbeOutcome::InvalidAddress => l10n.libre_chat_invalid_address(),
        LibreChatProbeOutcome::NotLibreChat => l10n.libre_chat_not_libre_chat(),
        LibreChatProbeOutcome::OpenWebUi => l10n.libre_chat_is_open_web_ui(),
        _ => l10n.libre_chat_unreachable(),
    }
}

/// An SSO provider's button label: the admin's name for it, else the
/// provider's own.
pub fn provider_name(kind: &str, label: Option<&str>) -> String {
    if let Some(label) = label.filter(|l| !l.trim().is_empty()) {
        return label.to_string();
    }
    match kind {
        "openid" => "OpenID".into(),
        "github" => "GitHub".into(),
        "google" => "Google".into(),
        "facebook" => "Facebook".into(),
        "discord" => "Discord".into(),
        "saml" => "SAML".into(),
        "apple" => "Apple".into(),
        other => other.to_string(),
    }
}

impl Render for LibreChatSignInView {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let l10n = cx.l10n().clone();
        let t = cx.conduit().clone();
        let r = t.roles;
        let m = t.metrics;
        let this = cx.entity().downgrade();
        let handler = |f: fn(&mut LibreChatSignInView, &mut Window, &mut Context<Self>)| {
            let this = this.clone();
            Rc::new(move |_: &ClickEvent, window: &mut Window, cx: &mut App| {
                let _ = this.update(cx, |s, cx| f(s, window, cx));
            })
        };
        // The step's title, as the phone titles the page: LibreChat for the
        // address, Sign In after it.
        let (title, subtitle) = match self.step {
            Step::Server => (
                if self.sheet {
                    l10n.libre_chat_add_account()
                } else {
                    l10n.libre_chat_title()
                },
                l10n.libre_chat_add_account_message(),
            ),
            Step::Methods => (
                l10n.desktop_sign_in(),
                self.ended
                    .as_deref()
                    .map(|server| l10n.libre_chat_session_ended(server))
                    .unwrap_or_else(|| l10n.desktop_libre_chat_sign_in_subtitle()),
            ),
            Step::TwoFactor => (
                l10n.two_step_verify_title(),
                if self.backup_code {
                    l10n.two_step_recovery_code_description()
                } else {
                    l10n.two_step_verify_description()
                },
            ),
        };
        let heading = if self.sheet {
            div()
                .flex()
                .flex_col()
                .gap(px(4.))
                .child(conduit_components::views::kit::heading(
                    "librechat-title",
                    title.clone(),
                    1,
                    m.control + 3.,
                    FontWeight::SEMIBOLD,
                    r.text,
                ))
                .child(
                    div()
                        .text_size(px(m.control))
                        .text_color(r.text_subtle)
                        .child(subtitle.clone()),
                )
                .into_any_element()
        } else {
            title_block(&title, &subtitle, false, cx).into_any_element()
        };
        let back_label: SharedString = match self.step {
            Step::Server if self.sheet => l10n.cancel().into(),
            Step::Server => l10n.back().into(),
            Step::Methods => l10n.libre_chat_change_server().into(),
            Step::TwoFactor => l10n.two_step_back_to_sign_in().into(),
        };
        let back = handler(|s, window, cx| s.back(window, cx));
        let submit = handler(|s, window, cx| s.submit(window, cx));
        let mut body = div().flex().flex_col().gap(px(18.));
        // A sheet cancels from its buttons; a page steps back from the top.
        if !(self.sheet && self.step == Step::Server) {
            body = body.child(back_link(back_label.clone(), Some(back.clone()), cx));
        }
        if let (Some(server), true) = (self.server.as_ref(), self.step != Step::Server) {
            body = body.child(
                div()
                    .flex()
                    .justify_center()
                    .child(server_chip(server, &l10n, cx)),
            );
        }
        body = body.child(heading);
        let primary_label = |busy: bool, idle: String| -> String {
            if busy {
                l10n.desktop_signing_in()
            } else {
                idle
            }
        };
        match self.step {
            Step::Server => {
                body = body.child(form_group(
                    vec![
                        field(
                            l10n.desktop_server_address(),
                            &self.address,
                            Some(l10n.desktop_server_url_help().into()),
                            None,
                            window,
                            cx,
                        )
                        .into_any_element(),
                    ],
                    cx,
                ));
            }
            Step::Methods => {
                let server = self.server.clone().unwrap_or(LibreChatServerDto {
                    base_url: String::new(),
                    title: String::new(),
                    password_sign_in: false,
                    ldap: false,
                    ldap_uses_username: false,
                    sso_providers: Vec::new(),
                });
                if server.password_sign_in {
                    let ldap = server.ldap && server.ldap_uses_username;
                    body = body.child(form_group(
                        vec![
                            field_hinted(
                                if ldap {
                                    l10n.ldap_username()
                                } else {
                                    l10n.email_label()
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
                        cx,
                    ));
                } else {
                    body = body.child(
                        div()
                            .text_size(px(m.control))
                            .text_color(r.text_subtle)
                            .child(l10n.libre_chat_password_sign_in_off()),
                    );
                }
                if !server.sso_providers.is_empty() {
                    let mut buttons = div()
                        .id("librechat-sso")
                        .role(Role::Group)
                        .aria_label(SharedString::from(l10n.sso_description()))
                        .flex()
                        .flex_col()
                        .gap(px(8.));
                    for (i, provider) in server.sso_providers.iter().enumerate() {
                        let name = provider_name(&provider.kind, provider.label.as_deref());
                        let kind = provider.kind.clone();
                        let this = this.clone();
                        buttons = buttons.child(
                            Button::new(
                                gpui_kit::ElementId::NamedInteger("librechat-sso".into(), i as u64),
                                if self.sso {
                                    l10n.desktop_signing_in()
                                } else {
                                    l10n.continue_with_provider(&name)
                                },
                            )
                            .full_width()
                            .disabled(self.busy)
                            .on_click(Rc::new(
                                move |_: &ClickEvent, window: &mut Window, cx: &mut App| {
                                    let kind = kind.clone();
                                    let _ = this.update(cx, |s, cx| s.start_sso(kind, window, cx));
                                },
                            )),
                        );
                    }
                    body = body.child(buttons);
                }
            }
            Step::TwoFactor => {
                body = body
                    .child(form_group(
                        vec![
                            field(
                                if self.backup_code {
                                    l10n.two_step_recovery_code_label()
                                } else {
                                    l10n.two_step_code_label()
                                },
                                &self.code,
                                None,
                                None,
                                window,
                                cx,
                            )
                            .into_any_element(),
                        ],
                        cx,
                    ))
                    .child(div().flex().justify_center().child(link(
                        "librechat-backup-code",
                        SharedString::from(if self.backup_code {
                            l10n.two_step_use_authenticator_code()
                        } else {
                            l10n.two_step_use_recovery_code()
                        }),
                        Some(handler(|s, window, cx| s.toggle_backup_code(window, cx))),
                        cx,
                    )));
            }
        }
        if let Some(error) = self.error.clone() {
            body = body.child(form_error("librechat-error", error, cx));
        }
        // A session that ended: another saved account may still be signed
        // in, and switching to it needs no sign-in here.
        if self.ended.is_some() && self.step == Step::Methods {
            body = body.child(div().flex().justify_center().child(link(
                "librechat-manage-accounts",
                SharedString::from(l10n.accounts_manage()),
                Some(Rc::new(|_: &ClickEvent, _: &mut Window, cx: &mut App| {
                    crate::open_settings(Some(crate::views::settings::Tab::Accounts), cx)
                })),
                cx,
            )));
        }
        let (show_primary, primary_text) = match self.step {
            Step::Server => (
                true,
                if self.busy {
                    l10n.connecting()
                } else {
                    l10n.continue_button()
                },
            ),
            Step::Methods => (
                self.server.as_ref().is_some_and(|s| s.password_sign_in),
                primary_label(self.busy && !self.sso, l10n.desktop_sign_in()),
            ),
            Step::TwoFactor => (true, primary_label(self.busy, l10n.desktop_sign_in())),
        };
        let buttons: Vec<gpui_kit::AnyElement> = [
            (self.sheet && self.step == Step::Server).then(|| {
                Button::new("librechat-cancel", back_label)
                    .on_click(back)
                    .into_any_element()
            }),
            show_primary.then(|| {
                Button::new("librechat-continue", primary_text)
                    .primary()
                    .disabled(!self.ready(cx))
                    .on_click(submit)
                    .into_any_element()
            }),
        ]
        .into_iter()
        .flatten()
        .collect();
        div()
            .id("librechat-sign-in")
            .role(Role::Form)
            .aria_label(SharedString::from(title))
            .child(body.child(form_buttons(buttons)))
    }
}

/// The server's chip: its name and host, over the sign-in steps.
fn server_chip(
    server: &LibreChatServerDto,
    l10n: &L10n,
    cx: &App,
) -> gpui_kit::Stateful<gpui_kit::Div> {
    let t = cx.conduit().clone();
    let r = t.roles;
    let m = t.metrics;
    let name = privacy::host(&server.title, cx);
    let host = privacy::host(&forms::host_of(&server.base_url), cx);
    div()
        .id("librechat-server-chip")
        .role(Role::Group)
        .aria_label(l10n.desktop_server_chip_label(&name, &host))
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
            IconName::MessagesSquare,
            20.,
            with_alpha(r.text, if t.dark { 0.14 } else { 0.07 }),
            r.text_subtle,
            10.,
        ))
        .child(div().text_size(px(m.small)).text_color(r.text).child(name))
        .child(
            div()
                .text_size(px(m.small))
                .text_color(r.text_subtle)
                .child(host),
        )
}

/// The forced switch to `account_id` (it stops the answer being written),
/// sent only while the account in charge is still `asked_under`, the one
/// the question was asked over: checked here, with no wait between the
/// check and the call, and by conduitd against `asked_over` (that
/// account's id), since this list can lag an account change.
fn switch_while_in_charge(
    stores: &Stores,
    asked_under: &Option<String>,
    asked_over: Option<String>,
    account_id: String,
    cx: &mut App,
) -> Option<Task<Result<AccountChangeResult, RpcError>>> {
    // No account recorded (the list was not there): nothing is sent.
    asked_over.as_ref()?;
    stores.accounts.update(cx, |a, cx| {
        (a.scope_key() == *asked_under).then(|| {
            a.change_asked_over(AccountChange::Switch { account_id }, true, asked_over, cx)
        })
    })
}

#[cfg(test)]
mod tests {
    use gpui_kit::TestAppContext;

    use super::*;
    use crate::stores::rpc::fake::FakeDaemon;

    /// Single sign-on finished for a form that has started over (another
    /// account's sign-in began meanwhile) completes nothing: conduitd would
    /// put the old account in charge again.
    #[gpui_kit::test]
    fn an_obsolete_sso_round_completes_nothing(cx: &mut TestAppContext) {
        let (daemon, stores, vcx) = crate::views::sheet::bench::bench(cx);
        let view = vcx
            .update(|window, cx| cx.new(|cx| LibreChatSignInView::new(stores.clone(), window, cx)));
        let round = view.read_with(vcx, |v, _| v.round);
        view.update_in(vcx, |v, window, cx| v.reset(window, cx));
        let cookies = BTreeMap::from([("refreshToken".to_string(), "rt-old".to_string())]);
        view.update_in(vcx, |v, window, cx| {
            v.complete_sso(
                round,
                "https://harbour.example.org".into(),
                cookies,
                Some("sso-start-1".into()),
                window,
                cx,
            )
        });
        vcx.run_until_parked();
        assert!(
            daemon.calls::<methods::LibrechatCompleteSso>().is_empty(),
            "an obsolete single sign-on was completed"
        );
    }

    /// Switch Anyway, answered after another account took charge, switches
    /// to nothing: the forced switch would stop that account's reply.
    #[gpui_kit::test]
    fn a_stale_switch_question_switches_nothing(cx: &mut TestAppContext) {
        use crate::views::sheet::bench::{bench, switch_account};
        let (daemon, stores, vcx) = bench(cx);
        vcx.update(|_, cx| cx.set_global(crate::shell::sheet::AutoAnswer(Some(true))));
        let view = vcx
            .update(|window, cx| cx.new(|cx| LibreChatSignInView::new(stores.clone(), window, cx)));
        let blocked: LibreChatSignInResult = serde_json::from_value(serde_json::json!({
            "outcome": "blockedByActiveReply",
            "accountId": "lc-harbour",
        }))
        .unwrap();
        view.update_in(vcx, |v, window, cx| v.finish(Ok(blocked), window, cx));
        switch_account(&stores, vcx);
        assert!(
            daemon.calls::<methods::AccountsSwitch>().is_empty(),
            "the stale question switched accounts"
        );
    }

    /// Switch Anyway read after another account took charge (the question
    /// had closed with a yes) sends no forced switch: it would stop the
    /// new account's reply without asking.
    #[gpui_kit::test]
    fn a_yes_read_after_another_account_took_charge_switches_nothing(cx: &mut TestAppContext) {
        use crate::views::sheet::bench::{bench, switch_account};
        let (daemon, stores, vcx) = bench(cx);
        let asked_under = vcx.update(|_, cx| stores.accounts.read(cx).scope_key());
        let asked_over = vcx.update(|_, cx| stores.accounts.read(cx).in_charge_id());
        switch_account(&stores, vcx);
        let sent = vcx.update(|_, cx| {
            switch_while_in_charge(&stores, &asked_under, asked_over, "lc-harbour".into(), cx)
                .is_some()
        });
        vcx.run_until_parked();
        assert!(!sent, "a switch was sent for the account before");
        assert!(
            daemon.calls::<methods::AccountsSwitch>().is_empty(),
            "the forced switch went out under another account"
        );
        let now = vcx.update(|_, cx| stores.accounts.read(cx).scope_key());
        let over = vcx.update(|_, cx| stores.accounts.read(cx).in_charge_id());
        assert!(over.is_some());
        // No account recorded when the question opened (the list was not
        // there): nothing is sent, whatever the list says now.
        let sent = vcx.update(|_, cx| {
            switch_while_in_charge(&stores, &now, None, "lc-harbour".into(), cx).is_some()
        });
        assert!(
            !sent,
            "a forced switch went out with no account it was asked over"
        );
        let sent = vcx.update(|_, cx| {
            switch_while_in_charge(&stores, &now, over.clone(), "lc-harbour".into(), cx).is_some()
        });
        assert!(sent, "the account still in charge can switch");
        vcx.run_until_parked();
        let calls = daemon.calls::<methods::AccountsSwitch>();
        assert_eq!(calls.len(), 1);
        assert_eq!(
            calls[0]["askedOver"].as_str(),
            over.as_deref(),
            "conduitd is told which account the question was asked over"
        );
    }

    /// Switch Anyway whose switch lands after the form started over tells
    /// that newer form nothing: the switch stands, the form is not done.
    #[gpui_kit::test]
    fn a_switch_landing_after_the_form_started_over_signs_nothing_in(cx: &mut TestAppContext) {
        let (daemon, stores, vcx) = crate::views::sheet::bench::bench(cx);
        vcx.update(|_, cx| cx.set_global(crate::shell::sheet::AutoAnswer(Some(true))));
        daemon.returns::<methods::AccountsSwitch>(
            serde_json::from_value::<AccountChangeResult>(serde_json::json!({
                "outcome": "done",
                "accounts": {"accounts": []},
            }))
            .unwrap(),
        );
        let held = daemon.hold::<methods::AccountsSwitch>();
        let view = vcx
            .update(|window, cx| cx.new(|cx| LibreChatSignInView::new(stores.clone(), window, cx)));
        let signed_in = std::rc::Rc::new(std::cell::Cell::new(false));
        let seen = signed_in.clone();
        let _watch = vcx.update(|_, cx| {
            cx.subscribe(&view, move |_, e: &LibreChatSignInEvent, _| {
                if matches!(e, LibreChatSignInEvent::SignedIn) {
                    seen.set(true);
                }
            })
        });
        let blocked: LibreChatSignInResult = serde_json::from_value(serde_json::json!({
            "outcome": "blockedByActiveReply",
            "accountId": "lc-harbour",
        }))
        .unwrap();
        view.update_in(vcx, |v, window, cx| v.finish(Ok(blocked), window, cx));
        vcx.run_until_parked();
        assert_eq!(daemon.calls::<methods::AccountsSwitch>().len(), 1);
        view.update_in(vcx, |v, window, cx| v.reset(window, cx));
        held.release();
        vcx.run_until_parked();
        assert!(!signed_in.get(), "the newer form was told it signed in");
    }

    /// A probe of the last address, answered after the form started over    /// A probe of the last address, answered after the form started over
    /// at another, never puts its server under the new address: the
    /// password goes only to the server the form now shows.
    #[gpui_kit::test]
    fn an_earlier_probe_never_replaces_the_server_signed_in_to(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        daemon.on::<methods::LibrechatProbe>(|params| {
            let url = params["url"].as_str().unwrap_or_default().to_string();
            Ok(
                serde_json::to_value(conduit_protocol::LibreChatProbeResult {
                    outcome: LibreChatProbeOutcome::Found,
                    server: Some(LibreChatServerDto {
                        base_url: url,
                        title: "Harbour".into(),
                        password_sign_in: true,
                        ldap: false,
                        ldap_uses_username: false,
                        sso_providers: vec![],
                    }),
                })
                .unwrap(),
            )
        });
        let held = daemon.hold_one::<methods::LibrechatProbe>(0);
        let scratch = std::env::temp_dir().join(format!("conduit-lcsign-{}", std::process::id()));
        let stores = cx.update(|cx| {
            crate::views::test_globals(cx);
            Stores::for_test(daemon.rpc(), &scratch, cx)
        });
        let (view, vcx) =
            cx.add_window_view(move |window, cx| LibreChatSignInView::new(stores, window, cx));
        view.update_in(vcx, |v, window, cx| {
            v.start_at("https://old.example.org", None, window, cx)
        });
        vcx.run_until_parked();
        view.update_in(vcx, |v, window, cx| {
            v.start_at("https://new.example.org", None, window, cx)
        });
        vcx.run_until_parked();
        held.release();
        vcx.run_until_parked();
        view.read_with(vcx, |v, _| {
            assert_eq!(
                v.server.as_ref().map(|s| s.base_url.as_str()),
                Some("https://new.example.org"),
                "the form signs in to the address it started over from"
            );
        });

        // The address changes while it is checked: the server found is not
        // the one now typed, so the form stays at the address.
        let held = daemon.hold::<methods::LibrechatProbe>();
        view.update_in(vcx, |v, window, cx| {
            v.reset(window, cx);
            v.address.update(cx, |i, cx| {
                i.set_value("https://typed.example.org", window, cx)
            });
            v.submit(window, cx);
            v.address.update(cx, |i, cx| {
                i.set_value("https://other.example.org", window, cx)
            });
        });
        held.release();
        vcx.run_until_parked();
        view.read_with(vcx, |v, _| {
            assert!(v.server.is_none(), "the form took the address typed before");
            assert!(matches!(v.step, Step::Server) && !v.busy);
        });
    }

    #[test]
    fn providers_are_named_by_the_admin_first() {
        assert_eq!(provider_name("openid", Some("Harbour ID")), "Harbour ID");
        assert_eq!(provider_name("openid", Some("  ")), "OpenID");
        assert_eq!(provider_name("github", None), "GitHub");
        assert_eq!(provider_name("custom", None), "custom");
    }
}
