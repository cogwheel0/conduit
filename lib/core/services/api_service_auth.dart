part of 'api_service.dart';

mixin _AuthApi on _ApiServiceBase {
  void updateAuthToken(String? token) {
    _authInterceptor.updateAuthToken(token);
  }

  /// Prevents a persisted reverse-proxy cookie from being attached to future
  /// requests. Used as a process-local logout fail-safe when durable config
  /// scrubbing cannot be confirmed.
  void setCookieCustomHeaderSuppressed(bool suppressed) {
    _authInterceptor.setCookieCustomHeaderSuppressed(suppressed);
  }

  /// Ensure interceptor callbacks stay in sync if they are set after construction
  void setAuthCallbacks({
    void Function()? onAuthTokenInvalid,
    Future<void> Function()? onTokenInvalidated,
  }) {
    if (onAuthTokenInvalid != null) {
      this.onAuthTokenInvalid = onAuthTokenInvalid;
      _authInterceptor.onAuthTokenInvalid = onAuthTokenInvalid;
    }
    if (onTokenInvalidated != null) {
      this.onTokenInvalidated = onTokenInvalidated;
      _authInterceptor.onTokenInvalidated = onTokenInvalidated;
    }
  }

  // Authentication
  Future<Map<String, dynamic>> login(String username, String password) async {
    try {
      final response = await _dio.post(
        '/api/v1/auths/signin',
        data: {'email': username, 'password': password},
      );

      return response.data;
    } catch (e) {
      if (e is DioException) {
        // Handle specific redirect cases
        if (e.response?.statusCode == 307 || e.response?.statusCode == 308) {
          final location = e.response?.headers.value('location');
          if (location != null) {
            throw Exception(
              'Server redirect detected. Please check your server URL configuration.',
            );
          }
        }
      }
      rethrow;
    }
  }

  Future<void> logout({ApiAuthSnapshot? authSnapshot}) async {
    await _dio.post(
      '/api/v1/auths/signout',
      options: _withAuthSnapshot(Options(), authSnapshot),
    );
  }

  /// LDAP authentication - uses username instead of email.
  ///
  /// Returns the same response format as regular login:
  /// `{"token": "...", "token_type": "Bearer", "id": "...", ...}`
  ///
  /// Throws an exception if LDAP is not enabled on the server (400 response).
  Future<Map<String, dynamic>> ldapLogin(
    String username,
    String password,
  ) async {
    try {
      final response = await _dio.post(
        '/api/v1/auths/ldap',
        data: {'user': username, 'password': password},
      );

      return response.data;
    } catch (e) {
      if (e is DioException) {
        // Handle LDAP not enabled
        if (e.response?.statusCode == 400) {
          final data = e.response?.data;
          if (data is Map &&
              data['detail'] == 'LDAP authentication is not enabled') {
            throw Exception('LDAP authentication is not enabled');
          }
          throw Exception('LDAP authentication failed');
        }
        // Handle specific redirect cases
        if (e.response?.statusCode == 307 || e.response?.statusCode == 308) {
          final location = e.response?.headers.value('location');
          if (location != null) {
            throw Exception(
              'Server redirect detected. Please check your server URL configuration.',
            );
          }
        }
      }
      rethrow;
    }
  }

  // User info
  Future<User> getCurrentUser({
    bool suppressAuthFailureNotification = false,
    String? candidateAuthToken,
    ApiAuthSnapshot? authSnapshot,
  }) async {
    final extra = <String, dynamic>{
      if (suppressAuthFailureNotification)
        'suppressAuthFailureNotification': true,
      ApiAuthInterceptor.candidateAuthTokenExtraKey: ?candidateAuthToken,
      ApiAuthInterceptor.authSnapshotExtraKey: ?authSnapshot,
    };
    final response = await _dio.get(
      '/api/v1/auths/',
      options: extra.isEmpty ? null : Options(extra: extra),
    );
    DebugLogger.log('user-info', scope: 'api/user');
    return User.fromJson(response.data);
  }

  Future<AccountMetadata> getAccountMetadata() async {
    final results = await Future.wait<dynamic>([
      _dio.get('/api/v1/auths/').then((response) => response.data),
      (() async {
        try {
          return (await _dio.get('/api/v1/users/user/info')).data;
        } catch (_) {
          return null;
        }
      })(),
    ]);

    final accountData = _coerceResponseMap(results[0]);
    if (accountData == null) {
      throw StateError('Unexpected account response type.');
    }

    return AccountMetadata.fromJson(
      accountData,
      info: _coerceResponseMap(results[1]),
    );
  }

  Future<void> updateUserInfo(Map<String, Object?> info) async {
    if (info.isEmpty) {
      return;
    }
    _traceApi('Updating user info');
    await _dio.post('/api/v1/users/user/info/update', data: info);
  }

  Future<AccountMetadata> updateAccountMetadata({
    required String name,
    required String profileImageUrl,
    String? bio,
    String? gender,
    String? dateOfBirth,
    String? timezone,
  }) async {
    final trimmedName = name.trim();
    if (trimmedName.isEmpty) {
      throw ArgumentError('name cannot be empty');
    }

    await _dio.post(
      '/api/v1/auths/update/profile',
      data: {
        'name': trimmedName,
        'profile_image_url': profileImageUrl.trim(),
        'bio': _normalizeNullableString(bio),
        'gender': _normalizeNullableString(gender),
        'date_of_birth': _normalizeNullableString(dateOfBirth),
      },
    );

    if (timezone != null) {
      await _dio.post(
        '/api/v1/auths/update/timezone',
        data: {'timezone': timezone.trim()},
      );
    }

    return getAccountMetadata();
  }

  Future<void> updateAccountPassword({
    required String password,
    required String newPassword,
  }) async {
    await _dio.post(
      '/api/v1/auths/update/password',
      data: {'password': password, 'new_password': newPassword},
    );
  }

  Future<WorkspacePagedResponse<WorkspacePrincipalPreview>>
  searchWorkspaceUsers(String query, {int page = 1}) async {
    final response = await _dio.get(
      '/api/v1/users/search',
      queryParameters: {'query': query, 'page': page},
    );
    return WorkspacePagedResponse.fromJson(
      response.data,
      WorkspacePrincipalPreview.user,
    );
  }

  Future<List<WorkspacePrincipalPreview>> getWorkspaceGroups() async {
    final response = await _dio.get('/api/v1/groups/');
    return workspaceJsonList(response.data)
        .map(WorkspacePrincipalPreview.group)
        .toList(growable: false);
  }

  // Permissions & Features
  Future<Map<String, dynamic>> getUserPermissions() async {
    _traceApi('Fetching user permissions');
    try {
      final response = await _dio.get('/api/v1/users/permissions');
      return response.data as Map<String, dynamic>;
    } catch (e) {
      _traceApi('Error fetching user permissions: $e');
      if (e is DioException) {
        _traceApi('Permissions error response: ${e.response?.data}');
        _traceApi('Permissions error status: ${e.response?.statusCode}');
      }
      rethrow;
    }
  }
}
