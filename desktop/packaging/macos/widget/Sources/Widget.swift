// The widget: its timeline (the app's snapshot, read again at each
// midnight so the dates move on) and its configuration.

import OSLog
import SwiftUI
import WidgetKit

struct ConduitEntry: TimelineEntry {
    let date: Date
    /// Nil until the app has written one (or when it can't be read).
    let snapshot: WidgetSnapshot?
}

struct ConduitProvider: TimelineProvider {
    private static let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "conduit.widget", category: "timeline")

    func placeholder(in context: Context) -> ConduitEntry {
        ConduitEntry(date: Date(), snapshot: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (ConduitEntry) -> Void) {
        completion(ConduitEntry(date: Date(), snapshot: read()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ConduitEntry>) -> Void) {
        let now = Date()
        let snapshot = read()
        // "Today" turns into "Yesterday" at midnight: one entry for now and
        // one for each of the next two midnights, then read again. The app
        // asks for a new timeline whenever its chats change.
        let midnights = WidgetL10n.dayBoundaries(after: now, count: 2)
        let entries =
            [ConduitEntry(date: now, snapshot: snapshot)]
            + midnights.map { ConduitEntry(date: $0, snapshot: snapshot) }
        completion(Timeline(entries: entries, policy: .after(midnights.last ?? now)))
    }

    private func read() -> WidgetSnapshot? {
        guard let url = WidgetSnapshot.url() else {
            Self.log.error("no app group container (ConduitAppGroup or its entitlement is missing)")
            return nil
        }
        guard let snapshot = WidgetSnapshot.load(from: url) else {
            Self.log.info("no snapshot yet")
            return nil
        }
        // Counts only: never titles or ids.
        Self.log.info(
            "snapshot: signedIn=\(snapshot.signedIn, privacy: .public) chats=\(snapshot.chats.count, privacy: .public)"
        )
        return snapshot
    }
}

struct ConduitWidgetView: View {
    let entry: ConduitEntry

    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var mode
    @Environment(\.colorScheme) private var scheme

    private var style: WidgetStyle {
        switch mode {
        case .accented: .accented
        case .vibrant: .vibrant
        default: .fullColor
        }
    }

    private var size: WidgetSize {
        switch family {
        case .systemSmall: .small
        case .systemLarge, .systemExtraLarge: .large
        default: .medium
        }
    }

    var body: some View {
        WidgetContent(snapshot: entry.snapshot, size: size, style: style, now: entry.date)
            .containerBackground(for: .widget) {
                WidgetPalette(style: style, dark: scheme == .dark).background
            }
    }
}

struct ConduitWidget: Widget {
    /// What the app's reload names (Bridge/WidgetBridge.swift reloads all).
    static let kind = "ConduitWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: ConduitProvider()) { entry in
            ConduitWidgetView(entry: entry)
        }
        .configurationDisplayName("Conduit")
        .description(WidgetL10n(appLocale: nil)(.galleryDescription))
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}
