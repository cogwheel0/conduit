//! `--e2e notes`, on the local Open WebUI (`tool/local_owui`): its
//! seeded notes (a note with pages, a note with every format and a file
//! attached, the pinned ones) and the fake model (titles, enhancements,
//! transcriptions).
//!
//! * **All Notes**: the sidebar's first Notes row opens the list pane,
//!   pinned first, then the time groups; search; pin and unpin from the
//!   note's menu.
//! * **Reading**: the formats note opens with every block and mark the
//!   editor offers, and its file as a card; it round-trips through the
//!   daemon unchanged. The paged note lists its pages; another page shows.
//! * **Writing**: New Note (⌘N in Notes); every format typed with the real
//!   keys (⇧⌘T, ⌘B, ⌘I, ⇧⌘X, ⌘E, ⌘K, the `- ` `1. ` `[] ` `> ` and ```
//!   shortcuts, Tab, ⇧⌘U); autosave; the note reopened shows the same
//!   document, and its stored markdown has every format.
//! * Find (⌘F, ⌘G), undo (⌘Z), a file attached, dictation into the note
//!   and an audio recording (WAVs from `say` standing in for the
//!   microphone), the recording transcribed into the text, Generate Title,
//!   Enhance Note (and ⌘Z), Share Access…, a deleted note's draft
//!   recovered as a new note, `conduit://note/<id>`, and Delete….
//!
//! Each new screen is shot in light and dark, with AccessKit checks.

use std::path::Path;
use std::time::Duration;

use conduit_protocol::{AccessRef, AccessResourceKind, NoteOpen, NoteRef, methods};
use gpui_kit::{App, AsyncApp, Entity, EntityInputHandler as _, Focusable as _};

use super::chat::sign_in;
use super::dictation::speak_to;
use super::*;
use crate::stores::navigation::{AreaItem, Selection};
use crate::views::notes::NoteCommand;
use crate::views::notes::doc::{BlockKind, Doc};
use crate::views::notes::list::{NotesList, Row};
use crate::views::notes::pane::{Load, NotePane, SaveState};
use crate::voice::InputOverride;

/// The fake model's answer to every transcription.
const TRANSCRIPT: &str = "A synthetic transcript from the fake model.";

fn list(cx: &mut App) -> Option<Entity<NotesList>> {
    let view = cx.global::<AppState>().main_view.clone()?;
    Some(view.read(cx).area_pane.read(cx).notes.read(cx).list.clone())
}

fn pane(cx: &mut App) -> Option<Entity<NotePane>> {
    let view = cx.global::<AppState>().main_view.clone()?;
    view.read(cx)
        .area_pane
        .read(cx)
        .notes
        .read(cx)
        .note_pane()
        .cloned()
}

fn selection(cx: &mut App) -> Selection {
    cx.global::<AppState>()
        .stores
        .navigation
        .read(cx)
        .selection()
        .clone()
}

fn open(item: AreaItem, cx: &mut AsyncApp) {
    cx.update(|cx| {
        cx.global::<AppState>()
            .stores
            .navigation
            .clone()
            .update(cx, |n, cx| n.open_item(item, cx))
    });
}

/// The note pane shown, once `id`'s is loaded.
async fn wait_note(id: &str, cx: &mut AsyncApp) -> bool {
    let id = id.to_string();
    wait_until(cx, Duration::from_secs(30), move |cx| {
        pane(cx).is_some_and(|p| p.read(cx).shows(&id) && p.read(cx).load == Load::Ready)
    })
    .await
}

fn doc(cx: &mut App) -> Option<Doc> {
    pane(cx).map(|p| p.read(cx).editor.read(cx).doc.clone())
}

fn kinds(cx: &mut App) -> Vec<BlockKind> {
    doc(cx)
        .map(|d| d.blocks.iter().map(|b| b.kind).collect())
        .unwrap_or_default()
}

fn plain(cx: &mut App) -> String {
    doc(cx).map(|d| d.plain_text()).unwrap_or_default()
}

/// Types `text` the way a keyboard does: through the platform's input
/// handler, a character at a time.
fn type_text(main: AnyWindowHandle, text: &str, cx: &mut AsyncApp) {
    cx.update(|cx| {
        let Some(pane) = pane(cx) else {
            return;
        };
        let editor = pane.read(cx).editor.clone();
        let _ = main.update(cx, |_, window, cx| {
            for c in text.chars() {
                editor.update(cx, |e, cx| {
                    e.replace_text_in_range(None, &c.to_string(), window, cx)
                });
            }
        });
    });
}

fn focus_editor(main: AnyWindowHandle, cx: &mut AsyncApp) {
    cx.update(|cx| {
        let Some(pane) = pane(cx) else {
            return;
        };
        let focus = pane.read(cx).editor.read(cx).focus_handle(cx);
        let _ = main.update(cx, |_, window, cx| window.focus(&focus, cx));
    });
}

async fn keys(main: AnyWindowHandle, strokes: &[&str], cx: &mut AsyncApp) {
    for stroke in strokes {
        press(main, stroke, cx);
        settle(cx, 40).await;
    }
}

async fn saved(cx: &mut AsyncApp) -> bool {
    wait_until(cx, Duration::from_secs(20), |cx| {
        pane(cx).is_some_and(|p| {
            let p = p.read(cx);
            p.save == SaveState::Saved && !p.dirty(cx)
        })
    })
    .await
}

async fn call<M: conduit_daemon::RpcMethod>(
    params: &M::Params,
    cx: &mut AsyncApp,
) -> Option<M::Result>
where
    M::Result: Send + 'static,
{
    let rpc = cx.update(|cx| cx.global::<AppState>().connection.read(cx).rpc());
    match rpc.call::<M>(params).await {
        Ok(r) => Some(r),
        Err(e) => {
            println!("SMOKE note {} failed: {e}", M::NAME);
            None
        }
    }
}

async fn stored_markdown(id: &str, cx: &mut AsyncApp) -> String {
    call::<methods::NotesGet>(
        &NoteOpen {
            id: id.to_string(),
            page_id: None,
        },
        cx,
    )
    .await
    .and_then(|r| r.note)
    .map(|n| n.markdown)
    .unwrap_or_default()
}

pub async fn run(inputs: &E2eInputs, dir: &Path, cx: &mut AsyncApp) -> bool {
    let Some((url, email, password)) = inputs.owui() else {
        return ok(NO_SERVER, false);
    };
    let mut pass = sign_in(&url, &email, &password, cx).await;
    let Some(main) = wait_main(cx).await else {
        return ok("main window", false);
    };
    let note_count: usize = inputs
        .get("OWUI_NOTE_COUNT")
        .and_then(|n| n.parse().ok())
        .unwrap_or(10);

    // ── All Notes ─────────────────────────────────────────────────────
    let listed = wait_until(cx, Duration::from_secs(60), |cx| {
        cx.global::<AppState>()
            .stores
            .areas
            .read(cx)
            .notes
            .as_ref()
            .is_some_and(|n| n.len() == note_count)
    })
    .await;
    pass &= ok(
        &format!("the account's {note_count} notes are listed"),
        listed,
    );
    let row = cx.update(|cx| {
        let view = cx.global::<AppState>().main_view.clone()?;
        Some(view.read(cx).sidebar.read(cx).rows().to_vec())
    });
    pass &= ok(
        "the Notes section starts with All Notes",
        row.is_some_and(|rows| {
            rows.iter()
                .filter_map(crate::views::sidebar_model::SidebarItem::area_item)
                .find(|i| i.area() == crate::stores::navigation::Area::Notes)
                == Some(&AreaItem::AllNotes)
        }),
    );
    open(AreaItem::AllNotes, cx);
    let rows_ok = wait_until(cx, Duration::from_secs(20), |cx| {
        list(cx).is_some_and(|l| {
            let rows = l.read(cx).rows();
            let notes = rows.iter().filter(|r| matches!(r, Row::Note(_))).count();
            notes == note_count && matches!(rows.first(), Some(Row::Heading { .. }))
        })
    })
    .await;
    let groups: Vec<String> = cx.update(|cx| {
        list(cx)
            .map(|l| {
                l.read(cx)
                    .rows()
                    .iter()
                    .filter_map(|r| match r {
                        Row::Heading { group, count, .. } => Some(format!("{group:?}:{count}")),
                        Row::Note(_) => None,
                    })
                    .collect()
            })
            .unwrap_or_default()
    });
    pass &= ok(
        &format!("All Notes lists every note in groups, pinned first ({groups:?})"),
        rows_ok && groups.first().is_some_and(|g| g.starts_with("Pinned:2")),
    );
    settle(cx, 400).await;
    shoot_main(dir, "notes-list", cx).await;
    let controls = ax(main, "notes-list", dir, cx).await;
    pass &= ok(
        "the list's rows and New Note are labelled",
        has(&controls, "ListBoxOption", "Moth sightings") && has(&controls, "Button", "New Note"),
    );

    // Search.
    cx.update(|cx| {
        if let Some(l) = list(cx) {
            l.update(cx, |l, cx| l.set_query("moth".into(), cx));
        }
    });
    let found = wait_until(cx, Duration::from_secs(15), |cx| {
        list(cx).is_some_and(|l| {
            let rows = l.read(cx).rows();
            rows.len() == 1 && matches!(&rows[0], Row::Note(n) if n.title == "Moth sightings")
        })
    })
    .await;
    pass &= ok("search finds Moth sightings alone", found);
    shoot_main(dir, "notes-search", cx).await;
    cx.update(|cx| {
        if let Some(l) = list(cx) {
            l.update(cx, |l, cx| l.set_query(String::new(), cx));
        }
    });

    // Pin and unpin from the note's menu.
    let quilt = cx.update(|cx| {
        cx.global::<AppState>()
            .stores
            .areas
            .read(cx)
            .notes
            .iter()
            .flatten()
            .find(|n| n.title == "Quilt colours")
            .map(|n| n.id.clone())
    });
    let Some(quilt) = quilt else {
        return ok("Quilt colours is listed", false);
    };
    run_command(main, &quilt, NoteCommand::Pin, cx);
    let pinned = wait_until(cx, Duration::from_secs(20), |cx| {
        list(cx).is_some_and(|l| {
            matches!(
                l.read(cx).rows().first(),
                Some(Row::Heading { count: 3, .. })
            )
        })
    })
    .await;
    pass &= ok("Pin moves a note into Pinned", pinned);
    run_command(main, &quilt, NoteCommand::Unpin, cx);
    let unpinned = wait_until(cx, Duration::from_secs(20), |cx| {
        list(cx).is_some_and(|l| {
            matches!(
                l.read(cx).rows().first(),
                Some(Row::Heading { count: 2, .. })
            )
        })
    })
    .await;
    pass &= ok("Unpin takes it out again", unpinned);

    // ── Reading every format ──────────────────────────────────────────
    if let Some(formats) = inputs.get("OWUI_FORMATS_NOTE") {
        open(AreaItem::Note(formats.clone()), cx);
        pass &= ok("the formats note opens", wait_note(&formats, cx).await);
        settle(cx, 500).await;
        let seen = cx.update(kinds);
        let want = [
            BlockKind::Heading(1),
            BlockKind::Bullet,
            BlockKind::Ordered,
            BlockKind::Check(true),
            BlockKind::Check(false),
            BlockKind::Quote,
            BlockKind::Code,
        ];
        pass &= ok(
            &format!("every block kind shows ({seen:?})"),
            want.iter().all(|k| seen.contains(k)),
        );
        let marks = cx.update(|cx| {
            doc(cx)
                .map(|d| {
                    let all: Vec<_> = d
                        .blocks
                        .iter()
                        .flat_map(|b| b.runs.iter().map(|r| r.marks.clone()))
                        .collect();
                    (
                        all.iter().any(|m| m.bold),
                        all.iter().any(|m| m.italic),
                        all.iter().any(|m| m.strike),
                        all.iter().any(|m| m.code),
                        all.iter()
                            .any(|m| m.link.as_deref() == Some("https://example.com/seed-swap")),
                        d.blocks.iter().filter_map(|b| b.file_link()).count(),
                    )
                })
                .unwrap_or_default()
        });
        pass &= ok(
            &format!("bold, italic, strikethrough, code, a link and the file's card ({marks:?})"),
            marks == (true, true, true, true, true, 1),
        );
        shoot_main(dir, "notes-formats", cx).await;
        let controls = ax(main, "notes-formats", dir, cx).await;
        pass &= ok(
            "the editor, its format bar and the file card are labelled",
            has(&controls, "MultilineTextInput", "Note Text")
                && has(&controls, "Button", "Bold")
                && has(&controls, "Button", "Quick Look"),
        );
    }

    // ── Pages ─────────────────────────────────────────────────────────
    if let Some(paged) = inputs.get("OWUI_PAGED_NOTE") {
        open(AreaItem::Note(paged.clone()), cx);
        pass &= ok("the paged note opens", wait_note(&paged, cx).await);
        let pages = cx.update(|cx| {
            pane(cx)
                .map(|p| {
                    p.read(cx)
                        .pages()
                        .iter()
                        .map(|p| (p.title.clone(), p.depth))
                        .collect::<Vec<_>>()
                })
                .unwrap_or_default()
        });
        pass &= ok(
            &format!("its pages are listed, nested ({pages:?})"),
            pages.len() == 4 && pages.iter().any(|(t, d)| t == "Evening walk" && *d == 1),
        );
        let day_two = cx.update(|cx| {
            pane(cx).and_then(|p| {
                p.read(cx)
                    .pages()
                    .iter()
                    .find(|p| p.title == "Day two")
                    .map(|p| p.id.clone())
            })
        });
        if let Some(day_two) = day_two {
            cx.update(|cx| {
                if let Some(p) = pane(cx) {
                    let _ = main.update(cx, |_, window, cx| {
                        p.update(cx, |p, cx| p.show_page(day_two.clone(), window, cx))
                    });
                }
            });
            let shown = wait_until(cx, Duration::from_secs(20), |cx| {
                pane(cx).is_some_and(|p| p.read(cx).page_id == day_two)
                    && plain(cx).contains("Rain until noon")
            })
            .await;
            pass &= ok("another page shows its own text", shown);
            shoot_main(dir, "notes-page", cx).await;
        } else {
            pass &= ok("Day two is a page", false);
        }
    }

    // ── New Note, every format typed ──────────────────────────────────
    open(AreaItem::AllNotes, cx);
    settle(cx, 300).await;
    cx.update(|cx| {
        let _ = main.update(cx, |_, window, cx| {
            if let Some(l) = list(cx) {
                let focus = l.read(cx).focus_handle(cx);
                window.focus(&focus, cx);
            }
        });
    });
    press(main, "cmd-n", cx);
    let made = wait_until(cx, Duration::from_secs(20), |cx| {
        matches!(selection(cx), Selection::Area(AreaItem::Note(_)))
            && pane(cx).is_some_and(|p| p.read(cx).load == Load::Ready)
    })
    .await;
    pass &= ok("⌘N in Notes makes a new note and opens it", made);
    let new_id = match cx.update(selection) {
        Selection::Area(AreaItem::Note(id)) => id,
        _ => return ok("a new note", false),
    };
    let today = chrono::Local::now().format("%Y-%m-%d").to_string();
    let titled = cx
        .update(|cx| pane(cx).is_some_and(|p| p.read(cx).title.read(cx).value() == today.as_str()));
    pass &= ok("the new note is named for today", titled);
    focus_editor(main, cx);
    settle(cx, 200).await;
    type_text(main, "Errands", cx);
    keys(main, &["shift-cmd-t", "enter"], cx).await;
    type_text(main, "Get ", cx);
    keys(main, &["cmd-b"], cx).await;
    type_text(main, "bold", cx);
    keys(main, &["cmd-b"], cx).await;
    type_text(main, " and ", cx);
    keys(main, &["cmd-i"], cx).await;
    type_text(main, "italic", cx);
    keys(main, &["cmd-i"], cx).await;
    type_text(main, " not ", cx);
    keys(main, &["shift-cmd-x"], cx).await;
    type_text(main, "gone", cx);
    keys(main, &["shift-cmd-x"], cx).await;
    type_text(main, " ", cx);
    keys(main, &["cmd-e"], cx).await;
    type_text(main, "code", cx);
    keys(main, &["cmd-e"], cx).await;
    type_text(main, " see site", cx);
    keys(main, &["alt-shift-left", "cmd-k"], cx).await;
    settle(cx, 200).await;
    let link_asked =
        cx.update(|cx| pane(cx).is_some_and(|p| p.read(cx).link_field_for_tests().is_some()));
    pass &= ok("⌘K asks for the link's address", link_asked);
    cx.update(|cx| {
        if let Some(p) = pane(cx) {
            let _ = main.update(cx, |_, window, cx| {
                p.update(cx, |p, cx| {
                    p.apply_link_for_tests("example.com/site", window, cx)
                })
            });
        }
    });
    focus_editor(main, cx);
    keys(main, &["cmd-right", "enter"], cx).await;
    type_text(main, "- milk", cx);
    keys(main, &["enter"], cx).await;
    type_text(main, "oat", cx);
    keys(main, &["enter", "enter", "enter"], cx).await;
    // A nested numbered item (Tab): the codec keeps numbered nesting.
    type_text(main, "1. one", cx);
    keys(main, &["enter", "tab"], cx).await;
    type_text(main, "two", cx);
    keys(main, &["enter", "enter", "enter"], cx).await;
    type_text(main, "[] call the vet", cx);
    keys(main, &["shift-cmd-u", "enter", "enter"], cx).await;
    type_text(main, "> quoted", cx);
    keys(main, &["enter", "enter"], cx).await;
    type_text(main, "```", cx);
    type_text(main, "let x = 1;", cx);
    keys(main, &["enter", "enter"], cx).await;
    type_text(main, "End.", cx);
    settle(cx, 300).await;
    let typed = cx.update(kinds);
    let want = [
        BlockKind::Heading(1),
        BlockKind::Paragraph,
        BlockKind::Bullet,
        BlockKind::Ordered,
        BlockKind::Check(true),
        BlockKind::Quote,
        BlockKind::Code,
    ];
    pass &= ok(
        &format!("the keys made every block kind ({typed:?})"),
        want.iter().all(|k| typed.contains(k)),
    );
    pass &= ok("autosave saves it", saved(cx).await);
    let before = cx.update(doc);
    shoot_main(dir, "notes-edited", cx).await;

    // Reopened: the same document; the stored markdown has every format.
    open(AreaItem::AllNotes, cx);
    settle(cx, 500).await;
    open(AreaItem::Note(new_id.clone()), cx);
    pass &= ok("the note opens again", wait_note(&new_id, cx).await);
    let after = cx.update(doc);
    // Markdown keeps no run of blank lines, so empty paragraphs may come
    // back fewer; everything else is the same.
    let written = |d: &Doc| {
        d.blocks
            .iter()
            .filter(|b| !b.text.is_empty())
            .map(|b| (b.kind, b.indent, b.text.clone(), b.runs.clone()))
            .collect::<Vec<_>>()
    };
    let same = match (&before, &after) {
        (Some(a), Some(b)) => written(a) == written(b),
        _ => false,
    };
    pass &= ok(
        "reopened, it is the same document (every format round-trips)",
        same,
    );
    let md = stored_markdown(&new_id, cx).await;
    let parts = [
        "# Errands",
        "**bold**",
        // As the codec writes them: `_` italic, `*` bullets, `[X]`.
        "_italic_",
        "~~gone~~",
        "`code`",
        "[site](https://example.com/site)",
        "* milk",
        "* oat",
        "1. one",
        "  1. two",
        "- [X] call the vet",
        "> quoted",
        "```",
        "let x = 1;",
    ];
    let missing: Vec<&&str> = parts.iter().filter(|p| !md.contains(**p)).collect();
    pass &= ok(
        &format!("its markdown has every format (missing {missing:?})"),
        missing.is_empty(),
    );

    // Find, and undo.
    focus_editor(main, cx);
    press(main, "cmd-f", cx);
    settle(cx, 200).await;
    cx.update(|cx| {
        if let Some(p) = pane(cx) {
            let _ = main.update(cx, |_, window, cx| {
                p.update(cx, |p, cx| p.type_find("o", window, cx))
            });
        }
    });
    settle(cx, 200).await;
    let matches = cx.update(|cx| {
        pane(cx)
            .map(|p| p.read(cx).editor.read(cx).find.matches.len())
            .unwrap_or(0)
    });
    pass &= ok(
        &format!("Find in Note finds every match ({matches})"),
        matches >= 3,
    );
    press(main, "cmd-g", cx);
    settle(cx, 100).await;
    let current = cx.update(|cx| {
        pane(cx)
            .map(|p| p.read(cx).editor.read(cx).find.current)
            .unwrap_or(0)
    });
    pass &= ok("⌘G goes to the next match", current == 1);
    shoot_main(dir, "notes-find", cx).await;
    press(main, "escape", cx);
    settle(cx, 100).await;
    pass &= ok(
        "Esc in the field closes Find",
        cx.update(|cx| pane(cx).is_some_and(|p| p.read(cx).find.is_none())),
    );
    focus_editor(main, cx);
    keys(main, &["cmd-down"], cx).await;
    type_text(main, "!", cx);
    let typed_bang = cx.update(plain).ends_with("End.!");
    keys(main, &["cmd-z"], cx).await;
    settle(cx, 100).await;
    pass &= ok(
        "⌘Z takes back what was typed",
        typed_bang && cx.update(plain).ends_with("End."),
    );

    // ── A file attached ───────────────────────────────────────────────
    let attach_path = std::env::temp_dir().join("conduit-e2e-tide-table.txt");
    std::fs::write(
        &attach_path,
        "High water 06:12, low water 12:30. Synthetic.\n",
    )
    .ok();
    cx.update(|cx| {
        if let Some(p) = pane(cx) {
            p.update(cx, |p, cx| p.attach_paths(vec![attach_path.clone()], cx));
        }
    });
    let card = wait_until(cx, Duration::from_secs(30), |cx| {
        doc(cx).is_some_and(|d| {
            d.blocks
                .iter()
                .filter_map(|b| b.file_link())
                .any(|f| f.name == "conduit-e2e-tide-table.txt")
        })
    })
    .await;
    pass &= ok("an attached file shows as a card", card);
    pass &= ok("…and is saved", saved(cx).await);
    let md = stored_markdown(&new_id, cx).await;
    pass &= ok(
        "the note links the file",
        md.contains("conduit-e2e-tide-table.txt](/api/v1/files/"),
    );
    shoot_main(dir, "notes-attached", cx).await;

    // ── Dictation ─────────────────────────────────────────────────────
    let spoken = dir.join("notes-dictation.wav");
    let spoken_ok = speak_to(&spoken, "Water the seedlings before the frost tonight.");
    pass &= ok("say wrote the stand-in recording", spoken_ok);
    if spoken_ok {
        // The server's engine (the fake model transcribes).
        super::dictation::set_settings(
            conduit_protocol::AppSettingsPatch {
                stt_preference: Some("serverOnly".into()),
                stt_language_code: Some("en".into()),
                voice_silence_duration: Some(800),
                ..Default::default()
            },
            cx,
        )
        .await;
        pass &= ok(
            "Settings › Audio: the server's engine",
            super::dictation::save_voice(
                conduit_protocol::VoiceSettingsEdit {
                    stt_engine: Some("server".into()),
                    ..Default::default()
                },
                cx,
            )
            .await,
        );
        focus_editor(main, cx);
        keys(main, &["cmd-down"], cx).await;
        cx.update(|cx| {
            if let Some(p) = pane(cx) {
                let d = p.read(cx).dictation.clone();
                d.update(cx, |d, _| {
                    d.set_input(Some(InputOverride::File(spoken.clone())))
                });
                let _ = main.update(cx, |_, window, cx| {
                    p.update(cx, |p, cx| p.toggle_dictation(window, cx))
                });
            }
        });
        let dictated = wait_until(cx, Duration::from_secs(60), |cx| {
            plain(cx).contains(TRANSCRIPT)
        })
        .await;
        pass &= ok("dictation writes into the note at the caret", dictated);
        pass &= ok("…and is saved", saved(cx).await);
    }

    // ── An audio recording ────────────────────────────────────────────
    if spoken_ok {
        cx.update(|cx| {
            if let Some(p) = pane(cx) {
                p.update(cx, |p, cx| {
                    p.record_input = Some(InputOverride::File(spoken.clone()));
                    p.record_audio(cx);
                });
            }
        });
        settle(cx, 600).await;
        shoot_main(dir, "notes-recording", cx).await;
        let attached = wait_until(cx, Duration::from_secs(90), |cx| {
            doc(cx).is_some_and(|d| {
                d.blocks
                    .iter()
                    .filter_map(|b| b.file_link())
                    .any(|f| f.name.ends_with(".wav"))
            })
        })
        .await;
        pass &= ok(
            "a recording is kept, uploaded and attached as a card",
            attached,
        );
        let recording = cx.update(|cx| {
            doc(cx).and_then(|d| {
                d.blocks
                    .iter()
                    .filter_map(|b| b.file_link())
                    .find(|f| f.name.ends_with(".wav"))
            })
        });
        if let Some(recording) = recording {
            let before = cx.update(plain).matches(TRANSCRIPT).count();
            cx.update(|cx| {
                if let Some(p) = pane(cx) {
                    let _ = main.update(cx, |_, window, cx| {
                        p.update(cx, |p, cx| {
                            p.file_action_for_tests(
                                recording.clone(),
                                crate::views::notes::editor::FileAction::Transcribe,
                                window,
                                cx,
                            )
                        })
                    });
                }
            });
            let transcribed = wait_until(cx, Duration::from_secs(60), |cx| {
                plain(cx).matches(TRANSCRIPT).count() > before
            })
            .await;
            pass &= ok(
                "Transcribe puts the recording's words under it",
                transcribed,
            );
            pass &= ok("…and is saved", saved(cx).await);
        }
        shoot_main(dir, "notes-recorded", cx).await;
    }

    // ── AI: Generate Title, Enhance Note ──────────────────────────────
    cx.update(|cx| {
        if let Some(p) = pane(cx) {
            let _ = main.update(cx, |_, window, cx| {
                p.update(cx, |p, cx| p.generate_title(window, cx))
            });
        }
    });
    let retitled = wait_until(cx, Duration::from_secs(60), |cx| {
        pane(cx).is_some_and(|p| {
            let p = p.read(cx);
            p.ai.is_none() && p.title.read(cx).value() != today.as_str()
        })
    })
    .await;
    let new_title = cx.update(|cx| {
        pane(cx)
            .map(|p| p.read(cx).title.read(cx).value().to_string())
            .unwrap_or_default()
    });
    pass &= ok(
        &format!("Generate Title names the note ({new_title})"),
        retitled,
    );
    pass &= ok("…and the title is saved", saved(cx).await);
    let before_enhance = cx.update(doc).map(|d| d.to_ops());
    cx.update(|cx| {
        if let Some(p) = pane(cx) {
            let _ = main.update(cx, |_, window, cx| {
                p.update(cx, |p, cx| p.enhance(window, cx))
            });
        }
    });
    let enhanced = wait_until(cx, Duration::from_secs(60), |cx| {
        pane(cx).is_some_and(|p| p.read(cx).ai.is_none())
            && cx.update_return_ops() != before_enhance
    })
    .await;
    pass &= ok("Enhance Note rewrites the text", enhanced);
    shoot_main(dir, "notes-enhanced", cx).await;
    focus_editor(main, cx);
    keys(main, &["cmd-z"], cx).await;
    settle(cx, 200).await;
    pass &= ok(
        "⌘Z takes the enhancement back",
        cx.update(doc).map(|d| d.to_ops()) == before_enhance,
    );
    pass &= ok("…and that is saved", saved(cx).await);

    // ── Share Access… ─────────────────────────────────────────────────
    run_command(main, &new_id, NoteCommand::Share, cx);
    let sheet = wait_until(cx, Duration::from_secs(20), |cx| {
        crate::views::sheet::current::<crate::views::access_sheet::AccessSheet>(cx)
            .is_some_and(|s| s.read(cx).state.is_some())
    })
    .await;
    pass &= ok("Share Access… opens the note's access sheet", sheet);
    if sheet {
        settle(cx, 400).await;
        if let Some(handle) = cx.update(|cx| crate::views::sheet::current_window(cx)) {
            crate::smoke::shoot_both_modes(handle, dir, "notes-share", cx).await;
        }
        let second = inputs.get("OWUI_SECOND_NAME").unwrap_or_default();
        cx.update(|cx| {
            if let Some(s) =
                crate::views::sheet::current::<crate::views::access_sheet::AccessSheet>(cx)
            {
                s.update(cx, |s, cx| s.find(second.clone(), cx));
            }
        });
        let found = wait_until(cx, Duration::from_secs(20), |cx| {
            crate::views::sheet::current::<crate::views::access_sheet::AccessSheet>(cx)
                .is_some_and(|s| !s.read(cx).results.is_empty())
        })
        .await;
        pass &= ok("the second user can be found", found);
        cx.update(|cx| {
            let Some(s) =
                crate::views::sheet::current::<crate::views::access_sheet::AccessSheet>(cx)
            else {
                return;
            };
            let Some(handle) = crate::views::sheet::current_window(cx) else {
                return;
            };
            let first = s.read(cx).results.first().cloned();
            let _ = handle.update(cx, |_, window, cx| {
                s.update(cx, |s, cx| {
                    if let Some(p) = first {
                        s.add(&p, window, cx);
                    }
                    s.save(window, cx);
                })
            });
        });
        let granted = wait_until(cx, Duration::from_secs(20), |cx| {
            crate::views::sheet::current::<crate::views::access_sheet::AccessSheet>(cx).is_none()
        })
        .await;
        let state = call::<methods::AccessGet>(
            &AccessRef {
                kind: AccessResourceKind::Note,
                id: new_id.clone(),
            },
            cx,
        )
        .await;
        pass &= ok(
            "the grant is saved on the server",
            granted && state.is_some_and(|s| !s.grants.is_empty()),
        );
    }

    // ── A deleted note's draft is kept ────────────────────────────────
    let reading = cx.update(|cx| {
        cx.global::<AppState>()
            .stores
            .areas
            .read(cx)
            .notes
            .iter()
            .flatten()
            .find(|n| n.title == "Reading list")
            .map(|n| n.id.clone())
    });
    if let Some(reading) = reading {
        open(AreaItem::Note(reading.clone()), cx);
        pass &= ok("Reading list opens", wait_note(&reading, cx).await);
        focus_editor(main, cx);
        keys(main, &["cmd-down"], cx).await;
        // Deleted elsewhere, while a change here waits to be saved.
        cx.update(|cx| {
            if let Some(p) = pane(cx) {
                p.update(cx, |p, cx| p.hold_saves_for_tests(true, cx));
            }
        });
        type_text(main, " Also a book on lichens.", cx);
        let deleted = call::<methods::NotesDelete>(
            &NoteRef {
                id: reading.clone(),
            },
            cx,
        )
        .await;
        pass &= ok("the note is deleted behind the editor", deleted.is_some());
        cx.update(|cx| {
            if let Some(p) = pane(cx) {
                p.update(cx, |p, cx| p.hold_saves_for_tests(false, cx));
            }
        });
        let recovered = wait_until(cx, Duration::from_secs(30), |cx| {
            pane(cx).is_some_and(|p| p.read(cx).recovered)
                && matches!(selection(cx), Selection::Area(AreaItem::Note(id)) if id != reading)
        })
        .await;
        pass &= ok(
            "the draft is kept as a new note, and the pane says so",
            recovered,
        );
        if let Selection::Area(AreaItem::Note(kept)) = cx.update(selection) {
            let md = stored_markdown(&kept, cx).await;
            pass &= ok(
                "the new note has the text typed",
                md.contains("Also a book on lichens."),
            );
        }
        shoot_main(dir, "notes-recovered", cx).await;
    }

    // ── A link opens the note ─────────────────────────────────────────
    shell_links(&[&format!("conduit://note/{new_id}")], cx);
    pass &= ok(
        "conduit://note/<id> opens the note",
        wait_note(&new_id, cx).await,
    );

    // ── Delete… ───────────────────────────────────────────────────────
    run_command(main, &new_id, NoteCommand::Delete, cx);
    let gone = wait_until(cx, Duration::from_secs(20), |cx| {
        selection(cx) == Selection::Area(AreaItem::AllNotes)
            && !cx
                .global::<AppState>()
                .stores
                .areas
                .read(cx)
                .notes
                .iter()
                .flatten()
                .any(|n| n.id == new_id)
    })
    .await;
    pass &= ok(
        "Delete… (confirmed) deletes the note and shows All Notes",
        gone,
    );

    // ── A note shared to read ─────────────────────────────────────────
    // The admin shared "Allotment rota" with the second user to read:
    // signed in as them, it opens read-only, says who shared it, and
    // offers neither formatting nor Delete.
    if let (Some(shared), Some(second), Some(second_password)) = (
        inputs.get("OWUI_SHARED_NOTE"),
        inputs.get("OWUI_SECOND_EMAIL"),
        inputs.get("OWUI_SECOND_PASSWORD"),
    ) {
        pass &= sign_in(&url, &second, &second_password, cx).await;
        // Listed as not to be edited. The list (the core's rows, as the
        // phone's) knows neither the server's write access nor the owner's
        // name; the pane learns both when it opens the note.
        let listed = wait_until(cx, Duration::from_secs(60), |cx| {
            cx.global::<AppState>()
                .stores
                .areas
                .read(cx)
                .note(&shared)
                .is_some_and(|n| !n.can_edit)
        })
        .await;
        let summary = cx.update(|cx| {
            cx.global::<AppState>()
                .stores
                .areas
                .read(cx)
                .note(&shared)
                .cloned()
        });
        pass &= ok(
            &format!("the shared note is listed, not to be edited ({summary:?})"),
            listed && summary.as_ref().is_some_and(|n| !n.can_edit),
        );
        open(AreaItem::Note(shared.clone()), cx);
        pass &= ok("it opens", wait_note(&shared, cx).await);
        let read_only = cx.update(|cx| {
            pane(cx).is_some_and(|p| {
                let p = p.read(cx);
                !p.editable() && p.editor.read(cx).is_read_only()
            })
        });
        pass &= ok("…read-only", read_only);
        let menu = summary.as_ref().map(crate::views::notes::commands);
        pass &= ok(
            "its menu offers no Delete or Share Access",
            menu.is_some_and(|m| {
                !m.contains(&NoteCommand::Delete) && !m.contains(&NoteCommand::Share)
            }),
        );
        let before = cx.update(plain);
        type_text(main, "x", cx);
        settle(cx, 300).await;
        pass &= ok("typing changes nothing", cx.update(plain) == before);
        shoot_main(dir, "notes-read-only", cx).await;
    }
    pass
}

fn run_command(main: AnyWindowHandle, id: &str, command: NoteCommand, cx: &mut AsyncApp) {
    let id = id.to_string();
    cx.update(|cx| {
        let stores = cx.global::<AppState>().stores.clone();
        let _ = main.update(cx, |_, window, cx| {
            crate::views::notes::run(&stores, &id, command, window, cx)
        });
    });
}

trait OpsOf {
    fn update_return_ops(&mut self) -> Option<Vec<serde_json::Value>>;
}

impl OpsOf for App {
    fn update_return_ops(&mut self) -> Option<Vec<serde_json::Value>> {
        doc(self).map(|d| d.to_ops())
    }
}
