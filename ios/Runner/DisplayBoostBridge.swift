import Flutter
import QuartzCore
import UIKit

/// Holds the ProMotion panel at its peak refresh rate while the user is
/// actively interacting with a scroll surface.
///
/// iOS drops an idle display to 10–40 Hz to save power and ramps back up
/// reactively. Flutter's engine only requests higher rates after frames start
/// arriving late, so the first ~fraction of a drag renders at 40 Hz on a
/// 120 Hz panel (frame-cadence profiling showed drags pinned at ~24 ms
/// intervals). UIKit avoids this by boosting the panel on touch-down for its
/// own gesture-driven views; this bridge gives Flutter surfaces the same
/// behavior: an otherwise-idle CADisplayLink with a fixed 120 Hz
/// preferredFrameRateRange. The system honors the maximum range across all
/// active display links, so while this link runs, the panel stays at peak.
///
/// The link renders nothing — its callback is empty — so its only cost is
/// the panel refresh power draw during interactions, matching native apps.
final class DisplayBoostBridge: NSObject {
  static let shared = DisplayBoostBridge()

  private static let channelName = "app.cogwheel.conduit/display_boost"
  /// Dart releases the boost explicitly; this cap only covers a Dart-side
  /// stall (hot restart mid-drag) so a leaked boost cannot pin the panel.
  private static let safetyTimeout: TimeInterval = 10

  private var displayLink: CADisplayLink?
  private var safetyTimer: Timer?

  private override init() {
    super.init()
  }

  func configure(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: Self.channelName,
      binaryMessenger: messenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "begin":
        self?.begin()
        result(nil)
      case "end":
        self?.end()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func begin() {
    DispatchQueue.main.async { [self] in
      armSafetyTimer()
      if let link = displayLink {
        link.isPaused = false
        return
      }
      guard let maxRate = maxScreenRefreshRate(), maxRate > 60 else {
        // Standard 60 Hz panel: nothing to boost.
        return
      }
      let link = CADisplayLink(target: self, selector: #selector(onTick))
      link.preferredFrameRateRange = CAFrameRateRange(
        minimum: Float(maxRate),
        maximum: Float(maxRate),
        preferred: Float(maxRate)
      )
      link.add(to: .main, forMode: .common)
      displayLink = link
    }
  }

  private func end() {
    DispatchQueue.main.async { [self] in
      safetyTimer?.invalidate()
      safetyTimer = nil
      displayLink?.isPaused = true
    }
  }

  private func armSafetyTimer() {
    safetyTimer?.invalidate()
    safetyTimer = Timer.scheduledTimer(
      withTimeInterval: Self.safetyTimeout,
      repeats: false
    ) { [weak self] _ in
      self?.displayLink?.isPaused = true
      self?.safetyTimer = nil
    }
  }

  private func maxScreenRefreshRate() -> Int? {
    let rates = UIApplication.shared.connectedScenes
      .compactMap { ($0 as? UIWindowScene)?.screen.maximumFramesPerSecond }
    return rates.max() ?? UIScreen.main.maximumFramesPerSecond
  }

  @objc private func onTick(_ link: CADisplayLink) {
    // Intentionally empty: the link exists purely to hold the panel's
    // refresh-rate floor. Flutter's own vsync pipeline drives rendering.
  }
}
