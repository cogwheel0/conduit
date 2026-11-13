//! Driving a window the way a person would, from inside the process:
//! synthetic mouse and key events dispatched straight into GPUI (the real
//! cursor never moves), and the window's AccessKit tree to find controls by
//! role and label, see where they are and what has focus.

use std::time::Duration;

use conduit_components::capture;
use conduit_components::window as cw;
use gpui_kit::{
    AnyWindowHandle, AsyncApp, Bounds, Keystroke, Modifiers, MouseButton, MouseDownEvent,
    MouseMoveEvent, MouseUpEvent, OperatingSystem, Pixels, PlatformInput, Point, point, px, size,
};
use serde_json::Value;

/// One AccessKit node, as the debug dump has it.
#[derive(Clone, Debug, Default)]
pub struct Node {
    pub role: String,
    pub label: String,
    pub value: String,
    /// Window-relative, logical pixels.
    pub bounds: Option<Bounds<Pixels>>,
    pub focused: bool,
    /// The focused list's highlighted option (AccessKit's active
    /// descendant).
    pub active: bool,
    pub toggled: Option<String>,
    pub selected: Option<bool>,
    pub expanded: Option<bool>,
    pub shortcut: Option<String>,
}

impl Node {
    pub fn center(&self) -> Option<Point<Pixels>> {
        self.bounds.map(|b| b.center())
    }

    /// `role:label`, as notes list controls.
    pub fn describe(&self) -> String {
        if self.label.is_empty() {
            format!("{} (no label)", self.role)
        } else {
            format!("{} \u{201c}{}\u{201d}", self.role, self.label)
        }
    }

    /// A small square button: an icon-only control.
    pub fn is_icon_button(&self) -> bool {
        self.role == "Button"
            && self.bounds.is_some_and(|b| {
                let (w, h) = (f32::from(b.size.width), f32::from(b.size.height));
                w <= 40. && h <= 40. && (w - h).abs() <= 6. && w >= 12.
            })
    }
}

/// Activates accessibility on the window (as an assistive app connecting
/// does), so GPUI builds the AccessKit tree each frame.
pub fn activate(handle: AnyWindowHandle, cx: &mut AsyncApp) {
    let ptr = cx.update(|cx| {
        handle
            .update(cx, |_, window, _| cw::macos::ns_window_ptr(window))
            .ok()
            .flatten()
    });
    if let Some(ptr) = ptr {
        // SAFETY: this process's live NSWindow, on the main thread.
        unsafe { capture::activate_accessibility(ptr) };
    }
}

async fn pause(cx: &mut AsyncApp, ms: u64) {
    cx.background_executor()
        .timer(Duration::from_millis(ms))
        .await;
}

/// The window's AccessKit nodes after the next frame.
pub async fn nodes(handle: AnyWindowHandle, cx: &mut AsyncApp) -> Vec<Node> {
    activate(handle, cx);
    let mut tree = None;
    for attempt in 0..12 {
        pause(cx, if attempt == 0 { 80 } else { 150 }).await;
        tree = cx.update(|cx| {
            handle
                .update(cx, |_, window, _| {
                    window.refresh();
                    window.debug_a11y_tree_json()
                })
                .ok()
                .flatten()
        });
        if tree.as_ref().is_some_and(|t| t.contains("\"bounds\"")) {
            break;
        }
    }
    // One more frame so the tree reflects the refresh just asked for.
    pause(cx, 60).await;
    let tree = cx
        .update(|cx| {
            handle
                .update(cx, |_, window, _| window.debug_a11y_tree_json())
                .ok()
                .flatten()
        })
        .or(tree);
    tree.map(|t| parse(&t)).unwrap_or_default()
}

/// Parses the debug dump.
pub fn parse(json: &str) -> Vec<Node> {
    let Ok(tree) = serde_json::from_str::<Value>(json) else {
        return vec![];
    };
    let scale = tree
        .pointer("/frame/scale_factor")
        .and_then(Value::as_f64)
        .unwrap_or(2.)
        .max(1.);
    let focus = tree
        .get("gpui_focus")
        .and_then(Value::as_str)
        .map(str::to_string);
    let active = tree
        .get("active_descendant_focus")
        .and_then(Value::as_str)
        .map(str::to_string);
    let Some(nodes) = tree.get("nodes").and_then(Value::as_object) else {
        return vec![];
    };
    // Children order: walk from the root so the list is in document order.
    let root = tree.get("root").and_then(Value::as_str).unwrap_or_default();
    let mut order = vec![];
    let mut stack = vec![root.to_string()];
    while let Some(id) = stack.pop() {
        let Some(node) = nodes.get(&id) else { continue };
        order.push(id.clone());
        if let Some(children) = node.get("children").and_then(Value::as_array) {
            for c in children.iter().rev() {
                if let Some(c) = c.as_str() {
                    stack.push(c.to_string());
                }
            }
        }
    }
    order
        .into_iter()
        .filter_map(|id| {
            let node = nodes.get(&id)?;
            let aria = node.get("aria").cloned().unwrap_or(Value::Null);
            let s = |k: &str| aria.get(k).and_then(Value::as_str).map(str::to_string);
            let bounds = node.get("bounds").and_then(Value::as_array).and_then(|b| {
                let v: Vec<f64> = b.iter().filter_map(Value::as_f64).collect();
                (v.len() == 4).then(|| {
                    Bounds::new(
                        point(px((v[0] / scale) as f32), px((v[1] / scale) as f32)),
                        size(
                            px(((v[2] - v[0]) / scale) as f32),
                            px(((v[3] - v[1]) / scale) as f32),
                        ),
                    )
                })
            });
            Some(Node {
                role: s("role").unwrap_or_default(),
                label: s("label").unwrap_or_default().trim().to_string(),
                value: s("value").unwrap_or_default(),
                bounds,
                focused: focus.as_deref() == Some(id.as_str()),
                active: active.as_deref() == Some(id.as_str()),
                toggled: s("toggled"),
                selected: aria.get("selected").and_then(Value::as_bool),
                expanded: aria.get("expanded").and_then(Value::as_bool),
                shortcut: s("keyboard_shortcut"),
            })
        })
        .collect()
}

/// The first node with `role` whose label passes `label`.
pub fn find<'a>(nodes: &'a [Node], role: &str, label: impl Fn(&str) -> bool) -> Option<&'a Node> {
    nodes
        .iter()
        .find(|n| n.role == role && n.bounds.is_some() && label(&n.label))
}

/// The highlighted option of the focused list, if any.
pub fn active(nodes: &[Node]) -> Option<&Node> {
    nodes.iter().find(|n| n.active)
}

/// The focused node, if the tree has one.
pub fn focused(nodes: &[Node]) -> Option<&Node> {
    nodes.iter().find(|n| n.focused)
}

fn dispatch(handle: AnyWindowHandle, event: PlatformInput, cx: &mut AsyncApp) {
    cx.update(|cx| {
        let _ = handle.update(cx, |_, window, cx| {
            window.dispatch_event(event, cx);
        });
    });
}

/// Moves the (synthetic) pointer to `at`, window-relative.
pub fn hover(handle: AnyWindowHandle, at: Point<Pixels>, cx: &mut AsyncApp) {
    dispatch(
        handle,
        PlatformInput::MouseMove(MouseMoveEvent {
            position: at,
            pressed_button: None,
            modifiers: Modifiers::default(),
        }),
        cx,
    );
}

/// Moves the pointer off every control (to the window's top-left corner,
/// over the toolbar's empty drag area).
pub fn unhover(handle: AnyWindowHandle, cx: &mut AsyncApp) {
    hover(handle, point(px(2.), px(2.)), cx);
}

pub fn press(handle: AnyWindowHandle, at: Point<Pixels>, button: MouseButton, cx: &mut AsyncApp) {
    dispatch(
        handle,
        PlatformInput::MouseDown(MouseDownEvent {
            button,
            position: at,
            modifiers: Modifiers::default(),
            click_count: 1,
            first_mouse: false,
        }),
        cx,
    );
}

pub fn release(handle: AnyWindowHandle, at: Point<Pixels>, button: MouseButton, cx: &mut AsyncApp) {
    dispatch(
        handle,
        PlatformInput::MouseUp(MouseUpEvent {
            button,
            position: at,
            modifiers: Modifiers::default(),
            click_count: 1,
        }),
        cx,
    );
}

/// A drag in progress: the left button held, moved to `at`.
pub fn drag_to(handle: AnyWindowHandle, at: Point<Pixels>, cx: &mut AsyncApp) {
    dispatch(
        handle,
        PlatformInput::MouseMove(MouseMoveEvent {
            position: at,
            pressed_button: Some(MouseButton::Left),
            modifiers: Modifiers::default(),
        }),
        cx,
    );
}

/// A click with keys held (⌘-click, ⇧-click): hover, press, release.
pub async fn click_with(
    handle: AnyWindowHandle,
    at: Point<Pixels>,
    modifiers: Modifiers,
    cx: &mut AsyncApp,
) {
    hover(handle, at, cx);
    pause(cx, 40).await;
    dispatch(
        handle,
        PlatformInput::MouseDown(MouseDownEvent {
            button: MouseButton::Left,
            position: at,
            modifiers,
            click_count: 1,
            first_mouse: false,
        }),
        cx,
    );
    pause(cx, 40).await;
    dispatch(
        handle,
        PlatformInput::MouseUp(MouseUpEvent {
            button: MouseButton::Left,
            position: at,
            modifiers,
            click_count: 1,
        }),
        cx,
    );
}

/// A scroll wheel's turn of `dy` points at `at` (positive scrolls down).
pub fn scroll(handle: AnyWindowHandle, at: Point<Pixels>, dy: f32, cx: &mut AsyncApp) {
    dispatch(
        handle,
        PlatformInput::Scroll(gpui_kit::ScrollEvent {
            position: at,
            delta: gpui_kit::ScrollDelta::Pixels(point(px(0.), px(-dy))),
            modifiers: Modifiers::default(),
            touch_phase: gpui_kit::TouchPhase::Moved,
            source: Default::default(),
        }),
        cx,
    );
}

/// A click: hover, press, release.
pub async fn click(handle: AnyWindowHandle, at: Point<Pixels>, cx: &mut AsyncApp) {
    hover(handle, at, cx);
    pause(cx, 40).await;
    press(handle, at, MouseButton::Left, cx);
    pause(cx, 40).await;
    release(handle, at, MouseButton::Left, cx);
}

/// Types a keystroke (`tab`, `shift-tab`, `down`, `escape`, `cmd-k`) as
/// the keyboard would; bindings and focus handling see it as real.
pub fn key(handle: AnyWindowHandle, stroke: &str, cx: &mut AsyncApp) {
    let Ok(keystroke) = Keystroke::parse_with_os(stroke, OperatingSystem::Mac) else {
        log::warn!("capture: bad keystroke {stroke}");
        return;
    };
    cx.update(|cx| {
        let _ = handle.update(cx, |_, window, cx| {
            window.dispatch_keystroke(keystroke, cx);
        });
    });
}
