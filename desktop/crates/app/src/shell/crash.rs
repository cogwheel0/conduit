//! A panic hook that writes a crash file next to the logs
//! (`~/Library/Logs/Conduit[ Dev]/crash-<UTC time>.txt`) before the default
//! hook runs. "Export diagnostics" zips the daemon's logs; the crash files
//! sit beside the app log for support to ask for.

use std::path::{Path, PathBuf};
use std::time::SystemTime;

use conduit_daemon::paths::format_utc;

/// Installs the hook. `version` goes into every report.
pub fn install(logs: PathBuf, version: &'static str) {
    let previous = std::panic::take_hook();
    std::panic::set_hook(Box::new(move |info| {
        let message = info
            .payload()
            .downcast_ref::<&str>()
            .map(|s| s.to_string())
            .or_else(|| info.payload().downcast_ref::<String>().cloned())
            .unwrap_or_else(|| "panic".into());
        let location = info
            .location()
            .map(|l| format!("{}:{}:{}", l.file(), l.line(), l.column()))
            .unwrap_or_default();
        let backtrace = std::backtrace::Backtrace::force_capture().to_string();
        if let Ok(path) = write_report(
            &logs,
            version,
            &message,
            &location,
            &backtrace,
            SystemTime::now(),
        ) {
            eprintln!("crash report: {}", path.display());
        }
        previous(info);
    }));
}

/// Writes one report; answers its path.
pub fn write_report(
    dir: &Path,
    version: &str,
    message: &str,
    location: &str,
    backtrace: &str,
    now: SystemTime,
) -> std::io::Result<PathBuf> {
    std::fs::create_dir_all(dir)?;
    let secs = now
        .duration_since(SystemTime::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or_default();
    let stamp = format_utc(secs);
    let mut path = dir.join(format!("crash-{stamp}.txt"));
    let mut n = 2;
    while path.exists() {
        path = dir.join(format!("crash-{stamp}-{n}.txt"));
        n += 1;
    }
    let thread = std::thread::current();
    let report = format!(
        "Conduit Desktop {version} crashed at {stamp} UTC\n\
         thread: {}\n\
         message: {message}\n\
         location: {location}\n\
         os: {} {}\n\n\
         {backtrace}\n",
        thread.name().unwrap_or("unnamed"),
        std::env::consts::OS,
        std::env::consts::ARCH,
    );
    std::fs::write(&path, report)?;
    Ok(path)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn writes_a_report_without_clobbering() {
        let dir = std::env::temp_dir().join(format!("conduit-crash-{}", std::process::id()));
        let now = SystemTime::UNIX_EPOCH + std::time::Duration::from_secs(1_794_141_296);
        let a = write_report(&dir, "0.0.0", "boom", "src/x.rs:1:2", "bt", now).unwrap();
        let b = write_report(&dir, "0.0.0", "again", "src/x.rs:1:2", "bt", now).unwrap();
        assert_ne!(a, b);
        let text = std::fs::read_to_string(&a).unwrap();
        assert!(text.contains("message: boom"));
        assert!(text.contains("location: src/x.rs:1:2"));
        assert!(
            a.file_name()
                .unwrap()
                .to_string_lossy()
                .starts_with("crash-2026-11-08")
        );
    }
}
