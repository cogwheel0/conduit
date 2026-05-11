import Flutter
import PhotosUI
import UIKit

private struct NativeSheetProfile {
    let displayName: String
    let email: String
    let initials: String
    let avatarUrl: String?
    let avatarData: Data?
    let avatarHeaders: [String: String]
    let bio: String
    let gender: String
    let dateOfBirth: String?
    let savedProfileImageUrl: String?
}

private struct NativeEditProfileSheetCopy {
    let title: String
    let saveLabel: String
    let cancelLabel: String
    let footerText: String
    let nameLabel: String
    let nameRequiredMessage: String
    let customGenderRequiredMessage: String
    let bioLabel: String
    let bioHint: String
    let genderLabel: String
    let genderPreferNotToSay: String
    let genderMale: String
    let genderFemale: String
    let genderCustom: String
    let customGenderLabel: String
    let customGenderHint: String
    let birthDateLabel: String
    let selectBirthDateLabel: String
    let clearLabel: String
    let uploadFromDeviceLabel: String
    let useInitialsLabel: String
    let removeAvatarLabel: String
    let currentAvatarLabel: String

    init(_ payload: [String: Any]?) {
        let p = payload ?? [:]
        title = (p["title"] as? String) ?? "Edit profile"
        saveLabel = (p["saveLabel"] as? String) ?? "Save profile"
        cancelLabel = (p["cancelLabel"] as? String) ?? "Cancel"
        footerText = (p["footerText"] as? String) ?? ""
        nameLabel = (p["nameLabel"] as? String) ?? "Name"
        nameRequiredMessage = (p["nameRequiredMessage"] as? String) ?? ""
        customGenderRequiredMessage = (p["customGenderRequiredMessage"] as? String) ?? ""
        bioLabel = (p["bioLabel"] as? String) ?? "Bio"
        bioHint = (p["bioHint"] as? String) ?? ""
        genderLabel = (p["genderLabel"] as? String) ?? "Gender"
        genderPreferNotToSay = (p["genderPreferNotToSay"] as? String) ?? "Prefer not to say"
        genderMale = (p["genderMale"] as? String) ?? "Male"
        genderFemale = (p["genderFemale"] as? String) ?? "Female"
        genderCustom = (p["genderCustom"] as? String) ?? "Custom"
        customGenderLabel = (p["customGenderLabel"] as? String) ?? "Custom gender"
        customGenderHint = (p["customGenderHint"] as? String) ?? ""
        birthDateLabel = (p["birthDateLabel"] as? String) ?? "Date of birth"
        selectBirthDateLabel = (p["selectBirthDateLabel"] as? String) ?? "Select a date"
        clearLabel = (p["clearLabel"] as? String) ?? "Clear"
        uploadFromDeviceLabel = (p["uploadFromDeviceLabel"] as? String) ?? "Upload"
        useInitialsLabel = (p["useInitialsLabel"] as? String) ?? "Initials"
        removeAvatarLabel = (p["removeAvatarLabel"] as? String) ?? "Remove"
        currentAvatarLabel = (p["currentAvatarLabel"] as? String) ?? "Avatar"
    }
}

private struct NativeSheetOption {
    let id: String
    let label: String
    let subtitle: String?
    let sfSymbol: String?
    let enabled: Bool
    let destructive: Bool
    let ancestorHasMoreSiblings: [Bool]
    let showBranch: Bool
    let hasMoreSiblings: Bool

    init?(_ payload: [String: Any]) {
        guard
            let id = payload["id"] as? String,
            let label = payload["label"] as? String,
            !label.isEmpty
        else {
            return nil
        }

        self.id = id
        self.label = label
        subtitle = payload["subtitle"] as? String
        sfSymbol = payload["sfSymbol"] as? String
        enabled = payload["enabled"] as? Bool ?? true
        destructive = payload["destructive"] as? Bool ?? false
        ancestorHasMoreSiblings = (payload["ancestorHasMoreSiblings"] as? [Bool]) ?? []
        showBranch = payload["showBranch"] as? Bool ?? false
        hasMoreSiblings = payload["hasMoreSiblings"] as? Bool ?? false
    }
}

private struct NativeSheetItem {
    let id: String
    let title: String
    let subtitle: String?
    let sfSymbol: String
    let destructive: Bool
    let url: URL?
    let kind: String
    let value: Any?
    let placeholder: String?
    let options: [NativeSheetOption]
    let sliderMin: Double?
    let sliderMax: Double?
    let sliderDivisions: Int?

    init?(_ payload: [String: Any]) {
        guard
            let id = payload["id"] as? String,
            !id.isEmpty,
            let title = payload["title"] as? String,
            !title.isEmpty
        else {
            return nil
        }

        self.id = id
        self.title = title
        subtitle = payload["subtitle"] as? String
        sfSymbol = (payload["sfSymbol"] as? String) ?? "circle"
        destructive = payload["destructive"] as? Bool ?? false
        if let urlString = payload["url"] as? String {
            url = URL(string: urlString)
        } else {
            url = nil
        }
        kind = (payload["kind"] as? String) ?? "navigation"
        value = payload["value"]
        placeholder = payload["placeholder"] as? String
        options = (payload["options"] as? [[String: Any]] ?? [])
            .compactMap(NativeSheetOption.init)
        sliderMin = NativeSheetItem.optionalDouble(payload["min"])
        sliderMax = NativeSheetItem.optionalDouble(payload["max"])
        if let n = payload["divisions"] as? NSNumber {
            sliderDivisions = n.intValue
        } else {
            sliderDivisions = nil
        }
    }

    private static func optionalDouble(_ value: Any?) -> Double? {
        switch value {
        case let n as NSNumber:
            return n.doubleValue
        case let d as Double:
            return d
        case let i as Int:
            return Double(i)
        default:
            return nil
        }
    }
}

private extension NativeSheetItem {
    var sliderNumericValue: Double {
        switch value {
        case let n as NSNumber:
            return n.doubleValue
        case let d as Double:
            return d
        case let i as Int:
            return Double(i)
        default:
            return sliderMin ?? 0
        }
    }

    var selectedOptionId: String? {
        value as? String
    }

    var selectedOptionLabel: String? {
        guard let selectedOptionId else { return nil }
        return options.first(where: { $0.id == selectedOptionId })?.label
    }
}

private extension NativeSheetOption {
    var showsHierarchyGuides: Bool {
        showBranch || !ancestorHasMoreSiblings.isEmpty
    }
}

private struct NativeModelSelectorOption {
    let id: String
    let name: String
    let subtitle: String?
    let sfSymbol: String?
    let avatarUrl: String?
    let avatarHeaders: [String: String]

    init?(_ payload: [String: Any]) {
        guard
            let id = payload["id"] as? String,
            !id.isEmpty,
            let name = payload["name"] as? String,
            !name.isEmpty
        else {
            return nil
        }

        self.id = id
        self.name = name
        subtitle = payload["subtitle"] as? String
        sfSymbol = payload["sfSymbol"] as? String
        avatarUrl = payload["avatarUrl"] as? String
        avatarHeaders = payload["avatarHeaders"] as? [String: String] ?? [:]
    }
}

private struct NativeModelSelectorConfiguration {
    let title: String
    let selectedModelId: String?
    let models: [NativeModelSelectorOption]

    init?(_ arguments: Any?) {
        guard let payload = arguments as? [String: Any] else {
            return nil
        }

        title = (payload["title"] as? String) ?? "Choose Model"
        selectedModelId = payload["selectedModelId"] as? String
        models = (payload["models"] as? [[String: Any]] ?? [])
            .compactMap(NativeModelSelectorOption.init)
        if models.isEmpty {
            return nil
        }
    }
}

private func nativeSheetParseDate(_ raw: String?) -> Date? {
    guard let raw, !raw.isEmpty else { return nil }
    let isoFormatter = ISO8601DateFormatter()
    isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let parsed = isoFormatter.date(from: raw) {
        return parsed
    }

    let fallbackPatterns = [
        "yyyy-MM-dd'T'HH:mm:ss.SSS",
        "yyyy-MM-dd'T'HH:mm:ss",
        "yyyy-MM-dd"
    ]
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    for pattern in fallbackPatterns {
        formatter.dateFormat = pattern
        if let parsed = formatter.date(from: raw) {
            return parsed
        }
    }
    return nil
}

private func nativeSheetFormatDate(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
}

private struct NativeOptionsSelectorConfiguration {
    let title: String
    let subtitle: String?
    let selectedOptionId: String?
    let searchable: Bool
    let options: [NativeSheetOption]

    init(
        title: String,
        subtitle: String?,
        selectedOptionId: String?,
        searchable: Bool,
        options: [NativeSheetOption]
    ) {
        self.title = title
        self.subtitle = subtitle
        self.selectedOptionId = selectedOptionId
        self.searchable = searchable
        self.options = options
    }

    init?(_ arguments: Any?) {
        guard let payload = arguments as? [String: Any] else {
            return nil
        }

        let parsedOptions = (payload["options"] as? [[String: Any]] ?? [])
            .compactMap(NativeSheetOption.init)
        guard !parsedOptions.isEmpty else {
            return nil
        }

        title = (payload["title"] as? String) ?? "Select"
        subtitle = payload["subtitle"] as? String
        selectedOptionId = payload["selectedOptionId"] as? String
        searchable = payload["searchable"] as? Bool ?? true
        options = parsedOptions
    }
}

private struct NativeDatePickerConfiguration {
    let title: String
    let initialDate: Date
    let firstDate: Date
    let lastDate: Date
    let doneLabel: String
    let cancelLabel: String

    init?(_ arguments: Any?) {
        guard
            let payload = arguments as? [String: Any],
            let initialDate = nativeSheetParseDate(payload["initialDate"] as? String),
            let firstDate = nativeSheetParseDate(payload["firstDate"] as? String),
            let lastDate = nativeSheetParseDate(payload["lastDate"] as? String)
        else {
            return nil
        }

        title = (payload["title"] as? String) ?? "Select Date"
        self.initialDate = initialDate
        self.firstDate = firstDate
        self.lastDate = lastDate
        doneLabel = (payload["doneLabel"] as? String) ?? "Done"
        cancelLabel = (payload["cancelLabel"] as? String) ?? "Cancel"
    }
}

private struct NativeResultSheetConfiguration {
    let root: NativeSheetDetail
    let details: [String: NativeSheetDetail]
    let initialValues: [String: Any]

    init?(_ arguments: Any?) {
        guard
            let payload = arguments as? [String: Any],
            let rootPayload = payload["root"] as? [String: Any],
            let root = NativeSheetDetail(rootPayload)
        else {
            return nil
        }

        self.root = root
        var detailsById: [String: NativeSheetDetail] = [root.id: root]
        let relatedDetails = (payload["detailSheets"] as? [[String: Any]] ?? [])
            .compactMap(NativeSheetDetail.init)
        for detail in relatedDetails {
            detailsById[detail.id] = detail
        }
        details = detailsById
        initialValues = Self.buildInitialValues(from: Array(detailsById.values))
    }

    private static func buildInitialValues(from details: [NativeSheetDetail]) -> [String: Any] {
        var values: [String: Any] = [:]
        for detail in details {
            for item in detail.items {
                guard let value = initialValue(for: item) else { continue }
                values[item.id] = value
            }
        }
        return values
    }

    private static func initialValue(for item: NativeSheetItem) -> Any? {
        switch item.kind {
        case "textField", "secureTextField", "multilineTextField":
            return (item.value as? String) ?? ""
        case "dropdown", "searchablePicker", "segment":
            return item.selectedOptionId ?? item.options.first?.id
        case "toggle":
            return item.value as? Bool ?? false
        case "slider":
            return item.sliderNumericValue
        default:
            return nil
        }
    }
}

private struct NativeSheetDetail {
    let id: String
    let title: String
    let subtitle: String?
    let items: [NativeSheetItem]

    init(id: String, title: String, subtitle: String?, items: [NativeSheetItem]) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.items = items
    }

    init?(_ payload: [String: Any]) {
        guard
            let id = payload["id"] as? String,
            !id.isEmpty,
            let title = payload["title"] as? String,
            !title.isEmpty
        else {
            return nil
        }

        self.id = id
        self.title = title
        subtitle = payload["subtitle"] as? String
        items = (payload["items"] as? [[String: Any]] ?? [])
            .compactMap(NativeSheetItem.init)
    }
}

private struct NativeSheetConfiguration {
    let profile: NativeSheetProfile
    let profileMenuTitle: String
    let editProfileLabel: String
    let editProfileSheet: NativeEditProfileSheetCopy
    let supportTitle: String?
    let supportSubtitle: String?
    let menuItems: [NativeSheetItem]
    let supportItems: [NativeSheetItem]
    let details: [String: NativeSheetDetail]

    init?(_ arguments: Any?) {
        guard let payload = arguments as? [String: Any],
              let profilePayload = payload["profile"] as? [String: Any] else {
            return nil
        }

        let displayName = (profilePayload["displayName"] as? String) ?? "User"
        let email = (profilePayload["email"] as? String) ?? "No email"
        let initials = (profilePayload["initials"] as? String) ?? "U"
        let bio = (profilePayload["bio"] as? String) ?? ""
        let gender = (profilePayload["gender"] as? String) ?? ""
        let dateOfBirth = profilePayload["dateOfBirth"] as? String
        let savedUrl = profilePayload["profileImageUrl"] as? String
        profile = NativeSheetProfile(
            displayName: displayName,
            email: email,
            initials: initials,
            avatarUrl: profilePayload["avatarUrl"] as? String,
            avatarData: (profilePayload["avatarBytes"] as? FlutterStandardTypedData)?.data,
            avatarHeaders: (profilePayload["avatarHeaders"] as? [String: String]) ?? [:],
            bio: bio,
            gender: gender,
            dateOfBirth: dateOfBirth,
            savedProfileImageUrl: savedUrl
        )
        editProfileLabel = (payload["editProfileLabel"] as? String)
            ?? "Edit Profile"
        profileMenuTitle = (payload["profileMenuTitle"] as? String)
            ?? editProfileLabel
        editProfileSheet = NativeEditProfileSheetCopy(payload["editProfileSheet"] as? [String: Any])
        supportTitle = payload["supportTitle"] as? String
        supportSubtitle = payload["supportSubtitle"] as? String
        menuItems = (payload["menuItems"] as? [[String: Any]] ?? [])
            .compactMap(NativeSheetItem.init)
        supportItems = (payload["supportItems"] as? [[String: Any]] ?? [])
            .compactMap(NativeSheetItem.init)

        let detailPayloads = payload["detailSheets"] as? [[String: Any]] ?? []
        var detailsById: [String: NativeSheetDetail] = [:]
        for payload in detailPayloads {
            guard let detail = NativeSheetDetail(payload) else { continue }
            detailsById[detail.id] = detail
        }
        details = detailsById
    }
}

private final class NativeSheetPresentationDelegate:
    NSObject,
    UIAdaptivePresentationControllerDelegate
{
    private let onWillDismiss: () -> Void
    private let onDismiss: () -> Void

    init(
        onWillDismiss: @escaping () -> Void = {},
        onDismiss: @escaping () -> Void
    ) {
        self.onWillDismiss = onWillDismiss
        self.onDismiss = onDismiss
    }

    func presentationControllerWillDismiss(
        _ presentationController: UIPresentationController
    ) {
        onWillDismiss()
    }

    func presentationControllerDidDismiss(
        _ presentationController: UIPresentationController
    ) {
        onDismiss()
    }
}

final class NativeSheetBridge {
    static let shared = NativeSheetBridge()

    private static let channelName = "conduit/native_sheet"

    private enum ActiveSheetMode {
        case profileMenu
        case resultSheet
    }

    private var channel: FlutterMethodChannel?
    private var activeController: UIViewController?
    private var presentationDelegate: NativeSheetPresentationDelegate?
    private var configuration: NativeSheetConfiguration?
    private var detailPayloads: [String: NativeSheetDetail] = [:]
    private weak var activeDetailTableController: NativeDetailTableViewController?
    private var activeSheetMode: ActiveSheetMode = .profileMenu
    private var pendingModelSelectorResult: FlutterResult?
    private var pendingOptionsSelectorResult: FlutterResult?
    private var pendingResultSheetResult: FlutterResult?
    private var resultSheetValues: [String: Any] = [:]

    private init() {}

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

    private func handle(
        _ call: FlutterMethodCall,
        result: @escaping FlutterResult
    ) {
        switch call.method {
        case "presentProfileMenu":
            guard let configuration = NativeSheetConfiguration(call.arguments)
            else {
                result(FlutterError(
                    code: "INVALID_ARGS",
                    message: "Missing native profile sheet configuration",
                    details: nil
                ))
                return
            }
            activeSheetMode = .profileMenu
            self.configuration = configuration
            self.detailPayloads = configuration.details
            result(presentProfileMenu(configuration))

        case "dismiss":
            dismissActive()
            result(true)

        case "presentModelSelector":
            guard let configuration = NativeModelSelectorConfiguration(call.arguments)
            else {
                result(FlutterError(
                    code: "INVALID_ARGS",
                    message: "Missing native model selector configuration",
                    details: nil
                ))
                return
            }
            presentModelSelector(configuration, result: result)

        case "presentOptionsSelector":
            guard let configuration = NativeOptionsSelectorConfiguration(call.arguments)
            else {
                result(FlutterError(
                    code: "INVALID_ARGS",
                    message: "Missing native options selector configuration",
                    details: nil
                ))
                return
            }
            presentOptionsSelector(configuration, result: result)

        case "presentDatePicker":
            guard let configuration = NativeDatePickerConfiguration(call.arguments)
            else {
                result(FlutterError(
                    code: "INVALID_ARGS",
                    message: "Missing native date picker configuration",
                    details: nil
                ))
                return
            }
            presentDatePicker(configuration, result: result)

        case "presentResultSheet":
            guard let configuration = NativeResultSheetConfiguration(call.arguments)
            else {
                result(FlutterError(
                    code: "INVALID_ARGS",
                    message: "Missing native result sheet configuration",
                    details: nil
                ))
                return
            }
            presentResultSheet(configuration, result: result)

        case "applyDetailPatch":
            guard let args = call.arguments as? [String: Any],
                  let detailId = args["detailId"] as? String,
                  let itemsPayload = args["items"] as? [[String: Any]]
            else {
                result(FlutterError(
                    code: "INVALID_ARGS",
                    message: "Missing applyDetailPatch payload",
                    details: nil
                ))
                return
            }
            let items = itemsPayload.compactMap(NativeSheetItem.init)
            let relatedDetails = (args["detailSheets"] as? [[String: Any]] ?? [])
                .compactMap(NativeSheetDetail.init)
            guard let existing = detailPayloads[detailId] else {
                result(false)
                return
            }
            for detail in relatedDetails {
                detailPayloads[detail.id] = detail
            }
            let patched = NativeSheetDetail(
                id: existing.id,
                title: args["title"] as? String ?? existing.title,
                subtitle: args["subtitle"] as? String ?? existing.subtitle,
                items: items
            )
            detailPayloads[detailId] = patched
            if activeDetailTableController?.detailId == detailId {
                activeDetailTableController?.applyUpdatedDetail(patched)
            }
            result(true)

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func presentProfileMenu(_ configuration: NativeSheetConfiguration) -> Bool {
        let controller = NativeProfileMenuTableViewController(
            configuration: configuration,
            onSelect: { [weak self] item in self?.handleSelection(item) },
            onEditProfile: { [weak self] in
                self?.presentEditProfileOverlay()
            },
            onClose: { [weak self] in self?.dismissActive() }
        )
        let navigation = NativeSheetNavigationController(rootViewController: controller)
        return present(navigation)
    }

    private func presentResultSheet(
        _ configuration: NativeResultSheetConfiguration,
        result: @escaping FlutterResult
    ) {
        if pendingResultSheetResult != nil {
            result(FlutterError(
                code: "ALREADY_PRESENTING",
                message: "A native result sheet is already open",
                details: nil
            ))
            return
        }

        activeSheetMode = .resultSheet
        self.configuration = nil
        detailPayloads = configuration.details
        resultSheetValues = configuration.initialValues
        pendingResultSheetResult = result

        let navigation = NativeSheetNavigationController(
            rootViewController: makeDetailController(detail: configuration.root)
        )
        if !present(navigation) {
            let pending = pendingResultSheetResult
            pendingResultSheetResult = nil
            resultSheetValues = [:]
            detailPayloads = [:]
            activeSheetMode = .profileMenu
            pending?(FlutterError(
                code: "PRESENTATION_FAILED",
                message: "Unable to present native result sheet",
                details: nil
            ))
        }
    }

    private func makeDetailController(detail: NativeSheetDetail) -> NativeDetailTableViewController {
        NativeDetailTableViewController(
            detail: detail,
            canNavigate: { [weak self] item in
                self?.detailPayloads[item.id] != nil
            },
            onSelect: { [weak self] item in self?.handleCurrentSheetSelection(item) },
            onControlChanged: { [weak self] item, value in
                self?.handleCurrentSheetControlChanged(item, value: value)
            },
            onClose: { [weak self] in self?.closeActiveSheet() }
        )
    }

    private func presentDetail(id: String) {
        guard let detail = detailPayloads[id] else { return }
        let controller = makeDetailController(detail: detail)

        if let navigation = activeNavigationController {
            navigation.pushViewController(controller, animated: true)
            return
        }

        let navigation = NativeSheetNavigationController(rootViewController: controller)
        _ = present(navigation)
    }

    private func closeActiveSheet() {
        if activeSheetMode == .resultSheet {
            resolvePendingResultSheet(nil)
        }
        dismissActive()
    }

    private func handleCurrentSheetSelection(_ item: NativeSheetItem) {
        switch activeSheetMode {
        case .profileMenu:
            handleSelection(item)
        case .resultSheet:
            handleResultSheetSelection(item)
        }
    }

    private func handleCurrentSheetControlChanged(_ item: NativeSheetItem, value: Any?) {
        switch activeSheetMode {
        case .profileMenu:
            channel?.invokeMethod(
                "onControlChanged",
                arguments: ["id": item.id, "value": value]
            )
        case .resultSheet:
            if let value {
                resultSheetValues[item.id] = value
            } else {
                resultSheetValues.removeValue(forKey: item.id)
            }
        }
    }

    private func presentInlineOptionsSelector(for item: NativeSheetItem) {
        guard let navigation = activeNavigationController else { return }
        let configuration = NativeOptionsSelectorConfiguration(
            title: item.title,
            subtitle: item.subtitle,
            selectedOptionId: item.selectedOptionId,
            searchable: true,
            options: item.options
        )
        let controller = NativeOptionsSelectorTableViewController(
            configuration: configuration,
            onSelect: { [weak self, weak navigation] optionId in
                guard let self else { return }
                self.handleCurrentSheetControlChanged(item, value: optionId)
                navigation?.popViewController(animated: true)
            },
            onClose: { [weak navigation] in
                navigation?.popViewController(animated: true)
            }
        )
        navigation.pushViewController(controller, animated: true)
    }

    private func handleResultSheetSelection(_ item: NativeSheetItem) {
        flushActiveSheetEditing()

        if item.kind == "searchablePicker" {
            presentInlineOptionsSelector(for: item)
            return
        }

        if item.destructive {
            presentDestructiveConfirm(for: item)
            return
        }

        if let url = item.url {
            UIApplication.shared.open(url)
            return
        }

        if detailPayloads[item.id] != nil {
            presentDetail(id: item.id)
            return
        }

        resolvePendingResultSheet([
            "actionId": item.id,
            "values": resultSheetValues
        ])
        dismissActive()
    }

    private func resolvePendingResultSheet(_ payload: Any?) {
        if let pending = pendingResultSheetResult {
            pendingResultSheetResult = nil
            pending(payload)
        }
    }

    private func presentEditProfileOverlay() {
        guard let configuration = configuration else { return }
        guard let presenter = activeNavigationController?.visibleViewController else { return }

        let overlay = NativeEditProfileSheetViewController(
            profile: configuration.profile,
            copy: configuration.editProfileSheet,
            onCommit: { [weak self] payload in
                self?.channel?.invokeMethod("commitEditProfile", arguments: payload)
            }
        )
        let navigation = NativeSheetNavigationController(rootViewController: overlay)
        navigation.modalPresentationStyle = .pageSheet
        applySheetStyle(to: navigation)
        presenter.present(navigation, animated: true)
    }

    private func present(_ controller: UIViewController) -> Bool {
        guard let presenter = topViewController() else { return false }
        activeController = controller
        presentationDelegate = NativeSheetPresentationDelegate(
            onWillDismiss: { [weak self] in
                self?.flushActiveSheetEditing()
            },
            onDismiss: { [weak self] in
                if let pending = self?.pendingModelSelectorResult {
                    self?.pendingModelSelectorResult = nil
                    pending(nil)
                }
                if let pending = self?.pendingOptionsSelectorResult {
                    self?.pendingOptionsSelectorResult = nil
                    pending(nil)
                }
                if let pending = self?.pendingResultSheetResult {
                    self?.pendingResultSheetResult = nil
                    pending(nil)
                }
                self?.activeController = nil
                self?.presentationDelegate = nil
                self?.activeDetailTableController = nil
                self?.detailPayloads = [:]
                self?.resultSheetValues = [:]
                let shouldNotifyDismiss = self?.activeSheetMode == .profileMenu
                self?.activeSheetMode = .profileMenu
                if shouldNotifyDismiss == true {
                    self?.channel?.invokeMethod("onDismissed", arguments: nil)
                }
            }
        )

        controller.modalPresentationStyle = .pageSheet
        controller.presentationController?.delegate = presentationDelegate
        applySheetStyle(to: controller)
        presenter.present(controller, animated: true)
        return true
    }

    private func presentModelSelector(
        _ configuration: NativeModelSelectorConfiguration,
        result: @escaping FlutterResult
    ) {
        if pendingModelSelectorResult != nil {
            result(FlutterError(
                code: "ALREADY_PRESENTING",
                message: "A native model selector is already open",
                details: nil
            ))
            return
        }

        activeSheetMode = .resultSheet
        pendingModelSelectorResult = result
        let controller = NativeModelSelectorTableViewController(
            configuration: configuration,
            onSelect: { [weak self] modelId in
                guard let self else { return }
                let pending = self.pendingModelSelectorResult
                self.pendingModelSelectorResult = nil
                self.activeController?.dismiss(animated: true)
                self.activeController = nil
                self.presentationDelegate = nil
                self.activeDetailTableController = nil
                self.detailPayloads = [:]
                self.resultSheetValues = [:]
                self.activeSheetMode = .profileMenu
                pending?(modelId)
            },
            onClose: { [weak self] in
                guard let self else { return }
                let pending = self.pendingModelSelectorResult
                self.pendingModelSelectorResult = nil
                self.dismissActive()
                pending?(nil)
            }
        )
        let navigation = NativeSheetNavigationController(rootViewController: controller)

        if !present(navigation) {
            pendingModelSelectorResult = nil
            activeSheetMode = .profileMenu
            result(FlutterError(
                code: "PRESENTATION_FAILED",
                message: "Unable to present native model selector",
                details: nil
            ))
        }
    }

    private func presentOptionsSelector(
        _ configuration: NativeOptionsSelectorConfiguration,
        result: @escaping FlutterResult
    ) {
        if pendingOptionsSelectorResult != nil {
            result(FlutterError(
                code: "ALREADY_PRESENTING",
                message: "A native options selector is already open",
                details: nil
            ))
            return
        }

        activeSheetMode = .resultSheet
        pendingOptionsSelectorResult = result
        let controller = NativeOptionsSelectorTableViewController(
            configuration: configuration,
            onSelect: { [weak self] optionId in
                guard let self else { return }
                let pending = self.pendingOptionsSelectorResult
                self.pendingOptionsSelectorResult = nil
                self.activeController?.dismiss(animated: true)
                self.activeController = nil
                self.presentationDelegate = nil
                self.activeDetailTableController = nil
                self.detailPayloads = [:]
                self.resultSheetValues = [:]
                self.activeSheetMode = .profileMenu
                pending?(optionId)
            },
            onClose: { [weak self] in
                guard let self else { return }
                let pending = self.pendingOptionsSelectorResult
                self.pendingOptionsSelectorResult = nil
                self.dismissActive()
                pending?(nil)
            }
        )
        let navigation = NativeSheetNavigationController(rootViewController: controller)
        if !present(navigation) {
            pendingOptionsSelectorResult = nil
            activeSheetMode = .profileMenu
            result(FlutterError(
                code: "PRESENTATION_FAILED",
                message: "Unable to present native options selector",
                details: nil
            ))
        }
    }

    private func presentDatePicker(
        _ configuration: NativeDatePickerConfiguration,
        result: @escaping FlutterResult
    ) {
        activeSheetMode = .resultSheet
        let controller = NativeDatePickerViewController(
            configuration: configuration,
            onConfirm: { [weak self] date in
                result(nativeSheetFormatDate(date))
                self?.dismissActive()
            },
            onClose: { [weak self] in
                result(nil)
                self?.dismissActive()
            }
        )
        let navigation = NativeSheetNavigationController(rootViewController: controller)
        if !present(navigation) {
            activeSheetMode = .profileMenu
            result(FlutterError(
                code: "PRESENTATION_FAILED",
                message: "Unable to present native date picker",
                details: nil
            ))
        }
    }

    private func applySheetStyle(to controller: UIViewController) {
        guard let sheet = controller.sheetPresentationController else { return }
        sheet.detents = [.medium(), .large()]
        sheet.prefersGrabberVisible = true
        sheet.prefersScrollingExpandsWhenScrolledToEdge = true
        sheet.prefersEdgeAttachedInCompactHeight = true
        sheet.widthFollowsPreferredContentSizeWhenEdgeAttached = true
    }

    private func handleSelection(_ item: NativeSheetItem) {
        if item.kind == "searchablePicker" {
            presentInlineOptionsSelector(for: item)
            return
        }

        if item.id == "sign-out" {
            dismissActive()
            channel?.invokeMethod("onLogoutRequested", arguments: nil)
            return
        }

        if item.id == "profile-details" {
            presentEditProfileOverlay()
            return
        }

        if item.destructive,
           item.id == "memory-clear-all" || item.id.hasPrefix("memory-delete:") {
            presentDestructiveConfirm(for: item)
            return
        }

        if let url = item.url {
            UIApplication.shared.open(url)
            return
        }

        if detailPayloads[item.id] != nil {
            presentDetail(id: item.id)
            return
        }

        channel?.invokeMethod(
            "onControlChanged",
            arguments: ["id": item.id, "value": item.value ?? true]
        )
    }

    private func presentDestructiveConfirm(for item: NativeSheetItem) {
        guard let presenter = activeNavigationController?.visibleViewController else {
            switch activeSheetMode {
            case .profileMenu:
                channel?.invokeMethod(
                    "onControlChanged",
                    arguments: ["id": item.id, "value": true]
                )
            case .resultSheet:
                resolvePendingResultSheet([
                    "actionId": item.id,
                    "values": resultSheetValues
                ])
                dismissActive()
            }
            return
        }

        let alert = UIAlertController(
            title: item.title,
            message: item.subtitle,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: item.title, style: .destructive) { [weak self] _ in
            guard let self else { return }
            switch self.activeSheetMode {
            case .profileMenu:
                self.channel?.invokeMethod(
                    "onControlChanged",
                    arguments: ["id": item.id, "value": true]
                )
            case .resultSheet:
                self.resolvePendingResultSheet([
                    "actionId": item.id,
                    "values": self.resultSheetValues
                ])
                self.dismissActive()
            }
        })
        presenter.present(alert, animated: true)
    }

    private func flushActiveSheetEditing() {
        activeController?.view.endEditing(true)
        activeNavigationController?.view.endEditing(true)
    }

    private func dismissActive() {
        flushActiveSheetEditing()
        activeController?.dismiss(animated: true)
        activeController = nil
        presentationDelegate = nil
        activeDetailTableController = nil
        detailPayloads = [:]
        resultSheetValues = [:]
        if let pending = pendingModelSelectorResult {
            pendingModelSelectorResult = nil
            pending(nil)
        }
        if let pending = pendingOptionsSelectorResult {
            pendingOptionsSelectorResult = nil
            pending(nil)
        }
        if let pending = pendingResultSheetResult {
            pendingResultSheetResult = nil
            pending(nil)
        }
        activeSheetMode = .profileMenu
    }

    private var activeNavigationController: UINavigationController? {
        activeController as? UINavigationController
    }

    private func topViewController() -> UIViewController? {
        let root = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }?
            .rootViewController

        return topViewController(from: root)
    }

    private func topViewController(from root: UIViewController?) -> UIViewController? {
        if let navigation = root as? UINavigationController {
            return topViewController(from: navigation.visibleViewController)
        }
        if let tab = root as? UITabBarController {
            return topViewController(from: tab.selectedViewController)
        }
        if let presented = root?.presentedViewController {
            return topViewController(from: presented)
        }
        return root
    }

    fileprivate func markDetailVisible(_ controller: NativeDetailTableViewController) {
        activeDetailTableController = controller
        guard activeSheetMode == .profileMenu else { return }
        channel?.invokeMethod(
            "onDetailAppeared",
            arguments: ["detailId": controller.detailId]
        )
    }
}

// MARK: - Edit profile helpers (Flutter account_settings_page parity)

private func nativeExtractInitials(from name: String) -> String {
    let parts = name
        .components(separatedBy: .whitespacesAndNewlines)
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    if parts.isEmpty { return "U" }
    if parts.count == 1 {
        let w = parts[0]
        return String(w.prefix(w.count >= 2 ? 2 : 1)).uppercased()
    }
    let a = parts[0].first!
    let b = parts[1].first!
    return "\(a)\(b)".uppercased()
}

private func nativeAvatarAccentColor(seed: String) -> UIColor {
    let normalized = seed.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    var hash: UInt32 = 5381
    for byte in normalized.utf8 {
        hash = ((hash << 5) &+ hash) &+ UInt32(byte)
    }
    let hue = CGFloat(hash % 360) / 360.0
    return UIColor(hue: hue, saturation: 0.55, brightness: 0.52, alpha: 1)
}

private func nativeInitialsAvatarUIImage(name: String, diameter: CGFloat = 250) -> UIImage? {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let seed = trimmed.isEmpty ? "user" : trimmed
    let initials = nativeExtractInitials(from: trimmed.isEmpty ? "User" : trimmed)
    let fill = nativeAvatarAccentColor(seed: seed)
    let size = CGSize(width: diameter, height: diameter)
    let renderer = UIGraphicsImageRenderer(size: size)
    return renderer.image { ctx in
        let rect = CGRect(origin: .zero, size: size)
        ctx.cgContext.addEllipse(in: rect)
        ctx.cgContext.setFillColor(fill.cgColor)
        ctx.cgContext.fillPath()

        let fontSize = diameter * 0.35
        let font = UIFont.systemFont(ofSize: fontSize, weight: .bold)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor.white,
            .paragraphStyle: paragraph,
        ]
        let text = NSString(string: initials)
        let bounds = text.boundingRect(
            with: size,
            options: [.usesLineFragmentOrigin],
            attributes: attrs,
            context: nil
        )
        let drawRect = CGRect(
            x: (diameter - bounds.width) / 2,
            y: (diameter - bounds.height) / 2,
            width: bounds.width,
            height: bounds.height
        )
        text.draw(in: drawRect, withAttributes: attrs)
    }
}

private func nativeInitialsAvatarDataUrl(name: String, diameter: CGFloat = 250) -> String? {
    guard let image = nativeInitialsAvatarUIImage(name: name, diameter: diameter) else { return nil }
    guard let data = image.pngData() else { return nil }
    return "data:image/png;base64," + data.base64EncodedString()
}

private func nativeFormatBirthDateIso(_ date: Date) -> String {
    let cal = Calendar(identifier: .gregorian)
    let c = cal.dateComponents([.year, .month, .day], from: date)
    guard let y = c.year, let m = c.month, let d = c.day else { return "" }
    return String(format: "%04d-%02d-%02d", y, m, d)
}

private func nativeParseBirthDateIso(_ raw: String) -> Date? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return nil }
    let parts = trimmed.split(separator: "-").compactMap { Int($0) }
    guard parts.count == 3 else { return nil }
    var dc = DateComponents()
    dc.year = parts[0]
    dc.month = parts[1]
    dc.day = parts[2]
    return Calendar(identifier: .gregorian).date(from: dc)
}

// MARK: - Native edit profile overlay (stacked sheet)

private final class NativeEditProfileSheetViewController: UIViewController, PHPickerViewControllerDelegate {
    private enum AvatarIntent {
        case unchanged
        case pickedJPEG(Data)
        case initialsGenerated
        case removed
    }

    private let profile: NativeSheetProfile
    private let copy: NativeEditProfileSheetCopy
    private let onCommit: ([String: Any]) -> Void

    private var avatarIntent: AvatarIntent = .unchanged
    private let avatarView: NativeAvatarView
    private let cameraButton = UIButton(type: .system)

    private let nameField = UITextField()
    private let bioField = UITextView()
    private let genderButton = UIButton(type: .system)
    private let customGenderField = UITextField()
    private let customGenderContainer = UIStackView()

    private let birthPicker = UIDatePicker()
    private let clearBirthButton = UIButton(type: .system)

    private var selectedGenderKey = ""
    private var birthIso: String

    init(
        profile: NativeSheetProfile,
        copy: NativeEditProfileSheetCopy,
        onCommit: @escaping ([String: Any]) -> Void
    ) {
        self.profile = profile
        self.copy = copy
        self.onCommit = onCommit
        self.avatarView = NativeAvatarView(profile: profile, diameter: 104)
        self.birthIso = profile.dateOfBirth?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        super.init(nibName: nil, bundle: nil)
        applyGenderSelectionFromProfile()
    }

    required init?(coder: NSCoder) {
        nil
    }

    private func applyGenderSelectionFromProfile() {
        let g = profile.gender.trimmingCharacters(in: .whitespacesAndNewlines)
        if g.isEmpty {
            selectedGenderKey = ""
            customGenderField.text = ""
            return
        }
        if g == "male" || g == "female" {
            selectedGenderKey = g
            customGenderField.text = ""
            return
        }
        selectedGenderKey = "custom"
        customGenderField.text = g
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        navigationItem.title = copy.title
        navigationItem.largeTitleDisplayMode = .never

        nameField.text = profile.displayName

        bioField.font = .preferredFont(forTextStyle: .body)
        bioField.adjustsFontForContentSizeCategory = true
        bioField.backgroundColor = .secondarySystemFill
        bioField.layer.cornerRadius = 12
        bioField.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        bioField.text = profile.bio

        customGenderField.borderStyle = .none
        customGenderField.backgroundColor = .secondarySystemFill
        customGenderField.layer.cornerRadius = 22
        customGenderField.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 16, height: 44))
        customGenderField.leftViewMode = .always
        customGenderField.font = .preferredFont(forTextStyle: .body)

        let avatarCaption = UILabel()
        avatarCaption.text = copy.currentAvatarLabel
        avatarCaption.font = .preferredFont(forTextStyle: .caption1)
        avatarCaption.textColor = .secondaryLabel

        let avatarWrap = UIView()
        avatarWrap.translatesAutoresizingMaskIntoConstraints = false
        avatarWrap.addSubview(avatarView)

        configureCameraButton()
        avatarWrap.addSubview(cameraButton)

        NSLayoutConstraint.activate([
            avatarView.centerXAnchor.constraint(equalTo: avatarWrap.centerXAnchor),
            avatarView.topAnchor.constraint(equalTo: avatarWrap.topAnchor),
            avatarView.bottomAnchor.constraint(equalTo: avatarWrap.bottomAnchor),
            cameraButton.widthAnchor.constraint(equalToConstant: 36),
            cameraButton.heightAnchor.constraint(equalToConstant: 36),
            cameraButton.trailingAnchor.constraint(equalTo: avatarView.trailingAnchor, constant: 4),
            cameraButton.bottomAnchor.constraint(equalTo: avatarView.bottomAnchor, constant: 4),
        ])

        let avatarActions = UIStackView()
        avatarActions.axis = .horizontal
        avatarActions.spacing = 8
        avatarActions.distribution = .fillEqually
        avatarActions.addArrangedSubview(
            makeSecondaryAction(title: copy.uploadFromDeviceLabel, symbol: "photo.on.rectangle") { [weak self] in
                self?.presentPhotoPicker()
            }
        )
        avatarActions.addArrangedSubview(
            makeSecondaryAction(title: copy.useInitialsLabel, symbol: "textformat.abc") { [weak self] in
                self?.useInitialsTapped()
            }
        )
        avatarActions.addArrangedSubview(
            makeSecondaryAction(title: copy.removeAvatarLabel, symbol: "trash") { [weak self] in
                self?.removeAvatarTapped()
            }
        )

        let bioCaption = UILabel()
        bioCaption.text = copy.bioLabel
        bioCaption.font = .preferredFont(forTextStyle: .caption1)
        bioCaption.textColor = .secondaryLabel

        let bioStack = UIStackView(arrangedSubviews: [bioCaption, bioField])
        bioStack.axis = .vertical
        bioStack.spacing = 6
        bioField.heightAnchor.constraint(greaterThanOrEqualToConstant: 100).isActive = true

        configureBirthPicker()

        let genderCaption = UILabel()
        genderCaption.text = copy.genderLabel
        genderCaption.font = .preferredFont(forTextStyle: .caption1)
        genderCaption.textColor = .secondaryLabel

        var genderCfg = UIButton.Configuration.bordered()
        genderCfg.titleAlignment = .leading
        genderButton.configuration = genderCfg
        genderButton.contentHorizontalAlignment = .leading
        configureGenderControls()

        let genderStack = UIStackView(arrangedSubviews: [genderCaption, genderButton])
        genderStack.axis = .vertical
        genderStack.spacing = 6

        let customCaption = UILabel()
        customCaption.text = copy.customGenderLabel
        customCaption.font = .preferredFont(forTextStyle: .caption1)
        customCaption.textColor = .secondaryLabel

        customGenderContainer.axis = .vertical
        customGenderContainer.spacing = 6
        customGenderContainer.isHidden = true
        customGenderContainer.addArrangedSubview(customCaption)
        customGenderContainer.addArrangedSubview(customGenderField)

        let birthCaption = UILabel()
        birthCaption.text = copy.birthDateLabel
        birthCaption.font = .preferredFont(forTextStyle: .caption1)
        birthCaption.textColor = .secondaryLabel

        clearBirthButton.setTitle(copy.clearLabel, for: .normal)
        clearBirthButton.titleLabel?.font = .preferredFont(forTextStyle: .subheadline)
        clearBirthButton.addAction(UIAction { [weak self] _ in self?.clearBirthTapped() }, for: .touchUpInside)

        let birthRow = UIStackView(arrangedSubviews: [birthPicker, clearBirthButton])
        birthRow.axis = .horizontal
        birthRow.spacing = 12
        birthRow.alignment = .center

        let birthStack = UIStackView(arrangedSubviews: [birthCaption, birthRow])
        birthStack.axis = .vertical
        birthStack.spacing = 8

        let footer = UILabel()
        footer.text = copy.footerText
        footer.font = .preferredFont(forTextStyle: .footnote)
        footer.textColor = .secondaryLabel
        footer.textAlignment = .center
        footer.numberOfLines = 0

        var saveCfg = UIButton.Configuration.filled()
        saveCfg.title = copy.saveLabel
        saveCfg.cornerStyle = .capsule
        let saveButton = UIButton(configuration: saveCfg)
        saveButton.addAction(UIAction { [weak self] _ in self?.saveTapped() }, for: .touchUpInside)

        var cancelCfg = UIButton.Configuration.plain()
        cancelCfg.title = copy.cancelLabel
        let cancelButton = UIButton(configuration: cancelCfg)
        cancelButton.addAction(UIAction { [weak self] _ in self?.dismiss(animated: true) }, for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [
            avatarCaption,
            avatarWrap,
            avatarActions,
            Self.labeledSingleLineRow(
                caption: copy.nameLabel,
                field: nameField,
                text: profile.displayName,
                placeholder: copy.nameLabel
            ),
            bioStack,
            genderStack,
            customGenderContainer,
            birthStack,
            footer,
            saveButton,
            cancelButton,
        ])
        stack.axis = .vertical
        stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setCustomSpacing(8, after: saveButton)

        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.alwaysBounceVertical = true
        scroll.keyboardDismissMode = .interactive
        scroll.addSubview(stack)
        view.addSubview(scroll)

        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -24),
        ])
    }

    private func configureCameraButton() {
        var cfg = UIButton.Configuration.filled()
        cfg.image = UIImage(systemName: "camera.fill")
        cfg.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        cfg.cornerStyle = .capsule
        cfg.baseForegroundColor = UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor.black : UIColor.white
        }
        cfg.baseBackgroundColor = UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(white: 0.92, alpha: 1)
                : UIColor(white: 0.14, alpha: 1)
        }
        cameraButton.configuration = cfg
        cameraButton.translatesAutoresizingMaskIntoConstraints = false
        cameraButton.accessibilityLabel = copy.uploadFromDeviceLabel
        cameraButton.addAction(UIAction { [weak self] _ in self?.presentPhotoPicker() }, for: .touchUpInside)
    }

    private func makeSecondaryAction(
        title: String,
        symbol: String,
        handler: @escaping () -> Void
    ) -> UIButton {
        var cfg = UIButton.Configuration.gray()
        cfg.title = title
        cfg.image = UIImage(systemName: symbol)
        cfg.imagePlacement = .top
        cfg.imagePadding = 4
        cfg.cornerStyle = .medium
        let b = UIButton(configuration: cfg)
        b.titleLabel?.font = .preferredFont(forTextStyle: .caption1)
        b.titleLabel?.numberOfLines = 2
        b.titleLabel?.textAlignment = .center
        b.addAction(UIAction { _ in handler() }, for: .touchUpInside)
        return b
    }

    private func configureBirthPicker() {
        birthPicker.datePickerMode = .date
        birthPicker.preferredDatePickerStyle = .compact
        birthPicker.maximumDate = Date()
        if let min = Calendar.current.date(from: DateComponents(year: 1900, month: 1, day: 1)) {
            birthPicker.minimumDate = min
        }
        if let d = nativeParseBirthDateIso(birthIso) {
            birthPicker.date = d
        } else {
            birthPicker.date =
                Calendar.current.date(from: DateComponents(year: 1990, month: 1, day: 1)) ?? Date()
        }
        birthPicker.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.birthIso = nativeFormatBirthDateIso(self.birthPicker.date)
        }, for: .valueChanged)
    }

    private func clearBirthTapped() {
        birthIso = ""
        if let d = Calendar.current.date(from: DateComponents(year: 1990, month: 1, day: 1)) {
            birthPicker.date = d
        }
    }

    private func configureGenderControls() {
        genderButton.showsMenuAsPrimaryAction = true
        genderButton.changesSelectionAsPrimaryAction = true
        rebuildGenderMenu()
    }

    private func rebuildGenderMenu() {
        let options: [(String, String)] = [
            ("", copy.genderPreferNotToSay),
            ("male", copy.genderMale),
            ("female", copy.genderFemale),
            ("custom", copy.genderCustom),
        ]
        genderButton.menu = UIMenu(children: options.map { id, label in
            UIAction(title: label, state: id == selectedGenderKey ? .on : .off) { [weak self] _ in
                self?.selectedGenderKey = id
                self?.refreshGenderTitle()
                self?.refreshCustomGenderVisibility()
            }
        })
        refreshGenderTitle()
        refreshCustomGenderVisibility()
    }

    private func refreshGenderTitle() {
        var cfg = genderButton.configuration ?? .bordered()
        cfg.title = genderTitle(for: selectedGenderKey)
        genderButton.configuration = cfg
    }

    private func genderTitle(for key: String) -> String {
        switch key {
        case "male":
            return copy.genderMale
        case "female":
            return copy.genderFemale
        case "custom":
            return copy.genderCustom
        default:
            return copy.genderPreferNotToSay
        }
    }

    private func refreshCustomGenderVisibility() {
        customGenderContainer.isHidden = selectedGenderKey != "custom"
        customGenderField.placeholder = copy.customGenderHint
    }

    private static func labeledSingleLineRow(
        caption: String,
        field: UITextField,
        text: String,
        placeholder: String
    ) -> UIStackView {
        let cap = UILabel()
        cap.text = caption
        cap.font = .preferredFont(forTextStyle: .caption1)
        cap.textColor = .secondaryLabel

        field.text = text
        field.placeholder = placeholder
        field.font = .preferredFont(forTextStyle: .body)
        field.adjustsFontForContentSizeCategory = true
        field.borderStyle = .none
        field.backgroundColor = .secondarySystemFill
        field.layer.cornerRadius = 22
        field.clipsToBounds = true
        field.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        field.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 16, height: 44))
        field.leftViewMode = .always
        field.rightView = UIView(frame: CGRect(x: 0, y: 0, width: 16, height: 44))
        field.rightViewMode = .always

        let pair = UIStackView(arrangedSubviews: [cap, field])
        pair.axis = .vertical
        pair.spacing = 6
        pair.alignment = .fill
        return pair
    }

    private func presentPhotoPicker() {
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = 1
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = self
        present(picker, animated: true)
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard let provider = results.first?.itemProvider,
              provider.canLoadObject(ofClass: UIImage.self) else {
            return
        }
        provider.loadObject(ofClass: UIImage.self) { [weak self] object, _ in
            DispatchQueue.main.async {
                guard let image = object as? UIImage else { return }
                let toCompress = image.preparingThumbnailSide(1024) ?? image
                guard let data = toCompress.jpegData(compressionQuality: 0.85) else { return }
                self?.avatarIntent = .pickedJPEG(data)
                self?.avatarView.setPickedPreview(toCompress)
            }
        }
    }

    private func useInitialsTapped() {
        let name =
            nameField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? profile.displayName
        avatarIntent = .initialsGenerated
        if let img = nativeInitialsAvatarUIImage(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? profile.displayName
                : name
        ) {
            avatarView.setPickedPreview(img)
        }
    }

    private func removeAvatarTapped() {
        avatarIntent = .removed
        avatarView.showRemovedPlaceholder()
    }

    private func resolvedProfileImageUrl(name: String) -> String {
        switch avatarIntent {
        case .unchanged:
            return profile.savedProfileImageUrl ?? ""
        case .pickedJPEG(let data):
            return "data:image/jpeg;base64," + data.base64EncodedString()
        case .initialsGenerated:
            return nativeInitialsAvatarDataUrl(name: name) ?? ""
        case .removed:
            return "/user.png"
        }
    }

    private func resolvedGenderPayload() -> String {
        switch selectedGenderKey {
        case "male", "female":
            return selectedGenderKey
        case "custom":
            return customGenderField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        default:
            return ""
        }
    }

    private func saveTapped() {
        let name = nameField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if name.isEmpty {
            presentValidationAlert(message: copy.nameRequiredMessage)
            return
        }
        if selectedGenderKey == "custom",
           customGenderField.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
            presentValidationAlert(message: copy.customGenderRequiredMessage)
            return
        }

        let payload: [String: Any] = [
            "name": name,
            "profileImageUrl": resolvedProfileImageUrl(name: name),
            "bio": bioField.text ?? "",
            "gender": resolvedGenderPayload(),
            "dateOfBirth": birthIso.trimmingCharacters(in: .whitespacesAndNewlines),
        ]
        onCommit(payload)
        dismiss(animated: true)
    }

    private func presentValidationAlert(message: String) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}

private extension UIImage {
    func preparingThumbnailSide(_ maxSide: CGFloat) -> UIImage? {
        let w = size.width
        let h = size.height
        guard w > 0, h > 0 else { return nil }
        let scale = min(maxSide / w, maxSide / h, 1)
        if scale >= 1 { return self }
        let nw = w * scale
        let nh = h * scale
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: nw, height: nh))
        return renderer.image { _ in
            draw(in: CGRect(x: 0, y: 0, width: nw, height: nh))
        }
    }
}

private final class NativeSheetNavigationController: UINavigationController {
    override func viewDidLoad() {
        super.viewDidLoad()
        modalPresentationStyle = .pageSheet
    }
}

private final class NativeProfileMenuTableViewController: UITableViewController {
    private enum Section: Int, CaseIterable {
        case menu
        case destructive
        case support
    }

    private let configuration: NativeSheetConfiguration
    private let onSelect: (NativeSheetItem) -> Void
    private let onEditProfile: () -> Void
    private let onClose: () -> Void

    private var menuItems: [NativeSheetItem] {
        configuration.menuItems.filter { !$0.destructive }
    }

    private var destructiveItems: [NativeSheetItem] {
        configuration.menuItems.filter(\.destructive)
    }

    private var visibleSections: [Section] {
        var sections: [Section] = [.menu]
        if !destructiveItems.isEmpty {
            sections.append(.destructive)
        }
        if !configuration.supportItems.isEmpty {
            sections.append(.support)
        }
        return sections
    }

    init(
        configuration: NativeSheetConfiguration,
        onSelect: @escaping (NativeSheetItem) -> Void,
        onEditProfile: @escaping () -> Void,
        onClose: @escaping () -> Void
    ) {
        self.configuration = configuration
        self.onSelect = onSelect
        self.onEditProfile = onEditProfile
        self.onClose = onClose
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = configuration.profileMenuTitle
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.rightBarButtonItem = closeButton()
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        NativeSheetSettingsStyle.apply(to: tableView)
        tableView.tableHeaderView = profileHeader()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateHeaderSize()
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        visibleSections.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch visibleSections[section] {
        case .menu:
            return menuItems.count
        case .destructive:
            return destructiveItems.count
        case .support:
            return configuration.supportItems.count
        }
    }

    override func tableView(
        _ tableView: UITableView,
        titleForHeaderInSection section: Int
    ) -> String? {
        guard visibleSections[section] == .support else { return nil }
        return configuration.supportTitle
    }

    override func tableView(
        _ tableView: UITableView,
        titleForFooterInSection section: Int
    ) -> String? {
        guard visibleSections[section] == .support else { return nil }
        return configuration.supportSubtitle
    }

    override func tableView(
        _ tableView: UITableView,
        willDisplayHeaderView view: UIView,
        forSection section: Int
    ) {
        NativeSheetSettingsStyle.applyHeaderFooterStyle(view)
    }

    override func tableView(
        _ tableView: UITableView,
        willDisplayFooterView view: UIView,
        forSection section: Int
    ) {
        NativeSheetSettingsStyle.applyHeaderFooterStyle(view)
    }

    override func tableView(
        _ tableView: UITableView,
        cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        let item = item(at: indexPath)
        configureNavigationCell(
            cell,
            item: item,
            showsDisclosure: shouldShowDisclosure(for: item)
        )
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        onSelect(item(at: indexPath))
    }

    private func item(at indexPath: IndexPath) -> NativeSheetItem {
        switch visibleSections[indexPath.section] {
        case .support:
            return configuration.supportItems[indexPath.row]
        case .destructive:
            return destructiveItems[indexPath.row]
        default:
            return menuItems[indexPath.row]
        }
    }

    private func shouldShowDisclosure(for item: NativeSheetItem) -> Bool {
        item.url != nil || configuration.details[item.id] != nil
    }

    private func profileHeader() -> UIView {
        let container = UIView()
        let stack = UIStackView()
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)

        let avatar = NativeAvatarView(profile: configuration.profile, diameter: 72)
        stack.addArrangedSubview(avatar)

        let nameLabel = UILabel()
        nameLabel.text = configuration.profile.displayName
        nameLabel.font = .preferredFont(forTextStyle: .title3)
        nameLabel.adjustsFontForContentSizeCategory = true
        nameLabel.textAlignment = .center
        nameLabel.textColor = .label
        stack.addArrangedSubview(nameLabel)

        let emailLabel = UILabel()
        emailLabel.text = configuration.profile.email
        emailLabel.font = .preferredFont(forTextStyle: .footnote)
        emailLabel.adjustsFontForContentSizeCategory = true
        emailLabel.textAlignment = .center
        emailLabel.textColor = .secondaryLabel
        stack.addArrangedSubview(emailLabel)

        var editCfg = UIButton.Configuration.gray()
        editCfg.title = configuration.editProfileLabel
        editCfg.cornerStyle = .capsule
        editCfg.buttonSize = .small
        editCfg.baseForegroundColor = view.tintColor
        let editButton = UIButton(configuration: editCfg)
        editButton.addAction(UIAction { [weak self] _ in self?.onEditProfile() }, for: .touchUpInside)
        stack.addArrangedSubview(editButton)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
        ])

        container.frame.size = CGSize(width: tableView.bounds.width, height: 154)
        return container
    }

    private func updateHeaderSize() {
        guard let header = tableView.tableHeaderView else { return }
        let targetSize = CGSize(
            width: tableView.bounds.width,
            height: UIView.layoutFittingCompressedSize.height
        )
        let size = header.systemLayoutSizeFitting(
            targetSize,
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        guard header.frame.width != targetSize.width || header.frame.height != size.height
        else { return }

        header.frame.size = CGSize(width: targetSize.width, height: size.height)
        tableView.tableHeaderView = header
    }

    private func closeButton() -> UIBarButtonItem {
        UIBarButtonItem(
            systemItem: .close,
            primaryAction: UIAction { [weak self] _ in self?.onClose() }
        )
    }
}

private final class NativeSheetSegmentTableViewCell: UITableViewCell {
    static let reuseId = "NativeSheetSegmentTableViewCell"

    private let stack = UIStackView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let segmentedControl = UISegmentedControl()
    private var boundOptions: [NativeSheetOption] = []
    private var valueChanged: ((String) -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        NativeSheetSettingsStyle.applyCellStyle(self)
        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .preferredFont(forTextStyle: .body)
        titleLabel.numberOfLines = 0
        subtitleLabel.font = .preferredFont(forTextStyle: .footnote)
        subtitleLabel.textColor = .secondaryLabel
        subtitleLabel.numberOfLines = 0
        segmentedControl.selectedSegmentTintColor = .tintColor
        contentView.addSubview(stack)
        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(subtitleLabel)
        stack.addArrangedSubview(segmentedControl)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 11),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -11),
        ])
        segmentedControl.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            let idx = self.segmentedControl.selectedSegmentIndex
            guard idx >= 0, idx < self.boundOptions.count else { return }
            self.valueChanged?(self.boundOptions[idx].id)
        }, for: .valueChanged)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        valueChanged = nil
        boundOptions = []
    }

    func configure(item: NativeSheetItem, onValueChanged: @escaping (String) -> Void) {
        titleLabel.text = item.title
        if let subtitle = item.subtitle, !subtitle.isEmpty {
            subtitleLabel.text = subtitle
            subtitleLabel.isHidden = false
        } else {
            subtitleLabel.isHidden = true
        }
        boundOptions = item.options
        while segmentedControl.numberOfSegments > 0 {
            segmentedControl.removeSegment(at: 0, animated: false)
        }
        for (idx, opt) in item.options.enumerated() {
            segmentedControl.insertSegment(withTitle: opt.label, at: idx, animated: false)
        }
        let selectedId = item.value as? String
        if let ix = item.options.firstIndex(where: { $0.id == selectedId }) {
            segmentedControl.selectedSegmentIndex = ix
        } else if !item.options.isEmpty {
            segmentedControl.selectedSegmentIndex = 0
        }
        valueChanged = onValueChanged
    }
}

private final class NativeSheetDropdownTableViewCell: UITableViewCell {
    static let reuseId = "NativeSheetDropdownTableViewCell"

    private let rowStack = UIStackView()
    private let iconView = UIImageView()
    private let textStack = UIStackView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let button = UIButton(type: .system)
    private var boundOptions: [NativeSheetOption] = []
    private var valueChanged: ((String) -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        NativeSheetSettingsStyle.applyCellStyle(self)

        rowStack.axis = .horizontal
        rowStack.alignment = .center
        rowStack.spacing = NativeSheetSettingsStyle.iconSpacing
        rowStack.translatesAutoresizingMaskIntoConstraints = false

        textStack.axis = .vertical
        textStack.spacing = 2
        textStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        iconView.tintColor = .secondaryLabel
        iconView.contentMode = .scaleAspectFit
        iconView.setContentHuggingPriority(.required, for: .horizontal)

        titleLabel.font = .preferredFont(forTextStyle: .body)
        titleLabel.textColor = .label
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.numberOfLines = 1

        subtitleLabel.font = .preferredFont(forTextStyle: .footnote)
        subtitleLabel.textColor = .secondaryLabel
        subtitleLabel.adjustsFontForContentSizeCategory = true
        subtitleLabel.numberOfLines = 1

        button.titleLabel?.font = .preferredFont(forTextStyle: .body)
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        button.tintColor = .secondaryLabel
        button.contentHorizontalAlignment = .trailing
        button.showsMenuAsPrimaryAction = true
        button.changesSelectionAsPrimaryAction = true
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        button.setContentHuggingPriority(.required, for: .horizontal)

        contentView.addSubview(rowStack)
        rowStack.addArrangedSubview(iconView)
        rowStack.addArrangedSubview(textStack)
        rowStack.addArrangedSubview(button)
        textStack.addArrangedSubview(titleLabel)
        textStack.addArrangedSubview(subtitleLabel)

        NSLayoutConstraint.activate([
            rowStack.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            rowStack.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            rowStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 11),
            rowStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -11),
            iconView.widthAnchor.constraint(equalToConstant: NativeSheetSettingsStyle.iconSize),
            iconView.heightAnchor.constraint(equalToConstant: NativeSheetSettingsStyle.iconSize),
            button.widthAnchor.constraint(lessThanOrEqualToConstant: 180),
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        boundOptions = []
        valueChanged = nil
        button.menu = nil
    }

    func configure(item: NativeSheetItem, onValueChanged: @escaping (String) -> Void) {
        titleLabel.text = item.title
        subtitleLabel.text = item.subtitle
        subtitleLabel.isHidden = item.subtitle?.isEmpty ?? true
        iconView.image = UIImage(systemName: item.sfSymbol)?.withConfiguration(
            UIImage.SymbolConfiguration(
                pointSize: NativeSheetSettingsStyle.iconSize,
                weight: .regular
            )
        )

        boundOptions = item.options
        valueChanged = onValueChanged
        let selectedId = (item.value as? String) ?? item.options.first?.id
        setSelectedTitle(Self.optionLabel(selectedId: selectedId, options: item.options))
        button.menu = UIMenu(children: item.options.map { option in
            UIAction(
                title: option.label,
                state: option.id == selectedId ? .on : .off
            ) { [weak self] _ in
                self?.setSelectedTitle(option.label)
                self?.valueChanged?(option.id)
            }
        })
    }

    private func setSelectedTitle(_ title: String) {
        var configuration = UIButton.Configuration.plain()
        configuration.title = title
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 0)
        configuration.baseForegroundColor = .secondaryLabel
        button.configuration = configuration
    }

    private static func optionLabel(
        selectedId: String?,
        options: [NativeSheetOption]
    ) -> String {
        guard let selectedId else { return options.first?.label ?? "Select" }
        return options.first { $0.id == selectedId }?.label
            ?? options.first?.label
            ?? "Select"
    }
}

private final class NativeSheetMultilineTextTableViewCell: UITableViewCell, UITextViewDelegate {
    static let reuseId = "NativeSheetMultilineTextTableViewCell"

    private let stack = UIStackView()
    private let captionLabel = UILabel()
    private let textView = UITextView()
    private var onCommit: ((String) -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        NativeSheetSettingsStyle.applyCellStyle(self)
        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        captionLabel.font = .preferredFont(forTextStyle: .caption1)
        captionLabel.textColor = .secondaryLabel
        captionLabel.numberOfLines = 0
        textView.font = .preferredFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        textView.layer.cornerCurve = .continuous
        textView.layer.cornerRadius = 12
        textView.backgroundColor = .tertiarySystemFill
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        textView.delegate = self
        textView.isScrollEnabled = false
        contentView.addSubview(stack)
        stack.addArrangedSubview(captionLabel)
        stack.addArrangedSubview(textView)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 11),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -11),
            textView.heightAnchor.constraint(greaterThanOrEqualToConstant: 120),
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        onCommit = nil
        textView.text = ""
    }

    func configure(item: NativeSheetItem, onEndEditing: @escaping (String) -> Void) {
        captionLabel.text = item.title
        textView.text = item.value as? String ?? ""
        textView.accessibilityLabel = item.title
        onCommit = onEndEditing
    }

    func textViewDidEndEditing(_ textView: UITextView) {
        onCommit?(textView.text ?? "")
    }
}

private final class NativeSheetReadOnlyTextTableViewCell: UITableViewCell {
    static let reuseId = "NativeSheetReadOnlyTextTableViewCell"

    private let stack = UIStackView()
    private let captionLabel = UILabel()
    private let textView = UITextView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        NativeSheetSettingsStyle.applyCellStyle(self)
        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        captionLabel.font = .preferredFont(forTextStyle: .caption1)
        captionLabel.textColor = .secondaryLabel
        captionLabel.numberOfLines = 0
        textView.font = .preferredFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = false
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        contentView.addSubview(stack)
        stack.addArrangedSubview(captionLabel)
        stack.addArrangedSubview(textView)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 11),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -11),
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }

    func configure(item: NativeSheetItem) {
        captionLabel.text = item.title
        textView.text = (item.value as? String) ?? item.subtitle ?? ""
    }
}

private final class NativeSheetSliderTableViewCell: UITableViewCell {
    static let reuseId = "NativeSheetSliderTableViewCell"

    private let stack = UIStackView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let slider = UISlider()
    private let valueLabel = UILabel()
    private var boundItem: NativeSheetItem?
    private var onCommit: ((Double) -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        NativeSheetSettingsStyle.applyCellStyle(self)
        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .preferredFont(forTextStyle: .body)
        titleLabel.numberOfLines = 0
        subtitleLabel.font = .preferredFont(forTextStyle: .footnote)
        subtitleLabel.textColor = .secondaryLabel
        subtitleLabel.numberOfLines = 0
        valueLabel.font = .preferredFont(forTextStyle: .body)
        valueLabel.textAlignment = .natural
        valueLabel.textColor = .secondaryLabel
        slider.addTarget(self, action: #selector(sliderEditingChanged), for: .valueChanged)
        slider.addTarget(self, action: #selector(sliderReleased), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        contentView.addSubview(stack)
        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(subtitleLabel)
        stack.addArrangedSubview(slider)
        stack.addArrangedSubview(valueLabel)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 11),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -11),
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        boundItem = nil
        onCommit = nil
    }

    func configure(item: NativeSheetItem, onValueCommitted: @escaping (Double) -> Void) {
        boundItem = item
        onCommit = onValueCommitted
        titleLabel.text = item.title
        if let subtitle = item.subtitle, !subtitle.isEmpty {
            subtitleLabel.text = subtitle
            subtitleLabel.isHidden = false
        } else {
            subtitleLabel.isHidden = true
        }

        let minV = Float(item.sliderMin ?? 0)
        let maxV = Float(item.sliderMax ?? 1)
        slider.minimumValue = minV
        slider.maximumValue = maxV

        var current = item.sliderNumericValue
        if let mn = item.sliderMin, let mx = item.sliderMax {
            current = min(mx, max(mn, current))
        }
        slider.value = Float(current)
        refreshValueLabel(for: item, value: current)
        valueLabel.textAlignment = item.id == "tts-speech-rate" ? .natural : .right
    }

    private func refreshValueLabel(for item: NativeSheetItem, value: Double) {
        switch item.id {
        case "stt-silence-duration":
            valueLabel.text = String(format: "%.1fs", value / 1000)
        case "tts-speech-rate":
            valueLabel.text = "\(Int(round(value * 100)))%"
        default:
            valueLabel.text = String(format: "%.2f", value)
        }
    }

    @objc private func sliderEditingChanged() {
        guard let item = boundItem else { return }
        refreshValueLabel(for: item, value: Double(slider.value))
    }

    @objc private func sliderReleased() {
        guard let item = boundItem else { return }
        var v = Double(slider.value)
        if let mn = item.sliderMin, let mx = item.sliderMax, let div = item.sliderDivisions, div > 0 {
            let step = (mx - mn) / Double(div)
            v = mn + (round((v - mn) / step) * step)
            v = min(mx, max(mn, v))
            slider.value = Float(v)
        }
        refreshValueLabel(for: item, value: v)
        onCommit?(v)
    }
}

private final class NativeDetailTableViewController: UITableViewController {
    private enum Section {
        case main
        case destructive
    }

    private var detail: NativeSheetDetail
    private let canNavigate: (NativeSheetItem) -> Bool
    private let onSelect: (NativeSheetItem) -> Void
    private let onControlChanged: (NativeSheetItem, Any?) -> Void
    private let onClose: () -> Void

    var detailId: String { detail.id }

    private var mainItems: [NativeSheetItem] {
        detail.items.filter { !$0.destructive }
    }

    private var destructiveItems: [NativeSheetItem] {
        detail.items.filter(\.destructive)
    }

    private var visibleSections: [Section] {
        destructiveItems.isEmpty ? [.main] : [.main, .destructive]
    }

    init(
        detail: NativeSheetDetail,
        canNavigate: @escaping (NativeSheetItem) -> Bool,
        onSelect: @escaping (NativeSheetItem) -> Void,
        onControlChanged: @escaping (NativeSheetItem, Any?) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.detail = detail
        self.canNavigate = canNavigate
        self.onSelect = onSelect
        self.onControlChanged = onControlChanged
        self.onClose = onClose
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) {
        nil
    }

    func applyUpdatedDetail(_ newDetail: NativeSheetDetail) {
        detail = newDetail
        title = newDetail.title
        navigationItem.title = newDetail.title
        tableView.reloadData()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        NativeSheetBridge.shared.markDetailVisible(self)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = detail.title
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.rightBarButtonItem = closeButton()
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        tableView.register(
            NativeSheetSegmentTableViewCell.self,
            forCellReuseIdentifier: NativeSheetSegmentTableViewCell.reuseId
        )
        tableView.register(
            NativeSheetDropdownTableViewCell.self,
            forCellReuseIdentifier: NativeSheetDropdownTableViewCell.reuseId
        )
        tableView.register(
            NativeSheetMultilineTextTableViewCell.self,
            forCellReuseIdentifier: NativeSheetMultilineTextTableViewCell.reuseId
        )
        tableView.register(
            NativeSheetReadOnlyTextTableViewCell.self,
            forCellReuseIdentifier: NativeSheetReadOnlyTextTableViewCell.reuseId
        )
        tableView.register(
            NativeSheetSliderTableViewCell.self,
            forCellReuseIdentifier: NativeSheetSliderTableViewCell.reuseId
        )
        tableView.estimatedRowHeight = NativeSheetSettingsStyle.defaultCellHeight
        tableView.rowHeight = UITableView.automaticDimension
        NativeSheetSettingsStyle.apply(to: tableView)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        view.endEditing(true)
    }

    override func tableView(
        _ tableView: UITableView,
        titleForFooterInSection section: Int
    ) -> String? {
        visibleSections[section] == .main ? detail.subtitle : nil
    }

    override func tableView(
        _ tableView: UITableView,
        willDisplayFooterView view: UIView,
        forSection section: Int
    ) {
        NativeSheetSettingsStyle.applyHeaderFooterStyle(view)
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch visibleSections[section] {
        case .main:
            return mainItems.count
        case .destructive:
            return destructiveItems.count
        }
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        visibleSections.count
    }

    override func tableView(
        _ tableView: UITableView,
        cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        let item = item(at: indexPath)
        switch item.kind {
        case "segment":
            let cell = tableView.dequeueReusableCell(
                withIdentifier: NativeSheetSegmentTableViewCell.reuseId,
                for: indexPath
            ) as! NativeSheetSegmentTableViewCell
            cell.configure(item: item) { [weak self] newValue in
                self?.onControlChanged(item, newValue)
            }
            return cell
        case "dropdown":
            let cell = tableView.dequeueReusableCell(
                withIdentifier: NativeSheetDropdownTableViewCell.reuseId,
                for: indexPath
            ) as! NativeSheetDropdownTableViewCell
            cell.configure(item: item) { [weak self] newValue in
                self?.onControlChanged(item, newValue)
            }
            return cell
        case "multilineTextField":
            let cell = tableView.dequeueReusableCell(
                withIdentifier: NativeSheetMultilineTextTableViewCell.reuseId,
                for: indexPath
            ) as! NativeSheetMultilineTextTableViewCell
            cell.configure(item: item) { [weak self] text in
                self?.onControlChanged(item, text)
            }
            return cell
        case "readOnlyText":
            let cell = tableView.dequeueReusableCell(
                withIdentifier: NativeSheetReadOnlyTextTableViewCell.reuseId,
                for: indexPath
            ) as! NativeSheetReadOnlyTextTableViewCell
            cell.configure(item: item)
            return cell
        case "slider":
            let cell = tableView.dequeueReusableCell(
                withIdentifier: NativeSheetSliderTableViewCell.reuseId,
                for: indexPath
            ) as! NativeSheetSliderTableViewCell
            cell.configure(item: item) { [weak self] value in
                self?.onControlChanged(item, value)
            }
            return cell
        default:
            let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
            configureCell(cell, item: item)
            return cell
        }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let item = item(at: indexPath)
        switch item.kind {
        case "toggle":
            if let toggle = tableView.cellForRow(at: indexPath)?.accessoryView as? UISwitch {
                toggle.setOn(!toggle.isOn, animated: true)
                onControlChanged(item, toggle.isOn)
            } else {
                onControlChanged(item, !(item.value as? Bool ?? false))
            }
        case "info", "textField", "secureTextField", "dropdown", "segment",
             "multilineTextField", "slider", "readOnlyText":
            break
        default:
            onSelect(item)
        }
    }

    private func item(at indexPath: IndexPath) -> NativeSheetItem {
        switch visibleSections[indexPath.section] {
        case .main:
            return mainItems[indexPath.row]
        case .destructive:
            return destructiveItems[indexPath.row]
        }
    }

    private func configureCell(_ cell: UITableViewCell, item: NativeSheetItem) {
        cell.accessoryView = nil
        cell.accessoryType = .none
        cell.selectionStyle = .default

        switch item.kind {
        case "info":
            configureNavigationCell(cell, item: item, showsDisclosure: false)
            cell.selectionStyle = .none

        case "textField", "secureTextField":
            configureNavigationCell(cell, item: item, showsDisclosure: false)
            let field = UITextField(frame: CGRect(x: 0, y: 0, width: 220, height: 36))
            field.text = item.value as? String
            field.placeholder = item.placeholder
            field.textAlignment = .right
            field.font = .preferredFont(forTextStyle: .body)
            field.adjustsFontForContentSizeCategory = true
            field.textColor = .secondaryLabel
            field.tintColor = view.tintColor
            field.isSecureTextEntry = item.kind == "secureTextField"
            field.returnKeyType = .done
            field.autocorrectionType = item.kind == "secureTextField" ? .no : .yes
            field.autocapitalizationType = item.kind == "secureTextField" ? .none : .sentences
            field.addAction(UIAction { [weak self, weak field] _ in
                self?.onControlChanged(item, field?.text ?? "")
            }, for: .editingDidEnd)
            if item.kind == "textField" {
                field.addAction(UIAction { [weak self, weak field] _ in
                    self?.onControlChanged(item, field?.text ?? "")
                }, for: .editingChanged)
            }
            field.addAction(UIAction { [weak field] _ in
                field?.resignFirstResponder()
            }, for: .primaryActionTriggered)
            cell.accessoryView = field
            cell.selectionStyle = .none

        case "toggle":
            configureNavigationCell(cell, item: item, showsDisclosure: false)
            let toggle = UISwitch()
            toggle.isOn = item.value as? Bool ?? false
            toggle.addAction(UIAction { [weak self, weak toggle] _ in
                self?.onControlChanged(item, toggle?.isOn ?? false)
            }, for: .valueChanged)
            cell.accessoryView = toggle
            cell.selectionStyle = .none

        case "searchablePicker":
            configureNavigationCell(cell, item: item, showsDisclosure: true)

        default:
            configureNavigationCell(
                cell,
                item: item,
                showsDisclosure: item.url != nil || canNavigate(item)
            )
        }
    }

    private func closeButton() -> UIBarButtonItem {
        UIBarButtonItem(
            systemItem: .close,
            primaryAction: UIAction { [weak self] _ in self?.onClose() }
        )
    }
}

private final class NativeModelSelectorTableViewController: UITableViewController {
    private let configuration: NativeModelSelectorConfiguration
    private let onSelect: (String) -> Void
    private let onClose: () -> Void
    private var filteredModels: [NativeModelSelectorOption]

    init(
        configuration: NativeModelSelectorConfiguration,
        onSelect: @escaping (String) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.configuration = configuration
        self.onSelect = onSelect
        self.onClose = onClose
        filteredModels = configuration.models
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = configuration.title
        navigationItem.rightBarButtonItem = closeButton()
        tableView.register(
            NativeModelSelectorTableViewCell.self,
            forCellReuseIdentifier: "modelCell"
        )
        NativeSheetSettingsStyle.apply(to: tableView)

        let searchController = UISearchController(searchResultsController: nil)
        searchController.searchResultsUpdater = self
        searchController.obscuresBackgroundDuringPresentation = false
        navigationItem.searchController = searchController
        navigationItem.hidesSearchBarWhenScrolling = false
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        filteredModels.count
    }

    override func tableView(
        _ tableView: UITableView,
        cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        let model = filteredModels[indexPath.row]
        let cell = tableView.dequeueReusableCell(
            withIdentifier: "modelCell",
            for: indexPath
        ) as! NativeModelSelectorTableViewCell
        cell.configure(
            model: model,
            isSelected: model.id == configuration.selectedModelId
        )
        cell.accessoryType = model.id == configuration.selectedModelId ? .checkmark : .none
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        onSelect(filteredModels[indexPath.row].id)
    }

    private func closeButton() -> UIBarButtonItem {
        UIBarButtonItem(
            systemItem: .close,
            primaryAction: UIAction { [weak self] _ in self?.onClose() }
        )
    }
}

extension NativeModelSelectorTableViewController: UISearchResultsUpdating {
    func updateSearchResults(for searchController: UISearchController) {
        let query = searchController.searchBar.text?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        filteredModels = query.isEmpty
            ? configuration.models
            : configuration.models.filter { model in
                model.name.lowercased().contains(query)
                    || model.id.lowercased().contains(query)
            }
        tableView.reloadData()
    }
}

private final class NativeOptionsSelectorTableViewController: UITableViewController {
    private let configuration: NativeOptionsSelectorConfiguration
    private let onSelect: (String) -> Void
    private let onClose: () -> Void
    private var filteredOptions: [NativeSheetOption]

    init(
        configuration: NativeOptionsSelectorConfiguration,
        onSelect: @escaping (String) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.configuration = configuration
        self.onSelect = onSelect
        self.onClose = onClose
        filteredOptions = configuration.options
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = configuration.title
        navigationItem.rightBarButtonItem = closeButton()
        tableView.register(
            NativeSheetOptionTableViewCell.self,
            forCellReuseIdentifier: "optionCell"
        )
        NativeSheetSettingsStyle.apply(to: tableView)

        if configuration.searchable {
            let searchController = UISearchController(searchResultsController: nil)
            searchController.searchResultsUpdater = self
            searchController.obscuresBackgroundDuringPresentation = false
            navigationItem.searchController = searchController
            navigationItem.hidesSearchBarWhenScrolling = false
        }
    }

    override func tableView(
        _ tableView: UITableView,
        titleForFooterInSection section: Int
    ) -> String? {
        configuration.subtitle
    }

    override func tableView(
        _ tableView: UITableView,
        willDisplayFooterView view: UIView,
        forSection section: Int
    ) {
        NativeSheetSettingsStyle.applyHeaderFooterStyle(view)
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        filteredOptions.count
    }

    override func tableView(
        _ tableView: UITableView,
        cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        let option = filteredOptions[indexPath.row]
        let cell = tableView.dequeueReusableCell(
            withIdentifier: "optionCell",
            for: indexPath
        ) as! NativeSheetOptionTableViewCell
        cell.configure(
            option: option,
            isSelected: option.id == configuration.selectedOptionId
        )
        cell.accessoryType = option.id == configuration.selectedOptionId ? .checkmark : .none
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let option = filteredOptions[indexPath.row]
        guard option.enabled else { return }
        onSelect(option.id)
    }

    private func closeButton() -> UIBarButtonItem {
        UIBarButtonItem(
            systemItem: .close,
            primaryAction: UIAction { [weak self] _ in self?.onClose() }
        )
    }
}

extension NativeOptionsSelectorTableViewController: UISearchResultsUpdating {
    func updateSearchResults(for searchController: UISearchController) {
        let query = searchController.searchBar.text?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        filteredOptions = query.isEmpty
            ? configuration.options
            : configuration.options.filter { option in
                option.label.lowercased().contains(query)
                    || option.id.lowercased().contains(query)
                    || (option.subtitle?.lowercased().contains(query) ?? false)
            }
        tableView.reloadData()
    }
}

private final class NativeModelSelectorTableViewCell: UITableViewCell {
    private let avatarView = NativeModelAvatarView(side: 32)
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let textStack = UIStackView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        configureViews()
    }

    required init?(coder: NSCoder) {
        nil
    }

    func configure(model: NativeModelSelectorOption, isSelected: Bool) {
        titleLabel.text = model.name
        titleLabel.font = .preferredFont(forTextStyle: .body)
        titleLabel.textColor = .label
        titleLabel.numberOfLines = 2

        let subtitle = model.subtitle?.isEmpty == false ? model.subtitle! : model.id
        subtitleLabel.text = subtitle
        subtitleLabel.font = .preferredFont(forTextStyle: .footnote)
        subtitleLabel.textColor = .secondaryLabel
        subtitleLabel.numberOfLines = 2
        subtitleLabel.isHidden = subtitle == nil

        avatarView.configure(
            name: model.name,
            avatarUrl: model.avatarUrl,
            avatarHeaders: model.avatarHeaders,
            sfSymbol: model.sfSymbol
        )

        accessoryType = isSelected ? .checkmark : .none
        selectionStyle = .default
        isUserInteractionEnabled = true
        NativeSheetSettingsStyle.applyCellStyle(self)
    }

    private func configureViews() {
        backgroundColor = .secondarySystemGroupedBackground
        contentView.addSubview(avatarView)
        contentView.addSubview(textStack)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.axis = .vertical
        textStack.spacing = 2
        textStack.alignment = .fill
        textStack.addArrangedSubview(titleLabel)
        textStack.addArrangedSubview(subtitleLabel)

        NSLayoutConstraint.activate([
            avatarView.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            avatarView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            avatarView.widthAnchor.constraint(equalToConstant: 32),
            avatarView.heightAnchor.constraint(equalToConstant: 32),

            textStack.leadingAnchor.constraint(
                equalTo: avatarView.trailingAnchor,
                constant: NativeSheetSettingsStyle.iconSpacing
            ),
            textStack.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            textStack.topAnchor.constraint(equalTo: contentView.layoutMarginsGuide.topAnchor),
            textStack.bottomAnchor.constraint(equalTo: contentView.layoutMarginsGuide.bottomAnchor),
        ])
    }
}

private final class NativeSheetOptionTableViewCell: UITableViewCell {
    private let hierarchyGuideView = NativeFolderHierarchyGuideView()
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let textStack = UIStackView()
    private var hierarchyWidthConstraint: NSLayoutConstraint?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        configureViews()
    }

    required init?(coder: NSCoder) {
        nil
    }

    func configure(option: NativeSheetOption, isSelected: Bool) {
        let isDestructive = option.destructive
        let tintColor: UIColor = isDestructive ? .systemRed : .secondaryLabel
        let textColor: UIColor = isDestructive ? .systemRed : .label

        titleLabel.text = option.label
        titleLabel.textColor = textColor
        titleLabel.numberOfLines = 2

        subtitleLabel.text = option.subtitle
        subtitleLabel.textColor = .secondaryLabel
        subtitleLabel.numberOfLines = 2
        subtitleLabel.isHidden = option.subtitle == nil || option.subtitle?.isEmpty == true

        if let sfSymbol = option.sfSymbol, !sfSymbol.isEmpty {
            iconView.image = UIImage(systemName: sfSymbol)
        } else {
            iconView.image = nil
        }
        iconView.tintColor = tintColor

        hierarchyGuideView.configure(
            ancestorHasMoreSiblings: option.ancestorHasMoreSiblings,
            showBranch: option.showBranch,
            hasMoreSiblings: option.hasMoreSiblings
        )
        let hierarchyWidth = option.showsHierarchyGuides
            ? NativeFolderHierarchyGuideView.requiredWidth(
                ancestorCount: option.ancestorHasMoreSiblings.count,
                showBranch: option.showBranch
            )
            : 0
        hierarchyWidthConstraint?.constant = hierarchyWidth
        hierarchyGuideView.isHidden = hierarchyWidth == 0

        accessoryType = isSelected ? .checkmark : .none
        selectionStyle = option.enabled ? .default : .none
        isUserInteractionEnabled = option.enabled
        contentView.alpha = option.enabled ? 1.0 : 0.55
        NativeSheetSettingsStyle.applyCellStyle(self)
    }

    private func configureViews() {
        backgroundColor = .secondarySystemGroupedBackground

        hierarchyGuideView.translatesAutoresizingMaskIntoConstraints = false
        iconView.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        textStack.translatesAutoresizingMaskIntoConstraints = false

        iconView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(
            pointSize: NativeSheetSettingsStyle.iconSize,
            weight: .regular
        )
        iconView.contentMode = .scaleAspectFit
        titleLabel.font = .preferredFont(forTextStyle: .body)
        subtitleLabel.font = .preferredFont(forTextStyle: .footnote)

        textStack.axis = .vertical
        textStack.spacing = 2
        textStack.alignment = .fill
        textStack.addArrangedSubview(titleLabel)
        textStack.addArrangedSubview(subtitleLabel)

        contentView.addSubview(hierarchyGuideView)
        contentView.addSubview(iconView)
        contentView.addSubview(textStack)

        hierarchyWidthConstraint = hierarchyGuideView.widthAnchor.constraint(equalToConstant: 0)
        hierarchyWidthConstraint?.isActive = true

        NSLayoutConstraint.activate([
            hierarchyGuideView.leadingAnchor.constraint(
                equalTo: contentView.layoutMarginsGuide.leadingAnchor
            ),
            hierarchyGuideView.topAnchor.constraint(equalTo: contentView.topAnchor),
            hierarchyGuideView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            iconView.leadingAnchor.constraint(equalTo: hierarchyGuideView.trailingAnchor),
            iconView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: NativeSheetSettingsStyle.iconSize),
            iconView.heightAnchor.constraint(equalToConstant: NativeSheetSettingsStyle.iconSize),

            textStack.leadingAnchor.constraint(
                equalTo: iconView.trailingAnchor,
                constant: NativeSheetSettingsStyle.iconSpacing
            ),
            textStack.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            textStack.topAnchor.constraint(equalTo: contentView.layoutMarginsGuide.topAnchor),
            textStack.bottomAnchor.constraint(equalTo: contentView.layoutMarginsGuide.bottomAnchor),
        ])
    }
}

private final class NativeFolderHierarchyGuideView: UIView {
    private var ancestorHasMoreSiblings: [Bool] = []
    private var showBranch = false
    private var hasMoreSiblings = false

    static let segmentWidth: CGFloat = 15

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) {
        nil
    }

    static func requiredWidth(ancestorCount: Int, showBranch: Bool) -> CGFloat {
        CGFloat(ancestorCount + (showBranch ? 1 : 0)) * segmentWidth
    }

    func configure(
        ancestorHasMoreSiblings: [Bool],
        showBranch: Bool,
        hasMoreSiblings: Bool
    ) {
        self.ancestorHasMoreSiblings = ancestorHasMoreSiblings
        self.showBranch = showBranch
        self.hasMoreSiblings = hasMoreSiblings
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard showBranch || ancestorHasMoreSiblings.contains(true) else { return }
        guard let context = UIGraphicsGetCurrentContext() else { return }

        context.setStrokeColor(UIColor.secondaryLabel.withAlphaComponent(0.28).cgColor)
        context.setLineWidth(1.25)
        context.setLineCap(.square)
        context.setLineJoin(.miter)

        let centerY = rect.height / 2
        let seg = Self.segmentWidth

        for (index, hasMore) in ancestorHasMoreSiblings.enumerated() {
            guard index > 0, hasMore else { continue }
            let x = (CGFloat(index) * seg) + (seg / 2)
            context.move(to: CGPoint(x: x, y: 0))
            context.addLine(to: CGPoint(x: x, y: rect.height))
            context.strokePath()
        }

        guard showBranch else { return }
        let branchX = (CGFloat(ancestorHasMoreSiblings.count) * seg) + (seg / 2)

        context.move(to: CGPoint(x: branchX, y: 0))
        context.addLine(to: CGPoint(x: branchX, y: centerY))
        context.addLine(to: CGPoint(x: rect.maxX, y: centerY))
        context.strokePath()

        if hasMoreSiblings {
            context.move(to: CGPoint(x: branchX, y: centerY))
            context.addLine(to: CGPoint(x: branchX, y: rect.height))
            context.strokePath()
        }
    }
}

private enum NativeSheetImageLoader {
    private static let cache = NSCache<NSString, UIImage>()

    static func load(
        rawUrl: String,
        headers: [String: String] = [:],
        completion: @escaping (UIImage) -> Void
    ) {
        if rawUrl.hasPrefix("data:image"),
           let image = decodeDataImage(rawUrl) {
            completion(image)
            return
        }

        guard rawUrl.hasPrefix("http"),
              let url = URL(string: rawUrl) else {
            return
        }

        let cacheKey = NSString(string: rawUrl)
        if let cached = cache.object(forKey: cacheKey) {
            completion(cached)
            return
        }

        var request = URLRequest(url: url)
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        URLSession.shared.dataTask(with: request) { data, _, _ in
            guard let data, let image = UIImage(data: data) else { return }
            cache.setObject(image, forKey: cacheKey)
            DispatchQueue.main.async {
                completion(image)
            }
        }.resume()
    }

    static func decodeDataImage(_ dataUrl: String) -> UIImage? {
        guard let commaIndex = dataUrl.firstIndex(of: ",") else {
            return nil
        }
        let base64Payload = String(dataUrl[dataUrl.index(after: commaIndex)...])
        guard let data = Data(base64Encoded: base64Payload) else {
            return nil
        }
        return UIImage(data: data)
    }
}

private final class NativeModelAvatarView: UIView {
    private let imageView = UIImageView()
    private let initialsLabel = UILabel()
    private let symbolView = UIImageView()
    private var expectedImageUrl: String?

    init(side: CGFloat = 32) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: side).isActive = true
        heightAnchor.constraint(equalToConstant: side).isActive = true
        layer.cornerRadius = 8
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        clipsToBounds = true

        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.contentMode = .scaleAspectFill
        imageView.isHidden = true
        addSubview(imageView)

        initialsLabel.translatesAutoresizingMaskIntoConstraints = false
        initialsLabel.font = .preferredFont(forTextStyle: .footnote)
        initialsLabel.adjustsFontForContentSizeCategory = true
        initialsLabel.textAlignment = .center
        addSubview(initialsLabel)

        symbolView.translatesAutoresizingMaskIntoConstraints = false
        symbolView.contentMode = .scaleAspectFit
        symbolView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(
            pointSize: 16,
            weight: .medium
        )
        symbolView.isHidden = true
        addSubview(symbolView)

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor),

            initialsLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            initialsLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            initialsLabel.topAnchor.constraint(equalTo: topAnchor),
            initialsLabel.bottomAnchor.constraint(equalTo: bottomAnchor),

            symbolView.centerXAnchor.constraint(equalTo: centerXAnchor),
            symbolView.centerYAnchor.constraint(equalTo: centerYAnchor),
            symbolView.widthAnchor.constraint(equalToConstant: 18),
            symbolView.heightAnchor.constraint(equalToConstant: 18),
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }

    func configure(
        name: String,
        avatarUrl: String?,
        avatarHeaders: [String: String],
        sfSymbol: String?
    ) {
        expectedImageUrl = avatarUrl
        imageView.image = nil
        imageView.isHidden = true

        let accentColor = nativeAvatarAccentColor(seed: name)
        backgroundColor = accentColor.withAlphaComponent(0.12)
        layer.borderColor = accentColor.withAlphaComponent(0.24).cgColor

        if let sfSymbol, !sfSymbol.isEmpty {
            symbolView.image = UIImage(systemName: sfSymbol)
            symbolView.tintColor = accentColor
            symbolView.isHidden = false
            initialsLabel.isHidden = true
        } else {
            symbolView.isHidden = true
            initialsLabel.text = name
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(1)
                .uppercased()
            initialsLabel.textColor = accentColor
            initialsLabel.isHidden = false
        }

        guard let avatarUrl, !avatarUrl.isEmpty else {
            return
        }

        NativeSheetImageLoader.load(rawUrl: avatarUrl, headers: avatarHeaders) { [weak self] image in
            guard let self, self.expectedImageUrl == avatarUrl else { return }
            self.imageView.image = image
            self.imageView.isHidden = false
            self.initialsLabel.isHidden = true
            self.symbolView.isHidden = true
        }
    }
}

private final class NativeDatePickerViewController: UIViewController {
    private let configuration: NativeDatePickerConfiguration
    private let onConfirm: (Date) -> Void
    private let onClose: () -> Void
    private let datePicker = UIDatePicker()

    init(
        configuration: NativeDatePickerConfiguration,
        onConfirm: @escaping (Date) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.configuration = configuration
        self.onConfirm = onConfirm
        self.onClose = onClose
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = configuration.title
        view.backgroundColor = .systemGroupedBackground
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: configuration.cancelLabel,
            style: .plain,
            target: self,
            action: #selector(cancelTapped)
        )
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: configuration.doneLabel,
            style: .done,
            target: self,
            action: #selector(doneTapped)
        )

        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.backgroundColor = .secondarySystemGroupedBackground
        container.layer.cornerRadius = 16
        container.layer.cornerCurve = .continuous

        datePicker.translatesAutoresizingMaskIntoConstraints = false
        datePicker.datePickerMode = .date
        datePicker.preferredDatePickerStyle = .wheels
        datePicker.minimumDate = configuration.firstDate
        datePicker.maximumDate = configuration.lastDate
        datePicker.date = min(
            max(configuration.initialDate, configuration.firstDate),
            configuration.lastDate
        )

        view.addSubview(container)
        container.addSubview(datePicker)
        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            container.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
            datePicker.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            datePicker.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            datePicker.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            datePicker.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
        ])
    }

    @objc private func cancelTapped() {
        onClose()
    }

    @objc private func doneTapped() {
        onConfirm(datePicker.date)
    }
}

private func configureNavigationCell(
    _ cell: UITableViewCell,
    item: NativeSheetItem,
    showsDisclosure: Bool = true
) {
    var content = cell.defaultContentConfiguration()
    content.text = item.title
    content.secondaryText = item.kind == "searchablePicker"
        ? (item.selectedOptionLabel ?? item.subtitle)
        : item.subtitle
    content.image = UIImage(systemName: item.sfSymbol)
    NativeSheetSettingsStyle.applyContentStyle(&content)
    if item.destructive {
        content.textProperties.color = .systemRed
        content.imageProperties.tintColor = .systemRed
    }
    content.textProperties.font = .preferredFont(forTextStyle: .body)
    cell.contentConfiguration = content
    cell.accessoryType = showsDisclosure ? .disclosureIndicator : .none
    NativeSheetSettingsStyle.applyCellStyle(cell)
}

private enum NativeSheetSettingsStyle {
    static let defaultCellHeight: CGFloat = 50
    static let iconSize: CGFloat = 24
    static let iconSpacing: CGFloat = 16

    static var horizontalMargin: CGFloat {
        let isWidePhone = UIDevice.current.userInterfaceIdiom == .phone &&
            UIScreen.main.bounds.width >= 414
        return isWidePhone ? 20 : 16
    }

    static func apply(to tableView: UITableView) {
        tableView.keyboardDismissMode = .interactive
        tableView.backgroundColor = .systemGroupedBackground
        tableView.separatorStyle = .none
        tableView.estimatedRowHeight = defaultCellHeight
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedSectionHeaderHeight = 20
        tableView.estimatedSectionFooterHeight = 44
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
        content.textProperties.color = .label
        content.textProperties.numberOfLines = 2
        content.secondaryTextProperties.font = .preferredFont(forTextStyle: .footnote)
        content.secondaryTextProperties.color = .secondaryLabel
        content.secondaryTextProperties.numberOfLines = 2
        content.imageProperties.preferredSymbolConfiguration = UIImage.SymbolConfiguration(
            pointSize: iconSize,
            weight: .regular
        )
        content.imageProperties.tintColor = .secondaryLabel
        content.imageToTextPadding = iconSpacing
    }

    static func applyCellStyle(_ cell: UITableViewCell) {
        cell.backgroundColor = .secondarySystemGroupedBackground
        cell.preservesSuperviewLayoutMargins = true
        cell.contentView.preservesSuperviewLayoutMargins = true
        cell.directionalLayoutMargins = NSDirectionalEdgeInsets(
            top: 11,
            leading: horizontalMargin,
            bottom: 11,
            trailing: horizontalMargin
        )
        let selectedBackground = UIView()
        selectedBackground.backgroundColor = .tertiarySystemFill
        cell.selectedBackgroundView = selectedBackground
    }

    static func applyHeaderFooterStyle(_ view: UIView) {
        guard let headerFooter = view as? UITableViewHeaderFooterView else { return }
        headerFooter.textLabel?.font = .preferredFont(forTextStyle: .footnote)
        headerFooter.textLabel?.textColor = .secondaryLabel
        headerFooter.textLabel?.numberOfLines = 0
    }
}



private final class NativeAvatarView: UIView {
    private let imageView = UIImageView()
    private let initialsLabel = UILabel()

    init(profile: NativeSheetProfile, diameter: CGFloat = 88) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: diameter).isActive = true
        heightAnchor.constraint(equalToConstant: diameter).isActive = true
        layer.cornerRadius = diameter / 2
        clipsToBounds = true
        backgroundColor = .secondarySystemGroupedBackground

        initialsLabel.text = profile.initials
        let fontStyle: UIFont.TextStyle = diameter >= 96 ? .largeTitle : .title2
        initialsLabel.font = .preferredFont(forTextStyle: fontStyle)
        initialsLabel.adjustsFontForContentSizeCategory = true
        initialsLabel.textColor = .secondaryLabel
        initialsLabel.textAlignment = .center
        initialsLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(initialsLabel)

        imageView.contentMode = .scaleAspectFill
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.isHidden = true
        addSubview(imageView)

        NSLayoutConstraint.activate([
            initialsLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            initialsLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            initialsLabel.topAnchor.constraint(equalTo: topAnchor),
            initialsLabel.bottomAnchor.constraint(equalTo: bottomAnchor),
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        loadImage(profile: profile)
    }

    required init?(coder: NSCoder) {
        nil
    }

    func setPickedPreview(_ image: UIImage?) {
        if let image {
            imageView.image = image
            imageView.tintColor = nil
            imageView.contentMode = .scaleAspectFill
            imageView.isHidden = false
            initialsLabel.isHidden = true
        }
    }

    func showRemovedPlaceholder() {
        let img = UIImage(systemName: "person.crop.circle.fill")?
            .withRenderingMode(.alwaysTemplate)
        imageView.image = img
        imageView.tintColor = .tertiaryLabel
        imageView.contentMode = .scaleAspectFit
        imageView.isHidden = false
        initialsLabel.isHidden = true
    }

    private func loadImage(profile: NativeSheetProfile) {
        if let avatarData = profile.avatarData,
           let image = UIImage(data: avatarData) {
            imageView.image = image
            imageView.isHidden = false
            return
        }

        guard let avatarUrl = profile.avatarUrl,
              !avatarUrl.isEmpty else {
            return
        }
        NativeSheetImageLoader.load(rawUrl: avatarUrl, headers: profile.avatarHeaders) { [weak self] image in
            self?.imageView.image = image
            self?.imageView.isHidden = false
        }
    }
}
