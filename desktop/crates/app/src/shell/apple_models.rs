//! Apple's on-device Foundation Models: the Swift engine in `apple/`
//! (linked by build.rs), which runs the daemon's `apple.command`s and
//! answers each, and tells what a run did, as an `apple.report`.
//!
//! The wire crosses as JSON both ways: [`command`] hands the engine an
//! `AppleCommand`, and the engine's reports, from any thread, arrive on the
//! channel [`install`] returns. Private Cloud Compute is never compiled in
//! (FoundationModels traps without its entitlement).
//!
//! `CONDUIT_APPLE_ENGINE=fake` (debug builds only) puts the engine's
//! scripted model in place of Apple's, for the `--e2e apple` pass.

use futures::channel::mpsc;

/// Whether the scripted model stands in for Apple's: debug builds asked
/// for it with `CONDUIT_APPLE_ENGINE=fake`.
pub fn fake() -> bool {
    cfg!(debug_assertions) && std::env::var("CONDUIT_APPLE_ENGINE").as_deref() == Ok("fake")
}

#[cfg(target_os = "macos")]
mod engine {
    use std::ffi::{CStr, CString, c_char};
    use std::sync::Mutex;

    use futures::channel::mpsc;

    unsafe extern "C" {
        fn conduit_apple_install(sink: extern "C" fn(*const c_char), fake: bool);
        fn conduit_apple_supported() -> bool;
        fn conduit_apple_command(json: *const c_char);
    }

    static SINK: Mutex<Option<mpsc::UnboundedSender<String>>> = Mutex::new(None);

    extern "C" fn on_report(json: *const c_char) {
        if json.is_null() {
            return;
        }
        // SAFETY: the engine passes a NUL-terminated string that lives for
        // the call.
        let text = unsafe { CStr::from_ptr(json) }
            .to_string_lossy()
            .into_owned();
        if let Ok(sink) = SINK.lock()
            && let Some(tx) = sink.as_ref()
        {
            let _ = tx.unbounded_send(text);
        }
    }

    pub fn install(fake: bool) -> mpsc::UnboundedReceiver<String> {
        let (tx, rx) = mpsc::unbounded();
        if let Ok(mut sink) = SINK.lock() {
            *sink = Some(tx);
        }
        // SAFETY: `on_report` is a plain C function for the life of the
        // process.
        unsafe { conduit_apple_install(on_report, fake) };
        rx
    }

    pub fn supported() -> bool {
        // SAFETY: no arguments; the engine reads the OS version.
        unsafe { conduit_apple_supported() }
    }

    pub fn set_fake(fake: bool) {
        // SAFETY: as in `install`; the sink stays the one installed.
        unsafe { conduit_apple_install(on_report, fake) };
    }

    pub fn command(json: &str) {
        let Ok(json) = CString::new(json) else {
            return;
        };
        // SAFETY: a NUL-terminated string the engine copies before return.
        unsafe { conduit_apple_command(json.as_ptr()) };
    }
}

#[cfg(not(target_os = "macos"))]
mod engine {
    use std::sync::Mutex;

    use futures::channel::mpsc;

    static SINK: Mutex<Option<mpsc::UnboundedSender<String>>> = Mutex::new(None);

    pub fn install(_fake: bool) -> mpsc::UnboundedReceiver<String> {
        let (tx, rx) = mpsc::unbounded();
        if let Ok(mut sink) = SINK.lock() {
            *sink = Some(tx);
        }
        rx
    }

    pub fn supported() -> bool {
        false
    }

    pub fn set_fake(_fake: bool) {}

    /// No Apple models off the Mac: each command is refused at once.
    pub fn command(json: &str) {
        let id = serde_json::from_str::<serde_json::Value>(json)
            .ok()
            .and_then(|v| v.get("id").and_then(|id| id.as_i64()));
        let report = serde_json::json!({
            "id": id,
            "ok": false,
            "error": "Apple's models need macOS",
        });
        if let Ok(sink) = SINK.lock()
            && let Some(tx) = sink.as_ref()
        {
            let _ = tx.unbounded_send(report.to_string());
        }
    }
}

/// Points the engine's reports at a new channel (one per app: the Apple
/// store's) and says whether the scripted model stands in.
pub fn install() -> mpsc::UnboundedReceiver<String> {
    engine::install(fake())
}

/// Whether this macOS has Apple's models (26 or later), or the scripted one
/// stands in.
pub fn supported() -> bool {
    engine::supported()
}

/// Puts the scripted model in place of Apple's from now on: the `--e2e
/// apple` pass reads this Mac's real status first, then switches. Debug
/// builds only; a release build keeps Apple's.
pub fn use_fake() {
    if cfg!(debug_assertions) {
        engine::set_fake(true);
    }
}

/// Runs one `apple.command` (as JSON); its answer comes on the channel.
pub fn command(json: &str) {
    engine::command(json)
}
