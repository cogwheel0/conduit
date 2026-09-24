part of 'api_service.dart';

abstract class _ApiServiceBase {
  // Declared here, implemented by the family mixins applied over this base.
  // A mixin cannot see a sibling mixin's members, and three of these are
  // reached from private helpers that live in this class, so the base has to
  // name them. Getting this list wrong is a compile error, not a silent
  // change in behaviour.
  Future<List<Model>> getModels({bool includeHidden = false});
  Future<Map<String, dynamic>?> getMessageData(
    String channelId,
    String messageId,
  );
  Future<ServerUserSettings> getServerUserSettingsModel();
  Future<bool> deleteChatRaw(String id);

  final Dio _dio;
  final ServerConfig serverConfig;
  final WorkerManager _workerManager;
  final PublicHealthAddressResolver _publicHealthAddressResolver;
  final PublicHealthSocketConnector _publicHealthSocketConnector;
  final PublicHealthSocketUpgrader _publicHealthSocketUpgrader;
  final Duration _publicHealthPinnedConnectTimeout;
  final Duration _publicHealthRequestTimeout;
  late final ApiAuthInterceptor _authInterceptor;
  Future<void> _userSettingsMutationQueue = Future<void>.value();
  bool _disposed = false;
  _ChatRequestMetadataFormat? _chatRequestMetadataFormat;
  // Public getter for dio instance
  Dio get dio => _dio;
  // Public getter for base URL
  String get baseUrl => serverConfig.url;
  // Callback to notify when auth token becomes invalid
  void Function()? onAuthTokenInvalid;
  // New callback for the unified auth state manager
  Future<void> Function()? onTokenInvalidated;
  _ApiServiceBase({
    required this.serverConfig,
    required WorkerManager workerManager,
    String? authToken,
    bool suppressCookieCustomHeader = false,
    bool Function()? shouldSuppressCookieCustomHeader,
    PublicHealthAddressResolver? publicHealthAddressResolver,
    PublicHealthSocketConnector? publicHealthSocketConnector,
    PublicHealthSocketUpgrader? publicHealthSocketUpgrader,
    Duration publicHealthPinnedConnectTimeout = const Duration(seconds: 30),
    Duration publicHealthRequestTimeout = const Duration(seconds: 30),
  }) : _dio = Dio(
         BaseOptions(
           baseUrl: serverConfig.url,
           connectTimeout: const Duration(seconds: 30),
           receiveTimeout: const Duration(seconds: 30),
           // Requests on this client can carry a bearer token plus
           // installation-specific reverse-proxy headers. Dart's redirect
           // handling cannot guarantee that arbitrary custom credentials are
           // stripped when Location crosses origins, so credentialed API
           // redirects must be surfaced to the caller instead of followed.
           followRedirects: false,
           maxRedirects: 0,
           validateStatus: (status) => status != null && status < 300,
         ),
       ),
       _workerManager = workerManager,
       _publicHealthAddressResolver =
           publicHealthAddressResolver ??
           ((host) => InternetAddress.lookup(host)),
       _publicHealthSocketConnector =
           publicHealthSocketConnector ??
           ((address, port) => Socket.startConnect(address, port)),
       _publicHealthSocketUpgrader =
           publicHealthSocketUpgrader ??
           ((socket, host) => SecureSocket.secure(socket, host: host)),
       _publicHealthPinnedConnectTimeout = publicHealthPinnedConnectTimeout,
       _publicHealthRequestTimeout = publicHealthRequestTimeout {
    if (publicHealthRequestTimeout <= Duration.zero) {
      throw ArgumentError.value(
        publicHealthRequestTimeout,
        'publicHealthRequestTimeout',
        'must be greater than zero',
      );
    }
    ServerTlsHttpClientFactory.configureDio(
      _dio,
      serverConfig,
      userAgent: ConduitUserAgent.value,
    );

    // Initialize the consistent auth interceptor
    _authInterceptor = ApiAuthInterceptor(
      serverUrl: serverConfig.url,
      // OpenWebUI bearer ownership comes only from AuthStateManager (or an
      // explicit operation-scoped discovery token). Legacy ServerConfig.apiKey
      // values must never silently survive logout or a server switch.
      authToken: authToken,
      onAuthTokenInvalid: onAuthTokenInvalid,
      onTokenInvalidated: onTokenInvalidated,
      customHeaders: serverConfig.customHeaders,
      suppressCookieCustomHeader: suppressCookieCustomHeader,
      shouldSuppressCookieCustomHeader: shouldSuppressCookieCustomHeader,
    );

    // Add interceptors in order of priority:
    // 1. Auth interceptor (must be first to add auth headers)
    _dio.interceptors.add(_authInterceptor);

    // 2. Same-origin redirect recovery. Base options disable redirect
    // following because Dart's client cannot guarantee credential stripping on
    // cross-origin Location hops. Reverse proxies still commonly redirect API
    // paths within the SAME origin (trailing slashes, canonical rewrites, and
    // default-port http→https upgrades), and those worked before redirect
    // following was disabled, so safe idempotent hops are replayed here with
    // the target restricted by [isCredentialSafeRedirectTarget].
    _dio.interceptors.add(
      SameOriginRedirectInterceptor(
        _dio,
        prepareReplay: _authInterceptor.prepareRedirectReplay,
      ),
    );

    // 3. Error handling interceptor (transforms errors to standardized format)
    _dio.interceptors.add(
      ApiErrorInterceptor(
        // Was Flutter's kDebugMode; the core cannot reach Flutter, and
        // `dart.vm.product` is the same signal without it.
        logErrors: !const bool.fromEnvironment('dart.vm.product'),
        throwApiErrors: true, // Transform DioExceptions to include ApiError
      ),
    );

    // 4. Success pings to relax offline detection. ApiService also supports
    // absolute image/CDN URLs, so only the configured server origin is allowed
    // to influence that server's health state.
    final connectivityOrigin = Uri.tryParse(serverConfig.url);
    _dio.interceptors.add(
      InterceptorsWrapper(
        onResponse: (response, handler) {
          try {
            if ((response.statusCode ?? 0) >= 200 &&
                (response.statusCode ?? 0) < 400 &&
                requestUsesServerConnectivityOrigin(
                  response.requestOptions.uri,
                  connectivityOrigin,
                )) {
              ConnectivityService.suppressOfflineGlobally(
                const Duration(seconds: 4),
              );
              ConnectivityService.noteSuccessfulTraffic(connectivityOrigin);
            }
          } catch (_) {}
          handler.next(response);
        },
        onError: (error, handler) {
          if (error.response == null &&
              requestUsesServerConnectivityOrigin(
                error.requestOptions.uri,
                connectivityOrigin,
              ) &&
              (error.type == DioExceptionType.connectionTimeout ||
                  error.type == DioExceptionType.sendTimeout ||
                  error.type == DioExceptionType.receiveTimeout ||
                  error.type == DioExceptionType.connectionError ||
                  error.type == DioExceptionType.unknown)) {
            ConnectivityService.reportTransportFailure(connectivityOrigin);
          }
          handler.next(error);
        },
      ),
    );
  }

  /// Live logout-fence state used by request paths that build headers outside
  /// Dio (for example authenticated image widgets).
  bool get cookieCustomHeaderSuppressed =>
      _authInterceptor.cookieCustomHeaderSuppressed;
  String? get authToken => _authInterceptor.authToken;

  /// Changes whenever the bearer/cookie transport identity changes.
  int get authenticationEpoch => _authInterceptor.authenticationEpoch;

  /// Freezes the current bearer token for an already-authorized unit of work.
  /// Passing this snapshot to supported request methods prevents a queued
  /// request from silently adopting a later account's token on the same
  /// [ApiService] instance.
  ApiAuthSnapshot captureAuthSnapshot() => _authInterceptor.captureSnapshot();
  Options _withAuthSnapshot(Options options, ApiAuthSnapshot? authSnapshot) {
    if (authSnapshot == null) return options;
    options.extra = <String, dynamic>{
      ...?options.extra,
      ApiAuthInterceptor.authSnapshotExtraKey: authSnapshot,
      'suppressAuthFailureNotification': true,
    };
    return options;
  }

  Future<bool> _followPublicHealthRedirect({
    required Uri from,
    required String location,
    required PublicHealthDeadline deadline,
    required CancelToken cancelToken,
  }) async {
    final serverOrigin = ServerTlsHttpClientFactory.parseBaseUri(
      serverConfig.url,
    );
    final visited = <Uri>{from.replace(fragment: '')};
    Uri current;
    try {
      current = from.resolve(location).replace(fragment: '');
    } on FormatException {
      return false;
    }

    for (
      var redirectCount = 0;
      redirectCount < maximumPublicHealthRedirects;
      redirectCount++
    ) {
      final scheme = current.scheme.toLowerCase();
      if ((scheme != 'http' && scheme != 'https') ||
          current.host.isEmpty ||
          current.userInfo.isNotEmpty ||
          !visited.add(current)) {
        return false;
      }

      final targetsServer = requestUsesServerConnectivityOrigin(
        current,
        serverOrigin,
      );
      List<InternetAddress>? pinnedAddresses;
      if (!targetsServer) {
        final validatedAddresses = await _resolveSafeOffOriginHealthTarget(
          current,
          deadline: deadline,
        );
        if (validatedAddresses == null) return false;
        pinnedAddresses = validatedAddresses;
      }
      final hopTimeout = deadline.remaining(
        cappedAt: targetsServer
            ? const Duration(seconds: 30)
            : _publicHealthPinnedConnectTimeout,
      );
      final redirectDio = Dio(
        BaseOptions(
          connectTimeout: hopTimeout,
          receiveTimeout: deadline.remaining(
            cappedAt: const Duration(seconds: 30),
          ),
          followRedirects: false,
          validateStatus: (status) => status != null,
          headers: _publicHealthHeaders(includeServerHeaders: targetsServer),
        ),
      );
      if (targetsServer) {
        // Server-specific trust and mTLS material must never be reused for an
        // off-origin redirect. A fresh client per hop keeps that boundary
        // explicit and makes connection-pool cleanup deterministic.
        ServerTlsHttpClientFactory.configureDio(
          redirectDio,
          serverConfig,
          userAgent: ConduitUserAgent.value,
        );
      } else {
        _configurePinnedPublicHealthDio(
          redirectDio,
          target: current,
          addresses: pinnedAddresses!,
          deadline: deadline,
        );
      }

      Response<dynamic>? response;
      final hopCancelToken = _linkedPublicHealthCancelToken(cancelToken);
      try {
        // Health checks only need status and headers. Keep the body as a
        // stream so an off-origin endpoint cannot force an arbitrarily large
        // response into memory before the per-hop client is closed.
        response = await redirectDio
            .getUri<dynamic>(
              current,
              options: Options(responseType: ResponseType.stream),
              cancelToken: hopCancelToken,
            )
            .timeout(deadline.remaining());
        if (response.statusCode == HttpStatus.ok) return true;
        if (!publicHealthRedirectStatusCodes.contains(response.statusCode)) {
          return false;
        }
        final nextLocation = response.headers.value(HttpHeaders.locationHeader);
        if (nextLocation == null || nextLocation.isEmpty) return false;
        current = current.resolve(nextLocation).replace(fragment: '');
      } on DioException catch (error) {
        response ??= error.response;
        return false;
      } on FormatException {
        return false;
      } finally {
        if (!hopCancelToken.isCancelled) {
          hopCancelToken.cancel('Health redirect response complete');
        }
        await _cancelPublicHealthResponse(response);
        redirectDio.close(force: true);
      }
    }
    return false;
  }

  Future<List<InternetAddress>?> _resolveSafeOffOriginHealthTarget(
    Uri target, {
    required PublicHealthDeadline deadline,
  }) async {
    try {
      final literal = InternetAddress.tryParse(target.host);
      final addresses = literal == null
          ? await _publicHealthAddressResolver(
              target.host,
            ).timeout(deadline.remaining(cappedAt: const Duration(seconds: 10)))
          : <InternetAddress>[literal];
      if (addresses.isEmpty) return null;

      var nat64Prefixes = const <PublicHealthNat64Prefix>[];
      if (addresses.any(requiresNat64PrefixDiscovery)) {
        final discoveryAnswers = await _publicHealthAddressResolver(
          'ipv4only.arpa',
        ).timeout(deadline.remaining(cappedAt: const Duration(seconds: 10)));
        final discovered = nat64PrefixesFromIpv4OnlyArpa(discoveryAnswers);
        if (discovered == null) return null;
        nat64Prefixes = discovered;
      }
      if (!addresses.every(
        (address) => isPublicHealthRedirectAddressWithNat64Prefixes(
          address,
          nat64Prefixes,
        ),
      )) {
        return null;
      }
      // Return the exact validated objects. The transport below connects to
      // one of these addresses directly and never resolves [target.host]
      // again, closing the DNS-rebinding gap between policy and use.
      return List<InternetAddress>.unmodifiable(addresses);
    } catch (_) {
      // DNS failure and malformed/unsupported address families fail closed.
      return null;
    }
  }

  void _configurePinnedPublicHealthDio(
    Dio dio, {
    required Uri target,
    required List<InternetAddress> addresses,
    required PublicHealthDeadline deadline,
  }) {
    final adapter = dio.httpClientAdapter;
    if (adapter is! IOHttpClientAdapter) {
      throw StateError('Pinned health redirects require dart:io transport');
    }
    adapter.createHttpClient = () {
      final client = HttpClient()..userAgent = ConduitUserAgent.value;
      // A proxy would resolve the hostname outside this validated boundary.
      client.findProxy = (_) => 'DIRECT';
      client.connectionFactory = (uri, proxyHost, proxyPort) {
        if (proxyHost != null ||
            proxyPort != null ||
            !requestUsesServerConnectivityOrigin(uri, target)) {
          return Future<ConnectionTask<Socket>>.error(
            StateError('Unexpected target for pinned health redirect'),
          );
        }
        return Future<ConnectionTask<Socket>>.value(
          PinnedPublicHealthConnection(
            target: uri,
            addresses: addresses,
            connectTimeout: deadline.remaining(
              cappedAt: _publicHealthPinnedConnectTimeout,
            ),
            connector: _publicHealthSocketConnector,
            upgrader: _publicHealthSocketUpgrader,
          ).start(),
        );
      };
      return client;
    };
  }

  Map<String, String> _publicHealthHeaders({
    required bool includeServerHeaders,
  }) {
    if (!includeServerHeaders) return ConduitUserAgent.mergeHeaders();
    final headers = Map<String, String>.from(serverConfig.customHeaders)
      ..removeWhere((name, _) {
        final normalized = name.toLowerCase();
        return normalized == HttpHeaders.authorizationHeader ||
            ConduitUserAgent.isHeaderName(name) ||
            (cookieCustomHeaderSuppressed &&
                normalized == HttpHeaders.cookieHeader);
      });
    final token = _authInterceptor.authToken;
    if (token != null && token.isNotEmpty) {
      headers[HttpHeaders.authorizationHeader] = 'Bearer $token';
    }
    return ConduitUserAgent.mergeHeaders(headers);
  }

  Future<BackendConfig> _enrichBackendConfigWithAudioConfig(
    BackendConfig config,
  ) async {
    final audioConfig = await _loadServerAudioConfig();
    return config.copyWith(
      ttsVoice: audioConfig.voice ?? config.ttsVoice,
      ttsSplitOn: audioConfig.splitOn ?? config.ttsSplitOn ?? 'punctuation',
      ttsVoices: audioConfig.voices.isEmpty
          ? config.ttsVoices
          : audioConfig.voices,
    );
  }

  /// Returns the ID of the first available model, or null if none available.
  ///
  /// Used as a fallback when user has no default model configured.
  Future<String?> _getFirstAvailableModelId() async {
    try {
      final models = await getModels();
      if (models.isNotEmpty) {
        final fallbackId = models.first.id;
        DebugLogger.log(
          'default-model-fallback-selected',
          scope: 'api/user-settings',
          data: {'id': fallbackId},
        );
        return fallbackId;
      }
    } catch (e) {
      DebugLogger.error(
        'default-model-fallback-failed',
        scope: 'api/user-settings',
        error: e,
      );
    }
    return null;
  }

  // Parse full OpenWebUI chat with messages
  // Parse OpenWebUI message format to our ChatMessage format
  // Build ordered messages list from Open‑WebUI history using parent chain to currentId
  // ===== Helpers to synthesize tool-call details blocks for UI parsing =====
  List<String>? _sanitizeEmbedsForWebUI(List<Map<String, dynamic>>? embeds) {
    return sanitizeEmbedsForWebUi(embeds);
  }

  Map<String, dynamic> _deepCloneJsonMap(Map<String, dynamic> source) {
    return normalizeJsonLikeMap(source);
  }

  Map<String, dynamic>? _coerceJsonMap(dynamic value) {
    if (value is Map<String, dynamic>) {
      return value;
    }
    if (value is Map) {
      return value.map((key, value) => MapEntry(key?.toString() ?? '', value));
    }
    return null;
  }

  List<dynamic>? _asListOrNull(Object? value) => value is List ? value : null;
  Map<String, dynamic>? _coerceResponseMap(dynamic value) {
    if (value is String && value.isNotEmpty) {
      try {
        final decoded = json.decode(value);
        return _coerceJsonMap(decoded);
      } catch (_) {
        return null;
      }
    }
    return _coerceJsonMap(value);
  }

  Map<String, dynamic> _requireResponseMap(dynamic value, String context) {
    final map = _coerceResponseMap(value);
    if (map == null) {
      throw FormatException('$context: expected JSON object response');
    }
    return map;
  }

  String? _normalizeNullableString(String? value) {
    final trimmed = value?.trim();
    if (trimmed == null || trimmed.isEmpty) {
      return null;
    }
    return trimmed;
  }

  String? _normalizeDynamicString(dynamic value) {
    final trimmed = value?.toString().trim();
    if (trimmed == null || trimmed.isEmpty) {
      return null;
    }
    return trimmed;
  }

  List<String> _coerceStringList(dynamic value) {
    if (value is! List) {
      return <String>[];
    }

    return value
        .map((item) => item?.toString().trim() ?? '')
        .where((item) => item.isNotEmpty)
        .toList(growable: true);
  }

  List<String> _coerceConfigStringList(dynamic value) {
    if (value is String) {
      return value
          .split(',')
          .map((item) => item.trim())
          .where((item) => item.isNotEmpty)
          .toList(growable: true);
    }
    return _coerceStringList(value);
  }

  List<Map<String, dynamic>> _buildHistoryChainMessages(
    Map<String, Map<String, dynamic>> messagesMap,
    String currentId,
  ) {
    return message_tree
        .chainToRoot<Map<String, dynamic>>(
          currentId,
          messagesById: messagesMap,
          parentIdOf: message_tree.rawMessageParentId,
        )
        .map(_deepCloneJsonMap)
        .toList(growable: false);
  }

  bool _shouldFallbackToLegacyMessageDelete(DioException error) {
    final statusCode = error.response?.statusCode;
    return statusCode == 404 || statusCode == 405;
  }

  /// Legacy fallback for older Open WebUI servers that predate the per-message
  /// DELETE endpoint. It edits the latest raw chat payload instead of replaying
  /// a local message list, preserving server-only history fields.
  Future<void> _deleteConversationMessageByHistoryRewrite(
    String conversationId,
    String messageId,
  ) async {
    final response = await _dio.get('/api/v1/chats/$conversationId');
    final rawConversation = _coerceJsonMap(response.data);
    final rawChat = _coerceJsonMap(rawConversation?['chat']);
    if (rawConversation == null || rawChat == null) {
      throw Exception(
        'Delete message failed: invalid chat payload for $conversationId',
      );
    }

    final chat = _deepCloneJsonMap(rawChat);
    final history = _coerceJsonMap(chat['history']) ?? <String, dynamic>{};
    final rawMessagesMap =
        _coerceJsonMap(history['messages']) ?? <String, dynamic>{};
    final messagesMap = <String, Map<String, dynamic>>{};

    for (final entry in rawMessagesMap.entries) {
      final message = _coerceJsonMap(entry.value);
      if (message == null) continue;
      messagesMap[entry.key] = _deepCloneJsonMap(message);
    }

    if (!messagesMap.containsKey(messageId)) {
      return;
    }

    final deleteResult = message_tree.deleteOpenWebUiMessageFromRawHistory(
      messagesMap,
      messageId,
    );
    if (deleteResult == null) {
      return;
    }

    final nextCurrentId = deleteResult.currentId;

    history['messages'] = messagesMap;
    if (nextCurrentId == null || nextCurrentId.isEmpty) {
      history.remove('currentId');
      chat['messages'] = <Map<String, dynamic>>[];
    } else {
      history['currentId'] = nextCurrentId;
      chat['messages'] = _buildHistoryChainMessages(messagesMap, nextCurrentId);
    }
    chat['history'] = history;

    await _dio.post('/api/v1/chats/$conversationId', data: {'chat': chat});
  }

  Future<void> _persistLegacyPendingTurn({
    required String conversationId,
    required String assistantMessageId,
    required String model,
    required Map<String, dynamic> userMessage,
    Map<String, dynamic>? modelItem,
  }) async {
    _traceApi(
      'Persisting legacy pending turn for chat=$conversationId '
      'assistant=$assistantMessageId',
    );

    final response = await _dio.get('/api/v1/chats/$conversationId');
    final rawConversation = _coerceJsonMap(response.data);
    final rawChat = _coerceJsonMap(rawConversation?['chat']);
    if (rawConversation == null || rawChat == null) {
      throw Exception(
        'Legacy chat persistence failed: invalid chat payload for '
        '$conversationId',
      );
    }

    final chat = _deepCloneJsonMap(rawChat);
    final history = _coerceJsonMap(chat['history']) ?? <String, dynamic>{};
    final rawMessagesMap =
        _coerceJsonMap(history['messages']) ?? <String, dynamic>{};
    final messagesMap = <String, Map<String, dynamic>>{};

    for (final entry in rawMessagesMap.entries) {
      final message = _coerceJsonMap(entry.value);
      if (message == null) {
        continue;
      }
      messagesMap[entry.key] = _deepCloneJsonMap(message);
    }

    final normalizedUserMessage = _deepCloneJsonMap(userMessage)
      ..removeWhere((_, value) => value == null);
    final userMessageId = normalizedUserMessage['id']?.toString().trim() ?? '';
    if (userMessageId.isEmpty) {
      throw Exception(
        'Legacy chat persistence failed: missing user message id',
      );
    }

    final existingUserMessage = messagesMap[userMessageId];
    final mergedUserMessage = <String, dynamic>{
      if (existingUserMessage != null)
        ..._deepCloneJsonMap(existingUserMessage),
      ...normalizedUserMessage,
    };
    final userChildrenIds = <String>[
      ..._coerceStringList(existingUserMessage?['childrenIds']),
      ..._coerceStringList(normalizedUserMessage['childrenIds']),
    ];
    if (!userChildrenIds.contains(assistantMessageId)) {
      userChildrenIds.add(assistantMessageId);
    }
    mergedUserMessage['childrenIds'] = userChildrenIds;
    messagesMap[userMessageId] = mergedUserMessage;

    final parentId = mergedUserMessage['parentId']?.toString().trim();
    if (parentId != null && parentId.isNotEmpty) {
      final existingParentMessage = messagesMap[parentId];
      if (existingParentMessage != null) {
        final mergedParentMessage = _deepCloneJsonMap(existingParentMessage);
        final parentChildrenIds = _coerceStringList(
          existingParentMessage['childrenIds'],
        );
        if (!parentChildrenIds.contains(userMessageId)) {
          parentChildrenIds.add(userMessageId);
        }
        mergedParentMessage['childrenIds'] = parentChildrenIds;
        messagesMap[parentId] = mergedParentMessage;
      }
    }

    final existingAssistantMessage = messagesMap[assistantMessageId];
    final assistantModelName =
        modelItem?['name']?.toString().trim().isNotEmpty == true
        ? modelItem!['name'].toString().trim()
        : model;
    final assistantTimestamp =
        existingAssistantMessage?['timestamp'] ??
        DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final mergedAssistantMessage = <String, dynamic>{
      if (existingAssistantMessage != null)
        ..._deepCloneJsonMap(existingAssistantMessage),
      'id': assistantMessageId,
      'parentId': userMessageId,
      'childrenIds': _coerceStringList(
        existingAssistantMessage?['childrenIds'],
      ),
      'role': 'assistant',
      'content': existingAssistantMessage?['content'] ?? '',
      'timestamp': assistantTimestamp,
      'model': model,
      'modelName': assistantModelName,
      'modelIdx': existingAssistantMessage?['modelIdx'] ?? 0,
    }..remove('done');
    messagesMap[assistantMessageId] = mergedAssistantMessage;

    history['messages'] = messagesMap;
    history['currentId'] = assistantMessageId;
    chat['history'] = history;
    chat['messages'] = _buildHistoryChainMessages(
      messagesMap,
      assistantMessageId,
    );

    final models = _coerceStringList(chat['models']);
    if (!models.contains(model)) {
      models.add(model);
    }
    chat['models'] = models;

    await _dio.post('/api/v1/chats/$conversationId', data: {'chat': chat});
  }

  Future<void> _setConversationToggle({
    required String id,
    required String field,
    required String endpoint,
    required bool desired,
  }) async {
    final current = await _fetchConversationBooleanField(id, field);
    if (current == desired) {
      return;
    }
    if (current == null) {
      throw StateError(
        'Cannot set $field for chat $id because the current state is unknown',
      );
    }

    final response = await _dio.post(endpoint);
    final data = _coerceResponseMap(response.data);
    final actual = data?[field] is bool
        ? data![field] as bool
        : await _fetchConversationBooleanField(id, field);
    if (actual == null) {
      throw StateError(
        'Cannot confirm $field for chat $id after toggling to $desired',
      );
    }
    if (actual != desired) {
      DebugLogger.warning(
        'toggle-mismatch',
        scope: 'api/conversation',
        data: {'id': id, 'field': field, 'desired': desired, 'actual': actual},
      );
      throw StateError(
        'Cannot confirm $field for chat $id after toggling to $desired '
        '(actual: $actual)',
      );
    }
  }

  Future<bool?> _fetchConversationBooleanField(String id, String field) async {
    try {
      if (field == 'pinned') {
        try {
          final pinnedResponse = await _dio.get('/api/v1/chats/$id/pinned');
          final pinned = pinnedResponse.data;
          if (pinned is bool) {
            return pinned;
          }
          if (pinned == null) {
            return false;
          }
        } on DioException {
          // Older servers may not expose the dedicated pinned-status endpoint;
          // fall through to the full chat payload below.
        }
      }
      final response = await _dio.get('/api/v1/chats/$id');
      final data = _coerceResponseMap(response.data);
      final value = data?[field];
      if (value == null && (data?.containsKey(field) ?? false)) {
        return false;
      }
      if (value is bool) {
        return value;
      }
      final wrappedChat = _coerceJsonMap(data?['chat']);
      final wrappedValue = wrappedChat?[field];
      if (wrappedValue == null && (wrappedChat?.containsKey(field) ?? false)) {
        return false;
      }
      return wrappedValue is bool ? wrappedValue : null;
    } catch (e, stackTrace) {
      DebugLogger.error(
        'toggle-state-fetch-failed',
        scope: 'api/conversation',
        error: e,
        stackTrace: stackTrace,
        data: {'id': id, 'field': field},
      );
      return null;
    }
  }

  Future<Response<dynamic>> _postUserSettings(
    Map<String, dynamic> settings, {
    ApiAuthSnapshot? authSnapshot,
  }) {
    return _dio.post(
      '/api/v1/users/user/settings/update',
      data: settings,
      options: _withAuthSnapshot(Options(), authSnapshot),
    );
  }

  Future<Map<String, dynamic>?> _loadPromptSuggestionConfig() async {
    try {
      final response = await _dio.get('/api/config');
      return _coerceResponseMap(response.data);
    } on DioException {
      return null;
    }
  }

  Future<List<String>> _loadLegacyPromptSuggestions() async {
    try {
      final response = await _dio.get('/api/v1/configs/suggestions');
      final data = response.data;
      final suggestions = data is List
          ? data
          : _coerceResponseMap(data)?['suggestions'] ??
                _coerceResponseMap(data)?['default_prompt_suggestions'];
      if (suggestions is List) {
        return suggestions
            .map(_promptSuggestionToString)
            .whereType<String>()
            .toList(growable: false);
      }
    } on DioException {
      return const [];
    }
    return [];
  }

  String? _promptSuggestionToString(dynamic value) {
    if (value is String) {
      final trimmed = value.trim();
      return trimmed.isEmpty ? null : trimmed;
    }
    final suggestion = _coerceJsonMap(value);
    if (suggestion == null) {
      return null;
    }
    final content = suggestion['content']?.toString().trim();
    if (content != null && content.isNotEmpty) {
      return content;
    }
    final title = suggestion['title'];
    if (title is List) {
      final parts = title
          .map((part) => part?.toString().trim() ?? '')
          .where((part) => part.isNotEmpty)
          .toList(growable: false);
      return parts.isEmpty ? null : parts.join(' ');
    }
    final fallback = title?.toString().trim();
    return fallback == null || fallback.isEmpty ? null : fallback;
  }

  Future<Conversation> _parseConversationPayload(
    Object? payload, {
    required String debugLabel,
  }) {
    if (_shouldUseWorkerForConversationPayload(payload)) {
      return _workerManager.schedule<Object?, Conversation>(
        parseFullConversationModelWorker,
        payload,
        debugLabel: debugLabel,
      );
    }
    return Future.value(parseFullConversationModel(payload));
  }

  Future<List<Conversation>> _parseConversationSummaryPayload({
    Object? regular = const <dynamic>[],
    Object? pinned = const <dynamic>[],
    Object? archived = const <dynamic>[],
    required String debugLabel,
  }) {
    final payload = <String, dynamic>{
      'regular': regular,
      'pinned': pinned,
      'archived': archived,
    };
    if (_shouldUseWorkerForConversationSummaries(
      regular: regular,
      pinned: pinned,
      archived: archived,
    )) {
      return _workerManager.schedule<Map<String, dynamic>, List<Conversation>>(
        parseConversationSummaryModelsWorker,
        payload,
        debugLabel: debugLabel,
      );
    }
    return Future.value(parseConversationSummaryModels(payload));
  }

  bool _shouldUseWorkerForConversationPayload(Object? payload) {
    return _estimatePayloadBytes(payload) >= _conversationWorkerByteThreshold;
  }

  bool _shouldUseWorkerForConversationSummaries({
    Object? regular,
    Object? pinned,
    Object? archived,
  }) {
    final payloadBytes =
        _estimatePayloadBytes(regular) +
        _estimatePayloadBytes(pinned) +
        _estimatePayloadBytes(archived);
    if (payloadBytes >= _conversationWorkerByteThreshold) {
      return true;
    }

    final itemCount =
        _estimateCollectionLength(regular) +
        _estimateCollectionLength(pinned) +
        _estimateCollectionLength(archived);
    return itemCount >= _conversationSummaryWorkerItemThreshold;
  }

  int _estimatePayloadBytes(Object? payload) {
    if (payload is Uint8List) {
      return payload.lengthInBytes;
    }
    if (payload is List) {
      if (payload.isEmpty) {
        return 0;
      }
      if (payload.every((entry) => entry is int)) {
        return payload.length;
      }
      if (payload.every((entry) => entry is Uint8List || entry is List<int>)) {
        return payload.fold<int>(0, (total, entry) {
          if (entry is Uint8List) {
            return total + entry.lengthInBytes;
          }
          if (entry is List<int>) {
            return total + entry.length;
          }
          return total;
        });
      }
    }
    return 0;
  }

  int _estimateCollectionLength(Object? payload) {
    if (payload is List) {
      if (payload.isEmpty) {
        return 0;
      }
      if (payload.every((entry) => entry is int) ||
          payload.every((entry) => entry is Uint8List || entry is List<int>)) {
        return 0;
      }
      return payload.length;
    }
    return 0;
  }

  Future<List<Map<String, dynamic>>> _normalizeList(
    List<dynamic> raw, {
    required String debugLabel,
  }) {
    return _workerManager
        .schedule<Map<String, dynamic>, List<Map<String, dynamic>>>(
          _normalizeMapListWorker,
          {'list': raw},
          debugLabel: debugLabel,
        );
  }

  Future<List<FileInfo>> _getUserFilesWith(
    Future<({List<FileInfo> items, int? total, bool isPaginated})> Function(
      int page,
    )
    getPage,
  ) async {
    _traceApi('Fetching user files');
    final files = <FileInfo>[];
    var page = 1;
    int? total;
    const maxPages = 200;

    while (page <= maxPages) {
      final pageResult = await getPage(page);

      files.addAll(pageResult.items);
      total ??= pageResult.total;

      if (pageResult.items.isEmpty) {
        break;
      }
      if (!pageResult.isPaginated) {
        break;
      }
      if (total != null && files.length >= total) {
        break;
      }

      page += 1;
    }

    if (page > maxPages) {
      _traceApi('Warning: Hit max user-files page limit ($maxPages)');
    }

    return List<FileInfo>.unmodifiable(files);
  }

  Future<({List<FileInfo> items, int? total, bool isPaginated})>
  _parseFileInfoCollection(dynamic data, {required String debugLabel}) async {
    if (data is List) {
      final normalized = await _normalizeList(data, debugLabel: debugLabel);
      return (
        items: normalized.map(FileInfo.fromJson).toList(growable: false),
        total: null,
        isPaginated: false,
      );
    }

    if (data is Map<String, dynamic>) {
      final items = data['items'];
      final totalValue = data['total'];
      final total = switch (totalValue) {
        int raw => raw,
        num raw => raw.toInt(),
        String raw => int.tryParse(raw),
        _ => null,
      };

      if (items is List) {
        final normalized = await _normalizeList(items, debugLabel: debugLabel);
        return (
          items: normalized.map(FileInfo.fromJson).toList(growable: false),
          total: total,
          isPaginated: true,
        );
      }
    }

    return (items: const <FileInfo>[], total: null, isPaginated: false);
  }

  KnowledgeBaseItem _knowledgeEntryToItem(Map<String, dynamic> file) {
    if (file.containsKey('title')) {
      return KnowledgeBaseItem.fromJson(file);
    }
    final meta = _coerceJsonMap(file['meta']) ?? const <String, dynamic>{};
    final filename =
        _normalizeDynamicString(file['filename']) ??
        _normalizeDynamicString(file['name']) ??
        _normalizeDynamicString(meta['filename']) ??
        _normalizeDynamicString(meta['name']) ??
        'Unknown';
    String? nonBlankContent(dynamic value) {
      final text = value?.toString();
      if (text == null || text.trim().isEmpty) {
        return null;
      }
      return text;
    }

    final dataMap = _coerceJsonMap(file['data']);
    final content =
        nonBlankContent(file['content']) ??
        nonBlankContent(file['text']) ??
        nonBlankContent(dataMap?['content']) ??
        nonBlankContent(dataMap?['text']) ??
        '';
    return KnowledgeBaseItem.fromJson({
      'id': file['id'],
      'content': content,
      'title': filename,
      'created_at': file['created_at'] ?? file['createdAt'],
      'updated_at':
          file['updated_at'] ?? file['updatedAt'] ?? file['created_at'],
      'metadata': {
        ...meta,
        'filename': filename,
        if (file['hash'] != null) 'hash': file['hash'],
        if (file['content_hash'] != null) 'content_hash': file['content_hash'],
      },
    });
  }

  bool _shouldFallbackToLegacyKnowledgeApi(DioException error) {
    final statusCode = error.response?.statusCode;
    return statusCode == 404 ||
        statusCode == 405 ||
        statusCode == 422 ||
        (statusCode == 400 && _looksLikeLegacyShapeError(error.response?.data));
  }

  bool _looksLikeLegacyShapeError(dynamic data) {
    final detail = data is Map
        ? data['detail']?.toString()
        : data is String
        ? data
        : null;
    final normalized = detail?.toLowerCase() ?? '';
    return normalized.contains('invalid body') ||
        normalized.contains('field required') ||
        normalized.contains('extra') ||
        normalized.contains('schema') ||
        normalized.contains('validation');
  }

  void _setChatRequestMetadataFormatFromVersion(dynamic rawVersion) {
    final inferred = _inferChatRequestMetadataFormatFromVersion(rawVersion);
    if (inferred != null) {
      _chatRequestMetadataFormat = inferred;
    }
  }

  _ChatRequestMetadataFormat? _inferChatRequestMetadataFormatFromVersion(
    dynamic rawVersion,
  ) {
    final version = rawVersion?.toString().trim();
    if (version == null || version.isEmpty) {
      return null;
    }

    final match = RegExp(r'(\d+)\.(\d+)').firstMatch(version);
    if (match == null) {
      return null;
    }

    final major = int.tryParse(match.group(1)!);
    final minor = int.tryParse(match.group(2)!);
    if (major == null || minor == null) {
      return null;
    }

    if (major > 0 || minor >= 9) {
      return _ChatRequestMetadataFormat.modernV09;
    }

    return _ChatRequestMetadataFormat.legacyPreV09;
  }

  // Audio
  Future<({String? voice, String? splitOn, List<BackendTtsVoice> voices})>
  _loadServerAudioConfig() async {
    String? voice;
    String? splitOn;

    try {
      _traceApi('Fetching server TTS defaults');
      final response = await _dio.get('/api/v1/audio/config');
      final data = response.data;
      final config = _coerceJsonMap(data);
      final ttsConfig = _coerceJsonMap(config?['tts']);
      final rawVoice = ttsConfig?['VOICE'] ?? ttsConfig?['voice'];
      final rawSplitOn = ttsConfig?['SPLIT_ON'] ?? ttsConfig?['split_on'];
      voice = _normalizeDynamicString(rawVoice);
      splitOn = _normalizeDynamicString(rawSplitOn);
    } catch (e, stackTrace) {
      DebugLogger.error(
        'backend-config-audio-defaults',
        scope: 'api/config',
        error: e,
        stackTrace: stackTrace,
      );
    }

    final voices = await _loadServerTtsVoicesOrEmpty();
    return (voice: voice, splitOn: splitOn, voices: voices);
  }

  Future<List<BackendTtsVoice>> _loadServerTtsVoicesOrEmpty() async {
    try {
      return await _loadServerTtsVoicesFromAudioEndpoint();
    } catch (e, stackTrace) {
      DebugLogger.error(
        'backend-config-audio-voices',
        scope: 'api/config',
        error: e,
        stackTrace: stackTrace,
      );
      return const [];
    }
  }

  Future<List<BackendTtsVoice>> _loadServerTtsVoicesFromAudioEndpoint() async {
    _traceApi('Fetching server TTS voices');
    final response = await _dio.get('/api/v1/audio/voices');
    final data = response.data;
    if (data is Map<String, dynamic>) {
      final voices = data['voices'];
      if (voices is List) {
        final normalized = await _normalizeList(
          voices,
          debugLabel: 'parse_voice_list',
        );
        return normalized
            .map(BackendTtsVoice.fromJson)
            .where((voice) => voice.name.isNotEmpty)
            .toList(growable: false);
      }
    }
    if (data is List) {
      return data
          .map((e) => BackendTtsVoice(id: e.toString(), name: e.toString()))
          .toList(growable: false);
    }
    return const [];
  }

  Uint8List _coerceAudioBytes(Object? data) {
    if (data is Uint8List && data.isNotEmpty) {
      return Uint8List.fromList(data);
    }
    if (data is List<int>) {
      return Uint8List.fromList(data);
    }
    if (data is List) {
      return Uint8List.fromList(data.cast<int>());
    }
    return Uint8List(0);
  }

  String _resolveAudioMimeType(String? rawMimeType, Uint8List bytes) {
    final sanitized = rawMimeType?.split(';').first.trim();
    if (sanitized != null && sanitized.isNotEmpty) {
      return sanitized;
    }
    if (_matchesPrefix(bytes, const [0x52, 0x49, 0x46, 0x46]) &&
        _matchesPrefix(bytes, const [0x57, 0x41, 0x56, 0x45], offset: 8)) {
      return 'audio/wav';
    }
    if (_matchesPrefix(bytes, const [0x4F, 0x67, 0x67, 0x53])) {
      return 'audio/ogg';
    }
    if (_matchesPrefix(bytes, const [0x66, 0x4C, 0x61, 0x43])) {
      return 'audio/flac';
    }
    if (_looksLikeMp4(bytes)) {
      return 'audio/mp4';
    }
    if (_looksLikeMpeg(bytes)) {
      return 'audio/mpeg';
    }
    return 'audio/mpeg';
  }

  bool _matchesPrefix(Uint8List bytes, List<int> signature, {int offset = 0}) {
    if (bytes.length < offset + signature.length) {
      return false;
    }
    for (var i = 0; i < signature.length; i++) {
      if (bytes[offset + i] != signature[i]) {
        return false;
      }
    }
    return true;
  }

  bool _looksLikeMp4(Uint8List bytes) {
    return bytes.length >= 8 &&
        _matchesPrefix(bytes, const [0x66, 0x74, 0x79, 0x70], offset: 4);
  }

  bool _looksLikeMpeg(Uint8List bytes) {
    if (bytes.length >= 3 &&
        bytes[0] == 0x49 &&
        bytes[1] == 0x44 &&
        bytes[2] == 0x33) {
      return true;
    }
    return bytes.length >= 2 && bytes[0] == 0xFF && (bytes[1] & 0xE0) == 0xE0;
  }

  String _inferMimeTypeFromName(String name) {
    final dotIndex = name.lastIndexOf('.');
    if (dotIndex == -1 || dotIndex == name.length - 1) {
      return 'audio/mpeg';
    }
    final ext = name.substring(dotIndex + 1).toLowerCase();
    switch (ext) {
      case 'wav':
        return 'audio/wav';
      case 'ogg':
        return 'audio/ogg';
      case 'm4a':
      case 'mp4':
        return 'audio/mp4';
      case 'aac':
        return 'audio/aac';
      case 'webm':
        return 'audio/webm';
      case 'flac':
        return 'audio/flac';
      case 'mp3':
        return 'audio/mpeg';
      default:
        return 'audio/mpeg';
    }
  }

  MediaType? _parseMediaType(String? value) {
    if (value == null || value.isEmpty) {
      return null;
    }
    try {
      return MediaType.parse(value);
    } catch (_) {
      return null;
    }
  }

  Map<String, dynamic> _workspaceListQuery({
    String? query,
    String? viewOption,
    String? tag,
    String? orderBy,
    String? direction,
    int page = 1,
  }) => <String, dynamic>{
    'page': page,
    if (query != null && query.isNotEmpty) 'query': query,
    if (viewOption != null && viewOption.isNotEmpty) 'view_option': viewOption,
    if (tag != null && tag.isNotEmpty) 'tag': tag,
    if (orderBy != null && orderBy.isNotEmpty) 'order_by': orderBy,
    if (direction != null && direction.isNotEmpty) 'direction': direction,
  };
  Future<List<Map<String, dynamic>>> _hydrateChannelMessageDataList(
    String channelId,
    List<Map<String, dynamic>> messages,
  ) {
    if (!messages.any((message) => message['data'] == true)) {
      return Future.value(messages);
    }
    return Future.wait(
      messages.map((message) => _hydrateChannelMessageData(channelId, message)),
    );
  }

  Future<Map<String, dynamic>> _hydrateChannelMessageData(
    String channelId,
    Map<String, dynamic> message,
  ) async {
    if (message['data'] != true) {
      return message;
    }

    final messageId = message['id'];
    if (messageId is! String || messageId.isEmpty) {
      return message;
    }

    try {
      final data = await getMessageData(channelId, messageId);
      if (data == null) {
        return message;
      }
      return {...message, 'data': data};
    } catch (error, stackTrace) {
      DebugLogger.error(
        'channel-message-data-hydrate-failed',
        scope: 'api/channels',
        error: error,
        stackTrace: stackTrace,
        data: {'channelId': channelId, 'messageId': messageId},
      );
      return message;
    }
  }

  // Chat streaming with conversation context
  // Track cancellable streaming requests by messageId for stop parity.
  // Widened from Map<String, CancelToken> to support both legacy CancelToken
  // cancellation and new abort-handle cancellation from sendMessageSession.
  final Map<String, Future<void> Function()> _streamCancelActions = {};
  // -----------------------------------------------------------------------
  // Payload construction (shared by legacy and new transport-aware path)
  // -----------------------------------------------------------------------

  /// Builds the JSON payload for a chat completion request matching the
  /// OpenWebUI request shape.
  ///
  /// Both [_sendMessageLegacy] and [sendMessageSession] delegate here so
  /// the wire format stays in sync.
  Map<String, dynamic> _buildChatCompletionPayload({
    required List<Map<String, dynamic>> messages,
    required String model,
    required String messageId,
    String? sessionId,
    String? conversationId,
    String? terminalId,
    List<String>? toolIds,
    List<String>? filterIds,
    List<String>? skillIds,
    bool enableWebSearch = false,
    bool enableImageGeneration = false,
    bool enableCodeInterpreter = false,
    bool isVoiceMode = false,
    Map<String, dynamic>? modelItem,
    List<Map<String, dynamic>>? toolServers,
    Map<String, dynamic>? backgroundTasks,
    Map<String, dynamic>? userSettings,
    String? reasoningEffort,
    String? parentId,
    Map<String, dynamic>? userMessage,
    Map<String, dynamic>? variables,
    List<Map<String, dynamic>>? files,
    _ChatRequestMetadataFormat metadataFormat =
        _ChatRequestMetadataFormat.modernV09,
  }) {
    bool isImageFile(Map<String, dynamic> file) {
      if (file['type'] == 'image') {
        return true;
      }
      final contentType = file['content_type']?.toString() ?? '';
      return contentType.startsWith('image/');
    }

    // Process messages to match OpenWebUI format
    final processedMessages = messages.map((message) {
      final role = message['role'] as String;
      final content = message['content'];
      final output = message['output'];
      final rawFiles = message['files'];
      final files = rawFiles is List
          ? rawFiles.whereType<Map<String, dynamic>>().toList()
          : <Map<String, dynamic>>[];

      final isContentArray = content is List;
      final hasImages = files.isNotEmpty && files.any(isImageFile);
      final messageBase = <String, dynamic>{'role': role, 'output': ?output};

      if (isContentArray) {
        return {...messageBase, 'content': content};
      } else if (hasImages && role == 'user') {
        final imageFiles = files.where(isImageFile).toList();
        final contentText = content is String ? content : '';
        final contentArray = <Map<String, dynamic>>[
          {'type': 'text', 'text': contentText},
        ];
        for (final file in imageFiles) {
          contentArray.add({
            'type': 'image_url',
            'image_url': {'url': file['url']},
          });
        }
        return {...messageBase, 'content': contentArray};
      } else {
        final contentText = content is String ? content : '';
        return {...messageBase, 'content': contentText};
      }
    }).toList();

    String requestFileKey(Map<String, dynamic> file) {
      final id = file['id']?.toString().trim();
      if (id != null && id.isNotEmpty) {
        return 'id:$id';
      }

      final url = file['url']?.toString().trim();
      if (url != null && url.isNotEmpty) {
        return 'url:$url';
      }

      final type = file['type']?.toString().trim() ?? 'file';
      final name = file['name']?.toString().trim();
      if (name != null && name.isNotEmpty) {
        return 'name:$type:$name';
      }

      return 'json:${jsonEncode(file)}';
    }

    // Separate non-image files from explicit request files and messages.
    final allFiles = <Map<String, dynamic>>[];
    final seenFileKeys = <String>{};

    void addRequestFiles(Iterable<Map<String, dynamic>> requestFiles) {
      for (final file in requestFiles) {
        final normalizedFile = Map<String, dynamic>.from(file);
        if (isImageFile(normalizedFile)) {
          continue;
        }

        final fileKey = requestFileKey(normalizedFile);
        if (seenFileKeys.add(fileKey)) {
          allFiles.add(normalizedFile);
        }
      }
    }

    if (files != null && files.isNotEmpty) {
      addRequestFiles(files);
    }
    for (final message in messages) {
      final rawFiles = message['files'];
      if (rawFiles is List) {
        addRequestFiles(rawFiles.whereType<Map<String, dynamic>>());
      }
    }

    // Build request data
    final data = <String, dynamic>{
      'stream': true,
      'model': model,
      if (processedMessages.isNotEmpty) 'messages': processedMessages,
      'params': <String, dynamic>{},
    };

    // Request usage statistics if model supports it (issue #274)
    final supportsUsage =
        modelItem?['capabilities']?['usage'] == true ||
        (modelItem?['info'] as Map?)?['meta']?['capabilities']?['usage'] ==
            true;
    if (supportsUsage) {
      data['stream_options'] = {'include_usage': true};
    }

    // Forward user model params (temperature, top_p, top_k, seed, etc.)
    // Mirrors OpenWebUI's: { ...$settings?.params, ...params, stop: getStopTokens() }
    final params = <String, dynamic>{};
    try {
      final raw = userSettings?['params'];
      final userParams = raw is Map ? Map<String, dynamic>.from(raw) : null;
      if (userParams != null && userParams.isNotEmpty) {
        params.addAll(userParams);
        // Normalize stop tokens: split comma-separated string into list
        final rawStop = params['stop'];
        if (rawStop is String && rawStop.isNotEmpty) {
          params['stop'] = rawStop
              .split(',')
              .map((s) => s.trim())
              .where((s) => s.isNotEmpty)
              .toList();
        }
        // Remove empty/null stop so the backend uses its own defaults
        if (params['stop'] is List && (params['stop'] as List).isEmpty) {
          params.remove('stop');
        }
      }
    } catch (_) {
      // Non-critical: proceed without user params
    }

    // The user's per-model pick is the chat-level `params` the web client
    // spreads after `$settings.params`. Sent explicitly, it reaches the
    // server as a top-level form field, so the model's configured
    // `reasoning_effort` default is skipped (apply_model_params_to_body only
    // fills keys absent from the body).
    if (reasoningEffort != null) {
      params['reasoning_effort'] = reasoningEffort;
    }

    final modelInfo = modelItem?['info'];
    final openAiModel = modelItem?['openai'];
    final effort = params['reasoning_effort'];
    final isAutomaticEffort =
        effort is String && effort.trim().toLowerCase() == 'automatic';
    final supportsReasoningEffort = modelSupportsReasoningEffort(
      modelId: model,
      supportedParameters: modelItem?['supported_parameters'],
      capabilities: _coerceJsonMap(modelItem?['capabilities']),
      metadata: <String, dynamic>{
        'params': modelItem?['params'],
        'info': modelInfo,
        'base_model_id':
            modelItem?['base_model_id'] ??
            (openAiModel is Map ? openAiModel['id'] : null),
      },
    );
    if (isAutomaticEffort || !supportsReasoningEffort) {
      params.remove('reasoning_effort');
    }
    data['params'] = params;

    // Include model_item with real server routing data (pipe, actions,
    // filters, etc.). This is critical for pipe models which need
    // model_item.pipe to be routed to the pipe function on the backend.
    if (modelItem != null) {
      data['model_item'] = modelItem;
    }

    // Feature flags via 'features' object (not top-level params).
    // Mirror the web client by always sending the base feature flags, even
    // when disabled, so pipes receive a stable request shape.
    final uiMemorySettings = userSettings?['ui'] as Map<String, dynamic>?;
    final bool memoryEnabled = uiMemorySettings?['memory'] == true;

    final features = <String, dynamic>{
      'voice': isVoiceMode,
      'web_search': enableWebSearch,
      'image_generation': enableImageGeneration,
      'code_interpreter': enableCodeInterpreter,
    };
    if (memoryEnabled) features['memory'] = true;
    data['features'] = features;
    if (enableWebSearch) {
      _traceApi('Web search enabled in streaming request');
    }
    if (enableImageGeneration) {
      _traceApi('Image generation enabled in streaming request');
    }
    if (enableCodeInterpreter) {
      _traceApi('Code interpreter enabled in streaming request');
    }
    if (memoryEnabled) {
      _traceApi('Memory enabled in streaming request (from user settings)');
    }

    // Template variables for prompt substitution ({{USER_NAME}}, etc.)
    data['variables'] = variables ?? <String, dynamic>{};

    // Add filter_ids if provided (Open-WebUI toggle filters)
    if (filterIds != null && filterIds.isNotEmpty) {
      data['filter_ids'] = filterIds;
      _traceApi('Including filter_ids in streaming request: $filterIds');
    }

    // Add skill_ids if provided (extracted from @-mentions in the message)
    if (skillIds != null && skillIds.isNotEmpty) {
      data['skill_ids'] = skillIds;
      _traceApi('Including skill_ids in streaming request: $skillIds');
    }

    // Add tool_ids if provided
    if (toolIds != null && toolIds.isNotEmpty) {
      data['tool_ids'] = toolIds;
      _traceApi('Including tool_ids in streaming request: $toolIds');

      try {
        final userParams = userSettings?['params'] as Map<String, dynamic>?;
        final functionCallingMode = userParams?['function_calling'] as String?;
        if (functionCallingMode != null) {
          final params =
              (data['params'] as Map<String, dynamic>?) ?? <String, dynamic>{};
          params['function_calling'] = functionCallingMode;
          data['params'] = params;
          _traceApi(
            'Set params.function_calling = $functionCallingMode '
            '(from user settings)',
          );
        } else {
          _traceApi(
            'No function_calling preference in user settings, '
            'backend will use default mode',
          );
        }
      } catch (_) {
        // Non-fatal; continue without setting function_calling mode
      }
    }

    data['tool_servers'] = toolServers ?? <Map<String, dynamic>>[];
    if (toolServers != null && toolServers.isNotEmpty) {
      _traceApi('Including tool_servers in request (${toolServers.length})');
    }

    if (allFiles.isNotEmpty) {
      data['files'] = allFiles;
      _traceApi('Including non-image files in request: ${allFiles.length}');
    }

    // Attach identifiers — only include session_id when a real socket
    // connection exists. Omitting it makes the backend return SSE directly
    // instead of creating an async task that emits to a dead session.
    if (sessionId != null) {
      data['session_id'] = sessionId;
    }
    data['id'] = messageId;
    if (conversationId != null) {
      data['chat_id'] = conversationId;
    }
    if (terminalId != null && terminalId.isNotEmpty) {
      data['terminal_id'] = terminalId;
    }
    // No conversation means no chat management, and the server reads that
    // from `parent_id` being *absent*, not null. Its three cases are: null
    // with no chat id creates a new chat, a value continues one, and absent
    // is a plain completion. A null `parent_id` with no `chat_id` therefore
    // asked it to create a chat it then had no id to save, and it answered
    // with a JSON null body instead of a stream. That is every
    // conversation-less completion this client sent: the desktop's
    // temporary chats, and any headless caller.
    final hasConversation =
        conversationId != null && conversationId.trim().isNotEmpty;
    if (!hasConversation) {
      data['background_tasks'] = backgroundTasks ?? <String, dynamic>{};
      _traceApi('Payload keys (no conversation): ${data.keys.toList()}');
      return data;
    }
    switch (metadataFormat) {
      case _ChatRequestMetadataFormat.modernV09:
        // Match OpenWebUI 0.9+'s request shape: `parent_id` is the user
        // message's parent (the grandparent of the pending assistant
        // response), and `user_message` is the full OpenWebUI-style user
        // message object.
        data['parent_id'] = parentId;
        data['user_message'] = userMessage ?? <String, dynamic>{};
      case _ChatRequestMetadataFormat.legacyPreV09:
        // OpenWebUI <0.9 expects the full message under `parent_message`,
        // while `parent_id` points at the current user message id.
        final legacyParentId = userMessage?['id']?.toString().trim();
        data['parent_id'] = legacyParentId != null && legacyParentId.isNotEmpty
            ? legacyParentId
            : parentId;
        if (userMessage != null) {
          data['parent_message'] = userMessage;
        }
    }

    data['background_tasks'] = backgroundTasks ?? <String, dynamic>{};

    // Diagnostic: log the full payload for pipe model debugging
    _traceApi(
      'Payload keys: ${data.keys.toList()}, '
      'has model_item: ${data.containsKey('model_item')}, '
      'has pipe: ${(data['model_item'] as Map?)?['pipe']}, '
      'has session_id: ${data.containsKey('session_id')}',
    );

    return data;
  }

  bool _isUnsupportedModernChatMetadataError(String error) {
    final normalized = error.toLowerCase();
    if (!normalized.contains('user_message')) {
      return false;
    }

    return normalized.contains('unsupported') ||
        normalized.contains('extra_forbidden') ||
        normalized.contains('extra inputs') ||
        normalized.contains('not permitted');
  }

  ChatCompletionSession _recoverJsonNullChatCompletion({
    required String messageId,
    String? sessionId,
    String? conversationId,
    required Future<void> Function() abort,
  }) {
    final persistedChatId = conversationId?.trim();
    if (persistedChatId == null ||
        persistedChatId.isEmpty ||
        persistedChatId.startsWith('local:')) {
      throw const FormatException(
        'Cannot recover a JSON null chat completion without a persisted '
        'conversation ID',
      );
    }
    DebugLogger.warning(
      'json-null-recovery',
      scope: 'api/chat',
      data: {'chatId': persistedChatId, 'messageId': messageId},
    );
    return ChatCompletionSession.httpStream(
      messageId: messageId,
      sessionId: sessionId,
      conversationId: conversationId,
      byteStream: const Stream<List<int>>.empty(),
      abort: abort,
    );
  }

  /// Classifies a fully-parsed JSON body as taskSocket or jsonCompletion.
  ChatCompletionSession _classifyJsonBody(
    Map<String, dynamic> json, {
    required String messageId,
    String? sessionId,
    String? conversationId,
    required Future<void> Function() abort,
  }) {
    String? taskId;
    if (json['task_id'] != null) {
      taskId = json['task_id'].toString();
    } else {
      final rawTaskIds = json['task_ids'];
      if (rawTaskIds is List) {
        final taskIds = rawTaskIds
            .map((taskId) => taskId?.toString().trim() ?? '')
            .where((taskId) => taskId.isNotEmpty)
            .toList(growable: false);
        if (taskIds.isNotEmpty) {
          taskId = taskIds.first;
        }
      }
    }

    if (taskId != null) {
      _traceApi(
        'classifyChatCompletionResponse → taskSocket '
        '(task_id=$taskId)',
      );
      return ChatCompletionSession.taskSocket(
        messageId: messageId,
        sessionId: sessionId,
        conversationId: conversationId,
        taskId: taskId,
        abort: abort,
      );
    }

    _traceApi('classifyChatCompletionResponse → jsonCompletion');
    return ChatCompletionSession.jsonCompletion(
      messageId: messageId,
      sessionId: sessionId,
      conversationId: conversationId,
      jsonPayload: json,
    );
  }
  // -----------------------------------------------------------------------
  // Internal helpers for response classification
  // -----------------------------------------------------------------------

  /// Attempts to decode a non-2xx response body into a human-readable
  /// error string.
  Future<String> _decodeChatCompletionError(Response<ResponseBody> resp) async {
    try {
      final bytes = await _collectBytes(resp.data!.stream);
      final text = utf8.decode(bytes, allowMalformed: true);
      final json = _tryParseJsonMap(text);
      if (json != null) {
        return json['error']?.toString() ?? json['detail']?.toString() ?? text;
      }
      return text;
    } catch (_) {
      return 'status ${resp.statusCode}';
    }
  }

  /// Buffers the full stream into a JSON map, permits literal `null`, or throws.
  Future<Map<String, dynamic>?> _requireJsonMapOrNull(
    Stream<List<int>> stream,
  ) async {
    final bytes = await _collectBytes(stream);
    final text = utf8.decode(bytes, allowMalformed: true);
    final decoded = jsonDecode(text);
    if (decoded == null) return null;
    if (decoded is Map<String, dynamic>) {
      return decoded;
    }
    throw FormatException('Expected JSON object, got ${decoded.runtimeType}');
  }

  /// Tries to parse [text] as a JSON map, returning `null` on failure.
  Map<String, dynamic>? _tryParseJsonMap(String text) {
    try {
      final decoded = jsonDecode(text);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
    } on FormatException catch (_) {
      // Incomplete or malformed JSON.
    }
    return null;
  }

  /// Collects all bytes from [stream] into a single list.
  Future<List<int>> _collectBytes(Stream<List<int>> stream) async {
    final chunks = <List<int>>[];
    await for (final chunk in stream) {
      chunks.add(chunk);
    }
    if (chunks.isEmpty) return const [];
    if (chunks.length == 1) return chunks.first;
    final total = chunks.fold<int>(0, (s, c) => s + c.length);
    final result = Uint8List(total);
    var offset = 0;
    for (final chunk in chunks) {
      result.setRange(offset, offset + chunk.length, chunk);
      offset += chunk.length;
    }
    return result;
  }

  /// Sniffs the first bytes of the body stream to determine whether it
  /// looks like SSE data or a JSON object.
  ///
  /// Returns a sealed [_SniffResult] so callers can pattern-match.
  Future<_SniffResult> _sniffChatCompletionBody(
    Stream<List<int>> stream,
  ) async {
    final buffered = <List<int>>[];
    final completer = Completer<_SniffResult>();
    late StreamSubscription<List<int>> sub;

    sub = stream.listen(
      (chunk) {
        buffered.add(chunk);
        final textSoFar = utf8.decode(
          buffered.expand((c) => c).toList(),
          allowMalformed: true,
        );

        // Check for SSE data prefix
        if (textSoFar.trimLeft().startsWith('data:')) {
          sub.pause();
          completer.complete(_SniffSse(buffered: buffered, rest: sub));
          return;
        }

        // Check for valid JSON
        final json = _tryParseJsonMap(textSoFar.trim());
        if (json != null) {
          sub.cancel();
          completer.complete(_SniffJson(json: json));
          return;
        }
        if (textSoFar.trim() == 'null') {
          sub.cancel();
          completer.complete(_SniffJson(json: null));
          return;
        }
      },
      onDone: () {
        if (!completer.isCompleted) {
          // Try one last time to parse the full buffered content as JSON
          final text = utf8.decode(
            buffered.expand((c) => c).toList(),
            allowMalformed: true,
          );
          final json = _tryParseJsonMap(text.trim());
          if (json != null) {
            completer.complete(_SniffJson(json: json));
          } else if (text.trim() == 'null') {
            completer.complete(_SniffJson(json: null));
          } else if (text.trimLeft().startsWith('data:')) {
            // Can't replay a done stream, but classify it correctly.
            completer.complete(_SniffSse(buffered: buffered, rest: null));
          } else {
            completer.completeError(
              StateError('Unable to classify chat completion response body'),
            );
          }
        }
      },
      onError: (Object e) {
        if (!completer.isCompleted) {
          completer.completeError(e);
        }
      },
    );

    return completer.future;
  }

  /// Reconstructs a byte stream from buffered chunks and an optional
  /// remaining subscription.
  Stream<List<int>> _replayStream(
    List<List<int>> buffered,
    StreamSubscription<List<int>>? rest,
  ) async* {
    for (final chunk in buffered) {
      yield chunk;
    }
    if (rest != null) {
      final controller = StreamController<List<int>>();
      rest
        ..onData(controller.add)
        ..onDone(controller.close)
        ..onError(controller.addError);
      rest.resume();
      yield* controller.stream;
    }
  }

  /// Set once the bulk active-chats endpoint returns 404 or 405. Open WebUI
  /// 0.11 removed that endpoint and exposes `active` on chat-list rows instead.
  /// Depending on the deployment's web fallback, the removed POST can surface
  /// as either status, so subsequent refreshes go straight to the list fallback.
  bool _activeChatsEndpointUnsupported = false;
  // Keep the total fallback ceiling at 20 requests while reserving capacity
  // for archived chats instead of allowing the regular list to consume all of
  // it before the archived endpoint is attempted.
  static const int _activeChatsListFallbackPageBudgetPerEndpoint = 10;

  /// Open WebUI 0.11 replacement for `/api/v1/tasks/active/chats`.
  ///
  /// The regular list includes pinned and folder chats when requested. If an
  /// id is not found there, also scan archived pages. Older servers omit the
  /// additive `active` field, which naturally degrades to an empty set.
  Future<Set<String>> _checkActiveChatsFromLists(List<String> chatIds) async {
    final remaining = chatIds.where((id) => id.isNotEmpty).toSet();
    final active = <String>{};
    if (remaining.isEmpty) return active;

    await _collectActiveChatsFromPagedList(
      endpoint: '/api/v1/chats/',
      remaining: remaining,
      active: active,
      queryParameters: const {'include_pinned': true, 'include_folders': true},
      pageBudget: _activeChatsListFallbackPageBudgetPerEndpoint,
    );
    if (remaining.isNotEmpty) {
      await _collectActiveChatsFromPagedList(
        endpoint: '/api/v1/chats/archived',
        remaining: remaining,
        active: active,
        queryParameters: const {'order_by': 'updated_at', 'direction': 'desc'},
        pageBudget: _activeChatsListFallbackPageBudgetPerEndpoint,
      );
    }
    return active;
  }

  Future<int> _collectActiveChatsFromPagedList({
    required String endpoint,
    required Set<String> remaining,
    required Set<String> active,
    required Map<String, dynamic> queryParameters,
    required int pageBudget,
  }) async {
    const serverPageSize = 60;
    const batchSize = 5;
    void collectRows(List<Map<String, dynamic>> rows) {
      for (final row in rows) {
        final id = row['id']?.toString();
        if (id == null || !remaining.remove(id)) continue;
        if (row['active'] == true) active.add(id);
      }
    }

    if (pageBudget <= 0) return 0;
    pageBudget -= 1;
    final firstResponse = await _dio.get(
      endpoint,
      queryParameters: {...queryParameters, 'page': 1},
    );
    final firstRows = _coerceRawMapList(firstResponse.data);
    collectRows(firstRows);
    if (remaining.isEmpty || firstRows.length < serverPageSize) {
      return pageBudget;
    }

    var page = 2;
    while (remaining.isNotEmpty && pageBudget > 0) {
      final futures = <Future<Response<dynamic>>>[];
      for (
        var i = 0;
        i < batchSize && pageBudget > 0 && remaining.isNotEmpty;
        i += 1, page += 1, pageBudget -= 1
      ) {
        futures.add(
          _dio.get(
            endpoint,
            queryParameters: {...queryParameters, 'page': page},
          ),
        );
      }
      final responses = await Future.wait(futures);
      var shortPageSeen = false;
      for (final response in responses) {
        final rows = _coerceRawMapList(response.data);
        collectRows(rows);
        if (rows.length < serverPageSize) shortPageSeen = true;
      }
      if (shortPageSeen) return pageBudget;
    }
    if (remaining.isNotEmpty) {
      DebugLogger.warning(
        'chat-list active-state fallback reached page limit',
        scope: 'api/tasks',
        data: {'endpoint': endpoint, 'remaining': remaining.length},
      );
    }
    return pageBudget;
  }
}

/// Shared by the base and by the chat/folder mixins.
///
/// Top-level rather than a static on [_ApiServiceBase]: a mixin cannot
/// reach the base's statics unqualified, but every part of this library
/// can see a private top-level function.
List<Map<String, dynamic>> _coerceRawMapList(Object? data) {
  Object? normalized = data;
  if (normalized is String && normalized.isNotEmpty) {
    normalized = jsonDecode(normalized);
  }
  if (normalized is! List) {
    throw FormatException('Expected JSON array response, got $normalized');
  }
  final rows = <Map<String, dynamic>>[];
  for (final item in normalized) {
    if (item is Map<String, dynamic>) {
      rows.add(item);
    } else if (item is Map) {
      rows.add(Map<String, dynamic>.from(item));
    } else {
      throw FormatException('Expected JSON object item, got $item');
    }
  }
  return rows;
}
