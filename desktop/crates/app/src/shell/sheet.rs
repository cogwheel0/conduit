//! Native confirmation sheets: an `NSAlert` attached to the window, for the
//! questions that must not be missed (remove an account, sign out, clear
//! local data, stop a reply to switch accounts).
//!
//! [`present_sheet`] resolves with whether the user confirmed. The confirm
//! button comes first (the default, ↩), cancel second (Esc), and a
//! destructive confirm draws red. AppKit calls back into GPUI's window
//! delegate while a sheet begins (key-window changes), so the alert is
//! started from a foreground task between GPUI borrows, never inside
//! `cx.update` or a window update, where AppKit's call back into the
//! borrowed window fails (as a `setFrame` from inside an update does).

use std::cell::RefCell;
use std::rc::{Rc, Weak};

use futures::channel::oneshot;
use gpui_kit::{AnyWindowHandle, App, Global, Task, Window};

/// The questions [`present_sheet`] has up, by window: each lives while its
/// token does (the task waiting for its answer), so a question dropped
/// unanswered is gone too. With AppKit's own attached sheet, this is how
/// [`question_up`] tells a window is asking something.
#[derive(Default)]
struct OpenQuestions(Vec<(AnyWindowHandle, Weak<()>)>);

impl Global for OpenQuestions {}

/// Records a question shown on `window` until the returned token drops.
fn hold_question(window: AnyWindowHandle, cx: &mut App) -> Rc<()> {
    let token = Rc::new(());
    let open = cx.default_global::<OpenQuestions>();
    open.0.retain(|(_, alive)| alive.strong_count() > 0);
    open.0.push((window, Rc::downgrade(&token)));
    token
}

/// Whether `window` has a question up: any of ours ([`present_sheet`]) or
/// any native sheet or alert AppKit has attached to it.
pub fn question_up(window: AnyWindowHandle, cx: &mut App) -> bool {
    let ours = cx.try_global::<OpenQuestions>().is_some_and(|open| {
        open.0
            .iter()
            .any(|(handle, alive)| *handle == window && alive.strong_count() > 0)
    });
    ours || native_sheet_up(window, cx)
}

#[cfg(target_os = "macos")]
fn native_sheet_up(window: AnyWindowHandle, cx: &mut App) -> bool {
    window
        .update(cx, |_, w, _| {
            crate::shell::macos::ns_window(w).is_some_and(|ns| ns.attachedSheet().is_some())
        })
        .unwrap_or(false)
}

#[cfg(not(target_os = "macos"))]
fn native_sheet_up(_: AnyWindowHandle, _: &mut App) -> bool {
    false
}

/// Test hook: questions wait for the test's answer (each sender, in the
/// order the questions came) instead of showing, and stay up meanwhile.
#[derive(Default)]
pub struct HeldAnswers(pub Vec<oneshot::Sender<bool>>);

impl Global for HeldAnswers {}

/// Test hook: beeps are counted here instead of sounded.
#[derive(Clone, Copy, Debug, Default)]
pub struct Beeps(pub u32);

impl Global for Beeps {}

/// The system beep, as a Mac app gives a key press it can't take now.
pub fn beep(cx: &mut App) {
    if cx.has_global::<Beeps>() {
        cx.global_mut::<Beeps>().0 += 1;
        return;
    }
    #[cfg(target_os = "macos")]
    // SAFETY: AppKit's NSBeep takes nothing and may be called any time.
    unsafe {
        NSBeep();
    }
}

#[cfg(target_os = "macos")]
#[link(name = "AppKit", kind = "framework")]
unsafe extern "C" {
    fn NSBeep();
}

/// A question [`HeldAnswers`] keeps up, answered by the test.
fn held(window: AnyWindowHandle, asked: Option<u64>, cx: &mut App) -> Option<Task<bool>> {
    if !cx.has_global::<HeldAnswers>() {
        return None;
    }
    let (tx, rx) = oneshot::channel();
    cx.global_mut::<HeldAnswers>().0.push(tx);
    let token = hold_question(window, cx);
    Some(cx.spawn(async move |cx| {
        let yes = rx.await.unwrap_or(false);
        drop(token);
        cx.update(|cx| crate::views::sheet::question_answered(asked, yes, cx));
        yes
    }))
}

/// What a sheet asks.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SheetSpec {
    pub title: String,
    pub message: String,
    pub confirm: String,
    pub cancel: String,
    /// The confirm button draws as destructive (red).
    pub destructive: bool,
}

impl SheetSpec {
    pub fn new(
        title: impl Into<String>,
        message: impl Into<String>,
        confirm: impl Into<String>,
        cancel: impl Into<String>,
    ) -> Self {
        Self {
            title: title.into(),
            message: message.into(),
            confirm: confirm.into(),
            cancel: cancel.into(),
            destructive: false,
        }
    }

    pub fn destructive(mut self) -> Self {
        self.destructive = true;
        self
    }

    /// A notice with one button (`ok`), as Finder's "name is already
    /// taken" alert: it resolves `true` when dismissed.
    pub fn notice(
        title: impl Into<String>,
        message: impl Into<String>,
        ok: impl Into<String>,
    ) -> Self {
        Self::new(title, message, ok, String::new())
    }
}

/// Test hook: when set, sheets answer at once with this instead of
/// showing (the `--shots` pass and tests).
#[derive(Clone, Copy, Debug, Default)]
pub struct AutoAnswer(pub Option<bool>);

impl gpui_kit::Global for AutoAnswer {}

/// Ends a sheet [`present_sheet_closable`] showed, as Cancel would (it
/// resolves `false`): the question was settled somewhere else.
#[derive(Clone, Default)]
pub struct SheetCloser(Rc<RefCell<CloserState>>);

#[derive(Default)]
struct CloserState {
    closed: bool,
    end: Option<Box<dyn FnOnce()>>,
}

impl SheetCloser {
    pub fn close(&self, cx: &mut App) {
        let mut state = self.0.borrow_mut();
        state.closed = true;
        // Between GPUI borrows: AppKit calls back as the sheet ends.
        if let Some(end) = state.end.take() {
            cx.foreground_executor()
                .spawn(async move { end() })
                .detach();
        }
    }

    pub fn is_closed(&self) -> bool {
        self.0.borrow().closed
    }
}

/// [`present_sheet`], with a [`SheetCloser`] that takes it away unanswered.
pub fn present_sheet_closable(
    window: &Window,
    spec: SheetSpec,
    cx: &mut App,
) -> (Task<bool>, SheetCloser) {
    let closer = SheetCloser::default();
    let asked = crate::views::sheet::question_shown(window.window_handle(), cx);
    if let Some(task) = held(window.window_handle(), asked, cx) {
        return (task, closer);
    }
    if let Some(answer) = cx.try_global::<AutoAnswer>().and_then(|a| a.0) {
        log::info!("sheet {:?} answered {answer} (auto)", spec.title);
        #[cfg(feature = "harness")]
        cx.default_global::<AutoAnswered>()
            .0
            .push(spec.title.clone());
        crate::views::sheet::question_answered(asked, answer, cx);
        return (Task::ready(answer), closer);
    }
    #[cfg(target_os = "macos")]
    {
        let Some(ns_window) = conduit_components::window::macos::ns_window(window) else {
            crate::views::sheet::question_answered(asked, false, cx);
            return (Task::ready(false), closer);
        };
        let state = closer.clone();
        let token = hold_question(window.window_handle(), cx);
        let task = cx.spawn(async move |cx| {
            let _token = token;
            let yes = if state.is_closed() {
                false
            } else if let Some((rx, sheet)) = macos::begin(&ns_window, &spec) {
                state.0.borrow_mut().end = Some(Box::new(move || {
                    crate::shell::macos::end_sheet(&sheet);
                }));
                rx.await.unwrap_or(false)
            } else {
                false
            };
            cx.update(|cx| crate::views::sheet::question_answered(asked, yes, cx));
            yes
        });
        (task, closer)
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = (window, spec);
        crate::views::sheet::question_answered(asked, false, cx);
        (Task::ready(false), closer)
    }
}
/// Harness: the titles of the sheets [`AutoAnswer`] answered, in order, so a
/// pass can tell what was asked.
#[cfg(feature = "harness")]
#[derive(Clone, Debug, Default)]
pub struct AutoAnswered(pub Vec<String>);

#[cfg(feature = "harness")]
impl gpui_kit::Global for AutoAnswered {}

/// Shows `spec` as a sheet on `window`; resolves with `true` when the user
/// confirmed.
pub fn present_sheet(window: &Window, spec: SheetSpec, cx: &mut App) -> Task<bool> {
    let asked = crate::views::sheet::question_shown(window.window_handle(), cx);
    if let Some(task) = held(window.window_handle(), asked, cx) {
        return task;
    }
    if let Some(answer) = cx.try_global::<AutoAnswer>().and_then(|a| a.0) {
        log::info!("sheet {:?} answered {answer} (auto)", spec.title);
        #[cfg(feature = "harness")]
        cx.default_global::<AutoAnswered>()
            .0
            .push(spec.title.clone());
        crate::views::sheet::question_answered(asked, answer, cx);
        return Task::ready(answer);
    }
    #[cfg(target_os = "macos")]
    {
        let Some(ns_window) = conduit_components::window::macos::ns_window(window) else {
            crate::views::sheet::question_answered(asked, false, cx);
            return Task::ready(false);
        };
        let token = hold_question(window.window_handle(), cx);
        cx.spawn(async move |cx| {
            let _token = token;
            // Outside any GPUI borrow: AppKit re-enters the window delegate.
            let yes = match macos::begin(&ns_window, &spec) {
                Some((rx, _)) => rx.await.unwrap_or(false),
                None => false,
            };
            cx.update(|cx| crate::views::sheet::question_answered(asked, yes, cx));
            yes
        })
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = (window, spec);
        crate::views::sheet::question_answered(asked, false, cx);
        Task::ready(false)
    }
}

#[cfg(target_os = "macos")]
mod macos {
    use std::cell::RefCell;

    use block2::RcBlock;
    use futures::channel::oneshot;
    use objc2::MainThreadMarker;
    use objc2::rc::Retained;
    use objc2_app_kit::{
        NSAlert, NSAlertFirstButtonReturn, NSAlertStyle, NSModalResponse, NSWindow,
    };
    use objc2_foundation::NSString;

    use super::SheetSpec;

    /// Starts the alert; the receiver gets the answer. With it, the alert's
    /// own window (which ends it unanswered).
    pub fn begin(
        window: &Retained<NSWindow>,
        spec: &SheetSpec,
    ) -> Option<(oneshot::Receiver<bool>, Retained<NSWindow>)> {
        let mtm = MainThreadMarker::new()?;
        let alert = NSAlert::new(mtm);
        alert.setMessageText(&NSString::from_str(&spec.title));
        alert.setInformativeText(&NSString::from_str(&spec.message));
        alert.setAlertStyle(if spec.destructive {
            NSAlertStyle::Warning
        } else {
            NSAlertStyle::Informational
        });
        let confirm = alert.addButtonWithTitle(&NSString::from_str(&spec.confirm));
        if spec.destructive {
            confirm.setHasDestructiveAction(true);
        }
        // Esc cancels; ↩ stays on the first button. A notice has no cancel.
        if !spec.cancel.is_empty() {
            let cancel = alert.addButtonWithTitle(&NSString::from_str(&spec.cancel));
            cancel.setKeyEquivalent(&NSString::from_str("\u{1b}"));
        }
        let (tx, rx) = oneshot::channel::<bool>();
        let tx = RefCell::new(Some(tx));
        // The block keeps the alert alive until it is answered.
        let keep = alert.clone();
        let handler = RcBlock::new(move |response: NSModalResponse| {
            let _ = &keep;
            if let Some(tx) = tx.borrow_mut().take() {
                let _ = tx.send(response == NSAlertFirstButtonReturn);
            }
        });
        alert.beginSheetModalForWindow_completionHandler(window, Some(&handler));
        Some((rx, alert.window()))
    }
}
