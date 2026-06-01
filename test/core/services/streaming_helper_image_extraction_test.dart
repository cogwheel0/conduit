import 'dart:convert';

import 'package:checks/checks.dart';
import 'package:conduit/core/services/streaming_helper.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('debugCollectImageReferencesFromContent', () {
    test('ignores bare image URLs in assistant text', () {
      final images = debugCollectImageReferencesFromContent(
        'A news article referenced https://cdn.example.com/photo.jpg in text.',
      );

      check(images).isEmpty();
    });

    test('ignores image URLs inside generic tool result payloads', () {
      final result = _attributeJson({
        'images': ['https://cdn.example.com/news-photo.webp'],
        'results': [
          {
            'title': 'News',
            'url': 'https://example.com/article',
            'thumbnail': 'https://cdn.example.com/thumb.png',
          },
        ],
      });
      final images = debugCollectImageReferencesFromContent(
        '<details type="tool_calls" done="true" id="call_1" '
        'name="fetch_url" result="$result">'
        '<summary>Tool Executed</summary></details>',
      );

      check(images).isEmpty();
    });

    test('collects explicitly marked tool-call image files', () {
      final files = _attributeJson([
        {'type': 'image', 'url': 'https://example.com/generated.png'},
        {'type': 'file', 'url': 'https://example.com/news-photo.jpg'},
        {
          'content_type': 'image/webp',
          'url': 'https://example.com/preview.webp',
        },
      ]);

      final images = debugCollectImageReferencesFromContent(
        '<details type="tool_calls" done="true" id="call_1" '
        'name="generate_image" files="$files">'
        '<summary>Tool Executed</summary></details>',
      );

      check(images).deepEquals([
        {'type': 'image', 'url': 'https://example.com/generated.png'},
        {'type': 'image', 'url': 'https://example.com/preview.webp'},
      ]);
    });

    test('collects explicitly marked image files nested in tool result', () {
      final result = _attributeJson({
        'files': [
          {'type': 'image', 'url': 'https://example.com/result-image.png'},
          {'type': 'file', 'url': 'https://example.com/news-photo.jpg'},
        ],
      });

      final images = debugCollectImageReferencesFromContent(
        '<details type="tool_calls" done="true" id="call_1" '
        'name="generate_image" result="$result">'
        '<summary>Tool Executed</summary></details>',
      );

      check(images).deepEquals([
        {'type': 'image', 'url': 'https://example.com/result-image.png'},
      ]);
    });

    test('collects explicitly marked base64 image files', () {
      final files = _attributeJson([
        {'type': 'image', 'b64_json': 'iVBORw0KGgo='},
        {'content_type': 'image/jpeg', 'b64': '/9j/4AAQSkZJRg=='},
      ]);

      final images = debugCollectImageReferencesFromContent(
        '<details type="tool_calls" done="true" id="call_1" '
        'name="generate_image" files="$files">'
        '<summary>Tool Executed</summary></details>',
      );

      check(images).deepEquals([
        {'type': 'image', 'url': 'data:image/png;base64,iVBORw0KGgo='},
        {'type': 'image', 'url': 'data:image/jpeg;base64,/9j/4AAQSkZJRg=='},
      ]);
    });
  });
}

String _attributeJson(Object? value) {
  return jsonEncode(value)
      .replaceAll('&', '&amp;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&#39;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');
}
