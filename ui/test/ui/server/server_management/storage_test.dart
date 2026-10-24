import 'package:flutter_test/flutter_test.dart';

import '_support/server_management_harness.dart';

/// Server Management Docker storage.
///
/// One of nine files T-3.6.2 split `server_management_view_test.dart` into,
/// one per tab, mirroring `lib/ui/server/management/`.
void main() {
  ensureSqliteRuntimeAvailable();

  testWidgets(
    'Docker storage clears the previous server figures when the server changes',
    (tester) async {
      final sshService = FirstCallOnlyDockerStorageSshService();
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);

      // The tree is pumped in place with only `server` changing, so the
      // section's State is *updated* rather than remounted. Remounting would
      // run initState and start from an empty cache, which would let this
      // test pass with no didUpdateWidget at all.
      final overrides = [
        appDatabaseProvider.overrideWithValue(database),
        serverConnectionPayloadResolverProvider.overrideWithValue(
          testServerConnectionPayload,
        ),
        sshServiceProvider.overrideWithValue(sshService),
      ];

      Future<void> pumpWithServer(Server server) async {
        await tester.pumpWidget(
          ProviderScope(
            overrides: overrides,
            child: MaterialApp(
              home: Scaffold(body: ServerManagementView(server: server)),
            ),
          ),
        );
        await tester.pumpAndSettle();
      }

      Future<void> revealDockerStorage() async {
        final settingsScrollable = find
            .descendant(
              of: find.byKey(const Key('server-management-system-tab')),
              matching: find.byType(Scrollable),
            )
            .first;
        await tester.scrollUntilVisible(
          find.byKey(const Key('server-management-docker-storage-section')),
          260,
          scrollable: settingsScrollable,
        );
        await tester.pumpAndSettle();
      }

      await pumpWithServer(serverWithCredentials);
      await tester.tap(find.widgetWithText(Tab, 'Settings'));
      await tester.pumpAndSettle();
      await revealDockerStorage();

      expect(
        find.text('1.25 GB'),
        findsOneWidget,
        reason: 'precondition: the first server\u2019s image size is on screen',
      );
      expect(
        sshService.statusCalls,
        1,
        reason: 'precondition: exactly one fetch has happened so far',
      );

      // Same tree, different server: this is an update, not a remount.
      await pumpWithServer(serverWithAlternateCredentials);
      await revealDockerStorage();

      expect(
        find.text('1.25 GB'),
        findsNothing,
        reason:
            'the previous machine\u2019s Docker usage must not appear '
            'under a different server\u2019s name (G-33)',
      );
      expect(
        find.text('450 MB'),
        findsNothing,
        reason: 'every cached figure clears, not just the first one',
      );
      expect(
        sshService.statusCalls,
        2,
        reason:
            'switching servers refetches rather than leaving the pane '
            'permanently blank',
      );
    },
  );
}
