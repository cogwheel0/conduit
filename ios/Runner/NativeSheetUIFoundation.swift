import UIKit

private func nativeSheetColor(_ argb: Int64) -> UIColor {
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
        controller.view.tintColor = accent
        apply(to: controller.view)

        if let navigationController = controller as? UINavigationController {
            navigationController.navigationBar.tintColor = accent
            navigationController.toolbar.tintColor = accent
        }

        controller.children.forEach(apply(to:))
        if let presented = controller.presentedViewController {
            apply(to: presented)
        }
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
}

func applyNativeSheetSegmentedControlTheme(_ control: UISegmentedControl) {
    let theme = NativeSheetTheme.shared
    control.backgroundColor = theme.elevatedSurface
    control.selectedSegmentTintColor = theme.accent
    control.setTitleTextAttributes(
        [.foregroundColor: theme.foreground],
        for: .normal
    )
    control.setTitleTextAttributes(
        [.foregroundColor: theme.onAccent],
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
        tableView.separatorStyle = .none
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
            tableView.sectionHeaderTopPadding = 12
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
            pointSize: iconSize,
            weight: .regular
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

    static func applyHeaderFooterStyle(_ view: UIView) {
        guard let headerFooter = view as? UITableViewHeaderFooterView else { return }
        headerFooter.textLabel?.font = .preferredFont(forTextStyle: .footnote)
        headerFooter.textLabel?.textColor = secondaryForeground
        headerFooter.textLabel?.numberOfLines = 0
    }
}
