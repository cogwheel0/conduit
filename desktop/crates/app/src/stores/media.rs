//! Pictures and PDFs an answer links to, for the transcript.
//!
//! * **Where a link points** ([`classify`]): a `data:` picture the message
//!   carries; a file on the account's own server (`/api/v1/files/{id}`,
//!   relative or on its address), loaded through the daemon's
//!   authenticated `/files` as attachments are; another path on that server;
//!   or another site.
//! * **Another site** loads only after a click (Load Image, one picture,
//!   until the app quits: [`load_once`]) or when its host is allowed
//!   (Always Load Images from …, `SettingsStore::allow_image_host`), since
//!   a picture from anywhere can be a tracking pixel. The daemon fetches it
//!   (`/media`), with no cookies, credentials or `Referer`, within a size
//!   and a time limit, once.
//! * **Loads** are GPUI assets ([`RemoteImage`], [`PdfPreviewAsset`]):
//!   asked for when drawn, kept while the app runs, and asked again only
//!   after [`retry_image`] / [`retry_pdf`] forget a failure.
//! * **PDF previews** draw the first page with Quartz (the PDF engine
//!   PDFKit uses) off the main thread, never in a web view, and count the
//!   pages, which costs nothing once the document is open.

use std::cell::RefCell;
use std::collections::HashSet;
use std::sync::Arc;

use conduit_daemon::runtime;
use gpui_kit::{App, Asset, Image, RenderImage, Window};

use super::files::{FileAccess, FileRef, image_format};

/// `host` as the allowed list keeps it: lower case, without a trailing dot.
pub fn normalize_host(host: &str) -> String {
    host.trim().trim_end_matches('.').to_ascii_lowercase()
}

/// Where a picture or PDF link points.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub enum LinkTarget {
    /// A `data:` URL the message carries.
    Inline,
    /// A file on the account's server, by its id.
    ServerFile(FileRef),
    /// Another address on the account's server (absolute): loaded without
    /// asking, like the server's files, but with no credentials.
    Server(String),
    /// Another site.
    Remote { url: String, host: String },
    /// Nothing to load (another scheme, or a relative link with no
    /// server to resolve it against).
    Unsupported,
}

/// The account's server, which links are checked against.
#[derive(Clone, Debug, Default)]
pub struct ServerOrigin {
    /// The account's id (`FileRef::server_id`).
    pub id: String,
    /// Its address (`ServerSummary::url`).
    pub url: String,
}

impl ServerOrigin {
    /// The active account's server, if there is one.
    pub fn active(cx: &App) -> Option<Self> {
        let state = cx.try_global::<crate::AppState>()?;
        let account = state.stores.accounts.read(cx).active()?;
        Some(Self {
            id: account.connection.id.clone(),
            url: account.connection.url.clone(),
        })
    }
}

/// The scheme, host and port that make `url` the same site as another.
fn origin_of(url: &url::Url) -> (String, String, Option<u16>) {
    (
        url.scheme().to_string(),
        url.host_str().map(normalize_host).unwrap_or_default(),
        url.port_or_known_default(),
    )
}

/// An Open WebUI file id in a path: `/api/v1/files/{id}` or
/// `/api/v1/files/{id}/content` (the daemon's own rule for message files).
pub fn file_id(path: &str) -> Option<String> {
    let rest = path.strip_prefix("/api/v1/files/")?;
    let id = rest.strip_suffix("/content").unwrap_or(rest);
    (!id.is_empty() && !id.contains('/')).then(|| id.to_string())
}

/// Where `raw` points, for the account's server `server`.
pub fn classify(raw: &str, server: Option<&ServerOrigin>) -> LinkTarget {
    let raw = raw.trim();
    if raw.starts_with("data:") {
        return LinkTarget::Inline;
    }
    let base = server.and_then(|s| url::Url::parse(&s.url).ok());
    // A path on the server (`/api/v1/files/…`), as Open WebUI stores an
    // image a tool returned.
    if raw.starts_with('/') && !raw.starts_with("//") {
        let (Some(server), Some(base)) = (server, &base) else {
            return LinkTarget::Unsupported;
        };
        let path = raw.split(['?', '#']).next().unwrap_or_default();
        if let Some(id) = file_id(path) {
            return LinkTarget::ServerFile(FileRef {
                server_id: server.id.clone(),
                file_id: id,
            });
        }
        return match base.join(raw) {
            Ok(url) => LinkTarget::Server(url.to_string()),
            Err(_) => LinkTarget::Unsupported,
        };
    }
    let Ok(url) = url::Url::parse(raw) else {
        return LinkTarget::Unsupported;
    };
    if !matches!(url.scheme(), "http" | "https") || !url.username().is_empty() {
        return LinkTarget::Unsupported;
    }
    let Some(host) = url.host_str().map(normalize_host) else {
        return LinkTarget::Unsupported;
    };
    if let (Some(server), Some(base)) = (server, &base)
        && origin_of(&url) == origin_of(base)
    {
        if let Some(id) = file_id(url.path()) {
            return LinkTarget::ServerFile(FileRef {
                server_id: server.id.clone(),
                file_id: id,
            });
        }
        return LinkTarget::Server(url.to_string());
    }
    LinkTarget::Remote {
        url: url.to_string(),
        host,
    }
}

thread_local! {
    /// Pictures and PDFs from other sites the user loaded with a click,
    /// by address, until the app quits.
    static LOADED: RefCell<HashSet<String>> = RefCell::new(HashSet::new());
}

/// Load Image: this one address loads, here and wherever else it shows.
pub fn load_once(url: &str, cx: &mut App) {
    LOADED.with(|l| l.borrow_mut().insert(url.to_string()));
    cx.refresh_windows();
}

/// Whether `url` (from `host`) loads without a click: loaded once, or its
/// host is allowed.
pub fn may_load(url: &str, host: &str, cx: &App) -> bool {
    LOADED.with(|l| l.borrow().contains(url)) || host_allowed(host, cx)
}

/// Whether `host` is on the allowed list.
pub fn host_allowed(host: &str, cx: &App) -> bool {
    cx.try_global::<crate::AppState>()
        .is_some_and(|s| s.settings.read(cx).image_host_allowed(host))
}

/// Always Load Images from `host`.
pub fn allow_host(host: &str, cx: &mut App) {
    if let Some(settings) = cx
        .try_global::<crate::AppState>()
        .map(|s| s.settings.clone())
    {
        settings.update(cx, |s, cx| s.allow_image_host(host, cx));
    }
}

/// Why a picture or PDF did not load.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum MediaError {
    /// Larger than the daemon fetches.
    TooLarge,
    /// The site answered with something else.
    WrongType,
    /// The site took too long.
    TimedOut,
    /// The site failed, could not be reached, or the bytes did not decode.
    Failed,
}

impl MediaError {
    fn of(e: &conduit_daemon::RpcError) -> Self {
        match e.code.as_str() {
            "media.tooLarge" => Self::TooLarge,
            "media.wrongType" => Self::WrongType,
            "media.timedOut" => Self::TimedOut,
            _ => Self::Failed,
        }
    }
}

/// A picture that loaded: its bytes (for the viewer, Copy Image and Save
/// Image…) and the decoded frames GPUI draws.
#[derive(Clone)]
pub struct LoadedImage {
    pub encoded: Arc<Image>,
    pub render: Arc<RenderImage>,
}

/// Fetches `url` (`kind` `image` or `pdf`) through the daemon on its
/// runtime; any executor can await it.
async fn fetch_media(
    access: FileAccess,
    kind: &'static str,
    url: String,
) -> Result<(Vec<u8>, String), MediaError> {
    let http = access.http.ok_or(MediaError::Failed)?;
    let (tx, rx) = futures::channel::oneshot::channel();
    runtime::shared().spawn(async move {
        let result = http
            .media(kind, &url)
            .await
            .map(|f| (f.bytes.to_vec(), f.content_type))
            .map_err(|e| MediaError::of(&e));
        let _ = tx.send(result);
    });
    rx.await.unwrap_or(Err(MediaError::Failed))
}

/// Fetches a server file through `/files`.
async fn fetch_file(access: FileAccess, file: FileRef) -> Result<(Vec<u8>, String), MediaError> {
    let http = access.http.ok_or(MediaError::Failed)?;
    let (tx, rx) = futures::channel::oneshot::channel();
    runtime::shared().spawn(async move {
        let result = http
            .file(&file.server_id, &file.file_id)
            .await
            .map(|f| (f.bytes.to_vec(), f.content_type))
            .map_err(|e| MediaError::of(&e));
        let _ = tx.send(result);
    });
    rx.await.unwrap_or(Err(MediaError::Failed))
}

/// The GPUI asset that loads a picture from another site (or another path
/// on the server) through `/media/image`.
pub enum RemoteImage {}

impl Asset for RemoteImage {
    /// The daemon's port (a new daemon refetches) and the address.
    type Source = (u16, String);
    type Output = Result<LoadedImage, MediaError>;

    fn load(
        (_, url): Self::Source,
        cx: &mut App,
    ) -> impl std::future::Future<Output = Self::Output> + Send + 'static {
        let access = cx.try_global::<FileAccess>().cloned().unwrap_or_default();
        let renderer = cx.svg_renderer();
        async move {
            let (bytes, content_type) = fetch_media(access, "image", url).await?;
            let format = image_format(&content_type, &bytes).ok_or(MediaError::WrongType)?;
            if too_many_pixels(&bytes) {
                return Err(MediaError::TooLarge);
            }
            let encoded = Arc::new(Image::from_bytes(format, bytes));
            let render = encoded
                .to_image_data(renderer)
                .map_err(|_| MediaError::WrongType)?;
            Ok(LoadedImage { encoded, render })
        }
    }
}

/// The most pixels a picture from another site may have: a small file
/// can unpack to gigabytes (a 30,000 × 30,000 PNG of one colour), and GPUI
/// decodes it whole.
const MAX_PIXELS: u64 = 40_000_000;

/// Whether `bytes` say they unpack to more than [`MAX_PIXELS`] (read from
/// the header alone; a format whose size is not read this way passes).
fn too_many_pixels(bytes: &[u8]) -> bool {
    image::ImageReader::new(std::io::Cursor::new(bytes))
        .with_guessed_format()
        .ok()
        .and_then(|r| r.into_dimensions().ok())
        .is_some_and(|(w, h)| u64::from(w) * u64::from(h) > MAX_PIXELS)
}

/// `url`'s picture: `None` while it loads (or with no daemon), then the
/// picture or why not. Asking starts the load; the window is drawn again
/// when it ends.
pub fn image_state(
    url: &str,
    window: &mut Window,
    cx: &mut App,
) -> Option<Result<LoadedImage, MediaError>> {
    let port = cx.try_global::<FileAccess>().and_then(|a| a.port)?;
    window.use_asset::<RemoteImage>(&(port, url.to_string()), cx)
}

/// Try Again: forgets `url`'s failure, so the next draw fetches it again.
pub fn retry_image(url: &str, cx: &mut App) {
    if let Some(port) = cx.try_global::<FileAccess>().and_then(|a| a.port) {
        cx.remove_asset::<RemoteImage>(&(port, url.to_string()));
    }
}

/// Where a PDF's bytes come from.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub enum PdfSource {
    /// A file on the account's server (`/files`).
    File(FileRef),
    /// An address the daemon fetches (`/media/pdf`).
    Url(String),
}

/// A PDF's card: its first page, drawn `width` pixels wide and cut at the
/// card's height, and how many pages it has.
#[derive(Clone)]
pub struct PdfPreview {
    pub page: Arc<RenderImage>,
    /// The page's width over its height.
    pub aspect: f32,
    pub pages: usize,
}

/// The GPUI asset that loads a PDF and draws its first page.
pub enum PdfPreviewAsset {}

impl Asset for PdfPreviewAsset {
    /// The daemon's port, the source, and the page's width and the card's
    /// height in pixels.
    type Source = (u16, PdfSource, u32, u32);
    type Output = Result<PdfPreview, MediaError>;

    fn load(
        (_, source, width, height): Self::Source,
        cx: &mut App,
    ) -> impl std::future::Future<Output = Self::Output> + Send + 'static {
        let access = cx.try_global::<FileAccess>().cloned().unwrap_or_default();
        async move {
            let (bytes, _) = match source {
                PdfSource::File(file) => fetch_file(access, file).await?,
                PdfSource::Url(url) => fetch_media(access, "pdf", url).await?,
            };
            if !bytes.starts_with(b"%PDF-") {
                return Err(MediaError::WrongType);
            }
            pdf_thumbnail(&bytes, width, height).ok_or(MediaError::Failed)
        }
    }
}

/// `source`'s card, drawn `width` × `height` pixels: `None` while it
/// loads.
pub fn pdf_state(
    source: &PdfSource,
    width: u32,
    height: u32,
    window: &mut Window,
    cx: &mut App,
) -> Option<Result<PdfPreview, MediaError>> {
    let port = cx.try_global::<FileAccess>().and_then(|a| a.port)?;
    window.use_asset::<PdfPreviewAsset>(&(port, source.clone(), width, height), cx)
}

/// Try Again for a PDF card.
pub fn retry_pdf(source: &PdfSource, width: u32, height: u32, cx: &mut App) {
    if let Some(port) = cx.try_global::<FileAccess>().and_then(|a| a.port) {
        cx.remove_asset::<PdfPreviewAsset>(&(port, source.clone(), width, height));
    }
}

/// The top of `pdf`'s first page, `width` pixels wide and at most `height`
/// tall, on white, and the page count. `None` when Quartz cannot open it.
#[cfg(target_os = "macos")]
pub fn pdf_thumbnail(pdf: &[u8], width: u32, height: u32) -> Option<PdfPreview> {
    quartz::first_page(pdf, width, height)
}

#[cfg(not(target_os = "macos"))]
pub fn pdf_thumbnail(_: &[u8], _: u32, _: u32) -> Option<PdfPreview> {
    None
}

#[cfg(target_os = "macos")]
mod quartz {
    //! CoreGraphics' PDF calls (Quartz), declared here: the document from
    //! bytes, its first page drawn into a BGRA bitmap.
    use std::ffi::c_void;
    use std::sync::Arc;

    use gpui_kit::RenderImage;

    use super::PdfPreview;

    #[repr(C)]
    #[derive(Clone, Copy)]
    struct CGPoint {
        x: f64,
        y: f64,
    }
    #[repr(C)]
    #[derive(Clone, Copy)]
    struct CGSize {
        width: f64,
        height: f64,
    }
    #[repr(C)]
    #[derive(Clone, Copy)]
    struct CGRect {
        origin: CGPoint,
        size: CGSize,
    }
    #[repr(C)]
    #[derive(Clone, Copy)]
    struct CGAffineTransform {
        a: f64,
        b: f64,
        c: f64,
        d: f64,
        tx: f64,
        ty: f64,
    }

    type Ref = *mut c_void;

    /// `kCGPDFCropBox`.
    const CROP_BOX: i32 = 1;
    /// `kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little`:
    /// BGRA in memory, as GPUI keeps its frames.
    const BGRA: u32 = 2 | (2 << 12);

    #[link(name = "CoreGraphics", kind = "framework")]
    unsafe extern "C" {
        fn CGDataProviderCreateWithData(
            info: *mut c_void,
            data: *const c_void,
            size: usize,
            release: Option<unsafe extern "C" fn(*mut c_void, *const c_void, usize)>,
        ) -> Ref;
        fn CGDataProviderRelease(provider: Ref);
        fn CGPDFDocumentCreateWithProvider(provider: Ref) -> Ref;
        fn CGPDFDocumentRelease(document: Ref);
        fn CGPDFDocumentGetNumberOfPages(document: Ref) -> usize;
        fn CGPDFDocumentGetPage(document: Ref, number: usize) -> Ref;
        fn CGPDFPageGetBoxRect(page: Ref, kind: i32) -> CGRect;
        fn CGPDFPageGetRotationAngle(page: Ref) -> i32;
        fn CGColorSpaceCreateDeviceRGB() -> Ref;
        fn CGColorSpaceRelease(space: Ref);
        fn CGBitmapContextCreate(
            data: *mut c_void,
            width: usize,
            height: usize,
            bits_per_component: usize,
            bytes_per_row: usize,
            space: Ref,
            info: u32,
        ) -> Ref;
        fn CGContextRelease(context: Ref);
        fn CGContextSetRGBFillColor(context: Ref, r: f64, g: f64, b: f64, a: f64);
        fn CGContextFillRect(context: Ref, rect: CGRect);
        fn CGContextConcatCTM(context: Ref, transform: CGAffineTransform);
        fn CGContextDrawPDFPage(context: Ref, page: Ref);
    }

    /// Maps the crop box `rect`, turned `rotation` degrees clockwise (a
    /// page's `/Rotate`), onto `[0, w] × [lift, lift + h]` at `scale`.
    fn page_transform(rect: CGRect, rotation: i32, scale: f64, lift: f64) -> CGAffineTransform {
        let (x0, y0) = (rect.origin.x, rect.origin.y);
        let (w0, h0) = (rect.size.width, rect.size.height);
        // (x, y) → (a·x + c·y + tx, b·x + d·y + ty), before the scale.
        let (a, b, c, d, tx, ty) = match rotation {
            90 => (0., -1., 1., 0., -y0, w0 + x0),
            180 => (-1., 0., 0., -1., x0 + w0, y0 + h0),
            270 => (0., 1., -1., 0., y0 + h0, -x0),
            _ => (1., 0., 0., 1., -x0, -y0),
        };
        CGAffineTransform {
            a: a * scale,
            b: b * scale,
            c: c * scale,
            d: d * scale,
            tx: tx * scale,
            ty: ty * scale + lift,
        }
    }

    pub fn first_page(pdf: &[u8], width: u32, height: u32) -> Option<PdfPreview> {
        if pdf.is_empty() || width == 0 || height == 0 {
            return None;
        }
        // SAFETY: Quartz's documented C API. The provider reads `pdf`
        // without copying, and is released (with the document) before
        // this function returns, while `pdf` is still borrowed.
        unsafe {
            let provider = CGDataProviderCreateWithData(
                std::ptr::null_mut(),
                pdf.as_ptr().cast(),
                pdf.len(),
                None,
            );
            if provider.is_null() {
                return None;
            }
            let document = CGPDFDocumentCreateWithProvider(provider);
            CGDataProviderRelease(provider);
            if document.is_null() {
                return None;
            }
            let out = draw(document, width, height);
            CGPDFDocumentRelease(document);
            out
        }
    }

    unsafe fn draw(document: Ref, width: u32, height: u32) -> Option<PdfPreview> {
        // SAFETY: as `first_page`: the document is open, the page is owned
        // by it, and the bitmap's buffer outlives its context.
        unsafe {
            let pages = CGPDFDocumentGetNumberOfPages(document);
            if pages == 0 {
                return None;
            }
            let page = CGPDFDocumentGetPage(document, 1);
            if page.is_null() {
                return None;
            }
            let rect = CGPDFPageGetBoxRect(page, CROP_BOX);
            let rotation = CGPDFPageGetRotationAngle(page).rem_euclid(360);
            let rotated = rotation % 180 == 90;
            let (pw, ph) = if rotated {
                (rect.size.height, rect.size.width)
            } else {
                (rect.size.width, rect.size.height)
            };
            if pw <= 0. || ph <= 0. {
                return None;
            }
            let aspect = (pw / ph) as f32;
            // The whole page at `width`; the bitmap keeps its top.
            let w = width as usize;
            let page_h = (f64::from(width) / pw * ph).round().max(1.);
            let h = (page_h as usize).min(height as usize).max(1);
            let stride = w * 4;
            let mut buffer = vec![0u8; stride * h];
            let space = CGColorSpaceCreateDeviceRGB();
            let context =
                CGBitmapContextCreate(buffer.as_mut_ptr().cast(), w, h, 8, stride, space, BGRA);
            CGColorSpaceRelease(space);
            if context.is_null() {
                return None;
            }
            let all = CGRect {
                origin: CGPoint { x: 0., y: 0. },
                size: CGSize {
                    width: w as f64,
                    height: h as f64,
                },
            };
            CGContextSetRGBFillColor(context, 1., 1., 1., 1.);
            CGContextFillRect(context, all);
            // Quartz's origin is the bottom left: the page is turned as it
            // asks, scaled to the width (up as well as down, which Quartz's
            // own drawing transform never does) and set so that its top
            // meets the bitmap's.
            let transform =
                page_transform(rect, rotation, f64::from(width) / pw, h as f64 - page_h);
            CGContextConcatCTM(context, transform);
            CGContextDrawPDFPage(context, page);
            CGContextRelease(context);
            let image = image::RgbaImage::from_raw(w as u32, h as u32, buffer)?;
            Some(PdfPreview {
                page: Arc::new(RenderImage::new(vec![image::Frame::new(image)])),
                aspect,
                pages,
            })
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn server() -> ServerOrigin {
        ServerOrigin {
            id: "acct-1".into(),
            url: "https://owui.example.test:8443/".into(),
        }
    }

    #[test]
    fn links_are_told_apart_by_where_they_point() {
        let s = server();
        assert_eq!(
            classify("data:image/png;base64,AA", Some(&s)),
            LinkTarget::Inline
        );
        let file = LinkTarget::ServerFile(FileRef {
            server_id: "acct-1".into(),
            file_id: "f-42".into(),
        });
        assert_eq!(classify("/api/v1/files/f-42/content", Some(&s)), file);
        assert_eq!(classify("/api/v1/files/f-42", Some(&s)), file);
        assert_eq!(
            classify(
                "https://OWUI.example.test:8443/api/v1/files/f-42/content",
                Some(&s)
            ),
            file
        );
        assert_eq!(
            classify("/static/logo.png", Some(&s)),
            LinkTarget::Server("https://owui.example.test:8443/static/logo.png".into())
        );
        // Another port, scheme or host is another site.
        assert_eq!(
            classify("https://owui.example.test/api/v1/files/f-42", Some(&s)),
            LinkTarget::Remote {
                url: "https://owui.example.test/api/v1/files/f-42".into(),
                host: "owui.example.test".into()
            }
        );
        assert_eq!(
            classify("https://Pictures.Example.org./tide.png", Some(&s)),
            LinkTarget::Remote {
                url: "https://pictures.example.org./tide.png".into(),
                host: "pictures.example.org".into()
            }
        );
        // No server to resolve a path against; other schemes; credentials.
        assert_eq!(classify("/static/logo.png", None), LinkTarget::Unsupported);
        assert_eq!(
            classify("file:///etc/hosts", Some(&s)),
            LinkTarget::Unsupported
        );
        assert_eq!(
            classify("javascript:alert(1)", Some(&s)),
            LinkTarget::Unsupported
        );
        assert_eq!(
            classify("https://me:pw@example.org/a.png", Some(&s)),
            LinkTarget::Unsupported
        );
        assert_eq!(classify("tide.png", Some(&s)), LinkTarget::Unsupported);
    }

    /// A PNG chunk, its CRC right.
    fn png_chunk(kind: &[u8], data: &[u8]) -> Vec<u8> {
        let mut body = kind.to_vec();
        body.extend_from_slice(data);
        let mut crc = 0xFFFF_FFFFu32;
        for b in &body {
            crc ^= u32::from(*b);
            for _ in 0..8 {
                crc = if crc & 1 != 0 {
                    (crc >> 1) ^ 0xEDB8_8320
                } else {
                    crc >> 1
                };
            }
        }
        let mut out = (data.len() as u32).to_be_bytes().to_vec();
        out.extend_from_slice(&body);
        out.extend_from_slice(&(!crc).to_be_bytes());
        out
    }

    /// A PNG's signature, header (`w` × `h`) and the start of its data:
    /// what a decoder reads to tell its size.
    fn png_header(w: u32, h: u32) -> Vec<u8> {
        let mut ihdr = w.to_be_bytes().to_vec();
        ihdr.extend_from_slice(&h.to_be_bytes());
        ihdr.extend_from_slice(&[8, 2, 0, 0, 0]);
        let mut out = b"\x89PNG\r\n\x1a\n".to_vec();
        out.extend(png_chunk(b"IHDR", &ihdr));
        out.extend(png_chunk(b"IDAT", &[0x78, 0x9c]));
        out
    }

    #[test]
    fn pictures_that_unpack_too_large_are_refused_by_their_header() {
        assert!(too_many_pixels(&png_header(30_000, 30_000)));
        assert!(!too_many_pixels(&png_header(480, 240)));
        assert!(!too_many_pixels(b"<svg/>"));
    }

    #[test]
    fn hosts_are_kept_in_one_spelling() {
        assert_eq!(
            normalize_host(" Pictures.Example.ORG. "),
            "pictures.example.org"
        );
        assert_eq!(normalize_host("127.0.0.1"), "127.0.0.1");
    }

    #[test]
    fn media_errors_follow_the_daemons_codes() {
        let e = |code: &str| conduit_daemon::protocol::error(code, "x");
        assert_eq!(MediaError::of(&e("media.tooLarge")), MediaError::TooLarge);
        assert_eq!(MediaError::of(&e("media.wrongType")), MediaError::WrongType);
        assert_eq!(MediaError::of(&e("media.timedOut")), MediaError::TimedOut);
        assert_eq!(MediaError::of(&e("http")), MediaError::Failed);
    }

    /// A synthetic one-page PDF, 200 × 100 points, black on its top half.
    pub fn tiny_pdf() -> Vec<u8> {
        let content = "0 0 0 rg 0 50 200 50 re f";
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>".to_string(),
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>".to_string(),
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 100] /Contents 4 0 R >>".to_string(),
            format!(
                "<< /Length {} >>\nstream\n{content}\nendstream",
                content.len()
            ),
        ];
        let mut out = String::from("%PDF-1.4\n");
        let mut offsets = vec![];
        for (i, body) in objects.iter().enumerate() {
            offsets.push(out.len());
            out.push_str(&format!("{} 0 obj\n{body}\nendobj\n", i + 1));
        }
        let xref = out.len();
        out.push_str(&format!(
            "xref\n0 {}\n0000000000 65535 f \n",
            objects.len() + 1
        ));
        for o in offsets {
            out.push_str(&format!("{o:010} 00000 n \n"));
        }
        out.push_str(&format!(
            "trailer\n<< /Size {} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n",
            objects.len() + 1
        ));
        out.into_bytes()
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn a_pdf_card_shows_the_top_of_its_first_page_and_counts_pages() {
        let preview = pdf_thumbnail(&tiny_pdf(), 400, 120).expect("Quartz opens it");
        assert_eq!(preview.pages, 1);
        assert!((preview.aspect - 2.).abs() < 0.01, "{}", preview.aspect);
        let size = preview.page.size(0);
        // 400 wide: the page is 200 tall there, cut at the card's 120.
        assert_eq!((size.width.0, size.height.0), (400, 120));
        let bytes = preview.page.as_bytes(0).unwrap();
        // The top rows are the black half (BGRA), the bottom rows white.
        assert!(bytes[..3].iter().all(|b| *b < 40), "{:?}", &bytes[..4]);
        let last = bytes.len() - 4;
        assert!(bytes[last..last + 3].iter().all(|b| *b > 200));
        assert!(pdf_thumbnail(b"%PDF-not really", 400, 120).is_none());
        assert!(pdf_thumbnail(b"", 400, 120).is_none());
    }
}
