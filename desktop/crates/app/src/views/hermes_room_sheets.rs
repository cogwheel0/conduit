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

/// Runs `then` on the main window once the sheet has gone.
fn after_sheet(cx: &mut App, then: impl FnOnce(&mut Window, &mut App) + 'static) {
    sheet::dismiss(cx);
    cx.defer(move |cx| {
        if let Some(handle) = cx
            .try_global::<crate::AppState>()
            .and_then(|s| s.main_window)
        {
            let _ = handle.update(cx, |_, window, cx| then(window, cx));
        }
    });
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
        Self {
            stores,
            name,
            picked: vec![],
            creating: false,
            failure: None,
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
            && name.trim().chars().count() <= MAX_NAME
            && (MIN_SEATS..=MAX_SEATS).contains(&self.picked.len())
    }

    pub fn create(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if !self.ready(cx) {
            return;
        }
        let Some(rpc) = self.stores.hermes_rooms.read(cx).rpc() else {
            return;
        };
        self.creating = true;
        self.failure = None;
        cx.notify();
        let call = rpc.call::<methods::HermesRoomsCreate>(&HermesRoomCreate {
            name: forms::text(&self.name, cx).trim().to_string(),
            bots: self.picked.clone(),
        });
        let handle = window.window_handle();
        let stores = self.stores.clone();
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result = call.await;
            let _ = handle.update(cx, |_, _, cx| {
                let _ = this.update(cx, |s, cx| {
                    s.creating = false;
                    match result {
                        Ok(room) => {
                            let id = room.id.clone();
                            stores.hermes_rooms.update(cx, |h, cx| {
                                h.patch_listed(room, cx);
                                h.refresh(cx);
                            });
                            let navigation = stores.navigation.clone();
                            after_sheet(cx, move |_, cx| {
                                navigation
                                    .update(cx, |n, cx| n.open_item(AreaItem::HermesRoom(id), cx));
                            });
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

    fn cancel(&mut self, _: &mut Window, cx: &mut Context<Self>) {
        if !self.creating {
            sheet::dismiss(cx);
        }
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
                if this.initial.is_none() {
                    this.adopt_current(window, cx);
                }
                cx.notify()
            }),
        ];
        let mut this = Self {
            stores,
            room_id,
            name,
            purpose,
            notes,
            edit: RoomEdit::default(),
            initial: None,
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

    fn adopt_current(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(edit) = self.view(cx).and_then(RoomEdit::of) else {
            return;
        };
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
            && name.chars().count() <= MAX_NAME
            && self.edit.purpose.trim().chars().count() <= MAX_PURPOSE
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
        if !self.can_save(cx) {
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
        let rename = (edit.name.trim() != initial.name.trim()).then(|| {
            rpc.call::<methods::HermesRoomsRename>(&HermesRoomRename {
                room_id: self.room_id.clone(),
                name: edit.name.trim().to_string(),
            })
        });
        let context = (edit.context() != initial.context()).then(|| {
            rpc.call::<methods::HermesRoomsSaveContext>(&HermesRoomContextEdit {
                room_id: self.room_id.clone(),
                context: edit.context(),
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
                    let error = renamed
                        .as_ref()
                        .and_then(|r| r.as_ref().err())
                        .or_else(|| saved.as_ref().and_then(|r| r.as_ref().err()));
                    if let Some(e) = error {
                        log::warn!("hermes room save: {e}");
                        s.failure = Some(failure_text(e, &l));
                        cx.notify();
                        return;
                    }
                    if let Some(Ok(room)) = renamed {
                        stores
                            .hermes_rooms
                            .update(cx, |h, cx| h.patch_listed(room, cx));
                    }
                    stores
                        .toasts
                        .update(cx, |t, cx| t.show(NoticeLevel::Info, l.saved(), cx));
                    sheet::dismiss(cx);
                });
            });
        })
        .detach();
    }

    fn stop(&mut self, cx: &mut Context<Self>) {
        let (stores, id) = (self.stores.clone(), self.room_id.clone());
        after_sheet(cx, move |_, cx| hermes_rooms::stop(&stores, &id, cx));
    }

    fn disband(&mut self, cx: &mut Context<Self>) {
        let (stores, id) = (self.stores.clone(), self.room_id.clone());
        after_sheet(cx, move |window, cx| {
            hermes_rooms::confirm_disband(&stores, &id, window, cx)
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
                            .on_click(Rc::new(move |_, _, cx| {
                                let _ = disband.update(cx, |v, cx| v.disband(cx));
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
        cx.spawn(async move |_, cx: &mut AsyncApp| {
            if ask.await {
                cx.update(sheet::dismiss);
            }
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
