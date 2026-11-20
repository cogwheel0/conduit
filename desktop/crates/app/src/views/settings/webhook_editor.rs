//! New Destination and Edit Destination: one webhook destination of the
//! account, in a sheet on the Settings window, as the phone's editor has it.
//!
//! A new one takes its URL and, optionally, a name (fixed once saved). An
//! edit shows the name and the server's masked URL only (the server never
//! returns the URL); a URL typed there replaces it. Enabled, Delivery (When
//! Away or Always) and the events it subscribes to follow. Make Default and
//! Send Test Notification act on the destination as the server holds it, so
//! they wait until the edits are saved. Delete… asks first. Every change is
//! sent for the account the list was read for (`owner`); after a switch it
//! is refused and the form keeps what was typed.

use std::collections::BTreeSet;
use std::rc::Rc;

use conduit_components::ActiveConduitTheme as _;
use conduit_components::views::kit::{Button, Segment, Segmented, Switch, setting_row};
use conduit_components::views::settings::settings_section;
use conduit_daemon::RpcError;
use conduit_protocol::{
    WebhookCreate, WebhookDto, WebhookEventDto, WebhookList, WebhookRef, WebhookUpdate, methods,
};
use gpui_kit::component::input::InputState;
use gpui_kit::prelude::*;
use gpui_kit::{
    AnyElement, App, AsyncApp, Context, ElementId, Entity, FontWeight, Role, SharedString,
    WeakEntity, Window, div, px, relative,
};

use crate::l10n::{ActiveL10n as _, L10n};
use crate::shell::sheet::{SheetSpec, present_sheet};
use crate::stores::Stores;
use crate::views::forms;
use crate::views::sheet::{self, SheetBody};

use super::controls;

/// The sheet's width.
pub const WIDTH: f32 = 560.;

/// What runs with the list a change answered.
pub type OnChange = Rc<dyn Fn(WebhookList, &mut App)>;

/// The one action running, so its control shows progress while the others
/// wait.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Action {
    Save,
    MakeDefault,
    Test,
    Delete,
}

const DELIVERIES: [&str; 2] = ["away", "always"];

pub struct WebhookEditorSheet {
    stores: Stores,
    owner: String,
    catalog: Vec<WebhookEventDto>,
    /// The destination being edited; None for a new one.
    pub target: Option<WebhookDto>,
    pub url: Entity<InputState>,
    pub name: Entity<InputState>,
    pub enabled: bool,
    pub delivery: String,
    pub events: BTreeSet<String>,
    pub running: Option<Action>,
    /// Save was tried without a URL.
    url_touched: bool,
    /// What the last action said: the server's words, or ours.
    pub error: Option<String>,
    /// A test notification went out.
    pub note: Option<String>,
    on_change: OnChange,
}

impl WebhookEditorSheet {
    pub fn open(
        stores: Stores,
        owner: String,
        catalog: Vec<WebhookEventDto>,
        target: Option<WebhookDto>,
        on_change: OnChange,
        parent: &Window,
        cx: &mut App,
    ) -> Option<Entity<Self>> {
        sheet::open(parent, WIDTH, cx, move |window, cx| {
            Self::new(stores, owner, catalog, target, on_change, window, cx)
        })
    }

    fn new(
        stores: Stores,
        owner: String,
        catalog: Vec<WebhookEventDto>,
        target: Option<WebhookDto>,
        on_change: OnChange,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Self {
        let l10n = cx.l10n().clone();
        let url = forms::input(
            if target.is_some() {
                l10n.notification_target_url_keep_hint()
            } else {
                l10n.notification_target_url_hint()
            },
            false,
            window,
            cx,
        );
        let name = forms::input(l10n.notification_target_name_hint(), false, window, cx);
        cx.observe(&url, |_, _, cx| cx.notify()).detach();
        cx.observe(&name, |_, _, cx| cx.notify()).detach();
        if target.is_none() {
            url.update(cx, |s, cx| s.focus(window, cx));
        }
        Self {
            stores,
            owner,
            catalog,
            enabled: target.as_ref().is_none_or(|t| t.enabled),
            delivery: target
                .as_ref()
                .map(|t| t.delivery.clone())
                .unwrap_or_else(|| "away".into()),
            events: target
                .as_ref()
                .map(|t| t.events.iter().cloned().collect())
                .unwrap_or_default(),
            target,
            url,
            name,
            running: None,
            url_touched: false,
            error: None,
            note: None,
            on_change,
        }
    }

    pub fn in_flight(&self) -> bool {
        self.running.is_some()
    }

    /// The catalog's first event (E2E).
    pub fn catalog_first(&self) -> Option<String> {
        self.catalog.first().map(|e| e.event.clone())
    }

    /// Send Test Notification, as its button presses it.
    pub fn press_test(&mut self, cx: &mut Context<Self>) {
        self.send_test(cx);
    }

    /// Make Default, as its button presses it.
    pub fn press_make_default(&mut self, cx: &mut Context<Self>) {
        self.make_default(cx);
    }

    /// Delete…, as its button presses it.
    pub fn press_delete(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.delete(window, cx);
    }

    /// The form holds something the server does not have yet.
    pub fn is_dirty(&self, cx: &App) -> bool {
        let initial_events: BTreeSet<String> = self
            .target
            .as_ref()
            .map(|t| t.events.iter().cloned().collect())
            .unwrap_or_default();
        !forms::text(&self.url, cx).is_empty()
            || !forms::text(&self.name, cx).is_empty()
            || self.enabled != self.target.as_ref().is_none_or(|t| t.enabled)
            || self.delivery
                != self
                    .target
                    .as_ref()
                    .map(|t| t.delivery.as_str())
                    .unwrap_or("away")
            || self.events != initial_events
    }

    /// Events the destination holds that the catalog no longer lists: the
    /// server refuses an update that keeps one, so every save drops them
    /// (as the phone does). Empty while the catalog is unknown.
    fn retired(&self) -> BTreeSet<String> {
        if self.catalog.is_empty() {
            return BTreeSet::new();
        }
        let listed: BTreeSet<&str> = self.catalog.iter().map(|e| e.event.as_str()).collect();
        self.target
            .iter()
            .flat_map(|t| t.events.iter())
            .filter(|e| !listed.contains(e.as_str()))
            .cloned()
            .collect()
    }

    /// The rows the events list shows: the catalog, then any held event the
    /// catalog doesn't name (kept until turned off), unless retired.
    fn event_rows(&self, l10n: &L10n) -> Vec<(String, String, Option<String>)> {
        let listed: BTreeSet<&str> = self.catalog.iter().map(|e| e.event.as_str()).collect();
        let retired = self.retired();
        let mut rows: Vec<(String, String, Option<String>)> = self
            .catalog
            .iter()
            .map(|e| (e.event.clone(), e.label.clone(), e.description.clone()))
            .collect();
        for id in self.target.iter().flat_map(|t| t.events.iter()) {
            if !listed.contains(id.as_str()) && !retired.contains(id) {
                rows.push((
                    id.clone(),
                    id.clone(),
                    Some(l10n.notification_target_unknown_event()),
                ));
            }
        }
        rows
    }

    fn rpc(&self, cx: &App) -> crate::stores::rpc::Rpc {
        self.stores.connection.read(cx).rpc()
    }

    /// Runs `call`; with the list it answers, `then` decides what follows
    /// (close the sheet, say the test went out).
    fn run(
        &mut self,
        action: Action,
        call: impl std::future::Future<Output = Result<WebhookList, RpcError>> + 'static,
        fallback: Option<String>,
        then: fn(&mut Self, &mut Context<Self>) -> bool,
        cx: &mut Context<Self>,
    ) {
        self.running = Some(action);
        self.error = None;
        self.note = None;
        cx.notify();
        let on_change = self.on_change.clone();
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result = call.await;
            let _ = this.update(cx, |s, cx| {
                s.running = None;
                match result {
                    Ok(list) => {
                        on_change(list, cx);
                        if then(s, cx) {
                            sheet::dismiss(cx);
                        }
                    }
                    Err(e) => {
                        log::warn!("webhooks: {e}");
                        let l10n = cx.l10n().clone();
                        s.error = Some(match e.args.get("reason").map(String::as_str) {
                            Some("accountChanged") => l10n.notification_targets_account_changed(),
                            Some("unavailable") => l10n.notification_targets_unavailable(),
                            Some("urlRequired") => l10n.notification_target_url_required(),
                            _ => e
                                .args
                                .get("detail")
                                .cloned()
                                .or(fallback)
                                .unwrap_or_else(|| l10n.error_message()),
                        });
                    }
                }
                cx.notify();
            });
        })
        .detach();
    }

    pub fn save(&mut self, cx: &mut Context<Self>) {
        if self.in_flight() {
            return;
        }
        let url = forms::text(&self.url, cx);
        let rows: Vec<String> = self
            .event_rows(&cx.l10n().clone())
            .into_iter()
            .map(|(id, _, _)| id)
            .filter(|id| self.events.contains(id))
            .collect();
        let rpc = self.rpc(cx);
        match self.target.clone() {
            None => {
                if url.is_empty() {
                    self.url_touched = true;
                    cx.notify();
                    return;
                }
                let call = rpc.call::<methods::WebhooksCreate>(&WebhookCreate {
                    owner: self.owner.clone(),
                    url,
                    name: forms::text(&self.name, cx),
                    enabled: self.enabled,
                    events: rows,
                    delivery: self.delivery.clone(),
                });
                self.run(Action::Save, call, None, |_, _| true, cx);
            }
            Some(target) => {
                let held: BTreeSet<String> = target.events.iter().cloned().collect();
                let events_changed = !self.retired().is_empty() || self.events != held;
                let call = rpc.call::<methods::WebhooksUpdate>(&WebhookUpdate {
                    owner: self.owner.clone(),
                    id: target.id.clone(),
                    enabled: (self.enabled != target.enabled).then_some(self.enabled),
                    events: events_changed.then_some(rows),
                    delivery: (self.delivery != target.delivery).then(|| self.delivery.clone()),
                    url: (!url.is_empty()).then_some(url),
                });
                self.run(Action::Save, call, None, |_, _| true, cx);
            }
        }
    }

    fn make_default(&mut self, cx: &mut Context<Self>) {
        let Some(target) = self.target.clone() else {
            return;
        };
        if self.in_flight() || self.is_dirty(cx) {
            return;
        }
        let call = self
            .rpc(cx)
            .call::<methods::WebhooksMakeDefault>(&WebhookRef {
                owner: self.owner.clone(),
                id: target.id,
            });
        self.run(Action::MakeDefault, call, None, |_, _| true, cx);
    }

    /// One real test notification: only ever for a press.
    fn send_test(&mut self, cx: &mut Context<Self>) {
        let Some(target) = self.target.clone() else {
            return;
        };
        if self.in_flight() || self.is_dirty(cx) {
            return;
        }
        let call = self.rpc(cx).call::<methods::WebhooksTest>(&WebhookRef {
            owner: self.owner.clone(),
            id: target.id,
        });
        let failed = cx.l10n().notification_target_test_failed();
        self.run(
            Action::Test,
            call,
            Some(failed),
            |s, cx| {
                s.note = Some(cx.l10n().notification_target_test_sent());
                false
            },
            cx,
        );
    }

    fn delete(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(target) = self.target.clone() else {
            return;
        };
        if self.in_flight() {
            return;
        }
        let l10n = cx.l10n().clone();
        let spec = SheetSpec::new(
            l10n.notification_target_delete(),
            l10n.notification_target_delete_confirm(&target.id),
            l10n.delete(),
            l10n.cancel(),
        )
        .destructive();
        let ask = present_sheet(window, spec, cx);
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            if !ask.await {
                return;
            }
            let _ = this.update(cx, |s, cx| {
                let call = s.rpc(cx).call::<methods::WebhooksDelete>(&WebhookRef {
                    owner: s.owner.clone(),
                    id: target.id.clone(),
                });
                s.run(Action::Delete, call, None, |_, _| true, cx);
            });
        })
        .detach();
    }

    fn url_error(&self, l10n: &L10n, cx: &App) -> Option<SharedString> {
        (self.target.is_none() && self.url_touched && forms::text(&self.url, cx).is_empty())
            .then(|| l10n.notification_target_url_required().into())
    }

    fn fields(&self, l10n: &L10n, window: &Window, cx: &mut Context<Self>) -> AnyElement {
        // No typing while an action is out: Save, Make Default and Delete
        // close the sheet when they land, so words typed meanwhile would go
        // with it unsaved. (The switch, segments and events wait on busy.)
        let locked = self.in_flight();
        let mut rows: Vec<AnyElement> = vec![];
        match &self.target {
            None => {
                rows.push(
                    forms::field_locked(
                        l10n.notification_target_url_label(),
                        &self.url,
                        None,
                        self.url_error(l10n, cx),
                        locked,
                        window,
                        cx,
                    )
                    .into_any_element(),
                );
                rows.push(
                    forms::field_locked(
                        l10n.notification_target_name_label(),
                        &self.name,
                        Some(l10n.notification_target_name_helper().into()),
                        None,
                        locked,
                        window,
                        cx,
                    )
                    .into_any_element(),
                );
            }
            Some(target) => {
                rows.push(
                    setting_row(
                        l10n.notification_target_id_label(),
                        None,
                        controls::value(target.id.clone(), cx),
                        cx,
                    )
                    .into_any_element(),
                );
                // Display only: the server never returns the saved URL. A
                // URL typed here replaces it.
                rows.push(
                    forms::field_locked(
                        l10n.notification_target_url_label(),
                        &self.url,
                        target.masked_url.clone().map(SharedString::from),
                        None,
                        locked,
                        window,
                        cx,
                    )
                    .into_any_element(),
                );
            }
        }
        forms::form_group(rows, cx).into_any_element()
    }

    fn options(&self, l10n: &L10n, cx: &mut Context<Self>) -> AnyElement {
        let view = cx.entity().downgrade();
        let enabled = self.enabled;
        let busy = self.in_flight();
        let switch = Switch::new(
            "webhook-enabled",
            l10n.notification_target_enabled_title(),
            enabled,
        )
        .disabled(busy)
        .on_click(Rc::new({
            let view = view.clone();
            move |_, _, cx| {
                let _ = view.update(cx, |v, cx| {
                    v.enabled = !enabled;
                    cx.notify();
                });
            }
        }));
        let selected = DELIVERIES
            .iter()
            .position(|d| *d == self.delivery)
            .unwrap_or(usize::MAX);
        let delivery = Segmented::new(
            "webhook-delivery",
            l10n.notification_target_delivery_label(),
            vec![
                Segment::new(l10n.notification_target_delivery_away()),
                Segment::new(l10n.notification_target_delivery_always()),
            ],
            selected,
        )
        .on_select(Rc::new({
            let view = view.clone();
            move |i, _, cx| {
                if busy {
                    return;
                }
                let _ = view.update(cx, |v, cx| {
                    v.delivery = DELIVERIES[i].to_string();
                    cx.notify();
                });
            }
        }));
        let note = match self.delivery.as_str() {
            "away" => Some(l10n.notification_target_delivery_away_description()),
            "always" => Some(l10n.notification_target_delivery_always_description()),
            _ => None,
        };
        settings_section(
            SharedString::default(),
            None,
            vec![
                setting_row(l10n.notification_target_enabled_title(), None, switch, cx)
                    .into_any_element(),
                setting_row(
                    l10n.notification_target_delivery_label(),
                    note.map(SharedString::from),
                    delivery,
                    cx,
                )
                .into_any_element(),
            ],
            cx,
        )
        .into_any_element()
    }

    fn events_group(&self, l10n: &L10n, window: &mut Window, cx: &mut Context<Self>) -> AnyElement {
        let rows = self.event_rows(l10n);
        let busy = self.in_flight();
        let items: Vec<AnyElement> = if rows.is_empty() {
            vec![
                setting_row(
                    l10n.notification_target_events_unavailable(),
                    None,
                    div(),
                    cx,
                )
                .into_any_element(),
            ]
        } else {
            rows.into_iter()
                .enumerate()
                .map(|(i, (id, label, description))| {
                    let on = self.events.contains(&id);
                    let view = cx.entity().downgrade();
                    let check = controls::checkbox(
                        ElementId::NamedInteger("webhook-event".into(), i as u64),
                        label.clone(),
                        on,
                        Rc::new(move |_, _, cx| {
                            if busy {
                                return;
                            }
                            let id = id.clone();
                            let _ = view.update(cx, |v, cx| {
                                if !v.events.remove(&id) {
                                    v.events.insert(id);
                                }
                                cx.notify();
                            });
                        }),
                        window,
                        cx,
                    );
                    setting_row(label, description.map(SharedString::from), check, cx)
                        .into_any_element()
                })
                .collect()
        };
        settings_section(l10n.notification_target_events_label(), None, items, cx)
            .into_any_element()
    }

    fn actions(&self, l10n: &L10n, cx: &mut Context<Self>) -> Option<AnyElement> {
        let target = self.target.as_ref()?;
        let dirty = self.is_dirty(cx);
        let busy = self.in_flight();
        let view = cx.entity().downgrade();
        let mut rows = vec![];
        if !target.is_default {
            let view = view.clone();
            rows.push(
                setting_row(
                    l10n.notification_target_make_default(),
                    dirty.then(|| l10n.notification_target_make_default_needs_save().into()),
                    Button::new(
                        "webhook-make-default",
                        l10n.notification_target_make_default(),
                    )
                    .disabled(dirty || busy)
                    .on_click(Rc::new(move |_, _, cx| {
                        let _ = view.update(cx, |v, cx| v.make_default(cx));
                    })),
                    cx,
                )
                .into_any_element(),
            );
        }
        rows.push(
            setting_row(
                l10n.notification_target_test(),
                dirty.then(|| l10n.notification_target_test_needs_save().into()),
                Button::new(
                    "webhook-test",
                    if self.running == Some(Action::Test) {
                        l10n.desktop_testing()
                    } else {
                        l10n.notification_target_test()
                    },
                )
                .disabled(dirty || busy)
                .on_click(Rc::new(move |_, _, cx| {
                    let _ = view.update(cx, |v, cx| v.send_test(cx));
                })),
                cx,
            )
            .into_any_element(),
        );
        Some(settings_section(SharedString::default(), None, rows, cx).into_any_element())
    }
}

impl SheetBody for WebhookEditorSheet {
    /// An action is out (from its start until it ends): Quit beeps instead
    /// of asking.
    fn busy(&self, _: &App) -> bool {
        self.in_flight()
    }

    /// A form changed: Quit asks first, as Cancel does.
    fn unsaved(&self, cx: &App) -> bool {
        self.is_dirty(cx)
    }

    fn footer(&mut self, _: &mut Window, cx: &mut Context<Self>) -> Option<AnyElement> {
        let l10n = cx.l10n().clone();
        let busy = self.in_flight();
        let view = cx.entity().downgrade();
        let delete = self.target.is_some().then(|| {
            let view = view.clone();
            Button::new("webhook-delete", l10n.desktop_delete_ellipsis())
                .disabled(busy)
                .on_click(Rc::new(move |_, window, cx| {
                    let _ = view.update(cx, |v, cx| v.delete(window, cx));
                }))
        });
        let cancel = {
            let view = view.clone();
            Button::new("webhook-cancel", l10n.cancel())
                .disabled(busy)
                .on_click(Rc::new(move |_, window, cx| {
                    let _ = view.update(cx, |v, cx| v.cancel(window, cx));
                }))
        };
        let save = Button::new(
            "webhook-save",
            if self.running == Some(Action::Save) {
                l10n.desktop_saving()
            } else {
                l10n.save()
            },
        )
        .primary()
        .disabled(busy)
        .on_click(Rc::new(move |_, _, cx| {
            let _ = view.update(cx, |v, cx| v.save(cx));
        }));
        Some(
            div()
                .w_full()
                .flex()
                .items_center()
                .gap(px(8.))
                .children(delete)
                .child(div().flex_1())
                .child(cancel)
                .child(save)
                .into_any_element(),
        )
    }

    fn cancel(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.in_flight() {
            return;
        }
        if !self.is_dirty(cx) {
            sheet::dismiss(cx);
            return;
        }
        let l10n = cx.l10n().clone();
        let spec = SheetSpec::new(
            l10n.desktop_discard_changes_title(),
            l10n.desktop_discard_changes_message(),
            l10n.desktop_discard(),
            l10n.cancel(),
        )
        .destructive();
        let ask = present_sheet(window, spec, cx);
        cx.spawn(async move |_, cx: &mut AsyncApp| {
            if ask.await {
                cx.update(sheet::dismiss);
            }
        })
        .detach();
    }

    fn label(&self, cx: &App) -> SharedString {
        let l10n = cx.l10n();
        if self.target.is_some() {
            l10n.notification_target_edit_title().into()
        } else {
            l10n.notification_target_new_title().into()
        }
    }
}

impl Render for WebhookEditorSheet {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let l10n = cx.l10n().clone();
        let t = cx.conduit().clone();
        let title = self.label(cx);
        let mut body: Vec<AnyElement> = vec![
            self.fields(&l10n, window, cx),
            self.options(&l10n, cx),
            self.events_group(&l10n, window, cx),
        ];
        if let Some(actions) = self.actions(&l10n, cx) {
            body.push(actions);
        }
        if let Some(error) = &self.error {
            body.push(forms::form_error("webhook-error", error.clone(), cx).into_any_element());
        } else if let Some(note) = &self.note {
            body.push(forms::form_note(note.clone(), true, cx).into_any_element());
        }
        div()
            .id("webhook-editor")
            .w_full()
            .flex()
            .flex_col()
            .gap(px(16.))
            .child(
                div()
                    .flex()
                    .flex_col()
                    .gap(px(4.))
                    .child(
                        div()
                            .id("sheet-title")
                            .role(Role::Heading)
                            .text_size(px(t.metrics.body + 2.))
                            .font_weight(FontWeight::SEMIBOLD)
                            .child(title),
                    )
                    .child(
                        div()
                            .text_size(px(t.metrics.small + 0.5))
                            .line_height(relative(1.4))
                            .text_color(t.roles.text_subtle)
                            .child(l10n.notification_targets_description()),
                    ),
            )
            .children(body)
    }
}

#[cfg(test)]
mod tests {
    use std::cell::Cell;
    use std::rc::Rc;

    use gpui_kit::App;

    use super::WebhookEditorSheet;
    use crate::views::sheet::{self, bench::bench};

    /// A destination typed and not saved: Quit asks first.
    #[gpui_kit::test]
    fn quit_asks_before_dropping_a_destination_not_saved(cx: &mut gpui_kit::TestAppContext) {
        let (_daemon, stores, vcx) = bench(cx);
        let sheet = vcx
            .update(|window, cx| {
                WebhookEditorSheet::open(
                    stores.clone(),
                    "w1".into(),
                    vec![],
                    None,
                    Rc::new(|_, _: &mut App| {}),
                    window,
                    cx,
                )
            })
            .expect("the editor opens");
        vcx.run_until_parked();
        let url = sheet.read_with(vcx, |s, _| s.url.clone());
        vcx.update(|window, cx| {
            url.update(cx, |s, cx| {
                s.set_value("https://hooks.example.com/seed", window, cx)
            })
        });
        vcx.run_until_parked();
        let quits = Rc::new(Cell::new(0));
        let q = quits.clone();
        vcx.update(|_, cx| sheet::quit_with(cx, Rc::new(move |_| q.set(q.get() + 1))));
        vcx.run_until_parked();
        assert_eq!(quits.get(), 0, "Quit dropped the destination typed");
        assert!(
            vcx.update(|_, cx| sheet::current::<WebhookEditorSheet>(cx))
                .is_some()
        );
    }

    /// Quit while a new destination saves queues nothing: a beep, no quit,
    /// and the sheet stays until its save ends; once that fails, Quit asks
    /// and Discard quits.
    #[gpui_kit::test]
    fn quit_beeps_during_a_destination_save_and_asks_after_it_fails(
        cx: &mut gpui_kit::TestAppContext,
    ) {
        let (daemon, stores, vcx) = bench(cx);
        daemon.once::<conduit_protocol::methods::WebhooksCreate>(Err(
            conduit_daemon::RpcError::internal("down"),
        ));
        let sheet = vcx
            .update(|window, cx| {
                WebhookEditorSheet::open(
                    stores.clone(),
                    "w1".into(),
                    vec![],
                    None,
                    Rc::new(|_, _: &mut App| {}),
                    window,
                    cx,
                )
            })
            .expect("the editor opens");
        vcx.run_until_parked();
        let url = sheet.read_with(vcx, |s, _| s.url.clone());
        vcx.update(|window, cx| {
            url.update(cx, |s, cx| {
                s.set_value("https://hooks.example.com/seed", window, cx)
            })
        });
        vcx.run_until_parked();
        let held = daemon.hold::<conduit_protocol::methods::WebhooksCreate>();
        sheet.update(vcx, |s, cx| s.save(cx));
        let quit = |vcx: &mut gpui_kit::VisualTestContext| {
            let quits = Rc::new(Cell::new(0));
            let q = quits.clone();
            vcx.update(|_, cx| sheet::quit_with(cx, Rc::new(move |_| q.set(q.get() + 1))));
            vcx.run_until_parked();
            quits
        };
        let settle = |vcx: &mut gpui_kit::VisualTestContext| {
            for _ in 0..2 {
                vcx.run_until_parked();
                vcx.executor()
                    .advance_clock(std::time::Duration::from_secs(5));
            }
            vcx.run_until_parked();
        };
        let up = |vcx: &mut gpui_kit::VisualTestContext| {
            vcx.update(|_, cx| sheet::current::<WebhookEditorSheet>(cx))
                .is_some()
        };
        let during = quit(vcx);
        assert_eq!(
            vcx.update(|_, cx| cx.global::<crate::shell::sheet::Beeps>().0),
            1,
            "Quit during the save did not beep"
        );
        drop(held);
        settle(vcx);
        assert!(up(vcx), "the failed save's sheet closed");
        assert_eq!(during.get(), 0, "a Quit waited on the save");
        vcx.update(|_, cx| cx.set_global(crate::shell::sheet::AutoAnswer(Some(true))));
        let after = quit(vcx);
        settle(vcx);
        assert!(!up(vcx), "Discard left the sheet open");
        assert_eq!(after.get(), 1, "Discard after the failed save did not quit");
    }
}
