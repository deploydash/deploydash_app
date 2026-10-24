import 'dart:convert';

import '../utils/sensitive_data_sanitizer.dart';

/// The maximum number of ordered diagnostic lines accepted from the engine.
const deployFailureEvidenceMaxLines = 12;

/// The UTF-8 budget for diagnostic line text joined with newline separators.
const deployFailureEvidenceMaxEncodedLineBytes = 6 * 1024;

/// The additive engine-envelope field owned by this decoder.
const deployFailureEvidenceEnvelopeField = 'failure_evidence';
const _failureEvidenceSchemaVersion = 1;
const _failureEvidenceFields = <String>{
  'schema_version',
  'phase',
  'source',
  'completeness',
  'lines',
  'failed_step_id',
  'failed_action_id',
  'probe',
};
const _probeFields = <String>{'path', 'curl_exit', 'http_status'};

/// The stable deployment phase at which the engine stopped.
enum DeployFailurePhase {
  /// Request preparation before repository or runtime work.
  prepare,

  /// Repository clone, fetch, checkout, or deploy-key access.
  repositorySync,

  /// Image or application build work.
  build,

  /// Candidate web or worker process startup.
  candidateStart,

  /// Candidate-local readiness verification.
  candidateReadiness,

  /// Proxy configuration or route activation.
  trafficSwitch,

  /// Routed health verification after cutover.
  postCutoverStabilization,

  /// Release or route rollback work.
  rollback,

  /// Engine execution before a more specific phase was available.
  engine,

  /// A future or unrecognized phase value.
  unknown,
}

/// Where the engine obtained the bounded failure evidence.
enum DeployFailureSource {
  /// Output emitted by the named operation that failed.
  failedOperation,

  /// Runtime output collected from the candidate process.
  candidateRuntime,

  /// Safe status facts from a candidate-local probe.
  candidateProbe,

  /// Safe status facts from a routed public probe.
  routedProbe,

  /// A caught exception before command output was available.
  exception,

  /// No diagnostic source could be recovered.
  none,

  /// A future or unrecognized source value.
  unknown,
}

/// How much useful evidence the engine recovered for a failed deployment.
enum DeployFailureCompleteness {
  /// At least one diagnostic line or safe probe fact is present.
  diagnostic,

  /// The failed boundary is known but it returned no diagnostic output.
  boundaryOnly,

  /// Execution ended before a reliable failure boundary could be recovered.
  unavailable,

  /// A future or unrecognized completeness value.
  unknown,
}

/// Exposes the contract-owned phase spelling to non-payload consumers.
extension DeployFailurePhaseStorage on DeployFailurePhase {
  /// Keeps analytics and audit metadata aligned with the engine envelope.
  String get storageKey => switch (this) {
    DeployFailurePhase.prepare => 'prepare',
    DeployFailurePhase.repositorySync => 'repository_sync',
    DeployFailurePhase.build => 'build',
    DeployFailurePhase.candidateStart => 'candidate_start',
    DeployFailurePhase.candidateReadiness => 'candidate_readiness',
    DeployFailurePhase.trafficSwitch => 'traffic_switch',
    DeployFailurePhase.postCutoverStabilization => 'post_cutover_stabilization',
    DeployFailurePhase.rollback => 'rollback',
    DeployFailurePhase.engine => 'engine',
    DeployFailurePhase.unknown => 'unknown',
  };
}

/// Exposes the contract-owned evidence-source spelling to safe consumers.
extension DeployFailureSourceStorage on DeployFailureSource {
  /// Prevents analytics and audit layers from inventing a second mapping.
  String get storageKey => switch (this) {
    DeployFailureSource.failedOperation => 'failed_operation',
    DeployFailureSource.candidateRuntime => 'candidate_runtime',
    DeployFailureSource.candidateProbe => 'candidate_probe',
    DeployFailureSource.routedProbe => 'routed_probe',
    DeployFailureSource.exception => 'exception',
    DeployFailureSource.none => 'none',
    DeployFailureSource.unknown => 'unknown',
  };
}

/// Exposes the contract-owned completeness spelling to safe consumers.
extension DeployFailureCompletenessStorage on DeployFailureCompleteness {
  /// Makes the model the sole owner of completeness serialization.
  String get storageKey => switch (this) {
    DeployFailureCompleteness.diagnostic => 'diagnostic',
    DeployFailureCompleteness.boundaryOnly => 'boundary_only',
    DeployFailureCompleteness.unavailable => 'unavailable',
    DeployFailureCompleteness.unknown => 'unknown',
  };
}

/// Safe, body-free facts from one HTTP readiness probe.
final class DeployFailureProbe {
  /// Creates probe facts already validated at the engine-envelope boundary.
  const DeployFailureProbe({this.path, this.curlExit, this.httpStatus});

  /// The attempted HTTP path, when the engine reported one.
  final String? path;

  /// The curl process exit code, constrained to one unsigned byte.
  final int? curlExit;

  /// The returned HTTP status between 100 and 599.
  final int? httpStatus;

  /// Decodes only the three safe probe facts; response bodies are rejected.
  static DeployFailureProbe? fromPayload(Object? payload) {
    if (payload is! Map || payload.isEmpty) {
      return null;
    }
    if (payload.keys.any((key) => key is! String) ||
        payload.keys.any((key) => !_probeFields.contains(key))) {
      return null;
    }

    final rawPath = payload['path'];
    if (rawPath != null &&
        (rawPath is! String || !rawPath.trim().startsWith('/'))) {
      return null;
    }
    final rawCurlExit = payload['curl_exit'];
    if (rawCurlExit != null &&
        (rawCurlExit is! int || rawCurlExit < 0 || rawCurlExit > 255)) {
      return null;
    }
    final rawHttpStatus = payload['http_status'];
    if (rawHttpStatus != null &&
        (rawHttpStatus is! int || rawHttpStatus < 100 || rawHttpStatus > 599)) {
      return null;
    }

    return DeployFailureProbe(
      path: rawPath == null
          ? null
          : sanitizeSensitiveText(rawPath as String).trim(),
      curlExit: rawCurlExit as int?,
      httpStatus: rawHttpStatus as int?,
    );
  }

  /// Serializes only safe probe facts, never a response body.
  Map<String, dynamic> toPayload() => <String, dynamic>{
    ...?path == null ? null : <String, dynamic>{'path': path},
    ...?curlExit == null ? null : <String, dynamic>{'curl_exit': curlExit},
    ...?httpStatus == null
        ? null
        : <String, dynamic>{'http_status': httpStatus},
  };

  @override
  bool operator ==(Object other) =>
      other is DeployFailureProbe &&
      other.path == path &&
      other.curlExit == curlExit &&
      other.httpStatus == httpStatus;

  @override
  int get hashCode => Object.hash(path, curlExit, httpStatus);
}

/// A bounded, sanitized excerpt attached additively to an engine error.
final class DeployFailureEvidence {
  /// Creates evidence already validated by [fromPayload].
  DeployFailureEvidence({
    required this.phase,
    required this.source,
    required this.completeness,
    required List<String> lines,
    this.failedStepId,
    this.failedActionId,
    this.probe,
  }) : lines = List<String>.unmodifiable(lines);

  /// The stable deployment phase that stopped.
  final DeployFailurePhase phase;

  /// Where the diagnostic information originated.
  final DeployFailureSource source;

  /// Whether diagnostic, boundary-only, or no evidence was recovered.
  final DeployFailureCompleteness completeness;

  /// Ordered, non-empty diagnostic lines within the contract limits.
  final List<String> lines;

  /// The workflow step identifier, when the backend had one.
  final String? failedStepId;

  /// The named action identifier, when the backend had one.
  final String? failedActionId;

  /// Safe HTTP probe facts without a response body.
  final DeployFailureProbe? probe;

  /// Reads the additive member from an engine envelope through this one owner.
  static DeployFailureEvidence? fromEnvelope(Map<String, dynamic> envelope) =>
      fromPayload(envelope[deployFailureEvidenceEnvelopeField]);

  /// Tolerantly decodes version one or returns null for malformed/future data.
  static DeployFailureEvidence? fromPayload(Object? payload) {
    if (payload is! Map ||
        payload.length != _failureEvidenceFields.length ||
        !_failureEvidenceFields.every(payload.containsKey)) {
      return null;
    }
    if (payload['schema_version'] is! int ||
        payload['schema_version'] != _failureEvidenceSchemaVersion) {
      return null;
    }

    final rawPhase = payload['phase'];
    final rawSource = payload['source'];
    final rawCompleteness = payload['completeness'];
    final rawLines = payload['lines'];
    if (rawPhase is! String ||
        rawSource is! String ||
        rawCompleteness is! String ||
        rawLines is! List ||
        rawLines.length > deployFailureEvidenceMaxLines ||
        rawLines.any((line) => line is! String || line.trim().isEmpty)) {
      return null;
    }
    final lines = List<String>.unmodifiable(
      rawLines.cast<String>().map(sanitizeSensitiveText),
    );
    if (lines.any((line) => line.isEmpty)) {
      return null;
    }
    if (utf8.encode(lines.join('\n')).length >
        deployFailureEvidenceMaxEncodedLineBytes) {
      return null;
    }

    final rawStepId = payload['failed_step_id'];
    final rawActionId = payload['failed_action_id'];
    if ((rawStepId != null &&
            (rawStepId is! String || rawStepId.trim().isEmpty)) ||
        (rawActionId != null &&
            (rawActionId is! String || rawActionId.trim().isEmpty))) {
      return null;
    }

    final rawProbe = payload['probe'];
    final probe = DeployFailureProbe.fromPayload(rawProbe);
    if (rawProbe != null && probe == null) {
      return null;
    }

    final phase = switch (rawPhase) {
      'prepare' => DeployFailurePhase.prepare,
      'repository_sync' => DeployFailurePhase.repositorySync,
      'build' => DeployFailurePhase.build,
      'candidate_start' => DeployFailurePhase.candidateStart,
      'candidate_readiness' => DeployFailurePhase.candidateReadiness,
      'traffic_switch' => DeployFailurePhase.trafficSwitch,
      'post_cutover_stabilization' =>
        DeployFailurePhase.postCutoverStabilization,
      'rollback' => DeployFailurePhase.rollback,
      'engine' => DeployFailurePhase.engine,
      _ => DeployFailurePhase.unknown,
    };
    final source = switch (rawSource) {
      'failed_operation' => DeployFailureSource.failedOperation,
      'candidate_runtime' => DeployFailureSource.candidateRuntime,
      'candidate_probe' => DeployFailureSource.candidateProbe,
      'routed_probe' => DeployFailureSource.routedProbe,
      'exception' => DeployFailureSource.exception,
      'none' => DeployFailureSource.none,
      _ => DeployFailureSource.unknown,
    };
    final completeness = switch (rawCompleteness) {
      'diagnostic' => DeployFailureCompleteness.diagnostic,
      'boundary_only' => DeployFailureCompleteness.boundaryOnly,
      'unavailable' => DeployFailureCompleteness.unavailable,
      _ => DeployFailureCompleteness.unknown,
    };
    if (completeness == DeployFailureCompleteness.diagnostic) {
      if (lines.isEmpty && probe == null) {
        return null;
      }
    } else if (completeness != DeployFailureCompleteness.unknown &&
        (lines.isNotEmpty || probe != null)) {
      return null;
    }

    return DeployFailureEvidence(
      phase: phase,
      source: source,
      completeness: completeness,
      lines: lines,
      failedStepId: rawStepId == null
          ? null
          : sanitizeSensitiveText(rawStepId as String).trim(),
      failedActionId: rawActionId == null
          ? null
          : sanitizeSensitiveText(rawActionId as String).trim(),
      probe: probe,
    );
  }

  /// Rebuilds the exact version-one wire shape from the typed value.
  Map<String, dynamic> toPayload() => <String, dynamic>{
    'schema_version': _failureEvidenceSchemaVersion,
    'phase': phase.storageKey,
    'source': source.storageKey,
    'completeness': completeness.storageKey,
    'lines': lines,
    'failed_step_id': failedStepId,
    'failed_action_id': failedActionId,
    'probe': probe?.toPayload(),
  };

  /// Returns the optional envelope member without exposing its wire key.
  static Map<String, dynamic> envelopeMember(DeployFailureEvidence? evidence) =>
      evidence == null
      ? const <String, dynamic>{}
      : <String, dynamic>{
          deployFailureEvidenceEnvelopeField: evidence.toPayload(),
        };

  /// Compares the immutable ordered lines without depending on list identity.
  bool _hasSameLines(DeployFailureEvidence other) {
    if (lines.length != other.lines.length) {
      return false;
    }
    for (var index = 0; index < lines.length; index += 1) {
      if (lines[index] != other.lines[index]) {
        return false;
      }
    }
    return true;
  }

  @override
  bool operator ==(Object other) =>
      other is DeployFailureEvidence &&
      other.phase == phase &&
      other.source == source &&
      other.completeness == completeness &&
      _hasSameLines(other) &&
      other.failedStepId == failedStepId &&
      other.failedActionId == failedActionId &&
      other.probe == probe;

  @override
  int get hashCode => Object.hash(
    phase,
    source,
    completeness,
    Object.hashAll(lines),
    failedStepId,
    failedActionId,
    probe,
  );
}
