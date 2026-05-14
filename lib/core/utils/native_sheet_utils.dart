import 'package:intl/intl.dart';

import '../../l10n/app_localizations.dart';
import '../models/model.dart';
import '../models/server_memory.dart';
import '../models/socket_health.dart';
import '../services/native_sheet_bridge.dart';

String nativeQuickActionsTitle(AppLocalizations l10n) {
  return l10n.quickActionsDescription;
}

String? resolveNativeSheetModelName(List<Model> models, String? modelId) {
  if (modelId == null || modelId.isEmpty) return null;
  for (final model in models) {
    if (model.id == modelId) return model.name;
  }
  return modelId;
}

String nativeSheetPreviewText(AppLocalizations l10n, String? value) {
  if (value == null || value.trim().isEmpty) return l10n.notSet;
  final text = value.trim();
  if (text.length > 88) return '${text.substring(0, 85)}...';
  return text;
}

String truncateNativeSheetMemory(String content) {
  final normalized = content.trim().replaceAll('\n', ' ');
  if (normalized.length <= 72) return normalized;
  return '${normalized.substring(0, 69)}...';
}

String nativeSheetMemoryUpdatedSubtitle(
  AppLocalizations l10n,
  ServerMemory memory,
) {
  final formatted = DateFormat.yMMMd().add_jm().format(memory.updatedAt);
  return l10n.memoryUpdatedAt(formatted);
}

NativeSheetItemConfig buildNativeLoadingItem(
  AppLocalizations l10n, {
  String id = 'loading',
  String? title,
  String sfSymbol = 'ellipsis.circle',
}) {
  return NativeSheetItemConfig(
    id: id,
    title: title ?? l10n.loadingShort,
    sfSymbol: sfSymbol,
    kind: NativeSheetItemKind.info,
  );
}

NativeSheetDetailConfig buildNativeLoadingDetail({
  required AppLocalizations l10n,
  required String id,
  required String title,
  String? subtitle,
}) {
  return NativeSheetDetailConfig(
    id: id,
    title: title,
    subtitle: subtitle ?? l10n.loadingShort,
    items: [buildNativeLoadingItem(l10n, id: '$id-loading')],
  );
}

NativeSheetDetailConfig buildNativePasswordDetail(
  AppLocalizations l10n, {
  required bool passwordChangeEnabled,
  String? subtitle,
}) {
  final items = passwordChangeEnabled
      ? [
          NativeSheetItemConfig(
            id: 'current-password',
            title: l10n.currentPassword,
            subtitle: l10n.passwordHint,
            sfSymbol: 'lock',
            kind: NativeSheetItemKind.secureTextField,
            placeholder: l10n.currentPassword,
          ),
          NativeSheetItemConfig(
            id: 'new-password',
            title: l10n.newPassword,
            subtitle: l10n.passwordHint,
            sfSymbol: 'key',
            kind: NativeSheetItemKind.secureTextField,
            placeholder: l10n.newPassword,
          ),
          NativeSheetItemConfig(
            id: 'confirm-password',
            title: l10n.confirmNewPassword,
            subtitle: l10n.passwordHint,
            sfSymbol: 'checkmark.shield',
            kind: NativeSheetItemKind.secureTextField,
            placeholder: l10n.confirmNewPassword,
          ),
        ]
      : [
          NativeSheetItemConfig(
            id: 'password-unavailable',
            title: l10n.changePasswordTitle,
            subtitle: l10n.passwordChangeUnavailable,
            sfSymbol: 'lock.slash',
            kind: NativeSheetItemKind.info,
          ),
        ];
  return NativeSheetDetailConfig(
    id: 'password',
    title: l10n.changePasswordTitle,
    subtitle: passwordChangeEnabled ? subtitle : null,
    items: items,
  );
}

List<NativeSheetOptionConfig> buildNativeDefaultModelOptions(
  AppLocalizations l10n,
  List<Model> models,
) {
  return [
    NativeSheetOptionConfig(id: 'auto-select', label: l10n.autoSelect),
    for (final model in models)
      NativeSheetOptionConfig(id: model.id, label: model.name),
  ];
}

NativeSheetDetailConfig buildNativeDefaultModelDetail(
  AppLocalizations l10n, {
  required List<Model> models,
  required String? selectedModelId,
  String? subtitle,
}) {
  return NativeSheetDetailConfig(
    id: 'default-model',
    title: l10n.defaultModel,
    subtitle: subtitle ?? l10n.autoSelectDescription,
    items: [
      NativeSheetItemConfig(
        id: 'default-model',
        title: l10n.defaultModel,
        subtitle: l10n.autoSelectDescription,
        sfSymbol: 'wand.and.stars',
        kind: NativeSheetItemKind.dropdown,
        value: selectedModelId ?? 'auto-select',
        options: buildNativeDefaultModelOptions(l10n, models),
      ),
    ],
  );
}

NativeSheetDetailConfig buildNativeSystemPromptDetail(
  AppLocalizations l10n, {
  required String value,
  String? subtitle,
}) {
  return NativeSheetDetailConfig(
    id: 'system-prompt',
    title: l10n.yourSystemPrompt,
    subtitle: subtitle ?? l10n.yourSystemPromptDescription,
    items: [
      NativeSheetItemConfig(
        id: 'system-prompt',
        title: l10n.yourSystemPrompt,
        subtitle: l10n.enterSystemPrompt,
        sfSymbol: 'text.bubble',
        kind: NativeSheetItemKind.multilineTextField,
        value: value,
        placeholder: l10n.enterSystemPrompt,
      ),
    ],
  );
}

NativeSheetDetailConfig buildNativeMemoryAddDetail(AppLocalizations l10n) {
  return NativeSheetDetailConfig(
    id: 'memory-add',
    title: l10n.addMemory,
    subtitle: l10n.memoryEditorDescription,
    items: [
      NativeSheetItemConfig(
        id: 'memory-add-content',
        title: l10n.addMemory,
        sfSymbol: 'plus.circle',
        kind: NativeSheetItemKind.multilineTextField,
        value: '',
        placeholder: l10n.memoryHint,
      ),
    ],
  );
}

List<NativeSheetDetailConfig> buildNativeMemoryEditDetails(
  AppLocalizations l10n,
  List<ServerMemory> memories,
) {
  return [
    for (final memory in memories)
      NativeSheetDetailConfig(
        id: 'memory-edit:${Uri.encodeComponent(memory.id)}',
        title: l10n.editMemory,
        subtitle: l10n.memoryEditorDescription,
        items: [
          NativeSheetItemConfig(
            id: 'memory-save:${Uri.encodeComponent(memory.id)}',
            title: l10n.editMemory,
            sfSymbol: 'quote.bubble',
            kind: NativeSheetItemKind.multilineTextField,
            value: memory.content,
            placeholder: l10n.memoryHint,
          ),
          NativeSheetItemConfig(
            id: 'memory-delete:${Uri.encodeComponent(memory.id)}',
            title: l10n.deleteMemory,
            subtitle: l10n.deleteMemoryConfirm,
            sfSymbol: 'trash',
            destructive: true,
          ),
        ],
      ),
  ];
}

List<NativeSheetDetailConfig> buildNativeModelPromptLoadingDetails(
  AppLocalizations l10n,
  List<Model> models,
) {
  return [
    for (final model in models)
      NativeSheetDetailConfig(
        id: 'model-prompt:${Uri.encodeComponent(model.id)}',
        title: l10n.modelSystemPromptTitle(model.name),
        subtitle: l10n.loadingShort,
        items: [
          buildNativeLoadingItem(
            l10n,
            id: 'model-prompt-loading:${Uri.encodeComponent(model.id)}',
          ),
        ],
      ),
  ];
}

String nativeLanguageLabel(AppLocalizations l10n, String code) {
  switch (code) {
    case 'system':
      return l10n.system;
    case 'en':
      return l10n.english;
    case 'de':
      return l10n.deutsch;
    case 'fr':
      return l10n.francais;
    case 'it':
      return l10n.italiano;
    case 'es':
      return l10n.espanol;
    case 'nl':
      return l10n.nederlands;
    case 'ru':
      return l10n.russian;
    case 'zh':
      return l10n.chineseSimplified;
    case 'ko':
      return l10n.korean;
    case 'ja':
      return l10n.japanese;
    case 'zh-Hant':
      return l10n.chineseTraditional;
    default:
      final normalized = code.replaceAll('_', '-').toLowerCase();
      if (normalized == 'zh-hant') return l10n.chineseTraditional;
      if (normalized == 'zh') return l10n.chineseSimplified;
      if (normalized == 'ko') return l10n.korean;
      if (normalized == 'ja') return l10n.japanese;
      return l10n.system;
  }
}

List<NativeSheetOptionConfig> nativeLanguageDropdownOptions(
  AppLocalizations l10n,
) {
  return [
    NativeSheetOptionConfig(id: 'system', label: l10n.system),
    NativeSheetOptionConfig(id: 'en', label: l10n.english),
    NativeSheetOptionConfig(id: 'de', label: l10n.deutsch),
    NativeSheetOptionConfig(id: 'es', label: l10n.espanol),
    NativeSheetOptionConfig(id: 'fr', label: l10n.francais),
    NativeSheetOptionConfig(id: 'it', label: l10n.italiano),
    NativeSheetOptionConfig(id: 'nl', label: l10n.nederlands),
    NativeSheetOptionConfig(id: 'ru', label: l10n.russian),
    NativeSheetOptionConfig(id: 'zh', label: l10n.chineseSimplified),
    NativeSheetOptionConfig(id: 'zh-Hant', label: l10n.chineseTraditional),
    NativeSheetOptionConfig(id: 'ko', label: l10n.korean),
    NativeSheetOptionConfig(id: 'ja', label: l10n.japanese),
  ];
}

String nativeSocketHealthSummary(AppLocalizations l10n, SocketHealth? health) {
  if (health == null) return l10n.socketNotConnected;
  if (!health.isConnected) return l10n.socketDisconnected;
  final transport = _nativeSocketTransportLabel(l10n, health.transport);
  if (health.hasLatencyInfo) {
    return '$transport · ${health.latencyMs}ms';
  }
  return transport;
}

List<NativeSheetItemConfig> nativeSocketHealthItems(
  AppLocalizations l10n,
  SocketHealth? health,
) {
  if (health == null) {
    return [
      NativeSheetItemConfig(
        id: 'socket-health-null',
        title: l10n.socketNotConnected,
        sfSymbol: 'cloud.fill',
        kind: NativeSheetItemKind.info,
      ),
    ];
  }
  final transportLabel = _nativeSocketTransportLabel(l10n, health.transport);
  final items = <NativeSheetItemConfig>[
    NativeSheetItemConfig(
      id: 'socket-connected',
      title: health.isConnected
          ? l10n.socketConnected
          : l10n.socketDisconnected,
      subtitle: transportLabel,
      sfSymbol: health.isConnected
          ? 'checkmark.circle.fill'
          : 'xmark.circle.fill',
      kind: NativeSheetItemKind.info,
    ),
  ];
  if (health.isConnected && health.hasLatencyInfo) {
    items.add(
      NativeSheetItemConfig(
        id: 'socket-latency',
        title: l10n.socketLatencyLabel,
        subtitle:
            '${health.latencyMs}ms · ${_nativeSocketQualityLabel(l10n, health.quality)}',
        sfSymbol: 'gauge.with.dots.needle.67percent',
        kind: NativeSheetItemKind.info,
      ),
    );
  }
  items.add(
    NativeSheetItemConfig(
      id: 'socket-reconnects',
      title: l10n.socketReconnectsLabel,
      subtitle: '${health.reconnectCount}',
      sfSymbol: 'arrow.clockwise',
      kind: NativeSheetItemKind.info,
    ),
  );
  if (health.lastHeartbeat != null) {
    items.add(
      NativeSheetItemConfig(
        id: 'socket-heartbeat',
        title: l10n.socketLastHeartbeat(
          _nativeFormatHeartbeatRelative(l10n, health.lastHeartbeat!),
        ),
        sfSymbol: 'heart.fill',
        kind: NativeSheetItemKind.info,
      ),
    );
  }
  return items;
}

String _nativeSocketTransportLabel(AppLocalizations l10n, String transport) {
  switch (transport) {
    case 'websocket':
      return l10n.socketTransportWebSocket;
    case 'polling':
      return l10n.socketTransportPolling;
    default:
      return l10n.socketTransportUnknown;
  }
}

String _nativeSocketQualityLabel(AppLocalizations l10n, String quality) {
  switch (quality) {
    case 'excellent':
      return l10n.socketQualityExcellent;
    case 'good':
      return l10n.socketQualityGood;
    case 'fair':
      return l10n.socketQualityFair;
    case 'poor':
      return l10n.socketQualityPoor;
    default:
      return '—';
  }
}

String _nativeFormatHeartbeatRelative(
  AppLocalizations l10n,
  DateTime lastHeartbeat,
) {
  final diff = DateTime.now().difference(lastHeartbeat);
  if (diff.inSeconds < 5) return l10n.timeJustNow;
  if (diff.inSeconds < 60) return l10n.timeSecondsAgo(diff.inSeconds);
  if (diff.inMinutes < 60) return l10n.timeMinutesAgo(diff.inMinutes);
  return l10n.timeHoursAgo(diff.inHours);
}
