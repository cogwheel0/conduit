import 'dart:async';
import 'dart:convert';

import 'package:checks/checks.dart';
import 'package:conduit/core/persistence/persistence_keys.dart';
import 'package:conduit/core/persistence/preferences_store.dart';
import 'package:conduit/features/hermes/services/hermes_local_document_trust_store.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    PreferencesStore.debugOverride(await SharedPreferences.getInstance());
    HermesLocalDocumentTrustStore.debugResetRuntimeState();
  });

  tearDown(() {
    HermesLocalDocumentTrustStore.debugResetRuntimeState();
    PreferencesStore.debugReset();
  });

  test('trust is scoped to the exact endpoint and session', () async {
    const prompt =
        'Question\n\n<<<BEGIN_HERMES_UNTRUSTED_REFERENCE_HDOC_TEST>>>';
    await HermesLocalDocumentTrustStore.remember(
      connectionIdentity: 'connection-one',
      sessionId: 'session-1',
      messageId: 'message-1',
      promptText: prompt,
      documentEnvelopes: const [
        '<<<BEGIN_HERMES_UNTRUSTED_REFERENCE_HDOC_TEST>>>',
      ],
    );
    final trustKey = HermesLocalDocumentTrustStore.documentTrustKey(
      messageId: 'message-1',
      promptText: prompt,
      documentEnvelope: '<<<BEGIN_HERMES_UNTRUSTED_REFERENCE_HDOC_TEST>>>',
      startOffset: prompt.indexOf(
        '<<<BEGIN_HERMES_UNTRUSTED_REFERENCE_HDOC_TEST>>>',
      ),
    );

    check(
      HermesLocalDocumentTrustStore.trustedDocumentKeys(
        connectionIdentity: 'connection-one',
        sessionId: 'session-1',
      ),
    ).deepEquals({trustKey});
    check(
      HermesLocalDocumentTrustStore.trustedDocumentKeys(
        connectionIdentity: 'connection-two',
        sessionId: 'session-1',
      ),
    ).isEmpty();
    check(
      HermesLocalDocumentTrustStore.trustedDocumentKeys(
        connectionIdentity: 'connection-one',
        sessionId: 'session-2',
      ),
    ).isEmpty();
  });

  test(
    'fork copies trust and delete removes only the target session',
    () async {
      const prompt =
          'Question\n\n<<<BEGIN_HERMES_UNTRUSTED_REFERENCE_HDOC_TEST>>>';
      await HermesLocalDocumentTrustStore.remember(
        connectionIdentity: 'connection-one',
        sessionId: 'source',
        messageId: 'message-1',
        promptText: prompt,
        documentEnvelopes: const [
          '<<<BEGIN_HERMES_UNTRUSTED_REFERENCE_HDOC_TEST>>>',
        ],
      );
      await HermesLocalDocumentTrustStore.rebindForkedSession(
        connectionIdentity: 'connection-one',
        sourceSessionId: 'source',
        targetSessionId: 'fork',
        messageIdMap: const <String, String>{'message-1': 'message-forked'},
      );

      check(
        HermesLocalDocumentTrustStore.trustedDocumentKeys(
          connectionIdentity: 'connection-one',
          sessionId: 'fork',
        ),
      ).deepEquals(<String>{
        HermesLocalDocumentTrustStore.documentTrustKey(
          messageId: 'message-forked',
          promptText: prompt,
          documentEnvelope: '<<<BEGIN_HERMES_UNTRUSTED_REFERENCE_HDOC_TEST>>>',
          startOffset: prompt.indexOf(
            '<<<BEGIN_HERMES_UNTRUSTED_REFERENCE_HDOC_TEST>>>',
          ),
        ),
      });
      await HermesLocalDocumentTrustStore.forgetSession(
        connectionIdentity: 'connection-one',
        sessionId: 'fork',
      );
      check(
        HermesLocalDocumentTrustStore.trustedDocumentKeys(
          connectionIdentity: 'connection-one',
          sessionId: 'fork',
        ),
      ).isEmpty();
      check(
        HermesLocalDocumentTrustStore.trustedDocumentKeys(
          connectionIdentity: 'connection-one',
          sessionId: 'source',
        ),
      ).isNotEmpty();
    },
  );

  test('ordinary prompts do not create trust records', () async {
    await HermesLocalDocumentTrustStore.remember(
      connectionIdentity: 'connection-one',
      sessionId: 'session-1',
      messageId: 'message-1',
      promptText: 'ordinary message',
      documentEnvelopes: const ['ordinary message'],
    );

    check(
      HermesLocalDocumentTrustStore.trustedDocumentKeys(
        connectionIdentity: 'connection-one',
        sessionId: 'session-1',
      ),
    ).isEmpty();
  });

  test('principal epochs cannot inherit another principal trust', () async {
    final first = HermesLocalDocumentTrustStore.connectionIdentity(
      endpointIdentity: 'https://hermes.example:443',
      principalId: 'principal-one',
    );
    final rotated = HermesLocalDocumentTrustStore.connectionIdentity(
      endpointIdentity: 'https://hermes.example:443',
      principalId: 'principal-two',
    );
    check(first).not((it) => it.equals(rotated));
  });

  test('a deleted session rejects delayed provenance writes', () async {
    const envelope = '<<<BEGIN_HERMES_UNTRUSTED_REFERENCE_HDOC_DELAYED>>>';
    const prompt = 'Question\n\n$envelope';
    HermesLocalDocumentTrustStore.beginSessionDeletion(
      connectionIdentity: 'connection-one',
      sessionId: 'deleted',
    );
    await HermesLocalDocumentTrustStore.remember(
      connectionIdentity: 'connection-one',
      sessionId: 'deleted',
      messageId: 'message-late',
      promptText: prompt,
      documentEnvelopes: const <String>[envelope],
    );
    check(
      HermesLocalDocumentTrustStore.trustedDocumentKeys(
        connectionIdentity: 'connection-one',
        sessionId: 'deleted',
      ),
    ).isEmpty();
  });

  test(
    'a reused session id is durably purged before it is unblocked',
    () async {
      const envelope = '<<<BEGIN_HERMES_UNTRUSTED_REFERENCE_HDOC_REUSED>>>';
      const prompt = 'Question\n\n$envelope';
      await HermesLocalDocumentTrustStore.remember(
        connectionIdentity: 'connection-one',
        sessionId: 'reused',
        messageId: 'message-old',
        promptText: prompt,
        documentEnvelopes: const <String>[envelope],
      );
      check(
        HermesLocalDocumentTrustStore.trustedDocumentKeys(
          connectionIdentity: 'connection-one',
          sessionId: 'reused',
        ),
      ).isNotEmpty();

      await HermesLocalDocumentTrustStore.prepareNewSession(
        connectionIdentity: 'connection-one',
        sessionId: 'reused',
      );

      check(
        HermesLocalDocumentTrustStore.trustedDocumentKeys(
          connectionIdentity: 'connection-one',
          sessionId: 'reused',
        ),
      ).isEmpty();
      HermesLocalDocumentTrustStore.debugResetRuntimeState();
      check(
        HermesLocalDocumentTrustStore.trustedDocumentKeys(
          connectionIdentity: 'connection-one',
          sessionId: 'reused',
        ),
      ).isEmpty();
    },
  );

  test('a reuse purge follows and removes an earlier delayed write', () async {
    const envelope = '<<<BEGIN_HERMES_UNTRUSTED_REFERENCE_HDOC_RACE>>>';
    const prompt = 'Question\n\n$envelope';
    final writeStarted = Completer<void>();
    final releaseWrite = Completer<void>();
    addTearDown(() {
      if (!releaseWrite.isCompleted) releaseWrite.complete();
    });
    var delayFirstTrustWrite = true;
    PreferencesStore.debugOverride(
      PreferencesStore.instance,
      writeInterceptor: (preferences, key, value) async {
        if (key == PreferenceKeys.hermesLocalDocumentTrust &&
            value is List<String> &&
            value.isNotEmpty &&
            delayFirstTrustWrite) {
          delayFirstTrustWrite = false;
          writeStarted.complete();
          await releaseWrite.future;
        }
        return null;
      },
    );

    final remember = HermesLocalDocumentTrustStore.remember(
      connectionIdentity: 'connection-one',
      sessionId: 'reused',
      messageId: 'message-old',
      promptText: prompt,
      documentEnvelopes: const <String>[envelope],
    );
    await writeStarted.future.timeout(const Duration(seconds: 1));

    final prepare = HermesLocalDocumentTrustStore.prepareNewSession(
      connectionIdentity: 'connection-one',
      sessionId: 'reused',
    );
    check(
      HermesLocalDocumentTrustStore.trustedDocumentKeys(
        connectionIdentity: 'connection-one',
        sessionId: 'reused',
      ),
    ).isEmpty();

    releaseWrite.complete();
    await Future.wait<void>([
      remember,
      prepare,
    ]).timeout(const Duration(seconds: 1));

    // Model restart: no in-memory tombstone may be required to hide a late
    // trust write after the reuse purge has reported success.
    HermesLocalDocumentTrustStore.debugResetRuntimeState();
    check(
      HermesLocalDocumentTrustStore.trustedDocumentKeys(
        connectionIdentity: 'connection-one',
        sessionId: 'reused',
      ),
    ).isEmpty();
  });

  test('a delete purge follows and removes an earlier delayed write', () async {
    const envelope = '<<<BEGIN_HERMES_UNTRUSTED_REFERENCE_HDOC_DELETE_RACE>>>';
    const prompt = 'Question\n\n$envelope';
    final writeStarted = Completer<void>();
    final releaseWrite = Completer<void>();
    addTearDown(() {
      if (!releaseWrite.isCompleted) releaseWrite.complete();
    });
    PreferencesStore.debugOverride(
      PreferencesStore.instance,
      writeInterceptor: (preferences, key, value) async {
        if (key == PreferenceKeys.hermesLocalDocumentTrust &&
            value is List<String> &&
            value.isNotEmpty &&
            !writeStarted.isCompleted) {
          writeStarted.complete();
          await releaseWrite.future;
        }
        return null;
      },
    );

    final remember = HermesLocalDocumentTrustStore.remember(
      connectionIdentity: 'connection-one',
      sessionId: 'deleted',
      messageId: 'message-old',
      promptText: prompt,
      documentEnvelopes: const <String>[envelope],
    );
    await writeStarted.future.timeout(const Duration(seconds: 1));
    final forget = HermesLocalDocumentTrustStore.forgetSession(
      connectionIdentity: 'connection-one',
      sessionId: 'deleted',
    );

    releaseWrite.complete();
    await Future.wait<void>([
      remember,
      forget,
    ]).timeout(const Duration(seconds: 1));

    HermesLocalDocumentTrustStore.debugResetRuntimeState();
    check(
      HermesLocalDocumentTrustStore.trustedDocumentKeys(
        connectionIdentity: 'connection-one',
        sessionId: 'deleted',
      ),
    ).isEmpty();
  });

  test('a failed trust purge keeps the reused session blocked', () async {
    const envelope = '<<<BEGIN_HERMES_UNTRUSTED_REFERENCE_HDOC_FAILED_PURGE>>>';
    const prompt = 'Question\n\n$envelope';
    await HermesLocalDocumentTrustStore.remember(
      connectionIdentity: 'connection-one',
      sessionId: 'reused',
      messageId: 'message-old',
      promptText: prompt,
      documentEnvelopes: const <String>[envelope],
    );
    check(
      HermesLocalDocumentTrustStore.trustedDocumentKeys(
        connectionIdentity: 'connection-one',
        sessionId: 'reused',
      ),
    ).isNotEmpty();

    PreferencesStore.debugOverride(
      PreferencesStore.instance,
      writeInterceptor: (preferences, key, value) async =>
          key == PreferenceKeys.hermesLocalDocumentTrust ? false : null,
    );

    await expectLater(
      HermesLocalDocumentTrustStore.prepareNewSession(
        connectionIdentity: 'connection-one',
        sessionId: 'reused',
      ),
      throwsA(isA<StateError>()),
    );
    check(
      HermesLocalDocumentTrustStore.trustedDocumentKeys(
        connectionIdentity: 'connection-one',
        sessionId: 'reused',
      ),
    ).isEmpty();
  });

  test('fork never evicts a full source or unrelated trust store', () async {
    const envelope = '<<<BEGIN_HERMES_UNTRUSTED_REFERENCE_HDOC_SOURCE>>>';
    const prompt = 'Question\n\n$envelope';
    await HermesLocalDocumentTrustStore.remember(
      connectionIdentity: 'connection-one',
      sessionId: 'source',
      messageId: 'message-source',
      promptText: prompt,
      documentEnvelopes: const <String>[envelope],
    );
    final sourceRecord = PreferencesStore.getStringList(
      PreferenceKeys.hermesLocalDocumentTrust,
    )!.single;
    String digest(String value) =>
        sha256.convert(utf8.encode(value)).toString();
    final fullStore = <String>[
      for (
        var index = 0;
        index < HermesLocalDocumentTrustStore.maxRecords - 1;
        index++
      )
        [for (var part = 0; part < 6; part++) digest('$index-$part')].join(':'),
      sourceRecord,
    ];
    await PreferencesStore.put(
      PreferenceKeys.hermesLocalDocumentTrust,
      fullStore,
    );

    await HermesLocalDocumentTrustStore.rebindForkedSession(
      connectionIdentity: 'connection-one',
      sourceSessionId: 'source',
      targetSessionId: 'fork',
      messageIdMap: const <String, String>{'message-source': 'message-forked'},
    );

    check(
      PreferencesStore.getStringList(PreferenceKeys.hermesLocalDocumentTrust),
    ).isNotNull().deepEquals(fullStore);
    check(
      HermesLocalDocumentTrustStore.trustedDocumentKeys(
        connectionIdentity: 'connection-one',
        sessionId: 'source',
      ),
    ).isNotEmpty();
    check(
      HermesLocalDocumentTrustStore.trustedDocumentKeys(
        connectionIdentity: 'connection-one',
        sessionId: 'fork',
      ),
    ).isEmpty();
  });
}
