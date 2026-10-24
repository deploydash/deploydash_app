import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_database.dart';
import '../../utils/bounded_int.dart';
import '../../utils/payload_codecs.dart';

/// One recorded action taken through Agent Access.
///
/// The user's record of what an external agent did on their behalf. Written
/// for every tool call, successful or not, because the failed attempts are as
/// much of the story as the successful ones.
class AgentAuditEntryRecord {
  /// Records one agent action.
  const AgentAuditEntryRecord({
    required this.id,
    required this.toolName,
    required this.accessLevel,
    required this.status,
    required this.summary,
    required this.details,
    required this.createdAt,
  });

  /// Autoincrement row id. Also the tiebreak that makes "recent" mean recent
  /// -- see [AgentAuditRepository.listRecent].
  final int id;

  /// Which MCP tool was called.
  final String toolName;

  /// What that tool is allowed to do -- read-only or an action.
  final String accessLevel;

  /// How the call ended, lower-cased.
  final String status;

  /// One line describing what happened, for the Agent Access list.
  final String summary;

  /// Structured detail, or null when there was none or it could not be read.
  final Map<String, dynamic>? details;

  /// When it happened. SQLite's default clock, so whole seconds.
  final DateTime createdAt;
}

/// Appends to, and reads back, the Agent Access audit trail.
class AgentAuditRepository {
  /// Creates the repository over the app database.
  const AgentAuditRepository(this._database);

  final AppDatabase _database;

  /// Records one agent action.
  ///
  /// An entry missing any of its four required fields is dropped rather than
  /// stored partially: a half-written audit line is worse than none, because
  /// it looks like a complete record of something else.
  Future<void> append({
    required String toolName,
    required String accessLevel,
    required String status,
    required String summary,
    Map<String, dynamic>? details,
  }) async {
    final normalizedToolName = toolName.trim();
    final normalizedAccessLevel = accessLevel.trim();
    final normalizedStatus = status.trim().toLowerCase();
    final normalizedSummary = summary.trim();
    if (normalizedToolName.isEmpty ||
        normalizedAccessLevel.isEmpty ||
        normalizedStatus.isEmpty ||
        normalizedSummary.isEmpty) {
      return;
    }
    await _database
        .into(_database.agentAuditEntries)
        .insert(
          AgentAuditEntriesCompanion.insert(
            toolName: normalizedToolName,
            accessLevel: normalizedAccessLevel,
            status: normalizedStatus,
            summary: normalizedSummary,
            detailsJson: Value(details == null ? null : jsonEncode(details)),
          ),
        );
  }

  /// The most recent entries, newest first.
  ///
  /// A non-positive [limit] falls back to 20 rather than returning nothing.
  Future<List<AgentAuditEntryRecord>> listRecent({int limit = 20}) async {
    final rows =
        await (_database.select(_database.agentAuditEntries)
              ..orderBy([
                (table) => OrderingTerm.desc(table.createdAt),
                // `createdAt` defaults to SQLite's `currentDateAndTime`, which
                // is whole seconds, so a burst of agent tool calls shares one
                // timestamp -- the normal case, not an edge one. Without this
                // tiebreak those rows came back in insertion order, meaning
                // the "recent actions" list showed the oldest of them first:
                // the exact reverse of what it promises. `id` is
                // autoincrement, so it is a total order agreeing with
                // insertion.
                (table) => OrderingTerm.desc(table.id),
              ])
              ..limit(boundedInt(limit, fallback: 20)))
            .get();
    return rows
        .map(
          (row) => AgentAuditEntryRecord(
            id: row.id,
            toolName: row.toolName,
            accessLevel: row.accessLevel,
            status: row.status,
            summary: row.summary,
            details: _decodeDetails(row.detailsJson),
            createdAt: row.createdAt,
          ),
        )
        .toList(growable: false);
  }

  // Swallows to null for audit-list robustness — policy differs from N1's
  // propagate; stringify step unified via mapFrom (D-45 pair 2, T-021).
  Map<String, dynamic>? _decodeDetails(String? raw) {
    if (raw == null || raw.trim().isEmpty) {
      return null;
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        return null;
      }
      return mapFrom(decoded);
    } on FormatException {
      return null;
    }
  }
}

/// The app-wide agent audit repository.
final agentAuditRepositoryProvider = Provider<AgentAuditRepository>((ref) {
  final database = ref.watch(appDatabaseProvider);
  return AgentAuditRepository(database);
});
