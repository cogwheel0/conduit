//! Conduit Desktop's shared UI layer on GPUI Kit.
//!
//! * [`theme`]: conduit_theme palettes (embedded JSON) mapped onto GPUI Kit's
//!   `Theme`, SF Pro typography and density metrics, and the design
//!   choices the gallery switches between ([`theme::DesignPrefs`]).
//! * [`window`]: transparent roots, inline traffic lights, sidebar material,
//!   the Quick Ask panel.
//! * [`views`]: the reusable views. They take plain view-model structs, never
//!   protocol DTOs or fake data, so the app and the design gallery
//!   share them.
//!
//! Accessibility: every interactive element gets an AccessKit role and label,
//! and each message is a labelled `Role::Article` (a bare TextView is
//! invisible to VoiceOver). Changes the user isn't looking at
//! are spoken through [`announce`].

pub mod announce;
pub mod assets;
#[cfg(target_os = "macos")]
pub mod capture;
pub mod motion;
pub mod strings;
pub mod theme;
pub mod views;
pub mod window;

pub use strings::{ActiveStrings, Strings};
pub use theme::{ActiveConduitTheme, ConduitTheme};
