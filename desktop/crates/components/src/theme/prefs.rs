//! The app's design choices, as switchable preferences.
//!
//! Each enum is one checkpoint the user decides; the gallery renders them as
//! `--variant key=value`. Once a value is locked the losing branch can go,
//! but until then every view reads its choice from [`DesignPrefs`].

use std::fmt;

/// Sidebar backdrop: `sidebar=material|surface`.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
pub enum SidebarStyle {
    /// An NSVisualEffectView (Sidebar material) behind a transparent sidebar.
    #[default]
    Material,
    /// The palette's opaque `sidebarBackground`.
    Surface,
}

/// What colours selection and focus: `accent=mono|system`.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
pub enum AccentPolicy {
    /// The palette only: monochrome on Conduit's own palette.
    #[default]
    Mono,
    /// The macOS accent colour, for selection and focus only.
    System,
}

/// How user messages look: `user=bubble|plain`.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
pub enum UserMessageStyle {
    /// Right-aligned bubbles, as on the phone.
    #[default]
    Bubble,
    /// Left-aligned like the reply, under a small "You" label.
    Plain,
}

/// Row height and body size: `density=compact|comfortable`.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
pub enum Density {
    /// 28 px rows, 14 px body (today's density).
    #[default]
    Compact,
    /// 32 px rows, 15 px body.
    Comfortable,
}

/// Toolbar contents: `toolbar=pill|model|title`.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
pub enum ToolbarLayout {
    /// The phone's header: a centred capsule with the chat's title over the
    /// model, which opens the model picker.
    #[default]
    Pill,
    /// The model picker leads the toolbar; the chat title follows, muted.
    Model,
    /// The chat title in the toolbar; the model picker in the composer footer.
    Title,
}

/// One choice per open design question. `Default` is the baseline:
/// material, mono, bubble, compact, pill.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
pub struct DesignPrefs {
    pub sidebar: SidebarStyle,
    pub accent: AccentPolicy,
    pub user_message: UserMessageStyle,
    pub density: Density,
    pub toolbar: ToolbarLayout,
}

/// The variant keys, in the order the gallery lists them.
pub const VARIANT_KEYS: &[&str] = &["sidebar", "accent", "user", "density", "toolbar"];

impl DesignPrefs {
    /// Applies one `key=value` pair.
    pub fn set(&mut self, key: &str, value: &str) -> Result<(), String> {
        let bad = || format!("unknown value {value:?} for {key}");
        match key {
            "sidebar" => {
                self.sidebar = match value {
                    "material" => SidebarStyle::Material,
                    "surface" => SidebarStyle::Surface,
                    _ => return Err(bad()),
                }
            }
            "accent" => {
                self.accent = match value {
                    "mono" => AccentPolicy::Mono,
                    "system" => AccentPolicy::System,
                    _ => return Err(bad()),
                }
            }
            "user" => {
                self.user_message = match value {
                    "bubble" => UserMessageStyle::Bubble,
                    "plain" => UserMessageStyle::Plain,
                    _ => return Err(bad()),
                }
            }
            "density" => {
                self.density = match value {
                    "compact" => Density::Compact,
                    "comfortable" => Density::Comfortable,
                    _ => return Err(bad()),
                }
            }
            "toolbar" => {
                self.toolbar = match value {
                    "pill" => ToolbarLayout::Pill,
                    "model" => ToolbarLayout::Model,
                    "title" => ToolbarLayout::Title,
                    _ => return Err(bad()),
                }
            }
            _ => return Err(format!("unknown variant key {key:?}")),
        }
        Ok(())
    }

    /// Parses `key=value,key=value`. An empty string is the baseline.
    pub fn parse(spec: &str) -> Result<Self, String> {
        let mut prefs = Self::default();
        for pair in spec.split(',').map(str::trim).filter(|p| !p.is_empty()) {
            let (key, value) = pair
                .split_once('=')
                .ok_or_else(|| format!("expected key=value, got {pair:?}"))?;
            prefs.set(key.trim(), value.trim())?;
        }
        Ok(prefs)
    }

    /// The value of one key, as the gallery spells it.
    pub fn get(&self, key: &str) -> Option<&'static str> {
        Some(match key {
            "sidebar" => match self.sidebar {
                SidebarStyle::Material => "material",
                SidebarStyle::Surface => "surface",
            },
            "accent" => match self.accent {
                AccentPolicy::Mono => "mono",
                AccentPolicy::System => "system",
            },
            "user" => match self.user_message {
                UserMessageStyle::Bubble => "bubble",
                UserMessageStyle::Plain => "plain",
            },
            "density" => match self.density {
                Density::Compact => "compact",
                Density::Comfortable => "comfortable",
            },
            "toolbar" => match self.toolbar {
                ToolbarLayout::Pill => "pill",
                ToolbarLayout::Model => "model",
                ToolbarLayout::Title => "title",
            },
            _ => return None,
        })
    }

    /// The other value of a two-way key (what the gallery varies).
    pub fn alternate(key: &str) -> Option<&'static str> {
        let baseline = Self::default();
        Some(match (key, baseline.get(key)?) {
            ("sidebar", _) => "surface",
            ("accent", _) => "system",
            ("user", _) => "plain",
            ("density", _) => "comfortable",
            ("toolbar", _) => "model",
            _ => return None,
        })
    }

    /// Keys whose value differs from the baseline.
    pub fn changed_keys(&self) -> Vec<&'static str> {
        let base = Self::default();
        VARIANT_KEYS
            .iter()
            .copied()
            .filter(|k| self.get(k) != base.get(k))
            .collect()
    }
}

impl fmt::Display for DesignPrefs {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let parts: Vec<String> = VARIANT_KEYS
            .iter()
            .map(|k| format!("{k}={}", self.get(k).unwrap_or("?")))
            .collect();
        f.write_str(&parts.join(","))
    }
}

/// Sizes that follow [`Density`].
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Metrics {
    /// Sidebar, list, menu and palette rows.
    pub row_height: f32,
    /// Message and composer text.
    pub body: f32,
    /// Sidebar row titles, buttons, form labels (macOS controls are 13 pt).
    pub control: f32,
    /// Secondary lines: timestamps, captions, hints.
    pub small: f32,
    /// Section headers.
    pub caption: f32,
    /// Code blocks.
    pub code: f32,
    /// Standard control height (buttons, text fields).
    pub control_height: f32,
    /// Width of the main window's sidebar.
    pub sidebar_width: f32,
    /// Message line height, as a multiple of `body`.
    pub leading: f32,
}

impl Metrics {
    pub fn for_density(density: Density) -> Self {
        match density {
            Density::Compact => Self {
                row_height: 28.,
                body: 14.,
                control: 13.,
                small: 12.,
                caption: 11.,
                code: 12.5,
                control_height: 28.,
                sidebar_width: 260.,
                leading: 1.6,
            },
            Density::Comfortable => Self {
                row_height: 32.,
                body: 15.,
                control: 14.,
                small: 13.,
                caption: 12.,
                code: 13.,
                control_height: 32.,
                sidebar_width: 276.,
                leading: 1.65,
            },
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn baseline_round_trips() {
        let base = DesignPrefs::default();
        assert_eq!(
            base.to_string(),
            "sidebar=material,accent=mono,user=bubble,density=compact,toolbar=pill"
        );
        assert_eq!(DesignPrefs::parse(&base.to_string()).unwrap(), base);
        assert!(base.changed_keys().is_empty());
    }

    #[test]
    fn each_alternate_changes_exactly_one_key() {
        for key in VARIANT_KEYS {
            let alt = DesignPrefs::alternate(key).unwrap();
            let prefs = DesignPrefs::parse(&format!("{key}={alt}")).unwrap();
            assert_eq!(prefs.changed_keys(), vec![*key]);
        }
    }

    #[test]
    fn rejects_unknown_keys_and_values() {
        assert!(DesignPrefs::parse("sidebar=glass").is_err());
        assert!(DesignPrefs::parse("colour=red").is_err());
        assert!(DesignPrefs::parse("sidebar").is_err());
    }
}
