part of '../../agent_access_service.dart';

/// The refusal for a `task_id` that is not an integer.
///
/// One constant, four call sites. Three of them used to answer
/// `500 internal_error` with the message `'Bad state: Task id must be an
/// integer.'` -- a client's malformed argument reported as a server fault,
/// carrying a Dart `StateError` prefix fossilised from a version that caught
/// and stringified an exception this code no longer throws. `_replyCancelTask`
/// in this same file always did it correctly; this is that one, parameterised
/// to nothing because there is nothing to vary.
const AgentAccessReply _invalidTaskIdReply = AgentAccessReply(
  HttpStatus.badRequest,
  <String, dynamic>{
    'error': 'invalid_task_id',
    'message': 'Task id must be an integer.',
  },
);

/// Tools answering about engine tasks — history, status, events, results,
/// queue-conflict preview — and the one that cancels a running task.
extension _AgentAccessTaskTools on AgentAccessService {
  Future<AgentAccessReply> _replyTaskHistory(
    AppPreferencesRecord preferences,
    String? authorization, {
    int limit = 20,
  }) async {
    final authError = AgentAccessAuthorization.errorForBearerToken(
      authorization,
      preferences,
    );
    if (authError != null) {
      return AgentAccessReply(HttpStatus.forbidden, authError);
    }
    final historyResult = await ref
        .read(sshServiceProvider)
        .getRecentTaskHistory(limit: limit);
    if (historyResult case Err<List<EngineTaskHistoryEntry>>(:final failure)) {
      return AgentAccessReply(HttpStatus.badGateway, <String, dynamic>{
        'error': 'engine_error',
        'message': _agentFailureMessage(failure),
      });
    }
    final history = (historyResult as Ok<List<EngineTaskHistoryEntry>>).value;
    final appHistory = history
        .where((entry) => entry.workflowId == 'app')
        .map(
          (entry) => <String, dynamic>{
            'task_id': entry.taskId,
            'status': entry.status,
            'code': entry.code,
            'message': entry.message,
            'cancelled': entry.cancelled,
            'started_at': entry.startedAt?.toIso8601String(),
            'completed_at': entry.completedAt?.toIso8601String(),
            'workflow_id': entry.workflowId,
            'operation_id': entry.operationId,
            'client_operation_id': entry.clientOperationId,
          },
        )
        .toList(growable: false);
    await _audit(
      toolName: 'get_task_history',
      accessLevel: 'read_only',
      status: 'success',
      summary: 'Read recent app workflow task history.',
      details: <String, dynamic>{'count': appHistory.length},
    );
    return AgentAccessReply(HttpStatus.ok, <String, dynamic>{
      'task_history': appHistory,
    });
  }

  Future<AgentAccessReply> _replyTaskStatus(
    AppPreferencesRecord preferences,
    String? authorization,
    Object? taskIdRaw,
  ) async {
    final authError = AgentAccessAuthorization.errorForBearerToken(
      authorization,
      preferences,
    );
    if (authError != null) {
      return AgentAccessReply(HttpStatus.forbidden, authError);
    }
    final taskId = _intOrNull(taskIdRaw);
    if (taskId == null) {
      return _invalidTaskIdReply;
    }
    final entryResult = await ref
        .read(sshServiceProvider)
        .getTaskHistoryEntry(taskId);
    if (entryResult case Err<EngineTaskHistoryEntry?>(:final failure)) {
      return AgentAccessReply(HttpStatus.badGateway, <String, dynamic>{
        'error': 'engine_error',
        'message': _agentFailureMessage(failure),
      });
    }
    final entry = (entryResult as Ok<EngineTaskHistoryEntry?>).value;
    if (entry == null) {
      return const AgentAccessReply(HttpStatus.notFound, <String, dynamic>{
        'error': 'task_not_found',
        'message': 'Task id was not found in recent history.',
      });
    }
    return AgentAccessReply(HttpStatus.ok, <String, dynamic>{
      'task': _taskHistoryEntryToJson(entry),
    });
  }

  Future<AgentAccessReply> _replyTaskEvents(
    AppPreferencesRecord preferences,
    String? authorization,
    Object? taskIdRaw, {
    int maxEvents = 100,
  }) async {
    final authError = AgentAccessAuthorization.errorForBearerToken(
      authorization,
      preferences,
    );
    if (authError != null) {
      return AgentAccessReply(HttpStatus.forbidden, authError);
    }
    final taskId = _intOrNull(taskIdRaw);
    if (taskId == null) {
      return _invalidTaskIdReply;
    }
    final result = await ref
        .read(sshServiceProvider)
        .pollTaskEventsEnvelope(
          taskId,
          maxEvents: maxEvents,
          sanitizeForExposure: true,
        );
    return AgentAccessReply(
      result is Ok<Map<String, dynamic>>
          ? HttpStatus.ok
          : HttpStatus.badGateway,
      <String, dynamic>{'task_id': taskId, ...result.diagnosticPayload},
    );
  }

  Future<AgentAccessReply> _replyTaskResult(
    AppPreferencesRecord preferences,
    String? authorization,
    Object? taskIdRaw,
  ) async {
    final authError = AgentAccessAuthorization.errorForBearerToken(
      authorization,
      preferences,
    );
    if (authError != null) {
      return AgentAccessReply(HttpStatus.forbidden, authError);
    }
    final taskId = _intOrNull(taskIdRaw);
    if (taskId == null) {
      return _invalidTaskIdReply;
    }
    final result = await ref
        .read(sshServiceProvider)
        .getTaskResultEnvelope(taskId, sanitizeForExposure: true);
    return AgentAccessReply(
      result is Ok<Map<String, dynamic>>
          ? HttpStatus.ok
          : HttpStatus.badGateway,
      <String, dynamic>{'task_id': taskId, ...result.diagnosticPayload},
    );
  }

  Future<AgentAccessReply> _replyEvaluateConflict(
    Map<String, dynamic> arguments,
  ) async {
    final workflowId = (arguments['workflow_id'] ?? '').toString().trim();
    final operationId = (arguments['operation_id'] ?? '').toString().trim();
    if (workflowId.isEmpty || operationId.isEmpty) {
      return const AgentAccessReply(HttpStatus.badRequest, <String, dynamic>{
        'error': 'invalid_request',
        'message': 'workflow_id and operation_id are required.',
      });
    }
    final connection = mcpMapOrNull(arguments['connection']);
    final params = mcpMapOrNull(arguments['params']);
    final serializePerHost = arguments['serialize_per_host'] != false;
    final evaluation = ref
        .read(sshServiceProvider)
        .evaluateWorkflowConflict(
          workflowId: workflowId,
          operationId: operationId,
          connection: connection,
          params: params,
          serializePerHost: serializePerHost,
        );
    return AgentAccessReply(HttpStatus.ok, <String, dynamic>{
      'workflow_id': workflowId,
      'operation_id': operationId,
      'conflict': evaluation.toMap(),
    });
  }

  Future<AgentAccessReply> _replyCancelTask(
    Object? taskIdRaw,
    AppPreferencesRecord preferences,
    String? authorization,
  ) async {
    final authError = AgentAccessAuthorization.errorForBearerToken(
      authorization,
      preferences,
    );
    if (authError != null) {
      return AgentAccessReply(HttpStatus.forbidden, authError);
    }
    final taskId = _intOrNull(taskIdRaw);
    if (taskId == null) {
      return _invalidTaskIdReply;
    }
    final cancellationResult = await ref
        .read(sshServiceProvider)
        .cancelTask(taskId);
    final cancelled = switch (cancellationResult) {
      Ok<bool>(:final value) => value,
      Err<bool>() => false,
    };
    await _audit(
      toolName: 'cancel_task',
      accessLevel: agentAccessPermissionRedeploy,
      status: cancelled ? 'success' : 'failed',
      summary: cancelled
          ? 'Cancelled running agent task.'
          : 'Task cancellation failed.',
      details: <String, dynamic>{'task_id': taskId},
    );
    return AgentAccessReply(
      cancelled ? HttpStatus.ok : HttpStatus.badGateway,
      <String, dynamic>{'cancelled': cancelled, 'task_id': taskId},
    );
  }

  Future<EngineTaskHistoryEntry?> _waitForTaskHistoryEntry(
    int taskId, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final entryResult = await ref
          .read(sshServiceProvider)
          .getTaskHistoryEntry(taskId);
      final entry = switch (entryResult) {
        Ok<EngineTaskHistoryEntry?>(:final value) => value,
        Err<EngineTaskHistoryEntry?>() => null,
      };
      if (entry != null) {
        return entry;
      }
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
    return null;
  }
}
