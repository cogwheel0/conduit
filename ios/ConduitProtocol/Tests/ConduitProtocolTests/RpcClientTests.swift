import XCTest

@testable import ConduitProtocol

/// A transport that hands every frame the client sends to the test.
private final class MemoryTransport: RpcTransport, @unchecked Sendable {
  let sent: AsyncStream<Data>
  private let continuation: AsyncStream<Data>.Continuation
  private let lock = NSLock()
  private var count = 0

  init() {
    (sent, continuation) = AsyncStream<Data>.makeStream()
  }

  /// How many frames went out.
  var sentCount: Int {
    lock.withLock { count }
  }

  func send(_ frame: Data) async throws {
    lock.withLock { count += 1 }
    continuation.yield(frame)
  }
}

/// Collects the events a client hands on.
private final class EventLog: @unchecked Sendable {
  private let lock = NSLock()
  private var events: [(EventEnvelope, Result<ConduitEvent, Error>)] = []

  func append(_ envelope: EventEnvelope, _ event: Result<ConduitEvent, Error>) {
    lock.lock()
    events.append((envelope, event))
    lock.unlock()
  }

  var all: [(EventEnvelope, Result<ConduitEvent, Error>)] {
    lock.lock()
    defer { lock.unlock() }
    return events
  }
}

final class RpcClientTests: XCTestCase {
  private func frame(_ json: JSONValue) throws -> Data {
    try JSONEncoder().encode(json)
  }

  /// The next frame the client sent, as JSON.
  private func nextSent(_ iterator: inout AsyncStream<Data>.Iterator) async throws -> [String: JSONValue] {
    guard let data = await iterator.next(),
      case .object(let request) = try JSONDecoder().decode(JSONValue.self, from: data)
    else {
      XCTFail("the client sent nothing")
      return [:]
    }
    return request
  }

  func testRepliesSettleTheCallsWithTheirIdsInAnyOrder() async throws {
    let transport = MemoryTransport()
    let client = RpcClient(transport: transport)
    var sent = transport.sent.makeAsyncIterator()

    async let first = client.call(Methods.SystemPing.self)
    let firstRequest = try await nextSent(&sent)
    async let second = client.call(Methods.SystemPing.self)
    let secondRequest = try await nextSent(&sent)

    XCTAssertEqual(firstRequest["jsonrpc"], .string("2.0"))
    XCTAssertEqual(firstRequest["method"], .string("system.ping"))
    XCTAssertEqual(firstRequest["params"], .object([:]))
    XCTAssertNotEqual(firstRequest["id"], secondRequest["id"])

    // The second is answered first.
    for (request, uptime) in [(secondRequest, 2), (firstRequest, 1)] {
      await client.receive(
        try frame(
          .object([
            "jsonrpc": .string("2.0"), "id": request["id"]!,
            "result": .object(["uptimeMs": .int(Int64(uptime)), "serverTimeMs": .int(0)]),
          ])))
    }
    let (one, two) = try await (first, second)
    XCTAssertEqual(one.uptimeMs, 1)
    XCTAssertEqual(two.uptimeMs, 2)
  }

  func testAnErrorReplyThrowsTheCoresError() async throws {
    let transport = MemoryTransport()
    let client = RpcClient(transport: transport)
    var sent = transport.sent.makeAsyncIterator()

    async let call = client.call(Methods.SystemPing.self)
    let request = try await nextSent(&sent)
    await client.receive(
      try frame(
        .object([
          "jsonrpc": .string("2.0"), "id": request["id"]!,
          "error": .object([
            "code": .int(-32000), "message": .string("slow down"),
            "data": .object(["code": .string("net.serverError"), "retryable": .bool(true)]),
          ]),
        ])))
    do {
      _ = try await call
      XCTFail("the call succeeded")
    } catch let error as RpcError {
      XCTAssertEqual(error.code, .serverError)
      XCTAssertTrue(error.retryable)
    }
  }

  func testAReplyForAnIdNobodyWaitsOnIsDropped() async throws {
    let transport = MemoryTransport()
    let client = RpcClient(transport: transport)
    var sent = transport.sent.makeAsyncIterator()

    async let call = client.call(Methods.SystemPing.self)
    let request = try await nextSent(&sent)
    await client.receive(
      try frame(
        .object([
          "jsonrpc": .string("2.0"), "id": .int(999),
          "result": .object(["uptimeMs": .int(9), "serverTimeMs": .int(9)]),
        ])))
    await client.receive(
      try frame(
        .object([
          "jsonrpc": .string("2.0"), "id": request["id"]!,
          "result": .object(["uptimeMs": .int(3), "serverTimeMs": .int(4)]),
        ])))
    let pong = try await call
    XCTAssertEqual(pong.uptimeMs, 3)
  }

  func testEventsArriveDecodedWithTheirEnvelope() async throws {
    let log = EventLog()
    let client = RpcClient(transport: MemoryTransport()) { log.append($0, $1) }

    await client.receive(
      try frame(
        .object([
          "jsonrpc": .string("2.0"), "method": .string("event"),
          "params": .object([
            "event": .string("turn.delta"), "seq": .int(7), "scope": .string("chat-1"),
            "payload": .object([
              "chatId": .string("chat-1"), "messageId": .string("m1"), "text": .string("Hel"),
            ]),
          ]),
        ])))

    let events = log.all
    XCTAssertEqual(events.count, 1)
    XCTAssertEqual(events.first?.0.seq, 7)
    XCTAssertEqual(events.first?.0.scope, "chat-1")
    guard case .success(.turnDelta(let delta))? = events.first?.1 else {
      return XCTFail("not a turn delta: \(String(describing: events.first?.1))")
    }
    XCTAssertEqual(delta.text, "Hel")
  }

  func testAnUnknownEventArrivesAsItCame() async throws {
    let log = EventLog()
    let client = RpcClient(transport: MemoryTransport()) { log.append($0, $1) }
    let payload: JSONValue = .object(["answer": .array([.int(42)])])

    await client.receive(
      try frame(
        .object([
          "jsonrpc": .string("2.0"), "method": .string("event"),
          "params": .object([
            "event": .string("future.thing"), "seq": .int(4), "payload": payload,
          ]),
        ])))

    guard case .success(let event)? = log.all.first?.1 else {
      return XCTFail("no event")
    }
    XCTAssertEqual(event, .unknown(name: "future.thing", payload: payload))
  }

  private func pong(_ id: JSONValue, uptime: Int64) throws -> Data {
    try frame(
      .object([
        "jsonrpc": .string("2.0"), "id": id,
        "result": .object(["uptimeMs": .int(uptime), "serverTimeMs": .int(0)]),
      ]))
  }

  func testACancelledCallStopsWaitingAndItsLateReplyIsDropped() async throws {
    let transport = MemoryTransport()
    let client = RpcClient(transport: transport)
    var sent = transport.sent.makeAsyncIterator()

    let call = Task { try await client.call(Methods.SystemPing.self) }
    let request = try await nextSent(&sent)
    call.cancel()
    do {
      _ = try await call.value
      XCTFail("the call succeeded")
    } catch is CancellationError {}
    let waiting = await client.waitingCalls
    XCTAssertEqual(waiting, 0)

    // The reply comes after all: nobody waits on it, and the next call
    // still gets its own.
    await client.receive(try pong(request["id"]!, uptime: 1))
    async let next = client.call(Methods.SystemPing.self)
    let nextRequest = try await nextSent(&sent)
    await client.receive(try pong(nextRequest["id"]!, uptime: 2))
    let answer = try await next
    XCTAssertEqual(answer.uptimeMs, 2)
  }

  func testACallCancelledBeforeItStartsSendsNothing() async throws {
    let transport = MemoryTransport()
    let client = RpcClient(transport: transport)

    let call = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await client.call(Methods.SystemPing.self)
    }
    do {
      _ = try await call.value
      XCTFail("the call succeeded")
    } catch is CancellationError {}
    let waiting = await client.waitingCalls
    XCTAssertEqual(waiting, 0)
    XCTAssertEqual(transport.sentCount, 0)
  }

  func testACancelRacingTheReplySettlesTheCallOnce() async throws {
    let transport = MemoryTransport()
    let client = RpcClient(transport: transport)
    var sent = transport.sent.makeAsyncIterator()

    for round in 1...20 {
      let call = Task { try await client.call(Methods.SystemPing.self) }
      let request = try await nextSent(&sent)
      let replyFrame = try pong(request["id"]!, uptime: Int64(round))
      async let reply: Void = client.receive(replyFrame)
      call.cancel()
      await reply
      // Either outcome, never both: a second resume would trap.
      do {
        let answer = try await call.value
        XCTAssertEqual(answer.uptimeMs, round)
      } catch is CancellationError {}
      let waiting = await client.waitingCalls
      XCTAssertEqual(waiting, 0)
    }
  }

  func testCallsStillWaitingFailWhenTheTransportCloses() async throws {
    let transport = MemoryTransport()
    let client = RpcClient(transport: transport)
    var sent = transport.sent.makeAsyncIterator()

    async let call = client.call(Methods.SystemPing.self)
    _ = try await nextSent(&sent)
    await client.failAll(RpcError.internal("closed"))
    do {
      _ = try await call
      XCTFail("the call succeeded")
    } catch let error as RpcError {
      XCTAssertEqual(error.debugMessage, "closed")
    }
  }
}
