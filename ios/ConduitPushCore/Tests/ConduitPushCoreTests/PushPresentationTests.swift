import XCTest

@testable import ConduitPushCore

final class PushPresentationTests: XCTestCase {
  private func payload(_ name: String) throws -> PushPayload {
    try PushPayload.parse(b64u(TestVectors.cp1Case(name).plaintext))
  }

  private func payload(json: String) throws -> PushPayload {
    try PushPayload.parse(Data(json.utf8))
  }

  func testAReplyShowsItsTitleAndPreview() throws {
    let shown = PushPresentation.make(
      payload: try payload("owui_reply"), scope: "owui:acct-1", config: .default)

    XCTAssertEqual(
      shown,
      PushPresentation(
        title: "Trip ideas",
        subtitle: "",
        body: "Here are three routes along the coast:",
        threadIdentifier: "owui:acct-1|chat:4f1c2a7e",
        playsSound: true
      )
    )
  }

  func testTheScopeLabelIsTheSubtitleOnlyWhenEnabled() throws {
    var config = PushConfig.default
    config.scopeLabels = ["owui:acct-1": "Work"]
    let reply = try payload("owui_reply")

    XCTAssertEqual(PushPresentation.make(payload: reply, scope: "owui:acct-1", config: config).subtitle, "")

    config.showScopeLabel = true
    XCTAssertEqual(PushPresentation.make(payload: reply, scope: "owui:acct-1", config: config).subtitle, "Work")
    XCTAssertEqual(PushPresentation.make(payload: reply, scope: "owui:other", config: config).subtitle, "")
  }

  func testAFailedReplyExplainsItself() throws {
    let shown = PushPresentation.make(
      payload: try payload("owui_reply_failed"), scope: "owui:acct-1", config: .default)

    XCTAssertEqual(shown.title, "Trip ideas")
    XCTAssertEqual(shown.body, "The reply couldn't be completed.")
  }

  func testAChannelMessageNamesItsAuthor() throws {
    let shown = PushPresentation.make(
      payload: try payload("owui_channel_unicode"), scope: "owui:acct-2", config: .default)

    XCTAssertEqual(shown.title, "#général")
    XCTAssertEqual(shown.body, "Zoë 🦊: Réunion à 15 h 🗓️ — 会议改到下午三点")
    XCTAssertEqual(shown.threadIdentifier, "owui:acct-2|channel:ch-9")

    let authorOnly = try payload(json: #"{"v":1,"k":"channel","dk":"c","a":"Ann","b":""}"#)
    XCTAssertEqual(PushPresentation.make(payload: authorOnly, scope: "s", config: .default).body, "Ann")
  }

  func testAScheduledTaskShowsItsResult() throws {
    let shown = PushPresentation.make(
      payload: try payload("hermes_cron"), scope: "hermes:x", config: .default)

    XCTAssertEqual(shown.title, "Morning briefing")
    XCTAssertEqual(shown.body, "3 new issues, 1 failing build on main.")
    XCTAssertEqual(shown.threadIdentifier, "hermes:x|cron:a1b2c3d4e5f6")
  }

  func testThreadsAreKeptApartPerAccount() throws {
    let reply = try payload("owui_reply")

    XCTAssertNotEqual(
      PushPresentation.make(payload: reply, scope: "owui:a", config: .default).threadIdentifier,
      PushPresentation.make(payload: reply, scope: "owui:b", config: .default).threadIdentifier)
  }

  func testATestPushUsesTheTestStrings() throws {
    var config = PushConfig.default
    config.strings = [PushStrings.testTitle: "Push funktioniert", PushStrings.testBody: "Entschlüsselt."]

    let shown = PushPresentation.make(payload: try payload("test"), scope: "owui:acct-1", config: config)

    XCTAssertEqual(shown.title, "Push funktioniert")
    XCTAssertEqual(shown.body, "Entschlüsselt.")
    // No group: the scope keeps an account's notifications together.
    XCTAssertEqual(shown.threadIdentifier, "owui:acct-1")
  }

  func testEmptyTitlesFallBackToLocalizedKindTitles() throws {
    let config = PushConfig(
      enabled: true, sound: false, enabledKinds: [], disabledScopes: [], scopeLabels: [:],
      showScopeLabel: false,
      strings: [
        PushStrings.replyTitle: "Neue Antwort",
        PushStrings.replyFailedTitle: "Antwort fehlgeschlagen",
        PushStrings.replyFailedBody: "Fehler.",
        PushStrings.channelTitle: "Neue Nachricht",
        PushStrings.cronTitle: "   ",
      ])
    let expected: [(String, String, String)] = [
      ("reply", "Neue Antwort", ""),
      ("reply_failed", "Antwort fehlgeschlagen", "Fehler."),
      ("channel", "Neue Nachricht", ""),
      // Blank translations fall back to English.
      ("cron", "Scheduled task finished", ""),
    ]
    for (kind, title, body) in expected {
      let shown = PushPresentation.make(
        payload: try payload(json: #"{"v":1,"k":"\#(kind)","dk":"d","t":""}"#),
        scope: "s", config: config)
      XCTAssertEqual(shown.title, title, kind)
      XCTAssertEqual(shown.body, body, kind)
      XCTAssertFalse(shown.playsSound, kind)
    }
  }

  func testTheFallbackIsLocalizedWithEnglishDefaults() {
    XCTAssertTrue(PushPresentation.fallback(config: .default) == ("Conduit", "New notification"))

    var config = PushConfig.default
    config.strings = [PushStrings.fallbackTitle: "Conduit", PushStrings.fallbackBody: "Nouvelle notification"]
    XCTAssertTrue(PushPresentation.fallback(config: config) == ("Conduit", "Nouvelle notification"))
  }

  func testConfigAllowsOnlyWhatIsSwitchedOn() {
    var config = PushConfig.default
    XCTAssertTrue(config.allows(.reply, scope: "owui:a"))

    config.disabledScopes = ["owui:a"]
    XCTAssertFalse(config.allows(.reply, scope: "owui:a"))
    XCTAssertTrue(config.allows(.reply, scope: "owui:b"))

    config.enabledKinds = ["channel"]
    XCTAssertFalse(config.allows(.reply, scope: "owui:b"))
    XCTAssertTrue(config.allows(.channel, scope: "owui:b"))

    config.enabled = false
    XCTAssertFalse(config.allows(.channel, scope: "owui:b"))
  }
}
