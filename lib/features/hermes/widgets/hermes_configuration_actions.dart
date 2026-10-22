import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/features/hermes/models/hermes_model.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/hermes/services/hermes_desktop_api_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_identifier.dart';
import 'package:conduit_core/features/hermes/services/hermes_backend_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_visual_model_store.dart';
import 'package:conduit_core/features/hermes/services/hermes_session_provenance.dart';
import 'package:conduit_core/features/hermes/services/hermes_local_document_trust_store.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/providers/app_providers.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/utils/ui_utils.dart';
import '../../../shared/widgets/platform_ui/platform_ui.dart';
import '../../../shared/widgets/adaptive_selection_sheet.dart';

import 'package:conduit_core/features/hermes/services/hermes_run_transport.dart'
    show sanitizeHermesProviderErrorMessage;

import '../../../shared/widgets/themed_dialogs.dart';
import '../providers/hermes_mobile_navigation.dart';

/// Remove command syntax from the mobile reasoning answer; controls live in
/// the footer and use structured gateway reads rather than this text.
String hermesReasoningSummary(ChatMessage message, AppLocalizations l10n) {
  final effort =
      message.metadata?['hermesReasoningEffort'] as String? ??
      RegExp(
        r'Reasoning effort:\s*([^\n]+)',
        caseSensitive: false,
      ).firstMatch(message.content)?.group(1)?.trim();
  final display = message.metadata?['hermesReasoningDisplay'] as bool?;
  final rawDisplay = RegExp(
    r'Reasoning display:\s*(on|off|show|hide)',
    caseSensitive: false,
  ).firstMatch(message.content)?.group(1)?.toLowerCase();
  final shown =
      display ??
      (rawDisplay == null ? null : const {'on', 'show'}.contains(rawDisplay));
  return [
    if (effort != null && effort.isNotEmpty)
      '${l10n.mobileCurrentReasoning}: ${effort[0].toUpperCase()}${effort.substring(1)}',
    if (shown != null)
      '${l10n.mobileReasoningDisplay}: ${shown ? l10n.enabled : l10n.disabled}',
  ].join('\n');
}

/// User-operated configuration controls attached to a bare slash response.
/// Captures its conversation and connection before any asynchronous selection.
class HermesConfigurationActions extends ConsumerStatefulWidget {
  const HermesConfigurationActions({super.key, required this.message});
  final ChatMessage message;
  @override
  ConsumerState<HermesConfigurationActions> createState() =>
      _HermesConfigurationActionsState();
}

class _HermesConfigurationActionsState
    extends ConsumerState<HermesConfigurationActions> {
  bool _busy = false;
  bool _autoOpening = false;

  String? get _sessionId => validateHermesOpaqueIdentifier(
    widget.message.metadata?['hermesConfigurationSessionId'],
  );

  bool _ownsSession(
    HermesDesktopApiService service,
    String sessionId,
    String conversationId,
  ) {
    final conversation = ref.read(activeConversationProvider);
    final activeId = conversation?.metadata['hermesSessionId'];
    final endpoint = HermesConfigController.connectionEndpoint(
      service.config.baseUrl,
    );
    if (endpoint == null) return false;
    final identity = HermesLocalDocumentTrustStore.connectionIdentity(
      endpointIdentity: endpoint,
      principalId: ref
          .read(hermesConfigProvider.notifier)
          .documentTrustPrincipalId(),
    );
    return identical(ref.read(hermesApiServiceProvider), service) &&
        isNativeHermesConversation(conversation) &&
        conversation?.metadata[kHermesConnectionIdentityMetadataKey] ==
            identity &&
        widget.message.metadata?[kHermesConnectionIdentityMetadataKey] ==
            identity &&
        conversation?.id == conversationId &&
        activeId is String &&
        service.sessionIdsReferToSameBinding(activeId, sessionId) &&
        ref
            .read(chatMessagesProvider)
            .any((message) => message.id == widget.message.id);
  }

  @override
  Widget build(BuildContext context) {
    final service = ref.watch(hermesApiServiceProvider);
    final conversation = ref.watch(activeConversationProvider);
    final session = _sessionId;
    final command = widget.message.metadata?['hermesConfigurationCommand'];
    if (service is! HermesDesktopApiService ||
        conversation == null ||
        session == null ||
        !const {'model', 'reasoning'}.contains(command) ||
        !_ownsSession(service, session, conversation.id)) {
      return const SizedBox.shrink();
    }
    final l10n = AppLocalizations.of(context)!;
    final navigation = ref.watch(hermesMobileNavigationProvider);
    if (!_autoOpening &&
        !widget.message.isStreaming &&
        widget.message.metadata?['hermesConfigurationAutoOpen'] == true &&
        navigation.area == HermesWorkArea.chat &&
        navigation.conversation) {
      _autoOpening = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_ownsSession(service, session, conversation.id)) {
          return;
        }
        final live = ref
            .read(chatMessagesProvider)
            .where((message) => message.id == widget.message.id)
            .firstOrNull;
        if (live?.metadata?['hermesConfigurationAutoOpen'] != true) return;
        ref
            .read(chatMessagesProvider.notifier)
            .updateMessageById(
              widget.message.id,
              (message) => message.copyWith(
                metadata: {
                  ...?message.metadata,
                  'hermesConfigurationAutoOpen': false,
                },
              ),
            );
        _choose(service, session, conversation.id, command as String);
      });
    }
    return CompactActionBubble(
      label: command == 'model'
          ? l10n.mobileChangeModel
          : l10n.mobileChangeReasoning,
      busy: _busy,
      onPressed: _busy
          ? null
          : () => _choose(service, session, conversation.id, command as String),
    );
  }

  Future<T?> _select<T>(
    String title,
    List<({T value, String label})> choices, {
    T? current,
  }) => showAdaptiveSelectionSheet<T>(
    context: context,
    builder: (sheetContext) => AdaptiveSelectionSheet(
      title: title,
      initialChildSize: .51,
      itemCount: choices.length,
      itemBuilder: (_, index) => AdaptiveSelectionTile(
        title: choices[index].label,
        selected: choices[index].value == current,
        onTap: () => Navigator.of(sheetContext).pop(choices[index].value),
      ),
    ),
  );

  Future<void> _rememberSelection(
    HermesDesktopApiService service,
    String session,
    bool Function() current,
  ) async {
    await service.sessionReasoningSettings(session);
    if (!current()) return;
    final endpoint = HermesConfigController.connectionEndpoint(
      service.config.baseUrl,
    );
    if (endpoint == null) return;
    final identity = HermesLocalDocumentTrustStore.connectionIdentity(
      endpointIdentity: endpoint,
      principalId: ref
          .read(hermesConfigProvider.notifier)
          .documentTrustPrincipalId(),
    );
    await HermesVisualModelStore.write(
      identity,
      session,
      const HermesDesktopSessionOptions(preserveSession: true),
    );
  }

  Future<void> _choose(
    HermesDesktopApiService service,
    String sessionId,
    String conversationId,
    String command,
  ) async {
    final controller = ref.read(hermesConfigProvider.notifier);
    final admission = controller.captureSessionActionAdmission();
    if (admission == null) return;
    bool current() =>
        mounted &&
        controller.sessionActionAdmissionIsCurrent(admission) &&
        _ownsSession(service, sessionId, conversationId);
    final l10n = AppLocalizations.of(context)!;
    setState(() => _busy = true);
    try {
      if (command == 'model') {
        final options = await service.sessionModelOptions(sessionId);
        if (!mounted || !current()) return;
        if (options.isEmpty) {
          UiUtils.showMessage(context, l10n.mobileNoModels);
          return;
        }
        final providers =
            options.map((model) => model.provider).toSet().toList()..sort();
        final provider = await showCompactSelectionGrid<String>(
          context,
          title: l10n.mobileChooseProvider,
          choices: [
            for (final provider in providers)
              CompactMenuChoice(provider, provider),
          ],
        );
        if (!mounted || !current() || provider == null) return;
        final models =
            options.where((model) => model.provider == provider).toList()
              ..sort((a, b) => a.name.compareTo(b.name));
        final selected = await _select(l10n.mobileChooseModel, [
          for (final model in models) (value: model, label: model.name),
        ]);
        if (!mounted || !current() || selected == null) return;
        final reasoning = await service.sessionReasoning(sessionId);
        if (!mounted || !current()) return;
        var result = await service.configureSession(
          sessionId,
          model: selected.id,
          provider: selected.provider,
        );
        if (!mounted || !current()) return;
        if (result['confirm_required'] == true) {
          final confirmed = await ThemedDialogs.confirm(
            context,
            title: l10n.mobileChooseModel,
            message: sanitizeHermesProviderErrorMessage(
              validateHermesBoundedString(
                    result['confirm_message'],
                    maxCharacters: 1000,
                  ) ??
                  selected.name,
              sensitiveValues: service.config.sensitiveValues,
            ),
          );
          if (!mounted || !current() || !confirmed) return;
          result = await service.configureSession(
            sessionId,
            model: selected.id,
            provider: selected.provider,
            confirmExpensiveModel: true,
          );
          if (!mounted || !current()) return;
          if (result['confirm_required'] == true) {
            throw StateError('Model confirmation was not accepted.');
          }
        }
        final pickedModel = hermesDesktopModel(
          modelId: selected.id,
          name: selected.name,
          provider: selected.provider,
          supportsFast: selected.supportsFast,
          supportsReasoning: selected.supportsReasoning,
        );
        ref.read(selectedModelProvider.notifier).set(pickedModel);
        if (const {
          'none',
          'minimal',
          'low',
          'medium',
          'high',
          'xhigh',
          'max',
          'ultra',
        }.contains(reasoning)) {
          await selectReasoningEffortForModel(ref, pickedModel, reasoning!);
          if (!mounted || !current()) return;
        }
        await _rememberSelection(service, sessionId, current);
        if (!mounted || !current()) return;
        final warning = validateHermesBoundedString(
          result['warning'],
          maxCharacters: 1000,
        );
        UiUtils.showMessage(
          context,
          warning == null
              ? l10n.mobileConfigurationSaved
              : sanitizeHermesProviderErrorMessage(
                  warning,
                  sensitiveValues: service.config.sensitiveValues,
                ),
        );
      } else {
        final settings = await service.sessionReasoningSettings(sessionId);
        if (!mounted || !current()) return;
        void record({String? effort, bool? display}) => ref
            .read(chatMessagesProvider.notifier)
            .updateMessageById(
              widget.message.id,
              (message) => message.copyWith(
                metadata: {
                  ...?message.metadata,
                  if (effort != null && effort.isNotEmpty)
                    'hermesReasoningEffort': effort,
                  'hermesReasoningDisplay': ?display,
                },
              ),
            );
        record(effort: settings.effort, display: settings.display);
        final selected = await showCompactConfigurationSheet<String>(
          context,
          (sheetContext) => _ReasoningPicker(
            settings: settings,
            onSelected: (value) => Navigator.of(sheetContext).pop(value),
            onDisplayChanged: (display) async {
              if (!current()) return false;
              try {
                await service.configureSession(
                  sessionId,
                  reasoningDisplay: display,
                );
                if (!current()) return false;
                record(display: display);
                return true;
              } catch (_) {
                return false;
              }
            },
          ),
        );
        if (!mounted || !current() || selected == null) return;
        await service.configureSession(sessionId, reasoning: selected);
        if (!mounted || !current()) return;
        await _rememberSelection(service, sessionId, current);
        if (!mounted || !current()) return;
        record(effort: selected);
        final model = ref.read(selectedModelProvider);
        if (model != null && isHermesModel(model)) {
          await selectReasoningEffortForModel(ref, model, selected);
        }
        if (mounted && current()) {
          UiUtils.showMessage(context, l10n.mobileConfigurationSaved);
        }
      }
    } catch (_) {
      if (mounted && current()) {
        UiUtils.showMessage(
          context,
          l10n.mobileConfigurationFailed,
          isError: true,
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

class _ReasoningPicker extends StatefulWidget {
  const _ReasoningPicker({
    required this.settings,
    required this.onSelected,
    required this.onDisplayChanged,
  });
  final HermesSessionReasoningSettings settings;
  final ValueChanged<String> onSelected;
  final Future<bool> Function(bool) onDisplayChanged;
  @override
  State<_ReasoningPicker> createState() => _ReasoningPickerState();
}

class _ReasoningPickerState extends State<_ReasoningPicker> {
  late bool? _display = widget.settings.display;
  bool _busy = false;
  bool _failed = false;
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final settings = widget.settings;
    final effort = settings.effort;
    return CompactSelectionGrid<String>(
      title: l10n.mobileChooseReasoning,
      choices: [
        for (final level in settings.levels)
          CompactMenuChoice(
            level,
            level == 'none'
                ? l10n.disabled
                : level[0].toUpperCase() + level.substring(1),
            selected: effort == level,
            enabled: !_busy,
          ),
      ],
      onSelected: widget.onSelected,
      header: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (settings.model != null)
            Text(
              settings.model!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          if (effort != null && effort.isNotEmpty)
            Text('${l10n.mobileCurrentReasoning}: $effort'),
          Row(
            children: [
              Expanded(child: Text(l10n.mobileReasoningDisplay)),
              if (_display == null)
                Text(l10n.mobileConfigurationUnavailable)
              else
                AdaptiveSwitch(
                  value: _display!,
                  onChanged: _busy
                      ? null
                      : (value) async {
                          setState(() {
                            _busy = true;
                            _failed = false;
                          });
                          final success = await widget.onDisplayChanged(value);
                          if (!mounted) return;
                          setState(() {
                            _busy = false;
                            _failed = !success;
                            if (success) _display = value;
                          });
                        },
                ),
            ],
          ),
          Text(
            l10n.mobileReasoningProfileDisplay,
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          Text(
            settings.reasoningAvailable == false
                ? l10n.mobileNoReasoningSupport
                : l10n.mobileReasoningLevelsHint,
            style: Theme.of(context).textTheme.bodySmall,
          ),
          if (_busy) const AdaptiveProgressIndicator(),
          if (_failed) Text(l10n.mobileConfigurationFailed),
        ],
      ),
    );
  }
}
