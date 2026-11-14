//! `--e2e hermes-admin`: Hermes's administration, against two
//! real local Hermes Desktop gateways (`hermes serve --isolated`, each
//! with its own home, scripted model and seeded chats) beside the local
//! Open WebUI.
//!
//! Signed in to Open WebUI, then in Settings › Hermes: the first
//! connection added (Desktop Gateway, session token) and tested, which
//! turns Hermes on; its status, skills and toolsets; edited and tested
//! again with its kept token; a second connection saved beside it, and
//! switched to from the sidebar's switcher and back from Settings, the
//! sessions following each time; an MCP server added (a command), tested,
//! given an API key and removed, and Hermes's catalog read (gateway A
//! through `catalog_proxy.py`'s synthetic catalog): an entry asking for a
//! required and an optional value added through its sheet, with Hermes
//! still installing it said, and one asking for nothing added. In the main
//! window: Scheduled Agents, a job created (delivery and missed runs),
//! run now and stopped, run again to its end, its run history opened and
//! a run's result opened as a Hermes chat, paused and deleted; a phone's
//! job with Notify Me (`conduit`) edited here keeps it. Then `/`
//! in a Hermes chat lists the agent's skills and inserts one; Hermes off
//! and on; the second connection deleted. Screenshots in light and dark,
//! AccessKit checks.
//!
//! Inputs, besides the local Open WebUI's env file: `HERMES_A_URL`,
//! `HERMES_A_TOKEN`, `HERMES_B_URL`, `HERMES_B_TOKEN` (the gateways'
//! session tokens) and `HERMES_CATALOG_LOG` (the catalog proxy's log),
//! from `--e2e-env`.

use std::path::Path;
use std::time::Duration;

use conduit_protocol::{HermesJobDto, HermesSessionDto, NoParams, methods};
use gpui_kit::{AnyWindowHandle, App, AsyncApp, Context, Entity, Window};

use super::chat::{chat_store, pane, sign_in};
use super::*;
use crate::stores::hermes_admin::{HermesAdminStore, Loaded};
use crate::stores::navigation::{AreaItem, Selection};
use crate::views::hermes_connection::HermesConnectionSheet;
use crate::views::hermes_job::HermesJobSheet;
use crate::views::hermes_mcp::{AddMcpSheet, CatalogSheet, McpKeySheet};
use crate::views::sheet;

/// Gateway A's seeded chats (`h4/hermes/scripts/chats_a.json`) and B's.
const A_CHAT: &str = "Balcony herb garden";
const B_CHAT: &str = "Three-day coastal trip";
const A_NAME: &str = "Studio gateway";
const A_RENAMED: &str = "Studio agent";
const B_NAME: &str = "Garden gateway";
const JOB: &str = "Standup notes";
/// The fake model answers a prompt with "slowly" after 12 s, so a run can
/// be seen running and stopped.
const JOB_PROMPT: &str = "Write a short standup summary, slowly.";
const MCP: &str = "demo_shop";

pub(super) fn admin(cx: &mut App) -> Entity<HermesAdminStore> {
    cx.global::<AppState>().stores.hermes_admin.clone()
}

pub(super) fn connections(cx: &mut App) -> Vec<(String, String, bool)> {
    admin(cx)
        .read(cx)
        .connections
        .as_ref()
        .map(|l| {
            l.connections
                .iter()
                .map(|c| (c.id.clone(), c.name.clone(), c.active))
                .collect()
        })
        .unwrap_or_default()
}

pub(super) fn connection_named(name: &str, cx: &mut App) -> Option<String> {
    connections(cx)
        .into_iter()
        .find(|(_, n, _)| n == name)
        .map(|(id, _, _)| id)
}

pub(super) fn active_name(cx: &mut App) -> Option<String> {
    admin(cx).read(cx).active().map(|c| c.name.clone())
}

pub(super) fn enabled(cx: &mut App) -> bool {
    admin(cx)
        .read(cx)
        .connections
        .as_ref()
        .is_some_and(|l| l.enabled)
}

pub(super) fn sessions(cx: &mut App) -> Vec<HermesSessionDto> {
    let areas = cx.global::<AppState>().stores.areas.read(cx);
    areas
        .hermes
        .as_ref()
        .map(|h| h.sessions.clone())
        .unwrap_or_default()
}

pub(super) fn listed(title: &str, cx: &mut App) -> bool {
    sessions(cx).iter().any(|s| s.title == title)
}

fn jobs(cx: &mut App) -> Vec<HermesJobDto> {
    admin(cx)
        .read(cx)
        .jobs
        .as_ref()
        .and_then(Loaded::ready)
        .map(|j| j.jobs.clone())
        .unwrap_or_default()
}

fn job(cx: &mut App) -> Option<HermesJobDto> {
    jobs(cx)
        .into_iter()
        .find(|j| j.name.as_deref() == Some(JOB))
}

pub(super) fn toasts(cx: &mut App) -> Vec<String> {
    let toasts = cx.global::<AppState>().stores.toasts.read(cx);
    toasts.toasts.iter().map(|t| t.message.clone()).collect()
}

pub(super) async fn toast(contains: &str, cx: &mut AsyncApp) -> bool {
    let want = contains.to_string();
    let seen = wait_until(cx, Duration::from_secs(30), move |cx| {
        toasts(cx).iter().any(|t| t.contains(&want))
    })
    .await;
    if !seen {
        log::warn!("toasts: {:?}", cx.update(toasts));
    }
    seen
}

pub(super) fn settings_window(cx: &mut App) -> Option<AnyWindowHandle> {
    cx.global::<AppState>()
        .settings_window
        .as_ref()
        .map(|(h, _)| *h)
}

/// Runs `f` in the Settings window (its window, for a sheet to hang from).
pub(super) fn in_settings<R>(
    cx: &mut AsyncApp,
    f: impl FnOnce(&mut Window, &mut App) -> R,
) -> Option<R> {
    cx.update(|cx| {
        let handle = settings_window(cx)?;
        handle.update(cx, |_, window, cx| f(window, cx)).ok()
    })
}

/// Runs `f` on the open sheet's body of type `V`, in the sheet's window.
pub(super) fn in_sheet<V: 'static, R>(
    cx: &mut AsyncApp,
    f: impl FnOnce(&mut V, &mut Window, &mut Context<V>) -> R,
) -> Option<R> {
    cx.update(|cx| {
        let body = sheet::current::<V>(cx)?;
        let handle = sheet::current_window(cx)?;
        handle
            .update(cx, |_, window, cx| {
                body.update(cx, |b, cx| f(b, window, cx))
            })
            .ok()
    })
}

pub(super) async fn wait_sheet<V: 'static>(cx: &mut AsyncApp) -> bool {
    wait_until(cx, Duration::from_secs(15), |cx| {
        sheet::current::<V>(cx).is_some()
    })
    .await
}

pub(super) async fn sheet_gone(cx: &mut AsyncApp) -> bool {
    wait_until(cx, Duration::from_secs(30), |cx| !sheet::is_open(cx)).await
}

pub(super) async fn shoot_sheet(dir: &Path, name: &str, cx: &mut AsyncApp) {
    if let Some(handle) = cx.update(|cx| sheet::current_window(cx)) {
        shoot_both_modes(handle, dir, name, cx).await;
    }
}

pub(super) async fn shoot_settings(dir: &Path, name: &str, cx: &mut AsyncApp) -> Vec<String> {
    let Some(handle) = cx.update(settings_window) else {
        return vec![];
    };
    crate::smoke::place_settings(handle, cx);
    settle(cx, 400).await;
    shoot_both_modes(handle, dir, name, cx).await;
    ax(handle, name, dir, cx).await
}

/// Fills the open connection editor.
fn fill_connection(
    sheet: &mut HermesConnectionSheet,
    name: &str,
    url: &str,
    token: Option<&str>,
    window: &mut Window,
    cx: &mut Context<HermesConnectionSheet>,
) {
    set_text(&sheet.name, name, window, cx);
    set_text(&sheet.url, url, window, cx);
    sheet.desktop = true;
    sheet.auth = crate::views::hermes_connection::Auth::Token;
    if let Some(token) = token {
        set_text(&sheet.token, token, window, cx);
    }
    cx.notify();
}

/// Tests the open editor and waits for its answer: whether it reached it.
pub(super) async fn test_connection(cx: &mut AsyncApp) -> bool {
    in_sheet::<HermesConnectionSheet, _>(cx, |s, w, cx| s.test(w, cx));
    let answered = wait_until(cx, Duration::from_secs(40), |cx| {
        sheet::current::<HermesConnectionSheet>(cx).is_some_and(|s| {
            let s = s.read(cx);
            !s.busy && (s.note.is_some() || s.error.is_some())
        })
    })
    .await;
    answered
        && cx.update(|cx| {
            sheet::current::<HermesConnectionSheet>(cx).is_some_and(|s| {
                matches!(
                    &s.read(cx).note,
                    Some(crate::views::hermes_connection::Note::Tested { ok: true, .. })
                )
            })
        })
}

pub(super) async fn open_editor(id: Option<String>, cx: &mut AsyncApp) -> bool {
    in_settings(cx, |window, cx| {
        let stores = cx.global::<AppState>().stores.clone();
        crate::views::hermes_connection::open(&stores, id, window, cx);
    });
    wait_sheet::<HermesConnectionSheet>(cx).await
}

fn choose_mcp(menu: &str, value: &str, cx: &mut AsyncApp) {
    let (menu, value) = (menu.to_string(), value.to_string());
    in_settings(cx, move |window, cx| {
        let stores = cx.global::<AppState>().stores.clone();
        crate::views::settings::hermes::choose(&stores, &menu, &value, window, cx);
    });
}

/// The proxy's log of installs asked of the (synthetic) catalog: each
/// entry's name and the names of the values sent (never the values).
fn installs(log: &str) -> Vec<(String, Vec<String>)> {
    std::fs::read_to_string(log)
        .unwrap_or_default()
        .lines()
        .filter_map(|l| serde_json::from_str::<serde_json::Value>(l).ok())
        .filter(|v| v["event"] == "install")
        .map(|v| {
            let names = v["envNames"]
                .as_array()
                .map(|a| {
                    a.iter()
                        .filter_map(|n| n.as_str().map(String::from))
                        .collect()
                })
                .unwrap_or_default();
            (v["name"].as_str().unwrap_or_default().to_string(), names)
        })
        .collect()
}

/// Add from Catalog with values (`scripts/catalog_proxy.py` in front of
/// gateway A serves a synthetic catalog and installs nothing): an entry
/// asking for a required and an optional value opens its sheet, Add waits
/// for the required one, the empty optional one is left out, and Hermes
/// still installing it is said in Settings until it is listed; an entry
/// asking for nothing is added at once.
async fn catalog_values(
    entries: &[conduit_protocol::HermesMcpCatalogEntryDto],
    inputs: &E2eInputs,
    dir: &Path,
    cx: &mut AsyncApp,
) -> bool {
    let Some(log) = inputs.get("HERMES_CATALOG_LOG") else {
        return ok(
            "the catalog proxy's log (HERMES_CATALOG_LOG) is there",
            false,
        );
    };
    let tide = entries.iter().find(|e| e.name == "tide_charts");
    let mut pass = ok(
        "the catalog says what an entry asks for, the optional value marked",
        tide.is_some_and(|e| {
            e.can_add
                && e.from_dashboard
                && e.credentials.len() == 2
                && e.credentials[0].required
                && !e.credentials[1].required
        }) && entries.iter().any(|e| e.name == "star_atlas" && e.oauth),
    );
    let shown = entries.to_vec();
    cx.update(|cx| admin(cx).update(cx, |a, _| a.mcp_catalog = shown));
    choose_mcp(
        crate::views::settings::hermes::CATALOG_MENU,
        "tide_charts",
        cx,
    );
    pass &= ok(
        "an entry asking for values opens its sheet",
        wait_sheet::<CatalogSheet>(cx).await,
    );
    let fields = in_sheet::<CatalogSheet, _>(cx, |s, _, _| s.fields.len());
    pass &= ok("one hidden field per value", fields == Some(2));
    in_sheet::<CatalogSheet, _>(cx, |s, w, cx| {
        let region = s.fields[1].clone();
        set_text(&region, "North Quay", w, cx);
        cx.notify();
    });
    settle(cx, 200).await;
    pass &= ok(
        "Add waits for the required value",
        in_sheet::<CatalogSheet, _>(cx, |s, _, cx| !s.can_add(cx)) == Some(true),
    );
    // Only the required one: the empty optional one is left out.
    in_sheet::<CatalogSheet, _>(cx, |s, w, cx| {
        let region = s.fields[1].clone();
        set_text(&region, "", w, cx);
        let key = s.fields[0].clone();
        set_text(&key, "tide-demo-key-42", w, cx);
        cx.notify();
    });
    settle(cx, 300).await;
    shoot_sheet(dir, "hermes-admin-mcp-catalog", cx).await;
    if let Some(handle) = cx.update(|cx| sheet::current_window(cx)) {
        let controls = ax(handle, "hermes-admin-mcp-catalog", dir, cx).await;
        pass &= ok(
            "the sheet's hidden fields are labelled with what they ask",
            ["PasswordInput", "TextInput"]
                .iter()
                .any(|role| has(&controls, role, "Tide service key"))
                && ["PasswordInput", "TextInput"]
                    .iter()
                    .any(|role| has(&controls, role, "Harbour region")),
        );
    }
    in_sheet::<CatalogSheet, _>(cx, |s, w, cx| s.add(w, cx));
    pass &= ok("Add closes the sheet", sheet_gone(cx).await);
    let sent = wait_until(cx, Duration::from_secs(20), {
        let log = log.clone();
        move |_| installs(&log).iter().any(|(n, _)| n == "tide_charts")
    })
    .await;
    pass &= ok(
        "Hermes is asked to install it with the required value alone",
        sent && installs(&log)
            .iter()
            .any(|(n, env)| n == "tide_charts" && env == &["TIDE_API_KEY".to_string()]),
    );
    pass &= ok(
        "still installing in the background is said",
        toast("Hermes is still installing tide_charts", cx).await,
    );
    let noted = wait_until(cx, Duration::from_secs(10), |cx| {
        admin(cx)
            .read(cx)
            .mcp_installing
            .iter()
            .any(|(n, _)| n == "tide_charts")
    })
    .await;
    pass &= ok("Settings keeps saying so until it is listed", noted);
    settle(cx, 400).await;
    shoot_settings(dir, "hermes-admin-mcp-installing", cx).await;
    // Nothing asked: added at once.
    choose_mcp(
        crate::views::settings::hermes::CATALOG_MENU,
        "moon_phases",
        cx,
    );
    pass &= ok(
        "an entry asking for nothing is added at once",
        toast("Added moon_phases", cx).await
            && installs(&log)
                .iter()
                .any(|(n, env)| n == "moon_phases" && env.is_empty()),
    );
    pass
}

fn mcp_servers(cx: &mut App) -> Vec<(String, Vec<String>)> {
    admin(cx)
        .read(cx)
        .mcp
        .as_ref()
        .and_then(Loaded::ready)
        .map(|m| {
            m.servers
                .iter()
                .map(|s| (s.name.clone(), s.tools.clone()))
                .collect()
        })
        .unwrap_or_default()
}

/// Closes (or opens) every sidebar section but Hermes's; answers the
/// sections it changed.
pub(super) fn set_others_collapsed(collapsed: bool, cx: &mut AsyncApp) -> Vec<String> {
    let keys: Vec<String> = cx.update(|cx| {
        let caps = cx
            .global::<AppState>()
            .stores
            .session
            .read(cx)
            .capabilities();
        crate::stores::areas::visible_areas(&caps)
            .into_iter()
            .filter(|a| *a != crate::stores::navigation::Area::Hermes)
            .map(|a| a.id().to_string())
            .collect()
    });
    set_others_collapsed_list(&keys, collapsed, cx);
    keys
}

pub(super) fn set_others_collapsed_list(keys: &[String], collapsed: bool, cx: &mut AsyncApp) {
    let keys = keys.to_vec();
    cx.update(|cx| {
        let sections = cx.global::<AppState>().stores.sections.clone();
        sections.update(cx, |s, cx| {
            for key in &keys {
                s.set_collapsed(key, collapsed, cx);
            }
        });
    });
}

pub(super) fn open_item(item: AreaItem, cx: &mut AsyncApp) {
    cx.update(|cx| {
        let nav = cx.global::<AppState>().stores.navigation.clone();
        nav.update(cx, |n, cx| n.open_item(item, cx));
    });
}

pub(super) fn selection(cx: &mut App) -> Selection {
    cx.global::<AppState>()
        .stores
        .navigation
        .read(cx)
        .selection()
        .clone()
}

pub async fn run(inputs: &E2eInputs, dir: &Path, cx: &mut AsyncApp) -> bool {
    let (Some(a_url), Some(a_token), Some(b_url), Some(b_token)) = (
        inputs.get("HERMES_A_URL"),
        inputs.get("HERMES_A_TOKEN"),
        inputs.get("HERMES_B_URL"),
        inputs.get("HERMES_B_TOKEN"),
    ) else {
        return ok(
            "the gateways' env (HERMES_A_URL/_TOKEN, HERMES_B_URL/_TOKEN) is there",
            false,
        );
    };
    let Some((url, email, password)) = inputs.owui() else {
        return ok(NO_SERVER, false);
    };
    let mut pass = sign_in(&url, &email, &password, cx).await;
    let Some(main) = wait_main(cx).await else {
        return ok("main window", false);
    };

    // ── Settings › Hermes, nothing saved ─────────────────────────────
    cx.update(|cx| crate::open_settings(Some(crate::views::settings::Tab::Hermes), cx));
    let listed_none = wait_until(cx, Duration::from_secs(20), |cx| {
        admin(cx).read(cx).connections.is_some()
    })
    .await;
    pass &= ok(
        "Settings › Hermes lists no connection, Hermes off",
        listed_none && cx.update(connections).is_empty() && !cx.update(enabled),
    );
    let empty = shoot_settings(dir, "hermes-admin-settings-empty", cx).await;
    pass &= ok(
        "the empty pane offers the switch and Add Connection…",
        has(&empty, "Switch", "Enable Hermes Agent") && has(&empty, "Button", "Add Connection…"),
    );

    // ── The first connection: a Desktop Gateway with its token ───────
    pass &= ok(
        "Add Connection… opens the editor",
        open_editor(None, cx).await,
    );
    let (a_url2, a_token2) = (a_url.clone(), a_token.clone());
    in_sheet::<HermesConnectionSheet, _>(cx, move |s, w, cx| {
        fill_connection(s, A_NAME, &a_url2, Some(&a_token2), w, cx)
    });
    settle(cx, 300).await;
    shoot_sheet(dir, "hermes-admin-connection-new", cx).await;
    if let Some(handle) = cx.update(|cx| sheet::current_window(cx)) {
        let controls = ax(handle, "hermes-admin-connection-new", dir, cx).await;
        pass &= ok(
            "the editor has its fields, the token among them, Test and Save",
            has(&controls, "TextInput", "Server URL")
                && has(&controls, "PasswordInput", "")
                && has(&controls, "Button", "Test Connection")
                && has(&controls, "Button", "Save"),
        );
    }
    pass &= ok(
        "Test Connection reaches gateway A",
        test_connection(cx).await,
    );
    in_sheet::<HermesConnectionSheet, _>(cx, |s, w, cx| s.save(w, cx));
    pass &= ok("Save closes the editor", sheet_gone(cx).await);
    let saved = wait_until(cx, Duration::from_secs(20), |cx| {
        active_name(cx).as_deref() == Some(A_NAME) && enabled(cx)
    })
    .await;
    pass &= ok("the first connection is in use and Hermes on", saved);
    let a_listed = wait_until(cx, Duration::from_secs(60), |cx| listed(A_CHAT, cx)).await;
    pass &= ok("gateway A's sessions are listed in the sidebar", a_listed);
    let ready = wait_until(cx, Duration::from_secs(40), |cx| {
        let a = admin(cx);
        let a = a.read(cx);
        a.status
            .as_ref()
            .and_then(Loaded::ready)
            .is_some_and(|s| s.reachable)
            && a.catalog
                .as_ref()
                .and_then(Loaded::ready)
                .is_some_and(|c| c.skills.iter().any(|s| s.name == "packing-list"))
            && a.mcp
                .as_ref()
                .and_then(Loaded::ready)
                .is_some_and(|m| m.available)
    })
    .await;
    pass &= ok(
        "the gateway's status, skills (packing-list among them) and MCP servers are read",
        ready,
    );
    let pane_ax = shoot_settings(dir, "hermes-admin-settings", cx).await;
    pass &= ok(
        "the pane lists the connection with Edit…, the status, and the MCP actions",
        has(&pane_ax, "Button", A_NAME)
            && has(&pane_ax, "Button", "Edit…")
            && has(&pane_ax, "Button", "Refresh")
            && has(&pane_ax, "Button", "Review Schedules")
            && has(&pane_ax, "Button", "Add Server…"),
    );

    // ── Edit and test it: its token is kept, unseen ──────────────────
    let a_id = cx.update(|cx| connection_named(A_NAME, cx));
    pass &= ok(
        "Edit… opens its editor",
        open_editor(a_id.clone(), cx).await,
    );
    let hinted = cx.update(|cx| {
        sheet::current::<HermesConnectionSheet>(cx).is_some_and(|s| {
            let s = s.read(cx);
            s.token.read(cx).value().is_empty()
                && crate::views::forms::hint(&s.token, cx).is_some_and(|h| h.contains("Configured"))
        })
    });
    pass &= ok("the saved token is kept, not shown", hinted);
    pass &= ok(
        "Test Connection reaches it with the kept token",
        test_connection(cx).await,
    );
    in_sheet::<HermesConnectionSheet, _>(cx, |s, w, cx| {
        set_text(&s.name, A_RENAMED, w, cx);
        s.save(w, cx)
    });
    pass &= ok("Save closes the editor", sheet_gone(cx).await);
    let renamed = wait_until(cx, Duration::from_secs(20), |cx| {
        active_name(cx).as_deref() == Some(A_RENAMED)
    })
    .await;
    pass &= ok("the connection is renamed, still in use", renamed);

    // ── A second connection, saved beside it ─────────────────────────
    pass &= ok(
        "Add Connection… opens a new editor",
        open_editor(None, cx).await,
    );
    let (b_url2, b_token2) = (b_url.clone(), b_token.clone());
    in_sheet::<HermesConnectionSheet, _>(cx, move |s, w, cx| {
        fill_connection(s, B_NAME, &b_url2, Some(&b_token2), w, cx);
        s.save(w, cx)
    });
    pass &= ok("Save closes the editor", sheet_gone(cx).await);
    let beside = wait_until(cx, Duration::from_secs(20), |cx| {
        connections(cx).len() == 2 && active_name(cx).as_deref() == Some(A_RENAMED)
    })
    .await;
    pass &= ok(
        "the second connection is saved beside, the first still in use",
        beside,
    );

    // ── Switch from the sidebar's switcher: sessions follow ──────────
    // The Open WebUI account's sections come first and fill the list,
    // which only builds the rows it shows: close them while the Hermes
    // section is looked at.
    let others = set_others_collapsed(true, cx);
    settle(cx, 600).await;
    shoot_main(dir, "hermes-admin-sidebar", cx).await;
    let sidebar = ax(main, "hermes-admin-sidebar", dir, cx).await;
    pass &= ok(
        "the Hermes section names the connection and lists Scheduled Agents",
        has(&sidebar, "ComboBox", A_RENAMED) && has(&sidebar, "TreeItem", "Scheduled Agents"),
    );
    let b_id = cx.update(|cx| connection_named(B_NAME, cx));
    if let Some(b_id) = b_id.clone() {
        in_main(cx, move |_, window, cx| {
            window.dispatch_action(
                Box::new(crate::actions::HermesSwitchConnection {
                    connection_id: b_id,
                }),
                cx,
            )
        });
    }
    let switched = wait_until(cx, Duration::from_secs(60), |cx| {
        active_name(cx).as_deref() == Some(B_NAME) && listed(B_CHAT, cx) && !listed(A_CHAT, cx)
    })
    .await;
    pass &= ok(
        "switched to the second: its sessions replace the first's",
        switched,
    );
    pass &= ok("the switch is said", toast(B_NAME, cx).await);
    settle(cx, 400).await;
    shoot_main(dir, "hermes-admin-switched", cx).await;
    set_others_collapsed_list(&others, false, cx);
    // And back, from Settings.
    if let Some(a_id) = a_id.clone() {
        cx.update(|cx| {
            let stores = cx.global::<AppState>().stores.clone();
            crate::stores::hermes_admin::activate(&stores, &a_id, cx);
        });
    }
    let back = wait_until(cx, Duration::from_secs(60), |cx| {
        active_name(cx).as_deref() == Some(A_RENAMED) && listed(A_CHAT, cx) && !listed(B_CHAT, cx)
    })
    .await;
    pass &= ok("switched back: the first's sessions return", back);

    // ── MCP servers: add (a command), test, an API key, remove ───────
    let mcp_ready = wait_until(cx, Duration::from_secs(30), |cx| {
        admin(cx)
            .read(cx)
            .mcp
            .as_ref()
            .and_then(Loaded::ready)
            .is_some_and(|m| m.available)
    })
    .await;
    pass &= ok(
        "the MCP servers of the connection in use are read",
        mcp_ready,
    );
    in_settings(cx, |window, cx| {
        let stores = cx.global::<AppState>().stores.clone();
        crate::views::hermes_mcp::open_add(&stores, window, cx);
    });
    pass &= ok(
        "Add Server… opens its sheet",
        wait_sheet::<AddMcpSheet>(cx).await,
    );
    // The demo server (synthetic, stdlib only) at a neutral path, so no
    // screenshot carries this Mac's own folders (the runner copies it).
    let python = "/usr/bin/python3".to_string();
    let script = "-I\n/tmp/conduit-demo/demo_mcp.py".to_string();
    in_sheet::<AddMcpSheet, _>(cx, move |s, w, cx| {
        s.by_command = true;
        set_text(&s.name, MCP, w, cx);
        set_text(&s.command, &python, w, cx);
        let script = script.clone();
        s.args.update(cx, |a, cx| a.set_value(script, w, cx));
        cx.notify();
    });
    settle(cx, 300).await;
    shoot_sheet(dir, "hermes-admin-mcp-add", cx).await;
    in_sheet::<AddMcpSheet, _>(cx, |s, w, cx| s.add(w, cx));
    pass &= ok("Add closes the sheet", sheet_gone(cx).await);
    let added = wait_until(cx, Duration::from_secs(30), |cx| {
        mcp_servers(cx).iter().any(|(n, _)| n == MCP)
    })
    .await;
    pass &= ok("the MCP server is listed", added);
    pass &= ok(
        "its addition is said",
        toast(&format!("Added {MCP}"), cx).await,
    );
    choose_mcp(
        crate::views::settings::hermes::MCP_MENU,
        &format!("test:{MCP}"),
        cx,
    );
    pass &= ok(
        "Test Connection reaches it",
        toast(&format!("{MCP} is working"), cx).await,
    );
    let tools = wait_until(cx, Duration::from_secs(20), |cx| {
        mcp_servers(cx)
            .iter()
            .any(|(n, t)| n == MCP && t.iter().any(|t| t == "render_poster"))
    })
    .await;
    pass &= ok("the tools a test found show in its row", tools);
    let catalog = cx
        .update(|cx| {
            cx.global::<AppState>()
                .connection
                .read(cx)
                .rpc()
                .call::<methods::HermesMcpCatalog>(&NoParams)
        })
        .await;
    let entries = catalog.map(|c| c.entries).unwrap_or_default();
    pass &= ok(
        "Hermes's catalog offers ready-made servers",
        !entries.is_empty(),
    );
    pass &= catalog_values(&entries, inputs, dir, cx).await;
    settle(cx, 400).await;
    let with_mcp = shoot_settings(dir, "hermes-admin-settings-mcp", cx).await;
    pass &= ok(
        "the server's row has its labelled menu button",
        has(&with_mcp, "Button", &format!("Actions for {MCP}")),
    );
    choose_mcp(
        crate::views::settings::hermes::MCP_MENU,
        &format!("key:{MCP}"),
        cx,
    );
    pass &= ok(
        "Set API Key… opens its sheet",
        wait_sheet::<McpKeySheet>(cx).await,
    );
    in_sheet::<McpKeySheet, _>(cx, |s, w, cx| {
        set_text(&s.key, "demo-key-123", w, cx);
        s.save(w, cx)
    });
    pass &= ok("Save closes the sheet", sheet_gone(cx).await);
    pass &= ok(
        "the key is saved",
        toast(&format!("Saved the API key for {MCP}"), cx).await,
    );
    choose_mcp(
        crate::views::settings::hermes::MCP_MENU,
        &format!("remove:{MCP}"),
        cx,
    );
    // Gone from a list that was read, not from one still loading or failed.
    let removed = wait_until(cx, Duration::from_secs(30), |cx| {
        matches!(admin(cx).read(cx).mcp, Some(Loaded::Ready(_)))
            && !mcp_servers(cx).iter().any(|(n, _)| n == MCP)
    })
    .await;
    pass &= ok("Remove… (asked) removes the server", removed);

    // ── Scheduled Agents ─────────────────────────────────────────────
    cx.update(crate::desktop::show_main);
    open_item(AreaItem::HermesJobs, cx);
    let listed_jobs = wait_until(cx, Duration::from_secs(30), |cx| {
        matches!(admin(cx).read(cx).jobs, Some(Loaded::Ready(_)))
    })
    .await;
    pass &= ok("Scheduled Agents opens and lists the jobs", listed_jobs);
    settle(cx, 400).await;
    shoot_main(dir, "hermes-admin-jobs-empty", cx).await;
    in_main(cx, |mw, window, cx| {
        crate::views::hermes_job::open(&mw.stores.clone(), None, window, cx)
    });
    pass &= ok(
        "New Scheduled Job… opens the editor",
        wait_sheet::<HermesJobSheet>(cx).await,
    );
    let options = wait_until(cx, Duration::from_secs(20), |cx| {
        sheet::current::<HermesJobSheet>(cx).is_some_and(|s| s.read(cx).options.is_some())
    })
    .await;
    pass &= ok("the editor reads where jobs can deliver", options);
    let scheduling =
        cx.update(|cx| sheet::current::<HermesJobSheet>(cx).is_some_and(|s| s.read(cx).scheduling));
    pass &= ok(
        "a Desktop Gateway's editor asks delivery and missed runs",
        scheduling,
    );
    in_sheet::<HermesJobSheet, _>(cx, |s, w, cx| {
        set_text(&s.name, JOB, w, cx);
        s.prompt
            .update(cx, |p, cx| p.set_value(JOB_PROMPT.to_string(), w, cx));
        set_text(&s.schedule, "0 9 * * 1-5", w, cx);
        s.catch_up = 2;
        cx.notify();
    });
    settle(cx, 300).await;
    shoot_sheet(dir, "hermes-admin-job-editor", cx).await;
    if let Some(handle) = cx.update(|cx| sheet::current_window(cx)) {
        let controls = ax(handle, "hermes-admin-job-editor", dir, cx).await;
        pass &= ok(
            "the editor has its fields, missed-run choices and delivery checkboxes",
            has(&controls, "TextInput", "Name")
                && has(&controls, "RadioButton", "Skip Missed Runs")
                && has(&controls, "CheckBox", "Save in Hermes"),
        );
    }
    in_sheet::<HermesJobSheet, _>(cx, |s, w, cx| s.save(w, cx));
    pass &= ok("Save closes the editor", sheet_gone(cx).await);
    let created = wait_until(cx, Duration::from_secs(20), |cx| job(cx).is_some()).await;
    pass &= ok("the job is listed", created);
    let made = cx.update(job);
    pass &= ok(
        "it keeps its schedule, delivery and missed-run choice",
        made.as_ref().is_some_and(|j| {
            j.schedule == "0 9 * * 1-5"
                && j.catch_up == "skip"
                && j.deliver.iter().any(|d| d.kind == "local")
        }),
    );
    let Some(job_id) = made.map(|j| j.id) else {
        return ok("the job's id", false);
    };

    // Run Now, then Stop while it runs.
    let id = job_id.clone();
    cx.update(|cx| {
        let stores = cx.global::<AppState>().stores.clone();
        let rpc = stores.connection.read(cx).rpc();
        let call = rpc.call::<methods::HermesRunJob>(&conduit_protocol::HermesJobRef {
            connection: stores.hermes_admin.read(cx).connection(),
            id,
        });
        crate::stores::hermes_admin::act(
            &stores,
            call,
            "run failed".into(),
            |a, jobs, cx| a.adopt_jobs(jobs, cx),
            cx,
        );
    });
    let running = wait_until(cx, Duration::from_secs(15), |cx| {
        job(cx).is_some_and(|j| j.running)
    })
    .await;
    pass &= ok("Run Now: the job runs (Running now)", running);
    settle(cx, 300).await;
    shoot_main(dir, "hermes-admin-job-running", cx).await;
    let jobs_ax = ax(main, "hermes-admin-job-running", dir, cx).await;
    pass &= ok(
        "a running job offers Stop beside Run Now",
        has(&jobs_ax, "Button", "Stop") && has(&jobs_ax, "Button", "Run Now"),
    );
    let id = job_id.clone();
    cx.update(|cx| {
        let stores = cx.global::<AppState>().stores.clone();
        let rpc = stores.connection.read(cx).rpc();
        let call = rpc.call::<methods::HermesJobsStop>(&conduit_protocol::HermesJobRef {
            connection: stores.hermes_admin.read(cx).connection(),
            id,
        });
        crate::stores::hermes_admin::act(
            &stores,
            call,
            "stop failed".into(),
            |a, jobs, cx| a.adopt_jobs(jobs, cx),
            cx,
        );
    });
    let stopped = wait_until(cx, Duration::from_secs(40), |cx| {
        job(cx).is_some_and(|j| !j.running && !j.stopping)
    })
    .await;
    pass &= ok("Stop ends the run", stopped);
    pass &= ok(
        "how the Stop ended is said",
        wait_until(cx, Duration::from_secs(30), |cx| {
            toasts(cx)
                .iter()
                .any(|t| t.contains("Run stopped") || t.contains("finished before"))
        })
        .await,
    );

    // Run again, to its end: a run in the history, opened as a chat. The
    // gateway may refuse a trigger while the stopped run winds down: ask
    // again a few times.
    let mut started = false;
    for _ in 0..4 {
        let id = job_id.clone();
        cx.update(|cx| {
            let stores = cx.global::<AppState>().stores.clone();
            let rpc = stores.connection.read(cx).rpc();
            let call = rpc.call::<methods::HermesRunJob>(&conduit_protocol::HermesJobRef {
                connection: stores.hermes_admin.read(cx).connection(),
                id,
            });
            crate::stores::hermes_admin::act(
                &stores,
                call,
                "run failed".into(),
                |a, jobs, cx| a.adopt_jobs(jobs, cx),
                cx,
            );
        });
        started = wait_until(cx, Duration::from_secs(8), |cx| {
            job(cx).is_some_and(|j| j.running)
        })
        .await;
        if started {
            break;
        }
        settle(cx, 3000).await;
    }
    let ran = started
        && wait_until(cx, Duration::from_secs(60), |cx| {
            job(cx).is_some_and(|j| !j.running)
        })
        .await;
    pass &= ok("a second run goes to its end", ran);
    let id = job_id.clone();
    cx.update(|cx| admin(cx).update(cx, |a, cx| a.toggle_runs(&id, cx)));
    let id = job_id.clone();
    let history = wait_until(cx, Duration::from_secs(20), move |cx| {
        admin(cx)
            .read(cx)
            .runs
            .get(&id)
            .and_then(Loaded::ready)
            .is_some_and(|r| !r.is_empty())
    })
    .await;
    pass &= ok("Run History lists its runs", history);
    settle(cx, 400).await;
    shoot_main(dir, "hermes-admin-job-history", cx).await;
    let run = cx.update(|cx| {
        admin(cx)
            .read(cx)
            .runs
            .get(&job_id)
            .and_then(Loaded::ready)
            .and_then(|r| r.first().cloned())
    });
    if let Some(run) = run {
        open_item(AreaItem::HermesSession(run.id.clone()), cx);
        let chat_id = format!("local:hermes_{}", run.id);
        let opened = wait_until(cx, Duration::from_secs(30), move |cx| {
            chat_store(cx).is_some_and(|s| {
                let s = s.read(cx);
                s.chat_id() == chat_id
                    && s.messages()
                        .iter()
                        .any(|m| m.role == "assistant" && m.content.contains("standup"))
            })
        })
        .await;
        pass &= ok("a run's result opens as a Hermes chat", opened);
        settle(cx, 600).await;
        shoot_main(dir, "hermes-admin-run-result", cx).await;
    } else {
        pass &= ok("a run to open", false);
    }

    // Pause it, then delete it (asked).
    open_item(AreaItem::HermesJobs, cx);
    settle(cx, 400).await;
    let id = job_id.clone();
    cx.update(|cx| {
        let stores = cx.global::<AppState>().stores.clone();
        let rpc = stores.connection.read(cx).rpc();
        let call = rpc.call::<methods::HermesSetJobEnabled>(&conduit_protocol::HermesJobToggle {
            id,
            enabled: false,
            connection: stores.hermes_admin.read(cx).connection(),
        });
        crate::stores::hermes_admin::act(
            &stores,
            call,
            "pause failed".into(),
            |a, jobs, cx| a.adopt_jobs(jobs, cx),
            cx,
        );
    });
    let paused = wait_until(cx, Duration::from_secs(20), |cx| {
        job(cx).is_some_and(|j| !j.enabled)
    })
    .await;
    pass &= ok("its switch pauses it", paused);
    settle(cx, 400).await;
    shoot_main(dir, "hermes-admin-job-paused", cx).await;
    let id = job_id.clone();
    in_main(cx, move |_, window, cx| {
        let stores = cx.global::<AppState>().stores.clone();
        crate::views::panes::hermes_jobs::confirm_delete(&stores, &id, window, cx);
    });
    let deleted = wait_until(cx, Duration::from_secs(30), |cx| {
        matches!(admin(cx).read(cx).jobs, Some(Loaded::Ready(_))) && job(cx).is_none()
    })
    .await;
    pass &= ok("Delete… (asked) deletes it", deleted);

    pass &= notify_me_kept(inputs, &a_url, &a_token, dir, cx).await;

    // ── `/` in a Hermes chat lists the agent's skills ────────────────
    let herb = cx.update(|cx| sessions(cx).into_iter().find(|s| s.title == A_CHAT));
    if let Some(herb) = herb {
        open_item(AreaItem::HermesSession(herb.id.clone()), cx);
        let chat_id = format!("local:hermes_{}", herb.id);
        let opened = wait_until(cx, Duration::from_secs(30), move |cx| {
            chat_store(cx).is_some_and(|s| s.read(cx).chat_id() == chat_id)
        })
        .await;
        pass &= ok("a Hermes session opens", opened);
        settle(cx, 600).await;
        super::chat::in_pane(cx, |p, window, cx| {
            p.composer.update(cx, |c, cx| {
                c.focus_input(window, cx);
                c.set_text("/pack", window, cx)
            })
        });
        let row = wait_until(cx, Duration::from_secs(20), |cx| {
            pane(cx).is_some_and(|p| {
                let composer = p.read(cx).composer.clone();
                composer
                    .read(cx)
                    .menu_rows(cx)
                    .is_some_and(|(_, rows)| rows.iter().any(|(_, t)| t == "/packing-list"))
            })
        })
        .await;
        pass &= ok("/ lists the agent's skills (/packing-list)", row);
        settle(cx, 300).await;
        shoot_main(dir, "hermes-admin-slash", cx).await;
        let index = cx.update(|cx| {
            pane(cx).and_then(|p| {
                let composer = p.read(cx).composer.clone();
                composer
                    .read(cx)
                    .menu_rows(cx)
                    .and_then(|(_, rows)| rows.iter().position(|(_, t)| t == "/packing-list"))
            })
        });
        if let Some(index) = index {
            super::chat::in_pane(cx, move |p, window, cx| {
                p.composer
                    .update(cx, |c, cx| c.choose_menu_item(index, window, cx))
            });
        }
        settle(cx, 400).await;
        let text = cx.update(|cx| {
            pane(cx)
                .map(|p| p.read(cx).composer.read(cx).text(cx))
                .unwrap_or_default()
        });
        pass &= ok(
            &format!("choosing it writes the command ({text:?})"),
            text == "/packing-list ",
        );
        super::chat::in_pane(cx, |p, window, cx| {
            p.composer.update(cx, |c, cx| c.set_text("", window, cx))
        });
    } else {
        pass &= ok("the herb garden session", false);
    }

    // ── Hermes off and on ────────────────────────────────────────────
    cx.update(|cx| {
        let stores = cx.global::<AppState>().stores.clone();
        crate::stores::hermes_admin::set_enabled(&stores, false, cx);
    });
    let off = wait_until(cx, Duration::from_secs(30), |cx| {
        !enabled(cx)
            && !cx
                .global::<AppState>()
                .stores
                .session
                .read(cx)
                .capabilities()
                .hermes
    })
    .await;
    pass &= ok("Hermes off: its section goes", off);
    let left = wait_until(cx, Duration::from_secs(10), |cx| {
        !matches!(selection(cx), Selection::Area(AreaItem::HermesSession(_)))
    })
    .await;
    pass &= ok("the Hermes chat left open makes way for a new chat", left);
    cx.update(|cx| {
        let stores = cx.global::<AppState>().stores.clone();
        crate::stores::hermes_admin::set_enabled(&stores, true, cx);
    });
    let on = wait_until(cx, Duration::from_secs(60), |cx| {
        enabled(cx) && listed(A_CHAT, cx)
    })
    .await;
    pass &= ok("Hermes on: its sessions are back", on);

    // ── Delete the second connection (asked) ─────────────────────────
    cx.update(|cx| crate::open_settings(Some(crate::views::settings::Tab::Hermes), cx));
    settle(cx, 400).await;
    pass &= ok("its editor opens", open_editor(b_id, cx).await);
    in_sheet::<HermesConnectionSheet, _>(cx, |s, w, cx| s.delete(w, cx));
    pass &= ok("Delete… closes the editor", sheet_gone(cx).await);
    let one = wait_until(cx, Duration::from_secs(20), |cx| {
        connections(cx).len() == 1 && active_name(cx).as_deref() == Some(A_RENAMED)
    })
    .await;
    pass &= ok("one connection left, still in use", one);
    pass
}

/// Gateway A's jobs over its REST (`/usr/bin/curl`, as a phone or the web
/// would have made them): `method` on `path`, with `body`.
fn gateway(
    url: &str,
    token: &str,
    method: &str,
    path: &str,
    body: Option<&str>,
) -> Option<serde_json::Value> {
    let mut command = std::process::Command::new("/usr/bin/curl");
    command
        .args(["-s", "-m", "15", "-X", method])
        .arg("-H")
        .arg(format!("Authorization: Bearer {token}"))
        .args(["-H", "content-type: application/json"]);
    if let Some(body) = body {
        command.args(["-d", body]);
    }
    let out = command
        .arg(format!("{}{path}", url.trim_end_matches('/')))
        .output()
        .ok()?;
    serde_json::from_slice(&out.stdout).ok()
}

/// A phone's Notify Me (`conduit` among a job's targets) survives an edit
/// made here: the editor neither lists nor drops it.
async fn notify_me_kept(
    inputs: &E2eInputs,
    url: &str,
    token: &str,
    dir: &Path,
    cx: &mut AsyncApp,
) -> bool {
    let _ = inputs;
    const NOTIFY: &str = "Seed watering reminder";
    let made = gateway(
        url,
        token,
        "POST",
        "/api/cron/jobs",
        Some(
            r#"{"name":"Seed watering reminder","prompt":"Remind me to water the seed trays.","schedule":"0 7 * * *","deliver":"local,conduit"}"#,
        ),
    );
    let Some(id) = made
        .as_ref()
        .and_then(|v| v["id"].as_str())
        .map(String::from)
    else {
        return ok("a job with Notify Me made on the gateway", false);
    };
    cx.update(|cx| admin(cx).update(cx, |a, cx| a.refresh_jobs(cx)));
    let listed = wait_until(cx, Duration::from_secs(30), |cx| {
        jobs(cx).iter().any(|j| j.name.as_deref() == Some(NOTIFY))
    })
    .await;
    let mut pass = ok("the phone's job is listed", listed);
    let job = cx.update(|cx| {
        jobs(cx)
            .into_iter()
            .find(|j| j.name.as_deref() == Some(NOTIFY))
    });
    pass &= ok(
        "its Notify Me is not one of the targets shown",
        job.as_ref().is_some_and(|j| {
            j.deliver.iter().any(|d| d.kind == "local")
                && !j.deliver.iter().any(|d| d.target == "conduit")
        }),
    );
    in_main(cx, move |mw, window, cx| {
        crate::views::hermes_job::open(&mw.stores.clone(), job, window, cx)
    });
    pass &= ok("its editor opens", wait_sheet::<HermesJobSheet>(cx).await);
    let options = wait_until(cx, Duration::from_secs(20), |cx| {
        sheet::current::<HermesJobSheet>(cx).is_some_and(|s| s.read(cx).options.is_some())
    })
    .await;
    pass &= ok(
        "the delivery list offers no Conduit target",
        options
            && cx.update(|cx| {
                sheet::current::<HermesJobSheet>(cx).is_some_and(|s| {
                    s.read(cx)
                        .options
                        .as_ref()
                        .is_some_and(|o| !o.options.iter().any(|t| t.target == "conduit"))
                })
            }),
    );
    in_sheet::<HermesJobSheet, _>(cx, |s, w, cx| {
        s.prompt.update(cx, |p, cx| {
            p.set_value(
                "Remind me to water the seed trays and the basil.".to_string(),
                w,
                cx,
            )
        });
        cx.notify();
    });
    settle(cx, 300).await;
    shoot_sheet(dir, "hermes-admin-job-notify-me", cx).await;
    in_sheet::<HermesJobSheet, _>(cx, |s, w, cx| s.save(w, cx));
    pass &= ok("Save closes the editor", sheet_gone(cx).await);
    let stored = wait_until(cx, Duration::from_secs(20), |cx| {
        jobs(cx)
            .iter()
            .any(|j| j.name.as_deref() == Some(NOTIFY) && j.prompt.contains("basil"))
    })
    .await;
    let on_gateway = gateway(url, token, "GET", "/api/cron/jobs", None).and_then(|v| {
        v.as_array()?
            .iter()
            .find(|j| j["id"] == id.as_str())
            .map(|j| {
                (
                    j["deliver"].as_str().unwrap_or_default().to_string(),
                    j["prompt"].clone(),
                )
            })
    });
    pass &= ok(
        "the edit is saved, and Hermes still delivers to Conduit",
        stored
            && on_gateway.as_ref().is_some_and(|(deliver, prompt)| {
                deliver.split(',').any(|t| t.trim() == "conduit")
                    && prompt.as_str().is_some_and(|p| p.contains("basil"))
            }),
    );
    if !pass {
        println!("SMOKE note notify-me job on the gateway: {on_gateway:?}");
    }
    gateway(url, token, "DELETE", &format!("/api/cron/jobs/{id}"), None);
    cx.update(|cx| admin(cx).update(cx, |a, cx| a.refresh_jobs(cx)));
    pass
}
