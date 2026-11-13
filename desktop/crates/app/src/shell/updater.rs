//! Updates through Sparkle 2's `SPUStandardUpdaterController` (objc2).
//!
//! The framework is loaded at run time from `Contents/Frameworks`, so dev
//! builds, tests and `cargo run` neither link nor need it. Release bundles
//! carry it (`packaging/macos/bundle.sh`) along with the two Info.plist keys
//! Sparkle needs: `SUFeedURL` and `SUPublicEDKey`. When any of the three is
//! missing there is no updater, and "Check for Updates…" stays disabled.
//!
//! **Channels.** One appcast serves both: beta items carry
//! `<sparkle:channel>beta</sparkle:channel>`, and the delegate's
//! `allowedChannelsForUpdater:` answers `{"beta"}` only while Settings ›
//! About › "Receive beta updates" is on. Items without a channel are for
//! everyone. Turning betas off never goes back to an older version: the
//! next stable release that is newer than the installed beta is offered.
//!
//! What Sparkle decides (an update found, none, downloaded, installing, an
//! error) goes to the app log, for support and the release checks.

use std::cell::Cell;

use objc2::rc::{Allocated, Retained};
use objc2::runtime::{AnyClass, AnyObject, Bool, NSObjectProtocol};
use objc2::{AnyThread, DefinedClass, define_class, msg_send};
use objc2_foundation::{NSBundle, NSError, NSObject, NSSet, NSString};

/// The channel beta items carry in the appcast.
pub const BETA_CHANNEL: &str = "beta";

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
    delegate: Retained<Delegate>,
}

impl Updater {
    /// Loads Sparkle and starts the updater (automatic checks follow the
    /// user's Sparkle defaults; `SUEnableAutomaticChecks` in Info.plist
    /// turns them on without the first-run prompt). `beta` is the saved
    /// "Receive beta updates".
    pub fn start(beta: bool) -> Result<Self, Unavailable> {
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
        let delegate = Delegate::new(beta);
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
            delegate,
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

    /// "Receive beta updates". Turning it on looks for a beta at once (in
    /// the background: Sparkle shows something only when it finds one).
    pub fn set_beta(&self, on: bool) {
        let before = self.delegate.ivars().beta.replace(on);
        if on && !before && self.can_check() {
            // SAFETY: an updater method, on the main thread.
            unsafe {
                let _: () = msg_send![&*self.updater(), checkForUpdatesInBackground];
            }
        }
    }

    pub fn beta(&self) -> bool {
        self.delegate.ivars().beta.get()
    }
}

/// The channels Sparkle may offer: the default channel always, `beta` too
/// when the user asked for betas.
pub fn allowed_channels(beta: bool) -> Vec<&'static str> {
    if beta { vec![BETA_CHANNEL] } else { vec![] }
}

struct DelegateIvars {
    beta: Cell<bool>,
}

fn describe_item(item: &AnyObject) -> String {
    // SAFETY: SUAppcastItem property reads (nullable strings).
    unsafe {
        let display: Option<Retained<NSString>> = msg_send![item, displayVersionString];
        let version: Option<Retained<NSString>> = msg_send![item, versionString];
        let channel: Option<Retained<NSString>> = msg_send![item, channel];
        format!(
            "{} (build {}, channel {})",
            display.map(|s| s.to_string()).unwrap_or_default(),
            version.map(|s| s.to_string()).unwrap_or_default(),
            channel
                .map(|s| s.to_string())
                .unwrap_or_else(|| "default".into()),
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
    #[ivars = DelegateIvars]
    struct Delegate;

    unsafe impl NSObjectProtocol for Delegate {}

    impl Delegate {
        #[unsafe(method_id(allowedChannelsForUpdater:))]
        fn allowed_channels_for_updater(&self, _updater: &AnyObject) -> Retained<NSSet<NSString>> {
            let channels: Vec<Retained<NSString>> = allowed_channels(self.ivars().beta.get())
                .into_iter()
                .map(NSString::from_str)
                .collect();
            NSSet::from_retained_slice(&channels)
        }

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
    fn new(beta: bool) -> Retained<Self> {
        let this = Self::alloc().set_ivars(DelegateIvars {
            beta: Cell::new(beta),
        });
        // SAFETY: NSObject's designated initializer.
        unsafe { msg_send![super(this), init] }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn betas_are_offered_only_when_asked_for() {
        assert!(allowed_channels(false).is_empty());
        assert_eq!(allowed_channels(true), vec!["beta"]);
    }

    #[test]
    fn a_bare_binary_has_no_updater() {
        // Tests run outside a bundle: no Info.plist keys, no framework.
        assert!(matches!(
            Updater::start(false),
            Err(Unavailable::NotConfigured(_) | Unavailable::NoFramework)
        ));
    }
}
