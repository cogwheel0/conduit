//! The window's own controls, the headers' drag areas, and GNOME's
//! client-side frame.

use std::rc::Rc;

use gpui_kit::prelude::*;
use gpui_kit::{
    AnyElement, App, BoxShadow, ClickEvent, CursorStyle, Decorations, DispatchPhase, ElementId,
    Hsla, MouseButton, MouseMoveEvent, MouseUpEvent, Pixels, Point, ResizeEdge, Role, SharedString,
    Size, Stateful, Tiling, Window, WindowControlArea, canvas, div, point, px, rgb,
};

use super::ChromeStyle;
use super::layout::{
    CAPTION_BUTTON_WIDTH, Corners, GNOME_CONTROL, GNOME_CONTROL_STEP, WindowButton,
};
use crate::assets::{IconName, icon};
use crate::theme::{ActiveConduitTheme, with_alpha};
use crate::window::{TOOLBAR_HEIGHT, drag_region};

/// What closing the window does (the app's Close Window); without one the
/// window goes.
pub type OnClose = Rc<dyn Fn(&ClickEvent, &mut Window, &mut App)>;

/// The window controls' accessible names.
#[derive(Clone, Debug, PartialEq)]
pub struct ControlLabels {
    pub minimize: SharedString,
    pub maximize: SharedString,
    pub restore: SharedString,
    pub close: SharedString,
}

/// A row of window controls: Windows' caption buttons, or GNOME's round
/// ones.
#[derive(IntoElement)]
pub struct WindowControls {
    style: ChromeStyle,
    buttons: Vec<WindowButton>,
    maximized: bool,
    labels: ControlLabels,
    on_close: Option<OnClose>,
}

impl WindowControls {
    pub fn new(
        style: ChromeStyle,
        buttons: Vec<WindowButton>,
        maximized: bool,
        labels: ControlLabels,
    ) -> Self {
        Self {
            style,
            buttons,
            maximized,
            labels,
            on_close: None,
        }
    }

    pub fn on_close(mut self, on_close: Option<OnClose>) -> Self {
        self.on_close = on_close;
        self
    }
}

impl RenderOnce for WindowControls {
    fn render(self, _: &mut Window, cx: &mut App) -> impl IntoElement {
        let t = cx.conduit().clone();
        let r = t.roles;
        let maximized = self.maximized;
        let labels = self.labels.clone();
        let on_close = self.on_close.clone();
        div()
            .id(ElementId::Name(
                format!("window-controls-{:?}", self.buttons.first()).into(),
            ))
            .flex()
            .flex_none()
            .items_center()
            .h(px(TOOLBAR_HEIGHT))
            .when(self.style == ChromeStyle::Gnome, |d| {
                d.gap(px(GNOME_CONTROL_STEP - GNOME_CONTROL))
            })
            .children(self.buttons.into_iter().map(move |button| {
                let (glyph, label) = match button {
                    WindowButton::Minimize => (IconName::WindowMinimize, labels.minimize.clone()),
                    WindowButton::Maximize if maximized => {
                        (IconName::WindowRestore, labels.restore.clone())
                    }
                    WindowButton::Maximize => (IconName::WindowMaximize, labels.maximize.clone()),
                    WindowButton::Close => (IconName::WindowClose, labels.close.clone()),
                };
                let id = ElementId::Name(format!("window-{button:?}").to_lowercase().into());
                let base = div()
                    .id(id)
                    .role(Role::Button)
                    .aria_label(label)
                    .occlude()
                    .flex()
                    .flex_none()
                    .items_center()
                    .justify_center();
                match self.style {
                    // Windows answers the press itself (HTMINBUTTON and the
                    // rest): Max brings Windows 11's snap layouts.
                    ChromeStyle::Windows => {
                        let close = button == WindowButton::Close;
                        let (hover, hover_fg) = if close {
                            (rgb(0xc42b1c).into(), gpui_kit::white())
                        } else {
                            (with_alpha(r.text, if t.dark { 0.06 } else { 0.04 }), r.text)
                        };
                        let on_close = on_close.clone();
                        base.w(px(CAPTION_BUTTON_WIDTH))
                            .h_full()
                            .window_control_area(match button {
                                WindowButton::Minimize => WindowControlArea::Min,
                                WindowButton::Maximize => WindowControlArea::Max,
                                WindowButton::Close => WindowControlArea::Close,
                            })
                            .text_color(r.text)
                            .hover(move |s| s.bg(hover).text_color(hover_fg))
                            // Windows answers a pointer's press itself (the control
                            // areas); a screen reader's press comes here.
                            .on_click(move |e, window, cx| {
                                act(
                                    control_press(button, maximized),
                                    on_close.as_ref(),
                                    e,
                                    window,
                                    cx,
                                )
                            })
                            .child(icon(glyph, 10., r.text))
                            .into_any_element()
                    }
                    ChromeStyle::Gnome => {
                        let on_close = on_close.clone();
                        base.size(px(GNOME_CONTROL))
                            .rounded_full()
                            .bg(with_alpha(r.text, if t.dark { 0.10 } else { 0.08 }))
                            .hover(|s| s.bg(with_alpha(r.text, if t.dark { 0.15 } else { 0.12 })))
                            .active(|s| s.bg(with_alpha(r.text, if t.dark { 0.20 } else { 0.16 })))
                            // Not a press on the header behind it.
                            .on_mouse_down(MouseButton::Left, |_, window, cx| {
                                window.prevent_default();
                                cx.stop_propagation();
                            })
                            .on_click(move |e, window, cx| {
                                cx.stop_propagation();
                                act(
                                    control_press(button, maximized),
                                    on_close.as_ref(),
                                    e,
                                    window,
                                    cx,
                                )
                            })
                            .child(icon(glyph, 12., r.text))
                            .into_any_element()
                    }
                }
            }))
    }
}

/// What a press on a window control does.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ControlPress {
    Minimize,
    Maximize,
    Restore,
    Close,
}

/// The press on `button`, with the window `maximized` or not.
pub fn control_press(button: WindowButton, maximized: bool) -> ControlPress {
    match button {
        WindowButton::Minimize => ControlPress::Minimize,
        WindowButton::Maximize if maximized => ControlPress::Restore,
        WindowButton::Maximize => ControlPress::Maximize,
        WindowButton::Close => ControlPress::Close,
    }
}

/// Does `press` to the window (`on_close` stands in for closing it).
fn act(
    press: ControlPress,
    on_close: Option<&OnClose>,
    e: &ClickEvent,
    window: &mut Window,
    cx: &mut App,
) {
    match press {
        ControlPress::Minimize => window.minimize_window(),
        ControlPress::Maximize => window.zoom_window(),
        ControlPress::Restore => restore(window),
        ControlPress::Close => match on_close {
            Some(f) => f(e, window, cx),
            None => window.remove_window(),
        },
    }
}

/// Restores a maximized window. On Linux GPUI's zoom toggles; on Windows it
/// only maximizes, so Windows restores it.
fn restore(window: &mut Window) {
    #[cfg(target_os = "windows")]
    if restore_hwnd(window) {
        return;
    }
    window.zoom_window();
}

#[cfg(target_os = "windows")]
fn restore_hwnd(window: &Window) -> bool {
    use raw_window_handle::{HasWindowHandle, RawWindowHandle};
    use windows::Win32::Foundation::HWND;
    use windows::Win32::UI::WindowsAndMessaging::{SW_RESTORE, ShowWindowAsync};
    let Ok(handle) = HasWindowHandle::window_handle(window) else {
        return false;
    };
    let RawWindowHandle::Win32(win32) = handle.as_raw() else {
        return false;
    };
    // SAFETY: GPUI hands out its own live window's HWND.
    let _ = unsafe { ShowWindowAsync(HWND(win32.hwnd.get() as *mut _), SW_RESTORE) };
    true
}

/// How far a header press must travel before it moves the window, as GTK
/// waits for a drag before taking it from a button.
const DRAG_THRESHOLD: f32 = 4.;

/// A header the window is dragged by, as each OS does it:
/// * Windows: a caption area (HTCAPTION), so Windows drags, snaps,
///   maximizes on double-click and offers Alt+Space's menu itself. Controls
///   inside must [`occlude`](gpui_kit::InteractiveElement::occlude) it, or
///   their presses go to the caption.
/// * GNOME: a drag once the pointer moves with the button down, double-click
///   to maximize, and the window manager's menu on a right-click.
/// * The Mac (no style): [`drag_region`].
pub fn header_drag(
    id: &'static str,
    style: Option<ChromeStyle>,
    window: &mut Window,
    cx: &mut App,
) -> Stateful<gpui_kit::Div> {
    match style {
        None => drag_region(id),
        Some(ChromeStyle::Windows) => div().id(id).window_control_area(WindowControlArea::Drag),
        Some(ChromeStyle::Gnome) => {
            let pressed = window.use_keyed_state(
                ElementId::Name(format!("{id}-press").into()),
                cx,
                |_, _| None::<Point<Pixels>>,
            );
            let armed = pressed.read(cx).is_some();
            let down = pressed.clone();
            div()
                .id(id)
                .on_mouse_down(MouseButton::Left, move |e, window, cx| {
                    if e.click_count >= 2 {
                        window.zoom_window();
                    } else {
                        let at = e.position;
                        down.update(cx, |p, cx| {
                            *p = Some(at);
                            cx.notify();
                        });
                    }
                })
                .on_mouse_down(MouseButton::Right, |e, window, _| {
                    window.show_window_menu(e.position)
                })
                // Once pressed, the drag is followed over the whole window:
                // the first move may already have left the header.
                .when(armed, |d| {
                    d.child(
                        canvas(
                            |_, _, _| {},
                            move |_, _, window, _| follow_press(&pressed, window),
                        )
                        .absolute()
                        .size_0(),
                    )
                })
        }
    }
}

/// Moves the window once a header press travels past the threshold,
/// wherever the pointer goes; a release anywhere ends the wait.
fn follow_press(pressed: &gpui_kit::Entity<Option<Point<Pixels>>>, window: &mut Window) {
    let moved = pressed.clone();
    window.on_mouse_event(move |e: &MouseMoveEvent, phase, window, cx| {
        if phase != DispatchPhase::Bubble {
            return;
        }
        let Some(at) = *moved.read(cx) else {
            return;
        };
        let lifted = e.pressed_button != Some(MouseButton::Left);
        let travelled = (e.position - at).magnitude() as f32 >= DRAG_THRESHOLD;
        if lifted || travelled {
            moved.update(cx, |p, cx| {
                *p = None;
                cx.notify();
            });
        }
        if !lifted && travelled {
            window.start_window_move();
        }
    });
    let up = pressed.clone();
    window.on_mouse_event(move |e: &MouseUpEvent, phase, _, cx| {
        if phase == DispatchPhase::Bubble && e.button == MouseButton::Left {
            up.update(cx, |p, cx| {
                *p = None;
                cx.notify();
            });
        }
    });
}

/// GNOME's shadow reach around a floating window (GPUI Kit's).
pub const SHADOW: f32 = 20.;
/// Half the width of the band a resize starts in, either side of the edge.
const RESIZE_BAND: f32 = 5.;

/// The visible window's inset from the surface on each side: the shadow,
/// except along a tiled edge.
pub fn frame_insets(tiling: Tiling) -> gpui_kit::Edges<f32> {
    let side = |tiled: bool| if tiled { 0. } else { SHADOW };
    gpui_kit::Edges {
        top: side(tiling.top),
        right: side(tiling.right),
        bottom: side(tiling.bottom),
        left: side(tiling.left),
    }
}

/// The edge a press at `at` resizes from, on a `size` surface whose window
/// sits `insets` in: within the band either side of the visible edge, a
/// corner where two meet; none along a tiled edge.
pub fn resize_edge(
    at: Point<f32>,
    size: Size<f32>,
    insets: gpui_kit::Edges<f32>,
    tiling: Tiling,
) -> Option<ResizeEdge> {
    let near = |pos: f32, edge: f32| (pos - edge).abs() <= RESIZE_BAND;
    let left = !tiling.left && (at.x < insets.left || near(at.x, insets.left));
    let right = !tiling.right
        && (at.x > size.width - insets.right || near(at.x, size.width - insets.right));
    let top = !tiling.top && (at.y < insets.top || near(at.y, insets.top));
    let bottom = !tiling.bottom
        && (at.y > size.height - insets.bottom || near(at.y, size.height - insets.bottom));
    match (top, bottom, left, right) {
        (true, _, true, _) => Some(ResizeEdge::TopLeft),
        (true, _, _, true) => Some(ResizeEdge::TopRight),
        (_, true, true, _) => Some(ResizeEdge::BottomLeft),
        (_, true, _, true) => Some(ResizeEdge::BottomRight),
        (true, ..) => Some(ResizeEdge::Top),
        (_, true, ..) => Some(ResizeEdge::Bottom),
        (_, _, true, _) => Some(ResizeEdge::Left),
        (_, _, _, true) => Some(ResizeEdge::Right),
        _ => None,
    }
}

fn cursor(edge: ResizeEdge) -> CursorStyle {
    match edge {
        ResizeEdge::Top | ResizeEdge::Bottom => CursorStyle::ResizeUpDown,
        ResizeEdge::Left | ResizeEdge::Right => CursorStyle::ResizeLeftRight,
        ResizeEdge::TopLeft | ResizeEdge::BottomRight => CursorStyle::ResizeUpLeftDownRight,
        ResizeEdge::TopRight | ResizeEdge::BottomLeft => CursorStyle::ResizeUpRightDownLeft,
    }
}

/// GNOME's client-side frame around the window's content: the shadow and
/// the resize edges outside it, a hairline at its edge and the rounded
/// corners ([`Corners::of`]). Under the window manager's frame, or on
/// Windows, it is just the content.
#[derive(IntoElement)]
pub struct ClientFrame {
    style: ChromeStyle,
    decorations: Decorations,
    maximized: bool,
    active: bool,
    content: AnyElement,
}

impl ClientFrame {
    pub fn new(
        style: ChromeStyle,
        decorations: Decorations,
        maximized: bool,
        active: bool,
        content: impl IntoElement,
    ) -> Self {
        Self {
            style,
            decorations,
            maximized,
            active,
            content: content.into_any_element(),
        }
    }
}

impl RenderOnce for ClientFrame {
    fn render(self, window: &mut Window, cx: &mut App) -> impl IntoElement {
        let Decorations::Client { tiling } = self.decorations else {
            return div().size_full().child(self.content).into_any_element();
        };
        if self.style != ChromeStyle::Gnome {
            return div().size_full().child(self.content).into_any_element();
        }
        let t = cx.conduit().clone();
        let corners = Corners::of(self.style, self.decorations, self.maximized);
        let tiling = if self.maximized {
            Tiling::tiled()
        } else {
            tiling
        };
        let insets = frame_insets(tiling);
        // The platform keeps the full shadow as the surface's inset even
        // while tiled, or the first resize after tiling grows the window.
        window.set_client_inset(px(SHADOW));
        let edge_color: Hsla = if t.dark {
            with_alpha(gpui_kit::white(), 0.10)
        } else {
            with_alpha(gpui_kit::black(), 0.14)
        };
        let shadow_alpha = if self.active { 0.24 } else { 0.12 };
        div()
            .id("client-frame")
            .size_full()
            .bg(gpui_kit::transparent_black())
            .pt(px(insets.top))
            .pr(px(insets.right))
            .pb(px(insets.bottom))
            .pl(px(insets.left))
            .relative()
            .on_mouse_down(MouseButton::Left, move |e, window, _| {
                if !window.is_resizable() {
                    return;
                }
                let size = window.window_bounds().get_bounds().size;
                let at = point(f32::from(e.position.x), f32::from(e.position.y));
                let size = Size {
                    width: f32::from(size.width),
                    height: f32::from(size.height),
                };
                if let Some(edge) = resize_edge(at, size, insets, tiling) {
                    window.start_window_resize(edge);
                }
            })
            .child(
                div()
                    .size_full()
                    .relative()
                    .rounded_tl(px(corners.top_left))
                    .rounded_tr(px(corners.top_right))
                    .rounded_br(px(corners.bottom_right))
                    .rounded_bl(px(corners.bottom_left))
                    .when(!tiling.is_tiled(), |d| {
                        d.shadow(vec![
                            BoxShadow {
                                color: with_alpha(gpui_kit::black(), shadow_alpha),
                                offset: point(px(0.), px(3.)),
                                blur_radius: px(12.),
                                spread_radius: px(-1.),
                                inset: false,
                            },
                            BoxShadow {
                                color: with_alpha(gpui_kit::black(), 0.08),
                                offset: point(px(0.), px(0.)),
                                blur_radius: px(1.),
                                spread_radius: px(1.),
                                inset: false,
                            },
                        ])
                    })
                    .child(self.content)
                    // The hairline over the content's edge, as libadwaita
                    // draws a window's outline.
                    .child(
                        div()
                            .absolute()
                            .inset_0()
                            .rounded_tl(px(corners.top_left))
                            .rounded_tr(px(corners.top_right))
                            .rounded_br(px(corners.bottom_right))
                            .rounded_bl(px(corners.bottom_left))
                            .border_1()
                            .border_color(edge_color),
                    ),
            )
            .children(resize_bands(insets, tiling))
            .into_any_element()
    }
}

/// The resize cursor over each untiled edge and corner, out to the band
/// inside the window; drawn over the content, so its cursor shows there.
fn resize_bands(insets: gpui_kit::Edges<f32>, tiling: Tiling) -> impl Iterator<Item = AnyElement> {
    let band = move |edge: ResizeEdge| {
        let (top, left) = (insets.top + RESIZE_BAND, insets.left + RESIZE_BAND);
        let (bottom, right) = (insets.bottom + RESIZE_BAND, insets.right + RESIZE_BAND);
        let d = div().absolute().cursor(cursor(edge));
        match edge {
            ResizeEdge::Top => d.top_0().left_0().right_0().h(px(top)),
            ResizeEdge::Bottom => d.bottom_0().left_0().right_0().h(px(bottom)),
            ResizeEdge::Left => d.left_0().top_0().bottom_0().w(px(left)),
            ResizeEdge::Right => d.right_0().top_0().bottom_0().w(px(right)),
            ResizeEdge::TopLeft => d.top_0().left_0().w(px(left)).h(px(top)),
            ResizeEdge::TopRight => d.top_0().right_0().w(px(right)).h(px(top)),
            ResizeEdge::BottomLeft => d.bottom_0().left_0().w(px(left)).h(px(bottom)),
            ResizeEdge::BottomRight => d.bottom_0().right_0().w(px(right)).h(px(bottom)),
        }
        .into_any_element()
    };
    let edges = [
        (ResizeEdge::Top, !tiling.top),
        (ResizeEdge::Bottom, !tiling.bottom),
        (ResizeEdge::Left, !tiling.left),
        (ResizeEdge::Right, !tiling.right),
        (ResizeEdge::TopLeft, !tiling.top && !tiling.left),
        (ResizeEdge::TopRight, !tiling.top && !tiling.right),
        (ResizeEdge::BottomLeft, !tiling.bottom && !tiling.left),
        (ResizeEdge::BottomRight, !tiling.bottom && !tiling.right),
    ];
    edges
        .into_iter()
        .filter(|(_, shown)| *shown)
        .map(move |(edge, _)| band(edge))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn size() -> Size<f32> {
        Size {
            width: 1000.,
            height: 800.,
        }
    }

    #[test]
    fn the_maximize_button_restores_a_maximized_window() {
        use WindowButton::*;
        assert_eq!(control_press(Maximize, false), ControlPress::Maximize);
        assert_eq!(control_press(Maximize, true), ControlPress::Restore);
        assert_eq!(control_press(Minimize, true), ControlPress::Minimize);
        assert_eq!(control_press(Close, true), ControlPress::Close);
    }

    #[test]
    fn presses_near_the_visible_edge_resize_from_it() {
        let free = Tiling::default();
        let insets = frame_insets(free);
        assert_eq!(insets.left, SHADOW);
        // In the shadow, and just inside the window's edge.
        assert_eq!(
            resize_edge(point(10., 400.), size(), insets, free),
            Some(ResizeEdge::Left)
        );
        assert_eq!(
            resize_edge(point(SHADOW + 3., 400.), size(), insets, free),
            Some(ResizeEdge::Left)
        );
        assert_eq!(
            resize_edge(point(990., 10.), size(), insets, free),
            Some(ResizeEdge::TopRight)
        );
        assert_eq!(
            resize_edge(point(500., 795.), size(), insets, free),
            Some(ResizeEdge::Bottom)
        );
        // Well inside: no resize.
        assert_eq!(resize_edge(point(500., 400.), size(), insets, free), None);
    }

    #[test]
    fn a_tiled_edge_has_no_shadow_and_no_resize() {
        let left = Tiling {
            left: true,
            ..Tiling::default()
        };
        let insets = frame_insets(left);
        assert_eq!(insets.left, 0.);
        assert_eq!(insets.right, SHADOW);
        assert_eq!(resize_edge(point(1., 400.), size(), insets, left), None);
        // The top-left corner resizes from the top only.
        assert_eq!(
            resize_edge(point(1., 5.), size(), insets, left),
            Some(ResizeEdge::Top)
        );
        // Snapped to the left half (tiled on three sides): only the right.
        let half = Tiling {
            top: true,
            left: true,
            bottom: true,
            right: false,
        };
        let insets = frame_insets(half);
        assert_eq!(resize_edge(point(500., 2.), size(), insets, half), None);
        assert_eq!(
            resize_edge(point(990., 400.), size(), insets, half),
            Some(ResizeEdge::Right)
        );
    }
}
