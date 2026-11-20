//! `--e2e hermes-cards`: a Hermes agent's cards, over the real daemon,
//! on a real local Hermes Desktop Gateway (`hermes serve` from
//! `hermes-src`) whose model is scripted: each message's keyword makes the
//! agent call the tools that raise one card. The env file
//! (`--e2e-env`) names the gateway (`HERMES_DESKTOP_URL`) and its session
//! token (`HERMES_DESKTOP_TOKEN`).
//!
//! * Hermes-only with the Desktop Gateway (a legacy session token).
//! * **The plan:** the agent's task list over the composer, its progress
//!   moving on, folded and unfolded.
//! * **A clarify form:** five questions on one card (a choice, several
//!   choices, own words, a skip), sent with one Send Response; the agent's
//!   reply has the answers.
//! * **A secret** typed masked and sent (and gone from the field), and a
//!   **sudo password** (the gateway's `sudo` is a harmless shell function).
//! * **A paid tool's approval** with its cost chips, allowed once.
//! * **Changed files:** the card with its counts and the path from the
//!   working directory, and the file's diff sheet.
//! * **Background work:** a subagent and a process on the chip; the sheet
//!   reads the subagent's output, steers it and stops it, and kills the
//!   process.
//! * **A failure's card:** a rate limit with its reset time, and Retry.
//! * **Context & Usage** from the Chat menu's action: the window, what fills
//!   it, the totals with the cache, and Compact Now.
//!
//! Each card is shot in light and dark.

use std::path::Path;
use std::time::Duration;

use conduit_protocol::{HermesSettingsEdit, MessageBlockKind, UiRequestKind, methods};
use gpui_kit::{App, AsyncApp};

use super::chat::{chat_store, in_pane, send};
use super::composer::new_chat;
use super::*;
use crate::stores::ui_requests::{Card, card};
use crate::views::approvals::ApprovalsView;
use crate::views::hermes_context_sheet::ContextSheet;
use crate::views::hermes_diff_sheet::DiffSheet;
use crate::views::hermes_work_sheet::BackgroundWorkSheet;
use crate::views::sheet;

fn work(cx: &mut App) -> Option<conduit_protocol::HermesWork> {
    let store = chat_store(cx)?;
    let hermes = store.read(cx).hermes.clone();
    hermes.read(cx).work.clone()
}

fn top_request(cx: &mut App) -> Option<conduit_protocol::UiRequest> {
    cx.global::<AppState>()
        .stores
        .ui_requests
        .read(cx)
        .top()
        .cloned()
}

fn approvals(cx: &mut App) -> Option<Entity<ApprovalsView>> {
    Some(main_window(cx)?.1.read(cx).approvals.clone())
}

fn in_approvals<R>(
    cx: &mut AsyncApp,
    f: impl FnOnce(&mut ApprovalsView, &mut Window, &mut gpui_kit::Context<ApprovalsView>) -> R,
) -> Option<R> {
    in_main(cx, |mw, window, cx| {
        let view = mw.approvals.clone();
        view.update(cx, |v, cx| f(v, window, cx))
    })
}

/// The newest answer's blocks, as the store holds them.
fn last_blocks(cx: &mut App) -> Vec<conduit_protocol::MessageBlockDto> {
    let Some(store) = chat_store(cx) else {
        return vec![];
    };
    let s = store.read(cx);
    s.rows()
        .iter()
        .rev()
        .filter_map(|r| s.item(*r))
        .find(|i| i.role == crate::stores::chat::Role::Assistant)
        .map(|i| i.blocks)
        .unwrap_or_default()
}

fn last_text(cx: &mut App) -> String {
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

/// The open chat's newest turn has ended and its answer has words. Not
/// that the stored copy has settled under it: a Hermes session's stored rows
/// (one per tool step) can stand beside the live answer.
async fn wait_answer(cx: &mut AsyncApp, timeout: Duration) -> bool {
    wait_until(cx, timeout, |cx| {
        chat_store(cx).is_some_and(|s| {
            let s = s.read(cx);
            !s.is_streaming()
                && s.live.as_ref().is_none_or(|l| !l.streaming())
                && s.rows()
                    .iter()
                    .rev()
                    .filter_map(|r| s.item(*r))
                    .find(|i| i.role == crate::stores::chat::Role::Assistant)
                    .is_some_and(|i| !i.text.trim().is_empty())
        })
    })
    .await
}

async fn wait_request(
    kind: UiRequestKind,
    cx: &mut AsyncApp,
) -> Option<conduit_protocol::UiRequest> {
    let found = wait_until(cx, Duration::from_secs(60), move |cx| {
        top_request(cx).is_some_and(|r| r.kind == kind)
    })
    .await;
    if !found {
        return None;
    }
    let request = cx.update(top_request)?;
    // The card draws it before a field is filled: its first draw of a new
    // request clears the card's fields (under load the store has a request
    // a frame or more before the card does).
    let id = request.request_id.clone();
    wait_until(cx, Duration::from_secs(10), move |cx| {
        cx.try_global::<crate::AppState>()
            .and_then(|s| s.main_view.clone())
            .is_some_and(|mw| mw.read(cx).approvals.read(cx).drawn_for() == Some(id.as_str()))
    })
    .await;
    Some(request)
}

async fn wait_no_request(cx: &mut AsyncApp) -> bool {
    wait_until(cx, Duration::from_secs(60), |cx| top_request(cx).is_none()).await
}

async fn shoot_sheet(dir: &Path, name: &str, cx: &mut AsyncApp) {
    if let Some(handle) = cx.update(|cx| sheet::current_window(cx)) {
        shoot_both_modes(handle, dir, name, cx).await;
    }
}

async fn close_sheet(cx: &mut AsyncApp) -> bool {
    cx.update(sheet::dismiss);
    wait_until(cx, Duration::from_secs(20), |cx| !sheet::is_open(cx)).await
}

/// Sends `text` in a new chat once the last one is done.
async fn ask(text: &str, cx: &mut AsyncApp) {
    send(text, cx).await;
    settle(cx, 400).await;
}

pub async fn run(inputs: &E2eInputs, dir: &Path, cx: &mut AsyncApp) -> bool {
    let (Some(url), Some(token)) = (
        inputs.get("HERMES_DESKTOP_URL"),
        inputs.get("HERMES_DESKTOP_TOKEN"),
    ) else {
        return ok(
            "the Hermes gateway's env file is there (hermes.sh env)",
            false,
        );
    };
    let mut pass = fresh_profile(cx).await;

    // Hermes Desktop Gateway, with the gateway's legacy session token, as
    // onboarding's choice (the token never shows).
    let rpc = cx.update(|cx| cx.global::<AppState>().stores.connection.read(cx).rpc());
    let saved = rpc
        .call::<methods::HermesSaveSettings>(&HermesSettingsEdit {
            enabled: true,
            base_url: url,
            mode: "desktop".into(),
            api_key: None,
            session_key: None,
            desktop_profile: "default".into(),
            desktop_auth_kind: "legacyToken".into(),
            legacy_token: Some(token),
            allow_self_signed_certificates: false,
            onboarding: true,
        })
        .await;
    pass &= ok("Hermes Desktop Gateway saved", saved.is_ok());
    pass &= wait_route(cx, Route::Main, Duration::from_secs(60)).await;
    pass &= ok("the main window opened", wait_main(cx).await.is_some());
    settle(cx, 1500).await;

    pass &= plan(dir, cx).await;
    pass &= call_over_cards(dir, cx).await;
    pass &= clarify(dir, cx).await;
    pass &= secrets(dir, cx).await;
    pass &= paid_approval(dir, cx).await;
    pass &= diff(dir, cx).await;
    pass &= background(dir, cx).await;
    pass &= processes(dir, cx).await;
    pass &= failure(dir, cx).await;
    pass &= context(dir, cx).await;
    pass
}

async fn plan(dir: &Path, cx: &mut AsyncApp) -> bool {
    new_chat(cx).await;
    ask("Make a plan for the demo", cx).await;
    let first = wait_until(cx, Duration::from_secs(60), |cx| {
        work(cx)
            .and_then(|w| w.plan)
            .is_some_and(|p| p.items.len() == 3)
    })
    .await;
    if !first {
        // What the window knew, for the log.
        let state = cx.update(|cx| {
            chat_store(cx).map(|s| {
                let s = s.read(cx);
                let h = s.hermes.read(cx);
                format!(
                    "chat {} abilities {:?} watching {} work {:?}",
                    s.chat_id(),
                    s.detail.as_ref().map(|d| d.abilities.clone()),
                    h.watching(),
                    h.work
                )
            })
        });
        println!("SMOKE e2e note {state:?}");
    }
    let mut pass = ok("the plan card has the agent's three items", first);
    let moved = wait_until(cx, Duration::from_secs(60), |cx| {
        work(cx).and_then(|w| w.plan).is_some_and(|p| p.done == 2)
    })
    .await;
    pass &= ok("the plan's progress moves on (2 of 3 done)", moved);
    pass &= ok(
        "the reply ends",
        wait_answer(cx, Duration::from_secs(60)).await,
    );
    // Unfolded while something is still under way.
    let chat_id = cx.update(|cx| chat_store(cx).map(|s| s.read(cx).chat_id().to_string()));
    let Some(chat_id) = chat_id else {
        return ok("a Hermes chat is open", false);
    };
    pass &= ok(
        "the chat is a Hermes session",
        chat_id.starts_with("local:hermes_"),
    );
    let active = cx.update(|cx| work(cx).and_then(|w| w.plan).is_some_and(|p| p.active));
    let folded = cx.update(|cx| crate::stores::hermes_work::plan_folded(&chat_id, active, cx));
    pass &= ok("the plan shows open while a step is under way", !folded);
    shoot_main(dir, "hermes-plan", cx).await;
    let id = chat_id.clone();
    cx.update(|cx| crate::stores::hermes_work::set_plan_folded(&id, true, cx));
    in_pane(cx, |_, _, cx| cx.notify());
    settle(cx, 400).await;
    shoot_main(dir, "hermes-plan-folded", cx).await;
    let id = chat_id.clone();
    pass &= ok(
        "folding keeps for the chat",
        cx.update(|cx| crate::stores::hermes_work::plan_folded(&id, true, cx)),
    );
    pass
}

/// A voice call in the plan's Hermes chat: the call button is ready (the
/// core admits a Hermes model while its connection is usable), and the
/// call's strip takes the composer's place with the plan card still docked
/// above it. Nothing transcribes in a Hermes-only setup (the server's
/// engine is Open WebUI's), so the call stops at its first listen and the
/// strip says why. A silent stand-in and the server's engine keep the Mac's
/// microphone and recognizer (and their prompts) out of it.
async fn call_over_cards(dir: &Path, cx: &mut AsyncApp) -> bool {
    use crate::l10n::ActiveL10n as _;
    use crate::voice::InputOverride;
    use conduit_protocol::{AppSettingsPatch, VoiceSettingsEdit};

    let quiet = dir.join("hermes-call-quiet.wav");
    let silence = vec![0u8; crate::voice::pcm::BYTES_PER_SECOND * 2];
    let mut pass = ok(
        "a silent stand-in for the microphone",
        std::fs::write(&quiet, crate::voice::pcm::wav(&silence)).is_ok(),
    );
    let call = cx.update(|cx| cx.global::<AppState>().stores.call.clone());
    call.update(cx, |c, cx| {
        c.set_input(Some(InputOverride::File(quiet.clone())), cx)
    });
    pass &= ok(
        "Settings › Audio: the server transcribes",
        super::dictation::save_voice(
            VoiceSettingsEdit {
                stt_engine: Some("server".into()),
                ..Default::default()
            },
            cx,
        )
        .await,
    );
    super::dictation::set_settings(
        AppSettingsPatch {
            stt_preference: Some("serverOnly".into()),
            ..Default::default()
        },
        cx,
    )
    .await;
    let ready = wait_until(cx, Duration::from_secs(20), |cx| {
        main_window(cx).is_some_and(|(_, mw)| {
            let composer = mw.read(cx).chat_pane.read(cx).composer.clone();
            composer.read(cx).call_ready
        })
    })
    .await;
    pass &= ok(
        "a Hermes chat offers a voice call (the core admits Hermes)",
        ready,
    );
    in_pane(cx, |p, _, cx| p.start_call(cx));
    let shown = wait_until(cx, Duration::from_secs(20), |cx| {
        let call = cx.global::<AppState>().stores.call.read(cx);
        call.is_shown() && call.state().mode == Some(conduit_protocol::CallMode::Standard)
    })
    .await;
    pass &= ok("the call is a Standard one", shown);
    settle(cx, 800).await;
    let Some(main) = wait_main(cx).await else {
        return ok("main window", false);
    };
    let controls = ax(main, "hermes-call", dir, cx).await;
    // The plan card's header (folded or not) and the strip's controls; no
    // composer's call button.
    let (show, hide) = cx.update(|cx| (cx.l10n().hermes_plan_show(), cx.l10n().hermes_plan_hide()));
    let plan = has(&controls, "Button", &show) || has(&controls, "Button", &hide);
    let strip = has(&controls, "Button", "End Call") || has(&controls, "Button", "Dismiss");
    pass &= ok(
        "the call's strip stands where the composer was, the plan card docked above it",
        strip && plan && !has(&controls, "Button", "Start Voice Call"),
    );
    shoot_main(dir, "hermes-call-over-plan", cx).await;
    // Ended (and a failed one dismissed): the composer is back.
    for _ in 0..2 {
        call.update(cx, |c, cx| {
            if c.is_shown() {
                c.end(cx)
            }
        });
        settle(cx, 600).await;
    }
    pass &= ok(
        "the call is over and the composer back",
        wait_until(cx, Duration::from_secs(15), |cx| {
            !cx.global::<AppState>().stores.call.read(cx).is_shown()
        })
        .await,
    );
    pass
}

async fn clarify(dir: &Path, cx: &mut AsyncApp) -> bool {
    ask("Pick a menu for the demo", cx).await;
    let Some(request) = wait_request(UiRequestKind::HermesClarify, cx).await else {
        return ok("a clarify form docks over the composer", false);
    };
    let Card::HermesClarify { questions, .. } = card(&request) else {
        return ok("the form reads as a clarify card", false);
    };
    let mut pass = ok("the form asks five questions", questions.len() == 5);
    pass &= ok(
        "the first choice is marked recommended, without the label",
        questions[0]
            .choices
            .first()
            .is_some_and(|c| c.recommended && !c.label.contains("Recommended")),
    );
    pass &= ok("the second question takes several", questions[1].multi);
    settle(cx, 500).await;
    shoot_main(dir, "hermes-clarify", cx).await;
    // A choice; two choices; a choice; own words; a skip.
    let q = questions.clone();
    in_approvals(cx, move |v, window, cx| {
        v.pick(0, q[0].choices[1].value.clone(), window, cx);
        v.pick(1, q[1].choices[1].value.clone(), window, cx);
        v.pick(1, q[1].choices[2].value.clone(), window, cx);
        v.pick(2, q[2].choices[1].value.clone(), window, cx);
        if let Some(input) = v.clarify_input(&q[3].id) {
            input.update(cx, |i, cx| i.set_value("No nuts, please", window, cx));
        }
        v.skip(4, cx);
    });
    settle(cx, 400).await;
    shoot_main(dir, "hermes-clarify-answered", cx).await;
    let sent = in_approvals(cx, |v, _, cx| v.allow(cx)).unwrap_or(false);
    pass &= ok(
        "Send Response sends once every question is answered or skipped",
        sent,
    );
    pass &= ok(
        "the form goes once Hermes has the answers",
        wait_no_request(cx).await,
    );
    pass &= ok(
        "the reply ends",
        wait_answer(cx, Duration::from_secs(60)).await,
    );
    let text = cx.update(last_text);
    pass &= ok(
        "the agent got every answer and the skip",
        text.contains("Japanese")
            && text.contains("Main")
            && text.contains("Dessert")
            && text.contains("No nuts")
            && text.contains("skipped"),
    );
    pass
}

async fn secrets(dir: &Path, cx: &mut AsyncApp) -> bool {
    ask("Set up the weather key", cx).await;
    let Some(request) = wait_request(UiRequestKind::HermesSecret, cx).await else {
        return ok("a secret request docks over the composer", false);
    };
    let mut pass = ok(
        "the request says what it is for",
        request
            .message_args
            .get("prompt")
            .is_some_and(|p| p.contains("Weather")),
    );
    in_approvals(cx, |v, window, cx| {
        let input = v.secret_input();
        input.update(cx, |i, cx| i.set_value("synthetic-weather-key", window, cx));
    });
    settle(cx, 400).await;
    shoot_main(dir, "hermes-secret", cx).await;
    let sent = in_approvals(cx, |v, _, cx| v.allow(cx)).unwrap_or(false);
    pass &= ok("Send Response sends the secret", sent);
    pass &= ok(
        "the card goes once Hermes has it",
        wait_no_request(cx).await,
    );
    // The next frame empties it.
    settle(cx, 300).await;
    let emptied = cx.update(|cx| {
        approvals(cx).is_some_and(|v| v.read(cx).secret_input().read(cx).value().is_empty())
    });
    pass &= ok("the secret is not kept in the field", emptied);
    pass &= ok(
        "the reply ends",
        wait_answer(cx, Duration::from_secs(60)).await,
    );

    ask("Elevate this harmless demo command", cx).await;
    let Some(request) = wait_request(UiRequestKind::HermesSudo, cx).await else {
        return ok("a sudo request docks over the composer", false) && pass;
    };
    pass &= ok(
        "the sudo card asks for a password",
        matches!(card(&request), Card::HermesSecret { sudo: true, .. }),
    );
    in_approvals(cx, |v, window, cx| {
        let input = v.secret_input();
        input.update(cx, |i, cx| i.set_value("synthetic-pass", window, cx));
    });
    settle(cx, 300).await;
    shoot_main(dir, "hermes-sudo", cx).await;
    in_approvals(cx, |v, _, cx| v.allow(cx));
    pass &= ok(
        "the sudo card goes once Hermes has it",
        wait_no_request(cx).await,
    );
    pass &= ok(
        "the reply ends",
        wait_answer(cx, Duration::from_secs(60)).await,
    );
    pass &= ok(
        "the command ran with the password read (and nothing elevated)",
        cx.update(last_text).contains("PRIVILEGED-DEMO"),
    );
    pass
}

async fn paid_approval(dir: &Path, cx: &mut AsyncApp) -> bool {
    ask("Make a poster for the fair", cx).await;
    let Some(request) = wait_request(UiRequestKind::HermesDecision, cx).await else {
        return ok("a paid tool's approval docks over the composer", false);
    };
    let Card::Hermes { cost, choices, .. } = card(&request) else {
        return ok("the approval reads as a Hermes approval", false);
    };
    let mut pass = ok(
        "the approval carries the tool's cost",
        cost.as_ref()
            .is_some_and(|c| c.price.as_deref() == Some("5 credits") && c.limit.is_some()),
    );
    pass &= ok(
        "Hermes offers once, session, always and deny",
        choices.len() == 4,
    );
    settle(cx, 400).await;
    shoot_main(dir, "hermes-approval-cost", cx).await;
    let allowed = in_approvals(cx, |v, _, cx| v.allow(cx)).unwrap_or(false);
    pass &= ok("Allow Once answers", allowed);
    pass &= ok("the approval goes", wait_no_request(cx).await);
    pass &= ok(
        "the reply ends",
        wait_answer(cx, Duration::from_secs(60)).await,
    );
    pass &= ok(
        "the paid tool ran",
        cx.update(last_text).contains("poster is ready"),
    );
    pass
}

async fn diff(dir: &Path, cx: &mut AsyncApp) -> bool {
    let stamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or_default();
    ask(&format!("Please edit notes {stamp}"), cx).await;
    let mut pass = ok(
        "the reply ends",
        wait_answer(cx, Duration::from_secs(90)).await,
    );
    let found = wait_until(cx, Duration::from_secs(20), |cx| {
        last_blocks(cx)
            .iter()
            .any(|b| b.kind == MessageBlockKind::ChangedFiles)
    })
    .await;
    pass &= ok("the reply lists the file its tools changed", found);
    let files = cx.update(|cx| {
        last_blocks(cx)
            .into_iter()
            .find(|b| b.kind == MessageBlockKind::ChangedFiles)
            .and_then(|b| b.changed_files)
            .unwrap_or_default()
    });
    let name = format!("notes-{stamp}.md");
    pass &= ok(
        "one file, written then edited, with its counts",
        files.len() == 1 && files[0].path.ends_with(&name) && files[0].added >= 1,
    );
    let directory = cx.update(|cx| work(cx).and_then(|w| w.working_directory));
    let shown = files
        .first()
        .map(|f| crate::views::chat::hermes_blocks::display_path(&f.path, directory.as_deref()));
    pass &= ok(
        "the file is listed from the chat's working directory",
        shown.as_deref() == Some(format!("demo/{name}").as_str()),
    );
    shoot_main(dir, "hermes-changed-files", cx).await;
    let opened = in_main(cx, move |_, window, cx| {
        crate::views::hermes_diff_sheet::open(files, 0, directory, window, cx)
    });
    pass &= ok("the diff opens", opened.is_some());
    let down = wait_until(cx, Duration::from_secs(10), |cx| {
        sheet::current::<DiffSheet>(cx).is_some()
    })
    .await;
    pass &= ok("the diff is a sheet on the main window", down);
    settle(cx, 600).await;
    shoot_sheet(dir, "hermes-diff-sheet", cx).await;
    pass &= ok("the diff sheet closes", close_sheet(cx).await);
    pass
}

async fn background(dir: &Path, cx: &mut AsyncApp) -> bool {
    ask("Start a helper for the garden notes", cx).await;
    let running = wait_until(cx, Duration::from_secs(60), |cx| {
        work(cx).is_some_and(|w| w.subagents.iter().any(|s| s.running))
    })
    .await;
    let mut pass = ok("a running subagent shows on the chip", running);
    pass &= ok(
        "the reply ends",
        wait_answer(cx, Duration::from_secs(60)).await,
    );
    settle(cx, 400).await;
    shoot_main(dir, "hermes-work-chip", cx).await;
    let hermes = cx.update(|cx| chat_store(cx).map(|s| s.read(cx).hermes.clone()));
    let Some(hermes) = hermes else {
        return ok("the chat follows its work", false);
    };
    let h = hermes.clone();
    in_main(cx, move |_, window, cx| {
        crate::views::hermes_work_sheet::open(h, window, cx)
    });
    let down = wait_until(cx, Duration::from_secs(10), |cx| {
        sheet::current::<BackgroundWorkSheet>(cx).is_some()
    })
    .await;
    pass &= ok("Background Work opens as a sheet", down);
    settle(cx, 600).await;
    shoot_sheet(dir, "hermes-work-sheet", cx).await;
    let subagent = cx.update(|cx| {
        work(cx).and_then(|w| w.subagents.iter().find(|s| s.running).map(|s| s.id.clone()))
    });
    let Some(subagent) = subagent else {
        close_sheet(cx).await;
        return ok("the sheet lists the subagent", false) && pass;
    };
    // Its output, read with the work.
    let sheet_view = cx.update(|cx| sheet::current::<BackgroundWorkSheet>(cx));
    let Some(sheet_view) = sheet_view else {
        close_sheet(cx).await;
        return ok("the sheet is there", false) && pass;
    };
    let id = subagent.clone();
    let handle = cx.update(|cx| sheet::current_window(cx));
    if let Some(handle) = handle {
        let view = sheet_view.clone();
        let _ = cx.update(|cx| {
            handle.update(cx, |_, window, cx| {
                view.update(cx, |v, cx| v.show_subagent(Some(id), window, cx))
            })
        });
    }
    let reading = wait_until(cx, Duration::from_secs(20), |cx| {
        work(cx).and_then(|w| w.output).is_some_and(|o| o.loaded)
    })
    .await;
    pass &= ok("the subagent's output is read", reading);
    settle(cx, 500).await;
    shoot_sheet(dir, "hermes-subagent", cx).await;
    // Steer it, then stop it, as the sheet does.
    let steer = cx.update(|cx| hermes.read(cx).steer(&subagent, "Only the north beds"));
    let steered = steer.await;
    pass &= ok(
        "a steer is queued for the running subagent",
        steered.is_ok_and(|r| r.ok),
    );
    let stop = cx.update(|cx| hermes.read(cx).stop(&subagent));
    let stopped = stop.await;
    pass &= ok("Stop Agent stops it", stopped.is_ok_and(|r| r.ok));
    let gone = wait_until(cx, Duration::from_secs(60), |cx| {
        work(cx).is_some_and(|w| !w.subagents.iter().any(|s| s.running))
    })
    .await;
    pass &= ok("the subagent no longer runs", gone);
    pass &= ok("Background Work closes", close_sheet(cx).await);
    // Let the helper's result turn settle before the next message.
    let _ = wait_answer(cx, Duration::from_secs(60)).await;
    settle(cx, 3000).await;
    pass
}

async fn processes(dir: &Path, cx: &mut AsyncApp) -> bool {
    let mut pass = true;
    let hermes = cx.update(|cx| chat_store(cx).map(|s| s.read(cx).hermes.clone()));
    let Some(hermes) = hermes else {
        return ok("the chat follows its work", false);
    };
    ask("Run a background job", cx).await;
    let process = wait_until(cx, Duration::from_secs(60), |cx| {
        work(cx).is_some_and(|w| w.processes.iter().any(|p| p.running))
    })
    .await;
    pass &= ok("a running process shows on the chip", process);
    pass &= ok(
        "the reply ends",
        wait_answer(cx, Duration::from_secs(60)).await,
    );
    shoot_main(dir, "hermes-work-process", cx).await;
    let process = cx.update(|cx| {
        work(cx).and_then(|w| w.processes.iter().find(|p| p.running).map(|p| p.id.clone()))
    });
    if let Some(process) = process {
        let kill = cx.update(|cx| hermes.read(cx).kill(&process));
        let killed = kill.await;
        pass &= ok(
            "Kill Process kills it",
            killed.is_ok_and(|r| r.status == conduit_protocol::HermesProcessKillStatus::Killed),
        );
        let gone = wait_until(cx, Duration::from_secs(30), |cx| {
            work(cx).is_some_and(|w| !w.processes.iter().any(|p| p.running))
        })
        .await;
        pass &= ok("the chip goes once nothing runs", gone);
    } else {
        pass &= ok("the process is listed", false);
    }
    pass
}

async fn failure(dir: &Path, cx: &mut AsyncApp) -> bool {
    ask("err-ratelimit for the demo", cx).await;
    let carded = wait_until(cx, Duration::from_secs(60), |cx| {
        last_blocks(cx).iter().any(|b| b.hermes_error.is_some())
    })
    .await;
    let mut pass = ok("the failure has a card", carded);
    let error = cx.update(|cx| last_blocks(cx).into_iter().find_map(|b| b.hermes_error));
    pass &= ok(
        "a rate limit, with its reset time and Retry",
        error.as_ref().is_some_and(|e| {
            e.kind == "rateLimit"
                && e.resets_at_ms.is_some()
                && e.actions.first().map(String::as_str) == Some("retry")
        }),
    );
    settle(cx, 600).await;
    shoot_main(dir, "hermes-error", cx).await;
    // Retry: the turn runs again (the scripted model answers this time).
    let key = cx.update(|cx| {
        chat_store(cx).and_then(|s| {
            let s = s.read(cx);
            s.rows()
                .iter()
                .rev()
                .filter_map(|r| s.item(*r))
                .find(|i| i.role == crate::stores::chat::Role::Assistant)
                .map(|i| i.key.clone())
        })
    });
    if let Some(key) = key {
        if let Some(store) = cx.update(chat_store) {
            store.update(cx, |s, cx| s.regenerate(&key, None, cx));
        }
        let fixed = wait_until(cx, Duration::from_secs(90), |cx| {
            cx_text_has(cx, "went through")
        })
        .await;
        if !fixed {
            // What the window shows, and what the daemon has, for the log.
            let (shown, chat_id) = cx.update(|cx| {
                chat_store(cx).map_or((vec![], String::new()), |s| {
                    let s = s.read(cx);
                    let shown: Vec<String> = s
                        .rows()
                        .iter()
                        .filter_map(|r| s.item(*r))
                        .map(|i| {
                            format!(
                                "{:?}:{}:{}",
                                i.role,
                                i.key.chars().take(8).collect::<String>(),
                                i.text.chars().take(40).collect::<String>()
                            )
                        })
                        .collect();
                    (shown, s.chat_id().to_string())
                })
            });
            println!("SMOKE e2e note retry key {key} shown {shown:?}");
            let rpc = cx.update(|cx| cx.global::<AppState>().stores.connection.read(cx).rpc());
            if let Ok(result) = rpc
                .call::<methods::ChatsGet>(&conduit_protocol::ChatRef { id: chat_id })
                .await
            {
                let got: Vec<String> = result
                    .chat
                    .map(|d| {
                        d.messages
                            .iter()
                            .map(|m| {
                                format!(
                                    "{:?}:{}:{}",
                                    m.role,
                                    m.id.chars().take(8).collect::<String>(),
                                    m.content.chars().take(40).collect::<String>()
                                )
                            })
                            .collect()
                    })
                    .unwrap_or_default();
                println!("SMOKE e2e note retry chats.get {got:?}");
            }
        }
        pass &= ok("Retry answers this time", fixed);
    }
    pass
}

fn cx_text_has(cx: &mut App, needle: &str) -> bool {
    last_text(cx).contains(needle)
}

async fn context(dir: &Path, cx: &mut AsyncApp) -> bool {
    let offered =
        cx.update(|cx| super::chat::pane(cx).is_some_and(|p| p.read(cx).hermes_context(cx)));
    let mut pass = ok("Context & Usage is offered for the Hermes chat", offered);
    in_pane(cx, |p, window, cx| p.show_context_usage(window, cx));
    let loaded = wait_until(cx, Duration::from_secs(30), |cx| {
        sheet::current::<ContextSheet>(cx).is_some_and(|s| s.read(cx).report.is_some())
    })
    .await;
    pass &= ok("Context & Usage opens and loads", loaded);
    let report =
        cx.update(|cx| sheet::current::<ContextSheet>(cx).and_then(|s| s.read(cx).report.clone()));
    pass &= ok(
        "the window's fill, what fills it, and the cache",
        report.as_ref().is_some_and(|r| {
            r.context_max == Some(131072)
                && r.context_used.is_some_and(|u| u > 0)
                && r.categories.iter().any(|c| c.id == "system_prompt")
                && r.categories.iter().any(|c| c.id == "tool_definitions")
                && r.categories.iter().any(|c| c.id == "conversation")
        }),
    );
    settle(cx, 600).await;
    shoot_sheet(dir, "hermes-context", cx).await;
    // Compact Now: Hermes summarizes the older messages (or says there is
    // nothing to), and the outcome is said in the sheet.
    if let Some(sheet) = cx.update(|cx| sheet::current::<ContextSheet>(cx)) {
        sheet.update(cx, |s, cx| s.compact(cx));
        let said = wait_until(cx, Duration::from_secs(60), |cx| {
            sheet::current::<ContextSheet>(cx).is_some_and(|s| s.read(cx).outcome.is_some())
        })
        .await;
        let outcome = cx.update(|cx| {
            sheet::current::<ContextSheet>(cx).and_then(|s| s.read(cx).outcome.clone())
        });
        pass &= ok(
            "Compact Now says what it did",
            said && outcome.is_some_and(|(lines, error)| !error && !lines.is_empty()),
        );
        settle(cx, 400).await;
        shoot_sheet(dir, "hermes-context-compacted", cx).await;
    }
    pass &= ok("Context & Usage closes", close_sheet(cx).await);
    pass
}
