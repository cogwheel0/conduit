import Flutter
import UIKit

/// Presents UIKit's edit menu for Flutter's read-only selection regions.
/// Flutter keeps the selection and action callbacks; only labels and geometry
/// cross the channel. No text input connection or hidden editor is needed.
@available(iOS 16.0, *)
@MainActor
final class NativeTextSelectionMenuBridge: NSObject, ConduitBridge, UIEditMenuInteractionDelegate {
  static let shared = NativeTextSelectionMenuBridge()

  private weak var host: ConduitBridgeHost?
  private var channel: FlutterMethodChannel?
  private var anchorView: UIView?
  private var interaction: UIEditMenuInteraction?
  private var session: Int?
  private var completion: FlutterResult?
  private var labels: [String] = []
  private var targetRect: CGRect = .zero
  private var selectedAction: Int?

  /// Resolves pending menus when the app gives up foreground interaction.
  override init() {
    super.init()
    NotificationCenter.default.addObserver(
      self, selector: #selector(dismiss),
      name: UIApplication.willResignActiveNotification, object: nil)
  }

  /// Ends the previous host's presentation before attaching a new engine.
  func attach(to host: ConduitBridgeHost) {
    dismiss()
    channel?.setMethodCallHandler(nil)
    self.host = host
    let channel = FlutterMethodChannel(
      name: "app.cogwheel.conduit/text_selection_menu", binaryMessenger: host.messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else { result(nil); return }
      let args = call.arguments as? [String: Any] ?? [:]
      switch call.method {
      case "show":
        show(args, result: result)
      case "hide":
        if args["session"] as? Int == session { dismiss() }
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    self.channel = channel
  }

  /// Adds a non-intercepting anchor to the host's view. UIKit owns the menu's
  /// appearance, placement, accessibility, and presentation/dismissal animations.
  private func show(_ args: [String: Any], result: @escaping FlutterResult) {
    dismiss()
    guard let id = args["session"] as? Int,
      let labels = args["labels"] as? [String], !labels.isEmpty,
      let rect = args["rect"] as? [Double], rect.count == 4,
      let width = args["viewWidth"] as? Double, width > 0,
      let height = args["viewHeight"] as? Double, height > 0,
      (rect + [width, height]).allSatisfy(\.isFinite), rect[2] >= 0, rect[3] >= 0,
      let view = host?.presentingViewController?.viewIfLoaded, view.window != nil
    else {
      result(FlutterError(code: "unavailable", message: "Selection menu unavailable", details: nil))
      return
    }
    let scaleX = view.bounds.width / width
    let scaleY = view.bounds.height / height
    let target = CGRect(
      x: rect[0] * scaleX, y: rect[1] * scaleY,
      width: rect[2] * scaleX, height: rect[3] * scaleY)
    targetRect = target.intersection(view.bounds)
    if targetRect.isNull {
      result(FlutterError(code: "unavailable", message: "Selection is off screen", details: nil))
      return
    }
    let anchor = UIView(frame: view.bounds)
    anchor.isUserInteractionEnabled = false
    anchor.overrideUserInterfaceStyle = args["dark"] as? Bool == true ? .dark : .light
    let interaction = UIEditMenuInteraction(delegate: self)
    anchor.addInteraction(interaction)
    view.addSubview(anchor)
    self.anchorView = anchor
    self.interaction = interaction
    self.session = id
    self.labels = labels
    self.completion = result
    selectedAction = nil
    interaction.presentEditMenu(with: UIEditMenuConfiguration(
      identifier: NSNumber(value: id),
      sourcePoint: CGPoint(x: targetRect.midX, y: targetRect.midY)))
  }

  /// Binds UIKit actions to the interaction that created them.
  func editMenuInteraction(
    _ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration,
    suggestedActions: [UIMenuElement]
  ) -> UIMenu? {
    let id = session
    return UIMenu(children: labels.enumerated().map { index, label in
      UIAction(title: label) { [weak self, weak interaction] _ in
        guard let self, let interaction,
          self.interaction === interaction, self.session == id else { return }
        self.selectedAction = index
      }
    })
  }

  /// Anchors UIKit to the visible selection within the Flutter host view.
  func editMenuInteraction(
    _ interaction: UIEditMenuInteraction, targetRectFor configuration: UIEditMenuConfiguration
  ) -> CGRect { targetRect }

  /// Returns the chosen action after the current interaction's animation.
  func editMenuInteraction(
    _ interaction: UIEditMenuInteraction, willDismissMenuFor configuration: UIEditMenuConfiguration,
    animator: UIEditMenuInteractionAnimating
  ) {
    let id = (configuration.identifier as? NSNumber)?.intValue
    animator.addCompletion { [weak self, weak interaction] in
      guard let self, let interaction,
        self.interaction === interaction, self.session == id else { return }
      self.finish()
    }
  }

  /// Delivers one result and releases this presentation's UIKit objects.
  private func finish() {
    let result = completion
    completion = nil
    session = nil
    interaction = nil
    anchorView?.removeFromSuperview()
    anchorView = nil
    labels = []
    result?(selectedAction)
    selectedAction = nil
  }

  /// Dismisses the current menu while preserving an already chosen action.
  @objc private func dismiss() {
    interaction?.dismissMenu()
    finish()
  }
}
