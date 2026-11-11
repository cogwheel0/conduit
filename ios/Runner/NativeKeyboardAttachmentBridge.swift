// FLUTTER HOST ONLY. Swizzles Flutter's FlutterTextInputView to attach a
// native accessory bar, so it is not a `ConduitBridge` and other
// hosts do not copy this file. The Flutter app delegate attaches it directly.

import Flutter
import ObjectiveC.runtime
import UIKit

private var nativeKeyboardAttachmentInputViewKey: UInt8 = 0

private struct NativeKeyboardAttachmentAction: Equatable {
    /// Whether the row turns an option on and off, or runs a command.
    enum Kind: Equatable {
        case toggle
        case command
    }

    let id: String
    let label: String
    let subtitle: String?
    let section: String
    /// Localized heading of the row's section, from Dart; nil shows none.
    let sectionTitle: String?
    let kind: Kind
    /// Localized on/off state of a toggle, read by VoiceOver.
    let stateLabel: String?
    let sfSymbol: String
    let enabled: Bool
    let selected: Bool
    let dismissesKeyboard: Bool

    init(_ config: PlatformKeyboardAttachmentActionConfig) {
        id = config.id
        label = config.label
        subtitle = config.subtitle
        section = config.section
        sectionTitle = config.sectionTitle
        kind = config.kind == .toggle ? .toggle : .command
        stateLabel = config.stateLabel
        sfSymbol = config.sfSymbol
        enabled = config.enabled
        selected = config.selected
        dismissesKeyboard = config.dismissesKeyboard
    }

    init?(_ payload: [String: Any]) {
        guard
            let id = payload["id"] as? String,
            !id.isEmpty,
            let label = payload["label"] as? String,
            !label.isEmpty
        else {
            return nil
        }

        self.id = id
        self.label = label
        subtitle = payload["subtitle"] as? String
        section = (payload["section"] as? String) ?? "attachments"
        sectionTitle = payload["sectionTitle"] as? String
        kind = (payload["kind"] as? String) == "toggle" ? .toggle : .command
        stateLabel = payload["stateLabel"] as? String
        sfSymbol = (payload["sfSymbol"] as? String) ?? "circle"
        enabled = payload["enabled"] as? Bool ?? true
        selected = payload["selected"] as? Bool ?? false
        dismissesKeyboard = payload["dismissesKeyboard"] as? Bool ?? true
    }

    /// Everything that shapes how the row is laid out. When only the rest (a
    /// toggle's state) changes, the panel updates the row in place, so its
    /// switch slides instead of the panel being rebuilt under the finger.
    var layoutIdentity: [String] {
        [
            id,
            label,
            subtitle ?? "",
            section,
            sectionTitle ?? "",
            kind == .toggle ? "toggle" : "command",
            sfSymbol,
            enabled ? "enabled" : "disabled",
            dismissesKeyboard ? "dismisses" : "stays",
        ]
    }
}

/// Presents the chat attachment picker as a native iOS keyboard replacement.
///
/// This mirrors the archived native composer approach: the Flutter text input
/// remains first responder while its `inputView` is temporarily replaced by a
/// native attachment surface.
final class NativeKeyboardAttachmentBridge: NativeKeyboardAttachmentHostApi {
    static let shared = NativeKeyboardAttachmentBridge()

    private static var didSwizzleInputView = false

    private var flutterApi: NativeKeyboardAttachmentFlutterApi?
    private weak var capturedFirstResponder: UIResponder?
    private weak var activeResponder: UIResponder?
    private var actions: [NativeKeyboardAttachmentAction] = []
    private var shouldPresentOnNextFocus = false
    private var cachedKeyboardHeight = NativeKeyboardAttachmentInputView.defaultHeight
    private lazy var attachmentInputView = NativeKeyboardAttachmentInputView {
        [weak self] action in
        self?.handleAction(action)
    }

    private init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleKeyboardFrameChange(_:)),
            name: UIResponder.keyboardDidChangeFrameNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleKeyboardDidHide(_:)),
            name: UIResponder.keyboardDidHideNotification,
            object: nil
        )
    }

    func configure(messenger: FlutterBinaryMessenger) {
        flutterApi = NativeKeyboardAttachmentFlutterApi(binaryMessenger: messenger)
        NativeKeyboardAttachmentHostApiSetup.setUp(
            binaryMessenger: messenger,
            api: self
        )
    }

    fileprivate func capture(firstResponder: UIResponder) {
        capturedFirstResponder = firstResponder
    }

    func configure(config: PlatformKeyboardAttachmentConfig) throws {
        if Thread.isMainThread {
            updateConfiguration(from: config)
            return
        }

        DispatchQueue.main.sync { [weak self] in
            self?.updateConfiguration(from: config)
        }
    }

    func toggle(config: PlatformKeyboardAttachmentConfig) throws -> Bool {
        if Thread.isMainThread {
            return toggleOnMainThread(config: config)
        }

        var didShow = false
        DispatchQueue.main.sync { [weak self] in
            didShow = self?.toggleOnMainThread(config: config) ?? false
        }
        return didShow
    }

    func hide() throws {
        if Thread.isMainThread {
            hideAttachmentView()
            return
        }

        DispatchQueue.main.sync { [weak self] in
            self?.hideAttachmentView()
        }
    }

    private func toggleOnMainThread(
        config: PlatformKeyboardAttachmentConfig
    ) -> Bool {
        if isPresented {
            hideAttachmentView()
            return true
        }
        updateConfiguration(from: config)
        return show()
    }

    private func updateConfiguration(
        from config: PlatformKeyboardAttachmentConfig
    ) {
        let parsedActions = config.actions.map(NativeKeyboardAttachmentAction.init)
        guard parsedActions != actions else {
            return
        }
        actions = parsedActions
        if isPresented {
            attachmentInputView.update(actions: parsedActions)
        }
    }

    private func updateConfiguration(from arguments: Any?) {
        guard let payload = arguments as? [String: Any] else {
            return
        }

        if let rawActions = payload["actions"] as? [[String: Any]] {
            let parsedActions: [NativeKeyboardAttachmentAction] = rawActions.compactMap(
                NativeKeyboardAttachmentAction.init
            )
            guard parsedActions != actions else {
                return
            }
            actions = parsedActions
            if isPresented {
                attachmentInputView.update(actions: parsedActions)
            }
        }
    }

    private func show() -> Bool {
        guard Self.installInputViewSwizzleIfNeeded() else {
            return false
        }

        if let responder = currentFirstResponder(),
           responder.isConduitFlutterTextInputView {
            activateAttachmentInputView(
                for: responder,
                reloadInputViews: true
            )
            return true
        }

        shouldPresentOnNextFocus = true
        return true
    }

    /// Replaces the Flutter responder's keyboard, using its app window to
    /// bound the panel's height independently of the keyboard hosting window.
    private func activateAttachmentInputView(
        for responder: UIResponder,
        reloadInputViews: Bool
    ) {
        shouldPresentOnNextFocus = false
        attachmentInputView.update(actions: actions)
        attachmentInputView.updatePreferredHeight(
            measuredKeyboardHeight(for: responder),
            in: (responder as? UIView)?.window ?? keyWindow
        )

        objc_setAssociatedObject(
            responder,
            &nativeKeyboardAttachmentInputViewKey,
            attachmentInputView,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
        activeResponder = responder
        if reloadInputViews {
            responder.reloadInputViews()
        }
        sendVisibilityChanged(true)
    }

    fileprivate func preparedInputView(for responder: UIResponder) -> UIView? {
        guard shouldPresentOnNextFocus,
              responder.isConduitFlutterTextInputView
        else {
            return nil
        }

        activateAttachmentInputView(
            for: responder,
            reloadInputViews: false
        )
        return attachmentInputView
    }

    private func hideAttachmentView() {
        shouldPresentOnNextFocus = false
        guard let responder = activeResponder else {
            sendVisibilityChanged(false)
            return
        }

        objc_setAssociatedObject(
            responder,
            &nativeKeyboardAttachmentInputViewKey,
            nil,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
        if responder.isFirstResponder {
            responder.reloadInputViews()
        }
        activeResponder = nil
        sendVisibilityChanged(false)
    }

    private var isPresented: Bool {
        guard let responder = activeResponder else {
            return false
        }
        return objc_getAssociatedObject(
            responder,
            &nativeKeyboardAttachmentInputViewKey
        ) != nil
    }

    private func handleAction(_ action: NativeKeyboardAttachmentAction) {
        guard action.enabled else { return }

        UIImpactFeedbackGenerator(style: .light).impactOccurred()

        if action.dismissesKeyboard {
            hideAttachmentView()
        }

        flutterApi?.onAction(
            event: PlatformKeyboardAttachmentActionEvent(id: action.id)
        ) { _ in }
    }

    private func sendVisibilityChanged(_ isVisible: Bool) {
        flutterApi?.onVisibilityChanged(
            event: PlatformKeyboardAttachmentVisibilityEvent(visible: isVisible)
        ) { _ in }
    }

    private func currentFirstResponder() -> UIResponder? {
        capturedFirstResponder = nil
        UIApplication.shared.sendAction(
            #selector(UIResponder.conduit_captureKeyboardAttachmentFirstResponder(_:)),
            to: nil,
            from: nil,
            for: nil
        )
        return capturedFirstResponder
    }

    /// Measures the keyboard in the responder's window, retaining the last
    /// usable height when focus arrives before a keyboard frame is available.
    private func measuredKeyboardHeight(for responder: UIResponder) -> CGFloat {
        guard #available(iOS 15.0, *) else {
            return cachedKeyboardHeight
        }

        let measurementView: UIView? = if let view = responder as? UIView {
            view.window ?? view
        } else {
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
                .first { $0.isKeyWindow }
        }

        let height = measurementView?.keyboardLayoutGuide.layoutFrame.height ?? 0
        if height > NativeKeyboardAttachmentInputView.minimumHeight {
            cachedKeyboardHeight = height
        }
        return cachedKeyboardHeight
    }

    /// Caches system keyboard heights without feeding the attachment panel's
    /// own frame notifications back into its self-sizing height constraint.
    @objc
    private func handleKeyboardFrameChange(_ notification: Notification) {
        guard !isPresented else {
            attachmentInputView.setNeedsLayout()
            return
        }

        guard let frameValue = notification.userInfo?[
            UIResponder.keyboardFrameEndUserInfoKey
        ] as? NSValue else {
            return
        }

        let screenFrame = frameValue.cgRectValue
        let window = activeResponderView?.window ?? keyWindow
        let convertedFrame = window?.convert(screenFrame, from: nil) ?? screenFrame
        let windowHeight = window?.bounds.height ?? UIScreen.main.bounds.height
        let visibleHeight = max(0, windowHeight - convertedFrame.minY)

        guard visibleHeight > NativeKeyboardAttachmentInputView.minimumHeight,
              visibleHeight != cachedKeyboardHeight
        else {
            return
        }

        cachedKeyboardHeight = visibleHeight
        attachmentInputView.updatePreferredHeight(visibleHeight, in: window)
    }

    /// Tap-outside (or other system) dismissal can hide the keyboard without
    /// Flutter invoking `hide`; sync native state and notify Dart so the UI
    /// does not keep showing the dismiss (X) control.
    @objc
    private func handleKeyboardDidHide(_: Notification) {
        guard isPresented else { return }
        hideAttachmentView()
    }

    private var activeResponderView: UIView? {
        activeResponder as? UIView
    }

    private var keyWindow: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
    }

    private static func installInputViewSwizzleIfNeeded() -> Bool {
        if didSwizzleInputView {
            return true
        }

        guard let targetClass = NSClassFromString("FlutterTextInputView") else {
            return false
        }

        let originalSelector = #selector(getter: UIResponder.inputView)
        let replacementSelector = #selector(
            getter: UIResponder.conduit_keyboardAttachmentInputView
        )

        guard let replacementMethod = class_getInstanceMethod(
                UIResponder.self,
                replacementSelector
            )
        else {
            return false
        }

        // FlutterTextInputView inherits UIResponder's default `inputView`.
        // Installing an override is safer than method_exchangeImplementations:
        // exchanging an inherited UIResponder method can mutate the superclass
        // implementation and make the fallback recursively call itself.
        class_replaceMethod(
            targetClass,
            originalSelector,
            method_getImplementation(replacementMethod),
            method_getTypeEncoding(replacementMethod)
        )

        didSwizzleInputView = true
        return true
    }
}

private final class NativeKeyboardAttachmentInputView: UIInputView {
    static let defaultHeight: CGFloat = 300
    static let minimumHeight: CGFloat = 170
    private static let panelCornerRadius: CGFloat = 26
    /// The last row's own 8 pt padding plus this sits just above the home
    /// indicator's inset, so the panel ends with its content.
    private static let bottomContentInset: CGFloat = 6

    private let onSelect: (NativeKeyboardAttachmentAction) -> Void
    private var currentActions: [NativeKeyboardAttachmentAction] = []
    /// The rows on screen, by action id, for in-place state updates.
    private var tilesByID: [String: NativeKeyboardAttachmentTile] = [:]
    /// The width the tile grid's columns were chosen for.
    private var gridWidth: CGFloat = 0
    private let scrollView = UIScrollView()
    private let stackView = UIStackView()
    private var preferredHeight = defaultHeight
    private weak var sizingWindow: UIWindow?
    private lazy var heightConstraint = heightAnchor.constraint(
        equalToConstant: Self.defaultHeight
    )
    private lazy var stackTopConstraint = stackView.topAnchor.constraint(
        equalTo: scrollView.contentLayoutGuide.topAnchor,
        constant: topContentInset
    )

    private var topContentInset: CGFloat {
        guard #available(iOS 26.0, *) else {
            return 14
        }
        return traitCollection.verticalSizeClass == .compact ? 14 : 20
    }

    private var horizontalContentInset: CGFloat {
        if #available(iOS 26.0, *) {
            return 20
        }
        return 16
    }

    /// Builds the scrollable attachment surface and routes tile selections to
    /// the supplied handler.
    init(onSelect: @escaping (NativeKeyboardAttachmentAction) -> Void) {
        self.onSelect = onSelect
        super.init(frame: .zero, inputViewStyle: .keyboard)

        // Let Auto Layout honor `heightConstraint`. Without self-sizing, UIKit
        // sizes a custom input view to the bare key plane, which leaves the
        // panel shorter than the keyboard it replaces (no predictive bar or
        // dictation strip) and drops the composer when the panel opens.
        allowsSelfSizing = true
        backgroundColor = if #available(iOS 26.0, *) {
            .clear
        } else {
            .systemBackground
        }
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        clipsToBounds = true
        layer.cornerRadius = Self.panelCornerRadius
        layer.cornerCurve = .continuous
        layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]

        heightConstraint.priority = .required
        heightConstraint.isActive = true

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = true
        scrollView.showsVerticalScrollIndicator = false
        scrollView.keyboardDismissMode = .none
        scrollView.contentInsetAdjustmentBehavior = .never

        stackView.axis = .vertical
        stackView.spacing = 12
        stackView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(scrollView)
        scrollView.addSubview(stackView)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            stackView.leadingAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.leadingAnchor,
                constant: horizontalContentInset
            ),
            stackView.trailingAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.trailingAnchor,
                constant: -horizontalContentInset
            ),
            stackTopConstraint,
            stackView.bottomAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.bottomAnchor,
                constant: -Self.bottomContentInset
            ),
            stackView.widthAnchor.constraint(
                equalTo: scrollView.frameLayoutGuide.widthAnchor,
                constant: -2 * horizontalContentInset
            ),
        ])
    }

    /// Requires a selection handler, so storyboard decoding is unsupported.
    required init?(coder: NSCoder) {
        nil
    }

    /// Sizes the panel to its content, never taller than the keyboard it
    /// replaces nor half the window (so the composer keeps its space on
    /// rotation), and never shorter than `minimumHeight`. A panel with a single
    /// tool row no longer leaves most of a keyboard's height empty.
    override func layoutSubviews() {
        // Rotation or a resized window changes how many tiles fit a row.
        if !currentActions.isEmpty, abs(currentPanelWidth - gridWidth) > 1 {
            update(actions: currentActions)
        }
        if let window = sizingWindow ?? self.window, window.bounds.height > 0 {
            let bottomInset = window.safeAreaInsets.bottom
            if scrollView.contentInset.bottom != bottomInset {
                scrollView.contentInset.bottom = bottomInset
            }
            let width = bounds.width > 0 ? bounds.width : window.bounds.width
            let ceiling = min(preferredHeight, window.bounds.height / 2)
            let fitted = fittedHeight(forWidth: width, bottomInset: bottomInset)
            let height = min(ceiling, max(fitted, Self.minimumHeight))
            if heightConstraint.constant != height {
                heightConstraint.constant = height
                invalidateIntrinsicContentSize()
            }
            scrollView.alwaysBounceVertical = fitted > height + 0.5
        }
        super.layoutSubviews()
    }

    /// The height that shows every section without scrolling.
    private func fittedHeight(forWidth width: CGFloat, bottomInset: CGFloat) -> CGFloat {
        let contentWidth = max(0, width - 2 * horizontalContentInset)
        let stackHeight = stackView.systemLayoutSizeFitting(
            CGSize(width: contentWidth, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height
        return ceil(topContentInset + stackHeight + Self.bottomContentInset + bottomInset)
    }

    /// Adjusts content padding when the vertical layout becomes compact or regular.
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard
            previousTraitCollection?.verticalSizeClass != traitCollection.verticalSizeClass
        else {
            return
        }
        stackTopConstraint.constant = topContentInset
    }

    /// Rebuilds the ordered attachment, feature, and tool sections from the
    /// latest Flutter configuration.
    func update(actions: [NativeKeyboardAttachmentAction]) {
        if canUpdateInPlace(to: actions) {
            currentActions = actions
            for action in actions {
                tilesByID[action.id]?.apply(action, animated: window != nil)
            }
            return
        }

        currentActions = actions
        gridWidth = currentPanelWidth
        tilesByID = [:]
        stackView.arrangedSubviews.forEach { view in
            stackView.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        var attachmentGrid: UIView?

        let grouped = Dictionary(grouping: actions, by: \.section)
        // List rows centre their symbol on the first tile's, so the rows'
        // symbols stand in the grid's first column.
        let listIconCenter = grouped["attachments"].map { attachments in
            firstAttachmentTileCenter(count: attachments.count)
        }
        let preferredOrder = ["attachments", "features", "tools"]
        let sectionKeys = preferredOrder.filter { grouped[$0] != nil }
            + grouped.keys
                .filter { !preferredOrder.contains($0) }
                .sorted()

        for key in sectionKeys {
            guard let sectionActions = grouped[key], !sectionActions.isEmpty else {
                continue
            }

            if let title = sectionActions.first?.sectionTitle, !title.isEmpty {
                addSectionTitle(title)
            }
            if key == "attachments" {
                attachmentGrid = addAttachmentGrid(sectionActions)
            } else {
                addListSection(sectionActions, iconCenter: listIconCenter)
            }
        }

        if let grid = attachmentGrid {
            stackView.setCustomSpacing(14, after: grid)
        }
        setNeedsLayout()
    }

    /// Whether [actions] differ from the rows on screen only in state, so the
    /// rows can be updated where they are.
    private func canUpdateInPlace(to actions: [NativeKeyboardAttachmentAction]) -> Bool {
        guard !tilesByID.isEmpty,
              abs(currentPanelWidth - gridWidth) <= 1,
              actions.count == currentActions.count
        else {
            return false
        }
        return actions.map(\.layoutIdentity) == currentActions.map(\.layoutIdentity)
    }

    /// Preserves the measured keyboard height independently of the panel's
    /// current bounds so repeated frame changes cannot compound its size.
    func updatePreferredHeight(_ height: CGFloat, in window: UIWindow?) {
        guard height > Self.minimumHeight else { return }
        preferredHeight = height
        sizingWindow = window
        heightConstraint.constant = height
        setNeedsLayout()
    }

    /// Adds a caption heading before a tool section.
    private func addSectionTitle(_ title: String) {
        let label = UILabel()
        label.text = title
        label.font = UIFont.systemFont(
            ofSize: UIFont.preferredFont(forTextStyle: .caption1).pointSize,
            weight: .semibold
        )
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .tertiaryLabel
        label.numberOfLines = 0
        label.accessibilityTraits = .header
        label.setContentHuggingPriority(.required, for: .vertical)
        stackView.addArrangedSubview(label)
        stackView.setCustomSpacing(2, after: label)
    }

    /// The panel's width, or its window's before the first layout.
    private var currentPanelWidth: CGFloat {
        if bounds.width > 0 { return bounds.width }
        let window = sizingWindow ?? self.window
        return window?.bounds.width ?? UIScreen.main.bounds.width
    }

    /// Attach tiles: a flat rounded key holding the icon, its name below.
    /// Tall enough to hold a 22 pt symbol with the key's air around it.
    private var attachmentTileHeight: CGFloat {
        traitCollection.verticalSizeClass == .compact ? 48 : 56
    }

    private static let attachmentTileSpacing: CGFloat = 8

    /// How far a key's name may reach past the key into the gap beside it.
    static let labelOutset: CGFloat = attachmentTileSpacing / 2
    private static let attachmentTileMinimumWidth: CGFloat = 62

    /// How many tiles each row holds: every tile fits the width (no tile cut
    /// off at the edge), and rows are balanced, so five tiles that cannot sit
    /// in one row split three and two rather than four and one.
    static func attachmentGridRows(
        count: Int,
        availableWidth: CGFloat,
        spacing: CGFloat = attachmentTileSpacing,
        minimumTileWidth: CGFloat = attachmentTileMinimumWidth
    ) -> [Int] {
        guard count > 0 else { return [] }
        let fitting = Int((availableWidth + spacing) / (minimumTileWidth + spacing))
        let maxColumns = max(1, fitting)
        let rowCount = Int(ceil(Double(count) / Double(maxColumns)))
        let columns = Int(ceil(Double(count) / Double(rowCount)))
        var rows: [Int] = []
        var remaining = count
        while remaining > 0 {
            let take = min(columns, remaining)
            rows.append(take)
            remaining -= take
        }
        return rows
    }

    /// How far the first attachment tile's centre is from the content's
    /// leading edge, for a grid of [count] tiles at the current width.
    private func firstAttachmentTileCenter(count: Int) -> CGFloat {
        let available = currentPanelWidth - 2 * horizontalContentInset
        let columns = CGFloat(
            Self.attachmentGridRows(count: count, availableWidth: available).first ?? 1
        )
        let spacing = Self.attachmentTileSpacing
        let tileWidth = (available - (columns - 1) * spacing) / max(columns, 1)
        return tileWidth / 2
    }

    /// Adds the attachment tiles as a grid of equal-width columns.
    @discardableResult
    private func addAttachmentGrid(_ actions: [NativeKeyboardAttachmentAction]) -> UIView {
        let grid = UIStackView()
        grid.axis = .vertical
        grid.spacing = Self.attachmentTileSpacing
        grid.alignment = .fill

        let rows = Self.attachmentGridRows(
            count: actions.count,
            availableWidth: currentPanelWidth - 2 * horizontalContentInset
        )
        let columns = rows.first ?? 0

        var index = 0
        for rowCount in rows {
            let row = UIStackView()
            row.axis = .horizontal
            row.spacing = Self.attachmentTileSpacing
            row.distribution = .fillEqually
            // A name that wraps to two lines makes only its own tile taller.
            row.alignment = .top
            for action in actions[index..<(index + rowCount)] {
                let button = NativeKeyboardAttachmentTile(
                    action: action,
                    style: .grid(keyHeight: attachmentTileHeight)
                )
                button.addAction(UIAction { [weak self] _ in
                    self?.onSelect(action)
                }, for: .touchUpInside)
                tilesByID[action.id] = button
                row.addArrangedSubview(button)
            }
            // A shorter last row keeps the columns of the rows above it.
            for _ in rowCount..<columns {
                let spacer = UIView()
                spacer.isAccessibilityElement = false
                row.addArrangedSubview(spacer)
            }
            index += rowCount
            grid.addArrangedSubview(row)
        }

        stackView.addArrangedSubview(grid)
        return grid
    }

    /// Adds the feature and tool rows with their current selection state.
    /// With [iconCenter], each row's symbol is centred that far from the
    /// content's leading edge.
    private func addListSection(
        _ actions: [NativeKeyboardAttachmentAction],
        iconCenter: CGFloat?
    ) {
        let sectionStack = UIStackView()
        sectionStack.axis = .vertical
        sectionStack.spacing = 0

        actions.forEach { action in
            let button = NativeKeyboardAttachmentTile(
                action: action,
                style: .list(iconCenter: iconCenter)
            )
            button.addAction(UIAction { [weak self, weak button] _ in
                // The switch answers the finger at once; the state Flutter
                // sends back then confirms it (or puts it back if refused).
                button?.flipToggleOptimistically()
                self?.onSelect(action)
            }, for: .touchUpInside)
            tilesByID[action.id] = button
            sectionStack.addArrangedSubview(button)
        }

        stackView.addArrangedSubview(sectionStack)
    }
}

private final class NativeKeyboardAttachmentTile: UIControl {
    enum Style {
        /// A flat key holding the icon, with the name beneath it, so a long
        /// name never crowds the key's edges.
        case grid(keyHeight: CGFloat)
        /// A menu row: symbol, title and subtitle, and a switch for an
        /// option or a chevron for a command. With `iconCenter`, the symbol
        /// is centred that far from the row's leading edge (on the first
        /// attach tile's centre); without, it starts on the edge.
        case list(iconCenter: CGFloat?)
    }

    private var action: NativeKeyboardAttachmentAction
    private let style: Style
    private weak var listTitleLabel: UILabel?
    private weak var highlightView: UIView?
    private weak var toggleSwitch: UISwitch?

    init(action: NativeKeyboardAttachmentAction, style: Style) {
        self.action = action
        self.style = style
        super.init(frame: .zero)

        isEnabled = action.enabled
        alpha = action.enabled ? 1 : 0.48
        backgroundColor = .clear

        switch style {
        case let .grid(keyHeight):
            buildGridContent(keyHeight: keyHeight)
        case let .list(iconCenter):
            buildListContent(iconCenter: iconCenter)
        }
    }

    required init?(coder: NSCoder) {
        nil
    }

    /// Takes a new state for the same row: a toggle's switch slides to it.
    func apply(_ newAction: NativeKeyboardAttachmentAction, animated: Bool) {
        action = newAction
        guard let toggleSwitch else { return }
        if toggleSwitch.isOn != newAction.selected {
            toggleSwitch.setOn(newAction.selected, animated: animated)
        }
        updateListAccessibility()
    }

    /// Slides a toggle's switch as soon as the row is tapped, before Flutter
    /// confirms the new state. A refused change sends no new state, so if
    /// none has arrived shortly after, the switch slides back to the last
    /// state Flutter reported.
    func flipToggleOptimistically() {
        guard let toggleSwitch, action.enabled else { return }
        toggleSwitch.setOn(!toggleSwitch.isOn, animated: true)

        pendingReconcile?.cancel()
        let reconcile = DispatchWorkItem { [weak self] in
            guard let self, let toggleSwitch = self.toggleSwitch else { return }
            if toggleSwitch.isOn != self.action.selected {
                toggleSwitch.setOn(self.action.selected, animated: true)
            }
        }
        pendingReconcile = reconcile
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.reconcileDelay,
            execute: reconcile
        )
    }

    private var pendingReconcile: DispatchWorkItem?
    private static let reconcileDelay: TimeInterval = 1.0

    deinit {
        pendingReconcile?.cancel()
    }

    /// Titles get a second line at accessibility text sizes; keys take the
    /// shadow of the new appearance.
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle {
            updateKeyShadow()
        }
        guard previousTraitCollection?.preferredContentSizeCategory
            != traitCollection.preferredContentSizeCategory
        else {
            return
        }
        listTitleLabel?.numberOfLines = listTitleLineCount
    }

    private var listTitleLineCount: Int {
        traitCollection.preferredContentSizeCategory.isAccessibilityCategory ? 2 : 1
    }

    /// The pressed shade lands with the finger and eases away on release.
    override var isHighlighted: Bool {
        didSet {
            guard oldValue != isHighlighted else { return }
            let target: CGFloat = isHighlighted ? 1 : 0
            if isHighlighted {
                highlightView?.alpha = target
            } else {
                UIView.animate(
                    withDuration: 0.2,
                    delay: 0,
                    options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseOut]
                ) {
                    self.highlightView?.alpha = target
                }
            }
        }
    }

    private var foreground: UIColor {
        action.enabled ? .label : .tertiaryLabel
    }

    /// A key on the panel, in the manner of the keyboard it replaces: solid
    /// white in light mode, as the keyboard's letter keys are, and a lifted
    /// grey in dark, with no glass of its own (the panel is already the
    /// glass). At the size of these keys a translucent white sank into the
    /// light panel, so light keys are opaque and sit on a soft shadow.
    private static let keyFill = UIColor { traits in
        if #unavailable(iOS 26.0) {
            return .tertiarySystemFill
        }
        return traits.userInterfaceStyle == .dark
            ? UIColor(white: 1, alpha: 0.18)
            : .white
    }

    /// The light key's shadow: a one-point drop with a little blur, enough
    /// to lift a white key off the light panel. Dark keys carry none, as the
    /// dark keyboard's do; their fill already stands off the panel.
    private static let keyShadowOpacity: Float = 0.12
    private static let keyShadowRadius: CGFloat = 1.5
    private static let keyShadowOffset = CGSize(width: 0, height: 1)
    private static let keyCornerRadius: CGFloat = 14

    private weak var keyView: UIView?

    private func updateKeyShadow() {
        guard let key = keyView else { return }
        let lifted: Bool
        if #available(iOS 26.0, *) {
            lifted = traitCollection.userInterfaceStyle != .dark
        } else {
            lifted = false
        }
        key.layer.shadowColor = UIColor.black.cgColor
        key.layer.shadowOpacity = lifted ? Self.keyShadowOpacity : 0
        key.layer.shadowRadius = Self.keyShadowRadius
        key.layer.shadowOffset = Self.keyShadowOffset
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if let key = keyView, key.bounds.width > 0 {
            key.layer.shadowPath = UIBezierPath(
                roundedRect: key.bounds,
                cornerRadius: Self.keyCornerRadius
            ).cgPath
        }
    }

    /// Laid over a key or row while it is pressed.
    private static let pressedShade = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(white: 1, alpha: 0.12)
            : UIColor(white: 0, alpha: 0.08)
    }

    private func buildGridContent(keyHeight: CGFloat) {
        let key = UIView()
        key.translatesAutoresizingMaskIntoConstraints = false
        key.isUserInteractionEnabled = false
        key.backgroundColor = Self.keyFill
        key.layer.cornerRadius = Self.keyCornerRadius
        key.layer.cornerCurve = .continuous
        // Not clipped, so the key's shadow shows; the pressed shade takes
        // the key's corners itself.
        addSubview(key)
        keyView = key
        updateKeyShadow()

        let highlight = UIView()
        highlight.translatesAutoresizingMaskIntoConstraints = false
        highlight.isUserInteractionEnabled = false
        highlight.backgroundColor = Self.pressedShade
        highlight.layer.cornerRadius = Self.keyCornerRadius
        highlight.layer.cornerCurve = .continuous
        highlight.alpha = 0
        key.addSubview(highlight)
        highlightView = highlight

        let icon = UIImageView(image: UIImage(systemName: action.sfSymbol))
        icon.translatesAutoresizingMaskIntoConstraints = false
        // Title 2 (22 pt, following Dynamic Type): the glyph should hold its
        // key the way a keyboard key's letter does, not float small in it.
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(
            textStyle: .title2,
            scale: .medium
        )
        icon.tintColor = foreground
        icon.contentMode = .scaleAspectFit
        key.addSubview(icon)

        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = action.label
        label.font = UIFont.systemFont(
            ofSize: UIFont.preferredFont(forTextStyle: .caption1).pointSize,
            weight: .medium
        )
        label.adjustsFontForContentSizeCategory = true
        label.textColor = foreground
        label.textAlignment = .center
        // A long localized name ("Fichiers du serveur") wraps rather than
        // truncates, so every key can share one column width.
        label.numberOfLines = 2
        label.lineBreakMode = .byWordWrapping
        label.allowsDefaultTighteningForTruncation = true
        addSubview(label)

        isAccessibilityElement = true
        accessibilityLabel = action.label
        accessibilityTraits = .button

        // The name may use half of the gap to each neighbour, so a two-word
        // name like "Server Files" still fits on one line.
        let labelOutset = NativeKeyboardAttachmentInputView.labelOutset
        NSLayoutConstraint.activate([
            key.leadingAnchor.constraint(equalTo: leadingAnchor),
            key.trailingAnchor.constraint(equalTo: trailingAnchor),
            key.topAnchor.constraint(equalTo: topAnchor),
            key.heightAnchor.constraint(equalToConstant: keyHeight),
            highlight.leadingAnchor.constraint(equalTo: key.leadingAnchor),
            highlight.trailingAnchor.constraint(equalTo: key.trailingAnchor),
            highlight.topAnchor.constraint(equalTo: key.topAnchor),
            highlight.bottomAnchor.constraint(equalTo: key.bottomAnchor),
            icon.centerXAnchor.constraint(equalTo: key.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: key.centerYAnchor),
            label.topAnchor.constraint(equalTo: key.bottomAnchor, constant: 6),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: -labelOutset),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: labelOutset),
            label.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    /// A flat menu row: plain symbol, regular-weight title, and a trailing
    /// switch on an option, or a chevron on a command that opens something.
    /// With [iconCenter], the symbol column reaches that far plus half the
    /// symbol's width, so the symbol's centre lands on the first tile's.
    private func buildListContent(iconCenter: CGFloat?) {
        let highlight = UIView()
        highlight.translatesAutoresizingMaskIntoConstraints = false
        highlight.isUserInteractionEnabled = false
        highlight.backgroundColor = Self.pressedShade
        highlight.layer.cornerRadius = 12
        highlight.layer.cornerCurve = .continuous
        highlight.alpha = 0
        addSubview(highlight)
        highlightView = highlight

        let icon = UIImageView(image: UIImage(systemName: action.sfSymbol))
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(
            textStyle: .subheadline,
            scale: .large
        )
        icon.tintColor = foreground
        icon.contentMode = .scaleAspectFit
        icon.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = UILabel()
        titleLabel.text = action.label
        titleLabel.font = .preferredFont(forTextStyle: .subheadline)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = foreground
        titleLabel.numberOfLines = listTitleLineCount
        listTitleLabel = titleLabel

        let subtitleLabel = UILabel()
        subtitleLabel.text = action.subtitle
        subtitleLabel.font = .preferredFont(forTextStyle: .caption1)
        subtitleLabel.adjustsFontForContentSizeCategory = true
        subtitleLabel.textColor = .secondaryLabel
        // A row that can't be used explains why in full; others get two lines.
        subtitleLabel.numberOfLines = action.enabled ? 2 : 0
        subtitleLabel.isHidden = (action.subtitle ?? "").isEmpty

        let textStack = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
        textStack.axis = .vertical
        textStack.spacing = 1

        let accessory: UIView
        if action.kind == .toggle {
            // The same switch as Settings, so an option shows whether it is
            // on before it is tapped. The row takes the tap; the switch
            // only shows the state.
            let toggle = UISwitch()
            toggle.isOn = action.selected
            toggle.isEnabled = action.enabled
            toggle.isUserInteractionEnabled = false
            toggle.isAccessibilityElement = false
            toggle.setContentHuggingPriority(.required, for: .horizontal)
            toggle.setContentCompressionResistancePriority(.required, for: .horizontal)
            toggleSwitch = toggle
            accessory = toggle
        } else {
            let chevron = UIImageView(image: UIImage(systemName: "chevron.right"))
            chevron.preferredSymbolConfiguration = UIImage.SymbolConfiguration(
                textStyle: .footnote,
                scale: .medium
            )
            chevron.tintColor = .tertiaryLabel
            chevron.contentMode = .scaleAspectFit
            chevron.translatesAutoresizingMaskIntoConstraints = false
            chevron.widthAnchor.constraint(equalToConstant: 20).isActive = true
            accessory = chevron
        }

        let iconColumn = UIView()
        iconColumn.translatesAutoresizingMaskIntoConstraints = false
        iconColumn.isUserInteractionEnabled = false
        iconColumn.addSubview(icon)
        let iconWidth = Self.listIconWidth
        let center = max(iconCenter ?? iconWidth / 2, iconWidth / 2)
        NSLayoutConstraint.activate([
            iconColumn.widthAnchor.constraint(equalToConstant: center + iconWidth / 2),
            icon.centerXAnchor.constraint(equalTo: iconColumn.leadingAnchor, constant: center),
            icon.centerYAnchor.constraint(equalTo: iconColumn.centerYAnchor),
            icon.topAnchor.constraint(greaterThanOrEqualTo: iconColumn.topAnchor),
            icon.bottomAnchor.constraint(lessThanOrEqualTo: iconColumn.bottomAnchor),
        ])

        let row = UIStackView(arrangedSubviews: [iconColumn, textStack, accessory])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 12
        row.setCustomSpacing(16, after: textStack)
        row.isUserInteractionEnabled = false
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        isAccessibilityElement = true
        accessibilityLabel = action.label
        accessibilityHint = action.subtitle
        updateListAccessibility()

        NSLayoutConstraint.activate([
            highlight.leadingAnchor.constraint(equalTo: leadingAnchor, constant: -8),
            highlight.trailingAnchor.constraint(equalTo: trailingAnchor, constant: 8),
            highlight.topAnchor.constraint(equalTo: topAnchor),
            highlight.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            icon.widthAnchor.constraint(equalToConstant: Self.listIconWidth),
            iconColumn.heightAnchor.constraint(equalTo: row.heightAnchor),
        ])
    }

    /// The box a list row's symbol is centred in.
    private static let listIconWidth: CGFloat = 22

    /// A toggle reads its on/off state as its value; without a state label, a
    /// selected option at least reads as selected.
    private func updateListAccessibility() {
        guard case .list = style else { return }
        if action.kind == .toggle, let state = action.stateLabel, !state.isEmpty {
            accessibilityValue = state
            accessibilityTraits = .button
        } else {
            accessibilityValue = nil
            accessibilityTraits = action.selected ? [.button, .selected] : .button
        }
    }
}

private extension UIResponder {
    var isConduitFlutterTextInputView: Bool {
        var currentClass: AnyClass? = type(of: self)
        while let candidate = currentClass {
            if NSStringFromClass(candidate).contains("FlutterTextInputView") {
                return true
            }
            currentClass = class_getSuperclass(candidate)
        }
        return false
    }

    @objc func conduit_captureKeyboardAttachmentFirstResponder(_ sender: Any?) {
        NativeKeyboardAttachmentBridge.shared.capture(firstResponder: self)
    }

    @objc var conduit_keyboardAttachmentInputView: UIView? {
        if let inputView = objc_getAssociatedObject(
            self,
            &nativeKeyboardAttachmentInputViewKey
        ) as? UIView {
            return inputView
        }

        return NativeKeyboardAttachmentBridge.shared.preparedInputView(for: self)
    }
}
