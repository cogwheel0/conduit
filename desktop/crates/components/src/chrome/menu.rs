//! The drawn menus' items, how they grey, and how the keyboard moves
//! through them.

use gpui_kit::{Action, MenuItem, SharedString};

use super::keys::MenuKey;

/// One row of a drawn menu.
pub enum ChromeMenuItem {
    Action {
        label: SharedString,
        action: Box<dyn Action>,
        /// The chord, as the app writes it (Ctrl+N).
        shortcut: Option<SharedString>,
        checked: bool,
        disabled: bool,
    },
    Submenu {
        label: SharedString,
        items: Vec<ChromeMenuItem>,
        disabled: bool,
    },
    Separator,
    /// GNOME's zoom row: zoom out, the size (back to the actual size), zoom
    /// in. It acts without closing the menu.
    Zoom(ZoomRow),
}

/// A part of the zoom row.
pub struct ZoomPart {
    /// What a screen reader says for it.
    pub label: SharedString,
    pub action: Box<dyn Action>,
    pub disabled: bool,
}

pub struct ZoomRow {
    /// The size, as shown between the buttons ("100%").
    pub level: SharedString,
    pub out: ZoomPart,
    pub reset: ZoomPart,
    pub zoom_in: ZoomPart,
}

impl ZoomRow {
    pub fn parts(&self) -> [&ZoomPart; 3] {
        [&self.out, &self.reset, &self.zoom_in]
    }
}

impl Clone for ZoomPart {
    fn clone(&self) -> Self {
        Self {
            label: self.label.clone(),
            action: self.action.boxed_clone(),
            disabled: self.disabled,
        }
    }
}

impl Clone for ZoomRow {
    fn clone(&self) -> Self {
        Self {
            level: self.level.clone(),
            out: self.out.clone(),
            reset: self.reset.clone(),
            zoom_in: self.zoom_in.clone(),
        }
    }
}

impl Clone for ChromeMenuItem {
    fn clone(&self) -> Self {
        match self {
            Self::Action {
                label,
                action,
                shortcut,
                checked,
                disabled,
            } => Self::Action {
                label: label.clone(),
                action: action.boxed_clone(),
                shortcut: shortcut.clone(),
                checked: *checked,
                disabled: *disabled,
            },
            Self::Submenu {
                label,
                items,
                disabled,
            } => Self::Submenu {
                label: label.clone(),
                items: items.clone(),
                disabled: *disabled,
            },
            Self::Separator => Self::Separator,
            Self::Zoom(row) => Self::Zoom(row.clone()),
        }
    }
}

impl std::fmt::Debug for ChromeMenuItem {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Action {
                label,
                action,
                shortcut,
                checked,
                disabled,
            } => f
                .debug_struct("Action")
                .field("label", label)
                .field("action", &action.name())
                .field("shortcut", shortcut)
                .field("checked", checked)
                .field("disabled", disabled)
                .finish(),
            Self::Submenu {
                label,
                items,
                disabled,
            } => f
                .debug_struct("Submenu")
                .field("label", label)
                .field("items", items)
                .field("disabled", disabled)
                .finish(),
            Self::Separator => f.write_str("Separator"),
            Self::Zoom(row) => f.debug_tuple("Zoom").field(&row.level).finish(),
        }
    }
}

impl ChromeMenuItem {
    pub fn action(label: impl Into<SharedString>, action: impl Action) -> Self {
        Self::Action {
            label: label.into(),
            action: Box::new(action),
            shortcut: None,
            checked: false,
            disabled: false,
        }
    }

    pub fn submenu(label: impl Into<SharedString>, items: Vec<ChromeMenuItem>) -> Self {
        Self::Submenu {
            label: label.into(),
            items,
            disabled: false,
        }
    }

    pub fn label(&self) -> Option<&SharedString> {
        match self {
            Self::Action { label, .. } | Self::Submenu { label, .. } => Some(label),
            Self::Zoom(row) => Some(&row.level),
            Self::Separator => None,
        }
    }

    pub fn is_disabled(&self) -> bool {
        match self {
            Self::Action { disabled, .. } | Self::Submenu { disabled, .. } => *disabled,
            Self::Zoom(row) => row.parts().iter().all(|p| p.disabled),
            Self::Separator => true,
        }
    }

    /// A row the keyboard stops on.
    pub fn is_selectable(&self) -> bool {
        !self.is_disabled()
    }
}

/// GPUI's menu items (the Mac's menus) as drawn rows: the system's own
/// submenus (Services) have no drawn form and go.
pub fn from_gpui(items: Vec<MenuItem>) -> Vec<ChromeMenuItem> {
    tidy(
        items
            .into_iter()
            .filter_map(|item| match item {
                MenuItem::Separator => Some(ChromeMenuItem::Separator),
                MenuItem::Action {
                    name,
                    action,
                    checked,
                    disabled,
                    ..
                } => Some(ChromeMenuItem::Action {
                    label: name,
                    action,
                    shortcut: None,
                    checked,
                    disabled,
                }),
                MenuItem::Submenu(menu) => Some(ChromeMenuItem::Submenu {
                    label: menu.name,
                    items: from_gpui(menu.items),
                    disabled: menu.disabled,
                }),
                MenuItem::SystemMenu(_) => None,
            })
            .collect(),
    )
}

/// Drops separators at either end and runs of them, as a menu with some
/// rows left out would otherwise show.
pub fn tidy(items: Vec<ChromeMenuItem>) -> Vec<ChromeMenuItem> {
    let mut out: Vec<ChromeMenuItem> = Vec::with_capacity(items.len());
    for item in items {
        let separator = matches!(item, ChromeMenuItem::Separator);
        if separator
            && out
                .last()
                .is_none_or(|l| matches!(l, ChromeMenuItem::Separator))
        {
            continue;
        }
        out.push(item);
    }
    if matches!(out.last(), Some(ChromeMenuItem::Separator)) {
        out.pop();
    }
    out
}

/// Greys each item the way AppKit greys the Mac's menus: an action item is
/// off when `available` says nothing would answer it (the app asks
/// `App::is_action_available`, as AppKit's validation does), as well as
/// when it is built off; a submenu is off when none of its items is on.
pub fn grey(
    items: Vec<ChromeMenuItem>,
    available: &mut dyn FnMut(&dyn Action) -> bool,
) -> Vec<ChromeMenuItem> {
    items
        .into_iter()
        .map(|item| match item {
            ChromeMenuItem::Action {
                label,
                action,
                shortcut,
                checked,
                disabled,
            } => {
                let disabled = disabled || !available(action.as_ref());
                ChromeMenuItem::Action {
                    label,
                    action,
                    shortcut,
                    checked,
                    disabled,
                }
            }
            ChromeMenuItem::Submenu {
                label,
                items,
                disabled,
            } => {
                let items = grey(items, available);
                let disabled = disabled || !items.iter().any(ChromeMenuItem::is_selectable);
                ChromeMenuItem::Submenu {
                    label,
                    items,
                    disabled,
                }
            }
            ChromeMenuItem::Zoom(mut row) => {
                for part in [&mut row.out, &mut row.reset, &mut row.zoom_in] {
                    part.disabled = part.disabled || !available(part.action.as_ref());
                }
                ChromeMenuItem::Zoom(row)
            }
            ChromeMenuItem::Separator => ChromeMenuItem::Separator,
        })
        .collect()
}

/// Writes each action item's chord, from `shortcut` (the first binding of
/// its action, as GPUI's Mac menus show it).
pub fn with_shortcuts(
    items: Vec<ChromeMenuItem>,
    shortcut: &mut dyn FnMut(&dyn Action) -> Option<SharedString>,
) -> Vec<ChromeMenuItem> {
    items
        .into_iter()
        .map(|item| match item {
            ChromeMenuItem::Action {
                label,
                action,
                checked,
                disabled,
                ..
            } => ChromeMenuItem::Action {
                shortcut: shortcut(action.as_ref()),
                label,
                action,
                checked,
                disabled,
            },
            ChromeMenuItem::Submenu {
                label,
                items,
                disabled,
            } => ChromeMenuItem::Submenu {
                label,
                items: with_shortcuts(items, shortcut),
                disabled,
            },
            other => other,
        })
        .collect()
}

/// The highlighted row in each open level: `path[0]` in the menu, then one
/// for each submenu opened from the row before it. The zoom row's
/// highlighted part is `part`.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Cursor {
    pub path: Vec<usize>,
    pub part: usize,
}

/// What a key did.
#[derive(Debug)]
pub enum Outcome {
    /// Nothing to do (a row that can't act, or no further to go).
    None,
    /// The highlight moved, or a submenu opened or closed.
    Moved,
    /// Run this; `keep_open` for the zoom row's parts.
    Activate {
        action: Box<dyn Action>,
        keep_open: bool,
    },
    Close,
}

impl Cursor {
    /// Opened from the keyboard: the first row is highlighted.
    pub fn opened_by_keyboard(items: &[ChromeMenuItem]) -> Self {
        Self {
            path: first(items).into_iter().collect(),
            part: 1,
        }
    }

    /// The rows shown at `level` (0: the menu itself).
    pub fn rows<'a>(
        &self,
        items: &'a [ChromeMenuItem],
        level: usize,
    ) -> Option<&'a [ChromeMenuItem]> {
        if self.path.len() < level {
            return None;
        }
        let mut rows = items;
        for &i in self.path.iter().take(level) {
            match rows.get(i)? {
                ChromeMenuItem::Submenu { items, .. } => rows = items,
                _ => return None,
            }
        }
        Some(rows)
    }

    /// How many levels are open: the menu, and the submenu of each
    /// highlighted submenu row.
    pub fn open_levels(&self, items: &[ChromeMenuItem]) -> usize {
        let mut levels = 1;
        while self.rows(items, levels).is_some() {
            levels += 1;
        }
        levels
    }

    /// The pointer is over `index` at `level`: it is highlighted, and the
    /// submenus past that level close (a submenu row opens its own).
    pub fn hover(&mut self, items: &[ChromeMenuItem], level: usize, index: usize) {
        let Some(rows) = self.rows(items, level) else {
            return;
        };
        if !rows.get(index).is_some_and(ChromeMenuItem::is_selectable) {
            return;
        }
        self.path.truncate(level);
        if self.path.len() == level {
            self.path.push(index);
            self.part = 1;
        }
    }

    pub fn key(&mut self, items: &[ChromeMenuItem], key: MenuKey) -> Outcome {
        let level = self.path.len().saturating_sub(1);
        let Some(rows) = self.rows(items, level) else {
            return Outcome::None;
        };
        let at = self.path.last().copied();
        let row = at.and_then(|i| rows.get(i));
        let moved = |cursor: &mut Self, to: Option<usize>| match to {
            Some(i) => {
                if cursor.path.is_empty() {
                    cursor.path.push(i);
                } else if let Some(last) = cursor.path.last_mut() {
                    *last = i;
                }
                cursor.part = 1;
                Outcome::Moved
            }
            None => Outcome::None,
        };
        match key {
            MenuKey::Down => moved(self, step(rows, at, true)),
            MenuKey::Up => moved(self, step(rows, at, false)),
            MenuKey::First => moved(self, first(rows)),
            MenuKey::Last => moved(self, last(rows)),
            MenuKey::Right => match row {
                Some(ChromeMenuItem::Zoom(_)) => {
                    self.part = (self.part + 1).min(2);
                    Outcome::Moved
                }
                Some(ChromeMenuItem::Submenu {
                    items: sub,
                    disabled: false,
                    ..
                }) => self.open(sub),
                _ => Outcome::None,
            },
            MenuKey::Left => match row {
                Some(ChromeMenuItem::Zoom(_)) => {
                    self.part = self.part.saturating_sub(1);
                    Outcome::Moved
                }
                _ if self.path.len() > 1 => {
                    self.path.pop();
                    Outcome::Moved
                }
                _ => Outcome::None,
            },
            MenuKey::Activate => match row {
                Some(ChromeMenuItem::Action {
                    action,
                    disabled: false,
                    ..
                }) => Outcome::Activate {
                    action: action.boxed_clone(),
                    keep_open: false,
                },
                Some(ChromeMenuItem::Submenu {
                    items: sub,
                    disabled: false,
                    ..
                }) => self.open(sub),
                Some(ChromeMenuItem::Zoom(zoom)) => match zoom.parts().get(self.part) {
                    Some(part) if !part.disabled => Outcome::Activate {
                        action: part.action.boxed_clone(),
                        keep_open: true,
                    },
                    _ => Outcome::None,
                },
                _ => Outcome::None,
            },
            MenuKey::Back if self.path.len() > 1 => {
                self.path.pop();
                Outcome::Moved
            }
            MenuKey::Back | MenuKey::Close => Outcome::Close,
        }
    }

    fn open(&mut self, sub: &[ChromeMenuItem]) -> Outcome {
        match first(sub) {
            Some(i) => {
                self.path.push(i);
                self.part = 1;
                Outcome::Moved
            }
            None => Outcome::None,
        }
    }
}

fn first(rows: &[ChromeMenuItem]) -> Option<usize> {
    rows.iter().position(ChromeMenuItem::is_selectable)
}

fn last(rows: &[ChromeMenuItem]) -> Option<usize> {
    rows.iter().rposition(ChromeMenuItem::is_selectable)
}

/// The next (or previous) row the keyboard stops on, wrapping; from no
/// highlight, the first (or last).
fn step(rows: &[ChromeMenuItem], from: Option<usize>, down: bool) -> Option<usize> {
    let Some(from) = from else {
        return if down { first(rows) } else { last(rows) };
    };
    let n = rows.len();
    (1..=n)
        .map(|k| {
            if down {
                (from + k) % n
            } else {
                (from + n - k) % n
            }
        })
        .find(|&i| rows[i].is_selectable())
}

#[cfg(test)]
mod tests {
    use super::*;
    use gpui_kit::{Menu, OsAction, SystemMenuType, actions};

    actions!(chrome_menu_test, [One, Two, Three, Four, Out, Reset, In]);

    fn shape(items: &[ChromeMenuItem]) -> Vec<String> {
        items
            .iter()
            .map(|i| match i {
                ChromeMenuItem::Action {
                    label,
                    disabled,
                    shortcut,
                    ..
                } => format!(
                    "{label}{}{}",
                    shortcut
                        .as_ref()
                        .map(|s| format!(" [{s}]"))
                        .unwrap_or_default(),
                    if *disabled { " (off)" } else { "" }
                ),
                ChromeMenuItem::Submenu {
                    label,
                    items,
                    disabled,
                } => format!(
                    "{label}{} ▸ {}",
                    if *disabled { " (off)" } else { "" },
                    shape(items).join(", ")
                ),
                ChromeMenuItem::Separator => "—".into(),
                ChromeMenuItem::Zoom(row) => format!(
                    "zoom {}: {}",
                    row.level,
                    row.parts()
                        .iter()
                        .map(|p| if p.disabled { "off" } else { "on" })
                        .collect::<Vec<_>>()
                        .join("/")
                ),
            })
            .collect()
    }

    #[test]
    fn gpui_menus_become_drawn_rows_without_system_submenus() {
        let rows = from_gpui(vec![
            MenuItem::action("One", One),
            MenuItem::os_action("Two", Two, OsAction::Copy).disabled(true),
            MenuItem::separator(),
            MenuItem::os_submenu("Services", SystemMenuType::Services),
            MenuItem::separator(),
            MenuItem::submenu(Menu::new("More").items([MenuItem::action("Three", Three)])),
        ]);
        assert_eq!(
            shape(&rows),
            ["One", "Two (off)", "—", "More ▸ Three"],
            "Services and the separator it leaves go"
        );
    }

    #[test]
    fn tidy_drops_separators_at_the_ends_and_in_runs() {
        let rows = tidy(vec![
            ChromeMenuItem::Separator,
            ChromeMenuItem::action("One", One),
            ChromeMenuItem::Separator,
            ChromeMenuItem::Separator,
            ChromeMenuItem::action("Two", Two),
            ChromeMenuItem::Separator,
        ]);
        assert_eq!(shape(&rows), ["One", "—", "Two"]);
    }

    fn zoom(reset_off: bool) -> ChromeMenuItem {
        ChromeMenuItem::Zoom(ZoomRow {
            level: "100%".into(),
            out: ZoomPart {
                label: "Zoom Out".into(),
                action: Box::new(Out),
                disabled: false,
            },
            reset: ZoomPart {
                label: "Actual Size".into(),
                action: Box::new(Reset),
                disabled: reset_off,
            },
            zoom_in: ZoomPart {
                label: "Zoom In".into(),
                action: Box::new(In),
                disabled: false,
            },
        })
    }

    #[test]
    fn items_grey_when_nothing_answers_them() {
        let rows = vec![
            ChromeMenuItem::action("One", One),
            ChromeMenuItem::action("Two", Two),
            // Built off: stays off even with a handler.
            ChromeMenuItem::Action {
                label: "Three".into(),
                action: Box::new(Three),
                shortcut: None,
                checked: false,
                disabled: true,
            },
            ChromeMenuItem::submenu("Some", vec![ChromeMenuItem::action("Four", Four)]),
            ChromeMenuItem::submenu("None", vec![ChromeMenuItem::action("Two", Two)]),
            zoom(false),
        ];
        let answered = |a: &dyn Action| {
            a.partial_eq(&One)
                || a.partial_eq(&Three)
                || a.partial_eq(&Four)
                || a.partial_eq(&Out)
                || a.partial_eq(&In)
        };
        let rows = grey(rows, &mut |a| answered(a));
        assert_eq!(
            shape(&rows),
            [
                "One",
                "Two (off)",
                "Three (off)",
                "Some ▸ Four",
                "None (off) ▸ Two (off)",
                "zoom 100%: on/off/on",
            ]
        );
    }

    #[test]
    fn chords_are_written_on_action_items() {
        let rows = with_shortcuts(
            vec![
                ChromeMenuItem::action("One", One),
                ChromeMenuItem::submenu("More", vec![ChromeMenuItem::action("Two", Two)]),
            ],
            &mut |a| a.partial_eq(&Two).then(|| "Ctrl+2".into()),
        );
        assert_eq!(shape(&rows), ["One", "More ▸ Two [Ctrl+2]"]);
    }

    fn menu() -> Vec<ChromeMenuItem> {
        vec![
            ChromeMenuItem::action("One", One),
            ChromeMenuItem::Separator,
            ChromeMenuItem::Action {
                label: "Off".into(),
                action: Box::new(Two),
                shortcut: None,
                checked: false,
                disabled: true,
            },
            ChromeMenuItem::submenu(
                "More",
                vec![
                    ChromeMenuItem::action("Three", Three),
                    ChromeMenuItem::action("Four", Four),
                ],
            ),
            zoom(false),
        ]
    }

    fn activated(outcome: Outcome) -> Option<(String, bool)> {
        match outcome {
            Outcome::Activate { action, keep_open } => Some((action.name().to_string(), keep_open)),
            _ => None,
        }
    }

    #[test]
    fn arrows_skip_separators_and_greyed_rows_and_wrap() {
        let items = menu();
        let mut c = Cursor::opened_by_keyboard(&items);
        assert_eq!(c.path, [0]);
        c.key(&items, MenuKey::Down);
        assert_eq!(c.path, [3], "past the separator and the greyed row");
        c.key(&items, MenuKey::Down);
        assert_eq!(c.path, [4]);
        c.key(&items, MenuKey::Down);
        assert_eq!(c.path, [0], "wraps to the top");
        c.key(&items, MenuKey::Up);
        assert_eq!(c.path, [4], "wraps to the bottom");
        c.key(&items, MenuKey::First);
        assert_eq!(c.path, [0]);
        c.key(&items, MenuKey::Last);
        assert_eq!(c.path, [4]);
        // Opened by the pointer, nothing is highlighted until a key moves.
        let mut pointer = Cursor::default();
        pointer.key(&items, MenuKey::Down);
        assert_eq!(pointer.path, [0]);
        let mut pointer = Cursor::default();
        pointer.key(&items, MenuKey::Up);
        assert_eq!(pointer.path, [4]);
    }

    #[test]
    fn right_and_enter_open_a_submenu_left_and_esc_close_it() {
        let items = menu();
        let mut c = Cursor {
            path: vec![3],
            part: 1,
        };
        assert!(matches!(c.key(&items, MenuKey::Right), Outcome::Moved));
        assert_eq!(c.path, [3, 0]);
        assert_eq!(c.open_levels(&items), 2);
        c.key(&items, MenuKey::Down);
        assert_eq!(c.path, [3, 1]);
        assert_eq!(
            activated(c.key(&items, MenuKey::Activate)),
            Some(("chrome_menu_test::Four".into(), false))
        );
        assert!(matches!(c.key(&items, MenuKey::Left), Outcome::Moved));
        assert_eq!(c.path, [3]);
        assert!(matches!(c.key(&items, MenuKey::Activate), Outcome::Moved));
        assert_eq!(c.path, [3, 0]);
        assert!(matches!(c.key(&items, MenuKey::Back), Outcome::Moved));
        assert_eq!(c.path, [3]);
        assert!(matches!(c.key(&items, MenuKey::Back), Outcome::Close));
        assert!(matches!(c.key(&items, MenuKey::Close), Outcome::Close));
        // Left in the menu itself, or Right on a plain row, goes nowhere.
        let mut top = Cursor {
            path: vec![0],
            part: 1,
        };
        assert!(matches!(top.key(&items, MenuKey::Left), Outcome::None));
        assert!(matches!(top.key(&items, MenuKey::Right), Outcome::None));
        assert_eq!(top.path, [0]);
    }

    #[test]
    fn the_zoom_row_steps_through_its_parts_and_stays_open() {
        let items = menu();
        let mut c = Cursor {
            path: vec![4],
            part: 1,
        };
        assert_eq!(
            activated(c.key(&items, MenuKey::Activate)),
            Some(("chrome_menu_test::Reset".into(), true))
        );
        c.key(&items, MenuKey::Left);
        assert_eq!(c.part, 0);
        c.key(&items, MenuKey::Left);
        assert_eq!(c.part, 0, "no further");
        assert_eq!(
            activated(c.key(&items, MenuKey::Activate)),
            Some(("chrome_menu_test::Out".into(), true))
        );
        c.key(&items, MenuKey::Right);
        c.key(&items, MenuKey::Right);
        assert_eq!(c.part, 2);
        assert_eq!(
            activated(c.key(&items, MenuKey::Activate)),
            Some(("chrome_menu_test::In".into(), true))
        );
        // At the actual size the size part can't act.
        let at_actual = vec![zoom(true)];
        let mut c = Cursor {
            path: vec![0],
            part: 1,
        };
        assert!(matches!(
            c.key(&at_actual, MenuKey::Activate),
            Outcome::None
        ));
    }

    #[test]
    fn hovering_highlights_and_opens_the_chain() {
        let items = menu();
        let mut c = Cursor::default();
        c.hover(&items, 0, 3);
        assert_eq!(c.path, [3]);
        c.hover(&items, 1, 1);
        assert_eq!(c.path, [3, 1]);
        // Back over the menu: the submenu closes.
        c.hover(&items, 0, 0);
        assert_eq!(c.path, [0]);
        // A greyed row or a separator takes no highlight.
        c.hover(&items, 0, 2);
        assert_eq!(c.path, [0]);
        c.hover(&items, 0, 1);
        assert_eq!(c.path, [0]);
    }
}
