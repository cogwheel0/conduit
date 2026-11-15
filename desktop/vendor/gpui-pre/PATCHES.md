# gpui-pre 0.3.11, patched

A copy of `gpui-pre` 0.3.11 from crates.io (Apache-2.0, see LICENSE-APACHE),
used through `[patch.crates-io]` in `desktop/Cargo.toml`. Only `src/`,
`build.rs`, `resources/`, the README and the licence are kept; the manifest
drops the `[[example]]` targets and dev-dependencies, whose files are not
copied. It is excluded from the workspace, so fmt, clippy and tests skip it.

## Changes

1. `src/window.rs`, `Window::dispatch_event`: `PlatformInput::FileDrop(_)`
   switches the input modality to `Mouse`, like `MouseMove` and `MouseDown`.

   Without it, a file dragged onto the window right after typing (the
   composer case) leaves the window in keyboard modality.
   `Hitbox::is_hovered` is false in keyboard modality, so the drop target's
   drag-over and `on_drop` handlers never run and the file is silently
   ignored.

2. `src/window/a11y/debug.rs`, `node_to_json`: each node's `bounds`
   (device pixels, window-relative) in `Window::debug_a11y_tree_json`.

   The dump is debug output only; the desktop app's capture harness
   (`--capture`) finds controls by role and label in it and needs to know
   where they are on screen to hover, press and drag them.

3. `src/window.rs`, `Window::set_focus_reveal_inset` and
   `Window::reveal_focused`, called from `Interactivity::prepaint`
   (`src/elements/div.rs`) for a focused element: once per focus change
   (`focus_generation`), the element taking keyboard focus requests an
   autoscroll of its bounds grown by the inset, so the `List` it is in
   scrolls it into view (AppKit's `scrollRectToVisible:` for the key view).
   Only when the last input was the keyboard: a click's focus never
   scrolls, or the control moved from under the pointer between press and
   release and the click was lost. Off unless a window sets an inset.

   Without it, Tab and Shift-Tab into an earlier answer's buttons left the
   focused control and its ring off screen: the app could only scroll the
   whole row into view, not the control.

   In `src/elements/list.rs`, `ListState::prepaint_items` and `List::prepaint`:
   an autoscroll the list accepts pauses tail-following
   (`FollowMode::Tail`), which resumes once the list is back at the bottom;
   before, the retry put the anchor back at the end and the focused control
   stayed off screen while an answer streamed. A focused item outside the
   visible range, which the list draws after the visible items at a stand-in
   position, is revealed from the top when its index is above the viewport,
   so Shift-Tab into the row above scrolls by that row, not a whole page.
   `conduit-components`' `focus_reveal` tests cover both.

To update: copy the new release's `src/`, `build.rs`, `resources/`,
README and licence over this one, re-apply the changes above, and keep the
manifest edits. Drop a patch once upstream carries it.
