import 'package:checks/checks.dart';
import 'package:conduit/features/release_notes/data/release_links.dart';
import 'package:conduit/features/release_notes/release_notes_presenter.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('iOS review action opens the App Store write-review URL', () async {
    final openedUrls = <String>[];

    await requestReleaseNotesReview(
      platform: TargetPlatform.iOS,
      launchReviewUrl: (url) async {
        openedUrls.add(url);
        return true;
      },
    );

    check(openedUrls).deepEquals([appleAppStoreReviewUrl]);
  });

  test('Android review action opens Google Play', () async {
    final openedUrls = <String>[];

    await requestReleaseNotesReview(
      platform: TargetPlatform.android,
      launchReviewUrl: (url) async {
        openedUrls.add(url);
        return true;
      },
    );

    check(openedUrls).deepEquals([googlePlayStoreUrl]);
  });

  test('macOS retains the Apple review URL behavior', () async {
    final openedUrls = <String>[];

    await requestReleaseNotesReview(
      platform: TargetPlatform.macOS,
      launchReviewUrl: (url) async {
        openedUrls.add(url);
        return true;
      },
    );

    check(openedUrls).deepEquals([appleAppStoreReviewUrl]);
  });
}
