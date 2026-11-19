//! `--e2e servers`: a saved Open WebUI server's sheet (Settings › Accounts
//! › Servers, or an account's Server Settings…) against the local Open
//! WebUI, reached at 127.0.0.1 and at localhost on its port: two addresses
//! of one server.
//!
//! Adding localhost asks before the account's session goes to that new
//! host (declined: nothing saved; agreed: saved, with its header); an
//! address with nothing listening and a header the app sets itself are
//! refused in the phone's words; an edit keeps a saved header value it was
//! never given and swaps the headers; Move Up reorders them, and the order
//! is still there after conduitd is killed and started again; behind the
//! fake sign-in proxy (when `OWUI_PROXY_URL` is set) an address goes to the
//! proxy's sign-in window and is saved with what it captured; one is
//! removed; the server is renamed; Add Account on This Server starts a
//! sign-in on it; and Add Account lists Hermes Agent and Model Provider,
//! each opening its editor. The sheet and editor are shot in light and dark.

use std::path::Path;
use std::process::Command;
use std::time::Duration;

use conduit_protocol::{ServerAddresses, ServerRef, methods};
use gpui_kit::{AnyWindowHandle, AsyncApp, Entity};

use super::*;
use crate::l10n::ActiveL10n as _;
use crate::stores::connection::DaemonPhase;
use crate::views::add_account::{AddAccountSheet, Kind};
use crate::views::settings::SettingsView;
use crate::views::settings::server_sheet::{AddressEditor, ServerSheet};
use crate::views::sheet;

fn settings_view(cx: &mut App) -> Option<(AnyWindowHandle, Entity<SettingsView>)> {
    cx.try_global::<AppState>()?.settings_window.clone()
}

fn server_sheet(cx: &mut App) -> Option<Entity<ServerSheet>> {
    sheet::current::<ServerSheet>(cx)
}

fn editor(cx: &mut App) -> Option<Entity<AddressEditor>> {
    server_sheet(cx)?.read(cx).editor.clone()
}

fn in_sheet<R>(
    cx: &mut AsyncApp,
    f: impl FnOnce(&mut ServerSheet, &mut Window, &mut gpui_kit::Context<ServerSheet>) -> R,
) -> Option<R> {
    let handle = cx.update(|cx| sheet::current_window(cx))?;
    let entity = cx.update(server_sheet)?;
    cx.update(|cx| {
        handle
            .update(cx, |_, window, cx| {
                entity.update(cx, |v, cx| f(v, window, cx))
            })
            .ok()
    })
}

fn in_editor<R>(
    cx: &mut AsyncApp,
    f: impl FnOnce(&mut AddressEditor, &mut Window, &mut gpui_kit::Context<AddressEditor>) -> R,
) -> Option<R> {
    let handle = cx.update(|cx| sheet::current_window(cx))?;
    let entity = cx.update(editor)?;
    cx.update(|cx| {
        handle
            .update(cx, |_, window, cx| {
                entity.update(cx, |v, cx| f(v, window, cx))
            })
            .ok()
    })
}

/// The sheet's addresses: (url, label, header names, in use).
fn rows(cx: &mut App) -> Vec<(String, Option<String>, Vec<String>, bool)> {
    server_sheet(cx)
        .and_then(|s| s.read(cx).addresses.clone())
        .map(|a| {
            a.addresses
                .into_iter()
                .map(|r| (r.url, r.label, r.custom_header_names, r.in_use))
                .collect()
        })
        .unwrap_or_default()
}

fn ids(cx: &mut App) -> Vec<String> {
    server_sheet(cx)
        .and_then(|s| s.read(cx).addresses.clone())
        .map(|a| a.addresses.into_iter().map(|r| r.id).collect())
        .unwrap_or_default()
}

async fn shot(dir: &Path, name: &str, cx: &mut AsyncApp) {
    if let Some((handle, _)) = cx.update(settings_view) {
        settle(cx, 600).await;
        shoot_both_modes(handle, dir, name, cx).await;
    }
}

/// Fills an open editor: its name, URL, and headers added (name, value).
async fn fill(label: &str, url: &str, headers: &[(&str, &str)], cx: &mut AsyncApp) {
    let (label, url) = (label.to_string(), url.to_string());
    let headers: Vec<(String, String)> = headers
        .iter()
        .map(|(n, v)| (n.to_string(), v.to_string()))
        .collect();
    in_editor(cx, move |e, window, cx| {
        set_text(&e.label, &label, window, cx);
        set_text(&e.url, &url, window, cx);
        for (name, value) in headers {
            e.adv.add_header(window, cx);
            let row = e.adv.headers.last().expect("added");
            set_text(&row.name, &name, window, cx);
            set_text(&row.value, &value, window, cx);
        }
        e.advanced_open = true;
        cx.notify();
    });
    settle(cx, 300).await;
}

/// Save Address, then waits for it to finish: the editor closed (saved)
/// or no longer busy (refused or declined). True when it closed.
async fn save(cx: &mut AsyncApp) -> bool {
    in_editor(cx, |e, window, cx| e.save(window, cx));
    settle(cx, 200).await;
    wait_until(cx, Duration::from_secs(120), |cx| {
        editor(cx).is_none_or(|e| !e.read(cx).busy)
    })
    .await;
    settle(cx, 400).await;
    cx.update(editor).is_none()
}

async fn open_editor(id: Option<String>, cx: &mut AsyncApp) -> bool {
    in_sheet(cx, move |s, window, cx| s.edit(id.as_deref(), window, cx));
    wait_until(cx, Duration::from_secs(5), |cx| editor(cx).is_some()).await
}

fn editor_error(cx: &mut App) -> Option<String> {
    editor(cx).and_then(|e| e.read(cx).error.clone())
}

/// `servers.addresses.list` straight from the daemon.
async fn listed(server_id: &str, cx: &mut AsyncApp) -> Option<ServerAddresses> {
    let rpc = cx.update(|cx| cx.global::<AppState>().connection.read(cx).rpc());
    rpc.call::<methods::ServersAddressesList>(&ServerRef {
        server_id: server_id.to_string(),
    })
    .await
    .ok()
}

/// Restarts conduitd through its supervisor, which starts another; the
/// window reconnects to it. Only the supervisor signals the daemon: a pid
/// read here could already belong to another process.
async fn restart_daemon(cx: &mut AsyncApp) -> bool {
    let pid = cx.update(
        |cx| match cx.global::<AppState>().connection.read(cx).daemon.clone() {
            DaemonPhase::Running { pid, .. } => Some(pid),
            _ => None,
        },
    );
    let Some(pid) = pid else {
        return ok("conduitd is running", false);
    };
    let killed = cx.update(|cx| {
        let connection = cx.global::<AppState>().connection.clone();
        connection.update(cx, |c, cx| c.restart_daemon(cx))
    });
    println!("e2e: restarted conduitd (was pid {pid})");
    let back = wait_until(cx, Duration::from_secs(90), |cx| {
        matches!(
            cx.global::<AppState>().connection.read(cx).daemon,
            DaemonPhase::Running { pid: p, .. } if p != pid
        ) && matches!(current_status(cx), Status::Connected)
            && current_route(cx) == Route::Main
    })
    .await;
    ok("conduitd restarted and started again", killed && back)
}

pub async fn run(inputs: &E2eInputs, dir: &Path, cx: &mut AsyncApp) -> bool {
    let Some((url, email, password)) = inputs.owui() else {
        return ok(NO_SERVER, false);
    };
    let localhost = url.replace("127.0.0.1", "localhost");
    // Nothing listens on the port after the fake Open Terminal's (server
    // +4: kept free in every local test port range).
    let silent = url::Url::parse(&url)
        .ok()
        .and_then(|u| u.port())
        .map(|p| format!("http://127.0.0.1:{}", p + 4))
        .unwrap_or_default();
    let l10n = cx.update(|cx| cx.l10n().clone());
    let mut pass = super::chat::sign_in(&url, &email, &password, cx).await;

    // An account's Server Settings… (its row menu) opens the server's sheet.
    let account = cx.update(|cx| {
        let s = cx.global::<AppState>().stores.accounts.read(cx);
        s.active().map(|a| (a.id.clone(), a.server_id.clone()))
    });
    let Some((account_id, server_id)) = account else {
        return ok("an account is active", false);
    };
    let Some(settings) = settings_tab(Tab::Accounts, dir, "accounts-servers", cx).await else {
        return ok("Settings › Accounts opened", false);
    };
    let ax_accounts = ax(settings, "accounts-servers", dir, cx).await;
    pass &= ok(
        "Accounts lists the server under Servers",
        has(
            &ax_accounts,
            "Button",
            &l10n.desktop_server_settings_ellipsis(),
        ),
    );
    let server = server_id.clone();
    let _ = settings.update(cx, |_, window, cx| {
        window.dispatch_action(
            Box::new(crate::actions::SettingsChoice {
                menu: crate::views::settings::SERVER_SETTINGS_MENU.into(),
                value: server,
            }),
            cx,
        )
    });
    let opened = wait_until(cx, Duration::from_secs(10), |cx| {
        server_sheet(cx).is_some_and(|s| s.read(cx).addresses.is_some())
    })
    .await;
    pass &= ok("Server Settings… opens the server's sheet", opened);
    let first = cx.update(rows);
    pass &= ok(
        &format!("one address, in use ({first:?})"),
        first.len() == 1 && first[0].0 == url && first[0].3,
    );
    let accounts_shown = cx.update(|cx| {
        let s = cx.global::<AppState>().stores.accounts.read(cx);
        s.accounts()
            .iter()
            .filter(|a| a.server_id == server_id)
            .count()
    });
    pass &= ok("its account is listed", accounts_shown == 1);
    shot(dir, "server-sheet", cx).await;
    if let Some(sheet_window) = cx.update(|cx| sheet::current_window(cx)) {
        let controls = ax(sheet_window, "server-sheet", dir, cx).await;
        pass &= ok(
            "Add Address…, Add Account on This Server… and Done",
            has(&controls, "Button", &l10n.desktop_add_address_ellipsis())
                && has(
                    &controls,
                    "Button",
                    &l10n.desktop_add_account_on_this_server_ellipsis(),
                )
                && has(&controls, "Button", &l10n.done()),
        );
    }

    // A new host: asked first. Declined, nothing is saved.
    pass &= ok("Add Address… opens the editor", open_editor(None, cx).await);
    fill("Loopback name", &localhost, &[("X-Lab", "one")], cx).await;
    shot(dir, "address-editor", cx).await;
    cx.update(|cx| cx.set_global(AutoAnswer(Some(false))));
    let closed = save(cx).await;
    pass &= ok(
        "a session for a new host is asked about first; declined, the editor stays",
        !closed && cx.update(editor_error).is_none() && cx.update(rows).len() == 1,
    );
    cx.update(|cx| cx.set_global(AutoAnswer(Some(true))));
    let saved = save(cx).await;
    let now = cx.update(rows);
    pass &= ok(
        &format!("agreed, the address is checked and saved ({now:?})"),
        saved
            && now.len() == 2
            && now[1].0 == localhost
            && now[1].1.as_deref() == Some("Loopback name")
            && now[1].2 == vec!["X-Lab".to_string()],
    );

    // Refused, in the phone's words.
    pass &= open_editor(None, cx).await;
    fill("", &silent, &[], cx).await;
    save(cx).await;
    let said = cx.update(editor_error);
    pass &= ok(
        &format!("nothing listening: {said:?}"),
        said.as_deref() == Some(l10n.could_not_connect_generic().as_str()),
    );
    fill("", &localhost, &[("Authorization", "Bearer made-up")], cx).await;
    save(cx).await;
    let said = cx.update(editor_error);
    pass &= ok(
        &format!("a header the app sets itself: {said:?}"),
        said.as_deref() == Some(l10n.header_name_reserved("Authorization").as_str()),
    );
    shot(dir, "address-editor-refused", cx).await;
    // Cancel asks before throwing the edit away (agreed).
    in_editor(cx, |e, window, cx| e.cancel(window, cx));
    pass &= ok(
        "Cancel leaves the editor",
        wait_until(cx, Duration::from_secs(5), |cx| editor(cx).is_none()).await,
    );

    // An edit keeps the saved header value it was never given, then swaps
    // the header for another.
    let second = cx.update(ids).get(1).cloned();
    pass &= open_editor(second.clone(), cx).await;
    let kept = cx.update(|cx| {
        editor(cx).map(|e| {
            let f = e.read(cx).form(cx);
            (
                f.headers.len(),
                f.headers.first().map(|h| h.value.is_none()),
            )
        })
    });
    pass &= ok(
        &format!("the saved header is shown, its value kept ({kept:?})"),
        kept == Some((1, Some(true))),
    );
    in_editor(cx, |e, _, cx| {
        e.adv.headers.clear();
        cx.notify();
    });
    fill("Loopback name", &localhost, &[("X-Region", "north")], cx).await;
    shot(dir, "address-editor-advanced", cx).await;
    let saved = save(cx).await;
    let now = cx.update(rows);
    pass &= ok(
        &format!("headers edited ({now:?})"),
        saved && now.len() == 2 && now[1].2 == vec!["X-Region".to_string()],
    );

    // Move Up (the row's menu): localhost is tried first.
    let second = cx.update(ids).get(1).cloned().unwrap_or_default();
    if let Some(h) = cx.update(|cx| sheet::current_window(cx)) {
        let value = format!("up:{second}");
        let _ = h.update(cx, |_, window, cx| {
            window.dispatch_action(
                Box::new(crate::actions::SettingsChoice {
                    menu: "server-address".into(),
                    value,
                }),
                cx,
            )
        });
    }
    let moved = wait_until(cx, Duration::from_secs(10), |cx| {
        ids(cx).first() == Some(&second) && !server_sheet(cx).is_some_and(|s| s.read(cx).busy)
    })
    .await;
    pass &= ok("Move Up puts it first", moved);
    shot(dir, "server-sheet-two", cx).await;

    // The order is the daemon's: it survives conduitd starting again.
    pass &= restart_daemon(cx).await;
    let after = listed(&server_id, cx).await;
    let order: Vec<String> = after
        .as_ref()
        .map(|a| a.addresses.iter().map(|r| r.url.clone()).collect())
        .unwrap_or_default();
    pass &= ok(
        &format!("after the restart the order is kept ({order:?})"),
        after.is_some_and(|a| a.addresses.first().map(|r| &r.id) == Some(&second)),
    );
    let followed = wait_until(cx, Duration::from_secs(20), |cx| {
        ids(cx).first() == Some(&second)
    })
    .await;
    pass &= ok("the sheet shows it after the reconnect", followed);

    // Behind the fake sign-in proxy: its sign-in window, then saved.
    if let Some(proxy) = inputs.get("OWUI_PROXY_URL") {
        pass &= proxy_control(&proxy, "guard");
        pass &= proxy_control(&proxy, "remember");
        pass &= open_editor(None, cx).await;
        fill("Through the proxy", &proxy, &[], cx).await;
        let saved = save(cx).await;
        let error = cx.update(editor_error);
        let now = cx.update(rows);
        pass &= ok(
            &format!(
                "behind a sign-in proxy: signed in in its window, then saved ({error:?}, {:?})",
                now.iter().map(|r| r.0.clone()).collect::<Vec<_>>()
            ),
            saved && now.iter().any(|r| r.0 == proxy),
        );
        pass &= proxy_control(&proxy, "open");
        if !saved {
            in_editor(cx, |_, _, cx| {
                cx.emit(crate::views::settings::server_sheet::EditorEvent::Back)
            });
        }
        // Removed again, so the rest runs on the two loopback addresses.
        if let Some(id) = cx.update(|cx| {
            server_sheet(cx)
                .and_then(|s| s.read(cx).addresses.clone())
                .and_then(|a| a.addresses.into_iter().find(|r| r.url == proxy))
                .map(|r| r.id)
        }) {
            in_sheet(cx, move |s, window, cx| s.remove(&id, window, cx));
            let back = wait_until(cx, Duration::from_secs(20), |cx| rows(cx).len() == 2).await;
            pass &= ok("…and removed", back);
        }
    } else {
        println!("SMOKE e2e skip the proxy hand-off: no OWUI_PROXY_URL (owui.sh proxy start)");
    }

    // The address in use, removed while a reply arrives through it: asked
    // first, then asked again, and the reply stops.
    super::chat::send("A slow answer, please", cx).await;
    let streaming = super::chat::wait_streaming(cx, Duration::from_secs(30)).await;
    pass &= ok("a slow reply streams", streaming);
    cx.update(|cx| cx.set_global(crate::shell::sheet::AutoAnswered::default()));
    let in_use = cx.update(|cx| {
        server_sheet(cx)
            .and_then(|s| s.read(cx).addresses.clone())
            .and_then(|a| a.addresses.into_iter().find(|r| r.in_use))
    });
    let Some(in_use) = in_use else {
        return ok("an address is in use", false);
    };
    let id = in_use.id.clone();
    in_sheet(cx, move |s, window, cx| s.remove(&id, window, cx));
    let removed = wait_until(cx, Duration::from_secs(30), |cx| {
        let r = rows(cx);
        r.len() == 1 && r[0].0 != in_use.url
    })
    .await;
    let asked = cx.update(|cx| {
        cx.try_global::<crate::shell::sheet::AutoAnswered>()
            .map(|a| a.0.clone())
            .unwrap_or_default()
    });
    pass &= ok(
        &format!("Remove Address… asks, and again mid-reply, then removes it ({asked:?})"),
        removed
            && asked.len() == 2
            && asked[0].starts_with(&l10n.desktop_remove_address_title("").replace("“”?", ""))
            && asked[1] == l10n.accounts_reply_in_progress_title(),
    );
    let stopped = wait_until(cx, Duration::from_secs(30), |cx| {
        super::chat::chat_store(cx).is_some_and(|s| !s.read(cx).is_streaming())
    })
    .await;
    pass &= ok("…and the reply was stopped", stopped);
    let removable = cx.update(|cx| {
        server_sheet(cx)
            .and_then(|s| s.read(cx).addresses.clone())
            .is_some_and(|a| a.removable)
    });
    pass &= ok("the last address cannot be removed", !removable);

    // Renamed with Done.
    in_sheet(cx, |s, window, cx| {
        set_text(&s.name, "Harbour Lab", window, cx);
        s.done(window, cx)
    });
    let renamed = wait_until(cx, Duration::from_secs(20), |cx| {
        !sheet::is_open(cx)
            && cx
                .global::<AppState>()
                .stores
                .accounts
                .read(cx)
                .accounts()
                .iter()
                .any(|a| a.id == account_id && a.connection.name == "Harbour Lab")
    })
    .await;
    pass &= ok("Done renames the server and closes", renamed);

    // Add Account on This Server: a sign-in on it, then cancelled.
    let server = server_id.clone();
    let _ = settings.update(cx, |_, window, cx| {
        let stores = cx.global::<AppState>().stores.clone();
        crate::views::settings::server_sheet::open(&stores, &server, window, cx);
    });
    let reopened = wait_until(cx, Duration::from_secs(10), |cx| {
        server_sheet(cx).is_some_and(|s| s.read(cx).addresses.is_some())
    })
    .await;
    pass &= ok("the sheet opens again", reopened);
    in_sheet(cx, |s, window, cx| s.add_account(window, cx));
    let adding = wait_until(cx, Duration::from_secs(30), |cx| {
        let s = cx.global::<AppState>().stores.accounts.read(cx);
        s.list.as_ref().is_some_and(|l| l.adding_account)
            && s.active()
                .is_some_and(|a| a.server_id == server_id && a.id != account_id)
    })
    .await;
    pass &= ok("Add Account on This Server adds a sign-in on it", adding);
    pass &= wait_route(cx, Route::SignIn, Duration::from_secs(30)).await;
    let cancel = cx.update(|cx| {
        let s = cx.global::<AppState>().stores.accounts.clone();
        s.update(cx, |a, cx| {
            a.change(crate::stores::accounts::AccountChange::CancelAdd, true, cx)
        })
    });
    let _ = cancel.await;
    pass &= wait_route(cx, Route::Main, Duration::from_secs(30)).await;

    // Add Account lists Hermes Agent and Model Provider (G14).
    let Some(settings) = settings_tab(Tab::Accounts, dir, "accounts-after", cx).await else {
        return ok("Settings › Accounts opened again", false);
    };
    pass &= add_account_kinds(settings, dir, cx).await;
    pass
}

async fn add_account_kinds(settings: AnyWindowHandle, dir: &Path, cx: &mut AsyncApp) -> bool {
    let mut pass = true;
    for (kind, name) in [
        (Kind::Hermes, "add-account-hermes"),
        (Kind::Direct, "add-account-direct"),
    ] {
        let _ = settings.update(cx, |_, window, cx| {
            if let Some((_, v)) = cx.global::<AppState>().settings_window.clone() {
                v.update(cx, |v, cx| v.open_add_sheet(window, cx));
            }
        });
        let shown = wait_until(cx, Duration::from_secs(10), |cx| {
            settings_view(cx).is_some_and(|(_, v)| v.read(cx).add_sheet.is_some())
        })
        .await;
        let add = cx.update(|cx| settings_view(cx).and_then(|(_, v)| v.read(cx).add_sheet.clone()));
        let Some(add) = add.filter(|_| shown) else {
            return ok("Add Account opened", false);
        };
        let view = add.view.clone();
        let _ = add.handle.update(cx, |_, window, cx| {
            view.update(cx, |s: &mut AddAccountSheet, cx| {
                s.set_kind(kind, window, cx)
            })
        });
        settle(cx, 500).await;
        shoot_both_modes(settings, dir, name, cx).await;
        let view = add.view.clone();
        let _ = add.handle.update(cx, |_, _, cx| {
            view.update(cx, |s: &mut AddAccountSheet, cx| s.continue_with(cx))
        });
        let editor = wait_until(cx, Duration::from_secs(10), |cx| match kind {
            Kind::Hermes => {
                sheet::current::<crate::views::hermes_connection::HermesConnectionSheet>(cx)
                    .is_some()
            }
            _ => sheet::current::<crate::views::direct::editor::DirectEditorSheet>(cx).is_some(),
        })
        .await;
        pass &= ok(&format!("Add Account › {kind:?} opens its editor"), editor);
        settle(cx, 500).await;
        cx.update(sheet::dismiss);
        wait_until(cx, Duration::from_secs(10), |cx| !sheet::is_open(cx)).await;
        settle(cx, 800).await;
    }
    pass
}

fn proxy_control(proxy: &str, action: &str) -> bool {
    let out = Command::new("/usr/bin/curl")
        .args(["-sf", "-X", "POST", &format!("{proxy}/__proxy/{action}")])
        .output();
    ok(
        &format!("the fake proxy: {action}"),
        out.is_ok_and(|o| o.status.success()),
    )
}
