import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:ui/data/local/app_data_directory.dart';
import 'package:ui/providers/github_integration_provider.dart';
import 'package:ui/providers/server_provider.dart';
import 'package:ui/services/app_analytics_service.dart';
import 'package:ui/ui/startup/database_unlock_gate.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:yaru_window_platform_interface/yaru_window_platform_interface.dart';

import 'package:ui/main.dart' as app;
// The terminal formatters moved to the shell with T-3.2.5.
import 'package:ui/ui/shell/shell_page.dart' as shell;

import '_support/fake_analytics_service.dart';

class _FakeYaruWindowPlatform extends YaruWindowPlatform
    with MockPlatformInterfaceMixin {
  @override
  Future<void> init(int id) async {}

  @override
  Future<void> hideTitle(int id) async {}

  @override
  Future<void> close(int id) async {}

  @override
  Future<void> drag(int id) async {}

  @override
  Future<void> fullscreen(int id) async {}

  @override
  Future<void> hide(int id) async {}

  @override
  Future<void> maximize(int id) async {}

  @override
  Future<void> minimize(int id) async {}

  @override
  Future<void> restore(int id) async {}

  @override
  Future<void> show(int id) async {}

  @override
  Future<void> showMenu(int id) async {}

  @override
  Future<void> showTitle(int id) async {}

  @override
  Future<void> setBackground(int id, Color color) async {}

  @override
  Future<void> setBrightness(int id, Brightness brightness) async {}

  @override
  Future<void> setTitle(int id, String title) async {}

  @override
  Future<void> setMinimizable(int id, bool minimizable) async {}

  @override
  Future<void> setMaximizable(int id, bool maximizable) async {}

  @override
  Future<void> setClosable(int id, bool closable) async {}

  @override
  Future<YaruWindowState> state(int id) async => const YaruWindowState();

  @override
  Stream<YaruWindowState> states(int id) => const Stream.empty();

  @override
  Future<void> onClose(int id, FutureOr<bool> Function() handler) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const windowManagerChannel = MethodChannel('window_manager');

  test(
    'buildDeployDashRootApp wires the unlock gate into a provider scope',
    () {
      final root = app.buildDeployDashRootApp();

      expect(root, isA<DatabaseUnlockGate>());
      final gate = root as DatabaseUnlockGate;
      final child = gate.childBuilder('topsecret');

      expect(child, isA<ProviderScope>());
    },
  );

  test(
    'formatConnectedServerTerminalMessage includes normalized host and port',
    () {
      const server = Server(
        id: 'server-1',
        name: 'Prod-01',
        host: '2001:db8::10',
        port: 2222,
        sshUser: 'ubuntu',
        authMethod: ServerAuthMethod.password,
      );

      expect(
        shell.formatConnectedServerTerminalMessage(server),
        '[server] Added "Prod-01" ([2001:db8::10]:2222)',
      );
    },
  );

  test(
    'formatGitHubDeploySummaryTerminalMessage summarizes timeline results',
    () {
      const successState = GitHubIntegrationState(
        deployStatus: GitHubDeployStatus.success,
        deployTimeline: [
          '[server] warning: runtime warning',
          '[server] error: ignored after successful deploy',
        ],
      );
      expect(
        shell.formatGitHubDeploySummaryTerminalMessage(successState),
        contains('Deploy summary: succeeded'),
      );
      expect(
        shell.formatGitHubDeploySummaryTerminalMessage(successState),
        contains('warnings 1'),
      );
      expect(
        shell.formatGitHubDeploySummaryTerminalMessage(successState),
        contains('errors 0'),
      );

      const failureState = GitHubIntegrationState(
        deployStatus: GitHubDeployStatus.error,
        deployTimeline: [
          '[server] warning: runtime warning',
          '[server] error: deploy failed',
        ],
      );
      expect(
        shell.formatGitHubDeploySummaryTerminalMessage(failureState),
        contains('Deploy summary: failed'),
      );
      expect(
        shell.formatGitHubDeploySummaryTerminalMessage(failureState),
        contains('warnings 1'),
      );
      expect(
        shell.formatGitHubDeploySummaryTerminalMessage(failureState),
        contains('errors 1'),
      );
    },
  );

  test(
    'formatServerVerificationSummaryTerminalMessage reports passed checks',
    () {
      final state = ServerState(
        result: const <String, dynamic>{
          'os': 'Ubuntu 24.04',
          'cpu': 'x86_64',
          'memory_mb': 8192,
          'compatibility': <String, dynamic>{
            'status': 'pass',
            'failed_checks': <Map<String, dynamic>>[],
          },
        },
        events: const <Map<String, dynamic>>[
          <String, dynamic>{'level': 'warning'},
        ],
      );

      expect(
        shell.formatServerVerificationSummaryTerminalMessage(
          state,
          succeeded: true,
        ),
        'Verification summary: passed • warnings 1 • errors 0 • '
        'Ubuntu 24.04 • x86_64 • 8192MB RAM',
      );
    },
  );

  test(
    'formatServerVerificationSummaryTerminalMessage reports blocked checks',
    () {
      final state = ServerState(
        result: const <String, dynamic>{
          'os': 'Ubuntu 24.04',
          'cpu': 'x86_64',
          'memory_mb': 8192,
          'compatibility': <String, dynamic>{
            'status': 'fail',
            'failed_checks': <Map<String, dynamic>>[
              <String, dynamic>{'id': 'ubuntu_repository_reachable'},
              <String, dynamic>{'id': 'docker_repository_reachable'},
            ],
          },
        },
      );

      expect(
        shell.formatServerVerificationSummaryTerminalMessage(
          state,
          succeeded: true,
        ),
        'Verification summary: blocked • failed checks 2 • warnings 0 • '
        'errors 0 • Ubuntu 24.04 • x86_64 • 8192MB RAM',
      );
    },
  );

  test(
    'formatServerVerificationSummaryTerminalMessage reports failed attempts',
    () {
      final state = ServerState(
        events: const <Map<String, dynamic>>[
          <String, dynamic>{'level': 'error'},
        ],
      );

      expect(
        shell.formatServerVerificationSummaryTerminalMessage(
          state,
          succeeded: false,
        ),
        'Verification summary: failed • warnings 0 • errors 1',
      );
    },
  );

  test(
    'formatServerVerificationSummaryTerminalMessage blocks missing reports',
    () {
      final state = ServerState(
        result: const <String, dynamic>{
          'os': 'Ubuntu 24.04',
          'cpu': 'x86_64',
          'memory_mb': 8192,
        },
      );

      expect(
        shell.formatServerVerificationSummaryTerminalMessage(
          state,
          succeeded: true,
        ),
        startsWith('Verification summary: blocked • warnings 0 • errors 0'),
      );
    },
  );

  testWidgets('main initializes and reports app_started once pre-unlock', (
    WidgetTester tester,
  ) async {
    final originalPlatform = YaruWindowPlatform.instance;
    final analyticsService = FakeAnalyticsService();
    // The startup crash store resolves the app-support directory, whose real
    // path-provider call never completes under testWidgets without a pump, so
    // the launch hangs without this override (same seam the app-data
    // directory tests use).
    final appDataDir = Directory.systemTemp.createTempSync(
      'deploydash-main-test-',
    );
    debugOverrideAppDataDirectoryResolver(() async => appDataDir);
    // A leftover marker from a crashed launch reports once, then clears.
    final crashStore = FileCrashMarkerStore(appDataDir);
    crashStore.write(
      buildCrashMarkerPayload(
        errorType: 'StateError',
        timestamp: DateTime.utc(2026, 9, 9),
      ),
    );

    YaruWindowPlatform.instance = _FakeYaruWindowPlatform();
    debugOverrideAppAnalyticsService(analyticsService);
    app.debugOverrideDeployDashDataDirPublisher(() async {});
    app.debugOverrideAnalyticsEnabled(true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(windowManagerChannel, (call) async {
          switch (call.method) {
            case 'ensureInitialized':
            case 'waitUntilReadyToShow':
            case 'setTitleBarStyle':
            case 'setSize':
            case 'setAlignment':
            case 'setMinimumSize':
            case 'setBackgroundColor':
            case 'setSkipTaskbar':
            case 'show':
            case 'focus':
            case 'setBounds':
              return null;
            case 'isFullScreen':
            case 'isMaximized':
            case 'isMinimized':
              return false;
            case 'getBounds':
              return <String, double>{
                'x': 0,
                'y': 0,
                'width': 1200,
                'height': 800,
              };
          }
          return null;
        });
    addTearDown(() async {
      YaruWindowPlatform.instance = originalPlatform;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(windowManagerChannel, null);
      debugOverrideAppAnalyticsService(null);
      app.debugOverrideDeployDashDataDirPublisher(null);
      app.debugOverrideAnalyticsEnabled(null);
      debugResetAppDataDirectoryTestState();
      if (await appDataDir.exists()) {
        await appDataDir.delete(recursive: true);
      }
    });

    await app.main();
    await tester.pump();

    // Usage reporting is default-on behind a notice, and the stored switch
    // lives in the encrypted database, unreadable before unlock: main()
    // initializes, reports the seeded crash, and tracks the single
    // content-free `app_started` pre-notice event. ShellPage's post-unlock
    // sync then applies the stored switch and reports nothing twice.
    expect(analyticsService.initializeCallCount, 1);
    expect(analyticsService.appStartedCallCount, 1);
    expect(analyticsService.previousSessionCrashes, ['StateError']);
    // Sync check: awaiting real file I/O never completes under testWidgets.
    expect(crashStore.markerFile.existsSync(), isFalse);
    expect(find.byType(DatabaseUnlockGate), findsOneWidget);
  });

  testWidgets('main keeps analytics dark outside release builds', (
    WidgetTester tester,
  ) async {
    final originalPlatform = YaruWindowPlatform.instance;
    final analyticsService = FakeAnalyticsService();
    final flutterOnErrorBefore = FlutterError.onError;
    final platformOnErrorBefore = PlatformDispatcher.instance.onError;
    // Same store setup as the enabled path, so a broken gate fails fast on
    // assertions instead of hanging on the real app-support channel: the
    // seeded marker must survive the launch untouched.
    final appDataDir = Directory.systemTemp.createTempSync(
      'deploydash-main-dark-test-',
    );
    debugOverrideAppDataDirectoryResolver(() async => appDataDir);
    final crashStore = FileCrashMarkerStore(appDataDir);
    crashStore.write(
      buildCrashMarkerPayload(
        errorType: 'StateError',
        timestamp: DateTime.utc(2026, 9, 9),
      ),
    );

    YaruWindowPlatform.instance = _FakeYaruWindowPlatform();
    debugOverrideAppAnalyticsService(analyticsService);
    app.debugOverrideDeployDashDataDirPublisher(() async {});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(windowManagerChannel, (call) async {
          switch (call.method) {
            case 'ensureInitialized':
            case 'waitUntilReadyToShow':
            case 'setTitleBarStyle':
            case 'setSize':
            case 'setAlignment':
            case 'setMinimumSize':
            case 'setBackgroundColor':
            case 'setSkipTaskbar':
            case 'show':
            case 'focus':
            case 'setBounds':
              return null;
            case 'isFullScreen':
            case 'isMaximized':
            case 'isMinimized':
              return false;
            case 'getBounds':
              return <String, double>{
                'x': 0,
                'y': 0,
                'width': 1200,
                'height': 800,
              };
          }
          return null;
        });
    addTearDown(() async {
      YaruWindowPlatform.instance = originalPlatform;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(windowManagerChannel, null);
      debugOverrideAppAnalyticsService(null);
      app.debugOverrideDeployDashDataDirPublisher(null);
      debugResetAppDataDirectoryTestState();
      if (await appDataDir.exists()) {
        await appDataDir.delete(recursive: true);
      }
    });

    await app.main();
    await tester.pump();

    // Debug builds never activate analytics: no init, no app_started, no
    // crash report, no handlers installed, and the seeded marker survives
    // untouched.
    expect(analyticsService.initializeCallCount, 0);
    expect(analyticsService.appStartedCallCount, 0);
    expect(analyticsService.previousSessionCrashes, isEmpty);
    expect(crashStore.markerFile.existsSync(), isTrue);
    expect(identical(FlutterError.onError, flutterOnErrorBefore), isTrue);
    expect(
      identical(PlatformDispatcher.instance.onError, platformOnErrorBefore),
      isTrue,
    );
    expect(find.byType(DatabaseUnlockGate), findsOneWidget);
  });
}
