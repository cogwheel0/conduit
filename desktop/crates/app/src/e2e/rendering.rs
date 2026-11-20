//! `--e2e rendering`: reply rendering and the in-chat surfaces, over
//! the real daemon, on the local Open WebUI and its fake model.
//!
//! * **A stored showcase chat** (`owui.sh showcase`): GitHub-style alerts
//!   as blocks of their own; two sources with the phone's inline labels,
//!   the citation preview and the Sources sheet; a tool call's HTML embed,
//!   opened and sized to its page; an MCP App (the fake model's
//!   `show_tides`), opened through the daemon's host and started; a page
//!   by its address; a picture in the image viewer; a video fetched
//!   through `/files` that AVKit can play.
//! * **Open WebUI's prompts, live:** `ask_user`'s two questions answered on
//!   the card (one per page, Next, Submit) and the answer going on with
//!   them; a tool approval approved, and the tool's answer.
//! * **The task checklist** a tool made, docked over the composer.
//! * **Alerts** in a streamed answer.
//! * **A message sent while the server is away:** queued on its answer,
//!   then sent on its own once the server is back; no "Answer ready" for
//!   the hand-off; a message sent while it still waits is queued behind it.
//!
//! Each state is shot in light and dark.

use std::collections::HashSet;
use std::path::Path;
use std::process::Command;
use std::time::Duration;

use conduit_protocol::{ChatPromptKind, ChatRef, EmbedKind, MessageBlockKind, methods};
use gpui_kit::{App, AsyncApp};
use serde_json::Value;

use super::chat::{chat_store, in_pane, pane, send, sign_in, wait_answer, wait_models};
use super::composer::{new_chat, open_chat};
use super::*;
use crate::views::chat::embed::EmbedView;

/// `owui.sh CMD [ARG]` from the repo (the app runs with `--cwd desktop/`;
/// the instance comes from `CONDUIT_OWUI_DIR`).
fn owui(command: &str, arg: Option<&Path>) -> bool {
    let mut c = Command::new("../tool/local_owui/owui.sh");
    c.arg(command);
    if let Some(a) = arg {
        c.arg(a);
    }
    c.status().is_ok_and(|s| s.success())
}

/// Auto tool permissions on the local server, or back as they were
/// (`owui.sh tool-permissions`): only the approval step wants them, and every
/// other pass expects the server as its seed left it.
fn tool_permissions(on: bool) -> bool {
    Command::new("../tool/local_owui/owui.sh")
        .args(["tool-permissions", if on { "on" } else { "off" }])
        .status()
        .is_ok_and(|s| s.success())
}

fn transcript(cx: &mut App) -> Option<Entity<crate::views::chat::transcript::Transcript>> {
    Some(pane(cx)?.read(cx).chat.as_ref()?.transcript.clone())
}

/// The open chat's newest answer, as the transcript draws it.
fn last_answer(cx: &mut App) -> Option<crate::stores::chat::RowItem> {
    let store = chat_store(cx)?;
    let s = store.read(cx);
    s.rows()
        .iter()
        .rev()
        .filter_map(|r| s.item(*r))
        .find(|i| i.role == crate::stores::chat::Role::Assistant)
}

fn embeds(cx: &mut App) -> Vec<Entity<EmbedView>> {
    transcript(cx)
        .map(|t| t.read(cx).embed_views(cx))
        .unwrap_or_default()
}

fn embed_of(kind: EmbedKind, cx: &mut App) -> Option<Entity<EmbedView>> {
    embeds(cx)
        .into_iter()
        .find(|e| e.read(cx).embed().kind == kind)
}

async fn open_embed(kind: EmbedKind, cx: &mut AsyncApp) -> bool {
    let found = wait_until(cx, Duration::from_secs(15), move |cx| {
        embed_of(kind, cx).is_some()
    })
    .await;
    if !found {
        return false;
    }
    // The main window is being updated here: reach the transcript through
    // it, not by reading it again.
    in_main(cx, move |mw, window, cx| {
        let transcript = mw
            .chat_pane
            .read(cx)
            .chat
            .as_ref()
            .map(|c| c.transcript.clone());
        let embed = transcript.and_then(|t| {
            t.read(cx)
                .embed_views(cx)
                .into_iter()
                .find(|e| e.read(cx).embed().kind == kind)
        });
        if let Some(e) = embed {
            e.update(cx, |e, cx| e.open(window, cx));
        }
    });
    true
}

pub async fn run(inputs: &E2eInputs, dir: &Path, cx: &mut AsyncApp) -> bool {
    let Some((url, email, password)) = inputs.owui() else {
        return ok(NO_SERVER, false);
    };
    // The showcase chat, stored on the server before the app signs in.
    let showcase_dir = dir.join("showcase");
    let stored = cx
        .background_executor()
        .spawn({
            let d = showcase_dir.clone();
            async move { owui("showcase", Some(&d)) }
        })
        .await;
    let mut pass = ok("owui.sh showcase stored the showcase chat", stored);
    let showcase: Value = std::fs::read_to_string(showcase_dir.join("showcase.json"))
        .ok()
        .and_then(|t| serde_json::from_str(&t).ok())
        .unwrap_or(Value::Null);
    let chat_id = showcase["chat_id"].as_str().unwrap_or_default().to_string();

    pass &= sign_in(&url, &email, &password, cx).await;
    pass &= ok("models.list answered", wait_models(cx).await);
    let model = inputs.model();
    in_pane(cx, move |p, _, cx| {
        p.composer_store
            .update(cx, |c, cx| c.select_model(&model, cx))
    });

    pass &= showcase_chat(&chat_id, &showcase, dir, cx).await;
    pass &= prompts(dir, cx).await;
    pass &= tasks_and_alerts(dir, cx).await;
    pass &= offline_queue(dir, cx).await;

    // ── Clean up: the chats this pass made, the showcase among them ────
    settle(cx, 1000).await;
    let made: HashSet<String> = MADE
        .lock()
        .map(|mut m| std::mem::take(&mut *m))
        .unwrap_or_default()
        .into_iter()
        .chain(std::iter::once(chat_id.clone()))
        .filter(|id| !id.is_empty() && !id.starts_with("local:"))
        .collect();
    let rpc = cx.update(|cx| cx.global::<AppState>().stores.connection.read(cx).rpc());
    let mut deleted = true;
    for id in &made {
        deleted &= rpc
            .call::<methods::ChatsDelete>(&ChatRef { id: id.clone() })
            .await
            .is_ok();
    }
    pass &= ok(
        &format!("the chats this pass made are deleted ({})", made.len()),
        deleted,
    );
    pass
}

/// The chats this pass made (the showcase aside), deleted at its end so the
/// account keeps its seed: the sidebar pass counts on it.
static MADE: std::sync::Mutex<Vec<String>> = std::sync::Mutex::new(Vec::new());

/// Notes the open chat as one this pass made, once it has the server's id.
async fn remember_chat(cx: &mut AsyncApp) {
    wait_until(cx, Duration::from_secs(15), |cx| {
        chat_store(cx).is_some_and(|s| !s.read(cx).chat_id().starts_with("local:"))
    })
    .await;
    let id = cx.update(|cx| chat_store(cx).map(|s| s.read(cx).chat_id().to_string()));
    if let Some(id) = id.filter(|id| !id.is_empty())
        && let Ok(mut made) = MADE.lock()
    {
        made.push(id);
    }
}

async fn showcase_chat(chat_id: &str, showcase: &Value, dir: &Path, cx: &mut AsyncApp) -> bool {
    let opened = open_chat(chat_id, cx).await;
    let mut pass = ok("the showcase chat opens", opened);
    settle(cx, 1200).await;
    let answer = cx.update(last_answer);
    let kinds: Vec<MessageBlockKind> = answer
        .as_ref()
        .map(|a| a.blocks.iter().map(|b| b.kind).collect())
        .unwrap_or_default();
    let alerts: Vec<String> = answer
        .as_ref()
        .map(|a| {
            a.blocks
                .iter()
                .filter(|b| b.kind == MessageBlockKind::Alert)
                .filter_map(|b| b.r#type.clone())
                .collect()
        })
        .unwrap_or_default();
    pass &= ok(
        &format!("five GitHub-style alerts, each its own block ({alerts:?})"),
        alerts == ["note", "tip", "important", "warning", "caution"],
    );
    pass &= ok(
        &format!("files, embeds, then the content ({kinds:?})"),
        kinds.first() == Some(&MessageBlockKind::Files)
            && kinds.get(1) == Some(&MessageBlockKind::Embeds),
    );
    let sources = answer
        .as_ref()
        .map(|a| a.sources.clone())
        .unwrap_or_default();
    pass &= ok(
        &format!(
            "two sources with inline labels ({:?})",
            sources
                .iter()
                .map(|s| s.inline_label.clone())
                .collect::<Vec<_>>()
        ),
        sources.len() == 2 && sources.iter().all(|s| s.inline_label.is_some()),
    );
    // The pill reads the source's site (or, with Show Citation Titles, its
    // title).
    let key = answer.as_ref().map(|a| a.key.clone()).unwrap_or_default();
    let label = cx.update({
        let key = key.clone();
        move |cx| transcript(cx).and_then(|t| t.read(cx).citation_label(&key, &[1], cx))
    });
    pass &= ok(
        &format!("a citation reads as its source's site ({label:?})"),
        label.as_ref().is_some_and(|(l, _, _)| l == "127.0.0.1"),
    );
    shoot_main(dir, "rendering-showcase", cx).await;

    // The citation preview.
    in_main(cx, {
        let key = key.clone();
        move |mw, window, cx| {
            if let Some(t) = mw
                .chat_pane
                .read(cx)
                .chat
                .as_ref()
                .map(|c| c.transcript.clone())
            {
                let at = gpui_kit::point(gpui_kit::px(420.), gpui_kit::px(220.));
                t.update(cx, |t, cx| t.show_citation(key, vec![1], at, window, cx));
            }
        }
    });
    let shown = wait_until(cx, Duration::from_secs(5), |cx| {
        transcript(cx).is_some_and(|t| t.read(cx).citation_open())
    })
    .await;
    pass &= ok("the citation preview opens", shown);
    settle(cx, 400).await;
    shoot_main(dir, "rendering-citation-preview", cx).await;
    in_main(cx, |mw, _, cx| {
        if let Some(t) = mw
            .chat_pane
            .read(cx)
            .chat
            .as_ref()
            .map(|c| c.transcript.clone())
        {
            t.update(cx, |t, cx| t.close_citation(cx));
        }
    });

    // The Sources sheet.
    let before = cx.update(|cx| cx.windows());
    in_main(cx, {
        let sources = sources.clone();
        move |_, window, cx| crate::views::chat::sources::open_sheet(sources, window, cx)
    });
    let sheet_window = new_window(&before, cx).await;
    pass &= ok("the Sources sheet opens", sheet_window.is_some());
    settle(cx, 800).await;
    if let Some(w) = sheet_window {
        shoot_both_modes(w, dir, "rendering-sources-sheet", cx).await;
        let _ = w.update(cx, |_, window, cx| {
            crate::views::settings::end_sheet_window(window.window_handle(), cx)
        });
        settle(cx, 500).await;
    } else {
        pass &= ok("the Sources sheet is a window of its own", false);
    }

    // The tool's HTML embed: opened, it reports its height.
    pass &= ok(
        "the tool's HTML embed is offered",
        open_embed(EmbedKind::Html, cx).await,
    );
    let sized = wait_until(cx, Duration::from_secs(15), |cx| {
        embed_of(EmbedKind::Html, cx).is_some_and(|e| {
            let e = e.read(cx);
            e.is_open()
                && (e.height() - crate::views::chat::preview::EMBED_DEFAULT_HEIGHT).abs() > 0.5
        })
    })
    .await;
    pass &= ok("the HTML embed opens and takes its page's height", sized);

    // The MCP App: the daemon hosts it, and it starts.
    pass &= ok(
        "the MCP App is offered",
        open_embed(EmbedKind::McpApp, cx).await,
    );
    let started = wait_until(cx, Duration::from_secs(30), |cx| {
        embed_of(EmbedKind::McpApp, cx).is_some_and(|e| e.read(cx).started())
    })
    .await;
    let failure = cx.update(|cx| {
        embed_of(EmbedKind::McpApp, cx).and_then(|e| e.read(cx).failure().map(str::to_string))
    });
    pass &= ok(
        &format!("the MCP App starts (failure: {failure:?})"),
        started,
    );
    let resized = wait_until(cx, Duration::from_secs(10), |cx| {
        embed_of(EmbedKind::McpApp, cx).is_some_and(|e| (e.read(cx).height() - 180.).abs() < 0.5)
    })
    .await;
    pass &= ok("the MCP App takes the height it asked for", resized);
    // The page by its address.
    pass &= ok(
        "the page embed is offered",
        open_embed(EmbedKind::Url, cx).await,
    );
    let page = wait_until(cx, Duration::from_secs(10), |cx| {
        embed_of(EmbedKind::Url, cx).is_some_and(|e| e.read(cx).is_open())
    })
    .await;
    pass &= ok("the page embed opens", page);
    settle(cx, 1500).await;
    shoot_main(dir, "rendering-embeds", cx).await;

    // The picture in the viewer.
    let server = cx.update(|cx| {
        cx.global::<AppState>()
            .stores
            .accounts
            .read(cx)
            .active()
            .map(|a| a.connection.id.clone())
    });
    let image_id = showcase["image_id"]
        .as_str()
        .unwrap_or_default()
        .to_string();
    let before = cx.update(|cx| cx.windows());
    if let Some(server_id) = server.clone() {
        cx.update(|cx| {
            crate::views::image_viewer::open(
                vec![crate::views::image_viewer::ViewerImage::File {
                    file: crate::stores::files::FileRef {
                        server_id,
                        file_id: image_id.clone(),
                    },
                    name: "tide-chart.png".into(),
                }],
                0,
                cx,
            )
        });
    }
    let viewer_window = new_window(&before, cx).await;
    pass &= ok("the image viewer opens", viewer_window.is_some());
    settle(cx, 1500).await;
    if let Some(w) = viewer_window {
        shoot_both_modes(w, dir, "rendering-image-viewer", cx).await;
        let _ = w.update(cx, |_, window, _| window.remove_window());
    }

    // The video: fetched through `/files` with the server's credentials,
    // and AVKit plays it.
    if let (Some(server_id), Some(video_id)) = (server, showcase["video_id"].as_str()) {
        let file = crate::stores::files::FileRef {
            server_id,
            file_id: video_id.to_string(),
        };
        let staged = cx.update(|cx| crate::stores::files::stage_file(file, "harbour-loop.mp4", cx));
        let staged = staged.await;
        let movie = staged
            .as_ref()
            .ok()
            .and_then(|p| std::fs::read(p).ok())
            .is_some_and(|b| b.len() > 8 && &b[4..8] == b"ftyp");
        pass &= ok(
            &format!("the video comes through /files ({staged:?})"),
            movie,
        );
        if let Ok(path) = staged {
            let plays = in_main(cx, move |_, window, _| {
                crate::views::chat::inline_web::InlineWebView::player(&path, window).is_some()
            })
            .unwrap_or(false);
            pass &= ok("AVKit's player takes it", plays);
        }
    } else {
        log::warn!("no video in the showcase (ffmpeg missing?)");
    }
    pass
}

/// The window that opened since `before` was listed, once it has.
async fn new_window(
    before: &[gpui_kit::AnyWindowHandle],
    cx: &mut AsyncApp,
) -> Option<gpui_kit::AnyWindowHandle> {
    let listed = before.to_vec();
    let opened = wait_until(cx, Duration::from_secs(5), move |cx| {
        cx.windows().iter().any(|w| !listed.contains(w))
    })
    .await;
    if !opened {
        return None;
    }
    let listed = before.to_vec();
    cx.update(move |cx| cx.windows().into_iter().find(|w| !listed.contains(w)))
}

async fn wait_prompt(kind: ChatPromptKind, cx: &mut AsyncApp) -> bool {
    wait_until(cx, Duration::from_secs(60), move |cx| {
        chat_store(cx).is_some_and(|s| s.read(cx).prompt.as_ref().is_some_and(|p| p.kind == kind))
    })
    .await
}

fn answer_text(cx: &mut App) -> String {
    last_answer(cx).map(|a| a.text).unwrap_or_default()
}

async fn prompts(dir: &Path, cx: &mut AsyncApp) -> bool {
    let mut pass = true;
    new_chat(cx).await;
    send("Please ask me where we should sail.", cx).await;
    remember_chat(cx).await;
    let asked = wait_prompt(ChatPromptKind::AskUser, cx).await;
    let questions = cx.update(|cx| {
        chat_store(cx)
            .and_then(|s| s.read(cx).prompt.clone())
            .map(|p| p.questions.len())
            .unwrap_or_default()
    });
    pass &= ok(
        &format!("ask_user's questions dock above the composer ({questions})"),
        asked && questions == 2,
    );
    settle(cx, 600).await;
    shoot_main(dir, "rendering-ask-user", cx).await;
    // The first question's first choice, Next, the second's second, Submit.
    in_pane(cx, |p, window, cx| {
        p.prompt_card.update(cx, |c, cx| {
            c.pick(0, cx);
            c.step(1, window, cx);
            c.pick(1, cx);
        })
    });
    settle(cx, 300).await;
    shoot_main(dir, "rendering-ask-user-second", cx).await;
    in_pane(cx, |p, _, cx| {
        p.prompt_card.update(cx, |c, cx| c.primary(cx))
    });
    let gone = wait_until(cx, Duration::from_secs(30), |cx| {
        chat_store(cx).is_some_and(|s| s.read(cx).prompt.is_none())
    })
    .await;
    pass &= ok("the card goes once answered", gone);
    let answered = wait_until(cx, Duration::from_secs(90), |cx| {
        answer_text(cx).contains("You chose Morning and Four")
    })
    .await;
    pass &= ok(
        &format!(
            "the answer goes on with the choices ({:?})",
            cx.update(answer_text)
        ),
        answered,
    );
    pass &= wait_answer(cx, Duration::from_secs(60)).await;

    // A tool that needs approval: the server asks only with auto tool
    // permissions on, which this step turns on and puts back after.
    let enabled = cx
        .background_executor()
        .spawn(async { tool_permissions(true) })
        .await;
    pass &= ok("owui.sh tool-permissions on", enabled);
    new_chat(cx).await;
    send("What time is it? Please approve the clock.", cx).await;
    remember_chat(cx).await;
    let approval = wait_prompt(ChatPromptKind::ToolApproval, cx).await;
    pass &= ok("the tool approval docks above the composer", approval);
    settle(cx, 600).await;
    shoot_main(dir, "rendering-tool-approval", cx).await;
    in_pane(cx, |p, _, cx| {
        p.prompt_card.update(cx, |c, cx| c.primary(cx))
    });
    let ran = wait_until(cx, Duration::from_secs(90), |cx| {
        answer_text(cx).contains("The clock said so")
    })
    .await;
    pass &= ok(
        &format!(
            "approved, the tool runs and the answer goes on ({:?})",
            cx.update(answer_text)
        ),
        ran,
    );
    pass &= wait_answer(cx, Duration::from_secs(60)).await;
    let restored = cx
        .background_executor()
        .spawn(async { tool_permissions(false) })
        .await;
    pass &= ok("owui.sh tool-permissions off", restored);
    pass
}

async fn tasks_and_alerts(dir: &Path, cx: &mut AsyncApp) -> bool {
    let mut pass = true;
    new_chat(cx).await;
    send("Please plan the tasks for the trip.", cx).await;
    remember_chat(cx).await;
    let listed = wait_until(cx, Duration::from_secs(90), |cx| {
        chat_store(cx).is_some_and(|s| s.read(cx).tasks.len() == 3)
    })
    .await;
    pass &= ok("the task checklist arrives with the turn", listed);
    pass &= wait_answer(cx, Duration::from_secs(60)).await;
    let kept = cx.update(|cx| {
        chat_store(cx)
            .map(|s| {
                s.read(cx)
                    .tasks
                    .iter()
                    .map(|t| t.status.clone())
                    .collect::<Vec<_>>()
            })
            .unwrap_or_default()
    });
    pass &= ok(
        &format!("the stored chat keeps it ({kept:?})"),
        kept == ["completed", "in_progress", "pending"],
    );
    in_pane(cx, |p, _, cx| p.set_tasks_open(true, cx));
    settle(cx, 400).await;
    shoot_main(dir, "rendering-tasks", cx).await;
    in_pane(cx, |p, _, cx| p.set_tasks_open(false, cx));

    send("Show me the alerts before we sail.", cx).await;
    pass &= wait_answer(cx, Duration::from_secs(60)).await;
    let alerts = cx.update(|cx| {
        last_answer(cx)
            .map(|a| {
                a.blocks
                    .iter()
                    .filter(|b| b.kind == MessageBlockKind::Alert)
                    .count()
            })
            .unwrap_or_default()
    });
    pass &= ok(
        &format!("a streamed answer's alerts ({alerts})"),
        alerts == 5,
    );
    shoot_main(dir, "rendering-alerts", cx).await;
    pass
}

async fn offline_queue(dir: &Path, cx: &mut AsyncApp) -> bool {
    let mut pass = true;
    new_chat(cx).await;
    send("Reply with exactly the word: plover", cx).await;
    remember_chat(cx).await;
    pass &= wait_answer(cx, Duration::from_secs(60)).await;
    // Every `turn.finished` from here on, as the notifications hear it.
    let ends: std::rc::Rc<std::cell::RefCell<Vec<conduit_protocol::TurnFinished>>> =
        Default::default();
    let _ends_watch = cx.update(|cx| {
        let connection = cx.global::<AppState>().connection.clone();
        let ends = ends.clone();
        cx.subscribe(&connection, move |_, event, _| {
            if let crate::stores::connection::ConnectionEvent::Daemon(event) = event
                && let conduit_protocol::Event::TurnFinished(f) = event.as_ref()
            {
                ends.borrow_mut().push(f.clone());
            }
        })
    });
    let stopped = cx
        .background_executor()
        .spawn(async { owui("stop", None) })
        .await;
    pass &= ok("owui.sh stop", stopped);
    settle(cx, 1500).await;
    send("Reply with exactly the word: tern", cx).await;
    let queued = wait_until(cx, Duration::from_secs(90), |cx| {
        last_answer(cx).is_some_and(|a| a.queued.is_some())
    })
    .await;
    pass &= ok(
        &format!(
            "sent while the server is away, the answer is queued ({:?})",
            cx.update(|cx| last_answer(cx).map(|a| a.queued))
        ),
        queued,
    );
    let tern = cx.update(|cx| last_answer(cx).map(|a| a.key));
    settle(cx, 600).await;
    shoot_main(dir, "rendering-queued", cx).await;
    let started = cx
        .background_executor()
        .spawn(async { owui("start", None) })
        .await;
    pass &= ok("owui.sh start", started);
    // Back online with the answer still waiting to go out: a message sent
    // now is queued behind it (the daemon is writing it; a turn beside it
    // would be refused as busy), as on the phone.
    let waits = wait_until(cx, Duration::from_secs(60), |cx| {
        let Some(store) = chat_store(cx) else {
            return false;
        };
        let online = pane(cx).is_some_and(|p| !p.read(cx).composer.read(cx).offline);
        let s = store.read(cx);
        online && s.answer_queued() && s.queue_offered()
    })
    .await;
    if waits {
        send("Reply with exactly the word: gull", cx).await;
        let behind = wait_until(cx, Duration::from_secs(10), |cx| {
            chat_store(cx).is_some_and(|s| !s.read(cx).queue.drafts.is_empty())
        })
        .await;
        pass &= ok(
            "a message sent while the answer waits is queued behind it",
            behind,
        );
    } else {
        println!("SMOKE e2e skip the queued answer went out before the window was back online");
    }
    let sent = wait_until(cx, Duration::from_secs(180), |cx| {
        let Some(store) = chat_store(cx) else {
            return false;
        };
        let s = store.read(cx);
        s.rows()
            .iter()
            .filter_map(|r| s.item(*r))
            .any(|i| Some(&i.key) == tern.as_ref() && i.queued.is_none() && i.text.contains("tern"))
    })
    .await;
    pass &= ok(
        &format!(
            "back online, it goes out on its own ({:?})",
            cx.update(answer_text)
        ),
        sent,
    );
    if waits {
        let after = wait_until(cx, Duration::from_secs(90), |cx| {
            last_answer(cx).is_some_and(|a| !a.streaming && a.text.contains("gull"))
        })
        .await;
        pass &= ok(
            &format!(
                "then the queued message goes out after it ({:?})",
                cx.update(answer_text)
            ),
            after,
        );
    }
    // The answer's hand-offs while it waited say `queued`, so no "Answer
    // ready" went out for them; the turn that brought it says it ended.
    let ends = ends.borrow().clone();
    let of_tern: Vec<_> = ends
        .iter()
        .filter(|f| Some(&f.message_id) == tern.as_ref())
        .collect();
    let (last, handoffs) = match of_tern.split_last() {
        Some((last, rest)) => (Some(*last), rest.to_vec()),
        None => (None, vec![]),
    };
    let quiet = handoffs.iter().all(|f| {
        f.queued
            && crate::shell::notify::kind_for(crate::shell::notify::Outcome::of(f.ok, f.queued))
                .is_none()
    });
    pass &= ok(
        &format!(
            "a queued answer's hand-off posts no Answer Ready ({} hand-off(s), then {:?})",
            handoffs.len(),
            last.map(|f| (f.ok, f.queued))
        ),
        quiet && last.is_some_and(|f| f.ok && !f.queued),
    );
    pass
}
