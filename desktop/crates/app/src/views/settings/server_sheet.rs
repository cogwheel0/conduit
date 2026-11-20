//! A saved Open WebUI server's sheet on Settings, as the phone's server
//! page (`server_address_settings_pages.dart`): its name, its accounts
//! (switch to one, sign out of one, add another on this server), and the
//! addresses it is reached at in the order they are tried.
//!
//! The addresses reorder by dragging a row, or with Move Up and Move Down
//! from its menu; one is removed from its menu after asking, and asked
//! again for the address in use while a reply arrives through it. A row
//! opens its editor in the same sheet (AppKit hangs one sheet at a time):
//! a name, the URL, and Advanced (an unverified certificate, a client
//! certificate and key picked with the open panel, the key's password,
//! custom headers), the server form's own fields. Save Address checks the
//! address and saves it through the core (`servers.addresses.check` and
//! `.save`): it asks before an account's session goes to a host the server
//! was never reached at, and before the address in use changes mid-reply;
//! a refusal stays on the editor in the phone's words. An address behind a
//! sign-in proxy goes to the proxy's sign-in window first, and is saved
//! with what that captured. The sheet closes when its server is gone.
//!
//! Secrets never come back from the daemon: a saved header value, client
//! key or key password shows as configured, and is kept unless replaced.

use std::rc::Rc;

use conduit_components::ActiveConduitTheme as _;
use conduit_components::announce::{Priority, announce};
use conduit_components::assets::{IconName, icon};
use conduit_components::views::focus::{ControlExt as _, pressed_fill};
use conduit_components::views::kit::{Button, IconButton, badge};
use conduit_components::views::settings::{AccountActions, accounts_list_with, settings_section};
use conduit_daemon::RpcError;
use conduit_protocol::{
    Event, ExternalAuthCompletion, ServerAddressChangeOutcome, ServerAddressCheckOutcome,
    ServerAddressCheckRequest, ServerAddressConfirmation, ServerAddressDto,
    ServerAddressEditResult, ServerAddressForm, ServerAddressHeader, ServerAddressRemoveRequest,
    ServerAddressReorderRequest, ServerAddressSaveRequest, ServerAddresses, ServerDraft, ServerRef,
    events, methods,
};
use gpui_kit::component::input::{InputEvent, InputState};
use gpui_kit::component::native_menu::NativeMenu;
use gpui_kit::prelude::*;
use gpui_kit::{
    AnyElement, AnyWindowHandle, App, AsyncApp, AsyncWindowContext, Context, Entity, EventEmitter,
    FocusHandle, Focusable, FontWeight, Pixels, Point, Role, SharedString, Subscription,
    WeakEntity, Window, div, px,
};

use crate::actions::SettingsChoice;
use crate::l10n::{ActiveL10n as _, L10n};
use crate::shell::sheet::{SheetSpec, present_sheet};
use crate::shell::sso::{SsoOutcome, run_proxy_sso};
use crate::stores::Stores;
use crate::stores::accounts::{AccountChange, display_name};
use crate::stores::connection::ConnectionEvent;
use crate::stores::rpc::Rpc;
use crate::views::accounts::{account_row, change_account, remove_account};
use crate::views::forms::{self, PemFile};
use crate::views::server_form::{AdvancedFields, HasAdvanced, advanced_section};
use crate::views::sheet::{self, SheetBody};
use crate::views::{privacy, words};

/// The sheet's width: an address and its badge, and the editor's fields.
pub const WIDTH: f32 = 560.;
/// The `SettingsChoice` menu of an address row (`<command>:<address id>`).
const ADDRESS_MENU: &str = "server-address";
/// The `SettingsChoice` menu of an account row (the account's id).
const ACCOUNT_MENU: &str = "server-account";

/// Opens `server_id`'s sheet on `window` (Settings). Another sheet already
/// down keeps the keyboard, and None comes back.
pub fn open(
    stores: &Stores,
    server_id: &str,
    window: &mut Window,
    cx: &mut App,
) -> Option<Entity<ServerSheet>> {
    let stores = stores.clone();
    let server_id = server_id.to_string();
    let parent = window.window_handle();
    sheet::open(window, WIDTH, cx, move |window, cx| {
        ServerSheet::new(stores, server_id, parent, window, cx)
    })
}

/// What an address row is called: its name, else its host.
pub fn address_title(address: &ServerAddressDto) -> String {
    address
        .label
        .as_deref()
        .map(str::trim)
        .filter(|l| !l.is_empty())
        .map(str::to_string)
        .unwrap_or_else(|| forms::host_of(&address.url))
}

/// `ids` with the address at `from` moved to `to` (both indexes into it).
pub fn moved(ids: &[String], from: usize, to: usize) -> Vec<String> {
    let mut out = ids.to_vec();
    if from < out.len() && to < out.len() && from != to {
        let id = out.remove(from);
        out.insert(to, id);
    }
    out
}

/// An address row being dragged.
#[derive(Clone, Debug)]
pub struct DraggedAddress {
    pub index: usize,
    pub title: SharedString,
    grab: Point<Pixels>,
}

impl Render for DraggedAddress {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let t = cx.conduit().clone();
        div().pl(self.grab.x).pt(self.grab.y).child(
            div()
                .px(px(10.))
                .py(px(6.))
                .rounded(px(6.))
                .bg(t.surfaces.menu)
                .border_1()
                .border_color(t.roles.border)
                .shadow_md()
                .text_size(px(t.metrics.control))
                .text_color(t.roles.text)
                .child(self.title.clone()),
        )
    }
}

pub struct ServerSheet {
    stores: Stores,
    pub server_id: String,
    pub addresses: Option<ServerAddresses>,
    /// Why the addresses could not be read or changed.
    pub notice: Option<String>,
    /// The server's name, saved with Done when changed.
    pub name: Entity<InputState>,
    name_saved: String,
    /// The name was read into its field ([`Self::load`]): until then it
    /// takes no typing, which the read would write over. A refresh of the
    /// addresses reads no name; a failed read leaves it unread.
    name_read: bool,
    /// The address editor in front, when one is open.
    pub editor: Option<Entity<AddressEditor>>,
    /// A rename, reorder or removal is on its way (set when it starts,
    /// cleared when it ends; a removal from its question on).
    pub busy: bool,
    /// The window the sheet hangs on, which outlives it: what the sheet
    /// starts and must ask about after it is gone asks there.
    parent: AnyWindowHandle,
    focus: FocusHandle,
    _subscriptions: Vec<Subscription>,
}

impl ServerSheet {
    fn new(
        stores: Stores,
        server_id: String,
        parent: AnyWindowHandle,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Self {
        let l10n = cx.l10n().clone();
        let name = forms::input(l10n.desktop_server_name(), false, window, cx);
        stores.connection.update(cx, |c, _| {
            c.subscribe("server-sheet", &[events::SERVERS_CHANGED], vec![])
        });
        let subscriptions = vec![
            // Its server changed elsewhere (or the address in use did).
            cx.subscribe(&stores.connection, |this, _, event, cx| match event {
                ConnectionEvent::Daemon(event) => {
                    if let Event::ServersChanged(changed) = event.as_ref()
                        && changed
                            .server_id
                            .as_deref()
                            .is_none_or(|id| id == this.server_id)
                    {
                        this.refresh(cx);
                    }
                }
                ConnectionEvent::Connected { .. } | ConnectionEvent::Gap => this.refresh(cx),
                _ => {}
            }),
            // An account signed out of, added or switched to: its rows; and
            // when the last account on the server went, the server and its
            // sheet go too.
            cx.observe(&stores.accounts, |this, accounts, cx| {
                let store = accounts.read(cx);
                let loaded = store.list.is_some();
                let gone = loaded
                    && store.busy.is_none()
                    && !store
                        .accounts()
                        .iter()
                        .any(|a| a.server_id == this.server_id);
                if gone {
                    sheet::dismiss(cx);
                } else {
                    this.refresh(cx);
                }
            }),
        ];
        let focus = cx.focus_handle();
        window.focus(&focus, cx);
        let mut this = Self {
            stores,
            server_id,
            addresses: None,
            notice: None,
            name,
            name_saved: String::new(),
            name_read: false,
            editor: None,
            busy: false,
            parent,
            focus,
            _subscriptions: subscriptions,
        };
        this.load(window, cx);
        this
    }

    /// Reads the addresses, and the name into its field (once).
    fn load(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let rpc = self.stores.connection.read(cx).rpc();
        let call = rpc.call::<methods::ServersAddressesList>(&ServerRef {
            server_id: self.server_id.clone(),
        });
        cx.spawn_in(
            window,
            async move |this: WeakEntity<Self>, cx: &mut AsyncWindowContext| {
                let result = call.await;
                let _ = this.update_in(cx, |s, window, cx| {
                    match result {
                        Ok(addresses) => {
                            s.name_saved = addresses.name.clone();
                            let name = addresses.name.clone();
                            s.name.update(cx, |i, cx| i.set_value(name, window, cx));
                            s.name_read = true;
                            s.addresses = Some(addresses);
                        }
                        Err(e) => s.notice = Some(words::connect_error(&e, cx.l10n())),
                    }
                    cx.notify();
                });
            },
        )
        .detach();
    }

    /// Reads the addresses again (the name field keeps what is typed).
    pub fn refresh(&mut self, cx: &mut Context<Self>) {
        let rpc = self.stores.connection.read(cx).rpc();
        let call = rpc.call::<methods::ServersAddressesList>(&ServerRef {
            server_id: self.server_id.clone(),
        });
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            if let Ok(addresses) = call.await {
                let _ = this.update(cx, |s, cx| {
                    s.addresses = Some(addresses);
                    cx.notify();
                });
            }
        })
        .detach();
    }

    fn rpc(&self, cx: &App) -> Rpc {
        self.stores.connection.read(cx).rpc()
    }

    fn address(&self, id: &str) -> Option<&ServerAddressDto> {
        self.addresses
            .as_ref()?
            .addresses
            .iter()
            .find(|a| a.id == id)
    }

    /// Opens the editor of `id`, or of a new address.
    pub fn edit(&mut self, id: Option<&str>, window: &mut Window, cx: &mut Context<Self>) {
        if self.busy {
            return;
        }
        let saved = id.and_then(|id| self.address(id)).cloned();
        let stores = self.stores.clone();
        let server_id = self.server_id.clone();
        let removable = self.addresses.as_ref().is_some_and(|a| a.removable);
        let editor = cx.new(|cx| {
            let mut e = AddressEditor::new(stores, server_id, saved, window, cx);
            e.removable = removable;
            e
        });
        self._subscriptions.push(cx.subscribe_in(
            &editor,
            window,
            |this, _, event: &EditorEvent, window, cx| this.on_editor(event, window, cx),
        ));
        let url = editor.read(cx).url.clone();
        window.on_next_frame(move |window, cx| {
            let handle = gpui_kit::Focusable::focus_handle(url.read(cx), cx);
            window.focus(&handle, cx);
        });
        self.editor = Some(editor);
        cx.notify();
    }

    fn on_editor(&mut self, event: &EditorEvent, window: &mut Window, cx: &mut Context<Self>) {
        match event {
            EditorEvent::Back => {}
            EditorEvent::Saved(addresses) => {
                self.addresses = Some((**addresses).clone());
                self.notice = None;
                announce(cx.l10n().desktop_address_saved(), Priority::High, cx);
            }
            EditorEvent::Removed(addresses) => {
                self.addresses = Some((**addresses).clone());
                self.notice = None;
                announce(cx.l10n().desktop_address_removed(), Priority::High, cx);
            }
        }
        self.editor = None;
        window.focus(&self.focus, cx);
        cx.notify();
    }

    /// Puts the addresses in `order`.
    pub fn reorder(&mut self, order: Vec<String>, window: &mut Window, cx: &mut Context<Self>) {
        if self.busy {
            return;
        }
        // Shown in the new order at once; the daemon's answer follows.
        if let Some(a) = self.addresses.as_mut() {
            let mut rows = std::mem::take(&mut a.addresses);
            for id in &order {
                if let Some(i) = rows.iter().position(|r| &r.id == id) {
                    a.addresses.push(rows.remove(i));
                }
            }
            a.addresses.append(&mut rows);
        }
        self.busy = true;
        cx.notify();
        let call =
            self.rpc(cx)
                .call::<methods::ServersAddressesReorder>(&ServerAddressReorderRequest {
                    server_id: self.server_id.clone(),
                    order,
                });
        cx.spawn_in(
            window,
            async move |this: WeakEntity<Self>, cx: &mut AsyncWindowContext| {
                let result = call.await;
                let _ = this.update(cx, |s, cx| {
                    s.busy = false;
                    s.finish_edit(result, cx);
                });
            },
        )
        .detach();
    }

    fn finish_edit(
        &mut self,
        result: Result<ServerAddressEditResult, RpcError>,
        cx: &mut Context<Self>,
    ) {
        match result {
            Ok(r) => {
                self.addresses = Some(r.addresses);
                self.notice = None;
            }
            Err(e) => {
                self.notice = Some(words::connect_error(&e, cx.l10n()));
                self.refresh(cx);
            }
        }
        cx.notify();
    }

    /// Moves address `id` by `by` places (−1 up, +1 down).
    pub fn nudge(&mut self, id: &str, by: isize, window: &mut Window, cx: &mut Context<Self>) {
        let Some(a) = &self.addresses else { return };
        let ids: Vec<String> = a.addresses.iter().map(|r| r.id.clone()).collect();
        let Some(from) = ids.iter().position(|i| i == id) else {
            return;
        };
        let to = from as isize + by;
        if to < 0 || to as usize >= ids.len() {
            return;
        }
        let order = moved(&ids, from, to as usize);
        let count = ids.len();
        let title = self.address(id).map(address_title).unwrap_or_default();
        self.reorder(order, window, cx);
        crate::views::a11y::announce_row(&title, to as usize, count, cx);
    }

    /// Removes address `id` after asking (and again for the address in use
    /// while a reply arrives through it).
    pub fn remove(&mut self, id: &str, window: &mut Window, cx: &mut Context<Self>) {
        let Some(address) = self.address(id).cloned() else {
            return;
        };
        if self.busy || !self.addresses.as_ref().is_some_and(|a| a.removable) {
            return;
        }
        let server_id = self.server_id.clone();
        let rpc = self.rpc(cx);
        let handle = cx.entity().downgrade();
        self.busy = true;
        cx.notify();
        ask_and_remove(rpc, server_id, address, window, cx, move |result, cx| {
            let _ = handle.update(cx, |s, cx| {
                s.busy = false;
                cx.notify();
                if let Some(Ok(r)) = &result
                    && r.outcome == ServerAddressChangeOutcome::Done
                {
                    announce(cx.l10n().desktop_address_removed(), Priority::High, cx);
                }
                if let Some(result) = result {
                    s.finish_edit(result, cx);
                }
            });
        });
    }

    /// Done: the name saved when it changed, then the sheet closes.
    pub fn done(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.busy {
            return;
        }
        let name = forms::text(&self.name, cx);
        if name.is_empty() || name == self.name_saved {
            sheet::dismiss(cx);
            return;
        }
        // `servers.update` with the server's id renames it, nothing else.
        let call = self.rpc(cx).call::<methods::ServersUpdate>(&ServerDraft {
            id: Some(self.server_id.clone()),
            name,
            url: String::new(),
            allow_self_signed_certificates: false,
            mtls_certificate_chain_pem: None,
            mtls_certificate_label: None,
            mtls_private_key_pem: None,
            mtls_private_key_label: None,
            mtls_private_key_password: None,
            clear_mutual_tls: false,
            custom_headers: None,
        });
        self.busy = true;
        cx.notify();
        let accounts = self.stores.accounts.clone();
        cx.spawn_in(
            window,
            async move |this: WeakEntity<Self>, cx: &mut AsyncWindowContext| {
                let result = call.await;
                let _ = this.update(cx, |s, cx| {
                    s.busy = false;
                    match result {
                        Ok(_) => {
                            accounts.update(cx, |a, cx| a.refresh(cx));
                            sheet::dismiss(cx);
                        }
                        Err(e) => {
                            s.notice = Some(words::connect_error(&e, cx.l10n()));
                            cx.notify();
                        }
                    }
                });
            },
        )
        .detach();
    }

    /// Add Account on This Server: a new account on it, whose sign-in
    /// follows in the main window. A name typed and not saved is asked
    /// about first, as Esc asks: kept, the sheet stays and nothing is added.
    /// The change runs from the window the sheet hangs on, so a reply
    /// running is asked about there once the sheet is gone.
    pub fn add_account(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(first) = self.addresses.as_ref().and_then(|a| a.addresses.first()) else {
            return;
        };
        let change = AccountChange::AddOnServer {
            server_id: self.server_id.clone(),
            server: Box::new(ServerDraft {
                id: None,
                name: self
                    .addresses
                    .as_ref()
                    .map(|a| a.name.clone())
                    .unwrap_or_default(),
                url: first.url.clone(),
                allow_self_signed_certificates: first.allow_self_signed_certificates,
                mtls_certificate_chain_pem: None,
                mtls_certificate_label: None,
                mtls_private_key_pem: None,
                mtls_private_key_label: None,
                mtls_private_key_password: None,
                clear_mutual_tls: false,
                custom_headers: None,
            }),
        };
        let stores = self.stores.clone();
        let parent = self.parent;
        let add = move |cx: &mut App| {
            sheet::dismiss(cx);
            // Once the update in progress ends: the parent may be the window
            // being updated now.
            cx.defer(move |cx| {
                let _ = parent.update(cx, |_, window, cx| {
                    change_account(&stores, change, window, cx)
                });
                crate::windows::sync(cx);
                crate::windows::show_front(cx);
            });
        };
        if !self.renamed(cx) {
            add(cx);
            return;
        }
        let ask = present_sheet(window, discard_name(cx.l10n()), cx);
        cx.spawn(async move |_, cx: &mut AsyncApp| {
            if ask.await {
                cx.update(add);
            }
        })
        .detach();
    }

    fn on_choice(&mut self, choice: &SettingsChoice, window: &mut Window, cx: &mut Context<Self>) {
        match choice.menu.as_str() {
            ADDRESS_MENU => {
                let Some((command, id)) = choice.value.split_once(':') else {
                    return;
                };
                match command {
                    "edit" => self.edit(Some(id), window, cx),
                    "up" => self.nudge(id, -1, window, cx),
                    "down" => self.nudge(id, 1, window, cx),
                    "remove" => self.remove(id, window, cx),
                    _ => {}
                }
            }
            ACCOUNT_MENU => remove_account(&self.stores, &choice.value, window, cx),
            _ => {}
        }
    }

    fn address_menu(&self, id: &str, window: &mut Window, cx: &mut App) {
        let l = cx.l10n().clone();
        let Some(a) = &self.addresses else { return };
        let index = a.addresses.iter().position(|r| r.id == id).unwrap_or(0);
        let item = |command: &str| {
            Box::new(SettingsChoice {
                menu: ADDRESS_MENU.into(),
                value: format!("{command}:{id}"),
            })
        };
        let mut menu = NativeMenu::new().menu(l.desktop_edit_address_ellipsis(), item("edit"));
        if a.addresses.len() > 1 {
            menu = menu.separator();
            if index > 0 {
                menu = menu.menu(l.desktop_move_up(), item("up"));
            }
            if index + 1 < a.addresses.len() {
                menu = menu.menu(l.desktop_move_down(), item("down"));
            }
        }
        if a.removable {
            menu = menu
                .separator()
                .menu(l.desktop_remove_address_ellipsis(), item("remove"));
        }
        menu.show(window.mouse_position(), window, cx);
    }

    fn accounts_group(&self, cx: &mut Context<Self>) -> AnyElement {
        let l10n = cx.l10n().clone();
        let store = self.stores.accounts.read(cx);
        let libre_chat = store.libre_chat_in_charge();
        let rows: Vec<_> = store
            .accounts()
            .iter()
            .filter(|a| a.server_id == self.server_id)
            .map(|a| {
                let mut row = account_row(a, cx);
                row.active &= !libre_chat;
                row
            })
            .collect();
        let busy = store
            .busy
            .as_ref()
            .and_then(|c| c.account_id().map(|id| SharedString::from(id.to_string())));
        let stores = self.stores.clone();
        let switch = Rc::new(move |id: &str, window: &mut Window, cx: &mut App| {
            change_account(
                &stores,
                AccountChange::Switch {
                    account_id: id.to_string(),
                },
                window,
                cx,
            );
        });
        let stores = self.stores.clone();
        let sign_in = Rc::new(move |id: &str, window: &mut Window, cx: &mut App| {
            change_account(
                &stores,
                AccountChange::Switch {
                    account_id: id.to_string(),
                },
                window,
                cx,
            );
            crate::open_main_window(cx);
        });
        let stores = self.stores.clone();
        let more = Rc::new(move |id: &str, window: &mut Window, cx: &mut App| {
            let name = stores
                .accounts
                .read(cx)
                .accounts()
                .iter()
                .find(|a| a.id == id)
                .map(display_name);
            let Some(name) = name else { return };
            let name = privacy::name(&name, cx);
            NativeMenu::new()
                .menu(
                    cx.l10n().desktop_sign_out_of(&name),
                    Box::new(SettingsChoice {
                        menu: ACCOUNT_MENU.into(),
                        value: id.to_string(),
                    }),
                )
                .show(window.mouse_position(), window, cx);
        });
        let actions = AccountActions {
            on_switch: Some(switch),
            on_sign_in: Some(sign_in),
            on_more: Some(more),
            busy,
        };
        let view = cx.entity().downgrade();
        let add = Button::new(
            "server-add-account",
            l10n.desktop_add_account_on_this_server_ellipsis(),
        )
        .icon(IconName::UserPlus)
        .disabled(self.busy || self.addresses.is_none())
        .on_click(Rc::new(move |_, window, cx| {
            let _ = view.update(cx, |s, cx| s.add_account(window, cx));
        }));
        settings_section(
            l10n.accounts_title(),
            None,
            vec![
                accounts_list_with(&rows, &actions, cx).into_any_element(),
                div().pt(px(8.)).child(add).into_any_element(),
            ],
            cx,
        )
        .into_any_element()
    }

    fn address_rows(&self, cx: &mut Context<Self>) -> AnyElement {
        let l10n = cx.l10n().clone();
        let t = cx.conduit().clone();
        let r = t.roles;
        let Some(addresses) = &self.addresses else {
            return div().into_any_element();
        };
        let count = addresses.addresses.len();
        let draggable = count > 1 && !self.busy;
        let ids: Vec<String> = addresses.addresses.iter().map(|a| a.id.clone()).collect();
        let hover = r.hover;
        let pressed = pressed_fill(r.hover, &t);
        let rows: Vec<AnyElement> = addresses
            .addresses
            .iter()
            .enumerate()
            .map(|(i, a)| {
                let title = address_title(a);
                let id = a.id.clone();
                let view = cx.entity().downgrade();
                let open = {
                    let view = view.clone();
                    let id = id.clone();
                    move |_: &gpui_kit::ClickEvent, window: &mut Window, cx: &mut App| {
                        let _ = view.update(cx, |s, cx| s.edit(Some(&id), window, cx));
                    }
                };
                let menu = {
                    let view = view.clone();
                    let id = id.clone();
                    Rc::new(
                        move |_: &gpui_kit::ClickEvent, window: &mut Window, cx: &mut App| {
                            let _ = view.update(cx, |s, cx| s.address_menu(&id, window, cx));
                        },
                    )
                };
                let label = [
                    title.clone(),
                    privacy::host(&a.url, cx),
                    if a.in_use {
                        l10n.accounts_address_in_use()
                    } else {
                        String::new()
                    },
                ]
                .into_iter()
                .filter(|s| !s.is_empty())
                .collect::<Vec<_>>()
                .join(", ");
                let ids = ids.clone();
                let mut row = div()
                    .id(SharedString::from(format!("server-address-{i}")))
                    .role(Role::Button)
                    .aria_label(SharedString::from(label))
                    .w_full()
                    .px(px(12.))
                    .py(px(9.))
                    .flex()
                    .items_center()
                    .gap(px(10.))
                    .cursor_pointer()
                    .hover(move |s| s.bg(hover))
                    .active(move |s| s.bg(pressed))
                    .when(i > 0, |d| d.border_t_1().border_color(r.divider))
                    .keyboard_shadow(cx)
                    .tip(l10n.desktop_edit_address_ellipsis(), None)
                    .on_click(open)
                    .child(icon(
                        if a.in_use {
                            IconName::CircleCheck
                        } else {
                            IconName::Network
                        },
                        15.,
                        if a.in_use { r.text } else { r.text_subtle },
                    ))
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .flex()
                            .flex_col()
                            .gap(px(1.))
                            .child(
                                div()
                                    .truncate()
                                    .text_size(px(t.metrics.control))
                                    .font_weight(FontWeight::MEDIUM)
                                    .text_color(r.text)
                                    .child(privacy::host(&title, cx)),
                            )
                            .child(
                                div()
                                    .truncate()
                                    .font_family(conduit_components::theme::MONO_FONT)
                                    .text_size(px(t.metrics.small))
                                    .text_color(r.text_subtle)
                                    .child(privacy::host(&a.url, cx)),
                            ),
                    )
                    .when(a.in_use, |d| {
                        d.child(badge(
                            l10n.accounts_address_in_use(),
                            conduit_components::theme::with_alpha(
                                r.text,
                                if t.dark { 0.14 } else { 0.07 },
                            ),
                            r.text_subtle,
                            cx,
                        ))
                    })
                    .child(
                        IconButton::new(
                            SharedString::from(format!("server-address-menu-{i}")),
                            IconName::Ellipsis,
                            l10n.desktop_more_actions_for(&title),
                        )
                        .size(24., 15.)
                        .on_click(menu),
                    );
                if draggable {
                    let dragged = DraggedAddress {
                        index: i,
                        title: privacy::host(&title, cx).into(),
                        grab: Point::default(),
                    };
                    let view = view.clone();
                    row = row
                        .on_drag(dragged, |d: &DraggedAddress, grab, _, cx| {
                            cx.new(|_| DraggedAddress { grab, ..d.clone() })
                        })
                        .drag_over::<DraggedAddress>(move |s, _, _, _| s.bg(hover))
                        .on_drop(move |d: &DraggedAddress, window, cx| {
                            let order = moved(&ids, d.index, i);
                            let _ = view.update(cx, |s, cx| s.reorder(order, window, cx));
                        });
                }
                row.into_any_element()
            })
            .collect();
        let view = cx.entity().downgrade();
        let add = Button::new("server-add-address", l10n.desktop_add_address_ellipsis())
            .icon(IconName::Plus)
            .disabled(self.busy)
            .on_click(Rc::new(move |_, window, cx| {
                let _ = view.update(cx, |s, cx| s.edit(None, window, cx));
            }));
        settings_section(
            l10n.accounts_server_addresses(),
            Some(l10n.accounts_server_addresses_help().into()),
            vec![
                conduit_components::views::kit::grouped(rows, cx).into_any_element(),
                div().pt(px(8.)).child(add).into_any_element(),
            ],
            cx,
        )
        .into_any_element()
    }
}

/// Asks before removing `address` (and again while a reply arrives
/// through it), then removes it; `then` gets the answer, None when the
/// user chose not to.
fn ask_and_remove<V: 'static>(
    rpc: Rpc,
    server_id: String,
    address: ServerAddressDto,
    window: &mut Window,
    cx: &mut Context<V>,
    then: impl FnOnce(Option<Result<ServerAddressEditResult, RpcError>>, &mut App) + 'static,
) {
    let l10n = cx.l10n().clone();
    let name = privacy::host(&address_title(&address), cx);
    let spec = SheetSpec::new(
        l10n.desktop_remove_address_title(&name),
        l10n.accounts_remove_address_message(),
        l10n.accounts_remove_address(),
        l10n.cancel(),
    )
    .destructive();
    let ask = present_sheet(window, spec, cx);
    cx.spawn_in(
        window,
        async move |_: WeakEntity<V>, cx: &mut AsyncWindowContext| {
            if !ask.await {
                let _ = cx.update(|_, cx| then(None, cx));
                return;
            }
            let mut request = ServerAddressRemoveRequest {
                server_id,
                endpoint_id: address.id,
                stop_replies: false,
            };
            loop {
                let result = rpc.call::<methods::ServersAddressesRemove>(&request).await;
                let asks = matches!(
                    &result,
                    Ok(r) if r.outcome == ServerAddressChangeOutcome::NeedsConfirmation
                );
                if !asks || request.stop_replies {
                    let _ = cx.update(|_, cx| then(Some(result), cx));
                    return;
                }
                let spec = reply_spec(&l10n);
                let Ok(ask) = cx.update(|window, cx| present_sheet(window, spec, cx)) else {
                    return;
                };
                if !ask.await {
                    let _ = cx.update(|_, cx| then(None, cx));
                    return;
                }
                request.stop_replies = true;
            }
        },
    )
    .detach();
}

/// The sheet asking before the address in use changes while a reply
/// arrives through it.
fn reply_spec(l10n: &L10n) -> SheetSpec {
    SheetSpec::new(
        l10n.accounts_reply_in_progress_title(),
        l10n.accounts_address_change_stops_reply(),
        l10n.accounts_address_change_anyway(),
        l10n.cancel(),
    )
    .destructive()
}

impl Focusable for ServerSheet {
    fn focus_handle(&self, _: &App) -> FocusHandle {
        self.focus.clone()
    }
}

/// The question before a name typed and not saved goes (Esc, Add Account
/// on This Server).
fn discard_name(l10n: &L10n) -> SheetSpec {
    SheetSpec::new(
        l10n.desktop_discard_changes_title(),
        l10n.desktop_discard_changes_message(),
        l10n.desktop_discard(),
        l10n.cancel(),
    )
    .destructive()
}

impl ServerSheet {
    /// A new name typed and not saved yet (Done saves it).
    fn renamed(&self, cx: &App) -> bool {
        let name = forms::text(&self.name, cx);
        self.addresses.is_some() && !name.is_empty() && name != self.name_saved
    }
}

impl SheetBody for ServerSheet {
    /// A rename, reorder or removal on its way, or the address editor's
    /// save or removal.
    fn busy(&self, cx: &App) -> bool {
        self.busy || self.editor.as_ref().is_some_and(|e| e.read(cx).busy)
    }

    /// A name typed and not saved, or an address edited and not saved.
    fn unsaved(&self, cx: &App) -> bool {
        self.renamed(cx)
            || self
                .editor
                .as_ref()
                .is_some_and(|e| e.read(cx).is_dirty(cx))
    }

    fn cancel(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if let Some(editor) = self.editor.clone() {
            editor.update(cx, |e, cx| e.cancel(window, cx));
            return;
        }
        if self.busy {
            return;
        }
        if !self.renamed(cx) {
            sheet::dismiss(cx);
            return;
        }
        let ask = present_sheet(window, discard_name(cx.l10n()), cx);
        cx.spawn(async move |_, cx: &mut AsyncApp| {
            if ask.await {
                cx.update(sheet::dismiss);
            }
        })
        .detach();
    }

    fn label(&self, cx: &App) -> SharedString {
        if let Some(editor) = &self.editor {
            return editor.read(cx).title(cx).into();
        }
        self.addresses
            .as_ref()
            .map(|a| privacy::host(&a.name, cx).into())
            .unwrap_or_else(|| cx.l10n().desktop_server_settings_ellipsis().into())
    }

    fn footer(&mut self, window: &mut Window, cx: &mut Context<Self>) -> Option<AnyElement> {
        if let Some(editor) = self.editor.clone() {
            return Some(editor.update(cx, |e, cx| e.footer(window, cx)));
        }
        let l10n = cx.l10n().clone();
        let view = cx.entity().downgrade();
        Some(
            div()
                .w_full()
                .flex()
                .items_center()
                .gap(px(8.))
                .child(div().flex_1())
                .child(
                    Button::new("server-done", l10n.done())
                        .primary()
                        .disabled(self.busy)
                        .on_click(Rc::new(move |_, window, cx| {
                            let _ = view.update(cx, |s, cx| s.done(window, cx));
                        })),
                )
                .into_any_element(),
        )
    }
}

impl Render for ServerSheet {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let root = div()
            .id("server-sheet")
            .track_focus(&self.focus)
            .w_full()
            .on_action(
                cx.listener(|this, a: &SettingsChoice, window, cx| this.on_choice(a, window, cx)),
            );
        if let Some(editor) = &self.editor {
            return root.child(editor.clone());
        }
        let l10n = cx.l10n().clone();
        let t = cx.conduit().clone();
        let title = self
            .addresses
            .as_ref()
            .map(|a| privacy::host(&a.name, cx))
            .unwrap_or_default();
        root.flex()
            .flex_col()
            .gap(px(16.))
            .child(
                div()
                    .id("sheet-title")
                    .role(Role::Heading)
                    .text_size(px(t.metrics.body + 2.))
                    .font_weight(FontWeight::SEMIBOLD)
                    .child(title),
            )
            .child(forms::form_group(
                vec![
                    // Not while Done saves it: it saves what was there when
                    // it was pressed.
                    forms::field_locked(
                        l10n.desktop_server_name(),
                        &self.name,
                        None,
                        None,
                        self.busy || !self.name_read,
                        window,
                        cx,
                    )
                    .into_any_element(),
                ],
                cx,
            ))
            .when_some(self.notice.clone(), |d, n| {
                d.child(forms::form_error("server-notice", n, cx))
            })
            .child(self.accounts_group(cx))
            .child(self.address_rows(cx))
    }
}

/// What the address editor tells its sheet.
#[derive(Clone, Debug)]
pub enum EditorEvent {
    /// Cancelled: back to the server's page.
    Back,
    /// Saved; the server's addresses now.
    Saved(Box<ServerAddresses>),
    /// Removed from the editor; the server's addresses now.
    Removed(Box<ServerAddresses>),
}

/// One address's editor: a name, the URL and Advanced.
pub struct AddressEditor {
    stores: Stores,
    server_id: String,
    /// The address being edited; None adds one.
    pub saved: Option<ServerAddressDto>,
    pub label: Entity<InputState>,
    pub url: Entity<InputState>,
    pub adv: AdvancedFields,
    pub advanced_open: bool,
    /// Header names whose saved value is kept unless one is typed.
    kept_headers: Vec<String>,
    /// The saved client certificate and key were cleared.
    tls_cleared: bool,
    /// Whether the server can do without this address.
    pub removable: bool,
    pub busy: bool,
    pub error: Option<String>,
    /// The form as it opened, to tell whether it was changed.
    initial: String,
    _subscriptions: Vec<Subscription>,
}

impl EventEmitter<EditorEvent> for AddressEditor {}

impl AddressEditor {
    fn new(
        stores: Stores,
        server_id: String,
        saved: Option<ServerAddressDto>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Self {
        let l10n = cx.l10n().clone();
        let label = forms::input(l10n.accounts_address_name_hint(), false, window, cx);
        let url = forms::input(l10n.server_url_hint(), false, window, cx);
        let mut adv = AdvancedFields::new(window, cx);
        let mut kept_headers = vec![];
        if let Some(a) = &saved {
            let (title, address) = (a.label.clone().unwrap_or_default(), a.url.clone());
            label.update(cx, |i, cx| i.set_value(title, window, cx));
            url.update(cx, |i, cx| i.set_value(address, window, cx));
            adv.self_signed = a.allow_self_signed_certificates;
            if a.has_mutual_tls_credentials {
                // Kept: named, never sent back (an empty text).
                adv.certificate = Some(PemFile {
                    label: a
                        .mtls_certificate_label
                        .clone()
                        .unwrap_or_else(|| "client-cert.pem".into()),
                    pem: String::new(),
                });
                adv.private_key = Some(PemFile {
                    label: a
                        .mtls_private_key_label
                        .clone()
                        .unwrap_or_else(|| "client-key.pem".into()),
                    pem: String::new(),
                });
                if a.has_private_key_password {
                    forms::set_hint(
                        &adv.key_password,
                        l10n.hermes_configured_replace_placeholder(),
                        cx,
                    );
                }
            }
            for name in &a.custom_header_names {
                adv.add_header(window, cx);
                let row = adv.headers.last().expect("just added");
                let n = name.clone();
                row.name.update(cx, |i, cx| i.set_value(n, window, cx));
                forms::set_hint(&row.value, l10n.hermes_configured_replace_placeholder(), cx);
                kept_headers.push(name.clone());
            }
        }
        let submit = |this: &mut Self,
                      _: &Entity<InputState>,
                      e: &InputEvent,
                      window: &mut Window,
                      cx: &mut Context<Self>| match e {
            InputEvent::PressEnter { .. } if !this.busy => this.save(window, cx),
            InputEvent::Change => {
                this.error = None;
                cx.notify();
            }
            _ => {}
        };
        let subscriptions = vec![
            cx.subscribe_in(&label, window, submit),
            cx.subscribe_in(&url, window, submit),
        ];
        let mut this = Self {
            stores,
            server_id,
            saved,
            label,
            url,
            adv,
            advanced_open: false,
            kept_headers,
            tls_cleared: false,
            removable: false,
            busy: false,
            error: None,
            initial: String::new(),
            _subscriptions: subscriptions,
        };
        this.initial = this.fingerprint(cx);
        this
    }

    fn title(&self, cx: &App) -> String {
        if self.saved.is_some() {
            cx.l10n().accounts_edit_address()
        } else {
            cx.l10n().accounts_add_address()
        }
    }

    /// What the form holds, to tell whether it changed.
    fn fingerprint(&self, cx: &App) -> String {
        let a = &self.adv;
        let file = |f: &Option<PemFile>| {
            f.as_ref()
                .map(|f| format!("{}:{}", f.label, f.pem.len()))
                .unwrap_or_default()
        };
        let headers: Vec<String> = a
            .headers
            .iter()
            .map(|r| format!("{}={}", forms::raw(&r.name, cx), forms::raw(&r.value, cx)))
            .collect();
        format!(
            "{}\u{1}{}\u{1}{}\u{1}{}\u{1}{}\u{1}{}\u{1}{}\u{1}{}",
            forms::raw(&self.label, cx),
            forms::raw(&self.url, cx),
            a.self_signed,
            file(&a.certificate),
            file(&a.private_key),
            forms::raw(&a.key_password, cx),
            headers.join("\u{2}"),
            self.tls_cleared,
        )
    }

    pub fn is_dirty(&self, cx: &App) -> bool {
        self.fingerprint(cx) != self.initial
    }

    /// The form as the daemon takes it: values it was never given, sent
    /// as None, are kept.
    pub fn form(&self, cx: &App) -> ServerAddressForm {
        let a = &self.adv;
        let headers = a
            .headers
            .iter()
            .filter_map(|r| {
                let name = forms::text(&r.name, cx);
                let value = forms::raw(&r.value, cx);
                if name.is_empty() && value.is_empty() {
                    return None;
                }
                let kept = value.is_empty() && self.kept_headers.contains(&name);
                Some(ServerAddressHeader {
                    name,
                    value: (!kept).then_some(value),
                })
            })
            .collect();
        let picked = |f: &Option<PemFile>| f.as_ref().filter(|f| !f.pem.is_empty()).cloned();
        let certificate = picked(&a.certificate);
        let key = picked(&a.private_key);
        let password = forms::raw(&a.key_password, cx);
        ServerAddressForm {
            url: forms::text(&self.url, cx),
            label: forms::text(&self.label, cx),
            allow_self_signed_certificates: a.self_signed,
            headers,
            mtls_certificate_chain_pem: certificate.as_ref().map(|f| f.pem.clone()),
            mtls_certificate_label: certificate.map(|f| f.label),
            mtls_private_key_pem: key.as_ref().map(|f| f.pem.clone()),
            mtls_private_key_label: key.map(|f| f.label),
            mtls_private_key_password: (!password.is_empty()).then_some(password),
            clear_mutual_tls: self.tls_cleared,
        }
    }

    pub fn cancel(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.busy {
            return;
        }
        if !self.is_dirty(cx) {
            cx.emit(EditorEvent::Back);
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
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            if ask.await {
                let _ = this.update(cx, |_, cx| cx.emit(EditorEvent::Back));
            }
        })
        .detach();
    }

    fn fail(&mut self, error: String, header: bool, window: &mut Window, cx: &mut Context<Self>) {
        self.busy = false;
        self.error = Some(error);
        if header {
            self.advanced_open = true;
        }
        let field = if header {
            self.adv.headers.last().map(|r| r.name.clone())
        } else {
            None
        };
        forms::focus_invalid(&field.unwrap_or_else(|| self.url.clone()), window, cx);
        cx.notify();
    }

    /// Save Address: check, then save, asking what the core asks.
    pub fn save(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.busy {
            return;
        }
        self.busy = true;
        self.error = None;
        cx.notify();
        let rpc = self.stores.connection.read(cx).rpc();
        let l10n = cx.l10n().clone();
        let request = ServerAddressCheckRequest {
            server_id: self.server_id.clone(),
            endpoint_id: self.saved.as_ref().map(|a| a.id.clone()),
            form: self.form(cx),
        };
        let header_names: Vec<String> = request
            .form
            .headers
            .iter()
            .map(|h| h.name.clone())
            .collect();
        cx.spawn_in(
            window,
            async move |this: WeakEntity<Self>, cx: &mut AsyncWindowContext| {
                let fail = |cx: &mut AsyncWindowContext, text: String, header: bool| {
                    let _ = this.update_in(cx, |s, window, cx| s.fail(text, header, window, cx));
                };
                let stop = |cx: &mut AsyncWindowContext| {
                    let _ = this.update(cx, |s, cx| {
                        s.busy = false;
                        cx.notify();
                    });
                };
                let found = match rpc.call::<methods::ServersAddressesCheck>(&request).await {
                    Ok(f) => f,
                    Err(e) => return fail(cx, words::connect_error(&e, &l10n), false),
                };
                let check_id = found.check_id.clone().unwrap_or_default();
                let mut save = ServerAddressSaveRequest {
                    check_id,
                    send_session_confirmed: false,
                    stop_replies: false,
                    proxy: None,
                };
                match found.outcome {
                    ServerAddressCheckOutcome::Answered => {}
                    ServerAddressCheckOutcome::BehindProxy => {
                        let spec = SheetSpec::new(
                            l10n.proxy_auth_required(),
                            l10n.proxy_auth_required_description(),
                            l10n.authenticate_through_proxy(),
                            l10n.cancel(),
                        );
                        let Ok(ask) = cx.update(|window, cx| present_sheet(window, spec, cx))
                        else {
                            return;
                        };
                        if !ask.await {
                            return stop(cx);
                        }
                        let url = found.url.clone().unwrap_or_default();
                        let title = l10n.desktop_sso_window_title(&forms::host_of(&url));
                        let Ok(sso) = cx.update(|_, cx| run_proxy_sso(&url, title, cx)) else {
                            return;
                        };
                        match sso.await {
                            SsoOutcome::Captured {
                                origin,
                                cookies,
                                token,
                            } => {
                                save.proxy = Some(ExternalAuthCompletion {
                                    origin,
                                    cookies: cookies.into_iter().collect(),
                                    token,
                                    // Only auth.renewProxy names the account.
                                    account: None,
                                })
                            }
                            _ => return fail(cx, l10n.proxy_auth_failed(), false),
                        }
                    }
                    _ => {
                        let header = found
                            .header_name
                            .as_ref()
                            .is_some_and(|h| header_names.contains(h))
                            || found.problem.is_some_and(is_header_problem);
                        return fail(cx, words::server_address_refusal(&found, &l10n), header);
                    }
                }
                loop {
                    let result = match rpc.call::<methods::ServersAddressesSave>(&save).await {
                        Ok(r) => r,
                        Err(e) => return fail(cx, words::connect_error(&e, &l10n), false),
                    };
                    match result.outcome {
                        ServerAddressChangeOutcome::Done => {
                            let _ = this.update(cx, |_, cx| match result.addresses {
                                Some(addresses) => cx.emit(EditorEvent::Saved(Box::new(addresses))),
                                None => cx.emit(EditorEvent::Back),
                            });
                            return;
                        }
                        ServerAddressChangeOutcome::NeedsConfirmation => {
                            let spec = match result.confirmation {
                                Some(ServerAddressConfirmation::ReplyInProgress) => {
                                    save.stop_replies = true;
                                    reply_spec(&l10n)
                                }
                                _ => {
                                    save.send_session_confirmed = true;
                                    SheetSpec::new(
                                        l10n.accounts_address_confirm_title(),
                                        l10n.accounts_address_confirm_message(
                                            &result.host.clone().unwrap_or_default(),
                                        ),
                                        l10n.accounts_address_confirm_action(),
                                        l10n.cancel(),
                                    )
                                }
                            };
                            let Ok(ask) = cx.update(|window, cx| present_sheet(window, spec, cx))
                            else {
                                return;
                            };
                            if !ask.await {
                                return stop(cx);
                            }
                            // Signed in through the proxy once: kept.
                            save.proxy = None;
                        }
                        _ => {
                            return match (result.problem, result.error_text) {
                                (Some(p), _) => {
                                    fail(cx, words::server_address_problem(p, None, &l10n), false)
                                }
                                (None, Some(text)) => fail(cx, text, false),
                                // The user chose not to go on.
                                (None, None) => stop(cx),
                            };
                        }
                    }
                }
            },
        )
        .detach();
    }

    /// Remove Address… from the editor.
    fn remove(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(saved) = self.saved.clone() else {
            return;
        };
        if self.busy {
            return;
        }
        let rpc = self.stores.connection.read(cx).rpc();
        let handle = cx.entity().downgrade();
        self.busy = true;
        cx.notify();
        ask_and_remove(
            rpc,
            self.server_id.clone(),
            saved,
            window,
            cx,
            move |result, cx| {
                let _ = handle.update(cx, |e, cx| {
                    e.busy = false;
                    cx.notify();
                    match result {
                        Some(Ok(r)) if r.outcome == ServerAddressChangeOutcome::Done => {
                            cx.emit(EditorEvent::Removed(Box::new(r.addresses)))
                        }
                        Some(Err(err)) => {
                            e.error = Some(words::connect_error(&err, cx.l10n()));
                            cx.notify();
                        }
                        _ => {}
                    }
                });
            },
        );
    }

    fn footer(&mut self, _: &mut Window, cx: &mut Context<Self>) -> AnyElement {
        let l10n = cx.l10n().clone();
        let view = cx.entity().downgrade();
        let remove = (self.saved.is_some() && self.removable).then(|| {
            let view = view.clone();
            Button::new("address-remove", l10n.desktop_remove_address_ellipsis())
                .disabled(self.busy)
                .on_click(Rc::new(move |_, window, cx| {
                    let _ = view.update(cx, |v, cx| v.remove(window, cx));
                }))
        });
        let cancel = {
            let view = view.clone();
            Button::new("address-cancel", l10n.cancel())
                .disabled(self.busy)
                .on_click(Rc::new(move |_, window, cx| {
                    let _ = view.update(cx, |v, cx| v.cancel(window, cx));
                }))
        };
        let save = Button::new(
            "address-save",
            if self.busy {
                l10n.desktop_connecting()
            } else {
                l10n.accounts_save_address()
            },
        )
        .primary()
        .disabled(self.busy || forms::text(&self.url, cx).is_empty())
        .on_click(Rc::new(move |_, window, cx| {
            let _ = view.update(cx, |v, cx| v.save(window, cx));
        }));
        div()
            .w_full()
            .flex()
            .items_center()
            .gap(px(8.))
            .children(remove)
            .child(div().flex_1())
            .child(cancel)
            .child(save)
            .into_any_element()
    }
}

/// Whether `problem` is about a custom header (its row is shown).
fn is_header_problem(problem: conduit_protocol::ServerAddressProblemCode) -> bool {
    use conduit_protocol::ServerAddressProblemCode as P;
    matches!(
        problem,
        P::HeaderFieldMissing
            | P::HeaderNameTooLong
            | P::HeaderNameInvalidCharacters
            | P::HeaderNameReserved
            | P::HeaderValueTooLong
            | P::HeaderValueInvalidCharacters
            | P::HeaderValueUnsafe
            | P::HeaderAlreadyAdded
            | P::TooManyHeaders
    )
}

impl HasAdvanced for AddressEditor {
    fn advanced(&self) -> &AdvancedFields {
        &self.adv
    }

    fn advanced_mut(&mut self) -> &mut AdvancedFields {
        &mut self.adv
    }

    fn file_problem(&mut self, problem: Option<String>) {
        self.error = problem;
    }

    /// A saved certificate or key cleared clears both (the daemon removes
    /// them together), with the key's saved password.
    fn file_cleared(&mut self, key: bool) {
        let kept = |f: &Option<PemFile>| f.as_ref().is_some_and(|f| f.pem.is_empty());
        let was_kept = if key {
            kept(&self.adv.private_key)
        } else {
            kept(&self.adv.certificate)
        };
        if key {
            self.adv.private_key = None;
        } else {
            self.adv.certificate = None;
        }
        if was_kept {
            self.tls_cleared = true;
            if kept(&self.adv.certificate) {
                self.adv.certificate = None;
            }
            if kept(&self.adv.private_key) {
                self.adv.private_key = None;
            }
        }
    }

    fn advanced_changed(&mut self) {
        self.error = None;
    }

    /// Locked while Save is out: it saves the form as it found it, so
    /// nothing can be changed after and then closed over.
    fn locked(&self) -> bool {
        self.busy
    }
}

impl Render for AddressEditor {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let l10n = cx.l10n().clone();
        let t = cx.conduit().clone();
        let title = self.title(cx);
        let this = cx.entity().downgrade();
        let toggle = move |_: &gpui_kit::ClickEvent, _: &mut Window, cx: &mut App| {
            let _ = this.update(cx, |s, cx| {
                s.advanced_open = !s.advanced_open;
                cx.notify();
            });
        };
        let summary: Vec<String> = [
            self.adv
                .self_signed
                .then(|| l10n.allow_self_signed_certificates()),
            (self.adv.certificate.is_some() || self.adv.private_key.is_some())
                .then(|| l10n.mutual_tls_section_title()),
            (!self.adv.headers.is_empty())
                .then(|| format!("{} ({})", l10n.custom_headers(), self.adv.headers.len())),
        ]
        .into_iter()
        .flatten()
        .collect();
        let advanced = self
            .advanced_open
            .then(|| advanced_section(&*self, window, cx));
        div()
            .id("address-editor")
            .role(Role::Form)
            .aria_label(SharedString::from(title.clone()))
            .w_full()
            .flex()
            .flex_col()
            .gap(px(16.))
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
                    .flex()
                    .flex_col()
                    .gap(px(6.))
                    .child(forms::form_group(
                        vec![
                            forms::field_locked(
                                l10n.accounts_address_name(),
                                &self.label,
                                None,
                                None,
                                self.busy,
                                window,
                                cx,
                            )
                            .into_any_element(),
                            forms::field_locked(
                                l10n.desktop_server_address(),
                                &self.url,
                                None,
                                None,
                                self.busy,
                                window,
                                cx,
                            )
                            .into_any_element(),
                        ],
                        cx,
                    ))
                    .child(forms::group_footer(l10n.server_address_footer(), cx)),
            )
            .child(
                div()
                    .id("address-advanced")
                    .role(Role::Button)
                    .aria_label(l10n.desktop_advanced_settings())
                    .aria_expanded(self.advanced_open)
                    .self_start()
                    .flex()
                    .items_center()
                    .gap(px(4.))
                    .cursor_pointer()
                    .text_size(px(t.metrics.control))
                    .font_weight(FontWeight::MEDIUM)
                    .text_color(t.roles.text)
                    .keyboard_outline(4., cx)
                    .child(icon(
                        if self.advanced_open {
                            IconName::ChevronDown
                        } else {
                            IconName::ChevronRight
                        },
                        13.,
                        t.roles.text_subtle,
                    ))
                    .child(l10n.desktop_advanced_settings())
                    .when(!self.advanced_open && !summary.is_empty(), |d| {
                        d.child(
                            div()
                                .pl(px(6.))
                                .text_size(px(t.metrics.small))
                                .font_weight(FontWeight::NORMAL)
                                .text_color(t.roles.text_subtle)
                                .child(summary.join(", ")),
                        )
                    })
                    .on_click(toggle),
            )
            .children(advanced)
            .when_some(self.error.clone(), |d, e| {
                d.child(forms::form_error("address-error", e, cx))
            })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::Cell;

    use gpui_kit::VisualTestContext;
    use serde_json::json;

    use crate::views::sheet::bench::bench;

    /// Seed lab's two addresses, the first in use.
    fn seed_lab() -> ServerAddresses {
        serde_json::from_value(json!({
            "serverId": "srv",
            "name": "Seed lab",
            "addresses": [
                {"id": "e1", "url": "http://127.0.0.1:20531", "inUse": true},
                {"id": "e2", "url": "http://127.0.0.1:20532"},
            ],
            "removable": true,
        }))
        .unwrap()
    }

    fn on_sheet<V: SheetBody>(
        vcx: &mut VisualTestContext,
        f: impl FnOnce(&mut V, &mut Window, &mut Context<V>),
    ) {
        vcx.update(|_, cx| {
            let body = sheet::current::<V>(cx).expect("the sheet is down");
            let window = sheet::current_window(cx).expect("the sheet's window");
            let _ = window.update(cx, |_, window, cx| {
                body.update(cx, |s, cx| f(s, window, cx))
            });
        });
    }

    fn open_seed_lab(stores: &Stores, vcx: &mut VisualTestContext) {
        let s = stores.clone();
        vcx.update(|window, cx| open(&s, "srv", window, cx));
        vcx.run_until_parked();
        assert!(
            vcx.update(|_, cx| sheet::current::<ServerSheet>(cx))
                .is_some()
        );
    }

    fn rename(vcx: &mut VisualTestContext, name: &str) {
        let name = name.to_string();
        on_sheet::<ServerSheet>(vcx, |s, w, cx| {
            s.name.update(cx, |i, cx| i.set_value(name, w, cx))
        });
    }

    fn quit_counted(vcx: &mut VisualTestContext) -> Rc<Cell<u32>> {
        let quits = Rc::new(Cell::new(0));
        let counted = quits.clone();
        vcx.update(|_, cx| sheet::quit_with(cx, Rc::new(move |_| counted.set(counted.get() + 1))));
        for _ in 0..2 {
            vcx.run_until_parked();
            vcx.executor()
                .advance_clock(std::time::Duration::from_secs(5));
        }
        vcx.run_until_parked();
        quits
    }

    fn beeps(vcx: &mut VisualTestContext) -> u32 {
        vcx.update(|_, cx| cx.global::<crate::shell::sheet::Beeps>().0)
    }

    fn sheet_up(vcx: &mut VisualTestContext) -> bool {
        vcx.update(|_, cx| sheet::current::<ServerSheet>(cx))
            .is_some()
    }

    /// A new name typed and not saved: Quit asks first, and so does Add
    /// Account on This Server. "Keep editing" (the bench's answer) keeps
    /// the sheet and its name, and adds nothing; Discard adds the account.
    #[gpui_kit::test]
    fn quit_and_add_account_ask_before_dropping_a_typed_name(cx: &mut gpui_kit::TestAppContext) {
        let (daemon, stores, vcx) = bench(cx);
        daemon.returns::<methods::ServersAddressesList>(seed_lab());
        open_seed_lab(&stores, vcx);
        rename(vcx, "Seed lab annex");
        let quits = quit_counted(vcx);
        assert_eq!(quits.get(), 0, "Quit dropped the typed name");
        assert!(sheet_up(vcx));
        assert_eq!(beeps(vcx), 0);

        on_sheet::<ServerSheet>(vcx, |s, w, cx| s.add_account(w, cx));
        vcx.run_until_parked();
        assert!(sheet_up(vcx), "Add Account dropped the typed name");
        assert!(daemon.calls::<methods::AccountsAdd>().is_empty());
        vcx.update(|_, cx| cx.set_global(crate::shell::sheet::AutoAnswer(Some(true))));
        on_sheet::<ServerSheet>(vcx, |s, w, cx| s.add_account(w, cx));
        vcx.run_until_parked();
        assert!(!sheet_up(vcx));
        assert_eq!(daemon.calls::<methods::AccountsAdd>().len(), 1);
    }

    /// Add Account on This Server while a reply is being written: the
    /// sheet is gone by the time the daemon says so, and the question comes
    /// up on the window it hung on.
    #[gpui_kit::test]
    fn add_account_asks_about_a_running_reply_once_the_sheet_is_gone(
        cx: &mut gpui_kit::TestAppContext,
    ) {
        use crate::stores::accounts::tests::{account, list};
        let (daemon, stores, vcx) = bench(cx);
        daemon.returns::<methods::ServersAddressesList>(seed_lab());
        daemon.returns::<methods::AccountsAdd>(conduit_protocol::AccountChangeResult {
            outcome: conduit_protocol::AccountChangeOutcome::BlockedByActiveReply,
            accounts: list(vec![account("a", "Avery", true, true)]),
        });
        open_seed_lab(&stores, vcx);
        on_sheet::<ServerSheet>(vcx, |s, w, cx| s.add_account(w, cx));
        vcx.run_until_parked();
        assert!(!sheet_up(vcx));
        let asked = vcx.update(|_, cx| {
            cx.try_global::<crate::shell::sheet::AutoAnswered>()
                .map(|a| a.0.clone())
                .unwrap_or_default()
        });
        assert_eq!(
            asked,
            [crate::l10n::L10n::new("en").desktop_reply_in_progress()],
            "the running reply was never asked about"
        );
    }

    /// Quit while Done's rename is out queues nothing: a beep, no quit,
    /// and the sheet stays until the rename lands.
    #[gpui_kit::test]
    fn quit_during_a_rename_beeps_and_stays(cx: &mut gpui_kit::TestAppContext) {
        let (daemon, stores, vcx) = bench(cx);
        daemon.returns::<methods::ServersAddressesList>(seed_lab());
        open_seed_lab(&stores, vcx);
        rename(vcx, "Seed lab annex");
        let held = daemon.hold::<methods::ServersUpdate>();
        on_sheet::<ServerSheet>(vcx, |s, w, cx| s.done(w, cx));
        vcx.run_until_parked();
        let quits = quit_counted(vcx);
        assert_eq!(beeps(vcx), 1, "Quit during the rename did not beep");
        assert_eq!(quits.get(), 0);
        assert!(sheet_up(vcx));
        drop(held);
        vcx.run_until_parked();
    }

    /// The name takes no typing until it is read, nor while Done saves it:
    /// what Done saves is what the field shows, and the read never writes
    /// over what was typed.
    #[gpui_kit::test]
    fn the_name_takes_no_typing_until_read_or_while_saved(cx: &mut gpui_kit::TestAppContext) {
        let app = cx.clone();
        let (daemon, stores, vcx) = bench(cx);
        daemon.returns::<methods::ServersAddressesList>(seed_lab());
        // The first read (the name's) is held; a refresh of the addresses,
        // asked as another window changes the server, lands first.
        let reading = daemon.hold_one::<methods::ServersAddressesList>(0);
        let s = stores.clone();
        vcx.update(|window, cx| open(&s, "srv", window, cx));
        vcx.run_until_parked();
        on_sheet::<ServerSheet>(vcx, |s, _, cx| s.refresh(cx));
        vcx.run_until_parked();
        let type_into_name = |text: &str, vcx: &mut VisualTestContext| {
            on_sheet::<ServerSheet>(vcx, |s, w, cx| s.name.update(cx, |i, cx| i.focus(w, cx)));
            vcx.update(|_, cx| {
                if let Some(handle) = sheet::current_window(cx) {
                    let _ = handle.update(cx, |_, window, cx| window.draw(cx).clear(cx));
                }
            });
            vcx.run_until_parked();
            let window = vcx
                .update(|_, cx| sheet::current_window(cx))
                .expect("the sheet's window");
            let mut sheet_cx = VisualTestContext::from_window(window, &app);
            sheet_cx.simulate_input(text);
            vcx.run_until_parked();
        };
        let name = |vcx: &mut VisualTestContext| {
            vcx.update(|_, cx| {
                let body = sheet::current::<ServerSheet>(cx).expect("the sheet is down");
                forms::text(&body.read(cx).name, cx)
            })
        };
        type_into_name("Kiln", vcx);
        assert_eq!(name(vcx), "", "typing went in before the name was read");
        drop(reading);
        vcx.run_until_parked();
        assert_eq!(name(vcx), "Seed lab");
        rename(vcx, "Seed lab annex");
        let held = daemon.hold::<methods::ServersUpdate>();
        on_sheet::<ServerSheet>(vcx, |s, w, cx| s.done(w, cx));
        vcx.run_until_parked();
        type_into_name(" East", vcx);
        assert_eq!(
            name(vcx),
            "Seed lab annex",
            "typing went in while Done saved"
        );
        drop(held);
        vcx.run_until_parked();
    }

    /// A removal the user confirmed is on its way: Quit beeps and waits
    /// for nothing.
    #[gpui_kit::test]
    fn quit_during_a_removal_beeps_and_stays(cx: &mut gpui_kit::TestAppContext) {
        let (daemon, stores, vcx) = bench(cx);
        daemon.returns::<methods::ServersAddressesList>(seed_lab());
        open_seed_lab(&stores, vcx);
        vcx.update(|_, cx| cx.set_global(crate::shell::sheet::AutoAnswer(Some(true))));
        let held = daemon.hold::<methods::ServersAddressesRemove>();
        on_sheet::<ServerSheet>(vcx, |s, w, cx| s.remove("e2", w, cx));
        vcx.run_until_parked();
        assert_eq!(daemon.calls::<methods::ServersAddressesRemove>().len(), 1);
        let quits = quit_counted(vcx);
        assert_eq!(beeps(vcx), 1, "Quit during the removal did not beep");
        assert_eq!(quits.get(), 0);
        assert!(sheet_up(vcx));
        drop(held);
        vcx.run_until_parked();
    }

    /// An address's Save is on its way in the editor: Quit beeps.
    #[gpui_kit::test]
    fn quit_during_an_address_save_beeps_and_stays(cx: &mut gpui_kit::TestAppContext) {
        let (daemon, stores, vcx) = bench(cx);
        daemon.returns::<methods::ServersAddressesList>(seed_lab());
        open_seed_lab(&stores, vcx);
        on_sheet::<ServerSheet>(vcx, |s, w, cx| s.edit(None, w, cx));
        vcx.run_until_parked();
        let held = daemon.hold::<methods::ServersAddressesCheck>();
        on_sheet::<ServerSheet>(vcx, |s, w, cx| {
            let editor = s.editor.clone().expect("the editor is open");
            editor.update(cx, |e, cx| {
                e.url
                    .update(cx, |i, cx| i.set_value("http://127.0.0.1:20533", w, cx));
                e.save(w, cx);
            });
        });
        vcx.run_until_parked();
        let quits = quit_counted(vcx);
        assert_eq!(beeps(vcx), 1, "Quit during the address save did not beep");
        assert_eq!(quits.get(), 0);
        assert!(sheet_up(vcx));
        drop(held);
        vcx.run_until_parked();
    }

    /// While an address's Save is out the editor takes no typing: Save
    /// saves the form as it found it, and closes, so nothing typed after
    /// may be closed over.
    #[gpui_kit::test]
    fn an_address_save_out_takes_no_typing(cx: &mut gpui_kit::TestAppContext) {
        let app = cx.clone();
        let (daemon, stores, vcx) = bench(cx);
        daemon.returns::<methods::ServersAddressesList>(seed_lab());
        open_seed_lab(&stores, vcx);
        on_sheet::<ServerSheet>(vcx, |s, w, cx| s.edit(None, w, cx));
        vcx.run_until_parked();
        let editor = Rc::new(std::cell::RefCell::new(None));
        let kept = editor.clone();
        // The name field has the caret, as when the user is typing in it.
        on_sheet::<ServerSheet>(vcx, |s, w, cx| {
            let e = s.editor.clone().expect("the editor is open");
            e.update(cx, |e, cx| {
                e.url
                    .update(cx, |i, cx| i.set_value("http://127.0.0.1:20533", w, cx));
                e.label.update(cx, |i, cx| {
                    i.set_value("Office", w, cx);
                    i.focus(w, cx);
                });
            });
            *kept.borrow_mut() = Some(e);
        });
        let editor = editor.borrow().clone().expect("the editor");
        let draw = |vcx: &mut VisualTestContext| {
            vcx.update(|_, cx| {
                if let Some(handle) = sheet::current_window(cx) {
                    let _ = handle.update(cx, |_, window, cx| window.draw(cx).clear(cx));
                }
            });
            vcx.run_until_parked();
        };
        draw(vcx);
        let held = daemon.hold::<methods::ServersAddressesCheck>();
        on_sheet::<ServerSheet>(vcx, |_, w, cx| editor.update(cx, |e, cx| e.save(w, cx)));
        vcx.run_until_parked();
        draw(vcx);
        let window = vcx
            .update(|_, cx| sheet::current_window(cx))
            .expect("the sheet's window");
        let mut sheet_cx = VisualTestContext::from_window(window, &app);
        sheet_cx.simulate_input(" East");
        vcx.run_until_parked();
        let label = vcx.update(|_, cx| forms::text(&editor.read(cx).label, cx));
        drop(held);
        vcx.run_until_parked();
        assert_eq!(label, "Office", "typing went in while Save was out");
    }

    fn ids(v: &[&str]) -> Vec<String> {
        v.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn a_dragged_address_lands_where_it_was_dropped() {
        let all = ids(&["a", "b", "c"]);
        assert_eq!(moved(&all, 0, 2), ids(&["b", "c", "a"]));
        assert_eq!(moved(&all, 2, 0), ids(&["c", "a", "b"]));
        assert_eq!(moved(&all, 1, 1), all);
        assert_eq!(moved(&all, 5, 0), all, "a row no longer there");
    }

    #[test]
    fn an_address_is_called_by_its_name_else_its_host() {
        let mut a = ServerAddressDto {
            id: "e".into(),
            url: "http://lab.example.net:8080".into(),
            label: Some("  ".into()),
            in_use: false,
            allow_self_signed_certificates: false,
            custom_header_names: vec![],
            has_mutual_tls_credentials: false,
            mtls_certificate_label: None,
            mtls_private_key_label: None,
            has_private_key_password: false,
        };
        assert_eq!(address_title(&a), "lab.example.net");
        a.label = Some("Home network".into());
        assert_eq!(address_title(&a), "Home network");
    }
}
