//! `--e2e share`: the Mac's way into Conduit from other apps, on the
//! local Open WebUI and its fake model:
//!
//! * **The Share menu's hand-off**: a share written into this bundle's
//!   inbox exactly as the Share extension writes it (`<uuid>.part`, the
//!   files, `manifest.json`, then the final name), and the link the
//!   extension opens (`conduit://share/<uuid>`) through `on_open_urls`'s
//!   path: a new chat with the message, text and link in the composer and
//!   the files attached and uploaded, nothing sent; the file the extension
//!   left out (over 256 MB) said in a toast; the share marked taken, and the
//!   same link again refused with a toast; then the chat sent, and its
//!   answer.
//! * **The Services menu**: the provider's `askConduit:userData:error:` and
//!   `newChatWithSelection:userData:error:` called as macOS calls them, with
//!   the selection on a pasteboard: Ask Conduit opens Quick Ask with the
//!   text quoted (an unsent quote there stays, and the next ask opens a new
//!   chat; with Quick Ask empty, an ask starts over there), or a new chat when
//!   Quick Ask is off; New Conduit Chat With Selection puts the text in a
//!   new chat as it is; a blank selection does nothing.
//!
//! `share-system` is the same check driven from outside, for a test bundle
//! with the real extension (packaging/macos/share/e2e-system.sh): it signs
//! in, says `SMOKE share-system ready`, and waits for the link to a share
//! the extension staged (the script finishes it as Open in Conduit does,
//! since the sheet takes no keys from outside), delivered by LaunchServices,
//! and for an "Ask Conduit" through NSPerformService.
//!
//! The extension itself (its sheet's content, the sandbox, PlugInKit) is
//! checked by `share/test.sh`, `share/preview.sh` and
//! `share/e2e-system.sh`; this pass covers the app's side of every
//! hand-off.

use std::path::{Path, PathBuf};
use std::time::Duration;

use gpui_kit::{App, AsyncApp, Entity};

use super::chat::{chat_store, in_pane, pane, sign_in, wait_answer, wait_models};
use super::*;
use crate::desktop;
use crate::shell::{services, share_inbox};
use crate::stores::composer::UploadState;
use crate::stores::navigation::Selection;
use crate::views::quick_ask::QuickAskView;

/// What the synthetic share holds (newly invented).
const MESSAGE: &str = "Which of these suits a shady corner?";
const TEXT: &str = "Ferns and hostas like shade.";
const LINK: &str = "https://example.org/garden/shade-plants";
const BIG: &str = "orchard walk.mov";

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

fn quick_ask(cx: &mut App) -> Option<(gpui_kit::AnyWindowHandle, Entity<QuickAskView>)> {
    cx.try_global::<desktop::Desktop>()?.quick_ask.clone()
}

fn quick_text(cx: &mut App) -> Option<String> {
    let (_, view) = quick_ask(cx)?;
    let composer = view.read(cx).composer.clone();
    Some(composer.read(cx).text(cx))
}

/// Names and whether each is uploaded, in order.
fn attachments(cx: &mut App) -> Vec<(String, bool)> {
    pane(cx)
        .map(|p| {
            p.read(cx)
                .composer_store
                .read(cx)
                .attachments
                .iter()
                .map(|a| (a.name.clone(), matches!(a.state, UploadState::Done { .. })))
                .collect()
        })
        .unwrap_or_default()
}

fn clear_composer(cx: &mut AsyncApp) {
    in_pane(cx, |p, window, cx| {
        p.composer.update(cx, |c, cx| c.set_text("", window, cx));
        let store = p.composer_store.clone();
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
    });
}

/// A synthetic 160×100 picture (a green gradient) as a PNG: stored
/// (uncompressed) deflate blocks, so no encoder is needed.
fn synthetic_png() -> Vec<u8> {
    const W: usize = 160;
    const H: usize = 100;
    fn crc32(bytes: &[u8]) -> u32 {
        let mut crc = !0u32;
        for b in bytes {
            crc ^= u32::from(*b);
            for _ in 0..8 {
                crc = if crc & 1 != 0 {
                    (crc >> 1) ^ 0xedb8_8320
                } else {
                    crc >> 1
                };
            }
        }
        !crc
    }
    fn chunk(out: &mut Vec<u8>, kind: &[u8; 4], data: &[u8]) {
        out.extend_from_slice(&(data.len() as u32).to_be_bytes());
        let mut body = kind.to_vec();
        body.extend_from_slice(data);
        out.extend_from_slice(&body);
        out.extend_from_slice(&crc32(&body).to_be_bytes());
    }
    let mut raw = Vec::with_capacity(H * (W * 3 + 1));
    for y in 0..H {
        raw.push(0);
        for x in 0..W {
            raw.extend_from_slice(&[
                (40 + x / 4) as u8,
                (110 + y) as u8,
                (60 + (x + y) / 6) as u8,
            ]);
        }
    }
    let mut zlib = vec![0x78, 0x01];
    for (i, block) in raw.chunks(65_535).enumerate() {
        let last = (i + 1) * 65_535 >= raw.len();
        zlib.push(u8::from(last));
        let len = block.len() as u16;
        zlib.extend_from_slice(&len.to_le_bytes());
        zlib.extend_from_slice(&(!len).to_le_bytes());
        zlib.extend_from_slice(block);
    }
    let (mut a, mut b) = (1u32, 0u32);
    for byte in &raw {
        a = (a + u32::from(*byte)) % 65_521;
        b = (b + a) % 65_521;
    }
    zlib.extend_from_slice(&((b << 16) | a).to_be_bytes());
    let mut png = vec![0x89, b'P', b'N', b'G', 0x0d, 0x0a, 0x1a, 0x0a];
    let mut header = vec![];
    header.extend_from_slice(&(W as u32).to_be_bytes());
    header.extend_from_slice(&(H as u32).to_be_bytes());
    header.extend_from_slice(&[8, 2, 0, 0, 0]);
    chunk(&mut png, b"IHDR", &header);
    chunk(&mut png, b"IDAT", &zlib);
    chunk(&mut png, b"IEND", &[]);
    png
}

/// Writes a share into `root` as the extension does and returns its id.
fn stage_share(root: &Path, id: &str) -> std::io::Result<PathBuf> {
    let part = root.join(format!("{id}.part"));
    let picture = synthetic_png();
    let files: [(&str, &[u8]); 2] = [
        ("shade plan.md", b"# Shady corner\n\n- ferns\n- hostas\n"),
        ("corner.png", &picture),
    ];
    for (i, (name, bytes)) in files.iter().enumerate() {
        let dir = part.join(format!("files/{i}"));
        std::fs::create_dir_all(&dir)?;
        std::fs::write(dir.join(name), bytes)?;
    }
    let manifest = serde_json::json!({
        "version": 1,
        "message": MESSAGE,
        "texts": [TEXT],
        "urls": [LINK],
        "files": [
            {"name": "shade plan.md", "path": "files/0/shade plan.md"},
            {"name": "corner.png", "path": "files/1/corner.png"},
        ],
        "tooLarge": [BIG],
        "tooMany": 0,
    });
    std::fs::write(
        part.join(share_inbox::MANIFEST),
        serde_json::to_vec_pretty(&manifest).unwrap_or_default(),
    )?;
    let entry = root.join(id);
    std::fs::rename(&part, &entry)?;
    Ok(entry)
}

/// A UUID-shaped id from the clock (the E2E needs no randomness crate).
fn share_id() -> String {
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or_default();
    let hex = format!("{:032x}", nanos ^ (u128::from(std::process::id()) << 96));
    format!(
        "{}-{}-4{}-8{}-{}",
        &hex[0..8],
        &hex[8..12],
        &hex[13..16],
        &hex[17..20],
        &hex[20..32]
    )
}

fn open(url: String, cx: &mut AsyncApp) {
    cx.update(|cx| desktop::handle_urls(vec![url], cx));
}

/// Calls the Services provider as the Services menu does.
fn service(message: &str, text: &str, cx: &mut AsyncApp) -> bool {
    let provider = cx.update(|cx| desktop::services_provider(cx));
    match provider {
        Some(p) => {
            services::perform(&p, message, text);
            true
        }
        None => false,
    }
}

pub async fn run(inputs: &E2eInputs, dir: &Path, cx: &mut AsyncApp) -> bool {
    let Some((url, email, password)) = inputs.owui() else {
        return ok(NO_SERVER, false);
    };
    let mut pass = sign_in(&url, &email, &password, cx).await;
    if cx.update(main_window).is_none() {
        return ok("main window", false);
    }
    pass &= ok("models.list answered", wait_models(cx).await);
    settle(cx, 500).await;
    if inputs.scenario == "share-system" {
        return system(dir, cx).await && pass;
    }
    pass &= share_menu(dir, cx).await;
    pass &= services_menu(dir, cx).await;
    pass
}

async fn share_menu(dir: &Path, cx: &mut AsyncApp) -> bool {
    let Some(root) = share_inbox::app_root() else {
        return ok(
            "running from an app bundle (the inbox is named for it)",
            false,
        );
    };
    let id = share_id();
    let entry = match stage_share(&root, &id) {
        Ok(entry) => entry,
        Err(e) => return ok(&format!("the share is staged in the inbox ({e})"), false),
    };
    open(format!("conduit://share/{id}"), cx);
    let want_text = format!("{MESSAGE}\n{TEXT}\n{LINK}");
    let filled = wait_until(cx, Duration::from_secs(8), |cx| {
        matches!(selection(cx), Selection::New { .. })
            && composer_text(cx) == want_text
            && chat_store(cx).is_none()
    })
    .await;
    let mut pass = ok(
        "a share opens a new chat with the message, text and link in the composer, not sent",
        filled,
    );
    // Read now: the toast goes after a few seconds, the upload can take longer.
    let left_out_named = cx.update(|cx| toasts(cx).iter().any(|t| t.contains(BIG)));
    let uploaded = wait_until(cx, Duration::from_secs(30), |cx| {
        let a = attachments(cx);
        a.len() == 2 && a.iter().all(|(_, done)| *done)
    })
    .await;
    let names: Vec<String> = cx.update(attachments).into_iter().map(|a| a.0).collect();
    pass &= ok(
        &format!("its two files are attached and uploaded ({names:?})"),
        uploaded && names == ["shade plan.md", "corner.png"],
    );
    pass &= ok(
        "the file the extension left out is named in a toast",
        left_out_named,
    );
    pass &= ok(
        "the share is marked taken",
        entry.join(share_inbox::TAKEN).exists() && !entry.join(share_inbox::MANIFEST).exists(),
    );
    if let Some((handle, _)) = cx.update(main_window) {
        let controls = ax(handle, "share-new-chat", dir, cx).await;
        pass &= ok(
            "the new chat's controls are labelled (Send, Message)",
            has(&controls, "Button", "Send"),
        );
    }
    shoot_main(dir, "share-new-chat", cx).await;

    // The same link again (a second delivery) attaches nothing.
    open(format!("conduit://share/{id}"), cx);
    let refused = wait_until(cx, Duration::from_secs(5), |cx| {
        toasts(cx).iter().any(|t| t.contains("couldn't be opened"))
    })
    .await;
    pass &= ok(
        "the same share twice is refused with a toast, and nothing more is attached",
        refused && cx.update(attachments).len() == 2,
    );

    // Send it: the files go with the message.
    in_pane(cx, |p, window, cx| {
        p.composer.update(cx, |c, cx| c.submit(window, cx))
    });
    pass &= ok(
        "the shared chat sends, and the answer arrives",
        wait_answer(cx, Duration::from_secs(60)).await,
    );
    let files_sent = cx.update(|cx| {
        chat_store(cx).is_some_and(|s| {
            let s = s.read(cx);
            s.rows()
                .iter()
                .filter_map(|r| s.item(*r))
                .any(|i| i.role == crate::stores::chat::Role::User && i.files.len() == 2)
        })
    });
    pass &= ok("the sent message carries both files", files_sent);
    shoot_main(dir, "share-sent", cx).await;
    pass
}

async fn services_menu(dir: &Path, cx: &mut AsyncApp) -> bool {
    let mut pass = ok(
        "the Services provider was installed at launch",
        cx.update(|cx| desktop::services_provider(cx)).is_some(),
    );
    let settings = cx.update(|cx| cx.global::<AppState>().settings.clone());
    settings.update(cx, |s, cx| s.set_desktop(|d| d.quick_ask = true, cx));
    settle(cx, 300).await;

    // Ask Conduit: Quick Ask, the selection quoted, the caret below it.
    let selected = "Ferns like shade.\n\nHostas too.";
    let quoted = "> Ferns like shade.\n>\n> Hostas too.\n\n";
    service(services::ASK, selected, cx);
    let shown = wait_until(cx, Duration::from_secs(8), |cx| {
        desktop::quick_ask_visible(cx) && quick_text(cx).as_deref() == Some(quoted)
    })
    .await;
    pass &= ok(
        "Ask Conduit opens Quick Ask with the selection quoted",
        shown,
    );
    if let Some((handle, _)) = cx.update(quick_ask) {
        let controls = ax(handle, "share-services-quick-ask", dir, cx).await;
        pass &= ok(
            "Quick Ask's actions are labelled",
            ["New Chat", "Open in Conduit", "Send"]
                .iter()
                .all(|l| has(&controls, "Button", l)),
        );
        cx.update(desktop::show_quick_ask);
        settle(cx, 400).await;
        shoot_both_modes(handle, dir, "share-services-quick-ask", cx).await;
    }
    // A second ask while the first quote still waits there unsent: that
    // draft stays, and the new selection opens in a new chat of its own.
    // (Quick Ask hides as the user goes to another app to select text.)
    cx.update(desktop::hide_quick_ask);
    settle(cx, 400).await;
    clear_composer(cx);
    service(services::ASK, "Moss on a north wall", cx);
    let elsewhere = wait_until(cx, Duration::from_secs(8), |cx| {
        matches!(selection(cx), Selection::New { .. })
            && composer_text(cx) == "> Moss on a north wall\n\n"
    })
    .await;
    pass &= ok(
        "a second Ask Conduit leaves Quick Ask's unsent draft and opens a new chat",
        elsewhere && cx.update(quick_text).as_deref() == Some(quoted),
    );
    // With nothing typed in Quick Ask, an ask starts over there.
    if let Some((handle, view)) = cx.update(quick_ask) {
        let _ = cx.update(|cx| {
            handle.update(cx, |_, window, cx| {
                view.update(cx, |v, cx| v.new_chat(window, cx))
            })
        });
    }
    service(services::ASK, "Lichen on the gate", cx);
    pass &= ok(
        "an Ask Conduit with Quick Ask empty starts over there with its own selection",
        wait_until(cx, Duration::from_secs(5), |cx| {
            desktop::quick_ask_visible(cx)
                && quick_text(cx).as_deref() == Some("> Lichen on the gate\n\n")
        })
        .await,
    );
    cx.update(desktop::hide_quick_ask);
    settle(cx, 400).await;

    // With Quick Ask off: a new chat in the main window, quoted.
    settings.update(cx, |s, cx| s.set_desktop(|d| d.quick_ask = false, cx));
    settle(cx, 300).await;
    clear_composer(cx);
    service(services::ASK, "Ivy on the fence", cx);
    let in_main = wait_until(cx, Duration::from_secs(8), |cx| {
        matches!(selection(cx), Selection::New { .. })
            && composer_text(cx) == "> Ivy on the fence\n\n"
    })
    .await;
    pass &= ok(
        "with Quick Ask off, Ask Conduit opens a new chat with the selection quoted",
        in_main && !cx.update(desktop::quick_ask_visible),
    );
    shoot_main(dir, "share-services-new-chat", cx).await;
    settings.update(cx, |s, cx| s.set_desktop(|d| d.quick_ask = true, cx));

    // New Conduit Chat With Selection: the text as it is.
    clear_composer(cx);
    service(services::NEW_CHAT, "Plant the bulbs in October.", cx);
    pass &= ok(
        "New Conduit Chat With Selection opens a new chat with the selection as it is",
        wait_until(cx, Duration::from_secs(8), |cx| {
            matches!(selection(cx), Selection::New { .. })
                && composer_text(cx) == "Plant the bulbs in October."
        })
        .await,
    );

    // A blank selection does nothing: the chat and its draft (the last
    // selection, still in the composer) stay as they are.
    let before = cx.update(|cx| (selection(cx), composer_text(cx)));
    service(services::NEW_CHAT, "  \n ", cx);
    settle(cx, 600).await;
    pass &= ok(
        "a blank selection changes nothing",
        !before.1.is_empty() && cx.update(|cx| (selection(cx), composer_text(cx))) == before,
    );
    pass
}

/// The bundle check's half (`share/e2e-system.sh`): the link to a share the
/// real extension staged, then "Ask Conduit" through NSPerformService.
async fn system(dir: &Path, cx: &mut AsyncApp) -> bool {
    let marker = std::env::var("CONDUIT_SHARE_MARKER")
        .unwrap_or_else(|_| "Synthetic text from the share driver".into());
    println!("SMOKE share-system ready");
    let filled = wait_until(cx, Duration::from_secs(180), |cx| {
        matches!(selection(cx), Selection::New { .. }) && composer_text(cx).contains(&marker)
    })
    .await;
    let mut pass = ok(
        "the link to a share the extension staged opens a new chat with its text",
        filled,
    );
    let uploaded = wait_until(cx, Duration::from_secs(30), |cx| {
        let a = attachments(cx);
        !a.is_empty() && a.iter().all(|(_, done)| *done)
    })
    .await;
    let names: Vec<String> = cx.update(attachments).into_iter().map(|a| a.0).collect();
    pass &= ok(
        &format!("and its file attached and uploaded ({names:?})"),
        uploaded,
    );
    println!(
        "SMOKE info share-system composer {:?}",
        cx.update(composer_text)
    );
    shoot_main(dir, "share-system-new-chat", cx).await;
    println!("SMOKE share-system shared");
    let asked = wait_until(cx, Duration::from_secs(120), |cx| {
        desktop::quick_ask_visible(cx)
            && quick_text(cx).is_some_and(|t| t.starts_with("> ") && t.contains(&marker))
    })
    .await;
    pass &= ok(
        "Ask Conduit from the Services menu opens Quick Ask with the selection quoted",
        asked,
    );
    if let Some((handle, _)) = cx.update(quick_ask) {
        shoot_both_modes(handle, dir, "share-system-quick-ask", cx).await;
    }
    println!("SMOKE share-system done");
    pass
}
