//! The computed conduit_theme palettes, read from the JSON that
//! `packages/conduit_theme/bin/export_theme_json.dart` writes.
//!
//! The Dart registry stays the single source of truth: this module only parses
//! its output, so a palette edit reaches the native app by regenerating
//! `assets/themes/palettes.json` (a Dart test fails while it is stale).

use std::collections::BTreeMap;

use gpui_kit::{Hsla, Rgba};
use serde::Deserialize;

/// The generated palettes, embedded at build time.
pub const PALETTES_JSON: &str = include_str!("../../assets/themes/palettes.json");

/// The file shape this reader understands (`kDesktopThemeJsonVersion`).
pub const PALETTES_JSON_VERSION: u32 = 1;

/// Errors from reading the palette file.
#[derive(Debug, Clone, PartialEq)]
pub enum PaletteError {
    Json(String),
    Version(u32),
    MissingToken {
        palette: String,
        token: &'static str,
    },
    BadColor {
        palette: String,
        token: String,
        value: String,
    },
}

impl std::fmt::Display for PaletteError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Json(e) => write!(f, "palettes.json: {e}"),
            Self::Version(v) => write!(
                f,
                "palettes.json version {v}, expected {PALETTES_JSON_VERSION}"
            ),
            Self::MissingToken { palette, token } => {
                write!(f, "palette {palette} has no {token}")
            }
            Self::BadColor {
                palette,
                token,
                value,
            } => write!(f, "palette {palette}: {token} = {value:?} is not #RRGGBBAA"),
        }
    }
}

impl std::error::Error for PaletteError {}

/// Declares a struct with one `Hsla` field per JSON token, in file order.
macro_rules! token_struct {
    ($(#[$meta:meta])* $name:ident { $($field:ident = $key:literal,)* }) => {
        $(#[$meta])*
        #[derive(Clone, Copy, Debug, PartialEq)]
        pub struct $name {
            $(pub $field: Hsla,)*
        }

        impl $name {
            /// The JSON token names, in the order the Dart side writes them.
            pub const KEYS: &'static [&'static str] = &[$($key,)*];

            fn from_map(
                palette: &str,
                map: &BTreeMap<String, String>,
            ) -> Result<Self, PaletteError> {
                Ok(Self {
                    $($field: {
                        let value = map.get($key).ok_or_else(|| PaletteError::MissingToken {
                            palette: palette.to_string(),
                            token: $key,
                        })?;
                        parse_color(value).ok_or_else(|| PaletteError::BadColor {
                            palette: palette.to_string(),
                            token: $key.to_string(),
                            value: value.clone(),
                        })?
                    },)*
                })
            }

            /// Every token as `(name, colour)`.
            pub fn entries(&self) -> Vec<(&'static str, Hsla)> {
                vec![$(($key, self.$field),)*]
            }

            /// Replaces the tokens named in `overrides` (used for the
            /// accessible-colour adjustments).
            #[allow(dead_code)]
            fn with_overrides(
                mut self,
                palette: &str,
                overrides: &BTreeMap<String, String>,
            ) -> Result<Self, PaletteError> {
                for (key, value) in overrides {
                    let color = parse_color(value).ok_or_else(|| PaletteError::BadColor {
                        palette: palette.to_string(),
                        token: key.clone(),
                        value: value.clone(),
                    })?;
                    match key.as_str() {
                        $($key => self.$field = color,)*
                        _ => {}
                    }
                }
                Ok(self)
            }
        }
    };
}

token_struct! {
    /// The 33 tweakcn colour tokens every palette defines.
    ColorTokens {
        background = "background",
        foreground = "foreground",
        card = "card",
        card_foreground = "cardForeground",
        popover = "popover",
        popover_foreground = "popoverForeground",
        primary = "primary",
        primary_foreground = "primaryForeground",
        secondary = "secondary",
        secondary_foreground = "secondaryForeground",
        muted = "muted",
        muted_foreground = "mutedForeground",
        accent = "accent",
        accent_foreground = "accentForeground",
        destructive = "destructive",
        destructive_foreground = "destructiveForeground",
        border = "border",
        input = "input",
        ring = "ring",
        sidebar_background = "sidebarBackground",
        sidebar_foreground = "sidebarForeground",
        sidebar_primary = "sidebarPrimary",
        sidebar_primary_foreground = "sidebarPrimaryForeground",
        sidebar_accent = "sidebarAccent",
        sidebar_accent_foreground = "sidebarAccentForeground",
        sidebar_border = "sidebarBorder",
        sidebar_ring = "sidebarRing",
        success = "success",
        success_foreground = "successForeground",
        warning = "warning",
        warning_foreground = "warningForeground",
        info = "info",
        info_foreground = "infoForeground",
    }
}

token_struct! {
    /// The desktop's 17 layered surface tokens (`kSurfaceTokens`). Unlike the
    /// colour tokens these may be translucent.
    SurfaceTokens {
        window = "window",
        panel = "panel",
        header = "header",
        surface = "surface",
        surface_hover = "surfaceHover",
        menu = "menu",
        menu_hover = "menuHover",
        hover = "hover",
        selected = "selected",
        border_hover = "borderHover",
        foreground_subtle = "foregroundSubtle",
        foreground_subtlest = "foregroundSubtlest",
        tab = "tab",
        tab_active = "tabActive",
        brand = "brand",
        tooltip = "tooltip",
        tooltip_foreground = "tooltipForeground",
    }
}

/// One palette in one brightness, resolved.
#[derive(Clone, Debug, PartialEq)]
pub struct PaletteVariant {
    /// Corner radius in points.
    pub radius: f32,
    /// The colour tokens with the accessible-colour adjustments applied (what
    /// the window paints).
    pub colors: ColorTokens,
    /// The colour tokens exactly as the palette defines them.
    pub raw_colors: ColorTokens,
    pub surfaces: SurfaceTokens,
    /// Names of the tokens the accessible-colour pass moved.
    pub adjusted: Vec<String>,
}

/// A palette with both brightness variants.
#[derive(Clone, Debug, PartialEq)]
pub struct Palette {
    /// Stable id persisted in settings, e.g. `conduit`.
    pub id: String,
    /// ARB keys for the display name and description.
    pub label_key: String,
    pub description_key: String,
    /// Three swatches for the palette picker.
    pub preview: Vec<Hsla>,
    pub light: PaletteVariant,
    pub dark: PaletteVariant,
}

impl Palette {
    pub fn variant(&self, dark: bool) -> &PaletteVariant {
        if dark { &self.dark } else { &self.light }
    }
}

/// Every desktop palette, in picker order, plus the default's id.
#[derive(Clone, Debug, PartialEq)]
pub struct PaletteSet {
    pub default_id: String,
    pub palettes: Vec<Palette>,
}

impl PaletteSet {
    /// Parses the embedded [`PALETTES_JSON`].
    pub fn embedded() -> Result<Self, PaletteError> {
        Self::parse(PALETTES_JSON)
    }

    pub fn parse(json: &str) -> Result<Self, PaletteError> {
        let file: FileDef =
            serde_json::from_str(json).map_err(|e| PaletteError::Json(e.to_string()))?;
        if file.version != PALETTES_JSON_VERSION {
            return Err(PaletteError::Version(file.version));
        }
        let palettes = file
            .palettes
            .into_iter()
            .map(|p| {
                let preview = p
                    .preview
                    .iter()
                    .map(|v| {
                        parse_color(v).ok_or_else(|| PaletteError::BadColor {
                            palette: p.id.clone(),
                            token: "preview".into(),
                            value: v.clone(),
                        })
                    })
                    .collect::<Result<Vec<_>, _>>()?;
                Ok(Palette {
                    light: p.light.resolve(&p.id)?,
                    dark: p.dark.resolve(&p.id)?,
                    id: p.id,
                    label_key: p.label_key,
                    description_key: p.description_key,
                    preview,
                })
            })
            .collect::<Result<Vec<_>, PaletteError>>()?;
        Ok(Self {
            default_id: file.default_palette,
            palettes,
        })
    }

    /// The palette with `id`, falling back to the default (as the Dart
    /// `desktopPaletteById` does), then to the first.
    pub fn get(&self, id: &str) -> &Palette {
        self.palettes
            .iter()
            .find(|p| p.id == id)
            .or_else(|| self.palettes.iter().find(|p| p.id == self.default_id))
            .unwrap_or(&self.palettes[0])
    }

    pub fn ids(&self) -> impl Iterator<Item = &str> {
        self.palettes.iter().map(|p| p.id.as_str())
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct FileDef {
    version: u32,
    default_palette: String,
    palettes: Vec<PaletteDef>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct PaletteDef {
    id: String,
    label_key: String,
    description_key: String,
    preview: Vec<String>,
    light: VariantDef,
    dark: VariantDef,
}

#[derive(Deserialize)]
struct VariantDef {
    radius: f32,
    colors: BTreeMap<String, String>,
    surfaces: BTreeMap<String, String>,
    #[serde(default)]
    accessible: BTreeMap<String, String>,
}

impl VariantDef {
    fn resolve(&self, palette: &str) -> Result<PaletteVariant, PaletteError> {
        let raw_colors = ColorTokens::from_map(palette, &self.colors)?;
        Ok(PaletteVariant {
            radius: self.radius,
            colors: raw_colors.with_overrides(palette, &self.accessible)?,
            raw_colors,
            surfaces: SurfaceTokens::from_map(palette, &self.surfaces)?,
            adjusted: self.accessible.keys().cloned().collect(),
        })
    }
}

/// Parses `#RRGGBBAA` (or `#RRGGBB`).
pub fn parse_color(value: &str) -> Option<Hsla> {
    let hex = value.strip_prefix('#')?;
    let packed = u32::from_str_radix(hex, 16).ok()?;
    let rgba = match hex.len() {
        8 => packed,
        6 => (packed << 8) | 0xFF,
        _ => return None,
    };
    Some(gpui_kit::rgba(rgba).into())
}

/// `color` as `#RRGGBBAA`, for logs and tests.
pub fn to_hex(color: Hsla) -> String {
    let c: Rgba = color.into();
    let byte = |v: f32| (v.clamp(0., 1.) * 255.).round() as u8;
    format!(
        "#{:02X}{:02X}{:02X}{:02X}",
        byte(c.r),
        byte(c.g),
        byte(c.b),
        byte(c.a)
    )
}
