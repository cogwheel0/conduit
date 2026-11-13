//! The windows AppKit shows outside GPUI: Sparkle's update alert and
//! progress window, and its error alerts. For the release rehearsal's
//! update test (docs/RELEASING-DESKTOP.md), the probe ([`super::shell::probe`])
//! lists their titles, texts and buttons in `<file>.panels.json` and clicks
//! a button by its title (`press <title>` in `<file>.cmd`), as a person
//! would.
//!
//! Sparkle shows its errors with `-[NSAlert runModal]`, a modal run loop in
//! which GPUI's tasks do not run. So this side runs on a CoreFoundation
//! timer in the run loop's common modes, which modal loops include.

use std::ffi::c_void;
use std::path::PathBuf;

use objc2::rc::Retained;
use objc2::{DowncastTarget, MainThreadMarker, Message};
use objc2_app_kit::{NSApplication, NSButton, NSTextField, NSView, NSWindow};
use serde_json::{Value, json};

/// Starts the timer: every 300 ms it runs the `press` lines appended to
/// `commands` since the last tick and writes the panels to `panels`. It
/// lives as long as the app.
pub fn watch(commands: PathBuf, panels: PathBuf) {
    let watcher = Box::into_raw(Box::new(Watcher {
        commands,
        panels,
        done: 0,
    }));
    let mut context = CFRunLoopTimerContext {
        version: 0,
        info: watcher.cast(),
        retain: None,
        release: None,
        copy_description: None,
    };
    // SAFETY: CoreFoundation calls; the context is copied by
    // CFRunLoopTimerCreate, and `info` (the leaked watcher) outlives the
    // timer, which is never invalidated. The callback runs on the main run
    // loop only.
    unsafe {
        let timer = CFRunLoopTimerCreate(
            std::ptr::null(),
            CFAbsoluteTimeGetCurrent() + 0.3,
            0.3,
            0,
            0,
            tick,
            &mut context,
        );
        CFRunLoopAddTimer(CFRunLoopGetMain(), timer, kCFRunLoopCommonModes);
    }
}

struct Watcher {
    commands: PathBuf,
    panels: PathBuf,
    done: usize,
}

extern "C" fn tick(_timer: *mut c_void, info: *mut c_void) {
    // SAFETY: `info` is the watcher `watch` leaked; only this callback, on
    // the main thread, touches it.
    let watcher = unsafe { &mut *info.cast::<Watcher>() };
    let lines: Vec<String> = std::fs::read_to_string(&watcher.commands)
        .map(|s| s.lines().map(str::to_owned).collect())
        .unwrap_or_default();
    for line in lines.iter().skip(watcher.done) {
        if let Some(title) = line.trim().strip_prefix("press ") {
            log::info!("probe: press {title}");
            if !press(title) {
                log::warn!("probe: no button titled '{title}'");
            }
        }
    }
    watcher.done = watcher.done.max(lines.len());
    let listed = serde_json::to_vec_pretty(&list()).unwrap_or_default();
    std::fs::write(&watcher.panels, listed).ok();
}

/// The visible windows that have buttons (GPUI's have none): their
/// titles, texts and enabled buttons.
fn list() -> Vec<Value> {
    visible_windows()
        .into_iter()
        .filter_map(|window| {
            let mut buttons = Vec::new();
            let mut texts = Vec::new();
            if let Some(view) = window.contentView() {
                collect(&view, &mut buttons, &mut texts);
            }
            let buttons: Vec<String> = buttons.iter().map(|b| b.title().to_string()).collect();
            (!buttons.is_empty()).then(|| {
                json!({
                    "title": window.title().to_string(),
                    "texts": texts,
                    "buttons": buttons,
                })
            })
        })
        .collect()
}

/// Clicks the first enabled button titled `title` in a visible window;
/// whether there was one.
fn press(title: &str) -> bool {
    for window in visible_windows() {
        let mut buttons = Vec::new();
        if let Some(view) = window.contentView() {
            collect(&view, &mut buttons, &mut Vec::new());
        }
        if let Some(button) = buttons.into_iter().find(|b| b.title().to_string() == title) {
            // SAFETY: an AppKit control's click, on the main thread; the
            // sender may be nil.
            unsafe { button.performClick(None) };
            return true;
        }
    }
    false
}

fn visible_windows() -> Vec<Retained<NSWindow>> {
    let Some(mtm) = MainThreadMarker::new() else {
        return Vec::new();
    };
    NSApplication::sharedApplication(mtm)
        .windows()
        .iter()
        .filter(|w| w.isVisible())
        .collect()
}

fn collect(view: &NSView, buttons: &mut Vec<Retained<NSButton>>, texts: &mut Vec<String>) {
    if view.isHidden() {
        return;
    }
    if let Some(button) = downcast::<NSButton>(view) {
        if button.isEnabled() {
            buttons.push(button);
        }
    } else if let Some(field) = downcast::<NSTextField>(view) {
        let text = field.stringValue().to_string();
        if !text.trim().is_empty() {
            texts.push(text);
        }
    }
    for sub in view.subviews().iter() {
        collect(&sub, buttons, texts);
    }
}

fn downcast<T: DowncastTarget>(view: &NSView) -> Option<Retained<T>> {
    view.retain().downcast::<T>().ok()
}

#[repr(C)]
struct CFRunLoopTimerContext {
    version: isize,
    info: *mut c_void,
    retain: Option<extern "C" fn(*const c_void) -> *const c_void>,
    release: Option<extern "C" fn(*const c_void)>,
    copy_description: Option<extern "C" fn(*const c_void) -> *const c_void>,
}

#[link(name = "CoreFoundation", kind = "framework")]
unsafe extern "C" {
    static kCFRunLoopCommonModes: *const c_void;
    fn CFRunLoopGetMain() -> *mut c_void;
    fn CFAbsoluteTimeGetCurrent() -> f64;
    fn CFRunLoopTimerCreate(
        allocator: *const c_void,
        fire_date: f64,
        interval: f64,
        flags: usize,
        order: isize,
        callout: extern "C" fn(*mut c_void, *mut c_void),
        context: *mut CFRunLoopTimerContext,
    ) -> *mut c_void;
    fn CFRunLoopAddTimer(run_loop: *mut c_void, timer: *mut c_void, mode: *const c_void);
}
