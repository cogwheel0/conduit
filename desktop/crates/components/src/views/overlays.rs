//! Where a window's floating overlays (a tooltip, a drag image) were laid
//! out this frame, for a mask that fades a list's edges (the sidebar's on
//! the translucent material) to leave them whole: an overlay is drawn in
//! the same layer as the list, so the mask would fade it too.
//!
//! An overlay notes its card with [`overlay_marker`] while it is laid out;
//! the mask's owner takes what was noted with [`take_overlays`] when it
//! paints. GPUI lays out every overlay (tooltips, the active drag) before
//! it paints anything, so a frame's overlays are known by then.

use std::collections::HashMap;

use gpui_kit::prelude::*;
use gpui_kit::{App, Bounds, Global, Pixels, Window, WindowId, canvas};

/// More than any frame draws; a window nobody reads stops growing here.
const MOST: usize = 8;

#[derive(Default)]
struct OverlayRects(HashMap<WindowId, Vec<Bounds<Pixels>>>);

impl Global for OverlayRects {}

/// An element over an overlay's card (absolute, filling it) that notes
/// where the card is.
pub fn overlay_marker() -> impl IntoElement {
    canvas(
        |bounds, window, cx| {
            let id = window.window_handle().window_id();
            let rects = cx.default_global::<OverlayRects>().0.entry(id).or_default();
            if rects.len() < MOST {
                rects.push(bounds);
            }
        },
        |_, _, _, _| {},
    )
    .absolute()
    .top_0()
    .left_0()
    .size_full()
}

/// The overlays noted in `window` since the last call (window points).
pub fn take_overlays(window: &Window, cx: &mut App) -> Vec<Bounds<Pixels>> {
    let id = window.window_handle().window_id();
    cx.default_global::<OverlayRects>()
        .0
        .remove(&id)
        .unwrap_or_default()
}
