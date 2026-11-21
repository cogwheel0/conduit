//! Conduit Desktop design gallery.
//!
//! Renders named screens on synthetic data, in-process, to PNG:
//!
//! ```text
//! conduit-gallery --screen main-empty --mode dark --palette conduit \
//!     --variant sidebar=surface --out shot.png
//! conduit-gallery --all /tmp/conduit-gallery
//! conduit-gallery --a11y main-streaming        # AccessKit check, JSON report
//! conduit-gallery --list
//! ```
//!
//! `--all` renders every screen in light and dark on Conduit and Catppuccin
//! with the baseline prefs, then varies one design key at a time on the
//! screens that can show it (`Screen::variant_keys`: empty chat, streaming
//! answer, long chat, sidebar), and writes `index.json`.

//!
//! It renders and captures through AppKit, so it runs only on macOS.

#[cfg(target_os = "macos")]
mod a11y;
#[cfg(target_os = "macos")]
mod fake;
#[cfg(target_os = "macos")]
mod gallery;
#[cfg(target_os = "macos")]
mod screens;
#[cfg(target_os = "macos")]
mod views;

fn main() {
    #[cfg(target_os = "macos")]
    gallery::main();
    #[cfg(not(target_os = "macos"))]
    {
        eprintln!("conduit-gallery renders through AppKit and runs only on macOS");
        std::process::exit(69);
    }
}
