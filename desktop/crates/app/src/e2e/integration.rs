//! `--e2e integration`: the sidebar and the chat view together in
//! one window, on the local Open WebUI and its fake model, as `chat`.
//!
//! Sending in a new chat lists and selects it in the sidebar; ⌘N starts a
//! new chat with the composer focused; opening a chat from the sidebar shows
//! its transcript; the palette's Choose model opens the model picker;
//! renaming the open chat retitles the toolbar; ⌃⌘S hides and shows the
//! sidebar; an approval card docks above the composer (open and new chat);
//! deleting the open chat returns to a new chat.

use std::path::Path;
use std::time::Duration;

use gpui_kit::{App, AsyncApp, Focusable as _};

use super::chat::{chat_store, dispatch, in_pane, pane, send, sign_in, wait_answer, wait_models};
use super::*;
use crate::stores::navigation::Selection;
use crate::stores::palette::{PaletteCommand, PaletteEntry};

const RENAMED: &str = "Integration chat, renamed";

fn selection(cx: &mut App) -> Selection {
    cx.global::<AppState>()
        .stores
        .navigation
        .read(cx)
        .selection()
        .clone()
}

fn open_chat_id(cx: &mut App) -> Option<String> {
    chat_store(cx).map(|s| s.read(cx).chat_id().to_string())
}

/// The open chat's title, which the toolbar shows.
fn open_title(cx: &mut App) -> Option<String> {
    chat_store(cx).and_then(|s| s.read(cx).title().map(str::to_string))
}

fn sidebar_visible(cx: &mut App) -> bool {
    cx.global::<AppState>()
        .layout
        .read(cx)
        .state
        .sidebar_visible
}

fn composer_focused(cx: &mut AsyncApp) -> bool {
    in_pane(cx, |p, window, cx| {
        let input = p.composer.read(cx).input.clone();
        input.read(cx).focus_handle(cx).is_focused(window)
    })
    .unwrap_or(false)
}

fn has_card(cx: &mut App) -> bool {
    main_window(cx).is_some_and(|(_, v)| v.read(cx).approvals.read(cx).has_request(cx))
}

/// Docks a synthetic tool approval and checks it sits in the chat pane (the
/// main window's bottom overlay is only for screens without a composer),
/// then answers it with ⌥⌘⌫.
async fn docked_card(id: &str, dir: &Path, name: &str, cx: &mut AsyncApp) -> bool {
    let tool = request(
        id,
        conduit_protocol::UiRequestKind::ToolApproval,
        &[
            ("title", "get_current_timestamp"),
            ("message", "The model wants to read the clock."),
        ],
    );
    cx.update(|cx| {
        let u = cx.global::<AppState>().stores.ui_requests.clone();
        u.update(cx, |u, cx| u.on_request(tool, cx));
    });
    settle(cx, 600).await;
    let docked = cx.update(|cx| {
        has_card(cx) && main_window(cx).is_some_and(|(_, v)| v.read(cx).shows_main(cx))
    });
    shoot_main(dir, name, cx).await;
    dispatch(&crate::actions::DenyRequest, cx);
    let gone = wait_until(cx, Duration::from_secs(10), |cx| !has_card(cx)).await;
    docked && gone
}

pub async fn run(inputs: &E2eInputs, dir: &Path, cx: &mut AsyncApp) -> bool {
    let Some((url, email, password)) = inputs.owui() else {
        return ok(NO_SERVER, false);
    };
    let mut pass = sign_in(&url, &email, &password, cx).await;
    let Some((main, _)) = cx.update(main_window) else {
        return ok("main window", false);
    };
    pass &= ok("models.list answered", wait_models(cx).await);
    let synced = wait_until(cx, Duration::from_secs(60), |cx| {
        let s = cx.global::<AppState>().stores.chat_list.read(cx);
        s.list.is_some()
            && s.sync
                .as_ref()
                .is_some_and(|s| s.ever_completed && !s.running)
    })
    .await;
    pass &= ok("the chat list loaded", synced);
    settle(cx, 600).await;

    // 1. Sending in a new chat lists it in the sidebar and selects it.
    send("Hello from the integration pass", cx).await;
    pass &= ok(
        "the new chat's answer settles",
        wait_answer(cx, Duration::from_secs(60)).await,
    );
    let Some(id) = cx.update(open_chat_id) else {
        return ok("the new chat opened", false);
    };
    let listed = {
        let id = id.clone();
        wait_until(cx, Duration::from_secs(30), move |cx| {
            chat_by_id(&id, cx).is_some()
        })
        .await
    };
    pass &= ok("sending in a new chat lists it in the sidebar", listed);
    pass &= ok(
        "the sidebar selects the new chat",
        cx.update(selection) == Selection::Chat(id.clone()),
    );
    settle(cx, 600).await;
    shoot_main(dir, "integration-sent", cx).await;

    // 2. ⌘N from the sidebar's search field: a new chat, ready to type.
    in_main(cx, |mw, window, cx| {
        let search = mw.sidebar.read(cx).search.clone();
        search.update(cx, |s, cx| s.focus(window, cx));
    });
    settle(cx, 200).await;
    dispatch(&crate::actions::NewChat, cx);
    settle(cx, 500).await;
    let fresh = cx.update(|cx| {
        selection(cx) == Selection::New { temporary: false }
            && pane(cx).is_some_and(|p| p.read(cx).chat.is_none())
    });
    pass &= ok("⌘N starts a new chat", fresh);
    pass &= ok("⌘N focuses the composer", composer_focused(cx));
    shoot_main(dir, "integration-new-chat", cx).await;

    // 3. Opening the chat from the sidebar shows its transcript.
    {
        let id = id.clone();
        in_main(cx, move |mw, _, cx| {
            mw.sidebar.update(cx, |s, cx| s.open(&id, cx))
        });
    }
    let shown = {
        let id = id.clone();
        wait_until(cx, Duration::from_secs(15), move |cx| {
            chat_store(cx).is_some_and(|s| {
                let s = s.read(cx);
                s.chat_id() == id && s.rows().len() >= 2
            })
        })
        .await
    };
    pass &= ok(
        "opening a chat from the sidebar shows its transcript",
        shown,
    );
    settle(cx, 600).await;
    shoot_main(dir, "integration-opened", cx).await;
    let controls = ax(main, "integration-opened", dir, cx).await;
    pass &= ok(
        "the sidebar and the chat view are both in the AX tree",
        has(&controls, "Button", "New Chat")
            && has(&controls, "TextInput", "Search chats")
            && has(&controls, "MultilineTextInput", "Message"),
    );

    // ⌘N with nothing focused (the binding then reaches the app's
    // fallback handler), then back to the chat.
    in_main(cx, |_, window, cx| window.blur(cx));
    settle(cx, 200).await;
    dispatch(&crate::actions::NewChat, cx);
    let fresh = wait_until(cx, Duration::from_secs(3), |cx| {
        selection(cx) == Selection::New { temporary: false }
    })
    .await;
    pass &= ok("⌘N with nothing focused starts a new chat", fresh);
    {
        let id = id.clone();
        cx.update(|cx| {
            let nav = cx.global::<AppState>().stores.navigation.clone();
            nav.update(cx, |n, cx| n.open(id, cx));
        });
    }
    settle(cx, 600).await;

    // 4. The palette's Choose model opens the model picker (⇧⌘M's).
    dispatch(&crate::actions::OpenPalette, cx);
    settle(cx, 600).await;
    let index = in_main(cx, |mw, _, cx| {
        mw.palette.read(cx).entries().iter().position(
            |e| matches!(e, PaletteEntry::Command(c) if c.command == PaletteCommand::ChooseModel),
        )
    })
    .flatten();
    if let Some(i) = index {
        in_main(cx, move |mw, window, cx| {
            mw.palette.update(cx, |p, cx| p.choose(i, window, cx))
        });
    }
    let picked = wait_until(cx, Duration::from_secs(5), |cx| {
        pane(cx).is_some_and(|p| p.read(cx).composer.read(cx).picker_open())
    })
    .await;
    let palette_closed = !in_main(cx, |mw, _, cx| mw.palette.read(cx).is_open(cx)).unwrap_or(true);
    pass &= ok(
        "the palette's Choose model opens the model picker",
        index.is_some() && picked && palette_closed,
    );
    settle(cx, 400).await;
    shoot_main(dir, "integration-palette-model", cx).await;
    in_pane(cx, |p, window, cx| {
        p.composer.update(cx, |c, cx| c.close_picker(window, cx))
    });
    settle(cx, 300).await;

    // 5. Renaming the open chat in the sidebar retitles the toolbar.
    chat_command(&id, ChatCommand::Rename, cx).await;
    settle(cx, 300).await;
    let field = in_main(cx, |mw, _, cx| mw.sidebar.read(cx).rename_input()).flatten();
    if let Some(field) = field.clone() {
        in_main(cx, move |_, window, cx| {
            set_text(&field, RENAMED, window, cx)
        });
        settle(cx, 200).await;
        in_main(cx, |mw, window, cx| {
            mw.sidebar.update(cx, |s, cx| s.commit_rename(window, cx))
        });
    }
    let retitled = wait_until(cx, Duration::from_secs(20), |cx| {
        open_title(cx).as_deref() == Some(RENAMED)
    })
    .await;
    let now = cx.update(open_title);
    pass &= ok(
        &format!("renaming the open chat retitles the toolbar ({now:?})"),
        field.is_some() && retitled,
    );
    settle(cx, 400).await;
    shoot_main(dir, "integration-renamed", cx).await;

    // 6. ⌃⌘S hides the sidebar (the toolbar makes room for the traffic
    // lights; see the shots) and shows it again.
    dispatch(&crate::actions::ToggleSidebar, cx);
    settle(cx, 500).await;
    pass &= ok("⌃⌘S hides the sidebar", !cx.update(sidebar_visible));
    shoot_main(dir, "integration-sidebar-hidden", cx).await;
    dispatch(&crate::actions::NewChat, cx);
    settle(cx, 400).await;
    shoot_main(dir, "integration-sidebar-hidden-new", cx).await;
    {
        let id = id.clone();
        cx.update(|cx| {
            let nav = cx.global::<AppState>().stores.navigation.clone();
            nav.update(cx, |n, cx| n.open(id, cx));
        });
    }
    settle(cx, 400).await;
    dispatch(&crate::actions::ToggleSidebar, cx);
    settle(cx, 500).await;
    pass &= ok("⌃⌘S shows it again", cx.update(sidebar_visible));

    // 7. Approval cards dock above the composer, in an open chat and in a
    // new one.
    pass &= ok(
        "an approval card docks above the open chat's composer",
        docked_card("e2e-int-open", dir, "integration-approval", cx).await,
    );

    // 8. Deleting the open chat returns to a new chat.
    chat_command(&id, ChatCommand::Delete, cx).await;
    let back = wait_until(cx, Duration::from_secs(20), |cx| {
        selection(cx) == Selection::New { temporary: false }
            && pane(cx).is_some_and(|p| p.read(cx).chat.is_none())
    })
    .await;
    pass &= ok("deleting the open chat returns to a new chat", back);
    pass &= wait_chat(
        &id,
        "the deleted chat leaves the sidebar",
        Duration::from_secs(20),
        |c| c.is_none(),
        cx,
    )
    .await;
    settle(cx, 400).await;
    shoot_main(dir, "integration-deleted", cx).await;
    pass &= ok(
        "an approval card docks above a new chat's composer",
        docked_card("e2e-int-new", dir, "integration-approval-new", cx).await,
    );
    pass
}
