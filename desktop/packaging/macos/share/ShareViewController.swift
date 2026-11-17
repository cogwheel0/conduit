// Conduit's Share extension: "Conduit" in any app's Share menu.
//
// The sheet shows what is being shared (files with their sizes, links,
// text) and an optional message, with Cancel and Open in Conduit. Open in
// Conduit hands the share to the app (ShareInbox.swift), which starts a new
// chat with the message and text in the message field and the files
// attached, never sent: the phone's share flow, with a Mac sheet in front.
//
// Return opens (⌥Return starts a new line in the message), Esc cancels.

import AppKit
import UniformTypeIdentifiers

/// The sheet's words, from Localizable.strings (generated from the app's
/// ARB catalogs by packaging/macos/native_strings.py), with English kept
/// here for a missing table.
private enum Words {
  static func word(_ key: String, _ english: String) -> String {
    Bundle.main.localizedString(forKey: key, value: english, table: nil)
  }

  static var cancel: String { word("cancel", "Cancel") }
  static var open: String { word("open", "Open in Conduit") }
  static var message: String { word("message", "Message") }
  static var messagePlaceholder: String { word("messagePlaceholder", "Add a message") }
  static var items: String { word("items", "Shared items") }
  static var nothing: String { word("nothing", "None of these items can be added to a chat.") }
  static var failed: String { word("failed", "Conduit couldn't be opened. Try again.") }
  static func tooLarge(_ name: String) -> String {
    String(format: word("tooLarge", "%1$@ is larger than 256 MB, so it wasn't attached."), name)
  }
}

/// One line in the sheet's list.
/// An error as the system log keeps it: its domain and code only. An
/// NSError's description can name the shared file and its path.
private func logged(_ error: Error) -> String {
  let error = error as NSError
  return "\(error.domain) \(error.code)"
}

private struct Row {
  enum Kind {
    case file(URL, Int64)
    case link(URL)
    case text(String)
  }

  let kind: Kind
}

@objc(ConduitShareViewController)
final class ShareViewController: NSViewController, NSTextFieldDelegate {
  /// Conduit.app: this extension lives in its Contents/PlugIns.
  private let appURL = Bundle.main.bundleURL
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()

  /// The draft is only touched on this queue.
  private let queue = DispatchQueue(label: "app.cogwheel.conduit.share.staging")
  private var draft: ShareDraft?
  private var publishedID: String?

  private var rows: [Row] = []
  private var loading = true
  private var sending = false
  private var hasContent = false

  private let messageField = NSTextField()
  private let listStack = NSStackView()
  private let listScroll = NSScrollView()
  private let listBox = NSBox()
  private let spinner = NSProgressIndicator()
  private let note = NSTextField(wrappingLabelWithString: "")
  private var listHeight: NSLayoutConstraint?
  private lazy var cancelButton = NSButton(
    title: Words.cancel, target: self, action: #selector(cancelShare(_:)))
  private lazy var openButton = NSButton(
    title: Words.open, target: self, action: #selector(openInConduit(_:)))

  private static let width: CGFloat = 400
  private static let rowHeight: CGFloat = 30
  private static let visibleRows = 4

  // MARK: - View

  override func loadView() {
    let root = NSView()
    root.translatesAutoresizingMaskIntoConstraints = false

    let icon = NSImageView(image: appIcon)
    icon.translatesAutoresizingMaskIntoConstraints = false
    icon.setAccessibilityElement(false)
    NSLayoutConstraint.activate([
      icon.widthAnchor.constraint(equalToConstant: 20),
      icon.heightAnchor.constraint(equalToConstant: 20),
    ])
    let title = NSTextField(labelWithString: "Conduit")
    title.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
    title.setAccessibilityRole(.staticText)
    let header = NSStackView(views: [icon, title])
    header.orientation = .horizontal
    header.spacing = 6

    messageField.placeholderString = Words.messagePlaceholder
    messageField.setAccessibilityLabel(Words.message)
    messageField.usesSingleLineMode = false
    messageField.cell?.wraps = true
    messageField.cell?.isScrollable = false
    messageField.lineBreakMode = .byWordWrapping
    messageField.maximumNumberOfLines = 0
    messageField.delegate = self
    messageField.translatesAutoresizingMaskIntoConstraints = false
    messageField.heightAnchor.constraint(greaterThanOrEqualToConstant: 54).isActive = true

    listStack.orientation = .vertical
    listStack.alignment = .leading
    listStack.spacing = 0
    listStack.edgeInsets = NSEdgeInsets(top: 2, left: 0, bottom: 2, right: 0)
    listStack.translatesAutoresizingMaskIntoConstraints = false
    let clip = FlippedView()
    clip.translatesAutoresizingMaskIntoConstraints = false
    clip.addSubview(listStack)
    NSLayoutConstraint.activate([
      listStack.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
      listStack.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
      listStack.topAnchor.constraint(equalTo: clip.topAnchor),
      listStack.bottomAnchor.constraint(equalTo: clip.bottomAnchor),
    ])
    listScroll.documentView = clip
    listScroll.hasVerticalScroller = true
    listScroll.autohidesScrollers = true
    listScroll.borderType = .noBorder
    listScroll.drawsBackground = false
    // The box sizes its content view by autoresizing.
    listScroll.setAccessibilityLabel(Words.items)
    // A grouped, rounded background, as the system's share sheets have.
    listBox.boxType = .custom
    listBox.cornerRadius = 8
    listBox.borderWidth = 0
    listBox.fillColor = .quaternarySystemFill
    listBox.contentViewMargins = .zero
    listBox.titlePosition = .noTitle
    listBox.contentView = listScroll
    NSLayoutConstraint.activate([
      clip.leadingAnchor.constraint(equalTo: listScroll.contentView.leadingAnchor),
      clip.topAnchor.constraint(equalTo: listScroll.contentView.topAnchor),
      clip.widthAnchor.constraint(equalTo: listScroll.contentView.widthAnchor),
    ])
    let height = listBox.heightAnchor.constraint(equalToConstant: Self.rowHeight + 6)
    height.isActive = true
    listHeight = height

    spinner.style = .spinning
    spinner.controlSize = .small
    spinner.isDisplayedWhenStopped = false
    spinner.translatesAutoresizingMaskIntoConstraints = false

    note.textColor = .secondaryLabelColor
    note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    note.isHidden = true

    cancelButton.keyEquivalent = "\u{1b}"
    openButton.keyEquivalent = "\r"
    openButton.isEnabled = false
    let gap = NSView()
    gap.setContentHuggingPriority(.init(1), for: .horizontal)
    let buttons = NSStackView(views: [spinner, gap, cancelButton, openButton])
    buttons.orientation = .horizontal
    buttons.distribution = .fill
    buttons.spacing = 12

    let column = NSStackView(views: [header, messageField, listBox, note, buttons])
    column.orientation = .vertical
    column.alignment = .leading
    column.spacing = 12
    column.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
    column.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(column)
    for wide in [messageField, listBox, note, buttons] {
      wide.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -40).isActive = true
    }
    NSLayoutConstraint.activate([
      column.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      column.trailingAnchor.constraint(equalTo: root.trailingAnchor),
      column.topAnchor.constraint(equalTo: root.topAnchor),
      column.bottomAnchor.constraint(equalTo: root.bottomAnchor),
      root.widthAnchor.constraint(equalToConstant: Self.width),
    ])
    view = root
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    spinner.startAnimation(nil)
    load()
  }

  override func viewDidAppear() {
    super.viewDidAppear()
    view.window?.makeFirstResponder(messageField)
    resize()
  }

  private func resize() {
    view.layoutSubtreeIfNeeded()
    preferredContentSize = view.fittingSize
  }

  // MARK: - Loading

  #if SHARE_PREVIEW
    /// tests/SharePreview.swift only (never in the extension): items, an
    /// inbox and the app's icon for a sheet drawn outside a share.
    var previewItems: [NSExtensionItem] = []
    var previewInbox: URL?
    var previewIcon: NSImage?
    private var appIcon: NSImage { previewIcon ?? NSImage() }
    private var inputItems: [NSExtensionItem] { previewItems }
    private var appBundleID: String? { previewInbox == nil ? nil : "preview" }
    private func inboxRoot(_: String) -> URL { previewInbox! }
  #else
    private var inputItems: [NSExtensionItem] {
      (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
    }
    /// The app this extension hands shares to (Info.plist, set by the build).
    private let appBundleID = Bundle.main.object(
      forInfoDictionaryKey: "ConduitAppBundleIdentifier") as? String
    private func inboxRoot(_ appBundleID: String) -> URL {
      ShareInbox.root(appBundleID: appBundleID, home: ShareInbox.realHome())
    }
    private var appIcon: NSImage { NSWorkspace.shared.icon(forFile: appURL.path) }
  #endif

  private func load() {
    let items = inputItems
    guard let appBundleID else {
      finishLoading(rows: [], note: Words.failed)
      return
    }
    let root = inboxRoot(appBundleID)
    queue.async { [self] in
      var rows: [Row] = []
      var note: String?
      do {
        let draft = try ShareInbox.begin(root: root)
        self.draft = draft
        for item in items {
          if let text = item.attributedContentText?.string,
            draft.addText(text) == .added
          {
            rows.append(Row(kind: .text(draft.manifest.texts.last ?? text)))
          }
          for provider in item.attachments ?? [] {
            rows.append(contentsOf: Loader.load(provider, into: draft))
          }
        }
        let tooLarge = draft.manifest.tooLarge.map(Words.tooLarge)
        if !tooLarge.isEmpty { note = tooLarge.joined(separator: "\n") }
        if rows.isEmpty && note == nil { note = Words.nothing }
      } catch {
        NSLog("Conduit share: could not start a share: %@", logged(error))
        note = Words.failed
      }
      DispatchQueue.main.async { self.finishLoading(rows: rows, note: note) }
    }
  }

  private func finishLoading(rows: [Row], note text: String?) {
    loading = false
    spinner.stopAnimation(nil)
    self.rows = rows
    hasContent = !rows.isEmpty
    for row in rows { listStack.addArrangedSubview(RowView(row: row, width: Self.width - 40)) }
    let shown = min(max(rows.count, 1), Self.visibleRows)
    listHeight?.constant = CGFloat(shown) * Self.rowHeight + 6
    listBox.isHidden = rows.isEmpty
    show(note: text)
    updateButtons()
    resize()
  }

  private func show(note text: String?) {
    note.stringValue = text ?? ""
    note.isHidden = (text ?? "").isEmpty
  }

  private func updateButtons() {
    let message = !messageField.stringValue
      .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    openButton.isEnabled = !loading && !sending && (hasContent || message) && appBundleID != nil
    cancelButton.isEnabled = !sending
    messageField.isEnabled = !sending
  }

  // MARK: - Actions

  func controlTextDidChange(_ notification: Notification) {
    updateButtons()
  }

  func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
    switch selector {
    case #selector(NSResponder.insertNewline(_:)):
      openInConduit(nil)
      return true
    case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
      textView.insertNewlineIgnoringFieldEditor(nil)
      return true
    case #selector(NSResponder.cancelOperation(_:)):
      cancelShare(nil)
      return true
    default:
      return false
    }
  }

  @objc private func cancelShare(_ sender: Any?) {
    guard !sending else { return }
    // The sheet goes now, even while a slow item still loads; the share is
    // cleaned up on the staging queue once that load ends (and, should the
    // extension be gone first, the app's prune clears the part folder).
    queue.async { [self] in
      if publishedID != nil { draft?.withdraw() } else { draft?.discard() }
    }
    extensionContext?.cancelRequest(
      withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
  }

  @objc private func openInConduit(_ sender: Any?) {
    guard openButton.isEnabled else { return }
    sending = true
    spinner.startAnimation(nil)
    show(note: nil)
    updateButtons()
    let message = messageField.stringValue
    queue.async { [self] in
      var id = publishedID
      if id == nil, let draft {
        do {
          id = try draft.publish(message: message)
          publishedID = id
        } catch {
          NSLog("Conduit share: could not finish the share: %@", logged(error))
        }
      }
      DispatchQueue.main.async {
        guard let id else { return self.handOffFailed() }
        self.handOff(id: id)
      }
    }
  }

  private func handOff(id: String) {
    guard appURL.pathExtension == "app", let link = ShareInbox.link(id: id) else {
      return handOffFailed()
    }
    // This app, never whichever app owns conduit:// on this Mac.
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = true
    NSWorkspace.shared.open([link], withApplicationAt: appURL, configuration: configuration) {
      [weak self] _, error in
      DispatchQueue.main.async {
        guard let self else { return }
        if let error {
          NSLog("Conduit share: could not open Conduit: %@", logged(error))
          return self.handOffFailed()
        }
        self.extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
      }
    }
  }

  private func handOffFailed() {
    sending = false
    spinner.stopAnimation(nil)
    show(note: Words.failed)
    updateButtons()
    resize()
  }
}

// MARK: - Items

/// Reads each shared item into the draft, in order, one at a time (on the
/// draft's queue: it waits for the item provider).
private enum Loader {
  static let timeout = 60

  static func load(_ provider: NSItemProvider, into draft: ShareDraft) -> [Row] {
    let types = provider.registeredTypeIdentifiers
    func conforms(_ type: UTType) -> String? {
      types.first { UTType($0)?.conforms(to: type) == true }
    }
    if let type = conforms(.fileURL) ?? conforms(.url),
      let url = loadURL(provider, type: type)
    {
      return url.isFileURL ? file(url, into: draft) : link(url, into: draft)
    }
    if conforms(.image) == nil, let type = conforms(.plainText) ?? conforms(.text),
      let text = loadText(provider, type: type)
    {
      return draft.addText(text) == .added
        ? [Row(kind: .text(draft.manifest.texts.last ?? text))] : []
    }
    if let type = conforms(.image) ?? conforms(.data) {
      return data(provider, type: type, into: draft)
    }
    return []
  }

  /// Waits for one provider answer (at most `timeout` seconds). An answer
  /// that comes later is refused, and `drop` cleans up what it made.
  private static func wait<T>(
    drop: @escaping (T) -> Void = { _ in }, _ start: (@escaping (T?) -> Void) -> Void
  ) -> T? {
    let gate = ShareWait<T>()
    start { value in
      if !gate.deliver(value), let value { drop(value) }
    }
    return gate.wait(until: .now() + .seconds(timeout))
  }

  private static func loadURL(_ provider: NSItemProvider, type: String) -> URL? {
    wait { finish in
      provider.loadItem(forTypeIdentifier: type, options: nil) { item, _ in
        switch item {
        case let url as URL: finish(url)
        case let data as Data: finish(URL(dataRepresentation: data, relativeTo: nil))
        case let text as String: finish(URL(string: text))
        default: finish(nil)
        }
      }
    }
  }

  private static func loadText(_ provider: NSItemProvider, type: String) -> String? {
    wait { finish in
      provider.loadItem(forTypeIdentifier: type, options: nil) { item, _ in
        switch item {
        case let text as String: finish(text)
        case let text as NSAttributedString: finish(text.string)
        case let data as Data: finish(String(data: data, encoding: .utf8))
        default: finish(nil)
        }
      }
    }
  }

  private static func file(_ url: URL, into draft: ShareDraft) -> [Row] {
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    do {
      guard try draft.addFile(copying: url) == .added, let copy = draft.manifest.files.last
      else { return [] }
      let staged = draft.dir.appendingPathComponent(copy.path)
      let size = (try? staged.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
      return [Row(kind: .file(staged, size ?? 0))]
    } catch {
      NSLog("Conduit share: could not copy a file: %@", logged(error))
      return []
    }
  }

  private static func link(_ url: URL, into draft: ShareDraft) -> [Row] {
    draft.addURL(url) == .added ? [Row(kind: .link(url))] : []
  }

  /// An item that is only data (an image from a web page, a clipping): its
  /// file representation, copied under the item's suggested name. TIFF
  /// becomes PNG, which every server shows.
  private static func data(_ provider: NSItemProvider, type: String, into draft: ShareDraft)
    -> [Row]
  {
    let utType = UTType(type)
    let tiff = utType?.conforms(to: .tiff) == true
    let stem = provider.suggestedName.flatMap { $0.isEmpty ? nil : $0 }
      ?? (utType?.conforms(to: .image) == true ? "Image" : "File")
    let ext = tiff ? "png" : (utType?.preferredFilenameExtension ?? "")
    let name = (stem as NSString).pathExtension.isEmpty && !ext.isEmpty ? "\(stem).\(ext)" : stem
    // The provider's file lasts only as long as its callback: the callback
    // copies it aside (PNG for TIFF), and the share takes the copy here, on
    // the draft's queue, only if it came in time.
    let answer: Staged? = wait(drop: { $0.cleanUp() }) { finish in
      _ = provider.loadFileRepresentation(forTypeIdentifier: type) { url, _ in
        guard let url else { return finish(nil) }
        do {
          if tiff, let image = NSBitmapImageRep(data: try Data(contentsOf: url)),
            let png = image.representation(using: .png, properties: [:])
          {
            finish(.data(png))
          } else {
            finish(try Staged.copy(of: url))
          }
        } catch {
          NSLog("Conduit share: could not copy an item: %@", logged(error))
          finish(nil)
        }
      }
    }
    var result: ShareAddResult?
    switch answer {
    case .data(let bytes)?:
      result = try? draft.addData(bytes, name: name)
    case .file(let copy, _)?:
      result = try? draft.addFile(copying: copy, name: name)
    case nil:
      result = nil
    }
    answer?.cleanUp()
    guard result == .added, let copy = draft.manifest.files.last else { return [] }
    let staged = draft.dir.appendingPathComponent(copy.path)
    let size = (try? staged.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
    return [Row(kind: .file(staged, size ?? 0))]
  }
}

/// What a provider's callback handed over: bytes, or a private copy of its
/// file (in a folder of its own under the temporary folder).
private enum Staged {
  case data(Data)
  case file(URL, folder: URL)

  static func copy(of url: URL) throws -> Staged {
    let fm = FileManager.default
    let folder = fm.temporaryDirectory.appendingPathComponent(
      "conduit-share-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    let copy = folder.appendingPathComponent(url.lastPathComponent, isDirectory: false)
    do {
      try fm.copyItem(at: url, to: copy)
    } catch {
      try? fm.removeItem(at: folder)
      throw error
    }
    return .file(copy, folder: folder)
  }

  /// Removes the private copy, if any.
  func cleanUp() {
    if case .file(_, let folder) = self { try? FileManager.default.removeItem(at: folder) }
  }
}

// MARK: - Row views

/// A document view that lays out from the top.
private final class FlippedView: NSView {
  override var isFlipped: Bool { true }
}

/// One shared item: an icon or thumbnail, its name, and a file's size.
private final class RowView: NSStackView {
  init(row: Row, width: CGFloat) {
    super.init(frame: .zero)
    orientation = .horizontal
    spacing = 8
    edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
    translatesAutoresizingMaskIntoConstraints = false
    heightAnchor.constraint(equalToConstant: 30).isActive = true
    widthAnchor.constraint(equalToConstant: width - 4).isActive = true

    let image: NSImage?
    let title: String
    var detail: String?
    switch row.kind {
    case .file(let url, let bytes):
      image = Self.thumbnail(url) ?? NSWorkspace.shared.icon(forFile: url.path)
      title = url.lastPathComponent
      detail = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    case .link(let url):
      image = NSImage(systemSymbolName: "link", accessibilityDescription: nil)
      title = url.absoluteString
    case .text(let text):
      image = NSImage(systemSymbolName: "text.quote", accessibilityDescription: nil)
      title = text.replacingOccurrences(of: "\n", with: " ")
    }
    let icon = NSImageView(image: image ?? NSImage())
    icon.imageScaling = .scaleProportionallyUpOrDown
    icon.wantsLayer = true
    icon.layer?.cornerRadius = 3
    icon.layer?.masksToBounds = true
    icon.contentTintColor = .secondaryLabelColor
    icon.translatesAutoresizingMaskIntoConstraints = false
    icon.widthAnchor.constraint(equalToConstant: 20).isActive = true
    icon.heightAnchor.constraint(equalToConstant: 20).isActive = true
    icon.setAccessibilityElement(false)
    let label = NSTextField(labelWithString: title)
    label.lineBreakMode = .byTruncatingMiddle
    label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    label.setAccessibilityElement(false)
    label.setContentHuggingPriority(.init(1), for: .horizontal)
    distribution = .fill
    addArrangedSubview(icon)
    addArrangedSubview(label)
    if let detail {
      let size = NSTextField(labelWithString: detail)
      size.textColor = .secondaryLabelColor
      size.setContentHuggingPriority(.required, for: .horizontal)
      size.setContentCompressionResistancePriority(.required, for: .horizontal)
      size.setAccessibilityElement(false)
      addArrangedSubview(size)
    }
    setAccessibilityElement(true)
    setAccessibilityRole(.staticText)
    setAccessibilityLabel([title, detail].compactMap { $0 }.joined(separator: ", "))
  }

  required init?(coder: NSCoder) { nil }

  private static func thumbnail(_ url: URL) -> NSImage? {
    guard UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true,
      let image = NSImage(contentsOf: url), image.isValid
    else { return nil }
    return image
  }
}
