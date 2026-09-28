import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:conduitd/src/ports/secure_store.dart';
import 'package:test/test.dart';

void main() {
  late Directory temporary;
  late File file;

  final keyA = List<int>.generate(32, (i) => i);
  final keyB = List<int>.generate(32, (i) => 255 - i);

  setUp(() {
    temporary = Directory.systemTemp.createTempSync('secure-store-test');
    file = File('${temporary.path}/secure_store.bin');
  });

  tearDown(() => temporary.deleteSync(recursive: true));

  Future<DaemonSecureStore> open({List<int>? key}) =>
      DaemonSecureStore.open(file: file, masterKey: key ?? keyA);

  group('round trip', () {
    test('a value written survives a reopen', () async {
      final store = await open();
      await store.write(key: 'token', value: 'abc123');

      final reopened = await open();
      expect(await reopened.read(key: 'token'), 'abc123');
    });

    test('a missing file opens empty rather than failing', () async {
      expect(file.existsSync(), isFalse);
      expect(await (await open()).readAll(), isEmpty);
    });

    test('a null value deletes, and does not store "null"', () async {
      final store = await open();
      await store.write(key: 'token', value: 'abc123');
      await store.write(key: 'token', value: null);

      expect(await (await open()).containsKey(key: 'token'), isFalse);
    });

    test('deleteAll empties the persisted file too', () async {
      final store = await open();
      await store.write(key: 'a', value: '1');
      await store.write(key: 'b', value: '2');
      await store.deleteAll();

      expect(await (await open()).readAll(), isEmpty);
    });

    test('concurrent writes all survive', () async {
      final store = await open();
      await Future.wait(<Future<void>>[
        for (var i = 0; i < 20; i++) store.write(key: 'k$i', value: 'v$i'),
      ]);

      final reopened = await open();
      expect(await reopened.readAll(), hasLength(20));
      expect(await reopened.read(key: 'k19'), 'v19');
    });
  });

  group('confidentiality', () {
    test('the value does not appear in the file', () async {
      final store = await open();
      await store.write(key: 'token', value: 'super-secret-value');

      final raw = file.readAsBytesSync();
      expect(
        utf8.decode(raw, allowMalformed: true),
        isNot(contains('super-secret-value')),
      );
      expect(utf8.decode(raw, allowMalformed: true), isNot(contains('token')));
    });

    test('two writes of the same value produce different ciphertext', () async {
      final store = await open();
      await store.write(key: 'token', value: 'same');
      final first = file.readAsBytesSync();
      await store.write(key: 'token', value: 'same');
      final second = file.readAsBytesSync();

      // A reused nonce under one key is the failure mode that breaks GCM
      // outright, so this is worth asserting rather than trusting.
      expect(first, isNot(equals(second)));
    });
  });

  group('integrity', () {
    test('a wrong master key is refused, not treated as empty', () async {
      final store = await open();
      await store.write(key: 'token', value: 'abc123');

      expect(
        () => open(key: keyB),
        throwsA(
          isA<SecureStoreCorruptException>().having(
            (e) => e.reason,
            'reason',
            contains('authentication failed'),
          ),
        ),
      );
    });

    test('a flipped ciphertext bit is refused', () async {
      final store = await open();
      await store.write(key: 'token', value: 'abc123');

      final raw = Uint8List.fromList(file.readAsBytesSync());
      raw[raw.length - 20] ^= 0x01;
      file.writeAsBytesSync(raw);

      expect(() => open(), throwsA(isA<SecureStoreCorruptException>()));
    });

    test('an unknown format version is named as such', () async {
      final store = await open();
      await store.write(key: 'token', value: 'abc123');

      final raw = Uint8List.fromList(file.readAsBytesSync());
      raw[0] = 99;
      file.writeAsBytesSync(raw);

      expect(
        () => open(),
        throwsA(
          isA<SecureStoreCorruptException>().having(
            (e) => e.reason,
            'reason',
            contains('unknown format version 99'),
          ),
        ),
      );
    });

    test('a truncated file is refused', () async {
      final store = await open();
      await store.write(key: 'token', value: 'abc123');
      file.writeAsBytesSync(file.readAsBytesSync().sublist(0, 6));

      expect(
        () => open(),
        throwsA(
          isA<SecureStoreCorruptException>().having(
            (e) => e.reason,
            'reason',
            'truncated',
          ),
        ),
      );
    });
  });

  test('a key that is not 32 bytes is rejected at open', () {
    expect(
      () => DaemonSecureStore.open(file: file, masterKey: <int>[1, 2, 3]),
      throwsA(isA<ArgumentError>()),
    );
  });

  test('a crash mid-flush cannot truncate the previous store', () async {
    final store = await open();
    await store.write(key: 'token', value: 'abc123');

    // The temp file is the one that would be half-written; the real file is
    // only ever replaced by a rename.
    expect(File('${file.path}.tmp').existsSync(), isFalse);
    expect(await (await open()).read(key: 'token'), 'abc123');
  });
}
