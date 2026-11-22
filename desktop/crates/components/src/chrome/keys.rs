//! The keyboard's way into ☰ and around an open menu.
//!
//! None of this is a key binding: the menu reads keystrokes before the
//! bindings do ([`super::menu::MainMenu`] intercepts them), so the app's
//! shortcut table stays as it is, and a binding without a context (Esc's
//! Stop) can't take a key from an open menu.

use gpui_kit::{Keystroke, Modifiers};

use super::ChromeStyle;

/// Whether `keystroke` opens ☰: F10 everywhere, as GTK's primary menu and
/// Windows' menu bar take it, and on Windows Alt pressed and let go alone
/// (GPUI reports a modifier tapped on its own as a keystroke named after
/// it, with no modifiers).
pub fn opens_main_menu(style: ChromeStyle, keystroke: &Keystroke) -> bool {
    let bare = keystroke.modifiers == Modifiers::default();
    match keystroke.key.as_str() {
        "f10" => bare,
        "alt" => bare && style == ChromeStyle::Windows,
        _ => false,
    }
}

/// What a key does in an open menu.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MenuKey {
    Up,
    Down,
    /// Back out of a submenu, or along the zoom row.
    Left,
    /// Into a submenu, or along the zoom row.
    Right,
    First,
    Last,
    Activate,
    /// Esc closes the innermost submenu, then the menu.
    Back,
    /// Closes the whole menu: Alt or F10 again, or Tab away.
    Close,
}

pub fn menu_key(style: ChromeStyle, keystroke: &Keystroke) -> Option<MenuKey> {
    if opens_main_menu(style, keystroke) {
        return Some(MenuKey::Close);
    }
    if keystroke.modifiers != Modifiers::default() {
        return None;
    }
    Some(match keystroke.key.as_str() {
        "up" => MenuKey::Up,
        "down" => MenuKey::Down,
        "left" => MenuKey::Left,
        "right" => MenuKey::Right,
        "home" | "pageup" => MenuKey::First,
        "end" | "pagedown" => MenuKey::Last,
        "enter" | "space" => MenuKey::Activate,
        "escape" => MenuKey::Back,
        "tab" => MenuKey::Close,
        _ => return None,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ks(s: &'static str) -> Keystroke {
        Keystroke::parse(s).unwrap()
    }

    /// GPUI's keystroke for a modifier tapped alone: the modifier's name,
    /// no modifiers held.
    fn tapped(modifier: &str) -> Keystroke {
        Keystroke {
            key: modifier.into(),
            key_char: None,
            modifiers: Default::default(),
        }
    }

    #[test]
    fn f10_opens_the_menu_on_both_and_a_lone_alt_on_windows() {
        for style in [ChromeStyle::Windows, ChromeStyle::Gnome] {
            assert!(opens_main_menu(style, &ks("f10")), "{style:?}");
            // Shift+F10 is the context menu's key; Ctrl+F10 is not ours.
            assert!(!opens_main_menu(style, &ks("shift-f10")), "{style:?}");
            assert!(!opens_main_menu(style, &ks("ctrl-f10")), "{style:?}");
        }
        assert!(opens_main_menu(ChromeStyle::Windows, &tapped("alt")));
        // GTK's header-bar apps open nothing on Alt.
        assert!(!opens_main_menu(ChromeStyle::Gnome, &tapped("alt")));
        // Other lone modifiers, and Alt with a key, do nothing.
        assert!(!opens_main_menu(ChromeStyle::Windows, &tapped("shift")));
        assert!(!opens_main_menu(ChromeStyle::Windows, &tapped("control")));
        assert!(!opens_main_menu(ChromeStyle::Windows, &ks("alt-f")));
        assert!(!opens_main_menu(ChromeStyle::Windows, &ks("f")));
    }

    #[test]
    fn menu_keys_move_activate_and_close() {
        let s = ChromeStyle::Windows;
        assert_eq!(menu_key(s, &ks("up")), Some(MenuKey::Up));
        assert_eq!(menu_key(s, &ks("down")), Some(MenuKey::Down));
        assert_eq!(menu_key(s, &ks("left")), Some(MenuKey::Left));
        assert_eq!(menu_key(s, &ks("right")), Some(MenuKey::Right));
        assert_eq!(menu_key(s, &ks("home")), Some(MenuKey::First));
        assert_eq!(menu_key(s, &ks("end")), Some(MenuKey::Last));
        assert_eq!(menu_key(s, &ks("enter")), Some(MenuKey::Activate));
        assert_eq!(menu_key(s, &ks("space")), Some(MenuKey::Activate));
        assert_eq!(menu_key(s, &ks("escape")), Some(MenuKey::Back));
        assert_eq!(menu_key(s, &ks("f10")), Some(MenuKey::Close));
        assert_eq!(menu_key(s, &ks("tab")), Some(MenuKey::Close));
        assert_eq!(menu_key(s, &tapped("alt")), Some(MenuKey::Close));
        // On GNOME a lone Alt is not the menu's key, open or closed.
        assert_eq!(menu_key(ChromeStyle::Gnome, &tapped("alt")), None);
        assert_eq!(
            menu_key(ChromeStyle::Gnome, &ks("f10")),
            Some(MenuKey::Close)
        );
        // Chords pass through to the app's bindings.
        assert_eq!(menu_key(s, &ks("ctrl-n")), None);
        assert_eq!(menu_key(s, &ks("shift-down")), None);
    }
}
