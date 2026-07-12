import 'package:checks/checks.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:conduit/features/workspace/models/workspace_tool_content.dart';

void main() {
  group('parseFrontmatter', () {
    test('parses a Python docstring front-matter block', () {
      const content = '''"""
title: Web Search
description: Search the web
required_open_webui_version: 0.10.2
"""

class Tools:
    pass
''';
      final fm = WorkspaceToolContent.parseFrontmatter(content);
      check(fm['title']).equals('Web Search');
      check(fm['description']).equals('Search the web');
      check(fm['required_open_webui_version']).equals('0.10.2');
    });

    test('returns empty when the first line is not triple quotes', () {
      const content = 'import os\n"""\ntitle: X\n"""';
      check(WorkspaceToolContent.parseFrontmatter(content)).isEmpty();
    });
  });

  group('nameToId', () {
    test('lowercases, folds accents, and underscores separators', () {
      check(WorkspaceToolContent.nameToId('Wéb Search Tool!')).equals(
        'web_search_tool',
      );
    });

    test('trims leading and trailing underscores', () {
      check(WorkspaceToolContent.nameToId('  ***My Tool***  ')).equals(
        'my_tool',
      );
    });
  });

  group('isValidId', () {
    test('accepts Python identifiers', () {
      check(WorkspaceToolContent.isValidId('web_search')).isTrue();
      check(WorkspaceToolContent.isValidId('_private')).isTrue();
    });

    test('rejects leading digits and illegal characters', () {
      check(WorkspaceToolContent.isValidId('1tool')).isFalse();
      check(WorkspaceToolContent.isValidId('my-tool')).isFalse();
      check(WorkspaceToolContent.isValidId('')).isFalse();
    });
  });

  group('githubUrlToRawUrl', () {
    test('normalizes a blob (file) URL to raw', () {
      final raw = WorkspaceToolContent.githubUrlToRawUrl(
        'https://github.com/acme/tools/blob/main/search/tool.py',
      );
      check(raw).equals(
        'https://raw.githubusercontent.com/acme/tools/refs/heads/main/search/tool.py',
      );
    });

    test('normalizes a tree (folder) URL to raw main.py', () {
      final raw = WorkspaceToolContent.githubUrlToRawUrl(
        'https://github.com/acme/tools/tree/main/search/',
      );
      check(raw).equals(
        'https://raw.githubusercontent.com/acme/tools/refs/heads/main/search/main.py',
      );
    });

    test('leaves non-GitHub URLs unchanged', () {
      const url = 'https://example.com/tool.py';
      check(WorkspaceToolContent.githubUrlToRawUrl(url)).equals(url);
    });
  });

  group('isAllowedImportUrl', () {
    test('accepts normalized GitHub raw and github.com hosts', () {
      check(
        WorkspaceToolContent.isAllowedImportUrl(
          'https://raw.githubusercontent.com/acme/tools/refs/heads/main/tool.py',
        ),
      ).isTrue();
      check(
        WorkspaceToolContent.isAllowedImportUrl(
          'https://github.com/acme/tools/blob/main/tool.py',
        ),
      ).isTrue();
    });

    test('rejects link-local metadata and internal hosts (SSRF guard)', () {
      for (final url in const [
        'http://169.254.169.254/latest/meta-data/',
        'https://169.254.169.254/latest/meta-data/',
        'http://localhost/tool.py',
        'https://internal.corp/tool.py',
        'https://example.com/tool.py',
        'file:///etc/passwd',
        'https://user:pass@raw.githubusercontent.com/x/y/z.py',
      ]) {
        check(
          because: url,
          WorkspaceToolContent.isAllowedImportUrl(url),
        ).isFalse();
      }
    });

    test('rejects non-https GitHub URLs', () {
      check(
        WorkspaceToolContent.isAllowedImportUrl(
          'http://raw.githubusercontent.com/acme/tools/main/tool.py',
        ),
      ).isFalse();
    });
  });

  group('meetsRequiredVersion', () {
    test('is compatible when required is missing or 0.0.0', () {
      check(
        WorkspaceToolContent.meetsRequiredVersion(
          required: null,
          current: '0.9.0',
        ),
      ).isTrue();
      check(
        WorkspaceToolContent.meetsRequiredVersion(
          required: '0.0.0',
          current: '0.9.0',
        ),
      ).isTrue();
    });

    test('is compatible when the server meets or exceeds the requirement', () {
      check(
        WorkspaceToolContent.meetsRequiredVersion(
          required: '0.10.2',
          current: '0.10.2',
        ),
      ).isTrue();
      check(
        WorkspaceToolContent.meetsRequiredVersion(
          required: '0.10.2',
          current: '0.11.0',
        ),
      ).isTrue();
    });

    test('is incompatible when the server is older than required', () {
      check(
        WorkspaceToolContent.meetsRequiredVersion(
          required: '0.10.2',
          current: '0.10.1',
        ),
      ).isFalse();
    });

    test('fails open when the current version is unknown', () {
      check(
        WorkspaceToolContent.meetsRequiredVersion(
          required: '0.10.2',
          current: null,
        ),
      ).isTrue();
    });
  });
}
