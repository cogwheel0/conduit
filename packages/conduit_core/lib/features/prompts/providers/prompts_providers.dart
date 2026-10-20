import 'package:riverpod_annotation/riverpod_annotation.dart';

import 'package:conduit_core/models/prompt.dart';
import 'package:conduit_core/services/prompts_service.dart';

part 'prompts_providers.g.dart';

@Riverpod(keepAlive: true)
Future<List<Prompt>> promptsList(Ref ref) async {
  final promptsService = ref.watch(promptsServiceProvider);
  if (promptsService == null) return const <Prompt>[];
  return promptsService.getPrompts();
}

@Riverpod(keepAlive: true)
class ActivePromptCommand extends _$ActivePromptCommand {
  @override
  String? build() => null;

  void set(String? command) => state = command;
}
