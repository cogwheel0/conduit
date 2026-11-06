import Flutter
import UIKit

// FLUTTER HOST ONLY. A platform view, so it is registered by the app
// delegate with the engine's plugin registry rather than through
// `ConduitBridgeRegistry`.

/// Creates the floating tab bar Flutter embeds as `conduit/floating_tab_bar`.
final class FloatingTabBarViewFactory: NSObject, FlutterPlatformViewFactory {
  static let viewType = "conduit/floating_tab_bar"

  private let messenger: FlutterBinaryMessenger

  init(messenger: FlutterBinaryMessenger) {
    self.messenger = messenger
    super.init()
  }

  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    FlutterStandardMessageCodec.sharedInstance()
  }

  func create(
    withFrame frame: CGRect,
    viewIdentifier viewId: Int64,
    arguments args: Any?
  ) -> FlutterPlatformView {
    FloatingTabBarPlatformView(
      frame: frame,
      viewId: viewId,
      arguments: args as? [String: Any] ?? [:],
      messenger: messenger
    )
  }
}

/// Connects one `FloatingTabBarView` to its Dart widget.
///
/// Dart sends `update` with the full configuration. The view sends `select`
/// with a tab index and `action` when its round button is pressed.
private final class FloatingTabBarPlatformView: NSObject, FlutterPlatformView {
  private let bar: FloatingTabBarView
  private let channel: FlutterMethodChannel

  init(
    frame: CGRect,
    viewId: Int64,
    arguments: [String: Any],
    messenger: FlutterBinaryMessenger
  ) {
    bar = FloatingTabBarView(frame: frame)
    channel = FlutterMethodChannel(
      name: "\(FloatingTabBarViewFactory.viewType)_\(viewId)",
      binaryMessenger: messenger
    )
    super.init()
    bar.apply(arguments)
    bar.onSelect = { [weak self] index in
      self?.channel.invokeMethod("select", arguments: index)
    }
    bar.onAction = { [weak self] in
      self?.channel.invokeMethod("action", arguments: nil)
    }
    channel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "update" else {
        result(FlutterMethodNotImplemented)
        return
      }
      self?.bar.apply(call.arguments as? [String: Any] ?? [:])
      result(nil)
    }
  }

  deinit {
    channel.setMethodCallHandler(nil)
  }

  func view() -> UIView { bar }
}

/// A `UITabBar` that reports where UIKit put its tab buttons.
private final class RowReportingTabBar: UITabBar {
  var onRowLayout: ((CGRect) -> Void)?

  override func layoutSubviews() {
    super.layoutSubviews()
    let row = tabButtons(in: self).reduce(CGRect.null) {
      $0.union(convert($1.bounds, from: $1))
    }
    if !row.isNull { onRowLayout?(row) }
  }

  override func safeAreaInsetsDidChange() {
    super.safeAreaInsetsDidChange()
    invalidateIntrinsicContentSize()
  }

  // The bar holds no other controls than its tab buttons.
  private func tabButtons(in view: UIView) -> [UIView] {
    view.subviews.filter { !$0.isHidden }.flatMap { subview -> [UIView] in
      subview is UIControl ? [subview] : tabButtons(in: subview)
    }
  }
}

/// Icon-only tabs on the system tab bar, aligned to the leading edge, with a
/// round glass action at the trailing edge.
///
/// The view spans the bottom of the window, so UIKit floats the bar above
/// the home indicator as it does for an app's own tab bar. The bar always
/// takes the phone layout, which an iPad sidebar would otherwise compress.
/// UIKit's platter keeps one height, while the window's other glass buttons
/// follow the text size, so the bar is scaled to their size, keeping its
/// selection lens, and the action takes the same size. The action follows the tab buttons UIKit laid
/// out, so the two line up on every device.
private final class FloatingTabBarView: UIView, UITabBarDelegate {
  var onSelect: ((Int) -> Void)?
  var onAction: (() -> Void)?

  private let tabBar = RowReportingTabBar()
  private let actionButton = UIButton(type: .system)
  private lazy var tabBarWidth = tabBar.widthAnchor.constraint(equalToConstant: 0)
  private var itemWidth: CGFloat = 72
  private var tabCount = 0
  private var selectedIndex = 0
  private var itemLabels: [String] = []
  private var itemImages: [Data] = []
  private var actionSymbol = ""

  /// Height of the window's other glass buttons, which the platter is scaled
  /// to and the action takes. Zero keeps UIKit's size.
  private var controlExtent: CGFloat = 0

  /// Inset of the platter and the action from the sides of the view.
  private var edgeInset: CGFloat = 16

  /// Point size of the action's symbol, as the window's other glass buttons
  /// draw theirs.
  private var actionSymbolSize: CGFloat = 18

  /// UIKit's inset of the floating platter from each side of the bar.
  private static let platterMargin: CGFloat = 21

  /// How far the platter's glass extends around its tab buttons.
  private static let platterPadding: CGFloat = 3

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear
    tabBar.itemPositioning = .fill
    if #available(iOS 17.0, *) {
      tabBar.traitOverrides.horizontalSizeClass = .compact
      tabBar.traitOverrides.verticalSizeClass = .regular
    }
    tabBar.delegate = self
    tabBar.translatesAutoresizingMaskIntoConstraints = false
    addSubview(tabBar)
    NSLayoutConstraint.activate([
      tabBar.leadingAnchor.constraint(equalTo: leadingAnchor),
      tabBar.bottomAnchor.constraint(equalTo: bottomAnchor),
      tabBarWidth,
    ])
    tabBar.onRowLayout = { [weak self] row in self?.layoutBar(alongside: row) }

    actionButton.addAction(
      UIAction { [weak self] _ in self?.onAction?() },
      for: .touchUpInside
    )
    addSubview(actionButton)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { nil }

  func apply(_ arguments: [String: Any]) {
    if let isDark = arguments["isDark"] as? Bool {
      overrideUserInterfaceStyle = isDark ? .dark : .light
    }
    // A tint sent as null restores the system's.
    if arguments.keys.contains("tint") {
      tabBar.tintColor = (arguments["tint"] as? NSNumber).map(Self.color)
    }
    if arguments.keys.contains("unselectedTint") {
      tabBar.unselectedItemTintColor = (arguments["unselectedTint"] as? NSNumber)
        .map(Self.color)
    }
    if let width = arguments["itemWidth"] as? Double { itemWidth = CGFloat(width) }
    if let extent = arguments["controlExtent"] as? Double { controlExtent = CGFloat(extent) }
    if let inset = arguments["edgeInset"] as? Double { edgeInset = CGFloat(inset) }
    if let size = arguments["actionSymbolSize"] as? Double,
       CGFloat(size) != actionSymbolSize
    {
      actionSymbolSize = CGFloat(size)
      if !actionSymbol.isEmpty { configureAction() }
    }
    if let tabs = arguments["tabs"] as? [[String: Any]] { setTabs(tabs) }
    if let index = arguments["selectedIndex"] as? Int {
      selectedIndex = index
      updateSelection()
    }
    if let symbol = arguments["actionSymbol"] as? String, symbol != actionSymbol {
      actionSymbol = symbol
      configureAction()
    }
    if let label = arguments["actionLabel"] as? String {
      actionButton.accessibilityLabel = label
    }
    if arguments.keys.contains("actionTint") {
      actionButton.configuration?.baseForegroundColor =
        (arguments["actionTint"] as? NSNumber).map(Self.color) ?? .label
    }
    setNeedsLayout()
  }

  private func setTabs(_ tabs: [[String: Any]]) {
    let labels = tabs.map { $0["label"] as? String ?? "" }
    let images = tabs.map { ($0["image"] as? FlutterStandardTypedData)?.data ?? Data() }
    tabCount = tabs.count
    tabBarWidth.constant = CGFloat(max(tabCount, 1)) * itemWidth + Self.platterMargin * 2
    guard labels != itemLabels || images != itemImages || tabBar.items == nil else { return }
    itemLabels = labels
    itemImages = images

    // A lone action still lines up with the bar UIKit would lay out, so a
    // hidden placeholder item keeps the row measurable.
    let hidesTabs = tabs.count < 2
    tabBar.alpha = hidesTabs ? 0 : 1
    tabBar.isUserInteractionEnabled = !hidesTabs
    tabBar.accessibilityElementsHidden = hidesTabs
    let items: [UITabBarItem] = hidesTabs
      ? [UITabBarItem(title: nil, image: UIImage(systemName: "circle"), tag: 0)]
      : tabs.enumerated().map { index, tab in
        let image = (tab["image"] as? FlutterStandardTypedData).flatMap { data in
          UIImage(data: data.data, scale: CGFloat(tab["imageScale"] as? Double ?? 1))
        }
        let item = UITabBarItem(
          title: nil,
          image: Self.tabIcon(image, size: CGFloat(tab["iconSize"] as? Double ?? 24)),
          tag: index
        )
        item.accessibilityLabel = tab["label"] as? String
        return item
      }
    tabBar.items = items
    updateSelection()
  }

  private func updateSelection() {
    guard let items = tabBar.items, items.indices.contains(selectedIndex) else { return }
    let item = items[selectedIndex]
    if tabBar.selectedItem !== item { tabBar.selectedItem = item }
  }

  private func configureAction() {
    var configuration: UIButton.Configuration
    if #available(iOS 26.0, *) {
      configuration = .glass()
    } else {
      configuration = .gray()
    }
    configuration.cornerStyle = .capsule
    configuration.baseForegroundColor = actionButton.configuration?.baseForegroundColor ?? .label
    configuration.image = UIImage(systemName: actionSymbol)
    configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(
      pointSize: actionSymbolSize
    )
    actionButton.configuration = configuration
  }

  /// Scales the bar so the platter around its tab [row] is [controlExtent]
  /// tall, about the platter's bottom-leading corner: the platter keeps the
  /// height UIKit floats it at, and its leading edge moves to [edgeInset].
  /// The action takes the platter's height, centred on it, [edgeInset] from
  /// the trailing edge.
  ///
  /// [row] is in the tab bar's own coordinates, which its scale leaves alone.
  private func layoutBar(alongside row: CGRect) {
    guard row.height > 0 else { return }
    let platter = row.insetBy(dx: -Self.platterPadding, dy: -Self.platterPadding)
    // Smaller at the default text size, larger at the largest ones.
    let scale = controlExtent > 0 ? controlExtent / platter.height : 1
    // A transform acts about the bar's centre, which Auto Layout places.
    let center = tabBar.center
    let corner = CGPoint(
      x: platter.minX - tabBar.bounds.midX,
      y: platter.maxY - tabBar.bounds.midY
    )
    let transform = CGAffineTransform(
      translationX: edgeInset - center.x - scale * corner.x,
      y: (1 - scale) * corner.y
    ).scaledBy(x: scale, y: scale)
    if tabBar.transform != transform { tabBar.transform = transform }

    let size = platter.height * scale
    let platterMidY = center.y + corner.y - size / 2
    actionButton.frame = CGRect(
      x: bounds.maxX - edgeInset - size,
      y: platterMidY - size / 2,
      width: size,
      height: size
    )
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    tabBar.setNeedsLayout()
  }

  override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
    if let target = actionButton.hitTest(convert(point, to: actionButton), with: event) {
      return target
    }
    guard tabBar.isUserInteractionEnabled else { return nil }
    return tabBar.hitTest(convert(point, to: tabBar), with: event)
  }

  func tabBar(_ tabBar: UITabBar, didSelect item: UITabBarItem) {
    guard item.tag < tabCount else { return }
    selectedIndex = item.tag
    onSelect?(item.tag)
  }

  /// Fits an icon into the same box for every tab, as a template the bar
  /// tints; UIKit would otherwise draw bitmaps at their own size.
  private static func tabIcon(_ image: UIImage?, size: CGFloat) -> UIImage? {
    guard let image, image.size.width > 0, image.size.height > 0 else { return nil }
    let canvas = CGSize(width: 28, height: 28)
    let scale = min(size / image.size.width, size / image.size.height)
    let drawn = CGSize(width: image.size.width * scale, height: image.size.height * scale)
    return UIGraphicsImageRenderer(size: canvas).image { _ in
      image.draw(in: CGRect(
        x: (canvas.width - drawn.width) / 2,
        y: (canvas.height - drawn.height) / 2,
        width: drawn.width,
        height: drawn.height
      ))
    }.withRenderingMode(.alwaysTemplate)
  }

  private static func color(_ argb: NSNumber) -> UIColor {
    let value = argb.uint32Value
    return UIColor(
      red: CGFloat((value >> 16) & 0xFF) / 255,
      green: CGFloat((value >> 8) & 0xFF) / 255,
      blue: CGFloat(value & 0xFF) / 255,
      alpha: CGFloat((value >> 24) & 0xFF) / 255
    )
  }
}
