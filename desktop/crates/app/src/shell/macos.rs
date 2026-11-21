//! AppKit and Network.framework calls the shell makes directly.

use std::ffi::{c_char, c_void};

use conduit_components::window::{self as cw, Material};
use gpui_kit::Window;
use objc2::MainThreadMarker;
use objc2::rc::Retained;
use objc2_app_kit::{
    NSAppearance, NSAppearanceNameAqua, NSAppearanceNameDarkAqua, NSApplication, NSVisualEffectView,
};

/// Forces the app's appearance (`Some(dark)`), or lets it follow the system
/// (`None`). Native chrome (traffic lights, menus, materials) follows it.
pub fn set_app_appearance(dark: Option<bool>) {
    let Some(mtm) = MainThreadMarker::new() else {
        return;
    };
    let app = NSApplication::sharedApplication(mtm);
    match dark {
        None => app.setAppearance(None),
        Some(dark) => {
            // SAFETY: AppKit constants.
            let name = unsafe {
                if dark {
                    NSAppearanceNameDarkAqua
                } else {
                    NSAppearanceNameAqua
                }
            };
            app.setAppearance(NSAppearance::appearanceNamed(name).as_deref());
        }
    }
}

/// System Settings › Keyboard › Keyboard Navigation: whether Tab moves to
/// every control, not only text fields and lists. AppKit reads it live.
pub fn full_keyboard_access() -> bool {
    MainThreadMarker::new()
        .is_some_and(|mtm| NSApplication::sharedApplication(mtm).isFullKeyboardAccessEnabled())
}

/// Window › Bring All to Front.
pub fn bring_all_to_front() {
    if let Some(mtm) = MainThreadMarker::new() {
        NSApplication::sharedApplication(mtm).arrangeInFront(None);
    }
}

/// A window's NSWindow, to act on after the GPUI update that fetched it
/// returns (AppKit calls made inside an update can call back into GPUI,
/// which is then still borrowed).
pub fn ns_window(window: &Window) -> Option<Retained<objc2_app_kit::NSWindow>> {
    cw::macos::ns_window(window)
}

/// Takes a window off screen without closing it (close to the menu bar,
/// Quick Ask hiding): its views and state stay.
pub fn order_out(window: &objc2_app_kit::NSWindow) {
    window.orderOut(None);
}

/// Bumped by every [`fade_in`], so a fade-out that is overtaken never
/// orders the window out after it has been shown again.
static FADES: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);

/// Animates `window`'s alpha to `alpha` over `secs` (Core Animation's
/// ease-out), then runs `done`.
fn animate_alpha(
    window: &objc2_app_kit::NSWindow,
    alpha: f64,
    secs: f64,
    done: impl Fn() + 'static,
) {
    use block2::RcBlock;
    use objc2::runtime::AnyObject;
    use objc2::{class, msg_send};
    let target: *const objc2_app_kit::NSWindow = window;
    let changes = RcBlock::new(move |context: *mut AnyObject| {
        // SAFETY: AppKit calls on the main thread inside the animation
        // group; the window outlives it (the caller holds it).
        unsafe {
            let _: () = msg_send![context, setDuration: secs];
            let curve: *mut AnyObject = msg_send![
                class!(CAMediaTimingFunction),
                functionWithName: &*objc2_foundation::NSString::from_str("easeOut")
            ];
            let _: () = msg_send![context, setTimingFunction: curve];
            let animator: *mut AnyObject = msg_send![target, animator];
            let _: () = msg_send![animator, setAlphaValue: alpha];
        }
    });
    let done = RcBlock::new(done);
    // SAFETY: as above.
    unsafe {
        let _: () = msg_send![
            class!(NSAnimationContext),
            runAnimationGroup: &*changes,
            completionHandler: &*done
        ];
    }
}

/// Shows a panel fading in over `secs` from transparent (Quick Ask: 150
/// ms). A crossfade, so Reduce Motion keeps it.
pub fn fade_in(window: &objc2_app_kit::NSWindow, activate: bool, secs: f64) {
    FADES.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
    // Hidden: from transparent. Visible (fading out, or new and kept
    // transparent): from where it is.
    if !is_visible(window) {
        window.setAlphaValue(0.);
    }
    show(window, activate);
    animate_alpha(window, 1., secs, || {});
}

/// Fades a panel out over `secs` (Quick Ask: 120 ms), then takes it off
/// screen and makes it opaque again for next time, unless it was shown
/// again in between.
pub fn fade_out(window: &objc2_app_kit::NSWindow, secs: f64) {
    let generation = FADES.load(std::sync::atomic::Ordering::SeqCst);
    let held = objc2::Message::retain(window);
    animate_alpha(window, 0., secs, move || {
        if FADES.load(std::sync::atomic::Ordering::SeqCst) == generation {
            held.orderOut(None);
            held.setAlphaValue(1.);
        }
    });
}

/// Puts a hidden window back in front and makes it key. With `activate`,
/// the app comes forward too (the main window); without it the app stays
/// where it is (the non-activating Quick Ask panel).
pub fn show(window: &objc2_app_kit::NSWindow, activate: bool) {
    if activate && let Some(mtm) = MainThreadMarker::new() {
        #[allow(deprecated)]
        NSApplication::sharedApplication(mtm).activateIgnoringOtherApps(true);
    }
    if window.isMiniaturized() {
        window.deminiaturize(None);
    }
    window.makeKeyAndOrderFront(None);
}

/// Moves a window to `frame` (AppKit global coordinates).
pub fn set_frame(window: &objc2_app_kit::NSWindow, frame: crate::shell::placement::Rect) {
    use objc2_foundation::{NSPoint, NSRect, NSSize};
    let rect = NSRect::new(
        NSPoint::new(frame.x, frame.y),
        NSSize::new(frame.width, frame.height),
    );
    window.setFrame_display(rect, true);
}

/// Whether the window is on screen.
pub fn is_visible(window: &objc2_app_kit::NSWindow) -> bool {
    window.isVisible()
}

/// Whether the window is the key window (the user is typing into it).
pub fn is_key(window: &objc2_app_kit::NSWindow) -> bool {
    window.isKeyWindow()
}

/// The app's key window, if one of its windows has focus.
pub fn key_window() -> Option<Retained<objc2_app_kit::NSWindow>> {
    let mtm = MainThreadMarker::new()?;
    NSApplication::sharedApplication(mtm).keyWindow()
}

/// Whether the app is the active (frontmost) app.
pub fn app_is_active() -> bool {
    MainThreadMarker::new().is_some_and(|mtm| NSApplication::sharedApplication(mtm).isActive())
}

/// Plays the named system sound (`Glass`, `Tink`, ...), if there is one.
pub fn play_sound(name: &str) {
    if let Some(sound) =
        objc2_app_kit::NSSound::soundNamed(&objc2_foundation::NSString::from_str(name))
    {
        sound.play();
    }
}

/// Every display's frame and visible frame (without the menu bar and the
/// Dock), in AppKit global coordinates.
pub fn screens() -> Vec<(crate::shell::placement::Rect, crate::shell::placement::Rect)> {
    use crate::shell::placement::Rect;
    let Some(mtm) = MainThreadMarker::new() else {
        return vec![];
    };
    let rect = |r: objc2_foundation::NSRect| {
        Rect::new(r.origin.x, r.origin.y, r.size.width, r.size.height)
    };
    objc2_app_kit::NSScreen::screens(mtm)
        .iter()
        .map(|s| (rect(s.frame()), rect(s.visibleFrame())))
        .collect()
}

/// The pointer, in AppKit global coordinates.
pub fn mouse_location() -> (f64, f64) {
    let p = objc2_app_kit::NSEvent::mouseLocation();
    (p.x, p.y)
}

/// The height AppKit draws an NSMenu with these entries at (`Some(title)`
/// an item, `None` a separator), so a menu can be placed to open upward
/// from a control at the bottom of the window, as Messages' bars do.
pub fn menu_height(entries: &[Option<&str>]) -> Option<f64> {
    use objc2::runtime::AnyObject;
    use objc2::{class, msg_send};
    use objc2_foundation::{NSSize, NSString};
    MainThreadMarker::new()?;
    // SAFETY: AppKit calls on the main thread; the menu owns its items and is
    // released here (it is never shown).
    unsafe {
        let menu: *mut AnyObject = msg_send![class!(NSMenu), new];
        if menu.is_null() {
            return None;
        }
        for entry in entries {
            match entry {
                Some(title) => {
                    let item: *mut AnyObject = msg_send![class!(NSMenuItem), new];
                    let _: () = msg_send![item, setTitle: &*NSString::from_str(title)];
                    let _: () = msg_send![menu, addItem: item];
                    let _: () = msg_send![item, release];
                }
                None => {
                    let item: *mut AnyObject = msg_send![class!(NSMenuItem), separatorItem];
                    let _: () = msg_send![menu, addItem: item];
                }
            }
        }
        let size: NSSize = msg_send![menu, size];
        let _: () = msg_send![menu, release];
        (size.height > 0.).then_some(size.height)
    }
}

/// Greys out the items titled `items` (each opens a submenu) in the menu
/// bar's menu titled `menu`. AppKit enables any item that holds a submenu,
/// whatever it was told: the submenu itself is its target. Taking that
/// action away (to one nothing answers) lets the menu's automatic enabling
/// grey it out, its disclosure arrow included, as Mail's Message › Move to
/// is with nothing selected. GPUI builds the bar afresh on every install, so
/// this runs after each.
pub fn disable_submenus(menu: &str, items: &[String]) {
    use objc2::runtime::AnyObject;
    use objc2::{class, msg_send, sel};
    use objc2_foundation::NSString;
    if items.is_empty() || MainThreadMarker::new().is_none() {
        return;
    }
    // SAFETY: AppKit calls on the main thread on the app's own main menu.
    unsafe {
        let app: *mut AnyObject = msg_send![class!(NSApplication), sharedApplication];
        let main: *mut AnyObject = msg_send![app, mainMenu];
        if main.is_null() {
            return;
        }
        let top: *mut AnyObject = msg_send![main, itemWithTitle: &*NSString::from_str(menu)];
        if top.is_null() {
            return;
        }
        let sub: *mut AnyObject = msg_send![top, submenu];
        if sub.is_null() {
            return;
        }
        for title in items {
            let item: *mut AnyObject = msg_send![sub, itemWithTitle: &*NSString::from_str(title)];
            if item.is_null() {
                continue;
            }
            let _: () = msg_send![item, setTarget: std::ptr::null_mut::<AnyObject>()];
            let _: () = msg_send![item, setAction: sel!(conduitNothingToMove:)];
        }
    }
}

/// Gives the items titled `items` in the menu bar's menu `menu` the Tab
/// key as their key equivalent (⌃ always, ⇧ where asked), so they read
/// ⌃⇥ and ⌃⇧⇥: GPUI's menu builder passes "tab" through as the literal
/// string, which AppKit draws (and matches) as T. Runs after each install.
pub fn tab_key_equivalents(menu: &str, items: &[(String, bool)]) {
    use objc2::runtime::AnyObject;
    use objc2::{class, msg_send};
    use objc2_foundation::NSString;
    // NSEventModifierFlagControl and NSEventModifierFlagShift.
    const CONTROL: usize = 1 << 18;
    const SHIFT: usize = 1 << 17;
    if items.is_empty() || MainThreadMarker::new().is_none() {
        return;
    }
    // SAFETY: AppKit calls on the main thread on the app's own main menu.
    unsafe {
        let app: *mut AnyObject = msg_send![class!(NSApplication), sharedApplication];
        let main: *mut AnyObject = msg_send![app, mainMenu];
        if main.is_null() {
            return;
        }
        let top: *mut AnyObject = msg_send![main, itemWithTitle: &*NSString::from_str(menu)];
        if top.is_null() {
            return;
        }
        let sub: *mut AnyObject = msg_send![top, submenu];
        if sub.is_null() {
            return;
        }
        for (title, shift) in items {
            let item: *mut AnyObject = msg_send![sub, itemWithTitle: &*NSString::from_str(title)];
            if item.is_null() {
                continue;
            }
            let _: () = msg_send![item, setKeyEquivalent: &*NSString::from_str("\t")];
            let mask = if *shift { CONTROL | SHIFT } else { CONTROL };
            let _: () = msg_send![item, setKeyEquivalentModifierMask: mask];
        }
    }
}

/// The key equivalent AppKit has for the menu bar's item titled `item` in
/// the menu titled `menu` (its character and modifier mask), for the E2E.
pub fn menu_key_equivalent(menu: &str, item: &str) -> Option<(String, usize)> {
    use objc2::runtime::AnyObject;
    use objc2::{class, msg_send};
    use objc2_foundation::NSString;
    MainThreadMarker::new()?;
    // SAFETY: AppKit calls on the main thread on the app's own main menu.
    unsafe {
        let app: *mut AnyObject = msg_send![class!(NSApplication), sharedApplication];
        let main: *mut AnyObject = msg_send![app, mainMenu];
        if main.is_null() {
            return None;
        }
        let top: *mut AnyObject = msg_send![main, itemWithTitle: &*NSString::from_str(menu)];
        if top.is_null() {
            return None;
        }
        let sub: *mut AnyObject = msg_send![top, submenu];
        if sub.is_null() {
            return None;
        }
        let it: *mut AnyObject = msg_send![sub, itemWithTitle: &*NSString::from_str(item)];
        if it.is_null() {
            return None;
        }
        let key: *mut NSString = msg_send![it, keyEquivalent];
        let mask: usize = msg_send![it, keyEquivalentModifierMask];
        Some(((*key).to_string(), mask))
    }
}

/// Whether the menu bar's item titled `item` in the menu titled `menu` is
/// enabled now (AppKit's automatic enabling run first), for the E2E.
pub fn menu_item_enabled(menu: &str, item: &str) -> Option<bool> {
    use objc2::runtime::{AnyObject, Bool};
    use objc2::{class, msg_send};
    use objc2_foundation::NSString;
    MainThreadMarker::new()?;
    // SAFETY: AppKit calls on the main thread on the app's own main menu.
    unsafe {
        let app: *mut AnyObject = msg_send![class!(NSApplication), sharedApplication];
        let main: *mut AnyObject = msg_send![app, mainMenu];
        if main.is_null() {
            return None;
        }
        let top: *mut AnyObject = msg_send![main, itemWithTitle: &*NSString::from_str(menu)];
        if top.is_null() {
            return None;
        }
        let sub: *mut AnyObject = msg_send![top, submenu];
        if sub.is_null() {
            return None;
        }
        let _: () = msg_send![sub, update];
        let it: *mut AnyObject = msg_send![sub, itemWithTitle: &*NSString::from_str(item)];
        if it.is_null() {
            return None;
        }
        let on: Bool = msg_send![it, isEnabled];
        Some(on.as_bool())
    }
}

/// The NSVisualEffectView behind a window's sidebar, kept in step with the
/// sidebar setting, the density's sidebar width and the sidebar's
/// visibility.
#[derive(Default)]
pub struct SidebarMaterial {
    view: Option<Retained<NSVisualEffectView>>,
    width: f64,
}

impl SidebarMaterial {
    /// `want`: the material's width, or `None` for no material.
    pub fn sync(&mut self, window: &Window, want: Option<f64>) {
        match (want, self.view.as_ref()) {
            (None, Some(view)) => {
                view.removeFromSuperview();
                self.view = None;
            }
            (Some(width), None) => {
                self.view = cw::macos::effect_view(window, Material::Sidebar, Some(width), None);
                self.width = width;
            }
            (Some(width), Some(view)) if (width - self.width).abs() > 0.5 => {
                let mut frame = view.frame();
                frame.size.width = width;
                view.setFrame(frame);
                self.width = width;
            }
            _ => {}
        }
    }

    pub fn is_shown(&self) -> bool {
        self.view.is_some()
    }
}

#[link(name = "Network", kind = "framework")]
unsafe extern "C" {
    fn nw_path_monitor_create() -> *mut c_void;
    fn nw_path_monitor_set_queue(monitor: *mut c_void, queue: *mut c_void);
    fn nw_path_monitor_set_update_handler(
        monitor: *mut c_void,
        handler: &block2::Block<dyn Fn(*mut c_void)>,
    );
    fn nw_path_monitor_start(monitor: *mut c_void);
    fn nw_path_monitor_cancel(monitor: *mut c_void);
    fn nw_path_get_status(path: *mut c_void) -> i32;
    fn nw_release(object: *mut c_void);
}

unsafe extern "C" {
    fn dispatch_queue_create(label: *const c_char, attr: *const c_void) -> *mut c_void;
}

/// `nw_path_status_satisfied` / `_satisfiable`: online (a satisfiable path
/// comes up on demand, e.g. a VPN).
fn is_online(status: i32) -> bool {
    matches!(status, 1 | 3)
}

/// NWPathMonitor: calls `on_change(online)` on a private queue whenever the
/// default path's status changes (and once at start).
pub struct NetworkMonitor {
    monitor: *mut c_void,
}

impl NetworkMonitor {
    pub fn start(on_change: impl Fn(bool) + Send + Sync + 'static) -> Option<Self> {
        // SAFETY: Network.framework and libdispatch C APIs; the monitor is
        // retained until Drop cancels and releases it, and the handler block
        // is copied by `nw_path_monitor_set_update_handler`.
        unsafe {
            let monitor = nw_path_monitor_create();
            if monitor.is_null() {
                return None;
            }
            let queue =
                dispatch_queue_create(c"app.cogwheel.conduit.network".as_ptr(), std::ptr::null());
            nw_path_monitor_set_queue(monitor, queue);
            let handler = block2::RcBlock::new(move |path: *mut c_void| {
                if !path.is_null() {
                    on_change(is_online(nw_path_get_status(path)));
                }
            });
            nw_path_monitor_set_update_handler(monitor, &handler);
            nw_path_monitor_start(monitor);
            Some(Self { monitor })
        }
    }
}

impl Drop for NetworkMonitor {
    fn drop(&mut self) {
        // SAFETY: the monitor this struct created and still owns.
        unsafe {
            nw_path_monitor_cancel(self.monitor);
            nw_release(self.monitor);
        }
    }
}

/// A Core Graphics colour, as Core Animation takes one (`CGColorRef`).
#[repr(C)]
struct CgColor {
    _private: [u8; 0],
}

// SAFETY: `CGColorRef` is a pointer to the opaque `struct CGColor`.
unsafe impl objc2::encode::RefEncode for CgColor {
    const ENCODING_REF: objc2::encode::Encoding =
        objc2::encode::Encoding::Pointer(&objc2::encode::Encoding::Struct("CGColor", &[]));
}

/// `color` as an sRGB NSColor (which owns the CGColor it hands out).
fn ns_color(color: gpui_kit::Hsla) -> Retained<objc2_app_kit::NSColor> {
    let c = gpui_kit::Rgba::from(color);
    objc2_app_kit::NSColor::colorWithSRGBRed_green_blue_alpha(
        c.r as f64, c.g as f64, c.b as f64, c.a as f64,
    )
}

/// A floating panel's native chrome (Quick Ask): its palette tint and
/// hairline are drawn by a layer between the material and GPUI's content,
/// not by GPUI, so an alpha mask on GPUI's layer can fade the transcript's
/// top and bottom edges into the real surface beneath (the material and
/// its tint), as Spotlight's and Raycast's panels fade their lists, rather
/// than painting a colour over them that never matches the material.
pub struct PanelChrome {
    tint: Retained<objc2_app_kit::NSView>,
    gpui: Retained<objc2_app_kit::NSView>,
    mask: Option<Retained<objc2::runtime::AnyObject>>,
    last_tint: Option<(gpui_kit::Hsla, gpui_kit::Hsla)>,
    last_fade: Option<[i32; 5]>,
}

impl PanelChrome {
    /// Puts the tint layer under the window's GPUI view, with `radius`
    /// corners.
    pub fn new(window: &Window, radius: f64) -> Option<Self> {
        use objc2::MainThreadOnly as _;
        use objc2::msg_send;
        use objc2::runtime::AnyObject;
        use objc2_app_kit::{NSAutoresizingMaskOptions, NSView, NSWindowOrderingMode};
        let mtm = MainThreadMarker::new()?;
        let gpui = cw::macos::ns_view(window)?;
        // SAFETY: the window's content view, on the main thread.
        let content = unsafe { gpui.superview() }?;
        let tint = NSView::initWithFrame(NSView::alloc(mtm), content.bounds());
        tint.setWantsLayer(true);
        tint.setAutoresizingMask(
            NSAutoresizingMaskOptions::ViewWidthSizable
                | NSAutoresizingMaskOptions::ViewHeightSizable,
        );
        // SAFETY: a layer-backed view has a CALayer; main thread.
        unsafe {
            let layer: *mut AnyObject = msg_send![&*tint, layer];
            if !layer.is_null() {
                let _: () = msg_send![layer, setCornerRadius: radius];
                let _: () = msg_send![layer, setMasksToBounds: true];
                let _: () = msg_send![layer, setBorderWidth: 1.0f64];
            }
        }
        content.addSubview_positioned_relativeTo(&tint, NSWindowOrderingMode::Below, Some(&gpui));
        Some(Self {
            tint,
            gpui,
            mask: None,
            last_tint: None,
            last_fade: None,
        })
    }

    /// The panel's fill and hairline (the palette's, for the appearance).
    pub fn sync_tint(&mut self, fill: gpui_kit::Hsla, border: gpui_kit::Hsla) {
        use objc2::msg_send;
        use objc2::runtime::{AnyObject, Bool};
        if self.last_tint == Some((fill, border)) {
            return;
        }
        self.last_tint = Some((fill, border));
        let (fill, border) = (ns_color(fill), ns_color(border));
        // SAFETY: Core Animation calls on the main thread; the layer copies
        // (retains) the colours it is given.
        unsafe {
            let layer: *mut AnyObject = msg_send![&*self.tint, layer];
            if layer.is_null() {
                return;
            }
            let fill: *const CgColor = msg_send![&*fill, CGColor];
            let border: *const CgColor = msg_send![&*border, CGColor];
            let _: () = msg_send![objc2::class!(CATransaction), begin];
            let _: () = msg_send![objc2::class!(CATransaction), setDisableActions: Bool::YES];
            let _: () = msg_send![layer, setBackgroundColor: fill];
            let _: () = msg_send![layer, setBorderColor: border];
            let _: () = msg_send![objc2::class!(CATransaction), commit];
        }
    }

    /// Fades GPUI's content to nothing inside the band `top`…`bottom`
    /// (window points from the top): over `top_fade` points at its top edge
    /// and `bottom_fade` at its bottom; everything outside the band stays
    /// opaque. `None` takes the mask off.
    pub fn sync_fade(&mut self, band: Option<(f32, f32)>, top_fade: f32, bottom_fade: f32) {
        use objc2::msg_send;
        use objc2::runtime::{AnyObject, Bool};
        use objc2_foundation::{NSPoint, NSRect};
        let bounds = self.gpui.bounds();
        let height = bounds.size.height as f32;
        let key = band.map(|(top, bottom)| {
            [
                top.round() as i32,
                bottom.round() as i32,
                height.round() as i32,
                top_fade.round() as i32,
                bottom_fade.round() as i32,
            ]
        });
        if key == self.last_fade {
            return;
        }
        self.last_fade = key;
        // SAFETY: Core Animation calls on the main thread. The view's layer
        // retains its mask; `self.mask` keeps another reference to update it.
        unsafe {
            let host: *mut AnyObject = msg_send![&*self.gpui, layer];
            if host.is_null() {
                return;
            }
            let _: () = msg_send![objc2::class!(CATransaction), begin];
            let _: () = msg_send![objc2::class!(CATransaction), setDisableActions: Bool::YES];
            match band {
                Some((top, bottom)) if height > 0. && bottom - top > top_fade + bottom_fade => {
                    let mask = match &self.mask {
                        Some(mask) => mask.clone(),
                        None => {
                            let layer: *mut AnyObject =
                                msg_send![objc2::class!(CAGradientLayer), layer];
                            let Some(mask) = Retained::retain(layer) else {
                                let _: () = msg_send![objc2::class!(CATransaction), commit];
                                return;
                            };
                            // Opaque outside the band, a hard step to clear
                            // at each of its edges, then a clear lip and an
                            // eased ramp inside ([`fade_stops`]; the alphas
                            // never change, only where they sit).
                            let colors: *mut AnyObject =
                                msg_send![objc2::class!(NSMutableArray), array];
                            for (_, alpha) in fade_stops(0., 1., 1., 0., 0.) {
                                let c = objc2_app_kit::NSColor::colorWithWhite_alpha(
                                    0.,
                                    f64::from(alpha),
                                );
                                let cg: *const CgColor = msg_send![&*c, CGColor];
                                let _: () = msg_send![colors, addObject: cg.cast::<AnyObject>()];
                            }
                            let _: () = msg_send![&*mask, setColors: colors];
                            let flipped: Bool = msg_send![host, contentsAreFlipped];
                            // From the top of the view to its bottom.
                            let (start, end) = if flipped.as_bool() {
                                (NSPoint::new(0.5, 0.), NSPoint::new(0.5, 1.))
                            } else {
                                (NSPoint::new(0.5, 1.), NSPoint::new(0.5, 0.))
                            };
                            let _: () = msg_send![&*mask, setStartPoint: start];
                            let _: () = msg_send![&*mask, setEndPoint: end];
                            let _: () = msg_send![host, setMask: &*mask];
                            self.mask = Some(mask.clone());
                            mask
                        }
                    };
                    let frame = NSRect::new(NSPoint::new(0., 0.), bounds.size);
                    let _: () = msg_send![&*mask, setFrame: frame];
                    let locations: *mut AnyObject = msg_send![objc2::class!(NSMutableArray), array];
                    for (stop, _) in fade_stops(top, bottom, height, top_fade, bottom_fade) {
                        let n: *mut AnyObject = msg_send![
                            objc2::class!(NSNumber),
                            numberWithDouble: stop.clamp(0., 1.) as f64
                        ];
                        let _: () = msg_send![locations, addObject: n];
                    }
                    let _: () = msg_send![&*mask, setLocations: locations];
                }
                _ => {
                    if self.mask.take().is_some() {
                        let _: () = msg_send![host, setMask: std::ptr::null_mut::<AnyObject>()];
                    }
                }
            }
            let _: () = msg_send![objc2::class!(CATransaction), commit];
        }
    }
}

/// Where a list in a window fades, in window points from its top-left:
/// its column, and how far each end fades (0 where nothing is scrolled
/// past that end).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct EdgeBand {
    pub left: f32,
    pub right: f32,
    pub top: f32,
    pub bottom: f32,
    pub fade_top: f32,
    pub fade_bottom: f32,
    /// How strongly the ends fade (0…1): 1 at rest, eased in once the
    /// panel stops moving ([`edge_strength`]).
    pub strength: f32,
}

/// Paints the panel must stand still for before its list's ends fade: the
/// mask is a Core Animation layer, shown as soon as it is committed, while
/// GPUI's frames reach the screen a frame or more later. A mask that moved
/// with a sliding sidebar ran ahead of it, its faded column over the chat
/// beside it (a grey bar past the panel at the footer's rule).
pub const EDGE_SETTLE: u8 = 3;
/// Paints the fade then takes to come in (about 100 ms).
pub const EDGE_RAMP: u8 = 6;

/// How strongly the list's ends fade `rest` paints after the panel came to
/// rest: none while it moves and for [`EDGE_SETTLE`] paints after, then
/// eased in over [`EDGE_RAMP`] (at once under Reduce Motion).
pub fn edge_strength(rest: u8, reduce_motion: bool) -> f32 {
    if rest < EDGE_SETTLE {
        return 0.;
    }
    if reduce_motion {
        return 1.;
    }
    let t = f32::from(rest - EDGE_SETTLE + 1) / f32::from(EDGE_RAMP);
    ease_in_from_edge(t)
}

/// The alpha a fade has `t` of the way in from the list's edge (0 at the
/// edge, 1 where the list is whole): a smoothstep, so the rows dissolve
/// into the material with no visible line where the ramp starts or ends.
fn ease_in_from_edge(t: f32) -> f32 {
    let t = t.clamp(0., 1.);
    t * t * (3. - 2. * t)
}

/// The fade's gradient stops down a column `height` high: opaque above the
/// band, eased in from its top edge, opaque through the middle, eased out
/// into its bottom edge, opaque below (the search field and the footer
/// stay whole). An end that does not fade stays opaque.
fn edge_stops(band: &EdgeBand, height: f32) -> Vec<(f32, f32)> {
    const STEPS: [f32; 4] = [0., 0.25, 0.5, 0.75];
    let h = height.max(1.);
    let strength = band.strength.clamp(0., 1.);
    let alpha = |s: f32| 1. - strength * (1. - ease_in_from_edge(s));
    let mut stops = vec![(0., 1.), (band.top / h, 1.)];
    if band.fade_top > 0.5 {
        for s in STEPS {
            stops.push(((band.top + s * band.fade_top) / h, alpha(s)));
        }
    }
    stops.push(((band.top + band.fade_top) / h, 1.));
    stops.push(((band.bottom - band.fade_bottom) / h, 1.));
    if band.fade_bottom > 0.5 {
        for s in STEPS.iter().rev() {
            stops.push(((band.bottom - s * band.fade_bottom) / h, alpha(*s)));
        }
    }
    stops.push((band.bottom / h, 1.));
    stops.push((1., 1.));
    stops
        .into_iter()
        .map(|(at, alpha)| (at.clamp(0., 1.), alpha))
        .collect()
}

/// The fades at the ends of the sidebar's list, on the translucent
/// material: an alpha mask on GPUI's layer that is opaque everywhere but
/// the list's column, where it eases to nothing at the list's top (under
/// the search field) and bottom (at the footer's rule). Through it the real
/// material shows, which no colour GPUI could paint would match.
///
/// Overlays GPUI draws in the same layer (a tooltip, the drag image) are
/// cut out of the fade so they stay whole.
#[derive(Default)]
pub struct ListEdges {
    mask: Option<Retained<objc2::runtime::AnyObject>>,
    last: Option<(Vec<i32>, Vec<[i32; 4]>)>,
    /// Paints since the panel last moved (see [`edge_strength`]).
    rest: u8,
}

impl ListEdges {
    /// One paint of the panel, `moving` or not: how strongly its list's
    /// ends fade now, and whether the fade is still coming in (draw again
    /// next frame).
    pub fn settle(&mut self, moving: bool, reduce_motion: bool) -> (f32, bool) {
        self.rest = if moving {
            0
        } else {
            self.rest.saturating_add(1).min(EDGE_SETTLE + EDGE_RAMP)
        };
        let strength = edge_strength(self.rest, reduce_motion);
        (strength, !moving && strength < 1.)
    }

    /// The panel is not drawn: when it is again (an instant show under
    /// Reduce Motion, say), it has not stood still yet.
    pub fn forget_rest(&mut self) {
        self.rest = 0;
    }

    /// Masks `window`'s content for `band` (`None`: takes the mask off),
    /// keeping `keep` (window points) opaque.
    pub fn sync(
        &mut self,
        window: &Window,
        band: Option<EdgeBand>,
        keep: &[gpui_kit::Bounds<gpui_kit::Pixels>],
    ) {
        use objc2::msg_send;
        use objc2::runtime::{AnyObject, Bool};
        use objc2_foundation::{NSPoint, NSRect, NSSize};
        let Some(view) = cw::macos::ns_view(window) else {
            return;
        };
        let bounds = view.bounds();
        let (width, height) = (bounds.size.width as f32, bounds.size.height as f32);
        let band =
            band.filter(|b| b.right > b.left && b.bottom - b.top > b.fade_top + b.fade_bottom + 2.);
        let keep: Vec<[i32; 4]> = keep
            .iter()
            .map(|b| {
                [
                    f32::from(b.origin.x).round() as i32,
                    f32::from(b.origin.y).round() as i32,
                    f32::from(b.size.width).round() as i32,
                    f32::from(b.size.height).round() as i32,
                ]
            })
            .collect();
        let key = band.map(|b| {
            (
                [
                    b.left,
                    b.right,
                    b.top,
                    b.bottom,
                    b.fade_top,
                    b.fade_bottom,
                    b.strength * 100.,
                    width,
                    height,
                ]
                .iter()
                .map(|v| v.round() as i32)
                .collect::<Vec<_>>(),
                keep.clone(),
            )
        });
        if key == self.last {
            return;
        }
        self.last = key;
        // SAFETY: Core Animation calls on the main thread, on the window's
        // own view's layer. The layer retains its mask; `self.mask` keeps
        // another reference to rebuild it.
        unsafe {
            let host: *mut AnyObject = msg_send![&*view, layer];
            if host.is_null() {
                return;
            }
            let _: () = msg_send![objc2::class!(CATransaction), begin];
            let _: () = msg_send![objc2::class!(CATransaction), setDisableActions: Bool::YES];
            match band {
                Some(band) if height > 0. => {
                    let flipped: Bool = msg_send![host, contentsAreFlipped];
                    let flipped = flipped.as_bool();
                    // A rectangle in window points from the top, in the
                    // mask's own coordinates.
                    let rect = |x: f32, y: f32, w: f32, h: f32| {
                        let y = if flipped { y } else { height - y - h };
                        NSRect::new(
                            NSPoint::new(x as f64, y as f64),
                            NSSize::new(w.max(0.) as f64, h.max(0.) as f64),
                        )
                    };
                    let solid = |frame: NSRect| -> *mut AnyObject {
                        let layer: *mut AnyObject = msg_send![objc2::class!(CALayer), layer];
                        let black = objc2_app_kit::NSColor::colorWithWhite_alpha(0., 1.);
                        let cg: *const CgColor = msg_send![&*black, CGColor];
                        let _: () = msg_send![layer, setBackgroundColor: cg];
                        let _: () = msg_send![layer, setFrame: frame];
                        layer
                    };
                    let mask: *mut AnyObject = msg_send![objc2::class!(CALayer), layer];
                    let _: () =
                        msg_send![mask, setFrame: NSRect::new(NSPoint::new(0., 0.), bounds.size)];
                    // Opaque beside the column.
                    if band.left > 0. {
                        let left = solid(rect(0., 0., band.left, height));
                        let _: () = msg_send![mask, addSublayer: left];
                    }
                    let right = solid(rect(band.right, 0., width - band.right, height));
                    let _: () = msg_send![mask, addSublayer: right];
                    // The column's fades.
                    let gradient: *mut AnyObject = msg_send![objc2::class!(CAGradientLayer), layer];
                    let _: () = msg_send![gradient, setFrame: rect(band.left, 0., band.right - band.left, height)];
                    let (start, end) = if flipped {
                        (NSPoint::new(0.5, 0.), NSPoint::new(0.5, 1.))
                    } else {
                        (NSPoint::new(0.5, 1.), NSPoint::new(0.5, 0.))
                    };
                    let _: () = msg_send![gradient, setStartPoint: start];
                    let _: () = msg_send![gradient, setEndPoint: end];
                    let colors: *mut AnyObject = msg_send![objc2::class!(NSMutableArray), array];
                    let locations: *mut AnyObject = msg_send![objc2::class!(NSMutableArray), array];
                    for (at, alpha) in edge_stops(&band, height) {
                        let c = objc2_app_kit::NSColor::colorWithWhite_alpha(0., alpha as f64);
                        let cg: *const CgColor = msg_send![&*c, CGColor];
                        let _: () = msg_send![colors, addObject: cg.cast::<AnyObject>()];
                        let n: *mut AnyObject =
                            msg_send![objc2::class!(NSNumber), numberWithDouble: at as f64];
                        let _: () = msg_send![locations, addObject: n];
                    }
                    let _: () = msg_send![gradient, setColors: colors];
                    let _: () = msg_send![gradient, setLocations: locations];
                    let _: () = msg_send![mask, addSublayer: gradient];
                    // Overlays drawn over the list stay whole.
                    for [x, y, w, h] in &keep {
                        let hole = solid(rect(*x as f32, *y as f32, *w as f32, *h as f32));
                        let _: () = msg_send![mask, addSublayer: hole];
                    }
                    let _: () = msg_send![host, setMask: mask];
                    self.mask = Retained::retain(mask);
                    let set: *mut AnyObject = msg_send![host, mask];
                    log::debug!(
                        "list edges: mask {band:?} keep {} flipped {flipped} ({width}x{height}) set {}",
                        keep.len(),
                        !set.is_null()
                    );
                }
                _ => {
                    if self.mask.take().is_some() {
                        let _: () = msg_send![host, setMask: std::ptr::null_mut::<AnyObject>()];
                        log::debug!("list edges: mask off");
                    }
                }
            }
            let _: () = msg_send![objc2::class!(CATransaction), commit];
        }
    }
}

// ── Window sheets ──────────────────────────────────────────────────────────

/// Readies a GPUI window to be a sheet: no title, title bar or window
/// buttons (a sheet has none), and not movable on its own.
pub fn prepare_sheet(sheet: &objc2_app_kit::NSWindow) {
    use objc2_app_kit::{NSWindowButton, NSWindowTitleVisibility};
    sheet.setTitleVisibility(NSWindowTitleVisibility::Hidden);
    sheet.setTitlebarAppearsTransparent(true);
    sheet.setMovable(false);
    for kind in [
        NSWindowButton::CloseButton,
        NSWindowButton::MiniaturizeButton,
        NSWindowButton::ZoomButton,
    ] {
        if let Some(button) = sheet.standardWindowButton(kind) {
            button.setHidden(true);
        }
    }
}

/// Hangs `sheet` from `parent`'s title bar: AppKit's window-modal sheet,
/// which slides down and takes the keyboard while `parent` waits.
pub fn begin_sheet(parent: &objc2_app_kit::NSWindow, sheet: &objc2_app_kit::NSWindow) {
    prepare_sheet(sheet);
    // No completion handler: the app ends the sheet itself.
    parent.beginSheet_completionHandler(sheet, None);
}

/// Ends `sheet` on whatever window it hangs from (it slides back up and
/// orders out). Nothing when it is no sheet.
pub fn end_sheet(sheet: &objc2_app_kit::NSWindow) {
    if let Some(parent) = sheet.sheetParent() {
        parent.endSheet(sheet);
    } else {
        sheet.orderOut(None);
    }
}

/// Gives a sheet `content_height` points of content, keeping its top edge
/// under the parent's title bar, and no taller than the parent leaves room
/// for (`margin` points spare). `animate` glides it as AppKit resizes a
/// sheet whose content grew.
pub fn fit_sheet(sheet: &objc2_app_kit::NSWindow, content_height: f64, margin: f64, animate: bool) {
    use objc2_foundation::{NSPoint, NSRect, NSSize};
    let frame = sheet.frame();
    let room = sheet
        .sheetParent()
        .map(|p| p.contentLayoutRect().size.height - margin)
        .filter(|r| *r > 120.);
    let content = sheet.contentRectForFrameRect(frame);
    let chrome = frame.size.height - content.size.height;
    let height = room.map_or(content_height, |r| content_height.min(r)) + chrome;
    if (height - frame.size.height).abs() < 0.5 {
        return;
    }
    let top = frame.origin.y + frame.size.height;
    let next = NSRect::new(
        NSPoint::new(frame.origin.x, top - height),
        NSSize::new(frame.size.width, height),
    );
    sheet.setFrame_display_animate(next, true, animate);
}

/// The visible area of the display `window` is on (the main display for
/// one not yet on screen), without the menu bar and the Dock.
pub fn visible_area(window: &objc2_app_kit::NSWindow) -> Option<crate::shell::placement::Rect> {
    let mtm = MainThreadMarker::new()?;
    let screen = window
        .screen()
        .or_else(|| objc2_app_kit::NSScreen::mainScreen(mtm))?;
    let v = screen.visibleFrame();
    Some(crate::shell::placement::Rect::new(
        v.origin.x,
        v.origin.y,
        v.size.width,
        v.size.height,
    ))
}

/// Sizes the setup window for `content_height` points of content, as
/// [`crate::shell::placement::setup_frame`] places it. The visible area it
/// was fitted to.
pub fn fit_setup_window(
    window: &objc2_app_kit::NSWindow,
    content_height: f64,
    shown: bool,
    animate: bool,
) -> Option<crate::shell::placement::Rect> {
    let visible = visible_area(window)?;
    fit_setup_window_to(window, visible, content_height, shown, animate);
    Some(visible)
}

/// Fits the setup window, on screen, to `content_height` again once its
/// display's visible area is no longer `fitted_to`: it moved to another
/// display, or the display changed. Moves within one display leave it be.
/// The visible area it is fitted to now.
pub fn refit_setup_window(
    window: &objc2_app_kit::NSWindow,
    content_height: f64,
    fitted_to: Option<crate::shell::placement::Rect>,
) -> Option<crate::shell::placement::Rect> {
    let visible = visible_area(window)?;
    if fitted_to != Some(visible) {
        fit_setup_window_to(window, visible, content_height, true, false);
    }
    Some(visible)
}

fn fit_setup_window_to(
    window: &objc2_app_kit::NSWindow,
    visible: crate::shell::placement::Rect,
    content_height: f64,
    shown: bool,
    animate: bool,
) {
    use crate::shell::placement::{Rect, setup_frame};
    use objc2_foundation::{NSPoint, NSRect, NSSize};
    let frame = window.frame();
    let chrome = frame.size.height - window.contentRectForFrameRect(frame).size.height;
    let current = Rect::new(
        frame.origin.x,
        frame.origin.y,
        frame.size.width,
        frame.size.height,
    );
    let next = setup_frame(visible, current, content_height + chrome, shown);
    if next == current {
        return;
    }
    window.setFrame_display_animate(
        NSRect::new(
            NSPoint::new(next.x, next.y),
            NSSize::new(next.width, next.height),
        ),
        true,
        animate,
    );
}

/// The fade's shape from a band's edge inward, as (share of the fade,
/// alpha): clear for its first 15%, so no sliver of a line shows against
/// the header or the composer, then a smoothstep to opaque (not a straight
/// ramp, whose first points still drew half-cut glyphs at a third).
const FADE_RAMP: [(f32, f32); 7] = {
    let mut ramp = [(0., 0.); 7];
    let mut i = 0;
    while i < 7 {
        // 0, 0.15, then five even steps to 1.
        let d = if i == 0 {
            0.
        } else {
            0.15 + 0.85 * (i - 1) as f32 / 5.
        };
        let x = if i == 0 { 0. } else { (i - 1) as f32 / 5. };
        ramp[i] = (d, x * x * (3. - 2. * x));
        i += 1;
    }
    ramp
};

/// The mask's gradient stops (location as a share of `height`, alpha) for
/// a band `top`…`bottom` in points from the view's top that fades over
/// `top_fade` points at its top edge and `bottom_fade` at its bottom:
/// opaque outside, [`FADE_RAMP`] inside each edge (a 0 fade is no fade).
/// Always the same number of stops with the same alphas.
pub fn fade_stops(
    top: f32,
    bottom: f32,
    height: f32,
    top_fade: f32,
    bottom_fade: f32,
) -> Vec<(f32, f32)> {
    let h = height.max(1.);
    let at = |y: f32| (y / h).clamp(0., 1.);
    let mut stops = vec![(0., 1.), (at(top), 1.)];
    stops.extend(FADE_RAMP.iter().map(|&(d, a)| (at(top + d * top_fade), a)));
    stops.extend(
        FADE_RAMP
            .iter()
            .rev()
            .map(|&(d, a)| (at(bottom - d * bottom_fade), a)),
    );
    stops.extend([(at(bottom), 1.), (1., 1.)]);
    stops
}

/// `path` (a HEIC, RAW or BMP picture) as JPEG bytes at `quality` (0–1),
/// as mobile sends such pictures: through the system's own image tool,
/// which reads every format the Photos app does.
pub fn jpeg_from_image(path: &std::path::Path, quality: f32) -> Result<Vec<u8>, String> {
    let dir = std::env::temp_dir().join(format!("conduit-jpeg-{}", std::process::id()));
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    let n = NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    let out = dir.join(format!("{n}.jpg"));
    let percent = ((quality.clamp(0., 1.) * 100.).round() as u32).max(1);
    let status = std::process::Command::new("/usr/bin/sips")
        .args(["-s", "format", "jpeg", "-s", "formatOptions"])
        .arg(percent.to_string())
        .arg(path)
        .arg("--out")
        .arg(&out)
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .map_err(|e| e.to_string())?;
    let bytes = if status.success() {
        std::fs::read(&out).map_err(|e| e.to_string())
    } else {
        Err(format!("could not read the picture ({status})"))
    };
    // The app's own scratch copy.
    let _ = std::fs::remove_file(&out);
    bytes
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn quick_ask_fades_clear_at_its_edges_then_eases_in() {
        let stops = super::fade_stops(40., 300., 360., 24., 24.);
        assert_eq!(stops.len(), 18);
        // Locations never go back.
        assert!(stops.windows(2).all(|w| w[0].0 <= w[1].0), "{stops:?}");
        // Opaque header, a hard step to clear at the band's top...
        assert_eq!(stops[1], (40. / 360., 1.));
        assert_eq!(stops[2], (40. / 360., 0.));
        // ...clear for the first 3.6 pt, eased: a quarter in, still faint.
        assert_eq!(stops[3].1, 0.);
        assert!((stops[3].0 * 360. - 43.6).abs() < 0.01);
        assert!(stops[4].1 < 0.12 && stops[5].1 < 0.4, "{stops:?}");
        assert_eq!(stops[8], ((40. + 24.) / 360., 1.));
        // The bottom edge mirrors it, then the composer stays opaque.
        assert_eq!(stops[9], ((300. - 24.) / 360., 1.));
        assert_eq!(stops[15], (300. / 360., 0.));
        assert_eq!(stops[16], (300. / 360., 1.));
        assert_eq!(stops[17], (1., 1.));
        // No top fade (an answer at its start): every top stop on the edge,
        // so nothing under the header fades.
        let still = super::fade_stops(40., 300., 360., 0., 20.);
        assert!(still[1..9].iter().all(|s| s.0 == 40. / 360.), "{still:?}");
        assert_eq!(still[9], ((300. - 20.) / 360., 1.));
    }

    #[test]
    fn a_list_fades_only_where_it_is_scrolled_past() {
        let band = EdgeBand {
            left: 0.,
            right: 260.,
            top: 100.,
            bottom: 800.,
            fade_top: 0.,
            fade_bottom: 16.,
            strength: 1.,
        };
        let stops = edge_stops(&band, 900.);
        // Opaque everywhere but the bottom ramp, which reaches nothing at
        // the list's end and is whole again below it.
        assert!(
            stops
                .iter()
                .filter(|(_, a)| *a < 1.)
                .all(|(at, _)| { *at >= (800. - 16.) / 900. && *at <= 800. / 900. })
        );
        assert!(stops.contains(&(800. / 900., 0.)));
        assert!(stops.windows(2).all(|w| w[0].0 <= w[1].0));
        let top = EdgeBand {
            fade_top: 16.,
            ..band
        };
        assert!(edge_stops(&top, 900.).contains(&(100. / 900., 0.)));
        // Coming in after the panel stopped: the same places, part strength.
        let half = edge_stops(
            &EdgeBand {
                strength: 0.5,
                ..band
            },
            900.,
        );
        assert!(half.contains(&(800. / 900., 0.5)));
        assert!(half.iter().all(|(_, a)| *a >= 0.5));
    }

    #[test]
    fn a_moving_panel_has_no_fade_until_it_has_stood_still() {
        let mut edges = ListEdges::default();
        // Sliding in: never a fade (the mask would run ahead of the panel).
        for _ in 0..12 {
            assert_eq!(edges.settle(true, false), (0., false));
        }
        // At rest: nothing for EDGE_SETTLE paints, then eased in, rising.
        let mut last = 0.;
        let mut steps = vec![];
        for _ in 0..(EDGE_SETTLE + EDGE_RAMP + 3) {
            let (strength, more) = edges.settle(false, false);
            assert!(strength >= last, "{steps:?}");
            assert_eq!(more, strength < 1.);
            steps.push(strength);
            last = strength;
        }
        assert!(
            steps[..usize::from(EDGE_SETTLE) - 1]
                .iter()
                .all(|s| *s == 0.),
            "{steps:?}"
        );
        assert_eq!(*steps.last().unwrap(), 1.);
        assert!(
            steps.iter().filter(|s| **s > 0. && **s < 1.).count() >= 4,
            "{steps:?}"
        );
        // Moving again takes it off at once.
        assert_eq!(edges.settle(true, false).0, 0.);
        // Hidden, then shown at once (Reduce Motion): it waits again.
        for _ in 0..12 {
            edges.settle(false, false);
        }
        edges.forget_rest();
        assert_eq!(edges.settle(false, true).0, 0.);
        // Reduce Motion: still waits for the panel, then whole at once.
        let mut edges = ListEdges::default();
        let steps: Vec<f32> = (0..EDGE_SETTLE + 1)
            .map(|_| edges.settle(false, true).0)
            .collect();
        assert_eq!(steps.last(), Some(&1.));
        assert!(
            steps[..usize::from(EDGE_SETTLE) - 1]
                .iter()
                .all(|s| *s == 0.)
        );
    }

    #[test]
    fn path_statuses() {
        assert!(!is_online(0)); // invalid
        assert!(is_online(1)); // satisfied
        assert!(!is_online(2)); // unsatisfied
        assert!(is_online(3)); // satisfiable
    }

    #[test]
    fn the_monitor_reports_at_start() {
        let (tx, rx) = std::sync::mpsc::channel();
        let monitor = NetworkMonitor::start(move |online| {
            let _ = tx.send(online);
        })
        .expect("NWPathMonitor starts");
        assert!(rx.recv_timeout(std::time::Duration::from_secs(5)).is_ok());
        drop(monitor);
    }
}
