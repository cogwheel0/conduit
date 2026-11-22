//! The app's own prompts on Windows and Linux, drawn in the window for the
//! questions [`crate::shell::sheet`] asks through GPUI's `window.prompt`
//! (the Mac attaches an NSAlert sheet instead).
//!
//! GPUI's own fallback is mouse-only, and Windows' task dialog cannot be
//! taken down. Here the confirm button has the keyboard when the prompt
//! opens; Tab, Shift-Tab and the arrow keys move between the buttons and
//! never leave the prompt; Return and Space answer the button with focus;
//! Esc answers Cancel (a notice's only button). Screen readers get an alert
//! dialog named by the title, described by the message, with labelled
//! buttons. [`AppPrompt::dismiss`] takes a prompt down unanswered, as an
//! account change does to a question that no longer applies.

use gpui_kit::prelude::*;
use gpui_kit::{
    AnyView, AnyWindowHandle, App, Context, Entity, EventEmitter, FocusHandle, Focusable,
    FontWeight, Global, KeyBinding, PromptButton, PromptHandle, PromptLevel, PromptResponse,
    RenderablePromptHandle, Role, ScrollHandle, SharedString, WeakEntity, Window, actions, div, px,
};

use conduit_components::ActiveConduitTheme as _;
use conduit_components::theme::with_alpha;
use conduit_components::views::focus::{Ring, ring_overlay};
use conduit_components::views::kit::{field_fill, overlay_shadow};

use crate::keymap::KeyOs;

actions!(
    app_prompt,
    [
        /// Answers the button with focus (the first, from an accessory).
        Confirm,
        /// Answers the button with focus, if one has it.
        Press,
        /// Answers Cancel, or a notice's only button.
        Cancel,
        NextButton,
        PreviousButton,
        /// Scroll a long message (the buttons keep Tab and Return).
        LineDown,
        LineUp,
        PageDown,
        PageUp
    ]
);

/// The key context of a prompt the app draws.
pub const CONTEXT: &str = "ConduitPrompt";

/// The prompt's keys, in its own context. Bound after the app's, since the
/// app's Esc (Stop Generating, with no context) ranks as deep as the focus
/// and the later of two equal bindings wins.
pub fn bindings() -> Vec<KeyBinding> {
    let c = Some(CONTEXT);
    vec![
        KeyBinding::new("enter", Confirm, c),
        KeyBinding::new("space", Press, c),
        KeyBinding::new("escape", Cancel, c),
        KeyBinding::new("tab", NextButton, c),
        KeyBinding::new("right", NextButton, c),
        KeyBinding::new("shift-tab", PreviousButton, c),
        KeyBinding::new("left", PreviousButton, c),
        KeyBinding::new("down", LineDown, c),
        KeyBinding::new("up", LineUp, c),
        KeyBinding::new("pagedown", PageDown, c),
        KeyBinding::new("pageup", PageUp, c),
    ]
}

/// While a prompt is up, the app's own chords act on nothing behind it
/// (Ctrl+Shift+Enter would allow a waiting tool request, Ctrl+N start a
/// chat): each of `chords` but the prompt's own keys is bound to nothing in
/// its context. Bound after the app's, which rank as deep as the focus.
pub fn guard_bindings(chords: &[crate::keymap::KeyStroke], os: KeyOs, cx: &App) -> Vec<KeyBinding> {
    // The prompt's own keys, and its accessory's (the date picker), keep
    // their meaning in there.
    let own: Vec<String> = bindings()
        .iter()
        .chain(crate::shell::date_picker::bindings().iter())
        .map(|b| {
            b.keystrokes()[0]
                .inner()
                .unparse(gpui_kit::OperatingSystem::Linux)
        })
        .collect();
    // In each context focus can be in while a prompt is up: a binding with
    // no context ranks as deep as the focus, so a guard in the prompt's
    // context alone is outranked inside the picker's.
    let contexts = [CONTEXT, crate::shell::date_picker::PICKER_CONTEXT];
    let chords: Vec<String> = chords
        .iter()
        .map(|s| crate::keymap::to_gpui_on(s, os))
        .filter(|chord| !own.contains(chord))
        .collect();
    contexts
        .iter()
        .flat_map(|context| {
            chords.iter().filter_map(move |chord| {
                KeyBinding::load(
                    chord,
                    Box::new(gpui_kit::NoAction),
                    Some(std::rc::Rc::new(
                        gpui_kit::KeyBindingContextPredicate::parse(context).ok()?,
                    )),
                    false,
                    None,
                    cx,
                )
                .ok()
            })
        })
        .collect()
}

/// Draws every `window.prompt` with [`AppPrompt`] from now on.
pub fn install(cx: &mut App) {
    cx.set_prompt_builder(build);
    cx.set_global(Installed);
}

/// [`install`] ran: questions with an accessory (the date picker) can be
/// asked in the window.
pub fn installed(cx: &App) -> bool {
    cx.has_global::<Installed>()
}

struct Installed;

impl Global for Installed {}

/// What a prompt shows between its message and its buttons (the date
/// picker), with the stops Tab reaches in it, first to last.
pub struct Accessory {
    pub view: AnyView,
    pub stops: Vec<FocusHandle>,
}

/// The accessory the next prompt built shows.
#[derive(Default)]
struct NextAccessory(Option<Accessory>);

impl Global for NextAccessory {}

/// Shows `accessory` in the next `window.prompt` (it is built at once,
/// inside that call). The accessory has the keyboard as the prompt opens.
pub fn show_next_with(accessory: Accessory, cx: &mut App) {
    cx.set_global(NextAccessory(Some(accessory)));
}

/// The prompts the app has drawn, by window, while they are up.
#[derive(Default)]
struct Shown(Vec<(AnyWindowHandle, WeakEntity<AppPrompt>)>);

impl Global for Shown {}

fn build(
    level: PromptLevel,
    title: &str,
    detail: Option<&str>,
    buttons: &[PromptButton],
    handle: PromptHandle,
    window: &mut Window,
    cx: &mut App,
) -> RenderablePromptHandle {
    let accessory = cx
        .has_global::<NextAccessory>()
        .then(|| cx.global_mut::<NextAccessory>().0.take())
        .flatten();
    let view = cx.new(|cx| {
        let mut prompt = AppPrompt::new(level, title, detail, buttons, KeyOs::CURRENT, cx);
        prompt.accessory = accessory;
        prompt
    });
    let shown = cx.default_global::<Shown>();
    shown.0.retain(|(_, p)| p.upgrade().is_some());
    shown.0.push((window.window_handle(), view.downgrade()));
    handle.with_view(view, window, cx)
}

/// The prompt the app last drew on `window`, while it is up.
pub fn shown_on(window: AnyWindowHandle, cx: &App) -> Option<Entity<AppPrompt>> {
    cx.try_global::<Shown>()?
        .0
        .iter()
        .rev()
        .find(|(w, _)| *w == window)
        .and_then(|(_, p)| p.upgrade())
}

/// A question drawn in the window: a title, a message and its buttons.
pub struct AppPrompt {
    level: PromptLevel,
    title: SharedString,
    detail: Option<SharedString>,
    buttons: Vec<PromptButton>,
    /// Each button's, in `buttons`' order.
    focus: Vec<FocusHandle>,
    /// The prompt's own, for one with no buttons.
    container: FocusHandle,
    /// The order the buttons stand in: GNOME puts the confirming button
    /// last, Windows first.
    os: KeyOs,
    accessory: Option<Accessory>,
    /// The message's scroll, when it is taller than the window allows.
    message_scroll: ScrollHandle,
    answered: bool,
}

impl AppPrompt {
    fn new(
        level: PromptLevel,
        title: &str,
        detail: Option<&str>,
        buttons: &[PromptButton],
        os: KeyOs,
        cx: &mut Context<Self>,
    ) -> Self {
        Self {
            level,
            title: SharedString::from(title.to_string()),
            detail: detail
                .filter(|d| !d.trim().is_empty())
                .map(|d| SharedString::from(d.to_string())),
            buttons: buttons.to_vec(),
            focus: buttons.iter().map(|_| cx.focus_handle()).collect(),
            container: cx.focus_handle(),
            os,
            accessory: None,
            message_scroll: ScrollHandle::new(),
            answered: false,
        }
    }

    /// Scrolls the message `lines` lines on (back, when negative).
    fn scroll_message(&mut self, lines: f32, cx: &mut Context<Self>) {
        const LINE: f32 = 20.;
        let max = self.message_scroll.max_offset().y;
        let now = self.message_scroll.offset();
        let y = (now.y - px(lines * LINE)).clamp(-max, px(0.));
        self.message_scroll.set_offset(gpui_kit::point(now.x, y));
        cx.notify();
    }

    /// Answers with the button at `index` (in the order the question gave
    /// them). Only the first answer counts.
    pub fn answer(&mut self, index: usize, cx: &mut Context<Self>) {
        if self.answered || index >= self.buttons.len().max(1) {
            return;
        }
        self.answered = true;
        cx.emit(PromptResponse(index));
    }

    /// Takes the prompt down as its Cancel would: the question was settled
    /// somewhere else.
    pub fn dismiss(&mut self, cx: &mut Context<Self>) {
        self.answer(self.cancel_index(), cx);
    }

    fn cancel_index(&self) -> usize {
        self.buttons
            .iter()
            .position(PromptButton::is_cancel)
            .unwrap_or(0)
    }

    /// The buttons' indices as they stand, first to last.
    fn shown_order(&self) -> Vec<usize> {
        let mut order: Vec<usize> = (0..self.buttons.len()).collect();
        if self.os == KeyOs::Linux {
            order.reverse();
        }
        order
    }

    fn focused(&self, window: &Window) -> Option<usize> {
        self.focus.iter().position(|f| f.is_focused(window))
    }

    /// Every stop Tab reaches, in order: the accessory's, then the buttons
    /// as they stand.
    fn stops(&self) -> Vec<FocusHandle> {
        let accessory = self.accessory.iter().flat_map(|a| a.stops.iter().cloned());
        let buttons = self
            .shown_order()
            .into_iter()
            .map(|i| self.focus[i].clone());
        accessory.chain(buttons).collect()
    }

    /// Moves focus `by` stops along, wrapping, so Tab never leaves.
    fn step(&mut self, by: isize, window: &mut Window, cx: &mut Context<Self>) {
        let stops = self.stops();
        if stops.is_empty() {
            return;
        }
        let at = stops
            .iter()
            .position(|f| f.contains_focused(window, cx))
            .unwrap_or(0) as isize;
        let n = stops.len() as isize;
        window.focus(&stops[(at + by).rem_euclid(n) as usize], cx);
        cx.notify();
    }
}

impl EventEmitter<PromptResponse> for AppPrompt {}

impl Focusable for AppPrompt {
    /// The accessory, else the confirm button, takes the keyboard as the
    /// prompt opens.
    fn focus_handle(&self, _: &App) -> FocusHandle {
        self.accessory
            .as_ref()
            .and_then(|a| a.stops.first())
            .or(self.focus.first())
            .cloned()
            .unwrap_or_else(|| self.container.clone())
    }
}

impl Render for AppPrompt {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let t = cx.conduit().clone();
        let r = &t.roles;
        let radius = f32::from(t.control_radius());
        let destructive = self.level != PromptLevel::Info;
        let buttons = self.shown_order().into_iter().map(|i| {
            let button = &self.buttons[i];
            let focused = self.focus[i].is_focused(window);
            let confirm = !button.is_cancel() && i == 0;
            let (bg, fg) = match (confirm, destructive) {
                (true, true) => (r.danger, r.danger_foreground),
                (true, false) => (r.primary, r.primary_foreground),
                (false, _) => (field_fill(&t), r.text),
            };
            div()
                .id(("prompt-button", i))
                .role(Role::Button)
                .aria_label(button.label().clone())
                .track_focus(&self.focus[i])
                .relative()
                .h(px(t.metrics.control_height))
                .px(px(14.))
                .flex()
                .items_center()
                .justify_center()
                .rounded(px(radius))
                .bg(bg)
                .when(!confirm, |d| d.border_1().border_color(r.border_strong))
                .text_color(fg)
                .text_size(px(t.metrics.control))
                .font_weight(if confirm {
                    FontWeight::SEMIBOLD
                } else {
                    FontWeight::MEDIUM
                })
                .cursor_pointer()
                .on_click(cx.listener(move |this, _, _, cx| this.answer(i, cx)))
                .child(button.label().clone())
                .when(focused, |d| d.child(ring_overlay(Ring::Outset(radius), &t)))
        });
        // The message scrolls inside a card no taller than the window, so
        // the buttons stay in view however long it is.
        let message = div()
            .id("prompt-message")
            .debug_selector(|| "prompt-message".into())
            .track_scroll(&self.message_scroll)
            .overflow_y_scroll()
            .min_h(px(0.))
            .flex_shrink(1.)
            .flex()
            .flex_col()
            .gap(px(8.))
            .child(
                div()
                    .text_size(px(t.metrics.control + 1.))
                    .font_weight(FontWeight::SEMIBOLD)
                    .text_color(r.text)
                    .child(self.title.clone()),
            )
            .when_some(self.detail.clone(), |d, detail| {
                d.child(
                    div()
                        .debug_selector(|| "prompt-detail".into())
                        .text_size(px(t.metrics.control))
                        .text_color(r.text_subtle)
                        .child(detail),
                )
            })
            .when_some(self.accessory.as_ref(), |d, a| {
                d.child(div().pt(px(8.)).child(a.view.clone()))
            });
        let card = div()
            .id("prompt")
            .role(Role::AlertDialog)
            .aria_label(self.title.clone())
            .when_some(self.detail.clone(), |d, detail| d.aria_description(detail))
            .w(px(360.))
            .max_w_full()
            .max_h(gpui_kit::relative(1.))
            .p(px(20.))
            .flex()
            .flex_col()
            .rounded(t.overlay_radius())
            .bg(r.overlay)
            .border_1()
            .border_color(r.border)
            .shadow(overlay_shadow(&t))
            .child(message)
            .child(
                div()
                    .debug_selector(|| "prompt-buttons".into())
                    .flex_none()
                    .pt(px(20.))
                    .flex()
                    .flex_row()
                    .justify_end()
                    .gap(px(8.))
                    .children(buttons),
            );
        div()
            .id("prompt-backdrop")
            .key_context(CONTEXT)
            .track_focus(&self.container)
            .on_action(cx.listener(|this, _: &Confirm, window, cx| {
                let index = this.focused(window).unwrap_or(0);
                this.answer(index, cx);
            }))
            .on_action(
                cx.listener(|this, _: &Press, window, cx| match this.focused(window) {
                    Some(index) => this.answer(index, cx),
                    None => cx.propagate(),
                }),
            )
            .on_action(cx.listener(|this, _: &Cancel, _, cx| this.dismiss(cx)))
            .on_action(cx.listener(|this, _: &NextButton, window, cx| this.step(1, window, cx)))
            .on_action(
                cx.listener(|this, _: &PreviousButton, window, cx| this.step(-1, window, cx)),
            )
            .on_action(cx.listener(|this, _: &LineDown, _, cx| this.scroll_message(1., cx)))
            .on_action(cx.listener(|this, _: &LineUp, _, cx| this.scroll_message(-1., cx)))
            .on_action(cx.listener(|this, _: &PageDown, _, cx| this.scroll_message(8., cx)))
            .on_action(cx.listener(|this, _: &PageUp, _, cx| this.scroll_message(-8., cx)))
            .occlude()
            .size_full()
            .flex()
            .items_center()
            .justify_center()
            .p(px(16.))
            .bg(with_alpha(
                gpui_kit::black(),
                if t.dark { 0.35 } else { 0.2 },
            ))
            .child(card)
    }
}
