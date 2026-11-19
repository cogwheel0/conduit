//! Open at login through `SMAppService.mainApp` (macOS 13+), and telling a
//! login launch apart from one the user made.
//!
//! The system starts a login item without arguments, so a login launch is
//! recognised by the open-application Apple event (`keyAELaunchedAsLogInItem`)
//! as well as by `--hidden` (for a manual check). A hidden start installs
//! only the menu-bar item, when "Close to menu bar" is on.

use objc2::msg_send;
use objc2::rc::Retained;
use objc2_foundation::{NSAppleEventDescriptor, NSAppleEventManager, NSString};
use objc2_service_management::{SMAppService, SMAppServiceStatus};

/// What the system says about the app's login item.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LoginItemStatus {
    NotRegistered,
    Enabled,
    /// Registered, but the user has to allow it in System Settings ›
    /// General › Login Items.
    RequiresApproval,
    /// The system can't find the app (e.g. run from a build folder that
    /// moved).
    NotFound,
}

impl LoginItemStatus {
    fn from_raw(status: SMAppServiceStatus) -> Self {
        match status {
            SMAppServiceStatus::Enabled => Self::Enabled,
            SMAppServiceStatus::RequiresApproval => Self::RequiresApproval,
            SMAppServiceStatus::NotFound => Self::NotFound,
            _ => Self::NotRegistered,
        }
    }

    /// Whether the switch reads as on.
    pub fn is_on(self) -> bool {
        matches!(self, Self::Enabled | Self::RequiresApproval)
    }
}

fn service() -> Retained<SMAppService> {
    // SAFETY: a class method with no preconditions (macOS 13+, the app's
    // minimum).
    unsafe { SMAppService::mainAppService() }
}

/// The login item's status now.
pub fn status() -> LoginItemStatus {
    // SAFETY: a property read on the shared service.
    LoginItemStatus::from_raw(unsafe { service().status() })
}

/// Registers (`true`) or unregisters the app as a login item; the status
/// after, or the system's reason.
pub fn set(enabled: bool) -> Result<LoginItemStatus, String> {
    let service = service();
    // SAFETY: SMAppService calls with an out-error, on the main thread.
    let result = unsafe {
        if enabled {
            service.registerAndReturnError()
        } else {
            service.unregisterAndReturnError()
        }
    };
    match result {
        Ok(()) => Ok(status()),
        Err(e) => {
            let text = e.localizedDescription().to_string();
            // Unregistering what was never registered is not a failure.
            if !enabled && status() == LoginItemStatus::NotRegistered {
                return Ok(LoginItemStatus::NotRegistered);
            }
            Err(text)
        }
    }
}

/// Opens System Settings › General › Login Items.
pub fn open_settings() {
    // SAFETY: a class method with no preconditions.
    unsafe { SMAppService::openSystemSettingsLoginItems() };
}

/// `kAEOpenApplication` and `keyAEPropData` / `keyAELaunchedAsLogInItem`.
const OPEN_APPLICATION: u32 = u32::from_be_bytes(*b"oapp");
const PROP_DATA: u32 = u32::from_be_bytes(*b"prdt");
const LAUNCHED_AS_LOGIN_ITEM: u32 = u32::from_be_bytes(*b"lgit");

/// Whether this launch is the system starting the login item. Only
/// meaningful while the app finishes launching (the open-application event
/// is the current Apple event then).
pub fn launched_as_login_item() -> bool {
    let manager = NSAppleEventManager::sharedAppleEventManager();
    let Some(event) = manager.currentAppleEvent() else {
        return false;
    };
    // SAFETY: NSAppleEventDescriptor methods (typed only behind the
    // CoreServices feature); `eventID` is an AEEventID (u32) and
    // `paramDescriptorForKeyword:` takes an AEKeyword (u32).
    let id: u32 = unsafe { msg_send![&*event, eventID] };
    if id != OPEN_APPLICATION {
        return false;
    }
    let prop: Option<Retained<NSAppleEventDescriptor>> =
        unsafe { msg_send![&*event, paramDescriptorForKeyword: PROP_DATA] };
    prop.is_some_and(|d| d.enumCodeValue() == LAUNCHED_AS_LOGIN_ITEM)
}

/// For the log: the bundle the login item points at.
pub fn describe() -> String {
    let bundle = objc2_foundation::NSBundle::mainBundle();
    let id = bundle
        .bundleIdentifier()
        .unwrap_or_else(|| NSString::from_str("(none)"));
    format!("{id} at {}", bundle.bundlePath())
}
