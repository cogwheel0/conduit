//! Hand-written synthetic data. Every name, chat, server and message here is
//! invented for the gallery (AGENTS.md: no real chats, people, servers or
//! prompts). Hosts use the reserved `example.*` domains.

use conduit_components::views::model::*;
use gpui_kit::SharedString;

pub const MODEL: &str = "Aster 2 Pro";
pub const USER_NAME: &str = "Sam Rivera";
pub const USER_INITIALS: &str = "SR";

pub fn models() -> Vec<ModelOption> {
    let m = |id: &str, name: &str, provider: &str, pinned: bool| ModelOption {
        id: id.into(),
        name: name.into(),
        provider: provider.into(),
        pinned,
    };
    vec![
        m("aster-2-pro", "Aster 2 Pro", "chat.example.org", true),
        m("aster-2-mini", "Aster 2 Mini", "chat.example.org", true),
        m("nimbus-8b", "Nimbus 8B", "chat.example.org", false),
        m("orca-7b-local", "Orca 7B", "Direct \u{b7} Local", false),
        m(
            "quill-r1",
            "Quill R1",
            "Direct \u{b7} api.example.net",
            false,
        ),
    ]
}

pub fn account() -> Account {
    Account {
        id: "acct-home".into(),
        name: USER_NAME.into(),
        email: "sam@example.org".into(),
        server: "chat.example.org".into(),
        backend: Backend::OpenWebUi,
        active: true,
        needs_sign_in: false,
    }
}

pub fn accounts() -> Vec<Account> {
    vec![
        account(),
        Account {
            id: "acct-studio".into(),
            name: "Sam Rivera".into(),
            email: "sam.r@studio.example.com".into(),
            server: "ai.studio.example.com".into(),
            backend: Backend::OpenWebUi,
            active: false,
            needs_sign_in: false,
        },
        Account {
            id: "acct-hermes".into(),
            name: "Workshop agent".into(),
            email: "Hermes gateway".into(),
            server: "hermes.example.net".into(),
            backend: Backend::Hermes,
            active: false,
            needs_sign_in: true,
        },
    ]
}

/// The sidebar most screens show.
pub fn sidebar(selected: Option<&str>) -> SidebarModel {
    SidebarModel {
        pinned: vec![
            ChatRow::new("c-sourdough", "Sourdough starter schedule", "7:12 AM")
                .spoken("7:12 AM")
                .pinned(),
            ChatRow::new("c-lisbon", "Trip budget for Lisbon", "Monday")
                .spoken("Monday")
                .pinned(),
        ],
        folders: vec![
            FolderRow {
                id: "f-garden".into(),
                name: "Garden".into(),
                expanded: true,
                chats: vec![
                    ChatRow::new("c-beds", "Raised bed layout", "Saturday").spoken("Saturday"),
                    ChatRow::new("c-tomato", "Tomato companion plants", "10/31/26")
                        .spoken("October 31, 2026"),
                ],
            },
            FolderRow {
                id: "f-work".into(),
                name: "Side project".into(),
                expanded: false,
                chats: vec![
                    ChatRow::new("c-api", "Rate limiter design", "10/24/26"),
                    ChatRow::new("c-schema", "Migration plan", "10/17/26"),
                ],
            },
        ],
        groups: vec![
            ChatGroup {
                label: "Today".into(),
                chats: vec![
                    ChatRow::new("c-orbit", "Orbital period of a moon", "9:41 AM")
                        .spoken("9:41 AM"),
                    ChatRow::new("c-espresso", "Dialing in espresso", "8:55 AM").spoken("8:55 AM"),
                    ChatRow::new("c-bike", "Bike fit notes", "6:30 AM").spoken("6:30 AM"),
                ],
            },
            ChatGroup {
                label: "Yesterday".into(),
                chats: vec![
                    ChatRow::new("c-regex", "Regex for ISO dates", "Yesterday"),
                    ChatRow::new("c-letter", "Cover letter tone", "Yesterday"),
                ],
            },
            // The phone's date sections: then the previous week and month,
            // then each earlier month.
            ChatGroup {
                label: "Previous 7 Days".into(),
                chats: vec![ChatRow::new(
                    "c-lifetimes",
                    "Rust lifetimes explained",
                    "Thursday",
                )],
            },
            ChatGroup {
                label: "Previous 30 Days".into(),
                chats: vec![
                    ChatRow::new("c-quilt", "Quilt pattern maths", "10/21/26"),
                    ChatRow::new("c-chords", "Jazz chord voicings", "10/14/26"),
                ],
            },
            ChatGroup {
                label: "September".into(),
                chats: vec![ChatRow::new("c-tides", "Why tides lag the moon", "9/28/26")],
            },
        ],
        selected: selected.map(SharedString::from),
        hovered: None,
        context_target: None,
        sync: SyncState::Synced {
            detail: "Synced just now".into(),
        },
        account: account(),
    }
}

/// The sidebar-detail state: a hovered row, a streaming chat, syncing.
pub fn sidebar_detail() -> SidebarModel {
    let mut m = sidebar(Some("c-orbit"));
    m.hovered = Some("c-espresso".into());
    m.groups[0].chats[2] = ChatRow::new("c-bike", "Bike fit notes", "6:30 AM")
        .spoken("4 hours ago")
        .streaming();
    m.folders[1].expanded = true;
    m.sync = SyncState::Syncing {
        detail: "Syncing 214 chats\u{2026}".into(),
    };
    m
}

pub fn suggestions() -> Vec<(conduit_components::assets::IconName, SharedString)> {
    use conduit_components::assets::IconName;
    vec![
        (IconName::Sparkles, "Explain a concept".into()),
        (IconName::Code, "Review my code".into()),
        (IconName::Pencil, "Help me write".into()),
        (IconName::Globe, "Search the web".into()),
    ]
}

pub const ORBIT_QUESTION: &str = "How long does a moon at 384,000 km take to orbit a planet with Earth's mass? Show the formula and a quick Python check.";

pub fn orbit_user() -> UserMessage {
    UserMessage {
        id: "u-orbit".into(),
        author: "You".into(),
        initials: USER_INITIALS.into(),
        text: ORBIT_QUESTION.into(),
        time: "9:41".into(),
        version: None,
        attachments: vec![],
        show_actions: false,
    }
}

const ORBIT_TEXT: &str = r#"For a small body orbiting a much heavier one, Kepler's third law gives the period from the semi-major axis $a$ and the central mass $M$:

$$
T = 2\pi \sqrt{\frac{a^3}{G M}}
$$

With $a = 3.84 \times 10^{8}\,\text{m}$ and $M = 5.97 \times 10^{24}\,\text{kg}$, that comes to about **27.4 days**, which matches the sidereal month [1](conduit-cite:1).

```python
from math import pi, sqrt
G, M, a = 6.674e-11, 5.97e24, 3.84e8   # SI units
T = 2 * pi * sqrt(a**3 / (G * M))
print(f"{T / 86400:.1f} days")  # 27.4 days
```

The small gap from the observed 27.32 days comes from the moon's own mass and the eccentric orbit [2](conduit-cite:2). If you"#;

pub fn orbit_streaming() -> AssistantMessage {
    AssistantMessage {
        id: "a-orbit".into(),
        model: MODEL.into(),
        time: "9:41".into(),
        blocks: vec![
            Block::Reasoning {
                summary: "Thought for 6 seconds".into(),
                body: "".into(),
                streaming: false,
                expanded: false,
            },
            Block::ToolCall {
                title: "Searched the web".into(),
                detail: "\u{201c}sidereal month length seconds\u{201d} \u{b7} 3 results".into(),
                tool: "web_search".into(),
                arguments: None,
                result: None,
                status: RunStatus::Done,
                expanded: false,
            },
            Block::Text(ORBIT_TEXT.into()),
        ],
        streaming: true,
        rating: None,
        version: None,
        show_actions: false,
    }
}

pub fn orbit_sources() -> Vec<Source> {
    vec![
        Source {
            n: 1,
            title: "Lunar orbit basics".into(),
            host: "astro.example.edu".into(),
        },
        Source {
            n: 2,
            title: "Two-body notes".into(),
            host: "physics.example.org".into(),
        },
        Source {
            n: 3,
            title: "Month lengths".into(),
            host: "sky.example.com".into(),
        },
    ]
}

/// A long finished chat about sourdough, scrolled to the bottom.
pub fn long_chat() -> Vec<LongItem> {
    vec![
        LongItem::User(UserMessage {
            id: "u-s1".into(),
            author: "You".into(),
            initials: USER_INITIALS.into(),
            text: "My starter doubles in about 6 hours at room temperature. When should I feed it if I want to bake on Saturday morning?".into(),
            time: "Sat 8:02".into(),
            version: None,
            attachments: vec![],
            show_actions: false,
        }),
        LongItem::Assistant(AssistantMessage {
            id: "a-s1".into(),
            model: MODEL.into(),
            time: "Sat 8:02".into(),
            blocks: vec![Block::Text(
                "Work backwards from the bake. If the dough needs about **12 hours** from mixing to oven, mix on Friday at 8 pm.\n\n1. **Friday 8 am**: discard all but 20 g and feed 1:5:5.\n2. **Friday 2 pm**: the starter should have doubled; this is your levain.\n3. **Friday 8 pm**: mix the dough with the levain at its peak.\n\nKeep the jar somewhere around 24 \u{b0}C so the timing holds.".into(),
            )],
            streaming: false,
            rating: None,
            version: None,
            show_actions: false,
        }),
        LongItem::User(UserMessage {
            id: "u-s2".into(),
            author: "You".into(),
            initials: USER_INITIALS.into(),
            text: "Can you turn that into a table with the temperatures too? My kitchen is closer to 20 \u{b0}C.".into(),
            time: "Sat 8:06".into(),
            version: Some((2, 2)),
            attachments: vec![Attachment {
                name: "kitchen-temps.csv".into(),
                detail: "CSV \u{b7} 2 KB".into(),
                image: false,
                progress: None,
            }],
            show_actions: true,
        }),
        LongItem::Assistant(AssistantMessage {
            id: "a-s2".into(),
            model: MODEL.into(),
            time: "Sat 8:06".into(),
            blocks: vec![Block::Text(
                "At 20 \u{b0}C fermentation runs roughly a third slower, so shift every step earlier:\n\n| Step | At 24 \u{b0}C | At 20 \u{b0}C |\n|---|---|---|\n| Feed starter | Fri 8 am | Fri 5 am |\n| Levain peaks | Fri 2 pm | Fri 1 pm |\n| Mix dough | Fri 8 pm | Fri 6 pm |\n| Shape, then fridge | Fri 11 pm | Fri 10 pm |\n| Bake | Sat 8 am | Sat 8 am |\n\nIf you'd rather not wake at 5, feed at 1:10:10 the night before; the higher ratio slows the starter enough to peak around the same time.".into(),
            )],
            streaming: false,
            rating: Some(true),
            version: Some((2, 3)),
            show_actions: true,
        }),
    ]
}

pub enum LongItem {
    User(UserMessage),
    Assistant(AssistantMessage),
}

pub const QUICK_QUESTION: &str = "Convert 3/4 cup of butter to grams";
pub const QUICK_ANSWER: &str = "**3/4 cup of butter is about 170 g** (one US cup of butter weighs 227 g, so 227 \u{d7} 0.75 \u{2248} 170).\n\nThat's 1\u{bd} sticks if your butter comes in 113 g sticks.";

pub fn approval_command() -> &'static str {
    "rg --count \"TODO\" src/ | sort -t: -k2 -nr | head -5"
}
