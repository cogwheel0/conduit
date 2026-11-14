// Runs CI's fast checks for what this branch changed.
//
//   dart run tool/check_changed.dart         compare with the merge base with origin/main
//   dart run tool/check_changed.dart <ref>   compare with the merge base with <ref>
//   dart run tool/check_changed.dart --list  print the steps without running them
//
// Committed, uncommitted and untracked files all count. From them it picks:
// the platform UI seam, the package boundaries and the ARB checks when their
// inputs changed; the analyzer for each workspace member that changed and for
// every member that depends on one; the test files beside the changed files;
// and the relay's format and lint checks.
//
// CI still runs the full test suites and the jobs listed at the end of the
// summary. Steps run one at a time: analyzers started together race to build
// the plugin they share under ~/.dartServer.
//
// Run it from the repository root, after tool/setup_worktree.dart.
import 'dart:io';

/// The app's directory in a [Workspace]; packages are `packages/<name>`.
const String appMember = '.';

/// One command of the plan.
class Step {
  const Step(
    this.name,
    this.command, {
    this.directory = '.',
    this.optional = false,
  });

  final String name;
  final List<String> command;

  /// Where the command runs, from the repository root.
  final String directory;

  /// Whether the step is skipped, not failed, when its program is missing.
  /// Only for a toolchain a Flutter checkout can do without.
  final bool optional;

  @override
  String toString() =>
      '$name: ${directory == '.' ? '' : '(in $directory) '}${command.join(' ')}';
}

class Plan {
  const Plan(this.steps, this.leftToCi);

  final List<Step> steps;

  /// CI jobs the changed files reach that this tool does not run.
  final List<String> leftToCi;
}

/// The pub workspace: the app, its packages and which depends on which.
class Workspace {
  Workspace(this.dependencies);

  /// Reads each member's name and dependencies from its pubspec, given as
  /// member directory to pubspec text. [appMember] is the app.
  factory Workspace.fromPubspecs(Map<String, String> pubspecs) {
    final directoryOf = <String, String>{
      for (final entry in pubspecs.entries)
        if (RegExp(r'^name:\s*(\S+)', multiLine: true).firstMatch(entry.value)
            case final match?)
          match.group(1)!: entry.key,
    };
    return Workspace({
      for (final entry in pubspecs.entries)
        entry.key: {
          for (final name in _dependencyNames(entry.value)) ?directoryOf[name],
        },
    });
  }

  /// Reads the workspace from the pubspecs under [root].
  factory Workspace.read(String root) {
    final rootPubspec = File('$root/pubspec.yaml').readAsStringSync();
    final members = RegExp(r'^\s+-\s+(\S+)\s*$', multiLine: true)
        .allMatches(_block(rootPubspec, 'workspace'))
        .map((match) => match.group(1)!);
    return Workspace.fromPubspecs({
      appMember: rootPubspec,
      for (final member in members)
        member: File('$root/$member/pubspec.yaml').readAsStringSync(),
    });
  }

  /// Each member's directory to the directories of the members it imports.
  final Map<String, Set<String>> dependencies;

  /// The member that analyzes [path], or null when no analyzer reads it.
  String? memberOf(String path) {
    for (final member in dependencies.keys) {
      if (member != appMember && path.startsWith('$member/')) return member;
    }
    const rootFiles = {
      'pubspec.yaml',
      'pubspec.lock',
      'analysis_options.yaml',
      'l10n.yaml',
    };
    final inApp =
        path.startsWith('lib/') ||
        path.startsWith('test/') ||
        rootFiles.contains(path) ||
        // analysis_options.yaml leaves pigeon_codegen to its own pubspec.
        (path.startsWith('tool/') &&
            path.endsWith('.dart') &&
            !path.startsWith('tool/pigeon_codegen/'));
    return inApp ? appMember : null;
  }

  /// [members] and every member that depends on one of them, however far.
  Set<String> withDependents(Set<String> members) {
    final affected = {...members};
    var grew = true;
    while (grew) {
      grew = false;
      for (final entry in dependencies.entries) {
        if (entry.value.any(affected.contains) && affected.add(entry.key)) {
          grew = true;
        }
      }
    }
    return affected;
  }
}

/// The text under the top-level [key] of a pubspec, up to the next one.
String _block(String pubspec, String key) {
  final lines = pubspec.split('\n');
  final start = lines.indexWhere((line) => line.startsWith('$key:'));
  if (start < 0) return '';
  final rest = lines.skip(start + 1);
  return rest
      .takeWhile((line) => line.isEmpty || line.startsWith(RegExp(r'[\s#]')))
      .join('\n');
}

/// What a member imports from its library and from its tests.
Iterable<String> _dependencyNames(String pubspec) =>
    RegExp(r'^  ([A-Za-z0-9_]+):', multiLine: true)
        .allMatches(
          '${_block(pubspec, 'dependencies')}\n'
          '${_block(pubspec, 'dev_dependencies')}',
        )
        .map((match) => match.group(1)!);

bool _reachesAnalyzer(String path) {
  const configs = {
    'pubspec.yaml',
    'pubspec.lock',
    'analysis_options.yaml',
    'build.yaml',
    'l10n.yaml',
  };
  return path.endsWith('.dart') ||
      // The app's localization code is generated from the ARB files.
      path.endsWith('.arb') ||
      configs.contains(path.split('/').last);
}

/// Picks the checks for [changed], the changed paths from the repository
/// root. [exists] says whether a path is still there; deleted files count as
/// changes but have no test to run. [base] is the commit the branch is
/// compared with.
Plan planChecks(
  List<String> changed, {
  required Workspace workspace,
  required bool Function(String path) exists,
  required String base,
}) {
  bool any(bool Function(String path) test) => changed.any(test);
  final steps = <Step>[];

  if (any(
    (path) =>
        (path.startsWith('lib/') && path.endsWith('.dart')) ||
        path.startsWith('tool/platform_ui_'),
  )) {
    steps.add(
      Step('Platform UI seam', [
        'dart',
        'tool/platform_ui_lint.dart',
        '--base-ref',
        base,
      ]),
    );
  }

  if (any(
    (path) =>
        ((path.startsWith('lib/') || path.startsWith('packages/')) &&
            path.endsWith('.dart')) ||
        path.split('/').last == 'pubspec.yaml' ||
        (path.startsWith('ios/Runner/') && path.endsWith('.swift')) ||
        path == 'tool/check_package_boundaries.dart',
  )) {
    steps.add(
      const Step('Package boundaries', [
        'dart',
        'run',
        'tool/check_package_boundaries.dart',
      ]),
    );
  }

  if (any(
    (path) =>
        (path.startsWith('lib/l10n/') && path.endsWith('.arb')) ||
        path == 'tool/verify_arb_descriptions.dart' ||
        path == 'tool/validate_arb_locales.dart',
  )) {
    steps
      ..add(
        const Step('ARB descriptions', [
          'dart',
          'run',
          'tool/verify_arb_descriptions.dart',
        ]),
      )
      ..add(
        const Step('ARB locales', [
          'dart',
          'run',
          'tool/validate_arb_locales.dart',
        ]),
      );
  }

  final changedMembers = {
    // The workspace resolves into one lockfile, so a new version there can
    // reach any member.
    if (changed.contains('pubspec.lock')) ...workspace.dependencies.keys,
    for (final path in changed)
      if (_reachesAnalyzer(path)) ?workspace.memberOf(path),
  };
  // Packages before the app, so the summary reads from the bottom of the
  // dependency graph up.
  final affected = workspace.withDependents(changedMembers).toList()
    ..sort((a, b) => _order(a).compareTo(_order(b)));
  for (final member in affected) {
    steps.add(
      member == appMember
          // The app carries riverpod_lint findings that do not fail CI yet.
          ? const Step('Analyze app', [
              'flutter',
              'analyze',
              '--no-fatal-warnings',
              '--no-fatal-infos',
            ])
          : Step('Analyze ${_label(member)}', [
              'dart',
              'analyze',
              '--fatal-infos',
            ], directory: member),
    );
  }

  final members = workspace.dependencies.keys.toList()
    ..sort((a, b) => _order(a).compareTo(_order(b)));
  for (final member in members) {
    final tests = <String>{};
    for (final path in changed) {
      if (workspace.memberOf(path) != member) continue;
      final relative = member == appMember
          ? path
          : path.substring(member.length + 1);
      final test = _testsFor(relative, inApp: member == appMember)
          .where((test) => exists(member == appMember ? test : '$member/$test'))
          .firstOrNull;
      if (test != null) tests.add(test);
    }
    if (tests.isEmpty) continue;
    final files = tests.toList()..sort();
    steps.add(
      Step(
        'Test ${_label(member)} (${files.length} '
        '${files.length == 1 ? 'file' : 'files'})',
        [if (member == appMember) 'flutter' else 'dart', 'test', ...files],
        directory: member,
      ),
    );
  }

  if (any((path) => path.startsWith('relay/'))) {
    steps
      ..add(
        const Step(
          'Relay format',
          ['cargo', 'fmt', '--check'],
          directory: 'relay',
          optional: true,
        ),
      )
      ..add(
        const Step(
          'Relay lint',
          [
            'cargo',
            'clippy',
            '--all-targets',
            '--locked',
            '--',
            '-D',
            'warnings',
          ],
          directory: 'relay',
          optional: true,
        ),
      );
  }

  return Plan(steps, [
    // A fixture or a helper under test/ can change what any test does.
    if (affected.isNotEmpty ||
        any(
          (path) => workspace.dependencies.keys.any(
            (member) => path.startsWith(
              member == appMember ? 'test/' : '$member/test/',
            ),
          ),
        ))
      'the full Dart test suites',
    if (any((path) => path.startsWith('packages/conduit_markdown/')))
      'Web-safe packages (conduit_markdown compiled to JS and run)',
    if (affected.contains(appMember) || any((p) => p.startsWith('android/')))
      'Android native tests and the foss build',
    if (any((path) => path.startsWith('relay/') || path.startsWith('push/')))
      'Push relay tests (cargo test)',
    if (any(
      (path) => path.startsWith('server-plugins/') || path.startsWith('push/'),
    ))
      'Push server plugins (pytest and the --check scripts)',
    if (any(
      (path) =>
          path.startsWith('ios/ConduitPushCore/') || path.startsWith('push/'),
    ))
      'Push Swift core (swift test)',
    if (any(
      (path) =>
          path.startsWith('tool/computer_viewer/') ||
          path.startsWith('assets/computer/'),
    ))
      'Computer viewer (npm test, build and the shipped bundle)',
  ]);
}

String _order(String member) => member == appMember ? '~' : member;

String _label(String member) =>
    member == appMember ? 'app' : member.split('/').last;

/// Where the test for [path] may be, best guess first, all from the member's
/// own directory: a changed test file itself, or the test beside a changed
/// library or tool.
List<String> _testsFor(String path, {required bool inApp}) {
  if (!path.endsWith('.dart')) return const [];
  if (path.startsWith('test/')) {
    return [if (path.endsWith('_test.dart')) path];
  }
  final stem = path.substring(0, path.length - '.dart'.length);
  if (path.startsWith('lib/')) {
    final library = stem.substring('lib/'.length);
    return [
      'test/${library}_test.dart',
      // Some packages keep lib/src/ but put its tests straight under test/.
      if (library.startsWith('src/'))
        'test/${library.substring('src/'.length)}_test.dart',
    ];
  }
  if (inApp && path.startsWith('tool/')) {
    return ['test/tool/${stem.split('/').last}_test.dart'];
  }
  return const [];
}

Future<void> main(List<String> args) async {
  var list = false;
  String? ref;
  for (final arg in args) {
    if (arg == '--list') {
      list = true;
    } else if (arg.startsWith('-') || ref != null) {
      stderr.writeln(
        'Usage: dart run tool/check_changed.dart [--list] [<ref>]',
      );
      exitCode = 64;
      return;
    } else {
      ref = arg;
    }
  }

  if (!File('pubspec.yaml').existsSync() || !Directory('tool').existsSync()) {
    stderr.writeln('Run this from the repository root.');
    exitCode = 64;
    return;
  }
  if (!list && !File('.dart_tool/package_config.json').existsSync()) {
    stderr.writeln(
      'This checkout is not set up. Run `dart tool/setup_worktree.dart` '
      'first, or wait for it if .t3/setup-running exists.',
    );
    exitCode = 1;
    return;
  }

  final target =
      ref ??
      ['origin/main', 'main'].where((name) {
        return _git(['rev-parse', '--verify', '--quiet', name]) != null;
      }).firstOrNull;
  final base = target == null ? null : _git(['merge-base', 'HEAD', target]);
  if (base == null) {
    stderr.writeln(
      'Cannot find a merge base with ${target ?? 'origin/main or main'}.',
    );
    exitCode = 1;
    return;
  }

  final tracked = _git(['diff', '--name-only', base]);
  final untracked = _git(['ls-files', '--others', '--exclude-standard']);
  if (tracked == null || untracked == null) {
    // An empty list here would read as "nothing changed" and pass.
    stderr.writeln('Cannot list the changed files: git failed.');
    exitCode = 1;
    return;
  }
  final changed = {..._lines(tracked), ..._lines(untracked)}.toList()..sort();
  final plan = planChecks(
    changed,
    workspace: Workspace.read('.'),
    exists: (path) => File(path).existsSync(),
    base: base,
  );

  stdout.writeln(
    '${changed.length} changed ${changed.length == 1 ? 'file' : 'files'} '
    'against $target (${base.substring(0, 9)}).',
  );
  if (list) {
    plan.steps.forEach(stdout.writeln);
    _printLeftToCi(plan);
    return;
  }

  final results = <(Step, String, Duration)>[];
  for (final step in plan.steps) {
    stdout.writeln('\n== ${step.name}');
    final watch = Stopwatch()..start();
    results.add((step, await _run(step), watch.elapsed));
  }

  stdout.writeln();
  if (results.isEmpty) stdout.writeln('Nothing here has a fast check.');
  for (final (step, outcome, elapsed) in results) {
    stdout.writeln(
      '${outcome.padRight(4)}  ${step.name}  ${elapsed.inSeconds}s'
      '${outcome == 'skip' ? '  (${step.command.first} is not installed)' : ''}',
    );
  }
  _printLeftToCi(plan);
  if (results.any((result) => result.$2 == 'FAIL')) exitCode = 1;
}

void _printLeftToCi(Plan plan) {
  if (plan.leftToCi.isEmpty) return;
  stdout.writeln('Left to CI: ${plan.leftToCi.join('; ')}.');
}

/// `pass` or `FAIL`. A step whose program is not installed fails too, unless
/// it is [Step.optional], which gives `skip`.
Future<String> _run(Step step) async {
  try {
    final process = await Process.start(
      step.command.first,
      step.command.sublist(1),
      workingDirectory: step.directory,
      mode: ProcessStartMode.inheritStdio,
      // flutter and dart are .bat shims on Windows and need a shell. Anything
      // else starts directly: through a shell, a missing program is a
      // non-zero exit, which would fail an optional step instead of
      // skipping it.
      runInShell:
          Platform.isWindows &&
          const {'flutter', 'dart'}.contains(step.command.first),
    );
    return await process.exitCode == 0 ? 'pass' : 'FAIL';
  } on ProcessException {
    if (step.optional) return 'skip';
    stderr.writeln('Cannot start ${step.command.first}. Is it installed?');
    return 'FAIL';
  }
}

String? _git(List<String> args) {
  final result = Process.runSync('git', ['-c', 'core.quotepath=off', ...args]);
  return result.exitCode == 0 ? (result.stdout as String).trim() : null;
}

Iterable<String> _lines(String text) =>
    text.split('\n').where((line) => line.isNotEmpty);
