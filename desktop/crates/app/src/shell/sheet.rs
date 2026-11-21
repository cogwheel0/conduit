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
//!
//! With no AppKit window to attach a sheet to (Windows and Linux), the
//! question goes through GPUI's own prompt instead ([`ask_in_window`]):
//! Windows' task dialog, or one GPUI draws in the window on Linux.

use std::cell::RefCell;
use std::rc::{Rc, Weak};

use futures::FutureExt as _;
use futures::channel::oneshot;
use gpui_kit::{AnyWindowHandle, App, Global, PromptButton, PromptLevel, Task, Window};

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
    } else {
        #[cfg(target_os = "macos")]
        // SAFETY: AppKit's NSBeep takes nothing and may be called any time.
        unsafe {
            NSBeep();
        }
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
            let task = ask_in_window(
                window.window_handle(),
                spec,
                asked,
                Some(closer.clone()),
                cx,
            );
            return (task, closer);
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
        let task = ask_in_window(
            window.window_handle(),
            spec,
            asked,
            Some(closer.clone()),
            cx,
        );
        (task, closer)
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
            return ask_in_window(window.window_handle(), spec, asked, None, cx);
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
    ask_in_window(window.window_handle(), spec, asked, None, cx)
}

/// Asks `spec` through GPUI's prompt on `window`, started between GPUI
/// borrows as the AppKit sheet is; resolves with whether the first button
/// was chosen. A `closer` settles it as Cancel, but GPUI cannot take its
/// prompt down: it stays up until answered, and that answer is dropped.
fn ask_in_window(
    window: AnyWindowHandle,
    spec: SheetSpec,
    asked: Option<u64>,
    closer: Option<SheetCloser>,
    cx: &mut App,
) -> Task<bool> {
    let token = hold_question(window, cx);
    cx.spawn(async move |cx| {
        let _token = token;
        let level = if spec.destructive {
            PromptLevel::Warning
        } else {
            PromptLevel::Info
        };
        let mut buttons = vec![PromptButton::ok(spec.confirm.clone())];
        if !spec.cancel.is_empty() {
            buttons.push(PromptButton::cancel(spec.cancel.clone()));
        }
        let (closed_tx, closed) = oneshot::channel::<()>();
        let open = match &closer {
            Some(closer) if closer.is_closed() => false,
            Some(closer) => {
                closer.0.borrow_mut().end = Some(Box::new(move || {
                    let _ = closed_tx.send(());
                }));
                true
            }
            None => true,
        };
        let shown = open
            .then(|| {
                window
                    .update(cx, |_, window, cx| {
                        window.prompt(level, &spec.title, Some(&spec.message), &buttons, cx)
                    })
                    .map_err(|e| log::warn!("sheet {:?} not shown: {e}", spec.title))
                    .ok()
            })
            .flatten();
        let yes = match shown {
            Some(answer) => {
                // Only a close settles it: a closer dropped unused does not.
                let closed = async {
                    if closed.await.is_err() {
                        std::future::pending::<()>().await;
                    }
                };
                let chose = futures::select! {
                    answer = answer.fuse() => answer == Ok(0),
                    () = closed.fuse() => false,
                };
                // A close settles it at once, though its signal comes later:
                // an answer that won the race after it is still Cancel.
                chose && !closer.as_ref().is_some_and(SheetCloser::is_closed)
            }
            None => false,
        };
        cx.update(|cx| crate::views::sheet::question_answered(asked, yes, cx));
        yes
    })
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

#[cfg(test)]
mod tests {
    use std::cell::Cell;

    use gpui_kit::prelude::*;
    use gpui_kit::{Context, TestAppContext, VisualTestContext, div};

    use super::*;

    struct Blank;

    impl Render for Blank {
        fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
            div()
        }
    }

    fn ask(
        vcx: &mut VisualTestContext,
        closable: bool,
    ) -> (Rc<Cell<Option<bool>>>, Option<SheetCloser>) {
        let spec = SheetSpec::new(
            "Remove the account?",
            "Its chats leave this computer.",
            "Remove",
            "Cancel",
        )
        .destructive();
        let (task, closer) = vcx.update(|window, cx| {
            if closable {
                let (task, closer) = present_sheet_closable(window, spec, cx);
                (task, Some(closer))
            } else {
                (present_sheet(window, spec, cx), None)
            }
        });
        let answer = Rc::new(Cell::new(None));
        let seen = answer.clone();
        vcx.update(|_, cx| cx.spawn(async move |_| seen.set(Some(task.await))).detach());
        vcx.run_until_parked();
        (answer, closer)
    }

    /// With no native sheet to attach it to (Windows and Linux, or a window
    /// with no NSWindow), a question is still asked, through GPUI's own
    /// prompt, and takes the button chosen: it never answers Cancel unseen.
    #[gpui_kit::test]
    fn a_question_without_a_native_sheet_is_still_asked(cx: &mut TestAppContext) {
        cx.update(crate::views::test_globals);
        let (_, vcx) = cx.add_window_view(|_, _| Blank);
        for (closable, button, yes) in [
            (false, "Remove", true),
            (false, "Cancel", false),
            (true, "Remove", true),
            (true, "Cancel", false),
        ] {
            let (answer, _) = ask(vcx, closable);
            assert_eq!(answer.get(), None, "answered before it was asked");
            assert_eq!(
                vcx.pending_prompt(),
                Some((
                    "Remove the account?".to_string(),
                    "Its chats leave this computer.".to_string()
                ))
            );
            vcx.simulate_prompt_answer(button);
            vcx.run_until_parked();
            assert_eq!(answer.get(), Some(yes), "{button}");
            assert!(!vcx.has_pending_prompt());
        }

        // Settled somewhere else: Cancel. GPUI's prompt stays up until
        // answered, and that answer changes nothing.
        let (answer, closer) = ask(vcx, true);
        assert!(vcx.has_pending_prompt());
        vcx.update(|_, cx| closer.unwrap().close(cx));
        vcx.run_until_parked();
        assert_eq!(answer.get(), Some(false));
        vcx.simulate_prompt_answer("Remove");
        vcx.run_until_parked();
        assert_eq!(answer.get(), Some(false));

        // A confirmation that comes after the close, before anything ran
        // between them: still Cancel.
        let (answer, closer) = ask(vcx, true);
        vcx.update(|_, cx| closer.unwrap().close(cx));
        vcx.simulate_prompt_answer("Remove");
        vcx.run_until_parked();
        assert_eq!(answer.get(), Some(false), "confirmed after the close");
    }
}
