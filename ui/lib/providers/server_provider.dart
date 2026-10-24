import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/local/app_database.dart';
import '../data/local/server_credential_repository.dart';
import '../domain/server.dart';
import '../models/result.dart';
import '../models/run_guard.dart';
import '../services/app_analytics_service.dart';
import '../services/ssh_service.dart';
import '../utils/payload_codecs.dart';

export '../data/local/server_repository.dart';

/// Provider-layer access to a server's sensitive workflow connection.
///
/// UI code may request a payload but must not import the credential table or
/// its repository directly.
typedef ServerConnectionPayloadResolver =
    Future<Map<String, dynamic>?> Function(Server server);

final serverConnectionPayloadResolverProvider =
    Provider<ServerConnectionPayloadResolver>((ref) {
      final credentials = ref.watch(serverCredentialRepositoryProvider);
      return credentials.connectionPayload;
    });

enum ServerTaskType { idle, verification, setup }

class ServerState {
  static const Object _unset = Object();

  final bool isLoading;
  final bool isCancelling;
  final Map<String, dynamic>? result;
  final Map<String, dynamic>? setupResult;
  final Map<String, dynamic>? errorPayload;
  final String? error;
  final List<Map<String, dynamic>> events;
  final List<Map<String, dynamic>> setupActions;
  final ServerTaskType taskType;

  ServerState({
    this.isLoading = false,
    this.isCancelling = false,
    this.result,
    this.setupResult,
    this.errorPayload,
    this.error,
    this.events = const [],
    this.setupActions = const [],
    this.taskType = ServerTaskType.idle,
  });

  ServerState copyWith({
    bool? isLoading,
    bool? isCancelling,
    Object? result = _unset,
    Object? setupResult = _unset,
    Object? errorPayload = _unset,
    String? error,
    Object? events = _unset,
    Object? setupActions = _unset,
    ServerTaskType? taskType,
  }) {
    return ServerState(
      isLoading: isLoading ?? this.isLoading,
      isCancelling: isCancelling ?? this.isCancelling,
      result: identical(result, _unset)
          ? this.result
          : result as Map<String, dynamic>?,
      setupResult: identical(setupResult, _unset)
          ? this.setupResult
          : setupResult as Map<String, dynamic>?,
      errorPayload: identical(errorPayload, _unset)
          ? this.errorPayload
          : errorPayload as Map<String, dynamic>?,
      error: error,
      events: identical(events, _unset)
          ? this.events
          : events as List<Map<String, dynamic>>,
      setupActions: identical(setupActions, _unset)
          ? this.setupActions
          : setupActions as List<Map<String, dynamic>>,
      taskType: taskType ?? this.taskType,
    );
  }
}

class ServerNotifier extends Notifier<ServerState> {
  final _ServerProviderRunGuard _runGuard = _ServerProviderRunGuard();

  @override
  ServerState build() {
    _sshService = ref.read(sshServiceProvider);
    return ServerState();
  }

  late final SSHService _sshService;

  Future<void> checkServer({
    required String host,
    int port = 22,
    required String username,
    String? password,
    String? privateKey,
  }) async {
    final run = _runGuard.start();
    state = state.copyWith(
      isLoading: true,
      isCancelling: false,
      error: null,
      errorPayload: null,
      result: null,
      setupResult: null,
      events: const <Map<String, dynamic>>[],
      taskType: ServerTaskType.verification,
    );

    try {
      final response = await _sshService.checkServer(
        host: host,
        port: port,
        username: username,
        password: password,
        privateKey: privateKey,
        onTaskStarted: (taskId) {
          _runGuard.registerTask(run, taskId);
        },
        onEvent: (event) {
          if (!_runGuard.isCurrent(run)) {
            return;
          }
          final nextEvents = List<Map<String, dynamic>>.from(state.events)
            ..add(event);
          state = state.copyWith(events: nextEvents);
        },
      );

      if (!_runGuard.isCurrent(run)) {
        return;
      }

      switch (response) {
        case Ok<Map<String, dynamic>>(:final value):
          state = state.copyWith(
            isLoading: false,
            isCancelling: false,
            result: value,
            errorPayload: null,
            setupActions: _extractActionsFromResult(value),
          );
          _runGuard.complete(run);
        case Err<Map<String, dynamic>>(failure: CancelledFailure()):
          state = state.copyWith(
            isLoading: false,
            isCancelling: false,
            error: null,
            errorPayload: null,
          );
          _runGuard.complete(run);
        case Err<Map<String, dynamic>>(:final failure):
          state = state.copyWith(
            isLoading: false,
            isCancelling: false,
            error: _failureMessage(failure, 'Unknown error'),
            errorPayload: _errorPayloadForFailure(failure),
          );
          _runGuard.complete(run);
      }
    } catch (e) {
      if (!_runGuard.isCurrent(run)) {
        return;
      }
      state = state.copyWith(
        isLoading: false,
        isCancelling: false,
        error: e.toString(),
        errorPayload: null,
      );
      _runGuard.complete(run);
    }
  }

  Future<bool> refreshServerHostKey({
    required String host,
    int port = 22,
    required String username,
  }) async {
    final run = _runGuard.start();
    state = state.copyWith(
      isLoading: true,
      isCancelling: false,
      error: null,
      errorPayload: null,
      result: null,
      setupResult: null,
      events: const <Map<String, dynamic>>[],
      taskType: ServerTaskType.verification,
    );

    try {
      final response = await _sshService.refreshServerHostKey(
        host: host,
        port: port,
        username: username,
        onTaskStarted: (taskId) {
          _runGuard.registerTask(run, taskId);
        },
        onEvent: (event) {
          if (!_runGuard.isCurrent(run)) {
            return;
          }
          final nextEvents = List<Map<String, dynamic>>.from(state.events)
            ..add(event);
          state = state.copyWith(events: nextEvents);
        },
      );

      if (!_runGuard.isCurrent(run)) {
        return false;
      }

      switch (response) {
        case Ok<Map<String, dynamic>>():
          state = state.copyWith(
            isLoading: false,
            isCancelling: false,
            error: null,
            errorPayload: null,
            result: null,
            setupResult: null,
          );
          _runGuard.complete(run);
          return true;
        case Err<Map<String, dynamic>>(failure: CancelledFailure()):
          state = state.copyWith(
            isLoading: false,
            isCancelling: false,
            error: null,
            errorPayload: null,
          );
          _runGuard.complete(run);
          return false;
        case Err<Map<String, dynamic>>(:final failure):
          state = state.copyWith(
            isLoading: false,
            isCancelling: false,
            error: _failureMessage(failure, 'Unable to refresh SSH host key.'),
            errorPayload: _errorPayloadForFailure(failure),
          );
          _runGuard.complete(run);
          return false;
      }
    } catch (error) {
      if (!_runGuard.isCurrent(run)) {
        return false;
      }
      state = state.copyWith(
        isLoading: false,
        isCancelling: false,
        error: error.toString(),
        errorPayload: null,
      );
      _runGuard.complete(run);
      return false;
    }
  }

  Future<void> loadSetupPlan({
    List<String>? parts,
    Map<String, dynamic>? settings,
  }) async {
    final run = _runGuard.start();
    final response = await _sshService.describeSetupPlan(
      parts: parts,
      settings: settings,
    );
    if (!_runGuard.isCurrent(run)) {
      return;
    }
    switch (response) {
      case Ok<Map<String, dynamic>>(:final value):
        state = state.copyWith(setupActions: _extractActionsFromResult(value));
      case Err<Map<String, dynamic>>():
        return;
    }
  }

  Future<void> setupServer({
    required String host,
    int port = 22,
    required String username,
    String? password,
    String? privateKey,
    Map<String, dynamic>? managedConnection,
    List<String>? parts,
    Map<String, dynamic>? settings,
    bool dryRun = false,
  }) async {
    final run = _runGuard.start();
    state = state.copyWith(
      isLoading: true,
      isCancelling: false,
      error: null,
      errorPayload: null,
      setupResult: null,
      events: const <Map<String, dynamic>>[],
      taskType: ServerTaskType.setup,
    );

    try {
      final response = await _sshService.setupServer(
        host: host,
        port: port,
        username: username,
        password: password,
        privateKey: privateKey,
        managedConnection: managedConnection,
        parts: parts,
        settings: settings,
        dryRun: dryRun,
        onTaskStarted: (taskId) {
          _runGuard.registerTask(run, taskId);
        },
        onEvent: (event) {
          if (!_runGuard.isCurrent(run)) {
            return;
          }
          final nextEvents = List<Map<String, dynamic>>.from(state.events)
            ..add(event);
          state = state.copyWith(events: nextEvents);
        },
      );

      if (!_runGuard.isCurrent(run)) {
        return;
      }

      switch (response) {
        case Ok<Map<String, dynamic>>(:final value):
          state = state.copyWith(
            isLoading: false,
            isCancelling: false,
            setupResult: value,
            errorPayload: null,
            setupActions: _extractActionsFromResult(value),
          );
          _runGuard.complete(run);
        case Err<Map<String, dynamic>>(failure: CancelledFailure()):
          state = state.copyWith(
            isLoading: false,
            isCancelling: false,
            error: null,
            errorPayload: null,
          );
          _runGuard.complete(run);
        case Err<Map<String, dynamic>>(:final failure):
          state = state.copyWith(
            isLoading: false,
            isCancelling: false,
            error: _failureMessage(failure, 'Unknown error'),
            errorPayload: _errorPayloadForFailure(failure),
          );
          _runGuard.complete(run);
      }
    } catch (error) {
      if (!_runGuard.isCurrent(run)) {
        return;
      }
      state = state.copyWith(
        isLoading: false,
        isCancelling: false,
        error: error.toString(),
        errorPayload: null,
      );
      _runGuard.complete(run);
    }
  }

  Future<void> cancelCheck() async {
    if (!state.isLoading) {
      return;
    }
    final taskIdToCancel = _runGuard.cancelActive();
    state = state.copyWith(isCancelling: true, error: null, errorPayload: null);
    try {
      final cancelResult = taskIdToCancel == null
          ? await _sshService.cancelActiveTask()
          : await _sshService.cancelTask(taskIdToCancel);
      final cancelled = switch (cancelResult) {
        Ok<bool>(:final value) => value,
        Err<bool>() => false,
      };
      final nextEvents = List<Map<String, dynamic>>.from(state.events)
        ..add({
          'type': 'task_cancel_requested',
          'level': cancelled ? 'warning' : 'error',
          'message': cancelled
              ? 'Cancellation requested.'
              : 'Unable to request cancellation.',
          'data': const <String, dynamic>{},
        });
      final cancelLabel = state.taskType == ServerTaskType.setup
          ? 'Setup cancelled.'
          : 'Verification cancelled.';
      state = state.copyWith(
        isLoading: false,
        isCancelling: false,
        error: cancelled ? cancelLabel : 'Cancellation failed.',
        errorPayload: null,
        result: null,
        events: nextEvents,
        taskType: ServerTaskType.idle,
      );
    } catch (error) {
      state = state.copyWith(
        isLoading: false,
        isCancelling: false,
        error: 'Cancellation failed: $error',
        errorPayload: null,
        taskType: ServerTaskType.idle,
      );
    }
  }

  static String _failureMessage(AppFailure failure, String fallback) {
    return switch (failure) {
      EngineFailure(:final msg) when msg.trim().isNotEmpty => msg.trim(),
      ConnectionFailure(:final message) => message,
      ValidationFailure(:final message) => message,
      LocalStorageFailure(:final message) => message,
      UnexpectedFailure(:final error) => error.toString(),
      _ => fallback,
    };
  }

  static Map<String, dynamic>? _errorPayloadForFailure(AppFailure failure) {
    return switch (failure) {
      EngineFailure(
        :final code,
        :final msg,
        :final stage,
        :final details,
        :final context,
      ) =>
        <String, dynamic>{
          'code': code,
          'msg': msg,
          ...?(stage == null ? null : <String, dynamic>{'stage': stage}),
          ...?(details == null ? null : <String, dynamic>{'details': details}),
          ...context,
        },
      _ => null,
    };
  }

  void reset() {
    _runGuard.reset();
    state = ServerState();
  }
}

class _ServerProviderRunGuard {
  static const String _scopeKey = 'server_provider';
  static const String _kind = 'request';

  final ScopedRunRegistry _runs = ScopedRunRegistry();
  ScopedRunContext? _activeRun;
  int? _activeTaskId;

  ScopedRunContext start() {
    final run = _runs.capture(scopeKey: _scopeKey, kind: _kind);
    _activeRun = run;
    _activeTaskId = null;
    return run;
  }

  bool isCurrent(ScopedRunContext run) {
    return _activeRun?.runId == run.runId && _runs.isCurrent(run);
  }

  void registerTask(ScopedRunContext run, int taskId) {
    if (!isCurrent(run)) {
      return;
    }
    _activeTaskId = taskId;
  }

  void complete(ScopedRunContext run) {
    if (!isCurrent(run)) {
      return;
    }
    _activeTaskId = null;
  }

  int? cancelActive() {
    final taskId = _activeTaskId;
    _activeRun = null;
    _activeTaskId = null;
    _runs.advance(scopeKey: _scopeKey, kind: _kind);
    return taskId;
  }

  void reset() {
    _activeRun = null;
    _activeTaskId = null;
    _runs.clearAll();
  }
}

final sshServiceProvider = Provider<SSHService>((ref) {
  final database = ref.watch(appDatabaseProvider);
  final service = SSHService(
    recoveryDatabase: database,
    housekeepingInterval: const Duration(seconds: 15),
    analyticsService: ref.watch(appAnalyticsServiceProvider),
  );
  ref.onDispose(service.dispose);
  return service;
});

final serverProvider = NotifierProvider<ServerNotifier, ServerState>(() {
  return ServerNotifier();
});

List<Map<String, dynamic>> _extractActionsFromResult(
  Map<String, dynamic> payload,
) {
  final steps = payload['steps'];
  if (steps is! List) {
    return const <Map<String, dynamic>>[];
  }

  final seenActionIds = <String>{};
  final extracted = <Map<String, dynamic>>[];

  for (final rawStep in steps) {
    if (rawStep is! Map) {
      continue;
    }
    final step = mapFrom(rawStep);
    final stepId = step['id']?.toString() ?? '';
    final stepTitle = step['title']?.toString() ?? '';
    final stepPart = step['part']?.toString() ?? '';
    final actions = step['actions'];
    if (actions is! List) {
      continue;
    }

    for (final rawAction in actions) {
      if (rawAction is! Map) {
        continue;
      }
      final action = mapFrom(rawAction);
      final actionId = action['id']?.toString().trim() ?? '';
      if (actionId.isEmpty || !seenActionIds.add(actionId)) {
        continue;
      }
      extracted.add(<String, dynamic>{
        'id': actionId,
        'label': action['label']?.toString() ?? stepTitle,
        'description':
            action['description']?.toString() ??
            'Execute configured server setup action',
        'step_id': stepId,
        'step_title': stepTitle,
        'part': stepPart,
      });
    }
  }

  return extracted;
}
