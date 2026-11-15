//! `--e2e chat-settings`: per-chat, model and folder settings over the
//! real daemon, on the local Open WebUI, its fake model (whose request log
//! keeps each request's system text and generation params) and its seed (a
//! tool with personal valves, the Recipes folder, a second user).
//!
//! * Chat Settings on a stored chat: a system prompt and two parameters
//!   saved, and the next request carries them; an out-of-range value
//!   refused in place; one parameter back to Your Default, then Reset All,
//!   each seen in the request;
//! * a new chat's settings kept for its first message;
//! * a reasoning effort preset from the model picker, in the request; pin
//!   and unpin a model;
//! * a personal valve changed in Tool Settings;
//! * a folder's system prompt, default model, icon and knowledge; a new
//!   chat in the folder runs on that model with that prompt and the
//!   folder's knowledge tools, and is filed there; ⌘I on the selected
//!   folder opens its settings;
//! * the folder shared with the seeded second user, who may edit it.
//!
//! Each new sheet and the picker's extras are shot in light and dark.

use std::path::Path;
use std::time::Duration;

use conduit_protocol::{
    AccessEdit, AccessRef, AccessResourceKind, AppSettingsPatch, ChatRef, ChatSettingError,
    ChatSettingMode, FolderUpdate, ValveTargetKind, ValvesRef, methods,
};
use gpui_kit::{App, AsyncApp, Entity};
use serde_json::Value;

use super::chat::{chat_store, in_pane, pane, send, sign_in, wait_answer, wait_models};
use super::*;
use crate::actions::SettingsChoice;
use crate::views::access_sheet::AccessSheet;
use crate::views::chat_settings::ChatSettingsSheet;
use crate::views::folder_settings::FolderSettingsSheet;
use crate::views::sheet;
use crate::views::valves::ValvesSheet;

/// The fake model's newest streamed request, as its log has it.
fn last_request(path: &Path) -> Option<Value> {
    let text = std::fs::read_to_string(path).ok()?;
    text.lines()
        .rev()
        .filter_map(|l| serde_json::from_str::<Value>(l).ok())
        .find(|v| v.get("stream").and_then(Value::as_bool) == Some(true))
}

fn param(request: &Option<Value>, key: &str) -> Option<Value> {
    request.as_ref()?.get("params")?.get(key).cloned()
}

fn system_text(request: &Option<Value>) -> String {
    request
        .as_ref()
        .and_then(|r| r.get("system"))
        .and_then(Value::as_array)
        .map(|a| {
            a.iter()
                .filter_map(Value::as_str)
                .collect::<Vec<_>>()
                .join("\n")
        })
        .unwrap_or_default()
}

/// Sends `text` and waits for the answer and for its request in the log:
/// `None` when either never came (no check passes on an earlier request).
async fn turn(text: &str, log: &Path, cx: &mut AsyncApp) -> Option<Value> {
    let before = std::fs::read_to_string(log).map(|t| t.len()).unwrap_or(0);
    send(text, cx).await;
    if !wait_answer(cx, Duration::from_secs(60)).await {
        return None;
    }
    let want = text.to_string();
    for _ in 0..40 {
        let grown = std::fs::read_to_string(log).map(|t| t.len()).unwrap_or(0) > before;
        let request = last_request(log);
        let ours = request
            .as_ref()
            .and_then(|r| r.get("user"))
            .and_then(Value::as_str)
            .is_some_and(|u| u.contains(&want));
        if grown && ours {
            return request;
        }
        settle(cx, 250).await;
    }
    None
}

fn navigation(cx: &mut App) -> Entity<crate::stores::navigation::NavigationStore> {
    cx.global::<AppState>().stores.navigation.clone()
}

async fn new_chat(cx: &mut AsyncApp) {
    let nav = cx.update(navigation);
    nav.update(cx, |n, cx| n.new_chat(false, cx));
    settle(cx, 400).await;
}

fn sheet_of<V: 'static>(cx: &mut App) -> Option<Entity<V>> {
    sheet::current::<V>(cx)
}

/// Waits for a sheet of `V` to be down (and loaded, by `loaded`).
async fn wait_sheet<V: 'static>(
    cx: &mut AsyncApp,
    loaded: impl Fn(&V) -> bool + 'static,
) -> Option<Entity<V>> {
    let found = wait_until(cx, Duration::from_secs(20), move |cx| {
        sheet_of::<V>(cx).is_some_and(|s| loaded(s.read(cx)))
    })
    .await;
    if found {
        cx.update(sheet_of::<V>)
    } else {
        None
    }
}

async fn wait_closed(cx: &mut AsyncApp) -> bool {
    wait_until(cx, Duration::from_secs(20), |cx| !sheet::is_open(cx)).await
}

/// The sheet's window is a real window sheet on the main window.
fn attached(cx: &mut AsyncApp) -> bool {
    let Some((main, _)) = cx.update(main_window) else {
        return false;
    };
    let Some(sheet) = cx.update(|cx| sheet::current_window(cx)) else {
        return false;
    };
    let (parent, own) = cx.update(|cx| {
        (
            crate::smoke::ns_window(main, cx),
            crate::smoke::ns_window(sheet, cx),
        )
    });
    match (parent, own) {
        (Some(parent), Some(own)) => {
            own.isSheet()
                && own.sheetParent().is_some_and(|p| {
                    objc2::rc::Retained::as_ptr(&p) == objc2::rc::Retained::as_ptr(&parent)
                })
        }
        _ => false,
    }
}

fn in_sheet<V: 'static, R>(
    cx: &mut AsyncApp,
    f: impl FnOnce(&mut V, &mut gpui_kit::Window, &mut gpui_kit::Context<V>) -> R,
) -> Option<R> {
    let handle = cx.update(|cx| sheet::current_window(cx))?;
    let entity = cx.update(sheet_of::<V>)?;
    cx.update(|cx| {
        handle
            .update(cx, |_, window, cx| {
                entity.update(cx, |v, cx| f(v, window, cx))
            })
            .ok()
    })
}

pub async fn run(inputs: &E2eInputs, dir: &Path, cx: &mut AsyncApp) -> bool {
    let Some((url, email, password)) = inputs.owui() else {
        return ok(NO_SERVER, false);
    };
    let Some(log) = inputs.get("FAKE_MODEL_LOG").map(std::path::PathBuf::from) else {
        return ok("FAKE_MODEL_LOG in the env file", false);
    };
    let mut pass = sign_in(&url, &email, &password, cx).await;
    pass &= ok("models.list answered", wait_models(cx).await);
    let model = inputs.model();
    {
        let model = model.clone();
        in_pane(cx, move |p, _, cx| {
            p.composer_store
                .update(cx, |c, cx| c.select_model(&model, cx))
        });
    }
    settle(cx, 600).await;
    let rpc = cx.update(|cx| cx.global::<AppState>().stores.connection.read(cx).rpc());

    // Without Advanced, a new chat with no settings offers none (as mobile).
    let _ = rpc
        .call::<methods::SettingsSet>(&AppSettingsPatch {
            advanced_features_enabled: Some(false),
            ..Default::default()
        })
        .await;
    cx.update(|cx| {
        let s = cx.global::<AppState>().stores.app_settings.clone();
        s.update(cx, |s, cx| s.refresh(cx));
    });
    new_chat(cx).await;
    let hidden = wait_until(cx, Duration::from_secs(15), |cx| {
        pane(cx).is_some_and(|p| !p.read(cx).settings_offer.chat_settings)
    })
    .await;
    pass &= ok(
        "without Advanced, a new chat offers no Chat Settings",
        hidden,
    );
    let _ = rpc
        .call::<methods::SettingsSet>(&AppSettingsPatch {
            advanced_features_enabled: Some(true),
            ..Default::default()
        })
        .await;
    cx.update(|cx| {
        let s = cx.global::<AppState>().stores.app_settings.clone();
        s.update(cx, |s, cx| s.refresh(cx));
    });
    let offered = wait_until(cx, Duration::from_secs(15), |cx| {
        pane(cx).is_some_and(|p| p.read(cx).settings_offer.chat_settings)
    })
    .await;
    pass &= ok("with Advanced on, Chat Settings is offered", offered);

    // ── A chat to work in, made here and deleted at the end ────────────
    send("Reply with exactly the word: pong", cx).await;
    pass &= ok(
        "a new chat answered",
        wait_answer(cx, Duration::from_secs(60)).await,
    );
    let stored = wait_until(cx, Duration::from_secs(30), |cx| {
        chat_store(cx).is_some_and(|s| !s.read(cx).chat_id().starts_with("local:"))
    })
    .await;
    pass &= ok("the chat has its server id", stored);
    let chat_id = cx
        .update(|cx| chat_store(cx).map(|s| s.read(cx).chat_id().to_string()))
        .unwrap_or_default();
    let mut made = vec![chat_id.clone()];

    pass &= chat_settings(&log, dir, cx).await;
    pass &= reasoning_and_pins(&model, &log, dir, cx).await;
    pass &= tool_settings(inputs, &rpc, dir, cx).await;
    let (ok_draft, draft_chat) = new_chat_settings(&log, dir, cx).await;
    pass &= ok_draft;
    made.extend(draft_chat);
    let (ok_folder, folder_chat) = folder_settings(&model, &rpc, &log, dir, cx).await;
    pass &= ok_folder;
    made.extend(folder_chat);
    pass &= share_folder(inputs, &rpc, dir, cx).await;

    // ── Clean up ───────────────────────────────────────────────────────
    for id in made {
        let deleted = rpc.call::<methods::ChatsDelete>(&ChatRef { id }).await;
        pass &= ok("a chat this pass made is deleted", deleted.is_ok());
    }
    let _ = rpc
        .call::<methods::SettingsSet>(&AppSettingsPatch {
            advanced_features_enabled: Some(false),
            ..Default::default()
        })
        .await;
    pass
}

/// Chat Settings on the open chat: saved, carried by the request, refused
/// when out of range, back to Your Default, then Reset All.
async fn chat_settings(log: &Path, dir: &Path, cx: &mut AsyncApp) -> bool {
    let mut pass = true;
    in_pane(cx, |p, w, cx| p.open_chat_settings(w, cx));
    let Some(_) = wait_sheet::<ChatSettingsSheet>(cx, |s| s.state.is_some()).await else {
        return ok("Chat Settings opens a sheet", false);
    };
    settle(cx, 600).await;
    pass &= ok(
        "Chat Settings is a window sheet on the main window",
        attached(cx),
    );
    shoot_main(dir, "chat-settings-editor", cx).await;
    if let Some(handle) = cx.update(|cx| sheet::current_window(cx)) {
        let controls = ax(handle, "chat-settings", dir, cx).await;
        pass &= ok(
            "the sheet has Save, Cancel, Reset All and the prompt's choice",
            has(&controls, "Button", "Save")
                && has(&controls, "Button", "Cancel")
                && has(&controls, "Button", "Reset All")
                && has(&controls, "ComboBox", "Effort"),
        );
    }
    // An out-of-range temperature is refused in place.
    in_sheet::<ChatSettingsSheet, _>(cx, |s, w, cx| s.type_field("temperature", "9", w, cx));
    let refused = wait_until(cx, Duration::from_secs(10), |cx| {
        sheet_of::<ChatSettingsSheet>(cx).is_some_and(|s| {
            s.read(cx).error_of("temperature") == Some(ChatSettingError::OutOfRange)
        })
    })
    .await;
    pass &= ok("a temperature of 9 is out of range", refused);
    shoot_main(dir, "chat-settings-error", cx).await;
    in_sheet::<ChatSettingsSheet, _>(cx, |s, w, cx| {
        s.type_field("temperature", "0.3", w, cx);
        s.type_field("seed", "42", w, cx);
        s.type_field("system", "Answer like a ship captain.", w, cx);
    });
    let clean = wait_until(cx, Duration::from_secs(10), |cx| {
        sheet_of::<ChatSettingsSheet>(cx).is_some_and(|s| {
            let s = s.read(cx);
            s.error_of("temperature").is_none() && s.is_dirty()
        })
    })
    .await;
    pass &= ok("the fixed value is accepted", clean);
    shoot_main(dir, "chat-settings-custom", cx).await;
    in_sheet::<ChatSettingsSheet, _>(cx, |s, w, cx| s.save(w, cx));
    pass &= ok("Save closes the sheet", wait_closed(cx).await);

    let request = turn("Say the word: alpha", log, cx).await;
    pass &= ok(
        &format!(
            "the request has the chat's prompt ({:?})",
            system_text(&request)
        ),
        system_text(&request).contains("ship captain"),
    );
    pass &= ok(
        &format!(
            "and its temperature and seed ({:?})",
            request.as_ref().and_then(|r| r.get("params"))
        ),
        param(&request, "temperature").and_then(|v| v.as_f64()) == Some(0.3)
            && param(&request, "seed").and_then(|v| v.as_i64()) == Some(42),
    );

    // Your Default for the seed: the next request has none of its own.
    in_pane(cx, |p, w, cx| p.open_chat_settings(w, cx));
    let opened = wait_sheet::<ChatSettingsSheet>(cx, |s| s.state.is_some()).await;
    pass &= ok("Chat Settings opens again with what is saved", {
        opened.is_some_and(|s| {
            cx.update(|cx| {
                s.read(cx)
                    .edits
                    .iter()
                    .any(|e| e.key == "seed" && e.mode == ChatSettingMode::Custom && e.text == "42")
            })
        })
    });
    in_sheet::<ChatSettingsSheet, _>(cx, |s, w, cx| s.inherit("seed", w, cx));
    settle(cx, 400).await;
    in_sheet::<ChatSettingsSheet, _>(cx, |s, w, cx| s.save(w, cx));
    pass &= ok("Save closes it", wait_closed(cx).await);
    let request = turn("Say the word: bravo", log, cx).await;
    pass &= ok(
        "the seed inherits again; the temperature stays",
        request.is_some()
            && param(&request, "seed").is_none()
            && param(&request, "temperature").and_then(|v| v.as_f64()) == Some(0.3),
    );

    // Reset All: nothing of the chat's own is sent.
    in_pane(cx, |p, w, cx| p.open_chat_settings(w, cx));
    let _ = wait_sheet::<ChatSettingsSheet>(cx, |s| s.state.is_some()).await;
    in_sheet::<ChatSettingsSheet, _>(cx, |s, w, cx| s.reset_all(w, cx));
    settle(cx, 400).await;
    in_sheet::<ChatSettingsSheet, _>(cx, |s, w, cx| s.save(w, cx));
    pass &= ok("Reset All saves and closes", wait_closed(cx).await);
    let request = turn("Say the word: charlie", log, cx).await;
    pass &= ok(
        "after Reset All the request has neither the prompt nor the temperature",
        request.is_some()
            && !system_text(&request).contains("ship captain")
            && param(&request, "temperature").is_none(),
    );

    // Cancel with an edit asks first (answered Discard here): nothing saved.
    in_pane(cx, |p, w, cx| p.open_chat_settings(w, cx));
    let _ = wait_sheet::<ChatSettingsSheet>(cx, |s| s.state.is_some()).await;
    in_sheet::<ChatSettingsSheet, _>(cx, |s, w, cx| s.type_field("top_k", "12", w, cx));
    settle(cx, 300).await;
    in_sheet::<ChatSettingsSheet, _>(cx, |s, w, cx| {
        crate::views::sheet::SheetBody::cancel(s, w, cx)
    });
    pass &= ok(
        "Cancel, then Discard, closes the sheet",
        wait_closed(cx).await,
    );
    in_pane(cx, |p, w, cx| p.open_chat_settings(w, cx));
    let reopened = wait_sheet::<ChatSettingsSheet>(cx, |s| s.state.is_some()).await;
    pass &= ok(
        "the discarded Top K was not saved",
        reopened.is_some_and(|s| {
            cx.update(|cx| {
                s.read(cx)
                    .edits
                    .iter()
                    .any(|e| e.key == "top_k" && e.mode == ChatSettingMode::Inherit)
            })
        }),
    );
    in_sheet::<ChatSettingsSheet, _>(cx, |s, w, cx| {
        crate::views::sheet::SheetBody::cancel(s, w, cx)
    });
    pass &= ok("an untouched sheet closes at once", wait_closed(cx).await);
    pass
}

/// A reasoning effort preset from the picker reaches the request; a model
/// pinned and unpinned.
async fn reasoning_and_pins(model: &str, log: &Path, dir: &Path, cx: &mut AsyncApp) -> bool {
    let mut pass = true;
    in_pane(cx, |p, w, cx| p.open_model_picker(w, cx));
    let offered = wait_until(cx, Duration::from_secs(15), |cx| {
        pane(cx).is_some_and(|p| {
            p.read(cx)
                .composer_store
                .read(cx)
                .model_options
                .as_ref()
                .is_some_and(|o| o.reasoning.visible)
        })
    })
    .await;
    pass &= ok(
        "the picker offers a reasoning effort for the model",
        offered,
    );
    settle(cx, 500).await;
    shoot_main(dir, "model-picker-extras", cx).await;
    in_pane(cx, |p, _, cx| {
        p.composer_store
            .update(cx, |c, cx| c.set_reasoning_effort("high", cx))
    });
    let high = wait_until(cx, Duration::from_secs(10), |cx| {
        pane(cx).is_some_and(|p| {
            p.read(cx)
                .composer_store
                .read(cx)
                .model_options
                .as_ref()
                .is_some_and(|o| o.reasoning.current == "high")
        })
    })
    .await;
    pass &= ok("High is the model's effort now", high);
    settle(cx, 300).await;
    shoot_main(dir, "model-picker-effort-high", cx).await;
    // Pin, then unpin, the model.
    let id = model.to_string();
    in_pane(cx, move |p, _, cx| {
        p.composer_store
            .update(cx, |c, cx| c.set_pinned(&id, true, cx))
    });
    let want = model.to_string();
    let pinned = wait_until(cx, Duration::from_secs(10), move |cx| {
        pane(cx).is_some_and(|p| {
            p.read(cx)
                .composer_store
                .read(cx)
                .models
                .as_ref()
                .is_some_and(|l| {
                    l.models.iter().any(|m| m.id == want && m.pinned)
                        && l.featured_ids.contains(&want)
                })
        })
    })
    .await;
    pass &= ok("models.setPinned: the model is pinned and featured", pinned);
    shoot_main(dir, "model-picker-pinned", cx).await;
    // With one pinned, the other is under More Models.
    in_pane(cx, |p, _, cx| {
        p.composer.update(cx, |c, cx| c.toggle_more_models(cx))
    });
    settle(cx, 300).await;
    shoot_main(dir, "model-picker-more-models", cx).await;
    in_pane(cx, |p, _, cx| {
        p.composer.update(cx, |c, cx| c.toggle_more_models(cx))
    });
    let id = model.to_string();
    in_pane(cx, move |p, _, cx| {
        p.composer_store
            .update(cx, |c, cx| c.set_pinned(&id, false, cx))
    });
    let want = model.to_string();
    let unpinned = wait_until(cx, Duration::from_secs(10), move |cx| {
        pane(cx).is_some_and(|p| {
            p.read(cx)
                .composer_store
                .read(cx)
                .models
                .as_ref()
                .is_some_and(|l| l.models.iter().any(|m| m.id == want && !m.pinned))
        })
    })
    .await;
    pass &= ok("and unpinned again", unpinned);
    in_pane(cx, |p, w, cx| {
        p.composer.update(cx, |c, cx| c.close_picker(w, cx))
    });
    settle(cx, 300).await;
    let request = turn("Say the word: delta", log, cx).await;
    pass &= ok(
        &format!(
            "the request carries reasoning_effort high ({:?})",
            param(&request, "reasoning_effort")
        ),
        param(&request, "reasoning_effort").and_then(|v| v.as_str().map(str::to_string))
            == Some("high".into()),
    );
    // Back to Automatic: none is sent.
    in_pane(cx, |p, _, cx| {
        p.composer_store
            .update(cx, |c, cx| c.set_reasoning_effort("automatic", cx))
    });
    settle(cx, 800).await;
    let request = turn("Say the word: echo", log, cx).await;
    pass &= ok(
        "with Automatic again, no reasoning_effort is sent",
        request.is_some() && param(&request, "reasoning_effort").is_none(),
    );
    pass
}

/// Tool Settings: the seeded tool's personal valves, one changed.
async fn tool_settings(
    inputs: &E2eInputs,
    rpc: &crate::stores::rpc::Rpc,
    dir: &Path,
    cx: &mut AsyncApp,
) -> bool {
    let mut pass = true;
    let Some(tool) = inputs.get("OWUI_VALVE_TOOL") else {
        return ok("OWUI_VALVE_TOOL in the env file (owui.sh reset)", false);
    };
    let id = tool.clone();
    in_pane(cx, move |p, _, cx| {
        p.composer_store.update(cx, |c, cx| {
            if !c.tool_ids.contains(&id) {
                c.toggle_tool(&id, cx)
            }
        })
    });
    let offered = wait_until(cx, Duration::from_secs(20), |cx| {
        pane(cx).is_some_and(|p| !p.read(cx).settings_offer.tool_targets.is_empty())
    })
    .await;
    pass &= ok("with the tool on, Tool Settings is offered", offered);
    in_pane(cx, |p, w, cx| p.open_tool_settings(w, cx));
    let loaded = wait_sheet::<ValvesSheet>(cx, |s| s.document.is_some()).await;
    pass &= ok(
        "Tool Settings opens with the tool's valves",
        loaded.is_some(),
    );
    settle(cx, 600).await;
    shoot_main(dir, "tool-settings", cx).await;
    in_sheet::<ValvesSheet, _>(cx, |s, w, cx| {
        s.on_choice(
            &SettingsChoice {
                menu: "valve-mode:units".into(),
                value: "__custom__".into(),
            },
            w,
            cx,
        );
        s.on_choice(
            &SettingsChoice {
                menu: "valve-choice:units".into(),
                value: "imperial".into(),
            },
            w,
            cx,
        );
    });
    settle(cx, 300).await;
    shoot_main(dir, "tool-settings-custom", cx).await;
    in_sheet::<ValvesSheet, _>(cx, |s, w, cx| s.save(w, cx));
    pass &= ok("Save closes Tool Settings", wait_closed(cx).await);
    let doc = rpc
        .call::<methods::ValvesGet>(&ValvesRef {
            kind: ValveTargetKind::Tool,
            id: tool.clone(),
            label: String::new(),
        })
        .await;
    pass &= ok(
        "valves.get: units is imperial now",
        doc.as_ref().is_ok_and(|d| {
            d.fields
                .iter()
                .any(|f| f.key == "units" && !f.is_default && f.text == "imperial")
        }),
    );
    // Put back.
    let _ = rpc
        .call::<methods::ValvesSave>(&conduit_protocol::ValvesSave {
            kind: ValveTargetKind::Tool,
            id: tool.clone(),
            label: String::new(),
            values: vec![conduit_protocol::ValveEdit {
                key: "units".into(),
                is_default: true,
                text: String::new(),
            }],
        })
        .await;
    let id = tool;
    in_pane(cx, move |p, _, cx| {
        p.composer_store.update(cx, |c, cx| c.toggle_tool(&id, cx))
    });
    settle(cx, 300).await;
    pass
}

/// A new chat's settings, kept for its first message.
async fn new_chat_settings(log: &Path, dir: &Path, cx: &mut AsyncApp) -> (bool, Option<String>) {
    let mut pass = true;
    new_chat(cx).await;
    let offered = wait_until(cx, Duration::from_secs(15), |cx| {
        pane(cx).is_some_and(|p| p.read(cx).settings_offer.chat_settings)
    })
    .await;
    pass &= ok("a new chat offers Chat Settings (Advanced on)", offered);
    in_pane(cx, |p, w, cx| p.open_chat_settings(w, cx));
    let Some(_) = wait_sheet::<ChatSettingsSheet>(cx, |s| s.state.is_some()).await else {
        return (ok("Chat Settings opens for a new chat", false), None);
    };
    in_sheet::<ChatSettingsSheet, _>(cx, |s, w, cx| s.type_field("max_tokens", "64", w, cx));
    settle(cx, 500).await;
    shoot_main(dir, "chat-settings-new-chat", cx).await;
    in_sheet::<ChatSettingsSheet, _>(cx, |s, w, cx| s.save(w, cx));
    pass &= ok("Save closes it", wait_closed(cx).await);
    let kept = wait_until(cx, Duration::from_secs(5), |cx| {
        pane(cx).is_some_and(|p| {
            p.read(cx)
                .composer_store
                .read(cx)
                .draft_params
                .get("max_tokens")
                == Some(&Value::from(64))
        })
    })
    .await;
    pass &= ok(
        "the new chat keeps max_tokens 64 for its first message",
        kept,
    );
    let request = turn("Say the word: foxtrot", log, cx).await;
    pass &= ok(
        &format!(
            "its first request has max_tokens 64 ({:?})",
            param(&request, "max_tokens")
        ),
        param(&request, "max_tokens").and_then(|v| v.as_i64()) == Some(64),
    );
    let id = cx.update(|cx| chat_store(cx).map(|s| s.read(cx).chat_id().to_string()));
    let cleared = cx.update(|cx| {
        pane(cx).is_some_and(|p| p.read(cx).composer_store.read(cx).draft_params.is_null())
    });
    pass &= ok("the composer let go of them once the chat existed", cleared);
    (pass, id)
}

/// Folder Settings for the seeded Recipes folder: prompt, default model and
/// icon; a new chat in it runs with them and is filed there.
async fn folder_settings(
    model: &str,
    rpc: &crate::stores::rpc::Rpc,
    log: &Path,
    dir: &Path,
    cx: &mut AsyncApp,
) -> (bool, Option<String>) {
    let mut pass = true;
    let Some(folder) = cx.update(|cx| folder_named("Recipes", cx)) else {
        return (ok("the seeded Recipes folder is listed", false), None);
    };
    let Some((main, _)) = cx.update(main_window) else {
        return (ok("main window", false), None);
    };
    // ⌘I with the sidebar's keyboard on the folder (Get Info), then the
    // folder's context menu.
    // A step at a time, as a user presses the arrows: each chat the cursor
    // passes opens, and the list follows that before the next step.
    let step = |key: crate::views::sidebar_keys::ListKey, cx: &mut AsyncApp| {
        cx.update(|cx| {
            let view = cx.global::<AppState>().main_view.clone()?;
            let sidebar = view.read(cx).sidebar.clone();
            main.update(cx, |_, window, cx| {
                sidebar.update(cx, |s, cx| {
                    if !s.list_focus.is_focused(window) {
                        s.focus_list(window, cx);
                    }
                    s.key(key, cx);
                    s.cursor().cloned()
                })
            })
            .ok()
            .flatten()
        })
    };
    let target = crate::views::sidebar_keys::KeyRow::Folder(folder.clone());
    let mut at = step(crate::views::sidebar_keys::ListKey::Home, cx);
    for _ in 0..60 {
        settle(cx, 120).await;
        if at.as_ref() == Some(&target) {
            break;
        }
        at = step(crate::views::sidebar_keys::ListKey::Down, cx);
    }
    settle(cx, 400).await;
    let on_folder = cx.update(|cx| {
        let view = cx.global::<AppState>().main_view.clone()?;
        let sidebar = view.read(cx).sidebar.clone();
        main.update(cx, |_, window, cx| sidebar.read(cx).focused_folder(window))
            .ok()
            .flatten()
    });
    let on_folder = on_folder.as_deref() == Some(folder.as_str());
    pass &= ok("the sidebar's keyboard reaches the folder", on_folder);
    press(main, "cmd-i", cx);
    let info = wait_sheet::<FolderSettingsSheet>(cx, |s| s.settings.is_some()).await;
    pass &= ok(
        "⌘I on a selected folder opens its settings (Get Info)",
        info.is_some(),
    );
    in_sheet::<FolderSettingsSheet, _>(cx, |s, w, cx| {
        crate::views::sheet::SheetBody::cancel(s, w, cx)
    });
    pass &= ok("it closes untouched", wait_closed(cx).await);
    // Whatever opened instead, nothing is left down for the next step.
    cx.update(sheet::dismiss);
    let _ = wait_closed(cx).await;
    let id = folder.clone();
    cx.update(|cx| {
        let view = cx.global::<AppState>().main_view.clone();
        let _ = main.update(cx, |_, window, cx| {
            if let Some(view) = view {
                let sidebar = view.read(cx).sidebar.clone();
                sidebar.update(cx, |s, cx| {
                    s.run_folder(
                        &id,
                        crate::views::sidebar::FolderCommand::Settings,
                        window,
                        cx,
                    )
                });
            }
        });
    });
    let Some(_) = wait_sheet::<FolderSettingsSheet>(cx, |s| s.settings.is_some()).await else {
        return (ok("Folder Settings opens", false), None);
    };
    settle(cx, 600).await;
    pass &= ok("Folder Settings is a window sheet", attached(cx));
    shoot_main(dir, "folder-settings", cx).await;
    if let Some(handle) = cx.update(|cx| sheet::current_window(cx)) {
        let controls = ax(handle, "folder-settings", dir, cx).await;
        pass &= ok(
            "the icons are a radio group; Share Folder… and New Chat in Folder are there",
            has(&controls, "RadioButton", "Books")
                && has(&controls, "Button", "Share Folder")
                && has(&controls, "Button", "New Chat in Folder"),
        );
    }
    // The seeded knowledge base, as project knowledge.
    let base = rpc
        .call::<methods::ComposerKnowledge>(&conduit_protocol::KnowledgeQuery::default())
        .await
        .ok()
        .and_then(|l| l.items.into_iter().next());
    pass &= ok("the seeded knowledge base is listed", base.is_some());
    if let Some(base) = base.clone() {
        in_sheet::<FolderSettingsSheet, _>(cx, move |s, _, cx| {
            s.on_choice(
                &SettingsChoice {
                    menu: "folder-add-knowledge".into(),
                    value: format!("collection:{}", base.id),
                },
                cx,
            )
        });
    }
    let m = model.to_string();
    in_sheet::<FolderSettingsSheet, _>(cx, move |s, w, cx| {
        s.type_prompt("Answer only about bread.", w, cx);
        s.set_icon(Some("books".into()), cx);
        s.on_choice(
            &SettingsChoice {
                menu: "folder-add-model".into(),
                value: m,
            },
            cx,
        );
    });
    settle(cx, 400).await;
    shoot_main(dir, "folder-settings-edited", cx).await;
    in_sheet::<FolderSettingsSheet, _>(cx, |s, w, cx| s.save(w, cx));
    pass &= ok("Save closes Folder Settings", wait_closed(cx).await);
    let saved = rpc
        .call::<methods::FoldersGet>(&conduit_protocol::FolderRef {
            folder_id: folder.clone(),
        })
        .await;
    pass &= ok(
        "folders.get: the knowledge base is the folder's knowledge",
        saved.as_ref().is_ok_and(|f| {
            base.as_ref().is_some_and(|b| {
                f.knowledge
                    .iter()
                    .any(|k| k.id == b.id && k.r#type == "collection")
            })
        }),
    );
    let f = folder.clone();
    let icon = wait_until(cx, Duration::from_secs(20), move |cx| {
        cx.global::<AppState>()
            .stores
            .chat_list
            .read(cx)
            .folder(&f)
            .is_some_and(|f| f.icon.as_deref() == Some("📚"))
    })
    .await;
    pass &= ok("the sidebar's folder has its new icon", icon);
    shoot_main(dir, "sidebar-folder-icon", cx).await;

    // A new chat in the folder: its model and its prompt.
    let nav = cx.update(navigation);
    let f = folder.clone();
    nav.update(cx, |n, cx| n.new_chat_in_folder(f, cx));
    let want = model.to_string();
    let on_model = wait_until(cx, Duration::from_secs(20), move |cx| {
        pane(cx).is_some_and(|p| {
            p.read(cx).composer_store.read(cx).draft_model.as_deref() == Some(want.as_str())
        })
    })
    .await;
    pass &= ok(
        "a new chat in the folder starts on the folder's model",
        on_model,
    );
    let request = turn("Say the word: golf", log, cx).await;
    pass &= ok(
        &format!(
            "its request has the folder's prompt ({:?})",
            system_text(&request)
        ),
        system_text(&request).contains("Answer only about bread."),
    );
    pass &= ok(
        "and draws on the folder's knowledge (its scoped knowledge tools)",
        request
            .as_ref()
            .and_then(|r| r.get("tools"))
            .and_then(Value::as_array)
            .is_some_and(|tools| {
                let has = |n: &str| tools.iter().any(|t| t.as_str() == Some(n));
                has("list_knowledge") && !has("list_knowledge_bases")
            }),
    );
    pass &= ok(
        "and runs on the folder's model",
        request
            .as_ref()
            .and_then(|r| r.get("model"))
            .and_then(Value::as_str)
            .is_some_and(|m| m.ends_with(model)),
    );
    let chat_id = cx.update(|cx| chat_store(cx).map(|s| s.read(cx).chat_id().to_string()));
    if let Some(id) = chat_id.clone() {
        let mut filed = false;
        for _ in 0..30 {
            let contents = rpc
                .call::<methods::ChatsFolder>(&conduit_protocol::FolderRef {
                    folder_id: folder.clone(),
                })
                .await;
            if contents.is_ok_and(|c| c.chats.iter().any(|c| c.id == id)) {
                filed = true;
                break;
            }
            settle(cx, 1000).await;
        }
        pass &= ok(
            "the chat is filed in the folder from its first message",
            filed,
        );
    }
    // Put the folder back as the seed had it.
    let restored = rpc
        .call::<methods::FoldersUpdate>(&FolderUpdate {
            id: folder,
            name: None,
            icon: Some(String::new()),
            system_prompt: Some(String::new()),
            model_ids: Some(vec![]),
            knowledge: Some(vec![]),
        })
        .await;
    pass &= ok("the folder is put back", restored.is_ok());
    (pass, chat_id)
}

/// Share Folder: the seeded second user may edit it, then no one.
async fn share_folder(
    inputs: &E2eInputs,
    rpc: &crate::stores::rpc::Rpc,
    dir: &Path,
    cx: &mut AsyncApp,
) -> bool {
    let mut pass = true;
    let Some(second) = inputs.get("OWUI_SECOND_NAME") else {
        return ok("OWUI_SECOND_NAME in the env file (owui.sh reset)", false);
    };
    let Some(folder) = cx.update(|cx| folder_named("Recipes", cx)) else {
        return ok("the Recipes folder", false);
    };
    let Some((main, _)) = cx.update(main_window) else {
        return ok("main window", false);
    };
    let id = folder.clone();
    cx.update(|cx| {
        let view = cx.global::<AppState>().main_view.clone();
        let _ = main.update(cx, |_, window, cx| {
            if let Some(view) = view {
                let sidebar = view.read(cx).sidebar.clone();
                sidebar.update(cx, |s, cx| {
                    s.run_folder(&id, crate::views::sidebar::FolderCommand::Share, window, cx)
                });
            }
        });
    });
    let Some(_) = wait_sheet::<AccessSheet>(cx, |s| s.state.is_some()).await else {
        return ok("Share Folder opens the access sheet", false);
    };
    settle(cx, 500).await;
    pass &= ok("Share Folder is a window sheet", attached(cx));
    shoot_main(dir, "share-folder-empty", cx).await;
    let first = second.split(' ').next().unwrap_or(&second).to_string();
    in_sheet::<AccessSheet, _>(cx, move |s, _, cx| s.find(first, cx));
    let found = wait_until(cx, Duration::from_secs(15), |cx| {
        sheet_of::<AccessSheet>(cx)
            .is_some_and(|s| s.read(cx).results.iter().any(|p| p.r#type == "user"))
    })
    .await;
    pass &= ok("people are found by name", found);
    in_sheet::<AccessSheet, _>(cx, |s, w, cx| {
        if let Some(p) = s.results.iter().find(|p| p.r#type == "user").cloned() {
            s.add(&p, w, cx);
            let key = format!("user:{}", p.id);
            s.set_write(&key, true, cx);
        }
    });
    // And the seeded group, which may only read it.
    let group = inputs.get("OWUI_GROUP_NAME").unwrap_or_default();
    let listed = wait_until(cx, Duration::from_secs(15), |cx| {
        sheet_of::<AccessSheet>(cx)
            .is_some_and(|s| s.read(cx).results.iter().any(|p| p.r#type == "group"))
    })
    .await;
    pass &= ok("the account's groups are listed", listed);
    in_sheet::<AccessSheet, _>(cx, |s, w, cx| {
        if let Some(p) = s.results.iter().find(|p| p.r#type == "group").cloned() {
            s.add(&p, w, cx);
        }
    });
    settle(cx, 400).await;
    shoot_main(dir, "share-folder", cx).await;
    in_sheet::<AccessSheet, _>(cx, |s, w, cx| s.save(w, cx));
    pass &= ok("Save closes the access sheet", wait_closed(cx).await);
    let state = rpc
        .call::<methods::AccessGet>(&AccessRef {
            kind: AccessResourceKind::Folder,
            id: folder.clone(),
        })
        .await;
    pass &= ok(
        &format!("access.get: {second} may edit the folder"),
        state
            .as_ref()
            .is_ok_and(|s| s.grants.iter().any(|g| g.name == second && g.write)),
    );
    pass &= ok(
        &format!("and the group {group} may read it"),
        state.as_ref().is_ok_and(|s| {
            s.grants
                .iter()
                .any(|g| g.principal_type == "group" && g.name == group && !g.write)
        }),
    );
    // Unshared again.
    let cleared = rpc
        .call::<methods::AccessSet>(&AccessEdit {
            kind: AccessResourceKind::Folder,
            id: folder,
            grants: vec![],
            audience: None,
        })
        .await;
    pass &= ok(
        "and unshared again",
        cleared.is_ok_and(|s| s.grants.is_empty()),
    );
    pass
}
