//! Answer notifications through `UNUserNotificationCenter` (objc2).
//!
//! Nothing here touches the notification center until [`Notifier::new`]:
//! outside an app bundle the framework aborts the process
//! ("bundleProxyForCurrentProcess is nil"), so a bare binary (tests,
//! `cargo run`) gets no notifier. The app asks for permission the first time
//! the setting is turned on or the first notification would go out, never
//! at launch.
//!
//! Completion handlers run on the framework's queues; results come back
//! through oneshot channels, clicks through the channel given to
//! [`Notifier::new`] (the request identifier, see [`super::notify`]).

use std::sync::Mutex;

use block2::RcBlock;
use futures::channel::{mpsc, oneshot};
use objc2::rc::Retained;
use objc2::runtime::{Bool, ProtocolObject};
use objc2::{AnyThread, DefinedClass, define_class, msg_send};
use objc2_foundation::{NSArray, NSBundle, NSError, NSObject, NSObjectProtocol, NSString};
use objc2_user_notifications::{
    UNAuthorizationOptions, UNAuthorizationStatus, UNMutableNotificationContent, UNNotification,
    UNNotificationDefaultActionIdentifier, UNNotificationPresentationOptions,
    UNNotificationRequest, UNNotificationResponse, UNNotificationSettings, UNNotificationSound,
    UNUserNotificationCenter, UNUserNotificationCenterDelegate,
};

use super::notify::Notification;

/// Whether the app may notify, as the system says.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Authorization {
    /// Not asked yet.
    NotDetermined,
    Denied,
    Authorized,
    /// Delivered quietly to Notification Center (no banner).
    Provisional,
}

impl Authorization {
    fn from_status(status: UNAuthorizationStatus) -> Self {
        match status {
            UNAuthorizationStatus::Authorized | UNAuthorizationStatus::Ephemeral => {
                Self::Authorized
            }
            UNAuthorizationStatus::Provisional => Self::Provisional,
            UNAuthorizationStatus::Denied => Self::Denied,
            _ => Self::NotDetermined,
        }
    }

    /// Whether a notification would be delivered.
    pub fn allows(self) -> bool {
        matches!(self, Self::Authorized | Self::Provisional)
    }
}

/// A delivered notification, as `getDeliveredNotifications` lists it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Delivered {
    pub id: String,
    pub title: String,
    pub body: String,
}

/// A one-shot completion that a block (`Fn`) can call from any thread.
fn once<T: Send + 'static>() -> (impl Fn(T) + Send + Sync + 'static, oneshot::Receiver<T>) {
    let (tx, rx) = oneshot::channel();
    let tx = Mutex::new(Some(tx));
    let call = move |value: T| {
        if let Some(tx) = tx.lock().ok().and_then(|mut t| t.take()) {
            let _ = tx.send(value);
        }
    };
    (call, rx)
}

fn error_text(error: *mut NSError) -> Option<String> {
    // SAFETY: when non-null, `error` is a valid NSError for the duration of
    // the completion handler.
    unsafe { error.as_ref() }.map(|e| e.localizedDescription().to_string())
}

pub struct Notifier {
    center: Retained<UNUserNotificationCenter>,
    /// The center keeps its delegate weakly.
    _delegate: Retained<Delegate>,
}

impl Notifier {
    /// The notifier, with `clicks` receiving the identifier of each
    /// notification the user clicks. `None` outside an app bundle.
    pub fn new(clicks: mpsc::UnboundedSender<String>) -> Option<Self> {
        let bundle = NSBundle::mainBundle();
        let in_app = bundle.bundleIdentifier().is_some()
            && bundle.bundlePath().to_string().ends_with(".app");
        if !in_app {
            log::info!("notifications: not running from an app bundle");
            return None;
        }
        let center = UNUserNotificationCenter::currentNotificationCenter();
        let delegate = Delegate::new(clicks);
        center.setDelegate(Some(ProtocolObject::from_ref(&*delegate)));
        Some(Self {
            center,
            _delegate: delegate,
        })
    }

    /// The current authorization.
    pub fn authorization(&self) -> oneshot::Receiver<Authorization> {
        let (done, rx) = once();
        let block = RcBlock::new(move |settings: std::ptr::NonNull<UNNotificationSettings>| {
            // SAFETY: the framework passes a valid settings object.
            let status = unsafe { settings.as_ref() }.authorizationStatus();
            done(Authorization::from_status(status));
        });
        self.center
            .getNotificationSettingsWithCompletionHandler(&block);
        rx
    }

    /// Asks for permission (alerts and sounds). With `provisional`, asks for
    /// quiet delivery instead, which needs no prompt.
    pub fn request(&self, provisional: bool) -> oneshot::Receiver<Result<bool, String>> {
        let (done, rx) = once();
        // A scripted run never raises the prompt (see `crate::scripted`);
        // quiet delivery raises none, so it is still asked for.
        if !provisional && crate::scripted::active() {
            log::info!("notifications not asked for: a scripted run");
            done(Ok(false));
            return rx;
        }
        let block = RcBlock::new(move |granted: Bool, error: *mut NSError| {
            done(match error_text(error) {
                Some(e) => Err(e),
                None => Ok(granted.as_bool()),
            });
        });
        let options = if provisional {
            UNAuthorizationOptions::Alert
                | UNAuthorizationOptions::Sound
                | UNAuthorizationOptions::Provisional
        } else {
            UNAuthorizationOptions::Alert | UNAuthorizationOptions::Sound
        };
        self.center
            .requestAuthorizationWithOptions_completionHandler(options, &block);
        rx
    }

    /// Delivers `n` now. A newer one with the same id replaces the older.
    pub fn post(&self, n: &Notification) -> oneshot::Receiver<Result<(), String>> {
        let content = UNMutableNotificationContent::new();
        content.setTitle(&NSString::from_str(&n.title));
        content.setBody(&NSString::from_str(&n.body));
        content.setThreadIdentifier(&NSString::from_str(&n.id));
        if n.sound {
            content.setSound(Some(&UNNotificationSound::defaultSound()));
        }
        let request = UNNotificationRequest::requestWithIdentifier_content_trigger(
            &NSString::from_str(&n.id),
            &content,
            None,
        );
        let (done, rx) = once();
        let block = RcBlock::new(move |error: *mut NSError| {
            done(match error_text(error) {
                Some(e) => Err(e),
                None => Ok(()),
            });
        });
        self.center
            .addNotificationRequest_withCompletionHandler(&request, Some(&block));
        rx
    }

    /// The app's notifications still in Notification Center.
    pub fn delivered(&self) -> oneshot::Receiver<Vec<Delivered>> {
        let (done, rx) = once();
        let block = RcBlock::new(move |list: std::ptr::NonNull<NSArray<UNNotification>>| {
            // SAFETY: the framework passes a valid array.
            let list = unsafe { list.as_ref() };
            let out = list
                .iter()
                .map(|n| {
                    let request = n.request();
                    let content = request.content();
                    Delivered {
                        id: request.identifier().to_string(),
                        title: content.title().to_string(),
                        body: content.body().to_string(),
                    }
                })
                .collect();
            done(out);
        });
        self.center
            .getDeliveredNotificationsWithCompletionHandler(&block);
        rx
    }

    /// Takes a chat's notification out of Notification Center (it was
    /// opened, so it has done its job).
    pub fn remove(&self, id: &str) {
        let ids = NSArray::from_retained_slice(&[NSString::from_str(id)]);
        self.center
            .removeDeliveredNotificationsWithIdentifiers(&ids);
    }

    /// Takes every one of the app's notifications out of Notification
    /// Center (the E2E run's cleanup).
    pub fn remove_all(&self) {
        self.center.removeAllDeliveredNotifications();
    }

    /// Hands a click to the app as the delegate would (E2E: a click can't be
    /// made programmatically).
    pub fn simulate_click(&self, id: &str) {
        self._delegate.clicked(id.to_string());
    }
}

struct DelegateIvars {
    clicks: mpsc::UnboundedSender<String>,
}

define_class!(
    // SAFETY: NSObject has no subclassing requirements and `Delegate` does
    // not implement Drop.
    #[unsafe(super(NSObject))]
    #[ivars = DelegateIvars]
    struct Delegate;

    unsafe impl NSObjectProtocol for Delegate {}

    unsafe impl UNUserNotificationCenterDelegate for Delegate {
        // A click on the notification (or its default action). Possibly on
        // a background queue; the channel hops to the main thread.
        #[unsafe(method(userNotificationCenter:didReceiveNotificationResponse:withCompletionHandler:))]
        fn did_receive(
            &self,
            _center: &UNUserNotificationCenter,
            response: &UNNotificationResponse,
            completion_handler: &block2::DynBlock<dyn Fn()>,
        ) {
            // SAFETY: an AppKit constant.
            let default = unsafe { UNNotificationDefaultActionIdentifier };
            if &*response.actionIdentifier() == default {
                let id = response.notification().request().identifier().to_string();
                self.clicked(id);
            }
            completion_handler.call(());
        }

        // Without this the system drops banners while the app is frontmost;
        // whether to notify is the app's decision (see `notify::decide`).
        #[unsafe(method(userNotificationCenter:willPresentNotification:withCompletionHandler:))]
        fn will_present(
            &self,
            _center: &UNUserNotificationCenter,
            _notification: &UNNotification,
            completion_handler: &block2::DynBlock<dyn Fn(UNNotificationPresentationOptions)>,
        ) {
            completion_handler.call((UNNotificationPresentationOptions::Banner
                | UNNotificationPresentationOptions::List
                | UNNotificationPresentationOptions::Sound,));
        }
    }
);

impl Delegate {
    fn new(clicks: mpsc::UnboundedSender<String>) -> Retained<Self> {
        let this = Self::alloc().set_ivars(DelegateIvars { clicks });
        // SAFETY: NSObject's designated initializer.
        unsafe { msg_send![super(this), init] }
    }

    fn clicked(&self, id: String) {
        let _ = self.ivars().clicks.unbounded_send(id);
    }
}
