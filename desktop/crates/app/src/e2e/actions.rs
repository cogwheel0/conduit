//! `--e2e actions`: message and chat actions on the local Open WebUI
//! and its fake models (`fake-model`, and `fake-model-b`, which answers
//! "B: …"):
//!
//! * an answer's Info popover (the usage the fake model streams);
//! * Regenerate With another model, then the version arrows switching the
//!   chat's branch on the server, kept after the chat is opened again; the
//!   version list and the Branches sheet (choosing a branch there);
//! * Branch in New Chat (Open WebUI's fork), opened at once;
//! * Delete on a question (its answer goes too);
//! * Compare Models with both answers drawn as columns, Continue from Here
//!   on the other one, then Merge Responses;
//! * Export as a JSON backup and a Markdown transcript, into a throwaway
//!   folder;
//! * Share Chat: link; Who Has Access in the access sheet (a person and
//!   the seeded group, then Anyone with the Link), back to Share Chat;
//!   update, delete;
//! * Generate Title, Mark as Unread (the sidebar's dot, gone on opening),
//!   and Save Chat for a temporary chat.
//!
//! Every chat this pass makes is deleted at the end.

use std::path::Path;
use std::time::Duration;

use conduit_protocol::{
    AccessAudience, AccessEdit, AccessRef, AccessResourceKind, AppSettingsPatch, ChatExportFormat,
    ChatRef, ShareAudience, methods,
};
use gpui_kit::{AsyncApp, Entity, point, px};

use super::chat::{chat_store, in_pane, pane, send, sign_in, wait_answer, wait_models};
use super::*;
use crate::stores::chat::{ChatStore, Role as MessageRole, RowItem};
use crate::views::chat::actions::{RowCommand, RowContext};

/// The second fake model, as the seed names it.
const MODEL_B: &str = "fake-model-b";

fn navigation(cx: &mut App) -> Entity<crate::stores::navigation::NavigationStore> {
    cx.global::<AppState>().stores.navigation.clone()
}

fn chat_list(cx: &mut App) -> Entity<crate::stores::chat_list::ChatListStore> {
    cx.global::<AppState>().stores.chat_list.clone()
}

async fn open_chat(id: &str, cx: &mut AsyncApp) -> bool {
    let id = id.to_string();
    let nav = cx.update(navigation);
    let want = id.clone();
    nav.update(cx, |n, cx| n.open(id, cx));
    wait_until(cx, Duration::from_secs(30), move |cx| {
        chat_store(cx).is_some_and(|s| {
            let s = s.read(cx);
            s.chat_id() == want && s.detail.is_some() && !s.loading
        })
    })
    .await
}

async fn new_chat(temporary: bool, cx: &mut AsyncApp) {
    let nav = cx.update(navigation);
    nav.update(cx, |n, cx| n.new_chat(temporary, cx));
    settle(cx, 400).await;
}

/// The open chat's id.
fn open_id(cx: &mut App) -> String {
    chat_store(cx)
        .map(|s| s.read(cx).chat_id().to_string())
        .unwrap_or_default()
}

/// The open chat's rows, as drawn.
fn items(cx: &mut App) -> Vec<RowItem> {
    let Some(store) = chat_store(cx) else {
        return vec![];
    };
    let s = store.read(cx);
    s.rows().iter().filter_map(|r| s.item(*r)).collect()
}

fn last_answer(cx: &mut App) -> Option<RowItem> {
    items(cx)
        .into_iter()
        .rev()
        .find(|i| i.role == MessageRole::Assistant)
}

fn last_question(cx: &mut App) -> Option<RowItem> {
    items(cx)
        .into_iter()
        .rev()
        .find(|i| i.role == MessageRole::User)
}

/// The context a row's action runs in, as its button gives it.
fn context(item: &RowItem, cx: &mut App) -> Option<RowContext> {
    let store: Entity<ChatStore> = chat_store(cx)?;
    let pane = pane(cx)?;
    let target = item
        .version
        .and_then(|(at, _)| item.siblings.get(at.wrapping_sub(1)).cloned())
        .unwrap_or_else(|| item.key.clone());
    Some(RowContext {
        store: store.downgrade(),
        pane: Some(pane.downgrade()),
        key: item.key.clone(),
        target,
        mergeable: item.mergeable.clone(),
        position: point(px(400.), px(300.)),
    })
}

/// Runs `command` on `item` in the main window, as its button does.
async fn act(item: &RowItem, command: RowCommand, cx: &mut AsyncApp) -> bool {
    let Some(ctx) = cx.update(|cx| context(item, cx)) else {
        return false;
    };
    in_main(cx, move |_, window, cx| {
        crate::views::chat::actions::run(ctx, command, window, cx)
    })
    .is_some()
}

fn transcript_popover(cx: &mut App) -> Option<crate::views::chat::transcript::RowPopoverKind> {
    let pane = pane(cx)?;
    let t = pane.read(cx).chat.as_ref()?.transcript.clone();
    t.read(cx).row_popover_open().map(|(k, _)| k)
}

fn close_popover(cx: &mut App) {
    if let Some(pane) = pane(cx)
        && let Some(chat) = &pane.read(cx).chat
    {
        let t = chat.transcript.clone();
        t.update(cx, |t, cx| t.close_row_popover(cx));
    }
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
    let model = inputs.model();
    in_pane(cx, move |p, _, cx| {
        p.composer_store
            .update(cx, |c, cx| c.select_model(&model, cx))
    });
    let two = wait_until(cx, Duration::from_secs(20), |cx| {
        pane(cx).is_some_and(|p| {
            p.read(cx)
                .composer_store
                .read(cx)
                .models
                .as_ref()
                .is_some_and(|m| m.models.iter().any(|m| m.id == MODEL_B))
        })
    })
    .await;
    pass &= ok("the second fake model is offered", two);
    // Merge Responses and Compare Models are Advanced's.
    let settings = cx.update(|cx| cx.global::<AppState>().stores.app_settings.clone());
    settings.update(cx, |s, cx| {
        s.set(
            AppSettingsPatch {
                advanced_features_enabled: Some(true),
                ..Default::default()
            },
            cx,
        )
    });
    let advanced = wait_until(cx, Duration::from_secs(10), |cx| {
        cx.global::<AppState>()
            .stores
            .app_settings
            .read(cx)
            .settings()
            .advanced_features_enabled
    })
    .await;
    pass &= ok("Advanced is on", advanced);
    let rpc = cx.update(|cx| cx.global::<AppState>().stores.connection.read(cx).rpc());
    let mut made: Vec<String> = vec![];

    // ── A chat to work in ──────────────────────────────────────────────
    new_chat(false, cx).await;
    send("Reply with exactly the word: alpha", cx).await;
    pass &= ok(
        "a new chat answered",
        wait_answer(cx, Duration::from_secs(60)).await,
    );
    let stored = wait_until(cx, Duration::from_secs(30), |cx| {
        !open_id(cx).starts_with("local:")
            && chat_store(cx).is_some_and(|s| s.read(cx).abilities().branch)
    })
    .await;
    pass &= ok("the chat is stored and can branch", stored);
    let chat_id = cx.update(open_id);
    made.push(chat_id.clone());

    pass &= usage(main, dir, cx).await;
    pass &= versions(&chat_id, main, dir, cx).await;
    pass &= fork(&chat_id, &mut made, cx).await;
    pass &= delete(&chat_id, cx).await;
    pass &= compare(&chat_id, main, dir, cx).await;
    pass &= export(&chat_id, dir, cx).await;
    pass &= share(&chat_id, inputs, &rpc, dir, cx).await;
    pass &= title_and_unread(&chat_id, main, dir, cx).await;
    pass &= save_temporary(&mut made, main, dir, cx).await;

    // ── Clean up ───────────────────────────────────────────────────────
    new_chat(false, cx).await;
    for id in made {
        let gone = rpc
            .call::<methods::ChatsDelete>(&ChatRef { id })
            .await
            .is_ok();
        pass &= ok("a chat this pass made is deleted", gone);
    }
    pass
}

/// Info: the fake model's usage in a popover from the answer.
async fn usage(main: AnyWindowHandle, dir: &Path, cx: &mut AsyncApp) -> bool {
    let reported = wait_until(cx, Duration::from_secs(20), |cx| {
        last_answer(cx).is_some_and(|i| i.usage.is_some())
    })
    .await;
    let mut pass = ok("the answer carries its usage", reported);
    let Some(answer) = cx.update(last_answer) else {
        return ok("an answer to look at", false);
    };
    pass &= act(&answer, RowCommand::Usage, cx).await;
    let open = wait_until(cx, Duration::from_secs(5), |cx| {
        transcript_popover(cx) == Some(crate::views::chat::transcript::RowPopoverKind::Usage)
    })
    .await;
    pass &= ok("Info opens the usage popover", open);
    settle(cx, 400).await;
    shoot_both_modes(main, dir, "actions-usage", cx).await;
    let controls = ax(main, "actions-usage", dir, cx).await;
    pass &= ok(
        "the answer's actions are labelled (Copy, Regenerate, More)",
        has(&controls, "Button", "Copy") && has(&controls, "Button", "More"),
    );
    cx.update(close_popover);
    pass
}

/// Regenerate With the second model; the arrows switch the chat's branch,
/// which a reopened chat keeps; the version list; the Branches sheet.
async fn versions(chat_id: &str, main: AnyWindowHandle, dir: &Path, cx: &mut AsyncApp) -> bool {
    let Some(answer) = cx.update(last_answer) else {
        return ok("an answer to regenerate", false);
    };
    let mut pass = act(&answer, RowCommand::Regenerate(Some(MODEL_B.into())), cx).await;
    let regenerated = wait_until(cx, Duration::from_secs(60), |cx| {
        last_answer(cx)
            .is_some_and(|i| !i.streaming && i.text.starts_with("B:") && i.version == Some((2, 2)))
            && chat_store(cx).is_some_and(|s| s.read(cx).live.is_none())
    })
    .await;
    pass &= ok(
        "Regenerate With answered with the other model (2 / 2)",
        regenerated,
    );
    settle(cx, 800).await;
    // ← : the first answer becomes the chat's, on the server.
    let key = cx
        .update(|cx| last_answer(cx).map(|i| i.key))
        .unwrap_or_default();
    let store = cx.update(chat_store);
    if let Some(store) = &store {
        store.update(cx, |s, cx| s.step_version(&key, -1, cx));
    }
    let back = wait_until(cx, Duration::from_secs(20), |cx| {
        last_answer(cx)
            .is_some_and(|i| i.version == Some((1, 2)) && i.text.trim() == "alpha" && i.stored)
            && chat_store(cx).is_some_and(|s| {
                s.read(cx)
                    .messages()
                    .iter()
                    .any(|m| m.content.trim() == "alpha")
            })
    })
    .await;
    pass &= ok("the arrow made the first answer current (1 / 2)", back);
    // Opened again, from the server's copy: still the first answer.
    new_chat(false, cx).await;
    pass &= ok("the chat opens again", open_chat(chat_id, cx).await);
    let kept = wait_until(cx, Duration::from_secs(20), |cx| {
        last_answer(cx).is_some_and(|i| i.version == Some((1, 2)) && i.text.trim() == "alpha")
    })
    .await;
    pass &= ok("the version chosen is kept after reopening", kept);
    // The version list.
    if let Some(answer) = cx.update(last_answer) {
        pass &= act(&answer, RowCommand::Versions, cx).await;
    }
    let listed = wait_until(cx, Duration::from_secs(5), |cx| {
        transcript_popover(cx) == Some(crate::views::chat::transcript::RowPopoverKind::Versions)
    })
    .await;
    pass &= ok("the n / N label lists the versions", listed);
    settle(cx, 400).await;
    shoot_both_modes(main, dir, "actions-versions", cx).await;
    cx.update(close_popover);
    // The Branches sheet: every message; choosing the other answer there.
    let sheet = in_pane(cx, |p, window, cx| p.show_branches(window, cx)).flatten();
    let Some(sheet) = sheet else {
        return ok("the Branches sheet opens", false);
    };
    let loaded = wait_until(cx, Duration::from_secs(20), |cx| {
        sheet.read(cx).lines().is_some_and(|l| l.len() >= 3)
    })
    .await;
    pass &= ok(
        "the Branches sheet lists the question and both answers",
        loaded,
    );
    settle(cx, 600).await;
    if let Some(handle) = cx.update(|cx| crate::views::chat::sheets::handle(cx)) {
        shoot_both_modes(handle, dir, "actions-branches", cx).await;
        let controls = ax(handle, "actions-branches", dir, cx).await;
        pass &= ok(
            "the branches are labelled tree items",
            has(&controls, "TreeItem", "alpha"),
        );
    }
    let other = cx.update(|cx| {
        sheet.read(cx).lines().and_then(|l| {
            l.iter()
                .find(|l| !l.user && l.preview.starts_with("B:"))
                .map(|l| l.id.clone())
        })
    });
    match other {
        Some(id) => sheet.update(cx, |s, cx| s.choose(&id, cx)),
        None => pass &= ok("the other answer is in the Branches sheet", false),
    }
    let chosen = wait_until(cx, Duration::from_secs(20), |cx| {
        !crate::views::chat::sheets::is_open(cx)
            && last_answer(cx)
                .is_some_and(|i| i.text.starts_with("B:") && i.version == Some((2, 2)))
    })
    .await;
    pass &= ok("choosing a branch there makes it the chat's", chosen);
    pass
}

/// Branch in New Chat: Open WebUI's fork, opened at once.
async fn fork(chat_id: &str, made: &mut Vec<String>, cx: &mut AsyncApp) -> bool {
    let Some(answer) = cx.update(last_answer) else {
        return ok("an answer to branch from", false);
    };
    let mut pass = ok(
        "Branch in New Chat is offered",
        cx.update(|cx| chat_store(cx).is_some_and(|s| s.read(cx).abilities().fork)),
    );
    pass &= act(&answer, RowCommand::Fork, cx).await;
    let source = chat_id.to_string();
    let opened = wait_until(cx, Duration::from_secs(30), move |cx| {
        let id = open_id(cx);
        !id.is_empty()
            && id != source
            && chat_store(cx).is_some_and(|s| {
                let s = s.read(cx);
                s.detail.is_some() && s.messages().iter().any(|m| m.role == "user")
            })
    })
    .await;
    pass &= ok("the fork opened with the conversation so far", opened);
    let fork = cx.update(open_id);
    if fork != chat_id {
        made.push(fork);
    }
    pass &= ok("back to the chat", open_chat(chat_id, cx).await);
    pass
}

/// Delete on a question: it goes with its answer.
async fn delete(chat_id: &str, cx: &mut AsyncApp) -> bool {
    send("Reply with exactly the word: beta", cx).await;
    let mut pass = ok(
        "a second question answered",
        wait_answer(cx, Duration::from_secs(60)).await,
    );
    settle(cx, 1500).await;
    let before = cx
        .update(|cx| chat_store(cx).map(|s| s.read(cx).messages().len()))
        .unwrap_or(0);
    let Some(question) = cx.update(last_question) else {
        return ok("a question to delete", false);
    };
    let count = cx.update(|cx| {
        chat_store(cx).map(|s| s.read(cx).delete_count(vec![question.key.clone()], cx))
    });
    if let Some(count) = count {
        pass &= ok(
            "a question takes its answer with it (2)",
            count.await.ok() == Some(2),
        );
    }
    // The sheet is answered at once in this pass (AutoAnswer).
    pass &= act(&question, RowCommand::Delete, cx).await;
    let gone = wait_until(cx, Duration::from_secs(20), move |cx| {
        chat_store(cx).is_some_and(|s| {
            let s = s.read(cx);
            s.messages().len() + 2 == before
                && !s.messages().iter().any(|m| m.content.trim() == "beta")
        })
    })
    .await;
    pass &= ok("the question and its answer were deleted", gone);
    // And on the server: reopened, they stay gone.
    new_chat(false, cx).await;
    pass &= ok("the chat opens again", open_chat(chat_id, cx).await);
    // Nor drawn: the turn that wrote it is not replayed to the new window.
    settle(cx, 1500).await;
    let still = cx.update(|cx| {
        chat_store(cx).is_some_and(|s| {
            !s.read(cx)
                .messages()
                .iter()
                .any(|m| m.content.contains("beta"))
        }) && !items(cx).iter().any(|i| i.text.contains("beta"))
    });
    pass &= ok("the deleted messages stay gone after reopening", still);
    pass
}

/// Compare Models: both answers as columns; Continue from Here; Merge.
async fn compare(chat_id: &str, main: AnyWindowHandle, dir: &Path, cx: &mut AsyncApp) -> bool {
    let mut pass = ok(
        "Compare Models is offered",
        cx.update(|cx| {
            pane(cx).is_some_and(|p| p.read(cx).composer_store.read(cx).options.compare_models)
        }),
    );
    let other = cx.update(|cx| {
        pane(cx).and_then(|p| {
            p.read(cx)
                .composer_store
                .read(cx)
                .models
                .as_ref()
                .and_then(|m| m.models.iter().find(|m| m.id == MODEL_B).cloned())
        })
    });
    let Some(other) = other else {
        return ok("the second model to compare with", false);
    };
    in_pane(cx, move |p, _, cx| {
        p.composer_store
            .update(cx, |c, cx| c.set_compare_with(Some(other), cx))
    });
    settle(cx, 300).await;
    shoot_both_modes(main, dir, "actions-compare-chip", cx).await;
    send("Reply with exactly the word: gamma", cx).await;
    // Both columns while they are written, or once they are done.
    let columns = wait_until(cx, Duration::from_secs(60), |cx| {
        last_answer(cx).is_some_and(|i| i.columns.len() == 2)
    })
    .await;
    pass &= ok("the answer shows two columns", columns);
    let done = wait_until(cx, Duration::from_secs(90), |cx| {
        last_answer(cx).is_some_and(|i| {
            i.stored
                && i.columns.len() == 2
                && i.columns
                    .iter()
                    .all(|c| !c.streaming && !c.text.trim().is_empty())
        }) && chat_store(cx).is_some_and(|s| !s.read(cx).is_streaming())
    })
    .await;
    pass &= ok("both models answered, side by side", done);
    settle(cx, 800).await;
    let seen = cx.update(|cx| {
        let abilities = chat_store(cx).map(|s| s.read(cx).abilities());
        let mergeable = last_answer(cx).map(|i| i.mergeable);
        format!("{abilities:?} mergeable {mergeable:?}")
    });
    println!("SMOKE compare {seen}");
    shoot_both_modes(main, dir, "actions-compare", cx).await;
    let both = cx.update(|cx| {
        last_answer(cx).is_some_and(|i| {
            i.columns.iter().any(|c| c.text.trim() == "gamma")
                && i.columns.iter().any(|c| c.text.starts_with("B:"))
        })
    });
    pass &= ok("one column per model", both);
    // Continue from Here on the other column.
    let (message, other_id) = cx
        .update(|cx| {
            last_answer(cx).and_then(|i| {
                let other = i.columns.iter().find(|c| !c.current)?.answer_id.clone();
                Some((i.key, other))
            })
        })
        .unwrap_or_default();
    if let Some(store) = cx.update(chat_store) {
        let (m, o) = (message.clone(), other_id.clone());
        store
            .update(cx, |s, cx| s.set_current(&o, Some(&m), cx))
            .await;
    }
    let continued = wait_until(cx, Duration::from_secs(20), {
        let other_id = other_id.clone();
        move |cx| {
            last_answer(cx).is_some_and(|i| {
                i.columns
                    .iter()
                    .any(|c| c.current && c.answer_id == other_id)
            })
        }
    })
    .await;
    pass &= ok(
        "Continue from Here makes the other answer the chat's",
        continued,
    );
    // Merge Responses: saved on the answer shown.
    settle(cx, 500).await;
    let Some(answer) = cx.update(last_answer) else {
        return ok("a comparison to merge", false);
    };
    pass &= ok("both answers can be merged", answer.mergeable.len() == 2);
    pass &= act(&answer, RowCommand::Merge, cx).await;
    let merged = wait_until(cx, Duration::from_secs(60), |cx| {
        chat_store(cx).is_some_and(|s| !s.read(cx).merging())
            && last_answer(cx)
                .is_some_and(|i| i.merged.as_ref().is_some_and(|m| !m.trim().is_empty()))
    })
    .await;
    pass &= ok("Merge Responses wrote a merged response", merged);
    settle(cx, 600).await;
    shoot_both_modes(main, dir, "actions-merged", cx).await;
    // Kept on the server: reopened, the merge is still there.
    new_chat(false, cx).await;
    pass &= ok("the chat opens again", open_chat(chat_id, cx).await);
    let kept = wait_until(cx, Duration::from_secs(20), |cx| {
        last_answer(cx).is_some_and(|i| i.merged.is_some() && i.columns.len() == 2)
    })
    .await;
    pass &= ok("the merged response is kept", kept);
    pass
}

/// Export, both formats, into a throwaway folder.
async fn export(chat_id: &str, dir: &Path, cx: &mut AsyncApp) -> bool {
    let out = dir.join("exports");
    std::fs::create_dir_all(&out).ok();
    let mut pass = true;
    for format in [ChatExportFormat::Json, ChatExportFormat::Markdown] {
        let id = chat_id.to_string();
        let out = out.clone();
        let task =
            cx.update(move |cx| crate::views::chat::export::export_to_dir(id, format, out, cx));
        let path = task.await;
        let text = path
            .as_ref()
            .and_then(|p| std::fs::read_to_string(p).ok())
            .unwrap_or_default();
        match format {
            ChatExportFormat::Json => {
                let json: Option<Value> = serde_json::from_str(&text).ok();
                let ok_json = json.as_ref().is_some_and(|v| {
                    let v = if v.is_array() {
                        v.get(0).cloned().unwrap_or_default()
                    } else {
                        v.clone()
                    };
                    v.get("chat").and_then(|c| c.get("history")).is_some()
                });
                pass &= ok(
                    "Export › Backup (JSON) holds the chat's whole history",
                    ok_json,
                );
                pass &= ok(
                    "the backup is named after the chat, .json",
                    path.as_ref()
                        .is_some_and(|p| p.extension().is_some_and(|e| e == "json")),
                );
            }
            _ => {
                pass &= ok(
                    "Export › Transcript (Markdown) reads the conversation",
                    text.contains("gamma")
                        && path
                            .as_ref()
                            .is_some_and(|p| p.extension().is_some_and(|e| e == "md")),
                );
            }
        }
    }
    pass
}

/// Share Chat: make the link, choose who may open it in the access sheet
/// (the one chat settings use, kind chat), update it, delete it.
async fn share(
    chat_id: &str,
    inputs: &E2eInputs,
    rpc: &crate::stores::rpc::Rpc,
    dir: &Path,
    cx: &mut AsyncApp,
) -> bool {
    let id = chat_id.to_string();
    let sheet = in_main(cx, move |_, window, cx| {
        crate::views::chat::share_sheet::open(id, window, cx)
    })
    .flatten();
    let Some(sheet) = sheet else {
        return ok("Share Chat opens", false);
    };
    let read = wait_until(cx, Duration::from_secs(20), |cx| {
        let s = sheet.read(cx);
        s.share.is_some() && !s.busy
    })
    .await;
    let mut pass = ok("Share Chat reads the chat's link", read);
    sheet.update(cx, |s, cx| s.copy_link(cx));
    let linked = wait_until(cx, Duration::from_secs(20), |cx| {
        let s = sheet.read(cx);
        !s.busy
            && s.linked()
            && s.share
                .as_ref()
                .is_some_and(|s| s.url.as_ref().is_some_and(|u| u.contains("/s/")))
    })
    .await;
    pass &= ok("Copy Link made a link to the chat", linked);
    let copied = cx.update(|cx| {
        cx.read_from_clipboard()
            .and_then(|c| c.text())
            .is_some_and(|t| t.contains("/s/"))
    });
    pass &= ok("the link is on the clipboard", copied);
    settle(cx, 400).await;
    if let Some(handle) = cx.update(|cx| crate::views::chat::sheets::handle(cx)) {
        shoot_both_modes(handle, dir, "actions-share", cx).await;
        let controls = ax(handle, "actions-share", dir, cx).await;
        pass &= ok(
            "Share Chat's controls are labelled",
            has(&controls, "Button", "Update and Copy Link") && has(&controls, "Button", "Edit…"),
        );
    }
    let (access, sheet) = who_has_access(chat_id, inputs, rpc, &sheet, dir, cx).await;
    pass &= access;
    let Some(sheet) = sheet else {
        return ok("Share Chat comes back after Who Has Access", false);
    };
    let first = cx.update(|cx| {
        sheet
            .read(cx)
            .share
            .as_ref()
            .and_then(|s| s.share_id.clone())
    });
    sheet.update(cx, |s, cx| s.copy_link(cx));
    let updated = wait_until(cx, Duration::from_secs(20), |cx| {
        let s = sheet.read(cx);
        !s.busy && s.linked() && s.copied
    })
    .await;
    pass &= ok("Update and Copy Link updates the link", updated);
    // Opened again, it shows the link the chat has (read from its copy).
    cx.update(crate::views::chat::sheets::close);
    settle(cx, 800).await;
    let id = chat_id.to_string();
    let again = in_main(cx, move |_, window, cx| {
        crate::views::chat::share_sheet::open(id, window, cx)
    })
    .flatten();
    let Some(sheet) = again else {
        return ok("Share Chat opens again", false);
    };
    let kept = wait_until(cx, Duration::from_secs(20), |cx| {
        let s = sheet.read(cx);
        !s.busy
            && s.linked()
            && s.share.as_ref().and_then(|s| s.share_id.clone()) == first
            && s.share.as_ref().and_then(|s| s.audience) == Some(ShareAudience::Open)
    })
    .await;
    pass &= ok(
        "opened again, Share Chat shows the same link and audience",
        kept,
    );
    sheet.update(cx, |s, cx| s.delete_link(cx));
    let deleted = wait_until(cx, Duration::from_secs(20), |cx| {
        let s = sheet.read(cx);
        !s.busy && !s.linked()
    })
    .await;
    pass &= ok("Delete This Link removed it", deleted);
    cx.update(crate::views::chat::sheets::close);
    settle(cx, 500).await;
    pass
}

/// Who Has Access › Edit…: Share Chat gives way to the access sheet for the
/// chat; the seeded second user and group are added, Anyone with the Link
/// is chosen, Save keeps them on the server, and Share Chat comes back with
/// the new audience. Returns the pass and the Share Chat that came back.
async fn who_has_access(
    chat_id: &str,
    inputs: &E2eInputs,
    rpc: &crate::stores::rpc::Rpc,
    share: &Entity<crate::views::chat::share_sheet::ShareSheet>,
    dir: &Path,
    cx: &mut AsyncApp,
) -> (
    bool,
    Option<Entity<crate::views::chat::share_sheet::ShareSheet>>,
) {
    use crate::views::access_sheet::AccessSheet;
    use crate::views::sheet;
    let (Some(second), Some(group)) = (
        inputs.get("OWUI_SECOND_NAME"),
        inputs.get("OWUI_GROUP_NAME"),
    ) else {
        return (
            ok(
                "OWUI_SECOND_NAME and OWUI_GROUP_NAME in the env file (owui.sh reset)",
                false,
            ),
            None,
        );
    };
    share.update(cx, |s, cx| s.edit_access(cx));
    let loaded = wait_until(cx, Duration::from_secs(20), |cx| {
        sheet::current::<AccessSheet>(cx).is_some_and(|s| s.read(cx).state.is_some())
    })
    .await;
    let mut pass = ok(
        "Who Has Access › Edit… opens the access sheet in Share Chat's place",
        loaded,
    );
    let Some(access) = cx.update(|cx| sheet::current::<AccessSheet>(cx)) else {
        return (pass, None);
    };
    let state = cx.update(|cx| access.read(cx).state.clone());
    pass &= ok(
        "it is the chat's, read only for those added (no Can Edit)",
        state.as_ref().is_some_and(|s| {
            s.kind == AccessResourceKind::Chat && s.id == chat_id && !s.allow_write
        }),
    );
    pass &= ok(
        "the account may open it to everyone and by link",
        state
            .as_ref()
            .is_some_and(|s| s.can_edit && s.allow_public && s.allow_open),
    );
    settle(cx, 500).await;
    if let Some(handle) = cx.update(|cx| sheet::current_window(cx)) {
        shoot_both_modes(handle, dir, "actions-share-access", cx).await;
        let controls = ax(handle, "actions-share-access", dir, cx).await;
        pass &= ok(
            "the access sheet offers General Access and Save",
            has(&controls, "ComboBox", "General Access") && has(&controls, "Button", "Save"),
        );
    }
    // The second user, found by name.
    let first_name = second.split(' ').next().unwrap_or(&second).to_string();
    in_access(cx, move |s, _, cx| s.find(first_name, cx));
    let found = wait_until(cx, Duration::from_secs(15), |cx| {
        sheet::current::<AccessSheet>(cx)
            .is_some_and(|s| s.read(cx).results.iter().any(|p| p.r#type == "user"))
    })
    .await;
    pass &= ok("people are found by name", found);
    in_access(cx, |s, w, cx| {
        if let Some(p) = s.results.iter().find(|p| p.r#type == "user").cloned() {
            s.add(&p, w, cx);
        }
    });
    // And the seeded group (listed once the field is empty again).
    let listed = wait_until(cx, Duration::from_secs(15), |cx| {
        sheet::current::<AccessSheet>(cx)
            .is_some_and(|s| s.read(cx).results.iter().any(|p| p.r#type == "group"))
    })
    .await;
    pass &= ok("the account's groups are listed", listed);
    in_access(cx, |s, w, cx| {
        if let Some(p) = s.results.iter().find(|p| p.r#type == "group").cloned() {
            s.add(&p, w, cx);
        }
        s.set_audience(AccessAudience::Open, cx);
    });
    settle(cx, 400).await;
    let chosen = cx.update(|cx| {
        let s = access.read(cx);
        s.audience() == AccessAudience::Open && s.grants.len() == 2 && s.is_dirty()
    });
    pass &= ok(
        "a person, a group and Anyone with the Link are chosen",
        chosen,
    );
    if let Some(handle) = cx.update(|cx| sheet::current_window(cx)) {
        shoot_both_modes(handle, dir, "actions-share-access-chosen", cx).await;
    }
    in_access(cx, |s, w, cx| s.save(w, cx));
    // Saved, the access sheet goes and Share Chat comes back.
    let back = wait_until(cx, Duration::from_secs(25), |cx| {
        crate::views::chat::sheets::is_open(cx)
            && sheet::current::<crate::views::chat::share_sheet::ShareSheet>(cx).is_some_and(|s| {
                let s = s.read(cx);
                !s.busy && s.share.is_some()
            })
    })
    .await;
    pass &= ok("Save brings Share Chat back", back);
    let again = cx.update(|cx| sheet::current::<crate::views::chat::share_sheet::ShareSheet>(cx));
    let shown = again.as_ref().is_some_and(|s| {
        cx.update(|cx| s.read(cx).share.as_ref().and_then(|s| s.audience))
            == Some(ShareAudience::Open)
    });
    pass &= ok("Share Chat shows Anyone with the Link", shown);
    let saved = rpc
        .call::<methods::AccessGet>(&AccessRef {
            kind: AccessResourceKind::Chat,
            id: chat_id.to_string(),
        })
        .await;
    pass &= ok(
        &format!("access.get: {second} and the group {group} may open the chat, by link too"),
        saved.as_ref().is_ok_and(|s| {
            s.audience == AccessAudience::Open
                && s.grants
                    .iter()
                    .any(|g| g.principal_type == "user" && g.name == second && !g.write)
                && s.grants
                    .iter()
                    .any(|g| g.principal_type == "group" && g.name == group && !g.write)
        }),
    );
    // Back to no one named (the link's audience stays for the steps after).
    let cleared = rpc
        .call::<methods::AccessSet>(&AccessEdit {
            kind: AccessResourceKind::Chat,
            id: chat_id.to_string(),
            grants: vec![],
            audience: None,
        })
        .await;
    pass &= ok(
        "and the people are removed again",
        cleared.is_ok_and(|s| s.grants.is_empty() && s.audience == AccessAudience::Open),
    );
    (pass, again)
}

/// Runs `f` on the access sheet down now, in its window.
fn in_access<R>(
    cx: &mut AsyncApp,
    f: impl FnOnce(
        &mut crate::views::access_sheet::AccessSheet,
        &mut gpui_kit::Window,
        &mut gpui_kit::Context<crate::views::access_sheet::AccessSheet>,
    ) -> R,
) -> Option<R> {
    use crate::views::sheet;
    let handle = cx.update(|cx| sheet::current_window(cx))?;
    let entity = cx.update(|cx| sheet::current::<crate::views::access_sheet::AccessSheet>(cx))?;
    cx.update(|cx| {
        handle
            .update(cx, |_, window, cx| {
                entity.update(cx, |v, cx| f(v, window, cx))
            })
            .ok()
    })
}

/// Generate Title; Mark as Unread with the sidebar's dot, gone on opening.
async fn title_and_unread(
    chat_id: &str,
    main: AnyWindowHandle,
    dir: &Path,
    cx: &mut AsyncApp,
) -> bool {
    let id = chat_id.to_string();
    let task = cx.update(|cx| chat_list(cx).update(cx, |c, cx| c.generate_title(&id, cx)));
    let titled = task.await;
    let mut pass = ok(
        "Generate Title answered with a title",
        titled
            .as_ref()
            .is_ok_and(|t| t.outcome != conduit_protocol::GenerateTitleOutcome::None),
    );
    if let Ok(t) = &titled
        && let Some(title) = &t.title
    {
        let want = title.clone();
        let id = chat_id.to_string();
        let shown = wait_until(cx, Duration::from_secs(20), move |cx| {
            chat_list(cx)
                .read(cx)
                .find(&id)
                .is_some_and(|c| c.title == want)
        })
        .await;
        pass &= ok("the sidebar shows the generated title", shown);
    }
    // Away from the chat, then Mark as Unread from its menu.
    new_chat(false, cx).await;
    chat_command(chat_id, ChatCommand::MarkUnread, cx).await;
    let id = chat_id.to_string();
    let dotted = wait_until(cx, Duration::from_secs(20), move |cx| {
        chat_list(cx).read(cx).find(&id).is_some_and(|c| c.unread)
    })
    .await;
    pass &= ok("Mark as Unread gives the chat its dot", dotted);
    settle(cx, 600).await;
    shoot_both_modes(main, dir, "actions-unread", cx).await;
    let controls = ax(main, "actions-unread", dir, cx).await;
    pass &= ok(
        "VoiceOver hears it is unread",
        has(&controls, "TreeItem", "Unread"),
    );
    pass &= ok("the chat opens", open_chat(chat_id, cx).await);
    let id = chat_id.to_string();
    let read = wait_until(cx, Duration::from_secs(20), move |cx| {
        chat_list(cx).read(cx).find(&id).is_some_and(|c| !c.unread)
    })
    .await;
    pass &= ok("opening it reads it", read);
    pass
}

/// Save Chat: a temporary chat becomes a stored one.
async fn save_temporary(
    made: &mut Vec<String>,
    main: AnyWindowHandle,
    dir: &Path,
    cx: &mut AsyncApp,
) -> bool {
    new_chat(true, cx).await;
    send("Reply with exactly the word: delta", cx).await;
    let mut pass = ok(
        "a temporary chat answered",
        wait_answer(cx, Duration::from_secs(60)).await,
    );
    let offered = wait_until(cx, Duration::from_secs(10), |cx| {
        pane(cx).is_some_and(|p| p.read(cx).can_save_temporary(cx))
    })
    .await;
    pass &= ok("Save Chat is offered for it", offered);
    settle(cx, 400).await;
    shoot_both_modes(main, dir, "actions-temporary", cx).await;
    let temp = cx.update(open_id);
    in_pane(cx, |p, window, cx| p.save_temporary(window, cx));
    let saved = wait_until(cx, Duration::from_secs(30), {
        let temp = temp.clone();
        move |cx| {
            let id = open_id(cx);
            !id.is_empty()
                && id != temp
                && chat_store(cx).is_some_and(|s| !s.read(cx).temporary)
                && chat_list(cx).read(cx).find(&id).is_some()
        }
    })
    .await;
    pass &= ok("Save Chat made it a stored chat, in the sidebar", saved);
    let id = cx.update(open_id);
    if saved {
        made.push(id);
    }
    pass
}
