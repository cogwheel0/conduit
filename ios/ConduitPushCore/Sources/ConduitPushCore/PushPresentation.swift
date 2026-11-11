import Foundation

/// Keys of `PushConfig.strings`, the localized text Dart mirrors for the
/// extension, with the English text used until it does.
public enum PushStrings {
  public static let fallbackTitle = "fallbackTitle"
  public static let fallbackBody = "fallbackBody"
  public static let replyTitle = "replyTitle"
  public static let replyFailedTitle = "replyFailedTitle"
  public static let replyFailedBody = "replyFailedBody"
  public static let channelTitle = "channelTitle"
  public static let cronTitle = "cronTitle"
  public static let testTitle = "testTitle"
  public static let testBody = "testBody"

  public static let english: [String: String] = [
    fallbackTitle: "Conduit",
    fallbackBody: "New notification",
    replyTitle: "New reply",
    replyFailedTitle: "Reply failed",
    replyFailedBody: "The reply couldn't be completed.",
    channelTitle: "New message",
    cronTitle: "Scheduled task finished",
    testTitle: "Push notifications work",
    testBody: "This test notification was decrypted on your device.",
  ]

  /// The localized string for `key`, or the English one.
  public static func text(_ key: String, in config: PushConfig) -> String {
    if let localized = config.strings[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
      !localized.isEmpty
    {
      return localized
    }
    return english[key] ?? ""
  }
}

/// What a decrypted push looks like on screen.
public struct PushPresentation: Equatable {
  public var title: String
  public var subtitle: String
  public var body: String
  public var threadIdentifier: String
  public var playsSound: Bool

  public init(
    title: String,
    subtitle: String,
    body: String,
    threadIdentifier: String,
    playsSound: Bool
  ) {
    self.title = title
    self.subtitle = subtitle
    self.body = body
    self.threadIdentifier = threadIdentifier
    self.playsSound = playsSound
  }

  public static func make(
    payload: PushPayload,
    scope: String,
    config: PushConfig
  ) -> PushPresentation {
    let text = { (key: String) in PushStrings.text(key, in: config) }
    let title: String
    let body: String
    switch payload.kind {
    case .test:
      title = text(PushStrings.testTitle)
      body = text(PushStrings.testBody)
    case .reply:
      title = payload.title.isEmpty ? text(PushStrings.replyTitle) : payload.title
      body = payload.body
    case .replyFailed:
      title = payload.title.isEmpty ? text(PushStrings.replyFailedTitle) : payload.title
      body = payload.body.isEmpty ? text(PushStrings.replyFailedBody) : payload.body
    case .channel:
      title = payload.title.isEmpty ? text(PushStrings.channelTitle) : payload.title
      switch (payload.author, payload.body.isEmpty) {
      case let (author?, false): body = "\(author): \(payload.body)"
      case let (author?, true): body = author
      case (nil, _): body = payload.body
      }
    case .cron:
      title = payload.title.isEmpty ? text(PushStrings.cronTitle) : payload.title
      body = payload.body
    }

    var subtitle = ""
    if config.showScopeLabel, let label = config.scopeLabels[scope], !label.isEmpty {
      subtitle = label
    }

    return PushPresentation(
      title: title,
      subtitle: subtitle,
      body: body,
      threadIdentifier: payload.group ?? scope,
      playsSound: config.sound
    )
  }

  /// The generic text shown for a push that is not shown with content.
  public static func fallback(config: PushConfig) -> (title: String, body: String) {
    (
      PushStrings.text(PushStrings.fallbackTitle, in: config),
      PushStrings.text(PushStrings.fallbackBody, in: config)
    )
  }
}
