//! `--e2e mac-extras-2`: more of the Mac integrations, on the local Open
//! WebUI and its fake model.
//!
//! * **Shortcuts:** Send to Conduit, Send Link to Conduit and Send Image to
//!   Conduit, through the Swift intents' own `perform()` as the App Intents
//!   runtime calls them ([`crate::intents::self_test`]): the text in a new
//!   chat's message box; the seeded page read by the server and attached
//!   with the phone's request (and a link the server can't read opening the
//!   chat with the link); an image staged and attached, from a file and from
//!   data; a file that is not an image and one over 20 MB refused in words.
//! * **The Dock menu:** its three items as AppKit has them, in English and in
//!   German, each chosen through AppKit (`sendAction:to:from:`): a new chat,
//!   Quick Ask, a voice call (a quiet stand-in for the microphone).
//! * **The clipboard link** (the widget's Clipboard): copied text and a
//!   copied picture each open a new chat with them; the phone widget's
//!   Camera and Photos links open a new chat.
//! * **Continuity Camera:** the + menu as AppKit shows it (its placeholder or
//!   a device's items in it), the requestor in the main window's responder
//!   chain, and a synthetic photo and scan handed to it through
//!   `readSelectionFromPasteboard:`, attached to the composer.
//! * **`{{USER_LOCATION}}`:** with the account's location setting off, a
//!   prompt template and a system prompt naming it ask nothing; on, both get
//!   the stand-in's position (never CoreLocation: no permission prompt), and
//!   a request that doesn't name it asks nothing.

use std::path::Path;
use std::time::Duration;

use conduit_protocol::{
    AccountSettingsPatch, LocationCommandKind, NoParams, RenderPrompt, methods,
};
use gpui_kit::{App, AsyncApp, ClipboardItem, Image, ImageFormat};
use serde_json::{Value, json};

use super::chat::{chat_store, in_pane, pane, sign_in, wait_answer, wait_models};
use super::intents::{brief, step, succeeded};
use super::*;
use crate::capture::grab;
use crate::desktop;
use crate::l10n::ActiveL10n as _;
use crate::shell::continuity_camera;
use crate::shell::location;
use crate::stores::navigation::Selection;

/// A 1×1 PNG (synthetic).
const PNG: &[u8] = &[
    0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52,
    0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x06, 0x00, 0x00, 0x00, 0x1f, 0x15, 0xc4,
    0x89, 0x00, 0x00, 0x00, 0x0d, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9c, 0x63, 0xf8, 0xcf, 0xc0, 0xf0,
    0x1f, 0x00, 0x05, 0x00, 0x01, 0xff, 0x89, 0x99, 0x3d, 0x1d, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45,
    0x4e, 0x44, 0xae, 0x42, 0x60, 0x82,
];

/// A one-page PDF (synthetic), as a scan comes back.
const PDF: &str = "%PDF-1.4\n1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj\n2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj\n3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 200 100]>>endobj\ntrailer<</Root 1 0 R>>\n%%EOF\n";

/// The stand-in's position, and Open WebUI's form of it.
const FIX: (f64, f64) = (51.50142, -0.14189);
const FIX_TEXT: &str = "51.501, -0.142 (lat, long)";

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

fn attachment_names(cx: &mut App) -> Vec<String> {
    pane(cx)
        .map(|p| {
            let store = p.read(cx).composer_store.clone();
            store
                .read(cx)
                .attachments
                .iter()
                .map(|a| a.name.clone())
                .collect()
        })
        .unwrap_or_default()
}

fn context(cx: &mut App) -> Vec<conduit_protocol::ContextAttachmentDto> {
    pane(cx)
        .map(|p| {
            let store = p.read(cx).composer_store.clone();
            store.read(cx).context.clone()
        })
        .unwrap_or_default()
}

fn error_is(out: &Value, words: &str) -> bool {
    out["ok"].as_bool() == Some(false) && out["error"].as_str() == Some(words)
}

fn value_is(out: &Value, words: &str) -> bool {
    succeeded(out) && out["value"].as_str() == Some(words)
}

/// Opens the newest chat the sidebar lists (seeded): somewhere to leave.
async fn open_a_chat(cx: &mut AsyncApp) -> bool {
    let id = cx.update(|cx| {
        cx.global::<AppState>()
            .stores
            .chat_list
            .read(cx)
            .recent(1)
            .first()
            .map(|c| c.id.clone())
    });
    let Some(id) = id else {
        return false;
    };
    let nav = cx.update(|cx| cx.global::<AppState>().stores.navigation.clone());
    nav.update(cx, |n, cx| n.open(id.clone(), cx));
    wait_until(cx, Duration::from_secs(10), move |cx| {
        selection(cx) == Selection::Chat(id.clone())
    })
    .await
}

/// A new, empty chat in the main window.
async fn fresh_chat(cx: &mut AsyncApp) {
    let nav = cx.update(|cx| cx.global::<AppState>().stores.navigation.clone());
    nav.update(cx, |n, cx| n.new_chat(false, cx));
    settle(cx, 500).await;
    in_pane(cx, |p, window, cx| {
        p.composer.update(cx, |c, cx| c.set_text("", window, cx))
    });
}

pub async fn run(inputs: &E2eInputs, dir: &Path, cx: &mut AsyncApp) -> bool {
    let Some((url, email, password)) = inputs.owui() else {
        return ok(NO_SERVER, false);
    };
    // No test reaches CoreLocation: the stand-in answers (with a position
    // only where this pass gives one).
    pass_mode_is_stand_in();
    // The menus this pass opens (the Dock's, the + menu) are seen as they
    // begin tracking, so the armed closer can end them (once per process).
    grab::install_menu_watch();
    let mut pass = fresh_profile(cx).await;
    pass &= ok("the setup window opened", wait_setup(cx).await.is_some());
    pass &= sign_in(&url, &email, &password, cx).await;
    pass &= ok("models listed", wait_models(cx).await);
    settle(cx, 800).await;

    pass &= shortcuts(inputs, dir, cx).await;
    pass &= dock_menu(dir, cx).await;
    pass &= clipboard(dir, cx).await;
    pass &= continuity_camera_items(inputs, dir, cx).await;
    pass &= user_location(inputs, &url, &email, &password, cx).await;

    let (_, system) = location::counts();
    pass &= ok(
        &format!("CoreLocation was never asked ({system} times)"),
        system == 0 && matches!(location::mode(), location::Mode::StandIn(_)),
    );
    pass
}

fn pass_mode_is_stand_in() {
    let _ = ok(
        "a scripted run answers locations with the stand-in",
        matches!(location::mode(), location::Mode::StandIn(_)),
    );
}

// ── Shortcuts: Send to Conduit, Send Link, Send Image ─────────────────────

async fn shortcuts(inputs: &E2eInputs, dir: &Path, cx: &mut AsyncApp) -> bool {
    let l10n = cx.update(|cx| cx.l10n().clone());
    let mut pass = true;

    let types = step(json!({ "intent": "types" })).await;
    let named = types["named"].as_u64().unwrap_or(0);
    pass &= ok(
        &format!(
            "Metadata.appintents names the three new actions too, all in the binary ({named} named, missing {})",
            types["missing"]
        ),
        succeeded(&types) && named >= 11 && types["missing"].as_array().is_some_and(Vec::is_empty),
    );

    // Send to Conduit.
    let sent = step(json!({ "intent": "sendText", "text": "  Tide times for Port Wren \n" })).await;
    let filled = wait_until(cx, Duration::from_secs(10), |cx| {
        matches!(selection(cx), Selection::New { .. })
            && composer_text(cx) == "Tide times for Port Wren"
            && chat_store(cx).is_none()
    })
    .await;
    pass &= ok(
        &format!(
            "Send to Conduit puts the text, trimmed, in a new chat's message box, unsent ({})",
            brief(&sent)
        ),
        value_is(&sent, &l10n.desktop_intent_sent_text()) && filled,
    );
    let empty = step(json!({ "intent": "sendText", "text": " \n " })).await;
    pass &= ok(
        "Send to Conduit with no text says so",
        error_is(&empty, &l10n.desktop_intent_send_text_empty()),
    );

    // Send Link to Conduit: the seeded page.
    match inputs.get("FAKE_PAGE_URL") {
        Some(page) => {
            fresh_chat(cx).await;
            let linked = step(json!({ "intent": "sendLink", "url": page })).await;
            let request = l10n.desktop_intent_link_prompt_page();
            let attached = wait_until(cx, Duration::from_secs(20), {
                let request = request.clone();
                move |cx| {
                    composer_text(cx) == request
                        && context(cx).iter().any(|c| {
                            c.kind == conduit_protocol::ContextAttachmentKind::Web
                                && c.content
                                    .as_deref()
                                    .is_some_and(|t| t.contains("raised bed"))
                        })
                }
            })
            .await;
            pass &= ok(
                &format!(
                    "Send Link attaches the page the server read, with the phone's request ({})",
                    brief(&linked)
                ),
                value_is(&linked, &l10n.desktop_intent_sent_page()) && attached,
            );
            settle(cx, 700).await;
            shoot_main(dir, "x4-send-link", cx).await;

            // A link the server can't read (nothing listens on port 9): the
            // chat opens with the link.
            let missing = "http://127.0.0.1:9/x4-unreadable".to_string();
            fresh_chat(cx).await;
            let unread = step(json!({ "intent": "sendLink", "url": missing })).await;
            let want = format!("{request} {missing}");
            let opened = wait_until(cx, Duration::from_secs(20), move |cx| {
                composer_text(cx) == want && context(cx).is_empty()
            })
            .await;
            pass &= ok(
                &format!(
                    "Send Link with a page that can't be read opens the chat with the link ({})",
                    brief(&unread)
                ),
                value_is(&unread, &l10n.desktop_intent_sent_link_unread()) && opened,
            );
        }
        None => pass &= ok("FAKE_PAGE_URL in the env file", false),
    }

    // Send Image to Conduit: from a file, and from data.
    let png = dir.join("x4-tide-chart.png");
    let _ = std::fs::write(&png, PNG);
    fresh_chat(cx).await;
    let image = step(json!({
        "intent": "sendImage",
        "path": png.to_string_lossy(),
        "filename": "tide-chart.png",
        "type": "public.png",
    }))
    .await;
    let attached = wait_until(cx, Duration::from_secs(15), |cx| {
        attachment_names(cx) == ["tide-chart.png"]
    })
    .await;
    pass &= ok(
        &format!(
            "Send Image attaches the image to a new chat ({})",
            brief(&image)
        ),
        value_is(&image, &l10n.desktop_intent_sent_image()) && attached,
    );
    settle(cx, 900).await;
    shoot_main(dir, "x4-send-image", cx).await;
    fresh_chat(cx).await;
    let data = step(json!({
        "intent": "sendImage",
        "path": png.to_string_lossy(),
        "filename": "harbour.png",
        "type": "public.png",
        "inMemory": true,
    }))
    .await;
    pass &= ok(
        &format!("…and an image given as data, not a file ({})", brief(&data)),
        value_is(&data, &l10n.desktop_intent_sent_image())
            && wait_until(cx, Duration::from_secs(15), |cx| {
                attachment_names(cx) == ["harbour.png"]
            })
            .await,
    );
    // A typed image whose name has no extension keeps its kind.
    fresh_chat(cx).await;
    let unnamed = step(json!({
        "intent": "sendImage",
        "path": png.to_string_lossy(),
        "filename": "Chart",
        "type": "public.png",
        "inMemory": true,
    }))
    .await;
    pass &= ok(
        &format!(
            "…and a typed image named without an extension is staged as one ({})",
            brief(&unnamed)
        ),
        value_is(&unnamed, &l10n.desktop_intent_sent_image())
            && wait_until(cx, Duration::from_secs(15), |cx| {
                attachment_names(cx) == ["Chart.png"]
            })
            .await,
    );
    let text_file = dir.join("x4-notes.txt");
    let _ = std::fs::write(&text_file, "Not a picture.");
    let not_image = step(json!({
        "intent": "sendImage",
        "path": text_file.to_string_lossy(),
        "filename": "notes.txt",
        "type": "public.plain-text",
    }))
    .await;
    pass &= ok(
        "Send Image refuses a file that is not an image",
        error_is(&not_image, &l10n.desktop_intent_send_image_not_image()),
    );
    // A file named and left untyped as a picture is still read: not one.
    let renamed = step(json!({
        "intent": "sendImage",
        "path": text_file.to_string_lossy(),
        "filename": "notes.png",
    }))
    .await;
    pass &= ok(
        "Send Image refuses a renamed file that is not an image",
        error_is(&renamed, &l10n.desktop_intent_send_image_not_image()),
    );
    let big = dir.join("x4-big.png");
    let sized = std::fs::File::create(&big)
        .and_then(|f| f.set_len(crate::intents::MAX_IMAGE_BYTES + 1))
        .is_ok();
    let too_large = step(json!({
        "intent": "sendImage",
        "path": big.to_string_lossy(),
        "filename": "big.png",
        "type": "public.png",
    }))
    .await;
    pass &= ok(
        "Send Image refuses an image over 20 MB",
        sized && error_is(&too_large, &l10n.desktop_intent_send_image_too_large()),
    );
    let _ = std::fs::remove_file(&big);
    pass
}

// ── The Dock menu ──────────────────────────────────────────────────────────

/// The Dock menu as the Dock asks for it (`applicationDockMenu:`).
fn app_dock_menu() -> Option<objc2::rc::Retained<objc2::runtime::AnyObject>> {
    use objc2::msg_send;
    use objc2::runtime::AnyObject;
    let mtm = objc2::MainThreadMarker::new()?;
    let app = objc2_app_kit::NSApplication::sharedApplication(mtm);
    // SAFETY: AppKit calls on the main thread; GPUI's delegate answers.
    unsafe {
        let delegate: *mut AnyObject = msg_send![&*app, delegate];
        if delegate.is_null() {
            return None;
        }
        let menu: *mut AnyObject = msg_send![delegate, applicationDockMenu: &*app];
        objc2::rc::Retained::retain(menu)
    }
}

fn menu_titles(menu: &objc2::runtime::AnyObject) -> Vec<String> {
    use objc2::msg_send;
    use objc2::runtime::AnyObject;
    use objc2_foundation::NSString;
    let mut titles = vec![];
    // SAFETY: NSMenu reads on the main thread.
    unsafe {
        let count: isize = msg_send![menu, numberOfItems];
        for i in 0..count {
            let item: *mut AnyObject = msg_send![menu, itemAtIndex: i];
            let title: *mut NSString = msg_send![item, title];
            titles.push(title.as_ref().map(|t| t.to_string()).unwrap_or_default());
        }
    }
    titles
}

/// Chooses item `index` as the Dock does: its action, sent to its target.
fn choose(menu: &objc2::runtime::AnyObject, index: isize) -> bool {
    use objc2::msg_send;
    use objc2::runtime::{AnyObject, Bool, Sel};
    let Some(mtm) = objc2::MainThreadMarker::new() else {
        return false;
    };
    let app = objc2_app_kit::NSApplication::sharedApplication(mtm);
    // SAFETY: AppKit calls on the main thread, outside any GPUI borrow.
    unsafe {
        let item: *mut AnyObject = msg_send![menu, itemAtIndex: index];
        if item.is_null() {
            return false;
        }
        let action: Option<Sel> = msg_send![item, action];
        let target: *mut AnyObject = msg_send![item, target];
        let Some(action) = action else {
            return false;
        };
        let sent: Bool = msg_send![&*app, sendAction: action, to: target, from: item];
        sent.as_bool()
    }
}

async fn dock_menu(dir: &Path, cx: &mut AsyncApp) -> bool {
    let mut pass = true;
    let en = crate::l10n::L10n::new("en");
    let want = |l: &crate::l10n::L10n| {
        vec![
            l.new_chat(),
            l.voice_call_title(),
            l.desktop_tray_quick_ask(),
        ]
    };
    let Some(menu) = app_dock_menu() else {
        return ok("the app has a Dock menu", false);
    };
    pass &= ok(
        &format!("the Dock menu lists {:?}", menu_titles(&menu)),
        menu_titles(&menu) == want(&en),
    );
    // In the app's language.
    let settings = cx.update(|cx| cx.global::<AppState>().settings.clone());
    cx.update(|cx| settings.update(cx, |s, cx| s.set_locale(Some("de".into()), cx)));
    settle(cx, 500).await;
    let de = crate::l10n::L10n::new("de");
    let german = app_dock_menu().map(|m| menu_titles(&m)).unwrap_or_default();
    pass &= ok(
        &format!("…in the app's language ({german:?})"),
        german == want(&de),
    );
    cx.update(|cx| settings.update(cx, |s, cx| s.set_locale(None, cx)));
    settle(cx, 500).await;
    let Some(menu) = app_dock_menu() else {
        return ok("the Dock menu is back in English", false);
    };
    pass &= ok("…and back in English", menu_titles(&menu) == want(&en));
    shoot_menu(&menu, dir, "x4-dock-menu", cx).await;

    // New Chat, from a chat that is open.
    pass &= ok("a chat is open", open_a_chat(cx).await);
    pass &= ok("the Dock's New Chat is chosen", choose(&menu, 0));
    let fresh = wait_until(cx, Duration::from_secs(10), |cx| {
        matches!(selection(cx), Selection::New { .. }) && desktop::main_visible(cx)
    })
    .await;
    pass &= ok("…a new chat in the main window", fresh);

    // Quick Ask.
    pass &= ok("the Dock's Quick Ask is chosen", choose(&menu, 2));
    let shown = wait_until(cx, Duration::from_secs(5), desktop::quick_ask_visible).await;
    pass &= ok("…the Quick Ask panel", shown);
    cx.update(desktop::hide_quick_ask);
    settle(cx, 400).await;

    // Voice Call: a quiet stand-in first (never the Mac's microphone).
    pass &= ok(
        "a quiet stand-in for the call's microphone",
        super::voice_call::prepare_quiet_call(dir, cx).await,
    );
    pass &= ok("the Dock's Voice Call is chosen", choose(&menu, 1));
    let on = wait_until(cx, Duration::from_secs(20), |cx| {
        super::voice_call::call_on(cx).is_some()
    })
    .await;
    pass &= ok(
        "…a voice call in a new chat",
        on && matches!(cx.update(selection), Selection::New { .. }),
    );
    pass &= ok("the call ends", super::voice_call::end_call(cx).await);
    pass
}

/// Shows `menu` (an NSMenu) over the main window, light then dark, and
/// keeps each as a shot; closes it without choosing anything.
async fn shoot_menu(menu: &objc2::runtime::AnyObject, dir: &Path, name: &str, cx: &mut AsyncApp) {
    use objc2::msg_send;
    use objc2::runtime::{AnyObject, Bool};
    let Some((handle, _)) = cx.update(main_window) else {
        return;
    };
    let Some(ns) = cx.update(|cx| crate::smoke::ns_window(handle, cx)) else {
        return;
    };
    for dark in [false, true] {
        let out = dir.join(format!(
            "{name}-{}.png",
            if dark { "dark" } else { "light" }
        ));
        grab::force_menu_appearance(Some(dark));
        let rx = menu_shot_thread(out);
        grab::arm_menu_closer(Duration::from_secs(6));
        if let Some(view) = ns.contentView() {
            let height = view.bounds().size.height;
            let location = objc2_foundation::NSPoint::new(80.0, height - 120.0);
            // SAFETY: AppKit's tracking loop on the main thread, outside
            // any GPUI borrow; the closer ends it.
            unsafe {
                let _: Bool = msg_send![
                    menu,
                    popUpMenuPositioningItem: std::ptr::null_mut::<AnyObject>(),
                    atLocation: location,
                    inView: &*view
                ];
            }
        }
        let shot = rx.recv_timeout(Duration::from_secs(8)).ok().flatten();
        let _ = ok(
            &format!("{name} shot ({})", if dark { "dark" } else { "light" }),
            shot.is_some(),
        );
        grab::force_menu_appearance(None);
        settle(cx, 300).await;
    }
}

/// A thread that waits for one of the app's menus to be open, keeps a shot
/// of it at `out`, and asks the armed closer to end it.
fn menu_shot_thread(out: std::path::PathBuf) -> std::sync::mpsc::Receiver<Option<()>> {
    let (tx, rx) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let deadline = std::time::Instant::now() + Duration::from_secs(5);
        loop {
            if let Some(menu) = grab::open_menus().first().copied() {
                // Past the menu's fade-in (and any items AppKit adds).
                std::thread::sleep(Duration::from_millis(450));
                let menu = grab::open_menus().first().copied().unwrap_or(menu);
                let shot =
                    crate::capture::grab::Frame::of_rect(grab::inset(menu.bounds, 24.0), true)
                        .and_then(|f| f.write_png(&out).ok())
                        .map(|_| ());
                grab::request_menu_close();
                let _ = tx.send(shot);
                return;
            }
            if std::time::Instant::now() > deadline {
                grab::request_menu_close();
                let _ = tx.send(None);
                return;
            }
            std::thread::sleep(Duration::from_millis(30));
        }
    });
    rx
}

// ── The clipboard link (the widget's Clipboard) ────────────────────────────

async fn clipboard(dir: &Path, cx: &mut AsyncApp) -> bool {
    let mut pass = true;
    // Only what this pass copied is read back (never anything another app
    // put there).
    cx.update(|cx| {
        cx.write_to_clipboard(ClipboardItem::new_string(
            "  Packing list for the ferry \n".into(),
        ))
    });
    shell_links(&["conduit://clipboard"], cx);
    let text = wait_until(cx, Duration::from_secs(10), |cx| {
        matches!(selection(cx), Selection::New { .. })
            && composer_text(cx) == "Packing list for the ferry"
    })
    .await;
    pass &= ok(
        "conduit://clipboard opens a new chat with the copied text",
        text,
    );
    settle(cx, 600).await;
    shoot_main(dir, "x4-clipboard-text", cx).await;

    let picture = Image::from_bytes(ImageFormat::Png, PNG.to_vec());
    cx.update(|cx| cx.write_to_clipboard(ClipboardItem::new_image(&picture)));
    shell_links(&["conduit://clipboard?homeWidget=true"], cx);
    // A new chat that starts empty, as the phone's widget resets it; a
    // copied picture is never attached (or uploaded) from a link.
    let empty = wait_until(cx, Duration::from_secs(10), |cx| {
        composer_text(cx).is_empty() && attachment_names(cx).is_empty()
    })
    .await;
    settle(cx, 600).await;
    pass &= ok(
        &format!(
            "…and a copied picture is left on the clipboard, not attached ({:?})",
            cx.update(attachment_names)
        ),
        empty && cx.update(attachment_names).is_empty(),
    );
    // Leave synthetic text on the clipboard, not a picture.
    cx.update(|cx| cx.write_to_clipboard(ClipboardItem::new_string("Conduit".into())));

    for link in ["conduit://camera?homeWidget=true", "conduit://photos"] {
        pass &= ok("a chat is open", open_a_chat(cx).await);
        shell_links(&[link], cx);
        let opened = wait_until(cx, Duration::from_secs(10), |cx| {
            matches!(selection(cx), Selection::New { .. })
        })
        .await;
        pass &= ok(&format!("{link} opens a new chat"), opened);
    }
    pass
}

// ── Continuity Camera in the + menu ────────────────────────────────────────

/// A personal tool server on the fake model server, added as the
/// Integrations pane adds one: the + menu's Tools list then offers it.
const BUOYS: &str = "Harbour buoys";

async fn add_personal_tool_server(inputs: &E2eInputs, cx: &mut AsyncApp) -> bool {
    use conduit_protocol::{
        PersonalConnectionDraft, PersonalConnectionSave, PersonalEditOp, PersonalKind,
    };
    let base = inputs
        .get("FAKE_OPENAI_URL")
        .map(|u| u.trim_end_matches('/').trim_end_matches("/v1").to_string())
        .unwrap_or_default();
    let rpc = cx.update(|cx| cx.global::<AppState>().stores.connection.read(cx).rpc());
    let Ok(list) = rpc.call::<methods::IntegrationsList>(&NoParams).await else {
        return ok("the account's personal connections are read", false);
    };
    let saved = rpc
        .call::<methods::IntegrationsSave>(&PersonalConnectionSave {
            owner: list.owner,
            kind: PersonalKind::ToolServer,
            op: PersonalEditOp::Add,
            identity: None,
            draft: Some(PersonalConnectionDraft {
                name: BUOYS.into(),
                description: "Invented buoy readings".into(),
                url: format!("{base}/personal"),
                // A new tool server's draft, as the editor fills it.
                path: "openapi.json".into(),
                auth_type: "none".into(),
                ..Default::default()
            }),
            enabled: None,
            fingerprint: None,
        })
        .await;
    ok(
        &format!(
            "a personal tool server is added ({:?})",
            saved.as_ref().err()
        ),
        saved.is_ok(),
    )
}

/// The + menu as AppKit had it (`grab::take_menu_items`), as the
/// composer's rows: titles, `—` for a separator; without check marks, key
/// equivalents, "(disabled)" or submenu marks, and without Continuity
/// Camera's placeholder.
fn menu_titles_as_rows(items: &[String]) -> Vec<String> {
    items
        .iter()
        .filter(|i| !i.starts_with('['))
        .map(|i| {
            let i = i.strip_prefix("\u{2713} ").unwrap_or(i);
            let i = i.strip_suffix(" \u{25b8}").unwrap_or(i);
            let i = i.strip_suffix(" (disabled)").unwrap_or(i);
            i.split("  [").next().unwrap_or(i).to_string()
        })
        .collect()
}

async fn continuity_camera_items(inputs: &E2eInputs, dir: &Path, cx: &mut AsyncApp) -> bool {
    let mut pass = add_personal_tool_server(inputs, cx).await;
    fresh_chat(cx).await;
    // As the Integrations pane does after a change: the composer reads its
    // tools again.
    in_pane(cx, |p, _, cx| {
        p.composer_store.update(cx, |c, cx| c.refresh_options(cx))
    });
    // The Terminal section's servers (the Build box), as the sidebar's
    // Terminal section reads them.
    cx.update(|cx| {
        let areas = cx.global::<AppState>().stores.areas.clone();
        areas.update(cx, |a, cx| {
            a.refresh(crate::stores::navigation::Area::Terminal, cx)
        });
    });
    let ready = wait_until(cx, Duration::from_secs(20), |cx| {
        let terminals = cx
            .global::<AppState>()
            .stores
            .areas
            .read(cx)
            .terminals
            .as_ref()
            .is_some_and(|t| !t.is_empty());
        let buoys = pane(cx).is_some_and(|p| {
            p.read(cx)
                .composer_store
                .read(cx)
                .options
                .tools
                .iter()
                .any(|t| t.name == BUOYS)
        });
        terminals && buoys
    })
    .await;
    pass &= ok(
        "the composer has the terminals and the personal tool server",
        ready,
    );
    settle(cx, 600).await;
    let Some((handle, _)) = cx.update(main_window) else {
        return ok("the main window", false);
    };
    let mut items = vec![];
    for dark in [false, true] {
        let out = dir.join(format!(
            "x4-plus-menu-{}.png",
            if dark { "dark" } else { "light" }
        ));
        cx.update(|cx| {
            crate::smoke::set_mode(
                if dark {
                    crate::prefs::ThemeMode::Dark
                } else {
                    crate::prefs::ThemeMode::Light
                },
                cx,
            )
        });
        settle(cx, 400).await;
        grab::force_menu_appearance(Some(dark));
        let rx = menu_shot_thread(out);
        grab::arm_menu_closer(Duration::from_secs(6));
        in_pane(cx, |p, window, cx| {
            p.composer.update(cx, |c, cx| {
                c.show_plus_menu(
                    gpui_kit::point(gpui_kit::px(40.), gpui_kit::px(600.)),
                    window,
                    cx,
                )
            })
        });
        // The menu runs in a task: wait for its shot (the closer ends it).
        let mut shot = None;
        for _ in 0..400 {
            if let Ok(s) = rx.try_recv() {
                shot = Some(s.is_some());
                break;
            }
            settle(cx, 20).await;
        }
        settle(cx, 400).await;
        grab::force_menu_appearance(None);
        let _ = ok(
            &format!("the + menu shot ({})", if dark { "dark" } else { "light" }),
            shot == Some(true),
        );
        items = grab::take_menu_items();
    }
    cx.update(|cx| crate::smoke::set_mode(crate::prefs::ThemeMode::Light, cx));
    println!("SMOKE note: the + menu as AppKit had it: {items:?}");
    // Every row the composer has (the Kit menu's) is in
    // the menu AppKit showed, in order: none dropped by the app-built menu.
    let rows: Vec<String> = in_pane(cx, |p, window, cx| {
        p.composer.update(cx, |c, cx| {
            c.plus_rows(window, cx)
                .into_iter()
                .filter_map(|r| match r {
                    crate::views::chat::composer::PlusRow::Item { label, .. } => Some(label),
                    crate::views::chat::composer::PlusRow::Separator => {
                        Some("\u{2014}".to_string())
                    }
                    crate::views::chat::composer::PlusRow::ImportFromDevice => None,
                })
                .collect()
        })
    })
    .unwrap_or_default();
    let shown = menu_titles_as_rows(&items);
    pass &= ok(
        &format!(
            "the + menu AppKit shows has every row of the composer's ({} rows)",
            rows.len()
        ),
        !rows.is_empty() && shown == rows,
    );
    if shown != rows {
        println!("SMOKE note: the composer's rows: {rows:?}");
    }
    let l10n = cx.update(|cx| cx.l10n().clone());
    let ellipsis = |s: String| format!("{s}\u{2026}");
    for (what, label) in [
        ("Attach Files…", ellipsis(l10n.desktop_attach_files())),
        (
            "Attach Server Files…",
            ellipsis(l10n.composer_attach_server_files()),
        ),
        ("Web Page…", ellipsis(l10n.web_page())),
        ("the Tools heading", l10n.tools()),
        ("the personal tool server", BUOYS.to_string()),
        ("the Terminal heading", l10n.terminal()),
        ("the Build box terminal", "Build box".to_string()),
    ] {
        pass &= ok(
            &format!("the + menu offers {what}"),
            shown.iter().any(|i| i == &label),
        );
    }
    let l10n = cx.update(|cx| cx.l10n().clone());
    let attach = format!("{}\u{2026}", l10n.desktop_attach_files());
    pass &= ok(
        "the + menu the app builds has its entries (Attach Files… first)",
        items.first() == Some(&attach),
    );
    // A context menu: AppKit adds a nearby device's items (Take Photo,
    // Scan Documents…) itself, and nothing with none near; the app adds no
    // placeholder of its own. (A nearby iPhone is checked before release.)
    let placeholder = items.iter().any(|i| i.contains("ImportFromDevice"));
    pass &= ok(
        "…and no Continuity Camera placeholder of the app's own (AppKit adds a device's items)",
        !placeholder,
    );

    let ns = cx.update(|cx| crate::smoke::ns_window(handle, cx));
    if let Some(w) = &ns {
        println!(
            "SMOKE note: the main window's responder chain: {:?}",
            continuity_camera::chain(w)
        );
    }
    // The menu has closed: the requestor no longer answers (a Services
    // request outside the menu brings nothing into the composer).
    let closed = ns
        .as_ref()
        .is_some_and(|w| !continuity_camera::requestor_in_chain(w, "public.jpeg"));
    pass &= ok(
        "the requestor answers only while the + menu is open",
        closed && !continuity_camera::accepting(),
    );
    // As while the menu is open, for the chain and delivery checks.
    continuity_camera::set_accepting(true);
    let chained = ns
        .as_ref()
        .is_some_and(|w| continuity_camera::requestor_in_chain(w, "public.jpeg"));
    let pdf = ns
        .as_ref()
        .is_some_and(|w| continuity_camera::requestor_in_chain(w, "com.adobe.pdf"));
    let not_text = ns
        .as_ref()
        .is_some_and(|w| !continuity_camera::requestor_in_chain(w, "public.utf8-plain-text"));
    continuity_camera::set_accepting(false);
    pass &= ok(
        "the main window's responder chain offers the requestor for photos and scans, not text",
        chained && pdf && not_text,
    );

    let before = cx.update(attachment_names).len();
    pass &= ok(
        "a photo handed to the requestor is read",
        continuity_camera::deliver("public.png", PNG),
    );
    let photo = wait_until(cx, Duration::from_secs(10), |cx| {
        attachment_names(cx).iter().any(|n| n == "Photo.png")
    })
    .await;
    pass &= ok("…and attached to the composer as Photo.png", photo);
    pass &= ok(
        "a scan handed to the requestor is read",
        continuity_camera::deliver("com.adobe.pdf", PDF.as_bytes()),
    );
    let scan = wait_until(cx, Duration::from_secs(10), |cx| {
        attachment_names(cx).iter().any(|n| n == "Scan.pdf")
    })
    .await;
    pass &= ok("…and attached as Scan.pdf", scan);
    pass &= ok(
        "text is not taken",
        !continuity_camera::deliver("public.utf8-plain-text", b"Not a photo"),
    );
    pass &= ok(
        "two attachments came",
        cx.update(attachment_names).len() == before + 2,
    );
    settle(cx, 900).await;
    shoot_main(dir, "x4-continuity-attached", cx).await;
    pass
}

// ── {{USER_LOCATION}} ──────────────────────────────────────────────────────

/// The fake model's newest streamed request.
fn last_request(log: &Path) -> Option<Value> {
    let text = std::fs::read_to_string(log).ok()?;
    text.lines()
        .rev()
        .filter_map(|l| serde_json::from_str::<Value>(l).ok())
        .find(|v| v.get("stream").and_then(Value::as_bool) == Some(true))
}

fn system_text(request: &Option<Value>) -> String {
    request
        .as_ref()
        .and_then(|r| r.get("system"))
        .and_then(Value::as_array)
        .map(|a| {
            a.iter()
                .filter_map(Value::as_str)
                .collect::<Vec<_>>()
                .join("\n")
        })
        .unwrap_or_default()
}

/// Sends `text` in a new chat and returns its request as the fake model
/// logged it.
async fn turn(text: &str, log: &Path, cx: &mut AsyncApp) -> Option<Value> {
    fresh_chat(cx).await;
    let before = std::fs::read_to_string(log).map(|t| t.len()).unwrap_or(0);
    super::chat::send(text, cx).await;
    wait_answer(cx, Duration::from_secs(60)).await;
    for _ in 0..40 {
        let grown = std::fs::read_to_string(log).map(|t| t.len()).unwrap_or(0) > before;
        let request = last_request(log);
        let ours = request
            .as_ref()
            .and_then(|r| r.get("user"))
            .and_then(Value::as_str)
            .is_some_and(|u| u.contains(text));
        if grown && ours {
            return request;
        }
        settle(cx, 250).await;
    }
    None
}

fn asked(cx: &mut App) -> Vec<LocationCommandKind> {
    cx.global::<AppState>()
        .stores
        .location
        .read(cx)
        .asked
        .clone()
}

/// The synthetic account's bearer token, from the local Open WebUI.
fn owui_token(url: &str, email: &str, password: &str) -> Option<String> {
    let body = json!({ "email": email, "password": password }).to_string();
    let (status, text) = super::direct::http_request(
        "POST",
        &format!("{}/api/v1/auths/signin", url.trim_end_matches('/')),
        None,
        Some(&body),
    )?;
    (status == 200)
        .then(|| serde_json::from_str::<Value>(&text).ok())
        .flatten()?
        .get("token")?
        .as_str()
        .map(str::to_string)
}

/// Turns the account's `userLocation` setting (Open WebUI's "Allow User
/// Location", which the phone honours) on or off, keeping its other
/// settings.
fn set_user_location(url: &str, token: &str, on: bool) -> bool {
    let base = url.trim_end_matches('/');
    let current = super::direct::http_request(
        "GET",
        &format!("{base}/api/v1/users/user/settings"),
        Some(token),
        None,
    )
    .and_then(|(_, text)| serde_json::from_str::<Value>(&text).ok())
    .filter(Value::is_object)
    .unwrap_or_else(|| json!({}));
    let mut settings = current;
    if !settings.get("ui").is_some_and(Value::is_object) {
        settings["ui"] = json!({});
    }
    settings["ui"]["userLocation"] = json!(on);
    super::direct::http_request(
        "POST",
        &format!("{base}/api/v1/users/user/settings/update"),
        Some(token),
        Some(&settings.to_string()),
    )
    .is_some_and(|(status, _)| status == 200)
}

async fn user_location(
    inputs: &E2eInputs,
    url: &str,
    email: &str,
    password: &str,
    cx: &mut AsyncApp,
) -> bool {
    let Some(log) = inputs.get("FAKE_MODEL_LOG").map(std::path::PathBuf::from) else {
        return ok("FAKE_MODEL_LOG in the env file", false);
    };
    let Some(token) = owui_token(url, email, password) else {
        return ok("a token for the synthetic account", false);
    };
    let mut pass = true;
    location::set_mode(location::Mode::StandIn(Some(FIX)));
    let rpc = cx.update(|cx| cx.global::<AppState>().stores.connection.read(cx).rpc());

    // A prompt template naming the variable (synthetic).
    let base = url.trim_end_matches('/');
    let created = super::direct::http_request(
        "POST",
        &format!("{base}/api/v1/prompts/create"),
        Some(&token),
        Some(
            &json!({
                "command": "x4-nearby",
                "name": "Nearby walk",
                "content": "Suggest a walk near {{USER_LOCATION}}.",
                "commit_message": "First version",
            })
            .to_string(),
        ),
    )
    .is_some_and(|(status, _)| status == 200);
    pass &= ok(
        "a prompt that names {{USER_LOCATION}} is on the server",
        created,
    );
    let listed = rpc.call::<methods::PromptsList>(&NoParams).await;
    let command = listed
        .ok()
        .and_then(|l| {
            l.prompts
                .into_iter()
                .find(|p| p.command.contains("x4-nearby"))
        })
        .map(|p| p.command);
    let render = |command: Option<String>| {
        let rpc = rpc.clone();
        async move {
            let command = command?;
            rpc.call::<methods::PromptsRender>(&RenderPrompt {
                command,
                values: Default::default(),
                clipboard: None,
            })
            .await
            .ok()
            .map(|r| r.content)
        }
    };

    // Off (the account's setting, as seeded): nothing is asked.
    pass &= ok(
        "the account's location setting is off",
        set_user_location(url, &token, false),
    );
    let (stand_in_before, _) = location::counts();
    let off = render(command.clone()).await;
    pass &= ok(
        &format!("with it off, the template gets LOCATION_UNKNOWN ({off:?})"),
        off.as_deref() == Some("Suggest a walk near LOCATION_UNKNOWN."),
    );
    let system_prompt = |text: &str| AccountSettingsPatch {
        system_prompt: Some(text.to_string()),
    };
    let _ = rpc
        .call::<methods::SettingsSetAccount>(&system_prompt("Walks start near {{USER_LOCATION}}."))
        .await;
    let request = turn("Reply with the word: compass", &log, cx).await;
    pass &= ok(
        &format!(
            "…and a request whose system prompt names it gets Open WebUI's Unknown ({:?})",
            system_text(&request)
        ),
        system_text(&request).contains("Walks start near Unknown."),
    );
    pass &= ok(
        "…and the Mac's location was never asked",
        location::counts().0 == stand_in_before && cx.update(asked).is_empty(),
    );

    // On: both get the position.
    pass &= ok(
        "the account's location setting is on",
        set_user_location(url, &token, true),
    );
    let on = render(command.clone()).await;
    pass &= ok(
        &format!("with it on, the template gets the position ({on:?})"),
        on.as_deref() == Some(&format!("Suggest a walk near {FIX_TEXT}.")),
    );
    let request = turn("Reply with the word: lantern", &log, cx).await;
    pass &= ok(
        &format!(
            "…and so does the request whose system prompt names it ({:?})",
            system_text(&request)
        ),
        system_text(&request).contains(&format!("Walks start near {FIX_TEXT}.")),
    );
    let after = cx.update(asked);
    pass &= ok(
        &format!("…from the window's stand-in ({after:?})"),
        after.contains(&LocationCommandKind::CurrentPosition)
            && location::counts().0 > stand_in_before,
    );

    // On, but nothing names it: nothing is asked.
    let _ = rpc
        .call::<methods::SettingsSetAccount>(&system_prompt(""))
        .await;
    let before = cx.update(asked).len();
    let plain = turn("Reply with the word: tiller", &log, cx).await;
    pass &= ok(
        "a request that names no {{USER_LOCATION}} asks nothing",
        plain.is_some() && cx.update(asked).len() == before,
    );
    let _ = set_user_location(url, &token, false);
    location::set_mode(location::Mode::StandIn(None));
    pass
}
