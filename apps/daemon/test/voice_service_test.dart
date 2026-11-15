@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:conduitd/conduitd.dart';
import 'package:test/test.dart';

import 'support/fake_owui_auth_server.dart';
import 'support/null_sink.dart';

/// Speech jobs against a fake Open WebUI with two synthetic users: a job's
/// text belongs to the account it was made under, and is never spoken
/// through the next one's server or session.
void main() {
  late Directory temporary;
  late CoreRuntime runtime;
  late FakeOwuiAuthServer owui;
  late AccountsService accounts;
  late AuthService auth;
  late VoiceService voice;

  setUpAll(() async {
    temporary = Directory.systemTemp.createTempSync('voice-test');
    runtime = await CoreRuntime.start(
      config: BootstrapConfig(
        sessionToken: 'a' * 43,
        masterKey: base64.encode(List<int>.generate(32, (i) => i)),
        userDataDir: temporary.path,
      ),
      directories: DaemonDirectories.create(temporary.path),
      log: DaemonLog(level: 'error', sink: NullSink()),
    );
    owui = await FakeOwuiAuthServer.start(
      users: const {
        'ada@example.com': (id: 'user-ada', name: 'Ada', password: 'pw-ada'),
        'bob@example.com': (id: 'user-bob', name: 'Bob', password: 'pw-bob'),
      },
    );
    accounts = AccountsService(runtime.container, events: EventBus());
    auth = AuthService(runtime.container);
    voice = VoiceService(
      runtime.container,
      whisperDirectory: Directory('${temporary.path}/whisper'),
    );
  });

  tearDownAll(() async {
    accounts.dispose();
    await owui.close();
    await runtime.dispose();
    temporary.deleteSync(recursive: true);
  });

  Future<void> signInAs(String email, String password) async {
    await accounts.add(
      AddAccount(
        server: ServerDraft(name: 'Fake', url: owui.url),
      ),
    );
    final snapshot = await auth.loginWithPassword(
      PasswordLogin(username: email, password: password),
    );
    expect(snapshot.isAuthenticated, isTrue, reason: email);
  }

  test('a job made under one account is not spoken under the next', () async {
    await signInAs('ada@example.com', 'pw-ada');
    final job = await voice.speak(
      const VoiceSpeak(text: 'Words Ada wrote', voice: 'alloy'),
    );
    await signInAs('bob@example.com', 'pw-bob');

    await expectLater(
      voice.audio(job.jobId),
      throwsA(
        isA<RpcError>().having(
          (e) => e.code,
          'code',
          ConduitErrorCodes.notFound,
        ),
      ),
    );
    expect(owui.requests.where((r) => r.contains('/audio/speech')), isEmpty);
  });
}
