import 'dart:async';

import 'package:ui/providers/server_provider.dart';
import 'package:ui/models/result.dart';
import 'package:ui/services/ssh_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _NoopTaskClient implements EngineTaskClient {
  @override
  String cancelTask(int taskId) => '{"status":"success","cancelled":true}';

  @override
  String getRecentTaskHistory({int limit = 50}) =>
      '{"status":"success","history":[]}';

  @override
  String getTaskResult(int taskId) => '{"status":"success","result":{}}';

  @override
  String pollTaskEvents(int taskId, {int maxEvents = 100}) =>
      '{"status":"success","events":[],"done":true}';

  @override
  String startTask(String jsonPayload) => '{"status":"success","task_id":1}';
}

class _ScriptedSshService extends SSHService {
  _ScriptedSshService({
    this.checkResponse = const <String, dynamic>{'status': 'success'},
    this.refreshHostKeyResponse = const <String, dynamic>{'status': 'success'},
    this.planResponse = const <String, dynamic>{'status': 'success'},
    this.setupResponse = const <String, dynamic>{'status': 'success'},
    this.throwOnCheck = false,
    this.throwOnRefreshHostKey = false,
    this.throwOnSetup = false,
    this.cancelActiveResult = true,
    this.cancelTaskResult = true,
    this.emitTaskStartedOnCheck = true,
  }) : super(taskClient: _NoopTaskClient());

  final Map<String, dynamic> checkResponse;
  final Map<String, dynamic> refreshHostKeyResponse;
  final Map<String, dynamic> planResponse;
  final Map<String, dynamic> setupResponse;
  final bool throwOnCheck;
  final bool throwOnRefreshHostKey;
  final bool throwOnSetup;
  final bool cancelActiveResult;
  final bool cancelTaskResult;
  final bool emitTaskStartedOnCheck;

  int? cancelledTaskId;
  bool cancelActiveCalled = false;
  int checkCalls = 0;
  int refreshHostKeyCalls = 0;
  int setupCalls = 0;
  int planCalls = 0;

  Result<Map<String, dynamic>> _responseResult(Map<String, dynamic> value) {
    if (value['status'] == 'error') {
      return Err<Map<String, dynamic>>(
        EngineFailure(
          code: value['code']?.toString() ?? 'ENGINE_TEST_FAILURE',
          msg: value['msg']?.toString() ?? 'Test engine failure.',
          stage: value['stage']?.toString(),
          details: value['details']?.toString(),
        ),
      );
    }
    return Ok<Map<String, dynamic>>(value);
  }

  @override
  Future<Result<Map<String, dynamic>>> checkServer({
    required String host,
    int port = 22,
    required String username,
    String? password,
    String? privateKey,
    void Function(Map<String, dynamic> event)? onEvent,
    void Function(int taskId)? onTaskStarted,
  }) async {
    checkCalls += 1;
    if (emitTaskStartedOnCheck) {
      onTaskStarted?.call(77);
    }
    onEvent?.call(const <String, dynamic>{
      'type': 'connection_start',
      'level': 'info',
      'message': 'Connecting',
    });
    if (throwOnCheck) {
      return Err<Map<String, dynamic>>(
        UnexpectedFailure(Exception('check failed')),
      );
    }
    return _responseResult(checkResponse);
  }

  @override
  Future<Result<Map<String, dynamic>>> describeSetupPlan({
    List<String>? parts,
    Map<String, dynamic>? settings,
    void Function(Map<String, dynamic> event)? onEvent,
  }) async {
    planCalls += 1;
    return _responseResult(planResponse);
  }

  @override
  Future<Result<Map<String, dynamic>>> refreshServerHostKey({
    required String host,
    int port = 22,
    required String username,
    void Function(Map<String, dynamic> event)? onEvent,
    void Function(int taskId)? onTaskStarted,
  }) async {
    refreshHostKeyCalls += 1;
    onTaskStarted?.call(66);
    onEvent?.call(const <String, dynamic>{
      'type': 'connection_info',
      'level': 'info',
      'message': 'Refreshing host key',
    });
    if (throwOnRefreshHostKey) {
      return Err<Map<String, dynamic>>(
        UnexpectedFailure(Exception('refresh host key failed')),
      );
    }
    return _responseResult(refreshHostKeyResponse);
  }

  @override
  Future<Result<Map<String, dynamic>>> setupServer({
    required String host,
    int port = 22,
    required String username,
    String? password,
    String? privateKey,
    Map<String, dynamic>? managedConnection,
    List<String>? parts,
    Map<String, dynamic>? settings,
    bool dryRun = false,
    void Function(Map<String, dynamic> event)? onEvent,
    void Function(int taskId)? onTaskStarted,
  }) async {
    setupCalls += 1;
    onTaskStarted?.call(88);
    onEvent?.call(const <String, dynamic>{
      'type': 'setup_start',
      'level': 'info',
      'message': 'Applying setup',
    });
    if (throwOnSetup) {
      return Err<Map<String, dynamic>>(
        UnexpectedFailure(Exception('setup failed')),
      );
    }
    return _responseResult(setupResponse);
  }

  @override
  Future<Result<bool>> cancelTask(int taskId) async {
    cancelledTaskId = taskId;
    return Ok<bool>(cancelTaskResult);
  }

  @override
  Future<Result<bool>> cancelActiveTask() async {
    cancelActiveCalled = true;
    return Ok<bool>(cancelActiveResult);
  }
}

class _BlockingSshService extends _ScriptedSshService {
  _BlockingSshService({
    required this.gate,
    required this.response,
    this.emitTaskStarted = true,
    this.cancelActiveOk = true,
    this.cancelTaskOk = true,
  }) : super(
         emitTaskStartedOnCheck: emitTaskStarted,
         cancelActiveResult: cancelActiveOk,
         cancelTaskResult: cancelTaskOk,
       );

  final Completer<void> gate;
  final Map<String, dynamic> response;
  final bool emitTaskStarted;
  final bool cancelActiveOk;
  final bool cancelTaskOk;

  @override
  Future<Result<Map<String, dynamic>>> checkServer({
    required String host,
    int port = 22,
    required String username,
    String? password,
    String? privateKey,
    void Function(Map<String, dynamic> event)? onEvent,
    void Function(int taskId)? onTaskStarted,
  }) async {
    if (emitTaskStarted) {
      onTaskStarted?.call(77);
    }
    onEvent?.call(const <String, dynamic>{
      'type': 'connection_start',
      'level': 'info',
      'message': 'Connecting',
    });
    await gate.future;
    return Ok<Map<String, dynamic>>(response);
  }
}

class _QueuedCheckSshService extends _ScriptedSshService {
  _QueuedCheckSshService(this._runs);

  final List<({Completer<void> gate, Map<String, dynamic> response})> _runs;
  int _nextRun = 0;

  @override
  Future<Result<Map<String, dynamic>>> checkServer({
    required String host,
    int port = 22,
    required String username,
    String? password,
    String? privateKey,
    void Function(Map<String, dynamic> event)? onEvent,
    void Function(int taskId)? onTaskStarted,
  }) async {
    final runIndex = _nextRun++;
    final run = _runs[runIndex];
    onTaskStarted?.call(70 + runIndex);
    onEvent?.call(<String, dynamic>{
      'type': 'connection_start',
      'level': 'info',
      'message': 'Connecting $runIndex',
    });
    await run.gate.future;
    return Ok<Map<String, dynamic>>(run.response);
  }
}

void main() {
  test(
    'checkServer success stores result, events, and extracted actions',
    () async {
      final service = _ScriptedSshService(
        checkResponse: const <String, dynamic>{
          'status': 'success',
          'msg': 'Connected',
          'steps': <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 'part1',
              'title': 'Part 1',
              'part': 'part1',
              'actions': <Map<String, dynamic>>[
                <String, dynamic>{
                  'id': 'a1',
                  'label': 'Install Docker',
                  'description': 'Install runtime',
                },
                <String, dynamic>{
                  'id': 'a1',
                  'label': 'Install Docker duplicate',
                },
              ],
            },
          ],
        },
      );

      final container = ProviderContainer(
        overrides: [sshServiceProvider.overrideWithValue(service)],
      );
      addTearDown(container.dispose);

      await container
          .read(serverProvider.notifier)
          .checkServer(
            host: '203.0.113.10',
            username: 'root',
            password: 'secret',
          );

      final state = container.read(serverProvider);
      expect(state.isLoading, isFalse);
      expect(state.error, isNull);
      expect(state.result?['status'], 'success');
      expect(state.events, isNotEmpty);
      expect(state.setupActions, hasLength(1));
      expect(state.setupActions.first['id'], 'a1');
      expect(state.taskType, ServerTaskType.verification);
    },
  );

  test('checkServer failure stores error', () async {
    final service = _ScriptedSshService(
      checkResponse: const <String, dynamic>{
        'status': 'error',
        'msg': 'Authentication failed',
      },
    );
    final container = ProviderContainer(
      overrides: [sshServiceProvider.overrideWithValue(service)],
    );
    addTearDown(container.dispose);

    await container
        .read(serverProvider.notifier)
        .checkServer(
          host: '203.0.113.11',
          username: 'root',
          password: 'bad-password',
        );

    final state = container.read(serverProvider);
    expect(state.isLoading, isFalse);
    expect(state.error, 'Authentication failed');
    expect(state.result, isNull);
  });

  test('checkServer exception stores thrown error string', () async {
    final service = _ScriptedSshService(throwOnCheck: true);
    final container = ProviderContainer(
      overrides: [sshServiceProvider.overrideWithValue(service)],
    );
    addTearDown(container.dispose);

    await container
        .read(serverProvider.notifier)
        .checkServer(
          host: '203.0.113.12',
          username: 'root',
          password: 'secret',
        );

    final state = container.read(serverProvider);
    expect(state.isLoading, isFalse);
    expect(state.error, contains('check failed'));
  });

  test('refreshServerHostKey success clears error state', () async {
    final service = _ScriptedSshService(
      refreshHostKeyResponse: const <String, dynamic>{'status': 'success'},
    );
    final container = ProviderContainer(
      overrides: [sshServiceProvider.overrideWithValue(service)],
    );
    addTearDown(container.dispose);

    final refreshed = await container
        .read(serverProvider.notifier)
        .refreshServerHostKey(host: '203.0.113.200', username: 'root');

    final state = container.read(serverProvider);
    expect(refreshed, isTrue);
    expect(service.refreshHostKeyCalls, 1);
    expect(state.isLoading, isFalse);
    expect(state.error, isNull);
  });

  test('refreshServerHostKey failure stores message', () async {
    final service = _ScriptedSshService(
      refreshHostKeyResponse: const <String, dynamic>{
        'status': 'error',
        'msg': 'Unable to refresh SSH host key.',
      },
    );
    final container = ProviderContainer(
      overrides: [sshServiceProvider.overrideWithValue(service)],
    );
    addTearDown(container.dispose);

    final refreshed = await container
        .read(serverProvider.notifier)
        .refreshServerHostKey(host: '203.0.113.201', username: 'root');

    final state = container.read(serverProvider);
    expect(refreshed, isFalse);
    expect(state.isLoading, isFalse);
    expect(state.error, 'Unable to refresh SSH host key.');
  });

  test('refreshServerHostKey exception stores thrown error', () async {
    final service = _ScriptedSshService(throwOnRefreshHostKey: true);
    final container = ProviderContainer(
      overrides: [sshServiceProvider.overrideWithValue(service)],
    );
    addTearDown(container.dispose);

    final refreshed = await container
        .read(serverProvider.notifier)
        .refreshServerHostKey(host: '203.0.113.202', username: 'root');

    final state = container.read(serverProvider);
    expect(refreshed, isFalse);
    expect(state.error, contains('refresh host key failed'));
  });

  test(
    'loadSetupPlan updates setupActions only for success responses',
    () async {
      final service = _ScriptedSshService(
        planResponse: const <String, dynamic>{
          'status': 'success',
          'steps': <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 'part2',
              'title': 'Part 2',
              'part': 'part2',
              'actions': <Map<String, dynamic>>[
                <String, dynamic>{'id': 'b1', 'label': 'Tune sysctl'},
              ],
            },
          ],
        },
      );
      final container = ProviderContainer(
        overrides: [sshServiceProvider.overrideWithValue(service)],
      );
      addTearDown(container.dispose);

      await container.read(serverProvider.notifier).loadSetupPlan();
      var state = container.read(serverProvider);
      expect(state.setupActions, hasLength(1));
      expect(state.setupActions.first['id'], 'b1');

      final failing = _ScriptedSshService(
        planResponse: const <String, dynamic>{
          'status': 'error',
          'msg': 'not available',
        },
      );
      final container2 = ProviderContainer(
        overrides: [sshServiceProvider.overrideWithValue(failing)],
      );
      addTearDown(container2.dispose);

      await container2.read(serverProvider.notifier).loadSetupPlan();
      state = container2.read(serverProvider);
      expect(state.setupActions, isEmpty);
    },
  );

  test('setupServer success stores setupResult and setup actions', () async {
    final service = _ScriptedSshService(
      setupResponse: const <String, dynamic>{
        'status': 'success',
        'steps': <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'part3',
            'title': 'Part 3',
            'part': 'part3',
            'actions': <Map<String, dynamic>>[
              <String, dynamic>{
                'id': 'c1',
                'label': 'Install Caddy',
                'description': 'Proxy setup',
              },
            ],
          },
        ],
      },
    );
    final container = ProviderContainer(
      overrides: [sshServiceProvider.overrideWithValue(service)],
    );
    addTearDown(container.dispose);

    await container
        .read(serverProvider.notifier)
        .setupServer(
          host: '203.0.113.20',
          username: 'root',
          password: 'secret',
        );

    final state = container.read(serverProvider);
    expect(state.isLoading, isFalse);
    expect(state.error, isNull);
    expect(state.setupResult?['status'], 'success');
    expect(state.setupActions, hasLength(1));
    expect(state.setupActions.first['id'], 'c1');
    expect(state.taskType, ServerTaskType.setup);
  });

  test('setupServer failure stores error', () async {
    final service = _ScriptedSshService(
      setupResponse: const <String, dynamic>{
        'status': 'error',
        'msg': 'Could not apply setup',
      },
    );
    final container = ProviderContainer(
      overrides: [sshServiceProvider.overrideWithValue(service)],
    );
    addTearDown(container.dispose);

    await container
        .read(serverProvider.notifier)
        .setupServer(
          host: '203.0.113.21',
          username: 'root',
          password: 'secret',
        );

    final state = container.read(serverProvider);
    expect(state.isLoading, isFalse);
    expect(state.error, 'Could not apply setup');
    expect(state.setupResult, isNull);
  });

  test('setupServer exception stores thrown error', () async {
    final service = _ScriptedSshService(throwOnSetup: true);
    final container = ProviderContainer(
      overrides: [sshServiceProvider.overrideWithValue(service)],
    );
    addTearDown(container.dispose);

    await container
        .read(serverProvider.notifier)
        .setupServer(
          host: '203.0.113.22',
          username: 'root',
          password: 'secret',
        );

    final state = container.read(serverProvider);
    expect(state.isLoading, isFalse);
    expect(state.error, contains('setup failed'));
  });

  test('cancelCheck returns early when no operation is active', () async {
    final service = _ScriptedSshService();
    final container = ProviderContainer(
      overrides: [sshServiceProvider.overrideWithValue(service)],
    );
    addTearDown(container.dispose);

    await container.read(serverProvider.notifier).cancelCheck();

    final state = container.read(serverProvider);
    expect(state.isLoading, isFalse);
    expect(state.events, isEmpty);
    expect(service.cancelActiveCalled, isFalse);
  });

  test('cancelCheck cancels in-flight verification by task id', () async {
    final gate = Completer<void>();
    final service = _BlockingSshService(
      gate: gate,
      response: const <String, dynamic>{'status': 'success'},
      emitTaskStarted: true,
    );
    final container = ProviderContainer(
      overrides: [sshServiceProvider.overrideWithValue(service)],
    );
    addTearDown(container.dispose);

    unawaited(
      container
          .read(serverProvider.notifier)
          .checkServer(
            host: '203.0.113.30',
            username: 'root',
            password: 'secret',
          ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(container.read(serverProvider).isLoading, isTrue);

    await container.read(serverProvider.notifier).cancelCheck();
    gate.complete();
    await Future<void>.delayed(const Duration(milliseconds: 10));

    final state = container.read(serverProvider);
    expect(state.isLoading, isFalse);
    expect(state.error, 'Verification cancelled.');
    expect(service.cancelledTaskId, 77);
    expect(
      state.events.any(
        (event) => event['type']?.toString() == 'task_cancel_requested',
      ),
      isTrue,
    );
  });

  test(
    'cancelCheck falls back to cancelActiveTask when no task id exists',
    () async {
      final gate = Completer<void>();
      final service = _BlockingSshService(
        gate: gate,
        response: const <String, dynamic>{'status': 'success'},
        emitTaskStarted: false,
        cancelActiveOk: false,
      );
      final container = ProviderContainer(
        overrides: [sshServiceProvider.overrideWithValue(service)],
      );
      addTearDown(container.dispose);

      unawaited(
        container
            .read(serverProvider.notifier)
            .checkServer(
              host: '203.0.113.31',
              username: 'root',
              password: 'secret',
            ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(container.read(serverProvider).isLoading, isTrue);

      await container.read(serverProvider.notifier).cancelCheck();
      gate.complete();
      await Future<void>.delayed(const Duration(milliseconds: 10));

      final state = container.read(serverProvider);
      expect(service.cancelActiveCalled, isTrue);
      expect(state.error, 'Cancellation failed.');
    },
  );

  test(
    'cancelCheck reports failure when task cancellation returns false',
    () async {
      final gate = Completer<void>();
      final service = _BlockingSshService(
        gate: gate,
        response: const <String, dynamic>{'status': 'success'},
        emitTaskStarted: true,
        cancelTaskOk: false,
      );
      final container = ProviderContainer(
        overrides: [sshServiceProvider.overrideWithValue(service)],
      );
      addTearDown(container.dispose);

      unawaited(
        container
            .read(serverProvider.notifier)
            .checkServer(
              host: '203.0.113.32',
              username: 'root',
              password: 'secret',
            ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(container.read(serverProvider).isLoading, isTrue);

      await container.read(serverProvider.notifier).cancelCheck();
      gate.complete();
      await Future<void>.delayed(const Duration(milliseconds: 10));

      final state = container.read(serverProvider);
      expect(state.error, 'Cancellation failed.');
      expect(service.cancelledTaskId, 77);
    },
  );

  test('reset ignores delayed verification completion', () async {
    final gate = Completer<void>();
    final service = _BlockingSshService(
      gate: gate,
      response: const <String, dynamic>{'status': 'success'},
    );
    final container = ProviderContainer(
      overrides: [sshServiceProvider.overrideWithValue(service)],
    );
    addTearDown(container.dispose);

    unawaited(
      container
          .read(serverProvider.notifier)
          .checkServer(
            host: '203.0.113.33',
            username: 'root',
            password: 'secret',
          ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 10));
    container.read(serverProvider.notifier).reset();

    gate.complete();
    await Future<void>.delayed(const Duration(milliseconds: 10));

    final state = container.read(serverProvider);
    expect(state.isLoading, isFalse);
    expect(state.result, isNull);
    expect(state.events, isEmpty);
  });

  test('newer verification request ignores delayed older completion', () async {
    final firstGate = Completer<void>();
    final secondGate = Completer<void>();
    final service = _QueuedCheckSshService(
      <({Completer<void> gate, Map<String, dynamic> response})>[
        (
          gate: firstGate,
          response: const <String, dynamic>{'status': 'success', 'msg': 'old'},
        ),
        (
          gate: secondGate,
          response: const <String, dynamic>{'status': 'success', 'msg': 'new'},
        ),
      ],
    );
    final container = ProviderContainer(
      overrides: [sshServiceProvider.overrideWithValue(service)],
    );
    addTearDown(container.dispose);

    unawaited(
      container
          .read(serverProvider.notifier)
          .checkServer(
            host: '203.0.113.34',
            username: 'root',
            password: 'secret',
          ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 10));

    unawaited(
      container
          .read(serverProvider.notifier)
          .checkServer(
            host: '203.0.113.35',
            username: 'root',
            password: 'secret',
          ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 10));

    secondGate.complete();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(container.read(serverProvider).result?['msg'], 'new');

    firstGate.complete();
    await Future<void>.delayed(const Duration(milliseconds: 10));

    final state = container.read(serverProvider);
    expect(state.result?['msg'], 'new');
    expect(state.events.last['message'], 'Connecting 1');
  });

  test('reset returns provider state to defaults', () async {
    final service = _ScriptedSshService(
      checkResponse: const <String, dynamic>{'status': 'error', 'msg': 'boom'},
    );
    final container = ProviderContainer(
      overrides: [sshServiceProvider.overrideWithValue(service)],
    );
    addTearDown(container.dispose);

    await container
        .read(serverProvider.notifier)
        .checkServer(host: '203.0.113.40', username: 'root', password: 'x');
    expect(container.read(serverProvider).error, isNotNull);

    container.read(serverProvider.notifier).reset();
    final state = container.read(serverProvider);
    expect(state.isLoading, isFalse);
    expect(state.result, isNull);
    expect(state.setupResult, isNull);
    expect(state.error, isNull);
    expect(state.events, isEmpty);
    expect(state.setupActions, isEmpty);
    expect(state.taskType, ServerTaskType.idle);
  });
}
