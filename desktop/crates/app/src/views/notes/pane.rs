//! A note's pane: its title, the editor ([`NoteEditor`]), and what the
//! phone's note editor offers around it.
//!
//! * **Autosave.** An edit is saved after a pause (the phone's 800 ms), at
//!   once when the editor loses focus, before a page switch or an AI
//!   action, when the note is left, and before Conduit quits. The footer
//!   says Edited, Saving… or Saved, with the word and character counts.
//!   Saves go to the page shown, with the page as last loaded as the base
//!   of the phone's file-link merge (`notes.save` `baseOps`), so a
//!   recording attached meanwhile is kept.
//! * **Refusals.** A save the server refuses because the account may no
//!   longer edit the note, or because the page was removed elsewhere,
//!   keeps the text read-only in place with Save as My Own Note and
//!   Discard Changes, the phone's choices. A note deleted elsewhere is not
//!   refused: the daemon keeps the text as a new note
//!   (`NoteDetail.recoveredFrom`), and the pane says so.
//! * **Read-only notes** (shared with the account to read) say who shared
//!   them and cannot be edited.
//! * **Pages** (Open WebUI 0.12.5): the toolbar's Pages menu shows another
//!   page; adding, renaming and moving pages is done on the web.
//! * **Attachments**: Attach File… (or a drop) uploads files and links
//!   them; a file the note links is a card in the text (Quick Look,
//!   Download, Transcribe for a recording, Remove); files an older server
//!   keeps in a list show under the text.
//! * **Recordings**: Record Audio records through dictation's voice engine; the
//!   daemon keeps the file until the server has it, then attaches it (the
//!   core's controller). Recordings not attached yet show with their
//!   state, Try Again and Remove.
//! * **Dictation** writes into the text at the caret (the dictation engine), each
//!   update replacing the run before, as the phone's.
//! * **AI**: Generate Title and Enhance Note ask the model selected for
//!   chats (`notes.generateTitle`, `notes.enhance`); an enhancement can be
//!   undone (⌘Z).
//! * **Find** (⌘F, ⌘G, ⇧⌘G) searches the note's text.

use std::rc::Rc;
use std::time::{Duration, Instant};

use conduit_components::ActiveConduitTheme as _;
use conduit_components::announce::{Priority, live_text};
use conduit_components::assets::{IconName, icon};
use conduit_components::theme::ConduitTheme;
use conduit_components::views::kit::{
    Button, ClickHandler, IconButton, bare_input, field_frame, raised_fill,
};
use conduit_daemon::RpcError;
use conduit_protocol::{
    NoteAi, NoteAttach, NoteDetach, NoteDetail, NoteFile, NoteOpen, NotePageDto, NoteRecordingAdd,
    NoteRecordingDto, NoteRecordingRef, NoteRecordingState, NoteRef, NoteSave, NoticeLevel, events,
    methods,
};
use gpui_kit::component::input::{Input, InputEvent, InputState};
use gpui_kit::component::native_menu::NativeMenu;
use gpui_kit::prelude::*;
use gpui_kit::{
    Action, AnyElement, App, AsyncApp, ClickEvent, Context, Entity, EventEmitter, ExternalPaths,
    FocusHandle, Focusable as _, FontWeight, Role, SharedString, Subscription, Task, WeakEntity,
    Window, div, px, relative,
};
use serde_json::Value;

use super::audio::{AudioSource, NoteAudio, PlayerWords};
use super::doc::{BlockKind, Doc, FileLink, Mark};
use super::editor::{CardLabels, EditorEvent, FileAction, NoteEditor};
use super::element::is_audio;
use super::recorder::{Phase as RecordPhase, Recorder, RecorderEvent};
use crate::actions::{FindInChat, FindNext, FindPrevious, StopGenerating};
use crate::l10n::{ActiveL10n as _, L10n};
use crate::shell::sheet::{SheetSpec, present_sheet};
use crate::stores::Stores;
use crate::stores::connection::ConnectionEvent;
use crate::stores::dictation::{DictationEvent, DictationStore, Phase as DictationPhase, Target};
use crate::stores::files::{FileRef, OpenWith, open_attachment, stage_file};
use crate::stores::rpc::Rpc;
use crate::voice::InputOverride;

/// Builds a toolbar button's menu when it is clicked.
type MenuBuilder = Rc<dyn Fn(&mut Window, &mut App) -> NativeMenu>;

/// The note pane's key context (⌘N is New Note in it).
pub const NOTE_PANE_CONTEXT: &str = "NotePane";

/// The pause after an edit before it is saved (the phone's).
const SAVE_DELAY: Duration = Duration::from_millis(800);
/// A failed save is tried again after this.
const RETRY_DELAY: Duration = Duration::from_secs(5);
/// A failed save tried again while Quit waits (well within its 3 s).
const QUIT_RETRY_DELAY: Duration = Duration::from_secs(1);

/// What a recording's transcript was asked for: the card it follows, on
/// the page shown then.
struct Transcription {
    block: Option<u64>,
    page: u64,
}
/// The longest a page change waits for a dictation's last words.
const RUN_END_WAIT: Duration = Duration::from_secs(3);
/// The text column's widest.
const COLUMN: f32 = 720.;

/// The pane's commands from its toolbar menus (AI, More, Pages, Format).
#[derive(Clone, Debug, PartialEq, Action)]
#[action(namespace = conduit_notes, no_json)]
pub struct PaneCommand {
    pub note_id: String,
    pub command: Command,
}

#[derive(Clone, Debug, PartialEq)]
pub enum Command {
    GenerateTitle,
    Enhance,
    ShowPage(String),
    Style(BlockKind),
    AttachFile,
    RecordAudio,
    Dictate,
}

#[derive(Clone, Debug, PartialEq)]
pub enum PaneEvent {
    /// Nothing is waiting to be saved now.
    Settled,
    /// The pane shows note `to` now, not `from`: the note was deleted
    /// elsewhere and its text kept as `to`, or the server created a note
    /// made here (a `local:` id) as `to`.
    Moved { from: String, to: String },
}

#[derive(Clone, Debug, PartialEq)]
pub enum Load {
    Loading,
    Ready,
    /// No such note (deleted elsewhere, with nothing unsaved here).
    Missing,
    Failed(String),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SaveState {
    Saved,
    Edited,
    Saving,
    Failed,
}

/// Why the text cannot be saved where it was.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Refusal {
    /// The account may no longer edit the note.
    ReadOnly,
    /// The page was removed elsewhere.
    PageMissing,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AiAction {
    Title,
    Enhance,
}

/// A dictation into the text: where its run starts (flat bytes) and how
/// long it is now.
struct DictationRun {
    anchor: usize,
    len: usize,
    started: bool,
    /// The editor's revision after the run's own last change: any other
    /// edit (typing while dictating) ends the run, so its next words never
    /// replace a range that has moved.
    revision: u64,
}

/// ⌘K's address field.
struct LinkPrompt {
    input: Entity<InputState>,
    current: Option<String>,
}

pub struct NotePane {
    stores: Stores,
    rpc: Rpc,
    id: String,
    pub detail: Option<NoteDetail>,
    pub load: Load,
    pub editor: Entity<NoteEditor>,
    pub title: Entity<InputState>,
    pub page_id: String,
    /// The page as last loaded or saved (the file-link merge's base).
    base_ops: Vec<Value>,
    /// What the server holds now, as far as this pane knows: the dirty
    /// check's baseline.
    saved_ops: Vec<Value>,
    saved_title: String,
    pub save: SaveState,
    pub refused: Option<Refusal>,
    /// The refused draft's choices were offered (Save as My Own Note, Show
    /// Draft): once per refusal.
    pub refusal_offered: bool,
    /// A deleted note's text was kept as this new note.
    pub recovered: bool,
    pub recordings: Vec<NoteRecordingDto>,
    pub ai: Option<AiAction>,
    pub dictation: Entity<DictationStore>,
    run: Option<DictationRun>,
    pub recorder: Option<Entity<Recorder>>,
    /// What records instead of the microphone (a dev build's WAV; the E2E).
    pub record_input: Option<InputOverride>,
    /// Find in Note's field, while open.
    pub find: Option<Entity<InputState>>,
    link: Option<LinkPrompt>,
    focus: FocusHandle,
    focus_body: bool,
    leaving: bool,
    /// The account signed in when the note opened: the only one its text
    /// is saved under.
    opened_under: Option<String>,
    /// conduitd refused the text because another account is active now: it
    /// stays here, unsaved, and is saved once [`Self::opened_under`] is
    /// active again (never under the other account).
    held_for_account: bool,
    /// Counts page loads asked for: an answer for a page (a load, a
    /// refresh, an upload or a file taken out) applies only while no other
    /// page was asked for since.
    page_asked: u64,
    /// Another page is being read over the one shown: the shown one takes
    /// no typing and no refresh until the asked page's answer is in.
    page_loading: bool,
    saving_rev: Option<(u64, String)>,
    save_again: bool,
    waiters: Vec<futures::channel::oneshot::Sender<()>>,
    /// Quit waits on these: told once nothing is saving and no recording,
    /// dictation or recording hand-off is still on its way.
    quit_waiters: Vec<futures::channel::oneshot::Sender<()>>,
    /// A failed save waits to be tried again ([`Self::retry_after`]).
    retrying: bool,
    /// Recordings sent to conduitd (`notes.addRecording`) not answered yet.
    recordings_out: u32,
    /// Counts this pane's saves that landed: a refresh asked before one is
    /// older than what the server holds (a title saved meanwhile).
    saves_landed: u64,
    /// Counts refreshes asked for: only the newest one's answer is taken.
    refresh_asked: u64,
    /// Told when the dictation run ends (its last words are in): a page
    /// change waits for them.
    run_waiters: Vec<futures::channel::oneshot::Sender<()>>,
    last_own_save: Option<Instant>,
    /// Saves wait (the E2E).
    hold: bool,
    /// The note's player: its recordings play in the note.
    pub audio: Entity<NoteAudio>,
    _debounce: Option<Task<()>>,
    _subscriptions: Vec<Subscription>,
}

impl EventEmitter<PaneEvent> for NotePane {}

impl NotePane {
    pub fn new(
        stores: Stores,
        id: String,
        focus_body: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Self {
        let l = cx.l10n().clone();
        let rpc = stores.connection.read(cx).rpc();
        let audio = cx.new(|_| NoteAudio::new());
        let editor = cx.new(|cx| {
            let mut e = NoteEditor::new(window, cx);
            e.set_audio(audio.clone(), cx);
            e.set_placeholder(
                l.desktop_note_body_placeholder().into(),
                l.desktop_note_body().into(),
            );
            e.set_card_labels(CardLabels {
                play: l.video_play().into(),
                pause: l.voice_call_pause().into(),
                position: l.desktop_note_audio_position().into(),
                audio_failed: l.failed_to_load_audio().into(),
                audio_loading: l.desktop_loading().into(),
                quick_look: l.desktop_quick_look().into(),
                download: l.download().into(),
                transcribe: l.desktop_transcribe().into(),
                remove: l.desktop_remove_ellipsis().into(),
                more: l.more().into(),
                audio: l.audio_attachment().into(),
                file: l.attachment_label().into(),
            });
            e
        });
        let title = cx
            .new(|cx| InputState::new(window, cx).placeholder(l.desktop_note_title_placeholder()));
        let dictation = {
            let connection = stores.connection.clone();
            cx.new(|cx| {
                let mut d = DictationStore::for_connection(connection, cx);
                d.set_input(InputOverride::current());
                d.set_target(
                    Target {
                        keeps_recordings: false,
                        ..Target::default()
                    },
                    cx,
                );
                d
            })
        };
        let subscriptions = vec![
            cx.subscribe_in(&editor, window, |this, _, e: &EditorEvent, window, cx| {
                this.on_editor(e, window, cx)
            }),
            cx.subscribe_in(
                &title,
                window,
                |this, _, e: &InputEvent, window, cx| match e {
                    InputEvent::Change => this.edited(cx),
                    InputEvent::PressEnter { .. } => {
                        let focus = this.editor.read(cx).focus.clone();
                        window.focus(&focus, cx);
                    }
                    InputEvent::Blur => this.save_now(cx),
                    _ => {}
                },
            ),
            cx.subscribe_in(&dictation, window, |this, _, e: &DictationEvent, _, cx| {
                this.on_dictation(e, cx)
            }),
            cx.observe(&dictation, |_, _, cx| cx.notify()),
            // A draft held for its account is saved once that account is
            // active again.
            cx.observe(&stores.accounts, |this: &mut Self, accounts, cx| {
                let active = accounts.read(cx).active().map(|a| a.id.clone());
                // Another account in charge: a recording started under the
                // last one stops (the one held-recording check).
                this.playable_changed(cx);
                if this.held_for_account && active.is_some() && active == this.opened_under {
                    this.held_for_account = false;
                    this.save_now(cx);
                }
            }),
            cx.observe(&audio, |_, _, cx| cx.notify()),
            cx.subscribe(&stores.connection, |this, _, e: &ConnectionEvent, cx| {
                if let ConnectionEvent::Daemon(event) = e
                    && let conduit_protocol::Event::NotesChanged(changed) = event.as_ref()
                    && changed.note_id.as_ref().is_none_or(|n| *n == this.id)
                {
                    // Its recordings only when the change names this note.
                    if changed.note_id.is_some() {
                        this.refresh_recordings(cx);
                    }
                    this.changed_elsewhere(cx);
                }
            }),
        ];
        stores.connection.update(cx, |c, _| {
            c.subscribe("note-pane", &[events::NOTES_CHANGED], vec![])
        });
        let opened_under = stores.accounts.read(cx).active().map(|a| a.id.clone());
        let mut this = Self {
            stores,
            rpc,
            id,
            detail: None,
            load: Load::Loading,
            editor,
            title,
            page_id: "main".into(),
            base_ops: vec![],
            saved_ops: vec![],
            saved_title: String::new(),
            save: SaveState::Saved,
            refused: None,
            refusal_offered: false,
            recovered: false,
            recordings: vec![],
            ai: None,
            dictation,
            run: None,
            recorder: None,
            record_input: InputOverride::current(),
            find: None,
            link: None,
            focus: cx.focus_handle(),
            focus_body,
            leaving: false,
            opened_under,
            held_for_account: false,
            page_asked: 0,
            page_loading: false,
            saving_rev: None,
            save_again: false,
            waiters: vec![],
            quit_waiters: vec![],
            retrying: false,
            recordings_out: 0,
            saves_landed: 0,
            refresh_asked: 0,
            run_waiters: vec![],
            last_own_save: None,
            hold: false,
            audio,
            _debounce: None,
            _subscriptions: subscriptions,
        };
        this.open_page(None, window, cx);
        this
    }

    pub fn note_id(&self) -> &str {
        &self.id
    }

    pub fn shows(&self, id: &str) -> bool {
        self.id == id
    }

    fn l(&self, cx: &App) -> L10n {
        cx.l10n().clone()
    }

    /// The note may be edited here: loaded, the account may edit it, and
    /// nothing was refused.
    pub fn editable(&self) -> bool {
        self.load == Load::Ready
            && !self.page_loading
            && self.refused.is_none()
            && self.detail.as_ref().is_some_and(|d| d.summary.can_edit)
            && self.ai != Some(AiAction::Enhance)
    }

    fn resolved_title(&self, cx: &App) -> String {
        let typed = self.title.read(cx).value().trim().to_string();
        if typed.is_empty() {
            cx.l10n().untitled()
        } else {
            typed
        }
    }

    /// Whether the text or title differs from what was saved.
    pub fn dirty(&self, cx: &App) -> bool {
        self.load == Load::Ready
            && (self.editor.read(cx).ops() != self.saved_ops
                || self.resolved_title(cx) != self.saved_title)
    }

    /// Still saving, something to save (a failed save's retry too), a
    /// recording or dictation still to come in or on its way to conduitd, or
    /// a draft held for its account.
    pub fn is_busy(&self) -> bool {
        self.saving_rev.is_some()
            || self._debounce.is_some()
            || self.recorder.is_some()
            || self.run.is_some()
            || self.recordings_out > 0
            || self.held_for_account
    }

    /// The account the note was opened under is the active one (true when
    /// it opened with none known).
    pub fn account_active(&self, cx: &App) -> bool {
        let accounts = self.stores.accounts.read(cx);
        // An account change in flight: not this account yet (conduitd may
        // be on the next one before this window hears).
        if accounts.busy.is_some() {
            return false;
        }
        let Some(opened) = &self.opened_under else {
            return true;
        };
        accounts.active().map(|a| &a.id) == Some(opened)
    }

    /// The account the note was opened under is the active one (true when
    /// it opened with none known), even while an account change is in
    /// flight: the pane's own account may take it back.
    pub fn opened_under_active(&self, cx: &App) -> bool {
        let Some(opened) = &self.opened_under else {
            return true;
        };
        self.stores.accounts.read(cx).active().map(|a| &a.id) == Some(opened)
    }

    pub fn has_refused_draft(&self) -> bool {
        self.refused.is_some()
    }

    /// The title of a draft that could not be saved where it was.
    pub fn refused_draft(&self) -> Option<String> {
        self.refused.map(|_| {
            self.detail
                .as_ref()
                .map(|d| d.summary.title.clone())
                .unwrap_or_default()
        })
    }

    // ── Loading ─────────────────────────────────────────────────────────

    /// Reads page `page` (the main page when None) and shows it.
    fn open_page(&mut self, page: Option<String>, window: &mut Window, cx: &mut Context<Self>) {
        // The page shown takes no typing until the next one is in: its words
        // would be replaced by it.
        if self.load == Load::Ready {
            self.editor.update(cx, |e, cx| e.set_read_only(true, cx));
            self.page_loading = true;
        }
        self.page_asked += 1;
        let asked = self.page_asked;
        let call = self.rpc.call::<methods::NotesGet>(&NoteOpen {
            id: self.id.clone(),
            page_id: page,
        });
        cx.spawn_in(window, async move |this, cx| {
            let result = call.await;
            let _ = this.update_in(cx, |this, window, cx| match result {
                // A later page was asked for: this answer is old.
                _ if this.page_asked != asked => {}
                Ok(found) => {
                    this.page_loading = false;
                    match found.note {
                        Some(detail) => this.show_detail(detail, true, window, cx),
                        None => {
                            this.set_load(Load::Missing, cx);
                            cx.notify();
                        }
                    }
                }
                Err(e) => {
                    this.page_loading = false;
                    log::warn!("notes.get: {e}");
                    this.set_load(Load::Failed(e.to_string()), cx);
                    cx.notify();
                }
            });
        })
        .detach();
    }

    /// Shows `detail` in the editor: the title, the page's text, whether
    /// it may be edited. `fresh`: a newly opened note or page (undo starts
    /// again).
    fn show_detail(
        &mut self,
        detail: NoteDetail,
        fresh: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let title = detail.summary.title.clone();
        self.title
            .update(cx, |t, cx| t.set_value(title.clone(), window, cx));
        let doc = Doc::from_ops(&detail.ops);
        let read_only = !detail.summary.can_edit;
        self.editor.update(cx, |e, cx| {
            e.set_doc(doc, true, cx);
            e.set_read_only(read_only, cx);
        });
        self.page_id = detail.page_id.clone();
        self.base_ops = detail.ops.clone();
        self.saved_ops = self.editor.read(cx).ops();
        self.saved_title = if title.trim().is_empty() {
            cx.l10n().untitled()
        } else {
            title.trim().to_string()
        };
        self.follow_id(&detail.summary.id, cx);
        self.detail = Some(detail);
        self.set_load(Load::Ready, cx);
        self.save = SaveState::Saved;
        if fresh {
            self.refresh_recordings(cx);
            if self.focus_body && !read_only {
                self.focus_body = false;
                let focus = self.editor.read(cx).focus.clone();
                window.focus(&focus, cx);
            }
        }
        cx.notify();
    }

    /// `notes.changed` for this note (or all notes): the text is read again
    /// when nothing here is waiting to be saved; the recordings always.
    fn changed_elsewhere(&mut self, cx: &mut Context<Self>) {
        if self.load != Load::Ready
            || self.page_loading
            || self.saving_rev.is_some()
            || self.dirty(cx)
            || self.refused.is_some()
            || self.ai.is_some()
            || self.run.is_some()
        {
            return;
        }
        // Just after this pane's own save, the change is most likely that
        // save's echo: looked at again once it has passed.
        if let Some(at) = self.last_own_save
            && at.elapsed() < Duration::from_millis(1500)
        {
            let wait = Duration::from_millis(1600) - at.elapsed();
            cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
                cx.background_executor().timer(wait).await;
                let _ = this.update(cx, |this, cx| this.changed_elsewhere(cx));
            })
            .detach();
            return;
        }
        let call = self.rpc.call::<methods::NotesGet>(&NoteOpen {
            id: self.id.clone(),
            page_id: Some(self.page_id.clone()),
        });
        let revision = self.editor.read(cx).revision();
        let asked = self.page_asked;
        let landed = self.saves_landed;
        self.refresh_asked += 1;
        let refresh = self.refresh_asked;
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result = call.await;
            let _ = this.update(cx, |this, cx| {
                if this.page_asked != asked
                    || this.page_loading
                    || this.saves_landed != landed
                    || this.refresh_asked != refresh
                    || this.editor.read(cx).revision() != revision
                    || this.dirty(cx)
                {
                    return;
                }
                match result {
                    Ok(found) => match found.note {
                        Some(detail) => this.adopt_quietly(detail, cx),
                        None => {
                            // Deleted elsewhere, with nothing unsaved here.
                            this.set_load(Load::Missing, cx);
                            cx.notify();
                        }
                    },
                    Err(e) => log::warn!("notes.get (refresh): {e}"),
                }
            });
        })
        .detach();
    }

    /// Takes in a stored copy that differs (another device's edit, a
    /// recording attached), keeping the caret where it can.
    fn adopt_quietly(&mut self, detail: NoteDetail, cx: &mut Context<Self>) {
        let doc = Doc::from_ops(&detail.ops);
        let same_text = doc.to_ops() == self.saved_ops;
        let title = detail.summary.title.trim().to_string();
        let same_title = title == self.saved_title || title.is_empty();
        let read_only = !detail.summary.can_edit;
        if !same_text {
            self.editor.update(cx, |e, cx| e.set_doc(doc, true, cx));
            self.saved_ops = self.editor.read(cx).ops();
            self.base_ops = detail.ops.clone();
        }
        if !same_title {
            self.saved_title = title.clone();
            if let Some(window) = cx.windows().first().copied() {
                let input = self.title.clone();
                let _ = window.update(cx, |_, window, cx| {
                    input.update(cx, |t, cx| t.set_value(title.clone(), window, cx))
                });
            }
        }
        self.editor
            .update(cx, |e, cx| e.set_read_only(read_only, cx));
        self.follow_id(&detail.summary.id, cx);
        self.detail = Some(detail);
        self.playable_changed(cx);
        cx.notify();
    }

    /// The daemon answers for a `local:` note the outbox has since created
    /// on the server with the server's id: the pane, and the sidebar's
    /// selection, go with it (later saves and refreshes, the toolbar's
    /// title and the note's menu all look the note up by its id).
    fn follow_id(&mut self, id: &str, cx: &mut Context<Self>) {
        if id.is_empty() || id == self.id {
            return;
        }
        let from = std::mem::replace(&mut self.id, id.to_string());
        cx.emit(PaneEvent::Moved {
            from,
            to: id.to_string(),
        });
    }

    // ── Saving ──────────────────────────────────────────────────────────

    fn on_editor(&mut self, e: &EditorEvent, window: &mut Window, cx: &mut Context<Self>) {
        match e {
            EditorEvent::Edited => {
                // A card removed (Remove, ⌫, undo or redo) takes its Play with it.
                self.playable_changed(cx);
                // Typed while dictating: the dictation ends, keeping the words
                // it put in, and its later words never land over the typing.
                if self
                    .run
                    .as_ref()
                    .is_some_and(|run| run.revision != self.editor.read(cx).revision())
                {
                    self.end_run();
                    if self.dictation.read(cx).is_active() {
                        self.dictation.update(cx, |d, cx| d.stop(cx));
                    }
                }
                self.edited(cx)
            }
            EditorEvent::Selected => cx.notify(),
            EditorEvent::Blurred => self.save_now(cx),
            EditorEvent::LinkRequested { current } => self.ask_link(current.clone(), window, cx),
            EditorEvent::OpenLink(url) => {
                if url.starts_with("http://")
                    || url.starts_with("https://")
                    || url.starts_with("mailto:")
                {
                    cx.open_url(url);
                }
            }
            EditorEvent::File(link, action) => self.file_action(link.clone(), *action, window, cx),
        }
    }

    /// An edit: Edited now, saved after a pause.
    fn edited(&mut self, cx: &mut Context<Self>) {
        if self.load != Load::Ready || self.refused.is_some() {
            return;
        }
        if !self.dirty(cx) {
            if self.save == SaveState::Edited {
                self.save = SaveState::Saved;
                cx.notify();
            }
            return;
        }
        if self.save != SaveState::Saving {
            self.save = SaveState::Edited;
        }
        self._debounce = Some(
            cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
                cx.background_executor().timer(SAVE_DELAY).await;
                let _ = this.update(cx, |this, cx| {
                    this._debounce = None;
                    this.save_now(cx);
                });
            }),
        );
        cx.notify();
    }

    /// Saves now what differs from the server's copy.
    pub fn save_now(&mut self, cx: &mut Context<Self>) {
        self._debounce = None;
        // This save is the retry any failed one waited for.
        self.retrying = false;
        if self.hold {
            return;
        }
        // Opened under another account than the one active now: its text is
        // held, not sent, so it never reaches the other account (which may
        // hold the same note, shared with it). A list being read again names
        // nobody: no change.
        let active = self.stores.accounts.read(cx).active().map(|a| a.id.clone());
        if self.opened_under.is_some() && active.is_some() && active != self.opened_under {
            self.held_for_account = true;
        }
        // Held for its account: nothing is sent until that account is back
        // (those waiting for a save are not kept waiting for it).
        if self.held_for_account {
            self.settle(cx);
            return;
        }
        if self.load != Load::Ready
            || self.refused.is_some()
            || !self.detail.as_ref().is_some_and(|d| d.summary.can_edit)
        {
            self.settle(cx);
            return;
        }
        if self.saving_rev.is_some() {
            self.save_again = true;
            return;
        }
        if !self.dirty(cx) {
            if self.save != SaveState::Saved {
                self.save = SaveState::Saved;
                cx.notify();
            }
            self.settle(cx);
            return;
        }
        let ops = self.editor.read(cx).ops();
        let title = self.resolved_title(cx);
        let revision = self.editor.read(cx).revision();
        self.saving_rev = Some((revision, title.clone()));
        self.save = SaveState::Saving;
        cx.notify();
        let call = self.rpc.call::<methods::NotesSave>(&NoteSave {
            id: Some(self.id.clone()),
            title: title.clone(),
            ops: Some(ops.clone()),
            page_id: Some(self.page_id.clone()),
            base_ops: Some(self.base_ops.clone()),
            account_id: self.opened_under.clone(),
        });
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result = call.await;
            let _ = this.update(cx, |this, cx| this.saved(result, ops, title, revision, cx));
        })
        .detach();
    }

    fn saved(
        &mut self,
        result: Result<NoteDetail, RpcError>,
        ops: Vec<Value>,
        title: String,
        revision: u64,
        cx: &mut Context<Self>,
    ) {
        self.saving_rev = None;
        self.last_own_save = Some(Instant::now());
        match result {
            Ok(detail) => {
                self.saves_landed += 1;
                if detail.recovered_from.is_some() {
                    self.recovered = true;
                }
                self.follow_id(&detail.summary.id, cx);
                self.saved_ops = ops;
                self.saved_title = title;
                self.base_ops = detail.ops.clone();
                // Files the stored page gained meanwhile (a recording
                // attached) show as cards, as the phone's editor puts them
                // in: those the save kept that it did not send.
                let sent: Vec<String> = Doc::from_ops(&self.saved_ops)
                    .blocks
                    .iter()
                    .filter_map(|b| b.file_link().map(|f| f.id))
                    .collect();
                let stored = Doc::from_ops(&detail.ops);
                let gained: Vec<FileLink> = stored
                    .blocks
                    .iter()
                    .filter_map(|b| b.file_link())
                    .filter(|f| !sent.contains(&f.id))
                    .collect();
                self.detail = Some(detail);
                self.playable_changed(cx);
                self.save = SaveState::Saved;
                if !gained.is_empty() {
                    self.editor.update(cx, |e, cx| e.append_cards(&gained, cx));
                }
                let _ = revision;
                if self.dirty(cx) {
                    self.save = SaveState::Edited;
                    self.save_again = true;
                }
            }
            Err(e) if is_refusal(&e, "readOnly") => {
                self.refused = Some(Refusal::ReadOnly);
                self.refusal_offered = false;
                self.editor.update(cx, |e, cx| e.set_read_only(true, cx));
                self.save = SaveState::Failed;
                self.save_again = false;
            }
            Err(e) if is_reason(&e, "account") => {
                // Opened under an account no longer active: the text never
                // goes to the next one. It stays here, unsaved, until its own
                // account is back ([`Self::held_for_account`]). A refusal
                // answered once that account is back already (sent while the
                // other was active) is tried again, as a failed save is.
                log::warn!("notes.save: {e}");
                self.save = SaveState::Failed;
                self.save_again = false;
                let active = self.stores.accounts.read(cx).active().map(|a| a.id.clone());
                if active.is_some() && active == self.opened_under {
                    self.retry_later(cx);
                } else {
                    self.held_for_account = true;
                }
            }
            Err(e) if is_refusal(&e, "page") => {
                self.refused = Some(Refusal::PageMissing);
                self.refusal_offered = false;
                self.editor.update(cx, |e, cx| e.set_read_only(true, cx));
                self.save = SaveState::Failed;
                self.save_again = false;
            }
            Err(e) => {
                log::warn!("notes.save: {e}");
                self.save = SaveState::Failed;
                self.retry_later(cx);
            }
        }
        cx.notify();
        if std::mem::take(&mut self.save_again) {
            self.save_now(cx);
        } else {
            self.settle(cx);
        }
    }

    /// A failed save is tried again after a while (or on the next edit);
    /// soon while Quit waits on it, within Quit's wait.
    fn retry_later(&mut self, cx: &mut Context<Self>) {
        let delay = if self.quit_waiters.is_empty() {
            RETRY_DELAY
        } else {
            QUIT_RETRY_DELAY
        };
        self.retry_after(delay, cx);
    }

    /// [`Self::retry_later`], after `delay`. Quit waits for the retry (its
    /// text is not saved yet).
    fn retry_after(&mut self, delay: Duration, cx: &mut Context<Self>) {
        self.retrying = true;
        self._debounce = Some(
            cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
                cx.background_executor().timer(delay).await;
                let _ = this.update(cx, |this, cx| {
                    this._debounce = None;
                    this.save_now(cx);
                });
            }),
        );
    }

    /// Nothing is saving: those waiting for it hear so.
    fn settle(&mut self, cx: &mut Context<Self>) {
        if self.saving_rev.is_some() {
            return;
        }
        for waiter in self.waiters.drain(..) {
            let _ = waiter.send(());
        }
        // A failed save still to be tried again keeps Quit waiting too
        // (within its wait).
        if !self.audio_pending() && !self.retrying {
            for waiter in self.quit_waiters.drain(..) {
                let _ = waiter.send(());
            }
        }
        cx.emit(PaneEvent::Settled);
    }

    /// Resolves once the dictation run has ended (at once with none).
    fn run_ended(&mut self) -> futures::channel::oneshot::Receiver<()> {
        let (tx, rx) = futures::channel::oneshot::channel();
        if self.run.is_some() {
            self.run_waiters.push(tx);
        } else {
            let _ = tx.send(());
        }
        rx
    }

    /// The dictation run is over: no later words land in the text, and those
    /// waiting for its end hear so.
    fn end_run(&mut self) {
        self.run = None;
        for waiter in self.run_waiters.drain(..) {
            let _ = waiter.send(());
        }
    }

    /// A recording or dictation still to come in, or a recording on its way
    /// to conduitd.
    fn audio_pending(&self) -> bool {
        self.recorder.is_some() || self.run.is_some() || self.recordings_out > 0
    }

    /// Quit: the note is left (a recording and dictation end), what is
    /// unsaved is saved, and the future resolves once that has landed and
    /// the recording's audio or the dictation's last words are in.
    pub fn finish_for_quit(
        &mut self,
        cx: &mut Context<Self>,
    ) -> impl std::future::Future<Output = ()> + use<> {
        let (tx, rx) = futures::channel::oneshot::channel();
        self.quit_waiters.push(tx);
        self.leave(cx);
        async move {
            let _ = rx.await;
        }
    }

    /// Saves now; resolves once the save has landed (or there was nothing
    /// to save).
    pub fn flush(
        &mut self,
        cx: &mut Context<Self>,
    ) -> impl std::future::Future<Output = ()> + use<> {
        let (tx, rx) = futures::channel::oneshot::channel();
        self.waiters.push(tx);
        self.save_now(cx);
        async move {
            let _ = rx.await;
        }
    }

    /// The note is left (another note or area shown): dictation and a
    /// recording end, and what is unsaved is saved.
    /// Shown again after it was left (its save still out): no longer
    /// leaving.
    pub fn shown_again(&mut self, cx: &mut Context<Self>) {
        self.leaving = false;
        cx.notify();
    }

    pub fn leave(&mut self, cx: &mut Context<Self>) {
        self.leaving = true;
        // A pane whose save is still out stays alive a while after it is
        // left: its recording stops now, not when the pane goes.
        self.stop_audio(cx);
        if self.dictation.read(cx).is_active() {
            self.dictation.update(cx, |d, cx| d.stop(cx));
        }
        if let Some(recorder) = &self.recorder {
            recorder.update(cx, |r, cx| r.stop(cx));
        }
        self.save_now(cx);
    }

    /// The player lets go of its recording: playing stops, and a download
    /// still out is dropped with it (its answer finds no recording held).
    fn stop_audio(&mut self, cx: &mut Context<Self>) {
        if self.audio.read(cx).current_key().is_some() {
            self.audio.update(cx, |a, cx| a.stop(cx));
        }
    }

    /// The user deleted this note here: what was not saved yet goes with
    /// it (it is not kept as a new note, as a note deleted elsewhere is).
    pub fn forget_edits(&mut self, cx: &mut Context<Self>) {
        self._debounce = None;
        self.retrying = false;
        self.hold = true;
        self.refused = None;
        self.saved_ops = self.editor.read(cx).ops();
        self.saved_title = self.resolved_title(cx);
        self.save = SaveState::Saved;
        self.settle(cx);
    }

    /// Save as My Own Note: the refused text becomes a note of its own,
    /// which opens.
    pub fn save_as_own_note(&mut self, cx: &mut Context<Self>) {
        // Made only under the account the note was opened under.
        if !self.account_active(cx) {
            return;
        }
        let ops = self.editor.read(cx).ops();
        let title = self.resolved_title(cx);
        let call = self.rpc.call::<methods::NotesSave>(&NoteSave {
            id: None,
            title,
            ops: Some(ops),
            page_id: None,
            base_ops: None,
            account_id: self.opened_under.clone(),
        });
        let stores = self.stores.clone();
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result = call.await;
            let _ = this.update(cx, |this, cx| match result {
                Ok(detail) => {
                    // The draft is kept: nothing is left to save here.
                    this.refused = None;
                    this.saved_ops = this.editor.read(cx).ops();
                    this.settle(cx);
                    let id = detail.summary.id;
                    stores.navigation.update(cx, |n, cx| {
                        n.open_item(crate::stores::navigation::AreaItem::Note(id), cx)
                    });
                }
                // Refused as another account's (conduitd switched before this
                // window heard): the draft stays held, offered again under
                // its own account.
                Err(e) if is_reason(&e, "account") => {
                    log::warn!("notes.save (own note): {e}");
                    this.refusal_offered = false;
                }
                Err(e) => {
                    log::warn!("notes.save (own note): {e}");
                    let text = cx.l10n().error_message();
                    stores
                        .toasts
                        .update(cx, |t, cx| t.show(NoticeLevel::Error, text, cx));
                }
            });
        })
        .detach();
    }

    /// Discard Changes: the refused text goes; the note shows as stored.
    pub fn discard_changes(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.refused = None;
        self.save = SaveState::Saved;
        let page = self.page_id.clone();
        self.set_load(Load::Loading, cx);
        self.open_page(Some(page), window, cx);
        self.settle(cx);
        cx.notify();
    }

    // ── Pages ───────────────────────────────────────────────────────────

    pub fn pages(&self) -> &[NotePageDto] {
        self.detail.as_ref().map_or(&[], |d| d.pages.as_slice())
    }

    /// Shows page `page`, after saving the one shown.
    pub fn show_page(&mut self, page: String, window: &mut Window, cx: &mut Context<Self>) {
        if page == self.page_id || self.ai.is_some() {
            return;
        }
        if self.dictation.read(cx).is_active() {
            self.dictation.update(cx, |d, cx| d.stop(cx));
        }
        // A dictation's last words go on the page they were said on: the
        // page changes once they are in (3 s at most), and saved.
        let ended = self.run_ended();
        let timer = cx.background_executor().timer(RUN_END_WAIT);
        cx.spawn_in(window, async move |this, cx| {
            let _ = futures::future::select(ended, Box::pin(timer)).await;
            let Ok(flushed) = this.update(cx, |this, cx| {
                this.end_run();
                this.flush(cx)
            }) else {
                return;
            };
            flushed.await;
            let _ = this.update_in(cx, |this, window, cx| {
                // A refused save keeps the text on its page.
                if this.refused.is_some() || this.dirty(cx) {
                    return;
                }
                this.open_page(Some(page), window, cx);
            });
        })
        .detach();
    }

    // ── AI ──────────────────────────────────────────────────────────────

    pub fn generate_title(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.ai.is_some() || !self.editable() {
            return;
        }
        let ops = self.editor.read(cx).ops();
        self.ai = Some(AiAction::Title);
        cx.notify();
        let call = self
            .rpc
            .call::<methods::NotesGenerateTitle>(&NoteAi { ops, model: None });
        cx.spawn_in(window, async move |this, cx| {
            let result = call.await;
            let _ = this.update_in(cx, |this, window, cx| {
                this.ai = None;
                let l = this.l(cx);
                match result {
                    Ok(t) => {
                        this.title
                            .update(cx, |input, cx| input.set_value(t.title, window, cx));
                        this.edited(cx);
                    }
                    Err(e) => {
                        let text = if is_reason(&e, "empty") {
                            l.no_content_to_generate_title()
                        } else {
                            l.failed_to_generate_title()
                        };
                        this.toast(NoticeLevel::Error, text, cx);
                    }
                }
                cx.notify();
            });
        })
        .detach();
    }

    pub fn enhance(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.ai.is_some() || !self.editable() {
            return;
        }
        let ops = self.editor.read(cx).ops();
        self.ai = Some(AiAction::Enhance);
        self.editor.update(cx, |e, cx| e.set_read_only(true, cx));
        cx.notify();
        let call = self
            .rpc
            .call::<methods::NotesEnhance>(&NoteAi { ops, model: None });
        cx.spawn_in(window, async move |this, cx| {
            let result = call.await;
            let _ = this.update_in(cx, |this, _, cx| {
                this.ai = None;
                let can_edit = this.detail.as_ref().is_some_and(|d| d.summary.can_edit);
                this.editor.update(cx, |e, cx| {
                    e.set_read_only(!can_edit || this.refused.is_some() || this.page_loading, cx)
                });
                let l = this.l(cx);
                match result {
                    Ok(body) => {
                        // One step: ⌘Z takes the enhancement back.
                        let doc = Doc::from_ops(&body.ops);
                        this.editor.update(cx, |e, cx| e.set_doc(doc, false, cx));
                        this.toast(NoticeLevel::Info, l.desktop_note_enhanced(), cx);
                    }
                    Err(e) => {
                        let text = if is_reason(&e, "empty") {
                            l.no_content_to_enhance()
                        } else {
                            l.failed_to_enhance_note()
                        };
                        this.toast(NoticeLevel::Error, text, cx);
                    }
                }
                cx.notify();
            });
        })
        .detach();
    }

    fn toast(&self, level: NoticeLevel, text: String, cx: &mut App) {
        self.stores
            .toasts
            .update(cx, |t, cx| t.show(level, text, cx));
    }

    // ── Link ────────────────────────────────────────────────────────────

    fn ask_link(&mut self, current: Option<String>, window: &mut Window, cx: &mut Context<Self>) {
        let placeholder = cx.l10n().desktop_link_placeholder();
        let input = cx.new(|cx| InputState::new(window, cx).placeholder(placeholder));
        if let Some(url) = &current {
            input.update(cx, |i, cx| i.set_value(url.clone(), window, cx));
        }
        let sub = cx.subscribe_in(&input, window, |this, input, e: &InputEvent, window, cx| {
            if let InputEvent::PressEnter { .. } = e {
                let url = input.read(cx).value().to_string();
                this.apply_link(Some(url), window, cx);
            }
        });
        self._subscriptions.push(sub);
        let focus = input.read(cx).focus_handle(cx);
        window.focus(&focus, cx);
        self.link = Some(LinkPrompt { input, current });
        cx.notify();
    }

    fn apply_link(&mut self, url: Option<String>, window: &mut Window, cx: &mut Context<Self>) {
        self.link = None;
        let url = url.map(normalize_url);
        self.editor.update(cx, |e, cx| e.set_link(url, cx));
        let focus = self.editor.read(cx).focus.clone();
        window.focus(&focus, cx);
        cx.notify();
    }

    /// ⌘K's field, while it asks (the E2E).
    pub fn link_field_for_tests(&self) -> Option<Entity<InputState>> {
        self.link.as_ref().map(|l| l.input.clone())
    }

    /// Types `url` into ⌘K's field and applies it (the E2E).
    pub fn apply_link_for_tests(&mut self, url: &str, window: &mut Window, cx: &mut Context<Self>) {
        self.apply_link(Some(url.to_string()), window, cx);
    }

    /// Holds autosave (the E2E deletes the note behind a waiting change);
    /// releasing it saves.
    pub fn hold_saves_for_tests(&mut self, hold: bool, cx: &mut Context<Self>) {
        self.hold = hold;
        if !hold {
            self.save_now(cx);
        }
    }

    fn cancel_link(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.link = None;
        let focus = self.editor.read(cx).focus.clone();
        window.focus(&focus, cx);
        cx.notify();
    }

    // ── Find ────────────────────────────────────────────────────────────

    pub fn open_find(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let input = match &self.find {
            Some(input) => input.clone(),
            None => {
                let placeholder = cx.l10n().desktop_find_in_note();
                let input = cx.new(|cx| InputState::new(window, cx).placeholder(placeholder));
                let sub =
                    cx.subscribe_in(
                        &input,
                        window,
                        |this, input, e: &InputEvent, _, cx| match e {
                            InputEvent::Change => {
                                let query = input.read(cx).value().to_string();
                                this.editor.update(cx, |e, cx| e.find(&query, cx));
                            }
                            InputEvent::PressEnter { secondary, .. } => {
                                let forward = !secondary;
                                this.editor.update(cx, |e, cx| e.find_step(forward, cx));
                            }
                            _ => {}
                        },
                    );
                self._subscriptions.push(sub);
                // The editor's selection seeds it, as ⌘E would.
                let selected = self.editor.read(cx).selected_text();
                if !selected.is_empty() && !selected.contains('\n') {
                    input.update(cx, |i, cx| i.set_value(selected.clone(), window, cx));
                    self.editor.update(cx, |e, cx| e.find(&selected, cx));
                }
                self.find = Some(input.clone());
                input
            }
        };
        let focus = input.read(cx).focus_handle(cx);
        window.focus(&focus, cx);
        cx.notify();
    }

    /// Find in Note's query (the E2E types it).
    pub fn type_find(&mut self, query: &str, window: &mut Window, cx: &mut Context<Self>) {
        self.open_find(window, cx);
        if let Some(input) = &self.find {
            input.update(cx, |i, cx| i.set_value(query.to_string(), window, cx));
        }
        self.editor.update(cx, |e, cx| e.find(query, cx));
    }

    pub fn close_find(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.find = None;
        self.editor.update(cx, |e, cx| e.end_find(cx));
        let focus = self.editor.read(cx).focus.clone();
        window.focus(&focus, cx);
        cx.notify();
    }

    // ── Dictation ───────────────────────────────────────────────────────

    pub fn toggle_dictation(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if !self.editable() {
            return;
        }
        if self.dictation.read(cx).is_active() {
            self.dictation.update(cx, |d, cx| d.stop(cx));
            return;
        }
        let focus = self.editor.read(cx).focus.clone();
        window.focus(&focus, cx);
        let (anchor, _) = self.editor.read(cx).run_anchor();
        self.run = Some(DictationRun {
            anchor,
            len: 0,
            started: false,
            revision: self.editor.read(cx).revision(),
        });
        self.dictation.update(cx, |d, cx| d.start(cx));
        cx.notify();
    }

    fn on_dictation(&mut self, e: &DictationEvent, cx: &mut Context<Self>) {
        match e {
            DictationEvent::Text { text, .. } => {
                let Some(run) = &mut self.run else {
                    return;
                };
                let before = {
                    let plain = self.editor.read(cx).doc.plain_text();
                    // An edit before the run's start while it went on can
                    // leave the start inside a character: its start then.
                    let mut at = run.anchor.min(plain.len());
                    while !plain.is_char_boundary(at) {
                        at -= 1;
                    }
                    plain[..at].to_string()
                };
                // A space first when the text before does not end in one,
                // as the phone's run adds it.
                let spaced = if !before.is_empty()
                    && !before.ends_with(char::is_whitespace)
                    && !text.is_empty()
                {
                    format!(" {text}")
                } else {
                    text.clone()
                };
                let (anchor, len, first) = (run.anchor, run.len, !run.started);
                let new_len = self
                    .editor
                    .update(cx, |e, cx| e.replace_run(anchor, len, &spaced, first, cx));
                let revision = self.editor.read(cx).revision();
                if let Some(run) = &mut self.run {
                    run.len = new_len;
                    run.started = true;
                    run.revision = revision;
                }
            }
            DictationEvent::Transcribed(text) => {
                self.editor.update(cx, |e, cx| e.insert_text(text, cx));
            }
            DictationEvent::Heard => {}
            DictationEvent::Ended { restore } => {
                if let Some(run) = self.run.take()
                    && *restore
                    && run.started
                {
                    self.editor.update(cx, |e, cx| {
                        e.replace_run(run.anchor, run.len, "", false, cx)
                    });
                }
                self.end_run();
                // A note left while dictating goes once the words are in.
                if self.leaving {
                    self.save_now(cx);
                }
            }
        }
        cx.notify();
    }

    // ── Recordings ──────────────────────────────────────────────────────

    pub fn record_audio(&mut self, cx: &mut Context<Self>) {
        if !self.editable() || self.recorder.is_some() {
            return;
        }
        let input = self.record_input.clone();
        let recorder = cx.new(|cx| Recorder::start(input, cx));
        let page = self.page_id.clone();
        let sub = cx.subscribe(&recorder, move |this, _, e: &RecorderEvent, cx| {
            this.recorder = None;
            let l = this.l(cx);
            match e {
                RecorderEvent::Saved(path) => this.keep_recording(path.clone(), page.clone(), cx),
                RecorderEvent::Denied => {
                    this.toast(NoticeLevel::Error, l.desktop_microphone_unavailable(), cx)
                }
                RecorderEvent::Failed(e) => {
                    log::warn!("recording: {e}");
                    this.toast(NoticeLevel::Error, l.recording_failed(), cx)
                }
                RecorderEvent::Cancelled => {}
            }
            // A note left while recording goes once the audio is handed on.
            if this.leaving {
                this.save_now(cx);
            }
            cx.notify();
        });
        self._subscriptions.push(sub);
        self.recorder = Some(recorder.clone());
        cx.observe(&recorder, |_, _, cx| cx.notify()).detach();
        cx.notify();
    }

    fn keep_recording(&mut self, path: std::path::PathBuf, page: String, cx: &mut Context<Self>) {
        self.recordings_out += 1;
        let call = self
            .rpc
            .call::<methods::NotesAddRecording>(&NoteRecordingAdd {
                note_id: self.id.clone(),
                path: path.to_string_lossy().to_string(),
                page_id: Some(page),
            });
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result = call.await;
            let _ = this.update(cx, |this, cx| {
                let l = this.l(cx);
                match result {
                    Ok(list) => {
                        this.adopt_recordings(list.recordings, cx);
                        this.toast(NoticeLevel::Info, l.audio_recording_saved(), cx);
                    }
                    Err(e) => {
                        log::warn!("notes.addRecording: {e}");
                        this.toast(NoticeLevel::Error, l.desktop_recording_save_failed(), cx);
                    }
                }
                this.recordings_out = this.recordings_out.saturating_sub(1);
                // Quit waits until conduitd has the audio.
                if this.leaving {
                    this.settle(cx);
                }
                cx.notify();
            });
        })
        .detach();
    }

    /// The one place the note's load state changes: what is not shown any
    /// more (missing, failed, reloading) is not played either.
    fn set_load(&mut self, load: Load, cx: &mut Context<Self>) {
        self.load = load;
        self.playable_changed(cx);
    }

    /// The one place the waiting recordings are replaced.
    fn adopt_recordings(&mut self, recordings: Vec<NoteRecordingDto>, cx: &mut Context<Self>) {
        self.recordings = recordings;
        self.playable_changed(cx);
    }

    /// What the note offers Play/Pause for now, by the player's key: its
    /// recording cards, recordings among the files listed under it, and the
    /// waiting recordings not uploading.
    fn playable_keys(&self, cx: &App) -> Vec<String> {
        // Loading, missing or failed: the note and its controls are not shown.
        if self.load != Load::Ready {
            return Vec::new();
        }
        let cards: Vec<FileLink> = self.editor.read(cx).cards();
        let mut keys: Vec<String> = cards
            .iter()
            .filter(|c| is_audio(&c.name))
            .map(|c| c.id.clone())
            .collect();
        if let Some(detail) = &self.detail {
            keys.extend(
                detail
                    .files
                    .iter()
                    .filter(|f| is_audio(&f.name) && !cards.iter().any(|c| c.id == f.id))
                    .map(|f| f.id.clone()),
            );
        }
        keys.extend(
            self.recordings
                .iter()
                .filter(|r| r.state != NoteRecordingState::Uploading)
                .map(|r| format!("waiting:{}", r.id)),
        );
        keys
    }

    /// The account in charge now (none while the list is being read).
    fn active_account(&self, cx: &App) -> Option<String> {
        self.stores.accounts.read(cx).active().map(|a| a.id.clone())
    }

    /// Called after every change of what the note can play (its cards,
    /// listed files, waiting recordings, the page shown) and of the account
    /// in charge: the player plays only what still has a Play/Pause to stop
    /// it with, for the account it started under. A recording removed,
    /// uploading, on another page, or started under another account than
    /// the one in charge (loading or held) stops; any other plays on. A list
    /// being read again names nobody: no change.
    fn playable_changed(&mut self, cx: &mut Context<Self>) {
        let audio = self.audio.read(cx);
        let Some(held) = audio.current_key().map(str::to_string) else {
            return;
        };
        let started_under = audio.current_account().map(str::to_string);
        let active = self.active_account(cx);
        let other_account = active.is_some() && active != started_under;
        if other_account || !self.playable_keys(cx).contains(&held) {
            self.stop_audio(cx);
        }
    }

    fn refresh_recordings(&mut self, cx: &mut Context<Self>) {
        let call = self.rpc.call::<methods::NotesRecordings>(&NoteRef {
            id: self.id.clone(),
        });
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result = call.await;
            let _ = this.update(cx, |this, cx| {
                if let Ok(list) = result
                    && list.note_id == this.id
                    && list.recordings != this.recordings
                {
                    this.adopt_recordings(list.recordings, cx);
                    cx.notify();
                }
            });
        })
        .detach();
    }

    fn retry_recording(&mut self, id: String, cx: &mut Context<Self>) {
        let call = self
            .rpc
            .call::<methods::NotesRetryRecording>(&NoteRecordingRef {
                note_id: self.id.clone(),
                id,
            });
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            if let Ok(list) = call.await {
                let _ = this.update(cx, |this, cx| {
                    this.adopt_recordings(list.recordings, cx);
                    cx.notify();
                });
            }
        })
        .detach();
    }

    fn remove_recording(&mut self, id: String, window: &mut Window, cx: &mut Context<Self>) {
        let l = self.l(cx);
        let spec = SheetSpec::new(
            l.desktop_discard_recording_title(),
            l.desktop_discard_recording_body(),
            l.desktop_discard(),
            l.cancel(),
        )
        .destructive();
        let ask = present_sheet(window, spec, cx);
        let rpc = self.rpc.clone();
        let note_id = self.id.clone();
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            if !ask.await {
                return;
            }
            let result = rpc
                .call::<methods::NotesRemoveRecording>(&NoteRecordingRef { note_id, id })
                .await;
            let _ = this.update(cx, |this, cx| {
                if let Ok(list) = result {
                    this.adopt_recordings(list.recordings, cx);
                }
                cx.notify();
            });
        })
        .detach();
    }

    // ── Files ───────────────────────────────────────────────────────────

    fn server_id(&self, cx: &App) -> Option<String> {
        self.stores
            .accounts
            .read(cx)
            .active()
            .map(|a| a.connection.id.clone())
    }

    pub fn file_action_for_tests(
        &mut self,
        link: FileLink,
        action: FileAction,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.file_action(link, action, window, cx)
    }

    fn file_action(
        &mut self,
        link: FileLink,
        action: FileAction,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let Some(server_id) = self.server_id(cx) else {
            return;
        };
        let file = FileRef {
            server_id,
            file_id: link.id.clone(),
        };
        match action {
            FileAction::Play => {
                let http = self.stores.connection.read(cx).http().cloned();
                let source = AudioSource::File {
                    server_id: file.server_id.clone(),
                    file_id: file.file_id.clone(),
                };
                let account = self.active_account(cx);
                self.audio
                    .update(cx, |a, cx| a.toggle(&link.id, source, http, account, cx));
            }
            FileAction::QuickLook | FileAction::Open => {
                let how = if action == FileAction::Open {
                    OpenWith::DefaultApp
                } else {
                    OpenWith::QuickLook
                };
                let task = open_attachment(file, &link.name, how, cx);
                let toasts = self.stores.toasts.clone();
                cx.spawn(async move |_, cx: &mut AsyncApp| {
                    if let Err(e) = task.await {
                        log::warn!("opening a note's file: {e}");
                        cx.update(|cx| {
                            let text = cx.l10n().desktop_file_open_failed();
                            toasts.update(cx, |t, cx| t.show(NoticeLevel::Error, text, cx));
                        });
                    }
                })
                .detach();
            }
            FileAction::Download => self.download(file, link.name, cx),
            FileAction::Transcribe => self.transcribe(file, link, cx),
            FileAction::Remove => self.confirm_remove(link, window, cx),
        }
    }

    fn download(&mut self, file: FileRef, name: String, cx: &mut Context<Self>) {
        let downloads = dirs_downloads();
        let ask = cx.prompt_for_new_path(&downloads, Some(&name));
        let staged = stage_file(file, &name, cx);
        let toasts = self.stores.toasts.clone();
        cx.spawn(async move |_, cx: &mut AsyncApp| {
            let Ok(Ok(Some(target))) = ask.await else {
                return;
            };
            let result = match staged.await {
                Ok(path) => std::fs::copy(&path, &target)
                    .map(|_| ())
                    .map_err(|e| e.to_string()),
                Err(e) => Err(e),
            };
            if let Err(e) = result {
                log::warn!("downloading a note's file: {e}");
                cx.update(|cx| {
                    let text = cx.l10n().desktop_file_download_failed();
                    toasts.update(cx, |t, cx| t.show(NoticeLevel::Error, text, cx));
                });
            }
        })
        .detach();
    }

    /// Transcribe: the recording's words, as a paragraph under its card.
    fn transcribe(&mut self, file: FileRef, link: FileLink, cx: &mut Context<Self>) {
        let http = self.stores.connection.read(cx).http().cloned();
        let staged = stage_file(file, &link.name, cx);
        let asked = Transcription {
            block: self.editor.read(cx).card_block(&link.id),
            page: self.page_asked,
        };
        self.ai = None;
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result: Result<String, String> = async {
                let path = staged.await?;
                let bytes = std::fs::read(&path).map_err(|e| e.to_string())?;
                let http = http.ok_or("the daemon is not running")?;
                let (tx, rx) = futures::channel::oneshot::channel();
                conduit_daemon::runtime::shared().spawn(async move {
                    let result = http
                        .transcribe(bytes.into(), Some("server"), None)
                        .await
                        .map_err(|e| e.to_string());
                    let _ = tx.send(result);
                });
                let value = rx.await.map_err(|e| e.to_string())??;
                Ok(value
                    .get("text")
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .to_string())
            }
            .await;
            let _ = this.update(cx, |this, cx| this.transcribed(asked, result, cx));
        })
        .detach();
    }

    /// A recording's transcript is in: after the card it was asked from.
    fn transcribed(
        &mut self,
        asked: Transcription,
        result: Result<String, String>,
        cx: &mut Context<Self>,
    ) {
        let l = self.l(cx);
        match result {
            // Another page is shown (or asked for) now: the words were said
            // on the one left, and are not put into this one.
            Ok(_) if asked.page != self.page_asked => {}
            Ok(text) if !text.trim().is_empty() => {
                self.editor
                    .update(cx, |e, cx| e.insert_after_block(asked.block, &text, cx));
            }
            Ok(_) => self.toast(NoticeLevel::Info, l.desktop_nothing_heard(), cx),
            Err(e) => {
                log::warn!("transcribing a note's recording: {e}");
                self.toast(NoticeLevel::Error, l.desktop_transcription_failed(), cx);
            }
        }
    }

    fn confirm_remove(&mut self, link: FileLink, window: &mut Window, cx: &mut Context<Self>) {
        let l = self.l(cx);
        let spec = SheetSpec::new(
            l.desktop_remove_file_title(&link.name),
            l.desktop_remove_file_message(),
            l.desktop_settings_remove_server(),
            l.cancel(),
        )
        .destructive();
        let ask = present_sheet(window, spec, cx);
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            if !ask.await {
                return;
            }
            let _ = this.update(cx, |this, cx| this.remove_file(link, cx));
        })
        .detach();
    }

    /// Takes a file off the note: its card out of the text, and out of an
    /// older server's file list.
    fn remove_file(&mut self, link: FileLink, cx: &mut Context<Self>) {
        if let Some(block) = self.editor.read(cx).card_block(&link.id) {
            self.editor.update(cx, |e, cx| e.remove_block(block, cx));
        }
        // Gone from the files listed under the note too (not shown there
        // while the server detaches it); back if the server refuses.
        let removed = self.detail.as_mut().and_then(|d| {
            let at = d.files.iter().position(|f| f.id == link.id)?;
            Some(d.files.remove(at))
        });
        self.playable_changed(cx);
        let flushed = self.flush(cx);
        let call_for = {
            let rpc = self.rpc.clone();
            let request = NoteDetach {
                note_id: self.id.clone(),
                file_id: link.id.clone(),
                page_id: Some(self.page_id.clone()),
            };
            move || rpc.call::<methods::NotesDetach>(&request)
        };
        let asked = self.page_asked;
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            flushed.await;
            let result = call_for().await;
            let _ = this.update(cx, |this, cx| match result {
                // Another page is shown: it reads its own files.
                Ok(_) if this.page_asked != asked => {}
                Ok(detail) => {
                    if let Some(d) = &mut this.detail {
                        d.files = detail.files;
                    }
                    this.playable_changed(cx);
                    cx.notify();
                }
                Err(e) => {
                    log::warn!("notes.detach: {e}");
                    if this.page_asked == asked
                        && let (Some(d), Some(file)) = (&mut this.detail, removed)
                        && !d.files.iter().any(|f| f.id == file.id)
                    {
                        d.files.push(file);
                        cx.notify();
                    }
                }
            });
        })
        .detach();
    }

    /// Attach File…: picks files, uploads them and links them from the page.
    pub fn attach_files(&mut self, cx: &mut Context<Self>) {
        if !self.editable() {
            return;
        }
        let ask = cx.prompt_for_paths(gpui_kit::PathPromptOptions {
            files: true,
            directories: false,
            multiple: true,
            prompt: Some(cx.l10n().attach().into()),
        });
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            if let Ok(Ok(Some(paths))) = ask.await {
                let _ = this.update(cx, |this, cx| this.attach_paths(paths, cx));
            }
        })
        .detach();
    }

    /// Uploads `paths` and attaches them, after saving the text.
    pub fn attach_paths(&mut self, paths: Vec<std::path::PathBuf>, cx: &mut Context<Self>) {
        if !self.editable() || paths.is_empty() {
            return;
        }
        let http = self.stores.connection.read(cx).http().cloned();
        let rpc = self.rpc.clone();
        let note_id = self.id.clone();
        let page_id = self.page_id.clone();
        let asked = self.page_asked;
        let flushed = self.flush(cx);
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            flushed.await;
            let mut last: Option<NoteDetail> = None;
            let mut failed = vec![];
            for path in paths {
                let name = path
                    .file_name()
                    .map(|n| n.to_string_lossy().to_string())
                    .unwrap_or_else(|| "file".into());
                let uploaded = upload(http.clone(), &path, &name).await;
                let file = match uploaded {
                    Ok(file) => file,
                    Err(e) => {
                        log::warn!("uploading {name} for a note: {e}");
                        failed.push(name);
                        continue;
                    }
                };
                match rpc
                    .call::<methods::NotesAttach>(&NoteAttach {
                        note_id: note_id.clone(),
                        file,
                        page_id: Some(page_id.clone()),
                    })
                    .await
                {
                    Ok(detail) => last = Some(detail),
                    Err(e) => {
                        log::warn!("notes.attach: {e}");
                        failed.push(name);
                    }
                }
            }
            let _ = this.update(cx, |this, cx| {
                // The cards belong to the page they were attached to: another
                // page shown now keeps its own (that page shows them when it
                // is opened again).
                if let Some(detail) = last.filter(|_| this.page_asked == asked) {
                    let links: Vec<FileLink> = Doc::from_ops(&detail.ops)
                        .blocks
                        .iter()
                        .filter_map(|b| b.file_link())
                        .collect();
                    this.base_ops = detail.ops.clone();
                    if let Some(d) = &mut this.detail {
                        d.files = detail.files.clone();
                    }
                    this.editor.update(cx, |e, cx| e.append_cards(&links, cx));
                    this.playable_changed(cx);
                }
                for name in failed {
                    let text = this.l(cx).desktop_attachment_failed(&name);
                    this.toast(NoticeLevel::Error, text, cx);
                }
                cx.notify();
            });
        })
        .detach();
    }

    /// Runs a toolbar menu's command.
    pub fn run(&mut self, command: Command, window: &mut Window, cx: &mut Context<Self>) {
        match command {
            Command::GenerateTitle => self.generate_title(window, cx),
            Command::Enhance => self.enhance(window, cx),
            Command::ShowPage(page) => self.show_page(page, window, cx),
            Command::Style(kind) => self.editor.update(cx, |e, cx| e.toggle_kind(kind, cx)),
            Command::AttachFile => self.attach_files(cx),
            Command::RecordAudio => self.record_audio(cx),
            Command::Dictate => self.toggle_dictation(window, cx),
        }
    }

    // ── Rendering ───────────────────────────────────────────────────────

    /// The toolbar's buttons for this note (the area pane draws them at its
    /// trailing edge).
    pub fn toolbar(&mut self, t: &ConduitTheme, cx: &mut Context<Self>) -> Option<AnyElement> {
        if self.load != Load::Ready {
            return None;
        }
        let l = self.l(cx);
        let editable = self.editable();
        let id = self.id.clone();
        let dictating = self.dictation.read(cx).is_active();
        let menu_button = |key: &'static str, glyph: IconName, label: String, menu: MenuBuilder| {
            IconButton::new(key, glyph, label)
                .size(30., 16.)
                .on_click(Rc::new(
                    move |e: &ClickEvent, window: &mut Window, cx: &mut App| {
                        let position = e.position();
                        menu(window, cx).show(position, window, cx);
                    },
                ))
        };
        let note_id = id.clone();
        let ai_menu: MenuBuilder = {
            let l = l.clone();
            Rc::new(move |_, _| {
                NativeMenu::new()
                    .menu(
                        l.generate_title(),
                        Box::new(PaneCommand {
                            note_id: note_id.clone(),
                            command: Command::GenerateTitle,
                        }),
                    )
                    .menu(
                        l.enhance_note(),
                        Box::new(PaneCommand {
                            note_id: note_id.clone(),
                            command: Command::Enhance,
                        }),
                    )
            })
        };
        let summary = self.detail.as_ref().map(|d| d.summary.clone());
        let more_menu: MenuBuilder = {
            let l = l.clone();
            Rc::new(move |_, _| match &summary {
                Some(s) => super::note_menu(s, &l),
                None => NativeMenu::new(),
            })
        };
        let pages = self.pages().to_vec();
        let page_title = pages
            .iter()
            .find(|p| p.id == self.page_id)
            .map(|p| p.title.clone());
        let pages_menu: MenuBuilder = {
            let (note_id, current) = (id.clone(), self.page_id.clone());
            let pages = pages.clone();
            Rc::new(move |_, _| {
                let mut menu = NativeMenu::new();
                for page in &pages {
                    let indent = "    ".repeat(page.depth.max(0) as usize);
                    menu = menu.menu_with_check(
                        format!("{indent}{}", page.title),
                        page.id == current,
                        Box::new(PaneCommand {
                            note_id: note_id.clone(),
                            command: Command::ShowPage(page.id.clone()),
                        }),
                    );
                }
                menu
            })
        };
        let entity = cx.entity().downgrade();
        let act = |command: Command| -> ClickHandler {
            let entity = entity.clone();
            Rc::new(move |_, window, cx| {
                let command = command.clone();
                entity.update(cx, |p, cx| p.run(command, window, cx)).ok();
            })
        };
        let can_share = self.detail.as_ref().is_some_and(|d| d.summary.can_share);
        let share: ClickHandler = {
            let (stores, id) = (self.stores.clone(), id.clone());
            Rc::new(move |_, window, cx| {
                super::run(&stores, &id, super::NoteCommand::Share, window, cx)
            })
        };
        let r = t.roles;
        Some(
            div()
                .flex()
                .items_center()
                .gap(px(2.))
                .when(!pages.is_empty(), |d| {
                    d.child(
                        Button::new("note-pages", page_title.unwrap_or_else(|| l.note_pages()))
                            .ghost()
                            .icon(IconName::Layers)
                            .on_click({
                                let pages_menu = pages_menu.clone();
                                Rc::new(move |e: &ClickEvent, window: &mut Window, cx: &mut App| {
                                    let position = e.position();
                                    pages_menu(window, cx).show(position, window, cx)
                                })
                            }),
                    )
                })
                .when(editable, |d| {
                    d.child(
                        IconButton::new(
                            "note-attach",
                            IconName::Paperclip,
                            l.desktop_attach_file(),
                        )
                        .size(30., 16.)
                        .on_click(act(Command::AttachFile)),
                    )
                    .child(
                        IconButton::new(
                            "note-dictate",
                            if dictating {
                                IconName::CircleStop
                            } else {
                                IconName::Mic
                            },
                            if dictating {
                                l.desktop_stop_dictation()
                            } else {
                                l.start_dictation()
                            },
                        )
                        .size(30., 16.)
                        .active(dictating)
                        .shortcut(conduit_components::views::focus::hints(cx).dictate.clone())
                        .on_click(act(Command::Dictate)),
                    )
                    .child(
                        IconButton::new("note-record", IconName::AudioLines, l.record_audio())
                            .size(30., 16.)
                            .disabled(self.recorder.is_some())
                            .on_click(act(Command::RecordAudio)),
                    )
                    .child(menu_button(
                        "note-ai",
                        IconName::Sparkles,
                        l.desktop_note_ai_actions(),
                        ai_menu,
                    ))
                })
                .when(can_share, |d| {
                    d.child(
                        IconButton::new(
                            "note-share",
                            IconName::Users,
                            l.desktop_share_access_ellipsis(),
                        )
                        .size(30., 16.)
                        .on_click(share),
                    )
                })
                .child(menu_button(
                    "note-more",
                    IconName::Ellipsis,
                    l.more(),
                    more_menu,
                ))
                .child(
                    div()
                        .w(px(2.))
                        .h(px(16.))
                        .bg(r.divider)
                        .mx(px(2.))
                        .opacity(0.),
                )
                .into_any_element(),
        )
    }

    fn format_bar(&mut self, t: &ConduitTheme, cx: &mut Context<Self>) -> AnyElement {
        let l = self.l(cx);
        let r = t.roles;
        let marks = self.editor.read(cx).active_marks();
        let kind = self.editor.read(cx).active_kind();
        let editor = self.editor.downgrade();
        let mark = |m: Mark| -> ClickHandler {
            let editor = editor.clone();
            Rc::new(move |_, window, cx| {
                editor
                    .update(cx, |e, cx| {
                        e.toggle_mark(m, cx);
                        let f = e.focus.clone();
                        window.focus(&f, cx);
                    })
                    .ok();
            })
        };
        let style = |k: BlockKind| -> ClickHandler {
            let editor = editor.clone();
            Rc::new(move |_, window, cx| {
                editor
                    .update(cx, |e, cx| {
                        e.toggle_kind(k, cx);
                        let f = e.focus.clone();
                        window.focus(&f, cx);
                    })
                    .ok();
            })
        };
        let link: ClickHandler = {
            let editor = editor.clone();
            Rc::new(move |_, _, cx| {
                editor.update(cx, |e, cx| e.request_link(cx)).ok();
            })
        };
        let button = |key: &'static str,
                      glyph: IconName,
                      label: String,
                      chord: &str,
                      on: bool,
                      h: ClickHandler| {
            IconButton::new(key, glyph, label)
                .size(28., 15.)
                .active(on)
                .shortcut(Some(SharedString::from(chord.to_string())))
                .on_click(h)
        };
        let style_label = match kind {
            BlockKind::Heading(1) => l.desktop_note_style_title(),
            BlockKind::Heading(2) => l.desktop_note_style_heading(),
            BlockKind::Heading(_) => l.desktop_note_style_subheading(),
            _ => l.desktop_note_style_body(),
        };
        let note_id = self.id.clone();
        let style_menu = move |e: &ClickEvent, window: &mut Window, cx: &mut App| {
            let l = cx.l10n().clone();
            let item = |label: String, k: BlockKind| (label, k);
            let mut menu = NativeMenu::new();
            for (label, k) in [
                item(l.desktop_note_style_title(), BlockKind::Heading(1)),
                item(l.desktop_note_style_heading(), BlockKind::Heading(2)),
                item(l.desktop_note_style_subheading(), BlockKind::Heading(3)),
                item(l.desktop_note_style_body(), BlockKind::Paragraph),
            ] {
                menu = menu.menu_with_check(
                    label,
                    kind.same_style(k)
                        || (k == BlockKind::Paragraph && !matches!(kind, BlockKind::Heading(_))),
                    Box::new(PaneCommand {
                        note_id: note_id.clone(),
                        command: Command::Style(k),
                    }),
                );
            }
            menu.show(e.position(), window, cx);
        };
        div()
            .id("note-format-bar")
            .role(Role::Toolbar)
            .aria_label(l.desktop_note_format())
            .w_full()
            .flex()
            .items_center()
            .justify_center()
            .gap(px(2.))
            .px(px(16.))
            .py(px(4.))
            .border_b_1()
            .border_color(r.divider)
            .child(
                Button::new("note-style", style_label)
                    .ghost()
                    .on_click(Rc::new(style_menu)),
            )
            .child(div().w(px(1.)).h(px(16.)).mx(px(4.)).bg(r.divider))
            .child(button(
                "note-bold",
                IconName::Bold,
                l.desktop_note_bold(),
                "⌘B",
                marks.bold,
                mark(Mark::Bold),
            ))
            .child(button(
                "note-italic",
                IconName::Italic,
                l.desktop_note_italic(),
                "⌘I",
                marks.italic,
                mark(Mark::Italic),
            ))
            .child(button(
                "note-strike",
                IconName::Strikethrough,
                l.desktop_note_strikethrough(),
                "⇧⌘X",
                marks.strike,
                mark(Mark::Strike),
            ))
            .child(button(
                "note-code",
                IconName::Code,
                l.desktop_note_code(),
                "⌘E",
                marks.code,
                mark(Mark::Code),
            ))
            .child(button(
                "note-link",
                IconName::Link,
                l.desktop_note_link(),
                "⌘K",
                marks.link.is_some(),
                link,
            ))
            .child(div().w(px(1.)).h(px(16.)).mx(px(4.)).bg(r.divider))
            .child(button(
                "note-bullets",
                IconName::List,
                l.desktop_note_bulleted_list(),
                "⇧⌘7",
                kind == BlockKind::Bullet,
                style(BlockKind::Bullet),
            ))
            .child(button(
                "note-numbers",
                IconName::ListOrdered,
                l.desktop_note_numbered_list(),
                "⇧⌘9",
                kind == BlockKind::Ordered,
                style(BlockKind::Ordered),
            ))
            .child(button(
                "note-checklist",
                IconName::ListTodo,
                l.desktop_note_checklist(),
                "⇧⌘8",
                matches!(kind, BlockKind::Check(_)),
                style(BlockKind::Check(false)),
            ))
            .child(button(
                "note-quote",
                IconName::TextQuote,
                l.desktop_note_quote(),
                "⌘'",
                kind == BlockKind::Quote,
                style(BlockKind::Quote),
            ))
            .child(button(
                "note-code-block",
                IconName::SquareCode,
                l.desktop_note_code_block(),
                "⌥⌘C",
                kind == BlockKind::Code,
                style(BlockKind::Code),
            ))
            .into_any_element()
    }

    fn banner(
        &mut self,
        t: &ConduitTheme,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Option<AnyElement> {
        let l = self.l(cx);
        let r = t.roles;
        let entity = cx.entity().downgrade();
        let (text, actions): (String, Vec<AnyElement>) = if let Some(refusal) = self.refused {
            let text = match refusal {
                Refusal::ReadOnly => l.note_access_revoked_notice(),
                Refusal::PageMissing => l.note_page_missing_notice(),
            };
            let (keep, discard) = (entity.clone(), entity.clone());
            (
                text,
                vec![
                    Button::new("note-save-own", l.note_save_as_own_note())
                        .primary()
                        .on_click(Rc::new(move |_, _, cx| {
                            keep.update(cx, |p, cx| p.save_as_own_note(cx)).ok();
                        }))
                        .into_any_element(),
                    Button::new("note-discard", l.note_discard_changes())
                        .on_click(Rc::new(move |_, window, cx| {
                            discard
                                .update(cx, |p, cx| p.discard_changes(window, cx))
                                .ok();
                        }))
                        .into_any_element(),
                ],
            )
        } else if self.recovered {
            let dismiss = entity.clone();
            (
                l.desktop_note_recovered(),
                vec![
                    Button::new("note-recovered-ok", l.desktop_done())
                        .on_click(Rc::new(move |_, _, cx| {
                            dismiss
                                .update(cx, |p, cx| {
                                    p.recovered = false;
                                    cx.notify();
                                })
                                .ok();
                        }))
                        .into_any_element(),
                ],
            )
        } else if let Some(detail) = &self.detail
            && !detail.summary.can_edit
        {
            let text = match &detail.summary.owner {
                _ if detail.summary.access_unverified => l.note_access_unverified_notice(),
                Some(owner) => l.library_note_shared_by(owner),
                None => l.note_read_only_notice(),
            };
            (text, vec![])
        } else {
            return None;
        };
        let _ = window;
        Some(
            div()
                .id("note-banner")
                .role(Role::Status)
                .w_full()
                .flex()
                .items_center()
                .gap(px(10.))
                .px(px(16.))
                .py(px(8.))
                .bg(raised_fill(t))
                .border_b_1()
                .border_color(r.divider)
                .child(icon(IconName::Info, 15., r.text_subtle))
                .child(
                    div()
                        .flex_1()
                        .min_w_0()
                        .text_size(px(t.metrics.control))
                        .text_color(r.text)
                        .child(text),
                )
                .children(actions)
                .into_any_element(),
        )
    }

    fn find_bar(
        &mut self,
        t: &ConduitTheme,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Option<AnyElement> {
        let input = self.find.clone()?;
        let l = self.l(cx);
        let r = t.roles;
        let (count, current) = {
            let e = self.editor.read(cx);
            (e.find.matches.len(), e.find.current)
        };
        let query = input.read(cx).value().to_string();
        let status = if query.is_empty() {
            String::new()
        } else if count == 0 {
            l.desktop_find_no_matches()
        } else {
            l.desktop_position_of(&(current + 1).to_string(), &count.to_string())
        };
        let focused = input.read(cx).focus_handle(cx).is_focused(window);
        let editor = self.editor.downgrade();
        let step = |forward: bool| -> ClickHandler {
            let editor = editor.clone();
            Rc::new(move |_, _, cx| {
                editor.update(cx, |e, cx| e.find_step(forward, cx)).ok();
            })
        };
        let entity = cx.entity().downgrade();
        Some(
            div()
                .id("note-find-bar")
                .role(Role::Search)
                // Esc is Stop Generating's (bound after Kit's, and its
                // app listener ends the dispatch): taken first here, as
                // the chat's Find bar does, so Esc in the field closes it.
                .capture_action(cx.listener(|this, _: &StopGenerating, window, cx| {
                    this.close_find(window, cx);
                    cx.stop_propagation();
                }))
                .w_full()
                .flex()
                .items_center()
                .gap(px(8.))
                .px(px(16.))
                .py(px(6.))
                .border_b_1()
                .border_color(r.divider)
                .child(
                    div().w(px(260.)).child(
                        field_frame(focused, t.metrics.control_height - 4., cx)
                            .child(icon(IconName::Search, 13., r.text_subtle))
                            .child(
                                div().flex_1().min_w_0().child(
                                    bare_input(&input, l.desktop_find_in_note(), t.metrics.control)
                                        .accessibility_id("note-find-field"),
                                ),
                            ),
                    ),
                )
                .child(
                    div()
                        .min_w(px(80.))
                        .text_size(px(t.metrics.small + 0.5))
                        .text_color(r.text_subtle)
                        .child(status),
                )
                .child(
                    IconButton::new(
                        "note-find-previous",
                        IconName::ChevronUp,
                        l.desktop_find_previous(),
                    )
                    .size(26., 14.)
                    .shortcut(Some("⇧⌘G".into()))
                    .disabled(count == 0)
                    .on_click(step(false)),
                )
                .child(
                    IconButton::new(
                        "note-find-next",
                        IconName::ChevronDown,
                        l.desktop_find_next(),
                    )
                    .size(26., 14.)
                    .shortcut(Some("⌘G".into()))
                    .disabled(count == 0)
                    .on_click(step(true)),
                )
                .child(div().flex_1())
                .child(
                    Button::new("note-find-done", l.desktop_done()).on_click(Rc::new(
                        move |_, window, cx| {
                            entity.update(cx, |p, cx| p.close_find(window, cx)).ok();
                        },
                    )),
                )
                .into_any_element(),
        )
    }

    fn link_bar(
        &mut self,
        t: &ConduitTheme,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Option<AnyElement> {
        let prompt = self.link.as_ref()?;
        let l = self.l(cx);
        let r = t.roles;
        let input = prompt.input.clone();
        let has_link = prompt.current.is_some();
        let focused = input.read(cx).focus_handle(cx).is_focused(window);
        let entity = cx.entity().downgrade();
        let (apply, remove, cancel) = (entity.clone(), entity.clone(), entity.clone());
        let value = input.clone();
        Some(
            div()
                .id("note-link-bar")
                .role(Role::Group)
                // Esc cancels, as in the Find bar (Stop Generating's).
                .capture_action(cx.listener(|this, _: &StopGenerating, window, cx| {
                    this.cancel_link(window, cx);
                    cx.stop_propagation();
                }))
                .aria_label(l.desktop_note_link())
                .w_full()
                .flex()
                .items_center()
                .gap(px(8.))
                .px(px(16.))
                .py(px(6.))
                .border_b_1()
                .border_color(r.divider)
                .child(icon(IconName::Link, 14., r.text_subtle))
                .child(
                    div().flex_1().min_w_0().max_w(px(420.)).child(
                        field_frame(focused, t.metrics.control_height - 4., cx).child(
                            div().flex_1().min_w_0().child(
                                bare_input(&input, l.desktop_link_placeholder(), t.metrics.control)
                                    .accessibility_id("note-link-field"),
                            ),
                        ),
                    ),
                )
                .when(has_link, |d| {
                    d.child(
                        Button::new("note-link-remove", l.desktop_remove_link()).on_click(Rc::new(
                            move |_, window, cx| {
                                remove
                                    .update(cx, |p, cx| p.apply_link(None, window, cx))
                                    .ok();
                            },
                        )),
                    )
                })
                .child(
                    Button::new("note-link-cancel", l.cancel()).on_click(Rc::new(
                        move |_, window, cx| {
                            cancel.update(cx, |p, cx| p.cancel_link(window, cx)).ok();
                        },
                    )),
                )
                .child(
                    Button::new("note-link-apply", l.desktop_add_link())
                        .primary()
                        .on_click(Rc::new(move |_, window, cx| {
                            let url = value.read(cx).value().to_string();
                            apply
                                .update(cx, |p, cx| p.apply_link(Some(url), window, cx))
                                .ok();
                        })),
                )
                .into_any_element(),
        )
    }

    fn recording_strip(&mut self, t: &ConduitTheme, cx: &mut Context<Self>) -> Option<AnyElement> {
        let recorder = self.recorder.clone()?;
        let l = self.l(cx);
        let r = t.roles;
        let (phase, level, elapsed) = {
            let rec = recorder.read(cx);
            (rec.phase, rec.level, rec.elapsed())
        };
        let clock = crate::stores::dictation::clock(elapsed);
        let label = match phase {
            RecordPhase::Starting => l.preparing_recording(),
            RecordPhase::Recording { .. } => l.recording_audio(),
            RecordPhase::Saving => l.processing_recording(),
        };
        let (stop, cancel) = (recorder.downgrade(), recorder.downgrade());
        Some(
            div()
                .id("note-recording")
                .role(Role::Status)
                .aria_label(SharedString::from(format!("{label} {clock}")))
                .w_full()
                .flex()
                .items_center()
                .gap(px(10.))
                .px(px(16.))
                .py(px(8.))
                .bg(raised_fill(t))
                .border_b_1()
                .border_color(r.divider)
                .child(div().size(px(9.)).rounded_full().bg(r.danger))
                .child(div().text_color(r.text).child(label))
                .child(
                    div()
                        .text_color(r.text_subtle)
                        .font_family("Menlo")
                        .child(clock),
                )
                .child(
                    div()
                        .w(px(80.))
                        .h(px(4.))
                        .rounded_full()
                        .bg(r.border)
                        .child(
                            div()
                                .h_full()
                                .rounded_full()
                                .bg(r.text_subtle)
                                .w(relative(level.clamp(0., 1.))),
                        ),
                )
                .child(div().flex_1())
                .child(
                    Button::new("note-recording-cancel", l.cancel()).on_click(Rc::new(
                        move |_, _, cx| {
                            cancel.update(cx, |r, cx| r.cancel(cx)).ok();
                        },
                    )),
                )
                .child(
                    Button::new("note-recording-stop", l.desktop_stop_and_save())
                        .primary()
                        .disabled(phase == RecordPhase::Saving)
                        .on_click(Rc::new(move |_, _, cx| {
                            stop.update(cx, |r, cx| r.stop(cx)).ok();
                        })),
                )
                .into_any_element(),
        )
    }

    /// Play or Pause for one of the note's recordings still waiting to
    /// upload, played from this Mac.
    pub fn toggle_waiting(&mut self, id: &str, cx: &mut Context<Self>) {
        let http = self.stores.connection.read(cx).http().cloned();
        let source = AudioSource::Waiting {
            note_id: self.id.clone(),
            id: id.to_string(),
        };
        let key = format!("waiting:{id}");
        let account = self.active_account(cx);
        self.audio
            .update(cx, |a, cx| a.toggle(&key, source, http, account, cx));
    }

    /// The player's words.
    fn player_words(&self, cx: &App) -> PlayerWords {
        let l = self.l(cx);
        PlayerWords {
            play: l.video_play().into(),
            pause: l.voice_call_pause().into(),
            position: l.desktop_note_audio_position().into(),
            failed: l.failed_to_load_audio().into(),
            loading: l.desktop_loading().into(),
        }
    }

    /// A recording row's Play or Pause, by the player's state for `key`.
    fn play_button(
        &self,
        id: SharedString,
        key: &str,
        on_click: ClickHandler,
        cx: &App,
    ) -> AnyElement {
        let words = self.player_words(cx);
        let playing = self.audio.read(cx).state(key).is_some_and(|s| s.playing);
        let label = if playing { words.pause } else { words.play };
        IconButton::new(
            id,
            if playing {
                IconName::Pause
            } else {
                IconName::Play
            },
            label.clone(),
        )
        .size(28., 14.)
        .tooltip(label)
        .on_click(on_click)
        .into_any_element()
    }

    /// Under a recording row's name: the player's scrubber and time while
    /// it holds `key`, else `fallback`.
    fn player_line(
        &self,
        id: &str,
        key: &str,
        fallback: AnyElement,
        t: &ConduitTheme,
        cx: &App,
    ) -> AnyElement {
        match self.audio.read(cx).state(key) {
            Some(state) => {
                super::audio::progress(id, key, state, &self.audio, &self.player_words(cx), t)
            }
            None => fallback,
        }
    }

    fn waiting_recordings(
        &mut self,
        t: &ConduitTheme,
        cx: &mut Context<Self>,
    ) -> Option<AnyElement> {
        if self.recordings.is_empty() {
            return None;
        }
        let l = self.l(cx);
        let r = t.roles;
        let entity = cx.entity().downgrade();
        let rows: Vec<AnyElement> = self
            .recordings
            .iter()
            .map(|rec| {
                let state = match rec.state {
                    NoteRecordingState::Waiting | NoteRecordingState::Unknown => {
                        l.desktop_recording_waiting()
                    }
                    NoteRecordingState::Uploading => l.desktop_recording_uploading(),
                    NoteRecordingState::Failed => l.desktop_recording_upload_failed(),
                };
                let (retry, remove, play) = (entity.clone(), entity.clone(), entity.clone());
                let (retry_id, remove_id, play_id) =
                    (rec.id.clone(), rec.id.clone(), rec.id.clone());
                let key = format!("waiting:{}", rec.id);
                // While it uploads it is not played, as on the phone.
                let playable = rec.state != NoteRecordingState::Uploading;
                let leading = if playable {
                    self.play_button(
                        SharedString::from(format!("note-waiting-play-{}", rec.id)),
                        &key,
                        Rc::new(move |_, _, cx| {
                            let id = play_id.clone();
                            play.update(cx, |p, cx| p.toggle_waiting(&id, cx)).ok();
                        }),
                        cx,
                    )
                } else {
                    icon(IconName::AudioLines, 18., r.text_subtle).into_any_element()
                };
                let status = div()
                    .text_size(px(t.metrics.small))
                    .text_color(if rec.state == NoteRecordingState::Failed {
                        r.danger
                    } else {
                        r.text_subtle
                    })
                    .child(state.clone())
                    .into_any_element();
                let second = self.player_line(
                    &format!("note-waiting-audio-{}", rec.id),
                    &key,
                    status,
                    t,
                    cx,
                );
                div()
                    .id(SharedString::from(format!("note-waiting-{}", rec.id)))
                    .role(Role::Group)
                    .aria_label(SharedString::from(format!("{}, {state}", rec.name)))
                    .w_full()
                    .flex()
                    .items_center()
                    .gap(px(10.))
                    .px(px(10.))
                    .py(px(8.))
                    .rounded(px(10.))
                    .border_1()
                    .border_color(r.border)
                    .child(leading)
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .flex()
                            .flex_col()
                            .child(div().truncate().text_color(r.text).child(rec.name.clone()))
                            .child(second),
                    )
                    .when(rec.state == NoteRecordingState::Failed, |d| {
                        d.child(
                            Button::new(
                                SharedString::from(format!("note-waiting-retry-{}", rec.id)),
                                l.desktop_try_again(),
                            )
                            .on_click(Rc::new(move |_, _, cx| {
                                let id = retry_id.clone();
                                retry.update(cx, |p, cx| p.retry_recording(id, cx)).ok();
                            })),
                        )
                    })
                    .when(rec.state != NoteRecordingState::Uploading, |d| {
                        d.child(
                            IconButton::new(
                                SharedString::from(format!("note-waiting-remove-{}", rec.id)),
                                IconName::X,
                                l.desktop_discard_recording_menu(),
                            )
                            .size(26., 14.)
                            .on_click(Rc::new(move |_, window, cx| {
                                let id = remove_id.clone();
                                remove
                                    .update(cx, |p, cx| p.remove_recording(id, window, cx))
                                    .ok();
                            })),
                        )
                    })
                    .into_any_element()
            })
            .collect();
        Some(
            div()
                .w_full()
                .flex()
                .flex_col()
                .gap(px(6.))
                .pt(px(16.))
                .child(
                    div()
                        .text_size(px(t.metrics.small + 0.5))
                        .font_weight(FontWeight::SEMIBOLD)
                        .text_color(r.text_subtle)
                        .child(l.desktop_recordings_waiting()),
                )
                .children(rows)
                .into_any_element(),
        )
    }

    /// Files an older server keeps in the note's file list (not linked in
    /// the text).
    fn listed_files(&mut self, t: &ConduitTheme, cx: &mut Context<Self>) -> Option<AnyElement> {
        let detail = self.detail.as_ref()?;
        let shown: Vec<String> = self
            .editor
            .read(cx)
            .cards()
            .into_iter()
            .map(|c| c.id)
            .collect();
        let files: Vec<NoteFile> = detail
            .files
            .iter()
            .filter(|f| !shown.contains(&f.id))
            .cloned()
            .collect();
        if files.is_empty() {
            return None;
        }
        let l = self.l(cx);
        let r = t.roles;
        let entity = cx.entity().downgrade();
        let editable = self.editable();
        let rows: Vec<AnyElement> = files
            .into_iter()
            .map(|f| {
                let link = FileLink {
                    id: f.id.clone(),
                    name: f.name.clone(),
                };
                let act = |action: FileAction| -> ClickHandler {
                    let (entity, link) = (entity.clone(), link.clone());
                    Rc::new(move |_, window, cx| {
                        let link = link.clone();
                        entity
                            .update(cx, |p, cx| p.file_action(link, action, window, cx))
                            .ok();
                    })
                };
                let audio = is_audio(&f.name);
                let leading = if audio {
                    self.play_button(
                        SharedString::from(format!("note-listed-play-{}", f.id)),
                        &f.id,
                        act(FileAction::Play),
                        cx,
                    )
                } else {
                    icon(IconName::FileText, 18., r.text_subtle).into_any_element()
                };
                let name_line = div()
                    .flex_1()
                    .min_w_0()
                    .flex()
                    .flex_col()
                    .child(div().truncate().text_color(r.text).child(f.name.clone()))
                    .when(audio, |d| {
                        let id = format!("note-listed-audio-{}", f.id);
                        d.when_some(
                            self.audio.read(cx).state(&f.id).map(|state| (id, state)),
                            |d, (id, state)| {
                                d.child(super::audio::progress(
                                    &id,
                                    &f.id,
                                    state,
                                    &self.audio,
                                    &self.player_words(cx),
                                    t,
                                ))
                            },
                        )
                    });
                div()
                    .id(SharedString::from(format!("note-listed-file-{}", f.id)))
                    .role(Role::Group)
                    .aria_label(SharedString::from(f.name.clone()))
                    .w_full()
                    .flex()
                    .items_center()
                    .gap(px(10.))
                    .px(px(10.))
                    .py(px(8.))
                    .rounded(px(10.))
                    .border_1()
                    .border_color(r.border)
                    .child(leading)
                    .child(name_line)
                    .when(!audio, |d| {
                        d.child(
                            IconButton::new(
                                SharedString::from(format!("note-listed-look-{}", f.id)),
                                IconName::Eye,
                                l.desktop_quick_look(),
                            )
                            .size(26., 14.)
                            .on_click(act(FileAction::QuickLook)),
                        )
                    })
                    .child(
                        IconButton::new(
                            SharedString::from(format!("note-listed-download-{}", f.id)),
                            IconName::Download,
                            l.download(),
                        )
                        .size(26., 14.)
                        .on_click(act(FileAction::Download)),
                    )
                    .when(editable, |d| {
                        d.child(
                            IconButton::new(
                                SharedString::from(format!("note-listed-remove-{}", f.id)),
                                IconName::X,
                                l.desktop_remove_ellipsis(),
                            )
                            .size(26., 14.)
                            .on_click(act(FileAction::Remove)),
                        )
                    })
                    .into_any_element()
            })
            .collect();
        Some(
            div()
                .w_full()
                .flex()
                .flex_col()
                .gap(px(6.))
                .pt(px(16.))
                .child(
                    div()
                        .text_size(px(t.metrics.small + 0.5))
                        .font_weight(FontWeight::SEMIBOLD)
                        .text_color(r.text_subtle)
                        .child(l.attachments()),
                )
                .children(rows)
                .into_any_element(),
        )
    }

    fn footer(&mut self, t: &ConduitTheme, cx: &mut Context<Self>) -> AnyElement {
        let l = self.l(cx);
        let r = t.roles;
        let (words, chars) = self.editor.read(cx).doc.counts();
        let status = match (self.save, self.refused) {
            (_, Some(_)) => l.desktop_note_not_saved(),
            (SaveState::Saved, _) => l.desktop_note_saved(),
            (SaveState::Edited, _) => l.desktop_note_edited(),
            (SaveState::Saving, _) => l.desktop_saving(),
            (SaveState::Failed, _) => l.desktop_note_save_failed(),
        };
        let read_only = self.detail.as_ref().is_some_and(|d| !d.summary.can_edit);
        let ai = match self.ai {
            Some(AiAction::Title) => Some(l.desktop_note_generating_title()),
            Some(AiAction::Enhance) => Some(l.desktop_note_enhancing()),
            None => None,
        };
        let listening = matches!(
            self.dictation.read(cx).phase,
            DictationPhase::Listening { .. }
        );
        let retry: ClickHandler = {
            let entity = cx.entity().downgrade();
            Rc::new(move |_, _, cx| {
                entity.update(cx, |p, cx| p.save_now(cx)).ok();
            })
        };
        div()
            .id("note-footer")
            .role(Role::Status)
            .w_full()
            .flex()
            .items_center()
            .gap(px(12.))
            .px(px(20.))
            .py(px(6.))
            .border_t_1()
            .border_color(r.divider)
            .text_size(px(t.metrics.small + 0.5))
            .text_color(r.text_subtle)
            .child(l.word_count(words as i64))
            .child(l.char_count(chars as i64))
            .when(listening, |d| {
                d.child(div().text_color(r.text).child(l.desktop_listening()))
            })
            .when_some(ai, |d, text| d.child(div().text_color(r.text).child(text)))
            .child(div().flex_1())
            .when(!read_only, |d| {
                d.child(
                    div()
                        .id("note-save-status")
                        .aria_label(SharedString::from(status.clone()))
                        .child(status),
                )
                .when(
                    self.save == SaveState::Failed && self.refused.is_none(),
                    |d| {
                        d.child(
                            Button::new("note-save-retry", l.desktop_try_again())
                                .ghost()
                                .on_click(retry),
                        )
                    },
                )
            })
            .into_any_element()
    }
}

/// The error a refusal of `reason` sends.
fn is_refusal(e: &RpcError, reason: &str) -> bool {
    is_reason(e, reason)
}

fn is_reason(e: &RpcError, reason: &str) -> bool {
    e.args.get("reason").is_some_and(|r| r == reason)
}

/// An address as a link holds it: one without a scheme is a web address.
pub fn normalize_url(url: String) -> String {
    let url = url.trim().to_string();
    if url.is_empty() || url.contains("://") || url.starts_with("mailto:") || url.starts_with('/') {
        url
    } else if url.contains('@') && !url.contains('/') {
        format!("mailto:{url}")
    } else {
        format!("https://{url}")
    }
}

fn dirs_downloads() -> std::path::PathBuf {
    std::env::var_os("HOME")
        .map(|h| std::path::PathBuf::from(h).join("Downloads"))
        .unwrap_or_else(std::env::temp_dir)
}

/// Uploads `path` through the daemon's `/upload`.
async fn upload(
    http: Option<conduit_daemon::http::HttpClient>,
    path: &std::path::Path,
    name: &str,
) -> Result<NoteFile, String> {
    let http = http.ok_or("the daemon is not running")?;
    let bytes = std::fs::read(path).map_err(|e| e.to_string())?;
    let size = bytes.len() as i64;
    let content_type = mime_for(name);
    let (tx, rx) = futures::channel::oneshot::channel();
    let request_name = name.to_string();
    conduit_daemon::runtime::shared().spawn(async move {
        let result = http
            .upload(&request_name, content_type, bytes.into(), None, 1)
            .await
            .map_err(|e| e.to_string());
        let _ = tx.send(result);
    });
    let value = rx.await.map_err(|e| e.to_string())??;
    let id = value
        .get("id")
        .and_then(Value::as_str)
        .ok_or("the upload named no file")?
        .to_string();
    Ok(NoteFile {
        id,
        name: name.to_string(),
        size: Some(size),
        content_type: content_type.map(str::to_string),
    })
}

fn mime_for(name: &str) -> Option<&'static str> {
    let lower = name.to_lowercase();
    let ext = lower.rsplit('.').next()?;
    Some(match ext {
        "pdf" => "application/pdf",
        "txt" | "md" => "text/plain",
        "png" => "image/png",
        "jpg" | "jpeg" => "image/jpeg",
        "gif" => "image/gif",
        "wav" => "audio/wav",
        "m4a" => "audio/mp4",
        "mp3" => "audio/mpeg",
        "csv" => "text/csv",
        "json" => "application/json",
        "docx" => "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        _ => return None,
    })
}

impl Render for NotePane {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let t = cx.conduit().clone();
        let l = self.l(cx);
        let r = t.roles;
        let body = match &self.load {
            Load::Loading => div()
                .flex_1()
                .flex()
                .items_center()
                .justify_center()
                .text_color(r.text_subtle)
                .child(l.loading_note())
                .child(live_text(
                    "note-loading",
                    Some(l.loading_note().into()),
                    Priority::Medium,
                ))
                .into_any_element(),
            Load::Missing => div()
                .id("note-missing")
                .flex_1()
                .flex()
                .flex_col()
                .items_center()
                .justify_center()
                .gap(px(8.))
                .child(icon(IconName::FileText, 32., r.text_faint))
                .child(
                    div()
                        .text_size(px(t.metrics.body + 4.))
                        .font_weight(FontWeight::SEMIBOLD)
                        .text_color(r.text)
                        .child(l.note_not_found()),
                )
                .child(
                    div()
                        .text_color(r.text_subtle)
                        .child(l.desktop_note_missing_message()),
                )
                .into_any_element(),
            Load::Failed(_) => {
                let entity = cx.entity().downgrade();
                div()
                    .flex_1()
                    .flex()
                    .flex_col()
                    .items_center()
                    .justify_center()
                    .gap(px(10.))
                    .child(div().text_color(r.text).child(l.desktop_note_load_failed()))
                    .child(
                        Button::new("note-load-retry", l.desktop_try_again()).on_click(Rc::new(
                            move |_, window, cx| {
                                entity
                                    .update(cx, |p, cx| {
                                        p.set_load(Load::Loading, cx);
                                        let page = p.page_id.clone();
                                        p.open_page(Some(page), window, cx);
                                    })
                                    .ok();
                            },
                        )),
                    )
                    .into_any_element()
            }
            Load::Ready => {
                let editable = self.editable();
                let title_size = t.metrics.body + 12.;
                let title_input = Input::new(&self.title)
                    .appearance(false)
                    .bordered(false)
                    .px_0()
                    // Kit's field sets a 20 pt line whatever the type's
                    // size, which cuts the large title's descenders: give
                    // it a line (and a box) of its own size.
                    .h(px((title_size * 1.5).round()))
                    .line_height(px((title_size * 1.3).round()))
                    .text_size(px(title_size))
                    .font_weight(FontWeight::BOLD)
                    .aria_label(l.desktop_note_title_placeholder())
                    .accessibility_id("note-title-field")
                    .disabled(!editable);
                let updated = self
                    .detail
                    .as_ref()
                    .map(|d| d.summary.updated_at_ms)
                    .unwrap_or_default();
                let (date, _) = crate::views::dates::stamp(updated, &chrono::Local::now(), &l);
                let column = div()
                    .w_full()
                    .max_w(px(COLUMN))
                    .flex()
                    .flex_col()
                    .px(px(32.))
                    .pt(px(18.))
                    .child(
                        div()
                            .text_size(px(t.metrics.small))
                            .text_color(r.text_faint)
                            .pb(px(4.))
                            .child(date),
                    )
                    .child(div().pb(px(10.)).child(title_input))
                    .child(self.editor.clone())
                    .children(self.waiting_recordings(&t, cx))
                    .children(self.listed_files(&t, cx))
                    .child(div().h(px(40.)));
                let scroll = self.editor.read(cx).scroll.clone();
                let editor_focus = self.editor.read(cx).focus.clone();
                let editor = self.editor.downgrade();
                div()
                    .flex_1()
                    .min_h_0()
                    .flex()
                    .flex_col()
                    .when(editable, |d| d.child(self.format_bar(&t, cx)))
                    .children(self.find_bar(&t, window, cx))
                    .children(self.link_bar(&t, window, cx))
                    .children(self.banner(&t, window, cx))
                    .children(self.recording_strip(&t, cx))
                    .child(
                        div()
                            .id("note-scroll")
                            .flex_1()
                            .min_h_0()
                            .overflow_y_scroll()
                            .track_scroll(&scroll)
                            .flex()
                            .flex_col()
                            .items_center()
                            // A click below the text puts the caret at its end.
                            .on_click(move |e: &ClickEvent, window, cx| {
                                if !editor_focus.is_focused(window) {
                                    window.focus(&editor_focus, cx);
                                }
                                let at = e.position();
                                editor
                                    .update(cx, |ed, cx| {
                                        let below = ed.layout.borrow().bounds.bottom();
                                        if at.y > below && !ed.is_read_only() {
                                            let end = ed.doc.end();
                                            ed.select_to(end, false, cx);
                                        }
                                    })
                                    .ok();
                            })
                            .child(column),
                    )
                    .child(self.footer(&t, cx))
                    .into_any_element()
            }
        };
        let entity = cx.entity().downgrade();
        div()
            .id("note-pane")
            .key_context(NOTE_PANE_CONTEXT)
            .track_focus(&self.focus)
            .size_full()
            .flex()
            .flex_col()
            .bg(r.content)
            .on_action(cx.listener(|this, _: &FindInChat, window, cx| this.open_find(window, cx)))
            .on_action(cx.listener(|this, _: &FindNext, _, cx| {
                this.editor.update(cx, |e, cx| e.find_step(true, cx))
            }))
            .on_action(cx.listener(|this, _: &FindPrevious, _, cx| {
                this.editor.update(cx, |e, cx| e.find_step(false, cx))
            }))
            .on_action(
                cx.listener(|this, _: &crate::actions::Dictate, window, cx| {
                    this.toggle_dictation(window, cx)
                }),
            )
            .on_action(cx.listener(|this, a: &PaneCommand, window, cx| {
                if a.note_id == this.id {
                    this.run(a.command.clone(), window, cx)
                }
            }))
            .on_action(
                cx.listener(|this, _: &gpui_kit::component::input::Escape, window, cx| {
                    if this.link.is_some() {
                        this.cancel_link(window, cx);
                    } else if this.find.is_some() {
                        this.close_find(window, cx);
                    } else {
                        cx.propagate();
                    }
                }),
            )
            .on_drop(move |paths: &ExternalPaths, _, cx| {
                let paths = paths.paths().to_vec();
                entity.update(cx, |p, cx| p.attach_paths(paths, cx)).ok();
            })
            .child(body)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn addresses_without_a_scheme_become_web_or_mail_links() {
        assert_eq!(
            normalize_url("example.com/a".into()),
            "https://example.com/a"
        );
        assert_eq!(
            normalize_url("https://a.example".into()),
            "https://a.example"
        );
        assert_eq!(
            normalize_url("ada@example.com".into()),
            "mailto:ada@example.com"
        );
        assert_eq!(normalize_url("  ".into()), "");
    }

    #[test]
    fn upload_types_follow_the_extension() {
        assert_eq!(mime_for("Recording.WAV"), Some("audio/wav"));
        assert_eq!(mime_for("notes.pdf"), Some("application/pdf"));
        assert_eq!(mime_for("archive"), None);
    }

    mod bench {
        use conduit_protocol::{NoteList, NoteRecordings, NoteResult, NoteSection, NoteSummary};
        use gpui_kit::{TestAppContext, VisualTestContext};

        use super::super::super::area::NotesArea;
        use super::*;
        use crate::stores::navigation::AreaItem;
        use crate::stores::rpc::fake::FakeDaemon;

        /// Page `page` of note `id`, its text `text`; the note has pages
        /// `main`, `p2` and `p3`.
        pub fn detail(id: &str, page: &str, text: &str) -> NoteDetail {
            NoteDetail {
                summary: NoteSummary {
                    id: id.into(),
                    title: "Trail log".into(),
                    updated_at_ms: 1,
                    pinned: false,
                    preview: String::new(),
                    conflict_copy: false,
                    section: NoteSection::Today,
                    can_edit: true,
                    access_unverified: false,
                    can_share: false,
                    owner: None,
                },
                ops: vec![serde_json::json!({ "insert": format!("{text}\n") })],
                files: vec![],
                pages: ["main", "p2", "p3"]
                    .iter()
                    .map(|p| NotePageDto {
                        id: (*p).into(),
                        title: (*p).into(),
                        path: (*p).into(),
                        depth: 0,
                    })
                    .collect(),
                page_id: page.into(),
                markdown: text.into(),
                recovered_from: None,
            }
        }

        /// The text a page holds on the fake server.
        pub fn page_text(page: &str) -> &'static str {
            match page {
                "p2" => "Second page",
                "p3" => "Third page",
                _ => "Ridge at dawn",
            }
        }

        /// The notes area with note `n1` open.
        pub fn open(
            cx: &mut TestAppContext,
        ) -> (
            FakeDaemon,
            Stores,
            Entity<NotesArea>,
            &mut VisualTestContext,
        ) {
            let daemon = FakeDaemon::new();
            daemon.returns::<methods::NotesList>(NoteList { notes: vec![] });
            daemon.returns::<methods::NotesRecordings>(NoteRecordings {
                note_id: "n1".into(),
                recordings: vec![],
            });
            daemon.on::<methods::NotesGet>(|p| {
                let page = p["pageId"].as_str().unwrap_or("main");
                let id = p["id"].as_str().unwrap_or("n1");
                Ok(serde_json::to_value(NoteResult {
                    note: Some(detail(id, page, page_text(page))),
                })
                .unwrap())
            });
            let scratch =
                std::env::temp_dir().join(format!("conduit-notes-{}", std::process::id()));
            let stores = cx.update(|cx| {
                crate::views::test_globals(cx);
                Stores::for_test(daemon.rpc(), &scratch, cx)
            });
            // Account `a` signed in.
            stores.accounts.update(cx, |a, cx| {
                use crate::stores::accounts::tests::{account, list};
                a.adopt(list(vec![account("a", "Avery", true, true)]), cx)
            });
            stores
                .navigation
                .update(cx, |n, cx| n.open_item(AreaItem::Note("n1".into()), cx));
            let s = stores.clone();
            let (area, vcx) = cx.add_window_view(move |window, cx| NotesArea::new(s, window, cx));
            vcx.run_until_parked();
            (daemon, stores, area, vcx)
        }

        pub fn pane(area: &Entity<NotesArea>, vcx: &mut VisualTestContext) -> Entity<NotePane> {
            area.read_with(vcx, |a, _| a.note_pane().cloned())
                .expect("a note shown")
        }

        pub fn text(pane: &Entity<NotePane>, vcx: &mut VisualTestContext) -> String {
            pane.read_with(vcx, |p, cx| p.editor.read(cx).doc.plain_text())
        }
    }

    /// New Note answered after another account signed in: the note made
    /// under the first account opens in nobody's window.
    #[gpui_kit::test]
    fn a_new_note_answered_after_a_switch_opens_nothing(cx: &mut gpui_kit::TestAppContext) {
        use crate::stores::accounts::tests::{account, list};
        use crate::stores::navigation::{AreaItem, Selection};
        let (daemon, stores, _area, vcx) = bench::open(cx);
        daemon.on::<methods::NotesSave>(|_| {
            Ok(serde_json::to_value(bench::detail("made-under-a", "main", "")).unwrap())
        });
        let late = daemon.hold::<methods::NotesSave>();
        vcx.update(|_, cx| super::super::new_note(&stores, cx));
        vcx.run_until_parked();
        stores.accounts.update(vcx, |a, cx| {
            a.adopt(
                list(vec![
                    account("a", "Avery", false, true),
                    account("b", "Blair", true, true),
                ]),
                cx,
            )
        });
        drop(late);
        vcx.run_until_parked();
        assert_ne!(
            stores
                .navigation
                .read_with(vcx, |n, _| n.selection().clone()),
            Selection::Area(AreaItem::Note("made-under-a".into())),
            "the last account's new note opened under the next"
        );
    }

    /// A note opened again while its save is still out shows the pane that
    /// is saving it, not a fresh one reading the stored text from before
    /// that save (whose own later save would write over it).
    #[gpui_kit::test]
    fn a_note_reopened_while_saving_shows_the_pane_saving_it(cx: &mut gpui_kit::TestAppContext) {
        use crate::stores::navigation::AreaItem;
        let (daemon, stores, area, vcx) = bench::open(cx);
        let pane = bench::pane(&area, vcx);
        daemon.on::<methods::NotesSave>(|p| {
            let page = p["pageId"].as_str().unwrap_or("main").to_string();
            Ok(serde_json::to_value(bench::detail("n1", &page, "kept")).unwrap())
        });
        let held = daemon.hold::<methods::NotesSave>();
        pane.update(vcx, |p, cx| {
            p.editor.update(cx, |e, cx| e.insert_text("Cairn ", cx))
        });
        stores
            .navigation
            .update(vcx, |n, cx| n.open_item(AreaItem::AllNotes, cx));
        vcx.run_until_parked();
        stores
            .navigation
            .update(vcx, |n, cx| n.open_item(AreaItem::Note("n1".into()), cx));
        vcx.run_until_parked();
        let shown = bench::pane(&area, vcx);
        assert_eq!(
            shown.entity_id(),
            pane.entity_id(),
            "a second pane opened over the save still out"
        );
        assert!(bench::text(&shown, vcx).contains("Cairn"));
        drop(held);
        vcx.run_until_parked();
    }

    /// A note left under one account while its save is out, then opened
    /// under the next account (a note shared with both): a fresh pane, with
    /// none of the last account's words; the last account gets its own pane
    /// back once it is active again.
    #[gpui_kit::test]
    fn a_note_reopened_under_another_account_gets_its_own_pane(cx: &mut gpui_kit::TestAppContext) {
        use crate::stores::accounts::tests::{account, list};
        use crate::stores::navigation::AreaItem;
        let (daemon, stores, area, vcx) = bench::open(cx);
        let accounts = |active: &str| {
            list(vec![
                account("a", "Avery", active == "a", true),
                account("b", "Blair", active == "b", true),
            ])
        };
        stores
            .accounts
            .update(vcx, |a, cx| a.adopt(accounts("a"), cx));
        let pane = bench::pane(&area, vcx);
        daemon.on::<methods::NotesSave>(|p| {
            let page = p["pageId"].as_str().unwrap_or("main").to_string();
            Ok(serde_json::to_value(bench::detail("n1", &page, "kept")).unwrap())
        });
        let held = daemon.hold::<methods::NotesSave>();
        pane.update(vcx, |p, cx| {
            p.editor.update(cx, |e, cx| e.insert_text("Cairn ", cx))
        });
        stores
            .navigation
            .update(vcx, |n, cx| n.open_item(AreaItem::AllNotes, cx));
        vcx.run_until_parked();
        stores
            .accounts
            .update(vcx, |a, cx| a.adopt(accounts("b"), cx));
        vcx.run_until_parked();
        stores
            .navigation
            .update(vcx, |n, cx| n.open_item(AreaItem::Note("n1".into()), cx));
        vcx.run_until_parked();
        let shown = bench::pane(&area, vcx);
        assert_ne!(
            shown.entity_id(),
            pane.entity_id(),
            "the last account's pane was shown under the next account"
        );
        assert!(
            !bench::text(&shown, vcx).contains("Cairn"),
            "the last account's unsaved words showed under the next account"
        );
        drop(held);
        vcx.run_until_parked();
    }

    /// The pane's player holds recording `key` (loading, as one from the
    /// server would be).
    fn hold_recording(pane: &Entity<NotePane>, vcx: &mut gpui_kit::VisualTestContext) {
        let audio = pane.read_with(vcx, |p, _| p.audio.clone());
        audio.update(vcx, |a, cx| {
            let source = super::super::audio::AudioSource::File {
                server_id: "server".into(),
                file_id: "trail-sounds".into(),
            };
            a.toggle("trail-sounds", source, None, Some("a".into()), cx)
        });
        assert_eq!(
            audio.read_with(vcx, |a, _| a.current_key().map(str::to_string)),
            Some("trail-sounds".into())
        );
    }

    fn held_recording(
        pane: &Entity<NotePane>,
        vcx: &mut gpui_kit::VisualTestContext,
    ) -> Option<String> {
        let audio = pane.read_with(vcx, |p, _| p.audio.clone());
        audio.read_with(vcx, |a, _| a.current_key().map(str::to_string))
    }

    /// A note left while its save is still out stays alive a while: its
    /// recording stops with the leaving, not when the save lands.
    #[gpui_kit::test]
    fn leaving_a_note_stops_its_recording(cx: &mut gpui_kit::TestAppContext) {
        use crate::stores::navigation::AreaItem;
        let (daemon, stores, area, vcx) = bench::open(cx);
        let pane = bench::pane(&area, vcx);
        let held = daemon.hold::<methods::NotesSave>();
        pane.update(vcx, |p, cx| {
            p.editor.update(cx, |e, cx| e.insert_text("Cairn ", cx))
        });
        hold_recording(&pane, vcx);
        stores
            .navigation
            .update(vcx, |n, cx| n.open_item(AreaItem::AllNotes, cx));
        vcx.run_until_parked();
        assert_eq!(
            held_recording(&pane, vcx),
            None,
            "the note's recording went on playing after it was left"
        );
        drop(held);
        vcx.run_until_parked();
    }

    /// A recording belongs to the account in charge when it started, even
    /// in a pane opened before any account was: another account taking
    /// charge stops it, whether it is loading or already held.
    #[gpui_kit::test]
    fn another_account_stops_a_recording_in_a_pane_opened_with_none(
        cx: &mut gpui_kit::TestAppContext,
    ) {
        use std::sync::{Arc, Mutex};

        use conduit_protocol::{NoteRecordingDto, NoteRecordings};

        use crate::stores::accounts::tests::{account, list};
        use crate::stores::navigation::AreaItem;
        let (daemon, stores, area, vcx) = bench::open(cx);
        let rec = |id: &str| NoteRecordingDto {
            id: id.into(),
            name: format!("{id}.m4a"),
            state: NoteRecordingState::Waiting,
            size: 1,
            created_at_ms: 1,
            page_id: None,
        };
        let listed: Arc<Mutex<Vec<NoteRecordingDto>>> = Arc::default();
        {
            let listed = listed.clone();
            daemon.on::<methods::NotesRecordings>(move |p| {
                Ok(serde_json::to_value(NoteRecordings {
                    note_id: p["id"].as_str().unwrap_or("n2").into(),
                    recordings: listed.lock().unwrap().clone(),
                })
                .unwrap())
            });
        }
        let accounts = |active: Option<&str>| {
            list(vec![
                account("a", "Avery", active == Some("a"), true),
                account("b", "Blair", active == Some("b"), true),
            ])
        };
        // No account in charge yet: the next note opens under none.
        stores
            .accounts
            .update(vcx, |a, cx| a.adopt(accounts(None), cx));
        stores
            .navigation
            .update(vcx, |n, cx| n.open_item(AreaItem::Note("n2".into()), cx));
        vcx.run_until_parked();
        let pane = bench::pane(&area, vcx);
        assert_eq!(pane.read_with(vcx, |p, _| p.opened_under.clone()), None);
        stores
            .accounts
            .update(vcx, |a, cx| a.adopt(accounts(Some("a")), cx));
        *listed.lock().unwrap() = vec![rec("r1"), rec("r2")];
        pane.update(vcx, |p, cx| p.refresh_recordings(cx));
        vcx.run_until_parked();
        let audio = pane.read_with(vcx, |p, _| p.audio.clone());
        // Loading under A when B takes charge.
        pane.update(vcx, |p, cx| p.toggle_waiting("r1", cx));
        assert_eq!(
            audio.read_with(vcx, |a, _| a.state("waiting:r1").map(|s| s.phase)),
            Some(super::super::audio::Phase::Loading)
        );
        stores
            .accounts
            .update(vcx, |a, cx| a.adopt(accounts(Some("b")), cx));
        assert_eq!(
            held_recording(&pane, vcx),
            None,
            "A's recording kept loading after B took charge"
        );
        vcx.run_until_parked();
        assert_eq!(held_recording(&pane, vcx), None);
        // Held (its load done) under A when B takes charge.
        stores
            .accounts
            .update(vcx, |a, cx| a.adopt(accounts(Some("a")), cx));
        pane.update(vcx, |p, cx| p.toggle_waiting("r2", cx));
        vcx.run_until_parked();
        assert_eq!(held_recording(&pane, vcx), Some("waiting:r2".into()));
        stores
            .accounts
            .update(vcx, |a, cx| a.adopt(accounts(Some("b")), cx));
        assert_eq!(
            held_recording(&pane, vcx),
            None,
            "A's recording went on playing after B took charge"
        );
    }

    /// A note deleted elsewhere shows no Play/Pause any more: its recording
    /// stops when a refresh finds it missing.
    #[gpui_kit::test]
    fn a_note_found_missing_stops_its_recording(cx: &mut gpui_kit::TestAppContext) {
        use conduit_protocol::NoteResult;
        let (daemon, _stores, area, vcx) = bench::open(cx);
        let pane = bench::pane(&area, vcx);
        // The stored note gains a recording card (another device attached it).
        daemon.on::<methods::NotesGet>(|_| {
            let mut detail = bench::detail("n1", "main", "First page");
            detail.ops = vec![
                serde_json::json!({ "insert": "First page\n" }),
                serde_json::json!({
                    "insert": "tide.wav",
                    "attributes": { "link": "/api/v1/files/f1/content" }
                }),
                serde_json::json!({ "insert": "\n" }),
            ];
            Ok(serde_json::to_value(NoteResult { note: Some(detail) }).unwrap())
        });
        pane.update(vcx, |p, cx| p.changed_elsewhere(cx));
        vcx.run_until_parked();
        assert_eq!(
            pane.read_with(vcx, |p, cx| p.editor.read(cx).cards().len()),
            1,
            "the stored card was taken in"
        );
        let audio = pane.read_with(vcx, |p, _| p.audio.clone());
        audio.update(vcx, |a, cx| {
            let source = super::super::audio::AudioSource::File {
                server_id: "server".into(),
                file_id: "f1".into(),
            };
            a.toggle("f1", source, None, Some("a".into()), cx)
        });
        assert_eq!(held_recording(&pane, vcx), Some("f1".into()));
        // Deleted elsewhere: the refresh finds no note.
        daemon.on::<methods::NotesGet>(|_| {
            Ok(serde_json::to_value(NoteResult { note: None }).unwrap())
        });
        pane.update(vcx, |p, cx| p.changed_elsewhere(cx));
        vcx.run_until_parked();
        assert_eq!(pane.read_with(vcx, |p, _| p.load.clone()), Load::Missing);
        assert_eq!(
            held_recording(&pane, vcx),
            None,
            "a missing note's recording went on playing with no control"
        );
    }

    /// An attachment plays only while the note offers Play for it: removing
    /// the one playing stops it; removing another leaves it playing.
    #[gpui_kit::test]
    fn removing_the_playing_attachment_stops_it(cx: &mut gpui_kit::TestAppContext) {
        use std::sync::{Arc, Mutex};

        use conduit_protocol::NoteFile;
        let file = |id: &str, name: &str| NoteFile {
            id: id.into(),
            name: name.into(),
            size: None,
            content_type: None,
        };
        let (daemon, _stores, area, vcx) = bench::open(cx);
        let attached = Arc::new(Mutex::new(vec![
            file("f1", "tide.wav"),
            file("f2", "gull.wav"),
        ]));
        {
            let attached = attached.clone();
            daemon.on::<methods::NotesDetach>(move |p| {
                let gone = p["fileId"].as_str().unwrap_or_default().to_string();
                let mut files = attached.lock().unwrap();
                files.retain(|f| f.id != gone);
                let mut detail = bench::detail("n1", "main", "kept");
                detail.files = files.clone();
                Ok(serde_json::to_value(detail).unwrap())
            });
        }
        daemon.on::<methods::NotesSave>(|_| {
            Ok(serde_json::to_value(bench::detail("n1", "main", "kept")).unwrap())
        });
        let pane = bench::pane(&area, vcx);
        let links = [
            FileLink {
                id: "f1".into(),
                name: "tide.wav".into(),
            },
            FileLink {
                id: "f2".into(),
                name: "gull.wav".into(),
            },
        ];
        pane.update(vcx, |p, cx| {
            if let Some(d) = &mut p.detail {
                d.files = attached.lock().unwrap().clone();
            }
            p.editor.update(cx, |e, cx| e.append_cards(&links, cx));
        });
        vcx.run_until_parked();
        let audio = pane.read_with(vcx, |p, _| p.audio.clone());
        audio.update(vcx, |a, cx| {
            let source = super::super::audio::AudioSource::File {
                server_id: "server".into(),
                file_id: "f1".into(),
            };
            a.toggle("f1", source, None, Some("a".into()), cx)
        });
        pane.update(vcx, |p, cx| p.remove_file(links[1].clone(), cx));
        vcx.run_until_parked();
        assert_eq!(
            held_recording(&pane, vcx),
            Some("f1".into()),
            "removing another attachment stopped this one"
        );
        pane.update(vcx, |p, cx| p.remove_file(links[0].clone(), cx));
        assert_eq!(
            held_recording(&pane, vcx),
            None,
            "a removed attachment went on playing with no control"
        );
        vcx.run_until_parked();
        assert_eq!(held_recording(&pane, vcx), None);
    }

    /// A waiting recording plays only while its row offers Play: the list
    /// read again keeps it playing while it stays playable, and stops it
    /// once it uploads (no control left) or has gone.
    #[gpui_kit::test]
    fn a_waiting_recording_stops_once_its_row_offers_no_play(cx: &mut gpui_kit::TestAppContext) {
        use std::sync::{Arc, Mutex};

        use conduit_protocol::NoteRecordings;
        let rec = |id: &str, state: NoteRecordingState| NoteRecordingDto {
            id: id.into(),
            name: format!("{id}.m4a"),
            state,
            size: 1,
            created_at_ms: 1,
            page_id: None,
        };
        let (daemon, _stores, area, vcx) = bench::open(cx);
        let listed: Arc<Mutex<Vec<NoteRecordingDto>>> = Arc::default();
        {
            let listed = listed.clone();
            daemon.on::<methods::NotesRecordings>(move |_| {
                Ok(serde_json::to_value(NoteRecordings {
                    note_id: "n1".into(),
                    recordings: listed.lock().unwrap().clone(),
                })
                .unwrap())
            });
        }
        let pane = bench::pane(&area, vcx);
        let list_again = |now: Vec<NoteRecordingDto>, vcx: &mut gpui_kit::VisualTestContext| {
            *listed.lock().unwrap() = now;
            pane.update(vcx, |p, cx| p.refresh_recordings(cx));
            vcx.run_until_parked();
        };
        use NoteRecordingState::{Uploading, Waiting};
        list_again(vec![rec("r1", Waiting), rec("r2", Waiting)], vcx);
        pane.update(vcx, |p, cx| p.toggle_waiting("r1", cx));
        assert_eq!(held_recording(&pane, vcx), Some("waiting:r1".into()));
        // Another one starts uploading; this one still offers Play.
        list_again(vec![rec("r1", Waiting), rec("r2", Uploading)], vcx);
        assert_eq!(
            held_recording(&pane, vcx),
            Some("waiting:r1".into()),
            "a recording still playable was stopped"
        );
        // It uploads: its row has no Play/Pause left.
        list_again(vec![rec("r1", Uploading), rec("r2", Uploading)], vcx);
        assert_eq!(
            held_recording(&pane, vcx),
            None,
            "an uploading recording went on playing with no control"
        );
        // One that goes from the list stops too.
        list_again(vec![rec("r3", Waiting)], vcx);
        pane.update(vcx, |p, cx| p.toggle_waiting("r3", cx));
        list_again(vec![], vcx);
        assert_eq!(
            held_recording(&pane, vcx),
            None,
            "a recording gone from the list went on playing"
        );
    }

    /// Another account taking charge stops a recording the note opened
    /// under the last one was playing.
    #[gpui_kit::test]
    fn another_account_stops_the_notes_recording(cx: &mut gpui_kit::TestAppContext) {
        use crate::stores::accounts::tests::{account, list};
        let (_daemon, stores, area, vcx) = bench::open(cx);
        let accounts = |active: &str| {
            list(vec![
                account("a", "Avery", active == "a", true),
                account("b", "Blair", active == "b", true),
            ])
        };
        stores
            .accounts
            .update(vcx, |a, cx| a.adopt(accounts("a"), cx));
        vcx.run_until_parked();
        let pane = bench::pane(&area, vcx);
        hold_recording(&pane, vcx);
        stores
            .accounts
            .update(vcx, |a, cx| a.adopt(accounts("b"), cx));
        vcx.run_until_parked();
        assert_eq!(
            held_recording(&pane, vcx),
            None,
            "the last account's recording went on playing"
        );
    }

    /// A note change heard while the next page is read does not make the
    /// page being left take typing again (its words would be replaced when
    /// the next page shows).
    #[gpui_kit::test]
    fn a_change_heard_while_a_page_opens_takes_no_typing(cx: &mut gpui_kit::TestAppContext) {
        let (daemon, _stores, area, vcx) = bench::open(cx);
        let pane = bench::pane(&area, vcx);
        let held = daemon.hold_one::<methods::NotesGet>(0);
        pane.update_in(vcx, |p, window, cx| p.show_page("p2".into(), window, cx));
        vcx.run_until_parked();
        pane.update(vcx, |p, cx| p.changed_elsewhere(cx));
        vcx.run_until_parked();
        pane.update(vcx, |p, cx| {
            p.editor.update(cx, |e, cx| e.insert_text("Cairn ", cx))
        });
        assert!(
            !bench::text(&pane, vcx).contains("Cairn"),
            "a refresh made the page being left take typing"
        );
        held.release();
        vcx.run_until_parked();
        assert_eq!(bench::text(&pane, vcx), "Second page");
    }

    /// Quit after a save conduitd refused for another account, its account
    /// active again by the answer: the save is tried again within Quit's
    /// wait, not after the usual pause Quit would not wait out.
    #[gpui_kit::test]
    fn quit_waits_for_an_account_refusals_retry(cx: &mut gpui_kit::TestAppContext) {
        let (daemon, _stores, area, vcx) = bench::open(cx);
        let pane = bench::pane(&area, vcx);
        let mut refused = conduit_daemon::protocol::error("auth.sessionExpired", "another account");
        refused.args.insert("reason".into(), "account".into());
        daemon.once::<methods::NotesSave>(Err(refused));
        daemon.on::<methods::NotesSave>(|p| {
            let page = p["pageId"].as_str().unwrap_or("main").to_string();
            Ok(serde_json::to_value(bench::detail("n1", &page, "kept")).unwrap())
        });
        let quits = Rc::new(std::cell::Cell::new(0));
        pane.update(vcx, |p, cx| {
            p.editor.update(cx, |e, cx| e.insert_text("Cairn ", cx))
        });
        let q = quits.clone();
        vcx.update(|_, cx| {
            crate::views::sheet::quit_with(cx, Rc::new(move |_| q.set(q.get() + 1)))
        });
        vcx.run_until_parked();
        assert_eq!(daemon.calls::<methods::NotesSave>().len(), 1);
        assert_eq!(quits.get(), 0);
        vcx.executor().advance_clock(QUIT_RETRY_DELAY);
        vcx.run_until_parked();
        assert_eq!(
            daemon.calls::<methods::NotesSave>().len(),
            2,
            "the refused save waited longer than Quit does"
        );
        assert_eq!(quits.get(), 1);
    }

    /// Typing while another page is read goes nowhere: the page being left
    /// takes no words until the next one shows, so nothing typed is
    /// replaced by it.
    #[gpui_kit::test]
    fn typing_waits_for_the_page_being_opened(cx: &mut gpui_kit::TestAppContext) {
        let (daemon, _stores, area, vcx) = bench::open(cx);
        let pane = bench::pane(&area, vcx);
        let held = daemon.hold_one::<methods::NotesGet>(0);
        pane.update_in(vcx, |p, window, cx| p.show_page("p2".into(), window, cx));
        vcx.run_until_parked();
        pane.update(vcx, |p, cx| {
            p.editor.update(cx, |e, cx| e.insert_text("Cairn ", cx))
        });
        assert!(
            !bench::text(&pane, vcx).contains("Cairn"),
            "typing went into the page being left, to be replaced by the next"
        );
        held.release();
        vcx.run_until_parked();
        assert_eq!(bench::text(&pane, vcx), "Second page");
        assert!(
            !pane.read_with(vcx, |p, cx| p.editor.read(cx).is_read_only()),
            "the page shown takes no typing"
        );
    }

    /// Quit after a failed save waits for the save tried again, within
    /// Quit's wait: the note's text is not left unsaved.
    #[gpui_kit::test]
    fn quit_waits_for_a_failed_saves_retry(cx: &mut gpui_kit::TestAppContext) {
        let (daemon, _stores, area, vcx) = bench::open(cx);
        let pane = bench::pane(&area, vcx);
        daemon.once::<methods::NotesSave>(Err(conduit_daemon::protocol::error(
            "rpc.daemonUnavailable",
            "away",
        )));
        daemon.on::<methods::NotesSave>(|p| {
            let page = p["pageId"].as_str().unwrap_or("main").to_string();
            Ok(serde_json::to_value(bench::detail("n1", &page, "kept")).unwrap())
        });
        let quits = Rc::new(std::cell::Cell::new(0));
        pane.update(vcx, |p, cx| {
            p.editor.update(cx, |e, cx| e.insert_text("Cairn ", cx))
        });
        let q = quits.clone();
        vcx.update(|_, cx| {
            crate::views::sheet::quit_with(cx, Rc::new(move |_| q.set(q.get() + 1)))
        });
        vcx.run_until_parked();
        assert_eq!(daemon.calls::<methods::NotesSave>().len(), 1);
        assert_eq!(
            quits.get(),
            0,
            "the app quit after a failed save, the note's text unsaved"
        );
        vcx.executor().advance_clock(QUIT_RETRY_DELAY);
        vcx.run_until_parked();
        assert_eq!(daemon.calls::<methods::NotesSave>().len(), 2);
        assert_eq!(quits.get(), 1);
    }

    /// A transcript that comes in after the page changed is not put into
    /// the page shown then.
    #[gpui_kit::test]
    fn a_transcript_after_a_page_change_goes_nowhere(cx: &mut gpui_kit::TestAppContext) {
        let (_daemon, _stores, area, vcx) = bench::open(cx);
        let pane = bench::pane(&area, vcx);
        let asked = pane.read_with(vcx, |p, _| Transcription {
            block: None,
            page: p.page_asked,
        });
        pane.update_in(vcx, |p, window, cx| p.show_page("p2".into(), window, cx));
        vcx.run_until_parked();
        assert_eq!(bench::text(&pane, vcx), "Second page");
        pane.update(vcx, |p, cx| {
            p.transcribed(asked, Ok("Heard by the river".into()), cx)
        });
        assert_eq!(
            bench::text(&pane, vcx),
            "Second page",
            "the first page's transcript went into the second"
        );
    }

    /// A note left while its save fails is kept, and saved again, until
    /// its text is kept: the departing pane is not let go with it.
    #[gpui_kit::test]
    fn a_note_left_is_saved_again_after_a_failed_save(cx: &mut gpui_kit::TestAppContext) {
        use crate::stores::navigation::AreaItem;
        let (daemon, stores, area, vcx) = bench::open(cx);
        let pane = bench::pane(&area, vcx);
        daemon.once::<methods::NotesSave>(Err(conduit_daemon::protocol::error(
            "rpc.daemonUnavailable",
            "away",
        )));
        daemon.on::<methods::NotesSave>(|p| {
            let page = p["pageId"].as_str().unwrap_or("main").to_string();
            Ok(serde_json::to_value(bench::detail("n1", &page, "kept")).unwrap())
        });
        pane.update(vcx, |p, cx| {
            p.editor.update(cx, |e, cx| e.insert_text("Cairn ", cx))
        });
        // Only the area holds the pane from here.
        drop(pane);
        stores
            .navigation
            .update(vcx, |n, cx| n.open_item(AreaItem::AllNotes, cx));
        vcx.run_until_parked();
        assert_eq!(daemon.calls::<methods::NotesSave>().len(), 1);
        vcx.executor().advance_clock(RETRY_DELAY);
        vcx.run_until_parked();
        assert_eq!(
            daemon.calls::<methods::NotesSave>().len(),
            2,
            "the note left was dropped with its unsaved text"
        );
    }

    /// A save refused (the note read-only now) after the note was left: the
    /// draft's choices are offered then, and keeping it saves it as a note of
    /// its own.
    #[gpui_kit::test]
    fn a_draft_refused_after_leaving_is_offered_back(cx: &mut gpui_kit::TestAppContext) {
        use crate::stores::navigation::AreaItem;
        let (daemon, stores, area, vcx) = bench::open(cx);
        vcx.update(|_, cx| cx.set_global(crate::shell::sheet::AutoAnswer(Some(true))));
        daemon.on::<methods::NotesSave>(|p| {
            if p["id"].is_string() {
                let mut e = conduit_daemon::protocol::error("conflict", "read-only now");
                e.args.insert("reason".into(), "readOnly".into());
                return Err(e);
            }
            Ok(serde_json::to_value(bench::detail("n2", "main", "kept")).unwrap())
        });
        let pane = bench::pane(&area, vcx);
        let late = daemon.hold::<methods::NotesSave>();
        pane.update(vcx, |p, cx| {
            p.editor.update(cx, |e, cx| e.insert_text("Cairn ", cx))
        });
        drop(pane);
        stores
            .navigation
            .update(vcx, |n, cx| n.open_item(AreaItem::AllNotes, cx));
        vcx.run_until_parked();
        drop(late);
        vcx.run_until_parked();
        let saves = daemon.calls::<methods::NotesSave>();
        assert_eq!(saves.len(), 2, "the refused draft was not offered back");
        assert!(saves[1]["id"].is_null() && saves[1].to_string().contains("Cairn"));

        // Under another account, a refusal answered late is held: no offer,
        // nothing made under it, until the draft's own account is back.
        use crate::stores::accounts::tests::{account, list};
        let accounts = |active: &str| {
            list(vec![
                account("a", "Avery", active == "a", true),
                account("b", "Blair", active == "b", true),
            ])
        };
        stores
            .accounts
            .update(vcx, |a, cx| a.adopt(accounts("a"), cx));
        stores
            .navigation
            .update(vcx, |n, cx| n.open_item(AreaItem::Note("n1".into()), cx));
        vcx.run_until_parked();
        let pane = bench::pane(&area, vcx);
        let late = daemon.hold::<methods::NotesSave>();
        pane.update(vcx, |p, cx| {
            p.editor.update(cx, |e, cx| e.insert_text("Ledge ", cx));
            p.save_now(cx);
        });
        drop(pane);
        stores
            .accounts
            .update(vcx, |a, cx| a.adopt(accounts("b"), cx));
        stores
            .navigation
            .update(vcx, |n, cx| n.open_item(AreaItem::AllNotes, cx));
        vcx.run_until_parked();
        drop(late);
        vcx.run_until_parked();
        let made = |daemon: &crate::stores::rpc::fake::FakeDaemon| {
            daemon
                .calls::<methods::NotesSave>()
                .iter()
                .filter(|s| s["id"].is_null() && s.to_string().contains("Ledge"))
                .count()
        };
        assert_eq!(
            made(&daemon),
            0,
            "account A's draft was made into a note under B"
        );
        stores
            .accounts
            .update(vcx, |a, cx| a.adopt(accounts("a"), cx));
        vcx.run_until_parked();
        assert_eq!(
            made(&daemon),
            1,
            "the draft was not offered once its account was back"
        );

        // The question answered after another account became active sends
        // the draft nowhere; it is offered again under its own account.
        stores
            .navigation
            .update(vcx, |n, cx| n.open_item(AreaItem::Note("n1".into()), cx));
        vcx.run_until_parked();
        let pane = bench::pane(&area, vcx);
        let late = daemon.hold::<methods::NotesSave>();
        pane.update(vcx, |p, cx| {
            p.editor.update(cx, |e, cx| e.insert_text("Scree ", cx));
            p.save_now(cx);
        });
        // The refusal comes in and the question goes up; account B becomes
        // active before it is answered.
        let s = stores.clone();
        vcx.update(|_, cx| {
            cx.subscribe(&pane, move |pane, e: &PaneEvent, cx| {
                if *e == PaneEvent::Settled && pane.read(cx).has_refused_draft() {
                    s.accounts.update(cx, |a, cx| {
                        a.adopt(
                            list(vec![
                                account("a", "Avery", false, true),
                                account("b", "Blair", true, true),
                            ]),
                            cx,
                        )
                    });
                }
            })
            .detach()
        });
        drop(pane);
        stores
            .navigation
            .update(vcx, |n, cx| n.open_item(AreaItem::AllNotes, cx));
        vcx.run_until_parked();
        drop(late);
        vcx.run_until_parked();
        let scree = |daemon: &crate::stores::rpc::fake::FakeDaemon| {
            daemon
                .calls::<methods::NotesSave>()
                .iter()
                .filter(|s| s["id"].is_null() && s.to_string().contains("Scree"))
                .count()
        };
        assert_eq!(
            scree(&daemon),
            0,
            "an answer given under account B made A's draft a note"
        );
        stores
            .accounts
            .update(vcx, |a, cx| a.adopt(accounts("a"), cx));
        vcx.run_until_parked();
        assert_eq!(
            scree(&daemon),
            1,
            "the held draft was not offered again under A"
        );

        // conduitd is already on B while the desktop still shows A (the
        // switch's answer not in yet): answering A's recovery then makes no
        // note under B; the draft stays held and is offered again under A.
        use std::sync::Arc;
        use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
        let on_b = Arc::new(AtomicBool::new(false));
        let made_under_b = Arc::new(AtomicUsize::new(0));
        let (b, made) = (on_b.clone(), made_under_b.clone());
        daemon.on::<methods::NotesSave>(move |p| {
            if p["id"].is_string() {
                let mut e = conduit_daemon::protocol::error("conflict", "read-only now");
                e.args.insert("reason".into(), "readOnly".into());
                return Err(e);
            }
            if b.load(Ordering::SeqCst) {
                if p["accountId"].as_str().is_some_and(|a| a != "b") {
                    let mut e =
                        conduit_daemon::protocol::error("auth.sessionExpired", "another account");
                    e.args.insert("reason".into(), "account".into());
                    return Err(e);
                }
                made.fetch_add(1, Ordering::SeqCst);
            }
            Ok(serde_json::to_value(bench::detail("n3", "main", "kept")).unwrap())
        });
        let talus = |daemon: &crate::stores::rpc::fake::FakeDaemon, account: Option<&str>| {
            daemon
                .calls::<methods::NotesSave>()
                .iter()
                .filter(|s| {
                    s["id"].is_null()
                        && s.to_string().contains("Talus")
                        && s["accountId"].as_str() == account
                })
                .count()
        };
        stores
            .navigation
            .update(vcx, |n, cx| n.open_item(AreaItem::Note("n1".into()), cx));
        vcx.run_until_parked();
        let pane = bench::pane(&area, vcx);
        let late = daemon.hold::<methods::NotesSave>();
        pane.update(vcx, |p, cx| {
            p.editor.update(cx, |e, cx| e.insert_text("Talus ", cx));
            p.save_now(cx);
        });
        let weak = pane.downgrade();
        drop(pane);
        stores
            .navigation
            .update(vcx, |n, cx| n.open_item(AreaItem::AllNotes, cx));
        vcx.run_until_parked();
        on_b.store(true, Ordering::SeqCst);
        drop(late);
        vcx.run_until_parked();
        assert_eq!(
            made_under_b.load(Ordering::SeqCst),
            0,
            "account A's draft was made into a note under B"
        );
        let held = weak.upgrade().expect("the draft was dropped");
        assert!(held.read_with(vcx, |p, _| p.has_refused_draft()));
        drop(held);
        // The switch's answer, then account A again.
        stores
            .accounts
            .update(vcx, |a, cx| a.adopt(accounts("b"), cx));
        vcx.run_until_parked();
        on_b.store(false, Ordering::SeqCst);
        stores
            .accounts
            .update(vcx, |a, cx| a.adopt(accounts("a"), cx));
        vcx.run_until_parked();
        assert_eq!(made_under_b.load(Ordering::SeqCst), 0);
        assert_eq!(
            talus(&daemon, Some("a")),
            2,
            "the draft was not offered again under A (or not for A)"
        );

        // While the desktop's own switch is in flight, no recovery is
        // offered or answered: not this account yet.
        stores
            .navigation
            .update(vcx, |n, cx| n.open_item(AreaItem::Note("n1".into()), cx));
        vcx.run_until_parked();
        let pane = bench::pane(&area, vcx);
        let late = daemon.hold::<methods::NotesSave>();
        pane.update(vcx, |p, cx| {
            p.editor.update(cx, |e, cx| e.insert_text("Scarp ", cx));
            p.save_now(cx);
        });
        drop(pane);
        stores
            .navigation
            .update(vcx, |n, cx| n.open_item(AreaItem::AllNotes, cx));
        vcx.run_until_parked();
        daemon.returns::<methods::AccountsSwitch>(conduit_protocol::AccountChangeResult {
            outcome: conduit_protocol::AccountChangeOutcome::Done,
            accounts: accounts("b"),
        });
        let switching = daemon.hold::<methods::AccountsSwitch>();
        stores.accounts.update(vcx, |a, cx| {
            a.change(
                crate::stores::accounts::AccountChange::Switch {
                    account_id: "b".into(),
                },
                false,
                cx,
            )
            .detach()
        });
        drop(late);
        vcx.run_until_parked();
        let scarp = |daemon: &crate::stores::rpc::fake::FakeDaemon| {
            daemon
                .calls::<methods::NotesSave>()
                .iter()
                .filter(|s| s["id"].is_null() && s.to_string().contains("Scarp"))
                .count()
        };
        assert_eq!(
            scarp(&daemon),
            0,
            "a recovery was offered while the switch was in flight"
        );
        drop(switching);
        vcx.run_until_parked();
        stores
            .accounts
            .update(vcx, |a, cx| a.adopt(accounts("a"), cx));
        vcx.run_until_parked();
        assert_eq!(
            scarp(&daemon),
            1,
            "the draft was not offered once A was back"
        );
    }

    /// A note's draft that conduitd refuses because another account is
    /// active now stays with its pane (never saved to the new account, not
    /// tried again meanwhile), and is saved once its own account is back.
    #[gpui_kit::test]
    fn a_draft_refused_for_another_account_waits_for_its_account(
        cx: &mut gpui_kit::TestAppContext,
    ) {
        use crate::stores::accounts::tests::{account, list};
        use crate::stores::navigation::AreaItem;
        let (daemon, stores, area, vcx) = bench::open(cx);
        let accounts = |active: &str| {
            list(vec![
                account("a", "Avery", active == "a", true),
                account("b", "Blair", active == "b", true),
            ])
        };
        stores
            .accounts
            .update(vcx, |a, cx| a.adopt(accounts("a"), cx));
        let pane = bench::pane(&area, vcx);
        let refuse = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(true));
        let r = refuse.clone();
        daemon.on::<methods::NotesSave>(move |p| {
            if r.load(std::sync::atomic::Ordering::SeqCst) {
                let mut e =
                    conduit_daemon::protocol::error("auth.sessionExpired", "another account");
                e.args.insert("reason".into(), "account".into());
                return Err(e);
            }
            let page = p["pageId"].as_str().unwrap_or("main").to_string();
            Ok(serde_json::to_value(bench::detail("n1", &page, "kept")).unwrap())
        });
        // Account B may have opened the same (shared) note: conduitd would
        // take the save. The pane sends none while B is active.
        refuse.store(false, std::sync::atomic::Ordering::SeqCst);
        pane.update(vcx, |p, cx| {
            p.editor.update(cx, |e, cx| e.insert_text("Cairn ", cx))
        });
        let weak = pane.downgrade();
        drop(pane);
        stores
            .accounts
            .update(vcx, |a, cx| a.adopt(accounts("b"), cx));
        stores
            .navigation
            .update(vcx, |n, cx| n.open_item(AreaItem::AllNotes, cx));
        vcx.run_until_parked();
        vcx.executor().advance_clock(RETRY_DELAY * 3);
        vcx.run_until_parked();
        assert_eq!(
            daemon.calls::<methods::NotesSave>().len(),
            0,
            "account A's draft was sent while account B was active"
        );
        assert!(weak.upgrade().is_some(), "the held draft was dropped");
        // Account A again: the draft is saved, under it.
        stores
            .accounts
            .update(vcx, |a, cx| a.adopt(accounts("a"), cx));
        vcx.run_until_parked();
        let saves = daemon.calls::<methods::NotesSave>();
        assert_eq!(
            saves.len(),
            1,
            "the draft was not saved once its account was back"
        );
        assert!(saves[0].to_string().contains("Cairn"));

        // A save sent under A that conduitd refused as another account's
        // (B active by then), the refusal answered only once A is back: the
        // draft is tried again under A, not held for good.
        stores
            .navigation
            .update(vcx, |n, cx| n.open_item(AreaItem::Note("n1".into()), cx));
        vcx.run_until_parked();
        let pane = bench::pane(&area, vcx);
        refuse.store(true, std::sync::atomic::Ordering::SeqCst);
        let late = daemon.hold::<methods::NotesSave>();
        pane.update(vcx, |p, cx| {
            p.editor.update(cx, |e, cx| e.insert_text("Ledge ", cx));
            p.save_now(cx);
        });
        drop(pane);
        stores
            .accounts
            .update(vcx, |a, cx| a.adopt(accounts("b"), cx));
        stores
            .navigation
            .update(vcx, |n, cx| n.open_item(AreaItem::AllNotes, cx));
        vcx.run_until_parked();
        stores
            .accounts
            .update(vcx, |a, cx| a.adopt(accounts("a"), cx));
        vcx.run_until_parked();
        drop(late);
        vcx.run_until_parked();
        refuse.store(false, std::sync::atomic::Ordering::SeqCst);
        vcx.executor().advance_clock(RETRY_DELAY);
        vcx.run_until_parked();
        let saves = daemon.calls::<methods::NotesSave>();
        assert!(
            saves
                .last()
                .is_some_and(|s| s.to_string().contains("Ledge"))
                && saves.len() == 3,
            "the draft stayed held with its account back: {} saves",
            saves.len()
        );
    }

    /// Quit saves the note's unsaved text first: the app quits (and the
    /// daemon stops) only once the save has landed, or after 3 s at most.
    #[gpui_kit::test]
    fn quit_waits_for_the_notes_save(cx: &mut gpui_kit::TestAppContext) {
        let (daemon, _stores, area, vcx) = bench::open(cx);
        let pane = bench::pane(&area, vcx);
        daemon.on::<methods::NotesSave>(|p| {
            let page = p["pageId"].as_str().unwrap_or("main").to_string();
            Ok(serde_json::to_value(bench::detail("n1", &page, "kept")).unwrap())
        });
        let quits = Rc::new(std::cell::Cell::new(0));
        let quit = |vcx: &mut gpui_kit::VisualTestContext| {
            let q = quits.clone();
            vcx.update(|_, cx| {
                crate::views::sheet::quit_with(cx, Rc::new(move |_| q.set(q.get() + 1)))
            });
        };
        // Typed just now: the autosave pause has not passed.
        let held = daemon.hold::<methods::NotesSave>();
        pane.update(vcx, |p, cx| {
            p.editor.update(cx, |e, cx| e.insert_text("Cairn ", cx))
        });
        quit(vcx);
        vcx.run_until_parked();
        assert_eq!(
            daemon.calls::<methods::NotesSave>().len(),
            1,
            "Quit did not save the note"
        );
        assert_eq!(quits.get(), 0, "the app quit before the note's save landed");
        drop(held);
        vcx.run_until_parked();
        assert_eq!(quits.get(), 1);

        // A save that never answers holds Quit back 3 s at most.
        let held = daemon.hold::<methods::NotesSave>();
        pane.update(vcx, |p, cx| {
            p.editor.update(cx, |e, cx| e.insert_text("again ", cx))
        });
        quit(vcx);
        vcx.run_until_parked();
        assert_eq!(quits.get(), 1);
        vcx.executor().advance_clock(Duration::from_secs(3));
        vcx.run_until_parked();
        assert_eq!(
            quits.get(),
            2,
            "a save that never answered kept the app from quitting"
        );
        drop(held);
        vcx.run_until_parked();

        // A dictation still finishing on a saved note: Quit waits for its
        // last words and their save.
        pane.update(vcx, |p, _| {
            p.run = Some(DictationRun {
                anchor: 0,
                len: 0,
                started: false,
                revision: 0,
            })
        });
        quit(vcx);
        vcx.run_until_parked();
        assert_eq!(
            quits.get(),
            2,
            "Quit went before the dictation's last words"
        );
        pane.update(vcx, |p, cx| {
            p.on_dictation(
                &DictationEvent::Text {
                    text: "summit".into(),
                    done: true,
                },
                cx,
            );
            p.on_dictation(&DictationEvent::Ended { restore: false }, cx);
        });
        vcx.run_until_parked();
        assert_eq!(quits.get(), 3);
        assert!(
            daemon
                .calls::<methods::NotesSave>()
                .last()
                .is_some_and(|s| s.to_string().contains("summit"))
        );

        // A recording on its way to conduitd: Quit waits until it has it.
        daemon.returns::<methods::NotesAddRecording>(conduit_protocol::NoteRecordings {
            note_id: "n1".into(),
            recordings: vec![],
        });
        let handing = daemon.hold::<methods::NotesAddRecording>();
        pane.update(vcx, |p, cx| {
            p.keep_recording("/tmp/take.wav".into(), "main".into(), cx)
        });
        quit(vcx);
        vcx.run_until_parked();
        assert_eq!(
            quits.get(),
            3,
            "Quit went before conduitd had the recording"
        );
        drop(handing);
        vcx.run_until_parked();
        assert_eq!(quits.get(), 4);
    }

    /// A dictation still finishing when the note is left keeps the pane
    /// until it ends: its last words are saved, then the pane goes.
    #[gpui_kit::test]
    fn a_note_left_while_dictating_stays_until_the_words_are_in(cx: &mut gpui_kit::TestAppContext) {
        use crate::stores::navigation::AreaItem;
        let (daemon, stores, area, vcx) = bench::open(cx);
        daemon.on::<methods::NotesSave>(|p| {
            let page = p["pageId"].as_str().unwrap_or("main").to_string();
            Ok(serde_json::to_value(bench::detail("n1", &page, "kept")).unwrap())
        });
        let pane = bench::pane(&area, vcx);
        pane.update(vcx, |p, _| {
            p.run = Some(DictationRun {
                anchor: 0,
                len: 0,
                started: false,
                revision: 0,
            })
        });
        stores
            .navigation
            .update(vcx, |n, cx| n.open_item(AreaItem::AllNotes, cx));
        vcx.run_until_parked();
        let weak = pane.downgrade();
        drop(pane);
        let pane = weak
            .upgrade()
            .expect("the pane went before its dictation ended");
        pane.update(vcx, |p, cx| {
            p.on_dictation(
                &DictationEvent::Text {
                    text: "summit".into(),
                    done: true,
                },
                cx,
            );
            p.on_dictation(&DictationEvent::Ended { restore: false }, cx);
        });
        vcx.run_until_parked();
        let saved = daemon.calls::<methods::NotesSave>();
        assert!(
            saved
                .last()
                .is_some_and(|s| s.to_string().contains("summit")),
            "the dictation's words were not saved: {saved:?}"
        );
        drop(pane);
        vcx.executor().advance_clock(SAVE_DELAY);
        vcx.run_until_parked();
        assert!(
            weak.upgrade().is_none(),
            "the pane stayed once its words were in"
        );
    }

    /// Show Draft, chosen while another note is shown with unsaved text:
    /// that note is left the usual way (saved) before the draft comes back.
    #[gpui_kit::test]
    fn show_draft_saves_the_note_shown_first(cx: &mut gpui_kit::TestAppContext) {
        use crate::stores::navigation::AreaItem;
        let (daemon, stores, area, vcx) = bench::open(cx);
        vcx.update(|_, cx| cx.set_global(crate::shell::sheet::AutoAnswer(Some(false))));
        daemon.on::<methods::NotesSave>(|p| {
            let id = p["id"].as_str().unwrap_or("n9").to_string();
            if id == "n1" {
                let mut e = conduit_daemon::protocol::error("conflict", "read-only now");
                e.args.insert("reason".into(), "readOnly".into());
                return Err(e);
            }
            Ok(serde_json::to_value(bench::detail(&id, "main", "kept")).unwrap())
        });
        let pane = bench::pane(&area, vcx);
        let late = daemon.hold::<methods::NotesSave>();
        pane.update(vcx, |p, cx| {
            p.editor.update(cx, |e, cx| e.insert_text("Cairn ", cx));
            p.save_now(cx);
        });
        drop(pane);
        stores
            .navigation
            .update(vcx, |n, cx| n.open_item(AreaItem::Note("n2".into()), cx));
        vcx.run_until_parked();
        let shown = bench::pane(&area, vcx);
        shown.update(vcx, |p, cx| {
            p.editor.update(cx, |e, cx| e.insert_text("Basalt ", cx))
        });
        drop(shown);
        // A's refusal comes in; Show Draft brings A back over B.
        drop(late);
        vcx.run_until_parked();
        assert!(
            daemon
                .calls::<methods::NotesSave>()
                .iter()
                .any(|s| s["id"] == "n2" && s.to_string().contains("Basalt")),
            "the note shown lost its unsaved text to Show Draft"
        );
        assert_eq!(
            bench::pane(&area, vcx).read_with(vcx, |p, _| p.note_id().to_string()),
            "n1"
        );
    }

    /// Two refreshes answered in reverse order: the older answer, coming
    /// last, does not replace what the newer one brought.
    #[gpui_kit::test]
    fn the_newest_refresh_wins(cx: &mut gpui_kit::TestAppContext) {
        let (daemon, _stores, area, vcx) = bench::open(cx);
        let pane = bench::pane(&area, vcx);
        let text = std::sync::Arc::new(std::sync::Mutex::new("Ridge at dusk".to_string()));
        let t = text.clone();
        daemon.on::<methods::NotesGet>(move |p| {
            let id = p["id"].as_str().unwrap_or("n1");
            let body = t.lock().unwrap().clone();
            Ok(serde_json::to_value(conduit_protocol::NoteResult {
                note: Some(bench::detail(id, "main", &body)),
            })
            .unwrap())
        });
        let older = daemon.hold_one::<methods::NotesGet>(0);
        pane.update(vcx, |p, cx| p.changed_elsewhere(cx));
        vcx.run_until_parked();
        *text.lock().unwrap() = "Ridge at night".into();
        pane.update(vcx, |p, cx| p.changed_elsewhere(cx));
        vcx.run_until_parked();
        assert_eq!(bench::text(&pane, vcx), "Ridge at night");
        // The older answer, as the server had it then.
        *text.lock().unwrap() = "Ridge at dusk".into();
        older.release();
        vcx.run_until_parked();
        assert_eq!(
            bench::text(&pane, vcx),
            "Ridge at night",
            "an older refresh replaced a newer one"
        );
    }

    /// A refresh asked before a newer title was saved brings the old title
    /// back to nothing: the title saved stays (and a later save keeps it).
    #[gpui_kit::test]
    fn a_late_refresh_keeps_a_newer_saved_title(cx: &mut gpui_kit::TestAppContext) {
        let (daemon, _stores, area, vcx) = bench::open(cx);
        let pane = bench::pane(&area, vcx);
        daemon.on::<methods::NotesSave>(|p| {
            let page = p["pageId"].as_str().unwrap_or("main").to_string();
            Ok(serde_json::to_value(bench::detail("n1", &page, "Ridge at dawn")).unwrap())
        });
        let refresh = daemon.hold_one::<methods::NotesGet>(0);
        pane.update(vcx, |p, cx| p.changed_elsewhere(cx));
        vcx.run_until_parked();
        pane.update_in(vcx, |p, window, cx| {
            p.title
                .update(cx, |t, cx| t.set_value("Trail log, ridge", window, cx));
            p.save_now(cx);
        });
        vcx.run_until_parked();
        refresh.release();
        vcx.run_until_parked();
        assert_eq!(
            pane.read_with(vcx, |p, cx| p.title.read(cx).value().to_string()),
            "Trail log, ridge",
            "a refresh older than the title's save put the old title back"
        );
    }

    /// Answers for a page the pane no longer shows are let go: a refresh
    /// of the page left, and an older page load answering after a newer
    /// one, leave the page shown as it is.
    #[gpui_kit::test]
    fn a_page_left_takes_no_late_answer(cx: &mut gpui_kit::TestAppContext) {
        let (daemon, _stores, area, vcx) = bench::open(cx);
        let pane = bench::pane(&area, vcx);
        assert_eq!(bench::text(&pane, vcx), "Ridge at dawn");
        // The main page's refresh is held; page 2 opens meanwhile.
        let refresh = daemon.hold_one::<methods::NotesGet>(0);
        pane.update(vcx, |p, cx| p.changed_elsewhere(cx));
        vcx.run_until_parked();
        pane.update_in(vcx, |p, window, cx| p.show_page("p2".into(), window, cx));
        vcx.run_until_parked();
        assert_eq!(bench::text(&pane, vcx), "Second page");
        refresh.release();
        vcx.run_until_parked();
        assert_eq!(
            bench::text(&pane, vcx),
            "Second page",
            "the page left's refresh replaced the page shown"
        );
        // Page 3 is asked for, held; page 1 then answers first... the
        // older load must not win over the newer one.
        let older = daemon.hold_one::<methods::NotesGet>(0);
        pane.update_in(vcx, |p, window, cx| p.show_page("p3".into(), window, cx));
        vcx.run_until_parked();
        pane.update_in(vcx, |p, window, cx| {
            p.open_page(Some("main".into()), window, cx)
        });
        vcx.run_until_parked();
        assert_eq!(bench::text(&pane, vcx), "Ridge at dawn");
        older.release();
        vcx.run_until_parked();
        assert_eq!(
            bench::text(&pane, vcx),
            "Ridge at dawn",
            "an older page load replaced the newer page"
        );

        // A dictation still finishing: the page changes once its last words
        // are in (and saved) on the page they were said on.
        daemon.on::<methods::NotesSave>(|p| {
            let page = p["pageId"].as_str().unwrap_or("main").to_string();
            Ok(serde_json::to_value(bench::detail("n1", &page, "kept")).unwrap())
        });
        pane.update(vcx, |p, cx| {
            let end = p.editor.read(cx).doc.plain_text().len();
            p.run = Some(DictationRun {
                anchor: end,
                len: 0,
                started: false,
                revision: p.editor.read(cx).revision(),
            })
        });
        pane.update_in(vcx, |p, window, cx| p.show_page("p2".into(), window, cx));
        vcx.run_until_parked();
        assert_eq!(
            bench::text(&pane, vcx),
            "Ridge at dawn",
            "the page changed before the dictation's last words were in"
        );
        pane.update(vcx, |p, cx| {
            p.on_dictation(
                &DictationEvent::Text {
                    text: "summit".into(),
                    done: true,
                },
                cx,
            );
            p.on_dictation(&DictationEvent::Ended { restore: false }, cx);
        });
        vcx.run_until_parked();
        assert_eq!(bench::text(&pane, vcx), "Second page");
        let saves = daemon.calls::<methods::NotesSave>();
        let last = saves.last().map(|s| s.to_string()).unwrap_or_default();
        assert!(
            last.contains("summit") && last.contains("\"pageId\":\"main\""),
            "the last words were not saved on their own page: {last}"
        );
        // One that never ends holds the page change back 3 s at most, and
        // says nothing more after it.
        pane.update(vcx, |p, cx| {
            p.run = Some(DictationRun {
                anchor: 0,
                len: 0,
                started: false,
                revision: p.editor.read(cx).revision(),
            })
        });
        pane.update_in(vcx, |p, window, cx| p.show_page("p3".into(), window, cx));
        vcx.run_until_parked();
        assert_eq!(bench::text(&pane, vcx), "Second page");
        vcx.executor().advance_clock(RUN_END_WAIT);
        vcx.run_until_parked();
        assert_eq!(bench::text(&pane, vcx), "Third page");
        assert!(pane.read_with(vcx, |p, _| p.run.is_none()));
    }

    /// Typing while a dictation runs ends it: its later words never
    /// overwrite what was typed, and a start left inside a character by an
    /// edit before it panics nothing.
    #[gpui_kit::test]
    fn typing_during_a_dictation_ends_it_and_keeps_the_typing(cx: &mut gpui_kit::TestAppContext) {
        let (_daemon, _stores, area, vcx) = bench::open(cx);
        let pane = bench::pane(&area, vcx);
        let say = |pane: &Entity<NotePane>, text: &str, vcx: &mut gpui_kit::VisualTestContext| {
            pane.update(vcx, |p, cx| {
                p.on_dictation(
                    &DictationEvent::Text {
                        text: text.into(),
                        done: false,
                    },
                    cx,
                )
            });
            vcx.run_until_parked();
        };
        // A start left inside "é" (byte 2).
        pane.update(vcx, |p, cx| {
            p.editor.update(cx, |e, cx| {
                e.set_doc(
                    Doc::from_ops(&[serde_json::json!({ "insert": "aéb\n" })]),
                    true,
                    cx,
                )
            });
        });
        vcx.run_until_parked();
        pane.update(vcx, |p, _| {
            p.run = Some(DictationRun {
                anchor: 2,
                len: 0,
                started: false,
                revision: 0,
            })
        });
        say(&pane, "summit", vcx);
        assert!(bench::text(&pane, vcx).contains("summit"));

        // Words in, then typing before them: the next words leave it be.
        pane.update(vcx, |p, cx| {
            p.editor.update(cx, |e, cx| {
                e.set_doc(
                    Doc::from_ops(&[serde_json::json!({ "insert": "Ridge\n" })]),
                    true,
                    cx,
                );
                e.select_to(super::super::doc::Pos::new(0, 5), false, cx);
            });
        });
        vcx.run_until_parked();
        pane.update(vcx, |p, _| {
            p.run = Some(DictationRun {
                anchor: 5,
                len: 0,
                started: false,
                revision: 0,
            })
        });
        say(&pane, "summit", vcx);
        assert_eq!(bench::text(&pane, vcx), "Ridge summit");
        pane.update(vcx, |p, cx| {
            p.editor.update(cx, |e, cx| {
                e.select_to(super::super::doc::Pos::new(0, 0), false, cx);
                e.insert_text("Éa ", cx);
            })
        });
        vcx.run_until_parked();
        say(&pane, "summit peak", vcx);
        assert_eq!(
            bench::text(&pane, vcx),
            "Éa Ridge summit",
            "the dictation's words went over what was typed"
        );
    }
}
