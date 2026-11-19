// Draws the Share sheet's view outside a share, for screenshots: the
// extension's own view controller (compiled with -D SHARE_PREVIEW) over
// synthetic items, in light or dark, written as a PNG. share/test.sh builds
// it; the shots go wherever the caller says.
//
//   SharePreview light|dark OUT.png ICON.icns FILE...
//
// The real sheet (ShareKit's windows around it) cannot be captured from
// the host without Screen Recording permission; this is its content.

import AppKit

/// A synthetic picture: a green gradient, as a PNG.
func gradient() -> Data {
  let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: 160, pixelsHigh: 100, bitsPerSample: 8,
    samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB,
    bytesPerRow: 0, bitsPerPixel: 0)!
  for y in 0..<100 {
    for x in 0..<160 {
      rep.setColor(
        NSColor(
          deviceRed: CGFloat(40 + x / 4) / 255, green: CGFloat(110 + y) / 255,
          blue: CGFloat(60 + (x + y) / 6) / 255, alpha: 1),
        atX: x, y: y)
    }
  }
  return rep.representation(using: .png, properties: [:]) ?? Data()
}

@main
enum SharePreview {
  static func main() {
    let args = Array(CommandLine.arguments.dropFirst())
    guard args.count >= 3 else {
      print("usage: SharePreview light|dark OUT.png ICON.icns FILE...")
      exit(2)
    }
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    let dark = args[0] == "dark"
    app.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)

    let item = NSExtensionItem()
    var providers = [
      NSItemProvider(object: "Ferns and hostas like shade." as NSString),
      NSItemProvider(object: URL(string: "https://example.org/garden/shade-plants")! as NSURL),
    ]
    let inbox = FileManager.default.temporaryDirectory
      .appendingPathComponent("conduit-share-preview-\(getpid())", isDirectory: true)
    let picture = inbox.appendingPathComponent("shady corner.png")
    try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
    try? gradient().write(to: picture)
    for url in [picture] + args.dropFirst(3).map({ URL(fileURLWithPath: $0) }) {
      providers.append(NSItemProvider(contentsOf: url)!)
    }
    item.attachments = providers
    let controller = ShareViewController()
    controller.previewItems = [item]
    controller.previewInbox = inbox.appendingPathComponent("inbox", isDirectory: true)
    controller.previewIcon = NSImage(contentsOfFile: args[2])

    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentViewController = controller
    window.appearance = app.appearance
    window.backgroundColor = dark
      ? NSColor(white: 0.17, alpha: 1) : NSColor(white: 0.97, alpha: 1)
    // Never on screen: cacheDisplay draws it where it is.

    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
      let view = controller.view
      view.layoutSubtreeIfNeeded()
      window.setContentSize(view.fittingSize)
      view.layoutSubtreeIfNeeded()
      let content = window.contentView!
      content.wantsLayer = true
      content.layer?.backgroundColor = window.backgroundColor.cgColor
      guard let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { exit(3) }
      content.cacheDisplay(in: content.bounds, to: rep)
      let data = rep.representation(using: .png, properties: [:])
      do {
        try data?.write(to: URL(fileURLWithPath: args[1]))
        try? FileManager.default.removeItem(at: inbox)
        print("SharePreview: \(args[1]) \(Int(content.bounds.width))x\(Int(content.bounds.height))")
        exit(0)
      } catch {
        print("SharePreview: \(error)")
        exit(1)
      }
    }
    app.run()
  }
}
