import 'package:ui/models/result.dart';
import 'package:ui/services/ssh_service.dart';

/// Adapts map-shaped fixture responses to the production [SSHService] result
/// boundary. Existing UI fixtures can focus on their payload while callers
/// still exercise the same [Ok] path as production code.
abstract class LegacySshService extends SSHService {
  LegacySshService({super.taskClient});

  Future<Map<String, dynamic>> checkServerLegacy({
    required String host,
    int port = 22,
    required String username,
    String? password,
    String? privateKey,
    void Function(Map<String, dynamic> event)? onEvent,
    void Function(int taskId)? onTaskStarted,
  }) async => const <String, dynamic>{'status': 'success'};

  Future<Map<String, dynamic>> runWorkflowLegacy({
    required String workflowId,
    required String operationId,
    Map<String, dynamic>? connection,
    Map<String, dynamic>? params,
    void Function(Map<String, dynamic> event)? onEvent,
    void Function(int taskId)? onTaskStarted,
    bool serializePerHost = true,
  }) async => const <String, dynamic>{'status': 'success'};

  Future<bool> cancelTaskLegacy(int taskId) async => false;

  Future<List<EngineTaskHistoryEntry>> getRecentTaskHistoryLegacy({
    int limit = 50,
  }) async => const <EngineTaskHistoryEntry>[];

  @override
  Future<Result<Map<String, dynamic>>> checkServer({
    required String host,
    int port = 22,
    required String username,
    String? password,
    String? privateKey,
    void Function(Map<String, dynamic> event)? onEvent,
    void Function(int taskId)? onTaskStarted,
  }) async => Ok<Map<String, dynamic>>(
    await checkServerLegacy(
      host: host,
      port: port,
      username: username,
      password: password,
      privateKey: privateKey,
      onEvent: onEvent,
      onTaskStarted: onTaskStarted,
    ),
  );

  @override
  Future<Result<Map<String, dynamic>>> runWorkflow({
    required String workflowId,
    required String operationId,
    Map<String, dynamic>? connection,
    Map<String, dynamic>? params,
    void Function(Map<String, dynamic> event)? onEvent,
    void Function(int taskId)? onTaskStarted,
    bool serializePerHost = true,
  }) async => Ok<Map<String, dynamic>>(
    await runWorkflowLegacy(
      workflowId: workflowId,
      operationId: operationId,
      connection: connection,
      params: params,
      onEvent: onEvent,
      onTaskStarted: onTaskStarted,
      serializePerHost: serializePerHost,
    ),
  );

  @override
  Future<Result<bool>> cancelTask(int taskId) async =>
      Ok<bool>(await cancelTaskLegacy(taskId));

  @override
  Future<Result<List<EngineTaskHistoryEntry>>> getRecentTaskHistory({
    int limit = 50,
  }) async => Ok<List<EngineTaskHistoryEntry>>(
    await getRecentTaskHistoryLegacy(limit: limit),
  );
}
