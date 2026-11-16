//! Add MCP Server and Edit MCP Server: a Streamable HTTP endpoint whose
//! tools direct models may call, in a sheet on the Settings window, as
//! mobile's MCP server editor.
//!
//! * The server: on or off, its name, its endpoint, and how the app signs
//!   in: no credentials, a bearer token, or OAuth. Custom headers.
//! * **OAuth**: Connect in Browser (`mcp.connect`) asks the daemon to sign
//!   in; it opens the provider's page in the browser (`shell.openUrl`) and
//!   waits on a loopback port for the answer. The sheet shows it waiting,
//!   with Cancel (`mcp.cancelConnect`); once signed in, the server and the
//!   scopes it granted, with Reconnect and Disconnect (`mcp.disconnect`).
//! * **Always Allowed Tools**: the tool calls the user chose to always
//!   allow, each with Revoke, and Revoke All (`mcp.forgetApproval`).
//!
//! Test Connection lists the tools as edited (`mcp.test`). Credentials over
//! plain HTTP to another computer are refused until the user agrees
//! (`args.reason == "insecure"`, then saved again with
//! `allowInsecureCredentials`).

use std::rc::Rc;
use std::time::Duration;

use conduit_components::ActiveConduitTheme as _;
use conduit_components::assets::IconName;
use conduit_components::views::kit::{
    Button, ClickHandler, Switch, grouped, grouped_section, setting_row,
};
use conduit_daemon::RpcError;
use conduit_protocol::{
    ErrorCode, McpAuth, McpForgetApproval, McpRef, McpServerEdit, McpServerList, McpServerSummary,
    McpTestResult, methods,
};
use gpui_kit::component::input::{InputEvent, InputState};
use gpui_kit::prelude::*;
use gpui_kit::{
    AnyElement, App, AsyncApp, ClickEvent, Context, ElementId, Entity, FontWeight, Role,
    SharedString, Subscription, WeakEntity, Window, div, px, relative,
};

use super::editor::OnChange;
use crate::actions::SettingsChoice;
use crate::l10n::{ActiveL10n as _, L10n};
use crate::shell::sheet::{SheetSpec, present_sheet};
use crate::stores::Stores;
use crate::stores::rpc::Rpc;
use crate::views::forms::{
    self, HeaderError, HeaderRow, field, form_error, form_group, form_note, form_row, header_rows,
    headers_edit, headers_from_rows, normalize_url,
};
use crate::views::settings::controls::{self, Choice};
use crate::views::sheet::{self, SheetBody};
use crate::views::words;

/// The sheet's width.
pub const WIDTH: f32 = 560.;
pub const MENU_AUTH: &str = "direct-mcp-auth";

/// How long a browser sign-in may take before the app stops waiting
/// (the daemon's own limit).
const SIGN_IN_TIMEOUT: Duration = Duration::from_secs(10 * 60 + 15);

/// What the last Test said, or that the sign-in worked.
#[derive(Clone, Debug, PartialEq)]
pub enum McpNote {
    Tested(McpTestResult),
    SignedIn,
}

pub struct McpServerSheet {
    rpc: Rpc,
    /// The server as last saved (`None` = a new one).
    pub saved: Option<McpServerSummary>,
    pub enabled: bool,
    pub name: Entity<InputState>,
    pub endpoint: Entity<InputState>,
    pub auth: McpAuth,
    pub token: Entity<InputState>,
    pub headers: Vec<HeaderRow>,
    pub clear_headers: bool,
    /// The address the user agreed to send credentials to over plain
    /// HTTP: another address asks again.
    pub insecure_ok: Option<String>,
    pub busy: bool,
    pub testing: bool,
    /// Signing in in the browser.
    pub connecting: bool,
    pub error: Option<String>,
    pub note: Option<McpNote>,
    initial: String,
    on_change: OnChange,
    _subscriptions: Vec<Subscription>,
}

impl McpServerSheet {
    pub fn open(
        stores: Stores,
        summary: Option<McpServerSummary>,
        on_change: OnChange,
        parent: &Window,
        cx: &mut App,
    ) -> Option<Entity<Self>> {
        sheet::open(parent, WIDTH, cx, move |window, cx| {
            Self::new(stores, summary, on_change, window, cx)
        })
    }

    fn new(
        stores: Stores,
        summary: Option<McpServerSummary>,
        on_change: OnChange,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Self {
        let l10n = cx.l10n().clone();
        let rpc = stores.connection.read(cx).rpc();
        let name = forms::input(l10n.desktop_mcp_name_hint(), false, window, cx);
        let endpoint = forms::input("https://mcp.example.com/mcp", false, window, cx);
        let token = forms::input(l10n.desktop_optional(), true, window, cx);
        let mut subscriptions = vec![];
        for input in [&name, &endpoint, &token] {
            subscriptions.push(cx.subscribe_in(
                input,
                window,
                |this: &mut Self, _, e: &InputEvent, window, cx| match e {
                    InputEvent::PressEnter { .. } if this.can_save(cx) => this.save(window, cx),
                    InputEvent::Change => {
                        this.error = None;
                        cx.notify();
                    }
                    _ => {}
                },
            ));
        }
        let mut this = Self {
            rpc,
            saved: None,
            enabled: true,
            name,
            endpoint,
            auth: McpAuth::None,
            token,
            headers: vec![],
            clear_headers: false,
            insecure_ok: None,
            busy: false,
            testing: false,
            connecting: false,
            error: None,
            note: None,
            initial: String::new(),
            on_change,
            _subscriptions: subscriptions,
        };
        if let Some(s) = summary {
            this.adopt(s, window, cx);
        }
        this.initial = this.fingerprint(cx);
        let first = this.name.clone();
        first.update(cx, |s, cx| s.focus(window, cx));
        this
    }

    fn adopt(&mut self, s: McpServerSummary, window: &mut Window, cx: &mut Context<Self>) {
        let l10n = cx.l10n().clone();
        self.enabled = s.enabled;
        self.auth = s.auth;
        self.insecure_ok = s
            .allow_insecure_credentials
            .then(|| normalize_url(&s.endpoint))
            .flatten();
        let (name, endpoint) = (s.name.clone(), s.endpoint.clone());
        self.name.update(cx, |i, cx| i.set_value(name, window, cx));
        self.endpoint
            .update(cx, |i, cx| i.set_value(endpoint, window, cx));
        self.token.update(cx, |i, cx| i.set_value("", window, cx));
        if s.has_bearer_token {
            forms::set_hint(
                &self.token,
                l10n.direct_configured_replace_placeholder(),
                cx,
            );
        }
        self.saved = Some(s);
    }

    /// The server's state from a list the daemon answered with.
    fn adopt_list(&mut self, list: &McpServerList) {
        if let Some(id) = self.saved.as_ref().map(|s| s.id.clone())
            && let Some(s) = list.servers.iter().find(|s| s.id == id)
        {
            self.saved = Some(s.clone());
        }
    }

    fn fingerprint(&self, cx: &App) -> String {
        let headers: Vec<String> = self
            .headers
            .iter()
            .map(|h| format!("{}={}", forms::text(&h.name, cx), forms::raw(&h.value, cx)))
            .collect();
        format!(
            "{}|{}|{}|{:?}|{}|{:?}|{}",
            self.enabled,
            forms::text(&self.name, cx),
            forms::text(&self.endpoint, cx),
            self.auth,
            !forms::raw(&self.token, cx).is_empty(),
            headers,
            self.clear_headers,
        )
    }

    pub fn is_dirty(&self, cx: &App) -> bool {
        self.fingerprint(cx) != self.initial
    }

    pub fn can_save(&self, cx: &App) -> bool {
        !self.busy
            && !self.testing
            && !self.connecting
            && forms::filled(&[&self.name, &self.endpoint], cx)
    }

    /// The edit to send, or why not.
    pub fn edit(&mut self, cx: &mut Context<Self>) -> Option<McpServerEdit> {
        let l10n = cx.l10n().clone();
        let Some(endpoint) = normalize_url(&forms::text(&self.endpoint, cx)) else {
            self.error = Some(l10n.desktop_invalid_server_address());
            cx.notify();
            return None;
        };
        let rows: Vec<(String, String)> = self
            .headers
            .iter()
            .map(|h| (forms::text(&h.name, cx), forms::raw(&h.value, cx)))
            .collect();
        let typed = match headers_from_rows(&rows) {
            Ok(map) => map,
            Err(e) => {
                self.error = Some(match e {
                    HeaderError::MissingName(_) => l10n.desktop_direct_header_name_required(),
                    HeaderError::InvalidName(_) => l10n.header_name_invalid_chars(),
                    HeaderError::Duplicate(name) => l10n.desktop_header_already_exists(&name),
                });
                cx.notify();
                return None;
            }
        };
        let saved_names = self
            .saved
            .as_ref()
            .map(|s| s.custom_header_names.as_slice())
            .unwrap_or_default();
        let custom_headers = headers_edit(typed, self.clear_headers, saved_names);
        let token = forms::raw(&self.token, cx).trim().to_string();
        let allow_insecure_credentials = self.insecure_ok.as_ref() == Some(&endpoint);
        Some(McpServerEdit {
            id: self.saved.as_ref().map(|s| s.id.clone()),
            name: forms::text(&self.name, cx),
            endpoint,
            enabled: self.enabled,
            auth: self.auth,
            bearer_token: (self.auth == McpAuth::Bearer && !token.is_empty()).then_some(token),
            custom_headers,
            allow_insecure_credentials,
        })
    }

    /// Whether `e` is the daemon asking before sending credentials over
    /// plain HTTP.
    fn is_insecure(e: &RpcError) -> bool {
        e.code == ErrorCode::InvalidParams
            && e.args.get("reason").map(String::as_str) == Some("insecure")
    }

    /// Asks before sending credentials over plain HTTP; on yes, runs
    /// `then` with the agreement recorded.
    fn ask_insecure(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
        then: impl FnOnce(&mut Self, &mut Window, &mut Context<Self>) + 'static,
    ) {
        let l10n = cx.l10n().clone();
        let spec = SheetSpec::new(
            l10n.direct_mcp_insecure_credentials_title(),
            l10n.direct_mcp_insecure_credentials_message(),
            l10n.direct_mcp_insecure_credentials_confirm(),
            l10n.cancel(),
        )
        .destructive();
        let ask = present_sheet(window, spec, cx);
        let handle = window.window_handle();
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            if !ask.await {
                return;
            }
            let _ = handle.update(cx, |_, window, cx| {
                let _ = this.update(cx, |s, cx| {
                    s.insecure_ok = normalize_url(&forms::text(&s.endpoint, cx));
                    then(s, window, cx);
                });
            });
        })
        .detach();
    }

    pub fn test(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if !self.can_save(cx) {
            return;
        }
        self.error = None;
        self.note = None;
        let Some(edit) = self.edit(cx) else { return };
        self.testing = true;
        cx.notify();
        let call = self.rpc.call::<methods::McpTest>(&edit);
        let handle = window.window_handle();
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result = call.await;
            let _ = handle.update(cx, |_, window, cx| {
                let _ = this.update(cx, |s, cx| {
                    s.testing = false;
                    match result {
                        Ok(r) => s.note = Some(McpNote::Tested(r)),
                        Err(e) if Self::is_insecure(&e) => {
                            s.ask_insecure(window, cx, |s, window, cx| s.test(window, cx));
                        }
                        Err(e) => s.error = Some(words::connect_error(&e, &cx.l10n().clone())),
                    }
                    cx.notify();
                });
            });
        })
        .detach();
    }

    /// Saves; with `then_connect`, signs in once saved (Connect in
    /// Browser on a server not saved as it stands).
    pub fn save_and(&mut self, then_connect: bool, window: &mut Window, cx: &mut Context<Self>) {
        if !self.can_save(cx) {
            return;
        }
        self.error = None;
        let Some(edit) = self.edit(cx) else { return };
        self.busy = true;
        cx.notify();
        let call = self.rpc.call::<methods::McpSave>(&edit);
        let handle = window.window_handle();
        let new = self.saved.is_none();
        let name = edit.name.clone();
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result = call.await;
            let _ = handle.update(cx, |_, window, cx| {
                let _ = this.update(cx, |s, cx| {
                    s.busy = false;
                    match result {
                        Ok(list) => {
                            (s.on_change)(cx);
                            if !then_connect {
                                sheet::dismiss(cx);
                                return;
                            }
                            // The server as saved: a new one is the one
                            // with this name that wasn't listed before.
                            let saved = if new {
                                list.servers.iter().rev().find(|x| x.name == name).cloned()
                            } else {
                                s.saved.as_ref().and_then(|old| {
                                    list.servers.iter().find(|x| x.id == old.id).cloned()
                                })
                            };
                            if let Some(saved) = saved {
                                s.adopt(saved, window, cx);
                                s.headers.clear();
                                s.clear_headers = false;
                                s.initial = s.fingerprint(cx);
                                s.connect(window, cx);
                            }
                        }
                        Err(e) if Self::is_insecure(&e) => {
                            s.ask_insecure(window, cx, move |s, window, cx| {
                                s.save_and(then_connect, window, cx)
                            });
                        }
                        Err(e) => {
                            s.error = Some(match e.code {
                                ErrorCode::Conflict => cx.l10n().direct_connection_save_conflict(),
                                _ => words::connect_error(&e, &cx.l10n().clone()),
                            })
                        }
                    }
                    cx.notify();
                });
            });
        })
        .detach();
    }

    pub fn save(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.save_and(false, window, cx);
    }

    /// Connect in Browser: saved as it stands first.
    pub fn connect(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.connecting {
            return;
        }
        let Some(id) = self.saved.as_ref().map(|s| s.id.clone()) else {
            self.save_and(true, window, cx);
            return;
        };
        if self.is_dirty(cx) {
            self.save_and(true, window, cx);
            return;
        }
        self.connecting = true;
        self.error = None;
        self.note = None;
        cx.notify();
        let call = self
            .rpc
            .call_with_timeout::<methods::McpConnect>(&McpRef { id }, SIGN_IN_TIMEOUT);
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result = call.await;
            let _ = this.update(cx, |s, cx| {
                // Cancelled from here: the answer no longer matters.
                if !s.connecting {
                    return;
                }
                s.connecting = false;
                match result {
                    Ok(list) => {
                        s.adopt_list(&list);
                        s.note = Some(McpNote::SignedIn);
                        (s.on_change)(cx);
                    }
                    Err(e) => {
                        log::warn!("mcp.connect: {e}");
                        s.error = Some(cx.l10n().desktop_mcp_sign_in_failed());
                    }
                }
                cx.notify();
            });
        })
        .detach();
    }

    pub fn cancel_connect(&mut self, cx: &mut Context<Self>) {
        let Some(id) = self.saved.as_ref().map(|s| s.id.clone()) else {
            return;
        };
        self.connecting = false;
        cx.notify();
        let call = self.rpc.call::<methods::McpCancelConnect>(&McpRef { id });
        cx.spawn(async move |_, _: &mut AsyncApp| {
            if let Err(e) = call.await {
                log::warn!("mcp.cancelConnect: {e}");
            }
        })
        .detach();
    }

    pub fn disconnect(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(id) = self.saved.as_ref().map(|s| s.id.clone()) else {
            return;
        };
        self.busy = true;
        self.note = None;
        cx.notify();
        let call = self.rpc.call::<methods::McpDisconnect>(&McpRef { id });
        let _ = window;
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result = call.await;
            let _ = this.update(cx, |s, cx| {
                s.busy = false;
                match result {
                    Ok(list) => {
                        s.adopt_list(&list);
                        (s.on_change)(cx);
                    }
                    Err(e) => {
                        log::warn!("mcp.disconnect: {e}");
                        s.error = Some(cx.l10n().desktop_mcp_sign_out_failed());
                    }
                }
                cx.notify();
            });
        })
        .detach();
    }

    /// Revokes one remembered approval (`digest`), or all of them.
    pub fn forget(&mut self, digest: Option<String>, cx: &mut Context<Self>) {
        let Some(server_id) = self.saved.as_ref().map(|s| s.id.clone()) else {
            return;
        };
        let call = self
            .rpc
            .call::<methods::McpForgetApproval>(&McpForgetApproval { server_id, digest });
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result = call.await;
            let _ = this.update(cx, |s, cx| {
                match result {
                    Ok(list) => {
                        s.adopt_list(&list);
                        (s.on_change)(cx);
                    }
                    Err(e) => {
                        log::warn!("mcp.forgetApproval: {e}");
                        s.error = Some(cx.l10n().desktop_mcp_revoke_failed());
                    }
                }
                cx.notify();
            });
        })
        .detach();
    }

    pub fn delete(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(s) = self.saved.clone() else { return };
        let l10n = cx.l10n().clone();
        let spec = SheetSpec::new(
            l10n.desktop_mcp_delete_title(&s.name),
            l10n.desktop_mcp_delete_message(),
            l10n.delete(),
            l10n.cancel(),
        )
        .destructive();
        let ask = present_sheet(window, spec, cx);
        let rpc = self.rpc.clone();
        let on_change = self.on_change.clone();
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            if !ask.await {
                return;
            }
            match rpc.call::<methods::McpRemove>(&McpRef { id: s.id }).await {
                Ok(_) => cx.update(|cx| {
                    on_change(cx);
                    sheet::dismiss(cx);
                }),
                Err(e) => {
                    let _ = this.update(cx, |s, cx| {
                        s.error = Some(words::connect_error(&e, &cx.l10n().clone()));
                        cx.notify();
                    });
                }
            }
        })
        .detach();
    }

    fn on_choice(&mut self, action: &SettingsChoice, cx: &mut Context<Self>) {
        if action.menu == MENU_AUTH {
            self.auth = match action.value.as_str() {
                "bearer" => McpAuth::Bearer,
                "oauth" => McpAuth::Oauth,
                _ => McpAuth::None,
            };
            self.note = None;
            cx.notify();
        }
    }

    fn listener(
        &self,
        cx: &Context<Self>,
        f: impl Fn(&mut Self, &mut Window, &mut Context<Self>) + 'static,
    ) -> ClickHandler {
        let this = cx.entity().downgrade();
        let f = Rc::new(f);
        Rc::new(move |_: &ClickEvent, window: &mut Window, cx: &mut App| {
            let f = f.clone();
            let _ = this.update(cx, |s, cx| f(s, window, cx));
        })
    }

    fn add_header(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let name = forms::input("X-Custom-Header", false, window, cx);
        let value = forms::input("", true, window, cx);
        self.headers.push(HeaderRow { name, value });
        cx.notify();
    }

    fn auth_value(auth: McpAuth) -> &'static str {
        match auth {
            McpAuth::Bearer => "bearer",
            McpAuth::Oauth => "oauth",
            _ => "none",
        }
    }

    fn oauth_group(&self, l10n: &L10n, cx: &mut Context<Self>) -> AnyElement {
        let saved_oauth = self.saved.as_ref().filter(|s| s.auth == McpAuth::Oauth);
        let connected = saved_oauth.is_some_and(|s| s.oauth_connected);
        let detail: Option<SharedString> = if self.connecting {
            Some(l10n.desktop_mcp_waiting_for_browser().into())
        } else if connected {
            let s = saved_oauth.expect("connected");
            let scopes = if s.oauth_scopes.is_empty() {
                l10n.desktop_mcp_no_scopes()
            } else {
                s.oauth_scopes.join(", ")
            };
            Some(
                l10n.desktop_mcp_connected_to(
                    s.oauth_issuer_host.as_deref().unwrap_or_default(),
                    &scopes,
                )
                .into(),
            )
        } else {
            Some(l10n.desktop_mcp_sign_in_help().into())
        };
        let mut buttons = div().flex().items_center().gap(px(8.));
        if self.connecting {
            buttons = buttons.child(
                Button::new("mcp-cancel-sign-in", l10n.cancel())
                    .on_click(self.listener(cx, |s, _, cx| s.cancel_connect(cx))),
            );
        } else {
            if connected {
                buttons = buttons.child(
                    Button::new("mcp-disconnect", l10n.desktop_sign_out())
                        .disabled(self.busy)
                        .on_click(self.listener(cx, |s, w, cx| s.disconnect(w, cx))),
                );
            }
            buttons = buttons.child(
                Button::new(
                    "mcp-connect",
                    if connected {
                        l10n.direct_mcp_o_auth_reconnect()
                    } else {
                        l10n.direct_mcp_o_auth_connect()
                    },
                )
                .icon(IconName::ExternalLink)
                .disabled(!self.can_save(cx))
                .on_click(self.listener(cx, |s, w, cx| s.connect(w, cx))),
            );
        }
        grouped(
            vec![
                setting_row(
                    if connected {
                        l10n.desktop_mcp_signed_in()
                    } else {
                        l10n.desktop_mcp_not_signed_in()
                    },
                    detail,
                    buttons,
                    cx,
                )
                .into_any_element(),
            ],
            cx,
        )
        .into_any_element()
    }

    fn approvals_group(&self, l10n: &L10n, cx: &mut Context<Self>) -> Option<AnyElement> {
        let s = self.saved.as_ref()?;
        if s.approvals.is_empty() {
            return None;
        }
        let mut rows: Vec<AnyElement> = s
            .approvals
            .iter()
            .map(|a| {
                let digest = a.digest.clone();
                setting_row(
                    a.tool_name.clone(),
                    None,
                    Button::new(
                        ElementId::Name(format!("mcp-revoke-{}", a.digest).into()),
                        l10n.desktop_mcp_revoke(),
                    )
                    .on_click(
                        self.listener(cx, move |s, _, cx| s.forget(Some(digest.clone()), cx)),
                    ),
                    cx,
                )
                .into_any_element()
            })
            .collect();
        if s.approvals.len() > 1 {
            rows.push(
                div()
                    .px(px(12.))
                    .py(px(8.))
                    .flex()
                    .justify_end()
                    .child(
                        Button::new(
                            "mcp-revoke-all",
                            l10n.direct_mcp_remembered_approvals_revoke_all(),
                        )
                        .on_click(self.listener(cx, |s, _, cx| s.forget(None, cx))),
                    )
                    .into_any_element(),
            );
        }
        Some(
            grouped_section(
                Some(l10n.direct_mcp_remembered_approvals_title().into()),
                rows,
                Some(l10n.desktop_mcp_approvals_help().into()),
                cx,
            )
            .into_any_element(),
        )
    }
}

impl SheetBody for McpServerSheet {
    fn footer(&mut self, _: &mut Window, cx: &mut Context<Self>) -> Option<AnyElement> {
        let l10n = cx.l10n().clone();
        let can_save = self.can_save(cx);
        let delete = self.saved.is_some().then(|| {
            Button::new("mcp-delete", l10n.desktop_delete_ellipsis())
                .disabled(self.busy || self.connecting)
                .on_click(self.listener(cx, |s, w, cx| s.delete(w, cx)))
        });
        Some(
            div()
                .w_full()
                .flex()
                .items_center()
                .gap(px(8.))
                .children(delete)
                .child(div().flex_1())
                .child(
                    Button::new(
                        "mcp-test",
                        if self.testing {
                            l10n.desktop_testing()
                        } else {
                            l10n.desktop_test_connection()
                        },
                    )
                    .disabled(!can_save)
                    .on_click(self.listener(cx, |s, w, cx| s.test(w, cx))),
                )
                .child(
                    Button::new("mcp-cancel", l10n.cancel())
                        .on_click(self.listener(cx, |s, w, cx| s.cancel(w, cx))),
                )
                .child(
                    Button::new(
                        "mcp-save",
                        if self.busy {
                            l10n.desktop_saving()
                        } else {
                            l10n.save()
                        },
                    )
                    .primary()
                    .disabled(!can_save)
                    .on_click(self.listener(cx, |s, w, cx| s.save(w, cx))),
                )
                .into_any_element(),
        )
    }

    fn cancel(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.busy {
            return;
        }
        if self.connecting {
            self.cancel_connect(cx);
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
        if self.saved.is_some() {
            cx.l10n().direct_mcp_editor_title().into()
        } else {
            cx.l10n().direct_mcp_add_title().into()
        }
    }
}

impl Render for McpServerSheet {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let l10n = cx.l10n().clone();
        let t = cx.conduit().clone();
        let title = self.label(cx);
        let mut rows: Vec<AnyElement> = vec![
            field(l10n.direct_mcp_name(), &self.name, None, None, window, cx).into_any_element(),
            field(
                l10n.desktop_mcp_endpoint(),
                &self.endpoint,
                Some(l10n.desktop_mcp_reachability_help().into()),
                None,
                window,
                cx,
            )
            .into_any_element(),
            form_row(
                l10n.desktop_direct_authentication(),
                controls::popup(
                    MENU_AUTH,
                    &l10n.desktop_direct_authentication(),
                    vec![
                        Choice::new("none", l10n.desktop_mcp_auth_none()),
                        Choice::new("bearer", l10n.direct_mcp_auth_bearer()),
                        Choice::new("oauth", l10n.desktop_mcp_auth_oauth()),
                    ],
                    Self::auth_value(self.auth),
                    self.busy || self.connecting,
                    window,
                    cx,
                ),
                cx,
            )
            .into_any_element(),
        ];
        if self.auth == McpAuth::Bearer {
            rows.push(
                field(l10n.bearer_token(), &self.token, None, None, window, cx).into_any_element(),
            );
        }
        let saved_headers: Vec<String> = self
            .saved
            .as_ref()
            .map(|s| s.custom_header_names.clone())
            .unwrap_or_default();
        let configured = (!saved_headers.is_empty() && !self.clear_headers).then(|| {
            div()
                .flex()
                .items_center()
                .gap(px(8.))
                .child(
                    div()
                        .flex_1()
                        .min_w_0()
                        .text_size(px(t.metrics.small))
                        .text_color(t.roles.text_subtle)
                        .child(l10n.desktop_mcp_headers_configured(&saved_headers.join(", "))),
                )
                .child(
                    Button::new("mcp-headers-clear", l10n.clear())
                        .ghost()
                        .on_click(self.listener(cx, |s, _, cx| {
                            s.clear_headers = true;
                            cx.notify();
                        })),
                )
        });
        let remove = {
            let this = cx.entity().downgrade();
            Rc::new(move |i: usize, _: &mut Window, cx: &mut App| {
                let _ = this.update(cx, |s, cx| {
                    if i < s.headers.len() {
                        s.headers.remove(i);
                    }
                    cx.notify();
                });
            })
        };
        let headers = form_group(
            vec![
                div()
                    .px(px(12.))
                    .py(px(8.))
                    .flex()
                    .flex_col()
                    .gap(px(8.))
                    .child(
                        setting_row(
                            l10n.desktop_custom_headers(),
                            Some(l10n.desktop_custom_headers_help().into()),
                            Button::new("mcp-add-header", l10n.desktop_add_header())
                                .icon(IconName::Plus)
                                .on_click(self.listener(cx, |s, w, cx| s.add_header(w, cx))),
                            cx,
                        )
                        .px_0(),
                    )
                    .children(configured)
                    .child(header_rows(
                        &self.headers,
                        l10n.desktop_header_name().into(),
                        l10n.desktop_header_value().into(),
                        l10n.desktop_remove_header().into(),
                        remove,
                        cx,
                    ))
                    .into_any_element(),
            ],
            cx,
        );
        let note = self.note.as_ref().map(|n| match n {
            McpNote::Tested(r) if r.reachable => (
                l10n.direct_mcp_test_succeeded(r.tool_count.unwrap_or(0)),
                true,
            ),
            McpNote::Tested(_) => (l10n.desktop_mcp_test_failed(), false),
            McpNote::SignedIn => (l10n.desktop_mcp_signed_in_note(), true),
        });
        div()
            .id("mcp-editor")
            .role(Role::Form)
            .aria_label(title.clone())
            .w_full()
            .flex()
            .flex_col()
            .gap(px(16.))
            .on_action(cx.listener(|this, a: &SettingsChoice, _, cx| this.on_choice(a, cx)))
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
                            .child(title),
                    )
                    .child(
                        div()
                            .text_size(px(t.metrics.small + 0.5))
                            .line_height(relative(1.4))
                            .text_color(t.roles.text_subtle)
                            .child(l10n.desktop_mcp_editor_subtitle()),
                    ),
            )
            .child(grouped(
                vec![
                    setting_row(
                        l10n.enabled_label(),
                        Some(l10n.desktop_mcp_enabled_help().into()),
                        Switch::new("mcp-enabled", l10n.enabled_label(), self.enabled).on_click(
                            self.listener(cx, |s, _, cx| {
                                s.enabled = !s.enabled;
                                cx.notify();
                            }),
                        ),
                        cx,
                    )
                    .into_any_element(),
                ],
                cx,
            ))
            .child(form_group(rows, cx))
            .when(self.auth == McpAuth::Oauth, |d| {
                d.child(self.oauth_group(&l10n, cx))
            })
            .child(headers)
            .children(self.approvals_group(&l10n, cx))
            .when_some(self.error.clone(), |d, e| {
                d.child(form_error("mcp-error", e, cx))
            })
            .when_some(note, |d, (text, ok)| d.child(form_note(text, ok, cx)))
    }
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeMap;

    use gpui_kit::{TestAppContext, VisualTestContext};
    use serde_json::json;

    use super::*;
    use crate::stores::rpc::fake::FakeDaemon;

    /// A saved server on plain HTTP, its credentials agreed to, with one
    /// saved header.
    fn saved() -> McpServerSummary {
        serde_json::from_value(json!({
            "id": "mcp-1", "name": "Docs", "endpoint": "http://docs.lab.example/mcp",
            "enabled": true, "auth": "bearer", "hasBearerToken": true,
            "customHeaderNames": ["X-Team"], "oauthConnected": false,
            "allowInsecureCredentials": true, "approvals": []
        }))
        .unwrap()
    }

    fn bench(cx: &mut TestAppContext) -> (Entity<McpServerSheet>, &mut VisualTestContext) {
        let daemon = FakeDaemon::new();
        let scratch = std::env::temp_dir().join(format!("conduit-mcp-{}", std::process::id()));
        let stores = cx.update(|cx| {
            crate::views::test_globals(cx);
            Stores::for_test(daemon.rpc(), &scratch, cx)
        });
        let on_change: OnChange = Rc::new(|_| {});
        cx.add_window_view(move |window, cx| {
            McpServerSheet::new(stores, Some(saved()), on_change, window, cx)
        })
    }

    /// The yes to plain HTTP was for the saved address: another one asks
    /// again.
    #[gpui_kit::test]
    fn agreeing_to_plain_http_stays_with_its_address(cx: &mut TestAppContext) {
        let (sheet, vcx) = bench(cx);
        let edit = sheet.update_in(vcx, |s, _, cx| s.edit(cx)).unwrap();
        assert!(edit.allow_insecure_credentials, "the saved yes was dropped");
        let edit = sheet
            .update_in(vcx, |s, window, cx| {
                s.endpoint.update(cx, |i, cx| {
                    i.set_value("http://other.lab.example/mcp", window, cx)
                });
                s.edit(cx)
            })
            .unwrap();
        assert!(
            !edit.allow_insecure_credentials,
            "the yes for one address went to another"
        );
    }

    /// Saved headers are known by name only: a header added joins them,
    /// and Clear with a new one takes the saved ones away.
    #[gpui_kit::test]
    fn added_headers_keep_or_clear_the_saved_ones_as_shown(cx: &mut TestAppContext) {
        let (sheet, vcx) = bench(cx);
        let headers = sheet
            .update_in(vcx, |s, window, cx| {
                s.add_header(window, cx);
                let row = &s.headers[0];
                row.name
                    .update(cx, |i, cx| i.set_value("X-Trace", window, cx));
                row.value.update(cx, |i, cx| i.set_value("on", window, cx));
                s.edit(cx)
            })
            .unwrap()
            .custom_headers;
        assert_eq!(
            headers,
            Some(BTreeMap::from([("X-Trace".into(), "on".into())]))
        );
        let headers = sheet
            .update_in(vcx, |s, _, cx| {
                s.clear_headers = true;
                s.edit(cx)
            })
            .unwrap()
            .custom_headers;
        assert_eq!(
            headers,
            Some(BTreeMap::from([
                ("X-Team".into(), String::new()),
                ("X-Trace".into(), "on".into()),
            ])),
            "Clear kept the saved header"
        );
    }
}
