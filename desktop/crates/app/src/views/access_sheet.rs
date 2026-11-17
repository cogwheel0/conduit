//! The access sheet: who may read, or read and edit, one resource (users
//! and groups), as mobile's sharing sheet, in a window sheet on the main
//! window. Share Folder… opens it for a folder, and Share Chat's Who Has
//! Access for a chat, where it also offers the chat's general access (only
//! the people added, everyone on the server, anyone with the link); it
//! takes any [`AccessResourceKind`], so Notes and Workspace items reuse it.
//!
//! Over `access.*`: the daemon reads the grants, names their people and
//! groups, says what this account may change, and writes the edited list
//! (keeping what the sheet cannot show), reading the server's answer back.

use std::rc::Rc;
use std::time::Duration;

use conduit_components::ActiveConduitTheme as _;
use conduit_components::assets::IconName;
use conduit_components::views::kit::{Button, IconButton, avatar, grouped_section};
use conduit_protocol::{
    AccessAudience, AccessEdit, AccessGrantDto, AccessPrincipal, AccessPrincipalQuery, AccessRef,
    AccessResourceKind, AccessState, NoticeLevel, methods,
};
use gpui_kit::component::input::{InputEvent, InputState};
use gpui_kit::prelude::*;
use gpui_kit::{
    AnyElement, App, AsyncApp, Context, ElementId, Entity, FontWeight, Role, SharedString,
    Subscription, Task, WeakEntity, Window, div, px, relative,
};

use crate::actions::SettingsChoice;
use crate::l10n::{ActiveL10n as _, L10n};
use crate::shell::sheet::{SheetSpec, present_sheet};
use crate::stores::Stores;
use crate::stores::rpc::Rpc;
use crate::views::forms;
use crate::views::settings::controls::{self, Choice};
use crate::views::sheet::{self, SheetBody};

/// The sheet's width.
pub const WIDTH: f32 = 520.;

/// How long typing pauses before the server is asked for people.
const SEARCH_DELAY: Duration = Duration::from_millis(200);

/// Share Folder…: the access sheet for `folder_id`, named `name`.
pub fn open_for_folder(
    stores: Stores,
    folder_id: &str,
    name: String,
    window: &mut Window,
    cx: &mut App,
) {
    let id = folder_id.to_string();
    sheet::open(window, WIDTH, cx, move |w, cx| {
        AccessSheet::new(stores, AccessResourceKind::Folder, id, name, w, cx)
    });
}

/// A note's Share Access…: who may read it, or read and change it.
pub fn open_for_note(
    stores: Stores,
    note_id: &str,
    title: String,
    window: &mut Window,
    cx: &mut App,
) {
    let id = note_id.to_string();
    sheet::open(window, WIDTH, cx, move |w, cx| {
        AccessSheet::new(stores, AccessResourceKind::Note, id, title, w, cx)
    });
}

/// Share Chat's Who Has Access: the access sheet for chat `chat_id`, named
/// `title`. Share Chat comes back once it is saved or cancelled, as the
/// phone's share flow returns to its sheet.
pub fn open_for_chat(
    stores: Stores,
    chat_id: &str,
    title: String,
    window: &mut Window,
    cx: &mut App,
) -> Option<Entity<AccessSheet>> {
    let id = chat_id.to_string();
    let opened = sheet::open(window, WIDTH, cx, move |w, cx| {
        AccessSheet::new(stores, AccessResourceKind::Chat, id, title, w, cx)
    });
    if opened.is_some() {
        let id = chat_id.to_string();
        sheet::after_dismiss(cx, move |cx| {
            let main = cx
                .try_global::<crate::AppState>()
                .and_then(|s| s.main_window);
            if let Some(main) = main {
                let _ = main.update(cx, |_, window, cx| {
                    crate::views::chat::share_sheet::open(id, window, cx)
                });
            }
        });
    }
    opened
}

/// Share Access… for a workspace item of `kind` (a model, knowledge base,
/// prompt, tool or skill) named `name`.
pub fn open_for_workspace(
    stores: Stores,
    kind: AccessResourceKind,
    id: &str,
    name: String,
    window: &mut Window,
    cx: &mut App,
) {
    let id = id.to_string();
    sheet::open(window, WIDTH, cx, move |w, cx| {
        AccessSheet::new(stores, kind, id, name, w, cx)
    });
}

pub struct AccessSheet {
    stores: Stores,
    rpc: Rpc,
    pub kind: AccessResourceKind,
    id: String,
    resource_name: String,
    pub state: Option<AccessState>,
    /// The grants as the sheet holds them, and as they were loaded.
    pub grants: Vec<AccessGrantDto>,
    initial: Vec<AccessGrantDto>,
    /// The general access picked in the sheet; None keeps the one loaded.
    picked_audience: Option<AccessAudience>,
    search: Entity<InputState>,
    pub results: Vec<AccessPrincipal>,
    saving: bool,
    pub failure: Option<String>,
    _subscriptions: Vec<Subscription>,
    _load: Option<Task<()>>,
    _search: Option<Task<()>>,
    /// Closes the sheet when another account becomes active.
    _account: Subscription,
}

impl AccessSheet {
    pub fn new(
        stores: Stores,
        kind: AccessResourceKind,
        id: String,
        resource_name: String,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Self {
        let rpc = stores.connection.read(cx).rpc();
        let search = forms::input(cx.l10n().desktop_access_search_hint(), false, window, cx);
        let subscriptions =
            vec![
                cx.subscribe_in(&search, window, |this, state, e: &InputEvent, _, cx| {
                    if matches!(e, InputEvent::Change) {
                        let query = state.read(cx).value().to_string();
                        this.find(query, cx);
                    }
                }),
            ];
        let account = sheet::close_with_account(&stores, cx);
        let mut this = Self {
            _account: account,
            stores,
            rpc,
            kind,
            id,
            resource_name,
            state: None,
            grants: vec![],
            initial: vec![],
            picked_audience: None,
            search,
            results: vec![],
            saving: false,
            failure: None,
            _subscriptions: subscriptions,
            _load: None,
            _search: None,
        };
        this.load(cx);
        this
    }

    fn load(&mut self, cx: &mut Context<Self>) {
        let call = self.rpc.call::<methods::AccessGet>(&AccessRef {
            kind: self.kind,
            id: self.id.clone(),
        });
        self._load = Some(
            cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
                let result = call.await;
                let _ = this.update(cx, |s, cx| {
                    match result {
                        Ok(state) => s.adopt(state),
                        Err(e) => {
                            log::warn!("access.get: {e}");
                            s.failure = Some(failure_text(&e, &cx.l10n().clone()));
                        }
                    }
                    cx.notify();
                });
            }),
        );
        // Groups first, before anything is typed.
        self.find(String::new(), cx);
    }

    fn adopt(&mut self, state: AccessState) {
        self.grants = state.grants.clone();
        self.initial = state.grants.clone();
        self.picked_audience = None;
        self.state = Some(state);
    }

    /// The sheet offers general access: a chat always, as the phone does;
    /// a note when it may be opened to everyone (or already is); never a
    /// folder.
    fn offers_audience(state: &AccessState) -> bool {
        match state.kind {
            AccessResourceKind::Chat => true,
            AccessResourceKind::Folder => false,
            _ => state.allow_public || state.audience != AccessAudience::Private,
        }
    }

    /// The general access on screen: the one picked, else the one loaded.
    pub fn audience(&self) -> AccessAudience {
        self.picked_audience
            .or_else(|| self.state.as_ref().map(|s| s.audience))
            .unwrap_or(AccessAudience::Private)
    }

    /// Picks the general access (saved with the grants).
    pub fn set_audience(&mut self, audience: AccessAudience, cx: &mut Context<Self>) {
        let loaded = self.state.as_ref().map(|s| s.audience);
        self.picked_audience = (Some(audience) != loaded).then_some(audience);
        self.failure = None;
        cx.notify();
    }

    /// People and groups matching `query`, once typing pauses.
    pub fn find(&mut self, query: String, cx: &mut Context<Self>) {
        let rpc = self.rpc.clone();
        self._search = Some(
            cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
                if !query.is_empty() {
                    cx.background_executor().timer(SEARCH_DELAY).await;
                }
                let result = rpc
                    .call::<methods::AccessPrincipals>(&AccessPrincipalQuery {
                        query: query.trim().to_string(),
                    })
                    .await;
                let _ = this.update(cx, |s, cx| {
                    s.results = result.map(|r| r.items).unwrap_or_default();
                    cx.notify();
                });
            }),
        );
    }

    fn can_edit(&self) -> bool {
        self.state.as_ref().is_some_and(|s| s.can_edit)
    }

    pub fn is_dirty(&self) -> bool {
        self.grants != self.initial || self.picked_audience.is_some()
    }

    fn can_save(&self) -> bool {
        self.can_edit() && !self.saving && self.is_dirty()
    }

    /// Whether the server lets this account give `principal` access: users
    /// and groups each as it allows.
    fn may_grant(&self, principal: &AccessPrincipal) -> bool {
        self.state.as_ref().is_some_and(|s| {
            if principal.r#type == "group" {
                s.allow_groups
            } else {
                s.allow_users
            }
        })
    }

    /// People and groups may be added: the account may edit, the server
    /// allows one kind or the other, and no save is on its way (what it
    /// sends is what the sheet then shows).
    fn may_add(&self) -> bool {
        !self.saving
            && self
                .state
                .as_ref()
                .is_some_and(|s| s.can_edit && (s.allow_users || s.allow_groups))
    }

    /// Adds `principal` with read access (Can View).
    pub fn add(
        &mut self,
        principal: &AccessPrincipal,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if !self.may_add()
            || !self.may_grant(principal)
            || self
                .grants
                .iter()
                .any(|g| g.principal_type == principal.r#type && g.principal_id == principal.id)
        {
            return;
        }
        self.grants.push(AccessGrantDto {
            principal_type: principal.r#type.clone(),
            principal_id: principal.id.clone(),
            write: false,
            name: principal.name.clone(),
            email: principal.email.clone(),
        });
        // The field empties (with no change event): the list goes back to
        // the groups.
        self.search.update(cx, |s, cx| s.set_value("", window, cx));
        self.find(String::new(), cx);
        self.failure = None;
        cx.notify();
    }

    fn remove(&mut self, index: usize, cx: &mut Context<Self>) {
        if index < self.grants.len() {
            self.grants.remove(index);
            cx.notify();
        }
    }

    /// Gives `principal_id` edit access, or read access only.
    pub fn set_write(&mut self, key: &str, write: bool, cx: &mut Context<Self>) {
        if let Some(g) = self
            .grants
            .iter_mut()
            .find(|g| format!("{}:{}", g.principal_type, g.principal_id) == key)
        {
            g.write = write;
            cx.notify();
        }
    }

    pub fn save(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if !self.can_save() {
            return;
        }
        self.saving = true;
        self.failure = None;
        cx.notify();
        let call = self.rpc.call::<methods::AccessSet>(&AccessEdit {
            kind: self.kind,
            id: self.id.clone(),
            grants: self.grants.clone(),
            audience: self.picked_audience,
        });
        let picked = self.picked_audience;
        let handle = window.window_handle();
        let asked: Vec<String> = self
            .grants
            .iter()
            .map(|g| format!("{}:{}", g.principal_type, g.principal_id))
            .collect();
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result = call.await;
            let _ = handle.update(cx, |_, _, cx| {
                let _ = this.update(cx, |s, cx| {
                    s.saving = false;
                    let l10n = cx.l10n().clone();
                    match result {
                        Ok(state) => {
                            // The server may keep only part of it.
                            let kept: Vec<String> = state
                                .grants
                                .iter()
                                .map(|g| format!("{}:{}", g.principal_type, g.principal_id))
                                .collect();
                            let dropped: Vec<String> = s
                                .grants
                                .iter()
                                .filter(|g| {
                                    let key = format!("{}:{}", g.principal_type, g.principal_id);
                                    asked.contains(&key) && !kept.contains(&key)
                                })
                                .map(|g| display_name(g, &l10n))
                                .collect();
                            let audience_kept = picked.is_none_or(|a| a == state.audience);
                            s.adopt(state);
                            if !audience_kept {
                                s.failure = Some(l10n.resource_sharing_filtered());
                            } else if dropped.is_empty() {
                                s.stores.toasts.update(cx, |t, cx| {
                                    t.show(NoticeLevel::Info, l10n.saved(), cx)
                                });
                                sheet::dismiss(cx);
                            } else {
                                s.failure =
                                    Some(l10n.library_access_partial_save(&dropped.join(", ")));
                            }
                        }
                        Err(e) => {
                            log::warn!("access.set: {e}");
                            s.failure = Some(failure_text(&e, &l10n));
                        }
                    }
                    cx.notify();
                });
            });
        })
        .detach();
    }

    fn on_choice(&mut self, action: &SettingsChoice, cx: &mut Context<Self>) {
        if let Some(key) = action.menu.strip_prefix("access-level:") {
            self.set_write(key, action.value == "write", cx);
        } else if action.menu == "access-audience" {
            let audience = match action.value.as_str() {
                "public" => AccessAudience::Public,
                "open" => AccessAudience::Open,
                _ => AccessAudience::Private,
            };
            self.set_audience(audience, cx);
        }
    }

    fn grant_row(
        &self,
        index: usize,
        grant: &AccessGrantDto,
        state: &AccessState,
        l10n: &L10n,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let t = cx.conduit().clone();
        let r = t.roles;
        let name = display_name(grant, l10n);
        let group = grant.principal_type == "group";
        let detail = if group {
            l10n.desktop_access_group_badge()
        } else {
            grant.email.clone().unwrap_or_default()
        };
        let key = format!("{}:{}", grant.principal_type, grant.principal_id);
        let editable = self.can_edit() && !self.saving;
        let level: AnyElement = if state.allow_write {
            controls::popup(
                &format!("access-level:{key}"),
                &l10n.library_access_level_for(&name),
                vec![
                    Choice::new("read", l10n.library_access_can_view()),
                    Choice::new("write", l10n.workspace_access_can_edit()),
                ],
                if grant.write { "write" } else { "read" },
                !editable,
                window,
                cx,
            )
            .into_any_element()
        } else {
            controls::value(l10n.library_access_can_view(), cx).into_any_element()
        };
        let view = cx.entity().downgrade();
        let initials: String = name.chars().take(1).collect::<String>().to_uppercase();
        div()
            .id(ElementId::NamedInteger("access-grant".into(), index as u64))
            .px(px(12.))
            .min_h(px(48.))
            .flex()
            .items_center()
            .gap(px(10.))
            .child(avatar(
                &initials,
                28.,
                conduit_components::theme::with_alpha(r.text, if t.dark { 0.16 } else { 0.08 }),
                r.text_subtle,
            ))
            .child(
                div()
                    .flex_1()
                    .min_w_0()
                    .flex()
                    .flex_col()
                    .child(div().truncate().child(name.clone()))
                    .when(!detail.is_empty(), |d| {
                        d.child(
                            div()
                                .truncate()
                                .text_size(px(t.metrics.small))
                                .text_color(r.text_subtle)
                                .child(detail),
                        )
                    }),
            )
            .child(level)
            .when(editable, |d| {
                d.child(
                    IconButton::new(
                        ElementId::NamedInteger("access-remove".into(), index as u64),
                        IconName::X,
                        l10n.library_access_remove_principal(&name),
                    )
                    .size(26., 14.)
                    .on_click(Rc::new(move |_, _, cx| {
                        let _ = view.update(cx, |v, cx| v.remove(index, cx));
                    })),
                )
            })
            .into_any_element()
    }

    fn results_rows(&self, l10n: &L10n, cx: &mut Context<Self>) -> Vec<AnyElement> {
        let t = cx.conduit().clone();
        let r = t.roles;
        let taken = |p: &AccessPrincipal| {
            self.grants
                .iter()
                .any(|g| g.principal_type == p.r#type && g.principal_id == p.id)
        };
        let shown: Vec<_> = self
            .results
            .iter()
            .filter(|p| !taken(p) && self.may_grant(p))
            .take(8)
            .cloned()
            .collect();
        let query = self.search.read(cx).value().trim().to_string();
        if shown.is_empty() {
            return if query.is_empty() {
                vec![]
            } else {
                vec![
                    div()
                        .px(px(12.))
                        .py(px(8.))
                        .text_color(r.text_subtle)
                        .child(l10n.desktop_access_no_results())
                        .into_any_element(),
                ]
            };
        }
        let view = cx.entity().downgrade();
        shown
            .into_iter()
            .enumerate()
            .map(|(i, p)| {
                let view = view.clone();
                let detail = if p.r#type == "group" {
                    l10n.desktop_access_group_badge()
                } else {
                    p.email.clone().unwrap_or_default()
                };
                let label = if p.name.is_empty() {
                    p.id.clone()
                } else {
                    p.name.clone()
                };
                div()
                    .id(ElementId::NamedInteger("access-result".into(), i as u64))
                    .role(Role::Button)
                    .aria_label(SharedString::from(label.clone()))
                    .px(px(12.))
                    .min_h(px(40.))
                    .flex()
                    .items_center()
                    .gap(px(10.))
                    .cursor_pointer()
                    .hover(|s| s.bg(r.overlay_hover))
                    .child(conduit_components::assets::icon(
                        if p.r#type == "group" {
                            IconName::Users
                        } else {
                            IconName::User
                        },
                        14.,
                        r.text_subtle,
                    ))
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .flex()
                            .flex_col()
                            .child(div().truncate().child(label))
                            .when(!detail.is_empty(), |d| {
                                d.child(
                                    div()
                                        .truncate()
                                        .text_size(px(t.metrics.small))
                                        .text_color(r.text_subtle)
                                        .child(detail),
                                )
                            }),
                    )
                    .child(conduit_components::assets::icon(
                        IconName::Plus,
                        14.,
                        r.text_subtle,
                    ))
                    .on_click(move |_, window, cx| {
                        let _ = view.update(cx, |v, cx| v.add(&p, window, cx));
                    })
                    .into_any_element()
            })
            .collect()
    }
}

/// The access sheet's title for a resource of `kind`, named for what it
/// shares (Share Note, Share Folder, Share Model…), as the phone's Share
/// Note and Share Folder are; a chat's is Who Has Access, the row of Share
/// Chat that opens it.
pub fn title_for(kind: AccessResourceKind, l10n: &L10n) -> String {
    match kind {
        AccessResourceKind::Chat => l10n.chat_share_audience(),
        AccessResourceKind::Folder => l10n.folder_share_settings(),
        AccessResourceKind::Note => l10n.note_share(),
        AccessResourceKind::Model => l10n.desktop_share_model_title(),
        AccessResourceKind::Knowledge => l10n.desktop_share_knowledge_title(),
        AccessResourceKind::Prompt => l10n.desktop_share_prompt_title(),
        AccessResourceKind::Tool => l10n.desktop_share_tool_title(),
        AccessResourceKind::Skill => l10n.desktop_share_skill_title(),
        AccessResourceKind::Unknown => l10n.desktop_workspace_share_access_title(),
    }
}

impl AccessSheet {
    /// The sheet's title: Who Has Access for a chat (the Share Chat row that
    /// opens it), Share Note for a note (the phone's Share Note), Share
    /// Folder for a folder, and Share Model, Share Knowledge, Share Prompt,
    /// Share Tool or Share Skill for a workspace item.
    fn title(&self, l10n: &L10n) -> String {
        title_for(self.kind, l10n)
    }

    /// General Access: who may open it beyond the people below. A choice
    /// the account may not make is left out (unless the resource has it),
    /// with a line saying so, as on the phone.
    fn audience_section(
        &self,
        state: &AccessState,
        l10n: &L10n,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let current = self.audience();
        let chat = state.kind == AccessResourceKind::Chat;
        let mut choices = vec![Choice::new(
            "private",
            l10n.library_access_only_people_added(),
        )];
        if state.allow_public || current == AccessAudience::Public {
            choices.push(Choice::new(
                "public",
                l10n.library_access_everyone_on_server(),
            ));
        }
        if chat && (state.allow_open || current == AccessAudience::Open) {
            choices.push(Choice::new("open", l10n.library_access_anyone_with_link()));
        }
        let selected = match current {
            AccessAudience::Public => "public",
            AccessAudience::Open => "open",
            _ => "private",
        };
        let label = l10n.library_general_access();
        let popup = controls::popup(
            "access-audience",
            &label,
            choices,
            selected,
            !self.can_edit() || self.saving,
            window,
            cx,
        );
        let mut footer = vec![match current {
            AccessAudience::Public => l10n.library_access_everyone_hint(),
            AccessAudience::Open => l10n.resource_audience_open_hint(),
            _ => l10n.resource_audience_private_hint(),
        }];
        if state.can_edit {
            if !state.allow_public && current != AccessAudience::Public {
                footer.push(l10n.desktop_access_public_not_allowed());
            }
            if chat && !state.allow_open && current != AccessAudience::Open {
                footer.push(l10n.library_access_link_not_allowed());
            }
        }
        grouped_section(
            None,
            vec![forms::form_row(label, popup, cx).into_any_element()],
            Some(footer.join(" ").into()),
            cx,
        )
        .into_any_element()
    }
}

/// A grant's name: an unnamed one is an unknown person or group, never its
/// id.
fn display_name(grant: &AccessGrantDto, l10n: &L10n) -> String {
    if !grant.name.is_empty() {
        grant.name.clone()
    } else if grant.principal_type == "group" {
        l10n.library_access_unknown_group()
    } else {
        l10n.library_access_unknown_person()
    }
}

fn failure_text(e: &conduit_protocol::RpcError, l10n: &L10n) -> String {
    match e.args.get("reason").map(String::as_str) {
        Some("notEditable") | Some("denied") => l10n.library_access_account_cant_share(),
        Some("sessionChanged") => l10n.chat_settings_owner_changed(),
        Some("missing") => l10n.folder_project_gone(),
        _ => l10n.error_message(),
    }
}

impl SheetBody for AccessSheet {
    fn busy(&self, _: &App) -> bool {
        self.saving
    }

    fn unsaved(&self, _: &App) -> bool {
        AccessSheet::is_dirty(self)
    }

    fn footer(&mut self, _: &mut Window, cx: &mut Context<Self>) -> Option<AnyElement> {
        let l10n = cx.l10n().clone();
        let view = cx.entity().downgrade();
        let cancel_view = view.clone();
        Some(
            forms::form_buttons(vec![
                Button::new("access-cancel", l10n.cancel())
                    .on_click(Rc::new(move |_, window, cx| {
                        let _ = cancel_view.update(cx, |v, cx| v.cancel(window, cx));
                    }))
                    .into_any_element(),
                Button::new("access-save", l10n.save())
                    .primary()
                    .disabled(!self.can_save())
                    .on_click(Rc::new(move |_, window, cx| {
                        let _ = view.update(cx, |v, cx| v.save(window, cx));
                    }))
                    .into_any_element(),
            ])
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
        self.title(cx.l10n()).into()
    }
}

impl Render for AccessSheet {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let l10n = cx.l10n().clone();
        let t = cx.conduit().clone();
        let mut body: Vec<AnyElement> = vec![
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
                        .child(self.title(&l10n)),
                )
                .child(
                    div()
                        .text_size(px(t.metrics.small + 0.5))
                        .line_height(relative(1.4))
                        .text_color(t.roles.text_subtle)
                        .child(self.resource_name.clone()),
                )
                .into_any_element(),
        ];
        match self.state.clone() {
            None => body.push(
                div()
                    .px(px(4.))
                    .text_color(t.roles.text_subtle)
                    .child(
                        self.failure
                            .clone()
                            .unwrap_or_else(|| l10n.desktop_loading()),
                    )
                    .into_any_element(),
            ),
            Some(state) => {
                if Self::offers_audience(&state) {
                    body.push(self.audience_section(&state, &l10n, window, cx));
                }
                let mut rows = vec![];
                if let Some(owner) = state.owner_name.clone() {
                    rows.push(
                        forms::form_row(
                            l10n.library_access_owner(),
                            controls::value(owner, cx),
                            cx,
                        )
                        .into_any_element(),
                    );
                }
                let grants = self.grants.clone();
                for (i, grant) in grants.iter().enumerate() {
                    rows.push(self.grant_row(i, grant, &state, &l10n, window, cx));
                }
                if grants.is_empty() {
                    rows.push(
                        div()
                            .px(px(12.))
                            .py(px(10.))
                            .text_color(t.roles.text_subtle)
                            .child(l10n.desktop_access_empty())
                            .into_any_element(),
                    );
                }
                body.push(
                    grouped_section(
                        Some(l10n.workspace_access_people_heading().into()),
                        rows,
                        (!state.can_edit).then(|| l10n.library_access_owner_only_notice().into()),
                        cx,
                    )
                    .into_any_element(),
                );
                if self.may_add() {
                    let mut add = vec![
                        div()
                            .p(px(4.))
                            .child(forms::field_hinted(
                                l10n.workspace_access_add_people(),
                                &self.search,
                                Some(l10n.desktop_access_search_hint().into()),
                                None,
                                None,
                                window,
                                cx,
                            ))
                            .into_any_element(),
                    ];
                    add.extend(self.results_rows(&l10n, cx));
                    body.push(grouped_section(None, add, None, cx).into_any_element());
                }
            }
        }
        if let Some(failure) = &self.failure
            && self.state.is_some()
        {
            body.push(forms::form_error("access-failure", failure.clone(), cx).into_any_element());
        }
        div()
            .id("access-sheet")
            .w_full()
            .flex()
            .flex_col()
            .gap(px(16.))
            .on_action(cx.listener(|this, a: &SettingsChoice, _, cx| this.on_choice(a, cx)))
            .children(body)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::views::sheet::bench::bench;

    fn principal(kind: &str, id: &str) -> AccessPrincipal {
        serde_json::from_value(serde_json::json!({"type": kind, "id": id, "name": id})).unwrap()
    }

    #[gpui_kit::test]
    fn only_what_the_server_allows_can_be_added(cx: &mut gpui_kit::TestAppContext) {
        let (daemon, stores, vcx) = bench(cx);
        daemon.returns::<methods::AccessGet>(
            serde_json::from_value(serde_json::json!({
                "kind": "folder", "id": "f1", "canEdit": true,
                "allowUsers": true, "allowGroups": false
            }))
            .unwrap(),
        );
        let s = stores.clone();
        let sheet = vcx
            .update(|window, cx| {
                sheet::open(window, WIDTH, cx, move |w, cx| {
                    AccessSheet::new(
                        s,
                        AccessResourceKind::Folder,
                        "f1".into(),
                        "Trips".into(),
                        w,
                        cx,
                    )
                })
            })
            .unwrap();
        vcx.run_until_parked();
        vcx.update(|window, cx| {
            sheet.update(cx, |s, cx| {
                s.add(&principal("group", "hikers"), window, cx);
                s.add(&principal("user", "robin"), window, cx);
            })
        });
        sheet.read_with(vcx, |s, _| {
            let added: Vec<&str> = s.grants.iter().map(|g| g.principal_id.as_str()).collect();
            assert_eq!(
                added,
                ["robin"],
                "a group was added on a server that forbids it"
            );
        });
        // While a save is on its way, nobody more is added.
        let held = daemon.hold::<methods::AccessSet>();
        vcx.update(|window, cx| {
            sheet.update(cx, |s, cx| {
                s.save(window, cx);
                s.add(&principal("user", "sam"), window, cx);
            })
        });
        sheet.read_with(vcx, |s, _| assert_eq!(s.grants.len(), 1));
        drop(held);
    }

    /// Access for folder f1 open over the bench, Robin added and a save
    /// held: the sheet and the held save.
    fn saving_robin(
        cx: &mut gpui_kit::TestAppContext,
        refused: bool,
    ) -> (
        crate::stores::rpc::fake::FakeDaemon,
        Entity<AccessSheet>,
        crate::stores::rpc::fake::Hold,
        &mut gpui_kit::VisualTestContext,
    ) {
        let (daemon, stores, vcx) = bench(cx);
        daemon.returns::<methods::AccessGet>(
            serde_json::from_value(serde_json::json!({
                "kind": "folder", "id": "f1", "canEdit": true,
                "allowUsers": true, "allowGroups": false
            }))
            .unwrap(),
        );
        if refused {
            daemon.once::<methods::AccessSet>(Err(conduit_protocol::RpcError::internal("down")));
        } else {
            // The server keeps nobody of those asked.
            daemon.returns::<methods::AccessSet>(
                serde_json::from_value(serde_json::json!({
                    "kind": "folder", "id": "f1", "canEdit": true,
                    "allowUsers": true, "allowGroups": false, "grants": []
                }))
                .unwrap(),
            );
        }
        let s = stores.clone();
        let sheet = vcx
            .update(|window, cx| {
                sheet::open(window, WIDTH, cx, move |w, cx| {
                    AccessSheet::new(
                        s,
                        AccessResourceKind::Folder,
                        "f1".into(),
                        "Trips".into(),
                        w,
                        cx,
                    )
                })
            })
            .unwrap();
        vcx.run_until_parked();
        let held = daemon.hold::<methods::AccessSet>();
        vcx.update(|window, cx| {
            sheet.update(cx, |s, cx| {
                s.add(&principal("user", "robin"), window, cx);
                s.save(window, cx);
            })
        });
        (daemon, sheet, held, vcx)
    }

    fn quit_counted(vcx: &mut gpui_kit::VisualTestContext) -> std::rc::Rc<std::cell::Cell<u32>> {
        let quits = std::rc::Rc::new(std::cell::Cell::new(0));
        let counted = quits.clone();
        vcx.update(|_, cx| {
            sheet::quit_with(
                cx,
                std::rc::Rc::new(move |_| counted.set(counted.get() + 1)),
            )
        });
        vcx.run_until_parked();
        quits
    }

    fn settle(vcx: &mut gpui_kit::VisualTestContext) {
        for _ in 0..2 {
            vcx.run_until_parked();
            vcx.executor()
                .advance_clock(std::time::Duration::from_secs(5));
        }
        vcx.run_until_parked();
    }

    fn beeps(vcx: &mut gpui_kit::VisualTestContext) -> u32 {
        vcx.update(|_, cx| cx.global::<crate::shell::sheet::Beeps>().0)
    }

    fn sheet_up(vcx: &mut gpui_kit::VisualTestContext) -> bool {
        vcx.update(|_, cx| sheet::current::<AccessSheet>(cx))
            .is_some()
    }

    /// Quit while a save is out queues nothing: a beep, and the sheet stays.
    /// When the server keeps only part of it, the warning stays up and
    /// nothing quits.
    #[gpui_kit::test]
    fn quit_during_a_save_beeps_and_stays(cx: &mut gpui_kit::TestAppContext) {
        let (_daemon, sheet, held, vcx) = saving_robin(cx, false);
        let quits = quit_counted(vcx);
        assert_eq!(beeps(vcx), 1, "Quit during the save did not beep");
        assert!(sheet_up(vcx));
        drop(held);
        settle(vcx);
        assert!(
            sheet_up(vcx),
            "the partial save's warning was dismissed unseen"
        );
        sheet.read_with(vcx, |s, _| {
            assert!(s.failure.is_some(), "the partial save says nothing")
        });
        assert_eq!(quits.get(), 0, "a Quit waited on the save");
    }

    /// After a save fails, the sheet is idle and dirty: ⌘Q asks, and Discard
    /// quits; answered No, the Quit is dropped and the next ⌘Q asks again.
    #[gpui_kit::test]
    fn after_a_failed_save_quit_asks(cx: &mut gpui_kit::TestAppContext) {
        let (_daemon, sheet, held, vcx) = saving_robin(cx, true);
        drop(held);
        settle(vcx);
        sheet.read_with(vcx, |s, _| {
            assert!(s.failure.is_some(), "the failure is hidden")
        });
        // The bench answers No: the sheet stays, nothing quits.
        let kept = quit_counted(vcx);
        settle(vcx);
        assert!(sheet_up(vcx));
        assert_eq!(kept.get(), 0);
        vcx.update(|_, cx| cx.set_global(crate::shell::sheet::AutoAnswer(Some(true))));
        let quits = quit_counted(vcx);
        settle(vcx);
        assert!(!sheet_up(vcx), "Discard left the sheet open");
        assert_eq!(quits.get(), 1, "Discard after the failed save did not quit");
        assert_eq!(kept.get(), 0, "the Quit answered No came back");
    }

    /// The discard question is up when another account signs in and closes
    /// the sheet: that ends the Quit (the app stays), and a later Quit quits
    /// as usual.
    #[gpui_kit::test]
    fn a_sheet_closed_for_another_account_drops_its_quit(cx: &mut gpui_kit::TestAppContext) {
        let (daemon, stores, vcx) = bench(cx);
        daemon.returns::<methods::AccessGet>(
            serde_json::from_value(serde_json::json!({
                "kind": "folder", "id": "f1", "canEdit": true,
                "allowUsers": true, "allowGroups": false
            }))
            .unwrap(),
        );
        let s = stores.clone();
        let sheet = vcx
            .update(|window, cx| {
                sheet::open(window, WIDTH, cx, move |w, cx| {
                    AccessSheet::new(
                        s,
                        AccessResourceKind::Folder,
                        "f1".into(),
                        "Trips".into(),
                        w,
                        cx,
                    )
                })
            })
            .unwrap();
        vcx.run_until_parked();
        vcx.update(|window, cx| {
            sheet.update(cx, |s, cx| s.add(&principal("user", "robin"), window, cx))
        });
        vcx.update(|_, cx| cx.set_global(crate::shell::sheet::HeldAnswers::default()));
        let first = quit_counted(vcx);
        crate::views::sheet::bench::switch_account(&stores, vcx);
        settle(vcx);
        assert!(!sheet_up(vcx), "the account switch left the sheet open");
        // The question that was up is answered late: nothing is left to quit.
        vcx.update(|_, cx| {
            let held = std::mem::take(&mut cx.global_mut::<crate::shell::sheet::HeldAnswers>().0);
            for tx in held {
                let _ = tx.send(true);
            }
            cx.remove_global::<crate::shell::sheet::HeldAnswers>();
        });
        settle(vcx);
        assert_eq!(first.get(), 0, "the account switch quit the app");
        let later = quit_counted(vcx);
        settle(vcx);
        assert_eq!(later.get(), 1, "a later Quit did nothing");
    }

    #[test]
    fn each_kind_is_titled_for_what_it_shares() {
        let l = L10n::new("en");
        let titles: Vec<String> = [
            AccessResourceKind::Chat,
            AccessResourceKind::Folder,
            AccessResourceKind::Note,
            AccessResourceKind::Model,
            AccessResourceKind::Knowledge,
            AccessResourceKind::Prompt,
            AccessResourceKind::Tool,
            AccessResourceKind::Skill,
        ]
        .into_iter()
        .map(|k| title_for(k, &l))
        .collect();
        assert_eq!(
            titles,
            [
                "Who Has Access",
                "Share Folder",
                "Share Note",
                "Share Model",
                "Share Knowledge",
                "Share Prompt",
                "Share Tool",
                "Share Skill"
            ]
        );
    }
}
