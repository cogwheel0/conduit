//
//  ConduitWidget.swift
//  ConduitWidget
//
//  Created by cogwheel on 07/12/25.
//

import WidgetKit
import SwiftUI

private enum WidgetDeepLink {
    static var scheme: String {
        guard
            let configuredScheme = Bundle.main.object(forInfoDictionaryKey: "AppUrlScheme") as? String,
            !configuredScheme.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return "conduit"
        }
        return configuredScheme
    }

    static func url(for action: String) -> URL {
        URL(string: "\(scheme)://\(action)?homeWidget=true")!
    }
}

// MARK: - Timeline Entry

struct ConduitEntry: TimelineEntry {
    let date: Date
}

// MARK: - Timeline Provider

struct ConduitProvider: TimelineProvider {
    func placeholder(in context: Context) -> ConduitEntry {
        ConduitEntry(date: Date())
    }

    func getSnapshot(in context: Context, completion: @escaping (ConduitEntry) -> Void) {
        let entry = ConduitEntry(date: Date())
        completion(entry)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ConduitEntry>) -> Void) {
        let entry = ConduitEntry(date: Date())
        let timeline = Timeline(entries: [entry], policy: .never)
        completion(timeline)
    }
}

// MARK: - Widget View

struct ConduitWidgetEntryView: View {
    var entry: ConduitProvider.Entry
    @Environment(\.widgetFamily) var family
    @Environment(\.colorScheme) var colorScheme

    /// Adaptive text/icon color based on color scheme
    private var contentColor: Color {
        colorScheme == .dark ? .white : .black
    }

    /// Adaptive button background based on color scheme
    private var buttonBackground: Color {
        colorScheme == .dark
            ? .white.opacity(0.15)
            : .black.opacity(0.08)
    }

    var body: some View {
        VStack(spacing: 12) {
            // Main "Ask Conduit" pill - ChatGPT style
            Link(destination: WidgetDeepLink.url(for: "new_chat")) {
                HStack(spacing: 12) {
                    Image("HubIcon")
                        .renderingMode(.template)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 28, height: 28)
                        .foregroundStyle(contentColor.opacity(0.85))
                    Text("Ask Conduit")
                        .font(.system(size: 18, weight: .medium, design: .rounded))
                        .foregroundStyle(contentColor.opacity(0.85))
                    Spacer()
                }
                .padding(.horizontal, 20)
                .frame(maxWidth: .infinity)
                .frame(height: 56)
                .background(
                    Capsule()
                        .fill(buttonBackground)
                )
            }
            .buttonStyle(.plain)

            // 4 circular icon buttons - ChatGPT style, fill width
            HStack(spacing: 8) {
                CircularIconButton(
                    symbol: "camera",
                    destination: WidgetDeepLink.url(for: "camera"),
                    contentColor: contentColor,
                    buttonBackground: buttonBackground
                )
                CircularIconButton(
                    symbol: "photo.on.rectangle.angled",
                    destination: WidgetDeepLink.url(for: "photos"),
                    contentColor: contentColor,
                    buttonBackground: buttonBackground
                )
                CircularIconButton(
                    symbol: "waveform",
                    destination: WidgetDeepLink.url(for: "mic"),
                    contentColor: contentColor,
                    buttonBackground: buttonBackground
                )
                CircularIconButton(
                    symbol: "doc.on.clipboard",
                    destination: WidgetDeepLink.url(for: "clipboard"),
                    contentColor: contentColor,
                    buttonBackground: buttonBackground
                )
            }
        }
        .padding(16)
    }
}

// MARK: - Circular Icon Button (ChatGPT Style)

struct CircularIconButton: View {
    let symbol: String
    let destination: URL
    let contentColor: Color
    let buttonBackground: Color

    var body: some View {
        Link(destination: destination) {
            Image(systemName: symbol)
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(contentColor.opacity(0.85))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(buttonBackground)
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Widget Configuration

struct ConduitWidget: Widget {
    let kind: String = "ConduitWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ConduitProvider()) { entry in
            if #available(iOS 17.0, *) {
                ConduitWidgetEntryView(entry: entry)
                    .containerBackground(Color("WidgetBackground"), for: .widget)
            } else {
                ConduitWidgetEntryView(entry: entry)
                    .background(Color("WidgetBackground"))
            }
        }
        .configurationDisplayName("Conduit")
        .description("Quick access to chat, camera, photos, and voice.")
        .supportedFamilies([.systemMedium])
        .contentMarginsDisabled()
    }
}

// MARK: - Preview

#Preview(as: .systemMedium) {
    ConduitWidget()
} timeline: {
    ConduitEntry(date: .now)
}

