//! `--e2e hermes-rooms`: Hermes Bot Mode and Group Chats,
//! against a real local Hermes Desktop gateway (`hermes serve --isolated`
//! with a scripted model; three synthetic bots, Fern, Moss and Reed, Reed
//! with a picture).
//!
//! From a fresh profile, Hermes on the gateway (chosen in onboarding), then:
//! the Bots and Rooms groups in the sidebar; a bot's Bot Chat opened from
//! its row (its face and name in the toolbar and on its reply) and a
//! message answered there; New Room with two bots; a message with
//! `@mentions` typed through the composer's completion, both bots
//! answering with their names and faces; a debate that pauses at its
//! round limit, and Continue; a bot's approval answered on its card; Room
//! Info (purpose, notes, a lead bot) saved; Rename; Stop All Work while a
//! bot works; Disband Room…. Screenshots in light and dark, AccessKit
//! checks.
//!
//! Inputs, in the env file: `HERMES_GATEWAY_URL` and
//! `HERMES_GATEWAY_TOKEN` (the gateway's legacy session token).

use std::path::Path;
use std::time::Duration;

use conduit_daemon::RpcMethod;
use conduit_protocol::{
    HermesRoomItemDto, HermesRoomItemKind, HermesRoomRouteKind, HermesRoomRouting, HermesRoomView,
    HermesSettingsEdit, methods,
};
use gpui_kit::{App, AsyncApp};

use super::chat::{chat_store, send};
use super::{
    E2eInputs, ax, fresh_profile, has, in_main, ok, settle, shoot_both_modes, shoot_main,
    wait_main, wait_route, wait_setup, wait_until,
};
use crate::AppState;
use crate::l10n::ActiveL10n as _;
use crate::smoke::current_route;
use crate::stores::Stores;
use crate::stores::navigation::{AreaItem, Selection};
use crate::stores::session::Route;
use crate::views::hermes_room::HermesRoomPane;
use crate::views::hermes_room_sheets::{CreateRoomSheet, RoomInfoSheet};
use crate::views::hermes_rooms::{self, RoomCommand};
use crate::views::sheet;

const ROOM: &str = "Greenhouse crew";
const RENAMED: &str = "Seed swap";

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

fn stores(cx: &mut App) -> Stores {
    cx.global::<AppState>().stores.clone()
}

fn selection(cx: &mut App) -> Selection {
    stores(cx).navigation.read(cx).selection().clone()
}

/// The open room's view, as its pane draws it.
fn view(cx: &mut App) -> Option<HermesRoomView> {
    let stores = stores(cx);
    let rooms = stores.hermes_rooms.read(cx);
    rooms.room.as_ref().and_then(|r| r.view.clone())
}

fn items(cx: &mut App) -> Vec<HermesRoomItemDto> {
    view(cx).map(|v| v.items).unwrap_or_default()
}

fn bot_messages(cx: &mut App) -> Vec<HermesRoomItemDto> {
    items(cx)
        .into_iter()
        .filter(|i| i.kind == HermesRoomItemKind::Message && !i.own)
        .collect()
}

fn toasts(cx: &mut App) -> Vec<String> {
    let stores = stores(cx);
    let toasts = stores.toasts.read(cx);
    toasts.toasts.iter().map(|t| t.message.clone()).collect()
}

/// The room pane shown, if a room is.
fn room_pane(cx: &mut App) -> Option<gpui_kit::Entity<HermesRoomPane>> {
    let (_, main) = (
        cx.global::<AppState>().main_window?,
        cx.global::<AppState>().main_view.clone()?,
    );
    main.read(cx).area_pane.read(cx).room.clone()
}

/// Types `text` into the room's composer.
fn type_in_room(text: &str, cx: &mut AsyncApp) {
    let text = text.to_string();
    in_main(cx, move |mw, window, cx| {
        let pane = mw.area_pane.read(cx).room.clone();
        if let Some(pane) = pane {
            pane.update(cx, |p, cx| p.type_text(&text, window, cx));
        }
    });
}

fn send_in_room(cx: &mut AsyncApp) {
    in_main(cx, |mw, window, cx| {
        let pane = mw.area_pane.read(cx).room.clone();
        if let Some(pane) = pane {
            pane.update(cx, |p, cx| p.send(window, cx));
        }
    });
}

/// Runs `f` on the open sheet's body `V`, with its window.
fn in_sheet<V: 'static, R>(
    cx: &mut AsyncApp,
    f: impl FnOnce(&mut V, &mut gpui_kit::Window, &mut gpui_kit::Context<V>) -> R,
) -> Option<R> {
    let (view, handle) = cx.update(|cx| (sheet::current::<V>(cx), sheet::current_window(cx)));
    let (view, handle) = (view?, handle?);
    cx.update(|cx| {
        handle
            .update(cx, |_, window, cx| {
                view.update(cx, |v, cx| f(v, window, cx))
            })
            .ok()
    })
}

async fn shoot_sheet(dir: &Path, name: &str, cx: &mut AsyncApp) {
    if let Some(handle) = cx.update(|cx| sheet::current_window(cx)) {
        shoot_both_modes(handle, dir, name, cx).await;
    }
}

async fn sheet_closed(cx: &mut AsyncApp) -> bool {
    wait_until(cx, Duration::from_secs(20), |cx| !sheet::is_open(cx)).await
}

async fn wait_room_items(
    cx: &mut AsyncApp,
    secs: u64,
    done: impl Fn(&[HermesRoomItemDto]) -> bool,
) -> bool {
    wait_until(cx, Duration::from_secs(secs), move |cx| done(&items(cx))).await
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

    // ── The Bots and Rooms groups ────────────────────────────────────
    let listed = wait_until(cx, Duration::from_secs(60), |cx| {
        let stores = stores(cx);
        let rooms = stores.hermes_rooms.read(cx);
        rooms.bot_list().len() == 3 && rooms.can_create()
    })
    .await;
    pass &= ok(
        "the gateway's three bots are listed, and a room can be made",
        listed,
    );
    let pictured = wait_until(cx, Duration::from_secs(20), |cx| {
        stores(cx)
            .hermes_rooms
            .read(cx)
            .known_avatar("reed")
            .is_some()
    })
    .await;
    pass &= ok("a bot with a picture shows it", pictured);
    settle(cx, 600).await;
    shoot_main(dir, "hermes-rooms-sidebar", cx).await;
    let controls = ax(main, "hermes-rooms-sidebar", dir, cx).await;
    pass &= ok(
        "the bots are rows of the sidebar's outline under Bots, with Rooms and New Room",
        has(&controls, "TreeItem", "Fern")
            && has(&controls, "TreeItem", "Reed")
            && has(&controls, "Heading", "Bots")
            && has(&controls, "Heading", "Rooms")
            && has(&controls, "Button", "New Room"),
    );

    // ── A bot's Bot Chat ─────────────────────────────────────────────
    cx.update(|cx| hermes_rooms::open_bot(&stores(cx), "fern", cx));
    let opened = wait_until(cx, Duration::from_secs(40), |cx| {
        chat_store(cx).is_some_and(|s| {
            let s = s.read(cx);
            s.hermes()
                .and_then(|h| h.bot.as_ref())
                .is_some_and(|b| b.name == "fern")
        })
    })
    .await;
    pass &= ok("a bot's row opens its Bot Chat in the chat pane", opened);
    let bot_session = cx.update(|cx| match selection(cx) {
        Selection::Area(AreaItem::HermesSession(id)) => Some(id),
        _ => None,
    });
    pass &= ok("the Bot Chat is a Hermes session", bot_session.is_some());
    send("What does the greenhouse log say?", cx).await;
    let answered = wait_until(cx, Duration::from_secs(90), |cx| {
        chat_store(cx).is_some_and(|s| {
            let s = s.read(cx);
            !s.is_streaming()
                && s.messages()
                    .last()
                    .is_some_and(|m| m.role == "assistant" && m.content.contains("Fern here"))
        })
    })
    .await;
    pass &= ok("the bot answers in its Bot Chat, as itself", answered);
    settle(cx, 800).await;
    shoot_main(dir, "hermes-bot-chat", cx).await;
    let controls = ax(main, "hermes-bot-chat", dir, cx).await;
    pass &= ok(
        "the toolbar names the bot, and its row is selected",
        has(&controls, "Heading", "Fern")
            && controls
                .iter()
                .any(|c| c.starts_with("TreeItem:Fern") && c.contains("selected")),
    );
    // (The dump lists controls and headings, not a reply's article: its
    // header names the bot the chat says it is.)
    pass &= ok(
        "the chat is the bot's, so its replies carry the bot's name and face",
        cx.update(|cx| {
            chat_store(cx).is_some_and(|s| {
                s.read(cx)
                    .hermes()
                    .and_then(|h| h.bot.as_ref())
                    .is_some_and(|b| b.title == "Fern" && b.shape == "squircle")
            })
        }),
    );

    // ── New Room with two bots ───────────────────────────────────────
    in_main(cx, |mw, window, cx| {
        crate::views::hermes_room_sheets::open_create(mw.stores.clone(), window, cx)
    });
    let shown = wait_until(cx, Duration::from_secs(10), |cx| {
        sheet::current::<CreateRoomSheet>(cx).is_some()
    })
    .await;
    pass &= ok("New Room opens its sheet", shown);
    in_sheet::<CreateRoomSheet, _>(cx, |s, window, cx| {
        s.set_name(ROOM, window, cx);
        s.toggle("fern", cx);
        s.toggle("moss", cx);
    });
    settle(cx, 500).await;
    shoot_sheet(dir, "hermes-room-new", cx).await;
    if let Some(handle) = cx.update(|cx| sheet::current_window(cx)) {
        ax(handle, "hermes-room-new", dir, cx).await;
    }
    in_sheet::<CreateRoomSheet, _>(cx, |s, window, cx| s.create(window, cx));
    pass &= ok("Create closes the sheet", sheet_closed(cx).await);
    let room_id = wait_until(cx, Duration::from_secs(30), |cx| {
        matches!(selection(cx), Selection::Area(AreaItem::HermesRoom(_)))
            && view(cx).is_some_and(|v| v.loaded && v.room.as_ref().is_some_and(|r| r.name == ROOM))
    })
    .await;
    pass &= ok("the new room opens in the main pane, read", room_id);
    let Some(room_id) = cx.update(|cx| match selection(cx) {
        Selection::Area(AreaItem::HermesRoom(id)) => Some(id),
        _ => None,
    }) else {
        return ok("a room is shown", false);
    };
    let listed = wait_until(cx, Duration::from_secs(20), |cx| {
        stores(cx)
            .hermes_rooms
            .read(cx)
            .listed_room(&room_id)
            .is_some()
    })
    .await;
    pass &= ok("the sidebar lists it under Rooms", listed);
    settle(cx, 600).await;
    shoot_main(dir, "hermes-room-empty", cx).await;

    // ── @mentions through the composer, both bots answering ──────────
    type_in_room("@fe", cx);
    let offered = cx.update(|cx| room_pane(cx).is_some());
    pass &= ok("the room pane is shown", offered);
    settle(cx, 300).await;
    shoot_main(dir, "hermes-room-mention", cx).await;
    let completed = in_main(cx, |mw, window, cx| {
        let pane = mw.area_pane.read(cx).room.clone()?;
        pane.update(cx, |p, cx| {
            p.insert("fern", window, cx);
            Some(p.text(cx))
        })
    })
    .flatten()
    .unwrap_or_default();
    pass &= ok("the @ list completes a bot's handle", completed == "@fern ");
    type_in_room("@fern @moss how many seed trays do we need?", cx);
    send_in_room(cx);
    let replied = wait_room_items(cx, 120, |items| {
        let mut authors: Vec<&str> = items
            .iter()
            .filter(|i| i.kind == HermesRoomItemKind::Message && !i.own)
            .map(|i| i.author.as_str())
            .collect();
        authors.sort();
        authors.dedup();
        items.iter().any(|i| i.own) && authors == ["Fern", "Moss"]
    })
    .await;
    pass &= ok("both bots answer the message, each by name", replied);
    let faced = cx.update(|cx| {
        bot_messages(cx).iter().all(|m| {
            m.member_id
                .as_deref()
                .is_some_and(|id| id == "fern" || id == "moss")
        })
    });
    pass &= ok("each reply is its bot's (its face)", faced);
    let cleared = cx.update(|cx| room_pane(cx).is_some_and(|p| p.read(cx).text(cx).is_empty()));
    pass &= ok("the composer is clear once Hermes has the message", cleared);
    settle(cx, 800).await;
    shoot_main(dir, "hermes-room-replies", cx).await;
    let controls = ax(main, "hermes-room-replies", dir, cx).await;
    pass &= ok(
        "the room's title (with its status) and its row are read out",
        has(&controls, "Button", &format!("{ROOM}, 2 bots"))
            && has(&controls, "TreeItem", ROOM)
            && has(&controls, "Button", "Room Info"),
    );

    // ── A debate pauses at its limit; Continue ───────────────────────
    let before = cx.update(|cx| bot_messages(cx).len());
    type_in_room("@fern let us debate the seed trays", cx);
    send_in_room(cx);
    let paused = wait_room_items(cx, 180, |items| {
        items
            .iter()
            .any(|i| i.kind == HermesRoomItemKind::Pause && i.actionable)
    })
    .await;
    pass &= ok(
        "the discussion pauses at its round limit, with Continue",
        paused,
    );
    let said = cx.update(|cx| bot_messages(cx).len() - before);
    pass &= ok("the bots said several things before it paused", said >= 3);
    settle(cx, 600).await;
    shoot_main(dir, "hermes-room-paused", cx).await;
    let pause = cx.update(|cx| {
        items(cx)
            .into_iter()
            .find(|i| i.kind == HermesRoomItemKind::Pause && i.actionable)
    });
    if let Some(pause) = pause {
        let discussion = pause.discussion_event_id.clone().unwrap_or_default();
        let id = room_id.clone();
        cx.update(|cx| hermes_rooms::continue_discussion(&stores(cx), &id, &discussion, cx));
        let continued = wait_room_items(cx, 120, |items| {
            items
                .iter()
                .any(|i| i.route == Some(HermesRoomRouteKind::Continued))
        })
        .await;
        pass &= ok("Continue goes on with the discussion", continued);
        let more = wait_until(cx, Duration::from_secs(120), |cx| {
            bot_messages(cx).len() > before + said
        })
        .await;
        pass &= ok("the bots speak again after Continue", more);
        // It runs to its next pause before the room is used again.
        wait_until(cx, Duration::from_secs(120), |cx| {
            view(cx).is_some_and(|v| !v.working)
        })
        .await;
    }

    // ── An approval, answered on its card ────────────────────────────
    type_in_room("@moss tidy the old labels", cx);
    send_in_room(cx);
    let asked = wait_until(cx, Duration::from_secs(90), |cx| {
        view(cx).is_some_and(|v| {
            v.actions
                .iter()
                .any(|a| a.kind == "approval" && a.choices.iter().any(|c| c == "once"))
        })
    })
    .await;
    pass &= ok("a bot's command waits on an approval card", asked);
    let needs = cx.update(|cx| {
        stores(cx)
            .hermes_rooms
            .read(cx)
            .room(&room_id)
            .is_some_and(|r| r.needs_you)
    });
    pass &= ok("the room says it needs an answer", needs);
    settle(cx, 600).await;
    shoot_main(dir, "hermes-room-approval", cx).await;
    let controls = ax(main, "hermes-room-approval", dir, cx).await;
    pass &= ok(
        "the card offers Allow Once and Deny",
        has(&controls, "Button", "Allow Once") && has(&controls, "Button", "Deny"),
    );
    let action = cx.update(|cx| view(cx).and_then(|v| v.actions.first().cloned()));
    if let Some(action) = action {
        let answer = conduit_protocol::HermesRoomAnswer {
            room_id: room_id.clone(),
            task_id: action.task_id.clone(),
            execution_generation: action.execution_generation,
            choice: Some("once".into()),
            connection: cx.update(|cx| view(cx).and_then(|v| v.connection.clone())),
        };
        cx.update(|cx| hermes_rooms::answer(&stores(cx), answer, |_| {}, cx));
    }
    let done = wait_until(cx, Duration::from_secs(90), |cx| {
        view(cx).is_some_and(|v| v.actions.is_empty())
            && bot_messages(cx)
                .iter()
                .any(|m| m.text.contains("old labels are cleared"))
    })
    .await;
    pass &= ok(
        "Allow Once lets the bot go on, and it says what it did",
        done,
    );

    // ── Room Info: purpose, notes, a lead bot ────────────────────────
    let id = room_id.clone();
    in_main(cx, move |mw, window, cx| {
        hermes_rooms::run(&mw.stores, &id, RoomCommand::Info, window, cx)
    });
    let info = wait_until(cx, Duration::from_secs(10), |cx| {
        sheet::current::<RoomInfoSheet>(cx).is_some()
    })
    .await;
    pass &= ok("Room Info opens its sheet", info);
    in_sheet::<RoomInfoSheet, _>(cx, |s, window, cx| {
        s.type_into("purpose", "Plan the spring beds", window, cx);
        s.type_into("notes", "Tomatoes go by the south wall.", window, cx);
        s.set_routing(HermesRoomRouting::Lead, cx);
        s.set_lead("moss", cx);
    });
    settle(cx, 500).await;
    shoot_sheet(dir, "hermes-room-info", cx).await;
    if let Some(handle) = cx.update(|cx| sheet::current_window(cx)) {
        let controls = ax(handle, "hermes-room-info", dir, cx).await;
        pass &= ok(
            "Room Info lists the bots, Moss as lead",
            controls
                .iter()
                .any(|c| c.starts_with("RadioButton:") && c.contains("Moss") && c.contains("Lead")),
        );
    }
    in_sheet::<RoomInfoSheet, _>(cx, |s, window, cx| s.save(window, cx));
    pass &= ok("Save closes Room Info", sheet_closed(cx).await);
    let saved = wait_until(cx, Duration::from_secs(20), |cx| {
        view(cx).and_then(|v| v.context).is_some_and(|c| {
            c.purpose == "Plan the spring beds"
                && c.notes == "Tomatoes go by the south wall."
                && c.routing == Some(HermesRoomRouting::Lead)
                && c.lead_member_id.as_deref() == Some("moss")
        })
    })
    .await;
    pass &= ok("the room keeps its purpose, notes and lead", saved);

    // ── Rename ───────────────────────────────────────────────────────
    let id = room_id.clone();
    in_main(cx, move |mw, window, cx| {
        hermes_rooms::run(&mw.stores, &id, RoomCommand::Rename, window, cx)
    });
    let renaming = wait_until(cx, Duration::from_secs(10), |cx| {
        sheet::current::<RoomInfoSheet>(cx).is_some()
    })
    .await;
    pass &= ok("Rename… opens Room Info at its name", renaming);
    in_sheet::<RoomInfoSheet, _>(cx, |s, window, cx| {
        s.type_into("name", RENAMED, window, cx);
        s.save(window, cx);
    });
    pass &= ok("Save closes it", sheet_closed(cx).await);
    let renamed = wait_until(cx, Duration::from_secs(30), |cx| {
        let stores = stores(cx);
        let rooms = stores.hermes_rooms.read(cx);
        rooms
            .listed_room(&room_id)
            .is_some_and(|r| r.name == RENAMED)
            && rooms
                .view(&room_id)
                .and_then(|v| v.room.as_ref())
                .is_some_and(|r| r.name == RENAMED)
    })
    .await;
    pass &= ok("the room and its row take the new name", renamed);

    // ── Stop All Work while a bot works ──────────────────────────────
    type_in_room("@fern slow count the trays", cx);
    send_in_room(cx);
    let working = wait_until(cx, Duration::from_secs(60), |cx| {
        view(cx).is_some_and(|v| v.working && crate::views::hermes_room::can_stop(&v))
    })
    .await;
    pass &= ok("the room shows a bot at work, with Stop", working);
    settle(cx, 2500).await;
    shoot_main(dir, "hermes-room-working", cx).await;
    let status = cx.update(|cx| {
        let l = cx.l10n().clone();
        let stores = stores(cx);
        let rooms = stores.hermes_rooms.read(cx);
        rooms.room.as_ref().and_then(|o| {
            o.view
                .as_ref()
                .and_then(|v| crate::views::hermes_room::status_line(v, o.received, &l))
        })
    });
    pass &= ok(
        "its status line names the bot and how long it has worked",
        status
            .as_deref()
            .is_some_and(|s| s.starts_with("Fern") && s.contains('s')),
    );
    let id = room_id.clone();
    cx.update(|cx| hermes_rooms::stop(&stores(cx), &id, cx));
    let stopped = wait_until(cx, Duration::from_secs(60), |cx| {
        view(cx).is_some_and(|v| !v.working)
            && items(cx).iter().any(|i| {
                i.kind == HermesRoomItemKind::Notice
                    && i.notice == Some(conduit_protocol::HermesRoomNoticeKind::Stopped)
            })
    })
    .await;
    pass &= ok("Stop All Work stops it, and the room says so", stopped);
    pass &= ok(
        "a toast says how much stopped",
        cx.update(|cx| {
            toasts(cx)
                .iter()
                .any(|t| t.contains("Stopped") || t.contains("Nothing"))
        }),
    );

    // ── Disband Room… ────────────────────────────────────────────────
    let id = room_id.clone();
    in_main(cx, move |mw, window, cx| {
        hermes_rooms::run(&mw.stores, &id, RoomCommand::Disband, window, cx)
    });
    let disbanded = wait_until(cx, Duration::from_secs(30), |cx| {
        !matches!(selection(cx), Selection::Area(AreaItem::HermesRoom(_)))
            && stores(cx)
                .hermes_rooms
                .read(cx)
                .listed_room(&room_id)
                .is_none()
    })
    .await;
    pass &= ok(
        "Disband Room… ends it: it leaves the pane and the list",
        disbanded,
    );
    settle(cx, 600).await;
    shoot_main(dir, "hermes-rooms-after", cx).await;
    pass
}
