//! A note's document, as the editor edits it: a list of blocks (a
//! paragraph, a heading, a list item, a quote line, a code block), each
//! with its text and the inline marks over it.
//!
//! **Markdown is canonical.** The daemon converts a note's stored markdown
//! to Quill ops and back with the core's Parchment codec, the one mobile's
//! editor uses, so this module only maps Quill ops onto blocks
//! ([`Doc::from_ops`]) and blocks back onto ops ([`Doc::to_ops`]). Only
//! what markdown can hold is modelled: bold, italic, strikethrough, inline
//! code and links inline; headings, bulleted, numbered and checklist items
//! (with their indent), quotes and code blocks per line. Underline is kept
//! when a note has it (Parchment writes it), but the editor does not offer
//! it, since markdown has no underline of its own.
//!
//! **Positions** are a block index and a byte offset into its text. The
//! flat text, which IME and VoiceOver see, is the blocks' texts joined by
//! `\n`; a code block's own lines are `\n`-separated inside it.

use std::ops::Range;

use serde_json::{Map, Value, json};
use unicode_segmentation::UnicodeSegmentation as _;

/// Inline formatting.
#[derive(Clone, Debug, Default, PartialEq, Eq, Hash)]
pub struct Marks {
    pub bold: bool,
    pub italic: bool,
    pub underline: bool,
    pub strike: bool,
    pub code: bool,
    pub link: Option<String>,
}

impl Marks {
    pub fn is_plain(&self) -> bool {
        *self == Self::default()
    }

    /// Whether `mark` is set.
    pub fn has(&self, mark: Mark) -> bool {
        match mark {
            Mark::Bold => self.bold,
            Mark::Italic => self.italic,
            Mark::Underline => self.underline,
            Mark::Strike => self.strike,
            Mark::Code => self.code,
        }
    }

    pub fn set(&mut self, mark: Mark, on: bool) {
        match mark {
            Mark::Bold => self.bold = on,
            Mark::Italic => self.italic = on,
            Mark::Underline => self.underline = on,
            Mark::Strike => self.strike = on,
            Mark::Code => self.code = on,
        }
    }
}

/// A mark the toolbar and the shortcuts toggle.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Mark {
    Bold,
    Italic,
    Underline,
    Strike,
    Code,
}

/// A run of a block's text with one set of marks, `len` bytes long.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Run {
    pub len: usize,
    pub marks: Marks,
}

/// What a block is.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum BlockKind {
    Paragraph,
    /// Levels 1 to 6.
    Heading(u8),
    Bullet,
    Ordered,
    /// A checklist item, checked or not.
    Check(bool),
    Quote,
    /// A code block: its text holds its lines, `\n`-separated.
    Code,
}

impl BlockKind {
    pub fn is_list(self) -> bool {
        matches!(self, Self::Bullet | Self::Ordered | Self::Check(_))
    }

    /// The same kind of block, as a toolbar compares them (a checked and
    /// an unchecked item are both checklist items).
    pub fn same_style(self, other: BlockKind) -> bool {
        match (self, other) {
            (Self::Check(_), Self::Check(_)) => true,
            (a, b) => a == b,
        }
    }
}

/// A file a paragraph links as an attachment: the paragraph holds only a
/// link to `/api/v1/files/{id}/content`, as Open WebUI 0.12.5 attaches
/// files; the editor draws it as a card.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct FileLink {
    pub id: String,
    pub name: String,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Block {
    /// Stable across edits: the block's element and leaf identity.
    pub id: u64,
    pub kind: BlockKind,
    /// A list item's nesting (0 at the top level).
    pub indent: u8,
    pub text: String,
    /// Cover `text` exactly; neighbours never share marks; none is empty.
    pub runs: Vec<Run>,
}

impl Block {
    pub fn new(id: u64, kind: BlockKind, text: &str) -> Self {
        let mut block = Self {
            id,
            kind,
            indent: 0,
            text: text.to_string(),
            runs: vec![],
        };
        if !text.is_empty() {
            block.runs.push(Run {
                len: text.len(),
                marks: Marks::default(),
            });
        }
        block
    }

    /// The marks at each byte range, in order.
    pub fn spans(&self) -> Vec<(Range<usize>, &Marks)> {
        let mut at = 0;
        self.runs
            .iter()
            .map(|r| {
                let range = at..at + r.len;
                at += r.len;
                (range, &r.marks)
            })
            .collect()
    }

    /// The marks of the character ending at `offset` (what typing there
    /// continues), else of the one starting there.
    pub fn marks_at(&self, offset: usize) -> Marks {
        let mut at = 0;
        let mut found: Option<&Marks> = None;
        for run in &self.runs {
            let end = at + run.len;
            if offset > at && offset <= end {
                return run.marks.clone();
            }
            if offset == at && found.is_none() {
                found = Some(&run.marks);
            }
            at = end;
        }
        found.cloned().unwrap_or_default()
    }

    /// The file this paragraph attaches, when it is nothing but a link to
    /// a server file.
    pub fn file_link(&self) -> Option<FileLink> {
        if self.kind != BlockKind::Paragraph || self.runs.len() != 1 {
            return None;
        }
        let url = self.runs[0].marks.link.as_deref()?;
        let id = url
            .strip_prefix("/api/v1/files/")?
            .strip_suffix("/content")?;
        let valid = !id.is_empty()
            && id
                .chars()
                .all(|c| c.is_alphanumeric() || c == '_' || c == '-');
        let name = self.text.trim();
        valid.then(|| FileLink {
            id: id.to_string(),
            name: if name.is_empty() {
                id.to_string()
            } else {
                name.to_string()
            },
        })
    }

    fn normalize(&mut self) {
        let mut out: Vec<Run> = Vec::with_capacity(self.runs.len());
        for run in self.runs.drain(..) {
            if run.len == 0 {
                continue;
            }
            match out.last_mut() {
                Some(last) if last.marks == run.marks => last.len += run.len,
                _ => out.push(run),
            }
        }
        self.runs = out;
        if self.kind == BlockKind::Code {
            // Code is code: no marks inside a code block.
            let len = self.text.len();
            self.runs = if len == 0 {
                vec![]
            } else {
                vec![Run {
                    len,
                    marks: Marks::default(),
                }]
            };
        }
        debug_assert_eq!(
            self.runs.iter().map(|r| r.len).sum::<usize>(),
            self.text.len()
        );
    }

    /// Inserts `text` (no line breaks, except in a code block) at `offset`
    /// with `marks`.
    fn insert(&mut self, offset: usize, text: &str, marks: &Marks) {
        if text.is_empty() {
            return;
        }
        self.text.insert_str(offset, text);
        let mut out = Vec::with_capacity(self.runs.len() + 2);
        let mut at = 0;
        let mut placed = false;
        for run in self.runs.drain(..) {
            let end = at + run.len;
            if !placed && offset <= end {
                let before = offset - at;
                if before > 0 {
                    out.push(Run {
                        len: before,
                        marks: run.marks.clone(),
                    });
                }
                out.push(Run {
                    len: text.len(),
                    marks: marks.clone(),
                });
                if run.len - before > 0 {
                    out.push(Run {
                        len: run.len - before,
                        marks: run.marks,
                    });
                }
                placed = true;
            } else {
                out.push(run);
            }
            at = end;
        }
        if !placed {
            out.push(Run {
                len: text.len(),
                marks: marks.clone(),
            });
        }
        self.runs = out;
        self.normalize();
    }

    /// Removes bytes `range`.
    fn remove(&mut self, range: Range<usize>) {
        if range.is_empty() {
            return;
        }
        self.text.replace_range(range.clone(), "");
        let mut at = 0;
        for run in &mut self.runs {
            let start = at;
            let end = at + run.len;
            let cut_start = range.start.max(start);
            let cut_end = range.end.min(end);
            if cut_start < cut_end {
                run.len -= cut_end - cut_start;
            }
            at = end;
        }
        self.normalize();
    }

    /// The part `range` of this block, as a block of its own (the same
    /// kind and indent).
    fn slice(&self, range: Range<usize>, id: u64) -> Block {
        let mut out = Block {
            id,
            kind: self.kind,
            indent: self.indent,
            text: self.text[range.clone()].to_string(),
            runs: vec![],
        };
        for (span, marks) in self.spans() {
            let start = span.start.max(range.start);
            let end = span.end.min(range.end);
            if start < end {
                out.runs.push(Run {
                    len: end - start,
                    marks: marks.clone(),
                });
            }
        }
        out.normalize();
        out
    }

    /// Appends `other`'s text and marks.
    fn append(&mut self, other: &Block) {
        let code = self.kind == BlockKind::Code;
        self.text.push_str(&other.text);
        if code {
            self.normalize();
            return;
        }
        self.runs.extend(other.runs.iter().cloned());
        self.normalize();
    }

    /// Changes `mark` over `range`, or sets the link.
    fn apply(&mut self, range: Range<usize>, change: &dyn Fn(&mut Marks)) {
        if range.is_empty() || self.kind == BlockKind::Code {
            return;
        }
        let mut out = Vec::with_capacity(self.runs.len() + 2);
        let mut at = 0;
        for run in self.runs.drain(..) {
            let start = at;
            let end = at + run.len;
            at = end;
            let cut_start = range.start.max(start);
            let cut_end = range.end.min(end);
            if cut_start >= cut_end {
                out.push(run);
                continue;
            }
            if cut_start > start {
                out.push(Run {
                    len: cut_start - start,
                    marks: run.marks.clone(),
                });
            }
            let mut marks = run.marks.clone();
            change(&mut marks);
            out.push(Run {
                len: cut_end - cut_start,
                marks,
            });
            if end > cut_end {
                out.push(Run {
                    len: end - cut_end,
                    marks: run.marks,
                });
            }
        }
        self.runs = out;
        self.normalize();
    }
}

/// A place in the document.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct Pos {
    pub block: usize,
    pub offset: usize,
}

impl Pos {
    pub fn new(block: usize, offset: usize) -> Self {
        Self { block, offset }
    }
}

/// A selection: where it started and where it ends now (the caret).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Selection {
    pub anchor: Pos,
    pub head: Pos,
}

impl Selection {
    pub fn caret(pos: Pos) -> Self {
        Self {
            anchor: pos,
            head: pos,
        }
    }

    pub fn is_empty(&self) -> bool {
        self.anchor == self.head
    }

    pub fn start(&self) -> Pos {
        self.anchor.min(self.head)
    }

    pub fn end(&self) -> Pos {
        self.anchor.max(self.head)
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Doc {
    pub blocks: Vec<Block>,
    next_id: u64,
}

impl Default for Doc {
    fn default() -> Self {
        Self {
            blocks: vec![Block::new(1, BlockKind::Paragraph, "")],
            next_id: 2,
        }
    }
}

impl Doc {
    pub fn new_id(&mut self) -> u64 {
        let id = self.next_id;
        self.next_id += 1;
        id
    }

    /// A document of `blocks` (ids are given afresh).
    pub fn from_blocks(blocks: Vec<Block>) -> Self {
        let mut doc = Self {
            blocks: vec![],
            next_id: 1,
        };
        for mut block in blocks {
            block.id = doc.new_id();
            block.normalize();
            doc.blocks.push(block);
        }
        if doc.blocks.is_empty() {
            let id = doc.new_id();
            doc.blocks.push(Block::new(id, BlockKind::Paragraph, ""));
        }
        doc
    }

    pub fn is_empty(&self) -> bool {
        self.blocks.len() == 1 && self.blocks[0].text.is_empty()
    }

    pub fn end(&self) -> Pos {
        let last = self.blocks.len() - 1;
        Pos::new(last, self.blocks[last].text.len())
    }

    /// `pos` moved onto the document (an index past the end, an offset
    /// past its block, or inside a character).
    pub fn clamp(&self, pos: Pos) -> Pos {
        let block = pos.block.min(self.blocks.len() - 1);
        let text = &self.blocks[block].text;
        let mut offset = pos.offset.min(text.len());
        while !text.is_char_boundary(offset) {
            offset -= 1;
        }
        Pos::new(block, offset)
    }

    // ── The flat text ───────────────────────────────────────────────────

    /// The blocks' texts joined by line breaks: what IME, VoiceOver and
    /// Find see.
    pub fn plain_text(&self) -> String {
        let mut out = String::new();
        for (i, block) in self.blocks.iter().enumerate() {
            if i > 0 {
                out.push('\n');
            }
            out.push_str(&block.text);
        }
        out
    }

    /// `pos` in the flat text, in bytes.
    pub fn flat(&self, pos: Pos) -> usize {
        let pos = self.clamp(pos);
        self.blocks[..pos.block]
            .iter()
            .map(|b| b.text.len() + 1)
            .sum::<usize>()
            + pos.offset
    }

    /// The position at flat byte `index`.
    pub fn unflat(&self, index: usize) -> Pos {
        let mut start = 0;
        for (i, block) in self.blocks.iter().enumerate() {
            let end = start + block.text.len();
            if index <= end {
                return self.clamp(Pos::new(i, index - start));
            }
            start = end + 1;
        }
        self.end()
    }

    /// The text between two positions, line breaks between blocks.
    pub fn text_in(&self, start: Pos, end: Pos) -> String {
        let (start, end) = (start.min(end), start.max(end));
        let flat = self.plain_text();
        flat[self.flat(start)..self.flat(end)].to_string()
    }

    /// Word and character counts, as the phone counts them (file cards
    /// are not words).
    pub fn counts(&self) -> (usize, usize) {
        let text: String = self
            .blocks
            .iter()
            .filter(|b| b.file_link().is_none())
            .map(|b| b.text.as_str())
            .collect::<Vec<_>>()
            .join("\n");
        let trimmed = text.trim();
        let words = if trimmed.is_empty() {
            0
        } else {
            trimmed.split_whitespace().count()
        };
        (words, trimmed.chars().count())
    }

    // ── Edits ───────────────────────────────────────────────────────────

    /// Deletes between two positions; returns where the caret goes.
    pub fn delete(&mut self, a: Pos, b: Pos) -> Pos {
        let (start, end) = (self.clamp(a.min(b)), self.clamp(a.max(b)));
        if start == end {
            return start;
        }
        if start.block == end.block {
            self.blocks[start.block].remove(start.offset..end.offset);
            return start;
        }
        let tail = {
            let last = &self.blocks[end.block];
            last.slice(end.offset..last.text.len(), last.id)
        };
        let first = &mut self.blocks[start.block];
        let len = first.text.len();
        first.remove(start.offset..len);
        first.append(&tail);
        self.blocks.drain(start.block + 1..=end.block);
        start
    }

    /// Inserts `text` at `pos` with `marks`; line breaks start new blocks
    /// (inside a code block they stay its lines). Returns the caret after.
    pub fn insert(&mut self, pos: Pos, text: &str, marks: &Marks) -> Pos {
        let mut pos = self.clamp(pos);
        let text = text.replace("\r\n", "\n").replace('\r', "\n");
        if self.blocks[pos.block].kind == BlockKind::Code {
            self.blocks[pos.block].insert(pos.offset, &text, &Marks::default());
            return Pos::new(pos.block, pos.offset + text.len());
        }
        let mut lines = text.split('\n').peekable();
        while let Some(line) = lines.next() {
            self.blocks[pos.block].insert(pos.offset, line, marks);
            pos.offset += line.len();
            if lines.peek().is_some() {
                pos = self.split(pos);
            }
        }
        pos
    }

    /// Splits the block at `pos` (Return): the part after the caret is a
    /// new block below, of the same kind (a heading's next line is a
    /// paragraph; a checked item's next one is unchecked). Returns the
    /// start of the new block.
    pub fn split(&mut self, pos: Pos) -> Pos {
        let pos = self.clamp(pos);
        let id = self.new_id();
        let block = &mut self.blocks[pos.block];
        let len = block.text.len();
        let mut tail = block.slice(pos.offset..len, id);
        block.remove(pos.offset..len);
        tail.kind = match block.kind {
            BlockKind::Heading(_) if pos.offset < len && pos.offset == 0 => block.kind,
            BlockKind::Heading(_) => BlockKind::Paragraph,
            BlockKind::Check(_) => BlockKind::Check(false),
            kind => kind,
        };
        if pos.offset == 0 && len > 0 {
            // Return at the start of a heading leaves an empty paragraph
            // above it, not an empty heading.
            if matches!(block.kind, BlockKind::Heading(_)) {
                block.kind = BlockKind::Paragraph;
            }
        }
        self.blocks.insert(pos.block + 1, tail);
        Pos::new(pos.block + 1, 0)
    }

    /// Sets the kind of blocks `range`; a list kind keeps their indent,
    /// another clears it. Lines of a code block become blocks of their own
    /// when it turns into something else, and blocks turned into code are
    /// joined into one.
    pub fn set_kind(&mut self, range: Range<usize>, kind: BlockKind) -> Range<usize> {
        let range = range.start.min(self.blocks.len() - 1)..range.end.min(self.blocks.len());
        if kind == BlockKind::Code {
            let first = range.start;
            let mut text = String::new();
            for (i, block) in self.blocks[range.clone()].iter().enumerate() {
                if i > 0 {
                    text.push('\n');
                }
                text.push_str(&block.text);
            }
            let id = self.blocks[first].id;
            let mut code = Block::new(id, BlockKind::Code, &text);
            code.normalize();
            self.blocks.splice(range, std::iter::once(code));
            return first..first + 1;
        }
        let mut out_end = range.start;
        let mut i = range.start;
        let mut end = range.end;
        while i < end {
            if self.blocks[i].kind == BlockKind::Code {
                // Its lines become blocks.
                let code = self.blocks.remove(i);
                let lines: Vec<&str> = code.text.split('\n').collect();
                let count = lines.len();
                for (k, line) in lines.into_iter().enumerate() {
                    let id = if k == 0 { code.id } else { self.new_id() };
                    let mut block = Block::new(id, kind, line);
                    block.normalize();
                    self.blocks.insert(i + k, block);
                }
                end += count - 1;
                i += count;
                out_end = i;
                continue;
            }
            let block = &mut self.blocks[i];
            block.kind = kind;
            if !kind.is_list() {
                block.indent = 0;
            }
            i += 1;
            out_end = i;
        }
        range.start..out_end
    }

    /// Changes `mark` over the selection: off when every character has it,
    /// else on.
    pub fn toggle_mark(&mut self, start: Pos, end: Pos, mark: Mark) -> bool {
        let on = !self.all_have(start, end, |m| m.has(mark));
        self.change_marks(start, end, &|m: &mut Marks| m.set(mark, on));
        on
    }

    /// Sets or clears the link over the selection.
    pub fn set_link(&mut self, start: Pos, end: Pos, url: Option<String>) {
        self.change_marks(start, end, &|m: &mut Marks| m.link = url.clone());
    }

    /// Whether every character between the positions has a mark that
    /// `test` accepts (false for an empty range).
    pub fn all_have(&self, start: Pos, end: Pos, test: impl Fn(&Marks) -> bool) -> bool {
        let mut any = false;
        for (block, range) in self.ranges(start, end) {
            for (span, marks) in self.blocks[block].spans() {
                if span.start < range.end && span.end > range.start {
                    any = true;
                    if !test(marks) {
                        return false;
                    }
                }
            }
        }
        any
    }

    fn change_marks(&mut self, start: Pos, end: Pos, change: &dyn Fn(&mut Marks)) {
        for (block, range) in self.ranges(start, end) {
            self.blocks[block].apply(range, change);
        }
    }

    /// The byte range of each block between the positions.
    pub fn ranges(&self, a: Pos, b: Pos) -> Vec<(usize, Range<usize>)> {
        let (start, end) = (self.clamp(a.min(b)), self.clamp(a.max(b)));
        (start.block..=end.block)
            .map(|i| {
                let from = if i == start.block { start.offset } else { 0 };
                let to = if i == end.block {
                    end.offset
                } else {
                    self.blocks[i].text.len()
                };
                (i, from..to)
            })
            .collect()
    }

    /// The link around `pos`, as the range it covers in its block.
    pub fn link_at(&self, pos: Pos) -> Option<(Range<usize>, String)> {
        let block = &self.blocks[pos.block];
        for (span, marks) in block.spans() {
            if let Some(url) = &marks.link
                && span.start <= pos.offset
                && pos.offset <= span.end
            {
                // Neighbouring runs of the same link (one is bold) count.
                let mut range = span.clone();
                for (other, m) in block.spans() {
                    if m.link.as_ref() == Some(url) {
                        if other.end == range.start {
                            range.start = other.start;
                        }
                        if other.start == range.end {
                            range.end = other.end;
                        }
                    }
                }
                return Some((range, url.clone()));
            }
        }
        None
    }

    /// The part of the document between two positions, as blocks (for
    /// Copy, and for Paste back into a note).
    pub fn fragment(&self, a: Pos, b: Pos) -> Vec<Block> {
        let (start, end) = (self.clamp(a.min(b)), self.clamp(a.max(b)));
        self.ranges(start, end)
            .into_iter()
            .map(|(i, range)| self.blocks[i].slice(range, 0))
            .collect()
    }

    /// Pastes `blocks` at `pos`: the first joins the text there, the last
    /// joins the text after the caret, those between come in whole.
    /// Returns the caret after.
    pub fn insert_fragment(&mut self, pos: Pos, blocks: &[Block]) -> Pos {
        let pos = self.clamp(pos);
        let Some((first, rest)) = blocks.split_first() else {
            return pos;
        };
        if self.blocks[pos.block].kind == BlockKind::Code {
            // Into a code block, a fragment is its text.
            let text: Vec<&str> = blocks.iter().map(|b| b.text.as_str()).collect();
            return self.insert(pos, &text.join("\n"), &Marks::default());
        }
        // The first block's text goes in with its marks.
        let mut caret = pos;
        for (range, marks) in first.spans() {
            caret = self.insert(caret, &first.text[range], marks);
        }
        if rest.is_empty() {
            return caret;
        }
        // An empty paragraph pasted into takes the first block's kind.
        let target = &mut self.blocks[pos.block];
        if target.text == first.text && target.kind == BlockKind::Paragraph {
            target.kind = first.kind;
            target.indent = first.indent;
        }
        let after = self.split(caret);
        let mut at = after.block;
        for block in rest.iter().take(rest.len() - 1) {
            let mut block = block.clone();
            block.id = self.new_id();
            self.blocks.insert(at, block);
            at += 1;
        }
        // The last one joins what followed the caret.
        let last = &rest[rest.len() - 1];
        let mut caret = Pos::new(at, 0);
        self.blocks[at].kind = last.kind;
        self.blocks[at].indent = last.indent;
        for (range, marks) in last.spans() {
            caret = self.insert(caret, &last.text[range], marks);
        }
        caret
    }

    // ── Movement ────────────────────────────────────────────────────────

    /// The position one grapheme before `pos` (into the previous block's
    /// end at a block's start).
    pub fn prev_char(&self, pos: Pos) -> Pos {
        let pos = self.clamp(pos);
        if pos.offset == 0 {
            return if pos.block == 0 {
                pos
            } else {
                Pos::new(pos.block - 1, self.blocks[pos.block - 1].text.len())
            };
        }
        let text = &self.blocks[pos.block].text[..pos.offset];
        let cut = text
            .grapheme_indices(true)
            .next_back()
            .map_or(0, |(i, _)| i);
        Pos::new(pos.block, cut)
    }

    pub fn next_char(&self, pos: Pos) -> Pos {
        let pos = self.clamp(pos);
        let text = &self.blocks[pos.block].text;
        if pos.offset >= text.len() {
            return if pos.block + 1 >= self.blocks.len() {
                pos
            } else {
                Pos::new(pos.block + 1, 0)
            };
        }
        let len = text[pos.offset..]
            .graphemes(true)
            .next()
            .map_or(0, str::len);
        Pos::new(pos.block, pos.offset + len)
    }

    /// The start of the word before `pos` (⌥←), crossing into the block
    /// above from a block's start.
    pub fn prev_word(&self, pos: Pos) -> Pos {
        let pos = self.clamp(pos);
        if pos.offset == 0 {
            return self.prev_char(pos);
        }
        let text = &self.blocks[pos.block].text[..pos.offset];
        let start = text
            .split_word_bound_indices()
            .filter(|(_, w)| w.chars().any(char::is_alphanumeric))
            .map(|(i, _)| i)
            .next_back()
            .unwrap_or(0);
        Pos::new(pos.block, start)
    }

    /// The end of the word after `pos` (⌥→).
    pub fn next_word(&self, pos: Pos) -> Pos {
        let pos = self.clamp(pos);
        let text = &self.blocks[pos.block].text;
        if pos.offset >= text.len() {
            return self.next_char(pos);
        }
        let end = text[pos.offset..]
            .split_word_bound_indices()
            .find(|(_, w)| w.chars().any(char::is_alphanumeric))
            .map_or(text.len() - pos.offset, |(i, w)| i + w.len());
        Pos::new(pos.block, pos.offset + end)
    }

    /// The word around `pos` (a double click).
    pub fn word_at(&self, pos: Pos) -> (Pos, Pos) {
        let pos = self.clamp(pos);
        let text = &self.blocks[pos.block].text;
        for (i, w) in text.split_word_bound_indices() {
            if pos.offset >= i && pos.offset < i + w.len()
                || pos.offset == i + w.len() && i + w.len() == text.len()
            {
                return (Pos::new(pos.block, i), Pos::new(pos.block, i + w.len()));
            }
        }
        (pos, pos)
    }

    // ── Quill ───────────────────────────────────────────────────────────

    /// The document `ops` describe (Quill 2 deltas, as `notes.get` sends
    /// them).
    pub fn from_ops(ops: &[Value]) -> Self {
        let mut blocks: Vec<Block> = vec![];
        let mut line = Block::new(0, BlockKind::Paragraph, "");
        for op in ops {
            let Some(object) = op.as_object() else {
                continue;
            };
            let attributes = object.get("attributes").and_then(Value::as_object);
            let text = match object.get("insert") {
                Some(Value::String(s)) => s.clone(),
                // An embed the codec sends back only for content made
                // elsewhere: kept as the markdown that means it.
                Some(Value::Object(embed)) => {
                    if embed.contains_key("divider") {
                        "---\n".into()
                    } else if let Some(src) = embed.get("image").and_then(Value::as_str) {
                        format!("![]({src})")
                    } else {
                        continue;
                    }
                }
                _ => continue,
            };
            let marks = marks_of(attributes);
            let mut parts = text.split('\n').peekable();
            while let Some(part) = parts.next() {
                if !part.is_empty() {
                    let at = line.text.len();
                    line.insert(at, part, &marks);
                }
                if parts.peek().is_some() {
                    // The line break carries the line's format.
                    let (kind, indent) = line_format(attributes);
                    let mut done =
                        std::mem::replace(&mut line, Block::new(0, BlockKind::Paragraph, ""));
                    done.kind = kind;
                    done.indent = indent;
                    // Consecutive code lines are one code block.
                    if kind == BlockKind::Code
                        && let Some(prev) = blocks.last_mut()
                        && prev.kind == BlockKind::Code
                    {
                        prev.text.push('\n');
                        prev.text.push_str(&done.text);
                        prev.normalize();
                        continue;
                    }
                    blocks.push(done);
                }
            }
        }
        if !line.text.is_empty() {
            blocks.push(line);
        }
        Self::from_blocks(blocks)
    }

    /// The document as Quill ops, for `notes.save`.
    pub fn to_ops(&self) -> Vec<Value> {
        blocks_to_ops(&self.blocks)
    }
}

/// `blocks` as Quill ops (a fragment for the clipboard, or a document).
pub fn blocks_to_ops(blocks: &[Block]) -> Vec<Value> {
    let mut ops: Vec<Value> = vec![];
    let mut push = |insert: String, attributes: Map<String, Value>| {
        // Neighbouring inserts with one format are one op, as Quill keeps
        // them.
        if let Some(Value::Object(last)) = ops.last_mut() {
            let same = last
                .get("attributes")
                .and_then(Value::as_object)
                .map_or(attributes.is_empty(), |a| *a == attributes);
            if same && let Some(Value::String(prev)) = last.get_mut("insert") {
                prev.push_str(&insert);
                return;
            }
        }
        let mut op = Map::new();
        op.insert("insert".into(), Value::String(insert));
        if !attributes.is_empty() {
            op.insert("attributes".into(), Value::Object(attributes));
        }
        ops.push(Value::Object(op));
    };
    for block in blocks {
        let lines: Vec<&str> = if block.kind == BlockKind::Code {
            block.text.split('\n').collect()
        } else {
            vec![block.text.as_str()]
        };
        if block.kind == BlockKind::Code {
            for line in lines {
                if !line.is_empty() {
                    push(line.to_string(), Map::new());
                }
                push("\n".into(), line_attributes(block));
            }
            continue;
        }
        for (range, marks) in block.spans() {
            push(block.text[range].to_string(), mark_attributes(marks));
        }
        push("\n".into(), line_attributes(block));
    }
    if ops.is_empty() {
        ops.push(json!({ "insert": "\n" }));
    }
    ops
}

/// A link the copied HTML keeps: `http`, `https` or `mailto` (a
/// `javascript:` or `file:` one stays words).
fn copyable_link(url: &str) -> bool {
    let scheme = url
        .split(':')
        .next()
        .unwrap_or_default()
        .to_ascii_lowercase();
    url.contains(':') && matches!(scheme.as_str(), "http" | "https" | "mailto")
}

/// `blocks` as HTML, for the pasteboard's rich form (Mail, Pages and Notes
/// paste it with its formatting).
pub fn blocks_to_html(blocks: &[Block]) -> String {
    fn escape(s: &str) -> String {
        s.replace('&', "&amp;")
            .replace('<', "&lt;")
            .replace('>', "&gt;")
            .replace('"', "&quot;")
    }
    fn inline(block: &Block) -> String {
        let mut out = String::new();
        for (range, m) in block.spans() {
            let mut text = escape(&block.text[range]);
            if m.code {
                text = format!("<code>{text}</code>");
            }
            if m.strike {
                text = format!("<s>{text}</s>");
            }
            if m.underline {
                text = format!("<u>{text}</u>");
            }
            if m.italic {
                text = format!("<i>{text}</i>");
            }
            if m.bold {
                text = format!("<b>{text}</b>");
            }
            // Only web and mail addresses: another app follows the link.
            if let Some(url) = m.link.as_ref().filter(|u| copyable_link(u)) {
                text = format!("<a href=\"{}\">{text}</a>", escape(url));
            }
            out.push_str(&text);
        }
        out
    }
    let mut out = String::new();
    let mut open: Option<&'static str> = None;
    for block in blocks {
        let list = match block.kind {
            BlockKind::Bullet | BlockKind::Check(_) => Some("ul"),
            BlockKind::Ordered => Some("ol"),
            _ => None,
        };
        if open != list {
            if let Some(tag) = open {
                out.push_str(&format!("</{tag}>"));
            }
            if let Some(tag) = list {
                out.push_str(&format!("<{tag}>"));
            }
            open = list;
        }
        match block.kind {
            BlockKind::Paragraph => out.push_str(&format!("<p>{}</p>", inline(block))),
            BlockKind::Heading(level) => {
                out.push_str(&format!("<h{level}>{}</h{level}>", inline(block)))
            }
            BlockKind::Bullet | BlockKind::Ordered => {
                out.push_str(&format!("<li>{}</li>", inline(block)))
            }
            BlockKind::Check(checked) => out.push_str(&format!(
                "<li>{} {}</li>",
                if checked { "\u{2611}" } else { "\u{2610}" },
                inline(block)
            )),
            BlockKind::Quote => {
                out.push_str(&format!("<blockquote>{}</blockquote>", inline(block)))
            }
            BlockKind::Code => {
                out.push_str(&format!("<pre><code>{}</code></pre>", escape(&block.text)))
            }
        }
    }
    if let Some(tag) = open {
        out.push_str(&format!("</{tag}>"));
    }
    out
}

/// A fragment of blocks from Quill ops (the clipboard's rich form).
pub fn blocks_from_ops(ops: &[Value]) -> Vec<Block> {
    // A fragment that does not end its last line still has it.
    let mut doc = Doc::from_ops(ops);
    let ends_line = ops
        .last()
        .and_then(|op| op.get("insert"))
        .and_then(Value::as_str)
        .is_some_and(|s| s.ends_with('\n'));
    if !ends_line && doc.blocks.len() > 1 && doc.blocks.last().is_some_and(|b| b.text.is_empty()) {
        doc.blocks.pop();
    }
    doc.blocks
}

fn marks_of(attributes: Option<&Map<String, Value>>) -> Marks {
    let mut marks = Marks::default();
    let Some(attributes) = attributes else {
        return marks;
    };
    let on = |key: &str| attributes.get(key).and_then(Value::as_bool) == Some(true);
    marks.bold = on("bold");
    marks.italic = on("italic");
    marks.underline = on("underline");
    marks.strike = on("strike");
    marks.code = on("code");
    marks.link = attributes
        .get("link")
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())
        .map(str::to_string);
    marks
}

fn line_format(attributes: Option<&Map<String, Value>>) -> (BlockKind, u8) {
    let Some(attributes) = attributes else {
        return (BlockKind::Paragraph, 0);
    };
    let indent = attributes
        .get("indent")
        .and_then(Value::as_u64)
        .map_or(0, |i| i.min(8) as u8);
    if let Some(level) = attributes.get("header").and_then(Value::as_u64) {
        return (BlockKind::Heading(level.clamp(1, 6) as u8), 0);
    }
    if let Some(list) = attributes.get("list").and_then(Value::as_str) {
        let kind = match list {
            "ordered" => BlockKind::Ordered,
            "checked" => BlockKind::Check(true),
            "unchecked" => BlockKind::Check(false),
            _ => BlockKind::Bullet,
        };
        return (kind, indent);
    }
    if attributes.get("blockquote").and_then(Value::as_bool) == Some(true) {
        return (BlockKind::Quote, 0);
    }
    match attributes.get("code-block") {
        Some(Value::Bool(false)) | Some(Value::Null) | None => {}
        Some(_) => return (BlockKind::Code, 0),
    }
    (BlockKind::Paragraph, 0)
}

fn mark_attributes(marks: &Marks) -> Map<String, Value> {
    let mut out = Map::new();
    if marks.bold {
        out.insert("bold".into(), true.into());
    }
    if marks.italic {
        out.insert("italic".into(), true.into());
    }
    if marks.underline {
        out.insert("underline".into(), true.into());
    }
    if marks.strike {
        out.insert("strike".into(), true.into());
    }
    if marks.code {
        out.insert("code".into(), true.into());
    }
    if let Some(link) = &marks.link {
        out.insert("link".into(), link.clone().into());
    }
    out
}

fn line_attributes(block: &Block) -> Map<String, Value> {
    let mut out = Map::new();
    match block.kind {
        BlockKind::Paragraph => {}
        BlockKind::Heading(level) => {
            out.insert("header".into(), u64::from(level).into());
        }
        BlockKind::Bullet => {
            out.insert("list".into(), "bullet".into());
        }
        BlockKind::Ordered => {
            out.insert("list".into(), "ordered".into());
        }
        BlockKind::Check(checked) => {
            out.insert(
                "list".into(),
                if checked { "checked" } else { "unchecked" }.into(),
            );
        }
        BlockKind::Quote => {
            out.insert("blockquote".into(), true.into());
        }
        BlockKind::Code => {
            out.insert("code-block".into(), "plain".into());
        }
    }
    if block.kind.is_list() && block.indent > 0 {
        out.insert("indent".into(), u64::from(block.indent).into());
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ops(value: Value) -> Vec<Value> {
        value.as_array().cloned().unwrap()
    }

    /// Every format the editor offers, as the daemon's codec sends them.
    fn every_format() -> Vec<Value> {
        ops(json!([
            { "insert": "Plan" }, { "insert": "\n", "attributes": { "header": 1 } },
            { "insert": "Some " }, { "insert": "bold", "attributes": { "bold": true } },
            { "insert": ", " }, { "insert": "italic", "attributes": { "italic": true } },
            { "insert": ", " }, { "insert": "gone", "attributes": { "strike": true } },
            { "insert": " and " }, { "insert": "code", "attributes": { "code": true } },
            { "insert": " with a " },
            { "insert": "link", "attributes": { "link": "https://example.com/a" } },
            { "insert": ".\n" },
            { "insert": "One" }, { "insert": "\n", "attributes": { "list": "bullet" } },
            { "insert": "Nested" },
            { "insert": "\n", "attributes": { "list": "bullet", "indent": 1 } },
            { "insert": "First" }, { "insert": "\n", "attributes": { "list": "ordered" } },
            { "insert": "Done" }, { "insert": "\n", "attributes": { "list": "checked" } },
            { "insert": "To do" }, { "insert": "\n", "attributes": { "list": "unchecked" } },
            { "insert": "Quoted" }, { "insert": "\n", "attributes": { "blockquote": true } },
            { "insert": "let a = 1;" },
            { "insert": "\n", "attributes": { "code-block": "plain" } },
            { "insert": "let b = 2;" },
            { "insert": "\n", "attributes": { "code-block": "plain" } },
            { "insert": "Sub" }, { "insert": "\n", "attributes": { "header": 2 } },
        ]))
    }

    #[test]
    fn every_format_round_trips_through_quill_ops() {
        let source = every_format();
        let doc = Doc::from_ops(&source);
        let kinds: Vec<BlockKind> = doc.blocks.iter().map(|b| b.kind).collect();
        assert_eq!(
            kinds,
            vec![
                BlockKind::Heading(1),
                BlockKind::Paragraph,
                BlockKind::Bullet,
                BlockKind::Bullet,
                BlockKind::Ordered,
                BlockKind::Check(true),
                BlockKind::Check(false),
                BlockKind::Quote,
                BlockKind::Code,
                BlockKind::Heading(2),
            ]
        );
        assert_eq!(doc.blocks[3].indent, 1);
        assert_eq!(doc.blocks[8].text, "let a = 1;\nlet b = 2;");
        let marks: Vec<Marks> = doc.blocks[1]
            .spans()
            .into_iter()
            .map(|(_, m)| m.clone())
            .collect();
        assert!(marks.iter().any(|m| m.bold));
        assert!(marks.iter().any(|m| m.italic));
        assert!(marks.iter().any(|m| m.strike));
        assert!(marks.iter().any(|m| m.code));
        assert!(
            marks
                .iter()
                .any(|m| m.link.as_deref() == Some("https://example.com/a"))
        );
        // Back to ops (Quill's canonical form: neighbours with one format
        // are one op), and again: nothing changes.
        let back = doc.to_ops();
        assert_eq!(back.len(), source.len() - 1);
        assert_eq!(Doc::from_ops(&back), doc);
        assert_eq!(Doc::from_ops(&back).to_ops(), back);
    }

    #[test]
    fn an_empty_note_is_one_empty_paragraph_and_one_line_break() {
        let doc = Doc::from_ops(&ops(json!([{ "insert": "\n" }])));
        assert!(doc.is_empty());
        assert_eq!(doc.to_ops(), ops(json!([{ "insert": "\n" }])));
        assert!(Doc::from_ops(&[]).is_empty());
        // Blank lines between paragraphs are kept.
        let spaced = ops(json!([{ "insert": "a\n\nb\n" }]));
        assert_eq!(Doc::from_ops(&spaced).blocks.len(), 3);
        assert_eq!(Doc::from_ops(&spaced).to_ops(), spaced);
    }

    #[test]
    fn typing_continues_the_marks_before_the_caret_but_not_a_link() {
        let mut doc = Doc::default();
        let bold = Marks {
            bold: true,
            ..Marks::default()
        };
        let caret = doc.insert(Pos::new(0, 0), "Hi", &bold);
        assert_eq!(caret, Pos::new(0, 2));
        assert_eq!(doc.blocks[0].marks_at(2), bold);
        doc.insert(caret, " there", &doc.blocks[0].marks_at(2));
        assert_eq!(doc.blocks[0].runs.len(), 1);
    }

    #[test]
    fn return_splits_a_block_and_lists_continue() {
        let mut doc = Doc::from_ops(&ops(json!([
            { "insert": "milk eggs" },
            { "insert": "\n", "attributes": { "list": "checked" } },
        ])));
        let next = doc.split(Pos::new(0, 4));
        assert_eq!(next, Pos::new(1, 0));
        assert_eq!(doc.blocks[0].text, "milk");
        assert_eq!(doc.blocks[1].text, " eggs");
        assert_eq!(doc.blocks[1].kind, BlockKind::Check(false));
        // A heading's next line is a paragraph.
        let mut doc = Doc::from_ops(&ops(json!([
            { "insert": "Title" }, { "insert": "\n", "attributes": { "header": 1 } },
        ])));
        doc.split(Pos::new(0, 5));
        assert_eq!(doc.blocks[1].kind, BlockKind::Paragraph);
    }

    #[test]
    fn deleting_across_blocks_joins_them_into_the_first() {
        let mut doc = Doc::from_ops(&ops(json!([
            { "insert": "Head" }, { "insert": "\n", "attributes": { "header": 2 } },
            { "insert": "body " }, { "insert": "text", "attributes": { "bold": true } },
            { "insert": "\n" },
        ])));
        let caret = doc.delete(Pos::new(0, 2), Pos::new(1, 5));
        assert_eq!(caret, Pos::new(0, 2));
        assert_eq!(doc.blocks.len(), 1);
        assert_eq!(doc.blocks[0].text, "Hetext");
        assert_eq!(doc.blocks[0].kind, BlockKind::Heading(2));
        assert!(doc.blocks[0].marks_at(6).bold);
    }

    #[test]
    fn marks_toggle_off_only_when_all_of_the_selection_has_them() {
        let mut doc = Doc::default();
        doc.insert(Pos::new(0, 0), "one two", &Marks::default());
        assert!(doc.toggle_mark(Pos::new(0, 0), Pos::new(0, 3), Mark::Bold));
        // Half bold: on for all of it.
        assert!(doc.toggle_mark(Pos::new(0, 0), Pos::new(0, 7), Mark::Bold));
        assert!(doc.all_have(Pos::new(0, 0), Pos::new(0, 7), |m| m.bold));
        assert!(!doc.toggle_mark(Pos::new(0, 0), Pos::new(0, 7), Mark::Bold));
        assert_eq!(doc.blocks[0].runs.len(), 1);
        doc.set_link(
            Pos::new(0, 4),
            Pos::new(0, 7),
            Some("https://a.example".into()),
        );
        assert_eq!(
            doc.link_at(Pos::new(0, 5)),
            Some((4..7, "https://a.example".into()))
        );
    }

    #[test]
    fn blocks_turn_into_code_and_back_line_by_line() {
        let mut doc = Doc::from_ops(&ops(json!([{ "insert": "a\nb\nc\n" }])));
        let range = doc.set_kind(0..2, BlockKind::Code);
        assert_eq!(range, 0..1);
        assert_eq!(doc.blocks[0].text, "a\nb");
        assert_eq!(doc.blocks.len(), 2);
        let range = doc.set_kind(0..1, BlockKind::Bullet);
        assert_eq!(range, 0..2);
        assert_eq!(doc.blocks[1].text, "b");
        assert_eq!(doc.blocks[1].kind, BlockKind::Bullet);
    }

    #[test]
    fn flat_offsets_cross_block_boundaries() {
        let doc = Doc::from_ops(&ops(json!([{ "insert": "ab\ncdé\n" }])));
        assert_eq!(doc.plain_text(), "ab\ncdé");
        assert_eq!(doc.flat(Pos::new(1, 1)), 4);
        assert_eq!(doc.unflat(4), Pos::new(1, 1));
        assert_eq!(doc.unflat(2), Pos::new(0, 2));
        assert_eq!(doc.unflat(3), Pos::new(1, 0));
        assert_eq!(doc.unflat(99), Pos::new(1, 4));
        assert_eq!(doc.text_in(Pos::new(0, 1), Pos::new(1, 2)), "b\ncd");
    }

    #[test]
    fn fragments_paste_back_with_their_formats() {
        let source = Doc::from_ops(&every_format());
        let fragment = source.fragment(Pos::new(1, 5), Pos::new(3, 3));
        assert_eq!(fragment.len(), 3);
        let ops = blocks_to_ops(&fragment);
        assert_eq!(blocks_from_ops(&ops).len(), 3);
        let mut doc = Doc::default();
        doc.insert(Pos::new(0, 0), "[]", &Marks::default());
        let caret = doc.insert_fragment(Pos::new(0, 1), &fragment);
        assert_eq!(doc.blocks.len(), 3);
        assert_eq!(
            doc.blocks[0].text,
            "[bold, italic, gone and code with a link."
        );
        assert_eq!(doc.blocks[2].text, "Nes]");
        assert_eq!(caret, Pos::new(2, 3));
        assert_eq!(doc.blocks[1].kind, BlockKind::Bullet);
    }

    #[test]
    fn a_fragment_copies_as_html_with_its_formats() {
        let doc = Doc::from_ops(&every_format());
        let html = blocks_to_html(&doc.blocks);
        for part in [
            "<h1>Plan</h1>",
            "<b>bold</b>",
            "<i>italic</i>",
            "<s>gone</s>",
            "<code>code</code>",
            "<a href=\"https://example.com/a\">link</a>",
            "<ul><li>One</li><li>Nested</li></ul><ol><li>First</li></ol>",
            "<blockquote>Quoted</blockquote>",
            "<pre><code>let a = 1;\nlet b = 2;</code></pre>",
        ] {
            assert!(html.contains(part), "{part} in {html}");
        }
    }

    /// Copied rich text links only to web and mail addresses: a `javascript:`
    /// or `file:` link stays words, never a link another app would follow.
    #[test]
    fn copies_link_only_web_and_mail_addresses() {
        let doc = Doc::from_ops(&ops(json!([
            { "insert": "map", "attributes": { "link": "https://example.com/trail" } },
            { "insert": " " },
            { "insert": "mail", "attributes": { "link": "mailto:ranger@example.com" } },
            { "insert": " " },
            { "insert": "run", "attributes": { "link": "javascript:alert(1)" } },
            { "insert": " " },
            { "insert": "disk", "attributes": { "link": "file:///etc/hosts" } },
            { "insert": "\n" },
        ])));
        let html = blocks_to_html(&doc.blocks);
        assert!(
            html.contains("<a href=\"https://example.com/trail\">map</a>"),
            "{html}"
        );
        assert!(
            html.contains("<a href=\"mailto:ranger@example.com\">mail</a>"),
            "{html}"
        );
        assert!(!html.contains("javascript:"), "{html}");
        assert!(!html.contains("file:"), "{html}");
        assert!(html.contains("run") && html.contains("disk"), "{html}");
    }

    #[test]
    fn file_links_alone_in_a_paragraph_are_attachments() {
        let doc = Doc::from_ops(&ops(json!([
            { "insert": "recording.wav", "attributes": { "link": "/api/v1/files/f-1_a/content" } },
            { "insert": "\nsee " },
            { "insert": "this", "attributes": { "link": "/api/v1/files/f2/content" } },
            { "insert": "\n" },
        ])));
        assert_eq!(
            doc.blocks[0].file_link(),
            Some(FileLink {
                id: "f-1_a".into(),
                name: "recording.wav".into()
            })
        );
        assert_eq!(doc.blocks[1].file_link(), None);
        assert_eq!(doc.counts(), (2, 8));
    }

    #[test]
    fn words_move_by_word_boundaries_and_cross_blocks() {
        let doc = Doc::from_ops(&ops(json!([{ "insert": "hello big world\nnext\n" }])));
        assert_eq!(doc.next_word(Pos::new(0, 0)), Pos::new(0, 5));
        assert_eq!(doc.next_word(Pos::new(0, 5)), Pos::new(0, 9));
        assert_eq!(doc.prev_word(Pos::new(0, 15)), Pos::new(0, 10));
        assert_eq!(doc.prev_word(Pos::new(1, 0)), Pos::new(0, 15));
        assert_eq!(doc.next_char(Pos::new(0, 15)), Pos::new(1, 0));
        assert_eq!(
            doc.word_at(Pos::new(0, 7)),
            (Pos::new(0, 6), Pos::new(0, 9))
        );
    }
}
