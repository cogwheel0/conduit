import 'dart:collection';

import 'package:conduit_core/features/notifications/providers/notification_target_providers.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:riverpod/riverpod.dart';

import 'account_scope.dart';
import 'server_rules.dart';
import 'settled.dart';

/// `webhooks.*`: the account's webhook destinations on its Open WebUI server,
/// through core's `NotificationTargets`, as the phone's Notifications page
/// manages them.
///
/// The account a list was read for is captured when the list is read and
/// handed to the window as an opaque `owner`; every change sends it back.
/// Once another account is signed in, the change is refused before anything
/// is sent, and the window keeps what the user typed.
final class WebhooksService {
  WebhooksService(this._container);

  final ProviderContainer _container;

  /// Owners handed out, newest last; the oldest go first. A token names an
  /// account's session: while it is still the signed-in one, every read
  /// answers with the same token, holding that session's newest owner, so
  /// list reads from other windows never push out the token an open editor
  /// will save with. Only tokens of accounts no longer in charge pile up.
  final LinkedHashMap<String, NotificationTargetsOwner> _owners =
      LinkedHashMap<String, NotificationTargetsOwner>();
  int _nextOwner = 0;
  static const int _maxOwners = 16;

  NotificationTargets get _targets =>
      _container.read(notificationTargetsProvider.notifier);

  /// Whether the account may manage destinations, once the server's config
  /// and the account's permissions have loaded ([readServerRule], the one
  /// rule every server feature reads through).
  Future<bool> _available() async {
    if (_container.read(apiServiceProvider) == null) return false;
    return readServerRule(
      _container,
      () => _container.read(notificationTargetsAvailableProvider),
      stale: (available) => !available,
    );
  }

  String _remember(NotificationTargetsOwner owner) {
    for (final entry in _owners.entries) {
      if (identical(entry.value, owner)) return entry.key;
    }
    // [owner] was just captured, so it is the signed-in account: a token
    // still current names that same account's session.
    for (final entry in _owners.entries) {
      if (_targets.isCurrentOwner(entry.value)) {
        _owners[entry.key] = owner;
        return entry.key;
      }
    }
    final token = 'w${++_nextOwner}';
    _owners[token] = owner;
    while (_owners.length > _maxOwners) {
      _owners.remove(_owners.keys.first);
    }
    return token;
  }

  NotificationTargetsOwner _owner(String token) {
    final owner = _owners[token];
    if (owner == null || !_targets.isCurrentOwner(owner)) {
      throw const RpcError(
        code: ConduitErrorCodes.conflict,
        debugMessage: 'another account is signed in now',
        args: <String, String>{'reason': 'accountChanged'},
      );
    }
    return owner;
  }

  static WebhookList _list(
    NotificationTargetsData data,
    String owner, {
    bool stale = false,
  }) => WebhookList(
    available: true,
    owner: owner,
    items: <WebhookDto>[
      for (final target in data.targets)
        if (target.isWebhook)
          WebhookDto(
            id: target.id,
            enabled: target.enabled,
            isDefault: target.isDefault == true,
            events: List<String>.of(target.events),
            delivery: target.delivery,
            maskedUrl: target.maskedUrl,
          ),
    ],
    events: <WebhookEventDto>[
      for (final event in data.events)
        WebhookEventDto(
          event: event.event,
          label: event.label,
          description: event.description,
        ),
    ],
    stale: stale || data.stale,
  );

  /// The destinations, read again from the server.
  ///
  /// Bound to the account it was asked under ([AccountScope]): once another
  /// account is in charge after any wait, it is refused rather than answered
  /// with the next account's destinations under this one's owner.
  Future<WebhookList> list() async {
    final account = AccountScope.capture(_container);
    if (!await _available()) {
      account.require('the webhook list is answered');
      return const WebhookList();
    }
    account.require('the webhook owner is captured');
    final owner = _targets.captureOwner();
    if (owner == null) return const WebhookList();
    final token = _remember(owner);
    final NotificationTargetsData data;
    try {
      // Every list is read from the server again, the user's own refresh
      // (core never retries a load behind their back): after a failed load
      // too, which would otherwise be answered until a restart. Only a
      // load still running is waited for instead.
      if (!_container.read(notificationTargetsProvider).isLoading) {
        await _targets.refresh(owner: owner);
      }
      data = await readSettled(_container, notificationTargetsProvider.future);
    } on Object {
      account.require('the webhook list is answered');
      return WebhookList(available: true, owner: token, failed: true);
    }
    account.require('the webhook list is answered');
    return _list(data, token);
  }

  /// The list as the notifier holds it after a change (it reads it back).
  WebhookList _current(String token) {
    final data = _container.read(notificationTargetsProvider).asData?.value;
    if (data == null) {
      return WebhookList(available: true, owner: token, stale: true);
    }
    return _list(data, token);
  }

  Future<WebhookList> _run(
    String token,
    Future<void> Function(NotificationTargetsOwner owner) action,
  ) async {
    final owner = _owner(token);
    final account = AccountScope.capture(_container);
    try {
      await action(owner);
    } on NotificationTargetsOwnerChangedException {
      throw const RpcError(
        code: ConduitErrorCodes.conflict,
        debugMessage: 'another account is signed in now',
        args: <String, String>{'reason': 'accountChanged'},
      );
    } on NotificationTargetsUnavailableException {
      throw const RpcError(
        code: ConduitErrorCodes.unsupported,
        debugMessage: 'webhook destinations are not available',
        args: <String, String>{'reason': 'unavailable'},
      );
    } on RpcError {
      rethrow;
    } on Object catch (error) {
      // The server's own words ("Webhook URL is required"), never the URL.
      final detail = notificationTargetErrorDetail(error);
      throw RpcError(
        code: ConduitErrorCodes.serverError,
        debugMessage: 'the server refused the change',
        args: <String, String>{'detail': ?detail},
      );
    }
    // The change went through for this owner, but another account is in
    // charge now: what the notifier holds is the next account's list, so it
    // is not shown under this owner (the window reads its own again).
    if (!account.isCurrent) {
      return WebhookList(available: true, owner: token, stale: true);
    }
    return _current(token);
  }

  Future<WebhookList> create(WebhookCreate params) {
    final url = params.url.trim();
    if (url.isEmpty) {
      throw const RpcError(
        code: ConduitErrorCodes.invalidParams,
        debugMessage: 'a destination needs a URL',
        args: <String, String>{'reason': 'urlRequired'},
      );
    }
    return _run(
      params.owner,
      (owner) => _targets.create(
        url: url,
        id: params.name.trim().isEmpty ? null : params.name.trim(),
        enabled: params.enabled,
        events: params.events,
        delivery: params.delivery,
        owner: owner,
      ),
    );
  }

  Future<WebhookList> update(WebhookUpdate params) => _run(
    params.owner,
    (owner) => _targets.updateTarget(
      params.id,
      enabled: params.enabled,
      events: params.events,
      delivery: params.delivery,
      replacementUrl: switch (params.url?.trim()) {
        final url? when url.isNotEmpty => url,
        _ => null,
      },
      owner: owner,
    ),
  );

  Future<WebhookList> makeDefault(WebhookRef params) => _run(
    params.owner,
    (owner) => _targets.makeDefault(params.id, owner: owner),
  );

  /// One real test notification: the server contacts the destination.
  Future<WebhookList> test(WebhookRef params) =>
      _run(params.owner, (owner) => _targets.sendTest(params.id, owner: owner));

  Future<WebhookList> delete(WebhookRef params) =>
      _run(params.owner, (owner) => _targets.remove(params.id, owner: owner));
}
