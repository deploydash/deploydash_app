import 'package:ui/models/engine_failure_mapper.dart';
import 'package:ui/models/deploy_failure_evidence.dart';
import 'package:ui/models/result.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('mapEngineErrorToFailure', () {
    // Every distinct `ENGINE_*` error code literal that appears anywhere in
    // orchestrator/src as of this test's writing (grepped, not guessed --
    // see the T-2.3.2 evidence comment in the plan for the exact command).
    // A code missing from this list is a code with no mapping test, which
    // is exactly what "Done when: every code in the engine has a mapping
    // test" forbids.
    const knownEngineErrorCodes = <String>[
      'ENGINE_AUTH_FAILED',
      'ENGINE_DEPENDENCY_ERROR',
      'ENGINE_FACTS_FAILED',
      'ENGINE_INVALID_JSON',
      'ENGINE_LAYOUT_MIGRATION_REQUIRED',
      'ENGINE_LAYOUT_TOO_NEW',
      'ENGINE_LAYOUT_UNREADABLE',
      'ENGINE_LAYOUT_UNVERSIONED',
      'ENGINE_NOT_IMPLEMENTED',
      'ENGINE_OPERATION_FAILED',
      'ENGINE_PROTOCOL_TOO_NEW',
      'ENGINE_RUNTIME_ERROR',
      'ENGINE_RUNTIME_NOT_CONFIGURED',
      'ENGINE_UNKNOWN_ACTION',
      'ENGINE_VALIDATION_ERROR',
    ];

    for (final code in knownEngineErrorCodes) {
      test('$code maps to an EngineFailure preserving the full envelope', () {
        final failure = mapEngineErrorToFailure(<String, dynamic>{
          'status': 'error',
          'code': code,
          'msg': 'A $code message.',
          'stage': 'some_stage',
          'details': 'some details',
        });

        expect(
          failure,
          const TypeMatcher<EngineFailure>()
              .having((f) => f.code, 'code', code)
              .having((f) => f.msg, 'msg', 'A $code message.')
              .having((f) => f.stage, 'stage', 'some_stage')
              .having((f) => f.details, 'details', 'some details')
              .having((f) => f.context, 'context', isEmpty),
        );
      });
    }

    for (final code in [
      'ENGINE_TASK_CANCELLED',
      'ENGINE_TASK_CANCELLED_FORCED',
    ]) {
      test(
        '$code maps to CancelledFailure, distinct from every EngineFailure',
        () {
          final failure = mapEngineErrorToFailure(<String, dynamic>{
            'status': 'error',
            'code': code,
            'msg': 'Task cancelled.',
          });

          expect(failure, const CancelledFailure());
        },
      );
    }

    test(
      'an unrecognized code maps to a generic EngineFailure preserving it',
      () {
        final failure = mapEngineErrorToFailure(<String, dynamic>{
          'status': 'error',
          'code': 'ENGINE_SOME_FUTURE_CODE_NOT_YET_KNOWN',
          'msg': 'Something new happened.',
        });

        expect(
          failure,
          const TypeMatcher<EngineFailure>()
              .having(
                (f) => f.code,
                'code',
                'ENGINE_SOME_FUTURE_CODE_NOT_YET_KNOWN',
              )
              .having((f) => f.msg, 'msg', 'Something new happened.'),
        );
      },
    );

    for (final code in <String>[
      'ENGINE_OPERATION_FAILED',
      'ENGINE_SOME_FUTURE_CODE_NOT_YET_KNOWN',
    ]) {
      test('$code preserves valid evidence as typed context', () {
        final failure = mapEngineErrorToFailure(<String, dynamic>{
          'status': 'error',
          'code': code,
          'msg': 'Build failed.',
          'failure_evidence': <String, dynamic>{
            'schema_version': 1,
            'phase': 'build',
            'source': 'failed_operation',
            'completeness': 'diagnostic',
            'lines': <String>['compiler error'],
            'failed_step_id': 'app_release',
            'failed_action_id': 'build_release_image',
            'probe': null,
          },
        });

        expect(
          failure,
          const TypeMatcher<EngineFailure>()
              .having(
                (f) => f.failureEvidence?.phase,
                'evidence phase',
                DeployFailurePhase.build,
              )
              .having(
                (f) => f.failureEvidence?.lines,
                'evidence lines',
                <String>['compiler error'],
              )
              .having(
                (f) => f.context.containsKey('failure_evidence'),
                'untyped evidence context',
                isFalse,
              ),
        );
      });
    }

    test('malformed and future evidence preserves the standard failure', () {
      for (final evidence in <Object?>[
        'not-an-object',
        <String, dynamic>{'schema_version': 2},
      ]) {
        final failure = mapEngineErrorToFailure(<String, dynamic>{
          'status': 'error',
          'code': 'ENGINE_OPERATION_FAILED',
          'msg': 'Build failed.',
          'details': 'Open the full log.',
          'failure_evidence': evidence,
        });

        expect(
          failure,
          const TypeMatcher<EngineFailure>()
              .having((f) => f.msg, 'msg', 'Build failed.')
              .having((f) => f.details, 'details', 'Open the full log.')
              .having((f) => f.failureEvidence, 'failure evidence', isNull),
        );
      }
    });

    test('stage and details are null when the envelope omits them', () {
      final failure = mapEngineErrorToFailure(<String, dynamic>{
        'status': 'error',
        'code': 'ENGINE_RUNTIME_ERROR',
        'msg': 'boom',
      });

      expect(
        failure,
        const TypeMatcher<EngineFailure>()
            .having((f) => f.stage, 'stage', isNull)
            .having((f) => f.details, 'details', isNull),
      );
    });

    test('preserves structured recovery context outside the raw envelope', () {
      final failure = mapEngineErrorToFailure(<String, dynamic>{
        'status': 'error',
        'code': 'ENGINE_AUTH_FAILED',
        'msg': 'The SSH host key changed.',
        'host_key_confirmation_required': true,
        'host_key_mismatch': <String, dynamic>{
          'old_fingerprint': 'SHA256:old',
          'new_fingerprint': 'SHA256:new',
        },
      });

      expect(
        failure,
        const TypeMatcher<EngineFailure>()
            .having(
              (f) => f.context['host_key_confirmation_required'],
              'confirmation requirement',
              isTrue,
            )
            .having(
              (f) => f.context['host_key_mismatch'],
              'host key mismatch',
              <String, dynamic>{
                'old_fingerprint': 'SHA256:old',
                'new_fingerprint': 'SHA256:new',
              },
            ),
      );
    });

    test('a missing code falls back to an empty string, not a crash', () {
      final failure = mapEngineErrorToFailure(<String, dynamic>{
        'status': 'error',
        'msg': 'No code at all.',
      });

      expect(
        failure,
        const TypeMatcher<EngineFailure>().having((f) => f.code, 'code', ''),
      );
    });

    test('a missing msg falls back to an empty string, not a crash', () {
      final failure = mapEngineErrorToFailure(<String, dynamic>{
        'status': 'error',
        'code': 'ENGINE_RUNTIME_ERROR',
      });

      expect(
        failure,
        const TypeMatcher<EngineFailure>().having((f) => f.msg, 'msg', ''),
      );
    });
  });
}
