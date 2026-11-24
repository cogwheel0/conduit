//! Settings › About › Open Source Licenses: the third-party notices this
//! install carries, opened in the system's plain-text app.
//!
//! Off the Mac, never through the file's default app: Conduit offers Open
//! With for `.md` (a new chat with the file attached), and Windows has no
//! other app for it, nor may a Linux desktop. On the Mac the default app is
//! right: Conduit is only an Alternate handler there (Info.plist).

use std::path::PathBuf;

use gpui_kit::App;

/// Opens `notices` (a file the install carries) in the system's plain-text
/// app: the default app on the Mac, Notepad on Windows, the desktop's app
/// for plain text on Linux. Where none starts, the file manager shows the
/// file instead.
pub fn open(notices: PathBuf, cx: &mut App) {
    #[cfg(target_os = "macos")]
    if let Ok(url) = url::Url::from_file_path(&notices) {
        cx.open_url(url.as_str());
    }
    #[cfg(windows)]
    {
        // The system folder's, never one found on PATH.
        let root = std::env::var_os("SystemRoot").unwrap_or_else(|| "C:\\Windows".into());
        let notepad = std::path::Path::new(&root)
            .join("System32")
            .join("notepad.exe");
        if let Err(e) = std::process::Command::new(&notepad).arg(&notices).spawn() {
            log::warn!("notices: {} didn't start: {e}", notepad.display());
            cx.reveal_path(&notices);
        }
    }
    #[cfg(target_os = "linux")]
    cx.spawn(async move |cx| {
        let file = notices.clone();
        let opened = cx
            .background_executor()
            .spawn(async move { linux::open(&file) })
            .await;
        if let Err(e) = opened {
            log::warn!("notices: {e}");
            cx.update(|cx| cx.reveal_path(&notices));
        }
    })
    .detach();
}

/// Which of `apps` (desktop entry ids: the desktop's default for plain text
/// first, then the others registered for it) opens the notices: the first
/// that isn't Conduit's, in either flavour.
#[cfg(any(target_os = "linux", test))]
fn plain_text_app(apps: &[impl AsRef<str>]) -> Option<usize> {
    use conduit_daemon::paths::Flavor;
    apps.iter().position(|id| {
        let id = id.as_ref().strip_suffix(".desktop").unwrap_or(id.as_ref());
        !id.is_empty()
            && ![Flavor::Production, Flavor::Dev]
                .iter()
                .any(|flavor| id == flavor.desktop_entry())
    })
}

#[cfg(target_os = "linux")]
mod linux {
    use std::path::Path;

    use gio::prelude::*;

    /// Launches the desktop's plain-text app (GIO's choice, as the file
    /// manager's) on `path`, and waits until it has it.
    pub fn open(path: &Path) -> Result<(), String> {
        let apps: Vec<gio::AppInfo> = gio::AppInfo::default_for_type("text/plain", false)
            .into_iter()
            .chain(gio::AppInfo::recommended_for_type("text/plain"))
            .collect();
        let ids: Vec<String> = apps
            .iter()
            .map(|app| app.id().map(|id| id.to_string()).unwrap_or_default())
            .collect();
        let i = super::plain_text_app(&ids).ok_or("no app but Conduit opens plain text")?;
        // The asynchronous launch, run to its end on a main context of this
        // thread's own: the blocking one reports success once a D-Bus
        // activated app's Open is queued, so a failed activation would
        // never reach the fallback.
        let uri = gio::File::for_path(path).uri();
        let context = gio::glib::MainContext::new();
        context
            .with_thread_default(|| {
                context.block_on(
                    apps[i].launch_uris_future(&[uri.as_str()], None::<&gio::AppLaunchContext>),
                )
            })
            .map_err(|e| e.to_string())?
            .map_err(|e| format!("{}: {e}", ids[i]))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_notices_never_open_in_conduit() {
        // The desktop's default for plain text, when it isn't Conduit.
        assert_eq!(
            plain_text_app(&["org.gnome.TextEditor.desktop", "conduit-desktop.desktop"]),
            Some(0)
        );
        // Past Conduit, either flavour's, to the next app for plain text.
        assert_eq!(
            plain_text_app(&[
                "conduit-desktop.desktop",
                "conduit-dev.desktop",
                "vim.desktop"
            ]),
            Some(2)
        );
        // None when only Conduit opens plain text.
        assert_eq!(plain_text_app(&["conduit-desktop.desktop"]), None);
        assert_eq!(plain_text_app(&[] as &[&str]), None);
    }
}
