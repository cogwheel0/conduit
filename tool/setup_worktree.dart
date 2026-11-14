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

final Launcher _launcher = Launcher();

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
    ProcessSignal.sighup,
    // Watching SIGTERM throws on Windows.
    if (!Platform.isWindows) ProcessSignal.sigterm,
  ]) {
    signal.watch().listen((received) async {
      // The marker says nothing is writing any more, so wait for that to be
      // true before leaving it.
      await _launcher.stop(received);
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
  } catch (error) {
    // A program that is not installed fails to start instead of exiting
    // non-zero; that still has to end with a marker.
    finish('$error');
    stderr.writeln('Setup failed: $error');
    exit(1);
  }
}

typedef StartProcess = Future<Process> Function(
  String executable,
  List<String> arguments,
  String directory,
);

Future<Process> _startProcess(
  String executable,
  List<String> arguments,
  String directory,
) => Process.start(
  executable,
  arguments,
  workingDirectory: directory,
  // flutter and dart are .bat shims on Windows.
  runInShell: Platform.isWindows,
);

/// Starts setup's programs and can stop them all, including one that was
/// still starting when the stop was asked for.
class Launcher {
  Launcher([this._start = _startProcess]);

  final StartProcess _start;
  final Set<Future<Process>> _starting = <Future<Process>>{};
  final Set<Process> _running = <Process>{};
  bool _stopping = false;

  /// Starts a program. Throws [StateError] once [stop] has been called.
  Future<Process> start(
    String executable,
    List<String> arguments,
    String directory,
  ) async {
    if (_stopping) throw StateError('Setup was cancelled.');
    final starting = _start(executable, arguments, directory);
    _starting.add(starting);
    try {
      final process = await starting;
      _running.add(process);
      unawaited(process.exitCode.whenComplete(() => _running.remove(process)));
      return process;
    } finally {
      _starting.remove(starting);
    }
  }

  /// Stops every program with [stopAll], and allows no more to start.
  Future<void> stop(
    ProcessSignal signal, {
    Duration grace = const Duration(seconds: 10),
  }) async {
    _stopping = true;
    // A start already under way cannot be taken back, so wait for it to land
    // and stop that program with the rest.
    final landed = await Future.wait([
      for (final starting in _starting.toList())
        starting.then<Process?>((process) => process, onError: (_) => null),
    ]);
    await stopAll({..._running, ...landed.nonNulls}, signal, grace: grace);
  }
}

/// Sends [signal] to each of [processes] and returns once all have exited.
/// One that is still running after [grace] is killed outright, and waited
/// for as well.
Future<void> stopAll(
  Iterable<Process> processes,
  ProcessSignal signal, {
  Duration grace = const Duration(seconds: 10),
}) async {
  final running = processes.toList();
  final exits = Future.wait([for (final process in running) process.exitCode]);
  for (final process in running) {
    process.kill(signal);
  }
  await exits.timeout(
    grace,
    onTimeout: () {
      for (final process in running) {
        process.kill(ProcessSignal.sigkill);
      }
      // SIGKILL cannot be ignored, so this wait ends.
      return exits;
    },
  );
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
  // output, so the app and the packages generate side by side. Future.wait
  // reports a failure only once every generator has exited, so none is still
  // writing when the failure marker appears.
  // Listed before any generator starts, so a failure to read a pubspec
  // cannot leave one running.
  final packages = codegenPackages(root);
  await Future.wait([
    _run(root, 'codegen app', _buildRunner),
    for (final package in packages)
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
  final process = await _launcher.start(
    command.first,
    command.sublist(1),
    directory,
  );
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
