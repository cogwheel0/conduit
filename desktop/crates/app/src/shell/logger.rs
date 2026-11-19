//! The app's own log: `conduit-desktop.log` (rotating) beside the daemon's
//! `conduitd.log`, plus stderr in debug builds.

use std::path::Path;
use std::sync::Mutex;

use conduit_daemon::logs::RotatingLog;
use log::{LevelFilter, Log, Metadata, Record};

struct AppLogger {
    file: Mutex<Option<RotatingLog>>,
}

impl Log for AppLogger {
    fn enabled(&self, metadata: &Metadata) -> bool {
        metadata.level() <= log::Level::Info
            || (cfg!(debug_assertions) && metadata.target().starts_with("conduit"))
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
