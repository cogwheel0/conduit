//! The menu-bar item (`tray-icon`, pinned exactly): Open Conduit, New Chat,
//! Quick Ask, Settings…, Quit. It shows while "Close to menu bar" is on, and
//! during a voice call, which it shows: the time beside the icon, and the
//! call's state, Show Call and End Call at the top of its menu.
//!
//! The icon is the brand mark (`components/assets/brand/mark.svg`: an open
//! C tilted towards a dot) drawn as a monochrome template image, so macOS
//! tints it for the menu bar's appearance.

use tray_icon::menu::accelerator::Accelerator;
use tray_icon::menu::{Menu, MenuEvent, MenuId, MenuItem, PredefinedMenuItem};

use crate::keymap::KeyStroke;
use tray_icon::{Icon, TrayIcon, TrayIconBuilder};

/// What a menu item asks for.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TrayCommand {
    Open,
    NewChat,
    QuickAsk,
    Settings,
    Quit,
    /// The call's chat, with its strip open.
    ShowCall,
    EndCall,
}

impl TrayCommand {
    const ALL: [Self; 5] = [
        Self::Open,
        Self::NewChat,
        Self::QuickAsk,
        Self::Settings,
        Self::Quit,
    ];

    fn id(self) -> &'static str {
        match self {
            Self::Open => "conduit-open",
            Self::NewChat => "conduit-new-chat",
            Self::QuickAsk => "conduit-quick-ask",
            Self::Settings => "conduit-settings",
            Self::Quit => "conduit-quit",
            Self::ShowCall => "conduit-show-call",
            Self::EndCall => "conduit-end-call",
        }
    }

    /// The command a menu event names.
    pub fn from_event(event: &MenuEvent) -> Option<Self> {
        Self::ALL
            .into_iter()
            .chain([Self::ShowCall, Self::EndCall])
            .find(|c| event.id == MenuId::new(c.id()))
    }
}

/// The menu's words, localized by the caller.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TrayLabels {
    pub open: String,
    pub new_chat: String,
    pub quick_ask: String,
    pub settings: String,
    pub quit: String,
    /// The item's tooltip and accessibility title.
    pub tooltip: String,
    /// The chords the menu shows beside New Chat and Quick Ask (they follow
    /// Settings › Keyboard and the Quick Ask shortcut).
    pub new_chat_keys: Option<KeyStroke>,
    pub quick_ask_keys: Option<KeyStroke>,
}

/// A voice call, as the item shows it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TrayCall {
    /// "Listening · 1:23", the menu's first line.
    pub status: String,
    /// "1:23", beside the icon.
    pub time: String,
    pub show: String,
    pub end: String,
}

/// The call's lines at the top of the menu.
struct CallItems {
    status: MenuItem,
    show: MenuItem,
    end: MenuItem,
    separator: PredefinedMenuItem,
}

pub struct MenuBarItem {
    tray: TrayIcon,
    menu: Menu,
    items: Vec<(TrayCommand, MenuItem)>,
    call: Option<CallItems>,
}

impl MenuBarItem {
    /// Installs the item (main thread).
    pub fn new(labels: &TrayLabels) -> Result<Self, String> {
        let menu = Menu::new();
        let items: Vec<(TrayCommand, MenuItem)> = TrayCommand::ALL
            .into_iter()
            .map(|c| {
                let item =
                    MenuItem::with_id(c.id(), label(labels, c), true, accelerator(labels, c));
                (c, item)
            })
            .collect();
        for (i, (command, item)) in items.iter().enumerate() {
            // Settings… and Quit each start a group, as the app menu has them.
            if matches!(command, TrayCommand::Settings | TrayCommand::Quit) && i > 0 {
                menu.append(&PredefinedMenuItem::separator())
                    .map_err(|e| e.to_string())?;
            }
            menu.append(item).map_err(|e| e.to_string())?;
        }
        let icon =
            Icon::from_rgba(template_icon(ICON_PX), ICON_PX, ICON_PX).map_err(|e| e.to_string())?;
        let tray = TrayIconBuilder::new()
            .with_id("conduit")
            .with_menu(Box::new(menu.clone()))
            .with_icon_templated(icon)
            .with_tooltip(&labels.tooltip)
            .build()
            .map_err(|e| e.to_string())?;
        Ok(Self {
            tray,
            menu,
            items,
            call: None,
        })
    }

    /// Shows the call `call` (its time beside the icon, its lines at the
    /// top of the menu), or that there is none.
    pub fn set_call(&mut self, call: Option<&TrayCall>) {
        match (call, self.call.as_ref()) {
            (Some(call), Some(items)) => {
                items.status.set_text(&call.status);
                items.show.set_text(&call.show);
                items.end.set_text(&call.end);
                self.tray.set_title(Some(&call.time));
            }
            (Some(call), None) => {
                let items = CallItems {
                    status: MenuItem::with_id("conduit-call-status", &call.status, false, None),
                    show: MenuItem::with_id(TrayCommand::ShowCall.id(), &call.show, true, None),
                    end: MenuItem::with_id(TrayCommand::EndCall.id(), &call.end, true, None),
                    separator: PredefinedMenuItem::separator(),
                };
                let _ = self.menu.insert(&items.status, 0);
                let _ = self.menu.insert(&items.show, 1);
                let _ = self.menu.insert(&items.end, 2);
                let _ = self.menu.insert(&items.separator, 3);
                self.tray.set_title(Some(&call.time));
                self.call = Some(items);
            }
            (None, Some(_)) => {
                if let Some(items) = self.call.take() {
                    let _ = self.menu.remove(&items.status);
                    let _ = self.menu.remove(&items.show);
                    let _ = self.menu.remove(&items.end);
                    let _ = self.menu.remove(&items.separator);
                }
                self.tray.set_title(None::<&str>);
            }
            (None, None) => {}
        }
    }

    /// Whether it shows a call (E2E).
    pub fn shows_call(&self) -> bool {
        self.call.is_some()
    }

    /// New words (the language changed) or chords (a shortcut changed).
    pub fn relabel(&self, labels: &TrayLabels) {
        for (command, item) in &self.items {
            item.set_text(label(labels, *command));
            let _ = item.set_accelerator(accelerator(labels, *command));
        }
        let _ = self.tray.set_tooltip(Some(&labels.tooltip));
    }

    /// Whether the item is on screen (it has a frame in the menu bar).
    pub fn is_visible(&self) -> bool {
        self.tray.rect().is_some()
    }

    /// The item itself (reference-counted), to open its menu as a click
    /// does (`TrayIcon::show_menu`) outside any GPUI borrow: the menu's
    /// tracking loop holds the main thread (the capture harness).
    pub fn icon(&self) -> TrayIcon {
        self.tray.clone()
    }
}

/// The chord shown beside `command`, as the app's own menus show it: New
/// Chat and Quick Ask follow their shortcuts, Settings… is ⌘, and Quit ⌘Q.
fn accelerator(labels: &TrayLabels, command: TrayCommand) -> Option<Accelerator> {
    let stroke = match command {
        TrayCommand::Open | TrayCommand::ShowCall | TrayCommand::EndCall => return None,
        TrayCommand::NewChat => labels.new_chat_keys.clone()?,
        TrayCommand::QuickAsk => labels.quick_ask_keys.clone()?,
        TrayCommand::Settings => KeyStroke::new(",").primary(),
        TrayCommand::Quit => KeyStroke::new("q").primary(),
    };
    accelerator_text(&stroke)?.parse().ok()
}

/// `stroke` in the menu library's syntax (`Shift+Cmd+Space`), or `None`
/// for a key it cannot name.
pub fn accelerator_text(stroke: &KeyStroke) -> Option<String> {
    let key = match stroke.key.as_str() {
        " " | "space" => "Space".to_string(),
        "," => "Comma".to_string(),
        "." => "Period".to_string(),
        ";" => "Semicolon".to_string(),
        "/" => "Slash".to_string(),
        "escape" => "Escape".to_string(),
        "enter" => "Enter".to_string(),
        "backspace" => "Backspace".to_string(),
        "tab" => "Tab".to_string(),
        k if k.len() == 1 && k.chars().all(|c| c.is_ascii_alphanumeric()) => k.to_uppercase(),
        _ => return None,
    };
    let mut parts = vec![];
    if stroke.ctrl {
        parts.push("Control");
    }
    if stroke.alt {
        parts.push("Alt");
    }
    if stroke.shift {
        parts.push("Shift");
    }
    if stroke.primary {
        parts.push("Cmd");
    }
    Some(format!(
        "{}{}{key}",
        parts.join("+"),
        if parts.is_empty() { "" } else { "+" }
    ))
}

fn label(labels: &TrayLabels, command: TrayCommand) -> &str {
    match command {
        TrayCommand::Open => &labels.open,
        TrayCommand::NewChat => &labels.new_chat,
        TrayCommand::QuickAsk => &labels.quick_ask,
        TrayCommand::Settings => &labels.settings,
        TrayCommand::Quit => &labels.quit,
        TrayCommand::ShowCall | TrayCommand::EndCall => "",
    }
}

/// The icon's size in pixels: an 18 pt menu-bar icon at 2×.
pub const ICON_PX: u32 = 36;

/// The mark as RGBA: black, with coverage in alpha (a template image).
///
/// `mark.svg` in a 24-unit box: an arc of radius 8 around (12.01, 11.93)
/// from (17.6, 6.2) the long way round to (19.4, 15), stroked 2.4 wide with
/// round caps, and a dot of radius 2 at (16.4, 11.6). The box's own margin
/// (about 3 units a side) is the icon's padding.
pub fn template_icon(size: u32) -> Vec<u8> {
    const CENTER: (f64, f64) = (12.01, 11.93);
    const RADIUS: f64 = 8.;
    const HALF_STROKE: f64 = 1.2;
    const START: (f64, f64) = (17.6, 6.2);
    const END: (f64, f64) = (19.4, 15.);
    const DOT: (f64, f64, f64) = (16.4, 11.6, 2.);
    let angle = |(x, y): (f64, f64)| (y - CENTER.1).atan2(x - CENTER.0);
    // The arc runs from START towards decreasing angles (SVG sweep 0) to
    // END: it covers every angle except the gap (start, end).
    let (gap_from, gap_to) = (angle(START), angle(END));
    let in_gap = |a: f64| a > gap_from && a < gap_to;
    let dist =
        |(x, y): (f64, f64), (px, py): (f64, f64)| ((x - px).powi(2) + (y - py).powi(2)).sqrt();
    let coverage_at = |p: (f64, f64)| -> bool {
        let on_arc = if in_gap(angle(p)) {
            dist(p, START).min(dist(p, END)) <= HALF_STROKE
        } else {
            (dist(p, CENTER) - RADIUS).abs() <= HALF_STROKE
        };
        on_arc || dist(p, (DOT.0, DOT.1)) <= DOT.2
    };
    const SAMPLES: u32 = 4;
    let scale = 24. / f64::from(size);
    let mut rgba = vec![0u8; (size * size * 4) as usize];
    for py in 0..size {
        for px in 0..size {
            let mut hits = 0;
            for sy in 0..SAMPLES {
                for sx in 0..SAMPLES {
                    let x = (f64::from(px) + (f64::from(sx) + 0.5) / f64::from(SAMPLES)) * scale;
                    let y = (f64::from(py) + (f64::from(sy) + 0.5) / f64::from(SAMPLES)) * scale;
                    if coverage_at((x, y)) {
                        hits += 1;
                    }
                }
            }
            let alpha = (hits * 255 / (SAMPLES * SAMPLES)) as u8;
            rgba[((py * size + px) * 4 + 3) as usize] = alpha;
        }
    }
    rgba
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_menu_shows_the_chords_the_app_menus_do() {
        let text = |s: KeyStroke| accelerator_text(&s);
        assert_eq!(
            text(KeyStroke::new("n").primary()).as_deref(),
            Some("Cmd+N")
        );
        assert_eq!(
            text(KeyStroke::new(" ").primary().shift()).as_deref(),
            Some("Shift+Cmd+Space")
        );
        assert_eq!(
            text(KeyStroke::new(",").primary()).as_deref(),
            Some("Cmd+Comma")
        );
        assert_eq!(
            text(KeyStroke::new("s").primary().ctrl()).as_deref(),
            Some("Control+Cmd+S")
        );
        assert_eq!(text(KeyStroke::new("arrowup")), None);
        // Every one the menu uses parses.
        for s in [
            KeyStroke::new("n").primary(),
            KeyStroke::new(" ").primary().shift(),
            KeyStroke::new(",").primary(),
            KeyStroke::new("q").primary(),
        ] {
            let parsed: Result<Accelerator, _> = text(s.clone()).unwrap().parse();
            assert!(parsed.is_ok(), "{s:?}");
        }
    }

    fn alpha(icon: &[u8], size: u32, x: u32, y: u32) -> u8 {
        icon[((y * size + x) * 4 + 3) as usize]
    }

    #[test]
    fn the_icon_is_the_mark_in_black_on_clear() {
        let icon = template_icon(ICON_PX);
        assert_eq!(icon.len(), (ICON_PX * ICON_PX * 4) as usize);
        // Only alpha carries the shape: a template image is black.
        assert!(icon.chunks(4).all(|p| p[0] == 0 && p[1] == 0 && p[2] == 0));
        // Corners are clear; the stroke and the dot are drawn.
        assert_eq!(alpha(&icon, ICON_PX, 0, 0), 0);
        assert_eq!(alpha(&icon, ICON_PX, ICON_PX - 1, ICON_PX - 1), 0);
        let inked = icon.chunks(4).filter(|p| p[3] > 128).count();
        let share = inked as f64 / f64::from(ICON_PX * ICON_PX);
        assert!((0.12..0.35).contains(&share), "{share}");
        // The C is open on the right: the left edge of the ring is inked,
        // the mouth (between the arc's ends, right of the dot) is not.
        let mid = ICON_PX / 2;
        assert!((0..ICON_PX / 3).any(|x| alpha(&icon, ICON_PX, x, mid) > 200));
        assert!(alpha(&icon, ICON_PX, ICON_PX - 4, mid) < 50);
    }
}
