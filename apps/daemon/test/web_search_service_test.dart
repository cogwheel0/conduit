@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:conduitd/conduitd.dart';
import 'package:test/test.dart';

import 'support/null_sink.dart';

/// `webSearch.*` over the real core's settings.
void main() {
  late Directory temporary;
  late CoreRuntime runtime;
  late WebSearchService search;

  setUpAll(() async {
    temporary = Directory.systemTemp.createTempSync('web-search-test');
    runtime = await CoreRuntime.start(
      config: BootstrapConfig(
        sessionToken: 'a' * 43,
        masterKey: base64.encode(List<int>.generate(32, (i) => i)),
        userDataDir: temporary.path,
      ),
      directories: DaemonDirectories.create(temporary.path),
      log: DaemonLog(level: 'error', sink: NullSink()),
    );
    search = WebSearchService(runtime.container);
  });

  tearDownAll(() async {
    await runtime.dispose();
    temporary.deleteSync(recursive: true);
  });

  test('starts on Auto, moderate, following this Mac', () {
    final settings = search.get();
    expect(settings.engine, 'auto');
    expect(settings.safeSearch, 'moderate');
    expect(settings.region, isNull);
    expect(settings.engines.first.id, 'auto');
    expect(settings.engines.first.name, isEmpty);
    expect(
      settings.engines.map((e) => e.name),
      containsAll(<String>['DuckDuckGo', 'Brave', 'Bing', 'Mojeek']),
    );
    expect(settings.regions.first.code, 'wt-wt');
    expect(
      settings.regions.where((r) => r.code == 'de-de').single.name,
      'Deutschland',
    );
  });

  test('changes what it is given, and only that', () async {
    final changed = await search.set(
      const WebSearchSettingsPatch(engine: 'brave', region: 'fr-fr'),
    );
    expect(changed.engine, 'brave');
    expect(changed.region, 'fr-fr');
    expect(changed.effectiveRegion, 'fr-fr');
    expect(changed.safeSearch, 'moderate');

    final strict = await search.set(
      const WebSearchSettingsPatch(safeSearch: 'strict'),
    );
    expect(strict.safeSearch, 'strict');
    expect(strict.engine, 'brave');

    final followed = await search.set(
      const WebSearchSettingsPatch(region: 'auto'),
    );
    expect(followed.region, isNull);
  });

  test('refuses what it does not know', () {
    for (final patch in const <WebSearchSettingsPatch>[
      WebSearchSettingsPatch(engine: 'altavista'),
      WebSearchSettingsPatch(safeSearch: 'loose'),
      WebSearchSettingsPatch(region: 'xx-yy'),
    ]) {
      expect(
        search.set(patch),
        throwsA(
          isA<RpcError>().having(
            (e) => e.code,
            'code',
            ConduitErrorCodes.invalidParams,
          ),
        ),
      );
    }
  });

  test('the logo catalog is found beside the daemon or where named', () {
    final bundle = Directory('${temporary.path}/bundle')..createSync();
    Directory('${bundle.path}/bin').createSync();
    final logos = Directory('${bundle.path}/model_logos')..createSync();
    File('${logos.path}/catalog.json').writeAsStringSync('{"logos":{}}');
    expect(
      findModelLogoCatalog(
        environment: const <String, String>{},
        executable: '${bundle.path}/bin/conduitd',
      ),
      '${logos.path}/catalog.json',
    );
    expect(
      findModelLogoCatalog(
        environment: <String, String>{
          'CONDUIT_MODEL_LOGOS': '${temporary.path}/nowhere',
        },
        executable: '${bundle.path}/bin/conduitd',
      ),
      isNull,
    );
  });
}
