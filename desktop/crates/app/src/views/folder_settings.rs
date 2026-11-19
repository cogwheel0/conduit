//! Folder Settings: a folder's name and icon, the system prompt the server
//! applies to every chat in it, the models its new chats start on, and its
//! project knowledge, as mobile's folder page (Edit Folder, Project
//! Settings) edits them, in one window sheet on the main window (a folder's
//! context menu › Folder Settings…, or ⌘I on a selected folder, as Finder's
//! Get Info). Share Folder… and New Chat in Folder start from here too.
//!
//! The daemon reads the folder from the server (`folders.get`) and writes
//! only what changed (`folders.update`): the name and icon at once, the
//! project defaults through the core's durable folder edit.

use std::rc::Rc;

use conduit_components::ActiveConduitTheme as _;
use conduit_components::assets::{IconName, icon};
use conduit_components::theme::with_alpha;
use conduit_components::views::focus::{ControlExt as _, RadioGroupExt as _, radio_option_id};
use conduit_components::views::kit::{Button, IconButton, grouped_section};
use conduit_protocol::{
    ComposerSearch, FolderKnowledgeItem, FolderRef, FolderSettings, FolderUpdate, KnowledgeQuery,
    NoticeLevel, methods,
};
use gpui_kit::component::input::{InputEvent, InputState, Textarea, TextareaState};
use gpui_kit::component::native_menu::NativeMenu;
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
use crate::views::sheet::{self, SheetBody};

/// The sheet's width.
pub const WIDTH: f32 = 560.;

/// How many knowledge bases and files the Add Knowledge menu lists.
const MENU_ITEMS: usize = 30;

/// Opens the sheet for `folder_id` on the main window.
pub fn open(stores: Stores, folder_id: &str, window: &mut Window, cx: &mut App) {
    let folder_id = folder_id.to_string();
    sheet::open(window, WIDTH, cx, move |w, cx| {
        FolderSettingsSheet::new(stores, folder_id, w, cx)
    });
}

/// What the form holds of the folder.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct FolderEdit {
    pub name: String,
    pub icon: Option<String>,
    pub system_prompt: String,
    pub model_ids: Vec<String>,
    pub knowledge: Vec<FolderKnowledgeItem>,
}

impl FolderEdit {
    fn of(settings: &FolderSettings) -> Self {
        Self {
            name: settings.name.clone(),
            icon: settings.icon.clone(),
            system_prompt: settings.system_prompt.clone(),
            model_ids: settings.model_ids.clone(),
            knowledge: settings.knowledge.clone(),
        }
    }
}

pub struct FolderSettingsSheet {
    stores: Stores,
    rpc: Rpc,
    pub folder_id: String,
    pub settings: Option<FolderSettings>,
    pub edit: FolderEdit,
    initial: FolderEdit,
    name: Entity<InputState>,
    prompt: Entity<TextareaState>,
    /// What Add Knowledge offers: knowledge bases, then files.
    bases: Vec<FolderKnowledgeItem>,
    files: Vec<FolderKnowledgeItem>,
    saving: bool,
    pub failure: Option<String>,
    _subscriptions: Vec<Subscription>,
    _load: Option<Task<()>>,
    /// Closes the sheet when another account becomes active.
    _account: Subscription,
}

impl FolderSettingsSheet {
    pub fn new(
        stores: Stores,
        folder_id: String,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Self {
        let rpc = stores.connection.read(cx).rpc();
        let l10n = cx.l10n().clone();
        let name = forms::input(l10n.folder_name(), false, window, cx);
        let prompt = cx.new(|cx| {
            TextareaState::new(window, cx)
                .auto_grow(3, 10)
                .placeholder(l10n.enter_system_prompt())
        });
        let subscriptions = vec![
            cx.subscribe_in(
                &name,
                window,
                |this, state, e: &InputEvent, window, cx| match e {
                    InputEvent::Change => {
                        this.edit.name = state.read(cx).value().to_string();
                        this.failure = None;
                        cx.notify();
                    }
                    InputEvent::PressEnter { .. } => this.save(window, cx),
                    _ => {}
                },
            ),
            cx.subscribe_in(&prompt, window, |this, state, e: &InputEvent, _, cx| {
                if matches!(e, InputEvent::Change) {
                    this.edit.system_prompt = state.read(cx).value().to_string();
                    this.failure = None;
                    cx.notify();
                }
            }),
        ];
        let account = sheet::close_with_account(&stores, cx);
        let mut this = Self {
            _account: account,
            stores,
            rpc,
            folder_id,
            settings: None,
            edit: FolderEdit::default(),
            initial: FolderEdit::default(),
            name,
            prompt,
            bases: vec![],
            files: vec![],
            saving: false,
            failure: None,
            _subscriptions: subscriptions,
            _load: None,
        };
        this.load(window, cx);
        this
    }

    fn load(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let call = self.rpc.call::<methods::FoldersGet>(&FolderRef {
            folder_id: self.folder_id.clone(),
        });
        let bases = self
            .rpc
            .call::<methods::ComposerKnowledge>(&KnowledgeQuery::default());
        let files = self
            .rpc
            .call::<methods::FilesList>(&ComposerSearch::default());
        let handle = window.window_handle();
        self._load = Some(
            cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
                let result = call.await;
                let bases = bases.await;
                let files = files.await;
                let _ = handle.update(cx, |_, window, cx| {
                    let _ = this.update(cx, |s, cx| {
                        s.bases = bases
                            .map(|l| {
                                l.items
                                    .into_iter()
                                    .take(MENU_ITEMS)
                                    .map(|k| FolderKnowledgeItem {
                                        r#type: "collection".into(),
                                        id: k.id,
                                        name: k.name,
                                        missing: false,
                                    })
                                    .collect()
                            })
                            .unwrap_or_default();
                        s.files = files
                            .map(|l| {
                                l.items
                                    .into_iter()
                                    .take(MENU_ITEMS)
                                    .map(|f| FolderKnowledgeItem {
                                        r#type: "file".into(),
                                        id: f.id,
                                        name: f.name,
                                        missing: false,
                                    })
                                    .collect()
                            })
                            .unwrap_or_default();
                        match result {
                            Ok(settings) => s.adopt(settings, window, cx),
                            Err(e) => {
                                log::warn!("folders.get: {e}");
                                s.failure = Some(failure_text(&e, &cx.l10n().clone()));
                                cx.notify();
                            }
                        }
                    });
                });
            }),
        );
    }

    fn adopt(&mut self, settings: FolderSettings, window: &mut Window, cx: &mut Context<Self>) {
        let edit = FolderEdit::of(&settings);
        let (name, prompt) = (edit.name.clone(), edit.system_prompt.clone());
        self.name.update(cx, |s, cx| s.set_value(name, window, cx));
        self.prompt
            .update(cx, |s, cx| s.set_value(prompt, window, cx));
        self.initial = edit.clone();
        self.edit = edit;
        self.settings = Some(settings);
        cx.notify();
    }

    pub fn is_dirty(&self) -> bool {
        self.edit != self.initial
    }

    /// Types the folder's system prompt, as the user would.
    pub fn type_prompt(&mut self, text: &str, window: &mut Window, cx: &mut Context<Self>) {
        let value = text.to_string();
        self.prompt
            .update(cx, |s, cx| s.set_value(value, window, cx));
        self.edit.system_prompt = text.to_string();
        cx.notify();
    }

    fn can_save(&self) -> bool {
        !self.saving && self.is_dirty() && !self.edit.name.trim().is_empty()
    }

    /// What changed, as `folders.update` takes it.
    pub fn update_request(&self) -> FolderUpdate {
        let (a, b) = (&self.edit, &self.initial);
        FolderUpdate {
            id: self.folder_id.clone(),
            name: (a.name.trim() != b.name.trim()).then(|| a.name.trim().to_string()),
            icon: (a.icon != b.icon).then(|| a.icon.clone().unwrap_or_default()),
            system_prompt: (a.system_prompt.trim() != b.system_prompt.trim())
                .then(|| a.system_prompt.trim().to_string()),
            model_ids: (a.model_ids != b.model_ids).then(|| a.model_ids.clone()),
            knowledge: (a.knowledge != b.knowledge).then(|| a.knowledge.clone()),
        }
    }

    pub fn save(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if !self.can_save() {
            return;
        }
        self.saving = true;
        self.failure = None;
        cx.notify();
        let sent = self.edit.clone();
        let call = self
            .rpc
            .call::<methods::FoldersUpdate>(&self.update_request());
        let handle = window.window_handle();
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            let result = call.await;
            let _ = handle.update(cx, |_, window, cx| {
                let _ = this.update(cx, |s, cx| {
                    s.saving = false;
                    let l10n = cx.l10n().clone();
                    match result {
                        Ok(settings) => {
                            s.stores
                                .toasts
                                .update(cx, |t, cx| t.show(NoticeLevel::Info, l10n.saved(), cx));
                            // The sidebar shows the new name and icon.
                            s.stores.chat_list.update(cx, |c, cx| c.refresh(cx));
                            if s.edit == sent {
                                s.adopt(settings, window, cx);
                                sheet::dismiss(cx);
                            } else {
                                // Changed again while it saved: what was
                                // saved is the new start, the rest stays to
                                // be saved.
                                s.initial = FolderEdit::of(&settings);
                                s.settings = Some(settings);
                            }
                        }
                        Err(e) => {
                            log::warn!("folders.update: {e}");
                            s.failure = Some(failure_text(&e, &l10n));
                        }
                    }
                    cx.notify();
                });
            });
        })
        .detach();
    }

    pub fn set_icon(&mut self, icon: Option<String>, cx: &mut Context<Self>) {
        self.edit.icon = icon;
        cx.notify();
    }

    fn remove_model(&mut self, index: usize, cx: &mut Context<Self>) {
        if index < self.edit.model_ids.len() {
            self.edit.model_ids.remove(index);
            cx.notify();
        }
    }

    fn move_model_up(&mut self, index: usize, cx: &mut Context<Self>) {
        if index > 0 && index < self.edit.model_ids.len() {
            self.edit.model_ids.swap(index - 1, index);
            cx.notify();
        }
    }

    fn remove_knowledge(&mut self, index: usize, cx: &mut Context<Self>) {
        if index < self.edit.knowledge.len() {
            self.edit.knowledge.remove(index);
            cx.notify();
        }
    }

    pub fn on_choice(&mut self, action: &SettingsChoice, cx: &mut Context<Self>) {
        match action.menu.as_str() {
            "folder-add-model" => {
                if !self.edit.model_ids.contains(&action.value) {
                    self.edit.model_ids.push(action.value.clone());
                }
            }
            "folder-add-knowledge" => {
                let Some((kind, id)) = action.value.split_once(':') else {
                    return;
                };
                let found = self
                    .bases
                    .iter()
                    .chain(self.files.iter())
                    .find(|k| k.r#type == kind && k.id == id)
                    .cloned();
                if let Some(item) = found
                    && !self
                        .edit
                        .knowledge
                        .iter()
                        .any(|k| k.r#type == item.r#type && k.id == item.id)
                {
                    self.edit.knowledge.push(item);
                }
            }
            _ => return,
        }
        cx.notify();
    }

    /// Leaves the sheet for `then` (New Chat, Share): unsaved edits are
    /// thrown away only once the user says so, as Cancel asks; not while a
    /// save is on its way.
    fn leave_then(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
        then: fn(&mut Self, &mut Context<Self>),
    ) {
        if self.saving {
            return;
        }
        if !self.is_dirty() {
            then(self, cx);
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
        cx.spawn(async move |this: WeakEntity<Self>, cx: &mut AsyncApp| {
            if ask.await {
                let _ = this.update(cx, then);
            }
        })
        .detach();
    }

    /// New Chat in Folder, from the sheet: it closes, and the new chat opens.
    fn new_chat(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.leave_then(window, cx, Self::start_new_chat);
    }

    fn start_new_chat(&mut self, cx: &mut Context<Self>) {
        let folder = self.folder_id.clone();
        let navigation = self.stores.navigation.clone();
        sheet::dismiss(cx);
        navigation.update(cx, |n, cx| n.new_chat_in_folder(folder, cx));
        cx.defer(|cx| {
            if let Some(handle) = cx
                .try_global::<crate::AppState>()
                .and_then(|s| s.main_window)
            {
                let _ = handle.update(cx, |_, window, cx| {
                    window.dispatch_action(Box::new(crate::actions::FocusComposer), cx)
                });
            }
        });
    }

    fn share(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.leave_then(window, cx, Self::open_share);
    }

    fn open_share(&mut self, cx: &mut Context<Self>) {
        // The folder's saved name: edits not saved went with the sheet.
        let (stores, id, name) = (
            self.stores.clone(),
            self.folder_id.clone(),
            self.initial.name.clone(),
        );
        // One sheet at a time: this one goes, then Share Folder comes.
        sheet::dismiss(cx);
        cx.defer(move |cx| {
            if let Some(handle) = cx
                .try_global::<crate::AppState>()
                .and_then(|s| s.main_window)
            {
                let _ = handle.update(cx, |_, window, cx| {
                    crate::views::access_sheet::open_for_folder(stores, &id, name, window, cx)
                });
            }
        });
    }

    // ── Drawing ────────────────────────────────────────────────────────

    fn icon_row(
        &self,
        settings: &FolderSettings,
        l10n: &L10n,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let t = cx.conduit().clone();
        let r = t.roles;
        let mut options: Vec<(Option<String>, String, String)> =
            vec![(None, String::new(), l10n.default_label())];
        options.extend(settings.icon_choices.iter().map(|c| {
            (
                Some(c.alias.clone()),
                c.emoji.clone(),
                icon_label(&c.alias, l10n),
            )
        }));
        let selected = options
            .iter()
            .position(|(alias, _, _)| *alias == self.edit.icon)
            .unwrap_or(0);
        let count = options.len();
        let view = cx.entity().downgrade();
        let pick_view = view.clone();
        let aliases: Vec<Option<String>> = options.iter().map(|o| o.0.clone()).collect();
        let tiles = options
            .into_iter()
            .enumerate()
            .map(|(i, (alias, emoji, label))| {
                let on = i == selected;
                let view = view.clone();
                div()
                    .id(radio_option_id("folder-icon", i, on))
                    .role(Role::RadioButton)
                    .aria_label(SharedString::from(label.clone()))
                    .aria_toggled(if on {
                        gpui_kit::Toggled::True
                    } else {
                        gpui_kit::Toggled::False
                    })
                    .size(px(30.))
                    .flex()
                    .flex_none()
                    .items_center()
                    .justify_center()
                    .rounded(px(7.))
                    .cursor_pointer()
                    .when(on, |d| {
                        d.bg(with_alpha(r.text, if t.dark { 0.16 } else { 0.09 }))
                            .border_1()
                            .border_color(r.border_strong)
                    })
                    .when(!on, |d| d.hover(|s| s.bg(r.overlay_hover)))
                    .child(if alias.is_none() {
                        icon(IconName::Folder, 15., r.text_subtle).into_any_element()
                    } else {
                        div().text_size(px(16.)).child(emoji).into_any_element()
                    })
                    .tip(label, None)
                    .radio_option_outline(on, 7., cx)
                    .on_click(move |_, _, cx| {
                        let alias = alias.clone();
                        let _ = view.update(cx, |v, cx| v.set_icon(alias, cx));
                    })
            });
        let group = div()
            .id("folder-icon-group")
            .role(Role::RadioGroup)
            .aria_label(SharedString::from(l10n.icon()))
            .flex()
            .flex_wrap()
            .gap(px(6.))
            .children(tiles)
            .radio_group(
                selected,
                count,
                Some(Rc::new(move |i, _, cx| {
                    let alias = aliases.get(i).cloned().flatten();
                    let _ = pick_view.update(cx, |v, cx| v.set_icon(alias, cx));
                })),
                cx,
            );
        forms::form_row(l10n.icon(), group, cx).into_any_element()
    }

    fn models_section(
        &self,
        settings: &FolderSettings,
        l10n: &L10n,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let t = cx.conduit().clone();
        let view = cx.entity().downgrade();
        let name_of = |id: &str| {
            settings
                .model_choices
                .iter()
                .find(|m| m.id == id)
                .map(|m| m.name.clone())
        };
        let mut rows: Vec<AnyElement> = self
            .edit
            .model_ids
            .iter()
            .enumerate()
            .map(|(i, id)| {
                let name = name_of(id);
                let shown = name.clone().unwrap_or_else(|| id.clone());
                let up_view = view.clone();
                let remove_view = view.clone();
                div()
                    .id(ElementId::NamedInteger("folder-model".into(), i as u64))
                    .px(px(12.))
                    .min_h(px(40.))
                    .flex()
                    .items_center()
                    .gap(px(8.))
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .flex()
                            .flex_col()
                            .child(div().truncate().child(shown.clone()))
                            .when(name.is_none(), |d| {
                                d.child(
                                    div()
                                        .text_size(px(t.metrics.small))
                                        .text_color(t.roles.text_subtle)
                                        .child(l10n.folder_project_not_available()),
                                )
                            }),
                    )
                    .when(i > 0, |d| {
                        d.child(
                            IconButton::new(
                                ElementId::NamedInteger("folder-model-up".into(), i as u64),
                                IconName::ArrowUp,
                                l10n.folder_project_move_up(&shown),
                            )
                            .size(26., 14.)
                            .on_click(Rc::new(move |_, _, cx| {
                                let _ = up_view.update(cx, |v, cx| v.move_model_up(i, cx));
                            })),
                        )
                    })
                    .child(
                        IconButton::new(
                            ElementId::NamedInteger("folder-model-remove".into(), i as u64),
                            IconName::Minus,
                            l10n.folder_project_remove(&shown),
                        )
                        .size(26., 14.)
                        .on_click(Rc::new(move |_, _, cx| {
                            let _ = remove_view.update(cx, |v, cx| v.remove_model(i, cx));
                        })),
                    )
                    .into_any_element()
            })
            .collect();
        if rows.is_empty() {
            rows.push(note(l10n.folder_project_no_models(), cx));
        }
        let left: Vec<_> = settings
            .model_choices
            .iter()
            .filter(|m| !self.edit.model_ids.contains(&m.id))
            .cloned()
            .collect();
        let add = add_menu_button(
            "folder-add-model",
            l10n.folder_project_add_model(),
            left.is_empty(),
            move |menu| {
                left.iter().fold(menu, |menu, m| {
                    menu.menu(
                        m.name.clone(),
                        Box::new(SettingsChoice {
                            menu: "folder-add-model".into(),
                            value: m.id.clone(),
                        }),
                    )
                })
            },
            window,
            cx,
        );
        rows.push(
            div()
                .px(px(12.))
                .py(px(8.))
                .flex()
                .child(add)
                .into_any_element(),
        );
        grouped_section(
            Some(l10n.folder_project_models().into()),
            rows,
            Some(l10n.folder_project_models_hint().into()),
            cx,
        )
        .into_any_element()
    }

    fn knowledge_section(
        &self,
        l10n: &L10n,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let t = cx.conduit().clone();
        let view = cx.entity().downgrade();
        let mut rows: Vec<AnyElement> = self
            .edit
            .knowledge
            .iter()
            .enumerate()
            .map(|(i, item)| {
                let kind = match item.r#type.as_str() {
                    "collection" => l10n.folder_project_kind_collection(),
                    "note" => l10n.folder_project_kind_note(),
                    _ => l10n.folder_project_kind_file(),
                };
                let glyph = match item.r#type.as_str() {
                    "collection" => IconName::LibraryBig,
                    "note" => IconName::NotebookPen,
                    _ => IconName::FileText,
                };
                let remove_view = view.clone();
                let name = if item.name.is_empty() {
                    item.id.clone()
                } else {
                    item.name.clone()
                };
                div()
                    .id(ElementId::NamedInteger("folder-knowledge".into(), i as u64))
                    .px(px(12.))
                    .min_h(px(40.))
                    .flex()
                    .items_center()
                    .gap(px(10.))
                    .child(icon(glyph, 15., t.roles.text_subtle))
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .flex()
                            .flex_col()
                            .child(div().truncate().child(name.clone()))
                            .child(
                                div()
                                    .text_size(px(t.metrics.small))
                                    .text_color(t.roles.text_subtle)
                                    .child(if item.missing {
                                        l10n.folder_project_not_available()
                                    } else {
                                        kind
                                    }),
                            ),
                    )
                    .child(
                        IconButton::new(
                            ElementId::NamedInteger("folder-knowledge-remove".into(), i as u64),
                            IconName::Minus,
                            l10n.folder_project_remove(&name),
                        )
                        .size(26., 14.)
                        .on_click(Rc::new(move |_, _, cx| {
                            let _ = remove_view.update(cx, |v, cx| v.remove_knowledge(i, cx));
                        })),
                    )
                    .into_any_element()
            })
            .collect();
        if rows.is_empty() {
            rows.push(note(l10n.folder_project_no_knowledge(), cx));
        }
        let taken = |k: &FolderKnowledgeItem| {
            self.edit
                .knowledge
                .iter()
                .any(|e| e.r#type == k.r#type && e.id == k.id)
        };
        let bases: Vec<_> = self.bases.iter().filter(|k| !taken(k)).cloned().collect();
        let files: Vec<_> = self.files.iter().filter(|k| !taken(k)).cloned().collect();
        let empty = bases.is_empty() && files.is_empty();
        let (bases_heading, files_heading) = (
            l10n.desktop_knowledge_bases_heading(),
            l10n.desktop_context_files(),
        );
        let add = add_menu_button(
            "folder-add-knowledge",
            l10n.folder_project_add_knowledge(),
            empty,
            move |mut menu| {
                for (heading, items) in [(&bases_heading, &bases), (&files_heading, &files)] {
                    if items.is_empty() {
                        continue;
                    }
                    // A heading, as the + menu's (a disabled item).
                    menu = menu.menu_with_disabled(
                        heading.clone(),
                        true,
                        Box::new(SettingsChoice {
                            menu: "folder-heading".into(),
                            value: String::new(),
                        }),
                    );
                    for k in items {
                        menu = menu.menu(
                            k.name.clone(),
                            Box::new(SettingsChoice {
                                menu: "folder-add-knowledge".into(),
                                value: format!("{}:{}", k.r#type, k.id),
                            }),
                        );
                    }
                }
                menu
            },
            window,
            cx,
        );
        rows.push(
            div()
                .px(px(12.))
                .py(px(8.))
                .flex()
                .child(add)
                .into_any_element(),
        );
        grouped_section(Some(l10n.desktop_knowledge().into()), rows, None, cx).into_any_element()
    }
}

/// A pop-up "Add …" button: a native menu `build` fills.
fn add_menu_button(
    id: &'static str,
    label: String,
    empty: bool,
    build: impl Fn(NativeMenu) -> NativeMenu + 'static,
    window: &mut Window,
    _cx: &mut App,
) -> AnyElement {
    let _ = window;
    Button::new(id, label)
        .icon(IconName::Plus)
        .disabled(empty)
        .on_click(Rc::new(move |_, window, cx| {
            build(NativeMenu::new()).show(window.mouse_position(), window, cx);
        }))
        .into_any_element()
}

/// A row that says why a list is empty.
fn note(text: String, cx: &App) -> AnyElement {
    let t = cx.conduit();
    div()
        .px(px(12.))
        .py(px(10.))
        .text_size(px(t.metrics.control))
        .text_color(t.roles.text_subtle)
        .child(text)
        .into_any_element()
}

/// An icon choice's name, as mobile's folder sheet calls it.
fn icon_label(alias: &str, l10n: &L10n) -> String {
    match alias {
        "file_folder" => l10n.folder_icon_folder(),
        "open_file_folder" => l10n.folder_icon_open_folder(),
        "briefcase" => l10n.folder_icon_briefcase(),
        "books" => l10n.folder_icon_books(),
        "memo" => l10n.folder_icon_memo(),
        "card_index_dividers" => l10n.folder_icon_dividers(),
        "hammer_and_wrench" => l10n.folder_icon_tools(),
        "toolbox" => l10n.folder_icon_toolbox(),
        "sparkles" => l10n.folder_icon_sparkles(),
        "brain" => l10n.folder_icon_brain(),
        "rocket" => l10n.folder_icon_rocket(),
        "dart" => l10n.folder_icon_target(),
        // An icon chosen on the web: the shortcode Open WebUI names it with,
        // as the phone labels it.
        "" => l10n.folder_icon_generic(),
        other => other.replace('_', " "),
    }
}

/// What a refused `folders.*` call says.
fn failure_text(e: &conduit_protocol::RpcError, l10n: &L10n) -> String {
    match e.args.get("reason").map(String::as_str) {
        Some("readOnly") => l10n.folder_project_read_only(),
        Some("ownerChanged") => l10n.folder_project_owner_changed(),
        Some("unavailable") => l10n.folder_project_gone(),
        _ if e.code.as_str() == "resource.conflict" => l10n.desktop_folder_name_taken_message(),
        _ if e.code.as_str() == "resource.notFound" => l10n.folder_project_gone(),
        _ => l10n.error_message(),
    }
}

impl SheetBody for FolderSettingsSheet {
    fn busy(&self, _: &App) -> bool {
        self.saving
    }

    fn unsaved(&self, _: &App) -> bool {
        FolderSettingsSheet::is_dirty(self)
    }

    fn footer(&mut self, _: &mut Window, cx: &mut Context<Self>) -> Option<AnyElement> {
        let settings = self.settings.clone()?;
        let l10n = cx.l10n().clone();
        let view = cx.entity().downgrade();
        let (share_view, chat_view, cancel_view) = (view.clone(), view.clone(), view.clone());
        Some(
            div()
                .w_full()
                .flex()
                .items_center()
                .gap(px(8.))
                .when(settings.can_share, |d| {
                    d.child(
                        Button::new("folder-share", l10n.desktop_share_folder_menu()).on_click(
                            Rc::new(move |_, window, cx| {
                                let _ = share_view.update(cx, |v, cx| v.share(window, cx));
                            }),
                        ),
                    )
                })
                .when(settings.can_write, |d| {
                    d.child(
                        Button::new("folder-new-chat", l10n.desktop_folder_new_chat()).on_click(
                            Rc::new(move |_, window, cx| {
                                let _ = chat_view.update(cx, |v, cx| v.new_chat(window, cx));
                            }),
                        ),
                    )
                })
                .child(div().flex_1())
                .child(
                    Button::new("folder-cancel", l10n.cancel()).on_click(Rc::new(
                        move |_, window, cx| {
                            let _ = cancel_view.update(cx, |v, cx| v.cancel(window, cx));
                        },
                    )),
                )
                .child(
                    Button::new("folder-save", l10n.save())
                        .primary()
                        .disabled(!self.can_save())
                        .on_click(Rc::new(move |_, window, cx| {
                            let _ = view.update(cx, |v, cx| v.save(window, cx));
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
        cx.l10n().desktop_folder_settings_title().into()
    }
}

impl Render for FolderSettingsSheet {
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
                        .child(l10n.desktop_folder_settings_title()),
                )
                .child(
                    div()
                        .text_size(px(t.metrics.small + 0.5))
                        .line_height(relative(1.4))
                        .text_color(t.roles.text_subtle)
                        .child(match self.settings.as_ref() {
                            Some(s) if s.shared => s
                                .owner_name
                                .clone()
                                .map(|o| l10n.shared_folder_owner(&o))
                                .unwrap_or_default(),
                            _ => l10n.folder_project_settings_description(),
                        }),
                )
                .into_any_element(),
        ];
        let Some(settings) = self.settings.clone() else {
            body.push(
                div()
                    .px(px(4.))
                    .text_color(t.roles.text_subtle)
                    .child(
                        self.failure
                            .clone()
                            .unwrap_or_else(|| l10n.desktop_loading()),
                    )
                    .into_any_element(),
            );
            return div()
                .id("folder-settings")
                .flex()
                .flex_col()
                .gap(px(16.))
                .children(body);
        };
        if settings.can_rename {
            body.push(
                grouped_section(
                    None,
                    vec![
                        forms::field(l10n.folder_name(), &self.name, None, None, window, cx)
                            .into_any_element(),
                        self.icon_row(&settings, &l10n, cx),
                    ],
                    None,
                    cx,
                )
                .into_any_element(),
            );
        }
        if settings.can_edit_system_prompt {
            body.push(
                grouped_section(
                    Some(l10n.system_prompt().into()),
                    vec![
                        div()
                            .id("folder-system-prompt")
                            .p(px(12.))
                            .child(Textarea::new(&self.prompt))
                            .into_any_element(),
                    ],
                    None,
                    cx,
                )
                .into_any_element(),
            );
        }
        if settings.can_write {
            body.push(self.models_section(&settings, &l10n, window, cx));
            body.push(self.knowledge_section(&l10n, window, cx));
        } else {
            body.push(note(l10n.folder_project_read_only(), cx));
        }
        if let Some(failure) = &self.failure {
            body.push(
                forms::form_error("folder-settings-failure", failure.clone(), cx)
                    .into_any_element(),
            );
        }
        div()
            .id("folder-settings")
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
            .on_action(cx.listener(|this, a: &SettingsChoice, _, cx| this.on_choice(a, cx)))
            .children(body)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::views::sheet::bench::bench;

    /// A save is out but the fields are back as they were (A, then B, Save,
    /// then A again): the sheet looks clean, yet it is busy. Quit beeps; it
    /// neither quits nor asks.
    #[gpui_kit::test]
    fn quit_during_a_save_beeps_even_when_the_fields_look_clean(cx: &mut gpui_kit::TestAppContext) {
        let (daemon, stores, vcx) = bench(cx);
        daemon.returns::<methods::FoldersGet>(
            serde_json::from_value(serde_json::json!({
                "id": "f1", "name": "Trips", "systemPrompt": "Plan trips.",
                "canRename": true, "canWrite": true, "canEditSystemPrompt": true
            }))
            .unwrap(),
        );
        let s = stores.clone();
        let sheet = vcx
            .update(|window, cx| {
                sheet::open(window, WIDTH, cx, move |w, cx| {
                    FolderSettingsSheet::new(s, "f1".into(), w, cx)
                })
            })
            .unwrap();
        vcx.run_until_parked();
        let held = daemon.hold::<methods::FoldersUpdate>();
        vcx.update(|_, cx| cx.set_global(crate::shell::sheet::HeldAnswers::default()));
        vcx.update(|window, cx| {
            sheet.update(cx, |s, cx| {
                s.type_prompt("Plan trips by train.", window, cx);
                s.save(window, cx);
                s.type_prompt("Plan trips.", window, cx);
            })
        });
        vcx.run_until_parked();
        sheet.read_with(vcx, |s, _| {
            assert!(!s.is_dirty(), "the fields are not back")
        });
        let quits = std::rc::Rc::new(std::cell::Cell::new(0));
        let counted = quits.clone();
        vcx.update(|_, cx| {
            sheet::quit_with(
                cx,
                std::rc::Rc::new(move |_| counted.set(counted.get() + 1)),
            )
        });
        vcx.run_until_parked();
        vcx.executor()
            .advance_clock(std::time::Duration::from_secs(5));
        vcx.run_until_parked();
        assert_eq!(
            vcx.update(|_, cx| cx.global::<crate::shell::sheet::Beeps>().0),
            1,
            "Quit during the save did not beep"
        );
        assert_eq!(quits.get(), 0, "Quit closed a sheet whose save was out");
        assert!(
            vcx.update(|_, cx| sheet::current::<FolderSettingsSheet>(cx))
                .is_some()
        );
        assert_eq!(
            vcx.update(|_, cx| cx.global::<crate::shell::sheet::HeldAnswers>().0.len()),
            0,
            "Quit asked during the save"
        );
        drop(held);
    }

    #[gpui_kit::test]
    fn new_chat_asks_before_throwing_edits_away(cx: &mut gpui_kit::TestAppContext) {
        let (daemon, stores, vcx) = bench(cx);
        daemon.returns::<methods::FoldersGet>(
            serde_json::from_value(serde_json::json!({
                "id": "f1", "name": "Trips", "systemPrompt": "Plan trips.",
                "canRename": true, "canWrite": true, "canEditSystemPrompt": true
            }))
            .unwrap(),
        );
        let s = stores.clone();
        let sheet = vcx
            .update(|window, cx| {
                sheet::open(window, WIDTH, cx, move |w, cx| {
                    FolderSettingsSheet::new(s, "f1".into(), w, cx)
                })
            })
            .unwrap();
        vcx.run_until_parked();
        vcx.update(|window, cx| {
            sheet.update(cx, |s, cx| {
                s.type_prompt("Plan trips by train.", window, cx);
                s.new_chat(window, cx);
            })
        });
        vcx.run_until_parked();
        // Asked, and kept editing (the bench answers no).
        assert!(
            vcx.update(|_, cx| sheet::current::<FolderSettingsSheet>(cx))
                .is_some()
        );
        assert_eq!(
            stores
                .navigation
                .read_with(vcx, |n, _| n.new_chat_folder().map(str::to_string)),
            None
        );
        // Yes: the edits go, the new chat opens in the folder.
        vcx.update(|_, cx| cx.set_global(crate::shell::sheet::AutoAnswer(Some(true))));
        vcx.update(|window, cx| sheet.update(cx, |s, cx| s.new_chat(window, cx)));
        vcx.run_until_parked();
        assert!(
            vcx.update(|_, cx| sheet::current::<FolderSettingsSheet>(cx))
                .is_none()
        );
        assert_eq!(
            stores
                .navigation
                .read_with(vcx, |n, _| n.new_chat_folder().map(str::to_string)),
            Some("f1".to_string())
        );
    }
}
