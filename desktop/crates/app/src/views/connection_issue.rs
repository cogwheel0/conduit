//! The phone's Connection Issue (`connection_issue_page.dart`), in the
//! setup window: the active account kept its session, but its server turns
//! it away. Most often a sign-in proxy in front of the server whose session
//! expired, which Sign In to Proxy Again renews in place (the proxy's page
//! in a browser window, `shell/sso.rs`, then `auth.renewProxy` into the same
//! account). Try Again checks the kept session again (`auth.retry`); Sign
//! Out leaves the account, as everywhere else.
//!
//! Nothing here signs out by itself: the account, its chats and its sign-in
//! stay until the user chooses.

use std::rc::Rc;

use conduit_components::views::kit::Button;
use conduit_components::views::onboarding::title_block;
use conduit_daemon::RpcError;
use conduit_protocol::{AuthSnapshot, ExternalAuthCompletion, NoParams, methods};
use gpui_kit::prelude::*;
use gpui_kit::{App, AsyncWindowContext, ClickEvent, Context, Role, WeakEntity, Window, div, px};

use crate::l10n::ActiveL10n as _;
use crate::shell::sso::{SsoOutcome, run_proxy_sso};
use crate::stores::Stores;
use crate::views::forms::{form_buttons, form_error, form_note};
use crate::views::sign_in::server_chip;

/// What the page is doing.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Busy {
    Idle,
    /// Try Again: the kept session is checked again.
    Retrying,
    /// Sign In to Proxy Again: the proxy's page, then the renewal.
    Renewing,
}

pub struct ConnectionIssueView {
    stores: Stores,
    pub busy: Busy,
    /// Why the last try didn't work, when it says more than the page.
    pub error: Option<String>,
}

impl ConnectionIssueView {
    pub fn new(stores: Stores, _: &mut Window, cx: &mut Context<Self>) -> Self {
        cx.observe(&stores.session, |_, _, cx| cx.notify()).detach();
        Self {
            stores,
            busy: Busy::Idle,
            error: None,
        }
    }

    /// The account's server is reached through a sign-in proxy whose
    /// session the account keeps.
    pub fn can_renew_proxy(&self, cx: &App) -> bool {
        self.stores
            .session
            .read(cx)
            .auth
            .as_ref()
            .is_some_and(|a| a.can_renew_proxy)
    }

    /// While a try runs, the page stays (the session reads as loading
    /// meanwhile, which alone would show "Opening your data").
    pub fn holds(&self) -> bool {
        self.busy != Busy::Idle
    }

    /// The account a try is for: an answer after another account's page
    /// took over is dropped ([`Self::moved_on`]).
    fn scope(&self, cx: &App) -> (Option<String>, bool) {
        crate::views::sign_in::sign_in_scope(self.stores.accounts.read(cx))
    }

    /// A try answered after the page moved on to another account: nothing
    /// of it is shown or adopted (true).
    fn moved_on(&mut self, scope: &(Option<String>, bool), cx: &mut Context<Self>) -> bool {
        if &self.scope(cx) == scope {
            return false;
        }
        self.busy = Busy::Idle;
        cx.notify();
        true
    }

    fn server(&self, cx: &App) -> Option<(String, String)> {
        let accounts = self.stores.accounts.read(cx);
        let a = accounts.active()?;
        Some((a.connection.name.clone(), a.connection.url.clone()))
    }

    /// Try Again.
    pub fn retry(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.busy != Busy::Idle {
            return;
        }
        self.busy = Busy::Retrying;
        self.error = None;
        cx.notify();
        let call = self
            .stores
            .connection
            .read(cx)
            .rpc()
            .call::<methods::AuthRetry>(&NoParams);
        let scope = self.scope(cx);
        cx.spawn_in(
            window,
            async move |this: WeakEntity<Self>, cx: &mut AsyncWindowContext| {
                let result = call.await;
                let _ = this.update(cx, |s, cx| {
                    if !s.moved_on(&scope, cx) {
                        s.settle(result, cx)
                    }
                });
            },
        )
        .detach();
    }

    /// Sign In to Proxy Again: the proxy's sign-in in a browser window, then
    /// its new session saved into this account.
    pub fn renew_proxy(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.busy != Busy::Idle {
            return;
        }
        let Some((name, url)) = self.server(cx) else {
            return;
        };
        let l10n = cx.l10n().clone();
        self.busy = Busy::Renewing;
        self.error = None;
        cx.notify();
        let rpc = self.stores.connection.read(cx).rpc();
        let scope = self.scope(cx);
        let outcome = run_proxy_sso(&url, l10n.desktop_sso_window_title(&name), cx);
        cx.spawn_in(
            window,
            async move |this: WeakEntity<Self>, cx: &mut AsyncWindowContext| {
                let completion = match outcome.await {
                    SsoOutcome::Captured {
                        origin,
                        cookies,
                        token,
                    } => ExternalAuthCompletion {
                        origin,
                        cookies,
                        token,
                    },
                    SsoOutcome::Cancelled => {
                        let _ = this.update(cx, |s, cx| {
                            s.busy = Busy::Idle;
                            cx.notify();
                        });
                        return;
                    }
                    _ => {
                        let _ = this.update(cx, |s, cx| {
                            s.busy = Busy::Idle;
                            s.error = Some(cx.l10n().desktop_proxy_sign_in_failed());
                            cx.notify();
                        });
                        return;
                    }
                };
                // The browser flow can take minutes: what it captured is
                // never sent once the page has moved on to another account.
                let moved_on = this
                    .update(cx, |s, cx| s.moved_on(&scope, cx))
                    .unwrap_or(true);
                if moved_on {
                    return;
                }
                let result = rpc.call::<methods::AuthRenewProxy>(&completion).await;
                let _ = this.update(cx, |s, cx| {
                    if !s.moved_on(&scope, cx) {
                        s.settle(result, cx)
                    }
                });
            },
        )
        .detach();
    }

    fn settle(&mut self, result: Result<AuthSnapshot, RpcError>, cx: &mut Context<Self>) {
        let renewing = self.busy == Busy::Renewing;
        self.busy = Busy::Idle;
        match result {
            Ok(snapshot) => {
                if !snapshot.is_authenticated && !snapshot.is_loading {
                    self.error = Some(if renewing {
                        cx.l10n().desktop_proxy_sign_in_failed()
                    } else {
                        cx.l10n().could_not_connect_generic()
                    });
                }
                self.stores
                    .session
                    .update(cx, |s, cx| s.adopt_auth(snapshot, cx));
            }
            Err(e) => {
                log::warn!("connection issue: {e}");
                self.error = Some(if renewing {
                    cx.l10n().desktop_proxy_sign_in_failed()
                } else {
                    cx.l10n().could_not_connect_generic()
                });
            }
        }
        cx.notify();
    }

    pub fn sign_out(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.busy != Busy::Idle {
            return;
        }
        crate::views::accounts::sign_out_active(&self.stores, window, cx);
    }

    /// A new issue starts without the last one's words.
    pub fn reset(&mut self, cx: &mut Context<Self>) {
        if self.busy == Busy::Idle {
            self.error = None;
            cx.notify();
        }
    }
}

impl Render for ConnectionIssueView {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let l10n = cx.l10n().clone();
        let this = cx.entity().downgrade();
        let handler = |f: fn(&mut ConnectionIssueView, &mut Window, &mut Context<Self>)| {
            let this = this.clone();
            Rc::new(move |_: &ClickEvent, window: &mut Window, cx: &mut App| {
                let _ = this.update(cx, |s, cx| f(s, window, cx));
            })
        };
        let proxy = self.can_renew_proxy(cx);
        let idle = self.busy == Busy::Idle;
        // What went wrong: the proxy's session, or the server turning the
        // account away; a failed try says why instead.
        let status = match (&self.error, self.busy) {
            (_, Busy::Retrying) | (_, Busy::Renewing) => {
                form_note(l10n.desktop_connecting(), false, cx).into_any_element()
            }
            (Some(e), _) => form_error("connection-issue-error", e.clone(), cx).into_any_element(),
            (None, _) => form_error(
                "connection-issue-status",
                if proxy {
                    l10n.desktop_proxy_session_ended()
                } else {
                    l10n.could_not_connect_generic()
                },
                cx,
            )
            .into_any_element(),
        };
        let mut buttons = vec![
            Button::new("connection-issue-sign-out", l10n.desktop_sign_out())
                .disabled(!idle)
                .on_click(handler(|s, window, cx| s.sign_out(window, cx)))
                .into_any_element(),
        ];
        let retry = Button::new(
            "connection-issue-retry",
            if self.busy == Busy::Retrying {
                l10n.desktop_connecting()
            } else {
                l10n.desktop_try_again()
            },
        )
        .disabled(!idle)
        .on_click(handler(|s, window, cx| s.retry(window, cx)));
        if proxy {
            buttons.push(retry.into_any_element());
            buttons.push(
                Button::new(
                    "connection-issue-renew",
                    if self.busy == Busy::Renewing {
                        l10n.desktop_signing_in()
                    } else {
                        l10n.proxy_auth_sign_in_again()
                    },
                )
                .primary()
                .disabled(!idle)
                .on_click(handler(|s, window, cx| s.renew_proxy(window, cx)))
                .into_any_element(),
            );
        } else {
            buttons.push(retry.primary().into_any_element());
        }
        div()
            .id("connection-issue")
            .role(Role::Form)
            .aria_label(l10n.connection_issue_title())
            .flex()
            .flex_col()
            .gap(px(18.))
            .child(
                div()
                    .flex()
                    .flex_col()
                    .items_center()
                    .gap(px(14.))
                    .child(server_chip(&self.stores, cx))
                    .child(title_block(
                        &l10n.connection_issue_title(),
                        &l10n.connection_issue_subtitle(),
                        false,
                        cx,
                    )),
            )
            .child(status)
            .child(form_buttons(buttons))
    }
}
