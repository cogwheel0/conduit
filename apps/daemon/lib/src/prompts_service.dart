import 'package:conduit_core/auth/auth_state_manager.dart';
import 'package:conduit_core/models/prompt.dart';
import 'package:conduit_core/ports/clipboard_port.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/utils/prompt_variable_parser.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:riverpod/riverpod.dart';
import 'package:conduit_core/features/hermes/models/hermes_model.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/librechat/models/librechat_prompts.dart';
import 'package:conduit_core/features/librechat/providers/librechat_composer_providers.dart'
    show libreChatPromptsProvider;
import 'package:conduit_core/features/librechat/providers/librechat_providers.dart'
    show libreChatSessionProvider, LibreChatSignedInState;
import 'package:conduit_core/providers/backend_mode_providers.dart';
import 'package:conduit_core/services/location_service.dart';

import 'settled.dart';
import 'language_tag.dart';

/// Implements `prompts.*`: the composer's `/` menu.
///
/// Filling a prompt in is the core's `PromptProcessor`, the one mobile
/// uses, so `{{CURRENT_DATE}}` and `{{team | select:...}}` mean the same in
/// both apps. It runs here rather than in the renderer because it needs the
/// signed-in user, which only the daemon holds; the clipboard is the one
/// input that has to come the other way.
final class PromptsService {
  PromptsService(
    this._container, {
    Future<List<Prompt>> Function()? fetch,
    Future<Map<String, dynamic>?> Function()? userSettings,
  }) : _fetchOverride = fetch,
       _userSettingsOverride = userSettings;

  final ProviderContainer _container;

  /// Stands in for the server in tests. The account a live test signs in
  /// with may have no prompts, and creating one would leave it behind.
  final Future<List<Prompt>> Function()? _fetchOverride;

  /// Stands in for the account's Open WebUI settings in tests, as [fetch]
  /// does for its prompts.
  final Future<Map<String, dynamic>?> Function()? _userSettingsOverride;

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

    if (isLibreChatPrompt(prompt)) return _renderLibreChat(prompt, request);

    final user = _container.read(authStateManagerProvider).value?.user;
    final processor = PromptProcessor(
      parser: _parser,
      systemResolver: SystemVariableResolver(
        userName: user?.name ?? user?.username,
        userLanguage: userLanguageTag(_container),
        userLocation: await _userLocation(prompt.content),
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

  /// `{{USER_LOCATION}}` for a prompt that names it, as the phone fills it
  /// in (its position, or `LOCATION_UNKNOWN`); the Mac asks its location
  /// services only while the account's location setting is on, else the
  /// place the user typed (the core's [LocationLookupPolicy]). Null for a
  /// prompt that does not name it: nothing is asked.
  Future<String?> _userLocation(String content) async {
    final named = _parser
        .parse(content)
        .any(
          (variable) =>
              variable.isSystemVariable &&
              variable.name.toUpperCase() == 'USER_LOCATION',
        );
    if (!named) return null;
    Map<String, dynamic>? settings;
    try {
      settings =
          await (_userSettingsOverride ??
              () async =>
                  _container.read(apiServiceProvider)?.getUserSettings())();
    } on Object {
      settings = null;
    }
    return _container
        .read(locationServiceProvider)
        .resolveLocationForPromptTemplate(settings);
  }

  /// A LibreChat prompt, read with LibreChat's grammar (`{{name}}`, and
  /// `{{name:a|b}}`, whose choices are suggestions), as mobile fills it:
  /// every blank is a text field, prefilled with its first choice, and one
  /// left empty stays in the text. Open WebUI's parser never reads it.
  RenderedPrompt _renderLibreChat(Prompt prompt, RenderPrompt request) {
    final variables = libreChatPromptVariables(prompt.content);
    final userName = _libreChatUserName();
    // Each blank once, under a name the form can key it by.
    final names = <String>[];
    for (final variable in variables) {
      var name = variable.name.isEmpty ? 'value' : variable.name;
      for (var suffix = 2; names.contains(name); suffix++) {
        name = '${variable.name} $suffix';
      }
      names.add(name);
    }
    if (variables.isEmpty || request.values.isNotEmpty) {
      return RenderedPrompt(
        content: fillLibreChatPrompt(
          prompt.content,
          values: <String, String>{
            for (final (index, variable) in variables.indexed)
              if ((request.values[names[index]] ?? '').isNotEmpty)
                variable.token: request.values[names[index]]!,
          },
          userName: userName,
        ),
      );
    }
    return RenderedPrompt(
      content: prompt.content,
      inputs: <PromptInput>[
        for (final (index, variable) in variables.indexed)
          PromptInput(
            name: names[index],
            label: names[index],
            type: 'text',
            placeholder: variable.options.isEmpty
                ? null
                : variable.options.join(' | '),
            defaultValue: variable.options.firstOrNull,
            options: variable.options,
          ),
      ],
    );
  }

  String? _libreChatUserName() {
    final state = _container.read(libreChatSessionProvider).value;
    if (state is! LibreChatSignedInState) return null;
    final user = state.handle.current?.user;
    return user?.name ?? user?.username;
  }

  Future<List<Prompt>> _fetch() async {
    // With Hermes Agent's model chosen, the `/` menu is its skills, as on
    // mobile: `/review` sent to the agent runs that skill. With a LibreChat
    // account in charge, its prompt library.
    final selected = _container.read(selectedModelProvider);
    final prompts = selected != null && isHermesModel(selected)
        ? await _hermesSkills()
        : _container.read(primaryAccountKindProvider) ==
              PrimaryAccountKind.libreChat
        ? await _libreChatPrompts()
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

  Future<List<Prompt>> _libreChatPrompts() async {
    _container.invalidate(libreChatPromptsProvider);
    try {
      return await readSettled(_container, libreChatPromptsProvider.future);
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
