import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/pending_enrollment_provider.dart';
import '../../providers/server_provider.dart';
import '../../services/app_analytics_service.dart';
import '../../services/ssh_service.dart';
import '../server/server_onboarding_view.dart';

/// Hosts the onboarding wizard before the passphrase exists.
///
/// Fresh installs open here instead of on the database create screen: the
/// wizard runs intro, credentials, and confirmation above the passphrase
/// scope, with an SSH service that has no recovery database (checks never
/// snapshot) and writes nothing. Finish opens the create-password modal,
/// which hands the checked pair plus the secret to [onEnrollmentRequired]:
/// the startup gate enrolls it and unlocks, or reports failure for the
/// modal to show next to the fields.
class PreEnrollmentOnboardingHost extends StatelessWidget {
  const PreEnrollmentOnboardingHost({
    super.key,
    required this.onEnrollmentRequired,
    required this.onRestoreRequest,
    this.serverNotifierFactory,
  });

  final Future<EnrollmentResult> Function(
    ServerDraft draft,
    Map<String, dynamic> checkResult,
    String passphrase,
  )
  onEnrollmentRequired;

  /// Opens the restore screen from the wizard's intro step, the only
  /// step that offers restore.
  final VoidCallback onRestoreRequest;

  /// Test-only seam replacing the transient check/run state.
  final ServerNotifier Function()? serverNotifierFactory;

  @override
  Widget build(BuildContext context) {
    return ProviderScope(
      overrides: [
        sshServiceProvider.overrideWith((ref) {
          final service = SSHService(
            recoveryDatabase: null,
            housekeepingInterval: const Duration(seconds: 15),
            analyticsService: ref.watch(appAnalyticsServiceProvider),
          );
          ref.onDispose(service.dispose);
          return service;
        }),
        if (serverNotifierFactory case final factory?)
          serverProvider.overrideWith(factory),
      ],
      child: ServerOnboardingView(
        firstRun: true,
        onSavePendingServer: (draft, result) {
          throw StateError(
            'Pre-enrollment save is unreachable: Finish setup enrolls first.',
          );
        },
        onUpdatePendingServer:
            ({required serverId, required draft, required checkResult}) {
              throw StateError(
                'Pre-enrollment update is unreachable: nothing is saved yet.',
              );
            },
        onAdoptManagedIdentity:
            ({
              required serverId,
              required sshUser,
              required authMethod,
              privateKey,
              publicKey,
              managedUserPassword,
            }) async {
              throw StateError(
                'Pre-enrollment handoff is unreachable: setup runs enrolled.',
              );
            },
        onEnrollmentRequired: onEnrollmentRequired,
        onRestoreRequest: onRestoreRequest,
      ),
    );
  }
}
