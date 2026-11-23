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
///
/// The zoom row keeps the state it is built with, by the rule its handlers
/// follow: it acts without closing, so it changes its own availability, and
/// the window's handlers only catch up when it next draws.
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
            other => other,
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
/// for each submenu opened from the row before it. The last highlighted
/// row's own submenu shows only while `expanded` (the pointer rests on it);
/// the keyboard opens it by moving into it. The zoom row's highlighted part
/// is `part`.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Cursor {
    pub path: Vec<usize>,
    pub part: usize,
    pub expanded: bool,
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
            part: first(items).map_or(1, |i| landing_part(&items[i])),
            expanded: false,
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

    /// How many levels are open: the menu, each submenu a highlight sits
    /// in, and the last highlighted row's own while it is expanded.
    pub fn open_levels(&self, items: &[ChromeMenuItem]) -> usize {
        let mut levels = 1;
        while levels < self.path.len() && self.rows(items, levels).is_some() {
            levels += 1;
        }
        if self.expanded && levels == self.path.len() && self.rows(items, levels).is_some() {
            levels += 1;
        }
        levels
    }

    /// The pointer is over part `part` of the zoom row at `index`, `level`:
    /// Enter then runs that part.
    pub fn hover_part(
        &mut self,
        items: &[ChromeMenuItem],
        level: usize,
        index: usize,
        part: usize,
    ) {
        self.hover(items, level, index);
        if self.path.len() != level + 1 || self.path.last() != Some(&index) {
            return;
        }
        let Some(ChromeMenuItem::Zoom(zoom)) = self.rows(items, level).and_then(|r| r.get(index))
        else {
            return;
        };
        if zoom.parts().get(part).is_some_and(|p| !p.disabled) {
            self.part = part;
        }
    }

    /// The pointer is over `index` at `level`: it is highlighted, and the
    /// submenus past that level close (a submenu row opens its own).
    pub fn hover(&mut self, items: &[ChromeMenuItem], level: usize, index: usize) {
        let Some(rows) = self.rows(items, level) else {
            return;
        };
        let Some(row) = rows.get(index).filter(|r| r.is_selectable()) else {
            return;
        };
        let submenu = matches!(row, ChromeMenuItem::Submenu { .. });
        if self.path.len() == level + 1 && self.path[level] == index {
            self.expanded = submenu;
            return;
        }
        self.path.truncate(level);
        self.path.push(index);
        self.part = landing_part(row);
        self.expanded = submenu;
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
                cursor.part = landing_part(&rows[i]);
                cursor.expanded = false;
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
                Some(ChromeMenuItem::Zoom(zoom)) => match step_part(zoom, self.part, true) {
                    Some(part) => {
                        self.part = part;
                        Outcome::Moved
                    }
                    None => Outcome::None,
                },
                Some(ChromeMenuItem::Submenu {
                    items: sub,
                    disabled: false,
                    ..
                }) => self.open(sub),
                _ => Outcome::None,
            },
            MenuKey::Left => match row {
                Some(ChromeMenuItem::Zoom(zoom)) => match step_part(zoom, self.part, false) {
                    Some(part) => {
                        self.part = part;
                        Outcome::Moved
                    }
                    None => Outcome::None,
                },
                _ if self.path.len() > 1 => {
                    self.path.pop();
                    self.expanded = false;
                    Outcome::Moved
                }
                // A submenu the pointer opened from the menu itself.
                _ if self.expanded => {
                    self.expanded = false;
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
            // A submenu the pointer opened collapses first.
            MenuKey::Back if self.expanded => {
                self.expanded = false;
                Outcome::Moved
            }
            MenuKey::Back if self.path.len() > 1 => {
                self.path.pop();
                self.expanded = false;
                Outcome::Moved
            }
            MenuKey::Back | MenuKey::Close => Outcome::Close,
        }
    }

    /// The items were built again with the menu open (a zoom part ran): a
    /// part that can no longer act gives the highlight to one that can, and
    /// a row that can't act at all gives it to the next row.
    pub fn settle(&mut self, items: &[ChromeMenuItem]) {
        let level = self.path.len().saturating_sub(1);
        let (Some(rows), Some(&at)) = (self.rows(items, level), self.path.last()) else {
            return;
        };
        match rows.get(at) {
            Some(ChromeMenuItem::Zoom(zoom))
                if zoom.parts().get(self.part).is_some_and(|p| !p.disabled) => {}
            Some(row) if row.is_selectable() => self.part = landing_part(row),
            _ => {
                if let Some(next) = step(rows, Some(at), true) {
                    *self.path.last_mut().unwrap() = next;
                    self.part = landing_part(&rows[next]);
                    self.expanded = false;
                }
            }
        }
    }

    fn open(&mut self, sub: &[ChromeMenuItem]) -> Outcome {
        match first(sub) {
            Some(i) => {
                self.path.push(i);
                self.part = landing_part(&sub[i]);
                self.expanded = false;
                Outcome::Moved
            }
            None => Outcome::None,
        }
    }
}

/// The part the highlight takes on landing on a row: the zoom row's size
/// (back to the actual size), or the nearest part that can act.
fn landing_part(row: &ChromeMenuItem) -> usize {
    match row {
        ChromeMenuItem::Zoom(zoom) => [1, 0, 2]
            .into_iter()
            .find(|&k| !zoom.parts()[k].disabled)
            .unwrap_or(1),
        _ => 1,
    }
}

/// The next part along the zoom row that can act, if any.
fn step_part(zoom: &ZoomRow, from: usize, forward: bool) -> Option<usize> {
    let parts = zoom.parts();
    if forward {
        (from + 1..parts.len()).find(|&k| !parts[k].disabled)
    } else {
        (0..from).rev().find(|&k| !parts[k].disabled)
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
                // The zoom row keeps the state it is built with: it acts
                // without closing, so it changes its own availability.
                "zoom 100%: on/on/on",
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
            expanded: false,
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
            expanded: false,
        };
        assert!(matches!(top.key(&items, MenuKey::Left), Outcome::None));
        assert!(matches!(top.key(&items, MenuKey::Right), Outcome::None));
        assert_eq!(top.path, [0]);
    }

    #[test]
    fn left_and_esc_close_a_submenus_panel() {
        let items = menu();
        let mut c = Cursor::opened_by_keyboard(&items);
        // Down onto a submenu row highlights it without opening it.
        c.key(&items, MenuKey::Down);
        assert_eq!(c.path, [3]);
        assert_eq!(c.open_levels(&items), 1);
        c.key(&items, MenuKey::Right);
        assert_eq!(c.path, [3, 0]);
        assert_eq!(c.open_levels(&items), 2);
        c.key(&items, MenuKey::Left);
        assert_eq!(c.path, [3]);
        assert_eq!(c.open_levels(&items), 1, "Left closes the submenu's panel");
        c.key(&items, MenuKey::Activate);
        c.key(&items, MenuKey::Back);
        assert_eq!(c.open_levels(&items), 1, "so does Esc");
        // The pointer opens a submenu by resting on its row.
        c.hover(&items, 0, 3);
        assert_eq!(c.open_levels(&items), 2);
        c.hover(&items, 0, 0);
        assert_eq!(c.open_levels(&items), 1);
    }

    #[test]
    fn back_collapses_a_submenu_the_pointer_opened() {
        let items = menu();
        let mut c = Cursor::default();
        c.hover(&items, 0, 3);
        assert_eq!(c.open_levels(&items), 2);
        assert!(matches!(c.key(&items, MenuKey::Back), Outcome::Moved));
        assert_eq!(c.path, [3]);
        assert_eq!(c.open_levels(&items), 1, "the submenu closes, not the menu");
        assert!(matches!(c.key(&items, MenuKey::Back), Outcome::Close));
    }

    #[test]
    fn the_keyboard_skips_a_zoom_part_that_cannot_act() {
        // At the actual size: Actual Size, the middle part, can't act.
        let items = vec![ChromeMenuItem::action("One", One), zoom(true)];
        let mut c = Cursor::opened_by_keyboard(&items);
        c.key(&items, MenuKey::Down);
        assert_eq!(c.path, [1]);
        assert_eq!(
            c.part, 0,
            "landing on the row skips Actual Size for Zoom Out"
        );
        c.key(&items, MenuKey::Left);
        assert_eq!(c.part, 0, "nothing before Zoom Out");
        c.key(&items, MenuKey::Right);
        assert_eq!(c.part, 2, "Right steps over Actual Size to Zoom In");
        // The pointer resting on it selects nothing new.
        c.hover_part(&items, 0, 1, 1);
        assert_ne!(c.part, 1);
    }

    #[test]
    fn opening_onto_a_zoom_row_lands_on_a_part_that_acts() {
        // At the actual size: Actual Size can't act.
        let items = vec![
            zoom(true),
            ChromeMenuItem::submenu("More", vec![zoom(true)]),
        ];
        let mut c = Cursor::opened_by_keyboard(&items);
        assert_eq!(
            (c.path.clone(), c.part),
            (vec![0], 0),
            "the menu opens on Zoom Out"
        );
        c.key(&items, MenuKey::Down);
        c.key(&items, MenuKey::Right);
        assert_eq!(
            (c.path.clone(), c.part),
            (vec![1, 0], 0),
            "so does a submenu"
        );
        assert!(matches!(
            c.key(&items, MenuKey::Activate),
            Outcome::Activate { .. }
        ));
        // Zoomed: Actual Size acts, so both land on it.
        let items = vec![
            zoom(false),
            ChromeMenuItem::submenu("More", vec![zoom(false)]),
        ];
        let mut c = Cursor::opened_by_keyboard(&items);
        assert_eq!((c.path.clone(), c.part), (vec![0], 1));
        c.key(&items, MenuKey::Down);
        c.key(&items, MenuKey::Right);
        assert_eq!((c.path.clone(), c.part), (vec![1, 0], 1));
    }

    #[test]
    fn settling_moves_on_from_a_zoom_row_that_can_no_longer_act() {
        let mut c = Cursor {
            path: vec![0],
            part: 2,
            expanded: false,
        };
        let ChromeMenuItem::Zoom(mut row) = zoom(true) else {
            unreachable!()
        };
        row.out.disabled = true;
        row.zoom_in.disabled = true;
        let items = vec![
            ChromeMenuItem::Zoom(row),
            ChromeMenuItem::Separator,
            ChromeMenuItem::action("One", One),
        ];
        c.settle(&items);
        assert_eq!((c.path.clone(), c.part), (vec![2], 1));
    }

    #[test]
    fn hovering_a_zoom_part_selects_it_for_enter() {
        let items = menu();
        let mut c = Cursor::opened_by_keyboard(&items);
        c.hover_part(&items, 0, 4, 2);
        assert_eq!((c.path.clone(), c.part), (vec![4], 2));
        assert_eq!(
            activated(c.key(&items, MenuKey::Activate)),
            Some(("chrome_menu_test::In".into(), true))
        );
    }

    #[test]
    fn the_zoom_row_steps_through_its_parts_and_stays_open() {
        let items = menu();
        let mut c = Cursor {
            path: vec![4],
            part: 1,
            expanded: false,
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
            expanded: false,
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
