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
  }

  func testTapRoundTripsThroughUserInfo() throws {
    let tap = PushTap(scope: "owui:acct-1", payloadJSON: #"{"v":1}"#)
    let userInfo: [AnyHashable: Any] = [PushUserInfoKey.tap: tap.userInfoValue]

    XCTAssertEqual(PushTap(userInfo: userInfo), tap)
    XCTAssertNil(PushTap(userInfo: [:]))
    XCTAssertNil(PushTap(userInfo: [PushUserInfoKey.tap: ["scope": "x"]]))
  }
}
