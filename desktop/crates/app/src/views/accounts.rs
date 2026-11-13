//! The Accounts page (Settings › Accounts) and the account changes other
//! views start: switch, sign out (hand-over to the next account), remove,
//! each confirmed with a native sheet where it loses something, and asked
//! again when a reply is still being written (`blockedByActiveReply`).

use std::rc::Rc;

use conduit_components::ActiveConduitTheme as _;
use conduit_components::assets::IconName;
use conduit_components::views::kit::{Button, ClickHandler, grouped, setting_row};
use conduit_components::views::model::{Account, Backend};
use conduit_components::views::settings::{AccountActions, accounts_list_with};
use conduit_protocol::{AccountChangeOutcome, AccountSummary, LibreChatAccountSummary};
use gpui_kit::prelude::*;
use gpui_kit::{AnyElement, App, AsyncApp, Div, SharedString, Window, div, px};

use crate::l10n::{ActiveL10n as _, L10n};
use crate::shell::sheet::{SheetSpec, present_sheet};
use crate::stores::Stores;
use crate::stores::accounts::{AccountChange, display_name, libre_chat_display_name};
use crate::views::forms::host_of;
use crate::views::privacy;

/// The sheet that asks before stopping a reply for `change`.
fn reply_sheet(change: &AccountChange, l10n: &L10n) -> SheetSpec {
    let (body, confirm) = if change.signs_out() {
        (
            l10n.accounts_sign_out_stops_reply(),
            l10n.desktop_sign_out_anyway(),
        )
    } else {
        (
            l10n.accounts_switch_stops_reply(),
            l10n.desktop_switch_anyway(),
        )
    };
    SheetSpec::new(
        l10n.desktop_reply_in_progress(),
        body,
        confirm,
        l10n.cancel(),
    )
}

/// Runs `change`; when the daemon refuses it because a reply is being
/// written, asks with a sheet and repeats it with `force`.
pub fn change_account(stores: &Stores, change: AccountChange, window: &mut Window, cx: &mut App) {
    let accounts = stores.accounts.clone();
    let task = accounts.update(cx, |a, cx| a.change(change.clone(), false, cx));
    let handle = window.window_handle();
    let l10n = cx.l10n().clone();
    cx.spawn(async move |cx: &mut AsyncApp| {
        let Ok(result) = task.await else { return };
        if result.outcome != AccountChangeOutcome::BlockedByActiveReply {
            return;
        }
        let spec = reply_sheet(&change, &l10n);
        let Ok(ask) = handle.update(cx, |_, window, cx| present_sheet(window, spec, cx)) else {
            return;
        };
        if ask.await {
            if let Some(task) = accounts.update(cx, |a, cx| a.confirm_blocked(cx)) {
                task.detach();
            }
        } else {
            accounts.update(cx, |a, cx| a.dismiss_blocked(cx));
        }
    })
    .detach();
}

/// Asks with `spec` first, then [`change_account`].
pub fn confirm_change(
    stores: &Stores,
    spec: SheetSpec,
    change: AccountChange,
    window: &mut Window,
    cx: &mut App,
) {
    let ask = present_sheet(window, spec, cx);
    let handle = window.window_handle();
    let stores = stores.clone();
    cx.spawn(async move |cx: &mut AsyncApp| {
        if !ask.await {
            return;
        }
        let _ = handle.update(cx, |_, window, cx| {
            change_account(&stores, change, window, cx)
        });
    })
    .detach();
}

/// The sheet for signing out of (and removing) `name`.
pub fn sign_out_sheet(name: &str, l10n: &L10n) -> SheetSpec {
    SheetSpec::new(
        l10n.accounts_sign_out_confirm_title(name),
        l10n.accounts_sign_out_confirm_message(),
        l10n.desktop_sign_out(),
        l10n.cancel(),
    )
    .destructive()
}

/// Sign out of the active account; the next one takes over.
pub fn sign_out_active(stores: &Stores, window: &mut Window, cx: &mut App) {
    let name = {
        let store = stores.accounts.read(cx);
        if store.libre_chat_in_charge() {
            store.libre_chat_active().map(libre_chat_display_name)
        } else {
            store.active().map(display_name)
        }
    };
    let Some(name) = name else {
        return;
    };
    let name = privacy::name(&name, cx);
    let spec = sign_out_sheet(&name, cx.l10n());
    confirm_change(stores, spec, AccountChange::SignOut, window, cx);
}

/// Sign out of `account_id` and remove it with its local data.
pub fn remove_account(stores: &Stores, account_id: &str, window: &mut Window, cx: &mut App) {
    let name = {
        let store = stores.accounts.read(cx);
        store
            .accounts()
            .iter()
            .find(|a| a.id == account_id)
            .map(display_name)
            .or_else(|| {
                store
                    .libre_chat_accounts()
                    .iter()
                    .find(|a| a.id == account_id)
                    .map(libre_chat_display_name)
            })
    };
    let Some(name) = name else {
        return;
    };
    let name = privacy::name(&name, cx);
    let spec = sign_out_sheet(&name, cx.l10n());
    confirm_change(
        stores,
        spec,
        AccountChange::Remove {
            account_id: account_id.to_string(),
        },
        window,
        cx,
    );
}

/// An account as the components draw it (names masked in `--shots`).
pub fn account_row(a: &AccountSummary, cx: &App) -> Account {
    let email = a
        .user
        .as_ref()
        .and_then(|u| u.email.clone())
        .unwrap_or_default();
    Account {
        id: a.id.clone().into(),
        name: privacy::name(&display_name(a), cx).into(),
        email: privacy::email(&email, cx).into(),
        server: privacy::host(&host_of(&a.connection.url), cx).into(),
        backend: Backend::OpenWebUi,
        active: a.is_active,
        needs_sign_in: !a.has_session,
    }
}

/// A LibreChat account as the components draw it (names masked in
/// `--shots`).
pub fn libre_chat_account_row(a: &LibreChatAccountSummary, cx: &App) -> Account {
    let email = a
        .user
        .as_ref()
        .and_then(|u| u.email.clone())
        .unwrap_or_default();
    Account {
        id: a.id.clone().into(),
        name: privacy::name(&libre_chat_display_name(a), cx).into(),
        email: privacy::email(&email, cx).into(),
        server: privacy::host(&host_of(&a.base_url), cx).into(),
        backend: Backend::LibreChat,
        active: a.is_active,
        needs_sign_in: !a.has_session,
    }
}

/// The Accounts tab's sections. `on_add` opens Add Account's sheet;
/// `on_more` opens the row's menu.
pub fn accounts_sections(
    stores: &Stores,
    on_add: ClickHandler,
    on_more: conduit_components::views::settings::AccountHandler,
    cx: &App,
) -> Vec<AnyElement> {
    let l10n = cx.l10n().clone();
    let t = cx.conduit().clone();
    let store = stores.accounts.read(cx);
    // Open WebUI's accounts, then LibreChat's, as the phone lists them; the
    // one marked is the account in charge of the chats.
    let libre_chat = store.libre_chat_in_charge();
    let rows: Vec<Account> = store
        .accounts()
        .iter()
        .map(|a| {
            let mut row = account_row(a, cx);
            row.active &= !libre_chat;
            row
        })
        .chain(store.libre_chat_accounts().iter().map(|a| {
            let mut row = libre_chat_account_row(a, cx);
            row.active &= libre_chat;
            row
        }))
        .collect();
    let busy = store
        .busy
        .as_ref()
        .and_then(|c| c.account_id().map(|id| SharedString::from(id.to_string())));
    let switch = {
        let stores = stores.clone();
        Rc::new(move |id: &str, window: &mut Window, cx: &mut App| {
            change_account(
                &stores,
                AccountChange::Switch {
                    account_id: id.to_string(),
                },
                window,
                cx,
            );
        })
    };
    let sign_in = {
        let stores = stores.clone();
        Rc::new(move |id: &str, window: &mut Window, cx: &mut App| {
            // Switch to it; its sign-in follows in the setup window.
            change_account(
                &stores,
                AccountChange::Switch {
                    account_id: id.to_string(),
                },
                window,
                cx,
            );
            crate::open_main_window(cx);
        })
    };
    let actions = AccountActions {
        on_switch: Some(switch),
        on_sign_in: Some(sign_in),
        on_more: Some(on_more),
        busy,
    };
    let list: AnyElement = if rows.is_empty() {
        grouped(
            vec![
                setting_row(l10n.desktop_settings_no_servers(), None, div(), cx).into_any_element(),
            ],
            cx,
        )
        .into_any_element()
    } else {
        accounts_list_with(&rows, &actions, cx).into_any_element()
    };
    let footer: Div = div()
        .flex()
        .items_center()
        .justify_between()
        .gap(px(8.))
        .child(
            div()
                .text_size(px(t.metrics.small))
                .text_color(t.roles.text_subtle)
                .child(l10n.accounts_add_account_message()),
        )
        .child(
            Button::new("add-account", l10n.desktop_add_account_ellipsis())
                .icon(IconName::UserPlus)
                .disabled(store.busy.is_some())
                .on_click(on_add),
        );
    vec![list, footer.into_any_element()]
}
