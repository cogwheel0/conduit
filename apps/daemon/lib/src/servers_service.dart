import 'dart:async';

import 'package:conduit_core/auth/auth_state_manager.dart';
import 'package:conduit_core/auth/openwebui_server_address.dart' as core;
import 'package:conduit_core/auth/proxy_renewal.dart';
import 'package:conduit_core/auth/proxy_session.dart'
    show mergeCapturedProxyCookiesIntoHeaders;
import 'package:conduit_core/models/openwebui_registry.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/providers/openwebui_accounts_controller.dart'
    show addressChangeReplyGuardProvider, addressChangeStopRepliesProvider;
import 'package:conduit_core/providers/openwebui_route_resolver.dart'
    show OpenWebUiRouteStatus, openWebUiRouteResolverProvider;
import 'package:conduit_core/models/backend_config.dart';
import 'package:conduit_core/services/api_service.dart'
    show ApiService, HealthCheckResult;
import 'package:conduit_core/services/optimized_storage_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:conduit_core/utils/debug_logger.dart';
import 'package:conduit_core/utils/server_version_compat.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:riverpod/riverpod.dart';
import 'package:uuid/uuid.dart';

import 'account_scope.dart';
import 'event_bus.dart';
import 'settled.dart';
import 'voice_service.dart';

/// Implements `servers.*` over the core: editing the server an account is
/// on, a saved server's addresses (`servers.addresses.*`, over the core's
/// `openwebui_server_address.dart`, which mobile's Settings pages call too),
/// and asking how the active server is doing.
///
/// Adding, removing and switching accounts -- each a saved server entry --
/// is `accounts.*`, over the core's accounts controller, which keeps the
/// account registry and its data purge in step.
///
/// The one rule this file exists to enforce is that nothing secret leaves.
/// [summarize] and [_address] are the only paths from a saved connection to
/// the wire, and they name each field they copy rather than spreading the
/// object, so adding a secret to `ServerConfig` or an endpoint cannot
/// silently start publishing it. An address's header values, client key and
/// key password stay here: the window sends replacements, never reads them.
final class ServersService {
  ServersService(this._container, {EventBus? events}) : _events = events {
    _routeWatch = _container.listen<(String?, String?)>(
      openWebUiRouteResolverProvider.select(
        (route) => (route.serverId, route.endpointId),
      ),
      // A server's address in use moved to another of its addresses (an
      // edit, or one stopped answering). Not the route first resolving or
      // going with the account: nothing shown of a server changes then.
      (previous, next) {
        final (from, to) = (previous?.$1, next.$1);
        if (from != null && to != null && previous != next) _changed(to);
      },
    );
  }

  final ProviderContainer _container;
  final EventBus? _events;
  late final ProviderSubscription<(String?, String?)> _routeWatch;

  /// The daemon's own running answers, which the core's guard cannot see:
  /// they stream in chat scopes, not in the root's open chat. Set once the
  /// turns service exists.
  AddressReplies? replies;

  /// Addresses checked and not yet saved, by check id.
  final Map<String, _CheckedAddress> _checked = <String, _CheckedAddress>{};

  /// How long a checked address waits for its save.
  static const Duration checkLifetime = Duration(minutes: 15);

  static const Uuid _uuid = Uuid();

  OptimizedStorageService get _storage =>
      _container.read(optimizedStorageServiceProvider);

  void dispose() => _routeWatch.close();

  void _changed(String? serverId) => _events?.emit(
    ConduitEventSpecs.serversChanged,
    ServersChanged(serverId: serverId),
  );

  /// Edits in place. A null secret means "leave alone", which is what lets
  /// the setup form save a rename without ever having been given the key.
  ///
  /// [ServerDraft.id] may name a saved server rather than an account: then
  /// only its name changes, whatever else the draft says.
  Future<ServerSummary> update(ServerDraft draft) async {
    final id = draft.id;
    if (id == null) {
      throw const RpcError(
        code: ConduitErrorCodes.invalidParams,
        debugMessage: 'servers.update needs an id',
      );
    }
    final registry = await _storage.getOpenWebUiRegistryStrict();
    if (registry.server(id) != null && registry.account(id) == null) {
      return _rename(id, validateName(draft.name));
    }
    final name = validateName(draft.name);
    final url = validateUrl(draft.url);
    final hadSession = await _storage.getAuthTokenStrict() != null;
    final activeBefore = await _activeConfig();
    // Onto the connection as stored when the write runs, not as read before
    // it: what another window saved meanwhile, and the draft leaves alone,
    // stays.
    final updated = await _storage.editServerConfig(
      id,
      (existing) => existing.copyWith(
        name: name,
        url: url,
        allowSelfSignedCertificates: draft.allowSelfSignedCertificates,
        customHeaders: draft.customHeaders ?? existing.customHeaders,
        mtlsCertificateChainPem: draft.clearMutualTls
            ? null
            : (draft.mtlsCertificateChainPem ??
                  existing.mtlsCertificateChainPem),
        mtlsCertificateLabel: draft.clearMutualTls
            ? null
            : (draft.mtlsCertificateLabel ?? existing.mtlsCertificateLabel),
        mtlsPrivateKeyPem: draft.clearMutualTls
            ? null
            : (draft.mtlsPrivateKeyPem ?? existing.mtlsPrivateKeyPem),
        mtlsPrivateKeyLabel: draft.clearMutualTls
            ? null
            : (draft.mtlsPrivateKeyLabel ?? existing.mtlsPrivateKeyLabel),
        mtlsPrivateKeyPassword: draft.clearMutualTls
            ? null
            : (draft.mtlsPrivateKeyPassword ?? existing.mtlsPrivateKeyPassword),
      ),
    );
    if (updated == null) throw _notFound(id);
    await _endSessionIfMoved(hadSession: hadSession);
    await _publishSaved(activeBefore);
    _changed(registry.account(id)?.serverId);
    return summarize(
      updated,
      hasStoredSession: (await _storage.accountIdsWithSession()).contains(id),
    );
  }

  /// Ends the live session when the save moved the active account's server
  /// to another address or client identity.
  ///
  /// Storage judges that, and drops the saved token when it does: the
  /// session belongs to the old address. That holds for an edit to another
  /// account too, as accounts on one server share its address. The auth
  /// manager still holds the session, though, and the client rebuilt for the
  /// new address would send it there. So it is ended here, before
  /// [_republishServerConfigs] rebuilds the client; the account then needs a
  /// sign-in on the new address.
  Future<void> _endSessionIfMoved({required bool hadSession}) async {
    if (!hadSession) return;
    if (await _storage.getAuthTokenStrict() != null) return;
    await _container
        .read(authStateManagerProvider.notifier)
        .onTokenInvalidated();
  }

  /// Renames the saved server [serverId] in storage as it is stored then:
  /// its addresses, and the cookies its accounts keep there, as they are.
  /// The name is not a connection, so the live client -- and every reply it
  /// carries -- stays: only the accounts list, which shows the name, is
  /// read again, whichever account is active by then (another window may
  /// have switched meanwhile; its client is not this rename's to rebuild).
  Future<ServerSummary> _rename(String serverId, String name) async {
    if (!await _storage.renameServer(serverId, name)) throw _notFound(serverId);
    _container.invalidate(openWebUiAccountsProvider);
    final registry = await _storage.getOpenWebUiRegistryStrict();
    final accounts = {
      for (final account in registry.accountsOn(serverId)) account.id,
    };
    final renamed = (await _storage.getServerConfigsStrict())
        .where((config) => accounts.contains(config.id))
        .firstOrNull;
    if (renamed == null) throw _notFound(serverId);
    _changed(serverId);
    return summarize(
      renamed,
      hasStoredSession: (await _storage.accountIdsWithSession()).contains(
        renamed.id,
      ),
    );
  }

  /// The active account's connection as stored now, if one is active.
  Future<ServerConfig?> _activeConfig() async {
    final id = await _storage.getEffectiveActiveServerId();
    if (id == null) return null;
    return (await _storage.getServerConfigsStrict())
        .where((config) => config.id == id)
        .firstOrNull;
  }

  /// Shows a save to the providers that cache storage. The live client is
  /// rebuilt -- which ends every reply it carries -- only when the active
  /// account's connection changed: its address, headers, certificates or
  /// cookies, or which account is active, or none was before
  /// ([_republishServerConfigs]). A name, or an edit to another server,
  /// re-reads the accounts list alone.
  Future<void> _publishSaved(ServerConfig? activeBefore) async {
    final activeAfter = await _activeConfig();
    if (activeBefore != null &&
        activeAfter != null &&
        activeAfter.sameConnectionAs(activeBefore)) {
      _container.invalidate(openWebUiAccountsProvider);
      return;
    }
    _republishServerConfigs();
  }

  // ---------------------------------------------------------------------
  // servers.addresses.*
  // ---------------------------------------------------------------------

  /// [serverId]'s addresses in the order they are tried.
  Future<ServerAddresses> addresses(ServerRef request) async {
    final registry = await _storage.getOpenWebUiRegistryStrict();
    final server = registry.server(request.serverId);
    if (server == null) throw _notFound(request.serverId);
    return _addressesOf(server, registry);
  }

  ServerAddresses _addressesOf(
    OpenWebUiServer server,
    OpenWebUiRegistry registry,
  ) {
    final inUse = _addressInUse(server.id, registry);
    return ServerAddresses(
      serverId: server.id,
      name: server.name,
      addresses: [
        for (final endpoint in server.endpoints)
          _address(endpoint, inUse: endpoint.id == inUse),
      ],
      removable: core.serverAddressesRemovable(server),
    );
  }

  /// The address of [serverId] the active account reaches it through: the
  /// route the resolver settled on, else the one selected for the server.
  String? _addressInUse(String serverId, OpenWebUiRegistry registry) {
    final OpenWebUiRouteStatus route = _container.read(
      openWebUiRouteResolverProvider,
    );
    if (route.serverId == serverId && route.endpointId != null) {
      return route.endpointId;
    }
    if (route.serverId != null) return null;
    final active = _container.read(activeServerProvider).asData?.value;
    if (active == null) return null;
    final account = registry.account(active.id);
    if (account == null || account.serverId != serverId) return null;
    return registry
        .server(serverId)
        ?.routeForConnection(
          active,
          selectedEndpointId: _storage.endpointSelection[serverId],
        )
        .id;
  }

  /// The only endpoint -> wire conversion: names, labels and flags, never a
  /// header value, a key or its password.
  static ServerAddressDto _address(
    OpenWebUiEndpoint endpoint, {
    required bool inUse,
  }) => ServerAddressDto(
    id: endpoint.id,
    url: endpoint.url,
    label: endpoint.label,
    inUse: inUse,
    allowSelfSignedCertificates: endpoint.allowSelfSignedCertificates,
    customHeaderNames: [
      for (final name in endpoint.customHeaders.keys)
        if (!isCapturedSessionHeader(name)) name,
    ],
    hasMutualTlsCredentials:
        (endpoint.mtlsCertificateChainPem?.isNotEmpty ?? false) &&
        (endpoint.mtlsPrivateKeyPem?.isNotEmpty ?? false),
    mtlsCertificateLabel: endpoint.mtlsCertificateLabel,
    mtlsPrivateKeyLabel: endpoint.mtlsPrivateKeyLabel,
    hasPrivateKeyPassword: endpoint.mtlsPrivateKeyPassword?.isNotEmpty ?? false,
  );

  /// Checks an address of a saved server ([core.checkServerAddressDraft]):
  /// what the window's form holds, with the values it was never given (a
  /// saved header's value, the client key) taken from the address it edits.
  /// Each header is checked as the phone's Add Header page checks it.
  Future<ServerAddressCheckResult> check(
    ServerAddressCheckRequest request,
  ) async {
    _forgetStale();
    final registry = await _storage.getOpenWebUiRegistryStrict();
    final server = registry.server(request.serverId);
    if (server == null) {
      return _unusable(core.ServerAddressProblem.serverMissing);
    }
    final endpointId = request.endpointId;
    final saved = endpointId == null ? null : server.endpoint(endpointId);
    if (endpointId != null && saved == null) {
      return _unusable(core.ServerAddressProblem.serverMissing);
    }
    final form = request.form;
    String? formatted;
    try {
      formatted = core.formatServerAddressInput(form.url);
    } on Object {
      formatted = null; // The core's check names what is wrong with it.
    }
    // As [validateUrl]: a server's credentials go in the sign-in, never in
    // its address, which is stored and shown. Read as typed and as it is
    // completed: `user:pass@host:8080` gains its scheme only then.
    bool carriesUser(String? url) =>
        url != null && (Uri.tryParse(url)?.userInfo.isNotEmpty ?? false);
    if (carriesUser(form.url.trim()) || carriesUser(formatted)) {
      return _unusable(core.ServerAddressProblem.invalidAddress);
    }
    // Typed without a scheme, the address is what its server redirects it
    // to: resolved first (the probe carries no header), so a saved address
    // reached again by its host alone keeps its values.
    if (formatted != null && !core.hasExplicitHttpScheme(form.url)) {
      formatted = await core.upgradeSchemeLessServerUrl(formatted);
    }
    final draft = _draftFor(saved, resolvedUrl: formatted);
    draft
      // The one resolved address: what was probed, what the saved values
      // were judged for, and what is checked and saved. Never the raw form,
      // which the core would resolve again (a second probe can answer
      // otherwise, and send those values over plain http).
      ..url = formatted ?? form.url
      ..label = form.label
      ..allowSelfSigned = form.allowSelfSignedCertificates;

    // Headers in the form's order, each against those before it.
    final kept = draft.headers;
    final headers = <String, String>{};
    for (final header in form.headers) {
      final name = header.name.trim();
      // Header names are case-insensitive, as duplicates are judged.
      final keptValue = header.value == null
          ? kept.entries
                .where((e) => e.key.toLowerCase() == name.toLowerCase())
                .firstOrNull
                ?.value
          : null;
      // A typed value is trimmed; a kept one stays as saved, byte for byte,
      // so a label edit changes nothing the connection is compared by.
      final value = header.value?.trim() ?? keptValue ?? '';
      // A value kept as saved is not typed input: only its name and place
      // are checked, so a label edit is never refused over it.
      final problem = keptValue != null
          ? core.validateServerAddressHeaderName(name) ??
                (headers.keys.any(
                      (added) => added.toLowerCase() == name.toLowerCase(),
                    )
                    ? core.ServerAddressProblem.headerAlreadyAdded
                    : headers.length >= core.maxServerAddressHeaders
                    ? core.ServerAddressProblem.tooManyHeaders
                    : null)
          : core.validateServerAddressHeader(headers, name: name, value: value);
      if (problem != null) return _unusable(problem, headerName: name);
      headers[name] = value;
    }
    draft.headers
      ..clear()
      ..addAll(headers);

    if (form.clearMutualTls) draft.clearMutualTls();
    final certificate = form.mtlsCertificateChainPem;
    if (certificate != null) {
      final problem = core.validatePickedPem(certificate, isPrivateKey: false);
      if (problem != null) return _unusable(problem);
      draft
        ..certificatePem = certificate
        ..certificateLabel = form.mtlsCertificateLabel;
    }
    final key = form.mtlsPrivateKeyPem;
    if (key != null) {
      final problem = core.validatePickedPem(key, isPrivateKey: true);
      if (problem != null) return _unusable(problem);
      draft
        ..privateKeyPem = key
        ..privateKeyLabel = form.mtlsPrivateKeyLabel;
    }
    final password = form.mtlsPrivateKeyPassword;
    if (password != null) draft.privateKeyPassword = password;

    final found = await core.checkServerAddressDraft(
      _container,
      serverId: server.id,
      endpointId: endpointId,
      draft: draft,
    );
    switch (found) {
      case core.ServerAddressUnusable(:final failure):
        return _unusableFor(failure);
      case core.ServerAddressAnswered(:final config, :final sessionRevision):
        return _keep(
          server.id,
          saved,
          draft.label,
          config,
          sessionRevision,
          behindProxy: false,
        );
      case core.ServerAddressBehindProxy(:final config, :final sessionRevision):
        return _keep(
          server.id,
          saved,
          draft.label,
          config,
          sessionRevision,
          behindProxy: true,
        );
    }
  }

  /// What an edit of [saved] (none for a new address) starts from: the
  /// saved address with its secrets -- header values, client certificate,
  /// key and key password -- only while it stays on the origin they were
  /// saved for ([resolvedUrl]). Moved to another origin it starts empty:
  /// none of them goes to a host the user did not give them to, and the
  /// form supplies each again. (Its captured cookies follow the same rule
  /// in the core, `keptAddressSessionHeaders`.)
  static core.ServerAddressDraft _draftFor(
    OpenWebUiEndpoint? saved, {
    required String? resolvedUrl,
  }) {
    final sameOrigin =
        saved != null &&
        resolvedUrl != null &&
        openWebUiServerIdentityUrl(resolvedUrl) ==
            openWebUiServerIdentityUrl(saved.url);
    return sameOrigin
        ? core.ServerAddressDraft.of(saved)
        : core.ServerAddressDraft();
  }

  ServerAddressCheckResult _keep(
    String serverId,
    OpenWebUiEndpoint? saved,
    String label,
    ServerConfig config,
    int sessionRevision, {
    required bool behindProxy,
  }) {
    final id = _uuid.v4();
    _checked[id] = _CheckedAddress(
      serverId: serverId,
      saved: saved,
      label: label,
      config: config,
      sessionRevision: sessionRevision,
      behindProxy: behindProxy,
    );
    return ServerAddressCheckResult(
      outcome: behindProxy
          ? ServerAddressCheckOutcome.behindProxy
          : ServerAddressCheckOutcome.answered,
      checkId: id,
      url: config.url,
    );
  }

  /// Saves a checked address ([core.saveVerifiedServerAddress]). What the
  /// core asks the user -- a session sent to a new host, the address in use
  /// changed mid-reply -- comes back as [ServerAddressChangeOutcome
  /// .needsConfirmation], and the window calls again with the answer. One
  /// behind a proxy is saved with what the proxy's sign-in captured, its
  /// cookie kept for the account that proves the address -- and refused when
  /// that is not the account the capture names.
  Future<ServerAddressSaveResult> save(ServerAddressSaveRequest request) async {
    _forgetStale();
    final checked = _checked[request.checkId];
    if (checked == null) {
      throw RpcError(
        code: ConduitErrorCodes.notFound,
        args: <String, String>{'checkId': request.checkId},
        debugMessage: 'no checked address under that id (check it again)',
      );
    }
    if (checked.behindProxy) {
      final proxy = request.proxy;
      if (proxy == null) {
        throw const RpcError(
          code: ConduitErrorCodes.invalidParams,
          debugMessage: 'the address is behind a sign-in proxy: sign in first',
        );
      }
      final refused = await _signedInThroughProxy(checked, proxy);
      if (refused != null) {
        _checked.remove(request.checkId);
        return refused;
      }
    }

    ServerAddressConfirmation? asked;
    String? host;
    final core.ServerAddressSave outcome;
    try {
      outcome = await core.saveVerifiedServerAddress(
        _container,
        serverId: checked.serverId,
        endpointId: checked.endpointId,
        addedEndpointId: checked.addedEndpointId,
        label: checked.label,
        verified: checked.config,
        editedFrom: checked.saved,
        sessionAccount: checked.sessionAccount,
        sessionRevision: checked.sessionRevision,
        confirmSendingSession: (address) async {
          if (request.sendSessionConfirmed) return true;
          asked = ServerAddressConfirmation.sendSession;
          host = address.authority;
          return false;
        },
        confirmChangingInUse: () async {
          if (!_replyArrives()) return true;
          if (request.stopReplies) {
            await _stopReplies();
            return true;
          }
          asked = ServerAddressConfirmation.replyInProgress;
          return false;
        },
        stillWanted: () => _checked.containsKey(request.checkId),
        replyArrives: _replyArrives,
      );
    } on core.ServerAddressReplyArriving {
      // A reply started through the address while Save waited to write:
      // asked about, never cut off; the check stays for the answer.
      return ServerAddressSaveResult(
        outcome: ServerAddressChangeOutcome.needsConfirmation,
        confirmation: ServerAddressConfirmation.replyInProgress,
        host: host,
      );
    } on Object catch (error, stackTrace) {
      DebugLogger.error(
        'server-address-save-failed',
        scope: 'daemon/servers',
        error: error,
        stackTrace: stackTrace,
      );
      // Whether the address was written is unknown: the check stays, so
      // Save can be tried again (by its ids it writes the same address, or
      // finds it written).
      return ServerAddressSaveResult(
        outcome: ServerAddressChangeOutcome.notSaved,
        problem: ServerAddressProblemCode.serverError,
        addresses: await _addressesNow(checked.serverId),
      );
    }
    switch (outcome) {
      case core.ServerAddressSaved():
        _changed(checked.serverId);
        final addresses = await _addressesNow(checked.serverId);
        // Used up once the answer is ready: until then a Save tried again
        // finds the address written.
        _checked.remove(request.checkId);
        return ServerAddressSaveResult(
          outcome: ServerAddressChangeOutcome.done,
          addresses: addresses,
        );
      case core.ServerAddressNotSaved(:final problem):
        final question = asked;
        if (problem == null && question != null) {
          // Kept for the call that answers it.
          return ServerAddressSaveResult(
            outcome: ServerAddressChangeOutcome.needsConfirmation,
            confirmation: question,
            host: host,
          );
        }
        _checked.remove(request.checkId);
        return ServerAddressSaveResult(
          outcome: ServerAddressChangeOutcome.notSaved,
          problem: problem == null ? null : _code(problem),
          addresses: await _addressesNow(checked.serverId),
        );
    }
  }

  /// Takes what a proxy's sign-in window captured into [checked]'s address
  /// and asks the server through it once more, as the phone's connection
  /// page does after its proxy sign-in. Null when it answered; else why not.
  Future<ServerAddressSaveResult?> _signedInThroughProxy(
    _CheckedAddress checked,
    ExternalAuthCompletion proxy,
  ) async {
    if (!_sameOrigin(checked.config.url, proxy.origin)) {
      throw RpcError(
        code: ConduitErrorCodes.invalidParams,
        args: <String, String>{'origin': proxy.origin},
        debugMessage: 'captured origin is not the checked address',
      );
    }
    final headers = mergeCapturedProxyCookiesIntoHeaders(
      headers: checked.config.customHeaders,
      capturedCookies: proxy.cookies,
    );
    final config = checked.config.copyWith(customHeaders: headers);
    final api = ApiService(
      serverConfig: config,
      workerManager: _container.read(workerManagerProvider),
      authToken: proxy.token,
    );
    try {
      final answered = await api.verifyAndGetConfig();
      if (answered == null) {
        return const ServerAddressSaveResult(
          outcome: ServerAddressChangeOutcome.notSaved,
          problem: ServerAddressProblemCode.proxyVerificationFailed,
        );
      }
    } on Object catch (error) {
      final failure = core.classifyServerConnectionError(
        error,
        sensitiveValues: [
          ...headers.values,
          ...proxy.cookies.values,
          if (proxy.token?.isNotEmpty ?? false) proxy.token!,
        ],
        hasMutualTlsInput: config.hasMutualTlsCredentials,
      );
      final unusable = _unusableFor(failure);
      return ServerAddressSaveResult(
        outcome: ServerAddressChangeOutcome.notSaved,
        problem: unusable.problem,
        errorText: unusable.errorText,
      );
    } finally {
      api.dispose();
    }
    // Signed in: a confirmation asked next does not need the window again.
    checked
      ..config = config
      ..sessionAccount = proxy.account
      ..behindProxy = false;
    return null;
  }

  /// Removes [request]'s address. The address in use asks first while a
  /// reply arrives through it.
  Future<ServerAddressEditResult> remove(
    ServerAddressRemoveRequest request,
  ) async {
    final registry = await _storage.getOpenWebUiRegistryStrict();
    final server = registry.server(request.serverId);
    if (server == null) throw _notFound(request.serverId);
    if (server.endpoint(request.endpointId) == null) {
      throw _notFound(request.endpointId);
    }
    if (!core.serverAddressesRemovable(server)) {
      throw const RpcError(
        code: ConduitErrorCodes.invalidParams,
        debugMessage: 'a server keeps one address',
      );
    }
    bool replyThroughIt() =>
        _addressInUse(server.id, registry) == request.endpointId &&
        _replyArrives();
    ServerAddressEditResult ask() => ServerAddressEditResult(
      outcome: ServerAddressChangeOutcome.needsConfirmation,
      confirmation: ServerAddressConfirmation.replyInProgress,
      addresses: _addressesOf(server, registry),
    );
    if (replyThroughIt()) {
      if (!request.stopReplies) return ask();
      await _stopReplies();
    }
    try {
      await core.editServerAddresses(_container, server.id, (endpoints) {
        // Asked again in storage's own write, right before it writes: a
        // reply another window started since is asked about too, never cut.
        if (replyThroughIt()) throw const _ReplyStarted();
        return core.withoutServerAddress(endpoints, request.endpointId);
      });
    } on _ReplyStarted {
      return ask();
    }
    _changed(server.id);
    return ServerAddressEditResult(
      outcome: ServerAddressChangeOutcome.done,
      addresses: await _addressesNow(server.id),
    );
  }

  /// Puts [request]'s server's addresses in the order it names.
  Future<ServerAddressEditResult> reorder(
    ServerAddressReorderRequest request,
  ) async {
    // Each address once: one written twice makes the saved servers
    // unreadable at the next start.
    if (request.order.toSet().length != request.order.length) {
      throw const RpcError(
        code: ConduitErrorCodes.invalidParams,
        debugMessage: 'an address is named twice in the order',
      );
    }
    final registry = await _storage.getOpenWebUiRegistryStrict();
    if (registry.server(request.serverId) == null) {
      throw _notFound(request.serverId);
    }
    await core.editServerAddresses(
      _container,
      request.serverId,
      (endpoints) => core.serverAddressesInOrder(endpoints, request.order),
    );
    _changed(request.serverId);
    return ServerAddressEditResult(
      outcome: ServerAddressChangeOutcome.done,
      addresses: await _addressesNow(request.serverId),
    );
  }

  Future<ServerAddresses> _addressesNow(String serverId) async {
    final registry = await _storage.getOpenWebUiRegistryStrict();
    final server = registry.server(serverId);
    return server == null
        ? ServerAddresses(serverId: serverId, name: '')
        : _addressesOf(server, registry);
  }

  /// Whether a reply arrives through the active account's address now: one
  /// of the daemon's own Open WebUI answers, or the core's open chat's.
  bool _replyArrives() {
    if (replies?.addressAnswering ?? false) return true;
    try {
      return _container.read(addressChangeReplyGuardProvider)();
    } on Object {
      return false;
    }
  }

  Future<void> _stopReplies() async {
    await replies?.stopAddressAnswers();
    try {
      _container.read(addressChangeStopRepliesProvider)();
    } on Object catch (error, stackTrace) {
      DebugLogger.error(
        'address-change-stop-replies-failed',
        scope: 'daemon/servers',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  void _forgetStale() {
    final now = DateTime.now();
    _checked.removeWhere(
      (_, checked) => now.difference(checked.at) > checkLifetime,
    );
  }

  static ServerAddressCheckResult _unusable(
    core.ServerAddressProblem problem, {
    String? headerName,
  }) => ServerAddressCheckResult(
    outcome: ServerAddressCheckOutcome.unusable,
    problem: _code(problem),
    headerName: headerName,
  );

  static ServerAddressCheckResult _unusableFor(
    core.ServerAddressFailure failure,
  ) => switch (failure) {
    core.ServerAddressProblemFailure(:final problem) => _unusable(problem),
    core.ServerAddressErrorText(:final text) => ServerAddressCheckResult(
      outcome: ServerAddressCheckOutcome.unusable,
      errorText: text,
    ),
  };

  /// The core's problem as the protocol names it: the same names.
  static ServerAddressProblemCode _code(core.ServerAddressProblem problem) =>
      ServerAddressProblemCode.values.byName(problem.name);

  /// The live state of the active server.
  ///
  /// Deliberately never throws for an unreachable server. "I could not reach
  /// it, and here is the code" is the answer the connection-issue page exists
  /// to render; turning it into an RPC error would leave that page with
  /// nothing to say but "something went wrong".
  Future<ServerStatus> status() async {
    final activeId = await _storage.getActiveServerId();
    if (activeId == null) {
      return const ServerStatus(
        maxSupportedVersion: ServerVersionCompat.maxSupportedVersion,
      );
    }

    // Await the active server before reading the client. `apiServiceProvider`
    // is synchronous and derives from an async one, so immediately after a
    // connect it is still null -- not because there is no server, but because
    // the provider it depends on has not resolved yet. Reading it directly
    // here reported "unknown" for a server that was about to work.
    await readSettled(_container, activeServerProvider.future);
    // What the checks below find belongs to the account whose client is
    // read here, taken once its server has settled.
    final account = AccountScope.capture(_container);
    final api = _container.read(apiServiceProvider);
    if (api == null) {
      return ServerStatus(
        activeServerId: activeId,
        reachability: ServerReachability.unknown,
        maxSupportedVersion: ServerVersionCompat.maxSupportedVersion,
      );
    }

    // `verifyAndGetConfig`, not `backendConfigProvider`. That provider hands
    // back the *cached* config and refreshes in the background, so on a first
    // connection it is null simply because nothing has been fetched yet --
    // which this used to report as "not an Open WebUI server", the one answer
    // guaranteed to send the user back to re-check a URL that was correct.
    //
    // The probe returns a config, or null for every failure: a request
    // that never arrived as much as an answer that is not Open WebUI's.
    // `/health` tells those apart, because every Open WebUI serves it. A
    // server out of reach used to be reported as "not Open WebUI", which
    // sends the user to re-check an address that is fine.
    final BackendConfig? config;
    try {
      config = await api.verifyAndGetConfig();
    } on Object catch (error) {
      return _unreachable(activeId, error);
    }

    if (config == null) {
      try {
        final health = await api.checkHealthWithProxyDetection();
        if (health == HealthCheckResult.unreachable) {
          return _unreachable(activeId, null);
        }
        _noteProxySession(health, account);
      } on Object catch (error) {
        return _unreachable(activeId, error);
      }
      return ServerStatus(
        activeServerId: activeId,
        reachability: ServerReachability.notOpenWebUi,
        errorCode: ConduitErrorCodes.connectionFailed,
        maxSupportedVersion: ServerVersionCompat.maxSupportedVersion,
      );
    }

    return ServerStatus(
      activeServerId: activeId,
      capabilities: capabilitiesFor(config),
      reachability: ServerReachability.reachable,
      version: config.version,
      isVersionSupported: config.isVersionSupported,
      maxSupportedVersion: ServerVersionCompat.maxSupportedVersion,
    );
  }

  /// A signed-in account whose server sits behind a sign-in proxy, which now
  /// sends it to its sign-in page: the proxy's session expired. Told to the
  /// core as its client tells it a redirect on the session endpoint, so the
  /// account keeps its session and the window offers to renew the proxy's
  /// (`auth.renewProxy`) instead of signing out.
  ///
  /// Only for the account the check was made for ([account]): another
  /// account's server answering meanwhile is no word on this one's proxy.
  void _noteProxySession(HealthCheckResult health, AccountScope account) {
    if (!account.isCurrent) return;
    final server = _container.read(activeServerProvider).asData?.value;
    final auth = _container.read(authStateManagerProvider).asData?.value;
    if (auth == null ||
        !auth.isAuthenticated ||
        !proxySessionExpired(server, health)) {
      return;
    }
    _container.read(authStateManagerProvider.notifier).onAuthIssue();
  }

  static ServerStatus _unreachable(String activeId, Object? error) =>
      ServerStatus(
        activeServerId: activeId,
        reachability: ServerReachability.unreachable,
        errorCode: error is RpcError
            ? error.code
            : ConduitErrorCodes.connectionFailed,
        maxSupportedVersion: ServerVersionCompat.maxSupportedVersion,
      );

  /// Projects the server's config onto the protocol's capability flags.
  ///
  /// The UI gates navigation on these rather than reading a server config it
  /// does not have, which is the whole reason the flags exist. Anything the
  /// server does not mention stays false: an unknown capability is one the
  /// UI must not offer, because offering it produces a sidebar entry that
  /// dead-ends.
  ///
  /// The flags with no `BackendConfig` counterpart -- Hermes, the terminal,
  /// the Apple helper, the parity-plus features -- are left off here; the
  /// services that implement them answer for themselves.
  static Capabilities capabilitiesFor(BackendConfig config) => Capabilities(
    // Open WebUI has no feature flag for these; they exist on every server
    // this app supports, and the sidebar entries are always meaningful.
    workspace: true,
    notes: true,
    channels: config.enableWebsocket ?? false,
    directConnections: config.enableDirectConnections ?? false,
    serverStt: VoiceService.transcribes(config),
    serverTts: VoiceService.speaks(config),
    // Browser speech synthesis, available wherever the renderer runs.
    deviceTts: true,
    branchNavigation: true,
    // Open WebUI's own client treats an unset flag as on.
    messageRating: config.enableMessageRating ?? true,
    tags: true,
    bulkSelection: true,
  );

  /// Tells the providers that stored configuration changed.
  ///
  /// These writes go straight to `OptimizedStorageService`, which the
  /// providers cache in front of -- so without this, adding the very first
  /// server leaves `serverConfigsProvider` holding the empty list it built
  /// before the server existed, and `apiServiceProvider` therefore stays
  /// null. Every later call then behaves as though no server were
  /// configured, which surfaces as a sign-in that fails for no visible
  /// reason.
  ///
  /// Not covered by the invalidation inside `switchToAccount`: that
  /// method returns early when the target is already the active server, and
  /// a lone stored config *is* already active by the storage layer's own
  /// fallback -- so the first connect after the first add does nothing at
  /// all.
  void _republishServerConfigs() {
    _container
      ..invalidate(serverConfigsProvider)
      ..invalidate(activeServerProvider)
      ..invalidate(apiServiceProvider);
  }

  /// The only `ServerConfig` -> wire conversion.
  ///
  /// Field-by-field on purpose. A spread or a generated mapper would publish
  /// whatever gets added to `ServerConfig` next, and three of its fields are
  /// private keys.
  ///
  /// [activeId] rather than `config.isActive`, when it is known. The stored
  /// flag and the stored active id are two records of one fact, and the id is
  /// the one the core resolves against -- so trusting the flag can produce a
  /// list where `activeServerId` points at a server that reports
  /// `isActive: false`, or at two servers that both report true.
  static ServerSummary summarize(
    ServerConfig config, {
    String? activeId,
    bool hasStoredSession = false,
  }) => ServerSummary(
    id: config.id,
    name: config.name,
    url: config.url,
    isActive: activeId == null ? config.isActive : config.id == activeId,
    lastConnectedMs: config.lastConnected?.millisecondsSinceEpoch,
    allowSelfSignedCertificates: config.allowSelfSignedCertificates,
    hasMutualTlsCredentials: config.hasMutualTlsCredentials,
    mtlsCertificateLabel: config.mtlsCertificateLabel,
    mtlsPrivateKeyLabel: config.mtlsPrivateKeyLabel,
    customHeaderNames: config.customHeaders.keys.toList(growable: false)
      ..sort(),
    hasStoredSession: hasStoredSession,
  );

  static RpcError _notFound(String id) => RpcError(
    code: ConduitErrorCodes.notFound,
    args: <String, String>{'id': id},
    debugMessage: 'no server with id $id',
  );

  /// Rejects anything that is not an absolute http(s) URL.
  ///
  /// Not cosmetic: a `file:` or `data:` URL reaching the request layer would
  /// make the daemon read local files on behalf of the renderer.
  static String validateUrl(String url) {
    final trimmed = url.trim();
    final parsed = Uri.tryParse(trimmed);
    if (parsed == null ||
        !parsed.isAbsolute ||
        (parsed.scheme != 'http' && parsed.scheme != 'https') ||
        parsed.host.isEmpty) {
      throw RpcError(
        code: ConduitErrorCodes.invalidParams,
        args: <String, String>{'url': trimmed},
        debugMessage: 'server url must be an absolute http(s) URL',
      );
    }
    // `user:password@` would be stored, and sent back in every summary;
    // a server's credentials go in the sign-in, never in its address. Not
    // echoed in the error either.
    if (parsed.userInfo.isNotEmpty) {
      throw const RpcError(
        code: ConduitErrorCodes.invalidParams,
        args: <String, String>{'reason': 'userInfo'},
        debugMessage: 'a server url must not carry a user or password',
      );
    }
    // Stored without a trailing slash so two spellings of the same server do
    // not become two servers.
    return trimmed.endsWith('/')
        ? trimmed.substring(0, trimmed.length - 1)
        : trimmed;
  }

  static String validateName(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      throw const RpcError(
        code: ConduitErrorCodes.invalidParams,
        debugMessage: 'server name must not be empty',
      );
    }
    return trimmed;
  }
}

/// Thrown inside a storage edit when a reply started through the address
/// since it was asked about.
final class _ReplyStarted implements Exception {
  const _ReplyStarted();
}

/// The daemon's own Open WebUI answers, which arrive through the active
/// account's address: whether one is being written, and stopping them once
/// the user has agreed to change that address anyway.
abstract interface class AddressReplies {
  bool get addressAnswering;
  Future<void> stopAddressAnswers();
}

/// An address checked by `servers.addresses.check`, waiting for its save.
final class _CheckedAddress {
  _CheckedAddress({
    required this.serverId,
    required this.saved,
    required this.label,
    required this.config,
    required this.sessionRevision,
    required this.behindProxy,
  });

  final String serverId;

  /// The address edited as stored when it was checked (none for a new one):
  /// what the save tells the form's changes by.
  final OpenWebUiEndpoint? saved;
  String? get endpointId => saved?.id;
  final String label;

  /// The address as it answered; with the proxy's cookie once signed in
  /// through it.
  ServerConfig config;
  final int sessionRevision;
  bool behindProxy;

  /// The account the proxy's sign-in window was for, when it named one:
  /// its cookie is kept for that account alone.
  String? sessionAccount;

  /// The id a new address is saved under: one per check, so saving again
  /// after a save that stored it and then failed edits it rather than
  /// adding it twice.
  final String addedEndpointId = const Uuid().v4();
  final DateTime at = DateTime.now();
}

/// Scheme, host and port, ignoring path and trailing slash.
bool _sameOrigin(String a, String b) {
  final left = Uri.tryParse(a);
  final right = Uri.tryParse(b);
  if (left == null || right == null) return false;
  return left.scheme == right.scheme &&
      left.host == right.host &&
      left.port == right.port;
}
