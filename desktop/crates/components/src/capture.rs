//! In-process capture of the process's own windows (no Screen Recording
//! permission is needed for a process's own windows), and the
//! accessibility activation the a11y checks need. Used by the gallery and by
//! the app's smoke screenshots.
//!
//! Every capture names the windows it takes by id, so nothing else on screen
//! (another app's window, a notification) can end up in a shot: there is no
//! capture of a bare screen rect.
//!
//! `CGWindowListCreateImage` and `CGWindowListCreateImageFromArray` are
//! obsoleted in the macOS 15+ SDK headers, so they are looked up with dlsym.

use std::ffi::{CString, c_void};

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct CGRect {
    pub x: f64,
    pub y: f64,
    pub w: f64,
    pub h: f64,
}

impl CGRect {
    /// CGRectNull: with a window list, the union of the windows' bounds.
    pub const NULL: CGRect = CGRect {
        x: f64::INFINITY,
        y: f64::INFINITY,
        w: 0.,
        h: 0.,
    };
}

type CreateImageFn = unsafe extern "C" fn(CGRect, u32, u32, u32) -> *mut c_void;
type CreateImageFromArrayFn = unsafe extern "C" fn(CGRect, *const c_void, u32) -> *mut c_void;

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
    fn CFArrayCreate(
        alloc: *const c_void,
        values: *const *const c_void,
        count: isize,
        callbacks: *const c_void,
    ) -> *const c_void;
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

fn lookup(name: &str) -> Option<*mut c_void> {
    let name = CString::new(name).ok()?;
    // SAFETY: dlsym with RTLD_DEFAULT and a NUL-terminated name.
    let p = unsafe { dlsym(RTLD_DEFAULT, name.as_ptr()) };
    (!p.is_null()).then_some(p)
}

fn create_image_fn() -> Option<CreateImageFn> {
    let p = lookup("CGWindowListCreateImage")?;
    // SAFETY: the symbol has this C signature.
    Some(unsafe { std::mem::transmute::<*mut c_void, CreateImageFn>(p) })
}

fn create_image_from_array_fn() -> Option<CreateImageFromArrayFn> {
    let p = lookup("CGWindowListCreateImageFromArray")?;
    // SAFETY: the symbol has this C signature.
    Some(unsafe { std::mem::transmute::<*mut c_void, CreateImageFromArrayFn>(p) })
}

/// What [`capture_windows`] asks CoreGraphics for: exactly these windows,
/// composited front to back in the order given (the first in front, as
/// CoreGraphics draws the array whatever the windows' on-screen order), cut
/// to `bounds`.
#[derive(Clone, Debug, PartialEq)]
pub struct WindowsCapture {
    pub windows: Vec<u32>,
    pub bounds: CGRect,
}

impl PartialEq for CGRect {
    fn eq(&self, other: &Self) -> bool {
        let same = |a: f64, b: f64| a == b || (a.is_infinite() && b.is_infinite());
        same(self.x, other.x) && same(self.y, other.y) && self.w == other.w && self.h == other.h
    }
}

/// Plans a capture of `windows` (CGWindowIDs) within `bounds` (global,
/// top-left origin, points), or their union with `None`. Refuses an empty
/// list and the null window id, which CoreGraphics would read as "every
/// window on screen".
pub fn plan_windows(windows: &[u32], bounds: Option<CGRect>) -> Result<WindowsCapture, String> {
    if windows.is_empty() {
        return Err("no window to capture".into());
    }
    if windows.contains(&0) {
        return Err("a window to capture has no id".into());
    }
    Ok(WindowsCapture {
        windows: windows.to_vec(),
        bounds: bounds.unwrap_or(CGRect::NULL),
    })
}

/// Captures only `windows` (this process's, by CGWindowID), listed front to
/// back (content first, a backdrop after), to a PNG at the display's native
/// resolution, within `bounds` or their union: whatever else is on screen
/// there is left out. Returns the pixel size.
pub fn capture_windows(
    windows: &[u32],
    bounds: Option<CGRect>,
    path: &str,
) -> Result<(usize, usize), String> {
    let plan = plan_windows(windows, bounds)?;
    let f = create_image_from_array_fn().ok_or("CGWindowListCreateImageFromArray unavailable")?;
    let ids: Vec<*const c_void> = plan
        .windows
        .iter()
        .map(|&id| id as usize as *const c_void)
        .collect();
    // SAFETY: an array of raw CGWindowIDs with no callbacks, as CoreGraphics
    // documents for this call; released after it.
    unsafe {
        let array = CFArrayCreate(
            std::ptr::null(),
            ids.as_ptr(),
            ids.len() as isize,
            std::ptr::null(),
        );
        if array.is_null() {
            return Err("cannot list the windows to capture".into());
        }
        // kCGWindowImageBestResolution = 8.
        let img = f(plan.bounds, array, 8);
        CFRelease(array);
        write_png(img, path)
    }
}

/// Captures one of this process's windows by its window number (CGWindowID)
/// to a PNG, whatever lies above it (a system alert, another window): only
/// that window's pixels, at native resolution, without its shadow.
pub fn capture_window(window_number: u32, path: &str) -> Result<(usize, usize), String> {
    plan_windows(&[window_number], None)?;
    // CGRectNull: the window's own bounds. kCGWindowListOptionIncludingWindow
    // = 8; kCGWindowImageBoundsIgnoreFraming = 1 | BestResolution = 8.
    capture(CGRect::NULL, 8, window_number, 1 | 8, path)
}

fn capture(
    rect: CGRect,
    list: u32,
    wid: u32,
    opts: u32,
    path: &str,
) -> Result<(usize, usize), String> {
    let f = create_image_fn().ok_or("CGWindowListCreateImage unavailable")?;
    // SAFETY: a CoreGraphics call whose image write_png releases.
    unsafe { write_png(f(rect, list, wid, opts), path) }
}

/// Writes `img` (an owned CGImage, released here; null is an error) to a PNG.
///
/// # Safety
///
/// `img` must be null or a CGImage the caller owns.
unsafe fn write_png(img: *mut c_void, path: &str) -> Result<(usize, usize), String> {
    // SAFETY: CoreGraphics/ImageIO calls with owned, released references.
    unsafe {
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
        // No URL for this path (an empty one): CFRelease must never see null.
        if url.is_null() {
            CGImageRelease(img);
            return Err(format!("cannot write {path:?}"));
        }
        let ty = CString::new("public.png").unwrap_or_default();
        let ty = CFStringCreateWithCString(std::ptr::null(), ty.as_ptr(), 0x0800_0100);
        if ty.is_null() {
            CGImageRelease(img);
            CFRelease(url);
            return Err("cannot name the PNG type".into());
        }
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_capture_names_its_windows() {
        let rect = CGRect {
            x: 10.,
            y: 20.,
            w: 300.,
            h: 200.,
        };
        // Kept in the caller's order: CoreGraphics draws the first in front.
        let plan = plan_windows(&[42, 7], Some(rect)).unwrap();
        assert_eq!(plan.windows, vec![42, 7]);
        assert_eq!(plan.bounds, rect);
        assert_eq!(plan_windows(&[42], None).unwrap().bounds, CGRect::NULL);
    }

    /// A 1×1 image, as a capture would return.
    fn tiny_image() -> *mut c_void {
        #[link(name = "CoreGraphics", kind = "framework")]
        unsafe extern "C" {
            fn CGColorSpaceCreateDeviceRGB() -> *mut c_void;
            fn CGColorSpaceRelease(cs: *mut c_void);
            fn CGBitmapContextCreate(
                data: *mut c_void,
                width: usize,
                height: usize,
                bits: usize,
                row: usize,
                cs: *mut c_void,
                info: u32,
            ) -> *mut c_void;
            fn CGBitmapContextCreateImage(ctx: *mut c_void) -> *mut c_void;
            fn CGContextRelease(ctx: *mut c_void);
        }
        // SAFETY: a fresh bitmap context, released once its image is made.
        unsafe {
            let cs = CGColorSpaceCreateDeviceRGB();
            // kCGImageAlphaPremultipliedLast = 1.
            let ctx = CGBitmapContextCreate(std::ptr::null_mut(), 1, 1, 8, 0, cs, 1);
            let img = CGBitmapContextCreateImage(ctx);
            CGContextRelease(ctx);
            CGColorSpaceRelease(cs);
            img
        }
    }

    #[test]
    fn a_path_that_names_no_file_is_an_error() {
        let img = tiny_image();
        assert!(!img.is_null());
        // SAFETY: write_png takes ownership of the image and releases it.
        let written = unsafe { write_png(img, "") };
        assert!(written.is_err());
    }

    #[test]
    fn a_capture_without_a_window_is_refused() {
        assert!(plan_windows(&[], None).is_err());
        // The null window id would mean every window on screen.
        assert!(plan_windows(&[42, 0], None).is_err());
        assert!(capture_window(0, "/nonexistent/never.png").is_err());
    }
}
