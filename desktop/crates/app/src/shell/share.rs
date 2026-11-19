//! The system Share menu (`NSSharingServicePicker`), for a message's text or
//! a chat's link, hung from where it was asked for, as Notes' and Safari's
//! Share buttons hang it.
//!
//! AppKit runs the picker's menu in its own tracking loop and calls back
//! into the window while it opens, so it is shown from a foreground task
//! between GPUI borrows (as the sheets are).

use gpui_kit::{App, Pixels, Point, Window};

/// What a share hands over: plain text, or a link (which services such as
/// Messages and Mail treat as one).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Shared {
    Text(String),
    Url(String),
}

/// Test hook: when set, shares are recorded here instead of shown (the E2E
/// pass checks what would have been shared).
#[derive(Clone, Debug, Default)]
pub struct ShareLog(pub std::rc::Rc<std::cell::RefCell<Vec<Shared>>>);

impl gpui_kit::Global for ShareLog {}

/// Shows the Share menu for `item` at `position` (window coordinates).
pub fn share(item: Shared, position: Point<Pixels>, window: &Window, cx: &mut App) {
    if let Some(log) = cx.try_global::<ShareLog>() {
        log::info!("share {item:?} (recorded)");
        log.0.borrow_mut().push(item);
        return;
    }
    #[cfg(target_os = "macos")]
    {
        let Some(ns_window) = conduit_components::window::macos::ns_window(window) else {
            return;
        };
        let (x, y) = (f64::from(position.x), f64::from(position.y));
        cx.foreground_executor()
            .spawn(async move { macos::show(&ns_window, item, x, y) })
            .detach();
    }
    #[cfg(not(target_os = "macos"))]
    let _ = (item, position, window);
}

#[cfg(target_os = "macos")]
mod macos {
    use objc2::rc::Retained;
    use objc2::runtime::AnyObject;
    use objc2::{AnyThread as _, MainThreadMarker};
    use objc2_app_kit::{NSSharingServicePicker, NSWindow};
    use objc2_foundation::{NSArray, NSPoint, NSRect, NSRectEdge, NSSize, NSString, NSURL};

    use super::Shared;

    /// Shows the picker from a point-sized rect at `(x, y)`, measured from
    /// the content view's top left.
    pub fn show(window: &Retained<NSWindow>, item: Shared, x: f64, y: f64) {
        let Some(_mtm) = MainThreadMarker::new() else {
            return;
        };
        let Some(view) = window.contentView() else {
            return;
        };
        let object: Retained<AnyObject> = match &item {
            Shared::Url(url) => match NSURL::URLWithString(&NSString::from_str(url)) {
                Some(u) => u.into_super().into(),
                None => NSString::from_str(url).into_super().into(),
            },
            Shared::Text(text) => NSString::from_str(text).into_super().into(),
        };
        let items = NSArray::from_retained_slice(&[object]);
        let picker = unsafe {
            NSSharingServicePicker::initWithItems(NSSharingServicePicker::alloc(), &items)
        };
        // GPUI's points run down from the top; a plain NSView's run up.
        let height = view.frame().size.height;
        let y = if view.isFlipped() { y } else { height - y };
        let rect = NSRect::new(NSPoint::new(x, y), NSSize::new(1., 1.));
        picker.showRelativeToRect_ofView_preferredEdge(rect, &view, NSRectEdge::MinY);
    }
}
