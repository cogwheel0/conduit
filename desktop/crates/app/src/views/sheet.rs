//! Window sheets on the main window: Chat Settings, Tool Settings, Folder
//! Settings and Share Folder, as a Mac app presents a form about the thing
//! in front of it (Mail's rules, Calendar's Get Info for a calendar).
//!
//! A sheet is a window of its own, opened hidden and hung from the main
//! window with AppKit's `beginSheet:` (Add Account does the same on
//! Settings). It is window-modal: the main window waits, the sheet has the
//! keyboard. Esc, ⌘. and ⌘W go to the body's [`SheetBody::cancel`], which
//! asks before throwing edits away. The window follows the body's height,
//! up to what fits under the main window's title bar, and scrolls beyond
//! that. One sheet at a time, as AppKit allows one per window: the chat's
//! own sheets (Branches, Share Chat, in [`crate::views::chat::sheets`]) are
//! registered here too, so no sheet is ever begun under another.

use std::cell::Cell;
use std::rc::Rc;

use conduit_components::ActiveConduitTheme as _;
use conduit_components::theme::ui_font;
use conduit_components::views::kit::grouped_tones;
use gpui_kit::prelude::*;
use gpui_kit::{
    AnyElement, AnyEntity, AnyWindowHandle, App, Bounds, Context, Entity, FocusHandle, Focusable,
    Global, Pixels, Role, SharedString, Subscription, Task, Window, WindowBackgroundAppearance,
    WindowBounds, WindowKind, WindowOptions, div, point, px, size,
};

use crate::actions::CloseWindow;

/// The body's inset from the sheet's edges.
pub const PADDING: f32 = 20.;
/// What a sheet opens at, before its first frame measures the body.
const FIRST_HEIGHT: f32 = 360.;
/// The least room left under the sheet in the main window.
const PARENT_MARGIN: f32 = 40.;
/// A sheet's top below its parent's, off the Mac: under the parent's
/// toolbar, where a Mac sheet hangs.
const BELOW_PARENT_TOP: f32 = conduit_components::window::TOOLBAR_HEIGHT;
/// The least a sheet may be fitted to, however small its parent.
const LEAST_ROOM: f32 = 240.;

/// What a sheet shows.
pub trait SheetBody: Render + Sized + 'static {
    /// Esc, ⌘. and ⌘W: close, unless the body asks first (unsaved edits).
    fn cancel(&mut self, window: &mut Window, cx: &mut Context<Self>);

    /// What VoiceOver calls the sheet ("Chat Settings").
    fn label(&self, cx: &App) -> SharedString;

    /// Edits not saved yet: Quit asks through [`Self::cancel`] first.
    fn unsaved(&self, cx: &App) -> bool {
        let _ = cx;
        false
    }

    /// A save, test or create is on its way: [`Self::cancel`] does nothing
    /// until it lands, and Quit only beeps (nothing waits for it).
    fn busy(&self, cx: &App) -> bool {
        let _ = cx;
        false
    }

    /// The buttons along the sheet's bottom edge, which stay put while the
    /// body scrolls (as a Mac sheet's).
    fn footer(&mut self, window: &mut Window, cx: &mut Context<Self>) -> Option<AnyElement> {
        let _ = (window, cx);
        None
    }
}

/// The window around a [`SheetBody`].
pub struct SheetHost<V: SheetBody> {
    pub body: Entity<V>,
    focus: FocusHandle,
    /// How tall the sheet may grow off the Mac ([`dialog_room`]).
    room: Option<f32>,
    hang: Hang,
    /// The dialog's title as last set (off the Mac), which follows the
    /// body's label.
    title: Option<SharedString>,
    /// The height last asked of the window, so a request never repeats
    /// while AppKit resizes it.
    requested: Rc<Cell<Option<f32>>>,
    /// The footer's height as last laid out.
    footer_height: Rc<Cell<f32>>,
    /// The body is taller than the sheet: a hairline marks where it
    /// scrolls under the footer.
    overflowing: Rc<Cell<bool>>,
}

/// What runs once a sheet has been dismissed (see [`after_dismiss`]).
type AfterDismiss = Box<dyn FnOnce(&mut App)>;

/// Whether the sheet down now holds unsaved edits, and its body's
/// [`SheetBody::cancel`] (which asks before throwing them away).
#[derive(Clone)]
struct Unsaved {
    edits: BodyState,
    /// [`SheetBody::busy`].
    busy: BodyState,
    ask: Rc<dyn Fn(&mut App)>,
}

/// One of the body's states, read through the sheet.
type BodyState = Rc<dyn Fn(&App) -> bool>;

/// The discard question a Quit asked a sheet with unsaved edits, owned by
/// that sheet ([`ticket`]). It exists only while that question is on
/// screen: Discard closes the sheet and quits, No drops it, and the sheet
/// ending any other way drops it. Nothing else ever waits for a Quit.
///
/// [`ticket`]: PendingQuit::ticket
struct PendingQuit {
    ticket: u64,
    sheet: AnyWindowHandle,
    then: Rc<dyn Fn(&mut App)>,
    /// Its question is up (set as the body shows it).
    shown: bool,
}

/// The sheet on the main window now, if any, and what runs once it has
/// gone.
#[derive(Default)]
struct OpenSheet {
    current: Option<(AnyWindowHandle, AnyEntity)>,
    after: Option<AfterDismiss>,
    unsaved: Option<Unsaved>,
    quit: Option<PendingQuit>,
    /// The last [`PendingQuit::ticket`] given.
    quit_tickets: u64,
    /// Sheets' windows closing are watched (once).
    watching: bool,
}

impl Global for OpenSheet {}

/// How a sheet's window hangs from the window it is about.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Hang {
    /// The Mac: AppKit's `beginSheet:` hangs it from the parent's title bar;
    /// it opens hidden and untitled, and AppKit places and shows it.
    BeginSheet,
    /// Windows and Linux: a modal dialog of its own over the parent
    /// (Windows owns it by the parent and disables the parent while it is
    /// up; X11 marks it transient for the parent, and modal). The OS's
    /// title bar names it to screen readers and has its close button.
    Dialog,
}

impl Hang {
    pub const NATIVE: Self = if cfg!(target_os = "macos") {
        Self::BeginSheet
    } else {
        Self::Dialog
    };
}

/// A sheet window's options: `width` by `height`, titled `title` (off the
/// Mac), over `parent` (its bounds on screen).
pub fn window_options(
    hang: Hang,
    width: f32,
    height: f32,
    title: &str,
    parent: Bounds<Pixels>,
) -> WindowOptions {
    let sheet = WindowOptions {
        window_bounds: Some(WindowBounds::Windowed(Bounds::new(
            point(px(0.), px(0.)),
            size(px(width), px(height)),
        ))),
        titlebar: Some(gpui_kit::TitlebarOptions {
            title: None,
            appears_transparent: true,
            traffic_light_position: None,
        }),
        focus: false,
        show: false,
        kind: WindowKind::Normal,
        is_movable: false,
        is_resizable: false,
        is_minimizable: false,
        window_background: WindowBackgroundAppearance::Opaque,
        window_min_size: None,
        ..Default::default()
    };
    match hang {
        Hang::BeginSheet => sheet,
        Hang::Dialog => WindowOptions {
            window_bounds: Some(WindowBounds::Windowed(Bounds::new(
                point(
                    parent.center().x - px(width / 2.),
                    parent.top() + px(BELOW_PARENT_TOP),
                ),
                size(px(width), px(height)),
            ))),
            titlebar: Some(gpui_kit::TitlebarOptions {
                title: Some(title.to_string().into()),
                appears_transparent: false,
                traffic_light_position: None,
            }),
            focus: true,
            show: true,
            kind: WindowKind::Dialog,
            is_movable: true,
            ..sheet
        },
    }
}

/// How tall a dialog over `parent` may grow (off the Mac): to the
/// parent's bottom, short of it as a Mac sheet stops.
pub fn dialog_room(parent: Bounds<Pixels>) -> f32 {
    (f32::from(parent.size.height) - BELOW_PARENT_TOP - PARENT_MARGIN).max(LEAST_ROOM)
}

/// The height a sheet takes for a body `measured` tall, in `room` (off the
/// Mac; AppKit fits a Mac sheet itself).
pub fn fitted_height(measured: f32, room: Option<f32>) -> f32 {
    room.map_or(measured, |room| measured.min(room))
}

/// Opens a sheet `width` points wide on `parent` (the main window) with the
/// body `build` makes. Another sheet already down keeps the keyboard and
/// this one does not open: None then.
pub fn open<V: SheetBody>(
    parent: &Window,
    width: f32,
    cx: &mut App,
    build: impl FnOnce(&mut Window, &mut Context<V>) -> V + 'static,
) -> Option<Entity<V>> {
    open_on(Hang::NATIVE, parent, width, cx, build)
}

/// [`open`], hung as `hang`.
pub(crate) fn open_on<V: SheetBody>(
    hang: Hang,
    parent: &Window,
    width: f32,
    cx: &mut App,
    build: impl FnOnce(&mut Window, &mut Context<V>) -> V + 'static,
) -> Option<Entity<V>> {
    if refuse_another(cx) {
        return None;
    }
    let over = parent.bounds();
    let room = (hang == Hang::Dialog).then(|| dialog_room(over));
    let opened = conduit_components::window::open_window_clear_root(
        window_options(hang, width, FIRST_HEIGHT, "", over),
        cx,
        move |window, cx| {
            let body = cx.new(|cx| build(window, cx));
            let title = (hang == Hang::Dialog).then(|| {
                let label = body.read(cx).label(cx);
                window.set_window_title(&label);
                label
            });
            let host = cx.new(|cx| SheetHost {
                body,
                focus: cx.focus_handle(),
                room,
                hang,
                title,
                requested: Rc::new(Cell::new(None)),
                footer_height: Rc::new(Cell::new(0.)),
                overflowing: Rc::new(Cell::new(false)),
            });
            // A body that focuses no field of its own leaves the sheet
            // focused, so its keys (Esc) reach it.
            if window.focused(cx).is_none() {
                let focus = host.read(cx).focus.clone();
                window.focus(&focus, cx);
            }
            host
        },
    );
    let (handle, host) = match opened {
        Ok(v) => v,
        Err(e) => {
            log::error!("could not open a sheet: {e}");
            return None;
        }
    };
    let body = host.read(cx).body.clone();
    adopt(handle, body.clone().into_any(), cx);
    let (weak, asked, busy) = (body.downgrade(), body.downgrade(), body.downgrade());
    cx.default_global::<OpenSheet>().unsaved = Some(Unsaved {
        edits: Rc::new(move |cx: &App| weak.upgrade().is_some_and(|b| b.read(cx).unsaved(cx))),
        busy: Rc::new(move |cx: &App| busy.upgrade().is_some_and(|b| b.read(cx).busy(cx))),
        ask: Rc::new(move |cx: &mut App| {
            let Some(body) = asked.upgrade() else { return };
            let _ = handle.update(cx, |_, window, cx| {
                conduit_components::chrome::activate(window, cx);
                body.update(cx, |b, cx| b.cancel(window, cx));
            });
        }),
    });
    begin(parent, handle, cx);
    Some(body)
}

/// A sheet is down already: it keeps the keyboard (brought forward), and
/// another may not open.
pub fn refuse_another(cx: &mut App) -> bool {
    let Some((handle, _)) = cx.default_global::<OpenSheet>().current.clone() else {
        return false;
    };
    cx.defer(move |cx| {
        let _ = handle.update(cx, |_, window, cx| {
            conduit_components::chrome::activate(window, cx)
        });
    });
    true
}

/// Records `handle` (whose view is `body`) as the sheet down now, for a
/// sheet opened outside [`open`].
pub fn adopt(handle: AnyWindowHandle, body: AnyEntity, cx: &mut App) {
    let open = cx.default_global::<OpenSheet>();
    open.current = Some((handle, body));
    open.after = None;
    open.unsaved = None;
    open.quit = None;
    if !std::mem::replace(&mut open.watching, true) {
        // A sheet whose window went some other way (with its parent) is no
        // longer down, and keeps no other from opening.
        cx.on_window_closed(|cx, id| {
            if let Some(gone) = current_window(cx).filter(|h| h.window_id() == id) {
                forget(gone, cx);
            }
        })
        .detach();
    }
    let _ = handle.update(cx, |_, window, cx| {
        window.on_window_should_close(cx, window_manager_closes)
    });
}

/// Hangs the sheet window `handle` from `parent` with `beginSheet:`, once
/// `parent` has no other sheet sliding away.
pub fn begin(parent: &Window, handle: AnyWindowHandle, cx: &mut App) {
    #[cfg(target_os = "macos")]
    {
        let parent = crate::shell::macos::ns_window(parent);
        let sheet = handle
            .update(cx, |_, w, _| crate::shell::macos::ns_window(w))
            .ok()
            .flatten();
        if let (Some(parent), Some(sheet)) = (parent, sheet) {
            // After this update: AppKit calls back into GPUI as the sheet
            // takes the keyboard. A sheet that has only just been dismissed
            // ends a moment later ([`dismiss`] ends it from a task); one
            // begun before then is queued by AppKit and never drawn, so the
            // new one waits for the window to be free (a second at most).
            let executor = cx.background_executor().clone();
            cx.spawn(async move |cx| {
                for _ in 0..60 {
                    if parent.attachedSheet().is_none() {
                        break;
                    }
                    executor.timer(std::time::Duration::from_millis(16)).await;
                }
                // Dismissed while it waited: its window is going, and
                // nothing would end it once hung.
                if cx.update(|cx| current_window(cx)) != Some(handle) {
                    return;
                }
                crate::shell::macos::begin_sheet(&parent, &sheet)
            })
            .detach();
        }
    }
    #[cfg(not(target_os = "macos"))]
    let _ = (parent, handle, cx);
}

/// The window manager asked to close a sheet's window (its × button,
/// Alt+F4): whether it may. That is the sheet's Cancel, as Esc: the body
/// asks first when it holds edits, and the sheet ends its own way, which
/// closes the window. A window no longer the sheet down goes.
pub(crate) fn window_manager_closes(window: &mut Window, cx: &mut App) -> bool {
    let handle = window.window_handle();
    if current_window(cx) != Some(handle) {
        return true;
    }
    // Asked already: that question stays, and keeps the keyboard.
    if crate::shell::sheet::question_up(handle, cx) {
        conduit_components::chrome::activate(window, cx);
        return false;
    }
    match cx.try_global::<OpenSheet>().and_then(|o| o.unsaved.clone()) {
        Some(unsaved) => cx.defer(move |cx| (unsaved.ask)(cx)),
        None => cx.defer(dismiss),
    }
    false
}

/// Forgets `handle` as the sheet down now, when it is: it is being ended
/// some other way ([`crate::views::settings::end_sheet_window`]), and what
/// was to run after it does not.
pub fn forget(handle: AnyWindowHandle, cx: &mut App) {
    let current = cx
        .try_global::<OpenSheet>()
        .and_then(|o| o.current.as_ref().map(|(h, _)| *h));
    if current == Some(handle) {
        let open = cx.global_mut::<OpenSheet>();
        open.current = None;
        open.after = None;
        open.unsaved = None;
        open.quit = None;
    }
}

/// Runs `then` once the sheet down now has been dismissed (saved or
/// cancelled), not when the app quits: Share Chat comes back after Who Has
/// Access, as the phone's share flow returns to its sheet.
pub fn after_dismiss(cx: &mut App, then: impl FnOnce(&mut App) + 'static) {
    let open = cx.default_global::<OpenSheet>();
    if open.current.is_some() {
        open.after = Some(Box::new(then));
    }
}

/// The body of the sheet down now, when it is a `V`.
pub fn current<V: 'static>(cx: &App) -> Option<Entity<V>> {
    cx.try_global::<OpenSheet>()?
        .current
        .as_ref()?
        .1
        .clone()
        .downcast::<V>()
        .ok()
}

/// The window of the sheet down now.
pub fn current_window(cx: &App) -> Option<AnyWindowHandle> {
    cx.try_global::<OpenSheet>()?
        .current
        .as_ref()
        .map(|(h, _)| *h)
}

/// Whether the sheet down now holds edits not saved yet.
pub fn has_unsaved(cx: &App) -> bool {
    cx.try_global::<OpenSheet>()
        .and_then(|s| s.unsaved.clone())
        .is_some_and(|unsaved| (unsaved.edits)(cx))
}

/// The sheet window's keyed state that holds its body's scroll.
const SCROLL_KEY: &str = "sheet-scroll-handle";

/// A scroll of the sheet's body asked for from outside a render.
#[derive(Clone, Copy, Debug, Default)]
struct ScrollRequest(Option<f32>);

impl gpui_kit::Global for ScrollRequest {}

/// Scrolls the sheet down now to `fraction` of its body (0 the top, 1 the
/// end), as a person would to reach what is below the fold: made on the
/// sheet's next render (its scroll is the window's, which only a render
/// can reach).
pub fn scroll_to(fraction: f32, cx: &mut App) {
    let Some(handle) = current_window(cx) else {
        return;
    };
    cx.set_global(ScrollRequest(Some(fraction)));
    let _ = handle.update(cx, |_, window, _| window.refresh());
}

/// Whether a sheet is down on the main window.
pub fn is_open(cx: &App) -> bool {
    cx.try_global::<OpenSheet>()
        .is_some_and(|s| s.current.is_some())
}

/// Quits the app, first ending a sheet that is down (AppKit keeps a
/// window-modal sheet's app from terminating while it hangs there).
pub fn quit(cx: &mut App) {
    quit_with(cx, Rc::new(|cx: &mut App| cx.quit()));
}

/// [`quit`], with `then` for the app's own quit (the tests' stand-in).
pub(crate) fn quit_with(cx: &mut App, then: Rc<dyn Fn(&mut App)>) {
    if !is_open(cx) {
        after_saves(cx, then);
        return;
    }
    let open = cx.default_global::<OpenSheet>();
    let Some((sheet, _)) = open.current.clone() else {
        return;
    };
    let waiting = open.quit.is_some();
    let unsaved = open.unsaved.clone();
    // Mid-operation (a save, test or create on its way) or asking something
    // (its discard question, a consent, any confirmation): Quit queues
    // nothing. The sheet comes forward and the Mac beeps, as a Mac app does
    // while it can't take the key; ⌘Q works again once the sheet is idle.
    let busy = unsaved.as_ref().is_some_and(|u| (u.busy)(cx));
    if busy || waiting || crate::shell::sheet::question_up(sheet, cx) {
        let _ = sheet.update(cx, |_, window, cx| {
            conduit_components::chrome::activate(window, cx)
        });
        crate::shell::sheet::beep(cx);
        return;
    }
    // Unsaved edits: the sheet comes forward and asks now, as Esc does.
    if unsaved.as_ref().is_some_and(|u| (u.edits)(cx)) {
        let open = cx.default_global::<OpenSheet>();
        open.quit_tickets += 1;
        let ticket = open.quit_tickets;
        open.quit = Some(PendingQuit {
            ticket,
            sheet,
            then,
            shown: false,
        });
        cx.defer(move |cx| ask(ticket, cx));
        return;
    }
    cx.default_global::<OpenSheet>().after = None;
    dismiss(cx);
    quit_once_gone(cx, then);
}

/// Whether an update's installer may close the app now (WinSparkle asks
/// before it starts one, and the installer then closes the app whatever
/// Quit would have done). A sheet Quit couldn't close without the user
/// (busy, asking something, or holding unsaved edits) comes forward and the
/// answer is no, so the install waits for the user; otherwise the saves
/// Quit waits for run first, and the answer is yes once they've landed (or
/// after [`SAVES_BEFORE_QUIT`]).
pub fn ready_for_installer(cx: &mut App) -> Task<bool> {
    if let Some(sheet) = holding_sheet(cx) {
        let _ = sheet.update(cx, |_, window, cx| {
            conduit_components::chrome::activate(window, cx)
        });
        crate::shell::sheet::beep(cx);
        return Task::ready(false);
    }
    let saves = cx.default_global::<BeforeQuit>().0.clone();
    let pending: Vec<_> = saves.iter().filter_map(|save| save(cx)).collect();
    cx.spawn(async move |cx| {
        let timer = cx.background_executor().timer(SAVES_BEFORE_QUIT);
        let _ = futures::future::select(futures::future::join_all(pending), Box::pin(timer)).await;
        // A sheet that opened while the saves ran holds the install too.
        cx.update(|cx| holding_sheet(cx).is_none())
    })
}

/// The sheet down now that Quit couldn't close without the user: busy,
/// asking something, or holding unsaved edits.
fn holding_sheet(cx: &mut App) -> Option<AnyWindowHandle> {
    let open = cx.try_global::<OpenSheet>()?;
    let sheet = open.current.as_ref().map(|(handle, _)| *handle)?;
    let waiting = open.quit.is_some();
    let unsaved = open.unsaved.clone();
    let holds = waiting
        || unsaved.is_some_and(|u| (u.busy)(cx) || (u.edits)(cx))
        || crate::shell::sheet::question_up(sheet, cx);
    holds.then_some(sheet)
}

/// The sheet has gone: once AppKit has ended it, Quit comes in again
/// through [`quit_with`], judging what is on screen then. A sheet opened
/// meanwhile (an approval, a link) beeps or asks; with none open, the app
/// quits after the app-wide saves.
fn quit_once_gone(cx: &mut App, then: Rc<dyn Fn(&mut App)>) {
    cx.spawn(async move |cx| {
        cx.background_executor()
            .timer(std::time::Duration::from_millis(250))
            .await;
        cx.update(|cx| quit_with(cx, then));
    })
    .detach();
}

/// Quit `ticket`'s sheet asks its discard question (its body's
/// [`SheetBody::cancel`]). A body that closes itself instead (nothing left
/// to discard) lets the Quit go on; one that neither asks nor closes leaves
/// nothing on screen, so the Quit is dropped.
fn ask(ticket: u64, cx: &mut App) {
    let open = cx.default_global::<OpenSheet>();
    let Some(sheet) = open
        .quit
        .as_ref()
        .filter(|q| q.ticket == ticket)
        .map(|q| q.sheet)
    else {
        return;
    };
    let Some(unsaved) = open
        .unsaved
        .clone()
        .filter(|_| open.current.as_ref().map(|(h, _)| *h) == Some(sheet))
    else {
        open.quit = None;
        return;
    };
    (unsaved.ask)(cx);
    let open = cx.default_global::<OpenSheet>();
    if open
        .quit
        .as_ref()
        .is_some_and(|q| q.ticket == ticket && !q.shown)
    {
        open.quit = None;
    }
}

/// A question is about to show on `window`
/// ([`crate::shell::sheet::present_sheet`]): the Quit it answers, when it is
/// the discard question that Quit's own sheet was just asked for. Any other
/// question (another window, another sheet) is not that Quit's.
pub(crate) fn question_shown(window: AnyWindowHandle, cx: &mut App) -> Option<u64> {
    let q = cx.default_global::<OpenSheet>().quit.as_mut()?;
    if q.sheet != window || q.shown {
        return None;
    }
    q.shown = true;
    Some(q.ticket)
}

/// The question [`question_shown`] tied to Quit `asked` was answered: No
/// (keep editing) drops that Quit; Discard closes the sheet and quits. Any
/// other question does nothing.
pub(crate) fn question_answered(asked: Option<u64>, yes: bool, cx: &mut App) {
    let Some(ticket) = asked else { return };
    let open = cx.default_global::<OpenSheet>();
    let Some(sheet) = open
        .quit
        .as_ref()
        .filter(|q| q.ticket == ticket)
        .map(|q| q.sheet)
    else {
        return;
    };
    if !yes {
        open.quit = None;
        return;
    }
    // Outside the question's (and the sheet's) update; the body's own
    // dismissal may come first, which quits the same way.
    cx.defer(move |cx| {
        let open = cx.default_global::<OpenSheet>();
        let ours = open.quit.as_ref().is_some_and(|q| q.ticket == ticket)
            && open.current.as_ref().map(|(h, _)| *h) == Some(sheet);
        if ours {
            dismiss(cx);
        }
    });
}

/// The longest Quit waits for saves still going (a daemon that does not
/// answer must not keep the app from quitting).
const SAVES_BEFORE_QUIT: std::time::Duration = std::time::Duration::from_secs(3);

/// A save Quit waits for: `None` when nothing is waiting to be saved.
type SaveBeforeQuit = Rc<dyn Fn(&mut App) -> Option<futures::future::LocalBoxFuture<'static, ()>>>;

/// What Quit saves first ([`save_before_quit`]).
#[derive(Default)]
struct BeforeQuit(Vec<SaveBeforeQuit>);

impl Global for BeforeQuit {}

/// Quit runs `save` first and waits for it (up to 3 s) before the app
/// quits and the daemon stops: what a view has not saved yet (a note's
/// last words, still in the autosave pause) is kept.
pub fn save_before_quit(
    cx: &mut App,
    save: impl Fn(&mut App) -> Option<futures::future::LocalBoxFuture<'static, ()>> + 'static,
) {
    cx.default_global::<BeforeQuit>().0.push(Rc::new(save));
}

/// Runs the saves Quit waits for, then `then` once they have landed (or
/// after [`SAVES_BEFORE_QUIT`]).
fn after_saves(cx: &mut App, then: Rc<dyn Fn(&mut App)>) {
    let saves = cx.default_global::<BeforeQuit>().0.clone();
    let pending: Vec<_> = saves.iter().filter_map(|save| save(cx)).collect();
    if pending.is_empty() {
        then(cx);
        return;
    }
    cx.spawn(async move |cx| {
        let timer = cx.background_executor().timer(SAVES_BEFORE_QUIT);
        let _ = futures::future::select(futures::future::join_all(pending), Box::pin(timer)).await;
        // A sheet opened while the saves ran: Quit comes in again for it.
        cx.update(|cx| {
            if is_open(cx) {
                quit_with(cx, then)
            } else {
                then(cx)
            }
        });
    })
    .detach();
}

/// Closes the sheet whose body `cx` is once another account is active (a
/// switch in Settings, which has its own window): what it shows and would
/// save belongs to the account it opened for, never to the next one. Edits
/// go with it, and nothing it was to reopen ([`after_dismiss`]) opens.
pub fn close_with_account<V: SheetBody>(
    stores: &crate::stores::Stores,
    cx: &mut Context<V>,
) -> Subscription {
    let opened = stores.accounts.read(cx).active().map(|a| a.id.clone());
    cx.observe(&stores.accounts, move |_, accounts, cx| {
        // A list being read again (a reconnect) names nobody: no change.
        let Some(now) = accounts.read(cx).active().map(|a| a.id.clone()) else {
            return;
        };
        if Some(&now) == opened.as_ref() {
            return;
        }
        if current::<V>(cx).is_some_and(|body| body == cx.entity()) {
            // Closed for the switch, not by the user: nothing reopens, and
            // a Quit waiting on it is dropped.
            cx.default_global::<OpenSheet>().after = None;
            end_sheet(cx, Ending::ClosedForIt);
        }
    })
}

/// Asks `spec` for the account active now, for an action that changes the
/// server: the question closes (answers no) when another account signs in,
/// and answers no if one has by the time it is answered, so what it
/// confirms never runs under the next account.
pub fn ask_for_account(
    stores: &crate::stores::Stores,
    window: &Window,
    spec: crate::shell::sheet::SheetSpec,
    cx: &mut App,
) -> gpui_kit::Task<bool> {
    // The account in charge: one LibreChat account after another changes
    // no Open WebUI id.
    let accounts = stores.accounts.clone();
    let opened = accounts.read(cx).scope_key();
    let (asked, closer) = crate::shell::sheet::present_sheet_closable(window, spec, cx);
    let watch = {
        let opened = opened.clone();
        cx.observe(&accounts, move |accounts, cx| {
            // A list being read again (a reconnect) names nobody: no change.
            let now = accounts.read(cx).scope_key();
            if now.is_some() && now != opened {
                closer.close(cx);
            }
        })
    };
    cx.spawn(async move |cx| {
        let yes = asked.await;
        drop(watch);
        yes && cx.update(|cx| accounts.read(cx).scope_key() == opened)
    })
}

/// Runs `f` (the next sheet, say) once a sheet window being ended has gone.
/// Off the Mac a dialog's owner is the window in front as it opens
/// (Windows), and GPUI destroys a closed window from a task of its own,
/// spawned as the task that closes it ([`crate::views::settings::end_sheet_window`])
/// runs: so `f` waits for a task spawned after that one.
pub fn once_sheet_window_gone(cx: &mut App, f: impl FnOnce(&mut App) + 'static) {
    cx.spawn(async move |cx| {
        cx.update(|cx| cx.spawn(async move |cx| cx.update(f)).detach());
    })
    .detach();
}

/// Closes the sheet down now (it slides up), from its body or anywhere.
pub fn dismiss(cx: &mut App) {
    end_sheet(cx, Ending::Own);
}

/// How a sheet ends, for a Quit waiting on it.
#[derive(Clone, Copy, PartialEq)]
enum Ending {
    /// The sheet's own outcome: Discard, a save that closed it, Cancel.
    Own,
    /// Closed for it (another account): never the Quit's answer.
    ClosedForIt,
}

/// The one place a sheet ends. A Quit's discard question goes on to quit
/// only with the sheet's own ending (Discard, or the sheet closing itself
/// when asked); closed any other way (another account), the Quit is
/// dropped and the user can quit again.
fn end_sheet(cx: &mut App, ending: Ending) {
    let open = cx.default_global::<OpenSheet>();
    let Some((handle, _)) = open.current.take() else {
        return;
    };
    open.unsaved = None;
    let quit = open
        .quit
        .take()
        .filter(|q| q.sheet == handle && ending == Ending::Own);
    let after = if quit.is_some() {
        None
    } else {
        open.after.take()
    };
    open.after = None;
    // The main window takes the keyboard back as AppKit ends the sheet, its
    // focus where it was.
    crate::views::settings::end_sheet_window(handle, cx);
    if let Some(after) = after {
        once_sheet_window_gone(cx, after);
    }
    // Quit asked about this sheet and it has gone (Discard, or the save it
    // was busy with closed it): the app quits now.
    if let Some(quit) = quit {
        quit_once_gone(cx, quit.then);
    }
}

impl<V: SheetBody> Focusable for SheetHost<V> {
    fn focus_handle(&self, _: &App) -> FocusHandle {
        self.focus.clone()
    }
}

/// Whether a sheet sized for `requested` must change for a body `measured`
/// tall (half a point either way is the same height).
fn needs_fit(requested: Option<f32>, measured: f32) -> bool {
    requested.is_none_or(|r| (r - measured).abs() >= 0.5)
}

/// Fits the sheet's window to the body, `height` points tall, after this
/// frame (AppKit calls back into GPUI on a resize). The first fit comes as
/// the sheet drops in, so it doesn't animate on top of AppKit's slide.
fn fit(height: f32, first: bool, room: Option<f32>, window: &Window, cx: &App) {
    #[cfg(target_os = "macos")]
    if let Some(ns) = crate::shell::macos::ns_window(window) {
        let _ = room;
        let animate = !first && !cx.reduce_motion();
        cx.foreground_executor()
            .spawn(async move {
                crate::shell::macos::fit_sheet(
                    &ns,
                    f64::from(height),
                    f64::from(PARENT_MARGIN),
                    animate,
                )
            })
            .detach();
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = first;
        let handle = window.window_handle();
        let fitted = size(
            window.viewport_size().width,
            px(fitted_height(height, room)),
        );
        cx.spawn(async move |cx| {
            let _ = handle.update(cx, |_, window, _| window.resize(fitted));
        })
        .detach();
    }
}

impl<V: SheetBody> Render for SheetHost<V> {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let t = cx.conduit().clone();
        let (page, _) = grouped_tones(&t);
        let requested = self.requested.clone();
        let footer_height = self.footer_height.clone();
        let room = self.room;
        let label = self.body.read(cx).label(cx);
        // A label that changes once the body has loaded (a server's sheet
        // names the server) renames the dialog.
        if self.hang == Hang::Dialog && self.title.as_ref() != Some(&label) {
            window.set_window_title(&label);
            self.title = Some(label.clone());
        }
        // The body's scroll, kept by the sheet's window; a scroll asked for
        // from outside a render ([`scroll_to`]) is made here.
        let scroll = window
            .use_keyed_state(SCROLL_KEY, cx, |_, _| gpui_kit::ScrollHandle::new())
            .read(cx)
            .clone();
        if let Some(fraction) = cx.try_global::<ScrollRequest>().and_then(|r| r.0) {
            let max = scroll.max_offset();
            scroll.set_offset(gpui_kit::point(gpui_kit::px(0.), -max.y * fraction));
            cx.set_global(ScrollRequest(None));
        }
        let footer = self.body.update(cx, |b, cx| b.footer(window, cx));
        let has_footer = footer.is_some();
        // The body's natural height (padding included), and the footer's:
        // the window is fitted to both.
        let footer_for_fit = footer_height.clone();
        let overflowing = self.overflowing.clone();
        let over = overflowing.get();
        let probe = gpui_kit::canvas(
            |bounds: Bounds<Pixels>, _, _| f32::from(bounds.size.height),
            move |_, height, window, cx| {
                let total = height + footer_for_fit.get();
                let now = total > f32::from(window.viewport_size().height) + 0.5;
                if overflowing.replace(now) != now {
                    window.refresh();
                }
                let before = requested.get();
                if needs_fit(before, total) {
                    requested.set(Some(total));
                    fit(total, before.is_none(), room, window, cx);
                }
            },
        )
        .absolute()
        .top_0()
        .left_0()
        .size_full();
        let footer_probe = gpui_kit::canvas(
            |bounds: Bounds<Pixels>, _, _| f32::from(bounds.size.height),
            move |_, height, _, _| footer_height.set(height),
        )
        .absolute()
        .top_0()
        .left_0()
        .size_full();
        let body = self.body.clone();
        let cancel_body = self.body.clone();
        let (esc_body, stop_body) = (self.body.clone(), self.body.clone());
        div()
            .id("sheet")
            .role(Role::Dialog)
            .aria_label(label)
            .key_context("ConduitSheet")
            .track_focus(&self.focus)
            // Esc: a field's Escape, and the app's (Stop Generating, bound
            // with no context and answered app-wide), would take the key
            // first; the capture phase reaches the sheet before either.
            .capture_action(move |_: &gpui_kit::component::input::Escape, window, cx| {
                esc_body.update(cx, |b, cx| b.cancel(window, cx));
                cx.stop_propagation();
            })
            .capture_action(move |_: &crate::actions::StopGenerating, window, cx| {
                stop_body.update(cx, |b, cx| b.cancel(window, cx));
                cx.stop_propagation();
            })
            .size_full()
            .flex()
            .flex_col()
            .font_family(ui_font())
            .bg(page)
            .text_color(t.roles.text)
            // Esc and ⌘. cancel, as in any sheet.
            .on_key_down(move |e: &gpui_kit::KeyDownEvent, window, cx| {
                let k = &e.keystroke;
                let m = &k.modifiers;
                let esc = k.key == "escape" && !(m.platform || m.alt || m.control || m.shift);
                let h = crate::keymap::held(m);
                let cmd_period = k.key == "." && h.primary && !(h.alt || h.ctrl);
                if esc || cmd_period {
                    body.update(cx, |b, cx| b.cancel(window, cx));
                    cx.stop_propagation();
                }
            })
            // ⌘W in a sheet cancels it (the window under it stays).
            .on_action(move |_: &CloseWindow, window, cx| {
                cancel_body.update(cx, |b, cx| b.cancel(window, cx));
            })
            .child(
                div()
                    .id("sheet-body")
                    .flex_1()
                    .min_h_0()
                    .overflow_y_scroll()
                    .track_scroll(&scroll)
                    .child(
                        div()
                            .relative()
                            .w_full()
                            .p(px(PADDING))
                            .when(has_footer, |d| d.pb(px(PADDING / 2.)))
                            .child(self.body.clone())
                            .child(probe),
                    ),
            )
            .when_some(footer, |d, footer| {
                d.child(
                    div()
                        .relative()
                        .flex_none()
                        .w_full()
                        .when(over, |d| d.border_t_1().border_color(t.roles.divider))
                        .px(px(PADDING))
                        .pt(px(PADDING / 2.))
                        .pb(px(PADDING))
                        .child(footer)
                        .child(footer_probe),
                )
            })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The main window a sheet is about, on screen.
    fn parent() -> Bounds<Pixels> {
        Bounds::new(point(px(100.), px(50.)), size(px(1280.), px(720.)))
    }

    #[test]
    fn a_sheet_opens_hidden_fixed_and_as_wide_as_asked() {
        let o = window_options(Hang::BeginSheet, 520., FIRST_HEIGHT, "Synthetic", parent());
        assert!(!o.show && !o.focus);
        assert!(!o.is_resizable && !o.is_minimizable && !o.is_movable);
        // AppKit hangs it, untitled: VoiceOver reads the sheet's own label.
        assert_eq!(o.kind, WindowKind::Normal);
        assert!(o.titlebar.as_ref().is_some_and(|t| t.title.is_none()));
        match o.window_bounds {
            Some(WindowBounds::Windowed(b)) => assert_eq!(f32::from(b.size.width), 520.),
            other => panic!("{other:?}"),
        }
    }

    /// Off the Mac a sheet is a titled modal dialog over its parent: the
    /// OS's title bar names it to screen readers ("Chat Settings, dialog",
    /// not "window"), and it hangs under the parent's toolbar, centred.
    #[test]
    fn off_the_mac_a_sheet_is_a_titled_dialog_over_its_parent() {
        let o = window_options(Hang::Dialog, 520., FIRST_HEIGHT, "Synthetic", parent());
        assert_eq!(o.kind, WindowKind::Dialog);
        assert!(o.show && o.focus && o.is_movable);
        assert!(!o.is_resizable && !o.is_minimizable);
        let titlebar = o.titlebar.expect("a title bar");
        assert_eq!(titlebar.title.as_deref(), Some("Synthetic"));
        assert!(!titlebar.appears_transparent, "the OS draws its title bar");
        match o.window_bounds {
            Some(WindowBounds::Windowed(b)) => {
                assert_eq!(f32::from(b.origin.x), 100. + (1280. - 520.) / 2.);
                assert_eq!(f32::from(b.origin.y), 50. + BELOW_PARENT_TOP);
                assert_eq!(f32::from(b.size.width), 520.);
            }
            other => panic!("{other:?}"),
        }
    }

    /// Off the Mac a sheet is as tall as its body, up to the room under its
    /// parent's toolbar (it scrolls beyond), and never shorter than a form
    /// needs however small the parent.
    #[test]
    fn off_the_mac_a_sheet_fits_its_body_under_its_parent() {
        let room = dialog_room(parent());
        assert_eq!(room, 720. - BELOW_PARENT_TOP - PARENT_MARGIN);
        assert_eq!(fitted_height(410., Some(room)), 410.);
        assert_eq!(fitted_height(900., Some(room)), room);
        assert_eq!(fitted_height(900., None), 900.);
        let small = Bounds::new(point(px(0.), px(0.)), size(px(720.), px(260.)));
        assert_eq!(dialog_room(small), LEAST_ROOM);
    }

    /// A sheet body that counts how often it is asked to close, and puts
    /// its discard question up (unanswered) as present_sheet would.
    struct Probe(Rc<Cell<u32>>, Rc<Cell<Option<u64>>>);

    impl Render for Probe {
        fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
            div()
        }
    }

    impl SheetBody for Probe {
        fn cancel(&mut self, window: &mut Window, cx: &mut Context<Self>) {
            self.0.set(self.0.get() + 1);
            self.1.set(question_shown(window.window_handle(), cx));
        }

        fn label(&self, _: &App) -> SharedString {
            "Probe".into()
        }

        fn unsaved(&self, _: &App) -> bool {
            true
        }
    }

    /// Quit again while the discard question of the first is up: ignored
    /// with a beep (no second question), and Discard quits once.
    #[gpui_kit::test]
    fn a_second_quit_while_the_question_is_up_beeps(cx: &mut gpui_kit::TestAppContext) {
        let (_daemon, _stores, vcx) = bench::bench(cx);
        let asks = Rc::new(Cell::new(0));
        let shown = Rc::new(Cell::new(None));
        let (probe, question) = (asks.clone(), shown.clone());
        vcx.update(|window, cx| open(window, 400., cx, move |_, _| Probe(probe, question)))
            .expect("the sheet opens");
        vcx.run_until_parked();
        let quits = Rc::new(Cell::new(0));
        let quit = |vcx: &mut gpui_kit::VisualTestContext| {
            let counted = quits.clone();
            vcx.update(|_, cx| quit_with(cx, Rc::new(move |_| counted.set(counted.get() + 1))));
            vcx.run_until_parked();
        };
        quit(vcx);
        assert_eq!(asks.get(), 1, "Quit did not ask the sheet");
        // The sheet's discard question is up, tied to this Quit.
        let asked = shown.get();
        assert!(asked.is_some());
        quit(vcx);
        assert_eq!(asks.get(), 1, "a second Quit asked again");
        assert_eq!(
            vcx.update(|_, cx| cx.global::<crate::shell::sheet::Beeps>().0),
            1,
            "the second Quit did not beep"
        );
        // Discard.
        vcx.update(|_, cx| question_answered(asked, true, cx));
        for _ in 0..2 {
            vcx.run_until_parked();
            vcx.executor()
                .advance_clock(std::time::Duration::from_secs(5));
        }
        vcx.run_until_parked();
        assert_eq!(quits.get(), 1, "Discard did not quit once");
    }

    /// An installer about to replace the app waits while a sheet holds
    /// unsaved edits: the sheet comes forward with a beep, and nothing is
    /// asked or closed.
    #[gpui_kit::test]
    fn an_installer_waits_for_a_sheet_with_unsaved_edits(cx: &mut gpui_kit::TestAppContext) {
        let (_daemon, _stores, vcx) = bench::bench(cx);
        let asks = Rc::new(Cell::new(0));
        let (probe, question) = (asks.clone(), Rc::new(Cell::new(None)));
        vcx.update(|window, cx| open(window, 400., cx, move |_, _| Probe(probe, question)))
            .expect("the sheet opens");
        vcx.run_until_parked();
        let mut ready = vcx.update(|_, cx| ready_for_installer(cx));
        vcx.run_until_parked();
        assert_eq!(futures::FutureExt::now_or_never(&mut ready), Some(false));
        assert!(vcx.update(|_, cx| is_open(cx)), "the sheet closed");
        assert_eq!(asks.get(), 0, "the sheet was asked to close");
        assert_eq!(
            vcx.update(|_, cx| cx.global::<crate::shell::sheet::Beeps>().0),
            1,
            "the sheet didn't come forward with a beep"
        );
    }

    /// With no sheet down, the saves Quit waits for run first, and the
    /// answer is yes only once they've landed.
    #[gpui_kit::test]
    fn an_installer_may_close_the_app_once_its_saves_land(cx: &mut gpui_kit::TestAppContext) {
        let (_daemon, _stores, vcx) = bench::bench(cx);
        let (landed, landing) = futures::channel::oneshot::channel::<()>();
        let landing = Rc::new(std::cell::RefCell::new(Some(landing)));
        let ran = Rc::new(Cell::new(0));
        let counted = ran.clone();
        vcx.update(|_, cx| {
            save_before_quit(cx, move |_| {
                counted.set(counted.get() + 1);
                let landing = landing.borrow_mut().take()?;
                Some(futures::FutureExt::boxed_local(async move {
                    let _ = landing.await;
                }))
            })
        });
        let mut ready = vcx.update(|_, cx| ready_for_installer(cx));
        vcx.run_until_parked();
        assert_eq!(ran.get(), 1, "the save didn't run");
        assert_eq!(
            futures::FutureExt::now_or_never(&mut ready),
            None,
            "it answered before the save landed"
        );
        landed.send(()).unwrap();
        vcx.run_until_parked();
        assert_eq!(futures::FutureExt::now_or_never(&mut ready), Some(true));
    }

    /// A sheet body whose Cancel closes it (nothing to discard), with a
    /// field it focuses as it opens, or none.
    struct Closer(Rc<Cell<u32>>, Option<FocusHandle>);

    impl Render for Closer {
        fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
            div().size_full().when_some(self.1.clone(), |d, f| {
                d.child(div().track_focus(&f).size_full())
            })
        }
    }

    impl SheetBody for Closer {
        fn cancel(&mut self, _: &mut Window, cx: &mut Context<Self>) {
            self.0.set(self.0.get() + 1);
            dismiss(cx);
        }

        fn label(&self, _: &App) -> SharedString {
            "Closer".into()
        }
    }

    fn open_closer(
        vcx: &mut gpui_kit::VisualTestContext,
        field: bool,
    ) -> (Rc<Cell<u32>>, AnyWindowHandle) {
        let cancels = Rc::new(Cell::new(0));
        let counted = cancels.clone();
        vcx.update(|window, cx| {
            open(window, 400., cx, move |window, cx| {
                let focus = field.then(|| cx.focus_handle());
                if let Some(f) = &focus {
                    window.focus(f, cx);
                }
                Closer(counted, focus)
            })
        })
        .expect("the sheet opens");
        vcx.run_until_parked();
        let sheet = vcx
            .update(|_, cx| current_window(cx))
            .expect("a sheet is down");
        (cancels, sheet)
    }

    /// Esc cancels a sheet, its field focused or nothing, though the app's
    /// Esc (Stop Generating, bound with no context and answered app-wide)
    /// would take the key first.
    #[gpui_kit::test]
    fn esc_cancels_a_sheet_over_the_apps_esc(cx: &mut gpui_kit::TestAppContext) {
        let (_daemon, _stores, vcx) = bench::bench(cx);
        let stops = Rc::new(Cell::new(0));
        let seen = stops.clone();
        vcx.update(|_, cx| {
            cx.bind_keys([gpui_kit::KeyBinding::new(
                "escape",
                crate::actions::StopGenerating,
                None,
            )]);
            cx.on_action(move |_: &crate::actions::StopGenerating, _| seen.set(seen.get() + 1));
        });
        for field in [true, false] {
            let (cancels, sheet) = open_closer(vcx, field);
            vcx.cx.simulate_keystrokes(sheet, "escape");
            vcx.run_until_parked();
            assert_eq!(
                cancels.get(),
                1,
                "field {field}: Esc didn't cancel the sheet"
            );
            assert!(!vcx.update(|_, cx| is_open(cx)), "field {field}");
        }
        assert_eq!(
            stops.get(),
            0,
            "Esc reached Stop Generating behind the sheet"
        );
    }

    /// The window manager's close (its × button, Alt+F4) is Cancel: the
    /// body asks first when it holds edits, and the window stays until the
    /// sheet ends its own way.
    #[gpui_kit::test]
    fn the_window_managers_close_is_cancel(cx: &mut gpui_kit::TestAppContext) {
        let (_daemon, _stores, vcx) = bench::bench(cx);
        let asks = Rc::new(Cell::new(0));
        let (probe, question) = (asks.clone(), Rc::new(Cell::new(None)));
        vcx.update(|window, cx| open(window, 400., cx, move |_, _| Probe(probe, question)))
            .expect("the sheet opens");
        vcx.run_until_parked();
        let sheet = vcx.update(|_, cx| current_window(cx)).unwrap();
        let closes = vcx
            .cx
            .update(|cx| sheet.update(cx, |_, window, cx| window_manager_closes(window, cx)))
            .unwrap();
        vcx.run_until_parked();
        assert!(!closes, "the window manager closed a sheet with edits");
        assert_eq!(asks.get(), 1, "the body wasn't asked");
        assert!(vcx.update(|_, cx| is_open(cx)));
    }

    /// A sheet whose window went some other way (its parent closed under
    /// it) no longer counts as down: the next sheet opens.
    #[gpui_kit::test]
    fn a_sheet_whose_window_went_lets_the_next_one_open(cx: &mut gpui_kit::TestAppContext) {
        let (_daemon, _stores, vcx) = bench::bench(cx);
        let (_, sheet) = open_closer(vcx, false);
        vcx.cx
            .update(|cx| sheet.update(cx, |_, window, _| window.remove_window()))
            .unwrap();
        vcx.run_until_parked();
        assert!(
            !vcx.update(|_, cx| is_open(cx)),
            "the gone sheet still counts"
        );
        let (_, next) = open_closer(vcx, false);
        assert_ne!(next, sheet);
    }

    /// Opens a sheet on `vcx`'s window that runs `then` once it has been
    /// dismissed, with whether its own window was still open by then.
    #[gpui_kit::test]
    fn the_sheet_after_one_opens_once_its_window_has_gone(cx: &mut gpui_kit::TestAppContext) {
        let (_daemon, _stores, vcx) = bench::bench(cx);
        let (_, sheet) = open_closer(vcx, false);
        let still_open = Rc::new(Cell::new(None));
        let seen = still_open.clone();
        vcx.update(|_, cx| {
            after_dismiss(cx, move |cx| seen.set(Some(cx.windows().contains(&sheet))));
            dismiss(cx);
        });
        vcx.run_until_parked();
        assert_eq!(
            still_open.get(),
            Some(false),
            "the next sheet opened while the last one's window was still there"
        );
    }

    /// A body that asks before it closes, its question held open.
    struct Asker(Rc<Cell<u32>>);

    impl Render for Asker {
        fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
            div()
        }
    }

    impl SheetBody for Asker {
        fn cancel(&mut self, window: &mut Window, cx: &mut Context<Self>) {
            self.0.set(self.0.get() + 1);
            let spec = crate::shell::sheet::SheetSpec::new(
                "Discard edits?",
                "Synthetic",
                "Discard",
                "Keep",
            );
            crate::shell::sheet::present_sheet(window, spec, cx).detach();
        }

        fn label(&self, _: &App) -> SharedString {
            "Asker".into()
        }
    }

    /// The window manager's close again while the sheet's question is up
    /// asks nothing more: the question stays, and keeps the keyboard.
    #[gpui_kit::test]
    fn a_second_close_while_the_question_is_up_asks_nothing(cx: &mut gpui_kit::TestAppContext) {
        let (_daemon, _stores, vcx) = bench::bench(cx);
        vcx.update(|_, cx| cx.set_global(crate::shell::sheet::HeldAnswers::default()));
        let asks = Rc::new(Cell::new(0));
        let counted = asks.clone();
        vcx.update(|window, cx| open(window, 400., cx, move |_, _| Asker(counted)))
            .expect("the sheet opens");
        vcx.run_until_parked();
        let sheet = vcx.update(|_, cx| current_window(cx)).unwrap();
        for _ in 0..2 {
            let closes = vcx
                .cx
                .update(|cx| sheet.update(cx, |_, window, cx| window_manager_closes(window, cx)))
                .unwrap();
            assert!(!closes);
            vcx.run_until_parked();
        }
        assert_eq!(asks.get(), 1, "asked again over its own question");
        assert_eq!(
            vcx.update(|_, cx| cx.global::<crate::shell::sheet::HeldAnswers>().0.len()),
            1
        );
    }

    /// A body whose label changes once it has loaded (a server's sheet
    /// names the server).
    struct Renamer(Rc<std::cell::RefCell<String>>);

    impl Render for Renamer {
        fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
            div()
        }
    }

    impl SheetBody for Renamer {
        fn cancel(&mut self, _: &mut Window, cx: &mut Context<Self>) {
            dismiss(cx);
        }

        fn label(&self, _: &App) -> SharedString {
            self.0.borrow().clone().into()
        }
    }

    /// Off the Mac the dialog's title (its name to screen readers) follows
    /// the sheet's label as it changes.
    #[gpui_kit::test]
    fn a_dialogs_title_follows_its_label(cx: &mut gpui_kit::TestAppContext) {
        let (_daemon, _stores, vcx) = bench::bench(cx);
        let label = Rc::new(std::cell::RefCell::new("Synthetic Settings…".to_string()));
        let named = label.clone();
        let body = vcx
            .update(|window, cx| {
                open_on(Hang::Dialog, window, 400., cx, move |_, _| Renamer(named))
            })
            .expect("the sheet opens");
        vcx.run_until_parked();
        let sheet = vcx.update(|_, cx| current_window(cx)).unwrap();
        let mut sheet_cx = gpui_kit::VisualTestContext::from_window(sheet, &vcx.cx);
        sheet_cx.update(|window, cx| window.draw(cx).clear(cx));
        assert_eq!(
            sheet_cx.window_title().as_deref(),
            Some("Synthetic Settings…")
        );
        *label.borrow_mut() = "Synthetic Server".into();
        body.update(&mut sheet_cx, |_, cx| cx.notify());
        sheet_cx.update(|window, cx| window.draw(cx).clear(cx));
        sheet_cx.run_until_parked();
        assert_eq!(sheet_cx.window_title().as_deref(), Some("Synthetic Server"));
    }

    #[test]
    fn a_sheet_refits_only_when_its_body_changes_height() {
        assert!(needs_fit(None, 310.));
        assert!(!needs_fit(Some(310.), 310.3));
        assert!(needs_fit(Some(310.), 512.));
    }
}

/// A main window with stores for sheet tests, an account signed in.
#[cfg(test)]
pub mod bench {
    use gpui_kit::{TestAppContext, VisualTestContext};

    use crate::stores::Stores;
    use crate::stores::accounts::tests::{account, list};
    use crate::stores::rpc::fake::FakeDaemon;

    struct Parent;

    impl gpui_kit::Render for Parent {
        fn render(
            &mut self,
            _: &mut gpui_kit::Window,
            _: &mut gpui_kit::Context<Self>,
        ) -> impl gpui_kit::IntoElement {
            gpui_kit::div()
        }
    }

    pub fn bench(cx: &mut TestAppContext) -> (FakeDaemon, Stores, &mut VisualTestContext) {
        let daemon = FakeDaemon::new();
        let scratch = std::env::temp_dir().join(format!("conduit-sheet-{}", std::process::id()));
        let stores = cx.update(|cx| {
            crate::views::test_globals(cx);
            // Questions answer "no" (keep editing) unless a test says, and
            // beeps are counted.
            cx.set_global(crate::shell::sheet::AutoAnswer(Some(false)));
            cx.set_global(crate::shell::sheet::Beeps::default());
            Stores::for_test(daemon.rpc(), &scratch, cx)
        });
        stores.accounts.update(cx, |a, cx| {
            a.adopt(list(vec![account("a", "Avery", true, true)]), cx)
        });
        let (_, vcx) = cx.add_window_view(|_, _| Parent);
        (daemon, stores, vcx)
    }

    /// Settings makes Blake's account the active one.
    pub fn switch_account(stores: &Stores, vcx: &mut VisualTestContext) {
        stores.accounts.update(vcx, |a, cx| {
            a.adopt(
                list(vec![
                    account("a", "Avery", false, true),
                    account("b", "Blake", true, true),
                ]),
                cx,
            )
        });
        vcx.run_until_parked();
    }
}
