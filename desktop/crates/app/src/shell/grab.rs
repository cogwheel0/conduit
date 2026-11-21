//! Pixels from this process's own windows, for the scripted runs: its
//! on-screen windows, named by id and composited within a screen rect, or
//! one window alone, kept as a [`Frame`] so it can be compared, cropped or
//! written later, from any thread. Every capture names the windows it
//! takes, so another app's window (or a notification) never ends up in one.
//! Even a capture of the app's own windows can make macOS ask for Screen
//! Recording access, so nothing in ordinary use captures.

use std::ffi::{CString, c_void};
use std::path::Path;

pub use conduit_components::capture::CGRect;

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
    fn CFDataGetLength(data: *const c_void) -> isize;
    fn CFDataGetBytePtr(data: *const c_void) -> *const u8;
    fn CFArrayCreate(
        alloc: *const c_void,
        values: *const *const c_void,
        count: isize,
        callbacks: *const c_void,
    ) -> *const c_void;
    fn CFArrayGetCount(array: *const c_void) -> isize;
    fn CFArrayGetValueAtIndex(array: *const c_void, index: isize) -> *const c_void;
    fn CFDictionaryGetValue(dict: *const c_void, key: *const c_void) -> *const c_void;
    fn CFNumberGetValue(number: *const c_void, ty: isize, out: *mut c_void) -> bool;
}

#[link(name = "CoreGraphics", kind = "framework")]
unsafe extern "C" {
    fn CGImageRelease(img: *mut c_void);
    fn CGImageGetWidth(img: *mut c_void) -> usize;
    fn CGImageGetHeight(img: *mut c_void) -> usize;
    fn CGImageGetBytesPerRow(img: *mut c_void) -> usize;
    fn CGImageGetDataProvider(img: *mut c_void) -> *mut c_void;
    fn CGDataProviderCopyData(provider: *mut c_void) -> *const c_void;
    fn CGImageCreateWithImageInRect(img: *mut c_void, rect: CGRect) -> *mut c_void;
    fn CGWindowListCopyWindowInfo(option: u32, relative_to: u32) -> *const c_void;
    static kCGWindowOwnerPID: *const c_void;
    static kCGWindowNumber: *const c_void;
}

unsafe extern "C" {
    fn dlsym(handle: *mut c_void, symbol: *const std::ffi::c_char) -> *mut c_void;
}

const RTLD_DEFAULT: *mut c_void = -2isize as *mut c_void;
/// kCGWindowListOptionOnScreenOnly.
pub const ON_SCREEN_ONLY: u32 = 1;
/// kCGWindowListOptionIncludingWindow.
const INCLUDING_WINDOW: u32 = 8;
/// kCGWindowImageBoundsIgnoreFraming.
const IGNORE_FRAMING: u32 = 1;
/// kCGWindowImageBestResolution (the display's pixels).
const BEST_RESOLUTION: u32 = 8;
/// kCGWindowImageNominalResolution (one pixel a point).
const NOMINAL_RESOLUTION: u32 = 16;
/// kCFNumberSInt64Type.
const SINT64: isize = 4;

fn symbol(name: &str) -> Option<*mut c_void> {
    let name = CString::new(name).ok()?;
    // SAFETY: dlsym with RTLD_DEFAULT and a NUL-terminated name.
    let p = unsafe { dlsym(RTLD_DEFAULT, name.as_ptr()) };
    (!p.is_null()).then_some(p)
}

fn create_image_fn() -> Option<CreateImageFn> {
    let p = symbol("CGWindowListCreateImage")?;
    // SAFETY: the symbol has this C signature.
    Some(unsafe { std::mem::transmute::<*mut c_void, CreateImageFn>(p) })
}

fn create_image_from_array_fn() -> Option<CreateImageFromArrayFn> {
    let p = symbol("CGWindowListCreateImageFromArray")?;
    // SAFETY: the symbol has this C signature.
    Some(unsafe { std::mem::transmute::<*mut c_void, CreateImageFromArrayFn>(p) })
}

/// The ids (CGWindowIDs) of this process's on-screen windows, front to
/// back: its windows, sheets, panels and open menus, and nothing of another
/// process.
pub fn own_window_ids() -> Vec<u32> {
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
            if let Some(id) = number(dict, kCGWindowNumber).and_then(|n| u32::try_from(n).ok()) {
                out.push(id);
            }
        }
        CFRelease(list);
    }
    out
}

/// A captured image (a retained CGImage). CGImages are immutable, so one
/// can go to another thread.
pub struct Frame(*mut c_void);

// SAFETY: a CGImage is immutable and its retain count is atomic.
unsafe impl Send for Frame {}

impl Drop for Frame {
    fn drop(&mut self) {
        // SAFETY: we own one reference.
        unsafe { CGImageRelease(self.0) }
    }
}

impl Frame {
    /// The screen rect `rect` (global points, top-left origin), with every
    /// on-screen window of ours in it and nothing of another app's: what
    /// lies behind our windows there is left transparent. `full`: the
    /// display's pixels, else one a point.
    pub fn of_rect(rect: CGRect, full: bool) -> Option<Self> {
        Self::of_windows(&own_window_ids(), rect, full)
    }

    /// Only `windows` (this process's, by CGWindowID, front to back),
    /// composited within `rect`. `None` for an empty list or the null id,
    /// which CoreGraphics would read as every window on screen.
    pub fn of_windows(windows: &[u32], rect: CGRect, full: bool) -> Option<Self> {
        let plan = conduit_components::capture::plan_windows(windows, Some(rect)).ok()?;
        let f = create_image_from_array_fn()?;
        let res = if full {
            BEST_RESOLUTION
        } else {
            NOMINAL_RESOLUTION
        };
        let ids: Vec<*const c_void> = plan
            .windows
            .iter()
            .map(|&id| id as usize as *const c_void)
            .collect();
        // SAFETY: an array of raw CGWindowIDs with no callbacks, as
        // CoreGraphics documents for this call; released after it. Null
        // means no image.
        unsafe {
            let array = CFArrayCreate(
                std::ptr::null(),
                ids.as_ptr(),
                ids.len() as isize,
                std::ptr::null(),
            );
            if array.is_null() {
                return None;
            }
            let img = f(plan.bounds, array, res);
            CFRelease(array);
            (!img.is_null()).then_some(Self(img))
        }
    }

    /// One window by its number, alone, without its shadow.
    pub fn of_window(number: u32, full: bool) -> Option<Self> {
        let null = CGRect {
            x: f64::INFINITY,
            y: f64::INFINITY,
            w: 0.,
            h: 0.,
        };
        let res = if full {
            BEST_RESOLUTION
        } else {
            NOMINAL_RESOLUTION
        };
        Self::create(null, INCLUDING_WINDOW, number, IGNORE_FRAMING | res)
    }

    fn create(rect: CGRect, list: u32, wid: u32, opts: u32) -> Option<Self> {
        let f = create_image_fn()?;
        // SAFETY: the documented C call; null means no image.
        let img = unsafe { f(rect, list, wid, opts) };
        (!img.is_null()).then_some(Self(img))
    }

    /// The CGImage, still owned by this frame (retain it to keep it).
    pub fn as_ptr(&self) -> *mut c_void {
        self.0
    }

    pub fn size(&self) -> (usize, usize) {
        // SAFETY: a live CGImage.
        unsafe { (CGImageGetWidth(self.0), CGImageGetHeight(self.0)) }
    }

    /// A part of the image, in its own pixels.
    pub fn crop(&self, x: f64, y: f64, w: f64, h: f64) -> Option<Self> {
        // SAFETY: a live CGImage; the result is a new reference or null.
        let img = unsafe { CGImageCreateWithImageInRect(self.0, CGRect { x, y, w, h }) };
        (!img.is_null()).then_some(Self(img))
    }

    /// The pixels (BGRA as the window server keeps them) and the row stride.
    pub fn pixels(&self) -> Option<(Vec<u8>, usize)> {
        // SAFETY: a live CGImage; the copied data is released after use.
        unsafe {
            let provider = CGImageGetDataProvider(self.0);
            if provider.is_null() {
                return None;
            }
            let data = CGDataProviderCopyData(provider);
            if data.is_null() {
                return None;
            }
            let len = CFDataGetLength(data) as usize;
            let bytes = std::slice::from_raw_parts(CFDataGetBytePtr(data), len).to_vec();
            CFRelease(data);
            Some((bytes, CGImageGetBytesPerRow(self.0)))
        }
    }

    /// A cheap fingerprint of the pixels, to tell identical frames apart.
    pub fn fingerprint(&self) -> u64 {
        use std::hash::{Hash, Hasher};
        let mut h = std::collections::hash_map::DefaultHasher::new();
        if let Some((bytes, _)) = self.pixels() {
            bytes.hash(&mut h);
        }
        h.finish()
    }

    /// Writes a PNG.
    pub fn write_png(&self, path: &Path) -> Result<(usize, usize), String> {
        let path_str = path.to_string_lossy().to_string();
        // SAFETY: CoreFoundation/ImageIO calls with owned, released references.
        unsafe {
            let url = CFURLCreateFromFileSystemRepresentation(
                std::ptr::null(),
                path_str.as_ptr(),
                path_str.len() as isize,
                false,
            );
            // A path that names no file gives no URL: never hand ImageIO, or
            // CFRelease, a null.
            if url.is_null() {
                return Err(format!("cannot write {path_str}"));
            }
            let ty = CString::new("public.png").unwrap_or_default();
            let ty = CFStringCreateWithCString(std::ptr::null(), ty.as_ptr(), 0x0800_0100);
            if ty.is_null() {
                CFRelease(url);
                return Err("no PNG type".into());
            }
            let dest = CGImageDestinationCreateWithURL(url, ty, 1, std::ptr::null());
            if dest.is_null() {
                CFRelease(url);
                CFRelease(ty);
                return Err(format!("cannot write {path_str}"));
            }
            CGImageDestinationAddImage(dest, self.0, std::ptr::null());
            let ok = CGImageDestinationFinalize(dest);
            CFRelease(dest);
            CFRelease(url);
            CFRelease(ty);
            if ok {
                Ok(self.size())
            } else {
                Err("PNG finalize failed".into())
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A 1×1 image, as a capture would return.
    fn tiny() -> Frame {
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
            let ctx = CGBitmapContextCreate(std::ptr::null_mut(), 1, 1, 8, 0, cs, 1);
            let img = CGBitmapContextCreateImage(ctx);
            CGContextRelease(ctx);
            CGColorSpaceRelease(cs);
            Frame(img)
        }
    }

    #[test]
    fn a_path_that_names_no_file_is_an_error() {
        assert!(tiny().write_png(Path::new("")).is_err());
    }
}
