//! Main-window screens: empty chat, streaming answer, long chat, sidebar
//! detail, and what is drawn over or docked in the main window (palette,
//! approval cards, context menu, model picker, toast).

use conduit_components::ActiveConduitTheme;
use conduit_components::assets::IconName;
use conduit_components::theme::ToolbarLayout;
use conduit_components::views::approval::{ApprovalCard, ApprovalKind, SelectOption};
use conduit_components::views::composer::{Composer, ComposerToggle};
use conduit_components::views::menu::{MenuEntry, MenuReplica, Toast, ToastTone};
use conduit_components::views::message::{AssistantMessageView, UserMessageView};
use conduit_components::views::model::{
    AssistantMessage, Block, RunStatus, SidebarModel, UserMessage,
};
use conduit_components::views::model_picker::ModelMenu;
use conduit_components::views::palette::{
    CommandPalette, PaletteItem, PaletteSection, palette_overlay,
};
use conduit_components::views::shell::{ChatColumn, ChatToolbar, MainWindowFrame, empty_chat};
use conduit_components::views::sidebar::Sidebar;
use gpui_kit::prelude::*;
use gpui_kit::{AnyElement, Context, Entity, SharedString, Window, div, px};

use crate::fake::{self, LongItem};
use crate::screens::Screen;

enum Item {
    User(UserMessage),
    Assistant(Entity<AssistantMessageView>),
}

enum Overlay {
    None,
    Palette(Entity<CommandPalette>),
    ContextMenu,
    ModelPicker,
    Toast,
}

/// One main-window screen.
pub struct MainScreen {
    sidebar: SidebarModel,
    model: SharedString,
    title: SharedString,
    items: Vec<Item>,
    composer: Entity<Composer>,
    scrolled: bool,
    overlay: Overlay,
    docked: Option<Screen>,
}

fn user(id: &str, text: &str, time: &str) -> UserMessage {
    UserMessage {
        id: id.into(),
        author: "You".into(),
        initials: fake::USER_INITIALS.into(),
        text: text.to_string().into(),
        time: time.to_string().into(),
        version: None,
        attachments: vec![],
        show_actions: false,
    }
}

fn palette_sections(search: bool) -> Vec<PaletteSection> {
    if search {
        let q = "starter";
        vec![PaletteSection {
            label: "Chats".into(),
            items: vec![
                PaletteItem::new("p-sourdough", IconName::MessageSquare, "Sourdough starter schedule")
                    .snippet("\u{2026}feed the starter 1:5:5 at 8 am so it peaks by 2 pm\u{2026}")
                    .trailing("7:12 AM")
                    .matching(q),
                PaletteItem::new("p-rye", IconName::MessageSquare, "Rye bread hydration")
                    .snippet("\u{2026}a stiffer rye starter ferments more slowly in a cool kitchen\u{2026}")
                    .trailing("10/9/26")
                    .matching(q),
                PaletteItem::new("p-garden", IconName::MessageSquare, "Raised bed layout")
                    .snippet("\u{2026}a starter tray of basil on the sunny windowsill\u{2026}")
                    .trailing("Saturday")
                    .matching(q),
                PaletteItem::new("p-kombucha", IconName::MessageSquare, "Kombucha second ferment")
                    .snippet("\u{2026}keep a cup of the old batch as the starter liquid\u{2026}")
                    .trailing("9/30/26")
                    .matching(q),
            ],
        }]
    } else {
        vec![
            PaletteSection {
                label: "Recent chats".into(),
                items: vec![
                    PaletteItem::new(
                        "p-orbit",
                        IconName::MessageSquare,
                        "Orbital period of a moon",
                    )
                    .trailing("9:41 AM"),
                    PaletteItem::new("p-espresso", IconName::MessageSquare, "Dialing in espresso")
                        .trailing("8:55 AM"),
                    PaletteItem::new(
                        "p-sourdough",
                        IconName::MessageSquare,
                        "Sourdough starter schedule",
                    )
                    .trailing("6:30 AM"),
                    PaletteItem::new("p-bike", IconName::MessageSquare, "Bike fit notes")
                        .trailing("6:30 AM"),
                ],
            },
            PaletteSection {
                label: "Commands".into(),
                items: vec![
                    PaletteItem::new("cmd-new", IconName::SquarePen, "New chat")
                        .trailing("\u{2318}N"),
                    PaletteItem::new("cmd-temp", IconName::ClockFading, "New temporary chat")
                        .trailing("\u{21e7}\u{2318}N"),
                    PaletteItem::new("cmd-sidebar", IconName::PanelLeft, "Toggle sidebar")
                        .trailing("\u{2318}\\"),
                    PaletteItem::new("cmd-account", IconName::Users, "Switch account\u{2026}"),
                    PaletteItem::new("cmd-settings", IconName::Settings, "Open settings")
                        .trailing("\u{2318},"),
                ],
            },
        ]
    }
}

impl MainScreen {
    pub fn new(screen: Screen, window: &mut Window, cx: &mut Context<Self>) -> Self {
        let composer = cx.new(|cx| {
            let mut c = Composer::new("Message Conduit", fake::MODEL, window, cx);
            c.toggles = vec![ComposerToggle {
                label: "Web search".into(),
                icon: IconName::Globe,
                on: false,
            }];
            c
        });
        let mut sidebar = fake::sidebar(None);
        let mut title: SharedString = "".into();
        let mut items = vec![];
        let mut scrolled = false;
        let mut overlay = Overlay::None;
        let mut docked = None;
        let mut model: SharedString = fake::MODEL.into();
        match screen {
            Screen::MainEmpty => {
                composer.update(cx, |c, _| c.force_focus = true);
            }
            Screen::MainStreaming => {
                sidebar = fake::sidebar(Some("c-orbit"));
                title = "Orbital period of a moon".into();
                items.push(Item::User(fake::orbit_user()));
                let mut msg = fake::orbit_streaming();
                msg.blocks.push(Block::Citations(fake::orbit_sources()));
                items.push(Item::Assistant(
                    cx.new(|cx| AssistantMessageView::new(msg, cx)),
                ));
                composer.update(cx, |c, cx| {
                    c.streaming = true;
                    c.toggles[0].on = true;
                    cx.notify();
                });
            }
            Screen::MainLong => {
                sidebar = fake::sidebar(Some("c-sourdough"));
                title = "Sourdough starter schedule".into();
                scrolled = true;
                overlay = Overlay::Toast;
                for item in fake::long_chat() {
                    items.push(match item {
                        LongItem::User(u) => Item::User(u),
                        LongItem::Assistant(a) => {
                            Item::Assistant(cx.new(|cx| AssistantMessageView::new(a, cx)))
                        }
                    });
                }
            }
            Screen::Sidebar => {
                sidebar = fake::sidebar_detail();
                title = "Orbital period of a moon".into();
                items.push(Item::User(fake::orbit_user()));
            }
            Screen::PaletteRecent | Screen::PaletteSearch => {
                sidebar = fake::sidebar(Some("c-orbit"));
                title = "Orbital period of a moon".into();
                items.push(Item::User(fake::orbit_user()));
                let mut msg = fake::orbit_streaming();
                msg.streaming = false;
                msg.show_actions = true;
                items.push(Item::Assistant(
                    cx.new(|cx| AssistantMessageView::new(msg, cx)),
                ));
                let search = screen == Screen::PaletteSearch;
                let palette = cx.new(|cx| {
                    CommandPalette::new(
                        if search { "starter" } else { "" },
                        palette_sections(search),
                        window,
                        cx,
                    )
                });
                overlay = Overlay::Palette(palette);
            }
            Screen::ApprovalTool => {
                sidebar = fake::sidebar(Some("c-bike"));
                sidebar.account.server = "hermes.example.net".into();
                title = "Tidy up the TODOs".into();
                items.push(Item::User(user(
                    "u-todo",
                    "Which files in this repo have the most TODO comments?",
                    "10:12",
                )));
                let msg = AssistantMessage {
                    id: "a-todo".into(),
                    model: "Workshop agent".into(),
                    time: "10:12".into(),
                    blocks: vec![
                        Block::Text("I'll count them with ripgrep and sort by file.".into()),
                        Block::ToolCall {
                            title: "Run command".into(),
                            detail: "terminal \u{b7} waiting for approval".into(),
                            tool: "terminal".into(),
                            arguments: None,
                            result: None,
                            status: RunStatus::Running,
                            expanded: false,
                        },
                    ],
                    streaming: false,
                    rating: None,
                    version: None,
                    show_actions: false,
                };
                items.push(Item::Assistant(
                    cx.new(|cx| AssistantMessageView::new(msg, cx)),
                ));
                docked = Some(screen);
                model = "Workshop agent".into();
            }
            Screen::ApprovalSelect => {
                sidebar = fake::sidebar(Some("c-bike"));
                sidebar.account.server = "hermes.example.net".into();
                title = "Ship the preview build".into();
                items.push(Item::User(user(
                    "u-deploy",
                    "Deploy the preview build of the recipe site.",
                    "10:20",
                )));
                let msg = AssistantMessage {
                    id: "a-deploy".into(),
                    model: "Workshop agent".into(),
                    time: "10:20".into(),
                    blocks: vec![
                        Block::Status {
                            text: "Built 42 pages in 3.1 s".into(),
                            done: true,
                        },
                        Block::Text("The build passed. Where should the preview run?".into()),
                    ],
                    streaming: false,
                    rating: None,
                    version: None,
                    show_actions: false,
                };
                items.push(Item::Assistant(
                    cx.new(|cx| AssistantMessageView::new(msg, cx)),
                ));
                docked = Some(screen);
                model = "Workshop agent".into();
            }
            Screen::ContextMenu => {
                sidebar = fake::sidebar(Some("c-orbit"));
                sidebar.context_target = Some("c-espresso".into());
                title = "Orbital period of a moon".into();
                items.push(Item::User(fake::orbit_user()));
                overlay = Overlay::ContextMenu;
            }
            Screen::ModelPicker => {
                overlay = Overlay::ModelPicker;
            }
            _ => {}
        }
        // The composer shows the scenario's model too (in the Title layout).
        composer.update(cx, |c, _| c.model = model.clone());
        Self {
            sidebar,
            model,
            title,
            items,
            composer,
            scrolled,
            overlay,
            docked,
        }
    }
}

impl Render for MainScreen {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let t = cx.conduit().clone();
        let picker_open = matches!(self.overlay, Overlay::ModelPicker);
        let toolbar = ChatToolbar::new(self.title.clone(), self.model.clone())
            .scrolled(self.scrolled)
            .picker_open(picker_open);
        let docked: Option<AnyElement> = self.docked.map(|s| {
            if s == Screen::ApprovalTool {
                ApprovalCard::new(
                    "tool",
                    "Allow the agent to run this command?",
                    "It reads files in the project folder. Nothing is changed.",
                    "Hermes \u{b7} terminal",
                    ApprovalKind::Tool {
                        tool: "Command".into(),
                        preview: fake::approval_command().into(),
                    },
                )
                .into_any_element()
            } else {
                ApprovalCard::new(
                    "select",
                    "Choose a region for the preview",
                    "The agent asks before it deploys anywhere.",
                    "Hermes \u{b7} question",
                    ApprovalKind::Select {
                        options: vec![
                            SelectOption {
                                label: "Frankfurt".into(),
                                detail: Some("eu-central \u{b7} closest to most visitors".into()),
                            },
                            SelectOption {
                                label: "Virginia".into(),
                                detail: Some("us-east".into()),
                            },
                            SelectOption {
                                label: "Singapore".into(),
                                detail: Some("ap-southeast".into()),
                            },
                        ],
                        selected: 0,
                    },
                )
                .queue(1, 2)
                .into_any_element()
            }
        });
        let body: AnyElement = if self.items.is_empty() {
            empty_chat(
                "Good evening, Sam",
                self.composer.clone(),
                fake::suggestions(),
                cx,
            )
            .into_any_element()
        } else {
            let messages = self
                .items
                .iter()
                .map(|i| match i {
                    Item::User(u) => UserMessageView::new(u.clone()).into_any_element(),
                    Item::Assistant(a) => a.clone().into_any_element(),
                })
                .collect();
            let mut column = ChatColumn::new(messages, self.composer.clone());
            if let Some(card) = docked {
                column = column.docked(card);
            }
            column.into_any_element()
        };
        let mut frame = MainWindowFrame::new(
            div()
                .size_full()
                .flex()
                .flex_col()
                .child(toolbar)
                .child(body),
        )
        .sidebar(Sidebar::new(self.sidebar.clone()));
        let sidebar_w = t.metrics.sidebar_width;
        match &self.overlay {
            Overlay::None => {}
            Overlay::Palette(p) => frame = frame.overlay(palette_overlay(p.clone(), cx)),
            Overlay::Toast => {
                frame = frame.overlay(
                    div().absolute().top(px(60.)).right(px(16.)).child(
                        Toast::new("copied", ToastTone::Success, "Reply copied")
                            .detail("Markdown is on the clipboard."),
                    ),
                )
            }
            Overlay::ContextMenu => {
                frame = frame.overlay(
                    div()
                        .absolute()
                        .left(px(sidebar_w - 92.))
                        .top(px(404.))
                        .child(
                            MenuReplica::new(
                                "Chat actions",
                                vec![
                                    MenuEntry::item("Open in New Window"),
                                    MenuEntry::Separator,
                                    MenuEntry::item("Rename\u{2026}"),
                                    MenuEntry::item("Pin").icon(IconName::Pin),
                                    MenuEntry::item("Move to Folder")
                                        .icon(IconName::Folder)
                                        .submenu(),
                                    MenuEntry::item("Share\u{2026}").icon(IconName::Share),
                                    MenuEntry::item("Export").icon(IconName::Download).submenu(),
                                    MenuEntry::Separator,
                                    MenuEntry::item("Archive").icon(IconName::Archive),
                                    MenuEntry::item("Delete\u{2026}")
                                        .icon(IconName::Trash)
                                        .destructive(),
                                ],
                            )
                            .highlighted(4)
                            .width(230.),
                        ),
                )
            }
            Overlay::ModelPicker => {
                let left = match t.prefs.toolbar {
                    // Under the centred title capsule.
                    ToolbarLayout::Pill => {
                        sidebar_w + (super::MAIN_WINDOW_SIZE.0 - sidebar_w) / 2. - 150.
                    }
                    ToolbarLayout::Model => sidebar_w + 10.,
                    ToolbarLayout::Title => sidebar_w + 300.,
                };
                frame = frame.overlay(
                    div()
                        .absolute()
                        .left(px(left))
                        .top(px(48.))
                        .child(ModelMenu::new(fake::models(), "aster-2-pro").highlighted(1)),
                )
            }
        }
        frame
    }
}
