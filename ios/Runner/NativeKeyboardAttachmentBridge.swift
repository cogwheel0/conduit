import Flutter
import ObjectiveC.runtime
import UIKit

private var nativeKeyboardAttachmentInputViewKey: UInt8 = 0

private struct NativeKeyboardAttachmentAction {
    let id: String
    let label: String
    let subtitle: String?
    let section: String
    let sfSymbol: String
    let enabled: Bool
    let selected: Bool
    let dismissesKeyboard: Bool

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
final class NativeKeyboardAttachmentBridge {
    static let shared = NativeKeyboardAttachmentBridge()

    private static let channelName = "conduit/keyboard_attachment"
    private static var didSwizzleInputView = false

    private var channel: FlutterMethodChannel?
    private weak var capturedFirstResponder: UIResponder?
    private weak var activeResponder: UIResponder?
    private var actions: [NativeKeyboardAttachmentAction] = []
    private var cachedKeyboardHeight = NativeKeyboardAttachmentInputView.defaultHeight
    private lazy var attachmentInputView = NativeKeyboardAttachmentInputView {
        [weak self] action in
        self?.handleAction(action)
    }

    private init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleKeyboardFrameChange(_:)),
            name: UIResponder.keyboardWillChangeFrameNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleKeyboardFrameChange(_:)),
            name: UIResponder.keyboardDidChangeFrameNotification,
            object: nil
        )
    }

    func configure(messenger: FlutterBinaryMessenger) {
        channel = FlutterMethodChannel(
            name: Self.channelName,
            binaryMessenger: messenger
        )
        channel?.setMethodCallHandler { [weak self] call, result in
            DispatchQueue.main.async {
                self?.handle(call, result: result)
            }
        }
    }

    fileprivate func capture(firstResponder: UIResponder) {
        capturedFirstResponder = firstResponder
    }

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "configure":
            updateConfiguration(from: call.arguments)
            result(true)
        case "show":
            updateConfiguration(from: call.arguments)
            result(show())
        case "hide":
            hide(reason: "method")
            result(true)
        case "toggle":
            updateConfiguration(from: call.arguments)
            if isPresented {
                hide(reason: "toggle")
                result(true)
            } else {
                result(show())
            }
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func updateConfiguration(from arguments: Any?) {
        guard let payload = arguments as? [String: Any] else {
            return
        }

        if let rawActions = payload["actions"] as? [Any] {
            actions = rawActions.compactMap { rawAction in
                guard let actionPayload = rawAction as? [String: Any] else {
                    return nil
                }
                return NativeKeyboardAttachmentAction(actionPayload)
            }
            attachmentInputView.update(actions: actions)
        }
    }

    private func show() -> Bool {
        guard Self.installInputViewSwizzleIfNeeded() else {
            return false
        }

        guard let responder = currentFirstResponder(),
              responder.isConduitFlutterTextInputView
        else {
            return false
        }

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
        responder.reloadInputViews()
        sendVisibilityChanged(true)
        return true
    }

    private func hide(reason: String) {
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
            hide(reason: "action")
        }

        channel?.invokeMethod(
            "onAction",
            arguments: [
                "id": action.id,
                "dismissesKeyboard": action.dismissesKeyboard,
            ]
        )
    }

    private func sendVisibilityChanged(_ isVisible: Bool) {
        channel?.invokeMethod(
            "onVisibilityChanged",
            arguments: ["visible": isVisible]
        )
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

        guard visibleHeight > NativeKeyboardAttachmentInputView.minimumHeight else {
            return
        }

        cachedKeyboardHeight = visibleHeight
        attachmentInputView.updatePreferredHeight(visibleHeight)
        if isPresented {
            attachmentInputView.setNeedsLayout()
            attachmentInputView.layoutIfNeeded()
        }
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

    private let onSelect: (NativeKeyboardAttachmentAction) -> Void
    private let scrollView = UIScrollView()
    private let stackView = UIStackView()
    private lazy var heightConstraint = heightAnchor.constraint(
        equalToConstant: Self.defaultHeight
    )

    init(onSelect: @escaping (NativeKeyboardAttachmentAction) -> Void) {
        self.onSelect = onSelect
        super.init(frame: .zero, inputViewStyle: .keyboard)

        allowsSelfSizing = false
        backgroundColor = .systemBackground
        autoresizingMask = [.flexibleWidth, .flexibleHeight]

        heightConstraint.priority = .required
        heightConstraint.isActive = true

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = true
        scrollView.keyboardDismissMode = .none

        stackView.axis = .vertical
        stackView.spacing = 14
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
                constant: 16
            ),
            stackView.trailingAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.trailingAnchor,
                constant: -16
            ),
            stackView.topAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.topAnchor,
                constant: 12
            ),
            stackView.bottomAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.bottomAnchor,
                constant: -18
            ),
            stackView.widthAnchor.constraint(
                equalTo: scrollView.frameLayoutGuide.widthAnchor,
                constant: -32
            ),
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }

    func update(actions: [NativeKeyboardAttachmentAction]) {
        stackView.arrangedSubviews.forEach { view in
            stackView.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

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

            addSectionTitle(title(for: key))
            if key == "attachments" {
                addAttachmentRow(sectionActions)
            } else {
                addListSection(sectionActions)
            }
        }
    }

    func updatePreferredHeight(_ height: CGFloat) {
        guard height > Self.minimumHeight else { return }
        heightConstraint.constant = height
    }

    private func addSectionTitle(_ title: String) {
        let label = UILabel()
        label.text = title
        label.font = .preferredFont(forTextStyle: .caption1)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .secondaryLabel
        label.setContentHuggingPriority(.required, for: .vertical)
        stackView.addArrangedSubview(label)
    }

    private func addAttachmentRow(_ actions: [NativeKeyboardAttachmentAction]) {
        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        scroll.alwaysBounceHorizontal = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let row = UIStackView()
        row.axis = .horizontal
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false

        scroll.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            row.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            row.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            row.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
            scroll.heightAnchor.constraint(equalToConstant: 86),
        ])

        actions.forEach { action in
            let button = NativeKeyboardAttachmentTile(action: action, style: .grid)
            button.addAction(UIAction { [weak self] _ in
                self?.onSelect(action)
            }, for: .touchUpInside)
            row.addArrangedSubview(button)
            button.widthAnchor.constraint(equalToConstant: 72).isActive = true
        }

        stackView.addArrangedSubview(scroll)
    }

    private func addListSection(_ actions: [NativeKeyboardAttachmentAction]) {
        let sectionStack = UIStackView()
        sectionStack.axis = .vertical
        sectionStack.spacing = 8

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
        alpha = action.enabled ? 1 : 0.42
        layer.cornerRadius = 14
        layer.cornerCurve = .continuous
        backgroundColor = action.selected
            ? tintColor.withAlphaComponent(0.16)
            : UIColor.secondarySystemBackground

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

    override var isHighlighted: Bool {
        didSet {
            UIView.animate(withDuration: 0.12) {
                self.transform = self.isHighlighted
                    ? CGAffineTransform(scaleX: 0.96, y: 0.96)
                    : .identity
                self.alpha = self.action.enabled
                    ? (self.isHighlighted ? 0.72 : 1)
                    : 0.42
            }
        }
    }

    private func buildGridContent() {
        let iconView = UIImageView(image: UIImage(systemName: action.sfSymbol))
        iconView.tintColor = action.selected ? tintColor : .label
        iconView.contentMode = .scaleAspectFit
        iconView.translatesAutoresizingMaskIntoConstraints = false

        let label = UILabel()
        label.text = action.label
        label.font = .preferredFont(forTextStyle: .caption2)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .label
        label.textAlignment = .center
        label.numberOfLines = 2

        let stack = UIStackView(arrangedSubviews: [iconView, label])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 7
        stack.isUserInteractionEnabled = false
        stack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 24),
            iconView.heightAnchor.constraint(equalToConstant: 24),
        ])
    }

    private func buildListContent() {
        let iconView = UIImageView(image: UIImage(systemName: action.sfSymbol))
        iconView.tintColor = action.selected ? tintColor : .label
        iconView.contentMode = .scaleAspectFit
        iconView.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = UILabel()
        titleLabel.text = action.label
        titleLabel.font = .preferredFont(forTextStyle: .subheadline)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = .label
        titleLabel.numberOfLines = 1

        let subtitleLabel = UILabel()
        subtitleLabel.text = action.subtitle
        subtitleLabel.font = .preferredFont(forTextStyle: .caption1)
        subtitleLabel.adjustsFontForContentSizeCategory = true
        subtitleLabel.textColor = .secondaryLabel
        subtitleLabel.numberOfLines = 2
        subtitleLabel.isHidden = (action.subtitle ?? "").isEmpty

        let textStack = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
        textStack.axis = .vertical
        textStack.spacing = 2

        let accessory = UIImageView(
            image: UIImage(systemName: action.selected ? "checkmark.circle.fill" : "circle")
        )
        accessory.tintColor = action.selected ? tintColor : .tertiaryLabel
        accessory.contentMode = .scaleAspectFit
        accessory.translatesAutoresizingMaskIntoConstraints = false

        let row = UIStackView(arrangedSubviews: [iconView, textStack, accessory])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 12
        row.isUserInteractionEnabled = false
        row.translatesAutoresizingMaskIntoConstraints = false

        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            iconView.widthAnchor.constraint(equalToConstant: 24),
            iconView.heightAnchor.constraint(equalToConstant: 24),
            accessory.widthAnchor.constraint(equalToConstant: 22),
            accessory.heightAnchor.constraint(equalToConstant: 22),
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

        return nil
    }
}
