//! The ⌘K palette over [`PaletteStore`], drawn by the
//! components' [`CommandPalette`].
//!
//! The query field keeps focus while ↑/↓ move the highlight (wrapping) and
//! ↩ opens the highlighted row; Esc or a click on the scrim closes it and
//! gives focus back to where it was. Rows: recent chats or search hits, then
//! the commands that match (see [`crate::stores::palette`]).
//!
//! It fades in over 120 ms, dropping 6 pt into place, and out over an even
//! 90 ms, scrim and panel together, the panel a step ahead so no faint
//! panel outlasts the scrim (`motion::specs::PALETTE_*`). So it is drawn for
//! a moment after it closes: then it takes no clicks or keys, and its rows
//! stay as they were.
//! Focus moves at once both ways, so typing never waits for the fade.
//!
//! [`PaletteStore`]: crate::stores::palette::PaletteStore

use std::rc::Rc;

use chrono::Local;
use conduit_components::assets::IconName;
use conduit_components::motion::{self, specs};
use conduit_components::views::palette::{
    CommandPalette, PaletteItem, PaletteSection, RowHandler, palette_overlay,
};
use gpui_kit::component::input::{InputEvent, InputState};
use gpui_kit::prelude::*;
use gpui_kit::{
    App, Context, Entity, FocusHandle, KeyDownEvent, MouseButton, MouseDownEvent, SharedString,
    Subscription, Window, div, px,
};

use super::dates;
use super::sidebar_model::parse_snippet;
use crate::AppState;
use crate::actions::{
    FocusModelPicker, NewChat, NewTemporaryChat, OpenSettings, ShowShortcuts, StopGenerating,
};
use crate::keymap::{Keymap, describe};
use crate::l10n::{ActiveL10n as _, L10n};
use crate::stores::Stores;
use crate::stores::palette::{CommandItem, PaletteCommand, PaletteEntry, RECENT_COUNT, entries};

/// The palette's commands, labelled, with the chords that are bound.
pub fn commands(l: &L10n, keymap: Option<&Keymap>) -> Vec<CommandItem> {
    PaletteCommand::ALL
        .into_iter()
        .map(|command| CommandItem {
            command,
            label: match command {
                PaletteCommand::NewChat => l.new_chat(),
                PaletteCommand::NewTemporaryChat => l.desktop_new_temporary_chat(),
                PaletteCommand::ChooseModel => l.desktop_shortcut_focus_model_picker(),
                PaletteCommand::OpenSettings => l.desktop_settings_title(),
                PaletteCommand::ShowShortcuts => l.desktop_shortcuts_title(),
            },
            // Only a chord that works: an unbound one would teach nothing.
            // A fixed one (⇧⌘N) is always bound.
            shortcut: command
                .shortcut()
                .filter(|a| a.is_live())
                .zip(keymap)
                .map(|(a, k)| describe(&k.stroke(a), cfg!(target_os = "macos")))
                .or_else(|| {
                    command.fixed().map(|f| {
                        describe(&crate::keymap::fixed_stroke(f), cfg!(target_os = "macos"))
                    })
                }),
        })
        .collect()
}

fn command_icon(command: PaletteCommand) -> IconName {
    match command {
        PaletteCommand::NewChat => IconName::SquarePen,
        PaletteCommand::NewTemporaryChat => IconName::ClockFading,
        PaletteCommand::ChooseModel => IconName::Sparkles,
        PaletteCommand::OpenSettings => IconName::Settings,
        PaletteCommand::ShowShortcuts => IconName::Keyboard,
    }
}

pub struct PaletteView {
    stores: Stores,
    pub palette: Entity<CommandPalette>,
    /// The rows as last drawn.
    entries: Vec<PaletteEntry>,
    /// Where focus was before the palette opened.
    restore: Option<FocusHandle>,
    _subscriptions: Vec<Subscription>,
}

impl PaletteView {
    pub fn new(stores: Stores, window: &mut Window, cx: &mut Context<Self>) -> Self {
        let palette = cx.new(|cx| {
            let mut p = CommandPalette::new("", vec![], window, cx);
            p.background_hint = false;
            p
        });
        let input = palette.read(cx).query.clone();
        let subscriptions = vec![
            cx.observe(&stores.palette, |_, _, cx| cx.notify()),
            cx.observe(&stores.chat_list, |_, _, cx| cx.notify()),
            cx.subscribe_in(
                &input,
                window,
                |this, input: &Entity<InputState>, e: &InputEvent, window, cx| match e {
                    InputEvent::Change => {
                        let q = input.read(cx).value().to_string();
                        this.stores.palette.update(cx, |p, cx| p.set_query(q, cx));
                    }
                    InputEvent::PressEnter { .. } => {
                        // The row drawn highlighted, though the rows may
                        // have shrunk since the index was set.
                        let index = this.stores.palette.read(cx).index;
                        let index = index.min(this.entries.len().saturating_sub(1));
                        this.choose(index, window, cx);
                    }
                    _ => {}
                },
            ),
        ];
        Self {
            stores,
            palette,
            entries: vec![],
            restore: None,
            _subscriptions: subscriptions,
        }
    }

    pub fn is_open(&self, cx: &App) -> bool {
        self.stores.palette.read(cx).open
    }

    /// The rows as last drawn.
    pub fn entries(&self) -> &[PaletteEntry] {
        &self.entries
    }

    /// Opens it empty, with the field focused.
    pub fn open(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if !self.is_open(cx) {
            self.restore = window.focused(cx);
        }
        self.stores.palette.update(cx, |p, cx| p.show(cx));
        let input = self.palette.read(cx).query.clone();
        input.update(cx, |i, cx| {
            i.set_value("", window, cx);
            i.focus(window, cx);
        });
        cx.notify();
    }

    pub fn close(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.stores.palette.update(cx, |p, cx| p.hide(cx));
        if let Some(focus) = self.restore.take() {
            window.focus(&focus, cx);
        }
        cx.notify();
    }

    /// Types `query` into the field (the E2E and the fixture). A value set
    /// from code does not announce a change, so the query goes to the store
    /// too.
    pub fn type_query(&mut self, query: &str, window: &mut Window, cx: &mut Context<Self>) {
        let input = self.palette.read(cx).query.clone();
        let q = query.to_string();
        input.update(cx, |i, cx| i.set_value(q.clone(), window, cx));
        self.stores.palette.update(cx, |p, cx| p.set_query(q, cx));
    }

    /// Moves the highlight, and says where it landed (VoiceOver; the query
    /// field keeps focus).
    pub fn step(&mut self, down: bool, cx: &mut Context<Self>) {
        let count = self.entries.len();
        self.stores
            .palette
            .update(cx, |p, cx| p.move_selection(down, count, cx));
        let index = self.stores.palette.read(cx).index;
        let label = match self.entries.get(index) {
            Some(PaletteEntry::Chat { title, .. }) => chat_title(title, cx.l10n()),
            Some(PaletteEntry::Command(c)) => c.label.clone(),
            None => return,
        };
        super::a11y::announce_row(&label, index, count, cx);
    }

    /// Opens row `index` (a chat, or runs a command) and closes.
    pub fn choose(&mut self, index: usize, window: &mut Window, cx: &mut Context<Self>) {
        // A click on the rows while they fade out.
        if !self.is_open(cx) {
            return;
        }
        let Some(entry) = self.entries.get(index).cloned() else {
            return;
        };
        self.close(window, cx);
        match entry {
            PaletteEntry::Chat { chat_id, .. } => {
                self.stores
                    .navigation
                    .update(cx, |n, cx| n.open(chat_id, cx));
            }
            PaletteEntry::Command(c) => match c.command {
                PaletteCommand::NewChat => window.dispatch_action(Box::new(NewChat), cx),
                // The main window's, as New Chat: it focuses the composer.
                PaletteCommand::NewTemporaryChat => {
                    window.dispatch_action(Box::new(NewTemporaryChat), cx)
                }
                // The chat view's model picker answers this.
                PaletteCommand::ChooseModel => {
                    window.dispatch_action(Box::new(FocusModelPicker), cx)
                }
                PaletteCommand::OpenSettings => window.dispatch_action(Box::new(OpenSettings), cx),
                PaletteCommand::ShowShortcuts => {
                    window.dispatch_action(Box::new(ShowShortcuts), cx)
                }
            },
        }
    }

    /// Recomputes the rows and hands them to the component.
    fn sync_component(&mut self, cx: &mut Context<Self>) {
        let l = cx.l10n().clone();
        let keymap = cx
            .try_global::<AppState>()
            .map(|s| s.settings.read(cx).keymap());
        let commands = commands(&l, keymap.as_ref());
        let store = self.stores.palette.read(cx);
        let query = store.query().trim().to_string();
        let searching = store.searching;
        // Recent chats show only with no query (sorting the list costs).
        let recent = if query.is_empty() {
            self.stores.chat_list.read(cx).recent(RECENT_COUNT)
        } else {
            vec![]
        };
        // Hits for another query (a search still on its way, or one that
        // failed) are not this query's.
        let results = store.results.as_ref().filter(|_| store.searched() == query);
        self.entries = entries(&query, &commands, &recent, results);
        let selected = store.index.min(self.entries.len().saturating_sub(1));
        if selected != store.index {
            // Enter, the arrows and the highlight all go from the row drawn.
            self.stores.palette.update(cx, |p, _| p.index = selected);
        }

        let now = Local::now();
        let mut chats = vec![];
        let mut cmds = vec![];
        for entry in &self.entries {
            match entry {
                PaletteEntry::Chat {
                    chat_id,
                    title,
                    snippet,
                    updated_at_ms,
                } => {
                    let title = chat_title(title, &l);
                    let mut item =
                        PaletteItem::new(format!("chat-{chat_id}"), IconName::MessageSquare, title)
                            .trailing(dates::stamp(*updated_at_ms, &now, &l).0)
                            .matching(&query);
                    if let Some(s) = snippet {
                        let (text, ranges) = parse_snippet(s);
                        item.snippet = Some(text.into());
                        item.snippet_matches = ranges;
                    }
                    chats.push(item);
                }
                PaletteEntry::Command(c) => {
                    let mut item = PaletteItem::new(
                        format!("cmd-{:?}", c.command).to_lowercase(),
                        command_icon(c.command),
                        c.label.clone(),
                    )
                    .matching(&query);
                    if let Some(s) = &c.shortcut {
                        item = item.trailing(s.clone());
                    }
                    cmds.push(item);
                }
            }
        }
        let mut sections = vec![];
        if !chats.is_empty() {
            sections.push(PaletteSection {
                label: if query.is_empty() {
                    l.desktop_palette_recent()
                } else {
                    l.desktop_palette_conversations()
                }
                .into(),
                items: chats,
            });
        }
        if !cmds.is_empty() {
            sections.push(PaletteSection {
                label: l.desktop_palette_commands().into(),
                items: cmds,
            });
        }
        let total = self.entries.len();
        let results_label: SharedString = l.desktop_palette_result_count(total as i64).into();
        let empty =
            (!query.is_empty() && !searching).then(|| l.desktop_palette_no_results().into());
        let this = cx.entity().downgrade();
        let choose: RowHandler = {
            let this = this.clone();
            Rc::new(move |i, window, cx| {
                this.update(cx, |v, cx| v.choose(i, window, cx)).ok();
            })
        };
        let hover: RowHandler = {
            let stores = self.stores.clone();
            Rc::new(move |i, _, cx| stores.palette.update(cx, |p, cx| p.set_index(i, cx)))
        };
        self.palette.update(cx, |p, _| {
            p.sections = sections;
            p.selected = selected;
            p.results_label = Some(results_label);
            p.empty = empty;
            p.on_choose = Some(choose);
            p.on_hover = Some(hover);
        });
    }
}

impl Render for PaletteView {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let open = self.is_open(cx);
        let shown = motion::appear(
            "palette",
            open,
            specs::PALETTE_IN,
            specs::PALETTE_OUT,
            window,
            cx,
        );
        if !shown.visible {
            return div().absolute().into_any_element();
        }
        if !open {
            // Fading out: drawn as it was, taking nothing. The panel's dark
            // text outlasts the pale scrim at the same opacity, so it fades
            // on the square of the same curve (its opacity times the
            // overlay's) and is gone a frame before the scrim's last trace.
            let panel = div()
                .relative()
                .top(px(shown.offset(-6.)))
                .opacity(shown.opacity)
                .child(self.palette.clone());
            return palette_overlay(panel, cx)
                .opacity(shown.opacity)
                // Over the sidebar too: its list's faded ends would show
                // through the scrim as stripes.
                .child(conduit_components::views::overlays::overlay_marker())
                .into_any_element();
        }
        self.sync_component(cx);
        let panel = div()
            .id("palette-panel")
            .relative()
            .top(px(shown.offset(-6.)))
            .on_mouse_down(MouseButton::Left, |_, _, cx| cx.stop_propagation())
            .child(self.palette.clone());
        palette_overlay(panel, cx)
            .opacity(shown.opacity)
            // Over the sidebar too: its list's faded ends would show
            // through the scrim as stripes.
            .child(conduit_components::views::overlays::overlay_marker())
            .id("palette-scrim")
            .occlude()
            .key_context("ConduitPalette")
            // Esc closes it, focus going back where it was. The field and
            // the app's Esc (Stop) would take the key first: the capture
            // phase reaches the palette before either.
            .capture_action(cx.listener(
                |this, _: &gpui_kit::component::input::Escape, window, cx| {
                    this.close(window, cx);
                    cx.stop_propagation();
                },
            ))
            .capture_action(cx.listener(|this, _: &StopGenerating, window, cx| {
                this.close(window, cx);
                cx.stop_propagation();
            }))
            .on_mouse_down(
                MouseButton::Left,
                cx.listener(|this, _: &MouseDownEvent, window, cx| this.close(window, cx)),
            )
            .capture_key_down(cx.listener(|this, ev: &KeyDownEvent, window, cx| {
                let k = &ev.keystroke;
                let ctrl = k.modifiers.control;
                match k.key.as_str() {
                    "up" => this.step(false, cx),
                    "down" => this.step(true, cx),
                    "p" if ctrl => this.step(false, cx),
                    "n" if ctrl => this.step(true, cx),
                    "escape" => this.close(window, cx),
                    _ => return,
                }
                cx.stop_propagation();
            }))
            .into_any_element()
    }
}

/// A chat row's title as drawn and as VoiceOver says it: an untitled chat
/// is New Chat.
fn chat_title(title: &str, l: &L10n) -> String {
    if title.trim().is_empty() {
        l.new_chat()
    } else {
        title.to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::keymap::ShortcutAction;

    /// Arrowing onto an untitled chat says the name its row shows, so
    /// VoiceOver never goes quiet on a row.
    #[gpui_kit::test]
    fn an_untitled_chat_is_said_by_the_name_its_row_shows(cx: &mut gpui_kit::TestAppContext) {
        use conduit_components::announce::AnnouncementLog;
        let daemon = crate::stores::rpc::fake::FakeDaemon::new();
        let scratch =
            std::env::temp_dir().join(format!("conduit-palette-say-{}", std::process::id()));
        let stores = cx.update(|cx| {
            crate::views::test_globals(cx);
            AnnouncementLog::install(cx);
            Stores::for_test(daemon.rpc(), &scratch, cx)
        });
        let s = stores.clone();
        let (view, vcx) = cx.add_window_view(move |window, cx| PaletteView::new(s, window, cx));
        view.update(vcx, |v, cx| {
            v.entries = vec![
                PaletteEntry::Chat {
                    chat_id: "c1".into(),
                    title: "Tide tables".into(),
                    snippet: None,
                    updated_at_ms: 0,
                },
                PaletteEntry::Chat {
                    chat_id: "c2".into(),
                    title: "  ".into(),
                    snippet: None,
                    updated_at_ms: 0,
                },
            ];
            v.stores.palette.update(cx, |p, _| p.index = 0);
            v.step(true, cx);
        });
        let said: Vec<String> = vcx.update(|_, cx| {
            AnnouncementLog::texts(cx)
                .iter()
                .map(ToString::to_string)
                .collect()
        });
        assert_eq!(said, ["New Chat, 2 of 2".to_string()]);
    }

    #[test]
    fn commands_show_only_chords_that_work() {
        let l = L10n::new("en");
        let keymap = Keymap::new(Default::default());
        let cmds = commands(&l, Some(&keymap));
        let find = |c: PaletteCommand| cmds.iter().find(|i| i.command == c).unwrap();
        assert_eq!(find(PaletteCommand::NewChat).label, "New Chat");
        assert_eq!(
            find(PaletteCommand::NewChat).shortcut.as_deref(),
            ShortcutAction::NewChat
                .is_live()
                .then(|| describe(
                    &keymap.stroke(ShortcutAction::NewChat),
                    cfg!(target_os = "macos")
                ))
                .as_deref()
        );
        // A fixed chord shows as well (File › New Temporary Chat's).
        assert_eq!(
            find(PaletteCommand::NewTemporaryChat).shortcut.as_deref(),
            Some(describe(
                &crate::keymap::fixed_stroke(crate::keymap::FixedCommand::NewTemporaryChat),
                cfg!(target_os = "macos")
            ))
            .as_deref()
        );
        // Not bound until the chat view handles it.
        assert_eq!(
            find(PaletteCommand::ChooseModel).shortcut.is_some(),
            ShortcutAction::FocusModelPicker.is_live()
        );
        assert_eq!(cmds.len(), PaletteCommand::ALL.len());
    }

    #[gpui_kit::test]
    fn enter_opens_the_row_drawn_when_the_rows_shrink(cx: &mut gpui_kit::TestAppContext) {
        let daemon = crate::stores::rpc::fake::FakeDaemon::new();
        let scratch = std::env::temp_dir().join(format!("conduit-palette-{}", std::process::id()));
        let stores = cx.update(|cx| {
            crate::views::test_globals(cx);
            Stores::for_test(daemon.rpc(), &scratch, cx)
        });
        let s = stores.clone();
        let (view, vcx) = cx.add_window_view(move |window, cx| PaletteView::new(s, window, cx));
        view.update_in(vcx, |v, window, cx| v.open(window, cx));
        vcx.run_until_parked();
        let rows = view.read_with(vcx, |v, _| v.entries.len());
        assert!(rows > 0);
        // The highlight was on a row a search answer has since taken away.
        stores.palette.update(vcx, |p, _| p.index = rows + 5);
        vcx.update(|window, cx| window.draw(cx).clear(cx));
        vcx.run_until_parked();
        assert_eq!(stores.palette.read_with(vcx, |p, _| p.index), rows - 1);
    }
}
