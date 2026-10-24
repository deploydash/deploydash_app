import 'package:ui/models/run_guard.dart';
import 'package:ui/models/server_scope.dart';
import 'package:flutter_test/flutter_test.dart';

/// Architecture invariant: asynchronous UI state is scoped by server and
/// operation kind, so an obsolete request cannot overwrite a current one.
///
/// Measurement: each registry's capture, invalidation, and selective-clear
/// behaviour is tested across same and different scopes and operation kinds.
void main() {
  group('ScopedRunRegistry', () {
    test('invalidates older runs for the same scope and kind', () {
      final registry = ScopedRunRegistry();

      final first = registry.capture(scopeKey: 'server-a', kind: 'status');
      final second = registry.capture(scopeKey: 'server-a', kind: 'status');

      expect(registry.isCurrent(first), isFalse);
      expect(registry.isCurrent(second), isTrue);
      expect(second.epoch, first.epoch + 1);
    });

    test('keeps different kinds independent under the same scope', () {
      final registry = ScopedRunRegistry();

      final status = registry.capture(scopeKey: 'server-a', kind: 'status');
      final action = registry.capture(scopeKey: 'server-a', kind: 'action');

      expect(registry.isCurrent(status), isTrue);
      expect(registry.isCurrent(action), isTrue);
    });

    test('keeps different scopes independent', () {
      final registry = ScopedRunRegistry();

      final first = registry.capture(scopeKey: 'server-a', kind: 'status');
      final second = registry.capture(scopeKey: 'server-b', kind: 'status');

      expect(registry.isCurrent(first), isTrue);
      expect(registry.isCurrent(second), isTrue);
    });

    test('clearScope invalidates runs for only that scope', () {
      final registry = ScopedRunRegistry();

      final first = registry.capture(scopeKey: 'server-a', kind: 'status');
      final second = registry.capture(scopeKey: 'server-b', kind: 'status');

      registry.clearScope('server-a');

      expect(registry.isCurrent(first), isFalse);
      expect(registry.isCurrent(second), isTrue);
    });

    test('advance bumps the epoch without starting a run', () {
      final registry = ScopedRunRegistry();

      final run = registry.capture(scopeKey: 'server-a', kind: 'status');
      final advanced = registry.advance(
        scopeKey: ' server-a ',
        kind: ' status ',
      );

      expect(advanced, run.epoch + 1);
      expect(registry.isCurrent(run), isFalse);
      final next = registry.capture(scopeKey: 'server-a', kind: 'status');
      expect(next.epoch, advanced + 1);
    });
  });

  group('ScopedBusyRegistry', () {
    test('tracks busy ids by scope and kind', () {
      final registry = ScopedBusyRegistry();

      final key = registry.markBusy(
        scopeKey: 'server-a',
        kind: 'status',
        id: 'postgres',
      );

      expect(
        registry.isBusy(scopeKey: 'server-a', kind: 'status', id: 'postgres'),
        isTrue,
      );
      expect(
        registry.isBusy(scopeKey: 'server-a', kind: 'action', id: 'postgres'),
        isFalse,
      );

      registry.remove(key);
      expect(
        registry.isBusy(scopeKey: 'server-a', kind: 'status', id: 'postgres'),
        isFalse,
      );
    });

    test('clearKind and clearScope remove only matching entries', () {
      final registry = ScopedBusyRegistry();
      registry.markBusy(scopeKey: 'server-a', kind: 'status', id: 'web');
      registry.markBusy(scopeKey: 'server-a', kind: 'action', id: 'web');
      registry.markBusy(scopeKey: 'server-b', kind: 'status', id: 'web');

      registry.clearKind(scopeKey: 'server-a', kind: 'status');

      expect(
        registry.isBusy(scopeKey: 'server-a', kind: 'status', id: 'web'),
        isFalse,
      );
      expect(
        registry.isBusy(scopeKey: 'server-a', kind: 'action', id: 'web'),
        isTrue,
      );

      registry.clearScope('server-a');
      expect(
        registry.isBusy(scopeKey: 'server-a', kind: 'action', id: 'web'),
        isFalse,
      );
      expect(
        registry.isBusy(scopeKey: 'server-b', kind: 'status', id: 'web'),
        isTrue,
      );
    });
  });

  group('ServerScope', () {
    test('normalizes ids and matches selected server ids', () {
      final scope = ServerScope.fromId(' server-a ');

      expect(scope?.key, 'server-a');
      expect(scope?.matches('server-a'), isTrue);
      expect(scope?.matches('server-b'), isFalse);
      expect(ServerScope.fromId(' '), isNull);
      expect(ServerScope.fromId(null), isNull);
    });
  });
}
