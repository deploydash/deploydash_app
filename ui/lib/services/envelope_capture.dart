import 'dart:convert';
import 'dart:io';

import 'sensitive_data_sanitizer.dart';

/// Records outgoing engine request envelopes for the T-0.5 corpus.
///
/// TEMPORARY. This exists only to build the frozen envelope corpus that
/// T-1.5.3 derives `params_schema` shapes from and T-1.5.5 replays as a
/// regression test. Delete this file, its call site in [SshService.runTaskStream],
/// and the dart-define once `qa/fixtures/envelopes/` is populated.
///
/// It is off unless `DEPLOYDASH_E2E_CAPTURE_ENVELOPES` is set at compile time,
/// so a production build cannot write anything: the const is folded to an
/// empty string and [isEnabled] is false.
const String _captureDirectory = String.fromEnvironment(
  'DEPLOYDASH_E2E_CAPTURE_ENVELOPES',
);

/// Whether envelope capture was compiled into this build.
bool get envelopeCaptureEnabled => _captureDirectory.isNotEmpty;

/// Writes one sanitized envelope, named for the operation it invokes.
///
/// Credentials are removed by [sanitizeSensitivePayloadMap] before anything
/// touches the disk, so the corpus can be committed. One file per
/// (workflow_id, operation_id) pair, or per legacy `action`; a repeat
/// overwrites, which keeps the corpus one example per operation rather than a
/// transcript.
void captureRequestEnvelope(Map<String, dynamic> payload) {
  if (!envelopeCaptureEnabled) {
    return;
  }
  try {
    final sanitized = sanitizeSensitivePayloadMap(payload);
    final action = sanitized['action']?.toString() ?? 'unknown';
    final String name;
    if (action == 'run_workflow') {
      final workflow = sanitized['workflow_id']?.toString() ?? 'unknown';
      final operation = sanitized['operation_id']?.toString() ?? 'unknown';
      name = '$workflow.$operation';
    } else {
      name = action;
    }
    final safeName = name.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    final directory = Directory(_captureDirectory);
    directory.createSync(recursive: true);
    File('${directory.path}/$safeName.json').writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(sanitized)}\n',
    );
  } on Object {
    // Capture is diagnostic scaffolding for one QA run. It must never be able
    // to fail an operation that would otherwise have succeeded.
  }
}
