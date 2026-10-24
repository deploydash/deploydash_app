import 'dart:async';

import 'package:ui/services/desktop_update_service.dart';
import 'package:ui/ui/settings/desktop_updates_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeUpdateController extends DesktopUpdateController {
  _FakeUpdateController({
    required this.initial,
    this.next,
    this.launchResult = true,
    this.notesResult = true,
    this.buildError,
    this.buildCompleter,
  });

  final DesktopUpdateSnapshot initial;
  final DesktopUpdateSnapshot? next;
  final bool launchResult;
  final bool notesResult;
  final Object? buildError;
  final Completer<DesktopUpdateSnapshot>? buildCompleter;
  int checkCount = 0;
  int updateCount = 0;
  int notesCount = 0;
  int dismissCount = 0;

  @override
  Future<DesktopUpdateSnapshot> build() async {
    if (buildError != null) {
      throw buildError!;
    }
    final completer = buildCompleter;
    if (completer != null) {
      return completer.future;
    }
    return initial;
  }

  @override
  Future<void> check() async {
    checkCount += 1;
    state = AsyncData(next ?? initial);
  }

  @override
  Future<bool> startUpdate() async {
    updateCount += 1;
    return launchResult;
  }

  @override
  Future<bool> openReleaseNotes() async {
    notesCount += 1;
    return notesResult;
  }

  @override
  Future<void> dismiss() async {
    dismissCount += 1;
  }
}

Widget _wrap(_FakeUpdateController controller) {
  return ProviderScope(
    key: UniqueKey(),
    overrides: [desktopUpdateControllerProvider.overrideWith(() => controller)],
    child: const MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: DesktopUpdatesView())),
    ),
  );
}

void main() {
  testWidgets('shows loading and provider failure states with retry', (
    WidgetTester tester,
  ) async {
    final completer = Completer<DesktopUpdateSnapshot>();
    final loadingController = _FakeUpdateController(
      initial: _snapshot(DesktopUpdateStatus.notChecked),
      buildCompleter: completer,
    );
    await tester.pumpWidget(_wrap(loadingController));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    completer.complete(_snapshot(DesktopUpdateStatus.notChecked));
    await tester.pumpAndSettle();

    final errorController = _FakeUpdateController(
      initial: _snapshot(DesktopUpdateStatus.notChecked),
      buildError: StateError('failed'),
    );
    await tester.pumpWidget(_wrap(errorController));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('app-settings-update-load-error')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('app-settings-update-retry-button')));
    await tester.pump();
    expect(errorController.checkCount, 1);
  });

  for (final status in DesktopUpdateStatus.values) {
    testWidgets('renders ${status.name} status presentation', (
      WidgetTester tester,
    ) async {
      final controller = _FakeUpdateController(initial: _snapshot(status));
      await tester.pumpWidget(_wrap(controller));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('app-settings-update-status')),
        findsOneWidget,
      );
      expect(find.text('Installed version: 1.0.0+1'), findsOneWidget);
      if (status == DesktopUpdateStatus.updateAvailable ||
          status == DesktopUpdateStatus.updateRequired) {
        expect(
          find.byKey(const Key('app-settings-update-now-button')),
          findsOneWidget,
        );
      } else {
        expect(
          find.byKey(const Key('app-settings-check-updates-button')),
          findsOneWidget,
        );
      }
    });
  }

  for (final severity in <DesktopUpdateSeverity>[
    DesktopUpdateSeverity.security,
    DesktopUpdateSeverity.critical,
  ]) {
    testWidgets('shows a non-blocking ${severity.name} warning', (
      WidgetTester tester,
    ) async {
      final controller = _FakeUpdateController(
        initial: _snapshot(
          DesktopUpdateStatus.updateAvailable,
          release: _release(severity: severity),
        ),
      );
      await tester.pumpWidget(_wrap(controller));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('app-settings-update-security-warning')),
        findsOneWidget,
      );
      expect(find.textContaining('keep using Deploy Dash'), findsOneWidget);
    });
  }

  for (final strategy in DesktopUpdateInstallStrategy.values) {
    testWidgets('explains ${strategy.name} installation', (
      WidgetTester tester,
    ) async {
      final controller = _FakeUpdateController(
        initial: _snapshot(
          DesktopUpdateStatus.updateAvailable,
          release: _release(strategy: strategy),
        ),
      );
      await tester.pumpWidget(_wrap(controller));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('app-settings-update-install-guidance')),
        findsOneWidget,
      );
    });
  }

  testWidgets('checks, opens update and notes, and dismisses normal releases', (
    WidgetTester tester,
  ) async {
    final available = _snapshot(DesktopUpdateStatus.updateAvailable);
    final controller = _FakeUpdateController(
      initial: _snapshot(DesktopUpdateStatus.current),
      next: available,
    );
    await tester.pumpWidget(_wrap(controller));
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const Key('app-settings-check-updates-button')),
    );
    await tester.pump();
    expect(controller.checkCount, 1);
    expect(find.text('Available version: 1.1.0+2'), findsOneWidget);

    await tester.tap(find.byKey(const Key('app-settings-update-now-button')));
    await tester.tap(
      find.byKey(const Key('app-settings-release-notes-button')),
    );
    await tester.tap(
      find.byKey(const Key('app-settings-dismiss-update-button')),
    );
    await tester.pump();
    expect(controller.updateCount, 1);
    expect(controller.notesCount, 1);
    expect(controller.dismissCount, 1);
  });

  testWidgets('shows acknowledged errors when system launchers fail', (
    WidgetTester tester,
  ) async {
    final controller = _FakeUpdateController(
      initial: _snapshot(DesktopUpdateStatus.updateAvailable),
      launchResult: false,
      notesResult: false,
    );
    await tester.pumpWidget(_wrap(controller));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('app-settings-update-now-button')));
    await tester.pumpAndSettle();
    expect(find.text('Could not open update'), findsOneWidget);
    await tester.tap(
      find.byKey(const Key('app-settings-update-error-ok-button')),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const Key('app-settings-release-notes-button')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Could not open update'), findsOneWidget);
  });

  testWidgets('hides reminder action after release is dismissed', (
    WidgetTester tester,
  ) async {
    final release = _release();
    final controller = _FakeUpdateController(
      initial: DesktopUpdateSnapshot(
        status: DesktopUpdateStatus.updateAvailable,
        currentBuild: const DesktopBuildInfo(version: '1.0.0', build: '1'),
        release: release,
        dismissedReleaseId: release.releaseId,
      ),
    );
    await tester.pumpWidget(_wrap(controller));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('app-settings-dismiss-update-button')),
      findsNothing,
    );
  });
}

DesktopUpdateSnapshot _snapshot(
  DesktopUpdateStatus status, {
  DesktopUpdateRelease? release,
}) {
  final hasRelease =
      status == DesktopUpdateStatus.updateAvailable ||
      status == DesktopUpdateStatus.updateRequired ||
      status == DesktopUpdateStatus.deferred;
  return DesktopUpdateSnapshot(
    status: status,
    currentBuild: const DesktopBuildInfo(version: '1.0.0', build: '1'),
    release: release ?? (hasRelease ? _release() : null),
    checkedAt: DateTime.utc(2026, 8, 11),
    message: status == DesktopUpdateStatus.failed ? 'Try again later.' : null,
  );
}

DesktopUpdateRelease _release({
  DesktopUpdateSeverity severity = DesktopUpdateSeverity.recommended,
  DesktopUpdateInstallStrategy strategy =
      DesktopUpdateInstallStrategy.aptRepository,
}) {
  return DesktopUpdateRelease(
    releaseId: 'release-2',
    version: '1.1.0',
    build: '2',
    publishedAt: DateTime.utc(2026, 8, 10),
    severity: severity,
    title: 'Deploy Dash 1.1.0',
    summary: 'Security and reliability improvements.',
    releaseNotesUri: Uri.parse('https://updates.example.test/releases/2'),
    minimumSupportedVersion: '0.9.0',
    minimumSupportedBuild: '1',
    minimumDatabaseSchema: 1,
    maximumDatabaseSchema: 47,
    rolloutPercentage: 100,
    rolloutSalt: 'salt',
    installStrategy: strategy,
    installUri: Uri.parse('https://updates.example.test/install'),
  );
}
