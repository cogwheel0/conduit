//! The setup window's root ([`crate::windows`]): a compact window for
//! everything before a session, 640 pt wide and as tall as its chooser.
//!
//! * While the daemon starts (or when it fails), its status card.
//! * [`Route::Onboarding`]: the backend chooser and its three paths.
//! * [`Route::SignIn`]: sign-in for the active account (first run, an
//!   account added from Settings, or a session that expired), with its
//!   second step when the server asks for one.
//! * [`Route::ConnectionIssue`]: the account kept its session but the
//!   server turns it away (an expired sign-in proxy): renew or retry it.
//!
//! The content sits in one 460 pt column, its top at a fixed place, and
//! scrolls, with a scroll bar, when it doesn't fit (the server form with
//! Advanced Settings open). The window takes the chooser's height (with
//! Apple On-Device when this Mac offers it), up to the display's visible
//! height: it opens hidden and shows itself at that height, so Try the
//! Demo is never below its bottom edge. The window is titled for its page:
//! "Set Up Conduit" or "Sign In". A `ui.request` card, toasts and the
//! reconnecting banner show over it as they do over the main window.

use std::cell::Cell;
use std::rc::Rc;
use std::time::Duration;

use conduit_components::ActiveConduitTheme as _;
use conduit_components::theme::UI_FONT;
use conduit_components::views::kit::grouped_tones;
use gpui_kit::base::{Scrollbar, ScrollbarMode};
use gpui_kit::prelude::*;
use gpui_kit::{
    AnyElement, App, AsyncWindowContext, Bounds, Context, Div, Entity, FocusHandle, Focusable,
    Pixels, Role, ScrollHandle, SharedString, Subscription, Task, WeakEntity, Window, div, px,
};

use crate::actions::{AllowRequest, DenyRequest};
use crate::l10n::ActiveL10n as _;
use crate::stores::Stores;
use crate::stores::connection::Status;
use crate::stores::session::Route;
use crate::views::add_account::needs_fit;
use crate::views::approvals::ApprovalsView;
use crate::views::connection_issue::ConnectionIssueView;
use crate::views::librechat_sign_in::LibreChatSignInView;
use crate::views::onboarding::{OnboardingView, Step};
use crate::views::sign_in::SignInView;
use crate::views::status::{reconnect_banner, status_screen};
use crate::views::toasts::toast_overlay;

/// The content column's width.
pub const COLUMN: f32 = 460.;
/// Room for the title bar (the traffic lights), which AppKit draws and
/// drags over the content.
pub const TITLE_BAR: f32 = 28.;

/// Where every step's column starts under the title bar's room: Back (or
/// the chooser's mark) sits here on every step.
pub const SETUP_TOP: f32 = 24.;

/// How long the window may stay hidden waiting for its chooser: a daemon
/// slow to answer shows its status card by then.
const REVEAL_AFTER: Duration = Duration::from_millis(1500);

/// The window's height, which follows the chooser's content.
#[derive(Default)]
struct Fit {
    /// The height last asked of the window, so a request never repeats
    /// while AppKit resizes it.
    requested: Cell<Option<f32>>,
    /// The chooser's height the window was given.
    applied: Cell<Option<f32>>,
    /// The display's visible area the window was last fitted to.
    area: Cell<Option<crate::shell::placement::Rect>>,
    shown: Cell<bool>,
    /// The page drawn last, and whether it was the chooser.
    page: Cell<Option<(Page, bool)>>,
    /// Starts again with every page drawn after another.
    generation: Cell<u64>,
}

impl Fit {
    /// A page drawn after another starts a new generation, and a height
    /// asked for the one before no longer stands: a chooser that comes
    /// back asks for its own.
    fn on_page(&self, page: Page, chooser: bool) {
        if self.page.replace(Some((page, chooser))) != Some((page, chooser)) {
            self.generation.set(self.generation.get() + 1);
            self.requested.set(None);
        }
    }
}

/// What the window shows.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Page {
    Status,
    Onboarding,
    SignIn,
    /// The LibreChat account in charge needs a sign-in (its session ended).
    LibreChatSignIn,
    /// The account's session is kept but turned away.
    ConnectionIssue,
}

/// The page for a route and status (`holding`: a server is being checked,
/// so the form stays whatever the route says meanwhile; `issue_held`: the
/// connection issue is being tried again, and the session reads as loading
/// meanwhile, so the issue stays).
pub fn page_for(route: Route, blocked: bool, holding: bool, issue_held: bool) -> Page {
    if blocked {
        Page::Status
    } else if holding || route == Route::Onboarding {
        Page::Onboarding
    } else if route == Route::SignIn {
        Page::SignIn
    } else if route == Route::ConnectionIssue || (issue_held && route == Route::Unknown) {
        Page::ConnectionIssue
    } else {
        Page::Status
    }
}

pub struct SetupWindow {
    pub stores: Stores,
    pub onboarding: Entity<OnboardingView>,
    pub sign_in: Entity<SignInView>,
    pub connection_issue: Entity<ConnectionIssueView>,
    /// Signing in again to the LibreChat account in charge.
    pub librechat: Entity<LibreChatSignInView>,
    /// The LibreChat account `librechat` was started for.
    librechat_for: Option<String>,
    pub approvals: Entity<ApprovalsView>,
    focus: FocusHandle,
    /// The page drawn last.
    page: Option<Page>,
    fit: Rc<Fit>,
    scroll: ScrollHandle,
    _reveal: Task<()>,
    _subscriptions: Vec<Subscription>,
}

impl SetupWindow {
    pub fn new(stores: Stores, window: &mut Window, cx: &mut Context<Self>) -> Self {
        let onboarding = cx.new(|cx| OnboardingView::new(stores.clone(), window, cx));
        let sign_in = cx.new(|cx| SignInView::new(stores.clone(), window, cx));
        let connection_issue = cx.new(|cx| ConnectionIssueView::new(stores.clone(), window, cx));
        let librechat = cx.new(|cx| {
            let mut view = LibreChatSignInView::new(stores.clone(), window, cx);
            view.sheet = false;
            view
        });
        let approvals = cx.new(|cx| ApprovalsView::new(stores.clone(), window, cx));
        let subscriptions = vec![
            // What decides the page: laid out at once while hidden.
            cx.observe_in(&stores.connection, window, |s, _, window, cx| {
                s.changed(window, cx)
            }),
            cx.observe_in(&stores.session, window, |s, _, window, cx| {
                s.changed(window, cx)
            }),
            cx.observe_in(&stores.accounts, window, |s, _, window, cx| {
                s.changed(window, cx)
            }),
            cx.observe(&stores.toasts, |_, _, cx| cx.notify()),
            cx.observe_in(&onboarding, window, |s, _, window, cx| {
                s.changed(window, cx)
            }),
            cx.observe(&connection_issue, |_, _, cx| cx.notify()),
            cx.observe(&librechat, |_, _, cx| cx.notify()),
            cx.observe(&approvals, |_, _, cx| cx.notify()),
            // Moved to another display, or its display changed: fitted
            // to the one it is on.
            cx.observe_window_bounds(window, |s, window, cx| s.refit(window, cx)),
            {
                let (handle, this) = (window.window_handle(), cx.entity().downgrade());
                cx.observe_displays(move |_, cx| {
                    let _ = handle.update(cx, |_, window, cx| {
                        let _ = this.update(cx, |s, cx| s.refit(window, cx));
                    });
                })
            },
            // Keyboard Navigation may have been switched in System Settings.
            cx.observe_window_activation(window, |_, window, cx| {
                if window.is_window_active() {
                    crate::sync_keyboard_access(cx);
                }
            }),
        ];
        let focus = cx.focus_handle();
        window.focus(&focus, cx);
        lay_out(window, cx);
        let reveal_later = cx.spawn_in(
            window,
            async move |this: WeakEntity<Self>, cx: &mut AsyncWindowContext| {
                cx.background_executor().timer(REVEAL_AFTER).await;
                let _ = this.update_in(cx, |s, window, cx| {
                    if reveal(&s.fit, window) {
                        s.refit(window, cx);
                    }
                });
            },
        );
        Self {
            stores,
            onboarding,
            sign_in,
            connection_issue,
            librechat,
            librechat_for: None,
            approvals,
            focus,
            page: None,
            fit: Rc::default(),
            scroll: ScrollHandle::new(),
            _reveal: reveal_later,
            _subscriptions: subscriptions,
        }
    }

    /// Whether the window is on screen: it shows itself once it is sized.
    pub fn shown(&self) -> bool {
        self.fit.shown.get()
    }

    /// Fits the window on screen again (its chooser's height, else the
    /// height it opened at) once the display's visible area it is on is
    /// another than the one it was fitted to, after this callback: AppKit
    /// calls back into GPUI on a resize.
    fn refit(&self, window: &Window, cx: &mut App) {
        if !self.fit.shown.get() {
            return;
        }
        #[cfg(target_os = "macos")]
        if let Some(ns) = crate::shell::macos::ns_window(window) {
            let fit = self.fit.clone();
            let height = fit
                .applied
                .get()
                .unwrap_or(crate::windows::SETUP_FIRST_HEIGHT);
            cx.spawn(async move |_: &mut gpui_kit::AsyncApp| {
                let area =
                    crate::shell::macos::refit_setup_window(&ns, f64::from(height), fit.area.get());
                fit.area.set(area);
            })
            .detach();
        }
        #[cfg(not(target_os = "macos"))]
        let _ = (window, cx, self.fit.applied.get(), self.fit.area.get());
    }

    fn changed(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        cx.notify();
        if !self.fit.shown.get() {
            lay_out(window, cx);
        }
    }

    /// The route, as the window shows it.
    pub fn route(&self, cx: &App) -> Route {
        self.stores.session.read(cx).route(cx)
    }

    /// The page the window shows now.
    pub fn page(&self, cx: &App) -> Page {
        let (_, blocked) = self.status(cx);
        // A try at the issue reads as loading until it settles; so does a
        // check that never settles behind a proxy still turning it away.
        let issue_held = self.connection_issue.read(cx).holds()
            || (self.page == Some(Page::ConnectionIssue)
                && self
                    .stores
                    .session
                    .read(cx)
                    .auth
                    .as_ref()
                    .is_some_and(|a| a.has_token && !a.is_authenticated));
        let page = page_for(
            self.route(cx),
            blocked,
            self.onboarding.read(cx).holds(cx),
            issue_held,
        );
        if page == Page::SignIn
            && self
                .stores
                .accounts
                .read(cx)
                .libre_chat_needs_sign_in()
                .is_some()
        {
            return Page::LibreChatSignIn;
        }
        page
    }

    fn status(&self, cx: &App) -> (Status, bool) {
        let route = self.route(cx);
        let error = self
            .stores
            .session
            .read(cx)
            .error
            .as_ref()
            .map(|e| e.to_string());
        let status = self
            .stores
            .connection
            .read(cx)
            .status(route != Route::Unknown, error.as_deref());
        let blocked = status.blocks(route != Route::Unknown);
        (status, blocked)
    }
}

/// The window's frame: room for the title bar, then the column, its top
/// at a fixed place under the title bar (as Setup Assistant's panes keep
/// their header still), so Back and the title stay put from step to step
/// whatever each step holds; it scrolls when taller than the window.
/// `probe` measures the column, paddings included.
fn setup_frame(
    content: AnyElement,
    label: SharedString,
    probe: Option<AnyElement>,
    scroll: &ScrollHandle,
    cx: &App,
) -> Div {
    let t = cx.conduit();
    // The phone's grouped page, so the forms' groups read as lifted.
    let (page, _) = grouped_tones(t);
    div()
        .size_full()
        .flex()
        .flex_col()
        .font_family(UI_FONT)
        .bg(page)
        .text_color(t.roles.text)
        .child(div().h(px(TITLE_BAR)).flex_none())
        .child(
            div()
                .relative()
                .flex_1()
                .min_h_0()
                .child(
                    div()
                        .id("setup-scroll")
                        .role(Role::Main)
                        .aria_label(label)
                        .size_full()
                        .overflow_y_scroll()
                        .track_scroll(scroll)
                        .child(
                            div()
                                .relative()
                                .w_full()
                                .flex()
                                .flex_col()
                                .items_center()
                                .pt(px(SETUP_TOP))
                                // As much room under the column as above it.
                                .pb(px(TITLE_BAR + SETUP_TOP))
                                .child(div().w(px(COLUMN)).child(content))
                                .children(probe),
                        ),
                )
                // Drawn only while the column is taller than the window.
                .child(
                    div().absolute().inset_0().child(
                        Scrollbar::vertical(scroll)
                            .mode(ScrollbarMode::Always)
                            .viewport_from_layout(),
                    ),
                ),
        )
}

/// Puts the window on screen, once: whether it did now.
fn reveal(fit: &Fit, window: &mut Window) -> bool {
    let now = !fit.shown.replace(true);
    if now {
        window.activate_window();
    }
    now
}

/// A hidden window draws no frames (AppKit stops its display link): lay it
/// out anyway, after this update, so its page is known and the chooser's
/// probe measures it before the window shows.
fn lay_out(window: &Window, cx: &mut App) {
    window.defer(cx, |window, cx| window.draw(cx).clear(cx));
}

/// Makes the window `height` points tall (at most what its display has
/// room for), after this frame: AppKit calls back into GPUI on a resize.
/// On screen, the change animates; a hidden window shows itself once it is
/// that tall, so it never changes size as it appears.
fn resize(height: f32, fit: Rc<Fit>, window: &Window, cx: &mut App) {
    let handle = window.window_handle();
    let shown = fit.shown.get();
    let generation = fit.generation.get();
    #[cfg(target_os = "macos")]
    let ns = crate::shell::macos::ns_window(window);
    #[cfg(target_os = "macos")]
    let animate = shown && !cx.reduce_motion();
    cx.spawn(async move |cx: &mut gpui_kit::AsyncApp| {
        // Another page was drawn since the chooser was measured: it keeps
        // its height.
        if fit.generation.get() != generation {
            return;
        }
        fit.applied.set(Some(height));
        #[cfg(target_os = "macos")]
        if let Some(ns) = ns {
            let area =
                crate::shell::macos::fit_setup_window(&ns, f64::from(height), shown, animate);
            fit.area.set(area);
        }
        if !shown {
            let _ = handle.update(cx, |_, window, _| reveal(&fit, window));
        }
    })
    .detach();
}

/// Measures the chooser's column and makes the window as tall: the title
/// bar's room and the column.
fn chooser_probe(fit: Rc<Fit>) -> AnyElement {
    gpui_kit::canvas(
        |bounds: Bounds<Pixels>, _, _| f32::from(bounds.size.height),
        move |_, column, window, cx| {
            // Whole points, as AppKit sizes it: a fraction short would scroll.
            let height = (TITLE_BAR + column).ceil();
            if needs_fit(fit.requested.get(), height) {
                fit.requested.set(Some(height));
                resize(height, fit.clone(), window, cx);
            }
        },
    )
    .absolute()
    .top_0()
    .left_0()
    .size_full()
    .into_any_element()
}

impl Focusable for SetupWindow {
    fn focus_handle(&self, _: &App) -> FocusHandle {
        self.focus.clone()
    }
}

impl Render for SetupWindow {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let l10n = cx.l10n().clone();
        let (status, blocked) = self.status(cx);
        let page = self.page(cx);
        let label: SharedString = match page {
            Page::SignIn | Page::LibreChatSignIn => l10n.desktop_sign_in().into(),
            Page::ConnectionIssue => l10n.connection_issue_title().into(),
            _ => l10n.desktop_set_up_conduit().into(),
        };
        let chooser = page == Page::Onboarding && self.onboarding.read(cx).step == Step::Choose;
        self.fit.on_page(page, chooser);
        // The chooser shows once the window is as tall (its probe); the
        // daemon's status card once it fails, or the wait is over; every
        // other page as it is.
        let starting = page == Page::Status
            && !matches!(
                status,
                Status::Failed { .. } | Status::StoreUnreadable | Status::VersionMismatch { .. }
            );
        if !chooser && !starting && reveal(&self.fit, window) {
            self.refit(window, cx);
        }
        let probe = chooser.then(|| chooser_probe(self.fit.clone()));
        let frame = |content: AnyElement, cx: &App| {
            setup_frame(content, label.clone(), None, &self.scroll, cx).into_any_element()
        };
        let content = match page {
            Page::Status => status_screen(&status, &self.stores.connection, cx).into_any_element(),
            Page::Onboarding => setup_frame(
                self.onboarding.clone().into_any_element(),
                label.clone(),
                probe,
                &self.scroll,
                cx,
            )
            .into_any_element(),
            Page::SignIn => frame(self.sign_in.clone().into_any_element(), cx),
            Page::LibreChatSignIn => frame(self.librechat.clone().into_any_element(), cx),
            Page::ConnectionIssue => frame(self.connection_issue.clone().into_any_element(), cx),
        };
        // The LibreChat account whose session ended: its server's sign-in,
        // saying so, started once per account.
        if page == Page::LibreChatSignIn {
            let ended = self
                .stores
                .accounts
                .read(cx)
                .libre_chat_needs_sign_in()
                .map(|a| (a.id.clone(), a.base_url.clone(), a.title.clone()));
            if let Some((id, base_url, title)) = ended
                && self.librechat_for.as_deref() != Some(id.as_str())
            {
                self.librechat_for = Some(id);
                let title = crate::views::privacy::host(&title, cx);
                self.librechat
                    .update(cx, |l, cx| l.start_at(&base_url, Some(title), window, cx));
            }
        } else {
            self.librechat_for = None;
        }
        if self.page != Some(page) && page == Page::ConnectionIssue {
            self.connection_issue.update(cx, |v, cx| v.reset(cx));
        }
        if self.page != Some(page) {
            // Titled for what it holds (the Window menu, Mission Control).
            window.set_window_title(&label);
            // Focus leaves the page that went (as AppKit's first responder
            // does when a window's content is swapped); sign-in starts in
            // its first field, as Mail's account sheet does.
            let root = self.focus.clone();
            // The field the method shows first: the token alone for a
            // Token, else the email.
            let first = (page == Page::SignIn).then(|| {
                let s = self.sign_in.read(cx);
                if s.method == crate::views::sign_in::Method::Token {
                    s.token.clone()
                } else {
                    s.email.clone()
                }
            });
            window.on_next_frame(move |window, cx| {
                if let Some(field) = first {
                    let handle = gpui_kit::Focusable::focus_handle(field.read(cx), cx);
                    window.focus(&handle, cx);
                } else if !root.contains_focused(window, cx) {
                    window.focus(&root, cx);
                }
            });
        }
        self.page = Some(page);
        if window.focused(cx).is_none() {
            window.focus(&self.focus, cx);
        }
        let banner = match status {
            Status::Reconnecting { .. } if !blocked => Some(reconnect_banner(
                l10n.desktop_core_reconnecting().into(),
                cx,
            )),
            _ => None,
        };
        let approvals = (!blocked && self.approvals.read(cx).has_request(cx)).then(|| {
            div()
                .absolute()
                .bottom(px(20.))
                .left_0()
                .right_0()
                .flex()
                .justify_center()
                .px(px(20.))
                .child(self.approvals.clone())
        });
        let toasts = toast_overlay(&self.stores.toasts, window, cx);
        // A click on no control focuses the window itself: named, so
        // VoiceOver says where focus went rather than the whole window.
        div()
            .id("setup-window")
            .role(Role::Group)
            .aria_label(label)
            .key_context("ConduitSetupWindow")
            .track_focus(&self.focus)
            .on_action(cx.listener(|this, _: &AllowRequest, _, cx| {
                this.approvals.update(cx, |a, cx| a.allow(cx));
            }))
            .on_action(cx.listener(|this, _: &DenyRequest, _, cx| {
                this.approvals.update(cx, |a, cx| a.deny(cx));
            }))
            .relative()
            .size_full()
            .child(content)
            .children(approvals)
            .children(toasts)
            .children(banner)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_page_follows_the_route() {
        assert_eq!(
            page_for(Route::Onboarding, false, false, false),
            Page::Onboarding
        );
        assert_eq!(page_for(Route::SignIn, false, false, false), Page::SignIn);
        assert_eq!(
            page_for(Route::ConnectionIssue, false, false, false),
            Page::ConnectionIssue
        );
        // Before the daemon answers, and once there is a session (the main
        // window is about to take over), the status card.
        assert_eq!(page_for(Route::Unknown, false, false, false), Page::Status);
        assert_eq!(page_for(Route::Main, false, false, false), Page::Status);
        // A server being checked keeps its form, whatever the route says.
        assert_eq!(
            page_for(Route::SignIn, false, true, false),
            Page::Onboarding
        );
        // The issue tried again keeps its page while the session loads, and
        // gives way once it is signed in.
        assert_eq!(
            page_for(Route::Unknown, false, false, true),
            Page::ConnectionIssue
        );
        assert_eq!(page_for(Route::Main, false, false, true), Page::Status);
        // A daemon that failed shows why, over anything.
        assert_eq!(
            page_for(Route::Onboarding, true, false, false),
            Page::Status
        );
    }
}

#[cfg(test)]
mod fit_tests {
    use conduit_protocol::{Capabilities, methods};
    use gpui_kit::{TestAppContext, VisualTestContext};

    use super::*;
    use crate::stores::rpc::fake::FakeDaemon;
    use crate::stores::session::SessionStore;

    /// The chooser in the window's frame, measured as the window measures
    /// it, or (`chooser` off) another page in its place.
    struct Chooser {
        onboarding: Entity<OnboardingView>,
        fit: Rc<Fit>,
        scroll: ScrollHandle,
        chooser: bool,
    }

    impl Render for Chooser {
        fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
            self.fit.on_page(Page::Onboarding, self.chooser);
            let (content, probe) = if self.chooser {
                (
                    self.onboarding.clone().into_any_element(),
                    Some(chooser_probe(self.fit.clone())),
                )
            } else {
                (div().h(px(200.)).into_any_element(), None)
            };
            setup_frame(content, "Set Up Conduit".into(), probe, &self.scroll, cx)
        }
    }

    fn bench(
        chooser: bool,
        cx: &mut TestAppContext,
    ) -> (
        FakeDaemon,
        Entity<SessionStore>,
        Rc<Fit>,
        gpui_kit::Entity<Chooser>,
        &mut VisualTestContext,
    ) {
        let daemon = FakeDaemon::new();
        daemon.returns::<methods::SystemCapabilities>(Capabilities::default());
        let scratch =
            std::env::temp_dir().join(format!("conduit-setup-fit-{}", std::process::id()));
        let stores = cx.update(|cx| {
            crate::views::test_globals(cx);
            Stores::for_test(daemon.rpc(), &scratch, cx)
        });
        let session = stores.session.clone();
        session.update(cx, |s, cx| s.refresh_capabilities(cx));
        cx.run_until_parked();
        let fit: Rc<Fit> = Rc::default();
        let shared = fit.clone();
        let (view, vcx) = cx.add_window_view(move |window, cx| Chooser {
            onboarding: cx.new(|cx| OnboardingView::new(stores, window, cx)),
            fit: shared,
            scroll: ScrollHandle::new(),
            chooser,
        });
        (daemon, session, fit, view, vcx)
    }

    fn draw(vcx: &mut VisualTestContext) {
        vcx.update(|window, cx| window.draw(cx).clear(cx));
    }

    /// The chooser measured, then another page drawn before the resize it
    /// asked for runs: that page keeps its own height, and a chooser that
    /// comes back meanwhile still gets its own.
    #[gpui_kit::test]
    fn a_page_drawn_before_the_choosers_resize_keeps_its_height(cx: &mut TestAppContext) {
        let (_daemon, _session, fit, view, vcx) = bench(false, cx);
        let show = |chooser: bool, vcx: &mut VisualTestContext| {
            view.update(vcx, |b, cx| {
                b.chooser = chooser;
                cx.notify();
            });
            draw(vcx);
        };
        // Measured; its resize waits for the next turn of the event loop.
        show(true, vcx);
        assert!(fit.requested.get().is_some(), "the chooser was measured");
        show(false, vcx);
        vcx.run_until_parked();
        assert_eq!(fit.applied.get(), None);
        // Back on the chooser, then away and back again before that resize
        // runs: the chooser still ends at its own height.
        show(true, vcx);
        let measured = fit.requested.get();
        show(false, vcx);
        show(true, vcx);
        vcx.run_until_parked();
        assert!(measured.is_some());
        assert_eq!(fit.applied.get(), measured);
    }

    /// The window asks for the chooser's height, and for the Apple
    /// Intelligence section's too once this Mac offers Apple On-Device.
    #[gpui_kit::test]
    fn the_window_is_as_tall_as_its_chooser_apple_section_included(cx: &mut TestAppContext) {
        let (daemon, session, fit, _view, vcx) = bench(true, cx);
        draw(vcx);
        vcx.run_until_parked();
        let plain = fit.requested.get().expect("the chooser was measured");

        daemon.returns::<methods::SystemCapabilities>(Capabilities {
            apple_on_device_models: true,
            ..Default::default()
        });
        session.update(vcx, |s, cx| s.refresh_capabilities(cx));
        vcx.run_until_parked();
        draw(vcx);
        vcx.run_until_parked();
        let apple = fit.requested.get().expect("measured again");
        // Its section title and its row.
        assert!(apple > plain + 60., "{plain} → {apple}");
    }
}
