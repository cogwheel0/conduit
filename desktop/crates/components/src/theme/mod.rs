//! Conduit's theme on GPUI: conduit_theme palettes mapped onto GPUI Kit's
//! `Theme`, plus the roles Conduit's own views read ([`ConduitTheme`]).
//!
//! Views never read palette tokens directly for state colours (selection,
//! focus, checked controls); they read [`Roles`], which is where the
//! `accent=mono|system` policy lives.

pub mod contrast;
pub mod palette;
pub mod prefs;

use std::sync::OnceLock;

use gpui_kit::component::{Theme, ThemeMode};
use gpui_kit::{App, Global, Hsla, Pixels, SharedString, px, rgb};

pub use contrast::{composite, contrast_ratio, mix, with_alpha};
pub use palette::{ColorTokens, Palette, PaletteSet, PaletteVariant, SurfaceTokens};
pub use prefs::{
    AccentPolicy, Density, DesignPrefs, Metrics, SidebarStyle, ToolbarLayout, UserMessageStyle,
    VARIANT_KEYS,
};

/// The UI font: SF Pro, through the system font alias.
pub const UI_FONT: &str = ".SystemUIFont";
/// Code font: SF Mono through the system's monospaced alias. (The family
/// name "SF Mono" does not resolve through GPUI's text system and silently
/// falls back to Helvetica.)
pub const MONO_FONT: &str = ".AppleSystemUIFontMonospaced";
/// macOS's default accent (blue), used when the system colour can't be read.
pub const DEFAULT_SYSTEM_ACCENT: u32 = 0x007AFF;
/// How far raised content moves from the column toward the text colour in
/// dark mode: Conduit's #000 column and #ECECEC text give #181818.
pub const DARK_RAISED_LIFT: f32 = DARK_RAMP[1];

/// Dark mode's one ramp of neutral surfaces: each step is the content
/// colour moved this far toward the text colour, so every dark surface is
/// one of four tones of the same grey (Conduit: #000, #181818, #232323,
/// #2F2F2F). Step 0 is the chat column, the Settings and setup pages and
/// every window's backdrop; 1 is what is raised on it (the composer, code,
/// cards, toasts, Settings' groups, Quick Ask's panel, menus); 2 is what
/// sits on a raised surface (a field or a button in a group, a chip in the
/// composer, a table's head); 3 is that one hovered, and tooltips. The
/// sidebar is the system's material, not part of the ramp.
pub const DARK_RAMP: [f32; 4] = [0.0, 0.10, 0.15, 0.20];

/// Step `step` (0–3) of the dark ramp for a palette's content and text
/// colours (see [`DARK_RAMP`]).
pub fn dark_step(content: Hsla, text: Hsla, step: usize) -> Hsla {
    mix(content, text, DARK_RAMP[step.min(DARK_RAMP.len() - 1)])
}

/// The embedded palettes, parsed once.
pub fn palettes() -> &'static PaletteSet {
    static SET: OnceLock<PaletteSet> = OnceLock::new();
    SET.get_or_init(|| PaletteSet::embedded().expect("embedded palettes.json is valid"))
}

/// Colours with a job, derived from the palette, the mode and the prefs.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Roles {
    /// Primary text.
    pub text: Hsla,
    /// Secondary text (AA on every opaque layer).
    pub text_subtle: Hsla,
    /// Icons, hints and placeholders (3:1).
    pub text_faint: Hsla,
    /// The window backdrop behind frames.
    pub window: Hsla,
    /// The chat column and other content frames.
    pub content: Hsla,
    /// Sidebar fill: transparent over the material, or the palette surface.
    pub sidebar: Hsla,
    /// Sidebar text and secondary text (AA on the sidebar surface, the
    /// translucent material and a hovered row).
    pub sidebar_text: Hsla,
    pub sidebar_text_subtle: Hsla,
    /// Secondary text on a selected row (a date, a badge): AA on the
    /// selection fill.
    pub selected_text_subtle: Hsla,
    /// Raised content inside a frame: code blocks, disclosures, cards.
    pub raised: Hsla,
    pub raised_hover: Hsla,
    /// The edge of a control that is off (an unselected radio, an empty
    /// checkbox, an off switch's knob): 3:1 on every layer it sits on, the
    /// WCAG non-text minimum.
    pub control_edge: Hsla,
    /// Menus, popovers and the palette.
    pub overlay: Hsla,
    pub overlay_hover: Hsla,
    /// Row hover (translucent, works on any layer).
    pub hover: Hsla,
    /// Selected row fill.
    pub selected: Hsla,
    /// Icon colour on a selected row.
    pub selected_icon: Hsla,
    /// Focus ring and focused border.
    pub focus: Hsla,
    /// Fill of a checked switch, the chosen segment, a selected radio.
    pub checked: Hsla,
    pub checked_foreground: Hsla,
    /// Text selection highlight.
    pub text_selection: Hsla,
    pub border: Hsla,
    pub border_strong: Hsla,
    /// Hairlines between rows and under toolbars.
    pub divider: Hsla,
    /// The strong colour: send button, primary buttons.
    pub primary: Hsla,
    pub primary_foreground: Hsla,
    pub secondary: Hsla,
    pub secondary_foreground: Hsla,
    /// User message bubble fill (`user=bubble`).
    pub bubble: Hsla,
    /// Destructive text and icons (AA on the content frame).
    pub danger: Hsla,
    /// Fill of a solid destructive button, and its label.
    pub danger_fill: Hsla,
    pub danger_foreground: Hsla,
    pub success: Hsla,
    pub warning: Hsla,
    pub info: Hsla,
    pub link: Hsla,
    /// Translucent scrim behind the palette and sheets.
    pub scrim: Hsla,
}

/// The active Conduit theme. Installed as a GPUI global by [`install`].
#[derive(Clone, Debug, PartialEq)]
pub struct ConduitTheme {
    pub palette_id: SharedString,
    pub dark: bool,
    pub colors: ColorTokens,
    pub surfaces: SurfaceTokens,
    /// The palette's radius (cards, frames).
    pub radius: f32,
    pub prefs: DesignPrefs,
    pub metrics: Metrics,
    pub system_accent: Hsla,
    pub roles: Roles,
}

impl Global for ConduitTheme {}

impl ConduitTheme {
    /// Resolves `palette_id` (falling back to Conduit's own) in one mode.
    pub fn new(palette_id: &str, dark: bool, prefs: DesignPrefs, system_accent: Hsla) -> Self {
        let palette = palettes().get(palette_id);
        let variant = palette.variant(dark);
        let roles = Self::roles(variant, dark, &prefs, system_accent);
        Self {
            palette_id: palette.id.clone().into(),
            dark,
            colors: variant.colors,
            surfaces: variant.surfaces,
            radius: variant.radius,
            prefs,
            metrics: Metrics::for_density(prefs.density),
            system_accent,
            roles,
        }
    }

    fn roles(v: &PaletteVariant, dark: bool, prefs: &DesignPrefs, accent: Hsla) -> Roles {
        let c = &v.colors;
        let s = &v.surfaces;
        let clear = with_alpha(c.foreground, 0.);
        let system = prefs.accent == AccentPolicy::System;
        // Row hover and the selection: a wash of the text colour, the
        // selection about three times the hover, so the two never read as
        // one state (Finder and Mail keep the same gap).
        let hover = with_alpha(c.foreground, if dark { 0.05 } else { 0.04 });
        let (selected, selected_icon, focus, checked, checked_foreground, text_selection) =
            if system {
                (
                    with_alpha(accent, if dark { 0.30 } else { 0.18 }),
                    accent,
                    with_alpha(accent, 0.75),
                    // A checked control's white mark reads at 3:1 whatever
                    // accent the user picked (a yellow one darkens).
                    legible_fill(accent, rgb(0xffffff).into(), 3.0),
                    rgb(0xffffff).into(),
                    with_alpha(accent, if dark { 0.45 } else { 0.28 }),
                )
            } else {
                (
                    // A wash of the text colour, as the phone highlights a
                    // selected row: never an accent, in any palette.
                    with_alpha(c.foreground, if dark { 0.14 } else { 0.12 }),
                    c.foreground,
                    mix(c.ring, c.foreground, 0.25),
                    c.primary,
                    c.primary_foreground,
                    with_alpha(c.foreground, if dark { 0.28 } else { 0.16 }),
                )
            };
        // Raised content (code blocks, tables, cards, the composer). In dark
        // mode a real step up from the column (Conduit: #181818 on #000, as
        // Notes and Messages lift theirs), so depth comes from the fill and
        // not only a hairline; the palette's own 5% wash read as #0C0C0C.
        let (raised_fill, raised_hover) = if dark {
            (
                dark_step(s.panel, c.foreground, 1),
                dark_step(s.panel, c.foreground, 2),
            )
        } else {
            (s.surface, s.surface_hover)
        };
        // Menus, popovers and the palette float on the ramp too in dark:
        // raised, their hovered row two steps up (the palette's own #1A1A1A
        // and #2F2F2F sat beside it).
        let (overlay, overlay_hover) = if dark {
            (
                dark_step(s.panel, c.foreground, 1),
                dark_step(s.panel, c.foreground, 3),
            )
        } else {
            (s.menu, s.menu_hover)
        };
        // Secondary text reads at AA on every layer it is drawn on: the
        // palette's own grey, its lightness moved only as far as that needs
        // (same hue and saturation). The palette files stay as they are.
        let raised = composite(raised_fill, s.panel);
        let content_layers = [
            s.panel,
            s.window,
            s.menu,
            c.card,
            raised,
            composite(raised_hover, s.panel),
            composite(s.menu_hover, s.menu),
            overlay,
            composite(overlay_hover, overlay),
            composite(hover, s.panel),
            composite(hover, raised),
        ];
        // An off control's edge: 3:1 on the column, on raised content and
        // on a field or button one step up (a radio on an approval card, a
        // checkbox in a group). Light keeps the palette's strong border,
        // which macOS's own light controls match.
        let control_edge = if dark {
            legible_lightness(
                s.border_hover,
                &[s.panel, raised, composite(raised_hover, s.panel)],
                true,
                3.0,
            )
        } else {
            s.border_hover
        };
        let text_subtle = legible_lightness(s.foreground_subtle, &content_layers, dark, 4.5);
        // Placeholders and hints: 3:1 on the same layers (a field sits on
        // the ramp's step 2 in a dark group), lightness only, as above.
        let text_faint = legible_lightness(s.foreground_subtlest, &content_layers, dark, 3.0);
        // The sidebar: its solid surface, or the material behind a
        // translucent one (what it shows depends on the desktop, so a
        // representative backdrop at the darker or lighter end stands in),
        // each also under a hovered row.
        let mut sidebar_layers = vec![c.sidebar_background];
        if prefs.sidebar == SidebarStyle::Material {
            sidebar_layers.push(material_backdrop(dark));
        }
        let hovered: Vec<Hsla> = sidebar_layers
            .iter()
            .map(|bg| composite(hover, *bg))
            .collect();
        sidebar_layers.extend(hovered);
        let sidebar_text_subtle =
            legible_lightness(s.foreground_subtle, &sidebar_layers, dark, 4.5);
        let on_selection: Vec<Hsla> = sidebar_layers
            .iter()
            .map(|bg| composite(selected, *bg))
            .collect();
        let selected_text_subtle = legible_lightness(sidebar_text_subtle, &on_selection, dark, 4.5);
        let all_sidebar: Vec<Hsla> = sidebar_layers
            .iter()
            .chain(on_selection.iter())
            .copied()
            .collect();
        let sidebar_text = legible_lightness(
            legible_text(
                c.sidebar_foreground,
                c.foreground,
                c.sidebar_background,
                4.5,
            ),
            &all_sidebar,
            dark,
            4.5,
        );
        Roles {
            text: c.foreground,
            text_subtle,
            text_faint,
            // Dark: every window's backdrop is the content tone (the
            // ramp's step 0), not a second near-black.
            window: if dark { s.panel } else { s.window },
            content: s.panel,
            sidebar: match prefs.sidebar {
                SidebarStyle::Material => clear,
                SidebarStyle::Surface => c.sidebar_background,
            },
            sidebar_text,
            sidebar_text_subtle,
            selected_text_subtle,
            raised: raised_fill,
            raised_hover,
            control_edge,
            overlay,
            overlay_hover,
            hover,
            selected,
            selected_icon,
            focus,
            checked,
            checked_foreground,
            text_selection,
            border: c.border,
            border_strong: s.border_hover,
            divider: c.border,
            primary: legible_fill(c.primary, c.primary_foreground, 4.5),
            primary_foreground: c.primary_foreground,
            secondary: c.secondary,
            secondary_foreground: c.secondary_foreground,
            // The phone's user bubble: the card tone in light, the muted
            // tone in dark. A palette whose light cards are the page's own
            // colour (Clay, T3 Chat) takes its muted tone in light too, or
            // the bubble would vanish into the transcript.
            bubble: if dark || contrast_ratio(c.card, s.panel) < 1.05 {
                c.muted
            } else {
                c.card
            },
            danger: legible_text(c.destructive, c.foreground, s.panel, 4.5),
            danger_fill: legible_fill(c.destructive, c.destructive_foreground, 4.5),
            danger_foreground: c.destructive_foreground,
            success: c.success,
            warning: c.warning,
            info: c.info,
            link: if system {
                legible_text(accent, c.foreground, s.panel, 4.5)
            } else {
                c.foreground
            },
            scrim: with_alpha(rgb(0x000000).into(), if dark { 0.45 } else { 0.18 }),
        }
    }

    /// Radius for controls (buttons, fields, rows): macOS-sized, whatever
    /// the palette's card radius is.
    pub fn control_radius(&self) -> Pixels {
        px(6.)
    }

    /// Radius for sidebar and list rows: a little rounder than controls,
    /// as the phone's row highlights.
    pub fn row_radius(&self) -> Pixels {
        px(7.)
    }

    /// Radius for cards, disclosures and code blocks.
    pub fn card_radius(&self) -> Pixels {
        px(self.radius.clamp(6., 12.))
    }

    /// Radius for overlays (menus, the palette, Quick Ask).
    pub fn overlay_radius(&self) -> Pixels {
        px((self.radius + 2.).clamp(8., 14.))
    }

    /// Writes this theme onto GPUI Kit's `Theme`, so Kit components (inputs,
    /// text views, scrollbars, code highlighting) match.
    pub fn apply_to_kit(&self, t: &mut Theme) {
        let c = &self.colors;
        let s = &self.surfaces;
        let r = &self.roles;
        let hover = |x: Hsla| mix(x, c.foreground, if self.dark { 0.10 } else { 0.08 });
        let active = |x: Hsla| mix(x, c.foreground, if self.dark { 0.18 } else { 0.14 });

        t.font_family = UI_FONT.into();
        t.font_size = px(self.metrics.body);
        t.mono_font_family = MONO_FONT.into();
        t.mono_font_size = px(self.metrics.code);
        t.radius = self.control_radius();
        t.radius_lg = self.card_radius();
        t.shadow = true;

        t.background = s.panel;
        t.foreground = c.foreground;
        t.border = c.border;
        t.input = c.input;
        t.ring = r.focus;
        t.caret = c.foreground;
        t.selection = r.text_selection;
        t.accent = s.menu_hover;
        t.accent_foreground = c.foreground;
        // Kit paints TextView table bodies with its popover colour (via the
        // base `surface` token); Conduit's own overlays use `roles.overlay`,
        // so Kit's popover follows the content frame instead. (Catppuccin's
        // menu grey filled every table otherwise.) In dark mode a table is
        // raised content, as a code block is.
        t.popover = if self.dark { r.raised } else { s.panel };
        t.popover_foreground = c.foreground;
        t.muted = c.muted;
        // The grey held to AA on every content layer, as Conduit's views.
        t.muted_foreground = r.text_subtle;
        t.link = r.link;
        t.link_hover = r.link;
        t.link_active = r.link;

        t.primary = r.primary;
        t.primary_foreground = r.primary_foreground;
        t.primary_hover = hover(r.primary);
        t.primary_active = active(r.primary);
        t.secondary = c.secondary;
        t.secondary_foreground = c.secondary_foreground;
        t.secondary_hover = hover(c.secondary);
        t.secondary_active = active(c.secondary);
        t.button = c.secondary;
        t.button_foreground = c.secondary_foreground;
        t.button_hover = hover(c.secondary);
        t.button_active = active(c.secondary);
        t.button_primary = r.primary;
        t.button_primary_foreground = r.primary_foreground;
        t.button_primary_hover = hover(r.primary);
        t.button_primary_active = active(r.primary);
        t.button_secondary = c.secondary;
        t.button_secondary_foreground = c.secondary_foreground;
        t.button_secondary_hover = hover(c.secondary);
        t.button_secondary_active = active(c.secondary);

        t.danger = r.danger_fill;
        t.danger_foreground = r.danger_foreground;
        t.danger_hover = hover(r.danger_fill);
        t.danger_active = active(r.danger_fill);
        t.button_danger = r.danger_fill;
        t.button_danger_foreground = r.danger_foreground;
        t.button_danger_hover = hover(r.danger_fill);
        t.button_danger_active = active(r.danger_fill);
        t.success = c.success;
        t.success_foreground = c.success_foreground;
        t.success_hover = hover(c.success);
        t.success_active = active(c.success);
        t.warning = c.warning;
        t.warning_foreground = c.warning_foreground;
        t.warning_hover = hover(c.warning);
        t.warning_active = active(c.warning);
        t.info = c.info;
        t.info_foreground = c.info_foreground;
        t.info_hover = hover(c.info);
        t.info_active = active(c.info);

        t.sidebar = r.sidebar;
        t.sidebar_foreground = c.sidebar_foreground;
        t.sidebar_accent = r.selected;
        t.sidebar_accent_foreground = c.sidebar_accent_foreground;
        t.sidebar_border = c.sidebar_border;
        t.sidebar_primary = c.sidebar_primary;
        t.sidebar_primary_foreground = c.sidebar_primary_foreground;

        t.colors.list = s.panel;
        t.list_hover = s.hover;
        t.list_active = r.selected;
        t.list_active_border = r.focus;
        t.list_even = s.surface;
        t.list_head = s.panel;
        t.scrollbar = with_alpha(c.foreground, 0.);
        t.scrollbar_thumb = with_alpha(c.foreground, if self.dark { 0.28 } else { 0.22 });
        t.scrollbar_thumb_hover = with_alpha(c.foreground, if self.dark { 0.42 } else { 0.36 });
        t.switch = c.input;
        t.switch_thumb = rgb(0xffffff).into();
        t.slider_bar = r.checked;
        t.slider_thumb = rgb(0xffffff).into();
        t.progress_bar = r.checked;
        t.skeleton = c.muted;
        t.tab = s.tab;
        t.tab_active = s.tab_active;
        t.tab_active_foreground = c.foreground;
        t.tab_bar = s.tab;
        t.tab_foreground = r.text_subtle;
        t.title_bar = s.header;
        t.title_bar_border = c.border;
        t.window_border = c.border;
        t.overlay = r.scrim;
        t.drag_border = r.focus;
        t.drop_target = with_alpha(r.checked, 0.12);
        t.group_box = s.surface;
        t.group_box_foreground = c.foreground;
        // The header row one step above the body (dark: #232323 on #181818).
        t.table_head = if self.dark { r.raised_hover } else { s.surface };
        t.table_head_foreground = c.foreground;
        t.table_hover = s.hover;
        t.table_row_border = c.border;
        t.accordion = s.surface;
    }
}

/// `fill` darkened (under a light label) or lightened (under a dark one)
/// until `label` reads at `ratio` on it. Keeps the palette's hue and its
/// label colour, which is what the palette meant; the Dart
/// `accessibleColors` does the same for the destructive red.
pub fn legible_fill(fill: Hsla, label: Hsla, ratio: f32) -> Hsla {
    let toward: Hsla = if contrast::relative_luminance(label) > 0.5 {
        rgb(0x000000).into()
    } else {
        rgb(0xffffff).into()
    };
    let mut value = fill;
    for _ in 0..40 {
        if contrast_ratio(label, value) >= ratio {
            break;
        }
        value = mix(value, toward, 0.04);
    }
    value
}

/// What the translucent sidebar material shows at its lighter (dark mode)
/// or darker (light mode) end, for contrast checks: AppKit's sidebar
/// material over an ordinary desktop measures about #DDDDDD in light mode
/// and #22252D in dark mode, so these leave a margin either way.
pub fn material_backdrop(dark: bool) -> Hsla {
    if dark {
        rgb(0x333336).into()
    } else {
        rgb(0xD6D6D6).into()
    }
}

/// `color` with only its lightness moved (darker on light layers, lighter
/// on dark ones) until it reads at `ratio` on every one of `layers`. Hue and
/// saturation stay the palette's, so a warm grey stays warm.
pub fn legible_lightness(color: Hsla, layers: &[Hsla], dark: bool, ratio: f32) -> Hsla {
    let reads = |c: Hsla| {
        layers
            .iter()
            .all(|bg| contrast_ratio(c, *bg) + 1e-4 >= ratio)
    };
    let mut value = color;
    for _ in 0..200 {
        if reads(value) {
            break;
        }
        value.l = if dark {
            (value.l + 0.005).min(1.)
        } else {
            (value.l - 0.005).max(0.)
        };
    }
    value
}

/// `color` moved toward `foreground` until it reads at `ratio` on `bg`.
pub fn legible_text(color: Hsla, foreground: Hsla, bg: Hsla, ratio: f32) -> Hsla {
    let mut value = color;
    for _ in 0..40 {
        if contrast_ratio(value, bg) >= ratio {
            break;
        }
        value = mix(value, foreground, 0.06);
    }
    value
}

/// Reads the active [`ConduitTheme`].
pub trait ActiveConduitTheme {
    fn conduit(&self) -> &ConduitTheme;
}

impl ActiveConduitTheme for App {
    fn conduit(&self) -> &ConduitTheme {
        self.global::<ConduitTheme>()
    }
}

/// Installs `theme` as the global Conduit theme and mirrors it onto GPUI
/// Kit's theme (loading Kit's light or dark base first, which carries the
/// code highlight theme).
pub fn install(theme: ConduitTheme, cx: &mut App) {
    let mode = if theme.dark {
        ThemeMode::Dark
    } else {
        ThemeMode::Light
    };
    Theme::change(mode, None, cx);
    Theme::update(cx, |t| theme.apply_to_kit(t));
    install_text_defaults(&theme, cx);
    cx.set_global(theme);
    cx.refresh_windows();
}

/// Rich text as Kit draws it, but with tables in hairlines: a quiet header
/// fill and a rule between rows, no box around the table and no column
/// lines, as Notes and Pages draw a simple table. (Kit installs its own
/// defaults on every theme change; this replaces only their style, keeping
/// its code highlighter and text-colour inheritance.)
fn install_text_defaults(theme: &ConduitTheme, cx: &mut App) {
    use gpui_kit::{HighlightStyle, StyleRefinement, Styled as _};
    let kit = Theme::global(cx).clone();
    let radius = theme.card_radius();
    let mut corners = StyleRefinement::default();
    corners.corner_radii.top_left = Some(radius.into());
    corners.corner_radii.top_right = Some(radius.into());
    corners.corner_radii.bottom_left = Some(radius.into());
    corners.corner_radii.bottom_right = Some(radius.into());
    let code_block = corners.clone();
    let mut table = corners;
    table.border_widths.top = Some(px(0.).into());
    table.border_widths.right = Some(px(0.).into());
    table.border_widths.bottom = Some(px(0.).into());
    table.border_widths.left = Some(px(0.).into());
    let cell = StyleRefinement {
        border_color: Some(with_alpha(kit.border, 0.)),
        ..Default::default()
    };
    let head = StyleRefinement::default()
        .bg(kit.table_head)
        .text_color(kit.table_head_foreground)
        .font_weight(gpui_kit::FontWeight::SEMIBOLD);
    let style = gpui_kit::base::TextViewStyle::default()
        .with_foreground(kit.foreground)
        .with_muted_foreground(kit.muted_foreground)
        .with_link(kit.link)
        .with_selection(kit.selection)
        .with_code_background(kit.muted)
        .with_border(kit.border)
        .with_code_block(code_block)
        .with_table(table)
        .with_table_head(head)
        .with_table_cell(cell)
        .with_inline_code(HighlightStyle {
            background_color: Some(kit.accent),
            ..Default::default()
        })
        .with_dark(theme.dark);
    gpui_kit::base::TextViewDefaults::global(cx)
        .with_style(style)
        .install(cx);
}

#[cfg(test)]
mod tests;
