import 'deploy_failure_evidence.dart';
import 'result.dart';

/// Backend error codes that mean "the operation was cancelled," not "the
/// operation failed." Distinct from every other engine code because
/// [AppFailure] keeps cancellation as its own kind -- see
/// `docs/contracts/engine-protocol.md`'s error-code table.
const _cancellationCodes = <String>{
  'ENGINE_TASK_CANCELLED',
  'ENGINE_TASK_CANCELLED_FORCED',
};

const _standardEnvelopeKeys = <String>{
  'status',
  'code',
  'msg',
  'stage',
  'details',
  deployFailureEvidenceEnvelopeField,
};

/// Maps an engine error envelope (`{"status": "error", "code": ...,
/// "msg": ..., "stage": ..., "details": ...}`, per
/// `docs/contracts/engine-protocol.md`) onto a typed [AppFailure].
///
/// A cancellation code maps to [CancelledFailure]. Every other code --
/// known or not -- maps to an [EngineFailure] that preserves the raw
/// `code`, `msg`, `stage`, and `details` exactly as the engine sent them,
/// so a code this mapper has never seen before still reaches the UI's
/// technical-details reveal intact instead of being discarded.
AppFailure mapEngineErrorToFailure(Map<String, dynamic> envelope) {
  final code = envelope['code']?.toString() ?? '';
  if (_cancellationCodes.contains(code)) {
    return const CancelledFailure();
  }

  return EngineFailure(
    code: code,
    msg: envelope['msg']?.toString() ?? '',
    stage: envelope['stage']?.toString(),
    details: envelope['details']?.toString(),
    failureEvidence: DeployFailureEvidence.fromEnvelope(envelope),
    context: Map<String, dynamic>.unmodifiable(<String, dynamic>{
      for (final entry in envelope.entries)
        if (!_standardEnvelopeKeys.contains(entry.key)) entry.key: entry.value,
    }),
  );
}
