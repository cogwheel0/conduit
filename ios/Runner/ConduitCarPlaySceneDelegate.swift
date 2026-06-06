import CarPlay
import UIKit

@MainActor
final class ConduitCarPlaySceneDelegate: UIResponder,
  CPTemplateApplicationSceneDelegate,
  CPInterfaceControllerDelegate {
  private enum VoiceState {
    static let ready = "ready"
    static let listening = "listening"
    static let working = "working"
    static let paused = "paused"
    static let unavailable = "unavailable"
  }

  private weak var interfaceController: CPInterfaceController?
  private var voiceTemplate: CPVoiceControlTemplate?
  private var hasRequestedLaunchStart = false
  private var didNotifyBridgeConnected = false

  func templateApplicationScene(
    _ templateApplicationScene: CPTemplateApplicationScene,
    didConnect interfaceController: CPInterfaceController
  ) {
    self.interfaceController = interfaceController
    interfaceController.delegate = self
    ConduitCarPlayBridge.shared.onSnapshotChanged = { [weak self] snapshot in
      Task { @MainActor in
        self?.apply(snapshot)
      }
    }

    if #available(iOS 26.4, *) {
      let didStartFlutter = (UIApplication.shared.delegate as? AppDelegate)?
        .ensureCarPlayFlutterEngine() ?? false
      if !didStartFlutter {
        print("ConduitCarPlaySceneDelegate: CarPlay Flutter engine is not ready")
      }

      didNotifyBridgeConnected = true
      ConduitCarPlayBridge.shared.carPlaySceneDidConnect()
      setVoiceRootTemplate(on: interfaceController)
    } else {
      setUnsupportedRootTemplate(on: interfaceController)
    }
  }

  @available(iOS 26.4, *)
  private func setVoiceRootTemplate(on interfaceController: CPInterfaceController) {
    let template = makeVoiceTemplate()
    voiceTemplate = template
    interfaceController.setRootTemplate(template, animated: false) { success, error in
      if let error {
        print("ConduitCarPlaySceneDelegate: failed to set root template: \(error)")
      } else if !success {
        print("ConduitCarPlaySceneDelegate: root template was not accepted")
      } else {
        Task { @MainActor in
          guard self.interfaceController === interfaceController else { return }
          self.startLaunchVoiceConversationIfNeeded()
        }
      }
    }
  }

  func templateApplicationScene(
    _ templateApplicationScene: CPTemplateApplicationScene,
    didDisconnectInterfaceController interfaceController: CPInterfaceController
  ) {
    interfaceController.delegate = nil
    guard self.interfaceController === interfaceController else { return }

    ConduitCarPlayBridge.shared.onSnapshotChanged = nil
    if didNotifyBridgeConnected {
      ConduitCarPlayBridge.shared.carPlaySceneDidDisconnect()
      didNotifyBridgeConnected = false
    }
    self.interfaceController = nil
    voiceTemplate = nil
    hasRequestedLaunchStart = false
  }

  private func setUnsupportedRootTemplate(on interfaceController: CPInterfaceController) {
    let template = CPVoiceControlTemplate(voiceControlStates: [
      CPVoiceControlState(
        identifier: VoiceState.unavailable,
        titleVariants: ["Update iOS to use Conduit CarPlay", "CarPlay requires iOS 26.4"],
        image: UIImage(systemName: "iphone"),
        repeats: false
      ),
    ])
    voiceTemplate = template
    interfaceController.setRootTemplate(template, animated: false) { success, error in
      if let error {
        print("ConduitCarPlaySceneDelegate: failed to set unsupported root template: \(error)")
      } else if !success {
        print("ConduitCarPlaySceneDelegate: unsupported root template was not accepted")
      }
    }
  }

  @available(iOS 26.4, *)
  private func makeVoiceTemplate() -> CPVoiceControlTemplate {
    let template = CPVoiceControlTemplate(voiceControlStates: [
      makeState(
        identifier: VoiceState.working,
        titleVariants: ["Conduit is starting", "Starting"],
        systemImageName: "ellipsis",
        repeats: true,
        actionButtons: [makeEndButton()]
      ),
      makeState(
        identifier: VoiceState.listening,
        titleVariants: ["Conduit is listening", "Listening"],
        systemImageName: "mic.fill",
        repeats: true,
        actionButtons: [makePauseButton(), makeEndButton()]
      ),
      makeState(
        identifier: VoiceState.paused,
        titleVariants: ["Conversation paused", "Paused"],
        systemImageName: "pause.circle.fill",
        repeats: true,
        actionButtons: [makeResumeButton(), makeEndButton()]
      ),
      makeState(
        identifier: VoiceState.unavailable,
        titleVariants: ["Open Conduit on iPhone", "Conduit unavailable"],
        systemImageName: "iphone",
        repeats: false,
        actionButtons: [makeStartButton()]
      ),
      makeState(
        identifier: VoiceState.ready,
        titleVariants: ["Ask Conduit", "Conduit"],
        systemImageName: "waveform",
        repeats: true,
        actionButtons: [makeStartButton()]
      ),
    ])

    template.backButton = CPBarButton(title: "Close") { [weak self] _ in
      Task { @MainActor in
        self?.interfaceController?.popToRootTemplate(animated: true, completion: nil)
      }
    }

    return template
  }

  @available(iOS 26.4, *)
  private func makeState(
    identifier: String,
    titleVariants: [String],
    systemImageName: String,
    repeats: Bool,
    actionButtons: [CPButton]
  ) -> CPVoiceControlState {
    let state = CPVoiceControlState(
      identifier: identifier,
      titleVariants: titleVariants,
      image: UIImage(systemName: systemImageName),
      repeats: repeats
    )
    state.actionButtons = Array(actionButtons.prefix(CPVoiceControlState.maximumActionButtonCount))
    return state
  }

  private func startLaunchVoiceConversationIfNeeded() {
    guard !hasRequestedLaunchStart else { return }

    let snapshot = ConduitCarPlayBridge.shared.latestSnapshot
    if snapshot.isActive {
      apply(snapshot)
      return
    }

    hasRequestedLaunchStart = true
    startVoiceConversation()
  }

  private func makeStartButton() -> CPButton {
    let button = CPButton(image: UIImage(systemName: "phone.arrow.up.right") ?? UIImage()) {
      [weak self] _ in
      Task { @MainActor in
        self?.startVoiceConversation()
      }
    }
    button.title = "Start"
    return button
  }

  private func makePauseButton() -> CPButton {
    let button = CPButton(image: UIImage(systemName: "pause.fill") ?? UIImage()) {
      [weak self] _ in
      Task { @MainActor in
        self?.pauseVoiceConversation()
      }
    }
    button.title = "Pause"
    return button
  }

  private func makeResumeButton() -> CPButton {
    let button = CPButton(image: UIImage(systemName: "play.fill") ?? UIImage()) {
      [weak self] _ in
      Task { @MainActor in
        self?.resumeVoiceConversation()
      }
    }
    button.title = "Resume"
    return button
  }

  private func makeEndButton() -> CPButton {
    let button = CPButton(image: UIImage(systemName: "phone.down.fill") ?? UIImage()) {
      [weak self] _ in
      Task { @MainActor in
        self?.endVoiceConversation()
      }
    }
    button.title = "End"
    return button
  }

  private func startVoiceConversation() {
    activate(VoiceState.working)
    ConduitCarPlayBridge.shared.startVoiceConversation { [weak self] result in
      Task { @MainActor in
        guard let self else { return }
        if !result.success {
          print("ConduitCarPlaySceneDelegate: unable to start voice conversation: \(result.error ?? "unknown error")")
          self.activate(VoiceState.unavailable)
        } else if let snapshot = result.snapshot {
          self.apply(snapshot)
        } else {
          self.activate(VoiceState.working)
        }
      }
    }
  }

  private func endVoiceConversation() {
    activate(VoiceState.working)
    ConduitCarPlayBridge.shared.endVoiceConversation { [weak self] result in
      Task { @MainActor in
        guard let self else { return }
        if !result.success {
          print("ConduitCarPlaySceneDelegate: unable to end voice conversation: \(result.error ?? "unknown error")")
          self.activate(VoiceState.unavailable)
        } else if let snapshot = result.snapshot {
          self.apply(snapshot)
        } else {
          self.activate(VoiceState.ready)
        }
      }
    }
  }

  private func pauseVoiceConversation() {
    ConduitCarPlayBridge.shared.pauseVoiceConversation { [weak self] result in
      Task { @MainActor in
        guard let self else { return }
        if !result.success {
          print("ConduitCarPlaySceneDelegate: unable to pause voice conversation: \(result.error ?? "unknown error")")
          if let snapshot = result.snapshot {
            self.apply(snapshot)
          } else {
            self.activate(VoiceState.unavailable)
          }
        } else if let snapshot = result.snapshot {
          self.apply(snapshot)
        } else {
          self.activate(VoiceState.paused)
        }
      }
    }
  }

  private func resumeVoiceConversation() {
    activate(VoiceState.working)
    ConduitCarPlayBridge.shared.resumeVoiceConversation { [weak self] result in
      Task { @MainActor in
        guard let self else { return }
        if !result.success {
          print("ConduitCarPlaySceneDelegate: unable to resume voice conversation: \(result.error ?? "unknown error")")
          if let snapshot = result.snapshot {
            self.apply(snapshot)
          } else {
            self.activate(VoiceState.unavailable)
          }
        } else if let snapshot = result.snapshot {
          self.apply(snapshot)
        } else {
          self.activate(VoiceState.listening)
        }
      }
    }
  }

  private func apply(_ snapshot: ConduitCarPlayVoiceSnapshot) {
    switch snapshot.phase {
    case "listening":
      activate(VoiceState.listening)
    case "paused", "muted":
      activate(VoiceState.paused)
    case "starting", "connecting", "thinking", "speaking", "ending":
      activate(VoiceState.working)
    case "failed":
      activate(VoiceState.unavailable)
    default:
      activate(snapshot.isActive ? VoiceState.working : VoiceState.ready)
    }
  }

  private func activate(_ identifier: String) {
    voiceTemplate?.activateVoiceControlState(withIdentifier: identifier)
  }
}
