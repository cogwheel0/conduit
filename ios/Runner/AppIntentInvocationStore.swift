import CryptoKit
import Foundation

let appIntentNativeDispatchStateKey = "_nativeDispatchState"
let appIntentNativeDispatchNotDispatched = "notDispatched"
let appIntentNativeDispatchCompleted = "completed"
let appIntentNativeDispatchIndeterminate = "indeterminate"
let appIntentNativeOwnedFilePathKey = "_nativeOwnedFilePath"

struct AppIntentInvocationLease: Equatable {
    let invocationId: String
    fileprivate let fingerprint: String
}

/// Persists the identity of an invocation whose dispatch outcome was
/// indeterminate. App Intents does not expose an execution identifier, so a
/// retry is correlated by a privacy-safe digest of the intent and its
/// canonical inputs. Completed and provably-undispatched calls immediately
/// release their lease; only an interrupted dispatched call remains reusable.
final class AppIntentInvocationStore: @unchecked Sendable {
    private struct Record: Codable, Equatable {
        let invocationId: String
        let fingerprint: String
        var expiresAtMilliseconds: Int64
    }

    private struct LegacyRecord: Codable {
        let invocationId: String
        let expiresAtMilliseconds: Int64
    }

    static let shared = AppIntentInvocationStore()

    private static let defaultsKey =
        "app.cogwheel.conduit.app-intent-invocations-v1"
    private static let leaseLifetimeMilliseconds: Int64 = 5 * 60 * 1_000

    private let lock = NSLock()
    private let defaults: UserDefaults
    private let nowMilliseconds: () -> Int64
    // Activity is intentionally process-local. A record left behind by
    // process termination must become retryable when the next process starts.
    private var activeInvocationIds = Set<String>()

    init(
        defaults: UserDefaults = .standard,
        nowMilliseconds: @escaping () -> Int64 = {
            Int64(Date().timeIntervalSince1970 * 1_000)
        }
    ) {
        self.defaults = defaults
        self.nowMilliseconds = nowMilliseconds
    }

    func lease(
        identifier: String,
        canonicalParameters: [String: String]
    ) -> AppIntentInvocationLease {
        let fingerprint = Self.fingerprint(
            identifier: identifier,
            canonicalParameters: canonicalParameters
        )
        lock.lock()
        defer { lock.unlock() }

        let now = nowMilliseconds()
        var records = readRecordsLocked().filter {
            $0.value.expiresAtMilliseconds > now
        }
        activeInvocationIds.formIntersection(records.keys)
        if let reusable = records.values
            .filter({
                !activeInvocationIds.contains($0.invocationId) &&
                    $0.fingerprint == fingerprint &&
                    UUID(uuidString: $0.invocationId) != nil
            })
            .max(by: {
                if $0.expiresAtMilliseconds == $1.expiresAtMilliseconds {
                    return $0.invocationId < $1.invocationId
                }
                return $0.expiresAtMilliseconds < $1.expiresAtMilliseconds
            }) {
            var renewed = reusable
            renewed.expiresAtMilliseconds =
                now + Self.leaseLifetimeMilliseconds
            records[renewed.invocationId] = renewed
            activeInvocationIds.insert(renewed.invocationId)
            persistLocked(records)
            return AppIntentInvocationLease(
                invocationId: renewed.invocationId,
                fingerprint: fingerprint
            )
        }

        let invocationId = UUID().uuidString.lowercased()
        records[invocationId] = Record(
            invocationId: invocationId,
            fingerprint: fingerprint,
            expiresAtMilliseconds: now + Self.leaseLifetimeMilliseconds
        )
        activeInvocationIds.insert(invocationId)
        persistLocked(records)
        return AppIntentInvocationLease(
            invocationId: invocationId,
            fingerprint: fingerprint
        )
    }

    func resolve(
        _ lease: AppIntentInvocationLease,
        dispatchState: String?
    ) {
        lock.lock()
        defer { lock.unlock() }
        var records = readRecordsLocked()
        activeInvocationIds.remove(lease.invocationId)
        guard var record = records[lease.invocationId],
              record.fingerprint == lease.fingerprint else { return }
        if dispatchState == appIntentNativeDispatchIndeterminate {
            record.expiresAtMilliseconds =
                nowMilliseconds() + Self.leaseLifetimeMilliseconds
            records[lease.invocationId] = record
        } else {
            records.removeValue(forKey: lease.invocationId)
        }
        persistLocked(records)
    }

    static func fingerprint(
        identifier: String,
        canonicalParameters: [String: String]
    ) -> String {
        var input = Data()
        func append(_ value: String) {
            let bytes = Data(value.utf8)
            var length = UInt64(bytes.count).bigEndian
            withUnsafeBytes(of: &length) { input.append(contentsOf: $0) }
            input.append(bytes)
        }
        append(identifier)
        for key in canonicalParameters.keys.sorted() {
            append(key)
            append(canonicalParameters[key] ?? "")
        }
        return SHA256.hash(data: input)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func readRecordsLocked() -> [String: Record] {
        guard let data = defaults.data(forKey: Self.defaultsKey) else {
            return [:]
        }
        if let records = try? JSONDecoder().decode(
            [String: Record].self,
            from: data
        ) {
            return records
        }
        guard let legacyRecords = try? JSONDecoder().decode(
            [String: LegacyRecord].self,
            from: data
        ) else { return [:] }
        return legacyRecords.reduce(into: [:]) { records, entry in
            let (fingerprint, legacy) = entry
            guard UUID(uuidString: legacy.invocationId) != nil else { return }
            records[legacy.invocationId] = Record(
                invocationId: legacy.invocationId,
                fingerprint: fingerprint,
                expiresAtMilliseconds: legacy.expiresAtMilliseconds
            )
        }
    }

    private func persistLocked(_ records: [String: Record]) {
        if records.isEmpty {
            defaults.removeObject(forKey: Self.defaultsKey)
        } else if let data = try? JSONEncoder().encode(records) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
        // App Intent execution may be terminated immediately after perform()
        // returns; flush the tiny lease record before exposing the result.
        defaults.synchronize()
    }
}

/// Exactly-once bridge between callback-based Pigeon calls and async App
/// Intents. Cancellation can race continuation installation, so the gate also
/// retains an early terminal payload until the continuation is ready.
final class AppIntentInvocationCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<[String: Any], Never>?
    private var earlyPayload: [String: Any]?
    private var resolved = false
    private var dispatched = false

    var isResolved: Bool {
        lock.lock()
        let value = resolved
        lock.unlock()
        return value
    }

    func install(
        _ continuation: CheckedContinuation<[String: Any], Never>
    ) {
        lock.lock()
        if resolved {
            let payload = earlyPayload ?? Self.failurePayload(
                "App Intent was cancelled.",
                dispatchState: appIntentNativeDispatchNotDispatched
            )
            earlyPayload = nil
            lock.unlock()
            continuation.resume(returning: payload)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    /// Atomically claims the right to send the Pigeon message.
    func beginDispatch() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !resolved, !dispatched else { return false }
        dispatched = true
        return true
    }

    @discardableResult
    func resolveCompleted(_ payload: [String: Any]) -> Bool {
        resolve(
            Self.payload(
                payload,
                dispatchState: appIntentNativeDispatchCompleted
            )
        )
    }

    @discardableResult
    func resolveTransportFailure(_ message: String) -> Bool {
        resolve(Self.failurePayload(
            message,
            dispatchState: appIntentNativeDispatchIndeterminate
        ))
    }

    @discardableResult
    func resolveNotDispatched(_ message: String) -> Bool {
        resolve(Self.failurePayload(
            message,
            dispatchState: appIntentNativeDispatchNotDispatched
        ))
    }

    @discardableResult
    func resolveInterrupted(_ message: String) -> Bool {
        lock.lock()
        let dispatchState = dispatched
            ? appIntentNativeDispatchIndeterminate
            : appIntentNativeDispatchNotDispatched
        guard !resolved else {
            lock.unlock()
            return false
        }
        resolved = true
        let payload = Self.failurePayload(
            message,
            dispatchState: dispatchState
        )
        let callback = continuation
        continuation = nil
        if callback == nil {
            earlyPayload = payload
        }
        lock.unlock()
        callback?.resume(returning: payload)
        return true
    }

    private func resolve(_ payload: [String: Any]) -> Bool {
        lock.lock()
        guard !resolved else {
            lock.unlock()
            return false
        }
        resolved = true
        let callback = continuation
        continuation = nil
        if callback == nil {
            earlyPayload = payload
        }
        lock.unlock()
        callback?.resume(returning: payload)
        return true
    }

    private static func payload(
        _ payload: [String: Any],
        dispatchState: String
    ) -> [String: Any] {
        var result = payload
        result[appIntentNativeDispatchStateKey] = dispatchState
        return result
    }

    private static func failurePayload(
        _ message: String,
        dispatchState: String
    ) -> [String: Any] {
        payload(
            ["success": false, "error": message],
            dispatchState: dispatchState
        )
    }
}
