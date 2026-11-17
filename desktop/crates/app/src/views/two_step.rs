//! The second step of an Open WebUI sign-in with two-step verification
//! (`auth.twoStep.*`), drawn in the sign-in page in place of its form, as the
//! phone's sign-in page does (`OpenWebUiTwoStepForm`):
//!
//! * **Verify**: the code from the account's authenticator app, or one of
//!   its recovery codes (Use a Recovery Code).
//! * **Enrol**: the first sign-in since two-step verification became
//!   required. The server's QR code and its setup key (Copy Setup Key, Add
//!   to Authenticator App), then the code the app shows.
//! * **Recover**: an administrator reset the authenticator: their recovery
//!   token, which leads on to enrolling a new one.
//! * **Recovery codes**: shown once, after a new authenticator was added,
//!   before the session is signed in to (Copy Recovery Codes, Continue).
//!
//! Back to Sign In leaves the step (`auth.twoStep.cancel`). The challenge
//! stays in the daemon: the window holds only what it shows. The code field
//! is a plain field: GPUI's text input is drawn by the app, so AppKit's
//! one-time-code autofill (`NSTextContentType.oneTimeCode`) cannot reach it.

use std::rc::Rc;
use std::sync::Arc;

use conduit_components::ActiveConduitTheme as _;
use conduit_components::theme::MONO_FONT;
use conduit_components::views::kit::{Button, ClickHandler, grouped_tones};
use conduit_components::views::onboarding::{back_link, link, title_block};
use conduit_daemon::RpcError;
use conduit_protocol::{
    AuthSnapshot, NoParams, TwoStepChallenge, TwoStepCode, TwoStepResetToken, TwoStepSetup,
    TwoStepStage, methods,
};
use gpui_kit::component::input::{InputEvent, InputState};
use gpui_kit::prelude::*;
use gpui_kit::{
    App, AsyncWindowContext, ClickEvent, ClipboardItem, Context, Entity, Image, ImageFormat,
    ObjectFit, Role, SharedString, Subscription, WeakEntity, Window, div, img, px, relative,
};

use crate::l10n::ActiveL10n as _;
use crate::stores::Stores;
use crate::views::forms::{self, field, form_buttons, form_error, form_group};
use crate::views::sign_in::server_chip;
use crate::views::words;

/// The QR code's side, in points: beside the key, so the whole step fits
/// the setup window without scrolling.
pub const QR_SIDE: f32 = 132.;

/// One attempt at the second step, as the window tells attempts apart: its
/// stage and the account whose sign-in it is.
#[derive(Clone, Debug, PartialEq, Eq)]
struct Attempt {
    stage: Option<TwoStepStage>,
    scope: (Option<String>, bool),
}

/// Loading the enrol step's setup key.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SetupState {
    Idle,
    Loading,
    Failed,
}

pub struct TwoStepView {
    stores: Stores,
    /// The code, recovery code or recovery token.
    pub code: Entity<InputState>,
    /// A verify step answered with a recovery code.
    pub recovery: bool,
    pub busy: bool,
    pub error: Option<String>,
    /// The enrol step's key, once the daemon answered.
    pub setup: Option<TwoStepSetup>,
    pub setup_state: SetupState,
    /// The server's QR code, ready to draw.
    qr: Option<Arc<Image>>,
    /// The attempt last drawn (its stage and the account it is for): a new
    /// one starts with an empty field and no key.
    seen: Option<Attempt>,
    /// Counts attempts: an answer applies only to the attempt it was asked
    /// for (a cancel, another account or a new enrolment moves it on).
    attempt: u64,
    /// A new stage puts the cursor in its field on its first draw.
    focus_field: bool,
    _subscriptions: Vec<Subscription>,
}

impl TwoStepView {
    pub fn new(stores: Stores, window: &mut Window, cx: &mut Context<Self>) -> Self {
        let l10n = cx.l10n().clone();
        let code = forms::input(l10n.desktop_required_placeholder(), false, window, cx);
        let subscriptions = vec![
            cx.subscribe_in(
                &code,
                window,
                |this: &mut Self, _, e: &InputEvent, window, cx| match e {
                    InputEvent::PressEnter { .. } if this.ready(cx) => this.submit(window, cx),
                    InputEvent::Change => {
                        if !this.busy {
                            this.error = None;
                        }
                        cx.notify();
                    }
                    _ => {}
                },
            ),
            cx.observe_in(&stores.session, window, |this: &mut Self, _, window, cx| {
                this.sync(window, cx);
            }),
        ];
        let mut view = Self {
            stores,
            code,
            recovery: false,
            busy: false,
            error: None,
            setup: None,
            setup_state: SetupState::Idle,
            qr: None,
            seen: None,
            attempt: 0,
            focus_field: false,
            _subscriptions: subscriptions,
        };
        view.sync(window, cx);
        view
    }

    /// The step the daemon holds for this sign-in, if one does.
    pub fn challenge(&self, cx: &App) -> Option<TwoStepChallenge> {
        self.stores
            .session
            .read(cx)
            .auth
            .as_ref()
            .filter(|a| !a.is_authenticated)
            .and_then(|a| a.two_step.clone())
    }

    /// The account this step is for: an answer that comes after another
    /// account's sign-in started is dropped, as the sign-in form's is.
    fn scope(&self, cx: &App) -> (Option<String>, bool) {
        crate::views::sign_in::sign_in_scope(self.stores.accounts.read(cx))
    }

    fn stage(&self, cx: &App) -> Option<TwoStepStage> {
        self.challenge(cx).map(|c| c.stage)
    }

    /// A new attempt (another stage, none, or another account's) clears
    /// what the last one left, its key and an answer still out included; an
    /// enrol step loads its own setup key.
    fn sync(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let stage = self.stage(cx);
        let now = Attempt {
            stage,
            scope: self.scope(cx),
        };
        if self.seen.as_ref() == Some(&now) {
            return;
        }
        self.seen = Some(now);
        self.attempt += 1;
        self.recovery = false;
        self.error = None;
        self.busy = false;
        self.setup = None;
        self.qr = None;
        self.setup_state = SetupState::Idle;
        self.code.update(cx, |i, cx| i.set_value("", window, cx));
        if stage == Some(TwoStepStage::Enroll) {
            self.load_setup(cx);
        }
        self.focus_field = matches!(
            stage,
            Some(TwoStepStage::Verify | TwoStepStage::Enroll | TwoStepStage::Recover)
        );
        cx.notify();
    }

    /// What to add to an authenticator app (`auth.twoStep.setup`).
    pub fn load_setup(&mut self, cx: &mut Context<Self>) {
        if self.setup_state == SetupState::Loading {
            return;
        }
        self.setup_state = SetupState::Loading;
        self.error = None;
        cx.notify();
        let call = self
            .stores
            .connection
            .read(cx)
            .rpc()
            .call::<methods::AuthTwoStepSetup>(&NoParams);
        let attempt = self.attempt;
        cx.spawn(
            async move |this: WeakEntity<Self>, cx: &mut gpui_kit::AsyncApp| {
                let result = call.await;
                let _ = this.update(cx, |s, cx| {
                    // Another attempt's key: the codes it makes are not the
                    // ones the daemon would take now.
                    if s.attempt != attempt {
                        return;
                    }
                    match result {
                        Ok(setup) => {
                            s.qr = setup.qr_svg.as_deref().map(qr_image);
                            s.setup = Some(setup);
                            s.setup_state = SetupState::Idle;
                        }
                        Err(e) => {
                            log::warn!("auth.twoStep.setup: {e}");
                            s.setup_state = SetupState::Failed;
                            if e.code.as_str() != "auth.twoStepFailed" {
                                s.error = Some(words::sign_in_error(e.code.as_str(), cx.l10n()));
                            }
                        }
                    }
                    cx.notify();
                });
            },
        )
        .detach();
    }

    /// Whether Continue can go: not busy, and the field filled (an enrol
    /// step also needs its key, so the code is the key's).
    pub fn ready(&self, cx: &App) -> bool {
        if self.busy {
            return false;
        }
        match self.stage(cx) {
            Some(TwoStepStage::RecoveryCodes) => true,
            Some(TwoStepStage::Enroll) => self.setup.is_some() && forms::filled(&[&self.code], cx),
            Some(_) => forms::filled(&[&self.code], cx),
            None => false,
        }
    }

    /// Continue: the code, the recovery token, or (after the recovery
    /// codes) the sign-in.
    pub fn submit(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(stage) = self.stage(cx) else {
            return;
        };
        if !self.ready(cx) {
            return;
        }
        let rpc = self.stores.connection.read(cx).rpc();
        let code = forms::text(&self.code, cx);
        let call = match stage {
            TwoStepStage::Verify | TwoStepStage::Enroll => {
                futures::FutureExt::boxed(rpc.call::<methods::AuthTwoStepVerify>(&TwoStepCode {
                    code,
                    recovery: self.recovery && stage == TwoStepStage::Verify,
                }))
            }
            TwoStepStage::Recover => futures::FutureExt::boxed(
                rpc.call::<methods::AuthTwoStepRedeem>(&TwoStepResetToken { reset_token: code }),
            ),
            TwoStepStage::RecoveryCodes => {
                futures::FutureExt::boxed(rpc.call::<methods::AuthTwoStepFinish>(&NoParams))
            }
            // A stage this build doesn't know: nothing to answer it with.
            TwoStepStage::Unknown => return,
        };
        self.busy = true;
        self.error = None;
        let attempt = self.attempt;
        cx.notify();
        cx.spawn_in(
            window,
            async move |this: WeakEntity<Self>, cx: &mut AsyncWindowContext| {
                let result = call.await;
                let _ = this.update_in(cx, |s, window, cx| {
                    // The attempt moved on meanwhile: its answer is not this
                    // one's (and the new attempt started not busy).
                    if s.attempt != attempt {
                        return;
                    }
                    s.finish(result, window, cx)
                });
            },
        )
        .detach();
    }

    fn finish(
        &mut self,
        result: Result<AuthSnapshot, RpcError>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.busy = false;
        match result {
            Ok(snapshot) => {
                self.stores
                    .session
                    .update(cx, |s, cx| s.adopt_auth(snapshot, cx));
            }
            Err(e) => {
                self.error = Some(words::sign_in_error(e.code.as_str(), cx.l10n()));
                if self.stage(cx) != Some(TwoStepStage::RecoveryCodes) {
                    forms::focus_invalid(&self.code.clone(), window, cx);
                }
            }
        }
        cx.notify();
    }

    /// Back to Sign In.
    pub fn cancel(&mut self, cx: &mut Context<Self>) {
        if self.busy {
            return;
        }
        let call = self
            .stores
            .connection
            .read(cx)
            .rpc()
            .call::<methods::AuthTwoStepCancel>(&NoParams);
        let session = self.stores.session.clone();
        let attempt = self.attempt;
        cx.spawn(
            async move |this: WeakEntity<Self>, cx: &mut gpui_kit::AsyncApp| {
                if let Ok(snapshot) = call.await
                    && this
                        .update(cx, |s, _| s.attempt == attempt)
                        .unwrap_or(false)
                {
                    session.update(cx, |s, cx| s.adopt_auth(snapshot, cx));
                }
            },
        )
        .detach();
    }

    /// Use a Recovery Code, or back to an authenticator code.
    pub fn toggle_recovery(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.busy {
            return;
        }
        self.recovery = !self.recovery;
        self.error = None;
        self.code.update(cx, |i, cx| {
            i.set_value("", window, cx);
            i.focus(window, cx);
        });
        cx.notify();
    }

    fn copy(&self, text: String, cx: &mut App) {
        cx.write_to_clipboard(ClipboardItem::new_string(text));
        let copied = cx.l10n().desktop_copied();
        self.stores.toasts.update(cx, |t, cx| {
            t.show(conduit_protocol::NoticeLevel::Success, copied, cx)
        });
    }

    pub fn copy_setup_key(&mut self, cx: &mut Context<Self>) {
        if let Some(setup) = &self.setup {
            self.copy(setup.manual_key.clone(), cx);
        }
    }

    pub fn copy_recovery_codes(&mut self, cx: &mut Context<Self>) {
        if let Some(c) = self.challenge(cx) {
            self.copy(c.recovery_codes.join("\n"), cx);
        }
    }

    /// Add to Authenticator App: the `otpauth://` link, to whichever app on
    /// this Mac adds codes (Passwords does); says so when none does.
    pub fn open_authenticator(&mut self, cx: &mut Context<Self>) {
        let Some(uri) = self.setup.as_ref().map(|s| s.authenticator_uri.clone()) else {
            return;
        };
        if crate::shell::open_url::has_handler(&uri) {
            cx.open_url(&uri);
        } else {
            let text = cx.l10n().two_step_no_authenticator_app();
            self.stores.toasts.update(cx, |t, cx| {
                t.show(conduit_protocol::NoticeLevel::Warning, text, cx)
            });
        }
    }
}

/// The server's QR code as an image: its SVG says its size in millimetres,
/// which would be drawn at about 180 px and scaled; given in pixels well
/// above the drawn size, it stays sharp on a Retina display.
pub fn qr_image(svg: &str) -> Arc<Image> {
    Arc::new(Image::from_bytes(
        ImageFormat::Svg,
        sized_svg(svg, 640).into_bytes(),
    ))
}

/// `svg` with its root element's `width` and `height` set to `side` pixels
/// (its `viewBox` keeps the drawing).
pub fn sized_svg(svg: &str, side: u32) -> String {
    let Some(start) = svg.find("<svg") else {
        return svg.to_string();
    };
    let Some(end) = svg[start..].find('>').map(|e| start + e) else {
        return svg.to_string();
    };
    let mut tag = svg[start..end].to_string();
    for name in ["width", "height"] {
        let needle = format!(" {name}=\"");
        if let Some(i) = tag.find(&needle) {
            let value_start = i + needle.len();
            if let Some(len) = tag[value_start..].find('"') {
                tag.replace_range(value_start..value_start + len, &side.to_string());
            }
        } else {
            tag.push_str(&format!(" {name}=\"{side}\""));
        }
    }
    format!("{}{}{}", &svg[..start], tag, &svg[end..])
}

/// The key as authenticator apps show it: groups of four.
pub fn grouped_key(key: &str) -> String {
    key.chars()
        .collect::<Vec<_>>()
        .chunks(4)
        .map(|c| c.iter().collect::<String>())
        .collect::<Vec<_>>()
        .join(" ")
}

impl Render for TwoStepView {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let l10n = cx.l10n().clone();
        let t = cx.conduit().clone();
        let r = t.roles;
        let m = t.metrics;
        let Some(challenge) = self.challenge(cx) else {
            return div().id("two-step");
        };
        let stage = challenge.stage;
        if stage == TwoStepStage::Unknown {
            return div().id("two-step");
        }
        if std::mem::take(&mut self.focus_field) {
            // Drawn now: the field takes the cursor (the form's own field,
            // focused before, is no longer on screen).
            let code = self.code.clone();
            window.on_next_frame(move |window, cx| {
                code.update(cx, |s, cx| s.focus(window, cx));
            });
        }
        let this = cx.entity().downgrade();
        let handler = |f: fn(&mut TwoStepView, &mut Window, &mut Context<TwoStepView>)| {
            let this = this.clone();
            Rc::new(move |_: &ClickEvent, window: &mut Window, cx: &mut App| {
                let _ = this.update(cx, |s, cx| f(s, window, cx));
            })
        };
        let (title, description) = match stage {
            TwoStepStage::Verify => (
                l10n.two_step_verify_title(),
                if self.recovery {
                    l10n.two_step_recovery_code_description()
                } else {
                    l10n.two_step_verify_description()
                },
            ),
            TwoStepStage::Enroll => (
                l10n.two_step_enroll_title(),
                l10n.two_step_enroll_description(),
            ),
            TwoStepStage::Recover => (
                l10n.two_step_recover_title(),
                l10n.two_step_recover_description(),
            ),
            TwoStepStage::RecoveryCodes | TwoStepStage::Unknown => (
                l10n.two_step_recovery_codes_title(),
                l10n.two_step_recovery_codes_description(),
            ),
        };
        let label = match stage {
            TwoStepStage::Recover => l10n.two_step_reset_token_label(),
            TwoStepStage::Verify if self.recovery => l10n.two_step_recovery_code_label(),
            _ => l10n.two_step_code_label(),
        };
        let (_, card) = grouped_tones(&t);
        let header = div()
            .flex()
            .flex_col()
            .items_center()
            .gap(px(14.))
            .child(server_chip(&self.stores, cx))
            .child(title_block(&title, &description, false, cx));

        let setup = (stage == TwoStepStage::Enroll).then(|| {
            let body = match (&self.setup, self.setup_state) {
                (Some(setup), _) => {
                    let key = grouped_key(&setup.manual_key);
                    div()
                        .id("two-step-setup")
                        .w_full()
                        .flex()
                        .items_center()
                        .gap(px(16.))
                        .p(px(14.))
                        .when_some(self.qr.clone(), |d, qr| {
                            d.child(
                                div()
                                    .id("two-step-qr")
                                    .role(Role::Image)
                                    .aria_label(l10n.two_step_qr_code_label())
                                    .flex_none()
                                    // Scanners need the code dark on light,
                                    // in either appearance.
                                    .bg(gpui_kit::white())
                                    .rounded(px(8.))
                                    .p(px(6.))
                                    .child(
                                        img(qr).size(px(QR_SIDE)).object_fit(ObjectFit::Contain),
                                    ),
                            )
                        })
                        .child(
                            div()
                                .flex_1()
                                .min_w_0()
                                .flex()
                                .flex_col()
                                .gap(px(10.))
                                .child(
                                    div()
                                        .id("two-step-key")
                                        .role(Role::Group)
                                        .aria_label(format!(
                                            "{}: {}",
                                            l10n.two_step_setup_key_label(),
                                            key
                                        ))
                                        .flex()
                                        .flex_col()
                                        .gap(px(2.))
                                        .child(
                                            div()
                                                .text_size(px(m.small))
                                                .text_color(r.text_subtle)
                                                .child(l10n.two_step_setup_key_label()),
                                        )
                                        .child(
                                            div()
                                                .font_family(MONO_FONT)
                                                .text_size(px(m.control))
                                                .line_height(relative(1.4))
                                                .text_color(r.text)
                                                .child(key),
                                        ),
                                )
                                .child(
                                    div()
                                        .flex()
                                        .flex_wrap()
                                        .gap(px(8.))
                                        .child(
                                            Button::new(
                                                "two-step-copy-key",
                                                l10n.two_step_copy_setup_key(),
                                            )
                                            .icon(conduit_components::assets::IconName::Copy)
                                            .on_click(handler(|s, _, cx| s.copy_setup_key(cx))),
                                        )
                                        .child(
                                            Button::new(
                                                "two-step-open-authenticator",
                                                l10n.two_step_open_authenticator(),
                                            )
                                            .on_click(handler(|s, _, cx| s.open_authenticator(cx))),
                                        ),
                                ),
                        )
                        .into_any_element()
                }
                (None, SetupState::Failed) => div()
                    .w_full()
                    .p(px(16.))
                    .flex()
                    .items_center()
                    .gap(px(12.))
                    .child(
                        div()
                            .flex_1()
                            .text_size(px(m.small))
                            .text_color(r.text_subtle)
                            .child(l10n.two_step_setup_failed()),
                    )
                    .child(
                        Button::new("two-step-retry-setup", l10n.desktop_try_again())
                            .on_click(handler(|s, _, cx| s.load_setup(cx))),
                    )
                    .into_any_element(),
                (None, _) => div()
                    .id("two-step-setup-loading")
                    .role(Role::Status)
                    .w_full()
                    .p(px(16.))
                    .text_size(px(m.small))
                    .text_color(r.text_subtle)
                    .child(l10n.two_step_setup_loading())
                    .into_any_element(),
            };
            div().w_full().rounded(px(10.)).bg(card).child(body)
        });

        let content = if stage == TwoStepStage::RecoveryCodes {
            let codes = challenge.recovery_codes.clone();
            let list = div()
                .id("two-step-recovery-codes")
                .role(Role::Group)
                .aria_label(l10n.two_step_recovery_codes_title())
                .w_full()
                .p(px(16.))
                .rounded(px(10.))
                .bg(card)
                .flex()
                .flex_col()
                .gap(px(4.))
                .font_family(MONO_FONT)
                .text_size(px(m.control))
                .text_color(r.text)
                .children(codes.into_iter().map(|c| div().child(c)));
            div()
                .flex()
                .flex_col()
                .gap(px(14.))
                .child(list)
                .when_some(self.error.clone(), |d, e| {
                    d.child(form_error("two-step-error", e, cx))
                })
                .child(form_buttons(vec![
                    Button::new("two-step-copy-codes", l10n.two_step_copy_recovery_codes())
                        .icon(conduit_components::assets::IconName::Copy)
                        .on_click(handler(|s, _, cx| s.copy_recovery_codes(cx)))
                        .into_any_element(),
                    Button::new(
                        "two-step-continue",
                        if self.busy {
                            l10n.desktop_signing_in()
                        } else {
                            l10n.continue_action()
                        },
                    )
                    .primary()
                    .disabled(!self.ready(cx))
                    .on_click(handler(|s, window, cx| s.submit(window, cx)))
                    .into_any_element(),
                ]))
        } else {
            let toggle = (stage == TwoStepStage::Verify).then(|| {
                link(
                    "two-step-toggle-recovery",
                    if self.recovery {
                        l10n.two_step_use_authenticator_code()
                    } else {
                        l10n.two_step_use_recovery_code()
                    }
                    .into(),
                    Some(handler(|s, window, cx| s.toggle_recovery(window, cx))),
                    cx,
                )
            });
            div()
                .flex()
                .flex_col()
                .gap(px(14.))
                .children(setup)
                .child(form_group(
                    vec![field(label, &self.code, None, None, window, cx).into_any_element()],
                    cx,
                ))
                .when_some(self.error.clone(), |d, e| {
                    d.child(form_error("two-step-error", e, cx))
                })
                .child(
                    div()
                        .w_full()
                        .flex()
                        .items_center()
                        .child(div().flex_1().children(toggle))
                        .child(form_buttons(vec![
                            Button::new(
                                "two-step-continue",
                                if self.busy {
                                    l10n.desktop_signing_in()
                                } else {
                                    l10n.continue_action()
                                },
                            )
                            .primary()
                            .disabled(!self.ready(cx))
                            .on_click(handler(|s, window, cx| s.submit(window, cx)))
                            .into_any_element(),
                        ])),
                )
        };

        let back: SharedString = l10n.two_step_back_to_sign_in().into();
        div()
            .id("two-step")
            .role(Role::Form)
            .aria_label(title.clone())
            .flex()
            .flex_col()
            .gap(px(18.))
            .when(stage != TwoStepStage::RecoveryCodes, |d| {
                d.child(back_link(
                    back,
                    (!self.busy).then(|| -> ClickHandler { handler(|s, _, cx| s.cancel(cx)) }),
                    cx,
                ))
            })
            .child(header)
            .child(content)
            .text_size(px(m.control))
            .line_height(relative(1.3))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_qr_code_is_drawn_at_a_size_in_pixels() {
        let svg = "<?xml version='1.0'?>\n<svg width=\"49mm\" height=\"49mm\" \
                   viewBox=\"0 0 49 49\"><path d=\"M4,4H5V5H4z\"/></svg>";
        let sized = sized_svg(svg, 640);
        assert!(sized.contains("width=\"640\" height=\"640\""), "{sized}");
        assert!(sized.contains("viewBox=\"0 0 49 49\""), "{sized}");
        assert!(sized.ends_with("</svg>"));
        // No size at all: one is added.
        assert!(sized_svg("<svg viewBox=\"0 0 9 9\"></svg>", 90).contains("width=\"90\""));
        // Not an SVG: left alone.
        assert_eq!(sized_svg("nothing", 90), "nothing");
    }

    use gpui_kit::TestAppContext;

    use crate::stores::accounts::tests::{account, list};
    use crate::stores::rpc::fake::FakeDaemon;

    /// The daemon's sign-in at `stage` (or none), not signed in.
    fn at(stage: Option<&str>) -> AuthSnapshot {
        let two_step = stage.map(|stage| {
            serde_json::json!({
                "stage": stage, "account": "avery", "expiresInSeconds": 300,
                "recoveryCodes": []
            })
        });
        serde_json::from_value(serde_json::json!({
            "phase": "unauthenticated", "isAuthenticated": false, "hasToken": false,
            "isLoading": false, "twoStep": two_step
        }))
        .unwrap()
    }

    fn key(manual_key: &str) -> TwoStepSetup {
        serde_json::from_value(serde_json::json!({
            "manualKey": manual_key,
            "authenticatorUri": format!("otpauth://totp/Demo:avery?secret={manual_key}")
        }))
        .unwrap()
    }

    fn view<'a>(
        daemon: &FakeDaemon,
        name: &str,
        cx: &'a mut TestAppContext,
    ) -> (
        Stores,
        Entity<TwoStepView>,
        &'a mut gpui_kit::VisualTestContext,
    ) {
        let scratch = std::env::temp_dir().join(format!("conduit-{name}-{}", std::process::id()));
        let stores = cx.update(|cx| {
            crate::views::test_globals(cx);
            Stores::for_test(daemon.rpc(), &scratch, cx)
        });
        stores.accounts.update(cx, |a, cx| {
            a.adopt(
                list(vec![
                    account("a", "Avery", true, false),
                    account("b", "Blake", false, false),
                ]),
                cx,
            )
        });
        let s = stores.clone();
        let (view, vcx) = cx.add_window_view(move |window, cx| TwoStepView::new(s, window, cx));
        (stores, view, vcx)
    }

    fn shown_key(
        view: &Entity<TwoStepView>,
        vcx: &mut gpui_kit::VisualTestContext,
    ) -> Option<String> {
        view.read_with(vcx, |v, _| v.setup.as_ref().map(|s| s.manual_key.clone()))
    }

    #[gpui_kit::test]
    fn a_key_loaded_for_an_abandoned_enrolment_never_replaces_the_next_ones(
        cx: &mut TestAppContext,
    ) {
        let daemon = FakeDaemon::new();
        daemon
            .once::<methods::AuthTwoStepSetup>(Ok(key("OLDKEY")))
            .once::<methods::AuthTwoStepSetup>(Ok(key("NEWKEY")));
        let held = daemon.hold_one::<methods::AuthTwoStepSetup>(0);
        let (stores, view, vcx) = view(&daemon, "two-step-abandoned", cx);
        stores
            .session
            .update(vcx, |s, cx| s.adopt_auth(at(Some("enroll")), cx));
        vcx.run_until_parked();
        // Back to Sign In while the key loads, then enrolling again.
        stores
            .session
            .update(vcx, |s, cx| s.adopt_auth(at(None), cx));
        vcx.run_until_parked();
        stores
            .session
            .update(vcx, |s, cx| s.adopt_auth(at(Some("enroll")), cx));
        vcx.run_until_parked();
        assert_eq!(shown_key(&view, vcx).as_deref(), Some("NEWKEY"));
        held.release();
        vcx.run_until_parked();
        assert_eq!(
            shown_key(&view, vcx).as_deref(),
            Some("NEWKEY"),
            "the abandoned enrolment's key came back"
        );
    }

    #[test]
    fn the_setup_key_reads_in_groups_of_four() {
        assert_eq!(grouped_key("MFRGGZDFMZTWQ2LK"), "MFRG GZDF MZTW Q2LK");
        assert_eq!(grouped_key("ABCDEF"), "ABCD EF");
        assert_eq!(grouped_key(""), "");
    }
}
