import Foundation

/// Why a push is not shown with content.
public enum PushRejection: Equatable {
  /// No `cp` envelope, or one this version does not understand.
  case malformedEnvelope
  /// No subscription has this sid.
  case unknownSubscription
  /// The subscription could not be read, for example before the first
  /// unlock. Nothing is known about the push, so it is never dropped.
  case storageUnavailable
  /// Authenticated decryption or the body checks failed.
  case undecryptable
  /// It decrypted, but is not a `cp/1` payload.
  case invalidPayload
  /// The user switched push, this kind, or this account off on this device.
  case switchedOff
  /// Already shown.
  case duplicate

  /// Whether the extension may drop the push once Apple grants the
  /// notification filtering entitlement. These are exactly the cases the
  /// entitlement request commits to: undecryptable or unauthenticated
  /// pushes, duplicates, and kinds or accounts the user turned off.
  public var mayDrop: Bool {
    self != .storageUnavailable
  }
}

/// A push that decrypted and should be shown.
public struct PushDelivery: Equatable {
  public let sid: String
  public let scope: String
  public let payload: PushPayload
  public let presentation: PushPresentation
  /// The app's own notification for the same item, to remove first.
  public let replacesLocalNotificationId: String?
}

public enum PushReceiveOutcome: Equatable {
  case deliver(PushDelivery)
  case reject(PushRejection)
}

/// Decides what a push shows, from the stores alone: no network, only the
/// Keychain, App Group files and CryptoKit (docs/push/PROTOCOL.md section 7).
public final class PushReceiver {
  private let keys: PushKeyStore
  private let configStore: PushConfigStore
  private let ledger: PushLedger

  public init(keys: PushKeyStore, configStore: PushConfigStore, ledger: PushLedger) {
    self.keys = keys
    self.configStore = configStore
    self.ledger = ledger
  }

  public func receive(userInfo: [AnyHashable: Any]) -> PushReceiveOutcome {
    guard let envelope = PushEnvelope(userInfo: userInfo) else {
      return .reject(.malformedEnvelope)
    }

    let found: PushKeyRecord?
    do {
      found = try keys.record(sid: envelope.sid)
    } catch {
      return .reject(.storageUnavailable)
    }
    guard let record = found else { return .reject(.unknownSubscription) }

    let payload: PushPayload
    do {
      let plaintext = try WebPushDecryptor.decrypt(
        envelope.body,
        privateKey: record.agreementKey(),
        authSecret: record.authSecret
      )
      do {
        payload = try PushPayload.parse(plaintext)
      } catch {
        return .reject(.invalidPayload)
      }
    } catch {
      return .reject(.undecryptable)
    }

    // A test proves the path works even when its notification is not shown.
    if payload.kind == .test, let nonce = payload.nonce {
      try? configStore.recordVerifiedNonce(nonce, sid: record.sid)
    }

    let config = configStore.load()
    guard config.allows(payload.kind, scope: record.scope) else {
      return .reject(.switchedOff)
    }

    var presentation = PushPresentation.make(
      payload: payload,
      scope: record.scope,
      config: config
    )
    // An unreadable ledger is not a duplicate: show the push.
    let claim = (try? ledger.claimForPush(payload.appDedupKey(scope: record.scope))) ?? .claimed
    var replacedId: String?
    switch claim {
    case .claimed:
      break
    case .duplicate:
      return .reject(.duplicate)
    case .replacesLocal(let localId):
      // The local copy already alerted the user.
      replacedId = localId
      presentation.playsSound = false
    }

    return .deliver(
      PushDelivery(
        sid: record.sid,
        scope: record.scope,
        payload: payload,
        presentation: presentation,
        replacesLocalNotificationId: replacedId
      )
    )
  }

  /// The config for text shown without content.
  public func currentConfig() -> PushConfig {
    configStore.load()
  }
}
