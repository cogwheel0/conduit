//! First run: the backend chooser, then one of three paths, as on mobile:
//!
//! * **Open WebUI**: the server form ([`ServerForm`]); sign-in follows.
//! * **Direct**: a connection form ([`DirectView`]); saving it prefers
//!   Direct, and the session moves the window to chat once it works.
//! * **Hermes**: the Hermes form ([`HermesView`]); once Hermes is usable
//!   the session moves on.
//! * **LibreChat** (Beta): the LibreChat sign-in ([`LibreChatSignInView`]);
//!   signed in, its account owns the chats and the window moves to chat.
//! * **Apple On-Device**, while this Mac's model answers
//!   (`Capabilities::apple_on_device_models`): one click, as the phone's
//!   `_selectAppleModel` (`apple.choose`): asked again, then Direct is
//!   preferred on it and the window moves to chat, or the reason it can't
//!   be used shows. Never Private Cloud Compute on the Mac.
//!
//! It lives in the setup window ([`crate::views::setup_window`]). Choosing
//! a path tells the daemon whether Direct is preferred
//! (`direct.setPreferred`).

use std::rc::Rc;

use conduit_components::views::kit::ClickHandler;
use conduit_components::views::model::Backend;
use conduit_components::views::onboarding::{
    AppleChoice, BACKENDS, BackendChooser, back_link, link, title_block,
};
use conduit_protocol::{
    AppleAvailability, DirectPreferred, NoParams, NoticeLevel, ReviewerMode, methods,
};
use gpui_kit::prelude::*;
use gpui_kit::{
    AnyElement, App, AsyncWindowContext, ClickEvent, Context, Entity, SharedString, Subscription,
    WeakEntity, Window, div, px,
};

use crate::l10n::ActiveL10n as _;
use crate::stores::Stores;
use crate::views::direct::DirectView;
use crate::views::direct::pane::apple_detail;
use crate::views::hermes::HermesView;
use crate::views::librechat_sign_in::{LibreChatSignInEvent, LibreChatSignInView};
use crate::views::server_form::{ServerForm, ServerFormEvent};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Step {
    Choose,
    Server,
    Direct,
    Hermes,
    LibreChat,
}

pub struct OnboardingView {
    stores: Stores,
    pub step: Step,
    pub selected: Backend,
    /// Opened from Accounts: only the server form, and Cancel leaves.
    pub adding: bool,
    pub server: Entity<ServerForm>,
    direct: Option<Entity<DirectView>>,
    hermes: Option<Entity<HermesView>>,
    pub librechat: Entity<LibreChatSignInView>,
    busy: bool,
    /// Why Apple On-Device could not be chosen last (shown as a warning
    /// toast, as the phone's snackbar).
    pub apple_error: Option<String>,
    _subscriptions: Vec<Subscription>,
}

impl OnboardingView {
    pub fn new(stores: Stores, window: &mut Window, cx: &mut Context<Self>) -> Self {
        let server = cx.new(|cx| ServerForm::new(stores.clone(), window, cx));
        let librechat = cx.new(|cx| LibreChatSignInView::new(stores.clone(), window, cx));
        let subscriptions = vec![
            // The Apple row comes and goes with this Mac's model.
            cx.observe(&stores.session, |_, _, cx| cx.notify()),
            cx.subscribe_in(
                &librechat,
                window,
                |this: &mut Self, _, event: &LibreChatSignInEvent, window, cx| match event {
                    LibreChatSignInEvent::Back => this.go(Step::Choose, window, cx),
                    // Signed in: the session routes to chat.
                    LibreChatSignInEvent::SignedIn => {
                        this.step = Step::Choose;
                        cx.notify();
                    }
                },
            ),
            cx.subscribe_in(
                &server,
                window,
                |this: &mut Self, _, event: &ServerFormEvent, window, cx| match event {
                    ServerFormEvent::Back => {
                        if this.adding {
                            this.adding = false;
                        }
                        this.go(Step::Choose, window, cx);
                    }
                    ServerFormEvent::Connected => {
                        // Sign-in is next; the session routes there.
                        this.adding = false;
                        this.step = Step::Choose;
                        cx.notify();
                    }
                    // Add Account's own; the first-run form never sends them.
                    ServerFormEvent::AddHermes | ServerFormEvent::AddDirect => {}
                },
            ),
        ];
        Self {
            stores,
            step: Step::Choose,
            selected: Backend::OpenWebUi,
            adding: false,
            server,
            direct: None,
            hermes: None,
            librechat,
            busy: false,
            apple_error: None,
            _subscriptions: subscriptions,
        }
    }

    /// Whether the chooser offers Apple On-Device: this Mac's model answers.
    pub fn offers_apple(&self, cx: &App) -> bool {
        self.stores
            .session
            .read(cx)
            .capabilities()
            .apple_on_device_models
    }

    /// The Apple On-Device row (`apple.choose`): Direct on this Mac's model,
    /// or why not.
    pub fn choose_apple(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.busy {
            return;
        }
        self.busy = true;
        self.apple_error = None;
        cx.notify();
        let call = self
            .stores
            .connection
            .read(cx)
            .rpc()
            .call::<methods::AppleChoose>(&NoParams);
        let (session, toasts) = (self.stores.session.clone(), self.stores.toasts.clone());
        cx.spawn_in(
            window,
            async move |this: WeakEntity<Self>, cx: &mut AsyncWindowContext| {
                let result = call.await;
                let _ = this.update(cx, |s, cx| {
                    s.busy = false;
                    let l10n = cx.l10n().clone();
                    let refused = match result {
                        Ok(model) if model.availability == AppleAvailability::Available => {
                            log::info!("onboarding: Apple On-Device chosen");
                            // Direct is preferred now: the session moves on.
                            session.update(cx, |s, cx| s.refresh(cx));
                            None
                        }
                        Ok(model) => {
                            log::info!("onboarding: Apple On-Device can't be used now");
                            Some((NoticeLevel::Warning, apple_detail(&model, &l10n)))
                        }
                        Err(e) => {
                            log::warn!("apple.choose: {e}");
                            Some((NoticeLevel::Error, l10n.apple_on_device_unavailable()))
                        }
                    };
                    if let Some((level, words)) = refused {
                        toasts.update(cx, |t, cx| t.show(level, words.clone(), cx));
                        s.apple_error = Some(words);
                    }
                    cx.notify();
                });
            },
        )
        .detach();
    }

    /// The Direct form, once that path was opened.
    pub fn direct_view(&self) -> Option<Entity<DirectView>> {
        self.direct.clone()
    }

    /// The Hermes form, once that path was opened.
    pub fn hermes_view(&self) -> Option<Entity<HermesView>> {
        self.hermes.clone()
    }

    /// Whether the window should keep showing this view over the route: an
    /// addition in progress, or a server being checked.
    pub fn holds(&self, cx: &App) -> bool {
        self.adding
            || self.server.read(cx).busy
            || (self.step == Step::LibreChat && self.librechat.read(cx).busy)
    }

    /// "Add account": the server form, with Cancel.
    pub fn start_adding(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.adding = true;
        self.step = Step::Server;
        self.server.update(cx, |s, cx| s.reset(true, window, cx));
        cx.notify();
    }

    pub fn go(&mut self, step: Step, window: &mut Window, cx: &mut Context<Self>) {
        self.step = step;
        match step {
            Step::Server => {
                let adding = self.adding;
                self.server.update(cx, |s, cx| {
                    if !s.busy {
                        s.reset(adding, window, cx)
                    }
                });
            }
            Step::Direct if self.direct.is_none() => {
                let stores = self.stores.clone();
                self.direct = Some(cx.new(|cx| DirectView::new(stores, true, window, cx)));
            }
            Step::Hermes if self.hermes.is_none() => {
                let stores = self.stores.clone();
                self.hermes = Some(cx.new(|cx| HermesView::new(stores, true, window, cx)));
            }
            Step::LibreChat => {
                self.librechat.update(cx, |l, cx| {
                    if !l.busy {
                        l.reset(window, cx)
                    }
                });
                let field = self.librechat.read(cx).first_field();
                window.on_next_frame(move |window, cx| {
                    let handle = gpui_kit::Focusable::focus_handle(field.read(cx), cx);
                    window.focus(&handle, cx);
                });
            }
            _ => {}
        }
        cx.notify();
    }

    /// Continue from the chooser.
    pub fn choose(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let step = match self.selected {
            Backend::OpenWebUi => Step::Server,
            Backend::Direct => Step::Direct,
            Backend::Hermes => Step::Hermes,
            Backend::LibreChat => Step::LibreChat,
        };
        // Remembered, so a working Direct connection skips server setup.
        let preferred = step == Step::Direct;
        let call = self
            .stores
            .connection
            .read(cx)
            .rpc()
            .call::<methods::DirectSetPreferred>(&DirectPreferred { preferred });
        cx.background_spawn(async move {
            if let Err(e) = call.await {
                log::debug!("direct.setPreferred: {e}");
            }
        })
        .detach();
        self.go(step, window, cx);
    }

    /// "Skip server setup and try the demo": the reviewer session.
    pub fn try_demo(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.busy {
            return;
        }
        self.busy = true;
        let call = self
            .stores
            .connection
            .read(cx)
            .rpc()
            .call::<methods::AuthSetReviewerMode>(&ReviewerMode { enabled: true });
        let session = self.stores.session.clone();
        cx.spawn_in(
            window,
            async move |this: WeakEntity<Self>, cx: &mut AsyncWindowContext| {
                let result = call.await;
                let _ = this.update(cx, |s, cx| {
                    s.busy = false;
                    cx.notify();
                });
                match result {
                    Ok(snapshot) => {
                        session.update(cx, |s, cx| s.adopt_auth(snapshot, cx));
                    }
                    Err(e) => log::warn!("auth.setReviewerMode: {e}"),
                }
            },
        )
        .detach();
    }

    fn back(&self, cx: &mut Context<Self>) -> ClickHandler {
        let this = cx.entity().downgrade();
        Rc::new(move |_: &ClickEvent, window: &mut Window, cx: &mut App| {
            let _ = this.update(cx, |s, cx| s.go(Step::Choose, window, cx));
        })
    }

    fn panel(
        &self,
        title: String,
        subtitle: String,
        body: AnyElement,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let l10n = cx.l10n().clone();
        div()
            .flex()
            .flex_col()
            .gap(px(18.))
            .child(back_link(l10n.back().into(), Some(self.back(cx)), cx))
            .child(title_block(&title, &subtitle, false, cx))
            .child(body)
            .into_any_element()
    }
}

impl Render for OnboardingView {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let l10n = cx.l10n().clone();
        let this = cx.entity().downgrade();
        let content: AnyElement = match self.step {
            Step::Choose => {
                let select = {
                    let this = this.clone();
                    Rc::new(move |i: usize, _: &mut Window, cx: &mut App| {
                        let _ = this.update(cx, |s, cx| {
                            s.selected = BACKENDS[i];
                            cx.notify();
                        });
                    })
                };
                let next = {
                    let this = this.clone();
                    Rc::new(move |_: &ClickEvent, window: &mut Window, cx: &mut App| {
                        let _ = this.update(cx, |s, cx| s.choose(window, cx));
                    })
                };
                let demo = {
                    let this = this.clone();
                    Rc::new(move |_: &ClickEvent, window: &mut Window, cx: &mut App| {
                        let _ = this.update(cx, |s, cx| s.try_demo(window, cx));
                    })
                };
                let apple = self.offers_apple(cx).then(|| {
                    let this = this.clone();
                    AppleChoice {
                        section: l10n.backend_chooser_apple_section_title().into(),
                        title: l10n.backend_chooser_apple_on_device_title().into(),
                        detail: l10n.desktop_backend_apple_on_device_subtitle().into(),
                        on_click: Rc::new(
                            move |_: &ClickEvent, window: &mut Window, cx: &mut App| {
                                let _ = this.update(cx, |s, cx| s.choose_apple(window, cx));
                            },
                        ),
                    }
                });
                div()
                    .flex()
                    .flex_col()
                    .gap(px(16.))
                    .child(
                        BackendChooser::new(self.selected)
                            .on_select(select)
                            .on_continue(next)
                            .apple(apple)
                            .busy(self.busy),
                    )
                    .child(div().flex().justify_center().child(link(
                        "try-demo",
                        SharedString::from(l10n.desktop_try_demo()),
                        Some(demo),
                        cx,
                    )))
                    .into_any_element()
            }
            Step::Server => self.server.clone().into_any_element(),
            Step::Direct => match self.direct.clone() {
                Some(direct) => self.panel(
                    l10n.desktop_connect_directly(),
                    l10n.backend_chooser_direct_subtitle(),
                    direct.into_any_element(),
                    cx,
                ),
                None => div().into_any_element(),
            },
            Step::LibreChat => self.librechat.clone().into_any_element(),
            Step::Hermes => match self.hermes.clone() {
                Some(hermes) => self.panel(
                    l10n.desktop_hermes_agent(),
                    l10n.desktop_hermes_subtitle(),
                    hermes.into_any_element(),
                    cx,
                ),
                None => div().into_any_element(),
            },
        };
        // The setup window frames it (`views::setup_window`).
        div().id("onboarding").w_full().child(content)
    }
}
