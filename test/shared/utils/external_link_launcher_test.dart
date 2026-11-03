import 'package:conduit/shared/utils/external_link_launcher.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:url_launcher/url_launcher.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group('native browser presentation', () {
    late _BrowserPlatform platform;
    late InAppWebViewPlatform? previousPlatform;
    late List<MethodCall> launches;

    setUp(() {
      previousPlatform = InAppWebViewPlatform.instance;
      platform = _BrowserPlatform();
      InAppWebViewPlatform.instance = platform;
      launches = [];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/url_launcher'),
            (call) async {
              launches.add(call);
              return true;
            },
          );
    });
    tearDown(() {
      debugDefaultTargetPlatformOverride = null;
      if (previousPlatform != null) {
        InAppWebViewPlatform.instance = previousPlatform;
      }
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/url_launcher'),
            null,
          );
    });

    test('iOS web links present vertically in the system browser', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      expect(await launchInAppBrowserLink('https://example.com/guide'), isTrue);
      final browser = platform.browsers.single;
      expect(browser.url.toString(), 'https://example.com/guide');
      expect(
        browser.settings!.transitionStyle,
        ModalTransitionStyle.COVER_VERTICAL,
      );
      expect(
        browser.settings!.presentationStyle,
        ModalPresentationStyle.OVER_FULL_SCREEN,
      );
      expect(launches, isEmpty);
      expect(browser.settings!.dismissButtonStyle, DismissButtonStyle.CLOSE);
    });

    test('Android keeps its existing in-app browser launcher', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      expect(await launchInAppBrowserLink('https://example.com/guide'), isTrue);
      expect(platform.browsers, isEmpty);
      expect(launches, hasLength(1));
    });

    test('explicit external launches bypass the iOS browser', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      expect(
        await launchExternalLink(
          'https://example.com/guide',
          mode: LaunchMode.externalApplication,
        ),
        isTrue,
      );
      expect(platform.browsers, isEmpty);
      expect(launches, hasLength(1));
    });

    test(
      'native presentation failure is reported without another launch',
      () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
        platform.failOpen = true;
        expect(
          await launchInAppBrowserLink('https://example.com/guide'),
          isFalse,
        );
        expect(platform.browsers, hasLength(1));
        expect(platform.browsers.single.disposed, isTrue);
        expect(launches, isEmpty);
      },
    );
  });
  group('parseAllowedExternalLink', () {
    test('allows https URLs', () {
      final uri = parseAllowedExternalLink('https://example.com/page');

      expect(uri, isNotNull);
      expect(uri!.scheme, 'https');
    });

    test('allows http URLs with local network hosts and ports', () {
      final uri = parseAllowedExternalLink('http://192.168.1.10:3000/x');

      expect(uri, isNotNull);
      expect(uri!.scheme, 'http');
    });

    test('allows mailto URLs', () {
      final uri = parseAllowedExternalLink('mailto:user@example.com');

      expect(uri, isNotNull);
      expect(uri!.scheme, 'mailto');
    });

    test('matches allowed schemes case-insensitively', () {
      final uri = parseAllowedExternalLink('HTTPS://EXAMPLE.COM');

      expect(uri, isNotNull);
      expect(uri!.scheme.toLowerCase(), 'https');
    });

    test('trims whitespace around URLs', () {
      final uri = parseAllowedExternalLink('  https://example.com  ');

      expect(uri, isNotNull);
      expect(uri!.toString(), 'https://example.com');
    });

    test('blocks tel URLs', () {
      expect(parseAllowedExternalLink('tel:+19005551234'), isNull);
    });

    test('blocks sms URLs', () {
      expect(parseAllowedExternalLink('sms:+19005551234'), isNull);
    });

    test('blocks javascript URLs', () {
      expect(parseAllowedExternalLink('javascript:alert(1)'), isNull);
    });

    test('blocks file URLs', () {
      expect(parseAllowedExternalLink('file:///etc/passwd'), isNull);
    });

    test('blocks Android intent URLs', () {
      expect(
        parseAllowedExternalLink('intent://scan/#Intent;scheme=zxing;end'),
        isNull,
      );
    });

    test('blocks empty URLs', () {
      expect(parseAllowedExternalLink(''), isNull);
    });

    test('blocks whitespace-only URLs', () {
      expect(parseAllowedExternalLink('   '), isNull);
    });

    test('blocks malformed URLs', () {
      expect(parseAllowedExternalLink('not a url ::'), isNull);
    });

    test('blocks bare hosts without a scheme', () {
      expect(parseAllowedExternalLink('example.com'), isNull);
    });
  });

  group('defaultLaunchModeForAllowedExternalLink', () {
    test('opens web URLs in the in-app browser by default', () {
      expect(
        defaultLaunchModeForAllowedExternalLink(
          Uri.parse('https://example.com'),
        ),
        LaunchMode.inAppBrowserView,
      );
      expect(
        defaultLaunchModeForAllowedExternalLink(
          Uri.parse('http://192.168.1.10:3000'),
        ),
        LaunchMode.inAppBrowserView,
      );
    });

    test('keeps non-web schemes external', () {
      expect(
        defaultLaunchModeForAllowedExternalLink(
          Uri.parse('mailto:user@example.com'),
        ),
        LaunchMode.externalApplication,
      );
    });
  });
}

class _BrowserPlatform extends InAppWebViewPlatform {
  final browsers = <_Browser>[];
  bool failOpen = false;

  @override
  PlatformChromeSafariBrowser createPlatformChromeSafariBrowser(
    PlatformChromeSafariBrowserCreationParams params,
  ) {
    final browser = _Browser(params, failOpen: failOpen);
    browsers.add(browser);
    return browser;
  }
}

class _Browser extends PlatformChromeSafariBrowser {
  _Browser(super.params, {required this.failOpen}) : super.implementation();

  final bool failOpen;
  WebUri? url;
  ChromeSafariBrowserSettings? settings;
  bool disposed = false;

  @override
  void dispose() {
    super.dispose();
    disposed = true;
  }

  @override
  Future<void> open({
    WebUri? url,
    Map<String, String>? headers,
    List<WebUri>? otherLikelyURLs,
    WebUri? referrer,
    Object? options,
    ChromeSafariBrowserSettings? settings,
  }) async {
    this.url = url;
    this.settings = settings;
    if (failOpen) throw const FormatException('Synthetic browser failure');
  }
}
