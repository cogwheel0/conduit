//! The Mac's location services, for `{{USER_LOCATION}}`: the window's half
//! of `location.*`.
//!
//! The daemon decides when to ask (the core's location policy): only for a
//! request or a prompt template that names `{{USER_LOCATION}}`, and only
//! while the account's location setting is on. Each `location.command` is
//! answered here ([`Engine::answer`]) and goes back as `location.report`
//! ([`crate::stores::location`]).
//!
//! Two engines:
//!
//! * **CoreLocation** (`CLLocationManager`), the app's own: status never
//!   asks the user anything; a permission request shows the system's prompt
//!   the first time (Info.plist's `NSLocationUsageDescription`, in every
//!   language); a fix is one `requestLocation`.
//! * **A stand-in**, for every scripted run (`crate::scripted::active`:
//!   a pass, the capture, a probe or a fixture) and
//!   `CONDUIT_LOCATION_STANDIN=<lat>,<lon>`: it never touches
//!   CoreLocation, so no test can raise the system's prompt. With no
//!   position it reads as location services off.

use std::sync::Mutex;
use std::sync::atomic::{AtomicUsize, Ordering};

use conduit_protocol::{LocationCommand, LocationCommandKind, LocationPermission, LocationReport};
use futures::channel::oneshot;

/// A position, in degrees.
pub type Fix = (f64, f64);

/// Which engine answers.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Mode {
    /// CoreLocation.
    System,
    /// The stand-in, with its position (none: services off).
    StandIn(Option<Fix>),
}

static MODE: Mutex<Mode> = Mutex::new(Mode::System);

/// How many commands the stand-in answered (for `--e2e mac-extras-2`).
static STAND_IN_ANSWERED: AtomicUsize = AtomicUsize::new(0);

/// How many commands CoreLocation was asked (must stay 0 in scripted runs).
static SYSTEM_ASKED: AtomicUsize = AtomicUsize::new(0);

/// Chooses the engine at launch: the stand-in for a scripted run or when
/// `CONDUIT_LOCATION_STANDIN` is set (`<lat>,<lon>`, or anything else for
/// services off), CoreLocation otherwise.
pub fn choose(scripted: bool, stand_in: Option<String>) {
    let mode = match stand_in {
        Some(value) => Mode::StandIn(parse_fix(&value)),
        None if scripted => Mode::StandIn(None),
        None => Mode::System,
    };
    set_mode(mode);
}

pub fn set_mode(mode: Mode) {
    *MODE.lock().unwrap_or_else(|e| e.into_inner()) = mode;
}

pub fn mode() -> Mode {
    *MODE.lock().unwrap_or_else(|e| e.into_inner())
}

/// What the stand-in and CoreLocation have answered so far.
pub fn counts() -> (usize, usize) {
    (
        STAND_IN_ANSWERED.load(Ordering::SeqCst),
        SYSTEM_ASKED.load(Ordering::SeqCst),
    )
}

/// `<lat>,<lon>` in degrees, each in range.
pub fn parse_fix(value: &str) -> Option<Fix> {
    let (lat, lon) = value.split_once(',')?;
    let lat: f64 = lat.trim().parse().ok()?;
    let lon: f64 = lon.trim().parse().ok()?;
    ((-90.0..=90.0).contains(&lat) && (-180.0..=180.0).contains(&lon)).then_some((lat, lon))
}

/// The stand-in's answer to `command`.
pub fn stand_in_report(command: &LocationCommand, fix: Option<Fix>) -> LocationReport {
    let permission = if fix.is_some() {
        LocationPermission::WhileInUse
    } else {
        LocationPermission::Denied
    };
    let base = LocationReport {
        id: command.id,
        ok: true,
        error: None,
        services_enabled: None,
        permission: None,
        latitude: None,
        longitude: None,
    };
    match command.kind {
        LocationCommandKind::Status => LocationReport {
            services_enabled: Some(fix.is_some()),
            permission: Some(permission),
            ..base
        },
        LocationCommandKind::RequestPermission => LocationReport {
            permission: Some(permission),
            ..base
        },
        LocationCommandKind::CurrentPosition => match fix {
            Some((lat, lon)) => LocationReport {
                latitude: Some(lat),
                longitude: Some(lon),
                ..base
            },
            None => LocationReport {
                ok: false,
                error: Some("no position".into()),
                ..base
            },
        },
        LocationCommandKind::Unknown => LocationReport {
            ok: false,
            error: Some("unknown command".into()),
            ..base
        },
    }
}

/// Answers `command` with the chosen engine; the report comes on the
/// receiver (CoreLocation answers a fix or a permission later, from its
/// delegate). Main thread only.
pub fn answer(command: &LocationCommand) -> oneshot::Receiver<LocationReport> {
    let (sender, receiver) = oneshot::channel();
    match mode() {
        Mode::StandIn(fix) => {
            STAND_IN_ANSWERED.fetch_add(1, Ordering::SeqCst);
            let _ = sender.send(stand_in_report(command, fix));
        }
        // A scripted run never asks macOS (`crate::scripted`), whatever
        // engine was chosen: a permission request would leave the
        // system's prompt on screen.
        Mode::System if crate::scripted::active() => {
            let _ = sender.send(stand_in_report(command, None));
        }
        Mode::System => {
            SYSTEM_ASKED.fetch_add(1, Ordering::SeqCst);
            #[cfg(target_os = "macos")]
            system::answer(command, sender);
            #[cfg(not(target_os = "macos"))]
            let _ = sender.send(stand_in_report(command, None));
        }
    }
    receiver
}

/// CoreLocation's authorization status as the core's port says it (the
/// phone's plugin maps iOS's the same way): not determined is `denied`, so
/// the core asks; restricted or refused is `deniedForever`.
pub fn permission_of(status: i32) -> LocationPermission {
    match status {
        3 => LocationPermission::Always,
        4 => LocationPermission::WhileInUse,
        1 | 2 => LocationPermission::DeniedForever,
        _ => LocationPermission::Denied,
    }
}

#[cfg(target_os = "macos")]
mod system {
    use std::cell::RefCell;

    use futures::channel::oneshot;
    use objc2::encode::{Encode, Encoding};
    use objc2::rc::Retained;
    use objc2::runtime::{AnyClass, AnyObject, Bool, NSObject};
    use objc2::{AnyThread, DefinedClass, define_class, msg_send};
    use objc2_foundation::{NSArray, NSError};

    use super::{LocationCommand, LocationCommandKind, LocationReport, permission_of};

    #[link(name = "CoreLocation", kind = "framework")]
    unsafe extern "C" {}

    /// `CLLocationCoordinate2D`.
    #[repr(C)]
    #[derive(Clone, Copy, Debug)]
    struct Coordinate {
        latitude: f64,
        longitude: f64,
    }

    // SAFETY: matches CoreLocation's struct of two doubles.
    unsafe impl Encode for Coordinate {
        const ENCODING: Encoding =
            Encoding::Struct("CLLocationCoordinate2D", &[f64::ENCODING, f64::ENCODING]);
    }

    type Waiting = Vec<(i64, oneshot::Sender<LocationReport>)>;

    #[derive(Default)]
    struct DelegateIvars {
        fixes: RefCell<Waiting>,
        permissions: RefCell<Waiting>,
    }

    define_class!(
        // SAFETY: NSObject has no subclassing requirements and `Delegate`
        // does not implement Drop.
        #[unsafe(super(NSObject))]
        #[name = "ConduitLocationDelegate"]
        #[ivars = DelegateIvars]
        struct Delegate;

        impl Delegate {
            #[unsafe(method(locationManager:didUpdateLocations:))]
            fn did_update(&self, _manager: &AnyObject, locations: &NSArray<AnyObject>) {
                let Some(location) = locations.lastObject() else {
                    return;
                };
                // SAFETY: a CLLocation's coordinate.
                let c: Coordinate = unsafe { msg_send![&*location, coordinate] };
                for (id, sender) in self.ivars().fixes.take() {
                    let _ = sender.send(LocationReport {
                        id,
                        ok: true,
                        error: None,
                        services_enabled: None,
                        permission: None,
                        latitude: Some(c.latitude),
                        longitude: Some(c.longitude),
                    });
                }
            }

            #[unsafe(method(locationManager:didFailWithError:))]
            fn did_fail(&self, _manager: &AnyObject, error: &NSError) {
                let text = error.localizedDescription().to_string();
                for (id, sender) in self.ivars().fixes.take() {
                    let _ = sender.send(failed(id, &text));
                }
            }

            #[unsafe(method(locationManagerDidChangeAuthorization:))]
            fn did_change(&self, manager: &AnyObject) {
                // SAFETY: CLLocationManager's status (macOS 11).
                let status: i32 = unsafe { msg_send![manager, authorizationStatus] };
                // Not determined yet: the prompt is still up.
                if status == 0 {
                    return;
                }
                for (id, sender) in self.ivars().permissions.take() {
                    let _ = sender.send(LocationReport {
                        id,
                        ok: true,
                        error: None,
                        services_enabled: None,
                        permission: Some(permission_of(status)),
                        latitude: None,
                        longitude: None,
                    });
                }
            }
        }
    );

    fn failed(id: i64, error: &str) -> LocationReport {
        LocationReport {
            id,
            ok: false,
            error: Some(error.to_string()),
            services_enabled: None,
            permission: None,
            latitude: None,
            longitude: None,
        }
    }

    struct Manager {
        manager: Retained<AnyObject>,
        delegate: Retained<Delegate>,
    }

    thread_local! {
        static MANAGER: RefCell<Option<Manager>> = const { RefCell::new(None) };
    }

    /// The one manager, made the first time a command needs it (main
    /// thread).
    fn with_manager<R>(f: impl FnOnce(&Manager) -> R) -> Option<R> {
        MANAGER.with(|slot| {
            let mut slot = slot.borrow_mut();
            if slot.is_none() {
                let class = AnyClass::get(c"CLLocationManager")?;
                // SAFETY: CLLocationManager's designated initializer.
                let manager: Retained<AnyObject> = unsafe { msg_send![class, new] };
                let delegate: Retained<Delegate> = {
                    let this = Delegate::alloc().set_ivars(DelegateIvars::default());
                    // SAFETY: NSObject's designated initializer.
                    unsafe { msg_send![super(this), init] }
                };
                // SAFETY: the manager keeps a weak reference; `Manager`
                // holds the delegate for as long as the manager lives.
                unsafe {
                    let _: () = msg_send![&*manager, setDelegate: &*delegate];
                    // Kilometre accuracy: Open WebUI writes three decimals.
                    let _: () = msg_send![&*manager, setDesiredAccuracy: 1000.0_f64];
                }
                *slot = Some(Manager { manager, delegate });
            }
            slot.as_ref().map(f)
        })
    }

    pub fn answer(command: &LocationCommand, sender: oneshot::Sender<LocationReport>) {
        let id = command.id;
        let Some(class) = AnyClass::get(c"CLLocationManager") else {
            let _ = sender.send(failed(id, "CoreLocation is not available"));
            return;
        };
        match command.kind {
            LocationCommandKind::Status => {
                // SAFETY: class method; asks the user nothing.
                let enabled: Bool = unsafe { msg_send![class, locationServicesEnabled] };
                let status = with_manager(|m| {
                    // SAFETY: CLLocationManager's status (macOS 11); asks
                    // nothing.
                    let status: i32 = unsafe { msg_send![&*m.manager, authorizationStatus] };
                    status
                });
                let _ = sender.send(LocationReport {
                    id,
                    ok: true,
                    error: None,
                    services_enabled: Some(enabled.as_bool()),
                    permission: Some(permission_of(status.unwrap_or(0))),
                    latitude: None,
                    longitude: None,
                });
            }
            LocationCommandKind::RequestPermission => {
                // SAFETY: as above; asks nothing.
                let status = with_manager(|m| {
                    let status: i32 = unsafe { msg_send![&*m.manager, authorizationStatus] };
                    status
                });
                match status {
                    None => {
                        let _ = sender.send(failed(id, "no CLLocationManager"));
                    }
                    // Already decided: no prompt.
                    Some(status) if status != 0 => {
                        let _ = sender.send(LocationReport {
                            id,
                            ok: true,
                            error: None,
                            services_enabled: None,
                            permission: Some(permission_of(status)),
                            latitude: None,
                            longitude: None,
                        });
                    }
                    Some(_) => {
                        let _ = with_manager(move |m| {
                            m.delegate
                                .ivars()
                                .permissions
                                .borrow_mut()
                                .push((id, sender));
                            // SAFETY: shows the system's prompt; the
                            // delegate hears the answer.
                            unsafe {
                                let _: () = msg_send![&*m.manager, requestWhenInUseAuthorization];
                            }
                        });
                    }
                }
            }
            LocationCommandKind::CurrentPosition => {
                let started = with_manager(|m| {
                    m.delegate.ivars().fixes.borrow_mut().push((id, sender));
                    // SAFETY: one fix; the delegate hears it or the error.
                    unsafe {
                        let _: () = msg_send![&*m.manager, requestLocation];
                    }
                });
                if started.is_none() {
                    log::warn!("location: no CLLocationManager");
                }
            }
            LocationCommandKind::Unknown => {
                let _ = sender.send(failed(id, "unknown command"));
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn command(kind: LocationCommandKind) -> LocationCommand {
        LocationCommand { id: 7, kind }
    }

    #[test]
    fn a_stand_in_position_reads_as_services_on() {
        let fix = Some((51.50142, -0.14189));
        let status = stand_in_report(&command(LocationCommandKind::Status), fix);
        assert_eq!(status.services_enabled, Some(true));
        assert_eq!(status.permission, Some(LocationPermission::WhileInUse));
        let position = stand_in_report(&command(LocationCommandKind::CurrentPosition), fix);
        assert!(position.ok);
        assert_eq!(
            (position.latitude, position.longitude),
            (Some(51.50142), Some(-0.14189))
        );
        assert_eq!(position.id, 7);
    }

    #[test]
    fn no_stand_in_position_reads_as_services_off() {
        let status = stand_in_report(&command(LocationCommandKind::Status), None);
        assert_eq!(status.services_enabled, Some(false));
        assert_eq!(status.permission, Some(LocationPermission::Denied));
        let asked = stand_in_report(&command(LocationCommandKind::RequestPermission), None);
        assert_eq!(asked.permission, Some(LocationPermission::Denied));
        let position = stand_in_report(&command(LocationCommandKind::CurrentPosition), None);
        assert!(!position.ok);
    }

    #[test]
    fn reads_a_stand_in_position() {
        assert_eq!(parse_fix("51.5014, -0.1419"), Some((51.5014, -0.1419)));
        assert_eq!(parse_fix("91,0"), None);
        assert_eq!(parse_fix("off"), None);
    }

    #[test]
    fn maps_core_location_status_as_the_phone_plugin_does() {
        assert_eq!(permission_of(0), LocationPermission::Denied);
        assert_eq!(permission_of(1), LocationPermission::DeniedForever);
        assert_eq!(permission_of(2), LocationPermission::DeniedForever);
        assert_eq!(permission_of(3), LocationPermission::Always);
        assert_eq!(permission_of(4), LocationPermission::WhileInUse);
    }

    /// The messages the CoreLocation engine sends, with the types it reads
    /// them as (objc2 checks them in debug builds): read from the classes,
    /// never called.
    #[cfg(target_os = "macos")]
    #[test]
    fn core_location_methods_have_the_types_the_engine_reads() {
        use objc2::runtime::AnyClass;
        use objc2::sel;
        #[link(name = "CoreLocation", kind = "framework")]
        unsafe extern "C" {}
        let returns = |class: &std::ffi::CStr, sel: objc2::runtime::Sel| {
            AnyClass::get(class)
                .and_then(|c| c.instance_method(sel))
                .map(|m| m.return_type().to_string_lossy().into_owned())
        };
        assert_eq!(
            returns(c"CLLocationManager", sel!(authorizationStatus)).as_deref(),
            Some("i")
        );
        assert_eq!(
            returns(c"CLLocation", sel!(coordinate)).as_deref(),
            Some("{CLLocationCoordinate2D=dd}")
        );
        let enabled = AnyClass::get(c"CLLocationManager")
            .and_then(|c| c.class_method(sel!(locationServicesEnabled)))
            .map(|m| m.return_type().to_string_lossy().into_owned());
        // BOOL: `B` on arm64 (`c` on Intel).
        assert!(
            matches!(enabled.as_deref(), Some("B") | Some("c")),
            "{enabled:?}"
        );
    }

    #[test]
    fn a_scripted_run_never_reaches_core_location() {
        choose(true, None);
        assert_eq!(mode(), Mode::StandIn(None));
        choose(false, Some("51.5,-0.14".into()));
        assert_eq!(mode(), Mode::StandIn(Some((51.5, -0.14))));
        choose(false, Some("off".into()));
        assert_eq!(mode(), Mode::StandIn(None));
        choose(false, None);
        assert_eq!(mode(), Mode::System);
    }
}
