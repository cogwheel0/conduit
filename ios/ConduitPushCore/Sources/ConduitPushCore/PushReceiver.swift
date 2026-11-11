import Foundation

/// Why a push is not shown with content.
public enum PushRejection: Equatable {
  /// No `cp` envelope, or one without a readable sid and body.
  case malformedEnvelope
  /// A `cp` envelope of a version this build does not understand.
  case unsupportedEnvelope
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

  /// Whether the extension may drop the push once Apple grants the
  /// notification filtering entitlement. The entitlement request commits to
  /// dropping only pushes that fail authenticated decryption, duplicates
  /// (`PushReceiveOutcome.duplicate`), and kinds or accounts the user turned
  /// off on the device.
  ///
  /// - A malformed envelope carries nothing that could pass authenticated
  ///   decryption (no envelope, no sid, or a body that is not base64url), so
  ///   it counts as undecryptable and may go, as may an unknown sid, whose
  ///   push no key on this device can authenticate.
  /// - An unsupported envelope version is not known to be undecryptable: it
  ///   may be a genuine push from a newer relay, so it stays.
  /// - An invalid payload passed authenticated decryption, so it is not
  ///   undecryptable either and stays, as does unreadable storage.
  public var mayDrop: Bool {
    switch self {
    case .malformedEnvelope, .unknownSubscription, .undecryptable, .switchedOff:
      return true
    case .unsupportedEnvelope, .storageUnavailable, .invalidPayload:
      return false
    }
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
  /// Show it.
  case deliver(PushDelivery)
  /// Already shown, by an earlier push or by the app. The relay collapses
  /// repeats of a message (`apns-collapse-id` is its `Topic`), so this
  /// notification replaces the one on screen: the delivery is what to show
  /// again, quietly, unless the extension may drop it.
  case duplicate(PushDelivery)
  /// Not shown with content. `scope` is the subscription's, when the sid is
  /// known, so even the generic notification can be cleared with its account.
  case reject(PushRejection, scope: String?)
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
      let reason: PushRejection =
        PushEnvelope.hasOtherVersion(userInfo) ? .unsupportedEnvelope : .malformedEnvelope
      return .reject(reason, scope: nil)
    }

    let found: PushKeyRecord?
    do {
      found = try keys.record(sid: envelope.sid)
    } catch {
      return .reject(.storageUnavailable, scope: nil)
    }
    guard let record = found else { return .reject(.unknownSubscription, scope: nil) }

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
        return .reject(.invalidPayload, scope: record.scope)
      }
    } catch {
      return .reject(.undecryptable, scope: record.scope)
    }

    // A test proves the path works even when its notification is not shown.
    if payload.kind == .test, let nonce = payload.nonce {
      try? configStore.recordVerifiedNonce(nonce, sid: record.sid)
    }

    let config = configStore.load()
    guard config.allows(payload.kind, scope: record.scope) else {
      return .reject(.switchedOff, scope: record.scope)
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
      // The first copy already alerted the user.
      presentation.playsSound = false
    case .replacesLocal(let localId):
      // The local copy already alerted the user.
      replacedId = localId
      presentation.playsSound = false
    }

    let delivery = PushDelivery(
      sid: record.sid,
      scope: record.scope,
      payload: payload,
      presentation: presentation,
      replacesLocalNotificationId: replacedId
    )
    return claim == .duplicate ? .duplicate(delivery) : .deliver(delivery)
  }

  /// The config for text shown without content.
  public func currentConfig() -> PushConfig {
    configStore.load()
  }
}
