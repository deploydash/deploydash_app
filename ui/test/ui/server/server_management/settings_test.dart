import 'package:flutter_test/flutter_test.dart';

import '_support/server_management_harness.dart';

/// Server Management settings tab.
///
/// One of nine files T-3.6.2 split `server_management_view_test.dart` into,
/// one per tab, mirroring `lib/ui/server/management/`.
void main() {
  ensureSqliteRuntimeAvailable();

  testWidgets('Settings tab shows Docker storage usage', (tester) async {
    final sshService = DockerStorageSshService();

    await pumpServerManagement(
      tester,
      server: serverWithCredentials,
      overrides: [sshServiceProvider.overrideWithValue(sshService)],
    );
    await tester.tap(find.widgetWithText(Tab, 'Settings'));
    await tester.pumpAndSettle();

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

    expect(sshService.statusCalls, 1);
    expect(find.text('Docker storage'), findsOneWidget);
    expect(find.text('1.25 GB'), findsOneWidget);
    expect(find.text('450 MB'), findsOneWidget);
    expect(find.text('1.15 GB'), findsOneWidget);
  });

  testWidgets('Settings tab shows no-server state for Docker storage', (
    tester,
  ) async {
    await pumpServerManagement(tester, server: null);
    await tester.tap(find.widgetWithText(Tab, 'Settings'));
    await tester.pumpAndSettle();

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

    expect(
      find.descendant(
        of: find.byKey(const Key('server-management-docker-storage-section')),
        matching: find.text('No server selected.'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('Settings tab shows missing credentials for Docker storage', (
    tester,
  ) async {
    final sshService = DockerStorageSshService();

    await pumpServerManagement(
      tester,
      server: server,
      overrides: [sshServiceProvider.overrideWithValue(sshService)],
    );
    await tester.tap(find.widgetWithText(Tab, 'Settings'));
    await tester.pumpAndSettle();

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

    expect(
      find.text(
        'This server is missing SSH access details. Update the connection first.',
      ),
      findsOneWidget,
    );
    expect(sshService.statusCalls, 0);
  });

  testWidgets('Settings tab surfaces Docker storage refresh failures', (
    tester,
  ) async {
    final sshService = DockerStorageSshService(statusSucceeds: false);

    await pumpServerManagement(
      tester,
      server: serverWithCredentials,
      overrides: [sshServiceProvider.overrideWithValue(sshService)],
    );
    await tester.tap(find.widgetWithText(Tab, 'Settings'));
    await tester.pumpAndSettle();

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

    expect(find.text('Couldn’t load Docker storage usage.'), findsOneWidget);
    expect(sshService.statusCalls, 1);
  });

  testWidgets('Settings tab surfaces Docker storage refresh exceptions', (
    tester,
  ) async {
    final sshService = DockerStorageSshService(throwOnStatus: true);

    await pumpServerManagement(
      tester,
      server: serverWithCredentials,
      overrides: [sshServiceProvider.overrideWithValue(sshService)],
    );
    await tester.tap(find.widgetWithText(Tab, 'Settings'));
    await tester.pumpAndSettle();

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

    expect(
      find.textContaining(
        'Couldn’t load Docker storage usage: Exception: Docker storage status crashed.',
      ),
      findsOneWidget,
    );
    expect(sshService.statusCalls, 1);
  });

  testWidgets('Settings tab writes Docker storage events to the terminal', (
    tester,
  ) async {
    final sshService = DockerStorageSshService(
      statusEvents: const <Map<String, dynamic>>[
        <String, dynamic>{'message': '   '},
        <String, dynamic>{'message': 'Storage refreshed.'},
        <String, dynamic>{
          'message': 'Detailed storage event.',
          'type': 'status',
          'level': 'debug',
        },
      ],
    );
    final writtenLines =
        <({String line, bool detail, String source, String? taskType})>[];

    await pumpServerManagement(
      tester,
      server: serverWithCredentials,
      overrides: [sshServiceProvider.overrideWithValue(sshService)],
      onTerminalLine: (line, {detail = false, source = '', taskType}) {
        writtenLines.add((
          line: line,
          detail: detail,
          source: source,
          taskType: taskType,
        ));
      },
    );
    await tester.tap(find.widgetWithText(Tab, 'Settings'));
    await tester.pumpAndSettle();

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

    expect(writtenLines, hasLength(2));
    expect(writtenLines[0], (
      line: 'Storage refreshed.',
      detail: false,
      source: 'docker-storage',
      taskType: 'docker-storage',
    ));
    expect(writtenLines[1], (
      line: 'Detailed storage event.',
      detail: true,
      source: 'docker-storage:status',
      taskType: 'docker-storage',
    ));
  });

  testWidgets('Settings tab refreshes Docker storage when the server changes', (
    tester,
  ) async {
    final sshService = DockerStorageSshService();

    await pumpServerManagement(
      tester,
      server: serverWithCredentials,
      overrides: [sshServiceProvider.overrideWithValue(sshService)],
    );
    await tester.tap(find.widgetWithText(Tab, 'Settings'));
    await tester.pumpAndSettle();
    var settingsScrollable = find
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
    expect(sshService.statusCalls, 1);

    await pumpServerManagement(
      tester,
      server: serverWithAlternateCredentials,
      overrides: [sshServiceProvider.overrideWithValue(sshService)],
    );
    await tester.tap(find.widgetWithText(Tab, 'Settings'));
    await tester.pumpAndSettle();
    settingsScrollable = find
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

    expect(sshService.statusCalls, 2);
  });

  testWidgets('Settings tab removes unused Docker images', (tester) async {
    final sshService = DockerStorageSshService();

    await pumpServerManagement(
      tester,
      server: serverWithCredentials,
      overrides: [sshServiceProvider.overrideWithValue(sshService)],
    );
    await tester.tap(find.widgetWithText(Tab, 'Settings'));
    await tester.pumpAndSettle();

    final settingsScrollable = find
        .descendant(
          of: find.byKey(const Key('server-management-system-tab')),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.scrollUntilVisible(
      find.byKey(const Key('docker-storage-prune-images-button')),
      260,
      scrollable: settingsScrollable,
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const Key('docker-storage-prune-images-button')),
    );
    await tester.pumpAndSettle();

    expect(find.text('Delete unused Docker images?'), findsOneWidget);

    await tester.tap(
      find.byKey(const Key('docker-storage-confirm-unused-images-button')),
    );
    await tester.pumpAndSettle();

    expect(sshService.lastPruneTarget, 'unused_images');
    expect(sshService.pruneCalls, 1);
    expect(
      find.textContaining(
        'Finished removing unused Docker images. Freed 1.25 GB.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('Settings tab clears Docker build cache', (tester) async {
    final sshService = DockerStorageSshService();

    await pumpServerManagement(
      tester,
      server: serverWithCredentials,
      overrides: [sshServiceProvider.overrideWithValue(sshService)],
    );
    await tester.tap(find.widgetWithText(Tab, 'Settings'));
    await tester.pumpAndSettle();

    final settingsScrollable = find
        .descendant(
          of: find.byKey(const Key('server-management-system-tab')),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.scrollUntilVisible(
      find.byKey(const Key('docker-storage-prune-cache-button')),
      260,
      scrollable: settingsScrollable,
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const Key('docker-storage-prune-cache-button')),
    );
    await tester.pumpAndSettle();

    expect(find.text('Delete Docker build cache?'), findsOneWidget);

    await tester.tap(
      find.byKey(const Key('docker-storage-confirm-build-cache-button')),
    );
    await tester.pumpAndSettle();

    expect(sshService.lastPruneTarget, 'build_cache');
    expect(sshService.pruneCalls, 1);
    expect(
      find.textContaining(
        'Finished removing the Docker build cache. Freed 450 MB.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('Settings tab shows cleanup message without reclaimed bytes', (
    tester,
  ) async {
    final sshService = DockerStorageSshService(includeReclaimedBytes: false);

    await pumpServerManagement(
      tester,
      server: serverWithCredentials,
      overrides: [sshServiceProvider.overrideWithValue(sshService)],
    );
    await tester.tap(find.widgetWithText(Tab, 'Settings'));
    await tester.pumpAndSettle();

    final settingsScrollable = find
        .descendant(
          of: find.byKey(const Key('server-management-system-tab')),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.scrollUntilVisible(
      find.byKey(const Key('docker-storage-prune-cache-button')),
      260,
      scrollable: settingsScrollable,
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const Key('docker-storage-prune-cache-button')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('docker-storage-confirm-build-cache-button')),
    );
    await tester.pumpAndSettle();

    expect(
      find.text('Finished removing the Docker build cache.'),
      findsOneWidget,
    );
    expect(find.textContaining('Freed'), findsNothing);
  });

  testWidgets('Settings tab shows cleanup connection errors in a dialog', (
    tester,
  ) async {
    await pumpServerManagement(tester, server: server);
    await tester.tap(find.widgetWithText(Tab, 'Settings'));
    await tester.pumpAndSettle();

    final settingsScrollable = find
        .descendant(
          of: find.byKey(const Key('server-management-system-tab')),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.scrollUntilVisible(
      find.byKey(const Key('docker-storage-prune-images-button')),
      260,
      scrollable: settingsScrollable,
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const Key('docker-storage-prune-images-button')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('docker-storage-confirm-unused-images-button')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('Couldn’t finish Docker cleanup'), findsOneWidget);
    expect(
      find.text(
        'This server is missing SSH access details. Update the connection first.',
      ),
      findsAtLeastNWidgets(1),
    );

    await tester.tap(find.widgetWithText(FilledButton, 'OK'));
    await tester.pumpAndSettle();
  });

  testWidgets('Settings tab shows Docker cleanup failures in a dialog', (
    tester,
  ) async {
    final sshService = DockerStorageSshService(pruneSucceeds: false);

    await pumpServerManagement(
      tester,
      server: serverWithCredentials,
      overrides: [sshServiceProvider.overrideWithValue(sshService)],
    );
    await tester.tap(find.widgetWithText(Tab, 'Settings'));
    await tester.pumpAndSettle();

    final settingsScrollable = find
        .descendant(
          of: find.byKey(const Key('server-management-system-tab')),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.scrollUntilVisible(
      find.byKey(const Key('docker-storage-prune-images-button')),
      260,
      scrollable: settingsScrollable,
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const Key('docker-storage-prune-images-button')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('docker-storage-confirm-unused-images-button')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('Couldn’t finish Docker cleanup'), findsOneWidget);
    expect(
      find.text('Docker cleanup did not finish.'),
      findsAtLeastNWidgets(1),
    );

    await tester.tap(find.widgetWithText(FilledButton, 'OK'));
    await tester.pumpAndSettle();
  });

  testWidgets('Settings tab shows Docker cleanup exceptions in a dialog', (
    tester,
  ) async {
    final sshService = DockerStorageSshService(throwOnPrune: true);

    await pumpServerManagement(
      tester,
      server: serverWithCredentials,
      overrides: [sshServiceProvider.overrideWithValue(sshService)],
    );
    await tester.tap(find.widgetWithText(Tab, 'Settings'));
    await tester.pumpAndSettle();

    final settingsScrollable = find
        .descendant(
          of: find.byKey(const Key('server-management-system-tab')),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.scrollUntilVisible(
      find.byKey(const Key('docker-storage-prune-cache-button')),
      260,
      scrollable: settingsScrollable,
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const Key('docker-storage-prune-cache-button')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('docker-storage-confirm-build-cache-button')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('Couldn’t finish Docker cleanup'), findsOneWidget);
    expect(
      find.textContaining(
        'Docker cleanup did not finish: Exception: Docker prune crashed.',
      ),
      findsAtLeastNWidgets(1),
    );

    await tester.tap(find.widgetWithText(FilledButton, 'OK'));
    await tester.pumpAndSettle();
  });

  testWidgets('Settings tab can remove the saved server', (tester) async {
    var removeCalls = 0;

    await pumpServerManagement(
      tester,
      server: serverWithCredentials,
      onRemoveServer: () async {
        removeCalls += 1;
      },
    );
    await tester.tap(find.widgetWithText(Tab, 'Settings'));
    await tester.pumpAndSettle();

    final settingsScrollable = find
        .descendant(
          of: find.byKey(const Key('server-management-system-tab')),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.scrollUntilVisible(
      find.byKey(const Key('system-remove-server-button')),
      260,
      scrollable: settingsScrollable,
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('system-remove-server-button')));
    await tester.pumpAndSettle();

    expect(find.text('Remove this server?'), findsOneWidget);

    await tester.tap(
      find.byKey(const Key('system-remove-server-confirm-button')),
    );
    await tester.pumpAndSettle();

    expect(removeCalls, 1);
  });
}
