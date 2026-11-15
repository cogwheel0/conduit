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
use std::rc::Rc;

use gpui_kit::{App, Task, Window};

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
    if let Some(answer) = cx.try_global::<AutoAnswer>().and_then(|a| a.0) {
        log::info!("sheet {:?} answered {answer} (auto)", spec.title);
        return (Task::ready(answer), closer);
    }
    #[cfg(target_os = "macos")]
    {
        let Some(ns_window) = conduit_components::window::macos::ns_window(window) else {
            return (Task::ready(false), closer);
        };
        let state = closer.clone();
        let task = cx.spawn(async move |_| {
            if state.is_closed() {
                return false;
            }
            let Some((rx, sheet)) = macos::begin(&ns_window, &spec) else {
                return false;
            };
            state.0.borrow_mut().end = Some(Box::new(move || {
                crate::shell::macos::end_sheet(&sheet);
            }));
            rx.await.unwrap_or(false)
        });
        (task, closer)
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = (window, spec);
        (Task::ready(false), closer)
    }
}

/// Shows `spec` as a sheet on `window`; resolves with `true` when the user
/// confirmed.
pub fn present_sheet(window: &Window, spec: SheetSpec, cx: &mut App) -> Task<bool> {
    if let Some(answer) = cx.try_global::<AutoAnswer>().and_then(|a| a.0) {
        log::info!("sheet {:?} answered {answer} (auto)", spec.title);
        return Task::ready(answer);
    }
    #[cfg(target_os = "macos")]
    {
        let Some(ns_window) = conduit_components::window::macos::ns_window(window) else {
            return Task::ready(false);
        };
        cx.spawn(async move |_| {
            // Outside any GPUI borrow: AppKit re-enters the window delegate.
            match macos::begin(&ns_window, &spec) {
                Some((rx, _)) => rx.await.unwrap_or(false),
                None => false,
            }
        })
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = (window, spec);
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
