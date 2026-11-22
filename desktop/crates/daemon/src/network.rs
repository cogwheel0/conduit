//! Whether the computer has a network, on Windows and Linux, for the
//! app's `system.network` report (NWPathMonitor does it on the Mac).
//!
//! * Windows: `NetworkInformation.NetworkStatusChanged`. Online while any
//!   connection reaches at least its local network: a server on the LAN
//!   with no internet beyond it counts, as NWPathMonitor's satisfied path
//!   does.
//! * Linux: the desktop portal's NetworkMonitor (in a Flatpak too), whose
//!   `available` is the same test: a default route. With no portal the
//!   computer reads as online, so a missing portal never stops the app.

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
            linux_monitor::start(report).then_some(Self { stopped })
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
    use ashpd::desktop::network_monitor::NetworkMonitor;
    use futures_lite::StreamExt as _;

    /// Follows the portal on a thread of its own, for the process's life.
    pub fn start(report: impl Fn(bool) + Send + Sync + 'static) -> bool {
        std::thread::Builder::new()
            .name("conduit-network".into())
            .spawn(move || futures_lite::future::block_on(follow(report)))
            .inspect_err(|e| log::warn!("network monitor: {e}"))
            .is_ok()
    }

    async fn follow(report: impl Fn(bool)) {
        let monitor = match NetworkMonitor::new().await {
            Ok(monitor) => monitor,
            Err(e) => {
                log::info!("no network portal ({e}): reading as online");
                report(true);
                return;
            }
        };
        report(monitor.is_available().await.unwrap_or(true));
        let Ok(mut changes) = monitor.receive_changed().await else {
            return;
        };
        while changes.next().await.is_some() {
            report(monitor.is_available().await.unwrap_or(true));
        }
    }
}
