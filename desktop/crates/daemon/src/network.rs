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
        let report = std::sync::Arc::new(report);
        let handler = {
            let report = report.clone();
            NetworkStatusChangedEventHandler::new(move |_| {
                report(online());
                Ok(())
            })
        };
        let token = NetworkInformation::NetworkStatusChanged(&handler)
            .inspect_err(|e| log::warn!("network status: {e}"))
            .ok()?;
        report(online());
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
