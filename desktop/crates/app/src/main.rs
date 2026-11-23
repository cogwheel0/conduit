//! The `conduit-desktop` binary: see the `conduit_desktop` library.

// A Windows release build is a GUI program: a link opened from a browser, or
// a double-click, starts no console window with it. Debug and harness builds
// keep their console, where the run scripts and the passes read the output.
#![cfg_attr(
    all(windows, not(debug_assertions), not(feature = "harness")),
    windows_subsystem = "windows"
)]

fn main() {
    conduit_desktop::run();
}
