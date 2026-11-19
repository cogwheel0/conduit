// The widget's views: small, medium and large, signed in or out.
//
// Everything is drawn from the snapshot and the style the system asks for,
// passed in rather than read from WidgetKit's environment, so the render
// tool (Render/RenderWidgets.swift) draws the same views outside a widget.

import SwiftUI

enum WidgetSize: String, CaseIterable {
    case small, medium, large

    /// The macOS sizes, in points (the render tool's canvases).
    var points: CGSize {
        switch self {
        case .small: CGSize(width: 170, height: 170)
        case .medium: CGSize(width: 364, height: 170)
        case .large: CGSize(width: 364, height: 382)
        }
    }

    /// How many chats the family lists.
    var rows: Int {
        switch self {
        case .small: 1
        case .medium: 3
        case .large: WidgetSnapshot.maxChats
        }
    }
}

/// How the system draws the widget (WidgetKit's rendering modes).
enum WidgetStyle: String, CaseIterable {
    /// Conduit's own colours (a desktop widget in front, Notification
    /// Center).
    case fullColor
    /// Tinted or clear (macOS 26 and later): the system draws the
    /// background and tints the accented parts (the mark) with the
    /// accent colour, the rest in one colour.
    case accented
    /// A desktop widget behind the windows: the system desaturates it
    /// into the wallpaper.
    case vibrant
}

/// The Conduit monochrome palette (desktop/crates/components/assets/themes,
/// `conduit`), and the system's own colours where the system tints.
struct WidgetPalette {
    let background: Color
    let fill: Color
    let primary: Color
    let secondary: Color
    let separator: Color

    init(style: WidgetStyle, dark: Bool) {
        switch style {
        case .fullColor where dark:
            background = Color(red: 0x14 / 255, green: 0x14 / 255, blue: 0x14 / 255)
            fill = Color(red: 0x23 / 255, green: 0x23 / 255, blue: 0x23 / 255)
            primary = Color(red: 0xEC / 255, green: 0xEC / 255, blue: 0xEC / 255)
            secondary = Color(red: 0x98 / 255, green: 0x98 / 255, blue: 0x9F / 255)
            separator = Color(red: 0xEC / 255, green: 0xEC / 255, blue: 0xEC / 255).opacity(0.1)
        case .fullColor:
            background = .white
            fill = Color(red: 0xF4 / 255, green: 0xF4 / 255, blue: 0xF4 / 255)
            primary = .black
            secondary = Color(red: 0x6E / 255, green: 0x6E / 255, blue: 0x73 / 255)
            separator = Color(red: 0xE5 / 255, green: 0xE5 / 255, blue: 0xE5 / 255)
        case .accented, .vibrant:
            background = .clear
            fill = Color.primary.opacity(0.12)
            primary = .primary
            secondary = .secondary
            separator = Color.primary.opacity(0.12)
        }
    }
}

struct WidgetContent: View {
    /// Nil until the app has written one.
    let snapshot: WidgetSnapshot?
    let size: WidgetSize
    let style: WidgetStyle
    let now: Date

    @Environment(\.colorScheme) private var scheme

    private var l10n: WidgetL10n { WidgetL10n(appLocale: snapshot?.locale) }
    private var palette: WidgetPalette { WidgetPalette(style: style, dark: scheme == .dark) }

    var body: some View {
        Group {
            if let snapshot, !snapshot.signedIn {
                SignedOut(size: size, l10n: l10n, palette: palette)
            } else {
                switch size {
                case .small: small
                case .medium: medium
                case .large: large
                }
            }
        }
        .environment(\.locale, l10n.formattingLocale)
    }

    private var chats: [WidgetSnapshot.Chat] {
        Array((snapshot?.chats ?? []).prefix(size.rows))
    }

    // MARK: Families

    private var small: some View {
        VStack(alignment: .leading, spacing: 10) {
            AskBar(title: l10n(.ask), height: 34, palette: palette)
            if let chat = chats.first {
                ChatLink(chat: chat) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(chat.title)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(palette.primary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(l10n.stamp(chat.updatedAt, now: now))
                            .font(.system(size: 11))
                            .foregroundStyle(palette.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if snapshot != nil {
                Text(l10n(.noChats))
                    .font(.system(size: 12))
                    .foregroundStyle(palette.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                ActionButton(
                    symbol: "square.and.pencil", label: l10n(.newChat), layout: .iconOnly,
                    url: WidgetLink.newChat, palette: palette)
                ActionButton(
                    symbol: "waveform", label: l10n(.voiceCall), layout: .iconOnly,
                    url: WidgetLink.voiceCall, palette: palette)
                ActionButton(
                    symbol: "doc.on.clipboard", label: l10n(.clipboard), layout: .iconOnly,
                    url: WidgetLink.clipboard, palette: palette)
            }
            .frame(height: 34)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var medium: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                AskBar(title: l10n(.ask), height: 34, palette: palette)
                ActionButton(
                    symbol: "square.and.pencil", label: l10n(.newChat), layout: .iconOnly,
                    url: WidgetLink.newChat, palette: palette
                )
                .frame(width: 44)
                ActionButton(
                    symbol: "waveform", label: l10n(.voiceCall), layout: .iconOnly,
                    url: WidgetLink.voiceCall, palette: palette
                )
                .frame(width: 44)
                ActionButton(
                    symbol: "doc.on.clipboard", label: l10n(.clipboard), layout: .iconOnly,
                    url: WidgetLink.clipboard, palette: palette
                )
                .frame(width: 44)
            }
            .frame(height: 34)
            RecentList(
                chats: chats, rows: size.rows, rowHeight: 24, snapshot: snapshot, now: now,
                l10n: l10n, palette: palette)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var large: some View {
        VStack(alignment: .leading, spacing: 10) {
            AskBar(title: l10n(.ask), height: 40, palette: palette)
            HStack(spacing: 8) {
                ActionButton(
                    symbol: "square.and.pencil", label: l10n(.newChat), layout: .stacked,
                    url: WidgetLink.newChat, palette: palette)
                ActionButton(
                    symbol: "waveform", label: l10n(.voiceCall), layout: .stacked,
                    url: WidgetLink.voiceCall, palette: palette)
                ActionButton(
                    symbol: "doc.on.clipboard", label: l10n(.clipboard), layout: .stacked,
                    url: WidgetLink.clipboard, palette: palette)
            }
            .frame(height: 52)
            RecentList(
                chats: chats, rows: size.rows, rowHeight: 34, snapshot: snapshot, now: now,
                l10n: l10n, palette: palette
            )
            .padding(.top, 4)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Parts

private struct DrawsLinksKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// Links are drawn as links (the widget); the render tool turns this
    /// off, because ImageRenderer can't draw a `Link`.
    var drawsLinks: Bool {
        get { self[DrawsLinksKey.self] }
        set { self[DrawsLinksKey.self] = newValue }
    }
}

/// Something the user clicks in the widget: a link to the app.
struct TapTarget<Label: View>: View {
    let url: URL?
    @ViewBuilder let label: () -> Label

    @Environment(\.drawsLinks) private var drawsLinks

    var body: some View {
        if drawsLinks, let url {
            Link(destination: url) { label() }
        } else {
            label()
        }
    }
}

/// "Ask Conduit": opens Quick Ask. Drawn like a field, as the panel's own
/// composer is.
struct AskBar: View {
    let title: String
    let height: CGFloat
    let palette: WidgetPalette

    var body: some View {
        TapTarget(url: WidgetLink.quickAsk) {
            HStack(spacing: 8) {
                ConduitMark()
                    .frame(width: 18, height: 18)
                    .foregroundStyle(palette.primary)
                    .widgetAccentable()
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(palette.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(Capsule(style: .continuous).fill(palette.fill))
            .contentShape(Capsule(style: .continuous))
        }
        .accessibilityLabel(title)
    }
}

struct ActionButton: View {
    enum Layout {
        /// The symbol alone (small); the label is VoiceOver's.
        case iconOnly
        /// The symbol beside its label.
        case inline
        /// The symbol over its label (large: three buttons in a row, with
        /// room for the longer languages' words).
        case stacked
    }

    let symbol: String
    let label: String
    let layout: Layout
    let url: URL
    let palette: WidgetPalette

    var body: some View {
        TapTarget(url: url) {
            content
                .foregroundStyle(palette.primary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(palette.fill)
                )
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .accessibilityLabel(label)
    }

    @ViewBuilder private var content: some View {
        let image = Image(systemName: symbol).font(.system(size: 15, weight: .medium))
        switch layout {
        case .iconOnly:
            image
        case .inline:
            HStack(spacing: 6) {
                image
                Text(label)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .padding(.horizontal, 10)
        case .stacked:
            VStack(spacing: 4) {
                // One height for every symbol, so the labels line up.
                image.frame(height: 18)
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .padding(.horizontal, 6)
        }
    }
}

/// A chat's row links to it; a row without a usable link is plain.
struct ChatLink<Label: View>: View {
    let chat: WidgetSnapshot.Chat
    @ViewBuilder let label: () -> Label

    var body: some View {
        TapTarget(url: WidgetLink.chat(chat.id), label: label)
    }
}

struct RecentList: View {
    let chats: [WidgetSnapshot.Chat]
    let rows: Int
    let rowHeight: CGFloat
    let snapshot: WidgetSnapshot?
    let now: Date
    let l10n: WidgetL10n
    let palette: WidgetPalette

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(l10n(.recentChats))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(palette.secondary)
                .lineLimit(1)
                .padding(.bottom, 2)
                .accessibilityAddTraits(.isHeader)
            if chats.isEmpty {
                if snapshot != nil {
                    Text(l10n(.noChats))
                        .font(.system(size: 12))
                        .foregroundStyle(palette.secondary)
                        .padding(.top, 4)
                }
            } else {
                ForEach(Array(chats.enumerated()), id: \.element.id) { index, chat in
                    if index > 0 {
                        Rectangle().fill(palette.separator).frame(height: 1)
                    }
                    ChatLink(chat: chat) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(chat.title)
                                .font(.system(size: 13))
                                .foregroundStyle(palette.primary)
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            Text(l10n.stamp(chat.updatedAt, now: now))
                                .font(.system(size: 11))
                                .foregroundStyle(palette.secondary)
                                .lineLimit(1)
                                .fixedSize()
                        }
                        .frame(height: rowHeight)
                        .contentShape(Rectangle())
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Nobody is signed in: no chats, only the way back into the app. The
/// small family reads from its corner; the wider ones are centred.
struct SignedOut: View {
    let size: WidgetSize
    let l10n: WidgetL10n
    let palette: WidgetPalette

    var body: some View {
        if size == .small {
            VStack(alignment: .leading, spacing: 8) {
                mark(24)
                Spacer(minLength: 0)
                message(alignment: .leading, lines: 3)
                button.frame(maxWidth: .infinity)
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            VStack(spacing: size == .large ? 14 : 10) {
                mark(size == .large ? 36 : 28)
                message(alignment: .center, lines: 2)
                button
            }
            .padding(size == .large ? 24 : 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func mark(_ side: CGFloat) -> some View {
        ConduitMark()
            .frame(width: side, height: side)
            .foregroundStyle(palette.primary)
            .widgetAccentable()
    }

    private func message(alignment: TextAlignment, lines: Int) -> some View {
        Text(l10n(.signedOut))
            .font(.system(size: size == .small ? 12 : 13))
            .foregroundStyle(palette.secondary)
            .multilineTextAlignment(alignment)
            .lineLimit(lines)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var button: some View {
        TapTarget(url: WidgetLink.newChat) {
            Text(l10n(.openConduit))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(palette.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.horizontal, 14)
                .frame(height: 30)
                .frame(maxWidth: size == .small ? .infinity : nil)
                .background(Capsule(style: .continuous).fill(palette.fill))
                .contentShape(Capsule(style: .continuous))
        }
        .accessibilityLabel(l10n(.openConduit))
    }
}
