// Draws the widget's views to PNG files, outside WidgetKit: the gallery
// needs a signed bundle (docs/BUILDING-DESKTOP.md), these don't.
//
//   widget/render.sh OUT_DIR
//
// The same views as the widget (Sources/), fed the app's snapshot format
// (Fixtures/snapshot.json, which the app's writer test checks), at a fixed
// clock, in light and dark, for each family and state. The tile is drawn
// as macOS draws a desktop widget: the container background, the system's
// corner radius, on a neutral desktop.

import AppKit
import SwiftUI

@MainActor
struct Renderer {
    let out: URL
    let fixture: WidgetSnapshot
    let now: Date
    var written: [String] = []

    /// A desktop widget's corner radius on macOS 14 and later.
    static let radius: CGFloat = 22
    static let margin: CGFloat = 24

    mutating func shot(
        _ name: String, snapshot: WidgetSnapshot?, size: WidgetSize, dark: Bool,
        style: WidgetStyle = .fullColor
    ) {
        let palette = WidgetPalette(style: style, dark: dark)
        let tile = WidgetContent(snapshot: snapshot, size: size, style: style, now: now)
            .frame(width: size.points.width, height: size.points.height)
            .background(palette.background)
            .clipShape(RoundedRectangle(cornerRadius: Self.radius, style: .continuous))
        let shape = RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
        let canvas = ZStack {
            Desktop(dark: dark)
            // The shadow on its own shape: on the tile it would fall from
            // every row and button.
            shape
                .fill(dark ? Color.black : Color.white)
                .frame(width: size.points.width, height: size.points.height)
                .shadow(color: .black.opacity(dark ? 0.5 : 0.18), radius: 10, y: 4)
            // The accented and vibrant styles have no background of their
            // own: the system's material stands in.
            if style != .fullColor {
                shape
                    .fill(.regularMaterial)
                    .frame(width: size.points.width, height: size.points.height)
            }
            tile
        }
        .frame(
            width: size.points.width + 2 * Self.margin,
            height: size.points.height + 2 * Self.margin
        )
        .environment(\.colorScheme, dark ? .dark : .light)
        .environment(\.drawsLinks, false)

        let renderer = ImageRenderer(content: canvas)
        renderer.scale = 2
        guard let image = renderer.cgImage else {
            FileHandle.standardError.write("could not render \(name)\n".data(using: .utf8)!)
            exit(1)
        }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
        let file = out.appendingPathComponent("\(name).png")
        do { try png.write(to: file) } catch {
            FileHandle.standardError.write("\(file.path): \(error)\n".data(using: .utf8)!)
            exit(1)
        }
        written.append(file.lastPathComponent)
    }
}

/// A plain desktop behind the tile.
struct Desktop: View {
    let dark: Bool
    var body: some View {
        LinearGradient(
            colors: dark
                ? [Color(white: 0.16), Color(white: 0.10)]
                : [Color(white: 0.86), Color(white: 0.78)],
            startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

@main
struct RenderWidgets {
    @MainActor static func main() {
        let args = CommandLine.arguments
        guard args.count >= 3 else {
            print("usage: render-widgets FIXTURE OUT_DIR")
            exit(2)
        }
        let fixtureURL = URL(fileURLWithPath: args[1])
        let out = URL(fileURLWithPath: args[2], isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        guard let fixture = WidgetSnapshot.load(from: fixtureURL) else {
            print("could not read \(fixtureURL.path)")
            exit(1)
        }
        // The fixture's clock: 2026-11-11 15:00 UTC, in UTC, so the dates
        // read the same on every Mac.
        NSTimeZone.default = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_794_409_200)
        var r = Renderer(out: out, fixture: fixture, now: now)

        var signedOut = fixture
        signedOut.signedIn = false
        signedOut.chats = []
        var empty = fixture
        empty.chats = []

        for dark in [false, true] {
            let scheme = dark ? "dark" : "light"
            for size in WidgetSize.allCases {
                r.shot("\(size.rawValue)-\(scheme)", snapshot: fixture, size: size, dark: dark)
                r.shot(
                    "\(size.rawValue)-signed-out-\(scheme)", snapshot: signedOut, size: size,
                    dark: dark)
            }
            r.shot("medium-no-chats-\(scheme)", snapshot: empty, size: .medium, dark: dark)
            r.shot("small-no-snapshot-\(scheme)", snapshot: nil, size: .small, dark: dark)
            // The system's own colours where it tints (macOS 26 tinted and
            // clear desktop styles; a desktop widget behind windows), drawn
            // here on a material as an approximation of the system's look.
            r.shot("medium-accented-\(scheme)", snapshot: fixture, size: .medium, dark: dark, style: .accented)
        }
        // Longer words: the app's language comes with the snapshot.
        for locale in ["de", "es", "ja", "ru"] {
            var localized = fixture
            localized.locale = locale
            r.shot("medium-\(locale)-light", snapshot: localized, size: .medium, dark: false)
            r.shot("large-\(locale)-dark", snapshot: localized, size: .large, dark: true)
            var out = signedOut
            out.locale = locale
            r.shot("small-signed-out-\(locale)-light", snapshot: out, size: .small, dark: false)
        }
        print("wrote \(r.written.count) images to \(out.path)")
    }
}
