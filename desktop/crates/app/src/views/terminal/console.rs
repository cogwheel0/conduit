//! The console: a terminal's screen, drawn cell by cell, and its shell.
//!
//! * [`Console`] owns the [`Emulator`] and the socket ([`TerminalLink`]).
//!   Output is parsed on the socket's thread; the console wakes once per
//!   change and repaints what is on screen.
//! * [`Grid`], the element, measures the monospaced cell, fits the grid to
//!   its bounds (a new size goes to the shell as `resize`), and paints
//!   backgrounds, selection and Find highlights, text runs pinned to the
//!   cell grid, and the cursor. Unchanged rows reuse GPUI's line layouts.
//! * Keys that are not text (Return, arrows, ⌃C, function keys, Option as
//!   Meta) go to the shell from a keystroke interceptor, ahead of the app's
//!   shortcuts; typed and composed text arrives through the console's input
//!   handler, so dead keys and input methods work.

use std::cell::Cell;
use std::ops::Range;
use std::rc::Rc;
use std::time::Duration;

use alacritty_terminal::index::Side;
use alacritty_terminal::selection::SelectionType;
use alacritty_terminal::term::TermMode;
use alacritty_terminal::term::search::Match;
use alacritty_terminal::vte::ansi::{CursorShape, Rgb};
use conduit_components::theme::{
    ConduitTheme, MONO_FONT, composite, contrast_ratio, legible_lightness,
};
use conduit_daemon::http::HttpClient;
use conduit_daemon::terminal::{self as socket, TerminalEnd, TerminalInput, TerminalLink};
use futures::StreamExt as _;
use futures::channel::mpsc;
use gpui_kit::prelude::*;
use gpui_kit::{
    App, Bounds, ClipboardItem, Context, ElementId, ElementInputHandler, Entity,
    EntityInputHandler, EventEmitter, FocusHandle, Focusable, Font, FontStyle, FontWeight,
    GlobalElementId, Hsla, InspectorElementId, LayoutId, MouseButton, MouseDownEvent,
    MouseMoveEvent, MouseUpEvent, Pixels, Point, Rgba, ScrollDelta, ScrollEvent, ShapedLine,
    SharedString, StrikethroughStyle, Style, Task, TextAlign, TextRun, UTF16Selection,
    UnderlineStyle, Window, div, fill, font, point, px, relative, size,
};

use super::emulator::{CellView, Emulator, Frame, GridSize, Note, Palette};
use super::keys::{self, Mods};

/// The console's key context: bindings that belong to the console only.
pub const CONSOLE_CONTEXT: &str = "TerminalConsole";

/// The text size of the console, in points.
pub const FONT_SIZE: f32 = 13.;

/// Space around the grid, in points.
const PADDING: f32 = 8.;

/// Where the console's link stands.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum LinkStatus {
    Disconnected,
    Connecting,
    Connected,
    /// It could not connect, or the server ended it with an error.
    Failed,
}

/// What the console tells its pane.
#[derive(Clone, Debug)]
pub enum ConsoleEvent {
    Status(LinkStatus),
    /// The shell named itself (OSC 0/2), or reset its name.
    Title(Option<String>),
    /// Copy, Paste and Find fed back as text (Copied, Connect to Paste).
    Notice(String),
}

/// Wakes from the socket's thread.
enum Wake {
    Opened,
    Output,
    Closed(TerminalEnd),
}

/// The grid's place on screen, kept from the last paint: what pointer
/// positions are measured against.
#[derive(Clone, Copy, Debug)]
struct Geometry {
    origin: Point<Pixels>,
    cell: gpui_kit::Size<Pixels>,
    size: GridSize,
}

/// Find in the console: the field's text and what it matched.
pub struct Find {
    pub query: String,
    pub matches: Vec<Match>,
    pub current: Option<usize>,
}

pub struct Console {
    emulator: Emulator,
    focus: FocusHandle,
    link: Option<TerminalLink>,
    status: LinkStatus,
    /// Bumped by every connect and disconnect: a late wake from an older
    /// socket is ignored.
    generation: u64,
    /// Text an input method is composing, drawn at the cursor.
    marked: Option<String>,
    pub option_as_meta: bool,
    geometry: Rc<Cell<Option<Geometry>>>,
    /// A drag selects from where the press was.
    selecting: bool,
    /// The mouse button the shell was told is down, when it reports the
    /// mouse.
    reported_button: Option<u8>,
    /// Lines of wheel travel not yet scrolled.
    scroll_rest: f32,
    find: Option<Find>,
    palette: Option<(bool, Palette)>,
    /// Painted frames, for tests and the E2E (the text on screen).
    last_text: Rc<Cell<u64>>,
    _wake: Option<Task<()>>,
}

impl EventEmitter<ConsoleEvent> for Console {}

impl Focusable for Console {
    fn focus_handle(&self, _: &App) -> FocusHandle {
        self.focus.clone()
    }
}

/// `c` as alacritty's RGB.
pub fn to_rgb(c: Hsla) -> Rgb {
    let c = c.to_rgb();
    let byte = |v: f32| (v.clamp(0., 1.) * 255.).round() as u8;
    Rgb {
        r: byte(c.r),
        g: byte(c.g),
        b: byte(c.b),
    }
}

pub fn hsla(c: Rgb) -> Hsla {
    Rgba {
        r: c.r as f32 / 255.,
        g: c.g as f32 / 255.,
        b: c.b as f32 / 255.,
        a: 1.,
    }
    .into()
}

/// WCAG AA (4.5:1), with room for rounding each channel to a byte.
const ANSI_RATIO: f32 = 4.55;

/// `text` as drawn on `bg`: unchanged when it reads at WCAG AA there, else
/// only its lightness moved, toward the end (black or white) that reads
/// better on `bg`, until it does. A yellow stays yellow.
pub fn legible_on(text: Rgb, bg: Rgb) -> Rgb {
    let (fg, back) = (hsla(text), hsla(bg));
    if contrast_ratio(fg, back) >= 4.5 {
        return text;
    }
    let on_light =
        contrast_ratio(gpui_kit::black(), back) >= contrast_ratio(gpui_kit::white(), back);
    to_rgb(legible_lightness(fg, &[back], !on_light, ANSI_RATIO))
}

/// What the console paints over a cell: the selection and Find's colours
/// (translucent, over the cell's own background).
#[derive(Clone, Copy, Debug)]
pub struct Highlights {
    selection: Hsla,
    matched: Hsla,
    current: Hsla,
}

impl Highlights {
    pub fn of(t: &ConduitTheme) -> Self {
        let (matched, current) = crate::views::chat::transcript::find_fills(t);
        Self {
            selection: t.roles.text_selection,
            matched,
            current,
        }
    }

    /// The highlight painted over `c`: the current match, then a match,
    /// then the selection.
    pub fn over(&self, c: &CellView) -> Option<Hsla> {
        if c.style.current {
            Some(self.current)
        } else if c.style.matched {
            Some(self.matched)
        } else if c.style.selected {
            Some(self.selection)
        } else {
            None
        }
    }
}

/// What is actually painted under a cell's text: its highlight, if any,
/// over its own background (the console's for a default cell, which the
/// frame gives as its `bg`).
pub fn painted_background(c: &CellView, highlights: &Highlights) -> Rgb {
    match highlights.over(c) {
        Some(fill) => to_rgb(composite(fill, hsla(c.bg))),
        None => c.bg,
    }
}

/// The fills the grid paints for `frame`, row by row: runs of neighbouring
/// cells of one painted colour ([`painted_background`]), as (row, column,
/// cells, colour). Every cell is covered, the console's own background
/// too, so a background the terminal set (OSC 11) is the one painted, and
/// the colour painted under each cell is the one its text is kept legible
/// on.
pub fn fill_spans(frame: &Frame, highlights: &Highlights) -> Vec<(usize, usize, usize, Rgb)> {
    let mut spans = vec![];
    for row in 0..frame.size.rows {
        let cells = frame.row(row);
        let mut col = 0;
        while col < cells.len() {
            let here = painted_background(&cells[col], highlights);
            let mut end = col + 1;
            while end < cells.len() && painted_background(&cells[end], highlights) == here {
                end += 1;
            }
            spans.push((row, col, end - col, here));
            col = end;
        }
    }
    spans
}

/// The colour a cell's text is painted in: palette text kept at AA on what
/// is painted under it ([`painted_background`]); a colour the program gave
/// exactly, or hidden text, as the frame has it. Without a highlight this
/// is the frame's colour, already at AA on the cell's background.
pub fn cell_text(c: &CellView, highlights: &Highlights) -> Rgb {
    if c.palette_text {
        legible_on(c.fg, painted_background(c, highlights))
    } else {
        c.fg
    }
}

/// The terminal's colours for the window's theme: its text and content
/// colours for the defaults, and ANSI colours tuned to sit on them.
pub fn palette(t: &ConduitTheme) -> Palette {
    let hex = |v: u32| Rgb {
        r: (v >> 16) as u8,
        g: (v >> 8) as u8,
        b: v as u8,
    };
    let ansi = if t.dark {
        [
            0x48484a, 0xff6b63, 0x4fd16c, 0xf2c94c, 0x5ea8ff, 0xd28cf5, 0x5fd0e6, 0xd1d1d6,
            0x8e8e93, 0xff8f88, 0x7ee38f, 0xffdd7a, 0x8fc2ff, 0xe3b1ff, 0x93e3f2, 0xffffff,
        ]
    } else {
        [
            0x1d1d1f, 0xc4262e, 0x1d7f3a, 0x946200, 0x0a55b0, 0x8250c8, 0x167a85, 0x6e6e73,
            0x5a5a5f, 0xe0393f, 0x2a9e4c, 0xb57a00, 0x1a6fd6, 0xa16ae8, 0x2193a0, 0x3a3a3c,
        ]
    };
    // These are cell backgrounds as well as text: the text is kept legible
    // cell by cell, on the background it is drawn on ([`legible_on`]).
    let ansi = ansi.map(hex);
    Palette {
        ansi,
        foreground: to_rgb(t.roles.text),
        background: to_rgb(t.roles.content),
        cursor: to_rgb(t.roles.text),
    }
}

impl Console {
    pub fn new(cx: &mut Context<Self>) -> Self {
        // A stop for Tab, as a text view is; inside, Tab is the shell's.
        let focus = cx.focus_handle().tab_stop(true);
        Self {
            emulator: Emulator::new(GridSize { cols: 80, rows: 24 }),
            focus,
            link: None,
            status: LinkStatus::Disconnected,
            generation: 0,
            marked: None,
            option_as_meta: false,
            geometry: Rc::new(Cell::new(None)),
            selecting: false,
            reported_button: None,
            scroll_rest: 0.,
            find: None,
            palette: None,
            last_text: Rc::new(Cell::new(0)),
            _wake: None,
        }
    }

    pub fn status(&self) -> &LinkStatus {
        &self.status
    }

    pub fn emulator(&self) -> &Emulator {
        &self.emulator
    }

    pub fn find(&self) -> Option<&Find> {
        self.find.as_ref()
    }

    /// Frames painted so far.
    pub fn painted(&self) -> u64 {
        self.last_text.get()
    }

    fn set_status(&mut self, status: LinkStatus, cx: &mut Context<Self>) {
        if self.status != status {
            self.status = status.clone();
            cx.emit(ConsoleEvent::Status(status));
            cx.notify();
        }
    }

    /// Opens `handle`'s shell through `http`. A shell already open closes
    /// first.
    pub fn connect(&mut self, http: &HttpClient, handle: &str, cx: &mut Context<Self>) {
        self.close_link();
        self.generation += 1;
        let generation = self.generation;
        self.set_status(LinkStatus::Connecting, cx);
        let (tx, mut rx) = mpsc::unbounded::<Wake>();
        let mut feeder = self.emulator.feeder();
        let size = self.emulator.size();
        let (opened, output, closed) = (tx.clone(), tx.clone(), tx);
        let link = socket::spawn(
            http,
            handle,
            vec![TerminalInput::Resize {
                cols: size.cols as u16,
                rows: size.rows as u16,
            }],
            move || {
                let _ = opened.unbounded_send(Wake::Opened);
            },
            move |bytes| {
                if feeder.feed(bytes) {
                    let _ = output.unbounded_send(Wake::Output);
                }
            },
            move |end| {
                let _ = closed.unbounded_send(Wake::Closed(end));
            },
        );
        let writer = link.clone();
        self.emulator.set_writer(Some(Box::new(move |bytes: &[u8]| {
            writer.send(TerminalInput::Bytes(bytes.to_vec()));
        })));
        self.link = Some(link);
        self._wake = Some(cx.spawn(async move |this, cx| {
            while let Some(wake) = rx.next().await {
                let alive = this
                    .update(cx, |c, cx| c.on_wake(generation, wake, cx))
                    .is_ok();
                if !alive {
                    break;
                }
            }
        }));
    }

    fn close_link(&mut self) {
        self.emulator.set_writer(None);
        if let Some(link) = self.link.take() {
            link.close();
        }
    }

    /// Disconnect: the session ends, with a line saying so.
    pub fn disconnect(&mut self, label: &str, cx: &mut Context<Self>) {
        if self.link.is_none() {
            return;
        }
        self.generation += 1;
        self.close_link();
        self.emulator.feed(format!("\r\n[{label}]\r\n").as_bytes());
        self.set_status(LinkStatus::Disconnected, cx);
        cx.notify();
    }

    fn on_wake(&mut self, generation: u64, wake: Wake, cx: &mut Context<Self>) {
        if generation != self.generation {
            return;
        }
        match wake {
            Wake::Opened => self.set_status(LinkStatus::Connected, cx),
            Wake::Output => {
                for note in self.emulator.take_notes() {
                    match note {
                        Note::Title(title) => cx.emit(ConsoleEvent::Title(title)),
                        Note::Copy(text) => cx.write_to_clipboard(ClipboardItem::new_string(text)),
                        Note::Bell => {}
                    }
                }
                if self.find.is_some() {
                    self.research(false);
                }
                cx.notify();
            }
            Wake::Closed(end) => {
                self.emulator.set_writer(None);
                self.link = None;
                let failed = match &end {
                    TerminalEnd::Refused(_) => true,
                    // 4xxx: the daemon or the terminal refused the session.
                    TerminalEnd::Closed(Some(code)) => (4000..5000).contains(code),
                    TerminalEnd::Closed(None) | TerminalEnd::Dropped => false,
                };
                log::info!("terminal: closed ({end:?})");
                self.set_status(
                    if failed {
                        LinkStatus::Failed
                    } else {
                        LinkStatus::Disconnected
                    },
                    cx,
                );
                cx.notify();
            }
        }
    }

    /// Sends `bytes` to the shell, scrolled to the bottom as a terminal
    /// does when typed into. False while there is no shell.
    pub fn send(&mut self, bytes: Vec<u8>, cx: &mut Context<Self>) -> bool {
        let Some(link) = &self.link else {
            return false;
        };
        self.emulator.scroll_to_bottom();
        self.emulator.clear_selection();
        let sent = link.send(TerminalInput::Bytes(bytes));
        cx.notify();
        sent
    }

    /// Types `text` as if from the keyboard (E2E and the input handler).
    pub fn type_text(&mut self, text: &str, cx: &mut Context<Self>) -> bool {
        self.send(text.as_bytes().to_vec(), cx)
    }

    /// Fits the grid to `size`, telling the shell. Called from paint.
    fn fit(&mut self, size: GridSize, cell: (f32, f32)) {
        if self.emulator.resize(size, cell)
            && let Some(link) = &self.link
        {
            let size = self.emulator.size();
            link.send(TerminalInput::Resize {
                cols: size.cols as u16,
                rows: size.rows as u16,
            });
        }
    }

    /// A keystroke for the shell, if it is one: true when it was taken.
    pub fn key(&mut self, keystroke: &gpui_kit::Keystroke, cx: &mut Context<Self>) -> bool {
        if self.marked.is_some() {
            // An input method is composing: its keys are its own.
            return false;
        }
        let m = keystroke.modifiers;
        let mods = Mods {
            control: m.control,
            alt: m.alt,
            shift: m.shift,
            command: m.platform,
        };
        let mode = self.emulator.mode();
        let Some(bytes) = keys::keystroke_bytes(&keystroke.key, mods, mode, self.option_as_meta)
        else {
            return false;
        };
        if self.link.is_none() {
            // Nothing listens; the key still belongs to the console.
            return true;
        }
        self.send(bytes, cx);
        true
    }

    pub fn copy(&mut self, cx: &mut Context<Self>) -> bool {
        match self.emulator.selection_text() {
            Some(text) => {
                cx.write_to_clipboard(ClipboardItem::new_string(text));
                true
            }
            None => false,
        }
    }

    pub fn paste_text(&mut self, text: &str, cx: &mut Context<Self>) -> bool {
        let bytes = keys::paste_bytes(text, self.emulator.mode());
        self.send(bytes, cx)
    }

    pub fn paste(&mut self, cx: &mut Context<Self>) -> bool {
        let Some(text) = cx.read_from_clipboard().and_then(|c| c.text()) else {
            return false;
        };
        self.paste_text(&text, cx)
    }

    pub fn select_all(&mut self, cx: &mut Context<Self>) {
        self.emulator.select_all();
        cx.notify();
    }

    pub fn clear_scrollback(&mut self, cx: &mut Context<Self>) {
        self.emulator.clear_scrollback();
        cx.notify();
    }

    // ── Find ────────────────────────────────────────────────────────────

    pub fn set_find(&mut self, query: Option<String>, cx: &mut Context<Self>) {
        match query {
            None => self.find = None,
            Some(query) => {
                self.find = Some(Find {
                    query,
                    matches: vec![],
                    current: None,
                });
                self.research(true);
            }
        }
        cx.notify();
    }

    /// Searches again: on new output, or for a new query (`reveal` scrolls
    /// to the match nearest the bottom).
    fn research(&mut self, reveal: bool) {
        let Some(find) = &mut self.find else {
            return;
        };
        let current = find.current.and_then(|i| find.matches.get(i).cloned());
        find.matches = self.emulator.search(&find.query);
        find.current = match current {
            Some(old) => find.matches.iter().position(|m| m.start() == old.start()),
            None => None,
        }
        .or_else(|| find.matches.len().checked_sub(1));
        if reveal && let Some(m) = find.current.and_then(|i| find.matches.get(i)) {
            self.emulator.reveal(*m.start());
        }
    }

    /// Find Next (down the screen) or Previous, wrapping.
    pub fn find_step(&mut self, forward: bool, cx: &mut Context<Self>) {
        let Some(find) = &mut self.find else {
            return;
        };
        let n = find.matches.len();
        if n == 0 {
            return;
        }
        let i = match find.current {
            None => 0,
            Some(i) if forward => (i + 1) % n,
            Some(i) => (i + n - 1) % n,
        };
        find.current = Some(i);
        let start = *find.matches[i].start();
        self.emulator.reveal(start);
        cx.notify();
    }

    // ── Pointer ─────────────────────────────────────────────────────────

    /// The cell under `position`, and which half of it.
    fn cell_at(&self, position: Point<Pixels>) -> Option<(usize, usize, Side)> {
        let g = self.geometry.get()?;
        let x = (position.x - g.origin.x) / g.cell.width;
        let y = (position.y - g.origin.y) / g.cell.height;
        let col = x.floor().clamp(0., g.size.cols as f32 - 1.) as usize;
        let row = y.floor().clamp(0., g.size.rows as f32 - 1.) as usize;
        let side = if x - x.floor() < 0.5 {
            Side::Left
        } else {
            Side::Right
        };
        Some((row, col, side))
    }

    /// Whether the shell reads the mouse itself (and Shift does not ask
    /// for a selection instead).
    fn reports_mouse(&self, shift: bool) -> bool {
        !shift && self.emulator.mode().intersects(TermMode::MOUSE_MODE)
    }

    fn report(
        &mut self,
        button: u8,
        pressed: bool,
        row: usize,
        col: usize,
        mods: Mods,
        cx: &mut Context<Self>,
    ) {
        let mode = self.emulator.mode();
        if let Some(bytes) = keys::mouse_report(button, pressed, col, row, mods, mode)
            && let Some(link) = &self.link
        {
            link.send(TerminalInput::Bytes(bytes));
            cx.notify();
        }
    }

    fn mouse_down(&mut self, e: &MouseDownEvent, window: &mut Window, cx: &mut Context<Self>) {
        window.focus(&self.focus, cx);
        let Some((row, col, side)) = self.cell_at(e.position) else {
            return;
        };
        let mods = Mods {
            control: e.modifiers.control,
            alt: e.modifiers.alt,
            shift: e.modifiers.shift,
            command: e.modifiers.platform,
        };
        if self.reports_mouse(e.modifiers.shift) && e.button == MouseButton::Left {
            self.reported_button = Some(0);
            self.report(0, true, row, col, mods, cx);
            return;
        }
        if e.button != MouseButton::Left {
            return;
        }
        let point = self.emulator.point_at(row, col);
        if e.modifiers.shift && self.emulator.has_selection() {
            self.emulator.select_to(point, side);
        } else {
            let kind = match e.click_count {
                2 => SelectionType::Semantic,
                n if n >= 3 => SelectionType::Lines,
                _ => SelectionType::Simple,
            };
            self.emulator.select_start(point, side, kind);
        }
        self.selecting = true;
        cx.notify();
    }

    fn mouse_move(&mut self, e: &MouseMoveEvent, cx: &mut Context<Self>) {
        if !self.selecting || e.pressed_button != Some(MouseButton::Left) {
            return;
        }
        if let Some((row, col, side)) = self.cell_at(e.position) {
            let point = self.emulator.point_at(row, col);
            self.emulator.select_to(point, side);
            cx.notify();
        }
    }

    fn mouse_up(&mut self, e: &MouseUpEvent, cx: &mut Context<Self>) {
        if let Some(button) = self.reported_button.take()
            && let Some((row, col, _)) = self.cell_at(e.position)
        {
            let mods = Mods {
                control: e.modifiers.control,
                alt: e.modifiers.alt,
                shift: e.modifiers.shift,
                command: e.modifiers.platform,
            };
            self.report(button, false, row, col, mods, cx);
        }
        if self.selecting {
            self.selecting = false;
            // A click without a drag selects nothing.
            if !self.emulator.has_selection() {
                self.emulator.clear_selection();
            }
            cx.notify();
        }
    }

    fn scroll(&mut self, e: &ScrollEvent, cx: &mut Context<Self>) {
        let Some(g) = self.geometry.get() else {
            return;
        };
        let lines = match e.delta {
            ScrollDelta::Lines(d) => d.y,
            ScrollDelta::Pixels(d) => d.y / g.cell.height,
        };
        self.scroll_rest += lines;
        let whole = self.scroll_rest.trunc() as i32;
        if whole == 0 {
            return;
        }
        self.scroll_rest -= whole as f32;
        let mode = self.emulator.mode();
        if self.reports_mouse(e.modifiers.shift) {
            if let Some((row, col, _)) = self.cell_at(e.position) {
                let button = if whole > 0 { 64 } else { 65 };
                for _ in 0..whole.unsigned_abs().min(10) {
                    self.report(button, true, row, col, Mods::default(), cx);
                }
            }
            return;
        }
        if mode.contains(TermMode::ALT_SCREEN) && mode.contains(TermMode::ALTERNATE_SCROLL) {
            // A full-screen program without the mouse: the wheel is arrows.
            let arrow = if whole > 0 { "up" } else { "down" };
            if let Some(bytes) = keys::keystroke_bytes(arrow, Mods::default(), mode, false) {
                let bytes = bytes.repeat(whole.unsigned_abs().min(10) as usize);
                if let Some(link) = &self.link {
                    link.send(TerminalInput::Bytes(bytes));
                }
            }
            return;
        }
        self.emulator.scroll(whole);
        cx.notify();
    }

    pub fn focus(&self, window: &mut Window, cx: &mut App) {
        window.focus(&self.focus, cx);
    }

    pub fn is_focused(&self, window: &Window) -> bool {
        self.focus.is_focused(window)
    }
}

impl Drop for Console {
    fn drop(&mut self) {
        self.close_link();
    }
}

// ── Input handler: typed and composed text ───────────────────────────────

impl EntityInputHandler for Console {
    fn text_for_range(
        &mut self,
        range: Range<usize>,
        adjusted: &mut Option<Range<usize>>,
        _: &mut Window,
        _: &mut Context<Self>,
    ) -> Option<String> {
        let marked = self.marked.as_deref().unwrap_or("");
        let units: Vec<u16> = marked.encode_utf16().collect();
        let end = range.end.min(units.len());
        let start = range.start.min(end);
        *adjusted = Some(start..end);
        Some(String::from_utf16_lossy(&units[start..end]))
    }

    fn selected_text_range(
        &mut self,
        _: bool,
        _: &mut Window,
        _: &mut Context<Self>,
    ) -> Option<UTF16Selection> {
        let len = self
            .marked
            .as_deref()
            .map_or(0, |m| m.encode_utf16().count());
        Some(UTF16Selection {
            range: len..len,
            reversed: false,
        })
    }

    fn marked_text_range(&self, _: &mut Window, _: &mut Context<Self>) -> Option<Range<usize>> {
        self.marked.as_deref().map(|m| 0..m.encode_utf16().count())
    }

    fn unmark_text(&mut self, _: &mut Window, cx: &mut Context<Self>) {
        self.marked = None;
        cx.notify();
    }

    fn replace_text_in_range(
        &mut self,
        _: Option<Range<usize>>,
        text: &str,
        _: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.marked = None;
        if !text.is_empty() {
            self.type_text(text, cx);
        }
        cx.notify();
    }

    fn replace_and_mark_text_in_range(
        &mut self,
        _: Option<Range<usize>>,
        text: &str,
        _: Option<Range<usize>>,
        _: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.marked = (!text.is_empty()).then(|| text.to_string());
        cx.notify();
    }

    fn bounds_for_range(
        &mut self,
        _: Range<usize>,
        _: Bounds<Pixels>,
        _: &mut Window,
        _: &mut Context<Self>,
    ) -> Option<Bounds<Pixels>> {
        // The candidate window opens at the cursor.
        let g = self.geometry.get()?;
        let frame_cursor = {
            let palette = self.palette.map(|(_, p)| p)?;
            self.emulator.frame(&palette, &[], None).cursor?
        };
        Some(Bounds::new(
            point(
                g.origin.x + g.cell.width * frame_cursor.col as f32,
                g.origin.y + g.cell.height * frame_cursor.row as f32,
            ),
            g.cell,
        ))
    }

    fn character_index_for_point(
        &mut self,
        _: Point<Pixels>,
        _: &mut Window,
        _: &mut Context<Self>,
    ) -> Option<usize> {
        None
    }
}

// ── The element ──────────────────────────────────────────────────────────

/// One run of same-styled text in a row, from `col`.
struct Run {
    row: usize,
    col: usize,
    line: ShapedLine,
}

/// What paint draws, from prepaint.
pub struct Prepared {
    backgrounds: Vec<(Bounds<Pixels>, Hsla)>,
    runs: Vec<Run>,
    cursor: Option<(Bounds<Pixels>, CursorShape, Option<ShapedLine>)>,
    marked: Option<(Point<Pixels>, ShapedLine, Pixels)>,
    line_height: Pixels,
    origin: Point<Pixels>,
    cell: gpui_kit::Size<Pixels>,
}

/// The console's grid, painted from the emulator's frame.
pub struct Grid {
    console: Entity<Console>,
    palette: Palette,
    focused: bool,
    highlights: Highlights,
    cursor_text: Hsla,
}

impl Grid {
    pub fn new(console: Entity<Console>, t: &ConduitTheme, focused: bool) -> Self {
        Self {
            console,
            palette: palette(t),
            focused,
            highlights: Highlights::of(t),
            cursor_text: t.roles.content,
        }
    }
}

impl IntoElement for Grid {
    type Element = Self;

    fn into_element(self) -> Self::Element {
        self
    }
}

fn cell_font(bold: bool, italic: bool) -> Font {
    let mut f = font(MONO_FONT);
    if bold {
        f.weight = FontWeight::BOLD;
    }
    if italic {
        f.style = FontStyle::Italic;
    }
    f
}

/// Whether two cells can share a text run.
fn same_run(a: &CellView, b: &CellView) -> bool {
    a.fg == b.fg
        && a.style.bold == b.style.bold
        && a.style.italic == b.style.italic
        && a.style.underline == b.style.underline
        && a.style.strike == b.style.strike
        && !a.style.wide
        && !b.style.wide
        && a.zerowidth == 0
        && b.zerowidth == 0
}

impl Element for Grid {
    type RequestLayoutState = ();
    type PrepaintState = Prepared;

    fn id(&self) -> Option<ElementId> {
        None
    }

    fn source_location(&self) -> Option<&'static std::panic::Location<'static>> {
        None
    }

    fn request_layout(
        &mut self,
        _: Option<&GlobalElementId>,
        _: Option<&InspectorElementId>,
        window: &mut Window,
        cx: &mut App,
    ) -> (LayoutId, ()) {
        let mut style = Style::default();
        style.size.width = relative(1.).into();
        style.size.height = relative(1.).into();
        (window.request_layout(style, None, cx), ())
    }

    fn prepaint(
        &mut self,
        _: Option<&GlobalElementId>,
        _: Option<&InspectorElementId>,
        bounds: Bounds<Pixels>,
        _: &mut (),
        window: &mut Window,
        cx: &mut App,
    ) -> Prepared {
        let font_size = px(FONT_SIZE);
        let text = window.text_system().clone();
        let font_id = text.resolve_font(&cell_font(false, false));
        let width = text
            .advance(font_id, font_size, 'm')
            .map(|s| s.width)
            .unwrap_or(px(FONT_SIZE * 0.6));
        let cell = size(width, px((FONT_SIZE * 1.3).round()));
        let origin = point(bounds.origin.x + px(PADDING), bounds.origin.y + px(PADDING));
        let cols = ((bounds.size.width - px(PADDING * 2.)) / cell.width)
            .floor()
            .max(2.) as usize;
        let rows = ((bounds.size.height - px(PADDING * 2.)) / cell.height)
            .floor()
            .max(1.) as usize;
        let palette = self.palette;
        let (frame, marked) = self.console.update(cx, |c, _| {
            c.palette = Some((true, palette));
            c.emulator.set_palette(palette);
            c.fit(
                GridSize { cols, rows },
                (f32::from(cell.width), f32::from(cell.height)),
            );
            c.geometry.set(Some(Geometry {
                origin,
                cell,
                size: c.emulator.size(),
            }));
            c.emulator.take_dirty();
            let (matches, current) = c
                .find
                .as_ref()
                .map_or((&[][..], None), |f| (&f.matches[..], f.current));
            let frame = c.emulator.frame(&palette, matches, current);
            c.last_text.set(c.last_text.get() + 1);
            (frame, c.marked.clone())
        });
        self.layout(&frame, marked, origin, cell, window)
    }

    fn paint(
        &mut self,
        _: Option<&GlobalElementId>,
        _: Option<&InspectorElementId>,
        bounds: Bounds<Pixels>,
        _: &mut (),
        p: &mut Prepared,
        window: &mut Window,
        cx: &mut App,
    ) {
        window.with_content_mask(Some(gpui_kit::ContentMask { bounds }), |window| {
            for (b, color) in &p.backgrounds {
                window.paint_quad(fill(*b, *color));
            }
            for run in &p.runs {
                let at = point(
                    p.origin.x + p.cell.width * run.col as f32,
                    p.origin.y + p.cell.height * run.row as f32,
                );
                let _ = run
                    .line
                    .paint(at, p.line_height, TextAlign::Left, None, window, cx);
            }
            if let Some((b, shape, glyph)) = &p.cursor {
                let color = hsla(self.palette.cursor);
                match shape {
                    CursorShape::Block if self.focused => {
                        window.paint_quad(fill(*b, color));
                        if let Some(glyph) = glyph {
                            let _ = glyph.paint(
                                b.origin,
                                p.line_height,
                                TextAlign::Left,
                                None,
                                window,
                                cx,
                            );
                        }
                    }
                    CursorShape::Beam => {
                        window.paint_quad(fill(
                            Bounds::new(b.origin, size(px(2.), b.size.height)),
                            color,
                        ));
                    }
                    CursorShape::Underline => {
                        let y = b.origin.y + b.size.height - px(2.);
                        window.paint_quad(fill(
                            Bounds::new(point(b.origin.x, y), size(b.size.width, px(2.))),
                            color,
                        ));
                    }
                    _ => {
                        // Unfocused (or hollow): an outline.
                        window.paint_quad(gpui_kit::outline(
                            *b,
                            color,
                            gpui_kit::BorderStyle::Solid,
                        ));
                    }
                }
            }
            if let Some((at, line, width)) = &p.marked {
                window.paint_quad(fill(
                    Bounds::new(*at, size(*width, p.cell.height)),
                    hsla(self.palette.background),
                ));
                let _ = line.paint(*at, p.line_height, TextAlign::Left, None, window, cx);
            }
        });
        let focus = self.console.read(cx).focus.clone();
        window.handle_input(
            &focus,
            ElementInputHandler::new(bounds, self.console.clone()),
            cx,
        );
    }
}

impl Grid {
    fn layout(
        &self,
        frame: &Frame,
        marked: Option<String>,
        origin: Point<Pixels>,
        cell: gpui_kit::Size<Pixels>,
        window: &mut Window,
    ) -> Prepared {
        let font_size = px(FONT_SIZE);
        let line_height = cell.height;
        let text = window.text_system().clone();
        let cell_rect = |row: usize, col: usize, cols: usize| {
            Bounds::new(
                point(
                    origin.x + cell.width * col as f32,
                    origin.y + cell.height * row as f32,
                ),
                size(cell.width * cols as f32, cell.height),
            )
        };
        // Every cell's fill, as its text's contrast is reckoned against it.
        let backgrounds: Vec<(Bounds<Pixels>, Hsla)> = fill_spans(frame, &self.highlights)
            .into_iter()
            .map(|(row, col, cells, color)| (cell_rect(row, col, cells), hsla(color)))
            .collect();
        let mut runs = vec![];
        let cols = frame.size.cols;
        for row in 0..frame.size.rows {
            let cells = frame.row(row);
            // Text runs, pinned to the grid, each in its colour on what is
            // painted under it.
            let text_of = |c: &CellView| cell_text(c, &self.highlights);
            let mut col = 0;
            while col < cols {
                let first = &cells[col];
                if first.style.spacer {
                    col += 1;
                    continue;
                }
                let mut s = String::new();
                let mut end = col;
                while end < cols {
                    let c = &cells[end];
                    if c.style.spacer {
                        end += 1;
                        continue;
                    }
                    if end > col && (!same_run(first, c) || text_of(c) != text_of(first)) {
                        break;
                    }
                    s.push(c.ch);
                    if c.zerowidth > 0 {
                        s.push_str(&frame.zerowidth[c.zerowidth as usize - 1]);
                    }
                    end += if c.style.wide { 2 } else { 1 };
                    if first.style.wide || c.zerowidth > 0 {
                        break;
                    }
                }
                let blank = s.trim().is_empty() && !first.style.underline && !first.style.strike;
                if !blank {
                    let color = hsla(text_of(first));
                    let run = TextRun {
                        len: s.len(),
                        font: cell_font(first.style.bold, first.style.italic),
                        color,
                        background_color: None,
                        underline: first.style.underline.then_some(UnderlineStyle {
                            thickness: px(1.),
                            color: Some(color),
                            wavy: false,
                        }),
                        strikethrough: first.style.strike.then_some(StrikethroughStyle {
                            thickness: px(1.),
                            color: Some(color),
                        }),
                    };
                    let force = (!first.style.wide).then_some(cell.width);
                    let line = text.shape_line(SharedString::from(s), font_size, &[run], force);
                    runs.push(Run { row, col, line });
                }
                col = end.max(col + 1);
            }
        }
        let cursor = frame.cursor.map(|c| {
            let width = if c.wide { 2 } else { 1 };
            let bounds = cell_rect(c.row, c.col, width);
            let under = frame.row(c.row)[c.col];
            let glyph = (under.ch != ' ').then(|| {
                let run = TextRun {
                    len: under.ch.len_utf8(),
                    font: cell_font(under.style.bold, under.style.italic),
                    color: self.cursor_text,
                    background_color: None,
                    underline: None,
                    strikethrough: None,
                };
                text.shape_line(
                    SharedString::from(under.ch.to_string()),
                    font_size,
                    &[run],
                    Some(cell.width),
                )
            });
            (bounds, c.shape, glyph)
        });
        let marked = marked.and_then(|m| {
            let c = frame.cursor?;
            let at = cell_rect(c.row, c.col, 1).origin;
            let run = TextRun {
                len: m.len(),
                font: cell_font(false, false),
                color: hsla(self.palette.foreground),
                background_color: None,
                underline: Some(UnderlineStyle {
                    thickness: px(1.),
                    color: Some(hsla(self.palette.foreground)),
                    wavy: false,
                }),
                strikethrough: None,
            };
            let line = text.shape_line(SharedString::from(m), font_size, &[run], None);
            let width = line.width;
            Some((at, line, width))
        });
        Prepared {
            backgrounds,
            runs,
            cursor,
            marked,
            line_height,
            origin,
            cell,
        }
    }
}

/// Edit › Clear Scrollback, and the console's menu item.
#[derive(Clone, Debug, PartialEq, gpui_kit::Action)]
#[action(namespace = conduit_terminal, no_json)]
pub struct ClearScrollback;

/// The console's menu (a right click): Copy, Paste, Select All, Clear
/// Scrollback, Find.
fn context_menu(
    console: &Entity<Console>,
    position: Point<Pixels>,
    window: &mut Window,
    cx: &mut App,
) {
    use crate::l10n::ActiveL10n as _;
    use gpui_kit::component::input::{Copy, Paste, SelectAll};
    let l = cx.l10n().clone();
    let c = console.read(cx);
    let selected = c.emulator.has_selection();
    let connected = c.link.is_some();
    window.focus(&c.focus.clone(), cx);
    gpui_kit::component::native_menu::NativeMenu::new()
        .menu_with_disabled(l.copy(), !selected, Box::new(Copy))
        .menu_with_disabled(l.terminal_paste_action(), !connected, Box::new(Paste))
        .menu(l.desktop_menu_select_all(), Box::new(SelectAll))
        .separator()
        .menu(
            l.desktop_terminal_clear_scrollback(),
            Box::new(ClearScrollback),
        )
        .separator()
        .menu(l.desktop_menu_find(), Box::new(crate::actions::FindInChat))
        .show(position, window, cx);
}

/// The chords that leave the console, whose Tab is the shell's: Go › Move
/// Focus to Next Area and Previous Area, as menus write them (⌥⌘`, ⌥⌘~).
pub fn leave_keys() -> (String, String) {
    use crate::keymap::{FixedCommand, describe, fixed_stroke};
    let mac = cfg!(target_os = "macos");
    (
        describe(&fixed_stroke(FixedCommand::NextArea), mac),
        describe(&fixed_stroke(FixedCommand::PreviousArea), mac),
    )
}

/// The console as an element: the grid, with the pointer and keys wired to
/// `console`.
pub fn view(
    console: &Entity<Console>,
    t: &ConduitTheme,
    window: &Window,
    cx: &App,
) -> impl IntoElement {
    let focused = console.read(cx).focus.is_focused(window);
    let focus = console.read(cx).focus.clone();
    let down = console.clone();
    let moved = console.clone();
    let up = console.clone();
    let wheel = console.clone();
    use crate::l10n::ActiveL10n as _;
    let label = cx.l10n().terminal();
    // VoiceOver's help on it: Tab is the shell's here, so which keys leave.
    let (next, previous) = leave_keys();
    let help = cx.l10n().desktop_terminal_keys_help(&next, &previous);
    div()
        .id("terminal-console")
        .role(gpui_kit::Role::Terminal)
        .aria_label(SharedString::from(label))
        .aria_description(SharedString::from(help))
        .key_context(CONSOLE_CONTEXT)
        .track_focus(&focus)
        .size_full()
        .bg(t.roles.content)
        .cursor(gpui_kit::CursorStyle::IBeam)
        .on_mouse_down(MouseButton::Left, move |e, window, cx| {
            down.update(cx, |c, cx| c.mouse_down(e, window, cx));
        })
        .on_mouse_move(move |e, _, cx| moved.update(cx, |c, cx| c.mouse_move(e, cx)))
        .on_mouse_up(MouseButton::Left, move |e, _, cx| {
            up.update(cx, |c, cx| c.mouse_up(e, cx))
        })
        .on_scroll(move |e, _, cx| wheel.update(cx, |c, cx| c.scroll(e, cx)))
        .on_mouse_down(MouseButton::Right, {
            let console = console.clone();
            move |e: &MouseDownEvent, window, cx| context_menu(&console, e.position, window, cx)
        })
        .on_action({
            let console = console.clone();
            move |_: &gpui_kit::component::input::Copy, _, cx| {
                console.update(cx, |c, cx| {
                    c.copy(cx);
                });
            }
        })
        .on_action({
            let console = console.clone();
            move |_: &gpui_kit::component::input::Paste, _, cx| {
                console.update(cx, |c, cx| {
                    let pasted = c.paste(cx);
                    if !pasted && c.link.is_none() {
                        use crate::l10n::ActiveL10n as _;
                        let text = cx.l10n().terminal_paste_while_disconnected();
                        cx.emit(ConsoleEvent::Notice(text));
                    }
                });
            }
        })
        .on_action({
            let console = console.clone();
            move |_: &gpui_kit::component::input::SelectAll, _, cx| {
                console.update(cx, |c, cx| c.select_all(cx));
            }
        })
        .on_action({
            let console = console.clone();
            move |_: &ClearScrollback, _, cx| {
                console.update(cx, |c, cx| c.clear_scrollback(cx));
            }
        })
        .child(Grid::new(console.clone(), t, focused))
}

/// How long a console waits before taking a burst of output as finished,
/// for the E2E's "the output arrived" checks.
pub const SETTLE: Duration = Duration::from_millis(150);

#[cfg(test)]
mod contrast_tests {
    use conduit_components::theme::{ConduitTheme, DesignPrefs, contrast_ratio};

    use super::super::emulator::{Emulator, GridSize};
    use super::*;

    /// Text in every ANSI colour reads at WCAG AA (4.5:1) on what is
    /// painted under it: every background a cell can have (the console's
    /// own, and each ANSI colour set as a cell background, black on bright
    /// green among them), and each of those under the selection, a Find
    /// match and the current match. In light and dark, in every palette,
    /// as the console paints the cell.
    #[test]
    fn ansi_text_meets_wcag_aa_on_every_cell_background() {
        let backgrounds: Vec<(String, String)> = std::iter::once(("default".into(), "49".into()))
            .chain((0..16).map(|b| {
                let code = if b < 8 { 40 + b } else { 100 + b - 8 };
                (format!("ANSI {b}"), code.to_string())
            }))
            .collect();
        let mut low = vec![];
        let ids: Vec<&str> = conduit_components::theme::palettes().ids().collect();
        assert!(ids.len() > 1, "{ids:?}");
        for (id, dark) in ids.iter().flat_map(|id| [(*id, false), (*id, true)]) {
            let t = ConduitTheme::new(id, dark, DesignPrefs::default(), gpui_kit::black());
            let p = palette(&t);
            let h = Highlights::of(&t);
            let fg = contrast_ratio(hsla(p.foreground), hsla(p.background));
            assert!(fg >= 4.5, "{id} dark={dark}: foreground {fg:.2}");
            let e = Emulator::new(GridSize {
                cols: 20,
                rows: backgrounds.len() + 1,
            });
            for (row, (_, bg)) in backgrounds.iter().enumerate() {
                for f in 0..16 {
                    let fg = if f < 8 { 30 + f } else { 90 + f - 8 };
                    e.feed(format!("\x1b[{};{}H\x1b[0;{fg};{bg}mX", row + 1, f + 1).as_bytes());
                }
            }
            let mut check = |cell: &CellView, case: &str, f: usize, name: &str| {
                let (text, under) = (cell_text(cell, &h), painted_background(cell, &h));
                let r = contrast_ratio(hsla(text), hsla(under));
                if r < 4.5 {
                    low.push(format!(
                        "{id} dark={dark}: ANSI {f} on {name}{case}: {text:?} on {under:?} is {r:.2}:1"
                    ));
                }
            };
            let frame = e.frame(&p, &[], None);
            for (row, (name, _)) in backgrounds.iter().enumerate() {
                for (f, cell) in frame.row(row).iter().take(16).enumerate() {
                    check(cell, "", f, name);
                    for (case, mark) in [
                        (", selected", 0),
                        (", a Find match", 1),
                        (", the current match", 2),
                    ] {
                        let mut c = *cell;
                        c.style.selected = mark == 0;
                        c.style.matched = mark >= 1;
                        c.style.current = mark == 2;
                        check(&c, case, f, name);
                    }
                }
            }
            // What the grid paints under each cell is what its text was
            // kept legible on: one fill per cell, neighbours merged only
            // when their fills are equal (a selection over a black cell
            // and a white one paints each its own).
            let mixed = Emulator::new(GridSize { cols: 8, rows: 2 });
            mixed.feed(b"\x1b[0;37;40mA\x1b[0;30;47mB\x1b[0;31;40mC\x1b[0;32;47mD\x1b[0mE");
            mixed.select_all();
            let painted = |frame: &Frame, label: &str, low: &mut Vec<String>| {
                for (row, col, cells, color) in fill_spans(frame, &h) {
                    for at in col..col + cells {
                        let cell = frame.row(row)[at];
                        if painted_background(&cell, &h) != color {
                            low.push(format!("{id} dark={dark}: {label} ({row}, {at}) painted {color:?}, reckoned {:?}", painted_background(&cell, &h)));
                        }
                        let r = contrast_ratio(hsla(cell_text(&cell, &h)), hsla(color));
                        if cell.ch != ' ' && r < 4.5 {
                            low.push(format!("{id} dark={dark}: {label} ({row}, {at}) text on its fill is {r:.2}:1"));
                        }
                    }
                }
                let covered: usize = fill_spans(frame, &h).iter().map(|s| s.2).sum();
                if covered != frame.size.cols * frame.size.rows {
                    low.push(format!(
                        "{id} dark={dark}: {label} fills cover {covered} cells"
                    ));
                }
            };
            let mut fills_low = vec![];
            painted(
                &mixed.frame(&p, &[], None),
                "selected mixed cells",
                &mut fills_low,
            );
            // A background the terminal sets (OSC 11) is the one painted
            // and reckoned against, under Find's highlight too.
            let set = Emulator::new(GridSize { cols: 8, rows: 2 });
            set.feed(b"\x1b]11;rgb:66/66/66\x1b\\found");
            let found_matches = set.search("found");
            let frame = set.frame(&p, &found_matches, Some(0));
            assert_eq!(
                frame.background,
                Rgb {
                    r: 0x66,
                    g: 0x66,
                    b: 0x66
                },
                "{id} dark={dark}"
            );
            painted(&frame, "OSC 11 background, found", &mut fills_low);
            // The emulator marks them so: Find's matches, the current one,
            // and a selection over everything.
            let matches = e.search("x");
            assert_eq!(matches.len(), 16 * backgrounds.len(), "{id} dark={dark}");
            e.select_all();
            let found = e.frame(&p, &matches, Some(0));
            let first = found.row(0)[0].style;
            assert!(
                first.current && first.matched && first.selected,
                "{first:?}"
            );
            for (row, (name, _)) in backgrounds.iter().enumerate() {
                for (f, cell) in found.row(row).iter().take(16).enumerate() {
                    assert!(
                        cell.style.matched,
                        "{id}: ANSI {f} on {name} not marked found"
                    );
                    check(cell, ", found and selected", f, name);
                }
            }
            low.extend(fills_low);
        }
        assert!(low.is_empty(), "{low:#?}");
    }
}
