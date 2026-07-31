import 'package:checks/checks.dart';
import 'package:conduit/features/release_notes/data/release_links.dart';
import 'package:conduit/features/release_notes/release_notes_presenter.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('iOS native success does not open a URL', () async {
    var nativeCalls = 0;
    final openedUrls = <String>[];

    await requestReleaseNotesReview(
      platform: TargetPlatform.iOS,
      requestNativeReview: () async {
        nativeCalls += 1;
        return true;
      },
      launchReviewUrl: (url) async {
        openedUrls.add(url);
        return true;
      },
    );

    check(nativeCalls).equals(1);
    check(openedUrls).isEmpty();
  });

  test('iOS native false falls back to the App Store URL', () async {
    final openedUrls = <String>[];

    await requestReleaseNotesReview(
      platform: TargetPlatform.iOS,
      requestNativeReview: () async => false,
      launchReviewUrl: (url) async {
        openedUrls.add(url);
        return true;
      },
    );

    check(openedUrls).deepEquals([appleAppStoreReviewUrl]);
  });

  test('iOS native exception falls back to the App Store URL', () async {
    final openedUrls = <String>[];

    await requestReleaseNotesReview(
      platform: TargetPlatform.iOS,
      requestNativeReview: () async => throw StateError('bridge failed'),
      launchReviewUrl: (url) async {
        openedUrls.add(url);
        return true;
      },
    );

    check(openedUrls).deepEquals([appleAppStoreReviewUrl]);
  });

  test('Android skips native review and opens Google Play', () async {
    var nativeCalls = 0;
    final openedUrls = <String>[];

    await requestReleaseNotesReview(
      platform: TargetPlatform.android,
      requestNativeReview: () async {
        nativeCalls += 1;
        return true;
      },
      launchReviewUrl: (url) async {
        openedUrls.add(url);
        return true;
      },
    );

    check(nativeCalls).equals(0);
    check(openedUrls).deepEquals([googlePlayStoreUrl]);
  });

  test('macOS retains the Apple review URL behavior', () async {
    var nativeCalls = 0;
    final openedUrls = <String>[];

    await requestReleaseNotesReview(
      platform: TargetPlatform.macOS,
      requestNativeReview: () async {
        nativeCalls += 1;
        return true;
      },
      launchReviewUrl: (url) async {
        openedUrls.add(url);
        return true;
      },
    );

    check(nativeCalls).equals(0);
    check(openedUrls).deepEquals([appleAppStoreReviewUrl]);
  });
}
