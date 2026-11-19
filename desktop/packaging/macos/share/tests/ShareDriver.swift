// A stand-in for "any app" in share/e2e-system.sh: it opens the test
// bundle's Share extension as an app's Share menu does, and calls the
// Services menu's "Ask Conduit" as an app's Services menu does.
//
//   ShareDriver share EXTENSION_ID SECONDS TEXT FILE...
//       shows a window, performs the extension's sharing service with TEXT
//       and the FILEs, reports the windows ShareKit put up, waits SECONDS
//       (the extension loads and stages the items meanwhile) and quits,
//       which closes the sheet without sharing
//   ShareDriver service NAME TEXT
//       NSPerformService(NAME) with TEXT on a pasteboard
//
// Only a test bundle's extension: an id under app.cogwheel.conduit.desktop.
// other than the release one. Never another app's extension or service,
// which would reach the user's real data.
//
// What it cannot do: since macOS 13 the sheet is a remote view in windows
// ShareKit lays over the host (SHKRemoteWindow), which accepts neither
// keys posted by the host (NSEvent or CGEvent to its own pid) nor a
// capture without Screen Recording permission. Pressing Open in Conduit is
// left to a person; share/preview.sh draws the sheet's content.
//
// Prints one "DRIVER …" line per step.

import AppKit

func say(_ text: String) {
  print("DRIVER \(text)")
  fflush(stdout)
}

let testPrefix = "app.cogwheel.conduit.desktop."
let releaseExtension = "app.cogwheel.conduit.desktop.share"

final class Driver: NSObject, NSApplicationDelegate, NSSharingServiceDelegate {
  let args: [String]
  var window: NSWindow!

  init(args: [String]) { self.args = args }

  func applicationDidFinishLaunching(_ notification: Notification) {
    switch args.first {
    case "share": share()
    case "service": service()
    default:
      say("usage: share EXTENSION_ID SECONDS TEXT FILE... | service NAME TEXT")
      exit(2)
    }
  }

  // MARK: - Share

  func share() {
    guard args.count >= 4, let seconds = Double(args[2]) else {
      say("usage: share EXTENSION_ID SECONDS TEXT FILE...")
      exit(2)
    }
    let (id, text) = (args[1], args[3])
    guard id.hasPrefix(testPrefix), id.hasSuffix(".share"), id != releaseExtension else {
      say("refusing \(id): only a test bundle's Conduit extension")
      exit(2)
    }
    let files = args.dropFirst(4).map { URL(fileURLWithPath: $0) }
    window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.title = "Share driver"
    window.center()
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)

    let items: [Any] = [text as NSString] + files.map { $0 as NSURL }
    // An extension's sharing service is named by its bundle id.
    guard let service = NSSharingService(named: NSSharingService.Name(id)) else {
      say("no sharing service \(id)")
      exit(3)
    }
    say("service title=\(service.title)")
    service.delegate = self
    guard service.canPerform(withItems: items) else {
      say("cannot perform")
      exit(4)
    }
    service.perform(withItems: items)

    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [self] in
      let overlays = NSApp.windows.filter { $0 !== window && $0.isVisible }
      for w in overlays {
        say("sharekit window \(Swift.type(of: w)) \(Int(w.frame.width))x\(Int(w.frame.height))")
      }
      say(overlays.contains { "\(Swift.type(of: $0))" == "SHKRemoteWindow" }
        ? "presented" : "not presented")
      // Quitting the host closes the sheet without sharing.
      exit(0)
    }
  }

  func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
    say("shared")
  }

  func sharingService(
    _ sharingService: NSSharingService, didFailToShareItems items: [Any], error: Error
  ) {
    say("ended: \((error as NSError).code)")
  }

  func sharingService(
    _ sharingService: NSSharingService, sourceWindowForShareItems items: [Any],
    sharingContentScope: UnsafeMutablePointer<NSSharingService.SharingContentScope>
  ) -> NSWindow? {
    window
  }

  // MARK: - Services

  func service() {
    guard args.count == 3 else {
      say("usage: service NAME TEXT")
      exit(2)
    }
    let pboard = NSPasteboard.withUniqueName()
    pboard.clearContents()
    pboard.setString(args[2], forType: .string)
    let done = NSPerformService(args[1], pboard)
    say("service \(args[1]): \(done)")
    pboard.releaseGlobally()
    exit(done ? 0 : 1)
  }
}

let app = NSApplication.shared
let driver = Driver(args: Array(CommandLine.arguments.dropFirst()))
app.delegate = driver
app.setActivationPolicy(.regular)
app.run()
