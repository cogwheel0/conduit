//! The Group Chat sheets on the main window, as the phone's
//! (`hermes_room_create_sheet.dart`, `hermes_room_info_sheet.dart`):
//!
//! * **New Room**: a name and two to six of the connection's bots (only
//!   those Hermes can seat); Create makes the room and opens it.
//! * **Room Info**: the room's name, its purpose, the notes every bot
//!   keeps in mind and who answers a message that names nobody (everyone,
//!   a lead bot, or a quick model call), saved together; its bots with
//!   what each is doing (and, with a lead, which one leads); Stop All Work
//!   and Disband Room…. Bots can't be added or removed once a room exists.

use std::collections::BTreeSet;
use std::rc::Rc;

use conduit_components::ActiveConduitTheme as _;
use conduit_components::views::kit::{Button, Segment, Segmented, grouped_section};
use conduit_protocol::{
    HermesRoomContextDto, HermesRoomContextEdit, HermesRoomCreate, HermesRoomMemberState,
    HermesRoomRename, HermesRoomRouting, HermesRoomView, NoticeLevel, methods,
};
use gpui_kit::component::input::{InputEvent, InputState, Textarea, TextareaState};
use gpui_kit::prelude::*;
use gpui_kit::{
    AnyElement, App, AsyncApp, Context, ElementId, Entity, Focusable as _, FontWeight, Role,
    SharedString, Subscription, WeakEntity, Window, div, px, relative,
};

use crate::l10n::{ActiveL10n as _, L10n};
use crate::shell::sheet::{SheetSpec, present_sheet};
use crate::stores::Stores;
use crate::stores::navigation::AreaItem;
use crate::views::forms;
use crate::views::hermes_faces;
use crate::views::hermes_room::format_elapsed;
use crate::views::hermes_rooms::{self, failure_text};
use crate::views::settings::controls::checkbox;
use crate::views::sheet::{self, SheetBody};

/// The sheets' width.
pub const WIDTH: f32 = 480.;

/// Hermes seats two to six bots in a room.
pub const MIN_SEATS: usize = 2;
pub const MAX_SEATS: usize = 6;

/// The longest room name, purpose and notes Hermes takes.
const MAX_NAME: usize = 200;
const MAX_PURPOSE: usize = 500;
const MAX_NOTES_BYTES: usize = 4096;

/// A length as conduitd and Hermes count it (UTF-16 units): an emoji is
/// two.
fn units(text: &str) -> usize {
    text.encode_utf16().count()
}

fn sheet_title(id: &'static str, text: String, cx: &App) -> AnyElement {
    let t = cx.conduit();
    div()
        .id(id)
        .role(Role::Heading)
        .text_size(px(t.metrics.body + 2.))
        .font_weight(FontWeight::SEMIBOLD)
        .child(text)
        .into_any_element()
}

fn sheet_note(text: String, cx: &App) -> AnyElement {
    let t = cx.conduit();
    div()
        .text_size(px(t.metrics.small + 0.5))
        .line_height(relative(1.4))
        .text_color(t.roles.text_subtle)
        .child(text)
        .into_any_element()
}

/// Opens room `id`, made under generation `asked_in` -- only if the rooms
/// store is still there when this runs (it runs deferred, after the sheet
/// went: another account, gateway or connection may have taken charge in
/// between).
fn open_made_room(stores: &Stores, id: String, asked_in: u64, cx: &mut App) {
    if stores.hermes_rooms.read(cx).generation() != asked_in {
        return;
    }
    stores
        .navigation
        .update(cx, |n, cx| n.open_item(AreaItem::HermesRoom(id), cx));
}

// ── New Room ───────────────────────────────────────────────────────────

/// Opens New Room on the main window.
pub fn open_create(stores: Stores, window: &mut Window, cx: &mut App) {
    if !stores.hermes_rooms.read(cx).can_create() {
        return;
    }
    sheet::open(window, WIDTH, cx, move |w, cx| {
        CreateRoomSheet::new(stores, w, cx)
    });
}

pub struct CreateRoomSheet {
    stores: Stores,
    pub name: Entity<InputState>,
    /// The bots picked, in the order picked.
    pub picked: Vec<String>,
    creating: bool,
    pub failure: Option<String>,
    /// The Hermes connection the sheet opened on: the room is made there or
    /// not at all.
    connection: Option<String>,
    /// The rooms store's generation when it opened (its account, gateway and
    /// connection): New Room makes nothing, and opens nothing, once it moved.
    bound: u64,
    _subscriptions: Vec<Subscription>,
}

impl CreateRoomSheet {
    pub fn new(stores: Stores, window: &mut Window, cx: &mut Context<Self>) -> Self {
        let l = cx.l10n().clone();
        let name = forms::input(l.hermes_room_name_hint(), false, window, cx);
        name.read(cx).focus_handle(cx).focus(window, cx);
        let subscriptions = vec![
            cx.subscribe_in(
                &name,
                window,
                |this, _, e: &InputEvent, window, cx| match e {
                    InputEvent::Change => {
                        this.failure = None;
                        cx.notify();
                    }
                    InputEvent::PressEnter { .. } => this.create(window, cx),
                    _ => {}
                },
            ),
            cx.observe(&stores.hermes_rooms, |this, _, cx| {
                // A bot no longer seatable is unpicked: Create counts only
                // bots it can seat.
                let seatable = this.seatable(cx);
                this.picked.retain(|n| seatable.contains(n));
                cx.notify()
            }),
        ];
        let mut subscriptions = subscriptions;
        subscriptions.push(sheet::close_with_account(&stores, cx));
        let connection = stores.hermes_rooms.read(cx).connection();
        let bound = stores.hermes_rooms.read(cx).generation();
        Self {
            stores,
            name,
            picked: vec![],
            creating: false,
            failure: None,
            connection,
            bound,
            _subscriptions: subscriptions,
        }
    }

    /// The bots a new room may seat, by name, in the roster's order.
    fn seatable(&self, cx: &App) -> Vec<String> {
        let rooms = self.stores.hermes_rooms.read(cx);
        let seatable: BTreeSet<&String> = rooms
            .rooms
            .as_ref()
            .map(|r| r.seatable.iter().collect())
            .unwrap_or_default();
        rooms
            .bot_list()
            .iter()
            .filter(|b| seatable.contains(&b.name))
            .map(|b| b.name.clone())
            .collect()
    }

    pub fn toggle(&mut self, name: &str, cx: &mut Context<Self>) {
        self.failure = None;
        if let Some(at) = self.picked.iter().position(|n| n == name) {
            self.picked.remove(at);
        } else if self.picked.len() < MAX_SEATS {
            self.picked.push(name.to_string());
        }
        cx.notify();
    }

    pub fn set_name(&mut self, text: &str, window: &mut Window, cx: &mut Context<Self>) {
        let value = text.to_string();
        self.name.update(cx, |s, cx| s.set_value(value, window, cx));
        cx.notify();
    }

    fn ready(&self, cx: &App) -> bool {
        let name = forms::text(&self.name, cx);
        !self.creating
            && !name.trim().is_empty()
            && units(name.trim()) <= MAX_NAME
            && (MIN_SEATS..=MAX_SEATS).contains(&self.picked.len())
    }

    pub fn create(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if !self.ready(cx) {
            return;
        }
        let Some(rpc) = self.stores.hermes_rooms.read(cx).rpc() else {
            return;
        };
        // Opened for another account, gateway or connection: nothing is made
        // under the one in charge now.
        if self.stores.hermes_rooms.read(cx).generation() != self.bound {
            self.failure = Some(cx.l10n().hermes_room_create_failed());
            cx.notify();
            return;
        }
        self.creating = true;
        self.failure = None;
        cx.notify();
        let asked_in = self.bound;
        let call = rpc.call::<methods::HermesRoomsCreate>(&HermesRoomCreate {
            name: forms::text(&self.name, cx).trim().to_string(),
            bots: self.picked.clone(),
            connection: self.connection.clone(),
        });
        let handle = window.window_handle();
        let stores = self.stores.clone();
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result = call.await;
            let _ = handle.update(cx, |_, _, cx| {
                let _ = this.update(cx, |s, cx| {
                    s.creating = false;
                    match result {
                        // Made, but the store moved on meanwhile: the room is
                        // not listed, opened, or its sheet closed under the
                        // account, gateway or connection in charge now.
                        Ok(_) if stores.hermes_rooms.read(cx).generation() != asked_in => {}
                        Ok(room) => {
                            let id = room.id.clone();
                            stores.hermes_rooms.update(cx, |h, cx| {
                                h.patch_listed(room, asked_in, cx);
                                h.refresh(cx);
                            });
                            let this = cx.entity();
                            if sheet::current::<Self>(cx).is_some_and(|open| open == this) {
                                sheet::dismiss(cx);
                            }
                            let stores = stores.clone();
                            cx.defer(move |cx| open_made_room(&stores, id, asked_in, cx));
                        }
                        Err(e) => {
                            log::warn!("hermes.rooms.create: {e}");
                            let l = cx.l10n().clone();
                            s.failure = Some(match e.args.get("detail") {
                                Some(d) if !d.trim().is_empty() => l.hermes_room_refused(d),
                                _ => l.hermes_room_create_failed(),
                            });
                        }
                    }
                    cx.notify();
                });
            });
        })
        .detach();
    }
}

impl SheetBody for CreateRoomSheet {
    fn busy(&self, _: &App) -> bool {
        self.creating
    }

    fn footer(&mut self, _: &mut Window, cx: &mut Context<Self>) -> Option<AnyElement> {
        let l = cx.l10n().clone();
        let view = cx.entity().downgrade();
        let cancel = view.clone();
        Some(
            div()
                .w_full()
                .flex()
                .items_center()
                .gap(px(8.))
                .child(div().flex_1())
                .child(
                    Button::new("hermes-room-create-cancel", l.cancel()).on_click(Rc::new(
                        move |_, window, cx| {
                            let _ = cancel.update(cx, |v, cx| v.cancel(window, cx));
                        },
                    )),
                )
                .child(
                    Button::new("hermes-room-create-submit", l.create())
                        .primary()
                        .disabled(!self.ready(cx))
                        .on_click(Rc::new(move |_, window, cx| {
                            let _ = view.update(cx, |v, cx| v.create(window, cx));
                        })),
                )
                .into_any_element(),
        )
    }

    /// A room name typed or bots picked, not made yet: Quit asks first, as
    /// Cancel does.
    fn unsaved(&self, cx: &App) -> bool {
        !forms::text(&self.name, cx).trim().is_empty() || !self.picked.is_empty()
    }

    fn cancel(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.creating {
            return;
        }
        if !self.unsaved(cx) {
            sheet::dismiss(cx);
            return;
        }
        let l = cx.l10n().clone();
        let spec = SheetSpec::new(
            l.desktop_discard_changes_title(),
            l.desktop_discard_changes_message(),
            l.desktop_discard(),
            l.cancel(),
        )
        .destructive();
        let ask = present_sheet(window, spec, cx);
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            if !ask.await {
                return;
            }
            // Only this sheet, if it is still the one down when the answer
            // comes.
            let _ = this.update(cx, |_, cx| {
                let this = cx.entity();
                if sheet::current::<Self>(cx).is_some_and(|open| open == this) {
                    sheet::dismiss(cx);
                }
            });
        })
        .detach();
    }

    fn label(&self, cx: &App) -> SharedString {
        cx.l10n().hermes_room_new().into()
    }
}

impl Render for CreateRoomSheet {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let l = cx.l10n().clone();
        let t = cx.conduit().clone();
        let seatable = self.seatable(cx);
        let rooms = self.stores.hermes_rooms.read(cx);
        let full = self.picked.len() >= MAX_SEATS;
        let bots: Vec<(String, String, hermes_faces::Face)> = rooms
            .bot_list()
            .iter()
            .filter(|b| seatable.contains(&b.name))
            .map(|b| {
                (
                    b.name.clone(),
                    b.title.clone(),
                    hermes_faces::bot_face(b, rooms),
                )
            })
            .collect();
        let rows: Vec<AnyElement> = bots
            .into_iter()
            .map(|(name, title, face)| {
                let on = self.picked.contains(&name);
                let enabled = !self.creating && (on || !full);
                let view = cx.entity().downgrade();
                let toggle_name = name.clone();
                let toggle: conduit_components::views::kit::ClickHandler =
                    Rc::new(move |_, _, cx| {
                        let _ = view.update(cx, |v, cx| v.toggle(&toggle_name, cx));
                    });
                let row_toggle = toggle.clone();
                div()
                    .id(ElementId::Name(
                        format!("hermes-room-create-bot-{name}").into(),
                    ))
                    .px(px(12.))
                    .h(px(40.))
                    .flex()
                    .items_center()
                    .gap(px(10.))
                    .when(enabled, |d| {
                        d.cursor_pointer()
                            .on_click(move |e, w, cx| row_toggle(e, w, cx))
                    })
                    .when(!enabled, |d| d.opacity(0.5))
                    .child(checkbox(
                        ElementId::Name(format!("hermes-room-create-check-{name}").into()),
                        title.clone(),
                        on,
                        if enabled {
                            toggle
                        } else {
                            Rc::new(|_, _, _| {})
                        },
                        window,
                        cx,
                    ))
                    .child(hermes_faces::face(
                        ElementId::Name(format!("hermes-room-create-face-{name}").into()),
                        &face,
                        24.,
                        false,
                        true,
                    ))
                    .child(div().flex_1().truncate().child(SharedString::from(title)))
                    .into_any_element()
            })
            .collect();
        let hint = if seatable.len() < MIN_SEATS {
            l.hermes_room_needs_bots()
        } else {
            l.hermes_room_create_hint()
        };
        let mut body = vec![
            div()
                .flex()
                .flex_col()
                .gap(px(4.))
                .child(sheet_title("sheet-title", l.hermes_room_new(), cx))
                .child(sheet_note(hint, cx))
                .into_any_element(),
            grouped_section(
                None,
                vec![
                    forms::field(
                        l.hermes_room_name_hint(),
                        &self.name,
                        None,
                        None,
                        window,
                        cx,
                    )
                    .into_any_element(),
                ],
                None,
                cx,
            )
            .into_any_element(),
            grouped_section(Some(l.hermes_room_members().into()), rows, None, cx)
                .into_any_element(),
        ];
        if let Some(failure) = &self.failure {
            body.push(
                forms::form_error("hermes-room-create-failure", failure.clone(), cx)
                    .into_any_element(),
            );
        }
        let _ = &t;
        div()
            .id("hermes-room-create")
            .w_full()
            .flex()
            .flex_col()
            .gap(px(16.))
            .children(body)
    }
}

// ── Room Info ──────────────────────────────────────────────────────────

/// Opens Room Info for `room_id` on the main window; `rename`: its name
/// field first (Rename…).
pub fn open_info(stores: Stores, room_id: &str, rename: bool, window: &mut Window, cx: &mut App) {
    let room_id = room_id.to_string();
    sheet::open(window, WIDTH, cx, move |w, cx| {
        RoomInfoSheet::new(stores, room_id, rename, w, cx)
    });
}

/// What the form holds.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct RoomEdit {
    pub name: String,
    pub purpose: String,
    pub notes: String,
    pub routing: Option<HermesRoomRouting>,
    pub lead: Option<String>,
}

impl RoomEdit {
    fn of(view: &HermesRoomView) -> Option<Self> {
        let room = view.room.as_ref()?;
        let context = view.context.clone().unwrap_or_default();
        Some(Self {
            name: room.name.clone(),
            purpose: context.purpose,
            notes: context.notes,
            routing: context.routing,
            lead: context.lead_member_id,
        })
    }

    fn context(&self) -> HermesRoomContextDto {
        HermesRoomContextDto {
            purpose: self.purpose.trim().to_string(),
            notes: self.notes.trim().to_string(),
            routing: self.routing,
            lead_member_id: (self.routing == Some(HermesRoomRouting::Lead))
                .then(|| self.lead.clone())
                .flatten(),
        }
    }
}

pub struct RoomInfoSheet {
    stores: Stores,
    pub room_id: String,
    pub name: Entity<InputState>,
    pub purpose: Entity<InputState>,
    pub notes: Entity<TextareaState>,
    pub edit: RoomEdit,
    initial: Option<RoomEdit>,
    /// The Hermes connection the room's settings were read on: saved there
    /// or not at all.
    connection: Option<String>,
    /// The rooms store's generation when it opened (its account, gateway and
    /// connection): Save, Stop Work and Disband refuse once it moved, and a
    /// Save's answer closes it only while it is still current.
    bound: u64,
    saving: bool,
    pub failure: Option<String>,
    _subscriptions: Vec<Subscription>,
}

impl RoomInfoSheet {
    pub fn new(
        stores: Stores,
        room_id: String,
        rename: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Self {
        let l = cx.l10n().clone();
        let name = forms::input(l.hermes_room_name_hint(), false, window, cx);
        let purpose = forms::input(l.hermes_room_purpose_hint(), false, window, cx);
        let notes = cx.new(|cx| {
            TextareaState::new(window, cx)
                .auto_grow(3, 8)
                .placeholder(l.hermes_room_notes_hint())
        });
        let changed = |field: fn(&mut RoomEdit) -> &mut String| {
            move |this: &mut Self,
                  state: &Entity<InputState>,
                  e: &InputEvent,
                  window: &mut Window,
                  cx: &mut Context<Self>| {
                match e {
                    InputEvent::Change => {
                        *field(&mut this.edit) = state.read(cx).value().to_string();
                        this.failure = None;
                        cx.notify();
                    }
                    InputEvent::PressEnter { .. } => this.save(window, cx),
                    _ => {}
                }
            }
        };
        let subscriptions = vec![
            cx.subscribe_in(&name, window, changed(|e| &mut e.name)),
            cx.subscribe_in(&purpose, window, changed(|e| &mut e.purpose)),
            cx.subscribe_in(&notes, window, |this, state, e: &InputEvent, _, cx| {
                if matches!(e, InputEvent::Change) {
                    this.edit.notes = state.read(cx).value().to_string();
                    this.failure = None;
                    cx.notify();
                }
            }),
            // Settings that arrive after the sheet opened fill it once;
            // the bots' states follow the room.
            cx.observe_in(&stores.hermes_rooms, window, |this, _, window, cx| {
                if this.initial.is_none() && this.current(cx) {
                    this.adopt_current(window, cx);
                }
                cx.notify()
            }),
            sheet::close_with_account(&stores, cx),
        ];
        let bound = stores.hermes_rooms.read(cx).generation();
        let mut this = Self {
            stores,
            room_id,
            name,
            purpose,
            notes,
            edit: RoomEdit::default(),
            initial: None,
            connection: None,
            bound,
            saving: false,
            failure: None,
            _subscriptions: subscriptions,
        };
        this.adopt_current(window, cx);
        if rename {
            this.name.read(cx).focus_handle(cx).focus(window, cx);
        }
        this
    }

    fn view<'a>(&self, cx: &'a App) -> Option<&'a HermesRoomView> {
        self.stores.hermes_rooms.read(cx).view(&self.room_id)
    }

    /// The store is still on the account, gateway and connection the sheet
    /// opened for.
    fn current(&self, cx: &App) -> bool {
        self.stores.hermes_rooms.read(cx).generation() == self.bound
    }

    /// Refuses an action once the sheet's binding moved on, saying so; the
    /// words typed stay.
    fn refuse_if_stale(&mut self, cx: &mut Context<Self>) -> bool {
        if self.current(cx) {
            return false;
        }
        self.failure = Some(cx.l10n().hermes_room_action_failed());
        cx.notify();
        true
    }

    fn adopt_current(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(view) = self.view(cx) else {
            return;
        };
        let connection = view.connection.clone();
        let Some(edit) = RoomEdit::of(view) else {
            return;
        };
        self.connection = connection;
        self.adopt(edit, window, cx);
    }

    /// Shows `edit` as saved; edits made since are replaced.
    fn adopt(&mut self, edit: RoomEdit, window: &mut Window, cx: &mut Context<Self>) {
        let (name, purpose, notes) = (edit.name.clone(), edit.purpose.clone(), edit.notes.clone());
        self.name.update(cx, |s, cx| s.set_value(name, window, cx));
        self.purpose
            .update(cx, |s, cx| s.set_value(purpose, window, cx));
        self.notes
            .update(cx, |s, cx| s.set_value(notes, window, cx));
        self.initial = Some(edit.clone());
        self.edit = edit;
        cx.notify();
    }

    pub fn is_dirty(&self) -> bool {
        self.initial.as_ref().is_some_and(|i| {
            let (a, b) = (&self.edit, i);
            a.name.trim() != b.name.trim() || a.context() != b.context()
        })
    }

    fn notes_too_long(&self) -> bool {
        self.edit.notes.trim().len() > MAX_NOTES_BYTES
    }

    fn valid(&self) -> bool {
        let name = self.edit.name.trim();
        !name.is_empty()
            && units(name) <= MAX_NAME
            && units(self.edit.purpose.trim()) <= MAX_PURPOSE
            && !self.notes_too_long()
            && (self.edit.routing != Some(HermesRoomRouting::Lead) || self.edit.lead.is_some())
    }

    fn usable(&self, cx: &App) -> bool {
        self.view(cx).is_some_and(|v| !v.gone)
    }

    fn can_save(&self, cx: &App) -> bool {
        !self.saving && self.is_dirty() && self.valid() && self.usable(cx)
    }

    pub fn set_routing(&mut self, routing: HermesRoomRouting, cx: &mut Context<Self>) {
        self.edit.routing = Some(routing);
        if self.edit.lead.is_none() {
            self.edit.lead = self
                .view(cx)
                .and_then(|v| v.room.as_ref())
                .and_then(|r| r.members.first())
                .map(|m| m.member_id.clone());
        }
        self.failure = None;
        cx.notify();
    }

    pub fn set_lead(&mut self, member: &str, cx: &mut Context<Self>) {
        self.edit.lead = Some(member.to_string());
        cx.notify();
    }

    /// Types into a field, as the user would (the E2E).
    pub fn type_into(
        &mut self,
        field: &str,
        text: &str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let value = text.to_string();
        match field {
            "name" => {
                self.name.update(cx, |s, cx| s.set_value(value, window, cx));
                self.edit.name = text.to_string();
            }
            "purpose" => {
                self.purpose
                    .update(cx, |s, cx| s.set_value(value, window, cx));
                self.edit.purpose = text.to_string();
            }
            _ => {
                self.notes
                    .update(cx, |s, cx| s.set_value(value, window, cx));
                self.edit.notes = text.to_string();
            }
        }
        cx.notify();
    }

    /// Saves the name (`hermes.rooms.rename`) and the purpose, notes and
    /// who answers (`hermes.rooms.saveContext`), each only when changed.
    pub fn save(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.refuse_if_stale(cx) || !self.can_save(cx) {
            return;
        }
        let Some(rpc) = self.stores.hermes_rooms.read(cx).rpc() else {
            return;
        };
        let Some(initial) = self.initial.clone() else {
            return;
        };
        self.saving = true;
        self.failure = None;
        cx.notify();
        let edit = self.edit.clone();
        let asked_in = self.bound;
        let rename = (edit.name.trim() != initial.name.trim()).then(|| {
            rpc.call::<methods::HermesRoomsRename>(&HermesRoomRename {
                room_id: self.room_id.clone(),
                name: edit.name.trim().to_string(),
                connection: self.connection.clone(),
            })
        });
        let context = (edit.context() != initial.context()).then(|| {
            rpc.call::<methods::HermesRoomsSaveContext>(&HermesRoomContextEdit {
                room_id: self.room_id.clone(),
                context: edit.context(),
                connection: self.connection.clone(),
            })
        });
        let handle = window.window_handle();
        let stores = self.stores.clone();
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let renamed = match rename {
                Some(call) => Some(call.await),
                None => None,
            };
            let saved = match context {
                Some(call) => Some(call.await),
                None => None,
            };
            let _ = handle.update(cx, |_, _, cx| {
                let _ = this.update(cx, |s, cx| {
                    s.saving = false;
                    let l = cx.l10n().clone();
                    // What went through is saved, whatever else failed: the
                    // next Save compares with it.
                    if let Some(initial) = &mut s.initial {
                        if matches!(renamed, Some(Ok(_))) {
                            initial.name = edit.name.clone();
                        }
                        if matches!(saved, Some(Ok(_))) {
                            let context = edit.clone();
                            initial.purpose = context.purpose;
                            initial.notes = context.notes;
                            initial.routing = context.routing;
                            initial.lead = context.lead;
                        }
                    }
                    let error = renamed
                        .as_ref()
                        .and_then(|r| r.as_ref().err())
                        .or_else(|| saved.as_ref().and_then(|r| r.as_ref().err()));
                    if let Some(e) = error {
                        log::warn!("hermes room save: {e}");
                        s.failure = Some(failure_text(e, &l));
                        if let Some(Ok(room)) = renamed {
                            stores
                                .hermes_rooms
                                .update(cx, |h, cx| h.patch_listed(room, asked_in, cx));
                        }
                        cx.notify();
                        return;
                    }
                    if let Some(Ok(room)) = renamed {
                        stores
                            .hermes_rooms
                            .update(cx, |h, cx| h.patch_listed(room, asked_in, cx));
                    }
                    // Words typed while it saved are still to save: the
                    // sheet stays, with what was saved as its baseline. Nor
                    // does it close once the store moved on meanwhile.
                    if s.edit != edit || stores.hermes_rooms.read(cx).generation() != asked_in {
                        cx.notify();
                        return;
                    }
                    stores
                        .toasts
                        .update(cx, |t, cx| t.show(NoticeLevel::Info, l.saved(), cx));
                    let this = cx.entity();
                    if sheet::current::<Self>(cx).is_some_and(|open| open == this) {
                        sheet::dismiss(cx);
                    }
                });
            });
        })
        .detach();
    }

    fn stop(&mut self, cx: &mut Context<Self>) {
        if self.refuse_if_stale(cx) {
            return;
        }
        // The sheet stays, edits and all: Stop Work changes nothing it shows.
        hermes_rooms::stop(&self.stores, &self.room_id, cx);
    }

    /// Disband, asked over the sheet: it stays (with its edits) until the
    /// room is disbanded, and closes only then.
    fn disband(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.refuse_if_stale(cx) {
            return;
        }
        let this = cx.entity().downgrade();
        hermes_rooms::confirm_disband_then(&self.stores, &self.room_id, window, cx, move |cx| {
            if let Some(this) = this.upgrade()
                && sheet::current::<Self>(cx).is_some_and(|open| open == this)
            {
                sheet::dismiss(cx);
            }
        });
    }

    fn members(&self, l: &L10n, window: &mut Window, cx: &mut Context<Self>) -> Vec<AnyElement> {
        let t = cx.conduit().clone();
        let r = t.roles;
        let Some(view) = self.view(cx).cloned() else {
            return vec![];
        };
        let Some(room) = view.room.clone() else {
            return vec![];
        };
        let picking = self.edit.routing == Some(HermesRoomRouting::Lead) && !self.saving;
        let received = self
            .stores
            .hermes_rooms
            .read(cx)
            .room
            .as_ref()
            .map_or_else(std::time::Instant::now, |o| o.received);
        let _ = window;
        room.members
            .iter()
            .map(|member| {
                let rooms = self.stores.hermes_rooms.read(cx);
                let face = hermes_faces::member_face(member, rooms);
                let status = view
                    .members
                    .iter()
                    .find(|m| m.member_id == member.member_id);
                let busy = status.is_some_and(|s| {
                    matches!(
                        s.state,
                        HermesRoomMemberState::Working | HermesRoomMemberState::Stalled
                    )
                });
                let failed = status.is_some_and(|s| s.state == HermesRoomMemberState::Failed);
                let detail = status.and_then(|s| {
                    let elapsed = s
                        .elapsed_ms
                        .map(|ms| format_elapsed(ms + received.elapsed().as_millis() as i64));
                    match s.state {
                        HermesRoomMemberState::Working => {
                            let mut parts = vec![l.hermes_room_working()];
                            parts.extend(s.tool.clone());
                            parts.extend(elapsed);
                            Some(parts.join(" · "))
                        }
                        HermesRoomMemberState::Stalled => {
                            Some(l.hermes_room_quiet(&elapsed.unwrap_or_else(|| format_elapsed(0))))
                        }
                        HermesRoomMemberState::Queued => Some(l.hermes_room_waiting()),
                        HermesRoomMemberState::Failed => Some(match &s.reason {
                            Some(reason) => format!("{}: {reason}", l.hermes_room_turn_failed()),
                            None => l.hermes_room_turn_failed(),
                        }),
                        HermesRoomMemberState::Unavailable => {
                            Some(l.hermes_room_member_unavailable())
                        }
                        _ => None,
                    }
                });
                let lead = self.edit.routing == Some(HermesRoomRouting::Lead)
                    && self.edit.lead.as_deref() == Some(member.member_id.as_str());
                let view = cx.entity().downgrade();
                let pick = member.member_id.clone();
                let mut spoken = vec![member.name.clone(), format!("@{}", member.handle)];
                spoken.extend(detail.clone());
                if lead {
                    spoken.push(l.hermes_room_lead());
                }
                div()
                    .id(ElementId::Name(
                        format!("hermes-room-member-{}", member.member_id).into(),
                    ))
                    .role(if picking {
                        Role::RadioButton
                    } else {
                        Role::ListItem
                    })
                    .aria_label(SharedString::from(spoken.join(", ")))
                    .when(picking, |d| {
                        d.aria_toggled(if lead {
                            gpui_kit::Toggled::True
                        } else {
                            gpui_kit::Toggled::False
                        })
                        .cursor_pointer()
                        .hover(|s| s.bg(r.overlay_hover))
                        .on_click(move |_, _, cx| {
                            let _ = view.update(cx, |v, cx| v.set_lead(&pick, cx));
                        })
                    })
                    .px(px(12.))
                    .min_h(px(44.))
                    .flex()
                    .items_center()
                    .gap(px(10.))
                    .child(hermes_faces::face(
                        ElementId::Name(
                            format!("hermes-room-member-face-{}", member.member_id).into(),
                        ),
                        &face,
                        28.,
                        busy,
                        cx.reduce_motion(),
                    ))
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .flex()
                            .flex_col()
                            .child(
                                div()
                                    .flex()
                                    .gap(px(6.))
                                    .child(
                                        div()
                                            .truncate()
                                            .child(SharedString::from(member.name.clone())),
                                    )
                                    .child(
                                        div().text_color(r.text_subtle).child(SharedString::from(
                                            format!("@{}", member.handle),
                                        )),
                                    ),
                            )
                            .when_some(detail, |d, text| {
                                d.child(
                                    div()
                                        .truncate()
                                        .text_size(px(t.metrics.small))
                                        .text_color(if failed { r.danger } else { r.text_subtle })
                                        .child(SharedString::from(text)),
                                )
                            }),
                    )
                    .when(lead, |d| {
                        d.child(
                            div()
                                .flex()
                                .items_center()
                                .gap(px(4.))
                                .text_size(px(t.metrics.small))
                                .font_weight(FontWeight::SEMIBOLD)
                                .child(l.hermes_room_lead())
                                .child(conduit_components::assets::icon(
                                    conduit_components::assets::IconName::Check,
                                    12.,
                                    r.text,
                                )),
                        )
                    })
                    .into_any_element()
            })
            .collect()
    }
}

impl SheetBody for RoomInfoSheet {
    fn busy(&self, _: &App) -> bool {
        self.saving
    }

    /// Edits not saved yet: Quit asks first, as Cancel does.
    fn unsaved(&self, _: &App) -> bool {
        self.is_dirty()
    }

    fn footer(&mut self, _: &mut Window, cx: &mut Context<Self>) -> Option<AnyElement> {
        let l = cx.l10n().clone();
        let view = self.view(cx).cloned();
        let running = view.as_ref().is_some_and(|v| v.running && !v.gone);
        let gone = view.as_ref().is_none_or(|v| v.gone);
        let entity = cx.entity().downgrade();
        let (stop, disband, cancel) = (entity.clone(), entity.clone(), entity.clone());
        Some(
            div()
                .w_full()
                .flex()
                .items_center()
                .gap(px(8.))
                .when(running, |d| {
                    d.child(
                        Button::new("hermes-room-info-stop", l.hermes_room_stop_work()).on_click(
                            Rc::new(move |_, _, cx| {
                                let _ = stop.update(cx, |v, cx| v.stop(cx));
                            }),
                        ),
                    )
                })
                .when(!gone, |d| {
                    d.child(
                        Button::new("hermes-room-disband", l.desktop_hermes_disband_room_menu())
                            .danger()
                            .on_click(Rc::new(move |_, window, cx| {
                                let _ = disband.update(cx, |v, cx| v.disband(window, cx));
                            })),
                    )
                })
                .child(div().flex_1())
                .child(
                    Button::new("hermes-room-info-cancel", l.cancel()).on_click(Rc::new(
                        move |_, window, cx| {
                            let _ = cancel.update(cx, |v, cx| v.cancel(window, cx));
                        },
                    )),
                )
                .child(
                    Button::new("hermes-room-save", l.save())
                        .primary()
                        .disabled(!self.can_save(cx))
                        .on_click(Rc::new(move |_, window, cx| {
                            let _ = entity.update(cx, |v, cx| v.save(window, cx));
                        })),
                )
                .into_any_element(),
        )
    }

    fn cancel(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.saving {
            return;
        }
        if !self.is_dirty() {
            sheet::dismiss(cx);
            return;
        }
        let l = cx.l10n().clone();
        let spec = SheetSpec::new(
            l.desktop_discard_changes_title(),
            l.desktop_discard_changes_message(),
            l.desktop_discard(),
            l.cancel(),
        )
        .destructive();
        let ask = present_sheet(window, spec, cx);
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            if !ask.await {
                return;
            }
            // Only this sheet, if it is still the one down when the answer
            // comes.
            let _ = this.update(cx, |_, cx| {
                let this = cx.entity();
                if sheet::current::<Self>(cx).is_some_and(|open| open == this) {
                    sheet::dismiss(cx);
                }
            });
        })
        .detach();
    }

    fn label(&self, cx: &App) -> SharedString {
        cx.l10n().hermes_room_info_title().into()
    }
}

impl Render for RoomInfoSheet {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let l = cx.l10n().clone();
        let t = cx.conduit().clone();
        let view = self.view(cx).cloned();
        let Some(room) = view.as_ref().and_then(|v| v.room.clone()) else {
            return div()
                .id("hermes-room-info")
                .flex()
                .flex_col()
                .gap(px(16.))
                .child(sheet_title("sheet-title", l.hermes_room_info_title(), cx))
                .child(sheet_note(l.loading_short(), cx));
        };
        let rooms = self.stores.hermes_rooms.read(cx);
        let faces: Vec<hermes_faces::Face> =
            crate::stores::hermes_rooms::HermesRoomsStore::faces(&room)
                .iter()
                .map(|m| hermes_faces::member_face(m, rooms))
                .collect();
        let header = div()
            .flex()
            .items_center()
            .gap(px(12.))
            .child(hermes_faces::stack(
                "hermes-room-info-faces",
                &faces,
                44.,
                true,
            ))
            .child(
                div()
                    .flex()
                    .flex_col()
                    .gap(px(2.))
                    .child(sheet_title("sheet-title", l.hermes_room_info_title(), cx))
                    .child(sheet_note(
                        l.hermes_room_bot_count(room.members.len() as i64),
                        cx,
                    )),
            )
            .into_any_element();
        let modes = view
            .as_ref()
            .map(|v| v.routing_modes.clone())
            .unwrap_or_default();
        let mut body = vec![
            header,
            grouped_section(
                None,
                vec![
                    forms::field(
                        l.hermes_room_name_hint(),
                        &self.name,
                        None,
                        None,
                        window,
                        cx,
                    )
                    .into_any_element(),
                    forms::field(
                        l.hermes_room_purpose(),
                        &self.purpose,
                        None,
                        None,
                        window,
                        cx,
                    )
                    .into_any_element(),
                ],
                None,
                cx,
            )
            .into_any_element(),
            grouped_section(
                Some(l.hermes_room_notes().into()),
                vec![
                    div()
                        .id("hermes-room-notes")
                        .p(px(12.))
                        .child(Textarea::new(&self.notes).aria_label(l.hermes_room_notes()))
                        .into_any_element(),
                ],
                self.notes_too_long()
                    .then(|| l.hermes_room_notes_too_long().into()),
                cx,
            )
            .into_any_element(),
        ];
        if let Some(routing) = self.edit.routing {
            let selected = modes.iter().position(|m| *m == routing).unwrap_or(0);
            let labels: Vec<Segment> = modes
                .iter()
                .map(|m| {
                    Segment::new(match m {
                        HermesRoomRouting::Lead => l.hermes_room_routing_lead(),
                        HermesRoomRouting::Auto => l.hermes_room_routing_auto(),
                        _ => l.hermes_room_everyone(),
                    })
                })
                .collect();
            let view = cx.entity().downgrade();
            let pick_modes = modes.clone();
            let segmented = Segmented::new(
                "hermes-room-routing",
                l.hermes_room_who_answers(),
                labels,
                selected,
            )
            .on_select(Rc::new(move |ix, _, cx| {
                if let Some(mode) = pick_modes.get(ix).copied() {
                    let _ = view.update(cx, |v, cx| v.set_routing(mode, cx));
                }
            }));
            let hint = match routing {
                HermesRoomRouting::Lead => l.hermes_room_routing_lead_hint(),
                HermesRoomRouting::Auto => l.hermes_room_routing_auto_hint(),
                _ => l.hermes_room_routing_everyone_hint(),
            };
            body.push(
                grouped_section(
                    Some(l.hermes_room_who_answers().into()),
                    vec![div().p(px(12.)).child(segmented).into_any_element()],
                    Some(hint.into()),
                    cx,
                )
                .into_any_element(),
            );
        }
        let members = self.members(&l, window, cx);
        body.push(
            grouped_section(
                Some(l.hermes_room_members().into()),
                members,
                Some(l.hermes_room_members_fixed().into()),
                cx,
            )
            .into_any_element(),
        );
        if let Some(failure) = &self.failure {
            body.push(
                forms::form_error("hermes-room-info-failure", failure.clone(), cx)
                    .into_any_element(),
            );
        }
        let _ = &t;
        div()
            .id("hermes-room-info")
            .w_full()
            .flex()
            .flex_col()
            .gap(px(16.))
            .on_key_down(cx.listener(|this, e: &gpui_kit::KeyDownEvent, window, cx| {
                let k = &e.keystroke;
                if k.key == "enter" && k.modifiers.platform {
                    this.save(window, cx);
                    cx.stop_propagation();
                }
            }))
            .children(body)
    }
}

#[cfg(test)]
mod tests {
    use std::cell::Cell;
    use std::rc::Rc;
    use std::time::Duration;

    use conduit_protocol::{Event, HermesRoomDto, HermesRoomView, RpcError, methods};
    use gpui_kit::{Entity, TestAppContext, VisualTestContext};
    use serde_json::json;

    use super::{CreateRoomSheet, RoomInfoSheet};
    use crate::stores::Stores;
    use crate::stores::navigation::{AreaItem, Selection};
    use crate::stores::rpc::fake::FakeDaemon;
    use crate::views::sheet::SheetBody as _;

    fn room() -> HermesRoomView {
        serde_json::from_value(json!({
            "roomId": "r1", "loaded": true, "running": true,
            "room": {"id": "r1", "name": "Greenhouse crew", "members": [
                {"memberId": "fern", "profile": "fern", "handle": "fern", "name": "Fern"},
            ]},
            "context": {"purpose": "Plan the spring beds", "notes": ""},
        }))
        .unwrap()
    }

    fn open<'a>(
        cx: &'a mut TestAppContext,
        daemon: &FakeDaemon,
        tag: &str,
    ) -> (Entity<RoomInfoSheet>, &'a mut VisualTestContext) {
        daemon.returns::<methods::HermesRoomsWatch>(room());
        let scratch =
            std::env::temp_dir().join(format!("conduit-hinfo-{tag}-{}", std::process::id()));
        let stores = cx.update(|cx| {
            crate::views::test_globals(cx);
            Stores::for_test(daemon.rpc(), &scratch, cx)
        });
        stores.hermes_rooms.update(cx, |h, cx| {
            h.show(Some("r1"), cx);
            h.on_event(&Event::HermesRoomsChanged(room()), cx);
        });
        let (sheet, vcx) = cx.add_window_view(move |window, cx| {
            RoomInfoSheet::new(stores, "r1".into(), true, window, cx)
        });
        vcx.run_until_parked();
        (sheet, vcx)
    }

    #[gpui_kit::test]
    fn quit_asks_before_dropping_room_info_typed_but_not_saved(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        let (sheet, vcx) = open(cx, &daemon, "unsaved");
        sheet.read_with(vcx, |s, cx| assert!(!s.unsaved(cx)));
        sheet.update_in(vcx, |s, window, cx| {
            s.type_into("name", "Seed swap", window, cx)
        });
        sheet.read_with(vcx, |s, cx| assert!(s.unsaved(cx)));
    }

    #[gpui_kit::test]
    fn a_save_that_half_failed_keeps_what_was_saved_as_saved(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        daemon.returns::<methods::HermesRoomsRename>(
            serde_json::from_value::<HermesRoomDto>(json!({"id": "r1", "name": "Seed swap"}))
                .unwrap(),
        );
        daemon.once::<methods::HermesRoomsSaveContext>(Err(RpcError::internal("no context")));
        daemon.returns::<methods::HermesRoomsSaveContext>(Default::default());
        let (sheet, vcx) = open(cx, &daemon, "half");
        sheet.update_in(vcx, |s, window, cx| {
            s.type_into("name", "Seed swap", window, cx);
            s.type_into("purpose", "Seed trays", window, cx);
            s.save(window, cx);
        });
        vcx.run_until_parked();
        sheet.read_with(vcx, |s, _| assert!(s.failure.is_some()));
        // The rename went through; the name typed back is a rename of its own.
        sheet.update_in(vcx, |s, window, cx| {
            s.type_into("name", "Greenhouse crew", window, cx);
            s.save(window, cx);
        });
        vcx.run_until_parked();
        let renames = daemon.calls::<methods::HermesRoomsRename>();
        assert_eq!(renames.len(), 2);
        assert_eq!(renames[1]["name"], "Greenhouse crew");
    }

    #[gpui_kit::test]
    fn words_typed_while_room_info_saves_stay_to_save(cx: &mut TestAppContext) {
        let (daemon, stores, vcx) = crate::views::sheet::bench::bench(cx);
        daemon.returns::<methods::HermesRoomsWatch>(room());
        daemon.returns::<methods::HermesRoomsRename>(
            serde_json::from_value::<HermesRoomDto>(json!({"id": "r1", "name": "Seed swap"}))
                .unwrap(),
        );
        stores.hermes_rooms.update(vcx, |h, cx| {
            h.show(Some("r1"), cx);
            h.on_event(&Event::HermesRoomsChanged(room()), cx);
        });
        let sheet = vcx
            .update(|window, cx| {
                crate::views::sheet::open(window, super::WIDTH, cx, move |w, cx| {
                    RoomInfoSheet::new(stores, "r1".into(), true, w, cx)
                })
            })
            .unwrap();
        vcx.run_until_parked();
        let held = daemon.hold::<methods::HermesRoomsRename>();
        sheet.update_in(vcx, |s, window, cx| {
            s.type_into("name", "Seed swap", window, cx);
            s.save(window, cx);
            // Typed while the rename is out.
            s.type_into("name", "Seed swap crew", window, cx);
        });
        drop(held);
        vcx.run_until_parked();
        assert!(
            vcx.update(|_, cx| crate::views::sheet::current::<RoomInfoSheet>(cx))
                .is_some(),
            "the sheet closed over words typed during its save"
        );
        sheet.read_with(vcx, |s, cx| {
            assert_eq!(s.edit.name, "Seed swap crew");
            assert!(s.unsaved(cx), "the words typed meanwhile are still to save");
        });
    }

    fn creatable(daemon: &FakeDaemon) {
        daemon.returns::<methods::HermesBotsList>(
            serde_json::from_value(json!({"available": true, "bots": [
                {"name": "fern", "title": "Fern"}, {"name": "moss", "title": "Moss"},
            ]}))
            .unwrap(),
        );
        daemon.returns::<methods::HermesRoomsList>(
            serde_json::from_value(json!({
                "available": true, "canCreate": true, "seatable": ["fern", "moss"], "rooms": [],
            }))
            .unwrap(),
        );
        daemon.returns::<methods::HermesRoomsCreate>(
            serde_json::from_value::<HermesRoomDto>(json!({"id": "r9", "name": "Seed swap"}))
                .unwrap(),
        );
    }

    /// New Room asked to make "Seed swap"; `meanwhile` runs while its answer
    /// is out. Whether the sheet is still open after the answer.
    fn create_with(
        cx: &mut TestAppContext,
        meanwhile: impl FnOnce(&Stores, &mut VisualTestContext),
    ) -> (bool, Selection) {
        let (daemon, stores, vcx) = crate::views::sheet::bench::bench(cx);
        creatable(&daemon);
        stores
            .hermes_rooms
            .update(vcx, |h, cx| h.set_wanted(true, cx));
        vcx.run_until_parked();
        let sheet_stores = stores.clone();
        let sheet = vcx
            .update(|window, cx| {
                crate::views::sheet::open(window, super::WIDTH, cx, move |w, cx| {
                    CreateRoomSheet::new(sheet_stores, w, cx)
                })
            })
            .unwrap();
        vcx.run_until_parked();
        let held = daemon.hold::<methods::HermesRoomsCreate>();
        sheet.update_in(vcx, |s, window, cx| {
            s.set_name("Seed swap", window, cx);
            s.toggle("fern", cx);
            s.toggle("moss", cx);
            s.create(window, cx);
        });
        assert_eq!(daemon.calls::<methods::HermesRoomsCreate>().len(), 1);
        meanwhile(&stores, vcx);
        drop(held);
        vcx.run_until_parked();
        let open = vcx
            .update(|_, cx| crate::views::sheet::current::<CreateRoomSheet>(cx))
            .is_some();
        let shown = stores
            .navigation
            .read_with(vcx, |n, _| n.selection().clone());
        (open, shown)
    }

    /// Hermes counts a name's length as conduitd does, in UTF-16 units: a
    /// name of emoji within 200 characters but over 200 units is refused
    /// by both sheets before it is sent.
    #[gpui_kit::test]
    fn an_emoji_name_too_long_for_hermes_is_not_sent(cx: &mut TestAppContext) {
        let long = "\u{1F331}".repeat(150);
        let daemon = FakeDaemon::new();
        let (info, vcx) = open(cx, &daemon, "emoji");
        info.update_in(vcx, |s, window, cx| s.type_into("name", &long, window, cx));
        info.read_with(vcx, |s, _| assert!(!s.valid(), "Room Info would save it"));
        let (daemon, stores, vcx) = crate::views::sheet::bench::bench(cx);
        creatable(&daemon);
        stores
            .hermes_rooms
            .update(vcx, |h, cx| h.set_wanted(true, cx));
        vcx.run_until_parked();
        let sheet_stores = stores.clone();
        let sheet = vcx
            .update(|window, cx| {
                crate::views::sheet::open(window, super::WIDTH, cx, move |w, cx| {
                    CreateRoomSheet::new(sheet_stores, w, cx)
                })
            })
            .unwrap();
        vcx.run_until_parked();
        sheet.update_in(vcx, |s, window, cx| {
            s.set_name(&long, window, cx);
            s.toggle("fern", cx);
            s.toggle("moss", cx);
        });
        sheet.read_with(vcx, |s, cx| assert!(!s.ready(cx), "New Room would send it"));
    }

    /// New Room open over the bench's main window, "Seed swap" typed.
    fn new_room_typed(
        cx: &mut TestAppContext,
    ) -> (FakeDaemon, Entity<CreateRoomSheet>, &mut VisualTestContext) {
        let (daemon, stores, vcx) = crate::views::sheet::bench::bench(cx);
        creatable(&daemon);
        stores
            .hermes_rooms
            .update(vcx, |h, cx| h.set_wanted(true, cx));
        vcx.run_until_parked();
        let sheet_stores = stores.clone();
        let sheet = vcx
            .update(|window, cx| {
                crate::views::sheet::open(window, super::WIDTH, cx, move |w, cx| {
                    CreateRoomSheet::new(sheet_stores, w, cx)
                })
            })
            .unwrap();
        vcx.run_until_parked();
        assert!(!vcx.update(|_, cx| crate::views::sheet::has_unsaved(cx)));
        sheet.update_in(vcx, |s, window, cx| s.set_name("Seed swap", window, cx));
        (daemon, sheet, vcx)
    }

    /// Quit through the sheets' own path, with a counter for the app's quit.
    fn quit(vcx: &mut VisualTestContext) -> Rc<Cell<u32>> {
        let quits = Rc::new(Cell::new(0));
        let counted = quits.clone();
        vcx.update(|_, cx| {
            crate::views::sheet::quit_with(cx, Rc::new(move |_| counted.set(counted.get() + 1)))
        });
        settle(vcx);
        quits
    }

    fn answer(vcx: &mut VisualTestContext, yes: bool) {
        vcx.update(|_, cx| cx.set_global(crate::shell::sheet::AutoAnswer(Some(yes))));
    }

    fn sheet_open(vcx: &mut VisualTestContext) -> bool {
        vcx.update(|_, cx| crate::views::sheet::current::<CreateRoomSheet>(cx))
            .is_some()
    }

    /// Lets the sheet's slide and the saves Quit waits for run out.
    fn settle(vcx: &mut VisualTestContext) {
        for _ in 0..2 {
            vcx.run_until_parked();
            vcx.executor().advance_clock(Duration::from_secs(5));
        }
        vcx.run_until_parked();
    }

    /// A room name typed or bots picked and not made yet: Quit and Cancel
    /// ask before dropping them, as the other sheets' edits. Kept editing,
    /// Quit is dropped: a later Discard closes the sheet, not the app.
    #[gpui_kit::test]
    fn quit_asks_before_dropping_a_new_room_not_made(cx: &mut TestAppContext) {
        let (_daemon, sheet, vcx) = new_room_typed(cx);
        assert!(
            vcx.update(|_, cx| crate::views::sheet::has_unsaved(cx)),
            "Quit would drop the room name typed"
        );
        sheet.update_in(vcx, |s, window, cx| s.cancel(window, cx));
        vcx.run_until_parked();
        assert!(
            sheet_open(vcx),
            "Cancel dropped the room name without asking"
        );
        let quits = quit(vcx);
        assert!(sheet_open(vcx), "Quit dropped the room name without asking");
        assert_eq!(
            quits.get(),
            0,
            "Quit went on although the user kept editing"
        );
        answer(vcx, true);
        sheet.update_in(vcx, |s, window, cx| s.cancel(window, cx));
        settle(vcx);
        assert!(
            !sheet_open(vcx),
            "a confirmed Cancel left the room sheet open"
        );
        assert_eq!(
            quits.get(),
            0,
            "a Discard after keeping on editing quit the app"
        );
    }

    /// Discard, asked by Quit: the sheet closes and the app quits, once.
    #[gpui_kit::test]
    fn quit_goes_on_once_a_new_room_is_discarded(cx: &mut TestAppContext) {
        let (_daemon, _sheet, vcx) = new_room_typed(cx);
        answer(vcx, true);
        let quits = quit(vcx);
        assert!(!sheet_open(vcx), "Discard left the room sheet open");
        assert_eq!(
            quits.get(),
            1,
            "Discard closed the sheet but the app stayed"
        );
    }

    fn beeps(vcx: &mut VisualTestContext) -> u32 {
        vcx.update(|_, cx| cx.global::<crate::shell::sheet::Beeps>().0)
    }

    /// Answers the `n`th question still held (in the order they came).
    fn answer_held(vcx: &mut VisualTestContext, n: usize, yes: bool) {
        vcx.update(|_, cx| {
            let tx = cx
                .global_mut::<crate::shell::sheet::HeldAnswers>()
                .0
                .remove(n);
            let _ = tx.send(yes);
        });
        settle(vcx);
    }

    /// Quit while the room is being made queues nothing: the sheet comes
    /// forward with a beep, and the made room closes it without quitting.
    #[gpui_kit::test]
    fn quit_during_a_create_beeps_and_stays(cx: &mut TestAppContext) {
        let (daemon, sheet, vcx) = new_room_typed(cx);
        let held = daemon.hold::<methods::HermesRoomsCreate>();
        sheet.update_in(vcx, |s, window, cx| {
            s.toggle("fern", cx);
            s.toggle("moss", cx);
            s.create(window, cx);
        });
        assert_eq!(daemon.calls::<methods::HermesRoomsCreate>().len(), 1);
        let quits = quit(vcx);
        assert_eq!(beeps(vcx), 1, "Quit during the create did not beep");
        assert!(
            sheet_open(vcx),
            "Quit closed the sheet while its room was being made"
        );
        drop(held);
        settle(vcx);
        assert!(!sheet_open(vcx), "the made room left its sheet open");
        assert_eq!(quits.get(), 0, "a Quit waited on the create");
    }

    /// A refused create leaves the sheet idle with its error: ⌘Q now asks,
    /// and Discard quits.
    #[gpui_kit::test]
    fn after_a_refused_create_quit_asks_and_discard_quits(cx: &mut TestAppContext) {
        let (daemon, sheet, vcx) = new_room_typed(cx);
        daemon.once::<methods::HermesRoomsCreate>(Err(RpcError::internal("no room")));
        let held = daemon.hold::<methods::HermesRoomsCreate>();
        sheet.update_in(vcx, |s, window, cx| {
            s.toggle("fern", cx);
            s.toggle("moss", cx);
            s.create(window, cx);
        });
        let early = quit(vcx);
        drop(held);
        settle(vcx);
        assert!(sheet_open(vcx), "a refused create closed its sheet");
        sheet.read_with(vcx, |s, _| {
            assert!(s.failure.is_some(), "the refusal is not shown")
        });
        assert_eq!(early.get(), 0);
        answer(vcx, true);
        let quits = quit(vcx);
        assert!(!sheet_open(vcx), "Discard left the sheet open");
        assert_eq!(
            quits.get(),
            1,
            "Discard after the refused create did not quit"
        );
    }

    /// A create answered for a store that moved on (stale) leaves the sheet
    /// idle and still dirty: ⌘Q asks, and Discard quits.
    #[gpui_kit::test]
    fn after_a_stale_create_quit_asks_and_discard_quits(cx: &mut TestAppContext) {
        let (daemon, sheet, vcx) = new_room_typed(cx);
        let held = daemon.hold::<methods::HermesRoomsCreate>();
        sheet.update_in(vcx, |s, window, cx| {
            s.toggle("fern", cx);
            s.toggle("moss", cx);
            s.create(window, cx);
        });
        let stores = sheet.read_with(vcx, |s, _| s.stores.clone());
        stores.hermes_rooms.update(vcx, |h, cx| h.reset(cx));
        drop(held);
        settle(vcx);
        assert!(sheet_open(vcx), "the stale create closed its sheet");
        answer(vcx, true);
        let quits = quit(vcx);
        assert!(!sheet_open(vcx), "Discard left the sheet open");
        assert_eq!(
            quits.get(),
            1,
            "Discard after the stale create did not quit"
        );
    }

    /// New Room opened over the main window with "Seed swap" typed.
    fn another_room_typed(stores: &Stores, vcx: &mut VisualTestContext) -> Entity<CreateRoomSheet> {
        let sheet_stores = stores.clone();
        let sheet = vcx
            .update(|window, cx| {
                crate::views::sheet::open(window, super::WIDTH, cx, move |w, cx| {
                    CreateRoomSheet::new(sheet_stores, w, cx)
                })
            })
            .expect("the second sheet opens");
        vcx.run_until_parked();
        sheet.update_in(vcx, |s, window, cx| s.set_name("Seed swap", window, cx));
        sheet
    }

    /// Discard, and before the Quit it continues runs, another sheet opens
    /// and starts work (an approval, a link): Quit judges what is on screen
    /// then and beeps over the busy sheet, rather than quitting over it.
    #[gpui_kit::test]
    fn a_busy_sheet_opened_before_the_discarded_quit_runs_beeps(cx: &mut TestAppContext) {
        let (daemon, sheet, vcx) = new_room_typed(cx);
        let stores = sheet.read_with(vcx, |s, _| s.stores.clone());
        answer(vcx, true);
        let quits = Rc::new(Cell::new(0));
        let counted = quits.clone();
        vcx.update(|_, cx| {
            crate::views::sheet::quit_with(cx, Rc::new(move |_| counted.set(counted.get() + 1)))
        });
        vcx.run_until_parked();
        assert!(!sheet_open(vcx), "Discard left the first sheet open");
        assert_eq!(quits.get(), 0, "quit before the sheet was ended");
        // The second sheet comes before the Quit goes on; its question is held.
        vcx.update(|_, cx| cx.set_global(crate::shell::sheet::HeldAnswers::default()));
        let second = another_room_typed(&stores, vcx);
        let held = daemon.hold::<methods::HermesRoomsCreate>();
        second.update_in(vcx, |s, window, cx| {
            s.toggle("fern", cx);
            s.toggle("moss", cx);
            s.create(window, cx);
        });
        settle(vcx);
        assert_eq!(quits.get(), 0, "the app quit over a sheet opened meanwhile");
        assert!(sheet_open(vcx), "the second sheet was closed");
        assert_eq!(beeps(vcx), 1, "the busy second sheet did not beep");
        // The made room closes the second sheet; nothing waited, so nothing
        // quits.
        drop(held);
        settle(vcx);
        assert!(!sheet_open(vcx));
        assert_eq!(quits.get(), 0, "a Quit waited on the second sheet's create");
    }

    /// Discard, and before the Quit runs another sheet opens idle with
    /// edits: its discard question comes up and nothing quits.
    #[gpui_kit::test]
    fn an_idle_dirty_sheet_opened_before_the_quit_runs_asks(cx: &mut TestAppContext) {
        let (_daemon, sheet, vcx) = new_room_typed(cx);
        let stores = sheet.read_with(vcx, |s, _| s.stores.clone());
        answer(vcx, true);
        let quits = Rc::new(Cell::new(0));
        let counted = quits.clone();
        vcx.update(|_, cx| {
            crate::views::sheet::quit_with(cx, Rc::new(move |_| counted.set(counted.get() + 1)))
        });
        vcx.run_until_parked();
        assert!(!sheet_open(vcx));
        vcx.update(|_, cx| cx.set_global(crate::shell::sheet::HeldAnswers::default()));
        let _second = another_room_typed(&stores, vcx);
        settle(vcx);
        assert_eq!(
            quits.get(),
            0,
            "the app quit over a dirty sheet opened meanwhile"
        );
        assert!(sheet_open(vcx), "the second sheet was closed");
        let asked = vcx.update(|_, cx| cx.global::<crate::shell::sheet::HeldAnswers>().0.len());
        assert_eq!(asked, 1, "the new sheet's discard question did not come up");
    }

    /// While the sheet's discard question is up, a question in another window
    /// answered No is not that Quit's: Discard still quits, once.
    #[gpui_kit::test]
    fn another_windows_question_leaves_the_quit_alone(cx: &mut TestAppContext) {
        let (_daemon, _sheet, vcx) = new_room_typed(cx);
        vcx.update(|_, cx| cx.set_global(crate::shell::sheet::HeldAnswers::default()));
        let quits = quit(vcx);
        // The main window (not the sheet) asks something.
        vcx.update(|window, cx| {
            let spec = crate::shell::sheet::SheetSpec::new(
                "Sign Out?".to_string(),
                "You can sign in again later.".to_string(),
                "Sign Out".to_string(),
                "Cancel".to_string(),
            );
            crate::shell::sheet::present_sheet(window, spec, cx).detach();
        });
        answer_held(vcx, 1, false);
        assert_eq!(quits.get(), 0);
        answer_held(vcx, 0, true);
        assert!(!sheet_open(vcx), "Discard left the sheet open");
        assert_eq!(
            quits.get(),
            1,
            "another window's question dropped the sheet's Quit"
        );
    }

    #[gpui_kit::test]
    fn a_room_made_after_the_account_changed_does_not_close_or_open_anything(
        cx: &mut TestAppContext,
    ) {
        let (open, shown) = create_with(cx, |stores, vcx| {
            stores.hermes_rooms.update(vcx, |h, cx| h.reset(cx));
        });
        assert!(open, "a stale answer closed the sheet");
        assert_ne!(shown, made(), "a stale answer opened its room");
    }

    #[gpui_kit::test]
    fn a_room_made_opens_even_when_a_list_event_came_first(cx: &mut TestAppContext) {
        let (open, shown) = create_with(cx, |stores, vcx| {
            let list = serde_json::from_value(json!({
                "available": true, "canCreate": true, "seatable": ["fern", "moss"],
                "rooms": [{"id": "r9", "name": "Seed swap"}],
            }))
            .unwrap();
            stores.hermes_rooms.update(vcx, |h, cx| {
                h.on_event(&Event::HermesRoomsListChanged(list), cx)
            });
        });
        assert!(!open, "the room made did not close the sheet");
        assert_eq!(shown, made(), "the room made was not opened");
    }

    fn info_sheet(
        daemon: &FakeDaemon,
        stores: &Stores,
        vcx: &mut VisualTestContext,
    ) -> Entity<RoomInfoSheet> {
        daemon.returns::<methods::HermesRoomsWatch>(room());
        daemon.returns::<methods::HermesRoomsRename>(
            serde_json::from_value::<HermesRoomDto>(json!({"id": "r1", "name": "Seed swap"}))
                .unwrap(),
        );
        stores.hermes_rooms.update(vcx, |h, cx| {
            h.show(Some("r1"), cx);
            h.on_event(&Event::HermesRoomsChanged(room()), cx);
        });
        let sheet_stores = stores.clone();
        let sheet = vcx
            .update(|window, cx| {
                crate::views::sheet::open(window, super::WIDTH, cx, move |w, cx| {
                    RoomInfoSheet::new(sheet_stores, "r1".into(), true, w, cx)
                })
            })
            .unwrap();
        vcx.run_until_parked();
        sheet
    }

    #[gpui_kit::test]
    fn room_info_left_open_across_a_change_saves_nothing_under_the_next(cx: &mut TestAppContext) {
        let (daemon, stores, vcx) = crate::views::sheet::bench::bench(cx);
        let sheet = info_sheet(&daemon, &stores, vcx);
        sheet.update_in(vcx, |s, window, cx| {
            s.type_into("name", "Seed swap", window, cx)
        });
        // The store moves on (another account or gateway) and reads r1 again.
        stores.hermes_rooms.update(vcx, |h, cx| {
            h.reset(cx);
            h.on_event(&Event::HermesRoomsChanged(room()), cx);
        });
        vcx.run_until_parked();
        sheet.update_in(vcx, |s, window, cx| s.save(window, cx));
        vcx.run_until_parked();
        assert!(daemon.calls::<methods::HermesRoomsRename>().is_empty());
        sheet.read_with(vcx, |s, _| {
            assert!(s.failure.is_some());
            assert_eq!(s.edit.name, "Seed swap", "the words typed stay");
        });
    }

    #[gpui_kit::test]
    fn room_info_closes_when_another_account_takes_charge(cx: &mut TestAppContext) {
        let (daemon, stores, vcx) = crate::views::sheet::bench::bench(cx);
        let _sheet = info_sheet(&daemon, &stores, vcx);
        crate::views::sheet::bench::switch_account(&stores, vcx);
        vcx.run_until_parked();
        assert!(
            vcx.update(|_, cx| crate::views::sheet::current::<RoomInfoSheet>(cx))
                .is_none()
        );
    }

    fn made() -> Selection {
        Selection::Area(AreaItem::HermesRoom("r9".into()))
    }

    #[gpui_kit::test]
    fn a_made_room_opens_only_if_its_binding_still_holds_when_the_open_runs(
        cx: &mut TestAppContext,
    ) {
        let (_daemon, stores, vcx) = crate::views::sheet::bench::bench(cx);
        let asked = stores.hermes_rooms.read_with(vcx, |h, _| h.generation());
        // The binding moves between scheduling the open and running it.
        stores.hermes_rooms.update(vcx, |h, cx| h.reset(cx));
        vcx.update(|_, cx| super::open_made_room(&stores, "r9".into(), asked, cx));
        assert_ne!(
            stores
                .navigation
                .read_with(vcx, |n, _| n.selection().clone()),
            made()
        );
        let now = stores.hermes_rooms.read_with(vcx, |h, _| h.generation());
        vcx.update(|_, cx| super::open_made_room(&stores, "r9".into(), now, cx));
        assert_eq!(
            stores
                .navigation
                .read_with(vcx, |n, _| n.selection().clone()),
            made()
        );
    }

    #[gpui_kit::test]
    fn room_info_stays_open_over_its_edits_when_disband_is_cancelled(cx: &mut TestAppContext) {
        let (daemon, stores, vcx) = crate::views::sheet::bench::bench(cx);
        let sheet = info_sheet(&daemon, &stores, vcx);
        sheet.update_in(vcx, |s, window, cx| {
            s.type_into("purpose", "Seed trays", window, cx);
            // The bench answers the Disband question Cancel.
            s.disband(window, cx);
        });
        vcx.run_until_parked();
        assert!(
            vcx.update(|_, cx| crate::views::sheet::current::<RoomInfoSheet>(cx))
                .is_some(),
            "Room Info closed before Disband was confirmed"
        );
        sheet.read_with(vcx, |s, _| assert_eq!(s.edit.purpose, "Seed trays"));
        assert!(daemon.calls::<methods::HermesRoomsDisband>().is_empty());
    }

    #[gpui_kit::test]
    fn room_info_closes_once_its_room_is_disbanded(cx: &mut TestAppContext) {
        let (daemon, stores, vcx) = crate::views::sheet::bench::bench(cx);
        vcx.update(|_, cx| cx.set_global(crate::shell::sheet::AutoAnswer(Some(true))));
        daemon.returns::<methods::HermesRoomsDisband>(conduit_protocol::OkResult { ok: true });
        let sheet = info_sheet(&daemon, &stores, vcx);
        sheet.update_in(vcx, |s, window, cx| s.disband(window, cx));
        vcx.run_until_parked();
        assert_eq!(daemon.calls::<methods::HermesRoomsDisband>().len(), 1);
        assert!(
            vcx.update(|_, cx| crate::views::sheet::current::<RoomInfoSheet>(cx))
                .is_none()
        );
    }

    #[gpui_kit::test]
    fn stop_work_keeps_room_info_and_its_edits(cx: &mut TestAppContext) {
        let (daemon, stores, vcx) = crate::views::sheet::bench::bench(cx);
        daemon.returns::<methods::HermesRoomsStop>(conduit_protocol::HermesRoomStopped {
            stopped: 1,
        });
        let sheet = info_sheet(&daemon, &stores, vcx);
        sheet.update_in(vcx, |s, window, cx| {
            s.type_into("purpose", "Seed trays", window, cx);
            s.stop(cx);
        });
        vcx.run_until_parked();
        assert_eq!(daemon.calls::<methods::HermesRoomsStop>().len(), 1);
        assert!(
            vcx.update(|_, cx| crate::views::sheet::current::<RoomInfoSheet>(cx))
                .is_some(),
            "Stop Work closed Room Info over its edits"
        );
        sheet.read_with(vcx, |s, _| assert_eq!(s.edit.purpose, "Seed trays"));
    }
}
