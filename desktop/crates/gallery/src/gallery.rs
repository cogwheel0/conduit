//! The gallery itself: macOS only (AppKit windows, CGWindowList capture).

use std::path::{Path, PathBuf};
use std::time::Duration;

use conduit_components::assets::ConduitAssets;
use conduit_components::capture;
use conduit_components::theme::{self, ConduitTheme, DesignPrefs, VARIANT_KEYS};
use conduit_components::window::{self as cw, Material};
use gpui_kit::prelude::*;
use gpui_kit::{
    AnyWindowHandle, App, AsyncApp, Bounds, Context, SharedString, Window,
    WindowBackgroundAppearance, WindowBounds, WindowOptions, div, linear_color_stop,
    linear_gradient, point, px, rgb, size,
};
use serde::Serialize;

use crate::screens::{Frame, Screen};
use crate::{a11y, views};

/// The coloured palette shown next to Conduit: Catppuccin's lavender primary
/// and tinted greys show contrast decisions the monochrome palette hides.
const COLOURED_PALETTE: &str = "catppuccin";
/// How long a fresh window gets to lay out, paint and composite its
/// materials before capture.
const SETTLE: Duration = Duration::from_millis(900);
/// Desktop margin captured around a window (shows its shadow and the
/// material's backdrop).
const MARGIN: f64 = 28.;
/// Where screens open (top-left, points). The backdrop covers all of them.
const ORIGIN: (f32, f32) = (120., 96.);

#[derive(Clone, Debug)]
struct Job {
    screen: Screen,
    dark: bool,
    palette: String,
    prefs: DesignPrefs,
    out: PathBuf,
}

#[derive(Serialize)]
struct IndexEntry {
    file: String,
    screen: String,
    number: u8,
    mode: &'static str,
    palette: String,
    variants: serde_json::Map<String, serde_json::Value>,
    /// Keys that differ from the baseline (empty for baseline renders).
    varied: Vec<&'static str>,
    width: usize,
    height: usize,
}

/// `render.sh` cannot see the gallery's exit status through `open`, so
/// every failure prints a FAILED line, which it looks for.
fn usage() -> ! {
    eprintln!("FAILED: bad arguments");
    eprintln!(
        "usage:\n  conduit-gallery --screen <name> [--mode light|dark] [--palette <id>] \
         [--variant k=v,...] --out <png>\n  conduit-gallery --all <dir>\n  conduit-gallery --a11y <screen> [--mode ..] [--palette ..]\n  conduit-gallery --list"
    );
    std::process::exit(64)
}

fn arg(args: &[String], key: &str) -> Option<String> {
    args.iter()
        .position(|a| a == key)
        .and_then(|i| args.get(i + 1))
        .cloned()
}

fn file_name(job: &Job) -> String {
    let varied: Vec<String> = job
        .prefs
        .changed_keys()
        .iter()
        .map(|k| format!("{k}-{}", job.prefs.get(k).unwrap_or("?")))
        .collect();
    format!(
        "{:02}-{}__{}-{}__{}.png",
        job.screen.number(),
        job.screen.name(),
        job.palette,
        if job.dark { "dark" } else { "light" },
        if varied.is_empty() {
            "baseline".to_string()
        } else {
            varied.join("_")
        }
    )
}

/// The `--all` matrix: baselines everywhere, then one key at a time.
fn plan_all(dir: &Path) -> Vec<Job> {
    let mut jobs = vec![];
    let mut push = |screen: Screen, palette: &str, dark: bool, prefs: DesignPrefs| {
        let mut job = Job {
            screen,
            dark,
            palette: palette.to_string(),
            prefs,
            out: PathBuf::new(),
        };
        job.out = dir.join(file_name(&job));
        jobs.push(job);
    };
    for &screen in Screen::ALL {
        for palette in ["conduit", COLOURED_PALETTE] {
            for dark in [false, true] {
                push(screen, palette, dark, DesignPrefs::default());
            }
        }
    }
    for &screen in Screen::ALL {
        for key in screen.variant_keys() {
            let mut prefs = DesignPrefs::default();
            let alt = DesignPrefs::alternate(key).unwrap_or_default();
            if prefs.set(key, alt).is_err() {
                continue;
            }
            // Palette-sensitive keys also render on the coloured palette.
            let palettes: &[&str] = if matches!(*key, "sidebar" | "accent") {
                &["conduit", COLOURED_PALETTE]
            } else {
                &["conduit"]
            };
            for palette in palettes {
                for dark in [false, true] {
                    push(screen, palette, dark, prefs);
                }
            }
        }
    }
    jobs
}

pub fn main() {
    let args: Vec<String> = std::env::args().collect();
    // render.sh launches through `open`, which starts apps in `/`.
    if let Some(dir) = arg(&args, "--cwd") {
        std::env::set_current_dir(dir).ok();
    }
    if args.iter().any(|a| a == "--list") {
        for s in Screen::ALL {
            println!("{:02} {}", s.number(), s.name());
        }
        println!("variants: {}", VARIANT_KEYS.join(", "));
        println!(
            "palettes: {}",
            theme::palettes().ids().collect::<Vec<_>>().join(", ")
        );
        return;
    }
    let dark = arg(&args, "--mode").as_deref() == Some("dark");
    let palette = arg(&args, "--palette").unwrap_or_else(|| "conduit".into());
    let prefs = match DesignPrefs::parse(&arg(&args, "--variant").unwrap_or_default()) {
        Ok(p) => p,
        Err(e) => {
            eprintln!("{e}");
            usage()
        }
    };

    enum Mode {
        Render(Vec<Job>, Option<PathBuf>),
        A11y(Job),
    }
    let mode = if let Some(dir) = arg(&args, "--all") {
        let dir = PathBuf::from(dir);
        if let Err(e) = output_dir(&dir) {
            eprintln!("FAILED: {e}");
            std::process::exit(1);
        }
        // Iteration filters: --only a,b  --palettes conduit  --modes light  --no-variants
        let list =
            |k: &str| arg(&args, k).map(|v| v.split(',').map(str::to_string).collect::<Vec<_>>());
        let (only, palettes, modes) = (list("--only"), list("--palettes"), list("--modes"));
        let no_variants = args.iter().any(|a| a == "--no-variants");
        let jobs = plan_all(&dir)
            .into_iter()
            .filter(|j| {
                only.as_ref()
                    .is_none_or(|o| o.iter().any(|n| n == j.screen.name()))
            })
            .filter(|j| palettes.as_ref().is_none_or(|p| p.contains(&j.palette)))
            .filter(|j| {
                modes
                    .as_ref()
                    .is_none_or(|m| m.iter().any(|x| x == if j.dark { "dark" } else { "light" }))
            })
            .filter(|j| !no_variants || j.prefs.changed_keys().is_empty())
            .collect();
        Mode::Render(jobs, Some(dir))
    } else if let Some(name) = arg(&args, "--a11y") {
        let screen = Screen::by_name(&name).unwrap_or_else(|| usage());
        Mode::A11y(Job {
            screen,
            dark,
            palette,
            prefs,
            out: PathBuf::new(),
        })
    } else {
        let name = arg(&args, "--screen").unwrap_or_else(|| usage());
        let screen = Screen::by_name(&name).unwrap_or_else(|| {
            eprintln!("FAILED: unknown screen {name}; --list shows them");
            std::process::exit(64)
        });
        let out = arg(&args, "--out").unwrap_or_else(|| usage());
        Mode::Render(
            vec![Job {
                screen,
                dark,
                palette,
                prefs,
                out: PathBuf::from(out),
            }],
            None,
        )
    };

    gpui_kit::application()
        .with_assets(ConduitAssets)
        .run(move |cx: &mut App| {
            gpui_kit::init(cx);
            conduit_components::views::markdown::preload_grammars(&["python", "rust", "bash"]);
            let accent = cw::system_accent_color();
            theme::install(
                ConduitTheme::new("conduit", false, DesignPrefs::default(), accent),
                cx,
            );
            let backdrop = open_backdrop(cx);
            cx.activate(true);
            match mode {
                Mode::Render(jobs, index_dir) => {
                    cx.spawn(async move |cx: &mut AsyncApp| {
                        let mut index = vec![];
                        let total = jobs.len();
                        let mut failures = 0;
                        for (n, job) in jobs.into_iter().enumerate() {
                            match render_job(&job, accent, backdrop, cx).await {
                                Ok((w, h)) => {
                                    eprintln!("[{}/{total}] {}", n + 1, job.out.display());
                                    index.push(index_entry(&job, w, h));
                                }
                                Err(e) => {
                                    failures += 1;
                                    eprintln!(
                                        "[{}/{total}] FAILED {}: {e}",
                                        n + 1,
                                        job.out.display()
                                    );
                                }
                            }
                        }
                        if let Some(dir) = index_dir {
                            let path = dir.join("index.json");
                            match write_index(&path, &index) {
                                Ok(()) => eprintln!("wrote {}", path.display()),
                                Err(e) => {
                                    failures += 1;
                                    eprintln!("FAILED {}: {e}", path.display());
                                }
                            }
                        }
                        cx.update(|cx| cx.quit());
                        if failures > 0 {
                            std::process::exit(1);
                        }
                    })
                    .detach();
                }
                Mode::A11y(job) => {
                    cx.spawn(async move |cx: &mut AsyncApp| {
                        let report = a11y_job(&job, accent, cx).await;
                        println!(
                            "{}",
                            serde_json::to_string_pretty(&report).unwrap_or_default()
                        );
                        let ok = report.passed();
                        if !ok {
                            eprintln!("FAILED: accessibility check");
                        }
                        cx.update(|cx| cx.quit());
                        std::process::exit(if ok { 0 } else { 1 });
                    })
                    .detach();
                }
            }
        });
}

fn index_entry(job: &Job, width: usize, height: usize) -> IndexEntry {
    let mut variants = serde_json::Map::new();
    for key in VARIANT_KEYS {
        variants.insert(
            key.to_string(),
            serde_json::Value::String(job.prefs.get(key).unwrap_or("?").to_string()),
        );
    }
    IndexEntry {
        file: job
            .out
            .file_name()
            .map(|f| f.to_string_lossy().to_string())
            .unwrap_or_default(),
        screen: job.screen.name().to_string(),
        number: job.screen.number(),
        mode: if job.dark { "dark" } else { "light" },
        palette: job.palette.clone(),
        variants,
        varied: job.prefs.changed_keys(),
        width,
        height,
    }
}

/// A synthetic desktop wallpaper behind every screen, so materials have
/// something to blur.
struct Backdrop;

impl Render for Backdrop {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let dark = cx.global::<ConduitTheme>().dark;
        let (a, b, c) = if dark {
            (0x1d2a4a, 0x3b2a52, 0x16323a)
        } else {
            (0x9fb8e6, 0xe7c3c9, 0xb9dccf)
        };
        div()
            .size_full()
            .bg(linear_gradient(
                135.,
                linear_color_stop(rgb(a), 0.),
                linear_color_stop(rgb(b), 1.),
            ))
            .child(
                div()
                    .absolute()
                    .left(px(700.))
                    .top(px(380.))
                    .size(px(900.))
                    .rounded_full()
                    .bg(gpui_kit::Hsla::from(rgb(c)).opacity(0.55)),
            )
    }
}

/// Creates `--all`'s output folder (an existing file there, or no write
/// access, is an error the run reports).
fn output_dir(dir: &std::path::Path) -> Result<(), String> {
    std::fs::create_dir_all(dir).map_err(|e| format!("cannot create {}: {e}", dir.display()))
}

/// Writes the run's index of images, as pretty JSON.
fn write_index(path: &std::path::Path, index: &[impl serde::Serialize]) -> Result<(), String> {
    let json = serde_json::to_string_pretty(index).map_err(|e| e.to_string())?;
    std::fs::write(path, json + "\n").map_err(|e| e.to_string())
}

fn open_backdrop(cx: &mut App) -> AnyWindowHandle {
    let bounds = Bounds::new(point(px(40.), px(44.)), size(px(1460.), px(990.)));
    let options = WindowOptions {
        window_bounds: Some(WindowBounds::Windowed(bounds)),
        titlebar: None,
        focus: false,
        is_movable: false,
        window_background: WindowBackgroundAppearance::Opaque,
        ..Default::default()
    };
    let (handle, _) = cw::open_window_clear_root(options, cx, |_, cx| cx.new(|_| Backdrop))
        .expect("open backdrop window");
    handle
        .update(cx, |_, window, _| views::hide_window_buttons(window))
        .ok();
    handle
}

/// Opens `job`'s screen; returns the window and its bounds.
fn open_screen(
    job: &Job,
    cx: &mut App,
) -> gpui_kit::Result<(AnyWindowHandle, Bounds<gpui_kit::Pixels>)> {
    let (w, h) = job.screen.window_size(&job.prefs);
    let frame = job.screen.frame(&job.prefs);
    let origin = match frame {
        Frame::Main { .. } => ORIGIN,
        Frame::Settings => (ORIGIN.0 + 210., ORIGIN.1 + 120.),
        Frame::QuickAsk => (ORIGIN.0 + 280., ORIGIN.1 + 200.),
        Frame::Scene { .. } => (ORIGIN.0 + 260., ORIGIN.1 + 150.),
    };
    let bounds = Bounds::new(point(px(origin.0), px(origin.1)), size(px(w), px(h)));
    let screen = job.screen;
    let handle = match frame {
        Frame::Main { sidebar } => {
            let options = cw::window_options("Conduit", bounds, sidebar, true);
            let (handle, _) = cw::open_window_clear_root(options, cx, move |window, cx| {
                views::build(screen, window, cx)
            })?;
            if sidebar {
                let width = cx.global::<ConduitTheme>().metrics.sidebar_width as f64;
                handle.update(cx, |_, window, _| {
                    cw::macos::add_effect_view(window, Material::Sidebar, Some(width), None)
                })?;
            }
            handle
        }
        Frame::Settings => {
            let material = job.prefs.sidebar == theme::SidebarStyle::Material;
            let options = cw::window_options("Settings", bounds, material, true);
            let (handle, _) = cw::open_window_clear_root(options, cx, move |window, cx| {
                views::build(screen, window, cx)
            })?;
            if material {
                handle.update(cx, |_, window, _| {
                    cw::macos::add_effect_view(
                        window,
                        Material::Sidebar,
                        Some(views::SETTINGS_SIDEBAR as f64),
                        None,
                    )
                })?;
            }
            handle
        }
        Frame::QuickAsk => {
            let options = cw::quick_ask_options(bounds, true);
            let (handle, _) = cw::open_window_clear_root(options, cx, move |window, cx| {
                views::build(screen, window, cx)
            })?;
            handle.update(cx, |_, window, _| {
                views::hide_window_buttons(window);
                cw::macos::add_effect_view(window, Material::HudWindow, None, Some(16.))
            })?;
            handle
        }
        Frame::Scene { .. } => {
            let options = WindowOptions {
                window_bounds: Some(WindowBounds::Windowed(bounds)),
                titlebar: None,
                focus: true,
                window_background: WindowBackgroundAppearance::Opaque,
                ..Default::default()
            };
            let (handle, _) = cw::open_window_clear_root(options, cx, move |window, cx| {
                views::build(screen, window, cx)
            })?;
            handle.update(cx, |_, window, _| views::hide_window_buttons(window))?;
            handle
        }
    };
    Ok((handle, bounds))
}

fn apply_theme(job: &Job, accent: gpui_kit::Hsla, cx: &mut App) {
    cw::macos::set_app_appearance(job.dark);
    theme::install(
        ConduitTheme::new(&job.palette, job.dark, job.prefs, accent),
        cx,
    );
}

async fn render_job(
    job: &Job,
    accent: gpui_kit::Hsla,
    backdrop: AnyWindowHandle,
    cx: &mut AsyncApp,
) -> Result<(usize, usize), String> {
    let (handle, bounds) = cx
        .update(|cx| {
            apply_theme(job, accent, cx);
            backdrop.update(cx, |_, w, _| w.refresh()).ok();
            let opened = open_screen(job, cx);
            if let Ok((handle, _)) = &opened {
                handle
                    .update(cx, |_, w, _| {
                        w.activate_window();
                        views::force_activate(w);
                    })
                    .ok();
            }
            cx.activate(true);
            opened
        })
        .map_err(|e| e.to_string())?;
    // The shot takes the gallery's own windows by id, the screen and the
    // backdrop under it, and nothing else on screen. The backdrop sits
    // directly below the screen, so the screen's materials blur only it.
    let screen_id = cx
        .update(|cx| {
            let id = handle
                .update(cx, |_, w, _| cw::macos::window_number(w))
                .ok()
                .flatten()?;
            backdrop
                .update(cx, |_, w, _| cw::macos::order_below(w, id))
                .ok();
            Some(id)
        })
        .ok_or("the screen window has no number")?;
    let backdrop_id = cx
        .update(|cx| {
            backdrop
                .update(cx, |_, w, _| cw::macos::window_number(w))
                .ok()
                .flatten()
        })
        .ok_or("the backdrop window has no number")?;
    cx.background_executor().timer(SETTLE).await;
    // Where the window is now: it may have moved while it settled.
    let bounds = cx
        .update(|cx| handle.update(cx, |_, w, _| w.bounds()).ok())
        .unwrap_or(bounds);
    let frame = job.screen.frame(&job.prefs);
    let x = f32::from(bounds.origin.x) as f64;
    let y = f32::from(bounds.origin.y) as f64;
    let w = f32::from(bounds.size.width) as f64;
    let h = f32::from(bounds.size.height) as f64;
    let rect = match (job.screen, frame) {
        (_, Frame::Scene { .. }) => capture::CGRect { x, y, w, h },
        (Screen::Sidebar, _) => {
            let sidebar = cx.update(|cx| cx.global::<ConduitTheme>().metrics.sidebar_width) as f64;
            capture::CGRect {
                x: x - MARGIN,
                y: y - MARGIN,
                w: sidebar + 160. + MARGIN,
                h: h + 2. * MARGIN,
            }
        }
        _ => capture::CGRect {
            x: x - MARGIN,
            y: y - MARGIN,
            w: w + 2. * MARGIN,
            h: h + 2. * MARGIN,
        },
    };
    let out = job.out.to_string_lossy().to_string();
    let windows: &[u32] = match frame {
        Frame::Scene { .. } => &[screen_id],
        _ => &[screen_id, backdrop_id],
    };
    let result = capture::capture_windows(windows, Some(rect), &out);
    cx.update(|cx| {
        handle
            .update(cx, |_, window, _| window.remove_window())
            .ok()
    });
    cx.background_executor()
        .timer(Duration::from_millis(120))
        .await;
    result
}

async fn a11y_job(job: &Job, accent: gpui_kit::Hsla, cx: &mut AsyncApp) -> a11y::Report {
    let opened = cx.update(|cx| {
        apply_theme(job, accent, cx);
        open_screen(job, cx)
    });
    let Ok((handle, _)) = opened else {
        return a11y::Report::error(job.screen.name(), "could not open the screen");
    };
    cx.background_executor().timer(SETTLE).await;
    let ptr = cx.update(|cx| {
        handle
            .update(cx, |_, window, _| cw::macos::ns_window_ptr(window))
            .ok()
            .flatten()
    });
    if let Some(ptr) = ptr {
        // SAFETY: the gallery's own live NSWindow, on the main thread.
        unsafe { capture::activate_accessibility(ptr) };
    }
    // Activation forces a redraw; give GPUI frames to send the tree.
    let mut json = None;
    for _ in 0..20 {
        cx.background_executor()
            .timer(Duration::from_millis(150))
            .await;
        cx.update(|cx| {
            handle
                .update(cx, |_, window, _| {
                    window.refresh();
                })
                .ok()
        });
        json = cx.update(|cx| {
            handle
                .update(cx, |_, window, _| window.debug_a11y_tree_json())
                .ok()
                .flatten()
        });
        if json
            .as_ref()
            .is_some_and(|j| j.contains("\"Article\"") || j.contains("\"Button\""))
        {
            break;
        }
    }
    let name: SharedString = job.screen.name().into();
    match json {
        Some(json) => a11y::check(&name, &json),
        None => a11y::Report::error(&name, "no AccessKit tree (accessibility never activated)"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_output_folder_that_cannot_be_made_is_an_error() {
        // A folder inside a file cannot be created.
        let under_a_file = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("Cargo.toml")
            .join("shots");
        let error = output_dir(&under_a_file).unwrap_err();
        assert!(error.contains("shots"), "{error}");
    }

    #[test]
    fn an_index_that_cannot_be_written_is_an_error() {
        let path = std::path::Path::new("/nonexistent-gallery-output/index.json");
        assert!(write_index(path, &[serde_json::json!({"screen": "sign-in"})]).is_err());
    }
}
