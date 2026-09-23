import 'package:conduit_core/auth/auth_state_manager.dart';
import 'package:conduit_core/models/prompt.dart';
import 'package:conduit_core/ports/clipboard_port.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/utils/prompt_variable_parser.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:riverpod/riverpod.dart';
import 'package:conduit_core/features/hermes/models/hermes_model.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';

import 'settled.dart';
import 'language_tag.dart';

/// Implements `prompts.*`: the composer's `/` menu (WP-3.3).
///
/// Filling a prompt in is the core's `PromptProcessor`, the one mobile
/// uses, so `{{CURRENT_DATE}}` and `{{team | select:...}}` mean the same in
/// both apps. It runs here rather than in the renderer because it needs the
/// signed-in user, which only the daemon holds; the clipboard is the one
/// input that has to come the other way.
final class PromptsService {
  PromptsService(this._container, {Future<List<Prompt>> Function()? fetch})
    : _fetchOverride = fetch;

  final ProviderContainer _container;

  /// Stands in for the server in tests. The account a live test signs in
  /// with may have no prompts, and creating one would leave it behind.
  final Future<List<Prompt>> Function()? _fetchOverride;

  /// The last list fetched, by command, so rendering the prompt the user
  /// just picked does not fetch them all again.
  Map<String, Prompt> _byCommand = <String, Prompt>{};

  static const PromptVariableParser _parser = PromptVariableParser();

  Future<PromptList> list() async {
    final prompts = await _fetch();
    return PromptList(
      prompts: <PromptSummary>[
        for (final prompt in prompts)
          if (prompt.isActive)
            PromptSummary(
              command: prompt.command,
              title: prompt.title,
              description: prompt.description,
              usesClipboard: _parser
                  .parse(prompt.content)
                  .any(
                    (variable) => variable.name.toUpperCase() == 'CLIPBOARD',
                  ),
            ),
      ],
    );
  }

  Future<RenderedPrompt> render(RenderPrompt request) async {
    var prompt = _byCommand[request.command];
    if (prompt == null) {
      await _fetch();
      prompt = _byCommand[request.command];
    }
    if (prompt == null) {
      throw RpcError(
        code: ConduitErrorCodes.notFound,
        debugMessage: 'no prompt ${request.command}',
      );
    }

    final user = _container.read(authStateManagerProvider).value?.user;
    final processor = PromptProcessor(
      parser: _parser,
      systemResolver: SystemVariableResolver(
        userName: user?.name ?? user?.username,
        userLanguage: userLanguageTag(_container),
        clipboard: _GivenClipboard(request.clipboard),
      ),
    );
    final processed = await processor.process(prompt.content);
    final asked = processed.userInputVariables;

    // Nothing to ask, or the answers are here: the text is final.
    if (asked.isEmpty || request.values.isNotEmpty) {
      final values = <String, String>{
        for (final variable in asked)
          variable.name:
              request.values[variable.name] ?? variable.defaultValue ?? '',
      };
      return RenderedPrompt(
        content: processor.applyUserValues(processed.content, values),
      );
    }

    // Once per name: a prompt may use `{{team}}` in three places, and the
    // user should be asked for it once.
    final seen = <String>{};
    return RenderedPrompt(
      content: processed.content,
      inputs: <PromptInput>[
        for (final variable in asked)
          if (seen.add(variable.name))
            PromptInput(
              name: variable.name,
              label: variable.displayLabel,
              type: variable.type.name,
              placeholder: variable.placeholder,
              defaultValue: variable.defaultValue,
              required: variable.isRequired,
              options: variable.options,
            ),
      ],
    );
  }

  Future<List<Prompt>> _fetch() async {
    // With Hermes Agent's model chosen, the `/` menu is its skills, as on
    // mobile (M7): `/review` sent to the agent runs that skill.
    final selected = _container.read(selectedModelProvider);
    final prompts = selected != null && isHermesModel(selected)
        ? await _hermesSkills()
        : await (_fetchOverride ?? _fromServer)();
    _byCommand = <String, Prompt>{
      for (final prompt in prompts) prompt.command: prompt,
    };
    return prompts;
  }

  Future<List<Prompt>> _hermesSkills() async {
    _container.invalidate(hermesSkillPromptsProvider);
    try {
      return await readSettled(_container, hermesSkillPromptsProvider.future);
    } on Object {
      return const <Prompt>[];
    }
  }

  Future<List<Prompt>> _fromServer() async {
    final api = _container.read(apiServiceProvider);
    if (api == null) {
      throw const RpcError(
        code: ConduitErrorCodes.unauthenticated,
        debugMessage: 'sign in before listing prompts',
      );
    }
    return api.getPrompts();
  }
}

/// `{{CLIPBOARD}}` from what the window read, since the daemon has no
/// clipboard of its own.
final class _GivenClipboard implements ClipboardPort {
  const _GivenClipboard(this._text);

  final String? _text;

  @override
  Future<String?> readText() async => _text;

  @override
  Future<void> writeText(String text) async {}
}
