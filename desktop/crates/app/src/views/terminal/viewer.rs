//! Showing a terminal's file, as mobile's preview dialog does: text in a
//! sheet (with Copy and Download…), a picture in the app's image viewer, a
//! PDF in PDFKit's viewer at the page asked for ([`super::pdf`]), video and
//! audio in Quick Look, and when nothing can show it, mobile's "Preview
//! unavailable. Use Download instead."
//!
//! A model's `display_file` (`terminal.displayFile`) opens the same, a PDF
//! at the page the model names.

use std::rc::Rc;
use std::sync::Arc;

use base64::Engine as _;
use conduit_components::ActiveConduitTheme as _;
use conduit_components::theme::MONO_FONT;
use conduit_components::views::kit::Button;
use conduit_protocol::{TerminalFileContent, TerminalPath, methods};
use gpui_kit::prelude::*;
use gpui_kit::{
    AnyElement, App, ClipboardItem, Context, FocusHandle, Role, SharedString, Window, div, px,
};

use super::files;
use crate::l10n::ActiveL10n as _;
use crate::stores::Stores;
use crate::views::sheet::{self, SheetBody};

/// What a read file is shown as.
#[derive(Clone, Debug, PartialEq)]
pub enum Shown {
    Text(String),
    Image,
    /// A PDF: bytes for PDFKit's viewer.
    Pdf,
    /// Video and audio: bytes for Quick Look.
    Document,
    Unavailable,
}

/// How `content` shows.
pub fn shown(content: &TerminalFileContent) -> Shown {
    let kind = content
        .content_type
        .split(';')
        .next()
        .unwrap_or_default()
        .trim()
        .to_ascii_lowercase();
    if let Some(text) = &content.text {
        return Shown::Text(text.clone());
    }
    if content.base64.is_none() {
        return Shown::Unavailable;
    }
    if kind.starts_with("image/") {
        Shown::Image
    } else if kind == "application/pdf" {
        Shown::Pdf
    } else if kind.starts_with("video/") || kind.starts_with("audio/") {
        Shown::Document
    } else {
        Shown::Unavailable
    }
}

/// Reads `path` through `handle` and shows it. `page` is where a PDF
/// opens (1-based; the first when none).
pub fn show(
    stores: Stores,
    handle: String,
    path: String,
    page: Option<i64>,
    window: &mut Window,
    cx: &mut App,
) {
    let rpc = stores.connection.read(cx).rpc();
    let call = rpc.call::<methods::TerminalRead>(&TerminalPath {
        handle: handle.clone(),
        path: path.clone(),
    });
    let window_handle = window.window_handle();
    cx.spawn(async move |cx| {
        let content = match call.await {
            Ok(content) => content,
            Err(e) => {
                log::warn!("terminal.read: {e}");
                cx.update(|cx| {
                    let text = cx.l10n().terminal_failed_to_load_files();
                    stores.toasts.update(cx, |t, cx| {
                        t.show(conduit_protocol::NoticeLevel::Error, text, cx)
                    });
                });
                return;
            }
        };
        let name = if content.name.is_empty() {
            path.rsplit('/').next().unwrap_or_default().to_string()
        } else {
            content.name.clone()
        };
        let bytes = content
            .base64
            .as_deref()
            .and_then(|b| base64::engine::general_purpose::STANDARD.decode(b).ok());
        match shown(&content) {
            Shown::Image => {
                let Some(bytes) = bytes else { return };
                cx.update(|cx| {
                    let format = crate::stores::files::image_format(&content.content_type, &bytes)
                        .unwrap_or(gpui_kit::ImageFormat::Png);
                    let image = Arc::new(gpui_kit::Image::from_bytes(format, bytes));
                    crate::views::image_viewer::open(
                        vec![crate::views::image_viewer::ViewerImage::Data { image, name }],
                        0,
                        cx,
                    );
                });
            }
            Shown::Pdf => {
                let Some(bytes) = bytes else { return };
                let opened = cx.update(|cx| super::pdf::open(bytes, name.clone(), page, cx));
                if !opened {
                    // PDFKit could not read it: as for any file with no
                    // preview.
                    let _ = window_handle.update(cx, |_, window, cx| {
                        sheet::open(window, 640., cx, move |window, cx| {
                            FileSheet::new(stores, handle, path, name, None, window, cx)
                        });
                    });
                }
            }
            Shown::Document => {
                let Some(bytes) = bytes else { return };
                let staged =
                    cx.update(|cx| crate::stores::files::stage_bytes(bytes, &handle, &name, cx));
                match staged {
                    Ok(staged) => {
                        let _ = std::process::Command::new("/usr/bin/qlmanage")
                            .arg("-p")
                            .arg(&staged)
                            .stdout(std::process::Stdio::null())
                            .stderr(std::process::Stdio::null())
                            .spawn();
                    }
                    Err(e) => log::warn!("terminal file staging: {e}"),
                }
            }
            shown => {
                let text = match shown {
                    Shown::Text(text) => Some(text),
                    _ => None,
                };
                let _ = window_handle.update(cx, |_, window, cx| {
                    sheet::open(window, 640., cx, move |window, cx| {
                        FileSheet::new(stores, handle, path, name, text, window, cx)
                    });
                });
            }
        }
    })
    .detach();
}

/// A text file (or one with no preview) in a sheet.
pub struct FileSheet {
    stores: Stores,
    handle: String,
    path: String,
    name: String,
    text: Option<String>,
    copied: bool,
    focus: FocusHandle,
}

impl FileSheet {
    fn new(
        stores: Stores,
        handle: String,
        path: String,
        name: String,
        text: Option<String>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Self {
        let focus = cx.focus_handle();
        window.focus(&focus, cx);
        Self {
            stores,
            handle,
            path,
            name,
            text,
            copied: false,
            focus,
        }
    }

    pub fn name(&self) -> &str {
        &self.name
    }

    pub fn text(&self) -> Option<&str> {
        self.text.as_deref()
    }

    fn done(&mut self, cx: &mut Context<Self>) {
        cx.defer(|cx| {
            if sheet::current::<FileSheet>(cx).is_some() {
                sheet::dismiss(cx);
            }
        });
    }
}

impl SheetBody for FileSheet {
    fn cancel(&mut self, _: &mut Window, cx: &mut Context<Self>) {
        self.done(cx);
    }

    fn label(&self, _: &App) -> SharedString {
        SharedString::from(self.name.clone())
    }

    fn footer(&mut self, _: &mut Window, cx: &mut Context<Self>) -> Option<AnyElement> {
        let l = cx.l10n().clone();
        let view = cx.entity().downgrade();
        let done = Button::new("terminal-file-done", l.done())
            .primary()
            .on_click(Rc::new({
                let view = view.clone();
                move |_, _, cx| {
                    view.update(cx, |v, cx| v.done(cx)).ok();
                }
            }));
        let download = Button::new(
            "terminal-file-download",
            format!("{}\u{2026}", l.download()),
        )
        .on_click(Rc::new({
            let view = view.clone();
            move |_, _, cx| {
                let Some((stores, handle, path)) = view
                    .update(cx, |v, cx| {
                        v.done(cx);
                        (v.stores.clone(), v.handle.clone(), v.path.clone())
                    })
                    .ok()
                else {
                    return;
                };
                files::download(stores, handle, path, cx);
            }
        }));
        let copy = self.text.as_ref().map(|_| {
            Button::new(
                "terminal-file-copy",
                if self.copied {
                    l.desktop_copied()
                } else {
                    l.copy()
                },
            )
            .on_click(Rc::new(move |_, _, cx| {
                view.update(cx, |v, cx| {
                    if let Some(text) = &v.text {
                        cx.write_to_clipboard(ClipboardItem::new_string(text.clone()));
                        v.copied = true;
                        cx.notify();
                    }
                })
                .ok();
            }))
        });
        Some(
            div()
                .w_full()
                .flex()
                .items_center()
                .gap(px(8.))
                .child(div().flex_1())
                .children(copy)
                .child(download)
                .child(done)
                .into_any_element(),
        )
    }
}

impl Render for FileSheet {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let t = cx.conduit().clone();
        let r = t.roles;
        let m = t.metrics;
        let l = cx.l10n().clone();
        let body = match &self.text {
            Some(text) => div()
                .id("terminal-file-text")
                .role(Role::Document)
                .aria_label(SharedString::from(self.name.clone()))
                .max_h(px(420.))
                .overflow_y_scroll()
                .p(px(12.))
                .rounded(px(8.))
                .border_1()
                .border_color(r.border)
                .bg(conduit_components::views::kit::field_fill(&t))
                .font_family(MONO_FONT)
                .text_size(px(m.small))
                .text_color(r.text)
                .children(text.lines().map(|line| {
                    div()
                        .min_h(px(m.small * 1.4))
                        .child(SharedString::from(line.to_string()))
                }))
                .into_any_element(),
            None => div()
                .id("terminal-file-unavailable")
                .role(Role::Status)
                .text_size(px(m.control))
                .text_color(r.text_subtle)
                .child(SharedString::from(l.terminal_preview_unavailable()))
                .into_any_element(),
        };
        div()
            .id("terminal-file-sheet")
            .track_focus(&self.focus)
            .flex()
            .flex_col()
            .gap(px(12.))
            .child(
                div()
                    .id("terminal-file-title")
                    .role(Role::Heading)
                    .text_size(px(m.body + 2.))
                    .font_weight(gpui_kit::FontWeight::SEMIBOLD)
                    .text_color(r.text)
                    .truncate()
                    .child(SharedString::from(self.name.clone())),
            )
            .child(
                div()
                    .text_size(px(m.small))
                    .font_family(MONO_FONT)
                    .text_color(r.text_subtle)
                    .truncate()
                    .child(SharedString::from(self.path.clone())),
            )
            .child(body)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn content(kind: &str, text: Option<&str>, b64: Option<&str>) -> TerminalFileContent {
        TerminalFileContent {
            name: "f".into(),
            content_type: kind.into(),
            text: text.map(Into::into),
            base64: b64.map(Into::into),
        }
    }

    #[test]
    fn files_show_by_kind() {
        assert_eq!(
            shown(&content("text/plain", Some("hi"), None)),
            Shown::Text("hi".into())
        );
        assert_eq!(
            shown(&content("image/png", None, Some("iVBO"))),
            Shown::Image
        );
        assert_eq!(
            shown(&content("application/pdf; x=y", None, Some("JVBE"))),
            Shown::Pdf
        );
        assert_eq!(
            shown(&content("video/mp4", None, Some("AAAA"))),
            Shown::Document
        );
        assert_eq!(
            shown(&content("application/zip", None, Some("UEsD"))),
            Shown::Unavailable
        );
        assert_eq!(
            shown(&content("application/zip", None, None)),
            Shown::Unavailable
        );
    }
}
