// The widget's words, in the app's 14 languages (WidgetStrings.swift,
// generated from lib/l10n by packaging/macos/native_strings.py when the
// widget builds), and dates by the app's sidebar rules.

import Foundation

struct WidgetL10n {
    enum Key: String, CaseIterable {
        case ask
        case newChat
        case voiceCall
        case clipboard
        case recentChats
        case noChats
        case signedOut
        case openConduit
        case galleryDescription
        case yesterday
    }

    /// One of `WidgetStrings.locales`.
    let locale: String

    /// The app's language when the snapshot names one, else the first of
    /// the user's preferred languages the app speaks, else English.
    init(appLocale: String?, preferred: [String] = Locale.preferredLanguages) {
        if let app = appLocale, WidgetStrings.table[app] != nil {
            locale = app
            return
        }
        locale = preferred.lazy.compactMap(WidgetL10n.match).first ?? "en"
    }

    /// The app locale for a BCP 47 tag (`de-DE` → `de`, `zh-Hant-TW` →
    /// `zh_Hant`, `zh-Hans-CN` → `zh`), or nil when the app lacks it.
    static func match(_ tag: String) -> String? {
        let parts = tag.split(whereSeparator: { $0 == "-" || $0 == "_" }).map(String.init)
        guard let language = parts.first?.lowercased() else { return nil }
        if language == "zh" {
            let rest = Set(parts.dropFirst())
            let hant = rest.contains("Hant") || rest.contains("TW") || rest.contains("HK")
                || rest.contains("MO")
            return hant && !rest.contains("Hans") ? "zh_Hant" : "zh"
        }
        return WidgetStrings.table[language] != nil ? language : nil
    }

    func callAsFunction(_ key: Key) -> String {
        WidgetStrings.table[locale]?[key.rawValue] ?? WidgetStrings.table["en"]?[key.rawValue]
            ?? key.rawValue
    }

    /// Monday is 1, as the app numbers them.
    func weekday(_ number: Int) -> String {
        let key = "weekday\(number)"
        return WidgetStrings.table[locale]?[key] ?? WidgetStrings.table["en"]?[key] ?? ""
    }

    /// The system's own locale when it speaks the app's language (so the
    /// user's region and 12- or 24-hour clock apply), else the app's
    /// language: the app's `views/dates.rs` rule.
    var formattingLocale: Locale {
        let current = Locale.autoupdatingCurrent
        if WidgetL10n.match(current.identifier) == locale { return current }
        return Locale(identifier: locale.replacingOccurrences(of: "_", with: "-"))
    }

    /// A chat's date as the sidebar writes it: the time today,
    /// "Yesterday", the weekday within the last week, then the day and
    /// month this year, or the short date for an earlier year.
    func stamp(_ date: Date, now: Date, calendar: Calendar = .autoupdatingCurrent) -> String {
        let days =
            calendar.dateComponents(
                [.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)
            ).day ?? 0
        let formatter = DateFormatter()
        formatter.locale = formattingLocale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        switch days {
        case ...0:
            formatter.dateStyle = .none
            formatter.timeStyle = .short
            return formatter.string(from: date)
        case 1:
            return self(.yesterday)
        case 2...6:
            // Calendar weekdays start on Sunday (1); the app's on Monday.
            let sundayFirst = calendar.component(.weekday, from: date)
            return weekday((sundayFirst + 5) % 7 + 1)
        default:
            if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
                formatter.setLocalizedDateFormatFromTemplate("dMMM")
            } else {
                formatter.dateStyle = .short
                formatter.timeStyle = .none
            }
            return formatter.string(from: date)
        }
    }

    /// The next midnights after `now`, when a stamp may read differently.
    static func dayBoundaries(after now: Date, count: Int, calendar: Calendar = .autoupdatingCurrent)
        -> [Date]
    {
        var out: [Date] = []
        var day = calendar.startOfDay(for: now)
        for _ in 0..<count {
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            out.append(next)
            day = next
        }
        return out
    }
}
