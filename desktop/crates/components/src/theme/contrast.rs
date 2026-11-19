//! WCAG 2 contrast, matching `packages/conduit_theme/lib/src/contrast.dart`.

use gpui_kit::{Hsla, Rgba};

/// WCAG relative luminance of an opaque colour.
pub fn relative_luminance(color: Hsla) -> f32 {
    let c: Rgba = color.into();
    let channel = |v: f32| {
        if v <= 0.039_28 {
            v / 12.92
        } else {
            ((v + 0.055) / 1.055).powf(2.4)
        }
    };
    0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b)
}

/// WCAG contrast ratio between two colours, from 1 to 21. A translucent
/// `fg` is composited over `bg` first; `bg` is treated as opaque.
pub fn contrast_ratio(fg: Hsla, bg: Hsla) -> f32 {
    let fg = composite(fg, bg);
    let (a, b) = (relative_luminance(fg), relative_luminance(bg));
    (a.max(b) + 0.05) / (a.min(b) + 0.05)
}

/// `top` painted over an opaque `bottom`.
pub fn composite(top: Hsla, bottom: Hsla) -> Hsla {
    let t: Rgba = top.into();
    if t.a >= 1. {
        return top;
    }
    let b: Rgba = bottom.into();
    let mix = |x: f32, y: f32| x * t.a + y * (1. - t.a);
    Rgba {
        r: mix(t.r, b.r),
        g: mix(t.g, b.g),
        b: mix(t.b, b.b),
        a: 1.,
    }
    .into()
}

/// `color` moved `amount` of the way toward `toward` (in sRGB, like the Dart
/// `mixColor`), keeping `color`'s alpha.
pub fn mix(color: Hsla, toward: Hsla, amount: f32) -> Hsla {
    let a: Rgba = color.into();
    let b: Rgba = toward.into();
    let m = |x: f32, y: f32| x + (y - x) * amount;
    Rgba {
        r: m(a.r, b.r),
        g: m(a.g, b.g),
        b: m(a.b, b.b),
        a: a.a,
    }
    .into()
}

/// `color` with its alpha replaced.
pub fn with_alpha(color: Hsla, alpha: f32) -> Hsla {
    Hsla { a: alpha, ..color }
}

#[cfg(test)]
mod tests {
    use super::*;
    use gpui_kit::rgb;

    #[test]
    fn black_on_white_is_21() {
        let r = contrast_ratio(rgb(0x000000).into(), rgb(0xffffff).into());
        assert!((r - 21.).abs() < 0.01, "{r}");
    }

    #[test]
    fn translucent_foreground_composites_first() {
        let half_black = with_alpha(rgb(0x000000).into(), 0.5);
        let r = contrast_ratio(half_black, rgb(0xffffff).into());
        assert!(r > 3.5 && r < 4.5, "{r}");
    }
}
