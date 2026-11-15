//! First run: the backend chooser, then one of three paths, as on mobile:
//!
//! * **Open WebUI**: the server form ([`ServerForm`]); sign-in follows.
//! * **Direct**: a connection form ([`DirectView`]); saving it prefers
//!   Direct, and the session moves the window to chat once it works.
//! * **Hermes**: the Hermes form ([`HermesView`]); once Hermes is usable
//!   the session moves on.
//!
//! It lives in the setup window ([`crate::views::setup_window`]). Choosing
//! a path tells the daemon whether Direct is preferred
//! (`direct.setPreferred`).

use std::rc::Rc;

use conduit_components::views::kit::ClickHandler;
use conduit_components::views::model::Backend;
use conduit_components::views::onboarding::{
    BACKENDS, BackendChooser, back_link, link, title_block,
};
use conduit_protocol::{DirectPreferred, ReviewerMode, methods};
use gpui_kit::prelude::*;
use gpui_kit::{
    AnyElement, App, AsyncWindowContext, ClickEvent, Context, Entity, SharedString, Subscription,
    WeakEntity, Window, div, px,
};

use crate::l10n::ActiveL10n as _;
use crate::stores::Stores;
use crate::views::direct::DirectView;
use crate::views::hermes::HermesView;
use crate::views::server_form::{ServerForm, ServerFormEvent};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Step {
    Choose,
    Server,
    Direct,
    Hermes,
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
    busy: bool,
    _subscriptions: Vec<Subscription>,
}

impl OnboardingView {
    pub fn new(stores: Stores, window: &mut Window, cx: &mut Context<Self>) -> Self {
        let server = cx.new(|cx| ServerForm::new(stores.clone(), window, cx));
        let subscriptions = vec![cx.subscribe_in(
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
            },
        )];
        Self {
            stores,
            step: Step::Choose,
            selected: Backend::OpenWebUi,
            adding: false,
            server,
            direct: None,
            hermes: None,
            busy: false,
            _subscriptions: subscriptions,
        }
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
        self.adding || self.server.read(cx).busy
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
                div()
                    .flex()
                    .flex_col()
                    .gap(px(16.))
                    .child(
                        BackendChooser::new(self.selected)
                            .on_select(select)
                            .on_continue(next)
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
