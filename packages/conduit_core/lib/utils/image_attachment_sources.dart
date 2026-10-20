/// Recognises SVG and remote image sources by their text, before anything is
/// decoded. Read by the attachment views.
library;

import 'dart:convert';
import 'dart:typed_data';

bool imageAttachmentDataIsSvg(String data) =>
    data.toLowerCase().startsWith('data:image/svg+xml');

bool imageAttachmentUrlIsSvg(String url) {
  final parsed = Uri.tryParse(url.trim());
  if (parsed != null) {
    if (parsed.path.toLowerCase().endsWith('.svg')) return true;
    if (parsed.query.toLowerCase().contains('image/svg+xml')) return true;
    if (parsed.queryParameters.values.any(
      (value) => value.toLowerCase().contains('image/svg+xml'),
    )) {
      return true;
    }
    return false;
  }

  // Keep malformed-but-displayable sources on the legacy best-effort path,
  // while ensuring a fragment can never become part of the extension/query.
  final withoutFragment = url.split('#').first.toLowerCase();
  final queryIndex = withoutFragment.indexOf('?');
  final pathPart = queryIndex >= 0
      ? withoutFragment.substring(0, queryIndex)
      : withoutFragment;
  final queryPart = queryIndex >= 0
      ? withoutFragment.substring(queryIndex + 1)
      : '';
  return pathPart.endsWith('.svg') || queryPart.contains('image/svg+xml');
}

/// Whether [bytes] hold an SVG document rather than a raster image.
///
/// Only a document that starts with markup can be SVG. Raster formats can
/// carry `<svg` in their metadata: the C2PA manifest in OpenRouter-generated
/// PNGs embeds an SVG icon within the first kilobyte (issue #768).
bool imageAttachmentBytesAreSvg(Uint8List bytes) {
  final checkLength = bytes.length < 1024 ? bytes.length : 1024;
  var header = utf8.decode(bytes.sublist(0, checkLength), allowMalformed: true);
  if (header.startsWith('\uFEFF')) header = header.substring(1);
  if (!header.trimLeft().startsWith('<')) return false;
  return header.toLowerCase().contains('<svg');
}

bool imageAttachmentContentIsRemote(String data) => data.startsWith('http');
