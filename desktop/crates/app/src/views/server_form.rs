//! The Open WebUI server form: address, name, and (under Advanced) an
//! unverified certificate, mutual TLS and custom headers. Onboarding shows
//! it, and so does "Add account".
//!
//! Connecting is validate-then-commit, as on mobile, through the daemon:
//! the form checks what it can (an http(s) address, header names), then
//! `accounts.add` makes the new account active and `servers.status` asks
//! the server itself. If it does not answer as Open WebUI, the addition is
//! undone (`accounts.cancelAdd`, or `accounts.remove` for the first
//! account) and the form says why; otherwise the window moves on to sign-in.

use std::rc::Rc;

use conduit_components::ActiveConduitTheme as _;
use conduit_components::assets::IconName;
use conduit_components::views::focus::ControlExt as _;
use conduit_components::views::kit::{Button, Switch, grouped, setting_row};
use conduit_components::views::onboarding::{back_link, title_block};
use conduit_protocol::{AccountChangeOutcome, NoParams, ServerDraft, methods};
use gpui_kit::component::input::{InputEvent, InputState};
use gpui_kit::prelude::*;
use gpui_kit::{
    AnyElement, App, AsyncWindowContext, Context, Entity, EventEmitter, FontWeight, Role,
    SharedString, Subscription, WeakEntity, Window, div, px,
};

use crate::l10n::{ActiveL10n as _, L10n};
use crate::shell::sheet::{SheetSpec, present_sheet};
use crate::stores::Stores;
use crate::stores::accounts::AccountChange;
use crate::views::forms::{
    self, HeaderError, HeaderRow, PemError, PemFile, PemLabels, field, field_locked, form_buttons,
    form_error, form_group, header_rows_locked, headers_from_rows, normalize_url,
    pem_picker_locked, pick_pem,
};

fn labels(l10n: &L10n) -> PemLabels {
    PemLabels {
        choose: l10n.desktop_choose_file().into(),
        replace: l10n.desktop_replace_file().into(),
        clear: l10n.clear().into(),
    }
}
use crate::views::words;

#[derive(Clone, Debug, PartialEq)]
pub enum ServerFormEvent {
    /// The server answered as Open WebUI; sign-in is next.
    Connected,
    /// Back (onboarding) or Cancel (adding an account).
    Back,
    /// Add Account › Hermes Agent: the Hermes connection editor is next.
    AddHermes,
    /// Add Account › Model Provider: the provider editor is next.
    AddDirect,
}

/// The Advanced settings of a server's address: an unverified certificate
/// trusted or not, a client certificate with its key and the key's
/// password, and custom headers. The server form shows them, and so does
/// the editor of a saved server's address ([`crate::views::settings::server_sheet`]).
pub struct AdvancedFields {
    pub self_signed: bool,
    pub certificate: Option<PemFile>,
    pub private_key: Option<PemFile>,
    pub key_password: Entity<InputState>,
    pub headers: Vec<HeaderRow>,
    pub header_error: Option<String>,
    /// The custom header row `header_error` is about.
    pub header_error_row: Option<usize>,
}

impl AdvancedFields {
    pub fn new<V: 'static>(window: &mut Window, cx: &mut Context<V>) -> Self {
        let l10n = cx.l10n().clone();
        Self {
            self_signed: false,
            certificate: None,
            private_key: None,
            key_password: forms::input(l10n.desktop_optional(), true, window, cx),
            headers: vec![],
            header_error: None,
            header_error_row: None,
        }
    }

    /// Back to nothing set.
    pub fn clear(&mut self, window: &mut Window, cx: &mut App) {
        self.key_password
            .update(cx, |i, cx| i.set_value("", window, cx));
        self.headers.clear();
        self.certificate = None;
        self.private_key = None;
        self.self_signed = false;
        self.header_error = None;
        self.header_error_row = None;
    }

    /// Adds an empty header row.
    pub fn add_header<V: 'static>(&mut self, window: &mut Window, cx: &mut Context<V>) {
        // The fields are labelled; no placeholders restating the labels.
        let name = forms::input("", false, window, cx);
        let value = forms::input("", true, window, cx);
        self.headers.push(HeaderRow { name, value });
        self.header_error = None;
        self.header_error_row = None;
    }
}

/// A view showing [`AdvancedFields`].
pub trait HasAdvanced: Sized + 'static {
    fn advanced(&self) -> &AdvancedFields;
    fn advanced_mut(&mut self) -> &mut AdvancedFields;

    /// Why a picked certificate or key cannot be used, or None once one
    /// is taken.
    fn file_problem(&mut self, problem: Option<String>);

    /// The certificate (or with `key`, the key) was cleared.
    fn file_cleared(&mut self, key: bool) {
        let fields = self.advanced_mut();
        if key {
            fields.private_key = None;
        } else {
            fields.certificate = None;
        }
    }

    /// Anything in the Advanced settings changed.
    fn advanced_changed(&mut self) {}

    /// Whether the Advanced settings take no input now: a save of the form
    /// is out, so what it answers is the form as it stands.
    fn locked(&self) -> bool {
        false
    }
}

/// Picks a certificate (or with `key`, a private key) with the open panel.
pub fn choose_pem<V: HasAdvanced>(key: bool, window: &mut Window, cx: &mut Context<V>) {
    let marker = if key { "PRIVATE KEY" } else { "CERTIFICATE" };
    let pick = pick_pem(marker, cx);
    cx.spawn_in(
        window,
        async move |this: WeakEntity<V>, cx: &mut AsyncWindowContext| {
            let picked = pick.await;
            let _ = this.update(cx, |s, cx| {
                let l10n = cx.l10n().clone();
                match picked {
                    Ok(Some(file)) => {
                        if key {
                            s.advanced_mut().private_key = Some(file);
                        } else {
                            s.advanced_mut().certificate = Some(file);
                        }
                        s.file_problem(None);
                        s.advanced_changed();
                    }
                    Ok(None) => {}
                    Err(PemError::NotPem) => s.file_problem(Some(if key {
                        l10n.mutual_tls_private_key_pem_required()
                    } else {
                        l10n.mutual_tls_certificate_pem_required()
                    })),
                    Err(PemError::Unreadable(e)) => s.file_problem(Some(e)),
                }
                cx.notify();
            });
        },
    )
    .detach();
}

/// The Advanced settings' rows, in a group.
pub fn advanced_section<V: HasAdvanced>(
    view: &V,
    window: &mut Window,
    cx: &mut Context<V>,
) -> AnyElement {
    let l10n = cx.l10n().clone();
    let fields = view.advanced();
    let locked = view.locked();
    let this = cx.entity().downgrade();
    let toggle = {
        let this = this.clone();
        Rc::new(
            move |_: &gpui_kit::ClickEvent, _: &mut Window, cx: &mut App| {
                let _ = this.update(cx, |s, cx| {
                    let fields = s.advanced_mut();
                    fields.self_signed = !fields.self_signed;
                    s.advanced_changed();
                    cx.notify();
                });
            },
        )
    };
    let pem = |key: bool| -> conduit_components::views::kit::ClickHandler {
        let this = this.clone();
        Rc::new(move |_, window, cx| {
            let _ = this.update(cx, |_, cx| choose_pem::<V>(key, window, cx));
        })
    };
    let clear = |key: bool| -> conduit_components::views::kit::ClickHandler {
        let this = this.clone();
        Rc::new(move |_, _, cx| {
            let _ = this.update(cx, |s, cx| {
                s.file_cleared(key);
                s.advanced_changed();
                cx.notify();
            });
        })
    };
    let remove_header = {
        let this = this.clone();
        Rc::new(move |i: usize, _: &mut Window, cx: &mut App| {
            let _ = this.update(cx, |s, cx| {
                let fields = s.advanced_mut();
                if i < fields.headers.len() {
                    fields.headers.remove(i);
                }
                fields.header_error = None;
                fields.header_error_row = None;
                s.advanced_changed();
                cx.notify();
            });
        })
    };
    let add_header = {
        let this = this.clone();
        Rc::new(
            move |_: &gpui_kit::ClickEvent, window: &mut Window, cx: &mut App| {
                let _ = this.update(cx, |s, cx| {
                    s.advanced_mut().add_header(window, cx);
                    s.advanced_changed();
                    cx.notify();
                });
            },
        )
    };
    let mut rows: Vec<AnyElement> = vec![
        setting_row(
            l10n.desktop_allow_unverified_certificate(),
            Some(l10n.desktop_self_signed_help().into()),
            Switch::new(
                "self-signed",
                l10n.desktop_allow_unverified_certificate(),
                fields.self_signed,
            )
            .disabled(locked)
            .on_click(toggle),
            cx,
        )
        .into_any_element(),
        setting_row(
            l10n.mutual_tls_select_certificate(),
            Some(l10n.desktop_client_certificate_help().into()),
            pem_picker_locked(
                "mtls-certificate",
                fields.certificate.as_ref(),
                labels(&l10n),
                pem(false),
                clear(false),
                locked,
                cx,
            ),
            cx,
        )
        .into_any_element(),
        setting_row(
            l10n.desktop_private_key(),
            None,
            pem_picker_locked(
                "mtls-private-key",
                fields.private_key.as_ref(),
                labels(&l10n),
                pem(true),
                clear(true),
                locked,
                cx,
            ),
            cx,
        )
        .into_any_element(),
    ];
    if fields.private_key.is_some() {
        rows.push(
            field_locked(
                l10n.desktop_private_key_password(),
                &fields.key_password,
                None,
                None,
                locked,
                window,
                cx,
            )
            .into_any_element(),
        );
    }
    rows.push(
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
                    Button::new("add-header", l10n.desktop_add_header())
                        .icon(IconName::Plus)
                        .disabled(locked || fields.headers.len() >= MAX_HEADERS)
                        .on_click(add_header),
                    cx,
                )
                .px_0(),
            )
            .child(header_rows_locked(
                &fields.headers,
                l10n.desktop_header_name().into(),
                l10n.desktop_header_value().into(),
                l10n.desktop_remove_header().into(),
                remove_header,
                locked,
                cx,
            ))
            .when_some(fields.header_error.clone(), |d, e| {
                d.child(form_error("header-error", e, cx))
            })
            .into_any_element(),
    );
    grouped(rows, cx).into_any_element()
}

/// The most custom headers an address carries (the core's limit).
pub const MAX_HEADERS: usize = 10;

pub struct ServerForm {
    stores: Stores,
    pub url: Entity<InputState>,
    pub name: Entity<InputState>,
    pub adv: AdvancedFields,
    pub advanced: bool,
    /// Connecting and checking the server.
    pub busy: bool,
    pub error: Option<String>,
    pub url_error: Option<String>,
    /// Started from Accounts while another account is in use: Back reads
    /// "Cancel".
    pub adding: bool,
    /// Drawn in a sheet (Settings › Accounts › Add Account): a compact
    /// heading instead of the first-run page's large one.
    pub sheet: bool,
    _subscriptions: Vec<Subscription>,
}

impl EventEmitter<ServerFormEvent> for ServerForm {}

impl ServerForm {
    pub fn new(stores: Stores, window: &mut Window, cx: &mut Context<Self>) -> Self {
        let l10n = cx.l10n().clone();
        let url = forms::input(l10n.server_url_hint(), false, window, cx);
        // An example name, not the label again.
        let name = forms::input(l10n.desktop_server_name_placeholder(), false, window, cx);
        let adv = AdvancedFields::new(window, cx);
        let submit_on_enter = |this: &mut Self,
                               _: &Entity<InputState>,
                               e: &InputEvent,
                               window: &mut Window,
                               cx: &mut Context<Self>| {
            match e {
                // Return is Connect's: nothing while it is off.
                InputEvent::PressEnter { .. } if this.can_connect(cx) => this.submit(window, cx),
                // Typing clears the last error and may turn Connect on.
                InputEvent::Change => {
                    this.url_error = None;
                    this.error = None;
                    cx.notify();
                }
                _ => {}
            }
        };
        let subscriptions = vec![
            cx.subscribe_in(&url, window, submit_on_enter),
            cx.subscribe_in(&name, window, submit_on_enter),
        ];
        Self {
            stores,
            url,
            name,
            adv,
            advanced: false,
            busy: false,
            error: None,
            url_error: None,
            adding: false,
            sheet: false,
            _subscriptions: subscriptions,
        }
    }

    /// Whether Connect can go: not checking a server, and an address typed.
    pub fn can_connect(&self, cx: &App) -> bool {
        !self.busy && forms::filled(&[&self.url], cx)
    }

    /// Clears the form for another use (onboarding again, or an addition).
    pub fn reset(&mut self, adding: bool, window: &mut Window, cx: &mut Context<Self>) {
        for input in [&self.url, &self.name] {
            input.update(cx, |i, cx| i.set_value("", window, cx));
        }
        self.adv.clear(window, cx);
        self.advanced = false;
        self.busy = false;
        self.error = None;
        self.url_error = None;
        self.adding = adding;
        cx.notify();
    }

    /// The draft to send, or why there is none (shown on the form).
    pub fn draft(&mut self, cx: &mut Context<Self>) -> Option<ServerDraft> {
        let l10n = cx.l10n().clone();
        let raw = forms::text(&self.url, cx);
        let url = if raw.is_empty() {
            self.url_error = Some(l10n.server_url_empty());
            None
        } else {
            match normalize_url(&raw) {
                Some(u) => Some(u),
                None => {
                    self.url_error = Some(l10n.desktop_invalid_server_address());
                    None
                }
            }
        };
        let rows: Vec<(String, String)> = self
            .adv
            .headers
            .iter()
            .map(|r| (forms::text(&r.name, cx), forms::text(&r.value, cx)))
            .collect();
        let headers = match headers_from_rows(&rows) {
            Ok(h) => Some(h),
            Err(e) => {
                self.adv.header_error_row = match &e {
                    HeaderError::MissingName(i) | HeaderError::InvalidName(i) => Some(*i),
                    HeaderError::Duplicate(name) => rows
                        .iter()
                        .rposition(|(n, _)| n.trim().eq_ignore_ascii_case(name)),
                };
                self.adv.header_error = Some(match e {
                    HeaderError::MissingName(_) | HeaderError::InvalidName(_) => {
                        l10n.header_name_invalid_chars()
                    }
                    HeaderError::Duplicate(name) => l10n.desktop_header_already_exists(&name),
                });
                self.advanced = true;
                None
            }
        };
        cx.notify();
        let (url, headers) = (url?, headers?);
        let name = forms::text(&self.name, cx);
        let password = forms::raw(&self.adv.key_password, cx);
        let adv = &self.adv;
        Some(ServerDraft {
            id: None,
            name: if name.is_empty() {
                forms::host_of(&url)
            } else {
                name
            },
            url,
            allow_self_signed_certificates: adv.self_signed,
            mtls_certificate_chain_pem: adv.certificate.as_ref().map(|f| f.pem.clone()),
            mtls_certificate_label: adv.certificate.as_ref().map(|f| f.label.clone()),
            mtls_private_key_pem: adv.private_key.as_ref().map(|f| f.pem.clone()),
            mtls_private_key_label: adv.private_key.as_ref().map(|f| f.label.clone()),
            mtls_private_key_password: (!password.is_empty()).then_some(password),
            clear_mutual_tls: false,
            custom_headers: (!headers.is_empty()).then_some(headers),
        })
    }

    /// Connect: add the account, then ask the server.
    pub fn submit(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.busy {
            return;
        }
        self.error = None;
        self.url_error = None;
        self.adv.header_error = None;
        let Some(draft) = self.draft(cx) else {
            self.focus_invalid(window, cx);
            return;
        };
        self.busy = true;
        cx.notify();
        let accounts = self.stores.accounts.clone();
        let session = self.stores.session.clone();
        let rpc = self.stores.connection.read(cx).rpc();
        let l10n = cx.l10n().clone();
        // The accounts there before: only one this Connect made is ever
        // removed again.
        let before: Vec<String> = self
            .stores
            .accounts
            .read(cx)
            .accounts()
            .iter()
            .map(|a| a.id.clone())
            .collect();
        let add = accounts.update(cx, |a, cx| {
            a.change(AccountChange::Add(Box::new(draft.clone())), false, cx)
        });
        cx.spawn_in(
            window,
            async move |this: WeakEntity<Self>, cx: &mut AsyncWindowContext| {
                let mut result = add.await;
                // Adding leaves the account in use; ask before stopping a reply.
                if let Ok(r) = &result
                    && r.outcome == AccountChangeOutcome::BlockedByActiveReply
                {
                    let spec = SheetSpec::new(
                        l10n.desktop_reply_in_progress(),
                        l10n.accounts_switch_stops_reply(),
                        l10n.desktop_switch_anyway(),
                        l10n.cancel(),
                    );
                    let ask = cx.update(|window, cx| present_sheet(window, spec, cx));
                    let confirmed = match ask {
                        Ok(task) => task.await,
                        Err(_) => false,
                    };
                    if !confirmed {
                        accounts.update(cx, |a, cx| a.dismiss_blocked(cx));
                        let _ = this.update(cx, |s, cx| {
                            s.busy = false;
                            cx.notify();
                        });
                        return;
                    }
                    let again = accounts.update(cx, |a, cx| {
                        a.change(AccountChange::Add(Box::new(draft)), true, cx)
                    });
                    result = again.await;
                }
                let added = match result {
                    Ok(r) => r,
                    Err(e) => {
                        let _ = this.update_in(cx, |s, window, cx| {
                            s.busy = false;
                            s.error = Some(words::connect_error(&e, &l10n));
                            s.focus_invalid(window, cx);
                            cx.notify();
                        });
                        return;
                    }
                };
                // Validate against the server itself, now that it is active.
                let status = rpc.call::<methods::ServersStatus>(&NoParams).await;
                let problem = match &status {
                    Ok(s) => words::server_problem(s, &l10n),
                    Err(e) => Some(words::connect_error(e, &l10n)),
                };
                if let Some(problem) = problem {
                    // Undo, so the user stays on the form.
                    let undo = if added.accounts.adding_account {
                        AccountChange::CancelAdd
                    } else if let Some(id) = added.accounts.active_account_id.clone() {
                        AccountChange::Remove { account_id: id }
                    } else {
                        AccountChange::CancelAdd
                    };
                    let added_id = added
                        .accounts
                        .active_account_id
                        .clone()
                        .filter(|id| !before.contains(id));
                    let undone = accounts.update(cx, |a, cx| a.change(undo, true, cx)).await;
                    // Cancel leaves the new account when the one it was added
                    // from cannot take over (it has no session): remove it.
                    let left = matches!(&undone, Ok(r) if r.outcome == AccountChangeOutcome::Done);
                    let still_there = |id: &str| match &undone {
                        Ok(r) => r.accounts.accounts.iter().any(|a| a.id == id),
                        Err(_) => true,
                    };
                    if !left && let Some(id) = added_id.filter(|id| still_there(id)) {
                        let removed = accounts
                            .update(cx, |a, cx| {
                                a.change(AccountChange::Remove { account_id: id }, true, cx)
                            })
                            .await;
                        if let Err(e) = removed {
                            log::warn!("server form: the failed server stayed added: {e}");
                        }
                    }
                    session.update(cx, |s, cx| s.refresh(cx));
                    let _ = this.update_in(cx, |s, window, cx| {
                        s.busy = false;
                        s.error = Some(problem);
                        s.focus_invalid(window, cx);
                        cx.notify();
                    });
                    return;
                }
                session.update(cx, |s, cx| s.refresh(cx));
                let _ = this.update(cx, |s, cx| {
                    s.busy = false;
                    cx.emit(ServerFormEvent::Connected);
                    cx.notify();
                });
            },
        )
        .detach();
    }

    /// After a failed Connect: the field to fix, its text selected (a
    /// header row the check refused, else the address the server behind
    /// it did not answer as Open WebUI at).
    fn focus_invalid(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let header = self
            .adv
            .header_error
            .as_ref()
            .filter(|_| self.url_error.is_none())
            .and(self.adv.header_error_row)
            .and_then(|i| self.adv.headers.get(i))
            .map(|row| row.name.clone());
        let field = header.unwrap_or_else(|| self.url.clone());
        forms::focus_invalid(&field, window, cx);
    }
}

impl HasAdvanced for ServerForm {
    fn advanced(&self) -> &AdvancedFields {
        &self.adv
    }

    fn advanced_mut(&mut self) -> &mut AdvancedFields {
        &mut self.adv
    }

    fn file_problem(&mut self, problem: Option<String>) {
        self.error = problem;
    }
}

impl Render for ServerForm {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let l10n: L10n = cx.l10n().clone();
        let t = cx.conduit().clone();
        let this = cx.entity().downgrade();
        let back = {
            let this = this.clone();
            Rc::new(
                move |_: &gpui_kit::ClickEvent, _: &mut Window, cx: &mut App| {
                    let _ = this.update(cx, |s, cx| {
                        if !s.busy {
                            cx.emit(ServerFormEvent::Back)
                        }
                    });
                },
            )
        };
        let toggle_advanced = {
            let this = this.clone();
            move |_: &gpui_kit::ClickEvent, _: &mut Window, cx: &mut App| {
                let _ = this.update(cx, |s, cx| {
                    s.advanced = !s.advanced;
                    cx.notify();
                });
            }
        };
        let connect = {
            let this = this.clone();
            Rc::new(
                move |_: &gpui_kit::ClickEvent, window: &mut Window, cx: &mut App| {
                    let _ = this.update(cx, |s, cx| s.submit(window, cx));
                },
            )
        };
        let back_label: SharedString = if self.adding {
            l10n.cancel().into()
        } else {
            l10n.back().into()
        };
        let title = if self.adding {
            l10n.desktop_add_account()
        } else {
            l10n.desktop_connect_to_server()
        };
        let advanced = self.advanced.then(|| advanced_section(&*self, window, cx));
        div()
            .id("server-form")
            .role(Role::Form)
            .aria_label(title.clone())
            .flex()
            .flex_col()
            .gap(px(18.))
            // First run steps back to the chooser from the top, as a page
            // does; adding an account cancels from the buttons at the end.
            .when(!self.adding, |d| {
                d.child(back_link(back_label.clone(), Some(back.clone()), cx))
            })
            .child(if self.sheet {
                // A sheet's heading, as Mail's Add Account sheet: the title
                // at the leading edge over what to do.
                let r = t.roles;
                div()
                    .flex()
                    .flex_col()
                    .gap(px(4.))
                    .child(conduit_components::views::kit::heading(
                        "add-account-title",
                        title.clone(),
                        1,
                        t.metrics.control + 3.,
                        FontWeight::SEMIBOLD,
                        r.text,
                    ))
                    .child(
                        div()
                            .text_size(px(t.metrics.control))
                            .text_color(r.text_subtle)
                            .child(l10n.desktop_server_form_subtitle()),
                    )
                    .into_any_element()
            } else {
                title_block(&title, &l10n.desktop_server_form_subtitle(), false, cx)
                    .into_any_element()
            })
            .child(form_group(
                vec![
                    field(
                        l10n.desktop_server_address(),
                        &self.url,
                        Some(l10n.desktop_server_url_help().into()),
                        self.url_error.clone().map(Into::into),
                        window,
                        cx,
                    )
                    .into_any_element(),
                    field(
                        l10n.desktop_server_name(),
                        &self.name,
                        Some(l10n.desktop_server_name_help().into()),
                        None,
                        window,
                        cx,
                    )
                    .into_any_element(),
                ],
                cx,
            ))
            .child(
                div()
                    .id("advanced")
                    .role(Role::Button)
                    .aria_label(l10n.desktop_advanced_settings())
                    .aria_expanded(self.advanced)
                    // As wide as its label, so its focus ring is too.
                    .self_start()
                    .flex()
                    .items_center()
                    .gap(px(4.))
                    .cursor_pointer()
                    .text_size(px(t.metrics.control))
                    .font_weight(FontWeight::MEDIUM)
                    .text_color(t.roles.text)
                    .keyboard_outline(4., cx)
                    .child(conduit_components::assets::icon(
                        if self.advanced {
                            IconName::ChevronDown
                        } else {
                            IconName::ChevronRight
                        },
                        13.,
                        t.roles.text_subtle,
                    ))
                    .child(l10n.desktop_advanced_settings())
                    .on_click(toggle_advanced),
            )
            .children(advanced)
            .when_some(self.error.clone(), |d, e| {
                d.child(form_error("server-error", e, cx))
            })
            .child(form_buttons(
                [
                    self.adding.then(|| {
                        Button::new("cancel-add", back_label)
                            .on_click(back)
                            .into_any_element()
                    }),
                    Some(
                        Button::new(
                            "connect",
                            if self.busy {
                                l10n.desktop_connecting()
                            } else {
                                l10n.desktop_connect()
                            },
                        )
                        .primary()
                        .disabled(!self.can_connect(cx))
                        .on_click(connect)
                        .into_any_element(),
                    ),
                ]
                .into_iter()
                .flatten()
                .collect(),
            ))
    }
}

#[cfg(test)]
mod undo_tests {
    use conduit_protocol::{AccountChangeOutcome, AccountChangeResult, methods};
    use gpui_kit::TestAppContext;
    use serde_json::json;

    use super::*;
    use crate::stores::accounts::tests::{account, list};
    use crate::stores::rpc::fake::FakeDaemon;

    #[gpui_kit::test]
    fn a_server_that_fails_its_check_never_stays_added(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        // Avery's account has no session, so the addition cannot be
        // abandoned back to it: Cancel leaves the new account in place.
        let mut adding = list(vec![
            account("a", "Avery", false, false),
            account("n", "New", true, false),
        ]);
        adding.adding_account = true;
        daemon.returns::<methods::AccountsAdd>(AccountChangeResult {
            outcome: AccountChangeOutcome::NeedsSignIn,
            accounts: adding.clone(),
        });
        daemon.returns::<methods::AccountsCancelAdd>(AccountChangeResult {
            outcome: AccountChangeOutcome::Unchanged,
            accounts: adding,
        });
        daemon.returns::<methods::AccountsRemove>(AccountChangeResult {
            outcome: AccountChangeOutcome::Done,
            accounts: list(vec![account("a", "Avery", true, false)]),
        });
        daemon.on::<methods::ServersStatus>(|_| {
            Ok(json!({
                "activeServerId": "n",
                "reachability": "notOpenWebUi",
                "maxSupportedVersion": "0.13.3",
            }))
        });
        daemon.returns::<methods::AccountsList>(list(vec![account("a", "Avery", true, false)]));
        let scratch =
            std::env::temp_dir().join(format!("conduit-server-form-{}", std::process::id()));
        let stores = cx.update(|cx| {
            crate::views::test_globals(cx);
            Stores::for_test(daemon.rpc(), &scratch, cx)
        });
        stores.accounts.update(cx, |a, cx| {
            a.adopt(list(vec![account("a", "Avery", true, false)]), cx)
        });
        let (view, vcx) = cx.add_window_view(move |window, cx| ServerForm::new(stores, window, cx));
        view.update_in(vcx, |v, window, cx| {
            v.url
                .update(cx, |i, cx| i.set_value("http://127.0.0.1:9", window, cx));
            v.submit(window, cx);
        });
        vcx.run_until_parked();
        assert_eq!(
            daemon.calls::<methods::AccountsRemove>(),
            vec![json!({"accountId": "n", "force": true})]
        );
        view.read_with(vcx, |v, _| assert!(v.error.is_some() && !v.busy));
    }

    #[gpui_kit::test]
    fn a_first_server_that_fails_its_check_says_so_and_nothing_of_signing_out(
        cx: &mut TestAppContext,
    ) {
        let daemon = FakeDaemon::new();
        let mut added = account("n", "New", true, false);
        added.user = None;
        added.connection.name = "127.0.0.1".into();
        daemon.returns::<methods::AccountsAdd>(AccountChangeResult {
            outcome: AccountChangeOutcome::NeedsSignIn,
            accounts: list(vec![added]),
        });
        daemon.returns::<methods::AccountsRemove>(AccountChangeResult {
            outcome: AccountChangeOutcome::NeedsSignIn,
            accounts: list(vec![]),
        });
        daemon.on::<methods::ServersStatus>(|_| {
            Ok(json!({
                "activeServerId": "n",
                "reachability": "unreachable",
                "errorCode": "net.connectionFailed",
                "maxSupportedVersion": "0.13.4",
            }))
        });
        daemon.returns::<methods::AccountsList>(list(vec![]));
        let scratch =
            std::env::temp_dir().join(format!("conduit-server-form-first-{}", std::process::id()));
        let stores = cx.update(|cx| {
            crate::views::test_globals(cx);
            let stores = Stores::for_test(daemon.rpc(), &scratch, cx);
            stores.toast_account_notices(
                |notice, cx| crate::views::words::account_notice(notice, cx.l10n()),
                cx,
            );
            stores
        });
        stores
            .accounts
            .update(cx, |a, cx| a.adopt(list(vec![]), cx));
        let toasts = stores.toasts.clone();
        let (view, vcx) = cx.add_window_view(move |window, cx| ServerForm::new(stores, window, cx));
        view.update_in(vcx, |v, window, cx| {
            v.url
                .update(cx, |i, cx| i.set_value("http://127.0.0.1:9", window, cx));
            v.submit(window, cx);
        });
        vcx.run_until_parked();
        assert_eq!(
            daemon.calls::<methods::AccountsRemove>(),
            vec![json!({"accountId": "n", "force": true})]
        );
        let l10n = L10n::new("en");
        view.read_with(vcx, |v, _| {
            assert_eq!(v.error, Some(l10n.desktop_couldnt_reach_server()));
        });
        // The undo removed an account nobody signed in to: no toast says
        // it signed out of anything.
        toasts.read_with(vcx, |t, _| {
            let shown: Vec<_> = t
                .toasts
                .iter()
                .map(|t| (t.level, t.message.clone()))
                .collect();
            assert_eq!(shown, vec![]);
        });
    }
}
