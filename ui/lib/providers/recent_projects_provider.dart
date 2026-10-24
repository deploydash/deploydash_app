import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

import '../data/local/project_screen_visit_repository.dart';
import '../models/project_destination.dart';
import 'project_provider.dart';
import 'server_list_provider.dart';

/// One recently visited screen inside a project.
class RecentProjectScreen {
  const RecentProjectScreen({
    required this.destinationId,
    required this.label,
    required this.visitedAt,
  });

  final String destinationId;
  final String label;
  final DateTime visitedAt;
}

/// A project with its recently visited screens, sorted canonically.
class RecentProjectGroup {
  const RecentProjectGroup({
    required this.projectId,
    required this.projectName,
    required this.screens,
    this.serverId,
    this.serverName,
    this.showServerName = false,
  });

  final String projectId;
  final String projectName;
  final List<RecentProjectScreen> screens;
  final String? serverId;
  final String? serverName;

  /// Whether the server name must be shown to keep this project unambiguous.
  final bool showServerName;

  DateTime get lastVisitedAt {
    if (screens.isEmpty) {
      return DateTime.fromMillisecondsSinceEpoch(0);
    }
    return screens
        .map((s) => s.visitedAt)
        .reduce((a, b) => a.isAfter(b) ? a : b);
  }
}

/// Groups visits into recent project entries where:
/// - Projects are ordered descending by their newest visit.
/// - Sub-screens within each project are sorted in canonical tab order.
/// - The initial list is bounded so the total visible sub-screens <= [maxTotalSubscreens].
List<RecentProjectGroup> groupRecentProjectVisits(
  List<ProjectScreenVisitRecord> visits, {
  required Map<String, String> serverNamesById,
  int? maxTotalSubscreens,
  int? screenLimit,
}) {
  final effectiveLimit = maxTotalSubscreens ?? screenLimit ?? 10;
  if (effectiveLimit <= 0 || visits.isEmpty) {
    return const <RecentProjectGroup>[];
  }

  // Group visits by projectId
  final visitsByProject = <String, List<ProjectScreenVisitRecord>>{};
  final latestVisitByProject = <String, ProjectScreenVisitRecord>{};

  for (final visit in visits) {
    final projectId = visit.projectId.trim();
    if (projectId.isEmpty) continue;
    visitsByProject
        .putIfAbsent(projectId, () => <ProjectScreenVisitRecord>[])
        .add(visit);

    final currentLatest = latestVisitByProject[projectId];
    if (currentLatest == null ||
        visit.visitedAt.isAfter(currentLatest.visitedAt)) {
      latestVisitByProject[projectId] = visit;
    }
  }

  // Sort unique projects descending by their most recent visit. Sorting the
  // entries rather than the keys hands each comparison the value it needs, so
  // there is no lookup to assert on.
  final sortedProjects = latestVisitByProject.entries.toList()
    ..sort((a, b) => b.value.visitedAt.compareTo(a.value.visitedAt));

  final resultGroups = <RecentProjectGroup>[];
  var accumulatedScreens = 0;

  for (final entry in sortedProjects) {
    final projectId = entry.key;
    final latestVisit = entry.value;
    // Both maps gained this id in the same iteration of the loop above.
    final projectVisits =
        visitsByProject[projectId] ?? const <ProjectScreenVisitRecord>[];

    // Deduplicate screens per project, keeping newest visitedAt
    final screensByDest = <String, RecentProjectScreen>{};
    for (final v in projectVisits) {
      final destId = v.destinationId.trim();
      if (destId.isEmpty) continue;
      final existing = screensByDest[destId];
      if (existing == null || v.visitedAt.isAfter(existing.visitedAt)) {
        screensByDest[destId] = RecentProjectScreen(
          destinationId: destId,
          label: projectDestinationOrDefault(destId).label,
          visitedAt: v.visitedAt,
        );
      }
    }

    // Sort screens canonically based on workspace tab order
    final canonicalScreens = screensByDest.values.toList()
      ..sort((a, b) {
        final indexA = projectDestinationIndex(a.destinationId) ?? 999;
        final indexB = projectDestinationIndex(b.destinationId) ?? 999;
        if (indexA != indexB) {
          return indexA.compareTo(indexB);
        }
        return a.destinationId.compareTo(b.destinationId);
      });

    if (canonicalScreens.isEmpty) continue;

    // Check subscreen budget
    if (accumulatedScreens + canonicalScreens.length <= effectiveLimit) {
      resultGroups.add(
        RecentProjectGroup(
          projectId: projectId,
          projectName: latestVisit.projectName,
          serverId: latestVisit.serverId,
          serverName: latestVisit.serverId == null
              ? null
              : serverNamesById[latestVisit.serverId],
          screens: canonicalScreens,
        ),
      );
      accumulatedScreens += canonicalScreens.length;
    } else {
      if (accumulatedScreens == 0) {
        // Include at least the first project, sliced to fit within limit
        final slicedScreens = canonicalScreens.take(effectiveLimit).toList();
        resultGroups.add(
          RecentProjectGroup(
            projectId: projectId,
            projectName: latestVisit.projectName,
            serverId: latestVisit.serverId,
            serverName: latestVisit.serverId == null
                ? null
                : serverNamesById[latestVisit.serverId],
            screens: slicedScreens,
          ),
        );
        accumulatedScreens += slicedScreens.length;
      }
      break;
    }
  }

  // Resolve duplicate project name disambiguation
  final nameCounts = <String, int>{};
  for (final group in resultGroups) {
    nameCounts[group.projectName] = (nameCounts[group.projectName] ?? 0) + 1;
  }

  return [
    for (final group in resultGroups)
      RecentProjectGroup(
        projectId: group.projectId,
        projectName: group.projectName,
        serverId: group.serverId,
        serverName: group.serverName,
        showServerName: (nameCounts[group.projectName] ?? 0) > 1,
        screens: group.screens,
      ),
  ];
}

/// Maintains the session-stable recent project groups and raw visits in memory.
class RecentProjectVisitsNotifier extends Notifier<List<RecentProjectGroup>> {
  bool _didInitialize = false;
  List<ProjectScreenVisitRecord> _rawVisits =
      const <ProjectScreenVisitRecord>[];

  @override
  List<RecentProjectGroup> build() {
    if (!_didInitialize) {
      _didInitialize = true;
      scheduleMicrotask(refresh);
    }
    return const <RecentProjectGroup>[];
  }

  List<ProjectScreenVisitRecord> get rawVisits => _rawVisits;

  /// Loads initial recent visits from database and builds the initial 10-subscreen snapshot.
  Future<void> refresh() async {
    if (!ref.mounted) {
      return;
    }
    List<ProjectScreenVisitRecord> visits;
    try {
      visits = await ref
          .read(projectScreenVisitRepositoryProvider)
          .listRecentVisits();
    } on sqlite.SqliteException {
      visits = const <ProjectScreenVisitRecord>[];
    } on StateError {
      // A disposed local store has no recents to restore for this session.
      visits = const <ProjectScreenVisitRecord>[];
    }
    if (!ref.mounted) {
      return;
    }
    _rawVisits = visits;
    final serverNamesById = <String, String>{
      for (final server in ref.read(serverListProvider)) server.id: server.name,
    };
    state = groupRecentProjectVisits(
      visits,
      serverNamesById: serverNamesById,
      maxTotalSubscreens: 10,
    );
  }

  /// Records a visit with session spatial stability:
  /// - Persists visit to the database.
  /// - If the project is already in recents, keeps its position and inserts/sorts the screen canonically.
  /// - If the project is not in recents, prepends it to the top (Soft Session Growth).
  Future<void> recordVisit({
    required String projectId,
    required String destinationId,
    String? projectName,
    String? serverId,
  }) async {
    final normalizedProjectId = projectId.trim();
    final normalizedDestId = destinationId.trim();
    if (normalizedProjectId.isEmpty || normalizedDestId.isEmpty) {
      return;
    }

    try {
      await ref
          .read(projectScreenVisitRepositoryProvider)
          .recordVisit(
            projectId: normalizedProjectId,
            destinationId: normalizedDestId,
          );
    } on sqlite.SqliteException {
      // Do not add an in-memory visit that would disappear on restart.
      return;
    } on StateError {
      // Do not add an in-memory visit after the local store is disposed.
      return;
    }

    if (!ref.mounted) {
      return;
    }

    final now = DateTime.now().toUtc();
    final resolvedProjectName =
        projectName ?? _resolveProjectName(normalizedProjectId);
    final resolvedServerId = serverId ?? _resolveServerId(normalizedProjectId);

    final newVisit = ProjectScreenVisitRecord(
      projectId: normalizedProjectId,
      destinationId: normalizedDestId,
      visitedAt: now,
      projectName: resolvedProjectName,
      serverId: resolvedServerId,
    );

    _rawVisits = [
      newVisit,
      ..._rawVisits.where(
        (v) =>
            !(v.projectId == normalizedProjectId &&
                v.destinationId == normalizedDestId),
      ),
    ];

    final existingIndex = state.indexWhere(
      (g) => g.projectId == normalizedProjectId,
    );

    if (existingIndex >= 0) {
      final existingGroup = state[existingIndex];
      final alreadyHasScreen = existingGroup.screens.any(
        (s) => s.destinationId == normalizedDestId,
      );

      if (alreadyHasScreen) {
        // Zero list/screen movement while working in the same tab
        return;
      }

      // Unhide the new screen in its canonical slot without shifting the project
      final newScreen = RecentProjectScreen(
        destinationId: normalizedDestId,
        label: projectDestinationOrDefault(normalizedDestId).label,
        visitedAt: now,
      );

      final updatedScreens = [...existingGroup.screens, newScreen]
        ..sort((a, b) {
          final indexA = projectDestinationIndex(a.destinationId) ?? 999;
          final indexB = projectDestinationIndex(b.destinationId) ?? 999;
          if (indexA != indexB) return indexA.compareTo(indexB);
          return a.destinationId.compareTo(b.destinationId);
        });

      final updatedGroup = RecentProjectGroup(
        projectId: existingGroup.projectId,
        projectName: existingGroup.projectName,
        serverId: existingGroup.serverId,
        serverName: existingGroup.serverName,
        showServerName: existingGroup.showServerName,
        screens: updatedScreens,
      );

      final nextState = [...state];
      nextState[existingIndex] = updatedGroup;
      state = nextState;
    } else {
      // Prepend new project to the top
      final serverNamesById = <String, String>{
        for (final server in ref.read(serverListProvider))
          server.id: server.name,
      };
      final resolvedServerName = resolvedServerId == null
          ? null
          : serverNamesById[resolvedServerId];

      final newGroup = RecentProjectGroup(
        projectId: normalizedProjectId,
        projectName: resolvedProjectName,
        serverId: resolvedServerId,
        serverName: resolvedServerName,
        showServerName: false,
        screens: [
          RecentProjectScreen(
            destinationId: normalizedDestId,
            label: projectDestinationOrDefault(normalizedDestId).label,
            visitedAt: now,
          ),
        ],
      );

      final nextGroups = [newGroup, ...state];
      final nameCounts = <String, int>{};
      for (final g in nextGroups) {
        nameCounts[g.projectName] = (nameCounts[g.projectName] ?? 0) + 1;
      }

      state = [
        for (final g in nextGroups)
          RecentProjectGroup(
            projectId: g.projectId,
            projectName: g.projectName,
            serverId: g.serverId,
            serverName: g.serverName,
            showServerName: (nameCounts[g.projectName] ?? 0) > 1,
            screens: g.screens,
          ),
      ];
    }
  }

  void removeProject(String projectId) {
    state = state.where((g) => g.projectId != projectId).toList();
    _rawVisits = _rawVisits.where((v) => v.projectId != projectId).toList();
  }

  String _resolveProjectName(String projectId) {
    for (final group in state) {
      if (group.projectId == projectId) return group.projectName;
    }
    for (final v in _rawVisits) {
      if (v.projectId == projectId) return v.projectName;
    }
    // Neither source above can know about a project on its very first visit:
    // `state` is empty until this call adds it, and `_rawVisits` was loaded
    // once when this provider was built, before the project existed. Every
    // real caller (workspace_shell.dart, main.dart) omits `projectName` and
    // relies on this method, so without this the rail would show the
    // literal fallback below for a brand-new project's entire first
    // session -- caught by a live checklist run, not by the unit tests,
    // which always passed projectName explicitly.
    for (final project in ref.read(projectListProvider)) {
      if (project.id == projectId) return project.name;
    }
    return 'Project';
  }

  String? _resolveServerId(String projectId) {
    for (final group in state) {
      if (group.projectId == projectId) return group.serverId;
    }
    for (final v in _rawVisits) {
      if (v.projectId == projectId) return v.serverId;
    }
    for (final project in ref.read(projectListProvider)) {
      if (project.id == projectId) return project.serverId;
    }
    return null;
  }
}

final recentProjectVisitsProvider =
    NotifierProvider<RecentProjectVisitsNotifier, List<RecentProjectGroup>>(
      RecentProjectVisitsNotifier.new,
    );

final recentProjectGroupsProvider = Provider<List<RecentProjectGroup>>((ref) {
  return ref.watch(recentProjectVisitsProvider);
});

/// Resolves the screen a project was last left on, defaulting to the web app
/// screen for projects that have never been opened.
final lastVisitedDestinationProvider = Provider<String Function(String)>((ref) {
  ref.watch(recentProjectVisitsProvider);
  return (String projectId) {
    final notifier = ref.read(recentProjectVisitsProvider.notifier);
    final rawVisits = notifier.rawVisits;

    ProjectScreenVisitRecord? newest;
    for (final visit in rawVisits) {
      if (visit.projectId != projectId) {
        continue;
      }
      if (newest == null || visit.visitedAt.isAfter(newest.visitedAt)) {
        newest = visit;
      }
    }
    final destinationId = newest?.destinationId;
    if (destinationId == null ||
        projectDestinationIndex(destinationId) == null) {
      return defaultProjectDestinationId;
    }
    return destinationId;
  };
});
