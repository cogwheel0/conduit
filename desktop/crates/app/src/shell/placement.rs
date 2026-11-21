//! Where the Quick Ask window goes: 720×320, centred horizontally on the
//! display under the pointer, its top 1/5 of the way down that display's
//! visible area (below the menu bar, above the Dock).
//!
//! In AppKit's global coordinates (points, y up, origin at the primary
//! display's bottom-left), which is what `NSScreen.visibleFrame`,
//! `NSEvent.mouseLocation` and `NSWindow.setFrame` use.

/// The Quick Ask window's size, in points.
pub const QUICK_ASK_SIZE: (f64, f64) = (720., 320.);

/// A rectangle in AppKit's global coordinates (y up).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Rect {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

impl Rect {
    pub const fn new(x: f64, y: f64, width: f64, height: f64) -> Self {
        Self {
            x,
            y,
            width,
            height,
        }
    }

    fn contains(&self, (px, py): (f64, f64)) -> bool {
        px >= self.x && px < self.x + self.width && py >= self.y && py < self.y + self.height
    }

    fn distance_sq(&self, (px, py): (f64, f64)) -> f64 {
        let dx = (self.x - px).max(0.).max(px - (self.x + self.width));
        let dy = (self.y - py).max(0.).max(py - (self.y + self.height));
        dx * dx + dy * dy
    }
}

/// The display under `cursor` (by its full frame), else the nearest one.
/// `None` only when there are no displays.
pub fn display_under(frames: &[Rect], cursor: (f64, f64)) -> Option<usize> {
    frames.iter().position(|f| f.contains(cursor)).or_else(|| {
        frames
            .iter()
            .enumerate()
            .min_by(|a, b| a.1.distance_sq(cursor).total_cmp(&b.1.distance_sq(cursor)))
            .map(|(i, _)| i)
    })
}

/// The window's frame on a display whose visible area is `visible`: centred
/// horizontally, its top edge 1/5 of the way down, kept inside the visible
/// area when the display is small.
pub fn quick_ask_frame(visible: Rect, size: (f64, f64)) -> Rect {
    let (width, height) = (size.0.min(visible.width), size.1.min(visible.height));
    let x = visible.x + (visible.width - width) / 2.;
    let top = visible.y + visible.height - visible.height / 5.;
    // Never below the visible area's bottom edge.
    let y = (top - height).max(visible.y);
    Rect::new(x.round(), y.round(), width, height)
}

/// The setup window's frame `height` points tall (at most the visible
/// area's height) on a display whose visible area is `visible`. Not yet on
/// screen, it is centred there; on screen, its top edge stays where it is,
/// as long as the whole window stays inside the visible area.
pub fn setup_frame(visible: Rect, current: Rect, height: f64, shown: bool) -> Rect {
    let height = height.min(visible.height);
    if !shown {
        let x = visible.x + (visible.width - current.width) / 2.;
        let y = visible.y + (visible.height - height) / 2.;
        return Rect::new(x.round(), y.round(), current.width, height);
    }
    let top = current.y + current.height;
    let y = (top - height)
        .min(visible.y + visible.height - height)
        .max(visible.y);
    Rect::new(current.x, y, current.width, height)
}

#[cfg(test)]
mod tests {
    use super::*;

    // A 1512×982 laptop display with a 33 pt menu bar and no Dock, and a
    // 2560×1440 display to its left, top-aligned.
    const LAPTOP: Rect = Rect::new(0., 0., 1512., 982.);
    const LAPTOP_VISIBLE: Rect = Rect::new(0., 0., 1512., 949.);
    const LEFT: Rect = Rect::new(-2560., -458., 2560., 1440.);

    #[test]
    fn centred_and_a_fifth_of_the_way_down() {
        let f = quick_ask_frame(LAPTOP_VISIBLE, QUICK_ASK_SIZE);
        assert_eq!((f.width, f.height), (720., 320.));
        assert_eq!(f.x, 396.); // (1512 - 720) / 2
        // Top edge at 949 - 949/5 = 759.2 → frame bottom 439.2.
        assert_eq!(f.y + f.height, 759.);
        assert_eq!(f.y, 439.);
    }

    #[test]
    fn on_a_display_with_negative_coordinates() {
        let f = quick_ask_frame(LEFT, QUICK_ASK_SIZE);
        assert_eq!(f.x, -2560. + (2560. - 720.) / 2.);
        assert_eq!(f.y + f.height, (-458_f64 + 1440. - 288.).round());
    }

    #[test]
    fn small_displays_keep_it_inside() {
        let tiny = Rect::new(100., 50., 600., 300.);
        let f = quick_ask_frame(tiny, QUICK_ASK_SIZE);
        assert_eq!((f.x, f.width), (100., 600.));
        assert_eq!((f.y, f.height), (50., 300.));
    }

    #[test]
    fn the_setup_window_opens_centred_at_its_height_at_most_the_visible_one() {
        let opened = Rect::new(0., 0., 640., 640.);
        let f = setup_frame(LAPTOP_VISIBLE, opened, 731., false);
        assert_eq!((f.width, f.height), (640., 731.));
        assert_eq!((f.x, f.y), (436., 109.)); // (1512 - 640) / 2, (949 - 731) / 2
        let short = Rect::new(0., 0., 1280., 700.);
        let f = setup_frame(short, opened, 731., false);
        assert_eq!((f.y, f.height), (0., 700.));
    }

    #[test]
    fn on_screen_the_setup_window_keeps_its_top_edge_inside_the_visible_area() {
        let on = Rect::new(436., 200., 640., 640.);
        // Grows downward from its top edge (840).
        let f = setup_frame(LAPTOP_VISIBLE, on, 731., true);
        assert_eq!((f.x, f.y + f.height, f.height), (436., 840., 731.));
        // Near the bottom: moved up rather than off the visible area.
        let low = Rect::new(436., 20., 640., 640.);
        let f = setup_frame(LAPTOP_VISIBLE, low, 731., true);
        assert_eq!((f.y, f.height), (0., 731.));
        // Near the top, shrinking: the top edge stays.
        let high = Rect::new(436., 309., 640., 640.);
        let f = setup_frame(LAPTOP_VISIBLE, high, 600., true);
        assert_eq!(f.y + f.height, 949.);
        // Moved onto a display with less room than it is tall: as tall as
        // that display's visible area, and inside it.
        let short = Rect::new(1512., 0., 1280., 560.);
        let moved = Rect::new(1600., 100., 640., 747.);
        let f = setup_frame(short, moved, 747., true);
        assert_eq!((f.x, f.y, f.height), (1600., 0., 560.));
    }

    #[test]
    fn picks_the_display_under_the_pointer() {
        let frames = [LAPTOP, LEFT];
        assert_eq!(display_under(&frames, (700., 500.)), Some(0));
        assert_eq!(display_under(&frames, (-100., 900.)), Some(1));
        // Off every display (between two): the nearest one.
        assert_eq!(display_under(&frames, (1600., 500.)), Some(0));
        assert_eq!(display_under(&[], (0., 0.)), None);
    }
}
