import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';

Future<void> main(List<String> args) => build(args, (input, output) async {
  if (!input.config.buildCodeAssets) return;
  final target = input.config.code;
  final ios = target.targetOS == OS.iOS;
  if (!ios && target.targetOS != OS.android) return;
  final source = input.packageRoot.resolve('native/tailnet/');
  final out = input.outputDirectory;
  final library = out.resolve(
    ios ? 'libconduit_tailnet.dylib' : 'libconduit_tailnet.so',
  );
  final arch = switch (target.targetArchitecture) {
    Architecture.arm64 => 'arm64',
    Architecture.arm => 'arm',
    Architecture.x64 => 'amd64',
    Architecture.ia32 => '386',
    final other => throw UnsupportedError('Tailscale architecture: $other'),
  };
  final env = {
    'GOARCH': arch,
    'GOOS': ios ? 'ios' : 'android',
    'CGO_ENABLED': '1',
  };
  final archive = out.resolve('tailnet.a').toFilePath();
  late List<String> appleFlags;
  if (ios) {
    final sim = target.iOS.targetSdk == IOSSdk.iPhoneSimulator;
    final sdk = sim ? 'iphonesimulator' : 'iphoneos';
    final sdkPath = await _run('xcrun', ['--sdk', sdk, '--show-sdk-path']);
    final clang = await _run('xcrun', ['--sdk', sdk, '--find', 'clang']);
    appleFlags = [
      '-arch',
      arch == 'amd64' ? 'x86_64' : 'arm64',
      '-isysroot',
      sdkPath,
      '${sim ? '-mios-simulator-version-min' : '-miphoneos-version-min'}=${target.iOS.deploymentVersion.major}.${target.iOS.deploymentVersion.minor}',
    ];
    env['CC'] = clang;
    env['CGO_CFLAGS'] = appleFlags.map(_quote).join(' ');
    env['CGO_LDFLAGS'] = env['CGO_CFLAGS']!;
  } else {
    final triple = switch (arch) {
      'arm' => 'armv7a-linux-androideabi',
      'arm64' => 'aarch64-linux-android',
      '386' => 'i686-linux-android',
      _ => 'x86_64-linux-android',
    };
    final targetFlag = '--target=$triple${target.android.targetNdkApi}';
    env['CC'] =
        '${_quote(target.cCompiler!.compiler.toFilePath())} $targetFlag';
    env['CGO_LDFLAGS'] =
        '-Wl,-z,max-page-size=16384 -Wl,-soname,libconduit_tailnet.so';
    if (arch == 'arm') env['GOARM'] = '7';
  }
  await _run(
    'go',
    [
      'build',
      '-mod=readonly',
      '-trimpath',
      '-ldflags=-s -w',
      '-buildmode=${ios ? 'c-archive' : 'c-shared'}',
      '-o',
      ios ? archive : library.toFilePath(),
      '.',
    ],
    directory: source.toFilePath(),
    env: env,
  );
  if (ios) {
    await _run(env['CC']!, [
      ...appleFlags,
      '-dynamiclib',
      '-Wl,-force_load,$archive',
      '-framework',
      'CoreFoundation',
      '-framework',
      'Security',
      '-framework',
      'Foundation',
      '-install_name',
      '@rpath/conduit_tailnet.framework/conduit_tailnet',
      '-o',
      library.toFilePath(),
    ]);
  }
  output.dependencies.addAll(
    Directory.fromUri(source).listSync().whereType<File>().map((f) => f.uri),
  );
  output.assets.code.add(
    CodeAsset(
      package: input.packageName,
      name: 'platform/tailnet_native.dart',
      linkMode: DynamicLoadingBundled(),
      file: library,
    ),
  );
});

String _quote(String value) => '"${value.replaceAll('"', r'\"')}"';

Future<String> _run(
  String executable,
  List<String> args, {
  String? directory,
  Map<String, String>? env,
}) async {
  final result = await Process.run(
    executable,
    args,
    workingDirectory: directory,
    environment: env,
  );
  if (result.exitCode != 0) {
    throw StateError('$executable failed: ${result.stderr}');
  }
  return result.stdout.toString().trim();
}
