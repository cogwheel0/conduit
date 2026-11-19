//! Settings (every page), Accounts and Add Account, Quick Ask, the Preview
//! window, the menu bar's menus and the menu-bar item's menu (real NSMenus),
//! and the reconnecting banner.

use std::time::Duration;

use conduit_components::window as cw;
use gpui_kit::{AnyWindowHandle, AsyncApp};

use super::main_pass::{ax_dump, new_chat};
use super::{Run, Shot, drive, log, pause, place, wait_until};
use crate::AppState;
use crate::prefs::ThemeMode;
use crate::views::server_form::ServerFormEvent;
use crate::views::settings::{SETTINGS_SIZE, Tab};

type SettingsWindow = (
    AnyWindowHandle,
    gpui_kit::Entity<crate::views::settings::SettingsView>,
);

fn settings_window(cx: &mut AsyncApp) -> Option<SettingsWindow> {
    cx.update(|cx| cx.global::<AppState>().settings_window.clone())
}

fn tab_description(tab: Tab) -> &'static str {
    match tab {
        Tab::Accounts => "Settings › Accounts: the signed-in account with its menu, Add Account.",
        Tab::Direct => "Settings › Direct: model providers the app talks to directly.",
        Tab::Hermes => "Settings › Hermes: the Hermes Agent connection.",
        Tab::Appearance => {
            "Settings › Appearance: theme, palette, sidebar style, density, text size."
        }
        Tab::Language => "Settings › Language.",
        Tab::Keyboard => "Settings › Keyboard: every shortcut, rebindable.",
        Tab::Desktop => {
            "Settings › Desktop: menu bar, open at login, Quick Ask (the harness's profile turns the global shortcut off)."
        }
        Tab::Notifications => {
            "Settings › Notifications: what notifies and how; webhook destinations behind Advanced."
        }
        Tab::PersonalConnections => {
            "Settings › Personal Connections: the account's own tool servers and terminals."
        }
        Tab::Data => {
            "Settings › Data: clear local data; Diagnostics (the report, the background service's version, the data and log folders)."
        }
        Tab::About => "Settings › About: the app's icon, name, version and copyright; updates.",
        Tab::Profile => "Settings › Profile: the account's photo, details and password.",
        Tab::Personalization => {
            "Settings › Personalization: default model, system prompt, memories."
        }
        Tab::Connection => "Settings › Connection: transport mode and connection health.",
        Tab::Chats => {
            "Settings › Chat: composer, quick actions, message actions, prompts, Advanced."
        }
        Tab::Audio => "Settings › Audio: calls, speech to text, text to speech, voice provider.",
        Tab::DataControls => {
            "Settings › Data Controls: export, import and account-wide chat actions."
        }
    }
}

/// Pops `NSApp.mainMenu`'s submenu at `index` over the main window, as the
/// menu bar would drop it (the menu bar strip itself can't be captured).
/// Blocks in the menu's tracking loop until the capture closes it.
fn pop_main_menu(index: isize, main: AnyWindowHandle, cx: &mut AsyncApp) {
    use objc2::runtime::AnyObject;
    use objc2::{class, msg_send};
    use objc2_foundation::NSPoint;
    let view = cx.update(|cx| {
        main.update(cx, |_, window, _| cw::macos::ns_view(window))
            .ok()
            .flatten()
    });
    let Some(view) = view else { return };
    let height = view.bounds().size.height;
    // SAFETY: AppKit calls on the main thread, outside any GPUI borrow.
    unsafe {
        let app: *mut AnyObject = msg_send![class!(NSApplication), sharedApplication];
        let main_menu: *mut AnyObject = msg_send![app, mainMenu];
        if main_menu.is_null() {
            return;
        }
        let item: *mut AnyObject = msg_send![main_menu, itemAtIndex: index];
        if item.is_null() {
            return;
        }
        let sub: *mut AnyObject = msg_send![item, submenu];
        if sub.is_null() {
            return;
        }
        // A copy, out of the menu bar: a menu in the bar takes the bar's
        // appearance (the system's), whatever it is set to; the copy takes
        // the one a user in this mode sees.
        let sub: *mut AnyObject = msg_send![sub, copy];
        if sub.is_null() {
            return;
        }
        super::grab::set_appearance(sub, super::grab::forced_appearance());
        let at = NSPoint::new(40. + 110. * index as f64, height - 6.);
        let view_ptr: *const objc2_app_kit::NSView = &*view;
        let _: bool = msg_send![
            sub,
            popUpMenuPositioningItem: std::ptr::null_mut::<AnyObject>(),
            atLocation: at,
            inView: view_ptr
        ];
        let _: () = msg_send![sub, release];
    }
}

/// The menu bar's titles, left to right.
fn main_menu_titles() -> Vec<String> {
    use objc2::runtime::AnyObject;
    use objc2::{class, msg_send};
    use objc2_foundation::NSString;
    let mut out = vec![];
    // SAFETY: AppKit reads on the main thread.
    unsafe {
        let app: *mut AnyObject = msg_send![class!(NSApplication), sharedApplication];
        let main_menu: *mut AnyObject = msg_send![app, mainMenu];
        if main_menu.is_null() {
            return out;
        }
        let count: isize = msg_send![main_menu, numberOfItems];
        for i in 0..count {
            let item: *mut AnyObject = msg_send![main_menu, itemAtIndex: i];
            if item.is_null() {
                out.push(String::new());
                continue;
            }
            let sub: *mut AnyObject = msg_send![item, submenu];
            let title: *mut NSString = if sub.is_null() {
                msg_send![item, title]
            } else {
                msg_send![sub, title]
            };
            out.push(if title.is_null() {
                String::new()
            } else {
                (*title).to_string()
            });
        }
    }
    out
}

fn slug(text: &str) -> String {
    text.to_lowercase()
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() { c } else { '-' })
        .collect::<String>()
        .split('-')
        .filter(|p| !p.is_empty())
        .collect::<Vec<_>>()
        .join("-")
}

pub async fn run(run: &mut Run, cx: &mut AsyncApp) {
    if !run.wants("shell") {
        return;
    }
    let main = run.main;
    run.mode(ThemeMode::Light, cx).await;
    new_chat(run, cx).await;

    // ── Settings, every page ───────────────────────────────────────────
    cx.update(|cx| crate::open_settings(Some(Tab::Accounts), cx));
    pause(cx, 700).await;
    if let Some((handle, view)) = settings_window(cx) {
        place(handle, (250., 90.), SETTINGS_SIZE, cx);
        pause(cx, 400).await;
        for tab in Tab::ALL {
            // Each page as it opens: the tab chosen, focus on the window
            // (an earlier page's Tab walk leaves no ring behind).
            let _ = handle.update(cx, |_, window, cx| {
                view.update(cx, |v, cx| {
                    v.tab = tab;
                    v.rest_focus(window, cx);
                })
            });
            pause(cx, 500).await;
            run.state(
                handle,
                "settings",
                tab.id(),
                tab_description(tab),
                Shot::default(),
                cx,
            )
            .await;
            match tab {
                Tab::Accounts => {
                    ax_dump(run, handle, "settings-accounts", cx).await;
                    // The account row's menu, for real.
                    let nodes = drive::nodes(handle, cx).await;
                    match drive::find(&nodes, "Button", |l| l.starts_with("More"))
                        .and_then(|n| n.center())
                    {
                        Some(at) => {
                            run.native_menu(
                                handle,
                                "menu-settings-account-row",
                                "Settings › Accounts: the account row's menu, a real NSMenu.",
                                move |cx| {
                                    let s = cx.update(|cx| {
                                        cx.global::<AppState>()
                                            .settings_window
                                            .as_ref()
                                            .map(|(h, _)| *h)
                                    });
                                    if let Some(s) = s {
                                        cx.spawn(async move |cx| drive::click(s, at, cx).await)
                                            .detach();
                                    }
                                },
                                cx,
                            )
                            .await;
                        }
                        None => run.missing(
                            "menu · settings account row",
                            "no More button on the account row",
                        ),
                    }
                    run.focus_walk(handle, "settings-accounts", "tab", 10, cx)
                        .await;
                    run.tooltips(handle, "settings", cx).await;
                }
                Tab::Appearance => {
                    run.focus_walk(handle, "settings-appearance", "tab", 12, cx)
                        .await
                }
                Tab::Keyboard => {
                    ax_dump(run, handle, "settings-keyboard", cx).await;
                }
                _ => {}
            }
        }
        // The page list by keyboard: arrows from the selected page.
        let nodes = drive::nodes(handle, cx).await;
        if let Some(at) = drive::find(&nodes, "Tab", |l| !l.is_empty())
            .or_else(|| drive::find(&nodes, "Button", |l| l == "Accounts"))
            .and_then(|n| n.center())
        {
            drive::click(handle, at, cx).await;
            pause(cx, 300).await;
            run.focus_walk(handle, "settings-pages", "down", 5, cx)
                .await;
        }
        let _ = handle.update(cx, |_, window, _| window.remove_window());
        pause(cx, 500).await;
    } else {
        run.missing("settings", "the Settings window did not open");
    }

    // ── Add Account (a window sheet on Settings › Accounts) ───────────
    cx.update(crate::start_adding_account);
    // AppKit's sheet slides down in about a quarter second.
    pause(cx, 900).await;
    match settings_window(cx) {
        Some((handle, view)) if cx.update(|cx| view.read(cx).add_sheet.is_some()) => {
            run.state(
                handle,
                "accounts",
                "add-account",
                "Add Account: a window sheet (beginSheet) hung from the Settings window's title bar, with the server form, Cancel and Connect.",
                Shot::default(),
                cx,
            )
            .await;
            // The sheet's own focus walk, and Advanced Settings open (the
            // sheet grows to fit).
            if let Some(sheet) = cx.update(|cx| view.read(cx).add_sheet.clone()) {
                run.focus_walk(sheet.handle, "add-account", "tab", 6, cx)
                    .await;
                let form = cx.update(|cx| sheet.form(cx));
                cx.update(|cx| {
                    form.update(cx, |f, cx| {
                        f.advanced = true;
                        cx.notify();
                    })
                });
                pause(cx, 900).await;
                run.state(
                    handle,
                    "accounts",
                    "add-account-advanced",
                    "Add Account with Advanced Settings open: the sheet grows to fit the form.",
                    Shot::default(),
                    cx,
                )
                .await;
                cx.update(|cx| form.update(cx, |_, cx| cx.emit(ServerFormEvent::Back)));
            }
            pause(cx, 700).await;
            if cx.update(|cx| view.read(cx).add_sheet.is_some()) {
                run.problem("Add Account: Cancel did not close the sheet");
            }
            let _ = handle.update(cx, |_, window, _| window.remove_window());
        }
        _ => run.missing(
            "accounts · add-account",
            "the Add Account sheet did not open",
        ),
    }
    pause(cx, 400).await;

    // ── Quick Ask ──────────────────────────────────────────────────────
    cx.update(crate::desktop::show_quick_ask);
    pause(cx, 900).await;
    let qa = cx.update(|cx| {
        cx.try_global::<crate::desktop::Desktop>()
            .and_then(|d| d.quick_ask.clone())
    });
    match qa {
        Some((handle, view)) => {
            run.state(handle, "quick-ask", "empty", "Quick Ask (Window › Quick Ask, or the global shortcut): the floating panel, empty.", Shot::default(), cx).await;
            run.tooltips(handle, "quick-ask", cx).await;
            run.focus_walk(handle, "quick-ask", "tab", 6, cx).await;
            let _ = handle.update(cx, |_, window, cx| {
                view.update(cx, |v, cx| {
                    v.send_text("A long answer, please".into(), vec![], window, cx)
                })
            });
            let started = wait_until(cx, Duration::from_secs(30), |cx| {
                cx.try_global::<crate::desktop::Desktop>()
                    .and_then(|d| d.quick_ask.clone())
                    .is_some_and(|(_, v)| v.read(cx).chat_id(cx).is_some())
            })
            .await;
            pause(cx, 1600).await;
            if started {
                let fast = Shot {
                    settle: Duration::from_millis(150),
                    ..Shot::default()
                };
                run.state(
                    handle,
                    "quick-ask",
                    "answering",
                    "Quick Ask answering: the answer streaming in the panel.",
                    fast,
                    cx,
                )
                .await;
            } else {
                run.missing(
                    "quick-ask · answering",
                    "the Quick Ask answer never started",
                );
            }
            let _ = handle.update(cx, |_, _, cx| view.update(cx, |v, cx| v.stop(cx)));
            pause(cx, 1500).await;
            run.state(
                handle,
                "quick-ask",
                "answered",
                "Quick Ask after the answer (stopped part-way).",
                Shot::default(),
                cx,
            )
            .await;
            cx.update(crate::desktop::hide_quick_ask);
            pause(cx, 500).await;
        }
        None => run.missing("quick-ask", "the Quick Ask panel did not open"),
    }

    // A chat open from here on: the Preview windows are subtitled with it
    // (the block's chat), and the Chat menu shows what it does for one.
    cx.update(|cx| {
        let stores = cx.global::<AppState>().stores.clone();
        let recent = stores.chat_list.read(cx).recent(1);
        if let Some(chat) = recent.first() {
            let id = chat.id.clone();
            stores.navigation.update(cx, |n, cx| n.open(id, cx));
        }
    });
    pause(cx, 800).await;

    // ── Preview windows (opened per mode: the page takes the theme then) ──
    for (lang, code, what) in [
        (
            "html",
            "<!doctype html>\n<h1 style=\"font-family:-apple-system,sans-serif\">Tide board</h1>\n<p style=\"font-family:-apple-system,sans-serif\">High water at 06:12, low water at 12:40.</p>",
            "The Preview window for an HTML block (Preview on a code block).",
        ),
        (
            "mermaid",
            "graph TD\n  A[Question] --> B{Tide table}\n  B -->|high water| C[Chart]\n  B -->|range| D[Summary]",
            "The Preview window for a Mermaid diagram.",
        ),
    ] {
        let n = run.reserve_static();
        for mode in [ThemeMode::Light, ThemeMode::Dark] {
            run.mode(mode, cx).await;
            let handle = cx.update(|cx| crate::views::chat::preview::open_preview(lang, code, cx));
            let Some(handle) = handle else {
                run.missing(
                    &format!("preview · {lang}"),
                    "the Preview window did not open",
                );
                break;
            };
            pause(cx, 2800).await;
            run.state_one(n, handle, "preview", lang, what, mode, Shot::default(), cx)
                .await;
            let _ = handle.update(cx, |_, window, _| window.remove_window());
            pause(cx, 400).await;
        }
        run.mode(ThemeMode::Light, cx).await;
    }

    // ── The menu bar's menus, popped up for real ──────────────────────
    // (The chat opened above is still open.)
    let titles = main_menu_titles();
    log(format!("menu bar: {titles:?}"));
    for (i, title) in titles.iter().enumerate() {
        let name = if i == 0 {
            "app".to_string()
        } else {
            slug(title)
        };
        let idx = i as isize;
        let opened = run
            .native_menu_pair(
                main,
                "menubar",
                &name,
                &format!("The menu bar's {} menu, popped up in place (a real NSMenu; the menu bar strip itself can't be captured).", if i == 0 { "Conduit (app)" } else { title }),
                false,
                move |cx| {
                    let main = cx.update(|cx| cx.global::<AppState>().main_window);
                    if let Some(main) = main {
                        pop_main_menu(idx, main, cx);
                    }
                },
                cx,
            )
            .await;
        if !opened {
            run.missing(&format!("menubar · {title}"), "the menu did not pop up");
        }
    }

    // ── The menu-bar item ──────────────────────────────────────────────
    cx.update(|cx| {
        let s = cx.global::<AppState>().settings.clone();
        s.update(cx, |s, cx| {
            s.set_desktop(|d| d.close_to_menu_bar = true, cx)
        });
    });
    let shown = wait_until(cx, Duration::from_secs(10), |cx| {
        crate::desktop::menu_bar_item_visible(cx)
    })
    .await;
    if shown {
        pause(cx, 400).await;
        let opened = run
            .native_menu_pair(
                main,
                "menubar-item",
                "menu",
                "The menu-bar item's menu (shown while Close to Menu Bar is on), a real NSMenu.",
                false,
                |cx| {
                    if let Some(tray) = cx.update(|cx| crate::desktop::menu_bar_item(cx)) {
                        // Outside any GPUI borrow: the menu's tracking loop holds
                        // the main thread until the capture closes it.
                        tray.show_menu();
                    }
                },
                cx,
            )
            .await;
        if !opened {
            run.missing(
                "menubar-item · menu",
                "the menu-bar item's menu did not open",
            );
        }
    } else {
        run.missing("menubar-item · menu", "the menu-bar item did not appear");
    }
    cx.update(|cx| {
        let s = cx.global::<AppState>().settings.clone();
        s.update(cx, |s, cx| {
            s.set_desktop(|d| d.close_to_menu_bar = false, cx)
        });
    });
    pause(cx, 500).await;
}

/// The reconnecting banner: the supervisor stops this run's own daemon and
/// starts a fresh one a few seconds later, long enough to photograph.
pub async fn reconnect(run: &mut Run, cx: &mut AsyncApp) {
    if !run.wants("reconnect") {
        return;
    }
    let main = run.main;
    run.mode(ThemeMode::Light, cx).await;
    new_chat(run, cx).await;
    // The supervisor stops the daemon and a fresh one starts: the capture
    // signals no process itself (a pid it read could have been reused).
    let started = cx.update(|cx| {
        let c = cx.global::<AppState>().connection.clone();
        c.update(cx, |c, cx| {
            c.restart_daemon_after(Duration::from_secs(3), cx)
        })
    });
    if !started {
        run.missing(
            "banner · reconnecting",
            "this run's daemon could not be restarted",
        );
        return;
    }
    log("restarting this run's daemon");
    let seen = wait_until(cx, Duration::from_secs(10), |cx| {
        matches!(
            crate::smoke::current_status(cx),
            crate::stores::connection::Status::Reconnecting { .. }
                | crate::stores::connection::Status::Connecting
                | crate::stores::connection::Status::CoreStarting
        )
    })
    .await;
    if seen {
        let fast = Shot {
            settle: Duration::from_millis(100),
            ..Shot::default()
        };
        run.state(
            main,
            "banner",
            "reconnecting",
            "The daemon lost and restarting: the reconnecting banner over the main window.",
            fast,
            cx,
        )
        .await;
    } else {
        run.missing(
            "banner · reconnecting",
            "no reconnecting state was seen after the daemon stopped",
        );
    }
    let back = wait_until(cx, Duration::from_secs(60), |cx| {
        crate::smoke::current_status(cx) == crate::stores::connection::Status::Connected
    })
    .await;
    if !back {
        run.problem("the daemon did not come back within a minute");
    }
}
