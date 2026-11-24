import Foundation

// JSON-RPC 2.0 over whatever carries frames to the core: the counterpart of
// the Rust crate's rpc.rs and transport.rs. The types it moves are in
// Generated.swift.

public let jsonRpcVersion = "2.0"

/// The origin the app's requests carry.
public let appOrigin = "app://conduit"

/// The WebSocket subprotocol the core speaks.
public let subprotocol = "conduit.v1"

/// The notification method events arrive under.
public let eventNotification = "event"

/// The subprotocols a connection offers: the protocol's own, then the session
/// token, base64url without padding.
public func subprotocols(sessionToken: String) -> [String] {
  let token = Data(sessionToken.utf8).base64EncodedString()
    .replacingOccurrences(of: "+", with: "-")
    .replacingOccurrences(of: "/", with: "_")
    .replacingOccurrences(of: "=", with: "")
  return [subprotocol, "tk.\(token)"]
}

/// The core's HTTP routes beside the RPC socket.
public enum Routes {
  public static let rpc = "/rpc"
  public static let upload = "/upload"
  public static let transcribe = "/transcribe"
  public static let terminalUpload = "/terminal-upload"

  public static func file(serverId: String, fileId: String) -> String {
    "/files/\(serverId)/\(fileId)"
  }

  public static func tts(jobId: String) -> String { "/tts/\(jobId)" }

  public static func terminal(handle: String) -> String { "/terminal/\(handle)" }
}

/// An RPC method: its name on the wire, what it takes and what it answers.
public protocol ConduitMethod {
  associatedtype Params: Encodable & Sendable
  associatedtype Result: Decodable & Sendable
  static var name: String { get }
}

/// The params of a method that takes none: `{}` on the wire.
public struct EmptyParams: Codable, Equatable, Sendable {
  public init() {}
  public init(from decoder: Decoder) throws {}
  public func encode(to encoder: Encoder) throws {
    _ = encoder.container(keyedBy: NoCodingKeys.self)
  }
}

/// The result of a method that answers nothing: whatever comes is ignored.
public struct EmptyResult: Codable, Equatable, Sendable {
  public init() {}
  public init(from decoder: Decoder) throws {}
  public func encode(to encoder: Encoder) throws {
    _ = encoder.container(keyedBy: NoCodingKeys.self)
  }
}

/// The keys of an object without fields.
struct NoCodingKeys: CodingKey {
  var stringValue: String { "" }
  var intValue: Int? { nil }
  init?(stringValue: String) { nil }
  init?(intValue: Int) { nil }
}

/// A method in the method table, with its params and result DTOs by name.
public struct MethodSpec: Equatable, Sendable {
  public let name: String
  public let params: String?
  public let result: String?
}

/// An event in the event table, with its payload DTO by name.
public struct EventSpec: Equatable, Sendable {
  public let name: String
  public let payload: String?
  public let scoped: Bool
}

/// A JSON-RPC error object.
public struct ErrorObject: Codable, Equatable, Sendable {
  public var code: Int
  public var message: String
  public var data: JSONValue?

  public init(code: Int, message: String, data: JSONValue? = nil) {
    self.code = code
    self.message = message
    self.data = data
  }
}

/// What carries frames to the core. The client sends through it; its owner
/// hands every frame that arrives to `RpcClient.receive(_:)`.
public protocol RpcTransport: Sendable {
  func send(_ frame: Data) async throws
}

/// Calls the core's methods and hands its events on, over a transport.
///
/// Each call gets the next id and waits for the reply with that id. A reply
/// for an id nobody waits on is dropped. Events go to `onEvent` with their
/// envelope; a known event whose payload does not fit its DTO arrives as the
/// decoding error.
public actor RpcClient {
  public typealias EventHandler = @Sendable (EventEnvelope, Result<ConduitEvent, Error>) -> Void

  private let transport: RpcTransport
  private let onEvent: EventHandler?
  private var nextId: Int64 = 1
  private var pending: [Int64: CheckedContinuation<JSONValue, Error>] = [:]

  public init(transport: RpcTransport, onEvent: EventHandler? = nil) {
    self.transport = transport
    self.onEvent = onEvent
  }

  /// Calls `method` with `params` and decodes its reply.
  ///
  /// Cancelling the task stops the wait with `CancellationError`, and a reply
  /// that comes later is dropped. JSON-RPC has no cancel, so the core may
  /// still run the request.
  public func call<M: ConduitMethod>(_ method: M.Type, _ params: M.Params) async throws -> M.Result {
    let id = nextId
    nextId += 1
    let frame = try JSONEncoder().encode(
      OutgoingRequest(jsonrpc: jsonRpcVersion, id: id, method: M.name, params: params)
    )
    let result: JSONValue = try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        // Cancelled before it was asked: nothing goes out.
        if Task.isCancelled {
          continuation.resume(throwing: CancellationError())
          return
        }
        pending[id] = continuation
        Task { [transport] in
          do {
            try await transport.send(frame)
          } catch {
            self.settle(id, with: .failure(error))
          }
        }
      }
    } onCancel: {
      // Settled through the actor, which resumes a call once: a reply that
      // wins the race leaves nothing here to resume.
      Task { await self.settle(id, with: .failure(CancellationError())) }
    }
    do {
      return try result.decode(M.Result.self)
    } catch {
      throw RpcError.internal("\(M.name): undecodable result: \(error)")
    }
  }

  /// Calls `method`, which takes no params.
  public func call<M: ConduitMethod>(_ method: M.Type) async throws -> M.Result
  where M.Params == EmptyParams {
    try await call(method, EmptyParams())
  }

  /// Takes a frame the transport received: a reply settles its call, an
  /// event goes to `onEvent`, and anything else is ignored.
  public func receive(_ frame: Data) {
    guard case .object(let message)? = try? JSONDecoder().decode(JSONValue.self, from: frame)
    else { return }
    if message["method"] == nil, let idValue = message["id"] {
      guard case .int(let id) = idValue else { return }
      if let error = message["error"] {
        let object = try? error.decode(ErrorObject.self)
        settle(
          id,
          with: .failure(
            object.map(RpcError.init(errorObject:))
              ?? RpcError.internal("an error reply the client could not read")))
      } else {
        settle(id, with: .success(message["result"] ?? .null))
      }
      return
    }
    guard message["id"] == nil, message["method"] == .string(eventNotification),
      let params = message["params"],
      let envelope = try? params.decode(EventEnvelope.self)
    else { return }
    let event = Result {
      try ConduitEvent.decode(name: envelope.event, payload: .object(envelope.payload))
    }
    onEvent?(envelope, event)
  }

  /// Fails every call still waiting, as when the transport closes.
  public func failAll(_ error: Error) {
    let waiting = pending
    pending.removeAll()
    for continuation in waiting.values {
      continuation.resume(throwing: error)
    }
  }

  /// How many calls are waiting for their reply.
  var waitingCalls: Int { pending.count }

  private func settle(_ id: Int64, with result: Result<JSONValue, Error>) {
    pending.removeValue(forKey: id)?.resume(with: result)
  }
}

private struct OutgoingRequest<Params: Encodable>: Encodable {
  let jsonrpc: String
  let id: Int64
  let method: String
  let params: Params
}
