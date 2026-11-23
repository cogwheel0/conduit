//! Whether the computer has a network, on Windows and Linux, for the
//! app's `system.network` report (NWPathMonitor does it on the Mac).
//!
//! * Windows: `NetworkInformation.NetworkStatusChanged`. Online while any
//!   connection reaches at least its local network: a server on the LAN
//!   with no internet beyond it counts, as NWPathMonitor's satisfied path
//!   does.
//! * Linux: the desktop portal's NetworkMonitor (in a Flatpak too), whose
//!   `available` is the same test: a default route. With no portal the
//!   computer reads as online, so a missing portal never stops the app; a
//!   subscription that ends is made again.
//!
//! Both subscribe before they read the first state, so a change between the
//! two is never missed.

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

/// Calls its callback with `online` once at start and on every change,
/// until it drops.
pub struct NetworkMonitor {
    stop: Arc<Stop>,
    #[cfg(windows)]
    token: i64,
}

/// A monitor's stop: set when it drops, waking what waits on it (the Linux
/// worker's wait on the portal, or before asking it again).
#[derive(Default)]
struct Stop {
    stopped: AtomicBool,
    waker: std::sync::Mutex<Option<std::task::Waker>>,
}

impl Stop {
    fn stop(&self) {
        self.stopped.store(true, Ordering::SeqCst);
        let waker = self.waker.lock().unwrap_or_else(|e| e.into_inner()).take();
        if let Some(waker) = waker {
            waker.wake();
        }
    }

    fn is_stopped(&self) -> bool {
        self.stopped.load(Ordering::SeqCst)
    }

    /// Ends once the monitor stops.
    #[cfg_attr(not(target_os = "linux"), cfg(test))]
    fn stopped(&self) -> impl std::future::Future<Output = ()> + '_ {
        std::future::poll_fn(|cx| {
            if self.is_stopped() {
                return std::task::Poll::Ready(());
            }
            *self.waker.lock().unwrap_or_else(|e| e.into_inner()) = Some(cx.waker().clone());
            // Stopped between the look and the waker going in: its wake
            // found no waker, so look again.
            if self.is_stopped() {
                std::task::Poll::Ready(())
            } else {
                std::task::Poll::Pending
            }
        })
    }
}

impl NetworkMonitor {
    /// Starts watching; `on_change` runs on a thread of the system's.
    pub fn start(on_change: impl Fn(bool) + Send + Sync + 'static) -> Option<Self> {
        let stop = Arc::new(Stop::default());
        let report = {
            let stop = stop.clone();
            move |online: bool| {
                if !stop.is_stopped() {
                    on_change(online);
                }
            }
        };
        #[cfg(windows)]
        {
            windows_monitor::start(report).map(|token| Self { stop, token })
        }
        #[cfg(target_os = "linux")]
        {
            linux_monitor::start(report, stop.clone()).then_some(Self { stop })
        }
        #[cfg(not(any(windows, target_os = "linux")))]
        {
            let _ = report;
            None
        }
    }
}

/// Takes a sample and sends it holding `turn`, which every sample of one
/// monitor takes: no other sample-and-send comes between the two, so the
/// last sample taken is the last one sent, whichever thread takes it (the
/// system's handler, or the start's first look).
#[cfg_attr(not(windows), cfg(test))]
fn sample_and_send(
    turn: &std::sync::Mutex<()>,
    sample: impl FnOnce() -> bool,
    send: impl FnOnce(bool),
) {
    let _turn = turn.lock().unwrap_or_else(|e| e.into_inner());
    send(sample());
}

/// Reports each availability reading: the first, then one per change,
/// until the changes end. A reading that fails ends it with that error, so
/// the worker falls back (online) and asks again after its wait, rather than
/// report a guess and never read again while no change comes.
#[cfg_attr(not(target_os = "linux"), cfg(test))]
async fn follow_readings<E>(
    mut changed: impl AsyncFnMut() -> bool,
    mut available: impl AsyncFnMut() -> Result<bool, E>,
    report: &impl Fn(bool),
) -> Result<(), E> {
    report(available().await?);
    while changed().await {
        report(available().await?);
    }
    Ok(())
}

/// The end of one portal subscription: one that failed reports online, the
/// fallback, every time, since the last reading it gave may have been
/// offline. `told` only keeps a run of failures to one log line; a reading
/// ([`follow_readings`]) or a subscription that ended well resets it.
#[cfg_attr(not(target_os = "linux"), cfg(test))]
fn subscription_ended<E: std::fmt::Display>(
    ended: Result<(), E>,
    report: &impl Fn(bool),
    told: &std::cell::Cell<bool>,
) {
    match ended {
        Ok(()) => told.set(false),
        Err(e) => {
            if !told.replace(true) {
                log::info!("network portal: {e}; reading as online until it answers");
            }
            report(true);
        }
    }
}

impl Drop for NetworkMonitor {
    fn drop(&mut self) {
        self.stop.stop();
        #[cfg(windows)]
        windows_monitor::stop(self.token);
    }
}

#[cfg(windows)]
mod windows_monitor {
    use windows::Networking::Connectivity::{
        NetworkConnectivityLevel, NetworkInformation, NetworkStatusChangedEventHandler,
    };

    /// Any connection that reaches at least its local network.
    fn online() -> bool {
        let Ok(profiles) = NetworkInformation::GetConnectionProfiles() else {
            return true;
        };
        let count = profiles.Size().unwrap_or(0);
        (0..count).any(|i| {
            profiles
                .GetAt(i)
                .and_then(|p| p.GetNetworkConnectivityLevel())
                .is_ok_and(|level| level != NetworkConnectivityLevel::None)
        })
    }

    pub fn start(report: impl Fn(bool) + Send + Sync + 'static) -> Option<i64> {
        let report = std::sync::Arc::new(report);
        let turn = std::sync::Arc::new(std::sync::Mutex::new(()));
        let handler = {
            let (report, turn) = (report.clone(), turn.clone());
            NetworkStatusChangedEventHandler::new(move |_| {
                super::sample_and_send(&turn, online, &*report);
                Ok(())
            })
        };
        let token = NetworkInformation::NetworkStatusChanged(&handler)
            .inspect_err(|e| log::warn!("network status: {e}"))
            .ok()?;
        super::sample_and_send(&turn, online, &*report);
        Some(token)
    }

    pub fn stop(token: i64) {
        let _ = NetworkInformation::RemoveNetworkStatusChanged(token);
    }
}

#[cfg(target_os = "linux")]
mod linux_monitor {
    use std::sync::Arc;
    use std::time::Duration;

    use ashpd::desktop::network_monitor::NetworkMonitor;
    use futures_lite::StreamExt as _;
    use futures_lite::future::{block_on, or};

    use super::Stop;

    /// The longest wait before the portal is asked again.
    const MAX_BACKOFF: Duration = Duration::from_secs(60);

    /// Follows the portal on a thread of its own until `stop`, which wakes
    /// it from either wait. Whenever its subscription ends (the portal
    /// restarted, or was never there) it is asked again, after a wait that
    /// doubles up to a minute and starts over once a subscription holds.
    pub fn start(report: impl Fn(bool) + Send + Sync + 'static, stop: Arc<Stop>) -> bool {
        std::thread::Builder::new()
            .name("conduit-network".into())
            .spawn(move || {
                let mut backoff = Duration::from_secs(1);
                let told = std::cell::Cell::new(false);
                let reading = |online: bool| {
                    told.set(false);
                    report(online);
                };
                while !stop.is_stopped() {
                    let followed = block_on(or(async { Some(follow(&reading).await) }, async {
                        stop.stopped().await;
                        None
                    }));
                    let Some(ended) = followed else {
                        break;
                    };
                    if ended.is_ok() {
                        backoff = Duration::from_secs(1);
                    }
                    // With no portal the computer reads as online, so a
                    // missing portal never stops the app.
                    super::subscription_ended(ended, &report, &told);
                    block_on(or(stop.stopped(), async {
                        async_io::Timer::after(backoff).await;
                    }));
                    backoff = (backoff * 2).min(MAX_BACKOFF);
                }
            })
            .inspect_err(|e| log::warn!("network monitor: {e}"))
            .is_ok()
    }

    /// One subscription: made before the first read, so a change between
    /// the two is never missed. Ends when the portal's stream does.
    async fn follow(report: &impl Fn(bool)) -> Result<(), ashpd::Error> {
        let monitor = NetworkMonitor::new().await?;
        let mut changes = monitor.receive_changed().await?;
        super::follow_readings(
            async || changes.next().await.is_some(),
            async || monitor.is_available().await,
            report,
        )
        .await?;
        log::info!("network portal: its subscription ended; asking again");
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A failed availability reading ends the subscription with its error,
    /// so the worker's fallback and wait run and it asks again, rather than
    /// report a guess and never read again while no change comes.
    #[tokio::test]
    async fn a_failed_availability_reading_is_asked_again() {
        let readings = std::cell::RefCell::new(vec![Err("the portal went"), Ok(false)]);
        let changes = std::cell::Cell::new(2u32);
        let reported = std::cell::RefCell::new(Vec::new());
        let ended = follow_readings(
            async || {
                let left = changes.get();
                changes.set(left.saturating_sub(1));
                left > 0
            },
            async || readings.borrow_mut().pop().unwrap_or(Ok(true)),
            &|online| reported.borrow_mut().push(online),
        )
        .await;
        assert_eq!(ended, Err("the portal went"));
        assert_eq!(*reported.borrow(), [false], "nothing reported for it");
    }

    /// A subscription fails (online), the next reads offline and then fails
    /// a reading: the fallback reports online again, whatever was said
    /// before, so the app never stays offline with the network back.
    #[tokio::test]
    async fn every_failed_subscription_falls_back_to_online() {
        let told = std::cell::Cell::new(false);
        let reported = std::cell::RefCell::new(Vec::new());
        let report = |online: bool| reported.borrow_mut().push(online);
        let failed = follow_readings(
            async || false,
            async || Err::<bool, _>("no portal"),
            &report,
        )
        .await;
        subscription_ended(failed, &report, &told);
        let mut readings = vec![Err("the portal went"), Ok(false)];
        let failed =
            follow_readings(async || true, async || readings.pop().unwrap(), &report).await;
        subscription_ended(failed, &report, &told);
        assert_eq!(*reported.borrow(), [true, false, true]);
    }

    /// Dropping the monitor wakes its worker's wait (on the portal, or
    /// before asking it again), which then ends; a wait that starts once it
    /// stopped ends at once.
    #[test]
    fn stopping_the_monitor_wakes_its_wait() {
        use std::future::Future as _;
        struct Woken(std::sync::atomic::AtomicUsize);
        impl std::task::Wake for Woken {
            fn wake(self: Arc<Self>) {
                self.0.fetch_add(1, Ordering::SeqCst);
            }
        }
        let woken = Arc::new(Woken(Default::default()));
        let waker = std::task::Waker::from(woken.clone());
        let mut cx = std::task::Context::from_waker(&waker);
        let stop = Stop::default();
        let mut wait = std::pin::pin!(stop.stopped());
        assert!(wait.as_mut().poll(&mut cx).is_pending());
        stop.stop();
        assert_eq!(woken.0.load(Ordering::SeqCst), 1, "the wait is woken");
        assert!(wait.as_mut().poll(&mut cx).is_ready());
        assert!(std::pin::pin!(stop.stopped()).poll(&mut cx).is_ready());
    }

    /// A sample is taken and sent in one turn: the turn is held while it
    /// is sampled and while it is sent, so the handler's newer "online"
    /// can't land before the start's older "offline", and then be undone
    /// by it.
    #[test]
    fn the_last_sample_taken_is_the_last_one_sent() {
        let turn = std::sync::Mutex::new(());
        let held = || matches!(turn.try_lock(), Err(std::sync::TryLockError::WouldBlock));
        let sent = std::cell::Cell::new(None);
        sample_and_send(
            &turn,
            || {
                assert!(held(), "sampled outside the turn");
                false
            },
            |online| {
                assert!(held(), "sent outside the turn");
                sent.set(Some(online));
            },
        );
        assert_eq!(sent.get(), Some(false));
        assert!(!held(), "the turn ends with the send");
    }
}
