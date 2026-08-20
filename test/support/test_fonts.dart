import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> loadTestFonts() async {
  TestWidgetsFlutterBinding.ensureInitialized();

  final sans = await File('test/assets/fonts/Roboto.ttf').readAsBytes();
  final mono = await File('test/assets/fonts/RobotoMono.ttf').readAsBytes();

  await Future.wait([
    for (final family in const [
      'Roboto',
      '.SF UI Text',
      '.SF UI Display',
      '.AppleSystemUIFont',
    ])
      _loadFont(family, sans),
    for (final family in const ['Menlo', 'monospace']) _loadFont(family, mono),
  ]);
}

Future<void> _loadFont(String family, Uint8List bytes) {
  final loader = FontLoader(family)
    ..addFont(Future.value(ByteData.sublistView(bytes)));
  return loader.load();
}
