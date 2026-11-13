//! `--e2e shell`: the macOS shell extras on the local Open WebUI and its
//! fake model, as `chat`, driven in-process through the paths the system
//! calls:
//!
//! * the composer names the selected model after a send, and the
//!   toolbar's Show Sidebar button with the sidebar hidden;
//! * links as `on_open_urls` hands them over: `new?q=` prefills a new chat
//!   without sending, `chat/<id>` opens the chat, `settings/<tab>` opens
//!   that tab, `channel/` toasts, others are ignored;
//! * Open with: synthetic files, ten attached through the upload path, the
//!   rest refused with toasts;
//! * Settings › Desktop and the hotkey status (and a rebind);
//! * Quick Ask: ask, answer, Open in Conduit;
//! * notifications under quiet (provisional) permission, which needs no
//!   prompt: an answer finishing out of sight is delivered with the chat's
//!   title and "The answer is ready." (never the answer), a failed one with the
//!   error title, and a click (the delegate's path) opens the chat;
//! * close to the menu bar and back, from the menu-bar item and a link;
//! * open at login: register, status, unregister.
//!
//! [`probe`] (`--probe <file>`) is for the links and files the system
//! hands a real launch (`open -a … 'conduit://…'`, cold and warm): it
//! writes the app's state to `<file>` and quits when `<file>.quit` exists.
//! It also runs the commands a driver appends to `<file>.cmd`, which the
//! release rehearsal's update test uses to check for updates and answer
//! Sparkle's windows (listed in `<file>.panels.json`).

use std::path::{Path, PathBuf};
use std::time::Duration;

use gpui_kit::{App, AsyncApp, Entity};
use serde_json::json;

use super::chat::{chat_store, dispatch, in_pane, pane, send, sign_in, wait_answer, wait_models};
use super::*;
use crate::desktop;
use crate::stores::navigation::Selection;
use crate::stores::shell::{HotkeyState, LoginState, NotificationAccess};
use crate::views::quick_ask::QuickAskView;

fn selection(cx: &mut App) -> Selection {
    cx.global::<AppState>()
        .stores
        .navigation
        .read(cx)
        .selection()
        .clone()
}

fn composer_text(cx: &mut App) -> String {
    pane(cx)
        .map(|p| {
            let c = p.read(cx).composer.clone();
            c.read(cx).text(cx)
        })
        .unwrap_or_default()
}

fn toasts(cx: &mut App) -> Vec<String> {
    cx.global::<AppState>()
        .stores
        .toasts
        .read(cx)
        .toasts
        .iter()
        .map(|t| t.message.clone())
        .collect()
}

fn shell_store(cx: &mut App) -> Entity<crate::stores::shell::ShellStore> {
    cx.global::<desktop::Desktop>().shell.clone()
}

pub(super) fn quick_ask(cx: &mut App) -> Option<(gpui_kit::AnyWindowHandle, Entity<QuickAskView>)> {
    cx.try_global::<desktop::Desktop>()?.quick_ask.clone()
}

fn settings_tab(cx: &mut App) -> Option<Tab> {
    let (handle, view) = cx.global::<AppState>().settings_window.clone()?;
    cx.windows().contains(&handle).then(|| view.read(cx).tab)
}

pub(super) fn links(urls: &[&str], cx: &mut AsyncApp) {
    let urls: Vec<String> = urls.iter().map(|u| u.to_string()).collect();
    cx.update(|cx| desktop::handle_urls(urls, cx));
}

fn close_settings(cx: &mut AsyncApp) {
    cx.update(|cx| {
        if let Some((handle, _)) = cx.global::<AppState>().settings_window.clone() {
            let _ = handle.update(cx, |_, window, _| window.remove_window());
        }
    });
}

/// The Quick Ask window's chat has a finished, stored answer.
pub(super) async fn wait_quick_answer(cx: &mut AsyncApp, timeout: Duration) -> bool {
    wait_until(cx, timeout, |cx| {
        let Some((_, view)) = quick_ask(cx) else {
            return false;
        };
        let Some(store) = view.read(cx).chat.as_ref().map(|c| c.store.clone()) else {
            return false;
        };
        let s = store.read(cx);
        let last = s.rows().last().and_then(|r| s.item(*r));
        !s.is_streaming()
            && s.live.is_none()
            && s.pending.is_none()
            && last.is_some_and(|i| i.role == crate::stores::chat::Role::Assistant)
    })
    .await
}

pub(super) fn quick_send(text: &str, cx: &mut AsyncApp) {
    let text = text.to_string();
    cx.update(|cx| {
        let Some((handle, view)) = quick_ask(cx) else {
            return;
        };
        let _ = handle.update(cx, |_, window, cx| {
            view.update(cx, |v, cx| {
                v.composer.update(cx, |c, cx| {
                    c.set_text(&text, window, cx);
                    c.submit(window, cx);
                })
            })
        });
    });
}

pub(super) fn quick_new_chat(cx: &mut AsyncApp) {
    cx.update(|cx| {
        if let Some((handle, view)) = quick_ask(cx) {
            let _ = handle.update(cx, |_, window, cx| {
                view.update(cx, |v, cx| v.new_chat(window, cx))
            });
        }
    });
}

fn quick_chat_id(cx: &mut App) -> Option<String> {
    let (_, view) = quick_ask(cx)?;
    view.read(cx).chat_id(cx)
}

async fn delivered(cx: &mut AsyncApp) -> Vec<crate::shell::notifications::Delivered> {
    let rx = cx.update(|cx| desktop::delivered_notifications(cx));
    match rx {
        Some(rx) => rx.await.unwrap_or_default(),
        None => vec![],
    }
}

async fn wait_delivered(
    id: &str,
    cx: &mut AsyncApp,
    timeout: Duration,
) -> Option<crate::shell::notifications::Delivered> {
    let deadline = std::time::Instant::now() + timeout;
    loop {
        if let Some(n) = delivered(cx).await.into_iter().find(|n| n.id == id) {
            return Some(n);
        }
        if std::time::Instant::now() > deadline {
            return None;
        }
        settle(cx, 300).await;
    }
}

/// Synthetic files for Open with: three of different kinds, nine more
/// small ones, and one sparse file over 256 MB.
fn synthetic_files(dir: &Path) -> Vec<PathBuf> {
    std::fs::create_dir_all(dir).ok();
    let mut out = vec![];
    let mut write = |name: &str, bytes: &[u8]| {
        let p = dir.join(name);
        std::fs::write(&p, bytes).ok();
        out.push(p);
    };
    write(
        "garden-notes.md",
        b"# Raised bed plan\n\n- tomatoes\n- basil\n",
    );
    write("harvest.csv", b"week,kg\n1,0.4\n2,1.1\n");
    // A 1x1 PNG.
    write(
        "pixel.png",
        &[
            0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 0x0d, 0x49, 0x48, 0x44, 0x52,
            0, 0, 0, 1, 0, 0, 0, 1, 8, 6, 0, 0, 0, 0x1f, 0x15, 0xc4, 0x89, 0, 0, 0, 0x0d, 0x49,
            0x44, 0x41, 0x54, 0x78, 0x9c, 0x63, 0xf8, 0xcf, 0xc0, 0xf0, 0x1f, 0, 5, 0, 1, 0xff,
            0x89, 0x99, 0x3d, 0x1d, 0, 0, 0, 0, 0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82,
        ],
    );
    for i in 1..=9 {
        write(
            &format!("note-{i}.txt"),
            format!("Synthetic note {i}.\n").as_bytes(),
        );
    }
    let big = dir.join("oversized.pdf");
    if let Ok(f) = std::fs::File::create(&big) {
        // Sparse: no real disk use.
        let _ = f.set_len(open_files_limit() + 1);
    }
    out.insert(3, big);
    out
}

fn open_files_limit() -> u64 {
    crate::shell::open_files::MAX_BYTES
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
    settle(cx, 500).await;

    // ── The model label after a send ───────────────────────────────────
    send("Hello from the shell check", cx).await;
    pass &= ok(
        "the first answer arrives",
        wait_answer(cx, Duration::from_secs(60)).await,
    );
    let labelled = wait_until(cx, Duration::from_secs(10), |cx| {
        pane(cx).is_some_and(|p| {
            p.read(cx)
                .composer_store
                .read(cx)
                .selected_model()
                .is_some()
        })
    })
    .await;
    pass &= ok(
        "after a send the composer names the selected model (not \"Choose a Model\")",
        labelled,
    );
    let first_chat = cx.update(|cx| chat_store(cx).map(|s| s.read(cx).chat_id().to_string()));
    let Some(first_chat) = first_chat else {
        return ok("the first chat is open", false);
    };
    if inputs.scenario == "shell-notify" {
        return notifications(&first_chat, cx).await && pass;
    }
    if inputs.scenario == "shell-close" {
        return close_to_menu_bar(&first_chat, cx).await && pass;
    }
    shoot_main(dir, "shell-model-label", cx).await;

    // ── Show Sidebar ───────────────────────────────────────────────────
    dispatch(&crate::actions::ToggleSidebar, cx);
    settle(cx, 500).await;
    let controls = ax(main, "shell-sidebar-hidden", dir, cx).await;
    pass &= ok(
        "with the sidebar hidden the toolbar has a labelled Show Sidebar button",
        has(&controls, "Button", "Show Sidebar"),
    );
    shoot_main(dir, "shell-sidebar-hidden", cx).await;
    // The button dispatches ToggleSidebar from the main window.
    dispatch(&crate::actions::ToggleSidebar, cx);
    settle(cx, 300).await;
    pass &= ok(
        "Show Sidebar shows it again",
        cx.update(|cx| {
            cx.global::<AppState>()
                .layout
                .read(cx)
                .state
                .sidebar_visible
        }),
    );

    // ── Links ──────────────────────────────────────────────────────────
    links(&["conduit://new?q=Draft%20from%20a%20link"], cx);
    let prefilled = wait_until(cx, Duration::from_secs(5), |cx| {
        matches!(selection(cx), Selection::New { .. })
            && composer_text(cx) == "Draft from a link"
            && chat_store(cx).is_none()
    })
    .await;
    pass &= ok("conduit://new?q= prefills a new chat, not sent", prefilled);
    shoot_main(dir, "shell-link-new", cx).await;
    in_pane(cx, |p, window, cx| {
        p.composer.update(cx, |c, cx| c.set_text("", window, cx))
    });

    links(&[&format!("conduit://chat/{first_chat}")], cx);
    let opened = wait_until(cx, Duration::from_secs(5), |cx| {
        selection(cx) == Selection::Chat(first_chat.clone())
    })
    .await;
    pass &= ok("conduit://chat/<id> opens the chat", opened);

    links(&["conduit://settings/keyboard"], cx);
    pass &= ok(
        "conduit://settings/keyboard opens Settings on Keyboard",
        wait_until(cx, Duration::from_secs(5), |cx| {
            settings_tab(cx) == Some(Tab::Keyboard)
        })
        .await,
    );
    close_settings(cx);
    settle(cx, 300).await;

    links(&["conduit://channel/c1"], cx);
    pass &= ok(
        "conduit://channel/<id> opens the channel's pane",
        wait_until(cx, Duration::from_secs(5), |cx| {
            selection(cx)
                == Selection::Area(crate::stores::navigation::AreaItem::Channel("c1".into()))
        })
        .await,
    );
    shoot_main(dir, "shell-link-channel", cx).await;
    let before = cx.update(selection);
    links(&["conduit://unknown/1", "https://example.org/x"], cx);
    settle(cx, 300).await;
    pass &= ok(
        "unknown links are ignored",
        cx.update(|cx| selection(cx) == before),
    );
    links(&[&format!("conduit://chat/{first_chat}")], cx);
    settle(cx, 300).await;

    // ── Open with ──────────────────────────────────────────────────────
    let files = synthetic_files(&dir.join("open-with"));
    let urls: Vec<String> = files
        .iter()
        .filter_map(|p| url::Url::from_file_path(p).ok())
        .map(|u| u.to_string())
        .collect();
    cx.update(|cx| desktop::handle_urls(urls, cx));
    let attached = wait_until(cx, Duration::from_secs(30), |cx| {
        pane(cx).is_some_and(|p| {
            let c = p.read(cx).composer_store.read(cx);
            c.attachments.len() == 10 && !c.uploading() && c.has_attachments()
        })
    })
    .await;
    let failed = cx.update(|cx| {
        pane(cx)
            .map(|p| {
                p.read(cx)
                    .composer_store
                    .read(cx)
                    .attachments
                    .iter()
                    .filter(|a| {
                        matches!(a.state, crate::stores::composer::UploadState::Failed { .. })
                    })
                    .count()
            })
            .unwrap_or(99)
    });
    pass &= ok(
        &format!("Open with attaches ten files in a new chat, uploaded ({failed} failed)"),
        attached && failed == 0,
    );
    let refused = cx.update(|cx| {
        let t = toasts(cx);
        (
            t.iter().any(|t| t.contains("more files weren't attached")),
            t.iter().any(|t| t.contains("oversized.pdf")),
        )
    });
    pass &= ok(
        "the eleventh and twelfth are refused with a toast",
        refused.0,
    );
    pass &= ok("the file over 256 MB is refused with a toast", refused.1);
    pass &= ok(
        "Open with does not send",
        cx.update(|cx| matches!(selection(cx), Selection::New { .. }) && chat_store(cx).is_none()),
    );
    shoot_main(dir, "shell-open-with", cx).await;
    cx.update(|cx| {
        if let Some(p) = pane(cx) {
            let store = p.read(cx).composer_store.clone();
            let ids: Vec<u64> = store
                .read(cx)
                .attachments
                .iter()
                .map(|a| a.local_id)
                .collect();
            store.update(cx, |c, cx| {
                for id in ids {
                    c.remove_attachment(id, cx);
                }
            });
        }
    });

    // ── Settings › Desktop and the hotkey ──────────────────────────────
    cx.update(|cx| crate::open_settings(Some(Tab::Desktop), cx));
    settle(cx, 800).await;
    if let Some((handle, _)) = cx.update(|cx| cx.global::<AppState>().settings_window.clone()) {
        let controls = ax(handle, "shell-settings-desktop", dir, cx).await;
        pass &= ok(
            "Settings › Desktop has its three switches (notifications have their own pane)",
            [
                "Close to the Menu Bar",
                "Open at Login",
                "Open Quick Ask from Anywhere",
            ]
            .iter()
            .all(|l| has(&controls, "Switch", l))
                && !has(&controls, "Switch", "Notify When an Answer Finishes"),
        );
        shoot_both_modes(handle, dir, "shell-settings-desktop", cx).await;
    }
    let hotkey = cx.update(|cx| shell_store(cx).read(cx).hotkey);
    println!("SMOKE info hotkey {hotkey:?}");
    pass &= ok(
        "the Quick Ask shortcut is registered (or reported as taken)",
        matches!(hotkey, HotkeyState::Registered | HotkeyState::Taken),
    );
    let settings = cx.update(|cx| cx.global::<AppState>().settings.clone());
    settings.update(cx, |s, cx| {
        s.set_desktop(|d| d.quick_ask_shortcut = "mod+alt+k".into(), cx)
    });
    settle(cx, 300).await;
    let rebound = cx.update(|cx| shell_store(cx).read(cx).hotkey);
    pass &= ok(
        &format!("a rebound shortcut registers ({rebound:?})"),
        rebound == HotkeyState::Registered,
    );
    settings.update(cx, |s, cx| s.reset_quick_ask_shortcut(cx));
    close_settings(cx);
    settle(cx, 300).await;

    // ── Quick Ask ──────────────────────────────────────────────────────
    // Through its action (Window › Quick Ask; the hotkey and the menu-bar
    // item take the same path).
    dispatch(&crate::actions::ToggleQuickAsk, cx);
    pass &= ok(
        "Quick Ask shows",
        wait_until(cx, Duration::from_secs(5), desktop::quick_ask_visible).await,
    );
    settle(cx, 600).await;
    // Where it went: 720×320, centred on the pointer's display, its top a
    // fifth of the way down that display's visible area.
    let placed = cx.update(|cx| {
        use crate::shell::{macos, placement};
        let (handle, _) = quick_ask(cx)?;
        let frame = handle
            .update(cx, |_, window, _| {
                macos::ns_window(window).map(|w| w.frame())
            })
            .ok()
            .flatten()?;
        let screens = macos::screens();
        let frames: Vec<placement::Rect> = screens.iter().map(|s| s.0).collect();
        let i = placement::display_under(&frames, macos::mouse_location())?;
        let want = placement::quick_ask_frame(screens[i].1, placement::QUICK_ASK_SIZE);
        println!(
            "SMOKE info quick ask frame {:?} want {want:?}",
            (
                frame.origin.x,
                frame.origin.y,
                frame.size.width,
                frame.size.height
            )
        );
        Some(
            (frame.origin.x - want.x).abs() < 1.
                && (frame.origin.y - want.y).abs() < 1.
                && (frame.size.width - want.width).abs() < 1.
                && (frame.size.height - want.height).abs() < 1.,
        )
    });
    pass &= ok(
        "Quick Ask sits centred, a fifth of the way down the pointer's display",
        placed == Some(true),
    );
    if let Some((handle, _)) = cx.update(quick_ask) {
        let controls = ax(handle, "shell-quick-ask", dir, cx).await;
        pass &= ok(
            "Quick Ask's actions are labelled",
            // Nothing typed: the call button stands where Send is.
            ["New Chat", "Open in Conduit", "Close", "Start Voice Call"]
                .iter()
                .all(|l| has(&controls, "Button", l)),
        );
    }
    quick_send("Hello from Quick Ask", cx);
    pass &= ok(
        "Quick Ask asks and the answer arrives",
        wait_quick_answer(cx, Duration::from_secs(60)).await,
    );
    if let Some((handle, _)) = cx.update(quick_ask) {
        cx.update(desktop::show_quick_ask);
        settle(cx, 400).await;
        shoot_both_modes(handle, dir, "shell-quick-ask", cx).await;
    }
    let quick_chat = cx.update(quick_chat_id);
    cx.update(|cx| {
        if let Some((handle, view)) = quick_ask(cx) {
            let _ = handle.update(cx, |_, window, cx| {
                view.update(cx, |v, cx| v.open_in_conduit(window, cx))
            });
        }
    });
    let shown = match &quick_chat {
        Some(id) => {
            wait_until(cx, Duration::from_secs(8), |cx| {
                selection(cx) == Selection::Chat(id.clone()) && !desktop::quick_ask_visible(cx)
            })
            .await
        }
        None => false,
    };
    pass &= ok(
        "Open in Conduit shows the main window on the Quick Ask chat and hides Quick Ask",
        shown,
    );

    // ── Notifications ──────────────────────────────────────────────────
    pass &= notifications(&first_chat, cx).await;

    // ── Close to the menu bar ──────────────────────────────────────────
    pass &= close_to_menu_bar(&first_chat, cx).await;

    // ── Open at login ──────────────────────────────────────────────────
    cx.update(|cx| desktop::set_launch_at_login(true, cx));
    let (on, error) = cx.update(|cx| {
        let s = shell_store(cx).read(cx);
        (s.login, s.login_error.clone())
    });
    println!("SMOKE info login item after register: {on:?} error={error:?}");
    pass &= ok(
        "open at login registers the app (on, or waiting for approval)",
        matches!(on, LoginState::On | LoginState::NeedsApproval),
    );
    cx.update(|cx| desktop::set_launch_at_login(false, cx));
    let off = cx.update(|cx| shell_store(cx).read(cx).login);
    println!("SMOKE info login item after unregister: {off:?}");
    pass &= ok("and unregisters it", off == LoginState::Off);
    pass
}

/// Close to the menu bar: the item comes and goes with the setting; the
/// close button and ⌘W hide the main window; the item and a link show it.
async fn close_to_menu_bar(first_chat: &str, cx: &mut AsyncApp) -> bool {
    let mut pass = true;
    let settings = cx.update(|cx| cx.global::<AppState>().settings.clone());
    settings.update(cx, |s, cx| {
        s.set_desktop(|d| d.close_to_menu_bar = true, cx)
    });
    settle(cx, 600).await;
    pass &= ok(
        "the menu-bar item shows with Close to the menu bar on",
        cx.update(|cx| desktop::menu_bar_item_visible(cx)),
    );
    // The red close button: AppKit's performClose: (windowShouldClose:).
    focus_main(cx).await;
    let ns = cx.update(|cx| {
        let handle = cx.global::<AppState>().main_window?;
        handle
            .update(cx, |_, window, _| crate::shell::macos::ns_window(window))
            .ok()
            .flatten()
    });
    if let Some(ns) = &ns {
        // Outside any GPUI update: AppKit calls back into GPUI.
        // SAFETY: the main window's live NSWindow, on the main thread.
        unsafe {
            let _: () = objc2::msg_send![&**ns, performClose: std::ptr::null::<objc2::runtime::AnyObject>()];
        }
    }
    let hidden = wait_until(cx, Duration::from_secs(5), |cx| {
        !desktop::main_visible(cx) && crate::main_window_alive(cx)
    })
    .await;
    pass &= ok(
        "the close button hides the main window; the app keeps running",
        hidden,
    );
    cx.update(|cx| desktop::on_tray_command(crate::shell::tray::TrayCommand::Open, cx));
    pass &= ok(
        "the menu-bar item's Open Conduit shows it again",
        wait_until(cx, Duration::from_secs(5), desktop::main_visible).await,
    );
    // ⌘W with the caret in the composer.
    focus_main(cx).await;
    in_pane(cx, |p, window, cx| p.focus_composer(window, cx));
    settle(cx, 200).await;
    dispatch(&crate::actions::CloseWindow, cx);
    pass &= ok(
        "⌘W hides it again",
        wait_until(cx, Duration::from_secs(5), |cx| !desktop::main_visible(cx)).await,
    );
    links(&[&format!("conduit://chat/{first_chat}")], cx);
    pass &= ok(
        "a link shows the hidden main window on its chat",
        wait_until(cx, Duration::from_secs(5), |cx| {
            desktop::main_visible(cx) && selection(cx) == Selection::Chat(first_chat.to_string())
        })
        .await,
    );
    settings.update(cx, |s, cx| {
        s.set_desktop(|d| d.close_to_menu_bar = false, cx)
    });
    settle(cx, 400).await;
    pass &= ok(
        "the menu-bar item goes with the setting",
        cx.update(|cx| !desktop::menu_bar_item_visible(cx)),
    );

    pass
}

/// Brings the main window forward and waits until it is the key window.
async fn focus_main(cx: &mut AsyncApp) {
    cx.update(desktop::show_main);
    wait_until(cx, Duration::from_secs(5), |cx| {
        desktop::on_screen(cx).main_key
    })
    .await;
}

/// A turn the local server's upstream fails ("fail", HTTP 500): the daemon
/// ends it with the server's words within a second or so, and it notifies
/// when [`notify`] (notifications allowed). Quick Ask goes out of sight as
/// the message leaves, since a failure on screen is shown there, not
/// notified.
async fn failed_turn(first_chat: &str, notify: bool, cx: &mut AsyncApp) -> bool {
    let mut pass = true;
    links(&[&format!("conduit://chat/{first_chat}")], cx);
    settle(cx, 500).await;
    cx.update(desktop::show_quick_ask);
    quick_new_chat(cx);
    settle(cx, 300).await;
    // What the daemon itself says about the turn.
    let ends: std::rc::Rc<std::cell::RefCell<Vec<conduit_protocol::Event>>> = Default::default();
    let _ends_watch = cx.update(|cx| {
        let connection = cx.global::<AppState>().connection.clone();
        let ends = ends.clone();
        cx.subscribe(&connection, move |_, event, _| {
            if let crate::stores::connection::ConnectionEvent::Daemon(event) = event
                && matches!(
                    event.as_ref(),
                    conduit_protocol::Event::TurnFinished(_)
                        | conduit_protocol::Event::TurnFailed(_)
                )
            {
                ends.borrow_mut().push(event.as_ref().clone());
            }
        })
    });
    quick_send("Please fail this one", cx);
    cx.update(desktop::hide_quick_ask);
    let started = wait_until(cx, Duration::from_secs(20), |cx| {
        quick_chat_id(cx).is_some()
    })
    .await;
    let failed_chat = cx.update(quick_chat_id);
    match (failed_chat, started) {
        (Some(id), true) => {
            let finished = |id: &str, ends: &[conduit_protocol::Event]| {
                ends.iter().any(|e| {
                    matches!(e, conduit_protocol::Event::TurnFinished(f) if f.chat_id == id && !f.ok)
                })
            };
            let ended = wait_until(cx, Duration::from_secs(20), |_| {
                finished(&id, &ends.borrow())
            })
            .await;
            pass &= ok(
                "the daemon ends the failed turn (turn.finished {ok: false})",
                ended,
            );
            let words = ends.borrow().iter().any(|e| {
                matches!(
                    e,
                    conduit_protocol::Event::TurnFailed(f)
                        if f.chat_id == id
                            && f.args.get("detail").is_some_and(|d| d.contains("failed on purpose"))
                )
            });
            pass &= ok("turn.failed carries the server's words", words);
            let key = crate::shell::notify::identifier(&id);
            if notify {
                let n = wait_delivered(&key, cx, Duration::from_secs(10)).await;
                pass &= ok(
                    "a failed turn notifies with the error title and the chat title",
                    n.as_ref().is_some_and(|n| {
                        n.title == "The answer didn't finish." && !n.body.is_empty()
                    }),
                );
            } else {
                settle(cx, 1000).await;
                let posted = delivered(cx).await.into_iter().any(|n| n.id == key);
                pass &= ok("with notifications denied, no failure is posted", !posted);
            }
        }
        _ => pass &= ok("the failing Quick Ask turn started", false),
    }
    pass
}

/// Answer notifications, under quiet (provisional) permission when the
/// system hasn't asked yet. When notifications are denied for this bundle
/// (a decision in System Settings), checks that nothing is posted.
async fn notifications(first_chat: &str, cx: &mut AsyncApp) -> bool {
    let mut pass = true;
    cx.update(|cx| desktop::ensure_permission(true, cx));
    wait_until(cx, Duration::from_secs(10), |cx| {
        !matches!(
            shell_store(cx).read(cx).notifications,
            NotificationAccess::Unknown | NotificationAccess::NotDetermined
        )
    })
    .await;
    let access = cx.update(|cx| shell_store(cx).read(cx).notifications);
    println!("SMOKE info notification access {access:?}");
    let denied = access == NotificationAccess::Denied;
    if !denied {
        pass &= ok(
            &format!("notifications are allowed for this bundle ({access:?})"),
            matches!(
                access,
                NotificationAccess::Quiet | NotificationAccess::Allowed
            ),
        );
    }
    // The main window shows the first chat; a Quick Ask chat finishes out
    // of sight, with the app counted as behind other apps (the core then
    // picks a system notification; in front it would be an in-app banner).
    cx.update(|cx| desktop::set_e2e_background(true, cx));
    links(&[&format!("conduit://chat/{first_chat}")], cx);
    settle(cx, 500).await;
    cx.update(desktop::show_quick_ask);
    quick_new_chat(cx);
    settle(cx, 300).await;
    quick_send("Hello again from Quick Ask", cx);
    let started = wait_until(cx, Duration::from_secs(20), |cx| {
        quick_chat_id(cx).is_some()
    })
    .await;
    cx.update(desktop::hide_quick_ask);
    let ready_chat = cx.update(quick_chat_id);
    let (Some(id), true) = (ready_chat, started) else {
        return ok("the out-of-sight Quick Ask turn started", false);
    };
    let answered = wait_quick_answer(cx, Duration::from_secs(60)).await;
    pass &= ok("the out-of-sight answer finished", answered);
    let key = crate::shell::notify::identifier(&id);
    if denied {
        settle(cx, 2000).await;
        let posted = delivered(cx).await.into_iter().any(|n| n.id == key);
        println!(
            "SMOKE info notifications are denied for this bundle in System Settings; delivery is checked under a fresh bundle (--e2e shell-notify)"
        );
        pass &= ok("with notifications denied, nothing is posted", !posted);
        let failed = failed_turn(first_chat, false, cx).await;
        cx.update(|cx| desktop::set_e2e_background(false, cx));
        return failed && pass;
    }
    let answer = cx.update(|cx| {
        quick_ask(cx)
            .and_then(|(_, v)| v.read(cx).chat.as_ref().map(|c| c.store.clone()))
            .and_then(|s| s.read(cx).last_reply())
            .unwrap_or_default()
    });
    let n = wait_delivered(&key, cx, Duration::from_secs(15)).await;
    let content_free = n.as_ref().is_some_and(|n| {
        let words: Vec<&str> = answer.split_whitespace().filter(|w| w.len() > 5).collect();
        !words
            .iter()
            .any(|w| n.title.contains(w) || n.body.contains(w))
    });
    pass &= ok(
        "a notification is delivered (getDeliveredNotifications)",
        n.as_ref()
            .is_some_and(|n| n.body == "The answer is ready." && !n.title.is_empty()),
    );
    pass &= ok("the notification carries no answer text", content_free);
    if let Some(n) = &n {
        println!(
            "SMOKE info notification title_len={} body={:?}",
            n.title.chars().count(),
            n.body
        );
    }
    // A click, through the delegate's path, opens the chat.
    cx.update(|cx| desktop::simulate_notification_click(&key, cx));
    let clicked = wait_until(cx, Duration::from_secs(8), |cx| {
        selection(cx) == Selection::Chat(id.clone()) && desktop::main_visible(cx)
    })
    .await;
    pass &= ok(
        "clicking the notification shows the main window on its chat",
        clicked,
    );
    settle(cx, 500).await;
    let left = delivered(cx).await.into_iter().any(|n| n.id == key);
    pass &= ok("the clicked notification leaves Notification Center", !left);

    pass &= failed_turn(first_chat, true, cx).await;
    cx.update(|cx| desktop::set_e2e_background(false, cx));
    // The chat on screen in the key main window gets no notification.
    links(&[&format!("conduit://chat/{first_chat}")], cx);
    focus_main(cx).await;
    send("One more on screen", cx).await;
    let answered = wait_answer(cx, Duration::from_secs(60)).await;
    settle(cx, 1500).await;
    let on_screen = delivered(cx)
        .await
        .into_iter()
        .any(|n| n.id == crate::shell::notify::identifier(first_chat));
    pass &= ok(
        "an answer on screen in the key main window is not notified",
        answered && !on_screen,
    );
    // Leave Notification Center as it was.
    cx.update(|cx| desktop::remove_all_notifications(cx));
    settle(cx, 500).await;
    pass &= ok(
        "the run's notifications are cleared",
        delivered(cx).await.is_empty(),
    );
    pass
}

/// `--probe <file>`: the state a shell driver checks after `open -a`
/// (links and files, cold and warm), written every 300 ms. The app quits
/// when `<file>.quit` appears. Each line a driver appends to `<file>.cmd`
/// runs once ([`probe_command`]).
pub fn probe(path: PathBuf, cx: &mut App) {
    cx.spawn(async move |cx: &mut AsyncApp| {
        let quit = path.with_extension("quit");
        let commands = path.with_extension("cmd");
        // `press` lines and the AppKit windows: on a run loop timer that
        // also runs inside Sparkle's modal alerts (super::panels).
        #[cfg(target_os = "macos")]
        super::panels::watch(commands.clone(), path.with_extension("panels.json"));
        let mut done = 0;
        loop {
            settle(cx, 300).await;
            let lines: Vec<String> = std::fs::read_to_string(&commands)
                .map(|s| s.lines().map(str::to_owned).collect())
                .unwrap_or_default();
            for line in lines.iter().skip(done) {
                probe_command(line.trim(), cx);
            }
            done = done.max(lines.len());
            let state = cx.update(|cx| {
                let Some(state) = cx.try_global::<AppState>() else {
                    return json!({});
                };
                let stores = state.stores.clone();
                let selection = match stores.navigation.read(cx).selection() {
                    Selection::Chat(id) => format!("chat:{id}"),
                    Selection::New { .. } => "new".into(),
                    Selection::Area(item) => format!("area:{item:?}"),
                };
                let (text, attachments) = pane(cx)
                    .map(|p| {
                        let p = p.read(cx);
                        let text = p.composer.read(cx).text(cx);
                        let names: Vec<String> = p
                            .composer_store
                            .read(cx)
                            .attachments
                            .iter()
                            .map(|a| format!("{}:{:?}", a.name, a.state))
                            .collect();
                        (text, names)
                    })
                    .unwrap_or_default();
                json!({
                    "route": format!("{:?}", stores.session.read(cx).route(cx)),
                    "mainReady": desktop::main_ready(cx),
                    "mainVisible": desktop::main_visible(cx),
                    "selection": selection,
                    "composerText": text,
                    "attachments": attachments,
                    "settingsTab": settings_tab(cx).map(|t| t.id()),
                    "toasts": toasts(cx),
                    "hiddenStart": shell_store(cx).read(cx).hidden_start,
                    "notifications": format!("{:?}", shell_store(cx).read(cx).notifications),
                    "login": format!("{:?}", shell_store(cx).read(cx).login),
                    "menuBarItem": desktop::menu_bar_item_visible(cx),
                    "updates": {
                        "available": crate::updates::available(cx),
                        "canCheck": crate::updates::can_check(cx),
                    },
                })
            });
            std::fs::write(&path, serde_json::to_vec_pretty(&state).unwrap_or_default()).ok();
            if quit.exists() {
                cx.update(|cx| cx.quit());
                break;
            }
        }
    })
    .detach();
}

/// One line of `<file>.cmd`:
/// * `check-for-updates`: the app menu's Conduit › Check for Updates…
///   (its action, as the menu item dispatches it);
/// * `press <title>`: clicks the button with that title in a window AppKit
///   shows outside GPUI (Sparkle's: Install Update, Install and Relaunch,
///   OK), as a person would; run by [`super::panels`], not here.
fn probe_command(line: &str, cx: &mut AsyncApp) {
    if line == "check-for-updates" {
        log::info!("probe: {line}");
        cx.update(|cx| cx.dispatch_action(&crate::actions::CheckForUpdates));
    } else if !line.is_empty() && !line.starts_with("press ") {
        log::warn!("probe: unknown command '{line}'");
    }
}
