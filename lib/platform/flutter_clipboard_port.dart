import 'package:conduit_core/conduit_core.dart';
import 'package:flutter/services.dart';

/// The Flutter app's [ClipboardPort].
class FlutterClipboardPort implements ClipboardPort {
  const FlutterClipboardPort();

  @override
  Future<String?> readText() async {
    // A platform channel failure here means the OS denied or has no
    // clipboard. A prompt variable that cannot be filled renders empty
    // rather than failing the send, so swallow it.
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final text = data?.text;
      return (text == null || text.isEmpty) ? null : text;
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  @override
  Future<void> writeText(String text) =>
      Clipboard.setData(ClipboardData(text: text));
}
