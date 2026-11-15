//! `--e2e offline-setup` and `--e2e offline`: a signed-in account whose
//! server is out of reach when the app opens. `crates/app/e2e-offline.sh`
//! runs both, and between the two it makes a chat on the server
//! (`owui.sh chat`) and stops the server.
//!
//! * `offline-setup`: a fresh profile, the server form, a password sign-in,
//!   and the main frame with the seeded chats. Then the app quits.
//! * `offline`: restarts conduitd once while the window is still opening, then
//!   expects the main frame from what the daemon stored: the stored chats,
//!   with the offline banner and without the chat made meanwhile. It starts
//!   the server again (`owui.sh start`) and expects the banner to go and
//!   that chat to appear in the sidebar, with no relaunch.

use std::path::Path;
use std::process::Command;
use std::time::{Duration, Instant};

use gpui_kit::{App, AsyncApp};

use super::*;
use crate::stores::connection::DaemonPhase;

/// Where the wrapper's `owui.sh chat` saved the chat the app has not seen.
const NEW_CHAT_DIR: &str = "offline-chat";

pub async fn setup(inputs: &E2eInputs, dir: &Path, cx: &mut AsyncApp) -> bool {
    let Some((url, email, password)) = inputs.owui() else {
        return ok(NO_SERVER, false);
    };
    let mut pass = fresh_profile(cx).await;
    pass &= ok("the setup window opened", wait_setup(cx).await.is_some());
    in_setup(cx, |sw, window, cx| {
        sw.onboarding.update(cx, |o, cx| o.choose(window, cx))
    });
    settle(cx, 500).await;
    connect_server(&url, "Lab server", cx).await;
    pass &= wait_route(cx, Route::SignIn, Duration::from_secs(60)).await;
    sign_in_password(&email, &password, cx).await;
    pass &= wait_route(cx, Route::Main, Duration::from_secs(60)).await;
    pass &= wait_main(cx).await.is_some();
    // Synced at least once, so the next launch has chats to show.
    let listed = wait_until(cx, Duration::from_secs(60), |cx| chat_count(cx) > 0).await;
    pass &= ok("the seeded chats are listed", listed);
    settle(cx, 1500).await;
    shoot_main(dir, "offline-setup-main", cx).await;
    pass
}

pub async fn run(inputs: &E2eInputs, dir: &Path, cx: &mut AsyncApp) -> bool {
    if inputs.owui().is_none() {
        return ok(NO_SERVER, false);
    }
    let new_chat = match new_chat_id(dir) {
        Some(id) => id,
        None => {
            return ok(
                "a chat made while the app was closed (crates/app/e2e-offline.sh)",
                false,
            );
        }
    };

    // The daemon is restarted as soon as it is up: the window is still
    // opening (the route is unknown).
    let restarted = restart_first_daemon(cx).await;
    let mut pass = ok(
        "conduitd restarted once while the window was still opening",
        restarted == Some(Route::Unknown),
    );
    pass &= wait_route(cx, Route::Main, Duration::from_secs(90)).await;

    let banner = wait_until(cx, Duration::from_secs(60), |cx| {
        let session = cx.global::<AppState>().stores.session.clone();
        session.read(cx).server_unreachable(cx)
    })
    .await;
    pass &= ok("the offline banner shows over the main frame", banner);
    let stored = wait_until(cx, Duration::from_secs(30), |cx| chat_count(cx) > 0).await;
    pass &= ok("the stored chats are listed", stored);
    pass &= ok(
        "the chat made while the app was closed is not listed yet",
        cx.update(|cx| chat_by_id(&new_chat, cx)).is_none(),
    );
    settle(cx, 800).await;
    shoot_main(dir, "offline-main", cx).await;

    // The server comes back while the window is open.
    let started = cx
        .background_executor()
        .spawn(async { start_server() })
        .await;
    pass &= ok("owui.sh start", started);
    let back = wait_until(cx, Duration::from_secs(90), |cx| {
        let session = cx.global::<AppState>().stores.session.clone();
        let session = session.read(cx);
        session.server.is_some() && !session.server_unreachable(cx)
    })
    .await;
    pass &= ok("the offline banner goes once the server answers", back);
    pass &= wait_chat(
        &new_chat,
        "the chat made meanwhile appears without a relaunch",
        Duration::from_secs(90),
        |chat| chat.is_some(),
        cx,
    )
    .await;
    pass &= wait_route(cx, Route::Main, Duration::from_secs(10)).await;
    settle(cx, 800).await;
    shoot_main(dir, "offline-back", cx).await;
    pass
}

fn chat_count(cx: &mut App) -> usize {
    let list = cx.global::<AppState>().stores.chat_list.read(cx);
    list.list.as_ref().map_or(0, |l| l.chats.len())
}

/// The id in `<shots>/offline-chat/chat.json`, which `owui.sh chat` wrote.
fn new_chat_id(dir: &Path) -> Option<String> {
    let text = std::fs::read_to_string(dir.join(NEW_CHAT_DIR).join("chat.json")).ok()?;
    let chat: Value = serde_json::from_str(&text).ok()?;
    chat.get("id")?.as_str().map(str::to_string)
}

/// Waits for the first daemon to be up, has its supervisor stop it and
/// starts a fresh one, and returns the route at that moment. None if it
/// never came up. Only the supervisor signals the daemon: a pid read here
/// could already belong to another process.
async fn restart_first_daemon(cx: &mut AsyncApp) -> Option<Route> {
    let deadline = Instant::now() + Duration::from_secs(60);
    loop {
        let restarted = cx.update(|cx| {
            let connection = cx.global::<AppState>().connection.clone();
            if !matches!(connection.read(cx).daemon, DaemonPhase::Running { .. }) {
                return None;
            }
            let route = current_route(cx);
            connection
                .update(cx, |c, cx| c.restart_daemon(cx))
                .then_some(route)
        });
        if let Some(route) = restarted {
            println!("e2e: restarted conduitd (route {route:?})");
            return Some(route);
        }
        if Instant::now() > deadline {
            return None;
        }
        cx.background_executor()
            .timer(Duration::from_millis(5))
            .await;
    }
}

/// `owui.sh start` from the repo (the app runs with `--cwd desktop/`; the
/// instance comes from `CONDUIT_OWUI_DIR`, which run.sh forwards).
fn start_server() -> bool {
    Command::new("../tool/local_owui/owui.sh")
        .arg("start")
        .status()
        .is_ok_and(|s| s.success())
}
