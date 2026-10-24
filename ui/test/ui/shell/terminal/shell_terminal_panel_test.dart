import 'dart:async';

import 'package:ui/data/local/app_database.dart';
import 'package:ui/providers/github_integration_provider.dart';
import 'package:ui/providers/server_provider.dart';
import 'package:ui/providers/shell_terminal_provider.dart';
import 'package:ui/providers/terminal_view_preferences_provider.dart';
import 'package:ui/services/concurrency_engine.dart';
import 'package:ui/ui/shell/terminal/shell_terminal_panel.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../_support/sqlite_test_harness.dart';

void main() {
  final sqliteAvailable = ensureSqliteRuntimeAvailable();

  testWidgets('shell terminal panel renders provider transition output', (
    WidgetTester tester,
  ) async {
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    final serverNotifier = _MutableServerNotifier();
    final gitHubNotifier = _MutableGitHubIntegrationNotifier();
    final debugNotifier = _FakeTerminalDebugViewNotifier();
    final queueStreams = ShellTerminalQueueStreams(
      queueStream: Stream<List<OperationQueueSnapshot>>.empty(),
      metricsStream: Stream<OperationSchedulerMetricsSnapshot>.empty(),
      initialQueueSnapshot: const <OperationQueueSnapshot>[],
      initialMetrics: OperationSchedulerMetricsSnapshot.empty(),
    );

    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(database),
        serverProvider.overrideWith(() => serverNotifier),
        gitHubIntegrationProvider.overrideWith(() => gitHubNotifier),
        terminalDebugViewProvider.overrideWith(() => debugNotifier),
        shellTerminalQueueStreamsProvider.overrideWithValue(queueStreams),
      ],
    );
    addTearDown(container.dispose);
    final streamedOutput = <String>[];
    final subscription = container
        .read(shellTerminalControllerProvider)
        .outputStream
        .listen((entry) => streamedOutput.add(entry.message));
    addTearDown(subscription.cancel);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(
            body: SizedBox(
              height: 500,
              child: ShellTerminalPanel(maxHeight: 420),
            ),
          ),
        ),
      ),
    );

    serverNotifier.publish(
      ServerState(isLoading: true, taskType: ServerTaskType.verification),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(streamedOutput, contains(contains('Starting server verification')));
    expect(
      tester
          .widget<Text>(
            find.byKey(const Key('terminal-collapsed-latest-output')),
          )
          .data,
      contains('Step 1/3: Connect to server via SSH'),
    );

    gitHubNotifier.publish(
      const GitHubIntegrationState(
        deployStatus: GitHubDeployStatus.generatingServerKey,
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byKey(const Key('terminal-details-toggle')), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const Key('terminal-latest-output'))).data,
      contains('Starting web app deploy.'),
    );

    await tester.tap(find.byKey(const Key('terminal-details-toggle')));
    await tester.pump();
    expect(debugNotifier.lastEnabled, isTrue);
  }, skip: !sqliteAvailable);
}

class _MutableServerNotifier extends ServerNotifier {
  @override
  ServerState build() => ServerState();

  void publish(ServerState nextState) {
    state = nextState;
  }
}

class _MutableGitHubIntegrationNotifier extends GitHubIntegrationNotifier {
  @override
  GitHubIntegrationState build() => const GitHubIntegrationState();

  void publish(GitHubIntegrationState nextState) {
    state = nextState;
  }
}

class _FakeTerminalDebugViewNotifier extends TerminalDebugViewNotifier {
  bool? lastEnabled;

  @override
  bool build() => false;

  @override
  Future<void> setEnabled(bool enabled) async {
    lastEnabled = enabled;
    state = enabled;
  }
}
