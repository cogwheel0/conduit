//! The named screens and how each one opens.

pub mod main_window;
pub mod other;

use conduit_components::theme::DesignPrefs;
use conduit_components::window::{MAIN_WINDOW_SIZE, QUICK_ASK_SIZE};

/// Every screen the gallery renders. Names are stable: they become file
/// names and `index.json` entries.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Screen {
    OnboardingBackend,
    OnboardingServer,
    SignIn,
    Accounts,
    MainEmpty,
    MainStreaming,
    MainLong,
    Sidebar,
    PaletteRecent,
    PaletteSearch,
    SettingsAppearance,
    ApprovalTool,
    ApprovalSelect,
    QuickAsk,
    QuickAskEmpty,
    MenuBar,
    ContextMenu,
    /// Extra: the model picker open over the empty chat.
    ModelPicker,
}

/// How a screen's window is built and captured.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Frame {
    /// The 1280×860 main window, with the sidebar material when chosen.
    Main { sidebar: bool },
    /// The Settings window: its own sidebar of tabs.
    Settings,
    /// The 720×320 Quick Ask panel.
    QuickAsk,
    /// A drawn scene (desktop + menu bar), captured as is.
    Scene { w: f32, h: f32 },
}

impl Screen {
    pub const ALL: &'static [Screen] = &[
        Screen::OnboardingBackend,
        Screen::OnboardingServer,
        Screen::SignIn,
        Screen::Accounts,
        Screen::MainEmpty,
        Screen::MainStreaming,
        Screen::MainLong,
        Screen::Sidebar,
        Screen::PaletteRecent,
        Screen::PaletteSearch,
        Screen::SettingsAppearance,
        Screen::ApprovalTool,
        Screen::ApprovalSelect,
        Screen::QuickAsk,
        Screen::QuickAskEmpty,
        Screen::MenuBar,
        Screen::ContextMenu,
        Screen::ModelPicker,
    ];

    pub fn name(self) -> &'static str {
        match self {
            Screen::OnboardingBackend => "onboarding-backend",
            Screen::OnboardingServer => "onboarding-server",
            Screen::SignIn => "sign-in",
            Screen::Accounts => "accounts",
            Screen::MainEmpty => "main-empty",
            Screen::MainStreaming => "main-streaming",
            Screen::MainLong => "main-long",
            Screen::Sidebar => "sidebar",
            Screen::PaletteRecent => "palette-recent",
            Screen::PaletteSearch => "palette-search",
            Screen::SettingsAppearance => "settings-appearance",
            Screen::ApprovalTool => "approval-tool",
            Screen::ApprovalSelect => "approval-select",
            Screen::QuickAsk => "quick-ask",
            Screen::QuickAskEmpty => "quick-ask-empty",
            Screen::MenuBar => "menu-bar",
            Screen::ContextMenu => "context-menu",
            Screen::ModelPicker => "model-picker",
        }
    }

    /// The screen's number in the gallery's list and its file names (1–12;
    /// 13 for extras).
    pub fn number(self) -> u8 {
        match self {
            Screen::OnboardingBackend | Screen::OnboardingServer => 1,
            Screen::SignIn => 2,
            Screen::Accounts => 3,
            Screen::MainEmpty => 4,
            Screen::MainStreaming => 5,
            Screen::MainLong => 6,
            Screen::Sidebar => 7,
            Screen::PaletteRecent | Screen::PaletteSearch => 8,
            Screen::SettingsAppearance => 9,
            Screen::ApprovalTool | Screen::ApprovalSelect => 10,
            Screen::QuickAsk | Screen::QuickAskEmpty => 11,
            Screen::MenuBar | Screen::ContextMenu => 12,
            Screen::ModelPicker => 13,
        }
    }

    pub fn by_name(name: &str) -> Option<Screen> {
        Self::ALL.iter().copied().find(|s| s.name() == name)
    }

    /// Design keys rendered one at a time on this screen: only those the
    /// screen can show (the empty chat has no user message; the sidebar
    /// crop shows neither messages nor the toolbar). `user` also renders on
    /// the long chat, where two user messages are on screen.
    pub fn variant_keys(self) -> &'static [&'static str] {
        match self {
            Screen::MainEmpty => &["sidebar", "accent", "density", "toolbar"],
            Screen::MainStreaming => &["sidebar", "accent", "user", "density", "toolbar"],
            Screen::MainLong => &["user"],
            Screen::Sidebar => &["sidebar", "accent", "density"],
            _ => &[],
        }
    }

    pub fn frame(self, prefs: &DesignPrefs) -> Frame {
        let material = prefs.sidebar == conduit_components::theme::SidebarStyle::Material;
        match self {
            Screen::OnboardingBackend | Screen::OnboardingServer | Screen::SignIn => {
                Frame::Main { sidebar: false }
            }
            Screen::Accounts | Screen::SettingsAppearance => Frame::Settings,
            Screen::QuickAsk | Screen::QuickAskEmpty => Frame::QuickAsk,
            Screen::MenuBar => Frame::Scene { w: 760., h: 460. },
            _ => Frame::Main { sidebar: material },
        }
    }

    pub fn window_size(self, prefs: &DesignPrefs) -> (f32, f32) {
        match self.frame(prefs) {
            Frame::Main { .. } => MAIN_WINDOW_SIZE,
            Frame::Settings => (860., 760.),
            Frame::QuickAsk => QUICK_ASK_SIZE,
            Frame::Scene { w, h } => (w, h),
        }
    }
}
