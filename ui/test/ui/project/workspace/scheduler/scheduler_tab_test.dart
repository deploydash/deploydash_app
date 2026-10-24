import 'dart:async';

import 'package:ui/data/local/app_database.dart';
import 'package:ui/data/local/scheduler_task_repository.dart';
import 'package:ui/providers/server_provider.dart';
import 'package:ui/providers/server_list_provider.dart';
import 'package:ui/providers/project_provider.dart';
import 'package:ui/services/app_analytics_service.dart';
import 'package:ui/ui/project/project_workspace.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../../_support/fake_analytics_service.dart';
import '../../../../_support/legacy_ssh_service.dart';

const _testServer = Server(
  id: 'server-runtime',
  name: 'srv.runtime.local',
  host: '192.168.1.30',
  port: 22,
  sshUser: 'ubuntu',
  authMethod: ServerAuthMethod.password,
);

const _testProject = Project(
  id: 'project-runtime',
  name: 'Regs v3',
  type: 'Web app',
  gitUrl: 'https://github.com/example/buildingregs',
  primaryDomain: 'dev.buildingregs.app',
  repositoryFullName: 'deploydash/laravel-example-app',
  appSubdirectory: 'website',
  deployBranch: 'main',
  appPort: 3000,
);

final _testProjectWithRuntime = Project(
  id: 'project-runtime',
  name: 'Regs v3',
  type: 'Web app',
  gitUrl: 'https://github.com/example/buildingregs',
  primaryDomain: 'dev.buildingregs.app',
  repositoryFullName: 'deploydash/laravel-example-app',
  appSubdirectory: 'website',
  deployBranch: 'main',
  appPort: 3000,
  lastDeployedAt: DateTime(2026, 1, 1),
);

Future<Map<String, dynamic>?> _testServerConnectionPayload(
  Server server,
) async {
  return <String, dynamic>{
    'host': server.host,
    'port': server.port,
    'username': server.sshUser,
    'password': 'password',
  };
}

const _schedulerErrorResponse = <String, dynamic>{
  'status': 'error',
  'msg': 'Engine refused the task.',
};

class _SchedulerWorkflowSshService extends LegacySshService {
  _SchedulerWorkflowSshService({
    this.taskUpsertResponse,
    this.taskRunNowResponse,
    this.taskDeleteResponse,
    this.taskSetEnabledResponse,
    this.throwAll = false,
  });

  Completer<void>? taskStatusCompleter;
  final Map<String, dynamic>? taskUpsertResponse;
  final Map<String, dynamic>? taskRunNowResponse;
  final Map<String, dynamic>? taskDeleteResponse;
  final Map<String, dynamic>? taskSetEnabledResponse;
  final bool throwAll;

  @override
  Future<Map<String, dynamic>> runWorkflowLegacy({
    required String workflowId,
    required String operationId,
    Map<String, dynamic>? connection,
    Map<String, dynamic>? params,
    void Function(Map<String, dynamic> event)? onEvent,
    void Function(int taskId)? onTaskStarted,
    bool serializePerHost = true,
  }) async {
    if (throwAll) {
      throw StateError('ssh unavailable');
    }
    if (workflowId == 'scheduler' && operationId == 'task_status') {
      if (taskStatusCompleter != null) {
        await taskStatusCompleter!.future;
      }
      return const <String, dynamic>{
        'status': 'success',
        'task_statuses': <dynamic>[],
      };
    }
    if (workflowId == 'scheduler' && operationId == 'task_upsert') {
      return taskUpsertResponse ??
          const <String, dynamic>{'status': 'success', 'msg': 'Task saved.'};
    }
    if (workflowId == 'scheduler' && operationId == 'task_run_now') {
      return taskRunNowResponse ??
          const <String, dynamic>{'status': 'success', 'msg': 'Task started.'};
    }
    if (workflowId == 'scheduler' && operationId == 'task_delete') {
      return taskDeleteResponse ??
          const <String, dynamic>{'status': 'success', 'msg': 'Task deleted.'};
    }
    if (workflowId == 'scheduler' && operationId == 'task_set_enabled') {
      return taskSetEnabledResponse ??
          const <String, dynamic>{'status': 'success', 'msg': 'Task updated.'};
    }
    return const <String, dynamic>{'status': 'success'};
  }
}

Future<void> _seedSchedulerTask(AppDatabase database) {
  return SchedulerTaskRepository(database).upsertTask(
    SchedulerTaskRecord(
      id: 'nightly',
      projectId: _testProject.id,
      name: 'Nightly',
      targetType: 'web_app',
      command: 'echo hi',
      scheduleType: 'every_minutes',
      intervalValue: 60,
    ),
  );
}

Future<void> _pumpSchedulerTab(
  WidgetTester tester, {
  required _SchedulerWorkflowSshService sshService,
  required FakeAnalyticsService analytics,
  Future<void> Function(AppDatabase database)? seed,
}) async {
  final database = AppDatabase.forTesting(NativeDatabase.memory());
  addTearDown(database.close);
  if (seed != null) {
    await seed(database);
  }

  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(1920, 1080);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        appDatabaseProvider.overrideWithValue(database),
        serverConnectionPayloadResolverProvider.overrideWithValue(
          _testServerConnectionPayload,
        ),
        selectedProjectProvider.overrideWithValue(_testProjectWithRuntime),
        selectedServerProvider.overrideWithValue(_testServer),
        sshServiceProvider.overrideWithValue(sshService),
        appAnalyticsServiceProvider.overrideWithValue(analytics),
      ],
      child: const MaterialApp(
        home: Scaffold(body: ProjectWorkspace(initialTabIndex: 6)),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'Scheduler shows shared empty state for custom jobs when runs exist',
    (WidgetTester tester) async {
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);

      // Seed run history for the project, but no custom tasks.
      final schedulerRepo = SchedulerTaskRepository(database);
      await schedulerRepo.appendRun(
        SchedulerTaskRunRecord(
          id: 1,
          taskId: 'historical-job',
          projectId: _testProject.id,
          status: 'completed',
          message: 'Previous run finished',
          triggeredManually: false,
          triggeredAt: DateTime.now().subtract(const Duration(hours: 1)),
        ),
      );

      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(1920, 1080);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appDatabaseProvider.overrideWithValue(database),
            serverConnectionPayloadResolverProvider.overrideWithValue(
              _testServerConnectionPayload,
            ),
            selectedProjectProvider.overrideWithValue(_testProject),
            selectedServerProvider.overrideWithValue(_testServer),
          ],
          child: const MaterialApp(
            home: Scaffold(body: ProjectWorkspace(initialTabIndex: 6)),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('scheduler-custom-empty-state')),
        findsOneWidget,
      );
      expect(
        find.text('Add a command and choose when Deploy Dash should run it.'),
        findsOneWidget,
        reason:
            'the empty state guides the next action rather than '
            'repeating its own title',
      );
      // G-40: the toolbar already carries the one primary action for this
      // section. A second filled button inside the empty state would be two
      // competing primary actions on the same screen.
      expect(
        find.text('Add scheduled job'),
        findsOneWidget,
        reason: 'exactly one add action is visible',
      );
      expect(
        find.byKey(const Key('scheduler-add-task-button')),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'shows refreshing status indicator while refresh is in flight after creating job',
    (WidgetTester tester) async {
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);

      final sshService = _SchedulerWorkflowSshService();
      sshService.taskStatusCompleter = Completer<void>();

      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(1920, 1080);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appDatabaseProvider.overrideWithValue(database),
            serverConnectionPayloadResolverProvider.overrideWithValue(
              _testServerConnectionPayload,
            ),
            selectedProjectProvider.overrideWithValue(_testProjectWithRuntime),
            selectedServerProvider.overrideWithValue(_testServer),
            sshServiceProvider.overrideWithValue(sshService),
          ],
          child: const MaterialApp(
            home: Scaffold(body: ProjectWorkspace(initialTabIndex: 6)),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Tap add scheduled job button
      await tester.tap(find.byKey(const Key('scheduler-add-task-button')));
      await tester.pumpAndSettle();

      // Enter task name and command
      await tester.enterText(
        find.byKey(const Key('scheduler-editor-name-field')),
        'Test task',
      );
      await tester.enterText(
        find.byKey(const Key('scheduler-editor-command-field')),
        'echo hello',
      );
      await tester.pumpAndSettle();

      // Save
      await tester.tap(find.byKey(const Key('scheduler-editor-save-button')));
      await tester.pump();

      // Refresh is in flight now: verify CircularProgressIndicator is in refresh button
      expect(
        find.descendant(
          of: find.byKey(const Key('scheduler-refresh-status-button')),
          matching: find.byType(CircularProgressIndicator),
        ),
        findsOneWidget,
      );

      // Complete refresh
      sshService.taskStatusCompleter!.complete();
      await tester.pumpAndSettle();

      // Now it's done: refresh icon returns
      expect(
        find.descendant(
          of: find.byKey(const Key('scheduler-refresh-status-button')),
          matching: find.byIcon(Icons.refresh),
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets('Empty-state add reports the empty-state control', (
    WidgetTester tester,
  ) async {
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    final analytics = FakeAnalyticsService();

    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1920, 1080);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(database),
          serverConnectionPayloadResolverProvider.overrideWithValue(
            _testServerConnectionPayload,
          ),
          selectedProjectProvider.overrideWithValue(_testProjectWithRuntime),
          selectedServerProvider.overrideWithValue(_testServer),
          appAnalyticsServiceProvider.overrideWithValue(analytics),
        ],
        child: const MaterialApp(
          home: Scaffold(body: ProjectWorkspace(initialTabIndex: 6)),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Fully empty: the section branch mounts the only add button.
    expect(find.byKey(const Key('scheduler-empty-state')), findsOneWidget);
    await tester.tap(find.byKey(const Key('scheduler-add-task-button')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('scheduler-editor-name-field')),
      findsOneWidget,
      reason: 'the tap still opens the editor',
    );
    expect(analytics.controlUses, [
      (control: AppControl.emptyStateAction, tab: null),
    ]);
  });

  testWidgets('Run-now reports the run control', (WidgetTester tester) async {
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    await SchedulerTaskRepository(database).upsertTask(
      SchedulerTaskRecord(
        id: 'nightly',
        projectId: _testProject.id,
        name: 'Nightly',
        targetType: 'web_app',
        command: 'echo hi',
        scheduleType: 'every_minutes',
        intervalValue: 60,
      ),
    );
    final analytics = FakeAnalyticsService();

    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1920, 1080);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(database),
          serverConnectionPayloadResolverProvider.overrideWithValue(
            _testServerConnectionPayload,
          ),
          selectedProjectProvider.overrideWithValue(_testProjectWithRuntime),
          selectedServerProvider.overrideWithValue(_testServer),
          sshServiceProvider.overrideWithValue(_SchedulerWorkflowSshService()),
          appAnalyticsServiceProvider.overrideWithValue(analytics),
        ],
        child: const MaterialApp(
          home: Scaffold(body: ProjectWorkspace(initialTabIndex: 6)),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('scheduler-run-now-nightly')));
    await tester.pumpAndSettle();

    expect(analytics.controlUses, [
      (control: AppControl.runNowPressed, tab: null),
    ]);
  });

  testWidgets('Scheduler creates report the scheduler event', (
    WidgetTester tester,
  ) async {
    final analytics = FakeAnalyticsService();
    await _pumpSchedulerTab(
      tester,
      sshService: _SchedulerWorkflowSshService(),
      analytics: analytics,
    );

    await tester.tap(find.byKey(const Key('scheduler-add-task-button')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('scheduler-editor-name-field')),
      'Nightly',
    );
    await tester.enterText(
      find.byKey(const Key('scheduler-editor-command-field')),
      'echo hi',
    );
    // Let the dialog rebuild with the entered text: the save button stays
    // disabled until the form validates, and the tap below must land on the
    // enabled button.
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('scheduler-editor-save-button')));
    await tester.pumpAndSettle();

    expect(analytics.schedulerEvents, [
      (action: SchedulerAction.create, outcome: DataOperationOutcome.success),
    ]);
  });

  testWidgets('Scheduler create failures report the scheduler event', (
    WidgetTester tester,
  ) async {
    final analytics = FakeAnalyticsService();
    await _pumpSchedulerTab(
      tester,
      sshService: _SchedulerWorkflowSshService(
        taskUpsertResponse: _schedulerErrorResponse,
      ),
      analytics: analytics,
    );

    await tester.tap(find.byKey(const Key('scheduler-add-task-button')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('scheduler-editor-name-field')),
      'Nightly',
    );
    await tester.enterText(
      find.byKey(const Key('scheduler-editor-command-field')),
      'echo hi',
    );
    // Let the dialog rebuild with the entered text: the save button stays
    // disabled until the form validates, and the tap below must land on the
    // enabled button.
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('scheduler-editor-save-button')));
    await tester.pumpAndSettle();

    expect(analytics.schedulerEvents, [
      (action: SchedulerAction.create, outcome: DataOperationOutcome.failure),
    ]);
  });

  testWidgets('Scheduler save throws report the scheduler event', (
    WidgetTester tester,
  ) async {
    final analytics = FakeAnalyticsService();
    await _pumpSchedulerTab(
      tester,
      sshService: _SchedulerWorkflowSshService(throwAll: true),
      analytics: analytics,
    );

    await tester.tap(find.byKey(const Key('scheduler-add-task-button')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('scheduler-editor-name-field')),
      'Nightly',
    );
    await tester.enterText(
      find.byKey(const Key('scheduler-editor-command-field')),
      'echo hi',
    );
    // Let the dialog rebuild with the entered text: the save button stays
    // disabled until the form validates, and the tap below must land on the
    // enabled button.
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('scheduler-editor-save-button')));
    await tester.pumpAndSettle();

    expect(analytics.schedulerEvents, [
      (action: SchedulerAction.create, outcome: DataOperationOutcome.failure),
    ]);
  });

  testWidgets('Scheduler edits report the update action', (
    WidgetTester tester,
  ) async {
    final analytics = FakeAnalyticsService();
    await _pumpSchedulerTab(
      tester,
      sshService: _SchedulerWorkflowSshService(),
      analytics: analytics,
      seed: _seedSchedulerTask,
    );

    await tester.tap(find.byKey(const Key('scheduler-edit-nightly')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('scheduler-editor-name-field')),
      'Nightly renamed',
    );
    await tester.tap(find.byKey(const Key('scheduler-editor-save-button')));
    await tester.pumpAndSettle();

    expect(analytics.schedulerEvents, [
      (action: SchedulerAction.update, outcome: DataOperationOutcome.success),
    ]);
  });

  testWidgets('Scheduler toggles report the update action', (
    WidgetTester tester,
  ) async {
    final analytics = FakeAnalyticsService();
    await _pumpSchedulerTab(
      tester,
      sshService: _SchedulerWorkflowSshService(),
      analytics: analytics,
      seed: _seedSchedulerTask,
    );

    await tester.tap(find.byKey(const Key('scheduler-task-enabled-nightly')));
    await tester.pumpAndSettle();

    expect(analytics.schedulerEvents, [
      (action: SchedulerAction.update, outcome: DataOperationOutcome.success),
    ]);
  });

  testWidgets('Scheduler toggle failures report the scheduler event', (
    WidgetTester tester,
  ) async {
    final analytics = FakeAnalyticsService();
    await _pumpSchedulerTab(
      tester,
      sshService: _SchedulerWorkflowSshService(
        taskSetEnabledResponse: _schedulerErrorResponse,
      ),
      analytics: analytics,
      seed: _seedSchedulerTask,
    );

    await tester.tap(find.byKey(const Key('scheduler-task-enabled-nightly')));
    await tester.pumpAndSettle();

    expect(analytics.schedulerEvents, [
      (action: SchedulerAction.update, outcome: DataOperationOutcome.failure),
    ]);
  });

  testWidgets('Scheduler toggle throws report the scheduler event', (
    WidgetTester tester,
  ) async {
    final analytics = FakeAnalyticsService();
    await _pumpSchedulerTab(
      tester,
      sshService: _SchedulerWorkflowSshService(throwAll: true),
      analytics: analytics,
      seed: _seedSchedulerTask,
    );

    await tester.tap(find.byKey(const Key('scheduler-task-enabled-nightly')));
    await tester.pumpAndSettle();

    expect(analytics.schedulerEvents, [
      (action: SchedulerAction.update, outcome: DataOperationOutcome.failure),
    ]);
  });

  testWidgets('Scheduler runs report the scheduler event', (
    WidgetTester tester,
  ) async {
    final analytics = FakeAnalyticsService();
    await _pumpSchedulerTab(
      tester,
      sshService: _SchedulerWorkflowSshService(),
      analytics: analytics,
      seed: _seedSchedulerTask,
    );

    await tester.tap(find.byKey(const Key('scheduler-run-now-nightly')));
    await tester.pumpAndSettle();

    expect(analytics.schedulerEvents, [
      (action: SchedulerAction.run, outcome: DataOperationOutcome.success),
    ]);
  });

  testWidgets('Scheduler run failures report the scheduler event', (
    WidgetTester tester,
  ) async {
    final analytics = FakeAnalyticsService();
    await _pumpSchedulerTab(
      tester,
      sshService: _SchedulerWorkflowSshService(
        taskRunNowResponse: _schedulerErrorResponse,
      ),
      analytics: analytics,
      seed: _seedSchedulerTask,
    );

    await tester.tap(find.byKey(const Key('scheduler-run-now-nightly')));
    await tester.pumpAndSettle();
    // The failure surfaces in an error dialog first; the event reports once
    // the user acknowledges it.
    await tester.tap(find.byKey(const Key('scheduler-action-error-ok-button')));
    await tester.pumpAndSettle();

    expect(analytics.schedulerEvents, [
      (action: SchedulerAction.run, outcome: DataOperationOutcome.failure),
    ]);
  });

  testWidgets('Scheduler run throws report the scheduler event', (
    WidgetTester tester,
  ) async {
    final analytics = FakeAnalyticsService();
    await _pumpSchedulerTab(
      tester,
      sshService: _SchedulerWorkflowSshService(throwAll: true),
      analytics: analytics,
      seed: _seedSchedulerTask,
    );

    await tester.tap(find.byKey(const Key('scheduler-run-now-nightly')));
    await tester.pumpAndSettle();

    expect(analytics.schedulerEvents, [
      (action: SchedulerAction.run, outcome: DataOperationOutcome.failure),
    ]);
  });

  testWidgets('Scheduler deletes report the scheduler event', (
    WidgetTester tester,
  ) async {
    final analytics = FakeAnalyticsService();
    await _pumpSchedulerTab(
      tester,
      sshService: _SchedulerWorkflowSshService(),
      analytics: analytics,
      seed: _seedSchedulerTask,
    );

    await tester.tap(find.byKey(const Key('scheduler-delete-nightly')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete').last);
    await tester.pumpAndSettle();

    expect(analytics.schedulerEvents, [
      (action: SchedulerAction.delete, outcome: DataOperationOutcome.success),
    ]);
  });

  testWidgets('Scheduler delete failures report the scheduler event', (
    WidgetTester tester,
  ) async {
    final analytics = FakeAnalyticsService();
    await _pumpSchedulerTab(
      tester,
      sshService: _SchedulerWorkflowSshService(
        taskDeleteResponse: _schedulerErrorResponse,
      ),
      analytics: analytics,
      seed: _seedSchedulerTask,
    );

    await tester.tap(find.byKey(const Key('scheduler-delete-nightly')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete').last);
    await tester.pumpAndSettle();

    expect(analytics.schedulerEvents, [
      (action: SchedulerAction.delete, outcome: DataOperationOutcome.failure),
    ]);
  });

  testWidgets('Scheduler delete throws report the scheduler event', (
    WidgetTester tester,
  ) async {
    final analytics = FakeAnalyticsService();
    await _pumpSchedulerTab(
      tester,
      sshService: _SchedulerWorkflowSshService(throwAll: true),
      analytics: analytics,
      seed: _seedSchedulerTask,
    );

    await tester.tap(find.byKey(const Key('scheduler-delete-nightly')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete').last);
    await tester.pumpAndSettle();

    expect(analytics.schedulerEvents, [
      (action: SchedulerAction.delete, outcome: DataOperationOutcome.failure),
    ]);
  });
}
