import 'package:flutter/widgets.dart';

import 'package:conduit_core/features/librechat/models/librechat_account.dart';
import 'package:conduit_core/features/librechat/models/librechat_cookies.dart';
import 'package:conduit_core/features/librechat/models/librechat_server.dart';
import 'package:conduit_core/features/librechat/models/librechat_server_info.dart';
import 'package:conduit_core/features/librechat/models/librechat_session.dart';
import 'package:conduit_core/features/librechat/services/librechat_auth_service.dart';
import 'package:conduit_core/features/librechat/services/librechat_errors.dart';
import 'package:conduit_core/features/librechat/services/librechat_probe.dart';
import 'package:conduit_core/utils/debug_logger.dart';
import 'package:dio/dio.dart';

/// Where adding a LibreChat account stands.
enum LibreChatSignInStep {
  /// Asking for the server's address.
  server,

  /// The server answered; offering its ways to sign in.
  methods,

  /// Waiting for an authenticator or backup code.
  twoFactor,
}

/// Why a step could not go on, for the form to word.
enum LibreChatSignInIssue {
  invalidAddress,
  unreachable,
  notLibreChat,
  isOpenWebUi,
  rejected,
  invalidCode,

  /// Google refuses sign-in inside an app's web view.
  googleUnsupported,

  /// A single sign-on page closed or failed before signing in.
  ssoUnfinished,

  /// Something else went wrong, such as saving the signed-in session.
  failed,
}

/// Saves a signed-in session as an account and returns it.
typedef LibreChatSaveSignedIn =
    Future<LibreChatAccount> Function({
      required LibreChatServer server,
      required LibreChatSession session,
      LibreChatServerInfo? info,
    });

/// Drives adding a LibreChat account: the address, then a password (local
/// or LDAP, with two-step verification) or single sign-on, then saving.
class LibreChatSignInController extends ChangeNotifier {
  LibreChatSignInController({
    required LibreChatSaveSignedIn saveSignedIn,
    HttpClientAdapter? adapter,
  }) : _saveSignedIn = saveSignedIn,
       _adapter = adapter;

  final LibreChatSaveSignedIn _saveSignedIn;
  final HttpClientAdapter? _adapter;

  final TextEditingController address = TextEditingController();
  final TextEditingController email = TextEditingController();
  final TextEditingController password = TextEditingController();
  final TextEditingController code = TextEditingController();

  LibreChatSignInStep step = LibreChatSignInStep.server;
  LibreChatServer? server;
  LibreChatServerInfo? info;

  /// The issue to show, with the server's own words when it gave some.
  LibreChatSignInIssue? issue;
  String? serverMessage;

  bool busy = false;

  /// Two-step verification by a backup code instead of the app's code.
  bool useBackupCode = false;

  String? _tempToken;
  bool _disposed = false;

  /// Starts at [baseUrl]: signing in again to an account whose session
  /// ended goes straight to its server's ways to sign in.
  Future<void> startAt(String baseUrl) {
    address.text = baseUrl;
    return probe();
  }

  /// Notes that Google sign-in was asked for, which cannot work here.
  void reportGoogleUnsupported() => _report(
    LibreChatSignInIssue.googleUnsupported,
  );

  /// Notes that a single sign-on page ended without signing in.
  void reportSingleSignOnUnfinished() => _report(
    LibreChatSignInIssue.ssoUnfinished,
  );

  /// Notes that the account signed in to could not be put in use.
  void reportFailed() => _report(LibreChatSignInIssue.failed);

  void _report(LibreChatSignInIssue value) {
    issue = value;
    serverMessage = null;
    _notify();
  }

  /// Checks the typed address and reads how to sign in there.
  Future<void> probe() => _run(() async {
    final baseUrl = LibreChatServer.normalizeBaseUrl(address.text);
    if (baseUrl == null) {
      issue = LibreChatSignInIssue.invalidAddress;
      return;
    }
    final candidate = LibreChatServer(baseUrl: baseUrl);
    final result = await probeLibreChatServer(candidate, adapter: _adapter);
    switch (result) {
      case LibreChatProbeFound(:final server, :final info):
        this.server = server;
        this.info = info;
        step = LibreChatSignInStep.methods;
      case LibreChatProbeNotLibreChat(:final looksLikeOpenWebUi):
        issue = looksLikeOpenWebUi
            ? LibreChatSignInIssue.isOpenWebUi
            : LibreChatSignInIssue.notLibreChat;
      case LibreChatProbeUnreachable():
        issue = LibreChatSignInIssue.unreachable;
    }
  });

  /// Signs in with the typed email (or LDAP username) and password.
  /// Returns the saved account, or null when another step is needed or it
  /// failed.
  Future<LibreChatAccount?> signIn() async {
    LibreChatAccount? account;
    await _run(() async {
      final auth = _auth();
      try {
        final result = await auth.signIn(
          email: email.text,
          password: password.text,
        );
        switch (result) {
          case LibreChatSignedIn(:final session):
            account = await _save(session);
          case LibreChatTwoFactorRequired(:final tempToken):
            _tempToken = tempToken;
            code.clear();
            step = LibreChatSignInStep.twoFactor;
        }
      } finally {
        auth.close();
      }
    });
    return account;
  }

  /// Finishes two-step verification with the typed code.
  Future<LibreChatAccount?> verifyCode() async {
    final tempToken = _tempToken;
    if (tempToken == null || code.text.trim().isEmpty) return null;
    LibreChatAccount? account;
    await _run(() async {
      final auth = _auth();
      try {
        final session = await auth.verifyTwoFactor(
          tempToken: tempToken,
          code: useBackupCode ? null : code.text,
          backupCode: useBackupCode ? code.text : null,
        );
        account = await _save(session);
      } on LibreChatApiException catch (error) {
        if (error.statusCode == 401) {
          issue = LibreChatSignInIssue.invalidCode;
          return;
        }
        rethrow;
      } finally {
        auth.close();
      }
    });
    return account;
  }

  /// Finishes single sign-on with the cookies the sign-in page left.
  Future<LibreChatAccount?> completeSingleSignOn(
    LibreChatCookies cookies,
  ) async {
    LibreChatAccount? account;
    await _run(() async {
      final auth = _auth();
      try {
        account = await _save(await auth.sessionFromCookies(cookies));
      } finally {
        auth.close();
      }
    });
    return account;
  }

  void toggleBackupCode() {
    useBackupCode = !useBackupCode;
    code.clear();
    issue = null;
    _notify();
  }

  /// Back a step: from the code to the methods, from the methods to the
  /// address.
  void back() {
    issue = null;
    serverMessage = null;
    code.clear();
    if (step == LibreChatSignInStep.twoFactor) {
      _tempToken = null;
      step = LibreChatSignInStep.methods;
    } else {
      // What was typed for this server is not sent to the next one.
      email.clear();
      password.clear();
      step = LibreChatSignInStep.server;
      server = null;
      info = null;
    }
    _notify();
  }

  LibreChatAuthService _auth() =>
      LibreChatAuthService(server!, adapter: _adapter);

  Future<LibreChatAccount> _save(LibreChatSession session) =>
      _saveSignedIn(server: server!, session: session, info: info);

  Future<void> _run(Future<void> Function() action) async {
    if (busy) return;
    busy = true;
    issue = null;
    serverMessage = null;
    _notify();
    try {
      await action();
    } on LibreChatApiException catch (error) {
      issue = LibreChatSignInIssue.rejected;
      serverMessage = error.message;
    } catch (error, stackTrace) {
      // Saving an accepted sign-in (secure storage, the account list) can
      // fail too; the form says so and the step can be tried again.
      DebugLogger.error(
        'librechat-sign-in-failed',
        scope: 'librechat/sign-in',
        error: error,
        stackTrace: stackTrace,
      );
      issue = LibreChatSignInIssue.failed;
    } finally {
      busy = false;
      _notify();
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    address.dispose();
    email.dispose();
    password.dispose();
    code.dispose();
    super.dispose();
  }
}
