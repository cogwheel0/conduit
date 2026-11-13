//! The capture's window helpers over [`crate::shell::grab`]: how far two
//! frames differ, this process's on-screen windows (to find an open
//! NSMenu, which is a window of ours at the pop-up menu level), and a
//! closer that ends an open menu's tracking loop from inside it.

use std::ffi::c_void;

use crate::shell::grab::ON_SCREEN_ONLY;
pub use crate::shell::grab::{CGRect, Frame};

#[link(name = "CoreFoundation", kind = "framework")]
unsafe extern "C" {
    fn CFRelease(p: *const c_void);
    fn CFArrayGetCount(array: *const c_void) -> isize;
    fn CFArrayGetValueAtIndex(array: *const c_void, index: isize) -> *const c_void;
    fn CFDictionaryGetValue(dict: *const c_void, key: *const c_void) -> *const c_void;
    fn CFNumberGetValue(number: *const c_void, ty: isize, out: *mut c_void) -> bool;
}

#[link(name = "CoreGraphics", kind = "framework")]
unsafe extern "C" {
    fn CGWindowListCopyWindowInfo(option: u32, relative_to: u32) -> *const c_void;
    fn CGRectMakeWithDictionaryRepresentation(dict: *const c_void, rect: *mut CGRect) -> bool;
    static kCGWindowOwnerPID: *const c_void;
    static kCGWindowLayer: *const c_void;
    static kCGWindowNumber: *const c_void;
    static kCGWindowBounds: *const c_void;
}

/// kCFNumberSInt64Type.
const SINT64: isize = 4;
/// NSPopUpMenuWindowLevel: where AppKit puts an open menu.
pub const MENU_LAYER: i64 = 101;

/// A pixel rect: x0, y0, x1, y1.
pub type PixelRect = (usize, usize, usize, usize);

/// How much of a pair of same-sized frames differs: the share of pixels
/// whose channels differ noticeably, within `region` when given and
/// outside `exclude`.
pub fn difference(a: &Frame, b: &Frame, region: Option<PixelRect>) -> f64 {
    difference_outside(a, b, region, None)
}

pub fn difference_outside(
    a: &Frame,
    b: &Frame,
    region: Option<PixelRect>,
    exclude: Option<PixelRect>,
) -> f64 {
    let (Some((pa, stride_a)), Some((pb, stride_b))) = (a.pixels(), b.pixels()) else {
        return 1.;
    };
    if a.size() != b.size() {
        return 1.;
    }
    let (w, h) = a.size();
    let (x0, y0, x1, y1) = region.unwrap_or((0, 0, w, h));
    let (x1, y1) = (x1.min(w), y1.min(h));
    let mut changed = 0usize;
    let mut total = 0usize;
    let excluded = |x: usize, y: usize| {
        exclude.is_some_and(|(ex0, ey0, ex1, ey1)| x >= ex0 && x < ex1 && y >= ey0 && y < ey1)
    };
    for y in y0..y1 {
        for x in x0..x1 {
            if excluded(x, y) {
                continue;
            }
            let ia = y * stride_a + x * 4;
            let ib = y * stride_b + x * 4;
            total += 1;
            if ia + 3 >= pa.len() || ib + 3 >= pb.len() {
                continue;
            }
            let delta = (0..3)
                .map(|c| (i32::from(pa[ia + c]) - i32::from(pb[ib + c])).unsigned_abs())
                .max()
                .unwrap_or(0);
            if delta > 24 {
                changed += 1;
            }
        }
    }
    if total == 0 {
        0.
    } else {
        changed as f64 / total as f64
    }
}

/// One on-screen window of this process.
#[derive(Clone, Copy, Debug)]
pub struct OwnWindow {
    pub layer: i64,
    /// Global points, top-left origin.
    pub bounds: CGRect,
}

/// This process's on-screen windows, front to back.
pub fn own_windows() -> Vec<OwnWindow> {
    let pid = i64::from(std::process::id());
    let mut out = vec![];
    // SAFETY: CoreGraphics/CoreFoundation reads of a copied, released list.
    unsafe {
        let list = CGWindowListCopyWindowInfo(ON_SCREEN_ONLY, 0);
        if list.is_null() {
            return out;
        }
        let number = |dict: *const c_void, key: *const c_void| -> Option<i64> {
            let v = CFDictionaryGetValue(dict, key);
            if v.is_null() {
                return None;
            }
            let mut n: i64 = 0;
            CFNumberGetValue(v, SINT64, (&mut n as *mut i64).cast()).then_some(n)
        };
        for i in 0..CFArrayGetCount(list) {
            let dict = CFArrayGetValueAtIndex(list, i);
            if number(dict, kCGWindowOwnerPID) != Some(pid) {
                continue;
            }
            let (Some(_), Some(layer)) =
                (number(dict, kCGWindowNumber), number(dict, kCGWindowLayer))
            else {
                continue;
            };
            let mut bounds = CGRect {
                x: 0.,
                y: 0.,
                w: 0.,
                h: 0.,
            };
            let b = CFDictionaryGetValue(dict, kCGWindowBounds);
            if b.is_null() || !CGRectMakeWithDictionaryRepresentation(b, &mut bounds) {
                continue;
            }
            out.push(OwnWindow { layer, bounds });
        }
        CFRelease(list);
    }
    out
}

/// This process's open menus (pop-up menu level windows).
pub fn open_menus() -> Vec<OwnWindow> {
    own_windows()
        .into_iter()
        .filter(|w| w.layer == MENU_LAYER && w.bounds.w > 20. && w.bounds.h > 20.)
        .collect()
}

/// The smallest rect holding both.
pub fn union(a: CGRect, b: CGRect) -> CGRect {
    let x0 = a.x.min(b.x);
    let y0 = a.y.min(b.y);
    let x1 = (a.x + a.w).max(b.x + b.w);
    let y1 = (a.y + a.h).max(b.y + b.h);
    CGRect {
        x: x0,
        y: y0,
        w: x1 - x0,
        h: y1 - y0,
    }
}

pub fn inset(r: CGRect, by: f64) -> CGRect {
    CGRect {
        x: r.x - by,
        y: r.y - by,
        w: r.w + 2. * by,
        h: r.h + 2. * by,
    }
}

// ── Closing an open menu ───────────────────────────────────────────────
//
// An open NSMenu runs a tracking loop on the main thread: GCD's main queue
// and GPUI's tasks wait, and events the app posts never reach it. Timers
// scheduled for the event-tracking run-loop mode do fire inside it, so a
// timer armed before the menu opens ends it (`cancelTracking`) once the
// capture thread says so. The menu comes from
// NSMenuDidBeginTrackingNotification.

use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};

/// The menu being tracked (a retained NSMenu*), or 0.
static TRACKED: AtomicUsize = AtomicUsize::new(0);
/// Set by the capture thread: close the tracked menu.
static CLOSE: AtomicBool = AtomicBool::new(false);
/// The appearance menus get when they open: 0 as they are, 1 light,
/// 2 dark. Menus from the menu bar and the menu-bar item follow the
/// system's menu bar, not the app; a shot "in light" shows what a user in
/// light mode sees.
static FORCED_DARK: std::sync::atomic::AtomicU8 = std::sync::atomic::AtomicU8::new(0);

/// Menus opened from now on take this appearance (`None`: their own).
pub fn force_menu_appearance(dark: Option<bool>) {
    FORCED_DARK.store(
        match dark {
            None => 0,
            Some(false) => 1,
            Some(true) => 2,
        },
        Ordering::SeqCst,
    );
}

/// Sets an NSMenu's appearance (main thread): 1 light, 2 dark.
///
/// # Safety
///
/// `menu` is a live NSMenu.
pub unsafe fn set_appearance(menu: *mut objc2::runtime::AnyObject, forced: u8) {
    use objc2::runtime::AnyObject;
    use objc2::{class, msg_send};
    if forced == 0 || menu.is_null() {
        return;
    }
    let name = ns_string(if forced == 2 {
        "NSAppearanceNameDarkAqua"
    } else {
        "NSAppearanceNameAqua"
    });
    // SAFETY: AppKit calls on the main thread.
    unsafe {
        let appearance: *mut AnyObject = msg_send![class!(NSAppearance), appearanceNamed: &*name];
        if !appearance.is_null() {
            let _: () = msg_send![menu, setAppearance: appearance];
        }
    }
}

/// The forced appearance (see [`force_menu_appearance`]).
pub fn forced_appearance() -> u8 {
    FORCED_DARK.load(Ordering::SeqCst)
}

fn ns_string(s: &str) -> objc2::rc::Retained<objc2_foundation::NSString> {
    objc2_foundation::NSString::from_str(s)
}

/// The items of the menu that last began tracking, as shown: title, a
/// check, the key equivalent, `(disabled)`, `▸` for a submenu, `—` for a
/// separator.
static LAST_ITEMS: std::sync::Mutex<Vec<String>> = std::sync::Mutex::new(Vec::new());

/// [`LAST_ITEMS`], taken.
pub fn take_menu_items() -> Vec<String> {
    LAST_ITEMS
        .lock()
        .map(|mut i| std::mem::take(&mut *i))
        .unwrap_or_default()
}

/// Reads an NSMenu's items (main thread).
///
/// # Safety
///
/// `menu` is a live NSMenu.
unsafe fn menu_items(menu: *mut objc2::runtime::AnyObject) -> Vec<String> {
    use objc2::msg_send;
    use objc2::runtime::AnyObject;
    use objc2_foundation::NSString;
    let mut out = vec![];
    // SAFETY: NSMenu/NSMenuItem reads on the main thread.
    unsafe {
        let count: isize = msg_send![menu, numberOfItems];
        for i in 0..count {
            let item: *mut AnyObject = msg_send![menu, itemAtIndex: i];
            if item.is_null() {
                continue;
            }
            let separator: bool = msg_send![item, isSeparatorItem];
            if separator {
                out.push("\u{2014}".to_string());
                continue;
            }
            let hidden: bool = msg_send![item, isHidden];
            let title: *mut NSString = msg_send![item, title];
            let mut line = if title.is_null() {
                String::new()
            } else {
                (*title).to_string()
            };
            // An item with no title (a placeholder AppKit fills, such as
            // Continuity Camera's) is listed by its identifier.
            if line.is_empty() {
                let identifier: *mut NSString = msg_send![item, identifier];
                if !identifier.is_null() {
                    line = format!("[{}]", *identifier);
                }
            }
            if hidden {
                if line.starts_with('[') {
                    out.push(format!("{line} (hidden)"));
                }
                continue;
            }
            let state: isize = msg_send![item, state];
            if state == 1 {
                line = format!("\u{2713} {line}");
            }
            let key: *mut NSString = msg_send![item, keyEquivalent];
            let key = if key.is_null() {
                String::new()
            } else {
                (*key).to_string()
            };
            if !key.is_empty() {
                let mask: usize = msg_send![item, keyEquivalentModifierMask];
                let mut chord = String::new();
                if mask & (1 << 18) != 0 {
                    chord.push('\u{2303}');
                }
                if mask & (1 << 19) != 0 {
                    chord.push('\u{2325}');
                }
                if mask & (1 << 17) != 0 || key.chars().any(|c| c.is_uppercase()) {
                    chord.push('\u{21e7}');
                }
                if mask & (1 << 20) != 0 {
                    chord.push('\u{2318}');
                }
                let shown = match key.as_str() {
                    "\r" => "\u{21a9}".to_string(),
                    "\u{1b}" => "\u{238b}".to_string(),
                    "\u{8}" | "\u{7f}" => "\u{232b}".to_string(),
                    " " => "Space".to_string(),
                    k => k.to_uppercase(),
                };
                line = format!("{line}  [{chord}{shown}]");
            }
            let enabled: bool = msg_send![item, isEnabled];
            if !enabled {
                line = format!("{line} (disabled)");
            }
            let submenu: bool = msg_send![item, hasSubmenu];
            if submenu {
                line = format!("{line} \u{25b8}");
            }
            out.push(line);
        }
    }
    out
}

/// Watches menus begin tracking (main thread, once).
pub fn install_menu_watch() {
    use block2::RcBlock;
    use objc2::runtime::AnyObject;
    use objc2::{class, msg_send};
    let block = RcBlock::new(|note: *mut AnyObject| {
        if note.is_null() {
            return;
        }
        // SAFETY: AppKit's notification, on the main thread.
        unsafe {
            let menu: *mut AnyObject = msg_send![note, object];
            if menu.is_null() {
                return;
            }
            if let Ok(mut items) = LAST_ITEMS.lock() {
                *items = menu_items(menu);
            }
            set_appearance(menu, FORCED_DARK.load(Ordering::SeqCst));
            let _: *mut AnyObject = msg_send![menu, retain];
            let old = TRACKED.swap(menu as usize, Ordering::SeqCst);
            if old != 0 {
                let _: () = msg_send![old as *mut AnyObject, release];
            }
        }
    });
    let name = ns_string("NSMenuDidBeginTrackingNotification");
    // SAFETY: plain Foundation calls on the main thread; the observer token
    // is kept for the life of the process.
    unsafe {
        let center: *mut AnyObject = msg_send![class!(NSNotificationCenter), defaultCenter];
        let token: *mut AnyObject = msg_send![
            center,
            addObserverForName: &*name,
            object: std::ptr::null_mut::<AnyObject>(),
            queue: std::ptr::null_mut::<AnyObject>(),
            usingBlock: &*block
        ];
        let _: *mut AnyObject = msg_send![token, retain];
    }
}

/// Arms the closer before a menu opens (main thread): a timer that fires
/// inside the tracking loop and cancels the tracked menu once
/// [`request_menu_close`] is called; it gives up after `give_up`.
pub fn arm_menu_closer(give_up: Duration) {
    use block2::RcBlock;
    use objc2::runtime::AnyObject;
    use objc2::{class, msg_send};
    CLOSE.store(false, Ordering::SeqCst);
    let deadline = Instant::now() + give_up;
    let block = RcBlock::new(move |timer: *mut AnyObject| {
        let close = CLOSE.load(Ordering::SeqCst);
        if !close && Instant::now() < deadline {
            return;
        }
        CLOSE.store(false, Ordering::SeqCst);
        let menu = TRACKED.swap(0, Ordering::SeqCst);
        // SAFETY: AppKit calls on the main thread (the timer's thread).
        unsafe {
            if menu != 0 {
                let menu = menu as *mut AnyObject;
                // The items as they are now, open: AppKit may have filled
                // placeholders since the menu began tracking.
                if let Ok(mut items) = LAST_ITEMS.lock() {
                    *items = menu_items(menu);
                }
                let _: () = msg_send![menu, cancelTrackingWithoutAnimation];
                let _: () = msg_send![menu, release];
            }
            if !timer.is_null() {
                let _: () = msg_send![timer, invalidate];
            }
        }
    });
    // SAFETY: Foundation calls on the main thread; the run loop retains the
    // timer until it is invalidated.
    unsafe {
        let timer: *mut AnyObject = msg_send![
            class!(NSTimer),
            timerWithTimeInterval: 0.05f64,
            repeats: true,
            block: &*block
        ];
        let run_loop: *mut AnyObject = msg_send![class!(NSRunLoop), mainRunLoop];
        for mode in ["kCFRunLoopCommonModes", "NSEventTrackingRunLoopMode"] {
            let mode = ns_string(mode);
            let _: () = msg_send![run_loop, addTimer: timer, forMode: &*mode];
        }
    }
}

/// Asks the armed closer to end the open menu (any thread).
pub fn request_menu_close() {
    CLOSE.store(true, Ordering::SeqCst);
}

use std::time::{Duration, Instant};
