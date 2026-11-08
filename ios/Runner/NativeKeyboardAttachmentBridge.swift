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
    private static let bottomContentInset: CGFloat = 16

    private let onSelect: (NativeKeyboardAttachmentAction) -> Void
    private var currentActions: [NativeKeyboardAttachmentAction] = []
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
        currentActions = actions
        gridWidth = currentPanelWidth
        stackView.arrangedSubviews.forEach { view in
            stackView.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        var attachmentGrid: UIView?

        let grouped = Dictionary(grouping: actions, by: \.section)
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
                addListSection(sectionActions)
            }
        }

        if let grid = attachmentGrid {
            stackView.setCustomSpacing(10, after: grid)
        }
        setNeedsLayout()
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

    /// Attach tiles: a filled rounded rectangle holding icon and label.
    private var attachmentTileHeight: CGFloat {
        traitCollection.verticalSizeClass == .compact ? 56 : 64
    }

    private static let attachmentTileSpacing: CGFloat = 8
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
            row.alignment = .fill
            for action in actions[index..<(index + rowCount)] {
                let button = NativeKeyboardAttachmentTile(action: action, style: .grid)
                button.addAction(UIAction { [weak self] _ in
                    self?.onSelect(action)
                }, for: .touchUpInside)
                let preferredHeight = button.heightAnchor.constraint(
                    equalToConstant: attachmentTileHeight
                )
                preferredHeight.priority = .defaultLow - 1
                NSLayoutConstraint.activate([
                    preferredHeight,
                    button.heightAnchor.constraint(
                        greaterThanOrEqualToConstant: attachmentTileHeight
                    ),
                ])
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
    private func addListSection(_ actions: [NativeKeyboardAttachmentAction]) {
        let sectionStack = UIStackView()
        sectionStack.axis = .vertical
        sectionStack.spacing = 0

        actions.forEach { action in
            let button = NativeKeyboardAttachmentTile(action: action, style: .list)
            button.addAction(UIAction { [weak self] _ in
                self?.onSelect(action)
            }, for: .touchUpInside)
            sectionStack.addArrangedSubview(button)
        }

        stackView.addArrangedSubview(sectionStack)
    }
}

private final class NativeKeyboardAttachmentTile: UIControl {
    enum Style {
        case grid
        case list
    }

    private let action: NativeKeyboardAttachmentAction
    private let style: Style
    private weak var listTitleLabel: UILabel?

    init(action: NativeKeyboardAttachmentAction, style: Style) {
        self.action = action
        self.style = style
        super.init(frame: .zero)

        isEnabled = action.enabled
        alpha = action.enabled ? 1 : 0.48
        backgroundColor = .clear

        switch style {
        case .grid:
            buildGridContent()
        case .list:
            buildListContent()
        }
    }

    required init?(coder: NSCoder) {
        nil
    }

    /// Titles get a second line at accessibility text sizes.
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
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

    private weak var highlightView: UIView?

    override var isHighlighted: Bool {
        didSet {
            UIView.animate(withDuration: 0.14) {
                self.highlightView?.alpha = self.isHighlighted ? 1 : 0
                if self.style == .grid {
                    self.alpha = self.action.enabled
                        ? (self.isHighlighted ? 0.7 : 1)
                        : 0.48
                }
            }
        }
    }

    private var foreground: UIColor {
        action.enabled ? .label : .tertiaryLabel
    }

    private func buildGridContent() {
        let background: UIView
        if #available(iOS 26.0, *) {
            background = UIVisualEffectView(effect: UIGlassEffect())
        } else {
            background = UIView()
            background.backgroundColor = .secondarySystemFill
        }
        background.translatesAutoresizingMaskIntoConstraints = false
        background.isUserInteractionEnabled = false
        background.layer.cornerRadius = 14
        background.layer.cornerCurve = .continuous
        background.clipsToBounds = true
        addSubview(background)

        let icon = UIImageView(image: UIImage(systemName: action.sfSymbol))
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(
            textStyle: .body,
            scale: .medium
        )
        icon.tintColor = foreground
        icon.contentMode = .scaleAspectFit

        let label = UILabel()
        label.text = action.label
        label.font = UIFont.systemFont(
            ofSize: UIFont.preferredFont(forTextStyle: .caption1).pointSize,
            weight: .medium
        )
        label.adjustsFontForContentSizeCategory = true
        label.textColor = foreground
        label.textAlignment = .center
        // A long localized name ("Appareil photo") wraps rather than
        // truncates, so every tile can share one column width.
        label.numberOfLines = 2
        label.lineBreakMode = .byWordWrapping
        label.allowsDefaultTighteningForTruncation = true

        isAccessibilityElement = true
        accessibilityLabel = action.label
        accessibilityTraits = .button

        let stack = UIStackView(arrangedSubviews: [icon, label])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 4
        stack.isUserInteractionEnabled = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo: leadingAnchor),
            background.trailingAnchor.constraint(equalTo: trailingAnchor),
            background.topAnchor.constraint(equalTo: topAnchor),
            background.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            stack.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 8),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -8),
        ])
    }

    /// A flat menu row: plain symbol, regular-weight title, and a trailing
    /// checkmark while a toggle is on, or a chevron on a command that opens
    /// something.
    private func buildListContent() {
        let highlight = UIView()
        highlight.translatesAutoresizingMaskIntoConstraints = false
        highlight.isUserInteractionEnabled = false
        highlight.backgroundColor = .tertiarySystemFill
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
        textStack.spacing = 0

        let isCommand = action.kind == .command
        let accessory = UIImageView(
            image: UIImage(systemName: isCommand ? "chevron.right" : "checkmark")
        )
        accessory.preferredSymbolConfiguration = UIImage.SymbolConfiguration(
            textStyle: isCommand ? .footnote : .subheadline,
            scale: .medium
        )
        accessory.tintColor = isCommand ? .secondaryLabel : .label
        accessory.contentMode = .scaleAspectFit
        accessory.isHidden = !isCommand && !action.selected
        accessory.translatesAutoresizingMaskIntoConstraints = false

        let row = UIStackView(arrangedSubviews: [icon, textStack, accessory])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 12
        row.isUserInteractionEnabled = false
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        // Below required so the stack's zero-width hiding constraint wins
        // when the option is off, without an Auto Layout conflict.
        let accessoryWidth = accessory.widthAnchor.constraint(equalToConstant: 20)
        accessoryWidth.priority = .defaultHigh

        // A toggle reads its on/off state as its value; without a state
        // label, a selected option at least reads as selected.
        isAccessibilityElement = true
        accessibilityLabel = action.label
        accessibilityHint = action.subtitle
        if action.kind == .toggle, let state = action.stateLabel, !state.isEmpty {
            accessibilityValue = state
            accessibilityTraits = .button
        } else {
            accessibilityTraits = action.selected ? [.button, .selected] : .button
        }

        NSLayoutConstraint.activate([
            highlight.leadingAnchor.constraint(equalTo: leadingAnchor, constant: -8),
            highlight.trailingAnchor.constraint(equalTo: trailingAnchor, constant: 8),
            highlight.topAnchor.constraint(equalTo: topAnchor),
            highlight.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
            icon.widthAnchor.constraint(equalToConstant: 22),
            accessoryWidth,
        ])
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
