/// What the per-chat settings editor lets a user type, and how that becomes a
/// patch of the chat's saved params.
///
/// The form only ever produces a patch over the keys it understands, and only
/// for fields the user actually changed, so every other saved key (and any
/// value that was never touched, even an odd one) is left exactly as stored.
/// Pure Dart: the widget stays a thin view over it.
library;

import 'dart:convert';

import 'package:meta/meta.dart';

import 'openwebui_chat_settings.dart';

/// `format` is an Ollama request option (`"json"` or a JSON schema).
const String kChatParamResponseFormat = 'format';

/// Why a typed value was not accepted.
enum ChatParamInputError {
  required,
  notANumber,
  notAWholeNumber,
  outOfRange,
  notJson,
  notAChoice,
}

enum ChatParamKind { text, decimal, integer, stopList, responseFormat, choice }

/// How one field stands relative to the user's defaults.
enum ChatParamMode {
  /// No override: the chat follows the user's global setting.
  inherit,

  /// An explicit null: the model's own default, ignoring the global setting.
  modelDefault,

  /// A value of its own.
  custom,
}

/// One editable parameter.
@immutable
final class ChatParamSpec {
  const ChatParamSpec(this.key, this.kind, {this.min, this.max});

  final String key;
  final ChatParamKind kind;
  final num? min;
  final num? max;
}

/// The parameters the editor offers, with the ranges the web client's own
/// controls enforce. Server resource knobs (threads, GPU layers, ...) are
/// deliberately absent.
const List<ChatParamSpec> kEditableChatParamSpecs = <ChatParamSpec>[
  ChatParamSpec(kChatParamTemperature, ChatParamKind.decimal, min: 0, max: 2),
  ChatParamSpec(kChatParamTopP, ChatParamKind.decimal, min: 0, max: 1),
  ChatParamSpec(kChatParamTopK, ChatParamKind.integer, min: 0, max: 1000),
  ChatParamSpec(kChatParamMinP, ChatParamKind.decimal, min: 0, max: 1),
  ChatParamSpec(
    kChatParamFrequencyPenalty,
    ChatParamKind.decimal,
    min: -2,
    max: 2,
  ),
  ChatParamSpec(
    kChatParamPresencePenalty,
    ChatParamKind.decimal,
    min: -2,
    max: 2,
  ),
  ChatParamSpec(kChatParamMaxTokens, ChatParamKind.integer, min: 1),
  ChatParamSpec(kChatParamSeed, ChatParamKind.integer),
  ChatParamSpec(kChatParamStop, ChatParamKind.stopList),
  ChatParamSpec(kChatParamReasoningEffort, ChatParamKind.choice),
  ChatParamSpec(kChatParamFunctionCalling, ChatParamKind.choice),
  ChatParamSpec(kChatParamResponseFormat, ChatParamKind.responseFormat),
];

/// The choices offered for `function_calling` (null is the server default).
const List<String> kChatFunctionCallingChoices = <String>['native', 'legacy'];

/// The result of reading one text box: a [value] to save, or an [error].
@immutable
final class ChatParamParse {
  const ChatParamParse.value(this.value) : error = null;
  const ChatParamParse.error(this.error) : value = null;

  final Object? value;
  final ChatParamInputError? error;
}

ChatParamParse parseChatParamText(ChatParamSpec spec, String text) {
  final trimmed = text.trim();
  switch (spec.kind) {
    case ChatParamKind.decimal:
    case ChatParamKind.integer:
      final num? number = spec.kind == ChatParamKind.integer
          ? int.tryParse(trimmed)
          : (int.tryParse(trimmed) ?? double.tryParse(trimmed));
      if (number == null) {
        return ChatParamParse.error(
          spec.kind == ChatParamKind.integer &&
                  double.tryParse(trimmed)?.isFinite == true
              ? ChatParamInputError.notAWholeNumber
              : ChatParamInputError.notANumber,
        );
      }
      if (!number.isFinite) {
        return const ChatParamParse.error(ChatParamInputError.notANumber);
      }
      final min = spec.min;
      final max = spec.max;
      if ((min != null && number < min) || (max != null && number > max)) {
        return const ChatParamParse.error(ChatParamInputError.outOfRange);
      }
      return ChatParamParse.value(number);
    case ChatParamKind.stopList:
      // Stored as the comma-separated string the web client's own field
      // writes; the request splits it once.
      final tokens = trimmed
          .split(',')
          .map((token) => token.trim())
          .where((token) => token.isNotEmpty)
          .toList(growable: false);
      return ChatParamParse.value(tokens.join(','));
    case ChatParamKind.responseFormat:
      if (!trimmed.startsWith('{')) return ChatParamParse.value(trimmed);
      try {
        final decoded = jsonDecode(trimmed);
        if (decoded is Map) return ChatParamParse.value(decoded);
      } on FormatException {
        // Reported below.
      }
      return const ChatParamParse.error(ChatParamInputError.notJson);
    case ChatParamKind.text:
    case ChatParamKind.choice:
      return ChatParamParse.value(trimmed);
  }
}

/// How a saved value reads back into its text box.
String chatParamToText(ChatParamSpec? spec, Object? value) {
  if (value == null) return '';
  if (value is List) return value.join(', ');
  if (value is Map) return jsonEncode(value);
  if (value is num &&
      value == value.truncate() &&
      spec?.kind != ChatParamKind.decimal) {
    return value.truncate().toString();
  }
  return value.toString();
}

/// The patch the editor submits: only what actually changed.
@immutable
final class ChatParamsPatch {
  const ChatParamsPatch({required this.set, required this.remove});

  final Map<String, dynamic> set;
  final List<String> remove;

  bool get isEmpty => set.isEmpty && remove.isEmpty;
}

/// Editable state for the per-chat settings sheet.
final class ChatSettingsForm {
  /// [reasoningChoices] are the efforts the selected model accepts; null hides
  /// the field. [offersResponseFormat] is true only for a model that can use
  /// `format` (an Ollama model).
  ChatSettingsForm({
    required Map<String, dynamic> saved,
    this.reasoningChoices,
    this.reasoningAllowsCustom = false,
    this.offersResponseFormat = false,
  }) : _saved = openWebUiChatParamsFrom(saved) {
    _modes[kChatParamSystem] =
        _saved.containsKey(kChatParamSystem) &&
            _saved[kChatParamSystem] is String
        ? ChatParamMode.custom
        : ChatParamMode.inherit;
    _texts[kChatParamSystem] = _saved[kChatParamSystem] is String
        ? _saved[kChatParamSystem] as String
        : '';
    for (final spec in kEditableChatParamSpecs) {
      final key = spec.key;
      if (!_saved.containsKey(key)) {
        _modes[key] = ChatParamMode.inherit;
        _texts[key] = '';
      } else if (_saved[key] == null) {
        _modes[key] = ChatParamMode.modelDefault;
        _texts[key] = '';
      } else {
        _modes[key] = ChatParamMode.custom;
        _texts[key] = chatParamToText(spec, _saved[key]);
      }
    }
    _initialModes = Map<String, ChatParamMode>.of(_modes);
    _initialTexts = Map<String, String>.of(_texts);
  }

  final Map<String, dynamic> _saved;
  final List<String>? reasoningChoices;
  final bool reasoningAllowsCustom;
  final bool offersResponseFormat;

  final Map<String, ChatParamMode> _modes = <String, ChatParamMode>{};
  final Map<String, String> _texts = <String, String>{};
  late final Map<String, ChatParamMode> _initialModes;
  late final Map<String, String> _initialTexts;

  /// Keys the sheet shows, in order.
  List<String> get parameterKeys => <String>[
    for (final spec in kEditableChatParamSpecs)
      if (_offers(spec.key)) spec.key,
  ];

  bool _offers(String key) {
    if (key == kChatParamReasoningEffort) return reasoningChoices != null;
    if (key == kChatParamResponseFormat) return offersResponseFormat;
    return true;
  }

  ChatParamMode modeOf(String key) => _modes[key] ?? ChatParamMode.inherit;
  String textOf(String key) => _texts[key] ?? '';

  void setMode(String key, ChatParamMode mode) {
    if (key == kChatParamSystem && mode == ChatParamMode.modelDefault) return;
    _modes[key] = mode;
  }

  void setText(String key, String text) {
    _texts[key] = text;
    _modes[key] = ChatParamMode.custom;
  }

  /// Puts the fields the form understands back to inheriting: the system
  /// prompt when [system], the parameters when [parameters]. Keys the form does
  /// not understand are never part of it, so they are never removed.
  void inheritAll({bool system = true, bool parameters = true}) {
    if (system) _modes[kChatParamSystem] = ChatParamMode.inherit;
    if (parameters) {
      for (final key in parameterKeys) {
        _modes[key] = ChatParamMode.inherit;
      }
    }
  }

  bool _changed(String key) =>
      _modes[key] != _initialModes[key] ||
      (_modes[key] == ChatParamMode.custom &&
          _texts[key] != _initialTexts[key]);

  /// Whether the user changed anything.
  bool get isDirty =>
      <String>[kChatParamSystem, ...parameterKeys].any(_changed);

  /// Whether any field the user changed would be saved as an override.
  bool overridesAnything() => <String>[
    kChatParamSystem,
    ...parameterKeys,
  ].any((key) => modeOf(key) != ChatParamMode.inherit);

  /// The reason a changed field cannot be saved, or null. An untouched field is
  /// never an error, even when what is stored there is unusual.
  ChatParamInputError? errorOf(String key) {
    if (!_changed(key) || modeOf(key) != ChatParamMode.custom) return null;
    if (key == kChatParamSystem) return null;
    final spec = chatParamSpecFor(key)!;
    final text = textOf(key);
    if (spec.kind == ChatParamKind.choice) {
      return _choiceValue(key, text) == null
          ? ChatParamInputError.notAChoice
          : null;
    }
    if (text.trim().isEmpty) return ChatParamInputError.required;
    return parseChatParamText(spec, text).error;
  }

  bool get hasErrors => parameterKeys.any((key) => errorOf(key) != null);

  /// The text a choice field would save, or null when it is not acceptable.
  String? _choiceValue(String key, String text) {
    final value = text.trim();
    if (value.isEmpty) return null;
    if (key == kChatParamFunctionCalling) {
      return kChatFunctionCallingChoices.contains(value) ? value : null;
    }
    final choices = reasoningChoices ?? const <String>[];
    if (choices.contains(value)) return value;
    return reasoningAllowsCustom ? value : null;
  }

  /// The minimal patch for what changed. Call only when [hasErrors] is false.
  ChatParamsPatch toPatch() {
    final set = <String, dynamic>{};
    final remove = <String>[];
    for (final key in <String>[kChatParamSystem, ...parameterKeys]) {
      if (!_changed(key)) continue;
      switch (modeOf(key)) {
        case ChatParamMode.inherit:
          if (_saved.containsKey(key)) remove.add(key);
        case ChatParamMode.modelDefault:
          set[key] = null;
        case ChatParamMode.custom:
          if (key == kChatParamSystem) {
            // Even an empty prompt is saved: it is an explicit "send no
            // system prompt", not a request to inherit.
            set[key] = textOf(key);
            continue;
          }
          final spec = chatParamSpecFor(key)!;
          set[key] = spec.kind == ChatParamKind.choice
              ? _choiceValue(key, textOf(key))
              : parseChatParamText(spec, textOf(key)).value;
      }
    }
    return ChatParamsPatch(set: set, remove: remove);
  }
}

ChatParamSpec? chatParamSpecFor(String key) {
  for (final spec in kEditableChatParamSpecs) {
    if (spec.key == key) return spec;
  }
  return null;
}
