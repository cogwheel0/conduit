//! First run: the backend chooser, the Open WebUI server form, and sign-in
//! (password plus SSO). Full-window, centred, on the window surface.

use gpui_kit::component::input::InputState;
use gpui_kit::prelude::*;
use gpui_kit::{
    AnyElement, App, Context, Div, ElementId, Entity, FontWeight, Role, SharedString, Window, div,
    px, relative,
};

use crate::assets::{IconName, brand_mark, icon};
use crate::strings::{ActiveStrings as _, fill};
use crate::theme::{ActiveConduitTheme, UI_FONT, with_alpha};
use crate::views::focus::{ControlExt as _, Ring, pressed_fill};
use crate::views::kit::{
    Button, ClickHandler, SelectHandler, Switch, bare_input, form_field, grouped, grouped_section,
    grouped_tones, heading, icon_tile, inline_field, nav_row_badged, on_click_or_noop, setting_row,
};
use crate::views::model::Backend;
use crate::window::{TOOLBAR_HEIGHT, drag_region};

/// The full-window frame first-run screens sit in: a drag strip on top,
/// content centred in a fixed-width column.
pub fn first_run_frame(content: impl IntoElement, cx: &App) -> Div {
    let t = cx.conduit();
    let label = cx.strings().set_up_conduit.clone();
    let r = t.roles;
    // The phone's grouped page, so the forms' groups read as lifted.
    let (page, _) = grouped_tones(t);
    div()
        .size_full()
        .flex()
        .flex_col()
        .font_family(UI_FONT)
        .bg(page)
        .text_color(r.text)
        .child(
            drag_region("first-run-titlebar")
                .h(px(TOOLBAR_HEIGHT))
                .flex_none()
                .w_full(),
        )
        .child(
            div()
                .id("first-run")
                .role(Role::Main)
                .aria_label(label)
                .flex_1()
                .min_h_0()
                .flex()
                .flex_col()
                .items_center()
                .justify_center()
                .pb(px(TOOLBAR_HEIGHT))
                .child(div().w(px(460.)).child(content)),
        )
}

/// A first-run screen's heading: the brand mark (optional), a level-1
/// title and a subtitle.
pub fn title_block(title: &str, subtitle: &str, mark: bool, cx: &App) -> Div {
    let t = cx.conduit();
    let r = t.roles;
    div()
        .flex()
        .flex_col()
        .items_center()
        .gap(px(8.))
        .when(mark, |d| {
            d.child(
                div()
                    .size(px(56.))
                    .mb(px(6.))
                    .rounded(px(14.))
                    .bg(r.primary)
                    .flex()
                    .items_center()
                    .justify_center()
                    .child(brand_mark(34., r.primary_foreground)),
            )
        })
        .child(heading(
            "first-run-title",
            title.to_string(),
            1,
            26.,
            FontWeight::BOLD,
            r.text,
        ))
        // Centred under the centred title, however many lines it wraps to.
        .child(
            div()
                .text_center()
                .text_size(px(t.metrics.control + 1.))
                .text_color(r.text_subtle)
                .line_height(relative(1.4))
                .child(SharedString::from(subtitle.to_string())),
        )
}

/// The order the chooser lists the backends in.
pub const BACKENDS: [Backend; 4] = [
    Backend::OpenWebUi,
    Backend::Direct,
    Backend::Hermes,
    Backend::LibreChat,
];

/// The chooser's Apple Intelligence section: one row, Apple On-Device,
/// shown while this Mac's model answers (the phone's `backendChooserApple*`
/// section; never Private Cloud Compute on the Mac).
pub struct AppleChoice {
    pub section: SharedString,
    pub title: SharedString,
    pub detail: SharedString,
    pub on_click: ClickHandler,
}

/// "How do you want to connect?" with three radio cards.
#[derive(IntoElement)]
pub struct BackendChooser {
    selected: Backend,
    on_select: Option<SelectHandler>,
    on_continue: Option<ClickHandler>,
    apple: Option<AppleChoice>,
    busy: bool,
}

impl BackendChooser {
    pub fn new(selected: Backend) -> Self {
        Self {
            selected,
            on_select: None,
            on_continue: None,
            apple: None,
            busy: false,
        }
    }
    /// The Apple Intelligence section, between the self-hosted backends and
    /// the model APIs (the phone's order); none when `choice` is None.
    pub fn apple(mut self, choice: Option<AppleChoice>) -> Self {
        self.apple = choice;
        self
    }
    /// Called with the index in [`BACKENDS`] of the card the user picked.
    pub fn on_select(mut self, handler: SelectHandler) -> Self {
        self.on_select = Some(handler);
        self
    }
    pub fn on_continue(mut self, handler: ClickHandler) -> Self {
        self.on_continue = Some(handler);
        self
    }
    pub fn busy(mut self, busy: bool) -> Self {
        self.busy = busy;
        self
    }
}

impl RenderOnce for BackendChooser {
    fn render(self, window: &mut Window, cx: &mut App) -> impl IntoElement {
        let st = cx.strings().clone();
        // The phone's chooser: grouped sections of rows that each go
        // straight to their setup, no separate Continue.
        let row = |i: usize,
                   ic: IconName,
                   title: SharedString,
                   badge: Option<SharedString>,
                   desc: SharedString,
                   window: &mut Window,
                   cx: &mut App| {
            let (on_select, on_continue) = (self.on_select.clone(), self.on_continue.clone());
            let busy = self.busy;
            // The backend chosen last (coming Back from its setup).
            let chosen = BACKENDS.get(i) == Some(&self.selected);
            nav_row_badged(
                ElementId::NamedInteger("backend".into(), i as u64),
                ic,
                title,
                badge,
                Some(desc),
                cx,
            )
            .aria_selected(chosen)
            .on_click(move |e, window, cx| {
                if busy {
                    return;
                }
                if let Some(h) = &on_select {
                    h(i, window, cx)
                }
                if let Some(h) = &on_continue {
                    h(e, window, cx)
                }
            })
            // A row of a grouped card: the ring on its edge, inside the
            // card's rounded clip.
            .keyboard_control(Ring::Inset(10.), window, cx)
            .into_any_element()
        };
        // The phone's order: Open WebUI, LibreChat (Beta), Hermes Agent.
        let self_hosted = vec![
            row(
                0,
                IconName::Server,
                st.open_webui.clone(),
                None,
                st.open_webui_detail.clone(),
                window,
                cx,
            ),
            row(
                3,
                IconName::MessagesSquare,
                st.librechat.clone(),
                Some(st.beta.clone()),
                st.librechat_detail.clone(),
                window,
                cx,
            ),
            row(
                2,
                IconName::Bot,
                st.hermes.clone(),
                None,
                st.hermes_detail.clone(),
                window,
                cx,
            ),
        ];
        let apple = self.apple.as_ref().map(|choice| {
            let (on_click, busy) = (choice.on_click.clone(), self.busy);
            let row = nav_row_badged(
                "backend-apple",
                IconName::Laptop,
                choice.title.clone(),
                None,
                Some(choice.detail.clone()),
                cx,
            )
            .on_click(move |e, window, cx| {
                if !busy {
                    on_click(e, window, cx)
                }
            })
            .keyboard_control(Ring::Inset(10.), window, cx)
            .into_any_element();
            (choice.section.clone(), row)
        });
        let model_apis = vec![row(
            1,
            IconName::Zap,
            st.direct.clone(),
            None,
            st.direct_detail.clone(),
            window,
            cx,
        )];
        div()
            .flex()
            .flex_col()
            .gap(px(24.))
            .child(title_block(
                &st.welcome_title,
                &st.welcome_subtitle,
                true,
                cx,
            ))
            .child(
                div()
                    .id("backend-choices")
                    .role(Role::Group)
                    .aria_label(st.backend.clone())
                    .flex()
                    .flex_col()
                    .gap(px(20.))
                    .child(grouped_section(
                        Some(st.self_hosted_section.clone()),
                        self_hosted,
                        None,
                        cx,
                    ))
                    .when_some(apple, |el, (section, row)| {
                        el.child(grouped_section(Some(section), vec![row], None, cx))
                    })
                    .child(grouped_section(
                        Some(st.model_apis_section.clone()),
                        model_apis,
                        None,
                        cx,
                    )),
            )
    }
}

/// "‹ Back": a link-styled button at the top of a first-run form.
pub fn back_link(label: SharedString, on_click: Option<ClickHandler>, _: &App) -> AnyElement {
    BackLink { label, on_click }.into_any_element()
}

#[derive(IntoElement)]
struct BackLink {
    label: SharedString,
    on_click: Option<ClickHandler>,
}

impl RenderOnce for BackLink {
    fn render(self, window: &mut Window, cx: &mut App) -> impl IntoElement {
        let t = cx.conduit().clone();
        let r = t.roles;
        div()
            .id("back")
            .role(Role::Button)
            .aria_label(self.label.clone())
            // As wide as its label (in a column it would stretch, and so
            // would its focus ring).
            .self_start()
            .flex()
            .items_center()
            .gap(px(2.))
            .h(px(24.))
            .px(px(4.))
            .ml(px(-4.))
            .rounded(t.control_radius())
            .cursor_pointer()
            .text_size(px(t.metrics.control))
            .text_color(r.text_subtle)
            .hover(|s| s.text_color(r.text))
            .active(|s| s.bg(pressed_fill(r.hover, &t)))
            .child(icon(IconName::ChevronLeft, 14., r.text_subtle))
            .child(self.label)
            .on_click(on_click_or_noop(self.on_click))
            .keyboard_control(Ring::Outset(f32::from(t.control_radius())), window, cx)
    }
}

/// The Open WebUI server form.
pub struct ServerForm {
    pub url: Entity<InputState>,
    pub name: Entity<InputState>,
    pub self_signed: bool,
    pub advanced_open: bool,
    /// Which field draws as focused in a static render.
    pub focused: Option<usize>,
}

impl ServerForm {
    pub fn new(window: &mut Window, cx: &mut Context<Self>) -> Self {
        Self {
            url: cx.new(|cx| {
                InputState::new(window, cx).placeholder(cx.strings().server_url_hint.clone())
            }),
            name: cx.new(|cx| {
                InputState::new(window, cx)
                    .placeholder(cx.strings().server_name_placeholder.clone())
            }),
            self_signed: false,
            advanced_open: true,
            focused: None,
        }
    }
}

impl Render for ServerForm {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let t = cx.conduit().clone();
        let st = cx.strings().clone();
        let r = t.roles;
        let url = inline_field(cx)
            .child(icon(IconName::Globe, 14., r.text_faint))
            .child(div().flex_1().child(bare_input(
                &self.url,
                st.server_url.clone(),
                t.metrics.control + 1.,
            )));
        let name = inline_field(cx).child(div().flex_1().child(bare_input(
            &self.name,
            st.display_name.clone(),
            t.metrics.control + 1.,
        )));
        div()
            .flex()
            .flex_col()
            .gap(px(20.))
            .child(back_link(st.back.clone(), None, cx))
            .child(title_block(
                &st.connect_title,
                &st.connect_subtitle,
                false,
                cx,
            ))
            .child(form_field(
                st.server_url.clone(),
                url,
                Some(st.server_url_help.clone()),
                cx,
            ))
            .child(form_field(
                st.display_name.clone(),
                name,
                Some(st.display_name_help.clone()),
                cx,
            ))
            .child(
                div()
                    .flex()
                    .flex_col()
                    .gap(px(8.))
                    .child(
                        div()
                            .id("advanced")
                            .role(Role::Button)
                            .aria_label(st.advanced.clone())
                            .aria_expanded(self.advanced_open)
                            .flex()
                            .items_center()
                            .gap(px(4.))
                            .cursor_pointer()
                            .text_size(px(t.metrics.control))
                            .font_weight(FontWeight::MEDIUM)
                            .text_color(r.text)
                            .child(icon(
                                if self.advanced_open {
                                    IconName::ChevronDown
                                } else {
                                    IconName::ChevronRight
                                },
                                13.,
                                r.text_subtle,
                            ))
                            .child(st.advanced.clone())
                            .on_click(|_, _, _| {}),
                    )
                    .when(self.advanced_open, |d| {
                        d.child(grouped(
                            vec![
                                setting_row(
                                    st.self_signed.clone(),
                                    Some(st.self_signed_help.clone()),
                                    Switch::new(
                                        "self-signed",
                                        st.self_signed.clone(),
                                        self.self_signed,
                                    ),
                                    cx,
                                )
                                .into_any_element(),
                                setting_row(
                                    st.client_certificate.clone(),
                                    Some(st.client_certificate_help.clone()),
                                    Button::new("choose-cert", st.choose_file.clone()),
                                    cx,
                                )
                                .into_any_element(),
                                setting_row(
                                    st.custom_headers.clone(),
                                    Some(st.custom_headers_help.clone()),
                                    Button::new("add-header", st.add.clone()).icon(IconName::Plus),
                                    cx,
                                )
                                .into_any_element(),
                            ],
                            cx,
                        ))
                    }),
            )
            .child(
                Button::new("connect", st.connect.clone())
                    .primary()
                    .large()
                    .full_width(),
            )
    }
}

/// Sign-in: email and password, then SSO.
pub struct SignInForm {
    pub server: SharedString,
    pub email: Entity<InputState>,
    pub password: Entity<InputState>,
    pub focused: Option<usize>,
}

impl SignInForm {
    pub fn new(
        server: impl Into<SharedString>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Self {
        Self {
            server: server.into(),
            email: cx.new(|cx| InputState::new(window, cx).placeholder("name@example.com")),
            password: cx.new(|cx| {
                InputState::new(window, cx)
                    .placeholder(cx.strings().password.clone())
                    .masked(true)
            }),
            focused: None,
        }
    }
}

impl Render for SignInForm {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let t = cx.conduit().clone();
        let st = cx.strings().clone();
        let r = t.roles;
        let m = t.metrics;
        let email = inline_field(cx).child(div().flex_1().child(bare_input(
            &self.email,
            st.email.clone(),
            t.metrics.control + 1.,
        )));
        let password = inline_field(cx).child(div().flex_1().child(bare_input(
            &self.password,
            st.password.clone(),
            t.metrics.control + 1.,
        )));
        let rule = || div().flex_1().h(px(1.)).bg(r.border);
        div()
            .flex()
            .flex_col()
            .gap(px(20.))
            .child(back_link(st.back.clone(), None, cx))
            .child(
                div()
                    .flex()
                    .flex_col()
                    .items_center()
                    .gap(px(14.))
                    .child(
                        div()
                            .id("server-chip")
                            .role(Role::Button)
                            .aria_label(fill(&st.server_chip, &[("name", &self.server)]))
                            .h(px(30.))
                            .pl(px(6.))
                            .pr(px(10.))
                            .flex()
                            .items_center()
                            .gap(px(7.))
                            .rounded_full()
                            .border_1()
                            .border_color(r.border)
                            .bg(t.surfaces.panel)
                            .cursor_pointer()
                            .child(icon_tile(
                                IconName::Server,
                                20.,
                                with_alpha(r.text, if t.dark { 0.14 } else { 0.07 }),
                                r.text_subtle,
                                10.,
                            ))
                            .child(
                                div()
                                    .text_size(px(m.small))
                                    .text_color(r.text)
                                    .child(self.server.clone()),
                            )
                            .child(
                                div()
                                    .text_size(px(m.small))
                                    .text_color(r.text_subtle)
                                    .child(st.change.clone()),
                            )
                            .on_click(|_, _, _| {}),
                    )
                    .child(title_block(&st.sign_in, &st.sign_in_subtitle, false, cx)),
            )
            .child(form_field(st.email.clone(), email, None, cx))
            .child(form_field(st.password.clone(), password, None, cx))
            .child(
                Button::new("sign-in", st.sign_in.clone())
                    .primary()
                    .large()
                    .full_width(),
            )
            .child(
                div()
                    .flex()
                    .items_center()
                    .gap(px(10.))
                    .text_size(px(m.small))
                    .text_color(r.text_subtle)
                    .child(rule())
                    .child(st.or.clone())
                    .child(rule()),
            )
            .child(
                Button::new("sso", st.sso.clone())
                    .icon(IconName::KeyRound)
                    .large()
                    .full_width(),
            )
            .child(
                div()
                    .flex()
                    .justify_center()
                    .gap(px(16.))
                    .child(link("ldap", st.ldap.clone(), None, cx))
                    .child(link("token", st.token.clone(), None, cx)),
            )
    }
}

/// A small link-styled button under a first-run form.
pub fn link(
    id: &'static str,
    label: SharedString,
    on_click: Option<ClickHandler>,
    _: &App,
) -> AnyElement {
    TextLink {
        id,
        label,
        on_click,
    }
    .into_any_element()
}

#[derive(IntoElement)]
struct TextLink {
    id: &'static str,
    label: SharedString,
    on_click: Option<ClickHandler>,
}

impl RenderOnce for TextLink {
    fn render(self, window: &mut Window, cx: &mut App) -> impl IntoElement {
        let t = cx.conduit().clone();
        let r = t.roles;
        div()
            .id(self.id)
            .role(Role::Link)
            .aria_label(self.label.clone())
            .cursor_pointer()
            .rounded(px(4.))
            .text_size(px(t.metrics.small))
            .font_weight(FontWeight::MEDIUM)
            .text_color(r.text_subtle)
            .hover(|s| s.text_color(r.text))
            .active(|s| s.text_color(r.text).bg(pressed_fill(r.hover, &t)))
            .child(self.label)
            .on_click(on_click_or_noop(self.on_click))
            .keyboard_control(Ring::Outset(4.), window, cx)
    }
}
