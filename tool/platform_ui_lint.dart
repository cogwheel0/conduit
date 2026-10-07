// Enforces platform UI imports and control use outside the shared facade.
import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

const _seam = 'lib/shared/widgets/platform_ui/';
const _widgetPackages = {'material_ui', 'cupertino_ui'};
const _controls = {
  'ElevatedButton',
  'OutlinedButton',
  'FilledButton',
  'TextButton',
  'IconButton',
  'FloatingActionButton',
  'Switch',
  'SwitchListTile',
  'Checkbox',
  'CheckboxListTile',
  'Slider',
  'ActionChip',
  'ChoiceChip',
  'FilterChip',
  'InputChip',
  'Chip',
  'SegmentedButton',
  'ButtonSegment',
  'CupertinoButton',
  'CupertinoSwitch',
  'CupertinoSlider',
  'CupertinoSlidingSegmentedControl',
  'CupertinoSegmentedControl',
  'CircularProgressIndicator',
  'LinearProgressIndicator',
  'CupertinoActivityIndicator',
  'Card',
  'ExpansionTile',
  'NavigationBar',
  'NavigationDestination',
  'Dialog',
  'AlertDialog',
  'AppBar',
  'SimpleDialog',
  'SimpleDialogOption',
  'DropdownButton',
  'DropdownButtonFormField',
  'DropdownMenuItem',
  'PopupMenuButton',
  'PopupMenuDivider',
  'PopupMenuEntry',
  'PopupMenuItem',
  'PopupMenuItemBuilder',
  'PopupMenuItemSelected',
  'showMenu',
};

bool _widgetUri(String uri) {
  final parsed = Uri.tryParse(uri);
  if (parsed == null ||
      parsed.scheme != 'package' ||
      parsed.pathSegments.isEmpty) {
    return false;
  }
  final package = parsed.pathSegments.first;
  return _widgetPackages.contains(package) ||
      (package == 'flutter' &&
          (parsed.path == 'flutter/material.dart' ||
              parsed.path == 'flutter/cupertino.dart' ||
              parsed.path.startsWith('flutter/src/material/') ||
              parsed.path.startsWith('flutter/src/cupertino/')));
}

// These generators own their imports. Authored files cannot opt out by comment.
bool _generated(String path) =>
    path.endsWith('.g.dart') ||
    path.endsWith('.freezed.dart') ||
    RegExp(r'^lib/l10n/app_localizations(?:_[a-z_]+)?\.dart$').hasMatch(path);

Future<void> main(List<String> args) async {
  var root = Directory.current.path;
  var allowlist = 'tool/platform_ui_allowlist.yaml';
  var inventory = false;
  String? baseRef;
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--root':
        root = args[++i];
      case '--allowlist':
        allowlist = args[++i];
      case '--inventory':
        inventory = true;
      case '--base-ref':
        baseRef = args[++i];
      default:
        throw ArgumentError('Unknown argument: ${args[i]}');
    }
  }
  root = p.normalize(p.absolute(root));
  final counts = await inventoryViolations(root);
  if (inventory) {
    stdout.writeln(const JsonEncoder.withIndent('  ').convert(counts));
    return;
  }
  final file = File(p.join(root, allowlist));
  if (!file.existsSync()) {
    stderr.writeln('Missing allow-list: ${file.path}');
    exitCode = 1;
    return;
  }
  final errors = checkAllowlist(counts, file.readAsStringSync());
  if (baseRef == null &&
      FileSystemEntity.typeSync(p.join(root, '.git')) !=
          FileSystemEntityType.notFound) {
    baseRef = 'HEAD';
  }
  if (baseRef != null) {
    final previous = Process.runSync('git', [
      'show',
      '$baseRef:$allowlist',
    ], workingDirectory: root);
    if (previous.exitCode == 0) {
      errors.addAll(
        checkAllowlistGrowth(
          previous.stdout as String,
          file.readAsStringSync(),
        ),
      );
    } else {
      // Only initial introduction may lack the file. An invalid ref fails.
      final validRef = Process.runSync('git', [
        'rev-parse',
        '--verify',
        baseRef,
      ], workingDirectory: root);
      if (validRef.exitCode != 0) errors.add('Invalid baseline ref: $baseRef');
    }
  }
  for (final error in errors) {
    stderr.writeln(error);
  }
  stdout.writeln(
    'platform_ui: ${counts.length} violations, '
    '${counts.values.fold(0, (a, b) => a + b)} occurrences; '
    '${errors.length} errors',
  );
  if (errors.isNotEmpty) exitCode = 1;
}

Future<Map<String, int>> inventoryViolations(String root) async {
  final counts = <String, int>{};
  final files =
      Directory(p.join(root, 'lib'))
          .listSync(recursive: true, followLinks: false)
          .whereType<File>()
          .where((file) {
            final path = p.relative(file.path, from: root);
            return path.endsWith('.dart') &&
                !path.startsWith(_seam) &&
                !_generated(path);
          })
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  final collection = AnalysisContextCollection(
    includedPaths: [p.join(root, 'lib')],
  );
  final units = <String, CompilationUnit>{};
  Set<String> widgetExports(String path, Set<String> visiting) {
    if (p.relative(path, from: root).startsWith(_seam)) return {};
    if (!visiting.add(path) || !File(path).existsSync()) return {};
    final unit = units.putIfAbsent(
      path,
      () => parseString(content: File(path).readAsStringSync()).unit,
    );
    final result = <String>{};
    for (final directive in unit.directives.whereType<ExportDirective>()) {
      for (final uri in [
        directive.uri.stringValue,
        ...directive.configurations.map((c) => c.uri.stringValue),
      ]) {
        if (uri == null) continue;
        if (_widgetUri(uri)) {
          result.add(uri);
          continue;
        }
        final target = _localPath(uri, path, root);
        if (target != null) result.addAll(widgetExports(target, visiting));
      }
    }
    visiting.remove(path);
    return result;
  }

  try {
    for (final file in files) {
      final path = p.relative(file.path, from: root);
      void record(String kind, String value) {
        final key = '$path|$kind|$value';
        counts.update(key, (n) => n + 1, ifAbsent: () => 1);
      }

      final parsed = parseString(
        content: file.readAsStringSync(),
        path: file.path,
      );
      if (parsed.errors.isNotEmpty) {
        throw FormatException('Cannot lint invalid Dart: $path');
      }
      for (final directive
          in parsed.unit.directives.whereType<UriBasedDirective>()) {
        if (directive is! ImportDirective && directive is! ExportDirective) {
          continue;
        }
        final uris = [
          directive.uri.stringValue,
          if (directive is NamespaceDirective)
            ...directive.configurations.map((c) => c.uri.stringValue),
        ];
        for (final uri in uris.toSet()) {
          if (uri == null) continue;
          if (_widgetUri(uri)) {
            record('package', uri);
            continue;
          }
          final target = _localPath(uri, file.path, root);
          if (target != null && widgetExports(target, {}).isNotEmpty) {
            record('package', 'barrel:$uri');
          }
        }
      }
      final resolved = await collection
          .contextFor(file.path)
          .currentSession
          .getResolvedUnit(file.path);
      if (resolved is! ResolvedUnitResult) {
        throw StateError('Cannot resolve $path: $resolved');
      }
      resolved.unit.accept(_ControlVisitor((name) => record('symbol', name)));
    }
  } finally {
    await collection.dispose();
  }
  return Map.fromEntries(
    counts.entries.toList()..sort((a, b) => a.key.compareTo(b.key)),
  );
}

String? _localPath(String uri, String source, String root) {
  if (uri.startsWith('package:conduit/')) {
    final path = p.normalize(
      p.join(root, 'lib', uri.substring('package:conduit/'.length)),
    );
    return p.isWithin(p.join(root, 'lib'), path) ? path : null;
  }
  if (Uri.parse(uri).hasScheme) return null;
  final path = p.normalize(p.join(p.dirname(source), uri));
  return p.isWithin(p.join(root, 'lib'), path) ? path : null;
}

class _ControlVisitor extends RecursiveAstVisitor<void> {
  _ControlVisitor(this.record);
  final void Function(String) record;
  // Directive names are already accounted for by package violations. In
  // particular, hiding a control is not a use of that control.
  @override
  void visitImportDirective(ImportDirective node) {}
  @override
  void visitExportDirective(ExportDirective node) {}
  void check(Element? element) {
    if (element is ConstructorElement) element = element.enclosingElement;
    if (element is TypeAliasElement && element.aliasedType is InterfaceType) {
      element = (element.aliasedType as InterfaceType).element;
    }
    final name = element?.name;
    final uri = element?.library?.uri.toString();
    if (name != null &&
        _controls.contains(name) &&
        uri != null &&
        (_widgetUri(uri) || uri.startsWith('package:flutter/'))) {
      record(name);
    }
  }

  @override
  void visitNamedType(NamedType node) {
    check(node.element);
    super.visitNamedType(node);
  }

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    if (!node.inDeclarationContext()) check(node.element);
    super.visitSimpleIdentifier(node);
  }
}

/// The reviewed baseline may shrink but may not gain or enlarge exceptions.
List<String> checkAllowlistGrowth(String baseline, String candidate) {
  Map<String, int> entries(String source) {
    final document = loadYaml(source) as YamlMap;
    return {
      for (final e in document['exceptions'] as YamlList)
        '${e['path']}|${e.containsKey('package') ? 'package' : 'symbol'}|${e['package'] ?? e['symbol']}':
            e['count'] as int,
    };
  }

  final old = entries(baseline);
  final current = entries(candidate);
  return [
    for (final entry in current.entries)
      if (entry.value > (old[entry.key] ?? 0))
        'Expanded exception: ${entry.key} (${old[entry.key] ?? 0} to ${entry.value})',
  ];
}

final _metadataName = RegExp(r'^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$');

List<String> checkAllowlist(Map<String, int> counts, String source) {
  final errors = <String>[];
  final document = loadYaml(source);
  if (document is! YamlMap ||
      document['version'] != 1 ||
      document['exceptions'] is! YamlList) {
    return ['Invalid allow-list schema'];
  }
  final seen = <String>{};
  for (final entry in document['exceptions'] as YamlList) {
    if (entry is! YamlMap ||
        entry.keys.any(
          (key) => !{
            'path',
            'package',
            'symbol',
            'count',
            'owner',
            'reason',
            'removal',
          }.contains(key),
        )) {
      errors.add('Invalid exception: $entry');
      continue;
    }
    final path = entry['path'];
    final kind = entry.containsKey('package') ? 'package' : 'symbol';
    final value = entry[kind];
    final count = entry['count'];
    if (path is! String ||
        !path.startsWith('lib/') ||
        p.normalize(path) != path ||
        RegExp(r'[*?\[\]]').hasMatch(path) ||
        value is! String ||
        value.isEmpty ||
        entry.containsKey('package') == entry.containsKey('symbol') ||
        count is! int ||
        count <= 0 ||
        ['owner', 'reason', 'removal'].any(
          (key) =>
              entry[key] is! String || (entry[key] as String).trim().isEmpty,
        ) ||
        [
          'owner',
          'removal',
        ].any((key) => !_metadataName.hasMatch(entry[key] as String))) {
      errors.add('Invalid exception: $entry');
      continue;
    }
    final key = '$path|$kind|$value';
    if (!seen.add(key)) {
      errors.add('Duplicate exception: $key');
      continue;
    }
    final actual = counts[key];
    if (actual == null || actual < count) {
      errors.add('Stale exception: $key ($actual < $count)');
    }
    if (actual != null && actual > count) {
      errors.add('Expanded violation: $key ($actual > $count)');
    }
  }
  for (final key in counts.keys.where((key) => !seen.contains(key))) {
    errors.add('New violation: $key (${counts[key]})');
  }
  return errors;
}
