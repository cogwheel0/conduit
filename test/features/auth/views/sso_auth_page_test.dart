import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit/features/auth/views/sso_auth_page.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('refreshSsoAuthWebView', () {
    test('claims a new generation before refresh awaits', () {
      check(
        nextSsoAuthRefreshGeneration(
          tokenCaptureStarted: false,
          sessionResetInProgress: false,
          currentGeneration: 7,
        ),
      ).equals(8);
    });

    test('declines refresh once token handling has started', () {
      check(
        nextSsoAuthRefreshGeneration(
          tokenCaptureStarted: true,
          sessionResetInProgress: false,
          currentGeneration: 7,
        ),
      ).isNull();
    });

    test('declines overlapping refresh while session reset is active', () {
      check(
        nextSsoAuthRefreshGeneration(
          tokenCaptureStarted: false,
          sessionResetInProgress: true,
          currentGeneration: 7,
        ),
      ).isNull();
    });

    test(
      'retries full initialization when cleanup left no controller',
      () async {
        var initializeCalls = 0;
        var reloadCalls = 0;

        await refreshSsoAuthWebView<Object>(
          controller: null,
          initialize: () async => initializeCalls++,
          reload: (_, releaseSessionReset) async {
            reloadCalls++;
            releaseSessionReset();
          },
          setSessionResetInProgress: (_) {},
        );

        check(initializeCalls).equals(1);
        check(reloadCalls).equals(0);
      },
    );

    test('reloads an existing controller without rebuilding it', () async {
      final controller = Object();
      Object? reloadedController;
      var initializeCalls = 0;

      await refreshSsoAuthWebView<Object>(
        controller: controller,
        initialize: () async => initializeCalls++,
        reload: (value, releaseSessionReset) async {
          reloadedController = value;
          releaseSessionReset();
        },
        setSessionResetInProgress: (_) {},
      );

      check(initializeCalls).equals(0);
      check(reloadedController).identicalTo(controller);
    });

    test(
      'keeps token capture fenced through replacement load startup',
      () async {
        final controller = Object();
        final cookiesCleared = Completer<void>();
        final replacementLoadStarted = Completer<void>();
        var resetInProgress = false;
        final observedResetStates = <bool>[];

        final refresh = refreshSsoAuthWebView<Object>(
          controller: controller,
          initialize: () async {},
          setSessionResetInProgress: (value) {
            resetInProgress = value;
            observedResetStates.add(value);
          },
          reload: (_, releaseSessionReset) async {
            check(resetInProgress).isTrue();
            await cookiesCleared.future;
            check(resetInProgress).isTrue();
            replacementLoadStarted.complete();
            releaseSessionReset();
            check(resetInProgress).isFalse();
          },
        );

        check(resetInProgress).isTrue();
        cookiesCleared.complete();
        await replacementLoadStarted.future;
        check(resetInProgress).isFalse();
        await refresh;

        check(resetInProgress).isFalse();
        check(observedResetStates).deepEquals([true, false]);
      },
    );

    test('reload failure releases the token-capture fence', () async {
      var resetInProgress = false;

      await expectLater(
        refreshSsoAuthWebView<Object>(
          controller: Object(),
          initialize: () async {},
          reload: (_, _) async => throw StateError('load failed'),
          setSessionResetInProgress: (value) => resetInProgress = value,
        ),
        throwsStateError,
      );

      check(resetInProgress).isFalse();
    });

    test('reports a failed boundary when cookie clearing fails', () async {
      final ready = await prepareFreshSsoWebViewSession(
        clearCookies: () async => false,
        clearWebsiteData: () async => true,
      );

      check(ready).isFalse();
    });

    test('reports a ready boundary after verified cookie clearing', () async {
      final ready = await prepareFreshSsoWebViewSession(
        clearCookies: () async => true,
        clearWebsiteData: () async => true,
      );

      check(ready).isTrue();
    });

    test(
      'reports a failed boundary when website-data clearing fails',
      () async {
        var websiteDataClearCalls = 0;
        final ready = await prepareFreshSsoWebViewSession(
          clearCookies: () async => true,
          clearWebsiteData: () async {
            websiteDataClearCalls++;
            return false;
          },
        );

        check(ready).isFalse();
        check(websiteDataClearCalls).equals(1);
      },
    );
  });

  group('isTrustedSsoTokenCaptureUrl', () {
    test('allows callback paths on the exact configured origin', () {
      expect(
        isTrustedSsoTokenCaptureUrl(
          pageUrl: 'https://chat.example/api/v1/auths/callback/oidc',
          serverUrl: 'https://CHAT.example:443',
        ),
        isTrue,
      );
    });

    test('rejects same-host HTTPS to HTTP downgrade', () {
      expect(
        isTrustedSsoTokenCaptureUrl(
          pageUrl: 'http://chat.example/auth',
          serverUrl: 'https://chat.example',
        ),
        isFalse,
      );
    });

    test('rejects same-host alternate port', () {
      expect(
        isTrustedSsoTokenCaptureUrl(
          pageUrl: 'https://chat.example:444/auth',
          serverUrl: 'https://chat.example',
        ),
        isFalse,
      );
    });
  });

  group('isExpectedSsoRefreshLoadStart', () {
    test('accepts the expected replacement path on the exact origin', () {
      check(
        isExpectedSsoRefreshLoadStart(
          startedUrl: 'https://chat.example/auth?fresh=1',
          expectedUrl: 'https://CHAT.example:443/auth',
        ),
      ).isTrue();
    });

    test('rejects an outgoing page callback during session clearing', () {
      check(
        isExpectedSsoRefreshLoadStart(
          startedUrl: 'https://chat.example/chat/old',
          expectedUrl: 'https://chat.example/auth',
        ),
      ).isFalse();
    });
  });
}
