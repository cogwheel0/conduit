import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/qonduit_runtime_state.dart';

class QonduitRuntimeNotifier extends Notifier<QonduitRuntimeState> {
  @override
  QonduitRuntimeState build() {
    return const QonduitRuntimeState(
      selectedModel: null,
      contextSize: 32768,
    );
  }

  void setRuntime({
    required String model,
    required int contextSize,
  }) {
    state = QonduitRuntimeState(
      selectedModel: model,
      contextSize: contextSize,
    );
  }
}

final qonduitRuntimeStateProvider =
NotifierProvider<QonduitRuntimeNotifier, QonduitRuntimeState>(
  QonduitRuntimeNotifier.new,
);