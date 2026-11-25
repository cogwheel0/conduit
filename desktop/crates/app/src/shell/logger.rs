//! The app's own log: `conduit-desktop.log` (rotating) beside the daemon's
//! `conduitd.log`, plus stderr in debug builds.

use std::path::Path;
use std::sync::Mutex;

use conduit_daemon::logs::RotatingLog;
use log::{Level, LevelFilter, Log, Metadata, Record};

struct AppLogger {
    file: Mutex<Option<RotatingLog>>,
}

impl Log for AppLogger {
    fn enabled(&self, metadata: &Metadata) -> bool {
        kept(metadata.target(), metadata.level())
    }

    fn log(&self, record: &Record) {
        if !self.enabled(record.metadata()) {
            return;
        }
        let line = format!(
            "{} {:5} {}: {}",
            unix_time(),
            record.level(),
            record.target(),
            record.args()
        );
        if cfg!(debug_assertions) {
            eprintln!("{line}");
        }
        if let Ok(mut guard) = self.file.lock()
            && let Some(file) = guard.as_mut()
        {
            let _ = file.write_line(line.as_bytes());
            let _ = file.flush();
        }
    }

    fn flush(&self) {}
}

/// Whether a record from `target` at `level` goes in the log: Info and up,
/// the app's own Debug too in a debug build. zbus (the accessibility
/// bridge's and the portals' D-Bus) only from Warn: it logs every call at
/// Info, and with a screen reader running those pushed every other line
/// out of the rotated files within minutes.
fn kept(target: &str, level: Level) -> bool {
    let krate = target.split("::").next().unwrap_or(target);
    if krate == "zbus" || krate.starts_with("zbus_") {
        return level <= Level::Warn;
    }
    level <= Level::Info || (cfg!(debug_assertions) && target.starts_with("conduit"))
}

fn unix_time() -> String {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default();
    format!("{} UTC", conduit_daemon::paths::format_utc(now.as_secs()))
}

/// Routes `log` records to `<logs>/conduit-desktop.log`.
pub fn install(logs: &Path) {
    let file = RotatingLog::standard(logs, "conduit-desktop").ok();
    let logger = AppLogger {
        file: Mutex::new(file),
    };
    if log::set_boxed_logger(Box::new(logger)).is_ok() {
        log::set_max_level(if cfg!(debug_assertions) {
            LevelFilter::Debug
        } else {
            LevelFilter::Info
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn zbus_writes_only_its_warnings_and_errors() {
        // With a screen reader running, the accessibility bridge's D-Bus
        // calls come at Info, thousands a minute.
        for target in ["zbus", "zbus::object_server", "zbus::connection::handshake"] {
            assert!(!kept(target, Level::Info), "{target} at Info");
            assert!(kept(target, Level::Warn), "{target} at Warn");
            assert!(kept(target, Level::Error), "{target} at Error");
        }
        assert!(kept("conduit_desktop::stores::connection", Level::Info));
        assert!(kept("gpui::window", Level::Info));
        assert!(!kept("gpui::window", Level::Debug));
    }
}
