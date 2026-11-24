import Foundation

/// What a call fails with: the core's error as it sent it, or one this side
/// made from a JSON-RPC error that carried none.
public struct RpcError: Error, Codable, Equatable, Sendable {
  /// The JSON-RPC error code every core error goes out under.
  public static let jsonRpcCode = -32000

  public var code: ErrorCode
  /// Placeholder values for the localized message.
  public var args: [String: String]
  /// Developer-facing detail; never shown to the user.
  public var debugMessage: String?
  /// Whether retrying the same request could plausibly succeed.
  public var retryable: Bool

  public init(
    code: ErrorCode,
    args: [String: String] = [:],
    debugMessage: String? = nil,
    retryable: Bool = false
  ) {
    self.code = code
    self.args = args
    self.debugMessage = debugMessage
    self.retryable = retryable
  }

  /// An error this side found, such as a reply it could not read.
  public static func `internal`(_ debugMessage: String) -> RpcError {
    RpcError(code: .internal, debugMessage: debugMessage)
  }

  private enum CodingKeys: String, CodingKey {
    case code, args, debugMessage, retryable
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    code = try container.decode(ErrorCode.self, forKey: .code)
    args = try container.decodeIfPresent([String: String].self, forKey: .args) ?? [:]
    debugMessage = try container.decodeIfPresent(String.self, forKey: .debugMessage)
    retryable = try container.decodeIfPresent(Bool.self, forKey: .retryable) ?? false
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(code, forKey: .code)
    try container.encode(args, forKey: .args)
    try container.encodeIfPresent(debugMessage, forKey: .debugMessage)
    try container.encode(retryable, forKey: .retryable)
  }

  /// The error a JSON-RPC error object stands for: the core's own when it
  /// carries one, else one named after the standard JSON-RPC code.
  public init(errorObject: ErrorObject) {
    if errorObject.code == RpcError.jsonRpcCode,
      let data = errorObject.data,
      case .object = data,
      let decoded = try? data.decode(RpcError.self)
    {
      self = decoded
      return
    }
    let code: ErrorCode
    switch errorObject.code {
    case -32601: code = .methodNotFound
    case -32602: code = .invalidParams
    case -32700, -32600: code = .protocolViolation
    default: code = .internal
    }
    self.init(code: code, debugMessage: errorObject.message)
  }

  /// The JSON-RPC error object this error goes out as.
  public var errorObject: ErrorObject {
    ErrorObject(
      code: RpcError.jsonRpcCode,
      message: debugMessage ?? code.rawValue,
      data: try? JSONValue(encoding: self)
    )
  }
}
