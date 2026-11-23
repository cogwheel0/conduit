//! Where each chrome control sits, and the room the headers leave for the
//! window's own controls.

use gpui_kit::{Decorations, WindowButtonLayout};

use super::ChromeStyle;

/// A window control.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum WindowButton {
    Minimize,
    Maximize,
    Close,
}

/// The window controls at each end of the header bars, as the desktop's
/// `button-layout` places them (GNOME's
/// `org.gnome.desktop.wm.preferences`, which GTK reads as
/// `gtk-decoration-layout`).
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct ButtonLayout {
    pub start: Vec<WindowButton>,
    pub end: Vec<WindowButton>,
}

impl ButtonLayout {
    /// Windows' caption buttons: minimize, maximize and close at the end.
    pub fn windows() -> Self {
        Self {
            start: vec![],
            end: vec![
                WindowButton::Minimize,
                WindowButton::Maximize,
                WindowButton::Close,
            ],
        }
    }

    /// GNOME's own default, `appmenu:close`.
    pub fn gnome() -> Self {
        Self::parse("appmenu:close")
    }

    /// Reads a `button-layout` string as GTK and Mutter do: the names before
    /// the colon go at the start, those after it at the end, and with no
    /// colon all of them at the start. Names other than the three controls
    /// (`appmenu`, `menu`, `icon`, `spacer`) and repeats are skipped.
    pub fn parse(layout: &str) -> Self {
        let mut seen = vec![];
        let mut side = |names: Option<&str>| -> Vec<WindowButton> {
            names
                .unwrap_or_default()
                .split(',')
                .filter_map(|name| match name.trim() {
                    "minimize" => Some(WindowButton::Minimize),
                    "maximize" => Some(WindowButton::Maximize),
                    "close" => Some(WindowButton::Close),
                    _ => None,
                })
                .filter(|b| {
                    let first = !seen.contains(b);
                    seen.push(*b);
                    first
                })
                .collect()
        };
        let mut halves = layout.splitn(2, ':');
        let start = side(halves.next());
        let end = side(halves.next());
        Self { start, end }
    }

    /// The layout GPUI read from the settings portal, keeping only the
    /// controls the window manager offers (a tiling one may offer neither
    /// minimize nor maximize; close is always offered).
    pub fn from_gpui(layout: WindowButtonLayout, minimize: bool, maximize: bool) -> Self {
        let side = |buttons: &[Option<gpui_kit::WindowButton>]| -> Vec<WindowButton> {
            buttons
                .iter()
                .flatten()
                .filter_map(|b| match b {
                    gpui_kit::WindowButton::Minimize => minimize.then_some(WindowButton::Minimize),
                    gpui_kit::WindowButton::Maximize => maximize.then_some(WindowButton::Maximize),
                    gpui_kit::WindowButton::Close => Some(WindowButton::Close),
                })
                .collect()
        };
        Self {
            start: side(&layout.left),
            end: side(&layout.right),
        }
    }

    pub fn is_empty(&self) -> bool {
        self.start.is_empty() && self.end.is_empty()
    }
}

/// One of the two headers: the sidebar's, or the content's (the chat
/// toolbar, or another area's).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Header {
    Sidebar,
    Content,
}

/// An end of a header.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Edge {
    Start,
    End,
}

/// Where a control sits: a header and its end.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Slot(pub Header, pub Edge);

/// Where the chrome's controls sit, by style and whether the sidebar shows.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Placement {
    /// ☰.
    pub main_menu: Slot,
    pub sidebar_toggle: Slot,
    pub new_chat: Slot,
    /// The window controls the layout puts at the start, and at the end.
    pub start_controls: Slot,
    pub end_controls: Slot,
}

impl Placement {
    pub fn of(style: ChromeStyle, sidebar_shown: bool) -> Self {
        use {Edge::*, Header::*};
        // Without the sidebar the content's header takes everything; New
        // Chat goes to its end, as the Mac's toolbar takes it.
        if !sidebar_shown {
            return Self {
                main_menu: Slot(
                    Content,
                    match style {
                        ChromeStyle::Windows => Start,
                        ChromeStyle::Gnome => End,
                    },
                ),
                sidebar_toggle: Slot(Content, Start),
                new_chat: Slot(Content, End),
                start_controls: Slot(Content, Start),
                end_controls: Slot(Content, End),
            };
        }
        match style {
            // ☰ in the traffic lights' place, the toggle after it, New
            // Chat at the sidebar header's end, as the Mac has them.
            ChromeStyle::Windows => Self {
                main_menu: Slot(Sidebar, Start),
                sidebar_toggle: Slot(Sidebar, Start),
                new_chat: Slot(Sidebar, End),
                start_controls: Slot(Sidebar, Start),
                end_controls: Slot(Content, End),
            },
            // libadwaita's split view: New Chat, the app's name and the
            // primary menu over the sidebar; the toggle leads the content.
            ChromeStyle::Gnome => Self {
                main_menu: Slot(Sidebar, End),
                sidebar_toggle: Slot(Content, Start),
                new_chat: Slot(Sidebar, Start),
                start_controls: Slot(Sidebar, Start),
                end_controls: Slot(Content, End),
            },
        }
    }
}

/// Windows' caption button: as wide as Windows 11 draws them, as tall as the
/// toolbar.
pub const CAPTION_BUTTON_WIDTH: f32 = 46.;
/// ☰ (and the other header buttons drawn with it).
pub const MENU_BUTTON: f32 = 32.;
/// A GNOME window control's circle, and the room each takes in a row.
pub const GNOME_CONTROL: f32 = 24.;
pub const GNOME_CONTROL_STEP: f32 = 34.;
/// From the window's edge to the first control drawn at it.
pub const CHROME_EDGE: f32 = 8.;

/// What the window's own controls take at its edges, over whichever header
/// is there (points); the headers start and end their own controls past it,
/// as they leave the traffic lights' room on the Mac.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Rooms {
    pub start: f32,
    pub end: f32,
}

impl Rooms {
    /// `decorated`: the app draws the window controls (client-side
    /// decorations); under a window manager's frame it draws none.
    pub fn of(
        style: ChromeStyle,
        buttons: &ButtonLayout,
        sidebar_shown: bool,
        decorated: bool,
    ) -> Self {
        let row = |n: usize| {
            if n == 0 {
                0.
            } else {
                CHROME_EDGE + n as f32 * GNOME_CONTROL_STEP
            }
        };
        match style {
            ChromeStyle::Windows => Self {
                start: CHROME_EDGE + MENU_BUTTON,
                end: if decorated {
                    buttons.end.len() as f32 * CAPTION_BUTTON_WIDTH
                } else {
                    0.
                },
            },
            ChromeStyle::Gnome => {
                let (start, end) = if decorated {
                    (row(buttons.start.len()), row(buttons.end.len()))
                } else {
                    (0., 0.)
                };
                // ☰ joins the content's end, just inside the controls.
                let menu = if sidebar_shown {
                    0.
                } else if end > 0. {
                    MENU_BUTTON + 4.
                } else {
                    CHROME_EDGE + MENU_BUTTON
                };
                Self {
                    start,
                    end: end + menu,
                }
            }
        }
    }
}

/// libadwaita's window corner radius.
pub const GNOME_CORNER_RADIUS: f32 = 12.;

/// Each corner's radius (points), clockwise from the top left.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Corners {
    pub top_left: f32,
    pub top_right: f32,
    pub bottom_right: f32,
    pub bottom_left: f32,
}

impl Corners {
    /// The corners the app rounds. Windows rounds the window itself; a
    /// GNOME-style window rounds its own unless the corner meets a tiled
    /// edge, or the window is maximized or under a window manager's frame.
    pub fn of(style: ChromeStyle, decorations: Decorations, maximized: bool) -> Self {
        let Decorations::Client { tiling } = decorations else {
            return Self::default();
        };
        if style == ChromeStyle::Windows || maximized {
            return Self::default();
        }
        let r = |square: bool| if square { 0. } else { GNOME_CORNER_RADIUS };
        Self {
            top_left: r(tiling.top || tiling.left),
            top_right: r(tiling.top || tiling.right),
            bottom_right: r(tiling.bottom || tiling.right),
            bottom_left: r(tiling.bottom || tiling.left),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use WindowButton::*;
    use gpui_kit::Tiling;

    #[test]
    fn button_layout_reads_both_ends_as_gtk_does() {
        assert_eq!(
            ButtonLayout::parse("appmenu:minimize,maximize,close"),
            ButtonLayout {
                start: vec![],
                end: vec![Minimize, Maximize, Close],
            }
        );
        // macOS-like: the controls at the start, the window menu at the end.
        assert_eq!(
            ButtonLayout::parse("close,minimize,maximize:appmenu"),
            ButtonLayout {
                start: vec![Close, Minimize, Maximize],
                end: vec![],
            }
        );
        // GNOME's default, and spaces around names.
        assert_eq!(
            ButtonLayout::parse(" appmenu : close "),
            ButtonLayout {
                start: vec![],
                end: vec![Close],
            }
        );
        // Split across both ends.
        assert_eq!(
            ButtonLayout::parse("close:minimize,maximize"),
            ButtonLayout {
                start: vec![Close],
                end: vec![Minimize, Maximize],
            }
        );
    }

    #[test]
    fn button_layout_without_a_colon_puts_everything_at_the_start() {
        assert_eq!(
            ButtonLayout::parse("close,maximize"),
            ButtonLayout {
                start: vec![Close, Maximize],
                end: vec![],
            }
        );
    }

    #[test]
    fn button_layout_skips_unknown_names_repeats_and_empties() {
        assert_eq!(
            ButtonLayout::parse("icon,spacer,close,close:menu,minimize,close,,bogus"),
            ButtonLayout {
                start: vec![Close],
                end: vec![Minimize],
            }
        );
        assert!(ButtonLayout::parse("").is_empty());
        assert!(ButtonLayout::parse(":").is_empty());
        assert!(ButtonLayout::parse("appmenu:").is_empty());
    }

    #[test]
    fn defaults_follow_each_desktop() {
        assert_eq!(
            ButtonLayout::windows(),
            ButtonLayout {
                start: vec![],
                end: vec![Minimize, Maximize, Close],
            }
        );
        assert_eq!(
            ButtonLayout::gnome(),
            ButtonLayout {
                start: vec![],
                end: vec![Close],
            }
        );
    }

    #[test]
    fn gpuis_layout_keeps_only_what_the_window_manager_offers() {
        let gpui = WindowButtonLayout {
            left: [Some(Close), None, None].map(|b| b.map(to_gpui)),
            right: [Some(Minimize), Some(Maximize), None].map(|b| b.map(to_gpui)),
        };
        assert_eq!(
            ButtonLayout::from_gpui(gpui, true, true),
            ButtonLayout {
                start: vec![Close],
                end: vec![Minimize, Maximize],
            }
        );
        // A tiling window manager: no minimize, no maximize.
        assert_eq!(
            ButtonLayout::from_gpui(gpui, false, false),
            ButtonLayout {
                start: vec![Close],
                end: vec![],
            }
        );
    }

    fn to_gpui(b: WindowButton) -> gpui_kit::WindowButton {
        match b {
            Minimize => gpui_kit::WindowButton::Minimize,
            Maximize => gpui_kit::WindowButton::Maximize,
            Close => gpui_kit::WindowButton::Close,
        }
    }

    const SIDEBAR_START: Slot = Slot(Header::Sidebar, Edge::Start);
    const SIDEBAR_END: Slot = Slot(Header::Sidebar, Edge::End);
    const CONTENT_START: Slot = Slot(Header::Content, Edge::Start);
    const CONTENT_END: Slot = Slot(Header::Content, Edge::End);

    #[test]
    fn windows_moves_the_menu_and_toggle_to_the_chat_toolbar_when_the_sidebar_hides() {
        let shown = Placement::of(ChromeStyle::Windows, true);
        assert_eq!(shown.main_menu, SIDEBAR_START);
        assert_eq!(shown.sidebar_toggle, SIDEBAR_START);
        assert_eq!(shown.new_chat, SIDEBAR_END);
        assert_eq!(shown.end_controls, CONTENT_END);
        let hidden = Placement::of(ChromeStyle::Windows, false);
        assert_eq!(hidden.main_menu, CONTENT_START);
        assert_eq!(hidden.sidebar_toggle, CONTENT_START);
        // As on the Mac: the toolbar takes New Chat at its end.
        assert_eq!(hidden.new_chat, CONTENT_END);
        assert_eq!(hidden.end_controls, CONTENT_END);
    }

    #[test]
    fn gnome_keeps_the_toggle_in_the_chat_header_and_moves_the_menu_there_when_hidden() {
        let shown = Placement::of(ChromeStyle::Gnome, true);
        assert_eq!(shown.new_chat, SIDEBAR_START);
        assert_eq!(shown.main_menu, SIDEBAR_END);
        assert_eq!(shown.sidebar_toggle, CONTENT_START);
        // Controls the layout puts at the start sit in the sidebar's header
        // bar, as libadwaita's split view draws them.
        assert_eq!(shown.start_controls, SIDEBAR_START);
        assert_eq!(shown.end_controls, CONTENT_END);
        let hidden = Placement::of(ChromeStyle::Gnome, false);
        assert_eq!(hidden.main_menu, CONTENT_END);
        assert_eq!(hidden.sidebar_toggle, CONTENT_START);
        assert_eq!(hidden.new_chat, CONTENT_END);
        assert_eq!(hidden.start_controls, CONTENT_START);
        assert_eq!(hidden.end_controls, CONTENT_END);
    }

    #[test]
    fn rooms_hold_the_window_controls_and_windows_menu() {
        let windows = Rooms::of(ChromeStyle::Windows, &ButtonLayout::windows(), true, true);
        assert_eq!(windows.start, CHROME_EDGE + MENU_BUTTON);
        assert_eq!(windows.end, 3. * CAPTION_BUTTON_WIDTH);
        // Hidden or shown, ☰ keeps the window's leading corner.
        assert_eq!(
            Rooms::of(ChromeStyle::Windows, &ButtonLayout::windows(), false, true),
            windows
        );
        let split = ButtonLayout::parse("close:minimize,maximize");
        let shown = Rooms::of(ChromeStyle::Gnome, &split, true, true);
        assert_eq!(shown.start, CHROME_EDGE + GNOME_CONTROL_STEP);
        assert_eq!(shown.end, CHROME_EDGE + 2. * GNOME_CONTROL_STEP);
        // With the sidebar hidden ☰ joins the controls at the end.
        let hidden = Rooms::of(ChromeStyle::Gnome, &split, false, true);
        assert_eq!(hidden.end, shown.end + MENU_BUTTON + 4.);
        // Under the window manager's frame there are no controls to make
        // room for.
        let framed = Rooms::of(ChromeStyle::Gnome, &split, true, false);
        assert_eq!(framed, Rooms::default());
        let framed_hidden = Rooms::of(ChromeStyle::Gnome, &split, false, false);
        assert_eq!(framed_hidden.start, 0.);
        assert_eq!(framed_hidden.end, CHROME_EDGE + MENU_BUTTON);
    }

    #[test]
    fn gnome_corners_round_unless_tiled_maximized_or_framed() {
        let free = Decorations::Client {
            tiling: Tiling::default(),
        };
        let round = Corners {
            top_left: GNOME_CORNER_RADIUS,
            top_right: GNOME_CORNER_RADIUS,
            bottom_right: GNOME_CORNER_RADIUS,
            bottom_left: GNOME_CORNER_RADIUS,
        };
        assert_eq!(Corners::of(ChromeStyle::Gnome, free, false), round);
        // Snapped to the left half: the left corners meet the screen's edge
        // and the top and bottom ones the panel and screen bottom.
        let left_half = Decorations::Client {
            tiling: Tiling {
                top: true,
                left: true,
                bottom: true,
                right: false,
            },
        };
        assert_eq!(
            Corners::of(ChromeStyle::Gnome, left_half, false),
            Corners::default()
        );
        // Tiled at the left only: the right corners stay round.
        let left_only = Decorations::Client {
            tiling: Tiling {
                left: true,
                ..Tiling::default()
            },
        };
        assert_eq!(
            Corners::of(ChromeStyle::Gnome, left_only, false),
            Corners {
                top_left: 0.,
                top_right: GNOME_CORNER_RADIUS,
                bottom_right: GNOME_CORNER_RADIUS,
                bottom_left: 0.,
            }
        );
        assert_eq!(
            Corners::of(ChromeStyle::Gnome, free, true),
            Corners::default()
        );
        assert_eq!(
            Corners::of(ChromeStyle::Gnome, Decorations::Server, false),
            Corners::default()
        );
        // Windows 11 rounds the window itself.
        assert_eq!(
            Corners::of(ChromeStyle::Windows, free, false),
            Corners::default()
        );
    }
}
