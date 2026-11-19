//! Share Chat, as the phone's share sheet (`chat_share_sheet.dart`): the
//! chat's public link, made or updated to the chat as it is now and copied
//! (Copy Link / Update and Copy Link); the system Share menu for it; who
//! may open it (Who Has Access); and Delete This Link.
//!
//! Who has access is the chat's own access grants (the core's
//! `ResourceAccessController`, kind chat), offered once the chat has a
//! link. Edit… there swaps this sheet for the access sheet
//! ([`crate::views::access_sheet`]), where people and groups are added and
//! the general access is chosen (only the people added, everyone on the
//! server, anyone with the link); Share Chat comes back when it is done,
//! as on the phone.

use conduit_components::ActiveConduitTheme as _;

use conduit_components::views::kit::Button;
use conduit_protocol::{ChatShare, NoticeLevel, ShareAudience};
use gpui_kit::prelude::*;
use gpui_kit::{
    App, Context, FocusHandle, Focusable, FontWeight, Role, SharedString, Window, div, px, relative,
};

use crate::l10n::{ActiveL10n as _, L10n};
use crate::stores::Stores;

pub const WIDTH: f32 = 480.;
pub const HEIGHT: f32 = 330.;
/// A LibreChat link has no Who Has Access row (it is public), so its sheet
/// is that row shorter.
pub const LIBRECHAT_HEIGHT: f32 = HEIGHT - 56.;

/// Opens Share Chat for `chat_id` on `window`.
pub fn open(
    chat_id: String,
    window: &mut Window,
    cx: &mut App,
) -> Option<gpui_kit::Entity<ShareSheet>> {
    let stores = cx
        .try_global::<crate::AppState>()
        .map(|s| s.stores.clone())?;
    let height = if stores.accounts.read(cx).libre_chat_in_charge() {
        LIBRECHAT_HEIGHT
    } else {
        HEIGHT
    };
    super::sheets::open(window, WIDTH, height, cx, move |window, cx| {
        ShareSheet::new(stores, chat_id, window, cx)
    })
}

/// The audience's label, as the access sheet's General Access names it.
pub fn audience_label(a: ShareAudience, l10n: &L10n) -> String {
    match a {
        ShareAudience::Private => l10n.library_access_only_people_added(),
        // Never "private" when it could not be read: a link may be open.
        ShareAudience::Unknown => l10n.resource_sharing_load_failed(),
        ShareAudience::Public => l10n.library_access_everyone_on_server(),
        ShareAudience::Open => l10n.library_access_anyone_with_link(),
    }
}

pub struct ShareSheet {
    stores: Stores,
    chat_id: String,
    /// What the chat has now, once read.
    pub share: Option<ChatShare>,
    /// A call is on its way.
    pub busy: bool,
    /// The link was just copied.
    pub copied: bool,
    focus: FocusHandle,
}

impl ShareSheet {
    pub fn new(
        stores: Stores,
        chat_id: String,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Self {
        let focus = cx.focus_handle();
        window.focus(&focus, cx);
        let mut sheet = Self {
            stores,
            chat_id,
            share: None,
            busy: false,
            copied: false,
            focus,
        };
        sheet.call(false, None, false, cx);
        sheet
    }

    pub fn linked(&self) -> bool {
        self.share.as_ref().is_some_and(|s| s.share_id.is_some())
    }

    /// `chats.share`: reads, publishes (`publish`) or sets who may open it;
    /// `copy` puts the link on the clipboard once it is there.
    fn call(
        &mut self,
        publish: bool,
        audience: Option<ShareAudience>,
        copy: bool,
        cx: &mut Context<Self>,
    ) {
        let id = self.chat_id.clone();
        let task = self
            .stores
            .chat_list
            .update(cx, |c, cx| c.share(&id, publish, audience, cx));
        self.busy = true;
        cx.notify();
        cx.spawn(async move |this, cx| {
            let result = task.await;
            let _ = this.update(cx, |s: &mut Self, cx| {
                s.busy = false;
                match result {
                    Ok(share) => {
                        if copy && let Some(url) = &share.url {
                            cx.write_to_clipboard(gpui_kit::ClipboardItem::new_string(url.clone()));
                            s.copied = true;
                        }
                        s.share = Some(share);
                    }
                    // The list store says it failed.
                    Err(e) => log::warn!("chats.share: {e}"),
                }
                cx.notify();
            });
        })
        .detach();
    }

    /// Copy Link, or Update and Copy Link once there is one: the link shows
    /// the chat as it is now.
    pub fn copy_link(&mut self, cx: &mut Context<Self>) {
        self.call(true, None, true, cx);
    }

    /// Who Has Access › Edit…: this sheet goes and the access sheet for the
    /// chat comes down in its place (one sheet hangs from a window at a
    /// time); Share Chat comes back once that one is saved or cancelled.
    pub fn edit_access(&mut self, cx: &mut Context<Self>) {
        let stores = self.stores.clone();
        let id = self.chat_id.clone();
        let title = stores
            .chat_list
            .read(cx)
            .find(&id)
            .map(|c| c.title.clone())
            .filter(|t| !t.trim().is_empty())
            .unwrap_or_else(|| cx.l10n().new_chat());
        super::sheets::close(cx);
        cx.defer(move |cx| {
            let main = cx
                .try_global::<crate::AppState>()
                .and_then(|s| s.main_window);
            if let Some(main) = main {
                let _ = main.update(cx, |_, window, cx| {
                    crate::views::access_sheet::open_for_chat(stores, &id, title, window, cx)
                });
            }
        });
    }

    /// Share…: the system Share menu with the link (made first if needed).
    pub fn share_link(
        &mut self,
        at: gpui_kit::Point<gpui_kit::Pixels>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        match self.share.as_ref().and_then(|s| s.url.clone()) {
            Some(url) => {
                crate::shell::share::share(crate::shell::share::Shared::Url(url), at, window, cx)
            }
            None => {
                let id = self.chat_id.clone();
                let task = self
                    .stores
                    .chat_list
                    .update(cx, |c, cx| c.share(&id, true, None, cx));
                self.busy = true;
                cx.spawn_in(window, async move |this, cx| {
                    let result = task.await;
                    let _ = this.update_in(cx, |s: &mut Self, window, cx| {
                        s.busy = false;
                        if let Ok(share) = result {
                            if let Some(url) = share.url.clone() {
                                crate::shell::share::share(
                                    crate::shell::share::Shared::Url(url),
                                    at,
                                    window,
                                    cx,
                                );
                            }
                            s.share = Some(share);
                        }
                        cx.notify();
                    });
                })
                .detach();
            }
        }
    }

    /// Delete This Link: whoever has it can no longer open the chat.
    pub fn delete_link(&mut self, cx: &mut Context<Self>) {
        let id = self.chat_id.clone();
        let task = self.stores.chat_list.update(cx, |c, cx| c.unshare(&id, cx));
        self.busy = true;
        cx.notify();
        let toasts = self.stores.toasts.clone();
        cx.spawn(async move |this, cx| {
            let result = task.await;
            let _ = this.update(cx, |s: &mut Self, cx| {
                s.busy = false;
                if let Ok(share) = result {
                    s.share = Some(share);
                    s.copied = false;
                    let text = cx.l10n().shared_link_deleted();
                    toasts.update(cx, |t, cx| t.show(NoticeLevel::Success, text, cx));
                }
                cx.notify();
            });
        })
        .detach();
    }
}

impl Focusable for ShareSheet {
    fn focus_handle(&self, _: &App) -> FocusHandle {
        self.focus.clone()
    }
}

impl Render for ShareSheet {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let t = cx.conduit().clone();
        let l10n = cx.l10n().clone();
        let (r, m) = (t.roles, t.metrics);
        let weak = cx.entity().downgrade();
        let linked = self.linked();
        let status = if self.copied {
            l10n.desktop_share_link_copied()
        } else if linked {
            l10n.share_chat_existing()
        } else {
            l10n.share_chat_description()
        };
        let url = self.share.as_ref().and_then(|s| s.url.clone());
        let audience = self.share.as_ref().and_then(|s| s.audience);
        let librechat = cx
            .try_global::<crate::AppState>()
            .is_some_and(|s| s.stores.accounts.read(cx).libre_chat_in_charge());
        let row = |id: &'static str, title: String, detail: Option<String>| {
            div()
                .id(id)
                .flex()
                .items_center()
                .justify_between()
                .gap(px(12.))
                .py(px(8.))
                .child(
                    div()
                        .flex()
                        .flex_col()
                        .gap(px(2.))
                        .child(
                            div()
                                .text_size(px(m.control))
                                .text_color(r.text)
                                .child(SharedString::from(title)),
                        )
                        .when_some(detail, |d, detail| {
                            d.child(
                                div()
                                    .text_size(px(m.caption))
                                    .line_height(relative(1.35))
                                    .text_color(r.text_subtle)
                                    .child(SharedString::from(detail)),
                            )
                        }),
                )
        };
        let audience_button = {
            let sheet = weak.clone();
            Button::new("share-audience", l10n.desktop_edit_ellipsis())
                .disabled(self.busy)
                .on_click(std::rc::Rc::new(move |_, _, cx| {
                    let _ = sheet.update(cx, |s, cx| s.edit_access(cx));
                }))
        };
        let body = div()
            .flex()
            .flex_col()
            .gap(px(8.))
            .child(
                div()
                    .text_size(px(m.small))
                    .line_height(relative(1.35))
                    .text_color(r.text_subtle)
                    .child(SharedString::from(status)),
            )
            .when_some(url, |d, url| {
                d.child(
                    div()
                        .id("share-url")
                        .role(Role::Label)
                        .aria_label(SharedString::from(url.clone()))
                        .px(px(8.))
                        .py(px(5.))
                        .rounded(px(6.))
                        .border_1()
                        .border_color(r.border)
                        .bg(r.content)
                        .text_size(px(m.small))
                        .font_weight(FontWeight::MEDIUM)
                        .truncate()
                        .child(SharedString::from(url)),
                )
            })
            .child(
                div()
                    .flex()
                    .gap(px(8.))
                    .child(
                        Button::new(
                            "share-copy",
                            if linked {
                                l10n.update_and_copy_link()
                            } else {
                                l10n.copy_link()
                            },
                        )
                        .disabled(self.busy)
                        .on_click(std::rc::Rc::new({
                            let s = weak.clone();
                            move |_, _, cx| {
                                let _ = s.update(cx, |s, cx| s.copy_link(cx));
                            }
                        })),
                    )
                    .child(
                        Button::new("share-system", l10n.share_system_sheet())
                            .disabled(self.busy)
                            .on_click(std::rc::Rc::new({
                                let s = weak.clone();
                                move |e, window, cx| {
                                    let at = e.position();
                                    let _ = s.update(cx, |s, cx| s.share_link(at, window, cx));
                                }
                            })),
                    ),
            )
            .when(linked, |d| d.child(div().h(px(1.)).bg(r.border)))
            // Who may open it: Open WebUI's access grants. A LibreChat link
            // is public, as the phone's sheet shows it.
            .when(linked && !librechat, |d| {
                d.child(
                    row(
                        "share-audience-row",
                        l10n.chat_share_audience(),
                        Some(
                            // A link whose audience could not be read may
                            // be open: never shown as private.
                            audience
                                .map(|a| audience_label(a, &l10n))
                                .unwrap_or_else(|| l10n.resource_sharing_load_failed()),
                        ),
                    )
                    .role(Role::Group)
                    .aria_label(SharedString::from(l10n.chat_share_audience()))
                    .child(audience_button),
                )
            })
            .when(linked, |d| {
                d.child(
                    row(
                        "share-delete-row",
                        l10n.share_chat_delete_link(),
                        Some(l10n.share_chat_delete_and_create()),
                    )
                    .child(
                        Button::new("share-delete", l10n.delete())
                            .disabled(self.busy)
                            .on_click(std::rc::Rc::new({
                                let s = weak.clone();
                                move |_, _, cx| {
                                    let _ = s.update(cx, |s, cx| s.delete_link(cx));
                                }
                            })),
                    ),
                )
            });
        let done = Button::new("share-done", l10n.done())
            .primary()
            .on_click(std::rc::Rc::new(|_, _, cx| super::sheets::close(cx)))
            .into_any_element();
        super::sheets::frame(
            "share-sheet",
            l10n.share_chat(),
            None,
            body.into_any_element(),
            vec![done],
            super::sheets::close,
            &t,
        )
        .track_focus(&self.focus)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_audience_that_could_not_be_read_is_never_private() {
        let l10n = L10n::new("en");
        let unknown = audience_label(ShareAudience::Unknown, &l10n);
        assert_ne!(unknown, audience_label(ShareAudience::Private, &l10n));
        assert_eq!(unknown, l10n.resource_sharing_load_failed());
    }
}
