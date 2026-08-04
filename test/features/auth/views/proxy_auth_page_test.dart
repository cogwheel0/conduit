import 'package:checks/checks.dart';
import 'package:conduit/features/auth/views/proxy_auth_page.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ProxyAuthDocumentFence', () {
    test('same-origin main-frame navigation invalidates older capture', () {
      final fence = ProxyAuthDocumentFence();
      fence.startNavigation('https://chat.example/proxy/login');
      final loginGeneration = fence.generation;

      check(
        fence.ownsDocument(loginGeneration, 'https://chat.example/proxy/login'),
      ).isTrue();

      fence.startNavigation('https://chat.example/oauth/callback');

      check(fence.ownsGeneration(loginGeneration)).isFalse();
      check(
        fence.ownsDocument(loginGeneration, 'https://chat.example/proxy/login'),
      ).isFalse();
      check(
        fence.ownsDocument(
          fence.generation,
          'https://chat.example/oauth/callback#complete',
        ),
      ).isTrue();
    });

    test('explicit invalidation owns no prior document', () {
      final fence = ProxyAuthDocumentFence();
      fence.startNavigation('https://chat.example/auth');
      final generation = fence.generation;

      fence.invalidate();

      check(fence.ownsGeneration(generation)).isFalse();
      check(
        fence.ownsDocument(fence.generation, 'https://chat.example/auth'),
      ).isFalse();
    });

    test('invalidated fence rejects a matching delayed completion', () {
      final fence = ProxyAuthDocumentFence();
      fence.startNavigation('https://chat.example/auth');
      fence.markDocumentCommitted('https://chat.example/auth');
      final document = fence.committedDocument!;

      fence.invalidate();

      final committed = fence.commitDocument(
        document: document,
        callbackUrl: 'https://chat.example/auth',
        currentUrl: 'https://chat.example/auth',
      );

      check(committed).isFalse();
      check(
        fence.ownsDocument(document.generation, 'https://chat.example/auth'),
      ).isFalse();
    });

    test('invalidated fence ignores navigation URL changes', () {
      final fence = ProxyAuthDocumentFence();
      fence.startNavigation('https://chat.example/auth');
      fence.markDocumentCommitted('https://chat.example/auth');
      final document = fence.committedDocument!;

      fence.invalidate();

      check(
        fence.observeSameDocumentHistory(
          document: document,
          url: 'https://chat.example/chat/new',
        ),
      ).isFalse();
      check(fence.committedDocument).isNull();
    });

    test('commits the final URL of an HTTP redirect without another start', () {
      final fence = ProxyAuthDocumentFence();
      fence.startNavigation('https://chat.example/');
      fence.markDocumentCommitted('https://chat.example/');
      final initialDocument = fence.committedDocument!;
      check(fence.markNavigationProvisional(initialDocument)).isTrue();
      final pendingDocument = fence.activeDocument!;
      check(
        fence.commitDocument(
          document: pendingDocument,
          callbackUrl: 'https://auth.example/?rd=https%3A%2F%2Fchat.example%2F',
          currentUrl: 'https://auth.example/?rd=https%3A%2F%2Fchat.example%2F',
        ),
      ).isTrue();
      final generation = fence.generation;

      check(
        fence.ownsDocument(
          generation,
          'https://auth.example/?rd=https%3A%2F%2Fchat.example%2F',
        ),
      ).isTrue();
    });

    test('load stop commits when no document-commit callback arrives', () {
      final fence = ProxyAuthDocumentFence();
      fence.startNavigation('https://chat.example/auth');
      final pendingDocument = fence.activeDocument!;

      check(fence.committedDocument).isNull();
      check(
        fence.commitDocument(
          document: pendingDocument,
          callbackUrl: 'https://chat.example/auth',
          currentUrl: 'https://chat.example/auth',
        ),
      ).isTrue();
      check(
        fence.ownsLiveDocument(
          fence.committedDocument!,
          'https://chat.example/auth',
        ),
      ).isTrue();
    });

    test('load stop adopts a redirect without document callbacks', () {
      final fence = ProxyAuthDocumentFence();
      fence.startNavigation('https://chat.example/');
      final pendingDocument = fence.activeDocument!;

      check(
        fence.commitDocument(
          document: pendingDocument,
          callbackUrl: 'https://auth.example/login',
          currentUrl: 'https://auth.example/login',
        ),
      ).isTrue();
      final committedDocument = fence.committedDocument!;
      check(
        fence.ownsLiveDocument(committedDocument, 'https://auth.example/login'),
      ).isTrue();
      check(fence.ownsCommittedDocument(pendingDocument)).isFalse();
    });

    test('load stop fallback rejects a superseded navigation ticket', () {
      final fence = ProxyAuthDocumentFence();
      fence.startNavigation('https://chat.example/old');
      final oldDocument = fence.activeDocument!;

      fence.startNavigation('https://chat.example/new');

      check(
        fence.commitDocument(
          document: oldDocument,
          callbackUrl: 'https://chat.example/old',
          currentUrl: 'https://chat.example/old',
        ),
      ).isFalse();
      check(fence.committedDocument).isNull();
    });

    test('delayed commit callback cannot replace a newer navigation', () {
      final fence = ProxyAuthDocumentFence();
      fence.startNavigation('https://chat.example/old');

      fence.startNavigation('https://chat.example/new');
      final newDocument = fence.activeDocument!;

      check(fence.markDocumentCommitted('https://chat.example/old')).isFalse();
      check(fence.committedDocument).isNull();
      check(
        fence.ownsDocument(newDocument.generation, newDocument.url),
      ).isTrue();
    });

    test('redirect commit waits for the load-stop fallback', () {
      final fence = ProxyAuthDocumentFence();
      fence.startNavigation('https://chat.example/');
      final pendingDocument = fence.activeDocument!;

      check(
        fence.markDocumentCommitted('https://auth.example/login'),
      ).isFalse();
      check(fence.committedDocument).isNull();
      check(
        fence.commitDocument(
          document: pendingDocument,
          callbackUrl: 'https://auth.example/login',
          currentUrl: 'https://auth.example/login',
        ),
      ).isTrue();
      check(
        fence.ownsLiveDocument(
          fence.committedDocument!,
          'https://auth.example/login',
        ),
      ).isTrue();
    });

    test('rejects a delayed completion after a newer navigation starts', () {
      final fence = ProxyAuthDocumentFence();
      fence.startNavigation('https://auth.example/login');
      fence.startNavigation('https://chat.example/auth');
      fence.markDocumentCommitted('https://chat.example/auth');
      final currentGeneration = fence.generation;
      final document = fence.committedDocument!;

      final committed = fence.commitDocument(
        document: document,
        callbackUrl: 'https://auth.example/login',
        currentUrl: 'https://chat.example/auth',
      );

      check(committed).isFalse();
      check(
        fence.ownsDocument(currentGeneration, 'https://chat.example/auth'),
      ).isTrue();
    });

    test('rejects an old document ticket even when the URL is unchanged', () {
      final fence = ProxyAuthDocumentFence();
      fence.startNavigation('https://chat.example/auth');
      fence.markDocumentCommitted('https://chat.example/auth');
      final oldDocument = fence.committedDocument!;

      fence.startNavigation('https://chat.example/auth');
      fence.markDocumentCommitted('https://chat.example/auth');
      final currentDocument = fence.committedDocument!;

      check(
        fence.commitDocument(
          document: oldDocument,
          callbackUrl: 'https://chat.example/auth',
          currentUrl: 'https://chat.example/auth',
        ),
      ).isFalse();
      check(
        fence.commitDocument(
          document: currentDocument,
          callbackUrl: 'https://chat.example/auth',
          currentUrl: 'https://chat.example/auth',
        ),
      ).isTrue();
    });

    test('new navigation cannot finish before its document commits', () {
      final fence = ProxyAuthDocumentFence();
      fence.startNavigation('https://chat.example/auth');
      fence.markDocumentCommitted('https://chat.example/auth');
      final oldDocument = fence.committedDocument!;

      fence.startNavigation('https://chat.example/auth');

      check(
        fence.commitDocument(
          document: oldDocument,
          callbackUrl: 'https://chat.example/auth',
          currentUrl: 'https://chat.example/auth',
        ),
      ).isFalse();
      check(fence.committedDocument).isNull();
    });

    test('committed ticket rejects a different same-origin URL', () {
      final fence = ProxyAuthDocumentFence();
      fence.startNavigation('https://chat.example/auth');
      fence.markDocumentCommitted('https://chat.example/auth');
      final document = fence.committedDocument!;

      check(
        fence.ownsLiveDocument(document, 'https://chat.example/auth#ready'),
      ).isTrue();
      check(
        fence.ownsLiveDocument(document, 'https://chat.example/chat/new'),
      ).isFalse();
    });

    test('same-document history change advances the committed ticket', () {
      final fence = ProxyAuthDocumentFence();
      fence.startNavigation('https://chat.example/auth');
      fence.markDocumentCommitted('https://chat.example/auth');
      final oldDocument = fence.committedDocument!;

      check(
        fence.observeSameDocumentHistory(
          document: oldDocument,
          url: 'https://chat.example/chat/new',
        ),
      ).isTrue();
      final currentDocument = fence.committedDocument!;

      check(fence.ownsCommittedDocument(oldDocument)).isFalse();
      check(
        fence.ownsLiveDocument(
          currentDocument,
          'https://chat.example/chat/new',
        ),
      ).isTrue();
    });

    test('loading history update only makes the document provisional', () {
      final fence = ProxyAuthDocumentFence();
      fence.startNavigation('https://chat.example/auth');
      fence.markDocumentCommitted('https://chat.example/auth');
      final document = fence.committedDocument!;

      check(fence.markNavigationProvisional(document)).isTrue();
      check(fence.committedDocument).isNull();
      check(
        fence.ownsDocument(fence.generation, 'https://chat.example/auth'),
      ).isTrue();
    });

    test('stale history ticket cannot replace a newer navigation', () {
      final fence = ProxyAuthDocumentFence();
      fence.startNavigation('https://chat.example/old');
      final oldDocument = fence.activeDocument!;

      fence.startNavigation('https://chat.example/new');
      final newDocument = fence.activeDocument!;

      check(
        fence.observeSameDocumentHistory(
          document: oldDocument,
          url: 'https://chat.example/old/history',
        ),
      ).isFalse();
      check(
        fence.ownsDocument(newDocument.generation, newDocument.url),
      ).isTrue();
    });
  });

  group('refreshProxyAuthWebView', () {
    test(
      'retries full initialization when cleanup left no controller',
      () async {
        var initializeCalls = 0;
        var reloadCalls = 0;

        await refreshProxyAuthWebView<Object>(
          controller: null,
          initialize: () async => initializeCalls++,
          reload: (_) async => reloadCalls++,
        );

        check(initializeCalls).equals(1);
        check(reloadCalls).equals(0);
      },
    );

    test('reloads an existing controller without rebuilding it', () async {
      final controller = Object();
      Object? reloadedController;
      var initializeCalls = 0;

      await refreshProxyAuthWebView<Object>(
        controller: controller,
        initialize: () async => initializeCalls++,
        reload: (value) async => reloadedController = value,
      );

      check(initializeCalls).equals(0);
      check(reloadedController).identicalTo(controller);
    });
  });

  group('isTrustedProxyCredentialCaptureUrl', () {
    test('allows Open WebUI paths on the exact configured origin', () {
      expect(
        isTrustedProxyCredentialCaptureUrl(
          pageUrl: 'https://chat.example/oauth/oidc/callback',
          serverUrl: 'https://CHAT.example:443',
        ),
        isTrue,
      );
    });

    test('rejects same-host HTTPS to HTTP downgrade', () {
      expect(
        isTrustedProxyCredentialCaptureUrl(
          pageUrl: 'http://chat.example/auth',
          serverUrl: 'https://chat.example',
        ),
        isFalse,
      );
    });

    test('rejects same-host alternate port', () {
      expect(
        isTrustedProxyCredentialCaptureUrl(
          pageUrl: 'https://chat.example:8443/auth',
          serverUrl: 'https://chat.example',
        ),
        isFalse,
      );
    });

    test('cookie lookup includes cookies scoped below a slashless base', () {
      expect(
        proxyCookieLookupUrl('https://chat.example/openwebui'),
        'https://chat.example/openwebui/',
      );
    });
  });

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
    test('load-stop redirect adoption releases an old capture', () {
      final fence = ProxyAuthDocumentFence();
      final queue = ProxyAuthCaptureQueue();
      fence.startNavigation('https://chat.example/');
      final pendingDocument = fence.activeDocument!;
      check(
        queue.begin(
          const ProxyAuthCaptureRequest.automatic(
            shouldWaitForJwt: false,
            path: '/',
          ),
        ),
      ).isNotNull();

      check(
        commitProxyAuthLoadStopDocument(
          fence: fence,
          captureQueue: queue,
          document: pendingDocument,
          callbackUrl: 'https://auth.example/login',
          currentUrl: 'https://auth.example/login',
        ),
      ).isTrue();
      check(
        queue.begin(
          const ProxyAuthCaptureRequest.automatic(
            shouldWaitForJwt: false,
            path: '/login',
          ),
        ),
      ).isNotNull();
    });

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

    test('stale document cannot publish a JWT-wait requirement', () {
      final fence = ProxyAuthDocumentFence();
      fence.startNavigation('https://chat.example/auth');
      final staleGeneration = fence.generation;
      fence.startNavigation('https://chat.example/');

      final requirement = resolveProxyAuthJwtRequirement(
        ownsDocument: fence.ownsGeneration(staleGeneration),
        hasPendingJwtWait: false,
        currentPageShouldWait: true,
      );

      expect(requirement, isNull);
    });

    test('current document can publish a sticky JWT-wait requirement', () {
      final requirement = resolveProxyAuthJwtRequirement(
        ownsDocument: true,
        hasPendingJwtWait: false,
        currentPageShouldWait: true,
      );

      expect(requirement, isTrue);
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
