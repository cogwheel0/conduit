//! `--e2e terminal`: the Terminal area and the Computer viewer,
//! on the seeded server's fake Open Terminal ("Build box", owui.sh).
//!
//! The console: it connects by itself, a command runs and its output shows,
//! the grid follows the window's size (`stty size`), Copy and Paste, ⌃C
//! stops a command, a flood of output (`yes`) keeps painting, and Find
//! counts matches. Files: browse, upload, rename, download, show a file,
//! new folder, a change made elsewhere arriving live, delete. Ports: the
//! dev server's preview window, through the daemon's preview listener,
//! following a link. A chat: the composer's Terminal section picks the
//! Build box, a model's `display_file` opens the file, and the header's
//! Computer opens the desktop live. Screenshots in light and dark,
//! AccessKit checks.

use std::path::Path;
use std::time::{Duration, Instant};

use gpui_kit::{App, AsyncApp, ClipboardItem, Entity};

use super::{
    E2eInputs, NO_SERVER, ax, connect_server, fresh_profile, has, in_main, in_setup, ok, press,
    settle, shoot_main, sign_in_password, wait_main, wait_route, wait_setup, wait_until,
};
use crate::AppState;
use crate::smoke::current_route;
use crate::stores::navigation::AreaItem;
use crate::stores::session::Route;
use crate::views::terminal::console::{Console, LinkStatus};
use crate::views::terminal::files::{DownloadTo, FilesView};
use crate::views::terminal::pane::Mode;
use crate::views::terminal::pane::TerminalPane;

/// The fake Open Terminal's id in TERMINAL_SERVER_CONNECTIONS.
pub const SERVER: &str = "buildbox";

/// The pane of the Build box, once opened.
pub(super) fn pane(cx: &mut App) -> Option<Entity<TerminalPane>> {
    let view = cx.try_global::<AppState>()?.main_view.clone()?;
    view.read(cx).area_pane.read(cx).shown_terminal(cx)
}

fn console(cx: &mut App) -> Option<Entity<Console>> {
    Some(pane(cx)?.read(cx).console.clone())
}

/// The console's screen as text.
fn screen(cx: &mut App) -> String {
    let Some(console) = console(cx) else {
        return String::new();
    };
    let t = crate::views::terminal::console::palette(
        &conduit_components::ActiveConduitTheme::conduit(cx).clone(),
    );
    console.read(cx).emulator().frame(&t, &[], None).text()
}

/// Types `text` into the console as keystrokes (printable ones through the
/// input handler, as typing does), then Return.
async fn run_command(text: &str, cx: &mut AsyncApp) {
    let Some((handle, _)) = cx.update(|cx| {
        let s = cx.global::<AppState>();
        Some((s.main_window?, ()))
    }) else {
        return;
    };
    for c in text.chars() {
        let key = match c {
            ' ' => "space".to_string(),
            c => c.to_string(),
        };
        press(handle, &key, cx);
    }
    press(handle, "enter", cx);
}

pub async fn run(inputs: &E2eInputs, dir: &Path, cx: &mut AsyncApp) -> bool {
    let Some((url, email, password)) = inputs.owui() else {
        return ok(NO_SERVER, false);
    };
    let routed = wait_until(cx, Duration::from_secs(90), |cx| {
        current_route(cx) != Route::Unknown
    })
    .await;
    let mut pass = ok("routed", routed);
    if cx.update(current_route) != Route::Onboarding {
        pass &= fresh_profile(cx).await;
    }
    pass &= ok("the setup window opened", wait_setup(cx).await.is_some());
    in_setup(cx, |sw, window, cx| {
        sw.onboarding.update(cx, |o, cx| o.choose(window, cx))
    });
    settle(cx, 500).await;
    connect_server(&url, "Lab server", cx).await;
    pass &= wait_route(cx, Route::SignIn, Duration::from_secs(60)).await;
    sign_in_password(&email, &password, cx).await;
    pass &= wait_route(cx, Route::Main, Duration::from_secs(60)).await;
    let Some(main) = wait_main(cx).await else {
        return ok("main window", false);
    };

    // ── The server's terminal, in the sidebar ─────────────────────────
    let listed = wait_until(cx, Duration::from_secs(60), |cx| {
        cx.global::<AppState>()
            .stores
            .areas
            .read(cx)
            .terminal(SERVER)
            .is_some_and(|t| t.name == "Build box")
    })
    .await;
    pass &= ok("the Build box is listed in the Terminal section", listed);
    cx.update(|cx| {
        let nav = cx.global::<AppState>().stores.navigation.clone();
        nav.update(cx, |n, cx| {
            n.open_item(AreaItem::Terminal(SERVER.into()), cx)
        });
    });

    // ── The console connects by itself ────────────────────────────────
    let connected = wait_until(cx, Duration::from_secs(30), |cx| {
        console(cx).is_some_and(|c| *c.read(cx).status() == LinkStatus::Connected)
    })
    .await;
    pass &= ok("the console connects on its own", connected);
    let banner = wait_until(cx, Duration::from_secs(15), |cx| {
        screen(cx).contains("Welcome to the Build box stand-in")
    })
    .await;
    pass &= ok("the shell's banner and prompt show", banner);
    in_main(cx, |mw, window, cx| {
        if let Some(c) = mw
            .area_pane
            .read(cx)
            .shown_terminal(cx)
            .map(|p| p.read(cx).console.clone())
        {
            let focus = gpui_kit::Focusable::focus_handle(c.read(cx), cx);
            window.focus(&focus, cx);
        }
    });
    settle(cx, 300).await;

    // A command, and its output on a line of its own.
    run_command("echo lighthouse-ready", cx).await;
    let echoed = wait_until(cx, Duration::from_secs(10), |cx| {
        screen(cx).lines().any(|l| l.trim() == "lighthouse-ready")
    })
    .await;
    pass &= ok("a typed command runs and its output shows", echoed);

    // The grid is the window's: the shell hears the size, and a new size.
    let size = cx.update(|cx| console(cx).map(|c| c.read(cx).emulator().size()));
    run_command("stty size", cx).await;
    let reported = |cx: &mut App, rows: usize, cols: usize| {
        screen(cx)
            .lines()
            .any(|l| l.trim() == format!("{rows} {cols}"))
    };
    let first_size = match size {
        Some(s) => {
            wait_until(cx, Duration::from_secs(10), move |cx| {
                reported(cx, s.rows, s.cols)
            })
            .await
        }
        None => false,
    };
    pass &= ok(
        &format!("the shell was told the grid's size ({size:?})"),
        first_size,
    );
    in_main(cx, |_, window, _| {
        let b = window.bounds();
        window.resize(gpui_kit::size(
            b.size.width - gpui_kit::px(160.),
            b.size.height - gpui_kit::px(120.),
        ));
    });
    settle(cx, 600).await;
    let resized = cx.update(|cx| console(cx).map(|c| c.read(cx).emulator().size()));
    run_command("clear", cx).await;
    run_command("stty size", cx).await;
    let second = match resized {
        Some(s) => {
            wait_until(cx, Duration::from_secs(10), move |cx| {
                reported(cx, s.rows, s.cols)
            })
            .await
        }
        None => false,
    };
    pass &= ok(
        &format!("a smaller window resizes the grid and tells the shell ({size:?} → {resized:?})"),
        second && resized != size,
    );

    // Copy and Paste.
    run_command("echo tide-table", cx).await;
    wait_until(cx, Duration::from_secs(10), |cx| {
        screen(cx).lines().any(|l| l.trim() == "tide-table")
    })
    .await;
    let copied = cx.update(|cx| {
        let Some(c) = console(cx) else { return false };
        let text = screen(cx);
        let Some(row) = text.lines().position(|l| l.trim() == "tide-table") else {
            return false;
        };
        c.update(cx, |c, cx| {
            let e = c.emulator().clone();
            e.select_start(
                e.point_at(row, 0),
                alacritty_terminal::index::Side::Left,
                alacritty_terminal::selection::SelectionType::Simple,
            );
            e.select_to(e.point_at(row, 9), alacritty_terminal::index::Side::Right);
            c.copy(cx)
        })
    });
    let clipboard = cx.update(|cx| cx.read_from_clipboard().and_then(|c| c.text()));
    pass &= ok(
        &format!("Copy puts the selection on the clipboard ({clipboard:?})"),
        copied && clipboard.as_deref() == Some("tide-table"),
    );
    cx.update(|cx| cx.write_to_clipboard(ClipboardItem::new_string("echo pasted-in".to_string())));
    in_main(cx, |_, window, cx| {
        window.dispatch_action(Box::new(gpui_kit::component::input::Paste), cx)
    });
    settle(cx, 200).await;
    if let Some((handle, _)) = cx.update(|cx| cx.global::<AppState>().main_window.map(|h| (h, ())))
    {
        press(handle, "enter", cx);
    }
    let pasted = wait_until(cx, Duration::from_secs(10), |cx| {
        screen(cx).lines().any(|l| l.trim() == "pasted-in")
    })
    .await;
    pass &= ok("Paste types the clipboard into the shell", pasted);

    // A flood of output: frames keep coming, and ⌃C stops it.
    let painted_before = cx.update(|cx| console(cx).map_or(0, |c| c.read(cx).painted()));
    let started = Instant::now();
    run_command("yes", cx).await;
    settle(cx, 3000).await;
    let painted = cx.update(|cx| console(cx).map_or(0, |c| c.read(cx).painted())) - painted_before;
    let elapsed = started.elapsed().as_secs_f64();
    println!(
        "SMOKE perf terminal flood: {painted} frames in {elapsed:.2} s ({:.1} fps)",
        painted as f64 / elapsed
    );
    pass &= ok(
        "the console keeps painting under a flood of output",
        painted as f64 / elapsed > 20.,
    );
    if let Some((handle, _)) = cx.update(|cx| cx.global::<AppState>().main_window.map(|h| (h, ())))
    {
        press(handle, "ctrl-c", cx);
    }
    // The echo may have scrolled into the history by the time it is read.
    let stopped = wait_until(cx, Duration::from_secs(20), |cx| {
        console(cx).is_some_and(|c| !c.read(cx).emulator().search("^C").is_empty())
    })
    .await;
    pass &= ok("⌃C stops the running command", stopped);
    run_command("echo after-the-flood", cx).await;
    let back = wait_until(cx, Duration::from_secs(10), |cx| {
        screen(cx).lines().any(|l| l.trim() == "after-the-flood")
    })
    .await;
    pass &= ok("the shell takes commands again", back);

    // Find (⌘F): the matches, counted.
    press(main, "cmd-f", cx);
    settle(cx, 300).await;
    in_main(cx, |mw, window, cx| {
        if let Some(p) = mw.area_pane.read(cx).shown_terminal(cx) {
            // Typed after the flood (which pushed the earlier lines out of
            // the history): the command and its output.
            p.update(cx, |p, cx| p.type_find("flood", window, cx));
        }
    });
    let found = wait_until(cx, Duration::from_secs(5), |cx| {
        console(cx).is_some_and(|c| c.read(cx).find().is_some_and(|f| f.matches.len() >= 2))
    })
    .await;
    pass &= ok("Find in Terminal counts the matches", found);
    shoot_main(dir, "terminal-console-find", cx).await;
    let controls = ax(main, "terminal-console", dir, cx).await;
    pass &= ok(
        "AX: the find field",
        has(&controls, "TextInput", "Find in Terminal"),
    );
    pass &= ok(
        "AX: Terminal and Files",
        has(&controls, "Button", "Disconnect"),
    );
    press(main, "escape", cx);
    settle(cx, 300).await;
    shoot_main(dir, "terminal-console", cx).await;

    pass &= files(main, dir, cx).await;
    pass &= ports(dir, cx).await;
    pass &= in_a_chat(inputs, dir, cx).await;
    pass &= option_as_meta(dir, cx).await;
    pass
}

/// Settings › Keyboard › Use Option as Meta Key reaches the open console.
async fn option_as_meta(dir: &Path, cx: &mut AsyncApp) -> bool {
    let set = |on: bool, cx: &mut AsyncApp| {
        cx.update(|cx| {
            let settings = cx.global::<AppState>().settings.clone();
            settings.update(cx, |s, cx| {
                s.set_desktop(|d| d.terminal_option_as_meta = on, cx)
            });
        })
    };
    let nav = |cx: &mut AsyncApp| {
        cx.update(|cx| {
            let nav = cx.global::<AppState>().stores.navigation.clone();
            nav.update(cx, |n, cx| {
                n.open_item(AreaItem::Terminal(SERVER.into()), cx)
            });
        })
    };
    nav(cx);
    settle(cx, 500).await;
    set(true, cx);
    let followed = wait_until(cx, Duration::from_secs(5), |cx| {
        console(cx).is_some_and(|c| c.read(cx).option_as_meta)
    })
    .await;
    let mut pass = ok("Use Option as Meta Key reaches the console", followed);
    if let Some(handle) = super::settings_tab(
        crate::views::settings::Tab::Keyboard,
        dir,
        "terminal-settings-keyboard",
        cx,
    )
    .await
    {
        let controls = ax(handle, "terminal-settings-keyboard", dir, cx).await;
        pass &= ok(
            "AX: the Keyboard pane's Use Option as Meta Key switch",
            has(&controls, "Switch", "Use Option as Meta Key"),
        );
    }
    set(false, cx);
    let back = wait_until(cx, Duration::from_secs(5), |cx| {
        console(cx).is_some_and(|c| !c.read(cx).option_as_meta)
    })
    .await;
    pass & ok("turned off again, Option types its character", back)
}

fn files_view(cx: &mut App) -> Option<Entity<FilesView>> {
    Some(pane(cx)?.read(cx).files.clone())
}

fn names(cx: &mut App) -> Vec<String> {
    files_view(cx)
        .map(|f| {
            f.read(cx)
                .entries()
                .iter()
                .map(|e| e.name.clone())
                .collect()
        })
        .unwrap_or_default()
}

fn in_files<R>(
    cx: &mut AsyncApp,
    f: impl FnOnce(&mut FilesView, &mut gpui_kit::Window, &mut gpui_kit::Context<FilesView>) -> R,
) -> Option<R> {
    in_main(cx, move |mw, window, cx| {
        let files = mw
            .area_pane
            .read(cx)
            .shown_terminal(cx)?
            .read(cx)
            .files
            .clone();
        Some(files.update(cx, |v, cx| f(v, window, cx)))
    })
    .flatten()
}

/// Types `name` into the row being named, then Return.
async fn name_row(main: gpui_kit::AnyWindowHandle, name: &str, cx: &mut AsyncApp) {
    for c in name.chars() {
        press(main, &c.to_string(), cx);
    }
    press(main, "enter", cx);
}

async fn files(main: gpui_kit::AnyWindowHandle, dir: &Path, cx: &mut AsyncApp) -> bool {
    let mut pass = true;
    in_main(cx, |mw, window, cx| {
        if let Some(p) = mw.area_pane.read(cx).shown_terminal(cx) {
            p.update(cx, |p, cx| p.set_mode(Mode::Files, window, cx));
        }
    });
    let listed = wait_until(cx, Duration::from_secs(15), |cx| {
        let n = names(cx);
        n.contains(&"notes.txt".to_string()) && n.contains(&"project".to_string())
    })
    .await;
    pass &= ok(
        &format!(
            "Files lists the shell's folder, folders first ({:?})",
            cx.update(names)
        ),
        listed && cx.update(names).first().map(String::as_str) == Some("project"),
    );
    shoot_main(dir, "terminal-files", cx).await;
    let controls = ax(main, "terminal-files", dir, cx).await;
    pass &= ok(
        "AX: a folder row says so",
        has(&controls, "ListBoxOption", "project, folder"),
    );
    pass &= ok(
        "AX: Upload and New Folder",
        has(&controls, "Button", "Upload") && has(&controls, "Button", "New Folder"),
    );

    // Upload a file from this Mac.
    let local = std::env::temp_dir().join(format!("conduit-n4-e2e-{}", std::process::id()));
    std::fs::create_dir_all(&local).ok();
    let upload = local.join("harbour-log.txt");
    std::fs::write(&upload, "Moorings checked at dusk.\n").ok();
    in_files(cx, |f, _, cx| f.upload(vec![upload.clone()], cx));
    let uploaded = wait_until(cx, Duration::from_secs(15), |cx| {
        names(cx).contains(&"harbour-log.txt".to_string())
    })
    .await;
    pass &= ok("Upload puts a file in the folder shown", uploaded);

    // Rename it in place.
    in_files(cx, |f, window, cx| {
        f.start_rename("/home/demo/harbour-log.txt", window, cx)
    });
    settle(cx, 300).await;
    in_main(cx, |_, window, cx| {
        // Select the name's text, as the field opens with it selected.
        window.dispatch_action(Box::new(gpui_kit::component::input::SelectAll), cx);
    });
    name_row(main, "harbour-notes.txt", cx).await;
    let renamed = wait_until(cx, Duration::from_secs(15), |cx| {
        let n = names(cx);
        n.contains(&"harbour-notes.txt".to_string()) && !n.contains(&"harbour-log.txt".to_string())
    })
    .await;
    pass &= ok(
        &format!("Rename names it in place ({:?})", cx.update(names)),
        renamed,
    );

    // Download it.
    let saved_dir = local.join("downloads");
    std::fs::create_dir_all(&saved_dir).ok();
    cx.update(|cx| cx.set_global(DownloadTo(Some(saved_dir.clone()))));
    in_files(cx, |f, _, cx| {
        f.download("/home/demo/harbour-notes.txt", cx)
    });
    let saved = saved_dir.join("harbour-notes.txt");
    let downloaded = wait_until(cx, Duration::from_secs(15), |_| {
        std::fs::read_to_string(&saved).is_ok_and(|t| t == "Moorings checked at dusk.\n")
    })
    .await;
    pass &= ok("Download saves the file's bytes", downloaded);

    // Show a file: text in the viewer.
    in_files(cx, |f, window, cx| {
        f.show("/home/demo/notes.txt", window, cx)
    });
    let shown = wait_until(cx, Duration::from_secs(15), |cx| {
        crate::views::sheet::current::<crate::views::terminal::viewer::FileSheet>(cx)
            .is_some_and(|s| s.read(cx).text().is_some_and(|t| t.contains("Tide tables")))
    })
    .await;
    pass &= ok("a text file shows in the viewer", shown);
    if let Some(sheet) = cx.update(|cx| crate::views::sheet::current_window(cx)) {
        crate::smoke::shoot_both_modes(sheet, dir, "terminal-file-viewer", cx).await;
    }
    cx.update(crate::views::sheet::dismiss);
    settle(cx, 600).await;

    // New Folder, then into it and back out (⌘↑).
    in_files(cx, |f, window, cx| f.start_new_folder(window, cx));
    settle(cx, 300).await;
    in_main(cx, |_, window, cx| {
        window.dispatch_action(Box::new(gpui_kit::component::input::SelectAll), cx);
    });
    name_row(main, "sea-charts", cx).await;
    let made = wait_until(cx, Duration::from_secs(15), |cx| {
        names(cx).contains(&"sea-charts".to_string())
    })
    .await;
    pass &= ok("New Folder makes a folder", made);
    in_files(cx, |f, window, cx| {
        f.open_entry("/home/demo/sea-charts/", window, cx)
    });
    let inside = wait_until(cx, Duration::from_secs(10), |cx| {
        files_view(cx).is_some_and(|f| f.read(cx).path() == "/home/demo/sea-charts/")
    })
    .await;
    pass &= ok("opening a folder shows its files", inside);
    in_files(cx, |f, window, cx| f.focus(window, cx));
    press(main, "cmd-up", cx);
    let out = wait_until(cx, Duration::from_secs(10), |cx| {
        files_view(cx).is_some_and(|f| f.read(cx).path() == "/home/demo/")
    })
    .await;
    pass &= ok("⌘↑ goes to the enclosing folder", out);

    // A change made elsewhere (the shell, an agent) arrives by itself.
    let handle = cx.update(|cx| pane(cx).and_then(|p| p.read(cx).handle().map(str::to_string)));
    if let Some(handle) = handle {
        let rpc = cx.update(|cx| cx.global::<AppState>().stores.connection.read(cx).rpc());
        let _ = rpc
            .call::<conduit_protocol::methods::TerminalFileAction>(
                &conduit_protocol::TerminalFileAction {
                    handle,
                    op: conduit_protocol::TerminalFileOp::Mkdir,
                    path: "/home/demo/from-elsewhere".into(),
                    destination: None,
                },
            )
            .await;
    }
    let live = wait_until(cx, Duration::from_secs(15), |cx| {
        names(cx).contains(&"from-elsewhere".to_string())
    })
    .await;
    pass &= ok(
        "a folder made elsewhere shows without a refresh (terminal.changed)",
        live,
    );

    // Delete, after the sheet (answered by the pass).
    for path in [
        "/home/demo/harbour-notes.txt",
        "/home/demo/sea-charts/",
        "/home/demo/from-elsewhere/",
    ] {
        let path = path.to_string();
        in_files(cx, move |f, window, cx| f.confirm_delete(&path, window, cx));
        settle(cx, 300).await;
    }
    let deleted = wait_until(cx, Duration::from_secs(15), |cx| {
        let n = names(cx);
        !n.iter()
            .any(|n| n == "harbour-notes.txt" || n == "sea-charts" || n == "from-elsewhere")
    })
    .await;
    pass &= ok("Delete removes them", deleted);
    std::fs::remove_dir_all(&local).ok();
    pass
}

async fn ports(dir: &Path, cx: &mut AsyncApp) -> bool {
    use crate::views::terminal::preview::OpenPreviews;
    let mut pass = true;
    in_main(cx, |mw, window, cx| {
        if let Some(p) = mw.area_pane.read(cx).shown_terminal(cx) {
            p.update(cx, |p, cx| {
                p.set_mode(Mode::Console, window, cx);
                p.toggle_ports(cx);
            });
        }
    });
    let listed = wait_until(cx, Duration::from_secs(15), |cx| {
        pane(cx).is_some_and(|p| p.read(cx).ports().iter().any(|p| p.port == 5173))
    })
    .await;
    pass &= ok("Listening Ports shows the dev server (5173, vite)", listed);
    shoot_main(dir, "terminal-ports", cx).await;
    cx.update(|cx| {
        if let Some(p) = pane(cx) {
            p.update(cx, |p, cx| p.open_port(5173, cx));
        }
    });
    let preview = |cx: &mut App| {
        cx.try_global::<OpenPreviews>()
            .and_then(|p| p.0.iter().find(|(port, _, _)| *port == 5173).cloned())
            .and_then(|(port, h, v)| Some((port, h, v.upgrade()?)))
    };
    let opened = wait_until(cx, Duration::from_secs(20), |cx| {
        preview(cx).is_some_and(|(_, _, v)| v.read(cx).address() == "localhost:5173")
    })
    .await;
    pass &= ok(
        "the port opens in a preview window, through the sign-in-free proxy",
        opened,
    );
    settle(cx, 1500).await;
    if let Some((_, handle, view)) = cx.update(preview) {
        crate::smoke::shoot_both_modes(handle, dir, "terminal-port-preview", cx).await;
        // A link on the page: Open WebUI's proxy reports it, the preview
        // follows it (the core's navigation script), still on the port.
        cx.update(|cx| {
            view.read(cx)
                .eval("document.getElementById('about').click()", cx)
        });
        let followed = wait_until(cx, Duration::from_secs(15), |cx| {
            view.read(cx).address() == "localhost:5173/about"
        })
        .await;
        let now = cx.update(|cx| view.read(cx).address());
        pass &= ok(
            &format!("a link in the preview stays on the port ({now})"),
            followed,
        );
        let _ = handle.update(cx, |_, window, _| window.remove_window());
    }
    pass
}

async fn in_a_chat(inputs: &E2eInputs, dir: &Path, cx: &mut AsyncApp) -> bool {
    use super::chat::{chat_store, in_pane, send, wait_answer, wait_models};
    use crate::views::terminal::computer::{OpenComputer, Phase};
    let mut pass = ok("models.list answered", wait_models(cx).await);
    super::composer::new_chat(cx).await;
    let model = inputs.model();
    in_pane(cx, move |p, _, cx| {
        p.composer_store
            .update(cx, |c, cx| c.select_model(&model, cx))
    });
    // The composer's Terminal section: the Build box for this chat's tool.
    cx.update(|cx| crate::views::terminal::chat::toggle_terminal(SERVER.into(), None, cx));
    let selected = wait_until(cx, Duration::from_secs(10), |cx| {
        cx.global::<AppState>()
            .stores
            .areas
            .read(cx)
            .terminal_selected
            .as_deref()
            == Some(SERVER)
    })
    .await;
    pass &= ok(
        "the composer's Terminal section selects the Build box",
        selected,
    );

    // The model's terminal tool shows a file: it opens over the chat.
    send("Please display the notes file.", cx).await;
    let shown = wait_until(cx, Duration::from_secs(60), |cx| {
        crate::views::sheet::current::<crate::views::terminal::viewer::FileSheet>(cx)
            .is_some_and(|s| s.read(cx).text().is_some_and(|t| t.contains("Tide tables")))
    })
    .await;
    pass &= ok("a model's display_file opens the file over the chat", shown);
    if let Some(sheet) = cx.update(|cx| crate::views::sheet::current_window(cx)) {
        crate::smoke::shoot(sheet, dir.join("terminal-display-file.png"), cx).await;
    }
    cx.update(crate::views::sheet::dismiss);
    pass &= ok(
        "the answer finishes",
        wait_answer(cx, Duration::from_secs(60)).await,
    );
    let chat_id = cx.update(|cx| chat_store(cx).map(|s| s.read(cx).chat_id().to_string()));

    // The header's Computer: the desktop, live through the relay.
    let offered = wait_until(cx, Duration::from_secs(20), |cx| {
        super::chat::pane(cx)
            .is_some_and(|p| p.read(cx).computer.as_ref().is_some_and(|c| c.available()))
    })
    .await;
    pass &= ok(
        "the header offers Computer for a chat with the Build box",
        offered,
    );
    shoot_main(dir, "terminal-chat-computer-button", cx).await;
    if let Some(chat_id) = chat_id.clone() {
        let status = cx.update(|cx| {
            super::chat::pane(cx)
                .and_then(|p| p.read(cx).computer.clone())
                .map(|c| c.status)
        });
        if let Some(status) = status {
            cx.update(|cx| {
                let stores = cx.global::<AppState>().stores.clone();
                crate::views::terminal::computer::open(stores, chat_id.clone(), status, cx)
            });
        }
    }
    let live = wait_until(cx, Duration::from_secs(30), |cx| {
        cx.try_global::<OpenComputer>()
            .and_then(|o| o.0.clone())
            .and_then(|(_, _, w)| w.upgrade())
            .is_some_and(|w| *w.read(cx).phase() == Phase::Live && w.read(cx).controlling())
    })
    .await;
    pass &= ok(
        "Computer shows the desktop live, the user in control while idle",
        live,
    );
    if let Some((_, handle, _)) =
        cx.update(|cx| cx.try_global::<OpenComputer>().and_then(|o| o.0.clone()))
    {
        settle(cx, 800).await;
        crate::smoke::shoot_both_modes(handle, dir, "terminal-computer", cx).await;
        let controls = ax(handle, "terminal-computer", dir, cx).await;
        pass &= ok("AX: Computer's More", has(&controls, "Button", "More"));
        let _ = handle.update(cx, |_, window, _| window.remove_window());
    }
    // Leave the account as it was: no terminal for chats, the chat gone.
    cx.update(|cx| crate::views::terminal::chat::toggle_terminal(SERVER.into(), None, cx));
    if let Some(chat_id) = chat_id {
        let rpc = cx.update(|cx| cx.global::<AppState>().stores.connection.read(cx).rpc());
        let _ = rpc
            .call::<conduit_protocol::methods::ChatsDelete>(&conduit_protocol::ChatRef {
                id: chat_id,
            })
            .await;
    }
    pass
}
