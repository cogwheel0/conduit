//! Bringing one of the app's windows forward.
//!
//! GPUI on Windows wins the foreground for a window by injecting an Alt
//! press and release (`SendInput`), which reaches the window as a lone Alt:
//! the key that opens ☰. So the app brings its windows forward through
//! [`activate`], which marks the window as owed that Alt, and ☰ takes the
//! first lone Alt after it as the activation's ([`is_injected_alt`]).

use std::time::{Duration, Instant};

use gpui_kit::{AnyWindowHandle, App, Global, Keystroke, Modifiers, Window};

/// How long after an activation its Alt may still arrive: the activation
/// runs from a task, and a window just opened may draw first.
pub const INJECTED_ALT_WITHIN: Duration = Duration::from_secs(3);

/// The windows brought forward whose injected Alt hasn't arrived yet.
#[derive(Default)]
struct InjectedAlt(Vec<(AnyWindowHandle, Instant)>);

impl Global for InjectedAlt {}

/// Brings `window` forward (`Window::activate_window`), for every window
/// the app brings forward itself.
pub fn activate(window: &Window, cx: &mut App) {
    let (handle, now) = (window.window_handle(), Instant::now());
    let owed = &mut cx.default_global::<InjectedAlt>().0;
    owed.retain(|(h, at)| *h != handle && now.duration_since(*at) < INJECTED_ALT_WITHIN);
    owed.push((handle, now));
    window.activate_window();
}

/// `keystroke` reached `window`: whether it is the Alt an activation of
/// that window injected. Its first keystroke settles it either way: a key
/// before the Alt means the activation's Alt went to another window.
pub fn is_injected_alt(window: AnyWindowHandle, keystroke: &Keystroke, cx: &mut App) -> bool {
    let owed = cx
        .try_global::<InjectedAlt>()
        .and_then(|o| o.0.iter().find(|(h, _)| *h == window).map(|(_, at)| *at));
    let Some(at) = owed else {
        return false;
    };
    cx.global_mut::<InjectedAlt>()
        .0
        .retain(|(h, _)| *h != window);
    let lone_alt = keystroke.key == "alt" && keystroke.modifiers == Modifiers::default();
    lone_alt && at.elapsed() < INJECTED_ALT_WITHIN
}
