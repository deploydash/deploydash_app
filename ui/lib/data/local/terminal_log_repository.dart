import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../utils/sensitive_data_sanitizer.dart';
import '../../utils/trim_or_null.dart';
import 'app_database.dart';

/// One line of engine output kept for the terminal view.
///
/// Persisted rather than held in memory so a user can still read what happened
/// during a deploy after closing and reopening the app -- which is exactly when
/// they go looking, because something went wrong.
class TerminalLogRecord {
  /// Records one line.
  const TerminalLogRecord({
    required this.id,
    this.projectId,
    this.serverId,
    this.serverLabel,
    required this.message,
    required this.renderedLine,
    required this.source,
    this.taskType,
    required this.createdAt,
  });

  /// Autoincrement row id.
  final int id;

  /// The project this line belongs to, when it belongs to one.
  final String? projectId;

  /// The server this line belongs to, when it belongs to one.
  final String? serverId;

  /// The server's name at the time, so an old line still reads sensibly after
  /// the server is renamed or removed.
  final String? serverLabel;

  /// The raw message.
  final String message;

  /// The message as it should appear, prefixes and formatting included.
  ///
  /// Stored alongside [message] rather than re-derived, so replaying an old log
  /// shows what the user actually saw, not what today's formatter would print.
  final String renderedLine;

  /// Where the line came from. `terminal` when unspecified.
  final String source;

  /// Which kind of operation produced it, used to replay one operation's
  /// output on its own.
  final String? taskType;

  /// When the line was produced.
  final DateTime createdAt;
}

/// Stores and replays terminal output.
///
/// Every read returns oldest-first: rows are selected newest-first so the
/// limit keeps the *recent* lines, then reversed so they read in the order they
/// happened.
class TerminalLogRepository {
  /// Creates the repository over the app database.
  const TerminalLogRepository(this._database);

  final AppDatabase _database;

  /// Appends one line, ignoring a blank message or rendered line.
  Future<void> appendLog({
    required String message,
    required String renderedLine,
    String? serverLabel,
    String? projectId,
    String? serverId,
    String source = 'terminal',
    String? taskType,
    DateTime? createdAt,
  }) async {
    final companion = _logCompanion(
      message: message,
      renderedLine: renderedLine,
      serverLabel: serverLabel,
      projectId: projectId,
      serverId: serverId,
      source: source,
      taskType: taskType,
      createdAt: createdAt ?? DateTime.now(),
    );
    if (companion == null) {
      return;
    }
    await _database.into(_database.terminalLogs).insert(companion);
  }

  // coverage-gate: terminal_evidence_batch
  /// Appends one timestamped batch at most once across live and restart paths.
  Future<void> appendLogBatchOnce({
    required List<({String message, String renderedLine})> lines,
    required String projectId,
    required String serverId,
    required String serverLabel,
    required String source,
    required String taskType,
    required DateTime createdAt,
  }) async {
    final normalizedProjectId = trimOrNull(projectId);
    final normalizedServerId = trimOrNull(serverId);
    final normalizedSource = source.trim().isEmpty ? 'terminal' : source.trim();
    final normalizedTaskType = trimOrNull(taskType);
    if (normalizedProjectId == null ||
        normalizedServerId == null ||
        normalizedTaskType == null) {
      return;
    }
    final companions = lines
        .map(
          (line) => _logCompanion(
            message: line.message,
            renderedLine: line.renderedLine,
            serverLabel: serverLabel,
            projectId: normalizedProjectId,
            serverId: normalizedServerId,
            source: normalizedSource,
            taskType: normalizedTaskType,
            createdAt: createdAt,
          ),
        )
        .whereType<TerminalLogsCompanion>()
        .toList(growable: false);
    if (companions.isEmpty) {
      return;
    }

    await _database.transaction(() async {
      final existing =
          await (_database.select(_database.terminalLogs)
                ..where(
                  (table) =>
                      table.projectId.equals(normalizedProjectId) &
                      table.serverId.equals(normalizedServerId) &
                      table.source.equals(normalizedSource) &
                      table.taskType.equals(normalizedTaskType) &
                      table.createdAt.equals(createdAt),
                )
                ..limit(1))
              .getSingleOrNull();
      if (existing != null) {
        return;
      }
      for (final companion in companions) {
        await _database.into(_database.terminalLogs).insert(companion);
      }
    });
  }
  // end coverage-gate

  /// Normalizes and sanitizes one row before any Terminal persistence path.
  TerminalLogsCompanion? _logCompanion({
    required String message,
    required String renderedLine,
    required String? serverLabel,
    required String? projectId,
    required String? serverId,
    required String source,
    required String? taskType,
    required DateTime createdAt,
  }) {
    // coverage-gate: terminal_persistence_sanitization
    final normalizedMessage = sanitizeSensitiveText(message).trim();
    final normalizedRenderedLine = sanitizeSensitiveText(renderedLine).trim();
    if (normalizedMessage.isEmpty || normalizedRenderedLine.isEmpty) {
      return null;
    }
    // end coverage-gate
    return TerminalLogsCompanion.insert(
      message: normalizedMessage,
      renderedLine: normalizedRenderedLine,
      projectId: Value(trimOrNull(projectId)),
      serverId: Value(trimOrNull(serverId)),
      serverLabel: Value(trimOrNull(serverLabel)),
      source: Value(source.trim().isEmpty ? 'terminal' : source.trim()),
      taskType: Value(trimOrNull(taskType)),
      createdAt: Value(createdAt),
    );
  }

  /// Recent lines for one kind of operation, oldest first, optionally scoped
  /// to a project and server.
  Future<List<TerminalLogRecord>> listRecentLogsForTaskType({
    required String taskType,
    String? projectId,
    String? serverId,
    int limit = 200,
  }) => _listRecent(
    taskType: taskType,
    projectId: projectId,
    serverId: serverId,
    limit: limit,
  );

  /// The most recent lines across everything, oldest first.
  Future<List<TerminalLogRecord>> listRecentLogs({int limit = 500}) =>
      _listRecent(limit: limit);

  /// Recent lines for one project on one server, oldest first.
  ///
  /// Requires both: a project id alone would mix in output from a time the
  /// project was on a different server.
  Future<List<TerminalLogRecord>> listRecentLogsForScope({
    required String projectId,
    required String serverId,
    int limit = 500,
  }) => _listRecent(
    projectId: projectId,
    serverId: serverId,
    requireScope: true,
    limit: limit,
  );

  /// Lists recent log lines, oldest first.
  ///
  /// Why: the three recent-logs lists share the order/limit/get/reversed tail
  /// and differ only in filter head and limit default; one owner keeps the
  /// "newest-first query, oldest-first result" contract in one place.
  /// `taskType` null means unfiltered; `requireScope` reproduces the scope
  /// list's both-required guard (false keeps the filter's lenient per-field
  /// behavior); `limit` passes through raw, never clamped.
  Future<List<TerminalLogRecord>> _listRecent({
    String? taskType,
    String? projectId,
    String? serverId,
    bool requireScope = false,
    int limit = 500,
  }) async {
    final normalizedTaskType = trimOrNull(taskType);
    if (taskType != null && normalizedTaskType == null) {
      return const <TerminalLogRecord>[];
    }
    final query = _database.select(_database.terminalLogs);
    if (normalizedTaskType != null) {
      query.where((table) => table.taskType.equals(normalizedTaskType));
    }
    if (requireScope) {
      final p = trimOrNull(projectId);
      final s = trimOrNull(serverId);
      if (p == null || s == null) {
        return const <TerminalLogRecord>[];
      }
      _applyScopeFilter(query, projectId: p, serverId: s);
    } else {
      _applyScopeFilter(query, projectId: projectId, serverId: serverId);
    }
    query
      ..orderBy([(table) => OrderingTerm.desc(table.createdAt)])
      ..limit(limit);
    final rows = await query.get();
    return rows.reversed.map(_mapRow).toList(growable: false);
  }

  void _applyScopeFilter(
    SimpleSelectStatement<$TerminalLogsTable, TerminalLogRow> query, {
    String? projectId,
    String? serverId,
  }) {
    final normalizedProjectId = trimOrNull(projectId);
    final normalizedServerId = trimOrNull(serverId);
    if (normalizedProjectId != null) {
      query.where((table) => table.projectId.equals(normalizedProjectId));
    }
    if (normalizedServerId != null) {
      query.where((table) => table.serverId.equals(normalizedServerId));
    }
  }

  TerminalLogRecord _mapRow(TerminalLogRow row) {
    return TerminalLogRecord(
      id: row.id,
      projectId: row.projectId,
      serverId: row.serverId,
      serverLabel: row.serverLabel,
      message: row.message,
      renderedLine: row.renderedLine,
      source: row.source,
      taskType: row.taskType,
      createdAt: row.createdAt,
    );
  }
}

/// The app-wide terminal log repository.
final terminalLogRepositoryProvider = Provider<TerminalLogRepository>((ref) {
  final database = ref.watch(appDatabaseProvider);
  return TerminalLogRepository(database);
});
