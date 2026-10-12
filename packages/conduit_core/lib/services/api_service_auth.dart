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

  // Two-step verification (Open WebUI 0.12 `/api/v1/auths/mfa`). Each call
  // carries only the challenge token a sign-in answered with; none of them is
  // a session, so a refusal never reports the session as ended.

  /// Starts adding an authenticator for an `enroll` step: the secret to add.
  Future<OpenWebUiTwoStepSetup> startTwoStepEnrollment(
    String challengeToken,
  ) async {
    final data = await _postTwoStep('enroll/start', {
      'challenge_token': challengeToken,
    });
    final key = data['manual_key'];
    final qr = data['qr_code'];
    if (key is! String || key.isEmpty) {
      throw const OpenWebUiTwoStepException(OpenWebUiTwoStepFailure.failed);
    }
    return OpenWebUiTwoStepSetup(
      manualKey: key,
      qrCode: qr is String ? qr : '',
    );
  }

  /// Confirms the new authenticator with a [code] from it. The session comes
  /// with the account's recovery codes, shown only this once.
  Future<OpenWebUiTwoStepSession> confirmTwoStepEnrollment(
    String challengeToken,
    String code,
  ) async {
    final data = await _postTwoStep('enroll/confirm', {
      'challenge_token': challengeToken,
      'code': code,
    });
    return _twoStepSession(data);
  }

  /// Answers a `verify` step with an authenticator [code], or with one of the
  /// account's recovery codes when [recovery] is set.
  Future<OpenWebUiTwoStepSession> verifyTwoStepCode(
    String challengeToken,
    String code, {
    bool recovery = false,
  }) async {
    final data = await _postTwoStep('verify', {
      'challenge_token': challengeToken,
      'code': code,
      'recovery': recovery,
    });
    return _twoStepSession(data);
  }

  /// Redeems an administrator's recovery token for a `recover` step. The
  /// server answers with an `enroll` step for a new authenticator.
  Future<OpenWebUiTwoStepChallenge> redeemTwoStepResetToken(
    String challengeToken,
    String resetToken,
  ) async {
    final data = await _postTwoStep('recover', {
      'challenge_token': challengeToken,
      'reset_token': resetToken,
    });
    final challenge = OpenWebUiTwoStepChallenge.fromJson(data);
    if (challenge == null) {
      throw const OpenWebUiTwoStepException(OpenWebUiTwoStepFailure.failed);
    }
    return challenge;
  }

  OpenWebUiTwoStepSession _twoStepSession(Map<String, dynamic> data) {
    final token = data['token'];
    if (token is! String || token.isEmpty) {
      throw const OpenWebUiTwoStepException(OpenWebUiTwoStepFailure.failed);
    }
    final codes = data['recovery_codes'];
    return OpenWebUiTwoStepSession(
      token: token,
      recoveryCodes: codes is List
          ? [for (final code in codes) code.toString()]
          : const <String>[],
    );
  }

  Future<Map<String, dynamic>> _postTwoStep(
    String path,
    Map<String, dynamic> body,
  ) async {
    try {
      final response = await _dio.post(
        '/api/v1/auths/mfa/$path',
        data: body,
        options: Options(extra: {'suppressAuthFailureNotification': true}),
      );
      final data = response.data;
      if (data is Map) return Map<String, dynamic>.from(data);
    } on DioException catch (e) {
      final data = e.response?.data;
      final failure = classifyOpenWebUiTwoStepError(
        e.response?.statusCode,
        data is Map ? data['detail'] : null,
      );
      DebugLogger.warning(
        'two-step-refused',
        scope: 'auth/mfa',
        data: {
          'step': path,
          'status': e.response?.statusCode,
          'failure': failure.name,
        },
      );
      throw OpenWebUiTwoStepException(failure);
    }
    throw const OpenWebUiTwoStepException(OpenWebUiTwoStepFailure.failed);
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
  searchWorkspaceUsers(
    String query, {
    int page = 1,
    ApiAuthSnapshot? authSnapshot,
  }) async {
    final response = await _dio.get(
      '/api/v1/users/search',
      queryParameters: {'query': query, 'page': page},
      options: _withAuthSnapshot(Options(), authSnapshot),
    );
    return WorkspacePagedResponse.fromJson(
      response.data,
      WorkspacePrincipalPreview.user,
    );
  }

  Future<List<WorkspacePrincipalPreview>> getWorkspaceGroups({
    ApiAuthSnapshot? authSnapshot,
  }) async {
    final response = await _dio.get(
      '/api/v1/groups/',
      options: _withAuthSnapshot(Options(), authSnapshot),
    );
    return workspaceJsonList(response.data)
        .map(WorkspacePrincipalPreview.group)
        .toList(growable: false);
  }

  /// Reads the name and email of one user, the way Open WebUI's access editor
  /// names the people a resource is shared with (`GET /users/{id}/info`, open
  /// to any verified user).
  ///
  /// Returns null when the server has no such user (it answers 400) or will
  /// not describe them (403/404). Any other failure is thrown, so a caller
  /// that caches answers can ask again later.
  Future<WorkspacePrincipalPreview?> getWorkspaceUserInfo(
    String userId, {
    ApiAuthSnapshot? authSnapshot,
  }) async {
    try {
      final response = await _dio.get(
        '/api/v1/users/${Uri.encodeComponent(userId)}/info',
        options: _withAuthSnapshot(Options(), authSnapshot),
      );
      final data = response.data;
      if (data is! Map) return null;
      final preview = WorkspacePrincipalPreview.user(
        Map<String, dynamic>.from(data),
      );
      return preview.id == userId ? preview : null;
    } on DioException catch (error) {
      switch (error.response?.statusCode) {
        case 400 || 403 || 404:
          return null;
      }
      rethrow;
    }
  }

  // Permissions & Features
  Future<Map<String, dynamic>> getUserPermissions({
    ApiAuthSnapshot? authSnapshot,
  }) async {
    _traceApi('Fetching user permissions');
    try {
      final response = await _dio.get(
        '/api/v1/users/permissions',
        options: _withAuthSnapshot(Options(), authSnapshot),
      );
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
