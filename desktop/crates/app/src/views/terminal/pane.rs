//! A terminal server's pane: its console or its files, as mobile's
//! Terminal tab shows them, with the listening ports below the console.
//!
//! The pane attaches to its server once (`terminal.attach`, the page scope
//! mobile's sidebar terminal uses), connects the console at once (mobile's
//! auto-connect), keeps the files and ports live (`terminal.watch`), and
//! lets the handle go when it closes (`terminal.detach`). A new daemon
//! session (a restart) attaches again.

use std::rc::Rc;

use conduit_components::ActiveConduitTheme as _;
use conduit_components::assets::{IconName, icon};
use conduit_components::theme::with_alpha;
use conduit_components::views::focus::ControlExt as _;
use conduit_components::views::kit::{Button, IconButton, Segment, Segmented, bare_input};
use conduit_protocol::{
    Event, TerminalAttach, TerminalAttached, TerminalHandleRef, TerminalPort, TerminalWatch,
    events, methods,
};
use gpui_kit::component::input::{InputEvent, InputState};
use gpui_kit::prelude::*;
use gpui_kit::{
    AnyElement, App, ClickEvent, Context, Entity, FocusHandle, Focusable, FontWeight, Role,
    SharedString, Subscription, Task, Window, div, px,
};

use super::console::{self, Console, ConsoleEvent, LinkStatus};
use super::files::FilesView;
use crate::l10n::ActiveL10n as _;
use crate::stores::Stores;
use crate::stores::connection::ConnectionEvent;

/// Settings › Keyboard › "Use Option as Meta Key".
fn option_as_meta(cx: &App) -> bool {
    cx.try_global::<crate::AppState>()
        .is_some_and(|s| s.settings.read(cx).prefs.desktop.terminal_option_as_meta)
}

/// The toolbar title's server menu: opens server `0`'s pane.
#[derive(Clone, Debug, PartialEq, gpui_kit::Action)]
#[action(namespace = conduit_terminal, no_json)]
pub struct SwitchServer(pub String);

/// The server picker (mobile's, in the toolbar's title): every terminal
/// server the page can open (none that needs a saved chat), the one shown
/// checked.
pub fn server_menu(
    current: &str,
    position: gpui_kit::Point<gpui_kit::Pixels>,
    window: &mut Window,
    cx: &mut App,
) {
    let servers: Vec<(String, String)> = cx
        .try_global::<crate::AppState>()
        .map(|s| s.stores.areas.read(cx))
        .map(|a| {
            a.terminals
                .iter()
                .flatten()
                .filter(|t| !t.requires_saved_chat)
                .map(|t| {
                    let name = if t.name.trim().is_empty() {
                        t.id.clone()
                    } else {
                        t.name.clone()
                    };
                    (t.id.clone(), name)
                })
                .collect()
        })
        .unwrap_or_default();
    let mut menu = gpui_kit::component::native_menu::NativeMenu::new();
    for (id, name) in servers {
        menu = menu.menu_with_check(name, id == current, Box::new(SwitchServer(id)));
    }
    menu.show(position, window, cx);
}

/// What the pane shows: mobile's Console/Files switch.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Mode {
    Console,
    Files,
}

/// The pane's hold on its server.
#[derive(Clone, Debug, PartialEq)]
pub enum Attach {
    Pending,
    Ready(TerminalAttached),
    Failed,
}

pub struct TerminalPane {
    stores: Stores,
    server_id: String,
    attach: Attach,
    pub console: Entity<Console>,
    pub files: Entity<FilesView>,
    mode: Mode,
    ports: Vec<TerminalPort>,
    ports_loaded: bool,
    ports_open: bool,
    /// What the shell called itself (OSC 0/2), for the toolbar's subtitle.
    shell_title: Option<String>,
    find_input: Entity<InputState>,
    find_open: bool,
    /// Whether the console had focus when the pane last drew, and whether
    /// the keyboard brought it there (Tab, Go › Move Focus to Next Area):
    /// then the bar under it says how to leave, since Tab is the shell's.
    console_focused: bool,
    keyboard_entry: bool,
    /// Bumped by each attach: late answers to older ones are dropped.
    generation: u64,
    _tasks: Vec<Task<()>>,
    _subscriptions: Vec<Subscription>,
}

impl Focusable for TerminalPane {
    fn focus_handle(&self, cx: &App) -> FocusHandle {
        match self.mode {
            Mode::Console => self.console.read(cx).focus_handle(cx),
            Mode::Files => self.files.read(cx).focus_handle(cx),
        }
    }
}

impl TerminalPane {
    pub fn new(
        stores: Stores,
        server_id: String,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Self {
        let console = cx.new(Console::new);
        let files = cx.new(|cx| FilesView::new(stores.clone(), window, cx));
        let find_input = cx.new(|cx| InputState::new(window, cx));
        let meta = option_as_meta(cx);
        console.update(cx, |c, _| c.option_as_meta = meta);
        stores.connection.update(cx, |c, _| {
            c.subscribe("terminal", &[events::TERMINAL_CHANGED], vec![])
        });
        // Keys that are not text reach the shell ahead of the app's
        // shortcuts (Esc, Tab, ⌃C, arrows); ⌘ keys stay the app's.
        let keys = console.downgrade();
        let intercept = cx.intercept_keystrokes(move |event, window, cx| {
            let Some(console) = keys.upgrade() else {
                return;
            };
            let taken = console.update(cx, |c, cx| {
                c.is_focused(window) && c.key(&event.keystroke, cx)
            });
            if taken {
                cx.stop_propagation();
            }
        });
        let mut subscriptions = vec![
            intercept,
            cx.subscribe(&console, |this, _, e: &ConsoleEvent, cx| match e {
                ConsoleEvent::Status(_) => cx.notify(),
                ConsoleEvent::Title(title) => {
                    this.shell_title = title.clone().filter(|t| !t.trim().is_empty());
                    cx.notify();
                }
                ConsoleEvent::Notice(text) => {
                    let text = text.clone();
                    this.stores.toasts.update(cx, |t, cx| {
                        t.show(conduit_protocol::NoticeLevel::Info, text, cx)
                    });
                }
            }),
            cx.subscribe(
                &stores.connection,
                |this, _, e: &ConnectionEvent, cx| match e {
                    ConnectionEvent::Connected { .. } => this.attach(cx),
                    ConnectionEvent::Daemon(event) => {
                        if let Event::TerminalChanged(changed) = event.as_ref()
                            && this.handle() == Some(changed.handle.as_str())
                        {
                            if changed.files {
                                this.files.update(cx, |f, cx| f.refresh(cx));
                            }
                            if let Some(ports) = &changed.ports {
                                this.ports = ports.clone();
                                this.ports_loaded = true;
                                cx.notify();
                            }
                        }
                    }
                    _ => {}
                },
            ),
            cx.subscribe_in(
                &find_input,
                window,
                |this, input: &Entity<InputState>, e: &InputEvent, window, cx| match e {
                    InputEvent::Change => {
                        let query = input.read(cx).value().to_string();
                        this.console.update(cx, |c, cx| c.set_find(Some(query), cx));
                    }
                    InputEvent::PressEnter { shift, .. } => {
                        let forward = !*shift;
                        this.console.update(cx, |c, cx| c.find_step(forward, cx));
                        let _ = window;
                    }
                    _ => {}
                },
            ),
        ];
        if let Some(settings) = cx
            .try_global::<crate::AppState>()
            .map(|s| s.settings.clone())
        {
            subscriptions.push(cx.observe(&settings, |this, _, cx| {
                let meta = option_as_meta(cx);
                this.console.update(cx, |c, _| c.option_as_meta = meta);
            }));
        }
        let mut pane = Self {
            stores,
            server_id,
            attach: Attach::Pending,
            console,
            files,
            mode: Mode::Console,
            ports: vec![],
            ports_loaded: false,
            ports_open: false,
            shell_title: None,
            find_input,
            find_open: false,
            console_focused: false,
            keyboard_entry: false,
            generation: 0,
            _tasks: vec![],
            _subscriptions: subscriptions,
        };
        pane.attach(cx);
        pane
    }

    pub fn server_id(&self) -> &str {
        &self.server_id
    }

    pub fn handle(&self) -> Option<&str> {
        match &self.attach {
            Attach::Ready(a) => Some(a.handle.as_str()),
            _ => None,
        }
    }

    pub fn attach_state(&self) -> &Attach {
        &self.attach
    }

    pub fn mode(&self) -> Mode {
        self.mode
    }

    pub fn ports(&self) -> &[TerminalPort] {
        &self.ports
    }

    /// Whether the bar under the console says how to leave it: the console
    /// has focus, and the keyboard brought it there.
    pub fn shows_leave_hint(&self) -> bool {
        self.console_focused && self.keyboard_entry
    }

    pub fn shell_title(&self) -> Option<&str> {
        self.shell_title.as_deref()
    }

    /// Attaches to the server (again), then connects, lists and watches.
    pub fn attach(&mut self, cx: &mut Context<Self>) {
        self.generation += 1;
        let generation = self.generation;
        self.attach = Attach::Pending;
        cx.notify();
        let rpc = self.stores.connection.read(cx).rpc();
        let call = rpc.call::<methods::TerminalAttach>(&TerminalAttach {
            server_id: self.server_id.clone(),
            scope_id: String::new(),
        });
        self._tasks = vec![cx.spawn(async move |this, cx| {
            let result = call.await;
            this.update(cx, |p, cx| {
                if p.generation != generation {
                    return;
                }
                match result {
                    Ok(attached) => p.ready(attached, cx),
                    Err(e) => {
                        log::warn!("terminal.attach: {e}");
                        p.attach = Attach::Failed;
                        cx.notify();
                    }
                }
            })
            .ok();
        })];
    }

    fn ready(&mut self, attached: TerminalAttached, cx: &mut Context<Self>) {
        self.attach = Attach::Ready(attached.clone());
        let handle = attached.handle.clone();
        self.files
            .update(cx, |f, cx| f.open(handle.clone(), attached.cwd.clone(), cx));
        if attached.supported {
            self.connect(cx);
        }
        self.load_ports(cx);
        let rpc = self.stores.connection.read(cx).rpc();
        let watch = rpc.call::<methods::TerminalWatch>(&TerminalWatch {
            handle,
            path: attached.cwd,
        });
        self._tasks.push(cx.spawn(async move |_, _| {
            if let Err(e) = watch.await {
                log::warn!("terminal.watch: {e}");
            }
        }));
        cx.notify();
    }

    /// Connect (or Reconnect): a new shell session.
    pub fn connect(&mut self, cx: &mut Context<Self>) {
        let Attach::Ready(attached) = &self.attach else {
            self.attach(cx);
            return;
        };
        let handle = attached.handle.clone();
        let Some(http) = self.stores.connection.read(cx).http().cloned() else {
            return;
        };
        self.console
            .update(cx, |c, cx| c.connect(&http, &handle, cx));
    }

    pub fn disconnect(&mut self, cx: &mut Context<Self>) {
        let label = cx.l10n().terminal_disconnected_status();
        self.console.update(cx, |c, cx| c.disconnect(&label, cx));
    }

    pub fn load_ports(&mut self, cx: &mut Context<Self>) {
        let Some(handle) = self.handle().map(str::to_string) else {
            return;
        };
        let rpc = self.stores.connection.read(cx).rpc();
        let call = rpc.call::<methods::TerminalPorts>(&TerminalHandleRef { handle });
        self._tasks.push(cx.spawn(async move |this, cx| {
            let result = call.await;
            this.update(cx, |p, cx| {
                match result {
                    Ok(ports) => {
                        p.ports = ports.ports;
                        p.ports_loaded = true;
                    }
                    Err(e) => log::warn!("terminal.ports: {e}"),
                }
                cx.notify();
            })
            .ok();
        }));
    }

    pub fn set_mode(&mut self, mode: Mode, window: &mut Window, cx: &mut Context<Self>) {
        if self.mode == mode {
            return;
        }
        self.mode = mode;
        match mode {
            Mode::Console => {
                let focus = self.console.read(cx).focus_handle(cx);
                window.focus(&focus, cx);
            }
            Mode::Files => {
                self.find_open = false;
                self.console.update(cx, |c, cx| c.set_find(None, cx));
                self.files.update(cx, |f, cx| f.focus(window, cx));
            }
        }
        cx.notify();
    }

    pub fn toggle_ports(&mut self, cx: &mut Context<Self>) {
        self.ports_open = !self.ports_open;
        if self.ports_open {
            self.load_ports(cx);
        }
        cx.notify();
    }

    /// Opens a port in a preview window.
    pub fn open_port(&mut self, port: u16, cx: &mut Context<Self>) {
        let Some(handle) = self.handle().map(str::to_string) else {
            return;
        };
        super::preview::open(self.stores.clone(), handle, port, cx);
    }

    // ── Find ────────────────────────────────────────────────────────────

    pub fn find_open(&self) -> bool {
        self.find_open
    }

    pub fn open_find(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.mode != Mode::Console {
            return;
        }
        self.find_open = true;
        self.find_input.update(cx, |s, cx| {
            s.focus(window, cx);
            s.select_all(window, cx);
        });
        let query = self.find_input.read(cx).value().to_string();
        self.console.update(cx, |c, cx| c.set_find(Some(query), cx));
        cx.notify();
    }

    pub fn close_find(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if !self.find_open {
            return;
        }
        self.find_open = false;
        self.console.update(cx, |c, cx| c.set_find(None, cx));
        let focus = self.console.read(cx).focus_handle(cx);
        window.focus(&focus, cx);
        cx.notify();
    }

    pub fn find_step(&mut self, forward: bool, window: &mut Window, cx: &mut Context<Self>) {
        if !self.find_open {
            self.open_find(window, cx);
        }
        self.console.update(cx, |c, cx| c.find_step(forward, cx));
    }

    /// Types `text` into the find field, as typing would (E2E).
    pub fn type_find(&mut self, text: &str, window: &mut Window, cx: &mut Context<Self>) {
        if !self.find_open {
            self.open_find(window, cx);
        }
        let value = text.to_string();
        self.find_input
            .update(cx, |s, cx| s.set_value(value, window, cx));
        self.console
            .update(cx, |c, cx| c.set_find(Some(text.to_string()), cx));
    }

    // ── Drawing ─────────────────────────────────────────────────────────

    /// The toolbar's trailing controls: Console/Files, the link's badge
    /// with Connect or Disconnect, and the ports.
    pub fn toolbar(this: &Entity<Self>, window: &Window, cx: &App) -> AnyElement {
        let p = this.read(cx);
        let t = cx.conduit().clone();
        let l = cx.l10n().clone();
        let status = p.console.read(cx).status().clone();
        let supported = matches!(&p.attach, Attach::Ready(a) if a.supported);
        let weak = this.downgrade();
        let pick = Rc::new(move |i: usize, window: &mut Window, cx: &mut App| {
            let mode = if i == 0 { Mode::Console } else { Mode::Files };
            weak.update(cx, |p, cx| p.set_mode(mode, window, cx)).ok();
        });
        let switch = Segmented::new(
            "terminal-mode",
            l.desktop_terminal_view(),
            vec![
                Segment::new(l.terminal()).icon(IconName::SquareTerminal),
                Segment::new(l.files()).icon(IconName::Folder),
            ],
            usize::from(p.mode == Mode::Files),
        )
        .on_select(pick);
        let (label, tone) = match (&p.attach, &status) {
            (Attach::Failed, _) | (_, LinkStatus::Failed) => {
                (l.desktop_terminal_connection_failed(), t.roles.danger)
            }
            (Attach::Pending, _) | (_, LinkStatus::Connecting) => {
                (l.desktop_terminal_connecting(), t.roles.text_subtle)
            }
            (_, LinkStatus::Connected) => (l.terminal_connected_status(), t.roles.success),
            (_, LinkStatus::Disconnected) => {
                (l.terminal_disconnected_status(), t.roles.text_subtle)
            }
        };
        let badge = div()
            .id("terminal-status")
            .role(Role::Status)
            .aria_label(SharedString::from(label.clone()))
            .flex()
            .items_center()
            .gap(px(6.))
            .px(px(8.))
            .h(px(22.))
            .rounded_full()
            .bg(with_alpha(tone, if t.dark { 0.18 } else { 0.12 }))
            .text_size(px(t.metrics.small))
            .font_weight(FontWeight::MEDIUM)
            .text_color(tone)
            .child(div().size(px(6.)).rounded_full().bg(tone))
            .child(SharedString::from(label));
        let connected = matches!(status, LinkStatus::Connected | LinkStatus::Connecting);
        let weak = this.downgrade();
        let link_button = if connected {
            IconButton::new(
                "terminal-disconnect",
                IconName::Unplug,
                l.terminal_disconnect_action(),
            )
            .size(30., 15.)
            .round()
            .on_click(Rc::new(move |_: &ClickEvent, _, cx: &mut App| {
                weak.update(cx, |p, cx| p.disconnect(cx)).ok();
            }))
        } else {
            let label =
                if matches!(status, LinkStatus::Disconnected) && p.console.read(cx).painted() > 0 {
                    l.desktop_terminal_reconnect()
                } else {
                    l.terminal_connect_action()
                };
            IconButton::new("terminal-connect", IconName::Plug, label)
                .size(30., 15.)
                .round()
                .disabled(!supported && !matches!(p.attach, Attach::Failed))
                .on_click(Rc::new(move |_: &ClickEvent, _, cx: &mut App| {
                    weak.update(cx, |p, cx| p.connect(cx)).ok();
                }))
        };
        let _ = window;
        div()
            .flex()
            .items_center()
            .gap(px(8.))
            .child(badge)
            .child(link_button)
            .child(switch)
            .into_any_element()
    }

    fn find_bar(&self, window: &Window, cx: &mut Context<Self>) -> AnyElement {
        let l = cx.l10n().clone();
        let t = cx.conduit().clone();
        let r = t.roles;
        let m = t.metrics;
        let mac = cfg!(target_os = "macos");
        let next_keys = crate::keymap::describe(&crate::keymap::KeyStroke::new("g").primary(), mac);
        let previous_keys =
            crate::keymap::describe(&crate::keymap::KeyStroke::new("g").primary().shift(), mac);
        let status = self
            .console
            .read(cx)
            .find()
            .map(|f| (f.current, f.matches.len()));
        let count = status.map_or(0, |(_, n)| n);
        let label = match status {
            None => String::new(),
            Some((_, 0)) => l.desktop_find_no_matches(),
            Some((Some(i), n)) => l.desktop_position_of(&(i + 1).to_string(), &n.to_string()),
            Some((None, n)) => l.desktop_position_of("0", &n.to_string()),
        };
        let this = cx.entity().downgrade();
        let step = move |forward: bool| {
            let this = this.clone();
            Rc::new(move |_: &ClickEvent, window: &mut Window, cx: &mut App| {
                this.update(cx, |p, cx| p.find_step(forward, window, cx))
                    .ok();
            })
        };
        let done = {
            let this = cx.entity().downgrade();
            Rc::new(move |_: &ClickEvent, window: &mut Window, cx: &mut App| {
                this.update(cx, |p, cx| p.close_find(window, cx)).ok();
            })
        };
        let focused = self.find_input.focus_handle(cx).is_focused(window);
        div()
            .id("terminal-find-bar")
            .role(Role::Search)
            .aria_label(SharedString::from(l.desktop_terminal_find()))
            .key_context("ConduitFindBar")
            .capture_action(cx.listener(
                |this, _: &gpui_kit::component::input::Escape, window, cx| {
                    this.close_find(window, cx);
                    cx.stop_propagation();
                },
            ))
            .flex_none()
            .w_full()
            .h(px(40.))
            .px(px(14.))
            .flex()
            .items_center()
            .justify_end()
            .gap(px(8.))
            .border_b_1()
            .border_color(r.divider)
            .child(
                div()
                    .id("terminal-find-count")
                    .role(Role::Status)
                    .aria_label(SharedString::from(label.clone()))
                    .text_size(px(m.small))
                    .text_color(r.text_subtle)
                    .child(SharedString::from(label)),
            )
            .child(
                div()
                    .flex()
                    .items_center()
                    .child(
                        IconButton::new(
                            "terminal-find-previous",
                            IconName::ChevronUp,
                            l.desktop_find_previous(),
                        )
                        .size(26., 14.)
                        .shortcut(Some(previous_keys.into()))
                        .disabled(count == 0)
                        .on_click(step(false)),
                    )
                    .child(
                        IconButton::new(
                            "terminal-find-next",
                            IconName::ChevronDown,
                            l.desktop_find_next(),
                        )
                        .size(26., 14.)
                        .shortcut(Some(next_keys.into()))
                        .disabled(count == 0)
                        .on_click(step(true)),
                    ),
            )
            .child(
                div().w(px(240.)).child(
                    conduit_components::views::kit::field_frame(focused, 28., cx)
                        .rounded_full()
                        .child(icon(IconName::Search, 13., r.text_subtle))
                        .child(
                            div().flex_1().min_w_0().child(
                                bare_input(&self.find_input, l.desktop_terminal_find(), m.control)
                                    .accessibility_id("terminal-find-query"),
                            ),
                        ),
                ),
            )
            .child(Button::new("terminal-find-done", l.done()).on_click(done))
            .into_any_element()
    }

    /// The listening ports under the console: a disclosure with the count,
    /// then one row per port, as mobile's. While the keyboard has brought
    /// focus into the console, the bar also says how to leave it.
    fn ports_section(&self, cx: &mut Context<Self>) -> AnyElement {
        let l = cx.l10n().clone();
        let t = cx.conduit().clone();
        let r = t.roles;
        let m = t.metrics;
        let open = self.ports_open;
        let count = self.ports.len();
        let header_label = if count > 0 {
            format!("{} ({count})", l.terminal_ports_toggle())
        } else {
            l.terminal_ports_toggle()
        };
        let header = div()
            .id("terminal-ports-toggle")
            .role(Role::Button)
            .aria_label(SharedString::from(header_label.clone()))
            .aria_expanded(open)
            .flex()
            .items_center()
            .gap(px(6.))
            .h(px(28.))
            .px(px(10.))
            .cursor_pointer()
            .text_size(px(m.small))
            .font_weight(FontWeight::SEMIBOLD)
            .text_color(r.text_subtle)
            .hover(|s| s.text_color(r.text))
            .keyboard_shadow(cx)
            .on_click(cx.listener(|p, _, _, cx| p.toggle_ports(cx)))
            .child(icon(
                if open {
                    IconName::ChevronDown
                } else {
                    IconName::ChevronRight
                },
                12.,
                r.text_subtle,
            ))
            .child(SharedString::from(header_label));
        // Tab is the shell's in the console: the way out, beside the
        // disclosure (not in it: a click there toggles the ports).
        let hint = self.shows_leave_hint().then(|| {
            let (next, _) = console::leave_keys();
            div()
                .id("terminal-leave-hint")
                .flex_1()
                .min_w_0()
                .pr(px(10.))
                .flex()
                .justify_end()
                .text_size(px(m.small))
                .text_color(r.text_subtle)
                .child(
                    div()
                        .truncate()
                        .child(SharedString::from(l.desktop_terminal_leave_hint(&next))),
                )
        });
        let header = div().flex().items_center().child(header).children(hint);
        let mut section = div()
            .id("terminal-ports")
            .role(Role::Group)
            .aria_label(SharedString::from(l.terminal_ports_section_label()))
            .flex_none()
            .flex()
            .flex_col()
            .border_t_1()
            .border_color(r.divider)
            .bg(t.roles.window)
            .child(header);
        if open {
            let mut list = div().flex().flex_col().max_h(px(180.)).pb(px(6.));
            if !self.ports_loaded {
                list = list.child(
                    div()
                        .px(px(28.))
                        .py(px(6.))
                        .text_size(px(m.small))
                        .text_color(r.text_subtle)
                        .child(SharedString::from(l.desktop_terminal_loading_ports())),
                );
            } else if self.ports.is_empty() {
                list = list.child(
                    div()
                        .px(px(28.))
                        .py(px(6.))
                        .text_size(px(m.small))
                        .text_color(r.text_subtle)
                        .child(SharedString::from(l.terminal_no_ports())),
                );
            }
            for port in &self.ports {
                let number = port.port;
                let detail = [
                    port.process.clone().filter(|p| !p.trim().is_empty()),
                    port.pid.map(|pid| format!("PID {pid}")),
                ]
                .into_iter()
                .flatten()
                .collect::<Vec<_>>()
                .join(" • ");
                let address = format!("localhost:{number}");
                let open_label = l.desktop_terminal_open_port(&address);
                list = list.child(
                    div()
                        .id(SharedString::from(format!("terminal-port-{number}")))
                        .role(Role::Button)
                        .aria_label(SharedString::from(open_label.clone()))
                        .flex()
                        .items_center()
                        .gap(px(10.))
                        .mx(px(6.))
                        .px(px(22.))
                        .h(px(30.))
                        .rounded(px(6.))
                        .cursor_pointer()
                        .hover(|s| s.bg(r.hover))
                        .active(|s| s.bg(r.selected))
                        .keyboard_shadow(cx)
                        .on_click(cx.listener(move |p, _, _, cx| p.open_port(number as u16, cx)))
                        .child(icon(IconName::Globe, 14., r.text_subtle))
                        .child(
                            div()
                                .text_size(px(m.control))
                                .font_family(conduit_components::theme::MONO_FONT)
                                .text_color(r.text)
                                .child(SharedString::from(address)),
                        )
                        .when(!detail.is_empty(), |d| {
                            d.child(
                                div()
                                    .flex_1()
                                    .min_w_0()
                                    .truncate()
                                    .text_size(px(m.small))
                                    .text_color(r.text_subtle)
                                    .child(SharedString::from(detail)),
                            )
                        })
                        .child(icon(IconName::ArrowUpRight, 13., r.text_subtle)),
                );
            }
            section = section.child(list);
        }
        section.into_any_element()
    }

    /// The console's place while it has nothing to show: why.
    fn overlay(&self, cx: &App) -> Option<String> {
        let l = cx.l10n();
        match &self.attach {
            Attach::Failed => Some(l.terminal_failed_to_connect()),
            Attach::Ready(a) if !a.supported => Some(l.terminal_feature_disabled()),
            _ => None,
        }
    }
}

impl Drop for TerminalPane {
    fn drop(&mut self) {
        // The handle (its watch and previews) goes with the pane; nothing
        // here can wait for the answer.
        let _ = &self.attach;
    }
}

impl TerminalPane {
    /// Lets the server's handle go (the pane is closing for good).
    pub fn release(&mut self, cx: &mut Context<Self>) {
        let label = cx.l10n().terminal_disconnected_status();
        self.console.update(cx, |c, cx| c.disconnect(&label, cx));
        if let Some(handle) = self.handle().map(str::to_string) {
            let rpc = self.stores.connection.read(cx).rpc();
            let call = rpc.call::<methods::TerminalDetach>(&TerminalHandleRef { handle });
            cx.background_executor()
                .spawn(async move {
                    let _ = call.await;
                })
                .detach();
        }
    }
}

impl Render for TerminalPane {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let t = cx.conduit().clone();
        let r = t.roles;
        // Focus that came into the console from the keyboard (not a click)
        // shows the way out until it leaves.
        let focused = self.console.read(cx).is_focused(window);
        if focused && !self.console_focused {
            self.keyboard_entry = window.last_input_was_keyboard();
        } else if !focused {
            self.keyboard_entry = false;
        }
        self.console_focused = focused;
        let body = match self.mode {
            Mode::Console => {
                let overlay = self.overlay(cx);
                let mut column = div()
                    .id("terminal-console-pane")
                    .flex_1()
                    .min_h_0()
                    .flex()
                    .flex_col()
                    .on_action(
                        cx.listener(|p, _: &crate::actions::FindInChat, window, cx| {
                            p.open_find(window, cx)
                        }),
                    )
                    .on_action(cx.listener(|p, _: &crate::actions::FindNext, window, cx| {
                        p.find_step(true, window, cx)
                    }))
                    .on_action(
                        cx.listener(|p, _: &crate::actions::FindPrevious, window, cx| {
                            p.find_step(false, window, cx)
                        }),
                    );
                if self.find_open {
                    column = column.child(self.find_bar(window, cx));
                }
                let console = console::view(&self.console, &t, window, cx);
                column = column.child(
                    div()
                        .relative()
                        .flex_1()
                        .min_h_0()
                        .child(console)
                        .when_some(overlay, |d, text| {
                            d.child(
                                div()
                                    .absolute()
                                    .inset_0()
                                    .flex()
                                    .items_center()
                                    .justify_center()
                                    .bg(with_alpha(r.content, 0.92))
                                    .child(
                                        div()
                                            .id("terminal-overlay")
                                            .role(Role::Status)
                                            .aria_label(SharedString::from(text.clone()))
                                            .max_w(px(420.))
                                            .text_center()
                                            .text_size(px(t.metrics.control))
                                            .text_color(r.text_subtle)
                                            .child(SharedString::from(text)),
                                    ),
                            )
                        }),
                );
                column.child(self.ports_section(cx)).into_any_element()
            }
            Mode::Files => div()
                .flex_1()
                .min_h_0()
                .child(self.files.clone())
                .into_any_element(),
        };
        div()
            .id("terminal-pane")
            .flex_1()
            .min_h_0()
            .flex()
            .flex_col()
            .bg(r.content)
            .child(body)
    }
}
