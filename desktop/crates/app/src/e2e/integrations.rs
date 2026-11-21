//! `--e2e integrations`: Settings › Personal Connections against the
//! local Open WebUI. With Advanced on, the pane lists none; Add Tool
//! Server… reads the fake model's OpenAPI document (Test Connection: one
//! operation) and saves it; the composer offers it; a turn that chooses it
//! has its `read_buoy` call run on this Mac (the fake server logs the call)
//! and the answer quotes the reading; it is renamed, switched off and
//! deleted. A terminal that can't be reached fails its test. Pane and
//! sheets are shot in light and dark. On a server that moved Personal
//! Connections into Tether (Open WebUI 0.13.4) it stops once the pane
//! opens, with a skip line.

use std::path::Path;
use std::time::Duration;

use conduit_protocol::{PersonalAccess, PersonalKind};
use gpui_kit::{AnyWindowHandle, AsyncApp, Entity};

use super::*;
use crate::views::settings::SettingsView;
use crate::views::settings::connection_editor::ConnectionEditorSheet;
use crate::views::settings::connections::PersonalConnectionsPane;
use crate::views::sheet;

const NAME: &str = "Harbour Buoys";
const RENAMED: &str = "Harbour Buoys East";

fn settings_view(cx: &mut App) -> Option<(AnyWindowHandle, Entity<SettingsView>)> {
    cx.try_global::<AppState>()?.settings_window.clone()
}

fn pane(cx: &mut App) -> Option<Entity<PersonalConnectionsPane>> {
    settings_view(cx)?.1.read(cx).personal_connections.clone()
}

fn in_pane<R>(
    cx: &mut AsyncApp,
    f: impl FnOnce(
        &mut PersonalConnectionsPane,
        &mut Window,
        &mut gpui_kit::Context<PersonalConnectionsPane>,
    ) -> R,
) -> Option<R> {
    let (handle, _) = cx.update(settings_view)?;
    let pane = cx.update(pane)?;
    handle
        .update(cx, |_, window, cx| {
            pane.update(cx, |p, cx| f(p, window, cx))
        })
        .ok()
}

fn in_sheet<R>(
    cx: &mut AsyncApp,
    f: impl FnOnce(
        &mut ConnectionEditorSheet,
        &mut Window,
        &mut gpui_kit::Context<ConnectionEditorSheet>,
    ) -> R,
) -> Option<R> {
    let handle = cx.update(|cx| sheet::current_window(cx))?;
    let entity = cx.update(|cx| sheet::current::<ConnectionEditorSheet>(cx))?;
    cx.update(|cx| {
        handle
            .update(cx, |_, window, cx| {
                entity.update(cx, |v, cx| f(v, window, cx))
            })
            .ok()
    })
}

async fn settings_shot(dir: &Path, name: &str, cx: &mut AsyncApp) {
    if let Some((handle, _)) = cx.update(settings_view) {
        settle(cx, 500).await;
        shoot_both_modes(handle, dir, name, cx).await;
    }
}

fn servers(cx: &mut App) -> Vec<conduit_protocol::PersonalConnectionDto> {
    pane(cx)
        .and_then(|p| p.read(cx).list.clone())
        .map(|l| l.tool_servers)
        .unwrap_or_default()
}

async fn wait_sheet(cx: &mut AsyncApp) -> bool {
    wait_until(cx, Duration::from_secs(10), |cx| {
        sheet::current::<ConnectionEditorSheet>(cx).is_some()
    })
    .await
}

async fn wait_closed(cx: &mut AsyncApp) -> bool {
    wait_until(cx, Duration::from_secs(20), |cx| !sheet::is_open(cx)).await
}

fn log_lines(path: &Option<std::path::PathBuf>) -> Vec<String> {
    path.as_ref()
        .and_then(|p| std::fs::read_to_string(p).ok())
        .map(|t| t.lines().map(str::to_string).collect())
        .unwrap_or_default()
}

pub async fn run(inputs: &E2eInputs, dir: &Path, cx: &mut AsyncApp) -> bool {
    let Some((url, email, password)) = inputs.owui() else {
        return ok(NO_SERVER, false);
    };
    let base = inputs
        .get("FAKE_OPENAI_URL")
        .map(|u| u.trim_end_matches('/').trim_end_matches("/v1").to_string())
        .unwrap_or_default();
    let log = inputs.get("FAKE_MODEL_LOG").map(std::path::PathBuf::from);
    let mut pass = super::chat::sign_in(&url, &email, &password, cx).await;
    pass &= ok("models listed", super::chat::wait_models(cx).await);

    // Behind Advanced, as on the phone.
    let hidden = cx.update(|cx| {
        let stores = cx.global::<AppState>().stores.clone();
        !Tab::visible(&stores, cx).contains(&Tab::PersonalConnections)
    });
    pass &= ok("Personal Connections waits for Advanced", hidden);
    cx.update(|cx| {
        let s = cx.global::<AppState>().stores.app_settings.clone();
        s.update(cx, |s, cx| {
            s.set(
                conduit_protocol::AppSettingsPatch {
                    advanced_features_enabled: Some(true),
                    ..Default::default()
                },
                cx,
            )
        });
    });
    let shown = wait_until(cx, Duration::from_secs(10), |cx| {
        let stores = cx.global::<AppState>().stores.clone();
        Tab::visible(&stores, cx).contains(&Tab::PersonalConnections)
    })
    .await;
    pass &= ok("with Advanced on, Personal Connections is listed", shown);
    let Some(h) = settings_tab(Tab::PersonalConnections, dir, "connections-empty", cx).await else {
        return ok("Settings › Personal Connections opened", false);
    };
    let loaded = wait_until(cx, Duration::from_secs(20), |cx| {
        pane(cx).is_some_and(|p| {
            p.read(cx).list.as_ref().is_some_and(|l| {
                (l.access == PersonalAccess::Allowed && !l.failed) || personal_moved_to_tether(l)
            })
        })
    })
    .await;
    pass &= ok("the account's connections load (none yet)", loaded);
    let moved = loaded
        && cx.update(|cx| {
            pane(cx).is_some_and(|p| {
                p.read(cx)
                    .list
                    .as_ref()
                    .is_some_and(personal_moved_to_tether)
            })
        });
    if moved {
        println!("SMOKE e2e skip Settings › Personal Connections: {MOVED_TO_TETHER}");
        return pass;
    }
    settings_shot(dir, "connections-empty", cx).await;
    let controls = ax(h, "connections-empty", dir, cx).await;
    pass &= ok(
        "the pane offers Add Tool Server… and Add Terminal…",
        has(&controls, "Button", "Add Tool Server") && has(&controls, "Button", "Add Terminal"),
    );

    // ── Add Tool Server… ──────────────────────────────────────────────
    in_pane(cx, |p, window, cx| {
        p.open_editor(PersonalKind::ToolServer, None, window, cx)
    });
    pass &= ok("Add Tool Server… opens a sheet", wait_sheet(cx).await);
    let server_url = format!("{base}/personal");
    in_sheet(cx, move |s, window, cx| {
        set_text(&s.name.clone(), NAME, window, cx);
        set_text(&s.description.clone(), "Invented buoy readings", window, cx);
        set_text(&s.url.clone(), &server_url, window, cx);
        s.auth_type = "none".into();
        cx.notify();
    });
    in_sheet(cx, |s, _, cx| s.press_test(cx));
    let tested = wait_until(cx, Duration::from_secs(20), |cx| {
        sheet::current::<ConnectionEditorSheet>(cx)
            .is_some_and(|s| s.read(cx).attempt.as_ref().is_some_and(|a| a.ok))
    })
    .await;
    let note = cx.update(|cx| {
        sheet::current::<ConnectionEditorSheet>(cx)
            .and_then(|s| s.read(cx).attempt.clone())
            .map(|a| a.text)
            .unwrap_or_default()
    });
    pass &= ok(
        &format!("Test Connection reads the OpenAPI document ({note})"),
        tested && note.contains('1'),
    );
    settings_shot(dir, "connection-editor-tool", cx).await;
    in_sheet(cx, |s, _, cx| s.save(cx));
    pass &= ok("Save closes the sheet", wait_closed(cx).await);
    let added = wait_until(cx, Duration::from_secs(10), |cx| {
        servers(cx).iter().any(|s| s.name == NAME && s.enabled)
    })
    .await;
    pass &= ok("the tool server lists, switched on", added);
    settings_shot(dir, "connections-listed", cx).await;

    // ── The composer offers it; a turn runs its tool here ─────────────
    let offered = wait_until(cx, Duration::from_secs(20), |cx| {
        super::chat::pane(cx).is_some_and(|p| {
            p.read(cx)
                .composer_store
                .read(cx)
                .options
                .tools
                .iter()
                .any(|t| t.name == NAME && t.id.starts_with("direct_server:"))
        })
    })
    .await;
    pass &= ok("the composer offers the personal tool server", offered);
    let tool_id = cx.update(|cx| {
        super::chat::pane(cx).and_then(|p| {
            p.read(cx)
                .composer_store
                .read(cx)
                .options
                .tools
                .iter()
                .find(|t| t.name == NAME)
                .map(|t| t.id.clone())
        })
    });
    if let Some(id) = tool_id {
        super::chat::in_pane(cx, move |p, _, cx| {
            p.composer_store.update(cx, |c, cx| c.toggle_tool(&id, cx))
        });
    }
    let mark = log_lines(&log).len();
    super::chat::send("What does the buoy say?", cx).await;
    let answered = super::chat::wait_answer(cx, Duration::from_secs(60)).await;
    let answer = cx.update(super::chat::last_answer_text);
    pass &= ok(
        &format!("the answer uses the tool's result ({answer})"),
        answered && answer.contains("North Mole buoy reads 0.8 m"),
    );
    let ran_here = log_lines(&log)
        .iter()
        .skip(mark)
        .any(|l| l.contains("\"personal_tool\"") && l.contains("read_buoy"));
    pass &= ok(
        "the tool call ran on this Mac (the tool server logged it)",
        ran_here,
    );
    shoot_main(dir, "connections-chat", cx).await;

    // ── Edit, switch off, delete ──────────────────────────────────────
    cx.update(|cx| crate::open_settings(Some(Tab::PersonalConnections), cx));
    settle(cx, 600).await;
    let entry = cx.update(|cx| servers(cx).into_iter().find(|s| s.name == NAME));
    in_pane(cx, move |p, window, cx| {
        p.open_editor(PersonalKind::ToolServer, entry, window, cx)
    });
    pass &= ok("Edit… opens the sheet", wait_sheet(cx).await);
    in_sheet(cx, |s, window, cx| {
        set_text(&s.name.clone(), RENAMED, window, cx)
    });
    settings_shot(dir, "connection-editor-edit", cx).await;
    in_sheet(cx, |s, _, cx| s.save(cx));
    pass &= ok("Save closes the sheet", wait_closed(cx).await);
    let renamed = wait_until(cx, Duration::from_secs(10), |cx| {
        servers(cx).iter().any(|s| s.name == RENAMED)
    })
    .await;
    pass &= ok("the tool server is renamed", renamed);
    let entry = cx.update(|cx| servers(cx).into_iter().find(|s| s.name == RENAMED));
    if let Some(entry) = entry.clone() {
        in_pane(cx, move |p, _, cx| p.press_switch(&entry, false, cx));
    }
    let off = wait_until(cx, Duration::from_secs(10), |cx| {
        servers(cx).iter().any(|s| s.name == RENAMED && !s.enabled)
    })
    .await;
    pass &= ok("its switch turns it off", off);
    let entry = cx.update(|cx| servers(cx).into_iter().find(|s| s.name == RENAMED));
    in_pane(cx, move |p, window, cx| {
        p.open_editor(PersonalKind::ToolServer, entry, window, cx)
    });
    wait_sheet(cx).await;
    in_sheet(cx, |s, window, cx| s.press_delete(window, cx));
    pass &= ok("Delete… closes the sheet", wait_closed(cx).await);
    let gone = wait_until(cx, Duration::from_secs(10), |cx| servers(cx).is_empty()).await;
    pass &= ok("the tool server is deleted", gone);

    // ── A terminal that can't be reached ──────────────────────────────
    in_pane(cx, |p, window, cx| {
        p.open_editor(PersonalKind::Terminal, None, window, cx)
    });
    wait_sheet(cx).await;
    in_sheet(cx, |s, window, cx| {
        set_text(&s.name.clone(), "Dock Shell", window, cx);
        set_text(&s.url.clone(), "http://127.0.0.1:9", window, cx);
    });
    in_sheet(cx, |s, _, cx| s.press_test(cx));
    let failed = wait_until(cx, Duration::from_secs(20), |cx| {
        sheet::current::<ConnectionEditorSheet>(cx)
            .is_some_and(|s| s.read(cx).attempt.as_ref().is_some_and(|a| !a.ok))
    })
    .await;
    pass &= ok("a terminal that can't be reached fails its test", failed);
    settings_shot(dir, "connection-editor-terminal", cx).await;
    // Cancel asks first (edits); the pass answers yes.
    in_sheet(cx, |s, window, cx| {
        crate::views::sheet::SheetBody::cancel(s, window, cx)
    });
    pass &= ok("Cancel closes the sheet", wait_closed(cx).await);
    pass
}
