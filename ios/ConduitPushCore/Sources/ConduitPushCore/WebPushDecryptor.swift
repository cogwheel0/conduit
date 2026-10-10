import CryptoKit
import Foundation

/// Why a Web Push body was refused. Every case is final: the push is never
/// shown with content.
public enum WebPushDecryptionError: Error, Equatable {
  case bodyTooLarge
  case bodyTooShort
  case invalidAuthSecret
  case invalidKeyIdLength
  case recordSizeTooSmall
  case multipleRecords
  case invalidSenderKey
  case authenticationFailed
  case missingDelimiter
}

/// Decrypts Web Push bodies (RFC 8291 with the RFC 8188 `aes128gcm` coding)
/// under the stricter rules of docs/push/PROTOCOL.md section 3.
///
/// Uses only CryptoKit: P-256 ECDH, HKDF built from HMAC-SHA256, and AES-GCM.
public enum WebPushDecryptor {
  /// salt (16) + record size (4) + key id length (1) + sender key (65).
  public static let headerLength = 86
  public static let tagLength = 16
  /// The header plus the largest padding bucket (2048).
  public static let maximumBodyLength = 2134

  static let saltLength = 16
  static let authSecretLength = 16
  static let keyIdLength = 65
  static let minimumRecordSize: UInt32 = 18
  static let lastRecordDelimiter: UInt8 = 0x02

  private static let keyInfo = Data("WebPush: info".utf8) + [0]
  private static let contentKeyInfo = Data("Content-Encoding: aes128gcm".utf8) + [0]
  private static let nonceInfo = Data("Content-Encoding: nonce".utf8) + [0]

  /// Returns the plaintext of a single-record body, without its padding.
  public static func decrypt(
    _ body: Data,
    privateKey: P256.KeyAgreement.PrivateKey,
    authSecret: Data
  ) throws -> Data {
    let bytes = [UInt8](body)
    guard bytes.count <= maximumBodyLength else {
      throw WebPushDecryptionError.bodyTooLarge
    }
    guard bytes.count >= headerLength + tagLength + 1 else {
      throw WebPushDecryptionError.bodyTooShort
    }
    guard authSecret.count == authSecretLength else {
      throw WebPushDecryptionError.invalidAuthSecret
    }

    let salt = Data(bytes[0..<saltLength])
    let recordSize = bytes[16..<20].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    guard Int(bytes[20]) == keyIdLength else {
      throw WebPushDecryptionError.invalidKeyIdLength
    }
    guard recordSize >= minimumRecordSize else {
      throw WebPushDecryptionError.recordSizeTooSmall
    }
    let senderPublicKey = Data(bytes[21..<headerLength])
    let ciphertext = Data(bytes[headerLength...])
    guard ciphertext.count <= Int(recordSize) else {
      throw WebPushDecryptionError.multipleRecords
    }

    let sender: P256.KeyAgreement.PublicKey
    let sharedSecret: SharedSecret
    do {
      sender = try P256.KeyAgreement.PublicKey(x963Representation: senderPublicKey)
      sharedSecret = try privateKey.sharedSecretFromKeyAgreement(with: sender)
    } catch {
      throw WebPushDecryptionError.invalidSenderKey
    }

    let keys = deriveKeys(
      ecdhSecret: sharedSecret.withUnsafeBytes { Data($0) },
      authSecret: authSecret,
      receiverPublicKey: privateKey.publicKey.x963Representation,
      senderPublicKey: senderPublicKey,
      salt: salt
    )

    let record: Data
    do {
      let box = try AES.GCM.SealedBox(
        nonce: AES.GCM.Nonce(data: keys.nonce),
        ciphertext: ciphertext.prefix(ciphertext.count - tagLength),
        tag: ciphertext.suffix(tagLength)
      )
      record = try AES.GCM.open(box, using: SymmetricKey(data: keys.contentKey))
    } catch {
      throw WebPushDecryptionError.authenticationFailed
    }

    // Padding is zero bytes after the delimiter; the last record's
    // delimiter is 0x02 (RFC 8188 section 2).
    let plain = [UInt8](record)
    var end = plain.count
    while end > 0, plain[end - 1] == 0 { end -= 1 }
    guard end > 0, plain[end - 1] == lastRecordDelimiter else {
      throw WebPushDecryptionError.missingDelimiter
    }
    return Data(plain[0..<(end - 1)])
  }

  /// RFC 8291 section 3.4 followed by RFC 8188 section 2.2.
  static func deriveKeys(
    ecdhSecret: Data,
    authSecret: Data,
    receiverPublicKey: Data,
    senderPublicKey: Data,
    salt: Data
  ) -> (contentKey: Data, nonce: Data) {
    let prkKey = hkdfExtract(salt: authSecret, inputKeyMaterial: ecdhSecret)
    let ikm = hkdfExpand(
      prk: prkKey,
      info: keyInfo + receiverPublicKey + senderPublicKey,
      length: 32
    )
    let prk = hkdfExtract(salt: salt, inputKeyMaterial: ikm)
    return (
      hkdfExpand(prk: prk, info: contentKeyInfo, length: 16),
      hkdfExpand(prk: prk, info: nonceInfo, length: 12)
    )
  }

  private static func hkdfExtract(salt: Data, inputKeyMaterial: Data) -> Data {
    Data(HMAC<SHA256>.authenticationCode(for: inputKeyMaterial, using: SymmetricKey(data: salt)))
  }

  /// Every output here fits one SHA-256 block, so expand is a single HMAC.
  private static func hkdfExpand(prk: Data, info: Data, length: Int) -> Data {
    let block = HMAC<SHA256>.authenticationCode(for: info + [1], using: SymmetricKey(data: prk))
    return Data(block).prefix(length)
  }
}
