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
    // The name is taken as the file is made (create_new): two threads that
    // crash in one second never write over each other's report.
    let mut n = 1;
    let (path, mut file) = loop {
        let path = if n == 1 {
            dir.join(format!("crash-{stamp}.txt"))
        } else {
            dir.join(format!("crash-{stamp}-{n}.txt"))
        };
        match std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&path)
        {
            Ok(file) => break (path, file),
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => n += 1,
            Err(e) => return Err(e),
        }
    };
    std::io::Write::write_all(&mut file, report.as_bytes())?;
    prune(dir, KEEP_REPORTS);
    Ok(path)
}

/// How many crash reports are kept, the newest (as the logs rotate).
pub const KEEP_REPORTS: usize = 10;

/// Removes all but the newest `keep` crash reports in `dir`.
fn prune(dir: &Path, keep: usize) {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return;
    };
    let mut reports: Vec<(SystemTime, PathBuf)> = entries
        .flatten()
        .filter(|e| {
            let name = e.file_name();
            let name = name.to_string_lossy();
            name.starts_with("crash-") && name.ends_with(".txt")
        })
        .filter_map(|e| Some((e.metadata().ok()?.modified().ok()?, e.path())))
        .collect();
    reports.sort();
    let extra = reports.len().saturating_sub(keep);
    for (_, path) in reports.into_iter().take(extra) {
        let _ = std::fs::remove_file(path);
    }
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

    #[test]
    fn threads_crashing_together_each_keep_their_report() {
        let dir = std::env::temp_dir().join(format!("conduit-crash-race-{}", std::process::id()));
        let now = SystemTime::UNIX_EPOCH + std::time::Duration::from_secs(1_794_141_296);
        let paths: Vec<PathBuf> = (0..8)
            .map(|i| {
                let dir = dir.clone();
                std::thread::spawn(move || {
                    write_report(&dir, "0.0.0", &format!("thread {i}"), "x", "bt", now).unwrap()
                })
            })
            .collect::<Vec<_>>()
            .into_iter()
            .map(|t| t.join().unwrap())
            .collect();
        let mut messages: Vec<String> = paths
            .iter()
            .map(|p| {
                let text = std::fs::read_to_string(p).unwrap();
                text.lines()
                    .find(|l| l.starts_with("message:"))
                    .unwrap()
                    .to_string()
            })
            .collect();
        messages.sort();
        messages.dedup();
        assert_eq!(messages.len(), 8, "{messages:?}");
    }

    #[test]
    fn only_the_newest_reports_are_kept() {
        let dir = std::env::temp_dir().join(format!("conduit-crash-keep-{}", std::process::id()));
        let now = SystemTime::UNIX_EPOCH + std::time::Duration::from_secs(1_794_141_296);
        for i in 0..(KEEP_REPORTS + 3) {
            write_report(&dir, "0.0.0", &format!("n{i}"), "x", "bt", now).unwrap();
        }
        let left = std::fs::read_dir(&dir).unwrap().count();
        assert_eq!(left, KEEP_REPORTS);
    }
}
