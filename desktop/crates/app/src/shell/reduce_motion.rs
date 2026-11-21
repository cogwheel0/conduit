//! macOS's Reduce Motion (System Settings › Accessibility › Display), kept
//! in [`App::reduce_motion`], which every transition reads
//! ([`conduit_components::motion`]): movement and size changes turn
//! instant, fades become plain crossfades.
//!
//! `CONDUIT_REDUCE_MOTION=1` (or `0`) overrides the system for a run (the
//! capture harness shows both).

use gpui_kit::App;

/// The override from the environment, if any.
fn forced() -> Option<bool> {
    match std::env::var("CONDUIT_REDUCE_MOTION").ok()?.trim() {
        "1" | "true" | "on" => Some(true),
        "0" | "false" | "off" => Some(false),
        _ => None,
    }
}

/// Reads the setting now and follows it from then on.
pub fn install(cx: &mut App) {
    if let Some(on) = forced() {
        cx.set_reduce_motion(on);
    } else {
        #[cfg(target_os = "macos")]
        {
            cx.set_reduce_motion(system::reduce_motion());
            let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel::<()>();
            system::on_change(move || {
                let _ = tx.send(());
            });
            cx.spawn(async move |cx| {
                while rx.recv().await.is_some() {
                    cx.update(|cx| cx.set_reduce_motion(system::reduce_motion()));
                }
            })
            .detach();
        }
    }
}

#[cfg(target_os = "macos")]
mod system {
    use block2::RcBlock;
    use objc2::runtime::{AnyObject, Bool};
    use objc2::{class, msg_send};
    use objc2_foundation::NSString;

    /// `NSWorkspace.accessibilityDisplayShouldReduceMotion`.
    pub fn reduce_motion() -> bool {
        // SAFETY: a read-only property of the shared workspace.
        unsafe {
            let workspace: *mut AnyObject = msg_send![class!(NSWorkspace), sharedWorkspace];
            let on: Bool = msg_send![workspace, accessibilityDisplayShouldReduceMotion];
            on.as_bool()
        }
    }

    /// Calls `changed` on the main thread whenever the display options
    /// change (Reduce Motion, Increase Contrast, Reduce Transparency).
    pub fn on_change(changed: impl Fn() + 'static) {
        let block = RcBlock::new(move |_: *mut AnyObject| changed());
        let name =
            NSString::from_str("NSWorkspaceAccessibilityDisplayOptionsDidChangeNotification");
        // SAFETY: Foundation calls on the main thread; the observer is kept
        // for the life of the process (the token is retained, never removed).
        unsafe {
            let workspace: *mut AnyObject = msg_send![class!(NSWorkspace), sharedWorkspace];
            let center: *mut AnyObject = msg_send![workspace, notificationCenter];
            let queue: *mut AnyObject = msg_send![class!(NSOperationQueue), mainQueue];
            let token: *mut AnyObject = msg_send![
                center,
                addObserverForName: &*name,
                object: std::ptr::null_mut::<AnyObject>(),
                queue: queue,
                usingBlock: &*block
            ];
            let _: *mut AnyObject = msg_send![token, retain];
        }
    }
}
