@TestOn('vm')
library;

import 'dart:io';

import 'package:conduitd/conduitd.dart';
import 'package:test/test.dart';

/// Where the daemon finds the model logo catalog it ships.
void main() {
  late Directory temporary;

  setUp(() {
    temporary = Directory.systemTemp.createTempSync('model-logos-test');
    addTearDown(() => temporary.deleteSync(recursive: true));
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
