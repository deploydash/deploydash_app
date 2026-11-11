import '../../../../providers/worker_instance_provider.dart';

/// The worker tab's pure logic: the values it edits, and the rule that names a
/// new worker.
///
/// Extracted by T-3.3.6. These were private types inside a `part` of
/// `project_workspace.dart`, so the only way to exercise `WorkerDraft`'s
/// round trip to and from a persisted `ProjectWorkerInstance` -- or the
/// de-duplicating id rule -- was to pump the whole workspace widget. They are
/// public here for the same reason the file exists: so a test can construct
/// one and assert on it.

/// The parsed content of the worker environment box: the valid entries
/// before the first problem, plus that problem described with its line
/// number (null when the whole box parses).
class WorkerEnvironmentParseResult {
  const WorkerEnvironmentParseResult({
    required this.variables,
    required this.error,
  });

  final Map<String, String> variables;
  final String? error;
}

/// Parses one `KEY=VALUE` per line into an insertion-ordered map.
///
/// Blank lines and full-line `#` comments are ignored. Keys must look
/// like `DATABASE_URL` (letters, digits, underscores, never starting
/// with a digit); values keep everything after the first `=` verbatim
/// except surrounding whitespace and one pair of matching outer quotes.
/// A `#` inside a value is literal: unlike dotenv there are no inline
/// comments, so a password containing one can never be silently cut.
/// A repeated key fails rather than picking a winner.
WorkerEnvironmentParseResult parseWorkerEnvironmentVariables(String raw) {
  final variables = <String, String>{};
  final lines = raw.split('\n');
  for (var index = 0; index < lines.length; index++) {
    final lineNumber = index + 1;
    final trimmed = lines[index].trim();
    if (trimmed.isEmpty || trimmed.startsWith('#')) {
      continue;
    }
    final equals = trimmed.indexOf('=');
    if (equals < 0) {
      return WorkerEnvironmentParseResult(
        variables: variables,
        error: 'Line $lineNumber: write KEY=value (one variable per line).',
      );
    }
    final key = trimmed.substring(0, equals).trim();
    if (!RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(key)) {
      return WorkerEnvironmentParseResult(
        variables: variables,
        error:
            'Line $lineNumber: ‘$key’ is not a valid variable name '
            '(letters, digits and underscores; must not start with a digit).',
      );
    }
    if (variables.containsKey(key)) {
      return WorkerEnvironmentParseResult(
        variables: variables,
        error: 'Line $lineNumber: ‘$key’ is set twice.',
      );
    }
    var value = trimmed.substring(equals + 1).trim();
    if (value.length >= 2 &&
        (value.startsWith("'") && value.endsWith("'") ||
            value.startsWith('"') && value.endsWith('"'))) {
      value = value.substring(1, value.length - 1);
    }
    variables[key] = value;
  }
  return WorkerEnvironmentParseResult(variables: variables, error: null);
}

/// Renders an environment map back to editor text, round-tripping exactly.
///
/// Values that would change under [parseWorkerEnvironmentVariables] -- padded
/// with whitespace, or wrapped in literal quote characters -- are wrapped in
/// double quotes, which the parser strips as its one pair.
String renderWorkerEnvironment(Map<String, String> environment) {
  return environment.entries
      .map((entry) {
        final value = entry.value;
        final padded = value.trim() != value;
        final quoted =
            value.length >= 2 &&
            ((value.startsWith("'") && value.endsWith("'")) ||
                (value.startsWith('"') && value.endsWith('"')));
        final rendered = padded || quoted ? '"$value"' : value;
        return '${entry.key}=$rendered';
      })
      .join('\n');
}

class WorkerDraft {
  const WorkerDraft({
    required this.id,
    required this.name,
    required this.startCommand,
    required this.cpuLimit,
    required this.memoryMb,
    required this.diskMb,
    this.environment = const <String, String>{},
    this.enabled = true,
  });

  final String id;
  final String name;
  final String startCommand;
  final double cpuLimit;
  final int memoryMb;
  final int diskMb;

  /// Extra variables injected into the worker container (`KEY=VALUE` from
  /// the editor, insertion-ordered). Empty means none.
  final Map<String, String> environment;
  final bool enabled;

  WorkerDraft copyWith({
    String? id,
    String? name,
    String? startCommand,
    double? cpuLimit,
    int? memoryMb,
    int? diskMb,
    Map<String, String>? environment,
    required bool enabled,
  }) {
    return WorkerDraft(
      id: id ?? this.id,
      name: name ?? this.name,
      startCommand: startCommand ?? this.startCommand,
      cpuLimit: cpuLimit ?? this.cpuLimit,
      memoryMb: memoryMb ?? this.memoryMb,
      diskMb: diskMb ?? this.diskMb,
      environment: environment ?? this.environment,
      enabled: enabled,
    );
  }

  ProjectWorkerInstance toWorkerInstance({
    required String projectId,
    required int sortOrder,
  }) {
    return ProjectWorkerInstance(
      id: id,
      projectId: projectId,
      name: name,
      startCommand: startCommand,
      cpuLimit: cpuLimit,
      memoryMb: memoryMb,
      diskMb: diskMb,
      environment: Map<String, String>.of(environment),
      enabled: enabled,
      sortOrder: sortOrder,
    );
  }

  static WorkerDraft fromWorker(ProjectWorkerInstance worker) {
    return WorkerDraft(
      id: worker.id,
      name: worker.name,
      startCommand: worker.startCommand,
      cpuLimit: worker.cpuLimit,
      memoryMb: worker.memoryMb,
      diskMb: worker.diskMb,
      environment: Map<String, String>.of(worker.environment),
      enabled: worker.enabled,
    );
  }
}

/// A worker id derived from [name], unique against [existingIds].
///
/// The id is what addresses the worker's container on the server, so it is
/// slugified and then suffixed until it does not collide. A blank name falls
/// back to `worker` rather than producing an empty id.
String nextWorkerId(String name, Set<String> existingIds) {
  final base = name
      .trim()
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  final candidateBase = base.isEmpty ? 'worker' : base;
  var candidate = candidateBase;
  var counter = 2;
  while (existingIds.contains(candidate)) {
    candidate = '$candidateBase-$counter';
    counter += 1;
  }
  return candidate;
}
