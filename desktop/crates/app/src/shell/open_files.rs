//! "Open with Conduit": files the system hands the app (Finder's Open With,
//! a drop on the Dock icon). They start a new chat with the files attached
//! through the composer's own upload path, never sent.
//!
//! At most [`MAX_FILES`] files of up to [`MAX_BYTES`] each are taken. The
//! rest are refused, and the app says so in a toast.

use std::path::{Path, PathBuf};

pub use crate::stores::composer::MAX_ATTACHMENT_BYTES as MAX_BYTES;

/// The most files one "Open with" attaches.
pub const MAX_FILES: usize = 10;

/// What [`plan`] makes of the paths.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct OpenFilesPlan {
    /// Attached, in the order given.
    pub accepted: Vec<PathBuf>,
    /// Regular files past the first [`MAX_FILES`].
    pub too_many: usize,
    /// Names of files over [`MAX_BYTES`].
    pub too_large: Vec<String>,
    /// Folders and missing paths, for the log.
    pub skipped: Vec<PathBuf>,
}

impl OpenFilesPlan {
    pub fn is_empty(&self) -> bool {
        self.accepted.is_empty()
    }
}

/// What the file system says about a path: `Some(len)` for a regular file.
pub fn file_size(path: &Path) -> Option<u64> {
    std::fs::metadata(path)
        .ok()
        .filter(|m| m.is_file())
        .map(|m| m.len())
}

fn display_name(path: &Path) -> String {
    path.file_name()
        .map(|n| n.to_string_lossy().to_string())
        .unwrap_or_else(|| path.to_string_lossy().to_string())
}

/// Sorts `paths` into what gets attached and what is refused. `size_of`
/// answers [`file_size`] (a fake in tests). Duplicates count once.
pub fn plan(paths: &[PathBuf], size_of: impl Fn(&Path) -> Option<u64>) -> OpenFilesPlan {
    let mut out = OpenFilesPlan::default();
    let mut seen: Vec<&PathBuf> = vec![];
    for path in paths {
        if seen.contains(&path) {
            continue;
        }
        seen.push(path);
        match size_of(path) {
            None => out.skipped.push(path.clone()),
            Some(len) if len > MAX_BYTES => out.too_large.push(display_name(path)),
            Some(_) if out.accepted.len() >= MAX_FILES => out.too_many += 1,
            Some(_) => out.accepted.push(path.clone()),
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fake(path: &Path) -> Option<u64> {
        let name = path.file_name()?.to_str()?;
        if name.starts_with("missing") || name.ends_with('/') || !name.contains('.') {
            return None;
        }
        Some(if name.starts_with("huge") {
            MAX_BYTES + 1
        } else if name.starts_with("edge") {
            MAX_BYTES
        } else {
            4
        })
    }

    fn p(s: &str) -> PathBuf {
        PathBuf::from(format!("/tmp/open/{s}"))
    }

    #[test]
    fn keeps_files_and_skips_folders_and_missing_paths() {
        let plan = plan(
            &[p("notes.md"), p("photo.png"), p("missing.txt"), p("folder")],
            fake,
        );
        assert_eq!(plan.accepted, vec![p("notes.md"), p("photo.png")]);
        assert_eq!(plan.skipped, vec![p("missing.txt"), p("folder")]);
        assert_eq!((plan.too_many, plan.too_large.len()), (0, 0));
    }

    #[test]
    fn at_most_ten_files_each_up_to_256_mb() {
        let mut paths: Vec<PathBuf> = (0..12).map(|i| p(&format!("f{i}.txt"))).collect();
        paths.insert(3, p("huge.pdf"));
        paths.insert(5, p("edge.pdf"));
        let plan = plan(&paths, fake);
        assert_eq!(plan.accepted.len(), MAX_FILES);
        // 256 MB exactly is allowed; one byte more is not.
        assert!(plan.accepted.contains(&p("edge.pdf")));
        assert_eq!(plan.too_large, vec!["huge.pdf".to_string()]);
        // 13 acceptable files, 10 attached.
        assert_eq!(plan.too_many, 3);
        assert_eq!(plan.accepted[0], p("f0.txt"));
    }

    #[test]
    fn duplicates_count_once() {
        let plan = plan(&[p("a.md"), p("a.md"), p("b.md")], fake);
        assert_eq!(plan.accepted, vec![p("a.md"), p("b.md")]);
    }

    #[test]
    fn real_files_on_disk() {
        let dir = std::env::temp_dir().join(format!("conduit-open-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let file = dir.join("notes.md");
        std::fs::write(&file, b"# hi").unwrap();
        assert_eq!(file_size(&file), Some(4));
        assert_eq!(file_size(&dir), None);
        assert_eq!(file_size(&dir.join("missing.txt")), None);
    }
}
