import 'package:checks/checks.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../../tool/run_test_shards.dart';

void main() {
  test('plan keeps socket files standalone and every file once', () {
    final sources = {
      'test/a_test.dart': 'x' * 400,
      // Split so this file is not itself classified as opening sockets.
      'test/b_test.dart':
          'await HttpServer'
          '.bind(host, 0);',
      'test/c/d_test.dart': 'x' * 400,
      'test/e_test.dart': 'x' * 400,
      'test/f_test.dart': 'x' * 400,
    };

    final plan = planTestShards(sources, shardCount: 2);

    check(plan.standalone).deepEquals(['test/b_test.dart']);
    check(plan.shards.length).equals(2);
    check([...plan.shards.expand((shard) => shard), ...plan.standalone]..sort())
        .deepEquals(sources.keys.toList()..sort());
    // Contiguous alphabetical runs, so adding a file only moves its
    // neighbours at a shard boundary.
    final ordered =
        sources.keys.where((path) => path != 'test/b_test.dart').toList()
          ..sort();
    check(
      (plan.shards.toList()..sort((a, b) => a.first.compareTo(b.first)))
          .expand((shard) => shard)
          .toList(),
    ).deepEquals(ordered);
  });

  test('a shard imports and registers every file it is given', () {
    const paths = ['test/a_test.dart', 'test/c/d_test.dart'];
    const shardDirectory = 'test/.shards_x';

    final source = renderShard(paths);

    final imports = {
      for (final match in RegExp(
        r"^import '([^']+)' as (\w+);$",
        multiLine: true,
      ).allMatches(source))
        match.group(2)!: p.normalize(p.join(shardDirectory, match.group(1)!)),
    };
    final groups = {
      for (final match in RegExp(
        r"^  group\('([^']+)', (\w+)\.main\);$",
        multiLine: true,
      ).allMatches(source))
        match.group(1)!: match.group(2)!,
    };
    check(groups.length).equals(paths.length);
    for (final path in paths) {
      final prefix = groups[p.relative(path, from: 'test')];
      check(because: path, prefix).isNotNull();
      check(because: path, imports[prefix]).equals(path);
    }
  });
}
