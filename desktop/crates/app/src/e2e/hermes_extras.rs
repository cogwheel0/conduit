//! `--e2e hermes-extras`: a Hermes connection's extras, against
//! real local Hermes Desktop gateways (`hermes serve --isolated`, each with
//! its own home, scripted model and synthetic data) beside the local Open
//! WebUI:
//!
//! * gateway A behind a stand-in for Cloudflare Access (a proxy that
//!   refuses a request without its two headers, and logs which it saw):
//!   the editor's headers make Test pass where it failed, are kept
//!   unseen, and carry the live connection (its sessions through the
//!   proxy); a reserved name is refused; Hermes Sign-In gives way when a
//!   header is added, as on a phone, but to Session Token (a phone turns
//!   to the dashboard, which this Mac's window can't send headers
//!   through), and says why when chosen again;
//! * A's profiles in the editor's menu (default and writer), the switch
//!   saved and back; the menu's fallback when the list cannot load;
//! * a toolset switched off in Settings, which the gateway reports, and on
//!   again; Reload Skills after a skill appeared in A's home, which
//!   Settings and the `/` list of an open Hermes chat then offer;
//! * an API server's memory key, kept unseen;
//! * gateway B, gated by the dashboard's own password sign-in: Dashboard
//!   in the editor, its sign-in window (the test fills the dashboard's own
//!   form), the session the daemon keeps carrying B's requests, and Sign
//!   Out.
//!
//! Screenshots in light and dark, AccessKit checks. Inputs from
//! `--e2e-env`: the Open WebUI's env (`FAKE_HERMES_URL`/`_KEY` among it),
//! and `HERMES_A_URL`, `HERMES_A_PROXY_URL`, `HERMES_A_TOKEN`,
//! `HERMES_A_HOME`, `HERMES_PROXY_LOG`, `HERMES_ACCESS_ID`,
//! `HERMES_ACCESS_SECRET`, `HERMES_B_URL`, `HERMES_B_USER`,
//! `HERMES_B_PASSWORD` (`h5/hermes-extras/hermes.sh env`).

use std::io::{Read as _, Write as _};
use std::path::Path;
use std::time::Duration;

use gpui_kit::{App, AsyncApp};

use super::chat::{chat_store, pane, sign_in};
use super::hermes_admin::{
    active_name, admin, connection_named, enabled, in_sheet, listed, open_editor, open_item,
    sessions, sheet_gone, shoot_settings, shoot_sheet, test_connection,
};
use super::*;
use crate::shell::sso::SsoScript;
use crate::stores::hermes_admin::Loaded;
use crate::stores::navigation::AreaItem;
use crate::views::forms;
use crate::views::hermes_connection::{Auth, HermesConnectionSheet, Note};
use crate::views::sheet;

/// Gateway A's seeded chat (`hermes-admin/scripts/chats_a.json`).
const A_CHAT: &str = "Balcony herb garden";
const A_NAME: &str = "Gated studio";
const MEMORY_NAME: &str = "Memory server";
const B_NAME: &str = "Dashboard gateway";
/// The skill the scenario adds to A's home before Reload Skills.
const NEW_SKILL: &str = "seed-swap";

fn sheet_state<R>(cx: &mut App, f: impl FnOnce(&HermesConnectionSheet, &App) -> R) -> Option<R> {
    let s = sheet::current::<HermesConnectionSheet>(cx)?;
    let s = s.read(cx);
    Some(f(s, cx))
}

fn connection(name: &str, cx: &mut App) -> Option<conduit_protocol::HermesConnectionDto> {
    admin(cx)
        .read(cx)
        .connections
        .as_ref()?
        .connections
        .iter()
        .find(|c| c.name == name)
        .cloned()
}

/// The access proxy's log: `(path, header names, passed)`, oldest first.
fn proxy_log(path: &str) -> Vec<(String, Vec<String>, bool)> {
    std::fs::read_to_string(path)
        .unwrap_or_default()
        .lines()
        .filter_map(|l| serde_json::from_str::<serde_json::Value>(l).ok())
        .map(|v| {
            (
                v["path"].as_str().unwrap_or_default().to_string(),
                v["headers"]
                    .as_array()
                    .map(|a| {
                        a.iter()
                            .filter_map(|h| h.as_str().map(str::to_string))
                            .collect()
                    })
                    .unwrap_or_default(),
                v["access"].as_bool().unwrap_or(false),
            )
        })
        .collect()
}

/// A GET to a gateway on this Mac with its session token: the body.
fn gateway_get(base: &str, path: &str, token: &str) -> Option<String> {
    let url = url::Url::parse(base).ok()?;
    let host = url.host_str()?.to_string();
    let port = url.port()?;
    let mut stream = std::net::TcpStream::connect((host.as_str(), port)).ok()?;
    stream
        .set_read_timeout(Some(Duration::from_secs(10)))
        .ok()?;
    write!(
        stream,
        "GET {path} HTTP/1.1\r\nHost: {host}:{port}\r\nX-Hermes-Session-Token: {token}\r\nAccept: application/json\r\nConnection: close\r\n\r\n"
    )
    .ok()?;
    let mut raw = String::new();
    stream.read_to_string(&mut raw).ok()?;
    let (_, body) = raw.split_once("\r\n\r\n")?;
    Some(body.to_string())
}

/// Whether gateway A reports toolset `name` on.
fn gateway_toolset_on(base: &str, token: &str, name: &str) -> Option<bool> {
    let body = gateway_get(base, "/api/tools/toolsets", token)?;
    let v: serde_json::Value = serde_json::from_str(&body).ok()?;
    let list = v.as_array().or_else(|| v["toolsets"].as_array())?;
    list.iter()
        .find(|t| t["name"].as_str() == Some(name))
        .and_then(|t| t["enabled"].as_bool())
}

fn catalog_toolset(name: &str, cx: &mut App) -> Option<bool> {
    admin(cx)
        .read(cx)
        .catalog
        .as_ref()
        .and_then(Loaded::ready)
        .and_then(|c| c.toolsets.iter().find(|t| t.name == name))
        .map(|t| t.enabled)
}

fn catalog_has_skill(name: &str, cx: &mut App) -> bool {
    admin(cx)
        .read(cx)
        .catalog
        .as_ref()
        .and_then(Loaded::ready)
        .is_some_and(|c| c.skills.iter().any(|s| s.name == name))
}

/// The open Hermes chat's `/` menu rows for `query`.
async fn slash_rows(query: &str, cx: &mut AsyncApp) -> Vec<String> {
    let query = query.to_string();
    super::chat::in_pane(cx, move |p, window, cx| {
        p.composer.update(cx, |c, cx| {
            c.focus_input(window, cx);
            c.set_text(&query, window, cx)
        })
    });
    settle(cx, 600).await;
    cx.update(|cx| {
        pane(cx)
            .and_then(|p| {
                let composer = p.read(cx).composer.clone();
                composer
                    .read(cx)
                    .menu_rows(cx)
                    .map(|(_, rows)| rows.into_iter().map(|(_, t)| t).collect())
            })
            .unwrap_or_default()
    })
}

/// Scrolls the Settings pane to `fraction` of its height (0 the top, 1 the
/// end), for a section below the fold to be shot.
async fn scroll_settings(fraction: f32, cx: &mut AsyncApp) {
    cx.update(|cx| {
        cx.set_global(conduit_components::views::settings::PaneScrollRequest(
            Some(fraction),
        ));
        let handle = cx
            .global::<AppState>()
            .settings_window
            .as_ref()
            .map(|(h, _)| *h);
        if let Some(handle) = handle {
            let _ = handle.update(cx, |_, window, _| window.refresh());
        }
    });
    settle(cx, 500).await;
}

/// Sets header row `i` (adding rows as needed) of the open editor.
fn set_header(i: usize, name: &str, value: &str, cx: &mut AsyncApp) {
    let (name, value) = (name.to_string(), value.to_string());
    in_sheet::<HermesConnectionSheet, _>(cx, move |s, w, cx| {
        while s.headers.len() <= i {
            s.add_header(w, cx);
        }
        let row = &s.headers[i];
        let (n, v) = (row.name.clone(), row.value.clone());
        set_text(&n, &name, w, cx);
        set_text(&v, &value, w, cx);
        cx.notify();
    });
}

pub async fn run(inputs: &E2eInputs, dir: &Path, cx: &mut AsyncApp) -> bool {
    let want = [
        "HERMES_A_URL",
        "HERMES_A_PROXY_URL",
        "HERMES_A_TOKEN",
        "HERMES_A_HOME",
        "HERMES_PROXY_LOG",
        "HERMES_ACCESS_ID",
        "HERMES_ACCESS_SECRET",
        "HERMES_B_URL",
        "HERMES_B_USER",
        "HERMES_B_PASSWORD",
        "FAKE_HERMES_URL",
        "FAKE_HERMES_KEY",
    ];
    let got: Vec<Option<String>> = want.iter().map(|k| inputs.get(k)).collect();
    if got.iter().any(Option::is_none) {
        return ok(
            "the gateways' env (h5/hermes-extras/hermes.sh env) and the Open WebUI's are there",
            false,
        );
    }
    let v = |k: &str| {
        got[want.iter().position(|w| *w == k).unwrap_or(0)]
            .clone()
            .unwrap_or_default()
    };
    let (a_url, proxy_url, a_token, a_home) = (
        v("HERMES_A_URL"),
        v("HERMES_A_PROXY_URL"),
        v("HERMES_A_TOKEN"),
        v("HERMES_A_HOME"),
    );
    let (proxy_log_path, access_id, access_secret) = (
        v("HERMES_PROXY_LOG"),
        v("HERMES_ACCESS_ID"),
        v("HERMES_ACCESS_SECRET"),
    );
    let (b_url, b_user, b_password) = (
        v("HERMES_B_URL"),
        v("HERMES_B_USER"),
        v("HERMES_B_PASSWORD"),
    );
    let (fake_url, fake_key) = (v("FAKE_HERMES_URL"), v("FAKE_HERMES_KEY"));
    let Some((url, email, password)) = inputs.owui() else {
        return ok(NO_SERVER, false);
    };
    let mut pass = sign_in(&url, &email, &password, cx).await;
    if wait_main(cx).await.is_none() {
        return ok("main window", false);
    }
    cx.update(|cx| crate::open_settings(Some(crate::views::settings::Tab::Hermes), cx));
    let listed_none = wait_until(cx, Duration::from_secs(20), |cx| {
        admin(cx).read(cx).connections.is_some()
    })
    .await;
    pass &= ok("Settings › Hermes is read", listed_none);

    // ── Access headers, behind the stand-in for Cloudflare Access ────
    pass &= ok(
        "Add Connection… opens the editor",
        open_editor(None, cx).await,
    );
    let (p2, t2) = (proxy_url.clone(), a_token.clone());
    in_sheet::<HermesConnectionSheet, _>(cx, move |s, w, cx| {
        set_text(&s.name.clone(), A_NAME, w, cx);
        set_text(&s.url.clone(), &p2, w, cx);
        s.desktop = true;
        s.auth = Auth::Token;
        set_text(&s.token.clone(), &t2, w, cx);
        cx.notify();
    });
    settle(cx, 300).await;
    pass &= ok(
        "without its headers the gateway behind Access refuses the test",
        !test_connection(cx).await,
    );
    let refused = proxy_log(&proxy_log_path)
        .iter()
        .any(|(_, _, passed)| !passed);
    pass &= ok("the proxy saw requests without the headers", refused);
    // As on a phone, a header-protected gateway is not signed in to
    // natively (the core refuses it). A phone turns to the dashboard; this
    // Mac's dashboard window can't send headers either, so the editor
    // turns to Session Token, the one way that sends them, and never
    // leaves a sign-in it can't use selected.
    in_sheet::<HermesConnectionSheet, _>(cx, |s, _, cx| {
        s.auth = Auth::Native;
        cx.notify();
    });
    set_header(0, "CF-Access-Client-Id", &access_id, cx);
    let moved = cx.update(|cx| sheet_state(cx, |s, _| s.auth)) == Some(Auth::Token);
    pass &= ok(
        "adding a header turns Hermes Sign-In into Session Token, not the Mac's header-less Dashboard",
        moved,
    );
    // Chosen again by hand, Hermes Sign-In says why it can't (its button
    // is off with the note, as Dashboard's is).
    in_sheet::<HermesConnectionSheet, _>(cx, |s, _, cx| {
        s.auth = Auth::Native;
        cx.notify();
    });
    settle(cx, 300).await;
    let note = cx
        .update(|cx| sheet_state(cx, |s, cx| s.shown_sign_in_note(cx)))
        .flatten()
        .unwrap_or_default();
    pass &= ok(
        "with headers, Hermes Sign-In says it can't send them and points to a session token",
        note.contains("Hermes Sign-In can't send custom headers") && note.contains("session token"),
    );
    shoot_sheet(dir, "hermes-extras-headers-native", cx).await;
    in_sheet::<HermesConnectionSheet, _>(cx, |s, _, cx| {
        s.auth = Auth::Token;
        cx.notify();
    });
    set_header(1, "CF-Access-Client-Secret", &access_secret, cx);
    settle(cx, 300).await;
    shoot_sheet(dir, "hermes-extras-headers-new", cx).await;
    if let Some(handle) = cx.update(|cx| sheet::current_window(cx)) {
        let controls = ax(handle, "hermes-extras-headers-new", dir, cx).await;
        pass &= ok(
            "the editor has header rows with names, masked values, Add Header and Remove Header",
            has(&controls, "Button", "Add Header")
                && has(&controls, "Button", "Remove Header")
                && has(&controls, "TextInput", "Header Name")
                && has(&controls, "PasswordInput", "Header Value"),
        );
    }
    let before = proxy_log(&proxy_log_path).len();
    pass &= ok(
        "with its headers Test Connection reaches gateway A through Access",
        test_connection(cx).await,
    );
    let sent = proxy_log(&proxy_log_path)
        .into_iter()
        .skip(before)
        .any(|(_, headers, passed)| {
            passed
                && headers.iter().any(|h| h == "cf-access-client-id")
                && headers.iter().any(|h| h == "cf-access-client-secret")
        });
    pass &= ok("the proxy saw both access headers on the test", sent);
    // A reserved name is refused, and says which.
    set_header(2, "Cookie", "nope", cx);
    in_sheet::<HermesConnectionSheet, _>(cx, |s, w, cx| s.save(w, cx));
    let named = wait_until(cx, Duration::from_secs(15), |cx| {
        sheet_state(cx, |s, _| {
            s.header_error
                .as_deref()
                .is_some_and(|e| e.contains("Cookie"))
        })
        .unwrap_or(false)
    })
    .await;
    pass &= ok("a reserved header name is refused by name", named);
    settle(cx, 300).await;
    cx.update(|cx| sheet::scroll_to(1.0, cx));
    settle(cx, 400).await;
    shoot_sheet(dir, "hermes-extras-header-error", cx).await;
    cx.update(|cx| sheet::scroll_to(0.0, cx));
    in_sheet::<HermesConnectionSheet, _>(cx, |s, w, cx| s.remove_header(2, w, cx));
    in_sheet::<HermesConnectionSheet, _>(cx, |s, w, cx| s.save(w, cx));
    pass &= ok("Save closes the editor", sheet_gone(cx).await);
    let saved = wait_until(cx, Duration::from_secs(20), |cx| {
        connection(A_NAME, cx).is_some_and(|c| {
            c.access_header_names == ["CF-Access-Client-Id", "CF-Access-Client-Secret"]
        }) && active_name(cx).as_deref() == Some(A_NAME)
            && enabled(cx)
    })
    .await;
    pass &= ok(
        "the connection keeps both headers by name and is in use",
        saved,
    );
    let through = wait_until(cx, Duration::from_secs(60), |cx| listed(A_CHAT, cx)).await;
    pass &= ok(
        "its sessions are listed through Access (the live connection sends the headers)",
        through,
    );
    let ws = proxy_log(&proxy_log_path)
        .iter()
        .any(|(path, _, passed)| *passed && path.starts_with("/api/ws"));
    pass &= ok(
        "the gateway's socket went through Access with the headers",
        ws,
    );
    let a_id = cx.update(|cx| connection_named(A_NAME, cx));
    pass &= ok(
        "its editor opens again",
        open_editor(a_id.clone(), cx).await,
    );
    let masked = cx.update(|cx| {
        sheet_state(cx, |s, cx| {
            s.headers.len() == 2
                && s.headers.iter().all(|r| {
                    forms::raw(&r.value, cx).is_empty()
                        && forms::hint(&r.value, cx).is_some_and(|h| h.contains("Configured"))
                })
        })
        .unwrap_or(false)
    });
    pass &= ok(
        "the saved headers show their names; their values stay hidden",
        masked,
    );

    // ── Profiles ─────────────────────────────────────────────────────
    let profiles = wait_until(cx, Duration::from_secs(40), |cx| {
        sheet_state(cx, |s, _| {
            !s.profiles.loading
                && s.profiles.names.iter().any(|p| p == "default")
                && s.profiles.names.iter().any(|p| p == "writer")
        })
        .unwrap_or(false)
    })
    .await;
    pass &= ok(
        "the profile menu lists the gateway's profiles (default, writer)",
        profiles,
    );
    settle(cx, 300).await;
    shoot_sheet(dir, "hermes-extras-headers-saved", cx).await;
    if let Some(handle) = cx.update(|cx| sheet::current_window(cx)) {
        let controls = ax(handle, "hermes-extras-profiles", dir, cx).await;
        pass &= ok(
            "the profile is a pop-up beside Refresh Profiles",
            has(&controls, "ComboBox", "Profile") && has(&controls, "Button", "Refresh Profiles"),
        );
    }
    pass &= ok(
        "its kept headers still pass the test",
        test_connection(cx).await,
    );
    in_sheet::<HermesConnectionSheet, _>(cx, |s, w, cx| s.choose_profile("writer", w, cx));
    in_sheet::<HermesConnectionSheet, _>(cx, |s, w, cx| s.save(w, cx));
    pass &= ok("Save closes the editor", sheet_gone(cx).await);
    let switched = wait_until(cx, Duration::from_secs(20), |cx| {
        connection(A_NAME, cx).is_some_and(|c| c.desktop_profile == "writer")
    })
    .await;
    pass &= ok("the writer profile is saved", switched);
    pass &= ok(
        "its editor opens again",
        open_editor(a_id.clone(), cx).await,
    );
    in_sheet::<HermesConnectionSheet, _>(cx, |s, w, cx| s.choose_profile("default", w, cx));
    in_sheet::<HermesConnectionSheet, _>(cx, |s, w, cx| s.save(w, cx));
    pass &= ok("Save closes the editor", sheet_gone(cx).await);
    let back = wait_until(cx, Duration::from_secs(20), |cx| {
        connection(A_NAME, cx).is_some_and(|c| c.desktop_profile == "default")
    })
    .await;
    pass &= ok("and back to default", back);
    // The fallback: a gateway that cannot be reached keeps the profile and
    // says why.
    pass &= ok(
        "Add Connection… opens the editor",
        open_editor(None, cx).await,
    );
    let closed = std::net::TcpListener::bind("127.0.0.1:0")
        .ok()
        .and_then(|l| l.local_addr().ok())
        .map(|a| a.port())
        .unwrap_or(9);
    in_sheet::<HermesConnectionSheet, _>(cx, move |s, w, cx| {
        set_text(&s.url.clone(), &format!("http://127.0.0.1:{closed}"), w, cx);
        s.desktop = true;
        s.auth = Auth::Token;
        set_text(&s.token.clone(), "demo-token", w, cx);
        s.load_profiles(w, cx);
    });
    let fallback = wait_until(cx, Duration::from_secs(30), |cx| {
        sheet_state(cx, |s, _| {
            !s.profiles.loading
                && s.profiles.issue.as_deref() == Some("signInFirst")
                && s.profile == "default"
        })
        .unwrap_or(false)
    })
    .await;
    pass &= ok(
        "an unreachable gateway keeps the profile and asks to sign in, then refresh",
        fallback,
    );
    settle(cx, 300).await;
    shoot_sheet(dir, "hermes-extras-profiles-fallback", cx).await;
    cx.update(sheet::dismiss);
    pass &= ok("the editor closes", sheet_gone(cx).await);

    // ── Toolsets ─────────────────────────────────────────────────────
    let read = wait_until(cx, Duration::from_secs(40), |cx| {
        admin(cx)
            .read(cx)
            .catalog
            .as_ref()
            .and_then(Loaded::ready)
            .is_some_and(|c| !c.toolsets.is_empty())
    })
    .await;
    pass &= ok("the gateway's toolsets are read", read);
    let toolset = cx.update(|cx| {
        admin(cx)
            .read(cx)
            .catalog
            .as_ref()
            .and_then(Loaded::ready)
            .and_then(|c| {
                c.toolsets
                    .iter()
                    .find(|t| t.name == "vision" && t.enabled)
                    .or_else(|| c.toolsets.iter().find(|t| t.enabled))
                    .map(|t| (t.name.clone(), t.label.clone()))
            })
    });
    if let Some((name, label)) = toolset {
        let pane = shoot_settings(dir, "hermes-extras-toolsets", cx).await;
        let shown = if label.trim().is_empty() {
            &name
        } else {
            &label
        };
        pass &= ok(
            "Settings shows each toolset as a switch, and Reload Skills",
            has(&pane, "Switch", shown) && has(&pane, "Button", "Reload Skills"),
        );
        let n = name.clone();
        cx.update(move |cx| {
            let stores = cx.global::<AppState>().stores.clone();
            let s = stores.clone();
            stores
                .hermes_admin
                .update(cx, |a, cx| a.set_toolset(&s, &n, false, cx));
        });
        let n = name.clone();
        let off = wait_until(cx, Duration::from_secs(30), move |cx| {
            catalog_toolset(&n, cx) == Some(false)
        })
        .await;
        pass &= ok(&format!("switching {name} off shows it off"), off);
        pass &= ok(
            &format!("the gateway reports {name} off"),
            gateway_toolset_on(&a_url, &a_token, &name) == Some(false),
        );
        settle(cx, 300).await;
        scroll_settings(1.0, cx).await;
        shoot_settings(dir, "hermes-extras-toolset-off", cx).await;
        scroll_settings(0.0, cx).await;
        let n = name.clone();
        cx.update(move |cx| {
            let stores = cx.global::<AppState>().stores.clone();
            let s = stores.clone();
            stores
                .hermes_admin
                .update(cx, |a, cx| a.set_toolset(&s, &n, true, cx));
        });
        let n = name.clone();
        let on = wait_until(cx, Duration::from_secs(30), move |cx| {
            catalog_toolset(&n, cx) == Some(true)
        })
        .await;
        pass &= ok(
            "and on again, which the gateway reports too",
            on && gateway_toolset_on(&a_url, &a_token, &name) == Some(true),
        );
    } else {
        pass &= ok("an enabled toolset to switch", false);
    }

    // ── Reload Skills ────────────────────────────────────────────────
    let herb = cx.update(|cx| sessions(cx).into_iter().find(|s| s.title == A_CHAT));
    if let Some(herb) = herb {
        open_item(AreaItem::HermesSession(herb.id.clone()), cx);
        let chat_id = format!("local:hermes_{}", herb.id);
        let opened = wait_until(cx, Duration::from_secs(30), move |cx| {
            chat_store(cx).is_some_and(|s| s.read(cx).chat_id() == chat_id)
        })
        .await;
        pass &= ok("a Hermes session opens", opened);
        settle(cx, 600).await;
        let before = slash_rows("/seed", cx).await;
        pass &= ok(
            &format!("/ does not list /{NEW_SKILL} yet ({} rows)", before.len()),
            !before.iter().any(|r| r == &format!("/{NEW_SKILL}")),
        );
        // A skill appears in the gateway's home (synthetic).
        let skill_dir = Path::new(&a_home).join("skills").join(NEW_SKILL);
        let wrote = std::fs::create_dir_all(&skill_dir).is_ok()
            && std::fs::write(
                skill_dir.join("SKILL.md"),
                "---\nname: seed-swap\ndescription: Plans a seed swap with neighbours (synthetic demo skill).\n---\nList five easy seeds to swap and a short note to invite neighbours.\n",
            )
            .is_ok();
        pass &= ok("a new skill is written to gateway A's home", wrote);
        cx.update(|cx| {
            let stores = cx.global::<AppState>().stores.clone();
            let s = stores.clone();
            stores
                .hermes_admin
                .update(cx, |a, cx| a.reload_skills(&s, cx));
        });
        let reloaded = wait_until(cx, Duration::from_secs(40), |cx| {
            catalog_has_skill(NEW_SKILL, cx) && !admin(cx).read(cx).skills_reloading
        })
        .await;
        pass &= ok("Reload Skills: Settings lists the new skill", reloaded);
        let listed_now = wait_until(cx, Duration::from_secs(20), |cx| {
            pane(cx).is_some_and(|p| {
                let composer = p.read(cx).composer.clone();
                composer.read(cx).menu_rows(cx).is_some_and(|(_, rows)| {
                    rows.iter().any(|(_, t)| t == &format!("/{NEW_SKILL}"))
                })
            })
        })
        .await;
        pass &= ok(
            "and the open Hermes chat's / lists it, without retyping",
            listed_now,
        );
        settle(cx, 300).await;
        shoot_main(dir, "hermes-extras-slash-reloaded", cx).await;
        super::chat::in_pane(cx, |p, window, cx| {
            p.composer.update(cx, |c, cx| c.set_text("", window, cx))
        });
        scroll_settings(0.75, cx).await;
        shoot_settings(dir, "hermes-extras-skills-reloaded", cx).await;
        scroll_settings(0.0, cx).await;
    } else {
        pass &= ok("the herb garden session", false);
    }

    // ── An API server's memory key ───────────────────────────────────
    pass &= ok(
        "Add Connection… opens the editor",
        open_editor(None, cx).await,
    );
    let (f2, k2) = (fake_url.clone(), fake_key.clone());
    in_sheet::<HermesConnectionSheet, _>(cx, move |s, w, cx| {
        set_text(&s.name.clone(), MEMORY_NAME, w, cx);
        set_text(&s.url.clone(), &f2, w, cx);
        s.desktop = false;
        set_text(&s.api_key.clone(), &k2, w, cx);
        set_text(&s.memory_key.clone(), "h5-demo-memory", w, cx);
        cx.notify();
    });
    settle(cx, 300).await;
    shoot_sheet(dir, "hermes-extras-memory-key", cx).await;
    in_sheet::<HermesConnectionSheet, _>(cx, |s, w, cx| s.save(w, cx));
    pass &= ok("Save closes the editor", sheet_gone(cx).await);
    let kept = wait_until(cx, Duration::from_secs(20), |cx| {
        connection(MEMORY_NAME, cx).is_some_and(|c| c.has_memory_key && c.mode == "responses")
    })
    .await;
    pass &= ok("the API server's memory key is saved", kept);
    let m_id = cx.update(|cx| connection_named(MEMORY_NAME, cx));
    pass &= ok("its editor opens again", open_editor(m_id, cx).await);
    let hidden = cx.update(|cx| {
        sheet_state(cx, |s, cx| {
            forms::raw(&s.memory_key, cx).is_empty()
                && forms::hint(&s.memory_key, cx).is_some_and(|h| h.contains("Configured"))
        })
        .unwrap_or(false)
    });
    pass &= ok("the kept memory key stays hidden", hidden);
    in_sheet::<HermesConnectionSheet, _>(cx, |s, w, cx| s.delete(w, cx));
    pass &= ok("Delete… (asked) closes the editor", sheet_gone(cx).await);

    // ── Dashboard sign-in, gateway B ─────────────────────────────────
    pass &= ok(
        "Add Connection… opens the editor",
        open_editor(None, cx).await,
    );
    let b2 = b_url.clone();
    in_sheet::<HermesConnectionSheet, _>(cx, move |s, w, cx| {
        set_text(&s.name.clone(), B_NAME, w, cx);
        set_text(&s.url.clone(), &b2, w, cx);
        s.desktop = true;
        s.auth = Auth::Dashboard;
        cx.notify();
    });
    settle(cx, 300).await;
    shoot_sheet(dir, "hermes-extras-dashboard", cx).await;
    if let Some(handle) = cx.update(|cx| sheet::current_window(cx)) {
        let controls = ax(handle, "hermes-extras-dashboard", dir, cx).await;
        pass &= ok(
            "Dashboard sits beside Hermes Sign-In and Session Token, with Open Dashboard Sign-In",
            has(&controls, "Button", "Open Dashboard Sign-In"),
        );
    }
    // Stands in for the user on the dashboard's own sign-in page: its
    // form, filled and sent as a person would.
    let script = format!(
        "setTimeout(function(){{var f=document.querySelector('form[data-provider=\"basic\"]')||document.querySelector('form');f.querySelector('input[name=username]').value={};f.querySelector('input[name=password]').value={};f.requestSubmit?f.requestSubmit():f.submit();}},4000);",
        serde_json::to_string(&b_user).unwrap_or_default(),
        serde_json::to_string(&b_password).unwrap_or_default()
    );
    cx.update(|cx| cx.set_global(SsoScript(Some(script))));
    let before: Vec<_> = cx.update(|cx| cx.windows());
    let windows_before = before.len();
    in_sheet::<HermesConnectionSheet, _>(cx, |s, w, cx| s.sign_in_dashboard(w, cx));
    let window_opened = wait_until(cx, Duration::from_secs(20), move |cx| {
        cx.windows().len() > windows_before
    })
    .await;
    pass &= ok("the dashboard's sign-in window opens", window_opened);
    if window_opened {
        // The dashboard's sign-in page, before the test script fills it.
        settle(cx, 2000).await;
        let opened = cx.update(|cx| {
            cx.windows()
                .into_iter()
                .find(|w| !before.iter().any(|b| b.window_id() == w.window_id()))
        });
        if let Some(handle) = opened {
            crate::smoke::shoot(handle, dir.join("hermes-extras-dashboard-window.png"), cx).await;
        }
    }
    let signed = wait_until(cx, Duration::from_secs(90), |cx| {
        connection(B_NAME, cx).is_some_and(|c| c.dashboard_signed_in && c.active)
    })
    .await;
    pass &= ok(
        "signing in on the dashboard's own page hands the session to the daemon; B is in use",
        signed,
    );
    cx.update(|cx| cx.set_global(SsoScript(None)));
    let closed = wait_until(cx, Duration::from_secs(10), move |cx| {
        cx.windows().len() <= windows_before
    })
    .await;
    pass &= ok("the sign-in window closed itself", closed);
    let tested = wait_until(cx, Duration::from_secs(40), |cx| {
        sheet_state(cx, |s, _| {
            !s.busy && matches!(&s.note, Some(Note::Tested { ok: true, .. }))
        })
        .unwrap_or(false)
    })
    .await;
    pass &= ok("then the connection is tested, through the session", tested);
    settle(cx, 300).await;
    shoot_sheet(dir, "hermes-extras-dashboard-signed-in", cx).await;
    cx.update(sheet::dismiss);
    let _ = sheet_gone(cx).await;
    let through = wait_until(cx, Duration::from_secs(40), |cx| {
        let a = admin(cx);
        let a = a.read(cx);
        a.status
            .as_ref()
            .and_then(Loaded::ready)
            .is_some_and(|s| s.reachable)
            && a.catalog
                .as_ref()
                .and_then(Loaded::ready)
                .is_some_and(|c| !c.toolsets.is_empty())
    })
    .await;
    pass &= ok(
        "B's status and toolsets are read with the dashboard session",
        through,
    );
    shoot_settings(dir, "hermes-extras-dashboard-settings", cx).await;
    let b_id = cx.update(|cx| connection_named(B_NAME, cx));
    pass &= ok("B's editor opens again", open_editor(b_id, cx).await);
    in_sheet::<HermesConnectionSheet, _>(cx, |s, w, cx| s.sign_out(w, cx));
    let out = wait_until(cx, Duration::from_secs(30), |cx| {
        connection(B_NAME, cx).is_some_and(|c| !c.dashboard_signed_in)
    })
    .await;
    pass &= ok("Sign Out drops the dashboard session", out);
    cx.update(sheet::dismiss);
    let _ = sheet_gone(cx).await;

    // Back to A, for whoever runs next.
    if let Some(id) = a_id {
        cx.update(|cx| {
            let stores = cx.global::<AppState>().stores.clone();
            crate::stores::hermes_admin::activate(&stores, &id, cx);
        });
        let back = wait_until(cx, Duration::from_secs(20), |cx| {
            active_name(cx).as_deref() == Some(A_NAME)
        })
        .await;
        pass &= ok("A is in use again", back);
    }
    pass
}
