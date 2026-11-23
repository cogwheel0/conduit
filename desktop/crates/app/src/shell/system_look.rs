//! What Windows and Linux say about the app's look: the accent colour
//! (Windows' accent; the desktop portal's `accent-color`), Reduce Motion
//! (Windows' animation effects off; the portal's `reduced-motion`, else
//! GNOME's `enable-animations`) and, on Linux, the fonts fontconfig names
//! for `sans-serif` and `monospace`. The Mac reads its own
//! (`conduit_components::window::macos`, [`super::reduce_motion`]).
//!
//! Windows' values are read at start-up; Linux follows the portal's
//! changes.

use gpui_kit::{Hsla, Rgba};

/// Windows' accent colour as the DWM keeps it (`AccentColor`, 0xAABBGGRR).
pub fn accent_from_abgr(abgr: u32) -> Hsla {
    let channel = |shift: u32| ((abgr >> shift) & 0xff) as f32 / 255.;
    Rgba {
        r: channel(0),
        g: channel(8),
        b: channel(16),
        a: 1.,
    }
    .into()
}

/// The portal's accent: red, green and blue from 0 to 1. A value outside
/// that range means the user chose none.
pub fn accent_from_portal(red: f64, green: f64, blue: f64) -> Option<Hsla> {
    let unit = |v: f64| (0.0..=1.0).contains(&v);
    (unit(red) && unit(green) && unit(blue)).then(|| {
        Rgba {
            r: red as f32,
            g: green as f32,
            b: blue as f32,
            a: 1.,
        }
        .into()
    })
}

/// Picks the UI and code fonts from the installed families (Windows and
/// Linux), before the first window draws.
#[cfg(not(target_os = "macos"))]
pub fn resolve_fonts(cx: &gpui_kit::App) {
    use conduit_components::theme::{FontSystem, resolve_fonts};
    let installed = cx.text_system().all_font_names();
    #[cfg(target_os = "windows")]
    let system = FontSystem::Windows;
    #[cfg(not(target_os = "windows"))]
    let system = FontSystem::Linux {
        sans: fontconfig_family("sans-serif"),
        mono: fontconfig_family("monospace"),
    };
    resolve_fonts(system, &installed);
}

/// The family fontconfig gives `generic`, if `fc-match` answers.
#[cfg(all(not(target_os = "macos"), not(target_os = "windows")))]
fn fontconfig_family(generic: &str) -> Option<String> {
    let out = std::process::Command::new("fc-match")
        .args(["--format=%{family[0]}", generic])
        .output()
        .ok()?;
    let name = String::from_utf8(out.stdout).ok()?.trim().to_string();
    (out.status.success() && !name.is_empty()).then_some(name)
}

/// Reads the OS accent into the theme (Windows at once; Linux when the
/// portal answers, and again when it changes), and re-applies the settings
/// so the theme takes it.
#[cfg(not(target_os = "macos"))]
pub fn follow_accent(
    settings: gpui_kit::Entity<crate::stores::settings::SettingsStore>,
    cx: &mut gpui_kit::App,
) {
    #[cfg(target_os = "windows")]
    {
        conduit_components::window::set_os_accent(windows::accent());
        settings.update(cx, |s, cx| s.apply(cx));
    }
    #[cfg(not(target_os = "windows"))]
    {
        let (tx, mut rx) = futures::channel::mpsc::unbounded::<Option<Hsla>>();
        cx.background_executor()
            .spawn(async move {
                if let Err(e) = portal::accents(tx).await {
                    log::info!("no accent from the desktop portal: {e}");
                }
            })
            .detach();
        cx.spawn(async move |cx| {
            use futures::StreamExt as _;
            while let Some(accent) = rx.next().await {
                conduit_components::window::set_os_accent(accent);
                cx.update(|cx| settings.update(cx, |s, cx| s.apply(cx)));
            }
        })
        .detach();
    }
}

/// Follows the OS's Reduce Motion (Windows: read once; Linux: the portal,
/// and its changes).
#[cfg(not(target_os = "macos"))]
pub fn follow_reduce_motion(cx: &mut gpui_kit::App) {
    #[cfg(target_os = "windows")]
    cx.set_reduce_motion(windows::reduce_motion());
    #[cfg(not(target_os = "windows"))]
    {
        let (tx, mut rx) = futures::channel::mpsc::unbounded::<bool>();
        cx.background_executor()
            .spawn(async move {
                if let Err(e) = portal::reduce_motion(tx).await {
                    log::info!("no Reduce Motion from the desktop portal: {e}");
                }
            })
            .detach();
        cx.spawn(async move |cx| {
            use futures::StreamExt as _;
            while let Some(on) = rx.next().await {
                cx.update(|cx| cx.set_reduce_motion(on));
            }
        })
        .detach();
    }
}

#[cfg(target_os = "windows")]
mod windows {
    use ::windows::Win32::System::Registry::{HKEY_CURRENT_USER, RRF_RT_REG_DWORD, RegGetValueW};
    use ::windows::Win32::UI::WindowsAndMessaging::{
        SPI_GETCLIENTAREAANIMATION, SYSTEM_PARAMETERS_INFO_UPDATE_FLAGS, SystemParametersInfoW,
    };
    use ::windows::core::{BOOL, w};
    use gpui_kit::Hsla;

    /// Settings › Personalization › Colors › Accent colour.
    pub fn accent() -> Option<Hsla> {
        let mut value = 0u32;
        let mut size = std::mem::size_of::<u32>() as u32;
        // SAFETY: a DWORD value read into a DWORD of the size given.
        unsafe {
            RegGetValueW(
                HKEY_CURRENT_USER,
                w!("Software\\Microsoft\\Windows\\DWM"),
                w!("AccentColor"),
                RRF_RT_REG_DWORD,
                None,
                Some(std::ptr::from_mut(&mut value).cast()),
                Some(std::ptr::from_mut(&mut size)),
            )
        }
        .ok()
        .ok()?;
        Some(super::accent_from_abgr(value))
    }

    /// Settings › Accessibility › Visual effects › Animation effects, off.
    pub fn reduce_motion() -> bool {
        let mut animate = BOOL(1);
        // SAFETY: SPI_GETCLIENTAREAANIMATION writes one BOOL.
        let read = unsafe {
            SystemParametersInfoW(
                SPI_GETCLIENTAREAANIMATION,
                0,
                Some(std::ptr::from_mut(&mut animate).cast()),
                SYSTEM_PARAMETERS_INFO_UPDATE_FLAGS(0),
            )
        };
        read.is_ok() && !animate.as_bool()
    }
}

#[cfg(all(not(target_os = "macos"), not(target_os = "windows")))]
mod portal {
    use ashpd::desktop::settings::{ReducedMotion, Settings};
    use futures::StreamExt as _;
    use futures::channel::mpsc::UnboundedSender;
    use gpui_kit::Hsla;

    /// Sends the accent now and on each change; returns when the portal
    /// has none or the app stops listening. The change stream is taken
    /// before the first read, so a change between them is not missed.
    pub async fn accents(tx: UnboundedSender<Option<Hsla>>) -> ashpd::Result<()> {
        let settings = Settings::new().await?;
        let read =
            |c: ashpd::desktop::Color| super::accent_from_portal(c.red(), c.green(), c.blue());
        let changed = settings.receive_accent_color_changed().await;
        let now = settings.accent_color().await.ok().and_then(read);
        super::follow(now, changed.map(|c| c.map(read)), &tx).await
    }

    /// Sends Reduce Motion now and on each change: the portal's own
    /// setting, else GNOME's `enable-animations` through it. Each change
    /// stream is taken before its first read.
    pub async fn reduce_motion(tx: UnboundedSender<bool>) -> ashpd::Result<()> {
        const GNOME: (&str, &str) = ("org.gnome.desktop.interface", "enable-animations");
        let settings = Settings::new().await?;
        let changed = settings.receive_reduced_motion_changed().await;
        match settings.reduced_motion().await {
            Ok(motion) => {
                let reduced = |m: ReducedMotion| m == ReducedMotion::ReducedMotion;
                super::follow(reduced(motion), changed.map(|c| c.map(reduced)), &tx).await
            }
            Err(_) => {
                let changed = settings
                    .receive_setting_changed_with_args::<bool>(GNOME.0, GNOME.1)
                    .await;
                let animate: bool = settings.read(GNOME.0, GNOME.1).await?;
                let changed = changed.map(|c| c.filter_map(|animate| async move { animate.ok() }));
                super::follow_animations(animate, changed, &tx).await
            }
        }
    }
}

/// Sends `now`, then each value `changes` brings, until the app stops
/// listening. `now` goes first even when the changes can't be followed.
#[cfg(any(test, all(not(target_os = "macos"), not(target_os = "windows"))))]
async fn follow<T, E>(
    now: T,
    changes: Result<impl futures::Stream<Item = T>, E>,
    tx: &futures::channel::mpsc::UnboundedSender<T>,
) -> Result<(), E> {
    use futures::StreamExt as _;
    if tx.unbounded_send(now).is_err() {
        return Ok(());
    }
    let mut changes = std::pin::pin!(changes?);
    while let Some(value) = changes.next().await {
        if tx.unbounded_send(value).is_err() {
            break;
        }
    }
    Ok(())
}

/// GNOME's `enable-animations` (read, then each change) as Reduce Motion.
#[cfg(any(test, all(not(target_os = "macos"), not(target_os = "windows"))))]
async fn follow_animations<E>(
    animate: bool,
    changes: Result<impl futures::Stream<Item = bool>, E>,
    tx: &futures::channel::mpsc::UnboundedSender<bool>,
) -> Result<(), E> {
    use futures::StreamExt as _;
    follow(!animate, changes.map(|c| c.map(|animate| !animate)), tx).await
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rgb(c: Hsla) -> (u8, u8, u8) {
        let c = Rgba::from(c);
        let byte = |v: f32| (v * 255.).round() as u8;
        (byte(c.r), byte(c.g), byte(c.b))
    }

    /// Windows keeps its accent as 0xAABBGGRR.
    #[test]
    fn windows_accent_reads_blue_green_red() {
        assert_eq!(rgb(accent_from_abgr(0xff_d7_78_00)), (0x00, 0x78, 0xd7));
        assert_eq!(rgb(accent_from_abgr(0xff_00_00_ff)), (0xff, 0x00, 0x00));
    }

    /// Without the portal's Reduce Motion, GNOME's `enable-animations` is
    /// followed, not only read: each change reaches the app, inverted.
    #[test]
    fn gnomes_animations_setting_is_followed() {
        let (tx, rx) = futures::channel::mpsc::unbounded();
        let changes = Ok::<_, ()>(futures::stream::iter([false, true]));
        futures::executor::block_on(follow_animations(true, changes, &tx)).unwrap();
        drop(tx);
        let sent: Vec<bool> = futures::executor::block_on(futures::StreamExt::collect(rx));
        assert_eq!(sent, [false, true, false]);
        // The value read goes out even when its changes can't be followed.
        let (tx, rx) = futures::channel::mpsc::unbounded();
        let failed = Err::<futures::stream::Empty<bool>, _>("no stream");
        assert_eq!(
            futures::executor::block_on(follow(true, failed, &tx)),
            Err("no stream")
        );
        drop(tx);
        let sent: Vec<bool> = futures::executor::block_on(futures::StreamExt::collect(rx));
        assert_eq!(sent, [true]);
    }

    /// The portal's accent is three fractions; any outside 0 to 1 means
    /// none was chosen.
    #[test]
    fn the_portals_accent_is_three_fractions() {
        assert_eq!(
            accent_from_portal(0.2, 0.4, 1.0).map(rgb),
            Some((51, 102, 255))
        );
        assert_eq!(accent_from_portal(-1., -1., -1.), None);
        assert_eq!(accent_from_portal(0.5, 2.0, 0.5), None);
    }
}
