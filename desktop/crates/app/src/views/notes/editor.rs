//! The note editor: a rich-text editor built on GPUI Kit's editor host.
//!
//! **Design.** The editor owns its document ([`Doc`]: blocks with inline
//! marks) and every editing rule; GPUI Kit only draws. Each render turns
//! the document into the block tree Kit's `TextView` renders for chat
//! answers (headings, lists with their checkboxes, quotes, code blocks,
//! marked runs), with one leaf key per block ([`super::element`]); Kit
//! reports back where each leaf's text was laid out
//! (`editor_host::collect_leaf_geometry`), and that geometry is what the
//! caret is drawn at, clicks are hit-tested against, ↑ and ↓ move through,
//! and IME places its candidate window by. The selection and Find's
//! matches are painted by Kit behind the text, as decorations.
//!
//! So text is WYSIWYG-lite: what the note will look like on the web and on
//! the phone, edited in place, with no markdown syntax showing. Typing is
//! the platform's text input (`EntityInputHandler`), so dead keys, the
//! emoji picker and IME composition (with marked text) work as in any Mac
//! text view; undo groups typing the way AppKit does.
//!
//! **What it edits:** paragraphs; headings 1–3 (up to 6 are kept); bulleted,
//! numbered and checklist items with their indent (Tab, ⇧Tab); quotes;
//! code blocks; bold (⌘B), italic (⌘I), strikethrough (⇧⌘X), inline code
//! (⌘E) and links (⌘K). Typing `# `, `- `, `1. `, `[] `, `> ` or ``` at the
//! start of a line turns it into that block, as the phone's editor does.
//! A paragraph that only links a server file is drawn as the file's card
//! ([`super::element`]) and steps as one piece.

use std::collections::HashMap;
use std::ops::Range;
use std::rc::Rc;
use std::time::{Duration, Instant};

use gpui_kit::base::text::editor_host::LeafGeometry;
use gpui_kit::{
    App, Bounds, ClipboardItem, Context, Entity, EntityInputHandler, EventEmitter, FocusHandle,
    Focusable, KeyBinding, Pixels, Point, ScrollHandle, SharedString, Task, UTF16Selection, Window,
    actions, point, px,
};
use serde_json::Value;

use super::doc::{Block, BlockKind, Doc, FileLink, Mark, Marks, Pos, Selection, blocks_from_ops};
// The Edit menu's own actions, so its items work (and show their keys)
// while a note is edited.
pub use gpui_kit::component::input::{Copy, Cut, Paste, Redo, SelectAll, Undo};

/// The key context the editor's bindings live in.
pub const EDITOR_CONTEXT: &str = "NoteEditor";

actions!(
    note_editor,
    [
        MoveLeft,
        MoveRight,
        MoveUp,
        MoveDown,
        MoveWordLeft,
        MoveWordRight,
        MoveLineStart,
        MoveLineEnd,
        MoveDocStart,
        MoveDocEnd,
        PageUp,
        PageDown,
        SelectLeft,
        SelectRight,
        SelectUp,
        SelectDown,
        SelectWordLeft,
        SelectWordRight,
        SelectLineStart,
        SelectLineEnd,
        SelectDocStart,
        SelectDocEnd,
        Backspace,
        Delete,
        DeleteWordLeft,
        DeleteWordRight,
        DeleteLineLeft,
        Newline,
        Indent,
        Outdent,
        PastePlain,
        ToggleBold,
        ToggleItalic,
        ToggleStrike,
        ToggleCode,
        AddLink,
        Title,
        Heading,
        Subheading,
        Body,
        BulletList,
        NumberedList,
        Checklist,
        ToggleChecked,
        QuoteBlock,
        CodeBlock,
    ]
);

/// The editor's key bindings, in its own context (they win over the
/// window's while a note is being edited: ⌘K is Add Link there, ⌘I
/// Italic).
pub fn bindings() -> Vec<KeyBinding> {
    let c = Some(EDITOR_CONTEXT);
    vec![
        KeyBinding::new("left", MoveLeft, c),
        KeyBinding::new("right", MoveRight, c),
        KeyBinding::new("up", MoveUp, c),
        KeyBinding::new("down", MoveDown, c),
        KeyBinding::new("alt-left", MoveWordLeft, c),
        KeyBinding::new("alt-right", MoveWordRight, c),
        KeyBinding::new("cmd-left", MoveLineStart, c),
        KeyBinding::new("cmd-right", MoveLineEnd, c),
        KeyBinding::new("ctrl-a", MoveLineStart, c),
        KeyBinding::new("ctrl-e", MoveLineEnd, c),
        KeyBinding::new("home", MoveDocStart, c),
        KeyBinding::new("end", MoveDocEnd, c),
        KeyBinding::new("cmd-up", MoveDocStart, c),
        KeyBinding::new("cmd-down", MoveDocEnd, c),
        KeyBinding::new("pageup", PageUp, c),
        KeyBinding::new("pagedown", PageDown, c),
        KeyBinding::new("shift-left", SelectLeft, c),
        KeyBinding::new("shift-right", SelectRight, c),
        KeyBinding::new("shift-up", SelectUp, c),
        KeyBinding::new("shift-down", SelectDown, c),
        KeyBinding::new("alt-shift-left", SelectWordLeft, c),
        KeyBinding::new("alt-shift-right", SelectWordRight, c),
        KeyBinding::new("cmd-shift-left", SelectLineStart, c),
        KeyBinding::new("cmd-shift-right", SelectLineEnd, c),
        KeyBinding::new("cmd-shift-up", SelectDocStart, c),
        KeyBinding::new("cmd-shift-down", SelectDocEnd, c),
        KeyBinding::new("shift-home", SelectDocStart, c),
        KeyBinding::new("shift-end", SelectDocEnd, c),
        KeyBinding::new("cmd-a", SelectAll, c),
        KeyBinding::new("backspace", Backspace, c),
        KeyBinding::new("shift-backspace", Backspace, c),
        KeyBinding::new("ctrl-h", Backspace, c),
        KeyBinding::new("delete", Delete, c),
        KeyBinding::new("ctrl-d", Delete, c),
        KeyBinding::new("alt-backspace", DeleteWordLeft, c),
        KeyBinding::new("alt-delete", DeleteWordRight, c),
        KeyBinding::new("cmd-backspace", DeleteLineLeft, c),
        KeyBinding::new("enter", Newline, c),
        KeyBinding::new("shift-enter", Newline, c),
        KeyBinding::new("tab", Indent, c),
        KeyBinding::new("shift-tab", Outdent, c),
        KeyBinding::new("cmd-c", Copy, c),
        KeyBinding::new("cmd-x", Cut, c),
        KeyBinding::new("cmd-v", Paste, c),
        KeyBinding::new("alt-shift-cmd-v", PastePlain, c),
        KeyBinding::new("cmd-z", Undo, c),
        KeyBinding::new("shift-cmd-z", Redo, c),
        KeyBinding::new("cmd-b", ToggleBold, c),
        KeyBinding::new("cmd-i", ToggleItalic, c),
        KeyBinding::new("shift-cmd-x", ToggleStrike, c),
        KeyBinding::new("cmd-e", ToggleCode, c),
        KeyBinding::new("cmd-k", AddLink, c),
        // Format › Paragraph Style, as Notes names and binds them.
        KeyBinding::new("shift-cmd-t", Title, c),
        KeyBinding::new("shift-cmd-h", Heading, c),
        KeyBinding::new("shift-cmd-j", Subheading, c),
        KeyBinding::new("shift-cmd-b", Body, c),
        KeyBinding::new("shift-cmd-7", BulletList, c),
        KeyBinding::new("shift-cmd-9", NumberedList, c),
        // Notes' ⇧⌘L is Dictate here (it writes into the note).
        KeyBinding::new("shift-cmd-8", Checklist, c),
        KeyBinding::new("shift-cmd-u", ToggleChecked, c),
        KeyBinding::new("cmd-'", QuoteBlock, c),
        KeyBinding::new("alt-cmd-c", CodeBlock, c),
    ]
}

/// What the note pane hears from its editor.
#[derive(Clone, Debug, PartialEq)]
pub enum EditorEvent {
    /// The document changed (the pane saves it after a pause).
    Edited,
    /// The caret or the selection moved (the toolbar's state).
    Selected,
    /// ⌘K or the toolbar's Link: the pane asks for an address. `current`
    /// is the link the selection is in.
    LinkRequested { current: Option<String> },
    /// A link was ⌘-clicked.
    OpenLink(String),
    /// A file card's action.
    File(FileLink, FileAction),
    /// The editor lost focus (the pane saves at once).
    Blurred,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FileAction {
    /// A recording: Play or Pause in the note.
    Play,
    QuickLook,
    Open,
    Download,
    Transcribe,
    Remove,
}

/// What the last frame laid out, for the caret, clicks and ↑↓.
#[derive(Default)]
pub struct Layout {
    /// Each text block's leaf, by block id.
    pub leaves: HashMap<u64, LeafGeometry>,
    /// The editor's bounds.
    pub bounds: Bounds<Pixels>,
}

/// One undo step: the document and selection before an edit.
#[derive(Clone)]
struct Snapshot {
    doc: Doc,
    selection: Selection,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum EditKind {
    Typing,
    Deleting,
    Other,
}

#[derive(Default)]
struct History {
    undo: Vec<Snapshot>,
    redo: Vec<Snapshot>,
    /// The kind and time of the last edit: typing (or deleting) within a
    /// moment of the last, at the caret it left, is one step.
    last: Option<(EditKind, Instant, Pos)>,
}

const HISTORY_LIMIT: usize = 200;
const TYPING_GROUP: Duration = Duration::from_millis(1200);

/// Find in Note: the query and where it matches.
#[derive(Default)]
pub struct Find {
    pub query: String,
    pub matches: Vec<(Pos, Pos)>,
    pub current: usize,
}

/// How a mouse drag extends the selection.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DragUnit {
    Char,
    Word,
    Block,
}

/// The words a file card shows.
#[derive(Clone, Default)]
pub struct CardLabels {
    pub play: SharedString,
    pub pause: SharedString,
    /// The scrubber's name ("Playback Position").
    pub position: SharedString,
    pub audio_failed: SharedString,
    pub audio_loading: SharedString,
    pub quick_look: SharedString,
    pub download: SharedString,
    pub transcribe: SharedString,
    pub remove: SharedString,
    pub more: SharedString,
    pub audio: SharedString,
    pub file: SharedString,
}

pub struct NoteEditor {
    pub doc: Doc,
    selection: Selection,
    /// IME composition: the marked text's range.
    marked: Option<(Pos, Pos)>,
    /// ⌘B with nothing selected: the marks the next typing gets.
    typing_marks: Option<Marks>,
    /// ↑ and ↓ keep to this x across short lines.
    goal_x: Option<Pixels>,
    pub(super) focus: FocusHandle,
    pub(super) scroll: ScrollHandle,
    history: History,
    pub(super) layout: Rc<std::cell::RefCell<Layout>>,
    pub find: Find,
    read_only: bool,
    pub(super) placeholder: SharedString,
    pub(super) label: SharedString,
    /// Bumped on every edit.
    revision: u64,
    /// The caret's blink: shown while true.
    pub(super) caret_on: bool,
    _blink: Option<Task<()>>,
    /// Scroll the caret into view on the next frame.
    pub(super) reveal: bool,
    pub(super) drag: Option<DragUnit>,
    /// The cards' labels, from the pane (localized).
    pub(super) card_labels: CardLabels,
    /// The note's player, for its recordings' cards (the pane's).
    pub(super) audio: Option<Entity<super::audio::NoteAudio>>,
}

impl EventEmitter<EditorEvent> for NoteEditor {}

impl Focusable for NoteEditor {
    fn focus_handle(&self, _: &App) -> FocusHandle {
        self.focus.clone()
    }
}

impl NoteEditor {
    pub fn new(window: &mut Window, cx: &mut Context<Self>) -> Self {
        let focus = cx.focus_handle();
        cx.on_focus_in(&focus, window, |e: &mut Self, _, cx| e.focused(cx))
            .detach();
        cx.on_blur(&focus, window, |e: &mut Self, _, cx| e.blurred(cx))
            .detach();
        Self {
            doc: Doc::default(),
            selection: Selection::default(),
            marked: None,
            typing_marks: None,
            goal_x: None,
            focus,
            scroll: ScrollHandle::new(),
            history: History::default(),
            layout: Rc::default(),
            find: Find::default(),
            read_only: false,
            placeholder: SharedString::default(),
            label: SharedString::default(),
            revision: 0,
            caret_on: true,
            _blink: None,
            reveal: false,
            drag: None,
            card_labels: CardLabels::default(),
            audio: None,
        }
    }

    // ── State ────────────────────────────────────────────────────────────

    pub fn revision(&self) -> u64 {
        self.revision
    }

    pub fn selection(&self) -> Selection {
        self.selection
    }

    pub fn is_read_only(&self) -> bool {
        self.read_only
    }

    pub fn set_read_only(&mut self, read_only: bool, cx: &mut Context<Self>) {
        if self.read_only != read_only {
            self.read_only = read_only;
            self.marked = None;
            cx.notify();
        }
    }

    pub fn set_placeholder(&mut self, text: SharedString, label: SharedString) {
        self.placeholder = text;
        self.label = label;
    }

    pub fn set_card_labels(&mut self, labels: CardLabels) {
        self.card_labels = labels;
    }

    /// The note's player: its recordings' cards show it, and redraw as it
    /// plays.
    pub fn set_audio(&mut self, audio: Entity<super::audio::NoteAudio>, cx: &mut Context<Self>) {
        cx.observe(&audio, |_, _, cx| cx.notify()).detach();
        self.audio = Some(audio);
    }

    pub fn marked(&self) -> Option<(Pos, Pos)> {
        self.marked
    }

    /// Replaces the document (a note opened, a page shown, an enhanced
    /// body kept), forgetting undo when `reset_history`.
    pub fn set_doc(&mut self, doc: Doc, reset_history: bool, cx: &mut Context<Self>) {
        if reset_history {
            self.history = History::default();
        } else {
            self.push_undo();
            self.history.last = None;
        }
        self.doc = doc;
        self.ensure_editable_tail();
        self.marked = None;
        self.typing_marks = None;
        let caret = self.doc.clamp(self.selection.head);
        self.selection = Selection::caret(self.skip_cards(caret, true));
        self.refind();
        if !reset_history {
            self.edited(cx);
        }
        cx.notify();
    }

    /// The document as Quill ops.
    pub fn ops(&self) -> Vec<Value> {
        self.doc.to_ops()
    }

    /// The marks at the caret, or over the whole selection (the toolbar's
    /// state).
    pub fn active_marks(&self) -> Marks {
        if let Some(marks) = &self.typing_marks {
            return marks.clone();
        }
        let s = self.selection;
        if s.is_empty() {
            return self.doc.blocks[s.head.block].marks_at(s.head.offset);
        }
        let mut marks = Marks::default();
        for mark in [Mark::Bold, Mark::Italic, Mark::Strike, Mark::Code] {
            marks.set(mark, self.doc.all_have(s.start(), s.end(), |m| m.has(mark)));
        }
        if let Some((_, url)) = self.doc.link_at(s.start()) {
            marks.link = Some(url);
        }
        marks
    }

    /// The kind of the block the caret is in.
    pub fn active_kind(&self) -> BlockKind {
        self.doc.blocks[self.selection.head.block].kind
    }

    /// The selected text, as plain text.
    pub fn selected_text(&self) -> String {
        let s = self.selection;
        self.doc.text_in(s.start(), s.end())
    }

    // ── Caret blink ─────────────────────────────────────────────────────

    /// Shows the caret and restarts its blink (on every edit and move).
    fn wake_caret(&mut self, cx: &mut Context<Self>) {
        self.caret_on = true;
        let task = cx.spawn(async move |this, cx| {
            loop {
                cx.background_executor()
                    .timer(Duration::from_millis(530))
                    .await;
                let alive = this
                    .update(cx, |e, cx| {
                        e.caret_on = !e.caret_on;
                        cx.notify();
                    })
                    .is_ok();
                if !alive {
                    break;
                }
            }
        });
        self._blink = Some(task);
    }

    /// Stops the blink (the editor lost focus).
    pub fn sleep_caret(&mut self) {
        self._blink = None;
        self.caret_on = false;
    }

    // ── Edits ───────────────────────────────────────────────────────────

    fn push_undo(&mut self) {
        self.history.undo.push(Snapshot {
            doc: self.doc.clone(),
            selection: self.selection,
        });
        if self.history.undo.len() > HISTORY_LIMIT {
            self.history.undo.remove(0);
        }
        self.history.redo.clear();
    }

    /// Records an undo step before an edit of `kind`, unless it continues
    /// the last one.
    fn checkpoint(&mut self, kind: EditKind) {
        let now = Instant::now();
        let continues = matches!(
            self.history.last,
            Some((last, at, caret)) if last == kind
                && kind != EditKind::Other
                && now.duration_since(at) < TYPING_GROUP
                && caret == self.selection.head
                && self.selection.is_empty()
        );
        if !continues {
            self.push_undo();
        }
        self.history.last = Some((kind, now, self.selection.head));
    }

    /// After an edit: the caret's place for grouping, a fresh blink, a
    /// fresh Find, and the pane told.
    fn edited(&mut self, cx: &mut Context<Self>) {
        self.ensure_editable_tail();
        self.revision += 1;
        if let Some((kind, at, _)) = self.history.last {
            self.history.last = Some((kind, at, self.selection.head));
        }
        self.goal_x = None;
        self.reveal = true;
        self.refind();
        self.wake_caret(cx);
        cx.emit(EditorEvent::Edited);
        cx.emit(EditorEvent::Selected);
        cx.notify();
    }

    /// A card last in the document has a paragraph after it, so there is
    /// somewhere to type below it.
    fn ensure_editable_tail(&mut self) {
        if self
            .doc
            .blocks
            .last()
            .is_some_and(|b| b.file_link().is_some())
        {
            let id = self.doc.new_id();
            self.doc
                .blocks
                .push(Block::new(id, BlockKind::Paragraph, ""));
        }
    }

    /// `pos`, moved off a file card: to the start of the next block going
    /// `forward`, else to the end of the one before (or after, at the top).
    fn skip_cards(&self, pos: Pos, forward: bool) -> Pos {
        let mut pos = self.doc.clamp(pos);
        let n = self.doc.blocks.len();
        let card = |i: usize| self.doc.blocks[i].file_link().is_some();
        if !card(pos.block) {
            return pos;
        }
        let after = (pos.block + 1..n).find(|&i| !card(i));
        let before = (0..pos.block).rev().find(|&i| !card(i));
        pos = match (forward, after, before) {
            (true, Some(i), _) | (false, Some(i), None) => Pos::new(i, 0),
            (_, _, Some(i)) => Pos::new(i, self.doc.blocks[i].text.len()),
            _ => pos,
        };
        pos
    }

    /// Replaces the selection with `text` (typing, a paste, dictation).
    pub fn insert_text(&mut self, text: &str, cx: &mut Context<Self>) {
        if self.read_only {
            return;
        }
        let kind = if text.chars().count() <= 2 && !text.contains('\n') {
            EditKind::Typing
        } else {
            EditKind::Other
        };
        self.checkpoint(kind);
        let mut at = self.delete_selection_raw();
        if self.doc.blocks[at.block].file_link().is_some() {
            // Never into a card: below it.
            let id = self.doc.new_id();
            self.doc
                .blocks
                .insert(at.block + 1, Block::new(id, BlockKind::Paragraph, ""));
            at = Pos::new(at.block + 1, 0);
        }
        let marks = self.typing_marks_at(at);
        let caret = self.doc.insert(at, text, &marks);
        self.selection = Selection::caret(caret);
        if kind == EditKind::Typing && text == " " {
            self.autoformat();
        }
        if kind == EditKind::Typing && text == "`" {
            self.autoformat_code();
        }
        self.edited(cx);
    }

    /// What typing at `at` is marked with: ⌘B's pending marks, else the
    /// character before's, but a link only inside it (typing after a link
    /// is plain).
    fn typing_marks_at(&mut self, at: Pos) -> Marks {
        if let Some(marks) = self.typing_marks.take() {
            return marks;
        }
        let block = &self.doc.blocks[at.block];
        let mut marks = block.marks_at(at.offset);
        if marks.link.is_some()
            && !self
                .doc
                .link_at(at)
                .is_some_and(|(r, _)| r.start < at.offset && at.offset < r.end)
        {
            marks.link = None;
        }
        marks
    }

    /// `# `, `- `, `1. `, `[] `, `> ` at a paragraph's start become its
    /// kind, as the phone's editor turns them.
    fn autoformat(&mut self) {
        let caret = self.selection.head;
        let block = &self.doc.blocks[caret.block];
        if block.kind != BlockKind::Paragraph {
            return;
        }
        let prefix = &block.text[..caret.offset];
        let numbered = prefix.len() >= 3
            && prefix.ends_with(". ")
            && prefix[..prefix.len() - 2]
                .chars()
                .all(|c| c.is_ascii_digit());
        let kind = match prefix {
            "# " => BlockKind::Heading(1),
            "## " => BlockKind::Heading(2),
            "### " => BlockKind::Heading(3),
            "- " | "* " | "+ " => BlockKind::Bullet,
            "[] " | "[ ] " | "- [ ] " => BlockKind::Check(false),
            "[x] " | "- [x] " => BlockKind::Check(true),
            "> " => BlockKind::Quote,
            _ if numbered => BlockKind::Ordered,
            _ => return,
        };
        let len = prefix.len();
        self.doc
            .delete(Pos::new(caret.block, 0), Pos::new(caret.block, len));
        self.doc.set_kind(caret.block..caret.block + 1, kind);
        self.selection = Selection::caret(Pos::new(caret.block, 0));
    }

    /// ``` alone on a line makes it a code block.
    fn autoformat_code(&mut self) {
        let caret = self.selection.head;
        let block = &self.doc.blocks[caret.block];
        if block.kind == BlockKind::Paragraph && block.text == "```" {
            self.doc.delete(Pos::new(caret.block, 0), caret);
            self.doc
                .set_kind(caret.block..caret.block + 1, BlockKind::Code);
            self.selection = Selection::caret(Pos::new(caret.block, 0));
        }
    }

    /// Deletes the selection without an undo step; returns where it was.
    fn delete_selection_raw(&mut self) -> Pos {
        let s = self.selection;
        let caret = self.doc.delete(s.start(), s.end());
        self.selection = Selection::caret(caret);
        self.marked = None;
        caret
    }

    pub fn backspace(&mut self, cx: &mut Context<Self>) {
        if self.read_only {
            return;
        }
        let s = self.selection;
        if !s.is_empty() {
            self.checkpoint(EditKind::Other);
            self.delete_selection_raw();
            self.edited(cx);
            return;
        }
        let caret = s.head;
        let block = &self.doc.blocks[caret.block];
        if caret.offset == 0 {
            // At a block's start: an indented item comes out a level, a
            // styled block becomes a paragraph, a paragraph joins the one
            // above (a card above goes).
            if block.kind.is_list() && block.indent > 0 {
                self.checkpoint(EditKind::Other);
                self.doc.blocks[caret.block].indent -= 1;
                self.edited(cx);
                return;
            }
            if block.kind != BlockKind::Paragraph {
                self.checkpoint(EditKind::Other);
                self.doc
                    .set_kind(caret.block..caret.block + 1, BlockKind::Paragraph);
                self.edited(cx);
                return;
            }
            if caret.block == 0 {
                return;
            }
            self.checkpoint(EditKind::Other);
            let above = caret.block - 1;
            if self.doc.blocks[above].file_link().is_some() {
                self.doc.blocks.remove(above);
                self.selection = Selection::caret(Pos::new(above, 0));
            } else {
                let to = self.doc.prev_char(caret);
                let at = self.doc.delete(to, caret);
                self.selection = Selection::caret(at);
            }
            self.edited(cx);
            return;
        }
        self.checkpoint(EditKind::Deleting);
        let to = self.doc.prev_char(caret);
        let at = self.doc.delete(to, caret);
        self.selection = Selection::caret(at);
        self.edited(cx);
    }

    pub fn delete_forward(&mut self, cx: &mut Context<Self>) {
        if self.read_only {
            return;
        }
        if !self.selection.is_empty() {
            self.checkpoint(EditKind::Other);
            self.delete_selection_raw();
            self.edited(cx);
            return;
        }
        let caret = self.selection.head;
        let next = self.doc.next_char(caret);
        if next == caret {
            return;
        }
        self.checkpoint(EditKind::Deleting);
        if next.block != caret.block && self.doc.blocks[next.block].file_link().is_some() {
            self.doc.blocks.remove(next.block);
        } else {
            self.doc.delete(caret, next);
        }
        self.edited(cx);
    }

    fn delete_to(&mut self, to: Pos, cx: &mut Context<Self>) {
        if self.read_only {
            return;
        }
        if !self.selection.is_empty() {
            self.checkpoint(EditKind::Other);
            self.delete_selection_raw();
            self.edited(cx);
            return;
        }
        let caret = self.selection.head;
        if to == caret {
            return;
        }
        self.checkpoint(EditKind::Other);
        let at = self.doc.delete(caret, to);
        self.selection = Selection::caret(at);
        self.edited(cx);
    }

    /// Return: a new block; an empty list item or quote line ends the list
    /// or quote instead (an indented item comes out a level first); in a
    /// code block a new line, and an empty last line ends the block.
    pub fn newline(&mut self, cx: &mut Context<Self>) {
        if self.read_only {
            return;
        }
        self.checkpoint(EditKind::Other);
        let caret = self.delete_selection_raw();
        let block = &self.doc.blocks[caret.block];
        match block.kind {
            BlockKind::Code => {
                let at_end = caret.offset == block.text.len();
                if at_end && (block.text.ends_with('\n') || block.text.is_empty()) {
                    // A blank last line ends the code block.
                    if !block.text.is_empty() {
                        let len = block.text.len();
                        self.doc
                            .delete(Pos::new(caret.block, len - 1), Pos::new(caret.block, len));
                    }
                    let id = self.doc.new_id();
                    self.doc
                        .blocks
                        .insert(caret.block + 1, Block::new(id, BlockKind::Paragraph, ""));
                    self.selection = Selection::caret(Pos::new(caret.block + 1, 0));
                } else {
                    let at = self.doc.insert(caret, "\n", &Marks::default());
                    self.selection = Selection::caret(at);
                }
            }
            kind if (kind.is_list() || kind == BlockKind::Quote) && block.text.is_empty() => {
                if block.indent > 0 {
                    self.doc.blocks[caret.block].indent -= 1;
                } else {
                    self.doc
                        .set_kind(caret.block..caret.block + 1, BlockKind::Paragraph);
                }
            }
            _ => {
                let at = self.doc.split(caret);
                self.selection = Selection::caret(at);
            }
        }
        self.edited(cx);
    }

    /// Tab in a list nests the items selected a level deeper (at most one
    /// deeper than the item above); elsewhere it types a tab.
    pub fn indent(&mut self, outdent: bool, cx: &mut Context<Self>) {
        if self.read_only {
            return;
        }
        let s = self.selection;
        let blocks: Vec<usize> = (s.start().block..=s.end().block).collect();
        let lists = blocks.iter().all(|&i| self.doc.blocks[i].kind.is_list());
        if !lists {
            if !outdent {
                self.insert_text("\t", cx);
            }
            return;
        }
        self.checkpoint(EditKind::Other);
        for i in blocks {
            let above = i
                .checked_sub(1)
                .map(|a| &self.doc.blocks[a])
                .filter(|b| b.kind.is_list())
                .map(|b| b.indent);
            let block = &mut self.doc.blocks[i];
            if outdent {
                block.indent = block.indent.saturating_sub(1);
            } else if above.is_some_and(|a| block.indent <= a) {
                block.indent = (block.indent + 1).min(8);
            }
        }
        self.edited(cx);
    }

    /// Bold, italic, strikethrough, inline code: over the selection, or for
    /// what is typed next.
    pub fn toggle_mark(&mut self, mark: Mark, cx: &mut Context<Self>) {
        if self.read_only || self.active_kind() == BlockKind::Code {
            return;
        }
        let s = self.selection;
        if s.is_empty() {
            let mut marks = self.active_marks();
            let on = !marks.has(mark);
            marks.set(mark, on);
            self.typing_marks = Some(marks);
            cx.emit(EditorEvent::Selected);
            cx.notify();
            return;
        }
        self.checkpoint(EditKind::Other);
        self.doc.toggle_mark(s.start(), s.end(), mark);
        self.edited(cx);
    }

    /// The link over the selection (or the link the caret is in), or none
    /// when `url` is empty. With nothing selected and no link there, the
    /// address goes in as its own text.
    pub fn set_link(&mut self, url: Option<String>, cx: &mut Context<Self>) {
        if self.read_only {
            return;
        }
        let url = url.map(|u| u.trim().to_string()).filter(|u| !u.is_empty());
        let s = self.selection;
        let (start, end) = if s.is_empty() {
            match self.doc.link_at(s.head) {
                Some((range, _)) => (
                    Pos::new(s.head.block, range.start),
                    Pos::new(s.head.block, range.end),
                ),
                None => {
                    if let Some(url) = url {
                        self.checkpoint(EditKind::Other);
                        let marks = Marks {
                            link: Some(url.clone()),
                            ..self.doc.blocks[s.head.block].marks_at(s.head.offset)
                        };
                        let caret = self.doc.insert(s.head, &url, &marks);
                        self.selection = Selection::caret(caret);
                        self.edited(cx);
                    }
                    return;
                }
            }
        } else {
            (s.start(), s.end())
        };
        self.checkpoint(EditKind::Other);
        self.doc.set_link(start, end, url);
        self.edited(cx);
    }

    /// The selected blocks' kind: `kind`, or a paragraph again when they
    /// all are `kind` already (the toolbar toggles).
    pub fn toggle_kind(&mut self, kind: BlockKind, cx: &mut Context<Self>) {
        if self.read_only {
            return;
        }
        let s = self.selection;
        let range = s.start().block..s.end().block + 1;
        let all = self.doc.blocks[range.clone()]
            .iter()
            .all(|b| b.kind.same_style(kind));
        let target = if all && kind != BlockKind::Paragraph {
            BlockKind::Paragraph
        } else {
            kind
        };
        self.checkpoint(EditKind::Other);
        let caret = self.doc.flat(s.head);
        let anchor = self.doc.flat(s.anchor);
        self.doc.set_kind(range, target);
        // Flat offsets survive a kind change (code joins lines with the
        // same line breaks blocks are joined with).
        self.selection = Selection {
            anchor: self.doc.unflat(anchor),
            head: self.doc.unflat(caret),
        };
        self.edited(cx);
    }

    /// Checks or unchecks the checklist items selected.
    pub fn toggle_checked(&mut self, cx: &mut Context<Self>) {
        let s = self.selection;
        self.toggle_checked_in(s.start().block..s.end().block + 1, cx);
    }

    /// Checks or unchecks the checklist items in `blocks` (a click on a
    /// box is one).
    pub fn toggle_checked_in(&mut self, blocks: Range<usize>, cx: &mut Context<Self>) {
        if self.read_only {
            return;
        }
        let is_check = |b: &Block| matches!(b.kind, BlockKind::Check(_));
        let items: Vec<usize> = blocks
            .filter(|&i| self.doc.blocks.get(i).is_some_and(is_check))
            .collect();
        if items.is_empty() {
            return;
        }
        self.checkpoint(EditKind::Other);
        let all_checked = items
            .iter()
            .all(|&i| self.doc.blocks[i].kind == BlockKind::Check(true));
        for i in items {
            self.doc.blocks[i].kind = BlockKind::Check(!all_checked);
        }
        self.edited(cx);
    }

    pub fn undo(&mut self, cx: &mut Context<Self>) {
        let Some(step) = self.history.undo.pop() else {
            return;
        };
        self.history.redo.push(Snapshot {
            doc: self.doc.clone(),
            selection: self.selection,
        });
        self.restore(step, cx);
    }

    pub fn redo(&mut self, cx: &mut Context<Self>) {
        let Some(step) = self.history.redo.pop() else {
            return;
        };
        self.history.undo.push(Snapshot {
            doc: self.doc.clone(),
            selection: self.selection,
        });
        self.restore(step, cx);
    }

    pub fn can_undo(&self) -> bool {
        !self.history.undo.is_empty()
    }

    pub fn can_redo(&self) -> bool {
        !self.history.redo.is_empty()
    }

    fn restore(&mut self, step: Snapshot, cx: &mut Context<Self>) {
        self.doc = step.doc;
        self.selection = Selection {
            anchor: self.doc.clamp(step.selection.anchor),
            head: self.doc.clamp(step.selection.head),
        };
        self.marked = None;
        self.typing_marks = None;
        self.history.last = None;
        self.edited(cx);
    }

    // ── The pane's edits ────────────────────────────────────────────────

    /// Dictation: replaces the run at flat byte `anchor`, `len` long, with
    /// `text`; the run's first update records the undo step for all of it.
    /// Returns the run's new length.
    pub fn replace_run(
        &mut self,
        anchor: usize,
        len: usize,
        text: &str,
        first: bool,
        cx: &mut Context<Self>,
    ) -> usize {
        if self.read_only {
            return len;
        }
        if first {
            self.checkpoint(EditKind::Other);
        }
        let start = self.doc.unflat(anchor);
        let end = self.doc.unflat(anchor + len);
        self.doc.delete(start, end);
        let start = self.doc.clamp(start);
        let mut marks = self.doc.blocks[start.block].marks_at(start.offset);
        marks.link = None;
        let caret = self.doc.insert(start, text, &marks);
        self.selection = Selection::caret(caret);
        self.history.last = None;
        self.edited(cx);
        self.doc.flat(caret) - self.doc.flat(start)
    }

    /// The selection's start in the flat text (where a dictation run
    /// starts), and the text before it.
    pub fn run_anchor(&self) -> (usize, String) {
        let start = self.selection.start();
        let flat = self.doc.flat(start);
        let text = self.doc.plain_text();
        (flat, text[..flat.min(text.len())].to_string())
    }

    /// Adds `text` as paragraphs after block `id` (a recording's
    /// transcript, under its card), or at the end when there is no such
    /// block; the caret goes after it.
    pub fn insert_after_block(&mut self, id: Option<u64>, text: &str, cx: &mut Context<Self>) {
        if self.read_only || text.trim().is_empty() {
            return;
        }
        self.checkpoint(EditKind::Other);
        let at = id
            .and_then(|id| self.doc.blocks.iter().position(|b| b.id == id))
            .map_or(self.doc.blocks.len(), |i| i + 1);
        let new_id = self.doc.new_id();
        self.doc
            .blocks
            .insert(at, Block::new(new_id, BlockKind::Paragraph, ""));
        let caret = self
            .doc
            .insert(Pos::new(at, 0), text.trim(), &Marks::default());
        self.selection = Selection::caret(caret);
        self.edited(cx);
    }

    /// Takes block `id` out (a file card's Remove).
    pub fn remove_block(&mut self, id: u64, cx: &mut Context<Self>) {
        let Some(i) = self.doc.blocks.iter().position(|b| b.id == id) else {
            return;
        };
        self.checkpoint(EditKind::Other);
        if self.doc.blocks.len() == 1 {
            self.doc.blocks[0] = Block::new(id, BlockKind::Paragraph, "");
        } else {
            self.doc.blocks.remove(i);
        }
        let caret = self.doc.clamp(self.selection.head);
        self.selection = Selection::caret(self.skip_cards(caret, true));
        self.edited(cx);
    }

    /// The block id of the card for file `file_id`.
    pub fn card_block(&self, file_id: &str) -> Option<u64> {
        self.doc
            .blocks
            .iter()
            .find(|b| b.file_link().is_some_and(|f| f.id == file_id))
            .map(|b| b.id)
    }

    /// Cards for `links` the document does not show yet, at its end (a
    /// recording attached, a file added), as the phone's editor puts in
    /// the cards a stored page gained.
    pub fn append_cards(&mut self, links: &[FileLink], cx: &mut Context<Self>) {
        let missing: Vec<&FileLink> = links
            .iter()
            .filter(|l| self.card_block(&l.id).is_none())
            .collect();
        if missing.is_empty() || self.read_only {
            return;
        }
        // Before a last empty paragraph, which stays last.
        let mut at = self.doc.blocks.len();
        if self
            .doc
            .blocks
            .last()
            .is_some_and(|b| b.text.is_empty() && b.kind == BlockKind::Paragraph)
            && at > 1
        {
            at -= 1;
        }
        for link in missing {
            let id = self.doc.new_id();
            let mut block = Block::new(id, BlockKind::Paragraph, "");
            let marks = Marks {
                link: Some(format!("/api/v1/files/{}/content", link.id)),
                ..Marks::default()
            };
            block.text.clear();
            self.doc.blocks.insert(at, block);
            self.doc.insert(Pos::new(at, 0), &link.name, &marks);
            at += 1;
        }
        self.edited(cx);
    }

    /// The file cards the document shows.
    pub fn cards(&self) -> Vec<FileLink> {
        self.doc
            .blocks
            .iter()
            .filter_map(Block::file_link)
            .collect()
    }

    // ── Clipboard ───────────────────────────────────────────────────────

    pub fn copy(&mut self, cx: &mut Context<Self>) {
        let s = self.selection;
        if s.is_empty() {
            return;
        }
        let text = self.doc.text_in(s.start(), s.end());
        let fragment = self.doc.fragment(s.start(), s.end());
        let ops = super::doc::blocks_to_ops(&fragment);
        cx.write_to_clipboard(ClipboardItem::new_string_with_json_metadata(
            text,
            serde_json::json!({ CLIPBOARD_KEY: ops }),
        ));
        // Other apps (Mail, Pages, Notes) paste the formatting from HTML.
        add_html_to_pasteboard(&super::doc::blocks_to_html(&fragment));
    }

    pub fn cut(&mut self, cx: &mut Context<Self>) {
        self.copy(cx);
        if self.read_only || self.selection.is_empty() {
            return;
        }
        self.checkpoint(EditKind::Other);
        self.delete_selection_raw();
        self.edited(cx);
    }

    /// Paste: a note's own copy keeps its formatting; text from elsewhere
    /// goes in as plain lines. `plain` (Paste and Match Style) always
    /// takes the plain text.
    pub fn paste(&mut self, plain: bool, cx: &mut Context<Self>) {
        if self.read_only {
            return;
        }
        let Some(item) = cx.read_from_clipboard() else {
            return;
        };
        let rich = if plain {
            None
        } else {
            item.entries().iter().find_map(rich_fragment)
        };
        match rich {
            Some(blocks) if !blocks.is_empty() => {
                self.checkpoint(EditKind::Other);
                let at = self.delete_selection_raw();
                let caret = self.doc.insert_fragment(at, &blocks);
                self.selection = Selection::caret(caret);
                self.edited(cx);
            }
            _ => {
                if let Some(text) = item.text() {
                    let pending = self.typing_marks.take();
                    self.checkpoint(EditKind::Other);
                    let at = self.delete_selection_raw();
                    let marks = pending.unwrap_or_else(|| {
                        let mut m = self.doc.blocks[at.block].marks_at(at.offset);
                        m.link = None;
                        m
                    });
                    let caret = self.doc.insert(at, &text, &marks);
                    self.selection = Selection::caret(caret);
                    self.edited(cx);
                }
            }
        }
    }

    // ── Selection and movement ──────────────────────────────────────────

    /// Moves the caret to `pos` (with `extend`, the selection's end).
    pub fn select_to(&mut self, pos: Pos, extend: bool, cx: &mut Context<Self>) {
        let pos = self.doc.clamp(pos);
        let forward = pos >= self.selection.head;
        let pos = self.skip_cards(pos, forward);
        self.selection = if extend {
            Selection {
                anchor: self.selection.anchor,
                head: pos,
            }
        } else {
            Selection::caret(pos)
        };
        self.after_move(cx);
    }

    pub fn select_range(&mut self, anchor: Pos, head: Pos, cx: &mut Context<Self>) {
        self.selection = Selection {
            anchor: self.doc.clamp(anchor),
            head: self.doc.clamp(head),
        };
        self.after_move(cx);
    }

    pub fn select_all(&mut self, cx: &mut Context<Self>) {
        self.selection = Selection {
            anchor: Pos::default(),
            head: self.doc.end(),
        };
        self.after_move(cx);
    }

    fn after_move(&mut self, cx: &mut Context<Self>) {
        self.typing_marks = None;
        self.history.last = None;
        self.marked = None;
        self.reveal = true;
        self.wake_caret(cx);
        cx.emit(EditorEvent::Selected);
        cx.notify();
    }

    fn horizontal(&mut self, forward: bool, word: bool, extend: bool, cx: &mut Context<Self>) {
        let s = self.selection;
        self.goal_x = None;
        if !s.is_empty() && !extend {
            let to = if forward { s.end() } else { s.start() };
            self.select_to(to, false, cx);
            return;
        }
        let to = match (forward, word) {
            (true, false) => self.doc.next_char(s.head),
            (false, false) => self.doc.prev_char(s.head),
            (true, true) => self.doc.next_word(s.head),
            (false, true) => self.doc.prev_word(s.head),
        };
        self.select_to(to, extend, cx);
    }

    /// ↑ or ↓ by visual lines `lines` (negative up), keeping to the goal x.
    fn vertical(&mut self, lines: f32, extend: bool, cx: &mut Context<Self>) {
        let s = self.selection;
        if !s.is_empty() && !extend {
            let to = if lines > 0. { s.end() } else { s.start() };
            self.select_to(to, false, cx);
            return;
        }
        let Some((caret, height)) = self.caret_point(s.head) else {
            return;
        };
        let x = *self.goal_x.get_or_insert(caret.x);
        let target = point(x, caret.y + height * (0.5 + lines));
        let to = match self.hit(target, lines > 0.) {
            // Nothing above the first line or below the last: the
            // document's edge, as in any Mac text view.
            Some(pos) if pos.block == s.head.block && self.same_line(pos, s.head) => {
                if lines > 0. {
                    self.doc.end()
                } else {
                    Pos::default()
                }
            }
            Some(pos) => pos,
            None if lines > 0. => self.doc.end(),
            None => Pos::default(),
        };
        let goal = self.goal_x;
        self.select_to(to, extend, cx);
        self.goal_x = goal;
    }

    /// Whether two positions' carets are on one visual line.
    fn same_line(&self, a: Pos, b: Pos) -> bool {
        match (self.caret_point(a), self.caret_point(b)) {
            (Some((pa, _)), Some((pb, _))) => (f32::from(pa.y) - f32::from(pb.y)).abs() < 1.,
            _ => false,
        }
    }

    /// The start or end of the visual line the caret is on (⌘← and ⌘→).
    fn line_edge(&mut self, end: bool, extend: bool, cx: &mut Context<Self>) {
        let head = self.selection.head;
        let id = self.doc.blocks[head.block].id;
        let caret = self.caret_point(head);
        let to = {
            let layout = self.layout.borrow();
            match (layout.leaves.get(&id), caret) {
                (Some(leaf), Some((caret, height))) => {
                    let bounds = leaf.bounds();
                    let x = if end {
                        bounds.right() + px(10_000.)
                    } else {
                        bounds.left() - px(10_000.)
                    };
                    Pos::new(
                        head.block,
                        leaf.index_for_position(point(x, caret.y + height / 2.)),
                    )
                }
                _ => Pos::new(
                    head.block,
                    if end {
                        self.doc.blocks[head.block].text.len()
                    } else {
                        0
                    },
                ),
            }
        };
        self.goal_x = None;
        self.select_to(to, extend, cx);
    }

    fn doc_edge(&mut self, end: bool, extend: bool, cx: &mut Context<Self>) {
        let to = if end { self.doc.end() } else { Pos::default() };
        self.goal_x = None;
        self.select_to(to, extend, cx);
    }

    /// Where `pos`'s caret is drawn (its top, in window coordinates), and
    /// its line height.
    pub fn caret_point(&self, pos: Pos) -> Option<(Point<Pixels>, Pixels)> {
        let block = self.doc.blocks.get(pos.block)?;
        let layout = self.layout.borrow();
        let leaf = layout.leaves.get(&block.id)?;
        Some((leaf.position_for_index(pos.offset), leaf.line_height()))
    }

    /// The position nearest `at` (window coordinates): in the text block
    /// whose lines hold it, else the nearest one (below first, going
    /// `down`).
    pub fn hit(&self, at: Point<Pixels>, down: bool) -> Option<Pos> {
        let layout = self.layout.borrow();
        let mut best: Option<(f32, usize)> = None;
        for (i, block) in self.doc.blocks.iter().enumerate() {
            if block.file_link().is_some() {
                continue;
            }
            let Some(leaf) = layout.leaves.get(&block.id) else {
                continue;
            };
            let b = leaf.bounds();
            let above = at.y < b.top();
            let dy = if above {
                f32::from(b.top() - at.y)
            } else if at.y > b.bottom() {
                f32::from(at.y - b.bottom())
            } else {
                0.
            };
            // A point in the gap between two blocks goes the way the caret
            // moves.
            let bias = if dy > 0. && (down != above) { 0.5 } else { 0. };
            let score = dy + bias;
            if best.is_none_or(|(s, _)| score < s) {
                best = Some((score, i));
            }
        }
        let (_, i) = best?;
        let leaf = layout.leaves.get(&self.doc.blocks[i].id)?;
        Some(Pos::new(i, leaf.index_for_position(at)))
    }

    /// A mouse press at `at`: the caret there (⇧ extends), a double click
    /// selects a word, a triple click the block, ⌘ opens a link. A click
    /// in a checklist item's box checks it.
    pub fn mouse_down(
        &mut self,
        at: Point<Pixels>,
        clicks: usize,
        shift: bool,
        cmd: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        window.focus(&self.focus, cx);
        if let Some(block) = self.checkbox_at(at) {
            self.toggle_checked_in(block..block + 1, cx);
            return;
        }
        let Some(pos) = self.hit(at, true) else {
            return;
        };
        if cmd && let Some((_, url)) = self.doc.link_at(pos) {
            cx.emit(EditorEvent::OpenLink(url));
            return;
        }
        match clicks {
            2 => {
                let (a, b) = self.doc.word_at(pos);
                self.drag = Some(DragUnit::Word);
                self.select_range(a, b, cx);
            }
            n if n >= 3 => {
                let len = self.doc.blocks[pos.block].text.len();
                self.drag = Some(DragUnit::Block);
                self.select_range(Pos::new(pos.block, 0), Pos::new(pos.block, len), cx);
            }
            _ => {
                self.drag = Some(DragUnit::Char);
                self.goal_x = None;
                self.select_to(pos, shift, cx);
            }
        }
    }

    pub fn mouse_drag(&mut self, at: Point<Pixels>, cx: &mut Context<Self>) {
        let Some(unit) = self.drag else {
            return;
        };
        let Some(pos) = self.hit(at, true) else {
            return;
        };
        let anchor = self.selection.anchor;
        let head = match unit {
            DragUnit::Char => pos,
            DragUnit::Word => {
                let (a, b) = self.doc.word_at(pos);
                if pos < anchor { a } else { b }
            }
            DragUnit::Block => {
                if pos < anchor {
                    Pos::new(pos.block, 0)
                } else {
                    Pos::new(pos.block, self.doc.blocks[pos.block].text.len())
                }
            }
        };
        if head != self.selection.head {
            self.selection.head = head;
            self.reveal = true;
            cx.emit(EditorEvent::Selected);
            cx.notify();
        }
    }

    pub fn mouse_up(&mut self) {
        self.drag = None;
    }

    /// The checklist item whose box is at `at`.
    fn checkbox_at(&self, at: Point<Pixels>) -> Option<usize> {
        let layout = self.layout.borrow();
        self.doc.blocks.iter().enumerate().find_map(|(i, block)| {
            if !matches!(block.kind, BlockKind::Check(_)) {
                return None;
            }
            let leaf = layout.leaves.get(&block.id)?;
            let b = leaf.bounds();
            let line = leaf.line_height();
            (at.x < b.left()
                && at.x > b.left() - px(28.)
                && at.y >= b.top()
                && at.y <= b.top() + line)
                .then_some(i)
        })
    }

    // ── Find ────────────────────────────────────────────────────────────

    /// Searches the note for `query` (ignoring case), the current match
    /// the first at or after the caret.
    pub fn find(&mut self, query: &str, cx: &mut Context<Self>) {
        self.find.query = query.to_string();
        self.refind();
        let caret = self.selection.start();
        self.find.current = self
            .find
            .matches
            .iter()
            .position(|(a, _)| *a >= caret)
            .unwrap_or(0);
        self.show_match(cx);
    }

    fn refind(&mut self) {
        let query = self.find.query.to_lowercase();
        self.find.matches.clear();
        if query.is_empty() {
            return;
        }
        for (i, block) in self.doc.blocks.iter().enumerate() {
            let lower = block.text.to_lowercase();
            // Lowercasing can change byte lengths; only text whose offsets
            // line up with the original is searched (nearly all).
            if lower.len() != block.text.len() {
                continue;
            }
            let mut from = 0;
            while let Some(found) = lower[from..].find(&query) {
                let start = from + found;
                let end = start + query.len();
                self.find
                    .matches
                    .push((Pos::new(i, start), Pos::new(i, end)));
                from = end;
            }
        }
        if self.find.current >= self.find.matches.len() {
            self.find.current = 0;
        }
    }

    /// Find Next (⌘G) and Find Previous (⇧⌘G).
    pub fn find_step(&mut self, forward: bool, cx: &mut Context<Self>) {
        let n = self.find.matches.len();
        if n == 0 {
            return;
        }
        self.find.current = if forward {
            (self.find.current + 1) % n
        } else {
            (self.find.current + n - 1) % n
        };
        self.show_match(cx);
    }

    fn show_match(&mut self, cx: &mut Context<Self>) {
        if let Some((a, b)) = self.find.matches.get(self.find.current).copied() {
            self.selection = Selection { anchor: a, head: b };
            self.reveal = true;
        }
        cx.emit(EditorEvent::Selected);
        cx.notify();
    }

    pub fn end_find(&mut self, cx: &mut Context<Self>) {
        self.find = Find::default();
        cx.notify();
    }

    // ── Flat text and UTF-16, for IME ───────────────────────────────────

    fn utf16_to_pos(&self, utf16: usize) -> Pos {
        let text = self.doc.plain_text();
        let mut count = 0;
        for (i, c) in text.char_indices() {
            if count >= utf16 {
                return self.doc.unflat(i);
            }
            count += c.len_utf16();
        }
        self.doc.end()
    }

    fn pos_to_utf16(&self, pos: Pos) -> usize {
        let text = self.doc.plain_text();
        let flat = self.doc.flat(pos);
        text[..flat.min(text.len())].encode_utf16().count()
    }

    fn range_from_utf16(&self, range: &Range<usize>) -> (Pos, Pos) {
        (self.utf16_to_pos(range.start), self.utf16_to_pos(range.end))
    }

    /// ⌘K: the pane asks for the address.
    pub fn request_link(&mut self, cx: &mut Context<Self>) {
        if self.read_only {
            return;
        }
        let current = self.doc.link_at(self.selection.start()).map(|(_, u)| u);
        cx.emit(EditorEvent::LinkRequested { current });
    }

    /// Page Up and Page Down: the caret a screen up or down.
    fn page(&mut self, down: bool, cx: &mut Context<Self>) {
        let visible = f32::from(self.scroll.bounds().size.height).max(100.);
        let line = self
            .caret_point(self.selection.head)
            .map_or(20., |(_, h)| f32::from(h));
        let lines = ((visible / line).floor() - 1.).max(1.);
        self.vertical(if down { lines } else { -lines }, false, cx);
    }

    /// The editor lost focus.
    pub(super) fn blurred(&mut self, cx: &mut Context<Self>) {
        self.sleep_caret();
        self.drag = None;
        cx.emit(EditorEvent::Blurred);
        cx.notify();
    }

    pub(super) fn focused(&mut self, cx: &mut Context<Self>) {
        self.wake_caret(cx);
        cx.notify();
    }

    // ── Actions ─────────────────────────────────────────────────────────

    pub(super) fn on_actions(
        &mut self,
        action: &dyn gpui_kit::Action,
        cx: &mut Context<Self>,
    ) -> bool {
        let a = action.as_any();
        macro_rules! is {
            ($t:ty) => {
                a.is::<$t>()
            };
        }
        if is!(MoveLeft) {
            self.horizontal(false, false, false, cx)
        } else if is!(MoveRight) {
            self.horizontal(true, false, false, cx)
        } else if is!(MoveWordLeft) {
            self.horizontal(false, true, false, cx)
        } else if is!(MoveWordRight) {
            self.horizontal(true, true, false, cx)
        } else if is!(SelectLeft) {
            self.horizontal(false, false, true, cx)
        } else if is!(SelectRight) {
            self.horizontal(true, false, true, cx)
        } else if is!(SelectWordLeft) {
            self.horizontal(false, true, true, cx)
        } else if is!(SelectWordRight) {
            self.horizontal(true, true, true, cx)
        } else if is!(MoveUp) {
            self.vertical(-1., false, cx)
        } else if is!(MoveDown) {
            self.vertical(1., false, cx)
        } else if is!(SelectUp) {
            self.vertical(-1., true, cx)
        } else if is!(SelectDown) {
            self.vertical(1., true, cx)
        } else if is!(PageUp) {
            self.page(false, cx)
        } else if is!(PageDown) {
            self.page(true, cx)
        } else if is!(MoveLineStart) {
            self.line_edge(false, false, cx)
        } else if is!(MoveLineEnd) {
            self.line_edge(true, false, cx)
        } else if is!(SelectLineStart) {
            self.line_edge(false, true, cx)
        } else if is!(SelectLineEnd) {
            self.line_edge(true, true, cx)
        } else if is!(MoveDocStart) {
            self.doc_edge(false, false, cx)
        } else if is!(MoveDocEnd) {
            self.doc_edge(true, false, cx)
        } else if is!(SelectDocStart) {
            self.doc_edge(false, true, cx)
        } else if is!(SelectDocEnd) {
            self.doc_edge(true, true, cx)
        } else if is!(SelectAll) {
            self.select_all(cx)
        } else if is!(Backspace) {
            self.backspace(cx)
        } else if is!(Delete) {
            self.delete_forward(cx)
        } else if is!(DeleteWordLeft) {
            let to = self.doc.prev_word(self.selection.head);
            self.delete_to(to, cx)
        } else if is!(DeleteWordRight) {
            let to = self.doc.next_word(self.selection.head);
            self.delete_to(to, cx)
        } else if is!(DeleteLineLeft) {
            let to = Pos::new(self.selection.head.block, 0);
            self.delete_to(to, cx)
        } else if is!(Newline) {
            self.newline(cx)
        } else if is!(Indent) {
            self.indent(false, cx)
        } else if is!(Outdent) {
            self.indent(true, cx)
        } else if is!(Copy) {
            self.copy(cx)
        } else if is!(Cut) {
            self.cut(cx)
        } else if is!(Paste) {
            self.paste(false, cx)
        } else if is!(PastePlain) {
            self.paste(true, cx)
        } else if is!(Undo) {
            self.undo(cx)
        } else if is!(Redo) {
            self.redo(cx)
        } else if is!(ToggleBold) {
            self.toggle_mark(Mark::Bold, cx)
        } else if is!(ToggleItalic) {
            self.toggle_mark(Mark::Italic, cx)
        } else if is!(ToggleStrike) {
            self.toggle_mark(Mark::Strike, cx)
        } else if is!(ToggleCode) {
            self.toggle_mark(Mark::Code, cx)
        } else if is!(AddLink) {
            self.request_link(cx)
        } else if is!(Title) {
            self.toggle_kind(BlockKind::Heading(1), cx)
        } else if is!(Heading) {
            self.toggle_kind(BlockKind::Heading(2), cx)
        } else if is!(Subheading) {
            self.toggle_kind(BlockKind::Heading(3), cx)
        } else if is!(Body) {
            self.toggle_kind(BlockKind::Paragraph, cx)
        } else if is!(BulletList) {
            self.toggle_kind(BlockKind::Bullet, cx)
        } else if is!(NumberedList) {
            self.toggle_kind(BlockKind::Ordered, cx)
        } else if is!(Checklist) {
            self.toggle_kind(BlockKind::Check(false), cx)
        } else if is!(ToggleChecked) {
            self.toggle_checked(cx)
        } else if is!(QuoteBlock) {
            self.toggle_kind(BlockKind::Quote, cx)
        } else if is!(CodeBlock) {
            self.toggle_kind(BlockKind::Code, cx)
        } else {
            return false;
        }
        true
    }
}

/// Adds `html` to what the general pasteboard holds (after GPUI wrote its
/// plain text and metadata).
#[cfg(target_os = "macos")]
fn add_html_to_pasteboard(html: &str) {
    use objc2_app_kit::{NSPasteboard, NSPasteboardTypeHTML};
    use objc2_foundation::{NSArray, NSString};
    let pasteboard = NSPasteboard::generalPasteboard();
    // SAFETY: the pasteboard's types are strings, and no owner is given.
    unsafe {
        let html_type = NSPasteboardTypeHTML;
        pasteboard.addTypes_owner(&NSArray::from_slice(&[html_type]), None);
        pasteboard.setString_forType(&NSString::from_str(html), html_type);
    }
}

#[cfg(not(target_os = "macos"))]
fn add_html_to_pasteboard(_: &str) {}

/// The clipboard metadata key a note's own copy carries its ops under.
const CLIPBOARD_KEY: &str = "conduitNoteOps";

fn rich_fragment(entry: &gpui_kit::ClipboardEntry) -> Option<Vec<Block>> {
    let gpui_kit::ClipboardEntry::String(s) = entry else {
        return None;
    };
    let value: Value = s.metadata_json()?;
    let ops = value.get(CLIPBOARD_KEY)?.as_array()?;
    Some(blocks_from_ops(ops))
}

impl EntityInputHandler for NoteEditor {
    fn text_for_range(
        &mut self,
        range: Range<usize>,
        adjusted: &mut Option<Range<usize>>,
        _: &mut Window,
        _: &mut Context<Self>,
    ) -> Option<String> {
        let (a, b) = self.range_from_utf16(&range);
        *adjusted = Some(self.pos_to_utf16(a)..self.pos_to_utf16(b));
        Some(self.doc.text_in(a, b))
    }

    fn selected_text_range(
        &mut self,
        _: bool,
        _: &mut Window,
        _: &mut Context<Self>,
    ) -> Option<UTF16Selection> {
        let s = self.selection;
        let start = self.pos_to_utf16(s.start());
        let end = self.pos_to_utf16(s.end());
        Some(UTF16Selection {
            range: start..end,
            reversed: s.head < s.anchor,
        })
    }

    fn marked_text_range(&self, _: &mut Window, _: &mut Context<Self>) -> Option<Range<usize>> {
        let (a, b) = self.marked?;
        Some(self.pos_to_utf16(a)..self.pos_to_utf16(b))
    }

    fn unmark_text(&mut self, _: &mut Window, cx: &mut Context<Self>) {
        self.marked = None;
        cx.notify();
    }

    fn replace_text_in_range(
        &mut self,
        range: Option<Range<usize>>,
        text: &str,
        _: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.read_only {
            return;
        }
        if let Some((a, b)) = self.marked.take() {
            self.selection = Selection { anchor: a, head: b };
        } else if let Some(range) = range {
            let (a, b) = self.range_from_utf16(&range);
            self.selection = Selection { anchor: a, head: b };
        }
        self.insert_text(text, cx);
    }

    fn replace_and_mark_text_in_range(
        &mut self,
        range: Option<Range<usize>>,
        text: &str,
        selected: Option<Range<usize>>,
        _: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.read_only {
            return;
        }
        if let Some((a, b)) = self.marked.take() {
            self.selection = Selection { anchor: a, head: b };
        } else if let Some(range) = range {
            let (a, b) = self.range_from_utf16(&range);
            self.selection = Selection { anchor: a, head: b };
        }
        // Composition is one undo step with what it commits.
        self.checkpoint(EditKind::Typing);
        let start = self.delete_selection_raw();
        let marks = self.typing_marks_at(start);
        let end = self.doc.insert(start, text, &marks);
        self.selection = match selected {
            Some(sel) => {
                let base = self.pos_to_utf16(start);
                Selection {
                    anchor: self.utf16_to_pos(base + sel.start),
                    head: self.utf16_to_pos(base + sel.end),
                }
            }
            None => Selection::caret(end),
        };
        self.edited(cx);
        self.marked = (!text.is_empty()).then_some((start, end));
    }

    fn bounds_for_range(
        &mut self,
        range: Range<usize>,
        _: Bounds<Pixels>,
        _: &mut Window,
        _: &mut Context<Self>,
    ) -> Option<Bounds<Pixels>> {
        let (a, _) = self.range_from_utf16(&range);
        let (top, height) = self.caret_point(a)?;
        Some(Bounds::new(top, gpui_kit::size(px(2.), height)))
    }

    fn character_index_for_point(
        &mut self,
        at: Point<Pixels>,
        _: &mut Window,
        _: &mut Context<Self>,
    ) -> Option<usize> {
        let pos = self.hit(at, true)?;
        Some(self.pos_to_utf16(pos))
    }

    fn accepts_text_input(&self, _: &mut Window, _: &mut Context<Self>) -> bool {
        !self.read_only
    }
}
