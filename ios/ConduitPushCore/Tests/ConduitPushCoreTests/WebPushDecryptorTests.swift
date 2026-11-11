import CryptoKit
import XCTest

@testable import ConduitPushCore

final class WebPushDecryptorTests: XCTestCase {
  func testRFC8291AppendixA() throws {
    let vector = try TestVectors.rfc8291()
    let key = try privateKey(vector.ua_private)
    XCTAssertEqual(key.publicKey.x963Representation, try b64u(vector.ua_public))

    let plaintext = try WebPushDecryptor.decrypt(
      b64u(vector.body), privateKey: key, authSecret: b64u(vector.auth))

    XCTAssertEqual(plaintext, try b64u(vector.plaintext))
    XCTAssertEqual(String(decoding: plaintext, as: UTF8.self), "When I grow up, I want to be a watermelon")
  }

  func testEveryCP1CaseDecryptsToItsPlaintext() throws {
    let cases = try TestVectors.cp1().cases
    XCTAssertFalse(cases.isEmpty)
    for vector in cases {
      let key = try privateKey(vector.ua_private)
      XCTAssertEqual(key.publicKey.x963Representation, try b64u(vector.ua_public), vector.name)
      let body = try b64u(vector.body)
      XCTAssertEqual(body.count, WebPushDecryptor.headerLength + vector.bucket, vector.name)

      let plaintext = try WebPushDecryptor.decrypt(
        body, privateKey: key, authSecret: b64u(vector.auth))

      XCTAssertEqual(plaintext, try b64u(vector.plaintext), vector.name)
    }
  }

  func testEveryRejectBodyIsRejected() throws {
    let reject = try TestVectors.cp1().reject
    let key = try privateKey(reject.ua_private)
    let auth = try b64u(reject.auth)
    let expected: [String: WebPushDecryptionError] = [
      "wrong_auth": .authenticationFailed,
      "not_last_record_delimiter": .missingDelimiter,
      "keyid_not_65": .invalidKeyIdLength,
      "record_size_too_small": .recordSizeTooSmall,
      "truncated": .authenticationFailed,
      "flipped_tag_bit": .authenticationFailed,
      "too_large": .bodyTooLarge,
    ]
    XCTAssertEqual(Set(reject.bodies.keys), Set(expected.keys), "update the expected errors")

    for (name, encoded) in reject.bodies.sorted(by: { $0.key < $1.key }) {
      XCTAssertThrowsError(
        try WebPushDecryptor.decrypt(b64u(encoded), privateKey: key, authSecret: auth), name
      ) { error in
        XCTAssertEqual(error as? WebPushDecryptionError, expected[name], name)
      }
    }
  }

  func testRejectsMoreThanOneRecord() throws {
    let vector = try TestVectors.cp1Case("owui_reply")
    var body = try b64u(vector.body)
    // Record size 18 is valid but smaller than this ciphertext.
    body.replaceSubrange(16..<20, with: [0, 0, 0, 18])

    XCTAssertThrowsError(
      try WebPushDecryptor.decrypt(
        body, privateKey: privateKey(vector.ua_private), authSecret: b64u(vector.auth))
    ) { error in
      XCTAssertEqual(error as? WebPushDecryptionError, .multipleRecords)
    }
  }

  func testRejectsShortBodiesAndBadAuthSecrets() throws {
    let vector = try TestVectors.cp1Case("owui_reply")
    let key = try privateKey(vector.ua_private)
    let body = try b64u(vector.body)

    XCTAssertThrowsError(
      try WebPushDecryptor.decrypt(body.prefix(102), privateKey: key, authSecret: b64u(vector.auth))
    ) { error in
      XCTAssertEqual(error as? WebPushDecryptionError, .bodyTooShort)
    }
    XCTAssertThrowsError(
      try WebPushDecryptor.decrypt(body, privateKey: key, authSecret: Data(count: 15))
    ) { error in
      XCTAssertEqual(error as? WebPushDecryptionError, .invalidAuthSecret)
    }
  }

  func testRejectsAnInvalidSenderKey() throws {
    let vector = try TestVectors.cp1Case("owui_reply")
    var body = try b64u(vector.body)
    body.replaceSubrange(22..<86, with: Data(repeating: 0xFF, count: 64))

    XCTAssertThrowsError(
      try WebPushDecryptor.decrypt(
        body, privateKey: privateKey(vector.ua_private), authSecret: b64u(vector.auth))
    ) { error in
      XCTAssertEqual(error as? WebPushDecryptionError, .invalidSenderKey)
    }
  }

  func testTheWrongKeyFailsAuthentication() throws {
    let vector = try TestVectors.cp1Case("owui_reply")

    XCTAssertThrowsError(
      try WebPushDecryptor.decrypt(
        b64u(vector.body), privateKey: P256.KeyAgreement.PrivateKey(),
        authSecret: b64u(vector.auth))
    ) { error in
      XCTAssertEqual(error as? WebPushDecryptionError, .authenticationFailed)
    }
  }

  func testDebugSubscriptionMatchesTheTestCase() throws {
    let vectors = try TestVectors.cp1()
    let debug = vectors.debug_subscription
    let testCase = try XCTUnwrap(vectors.cases.first { $0.name == "test" })

    XCTAssertEqual(debug.sid, "Y29uZHVpdC1kZWJ1Zy12MQ")
    XCTAssertEqual(testCase.sid, debug.sid)
    XCTAssertEqual(testCase.ua_private, debug.ua_private)
    XCTAssertEqual(testCase.auth, debug.auth)
    XCTAssertEqual(try privateKey(debug.ua_private).publicKey.x963Representation, try b64u(debug.ua_public))
  }

  func testBase64URLRoundTrips() throws {
    for length in 0..<40 {
      let data = PushKeyRecord.randomBytes(length)
      let text = data.base64URLEncodedString()
      XCTAssertFalse(text.contains("="))
      XCTAssertFalse(text.contains("+"))
      XCTAssertFalse(text.contains("/"))
      XCTAssertEqual(Data(base64URLEncoded: text), data)
    }
    XCTAssertEqual(Data(base64URLEncoded: "AQ=="), Data([1]))
    XCTAssertNil(Data(base64URLEncoded: "A"))
    XCTAssertNil(Data(base64URLEncoded: "a*bc"))
  }
}
