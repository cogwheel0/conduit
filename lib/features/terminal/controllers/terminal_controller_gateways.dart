import 'dart:io';

import 'package:conduit_core/features/terminal/controllers/terminal_controller_gateways.dart';
import 'package:file_picker/file_picker.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/terminal_models.dart';

// The gateway contracts and the Riverpod adapter moved to conduit_core; this
// file keeps the Flutter plugin gateway.
export 'package:conduit_core/features/terminal/controllers/terminal_controller_gateways.dart';

/// Platform plugin adapter for file picking, saving, and URL launching.
final class DefaultTerminalBrowserPlatformGateway
    implements TerminalBrowserPlatformGateway {
  const DefaultTerminalBrowserPlatformGateway();

  @override
  Future<TerminalUploadFile?> pickUploadFile() async {
    final pickedFile = await FilePicker.pickFile();
    if (pickedFile == null) return null;

    final existingPath = pickedFile.path;
    if (existingPath != null && existingPath.isNotEmpty) {
      return TerminalUploadFile(name: pickedFile.name, path: existingPath);
    }

    final bytes = await pickedFile.readAsBytes();
    final file = await _materializeTempFile(pickedFile.name, bytes);
    return TerminalUploadFile(name: pickedFile.name, path: file.path);
  }

  @override
  Future<void> saveDownload(TerminalDownloadedFile downloaded) async {
    // The name comes from the server's Content-Disposition header, so it must
    // not be able to steer the save location with separators or traversal.
    await FilePicker.saveFile(
      fileName: _safeFileName(downloaded.fileName),
      bytes: downloaded.bytes,
    );
  }

  @override
  Future<bool> openPort(Uri uri, {String? bearerToken}) {
    final token = bearerToken?.trim();
    return launchUrl(
      uri,
      mode: token == null || token.isEmpty
          ? LaunchMode.inAppBrowserView
          : LaunchMode.inAppWebView,
      browserConfiguration: const BrowserConfiguration(showTitle: true),
      webViewConfiguration: WebViewConfiguration(
        headers: token == null || token.isEmpty
            ? const <String, String>{}
            : <String, String>{'Authorization': 'Bearer $token'},
      ),
    );
  }

  @visibleForTesting
  static String safeFileName(String fileName) => _safeFileName(fileName);

  static String _safeFileName(String fileName) =>
      safeTerminalFileName(fileName);

  Future<File> _materializeTempFile(String fileName, List<int> bytes) async {
    final tempDir = await getTemporaryDirectory();
    final safeName = _safeFileName(fileName);
    final file = File(p.join(tempDir.path, safeName));
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }
}
