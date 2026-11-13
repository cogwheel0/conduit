import 'dart:io' show File;

import 'package:conduit_core/auth/openwebui_server_address.dart';
import 'package:file_picker/file_picker.dart' show PlatformFile;
import 'package:flutter/foundation.dart' show immutable;

/// The app's side of editing an Open WebUI server's address: reading a
/// picked certificate file, and the request that opens the editor. Checking
/// and saving an address is core's (`openwebui_server_address.dart`).

/// The text of a picked PEM file ([decodePickedPem]). Throws a
/// [ServerAddressInputException] when it is empty or not text.
Future<String> readPickedPemFile(PlatformFile file) async {
  final bytes = file.path != null
      ? await File(file.path!).readAsBytes()
      : await file.readAsBytes();
  return decodePickedPem(bytes);
}

/// What a picked file is called, from its name or path, else [fallback].
String pickedPlatformFileLabel(PlatformFile file, {required String fallback}) =>
    pickedFileLabel(name: file.name, path: file.path, fallback: fallback);

/// Where the address editor route goes: the address [endpointId] of the
/// saved server [serverId], or a new one when null. With [draft], the edit
/// was handed over from Settings to sign in through a proxy, and the
/// connection page carries on with it.
@immutable
class ServerAddressEditorRequest {
  const ServerAddressEditorRequest({
    required this.serverId,
    this.endpointId,
    this.draft,
  });

  final String serverId;

  /// The address to edit; null adds one.
  final String? endpointId;
  final ServerAddressDraft? draft;
}
