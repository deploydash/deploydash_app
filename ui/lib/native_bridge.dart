import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

import 'services/process_security_diagnostics.dart';

export 'services/process_security_diagnostics.dart';

typedef StartPyinfraTaskC = Pointer<Utf8> Function(Pointer<Utf8> jsonPayload);
typedef StartPyinfraTaskDart =
    Pointer<Utf8> Function(Pointer<Utf8> jsonPayload);
typedef PollPyinfraTaskEventsC =
    Pointer<Utf8> Function(Int32 taskId, Int32 maxEvents);
typedef PollPyinfraTaskEventsDart =
    Pointer<Utf8> Function(int taskId, int maxEvents);
typedef GetPyinfraTaskResultC = Pointer<Utf8> Function(Int32 taskId);
typedef GetPyinfraTaskResultDart = Pointer<Utf8> Function(int taskId);
typedef CancelPyinfraTaskC = Pointer<Utf8> Function(Int32 taskId);
typedef CancelPyinfraTaskDart = Pointer<Utf8> Function(int taskId);
typedef GetRecentPyinfraTaskHistoryC = Pointer<Utf8> Function(Int32 limit);
typedef GetRecentPyinfraTaskHistoryDart = Pointer<Utf8> Function(int limit);
typedef FreeBridgeStringC = Void Function(Pointer<Utf8> value);
typedef FreeBridgeStringDart = void Function(Pointer<Utf8> value);
typedef WarmupPythonRuntimeC = Void Function();
typedef WarmupPythonRuntimeDart = void Function();
typedef SetDeployDashDataDirC = Int32 Function(Pointer<Utf8> path);
typedef SetDeployDashDataDirDart = int Function(Pointer<Utf8> path);
typedef GetBridgeRuntimeDiagnosticsC = Pointer<Utf8> Function();
typedef GetBridgeRuntimeDiagnosticsDart = Pointer<Utf8> Function();

class NativeBridgeLoadPlan {
  const NativeBridgeLoadPlan({
    required this.operatingSystem,
    required this.executableDir,
    required this.overridePath,
    required this.eagerCandidates,
    required this.fallbackCandidates,
  });

  final String operatingSystem;
  final String executableDir;
  final String? overridePath;
  final List<String> eagerCandidates;
  final List<String> fallbackCandidates;

  List<String> get allCandidates => <String>[
    ...eagerCandidates,
    ...fallbackCandidates,
  ];

  String describeAttempts(List<String> attempted) {
    if (attempted.isEmpty) {
      return 'No bridge candidates were attempted.';
    }
    return attempted.join(', ');
  }
}

class NativeBridgeRuntimeDiagnostics {
  const NativeBridgeRuntimeDiagnostics({
    required this.status,
    required this.message,
    required this.platform,
    required this.executableDir,
    required this.libpythonPath,
    required this.pythonHome,
    required this.searchPaths,
    required this.backendRuntimePresent,
    required this.processSecurity,
  });

  final String status;
  final String message;
  final String? platform;
  final String? executableDir;
  final String? libpythonPath;
  final String? pythonHome;
  final List<String> searchPaths;
  final bool? backendRuntimePresent;
  final ProcessSecurityDiagnostics? processSecurity;

  bool get isError => status == 'error';

  static NativeBridgeRuntimeDiagnostics? tryParse(String? raw) {
    if (raw == null || raw.trim().isEmpty) {
      return null;
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        return null;
      }
      final searchPathsRaw = decoded['search_paths'];
      final searchPaths = searchPathsRaw is List
          ? searchPathsRaw.whereType<String>().toList(growable: false)
          : const <String>[];
      final processSecurity = ProcessSecurityDiagnostics.tryParse(
        decoded['process_security'],
      );
      return NativeBridgeRuntimeDiagnostics(
        status: decoded['status'] as String? ?? 'unknown',
        message:
            decoded['msg'] as String? ?? 'No diagnostics message provided.',
        platform: decoded['platform'] as String?,
        executableDir: decoded['exe_dir'] as String?,
        libpythonPath: decoded['libpython_path'] as String?,
        pythonHome: decoded['python_home'] as String?,
        searchPaths: searchPaths,
        backendRuntimePresent: decoded['backend_runtime_present'] as bool?,
        processSecurity: processSecurity,
      );
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    }
  }

  String describeForError() {
    // Hoisted so the `!= null` checks promote them. These are public final
    // fields, which Dart does not promote -- only private ones are eligible.
    final platform = this.platform;
    final executableDir = this.executableDir;
    final libpythonPath = this.libpythonPath;
    final pythonHome = this.pythonHome;
    final processSecurity = this.processSecurity;
    final details = <String>[message];
    if (platform != null && platform.isNotEmpty) {
      details.add('platform=$platform');
    }
    if (executableDir != null && executableDir.isNotEmpty) {
      details.add('exe_dir=$executableDir');
    }
    if (libpythonPath != null && libpythonPath.isNotEmpty) {
      details.add('libpython=$libpythonPath');
    }
    if (pythonHome != null && pythonHome.isNotEmpty) {
      details.add('python_home=$pythonHome');
    }
    if (backendRuntimePresent != null) {
      details.add('backend_runtime_present=$backendRuntimePresent');
    }
    if (searchPaths.isNotEmpty) {
      details.add('search_paths=${searchPaths.join(':')}');
    }
    if (processSecurity != null) {
      details.add(processSecurity.describeForError());
    }
    return details.join(' | ');
  }
}

NativeBridgeLoadPlan buildNativeBridgeLoadPlan({
  required String operatingSystem,
  required String executablePath,
  required Map<String, String> environment,
}) {
  final pathContext = operatingSystem == 'windows'
      ? p.Context(style: p.Style.windows)
      : p.Context(style: p.Style.posix);
  final executableDir = pathContext.dirname(executablePath);
  final overridePath = environment['DEPLOYDASH_BRIDGE_PATH']?.trim();
  // One owner of the override mapping: null-or-empty trims down to null, a
  // real path passes through. Evaluated once for all four plan branches.
  final resolvedOverridePath = overridePath == null || overridePath.isEmpty
      ? null
      : overridePath;
  if (operatingSystem == 'linux') {
    return NativeBridgeLoadPlan(
      operatingSystem: operatingSystem,
      executableDir: executableDir,
      overridePath: resolvedOverridePath,
      eagerCandidates: const ['libbridge.so'],
      fallbackCandidates: [
        '$executableDir/libbridge.so',
        '$executableDir/lib/libbridge.so',
      ],
    );
  }
  if (operatingSystem == 'macos') {
    return NativeBridgeLoadPlan(
      operatingSystem: operatingSystem,
      executableDir: executableDir,
      overridePath: resolvedOverridePath,
      eagerCandidates: const [],
      fallbackCandidates: [
        '$executableDir/libbridge.dylib',
        '$executableDir/../Frameworks/libbridge.dylib',
        'libbridge.dylib',
        'Frameworks/libbridge.dylib',
        'ui.framework/ui',
        'process exports',
      ],
    );
  }
  if (operatingSystem == 'windows') {
    return NativeBridgeLoadPlan(
      operatingSystem: operatingSystem,
      executableDir: executableDir,
      overridePath: resolvedOverridePath,
      eagerCandidates: const [],
      fallbackCandidates: [
        '$executableDir\\bridge.dll',
        '$executableDir\\libbridge.dll',
        'process exports',
      ],
    );
  }
  return NativeBridgeLoadPlan(
    operatingSystem: operatingSystem,
    executableDir: executableDir,
    overridePath: resolvedOverridePath,
    eagerCandidates: const <String>[],
    fallbackCandidates: const <String>[],
  );
}

/// The small task-client seam supplied by the native bridge.
///
/// Keeping this separate from [NativeBridge] lets Dart-only tests exercise the
/// forwarding adapter without loading a platform dynamic library.
abstract interface class NativeBridgeTaskApi {
  String startTask(String jsonPayload);
  String pollTaskEvents(int taskId, {int maxEvents = 100});
  String getTaskResult(int taskId);
  String cancelTask(int taskId);
  String getRecentTaskHistory(int limit);
}

class NativeBridge implements NativeBridgeTaskApi {
  static final NativeBridge _instance = NativeBridge._internal();
  factory NativeBridge() => _instance;
  NativeBridge._internal();

  late DynamicLibrary _lib;
  late StartPyinfraTaskDart _startPyinfraTask;
  late PollPyinfraTaskEventsDart _pollPyinfraTaskEvents;
  late GetPyinfraTaskResultDart _getPyinfraTaskResult;
  late CancelPyinfraTaskDart _cancelPyinfraTask;
  late GetRecentPyinfraTaskHistoryDart _getRecentPyinfraTaskHistory;
  late FreeBridgeStringDart _freeBridgeString;
  late WarmupPythonRuntimeDart _warmupPythonRuntime;
  late SetDeployDashDataDirDart _setDeployDashDataDir;
  GetBridgeRuntimeDiagnosticsDart? _getBridgeRuntimeDiagnostics;

  bool _initialized = false;

  String? _readBridgeRuntimeDiagnostics() {
    final getter = _getBridgeRuntimeDiagnostics;
    if (getter == null) {
      return null;
    }
    final Pointer<Utf8> resultPtr = getter();
    final String result = resultPtr.toDartString();
    _freeBridgeString(resultPtr);
    return result;
  }

  String _composeBridgeLoadFailure({
    required NativeBridgeLoadPlan plan,
    required List<String> attempted,
    Object? lastError,
    String? bridgeDiagnostics,
    String? lookupFailure,
  }) {
    final lines = <String>[
      'Unable to load the Deploy Dash native bridge on ${plan.operatingSystem}.',
      'Executable directory: ${plan.executableDir}.',
    ];
    if (plan.overridePath != null) {
      lines.add('Override path: ${plan.overridePath}.');
    }
    lines.add('Attempted: ${plan.describeAttempts(attempted)}.');
    if (lastError != null) {
      lines.add('Last loader error: $lastError.');
    }
    if (lookupFailure != null && lookupFailure.isNotEmpty) {
      lines.add('Bridge symbol lookup failed: $lookupFailure.');
    }
    final diagnostics = NativeBridgeRuntimeDiagnostics.tryParse(
      bridgeDiagnostics,
    );
    if (diagnostics != null) {
      lines.add('Runtime diagnostics: ${diagnostics.describeForError()}.');
    } else if (bridgeDiagnostics != null &&
        bridgeDiagnostics.trim().isNotEmpty) {
      lines.add('Runtime diagnostics: ${bridgeDiagnostics.trim()}.');
    }
    return lines.join(' ');
  }

  DynamicLibrary _openBridgeLibrary() {
    final plan = buildNativeBridgeLoadPlan(
      operatingSystem: Platform.operatingSystem,
      executablePath: Platform.resolvedExecutable,
      environment: Platform.environment,
    );
    final attempted = <String>[];

    DynamicLibrary tryOpen(String label, DynamicLibrary Function() opener) {
      attempted.add(label);
      return opener();
    }

    final overridePath = plan.overridePath;
    if (overridePath != null && overridePath.isNotEmpty) {
      return tryOpen(
        'override $overridePath',
        () => DynamicLibrary.open(overridePath),
      );
    }

    for (final candidate in plan.eagerCandidates) {
      try {
        if (candidate == 'process exports') {
          return tryOpen(candidate, DynamicLibrary.process);
        }
        return tryOpen(candidate, () => DynamicLibrary.open(candidate));
      } on ArgumentError {
        // Fall through to detailed diagnostics below.
      }
    }

    Object? lastError;
    for (final candidate in plan.fallbackCandidates) {
      try {
        return tryOpen(candidate, () => DynamicLibrary.open(candidate));
      } catch (error) {
        lastError = error;
      }
    }

    throw UnsupportedError(
      _composeBridgeLoadFailure(
        plan: plan,
        attempted: attempted,
        lastError: lastError,
      ),
    );
  }

  void initialize() {
    if (_initialized) return;

    if (!Platform.isLinux && !Platform.isWindows && !Platform.isMacOS) {
      throw UnsupportedError('Platform not supported');
    }
    _lib = _openBridgeLibrary();

    final plan = buildNativeBridgeLoadPlan(
      operatingSystem: Platform.operatingSystem,
      executablePath: Platform.resolvedExecutable,
      environment: Platform.environment,
    );
    // The nine lookups stay spelled out: Dart FFI requires constant
    // type arguments (`non_constant_type_argument`), so a generic
    // lookup-then-cast helper cannot exist. Recorded-leave (D-31).
    try {
      _startPyinfraTask = _lib
          .lookup<NativeFunction<StartPyinfraTaskC>>('start_pyinfra_task')
          .asFunction();
      _pollPyinfraTaskEvents = _lib
          .lookup<NativeFunction<PollPyinfraTaskEventsC>>(
            'poll_pyinfra_task_events',
          )
          .asFunction();
      _getPyinfraTaskResult = _lib
          .lookup<NativeFunction<GetPyinfraTaskResultC>>(
            'get_pyinfra_task_result',
          )
          .asFunction();
      _cancelPyinfraTask = _lib
          .lookup<NativeFunction<CancelPyinfraTaskC>>('cancel_pyinfra_task')
          .asFunction();
      _getRecentPyinfraTaskHistory = _lib
          .lookup<NativeFunction<GetRecentPyinfraTaskHistoryC>>(
            'get_recent_pyinfra_task_history',
          )
          .asFunction();
      _freeBridgeString = _lib
          .lookup<NativeFunction<FreeBridgeStringC>>('free_bridge_string')
          .asFunction();
      _warmupPythonRuntime = _lib
          .lookup<NativeFunction<WarmupPythonRuntimeC>>('warmup_python_runtime')
          .asFunction();
      _setDeployDashDataDir = _lib
          .lookup<NativeFunction<SetDeployDashDataDirC>>(
            'set_deploydash_data_dir',
          )
          .asFunction();
      final diagnosticsSymbol = _lib
          .lookup<NativeFunction<GetBridgeRuntimeDiagnosticsC>>(
            'get_bridge_runtime_diagnostics',
          );
      _getBridgeRuntimeDiagnostics = diagnosticsSymbol.asFunction();
    } on Object catch (error) {
      throw StateError(
        _composeBridgeLoadFailure(
          plan: plan,
          attempted: plan.allCandidates,
          lookupFailure: error.toString(),
        ),
      );
    }

    _initialized = true;
  }

  @override
  String startTask(String jsonPayload) {
    if (!_initialized) initialize();

    final Pointer<Utf8> payloadPtr = jsonPayload.toNativeUtf8();
    final Pointer<Utf8> resultPtr = _startPyinfraTask(payloadPtr);
    final String result = resultPtr.toDartString();

    _freeBridgeString(resultPtr);
    malloc.free(payloadPtr);
    return result;
  }

  /// Calls a string-returning native symbol, owning init + convert + free.
  ///
  /// Why: the four string-returning FFI calls share ensure-init, UTF-8
  /// conversion, and bridge-string release; one owner keeps the free
  /// discipline (convert before free, free exactly once) from drifting per
  /// call. `invoke` performs the single native call; ownership of the
  /// returned pointer transfers here, which frees it.
  String _callString(Pointer<Utf8> Function() invoke) {
    if (!_initialized) initialize();
    final Pointer<Utf8> resultPtr = invoke();
    final String result = resultPtr.toDartString();
    _freeBridgeString(resultPtr);
    return result;
  }

  @override
  String pollTaskEvents(int taskId, {int maxEvents = 100}) {
    return _callString(() => _pollPyinfraTaskEvents(taskId, maxEvents));
  }

  @override
  String getTaskResult(int taskId) {
    return _callString(() => _getPyinfraTaskResult(taskId));
  }

  @override
  String cancelTask(int taskId) {
    return _callString(() => _cancelPyinfraTask(taskId));
  }

  @override
  String getRecentTaskHistory(int limit) {
    return _callString(() => _getRecentPyinfraTaskHistory(limit));
  }

  void setDeployDashDataDir(String path) {
    final trimmed = path.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError.value(path, 'path', 'Deploy Dash data dir is empty.');
    }
    if (!_initialized) initialize();
    final Pointer<Utf8> pathPtr = trimmed.toNativeUtf8();
    try {
      final ok = _setDeployDashDataDir(pathPtr);
      if (ok == 0) {
        throw StateError(
          'Unable to publish DEPLOYDASH_DATA_DIR for the embedded runtime.',
        );
      }
    } finally {
      malloc.free(pathPtr);
    }
  }

  void warmupPythonRuntime() {
    if (!_initialized) initialize();
    _warmupPythonRuntime();
    final diagnostics = NativeBridgeRuntimeDiagnostics.tryParse(
      _readBridgeRuntimeDiagnostics(),
    );
    if (diagnostics != null && diagnostics.isError) {
      throw StateError(
        'Deploy Dash embedded runtime warmup failed. '
        '${diagnostics.describeForError()}',
      );
    }
  }

  NativeBridgeRuntimeDiagnostics? runtimeDiagnostics() {
    if (!_initialized) initialize();
    return NativeBridgeRuntimeDiagnostics.tryParse(
      _readBridgeRuntimeDiagnostics(),
    );
  }
}
