//! The chat's window sheets: Branches and Share Chat, each a window of its
//! own hung from the main window's title bar by AppKit's `beginSheet:`, as
//! Add Account and the release notes are. Esc, ⌘. and ⌘W close it, and Done
//! does. They are registered with [`crate::views::sheet`], the host of the
//! settings sheets, so one sheet shows at a time whichever kind it is, and
//! quitting ends it first.

use conduit_components::theme::{ConduitTheme, UI_FONT};
use conduit_components::views::kit::grouped_tones;
use gpui_kit::prelude::*;
use gpui_kit::{
    AnyElement, AnyWindowHandle, App, Bounds, Context, Entity, FontWeight, Global, Render, Role,
    SharedString, WindowBackgroundAppearance, WindowBounds, WindowKind, WindowOptions, div, point,
    px, relative, size,
};

/// The chat sheet opened last; it is the one showing while the sheet host
/// still has it down.
#[derive(Default)]
struct ChatSheet(Option<AnyWindowHandle>);

impl Global for ChatSheet {}

/// A sheet's window: opened hidden and fixed, `width` by `height`;
/// `beginSheet:` shows it.
fn options(width: f32, height: f32) -> WindowOptions {
    WindowOptions {
        window_bounds: Some(WindowBounds::Windowed(Bounds::new(
            point(px(0.), px(0.)),
            size(px(width), px(height)),
        ))),
        titlebar: Some(gpui_kit::TitlebarOptions {
            title: None,
            appears_transparent: true,
            traffic_light_position: None,
        }),
        focus: false,
        show: false,
        kind: WindowKind::Normal,
        is_movable: false,
        is_resizable: false,
        is_minimizable: false,
        window_background: WindowBackgroundAppearance::Opaque,
        window_min_size: None,
        ..Default::default()
    }
}

/// The chat sheet's window, while one shows.
pub fn handle(cx: &App) -> Option<AnyWindowHandle> {
    let mine = cx.try_global::<ChatSheet>().and_then(|s| s.0)?;
    (crate::views::sheet::current_window(cx) == Some(mine)).then_some(mine)
}

/// Whether a chat sheet is showing.
pub fn is_open(cx: &App) -> bool {
    handle(cx).is_some()
}

/// Opens `build`'s view as a sheet on `parent`, `width` by `height`
/// points; none when another chat sheet is showing.
pub fn open<V: Render + 'static>(
    parent: &gpui_kit::Window,
    width: f32,
    height: f32,
    cx: &mut App,
    build: impl FnOnce(&mut gpui_kit::Window, &mut Context<V>) -> V + 'static,
) -> Option<Entity<V>> {
    if crate::views::sheet::refuse_another(cx) {
        return None;
    }
    let opened = conduit_components::window::open_window_clear_root(
        options(width, height),
        cx,
        move |window, cx| cx.new(|cx| build(window, cx)),
    );
    let (handle, view) = match opened {
        Ok(v) => v,
        Err(e) => {
            log::error!("could not open the sheet: {e}");
            return None;
        }
    };
    cx.set_global(ChatSheet(Some(handle)));
    crate::views::sheet::adopt(handle, view.clone().into_any(), cx);
    crate::views::sheet::begin(parent, handle, cx);
    Some(view)
}

/// Closes the chat sheet showing, if one is.
pub fn close(cx: &mut App) {
    if is_open(cx) {
        cx.set_global(ChatSheet(None));
        crate::views::sheet::dismiss(cx);
    }
}

/// A sheet's frame: its title and what it is for, the body, then the
/// buttons at the bottom right. `on_close` runs for Esc, ⌘. and ⌘W.
pub fn frame(
    id: &'static str,
    title: String,
    description: Option<String>,
    body: AnyElement,
    buttons: Vec<AnyElement>,
    on_close: impl Fn(&mut App) + 'static,
    t: &ConduitTheme,
) -> gpui_kit::Stateful<gpui_kit::Div> {
    let (page, _) = grouped_tones(t);
    let (r, m) = (t.roles, t.metrics);
    let on_close = std::rc::Rc::new(on_close);
    let close_action = on_close.clone();
    div()
        .id(id)
        .role(Role::Dialog)
        .aria_label(SharedString::from(title.clone()))
        .key_context("ConduitSheet")
        .size_full()
        .font_family(UI_FONT)
        .bg(page)
        .text_color(r.text)
        .flex()
        .flex_col()
        .on_key_down(move |e: &gpui_kit::KeyDownEvent, _, cx| {
            let k = &e.keystroke;
            let mods = &k.modifiers;
            let esc =
                k.key == "escape" && !(mods.platform || mods.alt || mods.control || mods.shift);
            let cmd_period = k.key == "." && mods.platform && !(mods.alt || mods.control);
            if esc || cmd_period {
                on_close(cx);
                cx.stop_propagation();
            }
        })
        .on_action(move |_: &crate::actions::CloseWindow, _, cx| close_action(cx))
        .child(
            div()
                .px(px(20.))
                .pt(px(20.))
                .pb(px(10.))
                .flex()
                .flex_col()
                .gap(px(4.))
                .child(
                    div()
                        .id("sheet-title")
                        .role(Role::Heading)
                        .text_size(px(m.body + 2.))
                        .font_weight(FontWeight::SEMIBOLD)
                        .child(SharedString::from(title)),
                )
                .when_some(description, |d, text| {
                    d.child(
                        div()
                            .text_size(px(m.small))
                            .line_height(relative(1.35))
                            .text_color(r.text_subtle)
                            .child(SharedString::from(text)),
                    )
                }),
        )
        .child(div().flex_1().min_h_0().px(px(20.)).child(body))
        .child(
            div()
                .px(px(20.))
                .py(px(16.))
                .flex()
                .justify_end()
                .gap(px(8.))
                .children(buttons),
        )
}
