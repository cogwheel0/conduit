import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@available(iOS 16.2, *)
struct ConduitRecordingAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var savedSeconds: Double
    }
    var recordingId: String
    var startedAt: Date
}

@available(iOS 17.0, *)
struct StopConduitRecordingIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Stop recording"
    static var openAppWhenRun = false
    static var isDiscoverable = false

    @Parameter(title: "Recording") var recordingId: String

    init() {}
    init(recordingId: String) { self.recordingId = recordingId }

    func perform() async throws -> some IntentResult {
        #if !CONDUIT_WIDGET
        await RecordingActivityBridge.shared.stopFromActivity(recordingId)
        #endif
        return .result()
    }
}

#if CONDUIT_WIDGET
@available(iOS 17.0, *)
struct ConduitRecordingActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ConduitRecordingAttributes.self) { context in
            HStack(spacing: 16) {
                Image(systemName: "waveform").font(.title2).foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 4) {
                    Text(context.isStale ? "Recording interrupted" : "Recording audio")
                        .font(.headline)
                    if context.isStale {
                        Text("\(context.state.savedSeconds, format: .number.precision(.fractionLength(0))) seconds saved")
                    } else {
                        Text(context.attributes.startedAt, style: .timer)
                            .monospacedDigit()
                    }
                }
                Spacer()
                if !context.isStale {
                    Button(intent: StopConduitRecordingIntent(recordingId: context.attributes.recordingId)) {
                        Image(systemName: "stop.fill")
                            .accessibilityLabel("Stop recording")
                    }.buttonStyle(.bordered).tint(.red)
                }
            }
            .padding(20)
            .activityBackgroundTint(Color(.secondarySystemBackground))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("Conduit", systemImage: "waveform").foregroundStyle(.red)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if !context.isStale {
                        Button(intent: StopConduitRecordingIntent(recordingId: context.attributes.recordingId)) {
                            Image(systemName: "stop.fill")
                                .accessibilityLabel("Stop recording")
                        }.buttonStyle(.bordered).tint(.red)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if context.isStale {
                        Text("Recording interrupted. Open Conduit to recover the saved audio.")
                    } else {
                        Text(context.attributes.startedAt, style: .timer).monospacedDigit()
                    }
                }
            } compactLeading: {
                Image(systemName: context.isStale ? "mic.slash" : "waveform").foregroundStyle(.red)
            } compactTrailing: {
                if context.isStale { Image(systemName: "pause.fill") }
                else { Text(context.attributes.startedAt, style: .timer).monospacedDigit().frame(width: 44) }
            } minimal: {
                Image(systemName: context.isStale ? "mic.slash" : "waveform").foregroundStyle(.red)
            }
        }
    }
}
#endif
