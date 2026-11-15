//! Window chrome: a transparent GPUI Kit root, traffic lights inline with the
//! toolbar, the sidebar's NSVisualEffectView, and the Quick Ask panel.
//!
//! Two things this encodes: GPUI Kit's Root paints an opaque theme
//! background that hides any translucency, so windows open through
//! [`open_window_clear_root`]; and an objc2 NSVisualEffectView behind the
//! sidebar looks more native than `WindowBackgroundAppearance::Blurred`.

use gpui_kit::{
    AnyWindowHandle, App, AppContext as _, Bounds, Context, Entity, Hsla, InteractiveElement as _,
    IntoElement, MouseButton, MouseDownEvent, ParentElement as _, Pixels, Render, Stateful,
    Styled as _, TitlebarOptions, Window, WindowBackgroundAppearance, WindowBounds, WindowKind,
    WindowOptions, div, point, px, size,
};

/// Height of the unified toolbar the traffic lights sit in.
pub const TOOLBAR_HEIGHT: f32 = 52.;
/// Traffic-light origin: 14 pt in, vertically centred in the toolbar (the
/// buttons' frames are 14 pt tall).
pub const TRAFFIC_LIGHTS: (f32, f32) = (14., (TOOLBAR_HEIGHT - 14.) / 2.);
/// Room the traffic lights take at the toolbar's leading edge.
pub const TRAFFIC_LIGHTS_WIDTH: f32 = 78.;
/// The main window's default and minimum size.
pub const MAIN_WINDOW_SIZE: (f32, f32) = (1280., 860.);
pub const MAIN_WINDOW_MIN: (f32, f32) = (720., 480.);
/// Quick Ask's panel size.
pub const QUICK_ASK_SIZE: (f32, f32) = (720., 320.);

/// Options for a document-style window with a transparent, app-drawn
/// titlebar. `translucent` keeps the window background clear so a material
/// can show through.
pub fn window_options(
    title: &str,
    bounds: Bounds<Pixels>,
    translucent: bool,
    focus: bool,
) -> WindowOptions {
    WindowOptions {
        window_bounds: Some(WindowBounds::Windowed(bounds)),
        titlebar: Some(TitlebarOptions {
            title: Some(title.to_string().into()),
            appears_transparent: true,
            traffic_light_position: Some(point(px(TRAFFIC_LIGHTS.0), px(TRAFFIC_LIGHTS.1))),
        }),
        app_owns_titlebar_drag: true,
        focus,
        window_background: if translucent {
            WindowBackgroundAppearance::Transparent
        } else {
            WindowBackgroundAppearance::Opaque
        },
        window_min_size: Some(size(px(MAIN_WINDOW_MIN.0), px(MAIN_WINDOW_MIN.1))),
        ..Default::default()
    }
}

/// Options for the Quick Ask panel: a borderless `PopUp` (already a
/// non-activating NSPanel that floats above other apps).
pub fn quick_ask_options(bounds: Bounds<Pixels>, focus: bool) -> WindowOptions {
    WindowOptions {
        window_bounds: Some(WindowBounds::Windowed(bounds)),
        titlebar: None,
        kind: WindowKind::PopUp,
        focus,
        is_movable: true,
        window_background: WindowBackgroundAppearance::Transparent,
        ..Default::default()
    }
}

/// How far clear of a scrolled list's edges a control that takes keyboard
/// focus is brought (points).
pub const FOCUS_REVEAL_INSET: f32 = 24.;

/// `gpui_kit::open_window`, but with the Root's background cleared so
/// `Transparent` windows and NSVisualEffectViews show through.
pub fn open_window_clear_root<V: Render>(
    options: WindowOptions,
    cx: &mut App,
    build: impl FnOnce(&mut Window, &mut App) -> Entity<V>,
) -> gpui_kit::Result<(AnyWindowHandle, Entity<V>)> {
    let mut built = None;
    let window = cx.open_window(options, |window, cx| {
        // Keyboard focus moving into a scrolled list brings the control into
        // view, this far clear of the list's edges (as AppKit's key view).
        window.set_focus_reveal_inset(Some(px(FOCUS_REVEAL_INSET)));
        let view = build(window, cx);
        built = Some(view.clone());
        cx.new(|cx| gpui_kit::base::Root::new(view, window, cx).bg(gpui_kit::transparent_black()))
    })?;
    Ok((
        window.into(),
        built.expect("open_window ran its build closure"),
    ))
}

/// A region that drags the window, and zooms it on double-click, like a
/// native titlebar (the window owns its titlebar drag).
pub fn drag_region(id: &'static str) -> Stateful<gpui_kit::Div> {
    div()
        .id(id)
        .on_mouse_down(MouseButton::Left, |ev: &MouseDownEvent, window, _| {
            if ev.click_count >= 2 {
                window.titlebar_double_click();
            } else {
                window.start_window_move();
            }
        })
}

/// An empty view, for windows built before their content.
pub struct Blank;

impl Render for Blank {
    fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
        div().size_full().child("")
    }
}

/// Which AppKit material an effect view uses.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Material {
    /// Source-list sidebars.
    Sidebar,
    /// Floating panels: Quick Ask.
    HudWindow,
    /// Menus and popovers.
    Menu,
    /// Window backgrounds (Settings' sidebar uses Sidebar too).
    WindowBackground,
}

/// Window-chrome calls that need AppKit. They are no-ops elsewhere.
#[cfg(target_os = "macos")]
pub mod macos {
    use super::Material;
    use gpui_kit::{Hsla, Rgba, Window};
    use objc2::rc::Retained;
    use objc2::runtime::AnyObject;
    use objc2::{MainThreadMarker, MainThreadOnly as _, Message as _, msg_send};
    use objc2_app_kit::{
        NSAppearance, NSAppearanceNameAqua, NSAppearanceNameDarkAqua, NSApplication,
        NSAutoresizingMaskOptions, NSColor, NSColorSpace, NSView, NSVisualEffectBlendingMode,
        NSVisualEffectMaterial, NSVisualEffectState, NSVisualEffectView, NSWindow,
        NSWindowOrderingMode,
    };
    use objc2_foundation::{NSPoint, NSRect, NSSize};
    use raw_window_handle::RawWindowHandle;

    pub fn ns_view(window: &Window) -> Option<Retained<NSView>> {
        let handle = raw_window_handle::HasWindowHandle::window_handle(window).ok()?;
        let RawWindowHandle::AppKit(h) = handle.as_raw() else {
            return None;
        };
        // SAFETY: GPUI hands out the live NSView of this window.
        let view: &NSView = unsafe { h.ns_view.cast().as_ref() };
        Some(view.retain())
    }

    pub fn ns_window(window: &Window) -> Option<Retained<NSWindow>> {
        ns_view(window)?.window()
    }

    /// The CGWindowID, for in-process capture.
    pub fn window_number(window: &Window) -> Option<u32> {
        ns_window(window).map(|w| w.windowNumber() as u32)
    }

    /// Orders `window` directly below the window numbered `above`, at its
    /// level, so a material in `above` blurs only `window` (the gallery's
    /// synthetic backdrop) and never another app's window between them.
    /// AppKit orders windows only within a level, so `window` first takes
    /// the level of `above` (a Quick Ask panel floats above normal windows).
    pub fn order_below(window: &Window, above: u32) {
        let Some(w) = ns_window(window) else {
            return;
        };
        let Some(mtm) = MainThreadMarker::new() else {
            return;
        };
        if let Some(top) =
            NSApplication::sharedApplication(mtm).windowWithWindowNumber(above as isize)
        {
            w.setLevel(top.level());
        }
        w.orderWindow_relativeTo(NSWindowOrderingMode::Below, above as isize);
    }

    /// Raw pointer to the NSWindow, for walking its accessibility tree.
    pub fn ns_window_ptr(window: &Window) -> Option<*mut AnyObject> {
        ns_window(window).map(|w| Retained::as_ptr(&w) as *mut AnyObject)
    }

    fn material(m: Material) -> NSVisualEffectMaterial {
        match m {
            Material::Sidebar => NSVisualEffectMaterial::Sidebar,
            Material::HudWindow => NSVisualEffectMaterial::HUDWindow,
            Material::Menu => NSVisualEffectMaterial::Menu,
            Material::WindowBackground => NSVisualEffectMaterial::WindowBackground,
        }
    }

    /// Adds an NSVisualEffectView behind the GPUI content, `width` points
    /// from the leading edge (full width when `None`), full height. With
    /// `corner_radius` the view is clipped to rounded corners (Quick Ask).
    pub fn add_effect_view(
        window: &Window,
        m: Material,
        width: Option<f64>,
        corner_radius: Option<f64>,
    ) -> bool {
        effect_view(window, m, width, corner_radius).is_some()
    }

    /// [`add_effect_view`], returning the view so the caller can resize it
    /// (`setFrame`) or take it out (`removeFromSuperview`) when a setting
    /// changes.
    pub fn effect_view(
        window: &Window,
        m: Material,
        width: Option<f64>,
        corner_radius: Option<f64>,
    ) -> Option<Retained<NSVisualEffectView>> {
        let nswindow = ns_window(window)?;
        let mtm = MainThreadMarker::new()?;
        let content = nswindow.contentView()?;
        let bounds = content.bounds();
        let w = width.unwrap_or(bounds.size.width);
        let frame = NSRect::new(NSPoint::new(0.0, 0.0), NSSize::new(w, bounds.size.height));
        let effect = NSVisualEffectView::initWithFrame(NSVisualEffectView::alloc(mtm), frame);
        effect.setMaterial(material(m));
        effect.setBlendingMode(NSVisualEffectBlendingMode::BehindWindow);
        effect.setState(NSVisualEffectState::Active);
        let mask = if width.is_some() {
            NSAutoresizingMaskOptions::ViewHeightSizable
        } else {
            NSAutoresizingMaskOptions::ViewHeightSizable
                | NSAutoresizingMaskOptions::ViewWidthSizable
        };
        effect.setAutoresizingMask(mask);
        if let Some(radius) = corner_radius {
            effect.setWantsLayer(true);
            // SAFETY: a layer-backed view always has a CALayer.
            unsafe {
                let layer: *mut AnyObject = msg_send![&*effect, layer];
                if !layer.is_null() {
                    let _: () = msg_send![layer, setCornerRadius: radius];
                    let _: () = msg_send![layer, setMasksToBounds: true];
                }
            }
        }
        content.addSubview_positioned_relativeTo(&effect, NSWindowOrderingMode::Below, None);
        Some(effect)
    }

    /// Forces the app's appearance (the gallery renders light and dark
    /// without touching the system setting).
    pub fn set_app_appearance(dark: bool) {
        let Some(mtm) = MainThreadMarker::new() else {
            return;
        };
        let app = NSApplication::sharedApplication(mtm);
        // SAFETY: the appearance names are AppKit constants.
        let name = unsafe {
            if dark {
                NSAppearanceNameDarkAqua
            } else {
                NSAppearanceNameAqua
            }
        };
        let appearance = NSAppearance::appearanceNamed(name);
        app.setAppearance(appearance.as_deref());
    }

    /// The user's macOS accent colour (System Settings › Appearance).
    pub fn system_accent_color() -> Option<Hsla> {
        let color = NSColor::controlAccentColor();
        let srgb = color.colorUsingColorSpace(&NSColorSpace::sRGBColorSpace())?;
        Some(
            Rgba {
                r: srgb.redComponent() as f32,
                g: srgb.greenComponent() as f32,
                b: srgb.blueComponent() as f32,
                a: 1.,
            }
            .into(),
        )
    }
}

/// The macOS accent colour, or the default blue.
pub fn system_accent_color() -> Hsla {
    #[cfg(target_os = "macos")]
    if let Some(c) = macos::system_accent_color() {
        return c;
    }
    gpui_kit::rgb(crate::theme::DEFAULT_SYSTEM_ACCENT).into()
}

/// Paints nothing but keeps `color` as a translucent tint (used to tint a
/// material slightly toward the palette).
pub fn tint(color: Hsla) -> gpui_kit::Div {
    div().absolute().inset_0().bg(color)
}
