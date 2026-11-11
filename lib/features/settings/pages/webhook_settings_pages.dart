import 'package:collection/collection.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit_core/features/notifications/models/notification_target.dart';
import 'package:conduit_core/features/notifications/providers/notification_target_providers.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:conduit_core/utils/debug_logger.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/native_sheet_bridge.dart';
import '../../../core/utils/native_sheet_utils.dart';
import '../settings_page_module.dart';
import '../settings_pages.dart';

/// Id of the page listing the account's webhook destinations.
const webhookListPageId = 'notification-targets';

/// Id of the page that adds a destination.
const webhookNewPageId = 'webhook-new';

/// Prefix of the page of one destination; its id follows, URI-encoded.
const webhookPagePrefix = 'webhook:';

/// Row ids of a destination page: `webhook.<field>:<page id>`.
String webhookRowId(String field, String pageId) => 'webhook.$field:$pageId';

/// The rows of the list page that reload it.
const webhookRetryId = 'webhook.retry';

/// The account's destinations, as soon as they are read.
///
/// The list rebuilds once the account's permissions arrive. A provider no
/// one listens to rebuilds only when read again, so a future read from it
/// alone would wait on the build that was replaced. Listening while the list
/// loads keeps it rebuilding; [patience] bounds a server that does not answer.
Future<NotificationTargetsData> readNotificationTargets(
  Ref ref, {
  Duration patience = const Duration(seconds: 15),
}) async {
  final listening = ref.listen(notificationTargetsProvider, (_, _) {});
  try {
    return await ref.read(notificationTargetsProvider.future).timeout(patience);
  } finally {
    listening.close();
  }
}

/// What a destination page holds before Done saves it: the URL and name
/// typed, and the choices made, over the destination as the server has it.
final class WebhookDraft {
  WebhookDraft.from(NotificationTarget? target)
    : enabled = target?.enabled ?? true,
      delivery = target?.delivery ?? NotificationTarget.deliveryAway,
      events = {...?target?.events};

  String url = '';
  String name = '';
  bool enabled;
  String delivery;
  final Set<String> events;

  /// Whether it holds anything [target] does not.
  bool differsFrom(NotificationTarget? target) =>
      url.trim().isNotEmpty ||
      name.trim().isNotEmpty ||
      enabled != (target?.enabled ?? true) ||
      delivery != (target?.delivery ?? NotificationTarget.deliveryAway) ||
      !const SetEquality<String>().equals(events, {...?target?.events});
}

/// A destination page's message under its title: what went wrong, or what
/// was done (a test sent).
typedef WebhookNotice = ({String text, bool problem});

/// Events a destination holds that the server's catalog no longer lists. The
/// server refuses any update of a destination that keeps one, so they are
/// not shown and every save drops them. Empty while the catalog is unknown.
Set<String> retiredWebhookEvents(
  NotificationTarget? target,
  List<NotificationEvent> catalog,
) {
  if (catalog.isEmpty) return const {};
  final listed = {for (final event in catalog) event.event};
  return {
    for (final id in target?.events ?? const <String>[])
      if (!listed.contains(id)) id,
  };
}

/// The events a destination page lists: the catalog, then any event the
/// destination holds that the catalog does not, so one this app cannot name
/// is shown and kept.
List<({String id, String label, String? description})> webhookEventRows(
  AppLocalizations l10n,
  NotificationTarget? target,
  List<NotificationEvent> catalog,
) {
  final listed = {for (final event in catalog) event.event};
  final retired = retiredWebhookEvents(target, catalog);
  return [
    for (final event in catalog)
      (id: event.event, label: event.label, description: event.description),
    for (final id in target?.events ?? const <String>[])
      if (!listed.contains(id) && !retired.contains(id))
        (id: id, label: id, description: l10n.notificationTargetUnknownEvent),
  ];
}

String _deliveryLabel(AppLocalizations l10n, String delivery) =>
    switch (delivery) {
      NotificationTarget.deliveryAlways =>
        l10n.notificationTargetDeliveryAlways,
      NotificationTarget.deliveryAway => l10n.notificationTargetDeliveryAway,
      final other => other,
    };

/// The list page: each destination, then Add; or why the list could not be
/// read, with a way to try again.
@visibleForTesting
NativeSheetDetailConfig buildWebhookListPage(
  AppLocalizations l10n, {
  required NotificationTargetsData? data,
  required bool loading,
}) {
  final targets = [
    for (final target in data?.targets ?? const <NotificationTarget>[])
      if (target.isWebhook) target,
  ];
  NativeSheetItemConfig problem(String title) => NativeSheetItemConfig(
    id: '$webhookRetryId-problem',
    title: title,
    sfSymbol: 'exclamationmark.triangle',
    kind: NativeSheetItemKind.info,
  );
  final retry = NativeSheetItemConfig(
    id: webhookRetryId,
    title: l10n.retry,
    sfSymbol: 'arrow.clockwise',
    accent: true,
  );
  return NativeSheetDetailConfig(
    id: webhookListPageId,
    title: l10n.notificationTargetsTitle,
    sections: [
      NativeSheetSectionConfig(
        footer: l10n.notificationTargetsDescription,
        items: [
          if (data == null && loading)
            buildNativeLoadingItem(l10n)
          else if (data == null) ...[
            problem(l10n.notificationTargetsLoadFailed),
            retry,
          ] else if (targets.isEmpty)
            NativeSheetItemConfig(
              id: 'webhook-empty',
              title: l10n.notificationTargetsEmpty,
              sfSymbol: 'bell',
              kind: NativeSheetItemKind.info,
            )
          else
            for (final target in targets)
              NativeSheetItemConfig(
                id: '$webhookPagePrefix${Uri.encodeComponent(target.id)}',
                title: target.id,
                subtitle: [
                  [
                    ?target.maskedUrl,
                    _deliveryLabel(l10n, target.delivery),
                  ].join(' · '),
                  [
                    if (target.isDefault == true)
                      l10n.notificationTargetDefaultBadge,
                    target.enabled ? l10n.enabled : l10n.disabled,
                  ].join(' · '),
                ].join('\n'),
                sfSymbol: 'bell.and.waves.left.and.right',
              ),
          if (data != null)
            NativeSheetItemConfig(
              id: webhookNewPageId,
              title: l10n.notificationTargetsAdd,
              sfSymbol: 'plus.circle',
              accent: true,
            ),
        ],
      ),
      if (data?.stale ?? false)
        NativeSheetSectionConfig(
          items: [problem(l10n.notificationTargetsStale), retry],
        ),
    ],
  );
}

/// A destination's page, or the page adding one when [target] is null,
/// drawn from [draft]. Done saves it; [notice] says what happened last.
@visibleForTesting
NativeSheetDetailConfig buildWebhookPage(
  AppLocalizations l10n, {
  required String pageId,
  required NotificationTarget? target,
  required List<NotificationEvent> catalog,
  required WebhookDraft draft,
  WebhookNotice? notice,
}) {
  String row(String field) => webhookRowId(field, pageId);
  final events = webhookEventRows(l10n, target, catalog);
  final dirty = draft.differsFrom(target);
  return NativeSheetDetailConfig(
    id: pageId,
    title: target == null
        ? l10n.notificationTargetNewTitle
        : l10n.notificationTargetEditTitle,
    confirmActionId: row('save'),
    confirmActionLabel: l10n.save,
    discardPrompt: nativeDiscardPrompt(l10n),
    sections: [
      if (notice != null)
        NativeSheetSectionConfig(
          items: [
            NativeSheetItemConfig(
              id: row('notice'),
              title: notice.text,
              sfSymbol: notice.problem
                  ? 'exclamationmark.triangle'
                  : 'checkmark.circle',
              kind: NativeSheetItemKind.info,
            ),
          ],
        ),
      if (target == null)
        NativeSheetSectionConfig(
          footer: l10n.notificationTargetNameHelper,
          items: [
            NativeSheetItemConfig(
              id: row('url'),
              title: l10n.notificationTargetUrlLabel,
              sfSymbol: 'link',
              kind: NativeSheetItemKind.textField,
              value: draft.url,
              placeholder: l10n.notificationTargetUrlHint,
            ),
            NativeSheetItemConfig(
              id: row('name'),
              title: l10n.notificationTargetNameLabel,
              sfSymbol: 'tag',
              kind: NativeSheetItemKind.textField,
              value: draft.name,
              placeholder: l10n.notificationTargetNameHint,
            ),
          ],
        )
      else
        NativeSheetSectionConfig(
          items: [
            NativeSheetItemConfig(
              id: row('id'),
              title: l10n.notificationTargetIdLabel,
              subtitle: target.id,
              sfSymbol: 'tag',
              kind: NativeSheetItemKind.info,
            ),
            NativeSheetItemConfig(
              id: row('url'),
              title: l10n.notificationTargetUrlLabel,
              subtitle: target.maskedUrl,
              sfSymbol: 'link',
              kind: NativeSheetItemKind.textField,
              value: draft.url,
              placeholder: l10n.notificationTargetUrlKeepHint,
            ),
          ],
        ),
      NativeSheetSectionConfig(
        footer: switch (draft.delivery) {
          NotificationTarget.deliveryAway =>
            l10n.notificationTargetDeliveryAwayDescription,
          NotificationTarget.deliveryAlways =>
            l10n.notificationTargetDeliveryAlwaysDescription,
          _ => null,
        },
        items: [
          NativeSheetItemConfig(
            id: row('enabled'),
            title: l10n.notificationTargetEnabledTitle,
            sfSymbol: 'bell',
            kind: NativeSheetItemKind.toggle,
            value: draft.enabled,
          ),
          NativeSheetItemConfig(
            id: row('delivery'),
            title: l10n.notificationTargetDeliveryLabel,
            sfSymbol: 'paperplane',
            kind: NativeSheetItemKind.segment,
            value: draft.delivery,
            options: [
              NativeSheetOptionConfig(
                id: NotificationTarget.deliveryAway,
                label: l10n.notificationTargetDeliveryAway,
              ),
              NativeSheetOptionConfig(
                id: NotificationTarget.deliveryAlways,
                label: l10n.notificationTargetDeliveryAlways,
              ),
            ],
          ),
        ],
      ),
      NativeSheetSectionConfig(
        title: l10n.notificationTargetEventsLabel,
        items: [
          if (events.isEmpty)
            NativeSheetItemConfig(
              id: row('events-none'),
              title: l10n.notificationTargetEventsUnavailable,
              sfSymbol: 'info.circle',
              kind: NativeSheetItemKind.info,
            )
          else
            for (final event in events)
              NativeSheetItemConfig(
                id: row('event.${event.id}'),
                title: event.label,
                subtitle: event.description,
                sfSymbol: 'bell.badge',
                kind: NativeSheetItemKind.toggle,
                value: draft.events.contains(event.id),
              ),
        ],
      ),
      if (target != null) ...[
        NativeSheetSectionConfig(
          items: [
            if (target.isDefault != true)
              NativeSheetItemConfig(
                id: row('default'),
                title: l10n.notificationTargetMakeDefault,
                subtitle: dirty
                    ? l10n.notificationTargetMakeDefaultNeedsSave
                    : null,
                sfSymbol: 'checkmark.circle',
              ),
            NativeSheetItemConfig(
              id: row('test'),
              title: l10n.notificationTargetTest,
              subtitle: dirty ? l10n.notificationTargetTestNeedsSave : null,
              sfSymbol: 'paperplane',
            ),
          ],
        ),
        NativeSheetSectionConfig(
          items: [
            NativeSheetItemConfig(
              id: row('delete'),
              title: l10n.notificationTargetDelete,
              sfSymbol: 'trash',
              destructive: true,
              confirmMessage: l10n.notificationTargetDeleteConfirm(target.id),
            ),
          ],
        ),
      ],
    ],
  );
}

/// The webhook destination pages: the list, each destination's page, and
/// the page adding one. Changes wait on each page as a draft until Done,
/// and every action goes to the account the list was opened for.
class WebhookSettingsPages implements SettingsPageModule {
  WebhookSettingsPages(this._ref);

  final Ref _ref;
  NotificationTargetsOwner? _owner;
  final Map<String, WebhookDraft> _drafts = {};
  final Map<String, WebhookNotice> _notices = {};

  SettingsSurface get _surface => _ref.read(settingsSurfaceProvider);
  NotificationTargets get _targets =>
      _ref.read(notificationTargetsProvider.notifier);

  NotificationTargetsData? get _data =>
      _ref.read(notificationTargetsProvider).asData?.value;

  NotificationTarget? _target(String pageId) {
    if (!pageId.startsWith(webhookPagePrefix)) return null;
    final id = Uri.decodeComponent(pageId.substring(webhookPagePrefix.length));
    return _data?.targets.where((target) => target.id == id).firstOrNull;
  }

  @override
  bool ownsPage(String detailId) =>
      detailId == webhookListPageId ||
      detailId == webhookNewPageId ||
      detailId.startsWith(webhookPagePrefix);

  @override
  Future<void> hydrate(String detailId, AppLocalizations l10n) async {
    if (detailId == webhookListPageId) {
      await _hydrateList(l10n);
      return;
    }
    final target = _target(detailId);
    final draft = _drafts.putIfAbsent(
      detailId,
      () => WebhookDraft.from(target),
    );
    await _applyPage(l10n, detailId, target: target, draft: draft);
  }

  /// The list, as the account has it now. Any destination page opened from
  /// an earlier list starts over.
  Future<void> _hydrateList(AppLocalizations l10n) async {
    _owner = null;
    _drafts.clear();
    _notices.clear();
    // Whether the account may keep destinations rests on its permissions
    // and the server's flag, read before the row was offered; a little
    // patience covers a page opened straight from a link.
    try {
      await Future.wait<Object?>([
        _ref.read(userPermissionsProvider.future),
        _ref.read(backendConfigProvider.future),
      ]).timeout(const Duration(seconds: 2));
    } catch (_) {
      // Unread, the account is not offered destinations.
    }
    // Opened from a row that went stale (Advanced turned off, the account
    // lost access): say so rather than list anything.
    if (!_ref.read(appSettingsProvider).advancedFeaturesEnabled ||
        !_ref.read(notificationTargetsAvailableProvider)) {
      await _surface.applyDetail(
        NativeSheetDetailConfig(
          id: webhookListPageId,
          title: l10n.notificationTargetsTitle,
          items: [
            NativeSheetItemConfig(
              id: '$webhookRetryId-unavailable',
              title: l10n.nativeSheetOptionUnavailable,
              sfSymbol: 'exclamationmark.triangle',
              kind: NativeSheetItemKind.info,
            ),
          ],
        ),
      );
      return;
    }
    await _surface.applyDetail(
      buildWebhookListPage(l10n, data: _data, loading: true),
    );
    NotificationTargetsData? data;
    try {
      data = await readNotificationTargets(_ref);
      // The account the list was read for is the one its pages act for.
      _owner = _targets.captureOwner();
    } catch (error, stackTrace) {
      DebugLogger.error(
        'webhook-list-load-failed',
        scope: 'settings/webhooks',
        error: error,
        stackTrace: stackTrace,
      );
    }
    await _surface.applyDetail(
      buildWebhookListPage(l10n, data: data, loading: false),
      detailSheets: [
        buildNativeLoadingDetail(
          l10n: l10n,
          id: webhookNewPageId,
          title: l10n.notificationTargetNewTitle,
        ),
        for (final target in data?.targets ?? const <NotificationTarget>[])
          buildNativeLoadingDetail(
            l10n: l10n,
            id: '$webhookPagePrefix${Uri.encodeComponent(target.id)}',
            title: l10n.notificationTargetEditTitle,
          ),
      ],
    );
  }

  Future<void> _applyPage(
    AppLocalizations l10n,
    String pageId, {
    required NotificationTarget? target,
    required WebhookDraft draft,
  }) => _surface.applyDetail(
    buildWebhookPage(
      l10n,
      pageId: pageId,
      target: target,
      catalog: _data?.events ?? const [],
      draft: draft,
      notice: _notices[pageId],
    ),
  );

  @override
  Future<bool> handleChange(
    String id,
    Object? value,
    AppLocalizations l10n,
  ) async {
    if (id == webhookRetryId) {
      final owner = _targets.captureOwner();
      if (owner != null) await _targets.refresh(owner: owner);
      await _hydrateList(l10n);
      return true;
    }
    if (!id.startsWith('webhook.')) return false;
    final separator = id.indexOf(':');
    if (separator < 0) return true;
    final field = id.substring('webhook.'.length, separator);
    final pageId = id.substring(separator + 1);
    final target = _target(pageId);
    // A page holds a draft from the moment it appears until it closes. A row
    // of a page already closed (a second Done on its way) does nothing.
    final draft = _drafts[pageId];
    if (draft == null) return true;
    switch (field) {
      case 'url' when value is String:
        draft.url = value;
      case 'name' when value is String:
        draft.name = value;
      case 'enabled' when value is bool:
        draft.enabled = value;
      case 'delivery' when value is String:
        draft.delivery = value;
        // The note under the choice says what it does.
        await _applyPage(l10n, pageId, target: target, draft: draft);
      case final event when event.startsWith('event.') && value is bool:
        final eventId = event.substring('event.'.length);
        value ? draft.events.add(eventId) : draft.events.remove(eventId);
      case 'save':
        await _save(l10n, pageId, target, draft);
      case 'default' when target != null:
        if (draft.differsFrom(target)) {
          await _say(
            l10n,
            pageId,
            target,
            draft,
            l10n.notificationTargetMakeDefaultNeedsSave,
          );
          return true;
        }
        if (await _run(l10n, pageId, target, draft, (owner) async {
          await _targets.makeDefault(target.id, owner: owner);
        })) {
          await _leave(l10n, pageId);
        }
      case 'test' when target != null:
        // A test goes to the destination as the server has it.
        if (draft.differsFrom(target)) {
          await _say(
            l10n,
            pageId,
            target,
            draft,
            l10n.notificationTargetTestNeedsSave,
          );
          return true;
        }
        if (await _run(
          l10n,
          pageId,
          target,
          draft,
          (owner) => _targets.sendTest(target.id, owner: owner),
          fallback: l10n.notificationTargetTestFailed,
        )) {
          await _say(
            l10n,
            pageId,
            target,
            draft,
            l10n.notificationTargetTestSent,
            problem: false,
          );
        }
      case 'delete' when target != null:
        if (await _run(
          l10n,
          pageId,
          target,
          draft,
          (owner) => _targets.remove(target.id, owner: owner),
        )) {
          await _leave(l10n, pageId);
        }
    }
    return true;
  }

  Future<void> _save(
    AppLocalizations l10n,
    String pageId,
    NotificationTarget? target,
    WebhookDraft draft,
  ) async {
    final url = draft.url.trim();
    if (target == null && url.isEmpty) {
      await _say(
        l10n,
        pageId,
        target,
        draft,
        l10n.notificationTargetUrlRequired,
      );
      return;
    }
    final catalog = _data?.events ?? const <NotificationEvent>[];
    final events = [
      for (final row in webhookEventRows(l10n, target, catalog))
        if (draft.events.contains(row.id)) row.id,
    ];
    final saved = await _run(l10n, pageId, target, draft, (owner) async {
      if (target == null) {
        await _targets.create(
          url: url,
          id: draft.name,
          enabled: draft.enabled,
          events: events,
          delivery: draft.delivery,
          owner: owner,
        );
        return;
      }
      // Only what changed goes out, so an edit that leaves the destination
      // alone cannot touch the URL the server holds. The events go out too
      // when the destination keeps one the server no longer lists: the
      // server checks the stored ones, and refuses the whole update.
      await _targets.updateTarget(
        target.id,
        enabled: draft.enabled != target.enabled ? draft.enabled : null,
        events:
            retiredWebhookEvents(target, catalog).isEmpty &&
                const SetEquality<String>().equals(draft.events, {
                  ...target.events,
                })
            ? null
            : events,
        delivery: draft.delivery != target.delivery ? draft.delivery : null,
        replacementUrl: url.isEmpty ? null : url,
        owner: owner,
      );
    });
    if (saved) await _leave(l10n, pageId);
  }

  /// Runs [action] for the account the list was opened for. When it is
  /// refused, the page says why and keeps the draft. Returns whether it ran.
  Future<bool> _run(
    AppLocalizations l10n,
    String pageId,
    NotificationTarget? target,
    WebhookDraft draft,
    Future<void> Function(NotificationTargetsOwner owner) action, {
    String? fallback,
  }) async {
    final owner = _owner;
    if (owner == null) {
      await _say(
        l10n,
        pageId,
        target,
        draft,
        l10n.notificationTargetsAccountChanged,
      );
      return false;
    }
    try {
      await action(owner);
      return true;
    } on NotificationTargetsOwnerChangedException {
      await _say(
        l10n,
        pageId,
        target,
        draft,
        l10n.notificationTargetsAccountChanged,
      );
    } on NotificationTargetsUnavailableException {
      await _say(
        l10n,
        pageId,
        target,
        draft,
        l10n.notificationTargetsUnavailable,
      );
    } catch (error) {
      await _say(
        l10n,
        pageId,
        target,
        draft,
        notificationTargetErrorDetail(error) ?? fallback ?? l10n.errorMessage,
      );
    }
    return false;
  }

  Future<void> _say(
    AppLocalizations l10n,
    String pageId,
    NotificationTarget? target,
    WebhookDraft draft,
    String text, {
    bool problem = true,
  }) {
    _notices[pageId] = (text: text, problem: problem);
    return _applyPage(l10n, pageId, target: target, draft: draft);
  }

  /// Back to the list, which reads the destinations again.
  Future<void> _leave(AppLocalizations l10n, String pageId) async {
    _drafts.remove(pageId);
    _notices.remove(pageId);
    await _surface.closeDetail(pageId);
    await _hydrateList(l10n);
  }
}
