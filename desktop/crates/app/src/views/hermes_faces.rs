//! Bot Mode faces, as the phone draws them (`hermes_bot_avatar.dart`,
//! `hermes_room_avatars.dart`): a bot's picture when it has one, else its
//! shape in its colour with two eyes; a room member that is not one of
//! this connection's bots keeps a colour of its own; a room's picture is up
//! to three member faces overlapping in a square. A face whose bot is at
//! work bobs (still under Reduce Motion).
//!
//! The colours are the bots' own (chosen in Hermes), like a model's logo:
//! the one place the monochrome sidebar shows colour.

use std::f32::consts::PI;
use std::sync::Arc;
use std::time::Duration;

use conduit_protocol::{HermesBotDto, HermesRoomMemberDto};
use gpui_kit::prelude::*;
use gpui_kit::{
    Animation, AnimationExt as _, AnyElement, App, Bounds, ElementId, Hsla, Image, ImageSource,
    PathBuilder, Pixels, Point, Rgba, Window, canvas, div, img, point, px,
};

use crate::stores::hermes_rooms::HermesRoomsStore;

/// What a face is drawn from.
#[derive(Clone, Debug)]
pub struct Face {
    /// `circle`, `squircle`, `pill`, `triangle`, `hexagon`, `cloud`,
    /// `drop`, or a `blobatar:` kind.
    pub shape: String,
    pub color: Hsla,
    /// The bot's picture, when it has one (drawn instead of the shape).
    pub image: Option<Arc<Image>>,
}

/// Shape colours for a member that is not a bot of this connection, picked
/// by its profile so it keeps one colour.
const FALLBACK: [u32; 6] = [0x8b5cf6, 0x0ea5e9, 0xf97316, 0x10b981, 0xec4899, 0xeab308];

/// `#rrggbb` as a colour (the bots' default violet otherwise).
pub fn parse_color(hex: &str) -> Hsla {
    let value = hex
        .strip_prefix('#')
        .filter(|h| h.len() == 6)
        .and_then(|h| u32::from_str_radix(h, 16).ok())
        .unwrap_or(0x8b5cf6);
    gpui_kit::rgb(value).into()
}

/// Bot `bot`'s face, its picture once read.
pub fn bot_face(bot: &HermesBotDto, store: &HermesRoomsStore) -> Face {
    Face {
        shape: bot.shape.clone(),
        color: parse_color(&bot.color),
        image: store.known_avatar(&bot.name),
    }
}

/// A room member's face: its bot's when the roster has it, else a shape in
/// a colour of its own.
pub fn member_face(member: &HermesRoomMemberDto, store: &HermesRoomsStore) -> Face {
    match store.bot(&member.profile) {
        Some(bot) => bot_face(bot, store),
        None => {
            let sum: u32 = member.profile.encode_utf16().map(u32::from).sum();
            Face {
                shape: "squircle".into(),
                color: gpui_kit::rgb(FALLBACK[(sum as usize) % FALLBACK.len()]).into(),
                image: None,
            }
        }
    }
}

/// Asks for the pictures of `members`' bots that have one (each once).
pub fn request_avatars<'a>(
    names: impl IntoIterator<Item = &'a str>,
    store: &gpui_kit::Entity<HermesRoomsStore>,
    cx: &mut App,
) {
    let names: Vec<String> = names.into_iter().map(str::to_string).collect();
    let store = store.clone();
    cx.defer(move |cx| {
        store.update(cx, |s, cx| {
            for name in &names {
                s.avatar(name, cx);
            }
        })
    });
}

/// One face, `size` points square. `active`: its bot is at work (it bobs,
/// unless `reduce_motion`).
pub fn face(
    id: impl Into<ElementId>,
    face: &Face,
    size: f32,
    active: bool,
    reduce_motion: bool,
) -> AnyElement {
    let id = id.into();
    let inner: AnyElement = match &face.image {
        Some(image) => img(ImageSource::Image(image.clone()))
            .size(px(size))
            .rounded_full()
            .into_any_element(),
        None => {
            let (shape, color) = (classic_shape(&face.shape).to_string(), face.color);
            canvas(
                |_, _, _| {},
                move |bounds, _, window, _| paint_face(bounds, &shape, color, window),
            )
            .size(px(size))
            .into_any_element()
        }
    };
    let holder = div().flex_none().size(px(size)).relative().child(inner);
    if !active || reduce_motion {
        return holder.into_any_element();
    }
    holder
        .with_animation(
            id,
            Animation::new(Duration::from_millis(1400)).repeat(),
            move |d, delta| d.top(px(-size * 0.03 * (1. - (2. * PI * delta).cos()))),
        )
        .into_any_element()
}

/// A room's picture: up to three member faces overlapping in a square of
/// `size` (one face fills it).
pub fn stack(id: &str, faces: &[Face], size: f32, reduce_motion: bool) -> AnyElement {
    let shown = &faces[..faces.len().min(3)];
    let square = div().flex_none().size(px(size)).relative();
    match shown.len() {
        0 => square.into_any_element(),
        1 => square
            .child(face(
                ElementId::Name(format!("{id}-0").into()),
                &shown[0],
                size,
                false,
                reduce_motion,
            ))
            .into_any_element(),
        n => {
            let f = size * if n == 2 { 0.66 } else { 0.56 };
            let at = if n == 2 {
                vec![(0., 0.), (size - f, size - f)]
            } else {
                vec![((size - f) / 2., 0.), (0., size - f), (size - f, size - f)]
            };
            square
                .children(shown.iter().zip(at).enumerate().map(|(i, (one, (x, y)))| {
                    div().absolute().left(px(x)).top(px(y)).child(face(
                        ElementId::Name(format!("{id}-{i}").into()),
                        one,
                        f,
                        false,
                        reduce_motion,
                    ))
                }))
                .into_any_element()
        }
    }
}

/// A `blobatar:` shape as the classic shape the phone draws for it.
fn classic_shape(shape: &str) -> &str {
    let Some(kind) = shape
        .strip_prefix("blobatar")
        .map(|k| k.rsplit(':').next().unwrap_or(""))
    else {
        return shape;
    };
    match kind {
        "capsule" => "pill",
        "cloud" => "cloud",
        "droplet" => "drop",
        "hexagon" => "hexagon",
        "triangle" => "triangle",
        "round" | "sun" => "circle",
        _ => "squircle",
    }
}

/// Relative luminance, as Flutter's `computeLuminance`.
fn luminance(color: Hsla) -> f32 {
    let Rgba { r, g, b, .. } = color.to_rgb();
    let lin = |c: f32| {
        if c <= 0.03928 {
            c / 12.92
        } else {
            ((c + 0.055) / 1.055).powf(2.4)
        }
    };
    0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
}

fn paint_face(bounds: Bounds<Pixels>, shape: &str, color: Hsla, window: &mut Window) {
    let (x0, y0) = (f32::from(bounds.origin.x), f32::from(bounds.origin.y));
    let (w, h) = (f32::from(bounds.size.width), f32::from(bounds.size.height));
    let p = |x: f32, y: f32| -> Point<Pixels> { point(px(x0 + w * x), px(y0 + h * y)) };
    let mut body = PathBuilder::fill();
    match shape {
        "squircle" => rounded_rect(&mut body, p(0.075, 0.075), w * 0.85, h * 0.85, w * 0.275),
        "pill" => rounded_rect(&mut body, p(0.05, 0.175), w * 0.9, h * 0.65, h * 0.325),
        "triangle" => {
            body.move_to(p(0.5, 0.06));
            body.line_to(p(0.93, 0.87));
            body.line_to(p(0.07, 0.87));
            body.close();
        }
        "hexagon" => {
            body.move_to(p(0.5, 0.04));
            for (x, y) in [
                (0.87, 0.25),
                (0.87, 0.75),
                (0.5, 0.96),
                (0.13, 0.75),
                (0.13, 0.25),
            ] {
                body.line_to(p(x, y));
            }
            body.close();
        }
        "cloud" => {
            body.move_to(p(0.27, 0.8));
            body.cubic_bezier_to(p(0.25, 0.43), p(0.02, 0.8), p(0.02, 0.45));
            body.cubic_bezier_to(p(0.75, 0.38), p(0.3, 0.12), p(0.72, 0.14));
            body.cubic_bezier_to(p(0.73, 0.8), p(0.98, 0.36), p(1.0, 0.8));
            body.close();
        }
        "drop" => {
            body.move_to(p(0.5, 0.04));
            body.cubic_bezier_to(p(0.15, 0.68), p(0.5, 0.04), p(0.15, 0.5));
            body.cubic_bezier_to(p(0.85, 0.68), p(0.15, 1.0), p(0.85, 1.0));
            body.cubic_bezier_to(p(0.5, 0.04), p(0.85, 0.5), p(0.5, 0.04));
            body.close();
        }
        _ => ellipse(&mut body, p(0.5, 0.5), w * 0.44, h * 0.44),
    }
    if let Ok(path) = body.build() {
        window.paint_path(path, color);
    }
    let dark = luminance(color) < 0.22;
    let eye: Hsla = if dark {
        gpui_kit::rgb(0xe8dcc3).into()
    } else {
        gpui_kit::rgba(0x000000d9).into()
    };
    let shine: Hsla = if dark {
        gpui_kit::rgba(0x00000099).into()
    } else {
        gpui_kit::rgba(0xffffffd9).into()
    };
    let eye_y = if shape.contains("cloud") { 0.55 } else { 0.43 };
    for x in [0.385, 0.615] {
        let mut ball = PathBuilder::fill();
        ellipse(&mut ball, p(x, eye_y), w * 0.055, h * 0.0625);
        if let Ok(path) = ball.build() {
            window.paint_path(path, eye);
        }
        let mut glint = PathBuilder::fill();
        ellipse(
            &mut glint,
            p(x - 0.014, eye_y - 0.018),
            w * 0.016,
            w * 0.016,
        );
        if let Ok(path) = glint.build() {
            window.paint_path(path, shine);
        }
    }
}

/// An ellipse as four cubic Béziers.
fn ellipse(path: &mut PathBuilder, c: Point<Pixels>, rx: f32, ry: f32) {
    const K: f32 = 0.552_284_8;
    let (cx, cy) = (f32::from(c.x), f32::from(c.y));
    let q = |x: f32, y: f32| point(px(x), px(y));
    path.move_to(q(cx + rx, cy));
    path.cubic_bezier_to(
        q(cx, cy + ry),
        q(cx + rx, cy + ry * K),
        q(cx + rx * K, cy + ry),
    );
    path.cubic_bezier_to(
        q(cx - rx, cy),
        q(cx - rx * K, cy + ry),
        q(cx - rx, cy + ry * K),
    );
    path.cubic_bezier_to(
        q(cx, cy - ry),
        q(cx - rx, cy - ry * K),
        q(cx - rx * K, cy - ry),
    );
    path.cubic_bezier_to(
        q(cx + rx, cy),
        q(cx + rx * K, cy - ry),
        q(cx + rx, cy - ry * K),
    );
    path.close();
}

/// A rectangle with corners of radius `r`, from its top-left corner.
fn rounded_rect(path: &mut PathBuilder, origin: Point<Pixels>, w: f32, h: f32, r: f32) {
    const K: f32 = 0.552_284_8;
    let (x, y) = (f32::from(origin.x), f32::from(origin.y));
    let r = r.min(w / 2.).min(h / 2.);
    let q = |x: f32, y: f32| point(px(x), px(y));
    path.move_to(q(x + r, y));
    path.line_to(q(x + w - r, y));
    path.cubic_bezier_to(
        q(x + w, y + r),
        q(x + w - r + r * K, y),
        q(x + w, y + r - r * K),
    );
    path.line_to(q(x + w, y + h - r));
    path.cubic_bezier_to(
        q(x + w - r, y + h),
        q(x + w, y + h - r + r * K),
        q(x + w - r + r * K, y + h),
    );
    path.line_to(q(x + r, y + h));
    path.cubic_bezier_to(
        q(x, y + h - r),
        q(x + r - r * K, y + h),
        q(x, y + h - r + r * K),
    );
    path.line_to(q(x, y + r));
    path.cubic_bezier_to(q(x + r, y), q(x, y + r - r * K), q(x + r - r * K, y));
    path.close();
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn colours_and_shapes_follow_the_phone() {
        let violet = parse_color("#8b5cf6");
        assert_eq!(parse_color("nonsense"), violet);
        assert_eq!(parse_color("#8B5CF6"), violet);
        assert!(luminance(parse_color("#000000")) < 0.22);
        assert!(luminance(parse_color("#eab308")) > 0.22);
        assert_eq!(classic_shape("blobatar:v1:droplet"), "drop");
        assert_eq!(classic_shape("blobatar:v1:mystery"), "squircle");
        assert_eq!(classic_shape("cloud"), "cloud");
    }
}
