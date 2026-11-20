//! `--e2e agents`: Open WebUI 0.13.3's coding agents as models, and model
//! controls, on the seeded server's fake Open Terminal (the "Build box",
//! whose `/agents` lists Codex and Claude Code; owui.sh).
//!
//! Signs in to the local Open WebUI as its admin and starts a chat with the
//! fake model. With the Build box chosen as the chats' terminal, the picker
//! lists its agents under Coding Agents, named "Agent · model" with the
//! terminal under each. Picking Codex selects it: the composer says the chat
//! is an agent's (no Regenerate, Retry, Edit or Compare Models, Chat ›
//! Regenerate off) and that the model brings its own reasoning effort (the
//! app's Reasoning Effort row gives way), and the picker draws one row per
//! control (Reasoning Effort, Service Tier). A pick is saved in the
//! account's settings and read back. Back on the fake model the chat's
//! actions return; with Codex selected again, turning the terminal off puts
//! the default model back. Screenshots in light and dark, and AccessKit.
//!
//! Not covered: a live agent turn. The stand-in terminal refuses the agent
//! session transport (`POST /agents/{agent}/sessions`), so no agent ever
//! answers here.

use std::path::Path;
use std::time::Duration;

use conduit_protocol::{ModelControlsQuery, SetModelControl, methods};
use gpui_kit::{App, AsyncApp, Entity};

use super::chat::{chat_store, in_pane, pane, send, sign_in, wait_answer, wait_models};
use super::composer::new_chat;
use super::{E2eInputs, NO_SERVER, ax, has, main_window, ok, settle, shoot_main, wait_until};
use crate::AppState;
use crate::stores::composer::{ComposerStore, PickerRow, picker_rows};

const TERMINAL: &str = "buildbox";
const CODEX: &str = "agent:buildbox:codex:gpt-5.1";
const CLAUDE: &str = "agent:buildbox:claude-code:sonnet";

fn composer(cx: &mut App) -> Option<Entity<ComposerStore>> {
    Some(pane(cx)?.read(cx).composer_store.clone())
}

fn selected_id(cx: &mut App) -> Option<String> {
    composer(cx)?.read(cx).models.as_ref()?.selected_id.clone()
}

/// Chooses the chats' terminal (None: none), as the composer's Terminal
/// section does.
async fn choose_terminal(server: Option<&str>, cx: &mut AsyncApp) -> bool {
    let stores = cx.update(|cx| cx.global::<AppState>().stores.clone());
    let rpc = cx.update(|cx| stores.connection.read(cx).rpc());
    let asked = cx.update(|cx| {
        crate::views::terminal::chat::select_server(&rpc, server.map(String::from), cx)
    });
    let Some(servers) = asked.await else {
        println!("SMOKE note terminal.select({server:?}) failed");
        return false;
    };
    let chosen = servers.selected_id.clone();
    println!("SMOKE note terminal.select({server:?}) answered {chosen:?}");
    cx.update(|cx| {
        stores
            .areas
            .update(cx, |a, cx| a.set_terminals(servers, cx))
    });
    chosen.as_deref() == server
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
    let first = model.clone();
    in_pane(cx, move |p, _, cx| {
        p.composer_store
            .update(cx, |c, cx| c.select_model(&first, cx))
    });
    settle(cx, 500).await;

    // Regenerate inline (Settings › Chat › Message Actions), so whether an
    // answer offers it reads from the row's own buttons.
    cx.update(|cx| {
        let app = cx.global::<AppState>().stores.app_settings.clone();
        app.update(cx, |s, cx| {
            s.set(
                conduit_protocol::AppSettingsPatch {
                    inline_message_actions: Some(vec!["copy".into(), "regenerate".into()]),
                    ..Default::default()
                },
                cx,
            )
        });
    });

    // ── A saved chat to offer agents in ────────────────────────────────
    new_chat(cx).await;
    send("Say the word: kestrel", cx).await;
    pass &= ok(
        "a chat with the fake model answered",
        wait_answer(cx, Duration::from_secs(60)).await,
    );
    let stored = wait_until(cx, Duration::from_secs(30), |cx| {
        chat_store(cx).is_some_and(|s| !s.read(cx).chat_id().starts_with("local:"))
    })
    .await;
    pass &= ok("the chat is saved on the server", stored);

    // ── The terminal's agents in the picker ────────────────────────────
    pass &= ok(
        "the Build box is the chats' terminal",
        choose_terminal(Some(TERMINAL), cx).await,
    );
    cx.update(|cx| {
        if let Some(c) = composer(cx) {
            c.update(cx, |c, cx| c.refresh_models(cx));
        }
    });
    let listed = wait_until(cx, Duration::from_secs(30), |cx| {
        composer(cx).is_some_and(|c| {
            c.read(cx).models.as_ref().is_some_and(|l| {
                [CODEX, CLAUDE]
                    .iter()
                    .all(|id| l.agents.iter().any(|a| a.id == *id))
            })
        })
    })
    .await;
    pass &= ok(
        "models.list offers the Build box's agents for the chat",
        listed,
    );
    let agents = cx
        .update(|cx| {
            composer(cx).and_then(|c| c.read(cx).models.as_ref().map(|l| l.agents.clone()))
        })
        .unwrap_or_default();
    let codex = agents.iter().find(|a| a.id == CODEX).cloned();
    pass &= ok(
        &format!(
            "Codex is named \"Agent · model\" and runs on the Build box ({:?})",
            codex.as_ref().map(|a| (&a.name, &a.agent))
        ),
        codex.as_ref().is_some_and(|a| {
            a.name == "Codex · gpt-5.1"
                && a.agent.as_ref().is_some_and(|g| {
                    g.terminal_id == TERMINAL
                        && g.terminal_name.as_deref() == Some("Build box")
                        && g.agent_name == "Codex"
                })
        }),
    );
    let rows = cx
        .update(|cx| {
            composer(cx).and_then(|c| {
                c.read(cx)
                    .models
                    .as_ref()
                    .map(|l| picker_rows(l, "", true, "Coding Agents"))
            })
        })
        .unwrap_or_default();
    let heading = rows
        .iter()
        .position(|r| matches!(r, PickerRow::Heading(h) if h == "Coding Agents"));
    pass &= ok(
        "More Models ends with the agents under Coding Agents",
        heading.is_some_and(|h| {
            rows[h + 1..]
                .iter()
                .all(|r| matches!(r, PickerRow::Model(m) if m.agent.is_some()))
                && rows.len() > h + 2
        }),
    );
    in_pane(cx, |p, window, cx| {
        p.composer.update(cx, |c, cx| {
            c.open_picker(window, cx);
            c.toggle_more_models(cx);
        })
    });
    settle(cx, 1500).await;
    shoot_main(dir, "agents-picker", cx).await;
    let controls = ax(main, "agents-picker", dir, cx).await;
    pass &= ok(
        "the agents are options in the picker's list",
        has(&controls, "ListBoxOption", "Codex · gpt-5.1")
            && has(&controls, "ListBoxOption", "Claude Code · sonnet"),
    );
    in_pane(cx, |p, window, cx| {
        p.composer.update(cx, |c, cx| c.close_picker(window, cx))
    });
    settle(cx, 300).await;

    // ── Picking an agent ───────────────────────────────────────────────
    in_pane(cx, |p, _, cx| {
        p.composer_store
            .update(cx, |c, cx| c.select_model(CODEX, cx))
    });
    let picked = wait_until(cx, Duration::from_secs(30), |cx| {
        selected_id(cx).as_deref() == Some(CODEX)
            && composer(cx).is_some_and(|c| {
                let c = c.read(cx);
                c.options.agent_chat
                    && c.options.own_effort_control
                    && !c.options.compare_models
                    && c.model_controls.as_ref().is_some_and(|m| {
                        m.model_id.as_deref() == Some(CODEX) && m.controls.len() == 2
                    })
            })
    })
    .await;
    pass &= ok(
        "Codex is selected: an agent's chat, with its own effort and two controls",
        picked,
    );
    let shown = cx
        .update(|cx| composer(cx).map(|c| c.read(cx).model_options.clone()))
        .flatten();
    pass &= ok(
        "the app's Reasoning Effort is not offered for it",
        shown.is_none_or(|o| !o.reasoning.visible),
    );
    let keys = cx
        .update(|cx| {
            composer(cx).and_then(|c| {
                c.read(cx).model_controls.as_ref().map(|m| {
                    m.controls
                        .iter()
                        .map(|c| (c.key.clone(), c.value.clone()))
                        .collect::<Vec<_>>()
                })
            })
        })
        .unwrap_or_default();
    pass &= ok(
        &format!("its controls are the effort (Medium by default) and the tier ({keys:?})"),
        keys.first()
            .is_some_and(|(k, v)| k == "reasoning_effort" && v.as_deref() == Some("medium"))
            && keys.get(1).is_some_and(|(k, _)| k == "service_tier"),
    );
    in_pane(cx, |p, window, cx| {
        p.composer.update(cx, |c, cx| c.open_picker(window, cx))
    });
    settle(cx, 1500).await;
    shoot_main(dir, "agents-controls", cx).await;
    let controls = ax(main, "agents-controls", dir, cx).await;
    let effort_rows = controls
        .iter()
        .filter(|c| c.starts_with("Button:Reasoning Effort:"))
        .count();
    pass &= ok(
        &format!("one Reasoning Effort row, the agent's ({effort_rows})"),
        effort_rows == 1 && has(&controls, "Button", "Reasoning Effort: Medium"),
    );
    pass &= ok(
        "a Service Tier row",
        has(&controls, "Button", "Service Tier:"),
    );
    in_pane(cx, |p, window, cx| {
        p.composer.update(cx, |c, cx| c.close_picker(window, cx))
    });

    // ── A pick, saved in the account's settings ────────────────────────
    in_pane(cx, |p, _, cx| {
        p.composer_store.update(cx, |c, cx| {
            c.set_model_control("service_tier", "priority", cx)
        })
    });
    let rpc = cx.update(|cx| cx.global::<AppState>().stores.connection.read(cx).rpc());
    let saved = rpc
        .call::<methods::ModelsSetControl>(&SetModelControl {
            model_id: Some(CODEX.into()),
            chat_id: None,
            key: "reasoning_effort".into(),
            value: Some("high".into()),
        })
        .await;
    pass &= ok(
        &format!(
            "models.setControl saves a pick ({:?})",
            saved.as_ref().err()
        ),
        saved.is_ok(),
    );
    settle(cx, 800).await;
    let read = rpc
        .call::<methods::ModelsControls>(&ModelControlsQuery {
            model_id: Some(CODEX.into()),
            chat_id: None,
        })
        .await
        .ok();
    let values = read
        .map(|l| {
            l.controls
                .into_iter()
                .map(|c| (c.key, c.value))
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();
    pass &= ok(
        &format!("both picks read back ({values:?})"),
        values.contains(&("reasoning_effort".into(), Some("high".into())))
            && values.contains(&("service_tier".into(), Some("priority".into()))),
    );
    let refused = rpc
        .call::<methods::ModelsSetControl>(&SetModelControl {
            model_id: Some(CODEX.into()),
            chat_id: None,
            key: "reasoning_effort".into(),
            value: Some("ludicrous".into()),
        })
        .await;
    pass &= ok("an option the control lacks is refused", refused.is_err());

    // ── An agent's chat takes no Regenerate, Retry, Edit or Compare ────
    cx.update(|cx| {
        if let Some(c) = composer(cx) {
            c.update(cx, |c, cx| c.refresh_model_controls(cx));
        }
    });
    settle(cx, 1200).await;
    let controls = ax(main, "agents-chat", dir, cx).await;
    pass &= ok(
        "the answer offers Copy but no Regenerate",
        has(&controls, "Button", "Copy") && !has(&controls, "Button", "Regenerate"),
    );
    pass &= ok(
        "Chat › Regenerate does not apply",
        cx.update(|cx| pane(cx).is_some_and(|p| p.read(cx).agent_chat(cx))),
    );
    shoot_main(dir, "agents-chat", cx).await;

    // ── Back on the fake model, the actions return ─────────────────────
    let back = model.clone();
    in_pane(cx, move |p, _, cx| {
        p.composer_store
            .update(cx, |c, cx| c.select_model(&back, cx))
    });
    let plain = wait_until(cx, Duration::from_secs(30), {
        let model = model.clone();
        move |cx| {
            selected_id(cx).as_deref() == Some(model.as_str())
                && composer(cx).is_some_and(|c| {
                    let c = c.read(cx);
                    !c.options.agent_chat && !c.options.own_effort_control
                })
        }
    })
    .await;
    pass &= ok("the fake model again: not an agent's chat", plain);
    settle(cx, 1200).await;
    let controls = ax(main, "agents-chat-model", dir, cx).await;
    pass &= ok(
        "the answer offers Regenerate again",
        has(&controls, "Button", "Regenerate"),
    );

    // ── Turning the terminal off puts the default back ─────────────────
    in_pane(cx, |p, _, cx| {
        p.composer_store
            .update(cx, |c, cx| c.select_model(CODEX, cx))
    });
    // The daemon's answer, not the picker's own mark: the composer asks for
    // its options once `models.select` is through.
    let again = wait_until(cx, Duration::from_secs(30), |cx| {
        selected_id(cx).as_deref() == Some(CODEX)
            && composer(cx).is_some_and(|c| {
                let c = c.read(cx);
                c.options.agent_chat
                    && c.model_controls
                        .as_ref()
                        .is_some_and(|m| m.model_id.as_deref() == Some(CODEX))
            })
    })
    .await;
    settle(cx, 500).await;
    pass &= ok("Codex is selected again", again);
    pass &= ok(
        "the terminal is turned off",
        choose_terminal(None, cx).await,
    );
    let restored = wait_until(cx, Duration::from_secs(30), |cx| {
        selected_id(cx).is_some_and(|id| !id.starts_with("agent:"))
            && composer(cx).is_some_and(|c| {
                c.read(cx)
                    .models
                    .as_ref()
                    .is_some_and(|l| l.agents.is_empty())
            })
    })
    .await;
    pass &= ok(
        &format!(
            "without its terminal the agent gives way to the default model ({:?})",
            cx.update(selected_id)
        ),
        restored,
    );
    println!("SMOKE e2e skip a live agent turn: the stand-in terminal runs no agent session");
    pass
}
