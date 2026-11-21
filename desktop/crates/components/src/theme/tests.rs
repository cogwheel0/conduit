use super::*;
use gpui_kit::rgb;

fn accent() -> Hsla {
    rgb(DEFAULT_SYSTEM_ACCENT).into()
}

#[test]
fn embedded_palettes_parse_with_every_token() {
    let set = palettes();
    assert_eq!(set.default_id, "conduit");
    let ids: Vec<&str> = set.ids().collect();
    // Exactly the phone's palettes, in its order.
    assert_eq!(
        ids,
        ["conduit", "claude", "t3_chat", "catppuccin", "tangerine"]
    );
    assert_eq!(ColorTokens::KEYS.len(), 33);
    assert_eq!(SurfaceTokens::KEYS.len(), 17);

    // The Rust token lists must match what the Dart exporter declares, so a
    // token added on the Dart side cannot be silently dropped here.
    let doc: serde_json::Value = serde_json::from_str(palette::PALETTES_JSON).unwrap();
    let names = |key: &str| -> Vec<String> {
        doc[key]
            .as_array()
            .unwrap()
            .iter()
            .map(|v| v.as_str().unwrap().to_string())
            .collect()
    };
    assert_eq!(names("colorTokens"), ColorTokens::KEYS);
    assert_eq!(names("surfaceTokens"), SurfaceTokens::KEYS);

    for p in &set.palettes {
        for v in [&p.light, &p.dark] {
            assert_eq!(v.colors.entries().len(), 33, "{}", p.id);
            assert_eq!(v.surfaces.entries().len(), 17, "{}", p.id);
            assert!(v.radius > 0., "{}", p.id);
            // Colour tokens are opaque; a 0 alpha would render invisibly.
            for (name, color) in v.raw_colors.entries() {
                assert!(
                    (color.a - 1.).abs() < 1e-3,
                    "{}.{name} is translucent",
                    p.id
                );
            }
        }
        assert_eq!(p.preview.len(), 3);
    }
}

#[test]
fn unknown_palette_falls_back_to_conduit() {
    assert_eq!(palettes().get("no-such").id, "conduit");
    // The retired desktop-only palette too.
    assert_eq!(palettes().get("zai").id, "conduit");
    let t = ConduitTheme::new("no-such", false, DesignPrefs::default(), accent());
    assert_eq!(t.palette_id.as_ref(), "conduit");
}

#[test]
fn accessible_adjustments_are_applied() {
    let conduit = palettes().get("conduit");
    assert_eq!(conduit.light.adjusted, vec!["destructive".to_string()]);
    assert_ne!(
        conduit.light.colors.destructive,
        conduit.light.raw_colors.destructive
    );
    assert_eq!(
        palette::to_hex(conduit.light.colors.destructive),
        "#C33838FF",
        "matches the Dart accessibleColors output"
    );
}

#[test]
fn colour_round_trip() {
    for hex in ["#000000FF", "#FFFFFFFF", "#0D0D0D0D", "#BE2929FF"] {
        assert_eq!(palette::to_hex(palette::parse_color(hex).unwrap()), hex);
    }
    assert!(palette::parse_color("BE2929").is_none());
    assert!(palette::parse_color("#BE29").is_none());
}

/// Every pair the views use for body or control text meets WCAG AA (4.5:1),
/// in every palette and mode, and icon/hint colours meet 3:1.
#[test]
fn text_pairs_meet_wcag_aa() {
    let mut failures = vec![];
    for p in &palettes().palettes {
        for dark in [false, true] {
            for (policy, sidebar) in [
                (AccentPolicy::Mono, SidebarStyle::Material),
                (AccentPolicy::Mono, SidebarStyle::Surface),
                (AccentPolicy::System, SidebarStyle::Material),
                (AccentPolicy::System, SidebarStyle::Surface),
            ] {
                let system_accent = accent();
                let prefs = DesignPrefs {
                    accent: policy,
                    sidebar,
                    ..Default::default()
                };
                let t = ConduitTheme::new(&p.id, dark, prefs, system_accent);
                let c = &t.colors;
                let s = &t.surfaces;
                let r = &t.roles;
                let mode = if dark { "dark" } else { "light" };
                let mut check = |name: &str, fg: Hsla, bg: Hsla, min: f32| {
                    let ratio = contrast_ratio(fg, bg);
                    if ratio + 1e-3 < min {
                        failures.push(format!(
                            "{} {mode} {policy:?} {sidebar:?} {}: {name} = {ratio:.2} < {min}",
                            p.id,
                            palette::to_hex(system_accent)
                        ));
                    }
                };
                for (layer, bg) in [
                    ("panel", s.panel),
                    ("window", s.window),
                    ("menu", s.menu),
                    ("card", c.card),
                ] {
                    check(&format!("text on {layer}"), r.text, bg, 4.5);
                    check(&format!("subtle on {layer}"), r.text_subtle, bg, 4.5);
                    check(&format!("faint on {layer}"), r.text_faint, bg, 3.0);
                }
                // Secondary text (dates, section headers, captions, tool
                // arguments) on everything it is drawn on.
                let raised = composite(r.raised, s.panel);
                for (layer, bg) in [
                    ("raised block", raised),
                    (
                        "table head or chip on raised",
                        composite(r.raised_hover, s.panel),
                    ),
                    ("menu row hover", composite(r.overlay_hover, s.menu)),
                    ("hovered row", composite(r.hover, s.panel)),
                    ("hovered raised row", composite(r.hover, raised)),
                ] {
                    check(&format!("subtle on {layer}"), r.text_subtle, bg, 4.5);
                }
                check("text on sidebar", r.sidebar_text, c.sidebar_background, 4.5);
                let mut sidebar_layers = vec![("sidebar", c.sidebar_background)];
                if sidebar == SidebarStyle::Material {
                    sidebar_layers.push(("sidebar material", material_backdrop(dark)));
                }
                for (layer, bg) in sidebar_layers {
                    check(
                        &format!("subtle on {layer}"),
                        r.sidebar_text_subtle,
                        bg,
                        4.5,
                    );
                    check(
                        &format!("subtle on a hovered row on {layer}"),
                        r.sidebar_text_subtle,
                        composite(r.hover, bg),
                        4.5,
                    );
                    check(
                        &format!("subtle on a selected row on {layer}"),
                        r.selected_text_subtle,
                        composite(r.selected, bg),
                        4.5,
                    );
                    check(
                        &format!("text on a selected row on {layer}"),
                        r.sidebar_text,
                        composite(r.selected, bg),
                        4.5,
                    );
                    // A focused list's darker selection.
                    let key = crate::views::focus::selection_fill(&t, true);
                    let on_key = |c| crate::views::focus::on_selection(c, &t, true);
                    check(
                        &format!("subtle on a key list's selected row on {layer}"),
                        on_key(r.selected_text_subtle),
                        composite(key, bg),
                        4.5,
                    );
                    check(
                        &format!("text on a key list's selected row on {layer}"),
                        on_key(r.sidebar_text),
                        composite(key, bg),
                        4.5,
                    );
                }
                check(
                    "text on selected row",
                    r.text,
                    composite(r.selected, c.sidebar_background),
                    4.5,
                );
                check(
                    "text on hovered row",
                    r.text,
                    composite(r.hover, c.sidebar_background),
                    4.5,
                );
                check("text in bubble", r.text, r.bubble, 4.5);
                check(
                    "text on raised block",
                    r.text,
                    composite(r.raised, s.panel),
                    4.5,
                );
                check("primary button", r.primary_foreground, r.primary, 4.5);
                check("secondary button", r.secondary_foreground, r.secondary, 4.5);
                check("danger text", r.danger, s.panel, 4.5);
                check("danger button", r.danger_foreground, r.danger_fill, 4.5);
                check("checked control", r.checked_foreground, r.checked, 3.0);
                check("link on panel", r.link, s.panel, 4.5);
                check("focus ring on panel", r.focus, s.panel, 1.5);
            }
        }
    }
    // The system accent is the user's choice: a bright one, which white
    // text and a light panel both fail on, still gives a readable checked
    // control and link.
    for p in &palettes().palettes {
        for dark in [false, true] {
            let prefs = DesignPrefs {
                accent: AccentPolicy::System,
                ..Default::default()
            };
            let t = ConduitTheme::new(&p.id, dark, prefs, rgb(0xFFCC00).into());
            let r = &t.roles;
            for (name, fg, bg, min) in [
                ("checked control", r.checked_foreground, r.checked, 3.0),
                ("link on panel", r.link, t.surfaces.panel, 4.5),
            ] {
                let ratio = contrast_ratio(fg, bg);
                if ratio + 1e-3 < min {
                    failures.push(format!(
                        "{} {} #FFCC00: {name} = {ratio:.2} < {min}",
                        p.id,
                        if dark { "dark" } else { "light" }
                    ));
                }
            }
        }
    }
    assert!(failures.is_empty(), "{}", failures.join("\n"));
}

/// Secondary text keeps the palette's hue and saturation: only its
/// lightness moves, and only as far as AA needs.
#[test]
fn secondary_text_keeps_the_palette_hue() {
    for p in &palettes().palettes {
        for dark in [false, true] {
            let t = ConduitTheme::new(&p.id, dark, DesignPrefs::default(), accent());
            let raw = t.surfaces.foreground_subtle;
            for (name, role) in [
                ("text_subtle", t.roles.text_subtle),
                ("sidebar_text_subtle", t.roles.sidebar_text_subtle),
                ("selected_text_subtle", t.roles.selected_text_subtle),
            ] {
                assert!(
                    (role.h - raw.h).abs() < 1e-4 && (role.s - raw.s).abs() < 1e-4,
                    "{} {dark}: {name} changed hue or saturation",
                    p.id
                );
                // Moved away from the page, never toward it.
                if dark {
                    assert!(role.l >= raw.l - 1e-4, "{} {name}", p.id);
                } else {
                    assert!(role.l <= raw.l + 1e-4, "{} {name}", p.id);
                }
            }
        }
    }
    // A grey that already reads is left alone.
    let fine: Hsla = rgb(0x555555).into();
    assert_eq!(
        legible_lightness(fine, &[rgb(0xffffff).into()], false, 4.5),
        fine
    );
}

/// The selection is clearly heavier than a hover, in every palette.
#[test]
fn selection_is_well_apart_from_hover() {
    for p in &palettes().palettes {
        for dark in [false, true] {
            let t = ConduitTheme::new(&p.id, dark, DesignPrefs::default(), accent());
            let r = t.roles;
            assert!(
                r.selected.a >= 2.5 * r.hover.a,
                "{} {dark}: selected {} vs hover {}",
                p.id,
                r.selected.a,
                r.hover.a
            );
        }
    }
}

#[test]
fn accent_policy_only_moves_selection_and_focus() {
    let mono = ConduitTheme::new("conduit", false, DesignPrefs::default(), accent());
    let system = ConduitTheme::new(
        "conduit",
        false,
        DesignPrefs {
            accent: AccentPolicy::System,
            ..Default::default()
        },
        accent(),
    );
    assert_ne!(mono.roles.selected, system.roles.selected);
    assert_ne!(mono.roles.focus, system.roles.focus);
    assert_ne!(mono.roles.checked, system.roles.checked);
    // The strong colour (send, primary buttons) stays the palette's.
    assert_eq!(mono.roles.primary, system.roles.primary);
    assert_eq!(mono.roles.text, system.roles.text);
    assert_eq!(mono.roles.content, system.roles.content);
}

#[test]
fn sidebar_style_controls_the_sidebar_fill() {
    let material = ConduitTheme::new("conduit", true, DesignPrefs::default(), accent());
    assert_eq!(material.roles.sidebar.a, 0.);
    let surface = ConduitTheme::new(
        "conduit",
        true,
        DesignPrefs {
            sidebar: SidebarStyle::Surface,
            ..Default::default()
        },
        accent(),
    );
    assert_eq!(surface.roles.sidebar, surface.colors.sidebar_background);
}

#[test]
fn density_sets_row_and_body_sizes() {
    let compact = Metrics::for_density(Density::Compact);
    assert_eq!((compact.row_height, compact.body), (28., 14.));
    let comfortable = Metrics::for_density(Density::Comfortable);
    assert_eq!((comfortable.row_height, comfortable.body), (32., 15.));
}

#[test]
fn dark_raised_content_is_a_real_step_up_from_the_black_column() {
    let dark = ConduitTheme::new("conduit", true, DesignPrefs::default(), accent());
    let level = |c: Hsla| {
        let c: gpui_kit::Rgba = c.into();
        (
            (c.r * 255.).round(),
            (c.g * 255.).round(),
            (c.b * 255.).round(),
        )
    };
    // The column stays #000; code, tables, cards and the composer sit on
    // #181818 (inside #161616–#1C1C1C), a table head or chip on #232323.
    assert_eq!(level(dark.surfaces.panel), (0., 0., 0.));
    assert_eq!(
        level(composite(dark.roles.raised, dark.surfaces.panel)),
        (24., 24., 24.)
    );
    assert_eq!(level(dark.roles.raised_hover), (35., 35., 35.));
    assert_eq!(crate::views::kit::raised_fill(&dark), dark.roles.raised);
    // Light keeps the palette's own wash over white.
    let light = ConduitTheme::new("conduit", false, DesignPrefs::default(), accent());
    assert_eq!(light.roles.raised, light.surfaces.surface);
    assert_eq!(crate::views::kit::raised_fill(&light), light.surfaces.panel);
}

fn level(c: Hsla) -> (f32, f32, f32) {
    let c: gpui_kit::Rgba = c.into();
    (
        (c.r * 255.).round(),
        (c.g * 255.).round(),
        (c.b * 255.).round(),
    )
}

#[test]
fn dark_surfaces_are_one_neutral_ramp_around_the_black_column() {
    let t = ConduitTheme::new("conduit", true, DesignPrefs::default(), accent());
    let step = |n| level(dark_step(t.surfaces.panel, t.roles.text, n));
    assert_eq!(
        [step(0), step(1), step(2), step(3)],
        [
            (0., 0., 0.),
            (24., 24., 24.),
            (35., 35., 35.),
            (47., 47., 47.)
        ]
    );
    let r = &t.roles;
    let kit = crate::views::kit::grouped_tones(&t);
    // Every surface is one of the four steps: the column, Settings' and
    // the setup window's page and every window's backdrop on 0; what is
    // raised (the composer, cards, Settings' groups, menus) on 1; a field
    // or button on it on 2; tooltips and hovered fields on 3.
    for (name, c, n) in [
        ("content", r.content, 0),
        ("window", r.window, 0),
        ("grouped page", kit.0, 0),
        ("raised", r.raised, 1),
        ("grouped card", kit.1, 1),
        ("overlay", r.overlay, 1),
        ("raised fill", crate::views::kit::raised_fill(&t), 1),
        ("raised hover", r.raised_hover, 2),
        ("field", crate::views::kit::field_fill(&t), 2),
        ("on raised", crate::views::kit::on_raised_fill(&t), 2),
        ("overlay hover", r.overlay_hover, 3),
        ("field hover", crate::views::kit::field_fill_hover(&t), 3),
    ] {
        assert_eq!(level(c), step(n), "{name}");
    }
    // Neutral: no blue cast anywhere on the ramp.
    for n in 0..4 {
        let (red, green, blue) = step(n);
        assert!(red == green && green == blue, "step {n}");
    }
    // Light mode is untouched by it.
    let light = ConduitTheme::new("conduit", false, DesignPrefs::default(), accent());
    assert_eq!(light.roles.window, light.surfaces.window);
    assert_eq!(light.roles.overlay, light.surfaces.menu);
}

#[test]
fn off_controls_keep_a_three_to_one_edge_in_dark() {
    for p in &palettes().palettes {
        let t = ConduitTheme::new(&p.id, true, DesignPrefs::default(), accent());
        let s = &t.surfaces;
        let r = &t.roles;
        for (layer, bg) in [
            ("column", s.panel),
            ("raised card", composite(r.raised, s.panel)),
            ("field", composite(r.raised_hover, s.panel)),
        ] {
            let ratio = contrast_ratio(r.control_edge, bg);
            assert!(
                ratio + 1e-3 >= 3.0,
                "{} radio edge on {layer}: {ratio:.2}",
                p.id
            );
        }
    }
    // Conduit's dark radio ring is a mid grey now, not #3D3D3D (1.5:1).
    let t = ConduitTheme::new("conduit", true, DesignPrefs::default(), accent());
    assert!(level(t.roles.control_edge).0 >= 100.);
}

#[test]
fn settings_text_reads_on_its_dark_groups_and_fields() {
    for p in &palettes().palettes {
        let t = ConduitTheme::new(&p.id, true, DesignPrefs::default(), accent());
        let (page, card) = crate::views::kit::grouped_tones(&t);
        let field = composite(crate::views::kit::field_fill(&t), card);
        let r = &t.roles;
        for (layer, bg) in [("page", page), ("group", card), ("field", field)] {
            for (what, fg, min) in [
                ("text", r.text, 4.5),
                ("secondary", r.text_subtle, 4.5),
                ("placeholder", r.text_faint, 3.0),
            ] {
                let ratio = contrast_ratio(fg, bg);
                assert!(
                    ratio + 1e-3 >= min,
                    "{} {what} on {layer}: {ratio:.2}",
                    p.id
                );
            }
        }
    }
}

/// A user's message reads as a bubble on the transcript in every palette,
/// light and dark, including one whose cards are the page's own colour.
#[test]
fn a_user_bubble_stands_apart_from_the_transcript() {
    let mut flat = vec![];
    for p in &palettes().palettes {
        for dark in [false, true] {
            let t = ConduitTheme::new(&p.id, dark, DesignPrefs::default(), accent());
            let ratio = contrast_ratio(t.roles.bubble, t.roles.content);
            if ratio < 1.05 {
                flat.push(format!(
                    "{} {}: {} on {} is {ratio:.3}:1",
                    p.id,
                    if dark { "dark" } else { "light" },
                    palette::to_hex(t.roles.bubble),
                    palette::to_hex(t.roles.content),
                ));
            }
        }
    }
    assert!(flat.is_empty(), "{flat:#?}");
}

#[test]
fn an_off_switch_track_stands_apart_from_its_knob() {
    let light = ConduitTheme::new("conduit", false, DesignPrefs::default(), accent());
    let card = crate::views::kit::grouped_tones(&light).1;
    let track = composite(crate::views::kit::switch_track(false, &light), card);
    // About System Settings' off track (#D1D1D1), not the old #E0E0E0.
    let (red, _, _) = level(track);
    assert!((205. ..=213.).contains(&red), "{:?}", level(track));
}
