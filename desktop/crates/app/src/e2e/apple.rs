//! `--e2e apple`: Apple's on-device model as a Direct backend, on the local
//! Open WebUI's account:
//!
//! * this Mac's REAL status first, from Apple's framework through the
//!   window's engine (`apple.status`): Settings › Direct Connections shows
//!   it, and a model that cannot answer is not in the model picker;
//! * then the engine's scripted model in Apple's place (debug builds only,
//!   `CONDUIT_APPLE_ENGINE=fake` or [`apple_models::use_fake`]): Check
//!   Again finds it ready, with its 4K context; the model picker lists
//!   Apple On-Device "On this Mac"; a chat with it streams through the
//!   window and settles; Stop cancels the run in the engine; a full context
//!   fails in the phone's words;
//! * Private Cloud Compute is never offered (`apple.status`, capabilities).
//!
//! Screens are shot in light and dark: the section (real, then ready), the
//! picker, the answer, the stopped answer and the error.

use conduit_protocol::{
    AppleAvailability, AppleCommandKind, AppleModelKind, AppleModels, Capabilities,
    MessageBlockKind, NoParams, methods,
};

use super::chat::{chat_store, dispatch, in_pane, pane, send, sign_in, wait_answer, wait_models};
use super::composer::new_chat;
use super::*;
use crate::shell::apple_models;
use crate::stores::composer::is_apple_on_device;
use crate::views::direct::pane::{DirectPane, apple_detail};

fn settings_handle(cx: &mut App) -> Option<AnyWindowHandle> {
    cx.global::<AppState>()
        .settings_window
        .as_ref()
        .map(|(h, _)| *h)
}

fn direct_pane(cx: &mut App) -> Option<Entity<DirectPane>> {
    let (_, view) = cx.global::<AppState>().settings_window.clone()?;
    view.read(cx).direct.clone()
}

fn in_pane_settings<R>(
    cx: &mut AsyncApp,
    f: impl FnOnce(&mut DirectPane, &mut Window, &mut gpui_kit::Context<DirectPane>) -> R,
) -> Option<R> {
    let handle = cx.update(settings_handle)?;
    let pane = cx.update(direct_pane)?;
    cx.update(|cx| {
        handle
            .update(cx, |_, window, cx| {
                pane.update(cx, |p, cx| f(p, window, cx))
            })
            .ok()
    })
}

/// The pane's Apple models, once it has asked and is not asking again.
async fn wait_apple(cx: &mut AsyncApp) -> Option<AppleModels> {
    wait_until(cx, Duration::from_secs(30), |cx| {
        direct_pane(cx).is_some_and(|p| {
            let p = p.read(cx);
            p.apple.is_some() && !p.apple_checking
        })
    })
    .await;
    cx.update(|cx| direct_pane(cx).and_then(|p| p.read(cx).apple.clone()))
}

async fn call<M: conduit_daemon::RpcMethod>(
    params: &M::Params,
    cx: &mut AsyncApp,
) -> Option<M::Result>
where
    M::Result: Send + 'static,
{
    let rpc = cx.update(|cx| cx.global::<AppState>().connection.read(cx).rpc());
    match rpc.call::<M>(params).await {
        Ok(r) => Some(r),
        Err(e) => {
            println!("SMOKE note {} failed: {e}", M::NAME);
            None
        }
    }
}

/// The Apple On-Device model the picker lists, if it does.
fn apple_model(cx: &mut App) -> Option<conduit_protocol::ModelSummary> {
    let p = pane(cx)?;
    let list = p.read(cx).composer_store.read(cx).models.clone()?;
    list.models.into_iter().find(is_apple_on_device)
}

fn engine_asked(kind: AppleCommandKind, cx: &mut App) -> usize {
    let apple = cx.global::<AppState>().stores.apple.clone();
    apple.read(cx).asked.get(&kind).copied().unwrap_or(0)
}

pub async fn run(inputs: &E2eInputs, dir: &Path, cx: &mut AsyncApp) -> bool {
    let Some((url, email, password)) = inputs.owui() else {
        return ok(NO_SERVER, false);
    };
    let mut pass = sign_in(&url, &email, &password, cx).await;
    pass &= ok("models.list answered", wait_models(cx).await);

    // 1. This Mac as it is: Apple's framework answers through the window.
    cx.update(|cx| crate::open_settings(Some(Tab::Direct), cx));
    settle(cx, 600).await;
    if cx.update(settings_handle).is_none() {
        return ok("Settings opened on Direct Connections", false);
    }
    let real = wait_apple(cx).await;
    let faked_from_launch = apple_models::fake();
    let l10n = cx.update(|cx| crate::l10n::ActiveL10n::l10n(cx).clone());
    match real.as_ref().and_then(|a| a.models.first()) {
        Some(m) => {
            println!(
                "SMOKE note this Mac's Apple On-Device: {:?} {:?} ({})",
                m.availability,
                m.reason,
                apple_detail(m, &l10n)
            );
            pass &= ok(
                "Settings shows Apple On-Device from the engine's answer",
                m.model == AppleModelKind::OnDevice
                    && (m.availability == AppleAvailability::Available || m.reason.is_some()),
            );
            if !faked_from_launch && m.availability != AppleAvailability::Available {
                let listed = cx.update(|cx| apple_model(cx).is_some());
                pass &= ok(
                    "a model that cannot answer is not in the model picker",
                    !listed,
                );
            }
        }
        None => pass &= ok("apple.status answered", false),
    }
    pass &= ok(
        "only Apple On-Device is offered (no Private Cloud Compute)",
        real.as_ref()
            .is_some_and(|a| a.models.len() == 1 && a.models[0].model == AppleModelKind::OnDevice),
    );
    if let Some(h) = cx.update(settings_handle) {
        crate::smoke::shoot_both_modes(h, dir, "apple-this-mac", cx).await;
        let controls = ax(h, "apple-this-mac", dir, cx).await;
        pass &= ok(
            "Check Again is a labelled button",
            has(&controls, "Button", &l10n.desktop_apple_check_again()),
        );
    }

    // 2. The scripted model in Apple's place: Check Again finds it ready.
    apple_models::use_fake();
    let asked = cx.update(|cx| engine_asked(AppleCommandKind::Status, cx));
    in_pane_settings(cx, |p, window, cx| p.check_apple(window, cx));
    let checking = cx.update(|cx| direct_pane(cx).is_some_and(|p| p.read(cx).apple_checking));
    pass &= ok("Check Again shows Checking… while it asks", checking);
    let ready = wait_apple(cx).await;
    let on_device = ready.as_ref().and_then(|a| a.models.first().cloned());
    pass &= ok(
        "Check Again asked the engine again",
        cx.update(|cx| engine_asked(AppleCommandKind::Status, cx)) > asked,
    );
    pass &= ok(
        &format!("Apple On-Device is ready with its 4K context ({on_device:?})"),
        on_device.as_ref().is_some_and(|m| {
            m.availability == AppleAvailability::Available && m.context_size == Some(4096)
        }),
    );
    if let Some(m) = &on_device {
        pass &= ok(
            "the row says Available and the context limit",
            apple_detail(m, &l10n) == "Available \u{b7} Context limit: 4K",
        );
    }
    settle(cx, 400).await;
    if let Some(h) = cx.update(settings_handle) {
        crate::smoke::shoot_both_modes(h, dir, "apple-ready", cx).await;
    }
    let caps = call::<methods::SystemCapabilities>(&NoParams, cx).await;
    pass &= ok(
        "capabilities: Apple on-device models, never Private Cloud Compute",
        caps.as_ref()
            .is_some_and(|c: &Capabilities| c.apple_on_device_models && !c.apple_pcc),
    );
    if let Some(h) = cx.update(settings_handle) {
        let _ = h.update(cx, |_, window, _| window.remove_window());
    }
    settle(cx, 400).await;

    // 3. The model picker lists it, saying where it runs.
    let listed = wait_until(cx, Duration::from_secs(30), |cx| apple_model(cx).is_some()).await;
    pass &= ok("the model picker lists Apple On-Device", listed);
    let Some(model) = cx.update(apple_model) else {
        return pass;
    };
    pass &= ok(
        "its row reads Apple On-Device",
        model.name == "Apple On-Device",
    );
    new_chat(cx).await;
    in_pane(cx, |p, window, cx| {
        p.composer.update(cx, |c, cx| c.open_picker(window, cx))
    });
    settle(cx, 500).await;
    shoot_main(dir, "apple-picker", cx).await;
    in_pane(cx, |p, window, cx| {
        p.composer.update(cx, |c, cx| c.close_picker(window, cx))
    });
    let id = model.id.clone();
    in_pane(cx, move |p, _, cx| {
        p.composer_store.update(cx, |c, cx| c.select_model(&id, cx))
    });
    let selected = wait_until(cx, Duration::from_secs(15), |cx| {
        pane(cx).is_some_and(|p| {
            p.read(cx)
                .composer_store
                .read(cx)
                .models
                .as_ref()
                .and_then(|m| m.selected_id.clone())
                .as_deref()
                == Some(model.id.as_str())
        })
    })
    .await;
    pass &= ok("Apple On-Device is the chat's model", selected);

    // 4. A reply streams through the window's engine and settles.
    let started = cx.update(|cx| engine_asked(AppleCommandKind::Start, cx));
    send("Name three hardy herbs for a windowsill.", cx).await;
    pass &= ok(
        "the answer settles",
        wait_answer(cx, Duration::from_secs(60)).await,
    );
    pass &= ok(
        "the window's engine ran it",
        cx.update(|cx| engine_asked(AppleCommandKind::Start, cx)) > started,
    );
    let text = cx.update(super::chat::last_answer_text);
    pass &= ok(
        &format!("the answer is the model's ({text:?})"),
        text.trim() == "On this Mac, the answer is ready.",
    );
    settle(cx, 400).await;
    if let Some(h) = cx.update(|cx| main_window(cx).map(|(h, _)| h)) {
        crate::smoke::shoot_both_modes(h, dir, "apple-answer", cx).await;
    }

    // 5. Stop: the run ends in the engine.
    let cancels = cx.update(|cx| engine_asked(AppleCommandKind::Cancel, cx));
    send("Tell me a long story about the tide.", cx).await;
    let streaming = wait_until(cx, Duration::from_secs(30), |cx| {
        chat_store(cx).is_some_and(|s| {
            s.read(cx)
                .live
                .as_ref()
                .is_some_and(|l| l.streaming() && !l.blocks.is_empty())
        })
    })
    .await;
    pass &= ok("the long answer streams", streaming);
    settle(cx, 1200).await;
    dispatch(&crate::actions::StopGenerating, cx);
    let stopped = wait_until(cx, Duration::from_secs(30), |cx| {
        chat_store(cx).is_some_and(|s| !s.read(cx).is_streaming())
    })
    .await;
    pass &= ok("Stop ends the answer", stopped);
    let cancelled = wait_until(cx, Duration::from_secs(10), |cx| {
        engine_asked(AppleCommandKind::Cancel, cx) > cancels
    })
    .await;
    pass &= ok("Stop cancels the run in the engine", cancelled);
    wait_answer(cx, Duration::from_secs(30)).await;
    let partial = cx.update(super::chat::last_answer_text);
    pass &= ok(
        &format!(
            "the stopped answer is partial ({} words)",
            partial.split_whitespace().count()
        ),
        !partial.trim().is_empty() && partial.split_whitespace().count() < 240,
    );
    settle(cx, 400).await;
    shoot_main(dir, "apple-stopped", cx).await;

    // 6. A full context fails in the phone's words.
    send("Go past the context limit.", cx).await;
    let failed = wait_until(cx, Duration::from_secs(30), |cx| {
        chat_store(cx).is_some_and(|s| {
            let s = s.read(cx);
            !s.is_streaming()
                && s.rows().last().and_then(|r| s.item(*r)).is_some_and(|i| {
                    i.blocks.iter().any(|b| {
                        b.kind == MessageBlockKind::Error
                            && serde_json::to_string(b).is_ok_and(|j| {
                                j.contains("exceeds the Apple On-Device context limit")
                            })
                    })
                })
        })
    })
    .await;
    pass &= ok("a full context reads as the phone says it", failed);
    settle(cx, 400).await;
    if let Some(h) = cx.update(|cx| main_window(cx).map(|(h, _)| h)) {
        crate::smoke::shoot_both_modes(h, dir, "apple-error", cx).await;
    }
    pass
}

/// `--e2e apple-only`: Apple On-Device as the only model there is. The
/// engine's scripted model answers from the start (the app offers the
/// connection only while the model answers), so signing out of the local
/// Open WebUI account hands over to Direct with Apple On-Device alone, as
/// the core's fallback does. Then everything outside the chat pane that
/// asks a model asks it, through the window's engine:
///
/// * Shortcuts' Ask Conduit (the Swift intent's own `perform()`) gives
///   back the model's answer;
/// * Quick Ask streams it in its panel;
/// * the widget's snapshot is signed in, its Quick Ask link shows the
///   panel, and its Voice Call link either starts a call in a new chat or
///   says why it can't, in the core's words (never neither).
pub async fn only(inputs: &E2eInputs, dir: &Path, cx: &mut AsyncApp) -> bool {
    use serde_json::json;

    use super::intents::{brief, step, succeeded};
    use super::shell::{links, quick_ask, quick_new_chat, quick_send, wait_quick_answer};
    use crate::desktop;
    use crate::stores::navigation::Selection;

    const ANSWER: &str = "On this Mac, the answer is ready.";
    let Some((url, email, password)) = inputs.owui() else {
        return ok(NO_SERVER, false);
    };
    apple_models::use_fake();
    let mut pass = sign_in(&url, &email, &password, cx).await;
    pass &= ok("models.list answered", wait_models(cx).await);
    let ready = wait_until(cx, Duration::from_secs(30), |cx| apple_model(cx).is_some()).await;
    pass &= ok("the engine's model answers: the picker lists it", ready);

    // Signed out: Apple On-Device is the only usable connection left.
    in_main(cx, |mw, window, cx| {
        crate::views::accounts::sign_out_active(&mw.stores, window, cx)
    });
    let direct = wait_until(cx, Duration::from_secs(60), |cx| {
        let s = cx.global::<AppState>().stores.session.clone();
        let s = s.read(cx);
        s.route(cx) == Route::Main && s.direct_only(cx)
    })
    .await;
    pass &= ok("signing out hands over to Direct", direct);
    pass &= wait_main(cx).await.is_some();
    let alone = wait_until(cx, Duration::from_secs(30), |cx| {
        pane(cx).is_some_and(|p| {
            p.read(cx)
                .composer_store
                .read(cx)
                .models
                .as_ref()
                .is_some_and(|m| m.models.len() == 1 && is_apple_on_device(&m.models[0]))
        })
    })
    .await;
    pass &= ok("Apple On-Device is the only model", alone);
    settle(cx, 600).await;
    shoot_main(dir, "apple-only-main", cx).await;

    // Shortcuts' Ask Conduit.
    let started = cx.update(|cx| engine_asked(AppleCommandKind::Start, cx));
    let asked = step(json!({ "intent": "ask", "prompt": "Name a herb for a sunny sill." })).await;
    pass &= ok(
        &format!(
            "Ask Conduit answers with the model's words ({})",
            brief(&asked)
        ),
        succeeded(&asked) && asked["value"].as_str().map(str::trim) == Some(ANSWER),
    );
    pass &= ok(
        "…run by the window's engine",
        cx.update(|cx| engine_asked(AppleCommandKind::Start, cx)) > started,
    );

    // Quick Ask.
    cx.update(desktop::show_quick_ask);
    let shown = wait_until(cx, Duration::from_secs(5), desktop::quick_ask_visible).await;
    pass &= ok("Quick Ask opens", shown);
    quick_new_chat(cx);
    settle(cx, 300).await;
    quick_send("Which herb likes a cool morning?", cx);
    let answered = wait_quick_answer(cx, Duration::from_secs(60)).await;
    let text = cx.update(|cx| {
        quick_ask(cx)
            .and_then(|(_, v)| v.read(cx).chat.as_ref().map(|c| c.store.clone()))
            .map(|store| {
                let s = store.read(cx);
                s.rows()
                    .iter()
                    .rev()
                    .filter_map(|r| s.item(*r))
                    .find(|i| i.role == crate::stores::chat::Role::Assistant)
                    .map(|i| i.text)
                    .unwrap_or_default()
            })
            .unwrap_or_default()
    });
    pass &= ok(
        &format!("Quick Ask streams the model's answer ({text:?})"),
        answered && text.trim() == ANSWER,
    );
    if let Some((handle, _)) = cx.update(quick_ask) {
        crate::smoke::shoot_both_modes(handle, dir, "apple-only-quick-ask", cx).await;
    }
    cx.update(desktop::hide_quick_ask);
    settle(cx, 400).await;

    // The widget: signed in, its Quick Ask link, its Voice Call link.
    let signed_in = cx.update(|cx| {
        let s = cx.global::<AppState>().stores.session.clone();
        s.read(cx).route(cx) == Route::Main
    });
    pass &= ok(
        "the widget's snapshot is a signed-in one (the route is Main)",
        signed_in,
    );
    links(&["conduit://quick-ask"], cx);
    let shown = wait_until(cx, Duration::from_secs(5), desktop::quick_ask_visible).await;
    pass &= ok("conduit://quick-ask shows Quick Ask", shown);
    cx.update(desktop::hide_quick_ask);
    settle(cx, 400).await;
    pass &= ok(
        "a quiet stand-in for the call's microphone",
        super::voice_call::prepare_quiet_call(dir, cx).await,
    );
    let call = cx.update(|cx| cx.global::<AppState>().stores.call.clone());
    let before = cx.update(|cx| call.read(cx).state().call);
    links(&["conduit://call"], cx);
    // A call in a new chat, or the core's refusal (an error phase, its
    // words shown): never nothing.
    let settled = wait_until(cx, Duration::from_secs(20), |cx| {
        let (active, phase) = {
            let s = call.read(cx);
            (s.is_active(), s.state().phase)
        };
        let started = active && matches!(selection_of(cx), Selection::New { .. });
        started || phase == conduit_protocol::CallPhase::Error
    })
    .await;
    let (active, words) = cx.update(|cx| {
        let l = crate::l10n::ActiveL10n::l10n(cx).clone();
        let s = call.read(cx);
        (s.is_active(), crate::views::chat::call::error_text(s, &l))
    });
    pass &= ok(
        &format!(
            "the widget's Voice Call starts a call or says why not (active {active}, call {} after {before}, {words:?})",
            cx.update(|cx| call.read(cx).state().call)
        ),
        settled && (active || !words.trim().is_empty()),
    );
    settle(cx, 600).await;
    shoot_main(dir, "apple-only-voice-call", cx).await;
    if active {
        pass &= ok("…and the call ends", super::voice_call::end_call(cx).await);
    }
    pass
}

fn selection_of(cx: &mut App) -> crate::stores::navigation::Selection {
    cx.global::<AppState>()
        .stores
        .navigation
        .read(cx)
        .selection()
        .clone()
}

/// `--e2e onboarding-apple`: the first-run chooser's Apple On-Device row
/// (the phone's backend chooser, `_selectAppleModel`), with no server:
///
/// * this Mac's REAL model first: the row shows only if it answers, and a
///   choice it refuses says why in the Mac's words and chooses nothing;
/// * then the engine's scripted model: the row shows under "Apple
///   Intelligence" (no Private Cloud Compute row); one click prefers
///   Direct on it, history kept on this Mac, and the main window opens
///   with Apple On-Device as the only model.
pub async fn onboarding(_inputs: &E2eInputs, dir: &Path, cx: &mut AsyncApp) -> bool {
    use crate::views::onboarding::OnboardingView;

    fn onboarding_view(cx: &mut App) -> Option<Entity<OnboardingView>> {
        super::setup_window(cx).map(|(_, sw)| sw.read(cx).onboarding.clone())
    }
    fn offered(cx: &mut App) -> bool {
        onboarding_view(cx).is_some_and(|o| o.read(cx).offers_apple(cx))
    }

    let mut pass = fresh_profile(cx).await;
    pass &= ok("the setup window opened", wait_setup(cx).await.is_some());

    // 1. This Mac's own model.
    let real = call::<methods::AppleStatus>(&NoParams, cx).await;
    let real_available = real.as_ref().is_some_and(|m| {
        m.models
            .first()
            .is_some_and(|s| s.availability == AppleAvailability::Available)
    });
    settle(cx, 1500).await;
    pass &= ok(
        &format!(
            "the chooser offers Apple On-Device only while this Mac's model answers ({:?})",
            real.as_ref()
                .and_then(|m| m.models.first())
                .map(|s| s.availability)
        ),
        cx.update(offered) == real_available,
    );
    if !real_available {
        // A model that stopped answering after the row showed: the reason,
        // and nothing chosen.
        in_setup(cx, |sw, window, cx| {
            sw.onboarding.update(cx, |o, cx| o.choose_apple(window, cx))
        });
        let said = wait_until(cx, Duration::from_secs(20), |cx| {
            onboarding_view(cx).is_some_and(|o| o.read(cx).apple_error.is_some())
        })
        .await;
        let words =
            cx.update(|cx| onboarding_view(cx).and_then(|o| o.read(cx).apple_error.clone()));
        let expected = cx.update(|cx| {
            let l = crate::l10n::ActiveL10n::l10n(cx).clone();
            real.as_ref()
                .and_then(|m| m.models.first())
                .map(|s| apple_detail(s, &l))
        });
        let toasted = cx.update(|cx| {
            let app: &App = cx;
            app.global::<AppState>()
                .stores
                .toasts
                .read(app)
                .toasts
                .iter()
                .any(|t| Some(&t.message) == words.as_ref())
        });
        pass &= ok(
            &format!("a refused choice says why, in a toast ({words:?})"),
            said && words.is_some() && words == expected && toasted,
        );
        let direct = call::<methods::DirectList>(&NoParams, cx).await;
        pass &= ok(
            "…and chooses nothing (Direct is not preferred)",
            direct.is_some_and(|d| !d.preferred),
        );
        pass &= ok(
            "…and the window stays on the chooser",
            cx.update(current_route) == Route::Onboarding,
        );
        shoot_setup(dir, "onboarding-apple-refused", cx).await;
    }

    // 2. The engine's scripted model answers.
    apple_models::use_fake();
    let ready = call::<methods::AppleRefresh>(&NoParams, cx).await;
    pass &= ok(
        "the engine's model answers (apple.refresh)",
        ready.is_some_and(|m| {
            m.models
                .first()
                .is_some_and(|s| s.availability == AppleAvailability::Available)
        }),
    );
    let shown = wait_until(cx, Duration::from_secs(20), offered).await;
    pass &= ok("the chooser offers Apple On-Device", shown);
    in_setup(cx, |sw, _, cx| {
        sw.onboarding.update(cx, |o, cx| {
            o.apple_error = None;
            cx.notify()
        })
    });
    // A shot of the chooser, not of the refusal's toast.
    super::sign_in::clear_toasts(cx);
    settle(cx, 600).await;
    if let Some(handle) = wait_setup(cx).await {
        let controls = super::ax(handle, "onboarding-apple", dir, cx).await;
        pass &= ok(
            "the row is a button labelled Apple On-Device",
            has(&controls, "Button", "Apple On-Device"),
        );
        pass &= ok(
            "no Private Cloud Compute row",
            !controls.iter().any(|c| c.contains("Private Cloud Compute")),
        );
    }
    shoot_setup(dir, "onboarding-apple", cx).await;

    // 3. One click: Direct on Apple's model, history on this Mac.
    in_setup(cx, |sw, window, cx| {
        sw.onboarding.update(cx, |o, cx| o.choose_apple(window, cx))
    });
    pass &= wait_route(cx, Route::Main, Duration::from_secs(60)).await;
    let direct_only = wait_until(cx, Duration::from_secs(30), |cx| {
        let s = cx.global::<AppState>().stores.session.clone();
        s.read(cx).direct_only(cx)
    })
    .await;
    pass &= ok("the window is a Direct one", direct_only);
    pass &= wait_main(cx).await.is_some();
    let direct = call::<methods::DirectList>(&NoParams, cx).await;
    pass &= ok(
        &format!(
            "Direct is preferred, usable, with history on this Mac ({:?})",
            direct
                .as_ref()
                .map(|d| (d.preferred, d.usable, d.local_history))
        ),
        direct.is_some_and(|d| d.preferred && d.usable && d.local_history),
    );
    let alone = wait_until(cx, Duration::from_secs(30), |cx| {
        pane(cx).is_some_and(|p| {
            p.read(cx)
                .composer_store
                .read(cx)
                .models
                .as_ref()
                .is_some_and(|m| m.models.len() == 1 && is_apple_on_device(&m.models[0]))
        })
    })
    .await;
    pass &= ok("Apple On-Device is the only model", alone);
    settle(cx, 600).await;
    shoot_main(dir, "onboarding-apple-main", cx).await;
    pass
}
