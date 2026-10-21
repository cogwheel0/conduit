import 'package:checks/checks.dart';
import 'package:conduit/platform/conduit_platform_apis.g.dart';
import 'package:conduit/platform/pigeon_browser_auth_port.dart';
import 'package:conduit_core/conduit_core.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockBrowserAuthApi extends Mock implements BrowserAuthHostApi {}

void main() {
  setUpAll(() {
    registerFallbackValue(
      PlatformBrowserAuthRequest(
        authorizationUrl: '',
        callbackScheme: '',
        callbackHost: '',
        callbackPath: '',
        preferEphemeralSession: false,
      ),
    );
  });

  final authorizeUrl = Uri.parse(
    'https://id.example.com/authorize?client_id=conduit&state=s',
  );
  final redirect = Uri.parse(browserAuthDefaultRedirect);

  late _MockBrowserAuthApi api;
  late PigeonBrowserAuthPort port;

  setUp(() {
    api = _MockBrowserAuthApi();
    port = PigeonBrowserAuthPort(api: api);
  });

  void answer(PlatformBrowserAuthResult result) {
    when(() => api.authenticate(any())).thenAnswer((_) async => result);
  }

  test('sends the URL and the redirect split into its parts', () async {
    answer(
      PlatformBrowserAuthResult(outcome: PlatformBrowserAuthOutcome.cancelled),
    );

    await port.authorize(
      authorizeUrl,
      redirectUri: redirect,
      preferEphemeral: true,
    );

    final request =
        verify(() => api.authenticate(captureAny())).captured.single
            as PlatformBrowserAuthRequest;
    check(request.authorizationUrl).equals(authorizeUrl.toString());
    check(request.callbackScheme).equals('conduit');
    check(request.callbackHost).equals('oauth');
    check(request.callbackPath).equals('/callback');
    check(request.preferEphemeralSession).isTrue();
  });

  test('a Google redirect has no host', () async {
    answer(
      PlatformBrowserAuthResult(outcome: PlatformBrowserAuthOutcome.cancelled),
    );

    await port.authorize(
      authorizeUrl,
      redirectUri: Uri.parse(
        'com.googleusercontent.apps.123-abc:/oauth2redirect',
      ),
    );

    final request =
        verify(() => api.authenticate(captureAny())).captured.single
            as PlatformBrowserAuthRequest;
    check(request.callbackScheme).equals('com.googleusercontent.apps.123-abc');
    check(request.callbackHost).equals('');
    check(request.callbackPath).equals('/oauth2redirect');
  });

  test('a success returns the redirect it ended on and the channel', () async {
    answer(
      PlatformBrowserAuthResult(
        outcome: PlatformBrowserAuthOutcome.success,
        callbackUrl: 'conduit://oauth/callback?code=c&state=s',
        channel: 'auth_tab',
      ),
    );

    final result = await port.authorize(authorizeUrl, redirectUri: redirect);

    check(result.outcome).equals(BrowserAuthOutcome.success);
    check(result.callbackUri!.queryParameters)
        .deepEquals({'code': 'c', 'state': 's'});
    check(result.channel).equals(BrowserAuthChannels.authTab);
    check(result.errorCode).isNull();
  });

  test('a success on another redirect is a failure', () async {
    for (final callback in [
      'conduit://oauth/other?code=c',
      'conduit://evil/callback?code=c',
      'other://oauth/callback?code=c',
      'conduit://oauth:1234/callback?code=c',
      'conduit://user@oauth/callback?code=c',
      'conduit://oauth/callback?code=c#fragment',
      null,
    ]) {
      answer(
        PlatformBrowserAuthResult(
          outcome: PlatformBrowserAuthOutcome.success,
          callbackUrl: callback,
        ),
      );

      final result = await port.authorize(authorizeUrl, redirectUri: redirect);

      check(
        because: '$callback',
        result.outcome,
      ).equals(BrowserAuthOutcome.failed);
      check(result.errorCode).equals(BrowserAuthErrorCodes.unexpectedCallback);
      check(result.callbackUri).isNull();
    }
  });

  test('cancelled, unavailable and failed keep their codes', () async {
    answer(
      PlatformBrowserAuthResult(
        outcome: PlatformBrowserAuthOutcome.cancelled,
        channel: 'custom_tabs',
      ),
    );
    final cancelled = await port.authorize(authorizeUrl, redirectUri: redirect);
    check(cancelled.outcome).equals(BrowserAuthOutcome.cancelled);
    check(cancelled.channel).equals(BrowserAuthChannels.customTabs);

    answer(
      PlatformBrowserAuthResult(
        outcome: PlatformBrowserAuthOutcome.unavailable,
        errorCode: 'auth_tab_required',
      ),
    );
    final unavailable = await port.authorize(
      authorizeUrl,
      redirectUri: redirect,
    );
    check(unavailable.outcome).equals(BrowserAuthOutcome.unavailable);
    check(unavailable.errorCode).equals(BrowserAuthErrorCodes.authTabRequired);

    answer(
      PlatformBrowserAuthResult(
        outcome: PlatformBrowserAuthOutcome.failed,
        errorCode: 'superseded',
      ),
    );
    final failed = await port.authorize(authorizeUrl, redirectUri: redirect);
    check(failed.outcome).equals(BrowserAuthOutcome.failed);
    check(failed.errorCode).equals(BrowserAuthErrorCodes.superseded);
  });

  test('an unusable URL or redirect never reaches the bridge', () async {
    final requests = <(Uri, Uri)>[
      (Uri.parse('javascript:alert(1)'), redirect),
      (Uri.parse('https:///authorize'), redirect),
      (authorizeUrl, Uri.parse('https://app.example.com/callback')),
      (authorizeUrl, Uri.parse('conduit://oauth/callback?x=1')),
      (authorizeUrl, Uri.parse('conduit://oauth/callback#x')),
      (authorizeUrl, Uri.parse('conduit:callback')),
    ];
    for (final (url, redirectUri) in requests) {
      final result = await port.authorize(url, redirectUri: redirectUri);

      check(
        because: '$url $redirectUri',
        result.errorCode,
      ).equals(BrowserAuthErrorCodes.invalidRequest);
    }
    verifyNever(() => api.authenticate(any()));
  });

  test('a bridge error is a failure, a missing bridge unavailable', () async {
    when(() => api.authenticate(any()))
        .thenThrow(PlatformException(code: 'channel-error'));
    final failed = await port.authorize(authorizeUrl, redirectUri: redirect);
    check(failed.outcome).equals(BrowserAuthOutcome.failed);
    check(failed.errorCode).equals(BrowserAuthErrorCodes.startFailed);

    when(() => api.authenticate(any())).thenThrow(MissingPluginException());
    final missing = await port.authorize(authorizeUrl, redirectUri: redirect);
    check(missing.outcome).equals(BrowserAuthOutcome.unavailable);
    check(missing.errorCode).equals(BrowserAuthErrorCodes.noBrowser);
  });

  test('cancel reaches the bridge and swallows its errors', () async {
    when(() => api.cancel()).thenThrow(PlatformException(code: 'x'));

    await port.cancel();

    verify(() => api.cancel()).called(1);
  });

  test('the result never prints its redirect', () async {
    answer(
      PlatformBrowserAuthResult(
        outcome: PlatformBrowserAuthOutcome.success,
        callbackUrl: 'conduit://oauth/callback?code=secret-code',
      ),
    );

    final result = await port.authorize(authorizeUrl, redirectUri: redirect);

    check(result.toString()).not((it) => it.contains('secret-code'));
  });
}
