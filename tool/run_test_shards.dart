// Runs the app's whole test suite through a few combined entrypoints.
//
//   dart run tool/run_test_shards.dart [--shards=N] [flutter test options]
//
// `flutter test` compiles test files one at a time and loads a full program
// for each, so with a few hundred files most of the run is per-file overhead
// rather than tests. This groups the files into N generated entrypoints in a
// temporary test/.shards_*/ directory (each file's tests run inside a group
// named after it), runs them, and deletes them afterwards. Options other than --shards go to
// `flutter test` unchanged.
//
// Files that share an entrypoint share an isolate. Files that talk to a real
// socket keep their own: the first widget test installs the test binding,
// whose HttpOverrides answer every request with 400. A test that passes on
// its own but fails here is relying on state an earlier file left behind
// (preferences, statics); make it set up what it relies on.
//
// Run a single file with plain `flutter test <file>` as usual.
import 'dart:io';

final RegExp _realSocketUse = RegExp(
  r'HttpServer\.bind|ServerSocket\.bind|SecureServerSocket|HttpClient\(|'
  r'Socket\.connect|WebSocket\.connect|RawDatagramSocket|HttpOverrides',
);

Future<void> main(List<String> args) async {
  // Fixed rather than derived from the core count, so CI and every machine
  // group the same files and a failure caused by another file's leftover
  // state reproduces anywhere.
  var shardCount = 8;
  final flutterArgs = <String>[];
  for (final arg in args) {
    if (arg.startsWith('--shards=')) {
      shardCount = int.parse(arg.substring('--shards='.length));
      if (shardCount < 1) {
        stderr.writeln('--shards must be at least 1.');
        exitCode = 64;
        return;
      }
    } else {
      flutterArgs.add(arg);
    }
  }

  final sources = <String, String>{
    for (final file in Directory('test').listSync(recursive: true))
      if (file is File && file.path.endsWith('_test.dart'))
        file.path.replaceAll(r'\', '/'): file.readAsStringSync(),
  };
  final plan = planTestShards(sources, shardCount: shardCount);

  // Under test/ so flutter_test_config.dart applies; per run so concurrent
  // runs in one checkout keep their own.
  final shardDirectory = Directory('test').createTempSync('.shards_');
  final entrypoints = <String>[];
  try {
    for (var index = 0; index < plan.shards.length; index++) {
      final entrypoint = '${shardDirectory.path}/shard_$index.dart';
      File(entrypoint).writeAsStringSync(renderShard(plan.shards[index]));
      entrypoints.add(entrypoint);
    }
    stdout.writeln(
      'Running ${sources.length} test files as ${plan.shards.length} shards '
      'and ${plan.standalone.length} standalone files.',
    );
    final flutter = await Process.start(
      Platform.isWindows ? 'flutter.bat' : 'flutter',
      ['test', ...entrypoints, ...plan.standalone, ...flutterArgs],
      mode: ProcessStartMode.inheritStdio,
    );
    exitCode = await flutter.exitCode;
  } finally {
    if (shardDirectory.existsSync()) shardDirectory.deleteSync(recursive: true);
  }
}

/// Test files grouped into combined entrypoints, plus the files that must
/// keep their own.
class TestShardPlan {
  const TestShardPlan(this.shards, this.standalone);

  /// Each shard's test file paths, heaviest shard first.
  final List<List<String>> shards;

  /// Files that run as their own entrypoint.
  final List<String> standalone;
}

/// Splits [sources] (test file path to contents) into at most [shardCount]
/// runs of alphabetically adjacent files with similar total size. Adding a
/// file then moves only files near a shard boundary, so each file keeps
/// nearly the same neighbours from run to run. Every file is scheduled
/// exactly once.
TestShardPlan planTestShards(
  Map<String, String> sources, {
  required int shardCount,
}) {
  final paths = sources.keys.toList()..sort();
  final standalone = [
    for (final path in paths)
      if (_realSocketUse.hasMatch(sources[path]!)) path,
  ];
  final shardable = [
    for (final path in paths)
      if (!standalone.contains(path)) path,
  ];

  final total = shardable.fold(0, (sum, path) => sum + sources[path]!.length);
  final shards = <({int size, List<String> paths})>[];
  var current = <String>[];
  var size = 0;
  var cumulative = 0;
  for (final path in shardable) {
    final length = sources[path]!.length;
    // Cut where the running total lands nearest the next even split.
    final boundary = total * (shards.length + 1) / shardCount;
    if (current.isNotEmpty &&
        cumulative + length - boundary > boundary - cumulative) {
      shards.add((size: size, paths: current));
      current = <String>[];
      size = 0;
    }
    current.add(path);
    size += length;
    cumulative += length;
  }
  if (current.isNotEmpty) shards.add((size: size, paths: current));
  shards.sort((a, b) => b.size.compareTo(a.size));

  final plan = TestShardPlan([
    for (final shard in shards) shard.paths,
  ], standalone);
  final scheduled = [...plan.shards.expand((paths) => paths), ...standalone];
  if (scheduled.length != paths.length ||
      !scheduled.toSet().containsAll(paths)) {
    throw StateError('Shard plan does not schedule every test file once.');
  }
  return plan;
}

/// The source of a shard entrypoint that runs each of [paths] (relative to
/// the package root) in a group named after the file.
String renderShard(List<String> paths) {
  final buffer = StringBuffer()
    ..writeln('// Generated by tool/run_test_shards.dart. Do not edit.')
    ..writeln("import 'package:flutter_test/flutter_test.dart';")
    ..writeln();
  for (var index = 0; index < paths.length; index++) {
    final relative = paths[index].replaceFirst('test/', '../');
    buffer.writeln("import '$relative' as t$index;");
  }
  buffer
    ..writeln()
    ..writeln('void main() {');
  for (var index = 0; index < paths.length; index++) {
    final name = paths[index].replaceFirst('test/', '');
    buffer.writeln("  group('$name', t$index.main);");
  }
  buffer.writeln('}');
  return buffer.toString();
}
