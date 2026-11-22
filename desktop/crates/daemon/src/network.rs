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
    stopped: Arc<AtomicBool>,
    #[cfg(windows)]
    token: i64,
}

impl NetworkMonitor {
    /// Starts watching; `on_change` runs on a thread of the system's.
    pub fn start(on_change: impl Fn(bool) + Send + Sync + 'static) -> Option<Self> {
        let stopped = Arc::new(AtomicBool::new(false));
        let report = {
            let stopped = stopped.clone();
            move |online: bool| {
                if !stopped.load(Ordering::SeqCst) {
                    on_change(online);
                }
            }
        };
        #[cfg(windows)]
        {
            windows_monitor::start(report).map(|token| Self { stopped, token })
        }
        #[cfg(target_os = "linux")]
        {
            linux_monitor::start(report, stopped.clone()).then_some(Self { stopped })
        }
        #[cfg(not(any(windows, target_os = "linux")))]
        {
            let _ = report;
            None
        }
    }
}

/// Takes a sample and sends it as one step, so the last sample taken is the
/// last one sent, whichever thread takes it (the system's handler, or the
/// start's first look).
#[cfg_attr(not(windows), cfg(test))]
struct Reporter<R> {
    send: R,
    turn: std::sync::Mutex<()>,
}

#[cfg_attr(not(windows), cfg(test))]
impl<R: Fn(bool)> Reporter<R> {
    fn new(send: R) -> Self {
        Self {
            send,
            turn: std::sync::Mutex::new(()),
        }
    }

    fn sample_and_send(&self, sample: impl FnOnce() -> bool) {
        let _turn = self.turn.lock().unwrap_or_else(|e| e.into_inner());
        (self.send)(sample());
    }
}

impl Drop for NetworkMonitor {
    fn drop(&mut self) {
        self.stopped.store(true, Ordering::SeqCst);
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
        let reporter = std::sync::Arc::new(super::Reporter::new(report));
        let handler = {
            let reporter = reporter.clone();
            NetworkStatusChangedEventHandler::new(move |_| {
                reporter.sample_and_send(online);
                Ok(())
            })
        };
        let token = NetworkInformation::NetworkStatusChanged(&handler)
            .inspect_err(|e| log::warn!("network status: {e}"))
            .ok()?;
        reporter.sample_and_send(online);
        Some(token)
    }

    pub fn stop(token: i64) {
        let _ = NetworkInformation::RemoveNetworkStatusChanged(token);
    }
}

#[cfg(target_os = "linux")]
mod linux_monitor {
    use std::sync::Arc;
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::time::Duration;

    use ashpd::desktop::network_monitor::NetworkMonitor;
    use futures_lite::StreamExt as _;

    /// The longest wait before the portal is asked again.
    const MAX_BACKOFF: Duration = Duration::from_secs(60);

    /// Follows the portal on a thread of its own until `stopped`. Whenever
    /// its subscription ends (the portal restarted, or was never there) it
    /// is asked again, after a wait that doubles up to a minute and starts
    /// over once a subscription holds.
    pub fn start(report: impl Fn(bool) + Send + Sync + 'static, stopped: Arc<AtomicBool>) -> bool {
        std::thread::Builder::new()
            .name("conduit-network".into())
            .spawn(move || {
                let mut backoff = Duration::from_secs(1);
                let mut said_online = false;
                while !stopped.load(Ordering::SeqCst) {
                    match futures_lite::future::block_on(follow(&report)) {
                        Ok(()) => {
                            backoff = Duration::from_secs(1);
                            said_online = false;
                        }
                        Err(e) => {
                            // With no portal the computer reads as online,
                            // so a missing portal never stops the app (nor
                            // leaves the last state it gave standing).
                            if !said_online {
                                log::info!("no network portal ({e}): reading as online");
                                report(true);
                                said_online = true;
                            }
                        }
                    }
                    std::thread::sleep(backoff);
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
        report(monitor.is_available().await.unwrap_or(true));
        while changes.next().await.is_some() {
            report(monitor.is_available().await.unwrap_or(true));
        }
        log::info!("network portal: its subscription ended; asking again");
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The start samples "offline", and the network comes back before it
    /// sends that: the handler's "online" waits its turn, so it is the last
    /// word, not the stale "offline".
    #[test]
    fn the_last_sample_taken_is_the_last_one_sent() {
        let sent = Arc::new(std::sync::Mutex::new(Vec::new()));
        let reporter = Arc::new(Reporter::new({
            let sent = sent.clone();
            move |online| sent.lock().unwrap().push(online)
        }));
        let (sampled, handler_may_go) = std::sync::mpsc::channel();
        let handler = {
            let reporter = reporter.clone();
            std::thread::spawn(move || {
                handler_may_go.recv().unwrap();
                reporter.sample_and_send(|| true);
            })
        };
        reporter.sample_and_send(|| {
            sampled.send(()).unwrap();
            // Room for the handler to cut in between this sample and its
            // send, as the system's thread can.
            std::thread::sleep(std::time::Duration::from_millis(50));
            false
        });
        handler.join().unwrap();
        assert_eq!(*sent.lock().unwrap(), [false, true]);
    }
}
