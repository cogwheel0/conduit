//! `--e2e sign-in-two-step` and `--e2e sign-in-proxy`: sign-in parity with
//! the phone.
//!
//! * `sign-in-two-step`, against a local Open WebUI with two-step
//!   verification on (`owui.sh reset && owui.sh two-step`): the Token
//!   method (an API key and a short token refused in the phone's words, then
//!   a session token), an account awaiting approval, and the second step:
//!   Back to Sign In, a wrong code, a recovery code, an authenticator code,
//!   adding an authenticator (QR code, Copy Setup Key, the recovery codes),
//!   an administrator's reset, and the same step while adding a second
//!   account from Settings.
//! * `sign-in-proxy`, against a plain one behind the fake sign-in proxy
//!   (`owui.sh proxy start`): single sign-on through the proxy, the proxy's
//!   session expiring (the Connection Issue page, not a sign-out), Try
//!   Again, and Sign In to Proxy Again, which renews it in the same account.
//!
//! Each stage is shot in light and dark. Every account, code and token is
//! the local server's synthetic seed.

use std::path::Path;
use std::process::Command;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use conduit_protocol::TwoStepStage;
use gpui_kit::{App, AsyncApp, ClipboardItem};

use super::*;
use crate::l10n::ActiveL10n as _;
use crate::views::sign_in::Method;
use crate::views::two_step::TwoStepView;

pub async fn two_step(inputs: &E2eInputs, dir: &Path, cx: &mut AsyncApp) -> bool {
    let Some(url) = inputs.get("OWUI_URL") else {
        return ok(NO_SERVER, false);
    };
    if inputs.get("OWUI_TWO_STEP").as_deref() != Some("1") {
        return ok(
            "the local Open WebUI has two-step sign-in on (owui.sh two-step)",
            false,
        );
    }
    let user = |key: &str| {
        (
            inputs.get(&format!("OWUI_{key}_EMAIL")).unwrap_or_default(),
            inputs
                .get(&format!("OWUI_{key}_PASSWORD"))
                .unwrap_or_default(),
        )
    };
    let l10n = cx.update(|cx| cx.l10n().clone());
    let saved_clipboard = cx.update(|cx| cx.read_from_clipboard());
    let mut pass = fresh_profile(cx).await;
    pass &= ok("the setup window opened", wait_setup(cx).await.is_some());
    pass &= connect(&url, cx).await;
    let Some(setup) = cx.update(setup_window).map(|(h, _)| h) else {
        return ok("the setup window is there", false);
    };

    // ── Token ───────────────────────────────────────────────────────────
    in_setup(cx, |sw, _, cx| {
        sw.sign_in
            .update(cx, |s, cx| s.set_method(Method::Token, cx))
    });
    settle(cx, 400).await;
    shot(dir, "sign-in-token", cx).await;
    let controls = ax(setup, "sign-in-token", dir, cx).await;
    pass &= ok(
        "the method is called Token, as on the phone, and API Key is gone",
        has(&controls, "RadioButton", "Token") && !controls.iter().any(|c| c.contains("API Key")),
    );
    for (token, words, name) in [
        (
            "sk-test-placeholder",
            l10n.api_key_not_supported(),
            "sign-in-token-api-key",
        ),
        ("eyJ.short", l10n.token_too_short(), "sign-in-token-short"),
    ] {
        token_sign_in(token, cx).await;
        let error = wait_sign_in_error(cx).await;
        pass &= ok(
            &format!("a refused token says why ({token:.3}…: {error:?})"),
            error.as_deref() == Some(words.as_str()),
        );
        if name.ends_with("api-key") {
            shot(dir, name, cx).await;
        }
    }

    // ── Awaiting approval ───────────────────────────────────────────────
    in_setup(cx, |sw, _, cx| {
        sw.sign_in
            .update(cx, |s, cx| s.set_method(Method::Password, cx))
    });
    let (email, password) = user("PENDING");
    sign_in_password(&email, &password, cx).await;
    let error = wait_sign_in_error(cx).await;
    pass &= ok(
        &format!("an account awaiting approval says so ({error:?})"),
        error.as_deref() == Some(l10n.sign_in_account_pending_approval().as_str()),
    );
    mask_email(cx);
    shot(dir, "sign-in-pending-approval", cx).await;

    // ── The second step: Back to Sign In ────────────────────────────────
    let (email, password) = user("TWO_STEP");
    sign_in_password(&email, &password, cx).await;
    pass &= wait_stage(TwoStepStage::Verify, cx).await;
    settle(cx, 400).await;
    shot(dir, "two-step-verify", cx).await;
    let controls = ax(setup, "two-step-verify", dir, cx).await;
    pass &= ok(
        "the step has its code field, Continue, Use a Recovery Code and Back to Sign In",
        has(&controls, "TextInput", "")
            && has(&controls, "Button", &l10n.continue_action())
            && has(&controls, "Link", &l10n.two_step_use_recovery_code())
            && has(&controls, "Button", &l10n.two_step_back_to_sign_in()),
    );
    let focused = in_two_step(cx, |v, window, cx| {
        gpui_kit::Focusable::focus_handle(v.code.read(cx), cx).is_focused(window)
    })
    .unwrap_or(false);
    pass &= ok("the code field has the focus", focused);
    in_two_step(cx, |v, _, cx| v.cancel(cx));
    let back = wait_until(cx, Duration::from_secs(15), |cx| stage(cx).is_none()).await;
    pass &= ok("Back to Sign In returns to the form", back);
    pass &= ok(
        "the account is still signing in (not signed in, not gone)",
        cx.update(current_route) == Route::SignIn,
    );

    // ── A wrong code, then a recovery code ──────────────────────────────
    sign_in_password(&email, &password, cx).await;
    pass &= wait_stage(TwoStepStage::Verify, cx).await;
    submit_code("000000", cx).await;
    let error = wait_two_step_error(cx).await;
    pass &= ok(
        &format!("a wrong code is refused in the phone's words ({error:?})"),
        error.as_deref() == Some(l10n.two_step_invalid_code().as_str()),
    );
    shot(dir, "two-step-wrong-code", cx).await;
    in_two_step(cx, |v, window, cx| v.toggle_recovery(window, cx));
    settle(cx, 300).await;
    shot(dir, "two-step-recovery-code", cx).await;
    let recovery = inputs
        .get("OWUI_TWO_STEP_RECOVERY_CODES")
        .and_then(|c| c.split(',').next().map(str::to_string))
        .unwrap_or_default();
    submit_code(&recovery, cx).await;
    pass &= signed_in("a recovery code signs in", cx).await;
    pass &= sign_out(cx).await;

    // ── An authenticator code ───────────────────────────────────────────
    pass &= connect(&url, cx).await;
    sign_in_password(&email, &password, cx).await;
    pass &= wait_stage(TwoStepStage::Verify, cx).await;
    let secret = inputs.get("OWUI_TWO_STEP_SECRET").unwrap_or_default();
    let mut steps = Steps::default();
    let code = steps.next(&secret, cx).await;
    submit_code(&code, cx).await;
    pass &= signed_in("an authenticator code signs in", cx).await;
    pass &= sign_out(cx).await;

    // ── Adding an authenticator ─────────────────────────────────────────
    pass &= connect(&url, cx).await;
    let (enrol_email, enrol_password) = user("ENROL");
    sign_in_password(&enrol_email, &enrol_password, cx).await;
    pass &= wait_stage(TwoStepStage::Enroll, cx).await;
    let loaded = wait_until(cx, Duration::from_secs(20), |cx| {
        two_step_view(cx).is_some_and(|v| v.read(cx).setup.is_some())
    })
    .await;
    pass &= ok("the setup key and QR code arrive", loaded);
    settle(cx, 600).await;
    shot(dir, "two-step-enrol", cx).await;
    let controls = ax(current_setup(cx).await, "two-step-enrol", dir, cx).await;
    pass &= ok(
        "the QR code is a labelled image, with Copy Setup Key and Add to Authenticator App",
        controls.iter().any(|c| c.starts_with("Button:"))
            && has(&controls, "Button", &l10n.two_step_copy_setup_key())
            && has(&controls, "Button", &l10n.two_step_open_authenticator()),
    );
    let key = cx
        .update(|cx| two_step_view(cx).and_then(|v| v.read(cx).setup.clone()))
        .map(|s| s.manual_key)
        .unwrap_or_default();
    in_two_step(cx, |v, _, cx| v.copy_setup_key(cx));
    let copied = cx.update(|cx| cx.read_from_clipboard().and_then(|c| c.text()));
    pass &= ok(
        "Copy Setup Key copies the key",
        !key.is_empty() && copied.as_deref() == Some(key.as_str()),
    );
    submit_code(&totp(&key, 0), cx).await;
    pass &= wait_stage(TwoStepStage::RecoveryCodes, cx).await;
    clear_toasts(cx);
    settle(cx, 400).await;
    shot(dir, "two-step-recovery-codes", cx).await;
    ax(current_setup(cx).await, "two-step-recovery-codes", dir, cx).await;
    let codes = cx
        .update(|cx| two_step_view(cx).and_then(|v| v.read(cx).challenge(cx)))
        .map(|c| c.recovery_codes)
        .unwrap_or_default();
    in_two_step(cx, |v, _, cx| v.copy_recovery_codes(cx));
    let copied = cx.update(|cx| cx.read_from_clipboard().and_then(|c| c.text()));
    pass &= ok(
        &format!("ten recovery codes, all copied ({})", codes.len()),
        codes.len() == 10 && copied.as_deref() == Some(codes.join("\n").as_str()),
    );
    pass &= ok(
        "not signed in until the codes were seen",
        cx.update(current_route) != Route::Main,
    );
    in_two_step(cx, |v, window, cx| v.submit(window, cx));
    pass &= signed_in("Continue after the recovery codes signs in", cx).await;
    pass &= sign_out(cx).await;

    // ── An administrator's reset ────────────────────────────────────────
    pass &= connect(&url, cx).await;
    let (reset_email, reset_password) = user("RESET");
    sign_in_password(&reset_email, &reset_password, cx).await;
    pass &= wait_stage(TwoStepStage::Recover, cx).await;
    settle(cx, 300).await;
    shot(dir, "two-step-recover", cx).await;
    submit_code("not-the-recovery-token", cx).await;
    let error = wait_two_step_error(cx).await;
    pass &= ok(
        &format!("a wrong recovery token is refused ({error:?})"),
        error.is_some(),
    );
    let ticket = inputs.get("OWUI_RESET_TOKEN").unwrap_or_default();
    submit_code(&ticket, cx).await;
    pass &= wait_stage(TwoStepStage::Enroll, cx).await;
    let loaded = wait_until(cx, Duration::from_secs(20), |cx| {
        two_step_view(cx).is_some_and(|v| v.read(cx).setup.is_some())
    })
    .await;
    pass &= ok("the reset leads on to a new authenticator", loaded);
    let key = cx
        .update(|cx| two_step_view(cx).and_then(|v| v.read(cx).setup.clone()))
        .map(|s| s.manual_key)
        .unwrap_or_default();
    submit_code(&totp(&key, 0), cx).await;
    pass &= wait_stage(TwoStepStage::RecoveryCodes, cx).await;
    in_two_step(cx, |v, window, cx| v.submit(window, cx));
    pass &= signed_in("the reset account signs in", cx).await;

    // ── The same step while adding a second account ─────────────────────
    cx.update(crate::start_adding_account);
    settle(cx, 800).await;
    connect_in_sheet(&url, "Second server", cx).await;
    let adding = wait_until(cx, Duration::from_secs(60), |cx| {
        let a = cx.global::<AppState>().stores.accounts.read(cx);
        a.adding() && current_route(cx) == Route::SignIn
    })
    .await;
    pass &= ok("Add Account leads to sign-in", adding);
    pass &= ok(
        "the new account signs in in the setup window",
        wait_setup(cx).await.is_some(),
    );
    settle(cx, 500).await;
    sign_in_password(&email, &password, cx).await;
    pass &= wait_stage(TwoStepStage::Verify, cx).await;
    shot(dir, "two-step-adding-account", cx).await;
    let code = steps.next(&secret, cx).await;
    submit_code(&code, cx).await;
    pass &= signed_in("the added account signs in through its step", cx).await;
    let two = cx.update(|cx| {
        cx.global::<AppState>()
            .stores
            .accounts
            .read(cx)
            .accounts()
            .len()
    });
    pass &= ok(&format!("two accounts now ({two})"), two == 2);
    pass &= sign_out(cx).await;
    pass &= sign_out(cx).await;

    // ── A session token, then that session ending ───────────────────────
    pass &= connect(&url, cx).await;
    in_setup(cx, |sw, _, cx| {
        sw.sign_in
            .update(cx, |s, cx| s.set_method(Method::Token, cx))
    });
    let jwt = inputs.get("OWUI_TWO_STEP_JWT").unwrap_or_default();
    token_sign_in(&jwt, cx).await;
    pass &= signed_in("a session token signs in", cx).await;
    // The password changed on the web, which ends every session of the
    // account: the next check finds this one gone, and signing in again
    // goes through the second step.
    let new_password = format!("{password}-renewed");
    let body = json!({"password": password, "new_password": new_password}).to_string();
    pass &= ok(
        "the server ends the session (a password change)",
        Command::new("/usr/bin/curl")
            .args([
                "-sf",
                "-X",
                "POST",
                "-H",
                &format!("Authorization: Bearer {jwt}"),
                "-H",
                "Content-Type: application/json",
                "--data",
                &body,
                &format!("{url}/api/v1/auths/update/password"),
            ])
            .output()
            .is_ok_and(|o| o.status.success()),
    );
    let password = new_password;
    let rpc = cx.update(|cx| cx.global::<AppState>().connection.read(cx).rpc());
    let _ = rpc
        .call::<conduit_protocol::methods::AuthRetry>(&conduit_protocol::NoParams)
        .await;
    cx.update(|cx| {
        let s = cx.global::<AppState>().stores.session.clone();
        s.update(cx, |s, cx| s.refresh(cx));
    });
    pass &= wait_route(cx, Route::SignIn, Duration::from_secs(60)).await;
    let expired = cx.update(|cx| {
        let s = cx.global::<AppState>().stores.clone();
        s.accounts
            .read(cx)
            .active()
            .is_some_and(|a| a.user.is_some())
    });
    pass &= ok("the expired account asks to sign in again", expired);
    settle(cx, 500).await;
    in_setup(cx, |sw, _, cx| {
        sw.sign_in
            .update(cx, |s, cx| s.set_method(Method::Password, cx))
    });
    sign_in_password(&email, &password, cx).await;
    pass &= wait_stage(TwoStepStage::Verify, cx).await;
    shot(dir, "two-step-after-expiry", cx).await;
    let code = steps.next(&secret, cx).await;
    submit_code(&code, cx).await;
    pass &= signed_in("signing in again goes through the second step", cx).await;
    pass &= sign_out(cx).await;

    if let Some(item) = saved_clipboard {
        cx.update(|cx| cx.write_to_clipboard(item));
    } else {
        cx.update(|cx| cx.write_to_clipboard(ClipboardItem::new_string(String::new())));
    }
    pass
}

pub async fn proxy(inputs: &E2eInputs, dir: &Path, cx: &mut AsyncApp) -> bool {
    let (Some(proxy), Some((_, email, password))) = (inputs.get("OWUI_PROXY_URL"), inputs.owui())
    else {
        return ok(
            "the local Open WebUI's fake sign-in proxy (owui.sh proxy start)",
            false,
        );
    };
    cx.update(conduit_components::announce::AnnouncementLog::install);
    let mut pass = fresh_profile(cx).await;
    pass &= ok("the setup window opened", wait_setup(cx).await.is_some());
    // Added through the proxy while it lets everything through, then it
    // guards the server, and its sign-in page remembers the user (an
    // identity provider with a live session sends them straight back).
    pass &= control(&proxy, "open");
    pass &= connect(&proxy, cx).await;
    pass &= control(&proxy, "guard");
    pass &= control(&proxy, "remember");
    let body = json!({"email": email, "password": password}).to_string();
    let script = format!(
        "fetch('/api/v1/auths/signin',{{method:'POST',headers:{{'Content-Type':'application/json'}},credentials:'include',body:{}}}).then(()=>{{location.href='/';}})",
        serde_json::to_string(&body).unwrap_or_default()
    );
    cx.update(|cx| cx.set_global(SsoScript(Some(script))));
    in_setup(cx, |sw, window, cx| {
        sw.sign_in.update(cx, |s, cx| s.start_sso(window, cx))
    });
    pass &= wait_route(cx, Route::Main, Duration::from_secs(90)).await;
    cx.update(|cx| cx.set_global(SsoScript(None)));
    pass &= wait_main(cx).await.is_some();
    let (account, renewable) = cx.update(|cx| {
        let s = cx.global::<AppState>().stores.clone();
        (
            s.accounts.read(cx).active().map(|a| a.id.clone()),
            s.session
                .read(cx)
                .auth
                .as_ref()
                .is_some_and(|a| a.can_renew_proxy),
        )
    });
    pass &= ok(
        "signed in through the proxy, which it can renew",
        account.is_some() && renewable,
    );

    // The proxy's session ends; the next server check meets its sign-in
    // page: the Connection Issue, not a sign-out.
    pass &= control(&proxy, "expire");
    cx.update(|cx| {
        let s = cx.global::<AppState>().stores.session.clone();
        s.update(cx, |s, cx| s.refresh_server(cx));
    });
    pass &= wait_route(cx, Route::ConnectionIssue, Duration::from_secs(30)).await;
    let Some(setup) = wait_setup(cx).await else {
        return ok("the setup window shows the issue", false);
    };
    settle(cx, 600).await;
    let page = in_setup(cx, |sw, _, cx| sw.page(cx));
    pass &= ok(
        &format!("the Connection Issue page ({page:?})"),
        page == Some(crate::views::setup_window::Page::ConnectionIssue),
    );
    let kept = cx.update(|cx| {
        let s = cx.global::<AppState>().stores.clone();
        let a = s.accounts.read(cx);
        (a.accounts().len(), a.active().map(|a| a.id.clone()))
    });
    pass &= ok(
        &format!("the account is kept ({})", kept.0),
        kept.0 == 1 && kept.1 == account,
    );
    shot(dir, "connection-issue-proxy", cx).await;
    let l10n = cx.update(|cx| cx.l10n().clone());
    let controls = ax(setup, "connection-issue-proxy", dir, cx).await;
    pass &= ok(
        "Sign Out, Try Again and Sign In to Proxy Again",
        has(&controls, "Button", &l10n.desktop_sign_out())
            && has(&controls, "Button", &l10n.desktop_try_again())
            && has(&controls, "Button", &l10n.proxy_auth_sign_in_again()),
    );

    // Try Again cannot get past the proxy: the page stays, saying so, and
    // VoiceOver hears what it says (the status line's live text); a second
    // Try Again that comes back the same is heard again (each outcome is
    // its own live region).
    for attempt in 1..=2 {
        let before = cx.update(|cx| conduit_components::announce::AnnouncementLog::len(cx));
        in_setup(cx, |sw, window, cx| {
            sw.connection_issue.update(cx, |v, cx| v.retry(window, cx))
        });
        let tried = wait_until(cx, Duration::from_secs(20), |cx| {
            setup_window(cx).is_some_and(|(_, v)| {
                let v = v.read(cx).connection_issue.read(cx);
                !v.holds() && v.tries == attempt
            })
        })
        .await;
        settle(cx, 800).await;
        let page = in_setup(cx, |sw, _, cx| sw.page(cx));
        pass &= ok(
            &format!(
                "Try Again ({attempt}) keeps the issue while the proxy turns it away ({page:?})"
            ),
            tried && page == Some(crate::views::setup_window::Page::ConnectionIssue),
        );
        // What the page says now: the try's error, or the issue's own line.
        let shown = in_setup(cx, |sw, _, cx| sw.connection_issue.read(cx).error.clone())
            .flatten()
            .unwrap_or_else(|| l10n.desktop_proxy_session_ended());
        let said: Vec<String> = cx.update(|cx| {
            conduit_components::announce::AnnouncementLog::texts(cx)
                .into_iter()
                .skip(before)
                .map(|t| t.to_string())
                .collect()
        });
        pass &= ok(
            &format!("…and VoiceOver hears “{shown}” once ({said:?})"),
            said.iter().filter(|t| **t == shown).count() == 1,
        );
    }
    shot(dir, "connection-issue-after-retry", cx).await;

    // Sign In to Proxy Again: its page sends the user straight back, and
    // the new session is saved into the same account.
    in_setup(cx, |sw, window, cx| {
        sw.connection_issue
            .update(cx, |v, cx| v.renew_proxy(window, cx))
    });
    pass &= wait_route(cx, Route::Main, Duration::from_secs(60)).await;
    pass &= wait_main(cx).await.is_some();
    let after = cx.update(|cx| {
        let s = cx.global::<AppState>().stores.clone();
        let a = s.accounts.read(cx);
        (
            a.accounts().len(),
            a.active().map(|a| a.id.clone()),
            s.session
                .read(cx)
                .auth
                .as_ref()
                .is_some_and(|a| a.is_authenticated),
        )
    });
    pass &= ok(
        "renewed in place: the same account, signed in",
        after.0 == 1 && after.1 == account && after.2,
    );
    let sign_ins = proxy_state(&proxy)
        .and_then(|s| s.get("sign_ins").and_then(Value::as_u64))
        .unwrap_or(0);
    pass &= ok(
        &format!("the proxy saw a second sign-in ({sign_ins})"),
        sign_ins >= 2,
    );
    settle(cx, 1000).await;
    clear_toasts(cx);
    shoot_main(dir, "main-after-proxy-renewal", cx).await;
    pass &= sign_out(cx).await;
    control(&proxy, "open");
    pass
}

// ── Helpers ─────────────────────────────────────────────────────────────

/// The server form (from the chooser when it shows), then sign-in.
async fn connect(url: &str, cx: &mut AsyncApp) -> bool {
    let _ = wait_setup(cx).await;
    in_setup(cx, |sw, window, cx| {
        sw.onboarding
            .update(cx, |o, cx| o.go(Step::Server, window, cx))
    });
    settle(cx, 400).await;
    connect_server(url, "Lab server", cx).await;
    wait_route(cx, Route::SignIn, Duration::from_secs(60)).await
}

fn two_step_view(cx: &App) -> Option<Entity<TwoStepView>> {
    let (_, view) = cx.try_global::<AppState>()?.setup_window.clone()?;
    Some(view.read(cx).sign_in.read(cx).two_step.clone())
}

fn stage(cx: &mut App) -> Option<TwoStepStage> {
    let session = cx.global::<AppState>().stores.session.read(cx);
    session
        .auth
        .as_ref()
        .filter(|a| !a.is_authenticated)
        .and_then(|a| a.two_step.as_ref())
        .map(|c| c.stage)
}

async fn wait_stage(want: TwoStepStage, cx: &mut AsyncApp) -> bool {
    let reached = wait_until(cx, Duration::from_secs(30), |cx| stage(cx) == Some(want)).await;
    let now = cx.update(stage);
    ok(&format!("the second step: {want:?} (now {now:?})"), reached)
}

fn in_two_step<R>(
    cx: &mut AsyncApp,
    f: impl FnOnce(&mut TwoStepView, &mut Window, &mut gpui_kit::Context<TwoStepView>) -> R,
) -> Option<R> {
    let (handle, _) = cx.update(setup_window)?;
    let view = cx.update(|cx| two_step_view(cx))?;
    handle
        .update(cx, |_, window, cx| {
            view.update(cx, |v, cx| f(v, window, cx))
        })
        .ok()
}

async fn submit_code(code: &str, cx: &mut AsyncApp) {
    let code = code.to_string();
    in_two_step(cx, move |v, window, cx| {
        let field = v.code.clone();
        set_text(&field, &code, window, cx);
        v.submit(window, cx);
    });
    settle(cx, 200).await;
}

async fn wait_two_step_error(cx: &mut AsyncApp) -> Option<String> {
    wait_until(cx, Duration::from_secs(20), |cx| {
        two_step_view(cx).is_some_and(|v| {
            let v = v.read(cx);
            !v.busy && v.error.is_some()
        })
    })
    .await;
    cx.update(|cx| two_step_view(cx).and_then(|v| v.read(cx).error.clone()))
}

async fn token_sign_in(token: &str, cx: &mut AsyncApp) {
    let token = token.to_string();
    in_setup(cx, move |sw, window, cx| {
        let view = sw.sign_in.clone();
        let field = view.read(cx).token.clone();
        set_text(&field, &token, window, cx);
        view.update(cx, |v, cx| v.submit(window, cx));
    });
    settle(cx, 200).await;
}

async fn wait_sign_in_error(cx: &mut AsyncApp) -> Option<String> {
    wait_until(cx, Duration::from_secs(30), |cx| {
        setup_window(cx).is_some_and(|(_, v)| {
            let s = v.read(cx).sign_in.read(cx);
            !s.busy && s.error.is_some()
        })
    })
    .await;
    cx.update(|cx| setup_window(cx).and_then(|(_, v)| v.read(cx).sign_in.read(cx).error.clone()))
}

/// The email field shows a stock address in the shots.
fn mask_email(cx: &mut AsyncApp) {
    in_setup(cx, |sw, window, cx| {
        let e = sw.sign_in.read(cx).email.clone();
        set_text(&e, "avery@example.org", window, cx);
    });
}

async fn signed_in(label: &str, cx: &mut AsyncApp) -> bool {
    let reached = wait_route(cx, Route::Main, Duration::from_secs(60)).await;
    let main = wait_main(cx).await.is_some();
    ok(label, reached && main)
}

/// Signs out of the active account (the sheet answered Sign Out); with no
/// other account, back to first run.
async fn sign_out(cx: &mut AsyncApp) -> bool {
    let before = cx.update(|cx| {
        cx.global::<AppState>()
            .stores
            .accounts
            .read(cx)
            .accounts()
            .len()
    });
    in_main(cx, |mw, window, cx| {
        crate::views::accounts::sign_out_active(&mw.stores, window, cx)
    });
    let done = wait_until(cx, Duration::from_secs(60), |cx| {
        let n = cx
            .global::<AppState>()
            .stores
            .accounts
            .read(cx)
            .accounts()
            .len();
        n < before && current_route(cx) != Route::Unknown
    })
    .await;
    settle(cx, 600).await;
    ok("signed out", done)
}

/// Tells the fake proxy what to do (`owui.sh proxy` controls).
fn control(proxy: &str, action: &str) -> bool {
    let out = Command::new("/usr/bin/curl")
        .args(["-sf", "-X", "POST", &format!("{proxy}/__proxy/{action}")])
        .output();
    ok(
        &format!("the fake proxy: {action}"),
        out.is_ok_and(|o| o.status.success()),
    )
}

fn proxy_state(proxy: &str) -> Option<Value> {
    let out = Command::new("/usr/bin/curl")
        .args(["-sf", &format!("{proxy}/__proxy/state")])
        .output()
        .ok()?;
    serde_json::from_slice(&out.stdout).ok()
}

/// The 30-second step now (RFC 6238).
fn step_now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
        / 30
}

/// An authenticator app's code for the base32 `secret`, `ahead` 30-second
/// steps from now (RFC 6238, HMAC-SHA1, six digits).
pub fn totp(secret: &str, ahead: u64) -> String {
    totp_at(secret, step_now() + ahead)
}

/// Codes for one account signed in to more than once: Open WebUI takes the
/// step before, now or after, but never one at or before the last it took,
/// so the next code waits for a fresh step when it must.
#[derive(Default)]
struct Steps {
    last: Option<u64>,
}

impl Steps {
    async fn next(&mut self, secret: &str, cx: &mut AsyncApp) -> String {
        if let Some(last) = self.last {
            while step_now() < last {
                settle(cx, 1000).await;
            }
        }
        let step = step_now() + 1;
        self.last = Some(step);
        totp_at(secret, step)
    }
}

fn totp_at(secret: &str, step: u64) -> String {
    let mac = hmac_sha1(&base32(secret), &step.to_be_bytes());
    let offset = (mac[19] & 0x0f) as usize;
    let value = (u32::from(mac[offset] & 0x7f) << 24)
        | (u32::from(mac[offset + 1]) << 16)
        | (u32::from(mac[offset + 2]) << 8)
        | u32::from(mac[offset + 3]);
    format!("{:06}", value % 1_000_000)
}

fn base32(text: &str) -> Vec<u8> {
    const ALPHABET: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
    let mut out = vec![];
    let (mut buffer, mut bits) = (0u32, 0u32);
    for c in text.bytes().map(|b| b.to_ascii_uppercase()) {
        let Some(v) = ALPHABET.iter().position(|&a| a == c) else {
            continue;
        };
        buffer = (buffer << 5) | v as u32;
        bits += 5;
        if bits >= 8 {
            bits -= 8;
            out.push((buffer >> bits) as u8);
            buffer &= (1 << bits) - 1;
        }
    }
    out
}

fn hmac_sha1(key: &[u8], message: &[u8]) -> [u8; 20] {
    let mut block = [0u8; 64];
    if key.len() > 64 {
        block[..20].copy_from_slice(&sha1(key));
    } else {
        block[..key.len()].copy_from_slice(key);
    }
    let inner: Vec<u8> = block
        .iter()
        .map(|b| b ^ 0x36)
        .chain(message.iter().copied())
        .collect();
    let inner = sha1(&inner);
    let outer: Vec<u8> = block
        .iter()
        .map(|b| b ^ 0x5c)
        .chain(inner.iter().copied())
        .collect();
    sha1(&outer)
}

fn sha1(data: &[u8]) -> [u8; 20] {
    let mut h: [u32; 5] = [
        0x6745_2301,
        0xEFCD_AB89,
        0x98BA_DCFE,
        0x1032_5476,
        0xC3D2_E1F0,
    ];
    let mut msg = data.to_vec();
    let bit_len = (data.len() as u64).wrapping_mul(8);
    msg.push(0x80);
    while msg.len() % 64 != 56 {
        msg.push(0);
    }
    msg.extend_from_slice(&bit_len.to_be_bytes());
    for chunk in msg.chunks(64) {
        let mut w = [0u32; 80];
        for (i, word) in chunk.chunks(4).enumerate() {
            w[i] = u32::from_be_bytes([word[0], word[1], word[2], word[3]]);
        }
        for i in 16..80 {
            w[i] = (w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16]).rotate_left(1);
        }
        let [mut a, mut b, mut c, mut d, mut e] = h;
        for (i, wi) in w.iter().enumerate() {
            let (f, k) = match i {
                0..=19 => ((b & c) | (!b & d), 0x5A82_7999),
                20..=39 => (b ^ c ^ d, 0x6ED9_EBA1),
                40..=59 => ((b & c) | (b & d) | (c & d), 0x8F1B_BCDC),
                _ => (b ^ c ^ d, 0xCA62_C1D6),
            };
            let t = a
                .rotate_left(5)
                .wrapping_add(f)
                .wrapping_add(e)
                .wrapping_add(k)
                .wrapping_add(*wi);
            e = d;
            d = c;
            c = b.rotate_left(30);
            b = a;
            a = t;
        }
        for (x, y) in h.iter_mut().zip([a, b, c, d, e]) {
            *x = x.wrapping_add(y);
        }
    }
    let mut out = [0u8; 20];
    for (i, x) in h.iter().enumerate() {
        out[i * 4..i * 4 + 4].copy_from_slice(&x.to_be_bytes());
    }
    out
}

/// Takes the toasts away (a shot of a page, not of the last notice).
pub(super) fn clear_toasts(cx: &mut AsyncApp) {
    cx.update(|cx| {
        let toasts = cx.global::<AppState>().stores.toasts.clone();
        let ids: Vec<u64> = toasts.read(cx).toasts.iter().map(|t| t.id).collect();
        toasts.update(cx, |t, cx| {
            for id in ids {
                t.dismiss(id, cx);
            }
        });
    });
}

/// The setup window now: a sign-out closes it for the main window and a new
/// one opens for the next sign-in.
async fn current_setup(cx: &mut AsyncApp) -> AnyWindowHandle {
    wait_setup(cx).await.expect("the setup window is open")
}

/// A page's shot in both appearances, without the toasts earlier steps left.
async fn shot(dir: &Path, name: &str, cx: &mut AsyncApp) {
    clear_toasts(cx);
    settle(cx, 200).await;
    shoot_setup(dir, name, cx).await;
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sha1_matches_its_test_vector() {
        let digest = sha1(b"abc");
        let hex: String = digest.iter().map(|b| format!("{b:02x}")).collect();
        assert_eq!(hex, "a9993e364706816aba3e25717850c26c9cd0d89d");
    }

    #[test]
    fn codes_follow_rfc_6238() {
        // RFC 6238's SHA-1 vector (the ASCII secret 12345678901234567890):
        // 94287082 at 59 s, of which an authenticator shows six digits.
        assert_eq!(
            totp_at("GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ", 59 / 30),
            "287082"
        );
        // 07081804 at 1111111109 s.
        assert_eq!(
            totp_at("GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ", 1_111_111_109 / 30),
            "081804"
        );
    }
}
