import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:conduit_core/features/hermes/models/hermes_connection_form.dart';
import 'package:conduit_core/features/hermes/models/hermes_connection_profile.dart';
import 'package:test/test.dart';

void main() {
  final saved = HermesConfig(
    enabled: true,
    connectionId: 'c1',
    baseUrl: 'https://agent.example.test',
    apiKey: 'saved-key',
    sessionKey: 'saved-memory',
    desktopCredentials: HermesDesktopCredentials(legacyToken: 'saved-token'),
  );

  group('buildHermesConnectionDraft', () {
    test('keeps every saved secret when the origin stays and none is typed', () {
      final draft = buildHermesConnectionDraft(
        saved,
        const HermesConnectionForm(
          connectionId: 'c1',
          url: 'https://agent.example.test/v1',
        ),
      );
      expect(draft.config.apiKey, 'saved-key');
      expect(draft.config.sessionKey, 'saved-memory');
      expect(draft.config.desktopCredentials?.legacyToken, 'saved-token');
      expect(draft.apiKeyChanged, isFalse);
      expect(draft.desktopCredentialsChanged, isFalse);
      expect(draft.config.name, isNull, reason: 'an untouched name stays');
    });

    test('drops the saved secrets when the server changes', () {
      final draft = buildHermesConnectionDraft(
        saved,
        const HermesConnectionForm(
          connectionId: 'c1',
          url: 'https://other.example.test',
        ),
      );
      expect(draft.config.apiKey, isNull);
      expect(draft.config.sessionKey, isNull);
      expect(draft.config.desktopCredentials?.legacyToken, isNull);
      expect(draft.apiKeyChanged, isTrue);
      expect(draft.desktopCredentialsChanged, isTrue);
    });

    test('a typed legacy token replaces the saved one on the same server', () {
      final draft = buildHermesConnectionDraft(
        saved,
        const HermesConnectionForm(
          connectionId: 'c1',
          url: 'https://agent.example.test',
          mode: HermesBackendMode.desktopGateway,
          legacyToken: ' fresh-token ',
          desktopCredentialsDirty: true,
        ),
      );
      expect(draft.config.desktopCredentials?.legacyToken, 'fresh-token');
      expect(draft.config.mode, HermesBackendMode.desktopGateway);
    });

    test('an edited name is saved with its source', () {
      final draft = buildHermesConnectionDraft(
        saved,
        const HermesConnectionForm(
          connectionId: 'c1',
          url: 'https://agent.example.test',
          name: '  Studio agent ',
          nameDirty: true,
          nameSource: HermesConnectionNameSource.user,
        ),
      );
      expect(draft.config.name, 'Studio agent');
      expect(draft.nameSource, HermesConnectionNameSource.user);
    });
  });

  group('validateHermesConnectionForm', () {
    test('refuses an address Hermes cannot use', () {
      expect(
        validateHermesConnectionForm(
          saved,
          const HermesConnectionForm(url: 'not a url'),
        ),
        HermesConnectionValidationIssue.invalidUrl,
      );
    });

    test('an API server on a new origin needs its key typed again', () {
      expect(
        validateHermesConnectionForm(
          saved,
          const HermesConnectionForm(
            connectionId: 'c1',
            url: 'https://other.example.test',
          ),
        ),
        HermesConnectionValidationIssue.credentialsReentryRequired,
      );
    });

    test('a Desktop Gateway needs no key', () {
      expect(
        validateHermesConnectionForm(
          const HermesConfig(),
          const HermesConnectionForm(
            url: 'http://127.0.0.1:19303',
            mode: HermesBackendMode.desktopGateway,
          ),
        ),
        isNull,
      );
    });
  });
}
