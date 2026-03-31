import 'package:conduit/features/auth/views/proxy_auth_page.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('hasCapturedJwtToken', () {
    test('returns false for missing or blank tokens', () {
      expect(hasCapturedJwtToken(null), isFalse);
      expect(hasCapturedJwtToken('   '), isFalse);
    });

    test('returns true for a non-empty token', () {
      expect(hasCapturedJwtToken('header.payload.signature'), isTrue);
    });
  });

  group('ProxyAuthCaptureQueue', () {
    test('queues an automatic retry while a capture is in flight', () {
      final queue = ProxyAuthCaptureQueue();
      final request = const ProxyAuthCaptureRequest.automatic(
        shouldWaitForJwt: false,
        path: '/',
      );

      expect(queue.begin(request), request);
      expect(
        queue.begin(
          const ProxyAuthCaptureRequest.automatic(
            shouldWaitForJwt: false,
            path: '/',
          ),
        ),
        isNull,
      );
      expect(queue.finish(completed: false), request);
    });

    test('preserves a later automatic request that requires waiting', () {
      final queue = ProxyAuthCaptureQueue();

      expect(
        queue.begin(
          const ProxyAuthCaptureRequest.automatic(
            shouldWaitForJwt: false,
            path: '/',
          ),
        ),
        isNotNull,
      );
      expect(
        queue.begin(
          const ProxyAuthCaptureRequest.automatic(
            shouldWaitForJwt: true,
            path: '/auth',
          ),
        ),
        isNull,
      );

      expect(
        queue.finish(completed: false),
        const ProxyAuthCaptureRequest.automatic(
          shouldWaitForJwt: true,
          path: '/auth',
        ),
      );
    });

    test('manual capture takes precedence over queued automatic retries', () {
      final queue = ProxyAuthCaptureQueue();

      expect(
        queue.begin(
          const ProxyAuthCaptureRequest.automatic(
            shouldWaitForJwt: false,
            path: '/',
          ),
        ),
        isNotNull,
      );
      expect(
        queue.begin(
          const ProxyAuthCaptureRequest.automatic(
            shouldWaitForJwt: true,
            path: '/auth',
          ),
        ),
        isNull,
      );
      expect(queue.begin(const ProxyAuthCaptureRequest.manual()), isNull);
      expect(
        queue.finish(completed: false),
        const ProxyAuthCaptureRequest.manual(),
      );
    });

    test('completed captures clear any queued retry', () {
      final queue = ProxyAuthCaptureQueue();

      expect(queue.begin(const ProxyAuthCaptureRequest.manual()), isNotNull);
      expect(
        queue.begin(
          const ProxyAuthCaptureRequest.automatic(
            shouldWaitForJwt: true,
            path: '/oauth/oidc/callback',
          ),
        ),
        isNull,
      );
      expect(queue.finish(completed: true), isNull);
    });
  });

  group('shouldWaitForAutomaticProxyAuthCapture', () {
    test('waits on oauth routes', () {
      expect(
        shouldWaitForAutomaticProxyAuthCapture(
          path: '/oauth/oidc/callback',
          hasPasswordField: false,
        ),
        isTrue,
      );
    });

    test('waits on auth pages without a password field', () {
      expect(
        shouldWaitForAutomaticProxyAuthCapture(
          path: '/auth',
          hasPasswordField: false,
        ),
        isTrue,
      );
    });

    test('does not wait on auth pages with a password field', () {
      expect(
        shouldWaitForAutomaticProxyAuthCapture(
          path: '/auth',
          hasPasswordField: true,
        ),
        isFalse,
      );
    });

    test('does not wait on normal app routes', () {
      expect(
        shouldWaitForAutomaticProxyAuthCapture(
          path: '/',
          hasPasswordField: false,
        ),
        isFalse,
      );
    });
  });

  group('shouldRequireJwtForAutomaticCapture', () {
    test(
      'returns false when no page in the session has required a JWT yet',
      () {
        expect(
          shouldRequireJwtForAutomaticCapture(
            hasPendingJwtWait: false,
            currentPageShouldWait: false,
          ),
          isFalse,
        );
      },
    );

    test('returns true when the current page requires waiting for JWT', () {
      expect(
        shouldRequireJwtForAutomaticCapture(
          hasPendingJwtWait: false,
          currentPageShouldWait: true,
        ),
        isTrue,
      );
    });

    test('stays true once a prior automatic capture required waiting', () {
      expect(
        shouldRequireJwtForAutomaticCapture(
          hasPendingJwtWait: true,
          currentPageShouldWait: false,
        ),
        isTrue,
      );
    });
  });

  group('isKnownOpenWebUiProxyAuthPath', () {
    test('returns true for OpenWebUI auth paths', () {
      expect(isKnownOpenWebUiProxyAuthPath('/auth'), isTrue);
      expect(isKnownOpenWebUiProxyAuthPath('/auth/oidc'), isTrue);
      expect(isKnownOpenWebUiProxyAuthPath('/oauth/oidc/callback'), isTrue);
      expect(isKnownOpenWebUiProxyAuthPath('/api/v1/auths/signin'), isTrue);
    });

    test('returns false for proxy login pages on the same host', () {
      expect(isKnownOpenWebUiProxyAuthPath('/'), isFalse);
      expect(isKnownOpenWebUiProxyAuthPath('/login'), isFalse);
      expect(isKnownOpenWebUiProxyAuthPath('/oauth2/sign_in'), isFalse);
    });
  });

  group('shouldAttemptAutomaticProxyAuthCapture', () {
    test('waits on same-host pages that do not look like OpenWebUI', () {
      expect(
        shouldAttemptAutomaticProxyAuthCapture(
          looksLikeOpenWebUi: false,
          path: '/login',
        ),
        isFalse,
      );
      expect(
        shouldAttemptAutomaticProxyAuthCapture(
          looksLikeOpenWebUi: false,
          path: '/',
        ),
        isFalse,
      );
    });

    test('allows automatic capture for detected OpenWebUI pages', () {
      expect(
        shouldAttemptAutomaticProxyAuthCapture(
          looksLikeOpenWebUi: true,
          path: '/',
        ),
        isTrue,
      );
    });

    test('allows automatic capture on known OpenWebUI auth routes', () {
      expect(
        shouldAttemptAutomaticProxyAuthCapture(
          looksLikeOpenWebUi: false,
          path: '/auth',
        ),
        isTrue,
      );
      expect(
        shouldAttemptAutomaticProxyAuthCapture(
          looksLikeOpenWebUi: false,
          path: '/oauth/oidc/callback',
        ),
        isTrue,
      );
    });
  });

  group('shouldCompleteProxyAuthCapture', () {
    test('manual completion proceeds without a JWT', () {
      expect(
        shouldCompleteProxyAuthCapture(
          isManual: true,
          shouldWaitForJwt: true,
          jwtToken: null,
        ),
        isTrue,
      );
    });

    test('automatic completion waits for a JWT when required', () {
      expect(
        shouldCompleteProxyAuthCapture(
          isManual: false,
          shouldWaitForJwt: true,
          jwtToken: null,
        ),
        isFalse,
      );
      expect(
        shouldCompleteProxyAuthCapture(
          isManual: false,
          shouldWaitForJwt: true,
          jwtToken: '   ',
        ),
        isFalse,
      );
    });

    test(
      'automatic completion proceeds without a JWT when it is not required',
      () {
        expect(
          shouldCompleteProxyAuthCapture(
            isManual: false,
            shouldWaitForJwt: false,
            jwtToken: null,
          ),
          isTrue,
        );
      },
    );

    test('automatic completion proceeds when a JWT exists', () {
      expect(
        shouldCompleteProxyAuthCapture(
          isManual: false,
          shouldWaitForJwt: true,
          jwtToken: 'header.payload.signature',
        ),
        isTrue,
      );
    });
  });

  group('decideProxyAuthCapture', () {
    test('defers an older no-wait capture to a newer queued wait request', () {
      expect(
        decideProxyAuthCapture(
          activeRequest: const ProxyAuthCaptureRequest.automatic(
            shouldWaitForJwt: false,
            path: '/',
          ),
          queuedRequest: const ProxyAuthCaptureRequest.automatic(
            shouldWaitForJwt: true,
            path: '/auth',
          ),
          jwtToken: null,
        ),
        ProxyAuthCaptureDecision.deferToQueuedRequest,
      );
    });

    test('keeps waiting when the active request still requires a JWT', () {
      expect(
        decideProxyAuthCapture(
          activeRequest: const ProxyAuthCaptureRequest.automatic(
            shouldWaitForJwt: true,
            path: '/auth',
          ),
          queuedRequest: null,
          jwtToken: null,
        ),
        ProxyAuthCaptureDecision.waitForJwt,
      );
    });

    test(
      'does not let a later no-wait request override an active wait request',
      () {
        expect(
          decideProxyAuthCapture(
            activeRequest: const ProxyAuthCaptureRequest.automatic(
              shouldWaitForJwt: true,
              path: '/auth',
            ),
            queuedRequest: const ProxyAuthCaptureRequest.automatic(
              shouldWaitForJwt: false,
              path: '/',
            ),
            jwtToken: null,
          ),
          ProxyAuthCaptureDecision.waitForJwt,
        );
      },
    );

    test(
      'manual capture still completes even if an automatic retry is queued',
      () {
        expect(
          decideProxyAuthCapture(
            activeRequest: const ProxyAuthCaptureRequest.manual(),
            queuedRequest: const ProxyAuthCaptureRequest.automatic(
              shouldWaitForJwt: true,
              path: '/auth',
            ),
            jwtToken: null,
          ),
          ProxyAuthCaptureDecision.complete,
        );
      },
    );

    test('completes once a JWT is present', () {
      expect(
        decideProxyAuthCapture(
          activeRequest: const ProxyAuthCaptureRequest.automatic(
            shouldWaitForJwt: true,
            path: '/oauth/oidc/callback',
          ),
          queuedRequest: const ProxyAuthCaptureRequest.automatic(
            shouldWaitForJwt: true,
            path: '/',
          ),
          jwtToken: 'header.payload.signature',
        ),
        ProxyAuthCaptureDecision.complete,
      );
    });
  });
}
