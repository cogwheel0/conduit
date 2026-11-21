//! `--e2e apps-leftovers`: the apps' last pieces against the local
//! Open WebUI and its fake Open Terminal.
//!
//! * **Workspace models:** a new model's Terminal ID and Built-In Tools
//!   (JSON; a bad object is refused with its error), saved and read back
//!   from the server. Its picture: one on the server loads through the
//!   daemon's `/files`; one on another site (the synthetic media site, on
//!   this Mac's network address) waits behind Load Image, as an answer's
//!   pictures do: nothing is fetched until it, then once; one from a site
//!   in Remote Content loads without a click.
//! * **Knowledge:** Attach Server File… opens the composer's picker in a
//!   sheet; the seeded file picked goes into the base.
//! * **Notes:** a recording added to a note plays in the note: Play,
//!   Pause, seeking on the scrubber, the end.
//! * **Terminal:** a model's `display_file` for a PDF with a page opens
//!   PDFKit's viewer at that page; a port preview's live-reload WebSocket
//!   passes the daemon's preview listener (a personal terminal straight to
//!   the fake Open Terminal: Open WebUI's own proxy takes no WebSockets);
//!   skipped, with a line saying so, on a server that moved personal
//!   terminals into Tether (Open WebUI 0.13.4).
//!
//! Every new element is shot in light and dark.

use std::path::Path;
use std::time::Duration;

use conduit_protocol::{
    ChatRef, NoParams, NoteRecordingAdd, PersonalConnectionDraft, PersonalConnectionSave,
    PersonalEditOp, PersonalKeyMode, PersonalKind, WorkspaceDetail, WorkspaceImageSource,
    WorkspaceKind, WorkspaceKnowledgeDto, WorkspaceRef, WorkspaceSave, methods,
};
use gpui_kit::{App, AsyncApp, Entity};

use super::workspace::{
    call, in_editor, in_sheet, knowledge_editor, listed, model_editor, new_item, open,
    open_section, wait_editor_loaded,
};
use super::{
    E2eInputs, NO_SERVER, ax, connect_server, fresh_profile, has, in_setup, ok, settle, shoot_main,
    sign_in_password, wait_main, wait_route, wait_setup, wait_until,
};
use crate::AppState;
use crate::smoke::{current_route, shoot_both_modes};
use crate::stores::navigation::{AreaItem, WorkspaceSection};
use crate::stores::session::Route;
use crate::views::notes::audio::Phase;
use crate::views::notes::doc::FileLink;
use crate::views::notes::editor::FileAction;
use crate::views::notes::pane::NotePane;
use crate::views::workspace::ItemEditor as _;
use crate::views::workspace::knowledge::ServerFileSheet;

/// The fake Open Terminal's id among the server's terminals.
const BUILD_BOX: &str = "buildbox";

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
    if wait_main(cx).await.is_none() {
        return ok("main window", false);
    }

    pass &= model_fields(&url, dir, cx).await;
    pass &= knowledge_server_file(dir, cx).await;
    pass &= note_player(inputs, dir, cx).await;
    pass &= terminal_pdf(inputs, dir, cx).await;
    pass &= preview_socket(inputs, dir, cx).await;
    pass
}

// ── Workspace: a model's terminal, built-in tools and picture ───────────

async fn model_fields(server: &str, dir: &Path, cx: &mut AsyncApp) -> bool {
    let s = WorkspaceSection::Models;
    let mut pass = ok("Workspace › Models opens", open_section(s, cx).await);
    new_item(s, cx);
    settle(cx, 400).await;
    in_editor(cx, model_editor, |e, window, cx| {
        e.set_field("name", "Gull spotter", window, cx);
        e.set_field("terminal", BUILD_BOX, window, cx);
        e.set_field("builtin_tools", "{ \"time\": false", window, cx);
        e.save(window, cx);
    });
    settle(cx, 600).await;
    let refused = cx.update(|cx| {
        model_editor(cx).is_some_and(|e| {
            let e = e.read(cx);
            e.detail.is_none() && e.builtin_tools_error(cx).is_some()
        })
    });
    pass &= ok(
        "Built-In Tools that are not a JSON object are refused, with the field's error",
        refused,
    );
    in_editor(cx, model_editor, |e, window, cx| {
        e.set_field(
            "builtin_tools",
            "{ \"time\": false, \"memory\": true }",
            window,
            cx,
        );
        e.scroll.scroll_to_bottom();
        cx.notify();
    });
    settle(cx, 400).await;
    if let Some((handle, _)) = cx.update(super::main_window) {
        shoot_both_modes(handle, dir, "apps-model-advanced", cx).await;
    }
    in_editor(cx, model_editor, |e, window, cx| e.save(window, cx));
    let saved = wait_until(cx, Duration::from_secs(20), |cx| {
        listed(s, "Gull spotter", cx).is_some()
            && model_editor(cx).is_some_and(|e| e.read(cx).detail.is_some())
    })
    .await;
    pass &= ok("the model saves", saved);
    let Some(id) = cx.update(|cx| listed(s, "Gull spotter", cx).map(|i| i.id)) else {
        return ok("the new model is listed", false);
    };
    let read = call::<methods::WorkspaceGet>(
        &WorkspaceRef {
            kind: WorkspaceKind::Models,
            id: id.clone(),
        },
        cx,
    )
    .await;
    let model = read.as_ref().and_then(|d| d.model.clone());
    pass &= ok(
        "the server keeps the model's terminal",
        model.as_ref().is_some_and(|m| m.terminal_id == BUILD_BOX),
    );
    pass &= ok(
        "…and its built-in tools",
        model
            .as_ref()
            .is_some_and(|m| m.builtin_tools == serde_json::json!({"time": false, "memory": true})),
    );

    // A picture at an address on the server: through the daemon.
    let Some(detail) = read else {
        return pass;
    };
    let with_picture = |url: &str| {
        let mut d = detail.clone();
        if let Some(m) = d.model.as_mut() {
            m.image_url = Some(url.to_string());
        }
        d
    };
    let local = format!("{}/static/favicon.png", server.trim_end_matches('/'));
    pass &= ok(
        "a picture on the server is saved to the model",
        save_detail(with_picture(&local), cx).await,
    );
    open(s, id.clone(), cx);
    let shown = wait_until(cx, Duration::from_secs(20), |cx| {
        let Some(e) = model_editor(cx) else {
            return false;
        };
        let source = e
            .read(cx)
            .detail
            .as_ref()
            .and_then(|d| d.model.as_ref())
            .map(|m| m.image_source);
        source == Some(WorkspaceImageSource::Server) && e.read(cx).shows_picture()
    })
    .await;
    pass &= ok(
        "the server's picture loads through the daemon (/files)",
        shown,
    );
    in_editor(cx, model_editor, |e, _, cx| {
        e.scroll.set_offset(Default::default());
        cx.notify();
    });
    settle(cx, 300).await;
    if let Some((handle, _)) = cx.update(super::main_window) {
        shoot_both_modes(handle, dir, "apps-model-picture", cx).await;
    }

    // One on another site: never fetched, the initial stands in.
    pass &= ok(
        "a picture on another site is saved to the model",
        save_detail(with_picture("https://pictures.example/gull.png"), cx).await,
    );
    open(s, id.clone(), cx);
    let remote = wait_until(cx, Duration::from_secs(20), |cx| {
        model_editor(cx).is_some_and(|e| {
            e.read(cx)
                .detail
                .as_ref()
                .and_then(|d| d.model.as_ref())
                .is_some_and(|m| m.image_source == WorkspaceImageSource::Remote)
        })
    })
    .await;
    settle(cx, 1500).await;
    let initial = cx.update(|cx| model_editor(cx).is_some_and(|e| !e.read(cx).shows_picture()));
    pass &= ok(
        "a picture on another site is not fetched: the initial stands in",
        remote && initial,
    );
    let waits = cx.update(|cx| model_editor(cx).and_then(|e| e.read(cx).remote_picture_waits(cx)));
    pass &= ok(
        "…and Load Image waits beside it, naming the site",
        waits.as_deref() == Some("pictures.example"),
    );
    shoot_main(dir, "apps-model-remote-picture", cx).await;
    pass &= remote_model_picture(id, &with_picture, dir, cx).await;
    pass
}

/// A model's picture on another site follows an answer's pictures' rule:
/// it waits for Load Image (then loads once, through `/media`), or loads
/// without a click from a site in Remote Content. The site is the
/// `rendering-media` pass's synthetic one on this Mac's network address
/// (`/media` never fetches from this Mac itself).
async fn remote_model_picture(
    id: String,
    with_picture: &dyn Fn(&str) -> WorkspaceDetail,
    dir: &Path,
    cx: &mut AsyncApp,
) -> bool {
    let s = WorkspaceSection::Models;
    let Some(host) = super::rendering_media::network_host() else {
        return ok("this Mac has a network address for the other site", false);
    };
    let port: u16 = std::env::var("CONDUIT_MEDIA_PORT")
        .ok()
        .and_then(|p| p.parse().ok())
        .unwrap_or(8155);
    let log = dir.join("model-picture-requests.jsonl");
    let _ = std::fs::remove_file(&log);
    let site = std::process::Command::new("python3")
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
        .spawn();
    let Ok(mut site) = site else {
        return ok("the synthetic media site starts", false);
    };
    settle(cx, 800).await;
    let asked = |path: &str| {
        std::fs::read_to_string(&log)
            .unwrap_or_default()
            .lines()
            .filter(|l| l.contains(&format!("\"path\": \"{path}\"")))
            .count()
    };
    let mut pass = true;

    // Waits for Load Image; nothing is fetched until then, then once.
    let map = format!("http://{host}:{port}/harbour-map.png");
    pass &= ok(
        "a picture on the other site is saved to the model",
        save_detail(with_picture(&map), cx).await,
    );
    open(s, id.clone(), cx);
    let h = host.clone();
    let waits = wait_until(cx, Duration::from_secs(20), move |cx| {
        model_editor(cx).is_some_and(|e| e.read(cx).remote_picture_waits(cx).as_deref() == Some(&h))
    })
    .await;
    settle(cx, 800).await;
    pass &= ok(
        "the model's picture on the other site waits behind Load Image, unfetched",
        waits && asked("/harbour-map.png") == 0,
    );
    let url = map.clone();
    cx.update(|cx| crate::stores::media::load_once(&url, cx));
    let drawn = wait_until(cx, Duration::from_secs(20), |cx| {
        model_editor(cx).is_some_and(|e| e.read(cx).shows_picture())
    })
    .await;
    pass &= ok(
        "Load Image loads it through /media, once",
        drawn && asked("/harbour-map.png") == 1,
    );
    shoot_main(dir, "apps-model-remote-picture-loaded", cx).await;

    // A site in Remote Content: no click.
    let chart = format!("http://{host}:{port}/tide-chart.png");
    let h = host.clone();
    cx.update(move |cx| crate::stores::media::allow_host(&h, cx));
    pass &= ok(
        "another picture on that site is saved to the model",
        save_detail(with_picture(&chart), cx).await,
    );
    open(s, id, cx);
    let loaded = wait_until(cx, Duration::from_secs(20), |cx| {
        model_editor(cx).is_some_and(|e| {
            let e = e.read(cx);
            e.remote_picture_waits(cx).is_none()
                && e.shows_picture()
                && e.detail
                    .as_ref()
                    .and_then(|d| d.model.as_ref())
                    .and_then(|m| m.image_url.as_deref())
                    .is_some_and(|u| u.ends_with("/tide-chart.png"))
        })
    })
    .await;
    pass &= ok(
        "a picture from a site in Remote Content loads without a click",
        loaded && asked("/tide-chart.png") == 1,
    );
    let _ = site.kill();
    let _ = site.wait();
    pass
}

async fn save_detail(detail: WorkspaceDetail, cx: &mut AsyncApp) -> bool {
    call::<methods::WorkspaceSave>(
        &WorkspaceSave {
            detail,
            create: false,
            metadata_only: false,
        },
        cx,
    )
    .await
    .is_some()
}

// ── Knowledge: Attach Server File… ──────────────────────────────────────

async fn knowledge_server_file(dir: &Path, cx: &mut AsyncApp) -> bool {
    let s = WorkspaceSection::Knowledge;
    let made = call::<methods::WorkspaceSave>(
        &WorkspaceSave {
            detail: WorkspaceDetail {
                kind: WorkspaceKind::Knowledge,
                model: None,
                knowledge: Some(WorkspaceKnowledgeDto {
                    id: String::new(),
                    name: "Harbour records".into(),
                    description: "Tide and weather notes for the north pier".into(),
                    file_count: 0,
                    external: false,
                    max_file_count: None,
                    max_file_size: None,
                }),
                prompt: None,
                tool: None,
                skill: None,
                grants: vec![],
                write_access: true,
                owner_name: None,
                updated_at_ms: None,
            },
            create: true,
            metadata_only: false,
        },
        cx,
    )
    .await;
    let Some(id) = made.and_then(|d| d.knowledge.map(|k| k.id)) else {
        return ok("a knowledge base is made", false);
    };
    let mut pass = ok("Workspace › Knowledge opens", open_section(s, cx).await);
    open(s, id, cx);
    pass &= ok("the knowledge base opens", wait_editor_loaded(s, cx).await);
    in_editor(cx, knowledge_editor, |e, window, cx| {
        e.attach_server_file_sheet(window, cx)
    });
    let listed = wait_until(cx, Duration::from_secs(20), |cx| {
        crate::views::sheet::current::<ServerFileSheet>(cx).is_some_and(|s| {
            s.read(cx)
                .picker
                .read(cx)
                .files()
                .iter()
                .any(|f| f.name == "field-notes.txt")
        })
    })
    .await;
    pass &= ok(
        "Attach Server File… lists the account's files in a sheet",
        listed,
    );
    settle(cx, 400).await;
    if let Some(sheet) = cx.update(|cx| crate::views::sheet::current_window(cx)) {
        shoot_both_modes(sheet, dir, "apps-knowledge-server-files", cx).await;
        let controls = ax(sheet, "apps-knowledge-server-files", dir, cx).await;
        pass &= ok(
            "AX: the picker's rows",
            has(&controls, "ListBoxOption", "field-notes.txt"),
        );
        pass &= ok("AX: the sheet's Cancel", has(&controls, "Button", "Cancel"));
    }
    in_sheet::<ServerFileSheet, _>(cx, |s, _, cx| {
        let file = s
            .picker
            .read(cx)
            .files()
            .iter()
            .find(|f| f.name == "field-notes.txt")
            .cloned();
        if let Some(file) = file {
            s.pick(file, cx);
        }
    });
    let attached = wait_until(cx, Duration::from_secs(60), |cx| {
        knowledge_editor(cx).is_some_and(|e| {
            e.read(cx)
                .files
                .as_ref()
                .is_some_and(|f| f.files.iter().any(|f| f.filename == "field-notes.txt"))
        })
    })
    .await;
    pass &= ok(
        "the picked file goes into the knowledge base, as it is",
        attached,
    );
    settle(cx, 300).await;
    shoot_main(dir, "apps-knowledge-attached", cx).await;
    pass
}

// ── Notes: a recording plays in the note ────────────────────────────────

fn note_pane(cx: &mut App) -> Option<Entity<NotePane>> {
    let view = cx.global::<AppState>().main_view.clone()?;
    view.read(cx)
        .area_pane
        .read(cx)
        .notes
        .read(cx)
        .note_pane()
        .cloned()
}

fn recording_card(cx: &mut App) -> Option<FileLink> {
    let pane = note_pane(cx)?;
    let editor = pane.read(cx).editor.clone();
    editor
        .read(cx)
        .doc
        .blocks
        .iter()
        .filter_map(|b| b.file_link())
        // The core names a note's recordings itself (`recording_<ms>.wav`).
        .find(|f| f.name.starts_with("recording_") && f.name.ends_with(".wav"))
}

/// `secs` seconds of 16 kHz mono silence as a WAV file.
fn silent_wav(secs: u32) -> Vec<u8> {
    let rate: u32 = 16_000;
    let data = rate * 2 * secs;
    let mut out = Vec::with_capacity(44 + data as usize);
    out.extend_from_slice(b"RIFF");
    out.extend_from_slice(&(36 + data).to_le_bytes());
    out.extend_from_slice(b"WAVEfmt ");
    out.extend_from_slice(&16u32.to_le_bytes());
    out.extend_from_slice(&1u16.to_le_bytes());
    out.extend_from_slice(&1u16.to_le_bytes());
    out.extend_from_slice(&rate.to_le_bytes());
    out.extend_from_slice(&(rate * 2).to_le_bytes());
    out.extend_from_slice(&2u16.to_le_bytes());
    out.extend_from_slice(&16u16.to_le_bytes());
    out.extend_from_slice(b"data");
    out.extend_from_slice(&data.to_le_bytes());
    out.resize(44 + data as usize, 0);
    out
}

fn player(key: &str, cx: &mut App) -> Option<crate::views::notes::audio::PlayerState> {
    note_pane(cx)?.read(cx).audio.read(cx).state(key)
}

fn press_play(link: &FileLink, cx: &mut AsyncApp) {
    let link = link.clone();
    let Some((handle, _)) = cx.update(super::main_window) else {
        return;
    };
    let _ = handle.update(cx, |_, window, cx| {
        if let Some(p) = note_pane(cx) {
            p.update(cx, |p, cx| {
                p.file_action_for_tests(link, FileAction::Play, window, cx)
            });
        }
    });
}

async fn note_player(inputs: &E2eInputs, dir: &Path, cx: &mut AsyncApp) -> bool {
    let Some(note) = inputs.get("OWUI_NOTE") else {
        return ok("OWUI_NOTE in the env file (owui.sh reset)", false);
    };
    let wav = dir.join("apps-recording.wav");
    let mut pass = ok(
        "a three-second recording is written",
        std::fs::write(&wav, silent_wav(3)).is_ok(),
    );
    let added = call::<methods::NotesAddRecording>(
        &NoteRecordingAdd {
            note_id: note.clone(),
            path: wav.to_string_lossy().to_string(),
            page_id: None,
        },
        cx,
    )
    .await;
    pass &= ok("the recording is kept for the note", added.is_some());
    cx.update(|cx| {
        let nav = cx.global::<AppState>().stores.navigation.clone();
        nav.update(cx, |n, cx| n.open_item(AreaItem::Note(note.clone()), cx));
    });
    let carded = wait_until(cx, Duration::from_secs(90), |cx| {
        recording_card(cx).is_some()
    })
    .await;
    pass &= ok(
        "the recording uploads and shows as a card in the note",
        carded,
    );
    let Some(link) = cx.update(recording_card) else {
        return pass;
    };
    let key = link.id.clone();
    press_play(&link, cx);
    let playing = wait_until(cx, Duration::from_secs(20), |cx| {
        player(&key, cx).is_some_and(|s| {
            s.phase == Phase::Ready && s.playing && s.duration >= Duration::from_millis(2900)
        })
    })
    .await;
    pass &= ok("Play plays the recording in the note (3 s long)", playing);
    settle(cx, 700).await;
    let (handle, _) = cx.update(super::main_window).unzip();
    if let Some(handle) = handle {
        let controls = ax(handle, "apps-note-player", dir, cx).await;
        pass &= ok(
            "AX: the scrubber is a slider",
            has(&controls, "Slider", "Playback Position"),
        );
        pass &= ok("AX: Pause", has(&controls, "Button", "Pause"));
    }
    press_play(&link, cx);
    settle(cx, 300).await;
    let paused = cx.update(|cx| player(&key, cx)).filter(|s| !s.playing);
    pass &= ok(
        "Pause stops it where it is",
        paused.is_some_and(|s| s.position > Duration::ZERO && s.position < s.duration),
    );
    cx.update(|cx| {
        if let Some(p) = note_pane(cx) {
            let audio = p.read(cx).audio.clone();
            audio.update(cx, |a, cx| a.seek(&key, 0.5, cx));
        }
    });
    settle(cx, 200).await;
    let seeked = cx.update(|cx| player(&key, cx));
    pass &= ok(
        &format!("the scrubber seeks to the middle ({seeked:?})"),
        seeked.is_some_and(|s| {
            let at = s.position.as_secs_f32();
            (1.2..=1.8).contains(&at)
        }),
    );
    if let Some(handle) = handle {
        shoot_both_modes(handle, dir, "apps-note-player", cx).await;
    }
    press_play(&link, cx);
    let ended = wait_until(cx, Duration::from_secs(10), |cx| {
        player(&key, cx).is_some_and(|s| !s.playing && s.position == s.duration)
    })
    .await;
    pass &= ok("it plays to its end and shows it whole", ended);
    pass
}

// ── Terminal: a PDF at the model's page; a port's live reload ───────────

async fn terminal_pdf(inputs: &E2eInputs, dir: &Path, cx: &mut AsyncApp) -> bool {
    use super::chat::{chat_store, in_pane, send, wait_answer, wait_models};
    use crate::views::terminal::pdf::OpenPdfs;
    let mut pass = ok("models.list answered", wait_models(cx).await);
    super::composer::new_chat(cx).await;
    let model = inputs.model();
    in_pane(cx, move |p, _, cx| {
        p.composer_store
            .update(cx, |c, cx| c.select_model(&model, cx))
    });
    cx.update(|cx| crate::views::terminal::chat::toggle_terminal(BUILD_BOX.into(), None, cx));
    let selected = wait_until(cx, Duration::from_secs(10), |cx| {
        cx.global::<AppState>()
            .stores
            .areas
            .read(cx)
            .terminal_selected
            .as_deref()
            == Some(BUILD_BOX)
    })
    .await;
    pass &= ok("the chat uses the Build box", selected);
    send("Please show the tide table.", cx).await;
    let viewer = |cx: &mut App| {
        cx.try_global::<OpenPdfs>()
            .and_then(|o| o.0.last().cloned())
            .and_then(|(h, v)| Some((h, v.upgrade()?)))
    };
    let opened = wait_until(cx, Duration::from_secs(60), move |cx| {
        viewer(cx).is_some_and(|(_, v)| v.read(cx).name() == "tides.pdf")
    })
    .await;
    pass &= ok(
        "a model's display_file opens the PDF in PDFKit's viewer",
        opened,
    );
    settle(cx, 1200).await;
    let at = cx.update(|cx| viewer(cx).map(|(_, v)| v.read(cx).position()));
    pass &= ok(
        &format!("…at the page the model named, 2 of 3 ({at:?})"),
        at == Some((2, 3)),
    );
    if let Some((handle, _)) = cx.update(viewer) {
        shoot_both_modes(handle, dir, "apps-terminal-pdf", cx).await;
        let controls = ax(handle, "apps-terminal-pdf", dir, cx).await;
        pass &= ok(
            "AX: the PDF's name heads it",
            has(&controls, "Heading", "tides.pdf"),
        );
        pass &= ok("AX: Save…", has(&controls, "Button", "Save"));
        let _ = handle.update(cx, |_, window, _| window.remove_window());
    }
    pass &= ok(
        "the answer finishes",
        wait_answer(cx, Duration::from_secs(60)).await,
    );
    let chat_id = cx.update(|cx| chat_store(cx).map(|s| s.read(cx).chat_id().to_string()));
    cx.update(|cx| crate::views::terminal::chat::toggle_terminal(BUILD_BOX.into(), None, cx));
    if let Some(id) = chat_id {
        let _ = call::<methods::ChatsDelete>(&ChatRef { id }, cx).await;
    }
    pass
}

async fn preview_socket(inputs: &E2eInputs, dir: &Path, cx: &mut AsyncApp) -> bool {
    use crate::views::terminal::preview::OpenPreviews;
    let (Some(url), Some(key)) = (
        inputs.get("FAKE_TERMINAL_URL"),
        inputs.get("FAKE_TERMINAL_KEY"),
    ) else {
        return ok(
            "FAKE_TERMINAL_URL and _KEY in the env file (owui.sh reset)",
            false,
        );
    };
    let Some(list) = call::<methods::IntegrationsList>(&NoParams, cx).await else {
        return ok("integrations.list", false);
    };
    if super::personal_moved_to_tether(&list) {
        println!(
            "SMOKE e2e skip a personal terminal's preview: {}",
            super::MOVED_TO_TETHER
        );
        return true;
    }
    let added = call::<methods::IntegrationsSave>(
        &PersonalConnectionSave {
            owner: list.owner.clone(),
            kind: PersonalKind::Terminal,
            op: PersonalEditOp::Add,
            identity: None,
            draft: Some(PersonalConnectionDraft {
                name: "Dock box".into(),
                description: String::new(),
                url: url.clone(),
                spec_type: "url".into(),
                path: "/openapi.json".into(),
                spec: String::new(),
                auth_type: "bearer".into(),
                key,
                key_mode: PersonalKeyMode::Replace,
                enabled: true,
            }),
            enabled: None,
            fingerprint: None,
        },
        cx,
    )
    .await;
    let mut pass = ok(
        "a personal terminal straight to the fake Open Terminal is added",
        added.is_some(),
    );
    cx.update(|cx| {
        let areas = cx.global::<AppState>().stores.areas.clone();
        areas.update(cx, |a, cx| {
            a.refresh(crate::stores::navigation::Area::Terminal, cx)
        });
    });
    let id = url.clone();
    let listed = wait_until(cx, Duration::from_secs(30), move |cx| {
        cx.global::<AppState>()
            .stores
            .areas
            .read(cx)
            .terminal(&id)
            .is_some()
    })
    .await;
    pass &= ok("it is listed in the Terminal section", listed);
    let id = url.clone();
    cx.update(|cx| {
        let nav = cx.global::<AppState>().stores.navigation.clone();
        nav.update(cx, |n, cx| n.open_item(AreaItem::Terminal(id), cx));
    });
    let shown = wait_until(cx, Duration::from_secs(20), |cx| {
        cx.global::<AppState>()
            .main_view
            .clone()
            .is_some_and(|v| v.read(cx).area_pane.read(cx).shown_terminal(cx).is_some())
    })
    .await;
    pass &= ok("its pane opens", shown);
    settle(cx, 800).await;
    cx.update(|cx| {
        let pane = cx
            .global::<AppState>()
            .main_view
            .clone()
            .and_then(|v| v.read(cx).area_pane.read(cx).shown_terminal(cx));
        if let Some(p) = pane {
            p.update(cx, |p, cx| p.open_port(5173, cx));
        }
    });
    let preview = |cx: &mut App| {
        cx.try_global::<OpenPreviews>()
            .and_then(|p| p.0.iter().find(|(port, _, _)| *port == 5173).cloned())
            .and_then(|(port, h, v)| Some((port, h, v.upgrade()?)))
    };
    let opened = wait_until(cx, Duration::from_secs(20), move |cx| {
        preview(cx).is_some_and(|(_, _, v)| v.read(cx).address() == "localhost:5173")
    })
    .await;
    pass &= ok("the dev server's page opens in a preview", opened);
    settle(cx, 1500).await;
    if let Some((_, handle, view)) = cx.update(preview) {
        // The page's live reload: a WebSocket to its own host, which the
        // dev server answers with a reload to /reloaded.
        cx.update(|cx| {
            view.read(cx)
                .eval("document.getElementById('live').click()", cx)
        });
        let reloaded = wait_until(cx, Duration::from_secs(20), |cx| {
            view.read(cx).address() == "localhost:5173/reloaded"
        })
        .await;
        let now = cx.update(|cx| view.read(cx).address());
        pass &= ok(
            &format!("the page's live-reload WebSocket passes the preview listener ({now})"),
            reloaded,
        );
        settle(cx, 800).await;
        shoot_both_modes(handle, dir, "apps-preview-reloaded", cx).await;
        let _ = handle.update(cx, |_, window, _| window.remove_window());
    }
    // Leave the account as it was.
    if let Some(list) = call::<methods::IntegrationsList>(&NoParams, cx).await
        && let Some(entry) = list.terminals.iter().find(|t| t.url == url)
    {
        let _ = call::<methods::IntegrationsSave>(
            &PersonalConnectionSave {
                owner: list.owner.clone(),
                kind: PersonalKind::Terminal,
                op: PersonalEditOp::Remove,
                identity: Some(entry.identity.clone()),
                draft: None,
                enabled: None,
                fingerprint: None,
            },
            cx,
        )
        .await;
    }
    pass
}
