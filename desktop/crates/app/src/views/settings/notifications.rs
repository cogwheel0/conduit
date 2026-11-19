//! Settings › Notifications, the phone's Notifications page: Allow
//! Notifications (asks macOS for permission the first time), System
//! Notification Settings, how they show (In-App Banners while Conduit is in
//! front, System Notifications behind it, Sound, Always Play Sound), what
//! notifies (Chat Responses, Channel Messages, and Only Mentions and Direct
//! Messages), and, with Advanced on and the account allowed, the account's
//! Webhook Destinations on its Open WebUI server.
//!
//! The settings are core's (`notifications.*`); the master toggle and the
//! sounds are mirrored to the Open WebUI account, as on the phone.

use std::rc::Rc;

use conduit_components::views::kit::{Button, Switch, setting_row};
use conduit_components::views::settings::settings_section;
use conduit_protocol::{
    NoParams, NotificationSettingsDto, NotificationSettingsPatch, WebhookDto, WebhookList, methods,
};
use gpui_kit::prelude::*;
use gpui_kit::{
    AnyElement, App, AsyncApp, Context, SharedString, Subscription, WeakEntity, Window, div, px,
};

use crate::desktop::Desktop;
use crate::l10n::{ActiveL10n as _, L10n};
use crate::stores::Stores;
use crate::stores::shell::NotificationAccess;
use crate::views::forms;

use super::controls;
use super::webhook_editor::WebhookEditorSheet;

pub struct NotificationsPane {
    stores: Stores,
    /// The account's destinations, once read (Advanced only).
    pub webhooks: Option<WebhookList>,
    pub loading_webhooks: bool,
    /// The newest list read or change asked for: an older read's answer,
    /// landing after it, is not shown (a retry can overlap a reconnect's
    /// read, and either can overlap an editor's change).
    webhooks_ticket: u64,
    advanced: bool,
    _subscriptions: Vec<Subscription>,
}

impl NotificationsPane {
    pub fn new(stores: Stores, window: &mut Window, cx: &mut Context<Self>) -> Self {
        let advanced_on = advanced(&stores, cx);
        let mut subscriptions = vec![
            cx.observe(&stores.notifications, |_, _, cx| cx.notify()),
            cx.observe_in(&stores.app_settings, window, |this, _, window, cx| {
                let now = advanced(&this.stores, cx);
                if now && !this.advanced {
                    this.refresh_webhooks(window, cx);
                }
                this.advanced = now;
                cx.notify();
            }),
        ];
        if let Some(shell) = cx.try_global::<Desktop>().map(|d| d.shell.clone()) {
            subscriptions.push(cx.observe(&shell, |_, _, cx| cx.notify()));
        }
        let mut this = Self {
            stores,
            webhooks: None,
            loading_webhooks: false,
            webhooks_ticket: 0,
            advanced: advanced_on,
            _subscriptions: subscriptions,
        };
        if advanced_on {
            this.refresh_webhooks(window, cx);
        }
        // The settings could not be read: opening the pane reads again.
        if this.stores.notifications.read(cx).load_failed {
            this.stores.notifications.update(cx, |s, cx| s.refresh(cx));
        }
        this
    }

    /// The tab is shown (again): a read that failed is tried again.
    pub fn shown(&mut self, cx: &mut Context<Self>) {
        if self.stores.notifications.read(cx).load_failed {
            self.stores.notifications.update(cx, |s, cx| s.refresh(cx));
        }
        let failed = self.webhooks.as_ref().is_some_and(|l| l.failed);
        if self.advanced && failed && !self.loading_webhooks {
            self.reload_webhooks(cx);
        }
    }

    /// Reads the destinations again.
    pub fn refresh_webhooks(&mut self, _window: &mut Window, cx: &mut Context<Self>) {
        self.reload_webhooks(cx);
    }

    fn reload_webhooks(&mut self, cx: &mut Context<Self>) {
        self.webhooks_ticket += 1;
        let ticket = self.webhooks_ticket;
        self.loading_webhooks = true;
        cx.notify();
        let call = self
            .stores
            .connection
            .read(cx)
            .rpc()
            .call::<methods::WebhooksList>(&NoParams);
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result = call.await;
            let _ = this.update(cx, |s, cx| {
                if s.webhooks_ticket != ticket {
                    return;
                }
                s.loading_webhooks = false;
                match result {
                    Ok(list) => s.webhooks = Some(list),
                    Err(e) => {
                        log::warn!("webhooks.list: {e}");
                        s.webhooks = Some(WebhookList {
                            available: true,
                            failed: true,
                            ..Default::default()
                        });
                    }
                }
                cx.notify();
            });
        })
        .detach();
    }

    /// What a change in the editor answered.
    pub fn adopt(&mut self, list: WebhookList, cx: &mut Context<Self>) {
        // Newer than any read still out.
        self.webhooks_ticket += 1;
        self.loading_webhooks = false;
        self.webhooks = Some(list);
        cx.notify();
    }

    fn set(&self, patch: NotificationSettingsPatch, cx: &mut App) {
        self.stores
            .notifications
            .update(cx, |s, cx| s.set(patch, cx));
        // Turning them on asks macOS for permission (in `desktop`).
    }

    /// Add Destination… (none) or Edit… on one.
    pub fn open_editor(
        &mut self,
        target: Option<WebhookDto>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let Some(list) = self.webhooks.clone() else {
            return;
        };
        let pane = cx.entity().downgrade();
        let on_change: super::webhook_editor::OnChange = Rc::new(move |list, cx| {
            let _ = pane.update(cx, |p, cx| p.adopt(list, cx));
        });
        WebhookEditorSheet::open(
            self.stores.clone(),
            list.owner.clone(),
            list.events.clone(),
            target,
            on_change,
            window,
            cx,
        );
    }

    fn general(
        &self,
        s: &NotificationSettingsDto,
        l10n: &L10n,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let access = cx
            .try_global::<Desktop>()
            .map(|d| d.shell.read(cx).notifications)
            .unwrap_or_default();
        let store = self.stores.notifications.clone();
        let enabled = s.enabled;
        let master = Switch::new(
            "notifications-enabled",
            l10n.notifications_enabled_title(),
            enabled,
        )
        .disabled(!self.stores.notifications.read(cx).loaded)
        .on_click(Rc::new(move |_, _, cx| {
            store.update(cx, |s, cx| {
                s.set(
                    NotificationSettingsPatch {
                        enabled: Some(!enabled),
                        ..Default::default()
                    },
                    cx,
                )
            })
        }));
        let open = Button::new(
            "notification-system-settings",
            l10n.desktop_open_system_settings(),
        )
        .on_click(Rc::new(|_, _, cx| {
            crate::desktop::open_notification_settings(cx)
        }));
        let footer: Option<SharedString> = match access {
            NotificationAccess::Denied if enabled => {
                Some(l10n.desktop_notifications_denied().into())
            }
            NotificationAccess::Unavailable => {
                Some(l10n.desktop_notifications_unavailable().into())
            }
            _ => None,
        };
        settings_section(
            SharedString::default(),
            footer,
            vec![
                setting_row(
                    l10n.notifications_enabled_title(),
                    Some(l10n.notifications_enabled_description().into()),
                    master,
                    cx,
                )
                .into_any_element(),
                setting_row(
                    l10n.notification_system_settings_title(),
                    Some(l10n.notification_system_settings_description().into()),
                    open,
                    cx,
                )
                .into_any_element(),
            ],
            cx,
        )
        .into_any_element()
    }

    fn switch_row(
        &self,
        id: &'static str,
        (title, subtitle): (String, String),
        (on, disabled): (bool, bool),
        patch: fn(bool) -> NotificationSettingsPatch,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let view = cx.entity().downgrade();
        // Unknown settings take no change (see `NotificationsStore::set`).
        let unknown = !self.stores.notifications.read(cx).loaded;
        let control = Switch::new(id, title.clone(), on)
            .disabled(disabled || unknown)
            .on_click(Rc::new(move |_, _, cx| {
                let _ = view.update(cx, |v, cx| v.set(patch(!on), cx));
            }));
        setting_row(title, Some(subtitle.into()), control, cx).into_any_element()
    }

    fn surfaces(
        &self,
        s: &NotificationSettingsDto,
        l10n: &L10n,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let off = !s.enabled;
        let rows = vec![
            self.switch_row(
                "notification-banner",
                (
                    l10n.notification_in_app_banner_title(),
                    l10n.notification_in_app_banner_description(),
                ),
                (s.in_app_banner, off),
                |on| NotificationSettingsPatch {
                    in_app_banner: Some(on),
                    ..Default::default()
                },
                cx,
            ),
            self.switch_row(
                "notification-system",
                (
                    l10n.notification_system_title(),
                    l10n.notification_system_description(),
                ),
                (s.system, off),
                |on| NotificationSettingsPatch {
                    system: Some(on),
                    ..Default::default()
                },
                cx,
            ),
            self.switch_row(
                "notification-sound",
                (
                    l10n.notification_sound_title(),
                    l10n.notification_sound_description(),
                ),
                (s.sound, off),
                |on| NotificationSettingsPatch {
                    sound: Some(on),
                    ..Default::default()
                },
                cx,
            ),
            self.switch_row(
                "notification-sound-always",
                (
                    l10n.notification_sound_always_title(),
                    l10n.notification_sound_always_description(),
                ),
                (s.sound_always, off || !s.sound),
                |on| NotificationSettingsPatch {
                    sound_always: Some(on),
                    ..Default::default()
                },
                cx,
            ),
        ];
        let footer = off.then(|| SharedString::from(l10n.notification_requires_master()));
        settings_section(SharedString::default(), footer, rows, cx).into_any_element()
    }

    fn events(
        &self,
        s: &NotificationSettingsDto,
        l10n: &L10n,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let off = !s.enabled;
        let rows = vec![
            self.switch_row(
                "notification-chat",
                (
                    l10n.notification_chat_title(),
                    l10n.notification_chat_description(),
                ),
                (s.answers, off),
                |on| NotificationSettingsPatch {
                    answers: Some(on),
                    ..Default::default()
                },
                cx,
            ),
            self.switch_row(
                "notification-channel",
                (
                    l10n.notification_channel_title(),
                    l10n.notification_channel_description(),
                ),
                (s.channels, off),
                |on| NotificationSettingsPatch {
                    channels: Some(on),
                    ..Default::default()
                },
                cx,
            ),
            self.switch_row(
                "notification-mentions-only",
                (
                    l10n.desktop_notify_mentions_only(),
                    l10n.desktop_notify_mentions_only_detail(),
                ),
                (s.mentions_only, off || !s.channels),
                |on| NotificationSettingsPatch {
                    mentions_only: Some(on),
                    ..Default::default()
                },
                cx,
            ),
        ];
        settings_section(
            SharedString::default(),
            Some(l10n.desktop_notify_answers_footer().into()),
            rows,
            cx,
        )
        .into_any_element()
    }

    fn webhooks(
        &self,
        l10n: &L10n,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Option<AnyElement> {
        if !self.advanced {
            return None;
        }
        let list = self.webhooks.as_ref()?;
        if !list.available {
            return None;
        }
        let view = cx.entity().downgrade();
        let mut rows: Vec<AnyElement> = vec![];
        if list.failed {
            let view = view.clone();
            rows.push(
                setting_row(
                    l10n.notification_targets_load_failed(),
                    None,
                    Button::new("webhooks-retry", l10n.retry()).on_click(Rc::new(
                        move |_, window, cx| {
                            let _ = view.update(cx, |v, cx| v.refresh_webhooks(window, cx));
                        },
                    )),
                    cx,
                )
                .into_any_element(),
            );
        } else if list.items.is_empty() {
            rows.push(
                setting_row(l10n.notification_targets_empty(), None, div(), cx).into_any_element(),
            );
        }
        for (i, hook) in list.items.iter().enumerate() {
            rows.push(self.webhook_row(i, hook, l10n, cx));
        }
        if !list.failed {
            let view = view.clone();
            let add = Button::new("webhooks-add", l10n.desktop_add_destination_ellipsis())
                .on_click(Rc::new(move |_, window, cx| {
                    let _ = view.update(cx, |v, cx| v.open_editor(None, window, cx));
                }));
            rows.push(
                controls::buttons(vec![add.into_any_element()])
                    .p(px(10.))
                    .into_any_element(),
            );
        }
        if list.stale {
            let view = view.clone();
            rows.push(
                setting_row(
                    l10n.notification_targets_stale(),
                    None,
                    Button::new("webhooks-stale-retry", l10n.retry()).on_click(Rc::new(
                        move |_, window, cx| {
                            let _ = view.update(cx, |v, cx| v.refresh_webhooks(window, cx));
                        },
                    )),
                    cx,
                )
                .into_any_element(),
            );
        }
        let _ = window;
        Some(
            settings_section(
                l10n.notification_targets_title(),
                Some(l10n.notification_targets_description().into()),
                rows,
                cx,
            )
            .into_any_element(),
        )
    }

    fn webhook_row(
        &self,
        index: usize,
        hook: &WebhookDto,
        l10n: &L10n,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let delivery = match hook.delivery.as_str() {
            "always" => l10n.notification_target_delivery_always(),
            "away" => l10n.notification_target_delivery_away(),
            other => other.to_string(),
        };
        let subtitle = [hook.masked_url.clone().unwrap_or_default(), delivery]
            .into_iter()
            .filter(|s| !s.is_empty())
            .collect::<Vec<_>>()
            .join(" \u{00B7} ");
        let status = [
            hook.is_default
                .then(|| l10n.notification_target_default_badge()),
            Some(if hook.enabled {
                l10n.enabled()
            } else {
                l10n.disabled()
            }),
        ]
        .into_iter()
        .flatten()
        .collect::<Vec<_>>()
        .join(" \u{00B7} ");
        let view = cx.entity().downgrade();
        let target = hook.clone();
        let edit = Button::new(
            gpui_kit::ElementId::NamedInteger("webhook-edit".into(), index as u64),
            l10n.desktop_edit_ellipsis(),
        )
        .on_click(Rc::new(move |_, window, cx| {
            let target = target.clone();
            let _ = view.update(cx, |v, cx| v.open_editor(Some(target), window, cx));
        }));
        let control = div()
            .flex()
            .items_center()
            .gap(px(10.))
            .child(controls::value(status, cx))
            .child(edit);
        setting_row(hook.id.clone(), Some(subtitle.into()), control, cx).into_any_element()
    }
}

/// Advanced is on (the phone shows the destinations behind it).
fn advanced(stores: &Stores, cx: &App) -> bool {
    stores
        .app_settings
        .read(cx)
        .settings()
        .advanced_features_enabled
}

impl Render for NotificationsPane {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let l10n = cx.l10n().clone();
        let settings = self.stores.notifications.read(cx).settings().clone();
        let mut sections = vec![
            self.general(&settings, &l10n, cx),
            self.surfaces(&settings, &l10n, cx),
            self.events(&settings, &l10n, cx),
        ];
        if let Some(hooks) = self.webhooks(&l10n, window, cx) {
            sections.push(hooks);
        }
        let unread = {
            let store = self.stores.notifications.read(cx);
            !store.loaded && store.load_failed
        };
        if unread {
            // What is shown is not what was saved: say so.
            sections.insert(
                0,
                forms::form_error("notifications-load-error", l10n.error_message(), cx)
                    .into_any_element(),
            );
        }
        if let Some(e) = &self.stores.notifications.read(cx).error {
            log::debug!("notifications: last change refused: {e}");
            sections.push(
                forms::form_error("notifications-error", l10n.error_message(), cx)
                    .into_any_element(),
            );
        }
        div().flex().flex_col().gap(px(22.)).children(sections)
    }
}

#[cfg(test)]
mod tests {
    use conduit_protocol::{WebhookList, methods};
    use gpui_kit::AppContext as _;

    use super::NotificationsPane;
    use crate::views::sheet::bench::bench;

    fn owned(owner: &str) -> WebhookList {
        WebhookList {
            available: true,
            owner: owner.into(),
            ..Default::default()
        }
    }

    /// A destinations list that couldn't be read is read again when the tab
    /// is shown again (Advanced on); one that was read is not.
    #[gpui_kit::test]
    fn a_failed_destinations_read_is_tried_again_when_shown(cx: &mut gpui_kit::TestAppContext) {
        let (daemon, stores, vcx) = bench(cx);
        let s = stores.clone();
        let pane = vcx.update(|window, cx| cx.new(|cx| NotificationsPane::new(s, window, cx)));
        pane.update(vcx, |p, cx| {
            p.advanced = true;
            p.webhooks = Some(WebhookList {
                available: true,
                failed: true,
                ..Default::default()
            });
            p.shown(cx);
        });
        vcx.run_until_parked();
        assert_eq!(daemon.calls::<methods::WebhooksList>().len(), 1);
        daemon.returns::<methods::WebhooksList>(owned("w1"));
        pane.update(vcx, |p, cx| p.shown(cx));
        vcx.run_until_parked();
        let calls = daemon.calls::<methods::WebhooksList>().len();
        pane.update(vcx, |p, cx| p.shown(cx));
        vcx.run_until_parked();
        assert_eq!(daemon.calls::<methods::WebhooksList>().len(), calls);
    }

    /// A destinations read that lands after a newer one (a retry beside a
    /// reconnect's read) is not shown over it, nor its owner kept.
    #[gpui_kit::test]
    fn an_older_destinations_read_never_replaces_a_newer_one(cx: &mut gpui_kit::TestAppContext) {
        let (daemon, stores, vcx) = bench(cx);
        daemon.once::<methods::WebhooksList>(Ok(owned("w1")));
        daemon.once::<methods::WebhooksList>(Ok(owned("w2")));
        let held = daemon.hold_one::<methods::WebhooksList>(0);
        let s = stores.clone();
        let pane = vcx.update(|window, cx| cx.new(|cx| NotificationsPane::new(s, window, cx)));
        pane.update_in(vcx, |p, window, cx| p.refresh_webhooks(window, cx));
        vcx.run_until_parked();
        pane.update_in(vcx, |p, window, cx| p.refresh_webhooks(window, cx));
        vcx.run_until_parked();
        drop(held);
        vcx.run_until_parked();
        let owner = pane.read_with(vcx, |p, _| p.webhooks.as_ref().map(|l| l.owner.clone()));
        assert_eq!(owner.as_deref(), Some("w2"));
    }
}
