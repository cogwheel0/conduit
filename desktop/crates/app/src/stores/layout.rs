//! The main window's geometry and layout (`window-state.json`): saved as the
//! window moves and resizes (coalesced), restored on launch, and kept on a
//! display that still exists.

use std::path::PathBuf;
use std::time::Duration;

use gpui_kit::{
    App, AsyncApp, Bounds, Context, Pixels, Task, WeakEntity, WindowBounds, point, px, size,
};

use crate::prefs::{self, WindowState};

pub struct LayoutStore {
    pub state: WindowState,
    path: PathBuf,
    pending_save: Option<Task<()>>,
}

impl LayoutStore {
    pub fn load(path: PathBuf) -> Self {
        Self {
            state: prefs::load::<WindowState>(&path).sanitized(),
            path,
            pending_save: None,
        }
    }

    pub fn save_now(&self) {
        if let Err(e) = prefs::save(&self.path, &self.state) {
            log::error!("could not save {}: {e}", self.path.display());
        }
    }

    /// Saves after a short quiet period (window drags send many updates).
    fn save_soon(&mut self, cx: &mut Context<Self>) {
        self.pending_save = Some(cx.spawn(
            async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
                cx.background_executor()
                    .timer(Duration::from_millis(400))
                    .await;
                let _ = this.update(cx, |s, _| s.save_now());
            },
        ));
    }

    pub fn toggle_sidebar(&mut self, cx: &mut Context<Self>) {
        self.state.sidebar_visible = !self.state.sidebar_visible;
        self.save_soon(cx);
        cx.notify();
    }

    /// Whether the app fronted the main window last (see
    /// [`crate::windows`]): what it opens before the daemon answers.
    pub fn last_main(&self) -> bool {
        self.state.opens_main()
    }

    /// Remembers which window the app fronts now.
    pub fn set_last_main(&mut self, main: bool, cx: &mut Context<Self>) {
        if self.state.last_main != Some(main) {
            self.state.last_main = Some(main);
            self.save_soon(cx);
        }
    }

    /// Records the window's bounds as GPUI reports them.
    pub fn set_bounds(&mut self, bounds: WindowBounds, cx: &mut Context<Self>) {
        let (rect, maximized) = match bounds {
            WindowBounds::Windowed(b) => (b, false),
            WindowBounds::Maximized(b) => (b, true),
            // Full screen keeps the windowed geometry for next time.
            WindowBounds::Fullscreen(_) => return,
        };
        let next = WindowState {
            x: Some(f32::from(rect.origin.x)),
            y: Some(f32::from(rect.origin.y)),
            width: f32::from(rect.size.width),
            height: f32::from(rect.size.height),
            maximized,
            sidebar_visible: self.state.sidebar_visible,
            last_main: self.state.last_main,
        }
        .sanitized();
        if next != self.state {
            self.state = next;
            self.save_soon(cx);
        }
    }

    /// The bounds to open the window with: the saved ones if they still land
    /// on a display, else centred at the saved size.
    pub fn initial_bounds(&self, cx: &App) -> WindowBounds {
        let s = &self.state;
        let wanted = size(px(s.width), px(s.height));
        let saved = match (s.x, s.y) {
            (Some(x), Some(y)) => Some(Bounds::new(point(px(x), px(y)), wanted)),
            _ => None,
        };
        let on_screen = |b: &Bounds<Pixels>| {
            cx.displays().iter().any(|d| {
                let db = d.bounds();
                // At least a 100×40 grab area visible on some display.
                let ix = f32::from(b.right().min(db.right())) - f32::from(b.left().max(db.left()));
                let iy = f32::from(b.bottom().min(db.bottom())) - f32::from(b.top().max(db.top()));
                ix >= 100. && iy >= 40.
            })
        };
        let rect = saved
            .filter(on_screen)
            .unwrap_or_else(|| Bounds::centered(None, wanted, cx));
        if s.maximized {
            WindowBounds::Maximized(rect)
        } else {
            WindowBounds::Windowed(rect)
        }
    }
}
