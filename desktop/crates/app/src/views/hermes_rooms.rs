//! Hermes Bot Mode and Group Chats' commands, wherever they are asked: a
//! bot's row (open its Bot Chat), a room's row and its context menu, the
//! Rooms heading's New Room, the room's toolbar, its Info sheet and its
//! timeline (Continue, a decision card).
//!
//! As the phone's (`hermes_bot_tile.dart`, `hermes_rooms_section.dart`,
//! `hermes_room_page.dart`): a bot opens its permanent Bot Chat; a room
//! opens in the main pane; Room Info… shows its purpose, notes, who
//! answers and its bots; Stop All Work stops what its bots are doing;
//! Disband Room… asks first, then ends it for good. The daemon does the
//! work (`hermes.bots.*`, `hermes.rooms.*`); here a command is sent and a
//! failure said in the phone's words ("Hermes refused: …" with Hermes's
//! own reason when it gave one).

use conduit_daemon::RpcError;
use conduit_protocol::{
    HermesBotRef, HermesRoomAnswer, HermesRoomContinue, HermesRoomRef, NoticeLevel, methods,
};
use gpui_kit::component::native_menu::NativeMenu;
use gpui_kit::{Action, App, AsyncApp, Window};

use crate::l10n::{ActiveL10n as _, L10n};
use crate::shell::sheet::{SheetSpec, present_sheet};
use crate::stores::Stores;
use crate::stores::navigation::{AreaItem, Selection};

/// One command on a room.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum RoomCommand {
    /// Room Info… (its sheet).
    Info,
    /// Rename… (the Info sheet, its name field first).
    Rename,
    StopWork,
    Disband,
}

impl RoomCommand {
    pub fn label(self, l: &L10n) -> String {
        match self {
            Self::Info => l.desktop_hermes_room_info_menu(),
            Self::Rename => l.desktop_rename_ellipsis(),
            Self::StopWork => l.hermes_room_stop_work(),
            Self::Disband => l.desktop_hermes_disband_room_menu(),
        }
    }
}

/// A room's menu command: `command` on room `room_id`.
#[derive(Clone, Debug, PartialEq, Action)]
#[action(namespace = conduit_sidebar, no_json)]
pub struct RoomMenu {
    pub room_id: String,
    pub command: RoomCommand,
}

/// New Room… (the Rooms heading's "+", a room's menu).
#[derive(Clone, Debug, PartialEq, Default, Action)]
#[action(namespace = conduit_sidebar, no_json)]
pub struct NewRoom;

/// Opens a bot's Bot Chat (its row's menu).
#[derive(Clone, Debug, PartialEq, Action)]
#[action(namespace = conduit_sidebar, no_json)]
pub struct OpenBotChat {
    pub name: String,
}

/// What room `room_id` offers now: Stop only while its bots work, nothing
/// but Info on a room the gateway no longer runs.
pub fn commands(stores: &Stores, room_id: &str, cx: &App) -> Vec<RoomCommand> {
    let rooms = stores.hermes_rooms.read(cx);
    let view = rooms.view(room_id);
    let working = view.map_or_else(
        || rooms.room(room_id).is_some_and(|r| r.working),
        |v| v.working,
    );
    let gone = view.is_some_and(|v| v.gone);
    let mut out = vec![RoomCommand::Info];
    if gone {
        return out;
    }
    out.push(RoomCommand::Rename);
    if working {
        out.push(RoomCommand::StopWork);
    }
    out.push(RoomCommand::Disband);
    out
}

/// Room `room_id`'s context menu: Open is the row itself; New Room… heads
/// it, Disband Room… stands apart at the end.
pub fn native_menu(stores: &Stores, room_id: &str, cx: &App) -> NativeMenu {
    let l = cx.l10n();
    let mut menu = NativeMenu::new();
    for command in commands(stores, room_id, cx) {
        if command == RoomCommand::Disband {
            menu = menu.separator();
        }
        menu = menu.menu(
            command.label(l),
            Box::new(RoomMenu {
                room_id: room_id.to_string(),
                command,
            }),
        );
    }
    if stores.hermes_rooms.read(cx).can_create() {
        menu = menu
            .separator()
            .menu(l.desktop_hermes_new_room_menu(), Box::new(NewRoom));
    }
    menu
}

/// A bot's context menu.
pub fn bot_menu(name: &str, l: &L10n) -> NativeMenu {
    NativeMenu::new().menu(
        l.desktop_hermes_open_bot_chat(),
        Box::new(OpenBotChat {
            name: name.to_string(),
        }),
    )
}

fn toast(stores: &Stores, level: NoticeLevel, text: String, cx: &mut App) {
    stores.toasts.update(cx, |t, cx| t.show(level, text, cx));
}

/// What a failed room action says: Hermes's own reason when it gave one.
pub fn failure_text(error: &RpcError, l: &L10n) -> String {
    match error.args.get("detail") {
        Some(detail) if !detail.trim().is_empty() => l.hermes_room_refused(detail),
        _ => l.hermes_room_action_failed(),
    }
}

/// Opens bot `name`'s Bot Chat (made when it has none): its session opens
/// in the chat pane, and its row is selected.
pub fn open_bot(stores: &Stores, name: &str, cx: &mut App) {
    let rooms = stores.hermes_rooms.clone();
    if rooms.read(cx).opening_bot.is_some() {
        return;
    }
    // The chat opens once the daemon has bound its session to the bot's
    // profile: before that, a message would go to the connection's own.
    let Some(rpc) = rooms.read(cx).rpc() else {
        return;
    };
    rooms.update(cx, |r, cx| r.set_opening_bot(Some(name.to_string()), cx));
    let call = rpc.call::<methods::HermesBotsOpen>(&HermesBotRef {
        name: name.to_string(),
    });
    let stores = stores.clone();
    let name = name.to_string();
    cx.spawn(async move |cx: &mut AsyncApp| {
        let result = call.await;
        cx.update(|cx| {
            stores
                .hermes_rooms
                .update(cx, |r, cx| r.set_opening_bot(None, cx));
            match result {
                Ok(session) => {
                    stores
                        .hermes_rooms
                        .update(cx, |r, cx| r.note_bot_session(&session.id, &name, cx));
                    let chat = session.chat_id.clone();
                    let shown = stores.navigation.read(cx).selection().chat_id();
                    if shown.as_deref() != Some(chat.as_str()) {
                        stores.navigation.update(cx, |n, cx| n.open(chat, cx));
                    }
                }
                Err(e) => {
                    log::warn!("hermes.bots.open: {e}");
                    let text = cx.l10n().hermes_session_load_failed();
                    toast(&stores, NoticeLevel::Warning, text, cx);
                }
            }
        });
    })
    .detach();
}

/// Carries out `command` on room `room_id`.
pub fn run(
    stores: &Stores,
    room_id: &str,
    command: RoomCommand,
    window: &mut Window,
    cx: &mut App,
) {
    match command {
        RoomCommand::Info => {
            crate::views::hermes_room_sheets::open_info(stores.clone(), room_id, false, window, cx)
        }
        RoomCommand::Rename => {
            crate::views::hermes_room_sheets::open_info(stores.clone(), room_id, true, window, cx)
        }
        RoomCommand::StopWork => stop(stores, room_id, cx),
        RoomCommand::Disband => confirm_disband(stores, room_id, window, cx),
    }
}

/// Stops what room `room_id`'s bots are doing, and says how much stopped.
pub fn stop(stores: &Stores, room_id: &str, cx: &mut App) {
    let Some(rpc) = stores.hermes_rooms.read(cx).rpc() else {
        return;
    };
    let call = rpc.call::<methods::HermesRoomsStop>(&HermesRoomRef {
        room_id: room_id.to_string(),
    });
    let stores = stores.clone();
    cx.spawn(async move |cx: &mut AsyncApp| {
        let result = call.await;
        cx.update(|cx| {
            let l = cx.l10n().clone();
            match result {
                Ok(stopped) => toast(
                    &stores,
                    NoticeLevel::Info,
                    l.hermes_room_stopped_count(stopped.stopped),
                    cx,
                ),
                Err(e) => {
                    log::warn!("hermes.rooms.stop: {e}");
                    toast(&stores, NoticeLevel::Warning, failure_text(&e, &l), cx);
                }
            }
        });
    })
    .detach();
}

/// Disband Room…: asks, then ends room `room_id` for good; the pane goes
/// back to a new chat if it showed the room.
pub fn confirm_disband(stores: &Stores, room_id: &str, window: &mut Window, cx: &mut App) {
    let l = cx.l10n().clone();
    let name = stores
        .hermes_rooms
        .read(cx)
        .room(room_id)
        .map(|r| r.name.clone())
        .unwrap_or_default();
    let spec = SheetSpec::new(
        l.hermes_room_disband_title(&name),
        l.hermes_room_disband_message(),
        l.hermes_room_disband(),
        l.cancel(),
    )
    .destructive();
    let ask = present_sheet(window, spec, cx);
    let stores = stores.clone();
    let room_id = room_id.to_string();
    cx.spawn(async move |cx: &mut AsyncApp| {
        if !ask.await {
            return;
        }
        let call = cx.update(|cx| {
            stores.hermes_rooms.read(cx).rpc().map(|rpc| {
                rpc.call::<methods::HermesRoomsDisband>(&HermesRoomRef {
                    room_id: room_id.clone(),
                })
            })
        });
        let Some(call) = call else {
            return;
        };
        let result = call.await;
        cx.update(|cx| match result {
            Ok(_) => {
                let shown = Selection::Area(AreaItem::HermesRoom(room_id.clone()));
                if *stores.navigation.read(cx).selection() == shown {
                    stores.navigation.update(cx, |n, cx| n.new_chat(false, cx));
                }
                stores.hermes_rooms.update(cx, |r, cx| r.refresh(cx));
            }
            Err(e) => {
                log::warn!("hermes.rooms.disband: {e}");
                let text = failure_text(&e, &cx.l10n().clone());
                toast(&stores, NoticeLevel::Warning, text, cx);
            }
        });
    })
    .detach();
}

/// Continue on a paused discussion.
pub fn continue_discussion(stores: &Stores, room_id: &str, discussion: &str, cx: &mut App) {
    let Some(rpc) = stores.hermes_rooms.read(cx).rpc() else {
        return;
    };
    let call = rpc.call::<methods::HermesRoomsContinue>(&HermesRoomContinue {
        room_id: room_id.to_string(),
        discussion_event_id: discussion.to_string(),
    });
    let stores = stores.clone();
    cx.spawn(async move |cx: &mut AsyncApp| {
        if let Err(e) = call.await {
            log::warn!("hermes.rooms.continue: {e}");
            cx.update(|cx| {
                let text = failure_text(&e, &cx.l10n().clone());
                toast(&stores, NoticeLevel::Warning, text, cx);
            });
        }
    })
    .detach();
}

/// Answers a room's approval (`once`, `deny`) or retries its work (no
/// choice). `done` runs once the daemon answered (the card's spinner).
pub fn answer(
    stores: &Stores,
    answer: HermesRoomAnswer,
    done: impl FnOnce(&mut App) + 'static,
    cx: &mut App,
) {
    let Some(rpc) = stores.hermes_rooms.read(cx).rpc() else {
        return;
    };
    let call = rpc.call::<methods::HermesRoomsAnswer>(&answer);
    let stores = stores.clone();
    cx.spawn(async move |cx: &mut AsyncApp| {
        let result = call.await;
        cx.update(|cx| {
            done(cx);
            if let Err(e) = result {
                log::warn!("hermes.rooms.answer: {e}");
                let text = failure_text(&e, &cx.l10n().clone());
                toast(&stores, NoticeLevel::Warning, text, cx);
            }
        });
    })
    .detach();
}
