//! Charts and diagrams in dark mode: an answer's image that is drawn on a
//! flat light background (a plotted chart, a diagram, a table rendered to a
//! picture) is redrawn in the window's own tones, so it doesn't stand on
//! the #000 column as a block of white.
//!
//! * **Which images:** opaque, one frame, with a near-white, near-grey
//!   border all round and that background over much of the picture. A
//!   photo never qualifies, nor a picture with transparency (it is drawn as
//!   it is meant to be over any background).
//! * **How:** each pixel's lightness is turned over between two theme
//!   tokens: the background becomes the raised tone (the composer's and the
//!   code blocks' #181818) and black ink the text colour, the greys between
//!   in proportion, so bars stay a light grey, axes and labels a secondary
//!   one. Hue offsets are kept: a blue line stays blue, lighter.
//! * **The original** is what Quick Look opens, and light mode shows it
//!   as it is.
//!
//! The redrawn picture is made once per image and theme tone, the first
//! time it is drawn.

use std::cell::RefCell;
use std::collections::HashMap;
use std::sync::Arc;

use gpui_kit::{Hsla, RenderImage, Rgba};

/// How far a border pixel may be from the background, per channel.
const NEAR: i32 = 14;
/// The background must be at least this light (Rec. 709 luma, 0–255) and
/// at most this coloured (largest minus smallest channel).
const MIN_BG_LUMA: f32 = 225.;
const MAX_BG_CHROMA: i32 = 18;
/// Of the border samples, this share must be the background.
const BORDER_SHARE: f32 = 0.92;
/// Of the whole picture, this share must be the background (charts and
/// diagrams are mostly background; photos are not).
const FLAT_SHARE: f32 = 0.45;
/// A pixel with less alpha than this counts as transparent.
const OPAQUE: u8 = 250;
/// How many of the picture's pixels are sampled to classify it, at most.
const SAMPLES: usize = 40_000;
/// How many redrawn pictures are kept.
const CACHE_CAP: usize = 64;

/// The picture's background, as `[r, g, b]`, when `bgra` (GPUI's decoded
/// layout, `width` × `height`) is a chart or diagram on a flat light
/// background; `None` otherwise.
pub fn diagram_background(bgra: &[u8], width: usize, height: usize) -> Option<[u8; 3]> {
    if width < 16 || height < 16 || bgra.len() < width * height * 4 {
        return None;
    }
    let px = |x: usize, y: usize| {
        let i = (y * width + x) * 4;
        [bgra[i + 2], bgra[i + 1], bgra[i], bgra[i + 3]]
    };
    // The border: a band 2% deep (at least 2 px) along each edge.
    let band_x = (width / 50).max(2);
    let band_y = (height / 50).max(2);
    let step = ((2 * (width + height)) / 2000).max(1);
    let mut border = vec![];
    for x in (0..width).step_by(step) {
        for y in [0, band_y - 1, height - band_y, height - 1] {
            border.push(px(x, y));
        }
    }
    for y in (0..height).step_by(step) {
        for x in [0, band_x - 1, width - band_x, width - 1] {
            border.push(px(x, y));
        }
    }
    if border.iter().any(|p| p[3] < OPAQUE) {
        return None;
    }
    let median = |c: usize| {
        let mut v: Vec<u8> = border.iter().map(|p| p[c]).collect();
        v.sort_unstable();
        v[v.len() / 2]
    };
    let bg = [median(0), median(1), median(2)];
    let chroma = |p: [u8; 3]| {
        i32::from(*p.iter().max().unwrap_or(&0)) - i32::from(*p.iter().min().unwrap_or(&0))
    };
    if luma(bg) < MIN_BG_LUMA || chroma(bg) > MAX_BG_CHROMA {
        return None;
    }
    let near = |p: [u8; 4]| (0..3).all(|c| (i32::from(p[c]) - i32::from(bg[c])).abs() <= NEAR);
    let on_border = border.iter().filter(|p| near(**p)).count();
    if (on_border as f32) < BORDER_SHARE * border.len() as f32 {
        return None;
    }
    // The whole picture, on a grid.
    let total = width * height;
    let stride = (total / SAMPLES).max(1);
    let (mut seen, mut flat, mut clear) = (0usize, 0usize, 0usize);
    let mut i = 0;
    while i < total {
        let p = px(i % width, i / width);
        seen += 1;
        if p[3] < OPAQUE {
            clear += 1;
        }
        if near(p) {
            flat += 1;
        }
        i += stride;
    }
    if clear * 50 > seen || (flat as f32) < FLAT_SHARE * seen as f32 {
        return None;
    }
    Some(bg)
}

/// Rec. 709 luma of an sRGB colour, 0–255.
fn luma(p: [u8; 3]) -> f32 {
    0.2126 * f32::from(p[0]) + 0.7152 * f32::from(p[1]) + 0.0722 * f32::from(p[2])
}

/// Redraws `bgra` in place: `bg` becomes `card`, black becomes `ink`, the
/// lightnesses between them in proportion, each pixel keeping how far its
/// channels stand from its grey (its hue).
pub fn remap(bgra: &mut [u8], bg: [u8; 3], card: [u8; 3], ink: [u8; 3]) {
    let bg_luma = luma(bg).max(1.);
    let (pixels, _) = bgra.as_chunks_mut::<4>();
    for p in pixels {
        let rgb = [p[2], p[1], p[0]];
        let l = luma(rgb);
        let t = ((bg_luma - l) / bg_luma).clamp(0., 1.);
        let mut out = [0u8; 3];
        for c in 0..3 {
            let base = f32::from(card[c]) + t * (f32::from(ink[c]) - f32::from(card[c]));
            // The pixel's hue, less the paper's own tint (which fades out
            // toward the ink), so the background lands on the card exactly.
            let hue = f32::from(rgb[c]) - l - (1. - t) * (f32::from(bg[c]) - bg_luma);
            out[c] = (base + hue).round().clamp(0., 255.) as u8;
        }
        p[2] = out[0];
        p[1] = out[1];
        p[0] = out[2];
    }
}

fn rgb8(c: Hsla) -> [u8; 3] {
    let c: Rgba = c.into();
    [c.r, c.g, c.b].map(|v| (v * 255.).round().clamp(0., 255.) as u8)
}

/// A redrawn picture's key: the image, the card and the ink.
type ThemedKey = (usize, [u8; 3], [u8; 3]);

thread_local! {
    /// Redrawn pictures; `None`: not a diagram.
    static THEMED: RefCell<HashMap<ThemedKey, Option<Arc<RenderImage>>>> =
        RefCell::new(HashMap::new());
}

/// `image` redrawn on `card` with `ink` when it is a chart or diagram on a
/// light background (see the module notes); `None` when it is shown as it
/// is.
pub fn themed(image: &Arc<RenderImage>, card: Hsla, ink: Hsla) -> Option<Arc<RenderImage>> {
    let (card, ink) = (rgb8(card), rgb8(ink));
    let key = (image.id.0, card, ink);
    if let Some(hit) = THEMED.with(|m| m.borrow().get(&key).cloned()) {
        return hit;
    }
    let made = make(image, card, ink);
    THEMED.with(|m| {
        let mut m = m.borrow_mut();
        if m.len() >= CACHE_CAP {
            m.clear();
        }
        m.insert(key, made.clone());
    });
    made
}

fn make(image: &Arc<RenderImage>, card: [u8; 3], ink: [u8; 3]) -> Option<Arc<RenderImage>> {
    if image.frame_count() != 1 {
        return None;
    }
    let size = image.size(0);
    let (w, h) = (size.width.0 as usize, size.height.0 as usize);
    let bytes = image.as_bytes(0)?;
    let bg = diagram_background(bytes, w, h)?;
    let mut out = bytes.to_vec();
    remap(&mut out, bg, card, ink);
    // GPUI keeps frames in BGRA order inside an RGBA-typed buffer.
    let buffer = image::RgbaImage::from_raw(w as u32, h as u32, out)?;
    Some(Arc::new(RenderImage::new(vec![image::Frame::new(buffer)])))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A `w` × `h` BGRA picture from an RGB function.
    fn picture(w: usize, h: usize, mut f: impl FnMut(usize, usize) -> [u8; 3]) -> Vec<u8> {
        let mut v = Vec::with_capacity(w * h * 4);
        for y in 0..h {
            for x in 0..w {
                let [r, g, b] = f(x, y);
                v.extend_from_slice(&[b, g, r, 255]);
            }
        }
        v
    }

    /// The capture's chart: dark bars and labels on #FAFAF8.
    fn chart(x: usize, y: usize) -> [u8; 3] {
        let bar = (40..200).contains(&y) && (x % 40) > 12 && (x % 40) < 30 && x > 20 && x < 300;
        let axis = y == 200 && (20..300).contains(&x);
        if bar {
            [70, 70, 76]
        } else if axis {
            [120, 120, 124]
        } else {
            [250, 250, 248]
        }
    }

    #[test]
    fn a_chart_on_a_light_background_is_a_diagram() {
        let v = picture(320, 240, chart);
        assert_eq!(diagram_background(&v, 320, 240), Some([250, 250, 248]));
    }

    #[test]
    fn photos_dark_pictures_and_transparent_ones_are_not() {
        // Noise: a photo has no flat background.
        let mut seed = 7u32;
        let noise = picture(200, 200, |_, _| {
            seed = seed.wrapping_mul(1_103_515_245).wrapping_add(12_345);
            let v = (seed >> 16) as u8;
            [v, v.wrapping_add(40), v.wrapping_mul(3)]
        });
        assert_eq!(diagram_background(&noise, 200, 200), None);
        // Already dark.
        let dark = picture(
            200,
            200,
            |x, y| if (x + y) % 7 == 0 { [200; 3] } else { [20; 3] },
        );
        assert_eq!(diagram_background(&dark, 200, 200), None);
        // A light but coloured background (a sky, a product shot).
        let sky = picture(200, 200, |_, _| [200, 225, 255]);
        assert_eq!(diagram_background(&sky, 200, 200), None);
        // Transparent pixels: drawn as meant over any background.
        let mut clear = picture(200, 200, |_, _| [255; 3]);
        for p in clear.as_chunks_mut::<4>().0.iter_mut().step_by(3) {
            p[3] = 0;
        }
        assert_eq!(diagram_background(&clear, 200, 200), None);
        // Too small to tell.
        assert_eq!(diagram_background(&picture(8, 8, chart), 8, 8), None);
    }

    #[test]
    fn the_background_takes_the_card_tone_and_black_the_ink() {
        let card = [24, 24, 24];
        let ink = [236, 236, 236];
        let mut v = picture(4, 1, |x, _| match x {
            0 => [250, 250, 248],
            1 => [0, 0, 0],
            2 => [70, 70, 76],
            _ => [31, 119, 180],
        });
        remap(&mut v, [250, 250, 248], card, ink);
        let at = |i: usize| [v[i * 4 + 2], v[i * 4 + 1], v[i * 4]];
        // The background is the card, within a level of rounding.
        assert!(
            at(0).iter().zip(card).all(|(a, b)| a.abs_diff(b) <= 1),
            "{:?}",
            at(0)
        );
        assert_eq!(at(1), ink);
        // Dark bars turn a light grey, still short of the ink.
        let bar = at(2);
        assert!(bar[0] > 150 && bar[0] < 200, "{bar:?}");
        // A blue keeps its hue: blue stays the largest channel.
        let blue = at(3);
        assert!(blue[2] > blue[1] && blue[1] > blue[0], "{blue:?}");
    }
}
