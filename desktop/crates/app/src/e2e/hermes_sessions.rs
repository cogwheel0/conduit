//! `--e2e hermes-sessions`: Hermes sessions and their history,
//! against a real local Hermes Desktop gateway (`hermes serve` with a
//! scripted model, seeded with synthetic chats by real turns) and, for a
//! session another Hermes app owns, the fake API server.
//!
//! From a fresh profile, Hermes on the gateway (chosen in onboarding:
//! Hermes alone), then: the seeded sessions listed; one opened in the chat
//! pane and a turn sent in it, its row spinning meanwhile; a switch to a
//! second model Hermes holds (its context-cache guard) asked about in the
//! chat, kept (the question stays in the chat) and then confirmed, the answer
//! headed with the model's name, not Hermes' agent id; Pin and Unpin,
//! Rename in the row, Fork, Archive and Unarchive, Hide (Hidden Chats
//! lists it, Unhide brings it back), Branch from Here on a reply, Undo
//! Last Turn, Delete…; then the connection moved to the fake API server,
//! where Show Scheduled Runs off hides a scheduled agent's run (the
//! sidebar counts it, with Show), and a Hermes CLI session opens read-only
//! with the phone's notice and goes on in a copy. Screenshots in light and dark, AccessKit checks.
//!
//! Inputs, besides the local Open WebUI's env file (`FAKE_HERMES_URL`,
//! `FAKE_HERMES_KEY`): `HERMES_GATEWAY_URL` and `HERMES_GATEWAY_TOKEN`
//! (the gateway's legacy session token), in the same env file.

use std::path::Path;
use std::time::Duration;

use conduit_daemon::RpcMethod;
use conduit_protocol::{HermesSessionDto, HermesSettingsEdit, methods};
use gpui_kit::{App, AsyncApp};

use super::chat::{chat_store, in_pane, send};
use super::{
    E2eInputs, ax, fresh_profile, has, in_main, ok, settle, shoot_main, wait_main, wait_route,
    wait_setup, wait_until,
};
use crate::AppState;
use crate::smoke::current_route;
use crate::stores::navigation::{AreaItem, Selection};
use crate::stores::session::Route;
use crate::views::hermes_sessions::HermesCommand;

/// The gateway's seeded sessions: three synthetic chats, each started by
/// a real turn before the pass (the herb garden has two).
const HERB: &str = "Balcony herb garden";
const BREAD: &str = "Weekend sourdough schedule";
const TRIP: &str = "Three-day coastal trip";
/// The fake API server's session from the Hermes CLI.
const SHED: &str = "Shed shelves";

async fn call<M: RpcMethod>(params: &M::Params, cx: &mut AsyncApp) -> bool
where
    M::Result: Send + 'static,
{
    let rpc = cx.update(|cx| cx.global::<AppState>().connection.read(cx).rpc());
    match rpc.call::<M>(params).await {
        Ok(_) => true,
        Err(e) => {
            println!("SMOKE note {} failed: {e}", M::NAME);
            false
        }
    }
}

/// The Hermes list as the sidebar has it: listed, then archived.
fn listed(cx: &mut App) -> (Vec<HermesSessionDto>, Vec<HermesSessionDto>) {
    let areas = cx.global::<AppState>().stores.areas.read(cx);
    areas
        .hermes
        .as_ref()
        .map(|h| (h.sessions.clone(), h.archived.clone()))
        .unwrap_or_default()
}

fn titled(title: &str, cx: &mut App) -> Option<HermesSessionDto> {
    let (sessions, archived) = listed(cx);
    sessions
        .into_iter()
        .chain(archived)
        .find(|s| s.title == title)
}

fn hidden(cx: &mut App) -> Vec<HermesSessionDto> {
    let areas = cx.global::<AppState>().stores.areas.read(cx);
    match &areas.hermes_hidden {
        Some(Ok(sessions)) => sessions.clone(),
        _ => vec![],
    }
}

fn selection(cx: &mut App) -> Selection {
    cx.global::<AppState>()
        .stores
        .navigation
        .read(cx)
        .selection()
        .clone()
}

fn toasts(cx: &mut App) -> Vec<String> {
    let toasts = cx.global::<AppState>().stores.toasts.read(cx);
    toasts.toasts.iter().map(|t| t.message.clone()).collect()
}

fn open(id: &str, cx: &mut AsyncApp) {
    let item = AreaItem::HermesSession(id.to_string());
    cx.update(|cx| {
        let nav = cx.global::<AppState>().stores.navigation.clone();
        nav.update(cx, |n, cx| n.open_item(item, cx));
    });
}

fn run(id: &str, command: HermesCommand, cx: &mut AsyncApp) {
    let id = id.to_string();
    in_main(cx, move |mw, window, cx| {
        mw.run_hermes(&id, command, window, cx)
    });
}

/// The open chat is session `id`'s, read: its messages and how many.
async fn opened(id: &str, cx: &mut AsyncApp) -> Option<usize> {
    let chat_id = format!("local:hermes_{id}");
    let done = wait_until(cx, Duration::from_secs(30), |cx| {
        chat_store(cx).is_some_and(|s| {
            let s = s.read(cx);
            s.chat_id() == chat_id && s.hermes().is_some() && !s.messages().is_empty()
        })
    })
    .await;
    if !done {
        return None;
    }
    cx.update(|cx| chat_store(cx).map(|s| s.read(cx).messages().len()))
}

fn messages(cx: &mut App) -> Vec<(String, String, String)> {
    chat_store(cx)
        .map(|s| {
            s.read(cx)
                .messages()
                .iter()
                .map(|m| (m.id.clone(), m.role.clone(), m.content.clone()))
                .collect()
        })
        .unwrap_or_default()
}

pub async fn run_scenario(inputs: &E2eInputs, dir: &Path, cx: &mut AsyncApp) -> bool {
    let (Some(gateway), Some(token)) = (
        inputs.get("HERMES_GATEWAY_URL"),
        inputs.get("HERMES_GATEWAY_TOKEN"),
    ) else {
        return ok(
            "the Hermes gateway's env (HERMES_GATEWAY_URL, HERMES_GATEWAY_TOKEN) is there",
            false,
        );
    };
    let routed = wait_until(cx, Duration::from_secs(90), |cx| {
        current_route(cx) != Route::Unknown
    })
    .await;
    let mut pass = ok("routed", routed);
    if cx.update(current_route) != Route::Onboarding {
        pass &= fresh_profile(cx).await;
    }
    pass &= ok("the setup window opened", wait_setup(cx).await.is_some());

    // ── Hermes on the gateway, chosen in onboarding ──────────────────
    let edit: HermesSettingsEdit = serde_json::from_value(serde_json::json!({
        "enabled": true,
        "baseUrl": gateway,
        "mode": "desktop",
        "desktopAuthKind": "legacyToken",
        "legacyToken": token,
        "onboarding": true,
    }))
    .expect("a Hermes edit");
    pass &= ok(
        "Hermes on the Desktop Gateway, with its session token",
        call::<methods::HermesSaveSettings>(&edit, cx).await,
    );
    pass &= wait_route(cx, Route::Main, Duration::from_secs(60)).await;
    let Some(main) = wait_main(cx).await else {
        return ok("main window", false);
    };
    let seeded = wait_until(cx, Duration::from_secs(60), |cx| {
        [HERB, BREAD, TRIP]
            .iter()
            .all(|title| titled(title, cx).is_some())
    })
    .await;
    pass &= ok("the gateway's sessions are listed", seeded);
    let Some(herb) = cx.update(|cx| titled(HERB, cx)) else {
        return ok("the herb garden session", false);
    };
    let Some(trip) = cx.update(|cx| titled(TRIP, cx)) else {
        return ok("the coastal trip session", false);
    };
    settle(cx, 600).await;
    shoot_main(dir, "hermes-sessions", cx).await;
    let controls = ax(main, "hermes-sessions", dir, cx).await;
    pass &= ok(
        "the sessions are rows of the sidebar's outline, Hidden Chats among them",
        has(&controls, "TreeItem", HERB) && has(&controls, "TreeItem", "Hidden Chats"),
    );

    // ── Open a session in the chat pane, and answer in it ────────────
    open(&herb.id, cx);
    let before = opened(&herb.id, cx).await;
    pass &= ok(
        "a session opens in the chat pane with its transcript",
        before.is_some_and(|n| n >= 4),
    );
    let before = before.unwrap_or_default();
    pass &= ok(
        "the chat pane, not a placeholder, shows it",
        in_main(cx, |mw, _, cx| mw.shows_chat(cx)).unwrap_or(false),
    );
    let gateway_abilities = cx.update(|cx| {
        chat_store(cx)
            .map(|s| s.read(cx).abilities())
            .unwrap_or_default()
    });
    pass &= ok(
        "a gateway session offers Branch from Here and Undo Last Turn",
        gateway_abilities.branch_from_here && gateway_abilities.undo_last_turn,
    );
    send("Which of those grow well indoors?", cx).await;
    let spun = wait_until(cx, Duration::from_secs(20), |cx| {
        titled(HERB, cx).is_some_and(|s| s.running)
    })
    .await;
    pass &= ok("its row spins while the reply is written", spun);
    let answered = wait_until(cx, Duration::from_secs(60), |cx| {
        let n = messages(cx).len();
        n >= before + 2
            && chat_store(cx).is_some_and(|s| !s.read(cx).is_streaming())
            && messages(cx)
                .last()
                .is_some_and(|(_, role, text)| role == "assistant" && !text.trim().is_empty())
    })
    .await;
    pass &= ok("a turn sent in the session is answered there", answered);
    // Read again from the gateway once the turn settled: the question shows
    // once (its id is the one the window gave it).
    settle(cx, 1500).await;
    let asked = cx.update(|cx| {
        messages(cx)
            .iter()
            .filter(|(_, role, text)| role == "user" && text.contains("indoors"))
            .count()
    });
    pass &= ok(
        "the question shows once after the chat is read again",
        asked == 1,
    );
    let stopped = wait_until(cx, Duration::from_secs(30), |cx| {
        titled(HERB, cx).is_some_and(|s| !s.running)
    })
    .await;
    pass &= ok("the spinner stops with the reply", stopped);
    settle(cx, 600).await;
    shoot_main(dir, "hermes-session-open", cx).await;
    let controls = ax(main, "hermes-session-open", dir, cx).await;
    pass &= ok(
        "the open session's row is selected",
        controls
            .iter()
            .any(|c| c.starts_with("TreeItem:") && c.contains(HERB) && c.contains("selected")),
    );

    // ── Pin, Unpin ───────────────────────────────────────────────────
    run(&herb.id, HermesCommand::Pin, cx);
    let pinned = wait_until(cx, Duration::from_secs(20), |cx| {
        listed(cx)
            .0
            .first()
            .is_some_and(|s| s.id == herb.id && s.pinned)
    })
    .await;
    pass &= ok("Pin puts the session first, pinned", pinned);
    run(&herb.id, HermesCommand::Unpin, cx);
    pass &= ok(
        "Unpin",
        wait_until(cx, Duration::from_secs(20), |cx| {
            titled(HERB, cx).is_some_and(|s| !s.pinned)
        })
        .await,
    );

    // ── Rename, in its row ───────────────────────────────────────────
    const RENAMED: &str = "Herbs on the balcony";
    run(&herb.id, HermesCommand::Rename, cx);
    settle(cx, 300).await;
    let field = in_main(cx, |mw, _, cx| mw.sidebar.read(cx).rename_input()).flatten();
    pass &= ok("Rename… opens the name field in the row", field.is_some());
    if let Some(field) = field {
        in_main(cx, move |mw, window, cx| {
            field.update(cx, |i, cx| i.set_value(RENAMED, window, cx));
            mw.sidebar.update(cx, |s, cx| s.commit_rename(window, cx));
        });
    }
    pass &= ok(
        "the session takes its new name",
        wait_until(cx, Duration::from_secs(20), |cx| {
            titled(RENAMED, cx).is_some_and(|s| s.id == herb.id)
        })
        .await,
    );

    // ── Fork ─────────────────────────────────────────────────────────
    let count = cx.update(|cx| listed(cx).0.len());
    run(&trip.id, HermesCommand::Fork, cx);
    let forked = wait_until(cx, Duration::from_secs(30), |cx| {
        listed(cx).0.len() == count + 1
    })
    .await;
    pass &= ok("Fork adds a copy of the session to the list", forked);
    let fork = cx.update(|cx| {
        listed(cx)
            .0
            .into_iter()
            .find(|s| s.id != trip.id && s.title.contains("coastal"))
    });

    // ── Archive, Unarchive ───────────────────────────────────────────
    run(&trip.id, HermesCommand::Archive, cx);
    let archived = wait_until(cx, Duration::from_secs(20), |cx| {
        let (sessions, archived) = listed(cx);
        !sessions.iter().any(|s| s.id == trip.id) && archived.iter().any(|s| s.id == trip.id)
    })
    .await;
    pass &= ok("Archive moves it to the Archived row", archived);
    run(&trip.id, HermesCommand::Unarchive, cx);
    pass &= ok(
        "Unarchive lists it again",
        wait_until(cx, Duration::from_secs(20), |cx| {
            listed(cx).0.iter().any(|s| s.id == trip.id)
        })
        .await,
    );

    // ── Hide; Hidden Chats; Unhide ───────────────────────────────────
    run(&trip.id, HermesCommand::Hide, cx);
    let gone = wait_until(cx, Duration::from_secs(20), |cx| {
        let (sessions, archived) = listed(cx);
        !sessions
            .iter()
            .chain(archived.iter())
            .any(|s| s.id == trip.id)
    })
    .await;
    pass &= ok("Hide takes it out of every list", gone);
    let told = wait_until(cx, Duration::from_secs(5), |cx| {
        let said = cx.l10n_said_hidden();
        toasts(cx).contains(&said)
    })
    .await;
    pass &= ok("and says where to find it", told);
    cx.update(|cx| {
        let nav = cx.global::<AppState>().stores.navigation.clone();
        nav.update(cx, |n, cx| n.open_item(AreaItem::HermesHidden, cx));
    });
    let listed_hidden = wait_until(cx, Duration::from_secs(20), |cx| {
        hidden(cx).iter().any(|s| s.id == trip.id)
    })
    .await;
    pass &= ok("Hidden Chats lists it", listed_hidden);
    settle(cx, 600).await;
    shoot_main(dir, "hermes-hidden-chats", cx).await;
    let controls = ax(main, "hermes-hidden-chats", dir, cx).await;
    pass &= ok(
        "Hidden Chats: the chat to open, and Unhide",
        has(&controls, "Button", TRIP) && has(&controls, "Button", "Unhide"),
    );
    run(&trip.id, HermesCommand::Unhide, cx);
    let back = wait_until(cx, Duration::from_secs(20), |cx| {
        listed(cx).0.iter().any(|s| s.id == trip.id) && hidden(cx).is_empty()
    })
    .await;
    pass &= ok("Unhide lists it again, and Hidden Chats is empty", back);

    // ── Branch from Here ─────────────────────────────────────────────
    open(&herb.id, cx);
    let _ = opened(&herb.id, cx).await;
    let first_reply = cx.update(|cx| {
        messages(cx)
            .into_iter()
            .find(|(_, role, _)| role == "assistant")
            .map(|(id, _, _)| id)
    });
    let herb_chat = format!("local:hermes_{}", herb.id);
    if let Some(reply) = &first_reply {
        let (chat, reply) = (herb_chat.clone(), reply.clone());
        cx.update(|cx| {
            let stores = cx.global::<AppState>().stores.clone();
            crate::views::hermes_sessions::branch(&stores, &chat, &reply, cx);
        });
    }
    let branched = wait_until(
        cx,
        Duration::from_secs(40),
        |cx| matches!(selection(cx), Selection::Area(AreaItem::HermesSession(id)) if id != herb.id),
    )
    .await;
    pass &= ok("Branch from Here opens a new session", branched);
    let branch_id = match cx.update(selection) {
        Selection::Area(AreaItem::HermesSession(id)) => Some(id),
        _ => None,
    };
    if let Some(id) = &branch_id {
        let count = opened(id, cx).await;
        pass &= ok(
            "the branch holds the chat up to that reply",
            count == Some(2)
                && cx.update(|cx| {
                    messages(cx)
                        .first()
                        .is_some_and(|(_, _, text)| text.contains("balcony"))
                }),
        );
        settle(cx, 600).await;
        shoot_main(dir, "hermes-branch", cx).await;
    }

    // ── Undo Last Turn (a Desktop Gateway's) ─────────────────────────
    open(&herb.id, cx);
    let before = opened(&herb.id, cx).await.unwrap_or_default();
    cx.update(|cx| {
        let stores = cx.global::<AppState>().stores.clone();
        crate::views::hermes_sessions::undo(&stores, &herb_chat, cx);
    });
    let undone = wait_until(cx, Duration::from_secs(30), |cx| {
        messages(cx).len() + 2 == before
    })
    .await;
    pass &= ok(
        "Undo Last Turn takes the last question and reply away",
        undone,
    );
    pass &= ok(
        "and says so",
        wait_until(cx, Duration::from_secs(5), |cx| {
            let said = cx.l10n_said_undone();
            toasts(cx).contains(&said)
        })
        .await,
    );

    // ── Regenerate and edit, against the gateway's transcript ────────
    let count = cx.update(|cx| messages(cx).len());
    in_pane(cx, |p, _, cx| p.regenerate_last(cx));
    let regenerated = wait_until(cx, Duration::from_secs(60), |cx| {
        chat_store(cx).is_some_and(|s| !s.read(cx).is_streaming())
            && messages(cx).len() == count
            && messages(cx)
                .last()
                .is_some_and(|(_, role, text)| role == "assistant" && !text.trim().is_empty())
    })
    .await;
    settle(cx, 1500).await;
    pass &= ok(
        "Regenerate answers the last question again, in place",
        regenerated && cx.update(|cx| messages(cx).len()) == count,
    );
    const EDITED: &str = "Which of those grow well on a windowsill?";
    let last_question = cx.update(|cx| {
        messages(cx)
            .into_iter()
            .rev()
            .find(|(_, role, _)| role == "user")
            .map(|(id, _, _)| id)
    });
    if let Some(question) = last_question {
        cx.update(|cx| {
            if let Some(store) = chat_store(cx) {
                store.update(cx, |s, cx| s.edit(&question, EDITED.to_string(), cx));
            }
        });
    }
    let edited = wait_until(cx, Duration::from_secs(60), |cx| {
        let all = messages(cx);
        chat_store(cx).is_some_and(|s| !s.read(cx).is_streaming())
            && all.len() == count
            && all
                .iter()
                .any(|(_, role, text)| role == "user" && text == EDITED)
            && all
                .last()
                .is_some_and(|(_, role, text)| role == "assistant" && !text.trim().is_empty())
    })
    .await;
    pass &= ok(
        "an edited question replaces the last turn with its new answer",
        edited,
    );

    // ── Delete… ──────────────────────────────────────────────────────
    if let Some(fork) = fork {
        open(&fork.id, cx);
        let _ = opened(&fork.id, cx).await;
        run(&fork.id, HermesCommand::Delete, cx);
        let deleted = wait_until(cx, Duration::from_secs(20), |cx| {
            !listed(cx).0.iter().any(|s| s.id == fork.id)
                && matches!(selection(cx), Selection::New { .. })
        })
        .await;
        pass &= ok(
            "Delete… removes the open session, and a new chat shows",
            deleted,
        );
    } else {
        pass &= ok("the fork to delete", false);
    }

    // ── A model switch Hermes holds, in the coastal trip session (its
    // kept question stays in the chat, so the herb garden's checks above
    // run first) ──
    open(&trip.id, cx);
    let trip_before = opened(&trip.id, cx).await.unwrap_or_default();
    send("And if it rains on the second day?", cx).await;
    let warmed = wait_until(cx, Duration::from_secs(60), |cx| {
        messages(cx).len() >= trip_before + 2
            && chat_store(cx).is_some_and(|s| !s.read(cx).is_streaming())
            && messages(cx)
                .last()
                .is_some_and(|(_, role, text)| role == "assistant" && !text.trim().is_empty())
    })
    .await;
    pass &= ok("a turn gives the session context to keep", warmed);
    settle(cx, 1500).await;
    pass &= model_switch(main, dir, cx).await;

    // ── Another Hermes app's session, read-only, continued in a copy ──
    match (inputs.get("FAKE_HERMES_URL"), inputs.get("FAKE_HERMES_KEY")) {
        (Some(base_url), Some(key)) => {
            let edit: HermesSettingsEdit = serde_json::from_value(serde_json::json!({
                "enabled": true,
                "baseUrl": base_url,
                "mode": "responses",
                "apiKey": key,
            }))
            .expect("a Hermes edit");
            pass &= ok(
                "Hermes moved to the API server",
                call::<methods::HermesSaveSettings>(&edit, cx).await,
            );
            let shed =
                wait_until(cx, Duration::from_secs(30), |cx| titled(SHED, cx).is_some()).await;
            pass &= ok("the Hermes CLI's session is listed", shed);
            pass &= scheduled_runs(main, dir, cx).await;
            if let Some(shed) = cx.update(|cx| titled(SHED, cx)) {
                open(&shed.id, cx);
                let read_only = wait_until(cx, Duration::from_secs(30), |cx| {
                    chat_store(cx).is_some_and(|s| {
                        let s = s.read(cx);
                        s.chat_id() == format!("local:hermes_{}", shed.id) && s.hermes_read_only()
                    })
                })
                .await;
                pass &= ok("it opens read-only", read_only);
                let owner = cx.update(|cx| {
                    chat_store(cx)
                        .and_then(|s| s.read(cx).hermes().map(|h| h.owner.clone()))
                        .unwrap_or_default()
                });
                pass &= ok("naming the app that owns it", owner == "Hermes CLI");
                settle(cx, 600).await;
                shoot_main(dir, "hermes-read-only", cx).await;
                let controls = ax(main, "hermes-read-only", dir, cx).await;
                pass &= ok(
                    "the notice offers Continue Here and Continue in a Copy, not the composer",
                    has(&controls, "Button", "Continue Here")
                        && has(&controls, "Button", "Continue in a Copy")
                        && !controls
                            .iter()
                            .any(|c| c.starts_with("MultilineTextInput:")),
                );
                let originals = cx.update(|cx| messages(cx).len());
                in_pane(cx, |p, _, cx| p.continue_hermes(true, cx));
                let copied = wait_until(cx, Duration::from_secs(30), |cx| {
                    matches!(selection(cx), Selection::Area(AreaItem::HermesSession(id)) if id != shed.id)
                })
                .await;
                pass &= ok("Continue in a Copy opens a new session", copied);
                if let Selection::Area(AreaItem::HermesSession(copy)) = cx.update(selection) {
                    let count = opened(&copy, cx).await;
                    let writable = cx.update(|cx| {
                        chat_store(cx).is_some_and(|s| !s.read(cx).hermes_read_only())
                    });
                    pass &= ok(
                        "the copy keeps the chat's messages and can be answered",
                        count == Some(originals) && writable,
                    );
                    let title = cx.update(|cx| {
                        chat_store(cx)
                            .and_then(|s| s.read(cx).title().map(str::to_string))
                            .unwrap_or_default()
                    });
                    pass &= ok(
                        &format!("the copy keeps the chat's title ({title})"),
                        title == SHED,
                    );
                    settle(cx, 600).await;
                    shoot_main(dir, "hermes-copy", cx).await;
                }
            }
        }
        _ => pass &= ok("the fake Hermes API server's env is there", false),
    }
    pass
}

/// The words the E2E looks for in toasts.
trait Said {
    fn l10n_said_hidden(&self) -> String;
    fn l10n_said_undone(&self) -> String;
}

impl Said for App {
    fn l10n_said_hidden(&self) -> String {
        crate::l10n::ActiveL10n::l10n(self).desktop_hermes_chat_hidden()
    }
    fn l10n_said_undone(&self) -> String {
        crate::l10n::ActiveL10n::l10n(self).hermes_undo_last_turn_done()
    }
}

/// The fake API server's run of a scheduled agent (`gui-reset.sh` seeds it).
const RUN: &str = "Nightly seed-tray check";
/// What is asked on the model Hermes holds a switch to.
const SWITCHED_QUESTION: &str = "Which herbs want full sun?";

fn ui_top(cx: &mut App) -> Option<conduit_protocol::UiRequest> {
    cx.global::<AppState>()
        .stores
        .ui_requests
        .read(cx)
        .top()
        .cloned()
}

fn composer_text(cx: &mut App) -> String {
    super::chat::pane(cx)
        .map(|p| p.read(cx).composer.read(cx).text(cx))
        .unwrap_or_default()
}

fn selected_model(cx: &mut App) -> Option<String> {
    super::chat::pane(cx).and_then(|p| {
        p.read(cx)
            .composer_store
            .read(cx)
            .selected_model()
            .map(|m| m.id.clone())
    })
}

fn model_ending(suffix: &str, cx: &mut App) -> Option<String> {
    let pane = super::chat::pane(cx)?;
    let store = pane.read(cx).composer_store.clone();
    let s = store.read(cx);
    s.models
        .as_ref()?
        .models
        .iter()
        .find(|m| m.id.ends_with(suffix) || m.name == suffix)
        .map(|m| m.id.clone())
}

fn pick(id: &str, cx: &mut AsyncApp) {
    let id = id.to_string();
    in_pane(cx, move |p, _, cx| {
        let store = p.composer_store.clone();
        store.update(cx, |s, cx| s.select_model(&id, cx));
    });
}

fn answer(choice_allow: bool, cx: &mut AsyncApp) -> bool {
    in_main(cx, |mw, _, cx| {
        mw.approvals.update(cx, |v, cx| {
            if choice_allow {
                v.allow(cx)
            } else {
                v.deny(cx)
            }
        })
    })
    .unwrap_or(false)
}

/// Hermes holds a switch to another model (the recipe's context-cache
/// guard, `switch_context_confirm_tokens: 100`): the chat asks with
/// Hermes' reason; Keep Current Model sends nothing (the question stays in
/// the chat with its note, the composer and the picker as they were);
/// Switch and Send sends it on the new model.
async fn model_switch(main: gpui_kit::AnyWindowHandle, dir: &Path, cx: &mut AsyncApp) -> bool {
    let models = wait_until(cx, Duration::from_secs(30), |cx| {
        model_ending("demo-model-large", cx).is_some()
    })
    .await;
    let mut pass = ok("the gateway offers a second model", models);
    let Some(large) = cx.update(|cx| model_ending("demo-model-large", cx)) else {
        return ok("the models to switch between", false);
    };
    let before = cx.update(|cx| messages(cx).len());
    pick(&large, cx);
    settle(cx, 600).await;
    send(SWITCHED_QUESTION, cx).await;
    let asked = wait_until(cx, Duration::from_secs(40), |cx| {
        ui_top(cx).is_some_and(|r| r.kind == conduit_protocol::UiRequestKind::HermesModelSwitch)
    })
    .await;
    pass &= ok("the chat asks before Hermes switches its model", asked);
    let request = cx.update(ui_top);
    pass &= ok(
        "naming the model, with Hermes' own reason",
        request.as_ref().is_some_and(|r| {
            r.message_args
                .get("model")
                .is_some_and(|m| m.contains("demo-model-large"))
                && r.message_args
                    .get("reason")
                    .is_some_and(|m| m.contains("LARGE CONTEXT"))
        }),
    );
    settle(cx, 600).await;
    shoot_main(dir, "hermes-model-switch", cx).await;
    let controls = ax(main, "hermes-model-switch", dir, cx).await;
    pass &= ok(
        "its buttons are Keep Current Model and Switch and Send",
        has(&controls, "Button", "Keep Current Model") && has(&controls, "Button", "Switch"),
    );
    pass &= ok("Keep Current Model answers", answer(false, cx));
    settle(cx, 600).await;
    // A kept switch gives nothing back: the composer stays empty.
    let kept_empty = cx.update(|cx| composer_text(cx).is_empty());
    // Nothing went to Hermes: the question stays in the chat with the
    // core's note that the model was kept, and no answer.
    let noted = cx.update(|cx| {
        let all = messages(cx);
        let asked = all
            .iter()
            .rev()
            .find(|(_, role, _)| role == "user")
            .is_some_and(|(_, _, text)| text == SWITCHED_QUESTION);
        // The scripted model's answer never came.
        let answered = all.last().is_some_and(|(_, role, text)| {
            role == "assistant" && text.contains("Tell me a bit more")
        }) && all.len() > before + 1;
        asked && !answered
    });
    pass &= ok(
        "kept: the question stays in the chat, the composer stays empty, nothing sent",
        kept_empty && noted,
    );
    // The account's picker is left as the user set it.
    let left = cx.update(|cx| selected_model(cx).as_deref() == Some(large.as_str()));
    pass &= ok("and the picker is left as it was", left);
    settle(cx, 400).await;
    shoot_main(dir, "hermes-model-switch-kept", cx).await;

    // Asked again, and switched this time.
    send(SWITCHED_QUESTION, cx).await;
    let asked = wait_until(cx, Duration::from_secs(40), |cx| {
        ui_top(cx).is_some_and(|r| r.kind == conduit_protocol::UiRequestKind::HermesModelSwitch)
    })
    .await;
    pass &= ok("asked again on the next send", asked);
    pass &= ok("Switch and Send answers", answer(true, cx));
    let sent = wait_until(cx, Duration::from_secs(60), |cx| {
        let all = messages(cx);
        all.len() >= before + 2
            && all
                .iter()
                .any(|(_, role, text)| role == "user" && text == SWITCHED_QUESTION)
            && chat_store(cx).is_some_and(|s| !s.read(cx).is_streaming())
            && all
                .last()
                .is_some_and(|(_, role, text)| role == "assistant" && !text.trim().is_empty())
    })
    .await;
    pass &= ok(
        "switched: the words go out on the new model and are answered",
        sent,
    );
    // The answer's header names the model, as the phone's does: Hermes
    // answers a confirmed switch under an agent id no model on offer has
    // (`hermes:agent:…`), and the header falls back to the name the stored
    // answer kept.
    let named = wait_until(cx, Duration::from_secs(20), |cx| {
        answer_header(cx)
            .is_some_and(|(_, name)| !name.is_empty() && !name.starts_with("hermes:agent:"))
    })
    .await;
    let header = cx.update(answer_header);
    println!("SMOKE note switched answer's model and header {header:?}");
    pass &= ok(
        "its header names the model it answered on, not Hermes' agent id",
        named,
    );
    pass
}

/// The newest answer's model id and the name its header shows for it.
fn answer_header(cx: &mut App) -> Option<(String, String)> {
    let pane = super::chat::pane(cx)?;
    let store = chat_store(cx)?;
    let s = store.read(cx);
    let last = s.messages().iter().rposition(|m| m.role == "assistant")?;
    let item = s.item(crate::stores::chat::Row::Stored(last))?;
    let model = item.model?;
    let list = pane.read(cx).composer_store.read(cx).models.clone();
    let name = crate::stores::composer::answer_model_name(
        list.as_ref(),
        &model,
        item.model_name.as_deref(),
    );
    Some((model, name))
}

/// Show Scheduled Runs (Settings › Hermes) on the fake API server, whose
/// list cannot leave runs out itself: off, the run leaves the list and the
/// sidebar says how many are hidden, with Show; Show lists it again.
async fn scheduled_runs(main: gpui_kit::AnyWindowHandle, dir: &Path, cx: &mut AsyncApp) -> bool {
    let listed_run = wait_until(cx, Duration::from_secs(30), |cx| titled(RUN, cx).is_some()).await;
    let mut pass = ok("a scheduled agent's run is listed by default", listed_run);
    let set = |on: bool, cx: &mut AsyncApp| {
        cx.update(|cx| {
            let store = cx.global::<AppState>().stores.app_settings.clone();
            store.update(cx, |s, cx| {
                s.set(
                    conduit_protocol::AppSettingsPatch {
                        hermes_show_scheduled_sessions: Some(on),
                        ..Default::default()
                    },
                    cx,
                )
            });
        })
    };
    set(false, cx);
    let hidden = wait_until(cx, Duration::from_secs(30), |cx| {
        titled(RUN, cx).is_none()
            && cx
                .global::<AppState>()
                .stores
                .areas
                .read(cx)
                .hermes
                .as_ref()
                .is_some_and(|h| h.hidden_scheduled_runs == 1)
    })
    .await;
    pass &= ok(
        "Show Scheduled Runs off: the run leaves the list, counted",
        hidden,
    );
    let others = super::hermes_admin::set_others_collapsed(true, cx);
    settle(cx, 600).await;
    shoot_main(dir, "hermes-scheduled-hidden", cx).await;
    let controls = ax(main, "hermes-scheduled-hidden", dir, cx).await;
    pass &= ok(
        "the sidebar's row offers Show",
        has(&controls, "Button", "Show"),
    );
    super::hermes_admin::set_others_collapsed_list(&others, false, cx);
    // Show, as the row's button does.
    set(true, cx);
    let back = wait_until(cx, Duration::from_secs(30), |cx| titled(RUN, cx).is_some()).await;
    pass &= ok("Show lists it again", back);
    pass
}
