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

/// The windows brought forward whose injected Alt hasn't arrived yet, one
/// entry per activation: each injects an Alt of its own.
#[derive(Default)]
struct InjectedAlt(Vec<(AnyWindowHandle, Instant)>);

impl Global for InjectedAlt {}

/// Brings `window` forward (`Window::activate_window`), for every window
/// the app brings forward itself.
pub fn activate(window: &Window, cx: &mut App) {
    let (handle, now) = (window.window_handle(), Instant::now());
    let owed = &mut cx.default_global::<InjectedAlt>().0;
    owed.retain(|(_, at)| now.duration_since(*at) < INJECTED_ALT_WITHIN);
    owed.push((handle, now));
    window.activate_window();
}

/// `keystroke` reached `window`: whether it is the Alt one of that window's
/// activations injected (each lone Alt pays one). Any other key settles
/// them all: a key before them means their Alts went to another window.
pub fn is_injected_alt(window: AnyWindowHandle, keystroke: &Keystroke, cx: &mut App) -> bool {
    let owed = cx.try_global::<InjectedAlt>().and_then(|o| {
        o.0.iter()
            .position(|(h, at)| *h == window && at.elapsed() < INJECTED_ALT_WITHIN)
    });
    let Some(oldest) = owed else {
        return false;
    };
    let owed = &mut cx.global_mut::<InjectedAlt>().0;
    if keystroke.key == "alt" && keystroke.modifiers == Modifiers::default() {
        owed.remove(oldest);
        true
    } else {
        owed.retain(|(h, _)| *h != window);
        false
    }
}
