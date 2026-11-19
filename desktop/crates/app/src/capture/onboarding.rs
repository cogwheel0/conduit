//! First run, in the setup window: the backend chooser, the Direct and
//! Hermes forms, the server form (and its error), sign-in (and its error),
//! with hover and keyboard focus on each; then a password sign-in to the
//! seeded account, after which the main window takes over.

use std::time::Duration;

use conduit_components::views::model::Backend;
use gpui_kit::{AsyncApp, Entity, Window};

use super::{Run, Shot, drive, log, pause, wait_until};
use crate::AppState;
use crate::smoke::{current_route, current_status};
use crate::stores::connection::Status;
use crate::stores::session::Route;
use crate::views::main_window::MainWindow;
use crate::views::onboarding::Step;
use crate::views::setup_window::SetupWindow;

/// Runs `f` on the main window's view, with its window (the run's).
pub(super) fn in_main<R>(
    run: &Run,
    cx: &mut AsyncApp,
    f: impl FnOnce(&mut MainWindow, &mut Window, &mut gpui_kit::Context<MainWindow>) -> R,
) -> Option<R> {
    let view = cx.update(|cx| cx.global::<AppState>().main_view.clone())?;
    run.main
        .update(cx, |_, window, cx| {
            view.update(cx, |mw, cx| f(mw, window, cx))
        })
        .ok()
}

/// Runs `f` on the setup window's view, with its window.
pub(super) fn in_setup<R>(
    cx: &mut AsyncApp,
    f: impl FnOnce(&mut SetupWindow, &mut Window, &mut gpui_kit::Context<SetupWindow>) -> R,
) -> Option<R> {
    let (handle, view) = cx.update(|cx| cx.global::<AppState>().setup_window.clone())?;
    handle
        .update(cx, |_, window, cx| {
            view.update(cx, |sw, cx| f(sw, window, cx))
        })
        .ok()
}

pub(super) fn set_text(
    state: &Entity<gpui_kit::component::input::InputState>,
    text: &str,
    window: &mut Window,
    cx: &mut gpui_kit::App,
) {
    let text = text.to_string();
    state.update(cx, |i, cx| i.set_value(text, window, cx));
}

pub(super) async fn wait_route(want: Route, timeout: Duration, cx: &mut AsyncApp) -> bool {
    wait_until(cx, timeout, |cx| {
        current_route(cx) == want && current_status(cx) == Status::Connected
    })
    .await
}

fn go(step: Step, cx: &mut AsyncApp) {
    in_setup(cx, |sw, window, cx| {
        sw.onboarding.update(cx, |o, cx| o.go(step, window, cx))
    });
}

fn choose(backend: Backend, cx: &mut AsyncApp) {
    in_setup(cx, |sw, window, cx| {
        sw.onboarding.update(cx, |o, cx| {
            o.selected = backend;
            o.choose(window, cx)
        })
    });
}

pub async fn run(run: &mut Run, cx: &mut AsyncApp) -> bool {
    let Some(url) = run.env.get("OWUI_URL").cloned() else {
        run.missing(
            "everything",
            "no OWUI_URL in the env file (tool/local_owui/owui.sh up)",
        );
        return false;
    };
    let (Some(email), Some(password)) = (
        run.env.get("OWUI_EMAIL").cloned(),
        run.env.get("OWUI_PASSWORD").cloned(),
    ) else {
        run.missing("everything", "no OWUI_EMAIL/OWUI_PASSWORD in the env file");
        return false;
    };
    let routed = wait_until(cx, Duration::from_secs(90), |cx| {
        current_route(cx) != Route::Unknown && current_status(cx) == Status::Connected
    })
    .await;
    if !routed {
        run.missing("everything", "the daemon never connected");
        return false;
    }
    if cx.update(current_route) != Route::Onboarding {
        if !cx.update(|cx| crate::may_reset_profile(&cx.global::<AppState>().paths)) {
            run.missing("everything", "refusing to reset the app's own profile");
            return false;
        }
        // A used profile: start over (Settings › Data › Clear local data).
        cx.update(|cx| {
            let c = cx.global::<AppState>().connection.clone();
            c.update(cx, |c, cx| c.clear_local_data(cx));
        });
        pause(cx, 1500).await;
        wait_route(Route::Onboarding, Duration::from_secs(90), cx).await;
    }
    // First run is the setup window's (the main window closes without a
    // session, or never opened on a fresh profile).
    if !wait_until(cx, Duration::from_secs(15), crate::windows::setup_alive).await {
        run.missing("everything", "the setup window never opened");
        return false;
    }
    let Some(main) = cx.update(|cx| {
        cx.global::<AppState>()
            .setup_window
            .as_ref()
            .map(|(h, _)| *h)
    }) else {
        return false;
    };
    cx.update(|cx| super::activate(main, cx));
    pause(cx, 600).await;

    if run.wants("onboarding") {
        run.state(
            main,
            "onboarding",
            "chooser",
            "First run: the backend chooser (Open WebUI, a model provider, Hermes Agent).",
            Shot::default(),
            cx,
        )
        .await;
        // Hover and press on the first choice.
        let nodes = drive::nodes(main, cx).await;
        if let Some(row) = drive::find(&nodes, "Button", |l| l.contains("Open WebUI")).cloned()
            && let Some(at) = row.center()
        {
            drive::hover(main, at, cx);
            pause(cx, 250).await;
            run.interaction(
                main,
                "onboarding",
                "chooser-row-hover",
                "The chooser's Open WebUI row under the pointer.",
                Shot::quick(),
                cx,
            )
            .await;
            drive::press(main, at, gpui_kit::MouseButton::Left, cx);
            pause(cx, 120).await;
            run.interaction(
                main,
                "onboarding",
                "chooser-row-pressed",
                "The same row pressed (mouse down, not yet released).",
                Shot::quick(),
                cx,
            )
            .await;
            // Released off the row: no click.
            drive::release(
                main,
                gpui_kit::point(gpui_kit::px(2.), gpui_kit::px(2.)),
                gpui_kit::MouseButton::Left,
                cx,
            );
            drive::unhover(main, cx);
            pause(cx, 200).await;
        }
        run.focus_walk(main, "onboarding-chooser", "tab", 8, cx)
            .await;
        run.tooltips(main, "onboarding-chooser", cx).await;

        choose(Backend::Direct, cx);
        pause(cx, 700).await;
        run.state(
            main,
            "onboarding",
            "direct-form",
            "First run › model provider: the OpenAI-compatible provider form.",
            Shot::default(),
            cx,
        )
        .await;
        run.focus_walk(main, "onboarding-direct-form", "tab", 10, cx)
            .await;
        go(Step::Choose, cx);
        pause(cx, 400).await;
        choose(Backend::Hermes, cx);
        pause(cx, 700).await;
        run.state(
            main,
            "onboarding",
            "hermes-form",
            "First run › Hermes Agent: the agent connection form.",
            Shot::default(),
            cx,
        )
        .await;
        go(Step::Choose, cx);
        pause(cx, 400).await;
    }

    choose(Backend::OpenWebUi, cx);
    pause(cx, 700).await;
    if run.wants("onboarding") {
        run.state(
            main,
            "onboarding",
            "server-form",
            "First run › Open WebUI: the server form, empty.",
            Shot::default(),
            cx,
        )
        .await;
        run.focus_walk(main, "onboarding-server-form", "tab", 8, cx)
            .await;
        // A refused address.
        in_setup(cx, |sw, window, cx| {
            let form = sw.onboarding.read(cx).server.clone();
            let (u, n) = {
                let f = form.read(cx);
                (f.url.clone(), f.name.clone())
            };
            set_text(&u, "ftp://files.example.org", window, cx);
            set_text(&n, "", window, cx);
            form.update(cx, |f, cx| f.submit(window, cx));
        });
        pause(cx, 500).await;
        run.state(
            main,
            "onboarding",
            "server-form-error",
            "The server form refusing an ftp:// address.",
            Shot::default(),
            cx,
        )
        .await;
    }
    in_setup(cx, |sw, window, cx| {
        let form = sw.onboarding.read(cx).server.clone();
        let (u, n) = {
            let f = form.read(cx);
            (f.url.clone(), f.name.clone())
        };
        set_text(&u, &url, window, cx);
        set_text(&n, "Lab Server", window, cx);
        form.update(cx, |f, cx| f.submit(window, cx));
    });
    if !wait_route(Route::SignIn, Duration::from_secs(60), cx).await {
        run.missing("sign-in", "the server form never reached sign-in");
        return false;
    }
    pause(cx, 600).await;
    if run.wants("onboarding") {
        run.state(
            main,
            "sign-in",
            "empty",
            "Sign-in for the new server: method switch, email, password, SSO.",
            Shot::default(),
            cx,
        )
        .await;
        run.focus_walk(main, "sign-in", "tab", 10, cx).await;
        run.tooltips(main, "sign-in", cx).await;
        // A wrong password.
        let (e, p) = (email.clone(), "not-the-password".to_string());
        in_setup(cx, move |sw, window, cx| {
            let view = sw.sign_in.clone();
            let (ef, pf) = {
                let v = view.read(cx);
                (v.email.clone(), v.password.clone())
            };
            set_text(&ef, &e, window, cx);
            set_text(&pf, &p, window, cx);
            view.update(cx, |v, cx| v.submit(window, cx));
        });
        let refused = wait_until(cx, Duration::from_secs(30), |cx| {
            let Some((_, view)) = cx.global::<AppState>().setup_window.clone() else {
                return false;
            };
            let s = view.read(cx).sign_in.read(cx);
            !s.busy && s.error.is_some()
        })
        .await;
        if refused {
            // The address field shows a synthetic address, not the seed's.
            in_setup(cx, |sw, window, cx| {
                let ef = sw.sign_in.read(cx).email.clone();
                set_text(&ef, "avery@example.org", window, cx);
            });
            run.state(
                main,
                "sign-in",
                "error",
                "Sign-in refusing a wrong password.",
                Shot::default(),
                cx,
            )
            .await;
        } else {
            run.missing("sign-in · error", "the wrong password was never refused");
        }
    }
    let (e, p) = (email.clone(), password.clone());
    in_setup(cx, move |sw, window, cx| {
        let view = sw.sign_in.clone();
        let (ef, pf) = {
            let v = view.read(cx);
            (v.email.clone(), v.password.clone())
        };
        set_text(&ef, &e, window, cx);
        set_text(&pf, &p, window, cx);
        view.update(cx, |v, cx| v.submit(window, cx));
    });
    if !wait_route(Route::Main, Duration::from_secs(60), cx).await {
        run.missing("main", "sign-in never reached the main window");
        return false;
    }
    if !super::adopt_main(run, cx).await {
        run.missing("main", "the main window never opened after sign-in");
        return false;
    }
    // The first sync: 36 visible chats, then quiet.
    let loaded = wait_until(cx, Duration::from_secs(120), |cx| {
        let s = cx.global::<AppState>().stores.chat_list.read(cx);
        s.list.as_ref().is_some_and(|l| l.chats.len() >= 36)
            && s.sync
                .as_ref()
                .is_some_and(|s| s.ever_completed && !s.running)
    })
    .await;
    if !loaded {
        run.problem("the chat list did not finish its first sync in 2 minutes");
    }
    log("signed in");
    pause(cx, 1500).await;
    true
}
