import 'dart:convert';
import 'dart:io';

import 'package:conduitd/src/ports/key_value_store.dart';
import 'package:test/test.dart';

void main() {
  late Directory temporary;
  late File file;

  setUp(() {
    temporary = Directory.systemTemp.createTempSync('kv-store-test');
    file = File('${temporary.path}/preferences.json');
  });

  tearDown(() => temporary.deleteSync(recursive: true));

  test('reads are synchronous after open', () async {
    final store = await DaemonKeyValueStore.open(file);
    await store.setString('theme', 'dark');

    // No await: the interface promises the next read already sees it, which
    // is the whole reason the core can build providers on a cold start.
    expect(store.getString('theme'), 'dark');
  });

  test('values survive a reopen', () async {
    final store = await DaemonKeyValueStore.open(file);
    await store.setBool('onboarded', true);
    await store.setInt('launches', 3);
    await store.setDouble('scale', 1.5);
    await store.setStringList('recent', <String>['a', 'b']);

    final reopened = await DaemonKeyValueStore.open(file);
    expect(reopened.getBool('onboarded'), isTrue);
    expect(reopened.getInt('launches'), 3);
    expect(reopened.getDouble('scale'), 1.5);
    expect(reopened.getStringList('recent'), <String>['a', 'b']);
  });

  group('type mismatch reads as null rather than throwing', () {
    test('a string read as a bool', () async {
      final store = await DaemonKeyValueStore.open(file);
      await store.setString('flag', 'yes');
      expect(store.getBool('flag'), isNull);
      expect(store.getString('flag'), 'yes');
    });

    test('a list holding a non-string', () async {
      file.writeAsStringSync(
        jsonEncode(<String, Object?>{
          'recent': <Object?>['a', 7],
        }),
      );
      final store = await DaemonKeyValueStore.open(file);
      expect(store.getStringList('recent'), isNull);
    });

    test('a list that arrives from JSON as List<dynamic>', () async {
      file.writeAsStringSync(
        jsonEncode(<String, Object?>{
          'recent': <Object?>['a', 'b'],
        }),
      );
      final store = await DaemonKeyValueStore.open(file);
      expect(store.getStringList('recent'), <String>['a', 'b']);
    });
  });

  test(
    'an int and a double are not confused after a JSON round trip',
    () async {
      final store = await DaemonKeyValueStore.open(file);
      await store.setInt('count', 2);

      final reopened = await DaemonKeyValueStore.open(file);
      expect(reopened.getInt('count'), 2);
    },
  );

  test('keys lists everything, remove and clear empty it', () async {
    final store = await DaemonKeyValueStore.open(file);
    await store.setString('a', '1');
    await store.setString('b', '2');
    expect(store.keys, <String>{'a', 'b'});

    await store.remove('a');
    expect(store.containsKey('a'), isFalse);

    await store.clear();
    expect((await DaemonKeyValueStore.open(file)).keys, isEmpty);
  });

  test('a corrupt file starts empty and is kept as .corrupt', () async {
    file.writeAsStringSync('{not json');
    final store = await DaemonKeyValueStore.open(file);

    expect(store.keys, isEmpty);
    expect(File('${file.path}.corrupt').existsSync(), isTrue);
    expect(File('${file.path}.corrupt').readAsStringSync(), '{not json');
  });

  test('a write reports whether it reached disk', () async {
    final store = await DaemonKeyValueStore.open(file);
    expect(await store.setString('theme', 'dark'), isTrue);
  });

  test('concurrent writes all survive', () async {
    final store = await DaemonKeyValueStore.open(file);
    await Future.wait(<Future<bool>>[
      for (var i = 0; i < 20; i++) store.setString('k$i', 'v$i'),
    ]);

    final reopened = await DaemonKeyValueStore.open(file);
    expect(reopened.keys, hasLength(20));
    expect(reopened.getString('k19'), 'v19');
  });
}
