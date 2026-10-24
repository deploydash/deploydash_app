import 'package:ui/services/app_analytics_service.dart';
import 'package:ui/ui/server/server_onboarding_view_logic.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('onboarding intro steps and labels stay novice friendly', () {
    expect(onboardingIntroSteps(), <String>[
      'Add the server details Deploy Dash needs to connect.',
      'Review the server and confirm it is ready.',
      'Choose the services you want to install.',
      'Finish setup and add secure Deploy Dash access.',
    ]);
    expect(
      onboardingCheckConnectionLabel(isLoading: false),
      'Check connection',
    );
    expect(
      onboardingCheckConnectionLabel(isLoading: true),
      'Checking connection...',
    );
    expect(
      onboardingConnectionErrorHeadline(hostKeyMismatch: true),
      'This server looks different than before.',
    );
    expect(
      onboardingConnectionErrorHeadline(hostKeyMismatch: false),
      'Couldn’t connect to this server.',
    );
  });

  test('onboarding compatibility and finish labels explain next steps', () {
    expect(onboardingCompatibilityHeading(), 'What we’ll check');
    expect(
      onboardingCompatibilityHint(
        compatibilityPassed: true,
        summary: 'Everything passed.',
      ),
      'Everything looks ready. You can finish setup now.',
    );
    expect(
      onboardingCompatibilityHint(
        compatibilityPassed: false,
        summary: 'Install updates first.',
      ),
      'Install updates first.',
    );
    expect(onboardingFinishButtonLabel(isSaving: false), 'Finish setup');
    expect(onboardingFinishButtonLabel(isSaving: true), 'Finishing setup...');
    expect(
      onboardingFinishBlockedMessage(),
      'Finish setup becomes available after these checks pass.',
    );
  });

  test('setup progress copy separates running and failed states', () {
    expect(
      onboardingSetupProgressTitle(isRunning: true, hasError: false),
      'Setting up server',
    );
    expect(
      onboardingSetupProgressTitle(isRunning: false, hasError: true),
      'Setup needs attention',
    );
    expect(
      onboardingSetupProgressDescription(isRunning: true, hasError: false),
      'Deploy Dash is applying the secure server baseline. Keep this window open while setup runs.',
    );
    expect(
      onboardingSetupProgressDescription(isRunning: false, hasError: true),
      'Fix the issue below, then retry setup from this screen.',
    );
  });

  test('setup failure summary turns infrastructure failures into actions', () {
    expect(
      onboardingSetupFailureSummary(
        error:
            'apt update failed: Temporary failure resolving archive.ubuntu.com',
      ),
      'The server could not reach a required package or download source. Check DNS, outbound HTTPS, proxy, or firewall rules, then retry setup.',
    );
    expect(
      onboardingSetupFailureSummary(error: 'sudo password is required'),
      'Deploy Dash could not keep administrator access while setting up the server. Check the saved sign-in details, then retry setup.',
    );
    expect(
      onboardingSetupFailureSummary(error: 'No space left on device'),
      'The server does not have enough usable disk space to finish setup. Free space or choose a larger server, then retry.',
    );
    expect(
      onboardingSetupFailureSummary(error: 'Docker service failed to start'),
      'Docker service failed to start',
    );
    expect(
      onboardingSetupFailureSummary(),
      'Setup stopped before the server was fully configured. Review the details below, fix the issue, then retry.',
    );
  });

  group('layout version errors', () {
    // The server records which on-disk layout produced it (T-1.1.5/T-1.1.6).
    // These three codes are the only way a user learns that Deploy Dash and
    // the server disagree about that, so the copy has to say what happened
    // and what to do, without showing the code in the primary message.
    test('a server set up by a newer Deploy Dash asks the user to update', () {
      final summary = onboardingSetupFailureSummary(
        errorPayload: const <String, dynamic>{
          'code': 'ENGINE_LAYOUT_TOO_NEW',
          'msg': 'raw backend wording that should not reach the user',
        },
      );

      expect(summary, contains('newer version of Deploy Dash'));
      expect(summary.toLowerCase(), contains('update deploy dash'));
      expect(summary, isNot(contains('ENGINE_LAYOUT_TOO_NEW')));
      expect(summary, isNot(contains('raw backend wording')));
    });

    test('a pre-versioning server explains it cannot be managed yet', () {
      final summary = onboardingSetupFailureSummary(
        errorPayload: const <String, dynamic>{
          'code': 'ENGINE_LAYOUT_UNVERSIONED',
          'msg': 'raw backend wording',
        },
      );

      expect(summary.toLowerCase(), contains('earlier version of deploy dash'));
      expect(summary, isNot(contains('ENGINE_LAYOUT_UNVERSIONED')));
    });

    test('an older layout says it needs upgrading before it can be used', () {
      final summary = onboardingSetupFailureSummary(
        errorPayload: const <String, dynamic>{
          'code': 'ENGINE_LAYOUT_MIGRATION_REQUIRED',
          'msg': 'raw backend wording',
        },
      );

      expect(summary.toLowerCase(), contains('upgrade'));
      expect(summary, isNot(contains('ENGINE_LAYOUT_MIGRATION_REQUIRED')));
    });

    test('an unreadable layout check points at the connection', () {
      final summary = onboardingSetupFailureSummary(
        errorPayload: const <String, dynamic>{
          'code': 'ENGINE_LAYOUT_UNREADABLE',
          'msg': 'raw backend wording',
        },
      );

      expect(summary.toLowerCase(), contains('could not check'));
      expect(summary, isNot(contains('ENGINE_LAYOUT_UNREADABLE')));
    });

    test('the code wins over the message text', () {
      // The message here would match the existing package-source string
      // heuristic. A code is authoritative; a substring match is a guess,
      // and the guess must not win.
      final summary = onboardingSetupFailureSummary(
        errorPayload: const <String, dynamic>{
          'code': 'ENGINE_LAYOUT_TOO_NEW',
          'msg': 'could not resolve archive.ubuntu.com',
        },
      );

      expect(summary, contains('newer version of Deploy Dash'));
      expect(summary, isNot(contains('package')));
    });

    test('an unrelated code still falls through to the message heuristics', () {
      final summary = onboardingSetupFailureSummary(
        errorPayload: const <String, dynamic>{
          'code': 'ENGINE_VALIDATION_ERROR',
          'msg': 'could not resolve archive.ubuntu.com',
        },
      );

      expect(summary, contains('package'));
    });
  });

  group('a failed SSH hardening rollback', () {
    // I-6b in docs/contracts/onboarding-invariants.md. The worst outcome
    // onboarding can produce: an sshd option applied, the managed login
    // unverified, and the restore that should have undone it also failed.
    // Every other summary on this screen ends by telling the user to retry.
    test('tells the user not to retry, and where to recover from', () {
      final summary = onboardingSetupFailureSummary(
        errorPayload: const <String, dynamic>{
          'code': 'ENGINE_SSH_HARDENING_ROLLBACK_FAILED',
          'msg': 'raw backend wording that should not reach the user',
        },
      );

      expect(summary.toLowerCase(), contains('do not retry'));
      expect(summary.toLowerCase(), contains('console'));
      expect(summary, isNot(contains('ENGINE_SSH_HARDENING_ROLLBACK_FAILED')));
      expect(summary, isNot(contains('raw backend wording')));
    });

    test('is not downgraded into the ordinary sign-in advice', () {
      // The backend message for this failure is about a connection that
      // could not be verified, which is one word away from the strings the
      // administrator-access heuristic matches on. That heuristic ends with
      // "then retry setup" -- exactly the advice this failure must not give.
      final summary = onboardingSetupFailureSummary(
        errorPayload: const <String, dynamic>{
          'code': 'ENGINE_SSH_HARDENING_ROLLBACK_FAILED',
          'msg': 'permission denied (publickey) after sudo sshd restart',
        },
      );

      expect(summary.toLowerCase(), contains('do not retry'));
      expect(summary, isNot(contains('saved sign-in details')));
    });
  });

  group('setup failure step mapping', () {
    // The funnel reports the checkpoint a setup run failed at, but only
    // where the backend names it by code. A code is a statement; matching on
    // message text or guessing a stage would be a guess, and unmappable
    // failures report nothing rather than a wrong step.
    test('the SSH hardening rollback failure maps to its checkpoint', () {
      expect(
        onboardingFailedStepForCode('ENGINE_SSH_HARDENING_ROLLBACK_FAILED'),
        OnboardingStep.sshHardened,
      );
    });

    test('layout failures map to the earliest checkpoint', () {
      for (final code in <String>[
        'ENGINE_LAYOUT_TOO_NEW',
        'ENGINE_LAYOUT_UNVERSIONED',
        'ENGINE_LAYOUT_MIGRATION_REQUIRED',
        'ENGINE_LAYOUT_UNREADABLE',
      ]) {
        expect(
          onboardingFailedStepForCode(code),
          OnboardingStep.bootstrap,
          reason: code,
        );
      }
    });

    test('generic failures map to no checkpoint', () {
      for (final code in <String?>[
        null,
        '',
        '   ',
        'ENGINE_VALIDATION_ERROR',
        'ENGINE_RUNTIME_ERROR',
        'ENGINE_DEPENDENCY_ERROR',
        'ENGINE_TASK_CANCELLED',
        'ENGINE_SOMETHING_NEW',
      ]) {
        expect(onboardingFailedStepForCode(code), isNull, reason: '$code');
      }
    });
  });
}
