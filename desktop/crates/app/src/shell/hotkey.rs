//! The global Quick Ask shortcut through `global-hotkey` (pinned exactly):
//! a Carbon hot key that fires while any app is in front.
//!
//! [`Hotkey::apply`] (re)registers the chord Settings › Desktop asks for and
//! reports what happened, so Settings can say when another app holds it.
//! Presses arrive through `GlobalHotKeyEvent`'s handler; the app forwards
//! them to the main thread.

use global_hotkey::GlobalHotKeyManager;
use global_hotkey::hotkey::{Code, HotKey, Modifiers};

use crate::keymap::KeyStroke;

/// What happened to the Quick Ask shortcut.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum HotkeyStatus {
    /// Quick Ask's shortcut is turned off.
    Off,
    /// Held: pressing it anywhere opens Quick Ask.
    Registered,
    /// The system refused it (another app holds it).
    Taken,
    /// The chord has a key the hot key API can't take.
    Invalid,
    /// No hot key manager (it failed to start).
    Unavailable,
}

/// `stroke` as a hot key; `None` when its key has no hot-key code.
pub fn to_hotkey(stroke: &KeyStroke) -> Option<HotKey> {
    let code = code_for(&stroke.key)?;
    let mut mods = Modifiers::empty();
    if stroke.primary {
        mods |= if cfg!(target_os = "macos") {
            Modifiers::META
        } else {
            Modifiers::CONTROL
        };
    }
    if stroke.shift {
        mods |= Modifiers::SHIFT;
    }
    if stroke.alt {
        mods |= Modifiers::ALT;
    }
    if stroke.ctrl && cfg!(target_os = "macos") {
        mods |= Modifiers::CONTROL;
    }
    if mods.is_empty() {
        return None;
    }
    Some(HotKey::new(Some(mods), code))
}

fn code_for(key: &str) -> Option<Code> {
    let mut chars = key.chars();
    if let (Some(c), None) = (chars.next(), chars.next()) {
        let code = match c.to_ascii_lowercase() {
            'a' => Code::KeyA,
            'b' => Code::KeyB,
            'c' => Code::KeyC,
            'd' => Code::KeyD,
            'e' => Code::KeyE,
            'f' => Code::KeyF,
            'g' => Code::KeyG,
            'h' => Code::KeyH,
            'i' => Code::KeyI,
            'j' => Code::KeyJ,
            'k' => Code::KeyK,
            'l' => Code::KeyL,
            'm' => Code::KeyM,
            'n' => Code::KeyN,
            'o' => Code::KeyO,
            'p' => Code::KeyP,
            'q' => Code::KeyQ,
            'r' => Code::KeyR,
            's' => Code::KeyS,
            't' => Code::KeyT,
            'u' => Code::KeyU,
            'v' => Code::KeyV,
            'w' => Code::KeyW,
            'x' => Code::KeyX,
            'y' => Code::KeyY,
            'z' => Code::KeyZ,
            '0' => Code::Digit0,
            '1' => Code::Digit1,
            '2' => Code::Digit2,
            '3' => Code::Digit3,
            '4' => Code::Digit4,
            '5' => Code::Digit5,
            '6' => Code::Digit6,
            '7' => Code::Digit7,
            '8' => Code::Digit8,
            '9' => Code::Digit9,
            ' ' => Code::Space,
            ',' => Code::Comma,
            '.' => Code::Period,
            '/' => Code::Slash,
            ';' => Code::Semicolon,
            '\'' => Code::Quote,
            '[' => Code::BracketLeft,
            ']' => Code::BracketRight,
            '\\' => Code::Backslash,
            '-' => Code::Minus,
            '=' => Code::Equal,
            '`' => Code::Backquote,
            _ => return None,
        };
        return Some(code);
    }
    Some(match key {
        "enter" => Code::Enter,
        "escape" => Code::Escape,
        "backspace" => Code::Backspace,
        "tab" => Code::Tab,
        "arrowup" => Code::ArrowUp,
        "arrowdown" => Code::ArrowDown,
        "left" | "arrowleft" => Code::ArrowLeft,
        "right" | "arrowright" => Code::ArrowRight,
        "f1" => Code::F1,
        "f2" => Code::F2,
        "f3" => Code::F3,
        "f4" => Code::F4,
        "f5" => Code::F5,
        "f6" => Code::F6,
        "f7" => Code::F7,
        "f8" => Code::F8,
        "f9" => Code::F9,
        "f10" => Code::F10,
        "f11" => Code::F11,
        "f12" => Code::F12,
        _ => return None,
    })
}

/// The registered Quick Ask hot key.
pub struct Hotkey {
    manager: Option<GlobalHotKeyManager>,
    current: Option<HotKey>,
}

impl Hotkey {
    /// Starts the hot key manager (main thread).
    pub fn new() -> Self {
        let manager = GlobalHotKeyManager::new()
            .map_err(|e| log::warn!("global hot keys unavailable: {e}"))
            .ok();
        Self {
            manager,
            current: None,
        }
    }

    /// The registered hot key's id (events carry it).
    pub fn id(&self) -> Option<u32> {
        self.current.map(|h| h.id())
    }

    /// Holds `want` (or nothing, with `None`), letting go of the old chord.
    pub fn apply(&mut self, want: Option<&KeyStroke>) -> HotkeyStatus {
        let Some(manager) = &self.manager else {
            return if want.is_some() {
                HotkeyStatus::Unavailable
            } else {
                HotkeyStatus::Off
            };
        };
        let wanted = want.map(to_hotkey);
        if let (Some(Some(next)), Some(current)) = (wanted, self.current)
            && next == current
        {
            return HotkeyStatus::Registered;
        }
        if let Some(current) = self.current.take()
            && let Err(e) = manager.unregister(current)
        {
            log::warn!("could not release the Quick Ask shortcut: {e}");
        }
        match wanted {
            None => HotkeyStatus::Off,
            Some(None) => HotkeyStatus::Invalid,
            Some(Some(hotkey)) => match manager.register(hotkey) {
                Ok(()) => {
                    self.current = Some(hotkey);
                    HotkeyStatus::Registered
                }
                Err(e) => {
                    log::warn!("the Quick Ask shortcut was refused: {e}");
                    HotkeyStatus::Taken
                }
            },
        }
    }
}

impl Default for Hotkey {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn chords_become_hot_keys() {
        let default = to_hotkey(&KeyStroke::new(" ").primary().shift()).unwrap();
        assert_eq!(default.key, Code::Space);
        assert!(default.mods.contains(Modifiers::META | Modifiers::SHIFT));
        assert!(!default.mods.contains(Modifiers::ALT));

        let k = to_hotkey(&KeyStroke::new("k").alt()).unwrap();
        assert_eq!((k.key, k.mods), (Code::KeyK, Modifiers::ALT));
        assert_eq!(
            to_hotkey(&KeyStroke::new("enter").primary()).map(|h| h.key),
            Some(Code::Enter)
        );
        assert_eq!(
            to_hotkey(&KeyStroke::new(";").primary()).map(|h| h.key),
            Some(Code::Semicolon)
        );
        // Ids follow the chord, so a re-registration of the same chord is
        // recognised.
        assert_eq!(
            default.id(),
            to_hotkey(&KeyStroke::new(" ").primary().shift())
                .unwrap()
                .id()
        );
    }

    #[test]
    fn bare_keys_and_unknown_keys_are_not_hot_keys() {
        assert_eq!(to_hotkey(&KeyStroke::new("k")), None);
        assert_eq!(to_hotkey(&KeyStroke::new("é").primary()), None);
        assert_eq!(to_hotkey(&KeyStroke::new("pageup").primary()), None);
    }
}
