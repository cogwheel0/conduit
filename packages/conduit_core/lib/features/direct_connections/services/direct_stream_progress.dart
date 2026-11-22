import '../models/direct_completion.dart';

/// LM Studio event names and namespaced phase/fraction progress extensions.
DirectProgressUpdate? directStreamProgress(
  Map<String, dynamic> payload, {
  String? event,
}) {
  final name = event ?? payload['type'];
  Map? progress;
  if (name is String && name.endsWith('_progress')) {
    progress = payload;
  } else {
    for (final entry in payload.entries) {
      if (entry.key.endsWith('_progress') && entry.value is Map) {
        progress = entry.value as Map;
        break;
      }
    }
  }
  final type = progress != null
      ? switch (progress['phase']) {
          'load_start' => 'model_load.start',
          'load_end' => 'model_load.end',
          'prompt_start' => 'prompt_processing.start',
          'prompt' => 'prompt_processing.progress',
          'prompt_end' => 'prompt_processing.end',
          _ => null,
        }
      : name;
  final phase = switch (type) {
    'model_load.start' ||
    'model_load.progress' ||
    'model_load.end' => DirectProgressPhase.modelLoad,
    'prompt_processing.start' ||
    'prompt_processing.progress' ||
    'prompt_processing.end' => DirectProgressPhase.promptProcessing,
    _ => null,
  };
  if (phase == null) return null;
  final value = progress == null ? payload['progress'] : progress['fraction'];
  return DirectProgressUpdate(
    phase,
    fraction: value is num && value.isFinite
        ? value.toDouble().clamp(0, 1)
        : null,
    done: type == 'model_load.end' || type == 'prompt_processing.end',
  );
}
