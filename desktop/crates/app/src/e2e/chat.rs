//! `--e2e chat | chat-direct | chat-smoke | chat-read-only`: the chat view
//! over the real daemon, on the local Open WebUI and its fake model.
//!
//! * `chat`: send and stream (reasoning, code with Preview, math, a long
//!   answer), stop, regenerate and the version arrows, edit in place, rate,
//!   an attachment, a `/` prompt with its fill-in form, the model picker,
//!   a tool call and a tool approval docked above the composer, copy
//!   shortcuts, and the AccessKit check (messages are labelled articles;
//!   the composer and the model picker are labelled).
//! * `chat-direct`: Direct mode against the fake model as an
//!   OpenAI-compatible provider (`FAKE_OPENAI_URL`): reasoning and an answer.
//! * `chat-smoke`: two turns with the model chosen per message (`@`), then
//!   every chat this pass made is deleted and the account's chat list is
//!   checked against what it was before.
//! * `chat-read-only`: another user's chat in a folder shared with the
//!   account opens read-only.

use std::collections::BTreeSet;
use std::path::Path;
use std::time::Duration;

use conduit_protocol::{ChatRef, NoParams, methods};
use gpui_kit::{AnyWindowHandle, App, AsyncApp, Entity, Window};
use serde_json::Value;

use super::*;
use crate::stores::chat::ChatStore;
use crate::views::chat_pane::ChatPane;

pub(super) fn pane(cx: &mut App) -> Option<Entity<ChatPane>> {
    Some(main_window(cx)?.1.read(cx).chat_pane.clone())
}

pub(super) fn in_pane<R>(
    cx: &mut AsyncApp,
    f: impl FnOnce(&mut ChatPane, &mut Window, &mut gpui_kit::Context<ChatPane>) -> R,
) -> Option<R> {
    in_main(cx, |mw, window, cx| {
        let pane = mw.chat_pane.clone();
        pane.update(cx, |p, cx| f(p, window, cx))
    })
}

pub(super) fn chat_store(cx: &mut App) -> Option<Entity<ChatStore>> {
    Some(pane(cx)?.read(cx).chat.as_ref()?.store.clone())
}

/// Types `text` into the composer and presses Send.
pub(super) async fn send(text: &str, cx: &mut AsyncApp) {
    let text = text.to_string();
    in_pane(cx, move |p, window, cx| {
        p.composer.update(cx, |c, cx| {
            c.set_text(&text, window, cx);
            c.submit(window, cx);
        })
    });
}

/// The open chat's newest answer has finished and settled into the stored
/// copy.
pub(super) async fn wait_answer(cx: &mut AsyncApp, timeout: Duration) -> bool {
    wait_until(cx, timeout, |cx| {
        let Some(store) = chat_store(cx) else {
            return false;
        };
        let s = store.read(cx);
        let last = s.rows().last().and_then(|r| s.item(*r));
        !s.is_streaming()
            && s.live.is_none()
            && s.pending.is_none()
            && last.is_some_and(|i| {
                i.role == crate::stores::chat::Role::Assistant && !i.text.trim().is_empty()
            })
    })
    .await
}

pub(super) async fn wait_streaming(cx: &mut AsyncApp, timeout: Duration) -> bool {
    wait_until(cx, timeout, |cx| {
        chat_store(cx).is_some_and(|s| {
            let s = s.read(cx);
            s.live
                .as_ref()
                .is_some_and(|l| l.streaming() && !l.blocks.is_empty())
        })
    })
    .await
}

pub(super) fn last_answer_text(cx: &mut App) -> String {
    let Some(store) = chat_store(cx) else {
        return String::new();
    };
    let s = store.read(cx);
    s.rows()
        .iter()
        .rev()
        .filter_map(|r| s.item(*r))
        .find(|i| i.role == crate::stores::chat::Role::Assistant)
        .map(|i| i.text)
        .unwrap_or_default()
}

fn kinds_of_last_answer(cx: &mut App) -> Vec<String> {
    let Some(store) = chat_store(cx) else {
        return vec![];
    };
    let s = store.read(cx);
    s.rows()
        .iter()
        .rev()
        .filter_map(|r| s.item(*r))
        .find(|i| i.role == crate::stores::chat::Role::Assistant)
        .map(|i| i.blocks.iter().map(|b| format!("{:?}", b.kind)).collect())
        .unwrap_or_default()
}

/// Dispatches `action` in the main window, as its key binding would.
pub(super) fn dispatch(action: &dyn gpui_kit::Action, cx: &mut AsyncApp) {
    let action = action.boxed_clone();
    cx.update(|cx| {
        if let Some((handle, _)) = main_window(cx) {
            let _ = handle.update(cx, |_, window, cx| {
                window.activate_window();
                window.dispatch_action(action, cx)
            });
        }
    });
}

/// The AccessKit tree's labelled articles, and its controls as
/// `role:label`.
async fn ax_tree(handle: AnyWindowHandle, cx: &mut AsyncApp) -> (Vec<String>, Vec<String>) {
    let ptr = cx.update(|cx| {
        handle
            .update(cx, |_, window, _| cw::macos::ns_window_ptr(window))
            .ok()
            .flatten()
    });
    if let Some(ptr) = ptr {
        // SAFETY: this process's live NSWindow, on the main thread.
        unsafe { capture::activate_accessibility(ptr) };
    }
    let mut tree = None;
    for _ in 0..20 {
        settle(cx, 150).await;
        tree = cx.update(|cx| {
            handle
                .update(cx, |_, window, _| {
                    window.refresh();
                    window.debug_a11y_tree_json()
                })
                .ok()
                .flatten()
        });
        if tree.as_ref().is_some_and(|t| t.contains("\"Article\"")) {
            break;
        }
    }
    let Some(tree) = tree.and_then(|t| serde_json::from_str::<Value>(&t).ok()) else {
        return (vec![], vec![]);
    };
    let (mut articles, mut controls) = (vec![], vec![]);
    if let Some(nodes) = tree.get("nodes").and_then(Value::as_object) {
        for node in nodes.values() {
            let aria = node.get("aria").cloned().unwrap_or(Value::Null);
            let role = aria.get("role").and_then(Value::as_str).unwrap_or("");
            let label = aria
                .get("label")
                .and_then(Value::as_str)
                .unwrap_or("")
                .trim()
                .to_string();
            if role == "Article" {
                articles.push(label);
            } else if !role.is_empty() && role != "GenericContainer" {
                controls.push(format!("{role}:{label}"));
            }
        }
    }
    (articles, controls)
}

/// Signs in to `url` from a fresh profile.
pub(super) async fn sign_in(url: &str, email: &str, password: &str, cx: &mut AsyncApp) -> bool {
    let mut pass = fresh_profile(cx).await;
    pass &= ok("the setup window opened", wait_setup(cx).await.is_some());
    in_setup(cx, |sw, window, cx| {
        sw.onboarding.update(cx, |o, cx| o.choose(window, cx))
    });
    settle(cx, 500).await;
    connect_server(url, "Lab server", cx).await;
    pass &= wait_route(cx, Route::SignIn, Duration::from_secs(60)).await;
    sign_in_password(email, password, cx).await;
    pass &= wait_route(cx, Route::Main, Duration::from_secs(60)).await;
    pass &= wait_main(cx).await.is_some();
    pass
}

pub(super) async fn wait_models(cx: &mut AsyncApp) -> bool {
    wait_until(cx, Duration::from_secs(30), |cx| {
        pane(cx).is_some_and(|p| {
            p.read(cx)
                .composer_store
                .read(cx)
                .models
                .as_ref()
                .is_some_and(|m| !m.models.is_empty())
        })
    })
    .await
}

pub async fn run(inputs: &E2eInputs, dir: &Path, cx: &mut AsyncApp) -> bool {
    match inputs.scenario.as_str() {
        "chat" => local(inputs, dir, cx).await,
        "chat-direct" => direct_chat(inputs, dir, cx).await,
        "chat-smoke" => smoke(inputs, dir, cx).await,
        "chat-read-only" => read_only(inputs, dir, cx).await,
        other => ok(&format!("unknown chat scenario {other}"), false),
    }
}

/// `--e2e chat-read-only`: another user's chat in a folder shared with the
/// signed-in account (`OWUI_SHARED_CHAT`, seeded on the local server)
/// opens read-only: the toolbar says so, there is no composer, and no
/// follow-ups, edit, regenerate or rating.
async fn read_only(inputs: &E2eInputs, dir: &Path, cx: &mut AsyncApp) -> bool {
    let (Some((url, email, password)), Some(chat)) =
        (inputs.owui(), inputs.get("OWUI_SHARED_CHAT"))
    else {
        return ok(NO_SERVER, false);
    };
    let mut pass = sign_in(&url, &email, &password, cx).await;
    let Some((main, _)) = cx.update(main_window) else {
        return ok("main window", false);
    };
    // The shared folder in the sidebar holds its owner's chats, read-only
    // (`OWUI_SHARED_FOLDER`, seeded with two of them); the chat opens
    // from there.
    if let Some(folder_id) = inputs.get("OWUI_SHARED_FOLDER") {
        pass &= shared_folder(&folder_id, &chat, main, dir, cx).await;
        in_main(cx, |mw, _, cx| {
            mw.sidebar.update(cx, |s, cx| s.open(&chat, cx))
        });
    } else {
        cx.update(|cx| {
            let navigation = cx.global::<AppState>().stores.navigation.clone();
            navigation.update(cx, |n, cx| n.open(chat.clone(), cx));
        });
    }
    let loaded = wait_until(cx, Duration::from_secs(30), |cx| {
        chat_store(cx).is_some_and(|s| {
            let s = s.read(cx);
            s.chat_id() == chat && s.detail.is_some() && !s.messages().is_empty()
        })
    })
    .await;
    pass &= ok("the shared chat opens with its transcript", loaded);
    let (read_only, can_branch) = cx.update(|cx| {
        chat_store(cx)
            .map(|s| (s.read(cx).read_only(), s.read(cx).can_branch()))
            .unwrap_or_default()
    });
    pass &= ok("chats.get marks it read-only", read_only);
    pass &= ok("edit, regenerate and rate are off", !can_branch);
    settle(cx, 800).await;
    shoot_main(dir, "chat-read-only", cx).await;
    let (articles, controls) = ax_tree(main, cx).await;
    pass &= ok(
        &format!("its messages are shown ({} articles)", articles.len()),
        articles.len() >= 2,
    );
    pass &= ok(
        "the toolbar says Read-only",
        has(&controls, "Status", "Read-only"),
    );
    pass &= ok(
        "the composer is replaced by the shared-chat notice",
        !has(&controls, "MultilineTextInput", "Message")
            && has(&controls, "Status", "shared with you"),
    );
    // More stays: it holds Copy as Markdown, and the rating only where the
    // chat can branch (off here, checked above).
    pass &= ok(
        "no follow-ups, regenerate, edit or rating",
        !has(&controls, "Button", "Regenerate")
            && !has(&controls, "Button", "Edit")
            && !has(&controls, "Button", "Good Answer")
            && !has(&controls, "Button", "What about food?"),
    );
    pass &= ok(
        "copy stays, with More for Copy as Markdown",
        has(&controls, "Button", "Copy") && has(&controls, "Button", "More"),
    );
    pass
}

/// The shared folder `folder_id` in the sidebar: marked shared, without a
/// write grant, and, once opened, holding its owner's chats read-only, with
/// no row actions or menu (`chat` is one of them).
async fn shared_folder(
    folder_id: &str,
    chat: &str,
    main: AnyWindowHandle,
    dir: &Path,
    cx: &mut AsyncApp,
) -> bool {
    let mut pass = true;
    let chat_list = cx.update(|cx| cx.global::<AppState>().stores.chat_list.clone());
    let listed = wait_until(cx, Duration::from_secs(30), |cx| {
        chat_list.read(cx).list.as_ref().is_some_and(|l| {
            l.folders
                .iter()
                .any(|f| f.id == folder_id && f.shared && !f.can_write)
        })
    })
    .await;
    pass &= ok("the shared folder is listed as shared, read-only", listed);
    let fid = folder_id.to_string();
    chat_list.update(cx, |c, cx| {
        if !c.is_expanded(&fid) {
            c.toggle_folder(&fid, cx);
        }
    });
    let foreign = |cx: &mut App| -> Vec<(String, bool)> {
        chat_list
            .read(cx)
            .merged()
            .map(|l| {
                l.chats
                    .into_iter()
                    .filter(|c| c.folder_id.as_deref() == Some(folder_id))
                    .map(|c| (c.title, c.read_only))
                    .collect()
            })
            .unwrap_or_default()
    };
    let loaded = wait_until(cx, Duration::from_secs(30), |cx| foreign(cx).len() >= 2).await;
    let inside = cx.update(foreign);
    pass &= ok(
        &format!("its owner's chats are inside it, read-only ({inside:?})"),
        loaded && inside.len() == 2 && inside.iter().all(|(_, ro)| *ro),
    );
    let id = chat.to_string();
    in_main(cx, move |mw, _, cx| {
        mw.sidebar.update(cx, |s, cx| s.hover(Some(&id), cx))
    });
    settle(cx, 400).await;
    shoot_main(dir, "sidebar-shared-folder", cx).await;
    let (_, controls) = ax_tree(main, cx).await;
    pass &= ok(
        "the folder reads as shared",
        has(&controls, "TreeItem", ", Shared"),
    );
    pass &= ok(
        "its chats read as read-only",
        has(&controls, "TreeItem", "Day pack checklist, Read-only")
            && has(&controls, "TreeItem", "Trail snack ideas, Read-only"),
    );
    pass &= ok(
        "a hovered read-only chat offers no pin, rename, archive or delete",
        !has(&controls, "Button", "\u{201c}Day pack checklist\u{201d}"),
    );
    let id = chat.to_string();
    let items = in_main(cx, move |mw, _, cx| {
        let sidebar = mw.sidebar.read(cx);
        let chat = sidebar.stores.chat_list.read(cx).find(&id).cloned();
        chat.map(|c| sidebar.menu_items(&c, cx).len())
    })
    .flatten();
    pass &= ok("and no context menu", items == Some(0));
    in_main(cx, |mw, _, cx| {
        mw.sidebar.update(cx, |s, cx| s.hover(None, cx))
    });
    pass
}

async fn local(inputs: &E2eInputs, dir: &Path, cx: &mut AsyncApp) -> bool {
    let Some((url, email, password)) = inputs.owui() else {
        return ok(NO_SERVER, false);
    };
    let model = inputs.model();
    let mut pass = sign_in(&url, &email, &password, cx).await;
    let Some((main, _)) = cx.update(main_window) else {
        return ok("main window", false);
    };
    pass &= ok("models.list answered", wait_models(cx).await);
    settle(cx, 600).await;
    shoot_main(dir, "chat-empty", cx).await;

    // The model picker, from the composer footer (⇧⌘M's path).
    in_pane(cx, |p, window, cx| p.open_model_picker(window, cx));
    settle(cx, 500).await;
    shoot_main(dir, "chat-model-picker", cx).await;
    let (_, controls) = ax_tree(main, cx).await;
    pass &= ok(
        "the composer, its field and the model picker are labelled",
        has(&controls, "MultilineTextInput", "Message")
            && has(&controls, "Button", "Model: ")
            && has(&controls, "ListBoxOption", &model),
    );
    in_pane(cx, |p, window, cx| {
        p.composer.update(cx, |c, cx| c.close_picker(window, cx))
    });

    // 1. Reasoning, streamed, in a new chat.
    send("Answer with reasoning, please", cx).await;
    pass &= ok(
        "a new chat opens on send",
        wait_until(cx, Duration::from_secs(30), |cx| chat_store(cx).is_some()).await,
    );
    if wait_streaming(cx, Duration::from_secs(30)).await {
        shoot_main(dir, "chat-streaming", cx).await;
    }
    pass &= ok(
        "the reasoning answer settles",
        wait_answer(cx, Duration::from_secs(90)).await,
    );
    let kinds = cx.update(kinds_of_last_answer);
    pass &= ok(
        &format!("the answer has reasoning and text blocks ({kinds:?})"),
        kinds.contains(&"Reasoning".to_string()) && kinds.contains(&"Text".to_string()),
    );
    let selected = cx.update(|cx| {
        cx.global::<AppState>()
            .stores
            .navigation
            .read(cx)
            .selected_chat()
            .map(str::to_string)
    });
    let chat_id = cx.update(|cx| chat_store(cx).map(|s| s.read(cx).chat_id().to_string()));
    pass &= ok(
        "navigation.open followed the new chat",
        selected.is_some() && selected == chat_id,
    );
    settle(cx, 400).await;
    shoot_main(dir, "chat-reasoning", cx).await;
    let (articles, controls) = ax_tree(main, cx).await;
    pass &= ok(
        &format!("messages are labelled articles ({} found)", articles.len()),
        articles.len() >= 2
            && articles
                .iter()
                .any(|a| a.starts_with("You: Answer with reasoning"))
            && articles.iter().any(|a| a.contains(&format!("{model}: "))),
    );
    pass &= ok(
        "answer actions are labelled controls",
        has(&controls, "Button", "Copy")
            && has(&controls, "Button", "Regenerate")
            // Rating is in the answer's More menu, as on the phone.
            && has(&controls, "Button", "More"),
    );

    // 2. Code blocks, and an html Preview window.
    send("Show me some code", cx).await;
    pass &= ok(
        "the code answer settles",
        wait_answer(cx, Duration::from_secs(60)).await,
    );
    settle(cx, 500).await;
    shoot_main(dir, "chat-code", cx).await;
    for (lang, code, name) in [
        (
            "html",
            "<h1 style=\"font-family:sans-serif\">Preview works</h1><p>Rendered in a sandbox.</p>",
            "chat-preview-html",
        ),
        (
            "mermaid",
            "graph TD\n  A[Question] --> B{Fake model}\n  B -->|code| C[Blocks]",
            "chat-preview-mermaid",
        ),
    ] {
        let preview = cx.update(|cx| crate::views::chat::preview::open_preview(lang, code, cx));
        pass &= ok(&format!("Preview opens a {lang} window"), preview.is_some());
        if let Some(handle) = preview {
            settle(cx, 3000).await;
            crate::smoke::shoot(handle, dir.join(format!("{name}.png")), cx).await;
            let _ = handle.update(cx, |_, window, _| window.remove_window());
        }
    }
    settle(cx, 500).await;

    // 3. Math.
    send("Some math, please", cx).await;
    pass &= ok(
        "the math answer settles",
        wait_answer(cx, Duration::from_secs(60)).await,
    );
    settle(cx, 500).await;
    shoot_main(dir, "chat-math", cx).await;

    // 4. Stop a slow answer.
    send("A slow answer", cx).await;
    pass &= ok(
        "the slow answer streams",
        wait_streaming(cx, Duration::from_secs(30)).await,
    );
    settle(cx, 1500).await;
    let stop_shown =
        cx.update(|cx| pane(cx).is_some_and(|p| p.read(cx).composer.read(cx).streaming));
    pass &= ok("Stop replaces Send while streaming", stop_shown);
    shoot_main(dir, "chat-stop-shown", cx).await;
    dispatch(&crate::actions::StopGenerating, cx);
    let stopped = wait_until(cx, Duration::from_secs(30), |cx| {
        chat_store(cx).is_some_and(|s| !s.read(cx).is_streaming())
    })
    .await;
    pass &= ok("Esc (stopGenerating) stops the answer", stopped);
    wait_answer(cx, Duration::from_secs(30)).await;
    let text = cx.update(last_answer_text);
    pass &= ok(
        &format!("the stopped answer is partial ({} chars)", text.len()),
        !text.is_empty() && !text.contains("word299"),
    );

    // 5. Regenerate the last answer; the arrows step between versions.
    let regen_target = cx.update(|cx| {
        let s = chat_store(cx)?;
        let s = s.read(cx);
        s.rows().iter().rev().find_map(|r| {
            let i = s.item(*r)?;
            (i.role == crate::stores::chat::Role::Assistant).then_some(i.key)
        })
    });
    if let Some(key) = regen_target.clone() {
        cx.update(|cx| {
            if let Some(s) = chat_store(cx) {
                s.update(cx, |s, cx| s.regenerate(&key, None, cx));
            }
        });
    }
    settle(cx, 1500).await;
    // The slow answer again: stop it a moment in (Stop works mid-regenerate).
    dispatch(&crate::actions::StopGenerating, cx);
    pass &= ok(
        "the regenerated answer settles",
        wait_answer(cx, Duration::from_secs(60)).await,
    );
    let versions = cx.update(|cx| {
        let s = chat_store(cx)?;
        let s = s.read(cx);
        let last = *s.rows().last()?;
        s.item(last)?.version
    });
    pass &= ok(
        &format!("the answer has two versions ({versions:?})"),
        versions.is_some_and(|(_, n)| n >= 2),
    );
    cx.update(|cx| {
        if let Some(s) = chat_store(cx) {
            s.update(cx, |s, cx| {
                if let Some(last) = s.rows().last().copied()
                    && let Some(item) = s.item(last)
                {
                    s.step_version(&item.key, -1, cx);
                }
            });
        }
    });
    settle(cx, 400).await;
    shoot_main(dir, "chat-versions", cx).await;

    // 6. Back to the newest answer (a switch on the server, which the row
    // follows once it lands), then rate it.
    cx.update(|cx| {
        if let Some(s) = chat_store(cx) {
            s.update(cx, |s, cx| {
                if let Some(last) = s.rows().last().copied()
                    && let Some(item) = s.item(last)
                {
                    s.step_version(&item.key, 1, cx);
                }
            });
        }
    });
    let newest = wait_until(cx, Duration::from_secs(30), |cx| {
        chat_store(cx).is_some_and(|s| {
            let s = s.read(cx);
            s.rows()
                .last()
                .and_then(|r| s.item(*r))
                // The newest is the chat's own again (not a version shown in
                // its place while the switch is on its way), and no switch
                // is still on its way.
                .is_some_and(|i| i.stored && i.siblings.last() == Some(&i.key))
                && !s.is_switching()
        })
    })
    .await;
    pass &= ok("the arrow went back to the newest answer", newest);
    cx.update(|cx| {
        if let Some(s) = chat_store(cx) {
            s.update(cx, |s, cx| {
                if let Some(last) = s.rows().last().copied()
                    && let Some(item) = s.item(last)
                {
                    s.rate(&item.key, 1, cx);
                }
            });
        }
    });
    let rated = wait_until(cx, Duration::from_secs(20), |cx| {
        chat_store(cx).is_some_and(|s| {
            let s = s.read(cx);
            s.rows()
                .last()
                .and_then(|r| s.item(*r))
                .is_some_and(|i| i.rating == Some(1))
        })
    })
    .await;
    pass &= ok("a thumbs up shows (turns.rate)", rated);

    // 7. Edit the first question in place.
    let first_question = cx.update(|cx| {
        let s = chat_store(cx)?;
        let s = s.read(cx);
        s.rows().iter().find_map(|r| {
            let i = s.item(*r)?;
            (i.role == crate::stores::chat::Role::User).then_some(i.key)
        })
    });
    if let Some(key) = first_question {
        cx.update(|cx| {
            if let Some(s) = chat_store(cx) {
                s.update(cx, |s, cx| s.edit(&key, "Show me code instead".into(), cx));
            }
        });
        pass &= ok(
            "the edited branch settles",
            wait_answer(cx, Duration::from_secs(60)).await,
        );
        let rows = cx.update(|cx| chat_store(cx).map(|s| s.read(cx).rows().len()).unwrap_or(0));
        pass &= ok(
            &format!("the edit replaced the old branch ({rows} rows)"),
            rows == 2,
        );
        settle(cx, 400).await;
        shoot_main(dir, "chat-edited", cx).await;
    }

    // 8. An attachment, uploaded with progress, then sent.
    let file = dir.join("attachment-notes.md");
    std::fs::write(
        &file,
        "# Synthetic notes\n\nA day on the test planet lasts 30 hours.\n",
    )
    .ok();
    in_pane(cx, |p, _, cx| {
        let paths = vec![file.clone()];
        p.composer_store.update(cx, |c, cx| c.add_paths(&paths, cx));
    });
    let uploaded = wait_until(cx, Duration::from_secs(30), |cx| {
        pane(cx).is_some_and(|p| {
            let c = p.read(cx).composer_store.read(cx);
            c.has_attachments() && !c.uploading()
        })
    })
    .await;
    pass &= ok("the attachment uploads through /upload", uploaded);
    shoot_main(dir, "chat-attachment", cx).await;
    send("What does the attached file say?", cx).await;
    pass &= ok(
        "the attachment turn settles",
        wait_answer(cx, Duration::from_secs(60)).await,
    );
    let has_file = cx.update(|cx| {
        let Some(s) = chat_store(cx) else {
            return false;
        };
        let s = s.read(cx);
        s.rows()
            .iter()
            .filter_map(|r| s.item(*r))
            .any(|i| i.role == crate::stores::chat::Role::User && !i.files.is_empty())
    });
    pass &= ok("the sent message carries the file", has_file);
    shoot_main(dir, "chat-attachment-sent", cx).await;
    // Reloaded from the stored copy, the file keeps the name it was sent
    // with (it used to come back as "file").
    let sent_names = |cx: &mut App| -> Vec<String> {
        let Some(s) = chat_store(cx) else {
            return vec![];
        };
        let s = s.read(cx);
        s.messages()
            .iter()
            .filter(|m| m.role == "user")
            .flat_map(|m| m.files.iter().map(|f| f.name.clone()))
            .collect()
    };
    let mut named = false;
    for _ in 0..8 {
        settle(cx, 1500).await;
        cx.update(|cx| {
            if let Some(s) = chat_store(cx) {
                s.update(cx, |s, cx| s.fetch(cx));
            }
        });
        settle(cx, 800).await;
        if cx
            .update(sent_names)
            .iter()
            .any(|n| n == "attachment-notes.md")
        {
            named = true;
            break;
        }
    }
    let names = cx.update(sent_names);
    pass &= ok(
        &format!("after a reload the file keeps its name ({names:?})"),
        named,
    );

    // 9. A `/` prompt with a select field.
    in_pane(cx, |p, window, cx| {
        p.composer
            .update(cx, |c, cx| c.set_text("/bri", window, cx))
    });
    let listed = wait_until(cx, Duration::from_secs(15), |cx| {
        pane(cx).is_some_and(|p| {
            p.read(cx)
                .composer_store
                .read(cx)
                .prompts
                .as_ref()
                .is_some_and(|l| l.iter().any(|p| p.command.contains("brief")))
        })
    })
    .await;
    pass &= ok("prompts.list answered", listed);
    settle(cx, 300).await;
    shoot_main(dir, "chat-prompt-menu", cx).await;
    in_pane(cx, |p, window, cx| {
        p.composer
            .update(cx, |c, cx| c.choose_menu_item(0, window, cx))
    });
    settle(cx, 1500).await;
    shoot_main(dir, "chat-prompt-form", cx).await;
    in_pane(cx, |p, window, cx| {
        p.composer.update(cx, |c, cx| {
            c.fill_and_submit_form(&[("topic", "tides")], 1, window, cx)
        })
    });
    let inserted = wait_until(cx, Duration::from_secs(15), |cx| {
        pane(cx).is_some_and(|p| {
            let t = p.read(cx).composer.read(cx).text(cx);
            t.contains("casual") && t.contains("tides")
        })
    })
    .await;
    pass &= ok("the filled-in prompt lands in the composer", inserted);
    in_pane(cx, |p, window, cx| {
        p.composer.update(cx, |c, cx| c.set_text("", window, cx))
    });

    // 10. A tool call that needs approval: the card docks above the composer.
    // Open WebUI asks in the chat (its prompt card); an approval put to the
    // app over `ui.request` docks the approvals card. ⌥⌘↩ answers either.
    send("What time is it? Please approve", cx).await;
    let card = wait_until(cx, Duration::from_secs(20), |cx| {
        main_window(cx).is_some_and(|(_, v)| {
            v.read(cx).approvals.read(cx).has_request(cx)
                || v.read(cx)
                    .chat_pane
                    .read(cx)
                    .prompt_card
                    .read(cx)
                    .has_prompt(cx)
        })
    })
    .await;
    if card {
        ok("the server's tool approval arrives as a docked card", true);
        settle(cx, 500).await;
        shoot_main(dir, "chat-approval", cx).await;
        dispatch(&crate::actions::AllowRequest, cx);
    } else {
        // This server ran the tool without asking: dock a synthetic card
        // (answered through `ui.respond`, which refuses the made-up id).
        println!("SMOKE e2e note: the server did not ask for approval; docking a synthetic card");
        let mut tool = request(
            "e2e-chat-tool",
            conduit_protocol::UiRequestKind::ToolApproval,
            &[
                ("title", "get_current_timestamp"),
                ("message", "The model wants to read the clock."),
            ],
        );
        tool.message_code = "server.prompt".into();
        cx.update(|cx| {
            let u = cx.global::<AppState>().stores.ui_requests.clone();
            u.update(cx, |u, cx| u.on_request(tool, cx));
        });
        settle(cx, 600).await;
        let docked = cx.update(|cx| {
            main_window(cx).is_some_and(|(_, v)| v.read(cx).approvals.read(cx).has_request(cx))
        });
        pass &= ok("an approval card docks above the composer", docked);
        shoot_main(dir, "chat-approval", cx).await;
        let (_, controls) = ax_tree(main, cx).await;
        pass &= ok(
            "the docked card's Allow and Deny are labelled",
            has(&controls, "Button", "Allow") && has(&controls, "Button", "Deny"),
        );
        dispatch(&crate::actions::AllowRequest, cx);
        let gone = wait_until(cx, Duration::from_secs(10), |cx| {
            main_window(cx).is_some_and(|(_, v)| !v.read(cx).approvals.read(cx).has_request(cx))
        })
        .await;
        pass &= ok("⌥⌘↩ answers the docked card", gone);
    }
    pass &= ok(
        "the approved tool turn settles",
        wait_answer(cx, Duration::from_secs(60)).await,
    );
    let kinds = cx.update(kinds_of_last_answer);
    pass &= ok(
        &format!("the answer shows the tool call ({kinds:?})"),
        kinds.contains(&"ToolCalls".to_string()),
    );
    settle(cx, 400).await;
    shoot_main(dir, "chat-tool", cx).await;

    // 11. A long answer.
    send("A long answer, please", cx).await;
    if wait_streaming(cx, Duration::from_secs(30)).await {
        settle(cx, 600).await;
        shoot_main(dir, "chat-long-streaming", cx).await;
    }
    pass &= ok(
        "the long answer settles",
        wait_answer(cx, Duration::from_secs(120)).await,
    );
    let len = cx.update(last_answer_text).len();
    pass &= ok(
        &format!("the long answer is about 32K ({len})"),
        len > 30_000,
    );
    settle(cx, 1500).await;
    shoot_main(dir, "chat-long", cx).await;

    // 12. Copy shortcuts.
    dispatch(&crate::actions::CopyLastResponse, cx);
    settle(cx, 400).await;
    let copied = cx.update(|cx| cx.read_from_clipboard().and_then(|c| c.text()));
    pass &= ok(
        "⇧⌘C copies the last reply",
        copied.as_deref().is_some_and(|c| c.len() > 30_000),
    );

    // 13. Find in Chat (⌘F): the questions asked "please" more than once.
    dispatch(&crate::actions::FindInChat, cx);
    settle(cx, 300).await;
    in_main(cx, |mw, window, cx| {
        mw.chat_pane
            .update(cx, |p, cx| p.type_find("please", window, cx))
    });
    let find_status = |cx: &mut App| {
        pane(cx).and_then(|p| {
            p.read(cx)
                .chat
                .as_ref()
                .and_then(|c| c.transcript.read(cx).find_status())
        })
    };
    let found = wait_until(cx, Duration::from_secs(10), |cx| {
        find_status(cx).is_some_and(|(current, n)| current == Some(1) && n >= 2)
    })
    .await;
    pass &= ok(
        &format!("⌘F finds the text ({:?})", cx.update(find_status)),
        found,
    );
    let (_, controls) = match cx.update(main_window) {
        Some((handle, _)) => ax_tree(handle, cx).await,
        None => (vec![], vec![]),
    };
    pass &= ok(
        "the find bar is a search region",
        controls.iter().any(|c| c == "Search:Find in Chat"),
    );
    dispatch(&crate::actions::FindNext, cx);
    settle(cx, 300).await;
    pass &= ok(
        "⌘G moves to the next match",
        cx.update(find_status)
            .is_some_and(|(current, _)| current == Some(2)),
    );
    shoot_main(dir, "chat-find", cx).await;
    // Esc closes it (the field's Esc and Stop's both reach the bar first).
    dispatch(&crate::actions::StopGenerating, cx);
    settle(cx, 300).await;
    pass &= ok(
        "Esc closes the find bar",
        cx.update(|cx| pane(cx).is_some_and(|p| !p.read(cx).find_open())),
    );

    // 14. View › Zoom In, Zoom Out and Actual Size step the text size.
    let text_size = |cx: &mut App| {
        cx.global::<crate::AppState>()
            .settings
            .read(cx)
            .prefs
            .appearance
            .clone()
    };
    let before = cx.update(text_size).effective_text_size();
    dispatch(&crate::actions::ZoomIn, cx);
    settle(cx, 200).await;
    let bigger = cx.update(text_size).effective_text_size();
    dispatch(&crate::actions::ZoomOut, cx);
    dispatch(&crate::actions::ZoomOut, cx);
    settle(cx, 200).await;
    let smaller = cx.update(text_size).effective_text_size();
    dispatch(&crate::actions::ActualSize, cx);
    settle(cx, 200).await;
    let actual = cx.update(text_size);
    pass &= ok(
        &format!("⌘+ / ⌘− / ⌘0 step the text size ({before} → {bigger} → {smaller} → actual)"),
        bigger == before + 1. && smaller == before - 1. && actual.text_size.is_none(),
    );
    pass
}

async fn direct_chat(inputs: &E2eInputs, dir: &Path, cx: &mut AsyncApp) -> bool {
    let Some(base) = inputs.get("FAKE_OPENAI_URL") else {
        return ok(NO_SERVER, false);
    };
    let mut pass = fresh_profile(cx).await;
    pass &= ok("the setup window opened", wait_setup(cx).await.is_some());
    in_setup(cx, |sw, window, cx| {
        sw.onboarding.update(cx, |o, cx| {
            o.selected = conduit_components::views::model::Backend::Direct;
            o.choose(window, cx)
        })
    });
    settle(cx, 600).await;
    in_setup(cx, move |sw, window, cx| {
        let Some(direct) = sw.onboarding.read(cx).direct_view() else {
            return;
        };
        let (name, url, key) = {
            let d = direct.read(cx);
            (d.name.clone(), d.base_url.clone(), d.api_key.clone())
        };
        set_text(&name, "Local test provider", window, cx);
        set_text(&url, &base, window, cx);
        set_text(&key, "sk-test", window, cx);
        direct.update(cx, |d, cx| d.test(window, cx));
    });
    let tested = wait_until(cx, Duration::from_secs(30), |cx| {
        let Some((_, view)) = setup_window(cx) else {
            return false;
        };
        let Some(d) = view.read(cx).onboarding.read(cx).direct_view() else {
            return false;
        };
        matches!(&d.read(cx).note, Some(crate::views::direct::DirectNote::Tested(r)) if r.reachable)
    })
    .await;
    pass &= ok("direct.test reaches the fake provider", tested);
    in_setup(cx, |sw, window, cx| {
        if let Some(d) = sw.onboarding.read(cx).direct_view() {
            d.update(cx, |d, cx| d.save(window, cx));
        }
    });
    pass &= wait_route(cx, Route::Main, Duration::from_secs(60)).await;
    pass &= wait_main(cx).await.is_some();
    pass &= ok("Direct models listed", wait_models(cx).await);
    settle(cx, 600).await;
    shoot_main(dir, "direct-empty", cx).await;
    send("Answer with reasoning, please", cx).await;
    if wait_streaming(cx, Duration::from_secs(30)).await {
        shoot_main(dir, "direct-streaming", cx).await;
    }
    pass &= ok(
        "the direct answer settles",
        wait_answer(cx, Duration::from_secs(90)).await,
    );
    let kinds = cx.update(kinds_of_last_answer);
    pass &= ok(
        &format!("the direct answer keeps its reasoning ({kinds:?})"),
        kinds.contains(&"Reasoning".to_string()) && kinds.contains(&"Text".to_string()),
    );
    settle(cx, 400).await;
    shoot_main(dir, "direct-reasoning", cx).await;
    send("Some math, please", cx).await;
    pass &= ok(
        "the second direct answer settles",
        wait_answer(cx, Duration::from_secs(60)).await,
    );
    shoot_main(dir, "direct-math", cx).await;

    // A tool call: Direct's on-device web tools come with web search; the
    // fake model asks `web_fetch` for a page that was not in the message,
    // which is refused without any request.
    let offered = cx.update(|cx| {
        pane(cx).is_some_and(|p| p.read(cx).composer_store.read(cx).options.web_search)
    });
    if offered {
        in_pane(cx, |p, _, cx| {
            p.composer_store.update(cx, |c, cx| c.toggle_web_search(cx))
        });
        send("Use a tool, please", cx).await;
        pass &= ok(
            "the direct tool turn settles",
            wait_answer(cx, Duration::from_secs(60)).await,
        );
        let kinds = cx.update(kinds_of_last_answer);
        pass &= ok(
            &format!("the direct answer shows the tool call ({kinds:?})"),
            kinds.contains(&"ToolCalls".to_string()),
        );
        settle(cx, 400).await;
        shoot_main(dir, "direct-tool", cx).await;
    } else {
        pass &= ok(
            "composer.options offers web search for the direct model",
            false,
        );
    }
    #[cfg(target_os = "macos")]
    {
        pass &= menu_greying(cx).await;
    }
    pass
}

/// View's zoom items and the Chat menu's items that grey out, as AppKit
/// shows them (its validation asks GPUI, which never sees an item's
/// `disabled`): each as its menu value says, and off where it would do
/// nothing. Read outside any update: AppKit's validation calls back into
/// GPUI.
#[cfg(target_os = "macos")]
async fn menu_greying(cx: &mut AsyncApp) -> bool {
    use crate::prefs::TEXT_SIZE_MAX;
    let size = |size: Option<f32>, cx: &mut AsyncApp| {
        cx.update(|cx| {
            let settings = cx.global::<AppState>().settings.clone();
            settings.update(cx, |s, cx| s.set_appearance(|a| a.text_size = size, cx));
        })
    };
    let titles = cx.update(|cx| {
        let l = crate::l10n::ActiveL10n::l10n(cx).clone();
        (
            l.desktop_menu_view(),
            l.desktop_menu_zoom_in(),
            l.desktop_menu_chat(),
            l.desktop_read_aloud(),
        )
    });
    let (view, zoom_in, chat, read_aloud) = titles;

    // A chat open with answers, nothing read, the text at its actual size.
    size(None, cx);
    let open = menus_out_of_step(cx).await;
    let s = cx.update(|cx| crate::menus::menu_state(cx));
    let mut pass = ok(
        &format!("with a chat open, the items that grey out are as their menu says ({open:?})"),
        open.is_empty(),
    );
    pass &= ok(
        "… Read Aloud and Ask Conduit on, Actual Size and Stop Speaking off",
        s.read_aloud && s.ask_conduit && !s.zoom.can_reset && !s.speaking,
    );
    // The largest text size: Zoom In would do nothing.
    size(Some(TEXT_SIZE_MAX), cx);
    let largest = menus_out_of_step(cx).await;
    let on = crate::shell::macos::menu_item_enabled(&view, &zoom_in);
    pass &= ok(
        &format!("at the largest text size, View › Zoom In is off ({on:?}; {largest:?})"),
        on == Some(false) && largest.is_empty(),
    );
    size(None, cx);
    // A new chat: nothing to read or ask about.
    in_main(cx, |mw, _, cx| {
        mw.stores
            .navigation
            .update(cx, |n, cx| n.new_chat(false, cx))
    });
    settle(cx, 400).await;
    let new = menus_out_of_step(cx).await;
    let on = crate::shell::macos::menu_item_enabled(&chat, &read_aloud);
    pass &= ok(
        &format!("in a new chat, Chat › Read Aloud is off ({on:?}; {new:?})"),
        on == Some(false) && new.is_empty(),
    );
    pass
}

/// The items that grey out whose AppKit state differs from their menu
/// value (`menus::menu_state`), with the main window in front.
#[cfg(target_os = "macos")]
async fn menus_out_of_step(cx: &mut AsyncApp) -> Vec<String> {
    in_main(cx, |_, window, _| window.activate_window());
    cx.update(crate::menus::refresh_menus);
    settle(cx, 300).await;
    let items = cx.update(|cx| {
        let l = crate::l10n::ActiveL10n::l10n(cx).clone();
        let s = crate::menus::menu_state(cx);
        let (view, chat) = (l.desktop_menu_view(), l.desktop_menu_chat());
        let call = if s.in_call {
            l.desktop_end_voice_call()
        } else {
            l.desktop_start_voice_call()
        };
        vec![
            (view.clone(), l.desktop_menu_actual_size(), s.zoom.can_reset),
            (view.clone(), l.desktop_menu_zoom_in(), s.zoom.can_zoom_in),
            (view, l.desktop_menu_zoom_out(), s.zoom.can_zoom_out),
            (chat.clone(), l.ask_conduit_action(), s.ask_conduit),
            (chat.clone(), l.desktop_read_aloud(), s.read_aloud),
            (chat.clone(), l.desktop_stop_speaking(), s.speaking),
            (chat.clone(), call, s.in_call || s.call_ready),
            (
                chat.clone(),
                l.desktop_chat_settings_menu(),
                s.chat_settings,
            ),
            (chat, l.desktop_tool_settings_menu(), s.tool_settings),
        ]
    });
    items
        .into_iter()
        .filter_map(|(menu, item, want)| {
            let on = crate::shell::macos::menu_item_enabled(&menu, &item);
            (on != Some(want)).then(|| format!("{item}: AppKit {on:?}, menu {want}"))
        })
        .collect()
}

async fn chat_ids(cx: &mut AsyncApp) -> Option<BTreeSet<String>> {
    let call = cx.update(|cx| {
        cx.global::<AppState>()
            .connection
            .read(cx)
            .rpc()
            .call::<methods::ChatsList>(&NoParams)
    });
    call.await
        .ok()
        .map(|l| l.chats.into_iter().map(|c| c.id).collect())
}

async fn smoke(inputs: &E2eInputs, dir: &Path, cx: &mut AsyncApp) -> bool {
    let Some((url, email, password)) = inputs.owui() else {
        return ok(NO_SERVER, false);
    };
    let mut pass = sign_in(&url, &email, &password, cx).await;
    pass &= ok("models listed", wait_models(cx).await);
    // The first full sync lands over a few seconds; wait for the list to
    // stop changing before taking the "before" picture.
    let mut before = None;
    for _ in 0..12 {
        settle(cx, 2500).await;
        let now = chat_ids(cx).await;
        if now.is_some() && now == before {
            break;
        }
        before = now;
    }
    // Without a list to compare with, the clean-up below could take chats
    // this pass did not make: stop here.
    let Some(before) = before else {
        return ok("the chat list before the pass", false);
    };
    println!("SMOKE e2e chats before: {}", before.len());
    // The model for each message is chosen with `@` (this message only), so
    // the account's saved default is left alone.
    let want = inputs.model();
    let model = cx.update(|cx| {
        pane(cx).and_then(|p| {
            p.read(cx)
                .composer_store
                .read(cx)
                .models
                .as_ref()
                .and_then(|l| l.models.iter().find(|m| m.id.contains(&want)).cloned())
        })
    });
    pass &= ok("the test model is offered", model.is_some());
    let mention = move |cx: &mut AsyncApp| {
        let model = model.clone();
        in_pane(cx, move |p, _, cx| {
            p.composer_store
                .update(cx, |c, cx| c.set_mention(model, cx))
        });
    };

    let mut made = BTreeSet::new();
    mention(cx);
    send("Reply with one short sentence about the sea.", cx).await;
    pass &= ok(
        "the first turn settles",
        wait_answer(cx, Duration::from_secs(120)).await,
    );
    if let Some(id) = cx.update(|cx| chat_store(cx).map(|s| s.read(cx).chat_id().to_string())) {
        made.insert(id);
    }
    shoot_main(dir, "smoke-turn-1", cx).await;
    mention(cx);
    send("And one about mountains.", cx).await;
    pass &= ok(
        "the second turn settles",
        wait_answer(cx, Duration::from_secs(120)).await,
    );
    shoot_main(dir, "smoke-turn-2", cx).await;
    if let Some(id) = cx.update(|cx| chat_store(cx).map(|s| s.read(cx).chat_id().to_string())) {
        made.insert(id);
    }

    // Clean up: delete what this pass made, then compare.
    cx.update(|cx| {
        let nav = cx.global::<AppState>().stores.navigation.clone();
        nav.update(cx, |n, cx| n.new_chat(false, cx));
    });
    settle(cx, 1500).await;
    let mut after = chat_ids(cx).await.unwrap_or_default();
    let mut to_delete: BTreeSet<String> = after.difference(&before).cloned().collect();
    to_delete.extend(made);
    for id in &to_delete {
        let call = cx.update(|cx| {
            cx.global::<AppState>()
                .connection
                .read(cx)
                .rpc()
                .call::<methods::ChatsDelete>(&ChatRef { id: id.clone() })
        });
        let deleted = call.await.is_ok();
        println!("SMOKE e2e deleted a chat this pass made: {deleted}");
    }
    settle(cx, 3000).await;
    if let Some(now) = chat_ids(cx).await {
        after = now;
    }
    pass &= ok(
        &format!(
            "the account ends with the chats it started with ({} before, {} after)",
            before.len(),
            after.len()
        ),
        after == before,
    );
    pass
}
