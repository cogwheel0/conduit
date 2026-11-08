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
        background = nativeSheetColor(theme.backgroundArgb)
        surface = nativeSheetColor(theme.surfaceArgb)
        elevatedSurface = nativeSheetColor(theme.elevatedSurfaceArgb)
        input = nativeSheetColor(theme.inputArgb)
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
    /// One size and weight for every settings symbol.
    static let symbolPointSize: CGFloat = 19
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

    static func applyContentStyle(_ content: inout UIListContentConfiguration) {
        content.textProperties.font = .preferredFont(forTextStyle: .body)
        content.textProperties.color = NativeSheetTheme.shared.foreground
        content.textProperties.numberOfLines = 2
        content.secondaryTextProperties.font = .preferredFont(forTextStyle: .footnote)
        content.secondaryTextProperties.color = secondaryForeground
        content.secondaryTextProperties.numberOfLines = 2
        content.imageProperties.preferredSymbolConfiguration = UIImage.SymbolConfiguration(
            pointSize: symbolPointSize,
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

    /// The body font at a medium weight, scaled with Dynamic Type: the label
    /// of an action row (Add Account), which reads as an action by weight
    /// while its symbol keeps every row's tint.
    static var actionTitleFont: UIFont {
        // 17 pt is the body size at the default text size; the metrics
        // scale it with Dynamic Type as the body style scales.
        UIFontMetrics(forTextStyle: .body).scaledFont(
            for: .systemFont(ofSize: 17, weight: .medium)
        )
    }

    static func applyHeaderFooterStyle(_ view: UIView) {
        guard let headerFooter = view as? UITableViewHeaderFooterView else { return }
        headerFooter.textLabel?.font = .preferredFont(forTextStyle: .footnote)
        headerFooter.textLabel?.textColor = secondaryForeground
        headerFooter.textLabel?.numberOfLines = 0
    }
}

/// A palette's colours as small overlapping discs, the way a palette picker
/// previews one: each disc is ringed in the row's surface so the overlaps
/// read, and outlined in the separator tone so a disc the colour of the
/// surface (a white page on a white row) still shows. The first colour sits
/// on top.
func nativePaletteSwatchImage(
    _ colors: [UIColor],
    discDiameter: CGFloat = 14
) -> UIImage? {
    guard !colors.isEmpty else { return nil }
    let theme = NativeSheetTheme.shared
    // A little stronger than a separator, so a disc the colour of the row
    // keeps its edge.
    let outline = theme.foreground.withAlphaComponent(theme.isDark ? 0.28 : 0.16)
    let ring: CGFloat = 1.5
    let step = discDiameter * 0.62
    let size = CGSize(
        width: discDiameter + step * CGFloat(colors.count - 1) + ring * 2,
        height: discDiameter + ring * 2
    )
    let image = UIGraphicsImageRenderer(size: size).image { context in
        let cg = context.cgContext
        for (index, color) in colors.enumerated().reversed() {
            let disc = CGRect(
                x: ring + step * CGFloat(index),
                y: ring,
                width: discDiameter,
                height: discDiameter
            )
            cg.setFillColor(theme.surface.cgColor)
            cg.fillEllipse(in: disc.insetBy(dx: -ring, dy: -ring))
            cg.setFillColor(color.cgColor)
            cg.fillEllipse(in: disc)
            let hairline = 1 / max(UIScreen.main.scale, 1)
            cg.setStrokeColor(outline.cgColor)
            cg.setLineWidth(hairline)
            cg.strokeEllipse(in: disc.insetBy(dx: hairline / 2, dy: hairline / 2))
        }
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
