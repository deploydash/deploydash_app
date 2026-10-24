import 'dart:async';
import 'dart:convert';

import 'package:ui/data/local/app_database.dart';
import 'package:ui/models/result.dart';
import 'package:ui/native_bridge.dart';
import 'package:ui/services/concurrency_engine.dart';
import 'package:ui/services/ssh_service.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import '_support/fake_analytics_service.dart';
import '_support/sqlite_test_harness.dart';

T _expectOk<T>(Result<T> result) {
  expect(result, isA<Ok<T>>());
  return (result as Ok<T>).value;
}

AppFailure _expectErr<T>(Result<T> result) {
  expect(result, isA<Err<T>>());
  return (result as Err<T>).failure;
}

class _FakeTaskClient implements EngineTaskClient {
  _FakeTaskClient({
    required this.startResponse,
    required this.pollResponses,
    required this.resultResponse,
    this.recentHistoryResponse = '{"status":"success","history":[]}',
  });

  final String startResponse;
  final List<String> pollResponses;
  final String resultResponse;
  final String recentHistoryResponse;

  int _pollIndex = 0;
  int? lastCancelledTaskId;

  @override
  String cancelTask(int taskId) {
    lastCancelledTaskId = taskId;
    return '{"status":"success","cancelled":true}';
  }

  @override
  String getTaskResult(int taskId) => resultResponse;

  @override
  String pollTaskEvents(int taskId, {int maxEvents = 100}) {
    if (_pollIndex >= pollResponses.length) {
      return pollResponses.last;
    }
    final value = pollResponses[_pollIndex];
    _pollIndex += 1;
    return value;
  }

  @override
  String startTask(String jsonPayload) => startResponse;

  @override
  String getRecentTaskHistory({int limit = 50}) {
    return recentHistoryResponse;
  }
}

class _SerializingTaskClient implements EngineTaskClient {
  int startCalls = 0;
  int _nextTaskId = 1;
  bool allowFirstTaskComplete = false;

  @override
  String cancelTask(int taskId) => '{"status":"success","cancelled":true}';

  @override
  String getTaskResult(int taskId) =>
      '{"status":"success","result":{"status":"success","task_id":$taskId}}';

  @override
  String pollTaskEvents(int taskId, {int maxEvents = 100}) {
    if (taskId == 1 && !allowFirstTaskComplete) {
      return '{"status":"success","done":false,"events":[]}';
    }
    return '{"status":"success","done":true,"events":[]}';
  }

  @override
  String startTask(String jsonPayload) {
    final taskId = _nextTaskId;
    _nextTaskId += 1;
    startCalls += 1;
    return '{"status":"success","task_id":$taskId}';
  }

  @override
  String getRecentTaskHistory({int limit = 50}) {
    return '{"status":"success","history":[]}';
  }
}

class _CancelableTaskClient implements EngineTaskClient {
  int _nextTaskId = 1;
  final List<int> cancelledTaskIds = <int>[];
  final Set<int> _doneTaskIds = <int>{};

  @override
  String cancelTask(int taskId) {
    cancelledTaskIds.add(taskId);
    _doneTaskIds.add(taskId);
    return '{"status":"success","cancelled":true}';
  }

  @override
  String getTaskResult(int taskId) =>
      '{"status":"success","result":{"status":"success","task_id":$taskId}}';

  @override
  String pollTaskEvents(int taskId, {int maxEvents = 100}) {
    final done = _doneTaskIds.contains(taskId);
    return '{"status":"success","done":$done,"events":[]}';
  }

  @override
  String startTask(String jsonPayload) {
    final taskId = _nextTaskId;
    _nextTaskId += 1;
    return '{"status":"success","task_id":$taskId}';
  }

  @override
  String getRecentTaskHistory({int limit = 50}) {
    return '{"status":"success","history":[]}';
  }
}

class _CapturingTaskClient implements EngineTaskClient {
  String? lastStartPayload;

  @override
  String cancelTask(int taskId) => '{"status":"success","cancelled":true}';

  @override
  String getRecentTaskHistory({int limit = 50}) =>
      '{"status":"success","history":[]}';

  @override
  String getTaskResult(int taskId) =>
      '{"status":"success","result":{"status":"success"}}';

  @override
  String pollTaskEvents(int taskId, {int maxEvents = 100}) =>
      '{"status":"success","done":true,"events":[]}';

  @override
  String startTask(String jsonPayload) {
    lastStartPayload = jsonPayload;
    return '{"status":"success","task_id":1}';
  }
}

class _CancellationResultTaskClient implements EngineTaskClient {
  _CancellationResultTaskClient(this.cancelCode);

  final String cancelCode;
  bool _cancelled = false;

  @override
  String cancelTask(int taskId) {
    _cancelled = true;
    return '{"status":"success","cancelled":true}';
  }

  @override
  String getTaskResult(int taskId) => jsonEncode(<String, dynamic>{
    'status': 'success',
    'result': <String, dynamic>{
      'status': 'error',
      'code': cancelCode,
      'msg': 'Cancelled by test client.',
    },
  });

  @override
  String pollTaskEvents(int taskId, {int maxEvents = 100}) {
    return _cancelled
        ? '{"status":"success","done":true,"events":[]}'
        : '{"status":"success","done":false,"events":[]}';
  }

  @override
  String startTask(String jsonPayload) => '{"status":"success","task_id":1}';

  @override
  String getRecentTaskHistory({int limit = 50}) {
    return '{"status":"success","history":[]}';
  }
}

class _NativeBridgeTaskApiFake implements NativeBridgeTaskApi {
  @override
  String cancelTask(int taskId) => 'cancel:$taskId';

  @override
  String getRecentTaskHistory(int limit) => 'history:$limit';

  @override
  String getTaskResult(int taskId) => 'result:$taskId';

  @override
  String pollTaskEvents(int taskId, {int maxEvents = 100}) =>
      'poll:$taskId:$maxEvents';

  @override
  String startTask(String jsonPayload) => 'start:$jsonPayload';
}

class _EmptyStreamSshService extends SSHService {
  _EmptyStreamSshService()
    : super(
        taskClient: _FakeTaskClient(
          startResponse: '{"status":"success","task_id":1}',
          pollResponses: const <String>[
            '{"status":"success","done":true,"events":[]}',
          ],
          resultResponse: '{"status":"success","result":{"status":"success"}}',
        ),
      );

  @override
  Stream<Result<EngineEvent>> runTaskStream(
    Map<String, dynamic> payload, {
    Duration pollInterval = const Duration(milliseconds: 120),
    void Function(int taskId)? onTaskStarted,
    bool serializePerHost = true,
  }) => const Stream<Result<EngineEvent>>.empty();
}

class _FailingRecoveryDatabase extends AppDatabase {
  _FailingRecoveryDatabase() : super.forTesting(NativeDatabase.memory());

  @override
  Future<List<Map<String, dynamic>>> readOperationRecoverySnapshotMaps() {
    throw StateError('recovery read failed');
  }

  @override
  Future<void> writeOperationRecoverySnapshotMaps(
    List<Map<String, dynamic>> snapshots,
  ) {
    throw StateError('recovery write failed');
  }
}

class _ControllableTaskClient implements EngineTaskClient {
  _ControllableTaskClient({required this.cancelResponse});

  String cancelResponse;
  bool done = false;

  @override
  String cancelTask(int taskId) => cancelResponse;

  @override
  String getRecentTaskHistory({int limit = 50}) =>
      '{"status":"success","history":[]}';

  @override
  String getTaskResult(int taskId) =>
      '{"status":"success","result":{"status":"success"}}';

  @override
  String pollTaskEvents(int taskId, {int maxEvents = 100}) =>
      '{"status":"success","done":$done,"events":[]}';

  @override
  String startTask(String jsonPayload) => '{"status":"success","task_id":1}';
}

void main() {
  test('checkServerStream emits task events and terminal result', () async {
    final service = SSHService(
      taskClient: _FakeTaskClient(
        startResponse: '{"status":"success","task_id":42}',
        pollResponses: [
          '''
          {"status":"success","done":false,"events":[
            {"type":"connection_start","level":"info","message":"Connecting","data":{}}
          ]}
          ''',
          '''
          {"status":"success","done":true,"events":[
            {"type":"facts_collected","level":"info","message":"Facts ready","data":{"os":"Ubuntu"}}
          ]}
          ''',
        ],
        resultResponse:
            '{"status":"success","result":{"status":"success","os":"Ubuntu 24.04","cpu":"x86_64"}}',
      ),
    );

    final events = await service
        .checkServerStream(
          host: '203.0.113.10',
          username: 'root',
          pollInterval: Duration.zero,
        )
        .toList();

    final values = events
        .whereType<Ok<EngineEvent>>()
        .map((event) => event.value)
        .toList(growable: false);
    expect(values, hasLength(4));
    expect(values[0].type, 'operation_schedule_decision');
    expect(values[1].type, 'connection_start');
    expect(values[2].type, 'facts_collected');
    expect(values[3].type, 'result');
    expect(values[3].isResult, isTrue);
    expect(values[3].result?['status'], 'success');
  });

  test(
    'checkServer returns final result and forwards non-terminal events',
    () async {
      final emitted = <Map<String, dynamic>>[];
      int? startedTaskId;
      final service = SSHService(
        taskClient: _FakeTaskClient(
          startResponse: '{"status":"success","task_id":9}',
          pollResponses: [
            '''
          {"status":"success","done":true,"events":[
            {"type":"task_started","level":"info","message":"Task started","data":{}}
          ]}
          ''',
          ],
          resultResponse:
              '{"status":"success","result":{"status":"success","os":"Ubuntu","cpu":"x86_64"}}',
        ),
      );

      final result = await service.checkServer(
        host: '198.51.100.5',
        username: 'root',
        onEvent: emitted.add,
        onTaskStarted: (taskId) => startedTaskId = taskId,
      );

      expect(_expectOk(result)['status'], 'success');
      expect(startedTaskId, 9);
      expect(emitted.length, 2);
      expect(emitted.first['type'], 'operation_schedule_decision');
      expect(emitted.last['type'], 'task_started');
    },
  );

  test(
    'runTaskStream emits an unexpected failure on malformed poll events',
    () async {
      final service = SSHService(
        taskClient: _FakeTaskClient(
          startResponse: '{"status":"success","task_id":1}',
          pollResponses: [
            '{"status":"success","done":false,"events":"bad-shape"}',
          ],
          resultResponse: '{"status":"success","result":{"status":"success"}}',
        ),
      );

      final outcomes = await service.runTaskStream({
        'action': 'run_workflow',
        'workflow_id': 'core',
        'operation_id': 'echo',
        'connection': <String, dynamic>{'ip': '203.0.113.10'},
        'data': 'hello',
      }, pollInterval: Duration.zero).toList();

      expect(outcomes.whereType<Ok<EngineEvent>>(), isNotEmpty);
      expect(_expectErr(outcomes.last), isA<UnexpectedFailure>());
    },
  );

  test('cancelActiveTask returns false when no task is active', () async {
    final fakeClient = _FakeTaskClient(
      startResponse: '{"status":"success","task_id":11}',
      pollResponses: [
        '{"status":"success","done":false,"events":[]}',
        '{"status":"success","done":true,"events":[]}',
      ],
      resultResponse: '{"status":"success","result":{"status":"success"}}',
    );
    final service = SSHService(taskClient: fakeClient);
    final cancelled = await service.cancelActiveTask();

    expect(_expectOk(cancelled), isFalse);
    expect(fakeClient.lastCancelledTaskId, isNull);
  });

  test('runTaskStream serializes operations by host', () async {
    final fakeClient = _SerializingTaskClient();
    final service = SSHService(taskClient: fakeClient);

    final firstTaskFuture = service.runTaskStream({
      'action': 'run_workflow',
      'workflow_id': 'postgres',
      'operation_id': 'service_restart',
      'connection': {'ip': '203.0.113.10'},
    }, pollInterval: const Duration(milliseconds: 2)).toList();

    await Future<void>.delayed(const Duration(milliseconds: 20));

    final secondTaskFuture = service.runTaskStream({
      'action': 'run_workflow',
      'workflow_id': 'postgres',
      'operation_id': 'service_restart',
      'connection': {'ip': '203.0.113.10'},
      'params': {'nonce': 2},
    }, pollInterval: const Duration(milliseconds: 2)).toList();

    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(fakeClient.startCalls, 1);

    fakeClient.allowFirstTaskComplete = true;
    await firstTaskFuture;
    await secondTaskFuture;

    expect(fakeClient.startCalls, 2);
  });

  test('cancelAllActiveTasks cancels all tracked tasks', () async {
    final fakeClient = _CancelableTaskClient();
    final service = SSHService(taskClient: fakeClient);

    final firstTaskFuture = service.runTaskStream({
      'action': 'run_workflow',
      'workflow_id': 'postgres',
      'operation_id': 'service_status',
      'connection': {'ip': '203.0.113.10'},
    }, pollInterval: const Duration(milliseconds: 2)).toList();
    final secondTaskFuture = service.runTaskStream({
      'action': 'run_workflow',
      'workflow_id': 'postgres',
      'operation_id': 'service_status',
      'connection': {'ip': '203.0.113.11'},
    }, pollInterval: const Duration(milliseconds: 2)).toList();

    await Future<void>.delayed(const Duration(milliseconds: 20));
    final cancelledCount = await service.cancelAllActiveTasks();

    expect(_expectOk(cancelledCount), 2);
    expect(fakeClient.cancelledTaskIds, containsAll(<int>[1, 2]));

    await firstTaskFuture;
    await secondTaskFuture;
  });

  test('runTaskStream short-circuits duplicate operation requests', () async {
    final fakeClient = _SerializingTaskClient();
    final service = SSHService(taskClient: fakeClient);

    final firstTaskFuture = service.runTaskStream({
      'action': 'run_workflow',
      'workflow_id': 'postgres',
      'operation_id': 'service_restart',
      'connection': {'ip': '203.0.113.10'},
    }, pollInterval: const Duration(milliseconds: 2)).toList();

    await Future<void>.delayed(const Duration(milliseconds: 20));

    final duplicateEvents = await service.runTaskStream({
      'action': 'run_workflow',
      'workflow_id': 'postgres',
      'operation_id': 'service_restart',
      'connection': {'ip': '203.0.113.10'},
    }, pollInterval: const Duration(milliseconds: 2)).toList();

    final duplicateResult = _expectOk(duplicateEvents.last);
    expect(duplicateResult.type, 'result');
    expect(duplicateResult.result?['code'], 'ENGINE_OPERATION_DEDUPED');
    expect(fakeClient.startCalls, 1);

    fakeClient.allowFirstTaskComplete = true;
    await firstTaskFuture;
  });

  test(
    'restores in-flight snapshots as uncertain failures on startup',
    () async {
      if (!ensureSqliteRuntimeAvailable()) {
        return;
      }
      final recoveryDatabase = AppDatabase.forTesting(NativeDatabase.memory());
      await recoveryDatabase.writeOperationRecoverySnapshotMaps(
        <Map<String, dynamic>>[
          <String, dynamic>{
            'operation_instance_id': 'recovered-op-1',
            'operation_type': 'postgres/service_restart',
            'host_key': '203.0.113.10',
            'state': 'running',
            'submitted_at': DateTime.now().toUtc().toIso8601String(),
            'started_at': DateTime.now().toUtc().toIso8601String(),
            'claims': <Map<String, dynamic>>[
              <String, dynamic>{
                'resource': <String, dynamic>{
                  'kind': 'stack',
                  'scope': '203.0.113.10',
                  'id': 'postgres',
                },
                'mode': 'write',
              },
            ],
            'message': 'Running before restart.',
            'metadata': const <String, dynamic>{'source': 'test'},
          },
        ],
      );

      final service = SSHService(
        taskClient: _FakeTaskClient(
          startResponse: '{"status":"success","task_id":1}',
          pollResponses: const ['{"status":"success","done":true,"events":[]}'],
          resultResponse: '{"status":"success","result":{"status":"success"}}',
        ),
        recoveryDatabase: recoveryDatabase,
      );

      await Future<void>.delayed(const Duration(milliseconds: 80));
      final queueSnapshot = service.getOperationQueueSnapshot();
      final recovered = queueSnapshot.firstWhere(
        (entry) => entry.operationInstanceId == 'recovered-op-1',
      );
      expect(recovered.state, OperationQueueState.failed);
      expect(recovered.metadata['recovery_uncertain'], isTrue);

      service.dispose();
      await recoveryDatabase.close();
    },
  );

  test('getRecentTaskHistory parses entries', () async {
    final service = SSHService(
      taskClient: _FakeTaskClient(
        startResponse: '{"status":"success","task_id":1}',
        pollResponses: const ['{"status":"success","done":true,"events":[]}'],
        resultResponse: '{"status":"success","result":{"status":"success"}}',
        recentHistoryResponse:
            '{"status":"success","history":[{"task_id":7,"status":"error","code":"ENGINE_RUNTIME_ERROR","message":"Failed","cancelled":false,"started_at":"2026-02-18T10:00:00Z","completed_at":"2026-02-18T10:01:00Z","action":"run_workflow","workflow_id":"postgres","operation_id":"service_enable"}]}',
      ),
    );

    final history = _expectOk(await service.getRecentTaskHistory(limit: 2));
    expect(history.length, 1);
    expect(history.first.taskId, 7);
    expect(history.first.workflowId, 'postgres');
    expect(history.first.operationId, 'service_enable');
    expect(history.first.status, 'error');
  });

  test('refreshServerHostKey sends refresh action payload', () async {
    final client = _CapturingTaskClient();
    final service = SSHService(taskClient: client);

    final result = await service.refreshServerHostKey(
      host: '192.168.1.200',
      port: 22,
      username: 'ubuntu',
    );

    final payload =
        jsonDecode(client.lastStartPayload!) as Map<String, dynamic>;
    expect(payload['protocol'], 1);
    expect(payload['action'], 'run_workflow');
    expect(payload['workflow_id'], 'server');
    expect(payload['operation_id'], 'refresh_host_key');
    expect(payload['host'], '192.168.1.200');
    expect(payload['port'], 22);
    expect(payload['username'], 'ubuntu');
    expect(_expectOk(result)['status'], 'success');
  });

  test(
    'setupServer sends setup action payload with parts and settings',
    () async {
      final client = _CapturingTaskClient();
      final service = SSHService(taskClient: client);

      final result = await service.setupServer(
        host: '203.0.113.10',
        port: 2222,
        username: 'root',
        password: 'secret',
        privateKey: '-----BEGIN OPENSSH PRIVATE KEY-----\nsetup\n',
        parts: const ['part1', 'part2'],
        settings: const {
          'features': ['postgres'],
        },
        managedConnection: const <String, dynamic>{
          'host': '203.0.113.10',
          'username': 'ubuntu',
        },
        dryRun: true,
      );

      final payload =
          jsonDecode(client.lastStartPayload!) as Map<String, dynamic>;
      expect(payload['protocol'], 1);
      expect(payload['action'], 'run_workflow');
      expect(payload['workflow_id'], 'setup');
      expect(payload['operation_id'], 'run');
      expect(payload['host'], '203.0.113.10');
      expect(payload['port'], 2222);
      expect(payload['username'], 'root');
      expect(payload['password'], 'secret');
      expect(payload['private_key'], contains('BEGIN OPENSSH PRIVATE KEY'));
      expect(payload.containsKey('key_path'), isFalse);
      expect(payload['dry_run'], isTrue);
      expect(payload['parts'], const ['part1', 'part2']);
      expect(payload['settings'], const {
        'features': ['postgres'],
      });
      expect(payload['managed_connection'], const <String, dynamic>{
        'host': '203.0.113.10',
        'username': 'ubuntu',
      });
      // Additive onboarding has no takeover confirmation to send.
      expect(payload.containsKey('confirm_existing_admin_takeover'), isFalse);
      expect(_expectOk(result)['status'], 'success');
    },
  );

  test('checkServer sends inline private keys without file paths', () async {
    final client = _CapturingTaskClient();
    final service = SSHService(taskClient: client);

    final result = await service.checkServer(
      host: '203.0.113.10',
      username: 'ubuntu',
      privateKey: '-----BEGIN OPENSSH PRIVATE KEY-----\ninline\n',
    );

    final payload =
        jsonDecode(client.lastStartPayload!) as Map<String, dynamic>;
    expect(payload['protocol'], 1);
    expect(payload['action'], 'run_workflow');
    expect(payload['workflow_id'], 'server');
    expect(payload['operation_id'], 'check');
    expect(payload['private_key'], contains('BEGIN OPENSSH PRIVATE KEY'));
    expect(payload.containsKey('key_path'), isFalse);
    expect(_expectOk(result)['status'], 'success');
  });

  test(
    'describeSetupPlan sends a protocol-tagged describe action payload',
    () async {
      final client = _CapturingTaskClient();
      final service = SSHService(taskClient: client);

      final result = await service.describeSetupPlan(
        parts: const ['part1'],
        settings: const {'timezone': 'UTC'},
      );

      final payload =
          jsonDecode(client.lastStartPayload!) as Map<String, dynamic>;
      expect(payload['protocol'], 1);
      expect(payload['action'], 'run_workflow');
      expect(payload['workflow_id'], 'setup');
      expect(payload['operation_id'], 'describe');
      expect(payload['parts'], const ['part1']);
      expect(payload['settings'], const {'timezone': 'UTC'});
      expect(_expectOk(result)['status'], 'success');
    },
  );

  test(
    'runWorkflow sends a protocol-tagged run_workflow action payload',
    () async {
      final client = _CapturingTaskClient();
      final service = SSHService(taskClient: client);

      final result = await service.runWorkflow(
        workflowId: 'postgres',
        operationId: 'describe',
        connection: const {'ip': '203.0.113.10', 'username': 'ubuntu'},
        params: const {'dry_run': true},
      );

      final payload =
          jsonDecode(client.lastStartPayload!) as Map<String, dynamic>;
      expect(payload['protocol'], 1);
      expect(payload['action'], 'run_workflow');
      expect(payload['workflow_id'], 'postgres');
      expect(payload['operation_id'], 'describe');
      expect(payload['connection'], const {
        'ip': '203.0.113.10',
        'username': 'ubuntu',
      });
      expect(payload['params'], const {'dry_run': true});
      expect(_expectOk(result)['status'], 'success');
    },
  );

  test('cancelActiveTask surfaces cooperative cancellation code', () async {
    final service = SSHService(
      taskClient: _CancellationResultTaskClient('ENGINE_TASK_CANCELLED'),
    );

    final streamFuture = service.runTaskStream({
      'action': 'run_workflow',
      'workflow_id': 'postgres',
      'operation_id': 'service_restart',
      'connection': {'ip': '203.0.113.10'},
    }, pollInterval: const Duration(milliseconds: 2)).toList();

    await Future<void>.delayed(const Duration(milliseconds: 20));
    final cancelled = await service.cancelActiveTask();
    expect(_expectOk(cancelled), isTrue);

    final events = await streamFuture;
    expect(_expectErr(events.last), isA<CancelledFailure>());
  });

  test('cancelActiveTask surfaces forced cancellation code', () async {
    final service = SSHService(
      taskClient: _CancellationResultTaskClient('ENGINE_TASK_CANCELLED_FORCED'),
    );

    final streamFuture = service.runTaskStream({
      'action': 'run_workflow',
      'workflow_id': 'postgres',
      'operation_id': 'service_restart',
      'connection': {'ip': '203.0.113.10'},
    }, pollInterval: const Duration(milliseconds: 2)).toList();

    await Future<void>.delayed(const Duration(milliseconds: 20));
    final cancelled = await service.cancelActiveTask();
    expect(_expectOk(cancelled), isTrue);

    final events = await streamFuture;
    expect(_expectErr(events.last), isA<CancelledFailure>());
  });

  test(
    'pollTaskEventsEnvelope returns a result for success and failure',
    () async {
      final service = SSHService(
        taskClient: _FakeTaskClient(
          startResponse: '{"status":"success","task_id":1}',
          pollResponses: const <String>[
            '{"status":"success","done":false,"events":[]}',
          ],
          resultResponse: '{"status":"success","result":{"status":"success"}}',
        ),
      );

      final payload = _expectOk(
        await service.pollTaskEventsEnvelope(1, maxEvents: 5),
      );
      expect(payload['done'], isFalse);

      final failingService = SSHService(
        taskClient: _FakeTaskClient(
          startResponse: '{"status":"success","task_id":1}',
          pollResponses: const <String>[
            '{"status":"error","msg":"poll failed"}',
          ],
          resultResponse: '{"status":"success","result":{"status":"success"}}',
        ),
      );
      final failure = _expectErr(
        await failingService.pollTaskEventsEnvelope(1),
      );
      expect(failure, isA<EngineFailure>());
      expect((failure as EngineFailure).msg, 'poll failed');
    },
  );

  test(
    'getTaskResultEnvelope returns a result for success and failure',
    () async {
      final service = SSHService(
        taskClient: _FakeTaskClient(
          startResponse: '{"status":"success","task_id":1}',
          pollResponses: const <String>[
            '{"status":"success","done":true,"events":[]}',
          ],
          resultResponse:
              '{"status":"success","result":{"status":"success","msg":"ok"}}',
        ),
      );

      final payload = _expectOk(await service.getTaskResultEnvelope(1));
      expect((payload['result'] as Map<String, dynamic>)['msg'], 'ok');

      final failingService = SSHService(
        taskClient: _FakeTaskClient(
          startResponse: '{"status":"success","task_id":1}',
          pollResponses: const <String>[
            '{"status":"success","done":true,"events":[]}',
          ],
          resultResponse: '{"status":"error","msg":"missing"}',
        ),
      );
      final failure = _expectErr(await failingService.getTaskResultEnvelope(1));
      expect(failure, isA<EngineFailure>());
      expect((failure as EngineFailure).msg, 'missing');
    },
  );

  test(
    'pollTaskEventsEnvelope sanitizes payloads for external exposure',
    () async {
      final service = SSHService(
        taskClient: _FakeTaskClient(
          startResponse: '{"status":"success","task_id":1}',
          pollResponses: const <String>[
            '{"status":"success","done":false,"events":[{"message":"deploy_private_key=topsecret"}]}',
          ],
          resultResponse: '{"status":"success","result":{"status":"success"}}',
        ),
      );

      final payload = _expectOk(
        await service.pollTaskEventsEnvelope(1, sanitizeForExposure: true),
      );
      expect(
        ((payload['events'] as List<dynamic>).single
            as Map<String, dynamic>)['message'],
        'deploy_private_key=***',
      );
    },
  );

  test(
    'getTaskResultEnvelope sanitizes payloads for external exposure',
    () async {
      final service = SSHService(
        taskClient: _FakeTaskClient(
          startResponse: '{"status":"success","task_id":1}',
          pollResponses: const <String>[
            '{"status":"success","done":true,"events":[]}',
          ],
          resultResponse:
              '{"status":"success","result":{"status":"success","deploy_private_key":"topsecret","repository_url":"https://user:pass@example.com/repo.git"}}',
        ),
      );

      final payload = _expectOk(
        await service.getTaskResultEnvelope(1, sanitizeForExposure: true),
      );
      expect(
        (payload['result'] as Map<String, dynamic>)['deploy_private_key'],
        '***',
      );
      expect(
        (payload['result'] as Map<String, dynamic>)['repository_url'],
        'https://user:***@example.com/repo.git',
      );
    },
  );

  test('getTaskHistoryEntry returns matching entry or null', () async {
    final service = SSHService(
      taskClient: _FakeTaskClient(
        startResponse: '{"status":"success","task_id":1}',
        pollResponses: const <String>[
          '{"status":"success","done":true,"events":[]}',
        ],
        resultResponse: '{"status":"success","result":{"status":"success"}}',
        recentHistoryResponse:
            '{"status":"success","history":['
            '{"task_id":7,"status":"success","message":"done","cancelled":false,"cooperative_cancel":false,"workflow_id":"app","operation_id":"run","client_operation_id":"op-7"}'
            ']}',
      ),
    );

    final entry = _expectOk(await service.getTaskHistoryEntry(7));
    expect(entry, isNotNull);
    expect(entry!.clientOperationId, 'op-7');
    expect(_expectOk(await service.getTaskHistoryEntry(8)), isNull);
  });

  test('value objects and native task adapter preserve their contracts', () {
    final event = EngineEvent.fromEventMap(<String, dynamic>{
      'type': 'progress',
      'level': 'debug',
      'message': 'Working',
      'ts': '2026-09-01T12:00:00Z',
      'data': <String, dynamic>{'step': 1},
    });
    expect(event.timestamp, DateTime.parse('2026-09-01T12:00:00Z'));
    expect(event.toMap()['ts'], '2026-09-01T12:00:00.000Z');
    expect(EngineTaskException('bad envelope').toString(), 'bad envelope');

    final client = NativeBridgeTaskClient(_NativeBridgeTaskApiFake());
    expect(client.startTask('payload'), 'start:payload');
    expect(client.pollTaskEvents(4, maxEvents: 6), 'poll:4:6');
    expect(client.getTaskResult(4), 'result:4');
    expect(client.cancelTask(4), 'cancel:4');
    expect(client.getRecentTaskHistory(limit: 6), 'history:6');
  });

  test(
    'runTaskStream reports rejected starts and engine envelopes as failures',
    () async {
      final rejected =
          await SSHService(
            taskClient: _FakeTaskClient(
              startResponse: '{"status":"success","task_id":1}',
              pollResponses: const <String>[
                '{"status":"success","done":true,"events":[]}',
              ],
              resultResponse:
                  '{"status":"success","result":{"status":"success"}}',
            ),
          ).runTaskStream(<String, dynamic>{
            'action': 'run_workflow',
            'workflow_id': 'app',
            'operation_id': 'run',
          }).toList();
      expect(_expectErr(rejected.last), isA<EngineFailure>());

      final startFailure =
          await SSHService(
            taskClient: _FakeTaskClient(
              startResponse:
                  '{"status":"error","code":"ENGINE_START_FAILED","msg":"start failed"}',
              pollResponses: const <String>[
                '{"status":"success","done":true,"events":[]}',
              ],
              resultResponse:
                  '{"status":"success","result":{"status":"success"}}',
            ),
          ).runTaskStream(<String, dynamic>{
            'action': 'run_workflow',
            'workflow_id': 'app',
            'operation_id': 'run',
            'connection': <String, dynamic>{'ip': '203.0.113.10'},
          }).toList();
      final failure = _expectErr(startFailure.last) as EngineFailure;
      expect(failure.code, 'ENGINE_START_FAILED');
    },
  );

  test(
    'runTaskStream maps poll and terminal envelope failures without throwing',
    () async {
      final pollFailure =
          await SSHService(
            taskClient: _FakeTaskClient(
              startResponse: '{"status":"success","task_id":1}',
              pollResponses: const <String>[
                '{"status":"error","code":"ENGINE_POLL_FAILED","msg":"poll failed"}',
              ],
              resultResponse:
                  '{"status":"success","result":{"status":"success"}}',
            ),
          ).runTaskStream(<String, dynamic>{
            'action': 'run_workflow',
            'workflow_id': 'app',
            'operation_id': 'run',
            'connection': <String, dynamic>{'ip': '203.0.113.10'},
          }).toList();
      expect(
        (_expectErr(pollFailure.last) as EngineFailure).code,
        'ENGINE_POLL_FAILED',
      );

      final resultEnvelopeFailure =
          await SSHService(
            taskClient: _FakeTaskClient(
              startResponse: '{"status":"success","task_id":1}',
              pollResponses: const <String>[
                '{"status":"success","done":true,"events":[]}',
              ],
              resultResponse:
                  '{"status":"error","code":"ENGINE_RESULT_FAILED","msg":"result failed"}',
            ),
          ).runTaskStream(<String, dynamic>{
            'action': 'run_workflow',
            'workflow_id': 'app',
            'operation_id': 'run',
            'connection': <String, dynamic>{'ip': '203.0.113.10'},
          }).toList();
      expect(
        (_expectErr(resultEnvelopeFailure.last) as EngineFailure).code,
        'ENGINE_RESULT_FAILED',
      );
    },
  );

  test(
    'envelope helpers preserve unexpected failures and history absence',
    () async {
      final badJson = SSHService(
        taskClient: _FakeTaskClient(
          startResponse: '{"status":"success","task_id":1}',
          pollResponses: const <String>['not json'],
          resultResponse: 'not json',
          recentHistoryResponse: 'not json',
        ),
      );
      expect(
        _expectErr(await badJson.pollTaskEventsEnvelope(1)),
        isA<UnexpectedFailure>(),
      );
      expect(
        _expectErr(await badJson.getTaskResultEnvelope(1)),
        isA<UnexpectedFailure>(),
      );
      expect(
        _expectErr(await badJson.getRecentTaskHistory()),
        isA<UnexpectedFailure>(),
      );
      expect(
        _expectErr(await badJson.getTaskHistoryEntry(1)),
        isA<UnexpectedFailure>(),
      );

      final invalidStatus = SSHService(
        taskClient: _FakeTaskClient(
          startResponse: '{"status":"success","task_id":1}',
          pollResponses: const <String>['{"status":"pending"}'],
          resultResponse: '{"status":"success","result":{"status":"success"}}',
        ),
      );
      expect(
        _expectErr(await invalidStatus.pollTaskEventsEnvelope(1)),
        isA<UnexpectedFailure>(),
      );
    },
  );

  test(
    'high-level operations return an unexpected failure for an empty stream',
    () async {
      final outcome = await _EmptyStreamSshService().checkServer(
        host: '203.0.113.10',
        username: 'root',
      );
      expect(_expectErr(outcome), isA<UnexpectedFailure>());
    },
  );

  test('recovery faults are retained as typed diagnostics', () async {
    if (!ensureSqliteRuntimeAvailable()) {
      return;
    }
    final database = _FailingRecoveryDatabase();
    final service = SSHService(
      taskClient: _FakeTaskClient(
        startResponse: '{"status":"success","task_id":1}',
        pollResponses: const <String>[
          '{"status":"success","done":true,"events":[]}',
        ],
        resultResponse: '{"status":"success","result":{"status":"success"}}',
      ),
      recoveryDatabase: database,
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(service.lastRecoveryFailure, isA<UnexpectedFailure>());
    service.dispose();
    await database.close();
  });

  test(
    'runTaskStream handles invalid start, events, and terminal shapes',
    () async {
      Future<AppFailure> lastFailureFor(_FakeTaskClient client) async {
        final outcomes = await SSHService(taskClient: client).runTaskStream(
          <String, dynamic>{
            'action': 'run_workflow',
            'workflow_id': 'app',
            'operation_id': 'run',
            'connection': <String, dynamic>{'ip': '203.0.113.10'},
          },
        ).toList();
        return _expectErr(outcomes.last);
      }

      expect(
        await lastFailureFor(
          _FakeTaskClient(
            startResponse: '{"status":"success"}',
            pollResponses: const <String>[
              '{"status":"success","done":true,"events":[]}',
            ],
            resultResponse:
                '{"status":"success","result":{"status":"success"}}',
          ),
        ),
        isA<UnexpectedFailure>(),
      );
      expect(
        await lastFailureFor(
          _FakeTaskClient(
            startResponse: '{"status":"success","task_id":1}',
            pollResponses: const <String>[
              '{"status":"success","done":false,"events":[1]}',
            ],
            resultResponse:
                '{"status":"success","result":{"status":"success"}}',
          ),
        ),
        isA<UnexpectedFailure>(),
      );
      expect(
        await lastFailureFor(
          _FakeTaskClient(
            startResponse: '{"status":"success","task_id":1}',
            pollResponses: const <String>[
              '{"status":"success","done":true,"events":[]}',
            ],
            resultResponse: '{"status":"success","result":"bad-shape"}',
          ),
        ),
        isA<UnexpectedFailure>(),
      );
    },
  );

  test(
    'cancellation results distinguish queued, active, error, and malformed paths',
    () async {
      final serializingClient = _SerializingTaskClient();
      final queuedService = SSHService(taskClient: serializingClient);
      final first = queuedService.runTaskStream(<String, dynamic>{
        'action': 'run_workflow',
        'workflow_id': 'postgres',
        'operation_id': 'service_restart',
        'connection': <String, dynamic>{'ip': '203.0.113.10'},
      }, pollInterval: const Duration(milliseconds: 2)).toList();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final queuedOutcomes = <Result<EngineEvent>>[];
      final queuedDone = Completer<void>();
      queuedService
          .runTaskStream(<String, dynamic>{
            'action': 'run_workflow',
            'workflow_id': 'postgres',
            'operation_id': 'service_restart',
            'connection': <String, dynamic>{'ip': '203.0.113.10'},
            'params': <String, dynamic>{'nonce': 2},
          }, pollInterval: const Duration(milliseconds: 2))
          .listen(queuedOutcomes.add, onDone: queuedDone.complete);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final queuedEvent = _expectOk(queuedOutcomes.single).data;
      final queuedOperationId = queuedEvent['operation_instance_id'] as String;
      expect(queuedService.canCancelOperation(queuedOperationId), isTrue);
      expect(
        _expectOk(await queuedService.cancelOperation(queuedOperationId)),
        isTrue,
      );
      await queuedDone.future;
      expect(_expectErr(queuedOutcomes.last), isA<CancelledFailure>());
      serializingClient.allowFirstTaskComplete = true;
      await first;

      final activeClient = _CancellationResultTaskClient(
        'ENGINE_TASK_CANCELLED',
      );
      final activeService = SSHService(taskClient: activeClient);
      final activeOutcomes = <Result<EngineEvent>>[];
      final activeDone = Completer<void>();
      activeService
          .runTaskStream(<String, dynamic>{
            'action': 'run_workflow',
            'workflow_id': 'postgres',
            'operation_id': 'service_restart',
            'connection': <String, dynamic>{'ip': '203.0.113.11'},
          }, pollInterval: const Duration(milliseconds: 2))
          .listen(activeOutcomes.add, onDone: activeDone.complete);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final activeOperationId =
          _expectOk(activeOutcomes.single).data['operation_instance_id']
              as String;
      expect(
        _expectOk(await activeService.cancelOperation(activeOperationId)),
        isTrue,
      );
      await activeDone.future;

      final faultyClient = _ControllableTaskClient(
        cancelResponse:
            '{"status":"error","code":"ENGINE_CANCEL_FAILED","msg":"cancel failed"}',
      );
      final faultyService = SSHService(taskClient: faultyClient);
      expect(
        _expectErr(await faultyService.cancelTask(99)),
        isA<EngineFailure>(),
      );
      faultyClient.cancelResponse = '[]';
      expect(
        _expectErr(await faultyService.cancelTask(99)),
        isA<UnexpectedFailure>(),
      );

      final activeFaultyClient = _ControllableTaskClient(
        cancelResponse: '{"status":"error","msg":"cancel failed"}',
      );
      final activeFaultyService = SSHService(taskClient: activeFaultyClient);
      final activeFaultyRun = activeFaultyService.runTaskStream(
        <String, dynamic>{
          'action': 'run_workflow',
          'workflow_id': 'app',
          'operation_id': 'run',
          'connection': <String, dynamic>{'ip': '203.0.113.12'},
        },
        pollInterval: const Duration(milliseconds: 2),
      ).toList();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(
        _expectErr(await activeFaultyService.cancelAllActiveTasks()),
        isA<EngineFailure>(),
      );
      activeFaultyClient.done = true;
      await activeFaultyRun;

      final malformedCancelClient = _ControllableTaskClient(
        cancelResponse: '[]',
      );
      final malformedCancelService = SSHService(
        taskClient: malformedCancelClient,
      );
      final malformedCancelRun = malformedCancelService.runTaskStream(
        <String, dynamic>{
          'action': 'run_workflow',
          'workflow_id': 'app',
          'operation_id': 'run',
          'connection': <String, dynamic>{'ip': '203.0.113.13'},
        },
        pollInterval: const Duration(milliseconds: 2),
      ).toList();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(
        _expectErr(await malformedCancelService.cancelAllActiveTasks()),
        isA<UnexpectedFailure>(),
      );
      malformedCancelClient.done = true;
      await malformedCancelRun;
    },
  );

  test(
    'runTaskStream reports a failed known workflow to the failure heatmap',
    () async {
      final analytics = FakeAnalyticsService();
      final service = SSHService(
        taskClient: _FakeTaskClient(
          startResponse: '{"status":"success","task_id":1}',
          pollResponses: const ['{"status":"success","done":true,"events":[]}'],
          resultResponse:
              '{"status":"success","result":{"status":"error","code":"ENGINE_RUN_FAILED","msg":"run failed"}}',
        ),
        analyticsService: analytics,
      );

      final outcomes = await service
          .runWorkflowStream(
            workflowId: 'postgres',
            operationId: 'service_restart',
            connection: const <String, dynamic>{'ip': '203.0.113.10'},
            pollInterval: Duration.zero,
          )
          .toList();

      expect(_expectErr(outcomes.last), isA<EngineFailure>());
      expect(analytics.workflowFailedEvents, [
        (workflowId: 'postgres', operationId: 'service_restart'),
      ]);
    },
  );

  test('runTaskStream reports a start failure before any task exists', () async {
    final analytics = FakeAnalyticsService();
    final service = SSHService(
      taskClient: _FakeTaskClient(
        startResponse:
            '{"status":"error","code":"ENGINE_START_FAILED","msg":"start failed"}',
        pollResponses: const ['{"status":"success","done":true,"events":[]}'],
        resultResponse: '{"status":"success","result":{"status":"success"}}',
      ),
      analyticsService: analytics,
    );

    final outcomes = await service
        .runWorkflowStream(
          workflowId: 'server',
          operationId: 'check',
          connection: const <String, dynamic>{'ip': '203.0.113.10'},
          pollInterval: Duration.zero,
        )
        .toList();

    expect(
      (_expectErr(outcomes.last) as EngineFailure).code,
      'ENGINE_START_FAILED',
    );
    expect(analytics.workflowFailedEvents, [
      (workflowId: 'server', operationId: 'check'),
    ]);
  });

  test(
    'runTaskStream stays silent on success, unknown ids, rejection, and cancel',
    () async {
      final analytics = FakeAnalyticsService();
      SSHService serviceFor(_FakeTaskClient client) =>
          SSHService(taskClient: client, analyticsService: analytics);

      // Success resolves: heatmap counts failures only.
      final successOutcomes =
          await serviceFor(
                _FakeTaskClient(
                  startResponse: '{"status":"success","task_id":1}',
                  pollResponses: const [
                    '{"status":"success","done":true,"events":[]}',
                  ],
                  resultResponse:
                      '{"status":"success","result":{"status":"success"}}',
                ),
              )
              .runWorkflowStream(
                workflowId: 'postgres',
                operationId: 'service_restart',
                connection: const <String, dynamic>{'ip': '203.0.113.10'},
                pollInterval: Duration.zero,
              )
              .toList();
      expect(_expectOk(successOutcomes.last).isResult, isTrue);

      // Unknown ids fail loudly to the caller but never enter the registry
      // vocabulary.
      final unknownOutcomes =
          await serviceFor(
                _FakeTaskClient(
                  startResponse: '{"status":"success","task_id":1}',
                  pollResponses: const [
                    '{"status":"success","done":true,"events":[]}',
                  ],
                  resultResponse:
                      '{"status":"success","result":{"status":"error","code":"ENGINE_RUN_FAILED","msg":"run failed"}}',
                ),
              )
              .runWorkflowStream(
                workflowId: 'made_up_workflow',
                operationId: 'made_up_operation',
                connection: const <String, dynamic>{'ip': '203.0.113.10'},
                pollInterval: Duration.zero,
              )
              .toList();
      expect(_expectErr(unknownOutcomes.last), isA<EngineFailure>());

      // Rejected requests never ran: a desktop-side refusal, not an engine
      // workflow failure.
      final rejectedOutcomes =
          await serviceFor(
            _FakeTaskClient(
              startResponse: '{"status":"success","task_id":1}',
              pollResponses: const [
                '{"status":"success","done":true,"events":[]}',
              ],
              resultResponse:
                  '{"status":"success","result":{"status":"success"}}',
            ),
          ).runTaskStream(<String, dynamic>{
            'action': 'run_workflow',
            'workflow_id': 'postgres',
            'operation_id': 'service_restart',
          }, pollInterval: Duration.zero).toList();
      expect(_expectErr(rejectedOutcomes.last), isA<EngineFailure>());

      // Cancelled runs stopped at the user's request: never a failure.
      final cancelService = SSHService(
        taskClient: _CancellationResultTaskClient('ENGINE_TASK_CANCELLED'),
        analyticsService: analytics,
      );
      final cancelFuture = cancelService.runTaskStream(<String, dynamic>{
        'action': 'run_workflow',
        'workflow_id': 'postgres',
        'operation_id': 'service_restart',
        'connection': <String, dynamic>{'ip': '203.0.113.10'},
      }, pollInterval: const Duration(milliseconds: 2)).toList();

      await Future<void>.delayed(const Duration(milliseconds: 20));
      final cancelled = await cancelService.cancelActiveTask();
      expect(_expectOk(cancelled), isTrue);

      final cancelOutcomes = await cancelFuture;
      expect(_expectErr(cancelOutcomes.last), isA<CancelledFailure>());

      expect(analytics.workflowFailedEvents, isEmpty);
    },
  );

  test(
    'history error envelopes and scheduler inspection remain typed',
    () async {
      final service = SSHService(
        taskClient: _FakeTaskClient(
          startResponse: '{"status":"success","task_id":1}',
          pollResponses: const <String>['[]'],
          resultResponse: '{"status":"success","result":{"status":"success"}}',
          recentHistoryResponse: '{"status":"error","msg":"history failed"}',
        ),
      );
      expect(
        _expectErr(await service.getRecentTaskHistory()),
        isA<EngineFailure>(),
      );
      expect(
        _expectErr(await service.pollTaskEventsEnvelope(1)),
        isA<UnexpectedFailure>(),
      );
      expect(service.getOperationMetricsSnapshot(), isNotNull);
      expect(service.canCancelOperation('missing-operation'), isFalse);
      final metricsSubscription = service.watchOperationMetrics().listen(
        (_) {},
      );
      final auditSubscription = service.watchOperationAuditEvents().listen(
        (_) {},
      );
      await metricsSubscription.cancel();
      await auditSubscription.cancel();
      service.dispose();
    },
  );
}
