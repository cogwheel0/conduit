//! In-process capture of the process's own windows (no Screen Recording
//! permission is needed for a process's own windows), and the
//! accessibility activation the a11y checks need. Used by the gallery and by
//! the app's smoke screenshots.
//!
//! `CGWindowListCreateImage` is obsoleted in the macOS 15+ SDK headers, so it
//! is looked up with dlsym.

use std::ffi::{CString, c_void};

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct CGRect {
    pub x: f64,
    pub y: f64,
    pub w: f64,
    pub h: f64,
}

type CreateImageFn = unsafe extern "C" fn(CGRect, u32, u32, u32) -> *mut c_void;

#[link(name = "ImageIO", kind = "framework")]
unsafe extern "C" {
    fn CGImageDestinationCreateWithURL(
        url: *const c_void,
        ty: *const c_void,
        count: usize,
        opts: *const c_void,
    ) -> *mut c_void;
    fn CGImageDestinationAddImage(dest: *mut c_void, image: *mut c_void, props: *const c_void);
    fn CGImageDestinationFinalize(dest: *mut c_void) -> bool;
}

#[link(name = "CoreFoundation", kind = "framework")]
unsafe extern "C" {
    fn CFURLCreateFromFileSystemRepresentation(
        alloc: *const c_void,
        buf: *const u8,
        len: isize,
        is_dir: bool,
    ) -> *const c_void;
    fn CFStringCreateWithCString(
        alloc: *const c_void,
        cstr: *const std::ffi::c_char,
        encoding: u32,
    ) -> *const c_void;
    fn CFRelease(p: *const c_void);
}

#[link(name = "CoreGraphics", kind = "framework")]
unsafe extern "C" {
    fn CGImageRelease(img: *mut c_void);
    fn CGImageGetWidth(img: *mut c_void) -> usize;
    fn CGImageGetHeight(img: *mut c_void) -> usize;
}

unsafe extern "C" {
    fn dlsym(handle: *mut c_void, symbol: *const std::ffi::c_char) -> *mut c_void;
}

const RTLD_DEFAULT: *mut c_void = -2isize as *mut c_void;

fn create_image_fn() -> Option<CreateImageFn> {
    let name = CString::new("CGWindowListCreateImage").ok()?;
    // SAFETY: dlsym with RTLD_DEFAULT and a NUL-terminated name.
    let p = unsafe { dlsym(RTLD_DEFAULT, name.as_ptr()) };
    if p.is_null() {
        None
    } else {
        // SAFETY: the symbol has this C signature.
        Some(unsafe { std::mem::transmute::<*mut c_void, CreateImageFn>(p) })
    }
}

/// Captures an on-screen rect (global, top-left origin, points) to a PNG at
/// the display's native resolution. Returns the pixel size.
pub fn capture_rect(rect: CGRect, path: &str) -> Result<(usize, usize), String> {
    // kCGWindowListOptionOnScreenOnly = 1, kCGNullWindowID = 0,
    // kCGWindowImageBestResolution = 8.
    capture(rect, 1, 0, 8, path)
}

/// Captures one of this process's windows by its window number (CGWindowID)
/// to a PNG, whatever lies above it (a system alert, another window): only
/// that window's pixels, at native resolution, without its shadow.
pub fn capture_window(window_number: u32, path: &str) -> Result<(usize, usize), String> {
    // CGRectNull: the window's own bounds. kCGWindowListOptionIncludingWindow
    // = 8; kCGWindowImageBoundsIgnoreFraming = 1 | BestResolution = 8.
    let null = CGRect {
        x: f64::INFINITY,
        y: f64::INFINITY,
        w: 0.,
        h: 0.,
    };
    capture(null, 8, window_number, 1 | 8, path)
}

fn capture(
    rect: CGRect,
    list: u32,
    wid: u32,
    opts: u32,
    path: &str,
) -> Result<(usize, usize), String> {
    let f = create_image_fn().ok_or("CGWindowListCreateImage unavailable")?;
    // SAFETY: CoreGraphics/ImageIO calls with owned, released references.
    unsafe {
        let img = f(rect, list, wid, opts);
        if img.is_null() {
            return Err("capture returned null".into());
        }
        let size = (CGImageGetWidth(img), CGImageGetHeight(img));
        let url = CFURLCreateFromFileSystemRepresentation(
            std::ptr::null(),
            path.as_ptr(),
            path.len() as isize,
            false,
        );
        let ty = CString::new("public.png").unwrap_or_default();
        let ty = CFStringCreateWithCString(std::ptr::null(), ty.as_ptr(), 0x0800_0100);
        let dest = CGImageDestinationCreateWithURL(url, ty, 1, std::ptr::null());
        if dest.is_null() {
            CGImageRelease(img);
            CFRelease(url);
            CFRelease(ty);
            return Err(format!("cannot write {path}"));
        }
        CGImageDestinationAddImage(dest, img, std::ptr::null());
        let ok = CGImageDestinationFinalize(dest);
        CFRelease(dest);
        CFRelease(url);
        CFRelease(ty);
        CGImageRelease(img);
        if ok {
            Ok(size)
        } else {
            Err("PNG finalize failed".into())
        }
    }
}

/// Touches the window's NSAccessibility tree, which is what activates
/// AccessKit (as when VoiceOver connects); GPUI then builds an AccessKit
/// tree every frame.
///
/// # Safety
///
/// `ns_window` must be null or a live NSWindow owned by this process, used
/// on the main thread.
pub unsafe fn activate_accessibility(ns_window: *mut objc2::runtime::AnyObject) {
    use objc2::msg_send;
    use objc2::runtime::AnyObject;
    use objc2_foundation::NSArray;
    if ns_window.is_null() {
        return;
    }
    // SAFETY: ns_window is a live NSWindow owned by this process.
    unsafe {
        let children: *mut NSArray<AnyObject> = msg_send![ns_window, accessibilityChildren];
        if !children.is_null() {
            for i in 0..(*children).count() {
                let child: *mut AnyObject = msg_send![&*children, objectAtIndex: i];
                let _: *mut NSArray<AnyObject> = msg_send![child, accessibilityChildren];
            }
        }
    }
}
