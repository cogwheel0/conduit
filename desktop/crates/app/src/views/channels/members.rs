//! A channel's members, as the phone's members sheet
//! (`channel_members_sheet.dart`): who is in it, by name, with search and
//! a page at a time; and, for a group the user manages, Add People… (users
//! and groups, as the account's sharing rules allow) and Remove.
//!
//! The list is the core's (`channels.memberPage`, the core's member
//! controller for the owner who opened it): this sheet only draws it.

use std::rc::Rc;

use conduit_components::ActiveConduitTheme as _;
use conduit_components::announce::{Priority, live_text};
use conduit_components::assets::{IconName, icon};
use conduit_components::theme::with_alpha;
use conduit_components::views::kit::{Button, IconButton, avatar};
use conduit_protocol::{
    AccessPrincipal, AccessPrincipalQuery, ChannelMemberChangeResult, ChannelMemberDto,
    ChannelMemberListPhase, ChannelMemberPage, ChannelMemberQuery, ChannelMemberRemove,
    ChannelMembersAdd, NoticeLevel, methods,
};
use gpui_kit::component::input::{InputEvent, InputState};
use gpui_kit::prelude::*;
use gpui_kit::{
    AnyElement, App, AsyncApp, Context, ElementId, Entity, FontWeight, Role, SharedString,
    Subscription, Task, WeakEntity, Window, div, px,
};

use super::model::initials;
use crate::l10n::{ActiveL10n as _, L10n};
use crate::shell::sheet::{SheetSpec, present_sheet};
use crate::stores::Stores;
use crate::stores::rpc::Rpc;
use crate::views::sheet::{self, SheetBody};

pub const WIDTH: f32 = 480.;

/// Members… for channel `channel_id` on `window`.
pub fn open(stores: Stores, channel_id: String, window: &mut Window, cx: &mut App) {
    sheet::open(window, WIDTH, cx, move |w, cx| {
        MembersSheet::new(stores, channel_id, w, cx)
    });
}

/// What the sheet shows: the members, or the people to add.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Mode {
    Members,
    Adding,
}

pub struct MembersSheet {
    stores: Stores,
    rpc: Rpc,
    pub channel_id: String,
    pub page: Option<ChannelMemberPage>,
    pub mode: Mode,
    pub search: Entity<InputState>,
    /// Add People: what the search found, and who is chosen.
    pub found: Vec<AccessPrincipal>,
    pub chosen: Vec<AccessPrincipal>,
    pub busy: bool,
    pub error: Option<String>,
    /// Counts the changes that failed: each failure is heard, even in the
    /// words of the one before (see [`Self::failed`]).
    failures: u64,
    /// Empty the search field on the next frame.
    clear_search: bool,
    _subscriptions: Vec<Subscription>,
    _load: Option<Task<()>>,
    _find: Option<Task<()>>,
}

impl MembersSheet {
    pub fn new(
        stores: Stores,
        channel_id: String,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Self {
        let rpc = stores.connection.read(cx).rpc();
        let l = cx.l10n().clone();
        let search =
            cx.new(|cx| InputState::new(window, cx).placeholder(l.channel_members_search_hint()));
        search.update(cx, |s, cx| s.focus(window, cx));
        let subscriptions = vec![
            cx.subscribe_in(&search, window, |this, state, e: &InputEvent, _, cx| {
                if let InputEvent::Change = e {
                    let query = state.read(cx).value().trim().to_string();
                    match this.mode {
                        Mode::Members => this.load(query, false, cx),
                        Mode::Adding => this.find(query, cx),
                    }
                }
            }),
            // Its people and changes belong to the account it opened for.
            sheet::close_with_account(&stores, cx),
        ];
        let mut this = Self {
            stores,
            rpc,
            channel_id,
            page: None,
            mode: Mode::Members,
            search,
            found: vec![],
            chosen: vec![],
            busy: false,
            error: None,
            failures: 0,
            clear_search: false,
            _subscriptions: subscriptions,
            _load: None,
            _find: None,
        };
        this.load(String::new(), false, cx);
        this
    }

    /// `channels.memberPage`: the first page of `query`, or the next one.
    pub fn load(&mut self, query: String, more: bool, cx: &mut Context<Self>) {
        let call = self
            .rpc
            .call::<methods::ChannelsMemberPage>(&ChannelMemberQuery {
                channel_id: self.channel_id.clone(),
                query,
                more,
            });
        self._load = Some(
            cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
                let result = call.await;
                let _ = this.update(cx, |s, cx| {
                    match result {
                        Ok(page) => s.page = Some(page),
                        Err(e) => {
                            log::warn!("channels.memberPage: {e}");
                            if let Some(p) = s.page.as_mut() {
                                p.phase = ChannelMemberListPhase::Failed;
                            }
                        }
                    }
                    cx.notify();
                });
            }),
        );
    }

    pub fn load_more(&mut self, cx: &mut Context<Self>) {
        let query = self
            .page
            .as_ref()
            .map(|p| p.query.clone())
            .unwrap_or_default();
        self.load(query, true, cx);
    }

    /// Add People…: the search finds people and groups instead.
    pub fn start_adding(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.mode = Mode::Adding;
        self.chosen.clear();
        self.search.update(cx, |s, cx| s.set_value("", window, cx));
        let hint = cx.l10n().desktop_channel_add_search_hint();
        self.search
            .update(cx, |s, cx| s.set_placeholder(hint, window, cx));
        self.search.update(cx, |s, cx| s.focus(window, cx));
        self.find(String::new(), cx);
        cx.notify();
    }

    pub fn stop_adding(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.mode = Mode::Members;
        self.chosen.clear();
        self.found.clear();
        self.search.update(cx, |s, cx| s.set_value("", window, cx));
        let hint = cx.l10n().channel_members_search_hint();
        self.search
            .update(cx, |s, cx| s.set_placeholder(hint, window, cx));
        self.load(String::new(), false, cx);
        cx.notify();
    }

    /// Add People: people and groups matching `query` (people only for a
    /// typed name, as the phone's picker).
    pub fn find(&mut self, query: String, cx: &mut Context<Self>) {
        let call = self
            .rpc
            .call::<methods::AccessPrincipals>(&AccessPrincipalQuery { query });
        self._find = Some(
            cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
                let result = call.await;
                let _ = this.update(cx, |s, cx| {
                    match result {
                        Ok(list) => s.found = list.items,
                        Err(e) => log::warn!("access.principals: {e}"),
                    }
                    cx.notify();
                });
            }),
        );
    }

    fn is_member(&self, id: &str) -> bool {
        self.page
            .as_ref()
            .is_some_and(|p| p.members.iter().any(|m| m.id == id))
    }

    /// Whom the account may add: users, groups, as its rules say.
    fn may_add(&self, principal: &AccessPrincipal) -> bool {
        let Some(page) = &self.page else {
            return false;
        };
        match principal.r#type.as_str() {
            "group" => page.allow_groups,
            _ => page.allow_users,
        }
    }

    pub fn toggle_chosen(&mut self, principal: AccessPrincipal, cx: &mut Context<Self>) {
        if let Some(i) = self
            .chosen
            .iter()
            .position(|p| p.id == principal.id && p.r#type == principal.r#type)
        {
            self.chosen.remove(i);
        } else {
            self.chosen.push(principal);
        }
        cx.notify();
    }

    /// `channels.addMembers` for who is chosen.
    pub fn add(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.chosen.is_empty() || self.busy {
            return;
        }
        let (groups, users): (Vec<_>, Vec<_>) =
            self.chosen.iter().partition(|p| p.r#type == "group");
        let call = self
            .rpc
            .call::<methods::ChannelsAddMembers>(&ChannelMembersAdd {
                channel_id: self.channel_id.clone(),
                user_ids: users.into_iter().map(|p| p.id.clone()).collect(),
                group_ids: groups.into_iter().map(|p| p.id.clone()).collect(),
            });
        self.busy = true;
        cx.notify();
        let _ = window;
        self._load = Some(
            cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
                let result = call.await;
                let _ = this.update(cx, |s, cx| {
                    s.busy = false;
                    match result {
                        Ok(change) => {
                            s.page = Some(change.page);
                            if change.result == ChannelMemberChangeResult::Done {
                                let text = cx.l10n().desktop_channel_members_added();
                                s.toast(NoticeLevel::Success, text, cx);
                                // The field empties on the next frame (it needs
                                // the window).
                                s.clear_search = true;
                                s.mode = Mode::Members;
                                s.chosen.clear();
                                s.found.clear();
                                s.load(String::new(), false, cx);
                            } else {
                                s.failed(change_failure(change.result, cx.l10n()));
                            }
                        }
                        Err(e) => {
                            log::warn!("channels.addMembers: {e}");
                            s.failed(cx.l10n().channel_members_change_failed());
                        }
                    }
                    cx.notify();
                });
            }),
        );
    }

    /// Asks, then `channels.removeMember`.
    pub fn remove(
        &mut self,
        member: ChannelMemberDto,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let l = cx.l10n().clone();
        let name = if member.name.is_empty() {
            l.channel_unknown_member()
        } else {
            member.name.clone()
        };
        let spec = SheetSpec::new(
            l.desktop_channel_remove_member_title(&name),
            l.desktop_channel_remove_member_message(),
            l.desktop_channel_remove_member(),
            l.cancel(),
        )
        .destructive();
        let answer = present_sheet(window, spec, cx);
        let rpc = self.rpc.clone();
        let channel_id = self.channel_id.clone();
        self._load = Some(
            cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
                if !answer.await {
                    return;
                }
                let call = rpc.call::<methods::ChannelsRemoveMember>(&ChannelMemberRemove {
                    channel_id,
                    user_id: member.id.clone(),
                });
                let result = call.await;
                let _ = this.update(cx, |s, cx| {
                    match result {
                        Ok(change) => {
                            s.page = Some(change.page);
                            if change.result == ChannelMemberChangeResult::Done {
                                let text = cx.l10n().desktop_channel_member_removed(&name);
                                s.toast(NoticeLevel::Success, text, cx);
                            } else {
                                s.failed(change_failure(change.result, cx.l10n()));
                            }
                        }
                        Err(e) => {
                            log::warn!("channels.removeMember: {e}");
                            s.failed(cx.l10n().channel_members_change_failed());
                        }
                    }
                    cx.notify();
                });
            }),
        );
    }

    /// A change answered with a failure: shown under the search, and said
    /// again when a retry fails in the same words.
    fn failed(&mut self, text: String) {
        self.error = Some(text);
        self.failures += 1;
    }

    fn toast(&self, level: NoticeLevel, text: String, cx: &mut App) {
        self.stores
            .toasts
            .update(cx, |t, cx| t.show(level, text, cx));
    }

    fn member_row(
        &self,
        member: &ChannelMemberDto,
        manage: bool,
        l: &L10n,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let t = cx.conduit().clone();
        let r = t.roles;
        let m = t.metrics;
        let name = if member.name.is_empty() {
            l.channel_unknown_member()
        } else {
            member.name.clone()
        };
        let label = if member.me {
            format!("{name} {}", l.desktop_channel_you())
        } else {
            name.clone()
        };
        let remove = (manage && !member.me).then(|| {
            let view = cx.entity().downgrade();
            let member = member.clone();
            IconButton::new(
                ElementId::Name(format!("member-remove-{}", member.id).into()),
                IconName::UserMinus,
                l.channel_members_remove_member(&name),
            )
            .size(26., 15.)
            .on_click(Rc::new(move |_, window, cx| {
                let member = member.clone();
                let _ = view.update(cx, |v, cx| v.remove(member, window, cx));
            }))
        });
        div()
            .id(ElementId::Name(format!("member-{}", member.id).into()))
            .role(Role::ListItem)
            .aria_label(SharedString::from(label.clone()))
            .h(px(44.))
            .px(px(8.))
            .flex()
            .items_center()
            .gap(px(10.))
            .rounded(t.row_radius())
            .hover(|s| s.bg(r.hover))
            .child(
                div()
                    .relative()
                    .child(avatar(
                        &initials(&name),
                        28.,
                        with_alpha(r.text, 0.08),
                        r.text_subtle,
                    ))
                    .when(member.active, |d| {
                        d.child(
                            div()
                                .absolute()
                                .bottom(px(-1.))
                                .right(px(-1.))
                                .size(px(10.))
                                .rounded_full()
                                .border_2()
                                .border_color(r.content)
                                .bg(r.success),
                        )
                    }),
            )
            .child(
                div()
                    .flex_1()
                    .min_w_0()
                    .flex()
                    .flex_col()
                    .child(
                        div()
                            .truncate()
                            .text_size(px(m.body))
                            .text_color(r.text)
                            .child(SharedString::from(label)),
                    )
                    .when_some(member.email.clone(), |d, e| {
                        d.child(
                            div()
                                .truncate()
                                .text_size(px(m.caption))
                                .text_color(r.text_subtle)
                                .child(SharedString::from(e)),
                        )
                    }),
            )
            .children(remove)
            .into_any_element()
    }

    fn principal_row(
        &self,
        principal: &AccessPrincipal,
        l: &L10n,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let t = cx.conduit().clone();
        let r = t.roles;
        let m = t.metrics;
        let member = principal.r#type != "group" && self.is_member(&principal.id);
        let allowed = self.may_add(principal) && !member;
        let chosen = self
            .chosen
            .iter()
            .any(|p| p.id == principal.id && p.r#type == principal.r#type);
        let view = cx.entity().downgrade();
        let p = principal.clone();
        let group = principal.r#type == "group";
        div()
            .id(ElementId::Name(
                format!("principal-{}-{}", principal.r#type, principal.id).into(),
            ))
            .role(Role::CheckBox)
            .aria_label(SharedString::from(principal.name.clone()))
            .aria_toggled(if chosen {
                gpui_kit::Toggled::True
            } else {
                gpui_kit::Toggled::False
            })
            .h(px(44.))
            .px(px(8.))
            .flex()
            .items_center()
            .gap(px(10.))
            .rounded(t.row_radius())
            .when(!allowed, |d| d.opacity(0.5))
            .when(allowed, |d| d.cursor_pointer().hover(|s| s.bg(r.hover)))
            .child(if group {
                conduit_components::views::kit::icon_tile(
                    IconName::Users,
                    28.,
                    with_alpha(r.text, 0.08),
                    r.text_subtle,
                    14.,
                )
                .into_any_element()
            } else {
                avatar(
                    &initials(&principal.name),
                    28.,
                    with_alpha(r.text, 0.08),
                    r.text_subtle,
                )
                .into_any_element()
            })
            .child(
                div()
                    .flex_1()
                    .min_w_0()
                    .flex()
                    .flex_col()
                    .child(
                        div()
                            .truncate()
                            .text_size(px(m.body))
                            .text_color(r.text)
                            .child(SharedString::from(principal.name.clone())),
                    )
                    .child(
                        div()
                            .truncate()
                            .text_size(px(m.caption))
                            .text_color(r.text_subtle)
                            .child(SharedString::from(if member {
                                l.library_picker_already_member()
                            } else {
                                principal.email.clone().unwrap_or_default()
                            })),
                    ),
            )
            .when(chosen, |d| d.child(icon(IconName::Check, 15., r.text)))
            .when(allowed, |d| {
                d.on_click(move |_, _, cx| {
                    let p = p.clone();
                    let _ = view.update(cx, |v, cx| v.toggle_chosen(p, cx));
                })
            })
            .into_any_element()
    }
}

fn change_failure(result: ChannelMemberChangeResult, l: &L10n) -> String {
    match result {
        ChannelMemberChangeResult::Denied => l.channel_members_change_denied(),
        ChannelMemberChangeResult::NotPermitted => l.channel_members_change_not_permitted(),
        _ => l.channel_members_change_failed(),
    }
}

impl SheetBody for MembersSheet {
    fn cancel(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.mode == Mode::Adding {
            self.stop_adding(window, cx);
            return;
        }
        sheet::dismiss(cx);
    }

    fn label(&self, cx: &App) -> SharedString {
        cx.l10n().desktop_channel_members().into()
    }

    fn footer(&mut self, _: &mut Window, cx: &mut Context<Self>) -> Option<AnyElement> {
        let l = cx.l10n().clone();
        let view = cx.entity().downgrade();
        let manage = self.page.as_ref().is_some_and(|p| p.can_manage);
        let footer = div().w_full().flex().items_center().gap(px(8.));
        Some(match self.mode {
            Mode::Members => {
                let add = view.clone();
                footer
                    .when(manage, |d| {
                        d.child(
                            Button::new("members-add", l.desktop_channel_add_people())
                                .icon(IconName::UserPlus)
                                .on_click(Rc::new(move |_, window, cx| {
                                    let _ = add.update(cx, |v, cx| v.start_adding(window, cx));
                                })),
                        )
                    })
                    .child(div().flex_1())
                    .child(
                        Button::new("members-done", l.desktop_done())
                            .primary()
                            .on_click(Rc::new(move |_, window, cx| {
                                let _ = view.update(cx, |v, cx| v.cancel(window, cx));
                            })),
                    )
                    .into_any_element()
            }
            Mode::Adding => {
                let back = view.clone();
                footer
                    .child(div().flex_1())
                    .child(
                        Button::new("members-add-cancel", l.cancel()).on_click(Rc::new(
                            move |_, window, cx| {
                                let _ = back.update(cx, |v, cx| v.stop_adding(window, cx));
                            },
                        )),
                    )
                    .child(
                        Button::new("members-add-confirm", l.channel_members_add_confirm())
                            .primary()
                            .disabled(self.chosen.is_empty() || self.busy)
                            .on_click(Rc::new(move |_, window, cx| {
                                let _ = view.update(cx, |v, cx| v.add(window, cx));
                            })),
                    )
                    .into_any_element()
            }
        })
    }
}

impl Render for MembersSheet {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let l = cx.l10n().clone();
        let t = cx.conduit().clone();
        let r = t.roles;
        let m = t.metrics;
        if std::mem::take(&mut self.clear_search) {
            let hint = l.channel_members_search_hint();
            self.search.update(cx, |s, cx| {
                s.set_value("", window, cx);
                s.set_placeholder(hint, window, cx);
            });
        }
        let title = match self.mode {
            Mode::Members => match self.page.as_ref().and_then(|p| p.total) {
                Some(n) => l.channel_members_title(n),
                None => l.desktop_channel_members(),
            },
            Mode::Adding => l.desktop_channel_add_people_title(),
        };
        let mut list: Vec<AnyElement> = vec![];
        match self.mode {
            Mode::Members => match &self.page {
                None => list.push(
                    div()
                        .p(px(12.))
                        .text_color(r.text_subtle)
                        .child(SharedString::from(l.desktop_loading()))
                        .into_any_element(),
                ),
                Some(page) if page.phase == ChannelMemberListPhase::Failed => {
                    let view = cx.entity().downgrade();
                    let query = page.query.clone();
                    list.push(
                        div()
                            .p(px(12.))
                            .flex()
                            .items_center()
                            .gap(px(10.))
                            .child(
                                div()
                                    .text_color(r.text_subtle)
                                    .child(SharedString::from(l.channel_members_load_failed())),
                            )
                            .child(
                                Button::new("members-retry", l.desktop_try_again()).on_click(
                                    Rc::new(move |_, _, cx| {
                                        let q = query.clone();
                                        let _ = view.update(cx, |v, cx| v.load(q, false, cx));
                                    }),
                                ),
                            )
                            .into_any_element(),
                    );
                }
                Some(page) => {
                    let page = page.clone();
                    if page.members.is_empty() && page.phase == ChannelMemberListPhase::Ready {
                        list.push(
                            div()
                                .p(px(12.))
                                .text_color(r.text_subtle)
                                .child(SharedString::from(l.channel_members_empty()))
                                .into_any_element(),
                        );
                    }
                    for member in &page.members {
                        list.push(self.member_row(member, page.can_manage, &l, cx));
                    }
                    if page.has_more {
                        let view = cx.entity().downgrade();
                        list.push(
                            div()
                                .pt(px(6.))
                                .flex()
                                .justify_center()
                                .child(
                                    Button::new(
                                        "members-more",
                                        if page.load_more_failed {
                                            l.desktop_try_again()
                                        } else {
                                            l.channel_members_load_more()
                                        },
                                    )
                                    .on_click(Rc::new(
                                        move |_, _, cx| {
                                            let _ = view.update(cx, |v, cx| v.load_more(cx));
                                        },
                                    )),
                                )
                                .into_any_element(),
                        );
                    }
                }
            },
            Mode::Adding => {
                for principal in self.found.clone() {
                    list.push(self.principal_row(&principal, &l, cx));
                }
            }
        }
        div()
            .id("members-sheet")
            .flex()
            .flex_col()
            .gap(px(12.))
            .child(
                div()
                    .id("sheet-title")
                    .role(Role::Heading)
                    .text_size(px(m.body + 2.))
                    .font_weight(FontWeight::SEMIBOLD)
                    .child(SharedString::from(title.clone())),
            )
            .child({
                let focused =
                    gpui_kit::Focusable::focus_handle(self.search.read(cx), cx).is_focused(window);
                let hint = match self.mode {
                    Mode::Members => l.channel_members_search_hint(),
                    Mode::Adding => l.desktop_channel_add_search_hint(),
                };
                conduit_components::views::kit::field_frame(focused, 30., cx)
                    .child(icon(IconName::Search, 14., r.text_subtle))
                    .child(conduit_components::views::kit::bare_input(
                        &self.search,
                        hint,
                        m.control + 1.,
                    ))
            })
            .when_some(self.error.clone(), |d, e| {
                d.child(
                    div()
                        .id("members-error")
                        .role(Role::Alert)
                        .text_size(px(m.small))
                        .text_color(r.danger)
                        .child(SharedString::from(e.clone()))
                        .child(
                            live_text("live", Some(e.into()), Priority::High)
                                .attempt(self.failures),
                        ),
                )
            })
            .child(
                div()
                    .id("members-list")
                    .role(Role::List)
                    .aria_label(SharedString::from(title.clone()))
                    .flex()
                    .flex_col()
                    .gap(px(1.))
                    .children(list),
            )
    }
}
