import 'dart:async';

import 'package:conduit/core/auth/webview_cookie_helper.dart';
import 'package:conduit/core/persistence/persistence_keys.dart';
import 'package:conduit/core/persistence/preferences_store.dart';
import 'package:conduit/core/providers/app_providers.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('apple website data clear set targets storage without cookies', () {
    expect(
      appleWebsiteDataTypesForTesting,
      containsAll(<WebsiteDataType>{
        WebsiteDataType.WKWebsiteDataTypeLocalStorage,
        WebsiteDataType.WKWebsiteDataTypeSessionStorage,
        WebsiteDataType.WKWebsiteDataTypeIndexedDBDatabases,
        WebsiteDataType.WKWebsiteDataTypeWebSQLDatabases,
        WebsiteDataType.WKWebsiteDataTypeOfflineWebApplicationCache,
        WebsiteDataType.WKWebsiteDataTypeFetchCache,
        WebsiteDataType.WKWebsiteDataTypeServiceWorkerRegistrations,
      }),
    );
    expect(
      appleWebsiteDataTypesForTesting,
      isNot(contains(WebsiteDataType.WKWebsiteDataTypeCookies)),
    );
  });

  test('WebView data operations remain serialized after async waits', () async {
    final releaseFirst = Completer<void>();
    final firstEntered = Completer<void>();
    final order = <String>[];
    addTearDown(() async {
      if (!releaseFirst.isCompleted) releaseFirst.complete();
      await WebViewCookieHelper.waitForPendingDataOperations();
    });

    final first = serializeWebViewDataOperationForTesting(() async {
      order.add('first-start');
      firstEntered.complete();
      await releaseFirst.future;
      order.add('first-end');
      return 1;
    });
    await firstEntered.future;
    final second = serializeWebViewDataOperationForTesting(() async {
      order.add('second');
      return 2;
    });

    await Future<void>.delayed(Duration.zero);
    expect(order, ['first-start']);
    releaseFirst.complete();

    expect(await first, 1);
    expect(await second, 2);
    await WebViewCookieHelper.waitForPendingDataOperations();
    expect(order, ['first-start', 'first-end', 'second']);
  });

  test('restart logout fence requires a successful full clear', () async {
    SharedPreferences.setMockInitialValues({
      PreferenceKeys.incompleteLogoutFence: true,
    });
    PreferencesStore.debugOverride(await SharedPreferences.getInstance());
    addTearDown(PreferencesStore.debugReset);

    expect(WebViewCookieHelper.requiresSuccessfulFullClear, isTrue);
  });

  test('older WebView recovery cannot erase a newer logout fence', () async {
    SharedPreferences.setMockInitialValues({
      PreferenceKeys.incompleteLogoutFence: true,
    });
    PreferencesStore.debugOverride(await SharedPreferences.getInstance());
    final container = ProviderContainer();
    final clearStarted = Completer<void>();
    final releaseClear = Completer<void>();
    addTearDown(() async {
      if (!releaseClear.isCompleted) releaseClear.complete();
      await resetWebViewCookieHelperForTesting();
      container.dispose();
      PreferencesStore.debugReset();
    });

    final olderRecovery = WebViewCookieHelper.ensurePendingLogoutDataCleared(
      clearAllDataForTesting: () async {
        clearStarted.complete();
        await releaseClear.future;
        return true;
      },
    );
    await clearStarted.future;

    final newerFencePersisted = await container
        .read(incompleteLogoutFenceProvider.notifier)
        .persist(true);
    expect(newerFencePersisted, isTrue);
    releaseClear.complete();

    expect(await olderRecovery, isTrue);
    expect(
      PreferencesStore.getBool(PreferenceKeys.incompleteLogoutFence),
      isTrue,
    );
  });

  test('only the newest full-clear completion releases its flag', () async {
    final firstEntered = Completer<void>();
    final releaseFirst = Completer<void>();
    final secondEntered = Completer<void>();
    final releaseSecond = Completer<void>();
    addTearDown(() async {
      if (!releaseFirst.isCompleted) releaseFirst.complete();
      if (!releaseSecond.isCompleted) releaseSecond.complete();
      await resetWebViewCookieHelperForTesting();
    });

    final first = requestFullWebViewClearForTesting(() async {
      firstEntered.complete();
      await releaseFirst.future;
      return true;
    });
    await firstEntered.future;
    final second = requestFullWebViewClearForTesting(() async {
      secondEntered.complete();
      await releaseSecond.future;
      return true;
    });

    releaseFirst.complete();
    expect(await first, isTrue);
    expect(webViewFullClearRequiredForTesting, isTrue);

    await secondEntered.future;
    releaseSecond.complete();
    expect(await second, isTrue);
    expect(webViewFullClearRequiredForTesting, isFalse);
  });

  group('verified cookie clearing', () {
    test('accepts an already-empty store when delete reports false', () async {
      expect(
        await deleteAllWebViewCookiesWithVerification(
          deleteAllCookies: () async => false,
          remainingCookieCount: () async => 0,
        ),
        isTrue,
      );
    });

    test('rejects false deletion when cookies remain', () async {
      expect(
        await deleteAllWebViewCookiesWithVerification(
          deleteAllCookies: () async => false,
          remainingCookieCount: () async => 1,
        ),
        isFalse,
      );
    });

    test('rejects platform deletion and verification failures', () async {
      expect(
        await deleteAllWebViewCookiesWithVerification(
          deleteAllCookies: () => Future<bool>.error(
            PlatformException(code: 'cookie-store-failed'),
          ),
          remainingCookieCount: () async => 0,
        ),
        isFalse,
      );
      expect(
        await deleteAllWebViewCookiesWithVerification(
          deleteAllCookies: () async => false,
          remainingCookieCount: () =>
              Future<int>.error(PlatformException(code: 'cookie-read-failed')),
        ),
        isFalse,
      );
    });

    test(
      'trusts a non-throwing delete when enumeration is unimplemented',
      () async {
        // Android: removeAllCookies returns false for an already-empty store
        // and getAllCookies is not implemented, so verification must not turn
        // the routine empty-store clear into a failure.
        expect(
          await deleteAllWebViewCookiesWithVerification(
            deleteAllCookies: () async => false,
            remainingCookieCount: () =>
                Future<int>.error(UnimplementedError('getAllCookies')),
          ),
          isTrue,
        );
      },
    );
  });
}
