import UIKit

func nativeSheetColor(_ argb: Int64) -> UIColor {
    let value = UInt64(bitPattern: argb)
    return UIColor(
        red: CGFloat((value >> 16) & 0xff) / 255,
        green: CGFloat((value >> 8) & 0xff) / 255,
        blue: CGFloat(value & 0xff) / 255,
        alpha: CGFloat((value >> 24) & 0xff) / 255
    )
}

/// How much white dark mode washes over a presented surface: #000 becomes
/// about #1C1C1E and #141414 about #2C2C2E, UIKit's elevated grouped
/// background and its groups.
let nativeSheetDarkElevation: CGFloat = 0.11

/// [color] as a surface presented over the page shows it: lifted by
/// [nativeSheetDarkElevation] in dark mode, unchanged in light mode, where
/// iOS keeps a sheet's colours.
func nativeSheetElevated(_ color: UIColor, isDark: Bool) -> UIColor {
    guard isDark else { return color }
    var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
    guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
        return color
    }
    let wash = nativeSheetDarkElevation
    return UIColor(
        red: red + (1 - red) * wash,
        green: green + (1 - green) * wash,
        blue: blue + (1 - blue) * wash,
        alpha: alpha
    )
}

/// The palette shared by every UIKit surface that Conduit presents. It keeps
/// native typography, layout, and materials while matching the Flutter theme.
final class NativeSheetTheme {
    static let shared = NativeSheetTheme()

    private(set) var isDark = UITraitCollection.current.userInterfaceStyle == .dark
    private(set) var background = UIColor.systemGroupedBackground
    private(set) var surface = UIColor.secondarySystemGroupedBackground
    private(set) var elevatedSurface = UIColor.secondarySystemGroupedBackground
    private(set) var input = UIColor.tertiarySystemFill
    private(set) var foreground = UIColor.label
    private(set) var secondaryForeground = UIColor.secondaryLabel
    private(set) var icon = UIColor.secondaryLabel
    private(set) var border = UIColor.separator
    private(set) var accent = UIColor.tintColor
    private(set) var onAccent = UIColor.white
    private(set) var destructive = UIColor.systemRed

    var selectionBackground: UIColor {
        accent.withAlphaComponent(isDark ? 0.22 : 0.12)
    }

    private init() {}

    func update(_ theme: PlatformNativeSheetTheme) {
        isDark = theme.isDark
        // Everything drawn in these colours is presented over the page: a
        // sheet, a menu. In dark mode iOS lifts such content onto its
        // elevated colours (#1C1C1E over a #000 page, #2C2C2E groups), or a
        // sheet in the page's own black would vanish into its dimmed page.
        // The palette's surfaces take the same lift, as a white wash, so a
        // tinted dark palette keeps its hue.
        let dark = theme.isDark
        func lift(_ argb: Int64) -> UIColor {
            nativeSheetElevated(nativeSheetColor(argb), isDark: dark)
        }
        background = lift(theme.backgroundArgb)
        surface = lift(theme.surfaceArgb)
        elevatedSurface = lift(theme.elevatedSurfaceArgb)
        input = lift(theme.inputArgb)
        foreground = nativeSheetColor(theme.foregroundArgb)
        secondaryForeground = nativeSheetColor(theme.secondaryForegroundArgb)
        icon = nativeSheetColor(theme.iconArgb)
        border = nativeSheetColor(theme.borderArgb)
        accent = nativeSheetColor(theme.accentArgb)
        onAccent = nativeSheetColor(theme.onAccentArgb)
        destructive = nativeSheetColor(theme.destructiveArgb)
    }

    func apply(to controller: UIViewController) {
        controller.overrideUserInterfaceStyle = isDark ? .dark : .light

        // UIKit documents UIAlertController's view hierarchy as private and
        // unmodifiable, and reading `view` forces a load outside the
        // presentation it expects. Alerts take the interface style here and
        // their accent from `applyAccent(to:)` once they are presented.
        if controller is UIAlertController { return }

        controller.view.tintColor = accent
        applyBarButtonTheme(controller.navigationItem)
        apply(to: controller.view)

        if let navigationController = controller as? UINavigationController {
            applyNavigationBarTheme(navigationController.navigationBar)
            navigationController.toolbar.tintColor = accent
        }

        controller.children.forEach(apply(to:))
        if let presented = controller.presentedViewController {
            apply(to: presented)
        }
    }

    /// Title and back chevron follow the palette foreground, matching the
    /// Flutter toolbar icons. iOS 26 draws the back button as a glass control
    /// that ignores the bar's tint, so the chevron is supplied pre-colored.
    private func applyNavigationBarTheme(_ bar: UINavigationBar) {
        bar.tintColor = accent
        let titleAttributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: foreground,
        ]
        bar.titleTextAttributes = titleAttributes
        bar.largeTitleTextAttributes = titleAttributes

        let chevron = UIImage(systemName: "chevron.backward")?
            .withTintColor(foreground, renderingMode: .alwaysOriginal)
        func themed(_ appearance: UINavigationBarAppearance) -> UINavigationBarAppearance {
            let copy = appearance.copy()
            copy.titleTextAttributes = titleAttributes
            copy.largeTitleTextAttributes = titleAttributes
            copy.setBackIndicatorImage(chevron, transitionMaskImage: chevron)
            return copy
        }
        bar.standardAppearance = themed(bar.standardAppearance)
        if let scrollEdge = bar.scrollEdgeAppearance {
            bar.scrollEdgeAppearance = themed(scrollEdge)
        }
        if let compact = bar.compactAppearance {
            bar.compactAppearance = themed(compact)
        }
    }

    /// Icon-only bar buttons (close, ellipsis, add) match the title and back
    /// chevron; titled actions such as Save keep the accent. iOS 26 renders
    /// glass bar buttons with the label color unless the item sets a tint.
    func applyBarButtonTheme(_ item: UINavigationItem) {
        let items = (item.leftBarButtonItems ?? []) + (item.rightBarButtonItems ?? [])
        for button in items
        where button.title == nil && button.customView == nil && button.style != .done {
            // `.done` confirm buttons render as accent-filled glass; keep them.
            button.tintColor = foreground
        }
    }

    /// Tints a presented alert without walking its private subviews. Call this
    /// after `present(_:animated:)`, when UIKit has loaded the alert's view for
    /// the presentation it is part of.
    func applyAccent(to controller: UIAlertController) {
        controller.view.tintColor = accent
    }

    private func apply(to view: UIView) {
        if let segmentedControl = view as? UISegmentedControl {
            applyNativeSheetSegmentedControlTheme(segmentedControl)
        } else if let tableView = view as? UITableView {
            tableView.backgroundColor = background
            tableView.reloadData()
        } else if let collectionView = view as? UICollectionView {
            collectionView.backgroundColor = background
            collectionView.reloadData()
        }

        view.setNeedsDisplay()
        view.setNeedsLayout()
        view.subviews.forEach(apply(to:))
    }
}

/// Feedback emitted for app-owned actions inside native sheets. Standard
/// UIKit controls provide their own feedback; the system haptics setting
/// remains the single source of truth for whether feedback is rendered.
enum NativeSheetHaptics {
    static func selection() {
        UISelectionFeedbackGenerator().selectionChanged()
    }

    static func mediumImpact() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
}

final class NativeSheetNavigationController: UINavigationController {
    override func viewDidLoad() {
        super.viewDidLoad()
        modalPresentationStyle = .pageSheet
        navigationBar.prefersLargeTitles = false
        NativeSheetTheme.shared.apply(to: self)
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        // Pushed controllers install their bar buttons in viewDidLoad, after
        // the sheet was themed, so theme the visible items on each layout.
        if let item = topViewController?.navigationItem {
            NativeSheetTheme.shared.applyBarButtonTheme(item)
        }
    }
}

/// The transition still running in the modal chain above [root]: a sheet
/// animating in, or one still leaving or being dragged away.
func nativeModalTransitionInFlight(
    from root: UIViewController?
) -> UIViewControllerTransitionCoordinator? {
    var controller = root
    while let current = controller {
        if current.isBeingPresented || current.isBeingDismissed,
           let coordinator = current.transitionCoordinator {
            return coordinator
        }
        controller = current.presentedViewController
    }
    return nil
}

/// Runs [work] on the main queue once nothing in the modal chain above
/// [root] is mid-transition.
///
/// UIKit declines to present over a controller that is still animating in
/// or out, and says so only in the console. A sheet asked for while the one
/// before it was still leaving -- New Folder chosen in Move to Folder, say --
/// never appeared, and the call that asked for it never heard back.
func nativeWhenModalChainIdle(
    from root: @escaping () -> UIViewController?,
    remainingWaits: Int = 8,
    _ work: @escaping () -> Void
) {
    DispatchQueue.main.async {
        guard remainingWaits > 0,
              let coordinator = nativeModalTransitionInFlight(from: root())
        else {
            work()
            return
        }
        var resumed = false
        let resume = {
            guard !resumed else { return }
            resumed = true
            nativeWhenModalChainIdle(
                from: root,
                remainingWaits: remainingWaits - 1,
                work
            )
        }
        let queued = coordinator.animate(alongsideTransition: nil) { _ in
            resume()
        }
        if !queued {
            // The transition could not take a completion (it is ending this
            // very moment); look again shortly.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: resume)
        }
    }
}

/// The system segmented control: a raised pill in the surface colour on a
/// recessed track, as everywhere else in iOS. Only the titles take the
/// palette's ink, so a custom palette still reads.
func applyNativeSheetSegmentedControlTheme(_ control: UISegmentedControl) {
    let theme = NativeSheetTheme.shared
    control.backgroundColor = nil
    control.selectedSegmentTintColor = nil
    control.setTitleTextAttributes(
        [.foregroundColor: theme.foreground],
        for: .normal
    )
    control.setTitleTextAttributes(
        [.foregroundColor: theme.foreground],
        for: .selected
    )
    control.setTitleTextAttributes(
        [.foregroundColor: theme.secondaryForeground],
        for: .disabled
    )
    control.setTitleTextAttributes(
        [.foregroundColor: theme.secondaryForeground],
        for: [.selected, .disabled]
    )
}


enum NativeSheetSettingsStyle {
    static let defaultCellHeight: CGFloat = 48
    static let iconSize: CGFloat = 24
    /// The column every settings row's symbol is centred in, as wide as the
    /// icon tiles of the Settings app, so titles start on one line however
    /// wide or narrow a symbol is.
    static let iconColumnWidth: CGFloat = 29
    /// One size and weight for every settings symbol, except the few that
    /// `symbolPointSize(for:)` evens out.
    static let symbolPointSize: CGFloat = 19

    /// The point size [name] is drawn at, so every symbol in the column
    /// carries about the same ink. The antenna's short arcs and the bare
    /// waveform's hairline bars read lighter than their neighbours at 19 pt,
    /// so they are drawn a little larger, at the same weight.
    static func symbolPointSize(for name: String?) -> CGFloat {
        switch name {
        case "antenna.radiowaves.left.and.right": return 21
        case "waveform": return 20
        default: return symbolPointSize
        }
    }
    static let iconSpacing: CGFloat = 12
    static var secondaryForeground: UIColor {
        NativeSheetTheme.shared.secondaryForeground
    }
    static var iconForeground: UIColor { NativeSheetTheme.shared.icon }

    static var horizontalMargin: CGFloat {
        let isWidePhone = UIDevice.current.userInterfaceIdiom == .phone &&
            UIScreen.main.bounds.width >= 414
        return isWidePhone ? 20 : 16
    }

    static func apply(to tableView: UITableView) {
        tableView.keyboardDismissMode = .interactive
        tableView.backgroundColor = NativeSheetTheme.shared.background
        // The system hairline between rows, starting at the row text: list
        // content rows align it themselves, custom rows through
        // `alignSeparator(of:toLeadingOf:)`. Inset-grouped sections draw
        // none under their last row, so a single-row group has no line.
        tableView.separatorStyle = .singleLine
        tableView.separatorColor = .separator
        tableView.separatorInsetReference = .fromCellEdges
        tableView.estimatedRowHeight = defaultCellHeight
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedSectionHeaderHeight = 20
        tableView.estimatedSectionFooterHeight = 28
        tableView.directionalLayoutMargins = NSDirectionalEdgeInsets(
            top: 0,
            leading: horizontalMargin,
            bottom: 0,
            trailing: horizontalMargin
        )
        if #available(iOS 15.0, *) {
            tableView.sectionHeaderTopPadding = 0
        }
    }

    /// Styles a list row; [symbol] names the row's SF Symbol, if it has one,
    /// so it is drawn at its own optical size.
    static func applyContentStyle(
        _ content: inout UIListContentConfiguration,
        symbol: String? = nil
    ) {
        content.textProperties.font = .preferredFont(forTextStyle: .body)
        content.textProperties.color = NativeSheetTheme.shared.foreground
        content.textProperties.numberOfLines = 2
        content.secondaryTextProperties.font = .preferredFont(forTextStyle: .footnote)
        content.secondaryTextProperties.color = secondaryForeground
        content.secondaryTextProperties.numberOfLines = 2
        content.imageProperties.preferredSymbolConfiguration = UIImage.SymbolConfiguration(
            pointSize: symbolPointSize(for: symbol),
            weight: .regular,
            scale: .medium
        )
        // Only the width is reserved, so rows keep the height their text
        // gives them.
        content.imageProperties.reservedLayoutSize = CGSize(
            width: iconColumnWidth,
            height: 0
        )
        // A symbol wider than the column shrinks into it instead of pushing
        // its title out of line.
        content.imageProperties.maximumSize = CGSize(
            width: iconColumnWidth,
            height: iconColumnWidth
        )
        content.imageProperties.tintColor = iconForeground
        content.imageToTextPadding = iconSpacing
    }

    static func applyCellStyle(_ cell: UITableViewCell) {
        cell.backgroundColor = NativeSheetTheme.shared.surface
        cell.preservesSuperviewLayoutMargins = true
        cell.contentView.preservesSuperviewLayoutMargins = true
        cell.directionalLayoutMargins = NSDirectionalEdgeInsets(
            top: 8,
            leading: horizontalMargin,
            bottom: 8,
            trailing: horizontalMargin
        )
        let selectedBackground = UIView()
        selectedBackground.backgroundColor = NativeSheetTheme.shared.selectionBackground
        cell.selectedBackgroundView = selectedBackground
    }

    /// Starts [cell]'s separator where [text] starts, as a list content
    /// configuration's separator does, so a custom row's hairline meets its
    /// title rather than its symbol or picture. Call from `layoutSubviews`,
    /// after `super`.
    static func alignSeparator(of cell: UITableViewCell, toLeadingOf text: UIView) {
        guard text.isDescendant(of: cell), !text.isHidden else { return }
        let frame = text.convert(text.bounds, to: cell)
        let leading = cell.effectiveUserInterfaceLayoutDirection == .rightToLeft
            ? cell.bounds.width - frame.maxX
            : frame.minX
        guard leading.isFinite, leading >= 0 else { return }
        // The line ends at the row's trailing margin, as a list content
        // row's does on iOS 26.
        let trailing = horizontalMargin
        if abs(cell.separatorInset.left - leading) > 0.5
            || abs(cell.separatorInset.right - trailing) > 0.5 {
            cell.separatorInset = UIEdgeInsets(
                top: 0,
                left: leading,
                bottom: 0,
                right: trailing
            )
        }
    }

    static func applyHeaderFooterStyle(_ view: UIView) {
        guard let headerFooter = view as? UITableViewHeaderFooterView else { return }
        headerFooter.textLabel?.font = .preferredFont(forTextStyle: .footnote)
        headerFooter.textLabel?.textColor = secondaryForeground
        headerFooter.textLabel?.numberOfLines = 0
    }
}

/// A settings row's symbol by name. SF Symbols draws every calendar with a
/// solid header bar, which reads as a heavier, filled glyph beside the
/// outline symbols of the other rows, so "calendar" is drawn here as an
/// outline at the size and stroke of a 19 pt regular symbol. Every other
/// name is the system's symbol.
func nativeSettingsSymbolImage(_ name: String) -> UIImage? {
    if name == "calendar" { return nativeOutlineCalendarImage }
    return UIImage(systemName: name)
}

/// An outline calendar -- frame, header rule, two binder rings and a few
/// days -- drawn as a template so it takes a row's tint like a symbol.
private let nativeOutlineCalendarImage: UIImage = {
    let size = CGSize(width: 22, height: 22)
    let stroke: CGFloat = 1.5
    let image = UIGraphicsImageRenderer(size: size).image { _ in
        UIColor.black.setStroke()
        UIColor.black.setFill()
        let frame = UIBezierPath(
            roundedRect: CGRect(x: 2, y: 3.2, width: 18, height: 16.8),
            cornerRadius: 3.8
        )
        frame.lineWidth = stroke
        frame.stroke()
        let header = UIBezierPath()
        header.move(to: CGPoint(x: 2, y: 8))
        header.addLine(to: CGPoint(x: 20, y: 8))
        header.lineWidth = stroke
        header.stroke()
        for x: CGFloat in [7, 15] {
            let ring = UIBezierPath()
            ring.move(to: CGPoint(x: x, y: 1.3))
            ring.addLine(to: CGPoint(x: x, y: 5))
            ring.lineWidth = stroke
            ring.lineCapStyle = .round
            ring.stroke()
        }
        let dot: CGFloat = 1.9
        for y: CGFloat in [12, 15.9] {
            for x: CGFloat in [6.6, 11, 15.4] {
                UIBezierPath(ovalIn: CGRect(
                    x: x - dot / 2,
                    y: y - dot / 2,
                    width: dot,
                    height: dot
                )).fill()
            }
        }
    }
    return image.withRenderingMode(.alwaysTemplate)
}()

/// A palette's colour as one filled disc with a hairline edge, the way
/// Calendar marks a calendar beside its name: plainly a swatch, never a
/// control. (Overlapping discs read as a switch's knob and track.) The edge
/// is a little stronger than a separator, so a disc the colour of the row
/// still shows. Only the first colour is drawn.
func nativePaletteSwatchImage(
    _ colors: [UIColor],
    discDiameter: CGFloat = 12
) -> UIImage? {
    guard let color = colors.first else { return nil }
    let theme = NativeSheetTheme.shared
    let outline = theme.foreground.withAlphaComponent(theme.isDark ? 0.3 : 0.16)
    let size = CGSize(width: discDiameter, height: discDiameter)
    let image = UIGraphicsImageRenderer(size: size).image { context in
        let cg = context.cgContext
        let disc = CGRect(origin: .zero, size: size)
        cg.setFillColor(color.cgColor)
        cg.fillEllipse(in: disc)
        let hairline = 1 / max(UIScreen.main.scale, 1)
        cg.setStrokeColor(outline.cgColor)
        cg.setLineWidth(hairline)
        cg.strokeEllipse(in: disc.insetBy(dx: hairline / 2, dy: hairline / 2))
    }
    return image.withRenderingMode(.alwaysOriginal)
}

/// [text] led by [swatch], centred on the text's cap height, for a value
/// cell that shows a palette by its colours and its name.
func nativeSwatchedText(
    _ swatch: UIImage,
    _ text: String,
    font: UIFont,
    color: UIColor
) -> NSAttributedString {
    let attachment = NSTextAttachment(image: swatch)
    attachment.bounds = CGRect(
        x: 0,
        y: (font.capHeight - swatch.size.height) / 2,
        width: swatch.size.width,
        height: swatch.size.height
    )
    let result = NSMutableAttributedString(attachment: attachment)
    result.append(NSAttributedString(
        string: "\u{2002}" + text,
        attributes: [.font: font, .foregroundColor: color]
    ))
    return result
}
