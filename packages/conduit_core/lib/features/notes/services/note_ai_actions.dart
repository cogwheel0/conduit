import 'package:riverpod/riverpod.dart';

import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/utils/debug_logger.dart';

/// How an AI action on a note ended.
enum NoteAiOutcome {
  /// The model answered; [NoteAiResult.text] holds it.
  done,

  /// The note has no content to work from.
  noContent,

  /// No model is selected.
  noModel,

  /// There is no server connection; nothing is shown.
  unavailable,

  /// The model answered with nothing; nothing changes.
  empty,

  /// The request failed.
  failed,
}

class NoteAiResult {
  const NoteAiResult(this.outcome, [this.text]);

  final NoteAiOutcome outcome;
  final String? text;
}

/// A generated title for the note's [markdown], from the selected model.
Future<NoteAiResult> generateNoteTitle(
  ProviderContainer container,
  String markdown,
) => _run(
  container,
  markdown,
  (ApiService api, String content, String modelId) =>
      api.generateNoteTitle(content, modelId: modelId),
);

/// The note's [markdown] enhanced by the selected model (the reply is
/// markdown).
Future<NoteAiResult> enhanceNote(
  ProviderContainer container,
  String markdown,
) => _run(
  container,
  markdown,
  (ApiService api, String content, String modelId) =>
      api.enhanceNoteContent(content, modelId: modelId),
);

Future<NoteAiResult> _run(
  ProviderContainer container,
  String markdown,
  Future<String?> Function(ApiService api, String content, String modelId)
  request,
) async {
  final String content = markdown.trim();
  if (content.isEmpty) return const NoteAiResult(NoteAiOutcome.noContent);

  final Model? model = container.read(selectedModelProvider);
  if (model == null) return const NoteAiResult(NoteAiOutcome.noModel);

  final ApiService? api = container.read(apiServiceProvider);
  if (api == null) return const NoteAiResult(NoteAiOutcome.unavailable);

  try {
    final String? text = await request(api, content, model.id);
    if (text == null || text.isEmpty) {
      return const NoteAiResult(NoteAiOutcome.empty);
    }
    return NoteAiResult(NoteAiOutcome.done, text);
  } catch (error) {
    DebugLogger.warning(
      'note-ai-failed',
      scope: 'notes/ai',
      data: {'errorType': error.runtimeType.toString()},
    );
    return const NoteAiResult(NoteAiOutcome.failed);
  }
}
