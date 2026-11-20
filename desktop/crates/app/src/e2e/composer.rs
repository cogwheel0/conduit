//! `--e2e composer`: the composer's mobile parity over the real
//! daemon, on the local Open WebUI, its fake model and its seed (two notes,
//! a knowledge base with a file, a skill, a channel, a second user, a file
//! and a page to read).
//!
//! * a draft kept per chat: typed in a new chat and in a stored one, it is
//!   back after switching away and back;
//! * a message queued while an answer streams, then one sent now (Stop &
//!   Send), the rest going out after it;
//! * a message sent while the queue's next batch waits for the chat to
//!   settle: Send shows, the message goes first, and the batch follows;
//! * each trigger: `$` skills (sent: the server gets the skill), `@` people
//!   and channels, `#` notes, knowledge bases and their files, `/` prompts;
//! * the server-file picker; a web page read as context;
//! * the code interpreter switched on, and in the request the model got;
//! * quick pills; the larger editor; Save as Note; Ask Conduit;
//! * Settings › Chat driving the composer as it changes: Send with Enter
//!   (on by default on the desktop), quick pills, Save as Note, and a new
//!   chat starting temporary.
//!
//! Each new popover, panel and state is shot in light and dark.

use std::path::Path;
use std::time::Duration;

use conduit_protocol::{
    AppSettingsDto, AppSettingsPatch, ChatRef, NoteQuery, NoteRef, QueuePhase, methods,
};
use gpui_kit::{App, AsyncApp};
use serde_json::Value;

use super::chat::{chat_store, in_pane, pane, send, sign_in, wait_answer, wait_models};
use super::*;
use crate::stores::app_settings::AppSettingsStore;
use crate::stores::composer::{ComposerPrefs, TriggerKind, UploadState};
use crate::views::chat::composer::{ComposerMenu, MenuRows, Panel};

fn composer_text(cx: &mut App) -> String {
    pane(cx)
        .map(|p| p.read(cx).composer.read(cx).text(cx))
        .unwrap_or_default()
}

async fn type_text(text: &str, cx: &mut AsyncApp) {
    let text = text.to_string();
    in_pane(cx, move |p, window, cx| {
        p.composer.update(cx, |c, cx| {
            c.focus_input(window, cx);
            c.set_text(&text, window, cx)
        })
    });
}

async fn menu_action(action: ComposerMenu, cx: &mut AsyncApp) {
    in_pane(cx, move |p, window, cx| {
        p.composer
            .update(cx, |c, cx| c.on_menu(&action, window, cx))
    });
}

fn menu_rows(cx: &mut App) -> Option<(TriggerKind, MenuRows)> {
    let pane = pane(cx)?;
    let composer = pane.read(cx).composer.clone();
    composer.read(cx).menu_rows(cx)
}

/// Waits for the open menu to list a row titled `title` (in `group`), and
/// returns its index.
async fn wait_row(group: Option<&str>, title: &str, cx: &mut AsyncApp) -> Option<usize> {
    let (group, title) = (group.map(str::to_string), title.to_string());
    let found = wait_until(cx, Duration::from_secs(15), |cx| {
        menu_rows(cx).is_some_and(|(_, rows)| {
            rows.iter()
                .any(|(g, t)| *t == title && (group.is_none() || *g == group))
        })
    })
    .await;
    if !found {
        log::warn!("menu rows: {:?}", cx.update(menu_rows));
        return None;
    }
    cx.update(menu_rows).and_then(|(_, rows)| {
        rows.iter()
            .position(|(g, t)| *t == title && (group.is_none() || *g == group))
    })
}

async fn choose(index: usize, cx: &mut AsyncApp) {
    in_pane(cx, move |p, window, cx| {
        p.composer
            .update(cx, |c, cx| c.choose_menu_item(index, window, cx))
    });
}

fn navigation(cx: &mut App) -> Entity<crate::stores::navigation::NavigationStore> {
    cx.global::<AppState>().stores.navigation.clone()
}

pub(super) async fn open_chat(id: &str, cx: &mut AsyncApp) -> bool {
    let id = id.to_string();
    let nav = cx.update(navigation);
    let want = id.clone();
    nav.update(cx, |n, cx| n.open(id, cx));
    wait_until(cx, Duration::from_secs(30), move |cx| {
        chat_store(cx).is_some_and(|s| {
            let s = s.read(cx);
            s.chat_id() == want && s.detail.is_some()
        })
    })
    .await
}

pub(super) async fn new_chat(cx: &mut AsyncApp) {
    let nav = cx.update(navigation);
    nav.update(cx, |n, cx| n.new_chat(false, cx));
    settle(cx, 300).await;
}

/// The fake model's newest streamed request, as its log has it.
fn last_request(path: &Path) -> Option<Value> {
    let text = std::fs::read_to_string(path).ok()?;
    text.lines()
        .rev()
        .filter_map(|l| serde_json::from_str::<Value>(l).ok())
        .find(|v| v.get("stream").and_then(Value::as_bool) == Some(true))
}

fn tools_of(request: &Option<Value>) -> Vec<String> {
    request
        .as_ref()
        .and_then(|r| r.get("tools"))
        .and_then(Value::as_array)
        .map(|a| {
            a.iter()
                .filter_map(|t| t.as_str().map(String::from))
                .collect()
        })
        .unwrap_or_default()
}

fn user_messages(cx: &mut App) -> Vec<String> {
    chat_store(cx)
        .map(|s| {
            s.read(cx)
                .messages()
                .iter()
                .filter(|m| m.role == "user")
                .map(|m| m.content.clone())
                .collect()
        })
        .unwrap_or_default()
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
    // The fake model, by name: the server also offers one that refuses.
    let model = inputs.model();
    in_pane(cx, move |p, _, cx| {
        p.composer_store
            .update(cx, |c, cx| c.select_model(&model, cx))
    });
    let offered = wait_until(cx, Duration::from_secs(20), |cx| {
        pane(cx).is_some_and(|p| {
            let o = &p.read(cx).composer_store.read(cx).options;
            o.skills && o.attachments.server_files
        })
    })
    .await;
    pass &= ok("composer.options offers skills and server files", offered);
    let rpc = cx.update(|cx| cx.global::<AppState>().stores.connection.read(cx).rpc());

    // ── A chat to work in, made here and deleted at the end ────────────
    new_chat(cx).await;
    send("Reply with exactly the word: pong", cx).await;
    pass &= ok(
        "a new chat answered",
        wait_answer(cx, Duration::from_secs(60)).await,
    );
    let chat_id = cx
        .update(|cx| chat_store(cx).map(|s| s.read(cx).chat_id().to_string()))
        .unwrap_or_default();
    // Its server id, once the stored copy has it.
    let stored = wait_until(cx, Duration::from_secs(30), |cx| {
        chat_store(cx).is_some_and(|s| !s.read(cx).chat_id().starts_with("local:"))
    })
    .await;
    pass &= ok("the chat has its server id", stored);
    let chat_id = cx
        .update(|cx| chat_store(cx).map(|s| s.read(cx).chat_id().to_string()))
        .unwrap_or(chat_id);

    pass &= drafts(&chat_id, dir, cx).await;
    pass &= queue(&chat_id, main, dir, cx).await;
    pass &= send_while_batch_waits(cx).await;
    pass &= triggers(inputs, dir, cx).await;
    pass &= server_files(inputs, dir, cx).await;
    pass &= web_page(inputs, dir, cx).await;
    pass &= code_interpreter(inputs, dir, cx).await;
    pass &= quick_pills_and_editor(dir, cx).await;
    pass &= save_as_note(&rpc, dir, cx).await;
    pass &= ask_conduit(&chat_id, dir, cx).await;
    pass &= settings_drive_the_composer(dir, cx).await;

    // ── Clean up ───────────────────────────────────────────────────────
    let deleted = rpc
        .call::<methods::ChatsDelete>(&ChatRef {
            id: chat_id.clone(),
        })
        .await;
    pass &= ok("the chat this pass made is deleted", deleted.is_ok());
    pass
}

/// A draft typed in a new chat and one in a stored chat are each back after
/// switching away and back.
async fn drafts(chat_id: &str, dir: &Path, cx: &mut AsyncApp) -> bool {
    let mut pass = true;
    new_chat(cx).await;
    type_text("Draft for the north bed", cx).await;
    settle(cx, 900).await;
    pass &= ok("the chat opens", open_chat(chat_id, cx).await);
    let cleared = wait_until(cx, Duration::from_secs(5), |cx| {
        composer_text(cx).is_empty()
    })
    .await;
    pass &= ok("another chat's composer does not show the draft", cleared);
    type_text("Draft inside a stored chat", cx).await;
    settle(cx, 900).await;
    new_chat(cx).await;
    let back = wait_until(cx, Duration::from_secs(10), |cx| {
        composer_text(cx) == "Draft for the north bed"
    })
    .await;
    pass &= ok("the new chat's draft is back after a chat switch", back);
    shoot_main(dir, "composer-draft-new-chat", cx).await;
    // Cleared, so later runs start empty.
    type_text("", cx).await;
    settle(cx, 900).await;
    pass &= ok("the chat opens again", open_chat(chat_id, cx).await);
    let kept = wait_until(cx, Duration::from_secs(10), |cx| {
        composer_text(cx) == "Draft inside a stored chat"
    })
    .await;
    pass &= ok("the stored chat's draft is back too", kept);
    type_text("", cx).await;
    settle(cx, 900).await;
    pass
}

/// A message queued while the answer streams, a second one, Stop & Send for
/// the first, and the second going out after it.
async fn queue(chat_id: &str, main: AnyWindowHandle, dir: &Path, cx: &mut AsyncApp) -> bool {
    let mut pass = true;
    send("Answer slow please", cx).await;
    let offered = wait_until(cx, Duration::from_secs(30), |cx| {
        pane(cx).is_some_and(|p| p.read(cx).composer.read(cx).queue_offer)
    })
    .await;
    pass &= ok("while the answer streams, a message is queued", offered);
    type_text("And the north side?", cx).await;
    shoot_main(dir, "composer-queue-button", cx).await;
    in_pane(cx, |p, window, cx| {
        p.composer.update(cx, |c, cx| c.submit(window, cx))
    });
    let one = wait_until(cx, Duration::from_secs(10), |cx| {
        chat_store(cx).is_some_and(|s| s.read(cx).queue.drafts.len() == 1)
    })
    .await;
    pass &= ok("queue.add: one message waits", one);
    pass &= ok(
        "the composer is empty again",
        cx.update(composer_text).is_empty(),
    );
    type_text("And the south side?", cx).await;
    in_pane(cx, |p, window, cx| {
        p.composer.update(cx, |c, cx| c.submit(window, cx))
    });
    let two = wait_until(cx, Duration::from_secs(10), |cx| {
        chat_store(cx).is_some_and(|s| s.read(cx).queue.drafts.len() == 2)
    })
    .await;
    pass &= ok("a second message waits behind it", two);
    settle(cx, 400).await;
    shoot_main(dir, "composer-queue", cx).await;
    let controls = ax(main, "composer-queue", dir, cx).await;
    pass &= ok(
        "each queued message has Edit, Remove from Queue and Stop & Send",
        controls
            .iter()
            .filter(|c| *c == "Button:Stop & Send")
            .count()
            == 2
            && controls
                .iter()
                .filter(|c| *c == "Button:Remove from Queue")
                .count()
                == 2
            && has(&controls, "Button", "Edit"),
    );
    // Stop & Send the first: the slow answer stops for it.
    let first = cx
        .update(|cx| {
            chat_store(cx).and_then(|s| s.read(cx).queue.drafts.first().map(|d| d.id.clone()))
        })
        .unwrap_or_default();
    in_pane(cx, move |p, _, cx| p.send_queued_now(&first, cx));
    let drained = wait_until(cx, Duration::from_secs(120), |cx| {
        user_messages(cx).len() >= 4
            && chat_store(cx).is_some_and(|s| {
                let s = s.read(cx);
                s.queue.drafts.is_empty() && !s.is_streaming()
            })
    })
    .await;
    pass &= ok("Stop & Send, then the rest after its answer", drained);
    pass &= ok(
        "both answered",
        wait_answer(cx, Duration::from_secs(60)).await,
    );
    let asked = cx.update(user_messages);
    pass &= ok(
        &format!("in order ({asked:?})"),
        asked.ends_with(&[
            "Answer slow please".to_string(),
            "And the north side?".to_string(),
            "And the south side?".to_string(),
        ]),
    );
    let _ = chat_id;
    pass
}

/// [wait_until] at a finer grain, for a state that lasts under a second.
async fn wait_briefly(
    cx: &mut AsyncApp,
    timeout: Duration,
    mut done: impl FnMut(&mut App) -> bool,
) -> bool {
    let deadline = std::time::Instant::now() + timeout;
    loop {
        if cx.update(|cx| done(cx)) {
            return true;
        }
        if std::time::Instant::now() > deadline {
            return false;
        }
        cx.background_executor()
            .timer(Duration::from_millis(20))
            .await;
    }
}

/// A message sent while the queue's next batch waits for the chat to settle
/// (the answer before it has just ended): the window shows Send, and the
/// message is sent, not refused, and answered before the batch, as on the
/// phone.
async fn send_while_batch_waits(cx: &mut AsyncApp) -> bool {
    let mut pass = true;
    send("Tell me something long", cx).await;
    let offered = wait_until(cx, Duration::from_secs(30), |cx| {
        pane(cx).is_some_and(|p| p.read(cx).composer.read(cx).queue_offer)
    })
    .await;
    pass &= ok("a message can be queued behind a long answer", offered);
    type_text("And the east side?", cx).await;
    in_pane(cx, |p, window, cx| {
        p.composer.update(cx, |c, cx| c.submit(window, cx))
    });
    let queued = wait_until(cx, Duration::from_secs(10), |cx| {
        chat_store(cx).is_some_and(|s| s.read(cx).queue.drafts.len() == 1)
    })
    .await;
    pass &= ok("queue.add: it waits behind the long answer", queued);
    // The answer ends, and the batch waits for the chat to settle.
    let waiting = wait_briefly(cx, Duration::from_secs(60), |cx| {
        chat_store(cx).is_some_and(|s| {
            let s = s.read(cx);
            s.queue.phase == QueuePhase::Admitting && !s.is_streaming()
        })
    })
    .await;
    let offers_send = cx.update(|cx| {
        pane(cx).is_some_and(|p| {
            let c = p.read(cx).composer.read(cx);
            !c.streaming && !c.queue_offer
        })
    });
    pass &= ok(
        "while the batch waits, the composer offers Send",
        waiting && offers_send,
    );
    let before = cx.update(user_messages).len();
    send("Reply with exactly the word: lark", cx).await;
    let both = wait_until(cx, Duration::from_secs(120), |cx| {
        user_messages(cx).len() >= before + 2
            && chat_store(cx).is_some_and(|s| {
                let s = s.read(cx);
                s.queue.drafts.is_empty() && !s.is_streaming()
            })
    })
    .await;
    pass &= ok("Send while the batch waits, then the batch", both);
    pass &= ok(
        "both answered",
        wait_answer(cx, Duration::from_secs(60)).await,
    );
    let asked = cx.update(user_messages);
    pass &= ok(
        &format!("the message sent goes first ({asked:?})"),
        asked.ends_with(&[
            "Tell me something long".to_string(),
            "Reply with exactly the word: lark".to_string(),
            "And the east side?".to_string(),
        ]),
    );
    pass
}

/// `$`, `@`, `#` and `/`, each listing the seed's rows at the caret.
async fn triggers(inputs: &E2eInputs, dir: &Path, cx: &mut AsyncApp) -> bool {
    let mut pass = true;
    // `$`: a skill, sent.
    type_text("Say hi $plain", cx).await;
    let skill = wait_row(None, "Plain English", cx).await;
    pass &= ok("$ lists the seed's skill", skill.is_some());
    settle(cx, 300).await;
    shoot_main(dir, "composer-menu-skills", cx).await;
    if let Some(i) = skill {
        choose(i, cx).await;
    }
    let mentions = cx.update(|cx| {
        pane(cx)
            .map(|p| p.read(cx).composer.read(cx).mentions(cx))
            .unwrap_or_default()
    });
    pass &= ok(
        &format!("the skill is a token in the text ({mentions:?})"),
        mentions.len() == 1 && mentions[0].id == "plain-english",
    );
    in_pane(cx, |p, window, cx| {
        p.composer.update(cx, |c, cx| c.submit(window, cx))
    });
    pass &= ok(
        "the skill's message is answered",
        wait_answer(cx, Duration::from_secs(60)).await,
    );
    if let Some(log) = inputs.get("FAKE_MODEL_LOG") {
        let tools = tools_of(&last_request(Path::new(&log)));
        pass &= ok(
            &format!("the server took the skill: its tools reached the model ({tools:?})"),
            tools.iter().any(|t| t == "view_skill"),
        );
    }
    // `@`: a person, and a channel.
    type_text("Ask @ril", cx).await;
    let person = wait_row(Some("People"), "Riley Example", cx).await;
    pass &= ok("@ lists the server's people", person.is_some());
    settle(cx, 300).await;
    shoot_main(dir, "composer-menu-people", cx).await;
    if let Some(i) = person {
        choose(i, cx).await;
    }
    let mentions = cx.update(|cx| {
        pane(cx)
            .map(|p| p.read(cx).composer.read(cx).mentions(cx))
            .unwrap_or_default()
    });
    pass &= ok(
        "the person is a mention token",
        mentions
            .iter()
            .any(|m| m.id_type == "U" && m.label == "Riley Example"),
    );
    type_text("Post in @gard", cx).await;
    pass &= ok(
        "@ lists channels too",
        wait_row(Some("Channels"), "garden-club", cx)
            .await
            .is_some(),
    );
    // `#`: notes, knowledge bases and their files.
    type_text("Use #", cx).await;
    let note = wait_row(Some("Notes"), "Garden plan for spring", cx).await;
    pass &= ok("# lists the seed's notes", note.is_some());
    pass &= ok(
        "and its knowledge base",
        wait_row(Some("Knowledge"), "Garden handbook", cx)
            .await
            .is_some(),
    );
    let file = wait_row(Some("Files"), "soil-guide.md", cx).await;
    pass &= ok("and that base's file", file.is_some());
    settle(cx, 300).await;
    shoot_main(dir, "composer-menu-context", cx).await;
    if let Some(i) = file {
        choose(i, cx).await;
    }
    type_text("Use #garden", cx).await;
    if let Some(i) = wait_row(Some("Notes"), "Garden plan for spring", cx).await {
        choose(i, cx).await;
    }
    let context = cx.update(|cx| {
        pane(cx)
            .map(|p| p.read(cx).composer_store.read(cx).context.clone())
            .unwrap_or_default()
    });
    pass &= ok(
        &format!("a note and a knowledge file go with the message ({context:?})"),
        context.iter().any(|c| c.name == "Garden plan for spring")
            && context.iter().any(|c| c.file_id.is_some()),
    );
    settle(cx, 300).await;
    shoot_main(dir, "composer-context-chips", cx).await;
    in_pane(cx, |p, window, cx| {
        p.composer_store.update(cx, |c, cx| c.clear_message(cx));
        p.composer.update(cx, |c, cx| c.set_text("", window, cx));
    });
    // `/`: still the prompts.
    type_text("/orb", cx).await;
    pass &= ok(
        "/ still lists prompts",
        wait_row(None, "/orbit", cx).await.is_some(),
    );
    type_text("", cx).await;
    pass
}

async fn server_files(inputs: &E2eInputs, dir: &Path, cx: &mut AsyncApp) -> bool {
    let mut pass = true;
    menu_action(ComposerMenu::ServerFiles, cx).await;
    let listed = wait_until(cx, Duration::from_secs(20), |cx| {
        pane(cx).is_some_and(|p| match &p.read(cx).composer.read(cx).panel {
            Some(Panel::ServerFiles(panel)) => panel
                .picker
                .read(cx)
                .files()
                .iter()
                .any(|f| f.name == "field-notes.txt"),
            _ => false,
        })
    })
    .await;
    pass &= ok("Server Files lists the account's files", listed);
    settle(cx, 300).await;
    shoot_main(dir, "composer-server-files", cx).await;
    in_pane(cx, |p, window, cx| {
        let file = match &p.composer.read(cx).panel {
            Some(Panel::ServerFiles(panel)) => panel
                .picker
                .read(cx)
                .files()
                .iter()
                .find(|f| f.name == "field-notes.txt")
                .cloned(),
            _ => None,
        };
        if let Some(file) = file {
            p.composer
                .update(cx, |c, cx| c.attach_server_file(file, window, cx));
        }
    });
    let want = inputs.get("OWUI_FILE").unwrap_or_default();
    let attached = cx.update(|cx| {
        pane(cx).is_some_and(|p| {
            p.read(cx)
                .composer_store
                .read(cx)
                .attachments
                .iter()
                .any(|a| matches!(&a.state, UploadState::Done { file_id } if *file_id == want))
        })
    });
    pass &= ok("the picked file is attached as it is, by its id", attached);
    settle(cx, 300).await;
    shoot_main(dir, "composer-server-file-attached", cx).await;
    in_pane(cx, |p, _, cx| {
        p.composer_store.update(cx, |c, cx| c.clear_message(cx))
    });
    pass
}

async fn web_page(inputs: &E2eInputs, dir: &Path, cx: &mut AsyncApp) -> bool {
    let mut pass = true;
    let Some(page) = inputs.get("FAKE_PAGE_URL") else {
        return ok("FAKE_PAGE_URL in the env file", false);
    };
    menu_action(ComposerMenu::WebPage, cx).await;
    settle(cx, 300).await;
    // Not a web address first: the panel says so.
    in_pane(cx, |p, window, cx| {
        if let Some(Panel::WebPage(panel)) = &p.composer.read(cx).panel {
            let url = panel.url.clone();
            url.update(cx, |s, cx| s.set_value("garden notes", window, cx));
        }
        p.composer.update(cx, |c, cx| c.fetch_web_page(window, cx));
    });
    settle(cx, 300).await;
    shoot_main(dir, "composer-web-page-invalid", cx).await;
    let page2 = page.clone();
    in_pane(cx, move |p, window, cx| {
        if let Some(Panel::WebPage(panel)) = &p.composer.read(cx).panel {
            let url = panel.url.clone();
            url.update(cx, |s, cx| s.set_value(page2, window, cx));
        }
        p.composer.update(cx, |c, cx| c.fetch_web_page(window, cx));
    });
    let read = wait_until(cx, Duration::from_secs(30), |cx| {
        pane(cx).is_some_and(|p| {
            p.read(cx).composer_store.read(cx).context.iter().any(|c| {
                c.content
                    .as_deref()
                    .is_some_and(|t| t.contains("raised bed"))
            })
        })
    })
    .await;
    pass &= ok("Web Page: the server read the page as context", read);
    settle(cx, 300).await;
    shoot_main(dir, "composer-web-context", cx).await;
    in_pane(cx, |p, _, cx| {
        p.composer_store.update(cx, |c, cx| c.clear_message(cx))
    });
    pass
}

async fn code_interpreter(inputs: &E2eInputs, dir: &Path, cx: &mut AsyncApp) -> bool {
    let mut pass = true;
    let offered = cx.update(|cx| {
        pane(cx).is_some_and(|p| p.read(cx).composer_store.read(cx).options.code_interpreter)
    });
    pass &= ok(
        "the server's Jupyter engine offers the code interpreter",
        offered,
    );
    menu_action(ComposerMenu::CodeInterpreter, cx).await;
    let on = cx
        .update(|cx| pane(cx).is_some_and(|p| p.read(cx).composer_store.read(cx).code_interpreter));
    pass &= ok("the switch is on", on);
    type_text("Hello there", cx).await;
    settle(cx, 300).await;
    shoot_main(dir, "composer-code-interpreter", cx).await;
    in_pane(cx, |p, window, cx| {
        p.composer.update(cx, |c, cx| c.submit(window, cx))
    });
    pass &= ok("answered", wait_answer(cx, Duration::from_secs(60)).await);
    if let Some(log) = inputs.get("FAKE_MODEL_LOG") {
        let tools = tools_of(&last_request(Path::new(&log)));
        pass &= ok(
            &format!("the request carried the code interpreter ({tools:?})"),
            tools.iter().any(|t| t == "execute_code"),
        );
    } else {
        pass &= ok("FAKE_MODEL_LOG in the env file", false);
    }
    menu_action(ComposerMenu::CodeInterpreter, cx).await;
    pass
}

fn app_settings(cx: &mut App) -> gpui_kit::Entity<AppSettingsStore> {
    cx.global::<AppState>().stores.app_settings.clone()
}

/// What the open pane's composer was last told, as Settings has it.
fn composer_prefs(cx: &mut App) -> Option<ComposerPrefs> {
    pane(cx).map(|p| p.read(cx).composer_store.read(cx).prefs.clone())
}

/// Changes app settings as Settings › Chat does, waits for the daemon's
/// answer to show `done`, then for the open composer to follow.
async fn set_settings(
    patch: AppSettingsPatch,
    done: impl Fn(&AppSettingsDto) -> bool,
    cx: &mut AsyncApp,
) -> Option<AppSettingsDto> {
    let store = cx.update(app_settings);
    store.update(cx, |s, cx| s.set(patch, cx));
    let followed = wait_until(cx, Duration::from_secs(10), |cx| {
        let settings = app_settings(cx).read(cx).settings().clone();
        done(&settings)
            && composer_prefs(cx).is_some_and(|p| p == ComposerPrefs::from_settings(&settings))
    })
    .await;
    followed.then(|| cx.update(|cx| app_settings(cx).read(cx).settings().clone()))
}

async fn quick_pills_and_editor(dir: &Path, cx: &mut AsyncApp) -> bool {
    let mut pass = true;
    // Chosen in Settings › Chat.
    let pills = set_settings(
        AppSettingsPatch {
            quick_pills: Some(vec!["web".into(), "image".into()]),
            ..Default::default()
        },
        |s| s.quick_pills == ["web", "image"],
        cx,
    )
    .await;
    pass &= ok(
        "quick pills chosen in Settings reach the composer",
        pills.is_some(),
    );
    settle(cx, 300).await;
    shoot_main(dir, "composer-quick-pills", cx).await;
    if let Some((main, _)) = cx.update(main_window) {
        let controls = ax(main, "composer-quick-pills", dir, cx).await;
        // The seed's server has image generation and no web search engine:
        // a pill shows only for a switch the model may use.
        let web = cx.update(|cx| {
            pane(cx).is_some_and(|p| p.read(cx).composer_store.read(cx).options.web_search)
        });
        pass &= ok(
            "quick pills are switches, for what the model may use",
            has(&controls, "Switch", "Image Gen") && has(&controls, "Switch", "Web") == web,
        );
    }
    set_settings(
        AppSettingsPatch {
            quick_pills: Some(vec![]),
            ..Default::default()
        },
        |s| s.quick_pills.is_empty(),
        cx,
    )
    .await;
    type_text(
        "A longer prompt.\nIt has a second line,\nand a third, for the larger editor.",
        cx,
    )
    .await;
    in_pane(cx, |p, window, cx| {
        p.composer
            .update(cx, |c, cx| c.set_expanded(true, window, cx))
    });
    settle(cx, 400).await;
    shoot_main(dir, "composer-expanded", cx).await;
    let expanded = cx.update(|cx| pane(cx).is_some_and(|p| p.read(cx).composer.read(cx).expanded));
    pass &= ok("⇧⌘E grows the field into the larger editor", expanded);
    in_pane(cx, |p, window, cx| {
        p.composer.update(cx, |c, cx| {
            c.set_expanded(false, window, cx);
            c.set_text("", window, cx)
        })
    });
    pass
}

async fn save_as_note(rpc: &crate::stores::rpc::Rpc, dir: &Path, cx: &mut AsyncApp) -> bool {
    let mut pass = true;
    let text = "Plan the north bed: beans first, then herbs at the corners.";
    type_text(text, cx).await;
    menu_action(ComposerMenu::SaveAsNote, cx).await;
    pass &= ok(
        "the composer is empty after saving",
        cx.update(composer_text).is_empty(),
    );
    settle(cx, 1500).await;
    shoot_main(dir, "composer-saved-as-note", cx).await;
    let title = chrono::Local::now().format("%Y-%m-%d").to_string();
    let mut found = None;
    for _ in 0..20 {
        if let Ok(list) = rpc
            .call::<methods::NotesList>(&NoteQuery {
                query: String::new(),
            })
            .await
        {
            found = list
                .notes
                .into_iter()
                .find(|n| n.title == title && n.preview.contains("north bed"));
        }
        if found.is_some() {
            break;
        }
        settle(cx, 500).await;
    }
    pass &= ok(
        &format!("notes.save made a note named for today ({found:?})"),
        found.is_some(),
    );
    if let Some(note) = found {
        let _ = rpc
            .call::<methods::NotesDelete>(&NoteRef { id: note.id })
            .await;
    }
    pass
}

async fn ask_conduit(chat_id: &str, dir: &Path, cx: &mut AsyncApp) -> bool {
    let mut pass = ok("the chat opens", open_chat(chat_id, cx).await);
    settle(cx, 800).await;
    let selected = in_pane(cx, |p, _, cx| {
        p.chat
            .as_ref()
            .map(|c| c.transcript.update(cx, |t, cx| t.select_newest_answer(cx)))
            .unwrap_or(false)
    })
    .unwrap_or(false);
    pass &= ok("an answer's text is selected", selected);
    settle(cx, 200).await;
    super::chat::dispatch(&crate::actions::AskConduit, cx);
    let quoted = wait_until(cx, Duration::from_secs(5), |cx| {
        !composer_text(cx).is_empty()
    })
    .await;
    pass &= ok("Ask Conduit puts the selection into the composer", quoted);
    settle(cx, 300).await;
    shoot_main(dir, "composer-ask-conduit", cx).await;
    type_text("", cx).await;
    settle(cx, 900).await;
    pass
}

/// Settings › Chat drives the composer as it changes: Send with Enter (on
/// by default here, unlike the phone), the Save as Note button, and new
/// chats starting temporary. Everything is put back at the end.
async fn settings_drive_the_composer(dir: &Path, cx: &mut AsyncApp) -> bool {
    let mut pass = true;
    let before = cx.update(|cx| app_settings(cx).read(cx).settings().clone());
    let field_sends =
        |cx: &mut App| pane(cx).is_some_and(|p| p.read(cx).composer.read(cx).sends_on_enter());
    pass &= ok(
        "Send with Enter is on by default on the desktop, in Settings and the field",
        before.send_on_enter && cx.update(field_sends),
    );
    let changed = set_settings(
        AppSettingsPatch {
            send_on_enter: Some(false),
            show_composer_notes_button: Some(false),
            temporary_chat_by_default: Some(true),
            ..Default::default()
        },
        |s| !s.send_on_enter && !s.show_composer_notes_button && s.temporary_chat_by_default,
        cx,
    )
    .await;
    pass &= ok(
        "turning Send with Enter, Save as Note and temporary chats over reaches the composer",
        changed.is_some(),
    );
    pass &= ok(
        "with Send with Enter off, the field breaks the line on Enter",
        !cx.update(field_sends),
    );
    new_chat(cx).await;
    let temporary = wait_until(cx, Duration::from_secs(5), |cx| {
        pane(cx).is_some_and(|p| {
            let c = p.read(cx).composer.read(cx);
            c.new_chat && c.temporary
        })
    })
    .await;
    pass &= ok(
        "a new chat starts temporary when the setting says so",
        temporary,
    );
    settle(cx, 300).await;
    shoot_main(dir, "composer-settings-temporary", cx).await;
    let restored = set_settings(
        AppSettingsPatch {
            send_on_enter: Some(before.send_on_enter),
            show_composer_notes_button: Some(before.show_composer_notes_button),
            temporary_chat_by_default: Some(before.temporary_chat_by_default),
            ..Default::default()
        },
        |s| {
            s.send_on_enter == before.send_on_enter
                && s.show_composer_notes_button == before.show_composer_notes_button
                && s.temporary_chat_by_default == before.temporary_chat_by_default
        },
        cx,
    )
    .await;
    pass &= ok("the settings are put back", restored.is_some());
    // The untouched new chat follows the default back.
    let ordinary = wait_until(cx, Duration::from_secs(5), |cx| {
        pane(cx).is_some_and(|p| !p.read(cx).composer.read(cx).temporary)
    })
    .await;
    pass &= ok("an untouched new chat follows the default back", ordinary);
    pass &= ok("and Enter sends again", cx.update(field_sends));
    pass
}
