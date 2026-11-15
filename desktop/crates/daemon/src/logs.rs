//! A small rotating log file: `<stem>.log`, rolled to `<stem>.1.log` …
//! `<stem>.<keep>.log` once it passes `max_bytes`. The daemon's stderr and
//! the app's own log both go through it, under `~/Library/Logs/Conduit`
//! (or `Conduit Dev`).

use std::fs::{File, OpenOptions};
use std::io::{self, Write};
use std::path::{Path, PathBuf};

pub struct RotatingLog {
    dir: PathBuf,
    stem: String,
    max_bytes: u64,
    keep: usize,
    file: Option<File>,
    written: u64,
}

impl RotatingLog {
    /// Opens (appending to) `<dir>/<stem>.log`, creating `dir`.
    pub fn open(dir: &Path, stem: &str, max_bytes: u64, keep: usize) -> io::Result<Self> {
        std::fs::create_dir_all(dir)?;
        let mut log = Self {
            dir: dir.to_path_buf(),
            stem: stem.to_string(),
            max_bytes: max_bytes.max(1024),
            keep: keep.max(1),
            file: None,
            written: 0,
        };
        log.reopen()?;
        Ok(log)
    }

    /// 5 MB per file, five old files.
    pub fn standard(dir: &Path, stem: &str) -> io::Result<Self> {
        Self::open(dir, stem, 5 * 1024 * 1024, 5)
    }

    pub fn path(&self) -> PathBuf {
        self.dir.join(format!("{}.log", self.stem))
    }

    fn rolled(&self, n: usize) -> PathBuf {
        self.dir.join(format!("{}.{n}.log", self.stem))
    }

    fn reopen(&mut self) -> io::Result<()> {
        let path = self.path();
        let file = OpenOptions::new().create(true).append(true).open(&path)?;
        self.written = file.metadata().map(|m| m.len()).unwrap_or(0);
        self.file = Some(file);
        Ok(())
    }

    fn rotate(&mut self) -> io::Result<()> {
        self.file = None;
        // An earlier rotation renamed the file but could not reopen it: start
        // a new one instead of shifting the old ones again.
        if !self.path().exists() {
            return self.reopen();
        }
        // Oldest first, so each rename lands on a free (or the oldest) name.
        for n in (1..self.keep).rev() {
            let from = self.rolled(n);
            if from.exists() {
                std::fs::rename(&from, self.rolled(n + 1))?;
            }
        }
        std::fs::rename(self.path(), self.rolled(1))?;
        self.reopen()
    }

    /// Appends one line (a newline is added when missing).
    pub fn write_line(&mut self, line: &[u8]) -> io::Result<()> {
        if self.written >= self.max_bytes {
            self.rotate()?;
        }
        let file = match self.file.as_mut() {
            Some(f) => f,
            None => {
                self.reopen()?;
                self.file
                    .as_mut()
                    .ok_or_else(|| io::Error::other("log not open"))?
            }
        };
        file.write_all(line)?;
        let mut n = line.len() as u64;
        if !line.ends_with(b"\n") {
            file.write_all(b"\n")?;
            n += 1;
        }
        self.written += n;
        Ok(())
    }

    pub fn flush(&mut self) -> io::Result<()> {
        match self.file.as_mut() {
            Some(f) => f.flush(),
            None => Ok(()),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rolls_over_and_keeps_n_files() {
        let dir = std::env::temp_dir().join(format!("conduit-logs-test-{}", std::process::id()));
        let mut log = RotatingLog::open(&dir, "t", 1024, 2).unwrap();
        let line = vec![b'x'; 300];
        for _ in 0..20 {
            log.write_line(&line).unwrap();
        }
        log.flush().unwrap();
        assert!(log.path().exists());
        assert!(dir.join("t.1.log").exists());
        assert!(dir.join("t.2.log").exists());
        assert!(!dir.join("t.3.log").exists());
        assert!(std::fs::metadata(log.path()).unwrap().len() <= 1024 + 301);
    }

    #[test]
    fn a_rotation_that_could_not_reopen_starts_a_new_file() {
        let dir = std::env::temp_dir().join(format!("conduit-logs-reopen-{}", std::process::id()));
        let mut log = RotatingLog::open(&dir, "t", 1024, 2).unwrap();
        for _ in 0..4 {
            log.write_line(&[b'x'; 300]).unwrap();
        }
        // As after a rotation that renamed the file but could not reopen it.
        std::fs::remove_file(log.path()).unwrap();
        log.write_line(b"after").unwrap();
        log.flush().unwrap();
        assert!(
            std::fs::read_to_string(log.path())
                .unwrap()
                .contains("after")
        );
        assert!(!dir.join("t.1.log").exists(), "nothing shifted");
    }
}
