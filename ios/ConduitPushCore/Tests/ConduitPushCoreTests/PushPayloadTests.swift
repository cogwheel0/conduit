import XCTest

@testable import ConduitPushCore

final class PushPayloadTests: XCTestCase {
  func testParsesEveryCP1Case() throws {
    for vector in try TestVectors.cp1().cases {
      let plaintext = try b64u(vector.plaintext)
      let payload = try PushPayload.parse(plaintext)

      XCTAssertEqual(payload.json, String(decoding: plaintext, as: UTF8.self), vector.name)
      XCTAssertEqual(payload.appDedupKey(scope: vector.scope), vector.app_dedup_key, vector.name)
    }
  }

  func testParsesAnOpenWebUIReply() throws {
    let payload = try PushPayload.parse(b64u(TestVectors.cp1Case("owui_reply").plaintext))

    XCTAssertEqual(payload.kind, .reply)
    XCTAssertEqual(payload.source, "owui")
    XCTAssertEqual(payload.ids, ["chat": "4f1c2a7e", "msg": "b9d0e3f1"])
    XCTAssertEqual(payload.title, "Trip ideas")
    XCTAssertEqual(payload.body, "Here are three routes along the coast:")
    XCTAssertEqual(payload.timestamp, 1_760_000_000)
    XCTAssertEqual(payload.dedupKey, "chat:4f1c2a7e:b9d0e3f1")
    XCTAssertEqual(payload.group, "chat:4f1c2a7e")
    XCTAssertNil(payload.author)
    XCTAssertNil(payload.nonce)
  }

  func testParsesAChannelMessageWithUnicode() throws {
    let payload = try PushPayload.parse(b64u(TestVectors.cp1Case("owui_channel_unicode").plaintext))

    XCTAssertEqual(payload.kind, .channel)
    XCTAssertEqual(payload.title, "#général")
    XCTAssertEqual(payload.author, "Zoë 🦊")
    XCTAssertEqual(payload.body, "Réunion à 15 h 🗓️ — 会议改到下午三点")
  }

  func testParsesATestPush() throws {
    let payload = try PushPayload.parse(b64u(TestVectors.cp1Case("test").plaintext))

    XCTAssertEqual(payload.kind, .test)
    XCTAssertEqual(payload.nonce, "Nn3wq0Xk")
    XCTAssertEqual(payload.dedupKey, "test:Nn3wq0Xk")
    XCTAssertNil(payload.group)
    XCTAssertEqual(payload.ids, [:])
  }

  func testParsesEveryKind() throws {
    for kind in PushPayload.Kind.allCases {
      let json = #"{"v":1,"k":"\#(kind.rawValue)","dk":"x"}"#
      XCTAssertEqual(try PushPayload.parse(Data(json.utf8)).kind, kind)
    }
  }

  func testRejectsEveryPayloadRejectVector() throws {
    let expected: [String: PushPayloadError] = [
      "version_2": .unsupportedVersion,
      "unknown_kind": .unknownKind,
      "missing_dk": .missingDedupKey,
      "not_an_object": .notAnObject,
      "not_json": .notJSON,
    ]
    let vectors = try TestVectors.cp1().payload_reject
    XCTAssertEqual(Set(vectors.map(\.name)), Set(expected.keys), "update the expected errors")

    for vector in vectors {
      XCTAssertThrowsError(try PushPayload.parse(Data(vector.plaintext.utf8)), vector.name) { error in
        XCTAssertEqual(error as? PushPayloadError, expected[vector.name], vector.name)
      }
    }
  }

  func testRejectsOtherMalformedFields() {
    let cases: [String: PushPayloadError] = [
      #"{"k":"reply","dk":"x"}"#: .unsupportedVersion,
      #"{"v":true,"k":"reply","dk":"x"}"#: .unsupportedVersion,
      #"{"v":"1","k":"reply","dk":"x"}"#: .unsupportedVersion,
      #"{"v":1.5,"k":"reply","dk":"x"}"#: .unsupportedVersion,
      #"{"v":1,"dk":"x"}"#: .unknownKind,
      #"{"v":1,"k":"reply","dk":""}"#: .missingDedupKey,
      #"{"v":1,"k":"reply","dk":7}"#: .missingDedupKey,
      #""reply""#: .notAnObject,
      "": .notJSON,
    ]
    for (json, error) in cases {
      XCTAssertThrowsError(try PushPayload.parse(Data(json.utf8)), json) {
        XCTAssertEqual($0 as? PushPayloadError, error, json)
      }
    }
    XCTAssertThrowsError(try PushPayload.parse(Data([0xFF, 0xFE]))) {
      XCTAssertEqual($0 as? PushPayloadError, .notJSON)
    }
  }

  func testIgnoresUnknownKeysAndBadOptionalFields() throws {
    let json = #"{"v":1,"k":"cron","dk":"cron:j:r","future":{"x":1},"t":5,"ids":{"job":"j","run":7},"g":""}"#
    let payload = try PushPayload.parse(Data(json.utf8))

    XCTAssertEqual(payload.title, "")
    XCTAssertEqual(payload.body, "")
    XCTAssertEqual(payload.ids, ["job": "j"])
    XCTAssertNil(payload.group)
    XCTAssertNil(payload.timestamp)
  }

  func testReadsTheRelayEnvelope() throws {
    let vector = try TestVectors.cp1Case("test")
    let userInfo: [AnyHashable: Any] = [
      "aps": ["mutable-content": 1],
      "cp": ["v": 1, "s": vector.sid, "d": vector.body],
    ]

    let envelope = try XCTUnwrap(PushEnvelope(userInfo: userInfo))

    XCTAssertEqual(envelope.sid, vector.sid)
    XCTAssertEqual(envelope.body, try b64u(vector.body))
    XCTAssertEqual(PushEnvelope.sid(in: userInfo), vector.sid)
  }

  func testRefusesMalformedEnvelopes() {
    let bad: [[AnyHashable: Any]] = [
      [:],
      ["cp": "x"],
      ["cp": ["v": 2, "s": "sid", "d": "AAAA"]],
      ["cp": ["v": 1, "s": "", "d": "AAAA"]],
      ["cp": ["v": 1, "d": "AAAA"]],
      ["cp": ["v": 1, "s": "sid", "d": "not base64!"]],
    ]
    for userInfo in bad {
      XCTAssertNil(PushEnvelope(userInfo: userInfo), "\(userInfo)")
    }
    // Only a different version is unsupported rather than malformed.
    XCTAssertEqual(bad.filter(PushEnvelope.hasOtherVersion).count, 1)
    XCTAssertTrue(PushEnvelope.hasOtherVersion(["cp": ["v": 2]]))
  }

  func testATapOpensOnlyWithTheExtensionsSignature() throws {
    let key = try PushTapKey.load(storage: MemorySecretStorage())
    let tap = PushTap(scope: "owui:acct-1", payloadJSON: #"{"v":1}"#)
    let signed = tap.userInfoValue(signedWith: key)

    XCTAssertEqual(PushTap(userInfo: [PushUserInfoKey.tap: signed], key: key), tap)

    // Unsigned, as a push the extension never saw could carry it.
    var unsigned = signed
    unsigned.removeValue(forKey: "sig")
    XCTAssertNil(PushTap(userInfo: [PushUserInfoKey.tap: unsigned], key: key))
    // Signed by another install.
    let other = try PushTapKey.load(storage: MemorySecretStorage())
    XCTAssertNil(PushTap(userInfo: [PushUserInfoKey.tap: tap.userInfoValue(signedWith: other)], key: key))
    // Another scope or payload under the same signature.
    for (field, value) in [("scope", "owui:acct-2"), ("payload", #"{"v":2}"#), ("sig", "AAAA")] {
      var changed = signed
      changed[field] = value
      XCTAssertNil(PushTap(userInfo: [PushUserInfoKey.tap: changed], key: key), field)
    }
    // The scope and payload can't trade bytes.
    let shifted = PushTap(scope: "owui:acct-1{", payloadJSON: #""v":1}"#)
    var swapped = shifted.userInfoValue(signedWith: key)
    swapped["sig"] = signed["sig"]
    XCTAssertNil(PushTap(userInfo: [PushUserInfoKey.tap: swapped], key: key))

    XCTAssertNil(PushTap(userInfo: [:], key: key))
    XCTAssertNil(PushTap(userInfo: [PushUserInfoKey.tap: ["scope": "x"]], key: key))
  }

  private func delivery() throws -> PushDelivery {
    let payload = try PushPayload.parse(Data(#"{"v":1,"k":"reply","dk":"chat:c:m"}"#.utf8))
    return PushDelivery(
      sid: "sid-1", scope: "owui:acct-1", payload: payload,
      presentation: PushPresentation.make(payload: payload, scope: "owui:acct-1", config: .default),
      replacesLocalNotificationId: nil)
  }

  func testADecryptedNotificationCarriesItsScopeAndASignedTap() throws {
    let key = try PushTapKey.load(storage: MemorySecretStorage())
    // Whatever the push itself carried under Conduit's keys is replaced.
    let original: [AnyHashable: Any] = [
      "aps": ["mutable-content": 1],
      PushUserInfoKey.envelope: ["v": 1, "s": "sid-1", "d": "ciphertext"],
      PushUserInfoKey.tap: ["scope": "owui:evil", "payload": "{}", "sig": "AAAA"],
      PushUserInfoKey.scope: "owui:evil",
      PushUserInfoKey.repeated: true,
    ]

    let userInfo = PushNotificationUserInfo.decrypted(
      original, delivery: try delivery(), tapKey: key, repeated: false)

    XCTAssertNotNil(userInfo["aps"])
    XCTAssertEqual(userInfo[PushUserInfoKey.envelope] as? [String: AnyHashable], ["v": 1, "s": "sid-1"])
    XCTAssertEqual(userInfo[PushUserInfoKey.scope] as? String, "owui:acct-1")
    XCTAssertNil(userInfo[PushUserInfoKey.repeated])
    XCTAssertEqual(
      PushTap(userInfo: userInfo, key: key),
      PushTap(scope: "owui:acct-1", payloadJSON: #"{"v":1,"k":"reply","dk":"chat:c:m"}"#))

    let again = PushNotificationUserInfo.decrypted(
      original, delivery: try delivery(), tapKey: key, repeated: true)
    XCTAssertEqual(again[PushUserInfoKey.repeated] as? Bool, true)
    XCTAssertNotNil(PushTap(userInfo: again, key: key))

    // Without the key there is no tap to open.
    let keyless = PushNotificationUserInfo.decrypted(
      original, delivery: try delivery(), tapKey: nil, repeated: false)
    XCTAssertNil(keyless[PushUserInfoKey.tap])
    XCTAssertEqual(keyless[PushUserInfoKey.scope] as? String, "owui:acct-1")
  }

  func testAGenericNotificationKeepsOnlyItsScope() {
    let original: [AnyHashable: Any] = [
      "aps": ["mutable-content": 1],
      PushUserInfoKey.tap: ["scope": "owui:evil", "payload": "{}", "sig": "AAAA"],
      PushUserInfoKey.scope: "owui:evil",
      PushUserInfoKey.repeated: true,
    ]

    let known = PushNotificationUserInfo.generic(original, scope: "hermes:conn")
    XCTAssertEqual(known[PushUserInfoKey.scope] as? String, "hermes:conn")
    XCTAssertNil(known[PushUserInfoKey.tap])
    XCTAssertNil(known[PushUserInfoKey.repeated])
    XCTAssertNotNil(known["aps"])

    XCTAssertNil(PushNotificationUserInfo.generic(original, scope: nil)[PushUserInfoKey.scope])
  }
}
