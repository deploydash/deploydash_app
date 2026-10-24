import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ui/utils/bounded_int.dart';

import '../../integration_test/support/e2e_checklist.dart';

void main() {
  group('boundedInt', () {
    test('falls back below the minimum', () {
      expect(boundedInt(0, fallback: 20), 20);
      expect(boundedInt(-5, fallback: 5), 5);
      // The minimum itself passes through.
      expect(boundedInt(1, fallback: 20), 1);
    });

    test('passes large values through without a max', () {
      expect(boundedInt(1000000, fallback: 20), 1000000);
    });

    test('caps at max when given', () {
      expect(boundedInt(2001, fallback: 1, max: 1000), 1000);
      // The maximum itself passes through.
      expect(boundedInt(1000, fallback: 1, max: 1000), 1000);
      expect(boundedInt(500, fallback: 1, max: 1000), 500);
    });

    test('honors a custom minimum', () {
      expect(boundedInt(3, fallback: 10, min: 5), 10);
      expect(boundedInt(7, fallback: 10, min: 5), 7);
    });
  });

  group('boundedInt clamp routing (D-20)', () {
    test('clamp sites route through the shared owner', () {
      // Guard-style: the five clamp ternaries (four `limit < 1 ?` sites
      // plus the multi-line maxRunsPerTask trim bound) collapse onto five
      // shared-owner calls. Behavioral tests cannot prove the routing --
      // the owner is exactly equivalent -- so the shape is pinned here.
      final root = findRepositoryRoot();
      var ternaries = 0;
      var calls = 0;
      for (final file in [
        'agent_audit_repository.dart',
        'app_deployment_history_repository.dart',
        'backup_repository.dart',
        'scheduler_task_repository.dart',
      ]) {
        final source = File(
          '${root.path}/ui/lib/data/local/$file',
        ).readAsStringSync();
        ternaries += 'limit < 1 ?'.allMatches(source).length;
        calls += 'boundedInt('.allMatches(source).length;
      }
      expect(ternaries, 0);
      expect(calls, 5);
    });
  });
}
