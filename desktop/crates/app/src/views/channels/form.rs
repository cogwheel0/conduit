//! New Channel and Edit Channel, as the phone's channel form
//! (`channel_form_dialog.dart`): a name, a description and, for a new
//! channel, whether it is private. A sheet on the main window; Return
//! saves, Esc cancels. A new channel is a group with its maker as a member
//! (`channels.save`, as mobile's New Channel), and opens once made.

use std::rc::Rc;

use conduit_components::ActiveConduitTheme as _;
use conduit_components::views::kit::{Button, Switch};
use conduit_protocol::{ChannelEdit, ChannelSummary, methods};
use gpui_kit::component::input::{InputEvent, InputState};
use gpui_kit::prelude::*;
use gpui_kit::{
    AnyElement, App, AsyncApp, Context, FontWeight, Role, SharedString, Subscription, Task,
    WeakEntity, Window, div, px, relative,
};

use crate::l10n::ActiveL10n as _;
use crate::stores::Stores;
use crate::stores::navigation::AreaItem;
use crate::views::forms;
use crate::views::sheet::{self, SheetBody};

pub const WIDTH: f32 = 460.;

/// New Channel… on `window`.
pub fn open_new(stores: Stores, window: &mut Window, cx: &mut App) {
    sheet::open(window, WIDTH, cx, move |w, cx| {
        ChannelForm::new(stores, None, w, cx)
    });
}

/// Edit Channel… for `channel` on `window`.
pub fn open_edit(stores: Stores, channel: ChannelSummary, window: &mut Window, cx: &mut App) {
    sheet::open(window, WIDTH, cx, move |w, cx| {
        ChannelForm::new(stores, Some(channel), w, cx)
    });
}

pub struct ChannelForm {
    stores: Stores,
    /// The channel being edited; `None` for a new one.
    pub channel: Option<ChannelSummary>,
    pub name: Entity<InputState>,
    pub description: Entity<InputState>,
    pub private: bool,
    pub error: Option<String>,
    pub saving: bool,
    _subscriptions: Vec<Subscription>,
    _save: Option<Task<()>>,
}

use gpui_kit::Entity;

impl ChannelForm {
    pub fn new(
        stores: Stores,
        channel: Option<ChannelSummary>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Self {
        let l = cx.l10n().clone();
        let name = forms::input(l.channel_name(), false, window, cx);
        let description = forms::input(l.channel_description(), false, window, cx);
        if let Some(c) = &channel {
            name.update(cx, |s, cx| s.set_value(&c.name, window, cx));
            let text = c.description.clone().unwrap_or_default();
            description.update(cx, |s, cx| s.set_value(&text, window, cx));
        }
        name.update(cx, |s, cx| s.focus(window, cx));
        let on_input = |this: &mut Self,
                        _: &Entity<InputState>,
                        e: &InputEvent,
                        window: &mut Window,
                        cx: &mut Context<Self>| match e {
            InputEvent::Change => {
                this.error = None;
                cx.notify();
            }
            InputEvent::PressEnter { .. } => this.save(window, cx),
            _ => {}
        };
        // What it would make or change belongs to the account it opened for.
        let subscriptions = vec![
            cx.subscribe_in(&name, window, on_input),
            cx.subscribe_in(&description, window, on_input),
            sheet::close_with_account(&stores, cx),
        ];
        Self {
            stores,
            private: channel.as_ref().is_some_and(|c| c.private),
            channel,
            name,
            description,
            error: None,
            saving: false,
            _subscriptions: subscriptions,
            _save: None,
        }
    }

    pub fn set_private(&mut self, private: bool, cx: &mut Context<Self>) {
        self.private = private;
        cx.notify();
    }

    /// `channels.save`, then the sheet goes; a new channel opens.
    pub fn save(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.saving {
            return;
        }
        let l = cx.l10n().clone();
        let name = forms::text(&self.name, cx);
        if name.is_empty() {
            self.error = Some(l.desktop_channel_name_required());
            forms::focus_invalid(&self.name, window, cx);
            cx.notify();
            return;
        }
        let description = forms::text(&self.description, cx);
        let edit = ChannelEdit {
            id: self.channel.as_ref().map(|c| c.id.clone()),
            name: name.clone(),
            description: (!description.is_empty()).then_some(description),
            private: self.private,
        };
        let before: Vec<String> = self
            .stores
            .areas
            .read(cx)
            .channels
            .iter()
            .flatten()
            .map(|c| c.id.clone())
            .collect();
        let is_new = self.channel.is_none();
        let call = self
            .stores
            .connection
            .read(cx)
            .rpc()
            .call::<methods::ChannelsSave>(&edit);
        let stores = self.stores.clone();
        self.saving = true;
        cx.notify();
        self._save = Some(
            cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
                let result = call.await;
                cx.update(|cx| match result {
                    Ok(list) => {
                        stores.areas.update(cx, |a, cx| {
                            a.refresh(crate::stores::navigation::Area::Channels, cx)
                        });
                        // The new channel is the one the list did not hold.
                        let made = is_new
                            .then(|| {
                                list.channels
                                    .iter()
                                    .find(|c| !before.contains(&c.id) && c.name == name)
                                    .map(|c| c.id.clone())
                            })
                            .flatten();
                        sheet::dismiss(cx);
                        if let Some(id) = made {
                            stores
                                .navigation
                                .update(cx, |n, cx| n.open_item(AreaItem::Channel(id), cx));
                        }
                    }
                    Err(e) => {
                        log::warn!("channels.save: {e}");
                        let _ = this.update(cx, |s, cx| {
                            s.saving = false;
                            s.error = Some(cx.l10n().desktop_channel_save_failed());
                            cx.notify();
                        });
                    }
                });
            }),
        );
    }
}

impl SheetBody for ChannelForm {
    fn cancel(&mut self, _: &mut Window, cx: &mut Context<Self>) {
        if !self.saving {
            sheet::dismiss(cx);
        }
    }

    fn label(&self, cx: &App) -> SharedString {
        let l = cx.l10n();
        if self.channel.is_some() {
            l.channel_edit()
        } else {
            l.desktop_new_channel_title()
        }
        .into()
    }

    fn footer(&mut self, _: &mut Window, cx: &mut Context<Self>) -> Option<AnyElement> {
        let l = cx.l10n().clone();
        let save = cx.entity().downgrade();
        let cancel = save.clone();
        let filled = !forms::text(&self.name, cx).is_empty();
        Some(
            div()
                .w_full()
                .flex()
                .items_center()
                .justify_end()
                .gap(px(8.))
                .child(
                    Button::new("channel-form-cancel", l.cancel()).on_click(Rc::new(
                        move |_, window, cx| {
                            let _ = cancel.update(cx, |v, cx| v.cancel(window, cx));
                        },
                    )),
                )
                .child(
                    Button::new(
                        "channel-form-save",
                        if self.channel.is_some() {
                            l.save()
                        } else {
                            l.create()
                        },
                    )
                    .primary()
                    .disabled(self.saving || !filled)
                    .on_click(Rc::new(move |_, window, cx| {
                        let _ = save.update(cx, |v, cx| v.save(window, cx));
                    })),
                )
                .into_any_element(),
        )
    }
}

impl Render for ChannelForm {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let l = cx.l10n().clone();
        let t = cx.conduit().clone();
        let title = self.label(cx);
        let mut rows: Vec<AnyElement> = vec![
            forms::field(
                l.name(),
                &self.name,
                None,
                self.error.clone().map(Into::into),
                window,
                cx,
            )
            .into_any_element(),
            forms::field(
                l.channel_description(),
                &self.description,
                None,
                None,
                window,
                cx,
            )
            .into_any_element(),
        ];
        let new = self.channel.is_none();
        if new {
            let view = cx.entity().downgrade();
            let private = self.private;
            rows.push(
                forms::form_row(
                    l.channel_private(),
                    Switch::new("channel-private", l.channel_private(), private).on_click(Rc::new(
                        move |_, _, cx| {
                            let _ = view.update(cx, |v, cx| v.set_private(!private, cx));
                        },
                    )),
                    cx,
                )
                .into_any_element(),
            );
        }
        div()
            .id("channel-form")
            .flex()
            .flex_col()
            .gap(px(14.))
            .child(
                div()
                    .id("sheet-title")
                    .role(Role::Heading)
                    .text_size(px(t.metrics.body + 2.))
                    .font_weight(FontWeight::SEMIBOLD)
                    .child(title),
            )
            .child(forms::form_group(rows, cx))
            .when(new, |d| {
                d.child(
                    div()
                        .px(px(4.))
                        .text_size(px(t.metrics.small))
                        .line_height(relative(1.35))
                        .text_color(t.roles.text_subtle)
                        .child(SharedString::from(l.desktop_channel_private_footer())),
                )
            })
    }
}
