import ActivityKit
import Flutter
import Foundation

/// Contains only a random capture id and timing. Chat names, transcripts and
/// audio never leave the app's draft store for the lock screen.
@available(iOS 16.2, *)
@MainActor
final class RecordingActivityBridge: NSObject, ConduitBridge {
    static let shared = RecordingActivityBridge()
    private var channel: FlutterMethodChannel?
    private var activity: Activity<ConduitRecordingAttributes>?
    private var generation = 0
    private var currentId: String?

    static func endInterruptedActivities() {
        let interrupted = Activity<ConduitRecordingAttributes>.activities
        Task {
            for activity in interrupted {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    /// Accepts UUID-scoped start/update/end requests; generations reject superseded starts.
    /// Updates carry saved duration only and become stale after 20 seconds without a heartbeat.
    func attach(to host: ConduitBridgeHost) {
        channel?.setMethodCallHandler(nil)
        let channel = FlutterMethodChannel(name: "app.cogwheel.conduit/recording_activity", binaryMessenger: host.messenger)
        self.channel = channel
        channel.setMethodCallHandler { [weak self] call, result in
            guard let self, let data = call.arguments as? [String: Any],
                  let id = data["id"] as? String, UUID(uuidString: id) != nil else {
                result(false)
                return
            }
            Task { @MainActor in
                switch call.method {
                case "start":
                    self.generation += 1
                    self.currentId = id
                    let generation = self.generation
                    let previous = self.activity
                    self.activity = nil
                    await previous?.end(nil, dismissalPolicy: .immediate)
                    guard generation == self.generation,
                          ActivityAuthorizationInfo().areActivitiesEnabled else { result(false); return }
                    do {
                        let now = Date()
                        self.activity = try Activity.request(
                            attributes: ConduitRecordingAttributes(recordingId: id, startedAt: now),
                            content: ActivityContent(state: .init(savedSeconds: 0), staleDate: now.addingTimeInterval(20)),
                            pushType: nil
                        )
                        result(true)
                    } catch { result(false) }
                case "update":
                    guard let activity = self.activity, activity.attributes.recordingId == id else { result(false); return }
                    let now = Date()
                    let savedSeconds = max(0, data["savedSeconds"] as? Double ?? 0)
                    await activity.update(ActivityContent(state: .init(savedSeconds: savedSeconds), staleDate: now.addingTimeInterval(20)))
                    result(true)
                case "end":
                    guard self.currentId == id else { result(false); return }
                    self.generation += 1
                    self.currentId = nil
                    let activity = self.activity
                    self.activity = nil
                    await activity?.end(nil, dismissalPolicy: .immediate)
                    result(true)
                default: result(FlutterMethodNotImplemented)
                }
            }
        }
    }

    /// Awaits Dart acknowledgement for the active capture, or ends an interrupted activity.
    /// Channel acknowledgement alone does not guarantee that capture has stopped.
    func stopFromActivity(_ id: String) async {
        guard let activity, activity.attributes.recordingId == id, let channel else {
            for interrupted in Activity<ConduitRecordingAttributes>.activities where interrupted.attributes.recordingId == id {
                await interrupted.end(nil, dismissalPolicy: .immediate)
            }
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            channel.invokeMethod("stop", arguments: ["id": id]) { _ in continuation.resume() }
        }
    }
}
