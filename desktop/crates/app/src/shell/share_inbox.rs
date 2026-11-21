//! Shares from the Share extension (`packaging/macos/share`): "Conduit" in
//! another app's Share menu.
//!
//! The extension is sandboxed and the app is not, so they meet in one
//! folder the extension's entitlements open to it,
//! `~/Library/Caches/<bundle id>.share-inbox/`. Each share is a folder
//! named by a UUID, with `manifest.json` (what was shared; written by
//! `ShareInbox.swift`, whose tests and these share
//! `share/tests/manifest-v1.json`) and a copy of each file under
//! `files/<n>/<name>`. The extension writes it as `<uuid>.part`, renames it
//! when complete, and then opens `conduit://share/<uuid>` with this app.
//!
//! [`take`] reads a share once: the message and texts and links become the
//! new chat's message text (joined as the phone joins a share's text),
//! the files are attached, and the manifest is renamed so the same link
//! cannot attach them twice. Nothing in the manifest becomes a path
//! outside the share's folder. [`prune`] clears taken shares after a few
//! minutes (the composer has read them by then) and abandoned ones after a
//! day.

use std::path::{Component, Path, PathBuf};
use std::time::{Duration, SystemTime};

use serde::Deserialize;

/// The share's description, as the extension writes it.
pub const MANIFEST: &str = "manifest.json";
/// The manifest's name once the app took the share.
pub const TAKEN: &str = "manifest.taken.json";
/// The manifest version this app reads.
pub const VERSION: u32 = 1;
/// The longest message text a share fills in, in characters (the
/// extension cuts each text item to this too).
pub const MAX_TEXT: usize = 100_000;
/// How long a taken share's copies stay (the composer reads them at once).
pub const KEEP_TAKEN: Duration = Duration::from_secs(10 * 60);
/// How long a share nobody took stays.
pub const KEEP_UNTAKEN: Duration = Duration::from_secs(24 * 60 * 60);

#[derive(Clone, Debug, Default, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", default)]
pub struct Manifest {
    pub version: u32,
    pub message: Option<String>,
    pub texts: Vec<String>,
    pub urls: Vec<String>,
    pub files: Vec<ManifestFile>,
    pub too_large: Vec<String>,
    pub too_many: usize,
}

#[derive(Clone, Debug, Default, Deserialize, PartialEq, Eq)]
#[serde(default)]
pub struct ManifestFile {
    pub name: String,
    pub path: String,
}

/// What a share opens: a new chat with this text and these files, and
/// what the extension left out (for the same toasts "Open with" shows).
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Shared {
    pub text: Option<String>,
    pub files: Vec<PathBuf>,
    pub too_large: Vec<String>,
    pub too_many: usize,
}

/// Why a share could not be taken.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum TakeError {
    /// Not an id the extension makes.
    BadId,
    /// No such share (never written, or cleared).
    Missing,
    /// Already taken (the same link, twice).
    Taken,
    /// A newer extension wrote it.
    NewerVersion(u32),
    /// The manifest could not be read.
    Unreadable(String),
}

/// The inbox of the app with `bundle_id`, under `home`.
pub fn root(bundle_id: &str, home: &Path) -> PathBuf {
    home.join("Library/Caches")
        .join(format!("{bundle_id}.share-inbox"))
}

/// This app's inbox; `None` outside an app bundle (no extension then).
pub fn app_root() -> Option<PathBuf> {
    #[cfg(target_os = "macos")]
    {
        let bundle = objc2_foundation::NSBundle::mainBundle();
        if !bundle.bundlePath().to_string().ends_with(".app") {
            return None;
        }
        let id = bundle.bundleIdentifier()?.to_string();
        let home = std::env::var_os("HOME").map(PathBuf::from)?;
        Some(root(&id, &home))
    }
    #[cfg(not(target_os = "macos"))]
    None
}

/// A share id: a lowercase UUID, as the extension makes them.
pub fn valid_id(id: &str) -> bool {
    id.len() == 36
        && id.bytes().enumerate().all(|(i, b)| match i {
            8 | 13 | 18 | 23 => b == b'-',
            _ => b.is_ascii_digit() || (b'a'..=b'f').contains(&b),
        })
}

/// Reads share `id` from `root` and marks it taken.
pub fn take(root: &Path, id: &str) -> Result<Shared, TakeError> {
    if !valid_id(id) {
        return Err(TakeError::BadId);
    }
    let entry = root.join(id);
    if !std::fs::symlink_metadata(&entry).is_ok_and(|m| m.is_dir()) {
        return Err(TakeError::Missing);
    }
    let path = entry.join(MANIFEST);
    match std::fs::symlink_metadata(&path) {
        Ok(m) if m.is_file() => {}
        _ if entry.join(TAKEN).exists() => return Err(TakeError::Taken),
        _ => return Err(TakeError::Missing),
    }
    let text = std::fs::read_to_string(&path).map_err(|e| TakeError::Unreadable(e.to_string()))?;
    let manifest: Manifest =
        serde_json::from_str(&text).map_err(|e| TakeError::Unreadable(e.to_string()))?;
    if manifest.version > VERSION {
        return Err(TakeError::NewerVersion(manifest.version));
    }
    std::fs::rename(&path, entry.join(TAKEN)).map_err(|e| TakeError::Unreadable(e.to_string()))?;
    let files = manifest
        .files
        .iter()
        .filter_map(|f| file_in(&entry, &f.path))
        .collect();
    Ok(Shared {
        text: compose_text(&manifest),
        files,
        too_large: manifest.too_large.clone(),
        too_many: manifest.too_many,
    })
}

/// `relative` inside `entry`, when it names a regular file there: plain
/// components only, and no symlink anywhere on the way (a folder that is a
/// link would lead outside the share), the file itself included; and the
/// file, resolved, still inside the share.
fn file_in(entry: &Path, relative: &str) -> Option<PathBuf> {
    let rel = Path::new(relative);
    let plain =
        rel.components().count() > 0 && rel.components().all(|c| matches!(c, Component::Normal(_)));
    if !plain {
        return None;
    }
    let count = rel.components().count();
    let mut path = entry.to_path_buf();
    for (i, part) in rel.components().enumerate() {
        path.push(part);
        let meta = std::fs::symlink_metadata(&path).ok()?;
        let fits = if i + 1 == count {
            meta.file_type().is_file()
        } else {
            meta.file_type().is_dir()
        };
        if !fits {
            return None;
        }
    }
    let inside = std::fs::canonicalize(entry).ok()?;
    std::fs::canonicalize(&path)
        .is_ok_and(|real| real.starts_with(&inside))
        .then_some(path)
}

/// The new chat's message text: the message, then each text and link,
/// trimmed and each once, one per line (as the phone joins a share's text);
/// `None` when there is none.
pub fn compose_text(manifest: &Manifest) -> Option<String> {
    let mut parts: Vec<&str> = vec![];
    let all = manifest
        .message
        .iter()
        .chain(&manifest.texts)
        .chain(&manifest.urls);
    for part in all {
        let part = part.trim();
        if !part.is_empty() && !parts.contains(&part) {
            parts.push(part);
        }
    }
    (!parts.is_empty()).then(|| parts.join("\n").chars().take(MAX_TEXT).collect())
}

/// Clears shares in `root` that were taken more than [`KEEP_TAKEN`] ago,
/// or written more than [`KEEP_UNTAKEN`] ago and never taken. Only folders
/// the extension names (`<uuid>`, `<uuid>.part`) are touched. Returns how
/// many went.
pub fn prune(root: &Path, now: SystemTime) -> usize {
    let Ok(entries) = std::fs::read_dir(root) else {
        return 0;
    };
    let mut removed = 0;
    for entry in entries.flatten() {
        let name = entry.file_name().to_string_lossy().to_string();
        if !valid_id(name.strip_suffix(".part").unwrap_or(&name)) {
            continue;
        }
        let Ok(meta) = std::fs::symlink_metadata(entry.path()) else {
            continue;
        };
        if !meta.is_dir() {
            continue;
        }
        let path = entry.path();
        let keep = if path.join(TAKEN).exists() {
            KEEP_TAKEN
        } else {
            KEEP_UNTAKEN
        };
        let age = meta
            .modified()
            .ok()
            .and_then(|m| now.duration_since(m).ok())
            .unwrap_or_default();
        if age > keep && std::fs::remove_dir_all(&path).is_ok() {
            removed += 1;
        }
    }
    removed
}

#[cfg(test)]
mod tests {
    use super::*;

    const ID: &str = "6f1c2b9e-0d2a-4c1e-9a77-1b2c3d4e5f60";
    /// The manifest `ShareInbox.swift`'s tests write and compare against.
    const GOLDEN: &str = include_str!("../../../../packaging/macos/share/tests/manifest-v1.json");

    struct Scratch(PathBuf);

    impl Scratch {
        fn new(name: &str) -> Self {
            let dir = std::env::temp_dir()
                .join(format!("conduit-share-inbox-{name}-{}", std::process::id()));
            let _ = std::fs::remove_dir_all(&dir);
            std::fs::create_dir_all(&dir).unwrap();
            Self(dir)
        }

        /// A share as the extension leaves it.
        fn share(&self, id: &str, manifest: &str, files: &[&str]) -> PathBuf {
            let entry = self.0.join(id);
            for (i, name) in files.iter().enumerate() {
                let dir = entry.join(format!("files/{i}"));
                std::fs::create_dir_all(&dir).unwrap();
                std::fs::write(dir.join(name), b"synthetic").unwrap();
            }
            std::fs::create_dir_all(&entry).unwrap();
            std::fs::write(entry.join(MANIFEST), manifest).unwrap();
            entry
        }
    }

    impl Drop for Scratch {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn reads_the_extensions_manifest() {
        let m: Manifest = serde_json::from_str(GOLDEN).unwrap();
        assert_eq!(m.version, 1);
        assert_eq!(m.files.len(), 2);
        assert_eq!(m.files[0].path, "files/0/garden plan.pdf");
        assert_eq!(m.too_large, vec!["orchard tour.mov".to_string()]);
        assert_eq!(
            compose_text(&m).as_deref(),
            Some(
                "What should go in the north bed?\nTomatoes like six hours of sun.\n\
                 https://example.org/allotment/beds"
            )
        );
    }

    #[test]
    fn takes_a_share_once() {
        let s = Scratch::new("take");
        let entry = s.share(ID, GOLDEN, &["garden plan.pdf", "Image.png"]);
        let shared = take(&s.0, ID).unwrap();
        assert_eq!(
            shared.files,
            vec![
                entry.join("files/0/garden plan.pdf"),
                entry.join("files/1/Image.png")
            ]
        );
        assert_eq!(shared.too_large, vec!["orchard tour.mov".to_string()]);
        assert!(shared.text.unwrap().starts_with("What should go"));
        assert!(entry.join(TAKEN).exists() && !entry.join(MANIFEST).exists());
        // The same link again attaches nothing.
        assert_eq!(take(&s.0, ID), Err(TakeError::Taken));
    }

    #[test]
    fn refuses_bad_ids_missing_and_newer_shares() {
        let s = Scratch::new("refuse");
        assert_eq!(take(&s.0, "../etc"), Err(TakeError::BadId));
        assert_eq!(
            take(&s.0, &ID.to_uppercase()),
            Err(TakeError::BadId),
            "the extension writes lowercase ids"
        );
        assert_eq!(take(&s.0, ID), Err(TakeError::Missing));
        s.share(ID, r#"{"version": 2, "texts": ["x"]}"#, &[]);
        assert_eq!(take(&s.0, ID), Err(TakeError::NewerVersion(2)));
        let other = "00000000-0000-4000-8000-000000000000";
        s.share(other, "not json", &[]);
        assert!(matches!(take(&s.0, other), Err(TakeError::Unreadable(_))));
        // A share still being written is not there yet.
        let part = "11111111-1111-4111-8111-111111111111";
        std::fs::create_dir_all(s.0.join(format!("{part}.part"))).unwrap();
        assert_eq!(take(&s.0, part), Err(TakeError::Missing));
    }

    #[test]
    fn never_leaves_the_shares_folder() {
        let s = Scratch::new("paths");
        let outside = s.0.join("outside.txt");
        std::fs::write(&outside, b"not shared").unwrap();
        let manifest = format!(
            r#"{{"version": 1, "files": [
                {{"name": "a", "path": "../outside.txt"}},
                {{"name": "b", "path": {}}},
                {{"name": "c", "path": "files/0/link.txt"}},
                {{"name": "d", "path": ""}},
                {{"name": "e", "path": "files/1/kept.txt"}},
                {{"name": "f", "path": "files/9/missing.txt"}},
                {{"name": "g", "path": "files/2/notes.txt"}}
            ]}}"#,
            // As JSON, escaped: a Windows path has backslashes.
            serde_json::to_string(&outside).unwrap()
        );
        let entry = s.share(ID, &manifest, &[]);
        std::fs::create_dir_all(entry.join("files/0")).unwrap();
        #[cfg(unix)]
        std::os::unix::fs::symlink(&outside, entry.join("files/0/link.txt")).unwrap();
        std::fs::create_dir_all(entry.join("files/1")).unwrap();
        std::fs::write(entry.join("files/1/kept.txt"), b"kept").unwrap();
        // A folder on the way that is a link to a folder outside the share.
        let away = s.0.join("away");
        std::fs::create_dir_all(&away).unwrap();
        std::fs::write(away.join("notes.txt"), b"not shared").unwrap();
        #[cfg(unix)]
        std::os::unix::fs::symlink(&away, entry.join("files/2")).unwrap();
        let shared = take(&s.0, ID).unwrap();
        assert_eq!(shared.files, vec![entry.join("files/1/kept.txt")]);
        assert_eq!(shared.text, None);
    }

    #[test]
    fn joins_text_as_the_phone_does() {
        let m = Manifest {
            message: Some("  Look at this  ".into()),
            texts: vec!["Look at this".into(), " \n ".into(), "Second".into()],
            urls: vec!["https://example.org/a".into()],
            ..Default::default()
        };
        assert_eq!(
            compose_text(&m).as_deref(),
            Some("Look at this\nSecond\nhttps://example.org/a")
        );
        assert_eq!(compose_text(&Manifest::default()), None);
        let long = Manifest {
            texts: vec!["é".repeat(MAX_TEXT + 5)],
            ..Default::default()
        };
        assert_eq!(compose_text(&long).unwrap().chars().count(), MAX_TEXT);
    }

    #[test]
    fn prunes_old_shares_only() {
        let s = Scratch::new("prune");
        let fresh = "22222222-2222-4222-8222-222222222222";
        let taken = "33333333-3333-4333-8333-333333333333";
        s.share(fresh, GOLDEN, &[]);
        s.share(taken, GOLDEN, &[]);
        take(&s.0, taken).unwrap();
        std::fs::create_dir_all(s.0.join(format!("{fresh}.part"))).unwrap();
        std::fs::create_dir_all(s.0.join("not-a-share")).unwrap();
        let now = SystemTime::now();
        assert_eq!(prune(&s.0, now), 0, "nothing is old yet");
        // Eleven minutes on: the taken share goes.
        assert_eq!(prune(&s.0, now + Duration::from_secs(11 * 60)), 1);
        assert!(!s.0.join(taken).exists() && s.0.join(fresh).exists());
        // A day on: the untaken share and the unfinished one go; other
        // folders stay.
        assert_eq!(prune(&s.0, now + KEEP_UNTAKEN + Duration::from_secs(60)), 2);
        assert!(s.0.join("not-a-share").exists());
        assert_eq!(prune(&s.0.join("missing"), now), 0);
    }

    #[test]
    fn the_inbox_is_named_for_the_bundle() {
        assert_eq!(
            root("app.example.conduit", Path::new("/Users/someone")),
            PathBuf::from("/Users/someone/Library/Caches/app.example.conduit.share-inbox")
        );
        assert!(valid_id(ID));
        assert!(!valid_id("6f1c2b9e-0d2a-4c1e-9a77-1b2c3d4e5f6"));
        assert!(!valid_id("6f1c2b9e_0d2a-4c1e-9a77-1b2c3d4e5f60"));
    }
}
