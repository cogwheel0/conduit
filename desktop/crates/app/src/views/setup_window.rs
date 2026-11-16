//! The setup window's root ([`crate::windows`]): a compact, fixed-size
//! window for everything before a session.
//!
//! * While the daemon starts (or when it fails), its status card.
//! * [`Route::Onboarding`]: the backend chooser and its three paths.
//! * [`Route::SignIn`]: sign-in for the active account (first run, an
//!   account added from Settings, or a session that expired).
//!
//! The content sits in one 460 pt column, centred a little above the
//! middle when it fits and scrolling when it doesn't (the server form with
//! Advanced Settings open). The window is titled for its page: "Set Up
//! Conduit" or "Sign In". A `ui.request` card, toasts and the reconnecting
//! banner show over it as they do over the main window.

use conduit_components::ActiveConduitTheme as _;
use conduit_components::theme::UI_FONT;
use conduit_components::views::kit::grouped_tones;
use gpui_kit::prelude::*;
use gpui_kit::{
    AnyElement, App, Context, Div, Entity, FocusHandle, Focusable, Role, SharedString,
    Subscription, Window, div, px,
};

use crate::actions::{AllowRequest, DenyRequest};
use crate::l10n::ActiveL10n as _;
use crate::stores::Stores;
use crate::stores::connection::Status;
use crate::stores::session::Route;
use crate::views::approvals::ApprovalsView;
use crate::views::librechat_sign_in::LibreChatSignInView;
use crate::views::onboarding::OnboardingView;
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

/// What the window shows.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Page {
    Status,
    Onboarding,
    SignIn,
    /// The LibreChat account in charge needs a sign-in (its session ended).
    LibreChatSignIn,
}

/// The page for a route and status (`holding`: a server is being checked,
/// so the form stays whatever the route says meanwhile).
pub fn page_for(route: Route, blocked: bool, holding: bool) -> Page {
    if blocked {
        Page::Status
    } else if holding || route == Route::Onboarding {
        Page::Onboarding
    } else if route == Route::SignIn {
        Page::SignIn
    } else {
        Page::Status
    }
}

pub struct SetupWindow {
    pub stores: Stores,
    pub onboarding: Entity<OnboardingView>,
    pub sign_in: Entity<SignInView>,
    /// Signing in again to the LibreChat account in charge.
    pub librechat: Entity<LibreChatSignInView>,
    /// The LibreChat account `librechat` was started for.
    librechat_for: Option<String>,
    pub approvals: Entity<ApprovalsView>,
    focus: FocusHandle,
    /// The page drawn last.
    page: Option<Page>,
    _subscriptions: Vec<Subscription>,
}

impl SetupWindow {
    pub fn new(stores: Stores, window: &mut Window, cx: &mut Context<Self>) -> Self {
        let onboarding = cx.new(|cx| OnboardingView::new(stores.clone(), window, cx));
        let sign_in = cx.new(|cx| SignInView::new(stores.clone(), window, cx));
        let librechat = cx.new(|cx| {
            let mut view = LibreChatSignInView::new(stores.clone(), window, cx);
            view.sheet = false;
            view
        });
        let approvals = cx.new(|cx| ApprovalsView::new(stores.clone(), window, cx));
        let subscriptions = vec![
            cx.observe(&stores.connection, |_, _, cx| cx.notify()),
            cx.observe(&stores.session, |_, _, cx| cx.notify()),
            cx.observe(&stores.accounts, |_, _, cx| cx.notify()),
            cx.observe(&stores.toasts, |_, _, cx| cx.notify()),
            cx.observe(&onboarding, |_, _, cx| cx.notify()),
            cx.observe(&librechat, |_, _, cx| cx.notify()),
            cx.observe(&approvals, |_, _, cx| cx.notify()),
            // Keyboard Navigation may have been switched in System Settings.
            cx.observe_window_activation(window, |_, window, cx| {
                if window.is_window_active() {
                    crate::sync_keyboard_access(cx);
                }
            }),
        ];
        let focus = cx.focus_handle();
        window.focus(&focus, cx);
        Self {
            stores,
            onboarding,
            sign_in,
            librechat,
            librechat_for: None,
            approvals,
            focus,
            page: None,
            _subscriptions: subscriptions,
        }
    }

    /// The route, as the window shows it.
    pub fn route(&self, cx: &App) -> Route {
        self.stores.session.read(cx).route(cx)
    }

    /// The page the window shows now.
    pub fn page(&self, cx: &App) -> Page {
        let (_, blocked) = self.status(cx);
        let page = page_for(self.route(cx), blocked, self.onboarding.read(cx).holds(cx));
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
fn setup_frame(content: AnyElement, label: SharedString, cx: &App) -> Div {
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
                .id("setup-scroll")
                .role(Role::Main)
                .aria_label(label)
                .flex_1()
                .min_h_0()
                .overflow_y_scroll()
                .child(
                    div()
                        .w_full()
                        .flex()
                        .flex_col()
                        .items_center()
                        .pt(px(SETUP_TOP))
                        .pb(px(40.))
                        .child(div().w(px(COLUMN)).child(content)),
                ),
        )
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
            _ => l10n.desktop_set_up_conduit().into(),
        };
        let content = match page {
            Page::Status => status_screen(&status, &self.stores.connection, cx).into_any_element(),
            Page::Onboarding => setup_frame(
                self.onboarding.clone().into_any_element(),
                label.clone(),
                cx,
            )
            .into_any_element(),
            Page::SignIn => setup_frame(self.sign_in.clone().into_any_element(), label.clone(), cx)
                .into_any_element(),
            Page::LibreChatSignIn => {
                setup_frame(self.librechat.clone().into_any_element(), label.clone(), cx)
                    .into_any_element()
            }
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
        if self.page != Some(page) {
            // Titled for what it holds (the Window menu, Mission Control).
            window.set_window_title(&label);
            // Focus leaves the page that went (as AppKit's first responder
            // does when a window's content is swapped); sign-in starts in
            // its first field, as Mail's account sheet does.
            let root = self.focus.clone();
            // The field the method shows first: the key alone for an API
            // key, else the email.
            let first = (page == Page::SignIn).then(|| {
                let s = self.sign_in.read(cx);
                if s.method == crate::views::sign_in::Method::ApiKey {
                    s.api_key.clone()
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
        div()
            .id("setup-window")
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
        assert_eq!(page_for(Route::Onboarding, false, false), Page::Onboarding);
        assert_eq!(page_for(Route::SignIn, false, false), Page::SignIn);
        // Before the daemon answers, and once there is a session (the main
        // window is about to take over), the status card.
        assert_eq!(page_for(Route::Unknown, false, false), Page::Status);
        assert_eq!(page_for(Route::Main, false, false), Page::Status);
        // A server being checked keeps its form, whatever the route says.
        assert_eq!(page_for(Route::SignIn, false, true), Page::Onboarding);
        // A daemon that failed shows why, over anything.
        assert_eq!(page_for(Route::Onboarding, true, false), Page::Status);
    }
}
