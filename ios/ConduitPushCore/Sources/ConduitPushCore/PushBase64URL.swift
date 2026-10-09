import Foundation

extension Data {
  /// Decodes base64url, with or without padding, as every `cp/1` field uses.
  public init?(base64URLEncoded text: String) {
    var base64 = text
      .replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    while base64.hasSuffix("=") { base64.removeLast() }
    switch base64.count % 4 {
    case 0: break
    case 2: base64 += "=="
    case 3: base64 += "="
    default: return nil
    }
    self.init(base64Encoded: base64)
  }

  /// base64url without padding.
  public func base64URLEncodedString() -> String {
    base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }
}
