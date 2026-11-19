//! Notes: the notes list, and the note editor.
//!
//! * [`area`]: what the main window shows for the Notes section: the list
//!   pane for All Notes, a note's pane for a note.
//! * [`list`]: All Notes, searchable, pinned first, then in the phone's
//!   time groups.
//! * [`pane`]: a note: its title, the editor, pages, attachments,
//!   recordings, dictation, the AI actions, and autosave.
//! * [`doc`]: the editor's document (blocks with inline marks) and its
//!   mapping to and from the Quill ops `notes.get` and `notes.save` carry.
//! * [`editor`]: the editor itself, its editing rules, IME, undo, Find.
//! * [`element`]: how it draws, on GPUI Kit's editor host.
//!
//! [`run`] carries out a note's commands for every place that offers them
//! (the sidebar's rows, the list's rows, the note's own More menu).

pub mod area;
pub mod audio;
pub mod doc;
pub mod editor;
#[cfg(test)]
mod editor_tests;
pub mod element;
pub mod list;
pub mod pane;
pub mod recorder;

use conduit_components::theme::{ConduitTheme, with_alpha};
use conduit_protocol::{NoteOpen, NotePin, NoteRef, NoteSave, NoteSummary, NoticeLevel, methods};
use gpui_kit::component::native_menu::NativeMenu;
use gpui_kit::{Action, App, AsyncApp, ClipboardItem, Hsla, Window};

use crate::l10n::{ActiveL10n as _, L10n};
use crate::shell::sheet::{SheetSpec, present_sheet};
use crate::stores::Stores;
use crate::stores::navigation::{AreaItem, Selection};

/// The fills behind Find's matches and behind the current one (as Find in
/// Chat paints them).
pub fn find_fills(t: &ConduitTheme) -> (Hsla, Hsla) {
    let text = t.roles.text;
    if t.dark {
        (with_alpha(text, 0.2), with_alpha(text, 0.46))
    } else {
        (with_alpha(text, 0.1), with_alpha(text, 0.3))
    }
}

/// A note's commands, as its context menu offers them (the phone's: Open,
/// Copy, Pin, Share, Delete).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum NoteCommand {
    Open,
    Copy,
    Pin,
    Unpin,
    Share,
    Delete,
}

/// A note's context menu action: `command` on `note_id`.
#[derive(Clone, Debug, PartialEq, Action)]
#[action(namespace = conduit_notes, no_json)]
pub struct NoteMenu {
    pub note_id: String,
    pub command: NoteCommand,
}

/// File › New Note (and ⌘N while the Notes section is shown).
#[derive(Clone, Debug, PartialEq, Default, Action)]
#[action(namespace = conduit_notes, no_json)]
pub struct NewNote;

/// The commands `note` offers, in order: Open, Copy, Pin or Unpin, Share
/// Access… (a note the account may share), Delete… (one it may edit).
pub fn commands(note: &NoteSummary) -> Vec<NoteCommand> {
    let mut out = vec![NoteCommand::Open, NoteCommand::Copy];
    out.push(if note.pinned {
        NoteCommand::Unpin
    } else {
        NoteCommand::Pin
    });
    if note.can_share {
        out.push(NoteCommand::Share);
    }
    if note.can_edit {
        out.push(NoteCommand::Delete);
    }
    out
}

pub fn command_label(command: NoteCommand, l: &L10n) -> String {
    match command {
        NoteCommand::Open => l.library_note_open(),
        NoteCommand::Copy => l.copy(),
        NoteCommand::Pin => l.pin(),
        NoteCommand::Unpin => l.unpin(),
        NoteCommand::Share => l.desktop_share_access_ellipsis(),
        NoteCommand::Delete => l.desktop_delete_ellipsis(),
    }
}

/// `note`'s context menu: Open, Copy, Pin; Share Access…; Delete…
pub fn note_menu(note: &NoteSummary, l: &L10n) -> NativeMenu {
    let mut menu = NativeMenu::new();
    for command in commands(note) {
        if matches!(command, NoteCommand::Share | NoteCommand::Delete) {
            menu = menu.separator();
        }
        menu = menu.menu(
            command_label(command, l),
            Box::new(NoteMenu {
                note_id: note.id.clone(),
                command,
            }),
        );
    }
    menu
}

/// The summary the account's list holds for `id`.
pub fn summary(stores: &Stores, id: &str, cx: &App) -> Option<NoteSummary> {
    stores.areas.read(cx).note(id).cloned()
}

/// Carries out `command` on note `id`.
pub fn run(stores: &Stores, id: &str, command: NoteCommand, window: &mut Window, cx: &mut App) {
    match command {
        NoteCommand::Open => stores
            .navigation
            .update(cx, |n, cx| n.open_item(AreaItem::Note(id.to_string()), cx)),
        NoteCommand::Copy => copy(stores, id, cx),
        NoteCommand::Pin | NoteCommand::Unpin => {
            set_pinned(stores, id, command == NoteCommand::Pin, cx)
        }
        NoteCommand::Share => {
            let title = summary(stores, id, cx)
                .map(|n| n.title)
                .filter(|t| !t.trim().is_empty())
                .unwrap_or_else(|| cx.l10n().untitled());
            crate::views::access_sheet::open_for_note(stores.clone(), id, title, window, cx);
        }
        NoteCommand::Delete => confirm_delete(stores, id, window, cx),
    }
}

/// Copies the note's markdown, as the phone's Copy does.
fn copy(stores: &Stores, id: &str, cx: &mut App) {
    let rpc = stores.connection.read(cx).rpc();
    let call = rpc.call::<methods::NotesGet>(&NoteOpen {
        id: id.to_string(),
        page_id: None,
    });
    let toasts = stores.toasts.clone();
    cx.spawn(async move |cx: &mut AsyncApp| {
        let result = call.await;
        cx.update(|cx| {
            let l = cx.l10n().clone();
            match result {
                Ok(found) => {
                    let markdown = found.note.map(|n| n.markdown).unwrap_or_default();
                    cx.write_to_clipboard(ClipboardItem::new_string(markdown));
                    toasts.update(cx, |t, cx| {
                        t.show(NoticeLevel::Info, l.note_copied_to_clipboard(), cx)
                    });
                }
                Err(e) => {
                    log::warn!("notes.get for Copy: {e}");
                    toasts.update(cx, |t, cx| {
                        t.show(NoticeLevel::Error, l.error_message(), cx)
                    });
                }
            }
        });
    })
    .detach();
}

/// Pins or unpins the note.
pub fn set_pinned(stores: &Stores, id: &str, pinned: bool, cx: &mut App) {
    let rpc = stores.connection.read(cx).rpc();
    let call = rpc.call::<methods::NotesSetPinned>(&NotePin {
        id: id.to_string(),
        pinned,
    });
    let (toasts, areas) = (stores.toasts.clone(), stores.areas.clone());
    cx.spawn(async move |cx: &mut AsyncApp| {
        let result = call.await;
        cx.update(|cx| match result {
            Ok(_) => areas.update(cx, |a, cx| {
                a.refresh(crate::stores::navigation::Area::Notes, cx)
            }),
            Err(e) => {
                log::warn!("notes.setPinned: {e}");
                let text = cx.l10n().error_message();
                toasts.update(cx, |t, cx| t.show(NoticeLevel::Error, text, cx));
            }
        });
    })
    .detach();
}

/// Delete…: asks, then deletes; a note shown goes, and All Notes shows.
fn confirm_delete(stores: &Stores, id: &str, window: &mut Window, cx: &mut App) {
    let l = cx.l10n().clone();
    let title = summary(stores, id, cx)
        .map(|n| n.title)
        .filter(|t| !t.trim().is_empty())
        .unwrap_or_else(|| l.untitled());
    let spec = SheetSpec::new(
        l.desktop_delete_note_title(&title),
        l.desktop_delete_note_message(),
        l.delete(),
        l.cancel(),
    )
    .destructive();
    let ask = present_sheet(window, spec, cx);
    let stores = stores.clone();
    let id = id.to_string();
    cx.spawn(async move |cx: &mut AsyncApp| {
        if !ask.await {
            return;
        }
        let call = cx.update(|cx| {
            stores
                .connection
                .read(cx)
                .rpc()
                .call::<methods::NotesDelete>(&NoteRef { id: id.clone() })
        });
        let result = call.await;
        cx.update(|cx| match result {
            Ok(_) => {
                // Edits not saved yet go with the note.
                let pane = cx
                    .try_global::<crate::AppState>()
                    .and_then(|s| s.main_view.clone())
                    .and_then(|v| {
                        v.read(cx)
                            .area_pane
                            .read(cx)
                            .notes
                            .read(cx)
                            .note_pane()
                            .cloned()
                    });
                if let Some(pane) = pane.filter(|p| p.read(cx).shows(&id)) {
                    pane.update(cx, |p, cx| p.forget_edits(cx));
                }
                let shown = stores.navigation.read(cx).selection().clone()
                    == Selection::Area(AreaItem::Note(id.clone()));
                if shown {
                    stores
                        .navigation
                        .update(cx, |n, cx| n.open_item(AreaItem::AllNotes, cx));
                }
                stores.areas.update(cx, |a, cx| {
                    a.refresh(crate::stores::navigation::Area::Notes, cx)
                });
            }
            Err(e) => {
                log::warn!("notes.delete: {e}");
                let text = cx.l10n().desktop_note_delete_failed();
                stores
                    .toasts
                    .update(cx, |t, cx| t.show(NoticeLevel::Error, text, cx));
            }
        });
    })
    .detach();
}

/// New Note: a note named for today (as the phone names it), opened in
/// its pane with the caret in its text.
pub fn new_note(stores: &Stores, cx: &mut App) {
    let rpc = stores.connection.read(cx).rpc();
    let asked_under = stores.accounts.read(cx).scope_key();
    let call = rpc.call::<methods::NotesSave>(&NoteSave {
        id: None,
        title: chrono::Local::now().format("%Y-%m-%d").to_string(),
        ops: Some(vec![serde_json::json!({ "insert": "\n" })]),
        page_id: None,
        base_ops: None,
        // Made under the account shown, or refused (a switch in flight).
        account_id: stores.accounts.read(cx).active().map(|a| a.id.clone()),
    });
    let stores = stores.clone();
    cx.spawn(async move |cx: &mut AsyncApp| {
        let result = call.await;
        cx.update(|cx| match result {
            // Answered after another account took charge: the note made
            // under the last one opens in nobody's window.
            Ok(_) if stores.accounts.read(cx).scope_key() != asked_under => {}
            Ok(detail) => {
                area::focus_body_next(cx);
                stores.navigation.update(cx, |n, cx| {
                    n.open_item(AreaItem::Note(detail.summary.id.clone()), cx)
                });
                stores.areas.update(cx, |a, cx| {
                    a.refresh(crate::stores::navigation::Area::Notes, cx)
                });
            }
            Err(e) => {
                log::warn!("notes.save (new): {e}");
                let text = cx.l10n().desktop_note_create_failed();
                stores
                    .toasts
                    .update(cx, |t, cx| t.show(NoticeLevel::Error, text, cx));
            }
        });
    })
    .detach();
}
