import Flutter
import ObjectiveC.runtime
import UIKit

private var nativeKeyboardAttachmentInputViewKey: UInt8 = 0

private struct NativeKeyboardAttachmentAction: Equatable {
    let id: String
    let label: String
    let subtitle: String?
    let section: String
    let sfSymbol: String
    let enabled: Bool
    let selected: Bool
    let dismissesKeyboard: Bool

    init(_ config: PlatformKeyboardAttachmentActionConfig) {
        id = config.id
        label = config.label
        subtitle = config.subtitle
        section = config.section
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

    private func activateAttachmentInputView(
        for responder: UIResponder,
        reloadInputViews: Bool
    ) {
        shouldPresentOnNextFocus = false
        attachmentInputView.update(actions: actions)
        attachmentInputView.updatePreferredHeight(
            measuredKeyboardHeight(for: responder)
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

    @objc
    private func handleKeyboardFrameChange(_ notification: Notification) {
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
        attachmentInputView.updatePreferredHeight(visibleHeight)
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

    private let onSelect: (NativeKeyboardAttachmentAction) -> Void
    private let scrollView = UIScrollView()
    private let stackView = UIStackView()
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
                constant: -24
            ),
            stackView.widthAnchor.constraint(
                equalTo: scrollView.frameLayoutGuide.widthAnchor,
                constant: -2 * horizontalContentInset
            ),
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard
            previousTraitCollection?.verticalSizeClass != traitCollection.verticalSizeClass
        else {
            return
        }
        stackTopConstraint.constant = topContentInset
    }

    func update(actions: [NativeKeyboardAttachmentAction]) {
        stackView.arrangedSubviews.forEach { view in
            stackView.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        var attachmentStrip: UIScrollView?

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

            if key != "attachments", key != "features" {
                addSectionTitle(title(for: key))
            }
            if key == "attachments" {
                attachmentStrip = addAttachmentRow(sectionActions)
            } else {
                addListSection(sectionActions)
            }
        }

        if let strip = attachmentStrip {
            stackView.setCustomSpacing(8, after: strip)
        }
    }

    func updatePreferredHeight(_ height: CGFloat) {
        guard height > Self.minimumHeight else { return }
        heightConstraint.constant = height
    }

    private func addSectionTitle(_ title: String) {
        let label = UILabel()
        label.text = title
        label.font = UIFont.systemFont(
            ofSize: UIFont.preferredFont(forTextStyle: .caption1).pointSize,
            weight: .semibold
        )
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .tertiaryLabel
        label.setContentHuggingPriority(.required, for: .vertical)
        stackView.addArrangedSubview(label)
        stackView.setCustomSpacing(2, after: label)
    }

    /// Attach tiles: a filled rounded square holding icon and label.
    private var attachmentRowScrollHeight: CGFloat {
        traitCollection.verticalSizeClass == .compact ? 52 : 58
    }

    @discardableResult
    private func addAttachmentRow(_ actions: [NativeKeyboardAttachmentAction]) -> UIScrollView {
        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        scroll.alwaysBounceHorizontal = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.clipsToBounds = false

        let row = UIStackView()
        row.axis = .horizontal
        row.alignment = .fill
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false

        let rowHeight = attachmentRowScrollHeight
        scroll.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            row.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            row.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            row.heightAnchor.constraint(equalToConstant: rowHeight),
            scroll.heightAnchor.constraint(equalToConstant: rowHeight),
        ])

        actions.forEach { action in
            let button = NativeKeyboardAttachmentTile(action: action, style: .grid)
            button.addAction(UIAction { [weak self] _ in
                self?.onSelect(action)
            }, for: .touchUpInside)
            row.addArrangedSubview(button)
            button.widthAnchor.constraint(equalToConstant: 78).isActive = true
            button.heightAnchor.constraint(equalToConstant: rowHeight).isActive = true
        }

        stackView.addArrangedSubview(scroll)
        return scroll
    }

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

    private func title(for section: String) -> String {
        switch section {
        case "attachments":
            return "Attach"
        case "features":
            return "Features"
        case "tools":
            return "Tools"
        default:
            return section.capitalized
        }
    }
}

private final class NativeKeyboardAttachmentTile: UIControl {
    enum Style {
        case grid
        case list
    }

    private let action: NativeKeyboardAttachmentAction
    private let style: Style

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
        label.numberOfLines = 1
        label.lineBreakMode = .byTruncatingTail

        isAccessibilityElement = true
        accessibilityLabel = action.label
        accessibilityTraits = .button

        let stack = UIStackView(arrangedSubviews: [icon, label])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 3
        stack.isUserInteractionEnabled = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo: leadingAnchor),
            background.trailingAnchor.constraint(equalTo: trailingAnchor),
            background.topAnchor.constraint(equalTo: topAnchor),
            background.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
        ])
    }

    /// A flat menu row: plain symbol, regular-weight title, and a
    /// checkmark only while the option is on.
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
        titleLabel.numberOfLines = 1

        let subtitleLabel = UILabel()
        subtitleLabel.text = action.subtitle
        subtitleLabel.font = .preferredFont(forTextStyle: .caption1)
        subtitleLabel.adjustsFontForContentSizeCategory = true
        subtitleLabel.textColor = .secondaryLabel
        subtitleLabel.numberOfLines = 1
        subtitleLabel.isHidden = (action.subtitle ?? "").isEmpty

        let textStack = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
        textStack.axis = .vertical
        textStack.spacing = 0

        let accessory = UIImageView(image: UIImage(systemName: "checkmark"))
        accessory.preferredSymbolConfiguration = UIImage.SymbolConfiguration(
            textStyle: .subheadline,
            scale: .medium
        )
        accessory.tintColor = .label
        accessory.contentMode = .scaleAspectFit
        accessory.isHidden = !action.selected
        accessory.translatesAutoresizingMaskIntoConstraints = false

        let row = UIStackView(arrangedSubviews: [icon, textStack, accessory])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 12
        row.isUserInteractionEnabled = false
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        // A selected option also reads as selected to VoiceOver.
        isAccessibilityElement = true
        accessibilityLabel = action.label
        accessibilityHint = action.subtitle
        accessibilityTraits = action.selected ? [.button, .selected] : .button

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
            accessory.widthAnchor.constraint(equalToConstant: 20),
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
