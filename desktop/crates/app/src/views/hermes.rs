//! The Hermes Agent connection: `hermes.settings/saveSettings/test`, and for
//! a desktop gateway, `hermes.signIn` (native PKCE: the daemon asks the
//! window to open the gateway's page with `shell.openUrl`) and
//! `hermes.signOut`. Onboarding and Settings › Hermes share it.

use std::rc::Rc;

use conduit_components::views::kit::{Button, Segment, Segmented, Switch, grouped, setting_row};
use conduit_daemon::RpcError;
use conduit_protocol::{
    HermesSettings, HermesSettingsEdit, HermesSignInRequest, HermesTestResult, NoParams, methods,
};
use gpui_kit::component::input::{InputEvent, InputState};
use gpui_kit::prelude::*;
use gpui_kit::{
    App, AsyncWindowContext, ClickEvent, Context, Entity, Role, WeakEntity, Window, div, px,
};

use crate::l10n::{ActiveL10n as _, L10n};
use crate::stores::Stores;
use crate::views::forms::{
    self, field, form_buttons, form_error, form_group, form_note, form_row, normalize_url,
};
use crate::views::words;

/// `HermesSettings.mode`: the API server (with a key) or the desktop
/// gateway (with a sign-in).
pub const MODES: [&str; 2] = ["responses", "desktop"];

#[derive(Clone, Debug, PartialEq)]
pub enum HermesNote {
    Tested(HermesTestResult),
    Saved,
    SignInStarted,
}

pub struct HermesView {
    stores: Stores,
    pub onboarding: bool,
    pub saved: Option<HermesSettings>,
    pub mode: &'static str,
    pub base_url: Entity<InputState>,
    pub api_key: Entity<InputState>,
    pub profile: Entity<InputState>,
    pub self_signed: bool,
    pub busy: bool,
    pub error: Option<String>,
    pub note: Option<HermesNote>,
}

impl HermesView {
    pub fn new(
        stores: Stores,
        onboarding: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Self {
        let l10n = cx.l10n().clone();
        let base_url = forms::input("http://127.0.0.1:8642", false, window, cx);
        // The API server takes a key only when it was set up with one.
        let api_key = forms::input(l10n.desktop_optional(), true, window, cx);
        let profile = forms::input("default", false, window, cx);
        // Return is Save's (while it is on); typing may turn it on.
        for input in [&base_url, &api_key, &profile] {
            cx.subscribe_in(
                input,
                window,
                |this: &mut Self, _, e: &InputEvent, window, cx| match e {
                    InputEvent::PressEnter { .. } if this.can_save(cx) => this.save(window, cx),
                    InputEvent::Change => cx.notify(),
                    _ => {}
                },
            )
            .detach();
        }
        // Sign In waits for the connection in use to be known.
        cx.observe(&stores.hermes_admin, |_, _, cx| cx.notify())
            .detach();
        cx.observe(&stores.session, |this: &mut Self, session, cx| {
            let fresh = session.read(cx).hermes.clone();
            if fresh.is_some() && fresh != this.saved {
                this.saved = fresh;
                cx.notify();
            }
        })
        .detach();
        let mut this = Self {
            stores,
            onboarding,
            saved: None,
            mode: MODES[0],
            base_url,
            api_key,
            profile,
            self_signed: false,
            busy: false,
            error: None,
            note: None,
        };
        this.load(window, cx);
        this
    }

    /// Fills the form from `hermes.settings`.
    pub fn load(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let call = self
            .stores
            .connection
            .read(cx)
            .rpc()
            .call::<methods::HermesSettings>(&NoParams);
        cx.spawn_in(
            window,
            async move |this: WeakEntity<Self>, cx: &mut AsyncWindowContext| {
                let result = call.await;
                let _ = this.update_in(cx, |s, window, cx| {
                    if let Ok(saved) = result {
                        s.mode = if saved.mode == "desktop" {
                            MODES[1]
                        } else {
                            MODES[0]
                        };
                        s.self_signed = saved.allow_self_signed_certificates;
                        let (url, profile) =
                            (saved.base_url.clone(), saved.desktop_profile.clone());
                        s.base_url.update(cx, |i, cx| i.set_value(url, window, cx));
                        s.profile
                            .update(cx, |i, cx| i.set_value(profile, window, cx));
                        s.saved = Some(saved);
                    }
                    cx.notify();
                });
            },
        )
        .detach();
    }

    /// Whether Save (and Test) can go: not busy, and an address typed.
    pub fn can_save(&self, cx: &App) -> bool {
        !self.busy && forms::filled(&[&self.base_url], cx)
    }

    fn edit(&mut self, cx: &mut Context<Self>) -> Option<HermesSettingsEdit> {
        let l10n = cx.l10n().clone();
        let Some(base_url) = normalize_url(&forms::text(&self.base_url, cx)) else {
            self.error = Some(l10n.desktop_invalid_server_address());
            cx.notify();
            return None;
        };
        let key = forms::raw(&self.api_key, cx);
        let profile = forms::text(&self.profile, cx);
        Some(HermesSettingsEdit {
            enabled: true,
            base_url,
            mode: self.mode.to_string(),
            api_key: (!key.is_empty()).then_some(key),
            session_key: None,
            desktop_profile: if profile.is_empty() {
                "default".into()
            } else {
                profile
            },
            desktop_auth_kind: if self.mode == "desktop" {
                "nativePkce".into()
            } else {
                self.saved
                    .as_ref()
                    .map(|s| s.desktop_auth_kind.clone())
                    .unwrap_or_else(|| "legacyToken".into())
            },
            // Kept as saved: this form signs in natively.
            legacy_token: None,
            allow_self_signed_certificates: self.self_signed,
            // Onboarding's choice makes Hermes the backend the app is used
            // through (the core's preferred backend), as on a phone.
            onboarding: self.onboarding,
        })
    }

    fn run<T: Send + 'static>(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
        call: impl std::future::Future<Output = Result<T, RpcError>> + Send + 'static,
        done: impl FnOnce(&mut Self, Result<T, RpcError>, &L10n, &mut Window, &mut Context<Self>)
        + 'static,
    ) {
        self.busy = true;
        self.error = None;
        cx.notify();
        let session = self.stores.session.clone();
        let l10n = cx.l10n().clone();
        cx.spawn_in(
            window,
            async move |this: WeakEntity<Self>, cx: &mut AsyncWindowContext| {
                let result = call.await;
                session.update(cx, |s, cx| s.refresh(cx));
                let _ = this.update_in(cx, |s, window, cx| {
                    s.busy = false;
                    done(s, result, &l10n, window, cx);
                    cx.notify();
                });
            },
        )
        .detach();
    }

    /// After a failed Test or Save: the field to fix, its text selected (a
    /// refused key the key, anything else the address).
    fn focus_invalid(&mut self, error: Option<&RpcError>, window: &mut Window, cx: &mut App) {
        let field = match error {
            Some(e) if words::is_unauthorized(e) => &self.api_key,
            _ => &self.base_url,
        };
        forms::focus_invalid(&field.clone(), window, cx);
    }

    pub fn test(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(edit) = self.edit(cx) else {
            self.focus_invalid(None, window, cx);
            return;
        };
        let call = self
            .stores
            .connection
            .read(cx)
            .rpc()
            .call::<methods::HermesTest>(&edit);
        self.run(window, cx, call, |s, r, l10n, window, cx| match r {
            Ok(r) => s.note = Some(HermesNote::Tested(r)),
            Err(e) => {
                s.error = Some(words::connect_error(&e, l10n));
                s.focus_invalid(Some(&e), window, cx);
            }
        });
    }

    pub fn save(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(edit) = self.edit(cx) else {
            self.focus_invalid(None, window, cx);
            return;
        };
        let call = self
            .stores
            .connection
            .read(cx)
            .rpc()
            .call::<methods::HermesSaveSettings>(&edit);
        self.run(window, cx, call, |s, r, l10n, window, cx| match r {
            Ok(saved) => {
                s.saved = Some(saved);
                s.note = Some(HermesNote::Saved);
            }
            Err(e) => {
                s.error = Some(words::connect_error(&e, l10n));
                s.focus_invalid(Some(&e), window, cx);
            }
        });
    }

    /// Native PKCE: the gateway's page opens in the browser.
    /// For the connection in use as this window knows it: another
    /// window's switch meanwhile is refused, not signed in to. Until the
    /// window knows which connection is in use (its list is being read
    /// again after a change), nothing is sent.
    pub fn sign_in(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(connection) = self.stores.hermes_admin.read(cx).connection() else {
            return;
        };
        let connection = Some(connection);
        let call = self
            .stores
            .connection
            .read(cx)
            .rpc()
            .call::<methods::HermesSignIn>(&HermesSignInRequest { connection });
        self.note = Some(HermesNote::SignInStarted);
        self.run(window, cx, call, |s, r, l10n, _, _| match r {
            Ok(saved) => {
                s.saved = Some(saved);
                s.note = None;
            }
            Err(e) => {
                s.note = None;
                s.error = Some(match e.code.as_str() {
                    "rpc.unauthorized" => l10n.desktop_hermes_test_unauthorized(),
                    _ => words::connect_error(&e, l10n),
                })
            }
        });
    }

    pub fn sign_out(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let call = self
            .stores
            .connection
            .read(cx)
            .rpc()
            .call::<methods::HermesSignOut>(&NoParams);
        self.run(window, cx, call, |s, r, _, _, _| {
            if let Ok(saved) = r {
                s.saved = Some(saved);
            }
        });
    }
}

impl Render for HermesView {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let l10n = cx.l10n().clone();
        let this = cx.entity().downgrade();
        let act = |f: fn(&mut HermesView, &mut Window, &mut Context<HermesView>)| {
            let this = this.clone();
            Rc::new(move |_: &ClickEvent, window: &mut Window, cx: &mut App| {
                let _ = this.update(cx, |s, cx| f(s, window, cx));
            })
        };
        let desktop = self.mode == "desktop";
        let mode = Segmented::new(
            "hermes-mode",
            l10n.desktop_hermes_mode(),
            vec![
                Segment::new(l10n.desktop_hermes_mode_api()),
                Segment::new(l10n.hermes_desktop_gateway()),
            ],
            usize::from(desktop),
        )
        .on_select({
            let this = this.clone();
            Rc::new(move |i, _, cx| {
                let _ = this.update(cx, |s, cx| {
                    s.mode = MODES[i];
                    cx.notify();
                });
            })
        });
        let toggle = {
            let this = this.clone();
            Rc::new(move |_: &ClickEvent, _: &mut Window, cx: &mut App| {
                let _ = this.update(cx, |s, cx| {
                    s.self_signed = !s.self_signed;
                    cx.notify();
                });
            })
        };
        let saved = self.saved.clone().unwrap_or_default();
        let note = self.note.as_ref().map(|n| match n {
            HermesNote::Tested(r) if r.ok => (l10n.desktop_hermes_test_ok(), true),
            HermesNote::Tested(r) => (
                match r.reason.as_deref() {
                    Some("unauthorized") => l10n.desktop_hermes_test_unauthorized(),
                    _ => l10n.desktop_hermes_test_unreachable(),
                },
                false,
            ),
            HermesNote::Saved if desktop && !saved.desktop_signed_in => {
                (l10n.desktop_hermes_sign_in_to_finish(), false)
            }
            HermesNote::Saved => (l10n.saved(), true),
            HermesNote::SignInStarted => (l10n.desktop_hermes_signing_in(), false),
        });
        // Only when there is something to say: an empty line would add a
        // second gap above the buttons.
        let status = saved
            .usable
            .then(|| form_note(l10n.desktop_hermes_ready(), true, cx));
        // The connection type over its fields, in one group.
        let mut fields = vec![
            form_row(l10n.desktop_hermes_mode(), mode, cx).into_any_element(),
            field(
                l10n.desktop_server_address(),
                &self.base_url,
                None,
                None,
                window,
                cx,
            )
            .into_any_element(),
        ];
        if desktop {
            fields.push(
                field(
                    l10n.hermes_profile_label(),
                    &self.profile,
                    None,
                    None,
                    window,
                    cx,
                )
                .into_any_element(),
            );
        } else {
            fields.push(
                field(
                    l10n.desktop_api_key(),
                    &self.api_key,
                    saved
                        .has_api_key
                        .then(|| l10n.personal_connections_key_kept().into()),
                    None,
                    window,
                    cx,
                )
                .into_any_element(),
            );
        }
        let sign_in_row = desktop.then(|| {
            setting_row(
                l10n.desktop_sign_in_with_hermes(),
                Some(
                    if saved.desktop_signed_in {
                        l10n.desktop_mcp_signed_in()
                    } else {
                        l10n.desktop_mcp_not_signed_in()
                    }
                    .into(),
                ),
                if saved.desktop_signed_in {
                    Button::new("hermes-sign-out", l10n.desktop_sign_out_of_hermes())
                        .disabled(self.busy)
                        .on_click(act(|s, w, cx| s.sign_out(w, cx)))
                } else {
                    Button::new("hermes-sign-in", l10n.desktop_sign_in_with_hermes())
                        .disabled(
                            self.busy
                                || saved.base_url.is_empty()
                                || self.stores.hermes_admin.read(cx).connection().is_none(),
                        )
                        .on_click(act(|s, w, cx| s.sign_in(w, cx)))
                },
                cx,
            )
            .into_any_element()
        });
        div()
            .id("hermes-form")
            .role(Role::Form)
            .aria_label(l10n.desktop_hermes_agent())
            .flex()
            .flex_col()
            .gap(px(14.))
            .child(
                div()
                    .flex()
                    .flex_col()
                    .gap(px(6.))
                    .child(form_group(fields, cx))
                    // What the chosen connection type means, under it (both
                    // in the first run and in Settings).
                    .child(forms::group_footer(
                        if desktop {
                            l10n.desktop_hermes_mode_gateway_help()
                        } else {
                            l10n.desktop_hermes_mode_api_help()
                        },
                        cx,
                    )),
            )
            .child(grouped(
                [
                    Some(
                        setting_row(
                            l10n.desktop_allow_unverified_certificate(),
                            None,
                            Switch::new(
                                "hermes-self-signed",
                                l10n.desktop_allow_unverified_certificate(),
                                self.self_signed,
                            )
                            .on_click(toggle),
                            cx,
                        )
                        .into_any_element(),
                    ),
                    sign_in_row,
                ]
                .into_iter()
                .flatten()
                .collect(),
                cx,
            ))
            .children(status)
            .when_some(self.error.clone(), |d, e| {
                d.child(form_error("hermes-error", e, cx))
            })
            .when_some(note, |d, (text, ok)| d.child(form_note(text, ok, cx)))
            .child(form_buttons(vec![
                Button::new("hermes-test", l10n.desktop_test_connection())
                    .disabled(!self.can_save(cx))
                    .on_click(act(|s, w, cx| s.test(w, cx)))
                    .into_any_element(),
                // First run: one verb on every connection form ("Connect");
                // in Settings it saves an edit.
                Button::new(
                    "hermes-save",
                    match (self.busy, self.onboarding) {
                        (true, true) => l10n.desktop_connecting(),
                        (true, false) => l10n.desktop_saving(),
                        (false, true) => l10n.desktop_connect(),
                        (false, false) => l10n.save(),
                    },
                )
                .primary()
                .disabled(!self.can_save(cx))
                .on_click(act(|s, w, cx| s.save(w, cx)))
                .into_any_element(),
            ]))
    }
}

#[cfg(test)]
mod tests {
    use conduit_protocol::{HermesConnections, HermesSettings, methods};
    use gpui_kit::TestAppContext;
    use serde_json::json;

    use super::HermesView;
    use crate::stores::Stores;
    use crate::stores::rpc::fake::FakeDaemon;

    /// Until the window knows which connection is in use (the list read
    /// again after a change), Sign In sends nothing: a request without one
    /// would sign in to whichever connection another window put in use.
    #[gpui_kit::test]
    fn sign_in_waits_for_the_connection_in_use(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        daemon.returns::<methods::HermesSettings>(
            serde_json::from_value::<HermesSettings>(json!({
                "baseUrl": "http://127.0.0.1:20401", "mode": "desktop",
            }))
            .unwrap(),
        );
        let scratch =
            std::env::temp_dir().join(format!("conduit-hermes-signin-{}", std::process::id()));
        let stores = cx.update(|cx| {
            crate::views::test_globals(cx);
            Stores::for_test(daemon.rpc(), &scratch, cx)
        });
        let admin = stores.hermes_admin.clone();
        let (view, vcx) =
            cx.add_window_view(move |window, cx| HermesView::new(stores, true, window, cx));
        vcx.run_until_parked();
        view.update_in(vcx, |v, window, cx| v.sign_in(window, cx));
        vcx.run_until_parked();
        assert!(
            daemon.calls::<methods::HermesSignIn>().is_empty(),
            "Sign In went out naming no connection"
        );
        admin.update(vcx, |a, cx| {
            a.adopt_connections(
                serde_json::from_value::<HermesConnections>(json!({
                    "enabled": true, "activeId": "a", "connection": "0a1b2c3d:7",
                    "connections": [{"id": "a", "name": "Potting shed",
                        "baseUrl": "http://127.0.0.1:20401", "mode": "desktop", "active": true}],
                }))
                .unwrap(),
                cx,
            )
        });
        view.update_in(vcx, |v, window, cx| v.sign_in(window, cx));
        vcx.run_until_parked();
        let calls = daemon.calls::<methods::HermesSignIn>();
        assert_eq!(calls.len(), 1);
        assert_eq!(calls[0]["connection"], "0a1b2c3d:7");
    }
}
