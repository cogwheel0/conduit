//! Settings › Personalization for a LibreChat account in charge of the
//! chats: its memories, as the phone's Personalization page shows them
//! (`librechat.memories.*`). The assistant's use of them on or off (when
//! the role may opt out), each memory's key and value with Edit… and
//! Delete…, how much of the server's token budget they use, and Add
//! Memory…. Keys take lowercase letters and underscores, as LibreChat
//! requires; a refusal (a key taken, the budget full) shows in the server's
//! words.

use std::rc::Rc;

use conduit_components::ActiveConduitTheme as _;
use conduit_components::views::kit::{Button, Switch, setting_row};
use conduit_components::views::settings::settings_section;
use conduit_daemon::RpcError;
use conduit_protocol::{
    LibreChatMemories, LibreChatMemoryDto, LibreChatMemoryEdit, LibreChatMemoryRef,
    LibreChatMemoryToggle, NoParams, methods,
};
use gpui_kit::component::input::{InputState, Textarea, TextareaState};
use gpui_kit::prelude::*;
use gpui_kit::{
    AnyElement, App, AsyncWindowContext, Context, ElementId, Entity, SharedString, WeakEntity,
    Window, div, px,
};

use crate::l10n::{ActiveL10n as _, L10n};
use crate::shell::sheet::{SheetSpec, present_sheet};
use crate::stores::rpc::Rpc;
use crate::views::forms;

use super::controls;

/// A memory being written: a new one (`original` None) or an edit of the
/// memory `original` names.
pub struct LibreChatMemoryEditor {
    /// Which editor this is: a Save's answer goes only to the editor that
    /// sent it, never to one opened since.
    id: u64,
    pub original: Option<String>,
    pub saving: bool,
    /// What the server said when it refused, or a plain failure.
    pub error: Option<String>,
}

/// The LibreChat half of the Personalization pane.
pub struct LibreChatMemoriesView {
    rpc: Rpc,
    pub memories: Option<LibreChatMemories>,
    pub key: Entity<InputState>,
    pub value: Entity<TextareaState>,
    pub editor: Option<LibreChatMemoryEditor>,
    /// Editors opened so far (each takes the next id).
    editors: u64,
    pub busy: bool,
    pub failed: bool,
}

impl LibreChatMemoriesView {
    pub fn new(rpc: Rpc, window: &mut Window, cx: &mut Context<Self>) -> Self {
        let l10n = cx.l10n().clone();
        let key = forms::input(l10n.libre_chat_memory_key_hint(), false, window, cx);
        let value = cx.new(|cx| {
            TextareaState::new(window, cx)
                .auto_grow(2, 8)
                .placeholder(l10n.memory_hint())
        });
        cx.observe(&value, |_, _, cx| cx.notify()).detach();
        let mut this = Self {
            rpc,
            memories: None,
            key,
            value,
            editor: None,
            editors: 0,
            busy: false,
            failed: false,
        };
        this.refresh(window, cx);
        this
    }

    pub fn refresh(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let call = self.rpc.call::<methods::LibrechatMemoriesList>(&NoParams);
        self.run(call, None, window, cx);
    }

    /// Runs a `librechat.memories.*` call and shows the list it answers.
    /// `saved` is an editor's Save: that editor's id, with what it sent.
    /// The editor closes only while it still holds that, so words typed
    /// meanwhile stay; another editor is never touched.
    fn run(
        &mut self,
        call: impl std::future::Future<Output = Result<LibreChatMemories, RpcError>> + 'static,
        saved: Option<(u64, LibreChatMemoryEdit)>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let closes_editor = saved.is_some();
        self.busy = true;
        self.failed = false;
        if closes_editor && let Some(e) = self.editor.as_mut() {
            e.saving = true;
            e.error = None;
        }
        cx.notify();
        cx.spawn_in(
            window,
            async move |this: WeakEntity<Self>, cx: &mut AsyncWindowContext| {
                let result = call.await;
                let _ = this.update(cx, |s, cx| {
                    s.busy = false;
                    match result {
                        Ok(list) => {
                            s.memories = Some(list);
                            if let Some((id, sent)) = &saved {
                                if s.holds(*id, sent, cx) {
                                    s.editor = None;
                                } else if let Some(e) = s.editor.as_mut().filter(|e| e.id == *id) {
                                    // The memory is saved under the key sent
                                    // (made, or renamed): this editor's next
                                    // Save updates it there.
                                    e.original = Some(sent.key.clone());
                                    e.saving = false;
                                }
                            }
                        }
                        Err(e) => {
                            log::warn!("librechat.memories: {e}");
                            let words = e.args.get("detail").cloned();
                            let sender = saved.as_ref().map(|(id, _)| *id);
                            match s.editor.as_mut() {
                                Some(editor) if Some(editor.id) == sender => {
                                    editor.saving = false;
                                    editor.error =
                                        Some(words.unwrap_or_else(|| cx.l10n().error_message()));
                                }
                                _ => s.failed = true,
                            }
                        }
                    }
                    cx.notify();
                });
            },
        )
        .detach();
    }

    pub fn set_enabled(&mut self, on: bool, window: &mut Window, cx: &mut Context<Self>) {
        let call = self
            .rpc
            .call::<methods::LibrechatMemoriesSetEnabled>(&LibreChatMemoryToggle { enabled: on });
        self.run(call, None, window, cx);
    }

    /// Editor `id` is open and still holds `sent`: the key and value sent.
    fn holds(&self, id: u64, sent: &LibreChatMemoryEdit, cx: &App) -> bool {
        self.editor.as_ref().is_some_and(|e| e.id == id)
            && forms::text(&self.key, cx) == sent.key
            && self.value.read(cx).value().trim() == sent.value
    }

    /// Add Memory… (none) or Edit… on one.
    pub fn open_editor(
        &mut self,
        memory: Option<&LibreChatMemoryDto>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.editors += 1;
        self.editor = Some(LibreChatMemoryEditor {
            id: self.editors,
            original: memory.map(|m| m.key.clone()),
            saving: false,
            error: None,
        });
        let key = memory.map(|m| m.key.clone()).unwrap_or_default();
        let value = memory.map(|m| m.value.clone()).unwrap_or_default();
        self.key.update(cx, |s, cx| s.set_value(key, window, cx));
        self.value
            .update(cx, |s, cx| s.set_value(value, window, cx));
        let field = gpui_kit::Focusable::focus_handle(self.key.read(cx), cx);
        window.focus(&field, cx);
        cx.notify();
    }

    pub fn save(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(editor) = self.editor.as_mut() else {
            return;
        };
        let id = editor.id;
        let key = forms::text(&self.key, cx);
        let value = self.value.read(cx).value().trim().to_string();
        if key.is_empty() {
            editor.error = Some(cx.l10n().libre_chat_memory_key_required());
            cx.notify();
            return;
        }
        if value.is_empty() {
            return;
        }
        let edit = LibreChatMemoryEdit {
            original_key: editor.original.clone(),
            key,
            value,
        };
        let call = self.rpc.call::<methods::LibrechatMemoriesSave>(&edit);
        self.run(call, Some((id, edit)), window, cx);
    }

    /// Delete…: asks with a sheet, as the phone does.
    pub fn delete(&mut self, key: String, window: &mut Window, cx: &mut Context<Self>) {
        let l10n = cx.l10n().clone();
        let spec = SheetSpec::new(
            l10n.delete_memory(),
            l10n.delete_memory_confirm(),
            l10n.delete(),
            l10n.cancel(),
        )
        .destructive();
        let ask = present_sheet(window, spec, cx);
        cx.spawn_in(
            window,
            async move |this: WeakEntity<Self>, cx: &mut AsyncWindowContext| {
                if !ask.await {
                    return;
                }
                let _ = this.update_in(cx, |s, window, cx| {
                    let call = s
                        .rpc
                        .call::<methods::LibrechatMemoriesDelete>(&LibreChatMemoryRef { key });
                    s.run(call, None, window, cx);
                });
            },
        )
        .detach();
    }

    fn editor_group(
        &self,
        editor: &LibreChatMemoryEditor,
        l10n: &L10n,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let view = cx.entity().downgrade();
        let rows = vec![
            forms::field(
                l10n.libre_chat_memory_key_label(),
                &self.key,
                None,
                None,
                window,
                cx,
            )
            .into_any_element(),
            div()
                .p(px(12.))
                .child(Textarea::new(&self.value))
                .into_any_element(),
        ];
        let footer = editor
            .error
            .clone()
            .unwrap_or_else(|| l10n.memory_editor_description());
        let can_save = !self.value.read(cx).value().trim().is_empty() && !editor.saving;
        div()
            .flex()
            .flex_col()
            .gap(px(10.))
            .child(settings_section(
                if editor.original.is_some() {
                    l10n.edit_memory()
                } else {
                    l10n.add_memory()
                },
                Some(footer.into()),
                rows,
                cx,
            ))
            .child(controls::buttons(vec![
                Button::new("librechat-memory-cancel", l10n.cancel())
                    .on_click(Rc::new({
                        let view = view.clone();
                        move |_, _, cx| {
                            let _ = view.update(cx, |v, cx| {
                                v.editor = None;
                                cx.notify();
                            });
                        }
                    }))
                    .into_any_element(),
                Button::new("librechat-memory-save", l10n.save())
                    .primary()
                    .disabled(!can_save)
                    .on_click(Rc::new(move |_, window, cx| {
                        let _ = view.update(cx, |v, cx| v.save(window, cx));
                    }))
                    .into_any_element(),
            ]))
            .into_any_element()
    }
}

impl Render for LibreChatMemoriesView {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let l10n = cx.l10n().clone();
        let t = cx.conduit().clone();
        let Some(list) = self.memories.clone() else {
            return div().into_any_element();
        };
        let view = cx.entity().downgrade();
        let mut out: Vec<AnyElement> = vec![];
        if list.can_opt_out {
            let enabled = list.enabled;
            let toggle = Switch::new("librechat-memory-enabled", l10n.memory_title(), enabled)
                .on_click(Rc::new({
                    let view = view.clone();
                    move |_, window, cx| {
                        let _ = view.update(cx, |v, cx| v.set_enabled(!enabled, window, cx));
                    }
                }));
            out.push(
                settings_section(
                    SharedString::default(),
                    Some(
                        if enabled {
                            l10n.memory_enabled_description()
                        } else {
                            l10n.memory_disabled_description()
                        }
                        .into(),
                    ),
                    vec![setting_row(l10n.memory_title(), None, toggle, cx).into_any_element()],
                    cx,
                )
                .into_any_element(),
            );
        }
        let mut rows = vec![];
        for (i, m) in list.memories.iter().enumerate() {
            let mut buttons = div().flex().gap(px(6.));
            if list.can_update {
                let memory = m.clone();
                buttons = buttons.child(
                    Button::new(
                        ElementId::NamedInteger("librechat-memory-edit".into(), i as u64),
                        l10n.desktop_edit_ellipsis(),
                    )
                    .disabled(self.busy)
                    .on_click(Rc::new({
                        let view = view.clone();
                        move |_, window, cx| {
                            let memory = memory.clone();
                            let _ =
                                view.update(cx, |v, cx| v.open_editor(Some(&memory), window, cx));
                        }
                    })),
                );
            }
            let key = m.key.clone();
            buttons = buttons.child(
                Button::new(
                    ElementId::NamedInteger("librechat-memory-delete".into(), i as u64),
                    l10n.desktop_delete_ellipsis(),
                )
                .ghost()
                .disabled(self.busy || !list.can_update)
                .on_click(Rc::new({
                    let view = view.clone();
                    move |_, window, cx| {
                        let key = key.clone();
                        let _ = view.update(cx, |v, cx| v.delete(key, window, cx));
                    }
                })),
            );
            rows.push(
                setting_row(m.key.clone(), Some(m.value.clone().into()), buttons, cx)
                    .into_any_element(),
            );
        }
        if rows.is_empty() {
            rows.push(
                div()
                    .px(px(12.))
                    .py(px(12.))
                    .text_size(px(t.metrics.control))
                    .text_color(t.roles.text_subtle)
                    .child(SharedString::from(l10n.no_memories_saved()))
                    .into_any_element(),
            );
        }
        // How much of the server's budget the memories use.
        let footer = if self.failed {
            l10n.desktop_action_failed()
        } else if let Some(limit) = list.token_limit {
            l10n.libre_chat_memory_usage(list.total_tokens, limit)
        } else {
            l10n.manage_memories_description()
        };
        let mut buttons = vec![];
        if list.can_create {
            buttons.push(
                Button::new("librechat-memory-add", l10n.desktop_add_memory_ellipsis())
                    .disabled(
                        self.busy || self.editor.as_ref().is_some_and(|e| e.original.is_none()),
                    )
                    .on_click(Rc::new({
                        let view = view.clone();
                        move |_, window, cx| {
                            let _ = view.update(cx, |v, cx| v.open_editor(None, window, cx));
                        }
                    }))
                    .into_any_element(),
            );
        }
        out.push(
            div()
                .flex()
                .flex_col()
                .gap(px(10.))
                .child(settings_section(
                    l10n.manage_memories(),
                    Some(footer.into()),
                    rows,
                    cx,
                ))
                .child(controls::buttons(buttons))
                .into_any_element(),
        );
        if let Some(editor) = &self.editor {
            out.push(self.editor_group(editor, &l10n, window, cx));
        }
        div()
            .id("librechat-memories")
            .flex()
            .flex_col()
            .gap(px(22.))
            .children(out)
            .into_any_element()
    }
}

/// Whether `app`'s session shows LibreChat's memories: a LibreChat account
/// in charge whose role may read them.
pub fn shown(stores: &crate::stores::Stores, cx: &App) -> bool {
    stores
        .session
        .read(cx)
        .capabilities()
        .libre_chat
        .is_some_and(|f| f.memories)
}

#[cfg(test)]
mod tests {
    use conduit_protocol::{LibreChatMemories, methods};
    use gpui_kit::TestAppContext;

    use super::*;
    use crate::stores::rpc::fake::FakeDaemon;

    /// Words typed while a Save is out stay: the answer closes the editor
    /// only when it still holds what was sent.
    #[gpui_kit::test]
    fn words_typed_while_a_memory_saves_stay(cx: &mut TestAppContext) {
        let daemon = FakeDaemon::new();
        daemon.returns::<methods::LibrechatMemoriesList>(LibreChatMemories::default());
        daemon.returns::<methods::LibrechatMemoriesSave>(LibreChatMemories::default());
        cx.update(crate::views::test_globals);
        let rpc = daemon.rpc();
        let (view, vcx) =
            cx.add_window_view(move |window, cx| LibreChatMemoriesView::new(rpc, window, cx));
        vcx.run_until_parked();
        let held = daemon.hold::<methods::LibrechatMemoriesSave>();
        view.update_in(vcx, |v, window, cx| {
            v.open_editor(None, window, cx);
            v.key
                .update(cx, |s, cx| s.set_value("trail_notes", window, cx));
            v.value
                .update(cx, |s, cx| s.set_value("Ridge loop", window, cx));
            v.save(window, cx);
            v.value.update(cx, |s, cx| {
                s.set_value("Ridge loop, then the lake", window, cx)
            });
        });
        held.release();
        vcx.run_until_parked();
        view.read_with(vcx, |v, cx| {
            assert!(v.editor.is_some(), "the editor closed over the newer words");
            assert_eq!(v.value.read(cx).value(), "Ridge loop, then the lake");
            assert!(!v.editor.as_ref().unwrap().saving, "Save stays busy");
        });
        // Saved again: the memory made by the first Save is updated, not
        // made a second time.
        view.update_in(vcx, |v, window, cx| v.save(window, cx));
        vcx.run_until_parked();
        let sent = |daemon: &FakeDaemon| {
            daemon
                .calls::<methods::LibrechatMemoriesSave>()
                .last()
                .map(|p| p["originalKey"].clone())
        };
        assert_eq!(
            sent(&daemon),
            Some(serde_json::json!("trail_notes")),
            "the second Save made the memory again"
        );

        // A rename with words typed while it saves: the next Save goes to
        // the new key.
        let held = daemon.hold::<methods::LibrechatMemoriesSave>();
        view.update_in(vcx, |v, window, cx| {
            let memory = LibreChatMemoryDto {
                key: "old_key".into(),
                value: "Lake loop".into(),
                token_count: 2,
                updated_ms: None,
            };
            v.open_editor(Some(&memory), window, cx);
            v.key
                .update(cx, |s, cx| s.set_value("lake_notes", window, cx));
            v.save(window, cx);
            v.value
                .update(cx, |s, cx| s.set_value("Lake loop, twice", window, cx));
        });
        held.release();
        vcx.run_until_parked();
        view.update_in(vcx, |v, window, cx| v.save(window, cx));
        vcx.run_until_parked();
        assert_eq!(
            sent(&daemon),
            Some(serde_json::json!("lake_notes")),
            "the next Save went to the old key"
        );

        // A new memory's Save (A) is out; the opt-out switch answers
        // meanwhile; Cancel, Add Memory… (B), and B's own Save goes out too.
        // A's answer leaves B a new memory, still saving, with no error.
        daemon.returns::<methods::LibrechatMemoriesSetEnabled>(LibreChatMemories::default());
        let held = daemon.hold::<methods::LibrechatMemoriesSave>();
        view.update_in(vcx, |v, window, cx| {
            v.open_editor(None, window, cx);
            v.key
                .update(cx, |s, cx| s.set_value("camp_notes", window, cx));
            v.value
                .update(cx, |s, cx| s.set_value("Tent by the lake", window, cx));
            v.save(window, cx);
            v.set_enabled(false, window, cx);
        });
        vcx.run_until_parked();
        view.read_with(vcx, |v, _| {
            assert!(!v.busy, "the switch's answer left it busy")
        });
        view.update_in(vcx, |v, window, cx| {
            // Cancel, then Add Memory… again.
            v.editor = None;
            v.open_editor(None, window, cx);
            v.key
                .update(cx, |s, cx| s.set_value("gear_notes", window, cx));
            v.value
                .update(cx, |s, cx| s.set_value("Stove and fuel", window, cx));
            v.save(window, cx);
        });
        held.release_one();
        vcx.run_until_parked();
        view.read_with(vcx, |v, _| {
            let b = v.editor.as_ref().expect("the new editor closed");
            assert_eq!(
                b.original, None,
                "the new editor took the first memory's key"
            );
            assert!(b.saving, "the new editor's Save no longer shows as out");
            assert_eq!(b.error, None);
        });
        held.release();
        vcx.run_until_parked();
        assert_eq!(
            sent(&daemon),
            Some(serde_json::Value::Null),
            "the new memory's Save went to the closed editor's memory"
        );
    }
}
