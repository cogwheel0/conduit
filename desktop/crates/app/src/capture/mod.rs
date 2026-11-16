//! `--capture <dir>`: the design capture (dev tooling, macOS, behind the
//! `harness` feature with `--e2e` and `--fixture`): screenshots of every
//! screen and state, and frames of every transition, for design review.
//!
//! It drives the real app over the real daemon against the local Open
//! WebUI (`tool/local_owui`), from a fresh profile: onboarding, sign-in, the
//! main window, Settings, Quick Ask, Preview and the menu-bar item, and
//! writes
//!
//! * `static/NN-area-state-{light,dark}.png`: every state in both modes;
//! * `interaction/NN-area-state.png`: hover, pressed and focus states,
//!   right-click menus, a drag over a folder, tooltips;
//! * `motion/frames/NN-name/`: frames grabbed during each transition, with
//!   their timing (`hc/compose.py` tiles them into strips);
//! * `notes/keyboard.md` and `notes/inventory.json` (`hc/copy_notes.py`
//!   writes `notes/copy.md`).
//!
//! Shots are in-process captures of this app's own windows over a synthetic
//! backdrop window (no Screen Recording permission). Native menus are real:
//! an open NSMenu is a window of this process, captured from another thread
//! while the main thread sits in its tracking loop, then closed with Escape.
//! Input is synthetic: mouse and key events dispatched into GPUI, and
//! controls found through the window's AccessKit tree, so the real cursor is
//! never moved.
//!
//! `crates/app/hc-capture.sh` runs it end to end.

pub(crate) mod drive;
pub(crate) mod grab;
mod main_pass;
mod motion;
mod notes;
mod onboarding;
mod shell_pass;

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};
use std::sync::mpsc;
use std::time::{Duration, Instant};

use conduit_components::window as cw;
use gpui_kit::prelude::*;
use gpui_kit::{
    AnyWindowHandle, App, AsyncApp, Bounds, Context, Window, WindowBackgroundAppearance,
    WindowBounds, WindowOptions, div, linear_color_stop, linear_gradient, point, px, rgb, size,
};
use objc2::rc::Retained;
use objc2_app_kit::NSWindow;
use serde_json::{Value, json};

use crate::AppState;
use crate::prefs::ThemeMode;
use grab::{CGRect, Frame};

/// Where the main window sits (top-left, screen points) and its sizes.
pub const MAIN_ORIGIN: (f64, f64) = (96., 64.);
pub const MAIN_SIZE: (f32, f32) = (1280., 860.);
pub const NARROW_SIZE: (f32, f32) = (900., 700.);
/// The backdrop around the shots (window shadows land on it).
const MARGIN: f64 = 24.;

/// What `--capture` was given.
#[derive(Clone, Debug, Default)]
pub struct CaptureOptions {
    pub dir: PathBuf,
    /// The local server's env file plus the harness's own (`--capture-env`).
    pub env: BTreeMap<String, String>,
    /// `--capture-only a,b`: run only these phases (for iterating).
    pub only: Option<BTreeSet<String>>,
}

impl CaptureOptions {
    pub fn from_args(args: &[String]) -> Option<Self> {
        let arg = |k: &str| {
            args.iter()
                .position(|a| a == k)
                .and_then(|i| args.get(i + 1))
                .cloned()
        };
        let dir = PathBuf::from(arg("--capture")?);
        let var = |k: &str| std::env::var(k).ok().filter(|v| !v.is_empty());
        let mut env = BTreeMap::new();
        if let Some(path) = arg("--e2e-env")
            .map(PathBuf::from)
            .or_else(|| crate::e2e::default_env_path(var))
            && let Ok(text) = std::fs::read_to_string(path)
        {
            env.extend(crate::e2e::parse_env(&text));
        }
        if let Some(path) = arg("--capture-env")
            && let Ok(text) = std::fs::read_to_string(path)
        {
            env.extend(crate::e2e::parse_env(&text));
        }
        let only = arg("--capture-only").map(|s| {
            s.split(',')
                .map(|p| p.trim().to_string())
                .filter(|p| !p.is_empty())
                .collect()
        });
        Some(Self { dir, env, only })
    }
}

/// One file the run wrote, for `notes/inventory.json`.
#[derive(Clone, Debug)]
pub struct Entry {
    pub file: String,
    pub screen: String,
    pub description: String,
    /// `real`, or `look-alike` for drawn stand-ins.
    pub kind: &'static str,
}

/// What the notes collect along the way.
#[derive(Default)]
pub struct Notes {
    /// Per screen: the focus order, one control per Tab (or arrow) step.
    pub focus: Vec<(String, Vec<String>)>,
    /// Per icon-only button: the screen, its label, whether a tooltip
    /// showed, the file.
    pub tooltips: Vec<(String, String, bool, String)>,
    /// Context and pop-up menus: name, items, captured for real.
    pub menus: Vec<(String, Vec<String>, bool)>,
    /// States that could not be captured, with the reason.
    pub missing: Vec<(String, String)>,
    /// Capture problems found and handled (retries, inactive windows).
    pub problems: Vec<String>,
    /// Per motion strip: its stats.
    pub motion: Vec<Value>,
}

pub struct Run {
    pub dir: PathBuf,
    pub env: BTreeMap<String, String>,
    pub main: AnyWindowHandle,
    pub backdrop: AnyWindowHandle,
    pub mode: ThemeMode,
    seq: BTreeMap<&'static str, usize>,
    pub inventory: Vec<Entry>,
    pub notes: Notes,
    only: Option<BTreeSet<String>>,
}

/// Options for one shot.
#[derive(Clone, Copy, Debug)]
pub struct Shot {
    /// The longest to wait for the window to stop changing.
    pub settle: Duration,
    /// Capture this rect (screen points) instead of the window's.
    pub rect: Option<CGRect>,
    /// Make the window key first (off for shots of a window that must not
    /// take focus, like the main window behind Quick Ask).
    pub key: bool,
}

impl Default for Shot {
    fn default() -> Self {
        Self {
            settle: Duration::from_millis(2500),
            rect: None,
            key: true,
        }
    }
}

impl Shot {
    pub fn quick() -> Self {
        Self {
            settle: Duration::from_millis(400),
            ..Self::default()
        }
    }
}

pub fn log(line: impl AsRef<str>) {
    println!("CAPTURE {}", line.as_ref());
}

pub async fn pause(cx: &mut AsyncApp, ms: u64) {
    cx.background_executor()
        .timer(Duration::from_millis(ms))
        .await;
}

pub async fn wait_until(
    cx: &mut AsyncApp,
    timeout: Duration,
    mut done: impl FnMut(&mut App) -> bool,
) -> bool {
    let deadline = Instant::now() + timeout;
    loop {
        if cx.update(|cx| done(cx)) {
            return true;
        }
        if Instant::now() > deadline {
            return false;
        }
        pause(cx, 150).await;
    }
}

pub fn ns_window(handle: AnyWindowHandle, cx: &mut App) -> Option<Retained<NSWindow>> {
    handle
        .update(cx, |_, window, _| cw::macos::ns_window(window))
        .ok()
        .flatten()
}

/// Places a window (top-left, screen points). AppKit calls back into GPUI
/// from `setFrame`, so this runs outside any GPUI borrow.
pub fn place(handle: AnyWindowHandle, origin: (f64, f64), size: (f32, f32), cx: &mut AsyncApp) {
    let Some(ns) = cx.update(|cx| ns_window(handle, cx)) else {
        return;
    };
    let screen_h = ns.screen().map(|s| s.frame().size.height).unwrap_or(1080.);
    let frame = objc2_foundation::NSRect::new(
        objc2_foundation::NSPoint::new(origin.0, screen_h - origin.1 - f64::from(size.1)),
        objc2_foundation::NSSize::new(f64::from(size.0), f64::from(size.1)),
    );
    ns.setFrame_display(frame, true);
}

/// The window's frame (screen points, top-left origin).
pub fn window_rect(handle: AnyWindowHandle, cx: &mut AsyncApp) -> Option<CGRect> {
    cx.update(|cx| {
        handle
            .update(cx, |_, window, _| {
                let b = window.bounds();
                CGRect {
                    x: f64::from(f32::from(b.origin.x)),
                    y: f64::from(f32::from(b.origin.y)),
                    w: f64::from(f32::from(b.size.width)),
                    h: f64::from(f32::from(b.size.height)),
                }
            })
            .ok()
    })
}

/// A window-relative point in screen points.
pub fn to_screen(
    handle: AnyWindowHandle,
    at: gpui_kit::Point<gpui_kit::Pixels>,
    cx: &mut AsyncApp,
) -> Option<(f64, f64)> {
    let r = window_rect(handle, cx)?;
    Some((
        r.x + f64::from(f32::from(at.x)),
        r.y + f64::from(f32::from(at.y)),
    ))
}

fn app_active() -> bool {
    use objc2::runtime::AnyObject;
    use objc2::{class, msg_send};
    // SAFETY: a plain AppKit read on the main thread.
    unsafe {
        let app: *mut AnyObject = msg_send![class!(NSApplication), sharedApplication];
        let active: bool = msg_send![app, isActive];
        active
    }
}

/// Makes the app active and `handle` key, as a click on it would.
pub fn activate(handle: AnyWindowHandle, cx: &mut App) {
    use objc2::runtime::AnyObject;
    use objc2::{class, msg_send};
    let _ = handle.update(cx, |_, window, _| window.activate_window());
    // SAFETY: plain AppKit messages on the main thread, outside GPUI borrows
    // of the window (the update above has returned). macOS 14+ activates
    // cooperatively: while the user works in another app this is only a
    // request, which the callers retry.
    unsafe {
        let app: *mut AnyObject = msg_send![class!(NSApplication), sharedApplication];
        let _: () = msg_send![app, activateIgnoringOtherApps: true];
        let responds: bool = msg_send![app, respondsToSelector: objc2::sel!(activate)];
        if responds {
            let _: () = msg_send![app, activate];
        }
    }
    if let Some(ns) = ns_window(handle, cx) {
        ns.makeKeyAndOrderFront(None);
    }
}

/// Whether the app is active and `handle` is its key window.
/// Whether `handle` has the keyboard: it is the key window, or a sheet it
/// carries is (AppKit makes the sheet key; its parent never is meanwhile).
pub fn is_key(handle: AnyWindowHandle, cx: &mut App) -> bool {
    app_active()
        && ns_window(handle, cx).is_some_and(|ns| {
            ns.isKeyWindow() || ns.attachedSheet().is_some_and(|s| s.isKeyWindow())
        })
}

pub fn set_mode(mode: ThemeMode, cx: &mut App) {
    let settings = cx.global::<AppState>().settings.clone();
    settings.update(cx, |s, cx| s.set_appearance(|a| a.mode = mode, cx));
    for w in cx.windows() {
        let _ = w.update(cx, |_, window, _| window.refresh());
    }
}

pub fn mode_name(mode: ThemeMode) -> &'static str {
    match mode {
        ThemeMode::Dark => "dark",
        _ => "light",
    }
}

/// Grabs `rect` on another thread (CoreGraphics is thread-safe), so a
/// capture works while the main thread is busy (an open menu's tracking
/// loop), and waits for it without blocking the executor.
pub async fn grab_off_main(rect: CGRect, full: bool, cx: &mut AsyncApp) -> Option<Frame> {
    let (tx, rx) = mpsc::channel();
    std::thread::spawn(move || {
        let _ = tx.send(Frame::of_rect(rect, full));
    });
    for _ in 0..200 {
        if let Ok(frame) = rx.try_recv() {
            return frame;
        }
        pause(cx, 15).await;
    }
    None
}

fn is_blank(frame: &Frame) -> bool {
    let Some((px, _)) = frame.pixels() else {
        return true;
    };
    let first = px.get(..4).map(|p| p.to_vec()).unwrap_or_default();
    px.chunks(4).step_by(97).all(|p| p == first.as_slice())
}

impl Run {
    pub fn wants(&self, phase: &str) -> bool {
        self.only.as_ref().is_none_or(|o| o.contains(phase))
    }

    fn next(&mut self, folder: &'static str) -> usize {
        let n = self.seq.entry(folder).or_insert(0);
        *n += 1;
        *n
    }

    pub fn path(&self, folder: &str, file: &str) -> PathBuf {
        let dir = self.dir.join(folder);
        std::fs::create_dir_all(&dir).ok();
        dir.join(file)
    }

    pub fn record(
        &mut self,
        folder: &str,
        file: &str,
        screen: &str,
        description: &str,
        kind: &'static str,
    ) {
        self.inventory.push(Entry {
            file: format!("{folder}/{file}"),
            screen: screen.to_string(),
            description: description.to_string(),
            kind,
        });
    }

    pub fn missing(&mut self, state: &str, reason: &str) {
        log(format!("missing {state}: {reason}"));
        self.notes
            .missing
            .push((state.to_string(), reason.to_string()));
    }

    pub fn problem(&mut self, what: impl Into<String>) {
        let what = what.into();
        log(format!("problem: {what}"));
        self.notes.problems.push(what);
    }

    /// Switches light/dark (and the app appearance native chrome follows).
    pub async fn mode(&mut self, mode: ThemeMode, cx: &mut AsyncApp) {
        if self.mode != mode {
            cx.update(|cx| set_mode(mode, cx));
            self.mode = mode;
            pause(cx, 250).await;
        }
    }

    /// Makes `handle` key, waiting while macOS refuses (the user works in
    /// another app). `false` when it never became key: the capture goes on
    /// with inactive chrome, noted.
    pub async fn ensure_key(
        &mut self,
        handle: AnyWindowHandle,
        what: &str,
        cx: &mut AsyncApp,
    ) -> bool {
        // macOS 14+ activates cooperatively: while the user works in another
        // app the request is refused. The run waits (up to 20 minutes) rather
        // than capture grey traffic lights and an inactive window.
        let started = Instant::now();
        let mut announced = false;
        loop {
            if cx.update(|cx| is_key(handle, cx)) {
                if announced {
                    log(format!(
                        "{what}: active again after {:.0} s",
                        started.elapsed().as_secs_f64()
                    ));
                }
                if started.elapsed() > Duration::from_secs(5) {
                    self.problem(format!(
                        "{what}: macOS refused to activate the app for {:.0} s (the user was in another app); the run waited",
                        started.elapsed().as_secs_f64()
                    ));
                }
                return true;
            }
            if started.elapsed() > Duration::from_secs(20 * 60) {
                self.problem(format!(
                    "{what}: INACTIVE CHROME: the app could not be made active for 20 minutes"
                ));
                return false;
            }
            if !announced && started.elapsed() > Duration::from_secs(5) {
                log(format!(
                    "{what}: waiting for macOS to let the app become active"
                ));
                announced = true;
            }
            cx.update(|cx| activate(handle, cx));
            pause(
                cx,
                if started.elapsed() < Duration::from_secs(2) {
                    250
                } else {
                    2000
                },
            )
            .await;
        }
    }

    /// Puts the backdrop right behind `target` (a normal window), or in
    /// front of every other app's window (a floating one), so nothing but
    /// synthetic pixels lies behind what is captured.
    pub fn stack(&self, target: AnyWindowHandle, cx: &mut AsyncApp) {
        let (Some(t), Some(b)) =
            cx.update(|cx| (ns_window(target, cx), ns_window(self.backdrop, cx)))
        else {
            return;
        };
        if t.level() <= 0 {
            b.orderWindow_relativeTo(objc2_app_kit::NSWindowOrderingMode::Below, t.windowNumber());
        } else {
            b.orderFront(None);
        }
    }

    /// Captures `handle` (with a margin of backdrop) to `out`, once it has
    /// stopped changing.
    pub async fn snap(
        &mut self,
        handle: AnyWindowHandle,
        out: &Path,
        shot: Shot,
        cx: &mut AsyncApp,
    ) -> bool {
        self.stack(handle, cx);
        if shot.key {
            self.ensure_key(handle, &out.display().to_string(), cx)
                .await;
        }
        let Some(rect) = shot
            .rect
            .or_else(|| window_rect(handle, cx).map(|r| grab::inset(r, MARGIN)))
        else {
            self.problem(format!("{}: window gone", out.display()));
            return false;
        };
        // Stable: two captures in a row (one pixel a point) barely differ.
        let deadline = Instant::now() + shot.settle;
        let mut last = grab_off_main(rect, false, cx).await;
        loop {
            pause(cx, 120).await;
            let now = grab_off_main(rect, false, cx).await;
            let still = match (&last, &now) {
                (Some(a), Some(b)) => grab::difference(a, b, None) < 0.0008,
                _ => false,
            };
            last = now;
            if still || Instant::now() > deadline {
                break;
            }
        }
        for attempt in 0..3 {
            let Some(frame) = grab_off_main(rect, true, cx).await else {
                pause(cx, 300).await;
                continue;
            };
            if is_blank(&frame) {
                self.problem(format!(
                    "{}: blank frame (attempt {attempt})",
                    out.display()
                ));
                pause(cx, 800).await;
                continue;
            }
            return match frame.write_png(out) {
                Ok((w, h)) => {
                    log(format!("shot {} ({w}x{h})", out.display()));
                    true
                }
                Err(e) => {
                    self.problem(format!("{}: {e}", out.display()));
                    false
                }
            };
        }
        self.problem(format!("{}: no capture", out.display()));
        false
    }

    /// A static state in both modes: `static/NN-area-state-{light,dark}.png`.
    pub async fn state(
        &mut self,
        handle: AnyWindowHandle,
        area: &str,
        state: &str,
        description: &str,
        shot: Shot,
        cx: &mut AsyncApp,
    ) {
        let n = self.next("static");
        let first = self.mode;
        let second = if first == ThemeMode::Dark {
            ThemeMode::Light
        } else {
            ThemeMode::Dark
        };
        for mode in [first, second] {
            self.state_one(n, handle, area, state, description, mode, shot, cx)
                .await;
        }
    }

    /// The next static number, for a pair shot one mode at a time.
    pub fn reserve_static(&mut self) -> usize {
        self.next("static")
    }

    /// One mode of static state `n`.
    #[allow(clippy::too_many_arguments)]
    pub async fn state_one(
        &mut self,
        n: usize,
        handle: AnyWindowHandle,
        area: &str,
        state: &str,
        description: &str,
        mode: ThemeMode,
        shot: Shot,
        cx: &mut AsyncApp,
    ) {
        self.mode(mode, cx).await;
        let file = format!("{n:02}-{area}-{state}-{}.png", mode_name(mode));
        let out = self.path("static", &file);
        if self.snap(handle, &out, shot, cx).await {
            self.record(
                "static",
                &file,
                &format!("{area} · {state}"),
                description,
                "real",
            );
        }
    }

    /// One interaction state, in light (call [`Run::interaction_dark`] for
    /// dark).
    pub async fn interaction(
        &mut self,
        handle: AnyWindowHandle,
        area: &str,
        state: &str,
        description: &str,
        shot: Shot,
        cx: &mut AsyncApp,
    ) -> String {
        self.mode(ThemeMode::Light, cx).await;
        self.interaction_here(handle, area, state, description, shot, cx)
            .await
    }

    /// The same in dark.
    pub async fn interaction_dark(
        &mut self,
        handle: AnyWindowHandle,
        area: &str,
        state: &str,
        description: &str,
        shot: Shot,
        cx: &mut AsyncApp,
    ) -> String {
        self.mode(ThemeMode::Dark, cx).await;
        let file = self
            .interaction_here(handle, area, state, description, shot, cx)
            .await;
        self.mode(ThemeMode::Light, cx).await;
        file
    }

    /// One interaction state in the current mode.
    async fn interaction_here(
        &mut self,
        handle: AnyWindowHandle,
        area: &str,
        state: &str,
        description: &str,
        shot: Shot,
        cx: &mut AsyncApp,
    ) -> String {
        let n = self.next("interaction");
        let suffix = if self.mode == ThemeMode::Dark {
            "-dark"
        } else {
            ""
        };
        let file = format!("{n:02}-{area}-{state}{suffix}.png");
        let out = self.path("interaction", &file);
        if self.snap(handle, &out, shot, cx).await {
            self.record(
                "interaction",
                &file,
                &format!("{area} · {state}"),
                description,
                "real",
            );
        }
        file
    }

    /// Steps keyboard focus with `key` (`tab`, `down`) up to `max` times,
    /// capturing each step and noting what has focus, until it comes back
    /// to where it started.
    pub async fn focus_walk(
        &mut self,
        handle: AnyWindowHandle,
        screen: &str,
        key: &str,
        max: usize,
        cx: &mut AsyncApp,
    ) {
        let mut order = vec![];
        // Where each stop is (window points), to read a closed cycle from
        // the window's first stop.
        let mut places: Vec<Option<(f32, f32)>> = vec![];
        let mut closed = false;
        let mut first: Option<Option<gpui_kit::FocusHandle>> = None;
        let mut unlabelled: Vec<gpui_kit::FocusHandle> = vec![];
        // Where the walk starts, so a cycle that begins mid-way (Quick Ask
        // opens in its message field) reads right.
        let start = {
            let nodes = drive::nodes(handle, cx).await;
            match (drive::focused(&nodes), drive::active(&nodes)) {
                (Some(n), Some(a)) => format!("{} (in {})", a.describe(), n.describe()),
                (Some(n), None) => n.describe(),
                (None, _) => "nothing focused".to_string(),
            }
        };
        for step in 1..=max {
            drive::key(handle, key, cx);
            pause(cx, 200).await;
            let focus = cx.update(|cx| {
                handle
                    .update(cx, |_, window, cx| window.focused(cx))
                    .ok()
                    .flatten()
            });
            let nodes = drive::nodes(handle, cx).await;
            let arrows = !key.contains("tab");
            let label = match (drive::focused(&nodes), &focus) {
                (Some(n), _) if arrows => match drive::active(&nodes).or_else(|| {
                    nodes
                        .iter()
                        .find(|o| o.selected == Some(true) && o.role.contains("Option"))
                }) {
                    Some(o) => format!("{} (highlighted in {})", o.describe(), n.describe()),
                    None => n.describe(),
                },
                // A group that is one stop (a radio group, a list) reports
                // its chosen option as the focused control.
                (Some(n), _) => match drive::active(&nodes) {
                    Some(a) => format!("{} (in {})", a.describe(), n.describe()),
                    None => n.describe(),
                },
                (None, None) => "(nothing has focus)".to_string(),
                (None, Some(f)) => {
                    let k = match unlabelled.iter().position(|u| u == f) {
                        Some(k) => k,
                        None => {
                            unlabelled.push(f.clone());
                            unlabelled.len() - 1
                        }
                    };
                    format!("(a focused element with no accessibility node, #{})", k + 1)
                }
            };
            // Tab cycles focus; arrows move a highlight while focus stays.
            if step > 1 && !arrows && first.as_ref() == Some(&focus) {
                order.push(format!("{label} (back to the first stop)"));
                closed = true;
                break;
            }
            if first.is_none() {
                first = Some(focus.clone());
            }
            order.push(label.clone());
            places.push(
                drive::focused(&nodes)
                    .and_then(|n| n.bounds)
                    .map(|b| (f32::from(b.origin.y), f32::from(b.origin.x))),
            );
            self.interaction(
                handle,
                &format!("focus-{screen}"),
                &format!("step-{step:02}"),
                &format!("{screen}: after {step} \u{d7} {key}, focus is on {label}"),
                Shot::quick(),
                cx,
            )
            .await;
        }
        let reading = closed
            .then(|| reading_order(&order[..places.len()], &places))
            .flatten();
        self.notes
            .focus
            .push((format!("{screen} ({key}, starting on {start})"), order));
        if let Some(reading) = reading {
            self.notes.focus.push((
                format!("{screen}: the same cycle from the window's first stop (top left)"),
                reading,
            ));
        }
    }

    /// Hovers every icon-only button in `handle` that passes `filter` and
    /// waits past the tooltip delay; a tooltip counts when something
    /// appears outside the button. Each result is captured (cropped).
    pub async fn tooltips_where(
        &mut self,
        handle: AnyWindowHandle,
        screen: &str,
        filter: impl Fn(&drive::Node) -> bool,
        cx: &mut AsyncApp,
    ) {
        self.mode(ThemeMode::Light, cx).await;
        let nodes = drive::nodes(handle, cx).await;
        let mut seen = BTreeSet::new();
        let buttons: Vec<drive::Node> = nodes
            .into_iter()
            .filter(|n| n.is_icon_button() && filter(n))
            .filter(|n| seen.insert(n.label.clone()))
            .take(24)
            .collect();
        let Some(window) = window_rect(handle, cx) else {
            return;
        };
        for b in buttons {
            let (Some(at), Some(bounds)) = (b.center(), b.bounds) else {
                continue;
            };
            let (bx, by) = (
                f64::from(f32::from(bounds.origin.x)),
                f64::from(f32::from(bounds.origin.y)),
            );
            let (bw, bh) = (
                f64::from(f32::from(bounds.size.width)),
                f64::from(f32::from(bounds.size.height)),
            );
            // A region around the button, inside the window.
            let x0 = (window.x + bx - 170.).max(window.x);
            let y0 = (window.y + by - 70.).max(window.y);
            let x1 = (window.x + bx + bw + 170.).min(window.x + window.w);
            let y1 = (window.y + by + bh + 90.).min(window.y + window.h);
            let rect = CGRect {
                x: x0,
                y: y0,
                w: x1 - x0,
                h: y1 - y0,
            };
            drive::hover(handle, at, cx);
            pause(cx, 180).await;
            let before = grab_off_main(rect, true, cx).await;
            pause(cx, 1300).await;
            let after = grab_off_main(rect, true, cx).await;
            let (Some(before), Some(after)) = (before, after) else {
                continue;
            };
            let scale = after.size().0 as f64 / rect.w.max(1.);
            let px = |v: f64| (v.max(0.) * scale) as usize;
            let button = (
                px(window.x + bx - x0 - 6.),
                px(window.y + by - y0 - 6.),
                px(window.x + bx - x0 + bw + 6.),
                px(window.y + by - y0 + bh + 6.),
            );
            let shown = grab::difference_outside(&before, &after, None, Some(button)) > 0.002;
            let n = self.next("interaction");
            let slug: String = b
                .label
                .to_lowercase()
                .chars()
                .map(|c| if c.is_ascii_alphanumeric() { c } else { '-' })
                .collect::<String>()
                .split('-')
                .filter(|p| !p.is_empty())
                .take(5)
                .collect::<Vec<_>>()
                .join("-");
            let file = format!("{n:02}-tooltip-{screen}-{slug}.png");
            let out = self.path("interaction", &file);
            if after.write_png(&out).is_ok() {
                let what = if shown {
                    "a tooltip shows"
                } else {
                    "no tooltip"
                };
                self.record(
                    "interaction",
                    &file,
                    &format!("tooltip · {screen}"),
                    &format!("\u{201c}{}\u{201d} hovered for 1.3 s: {what}.", b.label),
                    "real",
                );
            }
            self.notes
                .tooltips
                .push((screen.to_string(), b.label.clone(), shown, file));
        }
        drive::unhover(handle, cx);
        pause(cx, 200).await;
    }

    pub async fn tooltips(&mut self, handle: AnyWindowHandle, screen: &str, cx: &mut AsyncApp) {
        self.tooltips_where(handle, screen, |_| true, cx).await;
    }

    /// Captures a native menu for real: `open` pops it (a right-click, a
    /// menu button, `TrayIcon::show_menu`); another thread waits for the
    /// menu window, captures it (over the window when `with_window`), then
    /// the armed closer ends the menu's tracking loop.
    async fn menu_capture(
        &mut self,
        handle: AnyWindowHandle,
        with_window: bool,
        out: &Path,
        open: impl FnOnce(&mut AsyncApp),
        cx: &mut AsyncApp,
    ) -> Result<CGRect, String> {
        self.ensure_key(handle, &out.display().to_string(), cx)
            .await;
        self.stack(handle, cx);
        grab::force_menu_appearance(Some(self.mode == ThemeMode::Dark));
        pause(cx, 200).await;
        let window = if with_window {
            Some(window_rect(handle, cx).ok_or("window gone")?)
        } else {
            None
        };
        let (tx, rx) = mpsc::channel::<Result<CGRect, String>>();
        let out_thread = out.to_path_buf();
        std::thread::spawn(move || {
            let deadline = Instant::now() + Duration::from_secs(4);
            loop {
                std::thread::sleep(Duration::from_millis(100));
                if let Some(menu) = grab::open_menus().first().copied() {
                    // Past the menu's fade-in.
                    std::thread::sleep(Duration::from_millis(350));
                    let menu = grab::open_menus().first().copied().unwrap_or(menu);
                    let rect = match window {
                        Some(w) => grab::inset(grab::union(w, menu.bounds), MARGIN),
                        None => grab::inset(menu.bounds, MARGIN),
                    };
                    let result = Frame::of_rect(rect, true)
                        .ok_or_else(|| "no capture".to_string())
                        .and_then(|f| f.write_png(&out_thread).map(|_| menu.bounds));
                    grab::request_menu_close();
                    let _ = tx.send(result);
                    return;
                }
                if Instant::now() > deadline {
                    let _ = tx.send(Err("no menu opened".into()));
                    return;
                }
            }
        });
        grab::arm_menu_closer(Duration::from_secs(6));
        open(cx);
        let mut result = Err("timed out".to_string());
        for _ in 0..400 {
            if let Ok(r) = rx.try_recv() {
                result = r;
                break;
            }
            pause(cx, 20).await;
        }
        // Let the menu close and the window repaint.
        pause(cx, 400).await;
        cx.update(|cx| {
            let _ = handle.update(cx, |_, window, _| window.refresh());
        });
        if let Ok(bounds) = &result {
            log(format!("menu {} at {bounds:?}", out.display()));
        }
        result
    }

    /// A native menu over its window, as an interaction shot (light).
    pub async fn native_menu(
        &mut self,
        handle: AnyWindowHandle,
        name: &str,
        description: &str,
        open: impl FnOnce(&mut AsyncApp),
        cx: &mut AsyncApp,
    ) -> Option<String> {
        self.mode(ThemeMode::Light, cx).await;
        let n = self.next("interaction");
        let file = format!("{n:02}-{name}.png");
        let out = self.path("interaction", &file);
        match self.menu_capture(handle, true, &out, open, cx).await {
            Ok(_) => {
                self.record("interaction", &file, name, description, "real");
                let items = grab::take_menu_items();
                self.notes.menus.push((name.to_string(), items, true));
                Some(file)
            }
            Err(e) => {
                self.problem(format!("{name}: {e}"));
                None
            }
        }
    }

    /// A native menu as a static state, light and dark under one number.
    /// `with_window`: over its window (else the menu alone).
    #[allow(clippy::too_many_arguments)]
    pub async fn native_menu_pair(
        &mut self,
        handle: AnyWindowHandle,
        area: &str,
        state: &str,
        description: &str,
        with_window: bool,
        open: impl Fn(&mut AsyncApp),
        cx: &mut AsyncApp,
    ) -> bool {
        let n = self.next("static");
        let mut all = true;
        for mode in [ThemeMode::Light, ThemeMode::Dark] {
            self.mode(mode, cx).await;
            let file = format!("{n:02}-{area}-{state}-{}.png", mode_name(mode));
            let out = self.path("static", &file);
            match self
                .menu_capture(handle, with_window, &out, &open, cx)
                .await
            {
                Ok(_) => {
                    self.record(
                        "static",
                        &file,
                        &format!("{area} · {state}"),
                        description,
                        "real",
                    );
                    let items = grab::take_menu_items();
                    if mode == ThemeMode::Light {
                        self.notes
                            .menus
                            .push((format!("{area}-{state}"), items, true));
                    }
                }
                Err(e) => {
                    self.problem(format!("{area}-{state} ({}): {e}", mode_name(mode)));
                    all = false;
                }
            }
        }
        self.mode(ThemeMode::Light, cx).await;
        all
    }
}

struct Backdrop;

impl Render for Backdrop {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let dark = cx.global::<conduit_components::ConduitTheme>().dark;
        // A quiet, wallpaper-like gradient for window shadows and the
        // sidebar material to sit on.
        let (a, b) = if dark {
            (0x1b2433, 0x2c3446)
        } else {
            (0xc9d3e1, 0xe6e1d9)
        };
        div().size_full().bg(linear_gradient(
            160.,
            linear_color_stop(rgb(a), 0.),
            linear_color_stop(rgb(b), 1.),
        ))
    }
}

fn open_backdrop(cx: &mut App) -> Option<AnyWindowHandle> {
    let display = cx.primary_display().map(|d| d.bounds());
    let bounds = display.unwrap_or(Bounds::new(
        point(px(0.), px(0.)),
        size(px(1728.), px(1117.)),
    ));
    let options = WindowOptions {
        window_bounds: Some(WindowBounds::Windowed(bounds)),
        titlebar: None,
        focus: false,
        is_movable: false,
        window_background: WindowBackgroundAppearance::Opaque,
        ..Default::default()
    };
    cw::open_window_clear_root(options, cx, |_, cx| cx.new(|_| Backdrop))
        .ok()
        .map(|(h, _)| h)
}

/// Once there is a session: the main window (it replaces the setup
/// window), placed where the shots expect it and made the run's.
pub async fn adopt_main(run: &mut Run, cx: &mut AsyncApp) -> bool {
    let opened = wait_until(cx, Duration::from_secs(15), |cx| {
        cx.global::<AppState>().main_window.is_some() && !crate::windows::setup_alive(cx)
    })
    .await;
    let Some(main) = cx.update(|cx| cx.global::<AppState>().main_window) else {
        run.problem("no main window after signing in");
        return false;
    };
    if !opened {
        run.problem("the setup window stayed open beside the main window");
    }
    place(main, MAIN_ORIGIN, MAIN_SIZE, cx);
    cx.update(|cx| activate(main, cx));
    run.main = main;
    pause(cx, 400).await;
    if let Some(r) = window_rect(main, cx) {
        log(format!("main window at {r:?}"));
        if (r.w - f64::from(MAIN_SIZE.0)).abs() > 1. || (r.h - f64::from(MAIN_SIZE.1)).abs() > 1. {
            run.problem(format!(
                "the main window is {}x{}, not {}x{}",
                r.w, r.h, MAIN_SIZE.0, MAIN_SIZE.1
            ));
        }
    }
    true
}

/// Starts the pass; it quits the app when done.
pub fn run(options: CaptureOptions, cx: &mut App) {
    for sub in ["static", "interaction", "motion", "notes"] {
        std::fs::create_dir_all(options.dir.join(sub)).ok();
    }
    // The seed's names are synthetic already; Redact's stand-ins would
    // disagree with each other (a greeting and an account row hashed apart).
    cx.set_global(crate::views::privacy::Redact(false));
    cx.set_global(crate::shell::sheet::AutoAnswer(None));
    grab::install_menu_watch();
    let backdrop = open_backdrop(cx);
    let started = Instant::now();
    cx.spawn(async move |cx: &mut AsyncApp| {
        // The window the app opened with: the main window on a used
        // profile, the setup window on a fresh one. The onboarding phase
        // moves to the setup window and back to the main one.
        let Some(main) = cx.update(crate::windows::front_window) else {
            log("FAILED no window");
            cx.update(crate::views::sheet::quit);
            return;
        };
        let is_main = cx.update(|cx| cx.global::<AppState>().main_window == Some(main));
        // The backdrop sits right behind the app's windows, over everything
        // else on screen: behind-window materials (the sidebar, menus, Quick
        // Ask) then blur synthetic pixels, never another app's windows.
        let Some(backdrop) = backdrop else {
            log("FAILED no backdrop window");
            cx.update(crate::views::sheet::quit);
            return;
        };
        if is_main {
            place(main, MAIN_ORIGIN, MAIN_SIZE, cx);
        }
        cx.update(|cx| activate(main, cx));
        let mode = cx.update(|cx| cx.global::<AppState>().settings.read(cx).prefs.appearance.mode);
        let mut run = Run {
            dir: options.dir.clone(),
            env: options.env.clone(),
            main,
            backdrop,
            mode,
            seq: BTreeMap::new(),
            inventory: vec![],
            notes: Notes::default(),
            only: options.only.clone(),
        };
        run.mode(ThemeMode::Light, cx).await;
        // A state that could not be captured, or any problem, fails the run.
        let passed = phases(&mut run, cx).await
            && run.notes.missing.is_empty()
            && run.notes.problems.is_empty();
        notes::write(&mut run, cx).await;
        log(format!(
            "{} after {:?}: {} static, {} interaction files, {} motion strips, {} missing, {} problems",
            if passed { "done" } else { "FAILED" },
            started.elapsed(),
            run.inventory.iter().filter(|e| e.file.starts_with("static/")).count(),
            run.inventory.iter().filter(|e| e.file.starts_with("interaction/")).count(),
            run.notes.motion.len(),
            run.notes.missing.len(),
            run.notes.problems.len(),
        ));
        cx.update(|cx| set_mode(ThemeMode::System, cx));
        cx.update(crate::views::sheet::quit);
    })
    .detach();
}

async fn phases(run: &mut Run, cx: &mut AsyncApp) -> bool {
    if !onboarding::run(run, cx).await {
        log("FAILED onboarding and sign-in");
        return false;
    }
    main_pass::run(run, cx).await;
    shell_pass::run(run, cx).await;
    motion::run(run, cx).await;
    main_pass::narrow(run, cx).await;
    shell_pass::reconnect(run, cx).await;
    true
}

/// `{"file": …}` rows for the inventory.
pub fn inventory_json(entries: &[Entry]) -> Value {
    Value::Array(
        entries
            .iter()
            .map(|e| {
                json!({
                    "file": e.file,
                    "screen": e.screen,
                    "description": e.description,
                    "kind": e.kind,
                })
            })
            .collect(),
    )
}

/// A closed focus cycle (`labels`, each stop's `(y, x)`) told from its stop
/// nearest the window's top left (rows 12 pt apart count as one), so it
/// reads in the order a person scans the window. `None` if a stop has no
/// place.
pub fn reading_order(labels: &[String], places: &[Option<(f32, f32)>]) -> Option<Vec<String>> {
    if labels.is_empty() || labels.len() != places.len() {
        return None;
    }
    let places: Vec<(f32, f32)> = places.iter().copied().collect::<Option<_>>()?;
    let start = (0..places.len()).min_by(|a, b| {
        let (ya, xa) = places[*a];
        let (yb, xb) = places[*b];
        ((ya / 12.).floor(), xa)
            .partial_cmp(&((yb / 12.).floor(), xb))
            .unwrap_or(std::cmp::Ordering::Equal)
    })?;
    Some(
        (0..labels.len())
            .map(|k| labels[(start + k) % labels.len()].clone())
            .collect(),
    )
}

#[cfg(test)]
mod reading_order_tests {
    use super::reading_order;

    #[test]
    fn a_cycle_walked_from_the_field_reads_from_the_top_left() {
        // Quick Ask walked from its message field: Model (bottom right),
        // New Chat and Close (top), Attach Files, Message (bottom left).
        let labels: Vec<String> = ["Model", "New Chat", "Close", "Attach Files", "Message"]
            .map(String::from)
            .to_vec();
        let places = vec![
            Some((300., 520.)),
            Some((12., 480.)),
            Some((13., 520.)),
            Some((302., 14.)),
            Some((300., 44.)),
        ];
        assert_eq!(
            reading_order(&labels, &places).unwrap(),
            ["New Chat", "Close", "Attach Files", "Message", "Model"]
        );
        // A stop with no place: no reading.
        let mut gap = places.clone();
        gap[2] = None;
        assert!(reading_order(&labels, &gap).is_none());
    }
}
