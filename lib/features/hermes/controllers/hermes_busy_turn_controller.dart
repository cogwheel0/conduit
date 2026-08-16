import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers/app_providers.dart';
import '../../../core/utils/debug_logger.dart';
import '../models/hermes_model.dart';
import '../models/hermes_config.dart';
import '../providers/hermes_providers.dart';
import '../services/hermes_desktop_api_service.dart';
import '../services/hermes_session_provenance.dart';

enum HermesBusyTurnAction { steer, sendNext }

final hermesBusyTurnControllerProvider = Provider<HermesBusyTurnController>(
  HermesBusyTurnController.new,
);

final class HermesBusyTurnController {
  HermesBusyTurnController(this._ref);

  final Ref _ref;

  /// Interrupts an authoritative Desktop turn that has no local stream.
  Future<bool> stopRecoveredTurn() async {
    final conversation = _ref.read(activeConversationProvider);
    final storedId = conversation?.metadata['hermesSessionId']?.toString();
    final service = _ref.read(hermesApiServiceProvider);
    final configController = _ref.read(hermesConfigProvider.notifier);
    final admission = configController.captureSessionActionAdmission();
    if (service is! HermesDesktopApiService ||
        !isNativeHermesConversation(conversation) ||
        storedId == null ||
        admission == null ||
        service.turnStateFor(storedId) != HermesDesktopTurnState.running) {
      return false;
    }
    try {
      if (!configController.sessionActionAdmissionIsCurrent(admission) ||
          !identical(_ref.read(hermesApiServiceProvider), service) ||
          _ref.read(activeConversationProvider)?.id != conversation?.id) {
        return false;
      }
      await service.interrupt(storedId);
      return true;
    } catch (_) {
      DebugLogger.warning(
        'recovered-turn-stop-failed',
        scope: 'hermes/desktop/composer',
      );
      return false;
    }
  }

  /// Submits a busy-turn action and returns true only while its original chat,
  /// connection, and session still own the acknowledgement.
  Future<bool> submit({
    required HermesBusyTurnAction action,
    required String text,
    required bool localStreaming,
  }) async {
    final trimmed = text.trim();
    final sessionId = _ref.read(hermesActiveSessionProvider);
    final service = _ref.read(hermesApiServiceProvider);
    final configController = _ref.read(hermesConfigProvider.notifier);
    final admission = configController.captureSessionActionAdmission();
    final conversation = _ref.read(activeConversationProvider);
    final conversationSessionId = conversation?.metadata['hermesSessionId']
        ?.toString();
    final selectedModel = _ref.read(selectedModelProvider);
    if (trimmed.isEmpty ||
        admission == null ||
        sessionId == null ||
        service is! HermesDesktopApiService ||
        (!localStreaming &&
            (conversationSessionId == null ||
                service.turnStateFor(conversationSessionId) !=
                    HermesDesktopTurnState.running)) ||
        selectedModel == null ||
        !isHermesModel(selectedModel) ||
        !isNativeHermesConversation(conversation) ||
        conversationSessionId == null ||
        !service.sessionIdsReferToSameBinding(
          sessionId,
          conversationSessionId,
        )) {
      return false;
    }
    try {
      switch (action) {
        case HermesBusyTurnAction.steer:
          await service.steer(sessionId, trimmed);
        case HermesBusyTurnAction.sendNext:
          await service.queue(sessionId, trimmed);
      }
    } catch (_) {
      DebugLogger.warning(
        action == HermesBusyTurnAction.steer ? 'steer-failed' : 'queue-failed',
        scope: 'hermes/desktop/composer',
      );
      return false;
    }
    return configController.sessionActionAdmissionIsCurrent(admission) &&
        identical(_ref.read(hermesApiServiceProvider), service) &&
        _ref.read(hermesActiveSessionProvider) == sessionId &&
        _ref.read(activeConversationProvider)?.id == conversation?.id;
  }
}
