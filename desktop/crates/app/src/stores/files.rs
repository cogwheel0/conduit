//! Server files through the daemon: images for the window and attachments
//! opened in another app.
//!
//! * **Images:** [`file_image_state`] loads `/files/{server}/{id}` through
//!   GPUI's asset cache ([`DaemonFileImage`]): the daemon is asked once per
//!   file and port (a restarted daemon is a new port, so a stale failure is
//!   not kept), with the session token as the bearer, and the bytes are
//!   decoded by GPUI like any other image. [`retry_file_image`] forgets a
//!   failure so the next draw asks again.
//! * **Attachments:** [`open_attachment`] downloads a file into the daemon's
//!   staging directory and opens it with its default app or in Quick Look.
//!
//! [`FileAccess`] (a global the connection store keeps current) holds the
//! HTTP client and the staging directory.

use std::path::{Path, PathBuf};
use std::sync::Arc;

use conduit_daemon::http::HttpClient;
use conduit_daemon::runtime;
use gpui_kit::{
    App, Asset, Global, Image, ImageCacheError, ImageFormat, RenderImage, Task, Window,
};

/// What file loads need: set by the connection store.
#[derive(Clone, Default)]
pub struct FileAccess {
    pub http: Option<HttpClient>,
    pub port: Option<u16>,
    /// The daemon's staging directory (`DaemonPaths.staging`).
    pub staging: Option<PathBuf>,
}

impl Global for FileAccess {}

/// A file on the active account's server.
#[derive(Clone, Debug, Hash, PartialEq, Eq)]
pub struct FileRef {
    /// The active account's id (its `ServerSummary.id`).
    pub server_id: String,
    pub file_id: String,
}

/// The image format for a response, from its type, else its bytes.
pub fn image_format(content_type: &str, bytes: &[u8]) -> Option<ImageFormat> {
    let mime = content_type
        .split(';')
        .next()
        .unwrap_or_default()
        .trim()
        .to_ascii_lowercase();
    let by_type = match mime.as_str() {
        "image/png" => Some(ImageFormat::Png),
        "image/jpeg" | "image/jpg" => Some(ImageFormat::Jpeg),
        "image/webp" => Some(ImageFormat::Webp),
        "image/gif" => Some(ImageFormat::Gif),
        "image/svg+xml" => Some(ImageFormat::Svg),
        "image/bmp" => Some(ImageFormat::Bmp),
        "image/tiff" => Some(ImageFormat::Tiff),
        "image/x-icon" | "image/vnd.microsoft.icon" => Some(ImageFormat::Ico),
        _ => None,
    };
    by_type.or_else(|| sniff(bytes))
}

fn sniff(b: &[u8]) -> Option<ImageFormat> {
    if b.starts_with(b"\x89PNG\r\n\x1a\n") {
        Some(ImageFormat::Png)
    } else if b.starts_with(&[0xff, 0xd8, 0xff]) {
        Some(ImageFormat::Jpeg)
    } else if b.starts_with(b"GIF8") {
        Some(ImageFormat::Gif)
    } else if b.len() >= 12 && &b[0..4] == b"RIFF" && &b[8..12] == b"WEBP" {
        Some(ImageFormat::Webp)
    } else if b.starts_with(b"BM") {
        Some(ImageFormat::Bmp)
    } else if b.starts_with(b"II*\0") || b.starts_with(b"MM\0*") {
        Some(ImageFormat::Tiff)
    } else {
        let head = String::from_utf8_lossy(&b[..b.len().min(256)]).to_ascii_lowercase();
        (head.contains("<svg") || head.trim_start().starts_with("<?xml"))
            .then_some(ImageFormat::Svg)
    }
}

/// Fetches `file` on the daemon's tokio runtime; any executor can await it.
async fn fetch(http: HttpClient, file: FileRef) -> Result<(Vec<u8>, String), String> {
    let (tx, rx) = futures::channel::oneshot::channel();
    runtime::shared().spawn(async move {
        let result = http
            .file(&file.server_id, &file.file_id)
            .await
            .map(|f| (f.bytes.to_vec(), f.content_type))
            .map_err(|e| e.to_string());
        let _ = tx.send(result);
    });
    rx.await
        .unwrap_or_else(|_| Err("the download was dropped".into()))
}

/// The GPUI asset that loads a `/files` image.
pub enum DaemonFileImage {}

impl Asset for DaemonFileImage {
    /// The daemon's port (a new daemon refetches) and the file.
    type Source = (u16, FileRef);
    type Output = Result<Arc<RenderImage>, ImageCacheError>;

    fn load(
        (_, file): Self::Source,
        cx: &mut App,
    ) -> impl std::future::Future<Output = Self::Output> + Send + 'static {
        let http = cx.try_global::<FileAccess>().and_then(|a| a.http.clone());
        let renderer = cx.svg_renderer();
        async move {
            let id = file.file_id.clone();
            let fetched = async {
                let http = http.ok_or_else(|| "the daemon is not running".to_string())?;
                let (bytes, content_type) = fetch(http, file).await?;
                let format = image_format(&content_type, &bytes)
                    .ok_or_else(|| format!("not an image ({content_type})"))?;
                Ok::<_, String>(Image::from_bytes(format, bytes))
            }
            .await;
            // The decoder's own error is kept (an SVG from outside the app
            // is told apart by it: the tile offers Open in Browser).
            let result = match fetched {
                Ok(image) => crate::stores::media::decode_picture(&image, renderer),
                Err(m) => Err(anyhow::anyhow!(m)),
            };
            if let Err(e) = &result {
                log::warn!("image {id}: {e}");
            }
            result.map_err(|e| ImageCacheError::Other(Arc::new(e)))
        }
    }
}

/// A model's profile image on the active account's server.
#[derive(Clone, Debug, Hash, PartialEq, Eq)]
pub struct ModelImageRef {
    pub server_id: String,
    pub model_id: String,
}

/// The GPUI asset that loads a model's picture through the daemon's
/// `/files/{server}/models/{model}`, as [`DaemonFileImage`] loads a file.
pub enum DaemonModelImage {}

impl Asset for DaemonModelImage {
    type Source = (u16, ModelImageRef);
    type Output = Result<Arc<RenderImage>, ImageCacheError>;

    fn load(
        (_, model): Self::Source,
        cx: &mut App,
    ) -> impl std::future::Future<Output = Self::Output> + Send + 'static {
        let http = cx.try_global::<FileAccess>().and_then(|a| a.http.clone());
        let renderer = cx.svg_renderer();
        async move {
            let other = |m: String| ImageCacheError::Other(Arc::new(anyhow::anyhow!(m)));
            let result = async {
                let http = http.ok_or_else(|| "the daemon is not running".to_string())?;
                let (tx, rx) = futures::channel::oneshot::channel();
                runtime::shared().spawn(async move {
                    let result = http
                        .model_image(&model.server_id, &model.model_id)
                        .await
                        .map(|f| (f.bytes.to_vec(), f.content_type))
                        .map_err(|e| e.to_string());
                    let _ = tx.send(result);
                });
                let (bytes, content_type) = rx
                    .await
                    .unwrap_or_else(|_| Err("the download was dropped".into()))?;
                let format = image_format(&content_type, &bytes)
                    .ok_or_else(|| format!("not an image ({content_type})"))?;
                crate::stores::media::decode_picture(&Image::from_bytes(format, bytes), renderer)
                    .map_err(|e| e.to_string())
            }
            .await;
            // A model with no picture of its own is not news; the window
            // draws its initial.
            if let Err(e) = &result {
                log::debug!("model image: {e}");
            }
            result.map_err(other)
        }
    }
}

/// Where a model's picture is, as [`file_image_state`] says for a file.
pub fn model_image_state(
    model: &ModelImageRef,
    window: &mut Window,
    cx: &mut App,
) -> Option<Result<Arc<RenderImage>, ImageCacheError>> {
    let port = cx.try_global::<FileAccess>().and_then(|a| a.port)?;
    window.use_asset::<DaemonModelImage>(&(port, model.clone()), cx)
}

/// Forgets a model's picture, so the next draw asks again (after a save
/// changed it).
pub fn forget_model_image(model: &ModelImageRef, cx: &mut App) {
    if let Some(port) = cx.try_global::<FileAccess>().and_then(|a| a.port) {
        cx.remove_asset::<DaemonModelImage>(&(port, model.clone()));
    }
}

/// Where `file`'s image is: `None` while it loads (or the daemon is down),
/// then the decoded image or why it failed. Asking starts the load, and the
/// calling view is drawn again when it ends.
pub fn file_image_state(
    file: &FileRef,
    window: &mut Window,
    cx: &mut App,
) -> Option<Result<Arc<RenderImage>, ImageCacheError>> {
    let port = cx.try_global::<FileAccess>().and_then(|a| a.port)?;
    window.use_asset::<DaemonFileImage>(&(port, file.clone()), cx)
}

/// Forgets `file`'s load (a failure), so the next draw asks the daemon
/// again.
pub fn retry_file_image(file: &FileRef, cx: &mut App) {
    if let Some(port) = cx.try_global::<FileAccess>().and_then(|a| a.port) {
        cx.remove_asset::<DaemonFileImage>(&(port, file.clone()));
    }
}

/// How [`open_attachment`] shows a file.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum OpenWith {
    /// The file's default app (Preview for a PDF).
    DefaultApp,
    /// A Quick Look panel.
    QuickLook,
}

/// A safe file name for `name`: no path parts, no control characters, not
/// hidden, at most 120 bytes, with its extension kept.
pub fn safe_name(name: &str) -> String {
    let base = name.rsplit(['/', '\\']).next().unwrap_or_default();
    let mut out: String = base
        .chars()
        .map(|c| {
            if c.is_control() || matches!(c, ':' | '/' | '\\') {
                '_'
            } else {
                c
            }
        })
        .collect();
    out = out.trim().trim_start_matches('.').to_string();
    if out.is_empty() {
        out = "attachment".into();
    }
    if out.len() > 120 {
        let ext = Path::new(&out)
            .extension()
            .and_then(|e| e.to_str())
            .filter(|e| e.len() <= 10)
            .map(|e| format!(".{e}"))
            .unwrap_or_default();
        let mut cut = 120 - ext.len();
        while !out.is_char_boundary(cut) {
            cut -= 1;
        }
        out = format!("{}{ext}", &out[..cut]);
    }
    out
}

/// Where `file` is staged: `<staging>/open/<file id>/<name>`, so two files
/// with one name do not collide.
pub fn staged_path(staging: &Path, file: &FileRef, name: &str) -> PathBuf {
    // Keyed by server too: two servers may hand out the same file id.
    staging
        .join("open")
        .join(safe_name(&file.server_id))
        .join(safe_name(&file.file_id))
        .join(safe_name(name))
}

/// Downloads `file` into the staging directory (the image viewer's Share
/// and Save…, a video to play). Resolves with where it was saved; a file
/// already staged is not fetched again.
pub fn stage_file(file: FileRef, name: &str, cx: &mut App) -> Task<Result<PathBuf, String>> {
    let access = cx.try_global::<FileAccess>().cloned().unwrap_or_default();
    let (Some(http), Some(staging)) = (access.http, access.staging) else {
        return Task::ready(Err("the daemon is not running".into()));
    };
    let path = staged_path(&staging, &file, name);
    cx.spawn(async move |cx| {
        if path.is_file() {
            return Ok(path);
        }
        let (bytes, _) = fetch(http, file).await?;
        let target = path.clone();
        cx.background_executor()
            .spawn(async move { write_whole(&target, &bytes) })
            .await?;
        Ok(path)
    })
}

/// Writes `bytes` beside `target`, then moves them into place: a file is
/// at `target` only once it is whole (a staged file found there is taken
/// as done, and a video player may already be reading it).
fn write_whole(target: &Path, bytes: &[u8]) -> Result<(), String> {
    if let Some(dir) = target.parent() {
        std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
    }
    static WRITES: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    let n = WRITES.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    let part = target.with_file_name(format!(
        ".{}.staging.{n}.part",
        target
            .file_name()
            .and_then(|f| f.to_str())
            .unwrap_or("file")
    ));
    std::fs::write(&part, bytes).map_err(|e| e.to_string())?;
    std::fs::rename(&part, target).map_err(|e| {
        let _ = std::fs::remove_file(&part);
        e.to_string()
    })
}

/// Writes `bytes` (an image an answer carried inline) into the staging
/// directory as `name`, for Share and Save…
pub fn stage_bytes(bytes: Vec<u8>, key: &str, name: &str, cx: &App) -> Result<PathBuf, String> {
    let staging = cx
        .try_global::<FileAccess>()
        .and_then(|a| a.staging.clone())
        .unwrap_or_else(std::env::temp_dir);
    let path = staging
        .join("open")
        .join(safe_name(key))
        .join(safe_name(name));
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
    }
    std::fs::write(&path, bytes).map_err(|e| e.to_string())?;
    Ok(path)
}

/// Downloads `file` into the staging directory and opens it. Resolves with
/// where it was saved.
pub fn open_attachment(
    file: FileRef,
    name: &str,
    how: OpenWith,
    cx: &mut App,
) -> Task<Result<PathBuf, String>> {
    let access = cx.try_global::<FileAccess>().cloned().unwrap_or_default();
    let (Some(http), Some(staging)) = (access.http, access.staging) else {
        return Task::ready(Err("the daemon is not running".into()));
    };
    let path = staged_path(&staging, &file, name);
    cx.spawn(async move |cx| {
        let (bytes, _) = fetch(http, file).await?;
        let target = path.clone();
        cx.background_executor()
            .spawn(async move {
                if let Some(dir) = target.parent() {
                    std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
                }
                // Written beside it, then moved into place: a viewer still
                // reading an earlier open never sees a half-written file.
                static WRITES: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
                let n = WRITES.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                let part = target.with_file_name(format!(
                    ".{}.{n}.part",
                    target
                        .file_name()
                        .and_then(|f| f.to_str())
                        .unwrap_or("file")
                ));
                std::fs::write(&part, bytes).map_err(|e| e.to_string())?;
                std::fs::rename(&part, &target).map_err(|e| e.to_string())
            })
            .await?;
        match how {
            OpenWith::DefaultApp => {
                cx.update(|cx| cx.open_with_system(&path));
            }
            OpenWith::QuickLook => {
                let mut child = std::process::Command::new("/usr/bin/qlmanage")
                    .arg("-p")
                    .arg(&path)
                    .stdout(std::process::Stdio::null())
                    .stderr(std::process::Stdio::null())
                    .spawn()
                    .map_err(|e| e.to_string())?;
                // Reaped once the preview closes, on a thread of its own.
                std::thread::spawn(move || {
                    let _ = child.wait();
                });
            }
        }
        Ok(path)
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn formats_come_from_the_type_then_the_bytes() {
        assert_eq!(image_format("image/png", b""), Some(ImageFormat::Png));
        assert_eq!(
            image_format("image/jpeg; charset=binary", b""),
            Some(ImageFormat::Jpeg)
        );
        assert_eq!(
            image_format("application/octet-stream", b"\x89PNG\r\n\x1a\n...."),
            Some(ImageFormat::Png)
        );
        assert_eq!(
            image_format("application/octet-stream", b"RIFF\0\0\0\0WEBPVP8 "),
            Some(ImageFormat::Webp)
        );
        assert_eq!(
            image_format("", b"<svg xmlns='http://www.w3.org/2000/svg'/>"),
            Some(ImageFormat::Svg)
        );
        assert_eq!(image_format("application/pdf", b"%PDF-1.7"), None);
    }

    #[test]
    fn a_staged_file_is_in_place_only_once_whole() {
        let dir = std::env::temp_dir().join(format!("conduit-stage-{}", std::process::id()));
        let target = dir.join("open").join("clip.mp4");
        write_whole(&target, b"synthetic movie bytes").unwrap();
        assert_eq!(std::fs::read(&target).unwrap(), b"synthetic movie bytes");
        let left: Vec<_> = std::fs::read_dir(target.parent().unwrap())
            .unwrap()
            .filter_map(|e| e.ok())
            .map(|e| e.file_name().to_string_lossy().to_string())
            .collect();
        assert_eq!(left, vec!["clip.mp4".to_string()], "a part file was left");
    }

    #[test]
    fn staged_names_cannot_escape_the_staging_directory() {
        let file = FileRef {
            server_id: "s".into(),
            file_id: "../../etc".into(),
        };
        let p = staged_path(Path::new("/stage"), &file, "../../.ssh/id_rsa");
        assert!(p.starts_with("/stage/open"), "{}", p.display());
        assert_eq!(p.file_name().unwrap(), "id_rsa");
        assert_eq!(safe_name(".hidden"), "hidden");
        assert_eq!(safe_name("a:b\u{0}c.pdf"), "a_b_c.pdf");
        assert_eq!(safe_name(""), "attachment");
        let long = format!("{}.pdf", "é".repeat(100));
        let s = safe_name(&long);
        assert!(s.len() <= 120 && s.ends_with(".pdf"), "{s}");
        // Two servers' files with one id and name never share a path.
        let on = |server: &str| FileRef {
            server_id: server.into(),
            file_id: "file-1".into(),
        };
        assert_ne!(
            staged_path(Path::new("/stage"), &on("server-a"), "notes.md"),
            staged_path(Path::new("/stage"), &on("server-b"), "notes.md")
        );
    }
}
