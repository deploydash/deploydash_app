import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import '../data/local/app_database.dart';
import '../models/engine_failure_mapper.dart';
import '../models/result.dart';
import '../utils/payload_codecs.dart';
import 'app_analytics_service.dart';
import 'concurrency_engine.dart';
import 'envelope_capture.dart';
import '../native_bridge.dart';
import 'sensitive_data_sanitizer.dart';

/// One thing the engine reported while a task ran.
///
/// The engine streams progress rather than returning only at the end, because
/// provisioning a server takes minutes and a novice watching a spinner with no
/// narration cannot tell a slow step from a hung one. Exactly one event per
/// task is a *result* event ([isResult]); every other is narration.
class EngineEvent {
  /// Creates an event. Built by [fromEventMap] or [resultEvent] rather than
  /// directly, except for the client-side scheduling events this service emits
  /// itself.
  const EngineEvent({
    required this.type,
    required this.level,
    required this.message,
    required this.data,
    this.timestamp,
    this.result,
  });

  /// What kind of event this is, in the engine's vocabulary.
  final String type;

  /// `info`, `warning` or `error`, deciding how the line is rendered.
  final String level;

  /// The line itself. Backend wording, so it belongs behind a technical
  /// reveal rather than on a novice's primary path.
  final String message;

  /// Structured detail belonging to this event. Empty when the engine sent
  /// none, never null, so callers need not guard before reading a key.
  final Map<String, dynamic> data;

  /// When the engine emitted it, when it said. Null for events this client
  /// synthesizes and for a timestamp that would not parse.
  final DateTime? timestamp;

  /// The terminal result envelope, on the one event that carries it.
  final Map<String, dynamic>? result;

  /// Whether this is the terminal event carrying the operation's outcome.
  bool get isResult => result != null;

  /// This event as a plain map, for callers that still take untyped events.
  Map<String, dynamic> toMap() {
    return {
      'type': type,
      'level': level,
      'message': message,
      'data': data,
      'ts': ?timestamp?.toIso8601String(),
      if (result != null) 'result': result,
    };
  }

  /// Reads one streamed event from the engine.
  ///
  /// Every field is defaulted rather than required: a progress line is
  /// narration, and dropping the whole stream because one event lacked a level
  /// would cost the user their only view of a long operation.
  static EngineEvent fromEventMap(Map<String, dynamic> value) {
    final tsRaw = value['ts'];
    DateTime? parsedTs;
    if (tsRaw is String && tsRaw.isNotEmpty) {
      parsedTs = DateTime.tryParse(tsRaw);
    }

    final rawData = value['data'];
    final parsedData = mapFrom(rawData);

    return EngineEvent(
      type: value['type']?.toString() ?? 'event',
      level: value['level']?.toString() ?? 'info',
      message: value['message']?.toString() ?? '',
      data: parsedData,
      timestamp: parsedTs,
    );
  }

  /// Wraps a terminal result envelope as the stream's last event.
  ///
  /// The level is derived from the envelope's own status, so a failed result
  /// cannot arrive labelled `info`.
  static EngineEvent resultEvent(Map<String, dynamic> result) {
    return EngineEvent(
      type: 'result',
      level: result['status'] == 'success' ? 'info' : 'error',
      message: result['msg']?.toString() ?? '',
      data: const {},
      result: result,
    );
  }
}

/// The engine's task client returned something this client cannot use.
///
/// Distinct from an engine *error*, which arrives as a well-formed envelope
/// and becomes an [EngineFailure]. This is the malformed case -- a reply that
/// is not JSON, a missing `task_id`, an event list that is not a list -- and it
/// means the bridge is broken rather than the operation failed.
class EngineTaskException implements Exception {
  /// Creates the exception with a message naming what was malformed.
  EngineTaskException(this.message);

  /// What was wrong with the reply.
  final String message;

  @override
  String toString() => message;
}

/// The five calls this service makes across the native bridge.
///
/// Every method returns a raw JSON string because that is what the FFI
/// boundary carries; decoding happens on this side. The interface exists so
/// the whole task lifecycle -- including its malformed-reply paths -- can be
/// driven from a unit test without an embedded Python runtime.
abstract class EngineTaskClient {
  /// Starts a task from an encoded request envelope, returning the start
  /// envelope with its `task_id`.
  String startTask(String jsonPayload);

  /// Fetches up to [maxEvents] buffered events, and whether the task is done.
  String pollTaskEvents(int taskId, {int maxEvents = 100});

  /// Fetches a finished task's result envelope.
  String getTaskResult(int taskId);

  /// Asks the engine to cancel a running task.
  String cancelTask(int taskId);

  /// Fetches the most recent [limit] tasks the engine has run.
  String getRecentTaskHistory({int limit = 50});
}

/// The real client, calling through to the embedded Python engine.
class NativeBridgeTaskClient implements EngineTaskClient {
  /// Creates a client over [bridge], defaulting to the process-wide bridge.
  NativeBridgeTaskClient([NativeBridgeTaskApi? bridge])
    : _bridge = bridge ?? NativeBridge();

  final NativeBridgeTaskApi _bridge;

  @override
  String cancelTask(int taskId) => _bridge.cancelTask(taskId);

  @override
  String getTaskResult(int taskId) => _bridge.getTaskResult(taskId);

  @override
  String pollTaskEvents(int taskId, {int maxEvents = 100}) {
    return _bridge.pollTaskEvents(taskId, maxEvents: maxEvents);
  }

  @override
  String startTask(String jsonPayload) => _bridge.startTask(jsonPayload);

  @override
  String getRecentTaskHistory({int limit = 50}) {
    return _bridge.getRecentTaskHistory(limit);
  }
}

/// One finished task, as the engine remembers it.
///
/// Read back rather than kept in memory, so the desktop app can still report
/// what happened to a task it started before a restart -- which is the only
/// way an interrupted deploy can be explained to the user afterwards.
class EngineTaskHistoryEntry {
  /// Creates a history entry. Built by [fromMap].
  const EngineTaskHistoryEntry({
    required this.taskId,
    required this.status,
    required this.code,
    required this.message,
    required this.cancelled,
    required this.cooperativeCancel,
    required this.startedAt,
    required this.completedAt,
    required this.action,
    required this.workflowId,
    required this.operationId,
    required this.clientOperationId,
    required this.idempotencyKey,
  });

  /// The engine's task id, or null when the entry predates one.
  final int? taskId;

  /// How the task ended. `unknown` when the engine did not say.
  final String status;

  /// The failure code, when it failed.
  final String? code;

  /// The engine's closing message.
  final String message;

  /// Whether cancellation was requested.
  final bool cancelled;

  /// Whether the task stopped at a safe point rather than being forced.
  ///
  /// Separate from [cancelled] because the difference matters to the user: a
  /// cooperative stop left the server in a known state, a forced one may not
  /// have.
  final bool cooperativeCancel;

  /// When the task started, when the engine recorded it.
  final DateTime? startedAt;

  /// When it finished, or null while it is still running.
  final DateTime? completedAt;

  /// The wire action. `run_workflow` for everything current.
  final String? action;

  /// Which workflow ran.
  final String? workflowId;

  /// Which operation within that workflow.
  final String? operationId;

  /// The client-side instance id, linking this entry to the queue entry that
  /// scheduled it.
  final String? clientOperationId;

  /// The key that made the request repeat-safe, for matching a retry to its
  /// original.
  final String? idempotencyKey;

  /// Reads one history entry, defaulting every field the engine omitted.
  ///
  /// Blank strings become null throughout, so callers test one condition
  /// rather than two.
  static EngineTaskHistoryEntry fromMap(Map<String, dynamic> map) {
    DateTime? parseDate(dynamic value) {
      if (value is! String || value.trim().isEmpty) {
        return null;
      }
      return DateTime.tryParse(value.trim());
    }

    String? parseOptionalString(dynamic value) {
      if (value == null) {
        return null;
      }
      final text = value.toString().trim();
      if (text.isEmpty) {
        return null;
      }
      return text;
    }

    return EngineTaskHistoryEntry(
      taskId: map['task_id'] is int ? map['task_id'] as int : null,
      status: map['status']?.toString() ?? 'unknown',
      code: parseOptionalString(map['code']),
      message: map['message']?.toString() ?? '',
      cancelled: map['cancelled'] == true,
      cooperativeCancel: map['cooperative_cancel'] == true,
      startedAt: parseDate(map['started_at']),
      completedAt: parseDate(map['completed_at']),
      action: parseOptionalString(map['action']),
      workflowId: parseOptionalString(map['workflow_id']),
      operationId: parseOptionalString(map['operation_id']),
      clientOperationId: parseOptionalString(map['client_operation_id']),
      idempotencyKey: parseOptionalString(map['idempotency_key']),
    );
  }
}

/// The desktop app's whole path to the engine.
///
/// Every request is a `run_workflow` envelope started as a task, polled for
/// events, and finished with a result -- see
/// `docs/contracts/engine-protocol.md`. Nothing else in the app talks to the
/// bridge.
///
/// Three things happen here that are easy to miss:
///
/// - Every operation goes through [OperationConcurrencyEngine] first, which
///   can accept, queue, dedupe or reject it. Two deploys to one server must
///   not run at once, and the decision is surfaced as an event rather than a
///   silent wait.
/// - The queue is mirrored into the encrypted local database, so operations
///   in flight when the app dies are visible after a restart instead of
///   vanishing.
/// - Failures are typed. An engine error envelope becomes an [EngineFailure]
///   with its code intact, a cancellation becomes [CancelledFailure], and a
///   malformed reply becomes [UnexpectedFailure] -- so a caller can never show
///   a user-initiated cancel as an error.
class SSHService {
  /// Creates the service.
  ///
  /// [recoveryDatabase] is optional: without it the queue simply is not
  /// persisted, which is the right behaviour before the user has unlocked.
  /// [analyticsService] is optional: without it the failure heatmap reads
  /// the shared global at call time, which is what direct constructions get.
  SSHService({
    EngineTaskClient? taskClient,
    OperationConcurrencyEngine? concurrencyEngine,
    AppDatabase? recoveryDatabase,
    Duration? housekeepingInterval,
    AppAnalyticsService? analyticsService,
  }) : _taskClient = taskClient ?? NativeBridgeTaskClient(),
       _concurrencyEngine =
           concurrencyEngine ??
           OperationConcurrencyEngine(
             housekeepingInterval: housekeepingInterval,
           ),
       _recoveryDatabase = recoveryDatabase,
       _analyticsService = analyticsService {
    _initializeRecovery();
  }

  static const int _maxRecoverySnapshots = 120;

  /// The request envelope protocol version this client sends (T-1.5.1).
  /// Matches `orchestrator.runtime.KNOWN_PROTOCOL_VERSION`.
  static const int _engineProtocolVersion = 1;

  final EngineTaskClient _taskClient;
  final OperationConcurrencyEngine _concurrencyEngine;
  final AppDatabase? _recoveryDatabase;
  final AppAnalyticsService? _analyticsService;
  final Set<int> _activeTaskIds = <int>{};
  final ListQueue<int> _activeTaskOrder = ListQueue<int>();
  final Map<int, String> _taskOperationIds = <int, String>{};
  final Map<String, int> _operationTaskIds = <String, int>{};
  AppFailure? _lastRecoveryFailure;

  /// The most recent local recovery persistence failure, if any.
  ///
  /// Recovery remains best-effort so a local database fault cannot prevent a
  /// new engine operation from running, but the typed diagnostic is retained
  /// for inspection and focused tests.
  AppFailure? get lastRecoveryFailure => _lastRecoveryFailure;
  var _operationSequence = 0;
  StreamSubscription<List<OperationQueueSnapshot>>? _recoverySubscription;

  /// Streams a connectivity and facts check against a server.
  ///
  /// The first thing onboarding runs, and the only operation that may be given
  /// a password: at this point Deploy Dash has no key on the machine yet.
  Stream<Result<EngineEvent>> checkServerStream({
    required String host,
    int port = 22,
    required String username,
    String? password,
    String? privateKey,
    Duration pollInterval = const Duration(milliseconds: 120),
    void Function(int taskId)? onTaskStarted,
  }) {
    final payload = {
      'protocol': _engineProtocolVersion,
      'action': 'run_workflow',
      'workflow_id': 'server',
      'operation_id': 'check',
      'host': host,
      'port': port,
      'username': username,
      'password': password,
      'private_key': privateKey,
    };
    return runTaskStream(
      payload,
      pollInterval: pollInterval,
      onTaskStarted: onTaskStarted,
    );
  }

  /// Streams a re-read of the server's SSH host key.
  ///
  /// Run only after the user has been shown the old and new fingerprints and
  /// confirmed. Deploy Dash never refreshes a changed host key on its own --
  /// that is exactly what a machine-in-the-middle would need it to do.
  Stream<Result<EngineEvent>> refreshServerHostKeyStream({
    required String host,
    int port = 22,
    required String username,
    Duration pollInterval = const Duration(milliseconds: 120),
    void Function(int taskId)? onTaskStarted,
  }) {
    final payload = {
      'protocol': _engineProtocolVersion,
      'action': 'run_workflow',
      'workflow_id': 'server',
      'operation_id': 'refresh_host_key',
      'host': host,
      'port': port,
      'username': username,
    };
    return runTaskStream(
      payload,
      pollInterval: pollInterval,
      onTaskStarted: onTaskStarted,
    );
  }

  /// Streams the plan for a setup run, without touching any server.
  ///
  /// Not serialized per host because it reaches no host: the plan is computed
  /// from [parts] and [settings] alone, so making it wait behind a running
  /// operation would stall the review screen for no reason.
  Stream<Result<EngineEvent>> describeSetupPlanStream({
    List<String>? parts,
    Map<String, dynamic>? settings,
    Duration pollInterval = const Duration(milliseconds: 120),
  }) {
    final payload = <String, dynamic>{
      'protocol': _engineProtocolVersion,
      'action': 'run_workflow',
      'workflow_id': 'setup',
      'operation_id': 'describe',
      ...?parts == null ? null : <String, dynamic>{'parts': parts},
      ...?settings == null ? null : <String, dynamic>{'settings': settings},
    };
    return runTaskStream(
      payload,
      pollInterval: pollInterval,
      serializePerHost: false,
    );
  }

  /// Streams a server setup run: the ownership handoff and provisioning.
  ///
  /// [managedConnection] is the identity to pivot to once the managed
  /// `ubuntu` account is verified, which is what lets root and password
  /// login be disabled safely. Setup only adds the Deploy Dash key; it never
  /// removes existing access.
  Stream<Result<EngineEvent>> setupServerStream({
    required String host,
    int port = 22,
    required String username,
    String? password,
    String? privateKey,
    Map<String, dynamic>? managedConnection,
    List<String>? parts,
    Map<String, dynamic>? settings,
    bool dryRun = false,
    Duration pollInterval = const Duration(milliseconds: 120),
    void Function(int taskId)? onTaskStarted,
  }) {
    final payload = <String, dynamic>{
      'protocol': _engineProtocolVersion,
      'action': 'run_workflow',
      'workflow_id': 'setup',
      'operation_id': 'run',
      'host': host,
      'port': port,
      'username': username,
      'password': password,
      'private_key': privateKey,
      'dry_run': dryRun,
      ...?managedConnection == null
          ? null
          : <String, dynamic>{'managed_connection': managedConnection},
      ...?parts == null ? null : <String, dynamic>{'parts': parts},
      ...?settings == null ? null : <String, dynamic>{'settings': settings},
    };
    return runTaskStream(
      payload,
      pollInterval: pollInterval,
      onTaskStarted: onTaskStarted,
    );
  }

  /// Streams any workflow operation.
  ///
  /// The general entry point every feature uses. [params] carries user intent
  /// only; backend-owned paths, pins and identifiers are resolved server-side
  /// under the settings-ownership contract, and sending one here gets the
  /// request rejected rather than honoured.
  Stream<Result<EngineEvent>> runWorkflowStream({
    required String workflowId,
    required String operationId,
    Map<String, dynamic>? connection,
    Map<String, dynamic>? params,
    Duration pollInterval = const Duration(milliseconds: 120),
    void Function(int taskId)? onTaskStarted,
    bool serializePerHost = true,
  }) {
    final payload = <String, dynamic>{
      'protocol': _engineProtocolVersion,
      'action': 'run_workflow',
      'workflow_id': workflowId,
      'operation_id': operationId,
      ...?connection == null
          ? null
          : <String, dynamic>{'connection': connection},
      ...?params == null ? null : <String, dynamic>{'params': params},
    };
    return runTaskStream(
      payload,
      pollInterval: pollInterval,
      onTaskStarted: onTaskStarted,
      serializePerHost: serializePerHost,
    );
  }

  /// Schedules [payload], runs it, and streams every event it produces.
  ///
  /// The one path all the others funnel through. In order: the operation is
  /// scheduled, the decision is emitted as the stream's first event, and then
  /// -- if it was accepted -- the task is started and polled until done.
  ///
  /// A rejected operation ends with an `ENGINE_OPERATION_REJECTED` failure; a
  /// deduped one ends *successfully*, naming the operation it duplicates,
  /// because the work the caller asked for is already happening. Cancellation
  /// while queued ends with [CancelledFailure].
  ///
  /// The permit is always released and the task always unregistered, on every
  /// exit including a thrown one -- a leaked permit would block that host's
  /// queue for the rest of the session.
  Stream<Result<EngineEvent>> runTaskStream(
    Map<String, dynamic> payload, {
    Duration pollInterval = const Duration(milliseconds: 120),
    void Function(int taskId)? onTaskStarted,
    bool serializePerHost = true,
  }) async* {
    // TEMPORARY (T-0.5): records the outgoing envelope corpus. No-op unless
    // built with --dart-define=DEPLOYDASH_E2E_CAPTURE_ENVELOPES=<dir>.
    captureRequestEnvelope(payload);
    final operationInstanceId = _nextOperationInstanceId(payload);
    final descriptor = OperationClaimRegistry.buildDescriptor(
      operationInstanceId: operationInstanceId,
      payload: payload,
      serializePerHost: serializePerHost,
    );
    final permit = await _concurrencyEngine.schedule(descriptor);
    yield Ok<EngineEvent>(
      _scheduleDecisionEvent(
        decision: permit.decision,
        descriptor: descriptor,
        operationInstanceId: operationInstanceId,
      ),
    );

    if (permit.decision.type == OperationScheduleDecisionType.rejected) {
      permit.release(
        OperationCompletionState.failure,
        message: permit.decision.message,
      );
      yield Err<EngineEvent>(
        EngineFailure(
          code: 'ENGINE_OPERATION_REJECTED',
          msg: permit.decision.message,
        ),
      );
      return;
    }

    if (permit.decision.type == OperationScheduleDecisionType.deduped) {
      yield Ok<EngineEvent>(
        EngineEvent.resultEvent(<String, dynamic>{
          'status': 'success',
          'code': 'ENGINE_OPERATION_DEDUPED',
          'msg': permit.decision.message,
          'operation_instance_id': operationInstanceId,
          'duplicate_of_operation_id': permit.decision.duplicateOfOperationId,
        }),
      );
      return;
    }

    try {
      await permit.waitUntilDispatch;
    } on OperationQueueCancelledException {
      yield const Err<EngineEvent>(CancelledFailure());
      return;
    }

    var taskId = -1;
    var didStartTask = false;
    var completionState = OperationCompletionState.failure;
    String? completionMessage;

    try {
      final payloadToStart = Map<String, dynamic>.from(payload)
        ..['client_operation_id'] = operationInstanceId
        ..['idempotency_key'] = descriptor.idempotencyKey;
      final start = _decodeAsMap(
        _taskClient.startTask(jsonEncode(payloadToStart)),
      );
      if (start['status'] != 'success') {
        yield Err<EngineEvent>(_failureFromEnvelope(start));
        return;
      }

      final rawTaskId = start['task_id'];
      if (rawTaskId is! int) {
        throw EngineTaskException(
          'Engine task start response missing task_id.',
        );
      }
      taskId = rawTaskId;
      didStartTask = true;

      _registerActiveTask(taskId, operationInstanceId);
      onTaskStarted?.call(taskId);
      _concurrencyEngine.markRunning(
        operationInstanceId,
        taskId: taskId,
        message: 'Running on engine task $taskId.',
      );

      while (true) {
        final poll = _decodeAsMap(
          _taskClient.pollTaskEvents(taskId, maxEvents: 200),
        );
        if (poll['status'] != 'success') {
          yield Err<EngineEvent>(_failureFromEnvelope(poll));
          return;
        }

        final rawEvents = poll['events'];
        if (rawEvents is! List) {
          throw EngineTaskException('Task event payload is not a list.');
        }

        for (final item in rawEvents) {
          if (item is Map<String, dynamic>) {
            _concurrencyEngine.markProgress(operationInstanceId);
            yield Ok<EngineEvent>(EngineEvent.fromEventMap(item));
            continue;
          }
          throw EngineTaskException('Task event entry is not an object.');
        }

        if (poll['done'] == true) {
          final resultPayload = _decodeAsMap(_taskClient.getTaskResult(taskId));
          if (resultPayload['status'] != 'success') {
            yield Err<EngineEvent>(_failureFromEnvelope(resultPayload));
            return;
          }

          final result = resultPayload['result'];
          final resultMap = result is Map<String, dynamic> ? result : null;
          if (resultMap == null) {
            throw EngineTaskException('Engine task result has invalid shape.');
          }

          final resultStatus = resultMap['status']?.toString() ?? 'error';
          final resultCode = resultMap['code']?.toString() ?? '';
          completionState = resultStatus == 'success'
              ? OperationCompletionState.success
              : resultCode == 'ENGINE_TASK_CANCELLED' ||
                    resultCode == 'ENGINE_TASK_CANCELLED_FORCED'
              ? OperationCompletionState.cancelled
              : OperationCompletionState.failure;
          completionMessage = resultMap['msg']?.toString();
          if (resultStatus != 'success') {
            yield Err<EngineEvent>(_failureFromEnvelope(resultMap));
            return;
          }
          yield Ok<EngineEvent>(EngineEvent.resultEvent(resultMap));
          return;
        }

        await Future<void>.delayed(pollInterval);
      }
    } catch (error, stackTrace) {
      completionState = OperationCompletionState.failure;
      yield Err<EngineEvent>(UnexpectedFailure(error, stackTrace));
    } finally {
      if (didStartTask && taskId >= 0) {
        _unregisterActiveTask(taskId);
      }
      permit.release(completionState, message: completionMessage);
      if (completionState == OperationCompletionState.failure) {
        _reportWorkflowFailure(payload);
      }
    }
  }

  /// Reports a failed run to the workflow-failure heatmap.
  ///
  /// Exactly one row per failed `run_workflow` task: the heatmap counts
  /// engine failures by registry id, so unknown ids stay silent
  /// ([isKnownEngineWorkflowOperation]) and anything that is not a failure
  /// -- success, cancellation, rejection, dedupe -- never reaches here.
  /// Runs after the permit release, so reporting can never hold a host's
  /// queue behind analytics.
  void _reportWorkflowFailure(Map<String, dynamic> payload) {
    final workflowId = payload['workflow_id']?.toString() ?? '';
    final operationId = payload['operation_id']?.toString() ?? '';
    if (!isKnownEngineWorkflowOperation(workflowId, operationId)) {
      return;
    }
    // Injected in tests; the shared global otherwise, read at call time so
    // debugOverrideAppAnalyticsService keeps working for direct
    // constructions.
    (_analyticsService ?? appAnalyticsService).trackWorkflowFailed(
      workflowId: workflowId.trim(),
      operationId: operationId.trim(),
    );
  }

  /// Asks the engine to cancel one running task.
  ///
  /// Returns `Ok(true)` when the engine accepted the request -- not when the
  /// task has stopped. Cancellation is cooperative, so the task ends on its
  /// own terms and its result says how.
  Future<Result<bool>> cancelTask(int taskId) async {
    try {
      final operationInstanceId = _taskOperationIds[taskId];
      if (operationInstanceId != null) {
        _concurrencyEngine.markCancelling(
          operationInstanceId,
          message: 'Cancellation requested for task $taskId.',
        );
      }
      final payload = _decodeAsMap(_taskClient.cancelTask(taskId));
      if (payload['status'] == 'success') {
        _unregisterActiveTask(taskId);
        return const Ok<bool>(true);
      }
      return Err<bool>(_failureFromEnvelope(payload));
    } catch (error, stackTrace) {
      return Err<bool>(UnexpectedFailure(error, stackTrace));
    }
  }

  /// Cancels an operation by its client-side id, queued or running.
  ///
  /// A queued operation is dropped without ever reaching the engine.
  /// `Ok(false)` means there was nothing to cancel -- it already finished.
  Future<Result<bool>> cancelOperation(String operationInstanceId) async {
    final cancelledQueued = _concurrencyEngine.cancelQueuedOperation(
      operationInstanceId,
      reason: 'Queued operation cancelled by user request.',
    );
    if (cancelledQueued) {
      return const Ok<bool>(true);
    }

    final taskId = _operationTaskIds[operationInstanceId];
    if (taskId == null) {
      return const Ok<bool>(false);
    }
    return cancelTask(taskId);
  }

  /// Cancels the most recently started task, or `Ok(false)` if none is
  /// running.
  Future<Result<bool>> cancelActiveTask() async {
    final taskId = _activeTaskOrder.isEmpty ? null : _activeTaskOrder.last;
    if (taskId == null) {
      return const Ok<bool>(false);
    }
    return cancelTask(taskId);
  }

  /// Cancels every running task, newest first, returning how many were
  /// cancelled.
  Future<Result<int>> cancelAllActiveTasks() async {
    return cancelAllActiveTasksSync();
  }

  /// Reads buffered events for a task the caller is tracking itself.
  ///
  /// For callers outside [runTaskStream] -- Agent Access, chiefly -- that
  /// follow a task they did not start. Set [sanitizeForExposure] whenever the
  /// envelope leaves this process: events can quote commands, and a command
  /// can quote a credential.
  Future<Result<Map<String, dynamic>>> pollTaskEventsEnvelope(
    int taskId, {
    int maxEvents = 100,
    bool sanitizeForExposure = false,
  }) async {
    try {
      final payload = _decodeAsMap(
        _taskClient.pollTaskEvents(taskId, maxEvents: maxEvents),
      );
      if (payload['status'] != 'success') {
        return Err<Map<String, dynamic>>(_failureFromEnvelope(payload));
      }
      return Ok<Map<String, dynamic>>(
        sanitizeForExposure ? sanitizeSensitivePayloadMap(payload) : payload,
      );
    } catch (error, stackTrace) {
      return Err<Map<String, dynamic>>(UnexpectedFailure(error, stackTrace));
    }
  }

  /// Reads a finished task's result envelope.
  ///
  /// Same [sanitizeForExposure] rule as [pollTaskEventsEnvelope].
  Future<Result<Map<String, dynamic>>> getTaskResultEnvelope(
    int taskId, {
    bool sanitizeForExposure = false,
  }) async {
    try {
      final payload = _decodeAsMap(_taskClient.getTaskResult(taskId));
      if (payload['status'] != 'success') {
        return Err<Map<String, dynamic>>(_failureFromEnvelope(payload));
      }
      return Ok<Map<String, dynamic>>(
        sanitizeForExposure ? sanitizeSensitivePayloadMap(payload) : payload,
      );
    } catch (error, stackTrace) {
      return Err<Map<String, dynamic>>(UnexpectedFailure(error, stackTrace));
    }
  }

  /// Finds one task in recent history, or `Ok(null)` when it has aged out.
  ///
  /// History is bounded, so a task older than [searchLimit] entries is simply
  /// not there. That is not an error: it means the engine no longer remembers
  /// it, and the caller should say so rather than report a failure.
  Future<Result<EngineTaskHistoryEntry?>> getTaskHistoryEntry(
    int taskId, {
    int searchLimit = 200,
  }) async {
    final historyResult = await getRecentTaskHistory(limit: searchLimit);
    switch (historyResult) {
      case Err<List<EngineTaskHistoryEntry>>(:final failure):
        return Err<EngineTaskHistoryEntry?>(failure);
      case Ok<List<EngineTaskHistoryEntry>>(:final value):
        for (final entry in value) {
          if (entry.taskId == taskId) {
            return Ok<EngineTaskHistoryEntry?>(entry);
          }
        }
        return const Ok<EngineTaskHistoryEntry?>(null);
    }
  }

  /// Reads the most recent [limit] tasks the engine ran.
  ///
  /// A missing history list yields an empty list rather than a failure -- an
  /// engine that has run nothing yet is a normal state. Individual entries
  /// that are not objects are skipped instead of failing the whole read.
  Future<Result<List<EngineTaskHistoryEntry>>> getRecentTaskHistory({
    int limit = 50,
  }) async {
    try {
      final payload = _decodeAsMap(
        _taskClient.getRecentTaskHistory(limit: limit),
      );
      if (payload['status'] != 'success') {
        return Err<List<EngineTaskHistoryEntry>>(_failureFromEnvelope(payload));
      }
      final rawHistory = payload['history'];
      if (rawHistory is! List) {
        return const Ok<List<EngineTaskHistoryEntry>>(
          <EngineTaskHistoryEntry>[],
        );
      }

      final entries = <EngineTaskHistoryEntry>[];
      for (final item in rawHistory) {
        if (item is Map<String, dynamic>) {
          entries.add(EngineTaskHistoryEntry.fromMap(item));
          continue;
        }
      }
      return Ok<List<EngineTaskHistoryEntry>>(entries);
    } catch (error, stackTrace) {
      return Err<List<EngineTaskHistoryEntry>>(
        UnexpectedFailure(error, stackTrace),
      );
    }
  }

  /// Streams the operation queue as it changes.
  Stream<List<OperationQueueSnapshot>> watchOperationQueue() {
    return _concurrencyEngine.watchQueue();
  }

  /// The queue as it stands, optionally narrowed to one host.
  List<OperationQueueSnapshot> getOperationQueueSnapshot({String? hostKey}) {
    return _concurrencyEngine.snapshotsForHost(hostKey);
  }

  /// Streams scheduler metrics as they change.
  Stream<OperationSchedulerMetricsSnapshot> watchOperationMetrics() {
    return _concurrencyEngine.watchMetrics();
  }

  /// Scheduler metrics as they stand.
  OperationSchedulerMetricsSnapshot getOperationMetricsSnapshot() {
    return _concurrencyEngine.metricsSnapshot;
  }

  /// Streams scheduling decisions as an audit trail.
  Stream<OperationAuditEvent> watchOperationAuditEvents() {
    return _concurrencyEngine.watchAuditEvents();
  }

  /// Whether the operation can still be cancelled, so a button can be
  /// disabled rather than fail when pressed.
  bool canCancelOperation(String operationInstanceId) {
    return _concurrencyEngine.canCancelOperation(operationInstanceId);
  }

  /// Stops mirroring the queue and disposes the scheduler.
  ///
  /// Does not cancel running engine tasks: they belong to the engine, and
  /// tearing down a Riverpod container is not a reason to abandon a
  /// half-provisioned server.
  void dispose() {
    _recoverySubscription?.cancel();
    _recoverySubscription = null;
    _concurrencyEngine.dispose();
  }

  /// Says what would happen if this workflow operation were scheduled now.
  ///
  /// Read-only: it schedules nothing and claims nothing. This is what lets a
  /// screen warn "a deploy is already running on this server" before the user
  /// commits, rather than after.
  OperationConflictEvaluation evaluateWorkflowConflict({
    required String workflowId,
    required String operationId,
    Map<String, dynamic>? connection,
    Map<String, dynamic>? params,
    bool serializePerHost = true,
  }) {
    final payload = <String, dynamic>{
      'protocol': _engineProtocolVersion,
      'action': 'run_workflow',
      'workflow_id': workflowId,
      'operation_id': operationId,
      ...?connection == null
          ? null
          : <String, dynamic>{'connection': connection},
      ...?params == null ? null : <String, dynamic>{'params': params},
    };
    return evaluatePayloadConflict(payload, serializePerHost: serializePerHost);
  }

  /// [evaluateWorkflowConflict] for an already-built payload.
  OperationConflictEvaluation evaluatePayloadConflict(
    Map<String, dynamic> payload, {
    bool serializePerHost = true,
  }) {
    final descriptor = OperationClaimRegistry.buildDescriptor(
      operationInstanceId: _nextPreviewOperationId(payload),
      payload: payload,
      serializePerHost: serializePerHost,
    );
    return _concurrencyEngine.evaluateConflicts(descriptor);
  }

  /// Cancels every running task without awaiting, for app shutdown.
  ///
  /// Synchronous because it runs from a lifecycle hook that will not wait for
  /// a future. Stops at the first failure and reports it, rather than
  /// continuing and reporting a count that would overstate what was cancelled.
  Result<int> cancelAllActiveTasksSync() {
    if (_activeTaskOrder.isEmpty) {
      return const Ok<int>(0);
    }
    final activeTaskIds = _activeTaskOrder.toSet().toList(growable: false);
    var cancelledCount = 0;
    for (final taskId in activeTaskIds.reversed) {
      final operationInstanceId = _taskOperationIds[taskId];
      if (operationInstanceId != null) {
        _concurrencyEngine.markCancelling(
          operationInstanceId,
          message: 'Cancellation requested for task $taskId.',
        );
      }
      try {
        final payload = _decodeAsMap(_taskClient.cancelTask(taskId));
        if (payload['status'] == 'success') {
          _unregisterActiveTask(taskId);
          cancelledCount += 1;
          continue;
        }
        return Err<int>(_failureFromEnvelope(payload));
      } catch (error, stackTrace) {
        return Err<int>(UnexpectedFailure(error, stackTrace));
      }
    }
    return Ok<int>(cancelledCount);
  }

  /// Runs a server check and returns only its final result.
  ///
  /// The awaited form of [checkServerStream]; [onEvent] still sees the
  /// progress lines.
  Future<Result<Map<String, dynamic>>> checkServer({
    required String host,
    int port = 22,
    required String username,
    String? password,
    String? privateKey,
    void Function(Map<String, dynamic> event)? onEvent,
    void Function(int taskId)? onTaskStarted,
  }) async {
    return _collectFinalResult(
      checkServerStream(
        host: host,
        port: port,
        username: username,
        password: password,
        privateKey: privateKey,
        onTaskStarted: onTaskStarted,
      ),
      onEvent: onEvent,
    );
  }

  /// The awaited form of [refreshServerHostKeyStream].
  Future<Result<Map<String, dynamic>>> refreshServerHostKey({
    required String host,
    int port = 22,
    required String username,
    void Function(Map<String, dynamic> event)? onEvent,
    void Function(int taskId)? onTaskStarted,
  }) {
    return _collectFinalResult(
      refreshServerHostKeyStream(
        host: host,
        port: port,
        username: username,
        onTaskStarted: onTaskStarted,
      ),
      onEvent: onEvent,
    );
  }

  /// The awaited form of [describeSetupPlanStream].
  Future<Result<Map<String, dynamic>>> describeSetupPlan({
    List<String>? parts,
    Map<String, dynamic>? settings,
    void Function(Map<String, dynamic> event)? onEvent,
  }) {
    return _collectFinalResult(
      describeSetupPlanStream(parts: parts, settings: settings),
      onEvent: onEvent,
    );
  }

  /// The awaited form of [setupServerStream].
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
  }) {
    return _collectFinalResult(
      setupServerStream(
        host: host,
        port: port,
        username: username,
        password: password,
        privateKey: privateKey,
        managedConnection: managedConnection,
        parts: parts,
        settings: settings,
        dryRun: dryRun,
        onTaskStarted: onTaskStarted,
      ),
      onEvent: onEvent,
    );
  }

  /// The awaited form of [runWorkflowStream]. The method most of the app
  /// calls.
  Future<Result<Map<String, dynamic>>> runWorkflow({
    required String workflowId,
    required String operationId,
    Map<String, dynamic>? connection,
    Map<String, dynamic>? params,
    void Function(Map<String, dynamic> event)? onEvent,
    void Function(int taskId)? onTaskStarted,
    bool serializePerHost = true,
  }) {
    return _collectFinalResult(
      runWorkflowStream(
        workflowId: workflowId,
        operationId: operationId,
        connection: connection,
        params: params,
        onTaskStarted: onTaskStarted,
        serializePerHost: serializePerHost,
      ),
      onEvent: onEvent,
    );
  }

  void _registerActiveTask(int taskId, String operationInstanceId) {
    _activeTaskIds.add(taskId);
    _activeTaskOrder.remove(taskId);
    _activeTaskOrder.addLast(taskId);
    _taskOperationIds[taskId] = operationInstanceId;
    _operationTaskIds[operationInstanceId] = taskId;
  }

  void _unregisterActiveTask(int taskId) {
    final operationInstanceId = _taskOperationIds.remove(taskId);
    if (operationInstanceId != null) {
      _operationTaskIds.remove(operationInstanceId);
    }
    if (_activeTaskIds.remove(taskId)) {
      _activeTaskOrder.remove(taskId);
    }
  }

  Future<Result<Map<String, dynamic>>> _collectFinalResult(
    Stream<Result<EngineEvent>> stream, {
    void Function(Map<String, dynamic> event)? onEvent,
  }) async {
    Map<String, dynamic>? finalResult;
    await for (final eventResult in stream) {
      switch (eventResult) {
        case Err<EngineEvent>(:final failure):
          return Err<Map<String, dynamic>>(failure);
        case Ok<EngineEvent>(:final value):
          if (value.isResult) {
            finalResult = value.result;
          } else {
            onEvent?.call(value.toMap());
          }
      }
    }

    if (finalResult == null) {
      return Err<Map<String, dynamic>>(
        UnexpectedFailure(
          StateError('Engine did not return a terminal result.'),
        ),
      );
    }
    return Ok<Map<String, dynamic>>(finalResult);
  }

  void _initializeRecovery() {
    unawaited(_initializeRecoveryAsync());
  }

  Future<void> _initializeRecoveryAsync() async {
    final recoveredSnapshots = await _loadRecoverySnapshots();
    if (recoveredSnapshots.isNotEmpty) {
      _concurrencyEngine.restoreRecoveredSnapshots(recoveredSnapshots);
    }
    unawaited(_recoverySubscription?.cancel());
    _recoverySubscription = _concurrencyEngine.watchQueue().listen((snapshot) {
      unawaited(_persistRecoverySnapshots(snapshot));
    });
    await _persistRecoverySnapshots(_concurrencyEngine.queueSnapshot);
  }

  Future<List<OperationQueueSnapshot>> _loadRecoverySnapshots() async {
    try {
      final recoveryDatabase = _recoveryDatabase;
      if (recoveryDatabase == null) {
        return const <OperationQueueSnapshot>[];
      }

      final snapshotsRaw = await recoveryDatabase
          .readOperationRecoverySnapshotMaps();
      final snapshots = <OperationQueueSnapshot>[];
      for (final item in snapshotsRaw) {
        snapshots.add(OperationQueueSnapshot.fromMap(item));
      }
      return snapshots;
    } catch (error, stackTrace) {
      _recordRecoveryFailure(error, stackTrace);
      return const <OperationQueueSnapshot>[];
    }
  }

  Future<void> _persistRecoverySnapshots(
    List<OperationQueueSnapshot> snapshots,
  ) async {
    try {
      final recoveryDatabase = _recoveryDatabase;
      if (recoveryDatabase == null) {
        return;
      }
      final sorted = List<OperationQueueSnapshot>.from(
        snapshots,
        growable: false,
      )..sort((left, right) => left.submittedAt.compareTo(right.submittedAt));
      final trimmed = sorted
          .skip((sorted.length - _maxRecoverySnapshots).clamp(0, sorted.length))
          .toList(growable: false);
      await recoveryDatabase.writeOperationRecoverySnapshotMaps(
        trimmed.map((snapshot) => snapshot.toMap()).toList(growable: false),
      );
    } catch (error, stackTrace) {
      _recordRecoveryFailure(error, stackTrace);
    }
  }

  AppFailure _failureFromEnvelope(Map<String, dynamic> envelope) {
    if (envelope['status'] == 'error') {
      return mapEngineErrorToFailure(envelope);
    }
    return UnexpectedFailure(
      StateError(
        envelope['msg']?.toString() ?? 'Engine returned an invalid envelope.',
      ),
    );
  }

  void _recordRecoveryFailure(Object error, StackTrace stackTrace) {
    _lastRecoveryFailure = UnexpectedFailure(error, stackTrace);
  }

  String _nextOperationInstanceId(Map<String, dynamic> payload) {
    _operationSequence += 1;
    final action = payload['action']?.toString().trim();
    final workflowId = payload['workflow_id']?.toString().trim();
    final workflowOperationId = payload['operation_id']?.toString().trim();
    final label = action == 'run_workflow'
        ? '${workflowId ?? 'workflow'}-${workflowOperationId ?? 'operation'}'
        : (action ?? 'task');
    return '$label-${DateTime.now().toUtc().microsecondsSinceEpoch}'
        '-$_operationSequence';
  }

  String _nextPreviewOperationId(Map<String, dynamic> payload) {
    final action = payload['action']?.toString().trim();
    return '${action ?? 'preview'}-preview-'
        '${DateTime.now().toUtc().microsecondsSinceEpoch}';
  }

  EngineEvent _scheduleDecisionEvent({
    required OperationScheduleDecision decision,
    required OperationDescriptor descriptor,
    required String operationInstanceId,
  }) {
    return EngineEvent(
      type: 'operation_schedule_decision',
      level: switch (decision.type) {
        OperationScheduleDecisionType.accepted => 'info',
        OperationScheduleDecisionType.queued => 'warning',
        OperationScheduleDecisionType.rejected => 'error',
        OperationScheduleDecisionType.deduped => 'info',
      },
      message: decision.message,
      data: <String, dynamic>{
        'decision': decision.toMap(),
        'operation_instance_id': operationInstanceId,
        'operation_type': descriptor.operationType,
        'workflow_id': descriptor.workflowId,
        'workflow_operation_id': descriptor.workflowOperationId,
        'claims': descriptor.claims
            .map((claim) => claim.toMap())
            .toList(growable: false),
      },
    );
  }

  Map<String, dynamic> _decodeAsMap(String raw) {
    final decoded = jsonDecode(raw);
    if (decoded is Map<String, dynamic>) {
      return decoded;
    }
    throw EngineTaskException('Invalid JSON envelope from engine task client.');
  }
}
