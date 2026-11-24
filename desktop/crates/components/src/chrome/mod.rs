//! The main window's chrome off the Mac (decision D13): one implementation,
//! styled per OS.
//!
//! * [`ChromeStyle::Windows`]: one ☰ menu, the toolbars as the title bar,
//!   and the caption buttons at the top right.
//! * [`ChromeStyle::Gnome`]: GNOME-style header bars with a ☰ primary menu
//!   and the window controls where the desktop's `button-layout` puts them.
//!
//! The Mac draws none of it: AppKit's traffic lights and menu bar stay.
//!
//! It follows the Mac's traffic lights: the window's own controls (the
//! caption buttons or window controls, and Windows' ☰) sit at fixed spots
//! at the window's edges, over whichever header is there, and the headers
//! leave them room ([`layout::Rooms`]) as they leave the traffic lights
//! theirs. The main window describes its chrome each frame ([`Chrome`]),
//! before its content draws, and the shared views read it.

pub mod activation;
pub mod controls;
pub mod keys;
pub mod layout;
pub mod main_menu;
pub mod menu;

use gpui_kit::prelude::*;
use gpui_kit::{AnyElement, App, Decorations, Entity, Global, div, px};

use crate::window::TOOLBAR_HEIGHT;

pub use activation::activate;
pub use controls::{ClientFrame, ControlLabels, OnClose, WindowControls, header_drag};
pub use layout::{ButtonLayout, Corners, Edge, Header, Placement, Rooms, Slot, WindowButton};
pub use main_menu::{MainMenu, MainMenuButton, MenuItems};
pub use menu::ChromeMenuItem;

/// How the chrome looks and behaves.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum ChromeStyle {
    Windows,
    Gnome,
}

impl ChromeStyle {
    /// The style this build draws: none on the Mac.
    pub const fn native() -> Option<Self> {
        if cfg!(target_os = "windows") {
            Some(Self::Windows)
        } else if cfg!(target_os = "macos") {
            None
        } else {
            Some(Self::Gnome)
        }
    }
}

/// The main window's chrome this frame.
#[derive(Clone)]
pub struct Chrome {
    pub style: ChromeStyle,
    /// The window controls, as the desktop lays them out.
    pub buttons: ButtonLayout,
    /// Whether the app draws the frame (client-side decorations) or the
    /// window manager does (no window controls of ours then).
    pub decorations: Decorations,
    pub maximized: bool,
    pub menu: Entity<MainMenu>,
    pub labels: ControlLabels,
    /// The app's name, over the sidebar's header bar (GNOME).
    pub title: gpui_kit::SharedString,
    pub on_close: Option<OnClose>,
}

impl Chrome {
    /// Whether the app draws the window controls.
    pub fn decorated(&self) -> bool {
        self.style == ChromeStyle::Windows || matches!(self.decorations, Decorations::Client { .. })
    }

    pub fn placement(&self, sidebar_shown: bool) -> Placement {
        Placement::of(self.style, sidebar_shown)
    }

    pub fn rooms(&self, sidebar_shown: bool) -> Rooms {
        Rooms::of(self.style, &self.buttons, sidebar_shown, self.decorated())
    }

    pub fn corners(&self) -> Corners {
        Corners::of(self.style, self.decorations, self.maximized)
    }

    /// The controls at one end, as drawn (none under a window manager's
    /// frame).
    pub fn controls(&self, edge: Edge) -> Option<WindowControls> {
        let buttons = match edge {
            Edge::Start => &self.buttons.start,
            Edge::End => &self.buttons.end,
        };
        (self.decorated() && !buttons.is_empty()).then(|| {
            WindowControls::new(
                self.style,
                buttons.clone(),
                self.maximized,
                self.labels.clone(),
            )
            .on_close(self.on_close.clone())
        })
    }
}

/// The window's own controls at its top corners, over whichever header is
/// there (as the traffic lights sit): Windows' ☰ and caption buttons;
/// GNOME's window controls, and ☰ at the end while no sidebar shows.
pub fn corner_controls(c: &Chrome, sidebar_shown: bool) -> AnyElement {
    let placement = c.placement(sidebar_shown);
    let edge = layout::CHROME_EDGE;
    let start = div()
        .absolute()
        .top_0()
        .left_0()
        .h(px(TOOLBAR_HEIGHT))
        .pl(px(edge))
        .flex()
        .items_center()
        .children(c.controls(Edge::Start))
        .when(c.style == ChromeStyle::Windows, |d| {
            d.child(main_menu::MainMenuButton::new(c.menu.clone()))
        });
    let end = div()
        .absolute()
        .top_0()
        .right_0()
        .h(px(TOOLBAR_HEIGHT))
        .flex()
        .items_center()
        .when(c.style == ChromeStyle::Gnome, |d| {
            d.pr(px(edge)).gap(px(4.))
        })
        .when(
            c.style == ChromeStyle::Gnome
                && placement.main_menu == Slot(Header::Content, Edge::End),
            |d| d.child(main_menu::MainMenuButton::new(c.menu.clone())),
        )
        .children(c.controls(Edge::End));
    div()
        .absolute()
        .top_0()
        .left_0()
        .right_0()
        .h(px(TOOLBAR_HEIGHT))
        .child(start)
        .child(end)
        .into_any_element()
}

/// The main window's [`Chrome`], set before its content draws; none on the
/// Mac.
#[derive(Clone, Default)]
pub struct ActiveChrome(pub Option<Chrome>);

impl Global for ActiveChrome {}

/// The main window's chrome, if it draws one.
pub fn active(cx: &App) -> Option<&Chrome> {
    cx.try_global::<ActiveChrome>().and_then(|c| c.0.as_ref())
}

/// The style the main window's chrome draws in, if any.
pub fn style(cx: &App) -> Option<ChromeStyle> {
    active(cx).map(|c| c.style)
}

#[cfg(test)]
mod tests;
