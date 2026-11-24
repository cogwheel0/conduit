import XCTest

@testable import ConduitProtocol

/// The Swift types against the Dart protocol's goldens, as the Rust crate's
/// `tests/conformance.rs` checks its own.
///
/// `packages/conduit_protocol/tool/dump_goldens.dart` writes every Dart
/// fixture to `goldens/<name>.json`, `manifest.json` (fixture -> DTO type)
/// and `specs.json` (the method and event tables as the core has them).
enum Goldens {
  static let directory = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()  // ConduitProtocolTests
    .deletingLastPathComponent()  // Tests
    .deletingLastPathComponent()  // ConduitProtocol
    .deletingLastPathComponent()  // ios
    .deletingLastPathComponent()  // repository root
    .appendingPathComponent("packages/conduit_protocol/goldens", isDirectory: true)

  static func json(_ name: String) throws -> JSONValue {
    let data = try Data(contentsOf: directory.appendingPathComponent(name))
    return try JSONDecoder().decode(JSONValue.self, from: data)
  }

  static func manifest() throws -> [String: String] {
    let data = try Data(contentsOf: directory.appendingPathComponent("manifest.json"))
    return try JSONDecoder().decode([String: String].self, from: data)
  }

  /// A golden file that is not what `dump_goldens.dart` writes: the test
  /// that read it fails.
  struct Malformed: Error, CustomStringConvertible {
    let description: String
  }

  static func specs() throws -> [String: JSONValue] {
    guard case .object(let specs) = try json("specs.json") else {
      throw Malformed(description: "specs.json is not an object")
    }
    return specs
  }

  /// The golden of the DTO called `typeName`.
  static func of(_ typeName: String) throws -> JSONValue {
    guard let fixture = try manifest().filter({ $0.value == typeName }).keys.sorted().first
    else {
      XCTFail("no golden for \(typeName)")
      return .null
    }
    return try json("\(fixture).json")
  }
}

final class ConformanceTests: XCTestCase {
  func testEveryGoldenRoundTripsThroughItsSwiftType() throws {
    let manifest = try Goldens.manifest()
    XCTAssertGreaterThan(manifest.count, 200, "only \(manifest.count) goldens")
    var failures: [String] = []
    for (fixture, typeName) in manifest.sorted(by: { $0.key < $1.key }) {
      let golden = try Goldens.json("\(fixture).json")
      do {
        guard let again = try Conformance.roundTrip(typeName, golden) else {
          failures.append("\(fixture): \(typeName) is not a generated type")
          continue
        }
        if again != golden {
          failures.append("\(fixture): \(typeName) came back as \(again)")
        }
      } catch {
        failures.append("\(fixture): \(typeName): \(error)")
      }
    }
    XCTAssert(failures.isEmpty, failures.joined(separator: "\n"))
  }

  func testEverySwiftTypeHasAGolden() throws {
    let covered = Set(try Goldens.manifest().values)
    let missing = Conformance.typeNames.filter { !covered.contains($0) }
    XCTAssert(missing.isEmpty, "no golden for \(missing)")
  }

  func testTheMethodTableMatchesTheCores() throws {
    guard case .array(let methods)? = try Goldens.specs()["methods"] else {
      return XCTFail("specs.json has no methods")
    }
    let expected = methods.map { method -> MethodSpec in
      guard case .object(let fields) = method, case .string(let name)? = fields["name"] else {
        return MethodSpec(name: "?", params: nil, result: nil)
      }
      return MethodSpec(name: name, params: string(fields["params"]), result: string(fields["result"]))
    }
    XCTAssertEqual(methodSpecs, expected)
  }

  func testEveryMethodInTheSpecHasTypes() throws {
    for method in methodSpecs {
      for typeName in [method.params, method.result].compactMap({ $0 }) {
        XCTAssert(Conformance.typeNames.contains(typeName), "\(method.name): \(typeName)")
        XCTAssertNotNil(try Conformance.roundTrip(typeName, Goldens.of(typeName)), method.name)
      }
    }
  }

  func testTheEventTableMatchesTheCores() throws {
    guard case .array(let events)? = try Goldens.specs()["events"] else {
      return XCTFail("specs.json has no events")
    }
    let expected = events.map { event -> EventSpec in
      guard case .object(let fields) = event, case .string(let name)? = fields["name"],
        case .bool(let scoped)? = fields["scoped"]
      else { return EventSpec(name: "?", payload: nil, scoped: false) }
      return EventSpec(name: name, payload: string(fields["payload"]), scoped: scoped)
    }
    XCTAssertEqual(eventSpecs, expected)
  }

  func testEveryEventRoundTripsThroughTheEventEnum() throws {
    for spec in eventSpecs {
      let payload = try spec.payload.map(Goldens.of) ?? .object([:])
      let event = try ConduitEvent.decode(name: spec.name, payload: payload)
      XCTAssertEqual(event.name, spec.name)
      if case .unknown = event { XCTFail("\(spec.name) decoded as unknown") }
      XCTAssertEqual(event.isScoped, spec.scoped, spec.name)
      XCTAssertEqual(try event.payload(), payload, spec.name)
    }
  }

  func testAnUnknownEventIsKeptAsItCame() throws {
    let payload: JSONValue = .object(["answer": .array([.int(42)])])
    let event = try ConduitEvent.decode(name: "future.thing", payload: payload)
    XCTAssertEqual(event, .unknown(name: "future.thing", payload: payload))
    XCTAssertFalse(event.isScoped)
    XCTAssertEqual(try event.payload(), payload)
  }

  func testAKnownEventWithAWrongPayloadIsAnError() throws {
    XCTAssertThrowsError(
      try ConduitEvent.decode(name: "turn.delta", payload: .object(["text": .int(1)])))
    // Without a payload DTO, whatever comes is ignored.
    XCTAssertEqual(
      try ConduitEvent.decode(name: "models.changed", payload: .object(["x": .int(1)])),
      .modelsChanged)
  }

  func testUnknownEnumValuesDecodeAsUnknownAndGoBackAsTheyCame() throws {
    XCTAssertEqual(try JSONValue.string("floating").decode(WindowKind.self), .unknown("floating"))
    XCTAssertEqual(try JSONValue.string("quickAsk").decode(WindowKind.self), .quickAsk)
    XCTAssertEqual(try JSONValue(encoding: WindowKind.unknown("floating")), .string("floating"))
    // An enum with its own `unknown` uses it as the fallback too.
    XCTAssertEqual(
      try JSONValue.string("unknown").decode(ServerReachability.self), .unknown("unknown"))
    XCTAssertEqual(
      try JSONValue(encoding: ServerReachability.unknown("unknown")), .string("unknown"))
    XCTAssertEqual(try JSONValue(encoding: ServerReachability.notOpenWebUi), .string("notOpenWebUi"))
  }

  func testNumbersCompareByExactValue() {
    XCTAssertEqual(JSONValue.int(3), .double(3.0))
    XCTAssertNotEqual(JSONValue.int(9_007_199_254_740_993), .double(9_007_199_254_740_992))
  }

  func testGeneratedFieldsReadAMissingKeyOrANullAsTheirDartDefault() throws {
    let required: [String: JSONValue] = [
      "id": .string("m1"), "channelId": .string("c1"), "createdAtMs": .int(1),
    ]
    // A string, a bool, an int, a list and an enum value.
    let defaulted = ["content", "pinned", "replyCount", "reactions", "senderKind"]
    for asNull in [false, true] {
      var json = required
      if asNull { for key in defaulted { json[key] = .null } }
      let message = try JSONValue.object(json).decode(ChannelMessageDto.self)
      XCTAssertEqual(message.content, "", "null: \(asNull)")
      XCTAssertFalse(message.pinned, "null: \(asNull)")
      XCTAssertEqual(message.replyCount, 0, "null: \(asNull)")
      XCTAssertEqual(message.reactions, [], "null: \(asNull)")
      XCTAssertEqual(message.senderKind, .user, "null: \(asNull)")

      // A nested DTO, whose own fields default too (`files` to true).
      let options = try JSONValue.object(asNull ? ["attachments": .null] : [:])
        .decode(ComposerOptions.self)
      XCTAssertEqual(options.attachments, AttachmentAvailability(), "null: \(asNull)")
      XCTAssertTrue(options.attachments.files, "null: \(asNull)")
      let nested = try JSONValue.object(["attachments": .object(asNull ? ["files": .null] : [:])])
        .decode(ComposerOptions.self)
      XCTAssertTrue(nested.attachments.files, "null: \(asNull)")
    }
  }

  func testCallsAreTypedByTheirMethod() throws {
    XCTAssertEqual(Methods.ChatsTagsAll.name, "chats.tags.all")
    XCTAssertEqual(try JSONValue(encoding: EmptyParams()), .object([:]))
    let pong = try JSONValue.object(["uptimeMs": .int(5), "serverTimeMs": .int(6)])
      .decode(Methods.SystemPing.Result.self)
    XCTAssertEqual(pong.uptimeMs, 5)
    XCTAssertEqual(pong.serverTimeMs, 6)
  }

  func testAConduitErrorComesBackAsItWasSent() throws {
    // As json_rpc_2 sends it: `data` with a `request` key added.
    let object = ErrorObject(
      code: -32000,
      message: "upstream returned 503",
      data: .object([
        "code": .string("net.serverError"),
        "args": .object(["status": .string("503")]),
        "debugMessage": .string("upstream returned 503"),
        "retryable": .bool(true),
        "request": .object(["method": .string("chats.list"), "id": .int(3)]),
      ]))
    let error = RpcError(errorObject: object)
    XCTAssertEqual(error.code, .serverError)
    XCTAssertEqual(error.args["status"], "503")
    XCTAssertTrue(error.retryable)
    XCTAssertEqual(.int(Int64(error.errorObject.code)), try Goldens.specs()["rpcErrorCode"])

    let unknown = RpcError(
      errorObject: ErrorObject(code: -32000, message: "", data: .object(["code": .string("future.code")])))
    XCTAssertEqual(unknown.code, .other("future.code"))
    XCTAssertEqual(unknown.code.rawValue, "future.code")

    let standard = RpcError(errorObject: ErrorObject(code: -32601, message: "Unknown method"))
    XCTAssertEqual(standard.code, .methodNotFound)
    XCTAssertEqual(standard.debugMessage, "Unknown method")
  }

  func testTransportConstantsMatchTheDartOnes() throws {
    let specs = try Goldens.specs()
    XCTAssertEqual(specs["protocolVersion"], .string(protocolVersion))
    XCTAssertEqual(specs["appOrigin"], .string(appOrigin))
    XCTAssertEqual(specs["subprotocol"], .string(subprotocol))
    XCTAssertEqual(specs["eventNotification"], .string(eventNotification))

    guard case .object(let example)? = specs["subprotocolsExample"],
      case .string(let token)? = example["sessionToken"]
    else { return XCTFail("specs.json has no subprotocolsExample") }
    XCTAssertEqual(
      example["protocols"], .array(subprotocols(sessionToken: token).map(JSONValue.string)))

    guard case .object(let routes)? = specs["httpRoutes"] else {
      return XCTFail("specs.json has no httpRoutes")
    }
    XCTAssertEqual(routes["rpc"], .string(Routes.rpc))
    XCTAssertEqual(routes["upload"], .string(Routes.upload))
    XCTAssertEqual(routes["transcribe"], .string(Routes.transcribe))
    XCTAssertEqual(routes["terminalUpload"], .string(Routes.terminalUpload))
    XCTAssertEqual(routes["file"], .string(Routes.file(serverId: "{serverId}", fileId: "{fileId}")))
    XCTAssertEqual(routes["tts"], .string(Routes.tts(jobId: "{jobId}")))
    XCTAssertEqual(routes["terminal"], .string(Routes.terminal(handle: "{handle}")))
  }

  private func string(_ value: JSONValue?) -> String? {
    if case .string(let text)? = value { return text }
    return nil
  }
}
