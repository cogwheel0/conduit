//! Keys as a shell reads them: the bytes an xterm sends for a keystroke.
//!
//! Only keys that are not plain text are mapped here. Typed text (and
//! anything an input method composes) reaches the terminal through its
//! input handler instead, so dead keys and IMEs work; a keystroke this
//! returns `None` for is left to them, or to the app's own shortcuts (⌘).

use alacritty_terminal::term::TermMode;

/// A keystroke's parts, as GPUI names them (`key` like `"a"`, `"enter"`,
/// `"up"`, `"f5"`).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Mods {
    pub control: bool,
    pub alt: bool,
    pub shift: bool,
    pub command: bool,
}

/// The xterm modifier parameter (1 + shift + 2·alt + 4·control), or None
/// without modifiers.
fn param(m: Mods) -> Option<u8> {
    let p = 1 + u8::from(m.shift) + 2 * u8::from(m.alt) + 4 * u8::from(m.control);
    (p > 1).then_some(p)
}

/// `CSI 1;{m}{final}` with modifiers, else `CSI {final}` (or `SS3 {final}`
/// for the arrows and Home/End in application cursor mode).
fn cursor_key(final_byte: char, m: Mods, app_cursor: bool) -> Vec<u8> {
    match param(m) {
        Some(p) => format!("\x1b[1;{p}{final_byte}").into_bytes(),
        None if app_cursor => format!("\x1bO{final_byte}").into_bytes(),
        None => format!("\x1b[{final_byte}").into_bytes(),
    }
}

/// `CSI {n};{m}~` with modifiers, else `CSI {n}~`.
fn tilde_key(n: u8, m: Mods) -> Vec<u8> {
    match param(m) {
        Some(p) => format!("\x1b[{n};{p}~").into_bytes(),
        None => format!("\x1b[{n}~").into_bytes(),
    }
}

/// The bytes for `key` with `mods` in `mode`, or None when the keystroke
/// is text (left to the input handler) or the app's (⌘).
///
/// `option_as_meta`: Option sends Escape before the key, as a Meta key,
/// instead of typing the character Option makes.
pub fn keystroke_bytes(
    key: &str,
    mods: Mods,
    mode: TermMode,
    option_as_meta: bool,
) -> Option<Vec<u8>> {
    // ⌘ keys are the app's, and so are ⌃⇥ and ⌃⇧⇥ (Next and Previous
    // Chat, as in Terminal.app's tabs).
    if mods.command || (mods.control && key == "tab") {
        return None;
    }
    let app_cursor = mode.contains(TermMode::APP_CURSOR);
    let meta = |bytes: Vec<u8>| -> Vec<u8> {
        if mods.alt && option_as_meta {
            let mut out = vec![0x1b];
            out.extend(bytes);
            out
        } else {
            bytes
        }
    };
    let named = match key {
        "enter" => Some(meta(b"\r".to_vec())),
        "escape" => Some(meta(b"\x1b".to_vec())),
        "tab" if mods.shift => Some(b"\x1b[Z".to_vec()),
        "tab" => Some(meta(b"\t".to_vec())),
        "backspace" if mods.control => Some(meta(b"\x08".to_vec())),
        "backspace" => Some(meta(b"\x7f".to_vec())),
        "space" if mods.control => Some(vec![0]),
        "up" => Some(cursor_key('A', mods, app_cursor)),
        "down" => Some(cursor_key('B', mods, app_cursor)),
        "right" => Some(cursor_key('C', mods, app_cursor)),
        "left" => Some(cursor_key('D', mods, app_cursor)),
        "home" => Some(cursor_key('H', mods, app_cursor)),
        "end" => Some(cursor_key('F', mods, app_cursor)),
        "insert" => Some(tilde_key(2, mods)),
        "delete" => Some(tilde_key(3, mods)),
        "pageup" => Some(tilde_key(5, mods)),
        "pagedown" => Some(tilde_key(6, mods)),
        "f1" => Some(f1_to_f4('P', mods)),
        "f2" => Some(f1_to_f4('Q', mods)),
        "f3" => Some(f1_to_f4('R', mods)),
        "f4" => Some(f1_to_f4('S', mods)),
        "f5" => Some(tilde_key(15, mods)),
        "f6" => Some(tilde_key(17, mods)),
        "f7" => Some(tilde_key(18, mods)),
        "f8" => Some(tilde_key(19, mods)),
        "f9" => Some(tilde_key(20, mods)),
        "f10" => Some(tilde_key(21, mods)),
        "f11" => Some(tilde_key(23, mods)),
        "f12" => Some(tilde_key(24, mods)),
        _ => None,
    };
    if named.is_some() {
        return named;
    }
    let mut chars = key.chars();
    let (Some(c), None) = (chars.next(), chars.next()) else {
        return None;
    };
    if mods.control {
        let byte = control_byte(c)?;
        return Some(meta(vec![byte]));
    }
    if mods.alt && option_as_meta {
        let c = if mods.shift {
            c.to_uppercase().next().unwrap_or(c)
        } else {
            c
        };
        let mut out = vec![0x1b];
        let mut buf = [0; 4];
        out.extend(c.encode_utf8(&mut buf).as_bytes());
        return Some(out);
    }
    None
}

/// F1–F4: `SS3 P`… without modifiers, `CSI 1;{m}P`… with.
fn f1_to_f4(final_byte: char, m: Mods) -> Vec<u8> {
    match param(m) {
        Some(p) => format!("\x1b[1;{p}{final_byte}").into_bytes(),
        None => format!("\x1bO{final_byte}").into_bytes(),
    }
}

/// Control-`c` as a C0 byte: ⌃A–⌃Z, ⌃@, ⌃[ (Escape), ⌃\, ⌃], ⌃^, ⌃_, ⌃?
/// (and ⌃2–⌃8 as xterm maps them).
fn control_byte(c: char) -> Option<u8> {
    let c = c.to_ascii_lowercase();
    Some(match c {
        'a'..='z' => c as u8 - b'a' + 1,
        '@' | '2' | ' ' => 0,
        '[' | '3' => 0x1b,
        '\\' | '4' => 0x1c,
        ']' | '5' => 0x1d,
        '^' | '6' => 0x1e,
        '_' | '-' | '7' => 0x1f,
        '?' | '8' => 0x7f,
        _ => return None,
    })
}

/// `text` pasted: bracketed when the shell asked for it (so it is not run
/// line by line), with line ends as Return; and stripped of the bracket
/// markers a hostile clipboard could carry. Inside brackets nothing can end
/// the paste early: markers are taken out until none is left (one can hide
/// inside another), then every Escape and Ctrl-C, as Alacritty does.
pub fn paste_bytes(text: &str, mode: TermMode) -> Vec<u8> {
    let mut clean = text.to_string();
    while clean.contains("\x1b[200~") || clean.contains("\x1b[201~") {
        clean = clean.replace("\x1b[200~", "").replace("\x1b[201~", "");
    }
    let clean = clean.replace("\r\n", "\r").replace('\n', "\r");
    if mode.contains(TermMode::BRACKETED_PASTE) {
        let clean = clean.replace(['\x1b', '\x03'], "");
        let mut out = b"\x1b[200~".to_vec();
        out.extend(clean.as_bytes());
        out.extend(b"\x1b[201~");
        out
    } else {
        clean.into_bytes()
    }
}

/// A mouse report for a press, release or wheel step at (`col`, `row`)
/// (zero-based), in the SGR form when the shell asked for it, else the
/// X10 form (which cannot say past column 223).
pub fn mouse_report(
    button: u8,
    pressed: bool,
    col: usize,
    row: usize,
    mods: Mods,
    mode: TermMode,
) -> Option<Vec<u8>> {
    let mut code = button;
    if mods.shift {
        code += 4;
    }
    if mods.alt {
        code += 8;
    }
    if mods.control {
        code += 16;
    }
    if mode.contains(TermMode::SGR_MOUSE) {
        let end = if pressed { 'M' } else { 'm' };
        return Some(format!("\x1b[<{code};{};{}{end}", col + 1, row + 1).into_bytes());
    }
    let code = if pressed { code } else { 3 + (code & !3) };
    let (x, y) = (col + 33, row + 33);
    if x > 255 || y > 255 {
        return None;
    }
    Some(vec![0x1b, b'[', b'M', 32 + code, x as u8, y as u8])
}

#[cfg(test)]
mod tests {
    use super::*;

    fn m() -> Mods {
        Mods::default()
    }

    fn keys(key: &str, mods: Mods) -> Option<Vec<u8>> {
        keystroke_bytes(key, mods, TermMode::empty(), false)
    }

    #[test]
    fn named_keys_send_xterm_sequences() {
        assert_eq!(keys("enter", m()).unwrap(), b"\r");
        assert_eq!(keys("backspace", m()).unwrap(), b"\x7f");
        assert_eq!(keys("escape", m()).unwrap(), b"\x1b");
        assert_eq!(keys("tab", m()).unwrap(), b"\t");
        assert_eq!(keys("tab", Mods { shift: true, ..m() }).unwrap(), b"\x1b[Z");
        assert_eq!(keys("up", m()).unwrap(), b"\x1b[A");
        assert_eq!(
            keys("left", Mods { shift: true, ..m() }).unwrap(),
            b"\x1b[1;2D"
        );
        assert_eq!(
            keys(
                "right",
                Mods {
                    alt: true,
                    control: true,
                    ..m()
                }
            )
            .unwrap(),
            b"\x1b[1;7C"
        );
        assert_eq!(keys("delete", m()).unwrap(), b"\x1b[3~");
        assert_eq!(
            keys(
                "pageup",
                Mods {
                    control: true,
                    ..m()
                }
            )
            .unwrap(),
            b"\x1b[5;5~"
        );
        assert_eq!(keys("f1", m()).unwrap(), b"\x1bOP");
        assert_eq!(keys("f5", m()).unwrap(), b"\x1b[15~");
        assert_eq!(
            keys("f12", Mods { shift: true, ..m() }).unwrap(),
            b"\x1b[24;2~"
        );
    }

    #[test]
    fn application_cursor_mode_changes_the_arrows() {
        let up = keystroke_bytes("up", m(), TermMode::APP_CURSOR, false).unwrap();
        assert_eq!(up, b"\x1bOA");
        let home = keystroke_bytes("home", m(), TermMode::APP_CURSOR, false).unwrap();
        assert_eq!(home, b"\x1bOH");
    }

    #[test]
    fn control_makes_c0_bytes() {
        let ctrl = Mods {
            control: true,
            ..m()
        };
        assert_eq!(keys("c", ctrl).unwrap(), [3]);
        assert_eq!(keys("a", ctrl).unwrap(), [1]);
        assert_eq!(keys("[", ctrl).unwrap(), [0x1b]);
        assert_eq!(keys("space", ctrl).unwrap(), [0]);
        assert_eq!(keys("\\", ctrl).unwrap(), [0x1c]);
        assert!(keys("1", ctrl).is_none());
    }

    #[test]
    fn text_and_shortcuts_are_left_alone() {
        assert!(
            keys("a", m()).is_none(),
            "typed text goes through the input handler"
        );
        assert!(keys("a", Mods { shift: true, ..m() }).is_none());
        assert!(
            keys(
                "c",
                Mods {
                    command: true,
                    ..m()
                }
            )
            .is_none()
        );
        assert!(
            keys(
                "enter",
                Mods {
                    command: true,
                    ..m()
                }
            )
            .is_none()
        );
        let ctrl = Mods {
            control: true,
            ..m()
        };
        assert!(keys("tab", ctrl).is_none(), "⌃⇥ is Next Chat");
        assert!(
            keys(
                "tab",
                Mods {
                    shift: true,
                    ..ctrl
                }
            )
            .is_none()
        );
        // Option types its character unless it is Meta.
        assert!(keys("e", Mods { alt: true, ..m() }).is_none());
    }

    #[test]
    fn option_as_meta_sends_escape_first() {
        let alt = Mods { alt: true, ..m() };
        let meta = |k: &str, mods: Mods| keystroke_bytes(k, mods, TermMode::empty(), true);
        assert_eq!(meta("f", alt).unwrap(), b"\x1bf");
        assert_eq!(meta("b", Mods { shift: true, ..alt }).unwrap(), b"\x1bB");
        assert_eq!(meta("backspace", alt).unwrap(), b"\x1b\x7f");
        assert_eq!(meta("enter", alt).unwrap(), b"\x1b\r");
        // Arrows keep their modifier parameter.
        assert_eq!(meta("left", alt).unwrap(), b"\x1b[1;3D");
    }

    #[test]
    fn pastes_are_bracketed_when_asked() {
        assert_eq!(paste_bytes("a\nb", TermMode::empty()), b"a\rb");
        assert_eq!(
            paste_bytes("ls\n", TermMode::BRACKETED_PASTE),
            b"\x1b[200~ls\r\x1b[201~"
        );
        assert_eq!(
            paste_bytes("x\x1b[201~rm", TermMode::BRACKETED_PASTE),
            b"\x1b[200~xrm\x1b[201~"
        );
        // A marker that only appears once an inner one is taken out, and a
        // bare Escape or Ctrl-C, cannot end the paste before its last line.
        let nested = paste_bytes(
            "\x1b[20\x1b[201~1~printf hello\n",
            TermMode::BRACKETED_PASTE,
        );
        assert_eq!(nested, b"\x1b[200~printf hello\r\x1b[201~");
        assert_eq!(
            paste_bytes("a\x1bb\x03c", TermMode::BRACKETED_PASTE),
            b"\x1b[200~abc\x1b[201~"
        );
    }

    #[test]
    fn mouse_reports_in_both_forms() {
        let sgr = TermMode::SGR_MOUSE;
        assert_eq!(
            mouse_report(0, true, 4, 2, m(), sgr).unwrap(),
            b"\x1b[<0;5;3M"
        );
        assert_eq!(
            mouse_report(0, false, 4, 2, m(), sgr).unwrap(),
            b"\x1b[<0;5;3m"
        );
        assert_eq!(
            mouse_report(64, true, 0, 0, m(), sgr).unwrap(),
            b"\x1b[<64;1;1M"
        );
        assert_eq!(
            mouse_report(0, true, 0, 0, m(), TermMode::empty()).unwrap(),
            vec![0x1b, b'[', b'M', 32, 33, 33]
        );
        assert!(mouse_report(0, true, 300, 0, m(), TermMode::empty()).is_none());
    }
}
