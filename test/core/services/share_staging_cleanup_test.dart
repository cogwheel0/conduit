import 'dart:async';
import 'dart:io';

import 'package:checks/checks.dart';
import 'package:conduit/core/services/share_staging_cleanup.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  group('share staging path ownership', () {
    test(
      'deletes a regular UUID file in the exact native staging root',
      () async {
        final stagingDirectory = Directory(
          p.join(Directory.systemTemp.path, 'conduit-native-paste'),
        );
        await stagingDirectory.create();
        final file = File(
          p.join(
            stagingDirectory.path,
            '123e4567-e89b-12d3-a456-426614174000-'
            '${DateTime.now().microsecondsSinceEpoch}.png',
          ),
        );
        await file.writeAsBytes([1, 2, 3]);
        addTearDown(() async {
          if (await file.exists()) await file.delete();
        });

        expect(await isShareStagingPath(file.path), isTrue);
        await deleteShareStagingFile(file.path);

        expect(await file.exists(), isFalse);
      },
    );

    test('reports an injected owned-file delete failure', () async {
      final stagingDirectory = Directory(
        p.join(Directory.systemTemp.path, 'conduit-native-paste'),
      );
      await stagingDirectory.create();
      final file = File(
        p.join(
          stagingDirectory.path,
          '123e4567-e89b-12d3-a456-426614174010-'
          '${DateTime.now().microsecondsSinceEpoch}.png',
        ),
      );
      await file.writeAsBytes([1, 2, 3]);
      addTearDown(() async {
        if (await file.exists()) await file.delete();
      });

      final result = await deleteShareStagingFileWithResult(
        file.path,
        deleteFile: (_) async {
          throw const FileSystemException('injected delete failure');
        },
      );

      expect(result, ShareStagingFileCleanupResult.failed);
      expect(await file.exists(), isTrue);
    });

    test('runs final delete admission and unlink in one turn', () async {
      final stagingDirectory = Directory(
        p.join(Directory.systemTemp.path, 'conduit-native-paste'),
      );
      await stagingDirectory.create();
      final file = File(
        p.join(
          stagingDirectory.path,
          '123e4567-e89b-12d3-a456-426614174015-'
          '${DateTime.now().microsecondsSinceEpoch}.png',
        ),
      );
      await file.writeAsBytes([1]);
      addTearDown(() async {
        if (await file.exists()) await file.delete();
      });
      final replacementWritten = Completer<void>();
      var pathWasAbsentBeforeReplacement = false;

      final result = await deleteShareStagingFileWithResult(
        file.path,
        canDelete: (_) {
          scheduleMicrotask(() {
            pathWasAbsentBeforeReplacement = !file.existsSync();
            file.writeAsBytesSync([2]);
            replacementWritten.complete();
          });
          return true;
        },
      );
      await replacementWritten.future;

      // The queued replacement must run after the admitted unlink. An await
      // between admission and unlink reverses the order and deletes byte 2.
      expect(pathWasAbsentBeforeReplacement, isTrue);
      expect(await file.readAsBytes(), [2]);
      expect(result, ShareStagingFileCleanupResult.removed);
    });

    test('recheck accepts a delete that throws after unlinking', () async {
      final stagingDirectory = Directory(
        p.join(Directory.systemTemp.path, 'conduit-native-paste'),
      );
      await stagingDirectory.create();
      final file = File(
        p.join(
          stagingDirectory.path,
          '123e4567-e89b-12d3-a456-426614174011-'
          '${DateTime.now().microsecondsSinceEpoch}.png',
        ),
      );
      await file.writeAsBytes([1, 2, 3]);

      final result = await deleteShareStagingFileWithResult(
        file.path,
        deleteFile: (candidate) async {
          await candidate.delete();
          throw const FileSystemException('late platform failure');
        },
      );

      expect(result, ShareStagingFileCleanupResult.removed);
      expect(await file.exists(), isFalse);
    });

    test(
      'reclaims files staged by pre-upgrade builds under legacy roots',
      () async {
        for (final legacyRootName in const ['shared-incoming',
            'shared-intents']) {
          final legacyRoot = Directory(
            p.join(Directory.systemTemp.path, legacyRootName),
          );
          await legacyRoot.create();
          final deletable = File(
            p.join(
              legacyRoot.path,
              '123e4567-e89b-12d3-a456-426614174020-'
              '${DateTime.now().microsecondsSinceEpoch}.png',
            ),
          );
          await deletable.writeAsBytes([1, 2, 3]);
          final terminal = File(
            p.join(
              legacyRoot.path,
              '123e4567-e89b-12d3-a456-426614174021-'
              '${DateTime.now().microsecondsSinceEpoch}.png',
            ),
          );
          await terminal.writeAsBytes([4, 5, 6]);
          addTearDown(() async {
            if (await deletable.exists()) await deletable.delete();
            if (await terminal.exists()) await terminal.delete();
          });

          // Legacy roots are cleanup-owned only: staging must still copy out
          // of them instead of adopting the legacy path in place.
          check(await isShareStagingPath(deletable.path)).isFalse();
          final stageResult = await stageIncomingSharedFileWithResult(
            deletable.path,
            deletePluginSourceAfterCopy: false,
          );
          check(stageResult.copied).isTrue();
          await deleteShareStagingFile(stageResult.file.path);

          check(
            await deleteShareStagingFileWithResult(deletable.path),
          ).equals(ShareStagingFileCleanupResult.removed);
          check(await deletable.exists()).isFalse();

          check(await cleanupTerminalAttachmentFile(terminal.path)).isTrue();
          check(await terminal.exists()).isFalse();
        }
      },
    );

    test(
      'does not delete a UUID file under a matching outside directory',
      () async {
        final outside = await Directory.systemTemp.createTemp(
          'conduit_share_cleanup_outside_',
        );
        addTearDown(() async {
          if (await outside.exists()) {
            await outside.delete(recursive: true);
          }
        });
        final impostorDirectory = Directory(
          p.join(outside.path, 'conduit-native-paste'),
        );
        await impostorDirectory.create();
        final file = File(
          p.join(
            impostorDirectory.path,
            '123e4567-e89b-12d3-a456-426614174000-outside.png',
          ),
        );
        await file.writeAsBytes([1, 2, 3]);

        expect(await isShareStagingPath(file.path), isFalse);
        await deleteShareStagingFile(file.path);

        expect(await file.exists(), isTrue);
      },
    );

    test(
      'retains unrelated regular files directly under system temp',
      () async {
        final file = File(
          p.join(
            Directory.systemTemp.path,
            'unrelated-${DateTime.now().microsecondsSinceEpoch}.txt',
          ),
        );
        await file.writeAsString('not owned by Conduit');
        addTearDown(() async {
          if (await file.exists()) await file.delete();
        });
        var deleteCalled = false;

        final handled = await deleteIncomingSharedSourceIfSafe(
          file.path,
          deleteFile: (_) async => deleteCalled = true,
        );

        check(handled).isFalse();
        check(deleteCalled).isFalse();
        check(await file.exists()).isTrue();
      },
    );

    test('plugin source deletion lease is exact and one-use', () async {
      final root = await Directory.systemTemp.createTemp(
        'conduit_plugin_lease_',
      );
      final source = File(p.join(root.path, 'plugin-source.txt'));
      await source.writeAsString('leased');
      addTearDown(() async {
        if (await root.exists()) await root.delete(recursive: true);
      });
      final lease = await createIncomingSharedSourceDeletionLease(
        source.path,
        trustedPluginRoot: root,
      );

      check(lease).isNotNull();
      check(await deleteIncomingSharedSourceIfSafe(lease!)).isTrue();
      check(await deleteIncomingSharedSourceIfSafe(lease)).isFalse();
      check(await source.exists()).isFalse();
    });

    test('plugin source lease rejects same-path replacement bytes', () async {
      final root = await Directory.systemTemp.createTemp(
        'conduit_plugin_lease_replacement_',
      );
      final source = File(p.join(root.path, 'plugin-source.txt'));
      await source.writeAsString('original');
      addTearDown(() async {
        if (await root.exists()) await root.delete(recursive: true);
      });
      final lease = await createIncomingSharedSourceDeletionLease(
        source.path,
        trustedPluginRoot: root,
      );
      await source.writeAsString('replacement bytes');

      check(lease).isNotNull();
      check(await deleteIncomingSharedSourceIfSafe(lease!)).isFalse();
      check(await source.readAsString()).equals('replacement bytes');
    });

    test(
      'native root lookup failure keeps terminal ownership indeterminate',
      () async {
        final container = await Directory.systemTemp.createTemp(
          'conduit_native_root_failure_',
        );
        final file = File(
          p.join(
            container.path,
            '123e4567-e89b-12d3-a456-426614174012-shared.jpg',
          ),
        );
        await file.writeAsBytes([1, 2, 3]);
        addTearDown(() async {
          if (await container.exists()) {
            await container.delete(recursive: true);
          }
        });

        Future<Directory?> failingNativeRootResolver() {
          throw PlatformException(code: 'app-group-unavailable');
        }

        final result = await deleteShareStagingFileWithResult(
          file.path,
          nativeStagingRootResolver: failingNativeRootResolver,
        );
        final terminalCleaned = await cleanupTerminalAttachmentFile(
          file.path,
          nativeStagingRootResolver: failingNativeRootResolver,
        );

        expect(result, ShareStagingFileCleanupResult.failed);
        expect(terminalCleaned, isFalse);
        expect(await file.exists(), isTrue);
      },
    );

    test(
      'staging does not copy when ownership resolution is indeterminate',
      () async {
        final container = await Directory.systemTemp.createTemp(
          'conduit_stage_indeterminate_',
        );
        final file = File(
          p.join(
            container.path,
            '123e4567-e89b-12d3-a456-426614174014-shared.jpg',
          ),
        );
        await file.writeAsBytes([1, 2, 3]);
        addTearDown(() async {
          if (await container.exists()) {
            await container.delete(recursive: true);
          }
        });

        final stagingDirectory = Directory(
          p.join(Directory.systemTemp.path, shareStagingDirectoryName),
        );
        final artifactsBefore = await _directArtifactSet(stagingDirectory);

        await check(
          stageIncomingSharedFile(
            file.path,
            nativeStagingRootResolver: () {
              throw const FileSystemException('injected resolution failure');
            },
          ),
        ).throws<FileSystemException>();
        check(await file.exists()).isTrue();
        check(
          await _directArtifactSet(stagingDirectory),
        ).deepEquals(artifactsBefore);
      },
    );

    test('does not follow a staging-file symlink to an outside file', () async {
      final outside = await Directory.systemTemp.createTemp(
        'conduit_share_cleanup_symlink_target_',
      );
      final target = File(p.join(outside.path, 'keep.txt'));
      await target.writeAsString('keep me');

      final stagingDirectory = Directory(
        p.join(Directory.systemTemp.path, 'conduit-native-paste'),
      );
      await stagingDirectory.create();
      final link = Link(
        p.join(
          stagingDirectory.path,
          '123e4567-e89b-12d3-a456-426614174000-'
          '${DateTime.now().microsecondsSinceEpoch}-link.png',
        ),
      );
      await link.create(target.path);
      addTearDown(() async {
        if (await link.exists()) await link.delete();
        if (await outside.exists()) await outside.delete(recursive: true);
      });

      expect(await isShareStagingPath(link.path), isFalse);
      await deleteShareStagingFile(link.path);

      expect(await target.exists(), isTrue);
      expect(await link.exists(), isTrue);
    });

    test(
      'accepts and deletes files in a native-resolved trusted root',
      () async {
        final container = await Directory.systemTemp.createTemp(
          'conduit_app_group_simulation_',
        );
        final stagingDirectory = Directory(
          p.join(container.path, shareStagingDirectoryName),
        );
        await stagingDirectory.create();
        final file = File(
          p.join(
            stagingDirectory.path,
            '123e4567-e89b-12d3-a456-426614174002-shared.jpg',
          ),
        );
        await file.writeAsBytes([1, 2, 3]);
        addTearDown(() async {
          if (await container.exists()) {
            await container.delete(recursive: true);
          }
        });

        Future<Directory?> resolveNativeStagingRoot() async => stagingDirectory;

        check(
          await isShareStagingPath(
            file.path,
            nativeStagingRootResolver: resolveNativeStagingRoot,
          ),
        ).isTrue();
        final staged = await stageIncomingSharedFile(
          file.path,
          nativeStagingRootResolver: resolveNativeStagingRoot,
        );
        check(
          p.normalize(await staged.resolveSymbolicLinks()),
        ).equals(p.normalize(await file.resolveSymbolicLinks()));

        await deleteShareStagingFile(
          file.path,
          nativeStagingRootResolver: resolveNativeStagingRoot,
        );
        check(await file.exists()).isFalse();
      },
    );

    test('terminal cleanup accepts an additional trusted root', () async {
      final container = await Directory.systemTemp.createTemp(
        'conduit_terminal_trusted_root_',
      );
      final stagingDirectory = Directory(
        p.join(container.path, shareStagingDirectoryName),
      );
      await stagingDirectory.create();
      final file = File(
        p.join(
          stagingDirectory.path,
          '123e4567-e89b-12d3-a456-426614174015-shared.jpg',
        ),
      );
      await file.writeAsBytes([1, 2, 3]);
      addTearDown(() async {
        if (await container.exists()) {
          await container.delete(recursive: true);
        }
      });

      check(
        await cleanupTerminalAttachmentFile(
          file.path,
          additionalTrustedRoots: [stagingDirectory],
        ),
      ).isTrue();
      check(await file.exists()).isFalse();
    });

    test('sidecar cleanup forwards the native staging resolver', () async {
      final container = await Directory.systemTemp.createTemp(
        'conduit_sidecar_native_root_',
      );
      final stagingDirectory = Directory(
        p.join(container.path, shareStagingDirectoryName),
      );
      await stagingDirectory.create();
      final file = File(
        p.join(
          stagingDirectory.path,
          '123e4567-e89b-12d3-a456-426614174016-thumbnail.jpg',
        ),
      );
      await file.writeAsBytes([1, 2, 3]);
      addTearDown(() async {
        if (await container.exists()) {
          await container.delete(recursive: true);
        }
      });

      await deleteIgnoredShareSidecarFile(
        file.path,
        nativeStagingRootResolver: () async => stagingDirectory,
      );
      check(await file.exists()).isFalse();
    });

    test('trusted-root cleanup still rejects escaping symlinks', () async {
      final container = await Directory.systemTemp.createTemp(
        'conduit_app_group_symlink_',
      );
      final stagingDirectory = Directory(
        p.join(container.path, shareStagingDirectoryName),
      );
      await stagingDirectory.create();
      final outside = File(p.join(container.path, 'outside.jpg'));
      await outside.writeAsBytes([1, 2, 3]);
      final link = Link(
        p.join(
          stagingDirectory.path,
          '123e4567-e89b-12d3-a456-426614174003-link.jpg',
        ),
      );
      await link.create(outside.path);
      addTearDown(() async {
        if (await container.exists()) {
          await container.delete(recursive: true);
        }
      });

      expect(
        await isShareStagingPath(
          link.path,
          additionalTrustedRoots: [stagingDirectory],
        ),
        isFalse,
      );
      await deleteShareStagingFile(
        link.path,
        additionalTrustedRoots: [stagingDirectory],
      );

      expect(await outside.exists(), isTrue);
      expect(await link.exists(), isTrue);
    });

    test('removes an owned image-conversion temp directory', () async {
      final directory = await Directory.systemTemp.createTemp('conduit_img_');
      final converted = File(p.join(directory.path, 'converted.jpg'));
      await converted.writeAsBytes([1, 2, 3]);
      addTearDown(() async {
        if (await directory.exists()) await directory.delete(recursive: true);
      });

      expect(await cleanupTerminalAttachmentFile(converted.path), isTrue);
      expect(await converted.exists(), isFalse);
      expect(await directory.exists(), isFalse);
    });

    test('reports an injected conversion-file delete failure', () async {
      final directory = await Directory.systemTemp.createTemp('conduit_img_');
      final converted = File(p.join(directory.path, 'converted.jpg'));
      await converted.writeAsBytes([1, 2, 3]);
      addTearDown(() async {
        if (await directory.exists()) await directory.delete(recursive: true);
      });

      final cleaned = await cleanupTerminalAttachmentFile(
        converted.path,
        deleteFile: (_) async {
          throw const FileSystemException('injected conversion failure');
        },
      );

      expect(cleaned, isFalse);
      expect(await converted.exists(), isTrue);
      expect(await directory.exists(), isTrue);
    });

    test(
      'rejects a converted.jpg symlink in an otherwise valid temp child',
      () async {
        final directory = await Directory.systemTemp.createTemp('conduit_img_');
        final outside = await Directory.systemTemp.createTemp(
          'conduit_conversion_target_',
        );
        final target = File(p.join(outside.path, 'keep.jpg'));
        final convertedLink = Link(p.join(directory.path, 'converted.jpg'));
        await target.writeAsBytes([4, 5, 6]);
        await convertedLink.create(target.path);
        addTearDown(() async {
          if (await directory.exists()) {
            await directory.delete(recursive: true);
          }
          if (await outside.exists()) await outside.delete(recursive: true);
        });

        expect(await resolveConvertedUploadFile(convertedLink.path), isNull);
        expect(
          await cleanupTerminalAttachmentFile(convertedLink.path),
          isFalse,
        );
        expect(await target.readAsBytes(), [4, 5, 6]);
        expect(
          await FileSystemEntity.type(convertedLink.path, followLinks: false),
          FileSystemEntityType.link,
        );
      },
    );

    test(
      'rejects a non-exact filename in a valid conversion directory',
      () async {
        final directory = await Directory.systemTemp.createTemp('conduit_img_');
        final lookalike = File(p.join(directory.path, 'converted.jpeg'));
        await lookalike.writeAsBytes([7, 8, 9]);
        addTearDown(() async {
          if (await directory.exists()) {
            await directory.delete(recursive: true);
          }
        });

        expect(await resolveConvertedUploadFile(lookalike.path), isNull);
        expect(await cleanupTerminalAttachmentFile(lookalike.path), isTrue);
        expect(await lookalike.readAsBytes(), [7, 8, 9]);
        expect(await directory.exists(), isTrue);
      },
    );
  });
}

Future<Set<String>> _directArtifactSet(Directory directory) async {
  if (!await directory.exists()) return <String>{};
  return directory
      .list(followLinks: false)
      .map((entity) => '${entity.runtimeType}:${p.basename(entity.path)}')
      .toSet();
}
