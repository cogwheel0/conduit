//! `--e2e rendering-media`: remote pictures, inline diagrams, PDF cards,
//! Highlight Citations and Live Updates, over the real daemon, on the
//! local Open WebUI, its fake model and a synthetic "other site"
//! (`tool/local_owui/media_site.py`, started here on the media port).
//!
//! * **A stored chat** (`owui.sh media`): three pictures from the other
//!   site wait behind placeholders, and nothing is fetched before a click
//!   (the site's request log is empty); Load Image loads one, once, with
//!   no cookie, credentials or `Referer` (and no cookie the site set
//!   before); Always Load Images from the site loads the rest (one that
//!   is not a picture fails, saying so); the server's own picture and PDF
//!   load with no prompt; a loaded picture opens in the viewer.
//! * **Diagrams:** the Mermaid diagram and the chart are drawn inline, the
//!   broken diagram falls back to its code; Show Code, Open in Preview; a
//!   change of appearance draws them again.
//! * **PDF cards:** the server's PDF with its page count; the other site's
//!   behind Load Preview, then loaded by the allowed site.
//! * **Streaming:** a diagram's code shows as code while its fence is open,
//!   and is drawn once the answer ends.
//! * **Settings › Chats:** Highlight Citations switches the setting;
//!   Remote Content lists the allowed site, and Remove takes it off.
//! * **Live Updates:** with the server stopped, the toolbar item appears,
//!   its popover's Retry says it is still disconnected; with the server
//!   back, the item goes.
//!
//! * **Never this Mac:** the daemon's `/media` refuses a picture on this
//!   Mac (loopback, `localhost`), a link-local address, and a redirect from
//!   the site back to this Mac, without asking for it. So the site listens
//!   on the Mac's network address (a private LAN address is allowed).
//!
//! Each state is shot in light and dark.

use std::path::Path;
use std::process::{Child, Command};
use std::time::Duration;

use conduit_protocol::{ChatRef, methods};
use gpui_kit::{App, AsyncApp, ListOffset, point, px};
use serde_json::Value;

use super::chat::{chat_store, in_pane, send, sign_in, wait_answer, wait_models};
use super::composer::{new_chat, open_chat};
use super::*;
use crate::capture::drive;
use crate::views::chat::diagrams::drawn_counts;
use crate::views::chat::remote_image::ImageAction;

/// The synthetic site, stopped when the pass ends.
struct Site(Child);

impl Drop for Site {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

/// The media site's port: `CONDUIT_MEDIA_PORT`, else five past the
/// server's.
fn media_port(server: &str) -> u16 {
    std::env::var("CONDUIT_MEDIA_PORT")
        .ok()
        .and_then(|p| p.parse().ok())
        .or_else(|| {
            url::Url::parse(server)
                .ok()
                .and_then(|u| u.port())
                .map(|p| p + 5)
        })
        .unwrap_or(8155)
}

/// The other site's host: this Mac's address on its network (the route
/// out), since `/media` never fetches from this Mac's own addresses. No
/// packet is sent: connecting a UDP socket only picks the route.
pub(super) fn network_host() -> Option<String> {
    let socket = std::net::UdpSocket::bind("0.0.0.0:0").ok()?;
    socket.connect("192.0.2.1:9").ok()?;
    let ip = socket.local_addr().ok()?.ip();
    (!ip.is_loopback() && !ip.is_unspecified()).then(|| ip.to_string())
}

static SITE_HOST: std::sync::OnceLock<String> = std::sync::OnceLock::new();

/// The other site's host, as the placeholders and Remote Content name it.
fn site_host() -> &'static str {
    SITE_HOST.get().map(String::as_str).unwrap_or("127.0.0.1")
}

/// Asks the daemon's `/media/image` for `url`, as a placeholder's Load
/// Image does: the error code it answers with, or None when it loaded.
async fn media_refusal(url: &str, cx: &mut AsyncApp) -> Option<String> {
    let http = cx.update(|cx| {
        cx.try_global::<crate::stores::files::FileAccess>()
            .and_then(|a| a.http.clone())
    })?;
    let (tx, rx) = futures::channel::oneshot::channel();
    let url = url.to_string();
    conduit_daemon::runtime::shared().spawn(async move {
        let answer = http.media("image", &url).await;
        let _ = tx.send(answer.err().map(|e| e.code.as_str().to_string()));
    });
    rx.await.unwrap_or(Some("no answer".into()))
}

/// What the site was asked for, as its log has it.
fn requests(log: &Path) -> Vec<Value> {
    std::fs::read_to_string(log)
        .unwrap_or_default()
        .lines()
        .filter_map(|l| serde_json::from_str(l).ok())
        .collect()
}

fn asked_for(log: &Path, path: &str) -> Vec<Value> {
    requests(log)
        .into_iter()
        .filter(|r| r["path"].as_str() == Some(path))
        .collect()
}

/// No request carried anything of the user's: no cookie (not even the one
/// the site set), no credentials, no `Referer`; the bare app name as agent.
fn anonymous(log: &Path) -> bool {
    let all = requests(log);
    !all.is_empty()
        && all.iter().all(|r| {
            r["cookie"].is_null()
                && r["referer"].is_null()
                && r["authorization"].is_null()
                && r["user_agent"].as_str() == Some("Conduit")
        })
}

fn owui(args: &[&str]) -> bool {
    Command::new("../tool/local_owui/owui.sh")
        .args(args)
        .status()
        .is_ok_and(|s| s.success())
}

/// Scrolls the open chat's last row (the answer) to `offset` points into it.
fn scroll_answer(offset: f32, cx: &mut AsyncApp) {
    in_pane(cx, move |p, _, cx| {
        if let Some(chat) = &p.chat {
            chat.transcript.update(cx, |t, cx| {
                t.stop_following();
                let list = t.list_state().clone();
                let last = list.item_count().saturating_sub(1);
                list.scroll_to(ListOffset {
                    item_ix: last,
                    offset_in_item: px(offset),
                });
                cx.notify();
            });
        }
    });
}

/// The main window's nodes after scrolling the answer to `offset`.
async fn nodes_at(offset: f32, cx: &mut AsyncApp) -> Vec<drive::Node> {
    scroll_answer(offset, cx);
    settle(cx, 400).await;
    let Some((main, _)) = cx.update(main_window) else {
        return vec![];
    };
    drive::nodes(main, cx).await
}

/// The main window's height, in points.
fn main_height(cx: &mut AsyncApp) -> f32 {
    cx.update(|cx| {
        main_window(cx).and_then(|(h, _)| {
            h.update(cx, |_, window, _| f32::from(window.viewport_size().height))
                .ok()
        })
    })
    .unwrap_or(800.)
}

/// The answer's offset at which [`find_in_answer`] last found its node.
static LAST_OFFSET: std::sync::Mutex<f32> = std::sync::Mutex::new(0.);

/// Scrolls through the answer until a node with `role` whose label passes
/// `label` is in the open part of the transcript (below the toolbar, above
/// the composer, which the transcript runs under); returns it.
async fn find_in_answer(
    role: &str,
    label: impl Fn(&str) -> bool,
    cx: &mut AsyncApp,
) -> Option<drive::Node> {
    let bottom = main_height(cx) - 150.;
    let mut offset = 0.;
    while offset <= 4000. {
        let nodes = nodes_at(offset, cx).await;
        let found = nodes.iter().find(|n| {
            n.role == role
                && label(&n.label)
                && n.center().is_some_and(|c| {
                    let y = f32::from(c.y);
                    y > 70. && y < bottom
                })
        });
        if let Some(n) = found {
            if let Ok(mut at) = LAST_OFFSET.lock() {
                *at = offset;
            }
            return Some(n.clone());
        }
        offset += 200.;
    }
    None
}

async fn click_in_answer(role: &str, label: impl Fn(&str) -> bool, cx: &mut AsyncApp) -> bool {
    let Some(node) = find_in_answer(role, label, cx).await else {
        return false;
    };
    let (Some((main, _)), Some(at)) = (cx.update(main_window), node.center()) else {
        return false;
    };
    drive::click(main, at, cx).await;
    settle(cx, 300).await;
    true
}

/// Shoots the main window in light and dark with the answer scrolled to
/// where the last [`find_in_answer`] found its node (a change of
/// appearance lays the list out again from the answer's top).
async fn shoot_answer(dir: &Path, name: &str, cx: &mut AsyncApp) {
    let offset = LAST_OFFSET.lock().map(|o| *o).unwrap_or(0.);
    let Some((main, _)) = cx.update(main_window) else {
        return;
    };
    for mode in [
        crate::prefs::ThemeMode::Light,
        crate::prefs::ThemeMode::Dark,
    ] {
        cx.update(|cx| crate::smoke::set_mode(mode, cx));
        settle(cx, 500).await;
        scroll_answer(offset, cx);
        settle(cx, 700).await;
        crate::smoke::shoot(
            main,
            dir.join(format!("{name}-{}.png", crate::smoke::mode_name(mode))),
            cx,
        )
        .await;
    }
}

/// Dispatches `action` in the main window, as a menu item does.
fn dispatch(action: ImageAction, cx: &mut AsyncApp) {
    in_main(cx, move |_, window, cx| {
        window.dispatch_action(Box::new(action), cx)
    });
}

fn windows(cx: &mut AsyncApp) -> Vec<gpui_kit::AnyWindowHandle> {
    cx.update(|cx| cx.windows())
}

/// The windows that opened since `before`.
fn opened_since(
    before: &[gpui_kit::AnyWindowHandle],
    cx: &mut AsyncApp,
) -> Vec<gpui_kit::AnyWindowHandle> {
    windows(cx)
        .into_iter()
        .filter(|w| !before.contains(w))
        .collect()
}

fn close(handle: gpui_kit::AnyWindowHandle, cx: &mut AsyncApp) {
    cx.update(|cx| {
        let _ = handle.update(cx, |_, window, _| window.remove_window());
    });
}

pub async fn run(inputs: &E2eInputs, dir: &Path, cx: &mut AsyncApp) -> bool {
    let Some((url, email, password)) = inputs.owui() else {
        return ok(NO_SERVER, false);
    };
    let port = media_port(&url);
    let host = network_host();
    let mut pass = ok(
        "this Mac has a network address for the other site",
        host.is_some(),
    );
    let host = SITE_HOST.get_or_init(|| host.unwrap_or_else(|| "127.0.0.1".into()));
    let site_url = format!("http://{host}:{port}");
    let log = dir.join("media-requests.jsonl");
    let _ = std::fs::remove_file(&log);
    // On every address: the Mac's network one for the pictures, loopback
    // for the refusals below to prove nothing reached it.
    let site = Command::new("python3")
        .args([
            "-I",
            "../tool/local_owui/media_site.py",
            "--host",
            "0.0.0.0",
            "--port",
        ])
        .arg(port.to_string())
        .arg("--log")
        .arg(&log)
        .spawn()
        .map(Site);
    pass &= ok("the synthetic media site starts", site.is_ok());
    settle(cx, 800).await;

    let media_dir = dir.join("media");
    let stored = cx
        .background_executor()
        .spawn({
            let d = media_dir.clone();
            let s = site_url.clone();
            async move { owui(&["media", &d.to_string_lossy(), &s]) }
        })
        .await;
    pass &= ok("owui.sh media stored the media chat", stored);
    let media: Value = std::fs::read_to_string(media_dir.join("media.json"))
        .ok()
        .and_then(|t| serde_json::from_str(&t).ok())
        .unwrap_or(Value::Null);
    let chat_id = media["chat_id"].as_str().unwrap_or_default().to_string();

    pass &= sign_in(&url, &email, &password, cx).await;
    pass &= ok("models.list answered", wait_models(cx).await);
    let model = inputs.model();
    in_pane(cx, move |p, _, cx| {
        p.composer_store
            .update(cx, |c, cx| c.select_model(&model, cx))
    });

    pass &= pictures(&chat_id, &log, dir, cx).await;
    pass &= never_this_mac(port, &log, cx).await;
    pass &= diagrams(dir, cx).await;
    pass &= pdf_cards(&log, dir, cx).await;
    pass &= chats_settings(dir, cx).await;
    pass &= streaming_diagram(dir, cx).await;
    pass &= live_updates(dir, cx).await;
    pass &= ok(
        "every request to the other site was anonymous (no cookie, credentials or Referer)",
        anonymous(&log),
    );

    // Clean up: the chats this pass made, the stored one among them.
    let mut made = vec![chat_id];
    made.extend(MADE.lock().map(|m| m.clone()).unwrap_or_default());
    let rpc = cx.update(|cx| cx.global::<AppState>().stores.connection.read(cx).rpc());
    let mut deleted = true;
    for id in made
        .iter()
        .filter(|id| !id.is_empty() && !id.starts_with("local:"))
    {
        deleted &= rpc
            .call::<methods::ChatsDelete>(&ChatRef { id: id.clone() })
            .await
            .is_ok();
    }
    pass &= ok("the chats this pass made are deleted", deleted);
    drop(site);
    pass
}

static MADE: std::sync::Mutex<Vec<String>> = std::sync::Mutex::new(Vec::new());

/// `/media` never fetches from this Mac (loopback, `localhost`), a
/// link-local address (a router's or cloud metadata), or through a
/// redirect from a site back to this Mac; and the site never hears of the
/// refused addresses.
async fn never_this_mac(port: u16, log: &Path, cx: &mut AsyncApp) -> bool {
    let refused = Some("media.refused".to_string());
    let mut pass = true;
    for url in [
        format!("http://127.0.0.1:{port}/this-mac-only.png"),
        format!("http://localhost:{port}/this-mac-only.png"),
        "http://169.254.169.254/latest/meta-data/".to_string(),
    ] {
        let answer = media_refusal(&url, cx).await;
        pass &= ok(
            &format!("/media refuses {url} (answer {answer:?})"),
            answer == refused,
        );
    }
    let redirect = format!("http://{}:{port}/to-this-mac.png", site_host());
    let answer = media_refusal(&redirect, cx).await;
    pass &= ok(
        &format!("/media refuses the site's redirect back to this Mac (answer {answer:?})"),
        answer == refused,
    );
    pass &= ok(
        "…having asked the site once, and this Mac never",
        asked_for(log, "/to-this-mac.png").len() == 1
            && asked_for(log, "/this-mac-only.png").is_empty(),
    );
    pass
}

async fn pictures(chat_id: &str, log: &Path, dir: &Path, cx: &mut AsyncApp) -> bool {
    let mut pass = ok("the media chat opens", open_chat(chat_id, cx).await);
    settle(cx, 1500).await;

    // ── Placeholders, and nothing fetched ───────────────────────────────
    let placeholder = find_in_answer(
        "Group",
        |l| {
            l.starts_with(&format!("Remote image from {}, not loaded", site_host()))
                && l.contains("Tide chart")
        },
        cx,
    )
    .await;
    pass &= ok(
        "a picture from another site is a placeholder named by its site and alt text",
        placeholder.is_some(),
    );
    let nodes = nodes_at(0., cx).await;
    pass &= ok(
        "the placeholder offers Load Image and Image Options",
        drive::find(&nodes, "Button", |l| l == "Load Image").is_some()
            && drive::find(&nodes, "Button", |l| l == "Image Options").is_some(),
    );
    shoot_main(dir, "media-placeholders", cx).await;
    pass &= ok(
        "nothing is fetched from the other site before a click",
        requests(log).is_empty(),
    );

    // ── The server's own picture loads with no prompt ──────────────────
    let office = find_in_answer("Image", |l| l == "Harbour office chart", cx).await;
    pass &= ok(
        "the server's own picture loads through /files with no prompt",
        office.is_some(),
    );

    // ── Load Image: that one picture, once ─────────────────────────────
    scroll_answer(0., cx);
    settle(cx, 300).await;
    let clicked = click_in_answer("Button", |l| l == "Load Image", cx).await;
    pass &= ok("Load Image is clicked", clicked);
    let loaded = find_in_answer("Image", |l| l == "Tide chart for Port Wren", cx)
        .await
        .is_some();
    pass &= ok("Load Image loads the picture", loaded);
    pass &= ok(
        "…with one request for it and none for the others",
        asked_for(log, "/tide-chart.png").len() == 1
            && asked_for(log, "/harbour-map.png").is_empty()
            && asked_for(log, "/not-a-picture.png").is_empty(),
    );
    shoot_main(dir, "media-loaded-one", cx).await;

    // ── Always Load Images from the site ───────────────────────────────
    dispatch(ImageAction::AllowHost(site_host().into()), cx);
    settle(cx, 600).await;
    let allowed = cx.update(|cx| {
        cx.global::<AppState>()
            .settings
            .read(cx)
            .prefs
            .remote_image_hosts
            .clone()
    });
    pass &= ok(
        "Always Load Images from the site keeps the site",
        allowed == vec![site_host().to_string()],
    );
    let map = find_in_answer(
        "Image",
        |l| l.contains("harbour-map") || l.contains("Harbour map"),
        cx,
    )
    .await;
    pass &= ok(
        "…and the site's other picture loads by itself",
        map.is_some(),
    );
    let not_picture = find_in_answer(
        "Group",
        |l| l.contains("Ferry timetable") && l.contains("isn't an image"),
        cx,
    )
    .await;
    pass &= ok(
        "a link that is not a picture says so, with Try Again",
        not_picture.is_some(),
    );
    pass &= ok(
        "each picture was asked for once",
        asked_for(log, "/tide-chart.png").len() == 1
            && asked_for(log, "/harbour-map.png").len() == 1
            && asked_for(log, "/not-a-picture.png").len() == 1,
    );
    shoot_main(dir, "media-allowed", cx).await;

    // ── A loaded picture opens in the viewer ────────────────────────────
    let before = windows(cx);
    let opened = click_in_answer("Image", |l| l == "Tide chart for Port Wren", cx).await;
    settle(cx, 800).await;
    let new = opened_since(&before, cx);
    pass &= ok(
        "a loaded picture opens in the image viewer",
        opened && new.len() == 1,
    );
    for v in new {
        shoot_both_modes(v, dir, "media-viewer", cx).await;
        close(v, cx);
    }
    settle(cx, 300).await;
    pass
}

async fn diagrams(dir: &Path, cx: &mut AsyncApp) -> bool {
    let mermaid = find_in_answer("Image", |l| l == "Diagram: Tide cycle", cx).await;
    let mut pass = ok(
        "the Mermaid diagram is drawn inline, named by its accTitle",
        mermaid.is_some(),
    );
    let chart = find_in_answer("Image", |l| l == "Chart: Water levels", cx).await;
    pass &= ok(
        "the chart is drawn inline, named by its title",
        chart.is_some(),
    );
    let (_, _, failed) = cx.update(|_| drawn_counts());
    pass &= ok(
        "the broken diagram is not drawn (its code shows, with a note)",
        failed >= 1,
    );
    // Shot with the diagram on screen (`find_in_answer` left it there).
    shoot_answer(dir, "media-diagrams", cx).await;
    let (ready_after_modes, _, _) = cx.update(|_| drawn_counts());
    pass &= ok(
        "light and dark each draw the diagrams in their own colours",
        ready_after_modes >= 4,
    );

    // Show Code, then Hide Code.
    let shown = click_in_answer("Button", |l| l == "Show Code", cx).await;
    settle(cx, 400).await;
    let hide = find_in_answer("Button", |l| l == "Hide Code", cx).await;
    pass &= ok(
        "Show Code shows the diagram's code (the button says Hide Code)",
        shown && hide.is_some(),
    );
    shoot_answer(dir, "media-diagram-code", cx).await;
    let hidden = click_in_answer("Button", |l| l == "Hide Code", cx).await;
    pass &= ok("Hide Code hides it again", hidden);

    // Open in Preview: the larger window.
    let before = windows(cx);
    let clicked = click_in_answer("Button", |l| l == "Open in Preview", cx).await;
    settle(cx, 1500).await;
    let new = opened_since(&before, cx);
    pass &= ok(
        "Open in Preview opens the Preview window",
        clicked && new.len() == 1,
    );
    for w in new {
        shoot_both_modes(w, dir, "media-diagram-preview", cx).await;
        close(w, cx);
    }
    settle(cx, 300).await;
    pass
}

async fn pdf_cards(log: &Path, dir: &Path, cx: &mut AsyncApp) -> bool {
    let server = find_in_answer(
        "Button",
        |l| l.starts_with("Open PDF: harbour-guide.pdf") && l.contains("2 pages"),
        cx,
    )
    .await;
    let mut pass = ok(
        "the server's PDF is a card with its first page and page count, with no prompt",
        server.is_some(),
    );
    // The site was allowed above, so its PDF loads too.
    let remote = find_in_answer(
        "Button",
        |l| l.starts_with("Open PDF: Tide tables") && l.contains("3 pages"),
        cx,
    )
    .await;
    pass &= ok(
        "the other site's PDF loads once its site is allowed (3 pages)",
        remote.is_some() && asked_for(log, "/tide-tables.pdf").len() == 1,
    );
    shoot_answer(dir, "media-pdf-cards", cx).await;
    // A PDF link inside a sentence: a chip that opens it, nothing fetched.
    let chip = find_in_answer("Link", |l| l == "Open PDF: ferry notes", cx).await;
    pass &= ok(
        "a PDF link in a sentence is a chip, and nothing is fetched for it",
        chip.is_some() && asked_for(log, "/ferry-notes.pdf").is_empty(),
    );
    pass
}

/// Clicks the [role] control named [label] in a settings pane once it is
/// on screen, scrolling the pane down until it is (the Chats pane is taller
/// than the window).
async fn click_in_view(
    handle: gpui_kit::AnyWindowHandle,
    role: &str,
    label: &str,
    cx: &mut AsyncApp,
) -> bool {
    let height = cx.update(|cx| {
        handle
            .update(cx, |_, window, _| f32::from(window.viewport_size().height))
            .unwrap_or(600.)
    });
    for _ in 0..12 {
        let nodes = drive::nodes(handle, cx).await;
        let at = drive::find(&nodes, role, |l| l == label)
            .filter(|n| {
                n.bounds
                    .is_some_and(|b| f32::from(b.top()) > 8. && f32::from(b.bottom()) < height - 8.)
            })
            .and_then(drive::Node::center);
        if let Some(at) = at {
            drive::click(handle, at, cx).await;
            return true;
        }
        drive::scroll(handle, point(px(420.), px(height / 2.)), 240., cx);
        settle(cx, 300).await;
    }
    false
}

async fn chats_settings(dir: &Path, cx: &mut AsyncApp) -> bool {
    let Some(handle) = settings_tab(Tab::Chats, dir, "media-settings-chats", cx).await else {
        return ok("Settings › Chats opens", false);
    };
    let controls = ax(handle, "media-settings-chats", dir, cx).await;
    let mut pass = ok(
        "Settings › Chats has Highlight Citations",
        has(&controls, "Switch", "Highlight Citations"),
    );
    let before = cx.update(|cx| {
        cx.global::<AppState>()
            .stores
            .app_settings
            .read(cx)
            .settings()
            .citation_background
    });
    click_in_view(handle, "Switch", "Highlight Citations", cx).await;
    let switched = wait_until(cx, Duration::from_secs(5), move |cx| {
        cx.global::<AppState>()
            .stores
            .app_settings
            .read(cx)
            .settings()
            .citation_background
            != before
    })
    .await;
    pass &= ok("Highlight Citations switches the setting", switched);
    // Back as it was.
    click_in_view(handle, "Switch", "Highlight Citations", cx).await;
    settle(cx, 500).await;

    // Remote Content lists the allowed site; Remove takes it off.
    let nodes = drive::nodes(handle, cx).await;
    let listed = nodes.iter().any(|n| n.label.contains(site_host()))
        || controls.iter().any(|c| c.contains("Remove"));
    pass &= ok("Remote Content lists the allowed site with Remove", listed);
    let mut removed = false;
    let height = cx.update(|cx| {
        handle
            .update(cx, |_, window, _| f32::from(window.viewport_size().height))
            .unwrap_or(600.)
    });
    for _ in 0..12 {
        let nodes = drive::nodes(handle, cx).await;
        let remove = drive::find(&nodes, "Button", |l| l == "Remove")
            .filter(|n| {
                n.bounds
                    .is_some_and(|b| f32::from(b.bottom()) < height - 8.)
            })
            .and_then(drive::Node::center);
        if let Some(at) = remove {
            shoot_both_modes(handle, dir, "media-settings-remote-content", cx).await;
            drive::click(handle, at, cx).await;
            removed = true;
            break;
        }
        // Further down the pane.
        drive::scroll(handle, point(px(420.), px(height / 2.)), 240., cx);
        settle(cx, 300).await;
    }
    let empty = wait_until(cx, Duration::from_secs(5), |cx| {
        cx.global::<AppState>()
            .settings
            .read(cx)
            .prefs
            .remote_image_hosts
            .is_empty()
    })
    .await;
    pass &= ok("Remove takes the site off the list", removed && empty);
    shoot_both_modes(handle, dir, "media-settings-chats-empty", cx).await;
    cx.update(|cx| {
        let _ = handle.update(cx, |_, window, _| window.remove_window());
    });
    pass
}

async fn streaming_diagram(dir: &Path, cx: &mut AsyncApp) -> bool {
    new_chat(cx).await;
    let (r0, p0, f0) = cx.update(|_| drawn_counts());
    send("Draw a diagram of the tide", cx).await;
    let Some((main, _)) = cx.update(main_window) else {
        return ok("the main window is open", false);
    };
    // While the fence is open the transcript draws a Mermaid code block
    // (named "Mermaid code" in English), and nothing is sent to be drawn.
    let code_label = cx.update(|cx| {
        use conduit_components::ActiveStrings as _;
        conduit_components::strings::fill(
            &cx.strings().code_block,
            &[(
                "name",
                &conduit_components::views::markdown::language_name("mermaid"),
            )],
        )
    });
    let deadline = std::time::Instant::now() + Duration::from_secs(40);
    let (mut saw_code, mut drawn_while_open, mut shot) = (false, false, false);
    while std::time::Instant::now() < deadline {
        let streaming = cx.update(|cx| chat_store(cx).is_some_and(|s| s.read(cx).is_streaming()));
        let nodes = drive::nodes(main, cx).await;
        if drive::find(&nodes, "Group", |l| l == code_label).is_some() && streaming {
            saw_code = true;
            let (r, p, f) = cx.update(|_| drawn_counts());
            drawn_while_open |= r + p + f != r0 + p0 + f0;
            if !shot {
                shot = true;
                let mode = cx.update(|cx| {
                    cx.global::<AppState>()
                        .settings
                        .read(cx)
                        .prefs
                        .appearance
                        .mode
                });
                crate::smoke::shoot(
                    main,
                    dir.join(format!(
                        "media-streaming-code-{}.png",
                        crate::smoke::mode_name(mode)
                    )),
                    cx,
                )
                .await;
            }
        }
        if saw_code && !streaming {
            break;
        }
        settle(cx, 150).await;
    }
    let mut pass = ok(
        "while the streamed diagram's fence is open it shows as code",
        saw_code,
    );
    pass &= ok(
        "…and nothing is drawn for it yet",
        saw_code && !drawn_while_open,
    );
    let answered = wait_answer(cx, Duration::from_secs(60)).await;
    pass &= ok("the diagram answer finishes", answered);
    let drawn = wait_until(cx, Duration::from_secs(20), move |_| {
        let (r, _, _) = drawn_counts();
        r > r0
    })
    .await;
    pass &= ok("once the fence closes the diagram is drawn", drawn);
    settle(cx, 500).await;
    shoot_main(dir, "media-streaming-drawn", cx).await;
    // Note the chat for clean-up.
    let id = cx.update(|cx| chat_store(cx).map(|s| s.read(cx).chat_id().to_string()));
    if let Some(id) = id
        && let Ok(mut m) = MADE.lock()
    {
        m.push(id);
    }
    pass
}

async fn live_updates(dir: &Path, cx: &mut AsyncApp) -> bool {
    let health = |cx: &mut App| {
        cx.global::<AppState>()
            .stores
            .app_settings
            .read(cx)
            .health
            .clone()
    };
    let up = wait_until(cx, Duration::from_secs(10), move |cx| {
        health(cx).is_some_and(|h| h.available && h.connected)
    })
    .await;
    let Some((main, _)) = cx.update(main_window) else {
        return ok("the main window is open", false);
    };
    let nodes = drive::nodes(main, cx).await;
    let mut pass = ok(
        "while live updates are connected the toolbar is quiet",
        up && drive::find(&nodes, "Button", |l| {
            l.contains("Live updates disconnected")
        })
        .is_none(),
    );

    // The server goes away: the socket drops.
    let stopped = cx
        .background_executor()
        .spawn(async { owui(&["stop"]) })
        .await;
    pass &= ok("owui.sh stop", stopped);
    let down = wait_until(cx, Duration::from_secs(45), move |cx| {
        health(cx).is_some_and(|h| h.available && !h.connected)
    })
    .await;
    pass &= ok("the realtime socket is reported down", down);
    settle(cx, 3600).await;
    let nodes = drive::nodes(main, cx).await;
    let item = drive::find(&nodes, "Button", |l| {
        l.contains("Live updates disconnected")
    })
    .cloned();
    pass &= ok(
        "Live Updates shows in the toolbar once it has been down a moment",
        item.is_some(),
    );
    if let Some(at) = item.as_ref().and_then(drive::Node::center) {
        drive::click(main, at, cx).await;
        // The pointer off the item, or its tooltip covers the popover.
        drive::unhover(main, cx);
        settle(cx, 500).await;
    }
    let nodes = drive::nodes(main, cx).await;
    pass &= ok(
        "its popover has the details, Retry and Connection Settings…",
        drive::find(&nodes, "Dialog", |l| l == "Live Updates").is_some()
            && drive::find(&nodes, "Button", |l| l == "Retry").is_some()
            && drive::find(&nodes, "Button", |l| l == "Connection Settings…").is_some(),
    );
    shoot_main(dir, "media-live-updates", cx).await;
    // Retry, with the server still away.
    let nodes = drive::nodes(main, cx).await;
    if let Some(at) = drive::find(&nodes, "Button", |l| l == "Retry").and_then(drive::Node::center)
    {
        drive::click(main, at, cx).await;
        drive::unhover(main, cx);
    }
    let failed = wait_until(cx, Duration::from_secs(20), |cx| {
        let s = cx.global::<AppState>().stores.app_settings.read(cx);
        !s.reconnecting && s.reconnect_failed
    })
    .await;
    pass &= ok(
        "Retry with the server away says it is still disconnected",
        failed,
    );
    shoot_main(dir, "media-live-updates-failed", cx).await;

    // The server comes back: the socket reconnects and the item goes.
    let started = cx
        .background_executor()
        .spawn(async { owui(&["start"]) })
        .await;
    pass &= ok("owui.sh start", started);
    let back = wait_until(cx, Duration::from_secs(90), move |cx| {
        health(cx).is_some_and(|h| h.available && h.connected)
    })
    .await;
    pass &= ok("the realtime socket reconnects", back);
    settle(cx, 600).await;
    let nodes = drive::nodes(main, cx).await;
    pass &= ok(
        "…and Live Updates leaves the toolbar",
        drive::find(&nodes, "Button", |l| {
            l.contains("Live updates disconnected")
        })
        .is_none()
            && drive::find(&nodes, "Dialog", |l| l == "Live Updates").is_none(),
    );
    pass
}
