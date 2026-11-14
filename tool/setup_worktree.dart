// Prepares a fresh clone or worktree for the analyzer and the tests.
//
//   dart tool/setup_worktree.dart
//
// It fetches the two submodules the build needs when they are missing, runs
// `flutter pub get`, and generates code for the app and for every workspace
// package that uses build_runner.
//
// It runs before `flutter pub get`, so it imports only the Dart SDK.
//
// T3 Code starts it from t3.json when it creates a worktree, in the
// background, so an agent can begin before it ends. `.t3/setup-running` holds
// this process's PID until setup ends with `.t3/setup-done` or
// `.t3/setup-failed`, which carries the end of the failing step's output.
// Agents wait on those files instead of racing setup with a `pub get` of
// their own.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Submodules `flutter pub get` and the asset bundle read. The other
/// submodules are reference sources that no build step opens.
const List<String> _buildSubmodules = [
  'third_party/katex',
  'third_party/mermaid',
];

/// Lines of a failing step's output kept for `.t3/setup-failed`.
const int _failureTailLines = 30;

final Set<Process> _running = <Process>{};

Future<void> main() async {
  final root = File.fromUri(Platform.script).parent.parent.path;
  final markers = Directory('$root/.t3')..createSync(recursive: true);
  final runningMarker = File('${markers.path}/setup-running');
  final doneMarker = File('${markers.path}/setup-done');
  final failedMarker = File('${markers.path}/setup-failed');
  for (final stale in [doneMarker, failedMarker]) {
    if (stale.existsSync()) stale.deleteSync();
  }
  runningMarker.writeAsStringSync('$pid\n');

  void finish(String? failure) {
    if (failure == null) {
      doneMarker.writeAsStringSync('');
    } else {
      failedMarker.writeAsStringSync('$failure\n');
    }
    if (runningMarker.existsSync()) runningMarker.deleteSync();
  }

  // A cancelled setup must still leave a marker, or agents would wait
  // forever.
  for (final signal in [
    ProcessSignal.sigint,
    ProcessSignal.sigterm,
    if (!Platform.isWindows) ProcessSignal.sighup,
  ]) {
    signal.watch().listen((received) {
      for (final process in _running) {
        process.kill(received);
      }
      finish('Cancelled by $received.');
      exit(1);
    });
  }

  try {
    await _setUp(root);
    finish(null);
    stdout.writeln('Setup finished.');
    // The signal subscriptions would otherwise keep the process alive.
    exit(0);
  } on _StepFailed catch (failure) {
    finish(failure.toString());
    stderr.writeln('Setup failed: ${failure.step}');
    exit(1);
  }
}

Future<void> _setUp(String root) async {
  final missing = [
    for (final path in _buildSubmodules)
      if (_isEmpty(Directory('$root/$path'))) path,
  ];
  if (missing.isNotEmpty) {
    await _run(root, 'submodules', [
      'git',
      'submodule',
      'update',
      '--init',
      '--recursive',
      '--depth',
      '1',
      ...missing,
    ]);
  }

  // One `pub get` at the workspace root resolves every member.
  await _run(root, 'pub get', ['flutter', 'pub', 'get']);

  // Each member keeps its own build cache and none waits on another's
  // output, so the app and the packages generate side by side.
  await Future.wait([
    _run(root, 'codegen app', _buildRunner),
    for (final package in codegenPackages(root))
      _run('$root/$package', 'codegen $package', _buildRunner),
  ]);
}

const List<String> _buildRunner = ['dart', 'run', 'build_runner', 'build'];

/// Workspace packages that declare build_runner, as paths from [root].
List<String> codegenPackages(String root) {
  final packages = Directory('$root/packages');
  if (!packages.existsSync()) return const [];
  final names = <String>[];
  for (final entry in packages.listSync()) {
    final pubspec = File('${entry.path}/pubspec.yaml');
    if (entry is Directory &&
        pubspec.existsSync() &&
        RegExp(
          r'^  build_runner:',
          multiLine: true,
        ).hasMatch(pubspec.readAsStringSync())) {
      names.add(
        'packages/${entry.uri.pathSegments.lastWhere((s) => s.isNotEmpty)}',
      );
    }
  }
  return names..sort();
}

bool _isEmpty(Directory directory) =>
    !directory.existsSync() || directory.listSync().isEmpty;

/// Runs one step, passing its output through with the step's name in front.
/// Throws [_StepFailed] with the end of that output when it exits non-zero.
Future<void> _run(String directory, String step, List<String> command) async {
  stdout.writeln('[$step] ${command.join(' ')}');
  final process = await Process.start(
    command.first,
    command.sublist(1),
    workingDirectory: directory,
    // flutter and dart are .bat shims on Windows.
    runInShell: Platform.isWindows,
  );
  _running.add(process);
  final tail = <String>[];
  Future<void> forward(Stream<List<int>> source, IOSink target) => source
      .transform(const Utf8Decoder(allowMalformed: true))
      .transform(const LineSplitter())
      .forEach((line) {
        target.writeln('[$step] $line');
        tail.add(line);
        if (tail.length > _failureTailLines) tail.removeAt(0);
      });
  await Future.wait([
    forward(process.stdout, stdout),
    forward(process.stderr, stderr),
  ]);
  final code = await process.exitCode;
  _running.remove(process);
  if (code != 0) throw _StepFailed(step, code, tail);
}

class _StepFailed implements Exception {
  _StepFailed(this.step, this.code, this.tail);

  final String step;
  final int code;
  final List<String> tail;

  @override
  String toString() => ['$step exited with code $code.', ...tail].join('\n');
}
