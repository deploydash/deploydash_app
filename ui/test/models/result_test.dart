import 'package:ui/models/deploy_failure_evidence.dart';
import 'package:ui/models/result.dart';
import 'package:flutter_test/flutter_test.dart';

// Takes a `Result<int>` parameter (rather than a switch over a local
// variable initialized directly to `Ok<int>(...)`/`Err<int>(...)`) so the
// analyzer sees the general `Result<int>` type at the switch, not a
// compile-time-narrowed concrete subtype -- keeping both branches genuinely
// reachable, matching how real callers consume a `Result<T>` return value.
String _describe(Result<int> result) => switch (result) {
  Ok<int>(:final value) => 'ok:$value',
  Err<int>(:final failure) => 'err:${failure.runtimeType}',
};

void main() {
  group('Result', () {
    test('Ok carries a value and exposes it through pattern matching', () {
      const result = Ok<int>(5);

      expect(result.value, 5);
      expect(_describe(result), 'ok:5');
    });

    test('Err carries a failure and exposes it through pattern matching', () {
      const failure = ValidationFailure('bad input');
      const result = Err<int>(failure);

      expect(result.failure, failure);
      expect(_describe(result), 'err:ValidationFailure');
    });

    test('Ok equality and hashCode are value-based', () {
      expect(const Ok<int>(1), const Ok<int>(1));
      expect(const Ok<int>(1).hashCode, const Ok<int>(1).hashCode);
      expect(const Ok<int>(1), isNot(const Ok<int>(2)));
      // ignore: unrelated_type_equality_checks
      expect(const Ok<int>(1) == const Err<int>(CancelledFailure()), isFalse);
    });

    test('Err equality and hashCode are value-based', () {
      const a = Err<int>(ValidationFailure('bad input'));
      const b = Err<int>(ValidationFailure('bad input'));
      const c = Err<int>(ValidationFailure('other'));

      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(c));
    });

    test('Ok and Err have distinguishable toString output', () {
      expect(const Ok<int>(1).toString(), 'Ok(1)');
      expect(
        const Err<int>(CancelledFailure()).toString(),
        'Err(CancelledFailure())',
      );
    });
  });

  group('AppFailure', () {
    test('EngineFailure carries the full backend error envelope', () {
      const failure = EngineFailure(
        code: 'ENGINE_VALIDATION_ERROR',
        msg: 'params.settings.database_name is required.',
        stage: 'validate_request',
        details: null,
      );

      expect(failure.code, 'ENGINE_VALIDATION_ERROR');
      expect(failure.msg, 'params.settings.database_name is required.');
      expect(failure.stage, 'validate_request');
      expect(failure.details, isNull);
    });

    test('EngineFailure stage and details are optional', () {
      const failure = EngineFailure(
        code: 'ENGINE_RUNTIME_ERROR',
        msg: 'The handler raised an unhandled exception.',
      );

      expect(failure.stage, isNull);
      expect(failure.details, isNull);
    });

    test('EngineFailure equality and toString are value-based', () {
      const a = EngineFailure(
        code: 'ENGINE_RUNTIME_ERROR',
        msg: 'boom',
        stage: 'execute_runtime_operation',
        details: 'traceback',
      );
      const b = EngineFailure(
        code: 'ENGINE_RUNTIME_ERROR',
        msg: 'boom',
        stage: 'execute_runtime_operation',
        details: 'traceback',
      );
      const c = EngineFailure(code: 'ENGINE_RUNTIME_ERROR', msg: 'other');

      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(c));
      expect(
        a.toString(),
        'EngineFailure(code: ENGINE_RUNTIME_ERROR, msg: boom, '
        'stage: execute_runtime_operation, details: traceback)',
      );
    });

    test('ConnectionFailure carries a message', () {
      const failure = ConnectionFailure('Could not connect to the server.');

      expect(failure.message, 'Could not connect to the server.');
      expect(
        failure.toString(),
        'ConnectionFailure(Could not connect to the server.)',
      );
    });

    test('ConnectionFailure equality is value-based', () {
      expect(const ConnectionFailure('same'), const ConnectionFailure('same'));
      expect(
        const ConnectionFailure('same').hashCode,
        const ConnectionFailure('same').hashCode,
      );
      expect(
        const ConnectionFailure('same'),
        isNot(const ConnectionFailure('different')),
      );
    });

    test('ValidationFailure carries a message', () {
      const failure = ValidationFailure('Server name is required.');

      expect(failure.message, 'Server name is required.');
      expect(failure.toString(), 'ValidationFailure(Server name is required.)');
    });

    test('ValidationFailure equality is value-based', () {
      expect(const ValidationFailure('same'), const ValidationFailure('same'));
      expect(
        const ValidationFailure('same').hashCode,
        const ValidationFailure('same').hashCode,
      );
      expect(
        const ValidationFailure('same'),
        isNot(const ValidationFailure('different')),
      );
    });

    test('LocalStorageFailure carries a message', () {
      const failure = LocalStorageFailure(
        'Could not write to the local database.',
      );

      expect(failure.message, 'Could not write to the local database.');
      expect(
        failure.toString(),
        'LocalStorageFailure(Could not write to the local database.)',
      );
    });

    test('LocalStorageFailure equality is value-based', () {
      expect(
        const LocalStorageFailure('same'),
        const LocalStorageFailure('same'),
      );
      expect(
        const LocalStorageFailure('same').hashCode,
        const LocalStorageFailure('same').hashCode,
      );
      expect(
        const LocalStorageFailure('same'),
        isNot(const LocalStorageFailure('different')),
      );
    });

    test('CancelledFailure has no payload and a fixed toString', () {
      const failure = CancelledFailure();

      expect(failure, const CancelledFailure());
      expect(failure.hashCode, const CancelledFailure().hashCode);
      expect(failure.toString(), 'CancelledFailure()');
    });

    test('UnexpectedFailure preserves the original error and stack trace', () {
      final error = StateError('unreachable');
      final stackTrace = StackTrace.current;
      final failure = UnexpectedFailure(error, stackTrace);

      expect(failure.error, error);
      expect(failure.stackTrace, stackTrace);
      expect(failure.toString(), 'UnexpectedFailure($error)');
    });

    test('UnexpectedFailure stack trace is optional', () {
      final error = StateError('unreachable');
      final failure = UnexpectedFailure(error);

      expect(failure.stackTrace, isNull);
    });

    test('UnexpectedFailure equality compares the wrapped error', () {
      final errorA = StateError('same message');
      final errorB = StateError('same message');

      expect(UnexpectedFailure(errorA), UnexpectedFailure(errorA));
      expect(
        UnexpectedFailure(errorA).hashCode,
        UnexpectedFailure(errorA).hashCode,
      );
      // Distinct StateError instances are not == to each other even with
      // the same message, so distinct UnexpectedFailures wrapping them
      // must not be == either -- this is identity-preserving, not lossy.
      expect(UnexpectedFailure(errorA), isNot(UnexpectedFailure(errorB)));
    });

    test('every AppFailure subtype is reachable through a switch', () {
      String describe(AppFailure failure) => switch (failure) {
        EngineFailure() => 'engine',
        ConnectionFailure() => 'connection',
        ValidationFailure() => 'validation',
        LocalStorageFailure() => 'local_storage',
        CancelledFailure() => 'cancelled',
        UnexpectedFailure() => 'unexpected',
      };

      expect(describe(const EngineFailure(code: 'X', msg: 'x')), 'engine');
      expect(describe(const ConnectionFailure('x')), 'connection');
      expect(describe(const ValidationFailure('x')), 'validation');
      expect(describe(const LocalStorageFailure('x')), 'local_storage');
      expect(describe(const CancelledFailure()), 'cancelled');
      expect(describe(UnexpectedFailure(StateError('x'))), 'unexpected');
    });
  });

  group('EngineOperationResultDiagnostics', () {
    test('keeps successful maps intact', () {
      const payload = <String, dynamic>{'status': 'success', 'value': 3};
      expect(
        const Ok<Map<String, dynamic>>(payload).diagnosticPayload,
        payload,
      );
    });

    test('rebuilds engine failures with structured context', () {
      const failure = EngineFailure(
        code: 'ENGINE_AUTH_FAILED',
        msg: 'Host key changed.',
        stage: 'connect',
        details: 'fingerprint mismatch',
        context: <String, dynamic>{'host_key_confirmation_required': true},
      );
      expect(
        const Err<Map<String, dynamic>>(failure).diagnosticPayload,
        <String, dynamic>{
          'status': 'error',
          'code': 'ENGINE_AUTH_FAILED',
          'msg': 'Host key changed.',
          'stage': 'connect',
          'details': 'fingerprint mismatch',
          'host_key_confirmation_required': true,
        },
      );
      expect(
        const Err<Map<String, dynamic>>(
          EngineFailure(code: 'ENGINE_RUNTIME_ERROR', msg: 'boom'),
        ).diagnosticPayload,
        <String, dynamic>{
          'status': 'error',
          'code': 'ENGINE_RUNTIME_ERROR',
          'msg': 'boom',
        },
      );
    });

    test('rebuilds typed failure evidence under its additive wire field', () {
      final evidence = DeployFailureEvidence.fromPayload(<String, dynamic>{
        'schema_version': 1,
        'phase': 'candidate_readiness',
        'source': 'candidate_probe',
        'completeness': 'diagnostic',
        'lines': <String>['candidate returned HTTP 503'],
        'failed_step_id': 'app_release',
        'failed_action_id': 'candidate_readiness',
        'probe': <String, dynamic>{'path': '/up', 'http_status': 503},
      });

      expect(
        Err<Map<String, dynamic>>(
          EngineFailure(
            code: 'ENGINE_OPERATION_FAILED',
            msg: 'Candidate readiness failed.',
            failureEvidence: evidence,
          ),
        ).diagnosticPayload,
        <String, dynamic>{
          'status': 'error',
          'code': 'ENGINE_OPERATION_FAILED',
          'msg': 'Candidate readiness failed.',
          deployFailureEvidenceEnvelopeField: evidence!.toPayload(),
        },
      );
    });

    test('rebuilds every non-engine failure category', () {
      expect(
        const Err<Map<String, dynamic>>(
          CancelledFailure(),
        ).diagnosticPayload['code'],
        'ENGINE_TASK_CANCELLED',
      );
      expect(
        const Err<Map<String, dynamic>>(
          ConnectionFailure('offline'),
        ).diagnosticPayload['code'],
        'ENGINE_CONNECTION_FAILED',
      );
      expect(
        const Err<Map<String, dynamic>>(
          ValidationFailure('invalid'),
        ).diagnosticPayload['code'],
        'ENGINE_CLIENT_VALIDATION_ERROR',
      );
      expect(
        const Err<Map<String, dynamic>>(
          LocalStorageFailure('full'),
        ).diagnosticPayload['code'],
        'ENGINE_LOCAL_STORAGE_ERROR',
      );
      expect(
        Err<Map<String, dynamic>>(
          UnexpectedFailure(StateError('unexpected')),
        ).diagnosticPayload['code'],
        'ENGINE_CLIENT_UNEXPECTED_ERROR',
      );
    });
  });
}
