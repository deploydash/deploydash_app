import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/local/server_repository.dart';

/// A confirmation-green server waiting for enrollment.
///
/// The pre-enrollment wizard hands its checked draft and check result to
/// the startup gate, which carries this value across the scope rebuild:
/// the enrolled app opens the wizard with it to save and provision. The
/// bootstrap credential rides along in memory only; it is never written
/// anywhere until the early save, and the wizard clears this the moment
/// that save lands so a remount can never save twice.
class PendingEnrollment {
  const PendingEnrollment({required this.draft, required this.checkResult});

  final ServerDraft draft;
  final Map<String, dynamic> checkResult;
}

/// The gate's answer to an in-wizard enrollment handoff.
///
/// [enrolled] carries creation success; [failureDetails] carries the
/// creation diagnostics for the wizard's inline failure, mirroring what
/// the startup create screen shows from `createFailureDetails`.
class EnrollmentResult {
  const EnrollmentResult({required this.enrolled, this.failureDetails});

  final bool enrolled;
  final String? failureDetails;
}

class PendingEnrollmentNotifier extends Notifier<PendingEnrollment?> {
  PendingEnrollmentNotifier([this._initial]);

  final PendingEnrollment? _initial;

  @override
  PendingEnrollment? build() => _initial;

  /// Drops the pending enrollment after its save lands.
  void clear() {
    state = null;
  }
}

final pendingEnrollmentProvider =
    NotifierProvider<PendingEnrollmentNotifier, PendingEnrollment?>(
      PendingEnrollmentNotifier.new,
    );

/// Whether this session unlocked through a fresh enrollment.
///
/// True only under the unlock gate's enrollment scope, which wraps the
/// app tree when a first-run passphrase enrolls. The shell reads this to
/// keep the first-run wizard mounted while its first server's setup is
/// still pending: the pending enrollment itself clears the moment the
/// early save lands, so without a session flag the shell cannot tell a
/// fresh enrollment's in-flight setup from any older incomplete server,
/// and drops the wizard to Home mid-provisioning. Defaults to false for
/// unlock, restore, and every test that does not override it.
final freshEnrollmentSessionProvider = Provider<bool>((ref) => false);
