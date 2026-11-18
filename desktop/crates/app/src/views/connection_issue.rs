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
    /// The try running now, and the account it is for: another account in
    /// charge ends it here at once, and an answer to an older try changes
    /// nothing.
    try_id: u64,
    try_scope: Option<(Option<String>, bool)>,
    /// Why the last try didn't work, when it says more than the page.
    pub error: Option<String>,
    /// Tries that came back (Try Again, Sign In to Proxy Again). The status
    /// line is drawn under this number, so each outcome is a new live
    /// region and VoiceOver hears it, even the same words as the last one
    /// when no "Connecting…" frame was drawn between them (a refusal that
    /// comes back within a frame).
    pub tries: usize,
}

impl ConnectionIssueView {
    pub fn new(stores: Stores, _: &mut Window, cx: &mut Context<Self>) -> Self {
        cx.observe(&stores.session, |_, _, cx| cx.notify()).detach();
        cx.observe(&stores.accounts, |s: &mut Self, _, cx| s.follow_account(cx))
            .detach();
        Self {
            stores,
            busy: Busy::Idle,
            try_id: 0,
            try_scope: None,
            error: None,
            tries: 0,
        }
    }

    /// Starts a try for the account in charge; its answers carry the id.
    fn begin(&mut self, busy: Busy, cx: &mut Context<Self>) -> u64 {
        self.try_id += 1;
        self.try_scope = Some(self.scope(cx));
        self.busy = busy;
        self.error = None;
        cx.notify();
        self.try_id
    }

    /// Another account took over while a try ran: that try is not this
    /// account's, so the page is free for this one's at once.
    fn follow_account(&mut self, cx: &mut Context<Self>) {
        if self.busy == Busy::Idle || self.try_scope == Some(self.scope(cx)) {
            return;
        }
        self.try_id += 1;
        self.try_scope = None;
        self.busy = Busy::Idle;
        self.error = None;
        cx.notify();
    }

    /// An answer for try [id]: true when it is still the one running.
    fn answers(&self, id: u64) -> bool {
        self.try_id == id
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

    /// The account a try is for ([`Self::begin`]).
    fn scope(&self, cx: &App) -> (Option<String>, bool) {
        crate::views::sign_in::sign_in_scope(self.stores.accounts.read(cx))
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
        let id = self.begin(Busy::Retrying, cx);
        let call = self
            .stores
            .connection
            .read(cx)
            .rpc()
            .call::<methods::AuthRetry>(&NoParams);
        cx.spawn_in(
            window,
            async move |this: WeakEntity<Self>, cx: &mut AsyncWindowContext| {
                let result = call.await;
                let _ = this.update(cx, |s, cx| {
                    if s.answers(id) {
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
        let id = self.begin(Busy::Renewing, cx);
        // The account this window is for: the daemon refuses the capture
        // for any other.
        let account = self.scope(cx).0;
        let rpc = self.stores.connection.read(cx).rpc();
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
                        account,
                    },
                    SsoOutcome::Cancelled => {
                        let _ = this.update(cx, |s, cx| {
                            if s.answers(id) {
                                s.busy = Busy::Idle;
                                cx.notify();
                            }
                        });
                        return;
                    }
                    _ => {
                        let _ = this.update(cx, |s, cx| {
                            if s.answers(id) {
                                s.busy = Busy::Idle;
                                s.tries += 1;
                                s.error = Some(cx.l10n().desktop_proxy_sign_in_failed());
                                cx.notify();
                            }
                        });
                        return;
                    }
                };
                // The browser flow can take minutes: what it captured is
                // never sent once the page has moved on to another account.
                if !this.update(cx, |s, _| s.answers(id)).unwrap_or(false) {
                    return;
                }
                let result = rpc.call::<methods::AuthRenewProxy>(&completion).await;
                let _ = this.update(cx, |s, cx| {
                    if s.answers(id) {
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
        self.tries += 1;
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
            // Each try's outcome under its own id: a new live region, spoken
            // when it draws (see `tries`).
            .child(
                div()
                    .id(("connection-issue-outcome", self.tries))
                    .flex()
                    .flex_col()
                    .child(status),
            )
            .child(form_buttons(buttons))
    }
}

#[cfg(test)]
mod tests {
    use gpui_kit::TestAppContext;

    use super::*;
    use crate::stores::accounts::tests::{account, list};
    use crate::stores::rpc::fake::FakeDaemon;

    #[gpui_kit::test]
    fn another_account_gets_its_own_try_while_the_last_ones_is_out(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        let issue: AuthSnapshot = serde_json::from_value(serde_json::json!({
            "phase": "error", "isAuthenticated": false, "hasToken": true, "isLoading": false
        }))
        .unwrap();
        let signed_in: AuthSnapshot = serde_json::from_value(serde_json::json!({
            "phase": "authenticated", "isAuthenticated": true, "hasToken": true,
            "isLoading": false
        }))
        .unwrap();
        // A's server takes A's session; B's still turns B's away.
        daemon
            .once::<methods::AuthRetry>(Ok(signed_in))
            .returns::<methods::AuthRetry>(issue);
        let held = daemon.hold_one::<methods::AuthRetry>(0);
        let scratch =
            std::env::temp_dir().join(format!("conduit-connection-issue-{}", std::process::id()));
        let stores = cx.update(|cx| {
            crate::views::test_globals(cx);
            Stores::for_test(daemon.rpc(), &scratch, cx)
        });
        let two = |active_a: bool| {
            list(vec![
                account("a", "Avery", active_a, true),
                account("b", "Blake", !active_a, true),
            ])
        };
        stores.accounts.update(cx, |a, cx| a.adopt(two(true), cx));
        let s = stores.clone();
        let (view, vcx) =
            cx.add_window_view(move |window, cx| ConnectionIssueView::new(s, window, cx));
        view.update_in(vcx, |v, window, cx| v.retry(window, cx));
        assert_eq!(view.read_with(vcx, |v, _| v.busy), Busy::Retrying);
        // B takes over (another window switched) while A's try is out.
        stores.accounts.update(vcx, |a, cx| a.adopt(two(false), cx));
        vcx.run_until_parked();
        assert_eq!(
            view.read_with(vcx, |v, _| v.busy),
            Busy::Idle,
            "A's try still held B's page"
        );
        view.update_in(vcx, |v, window, cx| v.retry(window, cx));
        assert_eq!(view.read_with(vcx, |v, _| v.busy), Busy::Retrying);
        // A's answer lands: B's try is still the one running.
        held.release();
        vcx.run_until_parked();
        assert_eq!(daemon.calls::<methods::AuthRetry>().len(), 2);
        assert!(
            stores.session.read_with(vcx, |s, _| s
                .auth
                .as_ref()
                .is_some_and(|a| !a.is_authenticated)),
            "A's answer was adopted for B"
        );
    }
}
