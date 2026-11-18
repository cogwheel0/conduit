//! The terminal's emulator: `alacritty_terminal`'s parser and grid behind
//! one lock, with nothing of GPUI in it.
//!
//! * The shell's output is parsed where it arrives, on the socket's runtime
//!   thread ([`Feeder`]), so a flood of output never holds up the UI thread;
//!   the UI thread only takes the lock to copy what is on screen
//!   ([`Emulator::frame`]) and to act on the grid (resize, scroll, select).
//! * Replies the terminal owes the shell (a cursor position report, a
//!   colour, the size) go straight back through the writer
//!   ([`Emulator::set_writer`]); what the window acts on (a title, a copy
//!   request, a bell) waits in [`Emulator::take_notes`].
//! * Colours resolve against a [`Palette`] here, so the painter gets plain
//!   RGB per cell.

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

use alacritty_terminal::event::{Event as TermEvent, EventListener, WindowSize};
use alacritty_terminal::grid::{Dimensions, Scroll};
use alacritty_terminal::index::{Column, Direction, Line, Point, Side};
use alacritty_terminal::selection::{Selection, SelectionType};
use alacritty_terminal::sync::FairMutex;
use alacritty_terminal::term::cell::Flags;
use alacritty_terminal::term::search::{Match, RegexIter, RegexSearch};
use alacritty_terminal::term::{Config, Term, TermMode};
use alacritty_terminal::vte::ansi::{Color, CursorShape, NamedColor, Processor, Rgb};

use super::console::legible_on;

/// How much history a terminal keeps, in lines.
pub const SCROLLBACK: usize = 10_000;

/// The most search matches kept (and highlighted) at once.
pub const MAX_MATCHES: usize = 2_000;

/// A grid size.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct GridSize {
    pub cols: usize,
    pub rows: usize,
}

impl Dimensions for GridSize {
    fn total_lines(&self) -> usize {
        self.rows
    }

    fn screen_lines(&self) -> usize {
        self.rows
    }

    fn columns(&self) -> usize {
        self.cols
    }
}

/// The colours a terminal paints with: the 16 ANSI colours, and the
/// default foreground, background and cursor.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Palette {
    pub ansi: [Rgb; 16],
    pub foreground: Rgb,
    pub background: Rgb,
    pub cursor: Rgb,
}

impl Palette {
    /// The colour of 256-colour index `i`: the 16 named ones, the 6×6×6
    /// cube, then the 24 greys.
    pub fn indexed(&self, i: u8) -> Rgb {
        match i {
            0..=15 => self.ansi[i as usize],
            16..=231 => {
                let i = i - 16;
                let level = |v: u8| if v == 0 { 0 } else { 55 + v * 40 };
                Rgb {
                    r: level(i / 36),
                    g: level((i / 6) % 6),
                    b: level(i % 6),
                }
            }
            232..=255 => {
                let v = 8 + (i - 232) * 10;
                Rgb { r: v, g: v, b: v }
            }
        }
    }

    /// The colour a colour request (OSC 4, 10, 11, 12) asks for by index:
    /// 0–255, then the foreground, background and cursor.
    fn requested(&self, index: usize) -> Rgb {
        match index {
            0..=255 => self.indexed(index as u8),
            i if i == NamedColor::Background as usize => self.background,
            i if i == NamedColor::Cursor as usize => self.cursor,
            _ => self.foreground,
        }
    }
}

/// Whether `color` is one of the palette's (the default colours and the 16
/// ANSI ones), not one the program gave as an exact colour.
fn from_palette(color: Color) -> bool {
    match color {
        Color::Named(_) => true,
        Color::Indexed(i) => i < 16,
        Color::Spec(_) => false,
    }
}

fn rgb_key(c: Rgb) -> u32 {
    (c.r as u32) << 16 | (c.g as u32) << 8 | c.b as u32
}

/// `c` at two thirds, toward `toward` (dim and faint text).
fn dim(c: Rgb, toward: Rgb) -> Rgb {
    let mix = |a: u8, b: u8| ((a as u16 * 2 + b as u16) / 3) as u8;
    Rgb {
        r: mix(c.r, toward.r),
        g: mix(c.g, toward.g),
        b: mix(c.b, toward.b),
    }
}

/// What the window does for the terminal, read with [`Emulator::take_notes`].
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Note {
    /// The shell named the window (OSC 0/2), or reset it (None).
    Title(Option<String>),
    /// The shell asked to copy text (OSC 52).
    Copy(String),
    Bell,
}

/// Bytes for the shell.
pub type Writer = Box<dyn Fn(&[u8]) + Send + Sync>;

#[derive(Default)]
struct Shared {
    writer: Mutex<Option<Writer>>,
    notes: Mutex<Vec<Note>>,
    /// A note came since the feeder last looked: the UI needs waking even
    /// when the screen is already waiting for its paint.
    noted: AtomicBool,
    palette: Mutex<Option<Palette>>,
    /// The grid in cells and in pixels, for size requests (CSI 14/18 t).
    size: Mutex<Option<WindowSize>>,
}

/// The terminal's event listener: replies go to the writer, the rest wait
/// as notes. Called with the grid locked, from whichever thread parses.
#[derive(Clone, Default)]
pub struct Listener(Arc<Shared>);

impl Listener {
    fn write(&self, text: &str) {
        if let Some(writer) = self.0.writer.lock().unwrap().as_ref() {
            writer(text.as_bytes());
        }
    }

    fn note(&self, note: Note) {
        self.0.notes.lock().unwrap().push(note);
        self.0.noted.store(true, Ordering::Release);
    }
}

impl EventListener for Listener {
    fn send_event(&self, event: TermEvent) {
        match event {
            TermEvent::PtyWrite(text) => self.write(&text),
            TermEvent::ColorRequest(index, format) => {
                let palette = *self.0.palette.lock().unwrap();
                if let Some(palette) = palette {
                    self.write(&format(palette.requested(index)));
                }
            }
            TermEvent::TextAreaSizeRequest(format) => {
                let size = *self.0.size.lock().unwrap();
                if let Some(size) = size {
                    self.write(&format(size));
                }
            }
            TermEvent::Title(title) => self.note(Note::Title(Some(title))),
            TermEvent::ResetTitle => self.note(Note::Title(None)),
            TermEvent::ClipboardStore(_, text) => self.note(Note::Copy(text)),
            TermEvent::Bell => self.note(Note::Bell),
            // Reading the clipboard is never offered to the shell.
            _ => {}
        }
    }
}

/// One cell as the painter needs it.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct CellView {
    pub ch: char,
    pub fg: Rgb,
    pub bg: Rgb,
    /// The background is the terminal's own: nothing to paint.
    pub default_bg: bool,
    /// The text is one of the palette's colours (kept at AA on what is
    /// painted under it), not one the program gave exactly or hidden.
    pub palette_text: bool,
    pub style: CellStyle,
    /// Index into [`Frame::zerowidth`] plus one; 0 for none.
    pub zerowidth: u16,
}

/// A cell's text style and what covers it.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
pub struct CellStyle {
    pub bold: bool,
    pub italic: bool,
    pub underline: bool,
    pub strike: bool,
    /// The left half of a double-width character.
    pub wide: bool,
    /// The right half of one, drawn by its left half.
    pub spacer: bool,
    pub selected: bool,
    /// Part of a search match; `current` for the one Find is on.
    pub matched: bool,
    pub current: bool,
}

/// Where the cursor is drawn.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct CursorView {
    pub row: usize,
    pub col: usize,
    pub shape: CursorShape,
    /// It sits on a double-width character.
    pub wide: bool,
}

/// What is on screen: the cells of every visible row, row by row.
#[derive(Clone, Debug)]
pub struct Frame {
    pub size: GridSize,
    pub cells: Vec<CellView>,
    pub zerowidth: Vec<String>,
    pub cursor: Option<CursorView>,
    /// Lines scrolled back from the bottom.
    pub display_offset: usize,
    pub history: usize,
    pub mode: TermMode,
    pub background: Rgb,
}

impl Frame {
    pub fn row(&self, row: usize) -> &[CellView] {
        &self.cells[row * self.size.cols..(row + 1) * self.size.cols]
    }

    /// A row's text, trailing blanks dropped (for tests and AccessKit).
    pub fn row_text(&self, row: usize) -> String {
        let mut text = String::new();
        for cell in self.row(row) {
            if cell.style.spacer {
                continue;
            }
            text.push(cell.ch);
            if cell.zerowidth > 0 {
                text.push_str(&self.zerowidth[cell.zerowidth as usize - 1]);
            }
        }
        text.trim_end().to_string()
    }

    /// Every row's text, one line each.
    pub fn text(&self) -> String {
        (0..self.size.rows)
            .map(|r| self.row_text(r))
            .collect::<Vec<_>>()
            .join("\n")
    }
}

/// A point in the grid: `line` counts from the top of the screen without
/// scrollback (history lines are negative), as `alacritty_terminal` does.
pub type GridPoint = Point;

/// A terminal: cheap to clone, shared by the UI and the socket's parser.
#[derive(Clone)]
pub struct Emulator {
    term: Arc<FairMutex<Term<Listener>>>,
    listener: Listener,
    dirty: Arc<AtomicBool>,
}

/// The socket's side: parses output into the grid.
pub struct Feeder {
    term: Arc<FairMutex<Term<Listener>>>,
    listener: Listener,
    parser: Processor,
    dirty: Arc<AtomicBool>,
}

impl Feeder {
    /// Parses `bytes` into the grid. True when the UI needs waking: this
    /// made the screen dirty (it was clean before), or left a note (a
    /// title, a copy, a bell), which must not wait for a paint.
    pub fn feed(&mut self, bytes: &[u8]) -> bool {
        let mut term = self.term.lock();
        self.parser.advance(&mut *term, bytes);
        drop(term);
        let noted = self.listener.0.noted.swap(false, Ordering::AcqRel);
        !self.dirty.swap(true, Ordering::AcqRel) || noted
    }
}

impl Emulator {
    pub fn new(size: GridSize) -> Self {
        let listener = Listener::default();
        let config = Config {
            scrolling_history: SCROLLBACK,
            ..Config::default()
        };
        let term = Term::new(config, &size, listener.clone());
        Self {
            term: Arc::new(FairMutex::new(term)),
            listener,
            dirty: Arc::new(AtomicBool::new(true)),
        }
    }

    /// A parser for one socket's output.
    pub fn feeder(&self) -> Feeder {
        Feeder {
            term: self.term.clone(),
            listener: self.listener.clone(),
            parser: Processor::new(),
            dirty: self.dirty.clone(),
        }
    }

    /// Parses `bytes` on this thread (a banner of the window's own).
    pub fn feed(&self, bytes: &[u8]) {
        self.feeder().feed(bytes);
    }

    /// Where replies to the shell go; None while no shell listens.
    pub fn set_writer(&self, writer: Option<Writer>) {
        *self.listener.0.writer.lock().unwrap() = writer;
    }

    pub fn set_palette(&self, palette: Palette) {
        *self.listener.0.palette.lock().unwrap() = Some(palette);
    }

    /// Marks the screen clean; true when it was dirty.
    pub fn take_dirty(&self) -> bool {
        self.dirty.swap(false, Ordering::AcqRel)
    }

    pub fn take_notes(&self) -> Vec<Note> {
        std::mem::take(&mut *self.listener.0.notes.lock().unwrap())
    }

    pub fn size(&self) -> GridSize {
        let term = self.term.lock();
        GridSize {
            cols: term.columns(),
            rows: term.screen_lines(),
        }
    }

    /// Resizes the grid; `cell` is a cell's size in pixels, for size
    /// requests. False when the size was already that.
    pub fn resize(&self, size: GridSize, cell: (f32, f32)) -> bool {
        let size = GridSize {
            cols: size.cols.max(2),
            rows: size.rows.max(1),
        };
        *self.listener.0.size.lock().unwrap() = Some(WindowSize {
            num_lines: size.rows as u16,
            num_cols: size.cols as u16,
            cell_width: cell.0.round() as u16,
            cell_height: cell.1.round() as u16,
        });
        let mut term = self.term.lock();
        if term.columns() == size.cols && term.screen_lines() == size.rows {
            return false;
        }
        term.resize(size);
        self.dirty.store(true, Ordering::Release);
        true
    }

    pub fn mode(&self) -> TermMode {
        *self.term.lock().mode()
    }

    pub fn display_offset(&self) -> usize {
        self.term.lock().grid().display_offset()
    }

    /// Scrolls the view `lines` up (positive) or down into the history.
    pub fn scroll(&self, lines: i32) {
        self.term.lock().scroll_display(Scroll::Delta(lines));
        self.dirty.store(true, Ordering::Release);
    }

    pub fn scroll_to_bottom(&self) {
        let mut term = self.term.lock();
        if term.grid().display_offset() != 0 {
            term.scroll_display(Scroll::Bottom);
            self.dirty.store(true, Ordering::Release);
        }
    }

    /// The grid point under viewport cell (`row`, `col`).
    pub fn point_at(&self, row: usize, col: usize) -> GridPoint {
        let term = self.term.lock();
        let offset = term.grid().display_offset() as i32;
        let row = row.min(term.screen_lines().saturating_sub(1));
        let col = col.min(term.columns().saturating_sub(1));
        Point::new(Line(row as i32 - offset), Column(col))
    }

    /// Starts a selection at `point`: by character, word or line.
    pub fn select_start(&self, point: GridPoint, side: Side, kind: SelectionType) {
        let mut term = self.term.lock();
        term.selection = Some(Selection::new(kind, point, side));
        self.dirty.store(true, Ordering::Release);
    }

    /// Moves the selection's end to `point`.
    pub fn select_to(&self, point: GridPoint, side: Side) {
        let mut term = self.term.lock();
        if let Some(selection) = term.selection.as_mut() {
            selection.update(point, side);
            self.dirty.store(true, Ordering::Release);
        }
    }

    pub fn select_all(&self) {
        let mut term = self.term.lock();
        let start = Point::new(term.topmost_line(), Column(0));
        let end = Point::new(term.bottommost_line(), term.last_column());
        let mut selection = Selection::new(SelectionType::Simple, start, Side::Left);
        selection.update(end, Side::Right);
        term.selection = Some(selection);
        self.dirty.store(true, Ordering::Release);
    }

    pub fn clear_selection(&self) {
        let mut term = self.term.lock();
        if term.selection.take().is_some() {
            self.dirty.store(true, Ordering::Release);
        }
    }

    pub fn has_selection(&self) -> bool {
        self.term
            .lock()
            .selection
            .as_ref()
            .is_some_and(|s| !s.is_empty())
    }

    pub fn selection_text(&self) -> Option<String> {
        self.term
            .lock()
            .selection_to_string()
            .filter(|s| !s.is_empty())
    }

    /// Clears the history above the screen (Edit › Clear Scrollback).
    pub fn clear_scrollback(&self) {
        let mut term = self.term.lock();
        term.grid_mut().clear_history();
        term.selection = None;
        self.dirty.store(true, Ordering::Release);
    }

    /// Every match of `query` (literal text; lower case matches either
    /// case), from the top of the history down, at most [`MAX_MATCHES`].
    pub fn search(&self, query: &str) -> Vec<Match> {
        if query.is_empty() {
            return vec![];
        }
        let Ok(mut regex) = RegexSearch::new(&escape_regex(query)) else {
            return vec![];
        };
        let term = self.term.lock();
        let start = Point::new(term.topmost_line(), Column(0));
        let end = Point::new(term.bottommost_line(), term.last_column());
        RegexIter::new(start, end, Direction::Right, &term, &mut regex)
            .take(MAX_MATCHES)
            .collect()
    }

    /// Scrolls so `point` is on screen.
    pub fn reveal(&self, point: GridPoint) {
        self.term.lock().scroll_to_point(point);
        self.dirty.store(true, Ordering::Release);
    }

    /// Copies what is on screen, colours resolved against `palette`, with
    /// `matches` marked and `current` (an index into them) singled out.
    pub fn frame(&self, palette: &Palette, matches: &[Match], current: Option<usize>) -> Frame {
        let term = self.term.lock();
        let content = term.renderable_content();
        let colors = content.colors;
        let offset = content.display_offset;
        let size = GridSize {
            cols: term.columns(),
            rows: term.screen_lines(),
        };
        let top = Line(-(offset as i32));
        let bottom = Line(size.rows as i32 - 1 - offset as i32);
        // Only the matches on screen are worth testing cell by cell.
        let visible: Vec<(usize, &Match)> = matches
            .iter()
            .enumerate()
            .filter(|(_, m)| m.end().line >= top && m.start().line <= bottom)
            .collect();
        let named = |n: NamedColor, fallback: Rgb| colors[n].unwrap_or(fallback);
        let resolve = |color: Color| -> Rgb {
            match color {
                Color::Spec(rgb) => rgb,
                Color::Indexed(i) => colors[i as usize].unwrap_or_else(|| palette.indexed(i)),
                Color::Named(n) => {
                    let i = n as usize;
                    if i < 16 {
                        colors[i].unwrap_or(palette.ansi[i])
                    } else {
                        match n {
                            NamedColor::Background => named(n, palette.background),
                            NamedColor::Cursor => named(n, palette.cursor),
                            NamedColor::DimForeground => dim(
                                named(NamedColor::Foreground, palette.foreground),
                                palette.background,
                            ),
                            NamedColor::DimBlack
                            | NamedColor::DimRed
                            | NamedColor::DimGreen
                            | NamedColor::DimYellow
                            | NamedColor::DimBlue
                            | NamedColor::DimMagenta
                            | NamedColor::DimCyan
                            | NamedColor::DimWhite => {
                                let base = i - NamedColor::DimBlack as usize;
                                dim(
                                    colors[base].unwrap_or(palette.ansi[base]),
                                    palette.background,
                                )
                            }
                            _ => named(NamedColor::Foreground, palette.foreground),
                        }
                    }
                }
            }
        };
        let background = named(NamedColor::Background, palette.background);
        let mut cells = vec![
            CellView {
                ch: ' ',
                fg: palette.foreground,
                bg: background,
                default_bg: true,
                palette_text: true,
                style: CellStyle::default(),
                zerowidth: 0,
            };
            size.cols * size.rows
        ];
        let mut zerowidth = vec![];
        let mut legible: HashMap<(u32, u32), Rgb> = HashMap::new();
        let selection = content.selection;
        for indexed in content.display_iter {
            let point = indexed.point;
            let row = (point.line.0 + offset as i32) as usize;
            let col = point.column.0;
            if row >= size.rows || col >= size.cols {
                continue;
            }
            let cell = indexed.cell;
            let flags = cell.flags;
            let mut fg = resolve(cell.fg);
            let mut bg = resolve(cell.bg);
            let mut default_bg = matches!(cell.bg, Color::Named(NamedColor::Background));
            if flags.intersects(Flags::DIM | Flags::DIM_BOLD) && !flags.contains(Flags::BOLD) {
                fg = dim(fg, bg);
            }
            if flags.contains(Flags::INVERSE) {
                std::mem::swap(&mut fg, &mut bg);
                default_bg = false;
            }
            let palette_text = !flags.contains(Flags::HIDDEN)
                && from_palette(if flags.contains(Flags::INVERSE) {
                    cell.bg
                } else {
                    cell.fg
                });
            if flags.contains(Flags::HIDDEN) {
                fg = bg;
            } else if palette_text {
                // The palette's text reads at AA on whatever this cell is
                // drawn on; a colour the program gave exactly is its own.
                let key = (rgb_key(fg), rgb_key(bg));
                fg = *legible.entry(key).or_insert_with(|| legible_on(fg, bg));
            }
            let matched = visible
                .iter()
                .find(|(_, m)| m.contains(&point))
                .map(|(i, _)| Some(*i) == current);
            let style = CellStyle {
                bold: flags.contains(Flags::BOLD),
                italic: flags.contains(Flags::ITALIC),
                underline: flags.intersects(Flags::ALL_UNDERLINES),
                strike: flags.contains(Flags::STRIKEOUT),
                wide: flags.contains(Flags::WIDE_CHAR),
                spacer: flags.intersects(Flags::WIDE_CHAR_SPACER | Flags::LEADING_WIDE_CHAR_SPACER),
                selected: selection.is_some_and(|s| s.contains(point)),
                matched: matched.is_some(),
                current: matched == Some(true),
            };
            let extra = match cell.zerowidth() {
                Some(chars) if !chars.is_empty() && zerowidth.len() < u16::MAX as usize - 1 => {
                    zerowidth.push(chars.iter().collect::<String>());
                    zerowidth.len() as u16
                }
                _ => 0,
            };
            cells[row * size.cols + col] = CellView {
                ch: if cell.c == '\t' { ' ' } else { cell.c },
                fg,
                bg,
                default_bg,
                palette_text,
                style,
                zerowidth: extra,
            };
        }
        // A double-width glyph is one thing on screen: its right half
        // carries the left's highlights and background, so both columns are
        // painted alike and its text reads on all it covers.
        for row in cells.chunks_mut(size.cols) {
            for col in 1..row.len() {
                if row[col - 1].style.wide && row[col].style.spacer {
                    let lead = row[col - 1];
                    let spacer = &mut row[col];
                    spacer.bg = lead.bg;
                    spacer.default_bg = lead.default_bg;
                    spacer.style.selected = lead.style.selected;
                    spacer.style.matched = lead.style.matched;
                    spacer.style.current = lead.style.current;
                }
            }
        }
        let cursor = {
            let c = content.cursor;
            let row = c.point.line.0 + offset as i32;
            let visible = c.shape != CursorShape::Hidden
                && content.mode.contains(TermMode::SHOW_CURSOR)
                && row >= 0
                && (row as usize) < size.rows
                && c.point.column.0 < size.cols;
            visible.then(|| {
                let row = row as usize;
                let col = c.point.column.0;
                CursorView {
                    row,
                    col,
                    shape: c.shape,
                    wide: cells[row * size.cols + col].style.wide,
                }
            })
        };
        Frame {
            size,
            cells,
            zerowidth,
            cursor,
            display_offset: offset,
            history: term.grid().history_size(),
            mode: content.mode,
            background,
        }
    }
}

/// `text` as a regular expression that matches it literally.
fn escape_regex(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for c in text.chars() {
        if "\\.+*?()|[]{}^$#&-~".contains(c) {
            out.push('\\');
        }
        out.push(c);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn palette() -> Palette {
        let grey = |v| Rgb { r: v, g: v, b: v };
        let mut ansi = [grey(0); 16];
        ansi[1] = Rgb {
            r: 255,
            g: 96,
            b: 96,
        };
        ansi[2] = Rgb { r: 0, g: 160, b: 0 };
        Palette {
            ansi,
            foreground: grey(220),
            background: grey(0),
            cursor: grey(220),
        }
    }

    fn emulator(cols: usize, rows: usize) -> Emulator {
        Emulator::new(GridSize { cols, rows })
    }

    #[test]
    fn output_lands_in_the_grid() {
        let e = emulator(20, 4);
        e.feed(b"hello\r\nworld");
        let f = e.frame(&palette(), &[], None);
        assert_eq!(f.row_text(0), "hello");
        assert_eq!(f.row_text(1), "world");
        let cursor = f.cursor.unwrap();
        assert_eq!((cursor.row, cursor.col), (1, 5));
    }

    #[test]
    fn colours_resolve_against_the_palette() {
        let e = emulator(20, 2);
        e.feed(b"\x1b[31mred\x1b[0m \x1b[42mbg\x1b[0m \x1b[38;2;1;2;3mrgb\x1b[0m");
        let f = e.frame(&palette(), &[], None);
        let row = f.row(0);
        assert_eq!(
            row[0].fg,
            Rgb {
                r: 255,
                g: 96,
                b: 96
            }
        );
        assert!(row[0].default_bg);
        assert_eq!(row[4].bg, Rgb { r: 0, g: 160, b: 0 });
        assert!(!row[4].default_bg);
        assert_eq!(row[7].fg, Rgb { r: 1, g: 2, b: 3 });
        // 256 colours: the cube and the greys.
        assert_eq!(palette().indexed(196), Rgb { r: 255, g: 0, b: 0 });
        assert_eq!(palette().indexed(232), Rgb { r: 8, g: 8, b: 8 });
    }

    #[test]
    fn styles_and_wide_characters_are_marked() {
        let e = emulator(20, 2);
        e.feed("\x1b[1;3;4mB\x1b[0m界x".as_bytes());
        let f = e.frame(&palette(), &[], None);
        let row = f.row(0);
        assert!(row[0].style.bold && row[0].style.italic && row[0].style.underline);
        assert!(row[1].style.wide);
        assert!(row[2].style.spacer);
        assert_eq!(row[3].ch, 'x');
        assert_eq!(f.row_text(0), "B界x");
    }

    #[test]
    fn resizing_reflows_and_reports_once() {
        let e = emulator(10, 3);
        assert!(e.resize(GridSize { cols: 40, rows: 12 }, (8.0, 17.0)));
        assert!(!e.resize(GridSize { cols: 40, rows: 12 }, (8.0, 17.0)));
        assert_eq!(e.size(), GridSize { cols: 40, rows: 12 });
    }

    #[test]
    fn replies_go_back_to_the_shell() {
        let e = emulator(20, 4);
        let sent = Arc::new(Mutex::new(Vec::<u8>::new()));
        let sink = sent.clone();
        e.set_writer(Some(Box::new(move |b: &[u8]| {
            sink.lock().unwrap().extend_from_slice(b)
        })));
        e.feed(b"ab\x1b[6n");
        assert_eq!(&*sent.lock().unwrap(), b"\x1b[1;3R");
        e.set_writer(None);
        e.feed(b"\x1b[6n");
        assert_eq!(&*sent.lock().unwrap(), b"\x1b[1;3R");
    }

    #[test]
    fn titles_and_copies_wait_as_notes() {
        let e = emulator(20, 2);
        e.feed(b"\x1b]0;Build box\x07\x07");
        assert_eq!(
            e.take_notes(),
            vec![Note::Title(Some("Build box".into())), Note::Bell]
        );
        assert!(e.take_notes().is_empty());
    }

    #[test]
    fn selection_copies_the_text_under_it() {
        let e = emulator(20, 3);
        e.feed(b"first line\r\nsecond");
        e.select_start(e.point_at(0, 6), Side::Left, SelectionType::Simple);
        e.select_to(e.point_at(1, 5), Side::Right);
        assert_eq!(e.selection_text().as_deref(), Some("line\nsecond"));
        let f = e.frame(&palette(), &[], None);
        assert!(f.row(0)[6].style.selected && !f.row(0)[5].style.selected);
        e.clear_selection();
        assert!(e.selection_text().is_none());
        e.select_all();
        assert!(e.selection_text().unwrap().contains("first line"));
    }

    #[test]
    fn find_marks_every_match_and_the_current_one() {
        let e = emulator(30, 3);
        e.feed(b"tide pool, Tide line\r\nlow (tide)");
        let matches = e.search("tide");
        assert_eq!(matches.len(), 3, "lower case matches either case");
        assert_eq!(e.search("Tide").len(), 1);
        assert_eq!(e.search("(tide)").len(), 1, "literal, not a pattern");
        let f = e.frame(&palette(), &matches, Some(1));
        assert!(f.row(0)[0].style.matched && !f.row(0)[0].style.current);
        assert!(f.row(0)[11].style.current);
        assert!(!f.row(0)[5].style.matched);
    }

    #[test]
    fn scrollback_keeps_history_and_find_reaches_it() {
        let e = emulator(10, 3);
        for i in 0..20 {
            e.feed(format!("line {i}\r\n").as_bytes());
        }
        assert!(e.frame(&palette(), &[], None).history > 0);
        let found = e.search("line 2");
        assert!(!found.is_empty());
        e.reveal(*found[0].start());
        let f = e.frame(&palette(), &[], None);
        assert!(f.display_offset > 0);
        assert!(f.text().contains("line 2"));
        e.scroll_to_bottom();
        assert_eq!(e.display_offset(), 0);
        e.clear_scrollback();
        assert_eq!(e.frame(&palette(), &[], None).history, 0);
    }

    #[test]
    fn the_feeder_wakes_the_ui_once_per_change() {
        let e = emulator(10, 2);
        e.take_dirty();
        let mut feeder = e.feeder();
        assert!(feeder.feed(b"a"));
        assert!(!feeder.feed(b"b"), "still dirty: no second wake");
        assert!(e.take_dirty());
        assert!(feeder.feed(b"c"));
    }

    /// A title, a copy or a bell wakes the UI even while the screen waits
    /// to be painted (a console hidden behind Files, or before its first
    /// paint): its notes do not wait for a paint that may not come.
    #[test]
    fn a_note_wakes_the_ui_even_while_the_screen_is_dirty() {
        let e = emulator(10, 2);
        let mut feeder = e.feeder();
        assert!(
            feeder.feed(b"\x1b]2;Tide tables\x07"),
            "a title from a screen never painted woke nothing"
        );
        assert!(
            !feeder.feed(b"plain"),
            "output alone still waits for the paint"
        );
        assert!(feeder.feed(b"\x07"), "a bell while dirty woke nothing");
        assert_eq!(
            e.take_notes(),
            vec![Note::Title(Some("Tide tables".into())), Note::Bell]
        );
    }

    /// A selection over only the left half of a double-width glyph still
    /// highlights the whole glyph: its right half carries the same
    /// highlights and background, so it is painted (and read) alike.
    #[test]
    fn a_wide_glyph_is_highlighted_whole() {
        let e = emulator(20, 2);
        e.feed("\x1b[44m界\x1b[0mx".as_bytes());
        e.select_start(e.point_at(0, 0), Side::Left, SelectionType::Simple);
        e.select_to(e.point_at(0, 0), Side::Right);
        let f = e.frame(&palette(), &[], None);
        let row = f.row(0);
        assert!(row[0].style.wide && row[1].style.spacer, "{:?}", &row[..2]);
        assert!(row[0].style.selected, "the left half is selected");
        assert!(row[1].style.selected, "the right half shares the selection");
        assert_eq!(
            (row[1].bg, row[1].default_bg),
            (row[0].bg, row[0].default_bg)
        );
        assert!(!row[2].style.selected);
    }
}
