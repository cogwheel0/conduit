//! Updates through Sparkle 2's `SPUStandardUpdaterController` (objc2).
//!
//! The framework is loaded at run time from `Contents/Frameworks`, so dev
//! builds, tests and `cargo run` neither link nor need it. Release bundles
//! carry it (`packaging/macos/bundle.sh`) along with the two Info.plist keys
//! Sparkle needs: `SUFeedURL` and `SUPublicEDKey`. When any of the three is
//! missing there is no updater, and "Check for Updates…" stays disabled.
//!
//! **One channel.** Releases are stable only: the appcast's items carry no
//! `sparkle:channel`, and the delegate names no other channel, so Sparkle
//! offers only items on its default channel.
//!
//! What Sparkle decides (an update found, none, downloaded, installing, an
//! error) goes to the app log, for support and the release checks.

use objc2::rc::{Allocated, Retained};
use objc2::runtime::{AnyClass, AnyObject, Bool, NSObjectProtocol};
use objc2::{AnyThread, define_class, msg_send};
use objc2_foundation::{NSBundle, NSError, NSObject, NSString};

/// Sparkle's `SUNoUpdateError` (SUErrors.h): the check found nothing newer.
const SU_NO_UPDATE_ERROR: isize = 1001;

/// Why there is no updater (logged once at launch).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Unavailable {
    /// Not inside a bundle that carries `Sparkle.framework`.
    NoFramework,
    /// The bundle lacks `SUFeedURL` or `SUPublicEDKey`.
    NotConfigured(&'static str),
    /// The framework would not load (signature, architecture).
    LoadFailed(String),
}

/// The running updater.
pub struct Updater {
    controller: Retained<AnyObject>,
    /// Kept alive here: the controller holds its delegate weakly.
    _delegate: Retained<Delegate>,
}

impl Updater {
    /// Loads Sparkle and starts the updater (automatic checks follow the
    /// user's Sparkle defaults; `SUEnableAutomaticChecks` in Info.plist
    /// turns them on without the first-run prompt).
    pub fn start() -> Result<Self, Unavailable> {
        let main = NSBundle::mainBundle();
        for key in ["SUFeedURL", "SUPublicEDKey"] {
            let value = main.objectForInfoDictionaryKey(&NSString::from_str(key));
            let set = value
                .and_then(|v| v.downcast::<NSString>().ok())
                .is_some_and(|s| !s.to_string().trim().is_empty());
            if !set {
                return Err(Unavailable::NotConfigured(key));
            }
        }
        let frameworks = main
            .privateFrameworksPath()
            .ok_or(Unavailable::NoFramework)?;
        let path = format!("{frameworks}/Sparkle.framework");
        if !std::path::Path::new(&path).is_dir() {
            return Err(Unavailable::NoFramework);
        }
        let bundle =
            NSBundle::bundleWithPath(&NSString::from_str(&path)).ok_or(Unavailable::NoFramework)?;
        // SAFETY: loads the framework's code into the process; it is signed
        // with the app (library validation holds it to the same team).
        unsafe { bundle.loadAndReturnError() }.map_err(|e: Retained<NSError>| {
            Unavailable::LoadFailed(e.localizedDescription().to_string())
        })?;
        let class = AnyClass::get(c"SPUStandardUpdaterController")
            .ok_or_else(|| Unavailable::LoadFailed("no SPUStandardUpdaterController".into()))?;
        let delegate = Delegate::new();
        // SAFETY: `+alloc` on an NSObject subclass, then its designated
        // initializer (`startingUpdater:` YES starts the update cycle now,
        // on the main thread). The controller keeps the delegate weakly;
        // `Updater` owns both.
        let controller: Retained<AnyObject> = unsafe {
            let alloc: Allocated<AnyObject> = msg_send![class, alloc];
            msg_send![
                alloc,
                initWithStartingUpdater: Bool::YES,
                updaterDelegate: &*delegate,
                userDriverDelegate: Option::<&AnyObject>::None,
            ]
        };
        Ok(Self {
            controller,
            _delegate: delegate,
        })
    }

    fn updater(&self) -> Retained<AnyObject> {
        // SAFETY: a property read on the controller.
        unsafe { msg_send![&*self.controller, updater] }
    }

    /// "Check for Updates…": Sparkle's own window shows progress, the
    /// update or "You're up to date".
    pub fn check_for_updates(&self) {
        // SAFETY: the controller's IBAction; the sender may be nil.
        unsafe {
            let _: () = msg_send![
                &*self.controller,
                checkForUpdates: Option::<&AnyObject>::None
            ];
        }
    }

    /// Whether a check can start now (not while one runs).
    pub fn can_check(&self) -> bool {
        // SAFETY: a property read on the updater.
        unsafe { msg_send![&*self.updater(), canCheckForUpdates] }
    }

    /// Sparkle's "check automatically" (kept in its user defaults).
    pub fn automatic_checks(&self) -> bool {
        // SAFETY: a property read on the updater.
        unsafe { msg_send![&*self.updater(), automaticallyChecksForUpdates] }
    }

    pub fn set_automatic_checks(&self, on: bool) {
        // SAFETY: a property write on the updater, on the main thread.
        unsafe {
            let _: () = msg_send![
                &*self.updater(),
                setAutomaticallyChecksForUpdates: Bool::new(on)
            ];
        }
    }
}

fn describe_item(item: &AnyObject) -> String {
    // SAFETY: SUAppcastItem property reads (nullable strings).
    unsafe {
        let display: Option<Retained<NSString>> = msg_send![item, displayVersionString];
        let version: Option<Retained<NSString>> = msg_send![item, versionString];
        format!(
            "{} (build {})",
            display.map(|s| s.to_string()).unwrap_or_default(),
            version.map(|s| s.to_string()).unwrap_or_default(),
        )
    }
}

fn describe_error(error: &NSError) -> String {
    format!("{} (code {})", error.localizedDescription(), error.code())
}

define_class!(
    // SAFETY: NSObject has no subclassing requirements and `Delegate` does
    // not implement Drop. Sparkle asks `respondsToSelector:` before each
    // optional SPUUpdaterDelegate method, so no protocol declaration is
    // needed.
    #[unsafe(super(NSObject))]
    struct Delegate;

    unsafe impl NSObjectProtocol for Delegate {}

    impl Delegate {
        #[unsafe(method(updater:didFindValidUpdate:))]
        fn did_find_valid_update(&self, _updater: &AnyObject, item: &AnyObject) {
            log::info!("updates: found {}", describe_item(item));
        }

        #[unsafe(method(updaterDidNotFindUpdate:error:))]
        fn did_not_find_update(&self, _updater: &AnyObject, error: &NSError) {
            log::info!("updates: none ({})", describe_error(error));
        }

        #[unsafe(method(updater:didDownloadUpdate:))]
        fn did_download_update(&self, _updater: &AnyObject, item: &AnyObject) {
            log::info!("updates: downloaded {}", describe_item(item));
        }

        #[unsafe(method(updater:failedToDownloadUpdate:error:))]
        fn failed_to_download(&self, _updater: &AnyObject, item: &AnyObject, error: &NSError) {
            log::warn!(
                "updates: download of {} failed: {}",
                describe_item(item),
                describe_error(error)
            );
        }

        #[unsafe(method(updater:willInstallUpdate:))]
        fn will_install_update(&self, _updater: &AnyObject, item: &AnyObject) {
            log::info!("updates: installing {}", describe_item(item));
        }

        #[unsafe(method(updaterWillRelaunchApplication:))]
        fn will_relaunch(&self, _updater: &AnyObject) {
            log::info!("updates: relaunching into the new version");
        }

        #[unsafe(method(updater:didAbortWithError:))]
        fn did_abort(&self, _updater: &AnyObject, error: &NSError) {
            // Sparkle ends a check that found nothing this way too, after
            // `updaterDidNotFindUpdate:error:` has said so.
            if error.code() != SU_NO_UPDATE_ERROR {
                log::warn!("updates: stopped: {}", describe_error(error));
            }
        }
    }
);

impl Delegate {
    fn new() -> Retained<Self> {
        let this = Self::alloc().set_ivars(());
        // SAFETY: NSObject's designated initializer.
        unsafe { msg_send![super(this), init] }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_bare_binary_has_no_updater() {
        // Tests run outside a bundle: no Info.plist keys, no framework.
        assert!(matches!(
            Updater::start(),
            Err(Unavailable::NotConfigured(_) | Unavailable::NoFramework)
        ));
    }
}
