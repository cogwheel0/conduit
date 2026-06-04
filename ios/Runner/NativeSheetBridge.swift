import Flutter
import PhotosUI
import UIKit

private func nativeLocalized(_ key: String, _ fallback: String) -> String {
    NSLocalizedString(key, tableName: nil, bundle: .main, value: fallback, comment: "")
}

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
    let okLabel: String
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
        title = (p["title"] as? String) ?? nativeLocalized("native.editProfile", "Edit profile")
        saveLabel = (p["saveLabel"] as? String) ?? nativeLocalized("native.saveProfile", "Save profile")
        cancelLabel = (p["cancelLabel"] as? String) ?? nativeLocalized("native.cancel", "Cancel")
        okLabel = (p["okLabel"] as? String) ?? nativeLocalized("native.ok", "OK")
        footerText = (p["footerText"] as? String) ?? ""
        nameLabel = (p["nameLabel"] as? String) ?? nativeLocalized("native.name", "Name")
        nameRequiredMessage = (p["nameRequiredMessage"] as? String) ?? ""
        customGenderRequiredMessage = (p["customGenderRequiredMessage"] as? String) ?? ""
        bioLabel = (p["bioLabel"] as? String) ?? nativeLocalized("native.bio", "Bio")
        bioHint = (p["bioHint"] as? String) ?? ""
        genderLabel = (p["genderLabel"] as? String) ?? nativeLocalized("native.gender", "Gender")
        genderPreferNotToSay = (p["genderPreferNotToSay"] as? String) ?? nativeLocalized("native.genderPreferNotToSay", "Prefer not to say")
        genderMale = (p["genderMale"] as? String) ?? nativeLocalized("native.genderMale", "Male")
        genderFemale = (p["genderFemale"] as? String) ?? nativeLocalized("native.genderFemale", "Female")
        genderCustom = (p["genderCustom"] as? String) ?? nativeLocalized("native.genderCustom", "Custom")
        customGenderLabel = (p["customGenderLabel"] as? String) ?? nativeLocalized("native.customGender", "Custom gender")
        customGenderHint = (p["customGenderHint"] as? String) ?? ""
        birthDateLabel = (p["birthDateLabel"] as? String) ?? nativeLocalized("native.dateOfBirth", "Date of birth")
        selectBirthDateLabel = (p["selectBirthDateLabel"] as? String) ?? nativeLocalized("native.selectDate", "Select a date")
        clearLabel = (p["clearLabel"] as? String) ?? nativeLocalized("native.clear", "Clear")
        uploadFromDeviceLabel = (p["uploadFromDeviceLabel"] as? String) ?? nativeLocalized("native.upload", "Upload")
        useInitialsLabel = (p["useInitialsLabel"] as? String) ?? nativeLocalized("native.initials", "Initials")
        removeAvatarLabel = (p["removeAvatarLabel"] as? String) ?? nativeLocalized("native.remove", "Remove")
        currentAvatarLabel = (p["currentAvatarLabel"] as? String) ?? nativeLocalized("native.avatar", "Avatar")
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
    let sourceIndex: Int?
    let sourceUrl: String?
    let sourceType: String?
    let snippet: String?
    let faviconUrl: String?
    let queries: [String]
    let links: [NativeSheetLink]
    let pending: Bool
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
        sourceIndex = NativeSheetItem.optionalInt(payload["sourceIndex"])
        sourceUrl = payload["sourceUrl"] as? String
        sourceType = payload["sourceType"] as? String
        snippet = payload["snippet"] as? String
        faviconUrl = payload["faviconUrl"] as? String
        queries = (payload["queries"] as? [Any] ?? []).compactMap { value in
            guard let raw = value as? String else { return nil }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        links = (payload["links"] as? [[String: Any]] ?? [])
            .compactMap(NativeSheetLink.init)
        pending = payload["pending"] as? Bool ?? false
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

    private static func optionalInt(_ value: Any?) -> Int? {
        switch value {
        case let n as NSNumber:
            return n.intValue
        case let i as Int:
            return i
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

    var sourceDisplayUrl: String? {
        if let sourceUrl, !sourceUrl.isEmpty {
            return sourceUrl
        }
        return url?.absoluteString
    }

    var sourceDisplayType: String? {
        guard let sourceType, !sourceType.isEmpty else { return nil }
        return sourceType
    }

    var sourceDisplaySnippet: String? {
        if let snippet, !snippet.isEmpty {
            return snippet
        }
        return subtitle
    }
}

private struct NativeSheetLink {
    let title: String?
    let rawUrl: String
    let url: URL?
    let faviconUrl: String?

    init?(_ payload: [String: Any]) {
        guard
            let rawUrl = payload["url"] as? String,
            !rawUrl.isEmpty
        else {
            return nil
        }

        self.rawUrl = rawUrl
        url = URL(string: rawUrl)
        title = payload["title"] as? String
        faviconUrl = payload["faviconUrl"] as? String
    }
}

private enum NativeSheetURLFormatting {
    static func extractDomain(from rawUrl: String?) -> String? {
        guard let rawUrl,
              let url = URL(string: rawUrl),
              var host = url.host,
              !host.isEmpty
        else {
            return nil
        }

        if host.hasPrefix("www.") {
            host.removeFirst(4)
        }
        return host
    }

    static func googleFaviconUrl(rawUrl: String?, size: Int) -> String? {
        guard let domain = extractDomain(from: rawUrl) else { return nil }
        return "https://www.google.com/s2/favicons?sz=\(size)&domain=\(domain)"
    }

    static func displayLabel(for rawUrl: String) -> String {
        extractDomain(from: rawUrl) ?? rawUrl
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
    let tags: [String]

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
        var seenTags = Set<String>()
        tags = (payload["tags"] as? [String] ?? []).compactMap { rawTag in
            let tag = rawTag.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !tag.isEmpty, seenTags.insert(tag.lowercased()).inserted else {
                return nil
            }
            return tag
        }
    }
}

private struct NativeModelSelectorConfiguration {
    let title: String
    let selectedModelId: String?
    let models: [NativeModelSelectorOption]
    let pinnedModelIds: [String]
    let allowsPinning: Bool
    let pinTitle: String
    let unpinTitle: String

    init?(_ arguments: Any?) {
        guard let payload = arguments as? [String: Any] else {
            return nil
        }

        title = (payload["title"] as? String) ?? nativeLocalized("native.chooseModel", "Choose Model")
        selectedModelId = payload["selectedModelId"] as? String
        models = (payload["models"] as? [[String: Any]] ?? [])
            .compactMap(NativeModelSelectorOption.init)
        var seenPinnedIds = Set<String>()
        pinnedModelIds = (payload["pinnedModelIds"] as? [String] ?? []).compactMap { modelId in
            let trimmed = modelId.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seenPinnedIds.insert(trimmed).inserted else {
                return nil
            }
            return trimmed
        }
        allowsPinning = payload["allowsPinning"] as? Bool ?? false
        pinTitle = (payload["pinTitle"] as? String) ?? nativeLocalized("native.pin", "Pin")
        unpinTitle = (payload["unpinTitle"] as? String) ?? nativeLocalized("native.unpin", "Unpin")
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

        title = (payload["title"] as? String) ?? nativeLocalized("native.select", "Select")
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

        title = (payload["title"] as? String) ?? nativeLocalized("native.selectDateTitle", "Select Date")
        self.initialDate = initialDate
        self.firstDate = firstDate
        self.lastDate = lastDate
        doneLabel = (payload["doneLabel"] as? String) ?? nativeLocalized("native.done", "Done")
        cancelLabel = (payload["cancelLabel"] as? String) ?? nativeLocalized("native.cancel", "Cancel")
    }
}

private struct NativeTextEditorConfiguration {
    let title: String
    let initialValue: String
    let placeholder: String?
    let sendLabel: String
    let valueId: String
    let sendActionId: String
    let closeActionId: String

    init?(_ arguments: Any?) {
        guard let payload = arguments as? [String: Any] else {
            return nil
        }

        title = (payload["title"] as? String) ?? nativeLocalized("native.message", "Message")
        initialValue = (payload["value"] as? String) ?? ""
        placeholder = payload["placeholder"] as? String
        sendLabel = (payload["sendLabel"] as? String) ?? nativeLocalized("native.send", "Send")
        valueId = (payload["valueId"] as? String) ?? "text"
        sendActionId = (payload["sendActionId"] as? String) ?? "send"
        closeActionId = (payload["closeActionId"] as? String) ?? "close"
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
            for item in detail.allItems {
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
    let sections: [NativeSheetSection]
    let confirmActionId: String?
    let confirmActionLabel: String?
    /// When set (0...1], sheet uses a single custom detent at this fraction of `maximumDetentValue`.
    let maxHeightFraction: CGFloat?

    init(
        id: String,
        title: String,
        subtitle: String?,
        items: [NativeSheetItem],
        sections: [NativeSheetSection] = [],
        confirmActionId: String? = nil,
        confirmActionLabel: String? = nil,
        maxHeightFraction: CGFloat? = nil
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.items = items
        self.sections = sections
        self.confirmActionId = confirmActionId
        self.confirmActionLabel = confirmActionLabel
        self.maxHeightFraction = maxHeightFraction
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
        confirmActionId = payload["confirmActionId"] as? String
        confirmActionLabel = payload["confirmActionLabel"] as? String
        items = (payload["items"] as? [[String: Any]] ?? [])
            .compactMap(NativeSheetItem.init)
        sections = (payload["sections"] as? [[String: Any]] ?? [])
            .compactMap(NativeSheetSection.init)
        maxHeightFraction = NativeSheetDetail.parseMaxHeightFraction(payload["maxHeightFraction"])
    }

    private static func parseMaxHeightFraction(_ value: Any?) -> CGFloat? {
        let raw: CGFloat?
        switch value {
        case let n as NSNumber:
            raw = CGFloat(truncating: n)
        case let d as Double:
            raw = CGFloat(d)
        case let i as Int:
            raw = CGFloat(i)
        default:
            raw = nil
        }
        guard let raw, raw > 0, raw <= 1 else { return nil }
        return raw
    }

    var allItems: [NativeSheetItem] {
        if sections.isEmpty {
            return items
        }
        return sections.flatMap(\.items)
    }
}

private struct NativeSheetSection {
    let title: String?
    let footer: String?
    let items: [NativeSheetItem]

    init(title: String?, footer: String?, items: [NativeSheetItem]) {
        self.title = title
        self.footer = footer
        self.items = items
    }

    init?(_ payload: [String: Any]) {
        items = (payload["items"] as? [[String: Any]] ?? [])
            .compactMap(NativeSheetItem.init)
        guard !items.isEmpty else { return nil }
        title = payload["title"] as? String
        footer = payload["footer"] as? String
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
    let sections: [NativeSheetSection]
    let details: [String: NativeSheetDetail]

    init?(_ arguments: Any?) {
        guard let payload = arguments as? [String: Any],
              let profilePayload = payload["profile"] as? [String: Any] else {
            return nil
        }

        let displayName = (profilePayload["displayName"] as? String) ?? nativeLocalized("native.user", "User")
        let email = (profilePayload["email"] as? String) ?? nativeLocalized("native.noEmail", "No email")
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
            ?? nativeLocalized("native.editProfile", "Edit Profile")
        profileMenuTitle = (payload["profileMenuTitle"] as? String)
            ?? editProfileLabel
        editProfileSheet = NativeEditProfileSheetCopy(payload["editProfileSheet"] as? [String: Any])
        supportTitle = payload["supportTitle"] as? String
        supportSubtitle = payload["supportSubtitle"] as? String
        menuItems = (payload["menuItems"] as? [[String: Any]] ?? [])
            .compactMap(NativeSheetItem.init)
        supportItems = (payload["supportItems"] as? [[String: Any]] ?? [])
            .compactMap(NativeSheetItem.init)
        sections = (payload["sections"] as? [[String: Any]] ?? [])
            .compactMap(NativeSheetSection.init)

        let detailPayloads = payload["detailSheets"] as? [[String: Any]] ?? []
        var detailsById: [String: NativeSheetDetail] = [:]
        for payload in detailPayloads {
            guard let detail = NativeSheetDetail(payload) else { continue }
            detailsById[detail.id] = detail
        }
        details = detailsById
    }
}

private extension PlatformNativeProfileSheetConfig {
    func asPayload() -> [String: Any] {
        var payload: [String: Any] = [
            "profile": profile.asPayload(),
            "editProfileLabel": editProfileLabel,
            "menuItems": menuItems.map { $0.asPayload() },
            "supportItems": supportItems.map { $0.asPayload() },
            "sections": sections.map { $0.asPayload() },
            "detailSheets": detailSheets.map { $0.asPayload() },
        ]
        payload["profileMenuTitle"] = profileMenuTitle
        payload["editProfileSheet"] = editProfileSheet?.asPayload()
        payload["supportTitle"] = supportTitle
        payload["supportSubtitle"] = supportSubtitle
        return payload
    }
}

private extension PlatformNativeProfileSheetUser {
    func asPayload() -> [String: Any] {
        var payload: [String: Any] = [
            "displayName": displayName,
            "email": email,
            "initials": initials,
            "avatarHeaders": avatarHeaders,
        ]
        payload["avatarUrl"] = avatarUrl
        payload["avatarBytes"] = avatarBytes
        payload["bio"] = bio
        payload["gender"] = gender
        payload["dateOfBirth"] = dateOfBirth
        payload["profileImageUrl"] = profileImageUrl
        return payload
    }
}

private extension PlatformNativeEditProfileSheetConfig {
    func asPayload() -> [String: Any] {
        [
            "title": title,
            "saveLabel": saveLabel,
            "cancelLabel": cancelLabel,
            "okLabel": okLabel,
            "footerText": footerText,
            "nameLabel": nameLabel,
            "nameRequiredMessage": nameRequiredMessage,
            "customGenderRequiredMessage": customGenderRequiredMessage,
            "bioLabel": bioLabel,
            "bioHint": bioHint,
            "genderLabel": genderLabel,
            "genderPreferNotToSay": genderPreferNotToSay,
            "genderMale": genderMale,
            "genderFemale": genderFemale,
            "genderCustom": genderCustom,
            "customGenderLabel": customGenderLabel,
            "customGenderHint": customGenderHint,
            "birthDateLabel": birthDateLabel,
            "selectBirthDateLabel": selectBirthDateLabel,
            "clearLabel": clearLabel,
            "uploadFromDeviceLabel": uploadFromDeviceLabel,
            "useInitialsLabel": useInitialsLabel,
            "removeAvatarLabel": removeAvatarLabel,
            "currentAvatarLabel": currentAvatarLabel,
        ]
    }
}

private extension PlatformNativeSheetSection {
    func asPayload() -> [String: Any] {
        var payload: [String: Any] = [
            "items": items.map { $0.asPayload() },
        ]
        payload["title"] = title
        payload["footer"] = footer
        return payload
    }
}

private extension PlatformNativeSheetDetail {
    func asPayload() -> [String: Any] {
        var payload: [String: Any] = [
            "id": id,
            "title": title,
            "items": items.map { $0.asPayload() },
            "sections": sections.map { $0.asPayload() },
        ]
        payload["subtitle"] = subtitle
        payload["confirmActionId"] = confirmActionId
        payload["confirmActionLabel"] = confirmActionLabel
        payload["maxHeightFraction"] = maxHeightFraction
        return payload
    }
}

private extension PlatformNativeSheetItem {
    func asPayload() -> [String: Any] {
        var payload: [String: Any] = [
            "id": id,
            "title": title,
            "sfSymbol": sfSymbol,
            "destructive": destructive,
            "kind": kind.payloadName,
            "options": options.map { $0.asPayload() },
            "queries": queries,
            "links": links.map { $0.asPayload() },
            "pending": pending,
        ]
        payload["subtitle"] = subtitle
        payload["url"] = url
        payload["value"] = value
        payload["placeholder"] = placeholder
        if let sourceIndex { payload["sourceIndex"] = Int(sourceIndex) }
        payload["sourceUrl"] = sourceUrl
        payload["sourceType"] = sourceType
        payload["snippet"] = snippet
        payload["faviconUrl"] = faviconUrl
        payload["min"] = min
        payload["max"] = max
        if let divisions { payload["divisions"] = Int(divisions) }
        return payload
    }
}

private extension PlatformNativeSheetItemKind {
    var payloadName: String {
        switch self {
        case .navigation: "navigation"
        case .textField: "textField"
        case .multilineTextField: "multilineTextField"
        case .secureTextField: "secureTextField"
        case .dropdown: "dropdown"
        case .searchablePicker: "searchablePicker"
        case .toggle: "toggle"
        case .segment: "segment"
        case .slider: "slider"
        case .info: "info"
        case .readOnlyText: "readOnlyText"
        case .source: "source"
        case .statusUpdate: "statusUpdate"
        }
    }
}

private extension PlatformNativeSheetOption {
    func asPayload() -> [String: Any] {
        var payload: [String: Any] = [
            "id": id,
            "label": label,
            "enabled": enabled,
            "destructive": destructive,
            "ancestorHasMoreSiblings": ancestorHasMoreSiblings,
            "showBranch": showBranch,
            "hasMoreSiblings": hasMoreSiblings,
        ]
        payload["subtitle"] = subtitle
        payload["sfSymbol"] = sfSymbol
        return payload
    }
}

private extension PlatformNativeSheetLink {
    func asPayload() -> [String: Any] {
        var payload: [String: Any] = ["url": url]
        payload["title"] = title
        payload["faviconUrl"] = faviconUrl
        return payload
    }
}

private extension PlatformNativeSheetModelOption {
    func asPayload() -> [String: Any] {
        var payload: [String: Any] = [
            "id": id,
            "name": name,
            "avatarHeaders": avatarHeaders,
        ]
        payload["subtitle"] = subtitle
        payload["sfSymbol"] = sfSymbol
        payload["avatarUrl"] = avatarUrl
        payload["tags"] = tags
        return payload
    }
}

private extension PlatformNativeSheetModelSelectorRequest {
    func asPayload() -> [String: Any] {
        var payload: [String: Any] = [
            "title": title,
            "models": models.map { $0.asPayload() },
            "pinnedModelIds": pinnedModelIds,
            "allowsPinning": allowsPinning,
        ]
        payload["selectedModelId"] = selectedModelId
        payload["pinTitle"] = pinTitle
        payload["unpinTitle"] = unpinTitle
        return payload
    }
}

private extension PlatformNativeSheetOptionsSelectorRequest {
    func asPayload() -> [String: Any] {
        var payload: [String: Any] = [
            "title": title,
            "searchable": searchable,
            "options": options.map { $0.asPayload() },
        ]
        payload["subtitle"] = subtitle
        payload["selectedOptionId"] = selectedOptionId
        return payload
    }
}

private extension PlatformNativeSheetDatePickerRequest {
    func asPayload() -> [String: Any] {
        var payload: [String: Any] = [
            "title": title,
            "initialDate": initialDateIso8601,
            "firstDate": firstDateIso8601,
            "lastDate": lastDateIso8601,
        ]
        payload["doneLabel"] = doneLabel
        payload["cancelLabel"] = cancelLabel
        return payload
    }
}

private extension PlatformNativeSheetTextEditorRequest {
    func asPayload() -> [String: Any] {
        var payload: [String: Any] = [
            "title": title,
            "value": value,
            "valueId": valueId,
            "sendActionId": sendActionId,
            "closeActionId": closeActionId,
        ]
        payload["placeholder"] = placeholder
        payload["sendLabel"] = sendLabel
        return payload
    }
}

private extension PlatformNativeSheetResultRequest {
    func asPayload() -> [String: Any] {
        [
            "root": root.asPayload(),
            "detailSheets": detailSheets.map { $0.asPayload() },
        ]
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

final class NativeSheetBridge: NativeSheetHostApi {
    static let shared = NativeSheetBridge()

    private enum ActiveSheetMode {
        case profileMenu
        case resultSheet
    }

    private typealias PendingStringResult = (Result<String?, Error>) -> Void
    private typealias PendingActionResult = (Result<PlatformNativeSheetActionResult?, Error>) -> Void

    private var flutterApi: NativeSheetFlutterApi?
    private var activeController: UIViewController?
    private var presentationDelegate: NativeSheetPresentationDelegate?
    private var configuration: NativeSheetConfiguration?
    private var detailPayloads: [String: NativeSheetDetail] = [:]
    private weak var activeDetailTableController: NativeDetailTableViewController?
    private var activeSheetMode: ActiveSheetMode = .profileMenu
    private var pendingModelSelectorResult: PendingStringResult?
    private var pendingOptionsSelectorResult: PendingStringResult?
    private var pendingTextEditorResult: PendingActionResult?
    private var pendingResultSheetResult: PendingActionResult?
    private var resultSheetValues: [String: Any] = [:]
    private weak var activeTextEditorController: NativeTextEditorViewController?

    private init() {}

    func configure(messenger: FlutterBinaryMessenger) {
        flutterApi = NativeSheetFlutterApi(binaryMessenger: messenger)
        NativeSheetHostApiSetup.setUp(
            binaryMessenger: messenger,
            api: self
        )
    }

    func presentProfileMenu(
        config: PlatformNativeProfileSheetConfig,
        completion: @escaping (Result<Bool, Error>) -> Void
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard let configuration = NativeSheetConfiguration(config.asPayload())
            else {
                completion(.failure(PigeonError(
                    code: "INVALID_ARGS",
                    message: "Missing native profile sheet configuration",
                    details: nil
                )))
                return
            }
            self.activeSheetMode = .profileMenu
            self.configuration = configuration
            self.detailPayloads = configuration.details
            completion(.success(self.presentProfileMenu(configuration)))
        }
    }

    func dismiss() throws -> Bool {
        if Thread.isMainThread {
            dismissActive()
        } else {
            DispatchQueue.main.sync { dismissActive() }
        }
        return true
    }

    func presentModelSelector(
        request: PlatformNativeSheetModelSelectorRequest,
        completion: @escaping (Result<String?, Error>) -> Void
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard let configuration = NativeModelSelectorConfiguration(request.asPayload())
            else {
                completion(.failure(PigeonError(
                    code: "INVALID_ARGS",
                    message: "Missing native model selector configuration",
                    details: nil
                )))
                return
            }
            self.presentModelSelector(configuration, result: completion)
        }
    }

    func presentOptionsSelector(
        request: PlatformNativeSheetOptionsSelectorRequest,
        completion: @escaping (Result<String?, Error>) -> Void
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard let configuration = NativeOptionsSelectorConfiguration(request.asPayload())
            else {
                completion(.failure(PigeonError(
                    code: "INVALID_ARGS",
                    message: "Missing native options selector configuration",
                    details: nil
                )))
                return
            }
            self.presentOptionsSelector(configuration, result: completion)
        }
    }

    func presentDatePicker(
        request: PlatformNativeSheetDatePickerRequest,
        completion: @escaping (Result<String?, Error>) -> Void
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard let configuration = NativeDatePickerConfiguration(request.asPayload())
            else {
                completion(.failure(PigeonError(
                    code: "INVALID_ARGS",
                    message: "Missing native date picker configuration",
                    details: nil
                )))
                return
            }
            self.presentDatePicker(configuration, result: completion)
        }
    }

    func presentTextEditor(
        request: PlatformNativeSheetTextEditorRequest,
        completion: @escaping (Result<PlatformNativeSheetActionResult?, Error>) -> Void
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard let configuration = NativeTextEditorConfiguration(request.asPayload())
            else {
                completion(.failure(PigeonError(
                    code: "INVALID_ARGS",
                    message: "Missing native text editor configuration",
                    details: nil
                )))
                return
            }
            self.presentTextEditor(configuration, result: completion)
        }
    }

    func presentResultSheet(
        request: PlatformNativeSheetResultRequest,
        completion: @escaping (Result<PlatformNativeSheetActionResult?, Error>) -> Void
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard let configuration = NativeResultSheetConfiguration(request.asPayload())
            else {
                completion(.failure(PigeonError(
                    code: "INVALID_ARGS",
                    message: "Missing native result sheet configuration",
                    details: nil
                )))
                return
            }
            self.presentResultSheet(configuration, result: completion)
        }
    }

    func applyDetailPatch(
        request: PlatformNativeSheetApplyDetailPatchRequest
    ) throws -> Bool {
        let apply = {
            let detailId = request.detailId
            let items = request.items
                .map { $0.asPayload() }
                .compactMap(NativeSheetItem.init)
            let relatedDetails = (request.detailSheets ?? [])
                .map { $0.asPayload() }
                .compactMap(NativeSheetDetail.init)
            guard let existing = self.detailPayloads[detailId] else {
                return false
            }
            for detail in relatedDetails {
                self.detailPayloads[detail.id] = detail
            }
            let patched = NativeSheetDetail(
                id: existing.id,
                title: request.title ?? existing.title,
                subtitle: request.subtitle ?? existing.subtitle,
                items: items,
                sections: existing.sections,
                confirmActionId: existing.confirmActionId,
                confirmActionLabel: existing.confirmActionLabel,
                maxHeightFraction: existing.maxHeightFraction
            )
            self.detailPayloads[detailId] = patched
            if self.activeDetailTableController?.detailId == detailId {
                self.activeDetailTableController?.applyUpdatedDetail(patched)
            }
            return true
        }

        if Thread.isMainThread {
            return apply()
        }
        var applied = false
        DispatchQueue.main.sync { applied = apply() }
        return applied
    }

    private func presentProfileMenu(_ configuration: NativeSheetConfiguration) -> Bool {
        let controller = NativeProfileMenuTableViewController(
            configuration: configuration,
            onSelect: { [weak self] item in self?.handleSelection(item) },
            onClose: { [weak self] in self?.dismissActive() }
        )
        let navigation = NativeSheetNavigationController(rootViewController: controller)
        return present(navigation, initialDetent: .large)
    }

    private func sendControlChanged(id: String, value: Any?) {
        flutterApi?.onControlChanged(
            event: PlatformNativeSheetControlChangedEvent(id: id, value: value)
        ) { _ in }
    }

    private func sendEditProfileCommitted(_ payload: [String: Any]) {
        guard let name = payload["name"] as? String,
              let profileImageUrl = payload["profileImageUrl"] as? String
        else { return }
        flutterApi?.commitEditProfile(
            event: PlatformNativeEditProfileCommittedEvent(
                name: name,
                profileImageUrl: profileImageUrl,
                bio: payload["bio"] as? String ?? "",
                gender: payload["gender"] as? String,
                dateOfBirth: payload["dateOfBirth"] as? String
            )
        ) { _ in }
    }

    private func actionResult(
        actionId: String,
        values: [String: Any]
    ) -> PlatformNativeSheetActionResult {
        PlatformNativeSheetActionResult(actionId: actionId, values: values)
    }

    private func actionResult(
        from payload: [String: Any]?
    ) -> PlatformNativeSheetActionResult? {
        guard let payload,
              let actionId = payload["actionId"] as? String
        else { return nil }
        return actionResult(
            actionId: actionId,
            values: payload["values"] as? [String: Any] ?? [:]
        )
    }

    private func presentResultSheet(
        _ configuration: NativeResultSheetConfiguration,
        result: @escaping PendingActionResult
    ) {
        if pendingResultSheetResult != nil {
            result(.failure(PigeonError(
                code: "ALREADY_PRESENTING",
                message: "A native result sheet is already open",
                details: nil
            )))
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
        if !present(
            navigation,
            initialDetent: .large,
            maxHeightFraction: configuration.root.maxHeightFraction
        ) {
            let pending = pendingResultSheetResult
            pendingResultSheetResult = nil
            resultSheetValues = [:]
            detailPayloads = [:]
            activeSheetMode = .profileMenu
            pending?(.failure(PigeonError(
                code: "PRESENTATION_FAILED",
                message: "Unable to present native result sheet",
                details: nil
            )))
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
            onConfirmAction: { [weak self] actionId in
                self?.handleCurrentSheetConfirmAction(actionId)
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
        _ = present(navigation, initialDetent: .large)
    }

    private func closeActiveSheet() {
        if activeSheetMode == .resultSheet {
            resolvePendingResultSheetAfterDismiss(nil)
            return
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
            sendControlChanged(id: item.id, value: value)
        case .resultSheet:
            if let value {
                resultSheetValues[item.id] = value
            } else {
                resultSheetValues.removeValue(forKey: item.id)
            }
        }
    }

    private func handleCurrentSheetConfirmAction(_ actionId: String) {
        switch activeSheetMode {
        case .profileMenu:
            sendControlChanged(id: actionId, value: true)
        case .resultSheet:
            resolvePendingResultSheetAfterDismiss(
                actionResult(actionId: actionId, values: resultSheetValues)
            )
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

        resolvePendingResultSheetAfterDismiss(
            actionResult(actionId: item.id, values: resultSheetValues)
        )
    }

    private func resolvePendingResultSheet(
        _ payload: PlatformNativeSheetActionResult?
    ) {
        if let pending = pendingResultSheetResult {
            pendingResultSheetResult = nil
            pending(.success(payload))
        }
    }

    private func resolvePendingResultSheetAfterDismiss(
        _ payload: PlatformNativeSheetActionResult?
    ) {
        guard let pending = pendingResultSheetResult else {
            dismissActive()
            return
        }

        pendingResultSheetResult = nil
        flushActiveSheetEditing()

        let controller = activeController
        let completion = { [weak self] in
            pending(.success(payload))
            self?.activeController = nil
            self?.presentationDelegate = nil
            self?.activeDetailTableController = nil
            self?.detailPayloads = [:]
            self?.resultSheetValues = [:]
            self?.activeSheetMode = .profileMenu
        }

        guard let controller else {
            completion()
            return
        }

        controller.dismiss(animated: true, completion: completion)
    }

    private func presentProfilePhotoEditor() {
        guard let configuration = configuration else { return }
        guard let presenter = activeNavigationController?.visibleViewController else { return }

        let controller = NativeProfilePhotoEditorViewController(
            profile: configuration.profile,
            copy: configuration.editProfileSheet,
            onCommit: { [weak self] payload in
                self?.sendEditProfileCommitted(payload)
            }
        )
        let navigation = NativeSheetNavigationController(rootViewController: controller)
        navigation.modalPresentationStyle = .pageSheet
        applySheetStyle(to: navigation, initialDetent: .large)
        presenter.present(navigation, animated: true)
    }

    private func presentProfileNameEditor() {
        guard let configuration = configuration else { return }
        guard let presenter = activeNavigationController?.visibleViewController else { return }

        let controller = NativeProfileNameEditorViewController(
            profile: configuration.profile,
            copy: configuration.editProfileSheet,
            onCommit: { [weak self] payload in
                self?.sendEditProfileCommitted(payload)
            }
        )
        let navigation = NativeSheetNavigationController(rootViewController: controller)
        navigation.modalPresentationStyle = .pageSheet
        applySheetStyle(to: navigation, initialDetent: .large)
        presenter.present(navigation, animated: true)
    }

    private func presentProfileAboutEditor() {
        guard let configuration = configuration else { return }
        guard let presenter = activeNavigationController?.visibleViewController else { return }

        let controller = NativeProfileAboutEditorViewController(
            profile: configuration.profile,
            copy: configuration.editProfileSheet,
            onCommit: { [weak self] payload in
                self?.sendEditProfileCommitted(payload)
            }
        )
        let navigation = NativeSheetNavigationController(rootViewController: controller)
        navigation.modalPresentationStyle = .pageSheet
        applySheetStyle(to: navigation, initialDetent: .large)
        presenter.present(navigation, animated: true)
    }

    private func presentProfileDetailsEditor() {
        guard let configuration = configuration else { return }
        guard let presenter = activeNavigationController?.visibleViewController else { return }

        let controller = NativeProfileDetailsEditorViewController(
            profile: configuration.profile,
            copy: configuration.editProfileSheet,
            onCommit: { [weak self] payload in
                self?.sendEditProfileCommitted(payload)
            }
        )
        let navigation = NativeSheetNavigationController(rootViewController: controller)
        navigation.modalPresentationStyle = .pageSheet
        applySheetStyle(to: navigation, initialDetent: .large)
        presenter.present(navigation, animated: true)
    }

    private func present(
        _ controller: UIViewController,
        initialDetent: UISheetPresentationController.Detent.Identifier? = nil,
        maxHeightFraction: CGFloat? = nil
    ) -> Bool {
        guard let presenter = topViewController() else { return false }
        activeController = controller
        presentationDelegate = NativeSheetPresentationDelegate(
            onWillDismiss: { [weak self] in
                self?.flushActiveSheetEditing()
            },
            onDismiss: { [weak self] in
                if let pending = self?.pendingModelSelectorResult {
                    self?.pendingModelSelectorResult = nil
                    pending(.success(nil))
                }
                if let pending = self?.pendingOptionsSelectorResult {
                    self?.pendingOptionsSelectorResult = nil
                    pending(.success(nil))
                }
                if let pending = self?.pendingTextEditorResult {
                    self?.pendingTextEditorResult = nil
                    pending(.success(self?.actionResult(
                        from: self?.activeTextEditorController?.resultPayload(
                            actionId: self?.activeTextEditorController?.closeActionId ?? "close"
                        )
                    )))
                }
                if let pending = self?.pendingResultSheetResult {
                    self?.pendingResultSheetResult = nil
                    pending(.success(nil))
                }
                self?.activeController = nil
                self?.presentationDelegate = nil
                self?.activeTextEditorController = nil
                self?.activeDetailTableController = nil
                self?.detailPayloads = [:]
                self?.resultSheetValues = [:]
                let shouldNotifyDismiss = self?.activeSheetMode == .profileMenu
                self?.activeSheetMode = .profileMenu
                if shouldNotifyDismiss == true {
                    self?.flutterApi?.onDismissed { _ in }
                }
            }
        )

        controller.modalPresentationStyle = .pageSheet
        controller.presentationController?.delegate = presentationDelegate
        applySheetStyle(
            to: controller,
            initialDetent: initialDetent,
            maxHeightFraction: maxHeightFraction
        )
        presenter.present(controller, animated: true)
        return true
    }

    private func presentModelSelector(
        _ configuration: NativeModelSelectorConfiguration,
        result: @escaping PendingStringResult
    ) {
        if pendingModelSelectorResult != nil {
            result(.failure(PigeonError(
                code: "ALREADY_PRESENTING",
                message: "A native model selector is already open",
                details: nil
            )))
            return
        }

        activeSheetMode = .resultSheet
        pendingModelSelectorResult = result
        let controller = NativeModelSelectorTableViewController(
            configuration: configuration,
            onSelect: { [weak self] modelId in
                guard let self else { return }
                self.completeModelSelector(with: modelId)
            },
            onTogglePin: { [weak self] modelId in
                guard let self else { return }
                self.flutterApi?.onModelPinToggled(
                    event: PlatformNativeSheetModelPinToggledEvent(modelId: modelId)
                ) { _ in }
            },
            onClose: { [weak self] in
                guard let self else { return }
                self.completeModelSelector(with: nil)
            }
        )
        let navigation = NativeSheetNavigationController(rootViewController: controller)

        if !present(navigation, initialDetent: .large) {
            pendingModelSelectorResult = nil
            activeSheetMode = .profileMenu
            result(.failure(PigeonError(
                code: "PRESENTATION_FAILED",
                message: "Unable to present native model selector",
                details: nil
            )))
        }
    }

    private func completeModelSelector(with value: String?) {
        let pending = pendingModelSelectorResult
        pendingModelSelectorResult = nil
        flushActiveSheetEditing()
        activeController?.dismiss(animated: true)
        activeController = nil
        presentationDelegate = nil
        activeDetailTableController = nil
        detailPayloads = [:]
        resultSheetValues = [:]
        activeSheetMode = .profileMenu
        pending?(.success(value))
    }

    private func presentOptionsSelector(
        _ configuration: NativeOptionsSelectorConfiguration,
        result: @escaping PendingStringResult
    ) {
        if pendingOptionsSelectorResult != nil {
            result(.failure(PigeonError(
                code: "ALREADY_PRESENTING",
                message: "A native options selector is already open",
                details: nil
            )))
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
                pending?(.success(optionId))
            },
            onClose: { [weak self] in
                guard let self else { return }
                let pending = self.pendingOptionsSelectorResult
                self.pendingOptionsSelectorResult = nil
                self.dismissActive()
                pending?(.success(nil))
            }
        )
        let navigation = NativeSheetNavigationController(rootViewController: controller)
        if !present(navigation, initialDetent: .large) {
            pendingOptionsSelectorResult = nil
            activeSheetMode = .profileMenu
            result(.failure(PigeonError(
                code: "PRESENTATION_FAILED",
                message: "Unable to present native options selector",
                details: nil
            )))
        }
    }

    private func presentDatePicker(
        _ configuration: NativeDatePickerConfiguration,
        result: @escaping PendingStringResult
    ) {
        activeSheetMode = .resultSheet
        let controller = NativeDatePickerViewController(
            configuration: configuration,
            onConfirm: { [weak self] date in
                result(.success(nativeSheetFormatDate(date)))
                self?.dismissActive()
            },
            onClose: { [weak self] in
                result(.success(nil))
                self?.dismissActive()
            }
        )
        let navigation = NativeSheetNavigationController(rootViewController: controller)
        if !present(navigation, initialDetent: .large) {
            activeSheetMode = .profileMenu
            result(.failure(PigeonError(
                code: "PRESENTATION_FAILED",
                message: "Unable to present native date picker",
                details: nil
            )))
        }
    }

    private func presentTextEditor(
        _ configuration: NativeTextEditorConfiguration,
        result: @escaping PendingActionResult
    ) {
        if pendingTextEditorResult != nil {
            result(.failure(PigeonError(
                code: "ALREADY_PRESENTING",
                message: "A native text editor sheet is already open",
                details: nil
            )))
            return
        }

        activeSheetMode = .resultSheet
        pendingTextEditorResult = result
        let controller = NativeTextEditorViewController(
            configuration: configuration,
            onClose: { [weak self] in
                self?.resolvePendingTextEditorAfterDismiss(
                    actionId: configuration.closeActionId
                )
            },
            onSend: { [weak self] in
                self?.resolvePendingTextEditorAfterDismiss(
                    actionId: configuration.sendActionId
                )
            }
        )
        activeTextEditorController = controller
        let navigation = NativeSheetNavigationController(rootViewController: controller)
        if present(navigation, initialDetent: .large) {
            navigation.sheetPresentationController?.detents = [.large()]
            controller.focusEditor()
            return
        }

        pendingTextEditorResult = nil
        activeTextEditorController = nil
        activeSheetMode = .profileMenu
        result(.failure(PigeonError(
            code: "PRESENTATION_FAILED",
            message: "Unable to present native text editor",
            details: nil
        )))
    }

    private func resolvePendingTextEditorAfterDismiss(actionId: String) {
        guard let pending = pendingTextEditorResult else {
            dismissActive()
            return
        }

        pendingTextEditorResult = nil
        flushActiveSheetEditing()
        let payload = actionResult(
            from: activeTextEditorController?.resultPayload(actionId: actionId)
        )
        let controller = activeController
        let completion = { [weak self] in
            pending(.success(payload))
            self?.activeController = nil
            self?.presentationDelegate = nil
            self?.activeTextEditorController = nil
            self?.activeDetailTableController = nil
            self?.detailPayloads = [:]
            self?.resultSheetValues = [:]
            self?.activeSheetMode = .profileMenu
        }

        guard let controller else {
            completion()
            return
        }

        controller.dismiss(animated: true, completion: completion)
    }

    private func applySheetStyle(
        to controller: UIViewController,
        initialDetent: UISheetPresentationController.Detent.Identifier? = nil,
        maxHeightFraction: CGFloat? = nil
    ) {
        guard let sheet = controller.sheetPresentationController else { return }
        if let fraction = maxHeightFraction, fraction > 0, fraction <= 1 {
            let cappedId = UISheetPresentationController.Detent.Identifier("conduit.sheetMaxHeightFraction")
            let cappedDetent = UISheetPresentationController.Detent.custom(identifier: cappedId) { context in
                max(context.maximumDetentValue * fraction, 1)
            }
            sheet.detents = [cappedDetent]
            sheet.selectedDetentIdentifier = cappedId
            sheet.prefersScrollingExpandsWhenScrolledToEdge = false
        } else {
            sheet.detents = [.medium(), .large()]
            if let initialDetent = initialDetent {
                sheet.selectedDetentIdentifier = initialDetent
            }
            sheet.prefersScrollingExpandsWhenScrolledToEdge = true
        }
        sheet.prefersGrabberVisible = true
        sheet.prefersEdgeAttachedInCompactHeight = true
        sheet.widthFollowsPreferredContentSizeWhenEdgeAttached = true
    }

    private func handleSelection(_ item: NativeSheetItem) {
        if item.kind == "searchablePicker" {
            presentInlineOptionsSelector(for: item)
            return
        }

        if item.id == "sign-out" {
            presentDestructiveConfirm(for: item)
            return
        }

        switch item.id {
        case "profile-photo":
            presentProfilePhotoEditor()
            return
        case "profile-name":
            presentProfileNameEditor()
            return
        case "profile-about":
            presentProfileAboutEditor()
            return
        case "profile-details":
            presentProfileDetailsEditor()
            return
        default:
            break
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

        sendControlChanged(id: item.id, value: item.value ?? true)
    }

    private func presentDestructiveConfirm(for item: NativeSheetItem) {
        guard let presenter = activeNavigationController?.visibleViewController else {
            switch activeSheetMode {
            case .profileMenu:
                if item.id == "sign-out" {
                    dismissActive()
                    flutterApi?.onLogoutRequested { _ in }
                    return
                }
                sendControlChanged(id: item.id, value: true)
            case .resultSheet:
                resolvePendingResultSheetAfterDismiss(
                    actionResult(actionId: item.id, values: resultSheetValues)
                )
            }
            return
        }

        let alert = UIAlertController(
            title: item.title,
            message: item.subtitle,
            preferredStyle: .alert
        )
        let cancelTitle = configuration?.editProfileSheet.cancelLabel ?? nativeLocalized("native.cancel", "Cancel")
        alert.addAction(UIAlertAction(title: cancelTitle, style: .cancel))
        alert.addAction(UIAlertAction(title: item.title, style: .destructive) { [weak self] _ in
            guard let self else { return }
            switch self.activeSheetMode {
            case .profileMenu:
                if item.id == "sign-out" {
                    self.dismissActive()
                    self.flutterApi?.onLogoutRequested { _ in }
                    return
                }
                self.sendControlChanged(id: item.id, value: true)
            case .resultSheet:
                self.resolvePendingResultSheetAfterDismiss(
                    self.actionResult(
                        actionId: item.id,
                        values: self.resultSheetValues
                    )
                )
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
            pending(.success(nil))
        }
        if let pending = pendingOptionsSelectorResult {
            pendingOptionsSelectorResult = nil
            pending(.success(nil))
        }
        if let pending = pendingTextEditorResult {
            pendingTextEditorResult = nil
            pending(.success(actionResult(
                from: activeTextEditorController?.resultPayload(
                    actionId: activeTextEditorController?.closeActionId ?? "close"
                )
            )))
        }
        if let pending = pendingResultSheetResult {
            pendingResultSheetResult = nil
            pending(.success(nil))
        }
        activeTextEditorController = nil
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
        flutterApi?.onDetailAppeared(
            event: PlatformNativeSheetDetailAppearedEvent(
                detailId: controller.detailId
            )
        ) { _ in }
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

private func nativeProfileCommitPayload(
    profile: NativeSheetProfile,
    name: String? = nil,
    profileImageUrl: String? = nil,
    bio: String? = nil,
    gender: String? = nil,
    dateOfBirth: String? = nil
) -> [String: Any] {
    [
        "name": name ?? profile.displayName,
        "profileImageUrl": profileImageUrl ?? profile.savedProfileImageUrl ?? "",
        "bio": bio ?? profile.bio,
        "gender": gender ?? profile.gender,
        "dateOfBirth": dateOfBirth ?? profile.dateOfBirth ?? "",
    ]
}

private final class NativeProfilePhotoEditorViewController: UIViewController, PHPickerViewControllerDelegate {
    private enum AvatarIntent {
        case unchanged
        case pickedJPEG(Data)
        case initialsGenerated
        case removed
    }

    private let profile: NativeSheetProfile
    private let copy: NativeEditProfileSheetCopy
    private let onCommit: ([String: Any]) -> Void
    private let avatarView: NativeAvatarView
    private let clearButton = UIButton(type: .system)
    private var avatarIntent: AvatarIntent = .unchanged {
        didSet { updateSetButton() }
    }

    init(
        profile: NativeSheetProfile,
        copy: NativeEditProfileSheetCopy,
        onCommit: @escaping ([String: Any]) -> Void
    ) {
        self.profile = profile
        self.copy = copy
        self.onCommit = onCommit
        self.avatarView = NativeAvatarView(profile: profile, diameter: 136)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        navigationItem.title = nativeLocalized("native.editPhoto", "Edit Photo")
        navigationItem.leftBarButtonItem = iconBarButton(
            systemName: "xmark",
            action: UIAction { [weak self] _ in self?.cancelTapped() }
        )
        navigationItem.rightBarButtonItem = iconBarButton(
            systemName: "checkmark",
            style: .done,
            action: UIAction { [weak self] _ in self?.saveTapped() }
        )
        updateSetButton()

        let avatarWrap = UIView()
        avatarWrap.translatesAutoresizingMaskIntoConstraints = false
        avatarWrap.addSubview(avatarView)
        avatarWrap.addSubview(clearButton)

        var clearConfiguration = UIButton.Configuration.filled()
        clearConfiguration.image = UIImage(systemName: "xmark")
        clearConfiguration.cornerStyle = .capsule
        clearConfiguration.baseBackgroundColor = .secondarySystemGroupedBackground
        clearConfiguration.baseForegroundColor = .secondaryLabel
        clearButton.configuration = clearConfiguration
        clearButton.translatesAutoresizingMaskIntoConstraints = false
        clearButton.addAction(UIAction { [weak self] _ in self?.removeAvatarTapped() }, for: .touchUpInside)
        clearButton.accessibilityLabel = copy.removeAvatarLabel

        let photoButton = makeActionButton(title: nativeLocalized("native.photo", "Photo"), symbol: "photo.on.rectangle") { [weak self] in
            self?.presentPhotoPicker()
        }
        let initialsButton = makeActionButton(title: nativeLocalized("native.initials", "Initials"), symbol: "textformat.abc") { [weak self] in
            self?.useInitialsTapped()
        }

        let actionStack = UIStackView(arrangedSubviews: [photoButton, initialsButton])
        actionStack.axis = .horizontal
        actionStack.distribution = .fillEqually
        actionStack.spacing = 12

        let stack = UIStackView(arrangedSubviews: [avatarWrap, actionStack])
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 28
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            avatarView.centerXAnchor.constraint(equalTo: avatarWrap.centerXAnchor),
            avatarView.topAnchor.constraint(equalTo: avatarWrap.topAnchor, constant: 24),
            avatarView.bottomAnchor.constraint(equalTo: avatarWrap.bottomAnchor),
            clearButton.widthAnchor.constraint(equalToConstant: 32),
            clearButton.heightAnchor.constraint(equalToConstant: 32),
            clearButton.trailingAnchor.constraint(equalTo: avatarView.trailingAnchor, constant: -4),
            clearButton.topAnchor.constraint(equalTo: avatarView.topAnchor, constant: 4),
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
        ])
    }

    private func makeActionButton(
        title: String,
        symbol: String,
        handler: @escaping () -> Void
    ) -> UIButton {
        var configuration = UIButton.Configuration.gray()
        configuration.title = title
        configuration.image = UIImage(systemName: symbol)
        configuration.imagePlacement = .top
        configuration.imagePadding = 6
        configuration.cornerStyle = .medium
        let button = UIButton(configuration: configuration)
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        button.titleLabel?.numberOfLines = 2
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 76).isActive = true
        button.addAction(UIAction { _ in handler() }, for: .touchUpInside)
        return button
    }

    private func updateSetButton() {
        navigationItem.rightBarButtonItem?.isEnabled = {
            if case .unchanged = avatarIntent { return false }
            return true
        }()
    }

    @objc private func cancelTapped() {
        dismiss(animated: true)
    }

    @objc private func saveTapped() {
        let imageUrl: String
        switch avatarIntent {
        case .unchanged:
            return
        case .pickedJPEG(let data):
            imageUrl = "data:image/jpeg;base64," + data.base64EncodedString()
        case .initialsGenerated:
            imageUrl = nativeInitialsAvatarDataUrl(name: profile.displayName) ?? ""
        case .removed:
            imageUrl = "/user.png"
        }
        onCommit(nativeProfileCommitPayload(profile: profile, profileImageUrl: imageUrl))
        dismiss(animated: true)
    }

    private func presentPhotoPicker() {
        var configuration = PHPickerConfiguration()
        configuration.filter = .images
        configuration.selectionLimit = 1
        let picker = PHPickerViewController(configuration: configuration)
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
                guard let self, let image = object as? UIImage else { return }
                let toCompress = image.preparingThumbnailSide(1024) ?? image
                guard let data = toCompress.jpegData(compressionQuality: 0.85) else { return }
                self.avatarIntent = .pickedJPEG(data)
                self.avatarView.setPickedPreview(toCompress)
            }
        }
    }

    private func useInitialsTapped() {
        avatarIntent = .initialsGenerated
        if let image = nativeInitialsAvatarUIImage(name: profile.displayName) {
            avatarView.setPickedPreview(image)
        }
    }

    private func removeAvatarTapped() {
        avatarIntent = .removed
        avatarView.showRemovedPlaceholder()
    }
}

private final class NativeProfileNameEditorViewController: UIViewController {
    private let profile: NativeSheetProfile
    private let copy: NativeEditProfileSheetCopy
    private let onCommit: ([String: Any]) -> Void
    private let textField = UITextField()

    init(
        profile: NativeSheetProfile,
        copy: NativeEditProfileSheetCopy,
        onCommit: @escaping ([String: Any]) -> Void
    ) {
        self.profile = profile
        self.copy = copy
        self.onCommit = onCommit
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        navigationItem.title = copy.nameLabel
        navigationItem.leftBarButtonItem = iconBarButton(
            systemName: "xmark",
            action: UIAction { [weak self] _ in self?.cancelTapped() }
        )
        navigationItem.rightBarButtonItem = iconBarButton(
            systemName: "checkmark",
            style: .done,
            action: UIAction { [weak self] _ in self?.saveTapped() }
        )

        let row = inputContainer(caption: copy.nameLabel, field: textField)
        textField.text = profile.displayName
        textField.placeholder = copy.nameLabel
        textField.returnKeyType = .done
        textField.addAction(UIAction { [weak self] _ in self?.saveTapped() }, for: .primaryActionTriggered)

        view.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            row.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
        ])
    }

    @objc private func cancelTapped() {
        dismiss(animated: true)
    }

    @objc private func saveTapped() {
        let name = textField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !name.isEmpty else {
            presentNativeValidationAlert(message: copy.nameRequiredMessage)
            return
        }
        onCommit(nativeProfileCommitPayload(profile: profile, name: name))
        dismiss(animated: true)
    }
}

private final class NativeProfileAboutEditorViewController: UIViewController {
    private let profile: NativeSheetProfile
    private let copy: NativeEditProfileSheetCopy
    private let onCommit: ([String: Any]) -> Void
    private let textView = UITextView()

    init(
        profile: NativeSheetProfile,
        copy: NativeEditProfileSheetCopy,
        onCommit: @escaping ([String: Any]) -> Void
    ) {
        self.profile = profile
        self.copy = copy
        self.onCommit = onCommit
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        navigationItem.title = copy.bioLabel
        navigationItem.leftBarButtonItem = iconBarButton(
            systemName: "xmark",
            action: UIAction { [weak self] _ in self?.cancelTapped() }
        )
        navigationItem.rightBarButtonItem = iconBarButton(
            systemName: "checkmark",
            style: .done,
            action: UIAction { [weak self] _ in self?.saveTapped() }
        )

        let caption = UILabel()
        caption.text = copy.bioLabel
        caption.font = .preferredFont(forTextStyle: .caption1)
        caption.textColor = .secondaryLabel
        caption.adjustsFontForContentSizeCategory = true

        textView.text = profile.bio
        textView.font = .preferredFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        textView.backgroundColor = .secondarySystemGroupedBackground
        textView.layer.cornerRadius = 12
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        textView.heightAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true

        let stack = UIStackView(arrangedSubviews: [caption, textView])
        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
        ])
    }

    @objc private func cancelTapped() {
        dismiss(animated: true)
    }

    @objc private func saveTapped() {
        onCommit(nativeProfileCommitPayload(profile: profile, bio: textView.text ?? ""))
        dismiss(animated: true)
    }
}

private final class NativeProfileDetailsEditorViewController: UIViewController {
    private let profile: NativeSheetProfile
    private let copy: NativeEditProfileSheetCopy
    private let onCommit: ([String: Any]) -> Void
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
        self.birthIso = profile.dateOfBirth?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        super.init(nibName: nil, bundle: nil)
        applyGenderSelectionFromProfile()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        navigationItem.title = copy.title
        navigationItem.leftBarButtonItem = iconBarButton(
            systemName: "xmark",
            action: UIAction { [weak self] _ in self?.cancelTapped() }
        )
        navigationItem.rightBarButtonItem = iconBarButton(
            systemName: "checkmark",
            style: .done,
            action: UIAction { [weak self] _ in self?.saveTapped() }
        )

        var genderConfiguration = UIButton.Configuration.bordered()
        genderConfiguration.titleAlignment = .leading
        genderButton.configuration = genderConfiguration
        genderButton.contentHorizontalAlignment = .leading
        genderButton.showsMenuAsPrimaryAction = true
        genderButton.changesSelectionAsPrimaryAction = true
        rebuildGenderMenu()

        customGenderField.borderStyle = .none
        customGenderField.backgroundColor = .secondarySystemFill
        customGenderField.layer.cornerRadius = 22
        customGenderField.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 16, height: 44))
        customGenderField.leftViewMode = .always
        customGenderField.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true

        configureBirthPicker()
        clearBirthButton.setTitle(copy.clearLabel, for: .normal)
        clearBirthButton.addAction(UIAction { [weak self] _ in self?.clearBirthTapped() }, for: .touchUpInside)

        let genderStack = labeledStack(caption: copy.genderLabel, arrangedSubviews: [genderButton])
        customGenderContainer.axis = .vertical
        customGenderContainer.spacing = 8
        customGenderContainer.addArrangedSubview(captionLabel(copy.customGenderLabel))
        customGenderContainer.addArrangedSubview(customGenderField)

        let birthRow = UIStackView(arrangedSubviews: [birthPicker, clearBirthButton])
        birthRow.axis = .horizontal
        birthRow.spacing = 12
        birthRow.alignment = .center
        let birthStack = labeledStack(caption: copy.birthDateLabel, arrangedSubviews: [birthRow])

        let stack = UIStackView(arrangedSubviews: [genderStack, customGenderContainer, birthStack])
        stack.axis = .vertical
        stack.spacing = 24
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
        ])
        refreshCustomGenderVisibility()
    }

    private func applyGenderSelectionFromProfile() {
        let gender = profile.gender.trimmingCharacters(in: .whitespacesAndNewlines)
        if gender.isEmpty {
            selectedGenderKey = ""
            customGenderField.text = ""
        } else if gender == "male" || gender == "female" {
            selectedGenderKey = gender
            customGenderField.text = ""
        } else {
            selectedGenderKey = "custom"
            customGenderField.text = gender
        }
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
    }

    private func refreshGenderTitle() {
        var configuration = genderButton.configuration ?? .bordered()
        configuration.title = genderTitle(for: selectedGenderKey)
        genderButton.configuration = configuration
    }

    private func genderTitle(for key: String) -> String {
        switch key {
        case "male": return copy.genderMale
        case "female": return copy.genderFemale
        case "custom": return copy.genderCustom
        default: return copy.genderPreferNotToSay
        }
    }

    private func refreshCustomGenderVisibility() {
        customGenderContainer.isHidden = selectedGenderKey != "custom"
        customGenderField.placeholder = copy.customGenderHint
    }

    private func configureBirthPicker() {
        birthPicker.datePickerMode = .date
        birthPicker.preferredDatePickerStyle = .compact
        birthPicker.maximumDate = Date()
        if let min = Calendar.current.date(from: DateComponents(year: 1900, month: 1, day: 1)) {
            birthPicker.minimumDate = min
        }
        if let parsed = nativeParseBirthDateIso(birthIso) {
            birthPicker.date = parsed
        } else {
            birthPicker.date = Calendar.current.date(from: DateComponents(year: 1990, month: 1, day: 1)) ?? Date()
        }
        birthPicker.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.birthIso = nativeFormatBirthDateIso(self.birthPicker.date)
        }, for: .valueChanged)
    }

    private func clearBirthTapped() {
        birthIso = ""
        birthPicker.date = Calendar.current.date(from: DateComponents(year: 1990, month: 1, day: 1)) ?? Date()
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

    @objc private func cancelTapped() {
        dismiss(animated: true)
    }

    @objc private func saveTapped() {
        if selectedGenderKey == "custom",
           customGenderField.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
            presentNativeValidationAlert(message: copy.customGenderRequiredMessage)
            return
        }
        onCommit(nativeProfileCommitPayload(
            profile: profile,
            gender: resolvedGenderPayload(),
            dateOfBirth: birthIso.trimmingCharacters(in: .whitespacesAndNewlines)
        ))
        dismiss(animated: true)
    }
}

private func captionLabel(_ text: String) -> UILabel {
    let label = UILabel()
    label.text = text
    label.font = .preferredFont(forTextStyle: .caption1)
    label.textColor = .secondaryLabel
    label.adjustsFontForContentSizeCategory = true
    return label
}

private func labeledStack(caption: String, arrangedSubviews: [UIView]) -> UIStackView {
    let stack = UIStackView(arrangedSubviews: [captionLabel(caption)] + arrangedSubviews)
    stack.axis = .vertical
    stack.spacing = 8
    return stack
}

private func inputContainer(caption: String, field: UITextField) -> UIStackView {
    field.font = .preferredFont(forTextStyle: .body)
    field.adjustsFontForContentSizeCategory = true
    field.backgroundColor = .secondarySystemGroupedBackground
    field.borderStyle = .none
    field.layer.cornerRadius = 12
    field.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 12, height: 44))
    field.leftViewMode = .always
    field.rightView = UIView(frame: CGRect(x: 0, y: 0, width: 12, height: 44))
    field.rightViewMode = .always
    field.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
    let stack = labeledStack(caption: caption, arrangedSubviews: [field])
    stack.translatesAutoresizingMaskIntoConstraints = false
    return stack
}

private func iconBarButton(
    systemName: String,
    style: UIBarButtonItem.Style = .plain,
    action: UIAction
) -> UIBarButtonItem {
    let button = UIBarButtonItem(
        image: UIImage(systemName: systemName),
        primaryAction: action
    )
    button.style = style
    return button
}

private extension UIViewController {
    func presentNativeValidationAlert(message: String) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: nativeLocalized("native.ok", "OK"), style: .default))
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
        navigationBar.prefersLargeTitles = false
    }
}

private final class NativeProfileMenuTableViewController: UITableViewController {
    private let configuration: NativeSheetConfiguration
    private let onSelect: (NativeSheetItem) -> Void
    private let onClose: () -> Void

    private var tableSections: [NativeSheetSection] {
        if !configuration.sections.isEmpty {
            return configuration.sections
        }

        var sections: [NativeSheetSection] = []
        let menuItems = configuration.menuItems.filter { !$0.destructive }
        if !menuItems.isEmpty {
            sections.append(NativeSheetSection(title: nil, footer: nil, items: menuItems))
        }

        let destructiveItems = configuration.menuItems.filter(\.destructive)
        if !destructiveItems.isEmpty {
            sections.append(NativeSheetSection(title: nil, footer: nil, items: destructiveItems))
        }

        if !configuration.supportItems.isEmpty {
            sections.append(NativeSheetSection(
                title: configuration.supportTitle,
                footer: configuration.supportSubtitle,
                items: configuration.supportItems
            ))
        }

        return sections
    }

    init(
        configuration: NativeSheetConfiguration,
        onSelect: @escaping (NativeSheetItem) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.configuration = configuration
        self.onSelect = onSelect
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
        navigationController?.navigationBar.prefersLargeTitles = false
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "profileCell")
        NativeSheetSettingsStyle.apply(to: tableView)
        tableView.tableHeaderView = configuration.sections.isEmpty ? profileHeader() : nil
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateHeaderSize()
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        tableSections.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        tableSections[section].items.count
    }

    override func tableView(
        _ tableView: UITableView,
        titleForHeaderInSection section: Int
    ) -> String? {
        tableSections[section].title
    }

    override func tableView(
        _ tableView: UITableView,
        titleForFooterInSection section: Int
    ) -> String? {
        tableSections[section].footer
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
        let item = item(at: indexPath)
        if item.id == "profile" && !configuration.sections.isEmpty {
            let cell = tableView.dequeueReusableCell(withIdentifier: "profileCell", for: indexPath)
            configureProfileSummaryCell(cell)
            return cell
        }

        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
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
        tableSections[indexPath.section].items[indexPath.row]
    }

    private func shouldShowDisclosure(for item: NativeSheetItem) -> Bool {
        item.url != nil || configuration.details[item.id] != nil
    }

    private func configureProfileSummaryCell(_ cell: UITableViewCell) {
        cell.accessoryType = .disclosureIndicator
        cell.selectionStyle = .default
        NativeSheetSettingsStyle.applyCellStyle(cell)

        let avatar = NativeAvatarView(profile: configuration.profile, diameter: 56)

        let titleLabel = UILabel()
        titleLabel.text = configuration.profile.displayName
        titleLabel.font = .preferredFont(forTextStyle: .body)
        titleLabel.textColor = .label
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.numberOfLines = 1

        let subtitleLabel = UILabel()
        subtitleLabel.text = configuration.profile.email
        subtitleLabel.font = .preferredFont(forTextStyle: .footnote)
        subtitleLabel.textColor = .secondaryLabel
        subtitleLabel.adjustsFontForContentSizeCategory = true
        subtitleLabel.numberOfLines = 1

        let textStack = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
        textStack.axis = .vertical
        textStack.spacing = 2

        let row = UIStackView(arrangedSubviews: [avatar, textStack])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = NativeSheetSettingsStyle.iconSpacing
        row.translatesAutoresizingMaskIntoConstraints = false

        cell.contentView.subviews.forEach { $0.removeFromSuperview() }
        cell.contentView.addSubview(row)

        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.trailingAnchor),
            row.topAnchor.constraint(equalTo: cell.contentView.topAnchor, constant: 11),
            row.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -11),
        ])
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
        nameLabel.numberOfLines = 2
        stack.addArrangedSubview(nameLabel)

        let emailLabel = UILabel()
        emailLabel.text = configuration.profile.email
        emailLabel.font = .preferredFont(forTextStyle: .footnote)
        emailLabel.adjustsFontForContentSizeCategory = true
        emailLabel.textAlignment = .center
        emailLabel.textColor = .secondaryLabel
        emailLabel.numberOfLines = 2
        stack.addArrangedSubview(emailLabel)

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
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.numberOfLines = 0
        subtitleLabel.font = .preferredFont(forTextStyle: .footnote)
        subtitleLabel.textColor = .secondaryLabel
        subtitleLabel.adjustsFontForContentSizeCategory = true
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

    private let rootStack = UIStackView()
    private let headerStack = UIStackView()
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

        rootStack.axis = .vertical
        rootStack.spacing = 8
        rootStack.translatesAutoresizingMaskIntoConstraints = false

        headerStack.axis = .horizontal
        headerStack.alignment = .top
        headerStack.spacing = NativeSheetSettingsStyle.iconSpacing

        textStack.axis = .vertical
        textStack.spacing = 2
        textStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        iconView.tintColor = .secondaryLabel
        iconView.contentMode = .scaleAspectFit
        iconView.setContentHuggingPriority(.required, for: .horizontal)

        titleLabel.font = .preferredFont(forTextStyle: .body)
        titleLabel.textColor = .label
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.numberOfLines = 0

        subtitleLabel.font = .preferredFont(forTextStyle: .footnote)
        subtitleLabel.textColor = .secondaryLabel
        subtitleLabel.adjustsFontForContentSizeCategory = true
        subtitleLabel.numberOfLines = 0

        button.titleLabel?.font = .preferredFont(forTextStyle: .body)
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        button.titleLabel?.numberOfLines = 2
        button.tintColor = .secondaryLabel
        button.contentHorizontalAlignment = .leading
        button.showsMenuAsPrimaryAction = true
        button.changesSelectionAsPrimaryAction = true

        contentView.addSubview(rootStack)
        rootStack.addArrangedSubview(headerStack)
        rootStack.addArrangedSubview(button)
        headerStack.addArrangedSubview(iconView)
        headerStack.addArrangedSubview(textStack)
        textStack.addArrangedSubview(titleLabel)
        textStack.addArrangedSubview(subtitleLabel)

        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            rootStack.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            rootStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 11),
            rootStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -11),
            iconView.widthAnchor.constraint(equalToConstant: NativeSheetSettingsStyle.iconSize),
            iconView.heightAnchor.constraint(equalToConstant: NativeSheetSettingsStyle.iconSize),
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 36),
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
        var configuration = UIButton.Configuration.gray()
        configuration.title = title
        configuration.titleLineBreakMode = .byTruncatingTail
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10)
        configuration.baseForegroundColor = .label
        configuration.cornerStyle = .medium
        button.configuration = configuration
    }

    private static func optionLabel(
        selectedId: String?,
        options: [NativeSheetOption]
    ) -> String {
        guard let selectedId else { return options.first?.label ?? nativeLocalized("native.select", "Select") }
        return options.first { $0.id == selectedId }?.label
            ?? options.first?.label
            ?? nativeLocalized("native.select", "Select")
    }
}

private final class NativeSheetMultilineTextTableViewCell: UITableViewCell, UITextViewDelegate {
    static let reuseId = "NativeSheetMultilineTextTableViewCell"

    private let stack = UIStackView()
    private let captionLabel = UILabel()
    private let textView = UITextView()
    private var onChange: ((String) -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        NativeSheetSettingsStyle.applyCellStyle(self)
        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        captionLabel.font = .preferredFont(forTextStyle: .caption1)
        captionLabel.textColor = .secondaryLabel
        captionLabel.adjustsFontForContentSizeCategory = true
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
        onChange = nil
        textView.text = ""
    }

    func configure(
        item: NativeSheetItem,
        value: String,
        onTextChanged: @escaping (String) -> Void
    ) {
        captionLabel.text = item.title
        textView.text = value
        textView.accessibilityLabel = item.title
        onChange = onTextChanged
    }

    func textViewDidChange(_ textView: UITextView) {
        onChange?(textView.text ?? "")
    }
}

private final class NativeSheetTextFieldTableViewCell: UITableViewCell {
    static let reuseId = "NativeSheetTextFieldTableViewCell"

    private let stack = UIStackView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let textField = UITextField()
    private var onChange: ((String) -> Void)?
    private var onDone: (() -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        NativeSheetSettingsStyle.applyCellStyle(self)

        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .preferredFont(forTextStyle: .body)
        titleLabel.textColor = .label
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.numberOfLines = 0

        subtitleLabel.font = .preferredFont(forTextStyle: .footnote)
        subtitleLabel.textColor = .secondaryLabel
        subtitleLabel.adjustsFontForContentSizeCategory = true
        subtitleLabel.numberOfLines = 0

        textField.font = .preferredFont(forTextStyle: .body)
        textField.adjustsFontForContentSizeCategory = true
        textField.backgroundColor = .tertiarySystemFill
        textField.layer.cornerRadius = 12
        textField.layer.cornerCurve = .continuous
        textField.clipsToBounds = true
        textField.textColor = .label
        textField.tintColor = .tintColor
        textField.returnKeyType = .done
        textField.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 12, height: 44))
        textField.leftViewMode = .always
        textField.rightView = UIView(frame: CGRect(x: 0, y: 0, width: 12, height: 44))
        textField.rightViewMode = .always
        textField.addAction(UIAction { [weak self] _ in
            self?.onChange?(self?.textField.text ?? "")
        }, for: .editingChanged)
        textField.addAction(UIAction { [weak self] _ in
            self?.onChange?(self?.textField.text ?? "")
        }, for: .editingDidEnd)
        textField.addAction(UIAction { [weak self] _ in
            self?.onChange?(self?.textField.text ?? "")
            self?.textField.resignFirstResponder()
            self?.onDone?()
        }, for: .primaryActionTriggered)

        contentView.addSubview(stack)
        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(subtitleLabel)
        stack.addArrangedSubview(textField)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 11),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -11),
            textField.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        onChange = nil
        onDone = nil
        textField.text = ""
        textField.placeholder = nil
        textField.isSecureTextEntry = false
    }

    func configure(
        item: NativeSheetItem,
        value: String,
        onTextChanged: @escaping (String) -> Void,
        onReturn: @escaping () -> Void
    ) {
        titleLabel.text = item.title
        subtitleLabel.text = item.subtitle
        subtitleLabel.isHidden = item.subtitle?.isEmpty ?? true
        textField.text = value
        textField.placeholder = item.placeholder
        textField.isSecureTextEntry = item.kind == "secureTextField"
        textField.textContentType = item.kind == "secureTextField" ? .password : nil
        textField.autocorrectionType = item.kind == "secureTextField" ? .no : .yes
        textField.autocapitalizationType = item.kind == "secureTextField" ? .none : .sentences
        textField.accessibilityLabel = item.title
        onChange = onTextChanged
        onDone = onReturn
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
        captionLabel.adjustsFontForContentSizeCategory = true
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
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.numberOfLines = 0
        subtitleLabel.font = .preferredFont(forTextStyle: .footnote)
        subtitleLabel.textColor = .secondaryLabel
        subtitleLabel.adjustsFontForContentSizeCategory = true
        subtitleLabel.numberOfLines = 0
        valueLabel.font = .preferredFont(forTextStyle: .body)
        valueLabel.adjustsFontForContentSizeCategory = true
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

private func clearArrangedSubviews(from stack: UIStackView) {
    for view in stack.arrangedSubviews {
        stack.removeArrangedSubview(view)
        view.removeFromSuperview()
    }
}

private func nativeChipConfiguration(
    title: String,
    image: UIImage?,
    foregroundColor: UIColor
) -> UIButton.Configuration {
    var configuration = UIButton.Configuration.gray()
    configuration.title = title
    configuration.image = image
    configuration.imagePadding = image == nil ? 0 : 6
    configuration.baseForegroundColor = foregroundColor
    configuration.buttonSize = .small
    configuration.cornerStyle = .capsule
    configuration.titleLineBreakMode = .byTruncatingTail
    configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(
        pointSize: 12,
        weight: .medium
    )
    configuration.contentInsets = NSDirectionalEdgeInsets(
        top: 4,
        leading: 8,
        bottom: 4,
        trailing: 8
    )
    return configuration
}

private final class NativeSheetQueryChipButton: UIButton {
    override init(frame: CGRect) {
        super.init(frame: frame)
        titleLabel?.font = .preferredFont(forTextStyle: .caption1)
        titleLabel?.adjustsFontForContentSizeCategory = true
        titleLabel?.numberOfLines = 1
        titleLabel?.lineBreakMode = .byTruncatingTail
        contentHorizontalAlignment = .leading
        isUserInteractionEnabled = false
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    required init?(coder: NSCoder) {
        nil
    }

    func configure(title: String) {
        configuration = nativeChipConfiguration(
            title: title,
            image: UIImage(systemName: "magnifyingglass"),
            foregroundColor: .secondaryLabel
        )
    }
}

private final class NativeSheetFaviconView: UIView {
    private let imageView = UIImageView()
    private let fallbackView = UIView()
    private let fallbackIconView = UIImageView()
    private var expectedImageUrl: String?

    init(side: CGFloat) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: side).isActive = true
        heightAnchor.constraint(equalToConstant: side).isActive = true
        layer.cornerRadius = side / 2
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        layer.borderColor = UIColor.systemBackground.cgColor
        clipsToBounds = true
        backgroundColor = .systemBackground

        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.contentMode = .scaleAspectFill
        imageView.isHidden = true
        addSubview(imageView)

        fallbackView.translatesAutoresizingMaskIntoConstraints = false
        fallbackView.backgroundColor = .tertiarySystemFill
        addSubview(fallbackView)

        fallbackIconView.translatesAutoresizingMaskIntoConstraints = false
        fallbackIconView.contentMode = .scaleAspectFit
        fallbackIconView.tintColor = .secondaryLabel
        fallbackView.addSubview(fallbackIconView)

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 1),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -1),
            imageView.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
            fallbackView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 1),
            fallbackView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -1),
            fallbackView.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            fallbackView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
            fallbackIconView.centerXAnchor.constraint(equalTo: fallbackView.centerXAnchor),
            fallbackIconView.centerYAnchor.constraint(equalTo: fallbackView.centerYAnchor),
            fallbackIconView.widthAnchor.constraint(equalTo: fallbackView.widthAnchor, multiplier: 0.6),
            fallbackIconView.heightAnchor.constraint(equalTo: fallbackView.heightAnchor, multiplier: 0.6),
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }

    func configure(rawUrl: String?, faviconUrl: String?, fallbackSystemName: String) {
        expectedImageUrl = faviconUrl ?? NativeSheetURLFormatting.googleFaviconUrl(rawUrl: rawUrl, size: 32)
        imageView.image = nil
        imageView.isHidden = true
        fallbackView.isHidden = false
        fallbackIconView.image = UIImage(systemName: fallbackSystemName)

        guard let imageUrl = expectedImageUrl else { return }
        NativeSheetImageLoader.load(rawUrl: imageUrl) { [weak self] image in
            guard let self, self.expectedImageUrl == imageUrl else { return }
            self.imageView.image = image
            self.imageView.isHidden = false
            self.fallbackView.isHidden = true
        }
    }
}

private final class NativeSheetLinkChipButton: UIButton {
    private var actionUrl: URL?
    private var onOpen: ((URL) -> Void)?
    private var expectedImageUrl: String?

    override init(frame: CGRect) {
        super.init(frame: frame)
        titleLabel?.font = .preferredFont(forTextStyle: .caption1)
        titleLabel?.adjustsFontForContentSizeCategory = true
        titleLabel?.numberOfLines = 1
        titleLabel?.lineBreakMode = .byTruncatingTail
        contentHorizontalAlignment = .leading
        addAction(
            UIAction { [weak self] _ in
                guard let self, let actionUrl = self.actionUrl else { return }
                self.onOpen?(actionUrl)
            },
            for: .touchUpInside
        )
    }

    required init?(coder: NSCoder) {
        nil
    }

    func configure(link: NativeSheetLink, onOpen: @escaping (URL) -> Void) {
        self.onOpen = onOpen
        actionUrl = link.url
        expectedImageUrl = link.faviconUrl
            ?? NativeSheetURLFormatting.googleFaviconUrl(rawUrl: link.rawUrl, size: 16)

        var buttonConfiguration = nativeChipConfiguration(
            title: link.title ?? NativeSheetURLFormatting.displayLabel(for: link.rawUrl),
            image: UIImage(systemName: "globe"),
            foregroundColor: .label
        )
        configuration = buttonConfiguration
        isEnabled = link.url != nil
        alpha = link.url == nil ? 0.75 : 1

        guard let imageUrl = expectedImageUrl else { return }
        NativeSheetImageLoader.load(rawUrl: imageUrl) { [weak self] image in
            guard let self, self.expectedImageUrl == imageUrl else { return }
            var updated = self.configuration ?? buttonConfiguration
            updated.image = image.withRenderingMode(.alwaysOriginal)
            self.configuration = updated
        }
    }
}
private final class NativeSheetSourceTableViewCell: UITableViewCell {
    static let reuseId = "NativeSheetSourceTableViewCell"

    private let rootStack = UIStackView()
    private let headerStack = UIStackView()
    private let indexLabel = UILabel()
    private let faviconView = NativeSheetFaviconView(side: NativeSheetSettingsStyle.iconSize)
    private let textStack = UIStackView()
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let snippetLabel = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        NativeSheetSettingsStyle.applyCellStyle(self)
        rootStack.axis = .vertical
        rootStack.spacing = 6
        rootStack.translatesAutoresizingMaskIntoConstraints = false

        headerStack.axis = .horizontal
        headerStack.alignment = .top
        headerStack.spacing = NativeSheetSettingsStyle.iconSpacing

        indexLabel.font = UIFontMetrics(forTextStyle: .caption1)
            .scaledFont(for: .systemFont(ofSize: 12, weight: .semibold))
        indexLabel.adjustsFontForContentSizeCategory = true
        indexLabel.textColor = .tertiaryLabel
        indexLabel.textAlignment = .natural
        indexLabel.setContentHuggingPriority(.required, for: .horizontal)
        indexLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        textStack.axis = .vertical
        textStack.spacing = 3
        textStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        titleLabel.font = UIFontMetrics(forTextStyle: .body)
            .scaledFont(for: .systemFont(ofSize: 17, weight: .semibold))
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = .label
        titleLabel.numberOfLines = 2

        detailLabel.font = .preferredFont(forTextStyle: .caption1)
        detailLabel.adjustsFontForContentSizeCategory = true
        detailLabel.textColor = .secondaryLabel
        detailLabel.numberOfLines = 1
        detailLabel.lineBreakMode = .byTruncatingMiddle

        snippetLabel.font = .preferredFont(forTextStyle: .footnote)
        snippetLabel.adjustsFontForContentSizeCategory = true
        snippetLabel.textColor = .secondaryLabel
        snippetLabel.numberOfLines = 4

        contentView.addSubview(rootStack)
        rootStack.addArrangedSubview(headerStack)
        rootStack.addArrangedSubview(snippetLabel)
        headerStack.addArrangedSubview(indexLabel)
        headerStack.addArrangedSubview(faviconView)
        headerStack.addArrangedSubview(textStack)
        textStack.addArrangedSubview(titleLabel)
        textStack.addArrangedSubview(detailLabel)

        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            rootStack.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            rootStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 11),
            rootStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -11),
            indexLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 18),
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }

    func configure(item: NativeSheetItem) {
        titleLabel.text = item.title
        detailLabel.text = item.sourceDisplayUrl ?? item.sourceDisplayType
        detailLabel.isHidden = detailLabel.text?.isEmpty ?? true
        snippetLabel.text = item.sourceDisplaySnippet
        snippetLabel.isHidden = snippetLabel.text?.isEmpty ?? true

        if let sourceIndex = item.sourceIndex {
            indexLabel.text = "\(sourceIndex)."
            indexLabel.isHidden = false
        } else {
            indexLabel.text = nil
            indexLabel.isHidden = true
        }

        let fallbackSymbol = item.url == nil ? "doc.text" : "globe"
        faviconView.configure(
            rawUrl: item.sourceDisplayUrl,
            faviconUrl: item.faviconUrl,
            fallbackSystemName: fallbackSymbol
        )

        accessoryType = item.url == nil ? .none : .disclosureIndicator
        selectionStyle = item.url == nil ? .none : .default
        NativeSheetSettingsStyle.applyCellStyle(self)
    }
}

private final class NativeSheetStatusTableViewCell: UITableViewCell {
    static let reuseId = "NativeSheetStatusTableViewCell"

    private let rootStack = UIStackView()
    private let headerStack = UIStackView()
    private let iconView = UIImageView()
    private let contentStack = UIStackView()
    private let titleLabel = UILabel()
    private let querySectionLabel = UILabel()
    private let queryStack = UIStackView()
    private let linkSectionLabel = UILabel()
    private let linkStack = UIStackView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        NativeSheetSettingsStyle.applyCellStyle(self)

        rootStack.axis = .vertical
        rootStack.spacing = 10
        rootStack.translatesAutoresizingMaskIntoConstraints = false

        headerStack.axis = .horizontal
        headerStack.alignment = .top
        headerStack.spacing = NativeSheetSettingsStyle.iconSpacing

        iconView.tintColor = .secondaryLabel
        iconView.contentMode = .scaleAspectFit
        iconView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(
            pointSize: NativeSheetSettingsStyle.iconSize,
            weight: .regular
        )
        iconView.setContentHuggingPriority(.required, for: .horizontal)

        contentStack.axis = .vertical
        contentStack.spacing = 6
        contentStack.alignment = .fill

        titleLabel.font = UIFontMetrics(forTextStyle: .body)
            .scaledFont(for: .systemFont(ofSize: 17, weight: .semibold))
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = .label
        titleLabel.numberOfLines = 0

        querySectionLabel.text = nativeLocalized("native.sheet.searches", "Searches")
        querySectionLabel.font = .preferredFont(forTextStyle: .caption1)
        querySectionLabel.adjustsFontForContentSizeCategory = true
        querySectionLabel.textColor = .secondaryLabel

        queryStack.axis = .vertical
        queryStack.spacing = 6
        queryStack.alignment = .leading

        linkSectionLabel.text = nativeLocalized("native.sheet.sources", "Sources")
        linkSectionLabel.font = .preferredFont(forTextStyle: .caption1)
        linkSectionLabel.adjustsFontForContentSizeCategory = true
        linkSectionLabel.textColor = .secondaryLabel

        linkStack.axis = .vertical
        linkStack.spacing = 6
        linkStack.alignment = .leading

        contentView.addSubview(rootStack)
        rootStack.addArrangedSubview(headerStack)
        headerStack.addArrangedSubview(iconView)
        headerStack.addArrangedSubview(contentStack)
        contentStack.addArrangedSubview(titleLabel)
        contentStack.addArrangedSubview(querySectionLabel)
        contentStack.addArrangedSubview(queryStack)
        contentStack.addArrangedSubview(linkSectionLabel)
        contentStack.addArrangedSubview(linkStack)

        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            rootStack.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            rootStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 11),
            rootStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -11),
            iconView.widthAnchor.constraint(equalToConstant: NativeSheetSettingsStyle.iconSize),
            iconView.heightAnchor.constraint(equalToConstant: NativeSheetSettingsStyle.iconSize),
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        clearArrangedSubviews(from: queryStack)
        clearArrangedSubviews(from: linkStack)
    }

    func configure(
        item: NativeSheetItem,
        onOpenLink: @escaping (URL) -> Void
    ) {
        titleLabel.text = item.title
        let symbolName = item.pending ? "circle.dotted" : "circle.fill"
        iconView.image = UIImage(systemName: symbolName)
        iconView.tintColor = item.pending ? .tintColor : .secondaryLabel

        clearArrangedSubviews(from: queryStack)
        clearArrangedSubviews(from: linkStack)

        for query in item.queries {
            let chip = NativeSheetQueryChipButton(frame: .zero)
            chip.configure(title: query)
            queryStack.addArrangedSubview(chip)
        }
        querySectionLabel.isHidden = item.queries.isEmpty
        queryStack.isHidden = item.queries.isEmpty

        for link in item.links {
            let button = NativeSheetLinkChipButton(frame: .zero)
            button.configure(link: link, onOpen: onOpenLink)
            linkStack.addArrangedSubview(button)
        }
        linkSectionLabel.isHidden = item.links.isEmpty
        linkStack.isHidden = item.links.isEmpty
    }
}

private final class NativeDetailTableViewController: UITableViewController {
    private var detail: NativeSheetDetail
    private let canNavigate: (NativeSheetItem) -> Bool
    private let onSelect: (NativeSheetItem) -> Void
    private let onControlChanged: (NativeSheetItem, Any?) -> Void
    private let onConfirmAction: (String) -> Void
    private let onClose: () -> Void
    private var pendingTextValues: [String: String] = [:]
    private var committedTextValues: [String: String] = [:]

    var detailId: String { detail.id }

    private var tableSections: [NativeSheetSection] {
        if !detail.sections.isEmpty {
            return detail.sections
        }

        var sections = [
            NativeSheetSection(
                title: nil,
                footer: detail.subtitle,
                items: detail.items.filter { !$0.destructive }
            ),
        ].filter { !$0.items.isEmpty }

        let destructiveItems = detail.items.filter(\.destructive)
        if !destructiveItems.isEmpty {
            sections.append(
                NativeSheetSection(title: nil, footer: nil, items: destructiveItems)
            )
        }

        return sections
    }

    init(
        detail: NativeSheetDetail,
        canNavigate: @escaping (NativeSheetItem) -> Bool,
        onSelect: @escaping (NativeSheetItem) -> Void,
        onControlChanged: @escaping (NativeSheetItem, Any?) -> Void,
        onConfirmAction: @escaping (String) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.detail = detail
        self.canNavigate = canNavigate
        self.onSelect = onSelect
        self.onControlChanged = onControlChanged
        self.onConfirmAction = onConfirmAction
        self.onClose = onClose
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) {
        nil
    }

    func applyUpdatedDetail(_ newDetail: NativeSheetDetail) {
        detail = newDetail
        pendingTextValues.removeAll()
        committedTextValues.removeAll()
        title = newDetail.title
        navigationItem.title = newDetail.title
        refreshNavigationAction()
        tableView.reloadData()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        NativeSheetBridge.shared.markDetailVisible(self)
        refreshNavigationAction()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = detail.title
        navigationItem.largeTitleDisplayMode = .never
        refreshNavigationAction()
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
            NativeSheetTextFieldTableViewCell.self,
            forCellReuseIdentifier: NativeSheetTextFieldTableViewCell.reuseId
        )
        tableView.register(
            NativeSheetReadOnlyTextTableViewCell.self,
            forCellReuseIdentifier: NativeSheetReadOnlyTextTableViewCell.reuseId
        )
        tableView.register(
            NativeSheetSliderTableViewCell.self,
            forCellReuseIdentifier: NativeSheetSliderTableViewCell.reuseId
        )
        tableView.register(
            NativeSheetSourceTableViewCell.self,
            forCellReuseIdentifier: NativeSheetSourceTableViewCell.reuseId
        )
        tableView.register(
            NativeSheetStatusTableViewCell.self,
            forCellReuseIdentifier: NativeSheetStatusTableViewCell.reuseId
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
        tableSections[section].footer
    }

    override func tableView(
        _ tableView: UITableView,
        titleForHeaderInSection section: Int
    ) -> String? {
        tableSections[section].title
    }

    override func tableView(
        _ tableView: UITableView,
        willDisplayFooterView view: UIView,
        forSection section: Int
    ) {
        NativeSheetSettingsStyle.applyHeaderFooterStyle(view)
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        tableSections[section].items.count
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        tableSections.count
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
            cell.configure(item: item, value: currentTextValue(for: item)) { [weak self] text in
                self?.trackTextValueChanged(for: item, value: text)
            }
            return cell
        case "textField", "secureTextField":
            let cell = tableView.dequeueReusableCell(
                withIdentifier: NativeSheetTextFieldTableViewCell.reuseId,
                for: indexPath
            ) as! NativeSheetTextFieldTableViewCell
            cell.configure(
                item: item,
                value: currentTextValue(for: item),
                onTextChanged: { [weak self] text in
                    self?.trackTextValueChanged(for: item, value: text)
                },
                onReturn: { [weak self] in
                    self?.confirmPendingTextChanges()
                }
            )
            return cell
        case "readOnlyText":
            let cell = tableView.dequeueReusableCell(
                withIdentifier: NativeSheetReadOnlyTextTableViewCell.reuseId,
                for: indexPath
            ) as! NativeSheetReadOnlyTextTableViewCell
            cell.configure(item: item)
            return cell
        case "source":
            let cell = tableView.dequeueReusableCell(
                withIdentifier: NativeSheetSourceTableViewCell.reuseId,
                for: indexPath
            ) as! NativeSheetSourceTableViewCell
            cell.configure(item: item)
            return cell
        case "statusUpdate":
            let cell = tableView.dequeueReusableCell(
                withIdentifier: NativeSheetStatusTableViewCell.reuseId,
                for: indexPath
            ) as! NativeSheetStatusTableViewCell
            cell.configure(item: item) { url in
                UIApplication.shared.open(url)
            }
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
             "multilineTextField", "slider", "readOnlyText", "statusUpdate":
            break
        case "source":
            guard item.url != nil || canNavigate(item) else { break }
            commitPendingTextChanges()
            onSelect(item)
        default:
            commitPendingTextChanges()
            onSelect(item)
        }
    }

    private func item(at indexPath: IndexPath) -> NativeSheetItem {
        tableSections[indexPath.section].items[indexPath.row]
    }

    private func configureCell(_ cell: UITableViewCell, item: NativeSheetItem) {
        cell.accessoryView = nil
        cell.accessoryType = .none
        cell.selectionStyle = .default

        switch item.kind {
        case "info":
            configureNavigationCell(cell, item: item, showsDisclosure: false)
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
        iconBarButton(
            systemName: "xmark",
            action: UIAction { [weak self] _ in self?.onClose() }
        )
    }

    private func confirmButton(actionId: String, label: String? = nil) -> UIBarButtonItem {
        iconBarButton(
            systemName: "checkmark",
            style: .done,
            action: UIAction { [weak self] _ in
                self?.confirmConfiguredAction(actionId)
            }
        )
    }

    private func refreshNavigationAction() {
        navigationItem.leftBarButtonItem = nil
        if let confirmActionId = detail.confirmActionId, !confirmActionId.isEmpty {
            if navigationController?.viewControllers.first === self {
                navigationItem.leftBarButtonItem = closeButton()
            }
            navigationItem.rightBarButtonItem = confirmButton(
                actionId: confirmActionId,
                label: detail.confirmActionLabel
            )
            return
        }

        if pendingTextValues.isEmpty {
            navigationItem.rightBarButtonItem = closeButton()
            return
        }

        navigationItem.rightBarButtonItem = confirmButton(actionId: "")
    }

    private func currentTextValue(for item: NativeSheetItem) -> String {
        pendingTextValues[item.id]
            ?? committedTextValues[item.id]
            ?? (item.value as? String)
            ?? ""
    }

    private func baselineTextValue(for item: NativeSheetItem) -> String {
        committedTextValues[item.id]
            ?? (item.value as? String)
            ?? ""
    }

    private func trackTextValueChanged(for item: NativeSheetItem, value: String) {
        guard item.kind == "textField"
            || item.kind == "secureTextField"
            || item.kind == "multilineTextField"
        else {
            return
        }

        if value == baselineTextValue(for: item) {
            pendingTextValues.removeValue(forKey: item.id)
        } else {
            pendingTextValues[item.id] = value
        }
        refreshNavigationAction()
    }

    @discardableResult
    private func commitPendingTextChanges() -> Bool {
        guard !pendingTextValues.isEmpty else { return false }

        view.endEditing(true)
        let changes = pendingTextValues
        pendingTextValues.removeAll()

        for (id, value) in changes {
            guard let item = detail.allItems.first(where: { $0.id == id }) else { continue }
            committedTextValues[id] = value
            onControlChanged(item, value)
        }
        refreshNavigationAction()
        return true
    }

    private func confirmPendingTextChanges() {
        guard commitPendingTextChanges() else { return }
        if let actionItem = textChangeConfirmationActionItem() {
            onSelect(actionItem)
        } else if let confirmActionId = detail.confirmActionId, !confirmActionId.isEmpty {
            onConfirmAction(confirmActionId)
        }
    }

    private func confirmConfiguredAction(_ actionId: String) {
        if actionId.isEmpty {
            confirmPendingTextChanges()
            return
        }

        _ = commitPendingTextChanges()
        onConfirmAction(actionId)
    }

    private func textChangeConfirmationActionItem() -> NativeSheetItem? {
        tableSections.flatMap(\.items).first { item in
            item.kind == "navigation"
                && !item.destructive
                && item.url == nil
                && !canNavigate(item)
                && item.sfSymbol.contains("checkmark")
        }
    }
}

private final class NativeModelSelectorTableViewController: UITableViewController {
    private let configuration: NativeModelSelectorConfiguration
    private let onSelect: (String) -> Void
    private let onTogglePin: (String) -> Void
    private let onClose: () -> Void
    private var filteredModels: [NativeModelSelectorOption]
    private var pinnedModelIds: [String]
    private var pinnedModelIdSet: Set<String>
    private var currentSearchQuery = ""

    init(
        configuration: NativeModelSelectorConfiguration,
        onSelect: @escaping (String) -> Void,
        onTogglePin: @escaping (String) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.configuration = configuration
        self.onSelect = onSelect
        self.onTogglePin = onTogglePin
        self.onClose = onClose
        pinnedModelIds = configuration.pinnedModelIds
        pinnedModelIdSet = Set(configuration.pinnedModelIds)
        filteredModels = Self.sortedModels(
            configuration.models,
            pinnedModelIds: configuration.pinnedModelIds
        )
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
            isSelected: model.id == configuration.selectedModelId,
            isPinned: pinnedModelIdSet.contains(model.id)
        )
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        onSelect(filteredModels[indexPath.row].id)
    }

    override func tableView(
        _ tableView: UITableView,
        contextMenuConfigurationForRowAt indexPath: IndexPath,
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard configuration.allowsPinning else { return nil }
        let model = filteredModels[indexPath.row]
        let isPinned = pinnedModelIdSet.contains(model.id)
        let title = isPinned ? configuration.unpinTitle : configuration.pinTitle
        let image = UIImage(systemName: isPinned ? "pin.slash" : "pin")
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            let action = UIAction(
                title: title,
                image: image
            ) { [weak self] _ in
                self?.togglePinnedModel(model.id)
                self?.onTogglePin(model.id)
            }
            return UIMenu(children: [action])
        }
    }

    private func closeButton() -> UIBarButtonItem {
        UIBarButtonItem(
            systemItem: .close,
            primaryAction: UIAction { [weak self] _ in self?.onClose() }
        )
    }

    private func togglePinnedModel(_ modelId: String) {
        if pinnedModelIdSet.contains(modelId) {
            pinnedModelIdSet.remove(modelId)
            pinnedModelIds.removeAll { $0 == modelId }
        } else {
            pinnedModelIdSet.insert(modelId)
            pinnedModelIds.append(modelId)
        }
        applyFilterAndSort(query: currentSearchQuery)
    }

    private func applyFilterAndSort(query: String) {
        currentSearchQuery = query
        let searchedModels = query.isEmpty
            ? configuration.models
            : configuration.models.filter { model in
                model.name.lowercased().contains(query)
                    || model.id.lowercased().contains(query)
                    || model.tags.contains { $0.lowercased().contains(query) }
            }
        filteredModels = Self.sortedModels(searchedModels, pinnedModelIds: pinnedModelIds)
        tableView.reloadData()
    }

    private static func sortedModels(
        _ models: [NativeModelSelectorOption],
        pinnedModelIds: [String]
    ) -> [NativeModelSelectorOption] {
        guard !models.isEmpty, !pinnedModelIds.isEmpty else {
            return models
        }
        let pinnedOrder = Dictionary(
            uniqueKeysWithValues: pinnedModelIds.enumerated().map { index, modelId in
                (modelId, index)
            }
        )
        return models.enumerated().sorted { lhs, rhs in
            let leftOrder = pinnedOrder[lhs.element.id]
            let rightOrder = pinnedOrder[rhs.element.id]
            switch (leftOrder, rightOrder) {
            case let (left?, right?):
                return left == right ? lhs.offset < rhs.offset : left < right
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                return lhs.offset < rhs.offset
            }
        }.map(\.element)
    }
}

extension NativeModelSelectorTableViewController: UISearchResultsUpdating {
    func updateSearchResults(for searchController: UISearchController) {
        let query = searchController.searchBar.text?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        applyFilterAndSort(query: query)
    }
}

private final class NativeModelTagButton: UIButton {
    init(text: String) {
        super.init(frame: .zero)

        var configuration = UIButton.Configuration.gray()
        configuration.title = text.uppercased()
        configuration.buttonSize = .mini
        configuration.cornerStyle = .capsule
        configuration.contentInsets = NSDirectionalEdgeInsets(
            top: 2,
            leading: 6,
            bottom: 2,
            trailing: 6
        )
        configuration.baseForegroundColor = .secondaryLabel
        configuration.baseBackgroundColor = .quaternarySystemFill
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer {
            incoming in
            var outgoing = incoming
            outgoing.font = .preferredFont(forTextStyle: .caption2)
            return outgoing
        }
        self.configuration = configuration

        isUserInteractionEnabled = false
        titleLabel?.adjustsFontForContentSizeCategory = true
        titleLabel?.numberOfLines = 1
        titleLabel?.lineBreakMode = .byTruncatingTail
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    required init?(coder: NSCoder) {
        nil
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
    private let tagsStack = UIStackView()
    private let textStack = UIStackView()
    private let pinImageView = UIImageView(image: UIImage(systemName: "pin.fill"))
    private var pinWidthConstraint: NSLayoutConstraint?
    private var textTrailingToPinConstraint: NSLayoutConstraint?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        configureViews()
    }

    required init?(coder: NSCoder) {
        nil
    }

    func configure(model: NativeModelSelectorOption, isSelected: Bool, isPinned: Bool) {
        titleLabel.text = model.name
        titleLabel.font = .preferredFont(forTextStyle: .body)
        titleLabel.textColor = .label
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.numberOfLines = 2

        let subtitle = model.subtitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        subtitleLabel.text = subtitle
        subtitleLabel.font = .preferredFont(forTextStyle: .footnote)
        subtitleLabel.textColor = .secondaryLabel
        subtitleLabel.adjustsFontForContentSizeCategory = true
        subtitleLabel.numberOfLines = 2
        subtitleLabel.isHidden = subtitle.isEmpty

        configureTags(model.tags)

        avatarView.configure(
            name: model.name,
            avatarUrl: model.avatarUrl,
            avatarHeaders: model.avatarHeaders,
            sfSymbol: model.sfSymbol
        )

        accessoryType = isSelected ? .checkmark : .none
        pinImageView.isHidden = !isPinned
        pinWidthConstraint?.constant = isPinned ? 16 : 0
        textTrailingToPinConstraint?.constant = isPinned ? -NativeSheetSettingsStyle.iconSpacing : 0
        selectionStyle = .default
        isUserInteractionEnabled = true
        NativeSheetSettingsStyle.applyCellStyle(self)
    }

    private func configureTags(_ tags: [String]) {
        tagsStack.arrangedSubviews.forEach { view in
            tagsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        let sortedTags = tags.sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
        let visibleTags = sortedTags.prefix(3)
        for tag in visibleTags {
            addTagLabel(tag)
        }
        if sortedTags.count > visibleTags.count {
            addTagLabel("+\(sortedTags.count - visibleTags.count)")
        }
        if !sortedTags.isEmpty {
            let spacer = UIView()
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            tagsStack.addArrangedSubview(spacer)
        }
        tagsStack.isHidden = sortedTags.isEmpty
    }

    private func addTagLabel(_ text: String) {
        let button = NativeModelTagButton(text: text)
        button.widthAnchor.constraint(lessThanOrEqualToConstant: 120).isActive = true
        tagsStack.addArrangedSubview(button)
    }

    private func configureViews() {
        backgroundColor = .secondarySystemGroupedBackground
        contentView.addSubview(avatarView)
        contentView.addSubview(textStack)
        contentView.addSubview(pinImageView)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.axis = .vertical
        textStack.spacing = 2
        textStack.alignment = .fill
        textStack.addArrangedSubview(titleLabel)
        textStack.addArrangedSubview(subtitleLabel)
        textStack.addArrangedSubview(tagsStack)
        tagsStack.translatesAutoresizingMaskIntoConstraints = false
        tagsStack.axis = .horizontal
        tagsStack.spacing = 4
        tagsStack.alignment = .center
        tagsStack.distribution = .fill
        tagsStack.isHidden = true
        pinImageView.translatesAutoresizingMaskIntoConstraints = false
        pinImageView.contentMode = .scaleAspectFit
        pinImageView.tintColor = .secondaryLabel
        pinImageView.isHidden = true
        pinImageView.setContentHuggingPriority(.required, for: .horizontal)
        pinWidthConstraint = pinImageView.widthAnchor.constraint(equalToConstant: 0)
        textTrailingToPinConstraint = textStack.trailingAnchor.constraint(
            equalTo: pinImageView.leadingAnchor
        )

        NSLayoutConstraint.activate([
            avatarView.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            avatarView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            avatarView.widthAnchor.constraint(equalToConstant: 32),
            avatarView.heightAnchor.constraint(equalToConstant: 32),

            textStack.leadingAnchor.constraint(
                equalTo: avatarView.trailingAnchor,
                constant: NativeSheetSettingsStyle.iconSpacing
            ),
            textTrailingToPinConstraint!,
            textStack.topAnchor.constraint(equalTo: contentView.layoutMarginsGuide.topAnchor),
            textStack.bottomAnchor.constraint(equalTo: contentView.layoutMarginsGuide.bottomAnchor),
            pinImageView.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            pinImageView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            pinImageView.heightAnchor.constraint(equalToConstant: 16),
            pinWidthConstraint!,
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
        titleLabel.adjustsFontForContentSizeCategory = true
        subtitleLabel.adjustsFontForContentSizeCategory = true

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

private final class NativeTextEditorViewController: UIViewController, UITextViewDelegate {
    private let configuration: NativeTextEditorConfiguration
    private let onClose: () -> Void
    private let onSend: () -> Void
    private let textView = UITextView()
    private let placeholderLabel = UILabel()

    var closeActionId: String { configuration.closeActionId }

    init(
        configuration: NativeTextEditorConfiguration,
        onClose: @escaping () -> Void,
        onSend: @escaping () -> Void
    ) {
        self.configuration = configuration
        self.onClose = onClose
        self.onSend = onSend
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = configuration.title
        view.backgroundColor = .systemBackground
        navigationItem.leftBarButtonItem = iconBarButton(
            systemName: "xmark",
            action: UIAction { [weak self] _ in self?.closeTapped() }
        )
        let sendButton = UIBarButtonItem(
            title: configuration.sendLabel,
            primaryAction: UIAction { [weak self] _ in self?.sendTapped() }
        )
        sendButton.style = .done
        navigationItem.rightBarButtonItem = sendButton

        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.backgroundColor = .clear
        textView.font = .preferredFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        textView.textColor = .label
        textView.tintColor = .tintColor
        textView.text = configuration.initialValue
        textView.delegate = self
        textView.keyboardDismissMode = .interactive
        textView.alwaysBounceVertical = true
        textView.textContainerInset = UIEdgeInsets(top: 16, left: 0, bottom: 16, right: 0)
        textView.textContainer.lineFragmentPadding = 0

        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        placeholderLabel.text = configuration.placeholder
        placeholderLabel.font = textView.font
        placeholderLabel.textColor = .placeholderText
        placeholderLabel.numberOfLines = 0
        placeholderLabel.adjustsFontForContentSizeCategory = true

        view.addSubview(textView)
        textView.addSubview(placeholderLabel)
        NSLayoutConstraint.activate([
            textView.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            textView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            textView.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),

            placeholderLabel.leadingAnchor.constraint(equalTo: textView.leadingAnchor),
            placeholderLabel.trailingAnchor.constraint(equalTo: textView.trailingAnchor),
            placeholderLabel.topAnchor.constraint(equalTo: textView.topAnchor, constant: textView.textContainerInset.top),
        ])

        refreshActions()
    }

    func focusEditor() {
        DispatchQueue.main.async { [weak self] in
            self?.textView.becomeFirstResponder()
        }
    }

    func resultPayload(actionId: String) -> [String: Any] {
        [
            "actionId": actionId,
            "values": [configuration.valueId: textView.text ?? ""],
        ]
    }

    func textViewDidChange(_ textView: UITextView) {
        refreshActions()
    }

    private func refreshActions() {
        placeholderLabel.isHidden = !textView.text.isEmpty
        navigationItem.rightBarButtonItem?.isEnabled =
            !textView.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func closeTapped() {
        onClose()
    }

    private func sendTapped() {
        guard !textView.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        onSend()
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
        navigationItem.leftBarButtonItem = iconBarButton(
            systemName: "xmark",
            action: UIAction { [weak self] _ in self?.cancelTapped() }
        )
        navigationItem.rightBarButtonItem = iconBarButton(
            systemName: "checkmark",
            style: .done,
            action: UIAction { [weak self] _ in self?.doneTapped() }
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
