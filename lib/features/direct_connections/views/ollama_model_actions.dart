import 'dart:io' show Platform;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/utils/debug_logger.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/utils/ui_utils.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../../../shared/widgets/themed_dialogs.dart';
import '../../profile/widgets/settings_page_scaffold.dart';
import '../models/ollama_keep_alive.dart';
import '../models/ollama_thinking.dart';
import '../providers/direct_connection_providers.dart';

enum _OllamaModelAction { load, unload, keepAlive, thinking }

const String _serverDefaultValue = '__server_default__';
const String _customValue = '__custom__';
const String _automaticThinkingValue = '__automatic__';

final class _KeepAliveOption {
  const _KeepAliveOption(this.value, this.label);

  final String value;
  final String label;
}

class OllamaModelActionsButton extends ConsumerWidget {
  const OllamaModelActionsButton({
    super.key,
    required this.profileId,
    required this.remoteModelId,
    required this.modelName,
    required this.isLoaded,
    required this.isStatusKnown,
    required this.isBusy,
    required this.currentKeepAlive,
    required this.supportsLifecycle,
    required this.isCloud,
    required this.currentThinking,
  });

  final String profileId;
  final String remoteModelId;
  final String modelName;
  final bool isLoaded;
  final bool isStatusKnown;
  final bool isBusy;
  final String? currentKeepAlive;
  final bool supportsLifecycle;
  final bool isCloud;
  final OllamaThinkingSetting? currentThinking;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    if (isBusy) {
      return const SizedBox.square(
        dimension: 32,
        child: Center(child: ConduitLoadingIndicator(isCompact: true)),
      );
    }
    return IconButton(
      key: ValueKey('ollama-model-actions:$profileId:$remoteModelId'),
      tooltip: l10n.ollamaModelActions,
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints.tightFor(width: 32, height: 32),
      padding: EdgeInsets.zero,
      iconSize: IconSize.small,
      icon: Icon(
        Platform.isIOS ? CupertinoIcons.ellipsis : Icons.more_horiz_rounded,
        color: context.conduitTheme.textSecondary,
      ),
      onPressed: () => _showActions(context, ref),
    );
  }

  Future<void> _showActions(BuildContext context, WidgetRef ref) async {
    final l10n = AppLocalizations.of(context)!;
    final actions = <_OllamaModelAction>[
      if (supportsLifecycle && (!isStatusKnown || !isLoaded))
        _OllamaModelAction.load,
      if (supportsLifecycle && (!isStatusKnown || isLoaded))
        _OllamaModelAction.unload,
      if (supportsLifecycle) _OllamaModelAction.keepAlive,
      if (isCloud) _OllamaModelAction.thinking,
    ];
    final selected = await showSettingsSheet<_OllamaModelAction>(
      context: context,
      builder: (sheetContext) => SettingsSelectorSheet(
        title: modelName,
        description: isCloud && !supportsLifecycle
            ? l10n.ollamaCloudModelActionsDescription
            : l10n.ollamaModelActionsDescription,
        itemCount: actions.length,
        initialChildSize: 0.42,
        minChildSize: 0.3,
        maxChildSize: 0.68,
        itemBuilder: (context, index) {
          final action = actions[index];
          return switch (action) {
            _OllamaModelAction.load => SettingsSelectorTile(
              title: l10n.ollamaLoadModel,
              subtitle: l10n.ollamaLoadModelDescription,
              selected: false,
              leading: Icon(
                Platform.isIOS
                    ? CupertinoIcons.arrow_down_to_line
                    : Icons.download_rounded,
                color: context.conduitTheme.buttonPrimary,
              ),
              onTap: () => Navigator.of(sheetContext).pop(action),
            ),
            _OllamaModelAction.unload => SettingsSelectorTile(
              title: l10n.ollamaUnloadModel,
              subtitle: l10n.ollamaUnloadModelDescription,
              selected: false,
              leading: Icon(
                Platform.isIOS ? CupertinoIcons.eject : Icons.eject_rounded,
                color: context.conduitTheme.error,
              ),
              onTap: () => Navigator.of(sheetContext).pop(action),
            ),
            _OllamaModelAction.keepAlive => SettingsSelectorTile(
              title: l10n.ollamaKeepAlive,
              subtitle: _keepAliveLabel(l10n, currentKeepAlive),
              selected: false,
              leading: Icon(
                Platform.isIOS ? CupertinoIcons.timer : Icons.timer_outlined,
                color: context.conduitTheme.textSecondary,
              ),
              onTap: () => Navigator.of(sheetContext).pop(action),
            ),
            _OllamaModelAction.thinking => SettingsSelectorTile(
              title: l10n.ollamaThinking,
              subtitle: _thinkingLabel(l10n, currentThinking),
              selected: false,
              leading: Icon(
                Platform.isIOS
                    ? CupertinoIcons.lightbulb
                    : Icons.psychology_alt_rounded,
                color: context.conduitTheme.textSecondary,
              ),
              onTap: () => Navigator.of(sheetContext).pop(action),
            ),
          };
        },
      ),
    );
    if (!context.mounted || selected == null) return;

    switch (selected) {
      case _OllamaModelAction.load:
        await _load(context, ref);
      case _OllamaModelAction.unload:
        await _unload(context, ref);
      case _OllamaModelAction.keepAlive:
        await _showKeepAlive(context, ref);
      case _OllamaModelAction.thinking:
        await _showThinking(context, ref);
    }
  }

  Future<void> _load(BuildContext context, WidgetRef ref) async {
    final l10n = AppLocalizations.of(context)!;
    try {
      await ref
          .read(ollamaModelLifecycleProvider(profileId).notifier)
          .loadModel(remoteModelId);
      if (context.mounted) {
        UiUtils.showMessage(context, l10n.ollamaModelLoadedMessage(modelName));
      }
    } catch (error) {
      DebugLogger.error(
        'load-failed',
        scope: 'direct/ollama-actions',
        error: error,
      );
      if (context.mounted) {
        UiUtils.showMessage(
          context,
          l10n.ollamaModelActionFailed,
          isError: true,
        );
      }
    }
  }

  Future<void> _unload(BuildContext context, WidgetRef ref) async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await ThemedDialogs.confirm(
      context,
      title: l10n.ollamaUnloadModelConfirmTitle(modelName),
      message: l10n.ollamaUnloadModelConfirmMessage,
      confirmText: l10n.ollamaUnloadModel,
      isDestructive: true,
    );
    if (!context.mounted || !confirmed) return;
    try {
      await ref
          .read(ollamaModelLifecycleProvider(profileId).notifier)
          .unloadModel(remoteModelId);
      if (context.mounted) {
        UiUtils.showMessage(
          context,
          l10n.ollamaModelUnloadedMessage(modelName),
        );
      }
    } catch (error) {
      DebugLogger.error(
        'unload-failed',
        scope: 'direct/ollama-actions',
        error: error,
      );
      if (context.mounted) {
        UiUtils.showMessage(
          context,
          l10n.ollamaModelActionFailed,
          isError: true,
        );
      }
    }
  }

  Future<void> _showKeepAlive(BuildContext context, WidgetRef ref) async {
    final l10n = AppLocalizations.of(context)!;
    final options = <_KeepAliveOption>[
      _KeepAliveOption(_serverDefaultValue, l10n.ollamaKeepAliveServerDefault),
      _KeepAliveOption('5m', l10n.ollamaKeepAliveFiveMinutes),
      _KeepAliveOption('30m', l10n.ollamaKeepAliveThirtyMinutes),
      _KeepAliveOption('1h', l10n.ollamaKeepAliveOneHour),
      _KeepAliveOption('-1', l10n.ollamaKeepAliveAlways),
      _KeepAliveOption('0', l10n.ollamaKeepAliveImmediate),
      _KeepAliveOption(_customValue, l10n.ollamaKeepAliveCustom),
    ];
    final selected = await showSettingsSheet<String>(
      context: context,
      builder: (sheetContext) => SettingsSelectorSheet(
        title: l10n.ollamaKeepAlive,
        description: l10n.ollamaKeepAliveDescription,
        itemCount: options.length,
        initialChildSize: 0.62,
        minChildSize: 0.4,
        maxChildSize: 0.84,
        itemBuilder: (context, index) {
          final option = options[index];
          final selectedValue = currentKeepAlive ?? _serverDefaultValue;
          final isPreset = options
              .where((item) => item.value != _customValue)
              .any((item) => item.value == selectedValue);
          return SettingsSelectorTile(
            title: option.label,
            subtitle: option.value == _customValue && !isPreset
                ? currentKeepAlive
                : null,
            selected: option.value == _customValue
                ? !isPreset
                : option.value == selectedValue,
            onTap: () => Navigator.of(sheetContext).pop(option.value),
          );
        },
      ),
    );
    if (!context.mounted || selected == null) return;

    String? value;
    if (selected == _serverDefaultValue) {
      value = null;
    } else if (selected == _customValue) {
      final input = await ThemedDialogs.promptTextInput(
        context,
        title: l10n.ollamaKeepAlive,
        hintText: l10n.ollamaKeepAliveCustomHint,
        initialValue: currentKeepAlive,
        keyboardType: TextInputType.text,
        textCapitalization: TextCapitalization.none,
        maxLength: 64,
      );
      if (input == null || !context.mounted) return;
      try {
        value = normalizeOllamaKeepAlive(input);
      } on FormatException {
        UiUtils.showMessage(
          context,
          l10n.ollamaKeepAliveInvalid,
          isError: true,
        );
        return;
      }
    } else {
      value = selected;
    }

    try {
      await ref
          .read(ollamaModelLifecycleProvider(profileId).notifier)
          .setKeepAlive(remoteModelId, value);
      if (context.mounted) UiUtils.showMessage(context, l10n.saved);
    } catch (error) {
      DebugLogger.error(
        'keep-alive-save-failed',
        scope: 'direct/ollama-actions',
        error: error,
      );
      if (context.mounted) {
        UiUtils.showMessage(
          context,
          l10n.directConnectionSaveFailed,
          isError: true,
        );
      }
    }
  }

  static String _keepAliveLabel(AppLocalizations l10n, String? keepAlive) =>
      switch (keepAlive) {
        null => l10n.ollamaKeepAliveServerDefault,
        '5m' => l10n.ollamaKeepAliveFiveMinutes,
        '30m' => l10n.ollamaKeepAliveThirtyMinutes,
        '1h' => l10n.ollamaKeepAliveOneHour,
        '-1' => l10n.ollamaKeepAliveAlways,
        '0' => l10n.ollamaKeepAliveImmediate,
        final value => value,
      };

  Future<void> _showThinking(BuildContext context, WidgetRef ref) async {
    final l10n = AppLocalizations.of(context)!;
    final isGptOss = remoteModelId.toLowerCase().contains('gpt-oss');
    final options = <({String value, String label})>[
      (value: _automaticThinkingValue, label: l10n.ollamaThinkingAutomatic),
      if (!isGptOss)
        (
          value: OllamaThinkingSetting.disabled.storageValue,
          label: l10n.ollamaThinkingDisabled,
        ),
      (
        value: OllamaThinkingSetting.low.storageValue,
        label: l10n.ollamaThinkingLow,
      ),
      (
        value: OllamaThinkingSetting.medium.storageValue,
        label: l10n.ollamaThinkingMedium,
      ),
      (
        value: OllamaThinkingSetting.high.storageValue,
        label: l10n.ollamaThinkingHigh,
      ),
      if (!isGptOss)
        (
          value: OllamaThinkingSetting.max.storageValue,
          label: l10n.ollamaThinkingMaximum,
        ),
    ];
    final selected = await showSettingsSheet<String>(
      context: context,
      builder: (sheetContext) => SettingsSelectorSheet(
        title: l10n.ollamaThinking,
        description: l10n.ollamaThinkingDescription,
        itemCount: options.length,
        initialChildSize: 0.58,
        minChildSize: 0.4,
        maxChildSize: 0.8,
        itemBuilder: (context, index) {
          final option = options[index];
          return SettingsSelectorTile(
            title: option.label,
            selected:
                option.value ==
                (currentThinking?.storageValue ?? _automaticThinkingValue),
            onTap: () => Navigator.of(sheetContext).pop(option.value),
          );
        },
      ),
    );
    if (!context.mounted || selected == null) return;
    final setting = selected == _automaticThinkingValue
        ? null
        : OllamaThinkingSetting.fromStorage(selected);
    try {
      await ref
          .read(directConnectionProfilesProvider.notifier)
          .setOllamaThinking(profileId, remoteModelId, setting);
      if (context.mounted) UiUtils.showMessage(context, l10n.saved);
    } catch (error) {
      DebugLogger.error(
        'thinking-save-failed',
        scope: 'direct/ollama-actions',
        error: error,
      );
      if (context.mounted) {
        UiUtils.showMessage(
          context,
          l10n.directConnectionSaveFailed,
          isError: true,
        );
      }
    }
  }

  static String _thinkingLabel(
    AppLocalizations l10n,
    OllamaThinkingSetting? setting,
  ) => switch (setting) {
    null => l10n.ollamaThinkingAutomatic,
    OllamaThinkingSetting.disabled => l10n.ollamaThinkingDisabled,
    OllamaThinkingSetting.low => l10n.ollamaThinkingLow,
    OllamaThinkingSetting.medium => l10n.ollamaThinkingMedium,
    OllamaThinkingSetting.high => l10n.ollamaThinkingHigh,
    OllamaThinkingSetting.max => l10n.ollamaThinkingMaximum,
  };
}
