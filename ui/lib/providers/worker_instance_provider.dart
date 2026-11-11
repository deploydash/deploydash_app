import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/local/worker_instance_repository.dart';

class ProjectWorkerInstance {
  const ProjectWorkerInstance({
    required this.id,
    required this.projectId,
    required this.name,
    required this.startCommand,
    this.cpuLimit = 0.5,
    this.memoryMb = 256,
    this.diskMb = 1024,
    this.environment = const <String, String>{},
    this.enabled = true,
    this.sortOrder = 0,
  });

  final String id;
  final String projectId;
  final String name;
  final String startCommand;
  final double cpuLimit;
  final int memoryMb;
  final int diskMb;

  /// Extra variables injected into the worker container, insertion-ordered.
  /// Empty means none.
  final Map<String, String> environment;
  final bool enabled;
  final int sortOrder;

  ProjectWorkerInstance copyWith({
    String? id,
    String? projectId,
    String? name,
    String? startCommand,
    double? cpuLimit,
    int? memoryMb,
    int? diskMb,
    Map<String, String>? environment,
    bool? enabled,
    int? sortOrder,
  }) {
    return ProjectWorkerInstance(
      id: id ?? this.id,
      projectId: projectId ?? this.projectId,
      name: name ?? this.name,
      startCommand: startCommand ?? this.startCommand,
      cpuLimit: cpuLimit ?? this.cpuLimit,
      memoryMb: memoryMb ?? this.memoryMb,
      diskMb: diskMb ?? this.diskMb,
      environment: environment ?? this.environment,
      enabled: enabled ?? this.enabled,
      sortOrder: sortOrder ?? this.sortOrder,
    );
  }
}

class ProjectWorkerInstancesNotifier
    extends Notifier<Map<String, List<ProjectWorkerInstance>>> {
  @override
  Map<String, List<ProjectWorkerInstance>> build() => const {};

  List<ProjectWorkerInstance> workersForProject(String projectId) {
    final normalizedProjectId = projectId.trim();
    if (normalizedProjectId.isEmpty) {
      return const [];
    }
    return state[normalizedProjectId] ?? const [];
  }

  Future<void> loadProject(String projectId) async {
    final normalizedProjectId = projectId.trim();
    if (normalizedProjectId.isEmpty) {
      return;
    }

    final records = await ref
        .read(workerInstanceRepositoryProvider)
        .listForProject(normalizedProjectId);
    if (!ref.mounted) {
      return;
    }

    state = {
      ...state,
      normalizedProjectId: records
          .map(_workerFromRecord)
          .toList(growable: false),
    };
  }

  Future<void> replaceProject(
    String projectId,
    List<ProjectWorkerInstance> workers,
  ) async {
    final normalizedProjectId = projectId.trim();
    if (normalizedProjectId.isEmpty) {
      return;
    }

    final normalizedWorkers = workers
        .where((worker) => worker.id.trim().isNotEmpty)
        .toList(growable: false);

    state = {...state, normalizedProjectId: normalizedWorkers};

    await ref
        .read(workerInstanceRepositoryProvider)
        .replaceForProject(
          projectId: normalizedProjectId,
          rows: normalizedWorkers
              .map(_recordFromWorker)
              .toList(growable: false),
        );
  }

  void forgetProject(String projectId) {
    final normalizedProjectId = projectId.trim();
    if (normalizedProjectId.isEmpty ||
        !state.containsKey(normalizedProjectId)) {
      return;
    }
    final nextState = Map<String, List<ProjectWorkerInstance>>.from(state);
    nextState.remove(normalizedProjectId);
    state = nextState;
  }

  /// The fields the worker mappers copy, in mapper order.
  ///
  /// Why a list, not shared code (D-83 verdict): the two mirror mappers
  /// construct different types, and Dart constructors cannot route through a
  /// list -- so the set is declared once HERE and enforced by the round-trip
  /// test (every listed field, both directions, values and nulls) plus a
  /// length pin below. Adding a field means extending this list, both
  /// mappers, and the test sentinels together. A type merge was rejected:
  /// D-22 (which co-owns the question) is undecided, the record lives in
  /// data/local while the instance carries providers-layer editing
  /// semantics, and sharing either direction inverts the layering the
  /// layering test pins.
  static const workerFieldNames = <String>[
    'id',
    'projectId',
    'name',
    'startCommand',
    'cpuLimit',
    'memoryMb',
    'diskMb',
    'environment',
    'enabled',
    'sortOrder',
  ];

  static ProjectWorkerInstance _workerFromRecord(WorkerInstanceRecord record) {
    return ProjectWorkerInstance(
      id: record.id,
      projectId: record.projectId,
      name: record.name,
      startCommand: record.startCommand,
      cpuLimit: record.cpuLimit,
      memoryMb: record.memoryMb,
      diskMb: record.diskMb,
      environment: Map<String, String>.of(record.environment),
      enabled: record.enabled,
      sortOrder: record.sortOrder,
    );
  }

  static WorkerInstanceRecord _recordFromWorker(ProjectWorkerInstance worker) {
    return WorkerInstanceRecord(
      id: worker.id,
      projectId: worker.projectId,
      name: worker.name,
      startCommand: worker.startCommand,
      cpuLimit: worker.cpuLimit,
      memoryMb: worker.memoryMb,
      diskMb: worker.diskMb,
      environment: Map<String, String>.of(worker.environment),
      enabled: worker.enabled,
      sortOrder: worker.sortOrder,
    );
  }
}

final projectWorkerInstancesProvider =
    NotifierProvider<
      ProjectWorkerInstancesNotifier,
      Map<String, List<ProjectWorkerInstance>>
    >(ProjectWorkerInstancesNotifier.new);
