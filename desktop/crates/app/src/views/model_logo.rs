//! Direct models' makers, by their models.dev logos: the same bundled set
//! mobile ships (`assets/model_logos`), so a logo never needs the network.
//! The daemon picks which logo a model gets (core's `ModelLogoCatalog`,
//! `ModelSummary.logo`); this only draws it, inked in one colour as the
//! phone does, and serves the SVGs to GPUI as assets under `model_logos/`.

use std::borrow::Cow;

use conduit_components::ActiveConduitTheme as _;
use conduit_components::assets::ConduitAssets;
use conduit_components::theme::with_alpha;
use gpui_kit::prelude::*;
use gpui_kit::{App, AssetSource, Div, Hsla, SharedString, Svg, div, px, svg};

mod table {
    include!(concat!(env!("OUT_DIR"), "/model_logos.rs"));
}

pub use table::MODEL_LOGO_CATALOG_DIR;

/// Where the logos live among the app's assets.
const PREFIX: &str = "model_logos/";

/// The logo `id`'s SVG, if the app bundles it.
pub fn bytes(id: &str) -> Option<&'static [u8]> {
    let logos = table::MODEL_LOGOS;
    logos
        .binary_search_by(|(k, _)| (*k).cmp(id))
        .ok()
        .map(|i| logos[i].1)
}

/// Whether the app can draw `id`.
pub fn known(id: &str) -> bool {
    bytes(id).is_some()
}

/// The logo `id`, `size` points square, in `color`; None when the app does
/// not bundle it (the caller draws its fallback).
pub fn logo(id: &str, size: f32, color: Hsla) -> Option<Svg> {
    known(id).then(|| {
        svg()
            .path(SharedString::from(format!("{PREFIX}{id}.svg")))
            .size(px(size))
            .flex_none()
            .text_color(color)
    })
}

/// A settings row for a model: its maker's logo on a tile (or its
/// initial), the name over `subtitle`, and `control` trailing, as
/// [`conduit_components::views::kit::setting_row`] lays rows out.
pub fn model_row(
    logo_id: Option<&str>,
    name: impl Into<SharedString>,
    subtitle: Option<SharedString>,
    control: impl IntoElement,
    cx: &App,
) -> Div {
    let t = cx.conduit();
    let r = t.roles;
    let name: SharedString = name.into();
    let mark = match logo_id.and_then(|id| logo(id, 15., r.text)) {
        Some(svg) => svg.into_any_element(),
        None => div()
            .text_size(px(t.metrics.small))
            .text_color(r.text_subtle)
            .child(SharedString::from(
                name.chars()
                    .next()
                    .map(|c| c.to_uppercase().to_string())
                    .unwrap_or_default(),
            ))
            .into_any_element(),
    };
    div()
        .w_full()
        .min_h(px(t.metrics.row_height + 16.))
        .px(px(12.))
        .py(px(8.))
        .flex()
        .items_center()
        .gap(px(12.))
        .child(
            div()
                .size(px(26.))
                .flex_none()
                .flex()
                .items_center()
                .justify_center()
                .rounded(px(7.))
                .bg(with_alpha(r.text, if t.dark { 0.12 } else { 0.06 }))
                .child(mark),
        )
        .child(
            div()
                .flex_1()
                .min_w_0()
                .flex()
                .flex_col()
                .gap(px(2.))
                .child(
                    div()
                        .truncate()
                        .text_size(px(t.metrics.control))
                        .text_color(r.text)
                        .child(name),
                )
                .when_some(subtitle, |d, s| {
                    d.child(
                        div()
                            .truncate()
                            .text_size(px(t.metrics.small))
                            .text_color(r.text_subtle)
                            .child(s),
                    )
                }),
        )
        .child(control)
}

/// The app's assets: the logos, then Conduit's icons and mark.
pub struct AppAssets;

impl AssetSource for AppAssets {
    fn load(&self, path: &str) -> gpui_kit::Result<Option<Cow<'static, [u8]>>> {
        if let Some(id) = path
            .strip_prefix(PREFIX)
            .and_then(|p| p.strip_suffix(".svg"))
        {
            return Ok(bytes(id).map(Cow::Borrowed));
        }
        ConduitAssets.load(path)
    }

    fn list(&self, path: &str) -> gpui_kit::Result<Vec<SharedString>> {
        let mut paths = ConduitAssets.list(path)?;
        if PREFIX.starts_with(path) || path.starts_with(PREFIX) {
            paths.extend(
                table::MODEL_LOGOS
                    .iter()
                    .map(|(id, _)| SharedString::from(format!("{PREFIX}{id}.svg")))
                    .filter(|p| p.starts_with(path)),
            );
        }
        Ok(paths)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_bundled_logos_are_sorted_and_served() {
        let ids: Vec<&str> = table::MODEL_LOGOS.iter().map(|(k, _)| *k).collect();
        let mut sorted = ids.clone();
        sorted.sort();
        assert_eq!(ids, sorted);
        assert!(ids.len() > 100, "the models.dev set");
        for id in ["openai", "ollama-cloud", "openrouter", "meta"] {
            assert!(known(id), "{id}");
            let svg = AppAssets
                .load(&format!("model_logos/{id}.svg"))
                .unwrap()
                .unwrap();
            assert!(svg.starts_with(b"<svg"), "{id}");
        }
        assert!(!known("not-a-maker"));
        assert!(
            AppAssets
                .load("model_logos/not-a-maker.svg")
                .unwrap()
                .is_none()
        );
        // Everything else is still Conduit's.
        assert!(
            AppAssets
                .load(conduit_components::assets::BRAND_MARK)
                .unwrap()
                .is_some()
        );
    }
}
