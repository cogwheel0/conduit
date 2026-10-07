import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/features/chat/providers/reasoning_effort_provider.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/models/openwebui_chat_settings.dart';
import 'package:conduit_core/models/openwebui_chat_settings_form.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../core/services/haptic_service.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/utils/ui_utils.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../../../shared/widgets/discard_changes.dart';
import '../../../shared/widgets/modal_safe_area.dart';
import '../../../shared/widgets/platform_ui/platform_ui.dart';
import '../../../shared/widgets/sheet_handle.dart';
import '../../../shared/widgets/themed_sheets.dart';

/// Opens what the chat overflow's "Chat settings" entry stands for: the editor
/// when it is available, otherwise the read-only summary of what applies.
///
/// Both are forms over the chat, so they sit above a dimmed barrier.
Future<void> showOpenWebUiChatSettings(BuildContext context, WidgetRef ref) {
  final entry = ref.read(openWebUiChatSettingsMenuEntryProvider);
  switch (entry) {
    case OpenWebUiChatSettingsMenuEntry.none:
      return Future<void>.value();
    case OpenWebUiChatSettingsMenuEntry.editor:
      return ThemedSheets.showCustom<void>(
        context: context,
        builder: (_) => const OpenWebUiChatSettingsSheet(),
      );
    case OpenWebUiChatSettingsMenuEntry.applied:
      return ThemedSheets.showCustom<void>(
        context: context,
        builder: (_) => const _AppliedThenEditor(),
      );
  }
}

/// The read-only summary, which becomes the editor in place once the user
/// turns Advanced on from it.
class _AppliedThenEditor extends ConsumerStatefulWidget {
  const _AppliedThenEditor();

  @override
  ConsumerState<_AppliedThenEditor> createState() => _AppliedThenEditorState();
}

class _AppliedThenEditorState extends ConsumerState<_AppliedThenEditor> {
  bool _editing = false;

  void _advancedTurnedOn() {
    if (!mounted) return;
    if (ref.read(openWebUiChatSettingsMenuEntryProvider) ==
        OpenWebUiChatSettingsMenuEntry.editor) {
      setState(() => _editing = true);
    } else {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) => _editing
      ? const OpenWebUiChatSettingsSheet()
      : OpenWebUiChatSettingsAppliedSheet(
          onAdvancedTurnedOn: _advancedTurnedOn,
        );
}

/// The editor: system prompt, parameters, reasoning and tool calling for the
/// open chat (or the next new chat when none is open).
class OpenWebUiChatSettingsSheet extends ConsumerStatefulWidget {
  const OpenWebUiChatSettingsSheet({super.key});

  @override
  ConsumerState<OpenWebUiChatSettingsSheet> createState() =>
      _OpenWebUiChatSettingsSheetState();
}

class _OpenWebUiChatSettingsSheetState
    extends ConsumerState<OpenWebUiChatSettingsSheet> {
  // Captured once: a save targets the chat the sheet was opened for, however
  // the user navigates meanwhile. Core re-checks the account before writing.
  late final Conversation? _conversation;
  late final ChatMutationOwnerToken _owner;
  late final ChatSettingsForm _form;
  late final Map<String, dynamic> _saved;
  final Map<String, TextEditingController> _controllers = {};
  final DraggableScrollableController _sheetController =
      DraggableScrollableController();
  bool _saving = false;
  bool _confirmingClose = false;
  String? _failure;

  static const double _initialSheetSize = 0.8;

  @override
  void initState() {
    super.initState();
    _conversation = ref.read(activeConversationProvider);
    _owner = captureChatMutationOwner(ref, _conversation);
    _saved = _conversation == null
        ? ref.read(pendingOpenWebUiChatSettingsProvider)
        : _conversation.chatParams;
    final model = ref.read(selectedModelProvider);
    final policy = reasoningEffortPolicyForModel(ref.read, model);
    _form = ChatSettingsForm(
      saved: _saved,
      reasoningChoices: policy.visible
          ? policy.options
                .where((option) => option != kAutomaticReasoningEffort)
                .toList(growable: false)
          : null,
      offersResponseFormat: _isOllama(model),
    );
    for (final key in <String>[kChatParamSystem, ..._form.parameterKeys]) {
      _controllers[key] = TextEditingController(text: _form.textOf(key));
    }
  }

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    _sheetController.dispose();
    super.dispose();
  }

  /// Closes the sheet, first asking whether to throw edits away. Close, the
  /// barrier, back and a swipe down all come here.
  Future<void> _close() async {
    if (_confirmingClose) return;
    final navigator = Navigator.of(context);
    if (!_form.isDirty) {
      navigator.pop();
      return;
    }
    _confirmingClose = true;
    final discard = await confirmDiscardChanges(context);
    _confirmingClose = false;
    if (!mounted) return;
    if (discard) {
      navigator.pop();
      return;
    }
    // A swipe that asked left the sheet at its smallest; put it back.
    if (_sheetController.isAttached &&
        _sheetController.size < _initialSheetSize) {
      final duration = context.motionDuration(
        const Duration(milliseconds: 220),
      );
      if (duration == Duration.zero) {
        _sheetController.jumpTo(_initialSheetSize);
      } else {
        _sheetController.animateTo(
          _initialSheetSize,
          duration: duration,
          curve: Curves.easeOutCubic,
        );
      }
    }
  }

  bool _onSheetExtent(DraggableScrollableNotification notification) {
    if (_form.isDirty &&
        notification.extent <= notification.minExtent + 0.001) {
      _close();
    }
    return false;
  }

  static bool _isOllama(Model? model) =>
      model?.metadata?['owned_by']?.toString() == 'ollama';

  void _edit(VoidCallback change) => setState(() {
    _failure = null;
    change();
  });

  void _setText(String key, String text) =>
      _edit(() => _form.setText(key, text));

  void _setMode(String key, ChatParamMode mode) {
    _edit(() {
      _form.setMode(key, mode);
      if (mode == ChatParamMode.inherit) {
        _controllers[key]?.text = '';
      }
    });
  }

  Future<void> _save(AppLocalizations l10n) async {
    final patch = _form.toPatch();
    if (patch.isEmpty) {
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _saving = true;
      _failure = null;
    });
    try {
      await saveOpenWebUiChatSettings(
        ref,
        conversation: _conversation,
        owner: _owner,
        set: patch.set,
        remove: patch.remove,
      );
      if (!mounted) return;
      Navigator.of(context).pop();
      ConduitHaptics.success();
      AdaptiveSnackBar.show(
        context,
        message: l10n.saved,
        type: AdaptiveSnackBarType.success,
      );
    } on OpenWebUiChatSettingsException catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _failure = switch (error.reason) {
          OpenWebUiChatSettingsFailure.permissionDenied =>
            l10n.chatSettingsParametersLocked,
          OpenWebUiChatSettingsFailure.ownerChanged =>
            l10n.chatSettingsOwnerChanged,
          _ => l10n.errorMessage,
        };
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _failure = l10n.errorMessage;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    final access =
        ref.watch(openWebUiChatSettingsAccessProvider).asData?.value ??
        OpenWebUiChatSettingsAccess.denied;
    final editsAnything = access.canEditAnything;
    final canSave =
        !_saving && _form.isDirty && !_form.hasErrors && editsAnything;
    final unknownKeys = _saved.keys
        .where(
          (key) =>
              key != kChatParamSystem &&
              !_form.parameterKeys.contains(key) &&
              chatParamSpecFor(key) == null,
        )
        .isNotEmpty;

    final dirty = _form.isDirty;

    // Close, the barrier, back and a swipe down all ask before throwing edits
    // away. The route's own swipe pops without consulting PopScope, so while
    // there are edits the sheet stops it from closing at its smallest size
    // and claims drags outside the form (see [SheetDismissGuard]).
    return PopScope<Object?>(
      canPop: !dirty,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _close();
      },
      child: SheetDismissGuard(
        guarded: dirty,
        onDismissRequest: _close,
        child: Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => Navigator.of(context).maybePop(),
                child: const SizedBox.shrink(),
              ),
            ),
            // ThemedSheets.showCustom adds no view inset, so the sheet lifts
            // itself above the software keyboard. The form scrolls in the
            // space that is left and Save stays reachable. The system strips
            // the home-indicator inset while the keyboard is up, so the safe
            // area below does not pad twice.
            AnimatedPadding(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOutCubic,
              padding: EdgeInsets.only(
                bottom: MediaQuery.viewInsetsOf(context).bottom,
              ),
              child: NotificationListener<DraggableScrollableNotification>(
                onNotification: _onSheetExtent,
                child: DraggableScrollableSheet(
                  controller: _sheetController,
                  expand: false,
                  initialChildSize: _initialSheetSize,
                  minChildSize: 0.4,
                  maxChildSize: 0.95,
                  shouldCloseOnMinExtent: !dirty,
                  builder: (context, scrollController) {
                    // The native iOS 26 sheet route supplies Flutter's own
                    // Material, which material_ui's text fields do not see.
                    // Sitting inside the surface keeps their ink above it.
                    return ConduitModalSheetSurface(
                      showHandle: false,
                      padding: const EdgeInsets.symmetric(
                        horizontal: Spacing.modalPadding,
                        vertical: Spacing.modalPadding,
                      ),
                      child: Material(
                        type: MaterialType.transparency,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            const SheetHandle(),
                            Row(
                              children: [
                                Expanded(
                                  child: Semantics(
                                    header: true,
                                    child: Text(
                                      l10n.chatSettingsTitle,
                                      style: theme.headingSmall?.copyWith(
                                        color: theme.textPrimary,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                ),
                                SheetCloseButton(
                                  key: const ValueKey('chat-settings-close'),
                                  tooltip: l10n.close,
                                  onPressed: _saving ? null : _close,
                                ),
                              ],
                            ),
                            const SizedBox(height: Spacing.xs),
                            Text(
                              l10n.chatSettingsDescription,
                              style: theme.bodySmall?.copyWith(
                                color: theme.textSecondary,
                              ),
                            ),
                            const SizedBox(height: Spacing.md),
                            Expanded(
                              child: ListView(
                                controller: scrollController,
                                padding: EdgeInsets.zero,
                                children: [
                                  _buildSystemPrompt(l10n, theme, access),
                                  const SizedBox(height: Spacing.lg),
                                  _buildParameters(l10n, theme, access),
                                  if (unknownKeys) ...[
                                    const SizedBox(height: Spacing.md),
                                    Text(
                                      l10n.chatSettingsOtherKept,
                                      style: theme.bodySmall?.copyWith(
                                        color: theme.textSecondary,
                                      ),
                                    ),
                                  ],
                                  if (editsAnything) ...[
                                    const SizedBox(height: Spacing.md),
                                    Align(
                                      alignment:
                                          AlignmentDirectional.centerStart,
                                      child: ConduitButton(
                                        key: const ValueKey(
                                          'chat-settings-reset-all',
                                        ),
                                        text: l10n.chatSettingsResetAll,
                                        isSecondary: true,
                                        isCompact: true,
                                        onPressed: _saving
                                            ? null
                                            : () => _edit(() {
                                                _form.inheritAll(
                                                  system: access
                                                      .canEditSystemPrompt,
                                                  parameters:
                                                      access.canEditParameters,
                                                );
                                                for (final entry
                                                    in _controllers.entries) {
                                                  entry.value.text = '';
                                                }
                                              }),
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                            if (_failure != null) ...[
                              const SizedBox(height: Spacing.sm),
                              Text(
                                _failure!,
                                key: const ValueKey('chat-settings-failure'),
                                style: theme.bodySmall?.copyWith(
                                  color: theme.error,
                                ),
                              ),
                            ],
                            const SizedBox(height: Spacing.md),
                            // Pinned below the scrolling form.
                            ConduitButton(
                              key: const ValueKey('chat-settings-save'),
                              text: l10n.save,
                              isFullWidth: true,
                              isLoading: _saving,
                              onPressed: canSave ? () => _save(l10n) : null,
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sectionTitle(String text, ConduitThemeExtension theme) => Padding(
    padding: const EdgeInsets.only(bottom: Spacing.sm),
    child: Text(
      text,
      style: theme.bodyMedium?.copyWith(
        color: theme.textPrimary,
        fontWeight: FontWeight.w600,
      ),
    ),
  );

  Widget _locked(String text, ConduitThemeExtension theme, Key key) => Text(
    text,
    key: key,
    style: theme.bodySmall?.copyWith(color: theme.textSecondary),
  );

  Widget _buildSystemPrompt(
    AppLocalizations l10n,
    ConduitThemeExtension theme,
    OpenWebUiChatSettingsAccess access,
  ) {
    final custom = _form.modeOf(kChatParamSystem) == ChatParamMode.custom;
    final editable = access.canEditSystemPrompt && !_saving;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle(l10n.chatSettingsSystemPrompt, theme),
        if (!access.canEditSystemPrompt)
          _locked(
            l10n.chatSettingsSystemPromptLocked,
            theme,
            const ValueKey('chat-settings-system-locked'),
          )
        else ...[
          Wrap(
            spacing: Spacing.sm,
            children: [
              _ChoicePill(
                key: const ValueKey('chat-settings-system-inherit'),
                label: l10n.chatSettingsInherit,
                selected: !custom,
                onSelected: editable
                    ? () => _setMode(kChatParamSystem, ChatParamMode.inherit)
                    : null,
              ),
              _ChoicePill(
                key: const ValueKey('chat-settings-system-custom'),
                label: l10n.chatSettingsCustom,
                selected: custom,
                onSelected: editable
                    ? () => _setMode(kChatParamSystem, ChatParamMode.custom)
                    : null,
              ),
            ],
          ),
          if (custom) ...[
            const SizedBox(height: Spacing.sm),
            ConduitInput(
              key: const ValueKey('chat-settings-system-field'),
              controller: _controllers[kChatParamSystem],
              enabled: editable,
              minLines: 3,
              maxLines: 8,
              keyboardType: TextInputType.multiline,
              textInputAction: TextInputAction.newline,
              hint: l10n.enterSystemPrompt,
              onChanged: (value) => _setText(kChatParamSystem, value),
            ),
            if (_controllers[kChatParamSystem]!.text.isEmpty) ...[
              const SizedBox(height: Spacing.xs),
              Text(
                l10n.chatSettingsSystemPromptEmptyNote,
                key: const ValueKey('chat-settings-system-empty-note'),
                style: theme.bodySmall?.copyWith(color: theme.textSecondary),
              ),
            ],
          ],
        ],
      ],
    );
  }

  Widget _buildParameters(
    AppLocalizations l10n,
    ConduitThemeExtension theme,
    OpenWebUiChatSettingsAccess access,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle(l10n.chatSettingsParameters, theme),
        if (!access.canEditParameters)
          _locked(
            l10n.chatSettingsParametersLocked,
            theme,
            const ValueKey('chat-settings-parameters-locked'),
          )
        else
          for (final key in _form.parameterKeys)
            Padding(
              padding: const EdgeInsets.only(bottom: Spacing.md),
              child: switch (chatParamSpecFor(key)!.kind) {
                ChatParamKind.choice => _buildChoice(l10n, theme, key),
                _ => _buildTextParameter(l10n, theme, key),
              },
            ),
      ],
    );
  }

  Widget _buildTextParameter(
    AppLocalizations l10n,
    ConduitThemeExtension theme,
    String key,
  ) {
    final spec = chatParamSpecFor(key)!;
    final mode = _form.modeOf(key);
    final error = _form.errorOf(key);
    final isModelDefault = mode == ChatParamMode.modelDefault;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: ConduitInput(
            key: ValueKey('chat-setting-$key'),
            label: _label(l10n, key),
            controller: _controllers[key],
            enabled: !_saving,
            hint: isModelDefault
                ? l10n.chatSettingsModelDefault
                : (key == kChatParamStop
                      ? l10n.chatSettingsStopHint
                      : l10n.chatSettingsInherit),
            keyboardType: _keyboardFor(spec),
            errorText: error == null ? null : _errorText(l10n, spec, error),
            onChanged: (value) => _setText(key, value),
          ),
        ),
        const SizedBox(width: Spacing.xs),
        Padding(
          padding: const EdgeInsets.only(top: Spacing.lg),
          child: ConduitIconButton(
            key: ValueKey('chat-setting-reset-$key'),
            tooltip: l10n.chatSettingsUseYourDefault,
            isCompact: true,
            icon: UiUtils.platformIcon(
              ios: CupertinoIcons.arrow_counterclockwise,
              android: Icons.restart_alt,
            ),
            onPressed: _saving || mode == ChatParamMode.inherit
                ? null
                : () => _setMode(key, ChatParamMode.inherit),
          ),
        ),
      ],
    );
  }

  Widget _buildChoice(
    AppLocalizations l10n,
    ConduitThemeExtension theme,
    String key,
  ) {
    final isReasoning = key == kChatParamReasoningEffort;
    final mode = _form.modeOf(key);
    final text = _form.textOf(key);
    final choices = isReasoning
        ? (_form.reasoningChoices ?? const <String>[])
        : kChatFunctionCallingChoices;
    // A saved value the choices do not offer stays selectable as it is, so
    // opening the sheet never silently rewrites it.
    final extra = mode == ChatParamMode.custom && !choices.contains(text)
        ? text
        : null;

    Widget chip({
      required String id,
      required String label,
      required bool selected,
      required VoidCallback onSelected,
    }) => _ChoicePill(
      key: ValueKey('chat-setting-$key-$id'),
      label: label,
      selected: selected,
      onSelected: _saving ? null : onSelected,
    );

    final error = _form.errorOf(key);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          _label(l10n, key),
          style: theme.bodySmall?.copyWith(color: theme.textSecondary),
        ),
        const SizedBox(height: Spacing.xs),
        Wrap(
          spacing: Spacing.sm,
          runSpacing: Spacing.xs,
          children: [
            chip(
              id: 'inherit',
              label: l10n.chatSettingsInherit,
              selected: mode == ChatParamMode.inherit,
              onSelected: () => _setMode(key, ChatParamMode.inherit),
            ),
            chip(
              id: 'default',
              label: isReasoning
                  ? l10n.ollamaThinkingAutomatic
                  : l10n.chatSettingsModelDefault,
              selected: mode == ChatParamMode.modelDefault,
              onSelected: () => _setMode(key, ChatParamMode.modelDefault),
            ),
            for (final choice in choices)
              chip(
                id: choice,
                label: isReasoning
                    ? _effortLabel(l10n, choice)
                    : _functionCallingLabel(l10n, choice),
                selected: mode == ChatParamMode.custom && text == choice,
                onSelected: () => _setText(key, choice),
              ),
            if (extra != null)
              chip(
                id: 'saved',
                label: extra,
                selected: true,
                onSelected: () {},
              ),
          ],
        ),
        if (error != null)
          Padding(
            padding: const EdgeInsets.only(top: Spacing.xs),
            child: Text(
              _errorText(l10n, chatParamSpecFor(key)!, error),
              style: theme.bodySmall?.copyWith(color: theme.error),
            ),
          ),
      ],
    );
  }

  static TextInputType _keyboardFor(ChatParamSpec spec) => switch (spec.kind) {
    ChatParamKind.decimal => const TextInputType.numberWithOptions(
      decimal: true,
      signed: true,
    ),
    ChatParamKind.integer => const TextInputType.numberWithOptions(
      signed: true,
    ),
    _ => TextInputType.text,
  };

  static String _label(AppLocalizations l10n, String key) => switch (key) {
    kChatParamTemperature => l10n.chatSettingTemperature,
    kChatParamTopP => l10n.chatSettingTopP,
    kChatParamTopK => l10n.chatSettingTopK,
    kChatParamMinP => l10n.chatSettingMinP,
    kChatParamFrequencyPenalty => l10n.chatSettingFrequencyPenalty,
    kChatParamPresencePenalty => l10n.chatSettingPresencePenalty,
    kChatParamMaxTokens => l10n.chatSettingMaxTokens,
    kChatParamSeed => l10n.chatSettingSeed,
    kChatParamStop => l10n.chatSettingStop,
    kChatParamReasoningEffort => l10n.reasoningEffort,
    kChatParamFunctionCalling => l10n.chatSettingFunctionCalling,
    kChatParamResponseFormat => l10n.chatSettingResponseFormat,
    _ => key,
  };

  static String _effortLabel(AppLocalizations l10n, String effort) =>
      switch (effort) {
        'low' => l10n.reasoningEffortLow,
        'medium' => l10n.reasoningEffortMedium,
        'high' => l10n.reasoningEffortHigh,
        'light' => l10n.reasoningEffortLight,
        'moderate' => l10n.reasoningEffortModerate,
        'deep' => l10n.reasoningEffortDeep,
        'minimal' => l10n.reasoningEffortMinimal,
        'xhigh' => l10n.reasoningEffortExtraHigh,
        'max' => l10n.reasoningEffortMaximum,
        'none' => l10n.reasoningEffortNone,
        _ => effort,
      };

  static String _functionCallingLabel(AppLocalizations l10n, String mode) =>
      switch (mode) {
        'native' => l10n.chatSettingFunctionCallingNative,
        'legacy' => l10n.chatSettingFunctionCallingLegacy,
        _ => mode,
      };

  static String _number(num value) =>
      value == value.truncate() ? '${value.truncate()}' : '$value';

  static String _errorText(
    AppLocalizations l10n,
    ChatParamSpec spec,
    ChatParamInputError error,
  ) => switch (error) {
    ChatParamInputError.required => l10n.chatSettingErrorRequired,
    ChatParamInputError.notANumber => l10n.chatSettingErrorNotANumber,
    ChatParamInputError.notAWholeNumber => l10n.chatSettingErrorNotAWholeNumber,
    ChatParamInputError.outOfRange =>
      spec.min != null && spec.max != null
          ? l10n.chatSettingErrorRange(_number(spec.min!), _number(spec.max!))
          : l10n.chatSettingErrorMinimum(_number(spec.min ?? 0)),
    ChatParamInputError.notJson => l10n.chatSettingErrorNotJson,
    ChatParamInputError.notAChoice => l10n.chatSettingErrorNotAChoice,
  };
}

/// Read-only summary: the chat has saved settings and they apply to every
/// reply, but the editor is not available (Advanced is off, or the account may
/// not change them). Offers to turn Advanced on when that is what is missing.
class OpenWebUiChatSettingsAppliedSheet extends ConsumerWidget {
  const OpenWebUiChatSettingsAppliedSheet({super.key, this.onAdvancedTurnedOn});

  /// Called once Advanced is on. The sheet closes itself when this is null;
  /// [showOpenWebUiChatSettings] passes one that swaps in the editor.
  final VoidCallback? onAdvancedTurnedOn;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    final conversation = ref.watch(activeConversationProvider);
    final params = conversation == null
        ? ref.watch(pendingOpenWebUiChatSettingsProvider)
        : conversation.chatParams;
    final advanced = ref.watch(
      appSettingsProvider.select((s) => s.advancedFeaturesEnabled),
    );
    final canEdit =
        ref
            .watch(openWebUiChatSettingsAccessProvider)
            .asData
            ?.value
            .canEditAnything ??
        false;
    final shown = <String>[
      for (final entry in params.entries)
        if (entry.key != kChatParamSystem) entry.key,
    ];

    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => Navigator.of(context).maybePop(),
            child: const SizedBox.shrink(),
          ),
        ),
        DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.5,
          minChildSize: 0.3,
          maxChildSize: 0.8,
          builder: (context, scrollController) => Container(
            decoration: BoxDecoration(
              color: theme.surfaceBackground,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(AppBorderRadius.bottomSheet),
              ),
              border: Border.all(
                color: theme.dividerColor,
                width: BorderWidth.regular,
              ),
              boxShadow: ConduitShadows.modal(context),
            ),
            child: ModalSheetSafeArea(
              padding: const EdgeInsets.all(Spacing.modalPadding),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SheetHandle(),
                  Text(
                    l10n.chatSettingsApplied,
                    style: theme.headingSmall?.copyWith(
                      color: theme.textPrimary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: Spacing.xs),
                  Text(
                    l10n.chatSettingsAppliedDescription,
                    style: theme.bodySmall?.copyWith(
                      color: theme.textSecondary,
                    ),
                  ),
                  const SizedBox(height: Spacing.md),
                  Expanded(
                    child: ListView(
                      controller: scrollController,
                      padding: EdgeInsets.zero,
                      children: [
                        if (params.containsKey(kChatParamSystem))
                          _AppliedRow(
                            label: l10n.chatSettingsSystemPrompt,
                            value: '${params[kChatParamSystem]}',
                          ),
                        for (final key in shown)
                          _AppliedRow(
                            label: _OpenWebUiChatSettingsSheetState._label(
                              l10n,
                              key,
                            ),
                            value: params[key] == null
                                ? l10n.chatSettingsModelDefault
                                : chatParamToText(
                                    chatParamSpecFor(key),
                                    params[key],
                                  ),
                          ),
                      ],
                    ),
                  ),
                  if (!advanced && canEdit) ...[
                    const SizedBox(height: Spacing.md),
                    ConduitButton(
                      key: const ValueKey('chat-settings-turn-on-advanced'),
                      text: l10n.chatSettingsTurnOnAdvanced,
                      isFullWidth: true,
                      onPressed: () async {
                        await ref
                            .read(appSettingsProvider.notifier)
                            .setAdvancedFeaturesEnabled(true);
                        if (!context.mounted) return;
                        final turnedOn = onAdvancedTurnedOn;
                        if (turnedOn != null) {
                          turnedOn();
                        } else {
                          Navigator.of(context).pop();
                        }
                      },
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _AppliedRow extends StatelessWidget {
  const _AppliedRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: Spacing.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 2,
            child: Text(
              label,
              style: theme.bodySmall?.copyWith(color: theme.textSecondary),
            ),
          ),
          Expanded(
            flex: 3,
            child: Text(
              value.isEmpty ? '—' : value,
              style: theme.bodyMedium?.copyWith(color: theme.textPrimary),
            ),
          ),
        ],
      ),
    );
  }
}

/// One option in a pick-one row. Shares [ConduitChip]'s look with a 44pt hit
/// area and the selected state announced, so it reads the same on iOS and
/// Android.
class _ChoicePill extends StatelessWidget {
  const _ChoicePill({
    super.key,
    required this.label,
    required this.selected,
    required this.onSelected,
  });

  final String label;
  final bool selected;
  final VoidCallback? onSelected;

  @override
  Widget build(BuildContext context) {
    final onSelected = this.onSelected;
    final VoidCallback? onTap = onSelected == null
        ? null
        : () {
            if (!selected) ConduitHaptics.selectionClick();
            onSelected();
          };
    return Semantics(
      button: true,
      selected: selected,
      enabled: onTap != null,
      label: label,
      onTap: onTap,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: TouchTarget.minimum),
          child: Center(
            widthFactor: 1,
            child: ConduitChip(label: label, isSelected: selected),
          ),
        ),
      ),
    );
  }
}
