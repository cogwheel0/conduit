//! Icons and the brand mark.
//!
//! Icons are Lucide (ISC; see GPUI Kit's LICENSE-LUCIDE), selected by name
//! from GPUI Kit's bundled catalog so only these SVGs are embedded. The asset
//! source falls back to GPUI Kit's default component icons.

use std::borrow::Cow;

use gpui_kit::{AssetSource, Hsla, IntoElement, Pixels, SharedString, Styled as _, Svg, svg};

pub use gpui_kit::assets::IconName;

gpui_kit::assets::icon_assets!(
    pub ConduitIcons,
    [
        AppWindow, Archive, ArrowDown, ArrowLeft, ArrowRight, ArrowUp, ArrowUpRight, AtSign,
        AudioLines, AudioWaveform, Bell, BellOff, Bold, BookOpen, Bot, Brain, Calendar,
        CalendarClock, Captions, Check, ChevronDown, ChevronLeft, ChevronRight, ChevronsUpDown,
        ChevronUp, Circle, CircleAlert, CircleCheck, CircleSlash, CircleStop, CircleUser, CircleX,
        Clock, ClockFading, Cloud, CloudOff, Code, Coffee, Columns2, Command, Copy, CornerDownLeft,
        Cpu, Database, DatabaseBackup, Download, Ellipsis, ExternalLink, Eye, EyeOff,
        FaceSlightlySmilingPlus, FileCode, FileDown, FileMusic, FileText, Film, FlaskConical,
        Folder, FolderClosed, FolderOpen, FolderPlus, Funnel, GitBranch, Github, GitMerge, Globe,
        Hash, Heading1, Heading2, Heading3, Heart, House, Image, ImageOff, Info, Italic, Keyboard,
        KeyRound, Laptop, Layers, LayoutGrid, LibraryBig, Lightbulb, Link, List, ListChecks,
        ListOrdered, ListTodo, ListTree, LoaderCircle, Lock, LogOut, Mail, Maximize2, Megaphone,
        MessageSquare, MessageSquareDot, MessageSquarePlus, MessagesSquare, Mic, MicOff, Minimize2,
        Monitor, Moon, Network, NotebookPen, OctagonAlert, Palette, PanelLeft, Paperclip, Pause,
        Pencil, PhoneOff, Pilcrow, Pin, PinOff, Play, Plug, Plus, RefreshCw, Reply, RotateCcw,
        RotateCw, Save, ScrollText, Search, Server, Settings, Share, ShieldAlert, ShieldCheck,
        SkipBack, SkipForward, SlidersHorizontal, Smartphone, Sparkles, Split, Square, SquareCode,
        SquarePen, SquareTerminal, Strikethrough, Sun, Terminal, TextCursorInput, TextQuote,
        ThumbsDown, ThumbsUp, Timer, Trash, TriangleAlert, Undo2, Unlink, Unplug, Upload, User,
        UserMinus, UserPlus, Users, WandSparkles, Wifi, Wrench, X, Zap, ZoomIn, ZoomOut
    ]
);

/// Path of the Conduit mark inside [`ConduitAssets`].
pub const BRAND_MARK: &str = "brand/mark.svg";
const BRAND_MARK_SVG: &[u8] = include_bytes!("../assets/brand/mark.svg");

/// The app's asset source: Conduit's icons and mark, then GPUI Kit's.
pub struct ConduitAssets;

impl AssetSource for ConduitAssets {
    fn load(&self, path: &str) -> gpui_kit::Result<Option<Cow<'static, [u8]>>> {
        if path == BRAND_MARK {
            return Ok(Some(Cow::Borrowed(BRAND_MARK_SVG)));
        }
        if let Some(bytes) = ConduitIcons.load(path)? {
            return Ok(Some(bytes));
        }
        gpui_kit::assets::Assets.load(path)
    }

    fn list(&self, path: &str) -> gpui_kit::Result<Vec<SharedString>> {
        let mut paths = gpui_kit::assets::Assets.list(path)?;
        paths.extend(ConduitIcons.list(path)?);
        if BRAND_MARK.starts_with(path) {
            paths.push(BRAND_MARK.into());
        }
        paths.sort();
        paths.dedup();
        Ok(paths)
    }
}

/// An icon at `size` points in `color`. Decorative: wrap it in a labelled
/// control when it is the only content of one.
pub fn icon(name: IconName, size: f32, color: Hsla) -> Svg {
    svg()
        .path(name.path())
        .size(Pixels::from(size))
        .flex_none()
        .text_color(color)
}

/// The Conduit mark.
pub fn brand_mark(size: f32, color: Hsla) -> impl IntoElement {
    svg()
        .path(BRAND_MARK)
        .size(Pixels::from(size))
        .flex_none()
        .text_color(color)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_selected_icon_and_the_mark_load() {
        for name in [IconName::Brain, IconName::SquarePen, IconName::ThumbsUp] {
            let bytes = ConduitAssets.load(&name.path()).unwrap();
            assert!(bytes.is_some_and(|b| b.starts_with(b"<svg")), "{name:?}");
        }
        assert!(ConduitAssets.load(BRAND_MARK).unwrap().is_some());
        // GPUI Kit's own component icons still resolve.
        assert!(ConduitAssets.load("icons/check.svg").unwrap().is_some());
    }
}
